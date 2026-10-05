-- observability.inflight —— 在飞请求年龄 tracker（lr_stats 的 i| 定长槽表）。
-- 自包含：1024 槽 + 4 探针、约 f^INFLIGHT_PROBES 丢新登记；四个 knob 由
-- init_by_lua 注入（LR_INFLIGHT_*）。只依赖门面的写侧私有把手（statsdict/
-- buckets/histo_key）与门面导出（_M.counter / _M.inflight_enabled）；抓取侧的
-- INFLIGHT_FAMILY 前缀过滤属导出器同域契约，留在 observability.lua 门面。
local _M = require "resty.luarouter.observability"
local internal = require "resty.luarouter.observability._internal"

local statsdict = internal.statsdict

-- store_age_snapshot 是本模块唯一的 JSON 写者（它绕开 observe() 做单次编解码）。
local json_encode = require("cjson.safe").encode
local buckets = internal.buckets
local histo_key = internal.histo_key

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

return { priv = {} }
