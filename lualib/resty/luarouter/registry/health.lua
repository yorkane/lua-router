-- registry.health - the health bit and the circuit breaker (blocks N of registry.lua).
--
-- Cut verbatim out of registry.lua (refactor 2026-10-05,
-- doc/refactor-arch-2026-10-05.md section 1).
--
-- Discipline that must not be rephrased:
--   * counters that mean consecutive are charged with shdict:incr (charge_cb) and any
--     state flip is re-read under the registry lock (flip_cb, breaker_available).
--     A get()/set() pair loses updates across nginx processes;
--   * breaker_available owns the single recovery clock: the open -> half_open timed
--     flip happens there and only there, under with_lock, with the state re-read
--     inside so exactly one caller performs the transition;
--   * hf:/hs: have a second writer on purpose - hb.lua incr/set them directly for
--     cross-process-safe counting (see the key layout in registry.keys).
--
-- The self-calls that originally read _M.x() go through the registry facade (R),
-- which is what keeps the test double/stub points where they were.

local M = {}

local cjson = require "cjson.safe"
local keys = require "resty.luarouter.registry.keys"

local json_decode = cjson.decode
local mesh_mirror = keys.mesh_mirror

local CB_STATE_NAME = keys.CB_STATE_NAME
local K_CBF = keys.K_CBF
local K_CBO = keys.K_CBO
local K_CBS = keys.K_CBS
local K_CBSTATE = keys.K_CBSTATE
local K_HEALTH = keys.K_HEALTH
local K_HFAIL = keys.K_HFAIL
local K_HSUCC = keys.K_HSUCC
local K_IDURL = keys.K_IDURL
local K_LOAD = keys.K_LOAD
local K_WORKER = keys.K_WORKER
local shdict = keys.shdict
local with_lock = keys.with_lock

-- The self-calls that read _M.x() in the original file resolve against the
-- registry facade, late-bound below so this module loads before the facade does.
local R

---@param id string
---@return boolean
---Worker URL for breaker metric labels (Rust labels those with the URL, not the
---id). Falls back to the id for a record written before the reverse key existed.
---@param id string
---@return string
function M.url_for(id)
    local d = shdict()
    local url = d:get(K_IDURL .. id)
    if url then
        return url
    end
    local record = json_decode(d:get(K_WORKER .. id) or "")
    if type(record) == "table" and record.url then
        d:set(K_IDURL .. id, record.url)
        return record.url
    end
    return id
end

---@param id string
---@return boolean
function M.is_healthy(id)
    return (shdict():get(K_HEALTH .. id) or 0) == 1
end

---@param id string
---@param healthy boolean
function M.set_healthy(id, healthy)
    shdict():set(K_HEALTH .. id, healthy and 1 or 0)
    -- The cluster view advertises worker health (Rust's WorkerState.health), and a
    -- flip is exactly when a peer's view goes stale. Mirroring here rather than in
    -- the health sweep means every writer of health gets it for free, and the
    -- version bump inside observe_worker is what makes the update propagate.
    mesh_mirror(id)
end

---A worker is selectable when healthy and its breaker is not open.
---
--- An open circuit is not permanent: once cb_timeout_duration_secs has elapsed
--- the breaker half-opens so the next request can probe it. The flip happens
--- here because this is the only place every selection path goes through, which
--- is how the Rust gateway behaves too (is_available() calls
--- circuit_breaker().can_execute(), and can_execute() runs the state check).
--- The CAS on the state key makes exactly one concurrent selector perform the
--- transition, mirroring the compare_exchange in core/circuit_breaker.rs.
---Circuit-breaker availability, including the timed open -> half_open flip.
---Every selection path reads it through is_available, so a worker can only ever
---have one recovery clock.
---@param id string
---@return boolean
function M.breaker_available(id)
    local d = shdict()
    local key = K_CBSTATE .. id
    local state = d:get(key) or keys.CB_CLOSED
    if state ~= keys.CB_OPEN then
        return true
    end

    local conf = require("resty.luarouter").config()
    if conf.disable_circuit_breaker then
        return true
    end

    local elapsed_ms = ngx.now() * 1000 - (d:get(K_CBO .. id) or 0)
    if elapsed_ms < conf.cb_timeout_duration_secs * 1000 then
        return false
    end

    -- This image has no shdict CAS, so the single-writer flip runs under the
    -- same registry lock the add/remove paths use. Whoever takes it performs the
    -- transition; everyone else just observes half_open and stays selectable.
    with_lock(function()
        local dd = shdict()
        if (dd:get(key) or keys.CB_CLOSED) ~= keys.CB_OPEN then
            return
        end
        dd:set(key, keys.CB_HALF_OPEN)
        dd:set(K_CBO .. id, ngx.now() * 1000)
        dd:set(K_CBF .. id, 0)
        dd:set(K_CBS .. id, 0)
        local label = R.url_for(id)
        local ok_obs, observability = pcall(require, "resty.luarouter.observability")
        if ok_obs then
            observability.record_cb_transition(label, "open", "half_open")
        end
    end)
    return true
end

---Health, pool membership and breaker for the HTTP inference plane.
---@param id string
---@return boolean
function M.is_available(id)
    if (shdict():get(K_HEALTH .. id) or 0) ~= 1 then
        return false
    end
    -- Pool gate: a non-HTTP record is invisible to the inference plane, and
    -- router.lua's candidate filter runs is_available on every route, so gating
    -- here keeps the HTTP surface byte-identical without touching router.lua.
    if not R.http_selectable(id) then
        return false
    end
    return R.breaker_available(id)
end

---Resilience state, used by hb.lua and the metrics exporter.
---@param id string
---@return table
function M.cb_state(id)
    local d = shdict()
    local state = d:get(K_CBSTATE .. id) or keys.CB_CLOSED
    return {
        state = state,
        state_name = CB_STATE_NAME[state + 1] or "closed",
        consecutive_failures = d:get(K_CBF .. id) or 0,
        consecutive_successes = d:get(K_CBS .. id) or 0,
        opened_at_ms = d:get(K_CBO .. id) or 0,
        healthy = (d:get(K_HEALTH .. id) or 0) == 1,
        health_failures = d:get(K_HFAIL .. id) or 0,
        health_successes = d:get(K_HSUCC .. id) or 0,
        -- Deliberately the raw in-flight counter, not _M.load(): this table feeds
        -- smg_worker_requests_active, whose Rust counterpart counts running requests
        -- per worker. Folding a GPU sample in here would make the gauge disagree
        -- with the router's own concurrency counters for no scheduling benefit.
        load = d:get(K_LOAD .. id) or 0,
    }
end

---@param id string
function M.set_cb_state(id, state, opened_at_ms)
    local d = shdict()
    d:set(K_CBSTATE .. id, state)
    if opened_at_ms then
        d:set(K_CBO .. id, opened_at_ms)
    end
end

---Accumulate one breaker outcome atomically.
---
---The counters mean "consecutive", so the other side is zeroed; the charged side
---uses shdict:incr(), which is the only cross-process-safe way to add one. A
---get()+set() pair loses updates when several nginx workers charge the same
---worker in the same window (four processes reading failures=2 all write 3),
---which delays the open transition far past cb_failure_threshold.
---@param id string
---@param success boolean
---@return number failures @ count after the update
---@return number successes @ count after the update
function M.charge_cb(id, success)
    local d = shdict()
    if success then
        d:set(K_CBF .. id, 0)
        local value, err = d:incr(K_CBS .. id, 1, 0)
        if not value then
            d:set(K_CBS .. id, 1)
            value = 1
        end
        return 0, value
    end
    d:set(K_CBS .. id, 0)
    local value, err = d:incr(K_CBF .. id, 1, 0)
    if not value then
        d:set(K_CBF .. id, 1)
        value = 1
    end
    return value, 0
end

---Breaker state flip, re-checked under the registry lock.
---
---Every process that crosses a threshold calls this; the lock plus the
---expected-state check makes exactly one of them perform the transition, so the
---transition metric and the log line are not counted per process. Closing also
---clears both counters (an open circuit keeps its failure count for the metrics
---page, which is what the Rust gateway shows too).
---@param id string
---@param expect number @ state the caller observed
---@param next_state number
---@param opened_at_ms number|nil @ stamped when the circuit opens
---@return boolean changed @ true when this caller performed the flip
function M.flip_cb(id, expect, next_state, opened_at_ms)
    local changed = false
    with_lock(function()
        local d = shdict()
        if (d:get(K_CBSTATE .. id) or keys.CB_CLOSED) ~= expect then
            return
        end
        d:set(K_CBSTATE .. id, next_state)
        if opened_at_ms then
            d:set(K_CBO .. id, opened_at_ms)
        end
        if next_state == keys.CB_CLOSED then
            d:set(K_CBF .. id, 0)
            d:set(K_CBS .. id, 0)
        end
        changed = true
    end)
    return changed
end

---@param id string
function M.set_cb_counters(id, failures, successes)
    local d = shdict()
    d:set(K_CBF .. id, failures)
    d:set(K_CBS .. id, successes)
end

---@param id string
---@param failures number|nil @ nil keeps the stored value
---@param successes number|nil
function M.set_health_counters(id, failures, successes)
    local d = shdict()
    if failures then
        d:set(K_HFAIL .. id, failures)
    end
    if successes then
        d:set(K_HSUCC .. id, successes)
    end
end

-- ---------------------------------------------------------- metadata discovery

-- Late-bind the facade: registry.lua pre-registers package.loaded before it
-- requires this module, and a test that swaps the whole module table for a stub
-- through package.loaded is honoured by the same lookup.
R = package.loaded["resty.luarouter.registry"] or require "resty.luarouter.registry"

return M
