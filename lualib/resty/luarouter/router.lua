-- All endpoint handlers, organised as a klib.router APP rooted at "/".
--
-- Route table and response shapes follow gateway/src/server.rs plus
-- routers/{http/router.rs,header_utils.rs,error.rs}, so the same client, the
-- same admin tooling and the same Grafana dashboards work against either
-- implementation:
--   inference plane  read body -> extract model + routing text -> policy select
--                    -> rewrite the body's "model" -> cosocket forward
--                    -> stream: pump bytes through without buffering
--                    -> retry on 408/429/5xx with exponential backoff
--   control plane    /workers CRUD, /flush_cache, /v1/loads
--   public plane     /health /liveness /readiness /v1/models /server_info
--   observability    /metrics, /_ui/logs, /_ui/stats
--
-- Handler convention (klib.router): return a table for JSON, return a table plus
-- a status for JSON with an explicit code, and return '' once the response has
-- been written by hand. A number in 100..599 with no result is a bare status.
--
-- Kubernetes discovery, OTel tracing and cluster mesh are all wired: the first
-- behind its own knob (SMG_SERVICE_DISCOVERY), mesh behind SMG_MESH_PEERS - with
-- SMG_ENABLE_MESH off, /ha/* answers the fixed 503, which is the contract for a
-- node that has not opted in. The gRPC transport plane, the prefill/decode pool
-- split, the conversation/response store and the tokenize/parse proxy plane
-- were removed (doc/scope-trim.md): this gateway speaks plain HTTP to its
-- workers, /v1/responses is a pure inference route, and the token-counting and
-- tool-parser proxy family answers from the 404 sink.
--
-- What is genuinely not implemented is tracked in doc/feature-gap.md: wasm
-- middleware is a deferred TODO (doc/todo-deferred.md, feasibility in
-- doc/wasm-feasibility.md) and its three /wasm routes answer 501, and the four
-- smg_mcp_* families stay unregistered with the MCP server absent.

local cjson = require "cjson.safe"
local router_class = require "klib.router"

local hb = require "resty.luarouter.hb"
local observability = require "resty.luarouter.observability"
local otel = require "resty.luarouter.otel"
local policy_mod = require "resty.luarouter.policy"
local registry = require "resty.luarouter.registry"
-- Wired gap module: cluster mesh (doc/gap-mesh.md). It is load-safe without ngx
-- (it only reads ngx inside its handlers), so the init_by_lua syntax gate can
-- require it. The conversation/response store went with the history plane and
-- the tokenize/parse proxies went with it (doc/scope-trim.md): /v1/responses
-- stays as a pure inference route and that proxy family is not routed.
local mesh_mod = require "resty.luarouter.mesh"
-- service_discovery carries the data-parallel rank injection helper. Loaded
-- lazily (same shape as registry's sd()) so the module stays optional for the
-- init_by_lua syntax gate and a broken discovery file can never take the
-- forwarding path down.
local discovery_mod
local function discovery()
    if discovery_mod == nil then
        local ok, mod = pcall(require, "resty.luarouter.service_discovery")
        discovery_mod = ok and mod or false
    end
    return discovery_mod or nil
end

-- Declared here so the handlers below can reach it; the limiter itself is at
-- resty/luarouter/limit.lua.
local limit_mod
-- Defined with the mesh handlers, called by the /workers control plane.
local mesh_observe_worker
local mesh_forget_worker

---Accessor so the limiter module is required once per process.

local json_encode = cjson.encode
local json_decode = cjson.decode

local _M = { _VERSION = "0.1.0" }

local config
local default_policy

local function cfg()
    if not config then
        config = require("resty.luarouter").config()
    end
    return config
end

local function limit()
    if not limit_mod then
        limit_mod = require "resty.luarouter.limit"
    end
    return limit_mod
end

-- Policy selection, per model.
--
-- The Rust gateway owns one PolicyRegistry that keys policies by model
-- (policies/registry.rs): the hint a worker advertises in labels.policy fixes the
-- policy of its model when that model gets its first worker, later workers of the
-- same model do not change it, and a model without a hint uses the configured
-- default. policy_mod.for_model holds the instances; policy.default stays the
-- global one so init_worker's eviction sweep and mesh mirror have an anchor.
local function policy_for(model)
    local conf = cfg()
    if not default_policy then
        default_policy = policy_mod.new(conf)
        default_policy.generation = policy_mod.generation()
        policy_mod.default = default_policy
    end
    -- Idempotent: init_worker already starts the sweep in every process, so this
    -- only matters when the policy is built outside that phase (unit probes).
    policy_mod.start_eviction()
    if type(model) ~= "string" or model == "" then
        return default_policy
    end
    local hint, count = registry.policy_hint_for_model(model)
    if not hint then
        -- No advertised hint: Rust's get_policy_or_default. The global instance is
        -- keyed "default", so a model without a hint shares its affinity state with
        -- the fallback path exactly as the pre-per-model router did.
        return default_policy
    end
    return policy_mod.for_model(conf, model, hint, count > 0)
end

_M.policy_for = policy_for

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
---would 404 (deviation 4 in doc/gap-core.md).
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

---Open the OTel request span and answer the client with its context.
---
---Two jobs in one call, both cheap no-ops when SMG_ENABLE_TRACE is off:
---  * otel.begin() extracts the caller's traceparent (or generates a trace) - the
---    step Rust's TraceLayer does implicitly through the global propagator;
---  * the response header hands our own context back so a client can correlate.
---    Rust never answers with a traceparent, so this header is the one deliberate
---    addition on the propagation side (doc/gap-otel.md "与 Rust 的差异").
---@return table|nil trace
local function begin_trace()
    local trace = otel.begin()
    if trace and trace.traceparent then
        local sent = pcall(function()
            ngx.header["traceparent"] = trace.traceparent
        end)
        if not sent then
            observability.log_debug("could not set the traceparent response header")
        end
    end
    return trace
end

_M.begin_trace = begin_trace

-- ------------------------------------------------------------------ text extract

---Flatten a content value: strings pass through, arrays keep {type:"text"} parts.
local function content_to_text(content)
    if type(content) == "string" then
        return content
    end
    if type(content) ~= "table" then
        return nil
    end
    if content.type == "text" and type(content.text) == "string" then
        return content.text
    end
    local parts = {}
    for i = 1, #content do
        local segment = content[i]
        if type(segment) == "table" and segment.type == "text"
            and type(segment.text) == "string" and segment.text ~= "" then
            parts[#parts + 1] = segment.text
        end
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, " ")
end

-- Mirrors extract_text_for_routing in openai-protocol/src/chat.rs: walk messages
-- in order, take content for system/user/tool/developer, content plus
-- reasoning_content for assistant, content for function, joined by single spaces.
local function chat_text(body)
    local messages = body.messages
    if type(messages) ~= "table" then
        return ""
    end
    local parts = {}
    for i = 1, #messages do
        local message = messages[i]
        if type(message) == "table" then
            local role = message.role
            local text = content_to_text(message.content)
            if text and text ~= "" and (role == "assistant" or role == "system"
                or role == "user" or role == "tool" or role == "developer"
                or role == "function") then
                parts[#parts + 1] = text
            end
            if role == "assistant" then
                local reasoning = message.reasoning_content
                if type(reasoning) == "string" and reasoning ~= "" then
                    parts[#parts + 1] = reasoning
                end
            end
        end
    end
    return table.concat(parts, " ")
end

local function array_text(value)
    if type(value) == "string" then
        return value
    end
    if type(value) ~= "table" then
        return ""
    end
    local parts = {}
    for i = 1, #value do
        if type(value[i]) == "string" and value[i] ~= "" then
            parts[#parts + 1] = value[i]
        end
    end
    return table.concat(parts, " ")
end

-- One extractor per endpoint, matching that protocol's extract_text_for_routing.
local text_extractors = {
    ["/v1/chat/completions"] = chat_text,
    ["/generate"] = function(body) return array_text(body.text) end,
    ["/v1/completions"] = function(body) return array_text(body.prompt) end,
    ["/v1/embeddings"] = function(body) return array_text(body.input) end,
    ["/v1/classify"] = function(body) return array_text(body.input) end,
    ["/v1/rerank"] = function(body)
        return type(body.query) == "string" and body.query or ""
    end,
    ["/v1/responses"] = function(body)
        local input = body.input
        if type(input) == "string" then
            return input
        end
        if type(input) == "table" then
            return chat_text({ messages = input })
        end
        return ""
    end,
}
_M.text_extractors = text_extractors

-- ------------------------------------------------------------------ body rewrite

-- Lazily loaded: the runtime-config module owns virtual aliases, the effort
-- ladder and the per-model context cap (doc/impl-ui.md §5). Wrapped so a router
-- without it (unit probes) still forwards.
local function store()
    local ok, mod = pcall(require, "resty.luarouter.config_store")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

-- ------------------------------------------------------------------ raw JSON edits
--
-- The forwarded payload is edited in place rather than re-encoded from the
-- decoded table: cjson cannot tell an empty array from an empty object, so
-- re-encoding would turn "tools": [] into "tools": {}. Only the top-level
-- object is touched, and every edit is anchored on the key name so a nested
-- field with the same name stays alone.

---Presence pattern for one field name: the key followed by its colon. It says
---nothing about the value shape, which is deliberate -- the exact member is found
---by top_member_span below, and this pattern only decides whether that walk can
---possibly find anything. Anchoring on the key name (rather than a position) is
---what keeps a nested member that shares the name from being edited.
local function field_pattern(field)
    return '"' .. field .. '"\\s*:'
end

local QUOTE, BACKSLASH, COLON, COMMA = 34, 92, 58, 44
local OPEN_BRACE, CLOSE_BRACE = 123, 125
local OPEN_BRACKET, CLOSE_BRACKET = 91, 93

---Index just past the closing quote of the string that starts at `i`. Escapes are
---honoured, so `\"` never ends the string.
---@return number
local function skip_string(raw, i, n)
    local j = i + 1
    while j <= n do
        local b = raw:byte(j)
        if b == BACKSLASH then
            j = j + 2
        elseif b == QUOTE then
            return j + 1
        else
            j = j + 1
        end
    end
    return n + 1
end

---Last byte of the JSON value that starts at `v`, or nil when it never closes.
---Only the matching bracket type is counted: in valid JSON the other kind only
---ever appears inside a string, and strings are skipped whole.
---@return number|nil
local function value_end(raw, v, n)
    local b = raw:byte(v)
    if b == nil then
        return nil
    elseif b == QUOTE then
        return skip_string(raw, v, n) - 1
    elseif b == OPEN_BRACE or b == OPEN_BRACKET then
        local opener, closer = b, (b == OPEN_BRACE) and CLOSE_BRACE or CLOSE_BRACKET
        local depth = 0
        local j = v
        while j <= n do
            local d = raw:byte(j)
            if d == QUOTE then
                j = skip_string(raw, j, n) - 1
            elseif d == opener then
                depth = depth + 1
            elseif d == closer then
                depth = depth - 1
                if depth == 0 then
                    return j
                end
            end
            j = j + 1
        end
        return nil
    end
    -- number / true / false / null: the value runs to the next delimiter
    local j = v
    while j < n do
        local d = raw:byte(j + 1)
        if d == COMMA or d == CLOSE_BRACE or d == CLOSE_BRACKET
            or d == 32 or d == 9 or d == 10 or d == 13 then
            break
        end
        j = j + 1
    end
    return j
end

---Byte span of the first **top-level** member named `field`: value start, value
---end and the opening quote of the key, or nil when the document has no such
---member.
---
---A PCRE search returns the first match anywhere in the document, and an OpenAI
---response nests members that share names with the ones /v1/responses has to
---patch ("model" inside a usage or tool object, "instructions" inside an output
---item, "conversation" inside user metadata). Rust edits a decoded Map and so can
---only ever touch the top level; a pattern-based edit would corrupt the nested
---member instead. This walk counts depth, skips strings with their escapes, and
---only reads a key at depth 1 -- the scan stops at the first top-level hit, and a
---nested member with the same name never registers. A depth-1 value string can
---look like a key to the walk, but valid JSON never puts a colon after one, so it
---cannot be mistaken for a member name.
---
---The cheap PCRE presence gate in front keeps the common paths (key absent, so
---the caller appends) allocation-free and only pays for the walk when the name
---really appears in the document.
---@param raw string
---@param field string
---@return number|nil value_from, number|nil value_to, number|nil member_from
local function top_member_span(raw, field)
    if not ngx.re.find(raw, field_pattern(field), "jo") then
        return nil
    end
    local n = #raw
    local open = raw:find("{", 1, true)
    if not open then
        return nil
    end
    local depth = 0
    local i = open
    local key, key_from = nil, nil
    while i <= n do
        local b = raw:byte(i)
        if b == QUOTE then
            local after = skip_string(raw, i, n)
            if depth == 1 and key == nil then
                key = raw:sub(i + 1, after - 2)
                key_from = i
            end
            i = after
        elseif b == OPEN_BRACE or b == OPEN_BRACKET then
            depth = depth + 1
            i = i + 1
        elseif b == CLOSE_BRACE or b == CLOSE_BRACKET then
            depth = depth - 1
            if depth <= 0 then
                break
            end
            i = i + 1
        elseif b == COMMA and depth == 1 then
            key, key_from = nil, nil
            i = i + 1
        elseif b == COLON and depth == 1 and key ~= nil then
            if key == field then
                local v = i + 1
                while v <= n do
                    local w = raw:byte(v)
                    if w ~= 32 and w ~= 9 and w ~= 10 and w ~= 13 then
                        break
                    end
                    v = v + 1
                end
                local last = value_end(raw, v, n)
                if not last then
                    return nil
                end
                return v, last, key_from
            end
            key, key_from = nil, nil
            i = i + 1
        else
            i = i + 1
        end
    end
    return nil
end

---Set, add or remove the first top-level JSON member named `field`. Spliced by
---hand instead of through gsub: a replacement string would have to re-escape the
---JSON we just encoded, and gsub would also rewrite nested members that happen
---to share the name.
---@param raw string
---@param field string
---@param value string|number|nil @ nil removes the member
---@return string raw
local function set_top_field(raw, field, value)
    if type(raw) ~= "string" or raw == "" then
        return raw
    end
    local value_from, value_to, member_from = top_member_span(raw, field)

    if value == nil then
        if not value_from then
            return raw
        end
        -- Eat the comma on whichever side of the member exists, preferring the
        -- preceding one so a middle or last member never leaves a dangling comma.
        if raw:sub(member_from - 1, member_from - 1) == "," then
            return raw:sub(1, member_from - 2) .. raw:sub(value_to + 1)
        end
        local after = value_to + 1
        while after <= #raw and raw:sub(after, after):match("^%s$") do
            after = after + 1
        end
        if raw:sub(after, after) == "," then
            return raw:sub(1, member_from - 1) .. raw:sub(after + 1)
        end
        return raw:sub(1, member_from - 1) .. raw:sub(value_to + 1)
    end

    local encoded_value = json_encode(value)
    if not encoded_value then
        return raw
    end
    if value_from then
        -- The span covers the value only, so the key is already in place and a
        -- member that exists can never be left behind as a duplicate.
        return raw:sub(1, value_from - 1) .. encoded_value .. raw:sub(value_to + 1)
    end
    encoded_value = '"' .. field .. '":' .. encoded_value

    -- Absent: insert as the first member of the top-level object.
    local brace_from, brace_to = ngx.re.find(raw, [[^\s*\{]], "jo")
    if not brace_from then
        return raw
    end
    local tail = raw:sub(brace_to + 1)
    local rest = ngx.re.gsub(tail, [[^\s*\}\s*$]], "", "jo")
    if rest == "" then
        return raw:sub(1, brace_to) .. encoded_value .. "}"
    end
    return raw:sub(1, brace_to) .. encoded_value .. "," .. tail
end

_M.set_top_field = set_top_field

---Decode the first top-level member named `field` without re-encoding the
---surrounding document. Returns (value, present); a JSON null comes back as
---cjson.null rather than Lua nil so "absent" and "explicit null" stay distinct.
local function top_field_value(raw, field)
    local from, to = top_member_span(raw, field)
    if not from then
        return nil, false
    end
    local value = json_decode(raw:sub(from, to))
    if value == nil then
        return nil, false
    end
    return value, true
end

---Rust's is_missing_or_empty (responses/utils.rs:12-18): missing, JSON null or an
---empty string. An object or array -- including `{}` and `[]` -- is present.
---@param raw string
---@param field string
---@return boolean
local function missing_or_empty(raw, field)
    local value, present = top_field_value(raw, field)
    if not present then
        return true
    end
    if value == cjson.null then
        return true
    end
    return value == ""
end

---responses/utils.rs::patch_response_with_request_metadata, expressed as
---byte-preserving top-level edits. With the response store removed this is the
---client-facing half only: /v1/responses answers the upstream bytes with the
---request's own metadata echoed back, which is the Rust wire shape.
---@param raw string @ upstream response bytes
---@param body table @ decoded request
---@return string raw
local function patch_response_metadata(raw, body)
    if type(raw) ~= "string" or raw == "" or type(body) ~= "table" then
        return raw
    end

    if type(body.previous_response_id) == "string"
        and missing_or_empty(raw, "previous_response_id") then
        raw = set_top_field(raw, "previous_response_id", body.previous_response_id)
    end
    if type(body.instructions) == "string"
        and missing_or_empty(raw, "instructions") then
        raw = set_top_field(raw, "instructions", body.instructions)
    end
    if type(body.metadata) == "table"
        and missing_or_empty(raw, "metadata") then
        raw = set_top_field(raw, "metadata", body.metadata)
    end
    -- Unconditional, and a request without the field lands false: ResponsesRequest
    -- ::store is Option<bool> and Rust writes unwrap_or(false).
    raw = set_top_field(raw, "store", body.store == true)
    if missing_or_empty(raw, "model") then
        -- ResponsesRequest.model is a String whose serde default is "unknown"
        -- (openai-protocol common.rs::default_model), so a request that omitted
        -- it still lands a concrete model on the response. Rust reads the
        -- client's own field here, not the worker's resolved id.
        raw = set_top_field(raw, "model",
            type(body.model) == "string" and body.model or "unknown")
    end

    -- Rust inserts the user only when safety_identifier is present and null, and
    -- only for a user that deserialized into Some(String): a JSON null decodes to
    -- cjson.null here, which is not a string.
    local safety, safety_present = top_field_value(raw, "safety_identifier")
    if safety_present and safety == cjson.null and type(body.user) == "string" then
        raw = set_top_field(raw, "safety_identifier", body.user)
    end
    -- The conversation link is not echoed: it only ever meant "this stored
    -- response belongs to that conversation", and the store is gone.
    return raw
end

_M.patch_response_metadata = patch_response_metadata

-- Only the top-level "model" field is rewritten, which is the first occurrence
-- in any OpenAI-style payload. Anchoring on the key name (not a positional
-- regex) keeps a nested "model" further down the document untouched.
local MODEL_FIELD_RE = [==["model"\s*:\s*"(?:[^"\\]|\\.)*"]==]

---Point the payload at the selected worker's real model id, the way the Rust
---router overwrites payload["model"] before sending. The first occurrence only.
---@param raw string
---@param target string
---@return string
local function rewrite_model(raw, target)
    if type(target) ~= "string" or target == "" or target == "unknown" then
        return raw
    end
    local encoded_target = json_encode(target)
    if not encoded_target then
        return raw
    end
    local from, to = ngx.re.find(raw, MODEL_FIELD_RE, "jo")
    if not from then
        return raw
    end
    return raw:sub(1, from - 1) .. '"model":' .. encoded_target .. raw:sub(to + 1)
end

_M.rewrite_model = rewrite_model

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
    -- W3C propagation towards the worker (Rust inject_trace_context_http at
    -- routers/http/router.rs:382). Insert semantics: a traceparent the client sent
    -- is replaced by this router's own span id, so the worker sees us as its
    -- parent. With tracing off the call is a no-op and the caller's header is
    -- forwarded untouched, which is the pre-trace contract the 659-check suite pins.
    return otel.inject(out)
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

-- ------------------------------------------------------------------ selection

---Healthy, breaker-not-open workers. With IGW off every worker is a candidate
---whatever model it serves, as in the Rust router (effective_model_id is nil
---unless enable_igw).
local function candidates_for(model)
    local records = registry.records()
    local out = {}
    local igw = cfg().enable_igw
    for i = 1, #records do
        local record = records[i]
        if registry.is_available(record.id) then
            if not igw or not model or record.model_id == model
                or record.model_id == "unknown" then
                -- The standalone policies read load and health off the worker
                -- itself (Rust reads them through Worker::load()/is_healthy()),
                -- so hand them a snapshot alongside the static record. records()
                -- decodes fresh tables, so this cannot leak into the dict.
                record.load = registry.load(record.id)
                record.healthy = true
                out[#out + 1] = record
            end
        end
    end
    return out
end

local function compact_url(url)
    return ngx.re.gsub(url, [[^https?://]], "", "jo")
end

_M.candidates_for = candidates_for
_M.compact_url = compact_url

-- ------------------------------------------------------------------ usage

local function usage_from_object(usage)
    if type(usage) ~= "table" then
        return nil
    end
    local prompt = tonumber(usage.prompt_tokens or usage.input_tokens)
    local completion = tonumber(usage.completion_tokens or usage.output_tokens)
    if not prompt and not completion then
        return nil
    end
    local details = (type(usage.prompt_tokens_details) == "table"
        and usage.prompt_tokens_details) or nil
    local cached = tonumber(details and details.cached_tokens or usage.cached_tokens) or 0
    -- Reasoning tokens come from completion_tokens_details, with a bare
    -- usage.reasoning_tokens as the fallback: exactly the two shapes Rust reads
    -- (observability/request_log.rs:304-309 and :918-922). SGLang and the
    -- thinking-capable engines use either, and the UI shows the field either way.
    local out_details = (type(usage.completion_tokens_details) == "table"
        and usage.completion_tokens_details) or nil
    local reasoning = tonumber(out_details and out_details.reasoning_tokens
        or usage.reasoning_tokens) or 0
    return prompt or 0, completion or 0, cached, reasoning
end

---Token counts from a buffered JSON body.
---
---Never write `return f() or g()` here: `or` truncates the multi-valued return
---to its first value, so completion_tokens and cached_tokens silently become
---nil and every buffered request logs 0 completion tokens.
local function usage_from_body(body)
    if type(body) ~= "string" or body == "" then
        return nil
    end
    local decoded = json_decode(body)
    if type(decoded) ~= "table" then
        return nil
    end
    local prompt, completion, cached, reasoning = usage_from_object(decoded.usage)
    if prompt or completion then
        return prompt, completion, cached, reasoning
    end
    return usage_from_object(decoded.usage_metadata)
end

---Byte-based fallback, used only when the worker sent no usage object.
local function estimate_tokens(text)
    if not text or text == "" then
        return 0
    end
    return math.floor(#text / 4 + 0.5)
end

_M.usage_from_body = usage_from_body
_M.estimate_tokens = estimate_tokens

-- ------------------------------------------------------------------ session

local session_digest

--- sha256 hex of a string, lowercase, one byte at a time.
---
---Same byte-wise hex loop the worker-id helper uses, and deliberately the same
---shape as Rust's hex_lower (request_log.rs:141-149): the fingerprint lands in the
---request log and in the UI's session filter, so it has to be comparable with what
---the Rust gateway wrote for the same conversation.
---@param text string
---@return string|nil hex
local function sha256_hex(text)
    if not session_digest then
        local ok, mod = pcall(require, "resty.openssl.digest")
        if not ok then
            return nil
        end
        session_digest = mod
    end
    local d, err = session_digest.new("sha256")
    if not d then
        return nil
    end
    local ok, uerr = d:update(text)
    if not ok then
        return nil
    end
    local raw, ferr = d:final()
    if not raw then
        return nil
    end
    local hex = {}
    for i = 1, #raw do
        hex[#hex + 1] = string.format("%02x", string.byte(raw, i))
    end
    return table.concat(hex)
end

--- Stable conversation key: an explicit OpenAI-ish conversation/user field when
--- present, otherwise a hash of the leading messages so a multi-turn chat
--- collapses onto one row group in the UI's session filter.
---
--- Byte-for-byte the Rust rule (observability/request_log.rs:151-200): the first
--- non-empty string among prompt_cache_key / user / conversation / session_id is
--- hashed on its own, and failing that a two-message-or-longer conversation is
--- hashed as role + NUL + first-message content, where a multimodal content array
--- contributes the concatenation of its text parts. nil means "no key", which is
--- what a single-turn request without an explicit id gets in either gateway.
---@param body table @ decoded request body
---@return string|nil hex
local function router_session_key(body)
    if type(body) ~= "table" then
        return nil
    end
    local keys = { "prompt_cache_key", "user", "conversation", "session_id" }
    for i = 1, #keys do
        local value = body[keys[i]]
        if type(value) == "string" and value ~= "" then
            return sha256_hex(value)
        end
    end

    local messages = body.messages
    if type(messages) ~= "table" or #messages < 2 then
        return nil
    end
    local first = messages[1]
    if type(first) ~= "table" then
        return nil
    end
    local content = first.content
    local text
    if type(content) == "string" then
        text = content
    elseif type(content) == "table" then
        -- Array of typed parts (the OpenAI multimodal shape): only text parts
        -- identify the conversation, and Rust joins them with no separator.
        local parts = {}
        for i = 1, #content do
            local part = content[i]
            if type(part) == "table" and type(part.text) == "string" then
                parts[#parts + 1] = part.text
            end
        end
        text = table.concat(parts)
    else
        return nil
    end
    if text == "" then
        return nil
    end
    local role = type(first.role) == "string" and first.role or ""
    return sha256_hex(role .. "\0" .. text)
end

_M.router_session_key = router_session_key
_M.sha256_hex = sha256_hex

---Usage carried by the final SSE data event; the payload may straddle reads, so
---the caller hands over a sliding tail window.
local function sse_usage(tail)
    local found
    for data in string.gmatch(tail, "data:%s*(.-)\r?\n") do
        if data ~= "" and data ~= "[DONE]" then
            local decoded = json_decode(data)
            if type(decoded) == "table" then
                local prompt, completion, cached, reasoning =
                    usage_from_object(decoded.usage)
                if prompt then
                    found = { prompt, completion, cached, reasoning }
                end
            end
        end
    end
    if found then
        return found[1], found[2], found[3], found[4]
    end
    return nil
end

-- ------------------------------------------------------------------ cosocket

---Split the worker URL, dropping the brackets an IPv6 literal carries so the
---cosocket resolver can use the address.
local function connect_target(url)
    local host, port, tls = registry.split_url(url)
    if host:sub(1, 1) == "[" and host:sub(-1) == "]" then
        host = host:sub(2, -2)
    end
    return host, port, tls
end

_M.connect_target = connect_target

local function read_response_head(sock)
    local line, err = sock:receive("*l")
    if not line then
        return nil, nil, "no status line: " .. tostring(err)
    end
    local status = tonumber(string.match(line, "^HTTP/%d%.%d%s+(%d%d%d)"))
    if not status then
        return nil, nil, "malformed status line: " .. line
    end
    local headers = {}
    while true do
        local header = sock:receive("*l")
        if header == nil then
            return nil, nil, "connection closed while reading headers"
        end
        if header == "" then
            break
        end
        local name, value = string.match(header, "^([%w%-]+):%s?(.*)$")
        if name then
            local lower = string.lower(name)
            if headers[lower] then
                headers[lower] = headers[lower] .. ", " .. value
            else
                headers[lower] = value
            end
        end
    end
    return status, headers
end

---Send one attempt and read only the response head; the caller reads the body.
---
---The connect goes through a named cosocket pool (registry.pool_opts), which is the
---Lua equivalent of the reqwest client the Rust gateway builds once from
---pool_idle_timeout_secs / pool_max_idle_per_host / tcp_keepalive_secs. The class
---comes from `kind`: streaming, health probes and mesh traffic must not inherit each
---other's sockets, and an https target gets its own pool because replaying a pooled
---cleartext socket against a TLS worker is a protocol error rather than a slow start.
---@param worker table
---@param kind string|nil @ pool class: "forward" (default) or "stream"
---@return table|nil response @ {status, headers, sock, kind}
local function send_attempt(worker, method, path, payload, headers, kind)
    local host, port, tls = connect_target(worker.url)
    local conf = cfg()
    local timeout_ms = conf.request_timeout_secs * 1000
    local connect_ms = math.min(conf.connect_timeout_secs * 1000, timeout_ms)
    kind = kind or "forward"
    local sock = ngx.socket.tcp()
    sock:settimeouts(connect_ms, timeout_ms, timeout_ms)
    local ok, cerr = sock:connect(host, port,
        registry.pool_opts(conf, kind, worker.url))
    if not ok then
        sock:close()
        return nil, "connect failed: " .. tostring(cerr)
    end
    -- The ssl option on connect is ignored in http{} context: an https worker
    -- has to be upgraded explicitly or the request goes out in cleartext.
    local tls_ok, terr = registry.tls_handshake(sock, host, tls)
    if not tls_ok then
        sock:close()
        return nil, terr
    end

    local authority = host
    if port ~= (tls and 443 or 80) then
        authority = host .. ":" .. port
    end
    local head = method .. " " .. path .. " HTTP/1.1\r\n"
        .. "Host: " .. authority .. "\r\n"
    for name, value in pairs(headers) do
        head = head .. name .. ": " .. value .. "\r\n"
    end
    head = head .. "\r\n"

    local bytes, serr = sock:send(head)
    if not bytes then
        sock:close()
        return nil, "send headers failed: " .. tostring(serr)
    end
    if payload and payload ~= "" then
        local sent, berr = sock:send(payload)
        if not sent then
            sock:close()
            return nil, "send body failed: " .. tostring(berr)
        end
    end
    local status, response_headers, herr = read_response_head(sock)
    if not status then
        sock:close()
        return nil, herr
    end
    return { status = status, headers = response_headers, sock = sock,
        kind = kind }
end

local function is_chunked(headers)
    local value = headers["transfer-encoding"]
    return value ~= nil and string.find(string.lower(value), "chunked") ~= nil
end

---Drain the body of an attempt we are throwing away.
---
---Always closes rather than pooling: this is the retry path, and the upstream either
---answered a status we will not serve or the attempt is being abandoned. Rust's
---retry loop drops the whole response object there too, so the connection is not
---returned to the pool either way.
local function discard_body(sock, headers)
    if is_chunked(headers) then
        while true do
            local size_line = sock:receive("*l")
            if not size_line then break end
            local size = tonumber(size_line, 16)
            if not size or size == 0 then break end
            if not sock:receive(size) then break end
            sock:receive(2)
        end
    else
        local length = tonumber(headers["content-length"])
        if length and length > 0 then
            sock:receive(length)
        end
    end
    sock:close()
end

---Read a complete non-streaming body.
---
---Returns the bytes and whether the message reached its declared end. The second
---value is the pool's gate: a body that broke off midway leaves unread bytes behind,
---and setkeepalive() then either fails with "unread data in buffer" or hands the next
---request a connection that starts mid-message.
---@return string body, boolean complete
local function read_response_body(sock, headers)
    if is_chunked(headers) then
        -- pump_chunked also consumes the last chunk's CRLF and the trailer block,
        -- which is what makes the socket reusable afterwards.
        return registry.pump_chunked(sock, true)
    end
    local buffer = {}
    local complete = true
    local length = tonumber(headers["content-length"])
    if length and length > 0 then
        local remaining = length
        while remaining > 0 do
            local block = sock:receive(math.min(65536, remaining))
            if not block then
                complete = false
                break
            end
            buffer[#buffer + 1] = block
            remaining = remaining - #block
        end
    end
    return table.concat(buffer), complete
end

-- ------------------------------------------------------------------ streaming

---Pump an upstream body to the client without buffering it. The client-facing
---framing is decided here: keep an exact Content-Length, otherwise let nginx
---chunk the response. Returns ok, tail where tail carries the last bytes read
---(used to spot the SSE usage event).
---
---`ok` describes the UPSTREAM and the client together: the pump has nothing to
---keep once the client stops reading, so a failed write tears the pump down and
---the upstream bandwidth stops being spent (Rust's non-persistence branch
---cancels the request the same way, streaming.rs:661-722).
---@param sock table
---@param headers table
---@param kind string|nil @ pool class of the connection being pumped
---@param url string|nil @ worker url, so release() can size the pool
---@param conf table @ router config for the pool knobs
local function stream_response(sock, headers, kind, url, conf)
    local chunked = is_chunked(headers)
    local length = tonumber(headers["content-length"])
    if not (length and not chunked) then
        ngx.header.content_length = nil
    end

    local tail = ""
    local ok = true
    local prompt, completion, cached, reasoning = nil, nil, nil, nil
    -- Incremental usage state (M5). The old code re-ran sse_usage over the
    -- whole 64KB tail for every forwarded block: O(stream length x 64KB)
    -- gmatch+decode work. Here each byte is considered once: usage_carry holds
    -- the trailing incomplete line, only the newly completed text is scanned,
    -- and only lines that literally contain "usage" are decoded. A frame can
    -- still straddle reads -- its bytes stay in usage_carry until the
    -- terminating newline arrives. Once usage has been seen the scanner stops.
    local usage_carry = ""
    local usage_found = false

    local function note(text)
        tail = tail .. text
        if #tail > 65536 then
            tail = tail:sub(-65536)
        end
        if usage_found then
            return
        end
        local buf = usage_carry .. text
        local last_nl = nil
        local pos = 1
        while true do
            local nl = string.find(buf, "\n", pos, true)
            if not nl then
                break
            end
            last_nl = nl
            pos = nl + 1
        end
        if not last_nl then
            -- No complete line yet; cap the carry like the tail window.
            usage_carry = #buf > 65536 and buf:sub(-65536) or buf
            return
        end
        local complete = buf:sub(1, last_nl)
        usage_carry = buf:sub(last_nl + 1)
        if #usage_carry > 65536 then
            usage_carry = usage_carry:sub(-65536)
        end
        if string.find(complete, "usage", 1, true) == nil then
            return
        end
        -- Last usage frame inside this batch wins, which is what the whole-tail
        -- scan did (engines that repeat usage do it cumulatively), and after a
        -- batch that produced one the scanner switches off.
        local found
        for data in string.gmatch(complete, "data:%s*(.-)\r?\n") do
            if data ~= "" and data ~= "[DONE]"
                and string.find(data, "usage", 1, true) then
                local decoded = json_decode(data)
                if type(decoded) == "table" then
                    local p, c, a, r = usage_from_object(decoded.usage)
                    if p then
                        found = { p, c, a, r }
                    end
                end
            end
        end
        if found then
            prompt, completion, cached, reasoning =
                found[1], found[2], found[3], found[4]
            usage_found = true
        end
    end

    local function emit(text)
        if not ngx.print(text) then
            ok = false
            return false
        end
        ngx.flush(true)
        note(text)
        return true
    end

    -- reusable: did the upstream message end cleanly at a framing boundary? Only
    -- then may the socket go back to the pool. A length- or chunk-delimited body
    -- that reached its end qualifies; a connection-delimited body never does (its
    -- end is the disconnect), and neither does a stream that broke off midway or
    -- one the client stopped reading.
    local reusable = false
    local remaining = length
    if length and not chunked then
        while ok and remaining > 0 do
            local block = sock:receive(math.min(65536, remaining))
            if not block then
                ok = false
                break
            end
            remaining = remaining - #block
            emit(block)
        end
        reusable = ok and remaining <= 0
    elseif chunked then
        -- Deliberately not registry.pump_chunked: that buffers the whole body, and
        -- an SSE stream has to reach the client chunk by chunk. The trailer block
        -- is consumed by hand for the same reason the pool needs it consumed.
        local complete = false
        while ok do
            local size_line = sock:receive("*l")
            if not size_line then
                ok = false
                break
            end
            local size = tonumber(string.match(size_line, "^%x+") or "", 16)
            if not size then
                ok = false
                break
            end
            if size == 0 then
                complete = true
                break
            end
            local block = sock:receive(size)
            if not block then
                ok = false
                break
            end
            sock:receive(2)
            emit(block)
        end
        if complete and ok then
            while true do
                local line = sock:receive("*l")
                if line == nil or line == "" then
                    break
                end
            end
        else
            ok = false
        end
        reusable = complete and ok
    else
        -- Connection-delimited upstream body.
        while ok do
            local block, err = sock:receive(65536)
            if not block then
                if err ~= "closed" and err ~= "timeout" then
                    ok = false
                end
                break
            end
            emit(block)
        end
    end

    registry.release(sock, conf,
        registry.response_reusable(headers, reusable), kind, url)
    return ok, tail, prompt, completion, cached, reasoning
end

---Track the in-flight reservation per worker so log_by_lua can sweep any guard
---the handler failed to hand back.
local function hold_load(worker)
    registry.change_load(worker.id, 1)
    local held = ngx.ctx.lr_held
    if not held then
        held = {}
        ngx.ctx.lr_held = held
    end
    held[#held + 1] = worker.id
end

local function release_load(worker)
    local held = ngx.ctx.lr_held
    if held then
        for i = #held, 1, -1 do
            if held[i] == worker.id then
                table.remove(held, i)
                break
            end
        end
    end
    registry.change_load(worker.id, -1)
end

-- ------------------------------------------------------------------ retry loop

---Backoff for a 0-based attempt index, mirroring BackoffCalculator.
local function backoff_delay(attempt)
    local conf = cfg()
    local delay = math.floor(conf.initial_backoff_ms * (conf.backoff_multiplier ^ attempt))
    if delay > conf.max_backoff_ms then
        delay = conf.max_backoff_ms
    end
    local jitter = conf.jitter_factor
    if jitter > 0 then
        local scale = (math.random() * 2 - 1) * jitter
        delay = math.max(0, math.floor(delay + delay * scale))
    end
    return delay
end

local function apply_response_headers(headers)
    for name, value in pairs(headers) do
        if not DROP_RESPONSE_HEADERS[name] then
            local sent = pcall(function()
                ngx.header[name] = value
            end)
            if not sent then
                observability.log_debug("dropping unusable upstream header: " .. name)
            end
        end
    end
    ngx.header["X-Request-Id"] = request_id()
    -- The worker echoes nothing back that we would forward as traceparent (it is
    -- not in DROP_RESPONSE_HEADERS, but its value is the *worker's* span, not
    -- ours): stamp our own so the client always sees the router's context.
    local trace = otel.current()
    if trace and trace.traceparent then
        pcall(function()
            ngx.header["traceparent"] = trace.traceparent
        end)
    end
    -- Upstream can emit its own CORS headers (a worker behind its own gateway),
    -- which would replace what cors_apply set for this response.
    cors_apply()
end

---Is the per-attempt child span wanted? Default on; SMG_TRACE_UPSTREAM_CHILD=0
---turns it off. Read with os.getenv per request (the name is declared via `env` in
---all three shipped configs), so a typo can never break the request path.
local function upstream_child_enabled()
    local value = os.getenv("SMG_TRACE_UPSTREAM_CHILD")
    if value == nil or value == "" then
        return true
    end
    value = string.lower(value)
    return not (value == "0" or value == "false" or value == "no" or value == "off")
end

---Open the attempt child span. Returns nil whenever there is nothing to record, so
---the retry loop never has to branch on the tracing feature.
---@param worker table
---@param route string
---@param attempt number
---@return table|nil child
local function otel_upstream_child(worker, route, attempt)
    if not otel.is_enabled() or not upstream_child_enabled() then
        return nil
    end
    local child = otel.child_start("upstream_forward")
    if not child then
        return nil
    end
    child.attrs = {
        otel.attr_string("worker", worker.url),
        otel.attr_string("worker_id", worker.id or ""),
        otel.attr_string("method", "POST"),
        otel.attr_string("path", route),
        otel.attr_int("attempt", attempt),
    }
    return child
end

---Close the attempt span. A connect failure has no status, so the error text is
---recorded instead - that is what makes a dead worker visible inside a trace.
---@param child table|nil
---@param status number|nil
---@param conn_err string|nil
local function otel_upstream_child_end(child, status, conn_err)
    if not child then
        return
    end
    if not status and conn_err then
        child.attrs[#child.attrs + 1] = otel.attr_string("error", tostring(conn_err))
    end
    otel.child_end(child, child.attrs, status)
end

---Forward one inference request with retries. Returns status, buffered_body_or_nil.
---For streaming requests the body is nil because it was already written out.
---@param route string
---@param body table @ decoded request body
---@param raw_body string @ original bytes
---@param model string|nil
---@param text string|nil @ routing text
---@param incoming table|nil @ request headers (defaults to the live request)
local function forward(route, body, raw_body, model, text, incoming)
    local conf = cfg()
    local is_stream = body.stream == true
    local endpoint = endpoint_label(route)

    incoming = incoming or ngx.req.get_headers()
    local routing_key = incoming["x-smg-routing-key"]
    if type(routing_key) ~= "string" or routing_key == "" then
        routing_key = nil
    end
    local pinned = incoming["x-smg-target-worker"]
    if type(pinned) ~= "string" or pinned == "" then
        pinned = nil
    end

    observability.record_router_request(model or "unknown", endpoint, is_stream)

    local max_attempts = conf.disable_retries and 1 or math.max(1, conf.max_retries)
    local attempt = 0
    local ttft_recorded = false

    while true do
        attempt = attempt + 1
        local candidates = candidates_for(model)
        local worker
        if pinned then
            for i = 1, #candidates do
                if candidates[i].id == pinned then
                    worker = candidates[i]
                    break
                end
            end
        end
        if not worker then
            worker = policy_for(model):select({
                candidates = candidates,
                routing_key = routing_key,
                request_text = text,
                headers = incoming,
                model = model,
            })
        end

        if not worker then
            observability.record_router_error(model or "unknown", endpoint, "no_workers")
            observability.note_error()
            ngx.status = 503
            -- The body is printed by route_inference, so the JSON content type
            -- has to be claimed here; Rust answers this path as application/json.
            ngx.header["Content-Type"] = "application/json"
            return 503, error_body(503, "no_available_workers",
                "No available workers (all circuits open or unhealthy)")
        end

        ngx.ctx.lr_worker = worker
        hold_load(worker)
        local otel_child = otel_upstream_child(worker, route, attempt)

        local payload = rewrite_model(raw_body, worker.model_id)
        -- A DP-aware engine needs to know which shard a call belongs to, so the
        -- forwarded body names it as a top-level member -- the same
        -- data_parallel_rank Rust writes in http/router.rs:575-617. Gated on
        -- cfg().dp_aware because that is Rust's switch too: a rank field left on a
        -- record by a hand-written POST /workers must not start rewriting bodies on
        -- a deployment that never opted in. The splice is byte-preserving, and a
        -- worker without dp_rank keeps the client's body exactly as sent.
        if cfg().dp_aware and discovery() then
            payload = (discovery().inject_dp_rank(payload, worker))
        end
        local forward_headers = collect_forward_headers(worker)
        forward_headers["content-length"] = tostring(#payload)

        -- The child span for this attempt is opened above (after the worker is
        -- picked) and closed on the line after send_attempt. Rust's HTTP plane
        -- creates no child span here - it emits RequestSentEvent /
        -- RequestReceivedEvent inside the parent span, and only its non-HTTP
        -- plane has a real child span - so this is a documented addition,
        -- switchable with SMG_TRACE_UPSTREAM_CHILD.
        local response, conn_err = send_attempt(worker, "POST", route, payload,
            forward_headers, is_stream and "stream" or "forward")
        otel_upstream_child_end(otel_child, response and response.status, conn_err)
        if not response then
            release_load(worker)
            hb.record_outcome(worker.id, false)
            observability.record_worker_error(worker.url, "backend_error")
            observability.log_debug("attempt " .. attempt .. " to " .. worker.url
                .. " failed: " .. tostring(conn_err))
            if attempt >= max_attempts then
                observability.note_error()
                ngx.status = 502
                ngx.header["Content-Type"] = "application/json"
                return 502, error_body(502, "call_upstream_connect_error",
                    tostring(conn_err) .. ". URL: " .. worker.url)
            end
            local delay = backoff_delay(attempt - 1)
            observability.record_worker_retry(endpoint)
            observability.record_worker_retry_backoff(attempt, delay / 1000)
            ngx.sleep(delay / 1000)

        else
            local status = response.status
            observability.record_router_upstream_response(status,
                response.headers["x-smg-error-code"] or "")

            if hb.is_retryable_status(status) and attempt >= max_attempts then
                -- Rust calls on_exhausted() when the last allowed attempt still
                -- came back retryable; the response is then returned as-is.
                observability.record_worker_retries_exhausted(endpoint)
            end

            if hb.is_retryable_status(status) and attempt < max_attempts then
                discard_body(response.sock, response.headers)
                release_load(worker)
                hb.record_status(worker.id, status)
                local delay = backoff_delay(attempt - 1)
                observability.record_worker_retry(endpoint)
                observability.record_worker_retry_backoff(attempt, delay / 1000)
                observability.log_debug("retryable " .. status .. " from " .. worker.url)
                ngx.sleep(delay / 1000)

            elseif is_stream then
                -- Commit status and headers, then copy bytes. The breaker outcome
                -- is recorded when the stream ends, never from the status line, so
                -- a "200 then broken pipe" worker still counts as a failure.
                ngx.status = status
                apply_response_headers(response.headers)
                if status < 400 and not ttft_recorded then
                    ttft_recorded = true
                    local seconds = ngx.now() - (ngx.ctx.lr_started or ngx.now())
                    ngx.ctx.lr_ttft = seconds
                    observability.record_router_ttft(model or "unknown", endpoint, seconds)
                end
                -- Every stream takes the zero-buffer fast path now (the
                -- history plane used to allocate an accumulator for
                -- store=true / conversation requests so the response could be
                -- stored; scope-trim.md removed that plane).
                local stream_ok, tail, prompt, completion, cached, reasoning =
                    stream_response(response.sock, response.headers,
                        response.kind, worker.url, conf)
                release_load(worker)
                hb.record_outcome(worker.id, stream_ok and status < 400)
                if not stream_ok then
                    observability.record_worker_error(worker.url, "backend_error")
                end
                local estimated = (not prompt) and (not completion)
                if estimated then
                    prompt, completion, cached = 0, estimate_tokens(tail), 0
                end
                -- Slot 5 is reasoning_tokens, slot 4 the "estimated" flag; both
                -- are read back by log_inference_request.
                ngx.ctx.lr_tokens = { prompt or 0, completion or 0, cached or 0,
                    estimated and 1 or nil, reasoning or 0 }
                if not stream_ok then
                    observability.note_error()
                end
                return status, nil

            else
                local response_body, body_complete =
                    read_response_body(response.sock, response.headers)
                -- Only a body that reached its declared end may be pooled, and the
                -- idle TTL is the pool's own (SMG_POOL_IDLE_TIMEOUT_SECS), not the
                -- request timeout: a socket that outlives the request budget would
                -- sit in the pool longer than the peer is likely to keep it.
                registry.release(response.sock, conf, registry.response_reusable(
                    response.headers, body_complete), response.kind, worker.url)
                release_load(worker)
                hb.record_status(worker.id, status)
                ngx.status = status
                apply_response_headers(response.headers)
                if status >= 400 then
                    observability.record_router_error(model or "unknown", endpoint,
                        error_type_from_status(status))
                    if status >= 500 then
                        observability.record_worker_error(worker.url, "backend_error")
                    end
                    observability.note_error()
                end
                local prompt, completion, cached, reasoning =
                    usage_from_body(response_body)
                local estimated = false
                if not prompt then
                    prompt, completion, cached = 0,
                        estimate_tokens(response_body), 0
                    estimated = true
                end
                ngx.ctx.lr_tokens = { prompt, completion, cached,
                    estimated and 1 or nil, reasoning or 0 }
                return status, response_body
            end
        end
    end
end

-- ------------------------------------------------------------------ inference plane

-- Defined further down (it needs the request-log writer); forward declared so
-- both handle() and the /_ui chat pipeline can reach it.
local finish_request

---Routing text for a route: the standalone policies need it (cache_aware, bucket,
---prefix_hash), the others ignore it. Empty means "no text" to the policies, which
---is how the modules were unit-tested.
local function text_for(route, body)
    local extractor = text_extractors[route]
    local text = extractor and extractor(body) or ""
    if type(text) ~= "string" then
        return nil
    end
    return text
end

---Virtual alias -> upstream id (doc/impl-ui.md 5). Rust resolves inside
---route_typed_request_once, so the candidate set, the policy state, the effort
---cards and the forwarded payload all key off the real id while the request log
---keeps the alias the client asked for.
local function resolve_alias(model)
    if type(model) ~= "string" or model == "" then
        return model
    end
    local store_mod = store()
    if store_mod and type(store_mod.resolve_model) == "function" then
        return store_mod.resolve_model(model)
    end
    return model
end

---Rust apply_effort_policy: the runtime config decides what the engine is asked
---for. `LMR_DEFAULT_EFFORT` fills a request that names no effort,
---`LMR_EFFORT_MAP` rewrites one that does, `LMR_MODEL_EFFORT` wins over both.
---@param raw string
---@param body table @ decoded request
---@param model string|nil @ resolved model id
---@return string raw, string|nil requested, string|nil effective
local function apply_effort_policy(raw, body, model)
    local requested
    if type(body.reasoning_effort) == "string" then
        requested = body.reasoning_effort
    end
    local store_mod = store()
    if not store_mod or type(store_mod.request_effort_for) ~= "function" then
        return raw, requested, requested
    end
    local ok, effective = pcall(store_mod.request_effort_for, model, requested)
    if not ok or type(effective) ~= "string" or effective == "" then
        -- Nothing configured and nothing requested: leave the field alone, which
        -- lets the engine default apply (as in Rust).
        return raw, requested, nil
    end
    if requested == effective then
        return raw, requested, effective
    end
    return set_top_field(raw, "reasoning_effort", effective), requested, effective
end

---Rust apply_ctx_cap: clamp max_tokens and its alias to the model context cap.
---Absent fields are written too, matching `current.is_none_or(|v| v > cap)`.
---@return string raw, number|nil cap
local function apply_ctx_cap(raw, body, model)
    local store_mod = store()
    if not store_mod or type(store_mod.ctx_cap) ~= "function" then
        return raw, nil
    end
    local ok, cap = pcall(store_mod.ctx_cap, model)
    if not ok or type(cap) ~= "number" or cap < 1 then
        return raw, nil
    end
    for _, field in ipairs({ "max_tokens", "max_completion_tokens" }) do
        local current = tonumber(body[field])
        if current == nil or current > cap then
            raw = set_top_field(raw, field, cap)
        end
    end
    return raw, cap
end

---Shared pipeline for every inference route: pick a worker, rewrite the payload,
---forward, write the response. Returns the status and (for buffered responses)
---the upstream bytes; streaming responses are already on the wire.
---@param route string
---@param body table @ decoded request
---@param raw string @ bytes to forward
---@return number status, string|nil response_body
local function route_inference(route, body, raw)
    if body.model ~= nil and type(body.model) ~= "string" then
        -- Rust deserializes model as String with a serde default, so an explicit
        -- null (cjson.null here), number or object fails the body parse with 400
        -- rather than routing as if the field were absent.
        return send_error(400, "invalid_json",
            "request field \"model\" must be a string")
    end
    local requested_model
    if type(body.model) == "string" and body.model ~= "" then
        requested_model = body.model
    end
    local model = requested_model
    if not model then
        if cfg().enable_igw then
            -- Rust deserializes a missing "model" to UNKNOWN_MODEL_ID
            -- (openai-protocol common.rs default_model), so with IGW on the
            -- lookup is get_by_model("unknown"): only workers whose model was
            -- never discovered match, and a registered pool returns 503.
            model = "unknown"
        else
            -- Single-model deployments route by worker even when the client
            -- omitted the field; the Rust gateway does the same via
            -- effective_model_id = nil.
            local first = registry.records()[1]
            model = first and first.model_id or "unknown"
        end
    end
    local resolved = resolve_alias(model) or model

    -- /generate carries its own sampling fields, so the effort ladder and the
    -- context cap stay off that route (Rust router.rs skips them too).
    local requested_effort, effective_effort
    if route ~= "/generate" then
        raw, requested_effort, effective_effort = apply_effort_policy(raw, body, resolved)
        raw = (apply_ctx_cap(raw, body, resolved))
    end

    ngx.ctx.lr_session = router_session_key(body)
    ngx.ctx.lr_model = resolved or "unknown"
    ngx.ctx.lr_requested_model = requested_model or resolved
    ngx.ctx.lr_model_query = resolved
    ngx.ctx.lr_endpoint = endpoint_label(route)
    ngx.ctx.lr_stream = (body.stream == true)
    ngx.ctx.lr_requested_effort = requested_effort
    ngx.ctx.lr_effort = effective_effort

    -- Only extract routing text when the policy reads it: the flattening walks
    -- every message, which random / round_robin / the hash ring never look at.
    local inst = policy_for(resolved)
    -- The request log calls this field route_type; the span reuses the same value
    -- so a trace and a log row name the same decision.
    ngx.ctx.lr_route_type = inst:policy_name()
    local text = inst:needs_request_text() and text_for(route, body) or nil
    local status, response_body = forward(route, body, raw, resolved, text,
        ngx.req.get_headers())
    if route == "/v1/responses" and status >= 200 and status < 300 then
        -- Rust patches the response Value before it answers (non_streaming.rs:
        -- 141-167). The response store is gone (scope-trim.md), so this is the
        -- only consumer and the client sees the same byte-preserving echo of its
        -- own request metadata.
        response_body = patch_response_metadata(response_body, body)
    end
    if response_body and response_body ~= "" then
        -- Upstream framing is dropped (content-length is in DROP_RESPONSE_HEADERS),
        -- so re-state the exact length like Rust does instead of letting nginx chunk.
        ngx.print(set_content_length(response_body))
    end
    return status, response_body
end

---Shared handler for every inference route.
local function inference_handler(params)
    -- The gateway authenticates nothing (doc/scope-trim.md): the whole surface
    -- is open and the concurrency gate is the first thing a request meets.
    if not limit().acquire() then
        -- Empty body, like StatusCode::TOO_MANY_REQUESTS.into_response(); the
        -- rejection counter is bumped inside limit.acquire().
        ngx.status = 429
        ngx.header["Content-Length"] = "0"
        return ""
    end
    local route = params.route

    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if not raw then
        local file = ngx.req.get_body_file()
        if file then
            local handle = io.open(file, "rb")
            if handle then
                raw = handle:read("*a")
                handle:close()
            end
        end
    end
    raw = raw or ""

    local body = json_decode(raw)
    if type(body) ~= "table" then
        return send_error(400, "invalid_json", "request body must be a JSON object")
    end

    route_inference(route, body, raw)
    return ""
end

---The webui chat/completion aliases (ui.lua, doc/impl-ui.md 3). The UI layer has
---already read the body, filled a missing model and dropped an empty effort, and
---passes the (spliced) original bytes alongside the decoded table; the pipeline
---owns everything else, including the accounting that handle() would have done
---had the request come through `location /`.
---@param route string
---@param body table
---@param raw_body string|nil @ original bytes; falls back to re-encoding
local function ui_pipeline(route, body, raw_body)
    local started = ngx.now()
    ngx.ctx.lr_started = started
    local method = ngx.req.get_method()
    local path = ngx.var.uri or route
    observability.record_http_request(method, path)
    begin_trace()

    -- Forward the caller's bytes whenever they exist. Re-encoding the decoded
    -- table is the last resort only: cjson cannot tell [] from {}, so a UI body
    -- with "tools":[] or "stop":[] would reach the worker as an empty object.
    local raw = raw_body
    if type(raw) ~= "string" or raw == "" then
        raw = json_encode(body)
    end
    if not raw then
        send_error(400, "invalid_json", "request body must be a JSON object")
        finish_request(started, method, path)
        return ""
    end

    -- The klib 500 handler is not in this call path, so catch and answer here
    -- rather than letting nginx print its own error page.
    local ok, status, response_body = pcall(route_inference, route, body, raw)
    if not ok then
        ngx.log(ngx.ERR, "luarouter: /_ui pipeline error: ", tostring(status))
        send_error(500, "internal_error", tostring(status))
        finish_request(started, method, path)
        return ""
    end

    finish_request(started, method, path)
    if not response_body and ngx.status < 400 then
        -- Streaming: the bytes are already on the wire, so just finalize.
        return ngx.exit(ngx.status)
    end
    return ""
end

---POST /_ui/v1/chat/completions
function _M.do_chat(body, raw_body)
    return ui_pipeline("/v1/chat/completions", body, raw_body)
end

---POST /_ui/v1/completions
function _M.do_completion(body, raw_body)
    return ui_pipeline("/v1/completions", body, raw_body)
end

-- ------------------------------------------------------------------ public plane

---Plain-text answer, since klib.router defaults to text/html for strings.
local function text_response(status, text, content_type)
    ngx.status = status
    ngx.header["Content-Type"] = content_type or "text/plain; charset=utf-8"
    if text and text ~= "" then
        ngx.print(set_content_length(text))
    end
    return ""
end

local function health_handler()
    return text_response(200, "OK")
end

---GET /health_generate - "is there anybody home", in Rust's exact words.
---@return string "" @ (text_response already wrote the answer)
local function health_generate_handler()
    local records = registry.records()
    for i = 1, #records do
        if registry.is_healthy(records[i].id) then
            return text_response(200, "At least one router has healthy workers")
        end
    end
    return text_response(503, "No routers with healthy workers available")
end

_M.health_generate_handler = health_generate_handler

---Ready when at least one worker is healthy (Regular mode, Rust semantics).
local function readiness_handler()
    local records = registry.records()
    local healthy = 0
    for i = 1, #records do
        if registry.is_healthy(records[i].id) then
            healthy = healthy + 1
        end
    end
    if healthy > 0 then
        return { status = "ready", healthy_workers = healthy, total_workers = #records }
    end
    return { status = "not ready", reason = "insufficient healthy workers" }, 503
end

---Advertise the runtime virtual-model aliases next to the real ones, the way
---inject_virtual_models (gateway/src/server.rs:831) does: an alias whose name a
---real worker already serves is skipped, the synthetic entries carry created 0
---and owned_by "llm-router-><target>", and the whole list is re-sorted by id.
---@param data table @ model entries built from the registry (mutated)
local function inject_virtual_models(data)
    local store_mod = store()
    if not store_mod or type(store_mod.virtual_models_list) ~= "function" then
        return
    end
    local aliases = store_mod.virtual_models_list()
    if #aliases == 0 then
        return
    end
    local seen = {}
    for i = 1, #data do
        seen[data[i].id] = true
    end
    for i = 1, #aliases do
        local alias, target = aliases[i][1], aliases[i][2]
        if not seen[alias] then
            -- A real worker keeps the name; the alias is dropped rather than
            -- duplicating the id, which would break clients that key on it.
            seen[alias] = true
            data[#data + 1] = {
                id = alias,
                object = "model",
                created = 0,
                owned_by = "llm-router->" .. tostring(target),
            }
        end
    end
    table.sort(data, function(a, b)
        return tostring(a.id) < tostring(b.id)
    end)
end

local function models_handler()
    local models = registry.models()
    if #models == 0 then
        -- Rust only rewrites responses that carry a "data" array, so the
        -- no-worker text answer is returned untouched.
        return text_response(503, "No models available")
    end
    local data = {}
    for i = 1, #models do
        data[i] = { id = models[i], object = "model", owned_by = "local" }
    end
    inject_virtual_models(data)
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

---Captured path segment, unescaped. Declared here because the store handlers
---below run first: klib.router hands out one `:param` per path section.
local function param_text(params, name)
    local value = params[name]
    if type(value) == "table" then
        value = value[1]
    end
    if type(value) ~= "string" then
        return nil
    end
    return ngx.unescape_uri(value)
end

-- ------------------------------------------------------------------ metrics
--
-- Prometheus text aggregation, ported from core/metrics_aggregator.rs.
--
-- Rust parses each worker's /metrics with openmetrics-parser, stamps every family
-- with the extra label worker_addr (the full worker url), merges the expositions
-- family by family, and re-renders the result. Doing it in Lua the same way is
-- what makes the endpoint scrapable at all: the old implementation concatenated
-- the per-worker bodies under a "# worker <url>" comment, so the same name
-- appeared with two "# HELP" / "# TYPE" lines, which a Prometheus scraper rejects.

---openmetrics-parser rejects colons in metric names, so Rust rewrites the whole
---text before parsing (metrics_aggregator.rs:20). It is a blanket replace and
---therefore touches label values and help text too; only labels added after
---parsing keep their colons, which is why worker_addr still reads http://host:port.
---Ported literally, quirks included.
---@param text string
---@return string
local function underscore_colons(text)
    return (string.gsub(text, ":", "_"))
end

---Scan a label list `a="1",b="x\"y"` starting at the opening brace.
---
---A character loop rather than a pattern because a Prometheus label value may
---contain commas, braces and escaped quotes, which no single pattern handles.
---Returns nil on a malformed list so the caller drops the sample instead of
---corrupting the family.
---@param text string
---@param start number @ index of the "{"
---@return table|nil labels @ {{name, value}, ...}, number|nil next index
local function scan_labels(text, start)
    local labels = {}
    local n = #text
    local pos = start + 1
    while pos <= n do
        local c = text:sub(pos, pos)
        if c == "}" then
            return labels, pos + 1
        end
        if c == "," then
            pos = pos + 1
        end
        local name_start = pos
        local eq = nil
        while pos <= n do
            local ch = text:sub(pos, pos)
            if ch == "=" then
                eq = pos
                break
            end
            if ch == "}" or ch == "," or ch == '"' then
                return nil
            end
            pos = pos + 1
        end
        if not eq then
            return nil
        end
        local name = text:sub(name_start, eq - 1):gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then
            return nil
        end
        pos = eq + 1
        if text:sub(pos, pos) ~= '"' then
            return nil
        end
        pos = pos + 1
        local value = {}
        local closed = false
        while pos <= n do
            local ch = text:sub(pos, pos)
            if ch == "\\" then
                local nxt = text:sub(pos + 1, pos + 1)
                if nxt == "n" then
                    value[#value + 1] = "\n"
                elseif nxt == "\\" then
                    value[#value + 1] = "\\"
                elseif nxt == '"' then
                    value[#value + 1] = '"'
                else
                    value[#value + 1] = nxt
                end
                pos = pos + 2
            elseif ch == '"' then
                pos = pos + 1
                closed = true
                break
            else
                value[#value + 1] = ch
                pos = pos + 1
            end
        end
        if not closed then
            return nil
        end
        labels[#labels + 1] = { name, table.concat(value) }
        if pos > n then
            return nil
        end
        if text:sub(pos, pos) == "}" then
            return labels, pos + 1
        end
    end
    return nil
end

-- Suffixes that belong to a histogram/summary family rather than to a metric of
-- their own, and the label the parser treats as part of the sample rather than of
-- the family (openmetrics-parser PrometheusType::get_ignored_labels plus the
-- summary/histogram handlers in prometheus/parsers.rs).
local SAMPLE_SUFFIXES = { "bucket", "count", "sum", "max", "min" }
local VALUE_RE = "^[-+0-9.eE]+$"

---Parse one Prometheus exposition into families.
---
---Family identity follows the declared type where one exists: SGLang writes
---"# TYPE sglang_x histogram" and then samples named sglang_x_bucket/_count/_sum,
---and those have to land in one family rather than three. Sample lines keep their
---own name, label list and value text verbatim, so nothing is re-formatted and a
---histogram stays a histogram on the wire.
---@param text string @ already colon-underscored
---@return table families @ name -> {name, help, type, samples}
---@return string[] order @ first-appearance order
local function parse_prometheus(text)
    local families = {}
    local order = {}
    local declared = {}

    local function family(name)
        local f = families[name]
        if not f then
            f = { name = name, samples = {} }
            families[name] = f
            order[#order + 1] = name
        end
        return f
    end

    for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
        local line = raw
        if line:sub(-1) == "\r" then
            line = line:sub(1, -2)
        end
        if line ~= "" and line:sub(1, 1) == "#" then
            local kind, name, rest = string.match(line,
                "^#%s+(%a+)%s+([%w_]+)%s*(.*)$")
            if kind and name then
                local upper = string.upper(kind)
                if upper == "HELP" or upper == "TYPE" then
                    local f = family(name)
                    declared[name] = true
                    if upper == "HELP" then
                        if f.help == nil then
                            f.help = rest
                        end
                    elseif f.type == nil then
                        f.type = rest
                    end
                end
            end
        elseif line ~= "" then
            local name, after = string.match(line, "^([%w_]+)(.*)$")
            if name then
                local labels = {}
                local tail = after
                if after:sub(1, 1) == "{" then
                    local scanned, next_pos = scan_labels(after, 1)
                    if not scanned then
                        goto continue
                    end
                    labels = scanned
                    tail = after:sub(next_pos or (#after + 1))
                end
                tail = tail:gsub("^%s+", ""):gsub("%s+$", "")
                -- Value or timestamp+value; the first field decides whether the line
                -- is a sample at all.
                local value = string.match(tail, "^(%S+)")
                if not value or not string.match(value, VALUE_RE) then
                    goto continue
                end
                -- A suffixed sample folds into the family that declared the base
                -- name; anything else keeps its own family (a TYPE-less scrape).
                local fname = name
                if not declared[name] then
                    for base in pairs(declared) do
                        if name ~= base and name:sub(1, #base + 1) == base .. "_" then
                            local suffix = name:sub(#base + 2)
                            for i = 1, #SAMPLE_SUFFIXES do
                                if SAMPLE_SUFFIXES[i] == suffix then
                                    fname = base
                                    break
                                end
                            end
                        end
                        if fname ~= name then
                            break
                        end
                    end
                end
                local f = family(fname)
                f.samples[#f.samples + 1] = {
                    name = name,
                    labels = labels,
                    tail = tail,
                }
            end
            ::continue::
        end
    end
    return families, order
end

---Position Rust's with_labels() gives an extra label: binary_search over the
---sample's label names (openmetrics-parser public/model.rs:105-125). Rust searches
---a list that is only sorted when the source happens to sort it, so the insert
---position has to come from the same algorithm rather than from a sorted insert.
---@param names string[]
---@param key string
---@return number @ 1-based insert position
local function label_insert_index(names, key)
    local lo, hi = 1, #names + 1
    while lo < hi do
        local mid = lo + math.floor((hi - lo) / 2)
        if names[mid] < key then
            lo = mid + 1
        else
            hi = mid
        end
    end
    return lo
end

---Render one sample with the aggregator's extra label folded in. Values are
---escaped for the wire (the only two characters that would break the line).
local function render_sample(sample, extra_name, extra_value)
    local labels = sample.labels
    local names = {}
    for i = 1, #labels do
        names[i] = labels[i][1]
    end
    local insert_at = label_insert_index(names, extra_name)
    local parts = {}
    local placed = false
    for i = 1, #labels do
        if not placed and i >= insert_at then
            parts[#parts + 1] = extra_name .. '="' .. extra_value .. '"'
            placed = true
        end
        local value = labels[i][2]:gsub("\\", "\\\\"):gsub('"', '\\"')
        parts[#parts + 1] = labels[i][1] .. '="' .. value .. '"'
    end
    if not placed then
        parts[#parts + 1] = extra_name .. '="' .. extra_value .. '"'
    end
    local text = sample.name
    if #parts > 0 then
        text = text .. "{" .. table.concat(parts, ",") .. "}"
    end
    return text .. " " .. sample.tail
end

---Merge one pack's families into the accumulator, stamping each sample with the
---pack's worker address (Rust stamps the family before merging, so a sample never
---travels without it).
local function merge_pack(acc, acc_order, families, order, label_value)
    for i = 1, #order do
        local name = order[i]
        local incoming = families[name]
        local target = acc[name]
        if not target then
            acc[name] = { name = name, help = incoming.help, type = incoming.type,
                samples = {} }
            acc_order[#acc_order + 1] = name
            target = acc[name]
        end
        if target.help == nil and incoming.help then
            target.help = incoming.help
        end
        if target.type == nil and incoming.type then
            target.type = incoming.type
        end
        for j = 1, #incoming.samples do
            target.samples[#target.samples + 1] = incoming.samples[j]
        end
        -- The stamp travels with the sample list, not the family, because two packs
        -- carry different addresses: keep the address alongside the samples.
        target.pack = target.pack or {}
        target.pack[#target.pack + 1] = {
            label_value = label_value,
            count = #incoming.samples,
            first = #target.samples - #incoming.samples + 1,
        }
    end
end

---Render the merged exposition: one HELP and one TYPE line per family, each sample
---carrying the worker_addr of the pack it came from, families separated by a blank
---line as Rust's Display for MetricsExposition does (model.rs:315-330).
---@param acc table
---@param acc_order string[]
---@return string
local function render_exposition(acc, acc_order)
    local blocks = {}
    for i = 1, #acc_order do
        local f = acc[acc_order[i]]
        local lines = {}
        if f.help and f.help ~= "" then
            lines[#lines + 1] = "# HELP " .. f.name .. " " .. f.help
        end
        if f.type and f.type ~= "" and f.type ~= "unknown" then
            lines[#lines + 1] = "# TYPE " .. f.name .. " " .. f.type
        end
        local stamps = {}
        for p = 1, #(f.pack or {}) do
            local entry = f.pack[p]
            for s = entry.first, entry.first + entry.count - 1 do
                stamps[s] = entry.label_value
            end
        end
        for s = 1, #f.samples do
            lines[#lines + 1] = render_sample(f.samples[s], "worker_addr",
                stamps[s] or "")
        end
        blocks[#blocks + 1] = table.concat(lines, "\n")
    end
    return table.concat(blocks, "\n\n")
end

_M.underscore_colons = underscore_colons
_M.merge_pack = merge_pack
_M.parse_prometheus = parse_prometheus
_M.render_exposition = render_exposition
_M.label_insert_index = label_insert_index

---Fan out a GET to every worker, returning the raw per-worker results.
local function fan_out_get(path, timeout_ms)
    local records = registry.records()
    local out = {}
    for i = 1, #records do
        local status, body = hb.http_get(records[i].url .. path, timeout_ms)
        out[#out + 1] = { worker = records[i].url, status = status or 0, body = body }
    end
    return out
end



---GET /engine_metrics - the workers' Prometheus text, aggregated.
---
---Rust's two error branches are part of the contract (core/worker_manager.rs
---get_engine_metrics plus its IntoResponse): no workers at all and every scrape
---failing both answer 500 with a plain-text reason, never an empty 200. The scrape
---timeout is reqwest's fixed 5s per worker (worker_manager.rs:25 REQUEST_TIMEOUT),
---not health_check_timeout_secs, and a worker's api_key is presented as a bearer
---token exactly as fan_out does.
local function engine_metrics_handler()
    local records = registry.records()
    if #records == 0 then
        return text_response(500, "No available workers")
    end

    local merged, merged_order = {}, {}
    local packs = 0
    for i = 1, #records do
        local record = records[i]
        local headers
        if record.api_key then
            headers = { Authorization = "Bearer " .. record.api_key }
        end
        local status, body = hb.http_get(record.url .. "/metrics", 5000, headers)
        if status and status >= 200 and status < 300 and body and body ~= "" then
            local families, order = parse_prometheus(underscore_colons(body))
            packs = packs + 1
            merge_pack(merged, merged_order, families, order, record.url)
        end
    end

    if packs == 0 then
        return text_response(500, "All backend requests failed")
    end
    return text_response(200, render_exposition(merged, merged_order),
        "text/plain; version=0.0.4; charset=utf-8")
end

local function model_info_handler()
    local merged = {}
    local results = fan_out_get("/model_info", cfg().health_check_timeout_secs * 1000)
    local merged_count = 0
    for i = 1, #results do
        if results[i].status == 200 then
            local decoded = json_decode(results[i].body)
            if type(decoded) == "table" then
                merged_count = merged_count + 1
                merged[merged_count] = decoded
            end
        end
    end
    if merged_count == 0 then
        merged = cjson.empty_array
    end
    return { model_infos = merged }
end

-- ------------------------------------------------------------------ control plane

---POST /workers - queue a registration and answer 202 with a Location header.
local function create_worker_handler(params, ctx, req)
    local body, err = req.get_body(ctx)
    if type(body) ~= "table" then
        return send_error(400, "invalid_json",
            err or "worker config must be a JSON object")
    end
    if type(body.url) ~= "string" or body.url == "" then
        return send_error(400, "invalid_request", "url is required")
    end

    local result, failure, kind = registry.add(body, cfg())
    if not result then
        if kind == "validation" then
            return send_error(400, "invalid_request", failure)
        end
        return send_error(500, "INTERNAL_SERVER_ERROR", failure)
    end
    -- Re-seed the stateful policies in every process: cache_aware / bucket / the
    -- hash rings derive their state from the worker set.
    policy_mod.bump_generation()
    mesh_observe_worker(result.id)

    -- A duplicate URL keeps its id and surfaces only as a failed job, so the
    -- response stays 202 with Location, exactly like the Rust service.
    ngx.header["Location"] = result.location
    return {
        status = "accepted",
        worker_id = result.id,
        url = result.url,
        location = result.location,
        message = "Worker addition queued for background processing",
    }, 202
end

local function list_workers_handler()
    local workers = registry.list()
    local count = #workers
    if count == 0 then
        -- cjson.empty_array is userdata: it encodes as [] but has no length, so
        -- the count is taken before the swap.
        workers = setmetatable({}, cjson.empty_array_mt)
    end
    return {
        workers = workers,
        total = count,
        stats = { prefill_count = 0, decode_count = 0, regular_count = count },
    }
end

local function get_worker_handler(params)
    local worker_id = param_text(params, "worker_id")
    local info, err = registry.get(worker_id)
    if not info then
        local bad_id = err and string.find(err, "Invalid worker_id", 1, true)
        if bad_id then
            return send_error(400, "BAD_REQUEST", err)
        end
        return send_error(404, "WORKER_NOT_FOUND",
            err or ("Worker " .. tostring(worker_id) .. " not found"))
    end
    return info
end

local function delete_worker_handler(params)
    local worker_id = param_text(params, "worker_id")
    local result, err = registry.remove(worker_id)
    if not result then
        if err and string.find(err, "Invalid worker_id", 1, true) then
            return send_error(400, "BAD_REQUEST", err)
        end
        return send_error(404, "WORKER_NOT_FOUND",
            err or ("Worker " .. tostring(worker_id) .. " not found"))
    end
    policy_for(nil):on_remove({ url = result.url })
    policy_mod.bump_generation()
    mesh_forget_worker(result.worker_id)
    return {
        status = "accepted",
        worker_id = result.worker_id,
        message = "Worker removal queued for background processing",
    }, 202
end

---Server-level preflight guard, for `rewrite_by_lua_block`.
---
---ui.conf owns the /_ui/* locations and each of them runs its own axum-style
---method gate (ui.lua method_only), so a preflight reaching one of those blocks
---answers 405 before the CORS code in handle() ever runs. nginx runs the server
---rewrite phase before it picks a location, so calling this there covers every
---path, including the ones the klib dispatcher never sees. Rust gets the same
---coverage for free because its CorsLayer is the outermost layer of the router
---(server.rs:1429), which also means a preflight is never metered and carries no
---x-request-id.
---@return boolean answered @ true when the response is complete
function _M.preflight_guard()
    if ngx.req.get_method() ~= "OPTIONS" then
        -- Not a preflight: still stamp the CORS headers here, because a /_ui/*
        -- request is answered by its own location and handle() never runs.
        cors_apply()
        return false
    end
    cors_apply()
    cors_preflight()
    return true
end

---Read and decode a JSON object body, or answer 400. Rust deserializes the body
---with Json<T>, so malformed JSON and non-object payloads both fail the request.
---@param ctx any
---@param req any
---@return table|nil body, string|nil reason
local function object_body(ctx, req)
    local body, err = req.get_body(ctx)
    if type(body) ~= "table" then
        return nil, err or "request body must be a JSON object"
    end
    return body
end

---PUT /workers/{id} - queue a priority/cost/labels/api_key/health update and
---answer 202. The Rust service (core/worker_service.rs:339 update_worker plus
---UpdateWorkerResult::into_response at :138-146) replies with exactly
---{status,worker_id,message}: unlike POST there is no url key and no Location.
local function update_worker_handler(params, ctx, req)
    local worker_id = param_text(params, "worker_id")
    local body = object_body(ctx, req)
    if not body then
        return send_error(400, "invalid_json",
            "request body must be a JSON object")
    end
    local result, err, kind = registry.update(worker_id, body)
    if not result then
        if kind == "validation" then
            return send_error(400, "BAD_REQUEST", err)
        end
        if kind == "not_found" then
            return send_error(404, "WORKER_NOT_FOUND", err)
        end
        return send_error(500, "INTERNAL_SERVER_ERROR", err)
    end
    -- Scheduling attributes moved, so the stateful policies must re-seed.
    policy_mod.bump_generation()
    mesh_observe_worker(result.worker_id)
    return {
        status = "accepted",
        worker_id = result.worker_id,
        message = "Worker update queued for background processing",
    }, 202
end

---POST /flush_cache - best-effort fan-out to each worker's own /flush_cache.
local function flush_cache_handler()
    local records = registry.records()
    local results = {}
    local all_failed = #records > 0
    for i = 1, #records do
        -- SGLang's /flush_cache is a POST route (the cache is being mutated, not
        -- read), so an HTTP GET there is answered 405 and every worker shows up
        -- as an error. hb.http_request keeps the raw status for the report.
        local status = hb.http_request("POST", records[i].url .. "/flush_cache",
            5000, nil, "{}")
        local ok = status == 200
        if ok then
            all_failed = false
        end
        results[#results + 1] = {
            worker = records[i].url,
            status = status or 0,
            result = ok and "success" or "error",
        }
    end
    return { results = results, success = not all_failed, all_failed = all_failed }
end

---GET /v1/loads - probe each worker's own engine load.
---
---Rust asks every worker for GET {url}/v1/loads?include=core and reads
---aggregate.total_tokens (core/worker_manager.rs parse_load_response), with reqwest's
---fixed 5s timeout and the worker's api_key as a bearer token; anything that does
---not answer that shape becomes -1. The response is WorkerLoadsResult through its
---IntoResponse, which emits only {"workers":[{"worker","load"}]} (a worker_type key
---appears for prefill/decode entries) - sampled on the Rust gateway, the body has no
---counter keys at all. The same three counters Rust computes internally are appended
---here because the lua-router UI reads them; doc/gap-http-semantics.md §4 records
---that as the one intentional superset.
---@param _params table|nil
---@return table|nil doc @ the response body
local function loads_handler()
    local records = registry.records()
    local workers = {}
    local successful, failed = 0, 0
    for i = 1, #records do
        local record = records[i]
        local load = -1
        if (record.connection_mode or "http") == "http" then
            local headers
            if record.api_key then
                headers = { Authorization = "Bearer " .. record.api_key }
            end
            local status, body = hb.http_get(
                record.url .. "/v1/loads?include=core", 5000, headers)
            if status and status >= 200 and status < 300 and body then
                local decoded = json_decode(body)
                if type(decoded) == "table" then
                    local aggregate = decoded.aggregate
                    if type(aggregate) == "table" then
                        load = tonumber(aggregate.total_tokens) or -1
                    end
                end
            end
        end
        if load >= 0 then
            successful = successful + 1
        else
            failed = failed + 1
        end
        workers[#workers + 1] = { worker = record.url, load = load }
    end
    if #workers == 0 then
        workers = cjson.empty_array
    end
    return {
        workers = workers,
        total_workers = #records,
        successful = successful,
        failed = failed,
    }
end

-- ------------------------------------------------------------------ observability

local function metrics_handler()
    return text_response(200, observability.prometheus_text(),
        "text/plain; version=0.0.4; charset=utf-8")
end

---GET /_ui/logs?cursor=&limit= - the ring buffer as JSON, oldest first.
local function ui_logs_handler(params, ctx, req)
    local query = req.get_query()
    local cursor = tonumber(query.cursor) or 0
    local limit = tonumber(query.limit) or 500
    local head, requests = observability.snapshot(cursor, limit)
    if #requests == 0 then
        requests = cjson.empty_array
    end
    return {
        cursor = head,
        capacity = observability.log_capacity(),
        requests = requests,
    }
end

local function ui_stats_handler()
    return observability.stats()
end

---Mirror one worker into the cluster view (doc/gap-mesh.md 4.2). Only the local
---worker's own control-plane events are mirrored here, so a peer sees the same
---worker set the registry has; health/load freshness is whatever the sweep saw last.
---@param id string|nil
mesh_observe_worker = function(id)
    local inst = mesh_mod.instance()
    if not inst or type(id) ~= "string" then
        return false
    end
    local record = registry.get(id)
    if not record then
        return inst:remove_worker(id)
    end
    return inst:observe_worker(id, record, registry.cb_state(id))
end

---Drop a worker from the cluster view.
---@param id string|nil
mesh_forget_worker = function(id)
    local inst = mesh_mod.instance()
    if not inst or type(id) ~= "string" then
        return false
    end
    return inst:remove_worker(id)
end

local function mesh_disabled_handler(params)
    local path = ngx.var.uri or "/"
    local inst = mesh_mod.instance()
    if not inst then
        return text_response(503, '{"error":"mesh not enabled"}',
            "application/json")
    end
    local out = mesh_mod.dispatch(inst, ngx.req.get_method(), path,
        params, { body = mesh_mod.read_body(nil) })
    if out == nil then
        return send_error(404, "not_found",
            "No route for " .. ngx.req.get_method() .. " " .. (ngx.var.uri or "/"))
    end
    if type(out) == "table" then
        -- Non-request phase (unit probe): render what the module returned.
        return text_response(out.status or 200, out.body or "", out.content_type)
    end
    return out
end

---GET /_ui/logs/backends - provider column on the Logs page (port + GPU label).
local function ui_backends_handler()
    local out = {}
    local records = registry.records()
    for i = 1, #records do
        local gpu = (type(records[i].labels) == "table"
            and records[i].labels.gpu) or cjson.null
        out[i] = {
            url = records[i].url,
            model = records[i].model_id,
            gpu = gpu,
        }
    end
    if #out == 0 then
        out = cjson.empty_array
    end
    return { backends = out }
end

-- ------------------------------------------------------------------ request log

---Build and store one RequestRecord for an inference request.
local function log_inference_request(duration_s, ttft_s)
    local worker = ngx.ctx.lr_worker
    local model = ngx.ctx.lr_model
    if not model or not worker then
        return
    end
    local endpoint = ngx.ctx.lr_endpoint or "other"
    local status = ngx.status
    local tokens = ngx.ctx.lr_tokens or {}
    local prompt = tokens[1] or 0
    local completion = tokens[2] or 0
    local cached = tokens[3] or 0
    local estimated = tokens[4] ~= nil and tokens[4] ~= 0
    local reasoning = tokens[5] or 0

    local candidates = {}
    local pool = candidates_for(ngx.ctx.lr_model_query)
    for i = 1, #pool do
        candidates[#candidates + 1] = compact_url(pool[i].url)
    end
    if #candidates == 0 then
        candidates = cjson.empty_array
    end

    local labels = worker.labels or {}
    local decode_ms = duration_s * 1000 - (ttft_s or 0) * 1000
    local record = {
        id = request_id(),
        ts_ms = math.floor((ngx.ctx.lr_started or ngx.now()) * 1000),
        method = ngx.req.get_method(),
        path = ngx.var.uri or "/",
        endpoint = endpoint,
        status = status,
        stream = ngx.ctx.lr_stream == true,
        model = model,
        requested_model = ngx.ctx.lr_requested_model or model,
        requested_effort = ngx.ctx.lr_requested_effort or cjson.null,
        effort = ngx.ctx.lr_effort or cjson.null,
        provider = labels.engine or "sglang",
        worker = compact_url(worker.url),
        route_type = policy_for(model):policy_name(),
        selected = compact_url(worker.url),
        candidates = candidates,
        duration_ms = math.floor(duration_s * 1000),
        ttft_ms = ttft_s and math.floor(ttft_s * 1000) or cjson.null,
        prompt_tokens = prompt,
        cached_tokens = cached,
        completion_tokens = completion,
        reasoning_tokens = reasoning,
        -- Fingerprint computed at route time (router_session_key), where the
        -- request body is still in hand. nil becomes cjson.null so the UI's
        -- session column stays renderable.
        session = ngx.ctx.lr_session or cjson.null,
        tokens_estimated = estimated,
        tok_per_s = (completion > 0 and decode_ms >= 100)
            and (completion / (decode_ms / 1000)) or cjson.null,
        error = (status >= 400) and (STATUS_TEXT[status] or "error") or cjson.null,
    }
    observability.append_request(record)
    observability.note_tokens(prompt, completion, estimated)
    -- /_ui/stats.avg_duration_ms is the mean of the recorded durations, so it is
    -- fed from the same place the record is built. Rust skips duration_ms == 0
    -- rows (request_log.rs:586), which would otherwise pull the average down.
    if record.duration_ms > 0 then
        observability.note_duration(duration_s)
    end
    observability.record_router_tokens(model, endpoint, "prompt", prompt)
    observability.record_router_tokens(model, endpoint, "completion", completion)
end

---Layer-1 accounting plus the request-log row, run once per request whichever
---entry point served it: `location /` goes through handle(), the /_ui chat
---aliases call it directly because ui.conf bypasses the klib dispatcher.
finish_request = function(started, method, path)
    local duration = ngx.now() - started
    -- Span close first: it wants the same `duration` the layer-1 histogram gets,
    -- and it must happen before anything that could error out of this function.
    otel.finish(duration, { method = method, path = path, status = ngx.status })
    -- Hand the concurrency slot back here rather than at the end of the handler:
    -- every entry point (handle, the /_ui aliases, early error returns) funnels
    -- through this function, and it is the only place that knows the response was
    -- fully written.
    limit().release()
    -- And the in-flight age slot with it: the request is no longer in flight the
    -- moment the response is written, so it must stop aging (Rust drops the
    -- InFlightGuard at the same point, middleware.rs:936). init.lua's log hook
    -- covers the paths that never reach here.
    observability.inflight_untrack()
    observability.record_http_duration(method, path, duration)
    observability.record_http_response(ngx.status,
        ngx.header["X-SMG-Error-Code"] or "")
    observability.inflight_add(-1)
    if ngx.ctx.lr_endpoint then
        -- Layer-2 duration, recorded only for a request that actually reached a
        -- worker and came back 2xx: routers/http/router.rs:249-251 gates
        -- record_router_duration on response.status().is_success(), and errors go
        -- to smg_router_request_errors_total instead (already counted in forward).
        if ngx.ctx.lr_worker and ngx.status >= 200 and ngx.status < 300 then
            observability.record_router_duration(ngx.ctx.lr_model or "unknown",
                ngx.ctx.lr_endpoint, duration)
        end
        log_inference_request(duration, ngx.ctx.lr_ttft)
    end
end
_M.finish_request = finish_request

-- ------------------------------------------------------------------ route table

local instance

local function build()
    local app = router_class.new("/")

    -- Inference plane. Each route closes over its own upstream path because a
    -- static klib.router rule hands the handler an empty params table.
    local inference_routes = {
        "/v1/chat/completions", "/v1/completions", "/v1/embeddings",
        "/v1/rerank", "/v1/classify", "/v1/responses", "/generate",
    }
    for i = 1, #inference_routes do
        local route = inference_routes[i]
        local rule = route:sub(2)
        app:post(rule, function()
            return inference_handler({ route = route })
        end)
    end

    -- Endpoints the Rust gateway serves but this router does not implement.
    -- Registered per path section because a klib.router `:param` matches exactly
    -- one segment; the list mirrors the axum table in server.rs:1279-1364 so the
    -- two gateways answer 501 for the same set instead of leaking 404.
    local not_implemented_routes = {
        { "POST", "wasm" },
        { "GET", "wasm" },
        { "DELETE", "wasm/:module_uuid" },
    }
    for i = 1, #not_implemented_routes do
        app:register(not_implemented_routes[i][2], not_implemented_handler,
            not_implemented_routes[i][1])
    end

    -- Public plane.
    app:get("health", health_handler)
    app:get("liveness", health_handler)
    app:get("readiness", exact_json(readiness_handler))
    app:get("v1/models", exact_json(models_handler))
    app:get("model_info", exact_json(model_info_handler))
    app:get("get_model_info", exact_json(model_info_handler))
    app:get("server_info", exact_json(server_info_handler))
    app:get("get_server_info", exact_json(server_info_handler))
    -- axum's get() also answers HEAD on every read-only GET route; klib.router
    -- matches the method literally, so mirror the registrations (nginx strips the
    -- HEAD body on its own).
    app:head("health", health_handler)
    app:head("liveness", health_handler)
    app:head("readiness", exact_json(readiness_handler))
    app:head("v1/models", exact_json(models_handler))
    app:head("model_info", exact_json(model_info_handler))
    app:head("get_model_info", exact_json(model_info_handler))
    app:head("server_info", exact_json(server_info_handler))
    app:head("get_server_info", exact_json(server_info_handler))
    app:head("engine_metrics", engine_metrics_handler)
    app:head("metrics", metrics_handler)
    -- Rust answers this from RouterManager::health_generate (routers/
    -- router_manager.rs:407): plain text, 200 when any worker is healthy and 503
    -- with a different sentence when none is - not a 501, and not an error body.
    app:get("health_generate", health_generate_handler)
    app:head("health_generate", health_generate_handler)
    app:get("engine_metrics", engine_metrics_handler)
    app:get("metrics", metrics_handler)

    -- Control plane.
    app:post("workers", exact_json(create_worker_handler))
    app:get("workers", exact_json(list_workers_handler))
    app:head("workers", exact_json(list_workers_handler))
    app:get("workers/:worker_id", exact_json(get_worker_handler))
    app:head("workers/:worker_id", exact_json(get_worker_handler))
    app:put("workers/:worker_id", exact_json(update_worker_handler))
    app:delete("workers/:worker_id", delete_worker_handler)
    app:post("flush_cache", exact_json(flush_cache_handler))
    app:get("v1/loads", exact_json(loads_handler))
    app:get("get_loads", exact_json(loads_handler))
    app:head("v1/loads", exact_json(loads_handler))
    app:head("get_loads", exact_json(loads_handler))

    -- Mesh / HA. mesh.ROUTES carries the Rust /ha table plus the internal peer
    -- endpoints and ha/stats, so registering the module's own table keeps the two
    -- implementations on one list (doc/gap-mesh.md §4.1). With no peers the same
    -- handler answers the pre-mesh fixed 503, byte-identical to the old contract.
    for i = 1, #mesh_mod.ROUTES do
        local r = mesh_mod.ROUTES[i]
        app:register(r.path, mesh_disabled_handler, r.method)
    end

    -- Observability reads owned by this module; /_ui/config and the chat page are
    -- the UI agent's routes.
    app:get("_ui/logs", ui_logs_handler)
    app:get("_ui/stats", ui_stats_handler)
    app:get("_ui/logs/backends", ui_backends_handler)

    app:error_handle(404, function(ctx)
        -- Anchored prefixes (string.find with plain=true has no "^" magic, so the
        -- match is done on the leading slice instead).
        if ctx.uri:sub(1, 4) == "/ha/" or ctx.uri == "/ha"
            or ctx.uri:sub(1, 16) == "/_mesh/internal/" then
            return mesh_disabled_handler()
        end
        return send_error(404, "not_found",
            "No route for " .. ctx.method .. " " .. ctx.request_uri)
    end)
    app:error_handle(500, function(ctx, status, err)
        ngx.log(ngx.ERR, "luarouter: handler error: ", tostring(err))
        return send_error(500, "internal_error", tostring(err))
    end)
    return app
end

_M.handle = function()
    if not instance then
        instance = build()
    end
    local started = ngx.now()
    ngx.ctx.lr_started = started
    local method = ngx.req.get_method()
    local path = ngx.var.uri or "/"
    observability.record_http_request(method, path)
    begin_trace()
    -- A route that opens no span (health, /workers, the control plane) has no
    -- context of its own, so the caller's valid traceparent is echoed back unchanged
    -- rather than a random id that no collector would ever have a span for.
    otel.echo_request_traceparent()
    -- The Rust gateway stamps x-request-id in its middleware, so the header is
    -- on every response, including the ones this router answers itself (health,
    -- models, error bodies). Proxied responses re-apply the same cached value.
    ngx.header["X-Request-Id"] = request_id()
    -- The CorsLayer sits outside the (now removed) auth route_layer in Rust, so a preflight
    -- never carries credentials far enough to be rejected: short-circuit first.
    cors_apply()
    if method == "OPTIONS" then
        cors_preflight()
        finish_request(started, method, path)
        return
    end
    instance:handle({})
    finish_request(started, method, path)
end

-- Exported for the unit probes in test/conf.
_M.build = build
_M.health_handler = health_handler
_M.readiness_handler = readiness_handler
_M.models_handler = models_handler
_M.server_info_handler = server_info_handler
_M.create_worker_handler = create_worker_handler
_M.list_workers_handler = list_workers_handler
_M.get_worker_handler = get_worker_handler
_M.delete_worker_handler = delete_worker_handler
_M.update_worker_handler = update_worker_handler
_M.inference_handler = inference_handler
_M.route_inference = route_inference
_M.apply_effort_policy = apply_effort_policy
_M.apply_ctx_cap = apply_ctx_cap
_M.forward = forward
_M.stream_response = stream_response
_M.request_id = request_id
_M.generate_request_id = generate_request_id
_M.send_error = send_error
_M.error_body = error_body
_M.log_inference_request = log_inference_request
_M.hold_load = hold_load
_M.release_load = release_load
_M.metrics_handler = metrics_handler
_M.cors_apply = cors_apply
_M.cors_preflight = cors_preflight
_M.mesh_disabled_handler = mesh_disabled_handler
_M.mesh_observe_worker = mesh_observe_worker
_M.mesh_forget_worker = mesh_forget_worker
_M.ui_logs_handler = ui_logs_handler
_M.ui_stats_handler = ui_stats_handler
_M.text_response = text_response

return _M
