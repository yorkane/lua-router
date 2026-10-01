#!/usr/bin/env luajit
-- gpu_load.lua 单测（doc/gap-gpu-load.md）：GPU 负载源的两路语义。
--
-- 与 test_watcher.lua / test_mesh.lua 同形状：先在 _G.ngx = nil 下 require，
-- gpu_load 在加载时记录「没有 ngx」，于是所有语义走注入的 seams（workers / get /
-- post / write / now），不需要 nginx、不需要真端口。真实的 cosocket 抓取、
-- registry 写入、共享字典 TTL 过期与定时器接线在 Phase B 里用一个假
-- ngx.shared.lr_workers 覆盖（resty.lock 走 package.preload 替身）。
--
-- 运行（只跑 luajit，与 final_gates.sh 的 run_unit_luajit 同口径）：
--   docker run --rm -v "$PWD:/repo:ro" -w /repo \
--     --entrypoint /usr/local/openresty/luajit/bin/luajit -e LUA_TEST_LIB=/repo/lualib authz:latest \
--     -e 'package.cpath="/usr/local/openresty/lualib/?.so;"..package.cpath
--         package.path="/repo/lualib/?.lua;"..package.path
--         dofile("/repo/test/unit/test_gpu_load.lua")'
_G.ngx = nil

package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath
package.path = (os.getenv("LUA_TEST_LIB") or "./lualib") .. "/?.lua;" .. package.path

local gpu_load = require "resty.luarouter.gpu_load"

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

local function near(actual, expect, name)
    check(type(actual) == "number" and math.abs(actual - expect) < 1e-9, name,
        string.format("%s ~= %s", tostring(actual), tostring(expect)))
end

local function new_case(name)
    io.write("  case: " .. name .. "\n")
end

--------------------------------------------------------------------------
-- 1. metric 名归一（冒号、大小写、空白）
--------------------------------------------------------------------------
new_case("metric names fold case, colons and whitespace")
eq(gpu_load.canon("  vLLM:GPU_Cache_usage_perc  "), "vllm_gpu_cache_usage_perc",
    "colon folds to underscore and case drops")
eq(gpu_load.canon("nvidia_gpu_utilization"), "nvidia_gpu_utilization",
    "an already-canonical name is unchanged")
eq(gpu_load.canon("   "), nil, "blank is not a name")
eq(gpu_load.canon(nil), nil, "nil is not a name")
eq(gpu_load.canon(7), nil, "a number is not a name")

local keys = gpu_load.metric_key_list("vllm:gpu_cache_usage_perc, sglang:token_usage")
eq(#keys, 2, "a comma-separated env value splits")
eq(keys[1], "vllm_gpu_cache_usage_perc", "and the first field is canonical")
eq(keys[2], "sglang_token_usage", "and the second field is canonical")
eq(#gpu_load.metric_key_list("  ,, "), 0, "empty fields are dropped")
eq(gpu_load.metric_key_list({ "A_b", "C:d" })[2], "c_d", "a list table works too")

--------------------------------------------------------------------------
-- 2. 样本值解析：NaN / Inf / 缺失 / 合法值
--------------------------------------------------------------------------
new_case("sample values: only finite numbers survive")
eq(gpu_load.parse_number("42.5"), 42.5, "a plain gauge value parses")
eq(gpu_load.parse_number(" 0.95 "), 0.95, "surrounding whitespace is trimmed")
eq(gpu_load.parse_number("NaN"), nil, "NaN is not a load")
eq(gpu_load.parse_number("nan"), nil, "NaN in either spelling")
eq(gpu_load.parse_number("+Inf"), nil, "+Inf is not a load")
eq(gpu_load.parse_number("-Inf"), nil, "-Inf is not a load")
eq(gpu_load.parse_number(""), nil, "an empty value is missing")
eq(gpu_load.parse_number(nil), nil, "nil is missing")
eq(gpu_load.parse_number("abc"), nil, "a non-numeric value is missing")
eq(gpu_load.parse_number(0 / 0), nil, "a Lua NaN is missing")
eq(gpu_load.parse_number(0 / 0), gpu_load.parse_number(0 / 0), "NaN stays NaN-typed")
eq(gpu_load.parse_number(7), 7, "an injected number is accepted")

--------------------------------------------------------------------------
-- 3. Prometheus 文本协议：样本切分与 gauge 抽取
--------------------------------------------------------------------------
---First return of split_sample, so a two-value function can be asserted for absence
---(an `or "nil"` idiom would turn the absent value into a string and prove nothing).
local function first_identity(line)
    local identity = gpu_load.split_sample(line)
    return identity
end

new_case("exposition samples split at the value, not the first space")
local id1, v1 = gpu_load.split_sample('gpu_util{gpu="0",uuid="a b,c"} 87')
eq(id1, "gpu_util", "labels with spaces and commas do not move the split")
eq(v1, "87", "and the value is still the last field")
local id2, v2 = gpu_load.split_sample("mock_uptime_seconds 1.5")
eq(id2, "mock_uptime_seconds", "a label-less sample keeps its name")
eq(v2, "1.5", "with the value split off")
eq(first_identity("# HELP x a comment"), nil,
    "a HELP line is not a sample")
eq(first_identity(""), nil, "a blank line is not a sample")
eq(first_identity("onlyname"), nil, "a line with no value is not a sample")

local TEX = [[
# HELP nvidia_gpu_utilization GPU utilization in percent
# TYPE nvidia_gpu_utilization gauge
nvidia_gpu_utilization{gpu="0",host="gpu-box"} 12.5
nvidia_gpu_utilization{gpu="1",host="gpu-box"} 93
# HELP unrelated counter
# TYPE unrelated counter
unrelated{q="1"} 7
sglang:token_usage{model_name="m"} NaN
vllm:gpu_cache_usage_perc 0.41
]]

new_case("max_gauge reduces the wanted names only")
eq(gpu_load.max_gauge(TEX, { "nvidia_gpu_utilization" }), 93,
    "the hottest card of the multi-label series wins")
eq(gpu_load.max_gauge(TEX, { "vllm:gpu_cache_usage_perc" }), 0.41,
    "the colon name matches the wire spelling")
eq(gpu_load.max_gauge(TEX, { "sglang:token_usage" }), nil,
    "a NaN-only gauge contributes nothing")
eq(gpu_load.max_gauge(TEX, { "unrelated" }), 7,
    "an explicitly named gauge is honoured outside the default set")
eq(gpu_load.max_gauge(TEX), 93, "the default candidate set covers the percent gauge")
eq(gpu_load.max_gauge("", { "nvidia_gpu_utilization" }), nil, "an empty body matches nothing")
eq(gpu_load.max_gauge(nil, { "nvidia_gpu_utilization" }), nil, "a nil body matches nothing")
eq(gpu_load.max_gauge("nvidia_gpu_utilization 40", { "nvidia_gpu_utilization" }), 40,
    "a single label-less series is read verbatim")
eq(gpu_load.max_gauge("nvidia_gpu_utilization{a=\"}{\"} 60", "nvidia_gpu_utilization"), 60,
    "brace-heavy label values do not truncate the identity")

new_case("max_gauge tolerates a truncated or malformed exposition")
eq(gpu_load.max_gauge("nvidia_gpu_utilization 5\nnvidia_gpu_utilization {broken",
    { "nvidia_gpu_utilization" }), 5, "a broken tail line does not lose the good sample")
eq(gpu_load.max_gauge("nvidia_gpu_utilization\n", { "nvidia_gpu_utilization" }), nil,
    "a name with no value is not a sample")
eq(gpu_load.max_gauge("x{y=\"1\" 4\nnvidia_gpu_utilization 70",
    { "nvidia_gpu_utilization" }), 70, "an unbalanced brace line is skipped, not fatal")

--------------------------------------------------------------------------
-- 4. 归一化：百分比与分数量纲统一
--------------------------------------------------------------------------
new_case("normalize maps percent and fraction gauges onto 0..1")
near(gpu_load.normalize(93), 0.93, "93 reads as a percent")
near(gpu_load.normalize(0.41), 0.41, "0.41 is already a fraction")
near(gpu_load.normalize(1), 1.0, "exactly 1 is a full card, not 1 %")
near(gpu_load.normalize(0), 0, "an idle card is 0")
near(gpu_load.normalize(100), 1.0, "100 percent clamps to 1")
near(gpu_load.normalize(400), 1,
    "an absurd reading clamps to busy rather than vanishing")
eq(gpu_load.normalize(-5), nil, "a negative value is not a load")
eq(gpu_load.normalize("NaN"), nil, "NaN normalizes to nothing")
eq(gpu_load.normalize(nil), nil, "missing normalizes to nothing")
near(gpu_load.normalize("77.5"), 0.775, "a textual percent parses")

--------------------------------------------------------------------------
-- 5. host 归一：worker url 与 Prometheus 身份标签对得上
--------------------------------------------------------------------------
new_case("split_host extracts the machine from a worker url")
local h1, p1 = gpu_load.split_host("http://10.252.25.217:8800")
eq(h1, "10.252.25.217", "an ipv4 url splits into host and port")
eq(p1, 8800, "and the port is a number")
eq((gpu_load.split_host("https://GPU-Box.local:443/v1")), "gpu-box.local",
    "the host is lower-cased and the path ignored")
eq((gpu_load.split_host("http://127.0.0.1:8100@2")), "127.0.0.1",
    "the DP rank suffix is dropped, as the dial path drops it")
eq((gpu_load.split_host("http://gpu1.example.com.")), "gpu1.example.com",
    "a trailing FQDN dot does not defeat the match")
eq((gpu_load.split_host("http://user:pw@10.0.0.9:30000")), "10.0.0.9",
    "userinfo is not a hostname")
eq((gpu_load.split_host("http://[fe80::1]:8080")), "fe80::1",
    "a bracketed IPv6 host keeps its address")
eq(gpu_load.split_host(nil), nil, "no url, no host")
eq(gpu_load.split_host(""), nil, "an empty url, no host")
eq(gpu_load.split_host("not a url at all"), nil, "junk yields no host")
eq(gpu_load.split_host("http://"), nil, "an authority-less url yields no host")

new_case("host_from_label reduces every identity-label spelling to a host")
eq(gpu_load.host_from_label("10.0.0.5:9100"), "10.0.0.5", "instance=\"host:port\"")
eq(gpu_load.host_from_label("10.0.0.5"), "10.0.0.5", "instance with no port")
eq(gpu_load.host_from_label("GPU-Box:9400"), "gpu-box", "and the case folds")
eq(gpu_load.host_from_label("http://10.0.0.5:8800/metrics"), "10.0.0.5",
    "a url-ish label still reduces to the host")
eq(gpu_load.host_from_label(""), nil, "a blank label names nobody")
eq(gpu_load.host_from_label(nil), nil, "an absent label names nobody")
local labels = { job = "node", instance = "gpu7.internal:9100", pod = "router-abc" }
eq(gpu_load.host_of(labels), "gpu7.internal",
    "instance wins over the other identity labels, in HOST_LABELS order")
eq(gpu_load.host_of({ node = "gpu3.internal" }), "gpu3.internal",
    "a node label is the fallback when instance is absent")
eq(gpu_load.host_of({}), nil, "no identity label, no host")
eq(gpu_load.host_of(nil), nil, "nil labels, no host")

--------------------------------------------------------------------------
-- 6. PromQL 模板与请求构造
--------------------------------------------------------------------------
new_case("render_query expands {host} and {instance} per worker")
eq(gpu_load.render_query('DCGM_FI_DEV_GPU_UTIL{hostname="{host}"}',
    { url = "http://10.0.0.5:30000" }), 'DCGM_FI_DEV_GPU_UTIL{hostname="10.0.0.5"}',
    "{host} becomes the host alone")
eq(gpu_load.render_query('up{instance="{instance}"}',
    { url = "http://10.0.0.5:30000" }), 'up{instance="10.0.0.5:30000"}',
    "{instance} keeps the worker's own port")
eq(gpu_load.render_query('avg by (host) (gpu_util)', { url = "http://10.0.0.5:3000" }),
    'avg by (host) (gpu_util)', "a template with no placeholder passes through")
eq(gpu_load.render_query('{host}', { url = "http://" }), nil,
    "a worker with no nameable host cannot answer a host-scoped query")
eq(gpu_load.render_query("", { url = "http://h:1" }), nil, "no template, no query")
check(gpu_load.query_needs_host('x{h="{host}"}'), "{host} marks a per-worker query")
check(gpu_load.query_needs_host('{instance}'), "{instance} marks it as well")
check(not gpu_load.query_needs_host("avg(gpu_util)"), "a plain aggregate does not")
check(not gpu_load.query_needs_host(nil), "nil does not")

new_case("query_endpoint accepts a base or a full endpoint")
eq(gpu_load.query_endpoint("http://prom:9090"), "http://prom:9090/api/v1/query",
    "a bare base gets the API path")
eq(gpu_load.query_endpoint("http://prom:9090/"), "http://prom:9090/api/v1/query",
    "a trailing slash is not doubled")
eq(gpu_load.query_endpoint("http://prom:9090/api/v1/query"),
    "http://prom:9090/api/v1/query", "an explicit endpoint is kept")
eq(gpu_load.query_endpoint("   "), nil, "blank is not an endpoint")
eq(gpu_load.query_endpoint(nil), nil, "absent is not an endpoint")
eq(gpu_load.query_body('sum(x{a="1 2"})/y'),
    "query=sum%28x%7Ba%3D%221%202%22%7D%29%2Fy", "the PromQL is percent-encoded, brace and slash included")

--------------------------------------------------------------------------
-- 7. Prometheus /api/v1/query 响应解析
--------------------------------------------------------------------------
local VECTOR = require("cjson.safe").encode({
    status = "success",
    data = {
        resultType = "vector",
        result = {
            { metric = { instance = "gpu-a:9100", gpu = "0" }, value = { 1700000000, "88" } },
            { metric = { instance = "gpu-a:9100", gpu = "1" }, value = { 1700000001, "12" } },
            { metric = { instance = "gpu-b:9100" }, value = { 1700000002, "0.35" } },
        },
    },
})

new_case("the vector is parsed into rows, and unusable rows drop out")
local rows, rerr = gpu_load.parse_prom_response(VECTOR)
check(type(rows) == "table" and #rows == 3, "every series becomes a row", rerr)
near(rows[1].value, 88, "the sample value is the second element of the pair")
eq(rows[1].labels.gpu, "0", "labels are carried through for the host match")
local bad = gpu_load.parse_prom_response('{"status":"error","errorType":"bad_data"}')
eq(bad, nil, "an error answer is not an empty result")
local mat = gpu_load.parse_prom_response('{"status":"success","data":{"resultType":"matrix","result":[]}}')
eq(mat, nil, "a range query has no per-series instant to map, so it is refused")
eq(gpu_load.parse_prom_response("not json"), nil, "a non-JSON body is refused")
eq(gpu_load.parse_prom_response(""), nil, "an empty body is refused")
eq(gpu_load.parse_prom_response(nil), nil, "a nil body is refused")
local empty, eerr = gpu_load.parse_prom_response(
    '{"status":"success","data":{"resultType":"vector","result":[]}}')
check(type(empty) == "table" and #empty == 0, "an empty vector is a valid answer", eerr)
local nanned = gpu_load.parse_prom_response(
    '{"status":"success","data":{"resultType":"vector","result":[{"metric":{"host":"h1"},"value":[1,"NaN"]}]}}')
eq(nanned[1].value, nil, "a NaN series arrives with no usable value")
local scalar = gpu_load.parse_prom_response(
    '{"status":"success","data":{"resultType":"scalar","result":[1,"5"]}}')
eq(scalar, nil, "a scalar answer is refused rather than guessed at")

new_case("the vector folds to one load per host")
local by_host = gpu_load.host_values(rows)
near(by_host["gpu-a"], 0.88, "the hottest of gpu-a's two cards defines its load")
near(by_host["gpu-b"], 0.35, "and gpu-b reads its own fraction")
eq(next(gpu_load.host_values({})), nil, "no rows, no hosts")
eq(next(gpu_load.host_values(nil)), nil, "nil rows, no hosts")
eq(next(gpu_load.host_values({ { labels = { instance = "h:1" }, value = "NaN" } })), nil,
    "a NaN series is not a host")

new_case("hosts map onto in-pool workers; unknown instances are ignored")
local workers = {
    { id = "a1", url = "http://gpu-a:8800" },
    { id = "a2", url = "http://gpu-a:8801" },
    { id = "b1", url = "http://gpu-b:8800" },
}
local assigned, unmatched = gpu_load.assign(by_host, workers)
near(assigned.a1, 0.88, "the first worker on gpu-a gets its reading")
near(assigned.a2, 0.88, "and its co-located sibling shares it (same GPU host)")
near(assigned.b1, 0.35, "the other machine reads its own value")
eq(unmatched, 0, "nothing in the vector is unexplained")
local partial, unmatched2 = gpu_load.assign({ ["gpu-z"] = 0.5 }, workers)
eq(next(partial), nil, "a series for a machine nobody pools assigns nothing")
eq(unmatched2, 1, "and it is counted as unmatched (a topology hint, not an error)")
eq(#gpu_load.assign(by_host, {}), 0, "no workers, no assignment")
eq(#gpu_load.assign(nil, workers), 0, "no samples, no assignment")

--------------------------------------------------------------------------
-- 8. 优先级：外部源 > 自报 > 只剩 in-flight
--------------------------------------------------------------------------
new_case("effective_load ranks the channels and keeps units comparable")
near(gpu_load.effective_load(nil, 3, 100), 3, "with no sample, in-flight is the load")
near(gpu_load.effective_load(0.95, 0, 100), 95,
    "a 95 %-busy GPU outranks an idle queue, in request units")
near(gpu_load.effective_load(0.95, 2, 100), 97,
    "and the two terms add, because they measure different things")
near(gpu_load.effective_load(0.5, 4, 100), 54,
    "so a sample and a request are comparable in one number")
near(gpu_load.effective_load(0.5, 4, 10), 9,
    "SMG_LOAD_SCALE=10 makes a fully busy card worth ten requests instead of a hundred")
near(gpu_load.effective_load(0, nil, 100), 0, "an idle GPU with an empty queue is 0")
near(gpu_load.effective_load(5, 0, 100), 100, "an out-of-range sample clamps at 1.0")
near(gpu_load.effective_load(-1, 0, 100), 0, "a negative sample clamps at 0")
near(gpu_load.effective_load(0.5, -3, 100), 50, "a broken in-flight counter floors at 0")
near(gpu_load.effective_load(0.5, 0), 50, "the weight defaults to 100 when unpublished")

--------------------------------------------------------------------------
-- 假 ngx + 假共享字典：live 层与 registry 负载字段的接线
--
-- gpu_load 的纯逻辑层在上面已经以「没有 ngx」的状态测完（那些函数不碰 ngx），
-- 从这里开始才立一个假的 ngx：registry 的负载字段要 shdict，run_pass 的 live 层要
-- ngx.log / ngx.now。抓取与写入仍然走注入的 seams，所以不需要 nginx、不需要端口。
-- resty.lock 是 registry 加载期的硬依赖，给一个总是成功的替身——本用例测的是负载
-- 字段的读写与优先级，不是锁。
--------------------------------------------------------------------------
local function new_store()
    return {}
end

local function dict_stub(backing)
    local s = backing or new_store()
    return setmetatable({}, { __index = {
        store = s,
        get = function(_, key)
            local hit = s[key]
            if not hit then
                return nil
            end
            if hit.expire and hit.expire <= ngx.now() then
                return nil              -- TTL 过期 = 「这个 tick 没有样本」
            end
            return hit.value
        end,
        set = function(_, key, value, ttl)
            s[key] = {
                value = value,
                expire = (tonumber(ttl) and ttl > 0) and (ngx.now() + ttl) or nil,
            }
            return true
        end,
        delete = function(_, key)
            s[key] = nil
            return true
        end,
        incr = function(_, key, delta, init)
            local cur = tonumber(s[key] and s[key].value) or init or 0
            s[key] = { value = cur + delta }
            return s[key].value
        end,
        get_keys = function()
            local out = {}
            for key in pairs(s) do out[#out + 1] = key end
            return out
        end,
    } })
end

local workers_store = new_store()
local stats_store = new_store()
local log_lines = {}
local clock = { t = 1000 }

package.preload["resty.lock"] = function()
    return {
        new = function()
            return {
                lock = function() return true end,
                unlock = function() return true end,
            }
        end,
    }
end

_G.ngx = {
    shared = {
        lr_workers = dict_stub(workers_store),
        lr_stats = dict_stub(stats_store),
        lr_policy = dict_stub(new_store()),
    },
    -- OpenResty's ngx.now() is *seconds* with ms resolution, so the injected clock
    -- advances in milliseconds and gets divided here rather than at every caller.
    now = function() return clock.t / 1000 end,
    time = function() return math.floor(clock.t / 1000) end,
    log = function(level, ...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring(select(i, ...))
        end
        log_lines[#log_lines + 1] = { level = level, text = table.concat(parts, "") }
        return true
    end,
    WARN = 4, ERR = 2, NOTICE = 5, INFO = 7, DEBUG = 8,
    socket = nil, timer = nil, worker = nil,
    config = { subsystem = "http" },
}

local registry = require "resty.luarouter.registry"

---Empty the shared state a case could leave behind. The dict objects stay: registry
---resolves ngx.shared.lr_workers once, so it is the backing tables that get cleared.
local function reset_store()
    for key in pairs(workers_store) do workers_store[key] = nil end
    for key in pairs(stats_store) do stats_store[key] = nil end
    registry.clear_external_samples_flag()
    registry.set_load_scale(100)
    gpu_load.reset_warn_dedup()
    log_lines = {}
    clock.t = 1000
end

---Seed one in-flight counter (router.lua's own channel) for a worker.
local function seed_inflight(id, n)
    workers_store["lo:" .. id] = { value = n }
end

local function warn_lines()
    local n = 0
    for i = 1, #log_lines do
        if log_lines[i].level == ngx.WARN then n = n + 1 end
    end
    return n
end

---Seams for one pass. `doc` describes the scripted answers:
---  { workers = <fn|list>, get = fn(url)->reply, post = <reply>|fn(body)->reply }
---and the returned `calls` records what the pass actually dialed.
local function counting_seams(doc)
    local calls = { get = {}, post = {}, writes = {} }
    local workers = doc.workers
    if type(workers) ~= "function" then
        local list = workers or {}
        workers = function() return list end
    end
    return calls, {
        workers = workers,
        get = function(url, timeout_ms, headers)
            calls.get[#calls.get + 1] = { url = url, timeout_ms = timeout_ms,
                                          headers = headers }
            local reply = doc.get and doc.get(url)
            if reply == nil then
                return nil, nil, "connection refused"
            end
            return reply.status or 200, reply.body, reply.err
        end,
        post = function(url, timeout_ms, headers, body)
            calls.post[#calls.post + 1] = { url = url, body = body,
                                            timeout_ms = timeout_ms, headers = headers }
            local script = doc.post
            local reply
            if type(script) == "function" then
                reply = script(body)
            else
                reply = script
            end
            if reply == nil then
                return nil, nil, "connection refused"
            end
            return reply.status or 200, reply.body, reply.err
        end,
        -- The default writer is registry.set_external_load; injecting it records the
        -- samples *and* leaves them where registry.load() reads them, so a case can
        -- assert both the pass and what selection would then see.
        write = function(id, value, ts, ttl, url)
            calls.writes[#calls.writes + 1] = { id = id, value = value, ttl = ttl,
                                               url = url }
            return registry.set_external_load(id, value, ttl)
        end,
        now = function() return clock.t end,
    }
end

local TWO_WORKERS = {
    { id = "a1", url = "http://gpu-a:8800" },
    { id = "a2", url = "http://gpu-a:8801" },
    { id = "b1", url = "http://gpu-b:8800" },
}

--------------------------------------------------------------------------
-- 9. registry 的负载字段：优先级就是在这里定的
--------------------------------------------------------------------------
new_case("registry.load stays in-flight-only while no source runs")
reset_store()
seed_inflight("a1", 3)
eq(registry.load("a1"), 3, "no samples: the number is exactly the in-flight count")
eq(registry.external_load("a1"), nil, "and there is no external reading to report")
local only_inflight = true
for key in pairs(workers_store) do
    if key ~= "lo:a1" then only_inflight = false end
end
check(only_inflight, "no xl:/sl:/xany key exists before the first sample")
eq(registry.any_external_samples(), false, "and the shared flag is off")

new_case("an external sample outranks the engine self-report")
reset_store()
seed_inflight("a1", 2)
check(registry.set_external_load("a1", 0.9, 60), "the external channel accepts a sample")
check(registry.set_self_reported_load("a1", 0.1, 60),
    "and the self-report channel accepts one too")
near(registry.load("a1"), 2 + 0.9 * 100,
    "the external sample wins the definition of load")
near(registry.external_load("a1"), 0.9, "and reads back normalized")
check(registry.any_external_samples(), "once a sample exists, the flag is on")

new_case("the self-report feeds the load when there is no external sample")
reset_store()
seed_inflight("b1", 1)
check(registry.set_self_reported_load("b1", 0.5, 60), "the self-report stores")
near(registry.load("b1"), 1 + 50, "and is the load in the absence of a GPU sample")
eq(registry.external_load("b1"), nil, "while the external channel stays empty")
near(registry.load_scale(), 100, "the weight is the published default")

new_case("SMG_LOAD_SCALE changes what a fully busy worker is worth")
reset_store()
seed_inflight("c1", 0)
registry.set_load_scale(10)
check(registry.set_external_load("c1", 0.5, 60), "stored under the new weight")
near(registry.load("c1"), 5, "a 50 %-busy card is worth five in-flight requests")
eq(registry.set_load_scale(0), 10, "a nonsensical weight is rejected, not applied")
eq(registry.set_load_scale("abc"), 10, "and so is a non-number")

new_case("an expired sample stops being a load (TTL, not a cleanup job)")
reset_store()
seed_inflight("d1", 0)
check(registry.set_external_load("d1", 0.8, 30), "a sample with a 30 s window lands")
near(registry.load("d1"), 80, "while it is fresh it is the load")
clock.t = clock.t + 31 * 1000
eq(registry.load("d1"), 0, "past its TTL the worker is back to in-flight only")
eq(registry.external_load("d1"), nil, "and the sample reads as absent")
eq(registry.any_external_samples(), false,
    "the shared flag expires with it, so nothing needs to clean up")

new_case("to_milli and stale_ttl refuse the unusable")
eq(registry.to_milli(0.9125), 913, "a fraction becomes milli, rounded")
eq(registry.to_milli(1), 1000, "a full card is 1000 milli")
eq(registry.to_milli(4), 1000, "and out-of-range clamps rather than rejecting")
eq(registry.to_milli("NaN"), nil, "text NaN stores nothing")
eq(registry.to_milli(0 / 0), nil, "a Lua NaN stores nothing")
eq(registry.to_milli(nil), nil, "nothing to store")
eq(registry.stale_ttl(0), 45, "an unset window falls back to the default")
eq(registry.stale_ttl(-7), 45, "a negative window is not honoured")
eq(registry.stale_ttl(1), 5, "a sub-second window is floored")
eq(registry.stale_ttl(99999), 3600, "and a huge one is capped")
reset_store()
eq(registry.set_external_load("x1", "NaN"), false, "a NaN sample is refused outright")
eq(registry.set_external_load("x1", nil), false, "and so is a missing one")
eq(next(workers_store), nil, "leaving no key behind at all")

new_case("clear_external_load takes both channels down")
reset_store()
seed_inflight("e1", 4)
registry.set_external_load("e1", 0.5, 60)
registry.set_self_reported_load("e1", 0.2, 60)
near(registry.load("e1"), 54, "both stored, external wins")
registry.clear_external_load("e1")
near(registry.load("e1"), 4, "cleared: the in-flight count is the whole load again")
eq(registry.external_load("e1"), nil, "and no sample is reportable")

new_case("the WorkerInfo view reports the ranked load; the breaker view stays raw")
reset_store()
seed_inflight("f1", 3)
registry.set_external_load("f1", 0.5, 60)
local info = registry.info({ id = "f1", url = "http://gpu-f:8800" })
near(info.load, 53, "/workers reports what selection ranked on")
near(registry.cb_state("f1").load, 3,
    "while the breaker snapshot keeps the raw in-flight count for smg_worker_requests_active")
near(registry.load_with(ngx.shared.lr_workers, "f1"), 53,
    "and the dict-taking variant agrees with the module-level one")
reset_store()
seed_inflight("f2", 7)
eq(registry.info({ id = "f2", url = "http://gpu-f:8801" }).load, 7,
    "with no samples it is the in-flight number the contract pins")

--------------------------------------------------------------------------
-- 10. run_pass: source=none 零副作用
--------------------------------------------------------------------------
new_case("source=none is exactly the pre-feature code path")
reset_store()
local calls, seams = counting_seams({ workers = { { id = "a1", url = "http://gpu-a:8800" } } })
local stats = gpu_load.run_pass({ load_source = "none" }, seams)
eq(stats.source, "none", "the source is reported")
eq(#calls.get, 0, "nothing is fetched")
eq(#calls.post, 0, "no prometheus query either")
eq(#calls.writes, 0, "and the registry is not written")
eq(next(workers_store), nil, "not one shared-dict key appears")
eq(next(stats_store), nil, "nor any counter of its own")
eq(#log_lines, 0, "not even a warning")

--------------------------------------------------------------------------
-- 11. run_pass: 本地 metrics 源
--------------------------------------------------------------------------
new_case("metrics source scrapes each worker's /metrics and normalizes it")
reset_store()
local calls_m, seams_m = counting_seams({
    workers = { TWO_WORKERS[1], TWO_WORKERS[3] },
    get = function(url)
        if url == "http://gpu-a:8800/metrics" then
            return { status = 200, body = 'nvidia_gpu_utilization{gpu="0"} 82.5\n' }
        end
        return { status = 200, body = "vllm:gpu_cache_usage_perc 0.61\n" }
    end,
})
local st_m = gpu_load.run_pass({
    load_source = "metrics", load_interval_secs = 15, load_timeout_secs = 4,
    load_scale = 100,
}, seams_m)
eq(st_m.probed, 2, "every pool member is scraped once")
eq(st_m.matched, 2, "and both answers became samples")
eq(st_m.failed, 0, "with nothing wrong")
eq(#calls_m.get, 2, "two GETs")
eq(calls_m.get[1].url, "http://gpu-a:8800/metrics", "on the worker's own /metrics")
eq(calls_m.get[1].timeout_ms, 4000, "with the configured deadline in ms")
eq(#calls_m.writes, 2, "two samples stored")
near(calls_m.writes[1].value, 0.825, "percent folded onto 0..1")
near(calls_m.writes[2].value, 0.61, "fraction kept as read")
eq(calls_m.writes[1].ttl, 45, "the staleness window is three intervals")
near(registry.load("a1"), 82.5, "so power_of_two reads it through registry.load")
near(registry.load("b1"), 61, "for the other worker as well")

new_case("the /metrics path is configurable for exporters on a different route")
reset_store()
local calls_p, seams_p = counting_seams({
    workers = { { id = "a1", url = "http://gpu-a:8800" } },
    get = function() return { status = 200, body = "gpu_util 40\n" } end,
})
gpu_load.run_pass({
    load_source = "metrics", load_metrics_path = "/metrics/", load_metrics_keys = "gpu_util",
}, seams_p)
eq(calls_p.get[1].url, "http://gpu-a:8800/metrics/", "the configured path is appended verbatim")

new_case("a 404 on /metrics is a missing gauge, never a health event")
reset_store()
workers_store["hl:a1"] = { value = 1 }
workers_store["hl:b1"] = { value = 1 }
workers_store["hf:a1"] = { value = 0 }
local _, seams_404 = counting_seams({
    workers = { TWO_WORKERS[1], TWO_WORKERS[3] },
    get = function() return { status = 404, body = "not found" } end,
})
local st_404 = gpu_load.run_pass({ load_source = "metrics" }, seams_404)
eq(st_404.matched, 0, "no samples came out of it")
eq(st_404.failed, 2, "counted as failures")
eq(workers_store["hl:a1"].value, 1, "worker a is still healthy")
eq(workers_store["hl:b1"].value, 1, "worker b is still healthy")
eq(workers_store["hf:a1"].value, 0, "and its consecutive-failure counter never moved")
eq(workers_store["xl:a1"], nil, "no load key was invented for it")
eq(registry.load("a1"), 0, "so it stays on in-flight load alone")

new_case("a gauge-less or oversized body fails quietly")
reset_store()
local _, seams_nog = counting_seams({
    workers = { { id = "a1", url = "http://gpu-a:8800" } },
    get = function() return { status = 200, body = "# nothing we asked for\nmock_x 1\n" } end,
})
local st_nog = gpu_load.run_pass({ load_source = "metrics" }, seams_nog)
eq(st_nog.failed, 1, "no wanted gauge in the exposition is a miss")
eq(st_nog.matched, 0, "and stores no sample")
reset_store()
local _, seams_big = counting_seams({
    workers = { { id = "a1", url = "http://gpu-a:8800" } },
    get = function() return { status = 200, body = string.rep("gpu_util 50\n", 400000) } end,
})
local st_big = gpu_load.run_pass({
    load_source = "metrics", load_metrics_keys = "gpu_util",
}, seams_big)
eq(st_big.failed, 1, "a megabyte-scale exposition is abandoned, not parsed")

new_case("a connection failure, a timeout or a raising fetch is silent")
reset_store()
workers_store["hl:a1"] = { value = 1 }
local _, seams_err = counting_seams({ workers = { TWO_WORKERS[1], TWO_WORKERS[3] } })
local st_err = gpu_load.run_pass({ load_source = "metrics" }, seams_err)
eq(st_err.failed, 2, "both probes failed")
eq(st_err.matched, 0, "nothing was stored")
eq(workers_store["hl:a1"].value, 1, "and health is untouched")
reset_store()
local _, seams_raise = counting_seams({
    workers = { { id = "a1", url = "http://gpu-a:8800" } },
    get = function() error("cosocket exploded") end,
})
local ok_run, st_raise = pcall(gpu_load.run_pass, { load_source = "metrics" }, seams_raise)
check(ok_run, "a raising fetch does not take the pass down", tostring(st_raise))
check(ok_run and st_raise.errors == 1, "it is counted as an error",
    ok_run and st_raise.errors or "n/a")

new_case("an api_key reaches the scrape as a bearer token")
reset_store()
local calls_auth, seams_auth = counting_seams({
    workers = { { id = "a1", url = "http://gpu-a:8800", api_key = "sk-secret" } },
    get = function() return { status = 200, body = "gpu_util 50\n" } end,
})
gpu_load.run_pass({ load_source = "metrics", load_metrics_keys = "gpu_util" }, seams_auth)
eq(calls_auth.get[1].headers and calls_auth.get[1].headers.Authorization,
    "Bearer sk-secret", "a worker with a key is scraped with it")
reset_store()
local calls_plain, seams_plain = counting_seams({
    workers = { { id = "a1", url = "http://gpu-a:8800" } },
    get = function() return { status = 200, body = "gpu_util 50\n" } end,
})
gpu_load.run_pass({ load_source = "metrics", load_metrics_keys = "gpu_util" }, seams_plain)
eq(calls_plain.get[1].headers, nil, "and a keyless worker is scraped without one")

new_case("SMG_LOAD_METRICS_KEYS restricts which gauges count")
reset_store()
local _, seams_keys = counting_seams({
    workers = { { id = "a1", url = "http://gpu-a:8800" } },
    get = function()
        return { status = 200,
                 body = "vllm:gpu_cache_usage_perc 0.9\nmy_custom_gauge 5\n" }
    end,
})
local st_keys = gpu_load.run_pass({
    load_source = "metrics", load_metrics_keys = { "my_custom_gauge" }, load_scale = 100,
}, seams_keys)
eq(st_keys.matched, 1, "the named gauge answered")
near(registry.external_load("a1"), 0.05,
    "and is the only gauge that counted (5 %), not the 0.9 cache gauge")

--------------------------------------------------------------------------
-- 12. run_pass: 远程 prom 源
--------------------------------------------------------------------------
local function prom_doc(body, workers)
    return { workers = workers or TWO_WORKERS, post = { status = 200, body = body } }
end

new_case("prom source pulls one vector and maps it back onto the pool")
reset_store()
local calls_q, seams_q = counting_seams(prom_doc(VECTOR))
local st_q = gpu_load.run_pass({
    load_source = "prom", load_prom_url = "http://prom:9090",
    load_prom_query = "avg by (instance) (DCGM_FI_DEV_GPU_UTIL)",
    load_interval_secs = 15, load_timeout_secs = 4, load_scale = 100,
}, seams_q)
eq(#calls_q.post, 1, "one query per pass when the PromQL is pool-wide")
eq(calls_q.post[1].url, "http://prom:9090/api/v1/query", "against the query API")
eq(calls_q.post[1].body,
   "query=avg%20by%20%28instance%29%20%28DCGM_FI_DEV_GPU_UTIL%29",
   "as an urlencoded form body")
eq(calls_q.post[1].headers["Content-Type"], "application/x-www-form-urlencoded",
   "with the form content type the API expects")
eq(st_q.probed, 1, "one query executed")
eq(st_q.matched, 3, "and all three workers on the two hosts got the sample")
eq(st_q.unmatched, 0, "every series had a worker behind it")
near(registry.load("a1"), 88, "the co-located pair shares the host reading")
near(registry.load("a2"), 88, "in the same number")
near(registry.load("b1"), 35, "and the other machine reads its own")

new_case("a {host} template is rendered once per worker")
reset_store()
local calls_h, seams_h = counting_seams({
    workers = { TWO_WORKERS[1], TWO_WORKERS[3] },
    post = { status = 200,
             body = '{"status":"success","data":{"resultType":"vector","result":'
                 .. '[{"metric":{"instance":"gpu-a:8800"},"value":[1,"77"]}]}}' },
})
local st_h = gpu_load.run_pass({
    load_source = "prom", load_prom_url = "http://prom:9090/",
    load_prom_query = 'DCGM_FI_DEV_GPU_UTIL{instance="{instance}"}',
    load_scale = 100,
}, seams_h)
eq(#calls_h.post, 2, "one request per worker, since the template names a host")
eq(calls_h.post[1].body,
   "query=DCGM_FI_DEV_GPU_UTIL%7Binstance%3D%22gpu-a%3A8800%22%7D",
   "expanded with that worker's own host:port")
eq(calls_h.post[2].body,
   "query=DCGM_FI_DEV_GPU_UTIL%7Binstance%3D%22gpu-b%3A8800%22%7D",
   "and the second worker's")
eq(st_h.matched, 1, "only the series that came back became a sample")
near(registry.load("a1"), 77, "on the worker it belongs to")
eq(registry.external_load("b1"), nil, "the other worker keeps no sample from this pass")

new_case("ranked workers on one host share a single rendered query")
reset_store()
local ranks = {
    { id = "r0", url = "http://gpu-c:8800@0" },
    { id = "r1", url = "http://gpu-c:8800@1" },
    { id = "r2", url = "http://gpu-c:8800@2" },
    { id = "r3", url = "http://gpu-c:8800@3" },
}
local calls_r, seams_r = counting_seams({
    workers = ranks,
    post = { status = 200,
             body = '{"status":"success","data":{"resultType":"vector","result":'
                 .. '[{"metric":{"instance":"gpu-c"},"value":[1,"64"]}]}}' },
})
local st_r = gpu_load.run_pass({
    load_source = "prom", load_prom_url = "http://prom:9090",
    load_prom_query = 'gpu_util{hostname="{host}"}', load_scale = 100,
}, seams_r)
eq(#calls_r.post, 1, "four DP ranks of one machine cost one POST, not four")
eq(st_r.matched, 4, "and every rank still received the host sample")
near(registry.load("r2"), 64, "which is what selection sees for each of them")

new_case("one host's reading never bleeds onto its neighbours' workers")
-- The port is deliberately dropped by the mapping, so this is the exact shape the
-- e2e tripped over: three workers, three hosts, one hot series and one cooler
-- sibling on the first host, and a NaN on the third. Folding per host means the
-- hot machine's 88 must not be able to reach the other two, and a host whose only
-- series is NaN must keep no sample at all -- not a stale one, and not its
-- neighbour's. If host_values() ever keyed on the array index instead of the
-- label, both of these numbers arrive as 88.
reset_store()
local _, seams_iso = counting_seams({
    workers = {
        { id = "h1", url = "http://10.0.0.1:8800" },
        { id = "h2", url = "http://10.0.0.2:8800" },
        { id = "h3", url = "http://10.0.0.3:8800" },
    },
    post = { status = 200, body =
        '{"status":"success","data":{"resultType":"vector","result":['
        .. '{"metric":{"instance":"10.0.0.1:9100","gpu":"0"},"value":[1,"88"]},'
        .. '{"metric":{"instance":"10.0.0.1:9100","gpu":"1"},"value":[1,"5"]},'
        .. '{"metric":{"instance":"10.0.0.2:9100"},"value":[1,"12"]},'
        .. '{"metric":{"instance":"10.0.0.3:9100"},"value":[1,"NaN"]}]}}' },
})
local st_iso = gpu_load.run_pass({
    load_source = "prom", load_prom_url = "http://prom:9090",
    load_prom_query = "gpu_util", load_scale = 100,
}, seams_iso)
near(registry.load("h1"), 88, "the hot machine contributes its maximum, not its mean")
near(registry.load("h2"), 12, "the next machine keeps its own reading")
eq(registry.external_load("h3"), nil, "the NaN-only machine gets no sample at all")
eq(registry.load("h3"), 0, "which is no load, and not the previous worker's 88")
eq(st_iso.matched, 2, "two workers sampled, the third legitimately unsampled")
eq(st_iso.unmatched, 0, "and every series belonged to someone")

new_case("unknown instances are ignored, never invented onto a worker")
reset_store()
local _, seams_unk = counting_seams(prom_doc(
    '{"status":"success","data":{"resultType":"vector","result":['
    .. '{"metric":{"instance":"some-other-box:9100"},"value":[1,"99"]}]}}'))
local st_unk = gpu_load.run_pass({
    load_source = "prom", load_prom_url = "http://prom:9090",
    load_prom_query = "gpu_util",
}, seams_unk)
eq(st_unk.matched, 0, "nothing in the vector names a pooled machine")
eq(st_unk.unmatched, 1, "counted as an unmatched host (the topology hint)")
eq(registry.external_load("a1"), nil, "no worker absorbed the stranger's load")
eq(registry.load("a1"), 0, "and it does not distort selection either")

new_case("a prometheus that is down or wrong is silent and costs no worker")
reset_store()
workers_store["hl:a1"] = { value = 1 }
local _, seams_down = counting_seams({ workers = { TWO_WORKERS[1] } })
local st_down = gpu_load.run_pass({
    load_source = "prom", load_prom_url = "http://prom:9090", load_prom_query = "gpu_util",
}, seams_down)
eq(st_down.failed, 1, "the connection failure is counted")
eq(workers_store["hl:a1"].value, 1, "the worker stays healthy")
reset_store()
local _, seams_garbage = counting_seams(prom_doc("<html>502 bad gateway</html>"))
local st_garbage = gpu_load.run_pass({
    load_source = "prom", load_prom_url = "http://prom:9090", load_prom_query = "gpu_util",
}, seams_garbage)
eq(st_garbage.matched, 0, "a body that is not the API's JSON stores nothing")
eq(st_garbage.failed, 1, "and is reported as a failed pass")
reset_store()
local _, seams_500 = counting_seams({ workers = { TWO_WORKERS[1] },
                                       post = { status = 500, body = '{"status":"error"}' } })
local st_500 = gpu_load.run_pass({
    load_source = "prom", load_prom_url = "http://prom:9090", load_prom_query = "gpu_util",
}, seams_500)
eq(st_500.failed, 1, "an HTTP error answer is a failed pass, not an empty one")

new_case("an incomplete prom config skips the pass instead of guessing")
reset_store()
local calls_cfg, seams_cfg = counting_seams(prom_doc("{}"))
local st_cfg = gpu_load.run_pass(
    { load_source = "prom", load_prom_url = "", load_prom_query = "" }, seams_cfg)
eq(st_cfg.skipped, 1, "no url and no query is a config gap")
eq(#calls_cfg.post, 0, "and it issues no request at all")
reset_store()
local _, seams_cfg2 = counting_seams(prom_doc("{}"))
eq(gpu_load.run_pass({ load_source = "prom", load_prom_url = "http://prom:9090",
                       load_prom_query = "" }, seams_cfg2).skipped, 1,
   "a missing PromQL template likewise")

new_case("an unknown source name does nothing")
reset_store()
local calls_unk, seams_unk2 = counting_seams({ workers = { TWO_WORKERS[1] } })
local st_unk2 = gpu_load.run_pass({ load_source = "bogus" }, seams_unk2)
eq(st_unk2.skipped, 1, "the pass is skipped")
eq(#calls_unk.get + #calls_unk.post, 0, "and no request is dialed")

--------------------------------------------------------------------------
-- 13. WARN 去重（1 小时窗口）
--------------------------------------------------------------------------
new_case("the same failure warns once per hour, not once per tick")
reset_store()
eq(gpu_load.warn_dedup("prom", "http://prom:9090", "connection refused", 1000), true,
    "the first failure logs")
eq(gpu_load.warn_dedup("prom", "http://prom:9090", "connection refused", 2000), false,
    "the next tick stays quiet")
eq(gpu_load.warn_dedup("prom", "http://prom:9090", "refused", 1000 + 3599 * 1000), false,
    "still quiet a second before the window closes")
eq(gpu_load.warn_dedup("prom", "http://prom:9090", "refused", 1000 + 3601 * 1000), true,
    "and it speaks again once the hour has passed")
eq(gpu_load.warn_dedup("prom", "http://other:9090", "refused", 1000 + 3601 * 1000), true,
    "a different target is a different line")
eq(gpu_load.warn_dedup("metrics", "http://prom:9090", "refused", 1000 + 3601 * 1000), true,
    "and a different failure family too")
gpu_load.reset_warn_dedup()
eq(gpu_load.warn_dedup("prom", "http://prom:9090", "again", 1000), true,
    "the reset is what lets a re-configured source speak immediately")

new_case("a metrics pass that keeps failing does not spam the log")
reset_store()
local _, seams_spam = counting_seams({ workers = { TWO_WORKERS[1], TWO_WORKERS[3] } })
for _ = 1, 20 do
    gpu_load.run_pass({ load_source = "metrics" }, seams_spam)
end
eq(warn_lines(), 2, "one line per worker for twenty ticks of the same failure")

--------------------------------------------------------------------------
-- 14. 观测面与定时器接线
--------------------------------------------------------------------------
new_case("the pass publishes its counters through observability under nginx")
reset_store()
local _, seams_obs = counting_seams({
    workers = { { id = "a1", url = "http://gpu-a:8800" } },
    get = function() return { status = 200, body = "gpu_util 40\n" } end,
})
gpu_load.run_pass({ load_source = "none" }, seams_obs)
eq(next(stats_store), nil, "none writes no counter at all")
gpu_load.run_pass({ load_source = "metrics", load_metrics_keys = "gpu_util" }, seams_obs)
local saw_pass, saw_workers = false, false
for key, hit in pairs(stats_store) do
    if key:find("lr_gpu_load_pass_total", 1, true) then saw_pass = true end
    if key:find("lr_gpu_load_workers", 1, true) then
        saw_workers = true
        eq(hit.value, 1, "the gauge says one worker carries a sample")
    end
    if key:find("lr_gpu_load{", 1, true) then
        eq(hit.value, 0.4, "and the per-worker sample is exported verbatim")
    end
end
check(saw_pass, "the pass counter exists")
check(saw_workers, "the coverage gauge exists")
reset_store()
local _, seams_fail = counting_seams({ workers = { { id = "a1", url = "http://gpu-a:8800" } } })
gpu_load.run_pass({ load_source = "metrics" }, seams_fail)
local saw_fail = false
for key in pairs(stats_store) do
    if key:find("lr_gpu_load_failures_total", 1, true) then saw_fail = true end
end
check(saw_fail, "a failed scrape bumps the failure counter")
eq(gpu_load.last().failed, 1, "and the last pass is readable for /_ui")

new_case("start refuses every shape that should not run")
reset_store()
local ok_none, why_none = gpu_load.start({ load_source = "none" })
eq(ok_none, false, "none never starts a timer")
eq(why_none, "disabled (SMG_LOAD_SOURCE=none)",
    "with the one message hb.start keeps quiet about")
local ok_prom, why_prom = gpu_load.start(
    { load_source = "prom", load_prom_url = "", load_prom_query = "" })
eq(ok_prom, false, "prom without a url/query is refused rather than half-running")
check(type(why_prom) == "string", "and it says why", tostring(why_prom))
local ok_bogus, why_bogus = gpu_load.start({ load_source = "bogus" })
eq(ok_bogus, false, "an unrecognized source does not start either")
check(why_bogus:find("unknown", 1, true) ~= nil, "naming the reason", tostring(why_bogus))

new_case("a valid config starts the timer exactly once")
reset_store()
local scheduled = {}
ngx.timer = { at = function(delay, fn, ...)
    scheduled[#scheduled + 1] = { delay = delay, fn = fn }
    return true
end }
local ok_metrics, err_metrics = gpu_load.start({
    load_source = "metrics", load_interval_secs = 15, load_timeout_secs = 4,
})
eq(ok_metrics, true, "metrics starts")
eq(err_metrics, nil, "with nothing to complain about")
eq(#scheduled, 1, "one immediate tick")
eq(scheduled[1].delay, 0, "scheduled to run now")
check(gpu_load.timer_running(), "and the module knows it is running")
eq((gpu_load.start({ load_source = "metrics" })), true,
    "a second start is a no-op that reports ok")
eq(#scheduled, 1, "still one tick scheduled, not two")
local notice_logged = false
for i = 1, #log_lines do
    if log_lines[i].level == ngx.NOTICE then notice_logged = true end
end
check(notice_logged, "the start is announced once at NOTICE")
gpu_load.stop()
eq(gpu_load.timer_running(), false, "stop clears it (what the e2e flips on)")

new_case("a tick that cannot take the lock skips instead of stacking")
reset_store()
local ticks = {}
ngx.timer = { at = function(delay, fn, ...)
    ticks[#ticks + 1] = { delay = delay, fn = fn }
    return true
end }
-- Lock unavailable (timeout = 0 and the previous pass still holds it) -> quiet skip.
package.loaded["resty.lock"] = {
    new = function() return { lock = function() return nil, "timeout" end,
                              unlock = function() return true end } end,
}
gpu_load.stop()
eq((gpu_load.start({ load_source = "metrics", load_interval_secs = 15 })), true,
    "start still succeeds")
local before = #ticks
ticks[before].fn(false, { load_source = "metrics", load_interval_secs = 15 })
eq(#ticks, before + 1, "the pass rescheduled itself once")
eq(ticks[#ticks].delay, 15, "on the configured interval")
eq(warn_lines(), 0, "and a busy lock is not worth a warning")
package.loaded["resty.lock"] = nil
package.preload["resty.lock"] = function()
    return { new = function()
        return { lock = function() return true end, unlock = function() return true end }
    end }
end
gpu_load.stop()

io.write(string.format("\n=== %d checks, %d failed ===\n", passed, failed))
for i = 1, #failures do
    io.write("FAILED: " .. failures[i] .. "\n")
end
os.exit(failed == 0 and 0 or 1)
