#!/usr/bin/env luajit
-- utils(文本抽取) / cache_aware / bucket 单测（纯 Lua 逻辑，不依赖 ngx）。
--   运行：见文件头 test_tree.lua 同样的 resty/luajit 命令行。
local root = os.getenv("LUA_TEST_LIB") or "./lualib"
package.path = root .. "/?.lua;" .. root .. "/resty/luarouter/policies/?.lua;" .. package.path

local utils = require "resty.luarouter.policies.utils"
local cache_aware = require "resty.luarouter.policies.cache_aware"
local bucket_mod = require "resty.luarouter.policies.bucket"

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
-- worker 测试替身
--------------------------------------------------------------------------
local function worker(url, opts)
    opts = opts or {}
    return {
        url = url,
        load = opts.load or 0,
        healthy = (opts.healthy == nil) and true or opts.healthy,
        model_id = opts.model_id or "m1",
        pool = opts.pool or "regular",
    }
end

--- 恒定随机源：总是取第 pick 个（并列随机路径可复现）
local function rng_at(pick)
    return function(n)
        if pick > n then
            return n
        end
        return pick
    end
end

--------------------------------------------------------------------------
-- extract_text_for_routing
--------------------------------------------------------------------------
new_case("chat: 单消息 system/user 拼接（单空格）")
eq(utils.extract_text_for_routing({ messages = { { role = "system", content = "sys" } } }),
    "sys", "single system")
eq(utils.extract_text_for_routing({ messages = {
    { role = "system", content = "sys" },
    { role = "user", content = "hi" },
} }), "sys hi", "system + user joined by one space")

new_case("chat: 各角色取用规则")
local body = { messages = {
    { role = "developer", content = "dev" },
    { role = "user", content = "u1" },
    { role = "tool", content = "toolout" },
    { role = "function", content = "funcout" },
} }
eq(utils.extract_text_for_routing(body), "dev u1 toolout funcout", "developer/tool/function 都取 content")

eq(utils.extract_text_for_routing({ messages = {
    { role = "user", content = "q" },
    { role = "assistant", content = "a" },
} }), "q a", "assistant content 参与拼接")

eq(utils.extract_text_for_routing({ messages = {
    { role = "assistant", reasoning_content = "think" },
} }), "think", "assistant 只有 reasoning_content")

eq(utils.extract_text_for_routing({ messages = {
    { role = "assistant", content = "a", reasoning_content = "think" },
} }), "a think", "assistant content + reasoning_content")

eq(utils.extract_text_for_routing({ messages = {
    { role = "user", content = "q" },
    { role = "assistant", reasoning_content = "" },
} }), "q", "空 reasoning_content 不产生分隔符")

new_case("chat: content 数组只拼 type=text 的 text 片段")
eq(utils.extract_text_for_routing({ messages = {
    { role = "user", content = {
        { type = "text", text = "part1" },
        { type = "image_url", image_url = { url = "http://x" } },
        { type = "text", text = "part2" },
    } },
} }), "part1 part2", "parts 拼接跳过非文本")

eq(utils.extract_text_for_routing({ messages = {
    { role = "user", content = { { type = "text", text = "" }, { type = "text", text = "b" } } },
} }), "b", "空 text 片段被跳过")

new_case("chat: 无文本 → nil（不是空串）")
eq(utils.extract_text_for_routing({ messages = { { role = "user", content = "" } } }), nil, "empty content")
eq(utils.extract_text_for_routing({ messages = {} }), nil, "no messages")
eq(utils.extract_text_for_routing({ messages = { { role = "user", content = { { type = "image_url" } } } } }),
    nil, "only image")
eq(utils.extract_text_for_routing({}), nil, "no messages field")
eq(utils.extract_text_for_routing(nil), nil, "nil body")
eq(utils.extract_text_for_routing({ messages = { { role = "unknown_role", content = "x" } } }), nil, "unknown role ignored")

new_case("chat: 多轮长对话保序（回归 sgl-project/sglang#26263）")
local text = utils.extract_text_for_routing({ messages = {
    { role = "system", content = "You are a helpful assistant." },
    { role = "user", content = "First question about apples." },
    { role = "assistant", content = "Apples are red." },
    { role = "user", content = "Follow up about oranges." },
} })
check(text:find("apples", 1, true) ~= nil, "含早期轮次")
check(text:find("oranges", 1, true) ~= nil, "含最新轮次")
eq(text, "You are a helpful assistant. First question about apples. Apples are red. Follow up about oranges.",
    "全量保序拼接")

new_case("completions: prompt 数组单空格 join")
eq(utils.extract_text_for_routing({ prompt = { "a", "b", "c" } }), "a b c", "prompt array join")
eq(utils.extract_text_for_routing({ prompt = "single" }), "single", "prompt string")
eq(utils.extract_text_for_routing({ prompt = {} }), nil, "empty prompt array")
eq(utils.extract_text_for_routing({ prompt = "" }), nil, "empty prompt string")

new_case("worker 访问器兼容字段与方法两种形态")
local method_worker = {
    _url = "http://w9",
    url = function(self) return self._url end,
    load = function() return 7 end,
    is_healthy = function() return true end,
}
eq(utils.worker_url(method_worker), "http://w9", "method url")
eq(utils.worker_load(method_worker), 7, "method load")
eq(utils.worker_healthy(method_worker), true, "method is_healthy")
eq(utils.worker_load(worker("http://a")), 0, "default load 0")
local blocked = worker("http://b")
blocked.circuit_breaker = { can_execute = false }
eq(utils.worker_can_execute(blocked), false, "circuit breaker blocks")
local cb_open = worker("http://c")
cb_open.circuit_breaker = { can_execute = function() return true end }
eq(utils.worker_can_execute(cb_open), true, "circuit breaker method form")

--------------------------------------------------------------------------
-- cache_aware：各选择分支
--------------------------------------------------------------------------
new_case("cache_aware: 无健康 worker → nil")
local p = cache_aware.new({}, rng_at(1))
local ws = { worker("http://w1", { healthy = false }) }
eq(p:select_worker(ws, {}), nil, "all unhealthy")
eq(p:select_worker({}, {}), nil, "empty workers")

new_case("cache_aware: 树未播种 → 随机健康 worker")
p = cache_aware.new({}, rng_at(2))
ws = { worker("http://w1"), worker("http://w2"), worker("http://w3") }
eq(p:select_worker(ws, { request_text = "hello" }), 2, "no tree → rng pick")

new_case("cache_aware: worker 注册写入树（insert 空文本）")
p = cache_aware.new({}, rng_at(1))
ws = { worker("http://w1"), worker("http://w2") }
p:init_workers(ws)
local key = cache_aware.make_tree_key("regular", "m1")
local counts = p:tenant_char_count(key)
eq(counts["http://w1"] ~= nil, true, "w1 registered in tree")
eq(counts["http://w2"] ~= nil, true, "w2 registered in tree")

new_case("cache_aware: 匹配率 > 阈值 → 命中缓存租户（即使它负载更高）")
p = cache_aware.new({ cache_threshold = 0.5 }, rng_at(1))
ws = { worker("http://w1"), worker("http://w2", { load = 5 }) }
p:init_workers(ws)
p:select_worker(ws, { request_text = "long shared prefix content here" })
local idx = p:select_worker(ws, { request_text = "long shared prefix content here" })
eq(ws[idx].url, "http://w1", "cache hit keeps same worker")

new_case("cache_aware: 匹配率 ≤ 阈值 → min load（并列随机）")
p = cache_aware.new({ cache_threshold = 0.5 }, rng_at(1))
ws = { worker("http://w1", { load = 3 }), worker("http://w2", { load = 1 }) }
p:init_workers(ws)
idx = p:select_worker(ws, { request_text = "totally different text" })
eq(ws[idx].url, "http://w2", "low match → min load")

new_case("cache_aware: 并列 min load 由 rng 决定")
for pick = 1, 3 do
    p = cache_aware.new({ cache_threshold = 0.5 }, rng_at(pick))
    ws = { worker("http://w1"), worker("http://w2"), worker("http://w3") }
    p:init_workers(ws)
    idx = p:select_worker(ws, { request_text = "brand new unmatched prompt" })
    eq(idx, pick, "tie broken by rng at " .. pick)
end

new_case("cache_aware: 失衡（abs 且 rel 双阈值）→ 最短队列，且不健康 worker 不参与")
p = cache_aware.new({ balance_abs_threshold = 32, balance_rel_threshold = 1.1 }, rng_at(1))
ws = {
    worker("http://w1", { load = 100 }),
    worker("http://w2", { load = 1 }),
    worker("http://w3", { load = 1, healthy = false }),
}
p:init_workers(ws)
idx = p:select_worker(ws, { request_text = "anything" })
eq(ws[idx].url, "http://w2", "imbalanced → min load healthy only")

new_case("cache_aware: 失衡判定需要 abs 与 rel 同时成立")
-- (max-min)=40 > 32，但 40 > 32*1.1 = 35.2 也成立 → 失衡
p = cache_aware.new({ balance_abs_threshold = 32, balance_rel_threshold = 1.1 }, rng_at(1))
ws = { worker("http://w1", { load = 40 }), worker("http://w2", { load = 0 }) }
p:init_workers(ws)
idx = p:select_worker(ws, { request_text = "x" })
eq(ws[idx].url, "http://w2", "rel satisfied → imbalance")

-- abs 不成立：差 30 ≤ 32 → 走 cache 路径
p = cache_aware.new({ balance_abs_threshold = 32, cache_threshold = 0.99 }, rng_at(1))
ws = { worker("http://w1", { load = 30 }), worker("http://w2", { load = 0 }) }
p:init_workers(ws)
idx = p:select_worker(ws, { request_text = "y" })
eq(ws[idx].url, "http://w2", "abs not satisfied → balanced min-load path")

-- rel 不成立：diff=40 > 32 但 440 > 400*1.1=440 为假 → 判定均衡 → 走 cache 亲和
p = cache_aware.new({ balance_abs_threshold = 32, balance_rel_threshold = 1.1,
                     cache_threshold = 0.5 }, rng_at(1))
ws = { worker("http://w1", { load = 440 }), worker("http://w2", { load = 400 }) }
p:init_workers(ws)
local tree = p:get_or_create_tree(cache_aware.make_tree_key("regular", "m1"))
tree:insert("affine prompt prefix", "http://w1")     -- 预置 w1 的亲和
idx = p:select_worker(ws, { request_text = "affine prompt prefix" })
eq(ws[idx].url, "http://w1", "rel not satisfied → cache affinity wins over load gap")

new_case("cache_aware: 失衡分支同样写树（后续能命中该 worker）")
p = cache_aware.new({ balance_abs_threshold = 1, balance_rel_threshold = 1.0001 }, rng_at(1))
ws = { worker("http://w1", { load = 10 }), worker("http://w2", { load = 0 }) }
p:init_workers(ws)
idx = p:select_worker(ws, { request_text = "imbalance text write" })
eq(ws[idx].url, "http://w2", "imbalance → min load")
-- 负载拉平后走 cache 路径，应命中刚才写树的 w2
ws[1].load = 0
p.config.balance_abs_threshold = 32
idx = p:select_worker(ws, { request_text = "imbalance text write" })
eq(ws[idx].url, "http://w2", "tree written during imbalance")

new_case("cache_aware: 缓存租户不健康 → remove_tenant 后取首个健康 worker")
p = cache_aware.new({ cache_threshold = 0.5 }, rng_at(1))
ws = { worker("http://w1"), worker("http://w2") }
p:init_workers(ws)
p:select_worker(ws, { request_text = "affinity prompt long" })   -- 写 w1
ws[1].healthy = false
idx = p:select_worker(ws, { request_text = "affinity prompt long" })
eq(idx, 2, "fallback to first healthy")
local healthy_workers = { worker("http://w2") }
local p2 = cache_aware.new({}, rng_at(1))
p2.trees = p.trees
local counts2 = p2:tenant_char_count(cache_aware.make_tree_key("regular", "m1"))
check(counts2["http://w1"] == nil or counts2["http://w1"] == 0,
    "stale tenant removed from tree", tostring(counts2["http://w1"]))

new_case("cache_aware: 同 URL 重复 worker 且首个不健康 → 按脏租户清理（对齐 Rust position+filter）")
p = cache_aware.new({ cache_threshold = 0.5 }, rng_at(1))
ws = { worker("http://w1"), worker("http://w1", { healthy = false }), worker("http://w2") }
local tree = p:get_or_create_tree(cache_aware.make_tree_key("regular", "m1"))
tree:insert("dup url prompt", "http://w1")
idx = p:select_worker(ws, { request_text = "dup url prompt" })
-- 首个 w1 健康 → 命中；把首个置为不健康后应退化到 healthy[1]
eq(ws[idx].url, "http://w1", "healthy duplicate still used")
ws[1].healthy = false
idx = p:select_worker(ws, { request_text = "dup url prompt" })
check(idx == 3 and ws[3].url == "http://w2", "unhealthy first match treated as stale", ws[idx].url)

new_case("cache_aware: 空 request_text 时 match_rate=0 → 走 min load")
p = cache_aware.new({ cache_threshold = 0.5 }, rng_at(1))
ws = { worker("http://w1", { load = 2 }), worker("http://w2", { load = 0 }) }
p:init_workers(ws)
idx = p:select_worker(ws, {})
eq(ws[idx].url, "http://w2", "no text → min load")

new_case("cache_aware: 树按 (pool, model) 隔离")
p = cache_aware.new({ cache_threshold = 0.5 }, rng_at(1))
ws = { worker("http://r1", { model_id = "mA" }), worker("http://r2", { model_id = "mB" }) }
p:init_workers(ws)
p:select_worker({ ws[1] }, { request_text = "model A prompt here" })
p:select_worker({ ws[2] }, { request_text = "model A prompt here" })
local mA_tree = p.trees[cache_aware.make_tree_key("regular", "mA")]
local mB_tree = p.trees[cache_aware.make_tree_key("regular", "mB")]
eq(mA_tree:prefix_match_with_counts("model A prompt here"), "http://r1", "mA 树只记 r1 亲和")
eq(mB_tree:prefix_match_with_counts("model A prompt here"), "http://r2", "mB 树只记 r2 亲和")
eq(cache_aware.make_tree_key("prefill", "mA"), "prefill::mA", "tree key format")

new_case("cache_aware: 空 model 归一化为 unknown")
eq(utils.normalize_model_key(""), "unknown", "empty model → unknown")
eq(cache_aware.make_tree_key("regular", ""), "regular::unknown", "tree key uses unknown")

new_case("cache_aware: remove_worker_by_url 清所有树")
p = cache_aware.new({}, rng_at(1))
ws = { worker("http://w1", { model_id = "mA" }), worker("http://w1", { model_id = "mB" }) }
p:init_workers(ws)
p:remove_worker_by_url("http://w1")
eq(p:tenant_char_count(cache_aware.make_tree_key("regular", "mA"))["http://w1"], nil, "mA tenant gone")
eq(p:tenant_char_count(cache_aware.make_tree_key("regular", "mB"))["http://w1"], nil, "mB tenant gone")

new_case("cache_aware: 快照 serialize/restore 保住的亲和")
p = cache_aware.new({ cache_threshold = 0.5 }, rng_at(1))
ws = { worker("http://w1"), worker("http://w2") }
p:init_workers(ws)
p:select_worker(ws, { request_text = "persisted affinity prompt" })
local snap = p:serialize()
local p2 = cache_aware.new({ cache_threshold = 0.5 }, rng_at(1))
p2:restore(snap)
idx = p2:select_worker(ws, { request_text = "persisted affinity prompt" })
eq(ws[idx].url, "http://w1", "restored tree keeps affinity")

new_case("cache_aware: evict_all 收缩超限树")
p = cache_aware.new({}, rng_at(1))
ws = { worker("http://w1") }
p:init_workers(ws)
p:select_worker(ws, { request_text = string.rep("x", 300) })
p:evict_all(50)
local cnt = p:tenant_char_count(cache_aware.make_tree_key("regular", "m1"))["http://w1"] or 0
check(cnt <= 50, "evict_all caps tenant size", cnt)

new_case("cache_aware: needs_request_text / name")
p = cache_aware.new()
eq(p:name(), "cache_aware", "name")
eq(p:needs_request_text(), true, "needs text")

--------------------------------------------------------------------------
-- bucket：边界与选择
--------------------------------------------------------------------------
new_case("bucket: 边界按 l_max=4096 均分，末桶上界 inf")
local b = bucket_mod.new_bucket(5000)
b:init_worker_urls({ "http://w1", "http://w2" })
eq(b.boundary[1].range[1], 0, "first bucket min 0")
eq(b.boundary[1].range[2], 4096 / 2 - 1, "first bucket max gap-1")
eq(b.boundary[2].range[1], 2048, "second bucket min 2048")
eq(b.boundary[2].range[2] == utils.INF_BOUND, true, "last bucket inf")
eq(b:find_boundary(0), "http://w1", "char 0 → first")
eq(b:find_boundary(2047), "http://w1", "2047 → first")
eq(b:find_boundary(2048), "http://w2", "2048 → second")
eq(b:find_boundary(10 ^ 12), "http://w2", "huge → last")

new_case("bucket: 3 worker 均分（整数除法，末桶吃余数）")
b = bucket_mod.new_bucket(5000)
b:init_worker_urls({ "http://w1", "http://w2", "http://w3" })
local gap = math.floor(4096 / 3)
eq(b.boundary[1].range[2], gap - 1, "b1 max")
eq(b.boundary[3].range[1], 2 * gap, "b3 min")
eq(b:find_boundary(gap - 1), "http://w1", "boundary lower edge")
eq(b:find_boundary(gap), "http://w2", "just above → b2")
eq(b:find_boundary(0), "http://w1", "zero")

new_case("bucket: 空 worker 列表 / 二分找不到时返回 nil")
b = bucket_mod.new_bucket(1000)
b:init_worker_urls({})
eq(b:find_boundary(10), nil, "no boundary → nil")
eq(next(b.boundary) == nil, true, "empty boundary table")

new_case("bucket: 滑动窗口按时间衰减 chars_per_url（注入时钟）")
local now = 1000
b = bucket_mod.new_bucket(5000)
b:set_clock(function() return now end)
b:init_worker_urls({ "http://w1", "http://w2" })
b:post_process_request(100, "http://w1")
eq(b.chars_per_url["http://w1"], 100, "load added")
eq(b.load_total, 100, "total load tracked")
b:post_process_request(50, "http://w2")     -- 窗口内：两条都算
eq(b.chars_per_url["http://w1"], 100, "in-window load kept")
eq(b.chars_per_url["http://w2"], 50, "w2 load present")
eq(b.load_total, 150, "in-window total")
now = 7000                                   -- 越过 5000ms 窗口 → 前两条过期
b:post_process_request(10, "http://w1")
eq(b.chars_per_url["http://w1"], 10, "expired decay removes old w1 load")
eq(b.chars_per_url["http://w2"], 0, "expired decay removes w2 load")
eq(b.load_total, 10, "total decayed")

new_case("bucket: select 命中对应桶")
local pol = bucket_mod.new({}, rng_at(1))
ws = { worker("http://w1"), worker("http://w2") }
pol:init_worker_urls(ws)
idx = pol:select_worker(ws, { request_text = "short" })
eq(ws[idx].url, "http://w1", "short text → bucket 1")
idx = pol:select_worker(ws, { request_text = string.rep("a", 3000) })
eq(ws[idx].url, "http://w2", "long text → bucket 2")

new_case("bucket: 无 request_text 视为 0 字符")
pol = bucket_mod.new({}, rng_at(1))
ws = { worker("http://w1"), worker("http://w2") }
pol:init_worker_urls(ws)
idx = pol:select_worker(ws, {})
eq(ws[idx].url, "http://w1", "nil text → 0 chars")

new_case("bucket: UTF-8 中文按码点分桶")
pol = bucket_mod.new({}, rng_at(1))
ws = { worker("http://w1"), worker("http://w2") }
pol:init_worker_urls(ws)
idx = pol:select_worker(ws, { request_text = string.rep("中", 3000) })
eq(ws[idx].url, "http://w2", "3000 汉字 > 2048 → bucket 2（按码点而非字节）")

new_case("bucket: 失衡（chars_per_url abs+rel）→ 选 chars 最小 worker")
pol = bucket_mod.new({ balance_abs_threshold = 32, balance_rel_threshold = 1.0001 }, rng_at(1))
b = pol:get_bucket("m1", true)
b:init_worker_urls({ "http://w1", "http://w2", "http://w3" })
b.chars_per_url["http://w1"] = 500
b.chars_per_url["http://w2"] = 10
b.chars_per_url["http://w3"] = 20
ws = { worker("http://w1"), worker("http://w2"), worker("http://w3") }
idx = pol:select_worker(ws, { request_text = "small" })   -- 本该落桶1(w1)，失衡后改选 w2
eq(ws[idx].url, "http://w2", "imbalanced → min chars")

new_case("bucket: 桶缺失 → 随机健康 worker")
pol = bucket_mod.new({}, rng_at(2))
ws = { worker("http://w1"), worker("http://w2") }   -- 故意不调 init_worker_urls
idx = pol:select_worker(ws, { request_text = "anything" })
eq(idx, 2, "no bucket state → rng")

new_case("bucket: 全不健康 → nil")
pol = bucket_mod.new({}, rng_at(1))
ws = { worker("http://w1", { healthy = false }) }
pol:init_worker_urls(ws)
eq(pol:select_worker(ws, { request_text = "x" }), nil, "no healthy")

new_case("bucket: add_worker / remove_worker 重建边界")
pol = bucket_mod.new({}, rng_at(1))
ws = { worker("http://w1") }
pol:init_worker_urls(ws)
b = pol.buckets["m1"]
eq(b.boundary[1].range[2] == utils.INF_BOUND, true, "single worker owns whole range")
pol:add_worker(worker("http://w2"))
eq(b.bucket_cnt, 2, "worker added")
eq(b.chars_per_url["http://w2"], 0, "new worker zeroed")
pol:remove_worker(worker("http://w1"))
eq(b.bucket_cnt, 1, "worker removed")
eq(b.chars_per_url["http://w1"], nil, "removed worker dropped from chars map")

new_case("bucket: adjust_boundary 首次建立负载分层，二次调用迟滞不动")
pol = bucket_mod.new({ bucket_adjust_interval_secs = 1 }, rng_at(1))
ws = { worker("http://w1"), worker("http://w2") }
pol:init_worker_urls(ws)
b = pol.buckets["m1"]
pol:select_worker(ws, { request_text = string.rep("a", 10) })
pol:select_worker(ws, { request_text = string.rep("a", 4000) })
local before = { b.boundary[1].range[1], b.boundary[1].range[2] }
b:adjust_boundary()
check(b.bucket_load > 0, "bucket_load computed", b.bucket_load)
local after = { b.boundary[1].range[1], b.boundary[1].range[2] }
eq(after[1], before[1], "lower bound stays 0")
check(after[2] ~= 2047, "boundary re-tiered by load", after[2])
b:adjust_boundary()
eq(b.boundary[1].range[2], after[2], "second call is a no-op (2x hysteresis)")

new_case("bucket: 全 worker 数>1 时任意 char_count 都能命中某桶")
b = bucket_mod.new_bucket(1000)
b:init_worker_urls({ "http://w1", "http://w2", "http://w3" })
local ok_all = true
local probes = { 0, 1, 1365, 1366, 2730, 2731, 4095, 4096, 100000 }
for i = 1, #probes do
    if b:find_boundary(probes[i]) == nil then
        ok_all = false
    end
end
eq(ok_all, true, "every probe maps to a bucket")

new_case("cjson 解码后的真实请求体：null 字段不炸")
local cjson_ok, cjson = pcall(require, "cjson")
if cjson_ok then
    local raw = [[{"model":"m","messages":[{"role":"assistant","content":null,"reasoning_content":"deep thought"},{"role":"user","content":[{"type":"text","text":"hello"}],"name":null}]}]]
    local decoded = cjson.decode(raw)
    eq(utils.extract_text_for_routing(decoded), "deep thought hello", "null content 跳过 + reasoning 保留")

    decoded = cjson.decode([[{"model":"m","messages":[{"role":"user","content":[]}]}]])
    eq(utils.extract_text_for_routing(decoded), nil, "空 parts → nil")

    decoded = cjson.decode([[{"model":"m","messages":[{"role":"user","content":""}],"stream":true}]])
    eq(utils.extract_text_for_routing(decoded), nil, "空串 content → nil")
else
    check(true, "cjson 不可用时跳过")
end

new_case("cache_aware / bucket: env 字符串配置被转成数值")
p = cache_aware.new({ cache_threshold = "0.8", max_tree_size = "123", eviction_interval_secs = "7" }, rng_at(1))
eq(p.config.cache_threshold, 0.8, "cache_threshold coerced")
eq(p.config.max_tree_size, 123, "max_tree_size coerced")
eq(p.config.eviction_interval_secs, 7, "eviction_interval_secs coerced")
local bp = bucket_mod.new({ balance_abs_threshold = "16" }, rng_at(1))
eq(bp.config.balance_abs_threshold, 16, "bucket abs threshold coerced")

new_case("cache_aware: 快照 JSON 编解码保住亲和（含中文 prompt）")
p = cache_aware.new({ cache_threshold = 0.5 }, rng_at(1))
ws = { worker("http://w1"), worker("http://w2") }
p:init_workers(ws)
p:select_worker(ws, { request_text = "持久化亲和提示词内容" })
local json_text = p:encode_snapshot()
check(type(json_text) == "string" and #json_text > 0, "snapshot encodes to json", json_text)
local p3 = cache_aware.new({ cache_threshold = 0.5 }, rng_at(1))
eq(p3:decode_snapshot(json_text), true, "decode snapshot ok")
idx = p3:select_worker(ws, { request_text = "持久化亲和提示词内容" })
eq(ws[idx].url, "http://w1", "json-restored tree keeps affinity")
eq(p3:encode_snapshot(5), nil, "oversize snapshot refused")
eq(p3:decode_snapshot(nil), false, "decode nil → false")
eq(p3:decode_snapshot("not json"), false, "decode garbage → false")

new_case("worker 视图：框架的 models 数组形态取首个模型")
eq(utils.worker_model_id({ url = "http://w", models = { "deepseek-v4" } }), "deepseek-v4", "models[1] string")
eq(utils.worker_model_id({ url = "http://w", models = { { id = "glm-5" } } }), "glm-5", "models[1].id")
eq(utils.worker_model_id({ url = "http://w" }), "unknown", "no models → unknown")

new_case("bucket: name / needs_request_text")
pol = bucket_mod.new()
eq(pol:name(), "bucket", "name")
eq(pol:needs_request_text(), true, "needs text")

--------------------------------------------------------------------------
io.write(string.format("\npolicies: %d passed, %d failed\n", passed, failed))
if failed > 0 then
    for i = 1, #failures do
        io.write("FAIL " .. failures[i] .. "\n")
    end
    os.exit(1)
end
os.exit(0)
