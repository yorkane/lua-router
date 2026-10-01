-- Parser surface: POST /parse/function_call and POST /parse/reasoning.
--
-- The Rust gateway answers these locally: it keeps a pooled tool_parser /
-- reasoning_parser factory in AppContext and runs the parser in-process
-- (gateway/src/routers/parse/handlers.rs). The Lua router ships no parsers, so it
-- proxies the same request to a worker that advertises the parser it was
-- registered with -- the equivalent surface, not the identical mechanism. The
-- client-visible differences are listed in doc/gap-tokenizer-parse.md.
--
-- Capability comes from the two WorkerSpec fields the gateway also accepts on
-- POST /workers (openai-protocol worker_spec.rs) and their label equivalents:
--   record.tool_parser      / labels.tool_parser
--   record.reasoning_parser / labels.reasoning_parser
--
-- Response shapes stay Rust's: success bodies are
--   {"remaining_text","tool_calls","success":true}
--   {"normal_text","reasoning_text","success":true}
-- and parse errors are {"error":<message>,"success":false}. That error shape is
-- NOT router.lua's error_body shape -- it is Rust's choice in
-- parse::error_response, reproduced here rather than "fixed". The validation
-- failures that Rust reaches through axum's Json extractor go through
-- router.lua's error_body style instead, because this router reads the body
-- itself; both shapes are documented per status in the doc.

local cjson = require "cjson.safe"

local _M = { _VERSION = "0.1.0" }

local json_encode = cjson.encode
local json_decode = cjson.decode

_M.proxy_timeout_ms = 15000

function _M.configure(opts)
    if type(opts) ~= "table" then
        return _M
    end
    if tonumber(opts.proxy_timeout_ms) then
        _M.proxy_timeout_ms = tonumber(opts.proxy_timeout_ms)
    end
    return _M
end

-- ------------------------------------------------------------------ responses

local STATUS_TEXT = {
    [400] = "Bad Request", [401] = "Unauthorized", [404] = "Not Found",
    [409] = "Conflict", [500] = "Internal Server Error",
    [502] = "Bad Gateway", [503] = "Service Unavailable",
    [504] = "Gateway Timeout",
}

---Writer seam; tests replace it. Exact Content-Length, as router.lua does.
---@param status number
---@param body string|nil
---@param content_type string|nil
---@param headers table|nil
---@return string @ '' so klib.router prints nothing of its own
function _M.write_raw(status, body, content_type, headers)
    ngx.status = status
    if content_type then
        ngx.header["Content-Type"] = content_type
    end
    if headers then
        for name, value in pairs(headers) do
            ngx.header[name] = value
        end
    end
    if body and body ~= "" then
        ngx.header["Content-Length"] = tostring(#body)
        ngx.print(body)
    end
    return ""
end

---@param result table
---@param status number|nil
---@return string
function _M.write_json(result, status)
    local text, err = json_encode(result)
    if not text then
        return _M.parser_error(500, "failed to encode response: " .. tostring(err))
    end
    return _M.write_raw(status or 200, text, "application/json")
end

---Rust's parse error body: {"error": message, "success": false}.
---@param status number
---@param message string
---@return string
function _M.parser_error(status, message)
    return _M.write_raw(status, json_encode({ error = message, success = false }),
        "application/json")
end

---router.lua's error_body shape, for the cases Rust answers through axum's
---extractor (a body that is not a JSON object).
---@param status number
---@param code string
---@param message string
---@return string
function _M.send_error(status, code, message)
    local body = json_encode({
        error = {
            ["type"] = STATUS_TEXT[status] or "Unknown Status Code",
            code = code,
            message = message,
        },
    })
    return _M.write_raw(status, body, "application/json",
        { ["X-SMG-Error-Code"] = code })
end

-- ------------------------------------------------------------------ auth
--
-- Rust's posture (gateway/src/server.rs): /v1/tokenize and /v1/detokenize sit in
-- protected_routes behind the data-plane api key, while /v1/tokenizers*,
-- /parse/function_call and /parse/reasoning sit in admin_routes behind the
-- control-plane key. The key comparison lives in router.lua, so it is reached
-- through this seam instead of being duplicated here. Resolution order:
--   1. _M.auth_checks, injected by the caller (router.lua's build() can pass its
--      own functions) -- the only form that works while router.lua is mid-load
--   2. package.loaded["resty.luarouter.router"], i.e. the already-loaded module
--   3. a lazy require, for a conf that mounts these handlers without router.lua
--      (then auth is the location's job, and the require must not be circular)
-- When none resolve, the check is a no-op rather than a silent 401.

---@param kind string @ "data" or "control"
---@return boolean @ true when the request may proceed
function _M.authorize(kind)
    local checks = _M.auth_checks
    local check = type(checks) == "table"
        and (kind == "control" and checks.control or checks.data) or nil
    if check == nil then
        local loaded = package.loaded["resty.luarouter.router"]
        if type(loaded) == "table" then
            check = kind == "control" and loaded.check_control_auth
                or loaded.check_data_auth
        end
    end
    if check == nil then
        local ok, router = pcall(require, "resty.luarouter.router")
        if ok and type(router) == "table" then
            check = kind == "control" and router.check_control_auth
                or router.check_data_auth
        end
    end
    if type(check) ~= "function" then
        return true
    end
    return check() and true or false
end

-- ------------------------------------------------------------------ request

---@return string @ original bytes, forwarded verbatim
function _M.raw_body()
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
    return raw or ""
end

function _M.decode_json(raw)
    local decoded = json_decode(raw)
    if type(decoded) ~= "table" then
        return nil
    end
    return decoded
end

local FORWARD_HEADERS = {
    ["authorization"] = true, ["x-request-id"] = true,
    ["x-correlation-id"] = true, traceparent = true, tracestate = true,
    ["x-smg-routing-key"] = true,
}
local FORWARD_PREFIX = "x-request-id-"

function _M.should_forward(name)
    local lower = string.lower(name)
    if FORWARD_HEADERS[lower] then
        return true
    end
    return #lower >= #FORWARD_PREFIX
        and string.lower(lower:sub(1, #FORWARD_PREFIX)) == FORWARD_PREFIX
end

---Incoming request headers seam (unit tests feed a table through this).
---@return table
function _M.incoming_headers()
    local ok, incoming = pcall(ngx.req.get_headers)
    if not ok then
        return {}
    end
    return incoming or {}
end

---@param worker table|nil
---@return table @ lowercase headers
function _M.forward_headers(worker)
    local out = {}
    local incoming = _M.incoming_headers()
    if type(incoming) == "table" then
        for name, value in pairs(incoming) do
            if type(name) == "string" and type(value) == "string"
                and _M.should_forward(name) then
                out[string.lower(name)] = value
            end
        end
    end
    out["content-type"] = out["content-type"] or "application/json"
    out["accept"] = out["accept"] or "application/json"
    out["accept-encoding"] = "identity"
    if worker and worker.api_key and not out["authorization"] then
        out["authorization"] = "Bearer " .. worker.api_key
    end
    return out
end

-- ------------------------------------------------------------------ upstream

---HTTP client seam (the same single client tokenizer.lua uses, via config_store).
---@return number|nil status, table|nil headers, string|nil body, string|nil err
function _M.request(method, url, body, headers, timeout_ms)
    local ok, store = pcall(require, "resty.luarouter.config_store")
    if not ok or type(store.raw_request) ~= "function" then
        return nil, nil, nil, "no HTTP client available"
    end
    local status, resp_headers, resp_body =
        store.raw_request(method, url, body, headers, timeout_ms)
    if not status then
        return nil, nil, nil, tostring(resp_headers or resp_body or "request failed")
    end
    return status, resp_headers or {}, resp_body or ""
end

-- ------------------------------------------------------------------ workers

---@return table[] @ selectable registry records
function _M.worker_records()
    local ok, registry = pcall(require, "resty.luarouter.registry")
    if not ok then
        return {}
    end
    local records = registry.records() or {}
    local out = {}
    for i = 1, #records do
        if registry.is_available(records[i].id) then
            out[#out + 1] = records[i]
        end
    end
    return out
end

---Parser name a worker advertises for a field, or nil.
---
---Reads the WorkerSpec-shaped field first (POST /workers and the discovery patch
---store it verbatim), then the label form. "true"/"yes"/"1" means "has a parser,
---name unstated", which still makes the worker a fallback candidate.
---@param record table
---@param field string @ "tool_parser" or "reasoning_parser"
---@return string|nil name @ "*" when unqualified
function _M.parser_claim(record, field)
    local direct = record[field]
    if type(direct) == "string" and direct ~= "" then
        return direct
    end
    local labels = type(record.labels) == "table" and record.labels or {}
    local value = labels[field]
    if type(value) ~= "string" and tonumber(value) then
        value = tostring(value)
    end
    if type(value) == "string" and value ~= "" then
        if value == "true" or value == "yes" or value == "1" then
            return "*"
        end
        return value
    end
    return nil
end

---Ranked parser candidates for one field and parser name. Higher is better, and
---the tiers are separated enough that a later bonus never outranks an earlier
---one: exact parser name (+4) > serves the requested model (+2) > unqualified
---claim (+1) > a differently named parser (0).
---@param field string @ "tool_parser" or "reasoning_parser"
---@param parser string|nil @ requested parser name
---@param model string|nil @ requested model, for the igw-style narrowing
---@return table[] @ {record, name, score}, score descending
function _M.parser_candidates(field, parser, model)
    local records = _M.worker_records()
    local ranked = {}
    for i = 1, #records do
        local record = records[i]
        local claim = _M.parser_claim(record, field)
        if claim then
            local score = 0
            if parser and parser ~= "" and claim == parser then
                score = score + 4
            end
            if model and record.model_id == model then
                score = score + 2
            end
            if claim == "*" then
                score = score + 1
            end
            ranked[#ranked + 1] = { record = record, name = claim, score = score }
        end
    end
    table.sort(ranked, function(a, b) return a.score > b.score end)
    return ranked
end

---Random pick among the highest-scoring entries whose claim equals `wanted`.
---@param ranked table[] @ parser_candidates() output
---@param wanted string
---@return table|nil entry
local function best_for(ranked, wanted)
    local best, top
    for i = 1, #ranked do
        if ranked[i].name == wanted
            and ((not top) or ranked[i].score > top) then
            top = ranked[i].score
            best = ranked[i]
        end
    end
    if not best then
        return nil
    end
    local tier = {}
    for i = 1, #ranked do
        if ranked[i].name == wanted and ranked[i].score == top then
            tier[#tier + 1] = ranked[i]
        end
    end
    return tier[math.random(#tier)]
end

---Random pick among the highest-scoring entries overall.
---@param ranked table[]
---@return table entry
local function best_overall(ranked)
    local top, tier
    for i = 1, #ranked do
        if (not top) or ranked[i].score > top then
            top = ranked[i].score
            tier = {}
        end
        if ranked[i].score == top then
            tier[#tier + 1] = ranked[i]
        end
    end
    return tier[math.random(#tier)]
end

---Pick the worker that should answer a parse request. A requested parser that no
---worker claims is reported separately (unknown_parser) so the handler can answer
---400 the way Rust does for an unknown parser, while "no parser anywhere" is the
---503 the Rust gateway gives when its factory was never initialised.
---@param field string
---@param parser string|nil
---@param model string|nil
---@return table|nil record
---@return table @ {claim, candidates, unknown_parser}
function _M.pick_parser_worker(field, parser, model)
    local ranked = _M.parser_candidates(field, parser, model)
    if #ranked == 0 then
        return nil, { candidates = ranked }
    end
    if parser and parser ~= "" then
        local chosen = best_for(ranked, parser)
        if not chosen then
            -- Unqualified claims ("*") can serve any parser name: the worker owns
            -- the final lookup and answers 400 itself if it disagrees.
            chosen = best_for(ranked, "*")
        end
        if not chosen then
            return nil, { candidates = ranked, unknown_parser = true }
        end
        return chosen.record, { claim = chosen.name, candidates = ranked }
    end
    local any = best_overall(ranked)
    return any.record, { claim = any.name, candidates = ranked }
end

-- ------------------------------------------------------------------ proxy

---Forward the request bytes to a worker's same path and pass its answer through.
---@param worker table @ registry record
---@param path string
---@param raw string @ original request bytes
---@return table|nil response @ {status, body, content_type}
---@return string|nil err
function _M.proxy_post(worker, path, raw)
    local status, headers, body, err = _M.request("POST",
        worker.url .. path, raw, _M.forward_headers(worker), _M.proxy_timeout_ms)
    if not status then
        return nil, err or "parser backend request failed"
    end
    return {
        status = status,
        body = body or "",
        content_type = headers and headers["content-type"] or "application/json",
    }
end

---@param response table @ {status, body, content_type}
---@return string
function _M.write_proxy(response)
    if response.status == 200 then
        return _M.write_raw(200, response.body,
            response.content_type or "application/json")
    end
    local parsed = _M.decode_json(response.body)
    if type(parsed) == "table" and parsed.error ~= nil then
        -- The worker already speaks the parse error shape, so forward it verbatim
        -- and let the client read one message instead of two layers of wrapping.
        return _M.write_raw(response.status, response.body,
            response.content_type or "application/json")
    end
    return _M.parser_error(response.status,
        string.format("parser backend said %d: %s", response.status,
            response.body ~= "" and response.body or "no body"))
end

-- ------------------------------------------------------------------ validation

---Shared entry path for both handlers: body check, text check, parser claim.
---
---The request field and the capability field have different names on purpose:
---Rust's request body is `tool_call_parser` (openai-protocol parser.rs) while the
---worker/capability field is `tool_parser` (openai-protocol worker_spec.rs), so
---`request_field` and `field` are passed separately.
---@param params table
---@param ctx any
---@param req any
---@param path string @ "/parse/function_call" or "/parse/reasoning"
---@param field string @ "tool_parser" or "reasoning_parser" (worker capability)
---@param request_field string|nil @ body key the client uses (defaults to `field`)
---@param parser_kind string|nil @ "tool" or "reasoning", for Rust's message wording
---@return string @ written response
function _M.dispatch(params, ctx, req, path, field, request_field, parser_kind)
    if not _M.authorize("control") then
        return ""
    end
    request_field = request_field or field
    parser_kind = parser_kind or (field == "tool_parser" and "tool" or "reasoning")
    local raw = _M.raw_body()
    local body = _M.decode_json(raw)
    if not body then
        -- Rust: axum's Json extractor answers 422 for a body that will not
        -- deserialise; router.lua's error shape carries that case here.
        return _M.send_error(400, "invalid_json",
            "request body must be a JSON object")
    end
    if type(body.text) ~= "string" then
        return _M.send_error(400, "invalid_request",
            "text is required and must be a string")
    end
    local parser = body[request_field]
    if type(parser) ~= "string" or parser == "" then
        return _M.send_error(400, "invalid_request",
            request_field .. " is required and must be a string")
    end

    local worker, picked = _M.pick_parser_worker(field, parser,
        type(body.model) == "string" and body.model or nil)
    if not worker then
        if picked and picked.unknown_parser then
            local names = {}
            for i = 1, #picked.candidates do
                names[i] = picked.candidates[i].name
            end
            -- Rust's wording is "Unknown tool parser: <name>"; the worker list is
            -- appended because here the answer is a routing outcome, not a registry
            -- lookup, so a client needs to know what the fleet actually has.
            return _M.parser_error(400, string.format(
                "Unknown %s parser: %s (workers advertise: %s)", parser_kind, parser,
                table.concat(names, ", ")))
        end
        return _M.parser_error(503, string.format(
            "%s factory not initialized",
            field == "tool_parser" and "Tool parser" or "Reasoning parser"))
    end

    local response, err = _M.proxy_post(worker, path, raw)
    if not response then
        return _M.parser_error(503, "parser backend " .. tostring(worker.url)
            .. " failed: " .. tostring(err))
    end
    return _M.write_proxy(response)
end

---POST /parse/function_call
function _M.handle_function_call(params, ctx, req)
    return _M.dispatch(params, ctx, req, "/parse/function_call", "tool_parser",
        "tool_call_parser", "tool")
end

---POST /parse/reasoning
function _M.handle_reasoning(params, ctx, req)
    return _M.dispatch(params, ctx, req, "/parse/reasoning", "reasoning_parser",
        "reasoning_parser", "reasoning")
end

return _M
