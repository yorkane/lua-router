-- 应答 / CORS / request id / 请求头与标签（自 router.lua 逐字搬来）。
--
-- P3 错误应答 + P4 CORS + P5 request id + P10 请求/响应头白名单与标签。
-- HTTP 面逐字节不变是唯一验收口径（doc/refactor-arch-2026-10-05.md §0）。
local cjson = require "cjson.safe"

local host = require "resty.luarouter.router.host"

local _M = {}
package.loaded["resty.luarouter.router.respond"] = _M

local json_encode = cjson.encode
local json_decode = cjson.decode
local cfg = host.cfg
-- ------------------------------------------------------------------ responses

local STATUS_TEXT = {
    [400] = "Bad Request", [401] = "Unauthorized", [403] = "Forbidden",
    [404] = "Not Found", [405] = "Method Not Allowed", [408] = "Request Timeout",
    [409] = "Conflict", [422] = "Unprocessable Entity", [429] = "Too Many Requests",
    [500] = "Internal Server Error", [501] = "Not Implemented",
    [502] = "Bad Gateway", [503] = "Service Unavailable",
    [504] = "Gateway Timeout", [507] = "Failed Dependency",
}

---Error body in the gateway's shape, with X-SMG-Error-Code set. Does not send.
---@return string|nil body
local function error_body(status, code, message)
    ngx.header["X-SMG-Error-Code"] = code
    return json_encode({
        error = {
            ["type"] = STATUS_TEXT[status] or "Unknown Status Code",
            code = code,
            message = message,
        },
    })
end

---Rust answers every buffered response with an exact Content-Length (axum writes
---the body length itself); nginx only does that when the handler finishes without
---printing, so set the length explicitly and let nginx drop its chunked framing.
---@param bytes string @ the exact body about to be written
local function set_content_length(bytes)
    ngx.header["Content-Length"] = tostring(#bytes)
    return bytes
end

---Wrap a table-returning handler so klib.router never reaches its own print():
---the klib path encodes through filter and ngx.say's the result, which forces
---chunked framing. Encoding here keeps the same application/json content type
---but answers with an exact Content-Length, matching Rust's buffered responses.
---@param func fun(params:table, ctx:any, req:any):table|string, number|nil
local function exact_json(func)
    return function(params, ctx, req)
        local result, status = func(params, ctx, req)
        if type(result) ~= "table" then
            return result, status
        end
        if status then
            ngx.status = status
        end
        local text = json_encode(result)
        if not text then
            return result, status
        end
        ngx.header["Content-Type"] = "application/json"
        ngx.print(set_content_length(text))
        return ""
    end
end

---Send an error immediately, for handlers with nothing else to do.
local function send_error(status, code, message)
    ngx.status = status
    ngx.ctx.lr_error_code = code
    ngx.header["Content-Type"] = "application/json"
    local body = error_body(status, code, message)
    if body then
        ngx.print(set_content_length(body))
    end
    return ""
end

-- ------------------------------------------------------------------ CORS
--
-- The Rust gateway wraps the whole axum router in a tower-http CorsLayer
-- (server.rs:1429), so the CORS headers are on every response, including the
-- router's own 404 sink and the preflight answers. Two modes, from
-- create_cors_layer (server.rs:1899):
--   * SMG_CORS_ALLOWED_ORIGINS empty: origin/methods/headers/expose are all `*`
--   * non-empty: only the listed origins, and an Origin outside the list gets no
--     Access-Control-Allow-Origin at all (the browser then blocks the response)
-- Tower joins the Vary values with ", " (cors/vary.rs:29-33), the list forms of
-- Access-Control-Allow-{Methods,Headers} with "," and no space
-- (cors/mod.rs:465-482), and max-age only rides a preflight answer (cors/mod.rs:681).
local VARY_CORS = "origin, access-control-request-method, access-control-request-headers"
local CORS_METHODS_LIST = "GET,POST,OPTIONS"
local CORS_HEADERS_LIST = "content-type,authorization"
local CORS_EXPOSE_LIST = "x-request-id"
local CORS_MAX_AGE = "3600"

---Whether SMG_CORS_ALLOWED_ORIGINS narrows the advertised methods/headers, and
---which origin (if any) may be echoed back. Only the origin check is conditional:
---tower stores the wildcard and list forms of Allow-Origin as a constant header,
---so Access-Control-Allow-Origin `*`, Allow-Methods, Allow-Headers, Expose-Headers
---and Max-Age are emitted even when the request carries no Origin at all
---(cors/allow_origin.rs to_header, verified against the live Rust gateway).
---@return boolean restricted @ true when a whitelist is configured
---@return string|nil allowed @ `*`, the matched origin, or nil when not allowed
local function cors_decision()
    local origins = cfg().cors_allowed_origins or {}
    local restricted = #origins > 0
    if not restricted then
        return false, "*"
    end
    local origin = ngx.req.get_headers()["origin"]
    if type(origin) ~= "string" or origin == "" then
        return true, nil
    end
    for i = 1, #origins do
        if origins[i] == origin then
            -- A whitelist echoes the matched origin rather than `*`, which is what
            -- lets the browser pair the response with the requesting site.
            return true, origin
        end
    end
    return true, nil
end

---CORS headers for a normal (non-preflight) response. Vary is unconditional so
---caches keep the origin-dependent behaviour, matching tower.
local function cors_apply()
    local restricted, allowed = cors_decision()
    ngx.header["Vary"] = VARY_CORS
    if allowed then
        ngx.header["Access-Control-Allow-Origin"] = allowed
    end
    ngx.header["Access-Control-Expose-Headers"] =
        restricted and CORS_EXPOSE_LIST or "*"
end

---Answer a preflight without consulting the route table, like the CorsLayer does
---(cors/mod.rs:677-689: it builds the response itself). The task contract asks for
---a successful OPTIONS on every path, so this also catches paths the Rust gateway
---would 404 (documented deviation).
local function cors_preflight()
    local restricted, allowed = cors_decision()
    ngx.header["Vary"] = VARY_CORS
    if allowed then
        ngx.header["Access-Control-Allow-Origin"] = allowed
    end
    ngx.header["Access-Control-Allow-Methods"] =
        restricted and CORS_METHODS_LIST or "*"
    ngx.header["Access-Control-Allow-Headers"] =
        restricted and CORS_HEADERS_LIST or "*"
    ngx.header["Access-Control-Max-Age"] = CORS_MAX_AGE
    ngx.status = 200
    ngx.header["Content-Length"] = "0"
end

-- ------------------------------------------------------------------ request id

local ID_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

---Prefix mirrors generate_request_id() in gateway/src/middleware.rs.
local function generate_request_id(path)
    local prefix = "req-"
    if string.find(path, "/chat/completions", 1, true) then
        prefix = "chatcmpl-"
    elseif string.find(path, "/completions", 1, true) then
        prefix = "cmpl-"
    elseif string.find(path, "/generate", 1, true) then
        prefix = "gnt-"
    elseif string.find(path, "/responses", 1, true) then
        prefix = "resp-"
    end
    local out = {}
    for _ = 1, 24 do
        local index = math.random(#ID_ALPHABET)
        out[#out + 1] = ID_ALPHABET:sub(index, index)
    end
    return prefix .. table.concat(out)
end

local function request_id()
    local cached = ngx.ctx.lr_request_id
    if cached then
        return cached
    end
    local headers = ngx.req.get_headers()
    local id
    local configured = cfg().request_id_headers
    for i = 1, #configured do
        local value = headers[string.lower(configured[i])]
        if type(value) == "string" and value ~= "" then
            id = value
            break
        end
    end
    if not id then
        for _, name in ipairs({ "x-request-id", "x-correlation-id" }) do
            local value = headers[name]
            if type(value) == "string" and value ~= "" then
                id = value
                break
            end
        end
    end
    if not id then
        id = generate_request_id(ngx.var.uri or "/")
    end
    ngx.ctx.lr_request_id = id
    return id
end
-- ------------------------------------------------------------------ headers

-- Forwarded request headers, copied from should_forward_request_header().
local FORWARD_HEADERS = {
    "authorization", "x-request-id", "x-correlation-id", "traceparent",
    "tracestate", "x-smg-routing-key",
}
local FORWARD_PREFIX = "x-request-id-"

-- Hop-by-hop and framing headers dropped from the upstream response, copied from
-- should_forward_header_no_alloc(). content-length joins the drop list because we
-- re-frame the body ourselves; content-encoding is there because the Rust client
-- decompresses upstream responses itself, while we send Accept-Encoding: identity
-- and forward the bytes untouched.
local DROP_RESPONSE_HEADERS = {
    connection = true, ["keep-alive"] = true, ["proxy-authenticate"] = true,
    ["proxy-authorization"] = true, te = true, trailers = true,
    ["transfer-encoding"] = true, upgrade = true, ["content-encoding"] = true,
    host = true, ["content-length"] = true,
}

local function should_forward_request_header(name)
    local lower = string.lower(name)
    for i = 1, #FORWARD_HEADERS do
        if FORWARD_HEADERS[i] == lower then
            return true
        end
    end
    if #lower >= #FORWARD_PREFIX
        and string.lower(lower:sub(1, #FORWARD_PREFIX)) == FORWARD_PREFIX then
        return true
    end
    return false
end

_M.should_forward_request_header = should_forward_request_header
_M.DROP_RESPONSE_HEADERS = DROP_RESPONSE_HEADERS

local function collect_forward_headers(worker)
    local out = {}
    local incoming = ngx.req.get_headers()
    for name, value in pairs(incoming) do
        if should_forward_request_header(name) and type(value) == "string" then
            out[string.lower(name)] = value
        end
    end
    local content_type = incoming["content-type"]
    out["content-type"] = (type(content_type) == "string" and content_type)
        or "application/json"
    out["accept-encoding"] = "identity"
    if worker and worker.api_key and not out["authorization"] then
        out["authorization"] = "Bearer " .. worker.api_key
    end
    -- W3C traceparent/tracestate simply ride along: the module that used to
    -- replace them with the router's own span was removed (doc/scope-trim.md),
    -- which is the pass-through contract the header suite pins.
    return out
end

-- ------------------------------------------------------------------ labels

local ENDPOINT_LABELS = {
    ["/v1/chat/completions"] = "chat",
    ["/generate"] = "generate",
    ["/v1/completions"] = "completions",
    ["/v1/rerank"] = "rerank",
    ["/v1/responses"] = "responses",
    ["/v1/embeddings"] = "embeddings",
    ["/v1/classify"] = "classify",
}

local function endpoint_label(route)
    return ENDPOINT_LABELS[route] or "other"
end

local function error_type_from_status(status)
    if status == 400 then
        return "validation_error"
    elseif status == 404 then
        return "no_workers"
    elseif status == 408 or status == 504 then
        return "timeout"
    elseif status >= 500 and status <= 599 then
        return "backend_error"
    end
    return "internal_error"
end
_M.error_type_from_status = error_type_from_status
-- 跨模块接线（拆分新增；文末，不进任何单测锚点区间）：这些名字在原文件里是
-- 同文件局部，拆开后按名导出给 facade / forward / inference / control 直调。
-- 原处已有的就近导出（should_forward_request_header / DROP_RESPONSE_HEADERS
-- 1313-1314 / error_type_from_status 1365）留在上面原样，赋的是本模块 _M。
_M.STATUS_TEXT = STATUS_TEXT
_M.set_content_length = set_content_length
_M.exact_json = exact_json
_M.error_body = error_body
_M.send_error = send_error
_M.cors_apply = cors_apply
_M.cors_preflight = cors_preflight
_M.request_id = request_id
_M.generate_request_id = generate_request_id
_M.collect_forward_headers = collect_forward_headers
_M.endpoint_label = endpoint_label
return _M
