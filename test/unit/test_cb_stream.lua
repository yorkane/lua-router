#!/usr/bin/env luajit
-- 流式熔断记账与 4xx 豁免对称性单测（forward.lua 流式分支的对齐修复）。
--
-- 钉四件事：
--   1. hb.record_stream_outcome 的状态矩阵 —— 2xx 记成功；4xx（除 408/429）**不记熔断**；
--      408/429 与 5xx 记熔断；
--   2. 关键不变量：stream_ok=true 时它与 hb.record_status 对同一 status 的记账方向逐状态
--      必须相同（两条转发分支从此共用同一条 4xx 豁免口径），且熔断计数器落到的槽位也一致；
--   3. stream_ok=false（传输层断流）一律记熔断失败，与状态码无关 —— 状态行说好话不算数；
--   4. 生产症状本身：连发 12 个流式 400（坏图被 sglang 拒绝）不得把整组实例熔断开闸，
--      而 12 个流式 500 必须开闸。修复前 forward.lua 记的是 `stream_ok and status < 400`，
--      前者会攒满 cb_failure_threshold 让组内无候选，进而对所有请求（含正常）返回 503。
--
-- 与 test_gpu_load.lua / test_watcher.lua 同形状：纯 luajit、无端口。registry 与
-- observability 用 package.loaded 注入的内存 stub —— charge_cb 保留 registry.health 的
-- 「连续」计数语义（另一侧清零、返回本次 rank），flip_cb 保留 expect 复核 —— 于是
-- 「这一笔记的是成功还是失败、有没有开闸」直接读 stub 状态就能断言。真 HTTP 面上的开闸
-- 时机仍由 test_lua_router.sh 的 cb_race 段（4 进程竞态）负责，两者覆盖面不同。
--
-- 运行（与 final_gates.sh 的 run_unit_luajit 同口径）：
--   docker run --rm -v "$PWD:/repo:ro" -w /repo \
--     --entrypoint /usr/local/openresty/luajit/bin/luajit authz:latest \
--     -e LUA_TEST_LIB=/repo/lualib /repo/test/unit/test_cb_stream.lua

package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath
package.path = (os.getenv("LUA_TEST_LIB") or "./lualib") .. "/?.lua;" .. package.path

local CB_CLOSED, CB_OPEN, CB_HALF_OPEN = 0, 1, 2

--------------------------------------------------------------------------
-- 假 registry：只装熔断记账用到的那几只键，其余一概不碰
--------------------------------------------------------------------------
local pool = {}

local function worker(id)
    local w = pool[id]
    if not w then
        w = { failures = 0, successes = 0, state = CB_CLOSED, flips = 0, outcomes = {} }
        pool[id] = w
    end
    return w
end

local charged = {}   -- 每个 id 的最后一笔记账（true=成功）

package.loaded["resty.luarouter.registry"] = {
    CB_CLOSED = CB_CLOSED, CB_OPEN = CB_OPEN, CB_HALF_OPEN = CB_HALF_OPEN,
    url_for = function(id) return "http://" .. id .. ":8000" end,
    charge_cb = function(id, success)
        local w = worker(id)
        w.outcomes[#w.outcomes + 1] = success
        charged[id] = success
        if success then
            w.failures = 0
            w.successes = w.successes + 1
            return 0, w.successes
        end
        w.successes = 0
        w.failures = w.failures + 1
        return w.failures, 0
    end,
    cb_state = function(id) return { state = worker(id).state } end,
    flip_cb = function(id, expect, next_state)
        local w = worker(id)
        if w.state ~= expect then return false end
        w.state = next_state
        w.flips = w.flips + 1
        if next_state == CB_CLOSED then
            w.failures, w.successes = 0, 0
        end
        return true
    end,
}

local transitions = {}
package.loaded["resty.luarouter.observability"] = {
    log = function() end,
    log_debug = function() end,
    record_cb_outcome = function() end,
    record_cb_transition = function(url, from, to)
        transitions[#transitions + 1] = from .. "->" .. to
    end,
}

local conf = {
    disable_circuit_breaker = false,
    -- 与生产缺省同量级：坏图 400 连发十余个就够把它攒满（229.k/21.k 的故障形状）。
    cb_failure_threshold = 10,
    cb_success_threshold = 3,
    cb_timeout_duration_secs = 30,
}
package.loaded["resty.luarouter"] = { config = function() return conf end }

_G.ngx = {
    now = function() return os.time() end,
    log = function() end,
    WARN = 1, ERR = 2, INFO = 3, NOTICE = 4,
    ctx = {},
}

local hb = require "resty.luarouter.hb"

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
        actual ~= expect and (tostring(actual) .. " ~= " .. tostring(expect)) or nil)
end

local function new_case(name)
    io.write("  case: " .. name .. "\n")
end

---一笔干净的记账：换新 id，桩状态从零开始，不会串到上一条断言。
local SEED = 0
local function fresh_id()
    SEED = SEED + 1
    return "w" .. SEED
end

--------------------------------------------------------------------------
-- 1. 状态矩阵
--------------------------------------------------------------------------
new_case("record_stream_outcome 的状态矩阵（stream_ok=true）")

local EXEMPT = { 200, 201, 204, 206, 299, 400, 401, 403, 404, 409, 413, 422 }
local FAILURE = { 408, 429, 500, 502, 503, 504 }

for i = 1, #EXEMPT do
    local status = EXEMPT[i]
    local id = fresh_id()
    hb.record_stream_outcome(id, status, true)
    eq(charged[id], true,
        "stream " .. status .. " 记的是成功（2xx 成功、4xx 豁免）")
    eq(worker(id).failures, 0,
        "stream " .. status .. " 没有累加连续失败")
end

for i = 1, #FAILURE do
    local status = FAILURE[i]
    local id = fresh_id()
    hb.record_stream_outcome(id, status, true)
    eq(charged[id], false, "stream " .. status .. " 记的是熔断失败")
    eq(worker(id).failures, 1, "stream " .. status .. " 累加了一笔连续失败")
end

--------------------------------------------------------------------------
-- 2. 与非流式 record_status 的逐状态对称性
--------------------------------------------------------------------------
new_case("stream_ok=true 时与 record_status 记账方向逐状态一致")
local ALL = {}
for i = 1, #EXEMPT do ALL[#ALL + 1] = EXEMPT[i] end
for i = 1, #FAILURE do ALL[#ALL + 1] = FAILURE[i] end
ALL[#ALL + 1] = 302   -- 3xx 两侧都算失败，钉住「不是按 <400 一刀切」
ALL[#ALL + 1] = 599

for i = 1, #ALL do
    local status = ALL[i]
    local plain, stream = fresh_id(), fresh_id()
    hb.record_status(plain, status)
    hb.record_stream_outcome(stream, status, true)
    eq(charged[stream], charged[plain],
        "status " .. status .. "：流式与非流式记同一侧")
    eq(worker(stream).failures, worker(plain).failures,
        "status " .. status .. "：连续失败落在同一槽")
    eq(worker(stream).successes, worker(plain).successes,
        "status " .. status .. "：连续成功落在同一槽")
end

--------------------------------------------------------------------------
-- 3. 断流一律计熔断，与状态码无关
--------------------------------------------------------------------------
new_case("stream_ok=false 时无论什么状态码都记熔断失败")
for i = 1, #ALL do
    local status = ALL[i]
    local id = fresh_id()
    hb.record_stream_outcome(id, status, false)
    eq(charged[id], false,
        "断流 + 状态 " .. status .. " 仍记熔断失败（200 断流也是失败）")
    eq(worker(id).failures, 1,
        "断流 + 状态 " .. status .. " 累加了一笔连续失败")
end

--------------------------------------------------------------------------
-- 4. 生产症状：坏图 400 连发不开闸，5xx 连发必须开闸
--------------------------------------------------------------------------
new_case("连发 12 个流式 400 不开闸；连发 12 个流式 500 必须开闸")
do
    local id = fresh_id()
    for _ = 1, 12 do
        hb.record_stream_outcome(id, 400, true)
    end
    eq(worker(id).state, CB_CLOSED, "坏图 400 攒不满 cb_failure_threshold")
    eq(worker(id).failures, 0, "400 一笔都没进连续失败")
    eq(worker(id).successes, 12, "400 按成功计（与非流式同口径）")
    eq(worker(id).flips, 0, "没有发生过任何状态翻转")

    local bad = fresh_id()
    for _ = 1, 12 do
        hb.record_stream_outcome(bad, 500, true)
    end
    eq(worker(bad).state, CB_OPEN, "流式 500 攒满阈值后开闸")
    eq(worker(bad).flips, 1, "只开闸一次（阈值以上不再重复翻转）")
    eq(worker(bad).failures >= conf.cb_failure_threshold, true,
        "连续失败计数没有因为阈值之后继续记账而被丢掉")

    -- 断流开闸：状态行是 200，但流没跑到头，熔断必须照旧生效。
    local broken = fresh_id()
    for _ = 1, conf.cb_failure_threshold do
        hb.record_stream_outcome(broken, 200, false)
    end
    eq(worker(broken).state, CB_OPEN, "200 断流攒满阈值同样开闸")
end

--------------------------------------------------------------------------
-- 5. 半开恢复：流式 4xx 算一次成功探测（与非流式一样能帮助闭合）
--------------------------------------------------------------------------
new_case("half_open 里流式 400 计成功并闭闸")
do
    local id = fresh_id()
    worker(id).state = CB_HALF_OPEN
    for _ = 1, conf.cb_success_threshold do
        hb.record_stream_outcome(id, 400, true)
    end
    eq(worker(id).state, CB_CLOSED, "半开期内的流式 400 累积到闭合阈值")
    eq(worker(id).failures, 0, "闭合清零连续失败")
    eq(worker(id).successes, 0, "闭合清零连续成功")

    local back = fresh_id()
    worker(back).state = CB_HALF_OPEN
    hb.record_stream_outcome(back, 503, true)
    eq(worker(back).state, CB_OPEN, "半开期内一笔流式 5xx 立即重新开闸")
end

io.write(string.format("\n=== %d checks, %d failed ===\n", passed, failed))
for i = 1, #failures do
    io.write("FAILED: " .. failures[i] .. "\n")
end
os.exit(failed == 0 and 0 or 1)
