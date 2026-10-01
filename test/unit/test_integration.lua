#!/usr/bin/env resty
-- 集成接线单测：policy 工厂分发、cache_aware 树快照、原始 JSON 字段编辑。
--   运行（真实 ngx 环境，stub 掉 shared-dict 依赖）：
--   docker run --rm -v "$PWD:/repo:ro" -w /repo \
--     --entrypoint /usr/bin/resty apache/apisix:3.11.0-debian \
--     -e 'package.path="/repo/lualib/?.lua;"..package.path
--         dofile("/repo/test/unit/test_integration.lua")'
--
-- 为什么能这么跑：policy.lua 只通过 observability.counter/gauge 与
-- registry.load/records 触碰外部世界，router.lua 的 set_top_field 是纯字符串函数。
-- 两个模块都在 require 之前塞进 package.loaded 的替身即可隔离测试，
-- 不需要 shared dict（dict() 只在被 stub 的方法路径上才会调用）。

package.path = (os.getenv("LUA_TEST_LIB") or "./lualib") .. "/?.lua;" .. package.path

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
        actual ~= expect and (tostring(actual) .. " ~= " .. tostring(expect)) or nil)
end

--------------------------------------------------------------------------
-- stubs（必须在 require "resty.luarouter.policy" 之前装好）
--------------------------------------------------------------------------
local observed = { counters = {}, gauges = {} }
package.loaded["resty.luarouter.observability"] = {
    counter = function(name, pairs_spec, delta)
        observed.counters[name] = (observed.counters[name] or 0) + (delta or 1)
    end,
    gauge = function(name, pairs_spec, value)
        observed.gauges[name] = value
    end,
    record_worker_selection = function(url, model, policy)
        observed.last_selection = { url = url, model = model, policy = policy }
    end,
}

local stub_workers = {}
package.loaded["resty.luarouter.registry"] = {
    load = function(id) return 0 end,
    change_load = function() return 0 end,
    records = function() return stub_workers end,
}

-- 共享字典替身：policy.lua 的 dict() 走 ngx.shared，直接给它一张表
local fake_store = {}
_G.ngx.shared = _G.ngx.shared or {}
setmetatable(_G.ngx.shared, { __index = function(_, key)
    if key ~= "lr_policy" then return nil end
    return {
        get = function(_, k) return fake_store[k] end,
        set = function(_, k, v) fake_store[k] = v; return true end,
        incr = function(_, k, d, init)
            fake_store[k] = (fake_store[k] or init or 0) + d; return fake_store[k]
        end,
        delete = function(_, k) fake_store[k] = nil end,
        get_keys = function() local out = {}; for k in pairs(fake_store) do out[#out+1]=k end; return out end,
    }
end })

local policy_mod = require "resty.luarouter.policy"

local function make_workers(n)
    local out = {}
    for i = 1, n do
        out[i] = { id = "w" .. i, url = "http://w" .. i, load = 0, healthy = true,
                   model_id = "m1" }
    end
    stub_workers = out
    return out
end

local base_cfg = {
    policy = "round_robin",
    eviction_interval_secs = 120, max_idle_secs = 14400, assignment_mode = "random",
    cache_threshold = 0.3, balance_abs_threshold = 64, balance_rel_threshold = 1.5,
    max_tree_size = 67108864, prefix_token_count = 256, prefix_hash_load_factor = 1.25,
    bucket_adjust_interval_secs = 5, snapshot_max_bytes = 3 * 1024 * 1024,
}

--------------------------------------------------------------------------
-- 1. 工厂分发：8 个策略名各自命中实现
--------------------------------------------------------------------------
local standalone_expected = {
    cache_aware = true, bucket = true, consistent_hashing = true, prefix_hash = true,
}
for _, name in ipairs({ "random", "round_robin", "cache_aware", "power_of_two",
                        "prefix_hash", "manual", "bucket", "consistent_hashing" }) do
    local cfg = {}
    for k, v in pairs(base_cfg) do cfg[k] = v end
    cfg.policy = name
    local inst = policy_mod.new(cfg)
    eq(inst:name_instance():match("^[^:]+"), name, "factory keeps name " .. name)
    eq(inst.impl ~= nil, standalone_expected[name] == true,
        "factory wires module for " .. name)
end

-- 未知策略名回落 round_robin，且不加载任何模块
local cfg_unknown = {}
for k, v in pairs(base_cfg) do cfg_unknown[k] = v end
cfg_unknown.policy = "not_a_policy"
local inst_unknown = policy_mod.new(cfg_unknown)
eq(inst_unknown.name, "round_robin", "unknown policy collapses to round_robin")
eq(inst_unknown.impl, nil, "unknown policy loads no module")

--------------------------------------------------------------------------
-- 2. select() 统一返回 entry（而非下标），并记 selection metric
--------------------------------------------------------------------------
local workers = make_workers(3)
local text = "the quick brown fox jumps over the lazy dog"

local function select_one(name, request_text)
    local cfg = {}
    for k, v in pairs(base_cfg) do cfg[k] = v end
    cfg.policy = name
    local inst = policy_mod.new(cfg)
    return inst:select({ candidates = workers, request_text = request_text,
                         headers = {}, model = "m1" })
end

for _, name in ipairs({ "random", "round_robin", "power_of_two", "manual",
                        "cache_aware", "bucket", "consistent_hashing", "prefix_hash" }) do
    local chosen = select_one(name, text)
    check(type(chosen) == "table" and chosen.url ~= nil,
        "select returns entry for " .. name, type(chosen))
    eq(observed.last_selection.policy, name, "selection metric names " .. name)
end

-- cache_aware 粘滞（同文本 10 次同一 worker）
local first = select_one("cache_aware", text)
local stuck = true
for _ = 1, 9 do
    if select_one("cache_aware", text).url ~= first.url then stuck = false end
end
-- 每次 select_one 都新建实例，粘滞必须在同一实例上测
local cfg_ca = {}
for k, v in pairs(base_cfg) do cfg_ca[k] = v end
cfg_ca.policy = "cache_aware"
local inst_ca = policy_mod.new(cfg_ca)
local ca_first = inst_ca:select({ candidates = workers, request_text = text, model = "m1" })
stuck = true
for _ = 1, 9 do
    local again = inst_ca:select({ candidates = workers, request_text = text, model = "m1" })
    if again.url ~= ca_first.url then stuck = false end
end
check(stuck, "cache_aware sticks to one worker for one prefix")

-- consistent_hashing 用 routing-key 粘滞
local cfg_ch = {}
for k, v in pairs(base_cfg) do cfg_ch[k] = v end
cfg_ch.policy = "consistent_hashing"
local inst_ch = policy_mod.new(cfg_ch)
local ch_first = inst_ch:select({ candidates = workers, model = "m1",
                                  headers = { ["x-smg-routing-key"] = "session-42" } })
local ch_stuck = true
for _ = 1, 9 do
    local again = inst_ch:select({ candidates = workers, model = "m1",
                                   headers = { ["x-smg-routing-key"] = "session-42" } })
    if again.url ~= ch_first.url then ch_stuck = false end
end
check(ch_stuck, "consistent_hashing sticks per routing key")
check(observed.counters["smg_consistent_hashing_policy_branch_total"] ~= nil,
    "hashing branch counter recorded")

-- needs_request_text
for _, name in ipairs({ "cache_aware", "bucket", "prefix_hash" }) do
    local cfg = {}
    for k, v in pairs(base_cfg) do cfg[k] = v end
    cfg.policy = name
    eq(policy_mod.new(cfg):needs_request_text(), true, name .. " needs request text")
end
for _, name in ipairs({ "random", "round_robin", "power_of_two", "manual",
                        "consistent_hashing" }) do
    local cfg = {}
    for k, v in pairs(base_cfg) do cfg[k] = v end
    cfg.policy = name
    eq(policy_mod.new(cfg):needs_request_text(), false, name .. " ignores request text")
end

--------------------------------------------------------------------------
-- 3. cache_aware 快照：写回 lr_policy、max_bytes 跳过、恢复回同进程树
--------------------------------------------------------------------------
local snap_workers = make_workers(2)
cfg_ca.snapshot_max_bytes = 3 * 1024 * 1024
local writer = policy_mod.new(cfg_ca)
writer:prepare()
writer:select({ candidates = snap_workers, request_text = "snapshot unit prefix", model = "m1" })
local key = writer:snapshot_key()
check(key:find("^snapshot:cache_aware:default:") ~= nil, "snapshot key shape", key)
eq(writer:save_snapshot(), true, "save_snapshot writes")
check(type(fake_store[key]) == "string" and #fake_store[key] > 0,
    "lr_policy holds JSON text")
local cjson = require "cjson.safe"
local parsed = cjson.decode(fake_store[key])
check(type(parsed) == "table" and parsed.policy == "cache_aware"
    and type(parsed.trees) == "table", "snapshot shape is the tree dump")

-- max_bytes 超限：跳过写盘，不报错，也不覆盖旧值
local stale = fake_store[key]
cfg_ca.snapshot_max_bytes = 16
local tight = policy_mod.new(cfg_ca)
tight:prepare()
tight:select({ candidates = snap_workers, request_text = "a much longer snapshot payload",
               model = "m1" })
eq(tight:save_snapshot(), false, "oversized snapshot is skipped")
-- the previously stored dump survives untouched (same key: same policy + model)
eq(fake_store[tight:snapshot_key()], stale, "skip leaves the previous dump alone")

-- 恢复：新实例 decode_snapshot 之后粘滞同一个 worker（模拟 reload）
cfg_ca.snapshot_max_bytes = 3 * 1024 * 1024
local reader = policy_mod.new(cfg_ca)
reader:restore_snapshot()
check(reader.seeded == false, "restore does not imply seeding")
reader:prepare()
local restored_first = reader:select({ candidates = snap_workers,
                                       request_text = "snapshot unit prefix", model = "m1" })
local restored_stuck = true
for _ = 1, 5 do
    local again = reader:select({ candidates = snap_workers,
                                  request_text = "snapshot unit prefix", model = "m1" })
    if again.url ~= restored_first.url then restored_stuck = false end
end
check(restored_stuck, "restored tree keeps affinity")

--------------------------------------------------------------------------
-- 4. worker 增删通知
--------------------------------------------------------------------------
local notify = policy_mod.new(cfg_ca)
notify:prepare()
notify:on_add({ url = "http://w9", model_id = "m1" })
notify:on_remove({ url = "http://w9" })
check(true, "on_add/on_remove survive on a standalone policy")

--------------------------------------------------------------------------
-- 5. router.set_top_field（纯字符串路径，不碰 ngx.req）
--    router.lua 依赖 klib 与 cosocket，无法在 resty CLI 里 require；
--    把函数体所在的片段单独 load 进沙箱不现实，这里用等价的独立编译：
--    直接读文件里 set_top_field 的实现并在最小环境执行。
--------------------------------------------------------------------------
local function load_set_top_field()
    local src = io.open((os.getenv("LUA_TEST_LIB") or "./lualib")
        .. "/resty/luarouter/router.lua"):read("*a")
    local body = src:match("(local function field_pattern.-)\n_M%.set_top_field")
    check(type(body) == "string", "set_top_field source extracted")
    local sandbox = {
        ngx = ngx,
        json_encode = require("cjson.safe").encode,
    }
    -- keep the standard library reachable (the chunk has no other _ENV)
    setmetatable(sandbox, { __index = _G })
    local chunk = load(body .. "\nreturn set_top_field", "set_top_field", "t", sandbox)
    return chunk and chunk() or nil
end

local set_top_field = load_set_top_field()
if set_top_field then
    local raw = '{"model":"m","tools":[{"type":"function"}],"nested":{"model":"keep"},'
        .. '"reasoning_effort":"low","max_tokens":99999}'
    local replaced = set_top_field(raw, "reasoning_effort", "high")
    check(replaced:find('"reasoning_effort":"high"', 1, true) ~= nil, "string member replaced")
    check(replaced:find('"reasoning_effort":"low"', 1, true) == nil, "old value gone")
    local capped = set_top_field(raw, "max_tokens", 128)
    check(capped:find('"max_tokens":128', 1, true) ~= nil, "number member replaced")
    local added = set_top_field(raw, "user", "u1")
    check(added:find('"user":"u1",', 1, true) ~= nil, "absent member inserted first")
    check(added:find('"nested":{"model":"keep"}', 1, true) ~= nil, "nested member untouched")
    check(added:find('"tools":[{"type":"function"}]', 1, true) ~= nil, "empty-ish array kept")
    local removed = set_top_field(raw, "reasoning_effort", nil)
    local decoded = cjson.decode(removed)
    check(decoded ~= nil and decoded.reasoning_effort == nil and decoded.model == "m"
        and decoded.max_tokens == 99999, "removal keeps the document valid", removed)
    local sole = set_top_field('{"reasoning_effort":"low"}', "reasoning_effort", nil)
    check(cjson.decode(sole) ~= nil and next(cjson.decode(sole) or {}) == nil
        or sole:gsub("%s", "") == "{}", "sole member removal yields empty object", sole)
    local empty = set_top_field("{}", "model", "m")
    check(empty:gsub("%s", "") == '{"model":"m"}', "insert into empty object", empty)
    -- removal when the member is last (no trailing comma on its right)
    local last = set_top_field('{"a":1,"reasoning_effort":"low"}', "reasoning_effort", nil)
    check(cjson.decode(last) ~= nil and cjson.decode(last).a == 1
        and #cjson.decode(last) >= 0, "last member removal valid", last)
    -- removal when the member is first
    local head = set_top_field('{"reasoning_effort":"low","a":1}', "reasoning_effort", nil)
    check(cjson.decode(head) ~= nil and cjson.decode(head).a == 1, "first member removal valid",
        head)
else
    check(false, "set_top_field loaded")
end

--------------------------------------------------------------------------
ngx.say("integration: " .. passed .. " passed, " .. failed .. " failed")
if failed > 0 then
    for i = 1, #failures do ngx.say("  FAIL " .. failures[i]) end
    os.exit(1)
end
