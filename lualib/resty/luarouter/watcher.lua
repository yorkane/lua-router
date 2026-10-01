-- In-process worker watcher: discovery + registration (doc/gap-watcher-merge.md).
--
-- Semantic port of the standalone llm-watcher daemon
-- (llm-router/watcher/llm_watcher.py, 1577 lines plus its README). The Python
-- daemon reconciled a running router through its HTTP control plane
-- (POST/DELETE /workers, 202 = queued); this module runs inside the router, so
-- registration is a direct registry.add / registry.remove call and the ledger
-- lives in a shared dict instead of a JSON file on disk.
--
-- The nine guards the Python version documents, and where each one lives here:
--   1. never add the router itself    -> classify() router fingerprint + is_self_url()
--      (own SMG_PORT / SMG_METRICS_PORT are never even candidates)
--   2. only real OpenAI endpoints     -> classify(): /v1/models must answer
--      data[].id, which is what keeps node_exporter and HTML 404 pages out
--   3. protect the pre-existing pool  -> first-contact snapshot into `protected`,
--      never deleted (they were written by SMG_WORKER_URLS or by a human)
--   4. only delete what it owns       -> removals iterate the ledger's owned set,
--      and unregister() re-checks that the id still maps to that URL
--   5. remove grace                   -> missing_since + remove_grace_secs
--   6. never empty a model            -> is_last_for_model() + keep_last_grace_secs
--   7. release stuck adds             -> reap_pending()
--   8. survive a router restart       -> refresh_ids() re-reads the worker ids
--   9. blind by design                -> no GPU reads, no service control, only
--      /v1/models, /server_info, /get_server_info, /props, /metrics and /health
--
-- Two layers, so the semantics are testable without nginx (same split as
-- mesh.lua): the pure functions below take an injected `fetch`/`getenv`/store,
-- and the live wiring at the bottom resolves ngx, hb, registry and docker.

local cjson = require "cjson.safe"

local _M = { _VERSION = "0.1.0" }

local has_ngx = (type(ngx) == "table")

local json_encode = cjson.encode
local json_decode = cjson.decode

---Provenance written into every worker this watcher registers (metadata of the
---same name on GET /workers, so an operator can tell managed rows from hand-made
---ones, exactly like the daemon's llm-watcher label).
_M.MANAGED_BY = "router-watch"

---Keys whose presence in a /server_info body means "this is another router"
---(llm_watcher.py ROUTER_FINGERPRINT_KEYS).
_M.ROUTER_FINGERPRINT_KEYS = { "router_manager", "workers_count", "routers_count" }

---Infrastructure ports never worth probing (llm_watcher.py DEFAULT_DENY_PORTS).
---Deliberately short: the probe is the real gate, this only trims noise, and
---inference servers do sit on web-default ports like 8080 or 3000.
_M.DEFAULT_DENY_PORTS = {
    [22] = true, [25] = true, [53] = true, [111] = true, [135] = true,
    [139] = true, [445] = true, [631] = true, [1433] = true, [1521] = true,
    [2049] = true, [3306] = true, [3389] = true, [5432] = true, [5900] = true,
    [6379] = true, [6443] = true, [9100] = true, [9400] = true,
    [11211] = true, [27017] = true,
}

-- ------------------------------------------------------------------ small utils

local function trim(value)
    if type(value) ~= "string" then
        return value
    end
    return (value:gsub("^%s*(.-)%s*$", "%1"))
end

local function is_blank(value)
    return value == nil or value == cjson.null
end

local function lower(value)
    return string.lower(tostring(value))
end

---Percent-encode everything a URI component cannot carry (ngx.escape_uri is not
---available to the pure layer, and the docker filter JSON needs this exactly).
local function uri_encode(text)
    return (tostring(text):gsub("[^%w%-_.~]", function(char)
        return string.format("%%%02X", char:byte())
    end))
end

---Sorted iteration, so a reconcile pass makes the same decisions in the same
---order in every process (the Python daemon sorted the same way).
local function sorted_keys(map)
    local out = {}
    for key in pairs(map) do
        out[#out + 1] = key
    end
    table.sort(out)
    return out
end

-- The config layer accepts the same value spellings as resty.luarouter.config
-- (1/true/yes/on), so one compose vocabulary covers the whole router.
local function bool_from(getenv, name, default)
    local value = getenv(name)
    if value == nil or value == "" then
        return default
    end
    value = lower(trim(value))
    if value == "1" or value == "true" or value == "yes" or value == "on" then
        return true
    end
    if value == "0" or value == "false" or value == "no" or value == "off" then
        return false
    end
    return default
end

local function num_from(getenv, name, default)
    local value = getenv(name)
    if value == nil or trim(value) == "" then
        return default
    end
    local parsed = tonumber(trim(value))
    if not parsed then
        return default
    end
    return parsed
end

---Comma/space separated list, dropping empty fields.
local function split_list(value)
    local out = {}
    if type(value) ~= "string" then
        return out
    end
    for item in string.gmatch(value, "[^,;%s]+") do
        if item ~= "" then
            out[#out + 1] = item
        end
    end
    return out
end

---Comma/";"/space separated list of non-empty fields (the daemon's env lists).
local function list_from(getenv, name)
    return split_list(getenv(name))
end

-- ------------------------------------------------------------------ url shapes

---Canonical worker key: scheme://host[:port], no path, no trailing slash,
---default port dropped (llm_watcher.py normalize_url).
---@param url string
---@return string|nil normalized, string|nil err
function _M.normalize_url(url)
    if type(url) ~= "string" then
        return nil, "url is required"
    end
    url = trim(url)
    if url == "" then
        return nil, "url is required"
    end
    if not string.find(url, "://", 1, true) then
        url = "http://" .. url
    end
    local scheme, rest = string.match(url, "^(%a[%w+.-]*)://(.*)$")
    if not scheme then
        return nil, "invalid worker url: " .. url
    end
    scheme = lower(scheme)
    if scheme ~= "http" and scheme ~= "https" then
        return nil, "unsupported worker url scheme \"" .. scheme
            .. "\" (only http and https are proxied)"
    end
    local authority = string.match(rest, "^([^/]+)")
    if not authority or authority == "" then
        return nil, "invalid worker url: " .. url
    end
    local host, port
    if string.sub(authority, 1, 1) == "[" then
        -- The port has to come off the *outside* of the bracket group: a pattern
        -- that captures ":8000" and then tonumber()s it silently loses the port,
        -- which made every bracketed IPv6 worker look like port 80 to the self-port
        -- guard.
        local bracketed, tail = string.match(authority, "^(%[[^%]]+%])(.*)$")
        if not bracketed then
            return nil, "invalid worker url: " .. url
        end
        host = bracketed
        if tail ~= "" then
            port = tonumber(string.match(tail, "^:(%d+)$"))
            if not port then
                return nil, "invalid worker url: " .. url
            end
        end
    else
        -- Last colon wins the port (a userinfo host has already been dropped by
        -- the callers, which only ever build host:port from a socket table).
        host, port = string.match(authority, "^([^:]*):?(%d*)$")
        if not host or host == "" then
            return nil, "invalid worker url: " .. url
        end
    end
    host = lower(host)
    port = tonumber(port)
    if port and ((scheme == "http" and port == 80)
        or (scheme == "https" and port == 443)) then
        port = nil
    end
    if port then
        return scheme .. "://" .. host .. ":" .. port
    end
    return scheme .. "://" .. host
end

---scheme, host, port of an already-normalized url (port resolved to the scheme
---default so a self-port comparison never has to care about spelling).
---@param url string
---@return string|nil scheme, string|nil host, number|nil port
function _M.split_http(url)
    local normalized, err = _M.normalize_url(url)
    if not normalized then
        return nil, nil, nil
    end
    local scheme, rest = string.match(normalized, "^(%a[%w+.-]*)://(.*)$")
    local host, port
    if string.sub(rest, 1, 1) == "[" then
        local bracketed, tail = string.match(rest, "^(%[[^%]]+%])(.*)$")
        if not bracketed then
            return nil, nil, nil
        end
        host = bracketed
        port = tonumber(string.match(tail, "^:(%d+)$"))
    else
        host, port = string.match(rest, "^([^:]*):?(%d*)$")
    end
    if not host then
        return nil, nil, nil
    end
    return scheme, host, tonumber(port)
        or ((scheme == "https") and 443 or 80)
end

local LOOPBACK = { ["127.0.0.1"] = true, localhost = true, ["::1"] = true }

---Self-loop guard: a loopback candidate on one of the router's own ports.
---
---Only loopback counts, because a router reached through its LAN address is a
---different deployment as far as the pool is concerned (and classify() still
---rejects it on the /server_info fingerprint).
---@param url string
---@param ports table|nil @ {port, ...} of the router's own listeners
---@return boolean
function _M.is_self_url(url, ports)
    local scheme, host, port = _M.split_http(url)
    if not scheme or not port then
        return false
    end
    -- split_http keeps the brackets on an IPv6 literal, and the loopback one is
    -- spelled "::1" in the table.
    local bare = host:match("^%[(.-)%]$") or host
    if not LOOPBACK[bare] then
        return false
    end
    for i = 1, #(ports or {}) do
        if ports[i] and ports[i] == port then
            return true
        end
    end
    return false
end

-- ------------------------------------------------------------------ model map

---Public model id for one advertised id (llm_watcher.py _model_name): the
---optional short-name transform, then the map (keyed on either spelling).
---@param raw string
---@param map table|nil @ original -> public
---@param short boolean|nil @ basename without the weights suffix
---@return string
function _M.model_name(raw, map, short)
    local name = tostring(raw or "")
    if short then
        name = trim((name:gsub("/+$", "")))
        name = (name:gsub("^.*[/\\]", ""))
        local low = lower(name)
        for _, suffix in ipairs({ ".gguf", ".safetensors", ".bin", ".pt", ".ckpt" }) do
            if string.sub(low, -#suffix) == suffix then
                name = string.sub(name, 1, #name - #suffix)
                break
            end
        end
        if trim(name) == "" then
            name = tostring(raw)
        end
    end
    if type(map) == "table" then
        local by_raw = map[raw]
        if type(by_raw) == "string" and by_raw ~= "" then
            return by_raw
        end
        local by_short = map[name]
        if type(by_short) == "string" and by_short ~= "" then
            return by_short
        end
    end
    return name
end

---`orig1:new1,orig2:new2` -> {orig = new} (llm_watcher.py parse_model_map).
---A blank value drops nothing here; deletion is a POST /model-map concern.
---@param spec string|nil
---@return table map, string[] ignored
function _M.parse_model_map(spec)
    local out, ignored = {}, {}
    if type(spec) ~= "string" then
        return out, ignored
    end
    for part in string.gmatch(spec, "[^,;\n]+") do
        part = trim(part)
        if part ~= "" then
            local orig, sep, new = string.match(part, "^([^:]*)(:)(.*)$")
            if not sep or trim(orig or "") == "" or trim(new or "") == "" then
                ignored[#ignored + 1] = part
            else
                out[trim(orig)] = trim(new)
            end
        end
    end
    return out, ignored
end

---Merge renames (llm_watcher.py set_model_map): an empty new id deletes.
---@param current table
---@param incoming table
---@return table merged, number deleted
function _M.merge_map(current, incoming)
    local merged = {}
    for key, value in pairs(current or {}) do
        merged[key] = value
    end
    local deleted = 0
    for key, value in pairs(incoming or {}) do
        local orig = trim(key)
        if orig ~= "" then
            local new = trim(value)
            if new == nil or new == cjson.null or new == "" then
                if merged[orig] ~= nil then
                    deleted = deleted + 1
                end
                merged[orig] = nil
            else
                merged[orig] = new
            end
        end
    end
    return merged, deleted
end

---Value coercion for a decoded JSON rename object: null is the empty string
---(that is how `{"a.gguf":""}` deletes), everything else is its text.
local function map_value(value)
    if is_blank(value) then
        return ""
    end
    return tostring(value)
end

---Decode a pairs text ("a:b,c:d", any of comma / ";" / newline).
---@return table|nil mapping, string[]|nil bad
local function pairs_to_map(text)
    local mapping, bad = {}, {}
    for chunk in string.gmatch(text, "[^,;\n]+") do
        local part = trim(chunk)
        if part ~= "" then
            local orig, sep, new = string.match(part, "^([^:]*)(:)(.*)$")
            if not sep or trim(orig or "") == "" then
                bad[#bad + 1] = part
            else
                mapping[trim(orig)] = trim(new)
            end
        end
    end
    if #bad > 0 then
        return nil, bad
    end
    return mapping
end

---Turn a POST /model-map body into ({original = new}, error).
---
---Port of parse_model_map_body, four accepted shapes and all: the plain object
---{"orig":"new"}, the same wrapped as {"map":{...}}, a bare pairs string
---"a:b,c:d", and the pairs string wrapped as {"map":"a:b,c:d"}. That last form
---used to fall into the object branch, which made the literal key "map" the
---original id so the rename silently never happened (hit on 217.t). An empty
---wrapper is deliberately NOT unwrapped, so {"map":""} stays a plain-object
---delete: that is the documented way to clear a poisoned entry whose key reads
---"map" (the cjson trap here is that `{}` decodes to an empty table with no
---object/array marker, so an empty table is taken for the object form exactly
---like Python takes an empty dict).
---@param raw string|nil
---@return table|nil mapping, table|nil err
function _M.parse_model_map_body(raw)
    local text = trim(raw or "")
    if text == "" then
        return nil, { error = 'empty body; send {"original":"new"} or '
            .. "original:new (an empty new id deletes the entry)" }
    end
    if string.sub(text, 1, 1) == "{" then
        local obj = json_decode(text)
        if type(obj) ~= "table" then
            return nil, { error = "invalid JSON" }
        end
        if rawget(obj, "map") ~= nil or next(obj) == nil then
            -- `{"map": ...}`: unwrap the two wrapped spellings.
            local wrapped = rawget(obj, "map")
            if type(wrapped) == "table" then
                local out = {}
                for key, value in pairs(wrapped) do
                    if type(key) == "string" then
                        out[key] = map_value(value)
                    end
                end
                return out
            elseif type(wrapped) == "string" and trim(wrapped) ~= "" then
                text = wrapped
            else
                -- {"map":null}, {"map":""} and {"map":{}} stay in the object
                -- branch: the literal "map" key is then deleted (or untouched).
                local out = {}
                for key, value in pairs(obj) do
                    if type(key) == "string" then
                        out[key] = map_value(value)
                    end
                end
                return out
            end
        else
            local out = {}
            for key, value in pairs(obj) do
                if type(key) == "string" then
                    out[key] = map_value(value)
                end
            end
            return out
        end
    end
    local mapping, bad = pairs_to_map(text)
    if not mapping then
        return nil, { error = "want original:new per entry", ignored = bad }
    end
    return mapping
end

---Worker URL list from comma / ";" / whitespace separated text (parse_targets).
---@param spec string|nil
---@return string[]
function _M.parse_targets(spec)
    return split_list(spec)
end

---`SMG_WATCHER_EXCLUDE` gate (the daemon's compiled regexes).
---
---The dialect is a Lua pattern rather than a POSIX regex, and a pattern Lua rejects
---(an unbalanced bracket) is then tried as a plain substring -- which is what
---`--exclude node-exporter` means either way. The difference only bites on
---`[0-9]`-style classes, which are written `%d` here.
---@param url string
---@param patterns string[]|nil
---@return boolean
function _M.is_excluded(url, patterns)
    for i = 1, #(patterns or {}) do
        local pattern = patterns[i]
        if type(pattern) == "string" and pattern ~= "" then
            local ok, found = pcall(string.find, url, pattern)
            if ok and found then
                return true
            elseif not ok and string.find(url, pattern, 1, true) then
                return true
            end
        end
    end
    return false
end

---`8000-8020,11434` -> set of ports (parse_ports).
---@param spec string|nil
---@return table ports
function _M.parse_ports(spec)
    local out = {}
    if type(spec) ~= "string" then
        return out
    end
    for part in string.gmatch(spec, "[^,;%s]+") do
        part = trim(part)
        if part ~= "" then
            local lo, hi = string.match(part, "^(%d+)%-(%d+)$")
            if lo then
                for port = tonumber(lo), tonumber(hi) do
                    out[port] = true
                end
            else
                local single = tonumber(part)
                if single then
                    out[single] = true
                end
            end
        end
    end
    return out
end

---GPU ids embedded in a container/service name (pennyroyal-gpu7 -> "7",
---qwen3.8-flashnext-gpu45 -> "45"), nil when the name carries no hint.
---@param name string|nil
---@return string|nil
function _M.gpu_from_name(name)
    if type(name) ~= "string" then
        return nil
    end
    return string.match(name, "[Gg][Pp][Uu](%d+)")
end


-- ------------------------------------------------------------------ env config

---All knobs read from the environment. Names mirror the daemon's LLM_WATCHER_*
---ones with the SMG_ prefix (the router's own vocabulary), and doc/gap-watcher-merge.md
---carries the mapping table.
---@param getenv function
---@param self_ports number|number[]|nil @ this router's SMG_PORT (a list is accepted
---        so a caller holding several listeners can pass them all)
---@param metrics_port number|nil @ this router's SMG_METRICS_PORT
---@return table
function _M.new_config(getenv, self_ports, metrics_port)
    local ports = {}
    if type(self_ports) == "table" then
        for i = 1, #self_ports do
            local port = tonumber(self_ports[i])
            if port then
                ports[#ports + 1] = port
            end
        end
    elseif tonumber(self_ports) then
        ports[#ports + 1] = tonumber(self_ports)
    end
    if metrics_port and metrics_port > 0 then ports[#ports + 1] = metrics_port end
    local cfg = {
        enabled = bool_from(getenv, "SMG_WATCHER_ENABLED", false),
        targets = list_from(getenv, "SMG_WATCHER_TARGETS"),
        scan_docker = bool_from(getenv, "SMG_WATCHER_DOCKER", false),
        scan_proc = bool_from(getenv, "SMG_WATCHER_PROC_SCAN", false),
        -- Unpublished container IPs are only reachable from a container that
        -- shares the bridge (our own listeners are reached through the host
        -- stack otherwise), so this mirrors the daemon's --container-ips.
        scan_container_ips = bool_from(getenv, "SMG_WATCHER_CONTAINER_IPS", true),
        docker_socket = trim(getenv("SMG_WATCHER_DOCKER_SOCKET"))
            or "/var/run/docker.sock",
        interval_secs = num_from(getenv, "SMG_WATCHER_INTERVAL_SECS", 15),
        probe_timeout_secs = num_from(getenv, "SMG_WATCHER_PROBE_TIMEOUT_SECS", 4),
        remove_grace_secs = num_from(getenv, "SMG_WATCHER_REMOVE_GRACE_SECS", 300),
        keep_last_grace_secs = num_from(getenv, "SMG_WATCHER_KEEP_LAST_GRACE_SECS", 1800),
        allow_remove = bool_from(getenv, "SMG_WATCHER_ALLOW_REMOVE", true),
        max_models = num_from(getenv, "SMG_WATCHER_MAX_MODELS", 8),
        require_health = bool_from(getenv, "SMG_WATCHER_REQUIRE_HEALTH", false),
        allow_models_only = bool_from(getenv, "SMG_WATCHER_ALLOW_MODELS_ONLY", false),
        short_model_names = bool_from(getenv, "SMG_WATCHER_SHORT_MODEL_NAMES", false),
        add_confirm_timeout_secs = num_from(getenv, "SMG_WATCHER_ADD_CONFIRM_TIMEOUT_SECS", 180),
        exclude_patterns = list_from(getenv, "SMG_WATCHER_EXCLUDE"),
        allow_ports = _M.parse_ports(getenv("SMG_WATCHER_ALLOW_PORT")),
        deny_ports = _M.parse_ports(getenv("SMG_WATCHER_DENY_PORT")),
        self_ports = ports,
        model_map = _M.parse_model_map(
            getenv("SMG_WATCHER_MODEL_MAP") or getenv("LMR_MODEL_MAP") or ""),
    }
    if cfg.interval_secs < 1 then cfg.interval_secs = 1 end
    if cfg.probe_timeout_secs < 1 then cfg.probe_timeout_secs = 1 end
    if cfg.max_models < 0 then cfg.max_models = 0 end
    -- The daemon spells "never empty a model, but let it expire" as two knobs
    -- (--no-keep-last plus --keep-last-grace). One number carries both here:
    -- 0 protects the last worker forever, a negative value switches the guard off
    -- (reconcile tests keep_last_grace_secs >= 0), so SMG_WATCHER_KEEP_LAST=false
    -- is the --no-keep-last spelling and LLM_WATCHER_KEEP_LAST maps onto it.
    if not bool_from(getenv, "SMG_WATCHER_KEEP_LAST", true) then
        cfg.keep_last_grace_secs = -1
    end
    return cfg
end

-- ------------------------------------------------------------------ probe

local function as_int(status)
    return tonumber(status) or 0
end

---One probe hop: fetch via the injected getter and decode defensively.
---@param fetch function @ (url) -> status, body, err
---@param url string
---@return number status, table|nil json, string|nil raw
local function get_json(fetch, url)
    local status, body = fetch(url)
    local code = as_int(status)
    if type(body) ~= "string" then
        return code, nil, nil
    end
    local decoded = json_decode(body)
    if type(decoded) ~= "table" then
        return code, nil, body
    end
    return code, decoded, body
end

---Ask a candidate whether it really is an inference worker.
---
---Port of probe_worker. Accept returns {url, models, engine, has_health}; a
---rejection returns nil plus a one-line reason (the reason is logged with a
---per-url rate limit, so a busy host does not fill the error log with the same
---"that is nginx" note every 15 s).
---@param url string
---@param opts table|nil @ {fetch, require_health, max_models, allow_models_only}
---@return table|nil info, string|nil reason
function _M.classify(url, opts)
    opts = opts or {}
    local fetch = opts.fetch
    if type(fetch) ~= "function" then
        return nil, "no probe transport"
    end
    local max_models = tonumber(opts.max_models) or 0

    local status, payload, raw = get_json(fetch, url .. "/v1/models")
    if status < 200 or status >= 400 or raw == nil then
        return nil, "no /v1/models answer"
    end
    local ids = {}
    local data = type(payload) == "table" and payload.data or nil
    if type(data) == "table" then
        for i = 1, #data do
            local item = data[i]
            if type(item) == "table"
                and (type(item.id) == "string" or type(item.id) == "number") then
                ids[#ids + 1] = tostring(item.id)
            end
        end
    end
    if #ids == 0 then
        -- An HTML/JSON service that is not an OpenAI model endpoint: this is the
        -- gate that keeps node_exporter and every 404 page out of the pool.
        return nil, "/v1/models answers without data[].id"
    end

    -- A server advertising dozens of models is an aggregator or another proxy,
    -- not a worker: routing through it adds a hop and can loop back here.
    if max_models > 0 and #ids > max_models then
        return nil, string.format("advertises %d models (> max-models %d), looks like a proxy",
            #ids, max_models)
    end

    -- Self-loop guard, second half: another router also serves /v1/models.
    local info_status, server_info = get_json(fetch, url .. "/server_info")
    if info_status >= 200 and info_status < 400 and type(server_info) == "table" then
        for i = 1, #_M.ROUTER_FINGERPRINT_KEYS do
            if rawget(server_info, _M.ROUTER_FINGERPRINT_KEYS[i]) ~= nil then
                return nil, "it is a router, not a worker"
            end
        end
    end

    local engine = "openai"
    local gsi_status, gsi = get_json(fetch, url .. "/get_server_info")
    local props_status, props = get_json(fetch, url .. "/props")
    local metrics_status, _, metrics_raw = get_json(fetch, url .. "/metrics")
    local metrics_text = metrics_raw or ""
    if gsi_status >= 200 and gsi_status < 400 and type(gsi) == "table"
        and (rawget(gsi, "disaggregation_mode") ~= nil or rawget(gsi, "tp_size") ~= nil
            or rawget(gsi, "model_path") ~= nil) then
        engine = "sglang"
    elseif info_status >= 200 and info_status < 400 and type(server_info) == "table"
        and rawget(server_info, "model_path") ~= nil then
        engine = "sglang"
    elseif string.find(metrics_text, "vllm:", 1, true) then
        engine = "vllm"
    elseif string.find(metrics_text, "llamacpp:", 1, true) then
        engine = "llama.cpp"
    elseif props_status >= 200 and props_status < 400 and type(props) == "table"
        and (rawget(props, "build_commit") ~= nil or rawget(props, "build_number") ~= nil
            or rawget(props, "webui") ~= nil) then
        engine = "llama.cpp"
    end

    local health_status = as_int((fetch(url .. "/health")))
    local has_health = health_status >= 200 and health_status < 400
    if opts.require_health and not has_health then
        return nil, "no usable /health endpoint"
    end

    -- /v1/models alone is not enough: an API gateway that only proxies the /v1
    -- surface answers it happily while /health and /metrics both 5xx (measured on
    -- 21.k's openresty :9080, which registered as a worker and then failed every
    -- AddWorker job). A 404 only means the engine did not implement the endpoint,
    -- so only a 5xx on BOTH counts as the proxy signal.
    if engine == "openai" and health_status >= 500 and metrics_status >= 500
        and not opts.allow_models_only then
        return nil, "/v1/models answers but /health and /metrics both 5xx -- an "
            .. "upstream/gateway, not a worker (or set SMG_WATCHER_ALLOW_MODELS_ONLY=1)"
    end

    return { url = url, models = ids, engine = engine, has_health = has_health }
end

-- ------------------------------------------------------------------ discovery

---Listening TCP sockets as {host, port} from /proc/net/tcp{,6}.
---
---Pure Lua (io.open, no io.popen): this is what catches host-network containers
---(their ports are published by the kernel, not by docker-proxy) and bare native
---processes such as a llama.cpp server. 0A is the TCP_LISTEN state.
---@param reader function|nil @ (path) -> lines (injectable for tests)
---@return table[] @ { {host=, port=}, ... } unique
function _M.listening_sockets(reader)
    reader = reader or function(path)
        local handle = io.open(path, "r")
        if not handle then
            return nil
        end
        local text = handle:read("*a")
        handle:close()
        return text
    end
    local out, seen = {}, {}
    for _, spec in ipairs({ { "/proc/net/tcp", false }, { "/proc/net/tcp6", true } }) do
        local text = reader(spec[1])
        if type(text) == "string" then
            local is_v6 = spec[2]
            local first = true
            for line in string.gmatch(text, "[^\n]+") do
                if first then
                    first = false   -- the header line
                else
                    local fields = {}
                    for field in string.gmatch(line, "%S+") do
                        fields[#fields + 1] = field
                    end
                    if #fields >= 4 and fields[4] == "0A" then
                    local hex_ip, hex_port = string.match(fields[2], "^([^:]+):(%x+)$")
                    local port = tonumber(hex_port, 16)
                    if hex_ip and port then
                        local host
                        -- The kernel prints the hex in lower case; normalising keeps
                        -- the v4-mapped test below from depending on it.
                        hex_ip = string.lower(hex_ip)
                        if not is_v6 then
                            local parts = {}
                            for i = 1, 4 do
                                parts[i] = tonumber(string.sub(hex_ip, (i - 1) * 2 + 1, i * 2), 16)
                            end
                            -- little-endian hex -> dotted quad
                            host = table.concat({ parts[4], parts[3], parts[2], parts[1] }, ".")
                        else
                            -- /proc stores an IPv6 address as four little-endian
                            -- 32-bit words, so the bytes have to be reversed inside
                            -- each word before the address can be read. The daemon
                            -- compares the *raw* hex against "0..01" and
                            -- "0..ffff.." instead, which real /proc output never
                            -- spells that way, so a ::1 or a v4-mapped listener is
                            -- mis-decoded there and the self-loop guard then misses
                            -- it. Swapping first makes both cases come out right.
                            local bytes = {}
                            for word = 1, 4 do
                                local group = string.sub(hex_ip, (word - 1) * 8 + 1, word * 8)
                                if #group ~= 8 then
                                    bytes = nil
                                    break
                                end
                                for b = 4, 1, -1 do
                                    bytes[#bytes + 1] = string.sub(group, (b - 1) * 2 + 1, b * 2)
                                end
                            end
                            local wire = bytes and table.concat(bytes) or nil
                            if not wire or #wire ~= 32 then
                                -- malformed line: skip it rather than guess
                            elseif wire == string.rep("0", 32) then
                                host = "::"
                            elseif wire == string.rep("0", 31) .. "1" then
                                host = "::1"
                            elseif string.sub(wire, 1, 24) == string.rep("0", 20) .. "ffff" then
                                -- v4-mapped: ten zero bytes, two 0xff bytes, then the
                                -- address itself (which is big-endian once swapped).
                                local parts = {}
                                for i = 1, 4 do
                                    parts[i] = tonumber(string.sub(wire, 24 + (i - 1) * 2 + 1,
                                        24 + i * 2), 16)
                                end
                                host = table.concat(parts, ".")
                            else
                                local groups = {}
                                for g = 1, 8 do
                                    local text = string.sub(wire, (g - 1) * 4 + 1, g * 4)
                                        :gsub("^0+", "")
                                    groups[g] = (text == "") and "0" or text
                                end
                                host = table.concat(groups, ":")
                            end
                        end
                            local key = host .. "|" .. port
                            if not seen[key] then
                                seen[key] = true
                                out[#out + 1] = { host = host, port = port }
                            end
                        end
                    end
                end
            end
        end
    end
    return out
end

---Candidates from a /containers/json document (the caller does the socket read).
---
---Published ports win over container-internal IPs: one instance must map to
---exactly one worker URL, two URLs for the same instance would split the prefix
---cache. Also returns {published_port = container_name} so a proc-scan candidate
---can be labelled with the container that owns it.
---@param containers table|nil
---@param include_container_ips boolean|nil
---@return table[] candidates, table port_names
function _M.docker_candidates_from(containers, include_container_ips)
    local cands, port_names = {}, {}
    if type(containers) ~= "table" then
        return cands, port_names
    end
    for _, ctr in ipairs(containers) do
        local names = type(ctr.Names) == "table" and ctr.Names or {}
        local name = string.gsub(names[1] or ctr.Id or "container", "^/", "")
        local host_net = type(ctr.HostConfig) == "table"
            and ctr.HostConfig.NetworkMode == "host"
        local published, mapped_private = {}, {}
        local ports = type(ctr.Ports) == "table" and ctr.Ports or {}
        for i = 1, #ports do
            local binding = ports[i]
            local public = tonumber(binding.PublicPort)
            if public then
                published[public] = true
                local private = tonumber(binding.PrivatePort)
                if private then mapped_private[private] = true end
                port_names[public] = name
                cands[#cands + 1] = {
                    url = _M.normalize_url("http://127.0.0.1:" .. public),
                    source = "docker", label = name,
                    instance_key = ctr.Id, gpu = _M.gpu_from_name(name),
                }
            end
        end
        -- Host-network containers share the host stack: /proc/net/tcp already
        -- covers their ports, and their "container IP" is a host address, so the
        -- container-IP half is skipped there (and when the operator opted out).
        local networks = (type(ctr.NetworkSettings) == "table"
            and type(ctr.NetworkSettings.Networks) == "table")
            and ctr.NetworkSettings.Networks or {}
        if not host_net and include_container_ips ~= false then
            for _, net in pairs(networks) do
                local ip = type(net) == "table" and net.IPAddress or nil
                if type(ip) == "string" and ip ~= "" then
                    local net_ports = type(net.Ports) == "table" and net.Ports or {}
                    for key in pairs(net_ports) do
                        local cport = tonumber(string.match(tostring(key), "^(%d+)"))
                        if cport and not published[cport] and not mapped_private[cport] then
                            cands[#cands + 1] = {
                                url = _M.normalize_url("http://" .. ip .. ":" .. cport),
                                source = "docker-net", label = name, instance_key = ctr.Id,
                            }
                        end
                    end
                end
            end
        end
    end
    return cands, port_names
end

---Listening sockets -> candidates (local_candidates). A wildcard bind is probed
---through loopback, which is the only address guaranteed to answer.
---@param sockets table[] @ {host=, port=}
---@param deny table|nil @ set of ports
---@param allow table|nil @ when non-empty, probe ONLY these ports
---@return table[]
function _M.local_candidates(sockets, deny, allow)
    local cands = {}
    for i = 1, #sockets do
        local item = sockets[i]
        local port = tonumber(item.port)
        if port then
            local wanted = (allow == nil or next(allow) == nil) or allow[port] == true
            if wanted and not (deny and deny[port]) then
                local host = item.host
                local target
                if host == "0.0.0.0" or host == "::" then
                    target = "127.0.0.1"
                elseif string.find(host, ":", 1, true) then
                    target = "[" .. host .. "]"
                else
                    target = host
                end
                cands[#cands + 1] = {
                    url = _M.normalize_url("http://" .. target .. ":" .. port),
                    source = "proc",
                }
            end
        end
    end
    return cands
end

---Candidate priority so one URL keeps its most specific source (docker beats
---proc beats the allow-list).
local SOURCE_ORDER = { docker = 1, cli = 2, ["docker-net"] = 3, proc = 4,
                       ["allow-list"] = 5 }

---Merge candidate lists into unique URLs with their owning label (collect()).
---@param lists table[]
---@return table[]
function _M.unique_candidates(lists)
    local by_url = {}
    for i = 1, #lists do
        for _, cand in ipairs(lists[i] or {}) do
            if cand.url then
                local existing = by_url[cand.url]
                if not existing
                    or (SOURCE_ORDER[cand.source] or 9)
                        < (SOURCE_ORDER[existing.source] or 9) then
                    by_url[cand.url] = cand
                end
            end
        end
    end
    local out = {}
    for url in pairs(by_url) do
        out[#out + 1] = by_url[url]
    end
    table.sort(out, function(a, b)
        local oa, ob = SOURCE_ORDER[a.source] or 9, SOURCE_ORDER[b.source] or 9
        if oa ~= ob then return oa < ob end
        return a.url < b.url
    end)
    return out
end

-- ------------------------------------------------------------------ ledger

---The ledger is the memory of what this watcher owns and what it must never
---touch. The daemon keeps it in a JSON file; here it lives in lr_watch so every
---nginx process (and a reload) sees one copy. A container restart clears it,
---which is coherent: lr_workers is a shared dict too, so a restart clears the
---pool as well and SMG_WORKER_URLS re-seeds it.
---
---Key layout (all in lr_watch):
---   p|<url>   protected marker
---   o|<url>   owned entry   {model_id, worker_id, engine, source, label, added_at, missing_since}
---   q|<url>   pending add   {queued_at, worker_id}
---   f|<url>   add back-off  {n, until}
---   map       the whole rename map as one JSON object
---@param d table ngx.shared.Dict (or a test double with get/set/delete/get_keys)
local function new_ledger(d)
    local self = { dict = d }

    local function url_key(prefix, url)
        return prefix .. url
    end

    function self.protected_urls()
        local out = {}
        for _, key in ipairs(d:get_keys(0)) do
            if string.sub(key, 1, 2) == "p|" then
                out[string.sub(key, 3)] = true
            end
        end
        return out
    end

    function self.is_protected(url)
        return d:get(url_key("p|", url)) ~= nil
    end

    function self.protect(url)
        d:set(url_key("p|", url), 1)
    end

    function self.unprotect(url)
        d:delete(url_key("p|", url))
    end

    local function decode(raw)
        if type(raw) ~= "string" then
            return nil
        end
        local value = json_decode(raw)
        if type(value) ~= "table" then
            return nil
        end
        return value
    end

    function self.owned_urls()
        local out = {}
        for _, key in ipairs(d:get_keys(0)) do
            if string.sub(key, 1, 2) == "o|" then
                local entry = decode(d:get(key))
                if entry then
                    out[string.sub(key, 3)] = entry
                end
            end
        end
        return out
    end

    function self.get_owned(url)
        return decode(d:get(url_key("o|", url)))
    end

    ---`ttl` keeps a live entry alive across a reload; it is rewritten on every
    ---pass that still sees the worker, so it only matters as a leak guard.
    function self.set_owned(url, entry, ttl)
        local encoded = json_encode(entry)
        if not encoded then
            return false
        end
        return d:set(url_key("o|", url), encoded, ttl or 0) and true or false
    end

    function self.drop_owned(url)
        d:delete(url_key("o|", url))
    end

    function self.get_pending(url)
        return decode(d:get(url_key("q|", url)))
    end

    function self.pending_urls()
        local out = {}
        for _, key in ipairs(d:get_keys(0)) do
            if string.sub(key, 1, 2) == "q|" then
                local value = decode(d:get(key))
                if value then
                    out[string.sub(key, 3)] = value
                end
            end
        end
        return out
    end

    function self.set_pending(url, value, ttl)
        local encoded = json_encode(value)
        if encoded then
            d:set(url_key("q|", url), encoded, ttl or 0)
        end
    end

    function self.drop_pending(url)
        d:delete(url_key("q|", url))
    end

    function self.get_backoff(url)
        return decode(d:get(url_key("f|", url)))
    end

    ---Exponential back-off after a rejected add, capped at 15 minutes like the
    ---daemon (30 s * 2^n, max 900 s).
    ---The field is named until_ts: `until` is a Lua keyword and cannot be a key.
    function self.set_backoff(url, n, now)
        local until_ts = now + math.min(900, 30 * (2 ^ n))
        d:set(url_key("f|", url), json_encode({ n = n, until_ts = until_ts }),
            until_ts - now + 60)
        return until_ts
    end

    function self.drop_backoff(url)
        d:delete(url_key("f|", url))
    end

    ---First-contact marker: the ledger has been seeded once. Separate from the
    ---protected set because an empty pool is a legitimate first contact too.
    function self.touched()
        return d:get("touched") ~= nil
    end

    function self.mark_touched()
        d:set("touched", 1)
    end

    function self.map()
        local value = decode(d:get("map"))
        if value then
            return value
        end
        return {}
    end

    function self.set_map(mapping)
        local encoded = json_encode(mapping or {})
        if encoded then
            d:set("map", encoded)
        end
    end

    return self
end

_M.new_ledger = new_ledger

-- ------------------------------------------------------------------ reconcile
--
-- What the daemon does here and the Lua version does not: a *mixed-model warning*.
-- The daemon logged one because the Rust gateway ignores the requested model when it
-- picks a worker in single-router mode (README measured 10/10 requests naming the
-- local model served by a remote one), so a heterogeneous pool silently mis-routes.
-- This router cannot mis-route that way - candidates_for(model) filters by
-- record.model_id (router.lua:987), and a request naming an unregistered model gets a
-- 404 rather than a random worker - so the warning has nothing to warn about and was
-- deliberately not ported. doc/gap-watcher-merge.md lists it as the one README
-- behaviour with no Lua counterpart.

local function warn(log, message)
    if type(log) == "function" then
        log("warn", message)
    end
end

local function notice(log, message)
    if type(log) == "function" then
        log("notice", message)
    end
end

---Is `url` the only remaining worker of `model_id`? (_is_last_for_model)
---An unhealthy sibling does not count as coverage.
---@param model_id string
---@param url string
---@param actual table @ url -> {model_id=, is_healthy=}
---@return boolean
function _M.is_last_for_model(model_id, url, actual)
    if not model_id or model_id == "" then
        return true
    end
    for other_url, item in pairs(actual or {}) do
        if other_url ~= url and tostring(item.model_id or "") == model_id then
            if item.is_healthy ~= false then
                return false
            end
        end
    end
    return true
end

---Confirm the adds we queued and release the stuck ones (guard 7).
---
---The daemon had to wait for the router's async AddWorker job: a 202 only meant
---"queued", and a job parked on a dead URL squatted the URL forever (every retry
---said "already exists"), so it deleted the worker to free it. Registration here
---is a direct registry.add, so a worker is live the moment we return; what is
---still worth reaping is a ledger entry whose URL has left the pool behind our
---back (a hand DELETE, or an add that never landed), which would otherwise keep
---the URL claimed and the model advertised as if it had a worker.
---@param state table @ {cfg, ledger, now, actual}
---@return table @ live pending urls (still waiting, excluded from this pass)
function _M.reap_pending(state)
    local ledger, now, actual = state.ledger, state.now, state.actual
    local live = {}
    for url, pending in pairs(ledger.pending_urls()) do
        if actual[url] then
            -- Confirmed: the pool carries it, so the ledger takes the live id.
            ledger.drop_pending(url)
            ledger.drop_backoff(url)
            local entry = ledger.get_owned(url)
            if entry then
                entry.worker_id = tostring(actual[url].id or entry.worker_id or "")
                entry.missing_since = nil
                ledger.set_owned(url, entry, state.entry_ttl)
            end
        else
            local age = now - tonumber(pending.queued_at or now)
            if age <= state.cfg.add_confirm_timeout_secs then
                live[url] = true
            else
                notice(state.log, string.format(
                    "watcher: add for %s never reached the pool after %.0fs; releasing the URL",
                    url, age))
                -- The id the add returned may still be in the pool under a
                -- different URL spelling (a DP expansion replaces the base
                -- entry): registry.remove answers "not found" for anything gone,
                -- so trying is safe and releases the URL either way.
                if pending.worker_id then
                    state.unregister(tostring(pending.worker_id))
                end
                ledger.drop_pending(url)
                ledger.drop_owned(url)
                state.stats.adds_stuck_released = state.stats.adds_stuck_released + 1
            end
        end
    end
    return live
end

---One reconcile pass. Everything outside this function is plumbing, which makes
---the eight guards above auditable in one place and testable with fakes.
---
---@param state table @ {cfg, ledger, actual, candidates, probe, register,
---                       unregister, now, stats, log}
---@return table @ the (mutated) stats
function _M.reconcile(state)
    local cfg, ledger, now = state.cfg, state.ledger, state.now
    local stats = state.stats
    stats.reconciles = stats.reconciles + 1

    -- Guard 3: on first contact every worker already in the pool was configured
    -- by someone else (SMG_WORKER_URLS or a human), so protect it permanently.
    if not ledger.touched() then
        local protected = ledger.protected_urls()
        local owned = ledger.owned_urls()
        if next(protected) == nil and next(owned) == nil then
            for url in pairs(state.actual) do
                ledger.protect(url)
            end
            ledger.mark_touched()
            if next(state.actual) ~= nil then
                notice(state.log, string.format("watcher: protecting %d pre-existing worker(s)",
                    (function()
                        local n = 0
                        for _ in pairs(state.actual) do n = n + 1 end
                        return n
                    end)()))
            end
        end
    end

    -- Discovery + strict probe.
    local discovered = {}
    for i = 1, #state.candidates do
        local cand = state.candidates[i]
        if cand and cand.url and not _M.is_self_url(cand.url, cfg.self_ports)
            and not _M.is_excluded(cand.url, cfg.exclude_patterns) then
            local info = state.probe(cand.url)
            if info then
                info.label = cand.label or info.engine
                info.source = cand.source
                info.gpu = cand.gpu
                discovered[#discovered + 1] = info
            end
        end
    end
    stats.discovered = #discovered

    -- desired = discovered - protected (guard 3 again, from the other side).
    local desired, protected_seen = {}, {}
    for i = 1, #discovered do
        local info = discovered[i]
        if ledger.is_protected(info.url) then
            protected_seen[info.url] = info
        else
            desired[info.url] = info
        end
    end

    local pending_live = _M.reap_pending(state)

    ---A URL with a queued add is claimed, whatever its stage in this pass.
    local function pending_now(url)
        return pending_live[url] or ledger.get_pending(url) ~= nil
    end

    -- Adds.
    for _, url in ipairs(sorted_keys(desired)) do
        if not state.actual[url] and not pending_live[url] then
            local entry = desired[url]
            local model_id = _M.model_name(entry.models[1], state.model_map, cfg.short_model_names)
            local fail_until = ledger.get_backoff(url)
            if fail_until and now < tonumber(fail_until.until_ts or 0) then
                -- in back-off after a rejected add
            else
                local worker_id, err = state.register(url, model_id, entry)
                if not worker_id then
                    stats.add_fails = stats.add_fails + 1
                    local n = ((ledger.get_backoff(url) or {}).n or 0) + 1
                    ledger.set_backoff(url, n, now)
                    warn(state.log, string.format("watcher: add %s failed: %s",
                        url, tostring(err)))
                else
                    stats.adds = stats.adds + 1
                    ledger.drop_backoff(url)
                    ledger.set_pending(url, { queued_at = now, worker_id = worker_id },
                        cfg.add_confirm_timeout_secs + cfg.interval_secs)
                    ledger.set_owned(url, {
                        model_id = model_id,
                        worker_id = worker_id,
                        engine = entry.engine,
                        source = entry.source,
                        label = entry.label,
                        added_at = now,
                    }, state.entry_ttl)
                    notice(state.log, string.format("watcher: registered %s as model %q (engine %s)",
                        url, model_id, entry.engine))
                end
            end
        end
    end

    -- Renames: a map (or short-model-names) change has to reach the pool, which
    -- means recycling the entry so the next pass re-adds it under the new id.
    -- Owned workers go through their ledger entry; protected ones have no entry,
    -- and dropping their protection is what hands ownership over (same trick as
    -- the daemon's eviction hand-off).
    for _, url in ipairs(sorted_keys(desired)) do
        if not pending_now(url) and state.actual[url] then
            local info = desired[url]
            local want = _M.model_name(info.models[1], state.model_map, cfg.short_model_names)
            local have = tostring(state.actual[url].model_id or "")
            local entry = ledger.get_owned(url)
            if entry and entry.model_id ~= want and have ~= want then
                notice(state.log, string.format("watcher: rename %s (registered %q, want %q)",
                    url, have, want))
                _M.release(state, url, entry, 0, "rename")
            end
        end
    end
    for _, url in ipairs(sorted_keys(protected_seen)) do
        if not pending_now(url) and state.actual[url] then
            local info = protected_seen[url]
            local want = _M.model_name(info.models[1], state.model_map, cfg.short_model_names)
            local have = tostring(state.actual[url].model_id or "")
            if have ~= "" and have ~= want then
                notice(state.log, string.format(
                    "watcher: rename of protected %s (registered %q, want %q); adopting it",
                    url, have, want))
                ledger.unprotect(url)
                if state.unregister(tostring(state.actual[url].id or "")) then
                    stats.removes = stats.removes + 1
                else
                    ledger.protect(url)   -- keep the promise if the delete failed
                end
            end
        end
    end

    -- Removals: only from our own ledger (guard 4).
    for _, url in ipairs(sorted_keys(ledger.owned_urls())) do
        local entry = ledger.get_owned(url)
        if entry then
            if desired[url] then
                -- The entry is rewritten on every pass that still sees the worker,
                -- which is what renews its lr_watch ttl. Skipping the write in the
                -- steady state would let a long-lived worker's entry age out (the
                -- ledger lives in a shared dict with a TTL as a leak guard), and an
                -- owned URL with no entry is invisible to the removal loop below:
                -- the worker would keep its pool row after the service died for
                -- good, which is precisely the zombie the daemon exists to prevent.
                entry.missing_since = nil
                entry.warned = nil
                ledger.set_owned(url, entry, state.entry_ttl)
                -- Guard 8: a router restart/reload re-creates workers with fresh
                -- ids, so keep the recorded id in step with the pool.
                local live = state.actual[url]
                if live and live.id and tostring(live.id) ~= tostring(entry.worker_id) then
                    entry.worker_id = tostring(live.id)
                    ledger.set_owned(url, entry, state.entry_ttl)
                end
            elseif not state.actual[url] then
                -- Gone from the pool and from discovery: forget it, nothing to delete.
                ledger.drop_owned(url)
                ledger.drop_pending(url)
            else
                local first_missing = tonumber(entry.missing_since)
                if not first_missing then
                    entry.missing_since = now
                    ledger.set_owned(url, entry, state.entry_ttl)
                    first_missing = now
                end
                local age = now - first_missing
                if not cfg.allow_remove then
                    if age >= cfg.remove_grace_secs and not entry.warned then
                        warn(state.log, string.format(
                            "watcher: %s has been undiscovered for %.0fs but removal is disabled",
                            url, age))
                        entry.warned = true
                        ledger.set_owned(url, entry, state.entry_ttl)
                    end
                elseif age < cfg.remove_grace_secs then
                    -- Guard 5: a short restart is the health sweep's job, not ours.
                elseif cfg.keep_last_grace_secs >= 0
                    and _M.is_last_for_model(tostring(entry.model_id or ""), url, state.actual) then
                    -- Guard 6: never empty a model, but do not keep a permanently
                    -- stopped service serving 5xx either.
                    if not (cfg.keep_last_grace_secs > 0 and age >= cfg.keep_last_grace_secs) then
                        if not entry.warned then
                            warn(state.log, string.format(
                                "watcher: %s gone %.0fs but it is the last worker of model %q; keeping it",
                                url, age, tostring(entry.model_id)))
                            entry.warned = true
                            ledger.set_owned(url, entry, state.entry_ttl)
                        end
                    else
                        notice(state.log, string.format(
                            "watcher: %s gone %.0fs and it is the last worker of model %q (>= keep-last grace %.0fs); removing it",
                            url, age, tostring(entry.model_id), cfg.keep_last_grace_secs))
                        _M.release(state, url, entry, age, "keep-last expired")
                    end
                else
                    _M.release(state, url, entry, age, "undiscovered")
                end
            end
        end
    end

    return stats
end

---Delete one ledger-owned worker and forget the entry (the daemon's _remove).
---@param state table
---@param url string
---@param entry table
---@param age number
---@param reason string
---@return boolean ok
function _M.release(state, url, entry, age, reason)
    local worker_id = tostring(entry.worker_id or "")
    if worker_id == "" then
        warn(state.log, string.format("watcher: %s has no recorded worker id; cannot delete", url))
        return false
    end
    if not state.unregister(worker_id) then
        warn(state.log, string.format("watcher: remove %s failed", url))
        return false
    end
    state.stats.removes = state.stats.removes + 1
    state.ledger.drop_owned(url)
    state.ledger.drop_pending(url)
    state.ledger.drop_backoff(url)
    notice(state.log, string.format("watcher: removed %s (%s, gone %.0fs)", url, reason, age or 0))
    return true
end


-- ==================================================================== live wiring
--
-- Everything below resolves the OpenResty globals: the cosocket probe transport, the
-- docker unix socket, /proc, the lr_watch shared dict, the registry, and the worker 0
-- timer. It is separated from the pure layer above so the semantics stay testable
-- under luajit with no ngx at all (test/unit/test_watcher.lua), exactly the split
-- mesh.lua uses.

local DICT_NAME = "lr_watch"
local LOCK_DICT = "lr_locks"
local TICK_LOCK = "watcher-tick"

---Shared dict, or nil outside nginx / before the dict is declared in the conf.
---@return table|nil
local function dict()
    if not has_ngx or not ngx.shared then
        return nil
    end
    return ngx.shared[DICT_NAME]
end

---Config captured by start() so the request phase (POST /model-map) can merge the
---env map without reparsing the environment.
local captured_config

_M.config = function()
    return captured_config
end

-- -------------------------------------------------------------- probe transport

---GET one URL, decoded by classify() through the same fetch contract the tests use.
---@param timeout_ms number
---@return function @ (url) -> status, body, err
local function make_fetch(timeout_ms)
    local hb = require "resty.luarouter.hb"
    return function(url)
        return hb.http_get(url, timeout_ms)
    end
end

---Probes through a bounded pool of coroutines.
---
---The daemon used a 16-thread pool; a serial pass would spend the whole interval on a
---host with a hundred listeners (each hanging probe costs probe_timeout). ngx.thread
---gives the same concurrency for free because every cosocket wait yields. Without ngx
---(unit tests) the caller falls back to a serial loop.
---@param urls string[]
---@param opts table @ classify options (fetch injected here)
---@param fanout number|nil
---@return table @ url -> info|nil
local function probe_pool(urls, opts, fanout)
    local results, next_index = {}, 0
    local function one(url)
        local info = _M.classify(url, opts)
        results[url] = info
    end
    if not has_ngx or type(ngx.thread) ~= "table" or #urls == 0 then
        for i = 1, #urls do
            one(urls[i])
        end
        return results
    end
    local width = math.max(1, math.min(fanout or 8, #urls))
    local threads = {}
    for _ = 1, width do
        threads[#threads + 1] = ngx.thread.spawn(function()
            while true do
                next_index = next_index + 1
                local index = next_index
                if index > #urls then
                    return
                end
                local ok, err = pcall(one, urls[index])
                if not ok then
                    ngx.log(ngx.WARN, "luarouter: watcher probe of ", urls[index],
                        " failed: ", tostring(err))
                end
            end
        end)
    end
    for i = 1, #threads do
        pcall(ngx.thread.wait, threads[i])
    end
    return results
end

-- ------------------------------------------------------------ docker discovery

---One HTTP GET over a unix socket.
---
---Verified against this box's daemon (OpenResty 1.31): the table form of connect
---(`{path = ...}`) is NOT supported in this build and raises "string expected, got
---table", so the "unix:<path>" string form is the one to use. The reply is chunked, and
---the request carries Connection: close so a daemon that ignores framing still ends the
---read. `path` must already be percent-encoded.
---@param socket_path string
---@param path string
---@param timeout_ms number
---@return number|nil status, string|nil body, string|nil err
function _M.unix_get(socket_path, path, timeout_ms)
    if not has_ngx then
        return nil, nil, "no ngx"
    end
    local sock = ngx.socket.tcp()
    sock:settimeout(timeout_ms or 2000)
    local ok, err = sock:connect("unix:" .. socket_path)
    if not ok then
        return nil, nil, "connect failed: " .. tostring(err)
    end
    local request = "GET " .. path .. " HTTP/1.1\r\n"
        .. "Host: localhost\r\nAccept: */*\r\nConnection: close\r\n\r\n"
    local sent, werr = sock:send(request)
    if not sent then
        sock:close()
        return nil, nil, "send failed: " .. tostring(werr)
    end
    local status_line = sock:receive("*l")
    if not status_line then
        sock:close()
        return nil, nil, "no response line"
    end
    local status = tonumber(string.match(status_line, "^HTTP/%d%.%d%s+(%d%d%d)"))
    local content_length, chunked = nil, false
    while true do
        local line = sock:receive("*l")
        if line == nil or line == "" then
            break
        end
        local name, value = string.match(line, "^([%w%-]+):%s*(.*)$")
        if name then
            local lowered = string.lower(name)
            if lowered == "content-length" then
                content_length = tonumber(value)
            elseif lowered == "transfer-encoding"
                and string.lower(value or ""):find("chunked") then
                chunked = true
            end
        end
    end
    local body = ""
    if chunked then
        local registry_mod = require "resty.luarouter.registry"
        body = registry_mod.pump_chunked(sock, true)
    elseif content_length and content_length > 0 then
        local remaining = content_length
        while remaining > 0 do
            local block = sock:receive(math.min(65536, remaining))
            if not block then
                break
            end
            body = body .. block
            remaining = remaining - #block
        end
    else
        body = sock:receive("*a") or ""
    end
    sock:close()
    return status or 0, body
end

---Running containers as a decoded array, or nil.
---@param cfg table
---@return table|nil
local function docker_containers(cfg)
    local path = "/containers/json?filters="
        .. uri_encode('{"status":["running"]}')
    local status, body, err = _M.unix_get(cfg.docker_socket, path,
        math.max(1000, (cfg.probe_timeout_secs or 4) * 1000))
    if not status or status < 200 or status >= 300 then
        if err then
            ngx.log(ngx.INFO, "luarouter: watcher docker scan skipped: ", err)
        end
        return nil
    end
    local decoded = json_decode(body or "")
    if type(decoded) ~= "table" then
        return nil
    end
    return decoded
end

-- -------------------------------------------------------------- candidate scan

---Build the candidate list from the enabled sources (the daemon's collect()).
---@param cfg table
---@param reader function|nil @ injectable /proc reader for tests
---@return table[]
function _M.collect(cfg, reader)
    local lists = {}
    local targets = {}
    for i = 1, #(cfg.targets or {}) do
        local url = _M.normalize_url(cfg.targets[i])
        if url then
            targets[#targets + 1] = { url = url, source = "cli", label = "static" }
        else
            ngx.log(ngx.WARN, "luarouter: watcher ignoring bad target ",
                tostring(cfg.targets[i]))
        end
    end
    lists[#lists + 1] = targets

    local port_names = {}
    if cfg.scan_docker then
        local containers = docker_containers(cfg)
        local cands, names = _M.docker_candidates_from(containers,
            cfg.scan_container_ips)
        for port, name in pairs(names) do
            port_names[port] = name
        end
        lists[#lists + 1] = cands
    end

    if cfg.scan_proc then
        -- Same rule as the daemon: the default deny list only trims noise when the
        -- operator did not narrow the scan with SMG_WATCHER_ALLOW_PORT.
        local narrowed = next(cfg.allow_ports) ~= nil
        local deny = cfg.deny_ports
        if not narrowed then
            deny = _M.DEFAULT_DENY_PORTS
        end
        local sockets = _M.listening_sockets(reader)
        local cands = _M.local_candidates(sockets, deny, cfg.allow_ports)
        for i = 1, #cands do
            local _, _, port = _M.split_http(cands[i].url)
            if port and port_names[port] and not cands[i].label then
                cands[i].label = port_names[port]
            end
        end
        lists[#lists + 1] = cands
    end

    local allowed = {}
    if next(cfg.allow_ports) ~= nil then
        local ports = {}
        for port in pairs(cfg.allow_ports) do
            ports[#ports + 1] = port
        end
        table.sort(ports)
        for i = 1, #ports do
            allowed[#allowed + 1] = {
                url = _M.normalize_url("http://127.0.0.1:" .. ports[i]),
                source = "allow-list",
            }
        end
    end
    lists[#lists + 1] = allowed

    return _M.unique_candidates(lists)
end

-- ----------------------------------------------------------- registry adapters

---registry.add in the POST /workers body shape (registry.lua:620).
---@param conf table @ router config providing the health-check defaults
---@return function @ (url, model_id, entry) -> worker_id|nil, err
local function make_register(conf)
    local registry = require "resty.luarouter.registry"
    local ok_policy, policy = pcall(require, "resty.luarouter.policy")
    return function(url, model_id, entry)
        local labels = {
            ["managed-by"] = _M.MANAGED_BY,
            engine = entry.engine or "openai",
        }
        if entry.gpu then
            labels.gpu = entry.gpu
        end
        if entry.source then
            labels.discovery = entry.source
        end
        local req = {
            url = url,
            model_id = model_id,
            labels = labels,
            -- The registry records provenance in its own field, copied from the
            -- watcher label so GET /workers shows who wrote the row.
            discovery = _M.MANAGED_BY,
        }
        -- Same rule as the daemon: a service with no /health must not be marked
        -- unhealthy by a sweep that can never succeed.
        if entry.has_health == false then
            req.disable_health_check = true
        end
        local result, err = registry.add(req, conf)
        if not result then
            return nil, err
        end
        -- The /workers handlers bump the policy generation after a registry write;
        -- a direct add has to as well, or every stateful policy keeps seeding from
        -- the worker list it was built with (mesh needs nothing here: registry.add
        -- mirrors the record itself).
        if ok_policy then
            policy.bump_generation()
        end
        return result.id
    end
end

---@return function @ (worker_id) -> boolean ok
local function make_unregister()
    local registry = require "resty.luarouter.registry"
    local ok_policy, policy = pcall(require, "resty.luarouter.policy")
    return function(worker_id)
        local id = tostring(worker_id or "")
        if id == "" then
            return false
        end
        -- Guard 4, second half: only delete an id that still names a live record.
        -- The id is sha224(url), so a stale id can never have been re-claimed by a
        -- different URL, but a hand DELETE already removed it, and re-checking here
        -- keeps the ledger honest about what actually happened.
        local info = registry.get(id)
        if not info then
            return false
        end
        local result, err = registry.remove(id)
        if not result then
            ngx.log(ngx.WARN, "luarouter: watcher remove ", id, " failed: ",
                tostring(err))
            return false
        end
        -- Same two steps delete_worker_handler does: forget the load bookkeeping of
        -- the departed url, then let the stateful policies re-seed.
        if ok_policy then
            local inst = policy.default
            if inst and type(inst.on_remove) == "function" then
                inst:on_remove({ url = result.url })
            end
            policy.bump_generation()
        end
        return true
    end
end

---Current pool as url -> {id, model_id, is_healthy} (the daemon's GET /workers).
---@return table
local function actual_pool()
    local registry = require "resty.luarouter.registry"
    local records = registry.records()
    local out = {}
    for i = 1, #records do
        local record = records[i]
        local key = _M.normalize_url(record.url) or record.url
        out[key] = {
            id = record.id,
            url = record.url,
            model_id = record.model_id or "unknown",
            is_healthy = registry.is_healthy(record.id),
        }
    end
    return out
end

-- ------------------------------------------------------------------ one pass

---Run one reconcile pass against the live registry.
---@param cfg table @ watcher config from new_config
---@param opts table|nil @{reader, fanout} (tests inject the /proc reader)
---@return table|nil stats, string|nil err
function _M.run_pass(cfg, opts)
    opts = opts or {}
    local d = dict()
    if not d then
        return nil, "lua_shared_dict " .. DICT_NAME .. " is not declared"
    end
    local conf = require("resty.luarouter").config()
    local ledger = _M.new_ledger(d)
    local now = ngx.now()
    local candidates = _M.collect(cfg, opts.reader)

    -- Probe every candidate once, concurrently, and hand reconcile the memo: the
    -- pure layer calls probe(url) per candidate, and a second HTTP round trip per
    -- URL would double the cost of a pass.
    local urls = {}
    for i = 1, #candidates do
        -- Filter before dialing. reconcile() applies the same two tests, so this is
        -- only about what a pass costs - and skipping the router's own listeners is
        -- not cosmetic: probing them from a timer every interval would add two
        -- requests per pass to the router's own smg_http_requests_total, and a
        -- /metrics scrape would then be counting the watcher watching itself.
        local cand = candidates[i]
        if cand and cand.url and not _M.is_self_url(cand.url, cfg.self_ports)
            and not _M.is_excluded(cand.url, cfg.exclude_patterns) then
            urls[#urls + 1] = candidates[i].url
        end
    end
    local fetch = make_fetch(math.floor((cfg.probe_timeout_secs or 4) * 1000))
    local probed = probe_pool(urls, {
        fetch = fetch,
        require_health = cfg.require_health,
        max_models = cfg.max_models,
        allow_models_only = cfg.allow_models_only,
    }, opts.fanout)

    local state = {
        cfg = cfg,
        ledger = ledger,
        now = now,
        actual = actual_pool(),
        candidates = candidates,
        model_map = _M.effective_map(cfg),
        entry_ttl = math.max(3600, (cfg.remove_grace_secs or 300) * 10
            + (cfg.keep_last_grace_secs or 1800)),
        probe = function(url)
            return probed[url]
        end,
        register = make_register(conf),
        unregister = make_unregister(),
        stats = {
            reconciles = 0, adds = 0, add_fails = 0, removes = 0,
            discovered = 0, adds_stuck_released = 0,
        },
        log = function(level, message)
            if level == "warn" then
                ngx.log(ngx.WARN, message)
            else
                ngx.log(ngx.NOTICE, message)
            end
        end,
    }
    local stats = _M.reconcile(state)
    _M.publish_metrics(stats, state)
    return stats
end

-- ------------------------------------------------------------------- metrics

---Registration points for the watcher families (doc/gap-watcher-merge.md). Only
---observability.counter/gauge calls: the exporter renders whatever is in lr_stats,
---so nothing existing is touched.
---@param stats table
---@param state table
function _M.publish_metrics(stats, state)
    local ok_obs, observability = pcall(require, "resty.luarouter.observability")
    if not ok_obs then
        return false
    end
    local owned, protected = 0, 0
    for _ in pairs(state.ledger.owned_urls()) do
        owned = owned + 1
    end
    for _ in pairs(state.ledger.protected_urls()) do
        protected = protected + 1
    end
    local map_entries = 0
    for _ in pairs(state.model_map or {}) do
        map_entries = map_entries + 1
    end
    observability.record_watch_pass(stats, owned, protected, map_entries)
    return true
end

-- ---------------------------------------------------------------- the timer

local timer_running = false

---Count the pool once so the pass log line says what the watcher did.
local function tick(premature, cfg)
    if premature then
        timer_running = false
        return
    end
    local lock_mod = require "resty.lock"
    -- Single-flight: a pass that outlives the interval (a host with a thousand
    -- listeners, a daemon that hangs) must not stack a second one behind it.
    local lock, lerr = lock_mod:new(LOCK_DICT, { timeout = 0, exptime = 120 })
    local held = false
    if lock then
        held = lock:lock(TICK_LOCK)
        if not held then
            -- The previous pass is still running; skip quietly, the next interval
            -- retries. busy is the normal answer on a slow host, not an error.
            local again, aerr = ngx.timer.at(cfg.interval_secs, tick, cfg)
            if not again then
                timer_running = false
                ngx.log(ngx.ERR, "luarouter: watcher timer stopped: ", tostring(aerr))
            end
            return
        end
    end
    local ok, err = pcall(_M.run_pass, cfg)
    if not ok then
        ngx.log(ngx.WARN, "luarouter: watcher pass failed: ", tostring(err))
    end
    if lock and held then
        pcall(function() lock:unlock() end)
    end
    local again, aerr = ngx.timer.at(cfg.interval_secs, tick, cfg)
    if not again then
        timer_running = false
        ngx.log(ngx.ERR, "luarouter: watcher timer not rescheduled: ",
            tostring(aerr))
    end
end

---Start the reconcile timer (worker 0 only; init.lua owns that gate).
---@param cfg table|nil @ watcher config; built from the environment when omitted
---@param self_ports table|nil @ this router's own listener ports
---@return boolean ok, string|nil err
function _M.start(cfg, self_ports, metrics_port)
    if not has_ngx then
        return false, "no ngx (watcher needs OpenResty)"
    end
    if not cfg then
        local conf = require("resty.luarouter").config()
        cfg = _M.new_config(os.getenv,
            self_ports or conf.port,
            metrics_port or conf.metrics_port)
    end
    captured_config = cfg
    if not cfg.enabled then
        return false, "disabled (set SMG_WATCHER_ENABLED=1)"
    end
    if not dict() then
        return false, "lua_shared_dict " .. DICT_NAME .. " is not declared"
    end
    if #cfg.targets == 0 and not cfg.scan_docker and not cfg.scan_proc
        and next(cfg.allow_ports) == nil then
        return false, "no discovery source enabled (SMG_WATCHER_TARGETS / _DOCKER /"
            .. " _PROC_SCAN / _ALLOW_PORT)"
    end
    if timer_running then
        return true
    end
    timer_running = true
    local ok, err = ngx.timer.at(0, tick, cfg)
    if not ok then
        timer_running = false
        return false, err
    end
    ngx.log(ngx.NOTICE, "luarouter: watcher enabled (interval ",
        cfg.interval_secs, "s, sources",
        (#cfg.targets > 0) and " targets" or "",
        cfg.scan_docker and " docker" or "",
        cfg.scan_proc and " proc" or "",
        ")")
    return true
end

-- ------------------------------------------------------------- model-map API

---Effective rename map: the env/flag map with the ledger map on top (the daemon
---merges the same way at start, so an API edit wins over a stale compose value).
---@param cfg table|nil
---@return table
function _M.effective_map(cfg)
    cfg = cfg or captured_config
    local merged = {}
    local env_map = (cfg and cfg.model_map)
        or _M.parse_model_map(
            os.getenv("SMG_WATCHER_MODEL_MAP") or os.getenv("LMR_MODEL_MAP") or "")
    for key, value in pairs(env_map) do
        merged[key] = value
    end
    local d = dict()
    if d then
        for key, value in pairs(_M.new_ledger(d).map()) do
            merged[key] = value
        end
    end
    return merged
end

---Merge a POST /model-map body into the ledger map.
---@param raw string|nil @ raw request body (all four shapes accepted)
---@return table|nil merged @ effective map after the merge
---@return table|nil err @ {error=, ignored=} for a bad body, or
---        {error=, kind="config"} when the ledger dict is missing (a 5xx condition)
function _M.apply_model_map(raw)
    local mapping, err = _M.parse_model_map_body(raw)
    if err then
        return nil, err
    end
    local d = dict()
    if not d then
        return nil, { error = "lua_shared_dict " .. DICT_NAME .. " is not declared",
                      kind = "config" }
    end
    local ledger = _M.new_ledger(d)
    local merged, _ = _M.merge_map(_M.effective_map(), mapping)
    ledger.set_map(merged)
    if has_ngx then
        ngx.log(ngx.NOTICE, "luarouter: watcher model map updated -> ",
            json_encode(merged) or "{}")
    end
    return merged
end

return _M
