local cjson = require "cjson.safe"

local _M = require "resty.luarouter.gpu_load"

-- gpu_load/prom.lua -- the remote Prometheus client: the PromQL template
-- rendering (host/instance substitution through a gsub function so a
-- literal % in a host name stays literal), the query endpoint and
-- urlencoded body, the /api/v1/query response shape check (a matrix or
-- scalar is an error, not an empty result), and the host folding that maps
-- a vector back onto pooled workers.  Moved verbatim.

------------------------------------------------------------------ prom (remote)

---Render one PromQL out of the template.
---
---`{host}` becomes the worker's host and `{instance}` its host:port (the label
---value the exporter was scraped with, minus the port for {instance} templates
---that carry it). Neither brace is a Lua pattern metacharacter, but the
---substitution is done through a function so a hostname containing '%' stays
---literal. A template that asks for a host this worker cannot name is a task the
---caller must skip, not one to guess at.
---@param template string
---@param worker table|nil @ {url=...}
---@return string|nil query
function _M.render_query(template, worker)
    if type(template) ~= "string" or template == "" then
        return nil
    end
    local host, port = _M.split_host(worker and worker.url)
    -- An unparseable url still gets the template verbatim rather than nil: a query
    -- that names no machine is a valid (if useless) PromQL, and returning nil here
    -- would make run_pass report a config skip for what is really a bad worker url.
    -- The substitution below simply finds nothing to replace.
    
    local wants_host = string.find(template, "{host}", 1, true) ~= nil
        or string.find(template, "{instance}", 1, true) ~= nil
    if wants_host and not host then
        return nil
    end
    local out = template
    if host then
        out = string.gsub(out, "{host}", function() return host end)
        out = string.gsub(out, "{instance}", function()
            return port and (host .. ":" .. port) or host
        end)
    end
    return out
end

--- True when the template must be expanded once per worker.
---@param template string|nil
---@return boolean
function _M.query_needs_host(template)
    if type(template) ~= "string" then
        return false
    end
    return string.find(template, "{host}", 1, true) ~= nil
        or string.find(template, "{instance}", 1, true) ~= nil
end

---Full query URL for a Prometheus base address.
---@param base string|nil @ e.g. http://prom:9090 or http://prom:9090/api/v1/query
---@return string|nil
function _M.query_endpoint(base)
    if type(base) ~= "string" then
        return nil
    end
    local trimmed = string.gsub(base, "%s+$", "")
    trimmed = string.gsub(trimmed, "/+$", "")
    if trimmed == "" then
        return nil
    end
    if string.match(trimmed, "/api/v1/query$") then
        return trimmed
    end
    return trimmed .. "/api/v1/query"
end

---Percent-encode one form value (the same rule watcher.lua's uri_encode uses).
---@param text string
---@return string
local function uri_encode(text)
    return (string.gsub(text, "([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end
_M.uri_encode = uri_encode

---Form body for one PromQL evaluation (POST /api/v1/query, urlencoded).
---@param query string
---@return string
function _M.query_body(query)
    return "query=" .. uri_encode(query or "")
end

---Parse a Prometheus query response into rows.
---
---`{"status":"success","data":{"resultType":"vector","result":[{"metric":{...},
---"value":[<ts>,"<number>"]}]}}` is the only shape read: a matrix (range query) or
---a scalar has no per-series identity to map back to a worker, so it is an error
---rather than an empty result. Sample values go through parse_number(), so a
---"NaN" series is dropped here instead of becoming a zero load.
---@param body string|nil
---@return table[]|nil rows @ {{labels=table, value=number|nil}, ...}
---@return string|nil err
function _M.parse_prom_response(body)
    if type(body) ~= "string" or body == "" then
        return nil, "empty response"
    end
    local decoded = cjson.decode(body)
    if type(decoded) ~= "table" then
        return nil, "invalid json"
    end
    if decoded.status ~= "success" then
        return nil, "status " .. tostring(decoded.status)
    end
    local data = decoded.data
    if type(data) ~= "table" then
        return nil, "missing data"
    end
    if type(data.resultType) == "string" and data.resultType ~= "vector" then
        return nil, "unsupported resultType " .. data.resultType
    end
    local result = data.result
    if type(result) ~= "table" then
        -- cjson decodes {} as an empty table and [] as an empty table too, so a
        -- missing result key is the only way to get here; an empty vector is fine.
        return {}, nil
    end
    local rows = {}
    for i = 1, #result do
        local item = result[i]
        if type(item) == "table" then
            local labels = type(item.metric) == "table" and item.metric or {}
            local raw
            local value = item.value
            if type(value) == "table" then
                raw = value[2] ~= nil and value[2] or value[1]
            elseif value ~= nil then
                raw = value
            end
            rows[#rows + 1] = {
                labels = labels,
                value = _M.parse_number(raw),
            }
        end
    end
    return rows, nil
end

---Fold a result vector down to one load per host (hottest series wins).
---@param rows table[]|nil
---@return table @ host -> normalized load
function _M.host_values(rows)
    local by_host = {}
    if type(rows) ~= "table" then
        return by_host
    end
    for i = 1, #rows do
        local row = rows[i]
        local host = row and _M.host_of(row.labels)
        local load = _M.normalize(row and row.value)
        if host and load then
            if by_host[host] == nil or load > by_host[host] then
                by_host[host] = load
            end
        end
    end
    return by_host
end

---Map host -> load onto the in-pool workers.
---
---Several workers on one machine (four ranks of a DP engine, or two engines on one
---GPU box) all read the same host sample: the GPU is the shared resource, so the
---shared reading is the honest one. Series that name a host nobody in the pool
---serves are counted as unmatched and ignored, never invented into a worker.
---@param by_host table @ host -> normalized load
---@param workers table[] @ records ({id, url})
---@return table @ worker id -> normalized load
---@return number unmatched @ hosts with no worker behind them
function _M.assign(by_host, workers)
    local out, unmatched = {}, 0
    if type(workers) ~= "table" then
        return out, unmatched
    end
    local claimed = {}
    for i = 1, #workers do
        local worker = workers[i]
        local host = worker and _M.split_host(worker.url)
        if host and type(by_host) == "table" then
            local load = by_host[host]
            if load ~= nil then
                out[worker.id] = load
                claimed[host] = true
            end
        end
    end
    if type(by_host) == "table" then
        for host in pairs(by_host) do
            if not claimed[host] then
                unmatched = unmatched + 1
            end
        end
    end
    return out, unmatched
end

return _M
