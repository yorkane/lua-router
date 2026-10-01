-- Cache-aware 路由策略：前缀树亲和 + 最短队列逃逸，逐分支对齐
-- gateway/src/policies/cache_aware.rs 的 CacheAwarePolicy::select_worker。
--
-- 与 Rust 的差异（详见 doc/impl-policies.md）：
--   * 无 mesh 同步、无跨进程共享：每 nginx worker 各持一棵树。
--   * 无后台线程：淘汰由外部 init_worker 定时器调用 M.evict_all()，或 select 时懒触发。
--   * 失衡判定用「min load 并列随机」与 Rust IteratorRandom::choose 对齐。

local utils = require "resty.luarouter.policies.utils"
local tree_mod = require "resty.luarouter.policies.tree"

local healthy_indices = utils.healthy_indices
local min_max = utils.min_max

local _M = {}

local DEFAULTS = {
    cache_threshold = 0.5,
    balance_abs_threshold = 32,
    balance_rel_threshold = 1.1,
    eviction_interval_secs = 30,
    max_tree_size = 10000,
}

_M.DEFAULTS = DEFAULTS

--------------------------------------------------------------------------
-- 树 key：pool::model（对齐 make_tree_key / tree_key_for_worker）
--------------------------------------------------------------------------

local function make_tree_key(pool, model)
    return pool .. "::" .. utils.normalize_model_key(model)
end

_M.make_tree_key = make_tree_key

--------------------------------------------------------------------------
-- Policy
--------------------------------------------------------------------------

local CacheAware = {}
CacheAware.__index = CacheAware

_M.CacheAware = CacheAware

--- config 字段见 DEFAULTS；可选注入 rng（单测用），worker_text_seen 记录请求文本插入历史
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

    local self = setmetatable({}, CacheAware)
    self.config = cfg
    self.trees = {}         -- tree_key -> Tree
    self.rng = rng or utils.default_rng
    return self
end

function CacheAware:get_or_create_tree(tree_key)
    local tree = self.trees[tree_key]
    if tree == nil then
        tree = tree_mod.new()
        self.trees[tree_key] = tree
    end
    return tree
end

local function tree_for_worker(self, w)
    return self:get_or_create_tree(make_tree_key(utils.worker_pool(w), utils.worker_model_id(w)))
end

--- worker 注册：向各自树插入空文本（对齐 init_workers / add_worker）
function CacheAware:add_worker(w)
    local tree = tree_for_worker(self, w)
    tree:insert("", utils.worker_url(w))
end

--- 全量重置 worker 列表（对齐 init_workers：会重建每池的租户集合）
function CacheAware:init_workers(workers)
    for i = 1, #workers do
        self:add_worker(workers[i])
    end
end

--- worker 摘除（按对象带的 pool/model 定位单树，对齐 remove_worker）
function CacheAware:remove_worker(w)
    local tree_key = make_tree_key(utils.worker_pool(w), utils.worker_model_id(w))
    local tree = self.trees[tree_key]
    if tree ~= nil then
        tree:remove_tenant(utils.worker_url(w))
    end
end

--- 仅按 URL 摘除：扫所有树（对齐 remove_worker_by_url 的向后兼容行为）
function CacheAware:remove_worker_by_url(url)
    for _, tree in pairs(self.trees) do
        tree:remove_tenant(url)
    end
end

--- 定时淘汰全部树（由 init_worker 定时器调用，对齐 PeriodicTask 里的 eviction 线程）
function CacheAware:evict_all(max_tree_size)
    local max_size = max_tree_size or self.config.max_tree_size
    for _, tree in pairs(self.trees) do
        tree:evict_tenant_by_size(max_size)
    end
end

--- 失衡时选 min load（并列随机），并且【同样写树】（对齐 select_worker_min_load）
function CacheAware:_select_worker_min_load(workers, request_text, healthy, tree_key)
    local load_of = function(idx)
        return utils.worker_load(workers[idx])
    end
    local idx = utils.min_load_index(healthy, load_of, self.rng)
    if idx == nil then
        return nil
    end

    if request_text then
        local tree = self.trees[tree_key]
        if tree ~= nil then
            tree:insert(request_text, utils.worker_url(workers[idx]))
        end
    end
    return idx
end

--- 对齐 CacheAwarePolicy::select_worker。返回 1-based 下标或 nil。
--- workers: 对象数组（字段/方法见 utils 的访问器）
--- info:    { request_text = string|nil }
function CacheAware:select_worker(workers, info)
    local request_text = (type(info) == "table") and info.request_text or nil
    if type(request_text) ~= "string" then
        request_text = nil
    end

    local healthy = healthy_indices(workers)
    if #healthy == 0 then
        return nil
    end

    -- 同一批 worker 已由上层按 (pool, model) 预筛，用首个健康 worker 定树 key
    local tree_key = make_tree_key(utils.worker_pool(workers[healthy[1]]),
        utils.worker_model_id(workers[healthy[1]]))

    local loads = {}
    for i = 1, #workers do
        loads[i] = utils.worker_load(workers[i])
    end
    local min_load, max_load = min_max(loads)
    if min_load == nil then
        min_load = 0
    end
    if max_load == nil then
        max_load = 0
    end

    local is_imbalanced = (max_load - min_load) > self.config.balance_abs_threshold
        and max_load > min_load * self.config.balance_rel_threshold

    if is_imbalanced then
        return self:_select_worker_min_load(workers, request_text, healthy, tree_key)
    end

    local text = request_text or ""
    local tree = self.trees[tree_key]

    if tree == nil then
        -- 对齐 Rust 的 warn + 随机（树未被播种时亲和失效）
        local pick = self.rng(#healthy)
        if type(pick) ~= "number" or pick < 1 or pick > #healthy then
            pick = 1
        end
        return healthy[math.floor(pick)]
    end

    local tenant, matched_chars, input_chars = tree:prefix_match_with_counts(text)
    local match_rate = 0
    if input_chars > 0 then
        match_rate = matched_chars / input_chars
    end

    local selected_idx
    if match_rate > self.config.cache_threshold then
        -- 命中缓存：先按 URL 定位（Rust 的 position 取首个匹配），再单独判健康。
        -- 同名 URL 的 worker 只要第一个不健康就按脏租户处理，与 Rust 完全一致。
        for i = 1, #workers do
            if utils.worker_url(workers[i]) == tenant then
                if utils.worker_healthy(workers[i]) then
                    selected_idx = i
                end
                break
            end
        end
    else
        -- 低匹配：min load（并列随机），只在健康集合里选
        selected_idx = utils.min_load_index(healthy, function(idx)
            return utils.worker_load(workers[idx])
        end, self.rng)
    end

    if selected_idx ~= nil then
        tree:insert(text, utils.worker_url(workers[selected_idx]))
        return selected_idx
    end

    -- 选中的 worker 已不存在 / 不健康：清掉脏租户
    if match_rate > self.config.cache_threshold then
        tree:remove_tenant(tenant)
    end

    return healthy[1]
end

function CacheAware:name()
    return "cache_aware"
end

function CacheAware:needs_request_text()
    return true
end

--- 快照 / 恢复（per-process 表 + lr_policy JSON 落盘用）
function CacheAware:serialize()
    local trees = {}
    for key, tree in pairs(self.trees) do
        trees[key] = tree:serialize()
    end
    return { policy = "cache_aware", trees = trees }
end

function CacheAware:restore(snapshot)
    if type(snapshot) ~= "table" or type(snapshot.trees) ~= "table" then
        return
    end
    for key, snap in pairs(snapshot.trees) do
        local tree = self:get_or_create_tree(key)
        tree:restore(snap)
    end
end

--- 快照 → JSON 文本（无 cjson 时返回 nil，调用方降级为不落盘）
function CacheAware:encode_snapshot(max_bytes)
    local ok_cjson, cjson = pcall(require, "cjson.safe")
    if not ok_cjson then
        return nil
    end
    local text = cjson.encode(self:serialize())
    if type(text) ~= "string" then
        return nil
    end
    if max_bytes and #text > max_bytes then
        return nil            -- 树太大：放弃本次落盘，等淘汰后再试
    end
    return text
end

--- JSON 文本 → 快照并合并进本进程树。返回 true 表示确实恢复了内容
function CacheAware:decode_snapshot(text)
    if type(text) ~= "string" or text == "" then
        return false
    end
    local ok_cjson, cjson = pcall(require, "cjson.safe")
    if not ok_cjson then
        return false
    end
    local snapshot = cjson.decode(text)
    if type(snapshot) ~= "table" then
        return false
    end
    self:restore(snapshot)
    return true
end

--- 调试：树规模
function CacheAware:tree_size(tree_key)
    local tree = self.trees[tree_key]
    if tree == nil then
        return 0
    end
    return tree:node_count()
end

function CacheAware:tenant_char_count(tree_key)
    local tree = self.trees[tree_key]
    if tree == nil then
        return {}
    end
    return tree:get_tenant_char_count()
end

return _M
