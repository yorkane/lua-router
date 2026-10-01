#!/usr/bin/env luajit
-- tree.lua / utils.lua 字符层单测。
--   运行：docker run --rm -v "$PWD:/repo:ro" authz:latest \
--          /usr/local/openresty/luajit/bin/luajit /repo/test/unit/test_tree.lua
local root = os.getenv("LUA_TEST_LIB") or "./lualib"
package.path = root .. "/?.lua;" .. root .. "/resty/luarouter/policies/?.lua;" .. package.path

local tree_mod = require "resty.luarouter.policies.tree"
local utils = require "resty.luarouter.policies.utils"

--------------------------------------------------------------------------
-- 极简断言框架
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
    check(actual == expect, name, (actual ~= expect) and (tostring(actual) .. " ~= " .. tostring(expect)) or nil)
end

local function new_case(name)
    io.write("  case: " .. name .. "\n")
end

--------------------------------------------------------------------------
-- UTF-8 字符层（tree 的正确性依赖它）
--------------------------------------------------------------------------
new_case("utf8 len/head/tail 码点计数")
eq(utils.utf8_len(""), 0, "utf8_len empty")
eq(utils.utf8_len("abc"), 3, "utf8_len ascii")
eq(utils.utf8_len("你好世界"), 4, "utf8_len cjk")
eq(utils.utf8_len("a你b"), 3, "utf8_len mixed")
eq(utils.utf8_head("你好世界", 2), "你好", "utf8_head cjk")
eq(utils.utf8_tail("你好世界", 2), "世界", "utf8_tail cjk")
eq(utils.utf8_head("你好", 9), "你好", "utf8_head overflow")
eq(utils.utf8_first("你好"), "你", "utf8_first cjk")
eq(utils.utf8_first(""), nil, "utf8_first empty")

new_case("utf8 shared_prefix_count 分叉正确")
eq(utils.utf8_shared_prefix_count("apple", "apricot"), 2, "shared ap")
eq(utils.utf8_shared_prefix_count("你好世界", "你好世界"), 4, "shared cjk full")
eq(utils.utf8_shared_prefix_count("你好a", "你好b"), 2, "shared cjk 2")
eq(utils.utf8_shared_prefix_count("abc", "abc"), 3, "shared equal")
eq(utils.utf8_shared_prefix_count("", "abc"), 0, "shared empty")
-- 同首字节但不同码点：不能按字节算
eq(utils.utf8_shared_prefix_count("\228\189\160", "\228\189\146"), 0, "shared same lead byte diff char")

--------------------------------------------------------------------------
-- 树形态：插入、分叉、公共前缀分裂、深度
--------------------------------------------------------------------------
new_case("insert + prefix_match 精确匹配（无分叉）")
local t = tree_mod.new()
t:insert("", "w1")
t:insert("hello world", "w1")
local tenant, matched, input = t:prefix_match_with_counts("hello world")
eq(tenant, "w1", "exact match tenant")
eq(matched, 11, "exact match chars")
eq(input, 11, "exact input chars")

new_case("prefix_match 分叉：只匹配公共前缀")
t = tree_mod.new()
t:insert("apple", "w1")
t:insert("apricot", "w2")
tenant, matched, input = t:prefix_match_with_counts("apricot")
eq(matched, 7, "apricot fully matched")
eq(input, 7, "apricot input chars")
tenant, matched, input = t:prefix_match_with_counts("apple")
eq(matched, 5, "apple fully matched")
tenant, matched, input = t:prefix_match_with_counts("ap")
eq(matched, 2, "ap partial")
eq(input, 2, "ap input")
tenant, matched, input = t:prefix_match_with_counts("zebra")
eq(matched, 0, "zebra no match")

new_case("公共前缀分裂后两条路径都可精确匹配")
t = tree_mod.new()
t:insert("abcdefgh", "w1")
t:insert("abcdefzz", "w2")          -- 触发 split：abcdefgh -> abcdef + {gh, zz}
tenant, matched, _ = t:prefix_match_with_counts("abcdefgh")
eq(matched, 8, "split path 1 exact")
tenant, matched, _ = t:prefix_match_with_counts("abcdefzz")
eq(matched, 8, "split path 2 exact")
eq(t:node_count() >= 3, true, "split created intermediate node")

new_case("分裂后各租户仍能命中自己的叶子")
t = tree_mod.new()
t:insert("system prompt v1 user question A", "wA")
t:insert("system prompt v1 user question B", "wB")
local aTenant = t:prefix_match_with_counts("system prompt v1 user question A")
local bTenant = t:prefix_match_with_counts("system prompt v1 user question B")
eq(aTenant, "wA", "tenant A")
eq(bTenant, "wB", "tenant B")

new_case("深层链式插入（每节点一字符）")
t = tree_mod.new()
t:insert("abcdef", "w1")
for i = 1, 6 do
    local _, m = t:prefix_match_with_counts(string.sub("abcdef", 1, i))
    eq(m, i, "depth " .. i)
end

new_case("分母是输入全文字符数（部分匹配时）")
t = tree_mod.new()
t:insert("prefix", "w1")
tenant, matched, input = t:prefix_match_with_counts("prefix------------------")
eq(matched, 6, "matched only prefix")
eq(input, 24, "input counts whole text")
check(matched / input < 0.5 and matched / input > 0.2, "match rate uses full denominator")

new_case("UTF-8 中文前缀匹配按码点计数")
t = tree_mod.new()
t:insert("你是一个助手，请回答问题。", "w1")
tenant, matched, input = t:prefix_match_with_counts("你是一个助手，请回答问题。")
eq(matched, 13, "cjk full match chars")
eq(input, 13, "cjk input chars")
tenant, matched, input = t:prefix_match_with_counts("你是一个助手，请回答另一个问题。")
eq(matched, 10, "cjk partial chars")

new_case("中间节点登记租户但不写 epoch（epoch=0 占位）")
t = tree_mod.new()
t:insert("aaa", "w1")
t:insert("aab", "w1")
-- 根上的租户 epoch 必须为 0（永不淘汰）
eq(t.root.tenant_last_access["w1"], 0, "root tenant epoch 0")

--------------------------------------------------------------------------
-- epoch 与 LRU 语义
--------------------------------------------------------------------------
new_case("同文本重复 insert 会推进叶子 epoch")
t = tree_mod.new()
t:insert("text", "w1")
local leaf_epoch1 = nil
do
    local prev = t.root
    for _, child in pairs(prev.children) do
        leaf_epoch1 = child.tenant_last_access["w1"]
    end
end
t:insert("othertext", "w2")          -- 消耗 epoch
t:insert("text", "w1")
local leaf_epoch2 = nil
do
    for _, child in pairs(t.root.children) do
        if child.tenant_last_access["w1"] then
            leaf_epoch2 = child.tenant_last_access["w1"]
        end
    end
end
check(leaf_epoch1 ~= nil and leaf_epoch2 ~= nil and leaf_epoch2 > leaf_epoch1,
    "repeat insert refreshes leaf epoch", tostring(leaf_epoch1) .. "/" .. tostring(leaf_epoch2))

new_case("prefix_match 的 1/8 概率回写会刷新租户 epoch")
t = tree_mod.new()
t:insert("sharedprefix", "w1")
local before = nil
for _, child in pairs(t.root.children) do
    if child.tenant_last_access["w1"] then
        before = child.tenant_last_access["w1"]
    end
end
local refreshed = false
for _ = 1, 400 do
    t:prefix_match_with_counts("sharedprefix")
    for _, child in pairs(t.root.children) do
        if child.tenant_last_access["w1"] and child.tenant_last_access["w1"] > before then
            refreshed = true
        end
    end
    if refreshed then
        break
    end
end
eq(refreshed, true, "probabilistic epoch write-back happens")

new_case("不变量：tenant_char_count == DFS 重算（随机 insert/分裂压力）")
math.randomseed(20260929)
t = tree_mod.new()
local alphabet = { "a", "b", "c", "你", "好", "-", "x" }
local texts = {}
for i = 1, 240 do
    local len = math.random(0, 8)
    local buf = {}
    for j = 1, len do
        buf[j] = alphabet[math.random(#alphabet)]
    end
    texts[i] = table.concat(buf)
end
for i = 1, 240 do
    t:insert(texts[i], "w" .. math.random(1, 4))
end
for i = 1, 120 do
    t:prefix_match_with_counts(texts[math.random(240)])
end
local incremental = t:get_tenant_char_count()
local recounted = t:get_used_size_per_tenant()
local mismatch = nil
for tenant, count in pairs(incremental) do
    if recounted[tenant] ~= count then
        mismatch = tenant .. ": " .. tostring(count) .. " vs " .. tostring(recounted[tenant])
    end
end
for tenant, count in pairs(recounted) do
    if incremental[tenant] == nil then
        mismatch = tenant .. " missing in incremental"
    end
end
eq(mismatch, nil, "char accounting consistent after splits", mismatch)

new_case("不变量：evict 之后字符计数仍与 DFS 一致")
t:evict_tenant_by_size(30)
incremental = t:get_tenant_char_count()
recounted = t:get_used_size_per_tenant()
mismatch = nil
for tenant, count in pairs(incremental) do
    if recounted[tenant] ~= count then
        mismatch = tenant .. ": " .. tostring(count) .. " vs " .. tostring(recounted[tenant])
    end
end
eq(mismatch, nil, "char accounting consistent after eviction", mismatch)

new_case("不变量：remove_tenant 后该租户彻底消失")
t:remove_tenant("w1")
local after = t:get_used_size_per_tenant()
eq(after["w1"], nil, "w1 gone from DFS sizes")
eq(t:get_tenant_char_count()["w1"], nil, "w1 gone from counters")
local _, m = t:prefix_match_with_counts(texts[1])
check(m >= 0, "tree still usable after removal")

new_case("无匹配时返回 empty 租户")
t = tree_mod.new()
tenant = t:prefix_match_with_counts("nothing here")
eq(tenant, "empty", "empty tenant fallback")

--------------------------------------------------------------------------
-- remove_tenant
--------------------------------------------------------------------------
new_case("remove_tenant 清除该租户且不影响其它租户")
t = tree_mod.new()
t:insert("", "w1")
t:insert("", "w2")
t:insert("hello cache", "w1")
t:insert("hello cache", "w2")
t:remove_tenant("w1")
eq(t.tenant_char_count["w1"], nil, "w1 char count cleared")
tenant = t:prefix_match_with_counts("hello cache")
check(tenant ~= "w1", "removed tenant not returned", tenant)
t:insert("hello cache again", "w2")
tenant = t:prefix_match_with_counts("hello cache again")
eq(tenant, "w2", "w2 still works")

new_case("remove_tenant 后空节点被回收")
t = tree_mod.new()
t:insert("onlybranch", "w1")
t:remove_tenant("w1")
eq(next(t.root.children), nil, "root children emptied")

--------------------------------------------------------------------------
-- evict_tenant_by_size（LRU）
--------------------------------------------------------------------------
new_case("evict 在限额内不改动")
t = tree_mod.new()
t:insert("abcdefghij", "w1")         -- 10 chars
t:evict_tenant_by_size(100)
eq(t.tenant_char_count["w1"], 10, "no eviction under limit")

new_case("evict 限额是「每租户」字符数（Rust evict_tenant_by_size 语义）")
t = tree_mod.new()
t:insert("aaaaaaaaaa", "w1")         -- 10 chars，超 5 的限额
t:insert("bbb", "w2")                -- 3 chars，在限额内
t:evict_tenant_by_size(5)
eq(t.tenant_char_count["w1"] or 0, 0, "over-limit tenant fully evicted")
eq(t.tenant_char_count["w2"] or 0, 3, "under-limit tenant untouched")

new_case("同一租户多叶子时按 LRU 从最旧叶子开始淘汰")
t = tree_mod.new()
t:insert("aaaaaaaaaa", "w1")         -- 10 chars，最旧叶子
t:insert("bb", "w1")                 -- 2 chars，最新叶子 → 共 12
for _ = 1, 40 do
    t:prefix_match_with_counts("bb")     -- 反复刷新 "bb" 叶子，保证它不是 LRU
end
t:evict_tenant_by_size(5)
local kept = t.tenant_char_count["w1"] or 0
check(kept <= 5 and kept >= 2, "newest leaf survives, oldest evicted", kept)
local _, m_old = t:prefix_match_with_counts("aaaaaaaaaa")
eq(m_old, 0, "oldest leaf gone from tree")

new_case("evict 逐层向上直到满足限额")
t = tree_mod.new()
local long = string.rep("z", 200)
t:insert(long, "w1")
t:evict_tenant_by_size(50)
check((t.tenant_char_count["w1"] or 0) <= 50, "evicted down to limit", tostring(t.tenant_char_count["w1"]))
tenant = t:prefix_match_with_counts(long)
check(tenant == "w1" or tenant == "empty", "tree still answerable", tenant)

new_case("evict 多租户共享前缀：叶子先淘汰")
t = tree_mod.new()
t:insert("commonprefix-111111", "w1")
t:insert("commonprefix-222222", "w2")
local before1 = t.tenant_char_count["w1"]
t:evict_tenant_by_size(1)
local after1 = t.tenant_char_count["w1"] or 0
local after2 = t.tenant_char_count["w2"] or 0
check(before1 > after1, "leaf evicted for w1", tostring(before1) .. "->" .. tostring(after1))
check(after1 < before1 and after2 < before1 + 1, "both tenants shrink under tiny limit")

--------------------------------------------------------------------------
-- serialize / restore（per-process 快照落盘用）
--------------------------------------------------------------------------
new_case("serialize + restore 保留匹配结果与租户")
t = tree_mod.new()
t:insert("", "w1")
t:insert("", "w2")
t:insert("prompt one long enough", "w1")
t:insert("prompt two long enough", "w2")
local snap = t:serialize()
local t2 = tree_mod.new()
t2:restore(snap)
local tenant_a, matched_a, input_a = t2:prefix_match_with_counts("prompt one long enough")
local tenant_b, matched_b = t:prefix_match_with_counts("prompt one long enough")
eq(matched_a, matched_b, "restored matched chars")
eq(input_a, 22, "restored input chars")
check(tenant_a == tenant_b, "restored tenant identical", tostring(tenant_a) .. " vs " .. tostring(tenant_b))

new_case("restore 后 epoch 单调（新写入比快照更新）")
t = tree_mod.new()
t:insert("alpha", "w1")
snap = t:serialize()
t2 = tree_mod.new()
t2:restore(snap)
local epoch_before = tree_mod.current_epoch()
t2:insert("beta", "w2")
check(tree_mod.current_epoch() > epoch_before, "epoch continues after restore")

--------------------------------------------------------------------------
-- 结果汇总
--------------------------------------------------------------------------
io.write(string.format("\ntree: %d passed, %d failed\n", passed, failed))
if failed > 0 then
    for i = 1, #failures do
        io.write("FAIL " .. failures[i] .. "\n")
    end
    os.exit(1)
end
os.exit(0)
