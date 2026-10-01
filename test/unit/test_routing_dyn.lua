#!/usr/bin/env luajit
-- 路由策略热变更单测：config_store 的 policy 段（校验/快照/优先级链）与
-- policy.lua 的运行时改道（链解析、原地换装、per-request 盖章）。
--
-- 与 test_watcher.lua 同形状：luajit 口径（authz:latest）跑纯 Lua 逻辑，ngx 用
-- 最小替身（re.find/gsub 只实现 config_store 用到的三个锚定模式，shared dict 是
-- 一张表）。config_store / policy 都用真模块，不 stub 业务，因此这条链路验的
-- 就是线上代码：PUT → write_snapshot → shdict+revision → policy 读取链。
--
-- 运行：
--   docker run --rm -v "$PWD:/repo:ro" -w /repo \
--     --entrypoint /usr/local/openresty/luajit/bin/luajit authz:latest \
--     -e 'package.path="/repo/lualib/?.lua;"..package.path
--         dofile("/repo/test/unit/test_routing_dyn.lua")'
--
-- 真实 HTTP 面的动态生效（改完策略下一次选路走新策略 / 非法 400 / 重启回 env）
-- 由 test/integration/e2e_routing_dyn.py 在真容器里验。

package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath
package.path = (os.getenv("LUA_TEST_LIB") or "./lualib") .. "/?.lua;" .. package.path

--------------------------------------------------------------------------
-- ngx 替身（config_store 与 policy 都只在函数体内碰 ngx，加载期无副作用）
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
        get_keys = function()
            local out = {}
            for k in pairs(store) do out[#out + 1] = k end
            return out
        end,
        _dump = store,
    }
end

local shared = {
    luarouter_config = new_shdict(),
    lr_policy = new_shdict(),
}
_G.ngx = {
    shared = shared,
    now = function() return os.time() end,
    log = function() end,
    WARN = 1, ERR = 2, INFO = 3, NOTICE = 4,
    HTTP_OK = 200, HTTP_BAD_REQUEST = 400,
    ctx = {},
    re = {
        -- config_store 的 trim / parse_positive_int 用到的三个锚定模式，逐个映射
        gsub = function(subject, pattern, repl)
            if pattern == [[^\s+]] then return (subject:gsub("^%s+", "")) end
            if pattern == [[\s+$]] then return (subject:gsub("%s+$", "")) end
            return nil
        end,
        find = function(subject, pattern, _, ctx)
            if pattern == [[^%d+$]] or pattern == [[^%d+$]] or pattern == [[^\d+$]] then
                if string.find(subject, "^%d+$") then
                    if ctx then ctx.pos = #subject + 1 end
                    return 1, #subject
                end
                return nil
            end
            if pattern == [[[,;
]+]] then
                if ctx then
                    local from, to = string.find(subject, "[,;%c]+", ctx.pos)
                    if not from then return nil end
                    ctx.pos = to + 1
                    return from, to
                end
            end
            return nil
        end,
    },
    socket = { tcp = function() return nil end },
}

-- 环境变量替身：env() 先读这张表（capture_env 的 fork 继承缓存语义）
_G.LMR_ENV_CACHE = {
    SMG_POLICY = "cache_aware",
}

--------------------------------------------------------------------------
-- stubs（必须早于 require policy）
--------------------------------------------------------------------------
local observed = { counters = {}, gauges = {} }
package.loaded["resty.luarouter.observability"] = {
    counter = function(name) observed.counters[name] = (observed.counters[name] or 0) + 1 end,
    gauge = function() end,
    record_worker_selection = function() end,
}

local stub_workers = {}
local hints = {}
package.loaded["resty.luarouter.registry"] = {
    load = function() return 0 end,
    change_load = function() return 0 end,
    records = function() return stub_workers end,
    policy_hint_for_model = function(model)
        local hint = hints[model]
        local count = 0
        for _, rec in ipairs(stub_workers) do
            if rec.model_id == model then count = count + 1 end
        end
        return hint, count
    end,
}

--------------------------------------------------------------------------
-- 断言小框架（与其它单测同形状）
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

local store = require "resty.luarouter.config_store"
local policy_mod = require "resty.luarouter.policy"

local base_cfg = {
    policy = "round_robin",
    eviction_interval_secs = 120, max_idle_secs = 14400, assignment_mode = "random",
    cache_threshold = 0.3, balance_abs_threshold = 64, balance_rel_threshold = 1.5,
    max_tree_size = 67108864, prefix_token_count = 256, prefix_hash_load_factor = 1.25,
    bucket_adjust_interval_secs = 5, snapshot_max_bytes = 3 * 1024 * 1024,
}
local function cfg_with(overrides)
    local cfg = {}
    for k, v in pairs(base_cfg) do cfg[k] = v end
    for k, v in pairs(overrides or {}) do cfg[k] = v end
    return cfg
end

--------------------------------------------------------------------------
-- 1. normalize_policy / policy_names（8 策略集合与 config.lua POLICIES 对齐）
--------------------------------------------------------------------------
eq(store.normalize_policy("cache_aware"), "cache_aware", "normalize keeps valid name")
eq(store.normalize_policy("  Random "), "random", "normalize trims and lowercases")
eq(store.normalize_policy(""), nil, "normalize empty is not-set")
eq(store.normalize_policy("auto"), nil, "normalize auto is not-set")
eq(store.normalize_policy("null"), nil, "normalize null string is not-set")
eq(store.normalize_policy(nil), nil, "normalize nil is not-set")
eq(store.normalize_policy(false), false, "normalize false is not-set")
eq(store.normalize_policy(42), false, "normalize non-string rejects")
eq(store.normalize_policy("nope_policy"), false, "normalize unknown rejects")
eq(#store.policy_names(), 8, "policy_names has the eight policies")
for _, name in ipairs({ "random", "round_robin", "cache_aware", "power_of_two",
                        "prefix_hash", "manual", "bucket", "consistent_hashing" }) do
    eq(store.normalize_policy(name), name, "policy set keeps " .. name)
end

--------------------------------------------------------------------------
-- 2. 缺省零行为变化：没有任何配置时链 = hint -> cfg.policy -> round_robin
--------------------------------------------------------------------------
eq(store.policy_global_override(), nil, "no global override by default")
eq(store.policy_override_for("m1"), nil, "no model override by default")
eq(store.policy_override_active(), false, "chain reports inactive by default")
local name, layer = store.resolve_policy("round_robin", "m1", nil)
eq(name, "round_robin", "default chain falls to cfg.policy"); eq(layer, "env", "layer is env")
name, layer = store.resolve_policy("round_robin", "m1", "prefix_hash")
eq(name, "prefix_hash", "default chain honours hint"); eq(layer, "hint", "hint layer")
name, layer = store.resolve_policy("cache_aware", "m1", "not_a_policy")
eq(name, "round_robin", "unknown hint collapses as before"); eq(layer, "hint", "unknown hint keeps hint layer")
name, layer = store.resolve_policy(nil, "m1", nil)
eq(name, "round_robin", "missing cfg.policy falls back to round_robin")
eq(store.env_policy(), "cache_aware", "env_policy mirrors SMG_POLICY default")
_G.LMR_ENV_CACHE.SMG_POLICY = "random"
eq(store.env_policy(), "random", "env_policy reads SMG_POLICY when set")
_G.LMR_ENV_CACHE.SMG_POLICY = "cache_aware"

--------------------------------------------------------------------------
-- 3. apply_policy：全局覆盖 / per-model 覆盖 / 优先级 / 校验回滚
--------------------------------------------------------------------------
local snap, err = store.apply_policy({ policy = "random" })
check(snap ~= nil and err == nil, "apply global policy ok", err)
eq(snap.policy, "random", "snapshot carries global override")
eq(store.policy_global_override(), "random", "override readable without restart")
eq(store.policy_override_active(), true, "chain reports active after first write")
name, layer = store.resolve_policy("cache_aware", "m1", nil)
eq(name, "random", "global override beats cfg.policy"); eq(layer, "global", "global layer wins")
name, layer = store.resolve_policy("cache_aware", "m1", "prefix_hash")
eq(name, "random", "operator global overrides the worker hint"); eq(layer, "global", "still global layer")

snap, err = store.apply_policy({ model_policy = { model = "m1", policy = "bucket" } })
check(snap ~= nil and err == nil, "apply per-model policy ok", err)
eq(store.policy_override_for("m1"), "bucket", "per-model override live")
name, layer = store.resolve_policy("cache_aware", "m1", "prefix_hash")
eq(name, "bucket", "per-model beats hint and global"); eq(layer, "model", "model layer")
name, layer = store.resolve_policy("cache_aware", "m2", "prefix_hash")
eq(name, "random", "untouched model keeps the global override"); eq(layer, "global", "global for other model")

-- 非法策略名：400 语义 = 返回 error 且什么都没写
local rev_before = store.policy_revision()
snap, err = store.apply_policy({ policy = "no_such_policy" })
check(snap == nil and type(err) == "string" and err:find("unknown policy", 1, true) ~= nil,
    "unknown policy rejected", err)
eq(store.policy_global_override(), "random", "rejected write kept the old global")
eq(store.policy_revision(), rev_before, "rejected write did not bump revision")
snap, err = store.apply_policy({ model_policy = { model = "m1", policy = "bogus" } })
check(snap == nil and err:find("m1", 1, true) ~= nil, "unknown per-model policy names the model", err)
eq(store.policy_override_for("m1"), "bucket", "rejected per-model write kept the old row")
snap, err = store.apply_policy({})
check(snap == nil and err:find("nothing to apply", 1, true) ~= nil, "empty patch rejected", err)
snap, err = store.apply_policy("string")
check(snap == nil, "non-object patch rejected", err)
snap, err = store.apply_policy({ policy = 42 })
check(snap == nil and err:find("string or null", 1, true) ~= nil, "numeric policy rejected", err)
snap, err = store.apply_policy({ model_policies = "x" })
check(snap == nil, "non-array model_policies rejected", err)

-- 单行 upsert 保留其它行；model_policies 整表替换；null 清除
snap, err = store.apply_policy({ model_policy = { model = "m9", policy = "manual" } })
check(snap ~= nil, "upsert second row ok", err)
eq(store.policy_override_for("m1"), "bucket", "upsert preserved the first row")
eq(store.policy_override_for("m9"), "manual", "upsert added the new row")
-- explicit JSON_NULL delete path
local cjson_test = require "cjson.safe"
snap, err = store.apply_policy({ model_policy = { model = "m9", policy = cjson_test.null } })
check(snap ~= nil and store.policy_override_for("m9") == nil, "null row deletes just that row", err)
eq(store.policy_override_for("m1"), "bucket", "delete kept m1")
snap, err = store.apply_policy({ model_policies = { { model = "m2", policy = "power_of_two" },
                                                    { model = "m3", policy = "null" } } })
check(snap ~= nil, "whole-table replace ok", err)
eq(store.policy_override_for("m1"), nil, "whole-table replace dropped old rows")
eq(store.policy_override_for("m2"), "power_of_two", "whole-table applied m2")
eq(store.policy_override_for("m3"), nil, "empty policy row means no override")
-- 清空全局：下一次选路回到 hint / env
snap, err = store.apply_policy({ policy = cjson_test.null })
check(snap ~= nil and store.policy_global_override() == nil, "clearing global override ok", err)
name, layer = store.resolve_policy("cache_aware", "m7", "prefix_hash")
eq(name, "prefix_hash", "after clearing global the hint is heard again"); eq(layer, "hint", "hint layer after clear")
store.apply_policy({ model_policies = {} })
name, layer = store.resolve_policy("cache_aware", "m7", nil)
eq(name, "cache_aware", "fully cleared chain is env default")

--------------------------------------------------------------------------
-- 4. 快照往返：policy 段随 snapshot 持久、cfg_from_document 再校验
--------------------------------------------------------------------------
store.apply_policy({ policy = "round_robin", model_policy = { model = "m4", policy = "random" } })
local doc = store.document()
eq(doc.policy, "round_robin", "document carries policy")
local found_m4 = false
for _, row in ipairs(doc.model_policies) do
    if row.model == "m4" then found_m4 = row.policy == "random" end
end
check(found_m4, "document carries model_policies rows")
-- shdict 里的那份 JSON 也带着新段（跨 worker 可见性的载体）
local raw_in_dict = shared.luarouter_config._dump.runtime_config
check(type(raw_in_dict) == "string" and raw_in_dict:find('"policy"', 1, true) ~= nil,
    "snapshot in shdict includes the policy section")
check(raw_in_dict:find("model_policies", 1, true) ~= nil, "shdict snapshot has model_policies key")
-- 从快照重建（模拟另一个 worker 的 current()）
local rebuilt, rerr = store.cfg_from_document(cjson_test.decode(raw_in_dict))
check(rebuilt ~= nil, "snapshot reloads unchanged", rerr)
eq(rebuilt.policy, "round_robin", "rebuilt cfg keeps global policy")
eq(rebuilt.model_policies.m4, "random", "rebuilt cfg keeps per-model policy")
local bad, bad_err = store.cfg_from_document({ policy = "not_a_policy" })
check(bad == nil and bad_err ~= nil, "cfg_from_document validates policy", bad_err)
bad = store.cfg_from_document({ model_policies = { { model = "", policy = "random" } } })
check(bad == nil, "cfg_from_document rejects nameless policy rows")
bad = store.cfg_from_document({ policy = cjson_test.null })
check(bad ~= nil and bad.policy == nil, "explicit null policy in document clears it")

--------------------------------------------------------------------------
-- 5. policy.lua：for_model 走链，实例缓存按新名字区分
--------------------------------------------------------------------------
local function make_workers(model, n)
    local out = {}
    for i = 1, n do
        out[i] = { id = model .. "-w" .. i, url = "http://" .. model .. i,
                   load = 0, healthy = true, model_id = model }
    end
    return out
end
stub_workers = make_workers("m1", 3)
hints.m1 = "prefix_hash"  -- 该模型的实例广告 labels.policy=prefix_hash

-- 无覆盖时 hint 说了算（与改造前逐字节一致）
store.apply_policy({ policy = cjson_test.null, model_policies = {} })
local inst_hint = policy_mod.for_model(base_cfg, "m1", "prefix_hash", true)
eq(inst_hint:policy_name(), "prefix_hash", "for_model keeps the advertised hint")

-- per-model 覆盖压过 hint（免重启的核心语义）
store.apply_policy({ model_policy = { model = "m1", policy = "cache_aware" } })
local inst_override = policy_mod.for_model(base_cfg, "m1", "prefix_hash", true)
eq(inst_override:policy_name(), "cache_aware", "operator per-model override beats the hint")
check(inst_override ~= inst_hint, "new policy means a new instance for that model")
-- 覆盖期间 hint 不再决定实例；清掉覆盖后回到 hint（同进程内存里旧实例复用）
store.apply_policy({ model_policies = {} })
local inst_back = policy_mod.for_model(base_cfg, "m1", "prefix_hash", true)
eq(inst_back:policy_name(), "prefix_hash", "clearing the override restores the hint instance")
check(inst_back == inst_hint, "the original prefix_hash instance is reused")

-- last-worker-gone 清理 + default key 行为不变
local inst_default = policy_mod.for_model(base_cfg, "m1", nil, false)
eq(inst_default:policy_name(), base_cfg.policy, "dropping the model falls back to default cfg policy")

--------------------------------------------------------------------------
-- 6. 原地换装：全局实例在引用不变的情况下换策略
--------------------------------------------------------------------------
local router_like = policy_mod.new(base_cfg)          -- router.policy_for 的 file-local
policy_mod.default = router_like
eq(router_like:policy_name(), "round_robin", "instance starts on cfg.policy")
store.apply_policy({ policy = "random" })
policy_mod.stamp_global(router_like, "m-none")
eq(router_like:policy_name(), "random", "stamp switches the global instance in place")
eq(policy_mod.default, router_like, "table identity survives the switch (router cache stays valid)")
check(policy_mod.instances["random:default"] == router_like, "instance registry re-keyed")
check(policy_mod.instances["round_robin:default"] == nil, "old key dropped from registry")

-- per-model 覆盖打在共享默认实例上（无 hint 的模型走 router 的 default 路径）
store.apply_policy({ policy = cjson_test.null, model_policy = { model = "alpha", policy = "cache_aware" } })
policy_mod.stamp_global(router_like, "alpha")
eq(router_like:policy_name(), "cache_aware", "per-model override reaches the shared default instance")
local candidates = make_workers("alpha", 3)
local chosen = router_like:select({ candidates = candidates, model = "alpha",
                                    request_text = "affinity probe" })
check(type(chosen) == "table" and chosen.url ~= nil, "switched instance selects via the new module",
    type(chosen))
check(policy_mod.instances["cache_aware:alpha"] == nil
    or policy_mod.instances["cache_aware:alpha"] ~= router_like,
    "stamped default keeps its own key")

-- 粘滞性检查：换到 random 后，同前缀不再粘同一个 worker
local random_cfg = cfg_with({ policy = "random" })
local inst_random = policy_mod.new(random_cfg, { model = "rand-m", name = "random" })
local urls_seen = {}
for _ = 1, 40 do
    local w = inst_random:select({ candidates = make_workers("rand", 4), model = "rand-m",
                                   request_text = "same prefix every time" })
    urls_seen[w.url] = true
end
check(next(urls_seen) ~= nil and (function()
    local n = 0
    for _ in pairs(urls_seen) do n = n + 1 end
    return n >= 2
end)(), "random spreads identical prefixes across workers")

-- 清掉全部覆盖 → stamp 让实例走回 env 链（router 的 cfg.policy 就是 SMG_POLICY
-- 经 config.lua one_of 解析后的值，所以 env 层看的是实例自带的 cfg）
store.apply_policy({ policy = cjson_test.null, model_policies = {} })
policy_mod.stamp_global(router_like, "alpha")
eq(router_like:policy_name(), "round_robin", "env layer drives the chain again once cleared")
-- env 换成别的策略时也要跟上去（证明不是「最后一次 stamp 粘住」）
router_like.cfg = cfg_with({ policy = "power_of_two" })
policy_mod.stamp_global(router_like, "alpha")
eq(router_like:policy_name(), "power_of_two", "chain re-resolves after the last override is cleared")

--------------------------------------------------------------------------
-- 7. 跨 worker 可见性：共享 shdict 的 revision 一变，本进程 memo 立刻失效
--------------------------------------------------------------------------
local rev_a = store.policy_revision()
policy_mod.stamp_global(router_like, "m1")   -- memo 建立
eq(store.policy_revision(), rev_a, "reading does not bump the revision")
-- 另一个进程写：直接动 shdict（等价 write_snapshot 的 incr）
shared.luarouter_config._dump.policy_revision = nil
local bumped = store.policy_revision()
check(bumped ~= rev_a, "revision token changes when another process writes", bumped)

--------------------------------------------------------------------------
-- 8. 非法策略在实例层的兜底与 metrics 名字
--------------------------------------------------------------------------
local junk = policy_mod.new(cfg_with({ policy = "not_a_policy" }))
eq(junk:policy_name(), "round_robin", "unknown cfg.policy still collapses (unchanged)")
-- stamp 传入未知覆盖名也绝不崩（store 层已挡，这里是第二道）
policy_mod.stamp_global(junk, "m1")
check(junk:policy_name() == "round_robin" or junk:policy_name() ~= nil,
    "stamp on a collapsed instance stays valid", junk:policy_name())

--------------------------------------------------------------------------
-- 9. policy_document（路由页的数据面）
--------------------------------------------------------------------------
store.apply_policy({ policy = "manual", model_policy = { model = "m1", policy = "bucket" } })
local pd = store.policy_document()
eq(#pd.policies, 8, "document lists the eight policies")
eq(pd.policy, "manual", "document shows the global override")
eq(pd.effective_default, "manual", "effective_default is the global override when set")
local by_model = {}
for _, row in ipairs(pd.models) do by_model[row.model] = row end
check(by_model.m1 ~= nil, "document row for a configured model exists")
eq(by_model.m1.effective, "bucket", "document row shows the per-model winner")
eq(by_model.m1.source, "model", "document names the winning layer")
check(by_model.m1.hint == "prefix_hash", "document still shows the shadowed hint",
    by_model.m1 and tostring(by_model.m1.hint))
check(type(pd.revision) == "string" or type(pd.revision) == "number",
    "document carries the revision token", type(pd.revision))
store.apply_policy({ policy = cjson_test.null, model_policies = {} })
pd = store.policy_document()
eq(pd.effective_default, "cache_aware", "cleared document falls back to env policy")

--------------------------------------------------------------------------
-- 10. 端点语义：ui.lua 桥 → config_store.handle_config_policy（400/200 与回显）
--------------------------------------------------------------------------
_G.ngx.header = {}
local captured = {}
local captured_body = nil
_G.ngx.say = function(text) captured[#captured + 1] = text end
_G.ngx.exit = function(status) return status end
_G.ngx.req = {
    read_body = function() end,
    get_body_data = function() return captured_body end,
    get_body_file = function() return nil end,
    get_method = function() return "PUT" end,
}
local function request_body(value)
    if value == nil then captured_body = nil
    elseif type(value) == "string" then captured_body = value
    else captured_body = cjson_test.encode(value) end
end

local ui = require "resty.luarouter.ui"

local function call_handler(fn)
    captured = {}
    _G.ngx.status = nil
    fn()
    return _G.ngx.status, cjson_test.decode(captured[1] or "")
end

-- GET 文档
store.apply_policy({ policy = cjson_test.null, model_policies = {} })
local status, payload = call_handler(ui.config_policy_get)
eq(status, 200, "GET handler answers 200")
eq(type(payload) == "table" and #payload.policies, 8, "GET handler returns the policy list")
eq(payload.effective_default, "cache_aware", "GET handler reports the env layer")

-- PUT 生效 + 回显
request_body({ policy = "bucket" })
status, payload = call_handler(ui.config_policy)
eq(status, 200, "PUT handler applies and echoes 200")
eq(payload.policy, "bucket", "PUT response echoes the new global policy")
eq(store.policy_global_override(), "bucket", "PUT really reached the live config")

-- 非法策略名：400 且不生效
request_body({ policy = "definitely_not_a_policy" })
status, payload = call_handler(ui.config_policy)
eq(status, 400, "PUT unknown policy answers 400")
check(type(payload) == "table" and type(payload.error) == "string"
    and payload.error:find("unknown policy", 1, true) ~= nil,
    "the 400 body explains the rejection", payload and payload.error)
eq(store.policy_global_override(), "bucket", "the 400 left the previous policy in place")

-- 空 body / 坏 JSON / 空 patch 都是 400
request_body(nil)
status = call_handler(ui.config_policy)
eq(status, 400, "empty body is a 400")
request_body("{not json")
status = call_handler(ui.config_policy)
eq(status, 400, "broken JSON is a 400")
request_body({})
status, payload = call_handler(ui.config_policy)
eq(status, 400, "patch without sections is a 400")

-- per-model 行经端点删除
request_body({ model_policy = { model = "alpha", policy = "manual" } })
status = call_handler(ui.config_policy)
eq(status, 200, "PUT per-model row ok")
eq(store.policy_override_for("alpha"), "manual", "per-model row live through the endpoint")
request_body({ model_policy = { model = "alpha", policy = cjson_test.null } })
status = call_handler(ui.config_policy)
eq(status, 200, "PUT null row ok")
eq(store.policy_override_for("alpha"), nil, "null row removed through the endpoint")

-- 全部清理，恢复默认（后面的回归检查跑在干净状态上）
call_handler(function() end)
store.apply_policy({ policy = cjson_test.null, model_policies = {} })

print("routing_dyn: " .. passed .. " passed, " .. failed .. " failed")
if failed > 0 then
    for i = 1, #failures do print("  FAIL " .. failures[i]) end
    os.exit(1)
end
