-- resty.luarouter.config_store.handlers
-- P32-P35：进程内 watcher 桥 + Config 页文档 + 注册模型与 models 文档 + 10 个
-- handle_config_*（ui.lua 按字符串名派发，facade 上逐名可用）。
--
-- 由 lualib/resty/luarouter/config_store.lua 拆分而来：函数体逐行原样搬家，只调整 require 与
-- 跨模块接线（doc/refactor-arch-2026-10-05.md §1–§2）。原文里经 _M.x() 的自调 → 经 CS_FACADE
-- 表调用（保住单测换桩的可拦截性逐点一致）；原文里的同文件 local 直调 → 直接 require 对端
-- 子模块的共享表调用（不进 facade 导出面，_M 契约因此逐名不变）。
local CS_FACADE = require "resty.luarouter.config_store"
local cjson = require "cjson.safe"
local EMPTY_ARRAY_MT = cjson.empty_array_mt
local JSON_NULL = cjson.null
local CS_LEXICON = require "resty.luarouter.config_store.lexicon"
local CS_ENV = require "resty.luarouter.config_store.env"
local CS_UPSTREAMS = require "resty.luarouter.config_store.upstreams"
local CS_SNAPSHOT = require "resty.luarouter.config_store.snapshot"
local CS_READERS = require "resty.luarouter.config_store.readers"

local _M = {}

--- The watcher lives in this process (doc/gap-watcher-merge.md), so the rename
--- ledger is read and written through the module instead of an HTTP round trip to
--- our own port. Same pcall posture init.lua uses: a module that cannot load
--- degrades the state section, it never takes the whole document down.
local function watcher_module()
    local ok, watcher = pcall(require, "resty.luarouter.watcher")
    if ok and type(watcher) == "table" then return watcher end
    return nil
end

--- SMG_WATCHER_ENABLED as the watcher itself reads it. The table start() captured
--- is authoritative when present (init.lua parses the environment once, before the
--- fork); the env fallback keeps the answer honest outside nginx, with the same
--- truth table as resty.luarouter.config.bool().
local function watcher_state(watcher)
    local captured = type(watcher.config) == "function" and watcher.config() or nil
    if type(captured) == "table" and type(captured.enabled) == "boolean" then
        return captured.enabled, captured
    end
    local raw = CS_LEXICON.lower(CS_ENV.env("SMG_WATCHER_ENABLED") or "")
    return raw == "1" or raw == "true" or raw == "yes" or raw == "on", captured
end

--- Effective rename ledger, or nil when the ledger is empty. An empty map is
--- reported as a deliberate null rather than `{}`: the config UI reads a null
--- model_map as "this save forwards no renames", where an explicit {} would wipe
--- the ledger.
local function watcher_ledger(watcher, captured)
    if type(watcher.effective_map) ~= "function" then return nil end
    local ok, map = pcall(watcher.effective_map, captured)
    if not ok or type(map) ~= "table" or next(map) == nil then return nil end
    return map
end

--- Merge a rename body into the ledger in process. `raw` is the request body text
--- so all four accepted shapes (and the cjson {} trap) stay watcher-side.
--- Returns the daemon-shaped document, or nil, reason, ignored-list on refusal.
local function apply_model_map_inprocess(raw)
    local watcher = watcher_module()
    if not watcher then
        return nil, "the watcher module is not loadable"
    end
    if type(watcher.apply_model_map) ~= "function" then
        return nil, "the watcher module has no model-map API"
    end
    local ok, merged, failure = pcall(watcher.apply_model_map, raw)
    if not ok then return nil, tostring(merged), nil end
    if merged == nil then
        return nil, (failure and failure.error) or "watcher rejected the body",
            failure and failure.ignored
    end
    -- Both key families, exactly like GET/POST /model-map: `renamed`/`status` from
    -- the task contract plus the daemon's `model_map`/`note`, so a consumer written
    -- against either keeps reading the same document.
    return {
        renamed = merged,
        status = "queued",
        model_map = merged,
        note = "owned workers are re-registered on the next pass",
    }
end

--- Full Config-page document: snapshot + env_defaults + watcher state.
function _M.document()
    local snap = CS_SNAPSHOT.snapshot_of(CS_FACADE.current())
    -- The stored snapshot carries the secret for the persistence layer; the
    -- response half of contract 3.4 masks it here.
    snap.upstreams = CS_UPSTREAMS.sanitize_upstream_rows(snap.upstreams)
    snap.env_defaults = CS_FACADE.env_defaults()
    -- url stays an explicit null: the watcher is in process, so there is no control
    -- plane address to echo, and the key itself is part of the /_ui/config document
    -- shape (the superset assertion in test_lua_router.sh pins it). `enabled` is what
    -- the model page's badge reads now: it tells "watcher off" apart from "watcher on
    -- with an empty ledger", which url=none used to conflate.
    local reachable, model_map, enabled = false, JSON_NULL, false
    local watcher = watcher_module()
    if watcher then
        local captured
        enabled, captured = watcher_state(watcher)
        local map = watcher_ledger(watcher, captured)
        if map ~= nil then
            reachable = true
            model_map = map
        end
    end
    snap.watcher = { url = JSON_NULL, reachable = reachable,
                     enabled = enabled, model_map = model_map }
    snap.persist = { file = CS_LEXICON.nul(CS_ENV.env("LMR_CONFIG_FILE")) }
    return snap
end

-- ---------------------------------------------------------- registered models

--- models section: registered + configured models merged, one card each.
function _M.models_document()
    local cfg = CS_FACADE.current()
    local order, sources = {}, {}
    local function note(model)
        if sources[model] == nil then
            sources[model] = {}
            order[#order + 1] = model
        end
    end
    for _, row in ipairs(CS_READERS.registered_models()) do
        note(row.model)
        sources[row.model][#sources[row.model] + 1] = row.url
    end
    for _, model in ipairs(CS_LEXICON.sorted_keys(cfg.model_configs)) do note(model) end
    for _, alias in ipairs(CS_LEXICON.sorted_keys(cfg.virtual_models)) do note(alias) end
    table.sort(order)
    local models = {}
    for _, model in ipairs(order) do
        local card = cfg.model_configs[model]
        local map = {}
        if card then
            for _, from in ipairs(CS_LEXICON.sorted_keys(card.effort_map)) do
                map[#map + 1] = { from = from, to = card.effort_map[from] }
            end
        end
        local doc = {
            model = model,
            registered = #sources[model] > 0,
            sources = CS_LEXICON.arr(sources[model]),
            ctx = CS_LEXICON.nul(card and card.ctx),
            default_effort = CS_LEXICON.nul(card and card.default_effort),
            effort_map = CS_LEXICON.arr(map),
            modalities = CS_LEXICON.nul(card and card.modalities),
            -- Tri-state on the models page as well: null = unknown (fall back to what
            -- the engine reports), false = the operator said no. Never merge the two.
            supports_tool_use = CS_LEXICON.nul(card and card.supports_tool_use),
            supports_streaming = CS_LEXICON.nul(card and card.supports_streaming),
            supports_reasoning = CS_LEXICON.nul(card and card.supports_reasoning),
            supports_vision = CS_LEXICON.nul(card and card.supports_vision),
            supports_reasoning_effort = CS_LEXICON.nul(card and card.supports_reasoning_effort),
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
    local doc = CS_FACADE.document()
    doc.models = CS_FACADE.models_document()
    return respond_json(ngx.HTTP_OK, doc)
end

--- Raw request bytes, or nil plus the reason there are none. The model-map route
--- needs the text (not a decoded table) because watcher.parse_model_map_body owns
--- the four accepted body shapes, including the bare `a:b,c:d` form that never
--- decodes as JSON.
local function raw_body_text()
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
    return raw
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

--- A mutator's refusal, with the status the operator deserves. The durable layer
--- turning down a compare-and-set is 409 -- the submitted document was fine, the base
--- underneath it moved -- and stays distinct from the 400 an invalid body has always
--- drawn, so "retry" is a thing a client can recognise instead of a failed validation.
--- The body keeps the {error = "..."} shape the admin pages already render
--- (ui/admin/api.js reads payload.error and response.status for any !ok response), so
--- nothing in ui/ needs to learn the new status.
---
--- 409 is what closes the second half of the stale-CAS bug: a refused write used to
--- come back as 200 carrying a document read out of this worker's shdict, i.e. the UI
--- confirmed a configuration the database had just rejected.
local function respond_apply_error(err)
    if CS_FACADE.is_store_conflict(err) then
        return respond_json((ngx and ngx.HTTP_CONFLICT) or 409, { error = err })
    end
    return respond_json(ngx.HTTP_BAD_REQUEST, { error = err })
end

_M.respond_apply_error = respond_apply_error

--- POST /_ui/config 和 /_ui/config/effort
function _M.handle_config_effort()
    local body, err = read_json_body()
    if body == nil then return respond_json(ngx.HTTP_BAD_REQUEST, { error = err }) end
    local _, apply_err = CS_FACADE.apply_effort(body)
    if apply_err then return respond_apply_error(apply_err) end
    return respond_json(ngx.HTTP_OK, CS_FACADE.document())
end

--- POST /_ui/config/ctx  {model, ctx}
function _M.handle_config_ctx()
    local body, err = read_json_body()
    if body == nil then return respond_json(ngx.HTTP_BAD_REQUEST, { error = err }) end
    local _, apply_err = CS_FACADE.apply_ctx(body.model, rawget(body, "ctx"))
    if apply_err then return respond_apply_error(apply_err) end
    return respond_json(ngx.HTTP_OK, CS_FACADE.document())
end

--- POST /_ui/config/model  one model card
function _M.handle_config_model()
    local body, err = read_json_body()
    if body == nil then return respond_json(ngx.HTTP_BAD_REQUEST, { error = err }) end
    local _, apply_err = CS_FACADE.apply_model_config(body)
    if apply_err then return respond_apply_error(apply_err) end
    local doc = CS_FACADE.document()
    doc.models = CS_FACADE.models_document()
    return respond_json(ngx.HTTP_OK, doc)
end

--- POST /_ui/config/virtual  {entries:[{model,target}]}
function _M.handle_config_virtual()
    local body, err = read_json_body()
    if body == nil then return respond_json(ngx.HTTP_BAD_REQUEST, { error = err }) end
    if type(body) ~= "table" then
        return respond_json(ngx.HTTP_BAD_REQUEST, { error = "body must be a JSON object" })
    end
    local entries = rawget(body, "entries")
    if entries == nil then entries = setmetatable({}, EMPTY_ARRAY_MT) end
    local _, apply_err = CS_FACADE.apply_virtual_models(entries)
    if apply_err then return respond_apply_error(apply_err) end
    return respond_json(ngx.HTTP_OK, CS_FACADE.document())
end

--- POST /_ui/config/upstreams  {entries:[{url,model_id?,api_key?,priority?,
---   cost?,labels?,disable_health_check?,max_concurrency?,max_power_w?}]}
--- Whole-list replace of the declared pool plus an immediate reconcile into
--- lr_workers (contract 3.5). entries missing = empty list = reclaim every
--- config row (root ruling 3: the UI always sends the full list and covers the
--- destructive edit with its own confirmation). The response is the document
--- with a top-level reconcile counter bag.
function _M.handle_config_upstreams()
    local body, err = read_json_body()
    if body == nil then return respond_json(ngx.HTTP_BAD_REQUEST, { error = err }) end
    if type(body) ~= "table" then
        return respond_json(ngx.HTTP_BAD_REQUEST, { error = "body must be a JSON object" })
    end
    local entries = rawget(body, "entries")
    if entries == nil then entries = setmetatable({}, EMPTY_ARRAY_MT) end
    local summary, apply_err = CS_FACADE.apply_upstreams(entries)
    if apply_err then return respond_apply_error(apply_err) end
    local doc = CS_FACADE.document()
    doc.reconcile = summary
    return respond_json(ngx.HTTP_OK, doc)
end

--- GET /_ui/config/policy — routing-page document (chain + per-model rows).
function _M.handle_config_policy_get()
    return respond_json(ngx.HTTP_OK, CS_FACADE.policy_document())
end

--- PUT/POST /_ui/config/policy — change the routing policy at runtime. The
--- response is the fresh document, which is how the page confirms the change.
function _M.handle_config_policy()
    local body, err = read_json_body()
    if body == nil then return respond_json(ngx.HTTP_BAD_REQUEST, { error = err }) end
    local _, apply_err = CS_FACADE.apply_policy(body)
    if apply_err then return respond_apply_error(apply_err) end
    return respond_json(ngx.HTTP_OK, CS_FACADE.policy_document())
end

--- POST /_ui/config/model-map  merge a rename into the in-process watcher ledger.
--- The route stays (the config page and any script written against it keep working)
--- but there is no proxy hop and no LMR_WATCHER_URL guard: the watcher is this
--- process, so an unconfigured environment is a normal success path again.
function _M.handle_config_model_map()
    local raw, err = raw_body_text()
    if raw == nil then return respond_json(ngx.HTTP_BAD_REQUEST, { error = err }) end
    local result, apply_err, ignored = apply_model_map_inprocess(raw)
    if not result then
        -- Body-level refusals carry the daemon's {error,ignored} document; the
        -- status stays the proxy era's 502 so any script pinning it is unaffected.
        return respond_json(ngx.HTTP_BAD_GATEWAY, {
            ok = false,
            error = apply_err,
            ignored = ignored or JSON_NULL,
        })
    end
    result.ok = true
    return respond_json(ngx.HTTP_OK, result)
end

--- POST /_ui/config/apply  whole-document replace, optional model_map section.
function _M.handle_config_apply()
    local patch, err = read_json_body()
    if patch == nil then return respond_json(ngx.HTTP_BAD_REQUEST, { error = err }) end
    if type(patch) ~= "table" then
        -- never a whole-document wipe by accident: only an object is a document
        return respond_json(ngx.HTTP_BAD_REQUEST, { error = "body must be a JSON object" })
    end
    local model_map
    if type(patch) == "table" then
        model_map = rawget(patch, "model_map")
        patch.model_map = nil
    end
    local _, apply_err, reconcile = CS_FACADE.apply_document(patch)
    if apply_err then return respond_apply_error(apply_err) end
    local doc = CS_FACADE.document()
    if reconcile then doc.reconcile = reconcile end
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
            -- In process: no URL to configure, so the only reasons this can fail are
            -- a body the ledger rejects (400-shaped message) or a missing lr_watch
            -- dict (a deployment gap). Both stay a warning, never a failed apply:
            -- the document itself already landed.
            local encoded = cjson.encode(map)
            if encoded == nil then
                warning = "model_map is not encodable; not applied"
            else
                local result, apply_err = apply_model_map_inprocess(encoded)
                if result then
                    doc.watcher_model_map = result
                else
                    warning = "model_map not applied: " .. tostring(apply_err)
                end
            end
        end
    end
    doc.models = CS_FACADE.models_document()
    if warning then doc.warning = warning end
    return respond_json(ngx.HTTP_OK, doc)
end

return _M
