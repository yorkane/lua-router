#!/usr/bin/env luajit
-- watcher.lua 单测：探针分类、候选发现、ledger、reconcile 九条守卫。
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
                return nil
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
                env.actual[url] = nil
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
    env.actual["http://seed:8000"] = nil
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

    -- undiscovered: grace has not elapsed -> keep
    env.now = 2000
    env.state.now = env.now
    env.probed["http://new:8000"] = nil
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

    -- it disappears: the first absent pass only stamps missing_since
    env.probed[url] = nil
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
    env2.probed[url] = nil
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
    env3.probed[url] = nil
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
    env.probed[url] = nil
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

io.write(string.format("\n=== %d checks, %d failed ===\n", passed, failed))
for i = 1, #failures do
    io.write("FAILED: " .. failures[i] .. "\n")
end
os.exit(failed == 0 and 0 or 1)
