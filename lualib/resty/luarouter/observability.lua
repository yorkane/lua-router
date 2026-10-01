-- Request log ring buffer, sliding-window stats and Prometheus text export.
--
-- Field names and metric names are the wire contract with ui/logs.html and the
-- Grafana dashboards that already target the Rust gateway, so both are copied
-- from gateway/src/observability/{request_log,metrics}.rs rather than invented.
--
-- lr_request_log layout:
--   head      monotonic sequence (incr)
--   q:<seq>   one RequestRecord as JSON
-- lr_stats layout:
--   c|<metric>|<labels>      counter
--   h|<metric>|<labels>      histogram  {n,s,b1..bN} packed in one value
--   w|<bucket_ms>            one-millisecond window sample
-- Per-worker gauges (health / load / breaker state) are derived live from
-- lr_workers at scrape time and never stored, so a scrape can never disagree
-- with the registry.
--
-- Label pairs inside a key use \1 and \2 as separators: URLs and request paths
-- both contain commas, which would break a comma-joined key.

local cjson = require "cjson.safe"

local _M = { _VERSION = "0.1.0" }

local LOG_DICT = "lr_request_log"
local STATS_DICT = "lr_stats"
-- Read-only at scrape time: the manual policy sticky map, whose keys are the
-- only durable record of which routing key is bound to which worker.
local POLICY_DICT = "lr_policy"

local json_encode = cjson.encode
local json_decode = cjson.decode

local PAIR_SEP = "\1"
local KV_SEP = "\2"

-- Default duration buckets from the Rust Prometheus setup.
local DEFAULT_BUCKETS = {
    0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5,
    5.0, 10.0, 15.0, 30.0, 45.0, 60.0, 90.0, 120.0, 180.0, 240.0,
}

local config

local function cfg()
    if not config then
        config = require("resty.luarouter").config()
    end
    return config
end

-- SMG_PROMETHEUS_DURATION_BUCKETS is read once and cached: the bucket array is
-- baked into every stored histogram (b[i] is the count for bucket i alone), so
-- changing the ladder mid-life would need a re-bucket, not a new ladder.
local buckets_cache

---@return table buckets @ ascending upper bounds
---@return integer count
local function buckets()
    if not buckets_cache then
        local configured = cfg().duration_buckets
        if configured and #configured > 0 then
            local sorted = {}
            for i = 1, #configured do
                sorted[i] = configured[i]
            end
            table.sort(sorted)
            buckets_cache = sorted
        else
            buckets_cache = DEFAULT_BUCKETS
        end
    end
    return buckets_cache, #buckets_cache
end

-- _M.log_enabled is defined with the other accessors; append_request guards on
-- it through the table so declaration order does not matter.
local function logdict()
    return ngx.shared[LOG_DICT]
end

local function statsdict()
    return ngx.shared[STATS_DICT]
end

-- ------------------------------------------------------------------ key/value

local function label_text(labels)
    if type(labels) ~= "table" or #labels == 0 then
        return ""
    end
    return table.concat(labels, PAIR_SEP)
end

--- Encode one label set: {"model","qwen","endpoint","chat"}.
local function label_pairs(pairs)
    local parts = {}
    for i = 1, #pairs do
        parts[#parts + 1] = pairs[i][1] .. KV_SEP .. pairs[i][2]
    end
    return table.concat(parts, PAIR_SEP)
end

-- The Prometheus text output uses these.
local function render_labels(text)
    if text == "" then
        return ""
    end
    local parts = {}
    for pair in string.gmatch(text, "([^" .. PAIR_SEP .. "]+)") do
        local name, value = string.match(pair, "^([^" .. KV_SEP .. "]+)"
            .. KV_SEP .. "(.*)$")
        if name then
            parts[#parts + 1] = name .. '="' .. _M.escape_label(value) .. '"'
        end
    end
    if #parts == 0 then
        return ""
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function render_bucket_labels(base, le)
    local le_text = (le == math.huge) and "+Inf" or string.format("%g", le)
    if base == "" then
        return '{le="' .. le_text .. '"}'
    end
    return "{" .. render_labels(base):sub(2, -2) .. ',le="' .. le_text .. '"}'
end

function _M.escape_label(value)
    value = tostring(value)
    local out = {}
    for i = 1, #value do
        local char = value:sub(i, i)
        if char == "\\" then
            out[#out + 1] = "\\\\"
        elseif char == '"' then
            out[#out + 1] = '\\"'
        elseif char == "\n" then
            out[#out + 1] = "\\n"
        else
            out[#out + 1] = char
        end
    end
    return table.concat(out)
end

local escape_label = _M.escape_label

-- ------------------------------------------------------------------ primitives

---Increase a Prometheus counter. `pairs` is a list of {name, value} pairs.
function _M.counter(metric, pairs, delta)
    local d = statsdict()
    local key = "c|" .. metric .. "|" .. label_pairs(pairs)
    local value = d:incr(key, delta or 1, 0)
    if not value then
        d:set(key, delta or 1)
    end
end

---Storage key of one packed histogram value. b[i] is the count for bucket i
---alone; the exporter prefix-sums it at render time.
local function histo_key(metric, pairs)
    return "h|" .. metric .. "|" .. label_pairs(pairs)
end

---Record one histogram observation.
function _M.observe(metric, pairs, seconds)
    local d = statsdict()
    local key = histo_key(metric, pairs)
    local raw = d:get(key)
    local hist
    if raw then
        hist = json_decode(raw)
        if type(hist) ~= "table" then
            hist = nil
        end
    end
    local current, count = buckets()
    if not hist then
        hist = { n = 0, s = 0, b = {} }
    end
    if type(hist.b) ~= "table" or #hist.b ~= count then
        -- Either a sparse array cjson rendered as nulls, or a histogram stored
        -- under the previous bucket ladder: rebuild at the current width. The
        -- per-bucket detail of an old ladder is lost, but n/s survive so
        -- _sum/_count stay correct.
        hist.b = {}
    end
    -- Every bucket must exist: lua-cjson turns a sparse numeric table into a
    -- JSON array full of nulls, and those decode back as cjson.null userdata.
    for i = 1, count do
        hist.b[i] = tonumber(hist.b[i]) or 0
    end
    hist.n = hist.n + 1
    hist.s = hist.s + seconds
    -- Buckets are ascending, so the first hit is the smallest le that covers the
    -- observation: b[i] stores the count for bucket i alone. The exporter
    -- prefix-sums it into the cumulative le= series (see render below); bumping
    -- every covering bucket here as well would count one request twice per
    -- bucket and make le=240 exceed _count.
    for i = 1, count do
        if seconds <= current[i] then
            hist.b[i] = hist.b[i] + 1
            break
        end
    end
    local encoded = json_encode(hist)
    if encoded then
        d:set(key, encoded)
    end
end

---Set a Prometheus gauge. Only for values that cannot be derived live.
function _M.gauge(metric, pairs, value)
    statsdict():set("g|" .. metric .. "|" .. label_pairs(pairs), value)
end

-- ------------------------------------------------------------------ window

-- One key per 200ms bucket: a minute of history costs 300 keys, and the stats
-- window itself is cfg().stats_window_s (default 10s = 50 buckets).
local BUCKET_MS = 200
local BUCKET_TTL = 120

local function bucket_key(now_ms)
    return "w|" .. (math.floor(now_ms / BUCKET_MS) * BUCKET_MS)
end

local FIELDS = { "req", "err", "in_tok", "out_tok", "dur_ms", "dur_n",
                 "ttft_ms", "ttft_n", "est" }

local function note_window(field, value)
    if value == 0 then
        return
    end
    local d = statsdict()
    local key = bucket_key(ngx.now() * 1000)
    local sample
    local raw = d:get(key)
    if raw then
        sample = json_decode(raw)
        if type(sample) ~= "table" then
            sample = nil
        end
    end
    if not sample then
        sample = {}
        for i = 1, #FIELDS do
            sample[FIELDS[i]] = 0
        end
    end
    sample[field] = (sample[field] or 0) + value
    local encoded = json_encode(sample)
    if encoded then
        d:set(key, encoded, BUCKET_TTL)
    end
end

---Aggregate the window samples covering the last `window_s` seconds.
---@param window_s number
---@return table
local function read_window(window_s)
    local d = statsdict()
    local now_ms = ngx.now() * 1000
    local span = math.max(1, math.floor(window_s * 1000))
    local total = {}
    for i = 1, #FIELDS do
        total[FIELDS[i]] = 0
    end
    local buckets = math.ceil(span / BUCKET_MS)
    local seen = 0
    for offset = 0, buckets do
        local raw = d:get(bucket_key(now_ms - offset * BUCKET_MS))
        if raw then
            local sample = json_decode(raw)
            if type(sample) == "table" then
                seen = seen + 1
                for i = 1, #FIELDS do
                    total[FIELDS[i]] = total[FIELDS[i]] + (tonumber(sample[FIELDS[i]]) or 0)
                end
            end
        end
    end
    total.buckets = seen
    return total
end

-- ------------------------------------------------------------------ logging

---Lifecycle log line (registrations, breaker and health transitions).
function _M.log(message)
    ngx.log(ngx.NOTICE, "luarouter: ", message)
end

---Probe chatter and per-attempt detail, gated on SMG_LOG_LEVEL=debug.
function _M.log_debug(message)
    if cfg().log_level == "debug" then
        ngx.log(ngx.INFO, "luarouter: ", message)
    end
end

-- ------------------------------------------------------------------ inflight

---Concurrency-limiter outcome, same name and labels as the Rust
---smg_http_rate_limit_total (observability/metrics.rs:171, labels allowed/rejected).
---@param result string @ "allowed" or "rejected"
function _M.record_http_rate_limit(result)
    _M.counter("smg_http_rate_limit_total", { { "result", result } })
end

function _M.inflight_add(delta)
    local value = statsdict():incr("inflight", delta, 0)
    if not value or value < 0 then
        statsdict():set("inflight", math.max(0, value or 0))
    end
end

function _M.inflight()
    return statsdict():get("inflight") or 0
end

-- ------------------------------------------------------- in-flight age tracker
--
-- Real ages for smg_http_inflight_request_age_count, the one Rust family that
-- needs a per-request start time. Rust keeps request_id -> Instant in a DashMap
-- and samples it every 20 s (observability/inflight_tracker.rs, started at
-- server.rs:1559), deregistering through the guard's Drop. Here the request is
-- served by whichever nginx worker took it, so the table has to be a shared
-- dict, and there is no Drop: the hand-back happens in finish_request and, for
-- the paths that never reach it, in the log phase (init.lua on_log).
--
-- Fixed-size slot table instead of one key per request: lr_stats also holds
-- every counter and histogram, and a churn of per-request keys would put those
-- under LRU pressure at high concurrency. The table has a constant key count,
-- so the tracker can never evict the wire contract out from under the exporter:
-- 1024 keys of ~35-byte token plus a shdict node is roughly 120 KB against the
-- 5m lr_stats ceiling, and it bounds the two walks the tracker pays (one scan
-- per 20 s tick, one per scrape for the occupancy gauge).
local INFLIGHT_SLOTS = 1024
local INFLIGHT_PROBES = 4
local INFLIGHT_PREFIX = "i|"
-- Family-name prefix of everything the tracker publishes. With the sampler off
-- (LR_INFLIGHT_SAMPLE_SECS=0) the exporter drops every key whose metric name
-- starts with this, so a snapshot left in lr_stats before the switch cannot be
-- scraped as if it were current.
local INFLIGHT_FAMILY = "smg_http_inflight_request_age"

-- Sampler interval and slot TTL, captured before the fork by init.lua (the
-- LR_INFLIGHT_* names, off by default to the Rust 20 s cadence).
local inflight_conf = { sample_s = 20, ttl_s = 3600 }

---Knobs for the tracker. Called from init_by_lua, where the real environment is
---still visible; anything read with os.getenv after the fork would need an
---`env` line in the shipped configs (all three confs declare the pair).
---
---`sample_s = 0` turns the tracker off completely: no sampler timer, no slot
---claims and therefore no age family in the scrape at all. That is the knob for a
---deployment that does not want a 1024-key walk every tick, and it is why the
---family is allowed to be absent rather than rendered with invented zeros.
---@param opts table|nil @ { sample_s = number, ttl_s = number }
---@return table @ the effective knobs
function _M.configure_inflight(opts)
    opts = opts or {}
    local sample_s = tonumber(opts.sample_s)
    local ttl_s = tonumber(opts.ttl_s)
    if sample_s and sample_s >= 0 then
        inflight_conf.sample_s = sample_s
    end
    if ttl_s and ttl_s >= 1 then
        inflight_conf.ttl_s = ttl_s
    end
    return inflight_conf
end

---Whether the tracker runs at all (LR_INFLIGHT_SAMPLE_SECS=0 disables it).
---@return boolean enabled
function _M.inflight_enabled()
    return inflight_conf.sample_s > 0
end

function _M.inflight_sample_s()
    return inflight_conf.sample_s
end

---Slot TTL in seconds: the self-heal bound. A request whose log phase never ran
---(worker killed, or a Lua abort before the hook) stops being sampled once its
---slot expires, so the table cannot leak past LR_INFLIGHT_TTL_SECS.
function _M.inflight_ttl_s()
    return inflight_conf.ttl_s
end

---Claim a slot for the request and remember it in ngx.ctx.
---
---add() is the allocator: it writes only into a free slot, so the claim is
---atomic across processes with no read-modify-write window. The search starts at
---a random slot and walks INFLIGHT_PROBES consecutive ones, which keeps the
---registration cost at one shdict op while the table is mostly empty. When every
---probe is taken the request is dropped from the age table and counted, so the
---approximation is visible rather than silent: at load factor f the chance of
---losing a registration is about f^INFLIGHT_PROBES, i.e. 0.39% at 256 concurrent
---requests against 1024 slots, 0.0015% at 64, and 6.25% at 512.
---@return boolean tracked
function _M.inflight_track()
    local ctx = ngx and ngx.ctx
    if not ctx or not _M.inflight_enabled() then
        return false
    end
    local ok, d = pcall(statsdict)
    if not ok or not d then
        return false
    end
    local token = math.floor(ngx.now() * 1000) .. "|" .. string.format("%06x", math.random(0, 0xFFFFFF))
    local start = math.random(0, INFLIGHT_SLOTS - 1)
    for probe = 0, INFLIGHT_PROBES - 1 do
        local key = INFLIGHT_PREFIX .. ((start + probe) % INFLIGHT_SLOTS)
        -- forcible means the write squeezed in by evicting somebody else's key:
        -- undo it and treat the slot as full, since the whole point of the fixed
        -- table is that the tracker never displaces a counter or histogram.
        local added, _, forcible = d:add(key, token, inflight_conf.ttl_s)
        if added and not forcible then
            ctx.lr_inflight_key = key
            ctx.lr_inflight_token = token
            return true
        elseif added then
            -- The dict was full and nginx squeezed our write in by evicting
            -- somebody else's key. Hand it back unless another request has since
            -- claimed the slot (the read-compare cannot undo that write, and it
            -- must not delete a live request's entry).
            if d:get(key) == token then
                d:delete(key)
            end
        end
    end
    _M.counter("smg_http_inflight_request_age_dropped_total", {})
    return false
end

---Hand the slot back. Idempotent per request (the ctx token goes first), so
---finish_request and the log-phase sweep can both call it without double-freeing.
---A slot that now names a different request is left alone: the entry there is
---somebody else's live request, and ours is already gone from the table.
---@return boolean untracked
function _M.inflight_untrack()
    local ctx = ngx and ngx.ctx
    if not ctx or not ctx.lr_inflight_key then
        return false
    end
    local key, token = ctx.lr_inflight_key, ctx.lr_inflight_token
    ctx.lr_inflight_key, ctx.lr_inflight_token = nil, nil
    local ok, d = pcall(statsdict)
    if not ok or not d then
        return false
    end
    if d:get(key) == token then
        d:delete(key)
    end
    return true
end

---Write one age snapshot into the packed histogram in a single decode/encode
---pair. Going through the whole batch here (rather than observe() per request)
---is what makes a 1024-slot walk every 20 s affordable.
---
---Snapshot, not accumulate: the stored value is replaced with what is in flight
---*now*, which is what Rust's handle.set_counts() does. The exporter prefix-sums
---b[] at render time, so the family reads as a cumulative histogram over the
---duration ladder while keeping the gauge meaning - a scraper that sees the
---request finish can watch the bucket fall back down instead of reading a
---monotonic total that never mentions the in-flight set emptied.
local function store_age_snapshot(counts, observed, sum)
    local d = statsdict()
    local current, count = buckets()
    local hist = { n = observed, s = sum, b = {} }
    for i = 1, count do
        hist.b[i] = counts[i] or 0
    end
    local encoded = json_encode(hist)
    if encoded then
        d:set(histo_key("smg_http_inflight_request_age_count", {}), encoded)
    end
end

---One sampler tick: bucket every in-flight request by age and publish the whole
---distribution as the current snapshot of smg_http_inflight_request_age_count.
---Driven from the worker-0 timer in init.lua over the shared table, which asks
---the same question Rust asks its DashMap (Rust samples one process-local map
---from one PeriodicTask; here every process writes one shared map and worker 0
---samples it, so N workers do not multiply the series).
---
---Ages are measured, never synthesised. A tick that finds nothing in flight
---publishes an all-zero snapshot (Rust's gauges read 0 the same way), which is
---what lets a dashboard see the in-flight set drain; before the first tick the
---family is simply absent from /metrics, because a distribution that was never
---sampled has no right to be on a graph.
---@return number observed @ requests bucketed by this tick
function _M.sample_inflight_ages()
    local d = statsdict()
    if not d then
        return 0
    end
    local current, count = buckets()
    local counts = {}
    for i = 1, count do
        counts[i] = 0
    end
    -- One clock reading for the whole tick, so every age in the batch is
    -- measured against the same instant (Rust reads Instant::now() per entry).
    local now_ms = ngx.now() * 1000
    local observed, sum = 0, 0
    for i = 0, INFLIGHT_SLOTS - 1 do
        local value = d:get(INFLIGHT_PREFIX .. i)
        if type(value) == "string" then
            local start_ms = tonumber(string.match(value, "^(%-?%d+)|"))
            if start_ms then
                -- Saturating age: a slot written with a clock ahead of this
                -- reading samples 0 rather than being skipped, the way Rust's
                -- as_secs() on a Duration can never go negative.
                local age = math.max(0, (now_ms - start_ms) / 1000)
                observed = observed + 1
                sum = sum + age
                for b = 1, count do
                    if age <= current[b] then
                        counts[b] = counts[b] + 1
                        break
                    end
                end
            end
        end
    end
    store_age_snapshot(counts, observed, sum)
    return observed
end

---In-flight slots currently claimed, read live at scrape time. Mirrors Rust's
---InFlightRequestTracker::len (the same number its tests assert on) and gives a
---dashboard the tracker saturation check that the drop counter alone cannot:
---used/1024 says when the approximation stops holding.
---@return number used
function _M.inflight_slots_used()
    if not _M.inflight_enabled() then
        return 0
    end
    local ok, d = pcall(statsdict)
    if not ok or not d then
        return 0
    end
    local used = 0
    for i = 0, INFLIGHT_SLOTS - 1 do
        if d:get(INFLIGHT_PREFIX .. i) then
            used = used + 1
        end
    end
    return used
end

-- ------------------------------------------------------------------ metric API

---Layer 1: a request hit the router.
function _M.record_http_request(method, path)
    _M.counter("smg_http_requests_total",
        { { "method", method }, { "path", path } })
    _M.inflight_add(1)
    -- Pair the concurrency counter with a start time. This is the position Rust
    -- takes the guard: HttpMetricsLayer is outside the route layers, so the
    -- request is tracked before auth and before the concurrency limiter
    -- (server.rs:1424) and an unauthenticated or 429'd request still has an age.
    _M.inflight_track()
    note_window("req", 1)
end

function _M.record_http_duration(method, path, seconds)
    _M.observe("smg_http_request_duration_seconds",
        { { "method", method }, { "path", path } }, seconds)
end

function _M.record_http_response(status, error_code)
    _M.counter("smg_http_responses_total",
        { { "status_code", tostring(status) }, { "error_code", error_code or "" } })
end

---Layer 2: one routed inference request.
function _M.record_router_request(model, endpoint, streaming)
    _M.counter("smg_router_requests_total", {
        { "router_type", "http" }, { "backend_type", "regular" },
        { "connection_mode", "http" }, { "model", model },
        { "endpoint", endpoint }, { "streaming", streaming and "true" or "false" },
    })
end

function _M.record_router_duration(model, endpoint, seconds)
    _M.observe("smg_router_request_duration_seconds", {
        { "router_type", "http" }, { "backend_type", "regular" },
        { "connection_mode", "http" }, { "model", model }, { "endpoint", endpoint },
    }, seconds)
    -- Time per output token, derived the way Rust's record_streaming_metrics
    -- does it (metrics.rs:750-764): (generation - ttft) / (output_tokens - 1),
    -- and only when there was a first token and more than one token after it.
    -- The Lua router has no separate generation timer, so the request duration
    -- plays that role - the same substitution finish_request already makes for
    -- the request log's tok_per_s column (router.lua decode_ms).
    -- Total generation time. Rust reaches it from the same streaming helper as
    -- ttft/tpot and only ever fills it on its non-HTTP plane; here the finished
    -- request duration *is* the generation window, so the family gets a real
    -- source instead of staying a name.
    _M.observe("smg_router_generation_duration_seconds", {
        { "router_type", "http" }, { "backend_type", "regular" },
        { "model", model }, { "endpoint", endpoint },
    }, seconds)
    local ttft = ngx.ctx.lr_ttft
    local tokens = ngx.ctx.lr_tokens
    if ttft and type(tokens) == "table" and (tonumber(tokens[2]) or 0) > 1 then
        -- saturating subtract, as Rust does: a response whose last chunk lands in
        -- the same clock tick as the first records 0 rather than being skipped.
        local decode_s = math.max(0, seconds - ttft)
        _M.observe("smg_router_tpot_seconds", {
            { "router_type", "http" }, { "backend_type", "regular" },
            { "model", model }, { "endpoint", endpoint },
        }, decode_s / (tokens[2] - 1))
    end
end

function _M.record_router_error(model, endpoint, error_type)
    _M.counter("smg_router_request_errors_total", {
        { "router_type", "http" }, { "backend_type", "regular" },
        { "connection_mode", "http" }, { "model", model },
        { "endpoint", endpoint }, { "error_type", error_type },
    })
end

function _M.record_router_upstream_response(status, error_code)
    _M.counter("smg_router_upstream_responses_total", {
        { "router_type", "http" }, { "status_code", tostring(status) },
        { "error_code", error_code or "" },
    })
end

function _M.record_router_ttft(model, endpoint, seconds)
    _M.observe("smg_router_ttft_seconds", {
        { "router_type", "http" }, { "backend_type", "regular" },
        { "model", model }, { "endpoint", endpoint },
    }, seconds)
    note_window("ttft_ms", seconds * 1000)
    note_window("ttft_n", 1)
end

function _M.record_router_tokens(model, endpoint, token_type, count)
    if count <= 0 then
        return
    end
    _M.counter("smg_router_tokens_total", {
        { "router_type", "http" }, { "backend_type", "regular" },
        { "model", model }, { "endpoint", endpoint }, { "token_type", token_type },
    }, count)
end

---Layer 3: worker-level events. `worker_url` is the label value, as in Rust.
function _M.record_worker_selection(worker_url, model, policy)
    _M.counter("smg_worker_selection_total", {
        { "worker_type", "regular" }, { "connection_mode", "http" },
        { "model", model or "unknown" }, { "policy", policy or "round_robin" },
    })
end

function _M.record_worker_error(worker_url, error_type)
    _M.counter("smg_worker_errors_total", {
        { "worker_type", "regular" }, { "connection_mode", "http" },
        { "error_type", error_type },
    })
end

function _M.record_worker_retry(endpoint)
    _M.counter("smg_worker_retries_total",
        { { "worker_type", "regular" }, { "endpoint", endpoint } })
end

--- The Rust histogram is labelled only by attempt number (1..5, higher values
--- collapse to their own bucket), not by worker or endpoint.
function _M.record_worker_retry_backoff(attempt, seconds)
    if attempt < 1 then
        attempt = 1
    end
    _M.observe("smg_worker_retry_backoff_seconds",
        { { "attempt", tostring(attempt) } }, seconds)
end

function _M.record_worker_retries_exhausted(endpoint)
    _M.counter("smg_worker_retries_exhausted_total",
        { { "worker_type", "regular" }, { "endpoint", endpoint } })
end

function _M.record_health_check(worker_url, ok)
    _M.counter("smg_worker_health_checks_total", {
        { "worker_type", "regular" }, { "result", ok and "success" or "failure" },
    })
end

function _M.record_cb_transition(worker_url, from, to)
    _M.counter("smg_worker_cb_transitions_total", {
        { "worker", worker_url }, { "from", from }, { "to", to },
    })
end

function _M.record_cb_outcome(worker_url, outcome)
    _M.counter("smg_worker_cb_outcomes_total",
        { { "worker", worker_url }, { "outcome", outcome } })
end

-- ------------------------------------------------------------------ request log

---Append one RequestRecord to the ring buffer.
---@param record table
---@return number seq
function _M.append_request(record)
    if not _M.log_enabled() then
        record.seq = 0
        return 0
    end
    local d = logdict()
    local seq = d:incr("head", 1, 0) or 0
    record.seq = seq
    local encoded = json_encode(record)
    if encoded then
        d:set("q:" .. seq, encoded)
    end
    local stale = seq - cfg().request_log_capacity
    if stale > 0 then
        d:delete("q:" .. stale)
    end
    return seq
end

---Read records newer than `cursor`, oldest first.
---@param cursor number
---@param limit number
---@return number head, table[] records
function _M.snapshot(cursor, limit)
    local d = logdict()
    local head = d:get("head") or 0
    local capacity = cfg().request_log_capacity
    cursor = tonumber(cursor) or 0
    limit = tonumber(limit) or 500
    if limit < 1 then
        limit = 1
    elseif limit > 2000 then
        limit = 2000
    end
    local start = cursor + 1
    if head - capacity >= start then
        start = head - capacity + 1
    end
    if head - start + 1 > limit then
        start = head - limit + 1
    end
    local out = {}
    for seq = start, head do
        local raw = d:get("q:" .. seq)
        if raw then
            local record = json_decode(raw)
            if type(record) == "table" then
                out[#out + 1] = record
            end
        end
    end
    return head, out
end

function _M.log_capacity()
    return cfg().request_log_capacity
end

---Mirror of the Rust `RequestLogStore::current()` check: capacity 0 means the
---store was never installed, so every /_ui/logs* route reports itself disabled.
---@return boolean
function _M.log_enabled()
    return cfg().request_log_capacity > 0
end

function _M.log_buffered()
    local head = logdict():get("head") or 0
    return math.min(head, cfg().request_log_capacity)
end

-- ------------------------------------------------------------------ _ui/stats

---Sliding-window counters for the logs page summary strip.
---@return table
function _M.stats()
    local conf = cfg()
    local window_s = conf.stats_window_s or 10
    local sample = read_window(window_s)
    local elapsed_s = math.max(1, (sample.buckets * 200)) / 1000
    local function rate(value)
        return value / elapsed_s
    end
    local function average(sum, count)
        if count <= 0 then
            return cjson.null
        end
        return sum / count
    end
    local requests = logdict():get("head") or 0
    return {
        inflight = _M.inflight(),
        uptime_s = ngx.now() - conf.started_at_ms / 1000,
        requests_total = requests,
        output_tok_s = rate(sample.out_tok),
        input_tok_s = rate(sample.in_tok),
        window_s = elapsed_s,
        requests_window = sample.req,
        errors_window = sample.err,
        avg_ttft_ms = average(sample.ttft_ms, sample.ttft_n),
        avg_duration_ms = average(sample.dur_ms, sample.dur_n),
        tokens_estimated_share = sample.req > 0 and (sample.est / sample.req) or 0,
        price_in_per_mtok = conf.price_in_per_mtok or cjson.null,
        price_out_per_mtok = conf.price_out_per_mtok or cjson.null,
        capacity = conf.request_log_capacity,
        buffered = _M.log_buffered(),
        started_at_ms = conf.started_at_ms,
    }
end

---Charge a finished request to the window (tokens, latency, estimate flag).
function _M.note_tokens(input_tokens, output_tokens, estimated)
    note_window("in_tok", input_tokens or 0)
    note_window("out_tok", output_tokens or 0)
    if estimated then
        note_window("est", 1)
    end
end

function _M.note_duration(seconds)
    note_window("dur_ms", seconds * 1000)
    note_window("dur_n", 1)
end

function _M.note_error()
    note_window("err", 1)
end

-- ------------------------------------------------------- /_ui HTTP entrypoints
--
-- ui.conf forwards /_ui/logs, /_ui/logs/stream, /_ui/logs/backends and
-- /_ui/stats here by name (see lua-router/doc/impl-ui.md section 6), so these
-- names are the bridge contract. The router registers the same handlers on its
-- own route table, which means both entry points behave identically.

local function respond_json(status, payload)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json; charset=UTF-8"
    local encoded = json_encode(payload)
    if encoded then
        ngx.print(encoded)
    end
    return ""
end

---Rust request_log_disabled(): the store is off, so say so instead of an empty
---200 that the UI would render as "no requests".
local function log_disabled()
    return respond_json(ngx.HTTP_SERVICE_UNAVAILABLE,
        { error = "request log not enabled" })
end

--- GET /_ui/logs?cursor=&limit=
function _M.handle_logs()
    if not _M.log_enabled() then
        return log_disabled()
    end
    local query = ngx.req.get_uri_args()
    local cursor = tonumber(query.cursor) or 0
    local limit = tonumber(query.limit) or 500
    local head, requests = _M.snapshot(cursor, limit)
    if #requests == 0 then
        requests = cjson.empty_array
    end
    return respond_json(ngx.HTTP_OK, {
        cursor = head,
        capacity = _M.log_capacity(),
        requests = requests,
    })
end

--- GET /_ui/stats
function _M.handle_stats()
    if not _M.log_enabled() then
        return log_disabled()
    end
    return respond_json(ngx.HTTP_OK, _M.stats())
end

--- GET /_ui/logs/backends - provider column on the Logs page.
function _M.handle_backends()
    if not _M.log_enabled() then
        return log_disabled()
    end
    local registry = require "resty.luarouter.registry"
    local out = {}
    local records = registry.records()
    for i = 1, #records do
        local gpu = (type(records[i].labels) == "table"
            and records[i].labels.gpu) or cjson.null
        out[#out + 1] = {
            url = records[i].url,
            model = records[i].model_id,
            gpu = gpu,
        }
    end
    if #out == 0 then
        out = cjson.empty_array
    end
    return respond_json(ngx.HTTP_OK, { backends = out })
end

--- GET /_ui/logs/stream - SSE fan-out of finished requests with a 15s ping,
--- matching the Rust keep_alive interval.
---
--- Rust pushes through a tokio broadcast channel; there is no cross-worker
--- channel here, so the stream polls the shared ring buffer by sequence number.
--- The buffer lives in lr_request_log, which every worker writes, so a follower
--- still sees requests served by other processes. A client that falls behind
--- jumps forward (the Rust stream drops frames the same way and lets the browser
--- re-sync with a cursor poll).
function _M.handle_logs_stream()
    if not _M.log_enabled() then
        return log_disabled()
    end
    local d = logdict()
    ngx.status = ngx.HTTP_OK
    ngx.header["Content-Type"] = "text/event-stream"
    ngx.header["Cache-Control"] = "no-cache"
    ngx.header["X-Accel-Buffering"] = "no"
    ngx.flush(true)

    local cursor = d:get("head") or 0
    local capacity = _M.log_capacity()
    local PING_S = 15
    local POLL_S = 0.5
    local since_ping = 0

    while true do
        local head = d:get("head") or 0
        if head - capacity > cursor then
            -- Fell behind the ring: skip to the oldest retained record.
            cursor = head - capacity
        end
        while cursor < head do
            cursor = cursor + 1
            local raw = d:get("q:" .. cursor)
            if raw then
                local ok = pcall(ngx.print, "data: " .. raw .. "\n\n")
                if not ok then
                    return ngx.exit(ngx.HTTP_OK)
                end
            end
        end
        since_ping = since_ping + POLL_S
        if since_ping >= PING_S then
            since_ping = 0
            local ok = pcall(ngx.print, ": ping\n\n")
            if not ok then
                return ngx.exit(ngx.HTTP_OK)
            end
        end
        if not pcall(ngx.flush, true) then
            return ngx.exit(ngx.HTTP_OK)
        end
        if not pcall(ngx.sleep, POLL_S) then
            return ngx.exit(ngx.HTTP_OK)
        end
    end
end

-- ------------------------------------------------------------------ prometheus

-- Every string is copied from the matching describe_* macro in
-- gateway/src/observability/metrics.rs so one Grafana query reads the same
-- comment on either gateway. Families with no Rust counterpart are marked.
local HELP = {
    smg_http_requests_total = "Total HTTP requests by method and path",
    smg_http_request_duration_seconds = "HTTP request duration by method and path",
    smg_http_responses_total = "Total HTTP responses by status_code and error_code",
    -- Rust reads this from an atomic connection counter incremented in its
    -- metrics middleware (middleware.rs:929); the Lua value comes from nginx's
    -- own stub_status counters (see http_connections_active).
    smg_http_connections_active = "Currently active HTTP connections",
    smg_router_requests_total = "Total routed requests by router_type, backend_type, connection_mode, model, endpoint, streaming",
    smg_router_request_duration_seconds = "Router request duration by router_type, backend_type, connection_mode, model, endpoint",
    smg_router_request_errors_total = "Router errors by router_type, backend_type, connection_mode, model, endpoint, error_type",
    smg_router_upstream_responses_total = "Upstream backend HTTP responses by router_type, status_code, error_code",
    -- Rust marks these three describes as only filled on its non-HTTP plane,
    -- because its HTTP router never reaches the streaming-metrics helper. The
    -- Lua router records them for HTTP streaming as well, so that qualifier is
    -- dropped rather than repeated as a false claim about the series.
    smg_router_ttft_seconds = "Time to first token by router_type, backend_type, model, endpoint",
    smg_router_tpot_seconds = "Time per output token by router_type, backend_type, model, endpoint",
    smg_router_generation_duration_seconds = "Total generation time by router_type, backend_type, model, endpoint",
    smg_router_tokens_total = "Total tokens processed by router_type, backend_type, model, endpoint, token_type",
    smg_worker_selection_total = "Worker selection events by worker_type, connection_mode, model, policy",
    smg_worker_errors_total = "Worker-level errors by worker_type, connection_mode, error_type",
    smg_worker_retries_total = "Total retry attempts by worker_type and endpoint",
    smg_worker_retries_exhausted_total = "Requests that exhausted all retries by worker_type and endpoint",
    smg_worker_retry_backoff_seconds = "Retry backoff duration by attempt number",
    smg_worker_health_checks_total = "Health check results by worker_type and result",
    smg_worker_cb_transitions_total = "Circuit breaker state transitions by worker, from, to",
    smg_worker_cb_outcomes_total = "Circuit breaker outcomes by worker and outcome (success/failure)",
    smg_worker_health = "Worker health status (1=healthy, 0=unhealthy)",
    smg_worker_requests_active = "Currently running requests per worker",
    smg_worker_cb_state = "Circuit breaker state per worker (0=closed, 1=open, 2=half_open)",
    smg_worker_cb_consecutive_failures = "Current consecutive failure count per worker",
    smg_worker_cb_consecutive_successes = "Current consecutive success count per worker",
    -- Rust sets this per unique (worker_type, connection_mode, model) triple on
    -- every registry mutation (steps/worker/shared/register.rs:77); the Lua
    -- exporter derives the same series from lr_workers at scrape time, which is
    -- why an empty combination is simply absent rather than rendered as 0.
    smg_worker_pool_size = "Current worker pool size by worker_type, connection_mode, model",
    -- Lua-side superset: Rust has no tracing-self metrics and no in-flight gauge.
    smg_http_inflight_requests = "Requests currently being served by the router",
    -- Rust renders this family as non-cumulative gt/le gauges off a 30 s..86400 s
    -- ladder; the Lua exporter emits it as a cumulative histogram over the
    -- duration ladder because that is the shape a scraper can read with
    -- histogram_quantile here. See doc/gap-inflight-age.md.
    smg_http_inflight_request_age_count = "In-flight HTTP request ages in seconds, sampled on a fixed interval (cumulative buckets over the duration ladder)",
    -- Lua-side superset: the tracker's saturation signal, so the approximated
    -- ages above are auditable.
    smg_http_inflight_request_age_dropped_total = "In-flight age registrations dropped because every probed slot was taken",
    smg_http_inflight_request_age_slots_active = "In-flight requests currently held in the age tracker",
    smg_http_rate_limit_total = "Rate limiting decisions by result (allowed/rejected)",
    -- Layer 4 discovery (resty.luarouter.service_discovery).
    smg_discovery_registrations_total = "Worker registration attempts by source and result",
    smg_discovery_deregistrations_total = "Worker deregistration events by source and reason",
    smg_discovery_sync_duration_seconds = "Discovery sync duration by source",
    smg_discovery_workers_discovered = "Workers known via discovery by source",
    -- Policy-internal bookkeeping (resty.luarouter.policy).
    smg_manual_policy_branch_total = "Manual policy execution branch by branch",
    smg_consistent_hashing_policy_branch_total = "Consistent hashing policy execution branch by branch",
    smg_prefix_hash_policy_branch_total = "Prefix hash policy execution branch by branch",
    smg_manual_policy_cache_entries = "Number of routing entries in manual policy cache",
    smg_worker_routing_keys_active = "Active routing keys per worker",
    -- Lua-side superset: the Rust cache_aware tree exposes no tenant gauge.
    smg_cache_aware_tenant_count = "Tenants tracked by the cache_aware policy trees",
    -- OTLP export bookkeeping (resty.luarouter.otel). The Rust gateway exports no
    -- tracing-self metrics, so this family is Lua-side; the names keep the smg_
    -- prefix to stay one vocabulary with the rest of the scrape.
    smg_otel_requests_total = "Requests that got a trace context by sampled and source (inherited, generated)",
    smg_otel_spans_total = "Spans handled by the exporter by result (exported, dropped)",
    smg_otel_exports_total = "OTLP export attempts by result (success, failure)",
    smg_otel_export_failures_total = "OTLP export failures by stage (connect, send, collector, encode, ...)",
}

---Pool membership labels for one worker record, in the spelling Rust uses.
---
---`worker_type` is the record's own field (this gateway stores regular workers
---only, so the prefill/decode folding that pd.pool_of used to do is gone).
---`connection_mode` is the record's transport, which after the scope trim can
---only ever be http.
---@param record table
---@return string worker_type, string connection_mode, string model
local function pool_labels_for(record)
    local pool = record.worker_type
    if pool ~= "regular" then
        pool = "regular"
    end
    local mode = "http"
    local model = record.model_id
    if type(model) ~= "string" or model == "" then
        model = "unknown"
    end
    return pool, mode, model
end

---Count workers per unique (worker_type, connection_mode, model) triple.
---Label pairs are alphabetical so the rendered series text matches the order
---the Rust exporter prints them in.
---@param records table[]
---@return table[] @ { { labels = label_pairs text, value = n }, ... }
function _M.pool_size_counts(records)
    local seen = {}
    local out = {}
    for i = 1, #records do
        local pool, mode, model = pool_labels_for(records[i])
        local key = mode .. "\0" .. model .. "\0" .. pool
        local entry = seen[key]
        if not entry then
            entry = {
                labels = label_pairs({ { "connection_mode", mode },
                                       { "model", model },
                                       { "worker_type", pool } }),
                value = 0,
            }
            seen[key] = entry
            out[#out + 1] = entry
        end
        entry.value = entry.value + 1
    end
    return out
end

---Routing keys currently bound to each worker, derived from the manual policy
---sticky map in lr_policy.
---
---Rust measures the in-flight set: WorkerRoutingKeyLoad (core/worker.rs:72) is
---incremented by WorkerLoadGuard::new with the request's routing key and
---decremented when the guard drops, so an idle session holds nothing. The Lua
---manual policy has no per-request guard, and lr_policy is the durable state
---that survives across processes: `manual:<model>|<routing-key>` holds the
---candidate URL list Rust keeps in Node::candi_worker_urls, and occupied_hit
---walks that list in order, so the *first* url is the worker the key is pinned
---to while the tail is failback history. Attributing a key to its first url is
---therefore "which worker does this key currently belong to", the same question
---the Rust gauge answers, with one documented difference: the binding lives as
---long as the sticky entry does (SMG_MAX_IDLE_SECS) instead of as long as one
---request. A key whose worker has left keeps counting on that worker, which is
---exactly the failback state Rust never notices either (it is not told about
---removals).
---
---The scan is get_keys(0) over lr_policy, i.e. the same sweep
---policy.lua:publish_gauges() does for smg_manual_policy_cache_entries; a fleet
---with thousands of sticky keys pays one dict walk per scrape for it.
---@param d ngx.shared.Dict|nil
---@return table @{ [worker_url] = routing_key_count }
function _M.manual_routing_key_counts(d)
    d = d or (ngx and ngx.shared and ngx.shared[POLICY_DICT])
    local counts = {}
    if not d then
        return counts
    end
    local keys = d:get_keys(0)
    for i = 1, #keys do
        local key = keys[i]
        if key:sub(1, 7) == "manual:" then
            local urls = json_decode(d:get(key) or "")
            -- cjson decodes [] as an empty table and a JSON null as userdata,
            -- so only a real string in slot 1 names a bound worker.
            if type(urls) == "table" and type(urls[1]) == "string" then
                counts[urls[1]] = (counts[urls[1]] or 0) + 1
            end
        end
    end
    return counts
end

---Active (non-idle) client connections from the stub_status counters, or nil
---when the module is absent. Read at scrape time, never stored.
---@return number|nil
function _M.http_connections_active()
    if not ngx or not ngx.var then
        return nil
    end
    local reading = tonumber(ngx.var.connections_reading)
    local writing = tonumber(ngx.var.connections_writing)
    if not reading or not writing then
        return nil
    end
    return reading + writing
end

---Prometheus exposition text for everything recorded so far.
---@return string
function _M.prometheus_text()
    local d = statsdict()
    local keys = d:get_keys(0)

    local metrics = {}
    local function family(name)
        local f = metrics[name]
        if not f then
            f = { counters = {}, gauges = {}, histograms = {} }
            metrics[name] = f
        end
        return f
    end

    local tracker_on = _M.inflight_enabled()
    for i = 1, #keys do
        local key = keys[i]
        local kind, name, rest = string.match(key, "^(%a)|([%w_]+)|(.*)$")
        if kind and name then
            -- With the tracker switched off (LR_INFLIGHT_SAMPLE_SECS=0) the whole
            -- age family stays out of the scrape, even if a value survived from a
            -- tick taken before the switch: a stale distribution has no right to a
            -- graph, and the contract is "no sampler, no family".
            -- string.find with plain=true would treat the leading caret as a
            -- literal, so the prefix test is a byte comparison instead.
            local age_off = not tracker_on
                and string.sub(name, 1, #INFLIGHT_FAMILY) == INFLIGHT_FAMILY
            if not age_off then
                local value = d:get(key)
                if kind == "c" then
                    family(name).counters[rest] = value
                elseif kind == "g" then
                    family(name).gauges[rest] = value
                elseif kind == "h" then
                    family(name).histograms[rest] = json_decode(value)
                end
            end
        end
    end

    -- Per-worker gauges come straight from the registry, never from lr_stats.
    local registry = require "resty.luarouter.registry"
    local records = registry.records()
    local health_f = family("smg_worker_health")
    local active_f = family("smg_worker_requests_active")
    local cb_state_f = family("smg_worker_cb_state")
    local cb_fail_f = family("smg_worker_cb_consecutive_failures")
    local cb_succ_f = family("smg_worker_cb_consecutive_successes")
    for i = 1, #records do
        local record = records[i]
        local label = label_pairs({ { "worker", record.url } })
        local state = registry.cb_state(record.id)
        health_f.gauges[label] = state.healthy and 1 or 0
        active_f.gauges[label] = state.load
        cb_state_f.gauges[label] = state.state
        cb_fail_f.gauges[label] = state.consecutive_failures
        cb_succ_f.gauges[label] = state.consecutive_successes
    end
    -- Pool sizes are counted per unique (worker_type, connection_mode, model)
    -- triple straight out of the registry, and a combination with no workers is
    -- absent (Rust only ever calls set_worker_pool_size for combinations it saw
    -- registered).
    local pool_sizes = _M.pool_size_counts(records)
    if #pool_sizes > 0 then
        local pool_f = family("smg_worker_pool_size")
        for i = 1, #pool_sizes do
            pool_f.gauges[pool_sizes[i].labels] = pool_sizes[i].value
        end
    end
    -- Routing-key footprint of the manual policy, one series per worker that
    -- currently holds a key (see manual_routing_key_counts).
    local routing_keys = _M.manual_routing_key_counts()
    if next(routing_keys) ~= nil then
        local keys_f = family("smg_worker_routing_keys_active")
        for worker_url, count in pairs(routing_keys) do
            keys_f.gauges[label_pairs({ { "worker", worker_url } })] = count
        end
    end
    family("smg_http_inflight_requests").gauges[""] = _M.inflight()
    -- The tracker's own occupancy, read from the slot table rather than stored,
    -- so it cannot disagree with the samples the histogram was built from. With
    -- the sampler off (LR_INFLIGHT_SAMPLE_SECS=0) neither it nor the histogram is
    -- rendered: a tracker that never ran has nothing to report.
    if _M.inflight_enabled() then
        family("smg_http_inflight_request_age_slots_active").gauges[""] =
            _M.inflight_slots_used()
    end
    -- nginx's stub_status counters, when the module is compiled in (it is in
    -- both shipped images). Rust counts connections whose request future is
    -- being polled, so idle keep-alive sockets - the "waiting" state - are
    -- excluded to keep the two gauges measuring the same thing.
    local connections = _M.http_connections_active()
    if connections then
        family("smg_http_connections_active").gauges[""] = connections
    end

    local names = {}
    for name in pairs(metrics) do
        names[#names + 1] = name
    end
    table.sort(names)

    local out = {}
    for _, name in ipairs(names) do
        local f = metrics[name]
        local has_counter = next(f.counters) ~= nil
        local has_gauge = next(f.gauges) ~= nil
        local has_hist = next(f.histograms) ~= nil
        -- A family with no series at all is a derived one whose source was empty
        -- (no workers, no discovery polls yet). Rust's exporter omits those
        -- entirely, and declaring `# TYPE x untyped` above nothing would both
        -- disagree with the Rust scrape and mis-type a gauge that is merely idle.
        if has_counter or has_gauge or has_hist then
            local type_name = has_counter and "counter"
                or (has_gauge and "gauge" or (has_hist and "histogram" or "untyped"))
            if HELP[name] then
                out[#out + 1] = "# HELP " .. name .. " " .. HELP[name]
            end
            out[#out + 1] = "# TYPE " .. name .. " " .. type_name

            local labels = {}
            for label in pairs(f.counters) do
                labels[#labels + 1] = label
            end
            table.sort(labels)
            for _, label in ipairs(labels) do
                out[#out + 1] = name .. render_labels(label) .. " " .. tostring(f.counters[label])
            end

            labels = {}
            for label in pairs(f.gauges) do
                labels[#labels + 1] = label
            end
            table.sort(labels)
            for _, label in ipairs(labels) do
                out[#out + 1] = name .. render_labels(label) .. " " .. tostring(f.gauges[label])
            end

            labels = {}
            for label in pairs(f.histograms) do
                labels[#labels + 1] = label
            end
            table.sort(labels)
            for _, label in ipairs(labels) do
                local hist = f.histograms[label]
                if type(hist) == "table" then
                    -- Prometheus bucket series is cumulative: le=x counts every
                    -- observation <= x. observe() keeps b[i] per-bucket, so the
                    -- prefix sum happens here and only here.
                    local current, count = buckets()
                    local cumulative = 0
                    for i = 1, count do
                        local bucket_count_i = tonumber(hist.b and hist.b[i]) or 0
                        cumulative = cumulative + bucket_count_i
                        out[#out + 1] = name .. "_bucket"
                            .. render_bucket_labels(label, current[i]) .. " "
                            .. tostring(cumulative)
                    end
                    out[#out + 1] = name .. "_bucket"
                        .. render_bucket_labels(label, math.huge) .. " "
                        .. tostring(hist.n or 0)
                    out[#out + 1] = name .. "_sum" .. render_labels(label) .. " "
                        .. string.format("%.6f", tonumber(hist.s) or 0)
                    out[#out + 1] = name .. "_count" .. render_labels(label) .. " "
                        .. tostring(tonumber(hist.n) or 0)
                end
            end
        end
    end
    return table.concat(out, "\n") .. "\n"
end

_M.render_labels = render_labels
_M.label_pairs = label_pairs

return _M
