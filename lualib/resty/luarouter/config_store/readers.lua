-- resty.luarouter.config_store.readers
-- P22-P26：current / ctx_cap 族 / 模态与能力声明 / policy 热路径读 / 虚拟视图 / 档位三层查表。
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
local CS_PERSISTENCE = require "resty.luarouter.config_store.persistence"
local CS_UPSTREAMS = require "resty.luarouter.config_store.upstreams"
local CS_SNAPSHOT = require "resty.luarouter.config_store.snapshot"
-- 同名遮蔽判据与写入层共用同一份实现（config_store/profiles.lua 的 engine_attested_models）。
-- 只走对端子模块的共享表、不进 facade 导出面：ctx_cap 与四处写入守卫必须对「这个名字是不是
-- 引擎报过的真实模型」只有一个答案，两处各查一次 registry 就会在巡检空档里说两套话。
local CS_PROFILES = require "resty.luarouter.config_store.profiles"

local _M = {}

-- Forward declaration: registered_models lives in the models-document section
-- further down, and policy_document needs it from earlier in the file.
local registered_models

-- 磁盘快照的读路径用这份上下文（config_store/profiles.lua 的 new_shadow_context 注释写了
-- 为什么读路径必须放行）：同名遮蔽的判据只在**写入侧**说话。在这里追问引擎读数会让一份
-- 当年合法的配置在那台实例恰好没被探到（或已被摘掉）时整体读不回来，而 current() 读不回
-- 配置就整份退回 env 默认 —— 等于把网关的全部配置抹平。
local SHADOW_READ = CS_PROFILES.new_shadow_context({ reload = true })

function _M.current()
    CS_FACADE.migrate_once()
    local snap = CS_PERSISTENCE.read_snapshot()
    if snap then
        local cfg, err = CS_SNAPSHOT.cfg_from_document(snap, nil, SHADOW_READ)
        if cfg then return cfg end
        ngx.log(ngx.WARN, "persisted config invalid (", err, "); falling back to env defaults")
    end
    return CS_SNAPSHOT.cfg_from_env()
end

function _M.env_defaults()
    if not CS_FACADE._env_defaults then
        local snap = CS_SNAPSHOT.snapshot_of(CS_SNAPSHOT.cfg_from_env())
        snap.upstreams = CS_UPSTREAMS.sanitize_upstream_rows(snap.upstreams)
        CS_FACADE._env_defaults = snap
    end
    return CS_FACADE._env_defaults
end

--- /v1/models「只广告虚拟入口」开关的权威读数：磁盘快照优先，其次 env，都没说过 = 关。
---
--- 为什么不直接读 current().models_virtual_only：current() 是「文件整层赢 env 整层」的二选一
--- 合并（快照存在且合法就整份用文件、否则整份退回 env），它不会逐字段 merge。于是「文件里没
--- 写这个键、但 env 里设了」这一情形下，current() 返回的是文件那份 cfg，其 models_virtual_only
--- 与 models_virtual_only_env 都是 nil，env 的 true 会被整个吞掉。这里改成逐键的两层读数：
--- 先看快照里的原始键（未擦除则它就是操作员的结论，false 也压过 env 的 true），键不在才让给
--- env，两层都没说过才 false。这正是 router.lua:4173 那份 models_advertise 自己读盘的口径 ——
--- 两边指向同一份数据、同一套真值表，router 侧刻意不动（030dab5 已定稿），此处只是把同一答案
--- 从 config_store 也答一遍，供 /_ui/config 的往返与任何想走 store 的读者用。
---@return boolean
function _M.models_virtual_only()
    local snap = CS_PERSISTENCE.read_snapshot()
    if type(snap) == "table" then
        local raw = rawget(snap, "models_virtual_only")
        -- JSON null 与 Lua nil 都算「文件里没说」，让给 env；显式布尔（含 false）就是结论。
        if raw ~= nil and raw ~= JSON_NULL then
            if type(raw) == "boolean" then return raw end
            return CS_LEXICON.advertise_truthy(raw)
        end
    end
    local e = CS_ENV.env("LMR_MODELS_VIRTUAL_ONLY")
    if e ~= nil then return CS_LEXICON.advertise_truthy(e) end
    return false
end

-- ------------------------------------------------------------- readers

--- Context cap of a *real* model, from its card or the legacy table. An entry's own name
--- is deliberately excluded: which clamp a virtual request gets is
--- virtual_ctx_cap's decision (uniform across the group, independent of the pick), and
--- letting a card written under the entry name leak in here would re-open the per-pick
--- variance the ruling closed.
---
--- 同名遮蔽（用户裁定 2026-10-07，方案 A）让开的那一条：入口名**同时是引擎报过的真实模型**
--- 时，这张卡片说的就是被遮蔽的那台落点实例本身，它必须能被读到。原来「入口名一律隐身」把
--- 这一情形一起吞掉了 —— 入口 X 遮蔽真实模型 X 之后，操作员给 X 写的卡片在 ctx_cap /
--- virtual_ctx_cap / /_ui/props 三条链上全是永不生效的死配置，而契约要求的正是「配置配在
--- 入口上、落到选中实例」。放宽的判据仍然**不认操作员的声明**：只有 registry 侧
--- `record_models` ∩ `models_are_verified`（引擎亲口答过 /v1/models 的广告列表）才算数，于是
---   * 纯虚拟名（引擎从不认识的那个名字）继续隐身，per-pick 抖动那条裁定逐字成立；
---   * 从没被探到的实例不算引擎背书，此时该名字的卡片复现改动前的答案（读不出来）——
---     与「探针失败只损失精度、未知不等于否定」同方向，也不让一份配置因巡检空档而变形状。
--- 判据与写入层共用 config_store/profiles.lua 那份实现：那里决定谁能被写进来，这里决定谁能被
--- 读出来，两处必须对「真实模型」只有一个答案，不能各查各的。
---
--- 已不参与 max_tokens 钳制（2026-10-04 裁定：网关不改写调用方的输出预算，见 router.lua
--- 的 apply_ctx_cap 恒等空壳）；保留供查看与兼容（UI 与 doc 仍按名字引用，单测也仍断言）。
--- 便宜的那一半判据：入口自己的模型组里是否含它自己的名字（= 它是否真的遮蔽了一个落点名）。
--- 只看组、不看 registry，因此纯虚拟名永远 false。手写脏行（组里没有这个名字）同样 false。
---@param cfg table @ current() 的快照
---@param name string
---@return boolean
local function entry_names_itself(cfg, name)
    local profile = cfg.virtual_profiles and cfg.virtual_profiles[name]
    if type(profile) ~= "table" then return false end
    local group = profile.targets
    if type(group) == "table" then
        for i = 1, #group do
            if group[i] == name then return true end
        end
    end
    return profile.target == name
end

--- 判据上下文按次现取：卡片读数走 current() 的 TTL 缓存，引擎名册走 registry 的 shdict，
--- 两处都不是新的进程内状态（「跨请求状态只走 shdict」这条红线不受影响）。registry 缺席时
--- attested 是 nil = 「没有任何背书」= 卡片继续隐身，缺省零行为变化。
---@return table ctx
local function shadow_context()
    local attested = CS_PROFILES.engine_attested_models
    if type(attested) ~= "function" then
        return { attested = nil }
    end
    return { attested = attested() }
end

function _M.ctx_cap(model)
    if type(model) ~= "string" or model == "" then return nil end
    local cfg = CS_FACADE.current()
    if cfg.virtual_profiles[model] ~= nil or cfg.virtual_models[model] ~= nil then
        -- 名字命中入口表。只有「这个入口名就是它自己所遮蔽的那个实际模型」时继续读卡片，
        -- 而且先用**便宜的**成员判定筛一遍：入口自己的组里不含这个名字时，这张卡片说的不是
        -- 它的任何一台落点实例，一律维持隐身——于是纯虚拟名（引擎从不认识的那个名字）这条
        -- 最常见的路径连 registry 都不用碰，per-pick 抖动那条裁定逐字继续成立。
        if not entry_names_itself(cfg, model) then return nil end
        -- 引擎背书这一半是判据的后置条件（不得把操作员的声明当引擎背书）。判据被剥掉时
        -- （一份只装了 readers 的探针 / profiles 那两项没落地）按「没有背书」处理 = 隐身，
        -- 与改动前逐字节一致。
        local may_shadow = CS_PROFILES.may_shadow_own_name
        if type(may_shadow) ~= "function" then return nil end
        if not may_shadow(shadow_context(), model, model) then return nil end
    end
    local card = cfg.model_configs[model]
    if card and card.ctx then return card.ctx end
    return cfg.model_ctx[model]
end

--- The one context clamp a virtual-model entry must present downstream.
---
--- Root ruling 2026-10-02 ("只能配置模型上下文长度覆盖，以便对下游保持统一"): the clamp
--- of a virtual entry is a property of the *entry*, not of whichever instance the policy
--- happened to pick, so it cannot be looked up per landing model -- the same request
--- would get one max_tokens on worker A and another on worker B, which is precisely the
--- non-uniformity the ruling exists to remove.
---   1. an explicit `context_window` on the entry wins outright and ignores every card;
---   2. otherwise the *minimum* of the cards of the models in its group. Minimum because
---      a group is served by engines the entry does not control: clamping to the widest
---      would send a body the narrowest of them can reject, and the value would still
---      flicker with the pick. A conservative constant is the only reading that is both
---      safe and uniform;
---   3. nil when no card and no override exists -- which is byte-for-byte the
---      pre-feature "nothing to clamp" answer.
--- An empty/absent group falls back to the representative target's card so a legacy
--- {model, target} pair keeps clamping exactly as it does today (the group of one *is*
--- that target, so the minimum is the same number).
---
--- 已不参与 max_tokens 钳制（2026-10-04 裁定，同上）；保留供查看与兼容。
---@param alias_or_profile table|string|nil
---@return number|nil cap
function _M.virtual_ctx_cap(alias_or_profile)
    local profile
    if type(alias_or_profile) == "table" then
        profile = alias_or_profile
    elseif type(alias_or_profile) == "string" and alias_or_profile ~= "" then
        profile = CS_FACADE.current().virtual_profiles[alias_or_profile]
    end
    if type(profile) ~= "table" then return nil end
    local explicit = profile.context_window
    if type(explicit) == "number" and explicit >= 1 then return math.floor(explicit) end
    -- A group of one is not a group: with nothing declared but one model, the clamp the
    -- engine's own card dictates *is* the uniform answer, and taking it here (rather than
    -- at the card_key the router resolves per pick) keeps a legacy {model, target} pair
    -- clamping byte-for-byte as it does today. Only a genuine multi-model entry needs a
    -- decision that is independent of which instance the policy chose.
    -- 只有操作员写过 targets 的入口才接管 clamp：legacy 行（只有 target
    -- 和或 candidates）一律返回 nil，让 clamp 照旧的「按落点模型卡」路径逐字节不变。
    -- 并集口径下一个多绑定的旧入口也许拟出 >=2 的组，所以这里只能看
    -- explicit_targets 而不能只看组长度，否则普通修改会把它的 clamp 换掉。
    if profile.explicit_targets ~= true then return nil end
    local group = profile.targets
    if type(group) ~= "table" or #group < 2 then return nil end
    local cap
    for i = 1, #group do
        local one = CS_FACADE.ctx_cap(group[i])
        if type(one) == "number" and one >= 1 then
            if cap == nil or one < cap then cap = one end
        end
    end
    return cap
end

function _M.modalities_for(model)
    if type(model) ~= "string" or model == "" then return nil end
    local card = CS_FACADE.current().model_configs[model]
    if card then return card.modalities end
    return nil
end

--- 操作员在模型卡片上勾选的档位阶梯（config 声明层，用户诉求 2026-10-08）。
--- 返回**新表**（调用方改不坏存储，与 profile_for 的拷贝纪律同口径），形状
--- { {value, label?, default}, ... }；没这张卡或这个键沉默 → nil = 「没说」，
--- 对外读数让位引擎自报。返回空数组 = 操作员说过「一个都不收」，与 nil 必须可分。
---@param model string
---@return table|nil
function _M.card_effort_ladder(model)
    if type(model) ~= "string" or model == "" then return nil end
    local card = CS_FACADE.current().model_configs[model]
    if not card then return nil end
    local raw = card.reasoning_efforts
    if type(raw) ~= "table" then return nil end
    local out = {}
    for i = 1, #raw do
        local rung = raw[i]
        if type(rung) == "table" and type(rung.value) == "string" then
            out[#out + 1] = {
                value = rung.value,
                label = rung.label,
                ["default"] = rung["default"] == true,
            }
        end
    end
    return out
end

--- 操作员在模型卡片上声明的 tool use 能力（三态）。/v1/models 的合成侧
--- （router.resolve_model_caps）把它填进 capabilities.supports_tool_use 的
--- 「config 声明」优先位：声明了就用声明的，没声明（nil）才退引擎自报，
--- 两边都没有就整键省略。nil 与 false 的区别必须一路保住——false 是结论，
--- nil 只是沉默（硬规则 9②：宁可不报也不猜）。
---@return boolean|nil
function _M.card_supports_tool_use(model)
    if type(model) ~= "string" or model == "" then return nil end
    local card = CS_FACADE.current().model_configs[model]
    if not card then return nil end
    local value = card.supports_tool_use
    if type(value) == "boolean" then return value end
    return nil
end

--- 虚拟模型条目的能力/档位声明（卡片级的读数由卡片自己出，这里只给条目这一层）。
--- 接受别名或 profile 表——router 手上往往已经有 profile_for 的拷贝，省一次回查。
--- 返回的是新表，调用方改不坏存储（与 profile_for 的拷贝纪律同口径）。
---@param alias_or_profile string|table
---@return table|nil { default_effort=, effort_map=, modalities=, supports_tool_use= }
function _M.entry_declaration(alias_or_profile)
    local profile
    if type(alias_or_profile) == "table" then
        profile = alias_or_profile
    elseif type(alias_or_profile) == "string" and alias_or_profile ~= "" then
        profile = CS_FACADE.current().virtual_profiles[alias_or_profile]
    end
    if type(profile) ~= "table" then return nil end
    local out
    local function field(key, value)
        if value == nil then return end
        out = out or {}
        out[key] = value
    end
    field("default_effort", profile.default_effort)
    if type(profile.effort_map) == "table" and next(profile.effort_map) ~= nil then
        local map = {}
        for from, to in pairs(profile.effort_map) do map[from] = to end
        field("effort_map", map)
    end
    if type(profile.modalities) == "table" then
        field("modalities", { table.unpack(profile.modalities) })
    end
    -- 三态：false 要原样带出去（它是要参与决策的声明），nil 不写键。
    field("supports_tool_use", profile.supports_tool_use)
    return out
end

-- ------------------------------------------------------ policy (hot path) reads
--
-- policy.lua calls these on every select, so the two keys the chain needs are
-- memoised per worker instead of decoding the whole snapshot each time. The
-- shared-dict revision token invalidates the memo the instant another process
-- writes; without a dict (unit runs, a missing lua_shared_dict) the 0.5s file
-- TTL bounds the staleness, which is the tolerance the rest of this module
-- already documents for config reads.

local policy_view = { token = nil, at = 0, global = nil, models = nil }

local function policy_state()
    local token = CS_FACADE.policy_revision()
    local now = (ngx and ngx.now) and ngx.now() or os.time()
    local fresh = (now - policy_view.at) < CS_LEXICON.SNAPSHOT_TTL and not CS_FACADE._policy_view_dirty
    if fresh and (token == nil or policy_view.token == token) then
        return policy_view
    end
    CS_FACADE._policy_view_dirty = nil
    local cfg = CS_FACADE.current()
    policy_view.token = token
    policy_view.at = now
    policy_view.global = cfg.policy
    policy_view.models = cfg.model_policies
    return policy_view
end

--- Operator override for one model (config-store layer only, no env fallback).
function _M.policy_override_for(model)
    if type(model) ~= "string" or model == "" then return nil end
    return policy_state().models[model]
end

--- Operator override for the global policy, nil when the page has not set one.
function _M.policy_global_override()
    return policy_state().global
end

--- SMG_POLICY as resty.luarouter.config parsed it (one_of collapses garbage to
--- the default), so the UI can label the env layer of the chain honestly.
function _M.env_policy()
    local raw_policy = CS_FACADE.normalize_policy(CS_ENV.env("SMG_POLICY"))
    if raw_policy then return raw_policy end
    return CS_LEXICON.ENV_POLICY_DEFAULT
end

--- Cheap gate for the per-request hot path in policy.lua: true when the
--- operator has configured any routing override at all. False means the policy
--- chain collapses to its pre-feature shape (hint or SMG_POLICY), so policy.lua
--- can skip re-resolving entirely.
function _M.policy_override_active()
    local state = policy_state()
    return state.global ~= nil or next(state.models) ~= nil
end

--- The precedence chain, implemented once for both the router and the page.
--- Returns (policy name, winning layer) where layer is one of
--- "model" | "global" | "hint" | "env".
---   1. model_policies[model]   operator per-model override  -> "model"
---   2. policy                  operator global override     -> "global"
---   3. hint                    worker labels.policy         -> "hint"
---   4. cfg_policy              env SMG_POLICY (config.lua)  -> "env"
---   5. round_robin                                          -> "env"
--- Operator configuration outranks the worker hint: what the console says is
--- what routes. With no overrides set the chain degenerates to
--- hint -> cfg.policy -> round_robin, the pre-feature behaviour, and an unknown
--- name at any layer collapses to round_robin as policy.new always did.
function _M.resolve_policy(cfg_policy, model, hint)
    if type(model) == "string" and model ~= "" and model ~= "default" then
        local override = CS_FACADE.policy_override_for(model)
        if override then return override, "model" end
    end
    local global_override = CS_FACADE.policy_global_override()
    if global_override then return global_override, "global" end
    if type(hint) == "string" and hint ~= "" then
        local named = CS_FACADE.normalize_policy(hint)
        if named then return named, "hint" end
        return "round_robin", "hint"
    end
    if type(cfg_policy) == "string" and cfg_policy ~= "" then
        local named = CS_FACADE.normalize_policy(cfg_policy)
        if named then return named, "env" end
        return "round_robin", "env"
    end
    return "round_robin", "env"
end

--- Snapshot rows, the round-trip format the apply endpoint accepts.
function _M.model_policies_list()
    local state = policy_state()
    local out = {}
    for _, model in ipairs(CS_LEXICON.sorted_keys(state.models)) do
        out[#out + 1] = { model = model, policy = state.models[model] }
    end
    return out
end

--- Routing-page document: the chain inputs, plus one row per model showing the
--- policy that model actually routes with and which layer supplied it.
function _M.policy_document()
    local env_policy = CS_FACADE.env_policy()
    local rows = {}
    local order, seen = {}, {}
    local function note(model)
        if model ~= nil and not seen[model] then
            seen[model] = true
            order[#order + 1] = model
        end
    end
    for _, row in ipairs(registered_models()) do note(row.model) end
    for _, row in ipairs(CS_FACADE.model_policies_list()) do note(row.model) end
    -- 虚拟入口名也进这一张表。root ruling 2026-10-02 摘掉了 per-alias 的 policy 字段，
    -- 于是「给这个入口换策略」只剩 model_policies 一条路；而 1 对多之后策略实例的 key
    -- 恰恰就是入口名（一个入口一棵亲和树，见 router.group_key_name）。少了这一行，
    -- 路由页就永远列不出入口那一行，操作员只能靠手打名字——最关键的调度开关反而没有入口。
    -- registered 对入口名恒为 false（引擎不认识这个名字，本就不该被算作已注册）。
    for alias in pairs(CS_FACADE.current().virtual_profiles) do note(alias) end
    table.sort(order)

    local registry_mod
    do
        local ok, mod = pcall(require, "resty.luarouter.registry")
        if ok and type(mod) == "table" then registry_mod = mod end
    end

    local registered_set = {}
    for _, row in ipairs(registered_models()) do registered_set[row.model] = true end
    local global_override = CS_FACADE.policy_global_override()
    for _, model in ipairs(order) do
        local hint
        if registry_mod and type(registry_mod.policy_hint_for_model) == "function" then
            local ok, value = pcall(registry_mod.policy_hint_for_model, model)
            if ok and type(value) == "string" and value ~= "" then hint = value end
        end
        local override = CS_FACADE.policy_override_for(model)
        -- One chain for both planes: policy.lua calls the same function, so the
        -- page can never advertise a policy the router is not using.
        local effective, source = CS_FACADE.resolve_policy(env_policy, model, hint)
        rows[#rows + 1] = {
            model = model,
            registered = registered_set[model] == true,
            override = CS_LEXICON.nul(override),
            hint = CS_LEXICON.nul(hint),
            effective = effective,
            source = source,
        }
    end

    local names = {}
    for i = 1, #CS_LEXICON.POLICY_NAMES do names[i] = CS_LEXICON.POLICY_NAMES[i] end
    return {
        policies = names,
        policy = CS_LEXICON.nul(global_override),
        env_policy = env_policy,
        effective_default = global_override or env_policy,
        model_policies = CS_LEXICON.arr(CS_FACADE.model_policies_list()),
        models = CS_LEXICON.arr(rows),
        revision = CS_FACADE.policy_revision(),
        persist = { file = CS_LEXICON.nul(CS_ENV.env("LMR_CONFIG_FILE")) },
    }
end

--- Virtual alias -> real upstream id; unknown names passes through unchanged.
function _M.resolve_model(model)
    if type(model) ~= "string" then return model end
    return CS_FACADE.current().virtual_models[model] or model
end

--- One row per alias: { alias, model... } -- the alias followed by every real model it
--- stands for. The row is deliberately variadic rather than {alias, target}: under the
--- group semantics an entry covers N engines and an advertiser that reads only [2] would
--- put the old single-owner shape back on the wire. Legacy rows carry the group of one
--- they always had, so their consumers see exactly what they saw before.
function _M.virtual_models_list()
    local cfg = CS_FACADE.current()
    local out = {}
    for _, alias in ipairs(CS_LEXICON.sorted_keys(cfg.virtual_models)) do
        local profile = cfg.virtual_profiles[alias]
        local group = (type(profile) == "table" and profile.targets) or nil
        if type(group) ~= "table" or #group == 0 then
            group = { cfg.virtual_models[alias] }
        end
        local row = { alias }
        for i = 1, #group do
            if type(group[i]) == "string" and group[i] ~= "" then
                row[#row + 1] = group[i]
            end
        end
        out[#out + 1] = row
    end
    return out
end

--- The model group an entry stands for, for the UI and the config document. Nil for a
--- name that is not an entry, so callers can tell "no entry" from "entry with nothing
--- mapped" (the latter cannot be built: the validator requires a non-empty group).
function _M.virtual_targets(model)
    if type(model) ~= "string" or model == "" then return nil end
    local profile = CS_FACADE.current().virtual_profiles[model]
    if type(profile) ~= "table" or type(profile.targets) ~= "table" then return nil end
    local out = {}
    for i = 1, #profile.targets do out[i] = profile.targets[i] end
    return out
end

--- 把一层的 effort_map 归一成 from->to 的查表；两种拼法都收。
---@param map table|nil
---@return table|nil
local function effort_map_view(map)
    if type(map) ~= "table" then return nil end
    -- 两种拼法都收：磁盘/UI 的 { {from,to}, ... } 数组，和装配后进 profile 的查表。
    -- router 传下来的 entry_fallback 可能出自调用方自己拼的形状，这里不能只认一种。
    if #map > 0 and type(map[1]) == "table" and rawget(map[1], "from") ~= nil then
        local out = {}
        for _, item in ipairs(map) do
            local from = CS_FACADE.normalize_effort(item.from)
            local to = CS_FACADE.normalize_effort(item.to)
            if from and to then out[from] = to end
        end
        if next(out) == nil then return nil end
        return out
    end
    return map
end

--- 装配三层查表用的表数组（顺序即优先级）；nil 层跳过，全局层永远在场。
local function effort_layers(card, entry_fallback, cfg)
    local layers = {}
    if type(card) == "table" then
        layers[#layers + 1] = { map = effort_map_view(card.effort_map),
                                default_effort = card.default_effort }
    end
    if type(entry_fallback) == "table" then
        layers[#layers + 1] = { map = effort_map_view(entry_fallback.effort_map),
                                default_effort = entry_fallback.default_effort }
    end
    layers[#layers + 1] = { map = effort_map_view(cfg.effort_map),
                            default_effort = cfg.default_effort }
    return layers
end

--- 点名了档位：逐层问「有没有人规定这个档位要改写成谁」，第一个命中的赢。
--- 查表键是规范化的档位（trim + lower），与它是否在八个已知档位之内无关——映射表里
--- 只可能有合法档位，未知档位自然查不到，于是走透传，这正是「不猜」的行为。
local function effort_map_lookup(layers, wanted)
    for i = 1, #layers do
        local map = layers[i].map
        if type(map) == "table" then
            local hit = map[wanted]
            if type(hit) == "string" and hit ~= "" then return hit end
        end
    end
    return nil
end

--- 没点名：逐层找第一个声明了缺省档的层。全空 = 完全不覆盖 = nil。
--- 层里读到的值重新过一次 normalize_effort：环境/文档层的历史字节可能带大小写或空格。
local function effort_default_lookup(layers)
    for i = 1, #layers do
        local value = layers[i].default_effort
        if type(value) == "string" then
            local normalized = CS_FACADE.normalize_effort(value)
            if normalized then return normalized end
        end
    end
    return nil
end

--- Effective effort for one request.
---
--- 阶梯（用户裁定 2026-10-04）：model_effort 强制行 > **卡片 > 条目 > 全局**。
---
--- 与旧实现的区别就是要修的那个 bug：老代码是「有卡片就整层走卡片，卡片没这条映射时
--- 直接透传」，于是同一份全局 effort_map 对配了卡片的模型永远不生效——操作员在全局
--- 页面填了 low->minimal，只要该模型有一张卡片（哪怕卡片只管 ctx），这条映射就悄悄
--- 失效。新口径是**逐 from 查表**：请求点名的档位依次问三层，第一个给了这条映射的层
--- 赢，三层都没给才原样透传。default_effort 同理：第一个非 nil 的层赢，三层全空返回
--- nil，网关一个字节都不改（完全透传）。
---
--- 参数名 entry_fallback 与调用方（router.lua 的 apply_effort_policy）逐字一致：它是
--- 虚拟模型条目那一层的读数，由 router 把手上的 profile 传下来，省掉这里再按别名回查
--- current()。形状 { default_effort=string|nil, effort_map=map 或 {from,to} 数组 }。
---
--- 为什么卡片仍排在条目之上：卡片说的是**落点引擎**自己的说法（配在真实模型名上），
--- 而入口跨 N 个引擎。放行条目层是加**兜底**，不是把入口提到引擎头上——2026-10-02
--- 「档位是引擎的属性」那条裁定继续成立。
---
---@param model string @ 落点实际模型名
---@param wanted string|nil @ 请求点名的档位
---@param entry_fallback table|nil @ 虚拟模型条目那一层的读数
---@return string|nil
function _M.request_effort_for(model, wanted, entry_fallback)
    local cfg = CS_FACADE.current()
    local model_key = (type(model) == "string" and model ~= "") and model or nil
    -- 强制层的位置不变：本来就在最前，而且它是操作员显式按模型钉死的。
    if model_key and cfg.model_effort[model_key] then
        return cfg.model_effort[model_key]
    end
    local card = model_key and cfg.model_configs[model_key] or nil
    local requested
    if type(wanted) == "string" then
        local v = CS_LEXICON.lower(CS_LEXICON.trim(wanted))
        -- "" / "null" / "default" 是客户端的「没说话」，走缺省档那一支。未知档位
        -- （例如上游新加的模式名）算「点了名、但没人规定怎么改写」，于是原样透传：
        -- 网关不替客户端猜档位，也不拿缺省档去覆盖客户端亲口写的值。未命中时返回
        -- **规范化后的档位**（trim + lower），与改动前两条分支完全一致：客户端写
        -- " High " 而引擎只认 "high" 是本项目第 2 条要弥补的欠配置请求，替它把大小写
        -- 顺平是既有行为，不是本次要改的东西。未知档位规范化后仍是原话（不在词表里
        -- 就没什么可顺的），所以 15c 那条透传口径不受影响。
        -- 旧实现唯一真正不一致的地方是「有卡片时未知档位被拉去填缺省档、无卡片时不会」
        -- ——卡片在场与否不该改变语义，这里统一成逐层查表 + 未命中即透传。
        if v ~= "" and v ~= "null" and v ~= "default" then
            requested = v
        end
    end
    local layers = effort_layers(card, entry_fallback, cfg)
    if requested then
        return effort_map_lookup(layers, requested) or requested
    end
    return effort_default_lookup(layers)
end

-- ------------------------------------------------------------- mutations

--- Registered (model, worker url) pairs from the core registry view.
registered_models = function()
    local props_ok, props = pcall(require, "resty.luarouter.props")
    local out = {}
    if props_ok then
        for _, w in ipairs(props.http_workers()) do
            for _, m in ipairs(w.models or {}) do
                out[#out + 1] = { model = m, url = w.url }
            end
        end
    end
    return out
end

-- ------------------------------------------------- 跨子模块直调的原文 local
-- 这些函数在原文里是同文件 local 直调、从未挂在 _M 上；拆开后由调用方直接 require 本表
-- 调用（不经 facade，所以既不是新增导出、也不给单测多开一个可替换点）。
_M.registered_models = registered_models

return _M
