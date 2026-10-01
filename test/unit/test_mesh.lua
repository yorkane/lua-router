#!/usr/bin/env luajit
-- mesh.lua 单测：成员收敛、LWW、分区状态、限流窗口合并。
--
-- 分两层跑：
--   * 纯 Lua 层（默认）：不注入 ngx，cosocket 路径用注入的假 http 覆盖；
--   * handler 层：mesh.dispatch 返回 {status=,body=}，不依赖 nginx。
-- 运行（两种都可以）：
--   docker run --rm -v "$PWD:/repo:ro" authz:latest \
--     /usr/local/openresty/luajit/bin/luajit \
--     -e 'package.cpath="/usr/local/openresty/lualib/?.so;"..package.cpath
--         package.path="/repo/lualib/?.lua;"..package.path
--         dofile("/repo/test/unit/test_mesh.lua")'
--   docker run --rm -v "$PWD:/repo:ro" -w /repo \
--     --entrypoint /usr/bin/resty apache/apisix:3.11.0-debian \
--     -e 'package.path="/repo/lualib/?.lua;"..package.path
--         dofile("/repo/test/unit/test_mesh.lua")'
--
-- resty 会提供真的 ngx，那样 handler_response 走 ngx.print 把正文写进标准输出，
-- 断言就拿不到 {status=,body=}。所以这里在 require mesh 之前把 ngx 摘掉：mesh
-- 在加载时记录「没有 ngx」，所有 handler 走返回 {status=,body=} 的分支，同一段逻辑两种
-- 环境都能断言。真实的 ngx 写响应路径由 nginx 里的 e2e 手工验证（见 gap-mesh.md §8）。
_G.ngx = nil

package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath
package.path = (os.getenv("LUA_TEST_LIB") or "./lualib") .. "/?.lua;" .. package.path

local mesh = require "resty.luarouter.mesh"

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
-- 可控时钟 + 假 cosocket
--------------------------------------------------------------------------
local function clock(start)
    local t = start or 1000
    return {
        now = function() return t end,
        advance = function(_, seconds) t = t + seconds end,
    }
end

---在若干 mesh 实例之间搭一张可编程的网络：drop[base]=true 让该地址全部失败。
local function fabric(nodes)
    local net = { drop = {}, calls = {}, reachable = true }
    local by_addr = {}
    for i = 1, #nodes do
        by_addr[nodes[i].self_addr] = nodes[i]
    end
    function net.http(method, url, body, content_type, timeout_ms)
        net.calls[#net.calls + 1] = { method = method, url = url }
        local base = string.match(url, "^(.-)/_mesh/") or url
        if net.drop[base] then
            return nil, nil, "connect failed: connection refused"
        end
        local node = by_addr[base]
        if not node then
            return nil, nil, "no such host: " .. tostring(base)
        end
        local snap = mesh.decode(body or "")
        if not snap then
            return 400, '{"error":"bad mesh envelope"}'
        end
        node:apply_snapshot(snap)
        local reply = mesh.encode(node:snapshot())
        return 200, reply
    end
    net.sync_all = function(_, rounds)
        for _ = 1, (rounds or 1) do
            for i = 1, #nodes do
                nodes[i]:sync_tick()
            end
        end
    end
    return net
end

---构造一个 mesh 节点。name 同时作为 hostport 身份，避免身份迁移干扰断言。
local function node(name, addr, peers, opts)
    local cfg = {
        self_name = name, self_addr = addr, peers = peers,
        now = (opts and opts.now) or (clock().now),
        http = (opts and opts.http),
    }
    for k, v in pairs(opts or {}) do
        cfg[k] = v
    end
    return mesh.new(cfg)
end

--------------------------------------------------------------------------
new_case("base64 / hex 往返：纯 Lua 实现必须自洽")
do
    local samples = { "", "a", "ab", "abc", "abcd", "hello world",
        string.rep("0123456789", 20), "中文", "\0\1\254\255" }
    for i = 1, #samples do
        local text = samples[i]
        local encoded = mesh.b64_encode(text)
        local decoded = mesh.b64_decode(encoded)
        check(decoded == text, "b64 roundtrip len=" .. #text,
            decoded ~= text and (tostring(encoded) .. " -> " .. tostring(decoded)) or nil)
    end
    eq(mesh.b64_encode("abc"), "YWJj", "b64 vector abc")
    eq(mesh.b64_encode("a"), "YQ==", "b64 vector a")
    eq(mesh.b64_encode("ab"), "YWI=", "b64 vector ab")
    eq(mesh.b64_encode("abcd"), "YWJjZA==", "b64 vector abcd")
    eq(mesh.b64_decode("YWJ=") , "ab", "b64 decode pad1")
    eq(mesh.b64_decode("YQ=="), "a", "b64 decode pad2")
    check(mesh.b64_decode("a") == nil, "b64 length not multiple of 4 rejected")
    check(mesh.b64_decode("ab=c") == nil, "b64 bad char rejected")
    eq(mesh.hex_encode("hello"), "68656c6c6f", "hex encode matches Rust fmt")
    eq(mesh.hex_decode("68656c6c6f"), "hello", "hex decode")
    eq(mesh.hex_decode("abc"), nil, "hex odd length rejected")
    eq(select(2, mesh.hex_decode("zz")), "Invalid hex encoding", "hex bad byte message")
end

--------------------------------------------------------------------------
new_case("peer 解析与身份命名")
do
    local peers = mesh.parse_peers("http://a:30000, http://b:30000,,http://a:30000/")
    eq(#peers, 2, "dedup + trim + drop empty")
    eq(peers[1], "http://a:30000", "trailing slash stripped")
    eq(mesh.hostport_from_url("http://10.0.0.7:30000"), "10.0.0.7:30000", "hostport from url")
    eq(mesh.hostport_from_url("http://10.0.0.7:30000/ha/status"), "10.0.0.7:30000", "hostport ignores path")
    eq(mesh.hostport_from_url("10.0.0.7:30000"), "10.0.0.7:30000", "bare hostport accepted")

    local clk = clock(1000)
    local solo = mesh.new{ self_name = "solo", self_addr = "http://127.0.0.1:30000",
                           now = clk.now }
    eq(#solo:peer_bases(), 0, "no peers -> no sync")
    eq(solo.config.quorum, 1, "single-node quorum is 1 (never self-partitioned)")
    eq(solo:partition_state(), "normal", "single node normal")
    eq(solo:should_serve(), true, "single node serves")
end

--------------------------------------------------------------------------
new_case("成员收敛：种子不全也能拼出完整视图")
do
    local clk = clock(1000)
    -- 三角集群，每个节点只写另外两个中的一个（transitive membership 的用意）。
    local a = node("a", "http://a:30000", { "http://b:30000" }, { now = clk.now })
    local b = node("b", "http://b:30000", { "http://c:30000" }, { now = clk.now })
    local c = node("c", "http://c:30000", { "http://a:30000" }, { now = clk.now })
    local net = fabric({ a, b, c })
    for _, n in ipairs({ a, b, c }) do
        n.http = net.http
    end
    eq(#a:members_snapshot(), 2, "a starts with self + one seed")

    net:sync_all(1)
    eq(#a:members_snapshot(), 3, "a learned c after one round")
    eq(#b:members_snapshot(), 3, "b full after one round")
    eq(#c:members_snapshot(), 3, "c full after one round")

    net:sync_all(2)
    local names = {}
    for _, n in ipairs({ a, b, c }) do
        local entry = n.store.members
        local seen = {}
        for name, rec in pairs(entry) do
            seen[name] = rec.value.status
        end
        names[n.self_name] = seen
        check(seen.a and seen.b and seen.c, "member table complete on " .. n.self_name)
    end
    eq(names.a.b, "alive", "a sees b alive (sync succeeded)")
    eq(names.a.a, "alive", "self always alive")

    -- 状态视图在轮次间保持一致（不允许 a 认为 b alive 而 c 认为 b down）。
    local agree = true
    for name in pairs(names.a) do
        if names.b[name] ~= names.a[name] or names.c[name] ~= names.a[name] then
            agree = false
        end
    end
    check(agree, "all three nodes agree on member status",
        string.format("a=%s b=%s c=%s", tostring(names.a.b), tostring(names.b.b), tostring(names.c.b)))

    -- peer_bases 覆盖成员表里的地址：收敛后 a 也要去同步 c。
    eq(#a:peer_bases(), 2, "a now syncs two peers")
    local found
    for i = 1, #a:peer_bases() do
        if a:peer_bases()[i] == "http://c:30000" then found = true end
    end
    check(found, "learned peer is syncable")
end

--------------------------------------------------------------------------
new_case("身份统一：种子按 hostport 记账，自报名不同也不能长出两个键")
do
    local clk = clock(1000)
    -- a 用 IP 记账 b，但 b 自报名是 host:port 之外的别名（SMG_MESH_SELF_NAME）。
    local a = node("a", "http://10.0.0.1:30000", { "http://10.0.0.2:30000" }, { now = clk.now })
    local b = node("router-b", "http://10.0.0.2:30000", { "http://10.0.0.1:30000" }, { now = clk.now })
    local net = fabric({ a, b })
    a.http = net.http
    b.http = net.http
    eq(a.store.members["10.0.0.2:30000"] ~= nil, true, "seed keyed by hostport")
    net:sync_all(1)
    eq(a.store.members["router-b"] ~= nil, true, "self-declared name adopted")
    eq(a.store.members["10.0.0.2:30000"], nil, "phantom key migrated away")
    eq(a.last_sync_ms["router-b"] ~= nil, true, "sync bookkeeping migrated")
    eq(#a:members_snapshot(), 2, "no duplicate identity in member table")
    eq(b.store.members["a"] ~= nil, true, "b adopts a's self-declared name")
end

--------------------------------------------------------------------------
-- 幻影键回归（2026-09-30）：拨号地址与对端自报地址写法不同（容器里最常见的
-- 形态：SMG_MESH_SELF 写 loopback、SMG_MESH_PEERS 写另一张网卡）时，成员表
-- 不能长出第二个键。fabric 按 hostport 路由，loopback 不给远端登记 —— 对端
-- 自报的 loopback 从我们这里拨过去就是「拨不通的写法」，用来验证 used_addr。
local function hostport_fabric(specs)
    local net = { drop = {}, calls = 0, by_hp = {} }
    for i = 1, #specs do
        local s = specs[i]
        for _, addr in ipairs(s.listen) do
            net.by_hp[mesh.hostport_from_url(addr)] = s.node
        end
    end
    function net.http(method, url, body)
        net.calls = net.calls + 1
        local base = string.match(url, "^(.-)/_mesh/") or url
        if net.drop[base] then
            return nil, nil, "connect failed: connection refused"
        end
        local target = net.by_hp[mesh.hostport_from_url(base)]
        if not target then
            return nil, nil, "no such host: " .. tostring(base)
        end
        target:apply_snapshot(mesh.decode(body or ""))
        return 200, mesh.encode(target:snapshot())
    end
    net.tick = function()
        for i = 1, #specs do
            specs[i].node:sync_tick()
        end
    end
    return net
end

local function member_keys(m)
    local out = {}
    for k in pairs(m.store.members) do out[#out + 1] = k end
    table.sort(out)
    return table.concat(out, ",")
end

new_case("幻影键回归：loopback SELF + 网卡 IP 种子，一轮并键且不再复发")
do
    local clk = clock(1000)
    local a = mesh.new{ self_name = "lr-a", self_addr = "http://127.0.0.1:18301",
        peers = { "http://10.0.0.2:18302" }, interval_s = 1, now = clk.now }
    local b = mesh.new{ self_name = "lr-b", self_addr = "http://127.0.0.1:18302",
        peers = { "http://10.0.0.1:18301" }, interval_s = 1, now = clk.now }
    local net = hostport_fabric({
        { node = a, listen = { "http://10.0.0.1:18301" } },
        { node = b, listen = { "http://10.0.0.2:18302" } },
    })
    a.http, b.http = net.http, net.http
    eq(member_keys(a), "10.0.0.2:18302,lr-a", "boot: self + seed keyed by hostport")

    net:tick()
    eq(member_keys(a), "lr-a,lr-b", "seed key migrated into the self-declared name")
    eq(member_keys(b), "lr-a,lr-b", "same unification on the other side")
    eq(tonumber(a:ha_status().body:match('"node_count":(%d+)')), 2,
        "node_count 2 (was 3 with the lingering :init key)")
    eq(a.used_addr["lr-b"], "http://10.0.0.2:18302",
        "the spelling that connected is remembered")
    eq(a.store.members["lr-b"].value.address, "http://127.0.0.1:18302",
        "member record keeps the declared (loopback) spelling")
    eq(#a:peer_bases(), 1, "one sync target per node, not one per spelling")
    eq(a:peer_bases()[1], "http://10.0.0.2:18302",
        "verified address preferred over the unreachable declared one")

    local before = net.calls
    for _ = 1, 5 do
        clk:advance(2)
        net:tick()
    end
    eq(member_keys(a), "lr-a,lr-b", "no phantom resurrection over 5 more ticks")
    eq(net.calls - before, 10, "exactly one request per peer per tick")
    eq(a.store.members["lr-b"].value.status, "alive", "peer stays alive across ticks")
    eq(a.last_sync_ms["lr-b"] ~= nil, true,
        "sync bookkeeping followed the migrated key")
    eq(a:ha_health().body:find('"status":"healthy"') ~= nil, true,
        "health stays healthy without a ghost waiting to time out")
end

new_case("第三方转发的「本实例记录」不得给自己长出第二个键")
do
    local clk = clock(1000)
    local relay = mesh.new{ self_name = "relay", self_addr = "http://10.0.0.9:30000",
        now = clk.now }
    -- relay 用 hostport 记过我们：名字是地址写法，地址就是我们的监听地址。
    relay:put_member({ name = "10.0.0.1:30000", address = "http://10.0.0.1:30000",
        status = "alive", version = 3 }, "10.0.0.1:30000")
    local alpha = mesh.new{ self_name = "alpha", self_addr = "http://10.0.0.1:30000",
        peers = { "http://10.0.0.9:30000" }, now = clk.now }
    local applied = alpha:apply_snapshot(relay:snapshot())
    eq(alpha.store.members["10.0.0.1:30000"], nil,
        "record carrying our own address is not adopted under a foreign key")
    eq(member_keys(alpha), "alpha,relay",
        "only relay's self-declared name entered; its seed form was absorbed")
    eq(alpha.store.members["alpha"].value.status, "alive", "self record untouched")
    eq(applied >= 1, true, "relay's own declaration still applies")
end

new_case("地址写法规范：IPv6 补全 / 大小写 / 前导零落到同一个 hostport")
do
    eq(mesh.hostport_from_url("http://[::1]:30000"),
        "0000:0000:0000:0000:0000:0000:0000:0001:30000", "IPv6 loopback expanded")
    eq(mesh.hostport_from_url("http://[0:0:0:0:0:0:0:1]:30000"),
        mesh.hostport_from_url("http://[::1]:30000"), "abbrev equals full form")
    eq(mesh.hostport_from_url("http://[FE80::1]:80"),
        mesh.hostport_from_url("http://[fe80:0:0:0:0:0:0:1]:80"), "case + zeros unify")
    eq(mesh.hostport_from_url("http://Router-A:30000"), "router-a:30000",
        "host name lowercased")
    eq(mesh.hostport_from_url("http://10.0.0.7:030000"), "10.0.0.7:30000",
        "leading-zero port normalized")
    eq(mesh.hostport_from_url("http://10.0.0.7:30000/"), "10.0.0.7:30000",
        "trailing slash stripped")
    eq(mesh.hostport_from_url("not a url at all"), "not a url at all",
        "unparseable falls back to lowercase passthrough")

    -- 规范相等之后，种子写缩写、对端自报写全量也必须并到同一个键。
    local clk = clock(1000)
    local v6a = mesh.new{ self_name = "v6-a", self_addr = "http://[::1]:18601",
        peers = { "http://[fd00::10]:18602" }, now = clk.now }
    local v6b = mesh.new{ self_name = "v6-b",
        self_addr = "http://[fd00:0000:0000:0000:0000:0000:0000:0010]:18602",
        peers = { "http://[FD00::1]:18601" }, now = clk.now }
    local net = hostport_fabric({
        { node = v6a, listen = { "http://[fd00::1]:18601" } },
        { node = v6b, listen = { "http://[fd00:0:0:0:0:0:0:10]:18602" } },
    })
    v6a.http, v6b.http = net.http, net.http
    net:tick()
    eq(member_keys(v6a), "v6-a,v6-b", "IPv6 spelling variant converges to one key")
    eq(tonumber(v6a:ha_status().body:match('"node_count":(%d+)')), 2,
        "IPv6 pair reports node_count 2")
    eq(member_keys(v6b), "v6-a,v6-b", "uppercase seed spelling unifies too")
end

new_case("第三方转发的未知节点只补地址，不新建键")
do
    local clk = clock(1000)
    local b = mesh.new{ self_name = "b", self_addr = "http://10.0.0.2:30000",
        now = clk.now }
    -- b 里有一条「转发的」c 记录：写作者是 a，不是 c 自己。
    b:put_member({ name = "c", address = "http://10.0.0.3:30000",
        status = "alive", version = 2 }, "a")
    local a = mesh.new{ self_name = "a", self_addr = "http://10.0.0.1:30000",
        peers = { "http://10.0.0.2:30000" }, now = clk.now }
    a:apply_snapshot(b:snapshot())
    eq(a.store.members["c"], nil, "forwarded third-party record does not mint a key")
    eq(member_keys(a), "a,b", "self-declared name adopted, seed key migrated away")
    eq(a.store.members["a"].value.address, "http://10.0.0.1:30000",
        "self record untouched")
end

--------------------------------------------------------------------------
new_case("LWW：ts -> version -> node id 三级决胜")
do
    local clk = clock(1000)
    local store = {}
    -- 时间优先
    mesh.put(store, "k", { v = 1 }, "node-a", 100, 1)
    eq(mesh.put(store, "k", { v = 0 }, "node-b", 90, 99), false, "older ts loses")
    eq(store.k.value.v, 1, "loser did not overwrite")
    -- 同 ts 比 version
    eq(mesh.put(store, "k", { v = 2 }, "node-b", 100, 2), true, "same ts higher version wins")
    eq(store.k.value.v, 2, "higher version applied")
    -- 同 ts 同 version 比 node id（字典序大的胜出，所有节点算出同一结果）
    eq(mesh.put(store, "k", { v = 3 }, "node-a", 100, 2), false, "same ts+version lower node loses")
    eq(store.k.value.v, 2, "lower node id did not overwrite")
    eq(mesh.put(store, "k", { v = 4 }, "node-c", 100, 2), true, "same ts+version higher node wins")
    eq(store.k.value.v, 4, "node id tiebreak applied")

    -- 双向对称：两个节点互相合并后收敛到同一个值，与合并顺序无关。
    local a = node("a", "http://a:30000", { "http://b:30000" }, { now = clk.now })
    local b = node("b", "http://b:30000", { "http://a:30000" }, { now = clk.now })
    a:put_app("k", "from-a")
    clk:advance(1)
    b:put_app("k", "from-b")
    local sa, sb = a:snapshot(), b:snapshot()
    a:apply_snapshot(sb)
    b:apply_snapshot(sa)
    eq(a:get_app("k").value, b:get_app("k").value, "concurrent app writes converge")

    -- 反向顺序也要得到同一个值（幂等 + 交换律）。
    local a2 = node("a", "http://a:30000", { "http://b:30000" }, { now = clock(1000).now })
    local b2 = node("b", "http://b:30000", { "http://a:30000" }, { now = clock(1001).now })
    a2:put_app("k", "from-a")
    b2:put_app("k", "from-b")
    b2:apply_snapshot(a2:snapshot())
    a2:apply_snapshot(b2:snapshot())
    eq(a2:get_app("k").value, b2:get_app("k").value, "convergence independent of merge order")
    eq(a2:get_app("k").value, a:get_app("k").value, "same winner regardless of order")
end

--------------------------------------------------------------------------
new_case("tombstone：删除不会被旧快照复活")
do
    local clk = clock(1000)
    local a = node("a", "http://a:30000", { "http://b:30000" }, { now = clk.now })
    local b = node("b", "http://b:30000", { "http://a:30000" }, { now = clk.now })
    a:observe_worker("w1", { model_id = "m", url = "http://u1" }, { healthy = true, load = 1 })
    clk:advance(1)
    a:apply_snapshot(b:snapshot())          -- b 空，什么都不会写
    eq(a.store.workers.w1.value.worker_id, "w1", "worker present before removal")
    local stale = a:snapshot()              -- b 拿到含 w1 的旧快照
    clk:advance(1)
    a:remove_worker("w1")
    eq(mesh.count_live(a.store.workers), 0, "removed worker not counted")
    clk:advance(1)
    a:apply_snapshot(mesh.decode(mesh.encode(stale)))
    eq(mesh.count_live(a.store.workers), 0, "stale snapshot did not resurrect the worker")
end

--------------------------------------------------------------------------
new_case("状态复制：worker / policy / manual 三类都过网")
do
    local clk = clock(1000)
    local a = node("a", "http://a:30000", { "http://b:30000" }, { now = clk.now })
    local b = node("b", "http://b:30000", { "http://a:30000" }, { now = clk.now })
    a:observe_worker("w1", { model_id = "deepseek", url = "http://10.0.0.9:30000" },
        { healthy = true, load = 7 })
    a:observe_policy("deepseek", "cache_aware", { cache_threshold = 0.3 })
    a:observe_manual("session-42", { "http://10.0.0.9:30000" })
    clk:advance(1)
    b:apply_snapshot(a:snapshot())
    local entry = b.store.workers.w1
    check(entry ~= nil, "worker replicated to b")
    eq(entry.value.url, "http://10.0.0.9:30000", "worker url")
    eq(entry.value.health, true, "worker health")
    eq(entry.value.load, 7, "worker load")
    eq(entry.version, 1, "worker version carried as LWW metadata")
    eq(entry.node, "a", "origin node recorded for /ha/workers")
    eq(b:ha_worker(nil, "w1").status, 200, "ha_worker finds replica")
    local pol = b.store.policies["policy:deepseek"]
    eq(pol.value.policy_type, "cache_aware", "policy type replicated")
    eq(pol.value.config.cache_threshold, 0.3, "policy config replicated")
    local man = b.store.manual["manual:session-42"]
    eq(man.value.urls[1], "http://10.0.0.9:30000", "manual stickiness replicated")
    eq(mesh.count_live(b.store.workers), 1, "worker_count via /ha/status")

    -- 空列表写入等于删除（Rust 的 vacant 状态不占位）
    clk:advance(1)
    b:observe_manual("session-42", {})
    eq(mesh.count_live(b.store.manual), 0, "manual delete counted as tombstone")
    -- 对 b 的删除做双向收敛：a 的旧值不能复活
    clk:advance(1)
    a:apply_snapshot(b:snapshot())
    eq(mesh.count_live(a.store.manual), 0, "manual tombstone propagated")
end

--------------------------------------------------------------------------
new_case("cache_aware 树快照：opaque blob + 版本向量")
do
    local clk = clock(1000)
    local a = node("a", "http://a:30000", { "http://b:30000" },
        { now = clk.now, snapshot_max_bytes = 32 })
    local b = node("b", "http://b:30000", { "http://a:30000" }, { now = clk.now })
    check(a:observe_tree("m1", "TREE-BLOB-v1"), "tree snapshot accepted")
    check(not a:observe_tree("m2", string.rep("x", 64)), "oversized blob skipped")
    eq(a.stats.tree_skipped, 1, "skip counted for observability")
    clk:advance(1)
    b:apply_snapshot(a:snapshot())
    eq(b.store.trees["tree:m1"].value.blob, "TREE-BLOB-v1", "blob replicated verbatim")
    eq(b.store.trees["tree:m1"].value.format, "cache_aware-snapshot-v1", "blob format tagged")

    -- 因果：b 拿到快照后又写了更新的 blob，a 的旧快照不得回滚 b。
    local seen = b:snapshot()
    clk:advance(1)
    b:observe_tree("m1", "TREE-BLOB-v2")
    b:apply_snapshot(seen)
    eq(b.store.trees["tree:m1"].value.blob, "TREE-BLOB-v2", "causally older blob ignored")

    -- 并发：两边各自写不同 blob，向量无法比较 -> 退回 LWW，两边同一胜者。
    local c = node("c", "http://c:30000", {}, { now = clock(2000).now })
    local d = node("d", "http://d:30000", {}, { now = clock(2000).now })
    c:observe_tree("m1", "from-c")
    d:observe_tree("m1", "from-d")
    local sc, sd = c:snapshot(), d:snapshot()
    c:apply_snapshot(sd)
    d:apply_snapshot(sc)
    eq(c.store.trees["tree:m1"].value.blob, d.store.trees["tree:m1"].value.blob,
        "concurrent tree writes converge")
end

--------------------------------------------------------------------------
new_case("限流窗口：跨节点合并 + 滚窗 + 不重复计数")
do
    local clk = clock(1000)
    local a = node("a", "http://a:30000", { "http://b:30000" },
        { now = clk.now, rate_window_s = 10 })
    local b = node("b", "http://b:30000", { "http://a:30000" },
        { now = clk.now, rate_window_s = 10 })
    eq(a:rate_inc("global", 1), 1, "local inc returns window total")
    a:rate_inc("global", 4)
    eq(a:rate_value("global"), 5, "same-window accumulation")
    clk:advance(1)
    b:rate_inc("global", 7)
    -- 双向同步两次：PN counter 合并必须幂等（同一节点重复同步不重复计数）。
    b:apply_snapshot(a:snapshot())
    a:apply_snapshot(b:snapshot())
    b:apply_snapshot(a:snapshot())
    a:apply_snapshot(b:snapshot())
    eq(a:rate_value("global"), 12, "a sees merged total")
    eq(b:rate_value("global"), 12, "b sees the same total")

    -- 滚窗：跨过窗口边界后旧窗口不再计入总量（Rust 靠负增 workaround，这里换 key）。
    clk:advance(10)
    eq(a:roll_windows(), true, "window advanced")
    eq(a:rate_value("global"), 0, "counter reset with the new window")
    a:rate_inc("global", 2)
    eq(a:rate_value("global"), 2, "new window counts from zero")

    -- 同一窗口内对等端的增量照常合并。
    clk:advance(1)
    b:rate_inc("global", 3)
    a:apply_snapshot(b:snapshot())
    eq(a:rate_value("global"), 5, "peer increments land in the same window")

    -- 配置写入 + 超限判定（Rust check_global_rate_limit 的三返回值语义）
    a:set_rate_limit_config(3)
    clk:advance(60)
    a:roll_windows()
    local exceeded = false
    for _ = 1, 4 do
        exceeded = a:check_global_rate_limit()
    end
    eq(exceeded, true, "limit exceeded after 4 requests at limit 3")
    local _, count, limit = a:check_global_rate_limit()
    eq(limit, 3, "limit echoed")
    check(count >= 4, "count keeps accumulating past the limit", count)
    eq(a:reset_rate_limit_counter(), true, "reset decrements the local share")
    eq(a:rate_value("global"), 0, "reset brings the window to zero")
    eq(a:reset_rate_limit_counter(), false, "second reset is a no-op")

    -- owner 只为可观测：与 Rust 不同，非 owner 也允许 inc（差别记入文档）。
    check(type(a:rate_owner("global")) == "string", "rate_owner returns a member name")
end

--------------------------------------------------------------------------
new_case("分区检测：不可达计数 -> suspect -> down -> 无 quorum")
do
    local clk = clock(1000)
    local opts = { now = clk.now, unreachable_s = 30, min_cluster_size = 3, quorum = 2,
                   suspect_threshold = 2 }
    local a = node("a", "http://a:30000", { "http://b:30000", "http://c:30000" }, opts)
    local b = node("b", "http://b:30000", { "http://a:30000", "http://c:30000" }, opts)
    local c = node("c", "http://c:30000", { "http://a:30000", "http://b:30000" }, opts)
    local net = fabric({ a, b, c })
    for _, n in ipairs({ a, b, c }) do
        n.http = net.http
    end
    net:sync_all(1)
    eq(a:partition_state(), "normal", "healthy cluster is normal")
    eq(a:ha_health().status, 200, "health 200 while normal")
    eq(a:ha_health().body:find('"status":"healthy"', 1, true) ~= nil, true,
        "health body says healthy")

    -- c 掉线：连续两次失败才降级 suspect（一次抖动不判死）。
    net.drop["http://c:30000"] = true
    a:sync_with("http://c:30000")
    eq(a.store.members.c.value.status, "alive", "one failure does not demote")
    eq(a:partition_state(), "normal", "one failure does not change the partition state")
    a:sync_with("http://c:30000")
    eq(a.store.members.c.value.status, "suspect", "two failures mark suspect")
    eq(a:partition_state(), "normal", "suspect inside the timeout is still reachable")

    -- 推过 unreachable_timeout：suspect -> down，且被计成不可达。b 保持新鲜，
    -- 于是「3 个期望成员 / 1 个不可达」的形态是确定的。
    clk:advance(31)
    a:sync_with("http://b:30000")
    a:sync_with("http://c:30000")
    eq(a.store.members.c.value.status, "down", "timeout marks the member down")
    local state, detail = a:partition_state()
    eq(state, "partitioned_with_quorum", "2 of 3 reachable keeps quorum")
    eq(detail.unreachable, 1, "unreachable counted")
    eq(detail.alive, 2, "alive counts only ALIVE members")
    eq(detail.expected, 3, "expected counts everything but LEAVING (down included)")
    eq(#detail.unreachable_names, 1, "unreachable names reported")
    eq(detail.unreachable_names[1], "c", "the right node is named")
    eq(a:should_serve(), true, "quorum keeps serving")

    -- 只剩自己可达 -> 无 quorum -> 停止服务，/ha/health 变 degraded。
    a.last_sync_ms.b = (clk.now() - 31) * 1e6
    state = a:partition_state()
    eq(state, "partitioned_without_quorum", "isolated node loses quorum")
    eq(a:should_serve(), false, "isolated node stops serving")
    eq(a:ha_health().body:find('"status":"degraded"', 1, true) ~= nil, true,
        "health reports degraded without quorum")
    eq(a:ha_health().body:find('"should_serve":false', 1, true) ~= nil, true,
        "health exposes should_serve")
    eq(a:ha_status().body:find('"partition":"partitioned_without_quorum"', 1, true) ~= nil,
        true, "status carries the partition state")

    -- min_cluster_size 规则：小集群不裁 quorum（Rust 声明了这个配置但没用）。
    local pair = node("x", "http://x:30000", { "http://y:30000" },
        { now = clk.now, unreachable_s = 30, min_cluster_size = 3, quorum = 2 })
    pair.store.members["y:30000"].value.status = "alive"
    pair.last_sync_ms["y:30000"] = (clk.now() - 40) * 1e6
    eq(pair:partition_state(), "normal", "below min_cluster_size never reports a partition")
    eq(pair:should_serve(), true, "small cluster keeps serving")

    -- 恢复：成功同步把成员抬回 alive。
    net.drop["http://c:30000"] = false
    clk:advance(1)
    net:sync_all(1)
    eq(a.store.members.c.value.status, "alive", "sync success clears suspect/down")
    eq(a:partition_state(), "normal", "recovered to normal")
    eq(a.sync_fail.c or 0, 0, "failure counter cleared on recovery")
    eq(a:ha_health().body:find('"status":"healthy"', 1, true) ~= nil, true,
        "health back to healthy")
end

new_case("分区期间的状态写入：恢复后仍按 LWW 收敛")
do
    local clk = clock(1000)
    local opts = { now = clk.now, unreachable_s = 30, min_cluster_size = 2, quorum = 1 }
    local a = node("a", "http://a:30000", { "http://b:30000" }, opts)
    local b = node("b", "http://b:30000", { "http://a:30000" }, opts)
    local net = fabric({ a, b })
    a.http, b.http = net.http, net.http
    net:sync_all(1)
    -- 分区：双方各自继续写
    net.drop["http://b:30000"] = true
    a:observe_worker("shared", { model_id = "m", url = "http://old" }, { healthy = true, load = 1 })
    clk:advance(5)
    b:observe_worker("shared", { model_id = "m", url = "http://new" }, { healthy = false, load = 9 })
    b:observe_worker("only-b", { model_id = "m", url = "http://only-b" }, { healthy = true, load = 0 })
    eq(a.store.workers.shared.value.url, "http://old", "a keeps its own write during split")
    -- 愈合：两个方向的写入都要出现
    net.drop["http://b:30000"] = false
    clk:advance(1)
    net:sync_all(1)
    eq(a.store.workers.shared.value.url, "http://new", "later write wins after heal")
    eq(a.store.workers["only-b"].value.url, "http://only-b", "peer-local writes merge in")
    eq(mesh.count_live(a.store.workers), 2, "worker set merged")
    eq(a.store.workers["only-b"].value.url, b.store.workers["only-b"].value.url, "views agree")
end

--------------------------------------------------------------------------
new_case("内部端点 handler：ping / sync / apply / state 协议自洽")
do
    local clk = clock(1000)
    local a = node("a", "http://a:30000", { "http://b:30000" }, { now = clk.now })
    local b = node("b", "http://b:30000", { "http://a:30000" }, { now = clk.now })
    a:observe_worker("w-a", { model_id = "m", url = "http://ua" }, { healthy = true, load = 0 })

    local ping = a:handle_ping()
    local ping_body = type(ping) == "table" and ping.body or nil
    if ping_body then
        eq(ping.status, 200, "ping 200")
        check(ping_body:find('"node":"a"', 1, true) ~= nil, "ping answers node name", ping_body)
        check(ping_body:find('"status":"alive"', 1, true) ~= nil, "ping answers alive")
    else
        check(true, "ping under ngx (body via ngx.print)")
    end

    -- sync：请求体是 a 的快照，响应体是 b 的快照，一次往返双向收敛。
    local envelope = mesh.encode(a:snapshot())
    local resp = b:handle_sync({ body = envelope })
    if type(resp) == "table" then
        eq(resp.status, 200, "sync 200")
        eq(mesh.read_body(nil), "", "read_body without ngx is safe")
        local remote = mesh.decode(resp.body)
        check(remote ~= nil, "sync response decodes")
        a:apply_snapshot(remote)
        eq(a.store.workers["w-a"] ~= nil, true, "a kept its own worker")
        eq(b.store.workers["w-a"].value.url, "http://ua", "b applied a's push")
        eq(a.store.members.b.value.status, "alive", "sync marks peer alive")
    else
        check(true, "sync under ngx (body via ngx.print)")
    end

    -- apply：只推不拉
    local before = b.stats.applied
    local pushed = a:handle_apply({ body = mesh.encode(b:snapshot()) })
    if type(pushed) == "table" then
        eq(pushed.status, 200, "apply 200")
        local bad = a:handle_apply({ body = "not-base64!!" })
        eq(bad.status, 400, "apply rejects a bad envelope")
        local bad2 = a:handle_sync({ body = "YWJj" })  -- "abc": not a snapshot
        eq(bad2.status, 400, "sync rejects a non-snapshot payload")
    end
    check(b.stats.applied >= before, "apply counted", b.stats.applied)

    -- 协议版本不符必须被拒（防止两版节点互相静默吞包）
    local wrong = b:handle_apply({ body = mesh.encode({ protocol = 99, node = "z" }) })
    if type(wrong) == "table" then
        eq(wrong.status, 400, "protocol mismatch rejected")
    end

    local state = a:handle_state()
    if type(state) == "table" then
        eq(state.status, 200, "state 200")
        local snap = mesh.decode(state.body)
        eq(snap.node, "a", "state carries own snapshot")
    end
end

--------------------------------------------------------------------------
new_case("/ha/* 对外语义（对齐 handlers.rs 的响应形状）")
do
    local clk = clock(1000)
    local a = node("a", "http://a:30000", { "http://b:30000" }, { now = clk.now })
    a:observe_worker("w1", { model_id = "m1", url = "http://u1" }, { healthy = true, load = 2 })
    a:observe_policy("m1", "round_robin", {})

    local status = a:ha_status()
    if type(status) == "table" then
        eq(status.status, 200, "status 200")
        local doc = require("cjson.safe").decode(status.body)
        eq(doc.node_name, "a", "node_name")
        eq(doc.node_count, 2, "node_count counts members")
        eq(type(doc.nodes) == "table" and #doc.nodes, 2, "nodes is an array")
        eq(doc.nodes[1].name, "a", "nodes sorted by name")
        eq(doc.stores.membership_count, 2, "stores.membership_count")
        eq(doc.stores.worker_count, 1, "stores.worker_count is real (Rust hardcodes 0)")
        eq(doc.stores.policy_count, 1, "stores.policy_count is real")
        eq(doc.stores.app_count, 0, "stores.app_count")

        local workers = require("cjson.safe").decode(a:ha_workers().body)
        eq(#workers, 1, "ha/workers lists one")
        eq(workers[1].worker_id, "w1", "worker_id field name (Rust WorkerState)")
        eq(workers[1].health, true, "health field name")
        eq(workers[1].load, 2, "load field name")

        local policies = require("cjson.safe").decode(a:ha_policies().body)
        eq(policies[1].policy_type, "round_robin", "policy_type field name")
        eq(a:ha_policy(nil, "m1").status, 200, "policy by model id")
        eq(a:ha_policy(nil, "nope").status, 404, "unknown policy 404")
        eq(a:ha_policy(nil, "nope").body:find("Policy not found", 1, true) ~= nil, true,
            "Rust error wording")
        eq(a:ha_worker(nil, "nope").body:find("Worker not found", 1, true) ~= nil, true,
            "worker 404 wording")

        -- config：hex 编码 + 400 校验（Rust 的三条错误分支）
        eq(a:ha_config_get(nil, "missing").status, 404, "config 404 wording")
        eq(a:ha_config_put({ body = '{"key":"k","value":"zz"}' }).status, 400, "bad hex 400")
        eq(a:ha_config_put({ body = '{"key":"k","value":"abc"}' }).status, 400, "odd hex 400")
        eq(a:ha_config_put({ body = '{"value":"61"}' }).status, 400, "missing key 400")
        eq(a:ha_config_put({ body = 'not json' }).status, 400, "invalid body 400")
        local ok_put = a:ha_config_put({ body = '{"key":"k","value":"6869"}' })
        eq(ok_put.status, 200, "config put 200")
        local got = require("cjson.safe").decode(a:ha_config_get(nil, "k").body)
        eq(got.value, "6869", "config value round-trips as hex")
        eq(got.format, "hex", "config format tag (Rust json field)")

        -- rate limit
        eq(a:ha_rate_limit_get().status, 404, "unset rate limit 404")
        eq(a:ha_rate_limit_set({ body = '{"limit_per_second":100}' }).status, 200, "set rate limit 200")
        local rl = require("cjson.safe").decode(a:ha_rate_limit_get().body)
        eq(rl.limit_per_second, 100, "rate limit read back")
        a:rate_inc(mesh.GLOBAL_RATE_LIMIT_COUNTER_KEY, 30)
        local stats = require("cjson.safe").decode(a:ha_rate_limit_stats().body)
        eq(stats.limit_per_second, 100, "stats limit")
        eq(stats.current_count, 30, "stats current_count")
        eq(stats.remaining, 70, "stats remaining")
        eq(a:ha_rate_limit_set({ body = '{}' }).status, 400, "rate limit needs a number")
    end
end

--------------------------------------------------------------------------
new_case("shutdown 只标记 draining + 广播，不退出进程")
do
    local clk = clock(1000)
    local a = node("a", "http://a:30000", { "http://b:30000" }, { now = clk.now })
    local b = node("b", "http://b:30000", { "http://a:30000" }, { now = clk.now })
    local net = fabric({ a, b })
    a.http, b.http = net.http, net.http

    local resp = a:ha_shutdown()
    if type(resp) == "table" then
        eq(resp.status, 202, "shutdown 202 (Rust ACCEPTED)")
        check(resp.body:find("shutdown initiated", 1, true) ~= nil, "shutdown wording")
    end
    eq(a.draining, true, "marked draining")
    eq(a.store.members.a.value.status, "leaving", "self member marked leaving")
    eq(a:should_serve(), false, "draining node reports not serving")
    eq(#net.calls > 0, true, "shutdown broadcast a round")
    eq(b.store.members.a.value.status, "leaving", "peer learned leaving from the broadcast")
    eq(b:ha_status().body:find('"status":"leaving"', 1, true) ~= nil, true,
        "peer status exposes leaving")
    eq(a.started, false, "no process exit / no timer running")
    -- 幂等：重复 shutdown 不再改版本
    local v1 = a.store.members.a.version
    a:ha_shutdown()
    eq(a.store.members.a.version, v1, "second shutdown does not bump the member version")
end

--------------------------------------------------------------------------
new_case("dispatch 路由表 + 未启用固定体")
do
    -- 路由表规模：Rust server.rs:1393-1404 的 12 条 /ha/* + 本实现补充的
    -- /ha/stats（Rust 无对应）+ 4 条 /_mesh/internal/*
    eq(#mesh.ROUTES, 17, "route table size")
    local seen = {}
    for i = 1, #mesh.ROUTES do
        local key = mesh.ROUTES[i].method .. " " .. mesh.ROUTES[i].path
        check(not seen[key], "route table has no duplicates: " .. key)
        seen[key] = true
        check(type(mesh[mesh.ROUTES[i].handler]) == "function",
            "handler exists: " .. mesh.ROUTES[i].handler)
    end

    local off = mesh.dispatch(nil, "GET", "/ha/status")
    if type(off) == "table" then
        eq(off.status, 503, "mesh disabled -> 503")
        eq(off.body, '{"error":"mesh not enabled"}',
            "disabled body is byte-identical to the existing contract")
        eq(off.content_type, "application/json", "disabled body content type")
    end

    local clk = clock(1000)
    local a = node("a", "http://a:30000", { "http://b:30000" }, { now = clk.now })
    eq(mesh.dispatch(a, "GET", "/ha/workers").status, 200, "dispatch GET /ha/workers")
    eq(mesh.dispatch(a, "GET", "/ha/workers/w1", { worker_id = "w1" }).status, 404,
        "dispatch passes the path param through")
    a:observe_worker("w1", { model_id = "m", url = "http://u" }, { healthy = true, load = 0 })
    eq(mesh.dispatch(a, "GET", "/ha/workers/w1", { worker_id = "w1" }).status, 200,
        "dispatch finds it after the write")
    eq(mesh.dispatch(a, "POST", "/ha/shutdown").status, 202, "dispatch POST /ha/shutdown")
    eq(mesh.dispatch(a, "GET", "/ha/rate-limit/stats").status, 200,
        "dispatch longest-prefix route wins")
    eq(mesh.dispatch(a, "GET", "/ha/nope").status, 404, "unknown /ha/* 404")
    eq(mesh.dispatch(a, "DELETE", "/ha/status").status, 404, "method must match")
    eq(mesh.dispatch(a, "GET", "/v1/models"), nil, "non-ha path returns nil (router handles)")
    eq(mesh.dispatch(a, "GET", "/_mesh/internal/ping").status, 200, "internal ping via dispatch")
    eq(mesh.dispatch(nil, "GET", "/_mesh/internal/ping").status, 503,
        "internal endpoint also gated by mesh enabled")
end

--------------------------------------------------------------------------
new_case("from_env：环境变量装配")
do
    local env = {
        SMG_MESH_PEERS = "http://10.0.0.1:30000 http://10.0.0.2:30000",
        SMG_MESH_SELF = "http://10.0.0.1:30000",
        SMG_MESH_SYNC_INTERVAL_SECS = "5",
        SMG_MESH_UNREACHABLE_TIMEOUT_SECS = "45",
        SMG_MESH_QUORUM = "1",
        SMG_MESH_RATE_WINDOW_SECS = "2",
    }
    local function getenv(name) return env[name] end
    local m, err = mesh.from_env(getenv)
    check(m ~= nil, "from_env builds a mesh", err)
    eq(m.self_name, "10.0.0.1:30000", "self name defaults to hostport(SELF)")
    eq(#m.seed_peers, 2, "space separated peers parsed")
    eq(m.config.interval_s, 5, "interval from env")
    eq(m.config.unreachable_s, 45, "unreachable timeout from env")
    eq(m.config.quorum, 1, "quorum from env")
    eq(m.config.rate_window_s, 2, "rate window from env")
    check(m.store.members["10.0.0.2:30000"] ~= nil, "peer seeded")
    check(m.store.members["10.0.0.1:30000"] ~= nil, "self seeded")
    eq(m.store.members["10.0.0.1:30000"].value.status, "alive", "self is alive")
    eq(m.store.members["10.0.0.2:30000"].value.status, "init", "unproven seed is init")

    local none, nerr = mesh.from_env(function() return nil end)
    eq(none, nil, "no peers -> nil (mesh disabled)")
    check(nerr ~= nil, "disabled reason reported")

    -- 模块级单例
    local first = mesh.init(getenv)
    check(first ~= nil, "init stores the instance")
    eq(mesh.instance(), first, "instance() returns it")
    eq(mesh.init(getenv), first, "init is idempotent")
    mesh.set_instance(nil)
    eq(mesh.instance(), nil, "set_instance(nil) clears it")
end

--------------------------------------------------------------------------
new_case("sync_tick 的失败/恢复记账（cosocket 用注入替身）")
do
    local clk = clock(1000)
    local opts = { now = clk.now, unreachable_s = 30, suspect_threshold = 2 }
    local a = node("a", "http://a:30000", { "http://b:30000" }, opts)
    local b = node("b", "http://b:30000", { "http://a:30000" }, opts)
    local net = fabric({ a, b })
    a.http, b.http = net.http, net.http
    eq(a:sync_tick(), 1, "tick reports how many peers were synced")
    eq(a.store.members.b.value.status, "alive", "b alive after a tick")

    -- 对端返 500：算失败，不推进状态之外的东西
    local broken = function() return 500, '{"error":"boom"}' end
    a.http = broken
    a:sync_tick()
    eq(a.stats.sync_failures, 1, "http failure counted")
    eq(a.sync_fail.b, 1, "consecutive failure recorded")
    a:sync_tick()
    eq(a.store.members.b.value.status, "suspect", "suspect after suspect_threshold")
    b:sync_tick()  -- b 仍然能连 a：a 从 b 的视角保持 alive
    a.http = net.http
    a:sync_tick()
    eq(a.store.members.b.value.status, "alive", "recovered to alive")
    eq(a.sync_fail.b, 0, "failure counter cleared")

    -- 传输层失败（连接被拒）
    a.http = function() return nil, nil, "connect failed" end
    local ok, err = a:sync_with("http://b:30000")
    eq(ok, 0, "sync_with returns 0 on transport failure")
    check(err ~= nil and err ~= false, "transport error surfaced", err)

    -- 坏包：状态不被污染
    a.http = function() return 200, "not-base64!!" end
    local applied, perr = a:sync_with("http://b:30000")
    eq(applied, 0, "undecodable snapshot applies nothing")
    check(perr ~= nil, "decode error surfaced")
    a.http = net.http
    clk:advance(1)
    net:sync_all(1)
    eq(a.store.members.b.value.status, "alive", "healthy again after good packets")

    -- start() 在没有 ngx.timer 时明确失败而不是静默不跑
    local started, serr = a:start()
    eq(started, false, "start refused without OpenResty")
    check(serr ~= nil, "start reports why")
end

--------------------------------------------------------------------------
new_case("快照体积与 blob 上限")
do
    local clk = clock(1000)
    local a = node("a", "http://a:30000", {}, { now = clk.now, snapshot_max_bytes = 128 })
    check(a:observe_tree("m", string.rep("y", 128)), "blob at the limit accepted")
    check(not a:observe_tree("m2", string.rep("y", 129)), "blob over the limit skipped")
    local text = mesh.encode(a:snapshot())
    check(text ~= nil and #text > 0, "snapshot encodes")
    -- 快照必须能整体解码回来（base64 + JSON 往返不丢结构）
    local back = mesh.decode(text)
    eq(back.node, a.self_name, "snapshot node survives")
    eq(back.protocol, mesh.PROTOCOL, "protocol survives")
    eq(#back.stores.trees, 1, "only the accepted blob is in the snapshot")
end

--------------------------------------------------------------------------
new_case("限流窗口跨机合并（任务书指定的合并语义）")
do
    local clk = clock(1000)
    local opts = { now = clk.now, rate_window_s = 60, min_cluster_size = 3, quorum = 2 }
    local nodes = {}
    for i = 1, 3 do
        local peers = {}
        for j = 1, 3 do
            if i ~= j then peers[#peers + 1] = "http://n" .. j .. ":30000" end
        end
        nodes[i] = node("n" .. i, "http://n" .. i .. ":30000", peers, opts)
    end
    local net = fabric(nodes)
    for i = 1, 3 do
        nodes[i].http = net.http
    end
    net:sync_all(1)
    nodes[1]:rate_inc("global", 10)
    nodes[2]:rate_inc("global", 20)
    nodes[3]:rate_inc("global", 30)
    net:sync_all(2)
    eq(nodes[1]:rate_value("global"), 60, "n1 sees the cluster total")
    eq(nodes[2]:rate_value("global"), 60, "n2 sees the cluster total")
    eq(nodes[3]:rate_value("global"), 60, "n3 sees the cluster total")
    -- 再同步几轮不能重复计数（PN counter 的幂等合并）
    net:sync_all(3)
    eq(nodes[1]:rate_value("global"), 60, "no double counting after extra rounds")
    eq(nodes[3]:rate_value("global"), 60, "still stable on the last node")

    -- 局部网络故障：只有两个分区可见的计数在愈合后自动补齐
    net.drop["http://n3:30000"] = true
    clk:advance(1)
    nodes[1]:rate_inc("global", 5)
    nodes[2]:rate_inc("global", 5)
    nodes[1]:sync_with("http://n2:30000")
    nodes[2]:sync_with("http://n1:30000")
    -- n1/n2 这一侧带着合并来的 60（含 n3 的 30）再加各自的 5。
    eq(nodes[1]:rate_value("global"), 70, "reachable side carries merged + own increments")
    eq(nodes[3]:rate_value("global"), 60, "isolated side keeps its own view")
    net.drop["http://n3:30000"] = false
    clk:advance(1)
    net:sync_all(1)
    eq(nodes[3]:rate_value("global"), 70, "healed side catches up without double counting")
    eq(nodes[1]:rate_value("global"), 70, "both sides agree after healing")
end

new_case("把自己写进 SMG_MESH_PEERS 不会自我同步，也不会污染分区判定")
do
    local clk = clock(1000)
    -- 运维常见手滑：peers 里连自己的地址一起写了，而且写法与 SELF 不同名。
    local a = mesh.new{
        self_name = "alpha", self_addr = "http://10.0.0.1:30000",
        peers = { "http://10.0.0.1:30000", "http://10.0.0.2:30000" },
        now = clk.now, unreachable_s = 30, min_cluster_size = 2, quorum = 2,
    }
    eq(mesh.count_live(a.store.members), 2,
        "member table is self + the one real peer (no phantom self key)")
    eq(a.store.members["10.0.0.1:30000"], nil, "self address not keyed as a separate member")
    eq(#a:peer_bases(), 1, "self address filtered out of the sync list")
    eq(a:peer_bases()[1], "http://10.0.0.2:30000", "the real peer survives")
    local calls = 0
    a.http = function(method, url)
        calls = calls + 1
        eq(type(url:find("10.0.0.1:30000")), "nil", "never POST to ourselves")
        return 200, mesh.encode(mesh.new{ self_name = "b",
            self_addr = "http://10.0.0.2:30000", now = clk.now }:snapshot())
    end
    eq(a:sync_tick(), 1, "one peer synced")
    eq(calls, 1, "exactly one HTTP call per tick")
    -- 幻影键不应该把单节点自己拖成 degraded
    eq(a:partition_state(), "normal", "self-referential seed does not fake a partition")
    -- 一个对等端也没有时，peers 只剩自己也要等价于「没启用同步」
    local solo = mesh.new{ self_name = "s", self_addr = "http://10.9.9.9:30000",
        peers = { "http://10.9.9.9:30000" }, now = clk.now }
    eq(#solo:peer_bases(), 0, "peers containing only self syncs nobody")
    eq(mesh.count_live(solo.store.members), 1, "and the member table stays single-node")
end

new_case("route_matches：段级匹配（':' 只通配一段）")
do
    local cases = {
        -- pattern, path, expect
        { "ha/status", "ha/status", true },
        { "ha/status", "ha/health", false },
        { "ha/status", "ha/status/extra", false },
        { "ha/status", "ha", false },
        { "ha/workers/:worker_id", "ha/workers/w1", true },
        { "ha/workers/:worker_id", "ha/workers/", false },
        { "ha/workers/:worker_id", "ha/workers/w1/w2", false },
        { "ha/workers/:worker_id", "ha/workers", false },
        { "ha/rate-limit/stats", "ha/rate-limit/stats", true },
        { "ha/rate-limit/stats", "ha/rate-limit", false },
        { "ha/rate-limit", "ha/rate-limit", true },
        { "ha/rate-limit", "ha/rate-limit/stats", false },
        { "ha/config/:key", "ha/config/global_rate_limit", true },
        { "_mesh/internal/sync", "_mesh/internal/sync", true },
        { "_mesh/internal/sync", "_mesh/internal/ping", false },
    }
    for i = 1, #cases do
        local c = cases[i]
        eq(mesh.route_matches(c[1], c[2]), c[3],
            string.format("route_matches(%s, %s)", c[1], c[2]))
    end
    -- 表里的每条路由都要能被「自己 + 把 :param 换成一段真实值」的路径匹配，
    -- 同时字面 pattern 必须精确匹配自己（防止 pattern 形状写错）。
    for i = 1, #mesh.ROUTES do
        local pattern = mesh.ROUTES[i].path
        eq(mesh.route_matches(pattern, pattern), true, "literal pattern matches itself: " .. pattern)
        local concrete = pattern:gsub(":[%w_]+", "x")
        eq(mesh.route_matches(pattern, concrete), true, "param pattern matches a value: " .. pattern)
    end
end

--------------------------------------------------------------------------
new_case("路由表自检：每条路由的 handler 都能带空参数跑通")
do
    -- 漏传 path param（接线时最常见的错）必须是 404，而不是 Lua 报错。
    local clk = clock(1000)
    local a = node("a", "http://a:30000", { "http://b:30000" }, { now = clk.now })
    for i = 1, #mesh.ROUTES do
        local route = mesh.ROUTES[i]
        local ok, err = pcall(a[route.handler], a, { body = "" })
        check(ok, "handler survives empty args: " .. route.path, err)
    end
    eq(a:ha_worker().status, 404, "missing worker_id is 404, not an error")
    eq(a:ha_policy(nil, nil).status, 404, "missing model_id is 404, not an error")
    eq(a:ha_config_get(nil, nil).status, 404, "missing key is 404, not an error")
    a:observe_worker("w1", { model_id = "m", url = "http://u" }, { healthy = true, load = 0 })
    eq(a:ha_worker(nil, "w1").status, 200, "the same call works once the id arrives")
end

--------------------------------------------------------------------------
io.write("\n")
if failed == 0 then
    io.write(string.format("test_mesh.lua: all %d checks passed\n", passed))
else
    io.write(string.format("test_mesh.lua: %d passed, %d failed\n", passed, failed))
    for i = 1, #failures do
        io.write("  FAIL: " .. failures[i] .. "\n")
    end
end
os.exit(failed == 0 and 0 or 1)
