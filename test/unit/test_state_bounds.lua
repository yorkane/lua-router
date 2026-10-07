#!/usr/bin/env luajit
-- 进程内累积状态的回收与预算单测（doc/gap-cpu-idle-burn.md，分支 fix/cpu-idle-burn）。
--   运行：docker run --rm -e LUA_TEST_LIB=/repo/lualib -v "$PWD:/repo:ro" \
--          --entrypoint /usr/local/openresty/luajit/bin/luajit authz:latest \
--          /repo/test/unit/test_state_bounds.lua
--
-- 这里钉的是 8801/8802 空载烧核的**内存线**三件事，全部是「以前只会涨、现在必须能降」
-- 的形状，而且每一条都配了「关掉这条闸门就复现旧行为」的反证断言：
--   * S2 _M.instances：select 打时间戳、reclaim 回收「名字没人认领 + 空闲过 TTL」的实例，
--     并且 registry 读不出来时一个都不许删（宁可留旧实例，也不能清空亲和）；
--   * S1 快照预算：cache_aware:encode_snapshot 超预算返回 nil，且不先把整棵树 encode
--     一遍（那是 8801 每 120s 一次的分配尖峰）；
--   * 可观测性：tree nodes/chars/count 与 evict_all 的增量预算语义。
--
-- 与 test_routing_dyn.lua 同形状：observability / registry 用替身，policy.lua 走真模块。
package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath
package.path = (os.getenv("LUA_TEST_LIB") or "./lualib") .. "/?.lua;" .. package.path

--------------------------------------------------------------------------
-- 替身：ngx（policy.lua 只在函数体里碰它）、observability、registry
--------------------------------------------------------------------------
local function new_shdict()
    local store = {}
    return {
        get = function(_, k) return store[k] end,
        set = function(_, k, v) store[k] = tostring(v); return true end,
        incr = function(_, k, delta, init)
            local cur = tonumber(store[k]) or init or 0
            cur = cur + delta
            store[k] = tostring(cur)
            return cur
        end,
        delete = function(_, k) store[k] = nil end,
        get_keys = function(_, n)
            local out = {}
            for k in pairs(store) do out[#out + 1] = k end
            table.sort(out)
            if n and n > 0 and #out > n then
                for i = n + 1, #out do out[i] = nil end
            end
            return out
        end,
        _dump = store,
    }
end

local shared = { lr_policy = new_shdict(), lr_stats = new_shdict() }
_G.ngx = {
    shared = shared,
    now = function() return os.time() end,
    log = function() end,
    timer = { at = function() return true end },
    worker = { id = function() return 0 end },
    WARN = 1, ERR = 2, INFO = 3, NOTICE = 4,
    ctx = {},
}

local gauges = {}
package.loaded["resty.luarouter.observability"] = {
    counter = function() end,
    gauge = function(name, _, value) gauges[name] = value end,
    record_worker_selection = function() end,
}

local live_models = {}
package.loaded["resty.luarouter.registry"] = {
    load = function() return 0 end,
    change_load = function() return 0 end,
    records = function() return {} end,
    all_models = function()
        local out = {}
        for i = 1, #live_models do out[i] = live_models[i] end
        return out
    end,
    policy_hint_for_model = function() return nil, 0 end,
}

local policy_mod = require "resty.luarouter.policy"
local cache_aware = require "resty.luarouter.policies.cache_aware"
local tree_mod = require "resty.luarouter.policies.tree"

--------------------------------------------------------------------------
-- 断言小框架
--------------------------------------------------------------------------
local passed, failed = 0, 0
local failures = {}
local function check(cond, name, detail)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = name .. (detail and (" -> " .. tostring(detail)) or "")
    end
end
local function eq(actual, expect, name)
    check(actual == expect, name,
        (actual ~= expect) and (tostring(actual) .. " ~= " .. tostring(expect)) or nil)
end
local function new_case(name) io.write("  case: " .. name .. "\n") end

local base_cfg = {
    policy = "round_robin",
    eviction_interval_secs = 120, max_idle_secs = 14400, assignment_mode = "random",
    cache_threshold = 0.3, balance_abs_threshold = 64, balance_rel_threshold = 1.5,
    max_tree_size = 67108864, max_tree_nodes = 200000, evict_budget = 0,
    prefix_token_count = 256, prefix_hash_load_factor = 1.25,
    bucket_adjust_interval_secs = 5, snapshot_max_bytes = 3 * 1024 * 1024,
    policy_instance_ttl_secs = 1800,
}
local function cfg_with(overrides)
    local cfg = {}
    for k, v in pairs(base_cfg) do cfg[k] = v end
    for k, v in pairs(overrides or {}) do cfg[k] = v end
    return cfg
end

local candidates = {
    { url = "http://w1:1", id = "w1", load = 0, healthy = true, model_id = "m1" },
    { url = "http://w2:1", id = "w2", load = 0, healthy = true, model_id = "m1" },
}

---实例登记数（gauge 与断言都用它，避免两处口径分家）
local function registered()
    local n = 0
    for _ in pairs(policy_mod.instances) do n = n + 1 end
    return n
end

--------------------------------------------------------------------------
new_case("select 给实例打空闲时间戳（回收判据的来源）")
do
    policy_mod.instances = {}
    local cfg = cfg_with({ policy = "cache_aware" })
    local inst = policy_mod.new(cfg, { model = "ghost", name = "cache_aware" })
    eq(inst.last_used, nil, "fresh instance has no stamp yet")
    inst:select({ candidates = candidates, model = "ghost",
                  request_text = "hello affinity" })
    check(type(inst.last_used) == "number", "select stamps last_used",
        tostring(inst.last_used))
    eq(inst.select_count, 1, "select counted")
    -- 时间戳必须是**当前**时钟，不是 0：否则刚建出来就在 TTL 上表现为"很久没用"
    check(math.abs(inst.last_used - os.time()) <= 2, "stamp is now, not epoch",
        tostring(inst.last_used))
end

--------------------------------------------------------------------------
new_case("reclaim：只删「名字没人认领 + 空闲过 TTL」的实例")
do
    policy_mod.instances = {}
    local cfg = cfg_with({ policy = "cache_aware" })
    local def = policy_mod.new(cfg)
    policy_mod.default = def
    def:select({ candidates = candidates, model = "m1" })

    live_models = { "kept" }
    local kept = policy_mod.for_model(cfg, "kept", "cache_aware", true)
    local ghost = policy_mod.for_model(cfg, "ghost", "cache_aware", true)
    check(kept ~= nil and ghost ~= nil, "both instances built")
    -- 两个实例都推到 TTL（1800 s）之外：留下的理由只能是「名字还活着」，
    -- 被收的理由只能是「名字没人认领」。
    kept.last_used = os.time() - 3600
    ghost.last_used = os.time() - 3600
    eq(policy_mod.reclaim_instances(), 1, "exactly the unclaimed instance goes")
    eq(policy_mod.instances[kept:name_instance()], kept, "live name survives")
    eq(policy_mod.instances[ghost:name_instance()], nil, "dead name reclaimed")
    eq(policy_mod.instances[def:name_instance()], def, "global default survives")
end

--------------------------------------------------------------------------
new_case("reclaim：空闲未过 TTL 的实例不回收（哪怕名字已经没人认领）")
do
    policy_mod.instances = {}
    local cfg = cfg_with({ policy = "cache_aware", policy_instance_ttl_secs = 3600 })
    policy_mod.default = policy_mod.new(cfg)
    live_models = {}
    local inst = policy_mod.for_model(cfg, "warm", "cache_aware", true)
    inst.last_used = os.time() - 60
    eq(policy_mod.reclaim_instances(), 0, "inside the TTL nothing goes")
    eq(policy_mod.instances[inst:name_instance()], inst, "still registered")
    inst.last_used = os.time() - 7200
    eq(policy_mod.reclaim_instances(), 1, "past the TTL it goes")
end

--------------------------------------------------------------------------
new_case("reclaim：名字最近还在被 select 的实例绝不回收")
do
    policy_mod.instances = {}
    local cfg = cfg_with({ policy = "cache_aware" })
    policy_mod.default = policy_mod.new(cfg)
    live_models = {}
    local inst = policy_mod.for_model(cfg, "busy", "cache_aware", true)
    inst:select({ candidates = candidates, model = "busy", request_text = "abc" })
    eq(policy_mod.reclaim_instances(), 0, "recently used instance is kept")
    eq(policy_mod.instances[inst:name_instance()], inst, "still registered")
end

--------------------------------------------------------------------------
new_case("reclaim：registry 读不出来时一个都不许删")
do
    policy_mod.instances = {}
    local cfg = cfg_with({ policy = "cache_aware" })
    policy_mod.default = policy_mod.new(cfg)
    live_models = {}
    for i = 1, 5 do
        local inst = policy_mod.for_model(cfg, "stale" .. i, "cache_aware", true)
        inst.last_used = os.time() - 99999
    end
    eq(policy_mod.reclaim_instances(), 5, "sanity: all five are reclaimable")

    -- 现在让 registry 抛错：没有可信的名字来源就必须保守（一个都不删）。
    policy_mod.instances = {}
    policy_mod.default = policy_mod.new(cfg)
    for i = 1, 5 do
        local inst = policy_mod.for_model(cfg, "keep" .. i, "cache_aware", true)
        inst.last_used = os.time() - 99999
    end
    local saved = package.loaded["resty.luarouter.registry"].all_models
    package.loaded["resty.luarouter.registry"].all_models = function()
        error("registry unavailable")
    end
    eq(policy_mod.reclaim_instances(), 0, "unreadable registry => nothing dropped")
    eq(registered(), 6, "all instances still there")
    package.loaded["resty.luarouter.registry"].all_models = saved
end

--------------------------------------------------------------------------
new_case("reclaim：policy_instance_ttl_secs<=0 是关掉回收的显式档位")
do
    policy_mod.instances = {}
    local cfg = cfg_with({ policy = "cache_aware", policy_instance_ttl_secs = 0 })
    policy_mod.default = policy_mod.new(cfg)
    live_models = {}
    for i = 1, 3 do
        local inst = policy_mod.for_model(cfg, "off" .. i, "cache_aware", true)
        inst.last_used = os.time() - 99999
    end
    eq(policy_mod.reclaim_instances(), 0, "ttl 0 disables reclamation")
    eq(registered(), 4, "nothing went")
end

--------------------------------------------------------------------------
new_case("candidates.lua 的 forced 路径创建的实例进同一回收")
do
    -- forced 路径（router/candidates.lua:56-66）不经 for_model，直接 policy_mod.new。
    -- 它落进同一个 _M.instances（policy.lua 的注册行），所以 sweep 顺带管它 —— 这条
    -- 就是 S2 里"绕过回收"的那一支现在不再绕过的证明。
    policy_mod.instances = {}
    local cfg = cfg_with({ policy = "round_robin" })
    policy_mod.default = policy_mod.new(cfg)
    live_models = {}
    local inst = policy_mod.new(cfg, { model = "forced-entry", name = "cache_aware" })
    eq(inst.impl ~= nil, true, "forced cache_aware instance built")
    eq(registered(), 2, "forced instance is registered")
    eq(policy_mod.reclaim_instances(), 1, "forced instance is reclaimed")
    eq(registered(), 1, "only the global default is left")
end

--------------------------------------------------------------------------
new_case("publish_affinity_gauges 跨实例求和后发出亲和树体量")
do
    policy_mod.instances = {}
    local cfg = cfg_with({ policy = "cache_aware" })
    policy_mod.default = policy_mod.new(cfg)
    -- 两个实例各带一份树。这组 gauge 没有 label，所以值必须是**求和**：
    -- 曾经逐实例各发一次，pairs() 的遍历顺序决定谁覆盖谁，线上正好会读到
    -- 空实例的 0 —— 而这组 gauge 存在的意义就是让人看出树又长大了。
    local inst = policy_mod.default
    local other = policy_mod.new(cfg, { model = "m2", name = "cache_aware" })
    -- 树要先有租户才会被写：这正是 prepare()/init_workers 在线上做的事（这里
    -- registry.records 是替身，所以显式喂一次，走的是同一个 add_worker 路径）。
    inst.impl:init_workers({
        { url = "http://w1:1", id = "w1", load = 0, healthy = true,
          model_id = "m1", pool = "regular" },
        { url = "http://w2:1", id = "w2", load = 0, healthy = true,
          model_id = "m1", pool = "regular" },
    })
    for i = 1, 20 do
        inst:select({ candidates = candidates, model = "m1",
                      request_text = "prefix-" .. i .. "-" .. ("t"):rep(40) })
        other:select({ candidates = candidates, model = "m2",
                       request_text = "other-" .. i .. "-" .. ("t"):rep(40) })
    end
    gauges = {}
    policy_mod.publish_affinity_gauges()
    check(type(gauges.smg_cache_aware_tree_nodes) == "number",
        "tree nodes published", tostring(gauges.smg_cache_aware_tree_nodes))
    check(gauges.smg_cache_aware_tree_nodes > 0, "nodes are non-zero after selects",
        tostring(gauges.smg_cache_aware_tree_nodes))
    check(gauges.smg_cache_aware_tree_chars > 0, "chars published",
        tostring(gauges.smg_cache_aware_tree_chars))
    check(type(gauges.smg_cache_aware_tree_count) == "number",
        "tree count published")
    check(type(gauges.smg_cache_aware_tenant_count) == "number",
        "the pre-existing tenant gauge stays")
    -- 回归点：值必须是「全部实例」之和，而不是最后一个被遍历到的那个实例
    -- tree_stats 返回 (trees, nodes, chars)
    local t_all, n_all = inst.impl:tree_stats()
    local t_one, n_one = other.impl:tree_stats()
    eq(gauges.smg_cache_aware_tree_count, t_all + t_one, "tree count is summed over instances")
    eq(gauges.smg_cache_aware_tree_nodes, n_all + n_one, "node count is summed, not overwritten")
end

--------------------------------------------------------------------------
new_case("publish_gauges 只管 manual 那族，不再逐实例覆盖亲和 gauge")
do
    policy_mod.instances = {}
    local cfg = cfg_with({ policy = "cache_aware" })
    policy_mod.default = policy_mod.new(cfg)
    local inst = policy_mod.new(cfg, { model = "m1", name = "cache_aware" })
    gauges = {}
    inst:publish_gauges()
    check(gauges.smg_cache_aware_tree_nodes == nil,
        "per-instance call must not touch the shared affinity gauges",
        tostring(gauges.smg_cache_aware_tree_nodes))
end

--------------------------------------------------------------------------
new_case("sweep 发 smg_policy_instances，且回收后的数量才是它读的数")
do
    policy_mod.instances = {}
    local cfg = cfg_with({ policy = "cache_aware" })
    policy_mod.default = policy_mod.new(cfg)
    live_models = {}
    for i = 1, 4 do
        local inst = policy_mod.for_model(cfg, "cnt" .. i, "cache_aware", true)
        inst.last_used = os.time() - 99999
    end
    gauges = {}
    policy_mod.sweep_tick_report()
    eq(gauges.smg_policy_instances, 1, "gauge reports the survivors, not the historical peak")
end

--------------------------------------------------------------------------
new_case("evict_all 接住节点维度与增量预算，并回报还有活")
do
    local impl = cache_aware.new({ max_tree_size = 100000, max_tree_nodes = 30,
                                   evict_budget = 4 })
    for i = 1, 80 do
        local tree = impl:get_or_create_tree("regular::m" .. (i % 2))
        tree:insert("ea-" .. i .. "-" .. ("x"):rep(30), "http://w" .. (1 + (i % 3)))
    end
    local t1, n1 = impl:tree_stats()
    check(t1 == 2 and n1 > 30, "over the node budget before", tostring(n1))
    local more = impl:evict_all(100000, 30, 4)
    eq(more, true, "one budgeted tick reports more work")
    local _, n2 = impl:tree_stats()
    check(n2 < n1, "node dimension really evicted", n1 .. " -> " .. n2)
    local guard = 0
    while guard < 400 do
        guard = guard + 1
        if not impl:evict_all(100000, 30, 4) then break end
    end
    local _, n3 = impl:tree_stats()
    -- 限额是**每棵树**的（两棵树各自不超过 30 节点 + 骨架余量）
    check(n3 <= 64, "converged near the per-tree node cap", tostring(n3))
    check(guard < 400, "converged without exhausting the loop", tostring(guard))
    -- 没超标的一拍必须真的什么都不做（这是 over_limit 那条 O(1) 前置判定的意义）
    eq(impl:evict_all(100000, 30, 4), false, "an in-limit tick reports no work")
end

--------------------------------------------------------------------------
new_case("encode_snapshot 超预算返回 nil，且不留静默")
do
    local impl = cache_aware.new({ max_tree_size = 100000, max_tree_nodes = 200000 })
    local tree = impl:get_or_create_tree("regular::m1")
    for i = 1, 200 do
        tree:insert("snap-" .. i .. "-" .. ("p"):rep(300), "http://w1")
    end
    eq(impl:encode_snapshot(2048), nil, "oversized tree is refused")
    eq(impl.snapshot_oversized, true, "the refusal is recorded for the WARN")
    local small = cache_aware.new({ max_tree_size = 100000 })
    local st = small:get_or_create_tree("regular::m1")
    st:insert("tiny prompt", "http://w1")
    local text = small:encode_snapshot(1024 * 1024)
    check(type(text) == "string" and #text > 0, "small tree still round-trips",
        tostring(text))
    eq(small.snapshot_oversized, false, "flag cleared on success")
    local back = cache_aware.new({ max_tree_size = 100000 })
    eq(back:decode_snapshot(text), true, "the snapshot decodes")
    eq((back:select_worker({ { url = "http://w1", healthy = true, load = 0,
        model_id = "m1", pool = "regular" } }, { request_text = "tiny prompt" })),
        1, "affinity survived the round trip")
end

--------------------------------------------------------------------------
new_case("tree_stats 的读数与树的增量计数一致")
do
    local impl = cache_aware.new({ max_tree_size = 100000 })
    local t = impl:get_or_create_tree("regular::a")
    t:insert("aaaa-bbbb", "http://w1")
    t:insert("aaaa-cccc", "http://w2")
    local trees, nodes, chars = impl:tree_stats()
    eq(trees, 1, "one tree")
    eq(nodes, t.live_nodes, "nodes agree with the tree")
    eq(chars, t.live_chars, "chars agree with the tree")
    impl:get_or_create_tree("regular::b")
    eq((impl:tree_stats()), 2, "tree count follows get_or_create_tree")
end

--------------------------------------------------------------------------
new_case("EMPTY_TENANT 不再堵死 detach（骨架能缩 = 节点数能降）")
do
    local t = tree_mod.new()
    for i = 1, 40 do
        t:prefix_match_with_counts("cold-" .. i .. "-" .. ("z"):rep(20))
    end
    t:insert("live-prefix-1", "http://w1")
    t:insert("live-prefix-2", "http://w2")
    t:remove_tenant("http://w1")
    t:remove_tenant("http://w2")
    local stack = { t.root }
    local stamped = 0
    while #stack > 0 do
        local curr = table.remove(stack)
        for _, child in pairs(curr.children) do stack[#stack + 1] = child end
        if curr.tenant_last_access["empty"] ~= nil then stamped = stamped + 1 end
    end
    eq(stamped, 0, "the synthetic tenant never lands in tenant_last_access")
    eq(t.live_nodes, 0, "the skeleton detached")
    eq(t.live_chars, 0, "chars went back to zero too")
end

io.write("\nstate-bounds: " .. passed .. " passed, " .. failed .. " failed\n")
if failed > 0 then
    for i = 1, #failures do io.write("  FAIL " .. failures[i] .. "\n") end
    os.exit(1)
end
os.exit(0)
