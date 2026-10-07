#!/usr/bin/env luajit
-- observability 的键基数与扫描预算单测（doc/gap-cpu-idle-burn.md S3，分支 fix/cpu-idle-burn）。
--   运行：docker run --rm -e LUA_TEST_LIB=/repo/lualib -v "$PWD:/repo:ro" \
--          --entrypoint /usr/local/openresty/luajit/bin/luajit authz:latest \
--          /repo/test/unit/test_observability.lua
--
-- 钉的是 8801/8802 的第三个无界容器：lr_stats 的 c|/h|/g| 行全仓没有任何 delete
-- （唯一的 :delete( 在 logstore 与 inflight 自己的键上），而 model 标签的取值空间由
-- **客户端**决定。所以一次「客户端乱填 model」的污染，长度由客户端决定，且永久留在
-- /metrics 与每一趟 gauge 扫描的成本里（8801 污染实验实测：10132 个 distinct model →
-- /metrics 3.2 MB / 20419 行）。这里验三件事：
--   1. model 标签撞上限后新名字并进同一个 other= 行（键数不再随客户端输入增长）；
--   2. 上限可关（LR_MODEL_LABEL_CAP=0 回到原名照落的旧行为）、可调；
--   3. /metrics 的导出扫描是**有界**的，且被截断时会发一条可见的指标而不是悄悄变少。
--
-- 与 test_gpu_load.lua 同形状：造一个最小的 _G.ngx（lr_stats 一张表），其余走真模块
-- —— 要验的就是线上那份键文法本身。
package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath
package.path = (os.getenv("LUA_TEST_LIB") or "./lualib") .. "/?.lua;" .. package.path

--------------------------------------------------------------------------
-- 假共享字典（get_keys(n) 的截断语义与 ngx.shared 一致：n>0 时最多返回 n 条）
--------------------------------------------------------------------------
local function new_dict()
    local store = {}
    local d = {}
    function d:get(k) return store[k] end
    function d:set(k, v) store[k] = v; return true end
    function d:incr(k, delta, init)
        local cur = tonumber(store[k]) or init or 0
        cur = cur + delta
        store[k] = cur
        return cur
    end
    function d:delete(k) store[k] = nil end
    function d:get_keys(n)
        local out = {}
        for k in pairs(store) do out[#out + 1] = k end
        table.sort(out)
        if n and n > 0 and #out > n then
            for i = n + 1, #out do out[i] = nil end
        end
        return out
    end
    function d:_keys() return store end
    return d
end

local stats = new_dict()
_G.ngx = {
    shared = { lr_stats = stats, lr_request_log = new_dict(), lr_policy = new_dict() },
    log = function() end,
    now = function() return 1000 end,
    WARN = 1, ERR = 2, INFO = 3, NOTICE = 4,
    ctx = {},
    var = {},
}

-- prometheus_text 会顺手从 registry 派生逐 worker 的 gauge；给一张空池就够，
-- 本文件不测那一段（它由 e2e / contract 门禁覆盖）。
package.loaded["resty.luarouter.registry"] = {
    records = function() return {} end,
}

-- cfg() 走 require("resty.luarouter").config()：桶阶梯那一段只需要一个可索引的表。
package.loaded["resty.luarouter"] = {
    config = function() return {} end,
}

local observability = require "resty.luarouter.observability"

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

---把 os.getenv 换成一张可控表 + 清掉基数登记（上限是加载期读一次的值，
---reset 是这条测试通道，线上没有调用点）。
local function with_env(t, body_fn)
    local saved = os.getenv
    os.getenv = function(name) return t[name] end
    observability.reset_model_label_cardinality()
    local ok, err = pcall(body_fn)
    os.getenv = saved
    observability.reset_model_label_cardinality()
    if not ok then error(err) end
end

local function fresh_stats()
    stats = new_dict()
    ngx.shared.lr_stats = stats
    return stats
end

---以 model=v 记一次 worker 选择（线上是 policy.lua 的 record_worker_selection）
local function select_once(v)
    observability.record_worker_selection("http://w1:1", v, "cache_aware")
end

---统计某个族在字典里占了多少行
local function rows_of(prefix)
    local n = 0
    for k in pairs(stats:_keys()) do
        if k:sub(1, #prefix) == prefix then n = n + 1 end
    end
    return n
end

--------------------------------------------------------------------------
new_case("model 标签在预算内原名照落（正常部署零行为变化）")
do
    with_env({}, function()
        fresh_stats()
        for i = 1, 10 do select_once("model-" .. i) end
        eq(observability.model_label_cardinality(), 10, "ten names registered")
        eq(rows_of("c|smg_worker_selection_total|"), 10, "ten distinct rows")
        select_once("model-1")
        eq(observability.model_label_cardinality(), 10,
            "a repeat name registers nothing new")
        eq(rows_of("c|smg_worker_selection_total|"), 10, "and costs no new row")
    end)
end

--------------------------------------------------------------------------
new_case("撞上限后新名字并进同一个 other= 行（无界 → 有界的那一步）")
do
    with_env({ LR_MODEL_LABEL_CAP = "4" }, function()
        fresh_stats()
        for i = 1, 4 do select_once("real-" .. i) end
        eq(observability.model_label_cardinality(), 4, "budget filled")
        -- 预算之后的 100 个假名字：字典只多**一行**，不是 100 行
        for i = 1, 100 do select_once("fake-" .. i) end
        eq(rows_of("c|smg_worker_selection_total|"), 5,
            "100 new names cost one row", tostring(
                rows_of("c|smg_worker_selection_total|")))
        eq(observability.model_label_cardinality(), 4, "the budget stops counting")
        -- 预算内已经出现过的名字仍可原名查（闸门不能顺手把合法维度也抹平）
        select_once("real-2")
        eq(rows_of("c|smg_worker_selection_total|"), 5,
            "a known name still hits its own row")
        local found_other = false
        for k in pairs(stats:_keys()) do
            if k:find("other", 1, true) then found_other = true end
        end
        check(found_other, "the collapsed row is labelled other")
        eq(tonumber(stats:_keys()["g|smg_model_label_cardinality|"]), 4,
            "the cardinality gauge publishes the reading")
    end)
end

--------------------------------------------------------------------------
new_case("LR_MODEL_LABEL_CAP=0 是关掉闸门的显式档位（回到旧行为）")
do
    with_env({ LR_MODEL_LABEL_CAP = "0" }, function()
        fresh_stats()
        for i = 1, 60 do select_once("free-" .. i) end
        eq(rows_of("c|smg_worker_selection_total|"), 60,
            "cap 0 stores every name verbatim")
    end)
end

--------------------------------------------------------------------------
new_case("负数上限按「关闭」处理，而不是「一个都不许存」")
do
    with_env({ LR_MODEL_LABEL_CAP = "-5" }, function()
        fresh_stats()
        for i = 1, 12 do select_once("neg-" .. i) end
        eq(rows_of("c|smg_worker_selection_total|"), 12,
            "a negative cap behaves like the off switch")
    end)
end

--------------------------------------------------------------------------
new_case("非字符串/空 model 落 unknown，且不占基数预算")
do
    with_env({ LR_MODEL_LABEL_CAP = "3" }, function()
        fresh_stats()
        select_once(nil)
        select_once("")
        select_once(42)
        eq(observability.model_label_cardinality(), 0,
            "none of them consumed the budget")
        eq(rows_of("c|smg_worker_selection_total|"), 1,
            "and they share one unknown= row",
            tostring(rows_of("c|smg_worker_selection_total|")))
        select_once("a")
        eq(observability.model_label_cardinality(), 1, "a real name does consume")
    end)
end

--------------------------------------------------------------------------
new_case("histogram / gauge 走同一道收口（闸门在 label_pairs，不在调用点）")
do
    with_env({ LR_MODEL_LABEL_CAP = "2" }, function()
        fresh_stats()
        observability.observe("t_hist", { { "model", "h1" } }, 0.01)
        observability.observe("t_hist", { { "model", "h2" } }, 0.01)
        for i = 1, 30 do
            observability.observe("t_hist", { { "model", "junk-" .. i } }, 0.01)
        end
        eq(rows_of("h|t_hist|"), 3, "30 junk names cost one row",
            tostring(rows_of("h|t_hist|")))
        -- 非 model 的标签不受影响：worker 维度由池子决定，本来就有界
        observability.gauge("t_gauge", { { "worker", "http://w1" } }, 1)
        for i = 1, 30 do
            observability.gauge("t_gauge", { { "worker", "http://w" .. i } }, 1)
        end
        -- w1 written twice + w2..w30 = 30 rows: non-model labels untouched
        eq(rows_of("g|t_gauge|"), 30,
            "labels other than model stay verbatim (pool-bounded)")
    end)
end

--------------------------------------------------------------------------
new_case("prometheus_text 的字典扫描有界，且截断可见")
do
    -- SCAN_LIMIT 是加载期读一次的值；set_metrics_scan_limit 是钉这条断言的测试通道。
    with_env({}, function()
        fresh_stats()
        observability.set_metrics_scan_limit(5)
        for i = 1, 40 do
            observability.counter("t_many", { { "model", "mm" .. i } })
        end
        local text = observability.prometheus_text()
        check(type(text) == "string" and #text > 0, "exporter still renders")
        local rendered = 0
        for line in text:gmatch("[^\n]+") do
            if line:find("t_many", 1, true) == 1 then rendered = rendered + 1 end
        end
        check(rendered > 0 and rendered <= 5, "the scan is capped", tostring(rendered))
        check(text:find("smg_dict_scan_truncated", 1, true) ~= nil,
            "truncation is published, not silent")
        check(text:find("# TYPE smg_dict_scan_truncated gauge", 1, true) ~= nil,
            "the new family carries its TYPE line")
        -- 没截断时那条必须回落到 0，否则它自己就成了新噪声
        observability.set_metrics_scan_limit(0)
        fresh_stats()
        observability.counter("t_few", { { "model", "only" } })
        local t2 = observability.prometheus_text()
        eq(t2:match("smg_dict_scan_truncated{dict=%\"lr_stats\"%}%s+([01])"), "0",
            "0 when the scan fits")
        check(t2:find("t_few", 1, true) ~= nil, "the normal family still renders")
    end)
end

--------------------------------------------------------------------------
new_case("本次新增的每条族都有 HELP 条目（否则抓取侧拿到空描述）")
do
    -- 这些 gauge 是交付项 5 的全部意义：下次不用靠 smaps_rollup 猜。导出器只在
    -- HELP[name] 登记过时才打 HELP 行，漏登记是**静默**的，所以逐条钉住。
    fresh_stats()
    observability.gauge("smg_cache_aware_tree_nodes", {}, 1234)
    observability.gauge("smg_cache_aware_tree_chars", {}, 4321)
    observability.gauge("smg_cache_aware_tree_count", {}, 2)
    observability.gauge("smg_policy_instances", {}, 7)
    observability.gauge("smg_model_label_cardinality", {}, 3)
    observability.counter("lr_watch_probe_budget_skips_total", {}, 4)
    local text = observability.prometheus_text()
    for _, name in ipairs({
        "smg_cache_aware_tree_nodes", "smg_cache_aware_tree_chars",
        "smg_cache_aware_tree_count", "smg_policy_instances",
        "smg_model_label_cardinality", "lr_watch_probe_budget_skips_total",
    }) do
        check(text:find("# HELP " .. name .. " ", 1, true) ~= nil,
            name .. " has a HELP line")
        check(text:find("# TYPE " .. name .. " ", 1, true) ~= nil,
            name .. " has a TYPE line")
    end
end

io.write("\nobservability: " .. passed .. " passed, " .. failed .. " failed\n")
if failed > 0 then
    for i = 1, #failures do io.write("  FAIL " .. failures[i] .. "\n") end
    os.exit(1)
end
os.exit(0)

