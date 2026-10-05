-- 请求日志与统一收尾（自 router.lua 逐字搬来，只调整了 require 接线）。
--
-- P28：log_inference_request 组装一条 RequestRecord（candidates 重问不带计数
-- 旗标——counted 双计守卫），finish_request 归还限流槽/在飞槽并落观测与日志。
-- finish_request 的「先声明、后赋值」缝（原文件在推理面顶部声明、本节末尾赋值）
-- 收进本文件闭合：facade 与推理面按名取用。
local cjson = require "cjson.safe"

local observability = require "resty.luarouter.observability"

local host = require "resty.luarouter.router.host"
local respond = require "resty.luarouter.router.respond"
local candidates = require "resty.luarouter.router.candidates"
local profiles = require "resty.luarouter.router.profiles"

local _M = {}
package.loaded["resty.luarouter.router.reqlog"] = _M

local limit = host.limit
local STATUS_TEXT = respond.STATUS_TEXT
local request_id = respond.request_id
local candidates_for = candidates.candidates_for
local compact_url = candidates.compact_url
local policy_for = candidates.policy_for
local profile_for_alias = profiles.profile_for_alias
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
    local pool = candidates_for(ngx.ctx.lr_model_query,
        profile_for_alias(ngx.ctx.lr_requested_model))
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
        -- 路由阶段由 route_inference 存进 ngx.ctx 的 prompt 预览（前 50 个字符）。
        -- 之前这里是就地提取的 IIFE，但它引用的 body 是本文件的顶格全局（nil），
        -- 字段恒为 nil 从未出现在日志行里；没有预览时保持 nil 让 cjson 省略该键，
        -- 用空串占位会和「prompt 本来就是空」混淆。
        prompt_preview = ngx.ctx.lr_prompt_preview,
        -- 网关转发出去的输出预算（max_tokens / max_completion_tokens /
        -- max_output_tokens 三种写法里调用方实际给的那一个）。Ruling 2026-10-04 起
        -- 网关不再改写它，所以此值恒等于调用方请求原值；线上据此判断 400 是调用方
        -- 要多了还是网关动过手。没给则为 nil，交给 cjson 省略键。
        output_budget = ngx.ctx.lr_output_budget,
        model = model,
        requested_model = ngx.ctx.lr_requested_model or model,
        requested_effort = ngx.ctx.lr_requested_effort or cjson.null,
        -- 转发给上游的实际模型名。1 对多之后它与 model 可以不同（model 是入口代表值），
        -- 排查「这个入口的流量有没有跑到预期的那个模型上」全靠它；缺省场景两者相等。
        forwarded_model = ngx.ctx.lr_forwarded_model or cjson.null,
        effort = ngx.ctx.lr_effort or cjson.null,
        provider = labels.engine or "sglang",
        worker = compact_url(worker.url),
        -- Reuse the name the selection actually ran under (a profile can force
        -- another policy than a bare policy_for(model) would pick), falling
        -- back to the plain chain when the route phase did not stamp one.
        route_type = ngx.ctx.lr_route_type or policy_for(model):policy_name(),
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
    -- prompt/completion keep their pre-existing behaviour (an estimated row is
    -- still charged, and stays identifiable by tokens_estimated plus the
    -- /_ui/stats estimated share) so the dashboards already built on this family
    -- see no discontinuity. cached/reasoning are different: they exist only as
    -- detail fields of a backend usage object, so an estimate can never produce a
    -- non-zero one and there is nothing to flag.
    observability.record_router_tokens(model, endpoint, "prompt", prompt)
    observability.record_router_tokens(model, endpoint, "completion", completion)
    observability.record_router_tokens(model, endpoint, "cached", cached)
    observability.record_router_tokens(model, endpoint, "reasoning", reasoning)
    -- Lua-side superset: did the accounting come from an injected usage frame?
    -- (doc/gap-token-accounting.md)
    if ngx.ctx.lr_usage_injection then
        observability.record_stream_usage_injection(model, endpoint,
            ngx.ctx.lr_usage_injection)
    end
end

---Layer-1 accounting plus the request-log row, run once per request whichever
---entry point served it: `location /` goes through handle(), the /_ui chat
---aliases call it directly because ui.conf bypasses the klib dispatcher.
local finish_request  -- 拆分接线：赋值缝从原文件推理面顶部收拢到这里
finish_request = function(started, method, path)
    local duration = ngx.now() - started
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
-- 跨模块接线（拆分新增；文末；原处 5507 的 _M.finish_request 导出留在上面原样，
-- 赋的是本模块 _M）。
_M.log_inference_request = log_inference_request
_M.finish_request = finish_request
return _M
