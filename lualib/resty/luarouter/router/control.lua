-- 控制面与观测面 handler（自 router.lua 逐字搬来，只调整了 require 接线）。
--
-- P26 workers CRUD / flush_cache / v1/loads / model-map + P27 metrics 与 _ui
-- handler、mesh observe/forget/disabled + klib :param 取段助手 + server 级
-- preflight_guard。mesh_observe_worker / mesh_forget_worker 的「先声明、后赋值」
-- 缝随本节闭合（/workers 控制面在定义之前调用它们，与原文件同形状；声明行随
-- 原文件 201-203 一起搬入本文件头部下方）。load-safe 纪律照 mesh：非请求阶段也能
-- 应答固定 503（docker-entrypoint 独立进程直调 metrics_handler 的前提）。
-- 注意：ui_logs_handler 里的 local limit 是查询参数名，本模块顶部刻意不绑定
-- host.limit（原文件同处也没有文件级的 limit 局部被它遮蔽的调用点）。
local cjson = require "cjson.safe"

local hb = require "resty.luarouter.hb"
local mesh_mod = require "resty.luarouter.mesh"
local observability = require "resty.luarouter.observability"
local policy_mod = require "resty.luarouter.policy"
local registry = require "resty.luarouter.registry"

local host = require "resty.luarouter.router.host"
local respond = require "resty.luarouter.router.respond"
local candidates = require "resty.luarouter.router.candidates"
local inference = require "resty.luarouter.router.inference"
local metrics_ep = require "resty.luarouter.router.metrics_ep"

local _M = {}
package.loaded["resty.luarouter.router.control"] = _M

local json_decode = cjson.decode
local cfg = host.cfg
local send_error = respond.send_error
local cors_apply = respond.cors_apply
local cors_preflight = respond.cors_preflight
local text_response = inference.text_response
local policy_for = candidates.policy_for
-- 控制面三档容量上限的持久化镜像（用户裁定 2026-10-09，doc/gap-worker-caps.md §4）。
-- host.store 是既有的惰性取用（拿不到 config_store 的裁剪构建只是少一层持久化，
-- 控制面照旧 202），所以这里不新增 require。
local store = host.store

-- The three capacity ceilings, spelled once. The pool side accepts them on
-- POST/PUT /workers (registry/discovery.lua's UPDATE_NUMBER_FIELDS); only these
-- three are mirrored into the declaration layer, because they are the ones the
-- operator configures per worker and the ones that evaporate on a restart.
local CAP_BODY_FIELDS = { "max_concurrency", "min_concurrency", "max_gpu_util" }

--- Pull the capacity ceilings a request body named out of it, in the shape
--- config_store.apply_upstream_caps wants. Absent / JSON_NULL means "the body
--- said nothing about this tier", which is *not* the same as the tier being
--- cleared -- clearing is a value the pool reader folds to unlimited (a
--- non-positive concurrency, a negative utilisation) and still counts as said.
---@param body table
---@return table|nil caps @ nil when the body named none of the three
local function caps_in_body(body)
    if type(body) ~= "table" then return nil end
    local caps
    for i = 1, #CAP_BODY_FIELDS do
        local field = CAP_BODY_FIELDS[i]
        local value = rawget(body, field)
        if value ~= nil and value ~= cjson.null then
            caps = caps or {}
            caps[field] = value
        end
    end
    return caps
end

--- Best-effort mirror of a worker's ceilings into the declaration layer after the
--- pool write already succeeded.
---
--- Deliberately never fatal: the in-memory update is the part the 202 contract
--- pins (and the Rust gateway it matches has no durable layer at all), so a
--- mirror that fails -- the CAS base went stale under us, the store refused, the
--- value shape was refused by the validator -- must not turn a 202 into a 500 or
--- roll back a ceiling the pool is already enforcing. The consequence of failure
--- is narrow and honest: this ceiling works now and will not survive a restart,
--- so it has to be loud in the log. Warn rather than ignore is the whole point --
--- the failure mode this closes ("配了上限，重建容器就没了") is otherwise silent.
---@param worker_url string|nil
---@param caps table|nil
---@param what string @ log context ("PUT /workers/<id>")
local function mirror_worker_caps(worker_url, caps, what)
    if not caps then return end
    if type(worker_url) ~= "string" or worker_url == "" then
        ngx.log(ngx.WARN, "luarouter caps mirror skipped (", what,
            "): the worker record carries no url")
        return
    end
    local mod = store()
    if not mod or type(mod.apply_upstream_caps) ~= "function" then
        ngx.log(ngx.WARN, "luarouter caps mirror skipped (", what,
            "): config_store unavailable -- the ceiling will not survive a restart")
        return
    end
    local ok_call, saved, err = pcall(mod.apply_upstream_caps, worker_url, caps)
    if not ok_call or saved == nil then
        ngx.log(ngx.WARN, "luarouter caps mirror FAILED (", what, "): ",
            ok_call and tostring(err) or tostring(saved),
            " -- the ceiling is live now but will not survive a restart")
    end
end

--- Mirror the pool-side ceiling back onto a *declared* (discovery=="config")
--- row, and report whether the caller may persist at all.
---
--- Why the ownership question belongs here: a config row's caps are owned by the
--- declaration, and the 30s self-heal reconciles the pool from it (the clear
--- sentinels live in upstream_patch). Writing the control plane's number into
--- that row would make the console's PUT silently edit the operator's
--- declaration, and a PUT whose value normalizes to "unlimited" would erase the
--- declared tier outright -- after which the self-heal stops sending its clear
--- sentinel and the ceiling silently reopens in the pool. That is a change of
--- ownership dressed up as a convenience, so it is refused: the PUT stays exactly
--- what it was before this feature (live-only on a config row), and the mirror
--- serves only rows the declaration layer does not own.
--- The refusal is logged because "I set a cap and it did not persist" otherwise
--- has no symptom at all -- the answer is the JSON editor / 服务池 的声明条目.
---@param worker_id string
---@param body table
---@param what string
local function mirror_caps_if_protected(worker_id, body, what)
    local caps = caps_in_body(body)
    if not caps then return end
    local record
    local ok_get, info = pcall(registry.get, worker_id)
    if ok_get and type(info) == "table" then record = info end
    if not record then return end
    if record.discovery == "config" then
        ngx.log(ngx.WARN, "luarouter caps mirror skipped (", what,
            "): ", tostring(record.url), " is a config-declared worker -- its",
            " ceilings belong to the declaration layer (服务池的「编辑声明条目」",
            " / POST /config/upstreams), so this PUT is live-only and will not",
            " survive a restart")
        return
    end
    mirror_worker_caps(record.url, caps, what)
end
-- Defined with the mesh handlers, called by the /workers control plane.
local mesh_observe_worker
local mesh_forget_worker

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
-- ------------------------------------------------------------------ control plane

---Raw request bytes, read the same way inference_handler reads them (the hot path
---keeps its own inlined copy so this adds no call to it).
---@return string
local function raw_body_text()
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

---GET/POST /model-map - the watcher's rename table (doc/gap-watcher-merge.md).
---
---The standalone llm-watcher daemon served this on its own metrics port; merged
---into the router it lives on the main port and this handler calls the module in
---process, so there is no watcher URL to configure. All four body
---shapes the daemon accepted are accepted here (plain object, `{"map":{...}}`, bare
---`a:b,c:d`, `{"map":"a:b,c:d"}`), a POST merges rather than replaces, and an empty
---new id deletes the entry. Owned workers are recycled by the next reconcile pass, so
---the response says "queued" instead of pretending the pool already moved.
---
---The keys follow the task's contract (`renamed` + `status`) and keep the daemon's
---(`model_map` + `note`) so the config UI and any script written against the old
---endpoint keep reading the same document.
local function model_map_handler()
    local ok, watcher = pcall(require, "resty.luarouter.watcher")
    if not ok or type(watcher) ~= "table" then
        return send_error(503, "watcher_unavailable",
            "the watcher module is not loadable")
    end
    if ngx.req.get_method() ~= "POST" then
        local map = watcher.effective_map(cfg())
        return {
            model_map = map,
            renamed = map,
            enabled = ((watcher.config() or cfg().watcher) or {}).enabled or false,
        }
    end
    local merged, failure = watcher.apply_model_map(raw_body_text())
    if not merged then
        if failure and failure.kind == "config" then
            -- The deployment is missing its ledger dict, not the client's body.
            return send_error(503, "watcher_unavailable", failure.error)
        end
        -- 400 with the daemon's {error,ignored} document: the ignored list names the
        -- offending entries, so it rides in the body rather than only the message.
        -- exact_json stamps the status, so this stays a plain table return.
        return {
            error = failure and failure.error or "invalid body",
            ignored = failure and failure.ignored or cjson.null,
        }, 400
    end
    return {
        renamed = merged,
        status = "queued",
        model_map = merged,
        note = "owned workers are re-registered on the next pass",
    }
end

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
    -- Same best-effort mirror as the PUT path: registry.add already stored the
    -- ceilings the body named, and they need the declaration layer to outlive
    -- the container. The url is taken from the *record*, not the body, so a
    -- registry-normalized spelling (http://H:P/ -> http://h:p) cannot fork a
    -- second mirror row for one worker.
    mirror_worker_caps(result.url, caps_in_body(body),
        "POST /workers " .. tostring(result.id))
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
    -- Forget the mirrored ceilings of the worker that is gone (belt; reconcile's
    -- add-branch guard against pure mirror rows is the braces). Only a pure
    -- mirror is removed -- a row the declaration layer genuinely owns survives
    -- the deletion of its worker, because deleting a live worker is a pool
    -- operation and not a licence to erase an operator's declaration.
    local mod = store()
    if mod and type(mod.drop_upstream_caps) == "function" then
        local ok_call, removed, derr = pcall(mod.drop_upstream_caps, result.url)
        if not ok_call or removed ~= true then
            local reason = ok_call and derr or removed
            if reason ~= nil then
                ngx.log(ngx.WARN, "luarouter caps mirror cleanup FAILED (",
                    tostring(result.url), "): ", tostring(reason))
            end
        end
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
    -- Mirror the ceilings the body named onto the declaration layer so they
    -- outlive a container restart. After this line the response shape is
    -- pinned by the contract (test_lua_router.sh pins Rust's
    -- UpdateWorkerResult::into_response to exactly {status,worker_id,message}),
    -- which is why a mirror failure can only ever reach the log: the 202 body
    -- must stay byte-identical whether or not the write took.
    mirror_caps_if_protected(result.worker_id or worker_id, body,
        "PUT /workers/" .. tostring(result.worker_id or worker_id))
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
---here because the lua-router UI reads them; the contract suite records
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

---GET /_ui/logs?cursor=&limit=&model=&forwarded_model=&worker=&status=
---    &route_type=&stream=&since_ms=&until_ms=&session=
---
---The ring buffer as JSON, oldest first. Every filter is optional and
---omitting all of them keeps the response byte-identical to the
---cursor+limit shape this route had before filtering existed.
---
---A bad parameter is a 400, never a silently empty array: a UI that cannot
---tell "nothing matched" from "you typed the filter wrong" will show
---the user an empty table and send them looking for a data problem.
local function ui_logs_handler(params, ctx, req)
    local query = req.get_query()
    local filter, bad_param, bad_msg = observability.parse_query(query)
    if bad_param then
        return send_error(400, "BAD_REQUEST",
            tostring(bad_param) .. ": " .. tostring(bad_msg))
    end
    if filter then
        local doc = observability.query(filter, query.cursor, query.limit)
        if #doc.requests == 0 then
            doc.requests = cjson.empty_array
        end
        return doc
    end
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
-- 跨模块接线（拆分新增；文末；function _M.preflight_guard 的定义留在上面原样，
-- nginx 三处 conf 按 facade 名取，facade re-export）。
_M.raw_body_text = raw_body_text
_M.param_text = param_text
_M.model_map_handler = model_map_handler
_M.create_worker_handler = create_worker_handler
_M.list_workers_handler = list_workers_handler
_M.get_worker_handler = get_worker_handler
_M.delete_worker_handler = delete_worker_handler
_M.update_worker_handler = update_worker_handler
_M.object_body = object_body
_M.flush_cache_handler = flush_cache_handler
_M.loads_handler = loads_handler
_M.metrics_handler = metrics_handler
_M.ui_logs_handler = ui_logs_handler
_M.ui_stats_handler = ui_stats_handler
_M.mesh_observe_worker = mesh_observe_worker
_M.mesh_forget_worker = mesh_forget_worker
_M.mesh_disabled_handler = mesh_disabled_handler
_M.ui_backends_handler = ui_backends_handler
return _M
