-- 按请求字符长度分桶的路由策略，对齐 gateway/src/policies/bucket.rs 的 BucketPolicy。
--
-- 要点：
--   * l_max = 4096，按 worker 数均分边界，最后一个桶上界为 inf（Lua 用大整数代替 usize::MAX）。
--   * select：二分找桶；失衡（abs + rel 双阈值，rel 默认 1.0001）改选 chars 最小的 worker；
--     桶缺失/边界缺失退化为健康 worker 随机。
--   * post_process_request：把请求塞进滑动窗口，过期请求按 url 扣减 chars_per_url（时间衰减）。
--   * adjust_boundary：由外部定时器按 bucket_adjust_interval_secs 调用。
--
-- 与 Rust 差异：每 (model) 一个桶状态为 per-process 表；request id 用自增序号代替 Uuid。

local utils = require "resty.luarouter.policies.utils"

local utf8_len = utils.utf8_len
local INF_BOUND = utils.INF_BOUND

local _M = {}

local DEFAULTS = {
    balance_abs_threshold = 32,
    balance_rel_threshold = 1.0001,
    bucket_adjust_interval_secs = 5,
}

_M.DEFAULTS = DEFAULTS

--------------------------------------------------------------------------
-- Bucket 状态机
--------------------------------------------------------------------------

local Bucket = {}
Bucket.__index = Bucket

_M.Bucket = Bucket

--- period_ms：滑动窗口长度（Rust: bucket_adjust_interval_secs * 1000）
function Bucket.new(period_ms)
    local self = setmetatable({}, Bucket)
    self.l_max = 4096
    self.bucket_cnt = 0
    self.period = period_ms or 5000
    self.load_total = 0
    self.bucket_load = 0
    self.boundary = {}                -- { {url=..., range={min,max}}, ... }（按 min 升序）
    self.prefill_worker_urls = {}
    self.request_list = {}            -- 滑动窗口（FIFO）
    self.request_head = 1
    self.t_req_loads = {}             -- id -> char_cnt
    self.chars_per_url = {}           -- url -> chars
    self.seq = 0
    return self
end

function Bucket:init_worker_urls(urls)
    local worker_urls = {}
    for i = 1, #urls do
        worker_urls[i] = urls[i]
    end
    self.bucket_cnt = #worker_urls
    self.prefill_worker_urls = worker_urls

    self.chars_per_url = {}
    for i = 1, #worker_urls do
        self.chars_per_url[worker_urls[i]] = 0
    end

    local worker_cnt = self.bucket_cnt
    if worker_cnt == 0 then
        self.boundary = {}
        return
    end

    local gap = math.floor(self.l_max / worker_cnt)
    self.l_max = INF_BOUND
    local boundary = {}
    for i = 1, worker_cnt do
        local min = (i - 1) * gap
        local max
        if i == worker_cnt then
            max = INF_BOUND
        else
            max = i * gap - 1
        end
        boundary[i] = { url = worker_urls[i], range = { min, max } }
    end
    self.boundary = boundary
end

--- 桶内二分查找（对齐 Rust find_boundary：闭区间 [range[0], range[1]]）
function Bucket:find_boundary(char_count)
    local left, right = 1, #self.boundary + 1   -- right 为开区间上界
    while left < right do
        local mid = left + math.floor((right - left) / 2)
        local range = self.boundary[mid].range
        if char_count < range[1] then
            right = mid
        elseif char_count > range[2] then
            left = mid + 1
        else
            return self.boundary[mid].url
        end
    end
    return nil
end

--- 请求进滑动窗口 + 过期扣减（时间衰减），对齐 post_process_request
function Bucket:post_process_request(char_cnt, prefill_url)
    local bucket = self.chars_per_url
    bucket[prefill_url] = (bucket[prefill_url] or 0) + char_cnt

    local now = self:now_ms()
    local window = self.period
    local removed_load = 0

    while self.request_head <= #self.request_list do
        local req = self.request_list[self.request_head]
        if (now - req.timestamp) <= window then
            break
        end
        self.request_head = self.request_head + 1
        self.t_req_loads[req.id] = nil
        removed_load = removed_load + req.char_cnt
        local cur = bucket[req.prefill_worker_url]
        if cur ~= nil then
            local next_val = cur - req.char_cnt
            bucket[req.prefill_worker_url] = next_val > 0 and next_val or 0
        end
    end

    self.load_total = self.load_total - removed_load
    if self.load_total < 0 then
        self.load_total = 0
    end

    -- 窗口全部过期后压缩一次，避免数组无限增长
    if self.request_head > 64 and self.request_head * 2 > #self.request_list then
        local rest = {}
        for i = self.request_head, #self.request_list do
            rest[#rest + 1] = self.request_list[i]
        end
        self.request_list = rest
        self.request_head = 1
    end

    self.seq = self.seq + 1
    local id = "req-" .. self.seq
    self.t_req_loads[id] = char_cnt
    self.request_list[#self.request_list + 1] = {
        id = id,
        char_cnt = char_cnt,
        timestamp = now,
        prefill_worker_url = prefill_url,
    }
    self.load_total = self.load_total + char_cnt
end

--- 可注入时钟（单测 / 集成测试要验证滑动窗口衰减时用），默认 utils.now_ms
function Bucket:now_ms()
    local clock = self.clock
    if type(clock) == "function" then
        return clock()
    end
    return utils.now_ms()
end

function Bucket:set_clock(fn)
    self.clock = fn
end

function Bucket:get_total_load()
    return self.load_total
end

function Bucket:update_workers_cnt()
    self.bucket_cnt = #self.prefill_worker_urls

    local current = {}
    for url in pairs(self.chars_per_url) do
        current[url] = true
    end
    local new_urls = {}
    for i = 1, #self.prefill_worker_urls do
        local url = self.prefill_worker_urls[i]
        new_urls[url] = true
        if self.chars_per_url[url] == nil then
            self.chars_per_url[url] = 0
        end
    end
    for url in pairs(current) do
        if not new_urls[url] and self.chars_per_url[url] == 0 then
            self.chars_per_url[url] = nil
        end
    end
end

--- 负载漂移超过 2 倍才重建边界（对齐 adjust_boundary 的迟滞判断）
function Bucket:adjust_boundary()
    if next(self.t_req_loads) == nil then
        return
    end

    self:update_workers_cnt()
    local worker_cnt = self.bucket_cnt
    if worker_cnt == 0 then
        return
    end

    local new_single_bucket_load = math.floor(self.load_total / worker_cnt)
    local old_single_bucket_load = self.bucket_load
    if new_single_bucket_load <= 2 * old_single_bucket_load
        and (old_single_bucket_load <= 2 * new_single_bucket_load and old_single_bucket_load ~= 0) then
        return
    end

    self.bucket_load = new_single_bucket_load

    local hist_load = {}
    for _, load in pairs(self.t_req_loads) do
        hist_load[#hist_load + 1] = load
    end
    table.sort(hist_load)

    local new_boundary = {}
    local upper_bound = 0
    local last_load_index = 1
    local urls = self.prefill_worker_urls

    for i = 1, worker_cnt do
        local url = urls[i]
        local is_last = (i == worker_cnt)

        if last_load_index > #hist_load and is_last then
            new_boundary[#new_boundary + 1] = { url = url, range = { upper_bound, INF_BOUND } }
            break
        end

        local load_accumulator = 0
        local break_flag = false
        local j = last_load_index
        while j <= #hist_load do
            local load = hist_load[j]
            load_accumulator = load_accumulator + load
            if load_accumulator >= new_single_bucket_load then
                if is_last then
                    new_boundary[#new_boundary + 1] = { url = url, range = { upper_bound, INF_BOUND } }
                    break_flag = true
                    break
                end
                local real_load = upper_bound + new_single_bucket_load
                if load <= upper_bound then
                    new_boundary[#new_boundary + 1] = { url = url, range = { upper_bound, real_load } }
                    upper_bound = real_load + 1
                else
                    new_boundary[#new_boundary + 1] = { url = url, range = { upper_bound, load } }
                    upper_bound = load + 1
                end
                last_load_index = last_load_index + 1
                break_flag = true
                break
            else
                last_load_index = last_load_index + 1
            end
            j = j + 1
        end

        if not break_flag then
            local right_bound_value = upper_bound + new_single_bucket_load
            if is_last then
                right_bound_value = INF_BOUND
                new_boundary[#new_boundary + 1] = { url = url, range = { upper_bound, right_bound_value } }
                break
            end
            new_boundary[#new_boundary + 1] = { url = url, range = { upper_bound, right_bound_value } }
            upper_bound = right_bound_value + 1
        end
    end

    self.boundary = new_boundary
end

--------------------------------------------------------------------------
-- Policy
--------------------------------------------------------------------------

local BucketPolicy = {}
BucketPolicy.__index = BucketPolicy

_M.BucketPolicy = BucketPolicy

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

    local self = setmetatable({}, BucketPolicy)
    self.config = cfg
    self.buckets = {}        -- model_key -> Bucket
    self.rng = rng or utils.default_rng
    return self
end

local function seeded_bucket(self, period_ms)
    local b = Bucket.new(period_ms)
    if type(self.clock) == "function" then
        b:set_clock(self.clock)
    end
    return b
end

local function bucket_key(model_id)
    return utils.normalize_model_key(model_id)
end

function BucketPolicy:get_bucket(model_id, create)
    local key = bucket_key(model_id)
    local bucket = self.buckets[key]
    if bucket == nil and create then
        bucket = seeded_bucket(self, self.config.bucket_adjust_interval_secs * 1000)
        self.buckets[key] = bucket
    end
    return bucket
end

--- 对齐 init_prefill_worker_urls：为该 model 建立 worker 边界
function BucketPolicy:init_worker_urls(workers)
    local by_model = {}
    for i = 1, #workers do
        local w = workers[i]
        local key = bucket_key(utils.worker_model_id(w))
        local list = by_model[key]
        if list == nil then
            list = {}
            by_model[key] = list
        end
        list[#list + 1] = utils.worker_url(w)
    end
    for key, urls in pairs(by_model) do
        local bucket = self:get_bucket(key, true)
        bucket:init_worker_urls(urls)
    end
end

function BucketPolicy:add_worker(w)
    local key = bucket_key(utils.worker_model_id(w))
    local bucket = self:get_bucket(key, true)
    local url = utils.worker_url(w)
    local exists = false
    for i = 1, #bucket.prefill_worker_urls do
        if bucket.prefill_worker_urls[i] == url then
            exists = true
            break
        end
    end
    if not exists then
        bucket.prefill_worker_urls[#bucket.prefill_worker_urls + 1] = url
    end
    if bucket.chars_per_url[url] == nil then
        bucket.chars_per_url[url] = 0
    end
    bucket:init_worker_urls(bucket.prefill_worker_urls)
end

function BucketPolicy:remove_worker(w)
    local key = bucket_key(utils.worker_model_id(w))
    local bucket = self.buckets[key]
    if bucket == nil then
        return
    end
    local url = utils.worker_url(w)
    local rest = {}
    for i = 1, #bucket.prefill_worker_urls do
        local item = bucket.prefill_worker_urls[i]
        if item ~= url then
            rest[#rest + 1] = item
        end
    end
    bucket:init_worker_urls(rest)
end

--- 给该 model 下所有桶装同一个时钟（测试用）
function BucketPolicy:set_clock(fn)
    self.clock = fn
    for _, b in pairs(self.buckets) do
        b:set_clock(fn)
    end
end

--- 定时重算边界（对齐 with_config 里的后台线程）
function BucketPolicy:adjust_all()
    for _, bucket in pairs(self.buckets) do
        bucket:adjust_boundary()
    end
end

local function random_healthy(self, healthy)
    return utils.choose(healthy, self.rng)
end

--- 对齐 BucketPolicy::select_worker：返回 1-based 下标或 nil
--- info: { request_text = string|nil }
function BucketPolicy:select_worker(workers, info)
    local healthy = utils.healthy_indices(workers)
    if #healthy == 0 then
        return nil
    end

    local request_text = (type(info) == "table") and info.request_text or nil
    local char_count = 0
    if type(request_text) == "string" then
        char_count = utf8_len(request_text)
    end

    local model_key = bucket_key(utils.worker_model_id(workers[healthy[1]]))
    local bucket = self.buckets[model_key]

    local chosen_url
    if bucket ~= nil then
        local urls = {}
        local snapshot = {}
        for url in pairs(bucket.chars_per_url) do
            urls[#urls + 1] = url
        end
        table.sort(urls)                    -- 让 min/max 与 min_url 的选择顺序确定

        local max_load, min_load = 0, 0
        for i = 1, #urls do
            local load = bucket.chars_per_url[urls[i]]
            snapshot[urls[i]] = load
            if i == 1 then
                max_load, min_load = load, load
            else
                if load > max_load then max_load = load end
                if load < min_load then min_load = load end
            end
        end

        local abs_diff = max_load - min_load
        local rel_threshold = self.config.balance_rel_threshold * min_load
        local is_imbalanced = abs_diff > self.config.balance_abs_threshold
            and max_load > rel_threshold

        if is_imbalanced then
            -- 失衡：选 chars 最小（并列取字典序最小，保证可复现）
            local best_url, best_chars
            for i = 1, #urls do
                local chars = snapshot[urls[i]]
                if best_chars == nil or chars < best_chars then
                    best_chars = chars
                    best_url = urls[i]
                end
            end
            chosen_url = best_url or utils.worker_url(workers[random_healthy(self, healthy)])
        else
            local found = bucket:find_boundary(char_count)
            if found ~= nil and found ~= "" then
                chosen_url = found
            else
                chosen_url = utils.worker_url(workers[random_healthy(self, healthy)])
            end
        end

        bucket:post_process_request(char_count, chosen_url)
    else
        chosen_url = utils.worker_url(workers[random_healthy(self, healthy)])
    end

    for i = 1, #workers do
        if utils.worker_url(workers[i]) == chosen_url then
            return i
        end
    end
    return nil
end

function BucketPolicy:name()
    return "bucket"
end

function BucketPolicy:needs_request_text()
    return true
end

_M.new_bucket = _M.Bucket.new

return _M
