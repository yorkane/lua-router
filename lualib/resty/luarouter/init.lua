-- Module bootstrap: parse the environment once and own the process lifecycle.
--
-- init_by_lua calls .init() (config only, before any ngx.* per-worker state is
-- available); init_worker_by_lua calls .worker_init() (seed workers, start the
-- health sweep, the policy eviction timer and - when SMG_MESH_PEERS names a
-- cluster - the mesh sync timer in worker 0 only).

local config_mod = require "resty.luarouter.config"

local _M = { _VERSION = "0.1.0" }

local config
local seeded = false

-- Mesh knobs captured in the master process. nginx rebuilds the worker environment,
-- so anything not declared with an `env` directive is gone after the fork and the
-- mesh module could not read it from init_worker; capturing here (and handing the
-- values to mesh.init explicitly) is what keeps the SMG_MESH_* names working without
-- changing the conf contract. SMG_ENABLE_MESH gates the whole feature and defaults
-- to false, so a box that never opted in keeps the pre-mesh /ha/* 503 contract even
-- if an operator left SMG_MESH_PEERS lying around in the environment.
local mesh_configured = false
local mesh_state = { enabled = false, captured = false }


---@return table @ router config (nil before init)
function _M.config()
    if not config then
        -- `resty` one-liners and unit probes have no init phase, so fall back to
        -- parsing the environment here instead of failing.
        config = config_mod.validate(config_mod.load())
    end
    return config
end

---Capture the in-flight age-tracker knobs and start its sampler timer.
---
---The two LR_INFLIGHT_* names are read here, before the fork, and handed to
---observability.configure_inflight() explicitly (the same reason SMG_MESH_* and
---SMG_MESH_* are snapshotted). Defaults match the Rust tracker: sample every
---20 s (server.rs:1559 start_sampler(20)), slot TTL 3600 s. The names are also
---declared with `env` in the three confs so a request-phase os.getenv sees them.
---LR_INFLIGHT_SAMPLE_SECS=0 switches the tracker off entirely (no timer, no slot
---claims, and the age family stays out of the scrape).
local function wire_inflight_tracker()
    local ok_obs, observability = pcall(require, "resty.luarouter.observability")
    if not ok_obs or type(observability.configure_inflight) ~= "function" then
        return false
    end
    local getenv = os.getenv
    observability.configure_inflight({
        sample_s = tonumber(getenv("LR_INFLIGHT_SAMPLE_SECS")),
        ttl_s = tonumber(getenv("LR_INFLIGHT_TTL_SECS")),
    })
    return true
end

---Sampler timer: one tick per LR_INFLIGHT_SAMPLE_SECS in worker 0 only.
---
---The slot table is shared, so a per-worker sampler would record the same ages
---once per process and inflate _count by the worker count. Rust has the same
---shape for the opposite reason (one process, one DashMap, one PeriodicTask).
local function start_inflight_sampler()
    local ok_obs, observability = pcall(require, "resty.luarouter.observability")
    if not ok_obs then
        return false
    end
    if not observability.inflight_enabled() then
        -- LR_INFLIGHT_SAMPLE_SECS=0: no timer, and the family stays out of the
        -- scrape rather than being published as invented zeros.
        return false
    end
    local interval = observability.inflight_sample_s()
    local function tick(premature)
        if premature then
            return
        end
        local ok, err = pcall(observability.sample_inflight_ages)
        if not ok then
            ngx.log(ngx.WARN, "luarouter: in-flight age sample failed: ", tostring(err))
        end
        local again, aerr = ngx.timer.at(interval, tick)
        if not again then
            ngx.log(ngx.ERR, "luarouter: in-flight age sampler stopped: ",
                tostring(aerr))
        end
    end
    local ok, err = ngx.timer.at(interval, tick)
    if not ok then
        ngx.log(ngx.ERR, "luarouter: in-flight age sampler not started: ",
            tostring(err))
        return false
    end
    return true
end

-- ------------------------------------------------------- upstreams reconcile
--
-- doc/gap-virtual-models.md 3.1 trigger points. config_store owns the sync
-- half (apply-time reconcile inside the write handlers); this is the two
-- async halves in worker 0 only: a bootstrap pass shortly after seeding, and
-- a 30 s self-healing timer that compares the config revision against the
-- applied token kept in lr_workers. Everything is pcall-guarded: while the
-- store has no reconcile_upstreams (mid-rollout / stripped build), both halves
-- are no-ops and a failure here can never reach the request plane.

local RECONCILE_INTERVAL_SECS = 30
-- Belt-and-suspenders full pass (see registry.lua invalidate_applied_rev): the
-- reconcile guard is a per-process flag, so an external pool mutation landing
-- inside a guarded window could go unseen; one unconditional sweep every
-- RECONCILE_INTERVAL_SECS * this ticks (~5 min) bounds that gap.
local RECONCILE_SWEEP_TICKS = 10
local sweep_ticks = 0
-- Applied-revision token inside the registry's dict: shdict state survives a
-- reload, so only a genuine change (or a full restart, which empties the dict)
-- re-runs the pass. Env visibility note: no new os.getenv names are read here
-- on purpose -- the conf `env` lists are owned by another agent (root ruled
-- the interval constant lives in code, keyed off store.policy_revision).
local UPSTREAMS_REV_KEY = "upstreams:applied_rev"

local function store_module()
    local ok, mod = pcall(require, "resty.luarouter.config_store")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

---Run one idempotent reconcile when the store offers it. Returns whether the
---pass ran (the caller only records the token after a real pass).
---@param store_mod table|nil
---@return boolean ran
local function reconcile_once(store_mod)
    if not store_mod or type(store_mod.reconcile_upstreams) ~= "function" then
        return false
    end
    -- Guard the registry for the duration of this pass: reconcile's own
    -- add/remove must not clear the applied-revision token (that would make
    -- every pass re-trigger the next one). The guard is per Lua process, so
    -- external mutations observed by other request workers stay visible; the
    -- periodic sweep in the tick bounds the narrow same-process window.
    local ok_reg, registry = pcall(require, "resty.luarouter.registry")
    local guarded = ok_reg and type(registry) == "table"
        and type(registry.set_reconcile_guard) == "function"
    if guarded then
        pcall(registry.set_reconcile_guard, true)
    end
    local ok, err = pcall(store_mod.reconcile_upstreams)
    if guarded then
        pcall(registry.set_reconcile_guard, false)
    end
    if not ok then
        ngx.log(ngx.WARN, "luarouter: upstreams reconcile failed: ", tostring(err))
        return false
    end
    return true
end

---The config document revision token. policy_revision is the token config_store
---already bumps on every write (including upstreams/virtual-model applies); a
---document-scoped accessor is preferred when one exists.
---@param store_mod table|nil
---@return string|nil
local function config_revision(store_mod)
    if not store_mod then
        return nil
    end
    if type(store_mod.document_revision) == "function" then
        local ok, value = pcall(store_mod.document_revision)
        if ok and value ~= nil then
            return tostring(value)
        end
    end
    if type(store_mod.policy_revision) == "function" then
        local ok, value = pcall(store_mod.policy_revision)
        if ok and value ~= nil then
            return tostring(value)
        end
    end
    return nil
end

local function applied_revision()
    local d = ngx.shared and ngx.shared.lr_workers
    if not d then
        return nil
    end
    local value = d:get(UPSTREAMS_REV_KEY)
    if value == nil then
        return nil
    end
    return tostring(value)
end

local function record_applied_revision(token)
    local d = ngx.shared and ngx.shared.lr_workers
    if d and token ~= nil then
        d:set(UPSTREAMS_REV_KEY, token)
    end
end

---Bootstrap pass: shortly after worker 0 seeded the registry, pull the declared
---upstreams into the pool (covers a container restart, where both lr_workers
---and the applied token start empty). Deferred by 0.5 s so it lands after the
---SMG_WORKER_URLS bootstrap and cannot race its shared-dict writes.
---@return boolean started
local function start_upstreams_bootstrap()
    local store_mod = store_module()
    if not store_mod or type(store_mod.reconcile_upstreams) ~= "function" then
        return false
    end
    local function tick(premature)
        if premature then
            return
        end
        if reconcile_once(store_mod) then
            record_applied_revision(config_revision(store_module()))
        end
    end
    local ok, err = ngx.timer.at(0.5, tick)
    if not ok then
        ngx.log(ngx.WARN, "luarouter: upstreams bootstrap timer not started: ",
            tostring(err))
        return false
    end
    return true
end

---Self-healing loop: every 30 s, reconcile when the document moved past the
---applied token. The comparison is per-pass state in the shared dict, so a
---worker restart, a hand DELETE against a config member, or a write that
---landed while this process was down all converge on the next tick. env seed
---file (LMR_UPSTREAMS_FILE) pickup is internal to reconcile_upstreams, so no
---separate env_upstreams call is needed beyond this pass.
---@return boolean started
local function start_upstreams_timer()
    local store_mod = store_module()
    if not store_mod or type(store_mod.reconcile_upstreams) ~= "function" then
        return false
    end
    local function tick(premature)
        if premature then
            return
        end
        local current = store_module()
        local token = config_revision(current)
        local applied = applied_revision()
        sweep_ticks = sweep_ticks + 1
        local force = sweep_ticks >= RECONCILE_SWEEP_TICKS
        if force then
            sweep_ticks = 0
        end
        if token ~= nil and (token ~= applied or force) then
            if reconcile_once(current) then
                -- Record last, from a fresh read: the document may have moved
                -- while the pass ran, and storing the pre-read token would
                -- reopen the same gap until the following tick.
                local fresh = config_revision(current) or token
                record_applied_revision(fresh)
                ngx.log(ngx.NOTICE, "luarouter: upstreams reconciled at revision ", fresh)
            end
        end
        local again, err = ngx.timer.at(RECONCILE_INTERVAL_SECS, tick)
        if not again then
            ngx.log(ngx.WARN, "luarouter: upstreams reconcile timer stopped: ",
                tostring(err))
        end
    end
    local ok, err = ngx.timer.at(RECONCILE_INTERVAL_SECS, tick)
    if not ok then
        ngx.log(ngx.WARN, "luarouter: upstreams reconcile timer not started: ",
            tostring(err))
        return false
    end
    return true
end

---Parse and validate the environment. Safe to call from init_by_lua.
---
--- Also snapshots the LMR_* names for the config store: nginx rebuilds the
--- worker environment from scratch, so anything it does not declare with an
--- `env` directive - including the inherited LMR_* and even HOME - is gone by
--- the time a request handler calls os.getenv. init_by_lua is the last place
--- that still sees the real environment, and it runs once before the fork, so
--- the cache is inherited by every worker.
---@return table
function _M.init()
    local store_ok, store = pcall(require, "resty.luarouter.config_store")
    if store_ok and type(store.capture_env) == "function" then
        local ok, err = pcall(store.capture_env)
        if not ok then
            ngx.log(ngx.ERR, "luarouter: config_store.capture_env failed: ",
                tostring(err))
        end
    end
    config = config_mod.load()
    config = config_mod.validate(config)

    -- In-flight request ages (doc/gap-inflight-age.md): same reason as tracing -
    -- the numbers are read once here and the module keeps them.
    wire_inflight_tracker()

    -- Cluster mesh: build the process-visible instance from the captured values.
    -- Every worker needs the object (the /ha/* handlers read its tables), but only
    -- worker 0 starts the sync timer, and that happens in worker_init.
    local getenv = os.getenv
    local flag = string.lower(getenv("SMG_ENABLE_MESH") or "")
    mesh_state.enabled = (flag == "1" or flag == "true" or flag == "yes"
        or flag == "on")
    if mesh_state.enabled then
        mesh_state.captured = true
        mesh_state.peers = getenv("SMG_MESH_PEERS")
        mesh_state.self_addr = getenv("SMG_MESH_SELF")
            or getenv("SMG_MESH_SELF_ADDR")
        mesh_state.self_name = getenv("SMG_MESH_SELF_NAME")
        mesh_state.interval_s = tonumber(getenv("SMG_MESH_SYNC_INTERVAL_SECS"))
        mesh_state.unreachable_s =
            tonumber(getenv("SMG_MESH_UNREACHABLE_TIMEOUT_SECS"))
        mesh_state.suspect_threshold = tonumber(getenv("SMG_MESH_SUSPECT_THRESHOLD"))
        mesh_state.quorum = tonumber(getenv("SMG_MESH_QUORUM"))
        mesh_state.min_cluster_size = tonumber(getenv("SMG_MESH_MIN_CLUSTER_SIZE"))
        mesh_state.rate_window_s = tonumber(getenv("SMG_MESH_RATE_WINDOW_SECS"))
        mesh_state.rpc_timeout_ms = tonumber(getenv("SMG_MESH_RPC_TIMEOUT_MS"))
        mesh_state.snapshot_max_bytes =
            tonumber(getenv("SMG_MESH_SNAPSHOT_MAX_BYTES"))
        local ok_mesh, mesh = pcall(require, "resty.luarouter.mesh")
        if ok_mesh then
            local opts = {}
            if mesh_state.peers and mesh_state.peers ~= "" then
                opts.peers_text = mesh_state.peers
            end
            if mesh_state.self_addr then opts.self_addr = mesh_state.self_addr end
            if mesh_state.self_name then opts.self_name = mesh_state.self_name end
            for _, key in ipairs({ "interval_s", "unreachable_s",
                "suspect_threshold", "quorum", "min_cluster_size", "rate_window_s",
                "rpc_timeout_ms", "snapshot_max_bytes" }) do
                if mesh_state[key] then opts[key] = mesh_state[key] end
            end
            local ok, inst_or_nil, err = pcall(mesh.init, nil, opts)
            if not ok then
                ngx.log(ngx.ERR, "luarouter: mesh init failed: ",
                    tostring(inst_or_nil))
            elseif inst_or_nil == nil then
                ngx.log(ngx.WARN, "luarouter: SMG_ENABLE_MESH is set but no peers ",
                    "were configured (", tostring(err), "); /ha/* stays 503")
            end
        end
    end
    return config
end

---Push this process's policy and cache_aware tree into the cluster view
---(doc/gap-mesh.md 4.2). The registry side is mirrored from the /workers handlers;
---these two only change on a reload or an eviction sweep, so a timer is enough and
---no hook inside policy.lua is needed. manual:<key> is deliberately not mirrored:
---it can hold thousands of entries and Rust does not replicate it either.
---@param inst table
---@param policy table
local function mirror_mesh_state(inst, policy)
    local inst_policy = policy.default
    if not inst_policy then
        return 0
    end
    local written = 0
    if inst:observe_policy(inst_policy.model or "default",
        inst_policy:policy_name(), { policy = inst_policy.name }) then
        written = written + 1
    end
    local snapshot_key = inst_policy:snapshot_key()
    local dump = ngx.shared.lr_policy and ngx.shared.lr_policy:get(snapshot_key)
    if type(dump) == "string" and inst:observe_tree(inst_policy.model or "default",
        dump) then
        written = written + 1
    end
    return written
end

---Re-mirror on the eviction cadence: that is when the tree snapshot is rewritten.
---@param inst table
---@param policy table
---@return boolean ok
local function start_mesh_mirror(inst, policy)
    local interval = (config and config.eviction_interval_secs) or 120
    local function tick(premature)
        if premature then
            return
        end
        local ok, err = pcall(mirror_mesh_state, inst, policy)
        if not ok then
            ngx.log(ngx.WARN, "luarouter: mesh state mirror failed: ",
                tostring(err))
        end
        local again, aerr = ngx.timer.at(interval, tick)
        if not again then
            ngx.log(ngx.ERR, "luarouter: mesh mirror timer stopped: ",
                tostring(aerr))
        end
    end
    local ok, err = ngx.timer.at(interval, tick)
    if not ok then
        ngx.log(ngx.ERR, "luarouter: mesh mirror timer not started: ",
            tostring(err))
        return false
    end
    return true
end

---Per-worker startup. Registration is shared through lr_workers, so only worker
---0 seeds the bootstrap list and runs the timers; the others just inherit state.
---@return boolean ok
function _M.worker_init()
    -- Seed after the fork: init_by_lua runs once for the whole process table, so
    -- seeding there would hand every worker the same random sequence and the
    -- random / power_of_two policies would pick in lockstep.
    math.randomseed(ngx.now() * 1000 + ngx.worker.pid())
    local conf = _M.config()
    local registry = require "resty.luarouter.registry"
    local hb = require "resty.luarouter.hb"
    local policy = require "resty.luarouter.policy"

    -- Every worker needs the shared policy instance: the eviction sweep walks
    -- per-process state (cache-aware trees live in Lua memory, not in
    -- lr_policy), so a worker that never runs it would keep stale tenants
    -- forever. Creating it here also means the timer has an instance to read
    -- instead of waiting for the first request to lazily build one.
    if not policy.default then
        policy.default = policy.new(conf)
        policy.default.generation = policy.generation()
    end
    -- Read the tree dump back before the first request: the snapshot lives in
    -- lr_policy, which survives a reload, so affinity does not start cold. The
    -- worker anchors are seeded lazily on the first select (worker 0 is still
    -- seeding the registry at this point).
    policy.default:restore_snapshot()
    local ok_timer, err_timer = policy.start_eviction()
    if ok_timer == false then
        ngx.log(ngx.ERR, "luarouter: policy eviction timer not started: ",
            tostring(err_timer))
    end
    -- The age sampler reads the shared slot table, so exactly one process runs it.
    if ngx.worker.id() == 0 then
        start_inflight_sampler()
    end

    -- Mesh runs in every process because /ha/* reads the tables of the worker
    -- that answered; only worker 0 syncs, so the others report local writes plus
    -- whatever the last reload kept. worker_processes is pinned to 1 by the
    -- entrypoint when SMG_ENABLE_MESH is on (doc/gap-mesh.md §4.4, route 1), which
    -- makes that distinction academic in a deployed container.
    if mesh_state.enabled and not mesh_configured then
        local ok_mesh, mesh = pcall(require, "resty.luarouter.mesh")
        if ok_mesh then
            local inst = mesh.instance()
            -- No sync credential: the gateway auth surface was removed
            -- (doc/scope-trim.md), so peers are reached (and reached) open.
            if inst then
                mirror_mesh_state(inst, policy)
                if ngx.worker.id() == 0 then
                    local ok_start, err_start = inst:start()
                    if ok_start == false then
                        ngx.log(ngx.ERR, "luarouter: mesh sync timer not started: ",
                            tostring(err_start))
                    end
                    start_mesh_mirror(inst, policy)
                end
            end
            mesh_configured = true
        end
    end

    -- Registration and the health sweep are shared-dict writers: one process
    -- doing them is enough, and it keeps duplicate job_state races away.
    if ngx.worker.id() ~= 0 then
        return true
    end

    if not seeded then
        seeded = true
        if #conf.worker_urls > 0 then
            local count = registry.bootstrap(conf)
            ngx.log(ngx.NOTICE, "luarouter: seeded ", count,
                " workers from SMG_WORKER_URLS")
        end
    end

    hb.start()
    -- The Kubernetes pod poller was removed (doc/scope-trim.md): workers arrive
    -- through SMG_WORKER_URLS, POST /workers, or the in-process watcher below,
    -- and the health sweep above is the only other registry writer.
    --
    -- The watcher is the merged form of the standalone llm-watcher daemon
    -- (doc/gap-watcher-merge.md): same worker-0-only shape as hb.start(), same
    -- captured-at-init config hand-off as the mesh, and its own lr_watch single
    -- flight inside the module. SMG_WATCHER_ENABLED defaults to off, so a box
    -- that never opted in runs exactly the pre-merge code path.
    local ok_watcher, watcher = pcall(require, "resty.luarouter.watcher")
    if ok_watcher and type(watcher) == "table" then
        local started, why = watcher.start(conf.watcher)
        if started == false and why ~= "disabled (set SMG_WATCHER_ENABLED=1)" then
            ngx.log(ngx.WARN, "luarouter: watcher not started: ", tostring(why))
        end
    end
    -- Config-declared upstreams (doc/gap-virtual-models.md 3.1): async safety
    -- net behind the synchronous apply-time reconcile in config_store. Both
    -- halves are guarded no-ops when the store lacks the feature.
    start_upstreams_bootstrap()
    start_upstreams_timer()
    return true
end

---Release load guards that a request reserved but never handed back. Every
---forward path balances its own counter, so anything left here means the handler
---aborted between reserving and releasing (a Lua error, or the client going away
---while an attempt was in flight). log_by_lua still runs in those cases.
function _M.on_log()
    -- Same leak story for the concurrency token: a client that disappears
    -- mid-stream stops the handler before finish_request, and log_by_lua is the
    -- only phase that still runs. release() is idempotent, so the normal path
    -- (finish_request already handed the slot back) is unaffected.
    local ok_limit, limit = pcall(require, "resty.luarouter.limit")
    if ok_limit and limit then
        limit.release()
    end
    -- Same leak story for the in-flight age slot: a client that disappears
    -- mid-stream stops the handler before finish_request hands the slot back, and
    -- log_by_lua is the only phase that still runs. untrack() is idempotent per
    -- request and will not free a slot another request has since claimed.
    local ok_obs, observability = pcall(require, "resty.luarouter.observability")
    if ok_obs and observability then
        pcall(observability.inflight_untrack)
    end
    local held = ngx.ctx.lr_held
    if not held or #held == 0 then
        return
    end
    local ok, registry = pcall(require, "resty.luarouter.registry")
    if not ok then
        return
    end
    for i = 1, #held do
        registry.change_load(held[i], -1)
        ngx.log(ngx.WARN, "luarouter: released leaked load guard on worker ", held[i])
    end
    ngx.ctx.lr_held = {}
end

return _M
