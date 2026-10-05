-- mesh.rate —— 全局限流窗口（PN counter + 窗口 id）。当前无生产调用者，
-- 按测绘结论整块保留（test/unit/test_mesh.lua 覆盖），退役与否后续单独定。
local _M = require "resty.luarouter.mesh"

local micros = require "resty.luarouter.mesh.crdt".priv.micros

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


return { priv = {} }
