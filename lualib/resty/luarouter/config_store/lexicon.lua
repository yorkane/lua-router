-- resty.luarouter.config_store.lexicon
-- P2-P6：通用 helper、词表常量、JSON 形状小工具、对端模块（registry / luarouter.config）
-- 的惰性取用，以及 P1「空 = 没说」的快照判定。
--
-- 由 lualib/resty/luarouter/config_store.lua 拆分而来：函数体逐行原样搬家，只调整 require 与
-- 跨模块接线（doc/refactor-arch-2026-10-05.md §1–§2）。原文里经 _M.x() 的自调 → 经 CS_FACADE
-- 表调用（保住单测换桩的可拦截性逐点一致）；原文里的同文件 local 直调 → 直接 require 对端
-- 子模块的共享表调用（不进 facade 导出面，_M 契约因此逐名不变）。
local CS_FACADE = require "resty.luarouter.config_store"

local _M = {}

local cjson = require "cjson.safe"

local EMPTY_ARRAY_MT = cjson.empty_array_mt

local JSON_NULL = cjson.null

-- Env: comma/semicolon-separated list of effort levels the picker understands.
local EFFORT_LEVELS = { "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra" }

local EFFORT_SET = {}
for _, v in ipairs(EFFORT_LEVELS) do EFFORT_SET[v] = true end

local EFFORT_LEVELS_JOIN = table.concat(EFFORT_LEVELS, ", ")

-- Routing policies the /_ui/config/policy endpoint accepts: the same eight
-- names resty.luarouter.config (POLICIES) dispatches on, spelled here so the
-- write side can reject an unknown name with 400 instead of letting policy.new
-- collapse it to round_robin at request time. Keep the three lists in sync.
local POLICY_NAMES = { "random", "round_robin", "cache_aware", "power_of_two",
                       "prefix_hash", "manual", "bucket", "consistent_hashing" }

local POLICY_SET = {}
for _, v in ipairs(POLICY_NAMES) do POLICY_SET[v] = true end

local POLICY_NAMES_JOIN = table.concat(POLICY_NAMES, ", ")

-- resty.luarouter.config one_of("SMG_POLICY", "cache_aware", POLICIES): the
-- env layer of the policy chain, mirrored here for the UI display only.
local ENV_POLICY_DEFAULT = "cache_aware"

-- Capability toggles the Config page exposes per model; text is always on.
local MODALITY_LEVELS = { "text", "image", "video", "audio" }

local MODALITY_SET = {}
for _, v in ipairs(MODALITY_LEVELS) do MODALITY_SET[v] = true end

local SNAPSHOT_TTL = 0.5  -- seconds a worker may reuse a snapshot read from disk

--- An empty snapshot is not an answer. cjson decodes {} to a table with no keys, and
--- that is exactly the shape a first deployment leaves behind when the JSON file was
--- {} and got imported into the database: snapshot_of() never produces it (it always
--- emits the ten section keys), so nothing that came through the gateway can look
--- like it. Treating it as "the store did not speak" is what keeps the env layer
--- reachable after such an import -- current() merges two whole layers, never field
--- by field, so one vacuous layer silences the other forever.
---
--- The section-key test is what keeps this from becoming a different bug: "the
--- operator emptied everything" is a real answer (a snapshot whose ten arrays are all
--- empty must still win over the env seed layer, or deleting the last upstream would
--- resurrect the LMR_UPSTREAMS_FILE rows). So a document that carries any section key
--- at all counts as an answer no matter how empty its contents are; only a table with
--- no section keys *and* nothing but empty containers / nulls in it -- what a hand
--- dropped {} or a wiped pre-store config looks like -- is silence.
local SNAPSHOT_SECTIONS = {
    "default_effort", "effort_map", "model_ctx", "model_context_limit",
    "model_effort", "model_configs", "virtual_models", "policy",
    "model_policies", "upstreams", "models_virtual_only",
}

local function value_says_nothing(value)
    if value == nil or value == JSON_NULL then return true end
    if type(value) == "table" then return next(value) == nil end
    return false
end

local function snapshot_is_empty(snap)
    if type(snap) ~= "table" then return true end
    if next(snap) == nil then return true end
    for _, key in ipairs(SNAPSHOT_SECTIONS) do
        if rawget(snap, key) ~= nil then return false end
    end
    for _, value in pairs(snap) do
        if not value_says_nothing(value) then return false end
    end
    return true
end

local function snapshot_is_hollow(snap)
    return type(snap) ~= "table" or snapshot_is_empty(snap)
end

-- ------------------------------------------------------------------ helpers

local function re_gsub(subject, pattern, repl)
    local out = ngx.re.gsub(subject, pattern, repl, "jo")
    if out == nil then return subject end
    return out
end

--- Split `subject` on a PCRE delimiter pattern. Empty pieces are dropped, which
--- is fine for every delimiter used here.
---
--- Walked with repeated anchored searches rather than gmatch: this build's
--- ngx.re.gmatch hands back a bare capture array (m[0] is the match, and
--- m.start / m.stop are only filled when the pattern has capture groups), so the
--- positions a delimiter walk needs are not available. `ctx.pos` advances the
--- search, and the two-state shape of the match value is never inspected.
local function re_split(subject, pattern)
    local out = {}
    if subject == nil or subject == "" then return out end
    local ctx = { pos = 1 }
    local pos = 1
    local len = #subject
    while pos <= len do
        ctx.pos = pos
        local from, to, err = ngx.re.find(subject, pattern, "jo", ctx)
        if err then
            ngx.log(ngx.ERR, "luarouter re_split failed: ", err)
            out[#out + 1] = subject:sub(pos)
            return out
        end
        if not from then
            out[#out + 1] = subject:sub(pos)
            return out
        end
        local piece = subject:sub(pos, from - 1)
        if piece ~= "" then out[#out + 1] = piece end
        pos = to + 1
    end
    return out
end

local function trim(value)
    if type(value) ~= "string" then return value end
    return re_gsub(re_gsub(value, [[^\s+]], ""), [[\s+$]], "")
end

local function lower(value)
    return (tostring(value):lower())
end

--- nil = "not set"; false = rejected value (callers word their own error).
function _M.normalize_effort(value)
    if value == nil then return nil end
    if type(value) ~= "string" then return false end
    local v = lower(trim(value))
    if v == "" or v == "null" or v == "default" then return nil end
    if EFFORT_SET[v] then return v end
    return false
end

function _M.effort_levels()
    return EFFORT_LEVELS
end

--- nil = "not set"; false = rejected value (same shape as normalize_effort).
function _M.normalize_policy(value)
    if value == nil then return nil end
    if type(value) ~= "string" then return false end
    local v = lower(trim(value))
    if v == "" or v == "null" or v == "default" or v == "auto" then return nil end
    if POLICY_SET[v] then return v end
    return false
end

function _M.policy_names()
    return POLICY_NAMES
end

--- Positive integer or nil; keeps 1.5 and "abc" out of the ctx tables.
local function parse_positive_int(value)
    if type(value) == "number" then
        if value ~= value or value < 1 or math.floor(value) ~= value then return nil end
        return value
    end
    if type(value) ~= "string" then return nil end
    local s = trim(value)
    if s == "" then return nil end
    if ngx.re.find(s, [[^\d+$]], "jo") == nil then return nil end
    local n = tonumber(s)
    if not n or n < 1 then return nil end
    return n
end

--- "a:b, c;d" -> { {a,b}, {c,d} }; an empty left side drops the row, the right
--- side survives trimmed (possibly empty) so callers can filter it themselves.
local function parse_pairs(raw)
    local pairs_list = {}
    if type(raw) ~= "string" then return pairs_list end
    for _, part in ipairs(re_split(raw, [[[,;\n]+]])) do
        part = trim(part)
        if part ~= "" then
            local from, to = part:match("^([^:]-):(.*)$")
            if from then
                from = trim(from)
                if from ~= "" then
                    pairs_list[#pairs_list + 1] = { from, trim(to) }
                end
            end
        end
    end
    return pairs_list
end

--- "text+image", "text,image" -> { "text", "image" } with text always first.
local function parse_caps(raw)
    local caps, seen = {}, {}
    for _, cap in ipairs(re_split(lower(trim(tostring(raw or ""))), [[[+, ]+]])) do
        cap = trim(cap)
        if MODALITY_SET[cap] and not seen[cap] then
            seen[cap] = true
            caps[#caps + 1] = cap
        end
    end
    -- text is always on (Rust from_env inserts it unconditionally)
    table.insert(caps, 1, "text")
    local dedup, order = {}, {}
    for _, cap in ipairs(caps) do
        if not dedup[cap] then dedup[cap] = true order[#order + 1] = cap end
    end
    return order
end

--- Log helper behind a guard: unit caliber carries a stubbed ngx, and the
--- master process may reach a logger-free moment.
local function ngx_log_warn(...)
    if ngx and ngx.log then
        pcall(ngx.log, ngx.WARN, ...)
    end
end

--- JSON null placeholder so absent fields still render as explicit nulls.
--- True when a decoded JSON value should be walked as an array. cjson gives no
--- marker for {}, so an empty table counts as an array; a table with only hash
--- keys is an object and fails.
local function is_array(v)
    if type(v) ~= "table" then return false end
    return #v > 0 or next(v) == nil
end

--- 操作员勾选的 reasoning_effort 档位表（用户诉求 2026-10-08：探测上游允许的档位，
--- 并允许手动添加 / 取消）。**nil = 没说**（该维度让位给引擎自报），**false = 形状不对、
--- 整条拒绝** ——与 normalize_effort 同一套「nil 沉默 / false 结论」的三态口径，调用方据此
--- 措辞报错。放在 is_array 之后：这两个是文件内 local，写成前向引用会掉到全局上。
---
--- 接受两种拼写，归一成 registry 阶梯的同一形状 { {value, label?, default}, ... }：
---   * 字符串数组 ["low","high","max"]（管理台勾选框发的就是这个）
---   * 对象数组 [{value,label,default}, ...]（从 /v1/models 抄回来的那份）
--- 归一成同一形状的意义：对外读数里「操作员说的」与「引擎自报的」在客户端不可区分，
--- 客户端不必知道这个数字是谁给的，也无需为此分叉两套读法。
---
--- 逐条纪律：
---   * 档位名一律过 normalize_effort，未知名字 = 整条拒绝而不是悄悄丢掉。勾选框的值来自
---     词表，正常路径不会触发；这个拒绝是为手改 JSON 的操作员准备的——一个拼错的档位名
---     会被客户端原样发给引擎并在那里 400，比保存失败难查得多。
---   * 输入顺序原样保留，**不按词表排序**：阶梯是客户端 picker 的显示顺序，操作员勾选的
---     先后就是他希望客户端看到的先后，替他重排等于改他的声明。
---   * default 至多一个为真：多余的 true 改 false（输出面 apply_default_ladder_rung 也做
---     同样收口，这里先收是为了让磁盘上那份字节本身自洽，往返不产生抖动）。
---
--- 本函数**保留**洗空的 {}（不塌成 nil）：它把「形状判定」与「这一族的三态语义」分开，
--- 后者由唯一写入者 merge_model_patch 收口 —— 那里把空数组折回「没说」（见其注释）。
--- 洗成 nil 会让「合法但为空」与「形状不对」两种输入在调用点再也分不开。
---@param value any
---@return table|false|nil
function _M.normalize_effort_ladder(value)
    if value == nil then return nil end
    if not is_array(value) then return false end
    local out, seen = {}, {}
    local has_default = false
    for i = 1, #value do
        local raw = value[i]
        local name, label, is_default
        if type(raw) == "string" then
            name = raw
        elseif type(raw) == "table" then
            name = raw.value or raw.name or raw.effort
            if type(raw.label) == "string" then
                local candidate = trim(raw.label)
                if candidate ~= "" then label = candidate end
            end
            is_default = raw["default"] == true or raw.is_default == true
        else
            return false
        end
        if type(name) ~= "string" then return false end
        local normalized = _M.normalize_effort(name)
        if normalized == false or normalized == nil then return false end
        if seen[normalized] then
            -- 重复的名字带着 default 而已在表里的那份没带：把标记补到已有的那一档，
            -- 而不是追加一条重复项。丢标记会让 picker 没有预选，补标记才是重排输入的本意。
            if is_default and not has_default then
                for j = 1, #out do
                    if out[j].value == normalized then
                        out[j]["default"] = true
                        has_default = true
                        break
                    end
                end
            end
        else
            seen[normalized] = true
            local rung = { value = normalized }
            if label then rung.label = label end
            if is_default and not has_default then
                rung["default"] = true
                has_default = true
            end
            out[#out + 1] = rung
        end
    end
    return out
end

local function nul(value)
    if value == nil then return JSON_NULL end
    return value
end

--- 布尔开关的读数真值表：true、以及 "true"/"1"/"yes"/"on" 这四种写法算开，其余一律关。
--- 与 router.lua 的 models_advertise.truthy 同一套口径（两处读数必须给出同一个答案，
--- 否则磁盘层与环境层各说一遍），也刻意「不认识即关」而不是「非假即真」：一个写错的
--- 字符串该退回缺省行为，而不是把一个改变对外形状的开关于 inadvertent 打开。
local function advertise_truthy(value)
    if value == true then return true end
    if type(value) ~= "string" then return false end
    local v = lower(trim(value))
    return v == "true" or v == "1" or v == "yes" or v == "on"
end

--- cjson renders an empty table as {} unless it carries the array metatable.
local function arr(list)
    if #list == 0 then return setmetatable({}, EMPTY_ARRAY_MT) end
    return list
end

local function sorted_keys(map)
    local keys = {}
    for k in pairs(map or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

---registry module for the pool helpers, required once (the pure-Lua unit tests
---never reach this path, so the pcall is only about a missing module on a box).
local cached_store_registry

local function store_registry()
    if cached_store_registry ~= nil then
        return cached_store_registry or nil
    end
    local ok, mod = pcall(require, "resty.luarouter.registry")
    cached_store_registry = (ok and type(mod) == "table") and mod or false
    return cached_store_registry or nil
end

--- Unit hook: forget the lazily required registry/router modules so a test can
--- run both the "registry absent" and "registry stubbed" reconcile passes. Only
--- the pure-Lua tests call this; production never resets a loaded module.
function _M._reset_pool_module_caches()
    cached_store_registry = nil
    cached_pool_config = nil
    CS_FACADE._file_cache = nil
    CS_FACADE._file_cache_at = 0
    CS_FACADE._env_defaults = nil
    CS_FACADE._policy_view_dirty = true
    CS_FACADE.reset_env_upstreams_cache()
end

---Router config for the pool knobs, or nil when the router is not initialised.
---Cached: this is on the path of every /props probe.
local cached_pool_config

local function store_config()
    if cached_pool_config ~= nil then
        return cached_pool_config or nil
    end
    local ok, luarouter = pcall(require, "resty.luarouter")
    if ok and type(luarouter) == "table"
        and type(luarouter.config) == "function" then
        local good, conf = pcall(luarouter.config)
        if good and type(conf) == "table" then
            cached_pool_config = conf
            return conf
        end
    end
    cached_pool_config = false
    return nil
end

-- ------------------------------------------------- upstream / profile helpers
--
-- The upstreams section (doc/gap-virtual-models.md 3.1) stores pool membership
-- by *normalized* url, and virtual profiles reference pool members the same way.
-- Normalization is reimplemented here rather than delegated to registry's
-- normalize_url so validation runs in the pure-Lua unit caliber (no ngx.re) and
-- config_store keeps no hard dependency on the pool module; the semantics match
-- (lowercase scheme + host, trailing slashes stripped, http(s) only) and the
-- reconcile path additionally pcall-delegates to registry when it is loadable.

-- ------------------------------------------------- 跨子模块直调的原文 local
-- 这些函数在原文里是同文件 local 直调、从未挂在 _M 上；拆开后由调用方直接 require 本表
-- 调用（不经 facade，所以既不是新增导出、也不给单测多开一个可替换点）。
_M.EFFORT_LEVELS_JOIN = EFFORT_LEVELS_JOIN
_M.ENV_POLICY_DEFAULT = ENV_POLICY_DEFAULT
_M.MODALITY_LEVELS = MODALITY_LEVELS
_M.MODALITY_SET = MODALITY_SET
_M.POLICY_NAMES = POLICY_NAMES
_M.POLICY_NAMES_JOIN = POLICY_NAMES_JOIN
_M.SNAPSHOT_TTL = SNAPSHOT_TTL
_M.advertise_truthy = advertise_truthy
_M.arr = arr
_M.is_array = is_array
_M.lower = lower
_M.ngx_log_warn = ngx_log_warn
_M.nul = nul
_M.parse_caps = parse_caps
_M.parse_pairs = parse_pairs
_M.parse_positive_int = parse_positive_int
_M.snapshot_is_empty = snapshot_is_empty
_M.snapshot_is_hollow = snapshot_is_hollow
_M.sorted_keys = sorted_keys
_M.store_config = store_config
_M.store_registry = store_registry
_M.trim = trim

return _M
