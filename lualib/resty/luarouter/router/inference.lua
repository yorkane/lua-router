-- 推理面与公开面（自 router.lua 逐字搬来，只调整了 require 接线）。
--
-- P20 推理面（别名解析、effort 三层继承改写、输出预算纯读、两条恒「无改写」的 ctx
-- 空壳、route_inference、inference_handler、/_ui chat 管线）+ P21 公开面
-- （text_response / health 族 / readiness）。
-- apply_ctx_cap / entry_ctx_cap 是用户裁定 2026-10-04 刻意保留的空壳导出，**不是
-- 死代码清理对象**（AGENTS.md；doc/gap-virtual-models.md §4）。
-- test/unit/test_effort_layers 按字符串锚点切本文件的 effort 改写函数
-- （定义行到「输出预算纯读」一节的首行文档注释之间）配桩加载——锚点区间内的
-- 代码逐字不许动。本文件头注释刻意不逐字复写那两个锚点：find 取的是全文第一处，
-- 头注释里写出来会把切片起点抢到这里（2026-10-05 拆分自查踩过）。
--
-- 环依赖（forward 与推理面互调）按设计书 §2 用「调用期模块表解析」解开：本模块与
-- router/forward.lua 都在加载期先预登记 package.loaded、再 require 对方——拿到的
-- 是同一张表；forward() 只在函数体内经模块表成员调用，加载期不触碰成员。
local cjson = require "cjson.safe"

local _M = {}
package.loaded["resty.luarouter.router.inference"] = _M

local observability = require "resty.luarouter.observability"
local policy_utils = require "resty.luarouter.policies.utils"
local registry = require "resty.luarouter.registry"

local host = require "resty.luarouter.router.host"
local respond = require "resty.luarouter.router.respond"
local jsonutil = require "resty.luarouter.router.jsonutil"
local profiles = require "resty.luarouter.router.profiles"
local candidates = require "resty.luarouter.router.candidates"
local forwardmod = require "resty.luarouter.router.forward"
local reqlog = require "resty.luarouter.router.reqlog"

local json_encode = cjson.encode
local json_decode = cjson.decode

local cfg = host.cfg
local limit = host.limit
local store = host.store
local send_error = respond.send_error
local set_content_length = respond.set_content_length
local endpoint_label = respond.endpoint_label
local set_top_field = jsonutil.set_top_field
local patch_response_metadata = jsonutil.patch_response_metadata
local router_session_key = jsonutil.router_session_key
local text_extractors = jsonutil.text_extractors
local profile_for_alias = profiles.profile_for_alias
local profile_effort_value = profiles.profile_effort_value
local profile_entry_fallback = profiles.profile_entry_fallback
local policy_for = candidates.policy_for
local profile_policy_model = candidates.profile_policy_model
-- The per-attempt request-body edits, defined further down with the rest of the
-- body-rewriting family. Their names are forward declared here because a plain reference
-- from forward() would compile to a *global* read and hand back nil at run time rather
-- than failing at boot; their definitions below assign to these names instead of
-- declaring new locals.
--
-- Only apply_effort_policy still edits anything. apply_ctx_cap / entry_ctx_cap are inert
-- shims kept alive for their _M exports (ruling 2026-10-04: the gateway no longer writes
-- the caller's output budget) -- see their comments for the failure that removed them
-- from the hot path.
local apply_effort_policy, apply_ctx_cap, entry_ctx_cap
-- ------------------------------------------------------------------ inference plane

-- Defined further down (it needs the request-log writer); forward declared so
-- both handle() and the /_ui chat pipeline can reach it.
local finish_request
finish_request = reqlog.finish_request

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

---Virtual alias -> upstream id. Rust resolves inside
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
---@param profile table|nil @ virtual-model profile of the client-facing alias
---@param alias string|nil @ client-facing model name (profile effort lookup prefers it)
---@return string raw, string|nil requested, string|nil effective
apply_effort_policy = function(raw, body, model, profile, alias)
    local requested
    if type(body.reasoning_effort) == "string" then
        requested = body.reasoning_effort
    end
    local store_mod = store()
    if not store_mod or type(store_mod.request_effort_for) ~= "function" then
        return raw, requested, requested
    end
    -- The model_effort forced layer (LMR_MODEL_EFFORT) sits above everything,
    -- including a profile effort (gap-virtual-models 3.3): request_effort_for
    -- returns it verbatim for the resolved key, so when that layer is set the
    -- profile stays out of the way. Below it the profile sits above the model
    -- card and the global map.
    local forced
    if type(model) == "string" and model ~= "" then
        local ok_cur, cur = pcall(store_mod.current)
        if ok_cur and type(cur) == "table" and type(cur.model_effort) == "table" then
            local candidate = cur.model_effort[model]
            if type(candidate) == "string" and candidate ~= "" then
                forced = candidate
            end
        end
    end
    if forced == nil then
        local pe = profile_effort_value(profile, alias, model)
        if pe then
            if requested == pe then
                return raw, requested, pe
            end
            return set_top_field(raw, "reasoning_effort", pe), requested, pe
        end
    end
    -- 三层继承（用户裁定 2026-10-04）的中间一层在这里接上：卡片由 request_effort_for
    -- 自己按落点名查，全局层在它手上，条目层只有 router 有（profile 是按**客户端给名**
    -- 查回来的，store 那侧的按名回查拿不到这一份）。装配失败/没有任何条目声明时
    -- profile_entry_fallback 返回 nil，request_effort_for 于是只走卡片与全局两层，
    -- 转发的字节与本次接线前完全一致（AGENTS.md 硬规则「新开关缺省零行为变化」）。
    --
    -- 刻意放在上面两条早退支路**之后**：强制层与 legacy 支路命中时根本走不到这里，
    -- 不该为它们多付一次 entry_declaration 的快照读。
    local entry_fallback = profile_entry_fallback(profile, alias, model)
    local ok, effective = pcall(store_mod.request_effort_for, model, requested,
        entry_fallback)
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

---The output budget the gateway forwards, read from the request body.
---
---One value across the three protocol spellings: chat names it `max_tokens` /
---`max_completion_tokens`, /v1/responses names it `max_output_tokens`. That third
---spelling is the one the retired clamp never looked at, which is what let the gateway
---invent a budget for every responses request -- see apply_ctx_cap below.
---Asked in that order, first present value wins.
---
---Returns nil when the caller gave none: the gateway does not decide the budget on the
---client's behalf, and the log says so honestly instead of impersonating a number with 0
---or with a configured cap. Pure read -- it never touches the payload bytes.
---@param body table|nil
---@return number|nil
local function output_budget_of(body)
    if type(body) ~= "table" then
        return nil
    end
    for _, field in ipairs({ "max_tokens", "max_completion_tokens", "max_output_tokens" }) do
        local value = tonumber(body[field])
        if value ~= nil then
            return value
        end
    end
    return nil
end

---Identity: the gateway never writes the caller's output budget.
---
---Ruling 2026-10-04 replaces the old "clamp max_tokens to the context cap" with this.
---The defect: the old field table was { "max_tokens", "max_completion_tokens" } only, so
---a /v1/responses body -- whose budget field is `max_output_tokens` -- always looked like
---"the caller asked for nothing", and the `current == nil` branch then *wrote*
---`max_tokens = <the virtual entry's context_window>` into every such request. In
---production that declared value was 350000 against an engine window of 524288, so
---    524288 - 350000 = 174288
---reproduced the exact input threshold of the three production 400s, with a `completion`
---token count frozen at 350000 no caller asked for (the caller capped its own at 131072
---and that cap was verified live on both entry points). Root cause is one number standing
---in for three different quantities: `context_window` is the *declared total window*
---(input + output) an entry advertises downstream; it is not a per-request output budget
---and was never a legitimate ceiling for `max_tokens`.
---
---Now: whatever the caller sends is forwarded byte for byte, and when it sends nothing the
---gateway does not pick a number for it. `context_window` keeps parsing, persisting,
---round-tripping and rendering in the UI exactly as before -- it just stops participating
---in any max_tokens arithmetic.
---
---Both exports (here and entry_ctx_cap) stay alive as inert shims rather than being
---deleted: ui/admin/models.html and doc/agent-handover.md reference them by name, and
---dropping an export would break a documented contract for no behavioural gain.
---@return string raw, nil cap @ identity; the payload is never rewritten
apply_ctx_cap = function(raw, _body, _model, _entry)
    return raw, nil
end

---Inert since the 2026-10-04 ruling above: a virtual entry has no clamp left to speak
---with, so it always answers "nothing to clamp".
---@return nil cap
entry_ctx_cap = function(_profile)
    return nil
end

---从已解码的请求体里取第一条 user 消息的前 50 个字符，供 UI 日志页的
---「记录详情 / prompt 预览」定位用。
---位置选在 route_inference 之前：两条推理入口（inference_handler 与 ui_pipeline）
---都汇合到 route_inference，且 body 到那里必定已经是解码好的 table，
---所以只在这一个点提取一次即可覆盖全部入口。
---必须从已解码的 table 里读，绝不重新编码请求体（AGENTS.md 红线：推理体字节透传）；
---本函数纯读、O(消息数) 且只做到前 50 字符。截断必须按 UTF-8 码点计（复用
---policies/utils.utf8_head），LuaJIT 的 string.sub 按字节切，直接从多字节汉字中间
---切断会在 UI 日志页渲染出一个 U+FFFD 替换字符。
---@param body table|nil
---@return string|nil
local function extract_prompt_preview(body)
    if type(body) ~= "table" then
        return nil
    end
    local msgs = body.messages
    if type(msgs) ~= "table" then
        return nil
    end
    for _, m in ipairs(msgs) do
        if m and m.role == "user" then
            local c = m.content
            if type(c) == "string" then
                return policy_utils.utf8_head(c, 50)
            elseif type(c) == "table" then
                for _, part in ipairs(c) do
                    if type(part) == "table" then
                        -- chat 协议的 {type="text"} 与 responses 风格的
                        -- {type="input_text"} 两种形态都取 part.text。
                        if part.type == "text" or part.type == "input_text" then
                            local t = part.text
                            if type(t) == "string" then
                                return policy_utils.utf8_head(t, 50)
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
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
    -- 给 log_inference_request 留一份 prompt 预览：两处入口的 body 都在这里汇合，
    -- 记录阶段（finish_request -> log_inference_request）已经拿不到请求体，
    -- 只能在这条热路径上顺手摘一次（纯读，不改任何字节）。
    ngx.ctx.lr_prompt_preview = extract_prompt_preview(body)
    -- 同一处、同样的理由记一条「网关实际发出的输出预算」：日志阶段（finish_request ->
    -- log_inference_request）已经拿不到请求体，只能在还握着 body 的这里摘一次。
    -- 纯读，不改 payload 任何字节。修复后它恒等于调用方请求值（网关不再改写），
    -- 保留它的意义正是让线上能一眼分清「调用方自己就要多了」还是「网关动过手」。
    -- 调用方三个字段都没给时为 nil，由 cjson 省略该键，不要用 0 冒充「要了 0」。
    ngx.ctx.lr_output_budget = output_budget_of(body)
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
    -- Virtual-model profile (gap-virtual-models 3.3): keyed off the *client*
    -- name, so an alias without a profile row (plain pair or no aliases at
    -- all) is nil here and every hook below degrades to the pre-feature path.
    local profile = profile_for_alias(model)

    -- The effort ladder and the context cap used to be applied here, once, off
    -- `resolved`. They now happen inside forward(), per attempt, against the model
    -- name of the instance that will actually serve the request -- under
    -- per-candidate bindings `resolved` names only the profile's representative, so
    -- a clamp taken from it can belong to a different engine than the one being
    -- asked. /generate still opts out of both (Rust router.rs skips them too).

    ngx.ctx.lr_session = router_session_key(body)
    ngx.ctx.lr_model = resolved or "unknown"
    ngx.ctx.lr_requested_model = requested_model or resolved
    ngx.ctx.lr_model_query = resolved
    ngx.ctx.lr_endpoint = endpoint_label(route)
    ngx.ctx.lr_stream = (body.stream == true)
    -- The two effort fields are stamped by forward() once a worker is picked (the
    -- last attempt wins, since that is the exchange the client receives). Cleared
    -- here so a retried request cannot inherit a stale value from the attempt before.
    ngx.ctx.lr_requested_effort = nil
    ngx.ctx.lr_effort = nil
    -- 落点模型与 effort 同理：由 forward() 在选中实例之后盖章，末次尝试说了算。
    -- 不清零的话，一次重试落到别的模型上会留下上一次那一发的落点名。
    ngx.ctx.lr_forwarded_model = nil

    -- Only extract routing text when the policy reads it: the flattening walks
    -- every message, which random / round_robin / the hash ring never look at.
    -- Which model the policy is asked about: the name every candidate of a bound
    -- alias shares, otherwise the resolved id as before. A bound alias's clients ask
    -- for a name that never appears in the pool, so the `labels.policy` hint lookup
    -- used to miss and the alias fell through to the global policy while the
    -- instances underneath were advertising their own; Rust's PolicyRegistry keys by
    -- the model served, and this is what makes that reach an alias.
    -- Computed once, here, and handed to forward(): the extract-the-text decision and
    -- the select decision must consult the same instance, or a text-needing policy
    -- would be run without its text.
    local policy_model = profile_policy_model(profile) or resolved
    local inst = policy_for(policy_model, profile)
    -- The request log calls this field route_type; the span reuses the same value
    -- so a trace and a log row name the same decision.
    ngx.ctx.lr_route_type = inst:policy_name()
    local text = inst:needs_request_text() and text_for(route, body) or nil
    local status, response_body = forwardmod.forward(route, body, raw, resolved, text,
        ngx.req.get_headers(), profile, model, policy_model)
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

---The webui chat/completion aliases (ui.lua). The UI layer has
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

-- 跨模块接线（拆分新增；文末，不进任何单测锚点区间）。原处
-- health_generate_handler 的就近导出留在上面原样；/workers 别名管线
-- do_chat / do_completion 的 function _M. 定义也在上面（ui.lua 按 facade 名取，
-- facade 再 re-export）。forward() 的调用点经 forwardmod 模块表解析（环依赖，
-- 见 router/forward.lua 头注释）。
_M.text_for = text_for
_M.resolve_alias = resolve_alias
_M.output_budget_of = output_budget_of
_M.extract_prompt_preview = extract_prompt_preview
_M.inference_handler = inference_handler
_M.ui_pipeline = ui_pipeline
_M.route_inference = route_inference
_M.apply_effort_policy = apply_effort_policy
_M.apply_ctx_cap = apply_ctx_cap
_M.entry_ctx_cap = entry_ctx_cap
_M.text_response = text_response
_M.health_handler = health_handler
_M.readiness_handler = readiness_handler
return _M
