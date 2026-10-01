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

-- Capability toggles the Config page exposes per model; text is always on.
local MODALITY_LEVELS = { "text", "image", "video", "audio" }
local MODALITY_SET = {}
for _, v in ipairs(MODALITY_LEVELS) do MODALITY_SET[v] = true end

local DICT_NAME = "luarouter_config"
local DICT_KEY = "runtime_config"
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

--- LMR_* names the module reads. Declared here so capture_env() can snapshot
--- them once in the master process (nginx strips undeclared variables from
--- worker environments, so os.getenv returns nil inside request phases).
_M.ENV_NAMES = {
    "LMR_DEFAULT_EFFORT", "LMR_EFFORT_MAP", "LMR_MODEL_CTX", "LMR_MODEL_EFFORT",
    "LMR_MODEL_EFFORT_MAP", "LMR_MODEL_MODALITIES", "LMR_VIRTUAL_MODELS",
    "LMR_WATCHER_URL", "LMR_CONFIG_FILE", "LMR_UI_DIR", "LMR_UI_ROUTER_MODE",
    "LMR_LOGS_BUFFER",
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
            cfg.virtual_models[alias] = target
        end
    end
    return cfg
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
        virtual_models[#virtual_models + 1] = { model = alias, target = cfg.virtual_models[alias] }
    end
    return {
        default_effort = nul(cfg.default_effort),
        effort_map = arr(effort_map),
        model_ctx = arr(model_ctx),
        model_effort = arr(model_effort),
        model_configs = arr(model_configs),
        virtual_models = arr(virtual_models),
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
local function cfg_from_document(doc)
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
        for _, entry in ipairs(doc.virtual_models) do
            local alias = trim(entry.model)
            local target = trim(entry.target)
            if alias == "" then return nil, "virtual_models entries need a model (the alias)" end
            if target == "" then
                return nil, string.format("virtual model %s needs a target model", alias)
            end
            if alias == target then
                return nil, string.format("virtual model %s must differ from its target", alias)
            end
            cfg.virtual_models[alias] = target
        end
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
    return ngx.shared[DICT_NAME]
end

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
        local now = ngx.now()
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
        _M._env_defaults = snapshot_of(cfg_from_env())
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

--- Virtual alias -> real upstream id; unknown names pass through unchanged.
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

--- Whole-list replace for the virtual model table.
function _M.apply_virtual_models(entries)
    if not is_array(entries) then return nil, "virtual_models must be an array" end
    local built = {}
    for _, entry in ipairs(entries) do
        local alias = trim(entry.model)
        local target = trim(entry.target)
        if alias == "" or target == "" then
            return nil, "virtual model entries need both model and target"
        end
        if alias == target then
            return nil, string.format("virtual model %s must differ from its target", alias)
        end
        built[alias] = target
    end
    local cfg = _M.current()
    cfg.virtual_models = built
    write_snapshot(snapshot_of(cfg))
    return snapshot_of(_M.current()), nil
end

--- Whole-document replace (JSON editor). Validate first: nothing half-applies.
function _M.apply_document(doc)
    local cfg, err = cfg_from_document(doc)
    if not cfg then return nil, err end
    write_snapshot(snapshot_of(cfg))
    return snapshot_of(_M.current()), nil
end

-- ------------------------------------------------------------- watcher

function _M.watcher_url()
    return env("LMR_WATCHER_URL")
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
local function registered_models()
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
    local entries = body.entries
    if entries == nil then entries = setmetatable({}, EMPTY_ARRAY_MT) end
    local _, apply_err = _M.apply_virtual_models(entries)
    if apply_err then return respond_json(ngx.HTTP_BAD_REQUEST, { error = apply_err }) end
    return respond_json(ngx.HTTP_OK, _M.document())
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
    local model_map
    if type(patch) == "table" then
        model_map = rawget(patch, "model_map")
        patch.model_map = nil
    end
    local _, apply_err = _M.apply_document(patch)
    if apply_err then return respond_json(ngx.HTTP_BAD_REQUEST, { error = apply_err }) end
    local doc = _M.document()
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
