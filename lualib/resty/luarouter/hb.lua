-- Health checks and circuit breaker.
--
-- Also the launch point for the GPU load source (doc/gap-gpu-load.md): start()
-- hands the interval timer to gpu_load.lua, whose shape is this module's own
-- timer pattern (worker-0 single-flight, self-rescheduling ngx.timer.at). It is
-- launched from here rather than from init.lua because the sweep already owns
-- "one process dials every worker on a clock", and init_worker's worker-0 gate is
-- what makes that true; gpu_load keeps its own interval and its own failure
-- semantics, so nothing about the health sweep changes.
--
-- Two independent mechanisms, both copied from the Rust gateway:
--
-- 1. Periodic health probe (this module's `check_all`, driven by a timer in
--    worker 0): GET {url}{health_check_endpoint}. `health_failure_threshold`
--    consecutive failures mark a worker unhealthy, `health_success_threshold`
--    consecutive successes bring it back. Counter semantics match
--    gateway/src/core/worker.rs exactly, including the reset-to-zero on a
--    threshold transition.
--
-- 2. Per-request circuit breaker (`record_outcome`), fed by the router from
--    real traffic. `cb_failure_threshold` consecutive failures open the circuit
--    for `cb_timeout_duration_secs`; `cb_success_threshold` successes in
--    half-open close it again.
--
-- Both counters live in lr_workers so the registry can expose them without a
-- second store.

local observability = require "resty.luarouter.observability"
local registry = require "resty.luarouter.registry"

local _M = { _VERSION = "0.1.0" }

local MAX_TIMER_DELAY = 3600

local config

local function cfg()
    if not config then
        config = require("resty.luarouter").config()
    end
    return config
end

-- ------------------------------------------------------------- http via cosocket

local function parse_url(url)
    return registry.split_url(url)
end

---One HTTP request with a deadline. Returns status, body, err.
---
---Generalised out of the original GET-only helper: /flush_cache is a POST on
---both gateways, so the fan-out path needs a method and a body. `http_get` stays
---as a thin wrapper because the health sweep and metadata discovery call it.
---@param method string
---@param url string
---@param timeout_ms number
---@param headers table|nil
---@param body string|nil @ sent with an explicit Content-Length when present
---@param kind string|nil @ cosocket pool class ("hb" default, "probe" for fan-out)
---@return number|nil status, string|nil body, string|nil err
function _M.http_request(method, url, timeout_ms, headers, body, kind)
    local conf = cfg()
    local host, port, tls = parse_url(url)
    local path = ngx.re.match(url, [==[^https?://[^/]+(/.*)$]==], "jo")
    local request_path = path and path[1] or "/"

    -- The same pool the forwarding path uses, under its own class: the health sweep
    -- touches every worker every second, so a fresh TCP+TLS handshake per probe was
    -- the dominant cost of the probe itself (and of the /metrics, /model_info and
    -- /v1/loads fan-outs that reuse this helper).
    local sock = ngx.socket.tcp()
    sock:settimeouts(timeout_ms, timeout_ms, timeout_ms)
    local ok, err = sock:connect(host, port,
        registry.pool_opts(conf, kind or "hb", url))
    if not ok then
        return nil, nil, "connect failed: " .. tostring(err)
    end
    local tls_ok, terr = registry.tls_handshake(sock, host, tls)
    if not tls_ok then
        sock:close()
        return nil, nil, terr
    end
    -- Explicit handshake (registry.tls_handshake): connect() does not do TLS in
    -- http{} context, so an https worker used to be probed in cleartext and marked
    -- unhealthy.
    --
    -- This runs on pooled sockets as well, where it is a no-op: OpenResty's
    -- sslhandshake returns immediately for a connection whose handshake already
    -- completed (verified against a pooled https mock: four probes over two
    -- accepted connections, every handshake reported ok). OpenResty does not
    -- expose the reuse through connect's third return value, so there is nothing
    -- to branch on here.
    -- No `Connection: close`: with the socket pooled that header asked the peer to
    -- drop the very connection setkeepalive() would hand back, so the next probe
    -- would find a dead socket. HTTP/1.1 keep-alive is the default either way, and
    -- registry.response_reusable still honours a peer's own `Connection: close`.
    local request = method .. " " .. request_path .. " HTTP/1.1\r\n"
        .. "Host: " .. host .. ":" .. port .. "\r\n"
        .. "User-Agent: lua-router/health\r\n"
        .. "Accept: */*\r\n"
    if body then
        request = request .. "Content-Length: " .. #body .. "\r\n"
    end
    if headers then
        for name, value in pairs(headers) do
            request = request .. name .. ": " .. value .. "\r\n"
        end
    end
    request = request .. "\r\n"

    local bytes, werr = sock:send(request)
    if not bytes then
        sock:close()
        return nil, nil, "send failed: " .. tostring(werr)
    end
    if body and body ~= "" then
        local sent, berr = sock:send(body)
        if not sent then
            sock:close()
            return nil, nil, "send failed: " .. tostring(berr)
        end
    end

    local status_line, read_err = sock:receive("*l")
    if not status_line then
        sock:close()
        return nil, nil, "no response: " .. tostring(read_err)
    end
    local status = tonumber(string.match(status_line, "^HTTP/%d%.%d%s+(%d%d%d)"))
    if not status then
        sock:close()
        return nil, nil, "malformed status line: " .. status_line
    end

    local content_length, chunked, connection = nil, false, nil
    repeat
        local line = sock:receive("*l")
        if line and line ~= "" then
            local name, value = string.match(line, "^([%w%-]+):%s*(.*)$")
            if name then
                local lower = string.lower(name)
                if lower == "content-length" then
                    content_length = tonumber(value)
                elseif lower == "transfer-encoding"
                    and string.lower(value):find("chunked") then
                    chunked = true
                elseif lower == "connection" then
                    connection = value
                end
            end
        end
    until line == nil or line == ""

    local response = ""
    local complete = true
    if chunked then
        response, complete = registry.pump_chunked(sock, true)
    elseif content_length and content_length > 0 then
        local remaining = content_length
        while remaining > 0 do
            local block = sock:receive(math.min(65536, remaining))
            if not block then
                complete = false
                break
            end
            response = response .. block
            remaining = remaining - #block
        end
    end

    registry.release(sock, conf,
        registry.response_reusable({ connection = connection }, complete),
        kind or "hb", url)
    return status, response
end

---Thin wrapper over http_request for the GET-only call sites.
---@param url string
---@param timeout_ms number
---@param headers table|nil
---@return number|nil status, string|nil body, string|nil err
function _M.http_get(url, timeout_ms, headers)
    return _M.http_request("GET", url, timeout_ms, headers, nil)
end

-- ------------------------------------------------------------- health probe

---Apply one probe result to a worker's health counters.
---@param id string
---@param ok boolean @ probe succeeded (2xx)
---@param hc table @ {failure_threshold, success_threshold}
---@return boolean healthy @ health state after the update
function _M.apply_health_result(id, ok, hc)
    local failure_threshold = hc.failure_threshold or cfg().health_failure_threshold
    local success_threshold = hc.success_threshold or cfg().health_success_threshold
    local healthy = registry.is_healthy(id)

    if ok then
        registry.set_health_counters(id, 0, nil)
        local d = ngx.shared.lr_workers
        -- incr, not get+set: the sweep and the request path can both charge a
        -- worker, and a lost increment just delays the recovery by one probe.
        local successes = d:incr("hs:" .. id, 1, 0) or 1
        if not healthy and successes >= success_threshold then
            registry.set_healthy(id, true)
            d:set("hs:" .. id, 0)
            observability.log("worker " .. id .. " healthy again")
            return true
        end
        return healthy
    end

    registry.set_health_counters(id, nil, 0)
    local d = ngx.shared.lr_workers
    local failures = d:incr("hf:" .. id, 1, 0) or 1
    if healthy and failures >= failure_threshold then
        registry.set_healthy(id, false)
        d:set("hf:" .. id, 0)
        observability.log("worker " .. id .. " marked unhealthy after "
            .. failures .. " consecutive failures")
        return false
    end
    return healthy
end

---Probe every worker once. Called from the interval timer.
---@return number @ number of workers probed
function _M.check_all()
    local conf = cfg()
    local timeout_ms = conf.health_check_timeout_secs * 1000
    local records = registry.records()
    local probed = 0
    local skipped_idle = 0
    -- 空闲阈值：缺省 300s。有流量的 worker 不需要探活——流量本身就是健康的证明。
    -- 设为 0 或负数 = 不跳过（兼容旧行为）。
    local idle_ms = (tonumber(os.getenv("SMG_HEALTH_CHECK_IDLE_SECS")) or 300) * 1000
    local now_ms = ngx.now() * 1000

    for i = 1, #records do
        local record = records[i]
        if not record.disable_health_check then
            local skip = false
            if idle_ms > 0 and registry.last_active_ms then
                local idle_ago = registry.last_active_ms(record.id)
                if idle_ago and idle_ago < idle_ms then
                    skip = true
                    skipped_idle = skipped_idle + 1
                end
            end
            if skip then
                -- 有流量：跳过探活，不翻转健康位（流量已经证明它活着）
                observability.record_health_check(record.id, true, true)
            else
                local url = record.url .. conf.health_check_endpoint
                local status, _, err = _M.http_get(url, timeout_ms)
            local ok = status ~= nil and status >= 200 and status < 300
            local hc = {
                failure_threshold = record.health_failure_threshold,
                success_threshold = record.health_success_threshold,
            }
            _M.apply_health_result(record.id, ok, hc)
            observability.record_health_check(record.id, ok)
            if ok then
                -- Registration is asynchronous: the model id and labels arrive
                -- here on the first probe that reaches a running worker.
                registry.discover(record, conf)
            end
            if not ok then
                observability.log_debug("health probe " .. url .. " failed: "
                    .. (err or ("status " .. tostring(status))))
            end
                probed = probed + 1
            end
        end
    end
    if skipped_idle > 0 then
        observability.log_debug("health sweep skipped " .. skipped_idle .. " idle workers")
    end
    return probed
end

local timer_running = false

local function interval()
    local seconds = cfg().health_check_interval_secs
    if seconds < 1 then
        seconds = 1
    end
    return math.min(seconds, MAX_TIMER_DELAY)
end

local function heartbeat(premature)
    if premature then
        timer_running = false
        return
    end
    local ok, err = pcall(_M.check_all)
    if not ok then
        ngx.log(ngx.ERR, "luarouter: health sweep error: ", tostring(err))
    end
    local again, terr = ngx.timer.at(interval(), heartbeat)
    if not again then
        timer_running = false
        ngx.log(ngx.ERR, "luarouter: failed to reschedule health sweep: ",
            tostring(terr))
    end
end

---Start the periodic sweep (worker 0 only, once per worker process), and with it
---the GPU load source.
---
---The load source starts *before* the disable_health_check early-return: SMG_DISABLE
---_HEALTH_CHECK says "do not judge workers by probing them", and a load sample that
---never touches health has no reason to disappear with the sweep. gpu_load.start()
---answers false and logs nothing when SMG_LOAD_SOURCE=none, so the shipped shape is
---unchanged.
function _M.start()
    local ok_load, gpu_load = pcall(require, "resty.luarouter.gpu_load")
    if ok_load and type(gpu_load) == "table" and type(gpu_load.start) == "function" then
        local started, why = gpu_load.start(cfg())
        if started == false and why ~= "disabled (SMG_LOAD_SOURCE=none)" then
            ngx.log(ngx.WARN, "luarouter: gpu-load not started: ", tostring(why))
        end
    end
    if timer_running then
        return
    end
    if cfg().disable_health_check then
        return
    end
    timer_running = true
    local ok, err = ngx.timer.at(0, heartbeat)
    if not ok then
        timer_running = false
        ngx.log(ngx.ERR, "luarouter: failed to start health sweep: ",
            tostring(err))
    end
end

-- ------------------------------------------------------------ circuit breaker

--- Whether a response should be charged to the breaker.
--- Client errors prove the worker is alive; 408/429 are real overload signals.
--- Mirrors breaker_failed() in gateway/src/routers/http/router.rs.
---@param status number
---@return boolean failed
function _M.breaker_failed(status)
    if status >= 200 and status < 300 then
        return false
    end
    if status >= 400 and status < 500 and status ~= 408 and status ~= 429 then
        return false
    end
    return true
end

--- True when a retry may be attempted. Mirrors is_retryable_status().
---@param status number
---@return boolean
function _M.is_retryable_status(status)
    return status == 408 or status == 429 or status == 500
        or status == 502 or status == 503 or status == 504
end

--- Availability (including the open -> half_open flip after the timeout) lives
--- in registry.is_available(), which every selection path already calls, so the
--- rule exists once. Do not re-implement it here.

---Charge a request outcome to the breaker. Streaming responses must call this
---when the stream actually ends, not when the status line arrives.
---@param id string
---@param success boolean
function _M.record_outcome(id, success)
    if cfg().disable_circuit_breaker then
        return
    end
    local conf = cfg()
    local url = registry.url_for(id)
    -- Count first, atomically, and judge the flip on the value incr returned:
    -- that value is this outcome's rank, so no process can be stranded below the
    -- threshold by a sibling overwriting the counter afterwards.
    local failures, successes = registry.charge_cb(id, success)
    local state = registry.cb_state(id).state

    if success then
        if state == registry.CB_HALF_OPEN and successes >= conf.cb_success_threshold
            and registry.flip_cb(id, registry.CB_HALF_OPEN, registry.CB_CLOSED) then
            observability.record_cb_transition(url, "half_open", "closed")
            observability.log("worker " .. id .. " circuit closed")
        end
    elseif state == registry.CB_HALF_OPEN then
        -- A single failed probe in half-open re-opens the circuit, and the timer
        -- restarts: same as Rust (can_execute() -> State::Open again).
        if registry.flip_cb(id, registry.CB_HALF_OPEN, registry.CB_OPEN,
                ngx.now() * 1000) then
            observability.record_cb_transition(url, "half_open", "open")
        end
    elseif state == registry.CB_CLOSED and failures >= conf.cb_failure_threshold then
        if registry.flip_cb(id, registry.CB_CLOSED, registry.CB_OPEN,
                ngx.now() * 1000) then
            observability.record_cb_transition(url, "closed", "open")
            observability.log("worker " .. id .. " circuit opened after "
                .. failures .. " consecutive failures")
        end
    end
    observability.record_cb_outcome(url, success and "success" or "failure")
end

---Charge an HTTP status to the breaker using the 4xx exemption rule.
---@param id string
---@param status number
function _M.record_status(id, status)
    _M.record_outcome(id, not _M.breaker_failed(status))
end

---Charge a *streaming* outcome to the breaker, with the same 4xx exemption rule
---as record_status. A stream that carries a client error (a malformed image gets
---a 400 from sglang) proves the worker answered, so it must not open the circuit;
---408/429 still do, and so does a stream that died mid-flight (stream_ok=false)
---regardless of the status line -- that is the transport failure the breaker is
---for. With stream_ok=true this is exactly record_status, which is the invariant
---the two forward.lua branches must keep.
---@param id string
---@param status number
---@param stream_ok boolean @ false when the stream broke before its end
function _M.record_stream_outcome(id, status, stream_ok)
    _M.record_outcome(id, stream_ok and not _M.breaker_failed(status))
end

return _M
