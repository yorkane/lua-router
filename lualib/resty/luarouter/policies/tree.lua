-- 多租户基数树（近似前缀树），逐字符对齐 gateway/src/policies/tree.rs。
--
-- 与 Rust 的结构性差异：
--   * 无锁：每个 nginx worker 进程各持有一棵树（LuaJIT 单线程），不做跨进程同步。
--   * 字符计数一律 UTF-8 码点数（utils.utf8_len），对齐 Rust 的 chars().count()。
--   * epoch 仍是全局自增计数器，prefix_match 的 1/8 回写保留（epoch % 8 == 0）。
--   * last_tenant 缓存 / tenant_char_count 全局表语义与 Rust 一致。
--
-- 节点结构 { children = {首字符 -> node}, text, text_chars,
--            tenant_last_access = {tenant -> epoch}, parent, last_tenant }

local utils = require "resty.luarouter.policies.utils"

local utf8_len = utils.utf8_len
local utf8_head = utils.utf8_head
local utf8_tail = utils.utf8_tail
local utf8_first = utils.utf8_first
local shared_prefix_count = utils.utf8_shared_prefix_count

local EMPTY_TENANT = "empty"       -- 对齐 Rust 的 Arc::from("empty") 兜底

local _M = {}

--------------------------------------------------------------------------
-- 全局 epoch 计数器（所有树共享，对齐 Rust 的 static EPOCH_COUNTER）
--------------------------------------------------------------------------

local epoch_counter = 0

local function next_epoch()
    epoch_counter = epoch_counter + 1
    return epoch_counter
end

--- 快照恢复后把计数器推到已见最大值之后，保证新写入永远更新
function _M.bump_epoch(to)
    if type(to) == "number" and to > epoch_counter then
        epoch_counter = to
    end
end

function _M.current_epoch()
    return epoch_counter
end

--------------------------------------------------------------------------
-- 小顶堆（按 timestamp），用于 evict_tenant_by_size 的 LRU 顺序
--------------------------------------------------------------------------

local heap = {}
heap.__index = heap

function heap.new()
    return setmetatable({ items = {} }, heap)
end

function heap:push(entry)
    local items = self.items
    items[#items + 1] = entry
    local i = #items
    while i > 1 do
        local parent = math.floor(i / 2)
        if items[parent].timestamp <= items[i].timestamp then
            break
        end
        items[parent], items[i] = items[i], items[parent]
        i = parent
    end
end

function heap:pop()
    local items = self.items
    local n = #items
    if n == 0 then
        return nil
    end
    local top = items[1]
    items[1] = items[n]
    items[n] = nil
    local size = n - 1                      -- 弹出后的有效元素个数
    local i = 1
    while true do
        local l, r = 2 * i, 2 * i + 1
        local smallest = i
        if l <= size and items[l].timestamp < items[smallest].timestamp then
            smallest = l
        end
        if r <= size and items[r].timestamp < items[smallest].timestamp then
            smallest = r
        end
        if smallest == i then
            break
        end
        items[i], items[smallest] = items[smallest], items[i]
        i = smallest
    end
    return top
end

function heap:size()
    return #self.items
end

_M.heap = heap

--------------------------------------------------------------------------
-- 节点
--------------------------------------------------------------------------

local function new_node(text, parent)
    return {
        children = {},
        text = text,
        text_chars = utf8_len(text),
        tenant_last_access = {},
        parent = parent,
        last_tenant = nil,
    }
end

local function set_tenant_epoch(node, tenant, epoch)
    node.tenant_last_access[tenant] = epoch
end

--- 租户是否为该节点的叶子（节点本身带该租户，且没有任何子节点带该租户）
local function is_leaf_for(node, tenant)
    if node.tenant_last_access[tenant] == nil then
        return false
    end
    for _, child in pairs(node.children) do
        if child.tenant_last_access[tenant] ~= nil then
            return false
        end
    end
    return true
end

local function leaf_of(node)
    local out = {}
    for tenant in pairs(node.tenant_last_access) do
        if is_leaf_for(node, tenant) then
            out[#out + 1] = tenant
        end
    end
    return out
end

--------------------------------------------------------------------------
-- Tree
--------------------------------------------------------------------------

local Tree = {}
Tree.__index = Tree

_M.Tree = Tree

function _M.new()
    local self = setmetatable({}, Tree)
    self.root = new_node("", nil)
    self.tenant_char_count = {}
    -- 体积计数：非 root 节点的个数与它们的 text_chars 总和。
    -- 存在的唯一理由是把「这棵树要不要淘汰」的判定从 O(全树 DFS 建堆) 降到 O(1) ——
    -- 见 needs_eviction。单 worker 进程里这两个数就是亲和状态的体量，
    -- 也由 publish_gauges 直接发成 gauge，免得下次再靠 smaps 猜。
    self.live_nodes = 0
    self.live_chars = 0
    return self
end

--- 对齐 Tree::insert：沿字符下钻，公共前缀不足则分裂节点，叶子写 epoch
--- epoch_override 只在快照恢复时使用（保持 LRU 相对顺序）
function Tree:insert(text, tenant, epoch_override)
    if type(tenant) ~= "string" then
        return
    end
    text = (type(text) == "string") and text or ""

    -- 根节点登记租户（不写 epoch → 永不被淘汰），并初始化字符计数
    if self.root.tenant_last_access[tenant] == nil then
        set_tenant_epoch(self.root, tenant, 0)
    end
    if self.tenant_char_count[tenant] == nil then
        self.tenant_char_count[tenant] = 0
    end

    local remaining = text
    local prev = self.root

    while remaining ~= "" do
        local first = utf8_first(remaining)
        local matched_node = prev.children[first]

        if matched_node == nil then
            -- 无匹配：以剩余文本建新叶子，写 epoch 后结束
            local remaining_chars = utf8_len(remaining)
            local epoch = epoch_override or next_epoch()
            local node = {
                children = {},
                text = remaining,
                text_chars = remaining_chars,
                tenant_last_access = {},
                parent = prev,
                last_tenant = tenant,
            }
            node.tenant_last_access[tenant] = epoch
            self.tenant_char_count[tenant] = self.tenant_char_count[tenant] + remaining_chars
            prev.children[first] = node
            self.live_nodes = self.live_nodes + 1
            self.live_chars = self.live_chars + remaining_chars
            self.node_evict_stalled = false         -- 同上：有新叶子就重新尝试节点维度
            return
        end

        local matched_chars = matched_node.text_chars
        local shared = shared_prefix_count(remaining, matched_node.text)

        if shared < matched_chars then
            -- 公共前缀分裂：new(前缀) -> matched(收缩后的后缀)
            local prefix_text = utf8_head(matched_node.text, shared)
            local suffix_text = utf8_tail(matched_node.text, shared)

            local copied = {}
            for t, e in pairs(matched_node.tenant_last_access) do
                copied[t] = e
            end

            local node = {
                children = {},
                text = prefix_text,
                text_chars = shared,
                tenant_last_access = copied,
                parent = prev,
                last_tenant = matched_node.last_tenant,
            }
            local suffix_first = utf8_first(suffix_text)
            node.children[suffix_first] = matched_node
            prev.children[first] = node

            matched_node.text = suffix_text
            matched_node.text_chars = matched_chars - shared
            matched_node.parent = node
            self.live_nodes = self.live_nodes + 1   -- 字符总量不变：前缀 + 后缀 = 原文
            self.node_evict_stalled = false         -- 长出新节点，节点维度重新有得清

            -- 分裂节点是中间节点：补登记租户但不写 epoch
            if node.tenant_last_access[tenant] == nil then
                self.tenant_char_count[tenant] = self.tenant_char_count[tenant] + shared
                set_tenant_epoch(node, tenant, 0)
            end

            prev = node
            remaining = utf8_tail(remaining, shared)
        else
            -- 全匹配：继续下钻
            if matched_node.tenant_last_access[tenant] == nil then
                self.tenant_char_count[tenant] = self.tenant_char_count[tenant] + matched_chars
                set_tenant_epoch(matched_node, tenant, 0)
            end
            prev = matched_node
            remaining = utf8_tail(remaining, shared)
        end
    end

    -- 文本走完：prev 是叶子，刷新 epoch 供 LRU 使用
    prev.tenant_last_access[tenant] = epoch_override or next_epoch()
end

--- 对齐 prefix_match_with_counts → (tenant, matched_chars, input_chars)
--- 分母是输入全文的字符数（不是剩余字符数）。
function Tree:prefix_match_with_counts(text)
    text = (type(text) == "string") and text or ""

    local remaining = text
    local matched_chars = 0
    local prev = self.root

    while remaining ~= "" do
        local first = utf8_first(remaining)
        local matched_node = prev.children[first]
        if matched_node ~= nil then
            local shared = shared_prefix_count(remaining, matched_node.text)
            if shared == matched_node.text_chars then
                matched_chars = matched_chars + shared
                remaining = utf8_tail(remaining, shared)
                prev = matched_node
            else
                -- 部分匹配：仍用该节点选租户
                matched_chars = matched_chars + shared
                prev = matched_node
                break
            end
        else
            break
        end
    end

    local curr = prev

    -- 先用 last_tenant 缓存（O(1)），缓存失效再遍历并回填缓存
    local tenant = curr.last_tenant
    if tenant ~= nil and curr.tenant_last_access[tenant] == nil then
        tenant = nil
    end
    if tenant == nil then
        for t in pairs(curr.tenant_last_access) do
            tenant = t
            break
        end
        if tenant == nil then
            tenant = EMPTY_TENANT
        end
        curr.last_tenant = tenant
    end

    -- 1/8 概率回写时间戳（降低写放大；LRU 只需近似准确）
    --
    -- 但兜底的假租户 EMPTY_TENANT 不参与：它只是「这条路径还没人认领」的返回值，
    -- 在 tenant_char_count 里根本没有条目，写进去既不产生 LRU 价值，又会永久堵住
    -- detach_if_empty（该函数要求 tenant_last_access 为空才摘节点）。冷前缀越多，
    -- 被这个槽位钉住的中间节点就越多 —— 骨架永不收缩的第二个原因。
    -- 路由决策不变：返回值仍是 EMPTY_TENANT，cache_aware 那边照样落到 min load 分支。
    local epoch = next_epoch()
    if epoch % 8 == 0 and tenant ~= EMPTY_TENANT then
        curr.tenant_last_access[tenant] = epoch
    end

    return tenant, matched_chars, utf8_len(text)
end

--- 兼容旧接口：返回 (matched_text, tenant)
function Tree:prefix_match(text)
    local tenant, matched_chars, _ = self:prefix_match_with_counts(text)
    return utils.utf8_head(text or "", matched_chars), tenant
end

--- 对齐 prefix_match_tenant：只匹配属于指定租户的路径
function Tree:prefix_match_tenant(text, tenant)
    text = (type(text) == "string") and text or ""

    local remaining = text
    local matched_chars = 0
    local prev = self.root

    while remaining ~= "" do
        local first = utf8_first(remaining)
        local matched_node = prev.children[first]
        if matched_node == nil then
            break
        end
        if matched_node.tenant_last_access[tenant] == nil then
            break
        end
        local shared = shared_prefix_count(remaining, matched_node.text)
        if shared == matched_node.text_chars then
            matched_chars = matched_chars + shared
            remaining = utf8_tail(remaining, shared)
            prev = matched_node
        else
            matched_chars = matched_chars + shared
            prev = matched_node
            break
        end
    end

    if prev.tenant_last_access[tenant] ~= nil then
        prev.tenant_last_access[tenant] = next_epoch()
    end
    return utf8_head(text, matched_chars)
end

--- 从父节点摘掉空节点（对齐 Rust 的 remove empty nodes）
---
--- 之所以是 Tree 方法而不是 local 函数：节点数/字符数是树上的字段，摘掉节点必须
--- 在同一处回收，否则 node_count 只涨不跌，后面新增的 SMG_MAX_TREE_NODES 上限就成了
--- 摆设。原本 detach 的触发条件（无子且无租户）在 trie 骨架长出来后几乎不成立，
--- 骨架因此永不收缩 —— 这是本次改动要修的形状之一。
function Tree:detach_if_empty(node)
    if node.parent == nil then
        return
    end
    if next(node.children) ~= nil then
        return
    end
    if next(node.tenant_last_access) ~= nil then
        return
    end
    local first = utf8_first(node.text)
    if first == nil then
        return
    end
    node.parent.children[first] = nil
    node.parent = nil
    self.live_nodes = self.live_nodes - 1
    if self.live_nodes < 0 then
        self.live_nodes = 0
    end
    local chars = node.text_chars or 0
    self.live_chars = self.live_chars - chars
    if self.live_chars < 0 then
        self.live_chars = 0
    end
    node.text_chars = 0
end

--- 对齐 remove_tenant：自叶子向上清租户，最后清 tenant_char_count
function Tree:remove_tenant(tenant)
    if type(tenant) ~= "string" then
        return
    end

    -- 1. 找出该租户的所有叶子
    local stack = { self.root }
    local queue = {}
    while #stack > 0 do
        local curr = table.remove(stack)
        for _, child in pairs(curr.children) do
            stack[#stack + 1] = child
        end
        if curr.tenant_last_access[tenant] ~= nil then
            local has_child_with = false
            for _, child in pairs(curr.children) do
                if child.tenant_last_access[tenant] ~= nil then
                    has_child_with = true
                    break
                end
            end
            if not has_child_with then
                queue[#queue + 1] = curr
            end
        end
    end

    -- 2. 从叶子出发逐层往上清理
    local head = 1
    while head <= #queue do
        local curr = queue[head]
        head = head + 1

        curr.tenant_last_access[tenant] = nil
        if curr.last_tenant == tenant then
            curr.last_tenant = nil
        end
        local parent = curr.parent
        self:detach_if_empty(curr)

        if parent ~= nil and parent.tenant_last_access[tenant] ~= nil then
            local has_child_with = false
            for _, child in pairs(parent.children) do
                if child.tenant_last_access[tenant] ~= nil then
                    has_child_with = true
                    break
                end
            end
            if not has_child_with then
                queue[#queue + 1] = parent
            end
        end
    end

    -- 3. 摘掉租户的字符计数
    self.tenant_char_count[tenant] = nil
end

--- 对齐 evict_tenant_by_size：按租户字符数总量做叶子 LRU 淘汰
--
-- 在原语义（每租户字符数上限）之外加了三件事，都不改变「限额内不改动」这条既有行为：
--
--   1. 廉价前置判定 over_limit()。原先每拍都要先把**全部节点** DFS 进一个小顶堆，
--      单 worker 进程里这就是 O(亲和状态总量) 的常驻成本；累积到百万节点时它本身就
--      是烧核来源。现在先用 O(租户数) 的 tenant_char_count 与 O(1) 的 live_nodes/
--      live_chars 判一次「有没有超标」，没超标就直接返回，一行 DFS 都不做。
--   2. 节点数维度 max_nodes。字符维度的语义是「每租户」，同一批 worker URL 可以合法
--      堆 len(tenants) x max_size 字符，且没有任何维度约束**节点个数**；而真正压垮
--      单核与 RSS 的是节点数（每节点一张 6 字段表 + children 哈希 + 一份 prompt 尾巴
--      字符串）。max_nodes <= 0 表示不设这一维（兼容只想用字符闸的部署）。
--   3. 增量预算 max_pops。原先一旦超标就要弹空整棵堆，单 tick 可以跑到秒级并卡死
--      唯一的转发核；现在每拍最多弹 max_pops 个，剩下的下一拍接着清（追平即可）。
local DEFAULT_EVICT_BUDGET = 2000

--- 是否已经越过字符/节点上限。只用增量计数与租户表，不做 DFS。
---@param max_size number @ 每租户字符上限
---@param max_nodes number|nil @ 节点数上限；nil/<=0 = 不看这一维
---@return boolean
function Tree:over_limit(max_size, max_nodes)
    local count = 0
    for _, used in pairs(self.tenant_char_count) do
        if used > max_size then
            return true
        end
        count = count + 1
        if count > 4096 then   -- 租户数本身就异常，直接判定需要清（不做全表遍历）
            return true
        end
    end
    -- 节点维度带一个停摆位：树里不能摘的骨架节点（还有子节点）永远不会被
    -- detach_if_empty 摘掉，于是 live_nodes 可能降不到 max_nodes 以下。若这里不加
    -- 判断，每一拍都会「以为还能清」而重建一次全树堆 —— 那正是本次要消掉的 O(累积
    -- 状态) 常驻成本。清到弹不动时置位，下次有新的插入再复位。
    if max_nodes and max_nodes > 0 and self.live_nodes > max_nodes
        and not self.node_evict_stalled then
        return true
    end
    if self.live_nodes < 0 then self.live_nodes = 0 end
    if self.live_chars < 0 then self.live_chars = 0 end
    return false
end

---@param max_size number @ 每租户字符上限（Rust evict_tenant_by_size 的语义）
---@param max_nodes number|nil @ 全树节点数上限（新增维度；nil/<=0 = 不限）
---@param budget number|nil @ 本次最多淘汰多少个叶子（增量，默认 2000）
---@return boolean more_work @ 是否仍有活没清完（调用方可提前再来一拍）
function Tree:evict_tenant_by_size(max_size, max_nodes, budget)
    max_size = max_size or 0
    max_nodes = max_nodes or 0
    local max_pops = budget or DEFAULT_EVICT_BUDGET
    if max_pops < 1 then max_pops = 1 end

    -- (1) 廉价闸：没超标就立刻返回，绝不建堆
    if not self:over_limit(max_size, max_nodes) then
        return false
    end

    local over_nodes = max_nodes > 0 and self.live_nodes > max_nodes or false

    local pq = heap.new()
    local stack = { self.root }
    while #stack > 0 do
        local curr = table.remove(stack)
        for _, child in pairs(curr.children) do
            stack[#stack + 1] = child
        end
        local leaves = leaf_of(curr)
        for i = 1, #leaves do
            local tenant = leaves[i]
            pq:push({ timestamp = curr.tenant_last_access[tenant], tenant = tenant, node = curr })
        end
    end

    local pops = 0
    while pq:size() > 0 do
        local entry = pq:pop()
        local tenant, node = entry.tenant, entry.node

        local used = self.tenant_char_count[tenant]
        -- (2) 节点维度生效时，字符没超标的租户也要能被淘汰；否则只看字符就 continue，
        --     live_nodes 永远降不下来，新增的 max_nodes 闸就成了摆设。
        if used ~= nil and used <= max_size and not over_nodes then
            goto continue
        end
        if pops >= max_pops then
            return true           -- (3) 本 tick 预算用完，剩下的下一拍接着清
        end
        pops = pops + 1

        -- 复核：该节点此刻仍是该租户的叶子才允许淘汰
        if not is_leaf_for(node, tenant) then
            goto continue
        end

        used = self.tenant_char_count[tenant]
        if used ~= nil then
            self.tenant_char_count[tenant] = used - node.text_chars
            if self.tenant_char_count[tenant] < 0 then
                self.tenant_char_count[tenant] = 0
            end
        end
        node.tenant_last_access[tenant] = nil
        if node.last_tenant == tenant then
            node.last_tenant = nil
        end

        local parent = node.parent
        self:detach_if_empty(node)

        if parent ~= nil and parent.tenant_last_access[tenant] ~= nil then
            local has_child_with = false
            for _, child in pairs(parent.children) do
                if child.tenant_last_access[tenant] ~= nil then
                    has_child_with = true
                    break
                end
            end
            if not has_child_with then
                pq:push({ timestamp = parent.tenant_last_access[tenant], tenant = tenant, node = parent })
            end
        end

        ::continue::
    end

    -- 一拍里什么都没弹掉却仍判超标，说明超标来自摘不动的骨架：置停摆位，
    -- 之后不再为节点维度重建全树堆（有字符维度的活照做，那部分由 over_limit 判）。
    if pops == 0 and over_nodes then
        self.node_evict_stalled = true
        return false
    end

    -- 堆空了但计数仍在上限之上（例如 detach 因共享前缀没摘掉节点）：
    -- 让调用方知道还有活，下一拍接着做，而不是在一拍里死磕。
    return self:over_limit(max_size, max_nodes)
end

--------------------------------------------------------------------------
-- 只读辅助（metrics / 快照）
--------------------------------------------------------------------------

function Tree:get_tenant_char_count()
    local out = {}
    for tenant, count in pairs(self.tenant_char_count) do
        out[tenant] = count
    end
    return out
end

--- DFS 统计每个租户实际占用的节点字符数（对齐 get_used_size_per_tenant）
function Tree:get_used_size_per_tenant()
    local out = {}
    local stack = { self.root }
    while #stack > 0 do
        local curr = table.remove(stack)
        for tenant in pairs(curr.tenant_last_access) do
            out[tenant] = (out[tenant] or 0) + curr.text_chars
        end
        for _, child in pairs(curr.children) do
            stack[#stack + 1] = child
        end
    end
    return out
end

function Tree:node_count()
    local n = 0
    local stack = { self.root }
    while #stack > 0 do
        local curr = table.remove(stack)
        n = n + 1
        for _, child in pairs(curr.children) do
            stack[#stack + 1] = child
        end
    end
    return n - 1        -- 不含 root，对齐“每棵树节点数”的语义
end

--- 把树压成「租户叶子全文 + epoch」列表，用于跨重启的 JSON 快照。
--- 重建时按 epoch 升序回放 insert，即可复原同样的节点拓扑与 LRU 相对顺序。
--
-- max_chars 是**边走边估**的预算。原实现先把整棵树拼成条目表、再 cjson.encode 成
-- 最多 3 MB 的字符串，**然后才**由 encode_snapshot 判是否超限（cache_aware.lua:
-- encode_snapshot），也就是说树越大，那一次注定被丢弃的分配就越大 —— 单 worker
-- 进程每 120s 制造一次数百 MB 垃圾正是这个形状，它同时解释烧核与 RSS 只涨不降。
-- 现在先按增量计数粗筛（O(1)），再边 DFS 边累计字符量，越预算立刻返回 nil 并置
-- snapshot_oversized（调用方据此只 WARN 一次），完全不建条目表。
-- 一条条目至少 "t":"<text>","tnt":"<url>","e":<n>，即 text + url + 约 24 字节开销，
-- 再乘一个安全系数。
local SNAPSHOT_JSON_SLACK = 3
local SNAPSHOT_URL_ALLOWANCE = 128
local SNAPSHOT_MAX_ENTRIES = 200000

---@param max_chars number|nil @ 允许落盘的字节预算；nil = 不设预算（单测与内部调用）
---@return table|nil snapshot
function Tree:serialize(max_chars)
    if max_chars ~= nil then
        if self.live_chars * SNAPSHOT_JSON_SLACK > max_chars then
            -- 粗筛：光字符数就不可能塞进预算，一次 DFS 都不走
            self.snapshot_oversized = true
            return nil
        end
    end
    local entries = {}
    local seen = 0
    local stack = { { node = self.root, path = "" } }
    while #stack > 0 do
        local frame = table.remove(stack)
        local node, path = frame.node, frame.path
        if max_chars ~= nil and node.parent ~= nil then
            seen = seen + #node.text
            if seen * SNAPSHOT_JSON_SLACK > max_chars then
                self.snapshot_oversized = true
                return nil
            end
        end
        local full = path .. node.text
        for tenant, epoch in pairs(node.tenant_last_access) do
            if is_leaf_for(node, tenant) then
                if #entries >= SNAPSHOT_MAX_ENTRIES then
                    self.snapshot_oversized = true
                    return nil
                end
                if max_chars ~= nil
                    and (seen + #tenant + SNAPSHOT_URL_ALLOWANCE)
                        * SNAPSHOT_JSON_SLACK > max_chars then
                    self.snapshot_oversized = true
                    return nil
                end
                entries[#entries + 1] = { t = full, tnt = tenant, e = epoch }
            end
        end
        for _, child in pairs(node.children) do
            stack[#stack + 1] = { node = child, path = full }
        end
    end
    table.sort(entries, function(a, b) return a.e < b.e end)
    self.snapshot_oversized = false
    return { leaves = entries, epoch = epoch_counter }
end

--- 从快照恢复（就地重建树内容）
function Tree:restore(snapshot)
    if type(snapshot) ~= "table" or type(snapshot.leaves) ~= "table" then
        return
    end
    self.root = new_node("", nil)
    self.tenant_char_count = {}
    -- restore 换掉整棵树，增量计数必须一起归零：下面的 insert 回放会给新节点重新记一次，
    -- 不重置就等于把旧账加在新树上（live_nodes 虚高 -> 节点闸误触发、gauge 也不可信）。
    self.live_nodes = 0
    self.live_chars = 0
    self.node_evict_stalled = false
    local max_epoch = 0
    local entries = {}
    for i = 1, #snapshot.leaves do
        entries[i] = snapshot.leaves[i]
    end
    table.sort(entries, function(a, b)
        return (tonumber(a.e) or 0) < (tonumber(b.e) or 0)
    end)
    for i = 1, #entries do
        local item = entries[i]
        local epoch = tonumber(item.e)
        if epoch and epoch > max_epoch then
            max_epoch = epoch
        end
        self:insert(item.t or item.text, item.tnt or item.tenant, epoch)
    end
    _M.bump_epoch(max_epoch)
    if type(snapshot.epoch) == "number" then
        _M.bump_epoch(snapshot.epoch)
    end
end

return _M
