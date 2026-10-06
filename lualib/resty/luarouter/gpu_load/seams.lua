local _M = require "resty.luarouter.gpu_load"
local M = {}   -- cross-module helper surface (not part of _M)

-- gpu_load/seams.lua -- the live seams: the lazy hb/registry module
-- resolvers, the nine default_* injection points (workers / get / post /
-- write / write_power / gpu_hints / now ...), the bearer header helper,
-- the effective-load priority rule and the hour-window WARN dedup.
-- default_gpu_hints pcalls resty.luarouter.watcher lazily on purpose: a
-- load-time require here would close the watcher -> ... -> gpu_load
-- cycle, and it is why the per-card channel can be entirely absent
-- without costing the power cap its honesty.  Moved verbatim.

---Whether this file is running inside nginx *right now*.
---
---Deliberately a predicate rather than the load-time snapshot watcher.lua and
---mesh.lua use: the pure-Lua half of this module is unit-tested under luajit with
---no ngx at all, and the live half (warn dedup, the metric families, the timer) has
---to be testable in the same file. Reading the global per call keeps both halves
---honest and costs one global lookup on paths that run once per worker per tick.
---@return table|nil @ the ngx global, or nil outside nginx
local function live_ngx()
    if type(ngx) ~= "table" then
        return nil
    end
    return ngx
end

-- One WARN line per (class, target) inside this window.
local WARN_DEDUP_SECS = 3600

local function now_ms()
    local ngxm = live_ngx()
    if ngxm and ngxm.now then
        return ngxm.now() * 1000
    end
    return os.time() * 1000
end

------------------------------------------------------------------ the priority rule

---Scheduling load for one worker: the router's own in-flight counter plus the
---external GPU sample when there is a fresh one.
---
---Why this is the priority order (doc/gap-gpu-load.md §4):
---  * The external source (metrics/prom) is the *only* writer of the GPU sample,
---    and it wins the definition of "load": a worker with no request in flight but
---    an 95 %-busy GPU must not look idle to power_of_two, and in-flight alone
---    cannot see a queue that another router process (or another router entirely)
---    filled.
---  * The in-flight term stays in the sum because the router is the only party
---    that knows what it just handed a worker and has not finished serving;
---    dropping it would make a burst look flat until the next load tick.
---  * The engine self-report path (`/v1/loads`, whose `aggregate.total_tokens` is
---    what Rust caches) deliberately does *not* feed this field: that endpoint
---    stays a live pull the router answers on demand (router.lua's loads_handler)
---    and never writes the registry, so the two channels cannot step on each
---    other. If a self-report fan-out is ever added, it has to write a *separate*
---    key and this function is the single place that decides the ranking: external
---    GPU sample first, self-report only as the fallback when there is none.
---  * `scale` exists because the two terms arrive in different units: the sample
---    is a 0..1 fraction while in-flight is a request count. Multiplying the
---    fraction by 100 (SMG_LOAD_SCALE) makes a 0.01 utilisation gap worth one
---    in-flight request, which keeps cache_aware's balance_abs_threshold (a
---    request-count-shaped knob, default 64) inside its usable range instead of
---    silently disabling the escape.
---@param external number|nil @ normalized 0..1, or nil when no fresh sample
---@param inflight number|nil
---@param scale number|nil @ value of a fully busy worker (default 100)
---@return number load
function _M.effective_load(external, inflight, scale)
    local pending = tonumber(inflight) or 0
    if pending < 0 then
        pending = 0
    end
    local sample = tonumber(external)
    if sample == nil then
        return pending
    end
    if sample < 0 then
        sample = 0
    elseif sample > 1 then
        sample = 1
    end
    local weight = tonumber(scale)
    if weight == nil then
        weight = 100
    end
    return pending + sample * weight
end

------------------------------------------------------------------ live layer

local function hb_mod()
    local ok, hb = pcall(require, "resty.luarouter.hb")
    if ok and type(hb) == "table" then
        return hb
    end
    return nil
end

local function registry_mod()
    local ok, registry = pcall(require, "resty.luarouter.registry")
    if ok and type(registry) == "table" then
        return registry
    end
    return nil
end

---In-pool workers, i.e. the ones the inference plane can actually be given. The
---health sweep has its own filter (it probes everything, including the workers
---registered with disable_health_check) and the load source wants the *pool*, so
---this asks registry.http_selectable and keeps workers the sweep skips.
---@return table[]
local function default_workers()
    local registry = registry_mod()
    if not registry then
        return {}
    end
    local out = {}
    local records = registry.records() or {}
    for i = 1, #records do
        local record = records[i]
        local selectable = true
        if type(registry.http_selectable) == "function" then
            local ok_sel, sel = pcall(registry.http_selectable, record.id)
            selectable = (not ok_sel) or sel ~= false
        end
        if selectable and type(record.url) == "string" then
            out[#out + 1] = record
        end
    end
    return out
end

---Per-card power reads the worker->gpu hint table off the watcher's ledger.
---
---Lazy pcall(require) like registry_mod()/hb_mod(): gpu_load must not require the
---watcher at load time (a require cycle watcher -> ... -> gpu_load would deadlock
---the first request that loads either), and outside nginx there is no lr_watch
---dict to read anyway. When the watcher is absent or its dict is not declared, the
---snapshot is empty and the per-card channel simply falls back to labels.gpu and
---then to the whole-machine max -- i.e. exactly the pre-feature behaviour. That is
---why this is a *hint* channel and not the source of truth: it can be entirely
---missing and the power cap stays as honest as it was before per-card attribution.
---@return table @ url -> gpu id
local function default_gpu_hints()
    local ok, watcher = pcall(require, "resty.luarouter.watcher")
    if not ok or type(watcher) ~= "table"
        or type(watcher.gpu_hint_snapshot) ~= "function" then
        return {}
    end
    local ok2, hints = pcall(watcher.gpu_hint_snapshot)
    if ok2 and type(hints) == "table" then
        return hints
    end
    return {}
end

local function default_get(url, timeout_ms, headers)
    local hb = hb_mod()
    if not hb then
        return nil, nil, "hb unavailable"
    end
    return hb.http_get(url, timeout_ms, headers)
end

local function default_post(url, timeout_ms, headers, body)
    local hb = hb_mod()
    if not hb then
        return nil, nil, "hb unavailable"
    end
    return hb.http_request("POST", url, timeout_ms, headers, body, "probe")
end

---Store one sample and publish its per-worker gauge. The gauge write is guarded
---because observability is not allowed to cost a load sample: the registry is the
---authority, the exporter is a copy.
---@param id string
---@param value number|nil @ normalized 0..1
---@param timestamp number @ ms clock (accepted for seam symmetry, unused here)
---@param ttl_secs number
---@param url string|nil @ only for the gauge label
---@return boolean written
local function default_write(id, value, timestamp, ttl_secs, url)
    local registry = registry_mod()
    if not registry or type(registry.set_external_load) ~= "function" then
        return false
    end
    local written = registry.set_external_load(id, value, ttl_secs)
    if written and url then
        _M.publish_worker_gauge(url, value)
    end
    return written
end

---Store one **watt** sample on the registry's independent `pw:` key.
---
---Why two return values rather than a boolean: the caller must distinguish "there
---was no reading to store" (nothing is written, the old sample simply TTLs out and
---the cap reads *unknown*) from "a reading registry refused" (a genuinely broken
---exporter, worth a counter), and both from a stored sample. This layer never
---writes 0 and never repeats the previous value — that is exactly what makes the
---power cap safe to leave switched on. registry.set_power_w() already rejects
---negatives/NaN/±inf; what is added here is the seam symmetry with
---default_write() and the per-worker gauge.
---@param id string
---@param watts number|nil @ absolute watts
---@param timestamp number @ ms clock (accepted for seam symmetry, unused here)
---@param ttl_secs number
---@param url string|nil @ only for the gauge label
---@return boolean stored, string reason
local function default_write_power_inner(id, watts, ttl_secs, url)
    local registry = registry_mod()
    if not registry or type(registry.set_power_w) ~= "function" then
        return false, "no-registry"
    end
    local stored = registry.set_power_w(id, watts, ttl_secs)
    if not stored then
        return false, "rejected"
    end
    if url then
        _M.publish_worker_power_gauge(url, watts)
    end
    return true, "stored"
end

---Store one watt sample, telling the two kinds of "not stored" apart.
---
---registry.set_power_w() answers false both when it refuses an unusable number
---(negative / NaN / ±inf) and when the shared dict simply had no room — the first
---means the exporter is lying, the second means this gateway is out of memory, and
---an operator reading one counter must not be sent looking at the wrong one. So
---the value is re-screened here with the same predicate the parsers use: if it is
---valid, a false from registry can only be the dict, which is counted as an error
---of *this* module rather than a rejection. (The "rejected" branch is therefore
---rare by construction — everything reaching here already passed power_watt().)
---@param id string
---@param watts number|nil @ absolute watts
---@param timestamp number @ ms clock (accepted for seam symmetry, unused here)
---@param ttl_secs number
---@param url string|nil @ only for the gauge label
---@return boolean stored, string reason
local function default_write_power(id, watts, timestamp, ttl_secs, url)
    if _M.power_watt(watts) == nil then
        return false, "rejected"
    end
    local stored, why = default_write_power_inner(id, watts, ttl_secs, url)
    if (not stored) and why == "rejected" then
        -- The number is usable, so registry's only remaining reason to refuse is
        -- the shared dict. It already logged the shdict error itself.
        return false, "store-failed"
    end
    return stored, why
end

---Store one **utilization** sample on the registry's independent gu: key.
---
---Structure is default_write_power()'s, and so is the reason for two return values:
---the caller must tell "there was no reading" (nothing written, the old sample TTLs
---out, the cap reads *unknown*) from "registry refused a number" (a lying exporter,
---worth a counter) and from "the store itself failed" (this gateway out of shared
---dict memory). Both are counted separately in runpass and exported as separate
---families, because an operator reading one number must not be sent looking at the
---wrong machine.
---
---Who screens what: the **authority** on what counts as a usable utilization reading
---is registry.set_gpu_util() (it refuses negatives/NaN/±inf/>1 and never writes a
---gu: key for them, so a refused sample leaves the key to expire back to nil =
---unknown = do not exclude). gpu_load's half of the bargain is collection and
---normalisation only: parse.collects, cards attributes, this seam stores. The
---pre-screen below exists for the same reason power's does -- it is what lets a false
---from registry be attributed to the dict rather than to the number.
---
---It deliberately does **not** reuse util_fraction(), and the reason is a bug class
---specific to this channel: util_fraction() carries the percent heuristic (anything
---above 1 is read as 0..100 and divided), so re-running it on an **already normalized**
---value would turn a corrupt 150 into a legitimate-looking 1.5 -> 0.015 and *hide* the
---very bug the pre-screen is here to catch. What arrives here is a fraction by contract
---(cards.assign_util hands out exactly what util_fraction produced), so the guard
---mirrors the registry's own predicate -- non-finite / negative / > 1 refused -- and
---the registry stays the authority that decides the stored (milli) shape.
---@param id string
---@param util number|nil @ normalized 0..1 utilization
---@param timestamp number @ ms clock (accepted for seam symmetry, unused here)
---@param ttl_secs number
---@param url string|nil @ only for the gauge label
---@return boolean stored, string reason
local function default_write_util_inner(id, util, ttl_secs, url)
    local registry = registry_mod()
    if not registry or type(registry.set_gpu_util) ~= "function" then
        return false, "no-registry"
    end
    local stored = registry.set_gpu_util(id, util, ttl_secs)
    if not stored then
        return false, "rejected"
    end
    if url then
        _M.publish_worker_util_gauge(url, util)
    end
    return true, "stored"
end

---Store one utilization sample, telling the two kinds of "not stored" apart.
---
---registry.set_gpu_util() answers false both when it refuses an unusable number and
---when the shared dict had no room. The first means the exporter is lying, the second
---means this gateway is out of memory, so the seam re-screens with util_fraction()
---and re-labels: a number that is still usable can only have been refused by the
---dict, which is counted as an error of *this* module rather than a rejection. (The
---"rejected" branch is rare by construction -- everything reaching here already went
---through util_fraction() on the way out of the parser.)
---@param id string
---@param util number|nil @ normalized 0..1 utilization
---@param timestamp number @ ms clock (accepted for seam symmetry, unused here)
---@param ttl_secs number
---@param url string|nil @ only for the gauge label
---@return boolean stored, string reason
local function default_write_util(id, util, timestamp, ttl_secs, url)
    local number = tonumber(util)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge
        or number < 0 or number > 1 then
        return false, "rejected"
    end
    local stored, why = default_write_util_inner(id, util, ttl_secs, url)
    if (not stored) and why == "rejected" then
        -- The number is usable, so registry's only remaining reason to refuse is
        -- the shared dict. It already logged the shdict error itself.
        return false, "store-failed"
    end
    return stored, why
end

-- One warn key per (class, target) so a Prometheus that is down does not spend the
-- error log; the window is the reason the key carries the class.
local warned_at = {}

---Warn once per WARN_DEDUP_SECS for one (class, target) pair.
---@param class string @ short failure family, e.g. "metrics" or "prom"
---@param target string @ worker url or prometheus url
---@param detail string|nil
---@param now number|nil @ ms clock (injected by the tests)
---@return boolean logged
function _M.warn_dedup(class, target, detail, now)
    local key = tostring(class) .. "|" .. tostring(target)
    local stamp = tonumber(now) or now_ms()
    local last = warned_at[key]
    if last and (stamp - last) < WARN_DEDUP_SECS * 1000 then
        return false
    end
    warned_at[key] = stamp
    local line = "gpu-load " .. class .. " " .. tostring(target)
        .. (detail and (": " .. tostring(detail)) or "")
    local ngxm = live_ngx()
    if ngxm and ngxm.log then
        ngxm.log(ngxm.WARN, "luarouter: ", line)
    end
    return true
end

---Clear the dedup window (tests, and an operator flipping SMG_LOAD_SOURCE).
function _M.reset_warn_dedup()
    warned_at = {}
end

local function worker_headers(record)
    if type(record) == "table" and type(record.api_key) == "string"
        and record.api_key ~= "" then
        return { Authorization = "Bearer " .. record.api_key }
    end
    return nil
end

-- Helpers the sibling submodules used as file-locals in the monolith
-- (invariant 4: direct calls stay direct calls).
M.live_ngx, M.now_ms = live_ngx, now_ms
M.hb_mod, M.registry_mod = hb_mod, registry_mod
M.default_workers, M.default_gpu_hints = default_workers, default_gpu_hints
M.default_get, M.default_post = default_get, default_post
M.default_write, M.default_write_power = default_write, default_write_power
M.default_write_util = default_write_util
M.worker_headers = worker_headers

return M
