local cjson = require "cjson.safe"

local _M = require "resty.luarouter.watcher"
local M = {}   -- cross-module helper surface (not part of _M)
local json_encode = cjson.encode
local json_decode = cjson.decode

-- watcher/env.lua -- the SMG_WATCHER_* env layer: the infrastructure port
-- set with its union helper, the small value parsers, the url/port
-- normalisation and new_config().  Moved verbatim from
-- resty.luarouter.watcher (2026-10-05 split).  The _M alias is the
-- pre-loaded facade, so every definition below registers the same name on
-- the same table the monolith filled.

---Infrastructure ports never worth probing (llm_watcher.py DEFAULT_DENY_PORTS).
---Deliberately short: the probe is the real gate, this only trims noise, and
---inference servers do sit on web-default ports like 8080 or 3000.
---6334 (qdrant's gRPC listener) joins the inherited list on measured evidence:
---it accepts the TCP connection and answers the HTTP/1.1 probe with a binary
---HTTP/2 frame, so hb.http_request's receive("*l") never sees a newline and the
---read ends in ECONNRESET. nginx logs that recv failure as [error] from its own
---core (lua_socket_log_errors off does not cover it), which is one log line per
---pass per such port. A gRPC endpoint can never serve /v1/models, so denying it
---costs nothing and is the only available mute (doc/gap-watcher-merge.md, dev. 13).
_M.DEFAULT_DENY_PORTS = {
    [22] = true, [25] = true, [53] = true, [111] = true, [135] = true,
    [139] = true, [445] = true, [631] = true, [1433] = true, [1521] = true,
    [2049] = true, [3306] = true, [3389] = true, [5432] = true, [5900] = true,
    [6379] = true, [6443] = true, [9100] = true, [9400] = true,
    [11211] = true, [27017] = true,
    [6334] = true,
}

---Port set union, the `|` of the daemon's
---`deny = cfg.deny_ports | (set() if cfg.allow_ports else DEFAULT_DENY_PORTS)`.
---The operator's list and the default list are additive: the default trims known
---noise, the operator's adds to it. It is *not* a replacement, and a replacement
---silently un-denies whatever the default covers but the operator was relying on.
---@vararg table|nil @ sets of ports keyed by number
---@return table
function _M.union_port_sets(...)
    local out = {}
    -- select("#") rather than {...} so a nil in the argument list does not shorten
    -- the table and hide the sets after it.
    for i = 1, select("#", ...) do
        local set = select(i, ...)
        if type(set) == "table" then
            for port in pairs(set) do
                out[tonumber(port) or port] = true
            end
        end
    end
    return out
end

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
        -- 探针摘除的滞回与保险丝，见 reconcile 的 removal 段与 probe_verdict。
        -- 阈值写 0 或负数 = 退回"首次传输层失败即摘"（测试与显式要求立即摘除）。
        probe_failures = num_from(getenv, "SMG_WATCHER_PROBE_FAILURES", 2),
        probe_fuse = bool_from(getenv, "SMG_WATCHER_PROBE_FUSE", true),
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

-- Helper exports for the other watcher submodules: these were file-local
-- functions in the monolith, and submodules call them directly through
-- this table (invariant 4: a direct local call stays a direct call, not
-- an _M lookup).
M.trim, M.is_blank, M.lower = trim, is_blank, lower
M.sorted_keys, M.bool_from = sorted_keys, bool_from
M.num_from, M.split_list, M.list_from = num_from, split_list, list_from
M.uri_encode = uri_encode

-- Load-time snapshot of the ngx global -- the same expression on the same
-- synchronous require tick as the original watcher.lua:40 (the facade
-- requires this file first and the whole chain resolves in one require).
M.has_ngx = (type(ngx) == "table")

return M
