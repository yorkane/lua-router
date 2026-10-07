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
--     reading means unknown: it never excludes. capacity_state is the one place the
--     three-way verdict (idle/busy/full) is computed - the /workers echo and the
--     router's green-light narrowing both read *that*, so no second caller can derive
--     the traffic-light from a different mix of readings (doc/caps-redesign-2026-10-06.md
--     section 2). xl:, pw: and gu: never share a field with each other or with the
--     in-flight counter, because a score and an admission number are different kinds.

local M = {}

local keys = require "resty.luarouter.registry.keys"


local K_ACTIVE = keys.K_ACTIVE
local K_GPU_UTIL = keys.K_GPU_UTIL
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
---@param integer boolean @ true for a request count, false for a float reading
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

---Normalize one declared GPU-utilisation ceiling in percent (0..100). This is
---deliberately *not* cap_limit: the utilisation scale carries a meaningful zero
---(`max_gpu_util = 0` is the legal strictest rung - any fresh reading at all means
-- "full"), so only a missing, non-numeric, NaN, +/-inf or negative value means
---"no limit". The value is floored to an integer percent; a stored 0 must survive,
---and clearing the cap is spelled "absent" or any negative number, both of which
---fold to nil here and therefore to "no gate" at read time
---(doc/caps-redesign-2026-10-06.md section 1).
---@param value any
---@return number|nil limit @ integer percent, or nil for "unlimited"
function M.util_limit(value)
    local number = tonumber(value)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge or number < 0 then
        return nil
    end
    return math.floor(number)
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

---------------------------------------------------------------- capacity verdict
--
-- Per-worker ceilings on the two things that actually run a serving instance out of
-- headroom: requests in flight (this gateway's own counter) and how busy the GPU
-- actually is (an external sample). doc/caps-redesign-2026-10-06.md replaces the
-- 2026-10-01 two-way gate with a three-way verdict, and the verdict - not the
-- caller - is what owns the comparison:
--
--   full  inflight >= max_concurrency, or a *fresh* gu: sample at/over max_gpu_util
--   idle  not full, and inflight < min_concurrency (an absent min reads 1)
--   busy  everything else
--   nil   no ceiling of any kind declared: no gate at all, i.e. today's behaviour
--
-- Three rules decide every shape below, and they are the reason a caller must not
-- recompute this at home:
--   * the readings are different in kind. `lo:` is this gateway's counter and is
--     always known (a missing key is 0 in-flight, never "unknown"); `gu:` is an
--     external sample whose absence means *unknown, not zero* - a monitoring
--     system that dies must cost accuracy, never capacity, so it never excludes.
--     That is why `gu:` is TTL'd rather than last-value-wins.
--   * `gu:` is read raw and never through _M.load. `xl:` - the ranking channel -
--     is scaled by load_scale into in-flight-request units, so comparing a
--     utilisation ceiling against it would make a scoring knob move an admission
--     gate. See the header comment of registry/keys.lua.
--   * the watt ceiling left the verdict on 2026-10-06. `pw:` and its exporter
--     family stay (pure observation), but no capacity decision reads them any
--     more, and the reason strings "concurrency"/"power" are retired.

---The verdict behind both public faces: the traffic-light plus the numbers that
---decided it. Private so that `capacity_state` stays exactly the one-value
---predicate the UI contract pins it to.
---@param record table
---@param d table|nil
---@return string|nil state @ "idle"|"busy"|"full", nil = no gate declared
---@return table|nil verdict @ set only for "full": the reason and its two numbers
local function capacity_verdict(record, d)
    if type(record) ~= "table" then
        return nil
    end
    -- One normalization for all three integer ceilings, and deliberately the same call
    -- shape the old gate used for max_concurrency (no floor): records.add stores the
    -- floored value, info() echoes the unfloored reading, and the verdict has to read
    -- the same number the console shows. The 1..31 / 1..32 range rules belong to the
    -- declaration layer (config_store), which is what the router-side consumer of
    -- these names was written against.
    local max_c = R.cap_limit(record.max_concurrency)
    local min_c = R.cap_limit(record.min_concurrency)
    local max_u = M.util_limit(record.max_gpu_util)
    if max_c == nil and min_c == nil and max_u == nil then
        return nil
    end
    d = d or shdict()
    local id = record.id
    local inflight = tonumber(d:get(K_LOAD .. id)) or 0

    if max_c ~= nil and inflight >= max_c then
        return "full", { reason = "concurrency_max", inflight = inflight,
            max_concurrency = max_c }
    end
    if max_u ~= nil then
        local milli = tonumber(d:get(K_GPU_UTIL .. id))
        -- Integer arithmetic: milli is percent x 10 and the ceiling is a percent, so
        -- milli >= max_u * 10 is the same comparison without a float division.
        if milli ~= nil and milli >= max_u * 10 then
            return "full", { reason = "gpu_util", gpu_util = milli / 1000,
                max_gpu_util = max_u }
        end
    end
    -- The lower rung only ever *adds* an idle/busy distinction: no ceiling of its own
    -- was reached above, and a worker cannot be "full" because it is too empty.
    if inflight < (min_c or 1) then
        return "idle"
    end
    return "busy"
end

---Three-way capacity state of one worker, or nil when it declares no ceiling.
---
---This is the *single* place the traffic-light is computed: `GET /workers` echoes it
---as the read-only `load_state` field (registry.records.info) and the router's
---green-light narrowing (router/candidates.lua) trims its candidate array with it, so
---the console colour and the scheduling decision cannot drift apart. The UI must
---display this value and never re-derive it from inflight/cap pairs of its own.
---
---Non-counting by construction: nothing here touches observability, and the only
---call site that bills a metric is the counted candidate-assembly pass going through
---_M.capacity_exclusion (forward.lua's selection pass). An N-worker pool where two
---processes both computed - and counted - the same verdict would double-count, which
---is why this function returns a string and no counter.
---@param record table @ static record (needs id; cap fields optional)
---@param d table|nil @ shared dict (resolved when omitted)
---@return string|nil state @ "idle" | "busy" | "full" | nil (no gate)
function M.capacity_state(record, d)
    local state = capacity_verdict(record, d)
    return state
end

---Hard capacity gate for one candidate worker: set only for a "full" verdict.
---
---Root ruling 2026-10-01: a worker at its configured ceiling must leave the candidate
---set even when cache_aware's affinity tree would have kept it here, so this is an
---*exclusion* evaluated where candidates are assembled, not another term in the
---ranking - the policies' own load escape turns "busier" into "less preferred", which
---under affinity keeps exactly the traffic this rule is meant to move. Root ruling
---2026-10-06: the gate fires on `capacity_state == "full"` and nothing else; idle and
---busy stay selectable (the green-light preference is a narrowing, not an exclusion).
---
---Absent = selectable; a returned table = exclude, with {reason=
---"concurrency_max"|"gpu_util"} and the two numbers that decided it so the caller can
---count and log which kind fired. The caller's pcall and the
---"predicate missing = no gate" fail-open discipline stay in router/candidates.lua.
---@param record table @ static record (needs id; cap fields optional)
---@param d table|nil @ shared dict (resolved when omitted)
---@return table|nil exclusion @ nil = selectable
function M.capacity_exclusion(record, d)
    local state, verdict = capacity_verdict(record, d)
    if state ~= "full" then
        return nil
    end
    return verdict
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
    -- Bounded: this is a render-time read (the /metrics power section and the UI pool
    -- table), and get_keys(0) walks the whole lr_workers dict inside the single
    -- forwarding worker on every scrape. Rows only leave lr_workers when a worker is
    -- deleted, so the scan length tracks the pool's history rather than its size.
    -- 4096 is ~500x the largest pool we run; a dict that big is the case where a
    -- cheaper scrape is the point. Power rows are also the only key family here that
    -- a *worker* writes every pass, so truncation shows up as missing watts, never as
    -- a mis-routed request.
    for _, key in ipairs(d:get_keys(4096)) do
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

---Store one raw GPU-utilisation sample for a worker.
--
--gpu_load's util pass is the only production writer (unit tests may call it
--directly), which is the same one-writer-per-key discipline `xl:` and `pw:` follow. The
--fraction goes in as integer milli (percent x 10) so gauge noise below 0.1 % cannot
--widen the key's type, exactly as the watt channel rounds to milli-watts.
--
--Unlike `to_milli` - the *scoring* normalizer, which clamps whatever it is handed into
--0..1 so a nonsense sample still ranks the worker - this gate feeds an admission
--decision, and a stored number there is a claim about hardware. A negative or unusable
--reading is therefore refused rather than clamped: `set_power_w` already refuses a
--negative watt for the same reason, and "0 % busy" is precisely the reading a broken
--exporter would produce for a saturated card, which would silently disarm the ceiling.
--Only out-of-range *above* clamps (a DCGM gauge that momentarily answers 105 %).
---@param id string
---@param frac number|nil @ pure utilisation as a 0..1 fraction
---@param ttl_secs number|nil @ staleness window
---@return boolean written
function M.set_gpu_util(id, frac, ttl_secs)
    local number = tonumber(frac)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge or number < 0 then
        return false
    end
    if number > 1 then
        number = 1
    end
    local seconds = R.stale_ttl(ttl_secs)
    local ok, err = shdict():set(K_GPU_UTIL .. id,
        math.floor(number * 1000 + 0.5), seconds)
    if not ok then
        -- No-capacity-on-the-dict is the only way this fails, and it is worth one
        -- line: the utilisation gate silently stops being enforceable for this worker
        -- until the sample TTLs out or the exporter refills it.
        if ngx and ngx.log then
            ngx.log(ngx.WARN, "luarouter: gpu util sample for ", tostring(id),
                " not stored: ", tostring(err))
        end
        return false
    end
    return true
end

---The fresh utilisation sample for one worker: nil when there is none (an absent
---sample is *unknown*, and never collapses to 0 - that distinction is what makes the
---utilisation ceiling safe to leave switched on, and the reason the key is TTL'd).
---@param id string
---@return number|nil util @ 0..1
function M.gpu_util(id)
    local milli = shdict():get(K_GPU_UTIL .. id)
    if milli == nil then
        return nil
    end
    return milli / 1000
end

---Drop the utilisation sample (an operator override, a re-registration, or a test;
---TTL expiry is the ordinary life cycle).
---@param id string
function M.clear_gpu_util(id)
    shdict():delete(K_GPU_UTIL .. id)
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
