-- /v1/models 合成与广告面（自 router.lua 逐字搬来，只调整了 require 接线）。
--
-- P22 模型对象合成（官方四字段 required；扩展字段「操作员声明 > 引擎自报 > 整键
-- 省略」，宁可不报也不猜）、P23 「只广告虚拟入口」开关、P24 models / server_info
-- handler。AGENTS.md 硬规则 9 的三条不可自作主张全在本文件。
-- test/unit/test_models_shape 与 test_models_advertise 按字符串锚点切本文件源码
-- 配桩加载：受限环境表（registry/store/cfg/text_response/json_decode/cjson 由桩
-- 注入），锚点区间内不许新增文件级 local 引用，切片才能原样编译。
local registry = require "resty.luarouter.registry"
local cjson = require "cjson.safe"

local host = require "resty.luarouter.router.host"
local respond = require "resty.luarouter.router.respond"
local inference = require "resty.luarouter.router.inference"

local _M = {}
package.loaded["resty.luarouter.router.models_api"] = _M

local json_decode = cjson.decode
local send_error = respond.send_error
local store = host.store
local cfg = host.cfg
-- 公开面的纯文本应答（router/inference.lua）；切片单测自己往环境表里塞桩版。
local text_response = inference.text_response
--- =================================================================== /v1/models
--
-- 对外模型列表分两层。
--
-- 第一层是 OpenAI 官方 ModelObject：id / object / created / owned_by 四个字段，
-- 四个都是 required。普通模型那支以前漏了 created，属于不合规，这里补齐；
-- 取不到上游读数时统一取 0 表示「未知」，与虚拟入口一直的写法相同，刻意
-- 不塞 ngx.time()——那会让同一条目每次请求产出不同字节，把客户端缓存和
-- 前后对比全打掉。
--
-- 第二层是 capabilities 命名空间，旁边再加三个 effort 键与一个顶层 context_length。
-- 这些都不是官方字段：vLLM、opencodex 这类服务器把它们挂在模型对象上，各家形状还
-- 不一样。收在 capabilities 下面是物理隔离，官方 SDK 只读它认识的四个键；顶层那三个
-- （supports_reasoning_effort / reasoning_effort / reasoning_efforts）沿用
-- opencodex 已经在用的位置，让照它写死的客户端继续照旧读。
-- context_length 两份并存（用户裁定 2026-10-08）：根层一份给直接读顶层的客户端，
-- capabilities.context_length 原样保留，同取一个读数来源，值必然一致。
--
-- 填充纪律：宁可不报，不要猜。数据源优先级固定为
--   操作员 config 声明 > 引擎自报（registry.model_caps）> 整个键省略。
-- 省略是「删键」，不写 null、不写空数组——空数组是一份「一个都不支持」的肯定
-- 答复，而这里要表达的是不知道。
--
-- id 的取值集合与排序不变：registry 的 worker 判定、watcher 的覆盖探针和客户端的
-- 模型选择全按 id 建，动了会连带影响选路。别名遮蔽规则的**方向**已于 2026-10-07 由
-- 用户裁定反转（方案 A）：入口名与真实模型名同名时**入口赢**——列表里 X 恰好一行，
-- id 仍是 X，owned_by 走入口口径，真实那一行不再单独出现。Rust
-- inject_virtual_models 的「真实 worker 保留名字」是旧口径，见该函数的注释。
-- 被遮蔽的那台实例仍在 /workers 里、仍是入口 targets 的落点，只是客户端不能再按这个
-- 名字点名访问它；转发体的 model 也仍是真实引擎名（lr_bound_model，不在本文件）。

--- created 取不到上游读数时的值：0 = 未知，恒定，可缓存。
local MODEL_CREATED_UNKNOWN = 0

--- 正整数读数（与 config_store 的 parse_positive_int 同口径；那边是文件内 local，
--- 不跨文件复用）。把 nil / 负数 / 小数 / 非数字字符串一律挡在对外字段之外。
local function positive_int(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n < 1 or n ~= math.floor(n) then return nil end
    return n
end

local function boolean_or_nil(value)
    if value == true then return true end
    if value == false then return false end
    return nil
end

--- 「这个名字被操作员藏起来了吗」（用户裁定 2026-10-08）——**判定只有一个实现**，
--- 住在 config_store（readers.lua 的 model_is_hidden：卡片 hidden=true 或入口 hidden=true）。
--- 本函数只做「有没有这个读面、答没答得出」的护栏，绝不在此复刻判据：广告与选路两处
--- 一旦各判各的，就是 2026-10-07 那次「一条目被广告却被路由拒服务」故障的翻版。
---
--- 形状纪律：本函数位于 test_models_shape.lua 的**切片区间**内（锚点从
--- MODEL_CREATED_UNKNOWN 起到「The Rust gateway answers」止，那份单测把整段连同这里
--- 一起切出去配桩加载），所以只准用受限环境里有的东西（type / pcall / 入参），
--- 不得新增对区间外 file-local 的引用。
---
--- 三处「答不出来」全部 fail-open 到「可见」（= 今天的逐字节行为）：store 缺席
--- （未装配的 build / 裸单测探针）、reader 缺席（半程发布的旧 build）、pcall 出错。
--- 一个读不出的隐藏声明绝不该把一台在服务的实例从对外面上抹掉 —— 那与 AGENTS.md
--- 硬规则 4 的「读数拿不到就不许摘 worker」是同一个姿态。
---@param store_mod table|nil
---@param name string|nil @ 真实模型名或虚拟入口名
---@return boolean
local function name_hidden(store_mod, name)
    if type(name) ~= "string" or name == "" then return false end
    if type(store_mod) ~= "table" then return false end
    local reader = store_mod.model_is_hidden
    if type(reader) ~= "function" then return false end
    local ok, verdict = pcall(reader, name)
    if not ok then return false end
    return verdict == true
end

local function list_contains(list, value)
    if type(list) ~= "table" then return false end
    for i = 1, #list do
        if list[i] == value then return true end
    end
    return false
end

--- 把任意来源的字符串数组洗成「去重的非空字符串数组」，洗不出东西返回 nil。
--- 刻意不返回空表：空表编码成 []，那是一份肯定答复。
local function clean_string_list(raw)
    if type(raw) ~= "table" then return nil end
    local seen, out = {}, {}
    for i = 1, #raw do
        local v = raw[i]
        if type(v) == "string" and v ~= "" and not seen[v] then
            seen[v] = true
            out[#out + 1] = v
        end
    end
    if #out == 0 then return nil end
    return out
end

--- 引擎侧的能力广告表（model -> caps）。registry 还没有这个 reader（未落地的
--- build、被裁掉的单测探针）时返回 nil，于是所有扩展字段整体省略，输出退回
--- 官方那四个 required 字段。
---@return table|nil
local function model_caps_table()
    if type(registry.model_caps) ~= "function" then return nil end
    local ok, caps = pcall(registry.model_caps)
    if ok and type(caps) == "table" then return caps end
    return nil
end

--- config 快照（操作员声明层）。拿不到（无 config_store、快照解码失败）返回 nil，
--- 声明层整体不参与，剩下引擎自报那一档。
---@return table|nil
local function config_snapshot()
    local store_mod = store()
    if not store_mod or type(store_mod.current) ~= "function" then return nil end
    local ok, current = pcall(store_mod.current)
    if ok and type(current) == "table" then return current end
    return nil
end

--- 操作员声明的单次输出预算上限的正式读法：卡片 max_output_tokens 优先，其次平铺层
--- model_max_output_tokens（用户裁定 2026-10-08：原卡片字段 context_limit 改名为
--- max_output_tokens，唯一去处就是 capabilities.max_output_tokens 的声明层）。它与
--- config_store 的 (card and card.max_output_tokens) or limits[model] 同一口径。
--- 走 current() 而不是新加 reader：本文件已经在用同一份快照，
--- 不值得为这一个读数再开一个导出面。
---@param cfg table|nil
---@param model string
---@return number|nil
local function declared_max_output_tokens(cfg, model)
    if type(cfg) ~= "table" or type(model) ~= "string" or model == "" then return nil end
    local cards = cfg.model_configs
    local card = type(cards) == "table" and cards[model] or nil
    local limit = positive_int(type(card) == "table" and card.max_output_tokens or nil)
    if limit then return limit end
    local flat = cfg.model_max_output_tokens
    return positive_int(type(flat) == "table" and flat[model] or nil)
end

--- 模型作用域的默认档位声明：强制行 model_effort 优先，其次卡片 default_effort。
--- 刻意不看全局 default_effort——「这台引擎的默认档」与「网关的缺省档」不是一回事，
--- 只有前者能单独成为对外声明。
local function model_scoped_effort(cfg, model)
    if type(cfg) ~= "table" or type(model) ~= "string" or model == "" then return nil end
    local forced = cfg.model_effort
    if type(forced) == "table" and type(forced[model]) == "string" and forced[model] ~= "" then
        return forced[model]
    end
    local cards = cfg.model_configs
    local card = type(cards) == "table" and cards[model] or nil
    if type(card) == "table" and type(card.default_effort) == "string"
        and card.default_effort ~= "" then
        return card.default_effort
    end
    return nil
end

--- 网关的全局缺省档位，只用来在引擎给的档位序列里挑一个打 default 标。
local function global_effort(cfg)
    if type(cfg) ~= "table" then return nil end
    local value = cfg.default_effort
    if type(value) == "string" and value ~= "" then return value end
    return nil
end

--- 引擎自报的档位表：唯一的档位来源（它是唯一带 label、并且知道「这台接受哪几档」
--- 的数据）。label 缺省时不造一个 label——编个 "Foo Effort" 就是猜。
local function clean_effort_ladder(raw)
    if type(raw) ~= "table" then return nil end
    local seen, out = {}, {}
    for i = 1, #raw do
        local item = raw[i]
        local value = type(item) == "table" and item.value or nil
        if type(value) == "string" and value ~= "" and not seen[value] then
            seen[value] = true
            local rung = { value = value }
            if type(item.label) == "string" and item.label ~= "" then
                rung.label = item.label
            end
            if item.default == true then rung.default = true end
            out[#out + 1] = rung
        end
    end
    if #out == 0 then return nil end
    return out
end

--- 给档位表打唯一的 default 标：想要的档位优先，其次引擎自己标的那一档。
--- 想要的档位不在引擎给的序列里时不硬塞一个假档位（那会让客户端渲染出一个发过去
--- 就被引擎拒掉的选项），而是回退到引擎自己的标记。
local function apply_default_ladder_rung(ladder, wanted)
    if type(ladder) ~= "table" then return end
    local chosen
    if type(wanted) == "string" then
        for i = 1, #ladder do
            if ladder[i].value == wanted then chosen = wanted break end
        end
    end
    if chosen == nil then
        for i = 1, #ladder do
            if ladder[i].default == true then chosen = ladder[i].value break end
        end
    end
    for i = 1, #ladder do ladder[i].default = nil end
    if chosen then
        for i = 1, #ladder do
            if ladder[i].value == chosen then
                ladder[i].default = true
                break
            end
        end
    end
end

--- 操作员勾选的档位表套到引擎自报的那份上（用户诉求 2026-10-08）。
---
--- 语义是**勾选决定成员、引擎决定描述**：以勾选的集合与顺序为准，每一档的 label 从引擎
--- 那份同名的档位上继承（勾选框只勾名字，把 "Low Effort" 这类引擎原话丢掉，等于让一次
--- 勾选顺手毁掉别的字段）；勾选表里没有的名字照原样出现、不带 label（**不替它编一个**，
--- 硬规则 9 第 2 条）。
---
--- default 的来源是勾选表本身（存储层保证至多一个 true）；勾选表一个 true 都没有时，
--- 才继承引擎标的那一档 —— 前提是那一档仍在勾选集合里。取消缺省档那次勾选因此会把
--- 预选让给引擎仍支持的那一档，而不是让 picker 失去预选。
---@param declared table @ 归一化后的勾选表（数组，可为空）
---@param engine table|nil @ 引擎自报的阶梯
---@return table|nil
local function overlay_effort_ladder(declared, engine)
    if type(declared) ~= "table" then return nil end
    if #declared == 0 then return {} end
    local by_name
    if type(engine) == "table" then
        by_name = {}
        for i = 1, #engine do
            local rung = engine[i]
            if type(rung) == "table" and type(rung.value) == "string" then
                by_name[rung.value:lower()] = rung
            end
        end
    end
    local out, seen, any_default = {}, {}, false
    for i = 1, #declared do
        local want = declared[i]
        local value = type(want) == "table" and want.value or nil
        if type(value) == "string" and value ~= "" then
            local key = value:lower()
            if not seen[key] then
                seen[key] = true
                local rung = { value = value }
                local source = by_name and by_name[key] or nil
                if source and type(source.label) == "string" and source.label ~= "" then
                    rung.label = source.label
                end
                if want["default"] == true then
                    rung["default"] = true
                    any_default = true
                end
                out[#out + 1] = rung
            end
        end
    end
    if #out == 0 then return {} end
    if not any_default and by_name then
        for i = 1, #out do
            local source = by_name[out[i].value:lower()]
            if source and source["default"] == true then
                out[i]["default"] = true
                break
            end
        end
    end
    return out
end

local function ladder_values(ladder)
    if type(ladder) ~= "table" then return nil end
    local out = {}
    for i = 1, #ladder do out[i] = ladder[i].value end
    if #out == 0 then return nil end
    return out
end

--- 卡片上操作员勾选的档位表（config 声明层，用户诉求 2026-10-08）。存的时候已经过
--- config_store 归一化：值一定在词表里、顺序即勾选顺序、至多一枚 default，且空数组在写入时
--- 就被折成「没说」（merge_model_patch）。所以这里的 nil 有三种来源，且都是同一句话
--- 「这一维让位引擎自报」：没有这张卡、键沉默、以及手改进磁盘的 [] ——最后一种不报空 []
--- 而是退回引擎，与旁边的 clean_string_list / clean_effort_ladder 同一条填充纪律（[] 是一份
--- 「一个都不支持」的肯定答复，而这里没有任何肯定可报）。
---@param card table|nil
---@return table|nil
local function card_ladder(card)
    if type(card) ~= "table" then return nil end
    local raw = card.reasoning_efforts
    if type(raw) ~= "table" then return nil end
    local out, seen = {}, {}
    for i = 1, #raw do
        local rung = raw[i]
        local value = type(rung) == "table" and rung.value or nil
        if type(value) == "string" and value ~= "" and not seen[value:lower()] then
            seen[value:lower()] = true
            out[#out + 1] = { value = value, ["default"] = rung["default"] == true }
        end
    end
    if #out == 0 then return nil end
    return out
end

--- 判定面的交集：在引擎说过接受的那份里，只留操作员还留着的档位（顺序按引擎那份）。
--- engine_face 为 nil（引擎没说判定面）时退到操作员那份序列 —— 与旁边「退到阶梯序列」
--- 同一支路。洗空返回 nil = 删键，报 [] 等于宣称整组什么都收不了。
---@param engine_face table|nil
---@param kept table|nil
---@return table|nil
local function intersect_strings(engine_face, kept)
    if type(engine_face) ~= "table" then return kept end
    if type(kept) ~= "table" then return engine_face end
    local out = {}
    for i = 1, #engine_face do
        if list_contains(kept, engine_face[i]) then out[#out + 1] = engine_face[i] end
    end
    if #out == 0 then return nil end
    return out
end

--- 勾选表里被操作员标为缺省的那一档（至多一个，存储层保证）。没有则 nil。
---@param ladder table
---@return string|nil
local function card_default_rung(ladder)
    if type(ladder) ~= "table" then return nil end
    for i = 1, #ladder do
        if ladder[i]["default"] == true then return ladder[i].value end
    end
    return nil
end

--- 单个**实际模型**的一行能力读数：操作员声明与引擎自报按优先级合成后的样子。
--- 每个维度独立取源，所以「操作员只声明了模态」不会连带把引擎报的上下文丢掉。
---@param entry_declared table|nil 虚拟条目那一层的声明（卡片没说的位由它接手）；真实模型那一行传 nil
local function resolve_model_caps(store_mod, cfg, model, caps, entry_declared)
    local row = {}
    local declared_ctx
    if store_mod and type(store_mod.ctx_cap) == "function" then
        local ok, value = pcall(store_mod.ctx_cap, model)
        if ok then declared_ctx = positive_int(value) end
    end
    -- context_length 只由两档决定：操作员在卡片/平铺层声明的 ctx（store 的 ctx_cap），
    -- 否则引擎自报（用户裁定 2026-10-08：原 declared_context_limit 一环删除——
    -- 卡片的 max_output_tokens 是输出预算读数，不再冒充上下文总窗口）。
    row.length = declared_ctx or positive_int(caps and caps.context_length)
    -- 输出预算声明层优先：操作员声明（卡片 > 平铺）压过引擎自报。
    row.max_output_tokens = declared_max_output_tokens(cfg, model)
        or positive_int(caps and caps.max_output_tokens)

    -- 模态有两个来源，且**穷尽性不同**，因此对 supports_vision 的话语权也不同：
    --   * 操作员卡片的 modalities 是穷尽列表（config_store 的写入路径把 text 常开，
    --     空列表也写成 { "text" }），所以「列表里没有 image」就是操作员说了不收图；
    --   * 引擎自报的 input_modalities 不保证穷尽——少写一列很常见，据此反推
    --     supports_vision=false 是替上游编话（registry 的规范化层同此理由，见
    --     model_caps_from_entry 的「刻意不从 input_modalities 反推 vision」）。
    -- 所以引擎那侧只允许反推**正向**（列了 image/video 就是收），负向只在操作员声明时给。
    local input, output, input_declared
    if store_mod and type(store_mod.modalities_for) == "function" then
        local ok, value = pcall(store_mod.modalities_for, model)
        input = clean_string_list(value)
        input_declared = input ~= nil
    end
    local modalities = type(caps) == "table" and caps.modalities or nil
    if type(modalities) == "table" then
        if input == nil then input = clean_string_list(modalities.input) end
        output = clean_string_list(modalities.output)
    end
    row.input, row.output = input, output

    local supports = type(caps) == "table" and caps.supports or nil
    supports = type(supports) == "table" and supports or {}

    -- ── 能力位的源优先级（五个字段一条链，硬规则 9 第 2 条）──
    -- 模型卡片声明 > 虚拟条目声明 > 引擎自报 > 整个键省略。卡片压过条目与 effort
    -- 三层继承（卡片 → 条目 → 全局）同一条纪律：离引擎越近的读数越先说话。
    -- tool use 早在上一轮就接了 config 这一层；streaming / reasoning / vision /
    -- reasoning_effort 当时只剩引擎自报一条来源，等于把「操作员说不支持」这一格整个
    -- 让给了引擎：引擎的 supports_tool_use 按它自己的 chat template 报，挂了工具模板的
    -- 引擎恒报 true，而操作员没有任何办法否掉它（用户诉求 2026-10-05：UI 要能配，
    -- 并且反映到 /v1/models 的对外声明）。
    --
    -- 三态必须逐分支判，不能写成 declared or engine：Lua 里 `false or engine` 取的是
    -- engine，操作员明确说的「不支持」会被引擎的 true 顶掉，正是这一支要防的缺陷
    -- （旁边 tool use 的注释把同一个坑写在了那里）。nil 才是没说话，只有那一支才让位；
    -- 两边都没说话则保持 nil，由 fill_model_fields 把整个键删掉（不写 false、
    -- 不写 null 冒充结论）。
    local card = nil
    if type(cfg) == "table" and type(cfg.model_configs) == "table" then
        local maybe = cfg.model_configs[model]
        if type(maybe) == "table" then card = maybe end
    end

    --- 一个能力位在这台模型上的声明层读数：卡片先说，条目随后，都没说才 nil（=沉默）。
    --- 刻意不看 `card[field] == false` 之类的一元判定：false 是结论、nil 是沉默，
    --- 两者在这里必须走两条不同的支路，任何「falsy 合并」都会把「不支持」降格成「不知道」。
    ---
    --- 条目那一层覆盖本轮补齐的四位，唯独 supports_tool_use 不在其中：它比这四位早上线，
    --- 条目层那一份当时的口径是「只登记、不改变对外读数」（i18n 的 virtualToolHint 与
    --- doc 都按这句钉着），本轮的诉求是那四位可配，不是重订这一位的既有条目层语义。
    --- 写成 field ~= "supports_tool_use" 而不是一张白名单表：后者每次调用都要新分配一张表，
    --- 而这里的判定是每模型每请求都走的。
    local function declared(field)
        if card ~= nil then
            local value = boolean_or_nil(card[field])
            if value ~= nil then return value end
        end
        if field ~= "supports_tool_use" and type(entry_declared) == "table" then
            return boolean_or_nil(entry_declared[field])
        end
        return nil
    end

    --- 引擎自报那一档（已经洗成真布尔或 nil）。
    local function resolve(field, engine_value)
        local value = declared(field)
        if value ~= nil then return value end
        return engine_value
    end

    -- tool use 走它既有的专属 reader（先于本轮上线、读数面已被单测钉住），条目层不参与。
    local declared_tool_use
    if store_mod and type(store_mod.card_supports_tool_use) == "function" then
        local ok_tool, tool_value = pcall(store_mod.card_supports_tool_use, model)
        if ok_tool then declared_tool_use = boolean_or_nil(tool_value) end
    end
    if declared_tool_use == nil and card ~= nil then
        declared_tool_use = boolean_or_nil(card.supports_tool_use)
    end
    if declared_tool_use ~= nil then
        row.tool_use = declared_tool_use
    else
        row.tool_use = boolean_or_nil(supports.tool_use)
    end
    row.streaming = resolve("supports_streaming", boolean_or_nil(supports.streaming))
    row.reasoning = resolve("supports_reasoning", boolean_or_nil(supports.reasoning))
    -- vision 的「引擎自报」那一档比旁边两位多一层：卡片 modalities 是**穷尽**声明，
    -- 所以能从「列没列 image/video」正负反推；引擎自报的 input_modalities 不保证穷尽，
    -- 只允许反推正向（registry 的规范化层同此理由，见 model_caps_from_entry）。
    -- 显式的 supports_vision 声明压过这一切（它是操作员就这个位本身说的话）。
    row.vision = resolve("supports_vision", boolean_or_nil(supports.vision))
    if row.vision == nil and type(input) == "table" then
        local sees_media = list_contains(input, "image") or list_contains(input, "video")
        if sees_media then
            row.vision = true
        elseif input_declared then
            row.vision = false
        end
    end

    -- 档位在上游有**两种拼写、两个含义**，registry 刻意各留一份，这里也必须各画各的：
    --   caps.reasoning_efforts        客户端 picker 的可选项（带 label / default）
    --   caps.reasoning_effort_values  下游真正**接受**的档位判定面
    -- 把判定面抄成阶梯是过度声称：引擎可能只接受 low/high/max，而 picker 里有 medium。
    -- 所以判定面优先用引擎亲口给的那份，只有它缺席时才退到阶梯序列。
    --
    -- 操作员在卡片上勾过档位表时（reasoning_efforts，用户诉求 2026-10-08），它接管这一行的
    -- 两份读数：picker 就是勾选表（label 仍从引擎那份同名档位继承，不替引擎编话），判定面
    -- 取「勾选 ∩ 引擎判定面」。交集不是虚构——它是把引擎说过的事情**少报**一件，与旁边
    -- 「组内取最窄」「宁可删键」同方向；反过来，勾选表里引擎从没提过的名字（手动补的 xhigh）
    -- 只进 picker、**不进判定面**，否则就是替引擎宣称它接受一个它没说过的名字。
    local engine_ladder = clean_effort_ladder(caps and caps.reasoning_efforts)
    local chosen_ladder = card_ladder(card)
    local ladder = chosen_ladder and overlay_effort_ladder(chosen_ladder, engine_ladder)
        or engine_ladder
    local declared_default = type(caps) == "table" and caps.reasoning_effort or nil
    if type(declared_default) ~= "string" or declared_default == "" then
        declared_default = nil
    end
    if ladder then
        apply_default_ladder_rung(ladder,
            -- 缺省档的定序（模型作用域 > 全局 > 操作员的勾选标记 > 引擎自报字符串 > 阶梯自己
            -- 的标记）：勾选表上那枚 default 是**模型作用域**的操作员声明，压过全局缺省档；
            -- 但让位给 default_effort / model_effort 这两条专职字段——它们就是为「哪档预选」
            -- 这个具体问题而存在的，同一条陈述里专职字段赢。引擎那份的标记排在最后（由
            -- overlay 继承进 ladder，再走 apply_default_ladder_rung 的兜底支）。
            model_scoped_effort(cfg, model) or global_effort(cfg)
            or (chosen_ladder and card_default_rung(chosen_ladder) or nil)
            or declared_default)
        for i = 1, #ladder do
            if ladder[i].default == true then
                row.default_effort = ladder[i].value
                break
            end
        end
        row.ladder = ladder
    elseif declared_default then
        -- 只有缺省档、没有阶梯：引擎确实说了默认用哪档，照报；但客户端无从枚举。
        row.default_effort = declared_default
    end
    -- 判定面的来源次序照旧是「引擎亲口给的那份优先」，只在操作员勾过时再与勾选表求交；
    -- 引擎压根没给判定面时才退到（可能被勾选表替换过的）阶梯序列。
    local engine_face = clean_string_list(caps and caps.reasoning_effort_values)
    if chosen_ladder then
        row.accepted = intersect_strings(engine_face, ladder_values(ladder))
    else
        row.accepted = engine_face or ladder_values(ladder)
    end
    -- 顶层 supports_reasoning_effort 的声明层读数（卡片 → 条目）。它是一位**独立**的
    -- 对外说法，不是「有没有档位读数」那个派生的别名：派生只在两边都没说时才起作用
    -- （见 fill_model_fields，那条派生链的行为逐字节不变，包括它什么时候省略这个键）。
    row.declared_effort_support = declared("supports_reasoning_effort")
    return row
end

local function same_values(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

--- 组内共同的支持列表：每台都必须给出读数，取它们的交集；交集为空也删键（报 []
--- 等于宣称整组什么都收不了，而真实情况是「这几台的说法不一致」）。
local function common_string_list(rows, key)
    local first
    for i = 1, #rows do
        local list = rows[i][key]
        if type(list) ~= "table" then return nil end
        if first == nil then first = list end
    end
    if first == nil then return nil end
    local out = {}
    for i = 1, #first do
        local value = first[i]
        local shared = true
        for j = 1, #rows do
            if not list_contains(rows[j][key], value) then shared = false break end
        end
        if shared then out[#out + 1] = value end
    end
    if #out == 0 then return nil end
    return out
end

--- 组内最窄数值读数：和另外四个兄弟聚合函数同一条纪律——**组里有任何一台没开口，
--- 整个键就删**（返回 nil），绝不在「给出读数的成员里」取最窄。
---
--- 为什么不能只比开了口的那几台（2026-10-04 的线上缺陷）：入口对外广告的窗口是客户端
--- 决定塞多少 token 的依据，而请求会被策略派给组内**任意一台**。一台没有读数意味着
--- 「网关不知道那台引擎装得下多少」，而不是「那台装得下且更宽」。跳过它去报已知读数里
--- 的最窄值，等于替一台不知底细的引擎担保了一个可能大于它上限的数——生产 235.t:8800
--- 的 Qn 入口就是这么拿着 kimi 的 1000000 对外广告的，而组里 Q38-Flash-Next 那一半
--- 当时一个长度读数都没有，客户端照 1000000 塞，请求落到那台就炸。
--- 宁可不报（客户端退回自己的保守值）也不报一个能让请求失败的数。
---
--- 与 config_store.virtual_ctx_cap **不是一回事**，别再拿它当口径依据：那里判的是
--- **操作员声明**之间的冲突（每台都给了声明值、只是数值不一致），本函数判的是
--- **引擎能力未知**。「知道它装得下但更窄」与「不知道它装得下多少」是两个不同的事实：
--- 前者取最窄，后者删键。
---
--- 例外只在调用点：入口自己显式声明的 context_window 是操作员说的话，压过这里的一切
--- （advertise_virtual_entry 里 length 那条 or 链的前半段），不会因为组内不齐被抹掉。
--- 本函数只管派生路径。
local function narrowest_number(rows, key)
    local best
    for i = 1, #rows do
        local value = rows[i][key]
        if type(value) ~= "number" then return nil end
        if best == nil or value < best then best = value end
    end
    return best
end

--- 组内一致的支持位：每台都报 true 才是 true，有一台 false 就是 false，
--- 有任何一台没报则删键。
local function common_boolean(rows, key)
    local all_true = true
    for i = 1, #rows do
        local value = rows[i][key]
        if value == nil then return nil end
        if value ~= true then all_true = false end
    end
    return all_true
end

--- 组内共同档位表：只有每台引擎给的档位**序列完全一致**才照抄对外报。
--- 序列不一致时删键——把两台并起来会造出一个「在另一台上会被拒」的选项。
local function common_ladder(rows)
    local first
    for i = 1, #rows do
        local ladder = rows[i].ladder
        if type(ladder) ~= "table" then return nil end
        if first == nil then
            first = ladder
        elseif not same_values(ladder_values(first), ladder_values(ladder)) then
            return nil
        end
    end
    if first == nil then return nil end
    local out = {}
    for i = 1, #first do
        local rung = { value = first[i].value }
        if type(first[i].label) == "string" then rung.label = first[i].label end
        if first[i].default == true then rung.default = true end
        out[i] = rung
    end
    return out
end

--- 组内一致的字符串读数（默认档位用）：任何一台没报或说法不一律删键。
local function common_string(rows, key)
    local value
    for i = 1, #rows do
        local one = rows[i][key]
        if type(one) ~= "string" then return nil end
        if value == nil then value = one end
        if one ~= value then return nil end
    end
    return value
end

--- 组内共同的可接受档位：按成员顺序取**交集**——交集里的每一档是每台都说过接受的，
--- picker（阶梯）刻意不作门槛：两台可以给出不同阶梯却给出可交集的判定面。
--- 所以既不虚构也不误报（与组内上下文取最窄同一个安全理由）。交集为空则删键。
--- 交集把阶梯的缺省档挤掉时也删键：判定面里没有缺省档，和旁边画着它的 picker 自相
--- 矛盾，这种不一致说明组内口径本来就不齐，宁可不报。
local function common_acceptance(rows, default_effort)
    local first
    for i = 1, #rows do
        local list = rows[i].accepted
        if type(list) ~= "table" then return nil end
        if first == nil then first = list end
    end
    if first == nil then return nil end
    -- 组只有一个成员时，入口**就是**那台引擎：没有任何「组内口径不齐」要仲裁，
    -- 上游自己给的缺省档与判定面之间的矛盾照原样透传。少了这一支，同一个模型会在
    -- 它的真实模型行上报出判定面、却在指向它的单目标入口行上不报——两行说的本来就是
    -- 同一台引擎，客户端会读成两种能力。
    if #rows == 1 then
        local only = {}
        for i = 1, #first do only[i] = first[i] end
        return only
    end
    local out = {}
    for i = 1, #first do
        local value = first[i]
        local shared = true
        for j = 1, #rows do
            if not list_contains(rows[j].accepted, value) then shared = false break end
        end
        if shared then out[#out + 1] = value end
    end
    if #out == 0 then return nil end
    if type(default_effort) == "string" and not list_contains(out, default_effort) then
        return nil
    end
    return out
end

--- 把一行能力读数摊到响应条目上：顶层三个 opencodex 键 + capabilities 命名空间，
--- 外加一个顶层 context_length。整行没有任何读数时什么都不加，条目回退成官方那四个
--- required 字段。
--- context_length 两份并存（用户裁定 2026-10-08）：模型对象根层与 capabilities 内各一份，
--- 同取 row.length，值必然一致。根层那份是给直接读顶层的客户端用的，capabilities 内那份
--- 保持既有命名空间口径不动。
local function fill_model_fields(entry, row)
    -- 顶层 supports_reasoning_effort：操作员声明（卡片 → 条目）优先，未声明时维持**原有
    -- 派生**——任一份档位读数（可选项、判定面、缺省档）都足以支撑「这台接受
    -- reasoning_effort」，没有读数则整个键省略。派生这一支的行为逐字节不变（2026-10-05
    -- 只是把三态的「明确说不支持」接到它前面），所以声明 false 时档位表与缺省档照旧
    -- 出现在条目上：操作员否掉的是那一位对外声明，不是引擎给过的档位事实。
    local effort_support = boolean_or_nil(row.declared_effort_support)
    if effort_support == nil then
        if row.ladder or row.accepted or row.default_effort then
            effort_support = true
        end
    end
    if effort_support ~= nil then
        entry.supports_reasoning_effort = effort_support
    end
    -- default_effort 在场时旧版必定进入上面那个 if（它是派生条件之一），所以把它挪到
    -- 分支外是字节等价的——这个"分支外提"不改变任何未声明场景的输出。
    if row.default_effort then entry.reasoning_effort = row.default_effort end
    if row.ladder then
        entry.reasoning_efforts = row.ladder
    end
    local out = {}
    if row.length then out.context_length = row.length end
    -- 根层副本：与 capabilities.context_length 同一来源（row.length），两份并存。
    if row.length then entry.context_length = row.length end
    if row.max_output_tokens then out.max_output_tokens = row.max_output_tokens end
    if row.input then out.input_modalities = row.input end
    if row.output then out.output_modalities = row.output end
    if row.tool_use ~= nil then out.supports_tool_use = row.tool_use end
    if row.streaming ~= nil then out.supports_streaming = row.streaming end
    if row.reasoning ~= nil then out.supports_reasoning = row.reasoning end
    if row.vision ~= nil then out.supports_vision = row.vision end
    if row.accepted then out.reasoning_effort = row.accepted end
    if next(out) ~= nil then entry.capabilities = out end
end

--- 真实模型那一行。owned_by 的口径保持不动（本仓所有 worker 都是操作员自己起的
--- 实例 = "local"）：引擎自报的 owned_by 是各家上游的说法，而有客户端在按 "local"
--- 判「这是我方实例」。
local function advertise_real_model(store_mod, cfg, caps_by_model, model)
    local caps = type(caps_by_model) == "table" and caps_by_model[model] or nil
    local entry = {
        id = model,
        object = "model",
        created = positive_int(caps and caps.created) or MODEL_CREATED_UNKNOWN,
        owned_by = "local",
    }
    fill_model_fields(entry, resolve_model_caps(store_mod, cfg, model, caps))
    return entry
end

--- 虚拟入口那一行：入口本身没有引擎，能力一律从组内的**实际模型**聚合，并且只在
--- 整组口径一致时才对外声明（与 virtual_ctx_cap「一组由该入口不控制的引擎提供服务」
--- 同一个安全理由）。created 恒 0：多台引擎的 created 取最小或取第一个都没有意义，
--- 0 是入口一直的写法。
---
--- 对外声明的上下文优先取条目自己写的 context_window（那是入口对外的总窗口，
--- 作用只是让客户端更早触发压缩，不参与任何 max_tokens 计算），其次才是组内
--- 各实际模型能力的最小值 —— 而且**组里有任何一台没给读数时连最小值也不报**，
--- 整键删掉（见 narrowest_number；2026-10-04 线上缺陷：入口拿着有读数那一半的
--- 1000000 对外广告，而另一半当时一个长度读数都没有）。操作员显式声明的那份不受影响。
---
--- 条目级的 effort / policy 依然不读（2026-10-02 裁定：停用期间「字段仍被接受、
--- 仍往返落盘、解析时 warn、热路径不读」是刻意行为）。对外默认档位由组内成员
--- 一致的说法给出，与转发链同口径，避免出现「面板显示 medium、转发实际别的档」。
local function advertise_virtual_entry(store_mod, cfg, caps_by_model, alias, tail)
    local profile
    if store_mod and type(store_mod.profile_for) == "function" then
        local ok, value = pcall(store_mod.profile_for, alias)
        if ok and type(value) == "table" then profile = value end
    end
    local rows = {}
    -- 条目层的四个能力位声明作为声明链的中间一档传进每个成员：卡片（离引擎最近）先说，
    -- 卡片没说才轮到条目，两边都沉默才让给引擎自报。profile_for 已经把这几位拷在 profile
    -- 上（与 supports_tool_use 同一条热路径拷贝），所以这里不必再回 store 查一次。
    for i = 1, #tail do
        local caps = type(caps_by_model) == "table" and caps_by_model[tail[i]] or nil
        rows[i] = resolve_model_caps(store_mod, cfg, tail[i], caps, profile)
    end
    local entry = {
        id = alias,
        object = "model",
        created = MODEL_CREATED_UNKNOWN,
    }
    if #tail == 1 then
        -- One model behind the entry: exactly the pre-group answer, byte for byte, so
        -- clients (and the contract) that read owned_by as "which engine this alias
        -- stands for" keep working for legacy rows.
        entry.owned_by = "llm-router->" .. tail[1]
    else
        -- A real group: the gateway owns the entry and the models behind it belong to
        -- whichever engines serve them. Naming one of them would advertise the entry as
        -- that single model's alias again, which is the semantics that just got
        -- retired; the full list rides a separate field so the pinned OpenAI-shaped
        -- owned_by keeps its old meaning.
        entry.owned_by = "llm-router"
        entry.owned_by_models = tail
    end
    -- 组内**声明层**的 supports_reasoning_effort 共识，与普通位用的 common_boolean 差一支：
    -- 任何一台明确说 false 就是 false（操作员关掉了这一位，必须关得住，不能被别的成员的
    -- 沉默拖成「没人说话」）；要给出 true 则每台都得亲口说 true（与 common_boolean 同样
    -- 保守，绝不替沉默的成员担保）；两种都不成立才答 nil，让调用点退回**原有派生**
    -- （组内有没有档位读数）。不能直接用 common_boolean：那里 nil 意味着「删键」，而这里
    -- 的 nil 意味着「回到派生」，语义不同，硬套会把操作员的 false 悄悄洗掉。
    -- 写成局部闭包而不是顶层 local：本文件的主函数局部槽位离 LuaJIT 的 200 上限只差
    -- 一个（同 models_advertise 那节的说明），读者只在这一处需要它。
    local function common_declared_effort_support(rows)
        local any_false, all_true = false, #rows > 0
        for i = 1, #rows do
            local value = rows[i].declared_effort_support
            if value == false then any_false = true end
            if value ~= true then all_true = false end
        end
        if any_false then return false end
        if all_true then return true end
        return nil
    end

    local ladder = common_ladder(rows)
    local default_effort
    if ladder then
        apply_default_ladder_rung(ladder, common_string(rows, "default_effort"))
        for i = 1, #ladder do
            if ladder[i].default == true then
                default_effort = ladder[i].value
                break
            end
        end
    end
    fill_model_fields(entry, {
        length = (profile and positive_int(profile.context_window) or nil)
            or narrowest_number(rows, "length"),
        max_output_tokens = narrowest_number(rows, "max_output_tokens"),
        input = common_string_list(rows, "input"),
        output = common_string_list(rows, "output"),
        tool_use = common_boolean(rows, "tool_use"),
        streaming = common_boolean(rows, "streaming"),
        reasoning = common_boolean(rows, "reasoning"),
        vision = common_boolean(rows, "vision"),
        declared_effort_support = common_declared_effort_support(rows),
        ladder = ladder,
        accepted = common_acceptance(rows, default_effort),
        default_effort = default_effort,
    })
    return entry
end

-- ------------------------------------------------ /v1/models 的广告面开关
--
-- 用户诉求（2026-10-04）：这台网关对外只暴露虚拟入口，不要把本地真实模型直接透出。
-- 做成配置开关且缺省关：data[].id 的取值集合是 AGENTS.md 硬规则 9 第三条钉住的老契约
-- （registry 的 worker 判定、watcher 的覆盖探针、客户端的模型选择全按 id 建），改缺省
-- 会直接打断按真实模型名直连的客户端。要只透出入口由操作员在配置里打开。
--
-- 语义严格限定为「只广告虚拟入口」这一件事：真实模型仍然可路由、仍在 /workers 里、
-- 仍然是入口 targets 的被调度对象。推理路径与 /workers 一个字节都不因它改变。
--
-- 读数两层，与 config_store 的优先级一致：磁盘快照（LMR_CONFIG_FILE）里的
-- models_virtual_only 优先，其次环境变量 LMR_MODELS_VIRTUAL_ONLY，两边都没说过
-- 才是关（= 改动前的输出逐字节一致）。
--
-- 为什么这里自己读磁盘原文而不是走 config_store.current()：那个键它不认识，
-- snapshot_of 的字段表是封闭的，走 current() 只会永远读到 nil，操作员在配置文件里
-- 写什么都没用。代价如实写在这里：从 /_ui/config 保存一次会把它抹掉（apply_document
-- 重生成快照时不留未知键），所以这个开关的正式落点是 config_store 的三条线
-- （ENV_NAMES 加名、cfg_from_document 认这个键、snapshot_of 回写它）加管理台一个
-- 开关位，那三处由改 config_store 与 UI 的人一并收掉。
--
-- 整块收进一个表：本文件的主函数局部槽位离 LuaJIT 的 200 上限只剩 2 个（实测加第 3
-- 个顶层 local 就编不过），所以这里的常量、缓存与函数一律做成表字段，整块只占一个
-- 槽位。想在这一节加第二个顶层 local 的人请先把它塞回本表。
local models_advertise = {
    env_key = "LMR_MODELS_VIRTUAL_ONLY",
    doc_key = "models_virtual_only",
    ttl_s = 0.5,      -- 与 config_store 的 SNAPSHOT_TTL 同一档：热配置允许的陈旧度
    on = false,       -- 缓存的读数
    at = 0,           -- 上次读盘时刻（仅在有毫秒时钟时使用）
}

--- 真值判定，与 props.router_mode 同一族：认 true/1/yes/on，其余一律 false。
--- 刻意「不认识即关」而不是「非假即真」：一个写错的字符串该退回缺省行为，
--- 而不是把硬规则 9 第三条的老契约整页翻掉。
function models_advertise.truthy(value)
    if value == true then return true end
    if type(value) ~= "string" then return false end
    local v = value:match("^%s*(.-)%s*$"):lower()
    return v == "true" or v == "1" or v == "yes" or v == "on"
end

--- cjson 的 null 与 Lua nil 分家。走 type(cjson) 守卫而不是裸索引：本块会被
--- test/unit/test_models_shape.lua 连同 models_handler 一起切出去配桩加载，
--- 那个受限环境里没有 cjson 这个 local。
function models_advertise.nullish(value)
    if value == nil then return true end
    if type(cjson) == "table" and value == cjson.null then return true end
    return false
end

--- 环境层读数：先 config_store.env（它会查 init_by_lua 抓的进程级快照），
--- 再 os.getenv（裸跑单测，以及 conf 的 env 白名单还没放行时的兜底）。
function models_advertise.from_env(store_mod)
    local raw
    if store_mod and type(store_mod.env) == "function" then
        local ok_env, value = pcall(store_mod.env, models_advertise.env_key)
        if ok_env then raw = value end
    end
    if raw == nil and type(os) == "table" and type(os.getenv) == "function" then
        raw = os.getenv(models_advertise.env_key)
    end
    return models_advertise.truthy(raw)
end

--- 磁盘快照里操作员声明的那一份。任何一步不成立都答 nil = 「他没说」，于是让给
--- 环境层。nil 与 false 必须分家：false 是「说了要全量广告」，是压过 env 的结论，
--- nil 只是沉默（与硬规则 9 第二条同一套三态纪律）。
---@param store_mod table|nil
---@return boolean|nil
function models_advertise.from_disk(store_mod)
    local path
    if store_mod and type(store_mod.env) == "function" then
        local ok_env, value = pcall(store_mod.env, "LMR_CONFIG_FILE")
        if ok_env and type(value) == "string" and value ~= "" then path = value end
    end
    if path == nil and type(os) == "table" and type(os.getenv) == "function" then
        local value = os.getenv("LMR_CONFIG_FILE")
        if type(value) == "string" and value ~= "" then path = value end
    end
    if path == nil then return nil end
    if type(io) ~= "table" or type(io.open) ~= "function" then return nil end
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local text = handle:read("*a")
    handle:close()
    if type(text) ~= "string" or text == "" then return nil end
    -- json_decode 是文件顶上的 local，切片单测把它连同本节一起切出去配桩加载时它不在
    -- 环境表里（那里给的是 type/pcall/string/table 这一族），于是它在这里是全局 nil。
    -- 与上面的 io 同纪律：先验可用，不可用就当「磁盘层没说」，让判定退回环境层。
    if type(json_decode) ~= "function" then return nil end
    local ok_json, doc = pcall(json_decode, text)
    if not ok_json or type(doc) ~= "table" then return nil end
    local raw = rawget(doc, models_advertise.doc_key)
    if models_advertise.nullish(raw) then return nil end
    return models_advertise.truthy(raw)
end

--- 开关读数。缓存只在有毫秒时钟（ngx.now）时启用：缺了它只能退回秒级 os.time，
--- 于是「同一秒内改了配置」会读到上一秒的值，在单测里那会让判定自我怀疑（改了开关
--- 却看不出变化，还被当成开关不生效）。宁可不缓存也不给判定掺陈旧值——这条路径只有
--- /v1/models 一处读者，量级上撑不起缓存的收益。
---@param store_mod table|nil
---@return boolean
function models_advertise.enabled(store_mod)
    local now
    if type(ngx) == "table" and type(ngx.now) == "function" then
        now = ngx.now()
    end
    if now ~= nil then
        if models_advertise.at > 0
            and (now - models_advertise.at) < models_advertise.ttl_s then
            return models_advertise.on
        end
    end
    local decided = models_advertise.from_disk(store_mod)
    if decided == nil then decided = models_advertise.from_env(store_mod) end
    decided = decided and true or false
    if now ~= nil then
        models_advertise.at = now
        models_advertise.on = decided
    end
    return decided
end

--- 只有入口的那份 data[]。一个入口一行，绝不静默少一条（少一条等于让客户端以为
--- 这个服务不存在）：本分支压根不装配真实那一半，所以 2026-10-07 反转后的遮蔽规则
--- （入口名遮蔽同名实际模型）在这里没有对手——真实行一条都不出，某个名字是否同时
--- 是入口，对结果没有影响，因此这里刻意不做遮蔽判定，配了几条入口就出几条。开关
--- 两种状态对同名给的是同一个答案：开=只出入口行；关=出入口行、摘掉真实行（见
--- inject_virtual_models）。重复别名照样去重（同一个 id 出两行会打断按 id 建索引的
--- 客户端），保留的是列表里第一条——store 侧按别名排序，哪条在前是确定的。
--- 返回 nil = 一份入口都拿不到（store 缺席 / reader 没落地 / 配置里根本没有入口），
--- 调用方据此退回全量广告并如实报一行日志。
--- capabilities 的聚合口径完全走 advertise_virtual_entry 原样，开关不参与。
---@param store_mod table|nil
---@param cfg table|nil
---@param caps_by_model table|nil
---@return table[]|nil data
function models_advertise.only_data(store_mod, cfg, caps_by_model)
    if not store_mod or type(store_mod.virtual_models_list) ~= "function" then
        return nil
    end
    local ok_list, aliases = pcall(store_mod.virtual_models_list)
    if not ok_list or type(aliases) ~= "table" or #aliases == 0 then
        return nil
    end
    local data, seen = {}, {}
    for i = 1, #aliases do
        local row = aliases[i]
        if type(row) == "table" then
            local alias = row[1]
            if type(alias) == "string" and alias ~= "" and not seen[alias] then
                seen[alias] = true
                -- 「隐藏」（用户裁定 2026-10-08）：藏起来的入口不产出条目，**在装配之前**就跳过
                -- 而不是产出一条再丢掉 —— 「不广告」与「不服务」必须是同一个决定的两面（这里、
                -- 候选门、watcher 读的是 config_store 那同一份判定）。去重照旧先占位（seen[alias]）：
                -- 一个被藏起来的名字同时也被从对外抹掉，不该再让同名的第二条入口顶上来冒充它。
                -- 「开关开着而一条出入口」的既有退回全量 + WARN 分支不因此改变：全部入口都被藏
                -- 时这里返回 nil，走的是老空配置那条路（WARN 说清「入口一条都没有」），而退回后
                -- 那份全量广告里的真实行仍各自过 model_is_hidden（下面 models_handler 那一圈）。
                -- 本节的切片纪律（同 models_advertise.from_disk 对 json_decode / io 的处理）：
                -- test_models_advertise 只把 models_advertise 这一块切出去配桩加载，那份受限
                -- 环境表里没有 name_hidden 这个 local（它在锚点区间**之上**），于是这里先验
                -- 可用、不可用就当「没人说隐藏」。真模块口径（生产 + test_models_shape 的
                -- 整体切片）里它恒是函数，判定照常问；隐藏语义本身的对外覆盖由探针 A 钉。
                local hide_alias = type(name_hidden) == "function"
                    and name_hidden(store_mod, alias) or false
                if not hide_alias then
                    local tail = {}
                    for j = 2, #row do
                        tail[#tail + 1] = tostring(row[j])
                    end
                    data[#data + 1] = advertise_virtual_entry(store_mod, cfg,
                        caps_by_model, alias, tail)
                end
            end
        end
    end
    if #data == 0 then return nil end
    table.sort(data, function(a, b)
        return tostring(a.id) < tostring(b.id)
    end)
    return data
end

---Advertise the runtime virtual-model aliases next to the real ones, the way
---inject_virtual_models (gateway/src/server.rs:831) does — with the winner of a
---name clash inverted per the 2026-10-07 ruling (方案 A): the entry keeps the
---name and the real row behind it is dropped, so that an id which routes
---through the entry's target group is never also advertised as a plain
---local model.
---Synthetic entries still carry created 0 and owned_by "llm-router-><target>",
---and the whole list is re-sorted by id.
---
---Why the entry wins: the old direction advertised X as owned_by "local" while
---route_inference resolved X to the entry's group, so the worker that actually
---served X was screened out by the group gate and every model=X request died with
---503 "healthy engines serve none of the mapped models" — an advertisement the
---router contradicted on every request. Shadowing makes the two surfaces agree.
---@param data table @ model entries built from the registry (mutated)
---@param sources table|nil @ 同一请求内共享的 {store_mod, cfg, caps_by_model}，
---  由 models_handler 装配一次；缺省时本函数自己取（单测直接调它的场景）。
---  刻意用**一个表**而不是三个位置参数：数据源合法为空时（cfg = nil、
---  caps_by_model = nil）位置参数分不出「没传」与「传了个 nil」，会各自重算一遍。
local function inject_virtual_models(data, sources)
    if type(sources) ~= "table" then
        sources = { store_mod = store(), cfg = config_snapshot(),
                    caps_by_model = model_caps_table() }
    end
    local store_mod = sources.store_mod
    if not store_mod or type(store_mod.virtual_models_list) ~= "function" then
        return
    end
    local aliases = store_mod.virtual_models_list()
    if #aliases == 0 then
        return
    end
    -- 遮蔽判定只有一个对手：入口名。先按名册建出「哪些名字是入口」的集合，然后
    -- 用同一个集合仲裁两个方向 —— 真实行里被入口抢走名字的那一行整行摘掉，
    -- 入口行则无条件补上。两种语义互斥，必须在同一处判，否则下一轮改动又会在
    -- 两处各留一半（勘察报告 §2.3 A1/A2）。
    --
    -- 判据是**纯查表**（不用 pairs()）：同一份配置连查两次要产出逐字节相同的响应
    -- （test_models_shape G9 / e2e_models_advertisement 的字节稳定断言），
    -- pairs 遍历建集合会把顺序依赖带进输出。
    local shadowed = {}
    for i = 1, #aliases do
        local row = aliases[i]
        if type(row) == "table" then
            local alias = row[1]
            if type(alias) == "string" and alias ~= "" then
                shadowed[alias] = true
            end
        end
    end
    -- 真实那一半：与入口同名的行摘掉（=「真实 X 不再单独可达」的对外那一面）。
    -- 判据精确到 id 相等 —— 组内成员名不参与（advertise_virtual_entry 的
    -- owned_by_models 仍如实挂着整组），否则「Y 也被某入口映射」会把 Y 那行误删。
    local kept = 0
    for i = 1, #data do
        if not shadowed[data[i].id] then
            kept = kept + 1
            data[kept] = data[i]
        end
    end
    for i = kept + 1, #data do
        data[i] = nil
    end
    local seen = {}
    for i = 1, kept do
        seen[data[i].id] = true
    end
    for i = 1, #aliases do
        -- aliases[i] is {alias, targets...}: a variable-length row, one entry per model
        -- the service stands for. Reading only [2] (the old single target) would
        -- advertise an entry as if it were one engine, which is the semantics that just
        -- got retired.
        local alias = aliases[i][1]
        local tail = {}
        for j = 2, #aliases[i] do
            local name = tostring(aliases[i][j])
            -- 「隐藏」的第三处联动（另两处：候选门 candidates_for、watcher 的注册与保留）：
            -- 被藏起来的**组内成员**不进这一份名册。理由与遮蔽规则同一条 —— 这一行说的就是
            -- 「这个入口替这几个实际模型服务」，而藏起来的模型在选路侧根本不成候选，留着它
            -- 就是「对外说服务、每个请求都被拒」的自相矛盾广告（2026-10-07 那次故障的正是这句）。
            -- 判据与候选门同一个：config_store 的 model_is_hidden（卡片或入口任一说了 hidden）。
            if not name_hidden(store_mod, name) then
                tail[#tail + 1] = name
            end
        end
        -- 入口自己被藏 = 整行不产出；整组成员都被藏 = 这个入口已经没有还能服务的落点，
        -- 同样不产出。与「一个入口一行、绝不静默少一条」不冲突：那条纪律护的是**没被操作员
        -- 藏过**的入口（少一条会让客户端以为服务消失），这里少的每一条正是操作员亲手要抹掉的
        -- 名字。原本就不带成员名的脏行（#row<=1）照旧产出，保持它今天的形状。
        if not seen[alias] and not name_hidden(store_mod, alias)
            and (#tail > 0 or #aliases[i] <= 1) then
            -- 入口赢：同名时上面已经把真实那一行摘掉，这里无条件补出入口那一行
            -- （少一条等于让客户端以为整个服务消失了，与 only_data 同一条纪律）。
            -- seen 此刻只剩两件事要挡：重复的入口名（同一 id 出两行会打断按 id
            -- 建索引的客户端，保留名册里的第一条 —— store 侧按别名排序，谁在前是
            -- 确定的），以及「同名入口被别的入口名抢先」。组内成员名与入口重名
            -- 不误伤：判据守的是入口自己的 id，不是组内成员。
            seen[alias] = true
            data[#data + 1] = advertise_virtual_entry(store_mod, sources.cfg,
                sources.caps_by_model, alias, tail)
        end
    end
    table.sort(data, function(a, b)
        return tostring(a.id) < tostring(b.id)
    end)
end

local function models_handler()
    local models = registry.models()
    local store_mod = store()
    if models_advertise.enabled(store_mod) then
        local data = models_advertise.only_data(store_mod, config_snapshot(),
            model_caps_table())
        if data then
            return { object = "list", data = data }
        end
        -- 开关打开却一条入口都装配不出来：这不是「对外只暴露入口」，而是整个服务
        -- 看起来消失了。按用户的纪律如实报出来（WARN 一行）并退回全量广告，让操作员
        -- 从日志和面板上都能看见配置没生效，而不是让客户端猜。
        if type(ngx) == "table" and type(ngx.log) == "function" then
            pcall(ngx.log, ngx.WARN, "lua-router: models_virtual_only is on but no ",
                "virtual entry is available; advertising real models instead")
        end
    end
    if #models == 0 then
        -- Rust only rewrites responses that carry a "data" array, so the
        -- no-worker text answer is returned untouched.
        return text_response(503, "No models available")
    end
    -- 配置快照与引擎广告表**只取一次**往下传：current() 会解码整份快照，
    -- 一个请求读两遍纯属白付（列表里 N 个模型也共享同一份读数）。
    local cfg = config_snapshot()
    local caps_by_model = model_caps_table()
    local data = {}
    for i = 1, #models do
        -- 「隐藏」（用户裁定 2026-10-08）第一处联动：藏起来的真实模型**不产出条目**（调用侧
        -- 过滤，advertise_real_model 本身一字未改 —— 它的形状被 test_models_shape 与 e2e 钉着，
        -- 且「不广告」是调用侧的策略而不是那一行的形状）。advertise_real_model 因此仍然可以
        -- 被任何调用方（含单测）直接调用并拿到与今天相同的字节。
        -- 与候选门读同一份判定：一处还广告、另一处已不服务，就是我们要避免的那件事。
        if not name_hidden(store_mod, models[i]) then
            data[#data + 1] = advertise_real_model(store_mod, cfg, caps_by_model, models[i])
        end
    end
    inject_virtual_models(data, {
        store_mod = store_mod, cfg = cfg, caps_by_model = caps_by_model,
    })
    return { object = "list", data = data }
end


---The Rust gateway answers this from router_manager with routers/workers counts;
---the Lua router has exactly one router, so it reports the same keys plus its own
---config summary, which is what the UI needs to show the active policy.
local function server_info_handler()
    local records = registry.records()
    local healthy = 0
    for i = 1, #records do
        if registry.is_healthy(records[i].id) then
            healthy = healthy + 1
        end
    end
    local conf = cfg()
    return {
        router_manager = false,
        router_type = "lua",
        version = conf.version,
        routers_count = 1,
        workers_count = #records,
        healthy_workers = healthy,
        policy = conf.policy,
        enable_igw = conf.enable_igw,
        models = registry.models(),
        health_check = {
            endpoint = conf.health_check_endpoint,
            interval_secs = conf.health_check_interval_secs,
            failure_threshold = conf.health_failure_threshold,
            success_threshold = conf.health_success_threshold,
        },
        circuit_breaker = {
            failure_threshold = conf.cb_failure_threshold,
            success_threshold = conf.cb_success_threshold,
            timeout_duration_secs = conf.cb_timeout_duration_secs,
            window_duration_secs = conf.cb_window_duration_secs,
        },
        retry = {
            max_retries = conf.max_retries,
            initial_backoff_ms = conf.initial_backoff_ms,
            max_backoff_ms = conf.max_backoff_ms,
        },
        uptime_s = ngx.now() - conf.started_at_ms / 1000,
    }
end

local function not_implemented_handler()
    return send_error(501, "not_implemented",
        "not implemented in the Lua router")
end
-- 跨模块接线（拆分新增；文末，不进锚点区间）。原文件底部导出区对
-- models_advertise 的就近导出（连同「刻意放在底部而不是本节内」的注释）随之搬入
-- router.lua facade 的导出区，那里的 _M 是 facade 表。
_M.MODEL_CREATED_UNKNOWN = MODEL_CREATED_UNKNOWN
_M.name_hidden = name_hidden
_M.advertise_virtual_entry = advertise_virtual_entry
_M.advertise_real_model = advertise_real_model
_M.model_caps_table = model_caps_table
_M.config_snapshot = config_snapshot
_M.models_advertise = models_advertise
_M.models_handler = models_handler
_M.server_info_handler = server_info_handler
_M.not_implemented_handler = not_implemented_handler
return _M
