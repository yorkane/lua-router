-- 一致性哈希路由策略：逐分支对齐 gateway/src/policies/consistent_hashing.rs
-- 的 ConsistentHashingPolicy::select_worker_impl；环的实现见 luarouter/hash.lua
-- （对齐 core/worker_registry.rs 的 HashRing）。
--
-- 优先级与 Rust 完全一致，前两条命中后不回退：
--   1. x-smg-target-worker: <0-based 下标> → 直接数组下标；解析失败/越界/不健康 → nil
--   2. x-smg-routing-key → 环 lookup
--   3. 隐式 key：authorization → x-forwarded-for → cookie（第一个非空者）
--   4. 都没有 → 健康 worker 随机
--
-- 纯 Lua，不依赖 ngx，luajit 可直接跑单测。headers 允许是 ngx.req.get_headers()
-- 的表（自带大小写不敏感 __index）或普通 Lua 表。

local hash = require "resty.luarouter.hash"
local utils = require "resty.luarouter.policies.utils"

local healthy_indices = utils.healthy_indices

local _M = {}

--------------------------------------------------------------------------
-- headers
--------------------------------------------------------------------------

-- ngx 的 header 表按 lowercase 直接命中；普通 Lua 表可能保留了原始大小写，
-- 所以再线性扫一遍兜底（每请求最多 4 次，header 数量小）。
local function get_header(headers, name)
    if type(headers) ~= "table" then
        return nil
    end
    local v = headers[name]
    if v == nil then
        v = headers[name:upper()]
    end
    if v == nil then
        for k, value in pairs(headers) do
            if type(k) == "string" and k:lower() == name then
                v = value
                break
            end
        end
    end
    if type(v) ~= "string" or v == "" then
        return nil
    end
    return v
end
_M.get_header = get_header

--- 对齐 Rust 的 str::parse::<usize>()：只接受可选 '+' 前缀后的纯数字，
--- 不允许空白、负号或小数点。先去掉前导零再判长度，这样 "0000...0001"
--- 这种 Rust 能解析的值照样解析；剩下的超过 15 位就一定 > 2^53，
--- Lua double 装不下精确值——但那种下标在任何真实拓扑里必然越界，
--- 统一按解析失败处理（Rust 那边也是 None → target_worker_miss）。
local function parse_index(s)
    if type(s) ~= "string" then
        return nil
    end
    local digits = s:match("^%+(%d+)$") or s:match("^(%d+)$")
    if digits == nil then
        return nil
    end
    digits = digits:gsub("^0+", "")
    if digits == "" then
        return 0                              -- 全零（"0"、"000"）
    end
    if #digits > 15 then
        return nil
    end
    return tonumber(digits)
end
_M.parse_index = parse_index

--------------------------------------------------------------------------
-- Policy
--------------------------------------------------------------------------

local ConsistentHashing = {}
ConsistentHashing.__index = ConsistentHashing
_M.ConsistentHashing = ConsistentHashing

-- 执行分支名，对齐 Rust 的 Branch::as_str（供 metrics 与单测断言）
_M.Branch = {
    NO_HEALTHY_WORKERS = "no_healthy_workers",
    TARGET_WORKER_HIT = "target_worker_hit",
    TARGET_WORKER_MISS = "target_worker_miss",
    ROUTING_KEY_HIT = "routing_key_hit",
    RANDOM_FALLBACK = "random_fallback",
}

function _M.new(config, rng)
    local self = setmetatable({}, ConsistentHashing)
    self.rings = {}     -- pool::model -> { signature, ring }（由 hash.ring_cached 维护）
    self.rng = rng or utils.default_rng
    return self
end

function ConsistentHashing:name()
    return "consistent_hashing"
end

function ConsistentHashing:needs_request_text()
    return false
end

--- 环按 (pool, model) 分桶缓存，URL 集合变化时才重建。
--- Rust 把环存在 WorkerRegistry.hash_rings，由 register/remove 触发重建；
--- 这里没有常驻 registry，改用 URL 列表签名等价判定拓扑是否变化。
--- 环覆盖【全部】worker（含不健康的），健康与否在 lookup 时过滤——这点和
--- Rust 一致：HashRing::new 收的是整个 worker 列表，find_healthy_url 才判健康。
function ConsistentHashing:ring_for(workers, tree_key)
    local urls = {}
    for i = 1, #workers do
        urls[i] = utils.worker_url(workers[i])
    end
    local slot = self.rings[tree_key]
    if slot == nil then
        slot = {}
        self.rings[tree_key] = slot
    end
    return hash.ring_cached(slot, urls)
end

--- 对齐 find_by_consistent_hash：环顺时针找到第一个健康 worker 的下标，
--- 全不健康 → nil。Rust 靠「健康 URL → 下标」的 HashMap 回调判健康，这里环
--- 下标就是 workers 下标，用一个 set 回调即可。
function ConsistentHashing:find_by_consistent_hash(ring, key, healthy_set)
    return hash.lookup(ring, key, function(w)
        return healthy_set[w] == true
    end)
end

--- 返回 1-based 下标 + 分支名。info: { headers = tbl|nil }
function ConsistentHashing:select_worker_impl(workers, info)
    local Branch = _M.Branch
    if type(workers) ~= "table" or #workers == 0 then
        return nil, Branch.NO_HEALTHY_WORKERS
    end

    local headers = (type(info) == "table") and info.headers or nil

    -- Priority 1: x-smg-target-worker。Rust 在算健康列表之前就处理它，
    -- 且失败直接返回 None（不回退到哈希）。
    local target = get_header(headers, "x-smg-target-worker")
    if target ~= nil then
        local idx = parse_index(target)
        if idx ~= nil and idx < #workers then
            local w = workers[idx + 1]
            if utils.worker_healthy(w) and utils.worker_can_execute(w) then
                return idx + 1, Branch.TARGET_WORKER_HIT
            end
        end
        return nil, Branch.TARGET_WORKER_MISS
    end

    local healthy = healthy_indices(workers)
    if #healthy == 0 then
        return nil, Branch.NO_HEALTHY_WORKERS
    end

    local first = workers[healthy[1]]
    local tree_key = utils.worker_pool(first) .. "::" .. utils.worker_model_id(first)
    local ring = self:ring_for(workers, tree_key)

    local healthy_set = {}
    for i = 1, #healthy do
        healthy_set[healthy[i]] = true
    end

    -- Priority 2: x-smg-routing-key
    local key = get_header(headers, "x-smg-routing-key")
    if key ~= nil then
        local w = self:find_by_consistent_hash(ring, key, healthy_set)
        if w == nil then
            return nil, Branch.NO_HEALTHY_WORKERS
        end
        return w, Branch.ROUTING_KEY_HIT
    end

    -- Priority 3: 隐式 key（会话亲和）
    local implicit = get_header(headers, "authorization")
        or get_header(headers, "x-forwarded-for")
        or get_header(headers, "cookie")
    if implicit ~= nil then
        local w = self:find_by_consistent_hash(ring, implicit, healthy_set)
        if w == nil then
            return nil, Branch.NO_HEALTHY_WORKERS
        end
        return w, Branch.ROUTING_KEY_HIT
    end

    -- Fallback: 健康 worker 等概率随机（真实匿名客户端）
    local pick = self.rng(#healthy)
    if type(pick) ~= "number" or pick < 1 or pick > #healthy then
        pick = 1
    end
    return healthy[math.floor(pick)], Branch.RANDOM_FALLBACK
end

function ConsistentHashing:select_worker(workers, info)
    local idx = self:select_worker_impl(workers, info)
    return idx
end

--- 没有常驻 registry 时，供框架显式失效环缓存
function ConsistentHashing:invalidate_rings()
    self.rings = {}
end

return _M
