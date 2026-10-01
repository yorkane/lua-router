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
    local epoch = next_epoch()
    if epoch % 8 == 0 then
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
local function detach_if_empty(node)
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
    if first ~= nil then
        node.parent.children[first] = nil
    end
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
        detach_if_empty(curr)

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
function Tree:evict_tenant_by_size(max_size)
    max_size = max_size or 0

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

    while pq:size() > 0 do
        local entry = pq:pop()
        local tenant, node = entry.tenant, entry.node

        local used = self.tenant_char_count[tenant]
        if used ~= nil and used <= max_size then
            goto continue
        end

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
        detach_if_empty(node)

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
function Tree:serialize()
    local entries = {}
    local stack = { { node = self.root, path = "" } }
    while #stack > 0 do
        local frame = table.remove(stack)
        local node, path = frame.node, frame.path
        local full = path .. node.text
        for tenant, epoch in pairs(node.tenant_last_access) do
            if is_leaf_for(node, tenant) then
                entries[#entries + 1] = { t = full, tnt = tenant, e = epoch }
            end
        end
        for _, child in pairs(node.children) do
            stack[#stack + 1] = { node = child, path = full }
        end
    end
    table.sort(entries, function(a, b) return a.e < b.e end)
    return { leaves = entries, epoch = epoch_counter }
end

--- 从快照恢复（就地重建树内容）
function Tree:restore(snapshot)
    if type(snapshot) ~= "table" or type(snapshot.leaves) ~= "table" then
        return
    end
    self.root = new_node("", nil)
    self.tenant_char_count = {}
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
