-- Tokenizer surface: /v1/tokenize, /v1/detokenize and the /v1/tokenizers
-- management API.
--
-- Strategy (deliberate, see doc/gap-tokenizer-parse.md): the Lua router does
-- not own a BPE implementation and will not grow one. Everything that needs
-- real token ids is proxied to a worker that advertises a tokenizer, and the
-- management API is a shared-dict job store that tracks which tokenizer names
-- have (or have not) been claimed by a backend.
--
-- Contract references (gateway side, read at authoring time):
--   * gateway/src/routers/tokenize/handlers.rs   202/409/503 shapes, 404 shapes,
--     get-by-id-then-name, status falls back to the job queue
--   * ~/.cargo/.../openai-protocol-1.0.0/src/tokenize.rs  request/response schemas
--     (StringOrArray, TokensInput untagged single/batch, vocab_size skipped when None)
--   * gateway/src/routers/error.rs               {"error":{"type","code","message"}}
--     plus X-SMG-Error-Code, which is the shape router.lua's error_body emits
--
-- Handler convention matches router.lua: a handler writes its own response and
-- returns '' once written, so klib.router never falls through to its chunked
-- print path. Every side-effecting primitive (body read, headers, worker list,
-- upstream request, response writer) sits behind a `_M.*` seam so the unit suite
-- can replace it without an ngx runtime.

local cjson = require "cjson.safe"

local _M = { _VERSION = "0.1.0" }

local json_encode = cjson.encode
local json_decode = cjson.decode

-- ------------------------------------------------------------------ storage
-- Reuses lr_workers (registry's dict) under a `tok:` prefix, so no new
-- lua_shared_dict directive is needed: the prefixes registry.lua owns are
-- w:/hl:/hf:/hs:/cbs:/cbf:/cbu:/cbo:/lo:/url:/u:/job:/disc:/ids, none of which
-- collide. Tokenizer jobs are tiny JSON documents, so 2m is plenty.
local DICT_NAME = "lr_workers"
local K_JOB = "tok:job:"   -- id -> job JSON
local K_NAME = "tok:name:" -- tokenizer name -> id
local K_IDS = "tok:ids"    -- comma-joined id index
local JOB_TTL_SECS = 86400

local UUID_RE = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

-- Tunables. Kept as module fields rather than environment variables on purpose:
-- the conf files that declare `env` directives are outside this module's scope,
-- and an undeclared variable is already gone from os.getenv by the time the
-- first request loads this module (post-fork). Use _M.configure() from an
-- init hook to override, or set the fields directly.
_M.pending_grace_secs = 5     -- pending -> processing
_M.stale_secs = 120           -- processing -> failed with no backend
_M.proxy_timeout_ms = 15000   -- upstream budget for tokenize/detokenize

function _M.configure(opts)
    if type(opts) ~= "table" then
        return _M
    end
    if tonumber(opts.pending_grace_secs) then
        _M.pending_grace_secs = tonumber(opts.pending_grace_secs)
    end
    if tonumber(opts.stale_secs) then
        _M.stale_secs = tonumber(opts.stale_secs)
    end
    if tonumber(opts.proxy_timeout_ms) then
        _M.proxy_timeout_ms = tonumber(opts.proxy_timeout_ms)
    end
    return _M
end

-- ------------------------------------------------------------------ responses

local STATUS_TEXT = {
    [400] = "Bad Request", [401] = "Unauthorized", [404] = "Not Found",
    [405] = "Method Not Allowed", [409] = "Conflict",
    [500] = "Internal Server Error", [501] = "Not Implemented",
    [502] = "Bad Gateway", [503] = "Service Unavailable",
    [504] = "Gateway Timeout",
}

-- --------------------------------------------------------------- writer seam

---Write one response with an exact Content-Length (axum behaviour, copied by
---router.lua's set_content_length). Tests replace this single function.
---@param status number
---@param body string|nil
---@param content_type string|nil
---@param headers table|nil @ extra response headers
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
---@param status number|nil @ defaults to 200
---@return string
function _M.write_json(result, status)
    local text, err = json_encode(result)
    if not text then
        return _M.send_error(500, "internal_error",
            "failed to encode response: " .. tostring(err))
    end
    return _M.write_raw(status or 200, text, "application/json")
end

---Error body in router.lua's shape (error.type/code/message + X-SMG-Error-Code).
---@return string|nil body
function _M.error_body(status, code, message)
    return json_encode({
        error = {
            ["type"] = STATUS_TEXT[status] or "Unknown Status Code",
            code = code,
            message = message,
        },
    }), { ["X-SMG-Error-Code"] = code }
end

---@param status number
---@param code string
---@param message string
---@return string
function _M.send_error(status, code, message)
    local body, headers = _M.error_body(status, code, message)
    return _M.write_raw(status, body, "application/json", headers)
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

---Raw request bytes. Proxied verbatim so the worker sees the caller's own JSON
---(cjson cannot tell [] from {}, so re-encoding would corrupt "tools":[]).
---@return string
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

---Request headers worth forwarding (same whitelist as router.lua's
---should_forward_request_header, copied because requiring router.lua from here
---would close a require cycle).
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

---@return table @ lowercase header map to send upstream
---Incoming request headers seam (unit tests feed a table through this).
---@return table
function _M.incoming_headers()
    local ok, incoming = pcall(ngx.req.get_headers)
    if not ok then
        return {}
    end
    return incoming or {}
end

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

---HTTP client seam. Default reuses config_store.raw_request (resty.http when the
---image ships it, raw cosocket otherwise) so there is exactly one hand-written
---client in this tree.
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

---@return table[] @ raw registry records for selectable workers
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

---Tokenizer name a worker claims to serve, or nil.
---
---Surfaces, in priority order: the WorkerSpec field copied onto the record
---(tokenizer_path), then the labels the Rust discovery step writes
---(labels.tokenizer_path) and the operator-set equivalents (labels.tokenizer /
---tokenizer_id). A label value of "true"/"yes"/"1" claims support without naming
---the tokenizer, which still makes the worker a fallback candidate.
---@param record table
---@return string|nil name @ claimed tokenizer name ("*" when unqualified)
function _M.tokenizer_claim(record)
    local direct = record.tokenizer_path
    if type(direct) == "string" and direct ~= "" then
        return direct
    end
    local labels = type(record.labels) == "table" and record.labels or {}
    for _, key in ipairs({ "tokenizer_path", "tokenizer", "tokenizer_id" }) do
        local value = labels[key]
        if type(value) == "string" and value ~= "" then
            if value == "true" or value == "yes" or value == "1" then
                return "*"
            end
            return value
        end
    end
    return nil
end

---Vocabulary size a worker advertises for its tokenizer, when it says.
---@param record table
---@return number|nil
function _M.vocab_size_for(record)
    local labels = type(record.labels) == "table" and record.labels or {}
    for _, key in ipairs({ "vocab_size", "tokenizer_vocab_size" }) do
        local value = tonumber(labels[key])
        if value then
            return value
        end
    end
    return tonumber(record.vocab_size)
end

---Workers bound to a tokenizer by a management job whose source is a worker URL.
---That is how an operator attaches a tokenizer name to a backend without setting
---labels (the Lua router cannot load a tokenizer from a path).
---@param records table[] @ candidate records
---@param jobs table[] @ settled jobs
---@return table<string, table[]> @ worker url -> { {name, exact}, ... }
function _M.bound_backends(records, jobs)
    local by_url = {}
    for i = 1, #jobs do
        local job = jobs[i]
        if job.status ~= "failed" and type(job.source) == "string"
            and string.find(job.source, "^https?://", 1) then
            for r = 1, #records do
                if records[r].url == job.source then
                    local list = by_url[records[r].url]
                    if not list then
                        list = {}
                        by_url[records[r].url] = list
                    end
                    list[#list + 1] = {
                        name = job.name,
                        exact = (job.name == records[r].model_id),
                    }
                end
            end
        end
    end
    return by_url
end

---Ranked tokenizer candidates for a model, highest tier first.
---  score 2 = a backend claims exactly the requested tokenizer name
---  score 1 = a backend claims some tokenizer (unqualified or a different name)
---@param model string|nil
---@return table[] @ {record, name, score}
function _M.tokenizer_candidates(model)
    local wanted = model
    if type(wanted) ~= "string" or wanted == "" or wanted == "unknown" then
        wanted = nil
    end
    local records = _M.worker_records()
    local bounds = _M.bound_backends(records, _M.list_jobs())
    local ranked = {}
    for i = 1, #records do
        local record = records[i]
        local claim = _M.tokenizer_claim(record)
        local bound = bounds[record.url]
        if claim or bound then
            local name = claim
            local score = 1
            if name == "*" or not name then
                if bound and bound[1] then
                    name = bound[1].name
                end
            end
            if wanted then
                if name == wanted then
                    score = 2
                elseif bound then
                    for b = 1, #bound do
                        if bound[b].name == wanted then
                            score = 2
                            name = wanted
                            break
                        end
                    end
                end
            end
            ranked[#ranked + 1] = { record = record, name = name, score = score }
        end
    end
    -- Stable order within a tier keeps the random pick reproducible in tests.
    table.sort(ranked, function(a, b) return a.score > b.score end)
    return ranked
end

---Choose the tokenizer backend for a request, at random inside the top tier
---(the router's default policy is `random`, so two calls balance across peers).
---@param model string|nil
---@return table|nil record
---@return string|nil name @ tokenizer name the backend claims
function _M.pick_tokenizer_worker(model)
    local ranked = _M.tokenizer_candidates(model)
    if #ranked == 0 then
        return nil
    end
    local tier = {}
    local top = ranked[1].score
    for i = 1, #ranked do
        if ranked[i].score == top then
            tier[#tier + 1] = ranked[i]
        end
    end
    local chosen = tier[math.random(#tier)]
    return chosen.record, chosen.name
end

-- ------------------------------------------------------------------ proxy

---Forward one POST to a worker's same-named path and hand the caller the exact
---upstream answer.
---@param worker table @ registry record
---@param path string @ request path, used unchanged on the worker
---@param raw string @ original request bytes
---@return table|nil response @ {status, body, content_type}
---@return string|nil err
function _M.proxy_post(worker, path, raw)
    local status, headers, body, err = _M.request("POST",
        worker.url .. path, raw, _M.forward_headers(worker), _M.proxy_timeout_ms)
    if not status then
        return nil, err or "tokenizer backend request failed"
    end
    return {
        status = status,
        body = body or "",
        content_type = headers and headers["content-type"] or "application/json",
    }, nil
end

---Answer with a proxied upstream response, passing bytes and status through.
---@param response table @ {status, body, content_type}
---@return string
function _M.write_proxy(response)
    local body = response.body or ""
    if response.status == 200 then
        -- Pass the worker's bytes through untouched; only the framing is ours.
        return _M.write_raw(200, body, response.content_type or "application/json")
    end
    -- Non-2xx: the worker owns the message, so forward it verbatim and keep the
    -- router's error-code header as a hint for the dashboards.
    return _M.write_raw(response.status, body ~= "" and body or nil,
        response.content_type or "application/json",
        { ["X-SMG-Error-Code"] = "backend_error" })
end

-- ------------------------------------------------------------------ validation

local function is_string_array(value)
    if type(value) ~= "table" then
        return false
    end
    for i = 1, #value do
        if type(value[i]) ~= "string" then
            return false
        end
    end
    return true
end

local U32_MAX = 4294967295

---Token input shape: array of integers, or array of arrays of integers.
---@param value any
---@return boolean ok
---@return string|nil err
function _M.valid_tokens(value)
    if type(value) ~= "table" or #value == 0 and next(value) ~= nil then
        return false, "tokens must be an array of token ids or an array of such arrays"
    end
    local saw_batch = false
    local saw_single = false
    for i = 1, #value do
        local item = value[i]
        if type(item) == "table" then
            saw_batch = true
            for k = 1, #item do
                local token = item[k]
                if type(token) ~= "number" or token ~= math.floor(token)
                    or token < 0 or token > U32_MAX then
                    return false, "tokens[" .. i .. "] must contain u32 integers"
                end
            end
        elseif type(item) == "number" then
            saw_single = true
            if item ~= math.floor(item) or item < 0 or item > U32_MAX then
                return false, "tokens must contain u32 integers"
            end
        else
            return false, "tokens must contain u32 integers or arrays of them"
        end
    end
    if saw_batch and saw_single then
        return false, "tokens must not mix sequences and single token ids"
    end
    return true
end

-- ============================================================ tokenization API

---POST /v1/tokenize
---@param params table
---@param ctx any
---@param req any
function _M.handle_tokenize(params, ctx, req)
    if not _M.authorize("data") then
        return ""
    end
    local raw = _M.raw_body()
    local body = _M.decode_json(raw)
    if not body then
        return _M.send_error(400, "invalid_json",
            "request body must be a JSON object")
    end
    if body.model ~= nil and type(body.model) ~= "string" then
        return _M.send_error(400, "invalid_request", "model must be a string")
    end
    local prompt = body.prompt
    if type(prompt) ~= "string" and not is_string_array(prompt) then
        return _M.send_error(400, "invalid_request",
            "prompt is required and must be a string or an array of strings")
    end

    local worker, claimed = _M.pick_tokenizer_worker(body.model)
    if not worker then
        return _M.send_error(501, "tokenizer_unavailable",
            "tokenizer backend unavailable")
    end
    local response, err = _M.proxy_post(worker, "/v1/tokenize", raw)
    if not response then
        return _M.send_error(502, "tokenizer_backend_error",
            "tokenizer backend " .. tostring(claimed or worker.url) .. " failed: "
                .. tostring(err))
    end
    return _M.write_proxy(response)
end

---POST /v1/detokenize
function _M.handle_detokenize(params, ctx, req)
    if not _M.authorize("data") then
        return ""
    end
    local raw = _M.raw_body()
    local body = _M.decode_json(raw)
    if not body then
        return _M.send_error(400, "invalid_json",
            "request body must be a JSON object")
    end
    if body.model ~= nil and type(body.model) ~= "string" then
        return _M.send_error(400, "invalid_request", "model must be a string")
    end
    if body.tokens == nil then
        return _M.send_error(400, "invalid_request", "tokens is required")
    end
    local ok, verr = _M.valid_tokens(body.tokens)
    if not ok then
        return _M.send_error(400, "invalid_request", verr)
    end
    if body.skip_special_tokens ~= nil and type(body.skip_special_tokens) ~= "boolean" then
        return _M.send_error(400, "invalid_request",
            "skip_special_tokens must be a boolean")
    end

    local worker, claimed = _M.pick_tokenizer_worker(body.model)
    if not worker then
        return _M.send_error(501, "tokenizer_unavailable",
            "tokenizer backend unavailable")
    end
    local response, err = _M.proxy_post(worker, "/v1/detokenize", raw)
    if not response then
        return _M.send_error(502, "tokenizer_backend_error",
            "tokenizer backend " .. tostring(claimed or worker.url) .. " failed: "
                .. tostring(err))
    end
    return _M.write_proxy(response)
end

-- ========================================================== management API

-- ------------------------------------------------------------ job store

local function dict()
    return ngx.shared[DICT_NAME]
end

local function read_ids()
    local d = dict()
    if not d then
        return {}
    end
    local raw = d:get(K_IDS)
    if not raw or raw == "" then
        return {}
    end
    local ids = {}
    for id in string.gmatch(raw, "[^,]+") do
        ids[#ids + 1] = id
    end
    return ids
end

local function write_ids(ids)
    local d = dict()
    if not d then
        return false
    end
    if #ids == 0 then
        d:delete(K_IDS)
        return true
    end
    return d:set(K_IDS, table.concat(ids, ","))
end

local function put_job(job)
    local d = dict()
    if not d then
        return false
    end
    job.updated_at = ngx.time()
    local encoded = json_encode(job)
    if not encoded then
        return false
    end
    d:set(K_JOB .. job.id, encoded, JOB_TTL_SECS)
    if job.name then
        d:set(K_NAME .. job.name, job.id, JOB_TTL_SECS)
    end
    return true
end

local function drop_job(job)
    local d = dict()
    if not d then
        return
    end
    d:delete(K_JOB .. job.id)
    if job.name then
        local mapped = d:get(K_NAME .. job.name)
        if mapped == job.id then
            d:delete(K_NAME .. job.name)
        end
    end
    local kept = {}
    local ids = read_ids()
    for i = 1, #ids do
        if ids[i] ~= job.id then
            kept[#kept + 1] = ids[i]
        end
    end
    write_ids(kept)
end

---Random UUID (version 4 layout, not Rust's v7: no ordered id is needed here,
---and the shape is what the clients and the id regex check).
---@return string
function _M.generate_id()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return (string.gsub(template, "[xy]", function(symbol)
        local r = math.random(0, 15)
        if symbol == "y" then
            r = bit.bor(bit.band(r, 0x3), 0x8)
        end
        return string.format("%x", r)
    end))
end

---@param id string|nil
---@return table|nil job
function _M.get_job(id)
    if type(id) ~= "string" or id == "" then
        return nil
    end
    local d = dict()
    if not d then
        return nil
    end
    local raw = d:get(K_JOB .. id)
    if not raw then
        local mapped = d:get(K_NAME .. id)
        if mapped then
            raw = d:get(K_JOB .. mapped)
        end
    end
    if not raw then
        return nil
    end
    local job = json_decode(raw)
    if type(job) ~= "table" then
        return nil
    end
    return job
end

---@param name string
---@return table|nil job
function _M.get_job_by_name(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local d = dict()
    if not d then
        return nil
    end
    return _M.get_job(d:get(K_NAME .. name) or name)
end

---@return table[] @ every stored job, oldest index order
function _M.list_jobs()
    local out = {}
    local ids = read_ids()
    for i = 1, #ids do
        local job = _M.get_job(ids[i])
        if job then
            out[#out + 1] = job
        end
    end
    return out
end

---Move one job along its lifecycle by observing the worker set. The Lua router
---cannot load a tokenizer, so "completed" always means "a backend claimed it":
---  pending     -> processing once pending_grace_secs passed with no claim
---  processing  -> failed once stale_secs passed with no claim
---  any         -> completed the moment an available worker advertises the name
---@param job table
---@param now number @ epoch seconds
---@return boolean changed
function _M.advance(job, now)
    if job.status == "completed" or job.status == "failed" then
        return false
    end
    now = now or (ngx and ngx.now and ngx.now()) or os.time()

    -- Completion means a live backend advertises *this* tokenizer name: an
    -- unqualified claim ("labels.tokenizer = true") cannot prove the named one.
    local matches = _M.tokenizer_candidates(job.name)
    for i = 1, #matches do
        local entry = matches[i]
        if entry.name == job.name then
            job.status = "completed"
            job.message = string.format(
                "Tokenizer '%s' is served by %s", job.name, entry.record.url)
            job.vocab_size = _M.vocab_size_for(entry.record) or job.vocab_size
            job.backend = entry.record.url
            put_job(job)
            return true
        end
    end

    local age = now - (tonumber(job.created_at) or now)
    local changed = false
    if age >= _M.stale_secs then
        job.status = "failed"
        job.message = string.format(
            "No worker advertised tokenizer '%s' within %ds; the Lua router does not"
                .. " load tokenizers itself, it proxies to a backend that has one",
            job.name, _M.stale_secs)
        changed = true
    elseif age >= _M.pending_grace_secs and job.status == "pending" then
        job.status = "processing"
        job.message = string.format(
            "Waiting for a worker to advertise tokenizer '%s'.", job.name)
        changed = true
    end
    if changed then
        put_job(job)
    end
    return changed
end

---Settle every job against the current worker set (lazy, read-driven).
---@return table[] @ settled jobs
function _M.settle_all()
    local jobs = _M.list_jobs()
    local now = ngx.now()
    for i = 1, #jobs do
        _M.advance(jobs[i], now)
    end
    return jobs
end

-- ------------------------------------------------------------ response shapes

---Rust's TokenizerInfo, with vocab_size omitted rather than invented when no
---backend reported one (deviation noted in the doc).
local function info_from_job(job)
    local info = {
        id = job.id,
        name = job.name,
        source = job.source,
    }
    if tonumber(job.vocab_size) then
        info.vocab_size = tonumber(job.vocab_size)
    end
    return info
end

---Rust's AddTokenizerResponse (vocab_size skipped when nil, per serde).
local function job_response(job)
    local out = {
        id = job.id,
        status = job.status,
        message = job.message or ("Tokenizer job is " .. tostring(job.status)),
    }
    if tonumber(job.vocab_size) then
        out.vocab_size = tonumber(job.vocab_size)
    end
    return out
end

-- ------------------------------------------------------------ handlers

---POST /v1/tokenizers - submit a registration job.
function _M.handle_add_tokenizer(params, ctx, req)
    if not _M.authorize("control") then
        return ""
    end
    local raw = _M.raw_body()
    local body = _M.decode_json(raw)
    if not body then
        return _M.send_error(400, "invalid_json",
            "request body must be a JSON object")
    end
    local name = body.name
    local source = body.source
    if type(name) ~= "string" or name == "" then
        return _M.send_error(400, "invalid_request", "name is required")
    end
    if type(source) ~= "string" or source == "" then
        return _M.send_error(400, "invalid_request", "source is required")
    end
    if body.chat_template_path ~= nil
        and type(body.chat_template_path) ~= "string" then
        return _M.send_error(400, "invalid_request",
            "chat_template_path must be a string")
    end

    if not dict() then
        -- Rust answers the same way when the job queue is missing.
        return _M.write_json({
            id = "",
            status = "failed",
            message = "Job queue not available",
        }, 503)
    end

    local existing = _M.get_job_by_name(name)
    if existing and existing.status ~= "failed" then
        return _M.write_json({
            id = existing.id,
            status = "failed",
            message = string.format("Tokenizer '%s' already exists", name),
        }, 409)
    end
    if existing then
        drop_job(existing)
    end

    local job = {
        id = _M.generate_id(),
        name = name,
        source = source,
        chat_template_path = body.chat_template_path,
        status = "pending",
        message = string.format(
            "Tokenizer '%s' registration job submitted. Loading from: %s",
            name, source),
        created_at = ngx.time(),
        updated_at = ngx.time(),
    }
    if not put_job(job) then
        return _M.write_json({
            id = "",
            status = "failed",
            message = "Failed to persist tokenizer job",
        }, 503)
    end
    local ids = read_ids()
    ids[#ids + 1] = job.id
    write_ids(ids)
    return _M.write_json(job_response(job), 202)
end

---GET /v1/tokenizers - loaded tokenizers; `?all=1` adds unclaimed jobs.
function _M.handle_list_tokenizers(params, ctx, req)
    if not _M.authorize("control") then
        return ""
    end
    local jobs = _M.settle_all()
    local args = ctx and ctx.uri_args
    if type(args) ~= "table" then
        local ok, fetched = pcall(ngx.req.get_uri_args)
        args = ok and fetched or {}
    end
    local want_all = args.all == "1" or args.all == true
        or args.all == "yes"

    local out = {}
    local with_status = {}
    for i = 1, #jobs do
        local job = jobs[i]
        if job.status == "completed" then
            out[#out + 1] = info_from_job(job)
        elseif want_all then
            -- Superset of Rust's TokenizerInfo: status/message/updated_at join
            -- so the pending set is actually observable from this listing.
            local entry = info_from_job(job)
            entry.status = job.status
            entry.message = job.message
            entry.updated_at = job.updated_at
            with_status[#with_status + 1] = entry
        end
    end
    if want_all then
        for i = 1, #with_status do
            out[#out + 1] = with_status[i]
        end
    end
    if #out == 0 then
        out = setmetatable({}, cjson.empty_array_mt)
    end
    return _M.write_json({ tokenizers = out })
end

local function param_text(params, name)
    local value = params and params[name]
    if type(value) == "table" then
        value = value[1]
    end
    if type(value) ~= "string" then
        return nil
    end
    -- Guarded so the pure-Lua unit suite can run without the full ngx surface.
    local ok, decoded = pcall(ngx.unescape_uri, value)
    if ok then
        return decoded
    end
    return value
end

_M.param_text = param_text

---GET /v1/tokenizers/{tokenizer_id} - by id, then by name.
function _M.handle_get_tokenizer(params, ctx, req)
    if not _M.authorize("control") then
        return ""
    end
    local id = param_text(params, "tokenizer_id")
    if not id then
        return _M.send_error(400, "invalid_request", "tokenizer_id is required")
    end
    local job = _M.get_job(id)
    if not job then
        return _M.send_error(404, "tokenizer_not_found",
            "Tokenizer '" .. id .. "' not found")
    end
    _M.advance(job)
    local info = info_from_job(job)
    if job.status ~= "completed" then
        info.status = job.status
        info.message = job.message
    end
    return _M.write_json(info)
end

---GET /v1/tokenizers/{tokenizer_id}/status - job status (Rust reads the loaded
---registry first, then the job queue; the store here is one record).
function _M.handle_tokenizer_status(params, ctx, req)
    if not _M.authorize("control") then
        return ""
    end
    local id = param_text(params, "tokenizer_id")
    if not id then
        return _M.send_error(400, "invalid_request", "tokenizer_id is required")
    end
    local job = _M.get_job(id)
    if not job then
        return _M.send_error(404, "not_found",
            "Tokenizer '" .. id .. "' not found and no pending job")
    end
    _M.advance(job)
    if job.status == "completed" then
        return _M.write_json({
            id = job.id,
            status = "completed",
            message = string.format("Tokenizer '%s' is loaded and ready", job.name),
            vocab_size = tonumber(job.vocab_size),
        })
    end
    return _M.write_json(job_response(job))
end

---DELETE /v1/tokenizers/{tokenizer_id} - by id, then by name.
function _M.handle_delete_tokenizer(params, ctx, req)
    if not _M.authorize("control") then
        return ""
    end
    local id = param_text(params, "tokenizer_id")
    if not id then
        return _M.send_error(400, "invalid_request", "tokenizer_id is required")
    end
    local job = _M.get_job(id)
    if not job then
        return _M.write_json({
            success = false,
            message = "Tokenizer '" .. id .. "' not found",
        }, 404)
    end
    drop_job(job)
    return _M.write_json({
        success = true,
        message = "Tokenizer '" .. tostring(job.name) .. "' removed successfully",
    })
end

return _M
