-- /_ui API aliases for the llama.cpp webui (lua-router).
--
-- Mirrors gateway/src/server.rs ui_api_routes(): the chat/completions aliases
-- reuse the shared routing pipeline (body-limit/metrics live in core; the
-- auth layer was removed with the whole gateway auth surface, doc/scope-trim.md),
-- the picker endpoints answer fixed responses, and everything else forwards
-- to the sibling modules (props.lua, config_store.lua, observability.lua).
--
-- Pipeline contract (doc/impl-ui.md): this module NEVER proxies upstream
-- itself. It requires resty.luarouter.api and calls
--   api.chat(body_table, raw)     -- POST body after model/effort clean-up
--   api.completion(body_table, raw)
-- and relies on them to write the response. The second argument carries the
-- original request bytes so the pipeline can splice its edits into them:
-- a cjson decode/encode round trip turns every empty array ("tools":[],
-- "stop":[]) into an empty object, which llama.cpp and vLLM both reject.
-- While api is missing it falls back to resty.luarouter.router with
-- do_chat/do_completion, then to the global LMR_TEST_PIPELINE (unit tests).

local cjson = require "cjson.safe"

local _M = {}

local props_ok, props = pcall(require, "resty.luarouter.props")
local store_ok, store = pcall(require, "resty.luarouter.config_store")

local JSON_NULL = cjson.null
local EMPTY_ARRAY = setmetatable({}, cjson.empty_array_mt)

-- ---------------------------------------------------------------- responses

--- axum-style method gating: the Rust router answers a wrong method with 405
--- before reaching the handler. method_only("POST") / method_any("GET","POST").
function _M.method_only(method)
    return _M.method_any(method)
end

function _M.method_any(...)
    local allowed = { ... }
    local m = ngx.req.get_method()
    for _, a in ipairs(allowed) do
        if m == a or (m == "HEAD" and a == "GET") then return end
    end
    ngx.header.allow = table.concat(allowed, ", ")
    return _M.respond_json(ngx.HTTP_NOT_ALLOWED or 405,
        { error = { message = "method not allowed" } })
end

function _M.respond_json(status, payload)
    ngx.status = status
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode(payload))
    return ngx.exit(status)
end

local function request_error(status, message)
    return _M.respond_json(status, { error = { message = message } })
end

local function read_raw_body()
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if not raw then
        local file = ngx.req.get_body_file()
        if file then
            local f = io.open(file, "r")
            if f then raw = f:read("*a") f:close() end
        end
    end
    if not raw or raw == "" then return nil, "empty request body" end
    return raw
end

local function read_json_body()
    local raw, err = read_raw_body()
    if not raw then return nil, nil, err end
    local value, derr = cjson.decode(raw)
    if value == nil then return nil, nil, "invalid JSON body: " .. (derr or "?") end
    if type(value) ~= "table" then return nil, nil, "request body must be a JSON object" end
    return value, raw
end

-- ------------------------------------------------------- shared chat helpers

--- The webui may send its first message before /props lands, with no model
--- (or an empty string). Fill the first HTTP worker's model, like Rust
--- default_ui_model().
function _M.fill_default_model(body)
    local model = rawget(body, "model")
    local missing = model == nil or model == JSON_NULL
        or (type(model) == "string" and model == "")
    if not missing then return body end
    if not props_ok then return body end
    for _, w in ipairs(props.http_workers()) do
        local models = w.models or {}
        if models[1] then
            body.model = models[1]
            break
        end
    end
    return body
end

--- Empty-string or null reasoning_effort is a UI "no preference": drop the key
--- so the engine default applies (Rust clean_ui_effort).
function _M.clean_ui_effort(body)
    local effort = rawget(body, "reasoning_effort")
    if effort == JSON_NULL then
        body.reasoning_effort = nil
    elseif type(effort) == "string" and effort == "" then
        body.reasoning_effort = nil
    end
    return body
end

--- Raw-bytes twin of fill_default_model / clean_ui_effort.
---
--- Same decisions, applied by editing the JSON text through
--- router.set_top_field so the rest of the document keeps its exact bytes
--- (and so empty arrays survive). The decoded table is still updated because
--- the pipeline reads it for routing, stream detection and the ctx cap.
---@param raw string
---@param body table
---@return string raw
local function splice_ui_cleanups(raw, body)
    local ok, router = pcall(require, "resty.luarouter.router")
    if not (ok and router and type(router.set_top_field) == "function") then
        -- Without the editor there is no way to keep the bytes; hand the
        -- original body over untouched and let the pipeline re-encode as
        -- it always did.
        return raw
    end
    _M.fill_default_model(body)
    local had_effort = rawget(body, "reasoning_effort")
    _M.clean_ui_effort(body)
    if body.model ~= nil and body.model ~= JSON_NULL then
        raw = router.set_top_field(raw, "model", body.model)
    end
    if had_effort ~= nil and had_effort ~= body.reasoning_effort then
        -- Only a dropped value needs removal here: a filled-in default stays
        -- absent from the payload so the engine default applies.
        raw = router.set_top_field(raw, "reasoning_effort", nil)
    end
    return raw
end

--- Resolve the shared pipeline module, per the contract above.
local function pipeline()
    local ok, api = pcall(require, "resty.luarouter.api")
    if ok and type(api) == "table" and type(api.chat) == "function" then
        return api, "chat", "completion"
    end
    local ok2, router = pcall(require, "resty.luarouter.router")
    if ok2 and type(router) == "table" and type(router.do_chat) == "function" then
        return router, "do_chat", "do_completion"
    end
    local test = rawget(_G, "LMR_TEST_PIPELINE")
    if type(test) == "table" and type(test.chat) == "function" then
        return test, "chat", "completion"
    end
    return nil
end

--- POST /_ui/v1/chat/completions
function _M.chat()
    local body, raw, err = read_json_body()
    if body == nil then
        return request_error(ngx.HTTP_BAD_REQUEST, "invalid chat request: " .. err)
    end
    raw = splice_ui_cleanups(raw, body)
    local mod, chat_fn = pipeline()
    if not mod then
        return request_error(ngx.HTTP_SERVICE_UNAVAILABLE,
            "invalid chat request: router pipeline not available")
    end
    return mod[chat_fn](body, raw)
end

--- POST /_ui/v1/completions
function _M.completion()
    local body, raw, err = read_json_body()
    if body == nil then
        return request_error(ngx.HTTP_BAD_REQUEST, "invalid completion request: " .. err)
    end
    raw = splice_ui_cleanups(raw, body)
    local mod, _, completion_fn = pipeline()
    if not mod then
        return request_error(ngx.HTTP_SERVICE_UNAVAILABLE,
            "invalid completion request: router pipeline not available")
    end
    return mod[completion_fn](body, raw)
end

-- ------------------------------------------------------------- picker model

--- GET /_ui/v1/models — every registered worker model plus the virtual
--- aliases; the picker keys off status.value, everything registered is loaded.
function _M.models()
    local data = {}
    local seen = {}
    if props_ok then
        for _, w in ipairs(props.http_workers()) do
            for _, id in ipairs(w.models or {}) do
                if not seen[id] then
                    seen[id] = true
                    data[#data + 1] = {
                        id = id,
                        object = "model",
                        created = 0,
                        owned_by = "llm-router",
                        status = { value = "loaded" },
                    }
                end
            end
        end
    end
    if store_ok then
        for _, pair in ipairs(store.virtual_models_list()) do
            local alias, target = pair[1], pair[2]
            if not seen[alias] then
                seen[alias] = true
                data[#data + 1] = {
                    id = alias,
                    object = "model",
                    created = 0,
                    owned_by = "llm-router->" .. target,
                    status = { value = "loaded" },
                }
            end
        end
    end
    table.sort(data, function(a, b) return a.id < b.id end)
    return _M.respond_json(ngx.HTTP_OK, { object = "list", data = data })
end

--- POST /_ui/models/load — models are resident behind the router: confirm.
function _M.model_load()
    return _M.respond_json(ngx.HTTP_OK, { success = true })
end

--- POST /_ui/models/unload — refuse: unloading would pull an instance out of
--- the pool for everyone; that is the watcher's job.
function _M.model_unload()
    return request_error(ngx.HTTP_BAD_REQUEST,
        "模型由 router 后的实例常驻提供，聊天界面不能卸载；要摘除请在 watcher / 服务侧操作")
end

--- GET /_ui/models/sse — the stock UI polls for load progress; behind a
--- router nothing changes, so keep the stream open with 30s ping comments.
function _M.models_sse()
    ngx.status = ngx.HTTP_OK
    ngx.header.content_type = "text/event-stream"
    ngx.header["Cache-Control"] = "no-cache"
    ngx.header["X-Accel-Buffering"] = "no"
    ngx.flush(true)
    while true do
        local ok = pcall(ngx.print, ": ping\n\n")
        if not ok then return ngx.exit(ngx.HTTP_OK) end
        local flushed = pcall(ngx.flush, true)
        if not flushed then return ngx.exit(ngx.HTTP_OK) end
        local slept = pcall(ngx.sleep, 30)
        if not slept then return ngx.exit(ngx.HTTP_OK) end
    end
end

--- GET/POST /_ui/slots, /_ui/tools, /_ui/v1/streams/lookup — the UI polls
--- these to resume in-flight llama.cpp server streams; the router owns none.
function _M.empty_array()
    return _M.respond_json(ngx.HTTP_OK, EMPTY_ARRAY)
end

--- ANY /_ui/v1/stream, /_ui/v1/chat/completions/control — answer honestly.
function _M.unsupported()
    return _M.respond_json(ngx.HTTP_NOT_IMPLEMENTED,
        { error = "llama.cpp server stream/control not available through the router" })
end

-- --------------------------------------------------------- props / config

--- GET /_ui/props
function _M.props()
    if not props_ok then
        return _M.respond_json(ngx.HTTP_SERVICE_UNAVAILABLE,
            { error = "props module unavailable" })
    end
    return props.handle()
end

local function config_handler(name)
    if not store_ok then
        return _M.respond_json(ngx.HTTP_SERVICE_UNAVAILABLE,
            { error = "config module unavailable" })
    end
    return store[name]()
end

function _M.config_get() return config_handler("handle_config_get") end
function _M.config_effort() return config_handler("handle_config_effort") end
function _M.config_ctx() return config_handler("handle_config_ctx") end
function _M.config_model() return config_handler("handle_config_model") end
function _M.config_virtual() return config_handler("handle_config_virtual") end
function _M.config_apply() return config_handler("handle_config_apply") end
function _M.config_model_map() return config_handler("handle_config_model_map") end

-- ------------------------------------------------------- observability bridge

--- /_ui/logs, /_ui/logs/stream, /_ui/stats, /_ui/logs/backends live in
--- observability.lua (core agent). Bridge with a thin 503 stub while that
--- module is missing (same body shape as Rust request_log_disabled).
local function observability_call(fn_name)
    local ok, obs = pcall(require, "resty.luarouter.observability")
    if ok and type(obs) == "table" and type(obs[fn_name]) == "function" then
        return obs[fn_name]()
    end
    return _M.respond_json(ngx.HTTP_SERVICE_UNAVAILABLE,
        { error = "request log not enabled" })
end

function _M.logs() return observability_call("handle_logs") end
function _M.logs_stream() return observability_call("handle_logs_stream") end
function _M.logs_backends() return observability_call("handle_backends") end
function _M.stats() return observability_call("handle_stats") end

return _M
