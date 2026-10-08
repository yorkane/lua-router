--
-- 本文件是 facade：klib 路由表装配（build）、content_by_lua 入口（handle）、
-- server 级预检与全量 _M 导出。实现逐字搬进了 router/ 子模块（拆分设计书
-- doc/refactor-arch-2026-10-05.md §1–§2）：
--   router/host        进程级惰性访问器 cfg()/limit()/store()
--   router/jsonutil    顶层精确改写 / DP rank / 路由文本抽取 / usage / SSE / 会话指纹
--   router/respond     错误应答 / CORS / request id / 请求头与标签
--   router/profiles    虚拟模型 profile 读层（含两条恒 nil 停用缝）
--   router/candidates  策略选路 policy_for + 候选装配 candidates_for（热路径）
--   router/pump        cosocket 泵
--   router/forward     streaming 泵 + 重试环 + forward 主循环
--   router/inference   推理面 + 公开面（health/readiness/text_response）
--   router/models_api  /v1/models 合成 + 广告开关 + handlers
--   router/metrics_ep  metrics 聚合渲染 + engine_metrics/model_info
--   router/control     控制面 + 观测/mesh handler + param 取段 + preflight
--   router/reqlog      请求日志 + finish_request 收尾
-- 加载顺序即依赖顺序（下层无环；forward<->inference 的环按 §2 用调用期模块表解析，
-- 两个模块都在各自文件头预登记 package.loaded）。facade 对每个导出**直接赋值**：
-- 全仓 grep 证实没有任何测试或生产路径在运行期替换 router 模块表的成员
-- （test/conf 探针与 docker-entrypoint 只读调用），所以不需要包装函数。
-- nginx 三处 conf 只取 preflight_guard/handle；ui.lua 运行时硬依赖
-- set_top_field/do_chat/do_completion；这些名字在本表原名保留。

local cjson = require "cjson.safe"
local router_class = require "klib.router"

local _M = { _VERSION = "0.1.0" }
package.loaded["resty.luarouter.router"] = _M

local hb = require "resty.luarouter.hb"
local observability = require "resty.luarouter.observability"
local policy_mod = require "resty.luarouter.policy"
local registry = require "resty.luarouter.registry"
-- Wired gap module: cluster mesh (doc/gap-mesh.md). It is load-safe without ngx
-- (it only reads ngx inside its handlers), so the init_by_lua syntax gate can
-- require it. The conversation/response store went with the history plane and
-- the tokenize/parse proxies went with it (doc/scope-trim.md): /v1/responses
-- stays as a pure inference route and that proxy family is not routed.
local mesh_mod = require "resty.luarouter.mesh"

local host = require "resty.luarouter.router.host"
local jsonutil = require "resty.luarouter.router.jsonutil"
local respond = require "resty.luarouter.router.respond"
local profiles = require "resty.luarouter.router.profiles"
local candidates = require "resty.luarouter.router.candidates"
local pump = require "resty.luarouter.router.pump"
local forwardmod = require "resty.luarouter.router.forward"
local inference = require "resty.luarouter.router.inference"
local models_api = require "resty.luarouter.router.models_api"
local metrics_ep = require "resty.luarouter.router.metrics_ep"
local control = require "resty.luarouter.router.control"
local reqlog = require "resty.luarouter.router.reqlog"

-- build()/handle() 的调用面（原文件的同文件局部，拆分后按名绑定）：
local exact_json = respond.exact_json
local send_error = respond.send_error
local request_id = respond.request_id
local cors_apply = respond.cors_apply
local cors_preflight = respond.cors_preflight
local health_handler = inference.health_handler
local health_generate_handler = inference.health_generate_handler
local readiness_handler = inference.readiness_handler
local inference_handler = inference.inference_handler
local text_response = inference.text_response
local models_handler = models_api.models_handler
local server_info_handler = models_api.server_info_handler
local not_implemented_handler = models_api.not_implemented_handler
local model_info_handler = metrics_ep.model_info_handler
local engine_metrics_handler = metrics_ep.engine_metrics_handler
local create_worker_handler = control.create_worker_handler
local list_workers_handler = control.list_workers_handler
local get_worker_handler = control.get_worker_handler
local update_worker_handler = control.update_worker_handler
local delete_worker_handler = control.delete_worker_handler
local flush_cache_handler = control.flush_cache_handler
local model_map_handler = control.model_map_handler
local loads_handler = control.loads_handler
local metrics_handler = control.metrics_handler
local ui_logs_handler = control.ui_logs_handler
local ui_stats_handler = control.ui_stats_handler
local ui_backends_handler = control.ui_backends_handler
local mesh_disabled_handler = control.mesh_disabled_handler
local finish_request = reqlog.finish_request
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
--   observability    /metrics (/logs /stats live in conf/ui.conf as root exacts)
--
-- Handler convention (klib.router): return a table for JSON, return a table plus
-- a status for JSON with an explicit code, and return '' once the response has
-- been written by hand. A number in 100..599 with no result is a bare status.
--
-- Cluster mesh is wired behind SMG_MESH_PEERS - with SMG_ENABLE_MESH off, /ha/*
-- answers the fixed 503, which is the contract for a node that has not opted
-- in. The gRPC transport plane, the prefill/decode pool split, the
-- conversation/response store, the tokenize/parse proxy plane, the Kubernetes
-- service discovery and the OTel trace exporter were removed
-- (doc/scope-trim.md): this gateway speaks plain HTTP to its workers,
-- /v1/responses is a pure inference route, and the token-counting and
-- tool-parser proxy family answers from the 404 sink.
--
-- What is genuinely not implemented is tracked in doc/todo-deferred.md: wasm
-- middleware is a deferred TODO (doc/todo-deferred.md §2) and its three /wasm routes answer 501, and the four
-- smg_mcp_* families stay unregistered with the MCP server absent.
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
    -- Watcher rename table. GET answers the effective map, POST merges into it;
    -- both are exact_json so the JSON content type and HEAD parity hold.
    app:get("model-map", exact_json(model_map_handler))
    app:head("model-map", exact_json(model_map_handler))
    app:post("model-map", exact_json(model_map_handler))
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

    -- Observability reads live in conf/ui.conf as root exact locations
    -- (/logs /logs/stream /logs/backends /stats, handlers in observability.lua);
    -- the /_ui/* registrations went away with the 2026-10-08 admin-to-root move,
    -- so /_ui/* now answers the 404 sink like any unregistered path. The three
    -- handlers stay exported (ui_logs_handler / ui_stats_handler /
    -- ui_backends_handler) for the UI agent's aliases and the unit tests.

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
-- 全量导出区（= 原文件底部导出区 + 就近导出的汇总面；78 个名字逐名保留，
-- doc/refactor-arch-2026-10-05.md 不变量 2）。原处散布的就近导出仍留在各子模块
-- 里（赋的是子模块自己的 _M），本区把子模块导出重新挂到 facade 表上。

-- 应答 / CORS / request id / 请求头与标签（router/respond.lua）
_M.error_body = respond.error_body
_M.send_error = respond.send_error
_M.cors_apply = respond.cors_apply
_M.cors_preflight = respond.cors_preflight
_M.generate_request_id = respond.generate_request_id
_M.request_id = respond.request_id
_M.should_forward_request_header = respond.should_forward_request_header
_M.DROP_RESPONSE_HEADERS = respond.DROP_RESPONSE_HEADERS
_M.error_type_from_status = respond.error_type_from_status

-- 顶层精确改写 / 文本抽取 / usage / SSE / 指纹（router/jsonutil.lua）
_M.text_extractors = jsonutil.text_extractors
_M.set_top_field = jsonutil.set_top_field
_M.merge_top_object = jsonutil.merge_top_object
_M.patch_response_metadata = jsonutil.patch_response_metadata
_M.rewrite_model = jsonutil.rewrite_model
_M.usage_from_body = jsonutil.usage_from_body
_M.estimate_tokens = jsonutil.estimate_tokens
_M.sse_event_droppable = jsonutil.sse_event_droppable
_M.sse_split = jsonutil.sse_split
_M.router_session_key = jsonutil.router_session_key
_M.sha256_hex = jsonutil.sha256_hex

-- profile 读层（router/profiles.lua）
_M.profile_for_alias = profiles.profile_for_alias
_M.profile_model_group = profiles.profile_model_group
_M.profile_worker_list = profiles.profile_worker_list
_M.profile_policy_name = profiles.profile_policy_name

-- 策略选路与候选装配（router/candidates.lua）
_M.policy_for = candidates.policy_for
_M.profile_bindings = candidates.profile_bindings
_M.card_key_for = candidates.card_key_for
_M.profile_policy_model = candidates.profile_policy_model
_M.group_policy_hint = candidates.group_policy_hint
_M.group_key_name = candidates.group_key_name
_M.candidates_for = candidates.candidates_for
_M.compact_url = candidates.compact_url

-- cosocket 泵（router/pump.lua）
_M.connect_target = pump.connect_target

-- 转发主循环（router/forward.lua）
_M.names_stream_options = forwardmod.names_stream_options
_M.client_wants_usage = forwardmod.client_wants_usage
_M.stream_options_rejected = forwardmod.stream_options_rejected
_M.note_stream_options_rejected = forwardmod.note_stream_options_rejected
_M.clear_stream_options_rejected = forwardmod.clear_stream_options_rejected
_M.forward = forwardmod.forward
_M.stream_response = forwardmod.stream_response
_M.hold_load = forwardmod.hold_load
_M.release_load = forwardmod.release_load

-- 推理面与公开面（router/inference.lua）
_M.route_inference = inference.route_inference
_M.inference_handler = inference.inference_handler
_M.apply_effort_policy = inference.apply_effort_policy
_M.apply_ctx_cap = inference.apply_ctx_cap
_M.entry_ctx_cap = inference.entry_ctx_cap
_M.do_chat = inference.do_chat
_M.do_completion = inference.do_completion
_M.health_handler = inference.health_handler
_M.health_generate_handler = inference.health_generate_handler
_M.readiness_handler = inference.readiness_handler
_M.text_response = inference.text_response

-- /v1/models 合成与广告面（router/models_api.lua）
_M.models_handler = models_api.models_handler
-- 导出开关状态表：单测与 /_ui 侧要能问「这个开关现在是什么状态」，否则操作员改了
-- 配置只能靠 data[] 的条数反推。刻意放在导出区而不是本节内——test/unit/
-- test_models_shape.lua 会把本节连 models_handler 一起切出去配桩加载，那个受限
-- 环境里没有 _M，写在节内会让切片编译成对全局 _M 的索引。
_M.models_advertise = models_api.models_advertise
_M.server_info_handler = models_api.server_info_handler

-- metrics 聚合（router/metrics_ep.lua）
_M.underscore_colons = metrics_ep.underscore_colons
_M.merge_pack = metrics_ep.merge_pack
_M.parse_prometheus = metrics_ep.parse_prometheus
_M.render_exposition = metrics_ep.render_exposition
_M.label_insert_index = metrics_ep.label_insert_index

-- 控制面与观测面（router/control.lua）
_M.create_worker_handler = control.create_worker_handler
_M.list_workers_handler = control.list_workers_handler
_M.get_worker_handler = control.get_worker_handler
_M.update_worker_handler = control.update_worker_handler
_M.delete_worker_handler = control.delete_worker_handler
_M.preflight_guard = control.preflight_guard
_M.metrics_handler = control.metrics_handler
_M.model_map_handler = control.model_map_handler
_M.mesh_observe_worker = control.mesh_observe_worker
_M.mesh_forget_worker = control.mesh_forget_worker
_M.mesh_disabled_handler = control.mesh_disabled_handler
_M.ui_logs_handler = control.ui_logs_handler
_M.ui_stats_handler = control.ui_stats_handler

-- 请求日志与收尾（router/reqlog.lua）
_M.log_inference_request = reqlog.log_inference_request
_M.finish_request = reqlog.finish_request

-- 路由表与入口（本文件）
_M.build = build
_M.handle = _M.handle

return _M
