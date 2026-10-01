-- Load balancing policies.
--
-- A policy instance is created once per worker process from the router config
-- and per model when a model override is registered. State that must be shared
-- across worker processes (round-robin cursor, manual routing map) lives in
-- lr_policy; purely local scratch stays in process memory.
--
-- Two families live behind one factory:
--   * the four stateless/shared-dict policies implemented here (random,
--     round_robin, power_of_two, manual), selected through policies[name]
--     with (inst, candidates) -> entry;
--   * the standalone policy modules under policies/ (cache_aware, bucket,
--     consistent_hashing, prefix_hash), which keep their Rust-shaped
--     interface new(cfg, rng) / select_worker(workers, info) / name() /
--     needs_request_text() and are wrapped here so the router still gets an
--     entry back instead of an index.
--
-- Selection receives an already-filtered candidate list (healthy and breaker
-- not open), matching the Rust router, which filters by is_available() before
-- calling the policy. `select` returns the chosen entry, not an index, so the
-- caller cannot misuse the index across retries.

local observability = require "resty.luarouter.observability"
local registry = require "resty.luarouter.registry"

-- Hot-config store (optional): the runtime routing-policy overrides. Required
-- through pcall so a build without the module, or a unit run that stubs the
-- world, keeps the plain hint -> cfg.policy chain.
local store_ok, store = pcall(require, "resty.luarouter.config_store")
if store_ok and type(store) ~= "table" then store_ok = false end

local json = require "cjson.safe"

local _M = { _VERSION = "0.1.0" }

local DICT = "lr_policy"

-- Standalone policy modules. Required through pcall so a missing or broken
-- file degrades to the default policy instead of failing the whole init phase.
local MODULE_SPECS = {
    cache_aware = "resty.luarouter.policies.cache_aware",
    bucket = "resty.luarouter.policies.bucket",
    consistent_hashing = "resty.luarouter.policies.consistent_hashing",
    prefix_hash = "resty.luarouter.policies.prefix_hash",
}
_M.MODULE_SPECS = MODULE_SPECS

-- Metrics family for the two hashing policies, per Rust Metrics::record_worker_*
local BRANCH_METRIC = {
    consistent_hashing = "smg_consistent_hashing_policy_branch_total",
    prefix_hash = "smg_prefix_hash_policy_branch_total",
}

-- Snapshot ceiling for one cache_aware tree dump written into lr_policy. Kept
-- well below the 20m dict so a big tree cannot evict the manual map.
local SNAPSHOT_MAX_BYTES = 3 * 1024 * 1024
local SNAPSHOT_KEY_PREFIX = "snapshot:"

local function dict()
    return ngx.shared[DICT]
end

local mt = { __index = _M }

---Every policy instance this process has built, keyed by name_instance()
---("<policy>:<model>"). The eviction sweep walks it so a per-model policy gets the
---same LRU maintenance as the default one, and _M.for_model uses it as its cache.
---Entries stay for the life of the process (they carry affinity state) and the
---model cardinality is bounded by the worker set.
_M.instances = {}

-- ------------------------------------------------------------------ helpers

local function random_index(n)
    if n <= 1 then
        return 1
    end
    return math.random(1, n)
end

--- Lowest-load entry, ties broken at random (manual's min_load mode).
local function select_min(candidates, get_value)
    local best, candidates_min = nil, nil
    for i = 1, #candidates do
        local value = get_value(candidates[i])
        if best == nil or value < best then
            best = value
            candidates_min = { candidates[i] }
        elseif value == best then
            candidates_min[#candidates_min + 1] = candidates[i]
        end
    end
    if not candidates_min or #candidates_min == 1 then
        return candidates_min and candidates_min[1]
    end
    return candidates_min[random_index(#candidates_min)]
end

-- ------------------------------------------------------------------ policies

local policies = {}

---Uniform random over the candidates. Stateless.
function policies.random(inst, candidates)
    return candidates[random_index(#candidates)]
end

---Round robin with a shared cursor so N worker processes stay balanced.
function policies.round_robin(inst, candidates)
    local key = "rr:" .. inst.name .. ":" .. (inst.model or "default")
    local counter = dict():incr(key, 1, 0) or 0
    return candidates[(counter % #candidates) + 1]
end

---Pick two candidates at random, send to the less loaded one.
---The Rust version reads a cached token-load map refreshed every few seconds;
---here the live in-flight counter from the registry plays that role.
function policies.power_of_two(inst, candidates)
    if #candidates <= 2 then
        return select_min(candidates, function(worker)
            return registry.load(worker.id)
        end)
    end
    local first = random_index(#candidates)
    local second = (first - 1 + random_index(#candidates - 1)) % #candidates + 1
    local load_first = registry.load(candidates[first].id)
    local load_second = registry.load(candidates[second].id)
    if load_first <= load_second then
        return candidates[first]
    end
    return candidates[second]
end

---Sticky routing by X-SMG-Routing-Key. Up to two candidate URLs per key so a
---failover can switch without reassigning every other session.
local MAX_CANDIDATES = 2

---Shared-dict key for one routing key.
---
---The Rust PolicyRegistry owns one ManualPolicy per model
---(policies/registry.rs:66 on_worker_added -> determine_policy_for_model), so two
---models never share a sticky map. Here the instance carries the model
---(inst.model), and the dict is global across models, so the key has to name the
---model or a session pinned while talking to model A would be honoured on model B.
---The "manual:" prefix is kept at the front because publish_gauges counts that
---prefix and mesh mirrors it.
local function manual_key(inst, routing_key)
    return "manual:" .. (inst.model or "default") .. "|" .. routing_key
end

---min_group assignment counter, likewise per model.
local function group_key(inst, url)
    return "group:" .. (inst.model or "default") .. "|" .. url
end

function policies.manual(inst, candidates)
    local routing_key = inst.routing_key
    local branch
    if not routing_key or routing_key == "" then
        branch = "no_routing_id"
        observability.counter("smg_manual_policy_branch_total",
            { { "branch", branch } })
        return candidates[random_index(#candidates)]
    end

    local d = dict()
    local stored = d:get(manual_key(inst, routing_key))
    local urls
    if stored then
        urls = json.decode(stored)
        if type(urls) ~= "table" then
            urls = nil
        end
    end

    local by_url = {}
    for i = 1, #candidates do
        by_url[candidates[i].url] = candidates[i]
    end

    if urls and #urls > 0 then
        for i = 1, #urls do
            local worker = by_url[urls[i]]
            if worker then
                branch = "occupied_hit"
                -- refresh recency and keep the same candidate order
                local encoded = json.encode(urls)
                if encoded then
                    d:set(manual_key(inst, routing_key), encoded, inst.max_idle_secs)
                end
                observability.counter("smg_manual_policy_branch_total",
                    { { "branch", branch } })
                return worker
            end
        end
        -- Every recorded candidate is gone: reassign and keep the tail so a
        -- returning worker can take over again later.
        branch = "occupied_miss"
    else
        branch = "vacant"
    end

    local chosen
    if inst.assignment_mode == "min_load" then
        chosen = select_min(candidates, function(worker)
            return registry.load(worker.id)
        end)
    elseif inst.assignment_mode == "min_group" then
        chosen = select_min(candidates, function(worker)
            return d:get(group_key(inst, worker.url)) or 0
        end)
    else
        chosen = candidates[random_index(#candidates)]
    end

    -- Rust records the choice with Node::push_bounded, which appends and only
    -- drops from the head once at capacity, so the list stays oldest-first.
    -- occupied_hit walks it in order, which is what lets a key fall back to its
    -- original worker after a failover instead of pinning to the new one.
    local updated = {}
    if branch == "occupied_miss" then
        for i = 1, #urls do
            updated[#updated + 1] = urls[i]
        end
        while #updated >= MAX_CANDIDATES do
            table.remove(updated, 1)
        end
    end
    updated[#updated + 1] = chosen.url
    local encoded = json.encode(updated)
    if encoded then
        d:set(manual_key(inst, routing_key), encoded, inst.max_idle_secs)
    end
    d:incr(group_key(inst, chosen.url), 1, 0)
    observability.counter("smg_manual_policy_branch_total",
        { { "branch", branch } })
    return chosen
end

-- ------------------------------------------------------------ standalone policies

---Rust-shaped policy modules are wrapped so select() returns a candidate entry
---instead of a 1-based index, and so their per-policy knobs come from cfg.
---@param name string
---@param cfg table
---@return table|nil impl @ configured module instance, nil when require failed
local function build_module(name, cfg)
    local spec = MODULE_SPECS[name]
    if not spec then
        return nil
    end
    local ok, mod = pcall(require, spec)
    if not ok or type(mod) ~= "table" or type(mod.new) ~= "function" then
        ngx.log(ngx.ERR, "luarouter: policy module ", spec, " unavailable: ",
            tostring(mod))
        return nil
    end

    local policy_cfg = {}
    if name == "cache_aware" then
        policy_cfg = {
            cache_threshold = cfg.cache_threshold,
            balance_abs_threshold = cfg.balance_abs_threshold,
            balance_rel_threshold = cfg.balance_rel_threshold,
            eviction_interval_secs = cfg.eviction_interval_secs,
            max_tree_size = cfg.max_tree_size,
        }
    elseif name == "bucket" then
        policy_cfg = {
            balance_abs_threshold = cfg.balance_abs_threshold,
            balance_rel_threshold = cfg.balance_rel_threshold,
            bucket_adjust_interval_secs = cfg.bucket_adjust_interval_secs,
        }
    elseif name == "prefix_hash" then
        policy_cfg = {
            prefix_token_count = cfg.prefix_token_count,
            load_factor = cfg.prefix_hash_load_factor,
        }
    end

    local impl = mod.new(policy_cfg)
    impl._policy_name = name
    return impl
end

---Build the SelectWorkerInfo the standalone modules expect (Rust
---SelectWorkerInfo{request_text, tokens, headers, hash_ring}; tokens and the
---ring stay nil - HTTP has no tokens and the modules build their own rings).
local function info_for(inst)
    return {
        request_text = inst.request_text,
        headers = inst.headers,
    }
end

---Index-returning select_worker adapted to the entry-returning framework. When
---the module exposes the branch-reporting variant (the two hashing policies do),
---it is used so the Rust branch counter is fed from the same decision rather than
---by running the lookup twice.
local function standalone_select(inst, candidates)
    local impl = inst.impl
    local index, branch
    if type(impl.select_worker_impl) == "function" then
        index, branch = impl:select_worker_impl(candidates, info_for(inst))
    else
        index = impl:select_worker(candidates, info_for(inst))
    end

    local metric = BRANCH_METRIC[inst.name]
    if metric and branch then
        observability.counter(metric, { { "branch", branch } })
    end

    if type(index) ~= "number" or index < 1 or index > #candidates then
        return nil
    end
    return candidates[index]
end

_M.standalone_select = standalone_select

_M.policies = policies

-- ------------------------------------------------------------------ instance

---Create a policy instance.
---@param cfg table @ router config
---@param opts table|nil @ {model=string, name=string}
---@return table inst
function _M.new(cfg, opts)
    opts = opts or {}
    -- opts.name arrives already resolved by for_model / policy_for; only the
    -- no-name path consults the chain so a caller cannot be second-guessed.
    local requested = opts.name
    if requested == nil or requested == "" then
        local cfg_policy = cfg.policy or "round_robin"
        if store_ok and type(store.resolve_policy) == "function"
            and (type(store.policy_override_active) ~= "function"
                or store.policy_override_active()) then
            local named = store.resolve_policy(cfg_policy, opts.model, nil)
            if named then cfg_policy = named end
        end
        requested = cfg_policy
    end
    local name = requested
    if not policies[name] then
        -- Fall back to the default policy when neither a built-in nor a
        -- standalone module answers to the name.
        name = "round_robin"
    end

    local inst = setmetatable({
        name = name,
        model = opts.model,
        cfg = cfg,
        max_idle_secs = cfg.max_idle_secs or 14400,
        eviction_interval_secs = cfg.eviction_interval_secs or 120,
        assignment_mode = cfg.assignment_mode or "random",
        seeded = false,
        restored = false,
        generation = -1,
    }, mt)

    -- Not a built-in: try the standalone modules before giving up on the name.
    if not policies[requested] then
        local impl = build_module(requested, cfg)
        if impl then
            inst.name = requested
            inst.impl = impl
        end
    end
    _M.instances[inst:name_instance()] = inst
    return inst
end

---Instance for one model, built on demand and cached.
---
---Rust keys its PolicyRegistry by model: the first worker of a model fixes the
---policy from labels.policy (update_policies.rs:102 -> policies/registry.rs:172),
---a model without a hint gets the default, and the model's entry is dropped with
---its last worker (registry.rs:111). Same rules here. `hint` and `has_workers`
---come from the registry's worker records, so a process that never saw the
---registration still routes by the advertised hint after a restart.
---@param cfg table @ router config
---@param model string|nil @ resolved model id (nil/"" falls back to the default)
---@param hint string|nil @ labels.policy of the model's first worker
---@param has_workers boolean|nil @ false drops the model's instance
---@return table inst
function _M.for_model(cfg, model, hint, has_workers)
    local key = model
    if type(key) ~= "string" or key == "" then
        key = "default"
    end
    if key ~= "default" and has_workers == false then
        -- Last worker gone: forget the model's policy so a re-registration under a
        -- different hint is not shadowed by the instance built for the old one.
        local stale = {}
        for name, inst in pairs(_M.instances) do
            if inst.model == key then
                stale[#stale + 1] = name
            end
        end
        for i = 1, #stale do
            _M.instances[stale[i]] = nil
        end
        key = "default"
        hint = nil
    end

    -- With no operator override configured this is the pre-feature expression
    -- verbatim (unknown hints kept as the cache key included). Once an override
    -- exists the full chain decides the name, so a policy change yields a
    -- different instance (fresh affinity tree, exactly like a restart) and an
    -- unchanged policy keeps hitting the instance built on the first request.
    local name
    if store_ok and type(store.policy_override_active) == "function"
        and store.policy_override_active()
        and type(store.resolve_policy) == "function" then
        local resolved = store.resolve_policy(cfg.policy or "round_robin", key, hint)
        name = resolved or "round_robin"
    else
        name = (hint ~= nil and hint ~= "") and hint
            or (cfg.policy or "round_robin")
    end
    local cached = _M.instances[name .. ":" .. key]
    if cached then
        return cached
    end

    local inst = _M.new(cfg, { model = key, name = name })
    inst.generation = _M.generation()
    if ngx and ngx.shared then
        inst:restore_snapshot()
    end
    return inst
end

---Chain-resolve the policy name one call should use.
---
---With the config store present this is config_store.resolve_policy
---(model_policies[model] > global policy > labels hint > SMG_POLICY); without it
---the function keeps the historical hint -> cfg.policy chain, so a stripped-down
---build behaves exactly as before the feature.
---@param cfg table @ router config
---@param model string|nil @ resolved model id (nil/""/default = global path)
---@param hint string|nil @ labels.policy advertised by the model's first worker
---@return string name, string layer
local function chain_name(cfg, model, hint)
    if store_ok and type(store.resolve_policy) == "function" then
        local name, layer = store.resolve_policy((cfg and cfg.policy) or "round_robin",
            model, hint)
        if name then return name, layer end
    end
    if type(hint) == "string" and hint ~= "" then
        return hint, "hint"
    end
    return (cfg and cfg.policy) or "round_robin", "env"
end

_M.chain_name = chain_name

---Point an existing instance at another policy in place.
---
---The instance table identity matters: router.policy_for caches the global
---instance in a file-local, and _M.instances caches per-model instances, so a
---runtime policy change has to mutate the table every holder already references
---rather than build a new one. Rebuilds the factory decisions for the new name
---(built-in handler vs standalone module, unknown collapses to round_robin),
---re-keys the instance registry, and re-seeds on the next select; the tree
---snapshot for the new policy (same name+model key as an earlier run used) is
---read back so flipping cache_aware -> random -> cache_aware restores affinity.
---@param inst table
---@param name string
---@return string name @ the policy the instance now runs
local function reconfigure(inst, name)
    if inst:policy_name() == name then
        return name
    end
    local cfg = inst.cfg or {}
    local old_key = inst:name_instance()
    local resolved = policies[name] and name or nil
    local impl
    if not resolved then
        impl = build_module(name, cfg)
        if impl then
            resolved = name
        else
            resolved = "round_robin"
        end
    end
    _M.instances[old_key] = nil
    inst.name = resolved
    inst.impl = impl
    inst.seeded = false
    inst.restored = false
    inst.generation = -1
    inst._next_adjust = nil
    _M.instances[inst:name_instance()] = inst
    if ngx and ngx.shared then
        inst:restore_snapshot()
    end
    ngx.log(ngx.INFO, "luarouter: policy ", old_key, " switched in place to ", resolved)
    return resolved
end

---Stamp the global instance with the policy the current request should use.
---
---router.policy_for returns its file-local default instance for every model
---without a worker hint, so a per-model override for such a model has to land on
---that shared table. Both consumers of the instance (policy_name/
---needs_request_text at route time, select at forward time) call into policy.lua
---first, and the whole request-pre → select window runs in one coroutine with no
---yield between the stamp and the decision, so stamping per request keeps each
---request's identity coherent even while the worker interleaves other requests.
---When no override is configured at all this collapses to a single memoised
---table lookup and the instance is never touched — the zero-behaviour-change
---requirement for deployments that do not use the routing page.
---@param inst table @ the instance router.policy_for is about to hand out
---@return table inst
local stamping_active = false

---@param inst table
---@param model string|nil @ explicit model (select passes ctx.model); falls back to ngx.ctx
local function stamp_global(inst, model)
    if not store_ok or type(store.policy_override_active) ~= "function" then
        return inst
    end
    -- Once an operator has configured an override in this process's lifetime,
    -- keep resolving on every request: after the last override is cleared the
    -- instance has to walk back to the hint / SMG_POLICY chain, and an early
    -- return here would leave it on the policy it was last stamped with.
    if not stamping_active and not store.policy_override_active() then
        return inst
    end
    stamping_active = true
    if type(model) ~= "string" or model == "" or model == "unknown" then
        model = ngx and ngx.ctx and ngx.ctx.lr_model
        if model == "unknown" then model = nil end
    end
    -- Routing must survive a broken override read: on any error keep the
    -- instance on the policy it already runs rather than 500 every request.
    local ok, name = pcall(chain_name, inst.cfg or {}, model, nil)
    if ok and name then
        pcall(reconfigure, inst, name)
    elseif not ok then
        ngx.log(ngx.WARN, "luarouter: policy chain resolve failed: ", tostring(name))
    end
    return inst
end

_M.stamp_global = stamp_global

---Name reported to metrics and the request log (Rust Policy::name()).
function _M:policy_name()
    if self.impl then
        return self.impl._policy_name or self.name
    end
    return self.name
end

---Shared-dict key holding this instance's tree snapshot. The key carries the
---worker id because the tree itself is per-process: two processes must not
---overwrite each other's dump, and each restores its own on a reload.
function _M:snapshot_key()
    local id = ngx.worker and ngx.worker.id and ngx.worker.id()
    return SNAPSHOT_KEY_PREFIX .. self:name_instance() .. ":" .. tostring(id or 0)
end

function _M:name_instance()
    return self:policy_name() .. ":" .. (self.model or "default")
end

---Layer the persisted tree snapshot into this process. Safe at init_worker time:
---the dump is self-contained, so it does not need the worker list yet.
---@return boolean restored
function _M:restore_snapshot()
    local impl = self.impl
    if not impl or self.restored or type(impl.decode_snapshot) ~= "function" then
        return false
    end
    self.restored = true
    local snap = dict():get(self:snapshot_key())
    if not snap then
        return false
    end
    local ok, restored = pcall(impl.decode_snapshot, impl, snap)
    if not ok or not restored then
        ngx.log(ngx.WARN, "luarouter: ", self:name_instance(),
            " snapshot unreadable; cold-starting from the worker list")
        return false
    end
    return true
end

---Give every current worker its "" anchor (Rust init_workers). Runs once per
---process on the first select rather than in init_worker: worker 0 seeds the
---registry from inside its own init_worker, so the other processes would race an
---empty table there. Restoring the snapshot first and seeding after it also covers
---workers registered after that dump was written.
---@return table|nil impl
function _M:prepare()
    local impl = self.impl
    if not impl or self.seeded then
        return impl
    end
    self.seeded = true

    local records = registry.records()
    if type(impl.init_workers) == "function" then
        impl:init_workers(records)
    elseif type(impl.init_worker_urls) == "function" then
        impl:init_worker_urls(records)
    end
    return impl
end

---Write the tree snapshot back into lr_policy. Skipped when the dump is larger
---than the budget (encode_snapshot returns nil) so a full dict cannot be pushed
---out by an oversized tree; the next sweep after eviction may fit.
---@return boolean written
function _M:save_snapshot()
    local impl = self.impl
    if not impl or type(impl.encode_snapshot) ~= "function" then
        return false
    end
    local max_bytes = self.cfg.snapshot_max_bytes or SNAPSHOT_MAX_BYTES
    local text = impl:encode_snapshot(max_bytes)
    if not text then
        return false
    end
    local ok, err = dict():set(self:snapshot_key(), text)
    if not ok then
        ngx.log(ngx.WARN, "luarouter: ", self:name_instance(),
            " snapshot write failed: ", tostring(err))
        return false
    end
    return true
end

---Select a worker.
---@param ctx table @ {candidates, routing_key, request_text, model}
---@return table|nil worker
function _M:select(ctx)
    -- Decision point: router calls policy_for(model):select(...) in one
    -- expression, so the instance that decides is stamped from the same model
    -- the request will be logged against.
    if self == _M.default and store_ok then
        stamp_global(self, ctx.model)
    end
    local candidates = ctx.candidates
    if not candidates or #candidates == 0 then
        observability.counter("smg_manual_policy_branch_total",
            { { "branch", "no_healthy_workers" } })
        return nil
    end
    self.routing_key = ctx.routing_key
    self.request_text = ctx.request_text
    self.headers = ctx.headers

    local worker
    if self.impl then
        self:restore_snapshot()
        self:refresh_generation()
        self:prepare()
        worker = standalone_select(self, candidates)
    else
        local handler = policies[self.name] or policies.round_robin
        worker = handler(self, candidates)
    end

    if worker then
        observability.record_worker_selection(worker.url, ctx.model, self:policy_name())
    end
    return worker
end

---Whether the policy needs the request text (Rust needs_request_text): the router
---can skip the body walk for policies that answer false.
function _M:needs_request_text()
    if self.impl and type(self.impl.needs_request_text) == "function" then
        return self.impl:needs_request_text() and true or false
    end
    -- The built-ins key off the candidate list and the routing-key header only.
    return false
end

---Notify the policy that a worker joined. Stateless policies ignore this.
---@param worker_record table
function _M:on_add(worker_record)
    local impl = self.impl
    if not impl then
        return nil
    end
    if type(impl.add_worker) == "function" then
        impl:add_worker(worker_record)
    end
    return nil
end

---Drop the load bookkeeping for a removed worker.
---
---The manual sticky map is deliberately NOT scrubbed: the Rust ManualPolicy is
---never notified when a worker leaves (remove_from_policy_registry only reaches
---cache_aware, and on_worker_removed just forgets a model with no workers left),
---so a key keeps its departed candidate and returns to it once the worker is
---re-registered. Rewriting the entries here would erase that failback and pin
---every session to its failover target; occupied_hit resolves a departed URL by
---simply missing in the candidate list, which is what drives occupied_miss.
---Entries still age out through max_idle_secs, exactly like Rust's eviction task.
---@param worker_record table
function _M:on_remove(worker_record)
    if self.impl then
        local impl = self.impl
        if worker_record.url and type(impl.remove_worker_by_url) == "function" then
            impl:remove_worker_by_url(worker_record.url)
        elseif type(impl.remove_worker) == "function" then
            impl:remove_worker(worker_record)
        end
        if type(impl.invalidate_rings) == "function" then
            impl:invalidate_rings()
        end
        return
    end
    if self.name ~= "manual" or not worker_record.url then
        return
    end
    -- One shared-dict sweep per known model: the counter keys are per model (see
    -- group_key), and the set of models is small and changes only with the worker
    -- set, so probing the live instance plus the default bucket is enough.
    local d = dict()
    d:delete("group:" .. (self.model or "default") .. "|" .. worker_record.url)
    if (self.model or "default") ~= "default" then
        d:delete("group:default|" .. worker_record.url)
    end
end

---Expose the manual policy cache size, mirroring the Rust gauge. Method form:
---the sweep calls inst:publish_gauges().
function _M:publish_gauges()
    -- cache_aware publishes its tenant footprint so the Logs page can show how
    -- much affinity state each process is carrying (Rust has no such gauge).
    if self.impl and self.impl._policy_name == "cache_aware" then
        local trees = self.impl.trees or {}
        local tenants = 0
        for _, tree in pairs(trees) do
            local counts = tree:get_tenant_char_count()
            for _ in pairs(counts) do
                tenants = tenants + 1
            end
        end
        observability.gauge("smg_cache_aware_tenant_count", {}, tenants)
    end
    if self.name ~= "manual" then
        return
    end
    local d = dict()
    local count = 0
    local keys = d:get_keys(0)
    for i = 1, #keys do
        if keys[i]:sub(1, 7) == "manual:" then
            count = count + 1
        end
    end
    observability.gauge("smg_manual_policy_cache_entries", {}, count)
end

-- ------------------------------------------------------------------ eviction

local eviction_started = false

---Per-tick work for the standalone policies. cache_aware runs the LRU sweep the
---Rust eviction thread owns and then writes the tree snapshot back (evict first:
---the dump only fits once the tree shrinks). bucket recomputes its boundaries on
---its own, faster interval.
local function sweep_standalone(inst)
    local impl = inst.impl
    if not impl then
        return
    end
    if type(impl.evict_all) == "function" then
        local ok, err = pcall(impl.evict_all, impl)
        if not ok then
            ngx.log(ngx.ERR, "luarouter: ", inst:name_instance(),
                " evict_all failed: ", tostring(err))
        end
    end
    if inst._next_adjust == nil then
        inst._next_adjust = ngx.now()
    end
    local now = ngx.now()
    if now >= inst._next_adjust then
        if type(impl.adjust_all) == "function" then
            local ok, err = pcall(impl.adjust_all, impl)
            if not ok then
                ngx.log(ngx.ERR, "luarouter: ", inst:name_instance(),
                    " adjust_all failed: ", tostring(err))
            end
        end
        inst._next_adjust = now + math.max(1,
            inst.cfg.bucket_adjust_interval_secs or 5)
    end
    inst:save_snapshot()
end

local function sweep_max_idle(self_premature)
    if self_premature then
        return
    end
    -- Every instance, not just the default: a per-model hint creates a second
    -- policy (policy_for), and its cache_aware tree is per-process Lua memory that
    -- nothing else would evict. _M.instances is the registry of them.
    local default_inst = _M.default
    -- pairs() yields keys, so the instance has to be the second variable: read as
    -- `for inst in pairs(...)` it walks the *names*, and indexing a string returns
    -- nil, which silently skips both the standalone sweep and the gauges.
    for _, inst in pairs(_M.instances or {}) do
        if inst.impl then
            sweep_standalone(inst)
            inst:publish_gauges()
        end
        if inst.name == "manual" then
            -- Touch every manual key so ngx.shared TTL expiry is the eviction
            -- mechanism; the loop publishes the cache-size gauge and logs how many
            -- entries survive, which is what the Rust PeriodicTask reports.
            inst:publish_gauges()
        end
    end
    local inst = default_inst
    local again, err = ngx.timer.at(inst and inst.eviction_interval_secs or 120,
        sweep_max_idle)
    if not again then
        eviction_started = false
        ngx.log(ngx.ERR, "luarouter: eviction timer stopped: ", tostring(err))
    end
end

---Topology generation, kept in lr_policy so a control-plane write in one process
---reaches the others: a stateful policy seeded from a stale worker list would
---otherwise never learn a new worker (bucket in particular builds its boundaries
---from the list it was seeded with).
local GEN_KEY = "policy:generation"

function _M.generation()
    local value = dict():get(GEN_KEY)
    return tonumber(value) or 0
end

---Call after the worker set changes. The instance itself survives (its trees are
---the whole point) and re-seeds on the next select.
function _M.bump_generation()
    local value, err = dict():incr(GEN_KEY, 1, 0)
    if not value then
        ngx.log(ngx.WARN, "luarouter: policy generation bump failed: ",
            tostring(err))
    end
end

---Re-seed the instance when another process changed the worker set. Restoring a
---snapshot again is deliberately not part of this: it would rewind the affinity
---learned since the last write.
function _M:refresh_generation()
    local current = _M.generation()
    if self.generation == current then
        return false
    end
    self.generation = current
    self.seeded = false
    return true
end

---Start the policy eviction timer once per worker process. Called from
---init_worker (every worker) and, defensively, from router.policy_for.
---@return boolean|nil started, string|nil err
function _M.start_eviction()
    -- router.policy_for calls this on every request *before* it returns the
    -- cached global instance, so it is the one hook every path goes through:
    -- this is where a runtime policy change reaches the shared instance.
    if _M.default then
        stamp_global(_M.default)
    end
    if eviction_started then
        return true
    end
    local inst = _M.default
    if not inst then
        -- Nothing to schedule yet: the instance is built by init_worker or the
        -- first select. Report rather than silently dropping the timer.
        return false, "no policy instance"
    end
    eviction_started = true
    local ok, err = ngx.timer.at(inst.eviction_interval_secs or 120, sweep_max_idle)
    if not ok then
        eviction_started = false
        ngx.log(ngx.ERR, "luarouter: failed to start eviction timer: ",
            tostring(err))
        return false, err
    end
    return true
end

return _M
