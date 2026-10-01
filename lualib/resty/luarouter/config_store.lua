-- RuntimeConfig for the lua-router: the /_ui/config* document, its validation,
-- and the atomic disk persistence behind LMR_CONFIG_FILE.
--
-- Mirrors gateway/src/runtime_config.rs: same sections (default_effort,
-- effort_map, model_ctx, model_effort, model_configs, virtual_models), the same
-- eight effort levels, the same validation messages, and the same snapshot
-- (array) shape on disk so a config.json written by the Rust gateway loads
-- here unchanged.
--
-- nginx runs several worker processes, so a process-global table (the Rust
-- model) is not enough. Storage order is:
--   1. ngx.shared.luarouter_config   (declared by core server.conf, if present)
--   2. LMR_CONFIG_FILE               (atomic rewrite, read back with a short TTL)
--   3. env defaults                  (LMR_* baseline)
-- Writes update all available layers so every worker sees the change.
--
-- Outbound control-plane HTTP (the llm-watcher model-map proxy) also lives
-- here, as a dependency-free cosocket client: _M.raw_request / _M.request_json.
-- props.lua reuses it rather than requiring lua-resty-http, which the image is
-- not guaranteed to ship.

local cjson = require "cjson.safe"

local _M = {}

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

local DICT_NAME = "luarouter_config"
local DICT_KEY = "runtime_config"
-- Cheap cross-worker invalidation token for the policy readers (policy.lua calls
-- this on the hot path; it is a plain shdict get with no JSON decode).
local REV_KEY = "policy_revision"
-- Cross-process token for the upstreams reconcile self-heal (contract 3.1):
-- written after every successful reconcile, read by init.lua's 30s timer. Same
-- unprefixed style as DICT_KEY / REV_KEY.
local UPS_REV_KEY = "upstreams_rev"
local SNAPSHOT_TTL = 0.5  -- seconds a worker may reuse a snapshot read from disk

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

--- LMR_* names the module reads. Declared here so capture_env() can snapshot
--- them once in the master process (nginx strips undeclared variables from
--- worker environments, so os.getenv returns nil inside request phases).
_M.ENV_NAMES = {
    "SMG_POLICY",
    "LMR_DEFAULT_EFFORT", "LMR_EFFORT_MAP", "LMR_MODEL_CTX", "LMR_MODEL_EFFORT",
    "LMR_MODEL_EFFORT_MAP", "LMR_MODEL_MODALITIES", "LMR_VIRTUAL_MODELS",
    "LMR_WATCHER_URL", "LMR_CONFIG_FILE", "LMR_UI_DIR", "LMR_UI_ROUTER_MODE",
    "LMR_LOGS_BUFFER", "LMR_UPSTREAMS_FILE",
}

--- Call from init_by_lua_block: caches the environment in a plain global that
--- every worker inherits by fork. Idempotent; safe to call again later.
function _M.capture_env()
    if _G.LMR_ENV_CACHE then return _G.LMR_ENV_CACHE end
    local cache = {}
    for _, name in ipairs(_M.ENV_NAMES) do
        local v = os.getenv(name)
        if v ~= nil then cache[name] = v end
    end
    _G.LMR_ENV_CACHE = cache
    return cache
end

--- Trimmed non-empty environment value, or nil. Reads the init-time cache
--- first, then os.getenv (covers unit tests run outside nginx).
local function env(name)
    local cache = _G.LMR_ENV_CACHE
    local v = cache and cache[name] or nil
    if v == nil then v = os.getenv(name) end
    if v == nil then return nil end
    v = trim(v)
    if v == "" then return nil end
    return v
end

_M.env = env

--- JSON null placeholder so absent fields still render as explicit nulls.
--- True when a decoded JSON value should be walked as an array. cjson gives no
--- marker for {}, so an empty table counts as an array; a table with only hash
--- keys is an object and fails.
local function is_array(v)
    if type(v) ~= "table" then return false end
    return #v > 0 or next(v) == nil
end

local function nul(value)
    if value == nil then return JSON_NULL end
    return value
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
    _M._file_cache = nil
    _M._file_cache_at = 0
    _M._env_defaults = nil
    _M._policy_view_dirty = true
    _M.reset_env_upstreams_cache()
end

---Router config for the pool knobs, or nil when the router is not initialised.
---Cached: this is on the path of every /props and model-map proxy call.
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

local UPSTREAMS_LIMIT = 256

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
    if not is_array(raw) then
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

--- One validated profile from one entry (shared by the env and document layers).
--- Returns (profile, nil) or (nil, err); profile carries target plus optional
--- workers/policy/effort, with unset fields absent (never JSON_NULL).
local function profile_from_entry(alias, entry)
    if type(entry) ~= "table" then
        return nil, "virtual model entries must be objects"
    end
    local target = trim(entry.target or "")
    if target == "" then
        return nil, string.format("virtual model %s needs a target model", alias)
    end
    if alias == target then
        return nil, string.format("virtual model %s must differ from its target", alias)
    end
    local profile = { target = target }
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
        local trimmed = trim(entry.policy)
        local name = _M.normalize_policy(trimmed)
        if name == false then
            return nil, string.format("unknown policy for virtual model %s: %s (want one of %s)",
                alias, trimmed, POLICY_NAMES_JOIN)
        end
        if name then profile.policy = name end
    end
    if rawget(entry, "effort") ~= nil and entry.effort ~= JSON_NULL then
        if type(entry.effort) ~= "string" then
            return nil, string.format("virtual model %s effort must be a string or null", alias)
        end
        local trimmed = trim(entry.effort)
        local level = _M.normalize_effort(trimmed)
        if level == false then
            return nil, string.format("unknown effort for virtual model %s: %s (want one of %s)",
                alias, trimmed, EFFORT_LEVELS_JOIN)
        end
        if level then profile.effort = level end
    end
    return profile, nil
end

--- Full-graph cycle guard: no alias may point at another alias, whether that
--- alias already exists or appears in the same batch (root ruling 4).
local function assert_no_alias_chain(built, alias, target)
    if built == nil then return nil end
    if built[target] ~= nil then
        return string.format("virtual model %s target must not be another virtual model: %s",
            alias, target)
    end
    return nil
end

--- Mask one upstreams row for a response body (contract 3.4): api_key is
--- present but always null, has_api_key says whether a secret is held, and the
--- persistence fields (api_key_state / api_key_stored) never leave the store.
local function sanitize_upstream_row(row)
    local out = {}
    for key, value in pairs(row) do
        if key ~= "api_key" and key ~= "api_key_state" and key ~= "api_key_stored" then
            out[key] = value
        end
    end
    out.api_key = JSON_NULL
    out.has_api_key = (row.api_key_state == "set") == true
    return out
end

local function sanitize_upstream_rows(rows)
    local out = {}
    for _, row in ipairs(rows or {}) do out[#out + 1] = sanitize_upstream_row(row) end
    if #out == 0 then return setmetatable({}, EMPTY_ARRAY_MT) end
    return out
end

--- Validate + normalize one upstreams entry. Returns (entry, nil) or (nil, err).
--- The entry keeps the three-state api_key (absent / JSON_NULL = keep, "" =
--- clear, non-empty = set) plus api_key_stored for persistence.
local function upstream_from_entry(entry, index)
    local who = "upstreams[" .. tostring(index) .. "]"
    if type(entry) ~= "table" then
        return nil, who .. " must be an object"
    end
    local url = type(entry.url) == "string" and trim(entry.url) or ""
    if url == "" then
        return nil, "every upstreams entry needs a url"
    end
    local canonical = norm_pool_url(url)
    if not canonical then
        return nil, string.format("invalid upstream url %s (want http(s)://host[:port])", url)
    end
    local out = { url = canonical }

    if rawget(entry, "model_id") ~= nil and entry.model_id ~= JSON_NULL then
        if type(entry.model_id) ~= "string" then
            return nil, string.format("upstream %s model_id must be a string", canonical)
        end
        local model_id = trim(entry.model_id)
        if model_id ~= "" then out.model_id = model_id end
    end

    -- Key tri-state (contract 3.4): absent / null = keep, "" = clear, non-empty
    -- = set. The persisted form additionally carries api_key_state plus
    -- api_key_stored, so a document rewrite that only knows the masked display
    -- shape (api_key: null) cannot lose the secret.
    local state, stored = "keep", nil
    local declared = rawget(entry, "api_key_state")
    if declared ~= nil and declared ~= JSON_NULL then
        if declared ~= "keep" and declared ~= "set" and declared ~= "clear" then
            return nil, string.format("upstream %s api_key_state must be keep, set or clear", canonical)
        end
        state = declared
    end
    -- The operative secret: api_key carries what the UI typed, api_key_stored
    -- what the persisted snapshot carries. A display null on either field is
    -- "not said" rather than "said empty", so the masked document shape
    -- round-trips through the JSON editor without touching the key.
    local explicit, explicit_field
    for _, field in ipairs({ "api_key", "api_key_stored" }) do
        local value = rawget(entry, field)
        if value ~= nil and value ~= JSON_NULL then
            explicit, explicit_field = value, field
            break
        end
    end
    if explicit ~= nil then
        if type(explicit) ~= "string" then
            return nil, string.format("upstream %s %s must be a string or null", canonical, explicit_field)
        end
        if explicit == "" then
            state, stored = "clear", nil
        else
            state, stored = "set", explicit
        end
    elseif state == "set" then
        ngx_log_warn("luarouter upstream ", canonical,
            " api_key_state set without api_key_stored; treating as keep")
        state = "keep"
    end
    out.api_key_state = state
    out.api_key_stored = stored

    for _, field in ipairs({ "priority", "cost" }) do
        local value = rawget(entry, field)
        if value ~= nil and value ~= JSON_NULL then
            local number = tonumber(value)
            if not number then
                return nil, string.format("upstream %s %s must be a number", canonical, field)
            end
            out[field] = number
        end
    end

    if rawget(entry, "labels") ~= nil and entry.labels ~= JSON_NULL then
        if type(entry.labels) ~= "table" then
            return nil, string.format("upstream %s labels must be an object of string values", canonical)
        end
        local labels = {}
        for k, v in pairs(entry.labels) do
            if type(k) ~= "string" or type(v) ~= "string" then
                return nil, string.format("upstream %s labels must be an object of string values", canonical)
            end
            labels[k] = v
        end
        if next(labels) then out.labels = labels end
    end

    local dhc = rawget(entry, "disable_health_check")
    if dhc ~= nil and dhc ~= JSON_NULL then
        if type(dhc) ~= "boolean" then
            return nil, string.format("upstream %s disable_health_check must be a boolean", canonical)
        end
        out.disable_health_check = dhc
    end
    return out, nil
end

--- Whole-section validation for upstreams: array, cap, url dedup. `previous`
--- (optional, url -> {api_key_state, api_key_stored}) is the declaration layer
--- being replaced: a row that says nothing about the key inherits the stored
--- secret rather than dropping it, which is what makes a masked document
--- round-trip (GET /_ui/config -> JSON editor -> apply) key-preserving. An
--- explicit "" still clears, and a url that changed identity inherits nothing.
local function build_upstreams(rows, previous)
    if rows == nil or rows == JSON_NULL then rows = {} end
    if not is_array(rows) then return nil, "upstreams must be an array" end
    if #rows > UPSTREAMS_LIMIT then
        return nil, string.format("upstreams exceeds the %d entry limit", UPSTREAMS_LIMIT)
    end
    local out, seen = {}, {}
    for i, entry in ipairs(rows) do
        local item, err = upstream_from_entry(entry, i)
        if not item then return nil, err end
        if seen[item.url] then
            return nil, string.format("duplicate upstream url after normalization: %s", item.url)
        end
        seen[item.url] = true
        if item.api_key_state == "keep" and not item.api_key_stored and previous then
            local before = previous[item.url]
            if before and before.api_key_state == "set" and before.api_key_stored then
                item.api_key_state = "set"
                item.api_key_stored = before.api_key_stored
            end
        end
        out[#out + 1] = item
    end
    return out, nil
end

--- The live declaration layer in the shape build_upstreams wants for inheritance.
local function previous_upstream_map(cfg)
    local by_url = {}
    for _, item in ipairs((cfg and cfg.upstreams) or {}) do
        if type(item) == "table" and type(item.url) == "string" then
            by_url[item.url] = item
        end
    end
    return by_url
end

-- ------------------------------------------------------------- config shape
-- Internal (map) form; the disk / dict form is the array snapshot below.

local function new_cfg()
    return {
        default_effort = nil,
        effort_map = {},
        model_ctx = {},
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
    }
end

local function new_card()
    return { ctx = nil, default_effort = nil, effort_map = {}, modalities = nil }
end

local function cfg_from_env()
    local cfg = new_cfg()
    local default_effort = _M.normalize_effort(env("LMR_DEFAULT_EFFORT"))
    if default_effort and default_effort ~= false then cfg.default_effort = default_effort end

    for _, pair in ipairs(parse_pairs(env("LMR_EFFORT_MAP"))) do
        local from = _M.normalize_effort(pair[1])
        if from and from ~= false and pair[2] ~= "" then cfg.effort_map[from] = pair[2] end
    end
    for _, pair in ipairs(parse_pairs(env("LMR_MODEL_CTX"))) do
        local ctx = parse_positive_int(pair[2])
        if ctx then cfg.model_ctx[pair[1]] = ctx end
    end
    for _, pair in ipairs(parse_pairs(env("LMR_MODEL_EFFORT"))) do
        local effort = _M.normalize_effort(pair[2])
        if effort and effort ~= false then cfg.model_effort[pair[1]] = effort end
    end

    local cards = cfg.model_configs
    local function card_for(model)
        local card = cards[model]
        if not card then card = new_card(); cards[model] = card end
        return card
    end
    for _, pair in ipairs(parse_pairs(env("LMR_MODEL_EFFORT_MAP"))) do
        local from, to = pair[2]:match("^(.-)>(.*)$")
        from = _M.normalize_effort(from)
        to = _M.normalize_effort(to)
        if from and to and from ~= false and to ~= false then
            card_for(pair[1]).effort_map[from] = to
        end
    end
    for _, pair in ipairs(parse_pairs(env("LMR_MODEL_MODALITIES"))) do
        local caps = parse_caps(pair[2])
        if caps then card_for(pair[1]).modalities = caps end
    end
    for _, pair in ipairs(parse_pairs(env("LMR_VIRTUAL_MODELS"))) do
        local alias, target = pair[1], pair[2]
        if alias ~= "" and target ~= "" and alias ~= target then
            -- Old alias=target pairs are exactly the new shape with no candidates
            -- and no overrides, so both views get the same content.
            cfg.virtual_models[alias] = target
            cfg.virtual_profiles[alias] = { target = target }
        end
    end
    for _, entry in ipairs(_M.env_upstreams()) do
        local item, err = upstream_from_entry(entry, #cfg.upstreams + 1)
        if item then
            local dup = false
            for _, existing in ipairs(cfg.upstreams) do
                if existing.url == item.url then dup = true break end
            end
            if not dup then cfg.upstreams[#cfg.upstreams + 1] = item end
        elseif err then
            ngx_log_warn("luarouter config env upstream skipped: ", err)
        end
    end
    return cfg
end

--- env-layer upstream seed: LMR_UPSTREAMS_FILE points at a JSON file holding
--- either the array form or {upstreams:[...]} (the same shapes the document
--- accepts). Missing/unreadable/invalid means "no seed" — the env layer must
--- never take the gateway down over a bootstrap file.
local env_upstreams_cache = { path = nil, at = 0, rows = nil }

--- Forget the cached seed file (unit hook + operator reload path).
function _M.reset_env_upstreams_cache()
    env_upstreams_cache.path = nil
    env_upstreams_cache.at = 0
    env_upstreams_cache.rows = nil
end

function _M.env_upstreams()
    local path = env("LMR_UPSTREAMS_FILE")
    if not path then return {} end
    local now = (ngx and ngx.now) and ngx.now() or os.time()
    if env_upstreams_cache.path == path and env_upstreams_cache.rows
        and (now - env_upstreams_cache.at) < SNAPSHOT_TTL then
        return env_upstreams_cache.rows
    end
    env_upstreams_cache.path = path
    env_upstreams_cache.at = now
    env_upstreams_cache.rows = {}
    local f = io.open(path, "r")
    if not f then return env_upstreams_cache.rows end
    local text = f:read("*a")
    f:close()
    local decoded = cjson.decode(text or "")
    if decoded == nil then return env_upstreams_cache.rows end
    local rows = decoded
    if type(decoded) == "table" and not is_array(decoded) and decoded.upstreams ~= nil then
        rows = decoded.upstreams
    end
    if is_array(rows) then env_upstreams_cache.rows = rows end
    return env_upstreams_cache.rows
end



--- Array snapshot, same key set and shapes as Rust RuntimeConfig::snapshot().
local function snapshot_of(cfg)
    local effort_map = {}
    for _, from in ipairs(sorted_keys(cfg.effort_map)) do
        effort_map[#effort_map + 1] = { from = from, to = cfg.effort_map[from] }
    end
    local model_ctx = {}
    for _, model in ipairs(sorted_keys(cfg.model_ctx)) do
        model_ctx[#model_ctx + 1] = { model = model, ctx = cfg.model_ctx[model] }
    end
    local model_effort = {}
    for _, model in ipairs(sorted_keys(cfg.model_effort)) do
        model_effort[#model_effort + 1] = { model = model, effort = cfg.model_effort[model] }
    end
    local model_configs = {}
    for _, model in ipairs(sorted_keys(cfg.model_configs)) do
        local card = cfg.model_configs[model]
        local map = {}
        for _, from in ipairs(sorted_keys(card.effort_map)) do
            map[#map + 1] = { from = from, to = card.effort_map[from] }
        end
        model_configs[#model_configs + 1] = {
            model = model,
            ctx = nul(card.ctx),
            default_effort = nul(card.default_effort),
            effort_map = arr(map),
            modalities = nul(card.modalities),
        }
    end
    local virtual_models = {}
    for _, alias in ipairs(sorted_keys(cfg.virtual_models)) do
        local profile = cfg.virtual_profiles[alias] or { target = cfg.virtual_models[alias] }
        local entry = { model = alias, target = profile.target or cfg.virtual_models[alias] }
        -- Optional fields are absent rather than null so a snapshot written by an
        -- older build round-trips unchanged and the JSON editor stays readable.
        if profile.workers then entry.workers = profile.workers end
        if profile.policy then entry.policy = profile.policy end
        if profile.effort then entry.effort = profile.effort end
        virtual_models[#virtual_models + 1] = entry
    end
    local upstreams = {}
    for _, item in ipairs(cfg.upstreams or {}) do
        local entry = {
            url = item.url,
            model_id = nul(item.model_id),
            -- Never echo the secret: the field is present and always null so the
            -- JSON editor round-trips it as "leave the stored key alone" (3.4).
            api_key = JSON_NULL,
            priority = tonumber(item.priority) or 50,
            cost = tonumber(item.cost) or 1.0,
            labels = item.labels or {},
            disable_health_check = (item.disable_health_check and true) or false,
        }
        -- Persistence half of the key: state + value ride the snapshot so a
        -- restart (or another worker) can re-apply the same key without ever
        -- seeing it on the wire.
        if item.api_key_state then entry.api_key_state = item.api_key_state end
        if item.api_key_stored then entry.api_key_stored = item.api_key_stored end
        entry.has_api_key = (item.api_key_state == "set") == true
        upstreams[#upstreams + 1] = entry
    end
    local model_policies = {}
    for _, model in ipairs(sorted_keys(cfg.model_policies)) do
        model_policies[#model_policies + 1] = { model = model, policy = cfg.model_policies[model] }
    end
    return {
        default_effort = nul(cfg.default_effort),
        effort_map = arr(effort_map),
        model_ctx = arr(model_ctx),
        model_effort = arr(model_effort),
        model_configs = arr(model_configs),
        virtual_models = arr(virtual_models),
        policy = nul(cfg.policy),
        model_policies = arr(model_policies),
        upstreams = arr(upstreams),
    }
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
            local n = parse_positive_int(raw)
            if not n then return nil, "ctx must be greater than zero" end
            card.ctx = n
        elseif type(raw) == "string" then
            local s = trim(raw)
            if s == "" then
                card.ctx = nil
            else
                local n = parse_positive_int(s)
                if not n then return nil, string.format("ctx must be a number: %s", s) end
                card.ctx = n
            end
        else
            return nil, "ctx must be a number or null"
        end
    end

    if patch.default_effort ~= nil or patch.default_effort == JSON_NULL then
        local raw = patch.default_effort
        if raw == JSON_NULL then
            card.default_effort = nil
        elseif type(raw) == "string" then
            local trimmed = trim(raw)
            if trimmed == "" or lower(trimmed) == "null" then
                card.default_effort = nil
            else
                local effort = _M.normalize_effort(trimmed)
                if effort == false then
                    return nil, string.format(
                        "unknown effort for default_effort: %s (want one of %s)",
                        trimmed, EFFORT_LEVELS_JOIN)
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
        elseif is_array(patch.effort_map) then
            local next_map = {}
            for _, entry in ipairs(patch.effort_map) do
                local from = _M.normalize_effort(entry.from)
                local to = trim(entry.to)
                if from == false or from == nil then
                    return nil, string.format("unknown effort in map: %s", tostring(entry.from or ""))
                end
                if to ~= "" then
                    local to_norm = _M.normalize_effort(to)
                    if to_norm == false then
                        return nil, string.format(
                            "unknown effort in map target: %s (want one of %s)", to, EFFORT_LEVELS_JOIN)
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
        elseif is_array(raw) then
            local caps = {}
            for _, item in ipairs(raw) do
                if type(item) == "string" then
                    local cap = lower(trim(item))
                    if MODALITY_SET[cap] then caps[#caps + 1] = cap end
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
    return true
end

--- Whole-document build (used by apply_document and from_snapshot): every
--- section is rebuilt from the payload, absent sections stay empty.
---@param doc table @ decoded document / stored snapshot
---@param previous table|nil @ url -> prior upstreams row, for key inheritance
local function cfg_from_document(doc, previous)
    local cfg = new_cfg()
    if type(doc) ~= "table" then return cfg end

    if doc.default_effort ~= nil then
        local raw = doc.default_effort
        if raw == JSON_NULL then
            cfg.default_effort = nil
        elseif type(raw) == "string" then
            local trimmed = trim(raw)
            if trimmed ~= "" and lower(trimmed) ~= "null" then
                local effort = _M.normalize_effort(trimmed)
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
        if not is_array(doc.effort_map) then return nil, "effort_map must be an array" end
        for _, entry in ipairs(doc.effort_map) do
            local from = _M.normalize_effort(entry.from)
            local to = trim(entry.to)
            if from == false or from == nil then
                return nil, string.format("unknown effort in effort_map: %s", tostring(entry.from or ""))
            end
            if to ~= "" then
                local to_norm = _M.normalize_effort(to)
                if to_norm == false then
                    return nil, string.format("unknown effort in effort_map target: %s", to)
                end
                cfg.effort_map[from] = to_norm
            end
        end
    end

    if doc.model_ctx ~= nil then
        if not is_array(doc.model_ctx) then return nil, "model_ctx must be an array" end
        for _, entry in ipairs(doc.model_ctx) do
            local model = trim(entry.model)
            if model ~= "" then
                if entry.ctx == nil or entry.ctx == JSON_NULL then
                    return nil, string.format("model_ctx for %s needs a numeric ctx", model)
                end
                local ctx = parse_positive_int(entry.ctx)
                if not ctx then
                    return nil, string.format("model_ctx for %s must be greater than zero", model)
                end
                cfg.model_ctx[model] = ctx
            end
        end
    end

    if doc.model_effort ~= nil then
        if not is_array(doc.model_effort) then return nil, "model_effort must be an array" end
        for _, entry in ipairs(doc.model_effort) do
            local model = trim(entry.model)
            local raw = entry.effort
            local trimmed = type(raw) == "string" and trim(raw) or ""
            if model ~= "" and trimmed ~= "" and lower(trimmed) ~= "null" then
                local effort = _M.normalize_effort(trimmed)
                if effort == false then
                    return nil, string.format("unknown effort for %s", model)
                end
                cfg.model_effort[model] = effort
            end
        end
    end

    if doc.virtual_models ~= nil then
        if not is_array(doc.virtual_models) then return nil, "virtual_models must be an array" end
        local built_profiles = {}
        for _, entry in ipairs(doc.virtual_models) do
            local alias = type(entry.model) == "string" and trim(entry.model) or ""
            if alias == "" then return nil, "virtual_models entries need a model (the alias)" end
            if type(entry.target) ~= "string" or trim(entry.target) == "" then
                return nil, string.format("virtual model %s needs a target model", alias)
            end
            local profile, perr = profile_from_entry(alias, entry)
            if not profile then return nil, perr end
            built_profiles[alias] = profile
        end
        -- Chain rejection over the merged batch (root ruling 4): no target may
        -- name an alias that exists in this table, whoever declared it.
        for alias, profile in pairs(built_profiles) do
            local cerr = assert_no_alias_chain(built_profiles, alias, profile.target)
            if cerr then return nil, cerr end
        end
        for alias, profile in pairs(built_profiles) do
            cfg.virtual_profiles[alias] = profile
            cfg.virtual_models[alias] = profile.target
        end
    end

    if doc.upstreams ~= nil then
        local rows, uerr = build_upstreams(rawget(doc, "upstreams"), previous)
        if not rows then return nil, uerr end
        cfg.upstreams = rows
    end

    if doc.policy ~= nil then
        local raw = doc.policy
        if raw == JSON_NULL then
            cfg.policy = nil
        elseif type(raw) == "string" then
            local trimmed = trim(raw)
            if trimmed == "" or lower(trimmed) == "null" then
                cfg.policy = nil
            else
                local name = _M.normalize_policy(trimmed)
                if name == false then
                    return nil, string.format("unknown policy: %s (want one of %s)",
                        trimmed, POLICY_NAMES_JOIN)
                end
                cfg.policy = name
            end
        else
            return nil, "policy must be a string or null"
        end
    end

    if doc.model_policies ~= nil then
        if not is_array(doc.model_policies) then return nil, "model_policies must be an array" end
        local built = {}
        for _, entry in ipairs(doc.model_policies) do
            local model = trim(entry.model)
            if model == "" then
                return nil, "every model_policies entry needs a model"
            end
            local raw = entry.policy
            local trimmed = type(raw) == "string" and trim(raw) or ""
            if raw == JSON_NULL or trimmed == "" or lower(trimmed) == "null" then
                -- an explicit null/empty row drops the override (inherit the global)
                goto next_model_policy
            end
            local name = _M.normalize_policy(trimmed)
            if name == false then
                return nil, string.format("unknown policy for %s: %s (want one of %s)",
                    model, trimmed, POLICY_NAMES_JOIN)
            end
            built[model] = name
            ::next_model_policy::
        end
        cfg.model_policies = built
    end

    if doc.model_configs ~= nil then
        if not is_array(doc.model_configs) then return nil, "model_configs must be an array" end
        local built = {}
        for _, entry in ipairs(doc.model_configs) do
            local model = trim(entry.model)
            if model == "" then return nil, "every model_configs entry needs a model" end
            local card = new_card()
            local ok, err = merge_model_patch(card, entry)
            if not ok then return nil, err end
            built[model] = card
        end
        cfg.model_configs = built
    end

    return cfg
end

_M.cfg_from_document = cfg_from_document
_M.snapshot_of = snapshot_of

-- ------------------------------------------------------------ shared storage

local function dict()
    -- Unit runs outside nginx (luajit caliber) may not carry ngx at all; nil
    -- then means the file layer alone works, which is the documented degraded
    -- mode for a missing lua_shared_dict as well.
    if not ngx or not ngx.shared then return nil end
    return ngx.shared[DICT_NAME]
end

-- Forward declaration: registered_models lives in the models-document section
-- further down, and policy_document needs it from earlier in the file.
local registered_models

--- Layered read of the current snapshot (array form). Returns table or nil.
local function read_snapshot()
    local shared = dict()
    if shared then
        local raw = shared:get(DICT_KEY)
        if raw then
            local snap = cjson.decode(raw)
            if snap then return snap end
        end
    end
    local path = env("LMR_CONFIG_FILE")
    if path then
        local now = (ngx and ngx.now) and ngx.now() or os.time()
        _M._file_cache_at = _M._file_cache_at or 0
        if _M._file_cache and (now - _M._file_cache_at) < SNAPSHOT_TTL then
            return _M._file_cache
        end
        _M._file_cache_at = now
        local f = io.open(path, "r")
        if f then
            local text = f:read("*a")
            f:close()
            local snap = cjson.decode(text or "")
            _M._file_cache = snap
            if snap then return snap end
        else
            _M._file_cache = nil
        end
    end
    return nil
end

--- Write the snapshot into every available layer (dict first, then disk).
local function write_snapshot(snap)
    local shared = dict()
    if shared then
        local ok, err = shared:set(DICT_KEY, cjson.encode(snap))
        if not ok then
            ngx.log(ngx.WARN, "luarouter config dict write failed: ", err or "?")
        end
    end
    local path = env("LMR_CONFIG_FILE")
    if path then
        local ok, err = _M.persist(path, snap)
        if not ok then
            ngx.log(ngx.WARN, "luarouter config persist to ", path, " failed: ", err)
        end
    end
    _M._file_cache = nil  -- force a re-read on next miss
    -- Invalidate the policy memo here and bump the revision last, so a reader
    -- that sees the new token also sees the new snapshot in the layers above.
    -- The dirty flag covers the writing worker (its own memo would otherwise
    -- serve the old policy for up to SNAPSHOT_TTL); incr is the atomic
    -- cross-process form - a per-process counter would let a second writer
    -- re-use the old token and leave the first writer's workers cached.
    _M._policy_view_dirty = true
    if shared then
        local value, err = shared:incr(REV_KEY, 1, 0)
        if not value then
            ngx.log(ngx.WARN, "luarouter config revision bump failed: ", err or "?")
        end
    end
    return true
end

--- Atomic write (tmp + rename), same as the Rust persist(). A missing parent
--- directory is created (mkdir -p) and the write retried once.
local function write_text(path, text)
    local f, err = io.open(path, "w")
    if not f then return nil, err end
    f:write(text)
    f:close()
    return true
end

function _M.persist(path, snap)
    local text, enc_err = cjson.encode(snap)
    if not text then return nil, "encode: " .. tostring(enc_err) end
    local dir = path:match("^(.*)/[^/]+$")
    local tmp = (path:gsub("[^/]+$", "")) .. "." .. (path:match("([^/]+)$") or "config.json") .. ".tmp"
    local ok, err = write_text(tmp, text)
    if not ok and dir and dir ~= "" then
        local executed = os.execute(string.format("mkdir -p '%s' 2>/dev/null", dir))
            or (io.popen(string.format("mkdir -p '%s' 2>/dev/null", dir)) ~= nil)
        if not executed then return nil, "create dir: " .. dir end
        ok, err = write_text(tmp, text)
    end
    if not ok then return nil, "write tmp: " .. tostring(err) end
    local renamed, rerr = os.rename(tmp, path)
    if not renamed then
        os.remove(tmp)
        return nil, "rename: " .. tostring(rerr)
    end
    return true
end

--- Current config as internal map form: env baseline overlaid with the
--- persisted/shared snapshot (same precedence as Rust: file wins when present
--- and valid; invalid file falls back to env).
function _M.current()
    local snap = read_snapshot()
    if snap then
        local cfg, err = cfg_from_document(snap)
        if cfg then return cfg end
        ngx.log(ngx.WARN, "persisted config invalid (", err, "); falling back to env defaults")
    end
    return cfg_from_env()
end


function _M.env_defaults()
    if not _M._env_defaults then
        local snap = snapshot_of(cfg_from_env())
        snap.upstreams = sanitize_upstream_rows(snap.upstreams)
        _M._env_defaults = snap
    end
    return _M._env_defaults
end

-- ------------------------------------------------------------- readers

function _M.ctx_cap(model)
    if type(model) ~= "string" or model == "" then return nil end
    local cfg = _M.current()
    local card = cfg.model_configs[model]
    if card and card.ctx then return card.ctx end
    return cfg.model_ctx[model]
end

function _M.modalities_for(model)
    if type(model) ~= "string" or model == "" then return nil end
    local card = _M.current().model_configs[model]
    if card then return card.modalities end
    return nil
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

--- Cross-process invalidation token, or nil when no shared dict can carry one
--- (then policy_state falls back to the plain TTL window).
function _M.policy_revision()
    local shared = dict()
    if not shared then return nil end
    local value = shared:get(REV_KEY)
    if value == nil then return "unset" end
    return tostring(value)
end

local function policy_state()
    local token = _M.policy_revision()
    local now = (ngx and ngx.now) and ngx.now() or os.time()
    local fresh = (now - policy_view.at) < SNAPSHOT_TTL and not _M._policy_view_dirty
    if fresh and (token == nil or policy_view.token == token) then
        return policy_view
    end
    _M._policy_view_dirty = nil
    local cfg = _M.current()
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
    local raw_policy = _M.normalize_policy(env("SMG_POLICY"))
    if raw_policy then return raw_policy end
    return ENV_POLICY_DEFAULT
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
        local override = _M.policy_override_for(model)
        if override then return override, "model" end
    end
    local global_override = _M.policy_global_override()
    if global_override then return global_override, "global" end
    if type(hint) == "string" and hint ~= "" then
        local named = _M.normalize_policy(hint)
        if named then return named, "hint" end
        return "round_robin", "hint"
    end
    if type(cfg_policy) == "string" and cfg_policy ~= "" then
        local named = _M.normalize_policy(cfg_policy)
        if named then return named, "env" end
        return "round_robin", "env"
    end
    return "round_robin", "env"
end

--- Snapshot rows, the round-trip format the apply endpoint accepts.
function _M.model_policies_list()
    local state = policy_state()
    local out = {}
    for _, model in ipairs(sorted_keys(state.models)) do
        out[#out + 1] = { model = model, policy = state.models[model] }
    end
    return out
end

--- Routing-page document: the chain inputs, plus one row per model showing the
--- policy that model actually routes with and which layer supplied it.
function _M.policy_document()
    local env_policy = _M.env_policy()
    local rows = {}
    local order, seen = {}, {}
    local function note(model)
        if model ~= nil and not seen[model] then
            seen[model] = true
            order[#order + 1] = model
        end
    end
    for _, row in ipairs(registered_models()) do note(row.model) end
    for _, row in ipairs(_M.model_policies_list()) do note(row.model) end
    table.sort(order)

    local registry_mod
    do
        local ok, mod = pcall(require, "resty.luarouter.registry")
        if ok and type(mod) == "table" then registry_mod = mod end
    end

    local registered_set = {}
    for _, row in ipairs(registered_models()) do registered_set[row.model] = true end
    local global_override = _M.policy_global_override()
    for _, model in ipairs(order) do
        local hint
        if registry_mod and type(registry_mod.policy_hint_for_model) == "function" then
            local ok, value = pcall(registry_mod.policy_hint_for_model, model)
            if ok and type(value) == "string" and value ~= "" then hint = value end
        end
        local override = _M.policy_override_for(model)
        -- One chain for both planes: policy.lua calls the same function, so the
        -- page can never advertise a policy the router is not using.
        local effective, source = _M.resolve_policy(env_policy, model, hint)
        rows[#rows + 1] = {
            model = model,
            registered = registered_set[model] == true,
            override = nul(override),
            hint = nul(hint),
            effective = effective,
            source = source,
        }
    end

    local names = {}
    for i = 1, #POLICY_NAMES do names[i] = POLICY_NAMES[i] end
    return {
        policies = names,
        policy = nul(global_override),
        env_policy = env_policy,
        effective_default = global_override or env_policy,
        model_policies = arr(_M.model_policies_list()),
        models = arr(rows),
        revision = _M.policy_revision(),
        persist = { file = nul(env("LMR_CONFIG_FILE")) },
    }
end

--- Virtual alias -> real upstream id; unknown names passes through unchanged.
function _M.resolve_model(model)
    if type(model) ~= "string" then return model end
    return _M.current().virtual_models[model] or model
end

function _M.virtual_models_list()
    local cfg = _M.current()
    local out = {}
    for _, alias in ipairs(sorted_keys(cfg.virtual_models)) do
        out[#out + 1] = { alias, cfg.virtual_models[alias] }
    end
    return out
end

--- Effective effort for one request (same order as Rust request_effort_for):
--- legacy forced model_effort > model card (map, default) > global map/default.
function _M.request_effort_for(model, requested)
    local cfg = _M.current()
    local model_key = (type(model) == "string" and model ~= "") and model or nil
    local card = model_key and cfg.model_configs[model_key] or nil
    if model_key and cfg.model_effort[model_key] then
        return cfg.model_effort[model_key]
    end
    local wanted
    if type(requested) == "string" then
        local v = lower(trim(requested))
        if v ~= "" and v ~= "null" and v ~= "default" then wanted = v end
    end
    if card then
        local level = wanted and EFFORT_SET[wanted] and wanted or nil
        if level then
            if card.effort_map[level] then return card.effort_map[level] end
            if next(card.effort_map) or card.default_effort then
                return card.default_effort or level
            end
            return cfg.effort_map[level] or level
        end
        if card.default_effort then return card.default_effort end
        if wanted then
            return card.default_effort or cfg.default_effort or wanted
        end
        return cfg.default_effort
    end
    if wanted then return cfg.effort_map[wanted] or wanted end
    return cfg.default_effort
end

-- ------------------------------------------------------------- mutations

--- Apply an effort edit; returns (snapshot, nil) or (nil, error).
function _M.apply_effort(patch)
    if type(patch) ~= "table" then return nil, "body must be a JSON object" end
    local cfg = _M.current()

    local has_default = rawget(patch, "default_effort") ~= nil
    if has_default then
        local raw = patch.default_effort
        if raw == JSON_NULL then
            cfg.default_effort = nil
        elseif type(raw) == "string" then
            local trimmed = trim(raw)
            if trimmed == "" or lower(trimmed) == "null" then
                cfg.default_effort = nil
            else
                local effort = _M.normalize_effort(trimmed)
                if effort == false then
                    return nil, string.format("unknown effort: %s (want one of %s)",
                        trimmed, EFFORT_LEVELS_JOIN)
                end
                cfg.default_effort = effort
            end
        else
            return nil, "default_effort must be a string or null"
        end
    end

    if patch.effort_map ~= nil then
        if not is_array(patch.effort_map) then return nil, "effort_map must be an array" end
        local next_map = {}
        for _, entry in ipairs(patch.effort_map) do
            local from = _M.normalize_effort(entry.from)
            local to = trim(entry.to)
            if from == false or from == nil then
                return nil, string.format("unknown effort in map: %s", tostring(entry.from or ""))
            end
            if to ~= "" then
                local to_norm = _M.normalize_effort(to)
                if to_norm == false then
                    return nil, string.format("unknown effort in map target: %s (want one of %s)",
                        to, EFFORT_LEVELS_JOIN)
                end
                next_map[from] = to_norm
            end
        end
        cfg.effort_map = next_map
    end

    if patch.model_effort ~= nil then
        if not is_array(patch.model_effort) then
            return nil, "model_effort must be an array of {model, effort}"
        end
        local next_map = {}
        for _, entry in ipairs(patch.model_effort) do
            local model = trim(entry.model)
            local raw = entry.effort
            local trimmed = type(raw) == "string" and trim(raw) or ""
            if model ~= "" and trimmed ~= "" and lower(trimmed) ~= "null" then
                local effort = _M.normalize_effort(trimmed)
                if effort == false then
                    return nil, string.format("unknown effort for %s: %s (want one of %s)",
                        model, trimmed, EFFORT_LEVELS_JOIN)
                end
                next_map[model] = effort
            end
        end
        cfg.model_effort = next_map
    end

    write_snapshot(snapshot_of(cfg))
    return snapshot_of(_M.current()), nil
end

--- Apply one context cap; ctx nil/JSON_NULL removes it.
function _M.apply_ctx(model, ctx)
    model = trim(model or "")
    if model == "" then return nil, "model is required" end
    local cfg = _M.current()
    if ctx == nil or ctx == JSON_NULL then
        cfg.model_ctx[model] = nil
    else
        local cap = parse_positive_int(ctx)
        if not cap then return nil, "ctx must be greater than zero" end
        cfg.model_ctx[model] = cap
    end
    write_snapshot(snapshot_of(cfg))
    return snapshot_of(_M.current()), nil
end

--- One model-card patch. remove:true drops the card plus legacy rows.
function _M.apply_model_config(patch)
    if type(patch) ~= "table" then return nil, "body must be a JSON object" end
    local model = trim(patch.model or "")
    if model == "" then return nil, "model is required" end
    local cfg = _M.current()
    if patch.remove == true then
        cfg.model_configs[model] = nil
        cfg.model_ctx[model] = nil
        cfg.model_effort[model] = nil
        write_snapshot(snapshot_of(cfg))
        return snapshot_of(_M.current()), nil
    end
    local card = cfg.model_configs[model] or new_card()
    local ok, err = merge_model_patch(card, patch)
    if not ok then return nil, err end
    if rawget(patch, "default_effort") ~= nil then cfg.model_effort[model] = nil end
    if rawget(patch, "ctx") ~= nil then cfg.model_ctx[model] = nil end
    cfg.model_configs[model] = card
    write_snapshot(snapshot_of(cfg))
    return snapshot_of(_M.current()), nil
end

--- Whole-list replace for the virtual model table (profiles shape). Kept as the
--- public entry point for the existing callers; it validates through the same
--- profile builder as apply_profiles.
function _M.apply_virtual_models(entries)
    return _M.apply_profiles(entries)
end

--- Whole-list replace for the profiles table: entries are the document shape
--- [{model, target, workers?, policy?, effort?}] (legacy {model, target} pairs
--- still validate). Returns (snapshot, nil) or (nil, error).
function _M.apply_profiles(entries)
    if not is_array(entries) then return nil, "virtual_models must be an array" end
    local built = {}
    for _, entry in ipairs(entries) do
        if type(entry) ~= "table" then
            return nil, "virtual model entries must be objects"
        end
        local alias = trim(type(entry.model) == "string" and entry.model or "")
        if alias == "" or trim(type(entry.target) == "string" and entry.target or "") == "" then
            return nil, "virtual model entries need both model and target"
        end
        local profile, perr = profile_from_entry(alias, entry)
        if not profile then return nil, perr end
        built[alias] = profile
    end
    -- Batch + existing-graph chain check (root ruling 4): an alias may never
    -- point at another alias, whether declared in this batch or earlier.
    for alias, profile in pairs(built) do
        local cerr = assert_no_alias_chain(built, alias, profile.target)
        if not cerr then
            local existing = _M.current().virtual_models[profile.target]
            if existing ~= nil then
                cerr = string.format(
                    "virtual model %s target must not be another virtual model: %s", alias, profile.target)
            end
        end
        if cerr then return nil, cerr end
    end
    local cfg = _M.current()
    local profiles, map = {}, {}
    for alias, profile in pairs(built) do
        profiles[alias] = profile
        map[alias] = profile.target
    end
    cfg.virtual_profiles = profiles
    cfg.virtual_models = map
    write_snapshot(snapshot_of(cfg))
    return snapshot_of(_M.current()), nil
end

-- ------------------------------------------------------- profile readers
--
-- Hot-path shape of the profile accessors: they read the already-memoised
-- current() snapshot (SNAPSHOT_TTL window, no extra shdict round trip) and are
-- pure functions of it, so router.lua may call them per request.

--- Profile for one alias, or nil when the name is not an alias. Returns a fresh
--- table each call so a caller cannot mutate the live snapshot.
function _M.profile_for(model)
    if type(model) ~= "string" or model == "" then return nil end
    local cfg = _M.current()
    local profile = cfg.virtual_profiles[model]
    if type(profile) ~= "table" then
        local target = cfg.virtual_models[model]
        if type(target) ~= "string" then return nil end
        return { target = target }
    end
    local out = { target = profile.target }
    if profile.workers then out.workers = { table.unpack(profile.workers) } end
    out.policy = profile.policy
    out.effort = profile.effort
    return out
end

--- Profiles as an array ordered by alias, the round-trip form the UI and the
--- apply endpoint accept.
function _M.profiles_list()
    local cfg = _M.current()
    local out = {}
    for _, alias in ipairs(sorted_keys(cfg.virtual_profiles)) do
        local profile = cfg.virtual_profiles[alias]
        local entry = { model = alias, target = profile.target }
        if profile.workers then entry.workers = { table.unpack(profile.workers) } end
        entry.policy = profile.policy
        entry.effort = profile.effort
        out[#out + 1] = entry
    end
    return out
end

--- Per-alias policy override (contract 3.3: profile.policy beats
--- model_policies, hint, global and env). Accepts either an alias or a profile
--- table, so router.lua can pass what it already resolved.
function _M.profile_policy(alias_or_profile)
    local name
    if type(alias_or_profile) == "table" then
        name = alias_or_profile.policy
    elseif type(alias_or_profile) == "string" and alias_or_profile ~= "" then
        local profile = _M.current().virtual_profiles[alias_or_profile]
        name = profile and profile.policy
    end
    if type(name) ~= "string" then return nil end
    local normalized = _M.normalize_policy(name)
    return normalized or nil
end

--- Per-alias effort override with the precedence of contract 3.3: a forced
--- model_effort row wins, then the profile of the alias, then the profile keyed
--- by the resolved target. nil = "no override", the caller keeps its ladder.
function _M.profile_effort(alias, resolved)
    local cfg = _M.current()
    for _, key in ipairs({ alias, resolved }) do
        if type(key) == "string" and key ~= "" then
            local forced = cfg.model_effort[key]
            if type(forced) == "string" and forced ~= "" then return forced end
        end
    end
    for _, key in ipairs({ alias, resolved }) do
        if type(key) == "string" and key ~= "" then
            local profile = cfg.virtual_profiles[key]
            local wanted = profile and profile.effort
            if type(wanted) == "string" and wanted ~= "" then return wanted end
        end
    end
    return nil
end

-- --------------------------------------------------------- upstreams layer
--
-- The declaration half of the pool: document rows keyed by normalized url, with
-- reconcile_upstreams() projecting them into lr_workers. Field defaults mirror
-- registry.add (priority 50, cost 1.0, model_id unknown), and the key follows
-- the tri-state of contract 3.4 (keep / clear / set).

local function upstream_defaults(item)
    return {
        model_id = (type(item.model_id) == "string" and item.model_id ~= "") and item.model_id or "unknown",
        priority = tonumber(item.priority) or 50,
        cost = tonumber(item.cost) or 1.0,
        labels = item.labels or {},
        disable_health_check = (item.disable_health_check and true) or false,
    }
end

local function same_labels(a, b)
    a = a or {}
    b = b or {}
    for k, v in pairs(a) do
        if b[k] ~= v then return false end
    end
    for k, v in pairs(b) do
        if a[k] == nil or a[k] ~= v then return false end
    end
    return true
end

--- True when applying `item` to `record` would change the stored worker. Root
--- ruling 1: an unchanged declaration must not count as an update, and a keep
--- (null/absent) api_key is never a change.
local function upstream_drifts(item, record)
    local want = upstream_defaults(item)
    if (record.model_id or "unknown") ~= want.model_id then return true end
    if (tonumber(record.priority) or 50) ~= want.priority then return true end
    if (tonumber(record.cost) or 1.0) ~= want.cost then return true end
    if ((record.disable_health_check and true) or false) ~= want.disable_health_check then
        return true
    end
    if not same_labels(want.labels, record.labels) then return true end
    local stored = record.api_key
    if stored == false or stored == cjson.null then stored = nil end
    if item.api_key_state == "set" then
        return stored ~= item.api_key_stored
    elseif item.api_key_state == "clear" then
        return stored ~= nil and stored ~= ""
    end
    return false
end

--- What registry.update should receive for one drifted config worker. Only the
--- tri-state key is sent when it says so; keep never touches the stored secret.
local function upstream_patch(item)
    local want = upstream_defaults(item)
    local patch = {
        model_id = want.model_id,
        priority = want.priority,
        cost = want.cost,
        labels = want.labels,
        disable_health_check = want.disable_health_check,
    }
    if item.api_key_state == "set" then
        patch.api_key = item.api_key_stored
    elseif item.api_key_state == "clear" then
        patch.api_key = ""
    end
    return patch
end

--- Idempotent projection of the declared upstreams into the worker pool
--- (contract 3.1 / 3.2). Discovery-tagged rows only: watcher, bootstrap and
--- manual workers are never overwritten, and only config rows are reclaimed.
--- Returns a summary {added=,updated=,removed=,skipped=} (arrays also carry the
--- affected urls). Without a usable registry module (unit caliber, stripped
--- build) every counter is 0 and nothing counts as an error.
function _M.reconcile_upstreams()
    local summary = { added = 0, updated = 0, removed = 0, skipped = 0 }
    local reg = store_registry()
    if not reg or type(reg.records) ~= "function"
        or type(reg.add) ~= "function" or type(reg.update) ~= "function"
        or type(reg.remove) ~= "function" then
        return summary
    end
    local declared = _M.current().upstreams or {}

    local all_records = {}
    local by_endpoint = {}
    local ok_records, records_or_err = pcall(reg.records)
    if ok_records and type(records_or_err) == "table" then
        for _, record in ipairs(records_or_err) do
            if type(record) == "table" and type(record.url) == "string" then
                all_records[#all_records + 1] = record
                local key = norm_pool_url(record.url) or record.url
                local slot = by_endpoint[key]
                if not slot then
                    slot = {}
                    by_endpoint[key] = slot
                end
                if record.discovery == "config" or not slot.chosen then
                    slot.chosen = record
                end
            end
        end
    end

    local owned = {}
    for _, item in ipairs(declared) do
        local key = norm_pool_url(item.url) or item.url
        owned[key] = true
        local slot = by_endpoint[key]
        local record = slot and slot.chosen
        if not record then
            local res, aerr, kind = reg.add({
                url = item.url,
                model_id = (type(item.model_id) == "string" and item.model_id ~= "") and item.model_id or "unknown",
                api_key = (item.api_key_state == "set") and item.api_key_stored or nil,
                priority = tonumber(item.priority) or 50,
                cost = tonumber(item.cost) or 1.0,
                labels = item.labels or {},
                disable_health_check = (item.disable_health_check and true) or false,
                discovery = "config",
            }, store_config() or {})
            if res then
                summary.added = summary.added + 1
            else
                -- Duplicate url (a race with discovery) still means the pool has
                -- the endpoint; anything else is a real validation failure.
                if kind == "validation" and type(aerr) == "string"
                    and aerr:find("already exists", 1, true) == nil then
                    ngx_log_warn("luarouter upstream add failed for ", item.url, ": ", aerr)
                end
                summary.skipped = summary.skipped + 1
            end
        elseif record.discovery == "config" then
            if upstream_drifts(item, record) then
                local upd_id = record.id
                if type(upd_id) ~= "string" then
                    local ok_id, derived = pcall(reg.worker_id_for_url, item.url)
                    upd_id = ok_id and derived or nil
                end
                local res, uerr = reg.update(upd_id, upstream_patch(item))
                if res then
                    summary.updated = summary.updated + 1
                else
                    ngx_log_warn("luarouter upstream update failed for ", item.url, ": ", uerr or "?")
                    summary.skipped = summary.skipped + 1
                end
            end
        else
            -- Held by the watcher / bootstrap / an operator: the declaration
            -- stands, the pool row is left exactly as it is.
            summary.skipped = summary.skipped + 1
        end
    end

    for _, record in ipairs(all_records) do
        local key = norm_pool_url(record.url) or record.url
        if record.discovery == "config" and not owned[key] then
            local res, rerr = reg.remove(record.id)
            if res then
                summary.removed = summary.removed + 1
            else
                ngx_log_warn("luarouter upstream remove failed for ",
                    tostring(record.url), ": ", rerr or "?")
            end
        end
    end

    local shared = dict()
    if shared then
        local token = _M.policy_revision() or tostring((ngx and ngx.now and ngx.now()) or os.time())
        local ok_set, serr = shared:set(UPS_REV_KEY, token)
        if not ok_set then
            ngx_log_warn("luarouter upstreams revision write failed: ", serr or "?")
        end
    end
    return summary
end

--- Token the 30s self-heal timer compares against the config revision
--- (init.lua). nil when no shared dict can carry it.
function _M.upstreams_revision()
    local shared = dict()
    if not shared then return nil end
    local value = shared:get(UPS_REV_KEY)
    if value == nil then return nil end
    return tostring(value)
end

--- Validate + persist + reconcile the declared upstream pool (whole-list
--- replace). Returns (summary, nil) or (nil, error).
function _M.apply_upstreams(entries)
    local rows, err = build_upstreams(entries, previous_upstream_map(_M.current()))
    if not rows then return nil, err end
    local cfg = _M.current()
    cfg.upstreams = rows
    write_snapshot(snapshot_of(cfg))
    local summary = _M.reconcile_upstreams()
    return summary, nil
end

--- True when the two-layer revision says a reconcile is overdue (a restart,
--- another worker's write, or a pool edit that dropped config rows).
function _M.upstreams_reconcile_due()
    local shared = dict()
    if not shared then return false end
    local applied = shared:get(UPS_REV_KEY)
    if applied == nil then return true end
    return tostring(applied) ~= tostring(_M.policy_revision())
end
--- Routing-policy patch. Body accepts three independent sections, all optional
--- and applied in one atomic write (validate-then-write, like apply_effort):
---   policy          string|null  global override; null / "" / "auto" clears it
---   model_policies  [{model, policy}]  whole-table replace of the per-model rows
---   model_policy    {model, policy}    upsert or delete one per-model row
--- An unknown policy name is rejected before anything is written, so the caller
--- sees 400 and the running configuration is untouched.
function _M.apply_policy(patch)
    if type(patch) ~= "table" then return nil, "body must be a JSON object" end
    local touched = false

    local next_global
    if rawget(patch, "policy") ~= nil then
        local raw = patch.policy
        if raw == JSON_NULL then
            next_global = nil
        elseif type(raw) == "string" then
            local trimmed = trim(raw)
            if trimmed == "" or lower(trimmed) == "null" then
                next_global = nil
            else
                local name = _M.normalize_policy(trimmed)
                if name == false then
                    return nil, string.format("unknown policy: %s (want one of %s)",
                        trimmed, POLICY_NAMES_JOIN)
                end
                next_global = name
            end
        else
            return nil, "policy must be a string or null"
        end
        touched = true
    end

    local next_rows
    if rawget(patch, "model_policies") ~= nil then
        local rows = patch.model_policies
        if rows == JSON_NULL then rows = {} end
        if not is_array(rows) then return nil, "model_policies must be an array" end
        next_rows = {}
        for _, entry in ipairs(rows) do
            if type(entry) ~= "table" then
                return nil, "model_policies entries must be objects"
            end
            local model = trim(type(entry.model) == "string" and entry.model or "")
            if model == "" then
                return nil, "every model_policies entry needs a model"
            end
            local raw = entry.policy
            local trimmed = type(raw) == "string" and trim(raw) or ""
            if raw ~= JSON_NULL and trimmed ~= "" and lower(trimmed) ~= "null" then
                local name = _M.normalize_policy(trimmed)
                if name == false then
                    return nil, string.format("unknown policy for %s: %s (want one of %s)",
                        model, trimmed, POLICY_NAMES_JOIN)
                end
                next_rows[model] = name
            end
        end
        touched = true
    elseif rawget(patch, "model_policy") ~= nil then
        local entry = patch.model_policy
        if entry == JSON_NULL or type(entry) ~= "table" then
            return nil, "model_policy must be an object {model, policy}"
        end
        local model = trim(type(entry.model) == "string" and entry.model or "")
        if model == "" then return nil, "model_policy needs a model" end
        local raw = entry.policy
        local trimmed = type(raw) == "string" and trim(raw) or ""
        next_rows = {}
        for target, name in pairs(_M.current().model_policies) do
            next_rows[target] = name
        end
        if raw == JSON_NULL or trimmed == "" or lower(trimmed) == "null" then
            next_rows[model] = nil
        else
            local name = _M.normalize_policy(trimmed)
            if name == false then
                return nil, string.format("unknown policy for %s: %s (want one of %s)",
                    model, trimmed, POLICY_NAMES_JOIN)
            end
            next_rows[model] = name
        end
        touched = true
    end

    if not touched then
        return nil, "nothing to apply: send policy, model_policies or model_policy"
    end

    -- Every section validated: rebuild the config, mutate only the policy keys,
    -- and write once.
    local cfg = _M.current()
    if next_global ~= nil or rawget(patch, "policy") ~= nil then
        cfg.policy = next_global
    end
    if next_rows ~= nil then cfg.model_policies = next_rows end
    write_snapshot(snapshot_of(cfg))
    return snapshot_of(_M.current()), nil
end

--- Whole-document replace (JSON editor). Validate first: nothing half-applies.
--- Returns (snapshot, nil, reconcile_summary_or_nil); the summary is present
--- only when this call actually reconciled the pool (root ruling 2), so a
--- config-only save keeps the response shape it always had.
function _M.apply_document(doc)
    local previous = previous_upstream_map(_M.current())
    local cfg, err = cfg_from_document(doc, previous)
    if not cfg then return nil, err end
    write_snapshot(snapshot_of(cfg))
    local summary
    if type(doc) == "table"
        and (rawget(doc, "upstreams") ~= nil or rawget(doc, "virtual_models") ~= nil) then
        summary = _M.reconcile_upstreams()
    end
    return snapshot_of(_M.current()), nil, summary
end

-- ------------------------------------------------------------- watcher

function _M.watcher_url()
    return env("LMR_WATCHER_URL")
end


--- Minimal HTTP/1.1 client on ngx.socket.tcp. Returns status, headers(table,
--- lowercase), body — or nil, err. Supports Content-Length and chunked.
function _M.raw_request(method, url, body, headers, timeout_ms)
    local ok, http_mod = pcall(require, "resty.http")
    if ok and http_mod and http_mod.new then
        if body == false then body = nil end  -- lua-resty-http would stringify it
        local client = http_mod.new()
        client:set_timeout(timeout_ms or 5000)
        local pool_cfg = store_config()
        local res, err = client:request_uri(url, {
            method = method,
            body = body,
            headers = headers,
            -- lua-resty-http has its own pool, keyed by host:port and scheme, and
            -- it only reuses when the caller opts in. The old `keepalive = false`
            -- meant one fresh TCP+TLS handshake per /props and per model-map proxy
            -- call; the timeouts are the router's pool knobs so both client paths
            -- agree on how long an idle socket may live.
            keepalive = true,
            keepalive_timeout = pool_cfg and (pool_cfg.pool_idle_timeout_secs * 1000) or 50000,
            keepalive_pool = pool_cfg and pool_cfg.pool_max_idle_per_host or 500,
            -- Same posture as the cosocket path below: internal workers and the
            -- watcher present self-signed certs, and lua-resty-http verifies by
            -- default, which would fail every https request outright.
            ssl_verify = false,
        })
        if not res then return nil, err or "http request failed" end
        local h = {}
        for k, v in pairs(res.headers or {}) do
            h[tostring(k):lower()] = type(v) == "table" and table.concat(v, ",") or tostring(v)
        end
        return res.status, h, res.body or ""
    end
    -- Fallback: raw cosocket (lua-resty-http missing on the box).
    local host, port, path = url:match("^https?://([^:/]+):?(%d*)(/?.*)$")
    if not host then return nil, "bad url: " .. tostring(url) end
    local tls = url:find("^https") ~= nil
    port = (port ~= "" and tonumber(port)) or (tls and 443 or 80)
    if path == "" then path = "/" end
    local sock = ngx.socket.tcp()
    sock:settimeouts(timeout_ms or 5000, timeout_ms or 5000, timeout_ms or 5000)
    local pool_cfg = store_config()
    local pool_opts
    if pool_cfg then
        local registry_mod = store_registry()
        if registry_mod and registry_mod.pool_opts then
            pool_opts = registry_mod.pool_opts(pool_cfg, "store", url)
        end
    end
    local ok_conn, conn_err = sock:connect(host, port, pool_opts)
    if not ok_conn then sock:close(); return nil, conn_err or "connect failed" end
    if tls then
        -- cosocket connect() has no TLS in http{} context, so an https url has
        -- to be upgraded here or the request is sent in cleartext. SNI carries
        -- the host; the cert is not verified (self-signed internal workers).
        local ok_tls, tls_err = sock:sslhandshake(nil, host, false)
        if not ok_tls then
            sock:close()
            return nil, "TLS handshake failed: " .. tostring(tls_err)
        end
    end
    -- No `Connection: close`: the socket is pooled below, and asking the peer to
    -- close it while setkeepalive() keeps it warm is how a reused socket ends up
    -- reset by the server.
    local req = { method .. " " .. path .. " HTTP/1.1\r\n",
                  "Host: " .. host .. ":" .. port .. "\r\n" }
    local has_body = body ~= nil and body ~= false
    for k, v in pairs(headers or {}) do
        req[#req + 1] = tostring(k) .. ": " .. tostring(v) .. "\r\n"
    end
    if has_body then
        req[#req + 1] = "Content-Length: " .. #body .. "\r\n"
    end
    req[#req + 1] = "\r\n"
    local ok_send, send_err = sock:send(table.concat(req))
    if not ok_send then sock:close(); return nil, send_err or "send failed" end
    if has_body then
        local ok_write, write_err = sock:send(body)
        if not ok_write then sock:close(); return nil, write_err or "write failed" end
    end
    local head = sock:receive("*l")
    if not head then sock:close(); return nil, "no response head" end
    local status = tonumber((head:match("^(%S+) (%d+)"))) or 0
    local hdrs = {}
    while true do
        local line = sock:receive("*l")
        if line == nil or line == "" then break end
        local k, v = line:match("^([^:]+):%s*(.*)$")
        if k then hdrs[lower(k)] = v end
    end
    local out
    local complete = true
    if hdrs["transfer-encoding"] and hdrs["transfer-encoding"]:lower():find("chunked") then
        local registry_mod = store_registry()
        if registry_mod and registry_mod.pump_chunked then
            out, complete = registry_mod.pump_chunked(sock, true)
        else
            out = {}
            while true do
                local size_line = sock:receive("*l")
                if not size_line then complete = false break end
                local size = tonumber(size_line:gsub("%s+$", ""), 16)
                if not size or size == 0 then break end
                local chunk = sock:receive(size)
                if not chunk then complete = false break end
                out[#out + 1] = chunk
                sock:receive(2)  -- trailing CRLF
            end
            out = table.concat(out)
        end
    else
        local len = tonumber(hdrs["content-length"] or "")
        if len then
            local parts = {}
            local remaining = len
            while remaining > 0 do
                local block = sock:receive(math.min(65536, remaining))
                if not block then complete = false break end
                parts[#parts + 1] = block
                remaining = remaining - #block
            end
            out = table.concat(parts)
        else
            -- Unframed answer: reading it to the end consumed the connection.
            out = sock:receive("*a") or ""
            complete = false
        end
    end
    if pool_cfg and complete then
        local registry_mod = store_registry()
        if registry_mod and registry_mod.release then
            registry_mod.release(sock, pool_cfg, registry_mod.response_reusable(
                hdrs, true), "store", url)
        else
            sock:close()
        end
    else
        sock:close()
    end
    return status, hdrs, out
end

--- JSON POST/GET helper: returns parsed value or nil, err.
function _M.request_json(method, url, payload, timeout_ms)
    local headers = { Accept = "application/json" }
    local body = false
    if payload ~= nil then
        headers["Content-Type"] = "application/json"
        body = cjson.encode(payload)
    end
    local status, _, resp_body = _M.raw_request(method, url, body, headers, timeout_ms)
    if not status then return nil, resp_body end
    local parsed = cjson.decode(resp_body or "")
    if not status or status < 200 or status >= 300 then
        local detail = type(parsed) == "table"
            and (parsed.error ~= nil and tostring(parsed.error) or "watcher rejected the request")
            or "watcher rejected the request"
        return nil, string.format("watcher said %d: %s", status, detail)
    end
    return parsed or {}
end

--- Forward a rename request to the watcher /model-map (Rust proxy_model_map).
function _M.proxy_model_map(url, body)
    return _M.request_json("POST", url .. "/model-map", body, 5000)
end

local function fetch_watcher_model_map(url)
    return _M.request_json("GET", url .. "/model-map", nil, 3000)
end

--- Full Config-page document: snapshot + env_defaults + watcher state.
function _M.document()
    local snap = snapshot_of(_M.current())
    -- The stored snapshot carries the secret for the persistence layer; the
    -- response half of contract 3.4 masks it here.
    snap.upstreams = sanitize_upstream_rows(snap.upstreams)
    snap.env_defaults = _M.env_defaults()
    local url = _M.watcher_url()
    local reachable, model_map = false, JSON_NULL
    if url then
        local map, err = fetch_watcher_model_map(url)
        if map then
            reachable = true
            model_map = map
        end
    end
    snap.watcher = { url = nul(url), reachable = reachable, model_map = model_map }
    snap.persist = { file = nul(env("LMR_CONFIG_FILE")) }
    return snap
end

-- ---------------------------------------------------------- registered models

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

--- models section: registered + configured models merged, one card each.
function _M.models_document()
    local cfg = _M.current()
    local order, sources = {}, {}
    local function note(model)
        if sources[model] == nil then
            sources[model] = {}
            order[#order + 1] = model
        end
    end
    for _, row in ipairs(registered_models()) do
        note(row.model)
        sources[row.model][#sources[row.model] + 1] = row.url
    end
    for _, model in ipairs(sorted_keys(cfg.model_configs)) do note(model) end
    for _, alias in ipairs(sorted_keys(cfg.virtual_models)) do note(alias) end
    table.sort(order)
    local models = {}
    for _, model in ipairs(order) do
        local card = cfg.model_configs[model]
        local map = {}
        if card then
            for _, from in ipairs(sorted_keys(card.effort_map)) do
                map[#map + 1] = { from = from, to = card.effort_map[from] }
            end
        end
        local doc = {
            model = model,
            registered = #sources[model] > 0,
            sources = arr(sources[model]),
            ctx = nul(card and card.ctx),
            default_effort = nul(card and card.default_effort),
            effort_map = arr(map),
            modalities = nul(card and card.modalities),
        }
        local target = cfg.virtual_models[model]
        if target then
            doc.target = target
        end
        models[#models + 1] = doc
    end
    return models
end

-- --------------------------------------------------------------- handlers

local function respond_json(status, payload)
    ngx.status = status
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode(payload))
    return ngx.exit(status)
end

_M.respond_json = respond_json

--- GET /_ui/config
function _M.handle_config_get()
    local doc = _M.document()
    doc.models = _M.models_document()
    return respond_json(ngx.HTTP_OK, doc)
end

local function read_json_body()
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if not raw then
        local file = ngx.req.get_body_file()
        if file then
            local f = io.open(file, "r")
            if f then raw = f:read("*a"); f:close() end
        end
    end
    if not raw or raw == "" then return nil, "empty request body" end
    local value, err = cjson.decode(raw)
    if value == nil then return nil, "invalid JSON body: " .. (err or "?") end
    return value
end

_M.read_json_body = read_json_body

--- POST /_ui/config 和 /_ui/config/effort
function _M.handle_config_effort()
    local body, err = read_json_body()
    if body == nil then return respond_json(ngx.HTTP_BAD_REQUEST, { error = err }) end
    local _, apply_err = _M.apply_effort(body)
    if apply_err then return respond_json(ngx.HTTP_BAD_REQUEST, { error = apply_err }) end
    return respond_json(ngx.HTTP_OK, _M.document())
end

--- POST /_ui/config/ctx  {model, ctx}
function _M.handle_config_ctx()
    local body, err = read_json_body()
    if body == nil then return respond_json(ngx.HTTP_BAD_REQUEST, { error = err }) end
    local _, apply_err = _M.apply_ctx(body.model, rawget(body, "ctx"))
    if apply_err then return respond_json(ngx.HTTP_BAD_REQUEST, { error = apply_err }) end
    return respond_json(ngx.HTTP_OK, _M.document())
end

--- POST /_ui/config/model  one model card
function _M.handle_config_model()
    local body, err = read_json_body()
    if body == nil then return respond_json(ngx.HTTP_BAD_REQUEST, { error = err }) end
    local _, apply_err = _M.apply_model_config(body)
    if apply_err then return respond_json(ngx.HTTP_BAD_REQUEST, { error = apply_err }) end
    local doc = _M.document()
    doc.models = _M.models_document()
    return respond_json(ngx.HTTP_OK, doc)
end

--- POST /_ui/config/virtual  {entries:[{model,target}]}
function _M.handle_config_virtual()
    local body, err = read_json_body()
    if body == nil then return respond_json(ngx.HTTP_BAD_REQUEST, { error = err }) end
    if type(body) ~= "table" then
        return respond_json(ngx.HTTP_BAD_REQUEST, { error = "body must be a JSON object" })
    end
    local entries = rawget(body, "entries")
    if entries == nil then entries = setmetatable({}, EMPTY_ARRAY_MT) end
    local _, apply_err = _M.apply_virtual_models(entries)
    if apply_err then return respond_json(ngx.HTTP_BAD_REQUEST, { error = apply_err }) end
    return respond_json(ngx.HTTP_OK, _M.document())
end

--- POST /_ui/config/upstreams  {entries:[{url,model_id?,api_key?,priority?,
---   cost?,labels?,disable_health_check?}]}
--- Whole-list replace of the declared pool plus an immediate reconcile into
--- lr_workers (contract 3.5). entries missing = empty list = reclaim every
--- config row (root ruling 3: the UI always sends the full list and covers the
--- destructive edit with its own confirmation). The response is the document
--- with a top-level reconcile counter bag.
function _M.handle_config_upstreams()
    local body, err = read_json_body()
    if body == nil then return respond_json(ngx.HTTP_BAD_REQUEST, { error = err }) end
    if type(body) ~= "table" then
        return respond_json(ngx.HTTP_BAD_REQUEST, { error = "body must be a JSON object" })
    end
    local entries = rawget(body, "entries")
    if entries == nil then entries = setmetatable({}, EMPTY_ARRAY_MT) end
    local summary, apply_err = _M.apply_upstreams(entries)
    if apply_err then return respond_json(ngx.HTTP_BAD_REQUEST, { error = apply_err }) end
    local doc = _M.document()
    doc.reconcile = summary
    return respond_json(ngx.HTTP_OK, doc)
end

--- GET /_ui/config/policy — routing-page document (chain + per-model rows).
function _M.handle_config_policy_get()
    return respond_json(ngx.HTTP_OK, _M.policy_document())
end

--- PUT/POST /_ui/config/policy — change the routing policy at runtime. The
--- response is the fresh document, which is how the page confirms the change.
function _M.handle_config_policy()
    local body, err = read_json_body()
    if body == nil then return respond_json(ngx.HTTP_BAD_REQUEST, { error = err }) end
    local _, apply_err = _M.apply_policy(body)
    if apply_err then return respond_json(ngx.HTTP_BAD_REQUEST, { error = apply_err }) end
    return respond_json(ngx.HTTP_OK, _M.policy_document())
end

--- POST /_ui/config/model-map  forward verbatim to the watcher.
function _M.handle_config_model_map()
    local body, err = read_json_body()
    if body == nil then return respond_json(ngx.HTTP_BAD_REQUEST, { error = err }) end
    local url = _M.watcher_url()
    if not url then
        return respond_json(ngx.HTTP_SERVICE_UNAVAILABLE,
            { ok = false, error = "watcher not configured (set LMR_WATCHER_URL)" })
    end
    local result, proxy_err = _M.proxy_model_map(url, body)
    if not result then
        return respond_json(ngx.HTTP_BAD_GATEWAY, { ok = false, error = proxy_err })
    end
    result.ok = true
    return respond_json(ngx.HTTP_OK, result)
end

--- POST /_ui/config/apply  whole-document replace, optional model_map section.
function _M.handle_config_apply()
    local patch, err = read_json_body()
    if patch == nil then return respond_json(ngx.HTTP_BAD_REQUEST, { error = err }) end
    if type(patch) ~= "table" then
        -- never a whole-document wipe by accident: only an object is a document
        return respond_json(ngx.HTTP_BAD_REQUEST, { error = "body must be a JSON object" })
    end
    local model_map
    if type(patch) == "table" then
        model_map = rawget(patch, "model_map")
        patch.model_map = nil
    end
    local _, apply_err, reconcile = _M.apply_document(patch)
    if apply_err then return respond_json(ngx.HTTP_BAD_REQUEST, { error = apply_err }) end
    local doc = _M.document()
    if reconcile then doc.reconcile = reconcile end
    local warning
    if model_map ~= nil and model_map ~= JSON_NULL then
        local map = model_map
        if type(map) == "string" then
            map = { map = map }
        elseif type(map) ~= "table" then
            warning = "model_map must be an object or an orig:new string"
            map = nil
        end
        if map then
            local url = _M.watcher_url()
            if not url then
                warning = "watcher not configured; model_map not applied"
            else
                local result, proxy_err = _M.proxy_model_map(url, map)
                if result then
                    doc.watcher_model_map = result
                else
                    warning = "model_map not applied: " .. tostring(proxy_err)
                end
            end
        end
    end
    doc.models = _M.models_document()
    if warning then doc.warning = warning end
    return respond_json(ngx.HTTP_OK, doc)
end

return _M
