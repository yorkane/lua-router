-- Mesh / HA state synchronization (smg-mesh 的最小 OpenResty 等价实现)。
--
-- 参考实现：
--   * gateway/src/routers/mesh/handlers.rs   /ha/* 的对外语义与错误体
--   * gateway/src/server.rs:1393-1404        路由表（12 条）
--   * smg-mesh-1.0.0/src/crdt.rs             LWWRegister / CRDTMap / PNCounter
--   * smg-mesh-1.0.0/src/stores.rs           五个 store 的字段名
--   * smg-mesh-1.0.0/src/partition.rs        分区检测 + should_serve
--   * smg-mesh-1.0.0/src/rate_limit_window.rs 限流窗口重置
--
-- 本模块刻意分成两层，方便在没有 nginx 的环境里做纯 Lua 单测：
--   1. 纯逻辑层（LWW map、PN counter、版本向量、成员表、分区、限流窗口、
--      协议编解码、handler 函数）—— 只依赖 cjson.safe 和注入的 now()；
--   2. cosocket 层（http_request / sync_tick / start 定时器）—— 只在真实
--      OpenResty 里跑，单测用注入的假 http 函数覆盖。
--
-- 设计上的两个硬约束：
--   * 状态表存在进程内存里（每个 nginx worker 一份），写入方是 router 的
--     接线代码（observe_* 系列），读取方是 /ha/* handler。这与 Rust 一致：
--     /ha/workers 返回的是 mesh store 的内容而不是本地 registry。
--   * 未启用（SMG_MESH_PEERS 为空）时所有 /ha/* 返回与现有契约测试逐字节
--     相同的 {"error":"mesh not enabled"}，接线前后行为不倒退。

local cjson = require "cjson.safe"

local _M = { _VERSION = "0.1.0" }

---协议版本：字段不兼容时 +1，接收方对不上的包直接 400。
_M.PROTOCOL = 1

-- NodeStatus 在 gossip.proto 里是 INIT/ALIVE/SUSPECTED/DOWN/LEAVING；这里用
-- 小写字符串，/ha/status 的 nodes[].status 直接透出，避免再引一张映射表。
_M.STATUS_INIT = "init"
_M.STATUS_ALIVE = "alive"
_M.STATUS_SUSPECT = "suspect"
_M.STATUS_DOWN = "down"
_M.STATUS_LEAVING = "leaving"

---Rust GLOBAL_RATE_LIMIT_KEY / GLOBAL_RATE_LIMIT_COUNTER_KEY。
_M.GLOBAL_RATE_LIMIT_KEY = "global_rate_limit"
_M.GLOBAL_RATE_LIMIT_COUNTER_KEY = "global"

local has_ngx = (type(ngx) == "table")

local json_encode = cjson.encode
local json_decode = cjson.decode

-- ------------------------------------------------------------------ 时钟

local function now_wall()
    if has_ngx and type(ngx.now) == "function" then
        return ngx.now()
    end
    return os.time()
end

_M.now_wall = now_wall

---微秒时间戳。LWW 比较用的是整数，浮点秒在跨节点时容易撞上同一值。
local function micros(now_fn)
    return math.floor((now_fn or now_wall)() * 1000000 + 0.5)
end

-- ------------------------------------------------------------------ base64

-- 纯 Lua 实现：ngx.encode_base64 在 resty/luajit 单测里不存在，而树快照这个
-- blob 必须能在两层都一样地编解码，所以不依赖 ngx。
local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_REVERSE = {}
for i = 1, 64 do
    B64_REVERSE[string.sub(B64_ALPHABET, i, i)] = i - 1
end
B64_REVERSE["="] = 0

---base64（纯 Lua，3 字节一组做整数运算，不依赖 ngx.encode_base64）。
function _M.b64_encode(text)
    if text == nil then
        return nil
    end
    local out = {}
    local n = #text
    local pos = 1
    while pos + 2 <= n do
        local b1, b2, b3 = string.byte(text, pos, pos + 2)
        local chunk = b1 * 65536 + b2 * 256 + b3
        out[#out + 1] = string.char(
            B64_ALPHABET:byte(math.floor(chunk / 262144) + 1),
            B64_ALPHABET:byte(math.floor(chunk / 4096) % 64 + 1),
            B64_ALPHABET:byte(math.floor(chunk / 64) % 64 + 1),
            B64_ALPHABET:byte(chunk % 64 + 1))
        pos = pos + 3
    end
    local rest = n - pos + 1
    if rest == 1 then
        local b1 = string.byte(text, pos)
        out[#out + 1] = string.char(
            B64_ALPHABET:byte(math.floor(b1 / 4) + 1),
            B64_ALPHABET:byte((b1 % 4) * 16 + 1),
            string.byte("="), string.byte("="))
    elseif rest == 2 then
        -- 16 位不够切出第三个 6 位组，直接按位移取，别拿合并后的整除值。
        local b1, b2 = string.byte(text, pos, pos + 1)
        out[#out + 1] = string.char(
            B64_ALPHABET:byte(math.floor(b1 / 4) + 1),
            B64_ALPHABET:byte((b1 % 4) * 16 + math.floor(b2 / 16) + 1),
            B64_ALPHABET:byte((b2 % 16) * 4 + 1),
            string.byte("="))
    end
    return table.concat(out)
end

function _M.b64_decode(text)
    if text == nil then
        return nil
    end
    local clean = string.gsub(text, "%s", "")
    if #clean % 4 ~= 0 then
        return nil, "invalid base64 length"
    end
    local out = {}
    for pos = 1, #clean, 4 do
        local c1 = string.sub(clean, pos, pos)
        local c2 = string.sub(clean, pos + 1, pos + 1)
        local c3 = string.sub(clean, pos + 2, pos + 2)
        local c4 = string.sub(clean, pos + 3, pos + 3)
        local v1, v2 = B64_REVERSE[c1], B64_REVERSE[c2]
        if not v1 or not v2 then
            return nil, "invalid base64 character"
        end
        out[#out + 1] = string.char(v1 * 4 + math.floor(v2 / 16))
        if c3 ~= "=" then
            local v3 = B64_REVERSE[c3]
            if not v3 then
                return nil, "invalid base64 character"
            end
            out[#out + 1] = string.char((v2 % 16) * 16 + math.floor(v3 / 4))
            if c4 ~= "=" then
                local v4 = B64_REVERSE[c4]
                if not v4 then
                    return nil, "invalid base64 character"
                end
                out[#out + 1] = string.char((v3 % 4) * 64 + v4)
            end
        elseif c4 ~= "=" then
            return nil, "invalid base64 padding"
        end
    end
    return table.concat(out)
end

---与 Rust handlers.rs 的 hex 编码约定一致（/ha/config/{key} 的 value 字段）。
function _M.hex_encode(text)
    if text == nil then
        return nil
    end
    return (string.gsub(text, ".", function(c)
        return string.format("%02x", string.byte(c))
    end))
end

function _M.hex_decode(hex)
    if type(hex) ~= "string" then
        return nil, "hex value must be a string"
    end
    if #hex % 2 ~= 0 then
        return nil, "Hex string must have even length"
    end
    local out = {}
    for pos = 1, #hex, 2 do
        local byte_hex = string.sub(hex, pos, pos + 1)
        local value = tonumber(byte_hex, 16)
        if not value then
            return nil, "Invalid hex encoding"
        end
        out[#out + 1] = string.char(value)
    end
    return table.concat(out)
end

-- ------------------------------------------------------------------ LWW 冲突策略
--
-- Rust LWWRegister::merge 只看 (timestamp, version)，同 timestamp 同 version 时
-- 谁都不换 —— 两个节点会永久分歧。这里补上 node id 作为最终决胜，两边算出来的
-- 胜者必然相同（任务书要求的 "version + node id tiebreak"）。

---a 是否胜出 b。返回 true 表示 a 应覆盖 b。
function _M.lww_wins(a, b)
    if not b then
        return true
    end
    if (a.ts or 0) ~= (b.ts or 0) then
        return (a.ts or 0) > (b.ts or 0)
    end
    if (a.version or 0) ~= (b.version or 0) then
        return (a.version or 0) > (b.version or 0)
    end
    -- 平手时按节点名字典序，保证所有节点收敛到同一个值。同名条目（自己重写自己
    -- 的镜像）不算胜出。
    return tostring(a.node or "") > tostring(b.node or "")
end

---版本向量：a 是否包含 b 的全部写入且更多。
local function vec_dominates(a, b)
    if not a or not b then
        return false
    end
    local sum_a, sum_b = 0, 0
    for node, version in pairs(b) do
        if (a[node] or 0) < version then
            return false
        end
    end
    for _, version in pairs(a) do
        sum_a = sum_a + version
    end
    for _, version in pairs(b) do
        sum_b = sum_b + version
    end
    return sum_a > sum_b
end

_M.vec_dominates = vec_dominates

---带版本向量的比较（cache_aware 树快照这类 opaque blob）。
---因果关系明确时按因果，并发时退回 LWW。
function _M.blob_wins(a, b)
    if not b then
        return true
    end
    if vec_dominates(a.vec, b.vec) then
        return true
    end
    if vec_dominates(b.vec, a.vec) then
        return false
    end
    return _M.lww_wins(a, b)
end

---本地写入时给 vec 打上自己的版本，其它节点的历史观测保留。
local function vec_bump(vec, node, version)
    local out = {}
    for k, v in pairs(vec or {}) do
        out[k] = v
    end
    out[node] = version
    return out
end

-- ------------------------------------------------------------------ PN counter
--
-- 与 crdt.rs CRDTPNCounter 同构：每个 actor 各自的增/减计数，合并取 per-actor
-- max（不可重复计数），值 = sum(pos) - sum(neg)。

function _M.counter_inc(counter, node, delta)
    if delta > 0 then
        counter.pos[node] = (counter.pos[node] or 0) + delta
    elseif delta < 0 then
        counter.neg[node] = (counter.neg[node] or 0) - delta
    end
end

function _M.counter_value(counter)
    local total = 0
    for _, v in pairs(counter.pos) do
        total = total + v
    end
    for _, v in pairs(counter.neg) do
        total = total - v
    end
    return total
end

---per-actor max 合并：CRDT 的交换律/幂等性由此保证。
function _M.counter_merge(dst, src)
    for node, v in pairs(src.pos) do
        if (dst.pos[node] or 0) < v then
            dst.pos[node] = v
        end
    end
    for node, v in pairs(src.neg) do
        if (dst.neg[node] or 0) < v then
            dst.neg[node] = v
        end
    end
end

---限流计数器按窗口分桶：windows[id] = {pos={}, neg={}}。
function _M.entry_bucket(entry, id)
    local bucket = entry.windows[id]
    if not bucket then
        bucket = { pos = {}, neg = {} }
        entry.windows[id] = bucket
    end
    return bucket
end

-- ------------------------------------------------------------------ 成员表
--
-- Rust 靠 gossip 协议（ping / broadcast_node_states）动态发现节点；本实现是
-- 静态配置的全对等列表：SMG_MESH_PEERS 决定初始成员，本实例从 SMG_MESH_SELF
-- 知道自己的名字与地址。之后每个同步轮次交换完整成员表，于是「配置里只写了
-- 部分对等端」也能收敛到同一视图（transitive membership）。

---逗号或空白分隔的地址列表 -> 规范化的 base url（去掉尾部 /）。
function _M.parse_peers(text)
    if type(text) ~= "string" then
        return {}
    end
    local out, seen = {}, {}
    for item in string.gmatch(text, "[^,%s]+") do
        local base = string.gsub(item, "/+$", "")
        if base ~= "" and not seen[base] then
            seen[base] = true
            out[#out + 1] = base
        end
    end
    return out
end

---规范化的 host:port：小写主机、IPv6 补全、去前导零、默认端口显式化。
-- 「同一个地址的两种写法」必须落到同一个字符串上，否则 hostport 相等判定会漏
-- （幻影键的成因之一）。不认识的写法原样返回，调用方按字符串比较仍然自洽。
function _M.canonical_hostport(authority)
    if not authority or authority == "" then
        return nil
    end
    local text = string.gsub(authority, "/+$", "")
    local host, port
    if string.sub(text, 1, 1) == "[" then
        host = string.match(text, "^%[([^%]]*)%]")
        port = string.match(text, "^%[[^%]]*%]:(%d+)$")
        if not host then
            return string.lower(text)
        end
        host = _M.expand_ipv6(host)
    else
        host, port = string.match(text, "^([^:]*):(%d+)$")
        if not host then
            host, port = text, nil
        end
        host = string.lower(host)
    end
    if port then
        local number = tonumber(port)
        if not number then
            return string.lower(text)
        end
        port = tostring(number)
    end
    if host == "" then
        host = "127.0.0.1"
    end
    if not port then
        return host
    end
    return host .. ":" .. port
end

---把 IPv6 地址补全成 8 组小写四位十六进制。
-- 无法解析（非法字符、组数不对、两个 "::"）时原样小写返回：宁可退化成文本比较，
-- 也不要把一个看不懂的地址错认成另一个节点。
function _M.expand_ipv6(raw)
    local h = string.lower(string.gsub(raw or "", "^%[(.-)%]$", "%1"))
    if h == "" then
        return "::"
    end
    if string.find(h, "[^0-9a-f:]", 1) then
        return h
    end
    local function words(text)
        local out = {}
        for seg in string.gmatch(text, "[^:]+") do
            out[#out + 1] = tonumber(seg, 16)
        end
        return out
    end
    local groups
    local head, tail = string.match(h, "^(.-)::(.*)$")
    if head ~= nil then
        if string.find(tail, "::", 1, true) then
            return h
        end
        local left, right = words(head), words(tail)
        local missing = 8 - #left - #right
        if missing < 1 then
            return h
        end
        groups = left
        for _ = 1, missing do
            groups[#groups + 1] = 0
        end
        for i = 1, #right do
            groups[#groups + 1] = right[i]
        end
    else
        groups = words(h)
        if #groups ~= 8 then
            return h
        end
    end
    for i = 1, #groups do
        local word = groups[i]
        if not word then
            return h
        end
        groups[i] = string.format("%04x", word)
    end
    return table.concat(groups, ":")
end

---从 http://host:port 取 host:port 作为默认节点名（对齐 Rust 用 addr 的习惯）。
-- 同时是「同一个地址的不同写法」的规范式：小写主机名、IPv6 补全，所以 hostport
-- 相等可以安全地当作「同一个监听点」判定。
function _M.hostport_from_url(url)
    local authority = string.match(url or "", "^[^:]+://([^/]+)")
    if not authority then
        -- 没写 scheme 时按裸 host:port 处理
        authority = string.match(url or "", "^([^/]+)")
    end
    if not authority then
        return nil
    end
    return _M.canonical_hostport(authority)
end

local function peer_id_from_base(base)
    -- 名字优先：成员表按 name 键，同名冲突时后写者按 LWW 胜出。
    return _M.hostport_from_url(base) or base
end

_M.peer_id_from_base = peer_id_from_base

---新建一张 mesh 状态。opts：
---  self_name, self_addr, peers(list), now(fn), http(fn), interval_s,
---  unreachable_s, quorum, min_cluster_size, rpc_timeout_ms, snapshot_max_bytes
---地址是否指向本实例（写法可能与 SMG_MESH_SELF 不同，所以按 hostport 比）。
local function is_self_address(self_addr, self_hp, address)
    if not address or address == "" then
        return false
    end
    if address == self_addr then
        return true
    end
    return self_hp ~= nil and _M.hostport_from_url(address) == self_hp
end

---登记「这个地址属于这个成员键」。
--
-- 幻影键的根因：成员表先按 hostport(种子 url) 记账，对端在快照里自报的却是
-- SMG_MESH_SELF（写法可以完全不同：种子写 docker bridge / pod IP，SELF 写
-- loopback 或别的网卡名）。只用自报地址回找旧键永远对不上，那个 init 键就留在
-- 表里 —— node_count 虚高，超过 unreachable_s 之后被永久判不可达，/ha/health
-- 卡在 degraded。别名表把「我们用来发起同步的地址」「成员表里存过的地址」和
-- 「对端自报的地址」都指回同一个键，于是身份迁移找得到目标，而且迁移后不再复发
-- （members_with_seeds 靠它判断种子已经在表里，不会再补一份）。
function _M:note_address_key(key, address)
    if not key or not address or address == "" then
        return false
    end
    local hp = _M.hostport_from_url(address)
    if not hp then
        return false
    end
    self.addr_keys[hp] = key
    return true
end

local mt = { __index = _M }

---@return table mesh
function _M.new(opts)
    opts = opts or {}
    local now_fn = opts.now or now_wall
    local self_addr = opts.self_addr
    local self_name = opts.self_name or (self_addr and _M.hostport_from_url(self_addr))
        or "node-" .. tostring(micros(now_fn))
    local mesh = {
        protocol = _M.PROTOCOL,
        self_name = self_name,
        self_addr = self_addr,
        self_hp = self_addr and _M.hostport_from_url(self_addr) or nil,
        config = {
            interval_s = opts.interval_s or 2,
            unreachable_s = opts.unreachable_s or 30,
            min_cluster_size = opts.min_cluster_size or 3,
            -- 默认取「配置里的成员数 + 自己」的多数派；只写了自己一个时 quorum=1，
            -- 这样单实例不会自己把自己判成分区。
            quorum = opts.quorum,
            rpc_timeout_ms = opts.rpc_timeout_ms or 2000,
            snapshot_max_bytes = opts.snapshot_max_bytes or (3 * 1024 * 1024),
            -- 连续同步失败多少次后把 alive 降级成 suspect（一次抖动不判死）。
            suspect_threshold = opts.suspect_threshold or 2,
            -- 全局限流窗口宽度（Rust 的 RateLimitWindow.window_seconds）。
            rate_window_s = opts.rate_window_s or 1,
        },
        now = now_fn,
        http = opts.http,
        -- 配置里的固定种子（永不因收敛而丢弃）
        seed_peers = _M.parse_peers(opts.peers and table.concat(opts.peers, ",")
            or opts.peers_text or ""),
        last_sync_ms = {},
        -- 地址（规范 hostport）-> 成员键。身份统一靠它，见 note_address_key。
        addr_keys = {},
        -- 成员键 -> 最近一次同步成功的地址。对端自报的地址未必从本机可达
        -- （它可能报的是自己的 loopback），所以发起同步时优先用「验证过的地址」。
        used_addr = {},
        -- 首次把某个名字写进成员表的时刻：从未同步成功的种子也要在
        -- unreachable_s 之后被判不可达（Rust 把未见过的节点算作可达，这里给一个
        -- 同样的宽限期而不是永久豁免）。
        first_seen = {},
        draining = false,
        started = false,
        -- 同步失败计数（key = node name）与本地写入计数（协议的 seq 字段）
        sync_fail = {},
        local_version = 0,
        stats = {
            applied = 0, tree_skipped = 0, sync_rounds = 0, sync_failures = 0,
            broadcasts = 0,
        },
        store = {
            -- 成员表：key = node name
            members = {},
            -- worker / policy / app / tree / manual：key -> {value, ts, version, node}
            workers = {},
            policies = {},
            apps = {},
            trees = {},
            manual = {},
            -- 限流：key -> { window_s, current = <id>, windows = { [id] = counter } }
            rate = {},
        },
    }
    if not mesh.config.quorum then
        local expected = #mesh.seed_peers + 1
        mesh.config.quorum = math.floor(expected / 2) + 1
    end
    setmetatable(mesh, mt)

    -- 本实例先写进成员表（Rust 也把自己 insert 进 membership store）。
    mesh:put_member({
        name = self_name,
        address = self_addr or "",
        status = _M.STATUS_ALIVE,
        version = 1,
    }, self_name)
    local self_hp = self_addr and _M.hostport_from_url(self_addr) or nil
    for i = 1, #mesh.seed_peers do
        local base = mesh.seed_peers[i]
        local id = peer_id_from_base(base)
        if id ~= self_name and not is_self_address(self_addr, self_hp, base) then
            mesh:put_member({
                name = id,
                address = base,
                -- 种子还没被同步证明过，先标 init：不满足 unreachable 判定，
                -- 也不至于让 /ha/health 一上线就报 degraded。
                status = _M.STATUS_INIT,
                version = 1,
            }, self_name)
        end
    end
    return mesh
end

-- ------------------------------------------------------------------ 通用写入

---LWW 写入一条记录。node 缺省为本实例。
---@return boolean written
function _M.put(store, key, value, node, ts, version, vec, force)
    local prev = store[key]
    local entry = {
        value = value,
        ts = ts,
        version = version,
        node = node,
        vec = vec,
    }
    if not prev then
        store[key] = entry
        return true
    end
    if not force and not _M.lww_wins(entry, prev) then
        return false
    end
    store[key] = entry
    return true
end

---blob 写入（版本向量比较优先，LWW 兜底）。
function _M.put_blob(store, key, value, node, ts, version, vec)
    local prev = store[key]
    local entry = {
        value = value, ts = ts, version = version, node = node, vec = vec,
    }
    if prev and not _M.blob_wins(entry, prev) then
        return false
    end
    store[key] = entry
    return true
end

-- ------------------------------------------------------------------ 成员表操作

---成员写入。status 的降级不由这里决定（见 mark_sync_failure / mark_sync_success），
---这里只做带元数据的 LWW 落表。
function _M:put_member(member, node, ts, version)
    local store = self.store.members
    local key = member.name
    local prev = store[key]
    -- 每次成员写入都刷新地址别名：地址可能是新学的（pod IP、对端自报），别名必须
    -- 跟着走，否则下一次身份迁移又找不到键。
    self:note_address_key(key, member.address)
    if not prev then
        self.first_seen[key] = ts or micros(self.now)
    end
    local entry = {
        value = member,
        ts = ts or micros(self.now),
        version = version or (member.version or ((prev and prev.version or 0) + 1)),
        node = node or self.self_name,
    }
    if prev and not _M.lww_wins(entry, prev) then
        return false
    end
    store[key] = entry
    return true
end

---成员快照（wire 格式：value + 元数据一起走）。
function _M:members_snapshot()
    local out = {}
    for key, entry in pairs(self.store.members) do
        out[#out + 1] = {
            key = key,
            value = entry.value,
            ts = entry.ts,
            version = entry.version,
            node = entry.node,
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

---把 seed 地址补进成员快照（Rust 的 init_peer 语义：种子必须出现在视图里，
---即使从没见过它）。未见过时保持 init，见过则带上当前状态。
function _M:members_with_seeds()
    local snapshot = self:members_snapshot()
    local by_key = {}
    for i = 1, #snapshot do
        by_key[snapshot[i].key] = true
    end
    for i = 1, #self.seed_peers do
        local base = self.seed_peers[i]
        local id = peer_id_from_base(base)
        -- 种子已经以别的名字（节点自报名）在表里时不能再补一份，否则身份分裂。
        local known = by_key[id]
            or (id ~= self.self_name and self:member_key_for_address(base, id))
        if id ~= self.self_name and not known
            and not is_self_address(self.self_addr, self.self_hp, base) then
            snapshot[#snapshot + 1] = {
                key = id,
                value = { name = id, address = base,
                          status = _M.STATUS_INIT, version = 1 },
                ts = micros(self.now),
                version = 1,
                node = self.self_name,
            }
            by_key[id] = true
        end
    end
    table.sort(snapshot, function(a, b) return a.key < b.key end)
    return snapshot
end

---某个成员键的候选地址，按优先级：最近验证过的写法、成员表里的地址、配置种子。
-- 对端自报的地址未必从本机可达（它可能报自己的 loopback 或另一个网卡），所以
-- 「能连通的那个写法」优先；全部失败时才退回其它写法。
function _M:peer_candidates(key)
    local out, seen = {}, {}
    local function add(address)
        if not address or address == "" then
            return
        end
        if is_self_address(self.self_addr, self.self_hp, address) then
            return
        end
        local hp = _M.hostport_from_url(address)
        if not hp or seen[hp] then
            return
        end
        seen[hp] = true
        out[#out + 1] = address
    end
    add(self.used_addr[key])
    local entry = self.store.members[key]
    if entry and entry.value then
        add(entry.value.address)
    end
    for i = 1, #self.seed_peers do
        if self.addr_keys[_M.hostport_from_url(self.seed_peers[i]) or ""] == key then
            add(self.seed_peers[i])
        end
    end
    return out
end

---已知对等端（排除自己），返回 base url 列表。优先用成员表里的 address，
-- 这样从别的节点学来的地址也能被同步；成员表没有的种子也带上。
--
-- 去重按「成员键」而不是地址字符串：同一个节点的两种写法（种子 hostport 与
-- 对端自报）只能占一个同步目标，否则每轮对同一节点发两次请求，失败时还会把
-- 另一个写法降级成 suspect，让健康集群看起来像分区。
function _M:peer_bases()
    local out, seen_target = {}, {}
    local names = {}
    for name in pairs(self.store.members) do
        if name ~= self.self_name then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    for i = 1, #names do
        local candidates = self:peer_candidates(names[i])
        local base = candidates[1]
        if base then
            local hp = _M.hostport_from_url(base)
            if not seen_target[hp] then
                seen_target[hp] = true
                out[#out + 1] = base
            end
        end
    end
    -- 从没进过成员表的种子（写法与自报身份对不上时会被 new() 跳过）仍然要带上，
    -- 否则一个还没起来的对等端会彻底消失，而不是停在 init 等超时。
    for i = 1, #self.seed_peers do
        local base = self.seed_peers[i]
        local hp = _M.hostport_from_url(base)
        if hp and not seen_target[hp] and self.addr_keys[hp] == nil
            and not is_self_address(self.self_addr, self.self_hp, base) then
            seen_target[hp] = true
            out[#out + 1] = base
        end
    end
    table.sort(out)
    return out
end

---按地址定位成员键：种子以 hostport(url) 记账，而对端可能用别的名字自报
--（SMG_MESH_SELF_NAME 与 hostport 不同时就会出现同一节点的两个键）。
---@param address string
---@param except string|nil @ 要排除的键（通常是节点自报的名字）
function _M:member_key_for_address(address, except)
    if not address or address == "" then
        return nil
    end
    local target = _M.hostport_from_url(address)
    if not target then
        return nil
    end
    -- 别名索引优先：它是「这个地址曾经被记在哪个键下」的唯一权威，成员表里的
    -- address 只是最近一次写入的值，可能已经被对端换成另一个网卡。
    local aliased = self.addr_keys[target]
    if aliased and aliased ~= except and self.store.members[aliased] then
        return aliased
    end
    for key, entry in pairs(self.store.members) do
        local stored = entry.value.address
        if key ~= except and stored and stored ~= "" then
            if stored == address or _M.hostport_from_url(stored) == target then
                return key
            end
        end
    end
    return nil
end

---把 from 键上的记账（观测时间、失败计数、首见时间）迁到 to 键，并删掉 from。
function _M:migrate_member(from, to)
    if not from or from == to then
        return false
    end
    local src = self.store.members[from]
    if not src then
        return false
    end
    -- 别名跟着改，并且把 from 键下的「验证过的地址」交给 to：迁移完成后同步仍然
    -- 要能发起，那个能连通的写法就是 used_addr。
    for hp, key in pairs(self.addr_keys) do
        if key == from then
            self.addr_keys[hp] = to
        end
    end
    if self.used_addr[from] and not self.used_addr[to] then
        self.used_addr[to] = self.used_addr[from]
    end
    self.used_addr[from] = nil
    local dst = self.store.members[to]
    if not dst then
        self.store.members[to] = src
        src.value.name = to
    elseif _M.lww_wins(src, dst) then
        self.store.members[to] = src
        src.value.name = to
    end
    self.store.members[from] = nil
    self.last_sync_ms[to] = self.last_sync_ms[to] or self.last_sync_ms[from]
    self.last_sync_ms[from] = nil
    self.first_seen[to] = math.min(self.first_seen[to] or math.huge,
        self.first_seen[from] or math.huge)
    self.first_seen[from] = nil
    if self.sync_fail[to] == nil then
        self.sync_fail[to] = self.sync_fail[from]
    end
    self.sync_fail[from] = nil
    return true
end

---同步记账用的键：优先复用地址已知的成员键，否则用 hostport(url)。
function _M:resolve_peer_name(base)
    local known = self:member_key_for_address(base, nil)
    if known then
        return known
    end
    return peer_id_from_base(base)
end

---把「我们实际用来发起同步的地址」与「对端自报的身份」认成同一个节点。
--
-- 这是幻影键的真修点。sync 的往返里只有 sync_with 同时知道两件事：我们拨的是
-- 哪个 url、对方报的是哪个名字。apply_snapshot 只能看到自报地址，而自报地址
-- （SMG_MESH_SELF，常写成 loopback）与种子写法（bridge IP / pod IP）对不上时，
-- 原先的迁移逻辑就找不到那个 init 键，幻影永久留下。
---@return string|nil key @ 统一后的成员键
function _M:unify_identity(used_base, declared_name)
    if not used_base or used_base == "" then
        return nil
    end
    -- 先登记拨号地址：即使成员表里还没有这个键，别名也要先建起来，后面的查找
    -- 才不会各找各的。
    local by_used = self:member_key_for_address(used_base, nil)
    if not declared_name or declared_name == "" or declared_name == self.self_name then
        return by_used
    end
    self:note_address_key(declared_name, used_base)
    if not by_used then
        return declared_name
    end
    if by_used == declared_name then
        return declared_name
    end
    -- 两个键指向同一个节点：以自报名为准合并（apply_snapshot 已经采纳了它自报的
    -- status/version），把种子键上的观测时间/失败计数搬过去再删掉。
    self:migrate_member(by_used, declared_name)
    return declared_name
end

---当前可达（alive + suspect 未超时）的成员名。
function _M:reachable_members()
    local out = {}
    local now_ms = micros(self.now)
    for name, entry in pairs(self.store.members) do
        local member = entry.value
        local seen = self.last_sync_ms[name] or self.first_seen[name]
        if member.status == _M.STATUS_ALIVE and seen
            and (now_ms - seen) / 1e6 < self.config.unreachable_s then
            out[#out + 1] = name
        elseif name == self.self_name then
            out[#out + 1] = name
        end
    end
    table.sort(out)
    return out
end

-- ------------------------------------------------------------------ 分区检测
--
-- partition.rs 用 last_seen + unreachable_timeout 判定；这里 last_seen 就是
-- last_sync_ms（一次成功同步的观测）。unreachable 计数 = 连续同步失败次数，
-- 达到 unreachable_threshold 才计为不可达，避免一次抖动就把节点判死。

---当前分区状态。返回 state, detail。
--
-- 判定基于「已知成员」（成员表里除 LEAVING 之外的全部节点）：
--   1. 已知成员数不足 min_cluster_size 时永远 normal —— 两节点集群没有仲裁可言，
--      判成无 quorum 会让 mesh 自己把流量停掉（Rust 声明了这个配置项但没有用它）；
--   2. 没有过期成员 -> normal；
--   3. 可达数 >= quorum -> partitioned_with_quorum（继续服务）；
--   4. 否则 partitioned_without_quorum。
--
-- 与 partition.rs 的差别：Rust 只把 status==Alive 的节点算进 unreachable_count，
-- 于是被自己降级成 DOWN 的成员会凭空消失、集群又变回 normal。这里 down 与
-- suspect 一样算期望成员，降级之后分区判定仍然成立。
function _M:partition_state()
    local now_us = micros(self.now)
    local unreachable_s = self.config.unreachable_s
    local expected, reachable, unreachable = 0, 0, 0
    local unreachable_names = {}
    for name, entry in pairs(self.store.members) do
        local member = entry.value
        if member.status ~= _M.STATUS_LEAVING then
            expected = expected + 1
            local seen = self.last_sync_ms[name] or self.first_seen[name]
            local fresh = (name == self.self_name)
                or (seen and (now_us - seen) / 1e6 < unreachable_s)
            if fresh then
                reachable = reachable + 1
            else
                unreachable = unreachable + 1
                unreachable_names[#unreachable_names + 1] = name
            end
        end
    end
    local alive = 0
    for _, entry in pairs(self.store.members) do
        if entry.value.status == _M.STATUS_ALIVE then
            alive = alive + 1
        end
    end
    local state
    if expected < self.config.min_cluster_size or unreachable == 0 then
        state = "normal"
    elseif reachable >= self.config.quorum then
        state = "partitioned_with_quorum"
    else
        state = "partitioned_without_quorum"
    end
    table.sort(unreachable_names)
    return state, {
        alive = alive,
        expected = expected,
        reachable = reachable,
        unreachable = unreachable,
        unreachable_names = unreachable_names,
        quorum = self.config.quorum,
        min_cluster_size = self.config.min_cluster_size,
    }
end

---有 quorum 就继续服务（partition.rs should_serve）。单节点集群（成员表只有
---自己）永远有 quorum —— 否则关掉 mesh 的实例会被自己判成不可用。
function _M:should_serve()
    if self.draining then
        return false
    end
    local state = self:partition_state()
    return state == "normal" or state == "partitioned_with_quorum"
end

---同步失败计数：连续失败先把成员降级为 suspect，超过 unreachable_s 再降为 down。
---@return number fails
function _M:mark_sync_failure(name)
    local fails = (self.sync_fail[name] or 0) + 1
    self.sync_fail[name] = fails
    local entry = self.store.members[name]
    if not entry then
        return fails
    end
    local member = entry.value
    local now_us = micros(self.now)
    local seen = self.last_sync_ms[name] or self.first_seen[name]
    local stale = seen and ((now_us - seen) / 1e6 >= self.config.unreachable_s)
    local version = (entry.version or 1) + 1
    if member.status == _M.STATUS_ALIVE and fails >= self.config.suspect_threshold then
        self:put_member({
            name = name, address = member.address,
            status = stale and _M.STATUS_DOWN or _M.STATUS_SUSPECT,
            version = version,
        }, self.self_name, now_us, version)
    elseif member.status == _M.STATUS_SUSPECT and stale then
        self:put_member({
            name = name, address = member.address,
            status = _M.STATUS_DOWN, version = version,
        }, self.self_name, now_us, version)
    end
    return fails
end

---同步成功：清零失败计数并把成员抬回 alive。
---declared_status 是快照里该节点自报的状态：LEAVING 是它自己的意愿，不能被
---「它现在还回 HTTP」这件事推翻，否则 draining 的对等端会被永久洗白。
function _M:mark_sync_success(name, declared_status)
    self.sync_fail[name] = 0
    self.last_sync_ms[name] = micros(self.now)
    if declared_status == _M.STATUS_LEAVING then
        return
    end
    local entry = self.store.members[name]
    -- leaving 是该节点自己声明的终态：sync_with 在 apply_snapshot 之后还会不带
    -- declared_status 再调一次这里（历史实测 bug，git 历史可查），若不
    -- 保住这个状态，一次成功同步就把刚下线过的节点重新标成 alive，对端永远看不到
    -- shutdown。只有对方在快照里自报新状态才覆盖（merge_membership 无条件采纳）。
    if entry and entry.value.status == _M.STATUS_LEAVING then
        return
    end
    if entry and entry.value.status ~= _M.STATUS_ALIVE then
        local member = entry.value
        self:put_member({
            name = name, address = member.address,
            status = _M.STATUS_ALIVE, version = (entry.version or 1) + 1,
        }, self.self_name, nil, (entry.version or 1) + 1)
    end
end


---------------------------------------------------------------------------
-- 动态成员：由 K8s router-pod 发现写入（service_discovery.reconcile_router_members）
--
-- Rust 的对应逻辑在 gateway/src/service_discovery.rs:622 的 start_router_discovery：
-- healthy 的 router pod 直接写进 cluster state（Alive, version+1），带
-- deletionTimestamp 的写 Down，不健康的写 Suspected 且只改已有条目。这里做的是
-- 同样的三件事，外加两条本实现特有的约束：
--   * 自己不能成为自己的 peer（pod 列表里必然包含本实例那台），否则单实例会
--     跟自己同步、并在抖动时把自己降级成 suspect；
--   * 轮询每 interval 都会重放同一批 pod，所以「没有变化」必须真的不写表 ——
--     每次都 version+1 会让成员表在两个节点之间永远互相覆盖。
--
-- 与种子（SMG_MESH_PEERS）的区别：种子在 new() 里就写进成员表并计入 quorum，
-- 动态成员只进成员表。quorum 因此保持启动时的语义（限制，见
-- 详见 git 历史里的 gap-discovery-watch.md 4.2）。
---------------------------------------------------------------------------

---把（或保持）一个发现到的 router pod 记为存活成员。
---@param name string @ pod 名（成员表键，与 Rust 用 pod name 一致）
---@param address string @ http://<podIP>:<meshPort>
---@return boolean changed, string|nil reason @ "self" | "unchanged" | "invalid"
function _M:adopt_member(name, address)
    if not name or name == "" or not address or address == "" then
        return false, "invalid"
    end
    if is_self_address(self.self_addr, self.self_hp, address) then
        -- 本实例那台 pod。什么都不写：成员表里已经有自己（new() 写的），再写一次
        -- 只是把版本白白推高一格，而且同步循环会多一个自环目标。
        return false, "self"
    end
    local entry = self.store.members[name]
    if not entry then
        -- 同一个地址可能已经用别的键记过账（对端自报名 != hostport(url)），复用它
        -- 免得一个节点长出两个身份。
        local key = self:member_key_for_address(address, name)
        if key then
            entry = self.store.members[key]
            name = key
        end
    end
    local prev_status = entry and entry.value.status or nil
    if entry and entry.value.address == address
        and (prev_status == _M.STATUS_ALIVE or prev_status == _M.STATUS_SUSPECT) then
        -- 地址没变且已经是（或曾经是）活成员：不写。Gossip 自己会把状态收敛过去，
        -- 每轮都重写则会把 LWW 变成噪音源。suspect 也算不写：那是同步失败判定的
        -- 结论，不该由「K8s 说它还活着」这条独立证据推翻。
        return false, "unchanged"
    end
    local version = (entry and entry.version or 0) + 1
    local written = self:put_member({
        name = name, address = address,
        status = _M.STATUS_ALIVE, version = version,
    }, self.self_name, nil, version)
    -- 发现成功就把同步记账清干净：这pod 刚被 API server 证明存在，之前的失败
    -- 计数（可能来自还没起来的对端）不该继续累积。
    self.sync_fail[name] = 0
    self.last_sync_ms[name] = nil
    if written and not self.started then
        -- 只有先配了 SMG_MESH_PEERS=<自身> 时实例才会在这里还没启动（init.lua 建
        -- 实例要求 peers 非空，而只有自己的列表 start() 会报 "no mesh peers"）。
        -- 第一次发现到对等端就是启动同步定时器的时机。
        local ok_start, start_err = self:start()
        if not ok_start and has_ngx then
            ngx.log(ngx.WARN, "luarouter: mesh sync timer not started after adopting ",
                name, ": ", tostring(start_err))
        end
    end
    return true
end

---成员定位：先按名字，再按地址兜底。
--
-- 两个键必须都查，因为同步会把发现时用的 pod 名迁成对端自报的身份
-- （apply_snapshot 里的 migrate_member）：只按 pod 名找就会在迁移之后失明，
-- 于是「pod 已经删了」这件事永远写不进成员表。
---@param name string|nil
---@param address string|nil
---@return string|nil key, table|nil entry
function _M:find_member(name, address)
    if name and self.store.members[name] then
        return name, self.store.members[name]
    end
    if address and address ~= "" then
        local key = self:member_key_for_address(address, name)
        if key then
            return key, self.store.members[key]
        end
    end
    return nil, nil
end

---把成员判死（保留记录，只把状态写成 down）。Rust 对 deletionTimestamp 就是这个动作。
---@param name string|nil @ pod 名（发现时用的键）
---@param address string|nil @ 同一成员的地址，键被同步改写后靠它定位
---@return boolean changed
function _M:retire_member(name, address)
    local key, entry = self:find_member(name, address)
    if not entry then
        return false
    end
    name = key
    if entry.value.status == _M.STATUS_DOWN or entry.value.status == _M.STATUS_LEAVING then
        return false
    end
    local member = entry.value
    local version = (entry.version or 1) + 1
    self:put_member({
        name = name, address = member.address,
        status = _M.STATUS_DOWN, version = version,
    }, self.self_name, nil, version)
    return true
end

---把已知成员降级为 suspect（不健康但未确认死亡）。Rust 只在条目已存在且不是 down
--时才做这件事，这里保持一致：从没见过、且 K8s 说不健康的 pod 不应该凭空成为成员。
---@param name string|nil @ pod 名
---@param address string|nil @ 地址兜底（理由同 retire_member）
---@return boolean changed
function _M:suspect_member(name, address)
    local key, entry = self:find_member(name, address)
    if not entry then
        return false
    end
    name = key
    local member = entry.value
    if member.status == _M.STATUS_DOWN or member.status == _M.STATUS_LEAVING
        or member.status == _M.STATUS_SUSPECT then
        return false
    end
    local version = (entry.version or 1) + 1
    self:put_member({
        name = name, address = member.address,
        status = _M.STATUS_SUSPECT, version = version,
    }, self.self_name, nil, version)
    return true
end

-- ------------------------------------------------------------------ 本地写入
--
-- 这一组是 router 接线要调的入口（见 doc/gap-mesh.md §4）。全部带 LWW 元数据，
-- 且带 tombstone：Rust 的 CRDTMap::remove 是硬删，merge 会把远端旧值复活，
-- 这里用删除标记 + ts 推进修掉那个复活问题。

local function local_write(mesh, store, key, value, is_blob)
    local prev = store[key]
    local version = (prev and prev.version or 0) + 1
    local ts = micros(mesh.now)
    local vec
    if is_blob then
        local merged = {}
        if prev and prev.vec then
            for k, v in pairs(prev.vec) do
                merged[k] = v
            end
        end
        vec = vec_bump(merged, mesh.self_name, version)
    end
    local ok
    if is_blob then
        ok = _M.put_blob(store, key, value, mesh.self_name, ts, version, vec)
    else
        ok = _M.put(store, key, value, mesh.self_name, ts, version)
    end
    if ok then
        mesh.local_version = mesh.local_version + 1
    end
    return ok, version
end

---tombstone 写入：保留 key 但把值标记为已删除。
local function local_delete(mesh, store, key)
    local prev = store[key]
    local value = { _deleted = true }
    local version = (prev and prev.version or 0) + 1
    local ok = _M.put(store, key, value, mesh.self_name, micros(mesh.now), version)
    if ok then
        mesh.local_version = mesh.local_version + 1
    end
    return ok
end

local function alive(record)
    return record and not record._deleted
end

---枚举 store 里未被删除的值。
function _M.all(store)
    local out = {}
    for key, entry in pairs(store) do
        if alive(entry.value) then
            out[#out + 1] = { key = key, entry = entry, value = entry.value }
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

function _M.count_live(store)
    local n = 0
    for _, entry in pairs(store) do
        if alive(entry.value) then
            n = n + 1
        end
    end
    return n
end

---worker registry 快照。record/state 来自 registry.record + registry.cb_state，
--字段名对齐 Rust WorkerState{worker_id,model_id,url,health,load,version}。
function _M:observe_worker(worker_id, rec, state)
    return local_write(self, self.store.workers, worker_id, {
        worker_id = worker_id,
        model_id = rec.model_id or "",
        url = rec.url or "",
        health = (state and state.healthy ~= false) and true or false,
        load = (state and state.load) or 0,
    })
end

function _M:remove_worker(worker_id)
    return local_delete(self, self.store.workers, worker_id)
end

---policy 状态（含 cache_aware / bucket 的 opaque 配置快照）。
function _M:observe_policy(model_id, policy_type, config)
    local key = "policy:" .. model_id
    return local_write(self, self.store.policies, key, {
        model_id = model_id,
        policy_type = policy_type,
        config = config,
    })
end

function _M:remove_policy(model_id)
    return local_delete(self, self.store.policies, "policy:" .. model_id)
end

---cache_aware 树快照：opaque blob + 版本向量（Rust 用操作日志 tree_ops，
--这里按任务书允许先只传整棵快照）。blob 是 base64 文本，超过上限则跳过。
function _M:observe_tree(model_id, snapshot_text)
    local key = "tree:" .. model_id
    if type(snapshot_text) ~= "string" then
        return false
    end
    if #snapshot_text > self.config.snapshot_max_bytes then
        self.stats.tree_skipped = self.stats.tree_skipped + 1
        return false
    end
    return local_write(self, self.store.trees, key, {
        model_id = model_id,
        format = "cache_aware-snapshot-v1",
        blob = snapshot_text,
    }, true)
end

---manual 粘滞映射（routing key -> 候选 url 列表）。
function _M:observe_manual(routing_key, urls)
    local key = "manual:" .. routing_key
    if type(urls) ~= "table" or #urls == 0 then
        return local_delete(self, self.store.manual, key)
    end
    local copy = {}
    for i = 1, #urls do
        copy[i] = tostring(urls[i])
    end
    return local_write(self, self.store.manual, key, {
        routing_key = routing_key,
        urls = copy,
    })
end

function _M:remove_manual(routing_key)
    return local_delete(self, self.store.manual, "manual:" .. routing_key)
end

---app 配置（含全局限流配置）。value 是原始字节。
function _M:put_app(key, value)
    return local_write(self, self.store.apps, key, { key = key, value = value })
end

function _M:get_app(key)
    local entry = self.store.apps[key]
    return entry and alive(entry.value) and entry.value or nil
end

---Rust set_global_rate_limit：写进 app store 的 RateLimitConfig。
function _M:set_rate_limit_config(limit_per_second)
    local text = json_encode({ limit_per_second = limit_per_second })
    return self:put_app(_M.GLOBAL_RATE_LIMIT_KEY, text)
end

function _M:get_rate_limit_config()
    local record = self:get_app(_M.GLOBAL_RATE_LIMIT_KEY)
    if not record then
        return nil
    end
    return json_decode(record.value) or { limit_per_second = 0 }
end

-- ------------------------------------------------------------------ 限流窗口
--
-- 语义目标与 Rust 相同：全局限流计数在窗口内跨节点累加，窗口结束清零。
-- 实现差别：Rust 用「owner + 按当前值负增」重置 PNCounter（自己代码里也标注
-- 这是 workaround，且 reset 与新请求竞态）；这里给计数器带窗口 id，滚窗只是
-- 换 key，天然没有竞态，也不需要 owner 才准增。owner 仅用于 /ha/rate-limit/stats
-- 的可观测字段。

local function window_id(mesh, window_s)
    return math.floor(micros(mesh.now) / (1000000 * window_s))
end

function _M:rate_entry(key, window_s)
    window_s = window_s or self.config.rate_window_s or 1
    local entry = self.store.rate[key]
    if not entry then
        entry = { window_s = window_s, current = window_id(self, window_s), windows = {} }
        self.store.rate[key] = entry
    elseif entry.window_s ~= window_s then
        -- 配置变了：窗口宽度改动作废历史，避免新旧桶混在一起。
        entry.window_s = window_s
        entry.windows = {}
        entry.current = window_id(self, window_s)
    end
    return entry
end

---推进窗口（Rust RateLimitWindow::start_reset_task 的等价物）。
---@return boolean advanced
function _M:roll_windows()
    local advanced = false
    for _, entry in pairs(self.store.rate) do
        local id = window_id(self, entry.window_s)
        if id ~= entry.current then
            entry.current = id
            -- 只保留当前窗口与前一窗口（容忍节点间秒级时钟差）。
            local keep = { [tostring(id)] = true, [tostring(id - 1)] = true }
            for bucket in pairs(entry.windows) do
                if not keep[bucket] then
                    entry.windows[bucket] = nil
                end
            end
            advanced = true
        end
    end
    return advanced
end

---本节点为 key 记一次用量。
function _M:rate_inc(key, delta, window_s)
    window_s = window_s or self.config.rate_window_s or 1
    local entry = self:rate_entry(key, window_s)
    self:roll_windows()
    local bucket = _M.entry_bucket(entry, tostring(entry.current))
    _M.counter_inc(bucket, self.self_name, delta or 1)
    self.local_version = self.local_version + 1
    return _M.counter_value(bucket)
end

---窗口内合并后的总量（各节点累加，同节点重复同步不会重计）。
---
---只算当前窗口：把上一窗口也计进去会把限额变成 2x，比限流失灵更糟。代价是时钟
---落后不到一个窗口的节点，它的增量会落在前一个桶里、这一轮不被计入（宁可少限
---几笔，不要双限）。前一个桶仍然保留在快照里，下个窗口自然合并进来。
function _M:rate_value(key)
    local entry = self.store.rate[key]
    if not entry then
        return nil
    end
    self:roll_windows()
    local bucket = entry.windows[tostring(entry.current)]
    if not bucket then
        return 0
    end
    return _M.counter_value(bucket)
end

---key 的 owner：可达成员按名字排序后取哈希环上的第一个。仅用于可观测，
--Rust 用它决定谁能 inc，这里不需要（见上）。
function _M:rate_owner(key)
    local members = self:reachable_members()
    if #members == 0 then
        return self.self_name
    end
    local hash = 2166136261
    for i = 1, #key do
        hash = (hash + string.byte(key, i)) % 4294967296
        hash = (hash * 16777619) % 4294967296
    end
    return members[(hash % #members) + 1]
end

---Rust check_global_rate_limit：返回 exceeded, count, limit。
function _M:check_global_rate_limit()
    local config = self:get_rate_limit_config() or {}
    local limit = config.limit_per_second or 0
    if limit == 0 then
        return false, 0, 0
    end
    self:rate_inc(_M.GLOBAL_RATE_LIMIT_COUNTER_KEY, 1, self.config.rate_window_s)
    local count = self:rate_value(_M.GLOBAL_RATE_LIMIT_COUNTER_KEY) or 0
    return count > limit, count, limit
end

function _M:reset_rate_limit_counter()
    local entry = self.store.rate[_M.GLOBAL_RATE_LIMIT_COUNTER_KEY]
    if not entry then
        return false
    end
    -- 用负增归零本节点这一份，保留其它节点的观测（CRDT 允许，且无竞态）。
    local bucket = _M.entry_bucket(entry, tostring(entry.current))
    local value = _M.counter_value(bucket)
    if value <= 0 then
        return false
    end
    _M.counter_inc(bucket, self.self_name, -value)
    return true
end

-- ------------------------------------------------------------------ 快照与合并
--
-- 一轮同步交换的就是这里 encode 出来的整包。每个 store 的每条记录带上
-- (value, ts, version, node[, vec])，接收方按 LWW 逐条合并 —— 与 Rust
-- broadcast_node_states 的 StateSync + CRDTMap::merge 等价，只是把 gossip 的
-- 「随机挑 k 个邻居」换成了「全对等一轮广播」。

local function encode_entries(store)
    local out = {}
    for key, entry in pairs(store) do
        out[#out + 1] = {
            key = key,
            value = entry.value,
            ts = entry.ts,
            version = entry.version,
            node = entry.node,
            vec = entry.vec,
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

---本实例的完整状态快照。`delta_from` 是预留的对端水位参数：本实现永远发全量
--（成员数小、状态有限），字段留着让协议向后兼容增量的实现。
function _M:snapshot(delta_from)
    self:roll_windows()
    local rate = {}
    for key, entry in pairs(self.store.rate) do
        local buckets = {}
        for id, bucket in pairs(entry.windows) do
            buckets[#buckets + 1] = {
                id = id, pos = bucket.pos, neg = bucket.neg,
            }
        end
        table.sort(buckets, function(a, b) return a.id < b.id end)
        rate[#rate + 1] = {
            key = key, window_s = entry.window_s, current = entry.current,
            windows = buckets,
        }
    end
    table.sort(rate, function(a, b) return a.key < b.key end)
    return {
        protocol = _M.PROTOCOL,
        node = self.self_name,
        addr = self.self_addr or "",
        ts = micros(self.now),
        seq = self.local_version,
        since = delta_from,
        draining = self.draining and true or false,
        stores = {
            members = self:members_with_seeds(),
            workers = encode_entries(self.store.workers),
            policies = encode_entries(self.store.policies),
            apps = encode_entries(self.store.apps),
            trees = encode_entries(self.store.trees),
            manual = encode_entries(self.store.manual),
        },
        rate = rate,
    }
end

local function apply_lww(store, item)
    if item.key == nil or item.value == nil then
        return false
    end
    return _M.put(store, item.key, item.value, item.node, item.ts,
        item.version, item.vec)
end

---合并对端快照。返回 applied, err。
function _M:apply_snapshot(snap)
    if type(snap) ~= "table" then
        return 0, "mesh snapshot is not a table"
    end
    if snap.protocol ~= _M.PROTOCOL then
        return 0, "unsupported mesh protocol version"
    end
    local applied = 0
    local stores = snap.stores or {}
    local names = { "workers", "policies", "apps", "trees", "manual" }
    for i = 1, #names do
        local items = stores[names[i]]
        if type(items) == "table" then
            for j = 1, #items do
                if apply_lww(self.store[names[i]], items[j]) then
                    applied = applied + 1
                end
            end
        end
    end
    -- 成员表单独合并：status 只有该节点自己的声明（或我们的超时判定）能改，
    -- 对等端转发的第三方记录只用来补 address。
    if type(stores.members) == "table" then
        applied = applied + self:merge_membership(stores.members)
    end
    -- 限流窗口按 CRDT 合并，不看 LWW（两个节点的增量都要计）。
    if type(snap.rate) == "table" then
        for i = 1, #snap.rate do
            local remote = snap.rate[i]
            if remote.key then
                local mine = self:rate_entry(remote.key, remote.window_s or 1)
                if type(remote.windows) == "table" then
                    for j = 1, #remote.windows do
                        local bucket = remote.windows[j]
                        if bucket.id then
                            _M.counter_merge(_M.entry_bucket(mine, bucket.id), {
                                pos = bucket.pos or {}, neg = bucket.neg or {},
                            })
                        end
                    end
                end
                applied = applied + 1
            end
        end
    end
    if snap.node and snap.node ~= self.self_name then
        -- 对端自报的身份优先：若我们之前用别的写法给它记过账，把那些观测迁到
        -- 自报名下，避免成员表里同一个节点出现两个键。这里只能看到自报地址，
        -- 覆盖「对方换了网卡/端口写法」的情况；「种子写法与自报地址完全不同」
        -- 那种由 sync_with 调 unify_identity 处理（那边才知道拨的是哪个 url）。
        local items = stores.members
        if type(items) == "table" then
            for j = 1, #items do
                local declared = items[j].value
                if declared and declared.name == snap.node and declared.address
                    and declared.address ~= "" then
                    self:note_address_key(snap.node, declared.address)
                    local phantom = self:member_key_for_address(declared.address, snap.node)
                    if phantom then
                        self:migrate_member(phantom, snap.node)
                    end
                    break
                end
            end
        end
        local declared_status
        if type(items) == "table" then
            for j = 1, #items do
                local value = items[j].value
                if value and value.name == snap.node then
                    declared_status = value.status
                    break
                end
            end
        end
        self:mark_sync_success(snap.node, declared_status)
    end
    self.stats.applied = self.stats.applied + applied
    return applied
end

---只用来合并对端的成员表：地址与名字带上，状态不覆盖本地观测。
function _M:merge_membership(items)
    if type(items) ~= "table" then
        return 0
    end
    local applied = 0
    for i = 1, #items do
        local item = items[i]
        local member = item.value
        if member and member.name and member.name ~= self.self_name
            -- 别人转来的「本实例记录」不能给自己长出第二个键：它对不上我们的
            -- self_name（写法不同），但对得上我们的地址，所以是一个自节点幻影。
            -- 自己的条目只有 new() 和 ha_shutdown 写得动。
            and not is_self_address(self.self_addr, self.self_hp, member.address) then
            local self_declared = item.node == member.name
            local mine = self.store.members[member.name]
            if not self_declared then
                -- 第三方转发的记录：只补已知节点的地址，绝不新建键。名字以节点
                -- 自报为准，否则同一节点会在成员表里长出两个身份。
                local known_key = mine and member.name
                    or self:member_key_for_address(member.address, member.name)
                local known = known_key and self.store.members[known_key]
                if known and member.address and member.address ~= ""
                    and known.value.address ~= member.address then
                    local version = (known.version or 1) + 1
                    _M.put(self.store.members, known_key, {
                        name = known_key, address = member.address,
                        status = known.value.status, version = version,
                    }, self.self_name, micros(self.now), version)
                    applied = applied + 1
                end
            else
                if not mine then
                    self.first_seen[member.name] = micros(self.now)
                end
                -- 自报状态无条件采纳：节点自己说在 draining，不能被对等端
                -- 「它还回 HTTP，所以 alive」的观测推翻。版本号仍取较大者加一，
                -- 保持本地单调。
                local adopted = member.version or item.version or 1
                _M.put(self.store.members, member.name, {
                    name = member.name,
                    address = member.address or (mine and mine.value.address) or "",
                    status = member.status,
                    version = math.max(adopted, (mine and mine.version or 0) + 1),
                }, item.node, item.ts, adopted, item.vec, true)
                applied = applied + 1
            end
        end
    end
    return applied
end

-- ------------------------------------------------------------------ wire 编解码

---JSON + base64：base64 让树快照这类二进制 blob 在 JSON 里安全往返。
function _M.encode(snap)
    local text = json_encode(snap)
    if not text then
        return nil, "snapshot not encodable"
    end
    return _M.b64_encode(text)
end

function _M.decode(text)
    local json_text, err = _M.b64_decode(text)
    if not json_text then
        return nil, err or "invalid base64"
    end
    local snap = json_decode(json_text)
    if type(snap) ~= "table" then
        return nil, "snapshot JSON unreadable"
    end
    return snap
end

-- ------------------------------------------------------------------ 内部端点协议
--
-- 全部走 /_mesh/internal/ 前缀，Content-Type: application/x-mesh-b64（正文是
-- 一段 base64(JSON)）。
--   POST /_mesh/internal/sync   请求体 = 本节点快照(b64)，响应体 = 对端快照(b64)
--   POST /_mesh/internal/apply  请求体 = 对端快照(b64)，响应 = {applied}
--   GET  /_mesh/internal/ping   响应 = {node,status,version,draining}
--   GET  /_mesh/internal/state  调试：本节点快照(b64)
-- 一轮 tick 对每个 peer 发一次 sync：请求带自己的快照（推送本地写入），响应带
-- 对方的快照（拉取远端写入），一次往返完成双向收敛。
--
-- handler 返回约定与 router.lua 一致：返回字符串表示响应已自行写完；在没有 ngx
-- 的单测环境里返回 {status=,body=} 表，两条路径共用同一段逻辑。

---当前是否处在可以写响应的阶段。ngx.status 在 init_worker / init 阶段是禁用
-- 的（读它就抛 "API disabled in the current context"），所以判定相位而不是探测
-- 字段：定时器里的广播路径也会经由 handler，必须能安全退回返回表的形式。
local RESPONSE_PHASES = {
    content = true, header_filter = true, body_filter = true, rewrite = true,
}

local function can_write_response()
    if not has_ngx then
        return false
    end
    local ok, phase = pcall(ngx.get_phase)
    return ok and RESPONSE_PHASES[phase] == true
end

---统一的小响应。
local function handler_response(status, payload, content_type)
    local body = ""
    if payload ~= nil then
        if type(payload) == "string" then
            body = payload
        else
            body = json_encode(payload) or "{}"
        end
    end
    if can_write_response() then
        ngx.status = status
        ngx.header["Content-Type"] = content_type or "application/json"
        if body ~= "" then
            ngx.print(body)
        end
        return ""
    end
    return { status = status, body = body, content_type = content_type or "application/json" }
end

local function read_body(req)
    if req and type(req.body) == "string" then
        return req.body
    end
    if req and type(req.get_body) == "function" then
        return req.get_body() or ""
    end
    if can_write_response() then
        ngx.req.read_body()
        return ngx.req.get_body_data() or ""
    end
    return ""
end

_M.read_body = read_body

---GET /_mesh/internal/ping —— 活着就行，回答自己的成员条目。
function _M:handle_ping(req)
    local entry = self.store.members[self.self_name]
    return handler_response(200, {
        protocol = _M.PROTOCOL,
        node = self.self_name,
        addr = self.self_addr or "",
        status = (entry and entry.value.status) or _M.STATUS_ALIVE,
        version = (entry and entry.version) or 1,
        draining = self.draining and true or false,
    })
end

---POST /_mesh/internal/sync —— 合并对端快照，再把自己的快照发回去。
function _M:handle_sync(req)
    local body = read_body(req)
    if body ~= "" then
        local snap, err = _M.decode(body)
        if not snap then
            return handler_response(400, { error = "bad mesh envelope: " .. tostring(err) })
        end
        local _, apply_err = self:apply_snapshot(snap)
        if apply_err then
            return handler_response(400, { error = apply_err })
        end
    end
    local text = _M.encode(self:snapshot())
    if not text then
        return handler_response(500, { error = "snapshot encode failed" })
    end
    return handler_response(200, text, "application/x-mesh-b64")
end

---POST /_mesh/internal/apply —— 只推不拉。
function _M:handle_apply(req)
    local snap, err = _M.decode(read_body(req))
    if not snap then
        return handler_response(400, { error = "bad mesh envelope: " .. tostring(err) })
    end
    local applied, apply_err = self:apply_snapshot(snap)
    if apply_err then
        return handler_response(400, { error = apply_err })
    end
    return handler_response(200, { applied = applied, node = self.self_name })
end

---GET /_mesh/internal/state —— 调试：本节点全量快照。
function _M:handle_state(req)
    local text = _M.encode(self:snapshot())
    if not text then
        return handler_response(500, { error = "snapshot encode failed" })
    end
    return handler_response(200, text, "application/x-mesh-b64")
end

-- ------------------------------------------------------------------ handler 小工具

---cjson 无法区分空表与空对象，空数组必须显式带元表（与 router.lua 的做法一致）。
local function empty_array()
    return setmetatable({}, cjson.empty_array_mt or {})
end
---读 JSON 请求体。req 为接线层传入的请求对象（可为 nil，则走 ngx）。
local function json_body(req)
    local text
    if req and type(req.body) == "string" then
        text = req.body
    else
        text = read_body(req)
    end
    if not text or text == "" then
        return nil, "empty body"
    end
    local value = json_decode(text)
    if type(value) ~= "table" then
        return nil, "invalid JSON body"
    end
    return value
end

---同步失败计数导出为数组（/ha/stats 用）。
local function sync_fail_list(mesh)
    local out = {}
    for name, fails in pairs(mesh.sync_fail) do
        out[#out + 1] = { node = name, consecutive_failures = fails }
    end
    table.sort(out, function(a, b) return a.node < b.node end)
    if #out == 0 then
        return empty_array()
    end
    return out
end

---rate store 的条目不是 LWW 记录，单独计数。
local function rate_key_count(store)
    local n = 0
    for _ in pairs(store) do
        n = n + 1
    end
    return n
end

-- ------------------------------------------------------------------ /ha/* handlers
--
-- 路由表逐条对齐 gateway/src/server.rs:1393-1404，响应体逐字段对齐
-- gateway/src/routers/mesh/handlers.rs。差别只有三处，都写进 doc/gap-mesh.md：
--   * stores 的三个 count 字段 Rust 硬编码 0（源码里就是 TODO），这里给真实值；
--   * /ha/health 在有 peer 不可达或没有 quorum 时 status=degraded（Rust 恒 healthy）；
--   * /ha/shutdown 只把本节点标成 draining 并向对等端广播，不退出进程。

local function not_found(message)
    return handler_response(404, { error = message })
end

---GET /ha/status
function _M:ha_status(req)
    local nodes = {}
    for name, entry in pairs(self.store.members) do
        local member = entry.value
        nodes[#nodes + 1] = {
            name = name,
            address = member.address or "",
            status = member.status or _M.STATUS_INIT,
            version = entry.version or member.version or 0,
        }
    end
    table.sort(nodes, function(a, b) return a.name < b.name end)
    local state, detail = self:partition_state()
    return handler_response(200, {
        node_name = self.self_name,
        node_count = #nodes,
        nodes = #nodes > 0 and nodes or empty_array(),
        partition = state,
        reachable = detail.reachable,
        unreachable = detail.unreachable,
        draining = self.draining and true or false,
        stores = {
            membership_count = #nodes,
            worker_count = _M.count_live(self.store.workers),
            policy_count = _M.count_live(self.store.policies),
            app_count = _M.count_live(self.store.apps),
        },
    })
end

---GET /ha/health
function _M:ha_health(req)
    local state, detail = self:partition_state()
    local healthy = (state == "normal") and not self.draining
    return handler_response(200, {
        status = healthy and "healthy" or "degraded",
        node_name = self.self_name,
        cluster_size = _M.count_live(self.store.members),
        partition = state,
        unreachable = detail.unreachable,
        should_serve = self:should_serve() and true or false,
        draining = self.draining and true or false,
        stores_healthy = healthy and true or false,
    })
end

local function worker_view(entry)
    local value = entry.value
    return {
        worker_id = value.worker_id,
        model_id = value.model_id,
        url = value.url,
        health = value.health and true or false,
        load = value.load or 0,
        version = entry.version or value.version or 0,
        origin = entry.node,
    }
end

---GET /ha/workers
function _M:ha_workers(req)
    local out = {}
    local live = _M.all(self.store.workers)
    for i = 1, #live do
        out[i] = worker_view(live[i].entry)
    end
    return handler_response(200, #out > 0 and out or empty_array())
end

---GET /ha/workers/{worker_id}
function _M:ha_worker(req, worker_id)
    local entry = type(worker_id) == "string" and self.store.workers[worker_id] or nil
    if not entry or not alive(entry.value) then
        return not_found("Worker not found")
    end
    return handler_response(200, worker_view(entry))
end

local function policy_view(entry)
    local value = entry.value
    return {
        model_id = value.model_id,
        policy_type = value.policy_type,
        config = value.config,
        version = entry.version or value.version or 0,
        origin = entry.node,
    }
end

---GET /ha/policies
function _M:ha_policies(req)
    local out = {}
    local live = _M.all(self.store.policies)
    for i = 1, #live do
        out[i] = policy_view(live[i].entry)
    end
    return handler_response(200, #out > 0 and out or empty_array())
end

---GET /ha/policies/{model_id}
function _M:ha_policy(req, model_id)
    if type(model_id) ~= "string" or model_id == "" then
        return not_found("Policy not found")
    end
    local entry = self.store.policies["policy:" .. model_id]
    if not entry or not alive(entry.value) then
        return not_found("Policy not found")
    end
    return handler_response(200, policy_view(entry))
end

---GET /ha/config/{key} —— 值按 Rust 约定 hex 编码。
function _M:ha_config_get(req, key)
    local record = type(key) == "string" and self:get_app(key) or nil
    if not record then
        return not_found("Config not found")
    end
    return handler_response(200, {
        key = key, value = _M.hex_encode(record.value or ""), format = "hex",
    })
end

---POST /ha/config —— body {key, value(hex)}，对齐 update_app_config。
function _M:ha_config_put(req)
    local body, err = json_body(req)
    if not body then
        return handler_response(400, { error = err or "invalid JSON body" })
    end
    if type(body.key) ~= "string" or body.key == "" then
        return handler_response(400, { error = "key is required" })
    end
    local value, verr = _M.hex_decode(body.value or "")
    if not value then
        return handler_response(400, { error = verr })
    end
    self:put_app(body.key, value)
    return handler_response(200, { status = "updated", key = body.key })
end

---POST /ha/rate-limit —— body {limit_per_second}。
function _M:ha_rate_limit_set(req)
    local body, err = json_body(req)
    if not body then
        return handler_response(400, { error = err or "invalid JSON body" })
    end
    local limit = tonumber(body.limit_per_second)
    if not limit or limit < 0 then
        return handler_response(400, { error = "limit_per_second must be a non-negative number" })
    end
    limit = math.floor(limit + 0.5)
    self:set_rate_limit_config(limit)
    self:broadcast_now()
    return handler_response(200, { status = "updated", limit_per_second = limit })
end

---GET /ha/rate-limit
function _M:ha_rate_limit_get(req)
    local config = self:get_rate_limit_config()
    if not config then
        return not_found("Global rate limit not configured")
    end
    return handler_response(200, { limit_per_second = config.limit_per_second or 0 })
end

---GET /ha/rate-limit/stats
function _M:ha_rate_limit_stats(req)
    local config = self:get_rate_limit_config() or { limit_per_second = 0 }
    local limit = config.limit_per_second or 0
    local count = self:rate_value(_M.GLOBAL_RATE_LIMIT_COUNTER_KEY) or 0
    local remaining = -1
    if limit > 0 then
        remaining = math.max(0, limit - count)
    end
    return handler_response(200, {
        limit_per_second = limit,
        current_count = count,
        remaining = remaining,
        window_s = self.config.rate_window_s or 1,
        owner = self:rate_owner(_M.GLOBAL_RATE_LIMIT_COUNTER_KEY),
    })
end

---POST /ha/shutdown —— 标记 draining 并广播；不退出进程（进程生命周期归 supervisor）。
function _M:ha_shutdown(req)
    if not self.draining then
        self.draining = true
        local entry = self.store.members[self.self_name]
        self:put_member({
            name = self.self_name,
            address = (entry and entry.value.address) or self.self_addr or "",
            status = _M.STATUS_LEAVING,
            version = (entry and entry.version or 0) + 1,
        }, self.self_name)
    end
    local sent = self:broadcast_now()
    return handler_response(202, {
        status = "shutdown initiated", node = self.self_name, peers_notified = sent,
    })
end

---GET /ha/stats（本模块补充的观测端点，Rust 无对应路由）。
function _M:ha_stats(req)
    local state, detail = self:partition_state()
    return handler_response(200, {
        node = self.self_name,
        draining = self.draining and true or false,
        partition = state,
        members = _M.count_live(self.store.members),
        alive = detail.alive,
        reachable = detail.reachable,
        unreachable = detail.unreachable,
        unreachable_names = detail.unreachable_names,
        sync_fail = sync_fail_list(self),
        stores = {
            workers = _M.count_live(self.store.workers),
            policies = _M.count_live(self.store.policies),
            apps = _M.count_live(self.store.apps),
            trees = _M.count_live(self.store.trees),
            manual = _M.count_live(self.store.manual),
            rate_keys = rate_key_count(self.store.rate),
        },
        stats = self.stats,
        local_version = self.local_version,
    })
end

-- ------------------------------------------------------------------ cosocket 层
--
-- 下面三个函数需要 cosocket（ngx.socket.tcp）与 ngx.timer，因此只能跑在
-- OpenResty 里；单测通过注入 mesh.http 覆盖同样的代码路径。

---路由器配置（连接池参数）。纯 Lua 单测里没有完整的 router 装配，所以取不到就
--退化成"不入池"，语义与旧实现一致。
local cached_mesh_config
local function mesh_config()
    if cached_mesh_config ~= nil then
        return cached_mesh_config or nil
    end
    local ok, luarouter = pcall(require, "resty.luarouter")
    if ok and type(luarouter) == "table"
        and type(luarouter.config) == "function" then
        local good, conf = pcall(luarouter.config)
        if good and type(conf) == "table" then
            cached_mesh_config = conf
            return conf
        end
    end
    cached_mesh_config = false
    return nil
end

---内部端点的共享 token（接线层在 init_by_lua 里写入控制面 key）。
--router.lua 用同一把 key 守 /_mesh/internal/*，所以出站同步必须带上它，否则每个
--对端都回 401、成员表永远停在 init（历史实测，git 历史可查）。单测的 http 替身
--不走这里，因此设不设都不影响既有断言。
_M.auth_token = nil

---POST/GET 一个 mesh 内部端点。返回 status, body, err。
---@return number|nil status, string|nil body, string|nil err
function _M.http_request(method, url, body, content_type, timeout_ms)
    local registry_ok, registry = pcall(require, "resty.luarouter.registry")
    if not registry_ok then
        return nil, nil, "registry unavailable: " .. tostring(registry)
    end
    local host, port, tls = registry.split_url(url)
    if not host then
        return nil, nil, "bad peer url: " .. tostring(url)
    end
    local path = string.match(url, "^[%w]+://[^/]+(/.*)$") or "/"
    local timeout = timeout_ms or 2000
    local sock = ngx.socket.tcp()
    sock:settimeouts(timeout, timeout, timeout)
    -- resty.luarouter.config() is the cached router config; pcall because the pure
    -- Lua unit tests load this module without the rest of the router wired up.
    local conf = mesh_config()
    local pool_opts
    if conf then
        pool_opts = registry.pool_opts(conf, "mesh", url)
    end
    local ok, err = sock:connect(host, port, pool_opts)
    if not ok then
        return nil, nil, "connect failed: " .. tostring(err)
    end
    local tls_ok, terr = registry.tls_handshake(sock, host, tls)
    if not tls_ok then
        sock:close()
        return nil, nil, terr
    end
    -- Pooled like every other outbound call, so a sync round per peer per interval
    -- stops paying for a fresh handshake each time. No `Connection: close`: that
    -- header asks the peer to drop the connection setkeepalive() is about to reuse.
    local request = method .. " " .. path .. " HTTP/1.1\r\n"
        .. "Host: " .. host .. ":" .. port .. "\r\n"
        .. "User-Agent: lua-router/mesh\r\n"
        .. "Accept: application/json, application/x-mesh-b64\r\n"
    if _M.auth_token then
        request = request .. "Authorization: Bearer " .. _M.auth_token .. "\r\n"
    end
    if body then
        request = request .. "Content-Type: "
            .. (content_type or "application/x-mesh-b64") .. "\r\n"
            .. "Content-Length: " .. #body .. "\r\n"
    end
    request = request .. "\r\n"
    local bytes, werr = sock:send(request)
    if not bytes then
        sock:close()
        return nil, nil, "send failed: " .. tostring(werr)
    end
    if body then
        local _, berr = sock:send(body)
        if berr then
            sock:close()
            return nil, nil, "send body failed: " .. tostring(berr)
        end
    end
    local head = sock:receive("*l")
    if not head then
        sock:close()
        return nil, nil, "no response head"
    end
    local status = tonumber(string.match(head, "^HTTP/%d%.%d%s+(%d%d%d)"))
    if not status then
        sock:close()
        return nil, nil, "malformed status line: " .. head
    end
    local content_length, chunked, connection = nil, false, nil
    repeat
        local line = sock:receive("*l")
        if line and line ~= "" then
            local name, value = string.match(line, "^([%w%-]+):%s*(.*)$")
            if name then
                local lower = string.lower(name)
                if lower == "content-length" then
                    content_length = tonumber(value)
                elseif lower == "transfer-encoding"
                    and string.lower(value):find("chunked") then
                    chunked = true
                elseif lower == "connection" then
                    connection = value
                end
            end
        end
    until line == nil or line == ""
    local out
    local complete = true
    if chunked then
        out, complete = registry.pump_chunked(sock, true)
    elseif content_length then
        local remaining = content_length
        local parts = {}
        while remaining > 0 do
            local block = sock:receive(math.min(65536, remaining))
            if not block then
                complete = false
                break
            end
            parts[#parts + 1] = block
            remaining = remaining - #block
        end
        out = table.concat(parts)
    else
        -- No framing at all: read to end of stream, which ends the connection.
        out = sock:receive("*a") or ""
        complete = false
    end
    if conf and complete then
        registry.release(sock, conf,
            registry.response_reusable({ connection = connection }, true),
            "mesh", url)
    else
        sock:close()
    end
    return status, out
end

---拉一次对端状态：POST /_mesh/internal/sync，body 是自己的快照。
---返回 applied, err。成功/失败都会更新成员表与 unreachable 计数。
function _M:sync_with(base)
    local name = self:resolve_peer_name(base)
    -- 记下这个地址属于哪个键：身份迁移、以及下一轮的 candidate 排序都靠它。
    self:note_address_key(name, base)
    local send = self.http or _M.http_request
    local snap = self:snapshot()
    local text = _M.encode(snap)
    if not text then
        self:mark_sync_failure(name)
        return 0, "snapshot encode failed"
    end

    -- 候选地址：先试已知写法（验证过的优先），再试调用方给的那个写法。
    local targets = self:peer_candidates(name)
    local has_base = false
    for i = 1, #targets do
        if targets[i] == base then
            has_base = true
        end
    end
    if not has_base and base and base ~= "" then
        targets[#targets + 1] = base
    end
    local status, body
    for _, target in ipairs(targets) do
        status, body = send("POST", target .. "/_mesh/internal/sync", text,
            "application/x-mesh-b64", self.config.rpc_timeout_ms)
        if status then
            -- 对方答了（哪怕 4xx/5xx）就不再换写法：鉴权与状态都是节点级的，
            -- 换地址重问只会把一轮同步的开销乘以写法数。只有连不上（拨号层
            -- 失败）才说明「这个写法是错的」，继续试下一个。
            if status >= 200 and status < 300 then
                -- 记住哪种写法能连通（对端自报的地址未必从本机可达）
                self.used_addr[name] = target
            end
            break
        end
    end

    if not status then
        self.stats.sync_failures = self.stats.sync_failures + 1
        self:mark_sync_failure(name)
        return 0, tostring(body)
    end
    if status < 200 or status >= 300 then
        self.stats.sync_failures = self.stats.sync_failures + 1
        self:mark_sync_failure(name)
        return 0, "peer said " .. status
    end
    local remote, err = _M.decode(body or "")
    if not remote then
        self.stats.sync_failures = self.stats.sync_failures + 1
        self:mark_sync_failure(name)
        return 0, "unreadable peer snapshot: " .. tostring(err)
    end
    local applied, apply_err = self:apply_snapshot(remote)
    if apply_err then
        self.stats.sync_failures = self.stats.sync_failures + 1
        self:mark_sync_failure(name)
        return 0, apply_err
    end
    -- 拨号地址与对端自报名认成同一个节点，这一步把种子键（幻影）合并掉。
    local unified = self:unify_identity(base, remote.node) or name
    -- apply_snapshot 已经把对端自报名记成可达；这里补上「对端没自报名」的情况，
    -- 并且不能再拿旧的名字去记账（那个键可能刚被 migrate 掉）。
    self:mark_sync_success(remote.node or unified)
    self.stats.sync_rounds = self.stats.sync_rounds + 1
    return applied
end

---一轮全对等同步。返回同步过的 peer 数。
function _M:sync_tick()
    local peers = self:peer_bases()
    for i = 1, #peers do
        local ok, err = pcall(self.sync_with, self, peers[i])
        if not ok and has_ngx then
            ngx.log(ngx.ERR, "luarouter: mesh sync with ", peers[i], " failed: ",
                tostring(err))
        end
    end
    self:roll_windows()
    return #peers
end

---立即广播一轮（/ha/shutdown 与 /ha/rate-limit 写后调用）。在无 cosocket 的
--环境里返回 0，这样 handler 在单测里也可调用。
function _M:broadcast_now()
    if not self.http and not has_ngx then
        return 0
    end
    local sent = self:sync_tick()
    self.stats.broadcasts = self.stats.broadcasts + 1
    return sent
end

---周期同步定时器。只在 worker 0 跑：状态表是进程内的，多 worker 各自同步会把
--对等端的负载乘以 worker 数，而收敛结果一样（LWW 幂等）。代价是非 0 号 worker
--的状态落后一个 interval，接线层若要严格一致应把 mesh 与 policy 一样限制
--worker_processes=1（见 doc/gap-mesh.md §4）。
function _M:start()
    if self.started then
        return true
    end
    if not has_ngx or type(ngx.timer) ~= "table" then
        return false, "no ngx.timer (mesh sync needs OpenResty)"
    end
    if #self:peer_bases() == 0 then
        return false, "no mesh peers"
    end
    self.started = true
    local function tick(premature)
        if premature or not self.started then
            return
        end
        local ok, err = pcall(self.sync_tick, self)
        if not ok and has_ngx then
            ngx.log(ngx.ERR, "luarouter: mesh sync tick failed: ", tostring(err))
        end
        local again, aerr = ngx.timer.at(self.config.interval_s, tick)
        if not again then
            self.started = false
            ngx.log(ngx.ERR, "luarouter: mesh sync timer stopped: ", tostring(aerr))
        end
    end
    -- init_by_lua 里 ngx.timer 表存在但 ngx.timer.at 会直接报 "no request"，
    -- 所以用 pcall 兜住：定时器只能在 init_worker 及之后的相位里排。
    local ok, scheduled, serr = pcall(ngx.timer.at, self.config.interval_s, tick)
    if not ok or not scheduled then
        self.started = false
        return false, tostring(scheduled or serr)
    end
    return true
end

function _M:stop()
    self.started = false
end

-- ------------------------------------------------------------------ 路由表与分发
--
-- 一张表说明所有对外端点，接线层可以整块交给 klib.router 注册（见
-- doc/gap-mesh.md §4），也可以按名字单独调 handler。
--   path    相对 /ha 或 /_mesh/internal 的路径（klib.router 的 pattern 形状）
--   method  大小写敏感的 HTTP method（klib.router 逐字匹配）
--   handler _M 上的方法名
--   args    从路由捕获参数里取的位置（worker_id / model_id / key）
_M.ROUTES = {
    { method = "GET",  path = "ha/status",                handler = "ha_status" },
    { method = "GET",  path = "ha/health",                handler = "ha_health" },
    { method = "GET",  path = "ha/workers",               handler = "ha_workers" },
    { method = "GET",  path = "ha/workers/:worker_id",    handler = "ha_worker", args = { "worker_id" } },
    { method = "GET",  path = "ha/policies",              handler = "ha_policies" },
    { method = "GET",  path = "ha/policies/:model_id",    handler = "ha_policy", args = { "model_id" } },
    { method = "GET",  path = "ha/config/:key",           handler = "ha_config_get", args = { "key" } },
    { method = "POST", path = "ha/config",                handler = "ha_config_put" },
    { method = "GET",  path = "ha/rate-limit",            handler = "ha_rate_limit_get" },
    { method = "POST", path = "ha/rate-limit",            handler = "ha_rate_limit_set" },
    { method = "GET",  path = "ha/rate-limit/stats",      handler = "ha_rate_limit_stats" },
    { method = "POST", path = "ha/shutdown",              handler = "ha_shutdown" },
    { method = "GET",  path = "ha/stats",                 handler = "ha_stats" },
    { method = "GET",  path = "_mesh/internal/ping",      handler = "handle_ping" },
    { method = "POST", path = "_mesh/internal/sync",      handler = "handle_sync" },
    { method = "POST", path = "_mesh/internal/apply",     handler = "handle_apply" },
    { method = "GET",  path = "_mesh/internal/state",     handler = "handle_state" },
}

---未启用 mesh 时的固定响应。接线层在拿不到 mesh 实例时用它回答 /ha/*，响应与
---router.lua 现在的 mesh_disabled_handler 逐字节一致（契约测试锁定了这个 body）。
function _M.disabled_response()
    return handler_response(503, '{"error":"mesh not enabled"}', "application/json")
end

---按路径分发（对齐 Rust /ha/* 与内部端点）。mesh 未启用一律 503 固定体。
---@param mesh table|nil @ 关闭时传 nil
---@param method string
---@param path string  @ 以 / 开头的请求路径
---@param params table|nil @ klib.router 的捕获参数
---@param req table|nil @ 请求对象（{body=} 或带 get_body 的对象）
function _M.dispatch(mesh, method, path, params, req)
    if not mesh then
        return _M.disabled_response()
    end
    local trimmed = path
    if trimmed:sub(1, 1) == "/" then
        trimmed = trimmed:sub(2)
    end
    for i = 1, #_M.ROUTES do
        local route = _M.ROUTES[i]
        if route.method == method and _M.route_matches(route.path, trimmed) then
            local fn = mesh[route.handler]
            if type(fn) ~= "function" then
                return handler_response(500, { error = "mesh handler missing: " .. route.handler })
            end
            if route.args then
                local args = {}
                for j = 1, #route.args do
                    args[j] = params and params[route.args[j]]
                end
                return fn(mesh, req, args[1], args[2])
            end
            return fn(mesh, req)
        end
    end
    if path:sub(1, 4) == "/ha/" or path == "/ha" then
        -- Rust 的 404 兜底：/ha 前缀下的未知路径同样回 mesh not enabled；这里
        -- mesh 已启用，用同样的固定体表示「这条路由本实现不提供」。
        return handler_response(404, { error = "unknown ha route: " .. method .. " " .. path })
    end
    return nil
end

---把 "ha/workers/:worker_id" 与请求路径做段级比较（':' 段通配一段）。
function _M.route_matches(pattern, path)
    local p, q = 1, 1
    while true do
        local p_seg = string.match(pattern, "^:([^/]+)", p)
        local q_seg_end = string.find(path, "/", q, true) or (#path + 1)
        if p_seg then
            if q >= #path + 1 then
                return false
            end
            p = p + #p_seg + 1
            q = q_seg_end + 1
        else
            local lit_end = string.find(pattern, "/", p, true) or (#pattern + 1)
            local literal = string.sub(pattern, p, lit_end - 1)
            if string.sub(path, q, q_seg_end - 1) ~= literal then
                return false
            end
            if lit_end > #pattern and q_seg_end > #path then
                return true
            end
            if lit_end > #pattern or q_seg_end > #path then
                return false
            end
            p = lit_end + 1
            q = q_seg_end + 1
        end
    end
end

-- ------------------------------------------------------------------ 环境变量装配

---从环境变量装配 mesh（SMG_MESH_PEERS / SMG_MESH_SELF 是任务书指定的两个名字，
--其余 SMG_MESH_* 是可选覆盖）。peers 为空时返回 nil —— 与 Rust 不带
-- --enable-mesh 时的行为一致，/ha/* 全部 503。
function _M.from_env(getenv, opts)
    local raw = getenv or (type(os) == "table" and os.getenv) or function() return nil end
    local take = function(name)
        local value = raw(name)
        if value == nil or value == "" then
            return nil
        end
        return value
    end
    local peers_text = take("SMG_MESH_PEERS")
    if not peers_text then
        return nil, "SMG_MESH_PEERS not set"
    end
    local peers = _M.parse_peers(peers_text)
    local self_addr = take("SMG_MESH_SELF") or take("SMG_MESH_SELF_ADDR")
    -- 本实例可以不在 peers 里（Rust 的 init_peer 允许只写对等端）；不在则补进去
    -- 也不算错，成员表最终靠同步收敛。
    local opts_tbl = {
        peers = peers,
        self_addr = self_addr,
        self_name = take("SMG_MESH_SELF_NAME")
            or (self_addr and _M.hostport_from_url(self_addr)),
        interval_s = tonumber(take("SMG_MESH_SYNC_INTERVAL_SECS")) or 2,
        unreachable_s = tonumber(take("SMG_MESH_UNREACHABLE_TIMEOUT_SECS")) or 30,
        suspect_threshold = tonumber(take("SMG_MESH_SUSPECT_THRESHOLD")) or 2,
        quorum = tonumber(take("SMG_MESH_QUORUM")),
        min_cluster_size = tonumber(take("SMG_MESH_MIN_CLUSTER_SIZE")) or 3,
        rate_window_s = tonumber(take("SMG_MESH_RATE_WINDOW_SECS")) or 1,
        rpc_timeout_ms = tonumber(take("SMG_MESH_RPC_TIMEOUT_MS")) or 2000,
        snapshot_max_bytes = tonumber(take("SMG_MESH_SNAPSHOT_MAX_BYTES"))
            or (3 * 1024 * 1024),
    }
    if opts then
        for k, v in pairs(opts) do
            opts_tbl[k] = v
        end
    end
    return _M.new(opts_tbl)
end

-- ------------------------------------------------------------------ 模块级单例
--
-- 与 policy.default / hb 的配置读取一样，mesh 实例是进程内的：router 的接线
-- 代码通过 _M.instance() 拿到它做本地写入，init_worker 负责构造与启动定时器。

local instance

---构造并保存进程内的 mesh 实例（已存在则返回原实例）。
function _M.init(getenv, opts)
    if instance then
        return instance
    end
    local mesh, err = _M.from_env(getenv, opts)
    if not mesh then
        return nil, err
    end
    instance = mesh
    return instance
end

---@return table|nil mesh
function _M.instance()
    return instance
end

---测试与热重载用：替换（传 nil 即清空）进程内实例。
function _M.set_instance(mesh)
    instance = mesh
    return instance
end

return _M
