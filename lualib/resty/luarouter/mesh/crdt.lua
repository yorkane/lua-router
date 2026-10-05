-- mesh.crdt —— CRDT 状态底座与成员表：时钟 + LWW/版本向量/PN counter +
-- 成员身份底座 + new() 六张 store + 成员表操作 + 分区检测 + observe_* 本地写入
-- + 快照与合并。
--
-- 【不许再拆】幻影键修复的正确性依赖这条链同时看见六样东西：addr_keys 别名、
-- used_addr、first_seen、peer_candidates 排序、member_key_for_address 的别名优先、
-- unify_identity→migrate_member、merge_membership 的自记录守卫（doc/gap-mesh-final.md
-- §3 的变异表逐条证明「只摘其中一点就有 N 条断言红」）。observe_* 同源留下：
-- local_write 需要 mesh.now / self_name / local_version。
--
-- 公共函数一律直写门面表（resty.luarouter.mesh），所以搬家的函数体逐字不变：
-- 原本文件内的 self:x() 与 _M.x() 仍然按同一张表解析。跨子模块要用的文件级私有
-- 把手（micros、alive）经 return { priv = ... } 交给 mesh/rate.lua 与 mesh/handlers.lua。
local _M = require "resty.luarouter.mesh"

local cjson = require "cjson.safe"

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


return { priv = { micros = micros, alive = alive } }
