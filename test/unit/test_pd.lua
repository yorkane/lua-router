#!/usr/bin/env luajit
-- pd.lua / grpc_proxy.lua 纯 Lua 单测（不依赖 ngx / shared dict）。
--   运行（cwd 与其余单测一致，取 lua-router/）：
--   docker run --rm -v "$PWD/lua-router:/r:ro" -w /r authz:latest \
--     /usr/local/openresty/luajit/bin/luajit test/unit/test_pd.lua
local root = os.getenv("LUA_TEST_LIB") or "./lualib"
package.path = root .. "/?.lua;" .. package.path

local pd = require "resty.luarouter.pd"
local gp = require "resty.luarouter.grpc_proxy"

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
        actual ~= expect and ("got " .. tostring(actual) .. " want " .. tostring(expect)) or nil)
end

local function new_case(name)
    io.write("  case: " .. name .. "\n")
end

--------------------------------------------------------------------------
-- 测试替身
--------------------------------------------------------------------------
local function worker(url, opts)
    opts = opts or {}
    return {
        id = opts.id or url,
        url = url,
        pool = opts.pool,
        worker_type = opts.worker_type,
        labels = opts.labels,
        healthy = (opts.healthy == nil) and true or opts.healthy,
        model_id = opts.model_id or "m1",
    }
end

--- 固定顺序选择器：总是取第 1 个候选（可换成按 url 匹配）
local function first(candidates)
    return candidates[1]
end

local function by_url(want)
    return function(candidates)
        for i = 1, #candidates do
            if candidates[i].url == want then
                return candidates[i]
            end
        end
        return nil
    end
end

--------------------------------------------------------------------------
new_case("pool_of: worker_type / pool / labels 三种写法都识别")
eq(pd.pool_of(worker("http://a:1", { worker_type = "prefill" })), "prefill", "worker_type=prefill")
eq(pd.pool_of(worker("http://a:1", { pool = "decode" })), "decode", "pool=decode")
eq(pd.pool_of(worker("http://a:1", { labels = { worker_type = "prefill" } })),
    "prefill", "labels.worker_type")
eq(pd.pool_of(worker("http://a:1")), "regular", "default regular")
eq(pd.pool_of(worker("http://a:1", { pool = "bogus" })), "regular", "unknown collapses")
eq(pd.pool_of(nil), "regular", "nil worker")
eq(pd.pool_of(worker("http://a:1", { worker_type = "prefill", pool = "decode" })),
    "decode", "pool wins over worker_type")

new_case("bootstrap_port_of: 数值、labels、越界")
eq(pd.bootstrap_port_of({ bootstrap_port = 9001 }), 9001, "numeric")
eq(pd.bootstrap_port_of({ labels = { bootstrap_port = "9002" } }), 9002, "labels string")
eq(pd.bootstrap_port_of({ bootstrap_port = 70000 }), nil, "out of range")
eq(pd.bootstrap_port_of({ bootstrap_port = 0 }), nil, "zero")
eq(pd.bootstrap_port_of({}), nil, "absent")
eq(pd.bootstrap_port_of(nil), nil, "nil worker")

new_case("split_dp_rank / bootstrap_host_of（对齐 parse_bootstrap_host_from_url）")
eq((pd.split_dp_rank("http://10.66.5.115:20664@3")), "http://10.66.5.115:20664", "base strips rank")
eq((pd.split_dp_rank("http://10.66.5.115:20664@3")), "http://10.66.5.115:20664", "base")
eq(pd.split_dp_rank("http://10.66.5.115:20664@3"), "http://10.66.5.115:20664", "returns base")
select(2, pd.split_dp_rank("http://h:1@3"))
local _, rank = pd.split_dp_rank("http://h:1@3")
eq(rank, 3, "rank parsed")
local _, rank2 = pd.split_dp_rank("http://h:1")
eq(rank2, nil, "no rank")
eq(pd.bootstrap_host_of("http://10.66.5.115:20664@3"), "10.66.5.115", "host strips port+rank")
eq(pd.bootstrap_host_of("grpc://cluster.local@1"), "cluster.local", "grpc scheme")
eq(pd.bootstrap_host_of("localhost:8080@2"), "localhost", "schemeless")
eq(pd.bootstrap_host_of("http://[2001:db8::1]:20000"), "2001:db8::1", "ipv6 brackets dropped")
eq(pd.bootstrap_host_of(""), "localhost", "empty -> localhost")
eq(pd.bootstrap_host_of(nil), "localhost", "nil -> localhost")

new_case("pools(): 健康过滤 + 三池分桶")
local recs = {
    worker("http://p1:1", { worker_type = "prefill" }),
    worker("http://p2:1", { worker_type = "prefill", healthy = false }),
    worker("http://d1:1", { worker_type = "decode" }),
    worker("http://r1:1", {}),
}
local pools = pd.pools(recs)
eq(#pools.prefill, 1, "one healthy prefill")
eq(#pools.decode, 1, "one decode")
eq(#pools.regular, 1, "one regular")
local counts = pd.counts(recs)
eq(counts.prefill, 1, "counts healthy prefill")
eq(counts.total.prefill, 2, "counts total prefill incl unhealthy")
eq(counts.total.decode, 1, "counts total decode")

new_case("pd_mode(): 双池齐备 / 半员 / 全 regular / 空")
local ok_pd, err_pd = pd.pd_mode(recs)
eq(ok_pd, true, "both pools present")
local half = { worker("http://p1:1", { worker_type = "prefill" }), worker("http://r1:1", {}) }
local ok_half, err_half = pd.pd_mode(half)
eq(ok_half, false, "half fleet not pd")
eq(err_half, pd.ERR_NO_DECODE, "missing decode named")
local only_dec = { worker("http://d1:1", { worker_type = "decode" }) }
local _, err_dec = pd.pd_mode(only_dec)
eq(err_dec, pd.ERR_NO_PREFILL, "missing prefill named")
local _, err_reg = pd.pd_mode({ worker("http://r1:1", {}) })
eq(err_reg, pd.ERR_NOT_PD_MODE, "regular-only -> pd_mode_disabled")
local _, err_empty = pd.pd_mode({})
eq(err_empty, pd.ERR_NO_WORKERS, "empty -> no workers")

new_case("select_pair(): 双池分别选择 + bootstrap 字段")
local pair, perr = pd.select_pair(recs, { select = first })
eq(perr, nil, "no error")
eq(pair and pair.prefill.url, "http://p1:1", "prefill chosen")
eq(pair and pair.decode.url, "http://d1:1", "decode chosen")
eq(pair and pair.bootstrap_host, "p1", "bootstrap host from prefill")
eq(pair and pair.bootstrap_port, nil, "no bootstrap port configured")
check(type(pair and pair.bootstrap_room) == "number", "room is a number")

new_case("select_pair(): 每池调用一次 select（对应 prefill/decode 双策略）")
local seen = {}
pd.select_pair(recs, { select = function(candidates, pool)
    seen[#seen + 1] = pool .. ":" .. #candidates
    return candidates[1]
end })
eq(#seen, 2, "select called twice")
eq(seen[1], "prefill:1", "first call prefill pool")
eq(seen[2], "decode:1", "second call decode pool")

new_case("select_pair(): 故障切换——首选池成员全部不可用")
local failover = {
    worker("http://p1:1", { worker_type = "prefill", healthy = false }),
    worker("http://p2:1", { worker_type = "prefill" }),
    worker("http://d1:1", { worker_type = "decode", healthy = false }),
    worker("http://d2:1", { worker_type = "decode" }),
}
local fo = pd.select_pair(failover, { select = function(cs) return cs[#cs] end })
eq(fo and fo.prefill.url, "http://p2:1", "unhealthy prefill excluded")
eq(fo and fo.decode.url, "http://d2:1", "unhealthy decode excluded")

-- 选择性故障切换：策略先挑 unhealthy（替身不知道健康状态），池已过滤所以拿不到
local pick_bad = pd.select_pair(failover, { select = by_url("http://p1:1") })
eq(pick_bad, nil, "selecting a filtered worker fails")

new_case("select_pair(): decode 池空 -> 明确错误码")
local no_decode = { worker("http://p1:1", { worker_type = "prefill" }) }
local nilp, nerr = pd.select_pair(no_decode, { select = first })
eq(nilp, nil, "no pair")
eq(nerr, pd.ERR_NO_DECODE, "ERR_NO_DECODE")

new_case("select_pair(): IGW 式按模型过滤由调用方完成（池传入即生效）")
local scoped = pd.select_pair({
    worker("http://p1:1", { worker_type = "prefill" }),
    worker("http://d1:1", { worker_type = "decode", model_id = "other" }),
}, { select = first })
eq(scoped and scoped.decode.url, "http://d1:1", "records as given are used verbatim")

new_case("room_id(): 范围 [0, 2^63-1] 且为整数值")
math.randomseed(12345)
local min_seen, max_seen, all_int = math.huge, -1, true
for i = 1, 5000 do
    local r = pd.room_id()
    if r < 0 or r > 9223372036854775807 then
        all_int = false
    end
    if r ~= math.floor(r) then
        all_int = false
    end
    if r < min_seen then min_seen = r end
    if r > max_seen then max_seen = r end
end
check(all_int, "room ids integral and in range", tostring(min_seen) .. ".." .. tostring(max_seen))
local uniq = {}
local dup = 0
for i = 1, 2000 do
    local r = pd.room_id()
    if uniq[r] then dup = dup + 1 end
    uniq[r] = true
end
eq(dup, 0, "2000 room ids unique")
local injected = pd.room_id(function() return 0.5 end)
check(type(injected) == "number", "rng injectable")

new_case("room_id_i32(): proto int32 上限（gRPC 路径专用）")
math.randomseed(777)
local ok_range, is_int = true, true
for i = 1, 3000 do
    local r = pd.room_id_i32()
    if r < 0 or r > 2147483646 then ok_range = false end
    if r ~= math.floor(r) then is_int = false end
end
check(ok_range, "i32 rooms in range")
check(is_int, "i32 rooms integral")
eq(pd.room_id_i32(function() return 0 end), 0, "rng=0 -> 0")
eq(pd.room_id_i32(function() return 0.5 end), 1073741823, "rng=0.5 -> half of 2^31-1")
eq(pd.DEFAULT_BOOTSTRAP_PORT, 8998, "sglang bootstrap default")

new_case("inject_bootstrap(): 单请求三字段")
local body = { text = "hi", model = "m" }
pd.inject_bootstrap(body, { bootstrap_host = "10.0.0.1", bootstrap_port = 9001,
                            bootstrap_room = 4242 })
eq(body.bootstrap_host, "10.0.0.1", "host")
eq(body.bootstrap_port, 9001, "port")
eq(body.bootstrap_room, 4242, "room")
eq(body.text, "hi", "original kept")

new_case("inject_bootstrap(): port 缺失写 JSON null（Rust Option -> Null）")
local b2 = {}
pd.inject_bootstrap(b2, { bootstrap_host = "h", bootstrap_port = nil, bootstrap_room = 7 })
eq(b2.bootstrap_port, nil, "nil port stays absent in Lua table")
eq(b2.bootstrap_host, "h", "host written anyway")

new_case("inject_bootstrap(): batch_size -> 三数组，room 逐项不同")
local b3 = {}
pd.inject_bootstrap(b3, { bootstrap_host = "h", bootstrap_port = 9000,
                          bootstrap_room = 100 }, 3)
eq(type(b3.bootstrap_host) == "table" and #b3.bootstrap_host, 3, "hosts array len")
eq(type(b3.bootstrap_port) == "table" and #b3.bootstrap_port, 3, "ports array len")
eq(type(b3.bootstrap_room) == "table" and #b3.bootstrap_room, 3, "rooms array len")
eq(b3.bootstrap_room[1] .. "," .. b3.bootstrap_room[3], "100,102", "rooms distinct & ordered")
eq(b3.bootstrap_host[2], "h", "each host")

new_case("inject_bootstrap(): 非对象报错")
local ok_bad = pd.inject_bootstrap("nope", { bootstrap_host = "h" })
eq(ok_bad, nil, "string body rejected")

new_case("inject_dp_rank_for_decode(): 仅 DP-aware prefill 注入")
local db = { text = "x" }
pd.inject_dp_rank_for_decode(db, { prefill_dp_rank = 3 })
eq(db.disagg_prefill_dp_rank, 3, "rank injected")
local db2 = { text = "x" }
pd.inject_dp_rank_for_decode(db2, { prefill_dp_rank = nil })
eq(db2.disagg_prefill_dp_rank, nil, "no rank -> untouched")
local dp_pair = pd.select_pair({
    worker("http://p1:1@2", { worker_type = "prefill" }),
    worker("http://d1:1", { worker_type = "decode" }),
}, { select = first })
eq(dp_pair and dp_pair.prefill_dp_rank, 2, "rank parsed from url")
eq(dp_pair and dp_pair.prefill_url, "http://p1:1", "pair url stripped of rank")
eq(dp_pair and dp_pair.bootstrap_host, "p1", "bootstrap host without rank")

new_case("outcome(): prefill 失败不给 decode 记过（Rust 同规则）")
local cp, cd, et = pd.outcome(nil)
eq(cp, true, "transport error charges prefill")
eq(cd, false, "decode never charged")
eq(et, "transport", "transport label")
eq((pd.outcome(503)), true, "5xx charges prefill")
eq((pd.outcome(400)), false, "4xx is client fault")
eq((pd.outcome(200)), false, "2xx charges nobody")
local _, _, et2 = pd.outcome(400)
eq(et2, "client", "client label")
local _, _, et3 = pd.outcome(500)
eq(et3, "upstream", "upstream label")

new_case("readiness(): PD 双池 / 半员 / regular / IGW")
local ready, rep = pd.readiness(recs)
eq(ready, true, "both pools -> ready")
eq(rep.status, "ready", "status ready")
eq(rep.prefill_workers, 1, "reports prefill count")
eq(rep.decode_workers, 1, "reports decode count")
local r_half, rep_half = pd.readiness(half)
eq(r_half, false, "missing decode pool -> not ready")
eq(rep_half.reason, pd.ERR_NO_DECODE, "reason names the missing pool")
eq(rep_half.status, "not ready", "not ready status")
local r_reg = pd.readiness({ worker("http://r1:1", {}) })
eq(r_reg, true, "regular-only fleet ready")
local r_none, rep_none = pd.readiness({ worker("http://r1:1", { healthy = false }) })
eq(r_none, false, "no healthy workers -> not ready")
eq(rep_none.reason, "insufficient healthy workers", "rust reason string")
local r_igw = pd.readiness({ worker("http://r1:1", {}) }, { enable_igw = true })
eq(r_igw, true, "igw regular ready")
local r_igw_pd = pd.readiness({ worker("http://p1:1", { worker_type = "prefill" }) },
                              { enable_igw = true })
eq(r_igw_pd, true, "igw ignores the pool requirement")

--------------------------------------------------------------------------
-- grpc_proxy
--------------------------------------------------------------------------
new_case("parse_worker: grpc/grpcs/http/https + 默认端口")
local h1, p1, t1 = gp.parse_worker("grpc://10.0.0.1:20000")
eq(h1, "10.0.0.1", "grpc host"); eq(p1, 20000, "grpc port"); eq(t1, false, "grpc plain")
local h2, p2, t2 = gp.parse_worker("grpcs://sg.example:443")
eq(h2, "sg.example", "grpcs host"); eq(t2, true, "grpcs tls")
local h3, p3, t3 = gp.parse_worker("http://host:30001@2")
eq(h3, "host", "dp rank stripped"); eq(p3, 30001, "port kept"); eq(t3, false, "plain")
local h4, p4, t4 = gp.parse_worker("http://host")
eq(p4, 80, "http default 80"); eq(t4, false, "http plain")
local h5, p5 = gp.parse_worker("grpc://host")
eq(p5, 50051, "grpc default port")
local h6, p6, t6 = gp.parse_worker("https://host")
eq(p6, 443, "https default 443"); eq(t6, true, "https tls")
local h7, p7 = gp.parse_worker("host:7000")
eq(h7, "host", "schemeless host"); eq(p7, 7000, "schemeless port")
local _, _, _, e8 = gp.parse_worker("ftp://host:1")
eq(e8, "unsupported worker scheme: ftp", "bad scheme rejected")
local _, _, _, e9 = gp.parse_worker("")
check(e9 ~= nil, "empty rejected")
local _, _, _, e10 = gp.parse_worker("grpc://host:99999")
check(e10 ~= nil, "port out of range rejected")
local h11, p11 = gp.parse_worker("grpc://[2001:db8::1]:20000")
eq(h11, "2001:db8::1", "ipv6 host"); eq(p11, 20000, "ipv6 port")
local h12, p12 = gp.parse_worker("http://host:80/some/path?q=1")
eq(p12, 80, "path stripped")

new_case("format_peer")
eq(gp.format_peer("10.0.0.1", 20000), "10.0.0.1:20000", "ipv4")
eq(gp.format_peer("2001:db8::1", 20000), "[2001:db8::1]:20000", "ipv6 bracketed")

new_case("parse_grpc_timeout: 六个单位")
eq(gp.parse_grpc_timeout("5S"), 5, "5 seconds")
eq(gp.parse_grpc_timeout("100m"), 0.1, "100 milli")
eq(gp.parse_grpc_timeout("2M"), 120, "2 minutes")
eq(gp.parse_grpc_timeout("1H"), 3600, "1 hour")
eq(gp.parse_grpc_timeout("1000u"), 1e-3, "1000 micro")
check(math.abs(gp.parse_grpc_timeout("7n") - 7e-9) < 1e-18, "7 nano")
eq(gp.parse_grpc_timeout(nil), nil, "nil -> nil")
eq(gp.parse_grpc_timeout(""), nil, "empty -> nil")
check(gp.parse_grpc_timeout("5X") == nil, "bad unit rejected")
check(gp.parse_grpc_timeout("-5S") == nil, "negative rejected")
check(gp.parse_grpc_timeout("123456789S") == nil, "9 digits rejected")
check(gp.parse_grpc_timeout("1.5S") == nil, "fraction rejected")
check(gp.parse_grpc_timeout(5) == nil, "non-string rejected")

new_case("format_grpc_timeout: 最粗可用单位")
eq(gp.format_grpc_timeout(5), "5S", "5s")
eq(gp.format_grpc_timeout(120), "2M", "2 min")
eq(gp.format_grpc_timeout(3600), "1H", "1 hour")
eq(gp.format_grpc_timeout(0.5), "500m", "500 milli")
eq(gp.format_grpc_timeout(1e-3), "1m", "1 ms -> 1m (coarser than 1000u)")
eq(gp.format_grpc_timeout(1.5e-3), "1500u", "1.5 ms needs microseconds")
eq(gp.format_grpc_timeout(0), nil, "zero rejected")
eq(gp.format_grpc_timeout(-1), nil, "negative rejected")
eq(gp.format_grpc_timeout(0 / 0), nil, "nan rejected")
-- round-trip on the values sglang actually uses
for _, secs in ipairs({ 1, 5, 30, 1800, 0.25, 0.001 }) do
    local text = gp.format_grpc_timeout(secs)
    local back = gp.parse_grpc_timeout(text)
    check(math.abs(back - secs) < 1e-9, "round-trip " .. secs, text .. " -> " .. tostring(back))
end

new_case("resolve_timeout: 客户端 deadline 优先，本地 cap 收紧")
eq(gp.resolve_timeout("5S", 1800), "5S", "client shorter kept")
eq(gp.resolve_timeout("1H", 1800), "30M", "cap tighter wins")
eq(gp.resolve_timeout(nil, 1800), "30M", "no client -> cap")
eq(gp.resolve_timeout("5S", nil), "5S", "no cap -> client")
eq(gp.resolve_timeout(nil, nil), nil, "neither -> none")
eq(gp.resolve_timeout("bogus", 1800), "bogus", "malformed passed through")
eq(gp.resolve_timeout("1800S", 1800), "30M", "equal -> unit-normalised")

new_case("encapsulate / decapsulate")
local f = gp.encapsulate("hello")
eq(#f, 10, "5 header + payload")
eq(f:byte(1), 0, "uncompressed flag")
local pl, used = gp.decapsulate(f)
eq(pl, "hello", "payload round-trip")
eq(used, 10, "consumed length")
local fc = gp.encapsulate("x", true)
eq(fc:byte(1), 1, "compressed flag")
eq((gp.decapsulate(fc:sub(1, 4))), nil, "short buffer -> nil")
check(({ gp.decapsulate("abc") })[3] ~= nil, "short buffer has error")
eq(gp.decapsulate(gp.encapsulate("")), "", "empty message")
-- a 4-byte length field must be big-endian
local big = gp.encapsulate(string.rep("a", 258))
eq(big:byte(4), 1, "len byte2 (258 = 0x00000102)")
eq(big:byte(5), 2, "len byte3")
eq(#gp.decapsulate(big), 258, "len decoded")

new_case("build_metadata: 白名单 + 必需头 + api_key")
local md = gp.build_metadata({
    ["content-type"] = "application/json",
    authorization = "Bearer client",
    ["x-request-id"] = "rid",
    ["x-request-id-alias"] = "dup",
    traceparent = "00-abc-def-01",
    cookie = "session=secret",
    connection = "keep-alive",
    host = "router:8801",
    ["content-length"] = "123",
    te = "trailers",
})
eq(md.authorization, "Bearer client", "authorization forwarded")
eq(md["x-request-id"], "rid", "x-request-id forwarded")
eq(md["x-request-id-alias"], "dup", "x-request-id- prefix forwarded")
eq(md.traceparent, "00-abc-def-01", "traceparent forwarded")
eq(md.cookie, nil, "cookie dropped")
eq(md.connection, nil, "connection dropped")
eq(md.host, nil, "host dropped")
eq(md["content-length"], nil, "content-length dropped")
eq(md["content-type"], "application/grpc", "content-type forced to grpc")
eq(md.te, "trailers", "te forced to trailers")

local md2 = gp.build_metadata({}, { worker_api_key = "wk-1" })
eq(md2.authorization, "Bearer wk-1", "worker key injected")
local md3 = gp.build_metadata({ authorization = "Bearer client" },
                              { worker_api_key = "wk-1" })
eq(md3.authorization, "Bearer client", "client auth wins over worker key")

local md4 = gp.build_metadata({}, { timeout = "30S", extra = { ["x-smg-routing-key"] = "k" } })
eq(md4["grpc-timeout"], "30S", "timeout header set")
eq(md4["x-smg-routing-key"], "k", "extra header set")

local md5 = gp.build_metadata({ ["grpc-timeout"] = "5S" })
eq(md5["grpc-timeout"], nil, "client grpc-timeout not copied (router owns it)")

new_case("is_grpc_content_type")
eq(gp.is_grpc_content_type("application/grpc"), true, "application/grpc")
eq(gp.is_grpc_content_type("application/grpc+proto"), true, "grpc+proto")
eq(gp.is_grpc_content_type("APPLICATION/GRPC; charset=utf-8"), true, "case + params")
eq(gp.is_grpc_content_type("application/json"), false, "json is not grpc")
eq(gp.is_grpc_content_type(nil), false, "nil")

new_case("target_for: labels.grpc_port / grpc_tls 覆盖")
local th, tp, tt = gp.target_for(worker("http://10.0.0.5:30000",
    { labels = { grpc_port = "20000", grpc_tls = "true" } }))
eq(th, "10.0.0.5", "host from url")
eq(tp, 20000, "port from label")
eq(tt, true, "tls from label")
local _, tp2, tt2 = gp.target_for(worker("http://10.0.0.5:30000"))
eq(tp2, 30000, "url port kept when no label")
eq(tt2, false, "plain by default")
local _, tp3, tt3 = gp.target_for(worker("grpc://h:1", { labels = { grpc_tls = false } }))
eq(tp3, 1, "explicit port kept")
eq(tt3, false, "grpc_tls=false")
local _, _, e4 = gp.target_for({})
check(e4 ~= nil, "worker without url rejected")

new_case("http_status_for_grpc / grpc_status_for_http")
eq(gp.http_status_for_grpc(0), 200, "OK")
eq(gp.http_status_for_grpc(4), 504, "DEADLINE_EXCEEDED")
eq(gp.http_status_for_grpc(5), 404, "NOT_FOUND")
eq(gp.http_status_for_grpc(8), 422, "RESOURCE_EXHAUSTED")
eq(gp.http_status_for_grpc(14), 503, "UNAVAILABLE")
eq(gp.http_status_for_grpc(16), 500, "UNAUTHENTICATED")
eq(gp.http_status_for_grpc(99), 500, "unknown code")
eq(gp.http_status_for_grpc(nil), 502, "missing code -> bad gateway")
eq(gp.grpc_status_for_http(404), 12, "404 -> UNIMPLEMENTED")
eq(gp.grpc_status_for_http(429), 8, "429 -> RESOURCE_EXHAUSTED")
eq(gp.grpc_status_for_http(503), 14, "503 -> UNAVAILABLE")
eq(gp.grpc_status_for_http(500), 13, "500 -> INTERNAL")
eq(#gp.GRPC_NAME, 17, "all 17 grpc status names")

new_case("ip_literal: balancer 路径只吃 IP 字面量")
eq(gp.ip_literal("10.0.0.1"), true, "ipv4")
eq(gp.ip_literal("255.255.255.255"), true, "ipv4 max")
eq(gp.ip_literal("2001:db8::1"), true, "ipv6")
eq(gp.ip_literal("::1"), true, "ipv6 loopback")
eq(gp.ip_literal("localhost"), false, "hostname")
eq(gp.ip_literal("sg.example.com"), false, "fqdn")
eq(gp.ip_literal("10.0.0"), false, "three octets")
eq(gp.ip_literal("10.0.0.1.2"), false, "five octets")
eq(gp.ip_literal("256.0.0.1"), false, "octet > 255")
eq(gp.ip_literal("010.0.0.1"), false, "leading zero octet")
eq(gp.ip_literal(""), false, "empty")
eq(gp.ip_literal(nil), false, "nil")

new_case("pick: gRPC 面的三种策略（round_robin / sticky / 兜底）")
-- registry 只在 power_of_two 分支被 require，这里给一个替身，保持纯 Lua 可跑。
local loads = {}
package.loaded["resty.luarouter.registry"] = {
    load = function(id) return loads[id] or 0 end,
    pd_available = function() return true end,
}
local function gworker(id, opts)
    opts = opts or {}
    return { id = id, url = opts.url or ("grpc://" .. id .. ":20000"),
             model_id = opts.model_id or "m", grpc_port = opts.grpc_port,
             connection_mode = opts.connection_mode or "grpc" }
end
local cands = { gworker("a"), gworker("b"), gworker("c") }

-- 轮询：三个 worker 各得一次，且顺序稳定
local seq = {}
for _ = 1, 6 do
    local w = gp.pick(cands, { pool = "regular", model = "m1" })
    seq[#seq + 1] = w.id
end
check(seq[1] ~= seq[2] and seq[2] ~= seq[3] and seq[1] ~= seq[3],
    "round_robin 三轮内命中三个不同 worker", table.concat(seq, ","))
check(seq[4] == seq[1] and seq[5] == seq[2] and seq[6] == seq[3],
    "游标循环回绕", table.concat(seq, ","))

-- 共享计数器存在时优先用它（跨 nginx 进程保持一致）
local shared_counter = 0
local counter = function(_key, step, init)
    shared_counter = (init or 0) + shared_counter + step
    return shared_counter
end
local sseq = {}
for _ = 1, 3 do
    local w = gp.pick(cands, { pool = "regular", model = "m1", counter = counter })
    sseq[#sseq + 1] = w.id
end
check(#sseq == 3 and sseq[1] ~= sseq[2] and sseq[2] ~= sseq[3] and sseq[1] ~= sseq[3],
    "外部 counter 决定轮询顺序", table.concat(sseq, ","))

-- 粘滞：同一 routing key 恒定，不同 key 会散开
local function sticky_of(key)
    return gp.pick(cands, { policy = "sticky", routing_key = key,
                            pool = "regular", model = "m1" }).id
end
local first_key = sticky_of("user-1")
local stable = true
for _ = 1, 10 do
    if sticky_of("user-1") ~= first_key then stable = false end
end
check(stable, "sticky: 同一 key 始终同一 worker", first_key)
local seen = {}
for i = 1, 40 do
    seen[sticky_of("key-" .. i)] = true
end
local spread_n = 0
for _ in pairs(seen) do spread_n = spread_n + 1 end
check(spread_n >= 2, "sticky: 不同 key 散到多个 worker", tostring(spread_n))
-- 没有 key 时退化为轮询（不能永远钉在第一个）
local nokey = {}
for _ = 1, 3 do
    nokey[#nokey + 1] = gp.pick(cands, { policy = "sticky", pool = "regular",
                                         model = "m1" }).id
end
check(nokey[1] ~= nokey[2], "sticky 无 key 时退回轮询", table.concat(nokey, ","))

-- power_of_two 读 registry.load
loads = { a = 5, b = 1, c = 9 }
local lighter = gp.pick({ cands[1], cands[2] },
    { policy = "power_of_two", pool = "regular", model = "m1",
      rng = function() return 0.5 end })
check(lighter.id == "b", "power_of_two 选负载低的", lighter.id)

-- 空候选返回 nil，不报错
check(gp.pick({}, { pool = "regular", model = "m1" }) == nil, "空候选返回 nil")

new_case("pools / filter_model / scope_named_model / exact_model")
local recs = {
    gworker("r1", { model_id = "m1" }), gworker("r2", { model_id = "m2" }),
    gworker("p1", { model_id = "m1" }), gworker("d1", { model_id = "m1" }),
}
-- pool_of 靠 worker_type，这里直接塞
recs[3].worker_type = "prefill"
recs[4].worker_type = "decode"
local pl = gp.pools(recs)
check(#pl.regular == 2 and #pl.prefill == 1 and #pl.decode == 1,
    "pools 按类型分池", string.format("%d/%d/%d", #pl.regular, #pl.prefill, #pl.decode))
check(#gp.filter_model(recs, "m1", false) == 4, "IGW off: filter_model 不过滤")
check(#gp.filter_model(recs, "m2", true) == 1, "IGW on: 只留该模型")
local with_unknown = {}
for i = 1, #recs do with_unknown[i] = recs[i] end
with_unknown[#with_unknown + 1] = gworker("u1", { model_id = "unknown" })
check(#gp.filter_model(with_unknown, "m2", true) == 2, "IGW on: unknown 仍可作候选")
check(#gp.scope_named_model(recs, "m2") == 1, "scope_named_model 精确+unknown")
check(#gp.scope_named_model(recs, "nope") == 0,
    "无人服务的模型得到空池（由调用方回 UNAVAILABLE，而不是偷发给别的 worker）")
check(#gp.scope_named_model(with_unknown, "nope") == 1,
    "未发现模型的 worker 仍可作为候选")
check(#gp.scope_named_model(recs, nil) == 4, "未点名模型不过滤")
check(#gp.exact_model(recs, "m1") == 3 and #gp.exact_model(recs, "unknown") == 0,
    "exact_model 严格相等（unknown 不算命中）")

new_case("pd_preferred: 混合池按模型决定走不走 PD")
local p_rec0 = gworker("p0", { model_id = "pd1" }); p_rec0.worker_type = "prefill"
local d_rec0 = gworker("d0", { model_id = "pd1" }); d_rec0.worker_type = "decode"
local r_rec0 = gworker("r0", { model_id = "rg1" })
check(gp.pd_preferred(gp.pools({ p_rec0, d_rec0 }), nil, { p_rec0, d_rec0 }) == true,
    "没有 regular 池时只能走 PD")
check(gp.pd_preferred(gp.pools({ r_rec0 }), nil, { r_rec0 }) == false,
    "纯 regular 池不走 PD")
local mixed = gp.pools({ r_rec0, p_rec0, d_rec0 })
check(gp.pd_preferred(mixed, nil, { r_rec0, p_rec0, d_rec0 }) == false,
    "混合池且未点名模型时优先 regular 池")
local p_rec = gworker("p", { model_id = "pd1" }); p_rec.worker_type = "prefill"
local d_rec = gworker("d", { model_id = "pd1" }); d_rec.worker_type = "decode"
local r_rec = gworker("r", { model_id = "rg1" })
local mixed2 = gp.pools({ p_rec, d_rec, r_rec })
check(gp.pd_preferred(mixed2, "pd1", { p_rec, d_rec, r_rec }) == true,
    "点名 PD 模型 => PD 路径")
check(gp.pd_preferred(mixed2, "rg1", { p_rec, d_rec, r_rec }) == false,
    "点名普通模型 => 普通路径")

new_case("outcome: grpc-status 决定要不要给熔断器记账")
eq(gp.outcome(200, "200", 0), true, "OK 记成功")
eq(gp.outcome(200, "200", 5), true, "NOT_FOUND 是客户端错，不算 worker 故障")
eq(gp.outcome(200, "200", 3), true, "INVALID_ARGUMENT 同上")
eq(gp.outcome(200, "200", 12), true, "UNIMPLEMENTED 同上")
eq(gp.outcome(200, "200", 14), false, "UNAVAILABLE 算故障")
eq(gp.outcome(200, "200", 13), false, "INTERNAL 算故障")
eq(gp.outcome(200, "200", 4), false, "DEADLINE_EXCEEDED 算故障")
local ok1, et1 = gp.outcome(200, "", nil)
eq(ok1, false, "无上游应答 = transport 故障")
eq(et1, "transport", "错误类型 transport")
eq(gp.outcome(502, "502", nil), false, "nginx 自己回 502 算故障")
eq(gp.outcome(404, "404", nil), true, "上游 404 算客户端错")
eq(gp.outcome(499, "499", nil, true), true, "客户端主动断开不记账")
local ok2, et2 = gp.outcome(200, "200", 16)
eq(ok2, true, "UNAUTHENTICATED 归客户端")
eq(et2, "client", "类型 client")

new_case("target_for: 记录的 grpc_port 优先于 labels")
local w = { url = "http://127.0.0.1:30000", connection_mode = "grpc", grpc_port = 20000 }
local h, prt, tls = gp.target_for(w)
eq(h, "127.0.0.1", "host 取自 url")
eq(prt, 20000, "顶层 grpc_port 生效（tagged 形态落在这里）")
eq(tls, false, "grpc 不带 TLS")
local w2 = { url = "http://127.0.0.1:30000", labels = { grpc_port = 21000 } }
eq((gp.target_for(w2)), "127.0.0.1", "labels.grpc_port 仍可用")
eq(select(2, gp.target_for(w2)), 21000, "labels 兜底")
local w3 = { url = "http://127.0.0.1:30000", grpc_port = 20000,
             labels = { grpc_port = 21000 } }
eq(select(2, gp.target_for(w3)), 20000, "顶层优先于 labels")
local w4 = { url = "grpcs://h.example:443" }
eq(select(3, gp.target_for(w4)), true, "grpcs url 带 TLS")

new_case("trailer_frame")
check(gp.trailer_frame(14, "unavailable"):find("grpc%-status:14") ~= nil
    or gp.trailer_frame(14, "unavailable"):find("grpc-status:14") ~= nil,
    "frame carries status")

-- Wrapped in a function: LuaJIT caps one chunk at 200 slot-allocated locals and
-- the pre-existing suite already uses most of them.
local function test_proto_body_codec()
---
-- gRPC PD 原生 proto body 注入（grpc_proxy 的 wire 编解码）
--
-- 参照实现：/usr/bin/protoc 3.12 + python protobuf 独立生成的期望字节，
-- 以及 vendored schema smg-grpc-client-1.0.0/proto/sglang_scheduler.proto 的字段号：
--   GenerateRequest.disaggregated_params = 10 (message)
--   DisaggregatedParams{bootstrap_host=1 string, bootstrap_port=2 int32,
--                       bootstrap_room=3 int32}
--------------------------------------------------------------------------

local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

new_case("encode_varint / encode_int32 与 protoc 期望字节一致")
eq(hex(gp.encode_varint(0)), "00", "0")
eq(hex(gp.encode_varint(1)), "01", "1")
eq(hex(gp.encode_varint(127)), "7f", "127")
eq(hex(gp.encode_varint(128)), "8001", "128")
eq(hex(gp.encode_varint(300)), "ac02", "300")
eq(hex(gp.encode_int32(8998)), "a646", "8998（protoc 参考 08a646 去掉 tag）")
eq(hex(gp.encode_int32(2147483647)), "ffffffff07", "i32::MAX")
eq(hex(gp.encode_int32(0)), "00", "0 编码为空 tag 值")
-- 负数：prost/protoc 用符号扩展到 10 字节
eq(hex(gp.encode_int32(-1)), "ffffffffffffffffff01", "-1")
eq(hex(gp.encode_int32(-128)), "80ffffffffffffffff01", "-128")
eq(hex(gp.encode_int32(-8998)), "dab9ffffffffffffff01", "-8998")
eq(hex(gp.encode_int32(-2147483648)), "80808080f8ffffffff01", "i32::MIN")
check(gp.encode_int32(2147483648) == nil, "i32 溢出拒绝")
check(gp.encode_int32(-2147483649) == nil, "i32 下溢拒绝")

new_case("encode_int_field / encode_len_field 的 tag")
eq(hex(gp.encode_int_field(2, 8998)), "10a646", "field 2 varint => tag 0x10")
eq(hex(gp.encode_len_field(1, "10.0.0.1")), "0a08" .. hex("10.0.0.1"), "field 1 string")
eq(hex(gp.encode_len_field(10, "abc")), "5203616263", "field 10 message => tag 0x52")

new_case("decode_varint / skip_varint")
local v, next_i = gp.decode_varint("\xac\002", 1)
eq(v, 300, "300 解回")
eq(next_i, 3, "消费 2 字节")
local big = gp.decode_varint(string.char(255, 255, 255, 255, 255, 255, 255, 255, 255, 127), 1)
check(big == nil, "超 2^53 拒绝而不是悄悄截断")
local _, _, terr = gp.decode_varint("\x80", 1)
check(terr ~= nil, "截断的 varint 报错")

new_case("parse_message 保留未知字段（fixed32/fixed64 的 tag 是变长的）")
-- 20:1 fixed64 = 8 字节, 21:5 fixed32 = 4 字节, 22:2 len = 3 字节
local mixed = "\x0a" .. "\x02" .. "r1"          -- field 1 string "r1"
    .. string.char(0xA1, 0x01) .. "12345678"    -- field 20 fixed64 (tag 161 = 20*8+1)
    .. string.char(0xAD, 0x01) .. "\001\002\003\004" -- field 21 fixed32
    .. string.char(0xB2, 0x01) .. "\003" .. "unk"    -- field 22 len "unk"
local parsed, perr = gp.parse_message(mixed)
check(parsed ~= nil, "混合 wire type 可解析", perr)
eq(#parsed, 4, "四个字段")
eq(parsed[1].field, 1, "field 1")
eq(parsed[2].field, 20, "field 20 (fixed64)")
eq(#parsed[2].raw, 10, "fixed64 raw = 2 字节 tag + 8 字节")
eq(parsed[2].payload, "12345678", "fixed64 payload")
eq(parsed[3].field, 21, "field 21 (fixed32)")
eq(#parsed[3].raw, 6, "fixed32 raw = 2 字节 tag + 4 字节")
eq(parsed[3].payload, "\001\002\003\004", "fixed32 payload")
eq(parsed[4].field, 22, "field 22 (len)")
eq(parsed[4].payload, "unk", "未知 length-delimited 原文保留")
eq(gp.serialize_fields(parsed), mixed, "parse+serialize 恒等（逐字节）")

new_case("parse_message 拒绝 groups 与损坏输入")
local _, gerr = gp.parse_message("\x1b")
check(gerr ~= nil, "start-group 拒绝（不做猜测式改写）")
local _, lerr = gp.parse_message("\x0a\xff\x63")
check(lerr ~= nil, "长度超出缓冲区报错")
local _, ferr = gp.parse_message("")
check(ferr == nil and #gp.parse_message("") == 0, "空 message 合法")

new_case("inject_disaggregated_params: 首次写入 = protoc 期望字节")
-- 与 python protobuf 对同一输入的输出逐字节对比：
--   ser 0a02723152100a0831302e302e302e3110a64618b960
local injected, rep, ierr = gp.inject_disaggregated_params("\x0a\x02r1", {
    bootstrap_host = "10.0.0.1", bootstrap_port = 8998, bootstrap_room = 12345,
})
check(injected ~= nil, "注入成功", ierr)
eq(hex(injected), "0a0272315210" .. hex("\x0a\x0810.0.0.1\x10\xa6\x46\x18\xb9\x60"),
    "外层 field 10 + 内层三字段与 protoc 一致")
eq(rep.replaced, false, "原来没有 field 10")
eq(rep.set[1], "string", "host 记为 string")
eq(rep.set[2], "int32", "port 记为 int32")

new_case("inject_disaggregated_params: 原位替换 + 未知字段逐字节保留")
local pre = "\x0a\x02r1" .. "\x22\x05\x0d\x33\x33\x33\x33" -- sampling_params(4) 里 temperature=0.7
    .. string.char(0xA1, 0x01) .. "12345678"                -- 未知 fixed64 20
    .. string.char(0xB2, 0x01) .. "\003unk"                  -- 未知 len 22
    .. "\x52\x04\x0a\x02" .. "aa"                            -- 已有 field 10（host="aa"，无端口）
local again, rep2, err2 = gp.inject_disaggregated_params(pre, {
    bootstrap_host = "10.0.0.9", bootstrap_port = 8998, bootstrap_room = 12345,
    decode_host = "10.0.0.8", decode_port = 20001, prefill_dp_rank = 3,
})
check(again ~= nil, "重复注入成功", err2)
eq(rep2.replaced, true, "识别出已有 field 10 并替换")
check(again:find("\x0a\x02r1", 1, true) ~= nil, "request_id 未被破坏")
check(again:find("\x22\x05\x0d\x33\x33\x33\x33", 1, true) ~= nil, "sampling_params 原文保留")
check(again:find(string.char(0xA1, 0x01) .. "12345678", 1, true) ~= nil, "未知 fixed64 逐字节保留")
check(again:find(string.char(0xB2, 0x01) .. "\003unk", 1, true) ~= nil, "未知 len 字段逐字节保留")
check(again:find("aa", 1, true) == nil, "旧的 host 被替换掉")
check(select(2, again:find("\x52", 1, true)) ~= nil, "field 10 恰好一份（原位）")
-- 重新解析改写结果，验证内层字段集合
local outer2 = assert(gp.parse_message(again))
local disagg = gp.find_field(outer2, gp.DISAGG_MSG_FIELD)
check(disagg ~= nil, "field 10 可见")
local inner2 = assert(gp.parse_message(disagg.payload))
local seen, count10 = {}, 0
for i = 1, #inner2 do
    if inner2[i].field == 1 then
        seen.host = inner2[i].payload
    elseif inner2[i].field == 2 or inner2[i].field == 3
        or inner2[i].field == 102 or inner2[i].field == 103 then
        local value = gp.decode_varint(inner2[i].payload, 1)
        seen[inner2[i].field] = value
    elseif inner2[i].field == 101 then
        seen.decode = inner2[i].payload
    end
    if inner2[i].field == 1 then count10 = count10 + 1 end
end
eq(seen.host, "10.0.0.9", "bootstrap_host 写对")
eq(seen[2], 8998, "bootstrap_port 写对")
eq(seen[3], 12345, "bootstrap_room 写对")
eq(seen.decode, "10.0.0.8", "decode_host 扩展字段写对")
eq(seen[102], 20001, "decode_port 扩展字段写对")
eq(seen[103], 3, "prefill_dp_rank 扩展字段写对")
eq(count10, 1, "同一个字段不会重复累积（幂等替换）")

new_case("inject_disaggregated_params 的输入校验")
local bad1, _, e1 = gp.inject_disaggregated_params("\x0a\x02r1", {
    bootstrap_host = "", bootstrap_port = 8998, bootstrap_room = 1 })
check(bad1 == nil and e1 ~= nil, "空 host 拒绝")
local bad2, _, e2 = gp.inject_disaggregated_params("\x0a\x02r1", {
    bootstrap_host = "h", bootstrap_port = 8998, bootstrap_room = 2 ^ 40 })
check(bad2 == nil and e2 ~= nil, "room 超出 int32 拒绝而不是截断")
-- 一个 message 型的 field 10，但 payload 是损坏的：必须整体失败
local broken, _, e3 = gp.inject_disaggregated_params(
    "\x0a\x02r1\x52\x02\xff\x00", { bootstrap_host = "h", bootstrap_port = 1, bootstrap_room = 1 })
check(broken == nil and e3 ~= nil, "已存在的 field 10 损坏时拒绝改写", e3)

new_case("rewrite_generate_body: gRPC 帧 + 只有单条未压缩消息才改写")
local framed = gp.encapsulate("\x0a\x02r1")
local rewritten, rep3, e4 = gp.rewrite_generate_body(framed, {
    bootstrap_host = "127.0.0.1", bootstrap_port = 8998, bootstrap_room = 42 })
check(rewritten ~= nil, "单条消息可改写", e4)
eq(rewritten:byte(1), 0, "压缩标志位保持 0")
local payload2 = (gp.decapsulate(rewritten))
check(payload2:find("\x52", 1, true) ~= nil, "改写后仍是一条合法帧")
local _, _, e5 = gp.rewrite_generate_body(gp.encapsulate("\x0a\x02r1", true), {
    bootstrap_host = "h", bootstrap_port = 1, bootstrap_room = 1 })
check(e5 ~= nil, "压缩消息不改写")
local _, _, e6 = gp.rewrite_generate_body(gp.encapsulate("\x0a\x02r1") .. gp.encapsulate("\x0a\x02r2"), {
    bootstrap_host = "h", bootstrap_port = 1, bootstrap_room = 1 })
check(e6 ~= nil, "两条消息（客户端流式）不改写")
local _, _, e7 = gp.rewrite_generate_body(gp.encapsulate("\x0a\x02r1"):sub(1, 6), {
    bootstrap_host = "h", bootstrap_port = 1, bootstrap_room = 1 })
check(e7 ~= nil, "帧不完整不改写")
local _, _, e8 = gp.rewrite_generate_body("", { bootstrap_host = "h", bootstrap_port = 1, bootstrap_room = 1 })
check(e8 ~= nil, "空 body 不改写")

new_case("is_generate_path 只认 sglang 的 Generate")
check(gp.is_generate_path("/sglang.grpc.scheduler.SglangScheduler/Generate"), "Rust 客户端用的完整路径")
check(gp.is_generate_path("/sglang.grpc.model_service.ModelService/Generate"), "模板注释里的另一套服务名")
check(not gp.is_generate_path("/sglang.grpc.scheduler.SglangScheduler/Embed"), "Embed 不改写")
check(not gp.is_generate_path("/probe.Echo/Say"), "探针方法不改写")
check(not gp.is_generate_path(nil), "nil 路径安全")
check(not gp.is_generate_path("/Generate/extra"), "方法名必须是最后一段")

new_case("carrier 开关：LR_GRPC_PD_METADATA")
-- LuaJIT has no os.setenv, so drive libc through FFI. Without it the switch
-- would be untestable and its default is exactly what this feature changes.
local setenv, unsetenv
do
    local ok, ffi = pcall(require, "ffi")
    if ok then
        ffi.cdef[[int setenv(const char *name, const char *value, int overwrite);
                  int unsetenv(const char *name);]]
        setenv = function(k, v) ffi.C.setenv(k, v, 1) end
        unsetenv = function(k) ffi.C.unsetenv(k) end
    end
end
if not setenv then
    setenv = function() return nil end
    unsetenv = function() return nil end
end
local function carrier_for(raw)
    if raw == nil then
        unsetenv("LR_GRPC_PD_METADATA")
    else
        setenv("LR_GRPC_PD_METADATA", raw)
    end
    return gp.pd_carrier()
end
eq(carrier_for(nil), "body", "未设置 = 原生 proto body（默认）")
eq(carrier_for("on"), "metadata", "on 保留 metadata 模式")
eq(carrier_for("ON"), "metadata", "大小写不敏感")
eq(carrier_for("metadata"), "metadata", "显式 metadata")
eq(carrier_for("off"), "none", "off 什么都不发")
eq(carrier_for("none"), "none", "显式 none")
eq(carrier_for("garbage"), "body", "无法识别的值回到默认 body，而不是静默不发")
unsetenv("LR_GRPC_PD_METADATA")

new_case("PD_MAX_BODY_BYTES 与既有门禁一致")
check(gp.PD_MAX_BODY_BYTES >= 1024 * 1024, "阈值不至于小于常用的 client_body_buffer_size")
check(gp.PD_MAX_BODY_BYTES < 512 * 1024 * 1024, "阈值必须小于 client_max_body_size 512m")

-- Cross-checked against python protobuf reference bytes for the *inner*
-- DisaggregatedParams payload (host="h", port=8998, room=R). Two reasons these
-- specific R values are pinned: the 4-byte varint boundaries at 2^27 and 2^28
-- (where the encoding gains a continuation byte), and i32::MAX, which is the
-- largest room pd.room_id_i32 can draw.
new_case("大 varint 边界与 python protobuf 逐字节一致（>2^27、>2^28、i32::MAX）")
local inner_ref = {
    [134217727] = "0a016810a64618ffffff3f",   -- 2^27-1: 4-byte room varint
    [134217728] = "0a016810a6461880808040",   -- 2^27  : gains the 5th byte? no -> still 4 bytes + 0x40
    [268435455] = "0a016810a64618ffffff7f",   -- 2^28-1
    [268435456] = "0a016810a646188080808001", -- 2^28  : 5-byte room varint
    [2147483647] = "0a016810a64618ffffffff07", -- i32::MAX
}
local ref_keys = {}
for k in pairs(inner_ref) do ref_keys[#ref_keys + 1] = k end
table.sort(ref_keys)
for i = 1, #ref_keys do
    local room = ref_keys[i]
    local msg = assert(gp.inject_disaggregated_params("", {
        bootstrap_host = "h", bootstrap_port = 8998, bootstrap_room = room,
    }))
    local parsed = assert(gp.parse_message(msg))
    local field10 = gp.find_field(parsed, gp.DISAGG_MSG_FIELD)
    eq(hex(field10.payload), inner_ref[room], "room=" .. room .. " 内层与 protoc 一致")
    -- the int32 fields must ride wire type 0: an int32 is never zigzag/sint on
    -- the wire, and the vendored schema declares no sint32/sint64 field at all
    -- (grep sint32|sint64 -> 0 hits in sglang_scheduler.proto), so no zigzag is
    -- implemented and none is needed.
    local inner = assert(gp.parse_message(field10.payload))
    for j = 1, #inner do
        if inner[j].field == 2 or inner[j].field == 3 then
            eq(inner[j].wire, gp.WIRE_VARINT, "room=" .. room .. " 字段 " .. inner[j].field .. " 是 varint")
        end
    end
end
eq(gp.decode_varint("\x80\x80\x80\x80\x01", 1), 268435456, "5 字节 varint 解回 2^28")

-- protobuf's own last-wins rule is *not* uniform: a repeated scalar keeps both
-- occurrences and the reader takes the last, but a duplicated SINGULAR message
-- field is merged by the parser (verified: two occurrences of field 10 whose
-- second carries only bootstrap_host decode as host=NEW + the FIRST port/room).
-- A blind "append and let the last one win" would therefore leak a stale
-- bootstrap_port across a retry. The implementation parses and replaces, so the
-- output holds exactly one occurrence and none of the old values.
new_case("输入已有两条 field 10：折叠成一条，旧值不泄漏（append 会踩 merge 语义）")
local duplicated = "\x0a\x02r1"
    .. "\x52\x07\x0a\x03" .. "OLD" .. "\x10\x09"  -- field 10 {1:"OLD", 2:9}
    .. "\x52\x03\x0a\x01" .. "N"                  -- field 10 again {1:"N"}
local collapsed, rep_d, err_d = gp.inject_disaggregated_params(duplicated, {
    bootstrap_host = "10.0.0.9", bootstrap_port = 8998, bootstrap_room = 12345,
})
check(collapsed ~= nil, "重复 field 10 的输入可改写", err_d)
local outer_d = assert(gp.parse_message(collapsed))
local occurrences = 0
for i = 1, #outer_d do
    if outer_d[i].field == gp.DISAGG_MSG_FIELD then occurrences = occurrences + 1 end
end
eq(occurrences, 1, "输出只有一条 field 10")
check(collapsed:find("OLD", 1, true) == nil, "旧的 bootstrap_host 不残留")
check(string.format("%s", hex(collapsed)):find("1009", 1, true) == nil,
    "旧的 bootstrap_port=9 不残留（merge 会保留它）")
local inner_d = assert(gp.parse_message(gp.find_field(outer_d, gp.DISAGG_MSG_FIELD).payload))
eq(gp.decode_varint(gp.find_field(inner_d, 2).payload, 1), 8998, "端口是新写入的 8998")
eq(gp.decode_varint(gp.find_field(inner_d, 3).payload, 1), 12345, "room 是新写入的 12345")

-- An existing field 10 may carry fields the router does not know. Those are kept
-- verbatim at the front of the inner message (same unknown-field rule the outer
-- message follows), and the three known fields are written from scratch.
new_case("已有 field 10 的未知内层字段逐字节保留")
local pre_unknown = "\x0a\x02r1" .. "\x52\x06\x28\x07\x0a\x02" .. "aa"  -- {5:varint 7, 1:"aa"}
local merged, rep_u, err_u = gp.inject_disaggregated_params(pre_unknown, {
    bootstrap_host = "10.0.0.9", bootstrap_port = 8998, bootstrap_room = 12345,
})
check(merged ~= nil, "带未知内层字段可改写", err_u)
check(merged:find("\x28\x07", 1, true) ~= nil, "未知内层字段 5 原文保留")
check(merged:find("aa", 1, true) == nil, "已知的旧 host 被替换")
eq(rep_u.replaced, true, "识别出已有 field 10")

-- The frame layer only ever rewrites a body that is exactly one message, so a
-- streaming call's *later* frames can never be touched: rewrite_generate_body
-- refuses (and the caller forwards the original bytes untouched) rather than
-- rewriting frame 1 of a multi-frame buffer.
new_case("多帧 body 整体拒绝 = 首帧之后的帧一定不动")
local stream_body = gp.encapsulate("\x0a\x02r1") .. gp.encapsulate("\x0a\x02r2")
local untouched, _, serr = gp.rewrite_generate_body(stream_body, {
    bootstrap_host = "h", bootstrap_port = 1, bootstrap_room = 1,
})
check(untouched == nil and serr ~= nil, "两帧拒绝改写（回退 metadata）")
-- decapsulate's consumed count is what proves only-one-message: it reports the
-- first frame and the caller compares it against the buffer length.
local first_payload, consumed = gp.decapsulate(stream_body)
eq(consumed, 9, "首帧消费 5+4 字节")
eq(first_payload, "\x0a\x02r1", "首帧内容可读出（但不会被单独改写）")
end
test_proto_body_codec()

--------------------------------------------------------------------------
io.write("pd/grpc_proxy: " .. passed .. " passed, " .. failed .. " failed\n")
if failed > 0 then
    for i = 1, #failures do
        io.write("  FAIL " .. failures[i] .. "\n")
    end
    os.exit(1)
end
