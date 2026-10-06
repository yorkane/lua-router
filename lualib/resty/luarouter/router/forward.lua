-- 转发主循环（自 router.lua 逐字搬来，只调整了 require 接线）。
--
-- P17 streaming 泵 + P18 重试环 + P19 forward 主循环。流式不缓冲（AGENTS.md 红线）；
-- stream_options 注入按证据分档 TTL；容量硬排除发生在策略之前（门序在
-- router/candidates.lua，逐行原样）。
--
-- 环依赖（forward 与推理面互调）按设计书 §2 用「调用期模块表解析」解开：本模块与
-- router/inference.lua 都在加载期先预登记 package.loaded、再 require 对方——拿到的
-- 是同一张表；effort 改写只在函数体内经模块表成员调用（它是本节唯一的跨模块反向
-- 引用），加载期不触碰成员。
local cjson = require "cjson.safe"

local _M = {}
package.loaded["resty.luarouter.router.forward"] = _M

local hb = require "resty.luarouter.hb"
local observability = require "resty.luarouter.observability"
local registry = require "resty.luarouter.registry"

local host = require "resty.luarouter.router.host"
local respond = require "resty.luarouter.router.respond"
local jsonutil = require "resty.luarouter.router.jsonutil"
local pump = require "resty.luarouter.router.pump"
local candidates = require "resty.luarouter.router.candidates"
local inference = require "resty.luarouter.router.inference"

local json_decode = cjson.decode

local cfg = host.cfg
local cors_apply = respond.cors_apply
local request_id = respond.request_id
local error_body = respond.error_body
local error_type_from_status = respond.error_type_from_status
local endpoint_label = respond.endpoint_label
local collect_forward_headers = respond.collect_forward_headers
local DROP_RESPONSE_HEADERS = respond.DROP_RESPONSE_HEADERS
local rewrite_model = jsonutil.rewrite_model
local merge_top_object = jsonutil.merge_top_object
local inject_dp_rank = jsonutil.inject_dp_rank
local usage_from_body = jsonutil.usage_from_body
local usage_from_chunk = jsonutil.usage_from_chunk
local estimate_tokens = jsonutil.estimate_tokens
local sse_split = jsonutil.sse_split
local sse_usage = jsonutil.sse_usage
local connect_target = pump.connect_target
local read_response_head = pump.read_response_head
local send_attempt = pump.send_attempt
local is_chunked = pump.is_chunked
local discard_body = pump.discard_body
local read_response_body = pump.read_response_body
local candidates_for = candidates.candidates_for
local card_key_for = candidates.card_key_for
local policy_for = candidates.policy_for
-- Worker marks written by the streaming usage injection (see forward()): the
-- registry keeps its own copy of this dict name because it owns the keys that
-- belong to it, and sharing one module constant across the boundary would make
-- the router depend on a registry internal for a key the registry never reads.
local WORKER_DICT_NAME = "lr_workers"
-- ------------------------------------------------------------------ streaming

--- Upper bound on one buffered SSE event while the usage-frame stripper is
--- engaged. A usage frame is a few hundred bytes; this only ever binds a stream
--- that never emits an event separator.
local MAX_SSE_FRAME = 262144

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
local function stream_response(sock, headers, kind, url, conf, strip_usage)
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
                    local p, c, a, r = usage_from_chunk(decoded)
                    if p or c then
                        found = { p or 0, c or 0, a or 0, r or 0 }
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

    -- A usage frame is only ever worth one decode pass, so stripping and the
    -- usage scan share this: the upstream bytes are always handed to note(),
    -- whether or not the client receives them. Stripping therefore cannot cost
    -- the accounting -- that is the whole point of injecting include_usage.
    --
    -- The frame splitter stays engaged for the whole stream rather than
    -- switching off when usage arrives. Flipping mid-stream would leak the frame:
    -- an engine that writes the data: line and its terminating blank line in two
    -- writes puts the captured-usage signal (line based) ahead of the frame
    -- boundary (blank-line based), so the still-partial frame would be flushed
    -- verbatim. Buffering one frame is what any correct SSE parser does anyway,
    -- and sse_event_droppable costs a plain "usage" substring test for every
    -- frame that is not a usage frame, so the ordinary path stays allocation-light
    -- apart from the split itself.
    local stripping = strip_usage and true or false
    local sse_carry = ""
    local usage_stripped = false

    local function deliver(text)
        if not ngx.print(text) then
            ok = false
            return false
        end
        ngx.flush(true)
        return true
    end

    local kept = {}

    local function emit(text)
        if not stripping then
            if not deliver(text) then
                return false
            end
            note(text)
            return true
        end
        -- The usage scanner always sees the upstream bytes, dropped or not: that
        -- is the whole point of injecting include_usage, and it means stripping
        -- can never cost the accounting.
        note(text)
        local events
        events, sse_carry = sse_split(sse_carry .. text)
        -- One write and one flush per upstream block, exactly as the unstripped
        -- pump does it. Delivering event by event would turn a block that happens
        -- to carry several frames into several round trips to the client and
        -- change the latency profile of the injection path.
        for i = 1, #kept do
            kept[i] = nil
        end
        for i = 1, #events do
            local event = events[i]
            if event.droppable then
                usage_stripped = true
            else
                kept[#kept + 1] = event.text
            end
        end
        -- Safety valve for an upstream that never terminates an event: without a
        -- blank line the carry would grow with the body and hold the client's
        -- bytes hostage. Release it verbatim and keep looking for boundaries; the
        -- cost of the valve is that one oversized frame cannot be dropped, which
        -- is the lesser harm next to truncating or stalling a response.
        if #sse_carry > MAX_SSE_FRAME then
            kept[#kept + 1] = sse_carry
            sse_carry = ""
        end
        if #kept == 0 then
            return true
        end
        local batch = table.concat(kept)
        for i = 1, #kept do
            kept[i] = nil
        end
        return deliver(batch)
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

    -- A stream that ended while a frame was still buffered (no usage ever
    -- arrived, or the upstream stopped mid-event): hand the client the bytes
    -- verbatim. Dropping them would truncate the body it was given.
    if ok and stripping and sse_carry ~= "" then
        local pending = sse_carry
        sse_carry = ""
        if not deliver(pending) then
            ok = false
        end
    end

    registry.release(sock, conf,
        registry.response_reusable(headers, reusable), kind, url)
    return ok, tail, prompt, completion, cached, reasoning, usage_stripped
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
    -- Upstream can emit its own CORS headers (a worker behind its own gateway),
    -- which would replace what cors_apply set for this response.
    cors_apply()
end

---Inference routes whose backends answer the OpenAI wire format, and therefore
---understand stream_options.include_usage. /generate and the embedding-family
---routes are excluded on purpose: /generate is SGLang-native (its SSE carries
---usage_metadata, which usage_from_object already reads), and a non-generating
---endpoint has no usage frame to ask for.
local USAGE_ROUTES = {
    ["/v1/chat/completions"] = true,
    ["/v1/completions"] = true,
    ["/v1/responses"] = true,
}

--- Marker key for "this worker rejected a body that carried stream_options",
--- kept in lr_workers next to the record it describes. A worker whose URL is
--- re-registered keeps the same id (sha224 of the URL), so the mark is given a
--- TTL instead of living forever, and any later stream that takes the injection
--- successfully clears it.
local K_STREAM_OPTIONS = "sop:"

--- How long a worker sits out the injection, and the two answers trade the same
--- risk against each other. The mark is what protects traffic -- an engine that
--- cannot parse the field answers 400, and because the contract forbids retrying
--- that 400, the request that discovered it is lost. So the field is never
--- injected at a worker that was seen refusing it, and the only question is how
--- long to believe the refusal.
---
---  * the backend named stream_options -> a day. That is a real refusal of our
---    field, and re-testing it hourly would spend one doomed request an hour.
---  * the 400 came with no such evidence -> five minutes, then try again, because
---    the more likely reading is that the client's own body was invalid and this
---    worker is fine. A wrong guess here costs one failed request per window and
---    a day of estimated (rather than exact) token counts on that worker;
---    permanently trusting the absence of evidence would cost every request to a
---    backend whose 400 text simply does not quote the field.
local STREAM_OPTIONS_TTL = 86400
local STREAM_OPTIONS_TTL_WEAK = 300

local function worker_flags()
    if not ngx or not ngx.shared then
        return nil
    end
    return ngx.shared[WORKER_DICT_NAME]
end

---Does a response body blame the field we injected? A backend that never learned
---stream_options says so by name ("Unexpected value stream_options ...",
---"'include_usage' is not supported"), which is strong enough evidence to sit the
---injection out for a day; a 400 that does not mention it is probably the
---client's own malformed body, so the worker only rests briefly.
---@param text string|nil @ buffered upstream body (a 400 on a stream arrives as SSE bytes)
---@return boolean
local function names_stream_options(text)
    if type(text) ~= "string" or text == "" then
        return false
    end
    return string.find(text, "stream_options", 1, true) ~= nil
        or string.find(text, "include_usage", 1, true) ~= nil
end

_M.names_stream_options = names_stream_options

---True when the last attempt that asked this worker for a usage frame was
---refused with 400: stop injecting for it until the mark expires or a success
---clears it.
---@param id string|nil
---@return boolean
local function stream_options_rejected(id)
    if not id then
        return false
    end
    local d = worker_flags()
    if not d then
        return false
    end
    return d:get(K_STREAM_OPTIONS .. id) ~= nil
end

---Charge a 400 that arrived while we had injected stream_options to the worker,
---and warn once per worker for the life of the mark.
---@param id string|nil
---@param url string|nil
---@param detail string @ upstream body, used to tell the operator what the backend said
---@return boolean first @ false when this worker was already marked (no second WARN)
local function note_stream_options_rejected(id, url, detail)
    if not id then
        return false
    end
    local d = worker_flags()
    if not d then
        return false
    end
    local names = names_stream_options(detail)
    local ttl = names and STREAM_OPTIONS_TTL or STREAM_OPTIONS_TTL_WEAK
    -- add (not set): only the request that actually stored the key warns, so a
    -- backend that refuses the field forever costs one line, not one per request.
    local stored, err = d:add(K_STREAM_OPTIONS .. id, 1, ttl)
    if not stored then
        if err ~= "exists" then
            observability.log_debug("stream_options marker for " .. tostring(url)
                .. " not stored: " .. tostring(err))
        end
        return false
    end
    local evidence = names
        and "the backend named the field"
        or "the body did not name the field, so this may be the client's own error"
    local excerpt = string.gsub(string.sub(tostring(detail), 1, 300), "%s+", " ")
    ngx.log(ngx.WARN, "luarouter: worker ", tostring(url), " answered 400 to the ",
        "injected stream_options.include_usage -- injection held off for ", ttl,
        "s, traffic forwarded unchanged, no retry (", evidence, "): ", excerpt)
    return true
end

---An injected usage frame that came back fine proves the worker supports the
---field, which clears any earlier mark (the operator may have swapped the engine
---behind the same URL).
---@param id string|nil
local function clear_stream_options_rejected(id)
    if not id then
        return
    end
    local d = worker_flags()
    if d then
        d:delete(K_STREAM_OPTIONS .. id)
    end
end

---True when the client itself asked for the usage frame. Such a stream is
---injected nothing and stripped nothing: the frame is the client's to keep.
---@param body table @ decoded request
---@return boolean
local function client_wants_usage(body)
    local options = body.stream_options
    if type(options) ~= "table" then
        return false
    end
    local value = options.include_usage
    return value ~= nil and value ~= false and value ~= cjson.null
end

_M.client_wants_usage = client_wants_usage
_M.stream_options_rejected = stream_options_rejected
_M.note_stream_options_rejected = note_stream_options_rejected
_M.clear_stream_options_rejected = clear_stream_options_rejected

---Forward one inference request with retries. Returns status, buffered_body_or_nil.
---For streaming requests the body is nil because it was already written out.
---@param route string
---@param body table @ decoded request body
---@param raw_body string @ original bytes
---@param model string|nil
---@param text string|nil @ routing text
---@param incoming table|nil @ request headers (defaults to the live request)
---@param alias string|nil @ client-facing model name (the effort card prefers it)
---@param policy_model string|nil @ model the policy is keyed by (defaults to `model`)
local function forward(route, body, raw_body, model, text, incoming, profile, alias,
                       policy_model)
    local conf = cfg()
    local is_stream = body.stream == true
    local endpoint = endpoint_label(route)
    if type(policy_model) ~= "string" or policy_model == "" then
        policy_model = model
    end
    if alias == nil then
        -- route_inference passes the client's own name; a caller that drives forward()
        -- directly (the /_ui chat aliases, a test) still gets the same card resolution
        -- instead of silently losing the alias layer.
        alias = ngx.ctx.lr_requested_model
    end
    -- The two request-body edits that depend on *which* engine answers, and therefore
    -- cannot be decided before the pick: the effort ladder and the context cap read
    -- their card off a model name, and under per-candidate bindings that name belongs
    -- to the chosen instance. Applying them per attempt from the *original* bytes,
    -- rather than once on the shared raw, is what makes a retry honest -- the second
    -- attempt gets the card of the engine that will actually serve it, never a clamp
    -- inherited from the one that just refused. stream_options and dp_rank are already
    -- attempt-scoped for the same reason.
    -- /generate carries its own sampling fields, so both stay off that route (Rust
    -- router.rs skips them too); payload is then byte-identical to the pre-feature path.
    local cards = route ~= "/generate"

    -- Token accounting for streams (doc/gap-token-accounting.md). Without
    -- stream_options.include_usage the OpenAI-compatible engines send no usage
    -- frame at all, so every streamed request would fall back to the byte/4
    -- estimate. The gateway asks for the frame on the client's behalf and then
    -- removes it again, which keeps the client's view byte-for-byte what it
    -- asked for while making the counters report what the backend itself said.
    local ask_usage = is_stream and USAGE_ROUTES[route] == true
        and not client_wants_usage(body)

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
        -- The selection pass: this is the one that counts cap exclusions (the log
        -- re-read below passes no flag and stays free of side effects).
        local candidates, why = candidates_for(model, profile, true)
        local worker
        if pinned then
            for i = 1, #candidates do
                if candidates[i].id == pinned then
                    worker = candidates[i]
                    break
                end
            end
            -- An explicit pin outranks the green-light preference: the narrowing is a
            -- hint for the *policy*, and a request that names its instance by id is not
            -- asking to be load-balanced away from it (candidates_for keeps the stepped-
            -- aside records on `why.stepped_aside` for exactly this). Nothing similar
            -- exists for the hard capacity gate -- a worker at its ceiling stays
            -- unreachable to a pin, which is the contract e2e_caps pins as
            -- "an explicit pin cannot resurrect a capped worker". A stepped-aside record
            -- is stamped like any survivor, and it never went through the policy, so the
            -- affinity tree is left with the green it would have chosen: the pin answers
            -- this one request, the next one follows the lights again.
            if not worker and why ~= nil then
                local aside = why.stepped_aside
                if aside then
                    for i = 1, #aside do
                        if aside[i].id == pinned then
                            worker = aside[i]
                            break
                        end
                    end
                end
            end
        end
        if not worker then
            worker = policy_for(policy_model, profile):select({
                candidates = candidates,
                routing_key = routing_key,
                request_text = text,
                headers = incoming,
                model = policy_model,
            })
        end

        if not worker then
            observability.record_router_error(model or "unknown", endpoint, "no_workers")
            observability.note_error()
            -- The body is printed by route_inference, so the JSON content type
            -- has to be claimed here; Rust answers this path as application/json.
            ngx.header["Content-Type"] = "application/json"
            -- Two shapes, two statuses, one code. An operator has to know whether the
            -- pool is empty or *full*, since the two have opposite fixes (add a worker
            -- vs raise a cap), and the code stays pinned to no_available_workers, which
            -- is what the contract asserts and what the UI keys on.
            --
            -- **用户裁定 2026-10-06 覆盖 2026-10-01 的「全到顶 503」口径**：容量到顶
            -- 不是服务不可用，是暂时没法接单——全池都抵在并发/GPU 利用率上限时答 **429**
            -- （Too Many Requests），熔断/不健康/组不服务仍走 503 原文案。理由：用户要求
            -- 「到顶不能直接 429，除非全池满」——中途任何时候有其他实例可接就转过去
            -- （candidates_for 的硬排除与绿灯优先保证了这一点），只有整组一个不剩才落
            -- 429；这与本机并发闸（limit.lua）对超限请求答 429 的姿态一致，客户端的重试
            -- 逻辑（429 可退避重试、503 常被视为宕机）也终于和真实原因对得上。
            -- No relaxation here either: queueing past the ceilings or falling back to
            -- the full workers would reproduce exactly what the caps exist to remove,
            -- and would do it under load, which is when it hurts most.
            -- Candidates that are healthy but *unavailable* (breaker open, sweep down)
            -- keep the original 503 wording untouched, so a pre-feature 503 reads
            -- exactly as it did before this feature existed.
            local status = 503
            local message = "No available workers (all circuits open or unhealthy)"
            if why ~= nil and why.capped > 0 and #candidates == 0 then
                status = 429
                message = "No available workers (" .. tostring(why.capped)
                    .. " at their concurrency or GPU-util limit)"
            elseif why ~= nil and why.group and why.refused > 0
                and #candidates == 0 then
                -- 组入口专属：这些实例是健康的，只是引擎答过「我不服务这一组里的任何
                -- 模型」。沿用旧文案会把操作员支去查熔断与巡检，而真正该查的是 targets
                -- 有没有写错名、或实例根本没加载那个模型。
                message = "No available workers (" .. tostring(why.refused)
                    .. " healthy engines serve none of the mapped models)"
            end
            ngx.status = status
            return status, error_body(status, "no_available_workers", message)
        end

        ngx.ctx.lr_worker = worker
        hold_load(worker)

        -- Two places the chosen instance gets to speak for itself: the forwarded model
        -- name is the *bound* one (a candidate may serve a model its record does not
        -- head with), and the cards are looked up under that same name. With no binding
        -- this is the pre-feature expression verbatim -- worker.model_id, and no card
        -- rewrite at all on /generate.
        local bound = worker.lr_bound_model
        -- rewrite_model takes the *forwarding* name, which must be a real engine model,
        -- never the entry's own name: record.model_id was stamped with the entry name for
        -- the policy tree (see candidates_for), so falling back to it here would send
        -- `{"model":"<virtual-name>"}` upstream. lr_bound_model is set for every group
        -- candidate, so a group request can never hit the fallback with a stamped record.
        -- The forwarding name must be a real engine model, never the entry's own name:
        -- record.model_id was stamped with the entry name for the policy tree, so a group
        -- candidate must not fall back to it. It cannot: the group gate always resolves a
        -- binding for a surviving candidate (either the operator's, or the first group
        -- name the engine will take), so `bound` is set whenever the stamp is.
        local payload = rewrite_model(raw_body, bound or worker.model_id)
        -- 组入口的日志必须说出「这一发到底落在哪个实际模型上」：行上的 model 是代表值
        -- （组头），策略把它整组当一棵树，于是同一个入口的 N 发请求在日志里看起来一模一样。
        -- 这个字段只记录、不参与任何转发决策（转发名就是上面 rewrite 用的那个）。
        -- legacy 路径下它等于选中实例自己的 model_id，与旧行为一致，只是多了一个可查字段。
        ngx.ctx.lr_forwarded_model = bound or worker.model_id
        if cards then
            local key = card_key_for(profile, model, worker, bound)
            local effort_raw, requested_effort, effective_effort =
                inference.apply_effort_policy(payload, body, key, profile, alias)
            -- Ruling 2026-10-04: no clamp step at all. The output budget is the
            -- caller's -- chat names it max_tokens / max_completion_tokens, responses
            -- names it max_output_tokens -- and the gateway forwards it untouched, so
            -- what the engine rejects is what the client asked for, never a number we
            -- manufactured. The former apply_ctx_cap call sat here; see its comment for
            -- why it is gone (context_window is a declared total window, not a budget).
            payload = effort_raw
            -- The last attempt's numbers are the ones logged, because that is the
            -- exchange the client actually received.
            ngx.ctx.lr_requested_effort = requested_effort
            ngx.ctx.lr_effort = effective_effort
        end
        -- Per attempt and not per request: the mark that turns the injection off
        -- belongs to the selected worker, and a retry lands on a different one.
        local inject_usage = ask_usage and not stream_options_rejected(worker.id)
        if inject_usage then
            local merged, changed = merge_top_object(payload, "stream_options",
                "include_usage", true)
            if changed then
                payload = merged
            else
                -- The client's own body already pins stream_options to something
                -- we must not rewrite; nothing to strip either.
                inject_usage = false
            end
        end
        -- A DP-aware engine needs to know which shard a call belongs to, so the
        -- forwarded body names it as a top-level member -- the same
        -- data_parallel_rank Rust writes in http/router.rs:575-617. Gated on
        -- cfg().dp_aware because that is Rust's switch too: a rank field left on a
        -- record by a hand-written POST /workers must not start rewriting bodies on
        -- a deployment that never opted in. The splice is byte-preserving, and a
        -- worker without dp_rank keeps the client's body exactly as sent.
        if cfg().dp_aware then
            payload = (inject_dp_rank(payload, worker))
        end
        local forward_headers = collect_forward_headers(worker)
        forward_headers["content-length"] = tostring(#payload)

        local response, conn_err = send_attempt(worker, "POST", route, payload,
            forward_headers, is_stream and "stream" or "forward")
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
            -- 流量就是健康的证明：touch 一下，健康巡检会跳过它
            if registry.touch_active then
                registry.touch_active(worker.id)
            end

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
                local stream_ok, tail, prompt, completion, cached, reasoning,
                    usage_stripped =
                    stream_response(response.sock, response.headers,
                        response.kind, worker.url, conf, inject_usage)
                release_load(worker)
                hb.record_outcome(worker.id, stream_ok and status < 400)
                if not stream_ok then
                    observability.record_worker_error(worker.url, "backend_error")
                end
                if inject_usage then
                    if status == 400 and names_stream_options(tail) then
                        -- The backend named the field we added, so the refusal is
                        -- about the injection: stop asking this worker for it.
                        -- Attribution is deliberately evidence-gated -- a client
                        -- body that is invalid for other reasons must not cost a
                        -- healthy worker its accounting for a day.
                        note_stream_options_rejected(worker.id, worker.url, tail)
                        ngx.ctx.lr_usage_injection = "rejected"
                    else
                        clear_stream_options_rejected(worker.id)
                        ngx.ctx.lr_usage_injection = usage_stripped
                            and "stripped" or "passed_through"
                    end
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
-- 跨模块接线（拆分新增；文末；原处 names_stream_options / client_wants_usage /
-- stream_options_* 的就近导出留在上面原样，赋的是本模块 _M）。
_M.forward = forward
_M.stream_response = stream_response
_M.hold_load = hold_load
_M.release_load = release_load
return _M
