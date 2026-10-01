-- 前缀哈希路由策略：对齐 gateway/src/policies/prefix_hash.rs 的
-- PrefixHashPolicy::select_worker_impl，环复用 consistent_hashing 用的同一个
-- （hash.new_ring / hash.lookup_position）。
--
-- 两处必要偏差：
--   1. Rust 对 token 序列哈希，HTTP 路径 tokens 恒为 None（router.rs / pd_router.rs
--      写死 "HTTP doesn't have tokens, use gRPC for PrefixHash"），所以 Rust 在 HTTP
--      下总是返回 NoTokens。这里用「请求文本前 N 个字符」近似 token 前缀，
--      让 HTTP 路径也能用（info.request_text，由 policies/utils 的
--      extract_text_for_routing 提供）。
--   2. Rust 用 xxh3_64；这里用已实现的 BLAKE3 前 8 字节小端 u64（见下方
--      compute_prefix_hash 的注释）。Rust 把 u64 渲染成 16 位 hex 字符串再让环
--      对它做一次 blake3，这里直接把位置交给 hash.lookup_position，省掉那一次
--      哈希，语义等价（同一前缀 → 同一位置）。
--
-- 纯 Lua，不依赖 ngx。

local hash = require "resty.luarouter.hash"
local utils = require "resty.luarouter.policies.utils"

local healthy_indices = utils.healthy_indices

local _M = {}

local DEFAULTS = {
    prefix_token_count = 256,   -- 字符数（Rust 侧是 token 数）
    load_factor = 1.25,
}
_M.DEFAULTS = DEFAULTS

--------------------------------------------------------------------------
-- Policy
--------------------------------------------------------------------------

local PrefixHash = {}
PrefixHash.__index = PrefixHash
_M.PrefixHash = PrefixHash

_M.Branch = {
    NO_HEALTHY_WORKERS = "no_healthy_workers",
    NO_TOKENS = "no_tokens",
    RING_HIT = "ring_hit",
    LOAD_BALANCE_WALK = "load_balance_walk",
    FALLBACK_LEAST_LOAD = "fallback_least_load",
}

function _M.new(config, rng)
    local cfg = {}
    for k, v in pairs(DEFAULTS) do
        cfg[k] = v
    end
    if type(config) == "table" then
        for k, v in pairs(config) do
            if cfg[k] ~= nil then
                if type(cfg[k]) == "number" then
                    v = tonumber(v) or cfg[k]
                end
                cfg[k] = v
            end
        end
    end
    local self = setmetatable({}, PrefixHash)
    self.config = cfg
    self.rings = {}
    self.rng = rng or utils.default_rng
    return self
end

function PrefixHash:name()
    return "prefix_hash"
end

-- 本策略靠文本选 worker（Rust 靠 tokens，needs_request_text 返回 false；
-- 我们改用文本，所以必须声明需要文本，框架才会把 request_text 传进来）
function PrefixHash:needs_request_text()
    return true
end

--- 前缀哈希 → 环位置 (hi, lo)。
---
--- 对齐 Rust 的「取前缀、哈希成 u64、format!("{:016x}") 当 key」这条链路：
---   Rust: xxh3_64(bytemuck::cast_slice(&tokens[..min(len, N)]))
---   这里: blake3(utf8_head(text, N))[..8] 小端 u64
--- 换成 blake3 的原因见文件头偏差 2；渲染成 16 位 hex 再走环，与 Rust 一样
--- 保证「同一前缀 → 同一字符串 key → 同一环位置」。
function PrefixHash:compute_prefix_hash(text)
    local prefix = utils.utf8_head(text, self.config.prefix_token_count)
    return hash.position(prefix)
end

--- 对齐 load_ok：total == 0 或 n == 0 时一律放行。
--- 平均负载按 (total + 1) / n 计，+1 是把正在路由的这条请求算进去。
function PrefixHash:load_ok(worker_load, total_load, num_workers)
    if total_load == 0 or num_workers == 0 then
        return true
    end
    local threshold = ((total_load + 1) / num_workers) * self.config.load_factor
    return worker_load <= threshold
end

local function ring_slot(self, workers, tree_key)
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

--- 对齐 find_worker_with_load_balance。返回下标 + 分支名。
function PrefixHash:find_worker_with_load_balance(workers, healthy, ring, hi, lo)
    local Branch = _M.Branch

    -- 只统计健康 worker 的负载（Rust 用 healthy_workers 求和）
    local total_load = 0
    for i = 1, #healthy do
        total_load = total_load + utils.worker_load(workers[healthy[i]])
    end
    local num_workers = #healthy

    local healthy_set = {}
    for i = 1, #healthy do
        healthy_set[healthy[i]] = true
    end

    if ring ~= nil and ring.count > 0 then
        local first = hash.lookup_position(ring, hi, lo, function(w)
            return healthy_set[w] == true
        end)
        if first ~= nil then
            local first_load = utils.worker_load(workers[first])
            if self:load_ok(first_load, total_load, num_workers) then
                return first, Branch.RING_HIT
            end
            -- 首站过载：在满足 load_ok 的健康 worker 里取 load 最小者（严格 <
            -- 使并列时取最小下标，对齐 Rust min_by_key 的首个最小值语义）
            local best_idx, best_load
            for i = 1, #healthy do
                local idx = healthy[i]
                local load = utils.worker_load(workers[idx])
                if self:load_ok(load, total_load, num_workers) then
                    if best_load == nil or load < best_load then
                        best_load = load
                        best_idx = idx
                    end
                end
            end
            if best_idx ~= nil then
                return best_idx, Branch.LOAD_BALANCE_WALK
            end
            -- 全部过载：仍用首站（Rust 也是 return (Some(idx), LoadBalanceWalk)）
            return first, Branch.LOAD_BALANCE_WALK
        end
    end

    -- 环不可用 / 环上找不到健康 worker：退化为最小负载。严格 < 保证并列时取
    -- 下标最小者，与 Rust min_by_key 取首个最小值的语义一致。
    local best_idx, best_load
    for i = 1, #healthy do
        local idx = healthy[i]
        local load = utils.worker_load(workers[idx])
        if best_load == nil or load < best_load then
            best_load = load
            best_idx = idx
        end
    end
    return best_idx, Branch.FALLBACK_LEAST_LOAD
end

--- 返回 1-based 下标或 nil。info: { request_text = string|nil }
function PrefixHash:select_worker_impl(workers, info)
    local Branch = _M.Branch
    if type(workers) ~= "table" or #workers == 0 then
        return nil, Branch.NO_HEALTHY_WORKERS
    end

    local text = (type(info) == "table") and info.request_text or nil
    if type(text) ~= "string" or text == "" then
        -- Rust 在 tokens 为 None/空时返回 NoTokens；空文本同理（哈希空串会把
        -- 所有无文本请求挤到同一个 worker）
        return nil, Branch.NO_TOKENS
    end

    local healthy = healthy_indices(workers)
    if #healthy == 0 then
        return nil, Branch.NO_HEALTHY_WORKERS
    end

    local first = workers[healthy[1]]
    local tree_key = utils.worker_pool(first) .. "::" .. utils.worker_model_id(first)
    local ring = ring_slot(self, workers, tree_key)

    local hi, lo = self:compute_prefix_hash(text)
    return self:find_worker_with_load_balance(workers, healthy, ring, hi, lo)
end

function PrefixHash:select_worker(workers, info)
    local idx = self:select_worker_impl(workers, info)
    return idx
end

--- worker 集合由外部直接维护时（没有常驻 registry）用于强制重建环
function PrefixHash:invalidate_rings()
    self.rings = {}
end

return _M
