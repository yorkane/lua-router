-- resty.luarouter.config_store.snapshot
-- P12 配置内部形态与派生视图 + P13 env 层装配 + P14 snapshot_of + P15 卡片 patch 合并与
-- 配置期校验 + P16 cfg_from_document。snapshot_of 与 cfg_from_document 同域（磁盘字节
-- 形状是对外契约）；sync_virtual_view 只在三条写路径上被显式调用，读时不派生。
--
-- 由 lualib/resty/luarouter/config_store.lua 拆分而来：函数体逐行原样搬家，只调整 require 与
-- 跨模块接线（doc/refactor-arch-2026-10-05.md §1–§2）。原文里经 _M.x() 的自调 → 经 CS_FACADE
-- 表调用（保住单测换桩的可拦截性逐点一致）；原文里的同文件 local 直调 → 直接 require 对端
-- 子模块的共享表调用（不进 facade 导出面，_M 契约因此逐名不变）。
local CS_FACADE = require "resty.luarouter.config_store"
local cjson = require "cjson.safe"
local JSON_NULL = cjson.null
local CS_LEXICON = require "resty.luarouter.config_store.lexicon"
local CS_ENV = require "resty.luarouter.config_store.env"
local CS_PROFILES = require "resty.luarouter.config_store.profiles"
local CS_UPSTREAMS = require "resty.luarouter.config_store.upstreams"

local _M = {}

local function new_cfg()
    return {
        default_effort = nil,
        effort_map = {},
        model_ctx = {},
        -- 平铺层的「单次输出预算上限」（与 model_ctx 同形状）：卡片上的
        -- max_output_tokens 优先，这里是没有卡片时的兜底读数。对外落到
        -- /v1/models 的 capabilities.max_output_tokens（用户裁定 2026-10-08：原
        -- context_limit 字段改名，不再参与 context_length 的决定）。
        model_max_output_tokens = {},
        model_effort = {},
        model_configs = {},
        virtual_models = {},
        -- Routing overrides (doc/gap-routing-dyn.md). Both stay empty when the
        -- operator has not touched the routing page, which is what keeps the
        -- policy chain byte-identical to the pre-feature behaviour.
        policy = nil,
        model_policies = {},
        -- Virtual-model profiles (doc/gap-virtual-models.md 3.1): alias -> {target,
        -- workers, policy, effort}. virtual_models stays the alias->target map the
        -- pre-feature readers use, so removing an entry clears both views.
        virtual_profiles = {},
        -- Ordered upstream declaration layer (normalized url + key tri-state).
        upstreams = {},
        -- /v1/models「只广告虚拟入口」开关，两份读数按**来源**分家（见
        -- _M.models_virtual_only 的优先级说明）：
        --   * models_virtual_only      = 磁盘快照里操作员声明的那一份，nil = 「没说」
        --   * models_virtual_only_env  = 环境层那一份，nil = 「没说」
        -- 只有磁盘那一份会被 snapshot_of 回写。两份都必须三态（nil / true / false）而不是
        -- 合并成一个布尔：false 是「说了要全量广告」这个结论，要能压过另一层的 true，而 nil
        -- 只是沉默（与硬规则 9 第二条同一套三态纪律）。合并成一份的代价更实在 —— 任何
        -- 「env 赢进来又被 write_snapshot 落盘」的路径，都会把一个只存在于环境变量里的声明
        -- 冻结进配置文件，操作员之后删掉 env 也关不掉它（本文件为 target / explicit_targets
        -- 已经立过两次同样的规矩）。
        models_virtual_only = nil,
        models_virtual_only_env = nil,
    }
end

--- Derive the legacy alias -> representative-target map from the profiles, which are
--- the single source of truth (root ruling 2026-10-02).
---
--- 为什么派生而不是并行维护：这两张表各自被独立写入过（cfg_from_document 与
--- apply_profiles 各写一次），于是任何一条只清一张表的路径都会留下"幻影别名"——
--- resolve_model / /v1/models / 模型文档三处 reader 各自读到不同的一张。1 对多之后
--- virtual_models 的单值语义本来也不成立了（一个入口对应一组模型，没有唯一的"它的
--- target"），把它降级成派生视图既消除了双写，也让 reader 在"必须只有一个名字"的
--- 地方继续读到代表值而不是 nil。
local function sync_virtual_view(cfg)
    local map = {}
    for alias, profile in pairs(cfg.virtual_profiles or {}) do
        if type(profile) == "table" then
            -- 写过 targets 的入口，代表值取**组头**而不是 profile.target：操作员可以先写
            -- target、再用 JSON 视图把那个名字从组里删掉，此时 profile.target 是一个已经
            -- 不属于这个入口的名字。让它进派生视图，resolve_model / 模型文档就会把流量与
            -- 卡片去找一个根本不在这个组里的模型名（选路本身不受影响：组候选的转发名一律
            -- 取 lr_bound_model）。profile.target 本身保持写过的原值不动，磁盘上的字节仍
            -- 由操作员说了算 —— 这里只保证派生视图与组口径一致。
            local rep = profile.target
            if profile.explicit_targets == true and type(profile.targets) == "table" then
                local head = profile.targets[1]
                if type(head) == "string" and head ~= "" then
                    rep = head
                end
            end
            -- 同名遮蔽（方案 A）下 rep 可以**等于 alias 自己**（入口 X 的组头就是它遮蔽的那个
            -- 真实模型 X）。这不是自映射环，也不需要在这里挡：
            --   * resolve_model 只在请求入口调用一次（router/inference.lua 的 resolve_alias），
            --     不存在把返回值再喂回自己的循环，恒等值因此只是「按原名查卡」；
            --   * 转发体的 model 一律取 worker.lr_bound_model（router/forward.lua），跟这张派生
            --     表无关，所以恒等映射不会把一个不是引擎真名的字符串发上游——那个名字能被写进
            --     组里，前提是 build_profiles 问过引擎（config_store/profiles.lua 的判据），
            --     或者它是磁盘快照的读路径（cfg_from_document 的 reload 上下文），后者不新增状态；
            --   * 「代表值取组头」这条口径保持不变：入口赢的语义要求 X 的卡片/档位/容量按 X 查，
            --     组头恰好是 X 时读到的正是被遮蔽那台实例的读数。
            map[alias] = rep
        end
    end
    cfg.virtual_models = map
end

--- 档位映射的对外形状：内部按 from 建表，磁盘与 UI 用有序数组 {from,to}。卡片、条目、
--- 全局三层共用这一个序列化器，往返（读回来再写出去）才不会有三种不同的字节。
local function effort_pairs(map)
    local out = {}
    if type(map) ~= "table" then return out end
    for _, from in ipairs(CS_LEXICON.sorted_keys(map)) do
        out[#out + 1] = { from = from, to = map[from] }
    end
    return out
end

local function new_card()
    -- max_output_tokens 是操作员替这台引擎声明的**单次输出预算上限**（用户裁定
    -- 2026-10-08，原名 context_limit）：它唯一的去处是 /v1/models 的
    -- capabilities.max_output_tokens 声明层，压过引擎自报的那一份。它不参与任何
    -- max_tokens 改写（root ruling 2026-10-04: the gateway rewrites no output budget），
    -- 也不再影响 capabilities.context_length —— 那条链只由 ctx（声明窗口）与引擎自报决定。
    -- 五个能力位都是三态：nil = 操作员没说（该维度让位给引擎自报），false = 说了不支持。
    -- 显式写成 nil 是为了把「这张卡片存在」与「这张卡片声明过能力位」分开——前者由
    -- new_card 决定，后者只看这些键上有没有真布尔（读侧一律 type == "boolean" 判定）。
    return { ctx = nil, max_output_tokens = nil, default_effort = nil,
             effort_map = {}, modalities = nil, supports_tool_use = nil,
             supports_streaming = nil, supports_reasoning = nil,
             supports_vision = nil, supports_reasoning_effort = nil,
             -- 操作员勾选的档位阶梯（用户诉求 2026-10-08）。nil = 没说，该维度让位给引擎
             -- 自报；非 nil = 整条替换对外读数。形状与 registry 归一化后的阶梯一致
             -- （{value,label?,default}），所以对外那份读数分不出数字来自哪一层——这正是
             -- 想要的：客户端不需要知道这个数字是谁说的。
             reasoning_efforts = nil,
             -- 「隐藏」（用户裁定 2026-10-08，2026-10-09 收窄）：三态，nil = 操作员没说，
             -- true = 该模型**不再对外广告**（/v1/models 不产出它），但它照常服务：仍进候选池、
             -- 仍被 watcher 注册与保留、仍能被虚拟入口选作落点。「不广告却继续服务」正是这个
             -- 开关存在的理由（只由虚拟入口对外、真实名不外露的那批引擎）。
             -- 刻意**不是** false 缺省：false 与 nil 在读取侧走的是同一条「照旧」支路，但磁盘上
             -- 必须分得开「说了不隐藏」与「没说」（与旁边五条能力位同一条三态纪律）。
             hidden = nil,
             -- 「禁用」（用户裁定 2026-10-09 新增）：三态，nil = 没说，true = 该模型**既不对外
             -- 广告也不被服务**（/v1/models 不产出、watcher 不注册/摘除、路由候选排除）—— 也就是
             -- 2026-10-08 那版 hidden 的语义，收窄后搬到这个开关上。两个开关刻意分成两个字段而
             -- 不是一个枚举：它们各自独立地「或」进判定（卡片或入口任一说了 true 即命中），且
             -- 隐藏是审美、禁用是熔断，操作员改的经常是其中一个。
             -- 同一份名册的判定实现见 config_store/readers.lua（model_is_hidden /
             -- model_is_disabled，共用一次扫描与一套失效口径）。
             disabled = nil }
end

local function cfg_from_env()
    local cfg = new_cfg()
    local default_effort = CS_FACADE.normalize_effort(CS_ENV.env("LMR_DEFAULT_EFFORT"))
    if default_effort and default_effort ~= false then cfg.default_effort = default_effort end

    -- 开关的环境层，写进 models_virtual_only_env（不写磁盘层那一份，理由见 new_cfg）。
    -- env() 对「未声明」和「空串」都答 nil，所以这里只认「说过」= 非 nil，值本身交给
    -- advertise_truthy 判定；缺省不设 = 关 = /v1/models 逐字节与开关落地前一致
    -- （AGENTS.md「新开关缺省零行为变化」）。
    --
    -- env 的 false 不单独造一个「明确说关」的三态：LMR_MODELS_VIRTUAL_ONLY=false 在这里
    -- 就是关，和没说一样，反正磁盘层无论如何都压过它（见 _M.models_virtual_only）。
    local virtual_only_env = CS_ENV.env("LMR_MODELS_VIRTUAL_ONLY")
    if virtual_only_env ~= nil then
        cfg.models_virtual_only_env = CS_LEXICON.advertise_truthy(virtual_only_env)
    end

    for _, pair in ipairs(CS_LEXICON.parse_pairs(CS_ENV.env("LMR_EFFORT_MAP"))) do
        local from = CS_FACADE.normalize_effort(pair[1])
        if from and from ~= false and pair[2] ~= "" then cfg.effort_map[from] = pair[2] end
    end
    for _, pair in ipairs(CS_LEXICON.parse_pairs(CS_ENV.env("LMR_MODEL_CTX"))) do
        local ctx = CS_LEXICON.parse_positive_int(pair[2])
        if ctx then cfg.model_ctx[pair[1]] = ctx end
    end
    -- 平铺层的单次输出预算上限，与 LMR_MODEL_CTX 同一形状（model=value）。它是操作员
    -- 替这台引擎声明的 max_output_tokens 读数，唯一去处是 /v1/models 的
    -- capabilities.max_output_tokens 声明层；不参与任何钳制，也不决定 context_length。
    for _, pair in ipairs(CS_LEXICON.parse_pairs(CS_ENV.env("LMR_MODEL_MAX_OUTPUT_TOKENS"))) do
        local limit = CS_LEXICON.parse_positive_int(pair[2])
        if limit then cfg.model_max_output_tokens[pair[1]] = limit end
    end
    for _, pair in ipairs(CS_LEXICON.parse_pairs(CS_ENV.env("LMR_MODEL_EFFORT"))) do
        local effort = CS_FACADE.normalize_effort(pair[2])
        if effort and effort ~= false then cfg.model_effort[pair[1]] = effort end
    end

    local cards = cfg.model_configs
    local function card_for(model)
        local card = cards[model]
        if not card then card = new_card(); cards[model] = card end
        return card
    end
    for _, pair in ipairs(CS_LEXICON.parse_pairs(CS_ENV.env("LMR_MODEL_EFFORT_MAP"))) do
        local from, to = pair[2]:match("^(.-)>(.*)$")
        from = CS_FACADE.normalize_effort(from)
        to = CS_FACADE.normalize_effort(to)
        if from and to and from ~= false and to ~= false then
            card_for(pair[1]).effort_map[from] = to
        end
    end
    for _, pair in ipairs(CS_LEXICON.parse_pairs(CS_ENV.env("LMR_MODEL_MODALITIES"))) do
        local caps = CS_LEXICON.parse_caps(pair[2])
        if caps then card_for(pair[1]).modalities = caps end
    end
    -- 卡片级档位勾选的 env 层（用户诉求 2026-10-08），形状照 LMR_MODEL_MODALITIES：
    -- "model:low+medium+high"（parse_pairs 先按 model:值 切成一行，值侧的分隔符在这里自己切,
    -- 因为 parse_pairs 是按逗号切行的 —— 值里再放逗号会把后面每个档位切成独立一行）。
    -- 档位名一律过归一化器；一个拼错的名字会被客户端原样发给引擎并在那里 400，而 env 层的
    -- 垃圾值历来是整条忽略，不替操作员猜一个近似名。整行洗不出任何档位 = 没说，不建卡。
    for _, pair in ipairs(CS_LEXICON.parse_pairs(CS_ENV.env("LMR_MODEL_EFFORT_LEVELS"))) do
        local ladder, seen = {}, {}
        -- 值侧的分隔符一律归成 +：档位名只含字母（词表 low/medium/high/xhigh/max/…），
        -- 所以按「非字母」切既容忍逗号/分号/空白/竖线，也不需要再操心转义。
        for piece in ((pair[2] or ""):gsub("[^%a]+", "+")):gmatch("([^+]+)") do
            local name = CS_LEXICON.normalize_effort(piece)
            if name and name ~= false and not seen[name] then
                seen[name] = true
                ladder[#ladder + 1] = { value = name, ["default"] = false }
            end
        end
        if #ladder > 0 then card_for(pair[1]).reasoning_efforts = ladder end
    end
    -- 卡片级 tool use 声明的 env 层：model=true|false。缺省不设 = 一个卡片都不建，
    -- 行为与改动前逐字节一致（新开关缺省零行为变化）。只认严格的小写 true/false，
    -- 其他写法一律当「没写」——env 层的垃圾值历来是忽略而不是拉网关下水。
    for _, pair in ipairs(CS_LEXICON.parse_pairs(CS_ENV.env("LMR_MODEL_TOOL_USE"))) do
        local value = CS_LEXICON.lower(pair[2])
        if value == "true" or value == "false" then
            card_for(pair[1]).supports_tool_use = (value == "true")
        end
    end
    for _, pair in ipairs(CS_LEXICON.parse_pairs(CS_ENV.env("LMR_VIRTUAL_MODELS"))) do
        local alias, target = pair[1], pair[2]
        if alias ~= "" and target ~= "" and alias ~= target then
            -- Old alias=target pairs are exactly the new shape with no candidates
            -- and no overrides, so both views get the same content.
            cfg.virtual_profiles[alias] = { target = target, targets = { target } }
        end
    end
    for _, entry in ipairs(CS_FACADE.env_upstreams()) do
        local item, err = CS_UPSTREAMS.upstream_from_entry(entry, #cfg.upstreams + 1)
        if item then
            local dup = false
            for _, existing in ipairs(cfg.upstreams) do
                if existing.url == item.url then dup = true break end
            end
            if not dup then cfg.upstreams[#cfg.upstreams + 1] = item end
        elseif err then
            CS_LEXICON.ngx_log_warn("luarouter config env upstream skipped: ", err)
        end
    end
    -- virtual_models 是派生视图，env 层同样要同步：否则 LMR_VIRTUAL_MODELS 种子进来的别名
    -- 只进了 virtual_profiles 一张表，resolve_model / snapshot_of / virtual_models_list 三个
    -- 读者全都读不到它，行为等同于整条 env 配置被静默丢弃。
    sync_virtual_view(cfg)
    return cfg
end

--- Array snapshot, same key set and shapes as Rust RuntimeConfig::snapshot().
local function snapshot_of(cfg)
    local effort_map = {}
    for _, from in ipairs(CS_LEXICON.sorted_keys(cfg.effort_map)) do
        effort_map[#effort_map + 1] = { from = from, to = cfg.effort_map[from] }
    end
    local model_ctx = {}
    for _, model in ipairs(CS_LEXICON.sorted_keys(cfg.model_ctx)) do
        model_ctx[#model_ctx + 1] = { model = model, ctx = cfg.model_ctx[model] }
    end
    local model_max_output_tokens = {}
    for _, model in ipairs(CS_LEXICON.sorted_keys(cfg.model_max_output_tokens)) do
        model_max_output_tokens[#model_max_output_tokens + 1] = {
            model = model, max_output_tokens = cfg.model_max_output_tokens[model],
        }
    end
    local model_effort = {}
    for _, model in ipairs(CS_LEXICON.sorted_keys(cfg.model_effort)) do
        model_effort[#model_effort + 1] = { model = model, effort = cfg.model_effort[model] }
    end
    local model_configs = {}
    for _, model in ipairs(CS_LEXICON.sorted_keys(cfg.model_configs)) do
        local card = cfg.model_configs[model]
        local map = {}
        for _, from in ipairs(CS_LEXICON.sorted_keys(card.effort_map)) do
            map[#map + 1] = { from = from, to = card.effort_map[from] }
        end
        local row = {
            model = model,
            ctx = CS_LEXICON.nul(card.ctx),
            max_output_tokens = CS_LEXICON.nul(card.max_output_tokens),
            default_effort = CS_LEXICON.nul(card.default_effort),
            effort_map = CS_LEXICON.arr(map),
            modalities = CS_LEXICON.nul(card.modalities),
            -- 档位阶梯的往返（用户诉求 2026-10-08）：与旁边的三态字段同一条纪律 —— null =
            -- 「清除回自动」（让位引擎自报），数组 = 操作员的结论。逐档重写而不是原样回吐
            -- 表引用：磁盘上那份字节必须由 normalize 后的形状决定，否则手改进来的多余键会
            -- 一路活到 /v1/models。空数组刻意保留（它编码成 []，读作「这台一个档位都不收」，
            -- 是一句肯定答复），「自动」由 null 表达，两者不合并。
            reasoning_efforts = card.reasoning_efforts == nil and CS_LEXICON.nul(nil) or (function ()
                local rows = {}
                for _, rung in ipairs(card.reasoning_efforts) do
                    if type(rung) == "table" and type(rung.value) == "string" then
                        rows[#rows + 1] = {
                            value = rung.value,
                            label = CS_LEXICON.nul(rung.label),
                            ["default"] = rung["default"] == true,
                        }
                    end
                end
                return CS_LEXICON.arr(rows)
            end)(),
            -- Tri-state: absent/null = "unknown" (nul renders the JSON null the editor
            -- round-trips as "leave alone"), false = the operator said no. The two must
            -- never merge on the way to disk, hence nul() rather than a bare field.
            -- 四条新能力位同一条纪律（2026-10-05）：全部走 nul，false 落 false、
            -- 没说落 null，编辑器的「留空 = 不动」与「说不支持」因此在磁盘上仍然可分。
            supports_tool_use = CS_LEXICON.nul(card.supports_tool_use),
            supports_streaming = CS_LEXICON.nul(card.supports_streaming),
            supports_reasoning = CS_LEXICON.nul(card.supports_reasoning),
            supports_vision = CS_LEXICON.nul(card.supports_vision),
            supports_reasoning_effort = CS_LEXICON.nul(card.supports_reasoning_effort),
        }
        -- 「隐藏」与「禁用」（用户裁定 2026-10-09）**不走**上面那一族 nul：那五位是对外读数，
        -- 操作员「没说」时磁盘上写 null 是编辑器「留空 = 不动」的那一份字节；hidden / disabled
        -- 不参与任何对外形状，一条没人声明过的 hidden:null 只会让每份老配置的磁盘字节都长出
        -- 一个键（违反「新开关缺省零行为变化」，也把 Rust 对拍的 model_configs 行字段表整页翻
        -- 掉）。缺席 = 没说，与条目层那五位同一条「绝不无中生有一个没人声明过的字段」的约定；
        -- false 是结论、必须写成 false，与条目层的 supports_* 同一条纪律。
        if card.hidden ~= nil then row.hidden = card.hidden end
        if card.disabled ~= nil then row.disabled = card.disabled end
        model_configs[#model_configs + 1] = row
    end
    local virtual_models = {}
    for _, alias in ipairs(CS_LEXICON.sorted_keys(cfg.virtual_models)) do
        local profile = cfg.virtual_profiles[alias] or { target = cfg.virtual_models[alias] }
        -- target 只在操作员真的写过它时回写。candidates-only 的配置里 profile.target 是
        -- 从第一条绑定推出来的代表值，写进磁盘就变成一个没人声明过的模型名：它会被后续
        -- reader 当成真实模型去找 effort/policy 卡，也会让"删掉 target"这种编辑在下次
        -- reload 后悄悄复活。缺省字段（而不是 null）是这里既有的往返约定。
        local entry = { model = alias }
        -- Same "only what the operator wrote" rule as target above: a legacy pair or a
        -- candidates-only row re-derives its group at read time, so re-emitting it here
        -- would put a derived list on disk and make "delete the targets" an edit that
        -- silently resurrects itself on the next reload.
        if profile.explicit_targets and profile.targets then
            entry.targets = { table.unpack(profile.targets) }
        end
        if profile.candidates then
            if profile.explicit_target then
                entry.target = profile.target or cfg.virtual_models[alias]
            end
            entry.candidates = CS_PROFILES.copy_bindings(profile.candidates)
        elseif not profile.explicit_targets then
            entry.target = profile.target or cfg.virtual_models[alias]
        end
        -- Optional fields are absent rather than null so a snapshot written by an
        -- older build round-trips unchanged and the JSON editor stays readable.
        if profile.workers then entry.workers = profile.workers end
        -- policy/effort are legacy-carried only (root ruling 2026-10-02): the hot path
        -- ignores them, but a row that still has them keeps them on disk so nothing an
        -- operator never deleted can vanish from the authoritative JSON view.
        if profile.policy then entry.policy = profile.policy end
        if profile.effort then entry.effort = profile.effort end
        -- Entry-level declarations (root ruling 2026-10-04): written only when the
        -- operator wrote them, same "never invent a field" rule as the block above.
        -- supports_tool_use is the exception that proves it -- false is *written as*
        -- false, because false is an answer and not an absence.
        if profile.default_effort then entry.default_effort = profile.default_effort end
        if profile.effort_map then
            entry.effort_map = effort_pairs(profile.effort_map)
        end
        if profile.modalities then entry.modalities = { table.unpack(profile.modalities) } end
        -- 能力位 false 是结论、必须写成 false；缺席是沉默、必须整个键不出现（写 null
        -- 会让老 build 与 JSON 编辑器把「擦掉声明」与「说了不支持」读成同一件事）。
        -- 与卡片那五条用 nul 相反：条目层是可选字段缺席的约定（见上面 default_effort 一段）。
        for _, field in ipairs({ "supports_tool_use", "supports_streaming",
                                 "supports_reasoning", "supports_vision",
                                 "supports_reasoning_effort" }) do
            if profile[field] ~= nil then entry[field] = profile[field] end
        end
        -- 「隐藏」与「禁用」与那五位同一条条目层纪律：false 是结论、必须写成 false，缺席是
        -- 沉默、整个键不出现（写 null 会让老 build 与 JSON 编辑器把「擦掉声明」与「说了不隐藏」
        -- 读成同一件事）。同样刻意不进上面那个循环，理由见 profiles.lua 的 build_entry_declarations。
        if profile.hidden ~= nil then entry.hidden = profile.hidden end
        if profile.disabled ~= nil then entry.disabled = profile.disabled end
        if profile.context_window then entry.context_window = profile.context_window end
        virtual_models[#virtual_models + 1] = entry
    end
    local upstreams = {}
    for _, item in ipairs(cfg.upstreams or {}) do
        local entry = {
            url = item.url,
            model_id = CS_LEXICON.nul(item.model_id),
            -- Never echo the secret: the field is present and always null so the
            -- JSON editor round-trips it as "leave the stored key alone" (3.4).
            api_key = JSON_NULL,
            priority = tonumber(item.priority) or 50,
            cost = tonumber(item.cost) or 1.0,
            labels = item.labels or {},
            disable_health_check = (item.disable_health_check and true) or false,
        }
        -- Advertised coverage rides the snapshot so the JSON editor round-trips it:
        -- absent when nothing was declared (never an explicit null), which is what
        -- distinguishes "the probe decides" from "declared empty" on the way back in.
        if item.models then entry.models = { table.unpack(item.models) } end
        -- Capacity gates round-trip the same way (doc/caps-redesign-2026-10-06.md §1,
        -- which supersedes doc/gap-worker-caps.md): written only when the row declared a
        -- usable limit, and *absent* (never an explicit null) for "unlimited". Writing
        -- an explicit null would make the snapshot carry a field no operator declared,
        -- and an old build reading it would have to know the key means nothing.
        --
        -- Per-tier normalizer, and the util tier cannot borrow the concurrency one:
        -- cap_limit folds <= 0 to nil, which would erase max_gpu_util = 0 -- the
        -- strictest legal gate -- into silence. No new phantom key is emitted either,
        -- which is what the lossless round-trip pins.
        for _, field in ipairs(CS_UPSTREAMS.CAP_FIELDS) do
            local cap
            if field == "max_gpu_util" then
                cap = CS_PROFILES.declared_util(item[field])
            else
                cap = CS_PROFILES.declared_cap(item[field], true)
            end
            if cap ~= nil then entry[field] = cap end
        end
        -- Persistence half of the key: state + value ride the snapshot so a
        -- restart (or another worker) can re-apply the same key without ever
        -- seeing it on the wire.
        if item.api_key_state then entry.api_key_state = item.api_key_state end
        if item.api_key_stored then entry.api_key_stored = item.api_key_stored end
        entry.has_api_key = (item.api_key_state == "set") == true
        upstreams[#upstreams + 1] = entry
    end
    local model_policies = {}
    for _, model in ipairs(CS_LEXICON.sorted_keys(cfg.model_policies)) do
        model_policies[#model_policies + 1] = { model = model, policy = cfg.model_policies[model] }
    end
    local snap = {
        default_effort = CS_LEXICON.nul(cfg.default_effort),
        effort_map = CS_LEXICON.arr(effort_map),
        model_ctx = CS_LEXICON.arr(model_ctx),
        model_max_output_tokens = CS_LEXICON.arr(model_max_output_tokens),
        model_effort = CS_LEXICON.arr(model_effort),
        model_configs = CS_LEXICON.arr(model_configs),
        virtual_models = CS_LEXICON.arr(virtual_models),
        policy = CS_LEXICON.nul(cfg.policy),
        model_policies = CS_LEXICON.arr(model_policies),
        upstreams = CS_LEXICON.arr(upstreams),
    }
    -- 开关的回写半：只有磁盘层那一份会被 re-emit，而且只在操作员真的在这份文件里说过时
    -- 才有键 —— 缺席而不是显式 null，与 target / explicit_targets / caps 同一套「绝不无中生有
    -- 一个没人声明过的字段」的约定（也保住「从没碰过这个开关的部署，落盘字节与今天逐字节
    -- 相同」）。环境层刻意不回写：把 env 的读数冻结进配置文件，等于让操作员删了环境变量也
    -- 关不掉它。
    --
    -- 这一支就是「从 /_ui/config 保存一次会把这个键抹掉」那个 bug 的正解：整表替换走
    -- cfg_from_document -> snapshot_of，未知键在两端都没有落点，于是每次保存都把它从磁盘上
    -- 擦掉。读侧（cfg_from_document）与写侧（这里）必须同时有，缺一个都等于没修。
    if cfg.models_virtual_only ~= nil then
        snap.models_virtual_only = cfg.models_virtual_only
    end
    return snap
end

-- --------------------------------------------------------------- validation

--- Merge one patch into a model card (Rust RuntimeConfig::merge_model_patch):
--- absent field = leave alone, null = clear back to auto.
local function merge_model_patch(card, patch)
    if patch.ctx ~= nil or patch.ctx == JSON_NULL then
        local raw = patch.ctx
        if raw == JSON_NULL then
            card.ctx = nil
        elseif type(raw) == "number" then
            local n = CS_LEXICON.parse_positive_int(raw)
            if not n then return nil, "ctx must be greater than zero" end
            card.ctx = n
        elseif type(raw) == "string" then
            local s = CS_LEXICON.trim(raw)
            if s == "" then
                card.ctx = nil
            else
                local n = CS_LEXICON.parse_positive_int(s)
                if not n then return nil, string.format("ctx must be a number: %s", s) end
                card.ctx = n
            end
        else
            return nil, "ctx must be a number or null"
        end
    end

    -- 单次输出预算上限（操作员替这台引擎声明的读数，原名 context_limit，
    -- 用户裁定 2026-10-08）。解析口径照抄 ctx：absent = leave alone,
    -- null = clear back to "unknown"（未知即让位给引擎自报）。它不参与任何
    -- max_tokens 钳制（2026-10-04 裁定），唯一去处是 /v1/models 的
    -- capabilities.max_output_tokens 声明层。
    if patch.max_output_tokens ~= nil then
        local raw = patch.max_output_tokens
        if raw == JSON_NULL then
            card.max_output_tokens = nil
        elseif type(raw) == "number" then
            local n = CS_LEXICON.parse_positive_int(raw)
            if not n then return nil, "max_output_tokens must be greater than zero" end
            card.max_output_tokens = n
        elseif type(raw) == "string" then
            local s = CS_LEXICON.trim(raw)
            if s == "" then
                card.max_output_tokens = nil
            else
                local n = CS_LEXICON.parse_positive_int(s)
                if not n then return nil, string.format("max_output_tokens must be a number: %s", s) end
                card.max_output_tokens = n
            end
        else
            return nil, "max_output_tokens must be a number or null"
        end
    end

    if patch.default_effort ~= nil or patch.default_effort == JSON_NULL then
        local raw = patch.default_effort
        if raw == JSON_NULL then
            card.default_effort = nil
        elseif type(raw) == "string" then
            local trimmed = CS_LEXICON.trim(raw)
            if trimmed == "" or CS_LEXICON.lower(trimmed) == "null" then
                card.default_effort = nil
            else
                local effort = CS_FACADE.normalize_effort(trimmed)
                if effort == false then
                    return nil, string.format(
                        "unknown effort for default_effort: %s (want one of %s)",
                        trimmed, CS_LEXICON.EFFORT_LEVELS_JOIN)
                end
                card.default_effort = effort
            end
        else
            return nil, "default_effort must be a string or null"
        end
    end

    if patch.effort_map ~= nil then
        if patch.effort_map == JSON_NULL then
            card.effort_map = {}
        elseif CS_LEXICON.is_array(patch.effort_map) then
            local next_map = {}
            for _, entry in ipairs(patch.effort_map) do
                local from = CS_FACADE.normalize_effort(entry.from)
                local to = CS_LEXICON.trim(entry.to)
                if from == false or from == nil then
                    return nil, string.format("unknown effort in map: %s", tostring(entry.from or ""))
                end
                if to ~= "" then
                    local to_norm = CS_FACADE.normalize_effort(to)
                    if to_norm == false then
                        return nil, string.format(
                            "unknown effort in map target: %s (want one of %s)", to, CS_LEXICON.EFFORT_LEVELS_JOIN)
                    end
                    next_map[from] = to_norm
                end
            end
            card.effort_map = next_map
        else
            return nil, "effort_map must be an array"
        end
    end

    if patch.modalities ~= nil or patch.modalities == JSON_NULL then
        local raw = patch.modalities
        if raw == JSON_NULL then
            card.modalities = nil
        elseif CS_LEXICON.is_array(raw) then
            local caps = {}
            for _, item in ipairs(raw) do
                if type(item) == "string" then
                    local cap = CS_LEXICON.lower(CS_LEXICON.trim(item))
                    if CS_LEXICON.MODALITY_SET[cap] then caps[#caps + 1] = cap end
                end
            end
            if #caps == 0 then
                card.modalities = { "text" }  -- explicit empty = text only, not auto
            else
                table.insert(caps, 1, "text")
                local seen, ordered = {}, {}
                for _, cap in ipairs(caps) do
                    if not seen[cap] then seen[cap] = true ordered[#ordered + 1] = cap end
                end
                table.sort(ordered, function(a, b)
                    if a == "text" then return b ~= "text" end
                    if b == "text" then return false end
                    return a < b
                end)
                card.modalities = ordered
            end
        else
            return nil, "modalities must be an array or null"
        end
    end

    -- 五个能力位（tool use 加上 2026-10-05 补齐的 streaming / reasoning / vision /
    -- reasoning_effort）：三态，nil = 不知道，false = 操作员说了不支持。解析口径照抄
    -- 其他卡片字段：absent = leave alone，null = clear 回「不知道」，布尔 = 写死。
    -- 这一族是「config 声明 > 引擎自报 > 整键省略」优先级里 config 那一层的唯一入口。
    -- 字段名与虚拟模型条目、UI 完全同名（扁平三态，与已上线的 supports_tool_use 同形状）：
    -- 刻意不折进 supports:{} 子对象，那会让已被测试钉住的 supports_tool_use 长出第二条路径。
    -- 五条走同一个循环，「每条都被读写」因此是结构性事实，而不是逐字段抄写的细心。
    for _, field in ipairs({ "supports_tool_use", "supports_streaming",
                             "supports_reasoning", "supports_vision",
                             "supports_reasoning_effort" }) do
        local raw = patch[field]
        if raw ~= nil then
            if raw == JSON_NULL then
                card[field] = nil
            elseif type(raw) == "boolean" then
                card[field] = raw
            else
                return nil, string.format("%s must be a boolean or null", field)
            end
        end
    end

    -- 「隐藏」与「禁用」（用户裁定 2026-10-09）：两个三态布尔，写入语义逐字照抄旁边那一族
    -- —— absent = 不动、null = 清回「没说」、true/false = 写死。刻意**不并进上面那个循环**：
    -- 那五位共享一条文案家族与一份被单测钉住的字段表，而 hidden / disabled 的语义根本不在
    -- 「能力位」那一族里（它们不是对外读数；hidden 管广告、disabled 连服务一起停）。两者都不进
    -- env 层：禁用是有熔断后果的决定（被禁的模型连候选都不进），隐藏也是对外契约的收窄，都只
    -- 从**磁盘配置**说得出，一个误设的环境变量不该让一台实例凭空消失。
    -- 字段名与语义在 2026-10-09 一分为二（hidden 只保留广告面，服务面让给 disabled）；读这两
    -- 个键的判定只有一份，见 config_store/readers.lua。
    for _, field in ipairs({ "hidden", "disabled" }) do
        local raw = rawget(patch, field)
        if raw ~= nil then
            if raw == JSON_NULL then
                card[field] = nil
            elseif type(raw) == "boolean" then
                card[field] = raw
            else
                return nil, string.format("%s must be a boolean or null", field)
            end
        end
    end

    -- 档位阶梯（用户诉求 2026-10-08）：absent = leave alone，null = clear 回「自动」
    -- （让位引擎自报），数组 = 操作员的结论、整条替换。与旁边的三态字段同一套写入语义，
    -- 区别只在值形状：那份是真布尔，这份是阶梯表，所以判定交给 lexicon 的归一化器，
    -- 它返回 false 表示「形状不对 / 有未知档位名」，当场 400 而不是悄悄丢档。
    if rawget(patch, "reasoning_efforts") ~= nil then
        local raw = patch.reasoning_efforts
        if raw == JSON_NULL then
            card.reasoning_efforts = nil
        else
            local ladder = CS_LEXICON.normalize_effort_ladder(raw)
            if ladder == false or ladder == nil then
                return nil, string.format(
                    "reasoning_efforts must be an array of effort names or null (want one of %s)",
                    CS_LEXICON.EFFORT_LEVELS_JOIN)
            end
            -- 空数组折回 nil（= 清除回自动），磁盘上不留 []：热路径上 card_ladder 对空表
            -- 答的就是「没说」（旁边的 clean_effort_ladder / clean_string_list 同一口径 ——
            -- 洗不出东西一律 nil，绝不报一份 [] 冒充「一个都不支持」这个肯定结论）。若这里
            -- 把 [] 存下来，磁盘上是一份、对外读数是另一份（退回引擎自报），同一份配置两种
            -- 说法；折成 nil 后「跟上游」只有一种拼法，管理台勾选框把全部取消折成 null 也与
            -- 这里对齐（见 ui/admin/models.html saveCard）。
            card.reasoning_efforts = #ladder > 0 and ladder or nil
        end
    end
    return true
end

--- Whole-document build (used by apply_document and from_snapshot): every
--- section is rebuilt from the payload, absent sections stay empty.
---@param doc table @ decoded document / stored snapshot
---@param previous table|nil @ url -> prior upstreams row, for key inheritance
---@param shadow table|nil @ 同名遮蔽判据上下文，透传给 build_profiles。**磁盘快照的读路径
---  （config_store/readers.lua 的 current()）必须传 new_shadow_context{reload=true}**：那份
---  路径上新增的任何拒绝都会让一份已落盘的配置在下次 reload 整体退回 env 默认（等于把网关
---  配置抹平）——与已移除的配置期校验（原 validate_declared_context_windows，2026-10-08）
---  刻意不挂读路径同一条理由。缺省（nil）是
---  **写入侧**口径：现查 registry 的引擎背书，所以 JSON 编辑器的整文档保存与 /_ui/config/virtual
---  两条链共用同一道判据，不会因为走的是不同入口而一边严一边松。
local function cfg_from_document(doc, previous, shadow)
    local cfg = new_cfg()
    if type(doc) ~= "table" then return cfg end

    if doc.default_effort ~= nil then
        local raw = doc.default_effort
        if raw == JSON_NULL then
            cfg.default_effort = nil
        elseif type(raw) == "string" then
            local trimmed = CS_LEXICON.trim(raw)
            if trimmed ~= "" and CS_LEXICON.lower(trimmed) ~= "null" then
                local effort = CS_FACADE.normalize_effort(trimmed)
                if effort == false then
                    return nil, string.format("unknown default_effort: %s", trimmed)
                end
                cfg.default_effort = effort
            end
        else
            return nil, "default_effort must be a string or null"
        end
    end

    if doc.effort_map ~= nil then
        if not CS_LEXICON.is_array(doc.effort_map) then return nil, "effort_map must be an array" end
        for _, entry in ipairs(doc.effort_map) do
            local from = CS_FACADE.normalize_effort(entry.from)
            local to = CS_LEXICON.trim(entry.to)
            if from == false or from == nil then
                return nil, string.format("unknown effort in effort_map: %s", tostring(entry.from or ""))
            end
            if to ~= "" then
                local to_norm = CS_FACADE.normalize_effort(to)
                if to_norm == false then
                    return nil, string.format("unknown effort in effort_map target: %s", to)
                end
                cfg.effort_map[from] = to_norm
            end
        end
    end

    if doc.model_ctx ~= nil then
        if not CS_LEXICON.is_array(doc.model_ctx) then return nil, "model_ctx must be an array" end
        for _, entry in ipairs(doc.model_ctx) do
            local model = CS_LEXICON.trim(entry.model)
            if model ~= "" then
                if entry.ctx == nil or entry.ctx == JSON_NULL then
                    return nil, string.format("model_ctx for %s needs a numeric ctx", model)
                end
                local ctx = CS_LEXICON.parse_positive_int(entry.ctx)
                if not ctx then
                    return nil, string.format("model_ctx for %s must be greater than zero", model)
                end
                cfg.model_ctx[model] = ctx
            end
        end
    end

    -- 平铺层的「单次输出预算上限」，解析口径照抄 model_ctx 那一套：行形状
    -- {model, max_output_tokens}，值必须是正整数（缺值或非法值与 model_ctx 同文案家族报错）。
    -- 卡片上的 max_output_tokens 优先，这一层是没有卡片时的兜底读数。对外落到
    -- /v1/models 的 capabilities.max_output_tokens（用户裁定 2026-10-08 由 context_limit 改名）。
    if doc.model_max_output_tokens ~= nil then
        if not CS_LEXICON.is_array(doc.model_max_output_tokens) then
            return nil, "model_max_output_tokens must be an array"
        end
        for _, entry in ipairs(doc.model_max_output_tokens) do
            local model = CS_LEXICON.trim(entry.model)
            if model ~= "" then
                local raw = entry.max_output_tokens
                if raw == nil or raw == JSON_NULL then
                    return nil, string.format("model_max_output_tokens for %s needs a numeric max_output_tokens", model)
                end
                local limit = CS_LEXICON.parse_positive_int(raw)
                if not limit then
                    return nil, string.format("model_max_output_tokens for %s must be greater than zero", model)
                end
                cfg.model_max_output_tokens[model] = limit
            end
        end
    end

    if doc.model_effort ~= nil then
        if not CS_LEXICON.is_array(doc.model_effort) then return nil, "model_effort must be an array" end
        for _, entry in ipairs(doc.model_effort) do
            local model = CS_LEXICON.trim(entry.model)
            local raw = entry.effort
            local trimmed = type(raw) == "string" and CS_LEXICON.trim(raw) or ""
            if model ~= "" and trimmed ~= "" and CS_LEXICON.lower(trimmed) ~= "null" then
                local effort = CS_FACADE.normalize_effort(trimmed)
                if effort == false then
                    return nil, string.format("unknown effort for %s", model)
                end
                cfg.model_effort[model] = effort
            end
        end
    end

    if doc.virtual_models ~= nil then
        if not CS_LEXICON.is_array(doc.virtual_models) then return nil, "virtual_models must be an array" end
        local built, berr = CS_PROFILES.build_profiles(doc.virtual_models, nil, shadow)
        if not built then return nil, berr end
        for alias, profile in pairs(built) do
            cfg.virtual_profiles[alias] = profile
        end
        sync_virtual_view(cfg)
    end

    if doc.upstreams ~= nil then
        local rows, uerr = CS_UPSTREAMS.build_upstreams(rawget(doc, "upstreams"), previous)
        if not rows then return nil, uerr end
        cfg.upstreams = rows
    end

    if doc.policy ~= nil then
        local raw = doc.policy
        if raw == JSON_NULL then
            cfg.policy = nil
        elseif type(raw) == "string" then
            local trimmed = CS_LEXICON.trim(raw)
            if trimmed == "" or CS_LEXICON.lower(trimmed) == "null" then
                cfg.policy = nil
            else
                local name = CS_FACADE.normalize_policy(trimmed)
                if name == false then
                    return nil, string.format("unknown policy: %s (want one of %s)",
                        trimmed, CS_LEXICON.POLICY_NAMES_JOIN)
                end
                cfg.policy = name
            end
        else
            return nil, "policy must be a string or null"
        end
    end

    if doc.model_policies ~= nil then
        if not CS_LEXICON.is_array(doc.model_policies) then return nil, "model_policies must be an array" end
        local built = {}
        for _, entry in ipairs(doc.model_policies) do
            local model = CS_LEXICON.trim(entry.model)
            if model == "" then
                return nil, "every model_policies entry needs a model"
            end
            local raw = entry.policy
            local trimmed = type(raw) == "string" and CS_LEXICON.trim(raw) or ""
            if raw == JSON_NULL or trimmed == "" or CS_LEXICON.lower(trimmed) == "null" then
                -- an explicit null/empty row drops the override (inherit the global)
                goto next_model_policy
            end
            local name = CS_FACADE.normalize_policy(trimmed)
            if name == false then
                return nil, string.format("unknown policy for %s: %s (want one of %s)",
                    model, trimmed, CS_LEXICON.POLICY_NAMES_JOIN)
            end
            built[model] = name
            ::next_model_policy::
        end
        cfg.model_policies = built
    end

    if doc.model_configs ~= nil then
        if not CS_LEXICON.is_array(doc.model_configs) then return nil, "model_configs must be an array" end
        local built = {}
        for _, entry in ipairs(doc.model_configs) do
            local model = CS_LEXICON.trim(entry.model)
            if model == "" then return nil, "every model_configs entry needs a model" end
            local card = new_card()
            local ok, err = merge_model_patch(card, entry)
            if not ok then return nil, err end
            built[model] = card
        end
        cfg.model_configs = built
    end

    -- /v1/models「只广告虚拟入口」开关的磁盘层。三态与缺省纪律：
    --   * 键缺席（含老配置文件）= 「没说」= 保持 nil,让给环境层；
    --   * 显式 null 同上,是 JSON 编辑器里「擦掉这条声明」的写法,不是「关」；
    --   * true / false 都是结论,false 也是「说了要全量广告」,必须压过 env 的 true。
    -- 非布尔的垃圾值按「未知字段拒绝」的老口径报错（同 supports_tool_use 文案家族）：
    -- 这是 /_ui/config 权威面的整表写入口,静默吞掉一个能改变对外广告形状的键,等于让
    -- 操作员以为他打开了开关。
    do
        local raw = rawget(doc, "models_virtual_only")
        if raw ~= nil then
            if raw == JSON_NULL then
                cfg.models_virtual_only = nil
            elseif type(raw) == "boolean" then
                cfg.models_virtual_only = raw
            else
                return nil, "models_virtual_only must be a boolean or null"
            end
        end
    end

    return cfg
end

_M.cfg_from_document = cfg_from_document

_M.snapshot_of = snapshot_of

-- ------------------------------------------------------------ shared storage

-- ------------------------------------------------- 跨子模块直调的原文 local
-- 这些函数在原文里是同文件 local 直调、从未挂在 _M 上；拆开后由调用方直接 require 本表
-- 调用（不经 facade，所以既不是新增导出、也不给单测多开一个可替换点）。
_M.cfg_from_document = cfg_from_document
_M.cfg_from_env = cfg_from_env
_M.effort_pairs = effort_pairs
_M.merge_model_patch = merge_model_patch
_M.new_card = new_card
_M.snapshot_of = snapshot_of
_M.sync_virtual_view = sync_virtual_view

return _M
