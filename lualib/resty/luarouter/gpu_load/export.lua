local _M = require "resty.luarouter.gpu_load"
local seams = require "resty.luarouter.gpu_load.seams"

-- The live predicates live in seams.lua now; the sliced body below stays
-- byte-identical through these aliases.
local live_ngx = seams.live_ngx

local MAX_TIMER_DELAY = 3600
local LOCK_DICT = "lr_locks"
local TICK_LOCK = "gpu-load-tick"

-- gpu_load/export.lua -- the lr_stats registration points and the
-- self-rescheduling single-flight timer.  Only observability.counter/gauge
-- writes land here (lr_stats); the load samples themselves go through the
-- registry xl:/sl:/pw:/xany keys in seams.lua, and lr_watch stays the
-- watcher sole shdict.  SMG_LOAD_SOURCE=none writes no key and starts
-- no timer.  Moved verbatim.

---The pass that produced the current samples, for /_ui and the doc report.
local last_stats = nil
_M.last = function()
    return last_stats
end

---Registration points (doc/gap-gpu-load.md §6). Only observability.counter/gauge
---calls: the exporter renders whatever lands in lr_stats, so observability.lua is
---untouched and SMG_LOAD_SOURCE=none writes nothing at all.
---@param stats table
function _M.publish_metrics(stats)
    last_stats = stats
    if not live_ngx() then
        return false
    end
    local ok_obs, observability = pcall(require, "resty.luarouter.observability")
    if not ok_obs or type(observability) ~= "table" then
        return false
    end
    pcall(observability.counter, "lr_gpu_load_pass_total", {}, 1)
    if (stats.failed or 0) > 0 or (stats.errors or 0) > 0 then
        pcall(observability.counter, "lr_gpu_load_failures_total", {},
            (stats.failed or 0) + (stats.errors or 0))
    end
    if (stats.unmatched or 0) > 0 then
        pcall(observability.counter, "lr_gpu_load_unmatched_total", {},
            stats.unmatched)
    end
    pcall(observability.gauge, "lr_gpu_load_workers", {}, stats.matched or 0)
    -- 功率家族只在**启用**时导出：缺省关闭的实例上这些键保持 0，一个 series 都不
    -- 渲染（observability 的导出器会跳过空家族），所以 /metrics 与改动前逐字节一致，
    -- 契约门禁的 prometheus 段也不会突然多出一族没人解释的指标。
    if stats.power_enabled then
        pcall(observability.counter, "lr_gpu_load_power_samples_total", {},
            stats.power_matched or 0)
        -- 「解析失败」= 拨通了、查询发出去了，却拿不到可用瓦数：正文里没有功率 gauge、
        -- 或响应不是合法 PromQL 向量。skipped（worker url 解析不出 host，压根没法问）
        -- 刻意**不在**这一族里——它是配置问题，数量随坏 url 线性增长，混进来会淹没真
        -- 故障。error log 里的 warn_dedup class 把每种情形分开写。
        if (stats.power_failed or 0) > 0 or (stats.power_errors or 0) > 0 then
            pcall(observability.counter, "lr_gpu_load_power_parse_failures_total", {},
                (stats.power_failed or 0) + (stats.power_errors or 0))
        end
        -- registry 主动拒收（负值 / NaN / ±inf）：单独的族，因为它意味着 exporter
        -- 在撒谎而不是没数据，运维要查的是 exporter 而不是网络。
        if (stats.power_rejected or 0) > 0 then
            pcall(observability.counter, "lr_gpu_load_power_rejected_total", {},
                stats.power_rejected)
        end
        if (stats.power_unmatched or 0) > 0 then
            pcall(observability.counter, "lr_gpu_load_power_unmatched_total", {},
                stats.power_unmatched)
        end
        pcall(observability.gauge, "lr_gpu_load_power_workers", {},
            stats.power_matched or 0)
        -- 逐卡归属命中数（见 stats.power_per_card 的口径）。看板拿它和
        -- lr_gpu_load_power_workers 一比就知道有多少 worker 还骑在整机 max 上：
        -- 前者为 0 而后者非 0 = 逐卡归属一台都没接上（卡号没解析出来，或查询把
        -- gpu 聚合掉了），这正是需要在生产上直接看见的那件事。
        pcall(observability.gauge, "lr_gpu_load_power_per_card_workers", {},
            stats.power_per_card or 0)
    end
    return true
end

---Per-worker sample gauge, written by whoever stored the value so the label is the
---worker url the dashboards already key on.
---@param url string
---@param load number @ normalized 0..1
function _M.publish_worker_gauge(url, load)
    if not live_ngx() then
        return false
    end
    local ok_obs, observability = pcall(require, "resty.luarouter.observability")
    if not ok_obs or type(observability) ~= "table"
        or type(observability.gauge) ~= "function" then
        return false
    end
    return pcall(observability.gauge, "lr_gpu_load", { { "worker", tostring(url) } },
        load)
end

---Per-worker watt gauge, the power counterpart of publish_worker_gauge(). 单位是
---**绝对瓦特**，所以这一族绝不能与 lr_gpu_load（0..1）混用或同族——一个看板把两者
---画在一条 y 轴上，读数是 96 还是 0.96 就说不清了。
---@param url string
---@param watts number @ absolute watts
function _M.publish_worker_power_gauge(url, watts)
    if not live_ngx() then
        return false
    end
    local ok_obs, observability = pcall(require, "resty.luarouter.observability")
    if not ok_obs or type(observability) ~= "table"
        or type(observability.gauge) ~= "function" then
        return false
    end
    return pcall(observability.gauge, "lr_gpu_load_power_watts",
        { { "worker", tostring(url) } }, watts)
end

------------------------------------------------------------------ the timer

local timer_running = false
_M.timer_running = function()
    return timer_running
end

local function interval(cfg)
    local seconds = tonumber(cfg and cfg.load_interval_secs) or 15
    if seconds < 1 then
        seconds = 1
    end
    return math.min(seconds, MAX_TIMER_DELAY)
end

local function tick(premature, cfg)
    if premature then
        timer_running = false
        return
    end
    local held = false
    local lock
    if live_ngx() then
        local ok_lock, lock_mod = pcall(require, "resty.lock")
        if ok_lock and type(lock_mod) == "table" then
            local instance
            instance = lock_mod:new(LOCK_DICT, { timeout = 0, exptime = 120 })
            if instance then
                held = instance:lock(TICK_LOCK)
                lock = instance
            end
        end
        if not held then
            -- The previous pass is still dialing (a Prometheus behind a hung
            -- listener); skipping is the normal answer on a slow host, so no WARN.
            local again, aerr = ngx.timer.at(interval(cfg), tick, cfg)
            if not again then
                timer_running = false
                ngx.log(ngx.ERR, "luarouter: gpu-load timer stopped: ",
                    tostring(aerr))
            end
            return
        end
    end
    local ok, err = pcall(_M.run_pass, cfg)
    if not ok then
        ngx.log(ngx.WARN, "luarouter: gpu-load pass failed: ", tostring(err))
    end
    if lock and held then
        pcall(function() lock:unlock() end)
    end
    local again, aerr = ngx.timer.at(interval(cfg), tick, cfg)
    if not again then
        timer_running = false
        ngx.log(ngx.ERR, "luarouter: gpu-load timer not rescheduled: ",
            tostring(aerr))
    end
end

---Start the load-source timer (worker 0 only; hb.start() is the caller, which is
---already inside that gate).
---@param cfg table|nil @ router config; the config module answers when omitted
---@return boolean ok, string|nil err
function _M.start(cfg)
    if not cfg then
        local ok_outer, outer = pcall(require, "resty.luarouter")
        if not ok_outer or type(outer) ~= "table" or type(outer.config) ~= "function" then
            return false, "no config"
        end
        cfg = outer.config()
    end
    local source = (cfg and cfg.load_source) or "none"
    if source == "none" then
        -- Zero behaviour change: no timer, no fetch, no shared-dict write.
        return false, "disabled (SMG_LOAD_SOURCE=none)"
    end
    if not live_ngx() then
        return false, "no ngx (gpu-load needs OpenResty)"
    end
    if source ~= "metrics" and source ~= "prom" then
        -- config.lua's one_of() already collapses an unknown name to "none", so this
        -- only fires for a caller that hands the module a hand-built table. Refusing
        -- here is what keeps a typo from starting a timer that fetches nothing.
        return false, "unknown SMG_LOAD_SOURCE: " .. tostring(source)
    end
    if source == "prom" then
        -- 启动门槛与 run_pass 对齐：负载查询与功率查询至少要有一条，Prometheus 地址
        -- 必须有。只填 SMG_LOAD_POWER_QUERY 也是合法部署（只要功率读数），以前这里
        -- 会连带把它拒掉，定时器根本不启动、功率永远采不到，而且失败原因说的是
        -- SMG_LOAD_PROM_QUERY，操作员照着改会以为必须配负载查询。
        local power = _M.power_config(cfg)
        local has_load = type(cfg.load_prom_query) == "string"
            and cfg.load_prom_query ~= ""
        if not _M.query_endpoint(cfg.load_prom_url) or (not has_load and not power.query) then
            return false, "source=prom needs SMG_LOAD_PROM_URL and SMG_LOAD_PROM_QUERY"
                .. " (or SMG_LOAD_POWER_QUERY for the power channel alone)"
        end
    end
    if timer_running then
        return true
    end
    timer_running = true
    local ngxm = live_ngx()
    local ok, err = ngxm.timer.at(0, tick, cfg)
    if not ok then
        timer_running = false
        return false, err
    end
    ngxm.log(ngxm.NOTICE, "luarouter: gpu-load source ", source, " (interval ",
        interval(cfg), "s, timeout ", (tonumber(cfg.load_timeout_secs) or 4), "s)")
    return true
end

---Stop the timer (used by the e2e scenarios that flip the source mid-run).
function _M.stop()
    timer_running = false
end

return _M
