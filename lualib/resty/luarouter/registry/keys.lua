-- registry.keys - the lr_workers key layout, the lazily resolved shared dict, the
-- registry lock, the worker id derivation, the ids roster and the mesh write hooks.
--
-- Cut verbatim out of registry.lua (refactor 2026-10-05,
-- doc/refactor-arch-2026-10-05.md section 1). The registry facade
-- (resty.luarouter.registry) re-exports every public name under its original spelling;
-- nothing outside the registry domain should require this module directly.
--
-- Key layout of lr_workers (conf/lua-router.conf:126) and its writer set, which is a
-- contract (AGENTS.md hard rule 3) and not an implementation detail:
--   ids                        registry/keys (write_ids; a failed set raises)
--   w: url: u: isel:           registry/records
--   hl: cbs: cbf: cbu: cbo:    registry/health      (hf:/hs: are written by hb.lua directly)
--   lo: act: xl: sl: pw: gu:   registry/loads       (xl:/pw:/gu: each has one
--   xany                                           production writer: gpu_load.lua)
--   job: disc: dpr: mp: mpok:  registry/discovery
-- Bypass writers that deliberately do not go through this module - do not "tidy" them:
--   hb.lua:201/215        incr/set hf: and hs: (cross-process-safe counting)
--   init.lua:184-200      reads and writes upstreams:applied_rev (APPLIED_REV_KEY here);
--                         registry only ever *deletes* that token, and
--                         _M.set_reconcile_guard decides when a write may skip the delete
--   router.lua:2712-2818  sop:<id> stream_options refusals - a router-domain key that
--                         merely lives in this dict
-- Lock discipline: with_lock is the single registry lock (resty.lock on lr_locks). The
-- whole-table writers (add/remove), the record merge writer (patch_record via update /
-- discover / expand_dp) and the breaker flips all take this one lock, and no submodule
-- is allowed a second one.

local M = {}

local lock_mod = require "resty.lock"

-- The self-calls that read _M.x() in the original file resolve against the
-- registry facade, late-bound below so this module loads before the facade does.
local R

local DICT_NAME = "lr_workers"
local LOCK_DICT = "lr_locks"
local IDS_KEY = "ids"

-- key prefixes
local K_WORKER = "w:"    -- static record (JSON)
local K_HEALTH = "hl:"   -- 1 healthy / 0 unhealthy
local K_HFAIL = "hf:"    -- consecutive health-check failures
local K_HSUCC = "hs:"    -- consecutive health-check successes
local K_CBSTATE = "cbs:" -- 0 closed, 1 half_open, 2 open
local K_CBF = "cbf:"     -- consecutive breaker failures
local K_CBS = "cbu:"     -- consecutive breaker successes
local K_CBO = "cbo:"     -- ms timestamp when the breaker opened
local K_LOAD = "lo:"     -- in-flight requests
local K_ACTIVE = "act:"  -- ms timestamp of the last completed request
local K_URL2ID = "url:"  -- url -> id
local K_IDURL  = "u:"    -- id -> url (cheap label lookup for metrics)
local K_JOB = "job:"     -- url -> JobStatus JSON
local K_DISC = "disc:"   -- id -> metadata discovery attempts
local K_DPROBE = "dpr:"  -- id -> /server_info probes spent on DP expansion
local K_MPROBE = "mp:"    -- id -> /v1/models coverage probes spent (failed ones)
local K_MPROBE_OK = "mpok:" -- id -> TTL stamp of the last successful coverage probe
-- Cached "this record may serve the HTTP inference plane" flag (see
-- _M.http_selectable). A derived value, recomputed whenever the static record is
-- written, so the selection path never has to decode the record to ask.
local K_HSEL = "isel:"

-- GPU 负载源（doc/gap-gpu-load.md）的两个外部采样通道，都是 **带 TTL 的数值键**：
-- 值为归一化负载的千分位整数（0..1000 = 0..1），所以过期（读取返回 nil）就等于
-- 「这个 tick 没有样本」，不需要额外的清理定时器，也不会把一台监控挂掉的机器永久
-- 钉在高负载上。两键分列是因为优先级明确（见 _M.load）：
--   xl: 外部负载源（gpu_load.lua 从 /metrics 或远程 Prometheus 抓来的 GPU 压力）
--   sl: 引擎自报负载（/v1/loads 那条通道）。本仓库的 /v1/loads 仍是按需拉取、
--       从不回写 registry（router.lua 的 loads_handler 只读上游），键位留给它，
--       是为了让「谁说了算」这件事在数据模型里就写清楚，而不是靠调用顺序。
local K_XLOAD = "xl:"  -- external GPU sample, milli of a 0..1 load, TTL'd
local K_SLOAD = "sl:"  -- engine self-report, same shape, lower priority
-- Raw measured power (doc/gap-worker-caps.md): the third external channel, and
-- deliberately *not* a load. `xl:` answers "how busy is this card" for the ranking
-- policies; `pw:` answers "how many watts is it drawing" for the per-worker power
-- cap, which is a hard admission gate and not a score. Folding watts into
-- _M.load() would let an idle-but-thirsty co-tenant's GPU make a worker look
-- overloaded to power_of_two, so the two numbers never share a field.
--   value = integer milli-watts (watts x 1000), TTL'd like the load samples: an
--   expired key means "no reading", and _M.capacity_exclusion reads that as
--   *unknown*, which never excludes a worker.
local K_POWER = "pw:"   -- raw power sample, milli-watts, TTL'd
-- Per-worker GPU **utilisation** ceiling (doc/caps-redesign-2026-10-06.md section 2): the
-- pure busy-fraction of the card this worker is pinned to, stored the same way as the
-- other external readings - integer milli of a 0..1 fraction (percent x 10), TTL'd, so an
-- expired key reads "no sample" = *unknown*, which never excludes a worker.
--
-- Why this needs its own key instead of a second reader on `xl:`: `xl:` is the ranking
-- channel, and _M.load_with folds it into the in-flight counter through load_scale - it is
-- kept and consumed in *units of in-flight requests*, which makes it a score, not an
-- admission number. The concurrency ceiling may only compare `lo:` (see
-- _M.inflight_requests), and a utilisation ceiling has to compare a utilisation, so it
-- needs a reading that never passed through load_scale. Reusing `xl:` would let an
-- operator moving a scoring knob (SMG_LOAD_SCALE) silently move an admission gate.
--
-- Why `pw:` is kept: what the 2026-10-06 ruling retires from capacity decisions is the
-- *watt* comparison, not the collection. The power channel stays a pure observation
-- (_M.power_samples and the lr_gpu_load_power_* family keep their readers); only
-- _M.capacity_exclusion stops reading it.
local K_GPU_UTIL = "gu:" -- pure GPU utilisation sample, milli of a 0..1 fraction, TTL'd
-- One shared "any sample exists anywhere" flag plus its per-process memo.
--
-- The writer is the load timer, which runs in worker 0 only; the readers are the
-- selection paths of every process, so a per-process boolean could never be set by
-- the process that needs it. The shared key (TTL'd like the samples it covers) is the
-- authority, and the memo is what keeps the shipped shape (SMG_LOAD_SOURCE=none, no
-- samples ever) at one shdict get per process per second instead of one per load()
-- call -- that call runs once per candidate on every request, and per-request shdict
-- traffic is already the dominant CPU cost (doc/parity-cpu-ablation.md).
local K_XANY = "xany"   -- shared "some worker has a fresh sample" flag, TTL'd
-- Numeric codes follow the Rust metric encoding (gateway/src/core/
-- circuit_breaker.rs STATE_CLOSED=0, STATE_OPEN=1, STATE_HALF_OPEN=2) so
-- smg_worker_cb_state means the same thing on both gateways. Lua-side ordering
-- assumptions must use the constants, never the numbers.
M.CB_CLOSED = 0
M.CB_OPEN = 1
M.CB_HALF_OPEN = 2

local CB_STATE_NAME = { "closed", "open", "half_open" }
M.CB_STATE_NAME = CB_STATE_NAME

-- ngx.shared.DICT is resolved lazily so the module also loads under `resty -t`.
local dict

local function shdict()
    if dict == nil then
        dict = ngx.shared[DICT_NAME]
    end
    return dict
end

-- ------------------------------------------------- upstream reconcile coupling
--
-- The worker-0 self-healing timer (init.lua) keys off the applied-revision
-- token in lr_workers (UPSTREAMS_REV_KEY there). e2e S3 showed the failure
-- mode: a manual DELETE /workers/<id> of a discovery=config member never
-- reached that token, so the pool drift stayed invisible and the member was
-- never re-added. Any *external* mutation of the pool therefore drops the
-- token here, and the next tick re-runs reconcile.
--
-- Anti-spin: config_store.reconcile_upstreams legitimately calls add/remove
-- while it applies the document; letting those clear the token would make
-- every pass schedule another one forever. The timer wraps its pass in
-- _M.set_reconcile_guard(true), so reconcile-originated add/remove skip the
-- clear (a per-Lua-process flag; the timer is worker 0 only, while
-- control-plane writes that reconcile run in request workers with the guard
-- off, so genuine drift stays visible). init.lua also runs one unconditional
-- sweep every few ticks to bound the narrow window where an external
-- mutation lands inside a guarded reconcile.
local APPLIED_REV_KEY = "upstreams:applied_rev"
local reconcile_guard = false

---Open/close the reconcile-origin filter for the applied-revision invalidation.
---@param on any @ truthy = suppress invalidation in this Lua process
function M.set_reconcile_guard(on)
    reconcile_guard = on and true or false
end

---Drop the applied-revision token so worker 0's timer sees pool drift.
---Tolerates every non-nginx shape (no ngx, no shdict, fake test dicts): pure
---unit environments must not raise from a pool write.
local function invalidate_applied_rev()
    if reconcile_guard then
        return
    end
    local ok, d = pcall(shdict)
    if ok and d then
        pcall(function() d:delete(APPLIED_REV_KEY) end)
    end
end

local function with_lock(fn)
    local lock, err = lock_mod:new(LOCK_DICT, { timeout = 5, exptime = 10 })
    if not lock then
        return nil, "lock init failed: " .. tostring(err)
    end
    local ok, err = lock:lock("registry")
    if not ok then
        return nil, "lock failed: " .. tostring(err)
    end
    local res, ferr = pcall(fn)
    lock:unlock()
    if not res then
        return nil, "registry operation failed: " .. tostring(ferr)
    end
    return true
end

-- ------------------------------------------------------------------ worker id

local digest_mod

--- sha224(url) hex, first 32 chars, rendered in 8-4-4-4-12 UUID form.
---@param url string
---@return string
function M.worker_id_for_url(url)
    if not digest_mod then
        digest_mod = require "resty.openssl.digest"
    end
    local d, err = digest_mod.new("sha224")
    if not d then
        error("sha224 unavailable: " .. tostring(err))
    end
    local ok, uerr = d:update(url)
    if not ok then
        error("sha224 update failed: " .. tostring(uerr))
    end
    local raw, ferr = d:final()
    if not raw then
        error("sha224 final failed: " .. tostring(ferr))
    end
    local hex = {}
    for i = 1, #raw do
        hex[#hex + 1] = string.format("%02x", string.byte(raw, i))
    end
    local h = table.concat(hex):sub(1, 32)
    return string.format("%s-%s-%s-%s-%s",
        h:sub(1, 8), h:sub(9, 12), h:sub(13, 16), h:sub(17, 20), h:sub(21, 32))
end

local UUID_RE = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

---@param raw string
---@return string|nil id, string|nil err
function M.parse_worker_id(raw)
    if type(raw) ~= "string" or raw == "" then
        return nil, "empty worker_id"
    end
    local candidate = string.lower(raw)
    if not ngx.re.match(candidate, UUID_RE, "jo") then
        return nil, string.format("Invalid worker_id '%s' (expected UUID)", raw)
    end
    return candidate
end

-- ------------------------------------------------------------------ url parse

local function read_ids(d)
    local raw = d:get(IDS_KEY)
    if not raw or raw == "" then
        return {}
    end
    local ids = {}
    for id in string.gmatch(raw, "[^,]+") do
        ids[#ids + 1] = id
    end
    return ids
end

local function write_ids(d, ids)
    if #ids == 0 then
        d:delete(IDS_KEY)
        return
    end
    local ok, err = d:set(IDS_KEY, table.concat(ids, ","))
    if not ok then
        error("failed to persist worker id index: " .. tostring(err))
    end
end

-- ------------------------------------------------------------------ CRUD

---Queue the registration of a worker (202 semantics live in router.lua).
---@param req table @ decoded POST /workers body
---@param cfg table @ router config providing the health-check defaults
---@return table|nil result @ {id, url, location, status}
---@return string|nil err
---@return string|nil kind @ "validation" for client-side rejections (400)
-- ------------------------------------------------------------------ mesh mirror
--
-- The cluster view (doc/gap-mesh.md 4.2) is a mirror of these records and has to
-- follow every write: the boot seed, a control-plane POST/PUT/DELETE, metadata
-- discovery and a health flip. router.lua used to be the only caller (from inside
-- its own /workers handlers), which left every other write path - above all
-- SMG_WORKER_URLS - invisible to peers, and left a mirrored worker frozen at the
-- record as it stood at registration time (health false, model unknown). Hooking
-- the registry's own write paths means a new one cannot forget it again.
--
-- mesh is required lazily and every step is guarded: the pure-Lua unit tests load
-- this module without ngx, and with the mesh off there is no instance to write to.
---@param id string
local function mesh_mirror(id)
    if not ngx or not ngx.shared then
        return false
    end
    local ok, mesh_mod = pcall(require, "resty.luarouter.mesh")
    if not ok or type(mesh_mod) ~= "table"
        or type(mesh_mod.instance) ~= "function" then
        return false
    end
    local inst = mesh_mod.instance()
    if not inst then
        return false
    end
    return inst:observe_worker(id, R.get(id), R.cb_state(id))
end

---Delete-side half: drop the key once the record is gone.
---@param id string
local function mesh_forget(id)
    if not ngx or not ngx.shared then
        return false
    end
    local ok, mesh_mod = pcall(require, "resty.luarouter.mesh")
    if not ok or type(mesh_mod) ~= "table"
        or type(mesh_mod.instance) ~= "function" then
        return false
    end
    local inst = mesh_mod.instance()
    if not inst or type(inst.remove_worker) ~= "function" then
        return false
    end
    return inst:remove_worker(id)
end

-- Late-bind the facade: registry.lua pre-registers package.loaded before it
-- requires this module, and a test that swaps the whole module table for a stub
-- through package.loaded is honoured by the same lookup.
R = package.loaded["resty.luarouter.registry"] or require "resty.luarouter.registry"


-- Published for the registry siblings and the facade.
M.K_ACTIVE = K_ACTIVE
M.K_CBF = K_CBF
M.K_CBO = K_CBO
M.K_CBS = K_CBS
M.K_CBSTATE = K_CBSTATE
M.K_DISC = K_DISC
M.K_DPROBE = K_DPROBE
M.K_GPU_UTIL = K_GPU_UTIL
M.K_HEALTH = K_HEALTH
M.K_HFAIL = K_HFAIL
M.K_HSEL = K_HSEL
M.K_HSUCC = K_HSUCC
M.K_IDURL = K_IDURL
M.K_JOB = K_JOB
M.K_LOAD = K_LOAD
M.K_MPROBE = K_MPROBE
M.K_MPROBE_OK = K_MPROBE_OK
M.K_POWER = K_POWER
M.K_SLOAD = K_SLOAD
M.K_URL2ID = K_URL2ID
M.K_WORKER = K_WORKER
M.K_XANY = K_XANY
M.K_XLOAD = K_XLOAD
M.invalidate_applied_rev = invalidate_applied_rev
M.mesh_forget = mesh_forget
M.mesh_mirror = mesh_mirror
M.read_ids = read_ids
M.shdict = shdict
M.with_lock = with_lock
M.write_ids = write_ids

return M
