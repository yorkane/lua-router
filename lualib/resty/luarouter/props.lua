-- /_ui/props synthesis for the llama.cpp webui (lua-router).
--
-- Mirrors gateway/src/server.rs ui_props(): collect the HTTP workers that serve
-- the requested model, try each worker's own /props (3s timeout, Bearer api_key),
-- run the rewrite chain thinking -> modalities -> role:"router" -> n_ctx cap.
-- When no worker answers, synthesize a minimal document so the UI can still
-- select the model and chat through the router.
--
-- Registry access is isolated in _M.http_workers() (see the contract in
-- doc/impl-ui.md). It prefers resty.luarouter.registry (owned by the core
-- agent); while that module does not exist yet, tests can inject a worker list
-- through the global LMR_TEST_WORKERS.

local cjson = require "cjson.safe"

local _M = {}

local JSON_NULL = cjson.null

-- ---------------------------------------------------------------- registry

--- HTTP workers as an array of {url=string, api_key=string|nil,
--- models={string,...}}; api_key is set only when the worker needs auth.
--- Source order: registry.http_workers() (if core adds it), then the registry
--- record list grouped by url (each record carries one model_id), then the
--- LMR_TEST_WORKERS global used by the unit checks.
function _M.http_workers()
    local ok, registry = pcall(require, "resty.luarouter.registry")
    if ok and type(registry) == "table" then
        if type(registry.http_workers) == "function" then
            return registry.http_workers() or {}
        end
        if type(registry.records) == "function" then
            local ok_recs, recs = pcall(registry.records)
            local by_url, order = {}, {}
            for _, rec in ipairs(ok_recs and recs or {}) do
                local url = rec.url
                local mode = rec.connection_mode or "http"
                if url and mode == "http" then
                    local w = by_url[url]
                    if not w then
                        w = { url = url, api_key = rec.api_key, models = {}, seen = {} }
                        by_url[url] = w
                        order[#order + 1] = w
                    end
                    local model = rec.model_id or "unknown"
                    if not w.seen[model] then
                        w.seen[model] = true
                        w.models[#w.models + 1] = model
                    end
                end
            end
            for _, w in ipairs(order) do w.seen = nil end
            if #order > 0 then return order end
        end
    end
    local injected = rawget(_G, "LMR_TEST_WORKERS")
    if type(injected) == "table" then return injected end
    return {}
end

_M.config_store = nil
local function store()
    if _M.config_store then return _M.config_store end
    local ok, mod = pcall(require, "resty.luarouter.config_store")
    if ok then _M.config_store = mod end
    return _M.config_store
end

--- LMR_UI_ROUTER_MODE defaults ON; false/0/off disables (Rust ui_router_mode).
function _M.router_mode()
    local s = store()
    local raw = s and s.env("LMR_UI_ROUTER_MODE") or nil
    if raw == nil then raw = os.getenv("LMR_UI_ROUTER_MODE") end
    if raw == nil then return true end
    local v = tostring(raw):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    return not (v == "false" or v == "0" or v == "off")
end

-- -------------------------------------------------------- rewrite-chain steps

--- Advertise thinking capability unless the worker's chat_template already
--- mentions a knob: the webui hides the effort picker otherwise.
function _M.with_thinking(value)
    if type(value) ~= "table" then return value end
    local tpl = rawget(value, "chat_template")
    local advertised = type(tpl) == "string"
        and (tpl:find("reasoning_effort", 1, true) or tpl:find("enable_thinking", 1, true)
             or tpl:find("<|im_start|>", 1, true))
    if not advertised then
        value.chat_template = "{% if reasoning_effort %}router-advertised{% endif %}"
    end
    return value
end

--- A Config-page capability override wins outright; otherwise vision is
--- advertised so the UI stops dropping image attachments (Rust
--- ui_props_with_modalities). `wanted` is the *requested* model name (card keys
--- follow the name the UI picked, alias or not, as in the Rust cap_model).
function _M.with_modalities(value, wanted_model)
    if type(value) ~= "table" then return value end
    local s = store()
    local caps = s and wanted_model and wanted_model ~= ""
        and s.modalities_for(wanted_model) or nil
    if type(caps) == "table" then
        local function has(c)
            for _, x in ipairs(caps) do if x == c then return true end end
            return false
        end
        value.modalities = { audio = has("audio"), video = has("video"),
                             vision = has("image") or has("video") }
        return value
    end
    if value.modalities == nil then
        value.modalities = { audio = false, video = false, vision = true }
    end
    return value
end

--- Force role:"router" so the UI shows the multi-model picker.
function _M.with_role(value)
    if _M.router_mode() and type(value) == "table" then
        value.role = "router"
    end
    return value
end

--- Report the configured context cap instead of the worker's raw n_ctx.
function _M.with_ctx(value, wanted_model)
    if type(value) ~= "table" then return value end
    local s = store()
    if not (s and wanted_model and wanted_model ~= "") then return value end
    local cap = s.ctx_cap(wanted_model)
    if not cap then return value end
    value.n_ctx = cap
    local train = tonumber(value.n_ctx_train) or cap
    if train < cap then train = cap end
    value.n_ctx_train = train
    return value
end

--- Apply the whole chain in Rust order (thinking -> modalities -> role -> ctx).
function _M.rewrite(props, cap_model)
    return _M.with_ctx(
        _M.with_role(
            _M.with_modalities(_M.with_thinking(props), cap_model),
            cap_model),
        cap_model)
end

-- ------------------------------------------------------------------ fetching

--- cosocket GET {worker.url}/props with a 3s timeout; decoded table or nil.
local function fetch_props(worker)
    local base = tostring(worker.url or ""):gsub("/+$", "")
    if base == "" then return nil end
    local s = store()
    if not s then return nil end
    local headers = { Accept = "application/json" }
    if worker.api_key and worker.api_key ~= "" then
        headers.Authorization = "Bearer " .. worker.api_key
    end
    local status, _, body = s.raw_request("GET", base .. "/props", false, headers, 3000)
    if not status or status < 200 or status >= 300 then return nil end
    return cjson.decode(body or "")
end

local function first_model_of(list)
    for _, w in ipairs(list) do
        local models = w.models or {}
        if models[1] then return models[1] end
    end
    return nil
end

-- ------------------------------------------------------------------- handler

--- GET /_ui/props?model=X
function _M.handle()
    local args = ngx.req.get_uri_args() or {}
    local wanted_raw = args.model
    if type(wanted_raw) ~= "string" or wanted_raw == "" then wanted_raw = nil end

    local s = store()
    -- cap_model keys the config cards; wanted is the resolved upstream id.
    local cap_model = wanted_raw
    local wanted = wanted_raw
    if s and wanted then wanted = s.resolve_model(wanted) end

    local all = _M.http_workers()
    local candidates = {}
    for _, w in ipairs(all) do
        if not wanted then
            candidates[#candidates + 1] = w
        else
            for _, m in ipairs(w.models or {}) do
                if m == wanted then
                    candidates[#candidates + 1] = w
                    break
                end
            end
        end
    end

    for _, w in ipairs(candidates) do
        local props = fetch_props(w)
        if props then
            ngx.header.content_type = "application/json"
            ngx.say(cjson.encode(_M.rewrite(props, cap_model)))
            return ngx.exit(ngx.HTTP_OK)
        end
    end

    local model_path = wanted or first_model_of(candidates) or first_model_of(all) or "unknown"
    local doc = _M.rewrite({
        model_path = model_path,
        model_alias = JSON_NULL,
        webui_version = "llm-router",
    }, cap_model)
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode(doc))
    return ngx.exit(ngx.HTTP_OK)
end

return _M
