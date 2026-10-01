-- OpenTelemetry tracing for the Lua router (doc/gap-otel.md).
--
-- Reference implementation: gateway/src/observability/otel_trace.rs. The Rust
-- gateway builds an opentelemetry-sdk TracerProvider with a BatchSpanProcessor
-- (500 ms scheduled delay, max export batch 64), a Resource carrying
-- service.name="smg", an instrumentation scope named "smg"
-- (provider.tracer("smg")), and a W3C TraceContextPropagator whose
-- inject_trace_context_http is called once per outbound attempt
-- (routers/http/router.rs:382, pd_router.rs).
--
-- What this module reproduces, and where it deliberately differs:
--
--   * propagation  W3C `traceparent` only. `tracestate` needs no work here: the
--                  Rust propagator does not create it either, and
--                  routers/header_utils.rs already lists it as a forwarded
--                  header, so router.lua passes the caller's value upstream in
--                  both implementations.
--   * span names   the request span is `http_request` with
--                  method/uri/version/request_id/status_code/latency/error/
--                  module="smg", copied from middleware.rs:277 (RequestSpan) and
--                  the values recorded in ResponseLogger (middleware.rs:350-351:
--                  status_code as u16, latency in microseconds). The optional
--                  per-attempt child span is `upstream_forward`; Rust creates no
--                  HTTP child span at all - it emits RequestSentEvent /
--                  RequestReceivedEvent *events* inside the parent - and only the
--                  gRPC plane has a real child span, `grpc_generate`
--                  (grpc/common/stages/request_execution.rs:92).
--   * transport    OTLP/HTTP with the protobuf JSON encoding, POSTed to
--                  SMG_OTLP_TRACES_ENDPOINT (default http://127.0.0.1:4318/v1/traces).
--                  Rust uses OTLP/gRPC against localhost:4317. Hand-rolling
--                  HTTP/2 + HPACK + protobuf wire format on a cosocket is not a
--                  bet to put on the data plane, so HTTP/JSON is the shipped
--                  transport and the collector's 4318 listener is the target. A
--                  bare `host:port` is still accepted (normalized to
--                  http://host:port/v1/traces) so an operator can paste the Rust
--                  value verbatim and read the WARN line naming the port to use.
--   * timing       nginx's cached clock is millisecond resolution, so
--                  {start,end}TimeUnixNano are ms x 1e6 and the `latency`
--                  attribute keeps Rust's microseconds with its last three digits
--                  always zero. Rust reports true nanoseconds.
--   * flush        a self-rescheduling ngx.timer.at chain per worker (the batch
--                  interval), plus an immediate wake-up once the buffer reaches
--                  the batch size. OpenResty 1.31.1.1 has no ngx.on_exit, so the
--                  process-exit flush rides on the same chain noticing
--                  ngx.worker.exiting(): verified empirically that a cosocket POST
--                  still lands at that point (nginx logs "exiting" before the
--                  worker returns, so the socket is still usable).
--   * failure      two attempts per batch, then the batch is dropped and counted,
--                  and a streak of failures stretches the next tick so a dead
--                  collector costs almost nothing. No part of the export path is
--                  reachable from a request (a request only appends to a Lua
--                  table), so tracing can neither add latency nor fail a request.
--
-- Config: SMG_ENABLE_TRACE / SMG_OTLP_TRACES_ENDPOINT / SMG_TRACE_* are captured
-- in init_by_lua by resty.luarouter.init and handed to .configure() explicitly -
-- the same capture-then-pass pattern SMG_MESH_* uses, chosen because
-- resty.luarouter.config is another module's ownership. The names are also
-- declared with `env` in all three shipped configs, so os.getenv still resolves
-- them inside a worker for probes and for this file's own fallback path.

local cjson = require "cjson.safe"

local _M = { _VERSION = "0.1.0" }

local json_encode = cjson.encode

-- Per-worker span buffer. Deliberately plain Lua state rather than a shared dict:
-- a span belongs to the process that recorded it and that process exports it, so
-- nothing needs to cross the fork. `flushing` coalesces wake-ups and
-- `timer_running` keeps exactly one batch chain per worker.
local queue = {}
local flushing = false
local timer_running = false

-- ------------------------------------------------------------------ knobs

local DEFAULT_ENDPOINT = "http://127.0.0.1:4318/v1/traces"
-- What Rust documents and defaults to (main.rs:563 --otlp-traces-endpoint,
-- config/types.rs:498 TraceConfig::default).
local RUST_DEFAULT_ENDPOINT = "localhost:4317"

local state = {
    configured = false,
    enabled = false,
    endpoint = DEFAULT_ENDPOINT,
    normalized = DEFAULT_ENDPOINT,
    host = "127.0.0.1",
    port = 4318,
    path = "/v1/traces",
    tls = false,
    transport = "http/json",
    batch_size = 64,
    interval_ms = 500,
    timeout_ms = 2000,
    sample_ratio = 1.0,
    max_queue = 1024,
    invalid_reason = nil,
}

---Normalize one endpoint value into host / port / path / tls.
---
---Accepts a full URL (http://, https://, and the OTel grpc:// / grpcs:// spellings
---folded onto HTTP) or the Rust `host:port` form. Returns nil plus a reason for
---the shapes Rust's validate_trace() rejects (empty host, port outside 1-65535,
---no port at all when nothing else can supply one).
---@param value string|nil
---@return table|nil target, string|nil reason
local function parse_endpoint(value)
    if type(value) ~= "string" then
        return nil, "empty endpoint"
    end
    local text = value:match("^%s*(.-)%s*$")
    if text == "" then
        return nil, "empty endpoint"
    end
    local scheme, rest = text:match("^(%a[%a%d+%-%.]*)://(.*)$")
    local tls = false
    if scheme then
        local lower = scheme:lower()
        if lower == "http" then
            tls = false
        elseif lower == "https" or lower == "grpcs" then
            tls = true
        elseif lower == "grpc" then
            tls = false
        else
            return nil, "unsupported scheme " .. scheme
        end
        text = rest
    end
    if text == "" then
        return nil, "host part cannot be empty"
    end
    -- Authority / path split. A path is honoured (collectors behind a reverse
    -- proxy use one); a bare or root path falls back to the OTLP default.
    local authority = text
    local path = "/v1/traces"
    local slash = string.find(text, "/", 1, true)
    if slash then
        authority = text:sub(1, slash - 1)
        path = text:sub(slash)
        if path == "/" or path == "" then
            path = "/v1/traces"
        end
    end
    if authority == "" then
        return nil, "host part cannot be empty"
    end
    local host, port
    if authority:sub(1, 1) == "[" then
        -- IPv6 literal: [::1]:4318 or [::1]
        host = authority:match("^%[([^%]]+)%]")
        if not host then
            return nil, "unbalanced IPv6 literal in endpoint"
        end
        port = authority:match("^%[[^%]]+%]:(%d+)$")
    else
        host, port = authority:match("^(.-):(%d+)$")
        if not host then
            host, port = authority, nil
        end
    end
    if not host or host == "" then
        return nil, "host part cannot be empty"
    end
    if port then
        port = tonumber(port)
    elseif scheme then
        -- http(s)://host with no port: the URL default.
        port = tls and 443 or 80
    else
        return nil, "expected format <host>:<port>, e.g. otel-collector:4318"
    end
    if not port or port < 1 or port > 65535 then
        return nil, "expected format <host>:<port>, e.g. otel-collector:4318"
    end
    return { host = host, port = port, path = path, tls = tls }
end

_M.parse_endpoint = parse_endpoint

---A hint for the operator who pasted the Rust endpoint value: this router speaks
---OTLP/HTTP, so a 4317 target (Rust's default, and the conventional OTLP/gRPC
---port) will connect and then fail to parse a response.
---@param conf table
---@return string|nil warning
function _M.transport_warning(conf)
    conf = conf or _M.config()
    if conf.invalid_reason then
        return "SMG_OTLP_TRACES_ENDPOINT is unusable (" .. conf.invalid_reason
            .. "); tracing is off"
    end
    if not conf.enabled then
        return nil
    end
    if conf.port == 4317 or string.find(conf.endpoint, "^grpc[s]?://", 1) then
        return "SMG_OTLP_TRACES_ENDPOINT=" .. conf.endpoint .. " names the OTLP/gRPC "
            .. "port, but lua-router exports OTLP/HTTP JSON over "
            .. conf.normalized .. " (Rust uses gRPC on 4317): point it at the "
            .. "collector's 4318 listener, e.g. http://127.0.0.1:4318/v1/traces"
    end
    return nil
end
_M.DEFAULT_ENDPOINT = DEFAULT_ENDPOINT
_M.RUST_DEFAULT_ENDPOINT = RUST_DEFAULT_ENDPOINT

---Apply the knobs. Called once from init_by_lua with the captured values, and
---directly by the unit gate / probes with an explicit table.
---@param opts table|nil @{enable, endpoint, batch_size, interval_ms, timeout_ms,
---  sample_ratio, max_queue}; anything absent falls back to os.getenv, then to the default
---@return table state
function _M.configure(opts)
    opts = opts or {}
    local function pick(name, env_name)
        if opts[name] ~= nil then
            return opts[name]
        end
        if not (_G.os and os.getenv) then
            return nil
        end
        local value = os.getenv(env_name)
        if value == nil or value == "" then
            return nil
        end
        return value
    end
    local function as_bool(value, default)
        if type(value) == "boolean" then
            return value
        end
        if value == nil then
            return default
        end
        value = tostring(value):lower()
        return value == "1" or value == "true" or value == "yes" or value == "on"
    end
    local function as_num(value, default)
        local parsed = tonumber(value)
        if parsed == nil then
            return default
        end
        return parsed
    end

    local raw_endpoint = pick("endpoint", "SMG_OTLP_TRACES_ENDPOINT")
    local target, reason
    if raw_endpoint == nil then
        -- Unset: this router's own default, which is the HTTP/JSON port rather
        -- than Rust's 4317, because that is the transport actually spoken here.
        target = parse_endpoint(DEFAULT_ENDPOINT)
        raw_endpoint = DEFAULT_ENDPOINT
    else
        target, reason = parse_endpoint(raw_endpoint)
    end

    state.enabled = as_bool(pick("enable", "SMG_ENABLE_TRACE"), false)
    state.endpoint = raw_endpoint
    if target then
        state.normalized = (target.tls and "https://" or "http://")
            .. target.host .. ":" .. target.port .. target.path
        state.host = target.host
        state.port = target.port
        state.path = target.path
        state.tls = target.tls
        state.invalid_reason = nil
    else
        -- Rust refuses to boot on an unusable endpoint (validate_trace). Aborting
        -- init_by_lua would take the data plane down over a tracing typo, so this
        -- router does what it does for every other soft config error: tracing
        -- turns itself off, routing is untouched, and the reason is in the log.
        state.enabled = false
        state.invalid_reason = reason
    end

    state.batch_size = math.max(1, math.floor(as_num(
        pick("batch_size", "SMG_TRACE_BATCH_SIZE"), 64)))
    state.interval_ms = math.max(1, math.floor(as_num(
        pick("interval_ms", "SMG_TRACE_BATCH_INTERVAL_MS"), 500)))
    state.timeout_ms = math.max(1, math.floor(as_num(
        pick("timeout_ms", "SMG_TRACE_TIMEOUT_MS"), 2000)))
    state.sample_ratio = as_num(pick("sample_ratio", "SMG_TRACE_SAMPLE_RATIO"), 1.0)
    if state.sample_ratio < 0 then
        state.sample_ratio = 0
    elseif state.sample_ratio > 1 then
        state.sample_ratio = 1
    end
    -- Buffer ceiling: a batch leaves per tick, so the queue only grows when the
    -- collector is slower than the traffic. Past this the oldest spans are dropped.
    state.max_queue = math.max(256, math.floor(as_num(
        pick("max_queue", "SMG_TRACE_MAX_QUEUE"), state.batch_size * 16)))
    state.configured = true
    return state
end

function _M.config()
    if not state.configured then
        _M.configure()
    end
    return state
end

function _M.is_enabled()
    if not state.configured then
        _M.configure()
    end
    return state.enabled
end

-- ------------------------------------------------------------------ ids

local HEX = "0123456789abcdef"
local rand_mod

---Random bytes, CSPRNG first. The same three-tier ladder history.random_bytes
---uses (OpenSSL, then seeded math.random), restated here rather than imported so
---the module stays loadable in a bare luajit probe with no history dependency.
---@param n_bytes number
---@return string|nil, string|nil
local function random_bytes(n_bytes)
    if not rand_mod then
        local ok, mod = pcall(require, "resty.openssl.rand")
        rand_mod = (ok and type(mod) == "table" and mod.bytes) and mod or false
    end
    if rand_mod then
        local bytes, err = rand_mod.bytes(n_bytes)
        if bytes then
            return bytes
        end
        return nil, "rand: " .. tostring(err)
    end
    if not _M._seeded then
        _M._seeded = true
        local clock = (_G.ngx and _G.ngx.now and _G.ngx.now() or os.time()) * 1000
        local pid = (_G.ngx and _G.ngx.worker and _G.ngx.worker.pid
            and _G.ngx.worker.pid()) or 0
        math.randomseed(math.floor(clock) + pid)
    end
    local out = {}
    for _ = 1, n_bytes do
        out[#out + 1] = string.char(math.random(0, 255))
    end
    return table.concat(out)
end

---@param bytes string
---@return string
local function to_hex(bytes)
    local out = {}
    for i = 1, #bytes do
        local byte = string.byte(bytes, i)
        out[2 * i - 1] = HEX:sub(math.floor(byte / 16) + 1, math.floor(byte / 16) + 1)
        out[2 * i] = HEX:sub(byte % 16 + 1, byte % 16 + 1)
    end
    return table.concat(out)
end

---Lowercase hex of n_bytes random bytes: 16 for a trace id, 8 for a span id.
---@param n_bytes number
---@return string|nil
local function random_hex(n_bytes)
    local bytes = random_bytes(n_bytes)
    if not bytes then
        return nil
    end
    local hex = to_hex(bytes)
    -- A zero id is invalid in W3C (an all-zero trace id means "invalid"), so
    -- nudge one in. Probability is 2^-128; this branch is paranoia, not a fix.
    if hex == string.rep("0", #hex) then
        hex = string.rep("0", #hex - 1) .. "1"
    end
    return hex
end

_M.random_hex = random_hex

local ZERO_TRACE = string.rep("0", 32)
local ZERO_SPAN = string.rep("0", 16)

-- ------------------------------------------------------------------ W3C context

---Parse one `traceparent` value per the W3C Trace Context level-1 grammar.
---
---Returns nil - meaning "generate a fresh context" - for a wrong field count, a
---non-hex field, version "ff", an all-zero trace id, an all-zero parent id, or a
---short field. A version above "00" is accepted with its extra trailing fields
---ignored, which is what a level-1 parser is required to do.
---@param value string|nil
---@return table|nil ctx@{version,trace_id,span_id,flags,sampled}
function _M.parse_traceparent(value)
    if type(value) ~= "string" then
        return nil
    end
    local text = value:lower()
    local version, trace_id, span_id, flags =
        text:match("^([0-9a-f][0-9a-f])%-([0-9a-f]+)%-([0-9a-f]+)%-([0-9a-f]+)")
    if not version then
        return nil
    end
    if version == "ff" then
        return nil
    end
    if #trace_id ~= 32 or trace_id == ZERO_TRACE then
        return nil
    end
    if #span_id ~= 16 or span_id == ZERO_SPAN then
        return nil
    end
    if #flags ~= 2 then
        return nil
    end
    local flag_byte = tonumber(flags, 16)
    if not flag_byte then
        return nil
    end
    return {
        version = version,
        trace_id = trace_id,
        span_id = span_id,
        flags = flags,
        sampled = bit.band(flag_byte, 0x01) == 1,
    }
end

---Render the `traceparent` value for a header. Version is pinned to "00": this is
---a level-1 producer, and re-emitting an inherited higher version would claim
---fields we do not write.
---@param ctx table
---@return string|nil
function _M.render_traceparent(ctx)
    if not ctx or not ctx.trace_id or not ctx.span_id then
        return nil
    end
    return "00-" .. ctx.trace_id .. "-" .. ctx.span_id .. "-" .. (ctx.flags or "00")
end

---OTLP `flags` for one context: bit 0 is the sampled flag taken from traceparent
---(so an inherited decision travels on), and bit 8 records "this is a root span"
---the way OTTL's RootedSpan does.
local function otlp_flags(ctx, is_root)
    local byte = tonumber(ctx.flags or "00", 16) or 0
    local flags = bit.band(byte, 0x01)
    if is_root then
        flags = bit.bor(flags, 0x100)
    end
    return flags
end

---The root bit belongs to the span, not to the trace: a child that borrowed the
---parent's flags would claim to be a root span as well (OTLP Span.flags bit 8 is
---"root status", 1 only when the span has no parent).

-- ------------------------------------------------------------------ stats

local stats = {
    requests = 0,
    sampled = 0,
    inherited = 0,
    generated = 0,
    recorded = 0,
    dropped = 0,
    exports_ok = 0,
    exports_fail = 0,
    export_retries = 0,
    batches = 0,
    fail_streak = 0,
    last_error = nil,
    last_export_ms = nil,
}

local observability

---The Prometheus family, required lazily and cached: this module has to keep
---working when the caller is a bare luajit probe with no observability dict.
local function obs()
    if observability == nil then
        local ok, mod = pcall(require, "resty.luarouter.observability")
        observability = (ok and type(mod) == "table" and mod.counter) and mod or false
    end
    return observability
end

local function metric(metric_name, pairs, delta)
    local mod = obs()
    if not mod then
        return
    end
    pcall(mod.counter, metric_name, pairs, delta)
end

function _M.stats()
    local conf = _M.config()
    return {
        enabled = conf.enabled,
        transport = conf.transport,
        endpoint = conf.normalized,
        endpoint_raw = conf.endpoint,
        invalid_reason = conf.invalid_reason or cjson.null,
        batch_size = conf.batch_size,
        interval_ms = conf.interval_ms,
        timeout_ms = conf.timeout_ms,
        sample_ratio = conf.sample_ratio,
        max_queue = conf.max_queue,
        queued = #queue,
        requests = stats.requests,
        sampled = stats.sampled,
        inherited = stats.inherited,
        generated = stats.generated,
        recorded = stats.recorded,
        dropped = stats.dropped,
        batches = stats.batches,
        exports_ok = stats.exports_ok,
        exports_fail = stats.exports_fail,
        export_retries = stats.export_retries,
        fail_streak = stats.fail_streak,
        last_error = stats.last_error or cjson.null,
        last_export_ms = stats.last_export_ms or cjson.null,
        timer_running = timer_running,
        pid = (_G.ngx and _G.ngx.worker and _G.ngx.worker.pid and _G.ngx.worker.pid()) or 0,
    }
end

function _M.reset_stats()
    for key in pairs(stats) do
        stats[key] = type(stats[key]) == "number" and 0 or nil
    end
    stats.requests = 0
    for i = #queue, 1, -1 do
        queue[i] = nil
    end
end

-- ------------------------------------------------------------------ request context

local SPAN_KEY = "lr_trace"
_M.SPAN_KEY = SPAN_KEY

---Open the request span. Idempotent per request and a no-op when tracing is off,
---so every entry point can call it unconditionally.
---
---This is the counterpart of Rust's TraceLayer + RequestIdLayer pair: Rust lets
---the propagator extract implicitly when the span is created, so the caller's
---traceparent becomes the parent; here that step is explicit and the result rides
---on ngx.ctx for the rest of the request.
---@param headers table|nil @ request headers (defaults to the live request)
---@return table|nil trace
function _M.begin(headers)
    local conf = _M.config()
    if not conf.enabled then
        return nil
    end
    if not (_G.ngx and ngx.ctx) then
        return nil
    end
    local trace = ngx.ctx[SPAN_KEY]
    if trace then
        return trace
    end
    headers = headers or ngx.req.get_headers()
    local incoming = headers["traceparent"]
    if type(incoming) == "table" then
        incoming = incoming[1]
    end
    local parent = _M.parse_traceparent(incoming)
    local source
    if parent then
        source = "inherited"
    else
        source = "generated"
        -- Head-based sampling: the decision is made once, here, and travels on the
        -- flags byte. Rust leaves this to the SDK's parentbased_always_on sampler,
        -- which samples everything - ratio 1 (the default) reproduces that.
        local sampled
        if conf.sample_ratio >= 1 then
            sampled = true
        elseif conf.sample_ratio <= 0 then
            sampled = false
        else
            sampled = math.random() < conf.sample_ratio
        end
        local trace_id = random_hex(16)
        local span_id = random_hex(8)
        if not trace_id or not span_id then
            -- No entropy: stay out of the way rather than invent a deterministic
            -- trace id that would collide across workers.
            conf.enabled = false
            stats.last_error = "no entropy source for trace ids"
            return nil
        end
        parent = {
            trace_id = trace_id,
            span_id = span_id,
            flags = sampled and "01" or "00",
            sampled = sampled,
        }
    end
    -- Our own span id is always new, even for an inherited trace: re-injecting the
    -- caller's id would make the worker its own parent.
    local own = random_hex(8)
    if not own then
        return nil
    end
    trace = {
        trace_id = parent.trace_id,
        -- Only an inherited context has a parent. Leaving the generated branch with
        -- `parent.span_id` would publish a random non-zero parentSpanId, which makes
        -- a root span look like an orphan in every collector.
        parent_span_id = (source == "inherited") and parent.span_id or nil,
        span_id = own,
        flags = parent.flags,
        sampled = parent.sampled,
        is_root = source == "generated",
        name = "http_request",
        started_ms = math.floor(ngx.now() * 1000),
        children = {},
        source = source,
        ended = false,
    }
    trace.traceparent = _M.render_traceparent(trace)
    ngx.ctx[SPAN_KEY] = trace
    stats.requests = stats.requests + 1
    if trace.sampled then
        stats.sampled = stats.sampled + 1
        stats.recorded = stats.recorded + 1
    end
    if source == "inherited" then
        stats.inherited = stats.inherited + 1
    else
        stats.generated = stats.generated + 1
    end
    metric("smg_otel_requests_total", {
        { "sampled", trace.sampled and "true" or "false" },
        { "source", source },
    })
    return trace
end

---The active trace, or nil. Callers must not care which case they are in.
---@return table|nil
function _M.current()
    if not _M.is_enabled() then
        return nil
    end
    if not (_G.ngx and ngx.ctx) then
        return nil
    end
    return ngx.ctx[SPAN_KEY]
end

---Inject the current span context into outbound headers, i.e. Rust's
---inject_trace_context_http: `insert` semantics, so a caller's traceparent that
---arrived at the router is overwritten with the router's own span and the worker
---sees the router as its parent. When tracing is off (or the request never got a
---context) the caller's header is left exactly as router.lua copied it.
---@param headers table
---@return table headers
function _M.inject(headers)
    local trace = _M.current()
    if not trace or not trace.traceparent then
        return headers
    end
    headers["traceparent"] = trace.traceparent
    return headers
end

---Alias used by the gRPC plane, where Rust injects into tonic MetadataMap
---(inject_trace_context_grpc). The Lua gRPC proxy carries its metadata as a header
---table, so the injection is the same operation; the name exists so call sites
---read like the Rust code they were ported from.
---@param metadata table
---@return table metadata
function _M.inject_grpc_metadata(metadata)
    return _M.inject(metadata)
end

---Response header value, i.e. what the client gets back. Rust does not answer
---with a traceparent at all (it only injects towards workers), so this is the one
---place the Lua router is deliberately more talkative: without it an e2e check
---cannot see the generated ids from the client side, and the value costs one
---header on a response that already carries x-request-id.
---@return string|nil
function _M.response_traceparent()
    local trace = _M.current()
    return trace and trace.traceparent or nil
end

---Echo the caller's own traceparent on a response that has no span of ours.
---
---Every inference route opens a span and answers with that context (begin /
---apply_response_headers); the non-span routes - /health, /workers, the control
---plane - would otherwise answer with a random id that no collector holds a span
---for, so they just pass the incoming value back when it is valid.
---@return string|nil echoed
function _M.echo_request_traceparent()
    if not _M.is_enabled() or not (_G.ngx and ngx.ctx) then
        return nil
    end
    if ngx.ctx[SPAN_KEY] or ngx.ctx[SPAN_KEY .. "_echoed"] then
        -- A span of ours is already in play: its context is the one begin() and
        -- apply_response_headers put on the response, and it is strictly better
        -- than the caller's (it names the router as the parent).
        return nil
    end
    ngx.ctx[SPAN_KEY .. "_echoed"] = true
    local headers = ngx.req.get_headers()
    local incoming = headers and headers["traceparent"]
    if type(incoming) == "table" then
        incoming = incoming[1]
    end
    local parsed = _M.parse_traceparent(incoming)
    if not parsed then
        return nil
    end
    local text = _M.render_traceparent(parsed)
    pcall(function()
        ngx.header["traceparent"] = text
    end)
    return text
end

-- ------------------------------------------------------------------ attributes

local function attr_string(key, value)
    return { key = key, value = { stringValue = tostring(value) } }
end

local function attr_int(key, value)
    return { key = key, value = { intValue = tostring(math.floor(tonumber(value) or 0)) } }
end

local function attr_bool(key, value)
    return { key = key, value = { boolValue = value and true or false } }
end

_M.attr_string = attr_string
_M.attr_int = attr_int
_M.attr_bool = attr_bool

---Build the request span's attributes from the router's own request bookkeeping
---(ngx.ctx.lr_*), which is what makes the span agree with /_ui/logs and /metrics
---rather than being a second, contradicting view of the same request.
---@param trace table
---@param extra table|nil @ {method=, path=, status=, error_code=}
---@return table attributes
local function collect_attrs(trace, extra)
    local out = {}
    local method = (extra and extra.method) or ngx.req.get_method()
    local path = (extra and extra.path) or (ngx.var and ngx.var.uri) or "/"
    -- http.request.method / http.* would be the semconv names; these are Rust's
    -- tracing field names from middleware.rs, which is what the parity contract
    -- asks for. Both spellings stay greppable in a collector.
    out[#out + 1] = attr_string("method", method)
    out[#out + 1] = attr_string("uri", (ngx.var and ngx.var.request_uri) or path)
    out[#out + 1] = attr_string("path", path)
    out[#out + 1] = attr_string("version", "HTTP/1.1")
    out[#out + 1] = attr_string("module", "smg")
    if ngx.ctx.lr_request_id then
        out[#out + 1] = attr_string("request_id", ngx.ctx.lr_request_id)
    end
    local status = (extra and extra.status) or ngx.status
    if status then
        out[#out + 1] = attr_int("status_code", status)
    end
    if trace.duration_ms then
        -- Rust records latency in microseconds (middleware.rs:350-351).
        out[#out + 1] = attr_int("latency", trace.duration_ms * 1000)
        out[#out + 1] = attr_int("duration_ms", trace.duration_ms)
    end
    if status and status >= 400 then
        local code = extra and extra.error_code
        if code == nil then
            code = ngx.ctx.lr_error_code
        end
        out[#out + 1] = attr_string("error", (code ~= nil and code ~= "") and code or "error")
    end
    local model = ngx.ctx.lr_model or ngx.ctx.lr_requested_model
    out[#out + 1] = attr_string("model", model or "unknown")
    if ngx.ctx.lr_endpoint then
        out[#out + 1] = attr_string("endpoint", ngx.ctx.lr_endpoint)
    end
    if ngx.ctx.lr_stream ~= nil then
        out[#out + 1] = attr_bool("stream", ngx.ctx.lr_stream)
    end
    local worker = ngx.ctx.lr_worker
    if type(worker) == "table" and worker.url then
        out[#out + 1] = attr_string("worker", worker.url)
    end
    -- Rust puts the policy name on the request-log row (router.rs:352
    -- ingest.set_route_type) rather than on the span; the Lua side reuses the same
    -- value so a trace and a /_ui/logs row name the same routing decision.
    if ngx.ctx.lr_route_type then
        out[#out + 1] = attr_string("route_type", ngx.ctx.lr_route_type)
    end
    local tokens = ngx.ctx.lr_tokens
    if type(tokens) == "table" then
        out[#out + 1] = attr_int("prompt_tokens", tokens[1] or 0)
        out[#out + 1] = attr_int("completion_tokens", tokens[2] or 0)
    end
    return out
end

-- ------------------------------------------------------------------ buffer

---Append one finished span to the batch buffer.
---@param span table
---@return boolean overflow
local function enqueue(span)
    queue[#queue + 1] = span
    local conf = _M.config()
    if #queue <= conf.max_queue then
        return false
    end
    local overflow = #queue - conf.max_queue
    for _ = 1, overflow do
        table.remove(queue, 1)
    end
    stats.dropped = stats.dropped + overflow
    metric("smg_otel_spans_total", { { "result", "dropped" } }, overflow)
    return true
end

-- ------------------------------------------------------------------ spans

---Start an optional child span (one upstream attempt). Returns nil whenever there
---is nothing to record, so call sites never branch on the feature.
---@param name string
---@return table|nil child
function _M.child_start(name)
    local trace = _M.current()
    if not trace or not trace.sampled or trace.ended then
        return nil
    end
    local id = random_hex(8)
    if not id then
        return nil
    end
    -- ngx.now() is the cached request time, so without this the child would read
    -- the same instant at both ends and every upstream span would be 0ms.
    pcall(ngx.update_time)
    local now_ms = math.floor(ngx.now() * 1000)
    return {
        name = name,
        parent = trace,
        span_id = id,
        started_ms = now_ms,
        ended_ms = now_ms,
        attrs = {},
    }
end

---Finish a child span. It is buffered with its parent, never exported on its own.
---@param child table|nil
---@param attrs table|nil
---@param status_code number|nil
function _M.child_end(child, attrs, status_code)
    if not child or not child.span_id then
        return
    end
    local trace = child.parent
    pcall(ngx.update_time)
    child.ended_ms = math.max(child.started_ms, math.floor(ngx.now() * 1000))
    local list = attrs or {}
    if status_code then
        list[#list + 1] = attr_int("status_code", status_code)
        if status_code >= 500 then
            list[#list + 1] = attr_string("error", "backend_error")
        end
    end
    child.attrs = list
    trace.children[#trace.children + 1] = child
end

---One-shot child span around a function, for the call sites that only need the
---wall clock. `attrs` may be a function so the status of the wrapped call can be
---recorded without the caller threading it through.
---@param name string
---@param attrs table|function|nil
---@param fn function
---@return any results...
function _M.with_child(name, attrs, fn)
    local child = _M.child_start(name)
    local ok, first, second = pcall(fn)
    local resolved = attrs
    if type(attrs) == "function" then
        resolved = attrs(ok, first, second) or {}
    end
    if type(resolved) == "table" then
        _M.child_end(child, resolved)
    else
        _M.child_end(child)
    end
    if not ok then
        error(first, 0)
    end
    return first, second
end

---Close the request span and buffer it. Called from finish_request on the normal
---path and from log_by_lua (init.on_log) for requests whose handler never got
---there - the same leak-sweep role the load guards play.
---@param duration_s number|nil
---@param extra table|nil
---@return boolean closed
function _M.finish(duration_s, extra)
    if not (_G.ngx and ngx.ctx) then
        return false
    end
    local trace = ngx.ctx[SPAN_KEY]
    if not trace or trace.ended then
        return false
    end
    trace.ended = true
    local now_ms = math.floor(ngx.now() * 1000)
    local duration = duration_s
    if duration == nil then
        duration = (now_ms - trace.started_ms) / 1000
    end
    trace.duration_ms = math.max(0, math.floor(duration * 1000))
    trace.ended_ms = trace.started_ms + trace.duration_ms
    if not trace.sampled then
        -- Not sampled: context propagates, nothing is recorded. That is OTel's
        -- contract, and it is why a ratio below 1 still yields coherent traces.
        return true
    end
    if not trace.attributes then
        local ok, attrs = pcall(collect_attrs, trace, extra)
        trace.attributes = ok and attrs or {}
    end
    local status = (extra and extra.status) or (_G.ngx and ngx.status)
    -- OTLP StatusCode: 1 = OK, 2 = ERROR. Rust's spans leave status unset and put
    -- the failure in the `error` field instead; a collector keys its error views
    -- off the status code, so the Lua side sets it as well.
    if status and status >= 400 then
        trace.status = { code = 2 }
    else
        trace.status = { code = 1 }
    end
    local overflowed = enqueue(trace)
    local conf = _M.config()
    if #queue >= conf.batch_size and not flushing and not overflowed then
        -- Batch full: export now instead of waiting for the tick.
        _M.schedule_flush(0)
    end
    return true
end

---Milliseconds to a nanosecond timestamp string.
---
---The string form is required by the OTLP JSON mapping (fixed64 is emitted as a
---string), and building it by concatenation rather than arithmetic is deliberate:
---a wall-clock millisecond value times 1e6 is ~1.7e18, which is far past the 2^53
---exact-integer limit of a Lua number, so `ms * 1e6` would corrupt the low digits.
---@param ms number
---@return string
local function to_ns(ms)
    return string.format("%d", math.floor(ms)) .. "000000"
end

_M.to_ns = to_ns

---Encode spans into one OTLP/JSON ExportTraceServiceRequest.
---@param spans table
---@return string|nil json, string|nil reason
local function encode_request(spans)
    local encoded = {}
    for i = 1, #spans do
        local span = spans[i]
        local entry = {
            traceId = span.trace_id,
            spanId = span.span_id,
            name = span.name,
            -- SPAN_KIND_SERVER: this span describes an inbound request we served.
            kind = 2,
            startTimeUnixNano = to_ns(span.started_ms),
            endTimeUnixNano = to_ns(span.ended_ms),
            attributes = span.attributes or {},
            flags = otlp_flags(span, span.is_root),
        }
        if span.parent_span_id and span.parent_span_id ~= ZERO_SPAN then
            entry.parentSpanId = span.parent_span_id
        end
        if type(span.status) == "table" and span.status.code and span.status.code ~= 0 then
            entry.status = { code = span.status.code }
        end
        encoded[#encoded + 1] = entry
        local children = span.children or {}
        for j = 1, #children do
            local child = children[j]
            encoded[#encoded + 1] = {
                traceId = span.trace_id,
                spanId = child.span_id,
                parentSpanId = span.span_id,
                name = child.name,
                -- SPAN_KIND_CLIENT: the view of one outbound attempt.
                kind = 3,
                startTimeUnixNano = to_ns(child.started_ms),
                endTimeUnixNano = to_ns(child.ended_ms),
                attributes = child.attrs or {},
                -- Never a root: it has parentSpanId.
                flags = otlp_flags(span, false),
            }
        end
    end
    if #encoded == 0 then
        return nil, "no spans"
    end
    local doc = {
        resourceSpans = {
            {
                resource = {
                    attributes = {
                        -- Rust: Resource::default().merge(service.name="smg"). The
                        -- telemetry.sdk.* trio is what Resource::default() brings
                        -- over there, so the shape matches and only the values say
                        -- "lua".
                        attr_string("service.name", "smg"),
                        attr_string("telemetry.sdk.name", "lua-router"),
                        attr_string("telemetry.sdk.language", "lua"),
                        attr_string("telemetry.sdk.version", _M._VERSION),
                    },
                },
                scopeSpans = {
                    -- Rust: provider.tracer("smg") -> scope name "smg".
                    { scope = { name = "smg" }, spans = encoded },
                },
            },
        },
    }
    local text = json_encode(doc)
    if type(text) ~= "string" then
        return nil, "json encode failed: " .. tostring(text)
    end
    return text
end

_M.encode_request = encode_request

-- ------------------------------------------------------------------ exporter

---@param conf table
---@param payload string
---@return string|nil err
local function post_json_real(conf, payload)
    local registry_ok, registry = pcall(require, "resty.luarouter.registry")
    local sock = ngx.socket.tcp()
    sock:settimeouts(conf.timeout_ms, conf.timeout_ms, conf.timeout_ms)
    local opts
    if registry_ok and registry and registry.pool_opts then
        -- Derived from the shared pool helper, then the pool name is overridden: a
        -- dedicated class keeps an exporter socket out of the inference pool and
        -- vice versa. `Connection: close` below means nothing is actually pooled,
        -- which is what a flaky collector deserves.
        opts = registry.pool_opts(conf, "otel", conf.normalized)
        opts.pool = "lr:otel:" .. (conf.tls and "s" or "c") .. ":" .. conf.host .. ":" .. conf.port
    end
    local ok, err = sock:connect(conf.host, conf.port, opts)
    if not ok then
        return "connect failed: " .. tostring(err)
    end
    if registry_ok and registry and registry.tls_handshake then
        local tls_ok, terr = registry.tls_handshake(sock, conf.host, conf.tls)
        if not tls_ok then
            sock:close()
            return tostring(terr)
        end
    end
    local request = "POST " .. conf.path .. " HTTP/1.1\r\n"
        .. "Host: " .. conf.host .. ":" .. conf.port .. "\r\n"
        .. "User-Agent: lua-router/otel\r\n"
        .. "Content-Type: application/json\r\n"
        .. "Accept: application/json\r\n"
        .. "Content-Length: " .. #payload .. "\r\n"
        .. "Connection: close\r\n\r\n"
    local bytes, werr = sock:send(request)
    if not bytes then
        sock:close()
        return "send failed: " .. tostring(werr)
    end
    local sent, serr = sock:send(payload)
    if not sent then
        sock:close()
        return "send failed: " .. tostring(serr)
    end
    local status_line, rerr = sock:receive("*l")
    if not status_line then
        sock:close()
        return "no response: " .. tostring(rerr)
    end
    local status = tonumber(string.match(status_line, "^HTTP/%d%.%d%s+(%d%d%d)"))
    -- Read the declared body so the peer's message boundary is respected even
    -- though the socket is then closed rather than pooled.
    local content_length
    repeat
        local line = sock:receive("*l")
        if line and line ~= "" then
            local name, value = string.match(line, "^([%w%-]+):%s*(.*)$")
            if name and string.lower(name) == "content-length" then
                content_length = tonumber(value)
            end
        end
    until line == nil or line == ""
    if content_length and content_length > 0 then
        sock:receive(content_length)
    end
    sock:close()
    if not status then
        return "malformed status line: " .. status_line
    end
    if status >= 400 then
        return "collector answered " .. status
    end
    return nil
end

-- The seam used by _M.set_exporter; nil in production means "use the cosocket
-- exporter", and the unit gate installs a recorder here instead.
local post_json_override
local function post_json(conf, payload)
    local override = post_json_override
    if override then
        return override(conf, payload)
    end
    return post_json_real(conf, payload)
end

---Send one batch: two attempts, then drop and count.
---@return boolean ok, number count, string|nil err
local function export_batch()
    local conf = _M.config()
    local take = math.min(conf.batch_size, #queue)
    if take <= 0 then
        return true, 0
    end
    local batch = {}
    for _ = 1, take do
        batch[#batch + 1] = table.remove(queue, 1)
    end
    stats.batches = stats.batches + 1
    local payload, enc_err = encode_request(batch)
    if not payload then
        -- Unencodable input is dropped, not retried: retrying it would loop
        -- forever on the same bytes.
        stats.dropped = stats.dropped + take
        stats.last_error = tostring(enc_err)
        metric("smg_otel_spans_total", { { "result", "dropped" } }, take)
        metric("smg_otel_export_failures_total", { { "stage", "encode" } })
        return false, take, enc_err
    end
    local err
    for attempt = 1, 2 do
        if attempt > 1 then
            stats.export_retries = stats.export_retries + 1
            -- Runs only inside a timer, so this sleep never touches a request.
            ngx.sleep(0.05)
        end
        err = post_json(conf, payload)
        if not err then
            break
        end
    end
    if not err then
        stats.exports_ok = stats.exports_ok + 1
        stats.fail_streak = 0
        stats.last_export_ms = math.floor(ngx.now() * 1000)
        metric("smg_otel_exports_total", { { "result", "success" } })
        metric("smg_otel_spans_total", { { "result", "exported" } }, take)
        return true, take
    end
    stats.exports_fail = stats.exports_fail + 1
    stats.dropped = stats.dropped + take
    stats.fail_streak = stats.fail_streak + 1
    stats.last_error = tostring(err)
    local stage = string.match(tostring(err), "^(%a+)") or "other"
    metric("smg_otel_exports_total", { { "result", "failure" } })
    metric("smg_otel_spans_total", { { "result", "dropped" } }, take)
    metric("smg_otel_export_failures_total", { { "stage", stage } })
    ngx.log(ngx.WARN, "luarouter: otel export dropped ", take,
        " spans: ", stats.last_error)
    return false, take, err
end


_M.export_batch = export_batch

---Drain the buffer, however many batches that takes.
---@return number batches, number spans, number failures
function _M.flush()
    if not _M.is_enabled() then
        return 0, 0, 0
    end
    local batches, spans, failures = 0, 0, 0
    while #queue > 0 do
        local ok, count = export_batch()
        batches = batches + 1
        spans = spans + count
        if not ok then
            failures = failures + 1
            -- The collector is down: stop hammering it and let the next tick try
            -- again. Span loss past this point is already counted as dropped.
            break
        end
    end
    return batches, spans, failures
end

---Wake the exporter soon. Coalesced: while a flush is in flight, the wake-ups are
---no-ops, so a burst cannot pile up timers or export the same span twice.
---@param delay_s number|nil
---@return boolean scheduled
function _M.schedule_flush(delay_s)
    if flushing or not _M.is_enabled() then
        return false
    end
    if not (_G.ngx and ngx.timer and ngx.timer.at) then
        return false
    end
    local ok, err = ngx.timer.at(delay_s or 0, function(premature)
        if premature then
            -- Same reason as the batch tick: shutdown cancels this wake-up, and a
            -- span enqueued by the last request would die with the worker.
            flushing = true
            local ran, rerr = pcall(_M.flush)
            flushing = false
            if not ran then
                ngx.log(ngx.WARN, "luarouter: otel shutdown flush failed: ",
                    tostring(rerr))
            end
            return
        end
        flushing = true
        local ran, b, s, f = pcall(_M.flush)
        flushing = false
        if not ran then
            ngx.log(ngx.WARN, "luarouter: otel flush error: ", tostring(b))
        end
    end)
    if not ok then
        ngx.log(ngx.WARN, "luarouter: otel flush not scheduled: ", tostring(err))
    end
    return ok and true or false
end

---Next tick's delay, stretched while the collector keeps refusing us: after three
---straight failures a dead endpoint costs one connection per ~4 seconds instead
---of one per interval_ms.
local function next_delay_ms()
    local conf = _M.config()
    if stats.fail_streak >= 3 then
        return math.min(conf.interval_ms * 8, 30000)
    end
    return conf.interval_ms
end

_M.next_delay_ms = next_delay_ms

---Start the per-worker batch timer. Idempotent, and a no-op when disabled.
---@return boolean started, string|nil reason
function _M.start_timer()
    local conf = _M.config()
    if not conf.enabled then
        return false, "tracing is disabled"
    end
    if timer_running then
        return false, "already running"
    end
    if not (_G.ngx and ngx.timer and ngx.timer.at) then
        return false, "no ngx.timer"
    end
    timer_running = true
    local function tick(premature)
        if premature then
            -- OpenResty fires pending timers with premature=true the moment the
            -- worker starts to quit, which is exactly the case a long
            -- SMG_TRACE_BATCH_INTERVAL_MS produces under `docker stop` (SIGQUIT).
            -- The buffered spans would otherwise die with the process, so the last
            -- batch still goes out here - one bounded attempt, no retry loop,
            -- because a worker that hangs shutdown is worse than losing spans.
            -- A hard SIGKILL never reaches this branch and loses the queue, which
            -- is the same trade Rust's BatchSpanProcessor makes.
            timer_running = false
            if #queue > 0 then
                flushing = true
                local ran, err = pcall(_M.flush)
                flushing = false
                if not ran then
                    ngx.log(ngx.WARN, "luarouter: otel shutdown flush failed: ",
                        tostring(err))
                end
            end
            return
        end
        flushing = true
        local ok, err = pcall(_M.flush)
        flushing = false
        if not ok then
            ngx.log(ngx.WARN, "luarouter: otel flush error: ", tostring(err))
        end
        if ngx.worker.exiting() then
            -- Final flush: what arrived since the pcall above, plus one retry for
            -- the batch that just failed. This is as close to Rust's
            -- shutdown_otel() -> force_flush() (main.rs, otel_trace.rs:186-205) as
            -- OpenResty gets, and it is the reason a graceful `docker stop` shows
            -- the last request's span while SIGKILL does not.
            flushing = true
            local again, aerr = pcall(_M.flush)
            flushing = false
            if not again then
                ngx.log(ngx.WARN, "luarouter: otel final flush failed: ",
                    tostring(aerr))
            end
            timer_running = false
            return
        end
        local restarted, restart_err = ngx.timer.at(next_delay_ms() / 1000, tick)
        if not restarted then
            timer_running = false
            ngx.log(ngx.WARN, "luarouter: otel batch timer stopped: ",
                tostring(restart_err))
        end
    end
    local ok, err = ngx.timer.at(conf.interval_ms / 1000, tick)
    if not ok then
        timer_running = false
        return false, tostring(err)
    end
    return true
end

---Number of spans waiting for the next batch.
---@return number
function _M.pending()
    return #queue
end

---Test seam: replace the transport with a spy so the unit gate can assert the
---encoder without a socket. Pass nil to restore the cosocket exporter.
---@param fn function|nil @ fn(conf, payload) -> err
function _M.set_exporter(fn)
    post_json_override = fn
end

---Synthetic span through the real encoder and exporter, so the e2e gate and an
---operator can prove the wiring without generating inference traffic.
---@param name string|nil
---@return boolean ok, string|nil detail
function _M.self_test(name)
    local conf = _M.config()
    if not conf.enabled then
        return false, "tracing is disabled"
    end
    local trace_id = random_hex(16)
    local span_id = random_hex(8)
    if not trace_id or not span_id then
        return false, "no entropy"
    end
    local now_ms = math.floor(ngx.now() * 1000)
    enqueue({
        trace_id = trace_id,
        span_id = span_id,
        name = name or "smg_otel_self_test",
        started_ms = now_ms - 1,
        ended_ms = now_ms,
        duration_ms = 1,
        flags = "01",
        sampled = true,
        is_root = true,
        children = {},
        attributes = { attr_string("smg.self_test", "true") },
        status = { code = 1 },
    })
    local _, count, failures = _M.flush()
    if failures > 0 then
        return false, stats.last_error or "export failed"
    end
    return true, tostring(count)
end

---Rust parity notes for /_ui and /probe consumers.
_M.RUST_TRANSPORT = "otlp/grpc (4317)"
_M.TRANSPORT = "otlp/http-json (4318)"

return _M
