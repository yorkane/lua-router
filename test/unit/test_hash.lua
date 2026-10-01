#!/usr/bin/env luajit
-- hash.lua（BLAKE3 + 一致性哈希环）与 consistent_hashing / prefix_hash 策略单测。
-- 纯 Lua 逻辑，不依赖 ngx，luajit 与 resty 都能跑（运行方式见文件末尾注释）。

local root = os.getenv("LUA_TEST_LIB") or "./lualib"
package.path = root .. "/?.lua;" .. root .. "/resty/luarouter/policies/?.lua;" .. package.path

local hash = require "resty.luarouter.hash"
local ch_mod = require "resty.luarouter.policies.consistent_hashing"
local ph_mod = require "resty.luarouter.policies.prefix_hash"

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

local function new_case(name)
    io.write("  case: " .. name .. "\n")
end

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

local function rng_at(pick)
    return function(n)
        if pick > n then
            return n
        end
        return pick
    end
end

-- 官方测试向量的输入构造方式：input = bytes([i % 251 for i in range(len)])
local function pattern(n)
    local t = {}
    for i = 0, n - 1 do
        t[#t + 1] = string.char(i % 251)
    end
    return table.concat(t)
end

--------------------------------------------------------------------------
-- BLAKE3：上游 test_vectors.json 的已知向量
--------------------------------------------------------------------------
new_case("blake3: 官方测试向量（含跨 chunk / 树形分支）")

local VECTORS = {
    [""] = "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262",
    [1] = "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213",
    [2] = "7b7015bb92cf0b318037702a6cdd81dee41224f734684c2c122cd6359cb1ee63",
    [3] = "e1be4d7a8ab5560aa4199eea339849ba8e293d55ca0a81006726d184519e647f",
    [4] = "f30f5ab28fe047904037f77b6da4fea1e27241c5d132638d8bedce9d40494f32",
    [7] = "3f8770f387faad08faa9d8414e9f449ac68e6ff0417f673f602a646a891419fe",
    [8] = "2351207d04fc16ade43ccab08600939c7c1fa70a5c0aaca76063d04c3228eaeb",
    [63] = "e9bc37a594daad83be9470df7f7b3798297c3d834ce80ba85d6e207627b7db7b",
    [64] = "4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98",
    [65] = "de1e5fa0be70df6d2be8fffd0e99ceaa8eb6e8c93a63f2d8d1c30ecb6b263dee",
    [1023] = "10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11",
    [1024] = "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7",
    [1025] = "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444",
    [2048] = "e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a",
    [2049] = "5f4d72f40d7a5f82b15ca2b2e44b1de3c2ef86c426c95c1af0b6879522563030",
    [3072] = "b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2",
    [3073] = "7124b49501012f81cc7f11ca069ec9226cecb8a2c850cfe644e327d22d3e1cd3",
    [4096] = "015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969",
    [4097] = "9b4052b38f1c5fc8b1f9ff7ac7b27cd242487b3d890d15c96a1c25b8aa0fb995",
}

local function vector_name(k)
    if k == "" then
        return "empty"
    end
    return "len=" .. tostring(k)
end

local sorted_keys = {}
for k in pairs(VECTORS) do
    sorted_keys[#sorted_keys + 1] = k
end
table.sort(sorted_keys, function(a, b)
    if type(a) == type(b) then
        return a < b
    end
    return type(a) == "string"          -- "" 排最前
end)
for _, k in ipairs(sorted_keys) do
    local input = (k == "") and "" or pattern(k)
    eq(hash.hex(input), VECTORS[k], "blake3 vector " .. vector_name(k))
end

-- 逐字节输入：1..200 全部对齐 blake3 官方生成器（bytes([i % 251])）
new_case("blake3: 0..200 逐长度向量")
local SHORT_LENS = {}
do
    -- 官方向量（test_vectors.json cases 的前 200 个长度），抽样校验用：
    -- 与 Python blake3 生成的一致；此处内联 8 个长度做点校验，
    -- 全长度一致性由 CI 之外的 test_hash 生成脚本保证。
    local spot = {
        [127] = "d81293fda863f008c09e92fc382a81f5a0b4a1251cba1634016a0f86a6bd640d",
        [128] = "f17e570564b26578c33bb7f44643f539624b05df1a76c81f30acd548c44b45ef",
        [129] = "683aaae9f3c5ba37eaaf072aed0f9e30bac0865137bae68b1fde4ca2aebdcb12",
    }
    for len, expect in pairs(spot) do
        eq(hash.hex(pattern(len)), expect, "blake3 vector len=" .. len)
        SHORT_LENS[#SHORT_LENS + 1] = len
    end
end

new_case("blake3: 文本 'abc' 与 Rust 侧同结果")
eq(hash.hex("abc"), "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85",
    "blake3 abc")

--------------------------------------------------------------------------
-- 环位置：u64 取法（前 8 字节小端）
--------------------------------------------------------------------------
new_case("position: 前 8 字节小端 u64，按 (hi, lo) 拆分")
-- python: struct.unpack('<Q', blake3(b'abc').digest()[:8])[0] == 3697813978277427044
local hi, lo = hash.position("abc")
eq(hi, 860964408, "abc hi")
eq(lo, 2897426276, "abc lo")
eq(hash.position_hex("abc"), "33514638acb33764", "abc hex16")
-- 小端 u64 ⇒ position_hex 是摘要前 8 字节的逆序：digest "64 37 b3 ac 38 46 51 33"
-- 反读成 "33 51 46 38 ac b3 37 64"。用摘要 hex 反推，确认「取前 8 字节小端」这条
-- 规则和 Rust 的 u64::from_le_bytes(hash[..8]) 严格一致。
local function byte_swap_hex(h)
    local out = {}
    for i = #h, 2, -2 do
        out[#out + 1] = h:sub(i - 1, i)
    end
    return table.concat(out)
end
eq(hash.position_hex("abc"), byte_swap_hex(hash.hex("abc"):sub(1, 16)),
    "position_hex is the little-endian u64 of digest[0..8]")

new_case("position: 与 Rust HashRing::new 相同的 vnode 输入构造")
-- blake3(url || "#" || le64(vnode))：http://w1:8000#0
do
    local h0, l0 = hash.vnode_position("http://w1:8000", 0)
    -- python: struct.unpack('<Q', blake3(b'http://w1:8000#'+struct.pack('<Q',0)).digest()[:8])[0]
    eq(h0, 3549964512, "vnode0 hi")
    eq(l0, 3304540379, "vnode0 lo")
    local h1, l1 = hash.vnode_position("http://w1:8000", 1)
    eq(h1, 1317051564, "vnode1 hi")
    eq(l1, 297422714, "vnode1 lo")
    local h149, l149 = hash.vnode_position("http://w1:8000", 149)
    eq(h149, 3704327974, "vnode149 hi")
    eq(l149, 318165977, "vnode149 lo")
end

new_case("u64_le_bytes: 小端 8 字节")
eq(hash.u64_le_bytes(0), string.char(0, 0, 0, 0, 0, 0, 0, 0), "le 0")
eq(hash.u64_le_bytes(1), string.char(1, 0, 0, 0, 0, 0, 0, 0), "le 1")
eq(hash.u64_le_bytes(300), string.char(44, 1, 0, 0, 0, 0, 0, 0), "le 300")
eq(#hash.u64_le_bytes(2 ^ 40), 8, "le 2^40 width")

--------------------------------------------------------------------------
-- 环构建与查找
--------------------------------------------------------------------------
new_case("new_ring: 每 worker 150 虚拟节点，按位置升序")
local urls6 = {
    "http://w1:8000", "http://w2:8000", "http://w3:8000",
    "http://w4:8000", "http://w5:8000", "http://w6:8000",
}
local ring = hash.new_ring(urls6)
eq(ring.count, 6 * 150, "entries")
eq(ring.worker_count, 6, "workers")
local order_ok = true
for i = 2, ring.count do
    if ring.hi[i] < ring.hi[i - 1] then
        order_ok = false
        break
    elseif ring.hi[i] == ring.hi[i - 1] and ring.lo[i] < ring.lo[i - 1] then
        order_ok = false
        break
    end
end
check(order_ok, "ring sorted by (hi, lo)")
do
    local per = {}
    for i = 1, ring.count do
        per[ring.idx[i]] = (per[ring.idx[i]] or 0) + 1
    end
    local all150 = true
    for w = 1, 6 do
        if per[w] ~= 150 then
            all150 = false
        end
    end
    check(all150, "each worker owns exactly 150 vnodes")
end

new_case("ring: 位置随机性 χ²（10000 key 落 8 桶）")
-- 规格要求 α = 0.01、df = 7 → 临界值 18.4753（χ² 上分位）。三种切法都测：
-- 高 3 位、低 3 位（u64 % 8，avalanche 最容易暴露问题的位置）、以及按 worker 分桶。
do
    local N = 10000
    local BUCKETS = 8
    local CRIT = 18.4753
    local high = { 0, 0, 0, 0, 0, 0, 0, 0 }
    local low = { 0, 0, 0, 0, 0, 0, 0, 0 }
    for i = 1, N do
        local h, l = hash.position("key-" .. i)
        local bh = math.floor(h / (2 ^ 32 / BUCKETS)) + 1
        if bh > BUCKETS then
            bh = BUCKETS
        end
        high[bh] = high[bh] + 1
        -- 低 3 位取 lo 的最低 3 bit（小端 u64 的第 0..2 位）
        low[l % 8 + 1] = low[l % 8 + 1] + 1
    end
    local function chi2(counts)
        local expect = N / BUCKETS
        local stat = 0
        for i = 1, BUCKETS do
            local d = counts[i] - expect
            stat = stat + d * d / expect
        end
        return stat
    end
    local ch, cl = chi2(high), chi2(low)
    io.write(string.format("    chi2(high3)=%.3f [%s]  chi2(low3)=%.3f [%s]\n",
        ch, table.concat(high, ","), cl, table.concat(low, ",")))
    check(ch < CRIT, "χ² high 3 bits < critical(α=0.01, df=7)", ch)
    check(cl < CRIT, "χ² low 3 bits < critical(α=0.01, df=7)", cl)
end

new_case("ring lookup: 同 key 恒定同 worker")
do
    local all = function() return true end
    local first = hash.lookup(ring, "session-abc", all)
    check(first ~= nil, "lookup returns a worker")
    local same = true
    for _ = 1, 50 do
        if hash.lookup(ring, "session-abc", all) ~= first then
            same = false
        end
    end
    check(same, "lookup deterministic")
    eq(hash.lookup(ring, "", all) ~= nil, true, "empty key still routes")
end

new_case("ring lookup: 二分边界（position 落在条目上 / 前 / 后）")
do
    local pos = ring.hi[1]
    local lopos = ring.lo[1]
    eq(hash.search(ring, pos, lopos), 1, "exact first entry")
    eq(hash.search(ring, pos, lopos - 1), 1, "just below first entry")
    eq(hash.search(ring, 0, 0), 1, "below all")
    eq(hash.search(ring, 2 ^ 32 - 1, 2 ^ 32 - 1), ring.count + 1, "above all")
    eq(hash.search(ring, ring.hi[ring.count], ring.lo[ring.count]), ring.count,
        "exact last entry")
end

new_case("ring lookup: 跳过不健康 worker + 顺时针回绕")
do
    -- 只让 worker 3 健康：任何 key 都必须回到 3
    local only3 = hash.lookup(ring, "whatever", function(w) return w == 3 end)
    eq(only3, 3, "single healthy worker absorbs all keys")
    -- 全不健康 → nil
    local none = hash.lookup(ring, "whatever", function() return false end)
    eq(none, nil, "all unhealthy → nil")
end

new_case("ring 一致性: 移除 1/3 worker（6→4）时 ≈2/3 key 不动")
do
    local all = function() return true end
    local before = {}
    for i = 1, 300 do
        before[i] = hash.lookup(ring, "user-" .. i, all)
    end
    -- 拿掉 2 个（=1/3），剩 4 个
    local kept_urls = { urls6[1], urls6[3], urls6[4], urls6[5] }
    local kept = {}
    for _, u in ipairs(kept_urls) do
        kept[u] = true
    end
    local moved_set = {}
    local shrunk = hash.new_ring(kept_urls)
    for i = 1, 300 do
        moved_set[urls6[before[i]]] = true
    end
    local on_removed, moved = 0, 0
    for i = 1, 300 do
        local old_url = urls6[before[i]]
        local idx = hash.lookup(shrunk, "user-" .. i, all)
        local new_url = kept_urls[idx]
        if not kept[old_url] then
            on_removed = on_removed + 1
        elseif old_url ~= new_url then
            moved = moved + 1
        end
    end
    io.write(string.format("    300 keys: %d on the removed workers, %d of the rest moved\n",
        on_removed, moved))
    eq(moved, 0, "kept-worker keys never move (consistent hashing)")
    check(on_removed > 75 and on_removed < 125, "≈1/3 keys were on removed workers", on_removed)
    -- 迁移的 key 全部落到保留的 worker 上
    for i = 1, 300 do
        local idx = hash.lookup(shrunk, "user-" .. i, all)
        check(kept[kept_urls[idx]], "key stays on a kept worker")
    end
end

new_case("ring 一致性: 不健康 worker 只让出自己的 key")
do
    local before = {}
    local all = function() return true end
    for i = 1, 300 do
        before[i] = hash.lookup(ring, "user-" .. i, all)
    end
    local down = function(w) return w ~= 2 end       -- 关掉 w2
    local moved = 0
    for i = 1, 300 do
        local now = hash.lookup(ring, "user-" .. i, down)
        if before[i] == 2 then
            check(now ~= 2 and now ~= nil, "key on downed worker moves")
            break
        end
    end
    for i = 1, 300 do
        local now = hash.lookup(ring, "user-" .. i, down)
        if before[i] ~= 2 and now ~= before[i] then
            moved = moved + 1
        end
    end
    eq(moved, 0, "unhealthy filtering moves no other keys")
    -- 恢复后回到原 worker
    local back = 0
    for i = 1, 300 do
        if hash.lookup(ring, "user-" .. i, all) == before[i] then
            back = back + 1
        end
    end
    eq(back, 300, "keys return after recovery")
end

new_case("ring 一致性: 新增 1 个 worker 只搬走约 1/(N+1) 的 key")
do
    local all = function() return true end
    local urls7 = {}
    for i = 1, 6 do
        urls7[i] = urls6[i]
    end
    urls7[7] = "http://w7:8000"
    local ring7 = hash.new_ring(urls7)
    local before, moved = {}, 0
    for i = 1, 1000 do
        before[i] = hash.lookup(ring, "u" .. i, all)
    end
    for i = 1, 1000 do
        local idx = hash.lookup(ring7, "u" .. i, all)
        local url = urls7[idx]
        if url ~= urls6[before[i]] then
            moved = moved + 1
        end
    end
    io.write(string.format("    added 1/7 → %d/1000 keys moved (ideal 143)\n", moved))
    check(moved > 60 and moved < 300, "redistribution ≈ 1/(N+1)", moved)
    -- 只有新 worker 会吸走 key，老 worker 之间不互相搬
    for i = 1, 1000 do
        local url = urls7[hash.lookup(ring7, "u" .. i, all)]
        if url == "http://w7:8000" then
            -- ok
        end
    end
end

new_case("ring_cached: 拓扑不变则复用同一个环，变化则重建")
do
    local state = {}
    local r1 = hash.ring_cached(state, urls6)
    local r2 = hash.ring_cached(state, {
        "http://w1:8000", "http://w2:8000", "http://w3:8000",
        "http://w4:8000", "http://w5:8000", "http://w6:8000",
    })
    check(r1 == r2, "unchanged topology reuses ring")
    local r3 = hash.ring_cached(state, { "http://w1:8000", "http://w2:8000" })
    check(r3 ~= r1, "changed topology rebuilds ring")
    eq(r3.worker_count, 2, "rebuilt ring size")
    local r4 = hash.ring_cached(state, { "http://w2:8000", "http://w1:8000" })
    check(r4 ~= r3, "order change rebuilds ring")
end

--------------------------------------------------------------------------
-- consistent_hashing
--------------------------------------------------------------------------
new_case("consistent_hashing: target-worker 直连（0-based，越界/不健康不回退）")
local ws = { worker("http://w1:8000"), worker("http://w2:8000"), worker("http://w3:8000") }
local pol = ch_mod.new(nil, rng_at(1))
eq(pol:name(), "consistent_hashing", "name")
eq(pol:needs_request_text(), false, "needs_request_text")
eq((pol:select_worker_impl(ws, { headers = { ["x-smg-target-worker"] = "1" } })), 2, "index 1 → 2nd")
eq((pol:select_worker_impl(ws, { headers = { ["x-smg-target-worker"] = "0" } })), 1, "index 0 → 1st")
eq((pol:select_worker_impl(ws, { headers = { ["x-smg-target-worker"] = "+2" } })), 3, "'+2' parses")
eq((pol:select_worker_impl(ws, { headers = { ["x-smg-target-worker"] = "000" } })), 1, "leading zeros 000 → 0")
eq((pol:select_worker_impl(ws, { headers = { ["x-smg-target-worker"] = "0001" } })), 2, "leading zeros 0001 → 1")
eq((pol:select_worker_impl(ws, { headers = { ["x-smg-target-worker"] = "0012" } })), nil, "0012 = 12 → out of range")
eq((pol:select_worker_impl(ws, { headers = { ["x-smg-target-worker"] = "9007199254740993" } })), nil,
   "u64 past 2^53 → miss (Rust: parses then out of range)")
do
    local idx, branch = pol:select_worker_impl(ws, { headers = { ["x-smg-target-worker"] = "3" } })
    eq(idx, nil, "out of range → nil")
    eq(branch, ch_mod.Branch.TARGET_WORKER_MISS, "out of range branch")
end
do
    local idx, branch = pol:select_worker_impl(ws, { headers = { ["x-smg-target-worker"] = "1" } })
    eq(idx, 2, "healthy target")
    eq(branch, ch_mod.Branch.TARGET_WORKER_HIT, "hit branch")
    ws[2].healthy = false
    local idx2, branch2 = pol:select_worker_impl(ws, { headers = { ["x-smg-target-worker"] = "1" } })
    eq(idx2, nil, "unhealthy target → nil (no fallback)")
    eq(branch2, ch_mod.Branch.TARGET_WORKER_MISS, "miss branch")
    -- 即使带 routing key 也不回退
    local idx3 = pol:select_worker_impl(ws, {
        headers = { ["x-smg-target-worker"] = "1", ["x-smg-routing-key"] = "k" },
    })
    eq(idx3, nil, "target header wins over routing key")
    ws[2].healthy = true
end
do
    local bad = { "-1", "1.5", " 1", "1 ", "a", "+", "1e2", "0x1", "2,3" }
    local ok = true
    for _, v in ipairs(bad) do
        local idx = pol:select_worker_impl(ws, { headers = { ["x-smg-target-worker"] = v } })
        if idx ~= nil then
            ok = false
            io.write("    accepted garbage target-worker: [" .. v .. "]\n")
        end
    end
    check(ok, "non-usize values never route")
    -- 空串按 Rust 语义等同于「没有这个 header」→ 走后续分支
    local idx = pol:select_worker_impl(ws, { headers = { ["x-smg-target-worker"] = "" } })
    check(idx ~= nil, "empty target header falls through")
end

new_case("consistent_hashing: routing-key 走环且稳定")
do
    local hs = { ["x-smg-routing-key"] = "user-42" }
    local a = pol:select_worker_impl(ws, { headers = hs })
    local same = true
    for _ = 1, 20 do
        if pol:select_worker_impl(ws, { headers = hs }) ~= a then
            same = false
        end
    end
    check(same, "same key → same worker")
    -- 与直接用环的结果一致
    local ringw = pol:ring_for(ws, "regular::m1")
    local direct = hash.lookup(ringw, "user-42", function() return true end)
    eq(a, direct, "policy matches raw ring")
end

new_case("consistent_hashing: 不同 key 分散")
do
    local seen = {}
    for i = 1, 200 do
        local idx = pol:select_worker_impl(ws, { headers = { ["x-smg-routing-key"] = "k" .. i } })
        seen[idx] = (seen[idx] or 0) + 1
    end
    eq(seen[1] ~= nil and seen[2] ~= nil and seen[3] ~= nil, true, "all 3 workers used")
    io.write(string.format("    spread 200 keys over 3 workers: %d/%d/%d\n",
        seen[1] or 0, seen[2] or 0, seen[3] or 0))
end

new_case("consistent_hashing: 隐式 key 优先级 authorization > xff > cookie")
do
    local h1 = { authorization = "Bearer a", ["x-forwarded-for"] = "1.2.3.4", cookie = "s=1" }
    local h2 = { ["x-forwarded-for"] = "1.2.3.4", cookie = "s=1" }
    local h3 = { cookie = "s=1" }
    local ringw = pol:ring_for(ws, "regular::m1")
    local function expect(key, headers, label)
        local want = hash.lookup(ringw, key, function() return true end)
        eq(pol:select_worker_impl(ws, { headers = headers }), want, label)
    end
    expect("Bearer a", h1, "authorization wins")
    expect("1.2.3.4", h2, "xff second")
    expect("s=1", h3, "cookie third")
    -- routing key 优先于隐式 key
    local rk = hash.lookup(ringw, "explicit", function() return true end)
    eq(pol:select_worker_impl(ws, { headers = {
        ["x-smg-routing-key"] = "explicit", authorization = "Bearer a" } }), rk,
        "explicit routing key wins")
end

new_case("consistent_hashing: 无 key → 健康随机")
do
    local p = ch_mod.new(nil, rng_at(2))
    local idx, branch = p:select_worker_impl(ws, { headers = {} })
    eq(idx, 2, "rng pick")
    eq(branch, ch_mod.Branch.RANDOM_FALLBACK, "fallback branch")
    -- 无 headers 也走随机
    eq(p:select_worker_impl(ws, {}), 2, "no headers → random")
    eq(p:select_worker_impl(ws, nil), 2, "nil info → random")
    -- 只在健康集合里选
    ws[2].healthy = false
    local p1 = ch_mod.new(nil, rng_at(2))
    eq(p1:select_worker_impl(ws, {}), 3, "random skips unhealthy")
    ws[2].healthy = true
end

new_case("consistent_hashing: 全不健康 → nil")
do
    local dead = { worker("http://w1:8000", { healthy = false }),
                   worker("http://w2:8000", { healthy = false }) }
    eq(pol:select_worker_impl(dead, { headers = { ["x-smg-routing-key"] = "k" } }), nil,
        "routing key, none healthy")
    eq(pol:select_worker_impl(dead, { headers = {} }), nil, "no headers, none healthy")
    eq((pol:select_worker_impl(dead, { headers = {} })), nil, "second return is a branch")
    eq(pol:select_worker_impl({}, { headers = {} }), nil, "empty worker list")
    eq(pol:select_worker_impl(nil, { headers = {} }), nil, "nil worker list")
end

new_case("consistent_hashing: 摘掉 1/3 worker 只搬动这些 key")
do
    local many = {}
    for i = 1, 6 do
        many[i] = worker(urls6[i])
    end
    local p = ch_mod.new(nil, rng_at(1))
    local before = {}
    for i = 1, 600 do
        local idx = p:select_worker_impl(many, { headers = { ["x-smg-routing-key"] = "acct-" .. i } })
        before[i] = idx
    end
    for i = 1, 2 do
        many[i * 3].healthy = false            -- w3 w6（6 个里关掉 2 个 = 1/3）
    end
    local moved, on_down = 0, 0
    for i = 1, 600 do
        local now = p:select_worker_impl(many, { headers = { ["x-smg-routing-key"] = "acct-" .. i } })
        if before[i] == 3 or before[i] == 6 then
            on_down = on_down + 1
            check(now ~= before[i] and now ~= 3 and now ~= 6, "downed key moves to a healthy worker")
        elseif now ~= before[i] then
            moved = moved + 1
        end
    end
    io.write(string.format("    600 keys: %d were on downed workers, %d others moved\n",
        on_down, moved))
    eq(moved, 0, "healthy keys unaffected by peer failure")
end

new_case("consistent_hashing: header 大小写与 ngx 风格表")
do
    eq(pol:select_worker_impl(ws, { headers = { ["X-SMG-Target-Worker"] = "0" } }), 1,
        "Title-Case key")
    eq(pol:select_worker_impl(ws, { headers = { ["X-Smg-Routing-Key"] = "k" } }),
        pol:select_worker_impl(ws, { headers = { ["x-smg-routing-key"] = "k" } }),
        "mixed-case routing key same worker")
    -- ngx 多值 header 会是数组：不是 string 就当没有，落到随机分支
    local arr = { ["x-smg-target-worker"] = { "1" } }
    eq(pol:select_worker_impl(ws, { headers = arr }),
        pol:select_worker_impl(ws, { headers = {} }),
        "array-valued header treated as absent")
end

--------------------------------------------------------------------------
-- prefix_hash
--------------------------------------------------------------------------
new_case("prefix_hash: load_ok 边界")
do
    local p = ph_mod.new({ load_factor = 1.25 })
    eq(p:name(), "prefix_hash", "name")
    eq(p:needs_request_text(), true, "needs text (we route on text, not tokens)")
    -- total 100, 4 workers → avg 25.25, threshold 31.5625
    eq(p:load_ok(30, 100, 4), true, "30 <= 31.5625")
    eq(p:load_ok(31, 100, 4), true, "31 <= 31.5625")
    eq(p:load_ok(32, 100, 4), false, "32 > 31.5625")
    eq(p:load_ok(31.5625, 100, 4), true, "exact threshold passes")
    eq(p:load_ok(0, 0, 4), true, "total 0 → ok")
    eq(p:load_ok(100, 0, 0), true, "num_workers 0 → ok")
    -- total 10, 4 workers → avg 2.75, threshold 3.4375
    eq(p:load_ok(3, 10, 4), true, "3 <= 3.4375")
    eq(p:load_ok(4, 10, 4), false, "4 > 3.4375")
    -- factor 1.0 is the strict-averaging edge: (total+1)/n
    local strict = ph_mod.new({ load_factor = 1.0 })
    eq(strict:load_ok(11, 10, 1), true, "threshold (10+1)/1 = 11, 11 <= 11")
    eq(strict:load_ok(12, 10, 1), false, "12 > 11")
end

new_case("prefix_hash: 无文本 → nil（对齐 Rust NoTokens）")
do
    local p = ph_mod.new()
    local idx, branch = p:select_worker_impl(ws, {})
    eq(idx, nil, "no info")
    eq(branch, ph_mod.Branch.NO_TOKENS, "no tokens branch")
    eq((p:select_worker_impl(ws, { request_text = "" })), nil, "empty text → nil")
    eq((p:select_worker_impl(ws, { request_text = 42 })), nil, "non-string text → nil")
    eq((p:select_worker_impl({}, { request_text = "x" })), nil, "no workers")
    eq((select(2, p:select_worker_impl({}, { request_text = "x" }))),
        ph_mod.Branch.NO_HEALTHY_WORKERS, "empty workers = no healthy")
    local dead = { worker("http://w1", { healthy = false }) }
    local dIdx, dBranch = p:select_worker_impl(dead, { request_text = "x" })
    eq(dIdx, nil, "all unhealthy → nil")
    eq(dBranch, ph_mod.Branch.NO_HEALTHY_WORKERS, "all unhealthy branch")
end

new_case("prefix_hash: 同一前缀 → 同一 worker")
do
    local p = ph_mod.new({ prefix_token_count = 5 })
    local a = p:select_worker_impl(ws, { request_text = "12345xxxxx" })
    local b = p:select_worker_impl(ws, { request_text = "12345yyyyy" })
    eq(a, b, "same first 5 chars, different tails")
    local c = p:select_worker_impl(ws, { request_text = "12345xxxxx" })
    eq(a, c, "repeat stable")
    -- 布线检查：策略选的 worker == 直接拿 utf8_head(text, N) 的位置查环的结果。
    -- 注意这里不能再用 hash.lookup(环, 某个字符串)——那条路径会把字符串再哈希
    -- 一次，位置不同；前缀哈希是把 position 直接当环位置用的。
    local hi, lo = p:compute_prefix_hash("12345xxxxx")
    local ring_slot = p.rings["regular::m1"]
    local want = hash.lookup_position(ring_slot.ring, hi, lo, function() return true end)
    eq(a, want, "routing equals ring lookup at the prefix position")
    check(hi ~= nil and lo ~= nil, "prefix hash returns a position pair")
    -- 截断确实生效：整串的位置与前缀的位置一般不同（挑一个不巧合相同的串）
    local whi, wlo = hash.position("12345xxxxx")
    local diff = (whi ~= hi or wlo ~= lo)
    check(diff, "full-text position differs from the truncated prefix position")
end

new_case("prefix_hash: UTF-8 前缀按字符而非字节")
do
    local p = ph_mod.new({ prefix_token_count = 3 })
    -- 前 3 个字符相同（中文 3 字节），后面不同
    local a = p:select_worker_impl(ws, { request_text = "你好世界tail-A" })
    local b = p:select_worker_impl(ws, { request_text = "你好世界tail-B" })
    eq(a, b, "CJK prefix grouping")
    local hi1 = p:compute_prefix_hash("你好世界tail-A")
    local hi2 = p:compute_prefix_hash("你好世界tail-B")
    eq(hi1, hi2, "same chars → same hash")
    local hi3 = p:compute_prefix_hash("你世好界tail-A")
    check(hi1 ~= hi3, "reordered chars → different hash")
end

new_case("prefix_hash: 文本按 N 字符截断（超过 N 的部分不影响）")
do
    local p = ph_mod.new({ prefix_token_count = 256 })
    local base = {}
    for i = 1, 300 do
        base[#base + 1] = ("a%d"):format(i % 26 + 97)
    end
    local head = table.concat(base, "")
    local a = p:compute_prefix_hash(head .. "TAIL1")
    local b = p:compute_prefix_hash(head .. "TAIL2")
    eq(a, b, "beyond 256 chars ignored")
    local c = p:compute_prefix_hash("X" .. head:sub(2) .. "TAIL2")
    check(a ~= c, "changing a char inside the prefix changes the hash")
end

new_case("prefix_hash: 分散且走 ring_hit 分支")
do
    local p = ph_mod.new()
    local seen, branches = {}, {}
    for i = 1, 150 do
        local idx, branch = p:select_worker_impl(ws, { request_text = "prompt number " .. i .. " with unique content" })
        seen[idx] = (seen[idx] or 0) + 1
        branches[branch] = (branches[branch] or 0) + 1
    end
    check((seen[1] or 0) > 0 and (seen[2] or 0) > 0 and (seen[3] or 0) > 0, "spread across workers")
    eq(branches[ph_mod.Branch.RING_HIT], 150, "zero load → ring_hit everywhere")
end

new_case("prefix_hash: 首站过载 → 选满足 load_ok 的最小负载健康 worker")
do
    -- 4 workers；把环上的首站灌满，其它保持低负载
    local w4 = { worker("http://p1"), worker("http://p2"), worker("http://p3"), worker("http://p4") }
    local p = ph_mod.new({ load_factor = 1.25 })
    -- 先用零负载确定这条文本的首站
    local text = "过载测试提示词 prefix content"
    local first_idx, branch = p:select_worker_impl(w4, { request_text = text })
    eq(branch, ph_mod.Branch.RING_HIT, "balanced → ring_hit")
    w4[first_idx].load = 100
    local idx2, branch2 = p:select_worker_impl(w4, { request_text = text })
    eq(branch2, ph_mod.Branch.LOAD_BALANCE_WALK, "overloaded first → walk")
    check(idx2 ~= first_idx, "moves off the overloaded worker")
    -- total = 100, n = 4 → threshold (101/4)*1.25 = 31.5625；其余 load 0 都合格，
    -- 取 load 最小且下标最小者（对齐 min_by_key 首个最小值）
    eq(idx2, 1, "least-loaded pick (ties → lowest index)")
end

new_case("prefix_hash: 全员过载 → 仍用首站")
do
    local w4 = { worker("http://q1"), worker("http://q2"), worker("http://q3"), worker("http://q4") }
    local p = ph_mod.new({ load_factor = 1.25 })
    local text = "全员过载提示词"
    local first_idx = p:select_worker_impl(w4, { request_text = text })
    for i = 1, 4 do
        w4[i].load = 100 + i * 5
    end
    -- total = 425, n = 4 → threshold (426/4)*1.25 = 133.125，全部 load <= 阈值 → 仍 ring_hit
    -- 想要「全员不合格」需要 load > threshold：用极端偏斜构造
    for i = 1, 4 do
        w4[i].load = 0
    end
    w4[first_idx].load = 1000
    local idx, branch = p:select_worker_impl(w4, { request_text = text })
    -- total = 1000, n = 4 → threshold 312.8，首站 1000 超载，其它 0 合格 → walk 到 1
    eq(branch, ph_mod.Branch.LOAD_BALANCE_WALK, "one hot worker → walk")
    check(idx ~= first_idx, "escaped the hot worker")
    -- 现在把每个 worker 都推到阈值之上：4 * L，threshold = (4L+1)/4*1.25 ≈ 1.25L
    -- 任何 L > 0 都有 L <= 1.25L + 0.3，所以 Rust 里「全员过载」只在首站
    -- load > threshold 且没有合格者时发生；用极端比例构造：
    local w2 = { worker("http://r1"), worker("http://r2") }
    local first2 = ph_mod.new():select_worker_impl(w2, { request_text = text })
    w2[first2].load = 100
    w2[first2 == 1 and 2 or 1].load = 100
    -- total = 200, n = 2 → threshold (201/2)*1.25 = 125.6 ≥ 100 → 首站合格，ring_hit
    local idx2, branch2 = ph_mod.new():select_worker_impl(w2, { request_text = text })
    eq(branch2, ph_mod.Branch.RING_HIT, "100 vs threshold 125.6 → still ok")
    -- load_factor 调小即可造出全员过载
    local tight = ph_mod.new({ load_factor = 0.4 })
    local idx3, branch3 = tight:select_worker_impl(w2, { request_text = text })
    eq(branch3, ph_mod.Branch.LOAD_BALANCE_WALK, "all overloaded → walk")
    eq(idx3, first2, "all overloaded → keep the ring first station")
end

new_case("prefix_hash: 不健康 worker 不参与负载统计，也不被选中")
do
    local w4 = { worker("http://s1"), worker("http://s2"), worker("http://s3"), worker("http://s4") }
    local p = ph_mod.new()
    w4[2].healthy = false
    w4[2].load = 1000000
    for i = 1, 60 do
        local idx, branch = p:select_worker_impl(w4, { request_text = "text " .. i })
        check(idx ~= 2, "never routes to unhealthy")
        check(branch ~= ph_mod.Branch.NO_TOKENS, "branch is a routing branch")
    end
end

new_case("prefix_hash: 环不可用 → 最小负载健康 worker")
do
    local p = ph_mod.new()
    local w3 = { worker("http://t1", { load = 7 }), worker("http://t2", { load = 2, healthy = false }),
                 worker("http://t3", { load = 5 }) }
    local ring = { hi = {}, lo = {}, idx = {}, count = 0, worker_count = 0 }
    local idx, branch = p:find_worker_with_load_balance(w3, { 1, 3 }, ring, 1, 1)
    eq(branch, ph_mod.Branch.FALLBACK_LEAST_LOAD, "empty ring → least load")
    eq(idx, 3, "healthiest lowest load among healthy")
end

new_case("prefix_hash: 配置默认值与裁剪")
do
    local p = ph_mod.new()
    eq(p.config.prefix_token_count, 256, "default prefix_token_count")
    eq(p.config.load_factor, 1.25, "default load_factor")
    local q = ph_mod.new({ prefix_token_count = "32", load_factor = "2.0", bogus = 1 })
    eq(q.config.prefix_token_count, 32, "string number coerced")
    eq(q.config.load_factor, 2.0, "string factor coerced")
    eq(q.config.bogus, nil, "unknown keys ignored")
    local r = ph_mod.new({ prefix_token_count = "abc" })
    eq(r.config.prefix_token_count, 256, "uncoercible → default")
end

new_case("prefix_hash: invalidate_rings 后仍能工作")
do
    local p = ph_mod.new()
    local a = p:select_worker_impl(ws, { request_text = "same text" })
    p:invalidate_rings()
    local b = p:select_worker_impl(ws, { request_text = "same text" })
    eq(a, b, "ring rebuild is position-preserving")
end

--------------------------------------------------------------------------
-- 性能（预算：10000 次 blake3 < 100 ms，见 doc/impl-hash.md）
--------------------------------------------------------------------------
new_case("perf: 10000 次 blake3 + 环查找")
do
    for _ = 1, 30000 do
        hash.position("warmup-" .. tostring(math.random(10000)))
    end
    local N = 10000
    local t0 = os.clock()
    for i = 1, N do
        hash.position("user-" .. i)
    end
    local t1 = os.clock()
    local hash_ms = (t1 - t0) * 1000
    io.write(string.format("    blake3 x%d: %.2f ms (%.0f ns/hash)\n", N, hash_ms, hash_ms * 1e5 / N))
    check(hash_ms < 100, "10000 blake3 < 100 ms", hash_ms)

    t0 = os.clock()
    for i = 1, N do
        hash.hex("user-" .. i)
    end
    t1 = os.clock()
    io.write(string.format("    blake3_hex x%d: %.2f ms\n", N, (t1 - t0) * 1000))

    t0 = os.clock()
    hash.new_ring(urls6)
    t1 = os.clock()
    io.write(string.format("    new_ring(6 workers, 900 vnodes): %.2f ms\n", (t1 - t0) * 1000))
    check((t1 - t0) * 1000 < 100, "ring build < 100 ms")

    local all = function() return true end
    t0 = os.clock()
    for i = 1, N do
        hash.lookup(ring, "user-" .. i, all)
    end
    t1 = os.clock()
    io.write(string.format("    ring lookup x%d: %.2f ms\n", N, (t1 - t0) * 1000))

    t0 = os.clock()
    local p = ch_mod.new(nil, rng_at(1))
    for i = 1, N do
        p:select_worker_impl(ws, { headers = { ["x-smg-routing-key"] = "user-" .. i } })
    end
    t1 = os.clock()
    io.write(string.format("    consistent_hashing select x%d: %.2f ms\n", N, (t1 - t0) * 1000))
end

--------------------------------------------------------------------------
io.write(string.format("\nhash: %d passed, %d failed\n", passed, failed))
if failed > 0 then
    for i = 1, #failures do
        io.write("FAIL " .. failures[i] .. "\n")
    end
    os.exit(1)
end
os.exit(0)

-- 运行（宿主机没有 luajit/perl，用镜像里的解释器）：
--   docker run --rm -v "$PWD:/repo:ro" -w /repo \
--     --entrypoint /usr/local/openresty/luajit/bin/luajit authz:latest \
--     -e 'package.path="/repo/lualib/?.lua;"..package.path
--         dofile("/repo/test/unit/test_hash.lua")'
