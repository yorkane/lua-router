-- resty.luarouter.config_store.profiles
-- P8-P10：池 URL / 候选 / 绑定 / 组 / 条目声明装配，profile 装配与两条别名链守卫。
--
-- 由 lualib/resty/luarouter/config_store.lua 拆分而来：函数体逐行原样搬家，只调整 require 与
-- 跨模块接线（doc/refactor-arch-2026-10-05.md §1–§2）。原文里经 _M.x() 的自调 → 经 CS_FACADE
-- 表调用（保住单测换桩的可拦截性逐点一致）；原文里的同文件 local 直调 → 直接 require 对端
-- 子模块的共享表调用（不进 facade 导出面，_M 契约因此逐名不变）。
local CS_FACADE = require "resty.luarouter.config_store"
local cjson = require "cjson.safe"
local JSON_NULL = cjson.null
local CS_LEXICON = require "resty.luarouter.config_store.lexicon"

local _M = {}

--- Lowercase scheme, lowercase host, port kept, no path/userinfo allowed:
--- upstreams are transport endpoints, so "http://H:P/" and "http://h:p" are one
--- entry and anything with a path is rejected by the caller-facing validator.
--- Returns canonical url or nil.
local function norm_pool_url(raw)
    if type(raw) ~= "string" then return nil end
    local s = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    if s:find("%s") then return nil end
    local scheme, rest = s:match("^([%a][%w+.-]*)://(.*)$")
    if not scheme then return nil end
    scheme = scheme:lower()
    if scheme ~= "http" and scheme ~= "https" then return nil end
    if rest == "" then return nil end
    local authority, path = rest:match("^([^/]*)(.*)$")
    if authority == nil then return nil end
    -- trailing slashes are identity, not a path: strip them, then anything left
    -- over is a real path and this is not a transport endpoint.
    path = path:gsub("/+$", "")
    if path ~= "" then return nil end
    if authority == "" or authority:find("@") then return nil end
    local host, port
    if authority:sub(1, 1) == "[" then
        host = authority:match("^(%[[^%]]-%])")
        if not host then return nil end
        local tail = authority:sub(#host + 1)
        if tail == "" then
            port = nil
        else
            port = tail:match("^:(%d+)$")
            if not port then return nil end
        end
    else
        if authority:find("[^%w%.%-%:]") then return nil end
        local h, p = authority:match("^([^:]-):(%d+)$")
        if h and h ~= "" and p then
            host, port = h, p
        elseif authority:find(":") then
            return nil
        else
            host, port = authority, nil
        end
    end
    if host == "" then return nil end
    host = host:lower()
    if port then
        local n = tonumber(port)
        if not n or n < 1 or n > 65535 then return nil end
        return scheme .. "://" .. host .. ":" .. tostring(n)
    end
    return scheme .. "://" .. host
end

local WORKER_ID_PAT = "^" .. ("%x"):rep(8) .. "%-" .. ("%x"):rep(4) .. "%-"
    .. ("%x"):rep(4) .. "%-" .. ("%x"):rep(4) .. "%-" .. ("%x"):rep(12) .. "$"

--- A candidate-instance entry may be a normalized url or a worker id (uuid); B's
--- router filter matches on either, so both shapes are accepted and stored.
local function looks_like_worker_id(value)
    if type(value) ~= "string" then return false end
    local s = value:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    return s:match(WORKER_ID_PAT) ~= nil
end

local function norm_candidate(value)
    if type(value) ~= "string" then return nil end
    local url = norm_pool_url(value)
    if url then return url end
    if looks_like_worker_id(value) then
        return (value:gsub("^%s+", ""):gsub("%s+$", "")):lower()
    end
    return nil
end

--- Ordered, deduplicated candidate list; nil entries rejected by the caller.
local function build_candidates(alias, raw)
    if raw == nil or raw == JSON_NULL then return nil end
    if not CS_LEXICON.is_array(raw) then
        return nil, string.format("virtual model %s workers must be an array of strings", alias)
    end
    local out, seen = {}, {}
    for _, item in ipairs(raw) do
        local cand = norm_candidate(item)
        if not cand then
            return nil, string.format(
                "virtual model %s workers entries must be normalized urls or worker ids", alias)
        end
        if not seen[cand] then
            seen[cand] = true
            out[#out + 1] = cand
        end
    end
    if #out == 0 then return nil end
    return out
end

--- Per-candidate model bindings: {worker=, model=} objects, in declaration order.
---
--- 为什么要这一层：一个虚拟模型过去只能整体指向一个 target，于是"217 上那两个实例服务
--- 同一个模型、21.k 那个实例服务另一个模型"这种真实拓扑就配不出来（要么把整池收窄成一
--- 个模型，要么所有候选共用一个名字）。候选各带 model 后，转发体里的 model 由选中的那个
--- 候选决定，绑定就与"上游恰好同构"解耦了。
---
--- model 允许缺省：绝大多数绑定就是"这个实例用它自己注册的模型名"，强制写全只会让配置
--- 冗长、并且和上游改名漂移。缺省即回退 profile.target；target 也没有时这条绑定没有意义
--- （转发出去的名字双方都没约定过），由 profile_from_entry 拒绝。
local function build_candidate_bindings(alias, raw)
    if raw == nil or raw == JSON_NULL then return nil end
    if not CS_LEXICON.is_array(raw) then
        return nil, string.format("virtual model %s candidates must be an array of objects", alias)
    end
    local out, seen = {}, {}
    for _, item in ipairs(raw) do
        if type(item) ~= "table" then
            return nil, string.format(
                "virtual model %s candidates entries must be objects with a worker", alias)
        end
        -- worker 是唯一必填项。url 收作同义字段：候选描述的就是一个池成员，UI 表格里
        -- 那一列历来叫 url，两种写法不该有两种语义。
        local raw_worker = rawget(item, "worker")
        if raw_worker == nil or raw_worker == JSON_NULL then
            raw_worker = rawget(item, "url")
        end
        local worker = norm_candidate(raw_worker)
        if not worker then
            return nil, string.format(
                "virtual model %s candidates entries must name a normalized url or worker id", alias)
        end
        local model
        local declared = rawget(item, "model")
        if declared ~= nil and declared ~= JSON_NULL then
            if type(declared) ~= "string" then
                return nil, string.format(
                    "virtual model %s candidate %s model must be a string or null", alias, worker)
            end
            local trimmed = CS_LEXICON.trim(declared)
            if trimmed ~= "" then model = trimmed end
        end
        -- 同一实例出现两次：同一条绑定重复提交（UI 往返、运维手改）就静默去重，绑到两个
        -- 不同模型则必须报 400——"最后一条说了算"会让一次误粘配置悄悄改变路由。
        local previous = seen[worker]
        if previous == nil then
            seen[worker] = model or false
            out[#out + 1] = { worker = worker, model = model }
        elseif previous ~= (model or false) then
            return nil, string.format(
                "virtual model %s candidate %s is bound to two models: %s and %s",
                alias, worker, tostring(previous), tostring(model))
        end
    end
    if #out == 0 then return nil end
    return out
end

--- Normalized, order-preserving, de-duplicated target group for one virtual model.
---
--- 为什么要有这一层（用户裁定 2026-10-02，虚拟模型语义反转）：虚拟模型不是"客户端别名 →
--- 单一上游模型"，它是**日常服务的主入口**，一对多地映射**一组实际模型**，由调度策略在
--- 这一组里选落点。旧形状只有单值 target，于是"一个入口同时对外提供 A 和 B 两个模型"
--- 根本配不出来，只能建两个别名，各自的亲和树与容量口径互相不认识。
---
--- 空数组按"未声明"处理（返回 nil），交给调用方决定回退到 target/candidates：一个写了
--- `targets: []` 的配置要么是手滑要么是 UI 序列化 bug，把它当"声明了零个模型"会在运行期
--- 得到一个永远 503 的入口，而当"没声明"则继续走既有的 target 路径——后者是可用的。
---@return string[]|nil targets, string|nil err
local function build_target_group(alias, raw)
    if raw == nil or raw == JSON_NULL then return nil end
    if not CS_LEXICON.is_array(raw) then
        return nil, string.format("virtual model %s targets must be an array of strings", alias)
    end
    local out, seen = {}, {}
    for _, item in ipairs(raw) do
        if type(item) ~= "string" then
            return nil, string.format(
                "virtual model %s targets entries must be strings", alias)
        end
        local model = CS_LEXICON.trim(item)
        if model == "" then
            return nil, string.format("virtual model %s targets entries must not be blank", alias)
        end
        if not seen[model] then
            seen[model] = true
            out[#out + 1] = model
        end
    end
    if #out == 0 then return nil end
    return out
end

--- The one declared model group of a profile, whatever the entry spelled it as.
--- Precedence is deliberate and is the whole compatibility story:
---   1. an explicit `targets` array (the new primary field);
---   2. a single `target` -> the group of one it always was;
---   3. the per-candidate bindings -> their distinct model names, in first-declaration
---      order, so a candidates-only config keeps routing exactly as it does today
---      without the operator having to restate the group.
--- Returns (group, explicit) where explicit says the operator wrote the `targets` key
--- himself: the snapshot only re-emits that key when it is true, which is what keeps a
--- legacy `{model, target}` row byte-identical on disk instead of growing a second,
--- derived copy of the same name (the phantom-field mistake documented at
--- profile_from_entry's explicit_target note).
local function target_group_of(target, candidates, declared_targets)
    if declared_targets then
        local out = {}
        for i = 1, #declared_targets do out[i] = declared_targets[i] end
        return out, true
    end
    -- 未显式写 targets 时，组是「target 与各候选绑定模型名的并集」。上一轮的多绑定形状
    -- (model + target + candidates 各带 model) 本来就用不同模型名绑不同实例；把它折成
    -- 单元素 target 会让那些绑定被「绑定名必须在组内」判成非法 400。取并集既保住那批
    -- 配置，也正是 1 对多的意思。target 恒在首位：凡是「必须挑一个代表名」的旧读者
    -- 读到的还是组头，与上一轮逐字节一致。
    local out, seen = {}, {}
    local function note(model)
        if type(model) == "string" and model ~= "" and not seen[model] then
            seen[model] = true
            out[#out + 1] = model
        end
    end
    note(target)
    for i = 1, #(candidates or {}) do
        note(candidates[i].model)
    end
    if #out == 0 then return nil, false end
    return out, false
end

--- Context-window override for one virtual model: the *only* per-entry override the
--- new design allows (root ruling 2026-10-02). Absent/blank/null = no override.
local function build_context_window(alias, raw)
    if raw == nil or raw == JSON_NULL then return nil end
    if raw == false or raw == true then
        return nil, string.format("virtual model %s context_window must be a positive integer", alias)
    end
    local n = CS_LEXICON.parse_positive_int(raw)
    if not n then
        return nil, string.format("virtual model %s context_window must be a positive integer", alias)
    end
    return n
end

--- 条目级的档位/能力声明（用户裁定 2026-10-04：effort 放行到虚拟模型入口）。
---
--- 为什么 2026-10-02 停用 per-alias effort 的裁定在这里不适用：那条理由是「一个入口跨
--- N 个引擎，把档位配在入口上对哪个都不诚实」，对 policy 成立——策略会在入口上建亲和树，
--- 配错就把一组裂成 N 棵；但 effort 不建树、不参与亲和，它只是「客户端没说话时代事填一个
--- 档位」，写在入口上与写在卡片上同样诚实（三层阶梯仍然卡片优先，落点引擎自己说的话永远
--- 压过入口）。所以放行 effort / modalities / tool 三个声明位，policy 继续锁在路由页。
---
--- 与 legacy 的 profile.effort 无关：那是 2026-10-02 裁定里「接受、往返、热路径不读」的
--- 弃用字段。这里的四个是新名字、新语义，两套并存且互不干扰。

--- default_effort：空串 / "null" / "default" / null = 「不覆盖」（返回 nil，让下一层说话）；
--- 非法档位 = 拒绝保存（口径照抄 context_window 的校验纪律）。
---@return string|nil level, string|nil err
local function build_entry_default_effort(alias, raw)
    if raw == nil or raw == JSON_NULL then return nil end
    if type(raw) ~= "string" then
        return nil, string.format("virtual model %s default_effort must be a string or null", alias)
    end
    local trimmed = CS_LEXICON.trim(raw)
    local level = CS_FACADE.normalize_effort(trimmed)
    if level == false then
        return nil, string.format(
            "unknown default_effort for virtual model %s: %s (want one of %s)",
            alias, trimmed, CS_LEXICON.EFFORT_LEVELS_JOIN)
    end
    return level
end

--- effort_map：文档形状 { {from=,to=}, ... }（与模型卡片同形）。逐 from 存成查表；
--- to 为空串 / null 表示「这条不改写」，与卡片同一个口径（卡片那边也是空 to 直接跳过）。
---@return table|nil map, string|nil err
local function build_entry_effort_map(alias, raw)
    if raw == nil or raw == JSON_NULL then return nil end
    if not CS_LEXICON.is_array(raw) then
        return nil, string.format(
            "virtual model %s effort_map must be an array of {from,to}", alias)
    end
    local out = {}
    for _, item in ipairs(raw) do
        if type(item) ~= "table" then
            return nil, string.format(
                "virtual model %s effort_map entries must be objects with a from and a to", alias)
        end
        local from_raw = rawget(item, "from")
        local to_raw = rawget(item, "to")
        local from = CS_FACADE.normalize_effort(from_raw)
        if from == false or from == nil then
            return nil, string.format(
                "unknown effort in virtual model %s effort_map: %s (want one of %s)",
                alias, tostring(from_raw or ""), CS_LEXICON.EFFORT_LEVELS_JOIN)
        end
        if to_raw ~= nil and to_raw ~= JSON_NULL and type(to_raw) ~= "string" then
            return nil, string.format(
                "virtual model %s effort_map target for %s must be a string or null", alias, from)
        end
        local to = CS_FACADE.normalize_effort(to_raw)
        if to == false then
            return nil, string.format(
                "unknown effort in virtual model %s effort_map target: %s (want one of %s)",
                alias, tostring(to_raw), CS_LEXICON.EFFORT_LEVELS_JOIN)
        end
        if to then out[from] = to end
    end
    if next(out) == nil then return nil end
    return out
end

--- 条目级模态声明（vision 的操作员声明位）。规范化与卡片同形：text 常开、去重、text 最前。
--- 与卡片的唯一区别是有意的：卡片当年把未知值静默滤掉，条目这一层拒绝保存——操作员写了
--- hologram 就是写错了，替他猜成「没写」会让一个拼错的 vision 声明悄悄变成「不收图」。
---@return string[]|nil caps, string|nil err
local function build_entry_modalities(alias, raw)
    if raw == nil or raw == JSON_NULL then return nil end
    if not CS_LEXICON.is_array(raw) then
        return nil, string.format("virtual model %s modalities must be an array of strings", alias)
    end
    local caps = {}
    for _, item in ipairs(raw) do
        if type(item) ~= "string" then
            return nil, string.format("virtual model %s modalities entries must be strings", alias)
        end
        local cap = CS_LEXICON.lower(CS_LEXICON.trim(item))
        if cap == "" then
            return nil, string.format("virtual model %s modalities entries must not be blank", alias)
        end
        if not CS_LEXICON.MODALITY_SET[cap] then
            return nil, string.format(
                "unknown modality for virtual model %s: %s (want one of %s)",
                alias, cap, table.concat(CS_LEXICON.MODALITY_LEVELS, ", "))
        end
        caps[#caps + 1] = cap
    end
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
    return ordered
end

--- tool use 能力声明：三态。缺键 / null = nil = 「不知道」（不等于 false），读侧据此
--- 继续退到引擎自报；写了 false 就是操作员说了「这个入口不支持工具」，必须落盘成 false。
---@return boolean|nil value, string|nil err
local function build_entry_supports_tool_use(alias, raw)
    if raw == nil or raw == JSON_NULL then return nil end
    if type(raw) ~= "boolean" then
        return nil, string.format(
            "virtual model %s supports_tool_use must be a boolean or null", alias)
    end
    return raw
end

--- 四个能力位的三态装配（缺键 / null = nil = 「不知道」，布尔 = 结论），文案家族照抄
--- build_entry_supports_tool_use。与它同一条纪律：**false 是操作员说的话，必须原样落盘**，
--- 绝不在装配路上与「没说」合并。2026-10-05 起 streaming / reasoning / vision /
--- reasoning_effort 与 tool use 一样有 config 这一层（用户诉求：UI 可配 → 落到
--- /v1/models 的对外声明），解析侧的优先级见 router.lua 的 resolve_model_caps。
---@return boolean|nil value, string|nil err
local function build_entry_supports_flag(alias, field, raw)
    if raw == nil or raw == JSON_NULL then return nil end
    if type(raw) ~= "boolean" then
        return nil, string.format(
            "virtual model %s %s must be a boolean or null", alias, field)
    end
    return raw
end

--- 七个声明字段一起装配；任何一条非法都整条入口拒绝保存（与 context_window 同纪律）。
---@return table|nil fields, string|nil err
local function build_entry_declarations(alias, entry)
    local out = {}
    local default_effort, derr = build_entry_default_effort(alias, rawget(entry, "default_effort"))
    if derr then return nil, derr end
    if default_effort then out.default_effort = default_effort end
    local effort_map, merr = build_entry_effort_map(alias, rawget(entry, "effort_map"))
    if merr then return nil, merr end
    if effort_map then out.effort_map = effort_map end
    local modalities, moderr = build_entry_modalities(alias, rawget(entry, "modalities"))
    if moderr then return nil, moderr end
    if modalities then out.modalities = modalities end
    local tool_use, terr = build_entry_supports_tool_use(alias, rawget(entry, "supports_tool_use"))
    if terr then return nil, terr end
    if tool_use ~= nil then out.supports_tool_use = tool_use end
    -- 四条新能力位走同一个循环：漏一条 = 该字段被静默忽略、往返丢失，而循环让「四条
    -- 都装配」成为结构性事实而不是逐字段的细心。名字与卡片、UI 完全同名（扁平三态，
    -- 与已上线的 supports_tool_use 同形状；刻意不塞进 supports:{} 子对象，那会让
    -- supports_tool_use 变成两条路径并被已钉住它的测试咬住）。
    for _, field in ipairs({ "supports_streaming", "supports_reasoning",
                             "supports_vision", "supports_reasoning_effort" }) do
        local value, ferr = build_entry_supports_flag(alias, field, rawget(entry, field))
        if ferr then return nil, ferr end
        if value ~= nil then out[field] = value end
    end
    if next(out) == nil then return nil end
    return out
end

local function copy_bindings(candidates)
    -- Shallow copy of the binding list: the snapshot and profile_for must not hand out
    -- the live tables, or a caller that edits one row would rewrite the config in place.
    if candidates == nil then return nil end
    local out = {}
    for i = 1, #candidates do
        out[i] = { worker = candidates[i].worker, model = candidates[i].model }
    end
    return out
end

--- Representative upstream model of one profile, i.e. what the *pre-feature* readers
--- (resolve_model, /v1/models 注入, models 文档) key off. A profile with an explicit
--- target keeps it verbatim; a candidates-only profile uses its first explicit model so
--- the alias stays a name those readers understand. Stays nil only when the entry is
--- rejected anyway (profile_from_entry guarantees a string for every accepted profile).
local function representative_target(target, candidates)
    if type(target) == "string" and target ~= "" then return target end
    for i = 1, #(candidates or {}) do
        local model = candidates[i].model
        if type(model) == "string" and model ~= "" then return model end
    end
    return nil
end

--- Shape test for the two pre-validations (document reader and apply_profiles): an
--- entry may carry either a target or a candidates array, so a missing target is only
--- fatal when the row also names no bindings. Element-level errors stay with
--- profile_from_entry; this guards only the wording family the contract pins for
--- "neither half present". Declared next to the builders because cfg_from_document,
--- which is much earlier in the file, has to see it as a local.
--- Same shape test for the new primary field: a row carrying a non-empty `targets`
--- array declares its model group and therefore needs no target of its own.
local function has_target_group(entry)
    if type(entry) ~= "table" then return false end
    local raw = rawget(entry, "targets")
    if raw == nil or raw == JSON_NULL then return false end
    if not CS_LEXICON.is_array(raw) then return true end   -- wrong type: let the builder word it
    return #raw > 0
end

local function entry_has_bindings(entry)
    if type(entry) ~= "table" then return false end
    local raw = rawget(entry, "candidates")
    if raw == nil or raw == JSON_NULL then return false end
    if not CS_LEXICON.is_array(raw) then return true end   -- wrong type: let the builder word it
    return #raw > 0
end

--- 「X 确实是引擎真实模型」的判据（用户裁定 2026-10-07，同名遮蔽方案 A）。
---
--- 为什么必须问引擎而不是问配置：入口名可以遮蔽一个实际模型，前提是那个名字**真的**由某个
--- 引擎提供——否则「入口 X 的组里含 X」就把一个谁都不服务的名字洗白成了合法落点，转发体里
--- 会出现一个上游不认识的 model（正是 root ruling 4 那道链守卫存在要挡的事）。操作员在
--- `targets` 里写下一个名字只是人在打字，不能当引擎的背书，所以判据只取 registry 侧那两个
--- 读数：record_models（引擎答过的广告列表，records.lua 的 models_of）与
--- models_are_verified（这份列表的来源确实是对方 /v1/models 的亲口回答，没探过 = 不算）。
--- 两者取交集，与 candidate_allows_model 在选路侧用的是同一套「只有引擎亲口答过的才算结论」
--- 口径，两条链不会各自定义一个「真实模型」。
---
--- 形状与 declared_cap / declared_util 同一条纪律：registry 优先、缺席就退到「什么都不知道」，
--- 并且**不打 warn**——纯 Lua 单测与网关未起时 registry 缺席是常态而不是误配，喊一行 warn 只
--- 会让 e2e 的日志断言多一个噪音源。返回空集就是「没有任何名字被引擎背书」，四处守卫因此
--- 逐字退回改动前的严格语义（探不着的名字仍按今天处理）。
---@return table<string, boolean>|nil attested @ 名字 -> 是否被引擎背书；nil = 无从知道
local function engine_attested_models()
    local reg = CS_LEXICON.store_registry()
    if reg == nil then return nil end
    if type(reg.records) ~= "function"
        or type(reg.models_are_verified) ~= "function"
        or type(reg.record_models) ~= "function" then
        return nil
    end
    local ok, records = pcall(reg.records)
    if not ok or type(records) ~= "table" then return nil end
    local set = {}
    for i = 1, #records do
        local record = records[i]
        local okv, verified = pcall(reg.models_are_verified, record)
        if okv and verified == true then
            local okm, list = pcall(reg.record_models, record)
            if okm and type(list) == "table" then
                for j = 1, #list do
                    local name = list[j]
                    if type(name) == "string" and name ~= "" then
                        set[name] = true
                    end
                end
            end
        end
    end
    return set
end

--- 一次写入批次的同名遮蔽判据上下文。
---
--- `reload == true` 那份（磁盘快照的读路径）刻意**不查** registry，直接放行同名落点：这条
--- 路径同时是「把已经落盘的配置读回来」，在那里新增一道拒绝会让一份当年合法的配置在某次
--- 巡检空档（或那台实例被摘掉）之后整体读不回来，而 `current()` 读不回配置就**整份退回 env
--- 默认**——等于把网关的全部配置抹平。这正是 `validate_declared_context_windows` 刻意不挂
--- 在读路径上的同一条理由（见 snapshot.lua 那节注释），两条校验必须同生同灭。
--- 写入侧（apply_profiles 与整文档 apply_document）照查：判据只在「谁能被写进来」这一头
--- 说话，落盘之后的字节不再被追问。
---@param opts table|nil @{reload=true: 磁盘快照的读路径,不查引擎读数}
local function new_shadow_context(opts)
    if type(opts) == "table" and opts.reload == true then
        return { reload = true }
    end
    return { attested = engine_attested_models() }
end

--- 「这个名字是该入口自己要遮蔽的那个真实模型」的唯一判据。
---
--- 只认**自己的**名字：`name == alias` 且（读路径放行 或 引擎背书了这个名字）。别人的入口名
--- 永远不算——那仍是 root ruling 4 要挡的链式转发，与它是否同时是个真实模型无关（两个入口抢
--- 同一个对外名字会把「一入口一棵亲和树」和 owned_by 的归属说成两套话）。
---@param ctx table|nil @ new_shadow_context 的产物；nil 当「无从知道」处理
---@param alias string|nil @ 入口名
---@param name string|nil @ 被检查的名字（target / 组内成员 / 绑定名）
---@return boolean
local function may_shadow_own_name(ctx, alias, name)
    if type(alias) ~= "string" or alias == "" then return false end
    if type(name) ~= "string" or name ~= alias then return false end
    if type(ctx) ~= "table" then return false end
    if ctx.reload == true then return true end
    local attested = ctx.attested
    return type(attested) == "table" and attested[name] == true
end

--- One validated profile from one entry (shared by the env and document layers).
--- Returns (profile, nil) or (nil, err); profile carries target plus optional
--- candidates/workers/policy/effort, with unset fields absent (never JSON_NULL).
---
--- target became optional (root ruling 2026-10-01, 虚拟模型多绑定): a profile may
--- instead bind each candidate to its own model, in which case the representative
--- target is derived from the first explicit binding. Both shapes round-trip; the
--- legacy {model, target} entry is untouched by this branch.
local function profile_from_entry(alias, entry, shadow)
    if type(entry) ~= "table" then
        return nil, "virtual model entries must be objects"
    end
    -- The new primary field (root ruling 2026-10-02): one entry maps the virtual name
    -- to a *group* of real models. Read it before target/candidates because the group,
    -- when written, is what the entry means; the two legacy spellings below only fill
    -- in for rows that predate it.
    local declared_group, gerr = build_target_group(alias, rawget(entry, "targets"))
    if gerr then return nil, gerr end
    local declared_target = rawget(entry, "target")
    if declared_target ~= nil and declared_target ~= JSON_NULL and type(declared_target) ~= "string" then
        return nil, string.format("virtual model %s target must be a string or null", alias)
    end
    local target = CS_LEXICON.trim(declared_target or "")
    if target == "" then target = nil end
    -- 同名遮蔽（方案 A）：入口 X 写 target = X 是被允许的形状之一——X 是引擎报过的真实模型，
    -- 转发体收到的 model 就是引擎自己认识的那个 X。判据不在这里放宽的就绪状态：没被背书时
    -- 这一支逐字保持改动前的拒绝与被钉住的文案。
    if target ~= nil and alias == target and not may_shadow_own_name(shadow, alias, target) then
        return nil, string.format("virtual model %s must differ from its target", alias)
    end
    local candidates, cerr = build_candidate_bindings(alias, rawget(entry, "candidates"))
    if cerr then return nil, cerr end
    local group = target_group_of(target, candidates, declared_group)
    -- 有候选但一个模型名都没给（既无 target 也无 candidate.model）时不能在这里报「两半都缺」：
    -- 那条路径下面会精确点到「哪一个候选缺 model」，措辞对操作员有用得多，单测也钉的是它。
    if group == nil and candidates == nil then
        return nil, string.format("virtual model %s needs a target model or candidates", alias)
    end
    group = group or {}
    -- A binding without its own model inherits the profile target; with no target to
    -- inherit the forwarded name would be undefined for that one instance, so it is a
    -- config error rather than something to guess at request time.
    if candidates then
        -- 继承源只能是「操作员亲口写过的名字」：写过的 target，或显式写过的 targets 组头。
        -- 不能退到派生组的组头——派生组会把候选自己声明的模型名也排进去，于是某条没写
        -- model 的绑定会去继承**兄弟候选**的模型名：同一份配置换个候选顺序就得到不同的
        -- 落点模型，而且本该报「no target to inherit」的错会被静默吞掉。
        local inherit = target
        if inherit == nil and declared_group then inherit = declared_group[1] end
        local in_group = {}
        for i = 1, #group do in_group[group[i]] = true end
        for i = 1, #candidates do
            local model = candidates[i].model
            if (model == nil or model == "") and inherit ~= nil then
                candidates[i].model = inherit
                model = inherit
            end
            if model == nil or model == "" then
                return nil, string.format(
                    "virtual model %s candidate %s needs a model (no target to inherit)",
                    alias, candidates[i].worker)
            end
            -- A binding to a name outside the group is a contradiction, not a detail:
            -- selection would never reach that instance for any declared model, or
            -- (worse) a typo'd name would silently pin traffic to a worker that 404s it.
            -- Refuse it here, where the operator sees it, rather than at request time.
            if not in_group[model] then
                return nil, string.format(
                    "virtual model %s candidate %s is bound to %s, which is not one of its targets",
                    alias, candidates[i].worker, model)
            end
        end
    end
    -- 写过 targets 之后 target 只是「代表值」。它落在组外（操作员改了组却没同步改
    -- target）会让 resolve_model / 模型文档去追一个该入口并不提供的名字，所以
    -- sync_virtual_view 对组入口一律改用组头，这里只留一条 warn 把不一致说出来。
    -- 不当场 400 是有意的：apply 是整表替换，一行的过期 target 会连带挡住操作员
    -- 保存其它行；而它在读侧已经不驱动任何行为，剩下的只是磁盘上的历史字节。
    -- 注意这与「绑定名必须在组内」不同——那条会决定转发名，所以必须硬拒。
    if declared_group and target ~= nil then
        local inside = false
        for i = 1, #declared_group do
            if declared_group[i] == target then inside = true break end
        end
        if not inside then
            CS_LEXICON.ngx_log_warn("luarouter: virtual model ", alias, " carries target ", target,
                " outside its declared targets; using the group head as representative")
        end
    end
    local profile = {
        -- The representative stays the single name every pre-feature reader keys off
        -- (resolve_model, /v1/models, the effort/ctx lookups). Under the new semantics
        -- it is only a representative: the group is authoritative.
        target = target or representative_target(target, candidates) or group[1],
        targets = group,
    }
    -- The derived representative is held to the same rule as a written target: without
    -- it a candidates-only entry that names itself gets rejected by the batch chain
    -- check with the "another virtual model" wording, while the identical shape written
    -- as a target gets "must differ from its target". Same mistake, one message.
    -- 同名遮蔽下这条与上面那条同判据：candidates-only 的入口 X 把所有候选都绑在真实模型 X 上
    -- 是合法形状（引擎认识 X），所以两处必须共用 may_shadow_own_name，否则同一个配置在
    -- 「写了 target」与「从候选推出代表值」两条路上会得到两个不同的答案。
    if profile.target == alias and not may_shadow_own_name(shadow, alias, profile.target) then
        return nil, string.format("virtual model %s must differ from its target", alias)
    end
    -- 记下 target 是操作员写的还是从候选推出来的。快照必须只回写"写过的"字段：一个
    -- candidates-only 配置如果被隐式补上 target，磁盘文档就长出一个没人声明的模型名，
    -- 之后所有 reader（effort 卡、policy hint、/v1/models）都会跟着这个幻影名字找配置。
    if target ~= nil then profile.explicit_target = true end
    -- Same rule as explicit_target: the group is written back only when the operator
    -- wrote the `targets` key. Everything else (a legacy pair, a candidates-only row)
    -- re-derives it at read time, so the disk document never grows a field nobody typed.
    if declared_group then profile.explicit_targets = true end
    local context_window, cwerr = build_context_window(alias, rawget(entry, "context_window"))
    if cwerr then return nil, cwerr end
    if context_window then profile.context_window = context_window end
    if candidates then profile.candidates = candidates end
    local workers, werr = build_candidates(alias, rawget(entry, "workers"))
    if werr then return nil, werr end
    if workers then profile.workers = workers end
    -- "" / "auto" / "null" / null are the UI's "follow the global/default"
    -- answers and omit the field; only a genuinely unknown name is a 400, and a
    -- non-string is a type error (same wording family as the policy handlers).
    if rawget(entry, "policy") ~= nil and entry.policy ~= JSON_NULL then
        if type(entry.policy) ~= "string" then
            return nil, string.format("virtual model %s policy must be a string or null", alias)
        end
        local trimmed = CS_LEXICON.trim(entry.policy)
        local name = CS_FACADE.normalize_policy(trimmed)
        if name == false then
            return nil, string.format("unknown policy for virtual model %s: %s (want one of %s)",
                alias, trimmed, CS_LEXICON.POLICY_NAMES_JOIN)
        end
        if name then
            profile.policy = name
            -- Root ruling 2026-10-02: scheduling policy belongs to the routing page
            -- (global / model_policies), not to the virtual-model entry. The field is
            -- still accepted and round-tripped so an exported-and-re-imported document
            -- keeps validating, and it is *not* consulted on the hot path any more.
            -- Saying nothing there would make the row silently stop doing what its
            -- name promises, so the load answers once per parse.
            CS_LEXICON.ngx_log_warn("luarouter: virtual model ", alias,
                " declares policy=", name,
                ", which no longer applies there (configure it on the routing page)")
        end
    end
    if rawget(entry, "effort") ~= nil and entry.effort ~= JSON_NULL then
        if type(entry.effort) ~= "string" then
            return nil, string.format("virtual model %s effort must be a string or null", alias)
        end
        local trimmed = CS_LEXICON.trim(entry.effort)
        local level = CS_FACADE.normalize_effort(trimmed)
        if level == false then
            return nil, string.format("unknown effort for virtual model %s: %s (want one of %s)",
                alias, trimmed, CS_LEXICON.EFFORT_LEVELS_JOIN)
        end
        if level then
            profile.effort = level
            -- Same ruling and the same honesty rule as policy above: the effort ladder
            -- is per *engine*, so it lives on the model card (model_effort /
            -- model_configs), keyed by the real model a request lands on.
            CS_LEXICON.ngx_log_warn("luarouter: virtual model ", alias,
                " declares effort=", level,
                ", which no longer applies there (configure it on the model card)")
        end
    end
    -- 条目级的四个新声明位（2026-10-04 裁定放行；理由见 build_entry_declarations）。
    -- 必须在 rawget 白名单里显式写出：profile_from_entry 是逐字段读取，漏一个字段就等于
    -- 该字段被静默忽略、往返丢失。
    local declarations, decl_err = build_entry_declarations(alias, entry)
    if decl_err then return nil, decl_err end
    if declarations then
        profile.default_effort = declarations.default_effort
        profile.effort_map = declarations.effort_map
        profile.modalities = declarations.modalities
        profile.supports_tool_use = declarations.supports_tool_use
        -- 四条能力位与 tool use 同一条往返链（漏一条 = 磁盘上那一份永远读不回来）
        profile.supports_streaming = declarations.supports_streaming
        profile.supports_reasoning = declarations.supports_reasoning
        profile.supports_vision = declarations.supports_vision
        profile.supports_reasoning_effort = declarations.supports_reasoning_effort
    end
    return profile, nil
end

--- One validated alias -> profile table from a decoded batch, chain-checked.
--- Shared by cfg_from_document and apply_profiles so the two writers cannot drift.
---@param entries table[] @ document-shape rows
---@param existing table|nil @ live alias -> profile map for the cross-batch chain check
---@param shadow table|nil @ 同名遮蔽判据上下文（new_shadow_context）；nil = 写入侧口径，
---  现查 registry 的引擎背书。**磁盘快照的读路径必须显式传 {reload=true}**：在那里新增的
---  拒绝会让一份当年合法的配置在下次 reload 整体退回 env 默认（与 validate_declared_context_windows
---  刻意不挂读路径同一条理由）。
---@return table|nil built, string|nil err
-- 前向声明：下面两个链守卫是 local function，定义在本函数之后。Lua 里没有这行声明的话，
-- build_profiles 里的同名标识符会退化成**全局读**（nil），任何一次写 virtual_models 都会
-- 崩在 "attempt to call global 'assert_no_alias_chain'"。
local assert_no_alias_chain, assert_bindings_no_alias

local function build_profiles(entries, existing, shadow)
    -- nil 是「调用方没表态」= 写入侧（apply_profiles 与整文档 apply_document 都是），
    -- 因此现查引擎读数；读路径由 cfg_from_document 显式传 reload 上下文。
    if shadow == nil then shadow = new_shadow_context(nil) end
    local built = {}
    for _, entry in ipairs(entries or {}) do
        if type(entry) ~= "table" then
            return nil, "virtual model entries must be objects"
        end
        local alias = type(entry.model) == "string" and CS_LEXICON.trim(entry.model) or ""
        if alias == "" then
            -- 文案回到被钉住的措辞家族：别名缺失与 target 缺失同属「这条 entry 两半没给全」，
            -- 单测钉的是 model and target 这一族，不该因为重构而换话术。
            return nil, "virtual model entries need both model and target"
        end
        -- Pre-validation only words the "declared nothing at all" case; element-level
        -- errors stay with profile_from_entry (the contract pins this wording family).
        if (type(entry.target) ~= "string" or CS_LEXICON.trim(entry.target) == "")
            and not entry_has_bindings(entry)
            and not has_target_group(entry) then
            -- 一句里同时含 needs a target model（契约家族）与 model and target（单测家族）：
            -- 同一个错误在 document / apply 两条写入路径上必须同一种话术。
            return nil, string.format(
                "virtual model %s needs a target model (an entry needs both model and target)",
                alias)
        end
        local profile, perr = profile_from_entry(alias, entry, shadow)
        if not profile then return nil, perr end
        built[alias] = profile
    end
    for _, alias in ipairs(CS_LEXICON.sorted_keys(built)) do
        local profile = built[alias]
        local cerr = assert_no_alias_chain(built, alias, profile.target, shadow)
        if not cerr then
            cerr = assert_bindings_no_alias(built, existing, alias, profile, shadow)
        end
        if not cerr then
            -- Every model in the group is a name the gateway will forward, so every one
            -- of them is held to the no-chain rule (root ruling 4). Checking only the
            -- representative would let `targets: [some-other-alias]` through, and the
            -- forwarded body would then name a name no upstream knows.
            for i = 1, #(profile.targets or {}) do
                local member = profile.targets[i]
                cerr = assert_no_alias_chain(built, alias, member, shadow)
                -- 存量入口这一半要自己判（assert_no_alias_chain 按设计只看得见本批 built）：
                -- 编辑一个**已存在**的同名入口时，alias 自己就在存量表里，直接查 existing 会
                -- 把「把自己的真实模型名放进组里」读成「引用了另一个入口」，那正是今天连自己
                -- 都拦的形状。判据与组头/绑定两处共用 may_shadow_own_name，只放过自己的名字，
                -- 别人的入口名继续拒绝（两个入口抢同一个对外名字会打掉「一入口一棵亲和树」与
                -- owned_by 的归属，硬规则 9③）。
                if not cerr and not may_shadow_own_name(shadow, alias, member)
                    and existing and existing[member] ~= nil then
                    cerr = string.format(
                        "virtual model %s target must not be another virtual model: %s",
                        alias, member)
                end
                if cerr then break end
            end
        end
        if cerr then return nil, cerr end
    end
    return built, nil
end

--- 组内/代表值的一个名字如果命中**本批另一个入口**，它是链式转发，必须拒绝（root ruling 4）。
---
--- 同名遮蔽（方案 A）唯一让开的一条是「这个名字就是本入口自己的名字，而且引擎背书过它」：
--- 那时 target/组成员指的是那台实际模型，入口遮蔽它、它只作为落点存在，不是链式转发。
--- 「另一个入口」与「同名真实模型」的区分就靠 built 的键 + 名字是否等于自己：built 的键是
--- 入口名，所以别人的入口名照样命中；自己的名字命中是因为自己刚进 built，那一支由
--- may_shadow_own_name 精确摘掉。被引擎背书的**别人的**入口名不放行——入口赢的规则对同一个
--- 对外名字只允许有一个主人。
---@param built table|nil @ alias -> profile for the batch being validated
---@param alias string @ 入口名
---@param target string|nil @ 被检查的名字
---@param shadow table|nil @ 同名遮蔽判据上下文
assert_no_alias_chain = function(built, alias, target, shadow)
    if built == nil then return nil end
    if built[target] ~= nil and not may_shadow_own_name(shadow, alias, target) then
        return string.format("virtual model %s target must not be another virtual model: %s",
            alias, target)
    end
    return nil
end

--- Per-worker capacity caps for the declaration layer.
---
--- 规范化一律走 registry.cap_limit（唯一权威实现）：声明层与 POST/PUT /workers 的 API 层
--- 必须对同一个输入给出同一个规范值，否则「UI 里填 2.5」与「curl 里填 2.5」会落进池子两
--- 条不同的记录，drift 判定也会永远收敛不掉。registry 用 store_registry() 的惰性 pcall
--- 取（与 reconcile 同一入口）：本模块在纯 Lua 单测里会在 registry 缺席或被 stub 替换的
--- 情况下解析声明，此时退化成本函数末尾那 6 行同语义兜底，并打一条 warn——两侧一致性由
--- 单测用同一组输入对齐断言，兜底路径本身不作为生产口径。
---
--- 为什么 nil 是「不限」而不是 0：记录里根本没有这个键，读取侧（registry.capacity_exclusion
--- / info）先过 cap_limit，<=0 与非数一律折成 nil。所以声明侧「没写这个字段」与写了个
--- 无效值，和记录侧「键缺席」，三者必须读成同一件事；drift 判定两侧都先规范化再比较，
--- 否则「声明不限」对「池里无限」会被判成漂移，30 秒自愈就永远在重写同一个 worker。
local function declared_cap(value, integer)
    local reg = CS_LEXICON.store_registry()
    if reg and type(reg.cap_limit) == "function" then
        return reg.cap_limit(value, integer)
    end
    local number = tonumber(value)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge or number <= 0 then
        return nil
    end
    CS_LEXICON.ngx_log_warn("luarouter config upstream cap normalization without registry (worker stub?)")
    return integer and math.floor(number) or number
end

--- Utilisation ceiling for the declaration layer (doc/caps-redesign-2026-10-06.md section 1).
---
--- 它是 declared_cap 之外的**另一个档**，不是 declared_cap(value, true)：cap_limit 把一切
--- <= 0 折成 nil，而 util 档必须保住 0 这个读数 —— 0 是「卡一有利用率就算到顶」的极严档，
--- 是一个结论而不是沉默。于是 -1（非数、缺省同归此支）与 0 在这里读成两件不同的事，而并发
--- 档里两者本来就都塌成「不限」，两档无法共用一个归一器。
---
--- 其余纪律与 declared_cap 一致，为的是 drift / patch 对同一含义只见到一个值：非数、NaN、
--- ±inf、负数、小数、>100 一律归一成 nil = 不限，存储侧写成**键缺席**（绝不写显式 null）。
--- 小数刻意判 nil 而不是 floor：DCGM 的利用率读数本身是整数百分比，55.5 没有诚实读法，而
--- 「操作员没说一个整百分比」的安全读法是让门保持敞开（读数未知绝不 cost capacity），
--- 而不是悄悄变成 55 去提前排除。
---
--- 与 declared_cap 同一条 registry 优先口径：registry 在场时用它的 util_limit 当权威实现，
--- 让声明层与 POST/PUT /workers 对同一输入落进同一条记录；末尾几行只是纯 Lua 单测口径的
--- 兜底（registry 缺席或被 stub 换掉时），并打一条 warn，不作为生产口径。
local function declared_util(value)
    local reg = CS_LEXICON.store_registry()
    if reg and type(reg.util_limit) == "function" then
        return reg.util_limit(value)
    end
    local number = tonumber(value)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge
        or number < 0 or number > 100 or math.floor(number) ~= number then
        return nil
    end
    CS_LEXICON.ngx_log_warn("luarouter config upstream cap normalization without registry (worker stub?)")
    return number
end

--- Chain guard for the per-candidate bindings.

--- 一条绑定如果指向另一个别名，选到那个候选后转发体里的 model 就成了别名本身，而它根本
--- 不是上游认识的名字：轻则 404，重则（对端也是本网关）成环。target 只覆盖代表值，其余
--- 候选必须在写入前一起查，否则"把 target 改成一池各绑各的"这条编辑路径会绕过 root
--- ruling 4。文案沿用 target 那一族（契约锚定的是措辞家族，不是字段名）。
---@param built table|nil @ alias -> profile for the batch being validated
---@param existing table|nil @ live alias -> target map (checked when built does not know it)
---@param shadow table|nil @ 同名遮蔽判据上下文（may_shadow_own_name 用）
---@return string|nil err
assert_bindings_no_alias = function(built, existing, alias, profile, shadow)
    if type(profile) ~= "table" or profile.candidates == nil then return nil end
    for i = 1, #profile.candidates do
        local model = profile.candidates[i].model
        if type(model) == "string" and model ~= "" then
            -- 绑定名等于入口名在遮蔽下是合法形状：X 是引擎报过的真实模型，转发体里的 model
            -- 就是它自己（lr_bound_model 与之一致）。没被背书时逐字保持改动前的拒绝与文案。
            if model == alias and not may_shadow_own_name(shadow, alias, model) then
                return string.format("virtual model %s must differ from its target", alias)
            end
            local cerr = assert_no_alias_chain(built, alias, model, shadow)
            -- 与组内成员那一条同判据：自己的名字不等于「另一个入口」，即使自己就在存量表里。
            if not cerr and not may_shadow_own_name(shadow, alias, model)
                and existing and existing[model] ~= nil then
                cerr = string.format(
                    "virtual model %s target must not be another virtual model: %s", alias, model)
            end
            if cerr then return cerr end
        end
    end
    return nil
end

-- ------------------------------------------------- 跨子模块直调的原文 local
-- 这些函数在原文里是同文件 local 直调、从未挂在 _M 上；拆开后由调用方直接 require 本表
-- 调用（不经 facade，所以既不是新增导出、也不给单测多开一个可替换点）。
_M.build_profiles = build_profiles
-- 同名遮蔽判据（方案 A）：入口名与引擎真实模型名的判据只有这一份实现。readers.lua 的
-- ctx_cap 用它决定「这个名字的卡片是不是落点实例的卡」，与四处写入守卫共用同一套引擎读数，
-- 不允许两处各定义一个「真实模型」。
_M.copy_bindings = copy_bindings
_M.engine_attested_models = engine_attested_models
_M.may_shadow_own_name = may_shadow_own_name
_M.new_shadow_context = new_shadow_context
_M.declared_cap = declared_cap
_M.declared_util = declared_util
_M.norm_pool_url = norm_pool_url

return _M
