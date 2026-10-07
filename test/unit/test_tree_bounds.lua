#!/usr/bin/env luajit
-- 亲和树体积上界与增量计数单测（doc/gap-cpu-idle-burn.md，分支 fix/cpu-idle-burn）。
--   运行：docker run --rm -e LUA_TEST_LIB=/repo/lualib -v "$PWD:/repo:ro" authz:latest \
--          /usr/local/openresty/luajit/bin/luajit /repo/test/unit/test_tree_bounds.lua
--
-- 这些用例盯的是生产事故的两条具体形状：
--   * 节点数没有上限维度（evict_tenant_by_size 只管「每租户字符数」）；
--   * detach_if_empty 的触发条件在 trie 骨架长出来后几乎不成立，计数只涨不跌。
-- 所以核心断言全部是「增量计数 == DFS 重算」，它一旦漂移，新加的节点闸就是摆设。
local root = os.getenv("LUA_TEST_LIB") or "./lualib"
package.path = root .. "/?.lua;" .. root .. "/resty/luarouter/policies/?.lua;" .. package.path

local tree_mod = require "resty.luarouter.policies.tree"

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

--- DFS 重算：非 root 节点数与它们的 text_chars 总和（对照用）
local function recount(t)
    local n, c = 0, 0
    local stack = { t.root }
    while #stack > 0 do
        local curr = table.remove(stack)
        for _, child in pairs(curr.children) do stack[#stack + 1] = child end
        if curr ~= t.root then
            n = n + 1
            c = c + (curr.text_chars or 0)
        end
    end
    return n, c
end

local function assert_counters(t, name)
    local n, c = recount(t)
    eq(t.live_nodes, n, name .. ": live_nodes == DFS")
    eq(t.live_chars, c, name .. ": live_chars == DFS")
end

new_case("insert 长出的节点数与字符数被增量记准")
local t = tree_mod.new()
assert_counters(t, "empty")
t:insert("hello world", "http://w1")
assert_counters(t, "one leaf")
t:insert("hello there", "http://w1")
assert_counters(t, "split")
check(t.live_nodes >= 3, "split added an intermediate node", t.live_nodes)

new_case("随机 insert 压力下计数仍与 DFS 一致")
local t2 = tree_mod.new()
local rnd = 1
local function rr(n)
    rnd = (rnd * 1103515245 + 12345) % 2147483648
    return rnd % n
end
for i = 1, 400 do
    local tenant = "http://w" .. (1 + rr(4))
    local base = "prefix-" .. (rr(5)) .. "-"
    t2:insert(base .. i .. "-tail-" .. ("x"):rep(rr(30)), tenant)
end
assert_counters(t2, "400 inserts")
check(t2.live_nodes > 300, "the tree actually grew", t2.live_nodes)

new_case("evict 之后计数仍与 DFS 一致（detach 必须同步回收）")
t2:evict_tenant_by_size(3)
assert_counters(t2, "after evict")

new_case("remove_tenant 之后计数仍与 DFS 一致")
local t3 = tree_mod.new()
t3:insert("aaaaaaaaaa", "http://w1")
t3:insert("aaaaaaaaab", "http://w1")
t3:insert("aaaaaaaaac", "http://w2")
assert_counters(t3, "before remove")
t3:remove_tenant("http://w1")
assert_counters(t3, "after remove_tenant")
eq(t3.tenant_char_count["http://w1"], nil, "tenant gone from counters")

new_case("EMPTY_TENANT 不再被写进 tenant_last_access（否则会永久堵住 detach）")
local t4 = tree_mod.new()
t4:insert("known-path", "http://w1")
-- 冷前缀查询：匹配不到租户的分支过去会把假租户 "empty" 盖在沿途节点上，
-- 而 detach_if_empty 要求 tenant_last_access 为空才摘节点 -> 骨架永不收缩。
local tenant = t4:prefix_match_with_counts("known-path-suffix-that-differs")
check(tenant == "empty" or tenant ~= nil, "match still answers something", tostring(tenant))
for _ = 1, 400 do
    t4:prefix_match_with_counts("known-path" .. "-" .. _ .. "-zzz")
end
local stamped = 0
local stack = { t4.root }
while #stack > 0 do
    local curr = table.remove(stack)
    for _, child in pairs(curr.children) do stack[#stack + 1] = child end
    if curr.tenant_last_access["empty"] ~= nil then stamped = stamped + 1 end
end
eq(stamped, 0, "no node carries the synthetic empty tenant")
assert_counters(t4, "after cold-prefix storm")

new_case("max_nodes 触发节点维度淘汰：字符没超标也要能收敛")
local t5 = tree_mod.new()
-- 4 个租户、每租户字符数很小（远低于 max_size），但节点数远超 max_nodes。
for i = 1, 60 do
    t5:insert("n" .. i .. "-" .. ("y"):rep(6), "http://w" .. (1 + (i % 4)))
end
assert_counters(t5, "t5 before")
local before = t5.live_nodes
local more = t5:evict_tenant_by_size(100000, 20)   -- 字符闸放宽，只卡节点数
check(t5.live_nodes < before, "node dimension evicted",
    before .. " -> " .. t5.live_nodes)
assert_counters(t5, "t5 after")

new_case("max_nodes <= 0 时节点维度不生效（兼容只想用字符闸的部署）")
local t6 = tree_mod.new()
for i = 1, 40 do
    t6:insert("k" .. i .. "-" .. ("z"):rep(5), "http://w1")
end
local n6 = t6.live_nodes
t6:evict_tenant_by_size(100000, 0)
eq(t6.live_nodes, n6, "no node-dimension eviction when max_nodes = 0")

new_case("增量预算：单拍最多弹 budget 个，剩下的下一拍接着清")
local t7 = tree_mod.new()
for i = 1, 200 do
    t7:insert("budget-" .. i .. "-" .. ("q"):rep(3), "http://w1")
end
local pops_more = t7:evict_tenant_by_size(1, nil, 5)
check(pops_more == true, "one tick reports more work", tostring(pops_more))
-- 反复调用应最终收敛（追平即可，不要求一拍清完）
local guard = 0
while guard < 60 do
    guard = guard + 1
    if not t7:evict_tenant_by_size(1, nil, 5) then break end
end
check(guard < 60, "eviction converged within the budget loop", guard)
assert_counters(t7, "t7 after budget loop")

new_case("over_limit 在未超限时不做全树 DFS（廉价前置判定）")
local t8 = tree_mod.new()
for i = 1, 500 do
    t8:insert("cheap-" .. i .. "-" .. ("m"):rep(20), "http://w" .. (1 + (i % 8)))
end
eq(t8:over_limit(100000, 100000), false, "under both limits -> no work")
eq(t8:over_limit(1, 100000), true, "per-tenant chars over limit")
eq(t8:over_limit(100000, 10), true, "node count over limit")
-- 骨架停摆位：节点摘不动时不再每拍重建堆
t8.node_evict_stalled = true
eq(t8:over_limit(100000, 10), false, "stalled flag suppresses the node dimension")

new_case("serialize 超预算时直接返回 nil，且不建条目表")
local t9 = tree_mod.new()
for i = 1, 300 do
    t9:insert("snap-" .. i .. "-" .. ("p"):rep(200), "http://w1")
end
eq(t9:serialize(10), nil, "tiny budget -> nil")
eq(t9.snapshot_oversized, true, "oversized flag set")
local snap = t9:serialize(50 * 1024 * 1024)
check(type(snap) == "table" and type(snap.leaves) == "table",
    "generous budget still serializes")
eq(t9.snapshot_oversized, false, "oversized flag cleared on success")
-- 预算之内：粗筛就该放行，且条目数与 DFS 看到的叶子数一致
local small = tree_mod.new()
small:insert("abc", "http://w1")
local s2 = small:serialize(4096)
check(type(s2) == "table" and #s2.leaves == 1, "one leaf -> one entry",
    s2 and #s2.leaves or "nil")

new_case("restore 后增量计数不重复计账（换树必须归零）")
local src = tree_mod.new()
for i = 1, 80 do
    src:insert("rs-" .. i .. "-" .. ("v"):rep(20), "http://w" .. (1 + (i % 3)))
end
local snapshot = src:serialize(10 * 1024 * 1024)
local dst = tree_mod.new()
dst:insert("junk-before-restore-xxxxxxxxxxxx", "http://w9")
dst:restore(snapshot)
assert_counters(dst, "restored tree")
-- 恢复出来的树与原树规模一致
eq(dst.live_nodes, src.live_nodes, "restored node count matches source")
eq(dst.live_chars, src.live_chars, "restored char count matches source")

io.write("\ntree-bounds: " .. passed .. " passed, " .. failed .. " failed\n")
if failed > 0 then
    for i = 1, #failures do io.write("  FAIL " .. failures[i] .. "\n") end
    os.exit(1)
end
os.exit(0)
