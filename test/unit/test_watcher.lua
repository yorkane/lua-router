#!/usr/bin/env luajit
-- watcher.lua 单测：探针分类、候选发现、ledger、reconcile 九条守卫，以及第 10 条
-- 「确认不可用即摘除」的分档（确定性否定当轮摘／传输层未知攒连续失败／与对方无关的
-- 理由不判定）、滞回阈值与单轮保险丝。
--
-- 与 test_mesh.lua 同形状：先把 _G.ngx 摘掉再 require，watcher 在加载时记录
-- 「没有 ngx」，于是所有语义走注入的 fetch / reader / store / register 分支，
-- 不需要 nginx、不需要真端口。真实的 cosocket / docker socket / 定时器接线由
-- test/integration/e2e_watcher.py 在真容器里验。
--
-- 运行：
--   docker run --rm -v "$PWD:/repo:ro" -w /repo \
--     --entrypoint /usr/local/openresty/luajit/bin/luajit authz:latest \
--     -e 'package.cpath="/usr/local/openresty/lualib/?.so;"..package.cpath
--         package.path="/repo/lualib/?.lua;"..package.path
--         dofile("/repo/test/unit/test_watcher.lua")'
_G.ngx = nil

package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath
package.path = (os.getenv("LUA_TEST_LIB") or "./lualib") .. "/?.lua;" .. package.path

local cjson = require "cjson.safe"
local watcher = require "resty.luarouter.watcher"

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

--------------------------------------------------------------------------
-- 假 ngx.shared.DICT（ledger 只需要 get/set/delete/get_keys 四个方法）
--------------------------------------------------------------------------
local function mem_dict(initial)
    local store = {}
    for key, value in pairs(initial or {}) do
        store[key] = value
    end
    local self = {}
    function self:get(key)
        local hit = store[key]
        if hit == nil then
            return nil
        end
        return hit
    end
    local sets = {}
    function self:set(key, value, ttl)
        store[key] = value
        sets[key] = sets[key] or {}
        sets[key][#sets[key] + 1] = ttl
        return true
    end
    ---How many times a key was written (and with which ttl). Used to prove the
    ---ledger renews an owned entry on every pass instead of only on a change.
    function self.writes(key)
        return sets[key] or {}
    end
    function self:delete(key)
        store[key] = nil
    end
    function self:incr(key, delta, init)
        store[key] = (tonumber(store[key]) or init or 0) + delta
        return store[key]
    end
    function self:get_keys(n)
        local out = {}
        for key in pairs(store) do
            out[#out + 1] = key
        end
        table.sort(out)
        if n and n > 0 and #out > n then
            for i = n + 1, #out do
                out[i] = nil
            end
        end
        return out
    end
    function self.raw()
        return store
    end
    return self
end

--------------------------------------------------------------------------
-- 1. parse_model_map：env 形态与坏输入
--------------------------------------------------------------------------
new_case("parse_model_map")
do
    local map, ignored = watcher.parse_model_map("a:b, c:d ;e:f\ng:h")
    eq(map.a, "b", "comma entry")
    eq(map["c"], "d", "space-padded entry trimmed")
    eq(map.e, "f", "semicolon separator")
    eq(map.g, "h", "newline separator")
    eq(#ignored, 0, "no ignored entries")

    local m2, ig2 = watcher.parse_model_map("novalue,:only,also:,ok:new")
    eq(m2.ok, "new", "well-formed entry survives")
    eq(m2.novalue, nil, "missing colon ignored")
    eq(#ig2, 3, "three bad entries reported")

    local m3 = watcher.parse_model_map(nil)
    eq(next(m3) == nil, true, "nil spec yields an empty map")
    local m4 = watcher.parse_model_map(123)
    eq(next(m4) == nil, true, "non-string spec yields an empty map")
    -- the value may itself contain a colon (an http URL as a public id)
    local m5 = watcher.parse_model_map("orig:http://host:9/p")
    eq(m5.orig, "http://host:9/p", "first colon splits, rest is the value")
end

--------------------------------------------------------------------------
-- 2. parse_model_map_body：四种 POST 形态 + 坏输入 + 删除语义
--------------------------------------------------------------------------
new_case("parse_model_map_body")
do
    -- shape 1: plain object
    local m1 = watcher.parse_model_map_body('{"a.gguf":"a","b.gguf":"b"}')
    eq(m1 and m1["a.gguf"], "a", "plain object")
    -- shape 2: wrapped object
    local m2 = watcher.parse_model_map_body('{"map":{"a.gguf":"a"}}')
    eq(m2 and m2["a.gguf"], "a", "wrapped object")
    -- shape 3: bare pairs string
    local m3 = watcher.parse_model_map_body("a:b,c:d")
    eq(m3 and m3.a, "b", "bare pairs")
    eq(m3 and m3.c, "d", "bare pairs second entry")
    -- shape 4: pairs string inside the wrapper. This is the historical trap: it
    -- used to fall into the object branch and store the literal key "map".
    local m4 = watcher.parse_model_map_body('{"map":"x.gguf:x,y.gguf:y"}')
    eq(m4 and m4["x.gguf"], "x", "wrapped pairs string unwrapped")
    eq(m4 and m4["y.gguf"], "y", "wrapped pairs second entry")
    eq(m4 and m4.map, nil, "no literal `map` key stored")

    -- delete semantics: an empty new id deletes
    local m5 = watcher.parse_model_map_body('{"a.gguf":""}')
    eq(m5 and m5["a.gguf"], "", "empty value arrives as the delete marker")
    local m6 = watcher.parse_model_map_body('{"a.gguf":null}')
    eq(m6 and m6["a.gguf"], "", "JSON null is also the delete marker")
    -- {"map":""} stays in the object branch so the literal "map" key is deleted
    local m7 = watcher.parse_model_map_body('{"map":""}')
    eq(m7 and m7.map, "", "empty wrapper deletes the literal map key")
    local m8 = watcher.parse_model_map_body("{}")
    eq(type(m8) == "table", true, "empty object is accepted")

    -- bad input
    local bad1, err1 = watcher.parse_model_map_body("")
    eq(bad1, nil, "empty body rejected")
    check(err1 and err1.error ~= nil, "empty body names a reason")
    local bad2, err2 = watcher.parse_model_map_body("novalue;also-bad")
    eq(bad2, nil, "pairs without a colon rejected")
    eq(err2 and #err2.ignored, 2, "offending entries are listed")
    local bad3, err3 = watcher.parse_model_map_body("{not json")
    eq(bad3, nil, "malformed JSON rejected")
    check(err3 and err3.error ~= nil, "malformed JSON names a reason")
end

--------------------------------------------------------------------------
-- 3. merge_map：合并而不是替换 + 删除计数
--------------------------------------------------------------------------
new_case("merge_map")
do
    local merged, deleted = watcher.merge_map({ a = "1", b = "2" }, { b = "3", c = "4" })
    eq(merged.a, "1", "existing entry kept")
    eq(merged.b, "3", "incoming entry wins")
    eq(merged.c, "4", "new entry added")
    eq(deleted, 0, "nothing deleted")
    local merged2, deleted2 = watcher.merge_map({ a = "1", b = "2" }, { b = "" })
    eq(merged2.b, nil, "empty value deletes")
    eq(deleted2, 1, "one entry deleted")
    local merged3, deleted3 = watcher.merge_map({ a = "1" }, { gone = "" })
    eq(deleted3, 0, "deleting an absent entry is not counted")
    eq(merged3.a, "1", "delete of an absent key leaves the map intact")
end

--------------------------------------------------------------------------
-- 4. url 形态与自排除（守卫 1 的端口那一半）
--------------------------------------------------------------------------
new_case("normalize_url / split_http / is_self_url")
do
    eq(watcher.normalize_url("127.0.0.1:8000"), "http://127.0.0.1:8000",
        "scheme added")
    eq(watcher.normalize_url("http://H:8000/"), "http://h:8000",
        "host lowered, path and trailing slash dropped")
    eq(watcher.normalize_url("http://h:80"), "http://h", "default http port dropped")
    eq(watcher.normalize_url("https://h:443"), "https://h", "default https port dropped")
    eq(watcher.normalize_url("http://[::1]:8000"), "http://[::1]:8000",
        "bracketed ipv6 kept")
    eq(watcher.normalize_url("ftp://h:21"), nil, "non-http scheme rejected")
    eq(watcher.normalize_url(""), nil, "empty rejected")
    eq(watcher.normalize_url(nil), nil, "nil rejected")

    local scheme, host, port = watcher.split_http("http://127.0.0.1:30000")
    eq(scheme, "http", "split scheme")
    eq(host, "127.0.0.1", "split host")
    eq(port, 30000, "split port")
    local _, _, p80 = watcher.split_http("http://example.com")
    eq(p80, 80, "missing port resolves to the scheme default")

    check(watcher.is_self_url("http://127.0.0.1:30000", { 30000, 29000 }),
        "own port on loopback is self")
    check(watcher.is_self_url("http://localhost:29000", { 30000, 29000 }),
        "metrics port on localhost is self")
    check(not watcher.is_self_url("http://127.0.0.1:8000", { 30000, 29000 }),
        "another loopback port is not self")
    check(not watcher.is_self_url("http://10.0.0.5:30000", { 30000 }),
        "same port on a LAN address is a different deployment")
    check(watcher.is_self_url("http://[::1]:30000", { 30000 }),
        "ipv6 loopback counts as self")
end

--------------------------------------------------------------------------
-- 5. model_name：short 名 + 映射优先
--------------------------------------------------------------------------
new_case("model_name")
do
    eq(watcher.model_name("/models/foo.gguf", nil, true), "foo",
        "short names strips the path and the suffix")
    eq(watcher.model_name("/models/foo.gguf", nil, false), "/models/foo.gguf",
        "without short the advertised id is used verbatim")
    eq(watcher.model_name("/models/foo.gguf", { ["/models/foo.gguf"] = "p2" }, false),
        "p2", "a raw-keyed map hits when short is off")
    eq(watcher.model_name("/models/foo.gguf", { ["/models/foo.gguf"] = "public" }, true),
        "public", "map keyed on the raw id wins")
    eq(watcher.model_name("/models/foo.gguf", { foo = "public" }, true), "public",
        "map keyed on the short name wins")
    eq(watcher.model_name("plain", { other = "x" }, false), "plain",
        "unrelated map leaves the id alone")
    eq(watcher.model_name("/models/a.bin", nil, true), "a", ".bin suffix stripped")
    eq(watcher.model_name("/", nil, true), "/",
        "a name that would become empty falls back to the raw id")
end

--------------------------------------------------------------------------
-- 6. 其它 env 解析小件
--------------------------------------------------------------------------
new_case("parse_ports / gpu_from_name / is_excluded")
do
    local ports = watcher.parse_ports("8000-8002,11434")
    eq(ports[8000] and ports[8001] and ports[8002] and ports[11434], true,
        "range and single port both parsed")
    eq(ports[8003], nil, "range is inclusive of its bounds only")
    eq(next(watcher.parse_ports(nil)) == nil, true, "nil spec yields an empty set")
    eq(watcher.gpu_from_name("pennyroyal-gpu7"), "7", "gpu id out of a container name")
    eq(watcher.gpu_from_name("qwen3.8-flashnext-gpu45"), "45", "two-digit gpu id")
    eq(watcher.gpu_from_name("sglang-router"), nil, "no hint means nil")
    check(watcher.is_excluded("http://10.0.0.9:9100/metrics", { "9100" }),
        "substring pattern excludes")
    check(watcher.is_excluded("http://a:9100/metrics.host", { "%.host" }),
        "lua pattern class excluded")
    check(not watcher.is_excluded("http://a:8000/v1/models", { "9100" }),
        "non-matching url kept")
    check(not watcher.is_excluded("http://a:8000", nil), "nil patterns keep everything")
    -- a pattern Lua rejects falls back to a literal substring match
    check(watcher.is_excluded("http://node[exporter:9", { "node[exporter" }),
        "unbalanced bracket retried as a plain substring")
end

--------------------------------------------------------------------------
-- 7. 探针分类（守卫 1 的指纹那一半 + 守卫 2 + 聚合器排除）
--------------------------------------------------------------------------
new_case("classify")
do
    local function fake(routes)
        return function(url)
            for prefix, reply in pairs(routes) do
                if string.sub(url, 1, #prefix) == prefix then
                    if type(reply) == "table" then
                        return reply[1], reply[2]
                    end
                    return reply
                end
            end
            return nil, nil, "connection refused"
        end
    end
    local base = "http://10.0.0.1:8000"

    -- 守卫 2：/v1/models 必须给出 OpenAI JSON
    local models = '{"object":"list","data":[{"id":"qwen","object":"model"}]}'
    local info, reason = watcher.classify(base, {
        fetch = fake({ [base .. "/v1/models"] = { 200, models },
                       [base .. "/health"] = { 200, "OK" } }),
        max_models = 8,
    })
    check(info ~= nil, "an OpenAI endpoint is accepted", reason)
    eq(info and info.models[1], "qwen", "advertised id captured")
    eq(info and info.has_health, true, "usable /health recorded")

    local none1 = watcher.classify(base, { fetch = fake({}) })
    eq(none1, nil, "connection refused rejected")
    local none2 = watcher.classify(base, { fetch = fake({
        [base .. "/v1/models"] = { 404, "<html>not found</html>" } }) })
    eq(none2, nil, "html 404 rejected")
    local none3 = watcher.classify(base, { fetch = fake({
        [base .. "/v1/models"] = { 200, '{"ok":true}' } }) })
    eq(none3, nil, "JSON without data[].id rejected (node_exporter shape)")
    local none4 = watcher.classify(base, { fetch = fake({
        [base .. "/v1/models"] = { 200, '{"data":[]}' } }) })
    eq(none4, nil, "empty data[] rejected")

    -- 聚合器排除（默认 max-models 8）
    local many_ids = {}
    for i = 1, 9 do
        many_ids[#many_ids + 1] = string.format('{"id":"m%d"}', i)
    end
    local many = '{"data":[' .. table.concat(many_ids, ",") .. "]}"
    local agg = watcher.classify(base, {
        fetch = fake({ [base .. "/v1/models"] = { 200, many },
                       [base .. "/health"] = { 200, "OK" } }),
        max_models = 8,
    })
    eq(agg, nil, "nine models look like a proxy and are skipped")
    local off = watcher.classify(base, {
        fetch = fake({ [base .. "/v1/models"] = { 200, many },
                       [base .. "/health"] = { 200, "OK" } }),
        max_models = 0,
    })
    check(off ~= nil, "max_models=0 disables the ceiling")

    -- 守卫 1：另一个 router 的指纹
    local router_body = '{"router_manager":false,"workers_count":3,"routers_count":1}'
    local router = watcher.classify(base, {
        fetch = fake({ [base .. "/v1/models"] = { 200, models },
                       [base .. "/server_info"] = { 200, router_body },
                       [base .. "/health"] = { 200, "OK" } }),
        max_models = 8,
    })
    eq(router, nil, "a candidate answering /server_info with router keys is refused")

    -- /health 与 /metrics 双 5xx 判活语义
    local gateway = watcher.classify(base, {
        fetch = fake({ [base .. "/v1/models"] = { 200, models },
                       [base .. "/health"] = { 502, "bad gateway" },
                       [base .. "/metrics"] = { 503, "unavailable" } }),
        max_models = 8,
    })
    eq(gateway, nil, "/v1/models answers while /health and /metrics both 5xx: a gateway")
    local gateway_ok = watcher.classify(base, {
        fetch = fake({ [base .. "/v1/models"] = { 200, models },
                       [base .. "/health"] = { 502, "bad gateway" },
                       [base .. "/metrics"] = { 503, "unavailable" } }),
        max_models = 8, allow_models_only = true,
    })
    check(gateway_ok ~= nil, "allow_models_only opts into that shape")
    local single = watcher.classify(base, {
        fetch = fake({ [base .. "/v1/models"] = { 200, models },
                       [base .. "/health"] = { 404, "no route" },
                       [base .. "/metrics"] = { 503, "unavailable" } }),
        max_models = 8,
    })
    check(single ~= nil, "only a 404 on /health is not the gateway signal")
    local no_health = watcher.classify(base, {
        fetch = fake({ [base .. "/v1/models"] = { 200, models },
                       [base .. "/health"] = { 404, "no route" } }),
        max_models = 8, require_health = true,
    })
    eq(no_health, nil, "require_health refuses a service with no /health")

    -- 引擎嗅探只用于 label
    local sglang = watcher.classify(base, {
        fetch = fake({ [base .. "/v1/models"] = { 200, models },
                       [base .. "/get_server_info"] = { 200, '{"tp_size":4}' },
                       [base .. "/health"] = { 200, "OK" } }),
        max_models = 8,
    })
    eq(sglang and sglang.engine, "sglang", "get_server_info identifies sglang")
    local vllm = watcher.classify(base, {
        fetch = fake({ [base .. "/v1/models"] = { 200, models },
                       [base .. "/metrics"] = { 200, "vllm:num_requests_running 1\n" },
                       [base .. "/health"] = { 200, "OK" } }),
        max_models = 8,
    })
    eq(vllm and vllm.engine, "vllm", "vllm: metrics identify vllm")
    local llama = watcher.classify(base, {
        fetch = fake({ [base .. "/v1/models"] = { 200, models },
                       [base .. "/props"] = { 200, '{"build_commit":"abc"}' },
                       [base .. "/health"] = { 200, "OK" } }),
        max_models = 8,
    })
    eq(llama and llama.engine, "llama.cpp", "/props identifies llama.cpp")
    local plain = watcher.classify(base, {
        fetch = fake({ [base .. "/v1/models"] = { 200, models },
                       [base .. "/health"] = { 200, "OK" } }),
        max_models = 8,
    })
    eq(plain and plain.engine, "openai", "no engine signal stays generic openai")
end

--------------------------------------------------------------------------
-- 8. /proc 解析（守卫 9：纯读文件，不起进程）
--------------------------------------------------------------------------
new_case("listening_sockets")
do
    local v4 = "  sl  local_address rem_address   st tx_queue\n"
        .. "   0: 0100007F:1F40 00000000:0000 0A 00000000:00000000 00:00000000\n"
        .. "   1: 00000000:1F41 00000000:0000 0A 00000000:00000000 00:00000000\n"
        .. "   2: 0100007F:1F42 0100007F:FFFFF 01 00000000:00000000 00:00000000\n"
    local v6 = "  sl  local_address rem_address   st tx_queue\n"
        .. "   0: 00000000000000000000000000000000:1F40 00000000000000000000000000000000:0000 0A\n"
        .. "   1: 0000000000000000FFFF00000100007F:2328 00000000000000000000000000000000:0000 0A\n"
        .. "   2: 00000000000000000000000001000000:1F43 00000000000000000000000000000000:0000 0A\n"
        .. "   3: b80d0120000000000000000001000000:1F44 00000000000000000000000000000000:0000 0A\n"
    local sockets = watcher.listening_sockets(function(path)
        if path == "/proc/net/tcp" then return v4 end
        if path == "/proc/net/tcp6" then return v6 end
        return nil
    end)
    local by_key = {}
    for i = 1, #sockets do
        by_key[sockets[i].host .. ":" .. sockets[i].port] = true
    end
    check(by_key["127.0.0.1:8000"], "v4 loopback little-endian hex decoded")
    check(by_key["0.0.0.0:8001"], "v4 wildcard decoded")
    check(not by_key["127.0.0.1:8002"], "an ESTABLISHED socket is not a listener")
    check(by_key[":::8000"], "v6 wildcard decoded")
    check(by_key["127.0.0.1:9000"], "v6-mapped v4 address decoded to dotted quad")
    check(by_key["::1:8003"], "v6 loopback decoded (words byte-swapped first)")
    check(by_key["2001:db8:0:0:0:0:0:1:8004"],
        "a global v6 address is byte-swapped per 32-bit word and grouped")

    -- unreadable /proc must not raise (a sandbox without the files)
    local empty = watcher.listening_sockets(function() return nil end)
    eq(#empty, 0, "missing /proc yields no sockets")
end

--------------------------------------------------------------------------
-- 9. docker 候选（含 container-IP 去重）
--------------------------------------------------------------------------
new_case("docker_candidates_from")
do
    local containers = {
        {
            Id = "aaa",
            Names = { "/qwen-gpu3" },
            Ports = {
                { IP = "0.0.0.0", PrivatePort = 8000, PublicPort = 18000, Type = "tcp" },
            },
            NetworkSettings = { Networks = { bridge = {
                IPAddress = "172.17.0.3", Ports = { ["8000/tcp"] = nil } } } },
        },
        {
            Id = "bbb",
            Names = { "/hostnet" },
            HostConfig = { NetworkMode = "host" },
            Ports = {},
            NetworkSettings = { Networks = { host = { IPAddress = "10.0.0.9" } } },
        },
        {
            Id = "ccc",
            Names = { "/unpublished" },
            Ports = {},
            NetworkSettings = { Networks = { mynet = {
                IPAddress = "172.18.0.4", Ports = { ["8080/tcp"] = {} } } } },
        },
    }
    local cands, port_names = watcher.docker_candidates_from(containers, true)
    local urls = {}
    for i = 1, #cands do
        urls[cands[i].url] = cands[i]
    end
    local pub = urls["http://127.0.0.1:18000"]
    check(pub ~= nil, "published port becomes a loopback candidate")
    eq(pub and pub.label, "qwen-gpu3", "container name carried as the label")
    eq(pub and pub.gpu, "3", "gpu id parsed out of the name")
    eq(pub and pub.source, "docker", "source is docker")
    eq(port_names[18000], "qwen-gpu3", "port -> name map for the proc scan")
    eq(urls["http://172.17.0.3:8000"], nil,
        "a container port the host publishes is not duplicated as docker-net")
    eq(urls["http://10.0.0.9:8080"], nil, "host-network containers get no container-IP candidate")
    local extra = urls["http://172.18.0.4:8080"]
    check(extra ~= nil, "an unpublished container port is reachable by container IP")
    eq(extra and extra.source, "docker-net", "source is docker-net")
    local no_ips = watcher.docker_candidates_from({ containers[3] }, false)
    eq(#no_ips, 0, "scan_container_ips=false drops the docker-net half")
    eq(#watcher.docker_candidates_from(nil, true), 0, "a failed docker call yields nothing")
end

--------------------------------------------------------------------------
-- 10. local_candidates 与去重优先级
--------------------------------------------------------------------------
new_case("local_candidates / unique_candidates")
do
    local sockets = {
        { host = "0.0.0.0", port = 8000 },
        { host = "::", port = 8001 },
        { host = "127.0.0.1", port = 8002 },
        { host = "10.0.0.5", port = 8003 },
        { host = "::1", port = 8004 },
    }
    local cands = watcher.local_candidates(sockets, { [8003] = true }, nil)
    local urls = {}
    for i = 1, #cands do
        urls[cands[i].url] = cands[i]
    end
    check(urls["http://127.0.0.1:8000"] ~= nil, "wildcard bind probed through loopback")
    check(urls["http://127.0.0.1:8001"] ~= nil, "ipv6 wildcard probed through loopback")
    check(urls["http://127.0.0.1:8002"] ~= nil, "explicit loopback kept")
    eq(urls["http://10.0.0.5:8003"], nil, "a denied port is dropped")
    check(urls["http://[::1]:8004"] ~= nil, "ipv6 literal bracketed")
    eq(cands[1].source, "proc", "source is proc")

    local narrowed = watcher.local_candidates(sockets, nil, { [8002] = true })
    eq(#narrowed, 1, "allow_ports probes only those ports")
    eq(narrowed[1].url, "http://127.0.0.1:8002", "the allowed port survives")

    local merged = watcher.unique_candidates({
        { { url = "http://127.0.0.1:18000", source = "proc" } },
        { { url = "http://127.0.0.1:18000", source = "docker", label = "ctr" } },
        { { url = "http://127.0.0.1:8000", source = "cli", label = "static" } },
    })
    eq(#merged, 2, "one URL collapses to one candidate")
    eq(merged[1].url, "http://127.0.0.1:18000", "docker sorts ahead of cli")
    eq(merged[1].source, "docker", "the most specific source wins")
    eq(merged[1].label, "ctr", "and it carries that source's label")
end

--------------------------------------------------------------------------
-- 11. ledger（shdict 上的键空间）
--------------------------------------------------------------------------
new_case("new_ledger")
do
    local d = mem_dict()
    local ledger = watcher.new_ledger(d)
    eq(ledger.touched(), false, "a fresh ledger is untouched")
    ledger.mark_touched()
    eq(ledger.touched(), true, "the first-contact marker sticks")

    eq(ledger.is_protected("http://a"), false, "unprotected to start")
    ledger.protect("http://a")
    eq(ledger.is_protected("http://a"), true, "protection stored")
    eq(ledger.protected_urls()["http://a"], true, "protection enumerated")
    ledger.unprotect("http://a")
    eq(ledger.is_protected("http://a"), false, "unprotect (the rename hand-off)")

    ledger.set_owned("http://a", { model_id = "m", worker_id = "id-a" }, 3600)
    eq(ledger.get_owned("http://a").model_id, "m", "owned entry round-trips")
    eq(ledger.owned_urls()["http://a"].worker_id, "id-a", "owned set enumerated")
    ledger.drop_owned("http://a")
    eq(ledger.get_owned("http://a"), nil, "drop clears the entry")

    ledger.set_pending("http://a", { queued_at = 100, worker_id = "id-a" }, 200)
    eq(ledger.get_pending("http://a").queued_at, 100, "pending add stored")
    eq(ledger.pending_urls()["http://a"].worker_id, "id-a", "pending set enumerated")
    ledger.drop_pending("http://a")
    eq(ledger.get_pending("http://a"), nil, "pending dropped")

    local until_ts = ledger.set_backoff("http://a", 1, 1000)
    eq(until_ts, 1060, "back-off is 30 * 2^n seconds")
    eq(ledger.get_backoff("http://a").until_ts, 1060, "back-off read back")
    local capped = ledger.set_backoff("http://b", 9, 1000)
    eq(capped, 1900, "back-off capped at 900 s")
    ledger.drop_backoff("http://a")
    eq(ledger.get_backoff("http://a"), nil, "back-off dropped on success")

    ledger.set_map({ a = "b" })
    eq(ledger.map().a, "b", "rename map persisted in the dict")
    eq(next(watcher.new_ledger(mem_dict()).map()) == nil, true, "empty dict gives an empty map")
end

--------------------------------------------------------------------------
-- 12. keep-last 判定
--------------------------------------------------------------------------
new_case("is_last_for_model")
do
    local actual = {
        ["http://a"] = { model_id = "m1", is_healthy = true },
        ["http://b"] = { model_id = "m1", is_healthy = true },
        ["http://c"] = { model_id = "m2", is_healthy = false },
    }
    eq(watcher.is_last_for_model("m1", "http://a", actual), false,
        "a healthy sibling is coverage")
    eq(watcher.is_last_for_model("m2", "http://c", actual), true,
        "an unhealthy sibling is not coverage")
    eq(watcher.is_last_for_model("m3", "http://z", actual), true,
        "a model with nothing else is the last")
    eq(watcher.is_last_for_model("", "http://a", actual), true,
        "an unknown model id is treated as last (safe default)")
end

--------------------------------------------------------------------------
-- reconcile 夹具：候选、探针结果、池、注册/删除回调
--------------------------------------------------------------------------
local function harness(overrides)
    local env = {
        now = 1000,
        d = mem_dict(),
        log = {},
        registered = {},
        unregistered = {},
        probed = {},
        -- 按 URL 指定「探针这一轮给出的失败理由」（classify 的第二返回值）。
        -- 分档测试全靠它：不写 reason 的老夹具等于「传输层未知」，要两轮才摘。
        probe_reason = {},
    }
    env.cfg = {
        enabled = true,
        self_ports = { 30000, 29000 },
        interval_secs = 15,
        probe_timeout_secs = 4,
        remove_grace_secs = 300,
        keep_last_grace_secs = 1800,
        add_confirm_timeout_secs = 180,
        max_models = 8,
        allow_remove = true,
        short_model_names = false,
        exclude_patterns = {},
        allow_ports = {},
        deny_ports = {},
    }
    for key, value in pairs(overrides or {}) do
        env[key] = value
    end
    env.ledger = watcher.new_ledger(env.d)
    env.state = {
        cfg = env.cfg,
        ledger = env.ledger,
        now = env.now,
        actual = env.actual or {},
        candidates = env.candidates or {},
        model_map = env.model_map or {},
        entry_ttl = 86400,
        probe = function(url)
            local entry = env.probed[url]
            if entry == nil then
                return nil, env.probe_reason[url]
            end
            return {
                url = url, models = entry.models or { "m" },
                engine = entry.engine or "openai",
                has_health = entry.has_health ~= false,
            }
        end,
        register = function(url, model_id, info)
            if env.register_fails then
                return nil, "mock add rejected"
            end
            local id = "id-" .. url
            env.registered[#env.registered + 1] = {
                url = url, model_id = model_id, id = id,
                disable_health_check = info.has_health == false or nil,
                engine = info.engine,
            }
            return id
        end,
        unregister = function(worker_id)
            local url = env.id_to_url and env.id_to_url[worker_id]
            if env.delete_fails then
                return false
            end
            env.unregistered[#env.unregistered + 1] = worker_id
            if url and env.actual then
                env.state.actual[url] = nil
            end
            return true
        end,
        stats = { reconciles = 0, adds = 0, add_fails = 0, removes = 0,
                  discovered = 0, adds_stuck_released = 0 },
        log = function(level, message)
            env.log[#env.log + 1] = { level = level, message = message }
        end,
    }
    return env
end

local function candidate(url, source, label, gpu)
    return { url = url, source = source or "cli", label = label, gpu = gpu }
end

local function models_of(url, model_id)
    return { [url] = { id = "id-" .. url, url = url,
                       model_id = model_id, is_healthy = true } }
end

local function count_in(list, value, field)
    local n = 0
    for i = 1, #list do
        if (field and list[i][field]) == value then
            n = n + 1
        end
    end
    return n
end

--------------------------------------------------------------------------
-- 13. 守卫 3：首接触快照 protected，永不删
--------------------------------------------------------------------------
new_case("guard 3 first-contact protection")
do
    local pool = {}
    for url, model in pairs({ ["http://seed:8000"] = "seed-model",
                              ["http://hand:8001"] = "hand-model" }) do
        for k, v in pairs(models_of(url, model)) do
            pool[k] = v
        end
    end
    local env = harness({ actual = pool, candidates = {
        candidate("http://seed:8000"), candidate("http://hand:8001") } })
    env.probed["http://seed:8000"] = { models = { "seed-model" } }
    env.probed["http://hand:8001"] = { models = { "hand-model" } }
    watcher.reconcile(env.state)
    eq(env.ledger.is_protected("http://seed:8000"), true, "seed worker protected")
    eq(env.ledger.is_protected("http://hand:8001"), true, "hand-added worker protected")
    eq(#env.registered, 0, "protected workers are not re-registered")
    eq(#env.unregistered, 0, "protected workers are not deleted")

    -- they still stop being candidates: a later pass must not add them
    local stats = watcher.reconcile(env.state)
    eq(stats.discovered, 2, "still discovered")
    eq(#env.registered, 0, "protected URLs stay out of the desired set")

    -- and a protected URL that disappears is not deleted either
    env.state.actual["http://seed:8000"] = nil
    env.now = env.now + 100000
    env.state.now = env.now
    env.probed["http://seed:8000"] = nil
    watcher.reconcile(env.state)
    eq(#env.unregistered, 0, "a vanished protected worker is never deleted")
end

--------------------------------------------------------------------------
-- 14. 注册 diff + 守卫 5 grace + 守卫 4 只删自己的
--------------------------------------------------------------------------
new_case("guards 4/5 add, grace period, own-ledger removal")
do
    local env = harness({ candidates = { candidate("http://new:8000", "proc") } })
    -- keep-last off (SMG_WATCHER_KEEP_LAST=false) so this case measures guard 5
    -- alone: an undiscovered owned worker is deleted once the grace elapsed.
    env.cfg.keep_last_grace_secs = -1
    env.probed["http://new:8000"] = { models = { "fresh" }, engine = "vllm" }
    local stats = watcher.reconcile(env.state)
    eq(stats.adds, 1, "a discovered worker is registered once")
    eq(env.registered[1].model_id, "fresh", "registered under its advertised id")
    eq(env.registered[1].engine, "vllm", "engine carried to the register callback")
    eq(env.ledger.get_owned("http://new:8000").model_id, "fresh", "ledger owns the URL")
    eq(env.state.actual["http://new:8000"], nil,
        "the pass does not fake the pool: registration is the caller's effect")

    -- The pool now shows it (as registry.add would). Second pass: nothing to do.
    env.state.actual = models_of("http://new:8000", "fresh")
    env.state.actual["http://new:8000"].id = env.registered[1].id
    watcher.reconcile(env.state)
    eq(#env.registered, 1, "no duplicate add for a URL already in the pool")

    -- it is now owned, not protected: the first-contact snapshot skipped it
    eq(env.ledger.is_protected("http://new:8000"), false, "owned is not protected")

    -- Undiscovered (not "probe failed"): the discovery source stops reporting
    -- the URL, so the probe never runs. That is what guard 5 is about -- a short
    -- restart must not empty the pool. A URL that is still a candidate but fails
    -- the probe is a different case (confirmed unavailable, removed at once) and
    -- lives in the probe-failure case further down.
    env.now = 2000
    env.state.now = env.now
    env.state.candidates = {}
    watcher.reconcile(env.state)
    eq(#env.unregistered, 0, "inside remove-grace nothing is deleted")
    eq(env.ledger.get_owned("http://new:8000").missing_since, 2000,
        "missing_since stamped on the first absent pass")

    -- grace elapsed -> delete, exactly once
    env.now = 2301
    env.state.now = env.now
    watcher.reconcile(env.state)
    eq(#env.unregistered, 1, "after remove-grace the owned worker is deleted")
    eq(env.unregistered[1], "id-http://new:8000", "deleted by the id it registered under")
    eq(env.ledger.get_owned("http://new:8000"), nil, "the ledger forgets it")

    -- a worker someone else added is never a deletion target (guard 4)
    local env2 = harness({
        actual = models_of("http://other:8000", "theirs"),
        candidates = {},
    })
    env2.now = 999999
    env2.state.now = env2.now
    watcher.reconcile(env2.state)
    eq(#env2.unregistered, 0, "a pool worker with no ledger entry is untouched")

    -- a worker the pool dropped on its own is just forgotten, not deleted twice
    local env3 = harness({ candidates = { candidate("http://gone:8000") } })
    env3.cfg.keep_last_grace_secs = -1
    env3.probed["http://gone:8000"] = { models = { "m" } }
    watcher.reconcile(env3.state)
    -- confirm the add first (otherwise this is the stuck-add path, tested above)
    env3.state.actual = models_of("http://gone:8000", "m")
    watcher.reconcile(env3.state)
    -- then someone else deleted it from the pool and discovery stopped seeing it
    env3.state.actual = {}
    env3.probed["http://gone:8000"] = nil
    env3.now = env3.now + 400
    env3.state.now = env3.now
    watcher.reconcile(env3.state)
    eq(#env3.unregistered, 0, "already absent from the pool: nothing to delete")
    eq(env3.ledger.get_owned("http://gone:8000"), nil, "and the ledger forgets it")
end

--------------------------------------------------------------------------
-- 15. 守卫 6：keep-last
--------------------------------------------------------------------------
new_case("guard 6 keep-last")
do
    local url = "http://solo:8000"
    local env = harness({ candidates = { candidate(url) } })
    env.probed[url] = { models = { "only-model" } }
    watcher.reconcile(env.state)
    env.state.actual = models_of(url, "only-model")
    watcher.reconcile(env.state)

    -- It disappears from discovery (not "probe failed" -- a candidate that is
    -- still reported but unreadable is removed at once, see the probe-failure
    -- case; keep-last is about a service that stopped being reported at all):
    -- the first absent pass only stamps missing_since.
    env.probed[url] = nil
    env.state.candidates = {}
    env.now = 2000
    env.state.now = env.now
    watcher.reconcile(env.state)
    eq(env.ledger.get_owned(url).missing_since, 2000, "first absent pass stamps it")
    eq(#env.unregistered, 0, "and deletes nothing")

    -- past remove-grace, but it is the last worker of its model: keep it, warn once
    env.now = 2400
    env.state.now = env.now
    local stats = watcher.reconcile(env.state)
    eq(#env.unregistered, 0, "the last worker of a model survives remove-grace")
    eq(stats.removes, 0, "no removal counted")
    local warned = 0
    for i = 1, #env.log do
        if string.find(env.log[i].message, "last worker", 1, true) then
            warned = warned + 1
        end
    end
    eq(warned, 1, "the keep-last decision is logged once")
    env.now = 2500
    env.state.now = env.now
    watcher.reconcile(env.state)
    local warned2 = 0
    for i = 1, #env.log do
        if string.find(env.log[i].message, "last worker", 1, true) then
            warned2 = warned2 + 1
        end
    end
    eq(warned2, 1, "and is not repeated on every pass")

    -- a sibling for the same model means it is no longer last: delete on time
    env.probed["http://sibling:8001"] = { models = { "only-model" } }
    env.candidates[#env.candidates + 1] = candidate("http://sibling:8001")
    env.state.actual["http://sibling:8001"] =
        models_of("http://sibling:8001", "only-model")["http://sibling:8001"]
    env.now = 3000
    env.state.now = env.now
    watcher.reconcile(env.state)
    eq(#env.unregistered, 1, "with a sibling present the dead worker goes")

    -- and the keep-last protection itself expires (keep_last_grace)
    local env2 = harness({ candidates = { candidate(url) } })
    env2.cfg.keep_last_grace_secs = 1800
    env2.probed[url] = { models = { "only-model" } }
    watcher.reconcile(env2.state)
    env2.state.actual = models_of(url, "only-model")
    watcher.reconcile(env2.state)
    -- 发现源消失（不是探针失败）：清空 candidates，探针压根不会被拨。
    -- 只置 probed[url] = nil 测的是「仍是候选但读不到 /v1/models」=确认不可用，
    -- 那条路径不等宽限、也不受 keep-last 保护（见文件末尾的探针失败用例），
    -- 两个状态必须区分，否则这里测的就不再是守卫 5/6。
    env2.probed[url] = nil
    env2.state.candidates = {}
    env2.now = 1500
    env2.state.now = env2.now
    watcher.reconcile(env2.state)            -- stamps missing_since = 1500
    env2.now = 1500 + 301
    env2.state.now = env2.now
    watcher.reconcile(env2.state)
    eq(#env2.unregistered, 0, "keep-last holds before its own grace elapses")
    env2.now = 1500 + 1801
    env2.state.now = env2.now
    watcher.reconcile(env2.state)
    eq(#env2.unregistered, 1, "after keep-last-grace even the last worker is removed")

    -- keep_last_grace_secs = 0 means "protect forever" (the daemon's old behaviour)
    local env3 = harness({ candidates = { candidate(url) } })
    env3.cfg.keep_last_grace_secs = 0
    env3.probed[url] = { models = { "only-model" } }
    watcher.reconcile(env3.state)
    env3.state.actual = models_of(url, "only-model")
    -- 认领：pass 1 只把 add 挂成 pending，必须再走一轮才是 owned；
    -- 且 unregister 靠 id_to_url 才会真删池行（否则「留在池里」是夹具假象）。
    env3.id_to_url = { ["id-" .. url] = url }
    watcher.reconcile(env3.state)
    env3.probed[url] = nil
    -- 同上：这条测的是「发现源消失 + keep-last 永久保护」，必须清空 candidates。
    env3.state.candidates = {}
    env3.now = 5000
    env3.state.now = env3.now
    watcher.reconcile(env3.state)            -- stamps
    env3.now = 10 ^ 7
    env3.state.now = env3.now
    watcher.reconcile(env3.state)
    eq(#env3.unregistered, 0, "keep_last_grace_secs=0 never removes the last worker")
end

--------------------------------------------------------------------------
-- 15b. ledger 条目每轮续期（shdict 有 TTL，漏写就等于永久失去回收能力）
--------------------------------------------------------------------------
new_case("owned entries are renewed every pass")
do
    local url = "http://steady:8000"
    local env = harness({ candidates = { candidate(url) } })
    env.probed[url] = { models = { "m" } }
    watcher.reconcile(env.state)                       -- registers
    env.state.actual = models_of(url, "m")
    for pass = 1, 5 do
        env.now = env.now + 15
        env.state.now = env.now
        watcher.reconcile(env.state)                   -- steady state
    end
    local writes = env.d.writes("o|" .. url)
    check(#writes >= 6, "the owned entry is rewritten on every pass",
        "writes=" .. #writes)
    local ttl = writes[1]
    eq(ttl, 86400, "and each rewrite carries the entry ttl")
    eq(env.ledger.get_owned(url).worker_id, "id-" .. url,
        "the entry is still readable after the passes")
    eq(#env.unregistered, 0, "a healthy owned worker is not disturbed")
end

--------------------------------------------------------------------------
-- 16. allow_remove=false 只警告
--------------------------------------------------------------------------
new_case("allow_remove false")
do
    local url = "http://keep:8000"
    local env = harness({ candidates = { candidate(url) } })
    env.cfg.allow_remove = false
    env.probed[url] = { models = { "m" } }
    watcher.reconcile(env.state)
    env.state.actual = models_of(url, "m")
    env.id_to_url = { ["id-" .. url] = url }
    watcher.reconcile(env.state)             -- 认领：pending -> owned
    env.probed[url] = nil
    -- 这条钉的是「发现源消失 + allow_remove=false」：探针没被拨过，走的是
    -- remove_grace 后只警告不删除的分支。探针失败时的 allow_remove 行为是另一
    -- 条语义（同样不删、warn 文案不同），在文件末尾单独钉。
    env.state.candidates = {}
    env.now = 2000
    env.state.now = env.now
    watcher.reconcile(env.state)             -- stamps missing_since
    env.now = 2400
    env.state.now = env.now
    watcher.reconcile(env.state)
    eq(#env.unregistered, 0, "removal disabled: nothing deleted")
    local warned = false
    for i = 1, #env.log do
        if string.find(env.log[i].message, "removal is disabled", 1, true) then
            warned = true
        end
    end
    check(warned, "the disabled-removal state is warned about once")
    env.now = env.now + 100
    env.state.now = env.now
    watcher.reconcile(env.state)
    local second = 0
    for i = 1, #env.log do
        if string.find(env.log[i].message, "removal is disabled", 1, true) then
            second = second + 1
        end
    end
    eq(second, 1, "and not repeated on every pass")
end

--------------------------------------------------------------------------
-- 17. 守卫 7：stuck add 释放
--------------------------------------------------------------------------
new_case("guard 7 stuck add released")
do
    local url = "http://stuck:8000"
    local env = harness({ candidates = { candidate(url) } })
    env.probed[url] = { models = { "m" } }
    watcher.reconcile(env.state)
    eq(#env.ledger.pending_urls(), 0)
    check(env.ledger.get_pending(url) ~= nil, "the add is parked as pending")
    eq(env.ledger.get_pending(url).worker_id, "id-" .. url, "with the id it returned")

    -- still pending and inside the confirm window: no second add, no release
    env.now = 1100
    env.state.now = env.now
    watcher.reconcile(env.state)
    eq(#env.registered, 1, "a live pending add is not re-attempted")

    -- the pool picked it up: pending confirmed, id refreshed from the pool
    env.state.actual = models_of(url, "m")
    env.state.actual[url].id = "fresh-pool-id"
    watcher.reconcile(env.state)
    eq(env.ledger.get_pending(url), nil, "confirmed add drops pending")
    eq(env.ledger.get_owned(url).worker_id, "fresh-pool-id",
        "and the ledger adopts the pool's id (guard 8: a restart or a reload hands"
        .. " the same URL a new id, and a stale id would make the later DELETE 404)")

    -- the stuck shape: the add never landed at all (the pool stayed empty, e.g. a
    -- reload cleared lr_workers while lr_watch survived). The URL must not stay
    -- claimed forever.
    local env2 = harness({ candidates = { candidate(url) } })
    env2.probed[url] = { models = { "m" } }
    watcher.reconcile(env2.state)
    check(env2.ledger.get_pending(url) ~= nil, "add queued, pool still empty")
    env2.now = 1000 + 100
    env2.state.now = env2.now
    watcher.reconcile(env2.state)
    eq(#env2.registered, 1, "inside the confirm window the add is not re-attempted")
    env2.now = 1000 + 190
    env2.state.now = env2.now
    local stats2 = watcher.reconcile(env2.state)
    eq(stats2.adds_stuck_released, 1,
        "after the confirm timeout the squatting add is released")
    eq(#env2.unregistered, 1,
        "the id the add returned is tried for deletion, which frees the URL")
    eq(#env2.registered, 2,
        "the same pass re-adds the now-free URL (release and re-add in one pass)")
    check(env2.ledger.get_owned(url) ~= nil, "and the URL is owned again")
    eq(env2.ledger.get_owned(url).worker_id, "id-" .. url, "with a fresh ledger entry")
end

--------------------------------------------------------------------------
-- 18. 守卫 1/2 在 reconcile 里生效：自排除与聚合器排除
--------------------------------------------------------------------------
new_case("guards 1/2 applied in reconcile")
do
    local env = harness({
        candidates = {
            candidate("http://127.0.0.1:30000", "proc"),
            candidate("http://127.0.0.1:29000", "proc"),
            candidate("http://127.0.0.1:8000", "proc"),
        },
    })
    env.probed["http://127.0.0.1:30000"] = { models = { "router-model" } }
    env.probed["http://127.0.0.1:29000"] = { models = { "metrics-model" } }
    env.probed["http://127.0.0.1:8000"] = { models = { "real" } }
    local stats = watcher.reconcile(env.state)
    eq(#env.registered, 1, "only the non-self candidate is registered")
    eq(env.registered[1].url, "http://127.0.0.1:8000", "the router ports are skipped")
    eq(stats.discovered, 1, "and they are not even counted as discovered")

    -- exclude patterns
    local env2 = harness({
        candidates = { candidate("http://127.0.0.1:8000", "proc"),
                       candidate("http://10.9.9.9:8000", "proc") },
    })
    env2.cfg.exclude_patterns = { "10%.9%.9%.9" }
    env2.probed["http://127.0.0.1:8000"] = { models = { "kept" } }
    env2.probed["http://10.9.9.9:8000"] = { models = { "excluded" } }
    watcher.reconcile(env2.state)
    eq(#env2.registered, 1, "excluded URL not registered")
    eq(env2.registered[1].url, "http://127.0.0.1:8000", "the rest still registers")
end

--------------------------------------------------------------------------
-- 18b. 探针不先拨号：自端口与被排除的 URL 连 HTTP 都不该发出去
--------------------------------------------------------------------------
new_case("candidates are filtered before they are probed")
do
    -- The router's own listener answers /v1/models, so a probe that reaches it is
    -- already a wasted request counted against the router itself. run_pass applies the
    -- self and exclude tests before building the fetch list, so the memo never even
    -- holds those URLs; reconcile's own loop keeps the same tests for callers that
    -- hand it a candidate list directly (this file and the e2e both do).
    local seen_urls = {}
    local env = harness({
        candidates = {
            candidate("http://127.0.0.1:30000", "proc"),
            candidate("http://127.0.0.1:29000", "proc"),
            candidate("http://10.1.1.1:8000", "proc"),
            candidate("http://10.2.2.2:8000", "proc"),
        },
    })
    env.cfg.exclude_patterns = { "10%.1%.1%.1" }
    env.state.probe = function(url)
        seen_urls[#seen_urls + 1] = url
        return { url = url, models = { "m" }, engine = "openai", has_health = true }
    end
    watcher.reconcile(env.state)
    local saw_self = false
    for i = 1, #seen_urls do
        if string.find(seen_urls[i], "127.0.0.1", 1, true) then
            saw_self = true
        end
    end
    check(not saw_self, "no probe is sent to the router's own ports",
        table.concat(seen_urls, " "))
    eq(#env.registered, 1, "only the surviving candidate is registered")
    eq(env.registered[1].url, "http://10.2.2.2:8000", "and it is the right one")
end

--------------------------------------------------------------------------
-- 19. model-map 改名如何落到池里（owned 回收 / protected 领养）
--------------------------------------------------------------------------
new_case("model map renames reach the pool")
do
    -- owned worker: recycled so the next pass re-adds it under the new id
    local url = "http://renamed:8000"
    local env = harness({ candidates = { candidate(url) } })
    env.probed[url] = { models = { "/models/x.gguf" } }
    watcher.reconcile(env.state)
    env.state.actual = models_of(url, "/models/x.gguf")
    watcher.reconcile(env.state)
    env.model_map = { ["/models/x.gguf"] = "x" }
    env.state.model_map = env.model_map
    watcher.reconcile(env.state)
    eq(#env.unregistered, 1, "the owned worker is deleted so it can be renamed")
    eq(env.ledger.get_owned(url), nil, "and the ledger entry goes with it")
    env.state.actual = {}
    env.now = env.now + 1
    env.state.now = env.now
    watcher.reconcile(env.state)
    eq(env.registered[2].model_id, "x", "re-registered under the mapped public id")

    -- protected worker: the map has to reach it too, so ownership is handed over
    local purl = "http://seed:8000"
    local env2 = harness({ actual = models_of(purl, "old-name"),
                           candidates = { candidate(purl) } })
    watcher.reconcile(env2.state)   -- first contact -> protected
    env2.probed[purl] = { models = { "old-model" } }
    env2.model_map = { ["old-model"] = "new-name" }
    env2.state.model_map = env2.model_map
    watcher.reconcile(env2.state)
    eq(#env2.unregistered, 1, "the protected worker is deleted to apply the rename")
    eq(env2.ledger.is_protected(purl), false, "protection dropped so discovery can own it")
    env2.state.actual = {}
    env2.now = env2.now + 1
    env2.state.now = env2.now
    watcher.reconcile(env2.state)
    eq(env2.registered[1].model_id, "new-name", "re-added under the new public id")
end

--------------------------------------------------------------------------
-- 20. 注册失败的退避 + delete 失败时保留 ledger
--------------------------------------------------------------------------
new_case("add back-off and failed delete")
do
    local url = "http://bad:8000"
    local env = harness({ candidates = { candidate(url) }, register_fails = true })
    env.probed[url] = { models = { "m" } }
    local stats = watcher.reconcile(env.state)
    eq(stats.add_fails, 1, "a rejected add is counted")
    check(env.ledger.get_backoff(url) ~= nil, "and the URL goes into back-off")
    env.now = env.now + 5
    env.state.now = env.now
    watcher.reconcile(env.state)
    eq(#env.registered, 0, "the back-off window suppresses the retry")
    eq(env.state.stats.add_fails, 1, "and does not count a second failure")
    env.now = env.now + 60
    env.state.now = env.now
    watcher.reconcile(env.state)
    eq(env.state.stats.add_fails, 2, "after the window it tries again")

    -- a delete that fails must leave the entry (and the protection) in place
    local env2 = harness({ candidates = { candidate(url) }, delete_fails = true })
    env2.cfg.remove_grace_secs = 0
    env2.cfg.keep_last_grace_secs = -1
    env2.probed[url] = { models = { "m" } }
    watcher.reconcile(env2.state)
    env2.state.actual = models_of(url, "m")
    env2.probed[url] = nil
    watcher.reconcile(env2.state)
    eq(env2.ledger.get_owned(url) ~= nil, true,
        "a failed remove keeps the ledger entry so it can retry")
end

--------------------------------------------------------------------------
-- 21. env 配置解析（缺省值 + 打开开关）
--------------------------------------------------------------------------
new_case("new_config defaults and overrides")
do
    local defaults = watcher.new_config(function() return nil end, 30000, 29000)
    eq(defaults.enabled, false, "watcher off unless told otherwise")
    eq(defaults.interval_secs, 15, "interval default")
    eq(defaults.probe_timeout_secs, 4, "probe timeout default")
    eq(defaults.remove_grace_secs, 300, "remove-grace default")
    eq(defaults.max_models, 8, "max-models default")
    eq(defaults.keep_last_grace_secs, 1800, "keep-last default")
    eq(defaults.add_confirm_timeout_secs, 180, "add-confirm default")
    eq(defaults.probe_failures, 2, "the transport-level hysteresis needs a run of two")
    eq(defaults.probe_fuse, true, "the pass fuse is on by default")
    eq(defaults.docker_socket, "/var/run/docker.sock", "docker socket default")
    eq(#defaults.self_ports, 2, "both own listeners are self ports")
    eq(defaults.self_ports[1], 30000, "main port")
    eq(defaults.self_ports[2], 29000, "metrics port")

    local overrides = watcher.new_config(function(name)
        local table_of = {
            SMG_WATCHER_ENABLED = "yes",
            SMG_WATCHER_TARGETS = "http://a:8001 http://b:8002",
            SMG_WATCHER_DOCKER = "true",
            SMG_WATCHER_PROC_SCAN = "false",
            SMG_WATCHER_INTERVAL_SECS = "7",
            SMG_WATCHER_REMOVE_GRACE_SECS = "2",
            SMG_WATCHER_PROBE_FAILURES = "4",
            SMG_WATCHER_PROBE_FUSE = "false",
            SMG_WATCHER_MAX_MODELS = "0",
            SMG_WATCHER_ALLOW_PORT = "8000-8001",
            SMG_WATCHER_DENY_PORT = "9100",
            SMG_WATCHER_EXCLUDE = "node-exporter,searxng",
            SMG_WATCHER_MODEL_MAP = "orig:pub",
        }
        return table_of[name]
    end, 30000, 0)
    eq(overrides.enabled, true, "SMG_WATCHER_ENABLED=yes opts in")
    eq(#overrides.targets, 2, "targets accept space separation")
    eq(overrides.scan_docker, true, "docker scan opt-in")
    eq(overrides.scan_proc, false, "proc scan opt-out")
    eq(overrides.interval_secs, 7, "interval override")
    eq(overrides.remove_grace_secs, 2, "grace override (what the e2e uses)")
    eq(overrides.max_models, 0, "max-models 0 accepted")
    eq(overrides.probe_failures, 4, "SMG_WATCHER_PROBE_FAILURES override")
    eq(overrides.probe_fuse, false, "SMG_WATCHER_PROBE_FUSE=false turns the fuse off")
    eq(overrides.allow_ports[8000] and overrides.allow_ports[8001], true,
        "allow-port parsed")
    eq(overrides.deny_ports[9100], true, "deny-port parsed")
    eq(#overrides.exclude_patterns, 2, "exclude list parsed")
    eq(overrides.model_map["orig"], "pub", "model map from env")
    eq(#overrides.self_ports, 1, "metrics_port 0 is not a self port")

    -- clamps: a nonsense value must not produce a broken loop
    local clamped = watcher.new_config(function(name)
        if name == "SMG_WATCHER_INTERVAL_SECS" then return "0" end
        if name == "SMG_WATCHER_PROBE_TIMEOUT_SECS" then return "-3" end
        if name == "SMG_WATCHER_MAX_MODELS" then return "-1" end
        if name == "SMG_WATCHER_REMOVE_GRACE_SECS" then return "not-a-number" end
        return nil
    end, 30000, 0)
    eq(clamped.interval_secs, 1, "interval floored at 1 s")
    eq(clamped.probe_timeout_secs, 1, "probe timeout floored at 1 s")
    eq(clamped.max_models, 0, "negative max-models clamps to 0 (disabled)")
    eq(clamped.remove_grace_secs, 300, "a non-numeric grace keeps the default")
    -- 滞回阈值在 reconcile 里钳制（floor，且 0/负数 = 显式的"首次即摘"），
    -- new_config 必须原样保留操作员写的数字，钳到 1 会偷走"立即摘除"这个档位。
    local explicit = watcher.new_config(function(name)
        if name == "SMG_WATCHER_PROBE_FAILURES" then return "0" end
        return nil
    end, 30000, 0)
    eq(explicit.probe_failures, 0, "an explicit 0 survives new_config")
    local garbage = watcher.new_config(function(name)
        if name == "SMG_WATCHER_PROBE_FAILURES" then return "lots" end
        return nil
    end, 30000, 0)
    eq(garbage.probe_failures, 2, "nonsense falls back to the default, not to 0")
end

--------------------------------------------------------------------------
-- 22. collect 三源开关 + 聚合器 labels
--------------------------------------------------------------------------
new_case("collect merges the enabled sources")
do
    local proc_text = "  sl  local_address rem_address   st\n"
        .. "   0: 0100007F:1F40 00000000:0000 0A\n"
    local function reader(path)
        if path == "/proc/net/tcp" then return proc_text end
        return nil
    end
    local cfg = watcher.new_config(function(name)
        if name == "SMG_WATCHER_TARGETS" then return "http://remote:8010" end
        return nil
    end, 30000, 0)
    cfg.scan_docker = false
    cfg.scan_proc = true
    local cands = watcher.collect(cfg, reader)
    local urls = {}
    for i = 1, #cands do
        urls[cands[i].url] = cands[i]
    end
    check(urls["http://remote:8010"] ~= nil, "explicit target is a candidate")
    eq(urls["http://remote:8010"].source, "cli", "explicit target source is cli")
    check(urls["http://127.0.0.1:8000"] ~= nil, "proc scan adds the listener")
    eq(#cands, 2, "docker source stayed silent when disabled")

    -- docker wins over proc for the same URL, and labels the proc candidate
    local cfg2 = watcher.new_config(function() return nil end, 30000, 0)
    cfg2.scan_docker = false
    cfg2.scan_proc = true
    local merged = watcher.unique_candidates({
        watcher.local_candidates({ { host = "0.0.0.0", port = 18000 } }, nil, nil),
        watcher.docker_candidates_from({ { Id = "z", Names = { "/gpu9" },
                                           Ports = { { PrivatePort = 8, PublicPort = 18000 } } } }, true),
    })
    eq(#merged, 1, "the published port and the proc listener collapse")
    eq(merged[1].source, "docker", "docker is the more specific source")
    eq(merged[1].gpu, "9", "and it brings the container label along")
end

--------------------------------------------------------------------------
-- 22b. deny 清单：default ∪ 操作员（回归：操作员清单不得被整体丢弃）
--------------------------------------------------------------------------
new_case("proc deny is the union of the default and the operator list")
do
    -- The /proc lines a real box contributes: an OpenAI worker on 8000, rpcbind on
    -- 111 (accepts, then RSTs), the qdrant gRPC port 6334 (binary HTTP/2 frame, so
    -- the probe's receive("*l") ends in ECONNRESET and nginx logs the recv failure
    -- from its own core), and a Win32-OpenSSH on 11022 -- the three noise sources an
    -- operator explicitly named in SMG_WATCHER_DENY_PORT.
    local proc_text = "  sl  local_address rem_address   st\n"
        .. "   0: 0100007F:1F40 00000000:0000 0A\n"   -- 127.0.0.1:8000
        .. "   1: 00000000:006F 00000000:0000 0A\n"   -- 0.0.0.0:111   (rpcbind)
        .. "   2: 0100007F:18BE 00000000:0000 0A\n"   -- 127.0.0.1:6334 (qdrant gRPC)
        .. "   3: 00000000:2B0E 00000000:0000 0A\n"   -- 0.0.0.0:11022 (ssh)
    local function reader(path)
        if path == "/proc/net/tcp" then return proc_text end
        return nil
    end
    local function urls_of(cands)
        local out = {}
        for i = 1, #cands do
            out[cands[i].url] = cands[i]
        end
        return out
    end

    -- (a) no allow list: the operator's list is honoured *and* the default still
    -- trims, because they are a union. This is the regression: the branch used to
    -- assign one list or the other, so SMG_WATCHER_DENY_PORT was dropped here.
    local cfg = watcher.new_config(function(name)
        if name == "SMG_WATCHER_DENY_PORT" then return "11022,14389,42209" end
        return nil
    end, 30000, 0)
    cfg.scan_proc = true
    local seen = urls_of(watcher.collect(cfg, reader))
    check(seen["http://127.0.0.1:8000"] ~= nil, "the real worker is still a candidate")
    check(seen["http://127.0.0.1:11022"] == nil,
        "an operator-denied port is never probed (was dropped by the old branch)")
    check(seen["http://127.0.0.1:111"] == nil,
        "rpcbind 111 is not probed (default list still applies alongside the operator's)")
    check(seen["http://127.0.0.1:6334"] == nil,
        "the qdrant gRPC port is not probed (default list, measured recv-RST source)")

    -- (b) with an allow list the default stays out of the way: naming a port is
    -- "probe exactly this", even one the default would have trimmed.
    local cfg2 = watcher.new_config(function(name)
        if name == "SMG_WATCHER_ALLOW_PORT" then return "111" end
        return nil
    end, 30000, 0)
    cfg2.scan_proc = true
    local seen2 = urls_of(watcher.collect(cfg2, reader))
    check(seen2["http://127.0.0.1:111"] ~= nil,
        "an allow-listed port beats the default deny (allow means exactly these)")
    check(seen2["http://127.0.0.1:8000"] == nil,
        "and nothing else is probed")

    -- (c) the allow list is an explicit instruction and outranks both deny lists,
    -- which is the daemon's shape too: llm_watcher.py appends every sorted
    -- cfg.allow_ports entry unconditionally, so naming a port probes it even when
    -- the default or the operator would have denied it. Pinned here so the deny fix
    -- cannot quietly turn allow into a hint.
    local cfg3 = watcher.new_config(function(name)
        if name == "SMG_WATCHER_ALLOW_PORT" then return "111,6334" end
        if name == "SMG_WATCHER_DENY_PORT" then return "111" end
        return nil
    end, 30000, 0)
    cfg3.scan_proc = true
    local seen3 = urls_of(watcher.collect(cfg3, reader))
    check(seen3["http://127.0.0.1:6334"] ~= nil,
        "allow-listed and not operator-denied: probed even though the default denies it")
    check(seen3["http://127.0.0.1:111"] ~= nil,
        "an explicitly allow-listed port outranks deny (both lists), as in the daemon")
    eq(seen3["http://127.0.0.1:111"].source, "allow-list",
        "and it arrives through the allow-list source")

    -- (d) the union helper itself: number keys, nil-tolerant, no shared state
    local u = watcher.union_port_sets({ [22] = true }, nil, { ["80"] = true })
    eq(u[22], true, "union keeps the first set")
    eq(u[80], true, "union accepts a string key and normalises it to a number")
    eq(watcher.union_port_sets(nil)[22], nil, "union of nothing denies nothing")
    eq(watcher.DEFAULT_DENY_PORTS[111], true, "rpcbind 111 is in the default list")
    eq(watcher.DEFAULT_DENY_PORTS[6334], true, "qdrant gRPC 6334 joined the default list")
end

--------------------------------------------------------------------------
-- 23. effective_map / merge 语义（请求期 POST /model-map 的纯逻辑半边）
--------------------------------------------------------------------------
new_case("map merge keeps env entries and lets the API win")
do
    local from_env = watcher.parse_model_map("env-only:pub,both:old")
    local api = watcher.parse_model_map_body('{"both":"new","api-only":"x"}')
    local merged = watcher.merge_map(from_env, api)
    eq(merged["env-only"], "pub", "an env entry survives an API merge")
    eq(merged["both"], "new", "the API edit wins")
    eq(merged["api-only"], "x", "the API adds")
    -- and the model_name resolution the pass will use
    eq(watcher.model_name("both", merged, false), "new", "resolution reads the merged map")
end

--------------------------------------------------------------------------
-- 24. 探针失败即摘除（2026-10-01 用户裁定：注册必须拿到 /v1/models 的真实
--     模型信息；周期检查判定不可用的服务不应继续出现在服务池里）
--
--     夹具必须区分两条路径，它们的语义完全不同：
--       * 「确认不可用」：URL 仍在 state.candidates 里，但严格探针读不到
--         /v1/models 的 data[].id（probed[url] = nil）。网关亲眼看见它答不出
--         模型列表，必须立刻摘除，不等 remove_grace、也不受 keep-last 保护，
--         否则池里留一行只会回 5xx 的僵尸。
--       * 「发现源消失」：URL 从 state.candidates 里没了（进程停了、容器删了），
--         探针根本没被拨过。这是「看不见」而不是「不健康」，短暂重启不该清空池，
--         所以仍走 remove_grace / keep-last 宽限。
--     只把 probed[url] 置 nil 而留着候选，测的是前者；要模拟后者必须同时清空
--     state.candidates。下面 keep-last 与 allow_remove 的用例走的是后者。
--------------------------------------------------------------------------

---把 url 放进 reconcile 真正读取的池（state.actual），并补上 id -> url 映射，
---让 unregister 回调真的删掉那一行；否则「池里没有残留」测的是夹具忘了删，
---而且下一轮会因为 state.actual[url] 仍在而跳过 add。
local function serve(env, url, model_id)
    env.state.actual = models_of(url, model_id)
    env.state.actual[url].id = "id-" .. url
    env.id_to_url = { ["id-" .. url] = url }
    -- harness 的 unregister 只在 env.actual 非空时才真去删 state.actual[url]
    -- （它是夹具里"池由外部提供"的标记）。这里把它指向同一张表，否则
    -- "摘除后池里没有残留"测的是夹具没删行，而且下一轮会因为 state.actual[url]
    -- 仍在而跳过 add，恢复用例也跟着失真。
    env.actual = env.state.actual
end

---假时钟：reconcile 读 state.now，用例写 env.now，两个必须一起动，否则
---missing_since 会钉在旧时间上，宽限断言就变成了测夹具。
local function advance(env, now)
    env.now = now
    env.state.now = now
end

---数一下日志里提到 needle 的行数（warn 只许出现一次的断言用）。
local function logged(env, needle)
    local n = 0
    for i = 1, #env.log do
        if string.find(env.log[i].message, needle, 1, true) then
            n = n + 1
        end
    end
    return n
end

---健康服务登记进池：先只给候选（首接触快照时池是空的，谁都不会被 protected），
---再补池行，让 URL 走正常认领变成 owned。
local function register_and_claim(env, url, model_id)
    env.probed[url] = { models = { model_id } }
    watcher.reconcile(env.state)
    serve(env, url, model_id)
    watcher.reconcile(env.state)   -- reap_pending 确认，条目转为 owned
    env.probed[url] = { models = { model_id } }
    watcher.reconcile(env.state)   -- 稳态：desired 命中，清掉 missing/warned
end

new_case("a probe failure removes the worker at once, without the undiscovered grace")
do
    local url = "http://flaky:8000"
    local env = harness({ candidates = { candidate(url, "proc") } })
    register_and_claim(env, url, "m")
    eq(#env.registered, 1, "the healthy service is registered once")
    local stats = watcher.reconcile(env.state)
    eq(stats.removes, 0, "nothing is removed while it is healthy")

    -- 仍是发现源候选，但严格探针读不到 /v1/models 的 data[].id。这条 reason 是
    -- 确定性否定（对方答了 HTTP、内容不合要求），所以第 1 轮就摘，不等滞回。
    env.probed[url] = nil
    env.probe_reason[url] = "/v1/models answers without data[].id"
    advance(env, 2000)
    local after = watcher.reconcile(env.state)
    eq(#env.unregistered, 1, "the unavailable service leaves the pool immediately")
    eq(after.removes, 1, "and it counts as one removal")
    eq(env.ledger.get_owned(url), nil, "its ledger entry is dropped, not just hidden")
    check(env.state.actual[url] == nil, "no pool row survives the failed probe")
    eq(logged(env, "undiscovered for"), 0, "the undiscovered grace never runs here")
    eq(logged(env, "last worker"), 0, "keep-last never excuses it either")
    check(logged(env, "without data[].id") >= 1,
        "the classify reason travels into the removal line")
end

new_case("keep-last does not excuse a service that fails the probe")
do
    local url = "http://solo:8000"
    local env = harness({ candidates = { candidate(url, "proc") } })
    register_and_claim(env, url, "only-model")
    eq(env.ledger.get_owned(url) ~= nil, true, "it is owned while it serves")

    -- keep_last_grace_secs = 1800：发现源消失的路径会把它保到 30 分钟，
    -- 探针确认不可用这条不能沾这个光
    env.cfg.keep_last_grace_secs = 1800
    env.probed[url] = nil
    env.probe_reason[url] = "/v1/models answers without data[].id"
    advance(env, 2100)
    watcher.reconcile(env.state)
    eq(#env.unregistered, 1, "the last worker of a model still leaves when its probe fails")
    check(env.state.actual[url] == nil, "no half-serving row is left behind for a dead model")
    eq(logged(env, "last worker"), 0, "and the keep-last branch never logged a keep")

    -- 反证（让这一条自己讲清它在区分什么）：同一个服务、同一份 keep-last 配置，
    -- 只要换成「发现源不再报它」而不是「探针确认它答不出模型」，keep-last 就把
    -- 它留过 remove-grace。也就是说决定后果的不是开关，而是证据的种类。
    local keep = harness({ candidates = { candidate(url, "proc") } })
    keep.cfg.keep_last_grace_secs = 1800
    register_and_claim(keep, url, "only-model")
    keep.state.candidates = {}
    advance(keep, 2200)
    watcher.reconcile(keep.state)                 -- stamps missing_since
    advance(keep, 2200 + 301)                     -- past remove-grace, inside keep-last
    watcher.reconcile(keep.state)
    eq(#keep.unregistered, 0,
        "counter-evidence: the same URL survives remove-grace once it merely vanishes")
    check(logged(keep, "last worker") == 1, "and that pass really took the keep-last branch")
end

new_case("allow_remove=false still refuses to delete a probe failure, but warns once")
do
    -- SMG_WATCHER_ALLOW_REMOVE=0 是操作员「只许加不许删」的总开关：探针结论再
    -- 确定也不能替他们做删除决定，否则严格探针就成了绕过这道保险的后门。
    local url = "http://hands-off:8000"
    local env = harness({ candidates = { candidate(url, "proc") } })
    env.cfg.allow_remove = false
    register_and_claim(env, url, "m")

    env.probed[url] = nil
    env.probe_reason[url] = "/v1/models answers without data[].id"
    advance(env, 2000)
    watcher.reconcile(env.state)
    eq(#env.unregistered, 0, "a probe failure does not delete while removal is disabled")
    check(env.state.actual[url] ~= nil, "the pool row is left for the operator to judge")
    eq(env.ledger.get_owned(url) ~= nil, true, "and the ledger keeps its claim so it can act later")
    eq(logged(env, "removal is disabled"), 1, "the refusal is warned about once")

    advance(env, 2100)
    watcher.reconcile(env.state)
    advance(env, 2200)
    watcher.reconcile(env.state)
    eq(logged(env, "removal is disabled"), 1, "and the warn is not repeated on every pass")
    eq(#env.unregistered, 0, "still nothing deleted after three passes")
end

new_case("a recovered service comes back through the same probe and add gates")
do
    local url = "http://flap:8000"
    local env = harness({ candidates = { candidate(url, "proc") } })
    register_and_claim(env, url, "m")
    local before = #env.registered
    -- stats 是跨轮累积的，所以"这是一次普通 add"要按增量算
    local adds_before = env.state.stats.adds

    env.probed[url] = nil
    env.probe_reason[url] = "/v1/models answers without data[].id"
    advance(env, 2000)
    watcher.reconcile(env.state)
    eq(#env.unregistered, 1, "the failure removed it")

    -- 服务恢复：探针又能读到 /v1/models 的模型信息，走普通 add 通道回来
    env.probed[url] = { models = { "m" } }
    advance(env, 2100)
    local back = watcher.reconcile(env.state)
    eq(#env.registered, before + 1, "recovery re-registers the service")
    eq(back.adds - adds_before, 1, "and it is a normal add, not a bypass")
    eq(env.ledger.get_owned(url) ~= nil, true, "the ledger owns it again")
    advance(env, 2200)
    watcher.reconcile(env.state)
    eq(#env.registered, before + 1, "the re-added service stays registered")
end

new_case("a service that merely leaves discovery still uses the undiscovered grace")
do
    local url = "http://vanish:8000"
    local env = harness({ candidates = { candidate(url, "proc") } })
    register_and_claim(env, url, "m")

    -- 发现源不再报它（进程停了、容器删了），探针没被拨过：这是「看不见」
    -- 而不是「看见了但不健康」，短暂重启不该清空池，先起宽限时钟。
    env.state.candidates = {}
    advance(env, 2000)
    watcher.reconcile(env.state)
    eq(#env.unregistered, 0, "an undiscovered URL is not deleted on the first pass")
    eq(env.ledger.get_owned(url).missing_since, 2000, "it starts the grace clock instead")

    -- 宽限内回来：missing_since 清掉，什么都不删
    env.state.candidates = { candidate(url, "proc") }
    env.probed[url] = { models = { "m" } }
    advance(env, 2100)
    watcher.reconcile(env.state)
    eq(env.ledger.get_owned(url).missing_since, nil, "coming back clears the grace clock")
    eq(#env.unregistered, 0, "and nothing was ever deleted")

    -- 对比：同样的时间线，只要它仍是候选而探针读不到模型，就没有宽限可言
    env.probed[url] = nil
    env.probe_reason[url] = "/v1/models answers without data[].id"
    advance(env, 2150)
    watcher.reconcile(env.state)
    eq(#env.unregistered, 1, "the same URL goes at once once it is back in discovery")
end

--------------------------------------------------------------------------
-- 25. 探针结论分档（第 10 条守卫的粒度那一半）
--
--     classify() 的拒绝不是一个结论而是三类，后果必须各不相同：
--       * 确定性否定（对方答了 HTTP，内容不合要求）→ 当轮摘；
--       * 传输层未知（拨号本身没给出可归因于对方的回答）→ 连续失败攒到
--         SMG_WATCHER_PROBE_FAILURES（缺省 2）才摘，任一轮成功即清零；
--       * 与对方能否服务无关的理由（网关自身缺 fetch、require_health 准入）
--         → 既不摘也不置计数，也不起 missing_since 时钟。
--     用例一律喂 classify() 的真实 reason 文案，而不是随手编一个字符串：
--     分档是按 reason 文案匹配的，文案与档位必须在这里钉死在一起。
--------------------------------------------------------------------------

---把若干 url 一次性登记进池并认领成 owned（多 worker 场景不能用
---register_and_claim：serve() 会整表替换 state.actual，把前一个 worker 的池行抹掉）。
local function claim_workers(env, specs)
    env.actual = env.state.actual
    env.id_to_url = env.id_to_url or {}
    for i = 1, #specs do
        local url = specs[i].url
        env.probed[url] = { models = { specs[i].model_id } }
        env.id_to_url["id-" .. url] = url
    end
    watcher.reconcile(env.state)                      -- adds queued as pending
    for i = 1, #specs do
        local url, model_id = specs[i].url, specs[i].model_id
        env.state.actual[url] = { id = "id-" .. url, url = url,
                                  model_id = model_id, is_healthy = true }
    end
    advance(env, env.now + 1)
    watcher.reconcile(env.state)                      -- reap_pending confirms
    advance(env, env.now + 1)
    watcher.reconcile(env.state)                      -- steady pass
    env.registered, env.unregistered = {}, {}         -- 只关心之后发生的动作
end

---把 url 标成「本轮探针给出的失败结论」。
local function fail_probe(env, url, reason)
    env.probed[url] = nil
    env.probe_reason[url] = reason
end

---读 owned 条目上的一个字段。滞回计数与宽限时钟的断言必须走它：条目可能已经被摘掉，
---直接 `get_owned(url).field` 会让整个文件崩在索引 nil 上，看不到后面的用例。
local function owned_field(env, url, field)
    local entry = env.ledger.get_owned(url)
    return entry and entry[field]
end

new_case("probe_verdict buckets the classify reasons")
do
    -- 分档表本身先钉住：它是摘除后果的唯一入口，文案一改就会悄悄换档。
    eq(watcher.probe_verdict("/v1/models answers without data[].id"), "reject",
        "no data[].id is a deterministic rejection")
    eq(watcher.probe_verdict("it is a router, not a worker"), "reject",
        "the router self-fingerprint is a deterministic rejection")
    eq(watcher.probe_verdict("advertises 9 models (> max-models 8), looks like a proxy"),
        "reject", "the max_models ceiling is a deterministic rejection")
    eq(watcher.probe_verdict("no /v1/models answer"), "count",
        "an unreachable or non-2xx /v1/models is a transport-level unknown")
    eq(watcher.probe_verdict("/v1/models answers but /health and /metrics both 5xx -- an "
        .. "upstream/gateway, not a worker (or set SMG_WATCHER_ALLOW_MODELS_ONLY=1)"),
        "count", "the double 5xx signal is evidence-incomplete, not a rejection")
    eq(watcher.probe_verdict("no probe transport"), nil,
        "a missing transport says nothing about the worker")
    eq(watcher.probe_verdict("no usable /health endpoint"), nil,
        "require_health is an admission gate, not an eviction reason")
    eq(watcher.probe_verdict(nil), "count", "an unnamed failure stays conservative")
    eq(watcher.probe_verdict(""), "count", "an empty reason stays conservative")
    eq(watcher.probe_verdict("some future wording"), "count",
        "unrecognised wording defaults to the hysteresis bucket")
    eq(watcher.probe_verdict(500), "count", "a non-string reason is not evidence either")
    -- "advertises" 只在句首算 max_models；正文里出现这四个字符的其它文案不得误档。
    eq(watcher.probe_verdict("nginx says advertises nothing"), "count",
        "the max_models match is anchored at the start of the line")
end

new_case("a deterministic rejection evicts on the first pass, whatever its wording")
do
    local reasons = {
        "/v1/models answers without data[].id",
        "it is a router, not a worker",
        "advertises 9 models (> max-models 8), looks like a proxy",
    }
    for i = 1, #reasons do
        local url = "http://nope" .. i .. ":8000"
        local env = harness({ candidates = { candidate(url, "proc") } })
        register_and_claim(env, url, "m")
        fail_probe(env, url, reasons[i])
        advance(env, 2000)
        local stats = watcher.reconcile(env.state)
        eq(#env.unregistered, 1, "pass one evicts: " .. reasons[i])
        eq(env.ledger.get_owned(url), nil, "and the ledger entry goes with it")
        eq(stats.removes, 1, "counted as a removal")
        check(env.state.actual[url] == nil, "the pool row is gone")
        eq(logged(env, "probe fuse"), 0, "a single eviction never trips the fuse")
    end
end

new_case("a transport-level unknown needs a run of failures before it evicts")
do
    local url = "http://slow:8000"
    local env = harness({ candidates = { candidate(url, "proc") } })
    register_and_claim(env, url, "m")

    fail_probe(env, url, "no /v1/models answer")
    advance(env, 2000)
    watcher.reconcile(env.state)
    eq(#env.unregistered, 0, "the first transport-level failure keeps the row")
    eq(owned_field(env, url, "probe_fails"), 1, "and records one strike")
    check(env.state.actual[url] ~= nil, "the pool row is untouched")
    eq(logged(env, "(1/2)"), 1, "the wait is visible in the log, at warn level")

    advance(env, 2015)
    watcher.reconcile(env.state)
    eq(#env.unregistered, 1, "the second consecutive failure evicts")
    eq(env.ledger.get_owned(url), nil, "and the ledger forgets the worker")
    check(logged(env, "probe failed (no /v1/models): no /v1/models answer") >= 1,
        "the removal line carries the classify reason verbatim")

    -- 阈值确实可配：SMG_WATCHER_PROBE_FAILURES=1 等于「回到当轮即摘」
    local url2 = "http://slow-tight:8000"
    local tight = harness({ candidates = { candidate(url2, "proc") } })
    tight.cfg.probe_failures = 1
    register_and_claim(tight, url2, "m")
    fail_probe(tight, url2, "no /v1/models answer")
    advance(tight, 2000)
    watcher.reconcile(tight.state)
    eq(#tight.unregistered, 1, "with the threshold at 1 the same reason evicts at once")

    -- 双 5xx 与传输层失败同档：/metrics 抖一下不能给 vLLM 定罪
    local url3 = "http://flapping-metrics:8000"
    local dual = harness({ candidates = { candidate(url3, "proc") } })
    register_and_claim(dual, url3, "m")
    fail_probe(dual, url3, "/v1/models answers but /health and /metrics both 5xx -- an "
        .. "upstream/gateway, not a worker (or set SMG_WATCHER_ALLOW_MODELS_ONLY=1)")
    advance(dual, 2000)
    watcher.reconcile(dual.state)
    eq(#dual.unregistered, 0, "one double-5xx pass does not evict")
    advance(dual, 2015)
    watcher.reconcile(dual.state)
    eq(#dual.unregistered, 1, "a second one does")
end

new_case("a probe success clears the hysteresis counter")
do
    -- 滞回最容易被写坏的地方：计数只增不减的话，一个反复抖动的服务迟早被
    -- 「攒够两次」收掉，而那正是滞回要避免的误判。
    local url = "http://flapper:8000"
    local env = harness({ candidates = { candidate(url, "proc") } })
    register_and_claim(env, url, "m")

    fail_probe(env, url, "no /v1/models answer")
    advance(env, 2000)
    watcher.reconcile(env.state)
    eq(owned_field(env, url, "probe_fails"), 1, "the first failure records a strike")

    env.probed[url] = { models = { "m" } }
    advance(env, 2015)
    watcher.reconcile(env.state)
    eq(owned_field(env, url, "probe_fails"), nil, "answering again clears it")
    eq(#env.unregistered, 0, "and nothing was deleted in between")

    fail_probe(env, url, "no /v1/models answer")
    advance(env, 2030)
    watcher.reconcile(env.state)
    eq(#env.unregistered, 0, "a fresh failure starts the run over, not at two")
    eq(owned_field(env, url, "probe_fails"), 1, "and the counter is back to one")

    advance(env, 2045)
    watcher.reconcile(env.state)
    eq(#env.unregistered, 1, "the run only evicts when it really is consecutive")
end

new_case("reasons about the gateway, not the worker, change nothing")
do
    local cases = {
        { url = "http://no-transport:8000", reason = "no probe transport" },
        { url = "http://no-health:8000", reason = "no usable /health endpoint" },
    }
    for i = 1, #cases do
        local url = cases[i].url
        local env = harness({ candidates = { candidate(url, "proc") } })
        env.cfg.require_health = true
        register_and_claim(env, url, "m")
        fail_probe(env, url, cases[i].reason)
        advance(env, 2000)
        watcher.reconcile(env.state)
        eq(#env.unregistered, 0, "no eviction for: " .. cases[i].reason)
        local entry = env.ledger.get_owned(url)
        check(entry ~= nil, "the entry survives")
        eq(owned_field(env, url, "probe_fails"), nil, "no strike is counted")
        eq(owned_field(env, url, "missing_since"), nil, "and the grace clock does not start either")
        eq(logged(env, "failed the strict"), 0, "no hysteresis warn for a non-verdict")
    end
end

new_case("the pass fuse spares more than half the pool from one probe verdict")
do
    local urls = { "http://a:8000", "http://b:8000", "http://c:8000" }
    local function pool(probe_fuse)
        local env = harness({ candidates = {
            candidate(urls[1], "proc"), candidate(urls[2], "proc"), candidate(urls[3], "proc"),
        } })
        if probe_fuse ~= nil then
            env.cfg.probe_fuse = probe_fuse
        end
        claim_workers(env, {
            { url = urls[1], model_id = "m1" },
            { url = urls[2], model_id = "m2" },
            { url = urls[3], model_id = "m3" },
        })
        eq(env.ledger.get_owned(urls[3]) ~= nil, true, "the healthy worker is owned")
        -- 两条同时被传输层判死刑，第三条照常应答：整池被清空更像是网关出事
        fail_probe(env, urls[1], "no /v1/models answer")
        fail_probe(env, urls[2], "no /v1/models answer")
        return env
    end

    local env = pool(nil)                                       -- 缺省：保险丝开
    advance(env, 2000)
    watcher.reconcile(env.state)                                -- 第一轮只是累计
    eq(#env.unregistered, 0, "below the threshold nothing is at stake yet")
    advance(env, 2015)
    local stats = watcher.reconcile(env.state)
    eq(#env.unregistered, 0, "two of three owned workers condemned in one pass is not acted on")
    eq(stats.probe_fuse_skips, 2, "and the pass says which verdict it overrode")
    check(logged(env, "probe fuse kept 2/3") == 1, "the fuse warn names the count and the total")
    check(env.state.actual[urls[1]] ~= nil and env.state.actual[urls[2]] ~= nil,
        "both pool rows survive the spared pass")
    eq(owned_field(env, urls[1], "probe_fails"), 2,
        "the counter still climbs while spared, so a real outage is not waited out forever")

    -- 前提一消失（这次只有一条被判定）就立刻动手：保险丝不是免死牌
    env.probed[urls[2]] = { models = { "m2" } }
    advance(env, 2030)
    watcher.reconcile(env.state)
    eq(#env.unregistered, 1, "once the pass condemns only one, it goes")
    eq(env.unregistered[1], "id-" .. urls[1], "and it is the one still failing")

    local off = pool(false)                                      -- SMG_WATCHER_PROBE_FUSE=0
    advance(off, 2000)
    watcher.reconcile(off.state)
    advance(off, 2015)
    watcher.reconcile(off.state)
    eq(#off.unregistered, 2, "with the fuse off the same pass evicts both")
    eq(logged(off, "probe fuse"), 0, "and nothing is claimed to be rescued")
    eq(off.ledger.get_owned(urls[3]) ~= nil, true, "the healthy worker was never touched")

    -- 一半以下不触发：owned=4 摘 2 条是正常规模的动作
    local four = harness({ candidates = {
        candidate(urls[1], "proc"), candidate(urls[2], "proc"),
        candidate("http://d:8000", "proc"), candidate("http://e:8000", "proc"),
    } })
    claim_workers(four, {
        { url = urls[1], model_id = "m1" }, { url = urls[2], model_id = "m2" },
        { url = "http://d:8000", model_id = "m4" }, { url = "http://e:8000", model_id = "m5" },
    })
    fail_probe(four, urls[1], "no /v1/models answer")
    fail_probe(four, urls[2], "no /v1/models answer")
    advance(four, 2000)
    watcher.reconcile(four.state)
    advance(four, 2015)
    watcher.reconcile(four.state)
    eq(#four.unregistered, 2, "half the pool is not more than half: no fuse")
    eq(logged(four, "probe fuse"), 0, "and no fuse warn is logged")
end

new_case("a whole discovery source vanishing is not a pool-wide eviction")
do
    -- 最容易在后续改动里被写坏的一条：发现源整体挂掉（docker.sock 读不到、
    -- /proc 读不到）会让所有 owned 条目「本轮没被探到」，那既不是探针失败
    -- 也不是整池死刑，必须仍旧只起 missing_since 时钟。
    local urls = { "http://x:8000", "http://y:8000", "http://z:8000" }
    local env = harness({ candidates = {
        candidate(urls[1], "docker"), candidate(urls[2], "docker"), candidate(urls[3], "docker"),
    } })
    claim_workers(env, {
        { url = urls[1], model_id = "m1" },
        { url = urls[2], model_id = "m2" },
        { url = urls[3], model_id = "m3" },
    })
    local registered = #env.registered

    env.state.candidates = {}
    advance(env, 2000)
    watcher.reconcile(env.state)
    eq(#env.unregistered, 0, "an empty discovery pass deletes nothing")
    eq(logged(env, "probe failed"), 0, "and nothing is blamed on the probe")
    eq(logged(env, "probe fuse"), 0, "the fuse is a probe device, not a discovery one")
    for i = 1, #urls do
        eq(env.ledger.get_owned(urls[i]).missing_since, 2000,
            "each owned entry starts the grace clock instead")
    end

    -- 时钟走完仍旧走守卫 5/6 的正常分支（这里 keep-last 关掉，免得三条同模型互保）
    env.cfg.keep_last_grace_secs = -1
    advance(env, 2000 + 301)
    watcher.reconcile(env.state)
    eq(#env.unregistered, 3, "past the grace the undiscovered path still reaps them")
    eq(#env.registered, registered, "no extra add happened on the way")
    eq(logged(env, "(undiscovered, gone"), 3, "each removal is attributed to discovery, not the probe")
end

new_case("a config-declared upstream is immune to the probe verdict")
do
    -- 守卫 4 的边界不因第 10 条守卫松动：config_store 声明的 upstream 由配置拥有，
    -- 探针结论再确定也不能替操作员删它（判定与保险丝的计数也都排除它）。
    local url = "http://by-config:8000"
    local env = harness({ candidates = { candidate(url, "proc") } })
    register_and_claim(env, url, "m")
    env.state.actual[url].discovery = "config"
    fail_probe(env, url, "/v1/models answers without data[].id")
    advance(env, 2000)
    local stats = watcher.reconcile(env.state)
    eq(#env.unregistered, 0, "the deterministic rejection does not delete a config member")
    check(env.state.actual[url] ~= nil, "its pool row stays")
    eq(env.ledger.get_owned(url), nil, "the ledger only stops claiming it (config owns the row)")
    eq(stats.probe_removes or 0, 0, "and the pass records no probe eviction")
end

--------------------------------------------------------------------------
-- 24. 每轮探测的预算闸门（doc/gap-cpu-idle-burn.md CPU 线第 1 条）
--------------------------------------------------------------------------
new_case("the per-pass probe budget knobs have defaults, overrides and clamps")
do
    local defaults = watcher.new_config(function() return nil end, 30000, 29000)
    eq(defaults.max_candidates, 32, "32 fresh candidates per pass by default")
    eq(defaults.pass_budget_secs, 5, "one pass costs at most 5 s of wall clock")
    eq(defaults.probe_fanout, 8, "the probe pool is 8 wide")
    -- 预算不得超过间隔：interval 缺省 15，所以 5 原样保留
    eq(defaults.pass_budget_secs <= defaults.interval_secs, true,
        "a pass cannot outlive its interval")

    local overrides = watcher.new_config(function(name)
        local table_of = {
            SMG_WATCHER_INTERVAL_SECS = "60",
            SMG_WATCHER_MAX_CANDIDATES = "5",
            SMG_WATCHER_PASS_BUDGET_SECS = "30",
            SMG_WATCHER_PROBE_FANOUT = "16",
        }
        return table_of[name]
    end, 30000, 0)
    eq(overrides.max_candidates, 5, "SMG_WATCHER_MAX_CANDIDATES override")
    eq(overrides.pass_budget_secs, 30, "SMG_WATCHER_PASS_BUDGET_SECS override")
    eq(overrides.probe_fanout, 16, "SMG_WATCHER_PROBE_FANOUT override")

    -- 0 = 不限制（旧行为），不是"一个都不探"
    local off = watcher.new_config(function(name)
        if name == "SMG_WATCHER_MAX_CANDIDATES" then return "0" end
        if name == "SMG_WATCHER_PASS_BUDGET_SECS" then return "0" end
        return nil
    end, 30000, 0)
    eq(off.max_candidates, 0, "an explicit 0 means unbudgeted")
    eq(off.pass_budget_secs, 0, "and so does the wall-clock one")

    -- 负数按"不限制"处理：钳成 0/负数的"一个都不探"会静默关掉整个发现层，
    -- 那是比烧核更糟的故障形状，所以这一侧的钳制方向必须是往"关"而不是往"1"。
    local neg = watcher.new_config(function(name)
        if name == "SMG_WATCHER_MAX_CANDIDATES" then return "-7" end
        if name == "SMG_WATCHER_PASS_BUDGET_SECS" then return "-7" end
        return nil
    end, 30000, 0)
    eq(neg.max_candidates, 0, "a negative count is the off switch, not a blackout")
    eq(neg.pass_budget_secs, 0, "same for the wall clock")

    -- 一轮墙钟不得超过间隔本身，否则 single-flight 锁会悄悄跳轮
    local tight = watcher.new_config(function(name)
        if name == "SMG_WATCHER_INTERVAL_SECS" then return "4" end
        if name == "SMG_WATCHER_PASS_BUDGET_SECS" then return "30" end
        return nil
    end, 30000, 0)
    eq(tight.pass_budget_secs, 4, "the pass budget is clamped to the interval")

    -- 池宽钳到 [1,32]：0 会让 probe_pool 一个候选都不拨
    local wide = watcher.new_config(function(name)
        if name == "SMG_WATCHER_PROBE_FANOUT" then return "0" end
        return nil
    end, 30000, 0)
    eq(wide.probe_fanout, 1, "fanout floors at 1")
    local wider = watcher.new_config(function(name)
        if name == "SMG_WATCHER_PROBE_FANOUT" then return "999" end
        return nil
    end, 30000, 0)
    eq(wider.probe_fanout, 32, "fanout caps at 32")
end

new_case("a budget-cut probe is the gateway saying nothing, not the worker failing")
do
    -- run_pass 把被预算切掉的候选交给这条理由。它必须落在"与对方无关"那一档：
    -- 既不计入摘除滞回、也不推进 missing_since 宽限，否则一次限流就会把活 worker 摘干净。
    eq(watcher.probe_verdict("probe skipped: pass budget"), nil,
        "the budget reason says nothing about the service")
    eq(watcher.probe_verdict("probe skipped: pass budget"),
        watcher.probe_verdict("no probe transport"),
        "it sits in the same bucket as a missing transport")
    -- 相邻文案不得误档：漏登记会掉进 "count"（攒两次就摘），那是最贵的错法。
    eq(watcher.probe_verdict("probe skipped: nothing else"), "count",
        "an unregistered probe-skipped wording stays conservative")
end


new_case("plan_probes: the owned prefix is exempt from both budget knobs")
do
    -- 每轮探测预算切错的代价不对称：切到台账活体 = 这一轮没人看过它，活 worker 会被摘
    -- （或僵尸活得更久）；切到噪音尾巴只是少一轮观测。所以「尾巴可切、活体不可切」必须
    -- 钉在最纯的一层（无 ngx、无字典、无端口）：在 live.run_pass 里切错，线上要几十轮才看得出来。
    local urls = {}
    for i = 1, 10 do
        urls[#urls + 1] = "http://127.0.0.1:3" .. string.format("%02d", 20 + i)
    end
    local owned = { [urls[4]] = true, [urls[9]] = true }

    local order, protected, cut = watcher.plan_probes(urls, owned, 0)
    eq(#order, #urls, "unbudgeted: everything is dialled")
    eq(protected, 2, "the exempt prefix is exactly the owned pool")
    eq(order[1], urls[4], "owned first, in stable (sorted) order")
    eq(order[2], urls[9], "both owned rows lead the list")
    eq(next(cut) == nil, true, "and nothing is cut when the cap is off")

    local order2, protected2, cut2 = watcher.plan_probes(urls, owned, 3)
    eq(protected2, 2, "the cap never shrinks the owned prefix")
    eq(#order2, 5, "owned + the capped fresh head")
    eq(cut2[urls[4]], nil, "an owned url is never in the cut set")
    eq(cut2[urls[9]], nil, "not even the owned row that sat mid-list")
    local ncut = 0
    for _ in pairs(cut2) do ncut = ncut + 1 end
    eq(ncut, 5, "the trimmed tail is reported by name")
    for i = 1, protected2 do
        check(owned[order2[i]] == true,
            "the protected prefix only ever holds owned rows", tostring(order2[i]))
    end
    for url in pairs(cut2) do
        check(owned[url] == nil, "the budget cuts noise, never the pool", url)
    end

    -- 台账里躺着一行现在已被自端口/排除规则过滤掉的 url：plan_probes 必须再认一次候选集，
    -- 否则等于绕过头顶那道过滤器去拨路由器自己（第二个真缺陷形状：自拨号）。
    local order3, protected3 = watcher.plan_probes(
        { "http://127.0.0.1:9001" }, { ["http://127.0.0.1:9000"] = true }, 0)
    eq(#order3, 1, "a ledger row outside the filtered candidate set is not dialled")
    eq(protected3, 0, "and it does not consume the protected prefix either")
    eq(order3[1], "http://127.0.0.1:9001", "only the surviving candidate is probed")
end

new_case("a cut candidate says nothing; a dialled one keeps its own verdict")
do
    -- probe() 的取值顺序是这条修复的另一半：只有被预算切掉的 url 才回答「本轮没拨」。
    -- 早先用整轮一个哨兵理由，会把「拨过但对端 5xx」一起吞掉 —— 那是滞回里最保守的一档，
    -- 吞掉它就等于让永远 5xx 的 worker 长生不老。
    local env = harness({ candidates = { candidate("http://127.0.0.1:8321") } })
    env.probed["http://127.0.0.1:8321"] = nil
    env.probe_reason["http://127.0.0.1:8321"] = "no /v1/models answer"
    local info, reason = env.state.probe("http://127.0.0.1:8321")
    eq(info, nil, "dialled-and-refused keeps the classify() reason")
    eq(reason, "no /v1/models answer", "it is not masked by the budget reason")
    eq(watcher.probe_verdict(reason), "count", "and it still counts toward eviction")
end


io.write(string.format("\n=== %d checks, %d failed ===\n", passed, failed))
for i = 1, #failures do
    io.write("FAILED: " .. failures[i] .. "\n")
end
os.exit(failed == 0 and 0 or 1)
