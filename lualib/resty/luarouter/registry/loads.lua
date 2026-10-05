-- registry.loads - load folding, external samples and the capacity gates (block O).
--
-- Cut verbatim out of registry.lua (refactor 2026-10-05,
-- doc/refactor-arch-2026-10-05.md section 1).
--
-- Two shapes here are load-bearing for the parity gates and are deliberately left
-- alone:
--   * load_with folds lo: + max(xl:, sl:) scaled by load_scale - that single ranking
--     rule is what power_of_two, manual min_load, cache_aware escape and the
--     WorkerInfo load field all read;
--   * capacity_exclusion is a hard admission gate, not a ranking term, and a missing
--     power reading means unknown: it never excludes. xl: and pw: never share a
--     field, because watts are an admission number and load is a score.

local M = {}

local keys = require "resty.luarouter.registry.keys"


local K_ACTIVE = keys.K_ACTIVE
local K_LOAD = keys.K_LOAD
local K_POWER = keys.K_POWER
local K_SLOAD = keys.K_SLOAD
local K_XANY = keys.K_XANY
local K_XLOAD = keys.K_XLOAD
local shdict = keys.shdict

-- The self-calls that read _M.x() in the original file resolve against the
-- registry facade, late-bound below so this module loads before the facade does.
local R

-- Weight of a fully busy worker: how many in-flight requests a 1.0 sample is
-- worth. Published by gpu_load.run_pass on every tick so the selection path never
-- reads the environment; the default keeps cache_aware's balance_abs_threshold (a
-- request-count-shaped knob, Rust default 64) inside its usable range.
local LOAD_SCALE_DEFAULT = 100
local load_scale = LOAD_SCALE_DEFAULT   -- set_load_scale override (tests, an operator knob)
local load_scale_from_cfg = false       -- memo of "the config value was applied"
local MEMO_SECS = 1
local memo_any = false
local memo_checked_at = -MEMO_SECS

---Scheduling load for one worker, in in-flight-request units.
--
--This is *the* consumer-facing load field: power_of_two and manual's min_load mode
--read it through registry.load(), and the standalone policies get it through
--router.lua's `record.load` snapshot and _M.info's `load` key. One ranking rule
--here therefore reaches every policy without any policy module knowing that a load
--source exists (doc/gap-gpu-load.md §4).
--
--Priority, highest first:
--  1. the router's own in-flight counter. Nothing else knows what this process
--     handed a worker and has not finished serving, and it is the only signal that
--     reacts within a millisecond of a burst.
--  2. `xl:` the external GPU sample. It outranks the self-report because it is the
--     only reading of the shared hardware: a worker with nothing in flight but a
--     95 %-busy GPU (a queue another router process filled, a sibling rank of the
--     same DP engine, a co-located second engine) must not look idle to
--     power_of_two, and only the metrics/prometheus source can see that.
--  3. `sl:` the engine's own self-report, consulted only when no fresh external
--     sample exists. The metrics source answers every worker it can reach, so in
--     practice one channel wins and the two never fight over a field.
--
--Both external terms are 0..1 fractions, so they are weighted by load_scale (a 1.0
--sample = load_scale in-flight requests) before being added; that weight is what
--keeps SMG_BALANCE_ABS_THRESHOLD meaningful whatever the knob measures. Samples
--expire with their TTL, which degrades to in-flight alone: a monitoring system
--that dies costs accuracy, never capacity, and never a worker.
---@param id string
---@return number @ load in in-flight units
function M.load(id)
    return R.load_with(shdict(), id)
end

---The same ranking against an already-resolved dict.
---
---_M.info/_M.list pass their dict in so a /workers sweep reads one dict once
---instead of resolving it per worker, and so a caller holding a dict (a test double,
---a future batch path) can rank without going through the module-level cache.
---@param d table @ an ngx.shared.DICT (or a test double with get)
---@param id string
---@return number
function M.load_with(d, id)
    local inflight = d:get(K_LOAD .. id) or 0
    if not R.any_external_samples() then
        return inflight
    end
    local milli = d:get(K_XLOAD .. id)
    if milli == nil then
        milli = d:get(K_SLOAD .. id)
    end
    if milli == nil then
        return inflight
    end
    return inflight + (milli * R.current_load_scale()) / 1000
end

---The external sample alone, normalized back to 0..1 (nil when there is none).
---Read by gpu_load's own reporting and the unit tests; the inference plane never
---needs it because _M.load already folded it in.
---@param id string
---@return number|nil load @ 0..1
function M.external_load(id)
    if not R.any_external_samples() then
        return nil
    end
    local milli = shdict():get(K_XLOAD .. id)
    if milli == nil then
        return nil
    end
    return milli / 1000
end

---Store one external GPU sample for a worker.
--
--Only gpu_load.lua (the metrics and prom sources) and the unit tests call this:
--the load source owns the key and there is no second writer, which is what makes
--the ranking in _M.load decidable rather than first-come-first-served.
---@param id string
---@param load number|nil @ normalized 0..1
---@param ttl_secs number|nil @ staleness window
---@return boolean written
function M.set_external_load(id, load, ttl_secs)
    local milli = R.to_milli(load)
    if milli == nil then
        return false
    end
    local seconds = R.stale_ttl(ttl_secs)
    if not shdict():set(K_XLOAD .. id, milli, seconds) then
        return false
    end
    R.flag_external_samples(seconds)
    return true
end

---Store one engine self-reported load (`/v1/loads`): the lower-priority channel.
---@param id string
---@param load number|nil @ normalized 0..1
---@param ttl_secs number|nil
---@return boolean written
function M.set_self_reported_load(id, load, ttl_secs)
    local milli = R.to_milli(load)
    if milli == nil then
        return false
    end
    local seconds = R.stale_ttl(ttl_secs)
    if not shdict():set(K_SLOAD .. id, milli, seconds) then
        return false
    end
    R.flag_external_samples(seconds)
    return true
end

---Drop both external channels for a worker (an operator override, or a test).
---@param id string
function M.clear_external_load(id)
    local d = shdict()
    d:delete(K_XLOAD .. id)
    d:delete(K_SLOAD .. id)
end

------------------------------------------------------------------ capacity caps
--
-- Per-worker ceilings on the two things that actually run a serving instance out
-- of headroom: requests in flight and watts the GPU is drawing (the latter is the
-- fleet's own reason for the feature -- a card pinned at its power limit decodes
-- noticeably slower than one at half load, and neither the request count nor the
-- utilization gauge shows it). doc/gap-worker-caps.md.

---Normalize one declared cap. Absent, blank, non-numeric, NaN, +/-inf or a value
---<= 0 all mean "no limit" and collapse to nil, so the selection path can test
---`cap ~= nil` without re-reading the environment, and a record that never
---declared a cap stores no key at all. Integers are floored for the concurrency
---cap: a fractional 2.5 slots would read "third request allowed" one way and
---"two slots" the other, and "at most 2" is the safe reading of both.
---@param value any
---@param integer boolean @ true for a request count, false for watts
---@return number|nil limit
function M.cap_limit(value, integer)
    local number = tonumber(value)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge or number <= 0 then
        return nil
    end
    if integer then
        return math.floor(number)
    end
    return number
end

---The router's own in-flight request count for one worker: the *pure* number,
---without the external GPU term that _M.load() adds. `lo:` is maintained by the
---hold/release pair in router.lua via shdict:incr, so it already spans every
---nginx process, and it is the same raw counter smg_worker_requests_active
---exports. The concurrency cap has to compare request counts, which is why it
---reads this key rather than load() (a mixed load would make a busy-but-not-full
---worker hit a request-count threshold it was never defined against).
---nil-safe: a worker with no key reads 0, exactly as load_with treats it.
---@param id string
---@return number inflight
---Touch the worker's activity clock (call on every completed request).
---The health sweep uses this to skip workers that just saw traffic.
---@param id string
function M.touch_active(id)
    shdict():set(K_ACTIVE .. id, ngx.now() * 1000)
end

---How long since the worker last saw traffic, in ms. nil = never seen.
---@param id string
---@return number|nil
function M.last_active_ms(id)
    local ts = shdict():get(K_ACTIVE .. id)
    if not ts or ts == 0 then return nil end
    return ngx.now() * 1000 - ts
end

function M.inflight_requests(id)
    return shdict():get(K_LOAD .. id) or 0
end

---Hard capacity gate for one candidate worker.
---
---Root ruling 2026-10-01: a worker at its configured in-flight or power ceiling
---must leave the candidate set even when cache_aware's affinity tree would have
---kept it here. So this is an *exclusion*, evaluated where candidates are
---assembled, not another term in the ranking: the policies' own load escape
---(balance_abs/rel thresholds, power_of_two's low-load branch) turns "busier"
---into "less preferred", which under affinity keeps exactly the traffic this
---rule is meant to move. Absent = selectable; a returned table = exclude, with
---{reason="concurrency"|"power"} and the two numbers that decided it so the
---caller can count and log which kind fired.
---
---The two readings are different in kind on purpose:
---  * concurrency is this gateway's own counter, always known;
---  * power is an external sample, and *missing means unknown, not zero*. A
---    monitoring system that dies must cost accuracy, never capacity, so a nil
---    sample never excludes -- the same rule the load samples follow, and the
---    reason the key is TTL'd rather than last-value-wins.
---Both caps default to unlimited, and an uncapped worker costs zero shdict reads.
---@param record table @ static record (needs id; cap fields optional)
---@param d table|nil @ shared dict (resolved when omitted)
---@return table|nil exclusion @ nil = selectable
function M.capacity_exclusion(record, d)
    if type(record) ~= "table" then
        return nil
    end
    local max_c = R.cap_limit(record.max_concurrency)
    local max_w = R.cap_limit(record.max_power_w)
    if max_c == nil and max_w == nil then
        return nil
    end
    d = d or shdict()
    local id = record.id
    if max_c ~= nil then
        local inflight = d:get(K_LOAD .. id) or 0
        if inflight >= max_c then
            return { reason = "concurrency", inflight = inflight,
                max_concurrency = max_c }
        end
    end
    if max_w ~= nil then
        local milli = d:get(K_POWER .. id)
        if milli ~= nil and milli >= max_w * 1000 then
            return { reason = "power", power_w = milli / 1000,
                max_power_w = max_w }
        end
    end
    return nil
end

---Store one raw watt sample for a worker (gpu_load's power pass is the only
---writer; unit tests may call it directly). Watts go in as milli-watts so gauge
---noise below one watt does not widen the key's type, and a negative or unusable
---reading is refused rather than clamped: "0 W" is a claim about the hardware
---that no exporter in this fleet can honestly make, and a stored 0 would read
---"far below any cap" for a worker whose exporter is misbehaving.
---@param id string
---@param watts number|nil
---@param ttl_secs number|nil
---@return boolean written
function M.set_power_w(id, watts, ttl_secs)
    local number = tonumber(watts)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge or number < 0 then
        return false
    end
    local seconds = R.stale_ttl(ttl_secs)
    local ok, err = shdict():set(K_POWER .. id,
        math.floor(number * 1000 + 0.5), seconds)
    if not ok then
        -- No-capacity-on-the-dict is the only way this fails and it is worth one
        -- line: the cap silently stops being enforceable for this worker until the
        -- sample TTLs out or the exporter refills it.
        if ngx and ngx.log then
            ngx.log(ngx.WARN, "luarouter: power sample for ", tostring(id),
                " not stored: ", tostring(err))
        end
        return false
    end
    return true
end

---The fresh watt sample for one worker: nil when there is none (an absent sample
---is *unknown*, and never collapses to 0 -- that distinction is what makes the
---power cap safe to leave switched on).
---@param id string
---@return number|nil watts
function M.power_w(id)
    local milli = shdict():get(K_POWER .. id)
    if milli == nil then
        return nil
    end
    return milli / 1000
end

---Every fresh watt sample, keyed by worker id. The exporter and the UI pool
---table both want the whole table (N single lookups over a shared dict is the
---shape this module has already paid for in _M.records).
---@return table @ worker id -> watts
function M.power_samples()
    local out = {}
    local d = shdict()
    if type(d.get_keys) ~= "function" then
        return out
    end
    for _, key in ipairs(d:get_keys(0)) do
        if type(key) == "string" and #key > #K_POWER
            and string.sub(key, 1, #K_POWER) == K_POWER then
            local value = d:get(key)
            if value ~= nil then
                out[string.sub(key, #K_POWER + 1)] = value / 1000
            end
        end
    end
    return out
end

---Drop the power sample (an operator override, a re-registration, or a test;
---TTL expiry is the ordinary life cycle).
---@param id string
function M.clear_power_w(id)
    shdict():delete(K_POWER .. id)
end

---Normalized 0..1 -> milli integer, nil for anything unusable. NaN and the
---infinities answer nil: they compare false against everything, so storing one
---would strand a worker at whatever the previous sample said.
---@param load number|nil
---@return number|nil milli
function M.to_milli(load)
    local number = tonumber(load)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge then
        return nil
    end
    if number < 0 then
        number = 0
    elseif number > 1 then
        number = 1
    end
    return math.floor(number * 1000 + 0.5)
end

---Staleness window of one sample. The TTL is what makes an expired reading stop
---being a load, so a caller that knows its interval always passes it; the default
---only covers a bare call from a test.
---@param ttl_secs number|nil
---@return number
function M.stale_ttl(ttl_secs)
    local seconds = tonumber(ttl_secs)
    if seconds == nil or seconds <= 0 or seconds ~= seconds then
        seconds = 45
    end
    return math.min(math.max(seconds, 5), 3600)
end

---Whether any worker currently has an external sample (memoized per process).
---@return boolean
function M.any_external_samples()
    local now = ngx.now()
    if now - memo_checked_at >= MEMO_SECS then
        memo_checked_at = now
        memo_any = shdict():get(K_XANY) ~= nil
    end
    return memo_any
end

---Publish the shared flag with the TTL of the sample that justified it. The TTL is
---what retires the flag when the source stops: an expired key sends the readers back
---to the in-flight counter without anything having to clean up, and a load source
---that never stores a sample never writes this key at all.
---@param ttl_secs number
---@return boolean written
function M.flag_external_samples(ttl_secs)
    if not shdict():set(K_XANY, 1, R.stale_ttl(ttl_secs)) then
        return false
    end
    -- The writer sees its own flag immediately: a policy in this process should not
    -- wait out the memo for the sample it just stored.
    memo_any = true
    memo_checked_at = ngx.now()
    return true
end

---Forget the flag as well as the samples (an operator override / a test).
function M.clear_external_samples_flag()
    shdict():delete(K_XANY)
    memo_any = false
    memo_checked_at = -MEMO_SECS
end

---Publish the weight of a fully busy worker. gpu_load.run_pass calls this on every
---tick, so an edited SMG_LOAD_SCALE lands on the next pass without a reload.
---@param scale number|nil
---@return number applied
function M.set_load_scale(scale)
    local number = tonumber(scale)
    if number == nil or number ~= number or number <= 0 then
        return load_scale
    end
    load_scale = number
    load_scale_from_cfg = true   -- an explicit override outranks the config value
    return load_scale
end

---Current weight of a fully busy worker.
---@return number
function M.load_scale()
    return load_scale
end

---The weight actually in force: an explicit set_load_scale wins, otherwise the
---env-published SMG_LOAD_SCALE from the config snapshot (identical in every process).
---
---The load timer that would otherwise publish this runs in worker 0 only, so a
---Lua-local written from the pass would leave the other processes on the default and
---make power_of_two rank the same pair of workers differently depending on which
---process answered. config.load_scale is read lazily -- one table field on the first
---sampled request -- and only superseded by an explicit set_load_scale.
---@return number
function M.current_load_scale()
    if not load_scale_from_cfg then
        load_scale_from_cfg = true
        local ok_cfg, outer = pcall(require, "resty.luarouter")
        if ok_cfg and type(outer) == "table" and type(outer.config) == "function" then
            local ok, conf = pcall(outer.config)
            local configured = ok and type(conf) == "table"
                and tonumber(conf.load_scale) or nil
            if configured and configured > 0 then
                load_scale = configured
            end
        end
    end
    return load_scale
end

---@param id string
---@param delta number
---@return number @ load after the change
function M.change_load(id, delta)
    local d = shdict()
    local value, err = d:incr(K_LOAD .. id, delta, 0)
    if not value then
        d:set(K_LOAD .. id, 0)
        value = 0
    end
    if value < 0 then
        d:set(K_LOAD .. id, 0)
        return 0
    end
    return value
end

-- Late-bind the facade: registry.lua pre-registers package.loaded before it
-- requires this module, and a test that swaps the whole module table for a stub
-- through package.loaded is honoured by the same lookup.
R = package.loaded["resty.luarouter.registry"] or require "resty.luarouter.registry"

return M
