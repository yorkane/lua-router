local _M = require "resty.luarouter.watcher"
local env_mod = require "resty.luarouter.watcher.env"
local ledger_mod = require "resty.luarouter.watcher.ledger"
local M = {}   -- cross-module helper surface (not part of _M)
local has_ngx = env_mod.has_ngx

-- watcher/live.lua -- everything that resolves the OpenResty globals: the
-- lr_watch dict handle, the cosocket probe transport and its bounded
-- thread pool, the registry adapters, run_pass and the worker-0
-- single-flight timer.  Moved verbatim; hb / registry / policy /
-- observability stay call-time requires exactly as before, so no load-time
-- cycle appears.

-- ==================================================================== live wiring
--
-- Everything below resolves the OpenResty globals: the cosocket probe transport, the
-- docker unix socket, /proc, the lr_watch shared dict, the registry, and the worker 0
-- timer. It is separated from the pure layer above so the semantics stay testable
-- under luajit with no ngx at all (test/unit/test_watcher.lua), exactly the split
-- mesh.lua uses.

local DICT_NAME = "lr_watch"
local LOCK_DICT = "lr_locks"
local TICK_LOCK = "watcher-tick"

---Shared dict, or nil outside nginx / before the dict is declared in the conf.
---@return table|nil
local function dict()
    if not has_ngx or not ngx.shared then
        return nil
    end
    return ngx.shared[DICT_NAME]
end

---Config captured by start() so the request phase (POST /model-map) can merge the
---env map without reparsing the environment.
local captured_config

_M.config = function()
    return captured_config
end

---卡号提示的只读快照，给 gpu_load 的逐卡功率通道用。台账是共享字典上的闭包、不是单例，
---所以这里每次现造一个读；字典不在（nginx 外、或 conf 没声明 lr_watch）时回 {}，功率那
---一路就退回 labels.gpu 与整机 max —— 也就是逐卡归属落地之前的行为。
---@return table @ url -> gpu id
function _M.gpu_hint_snapshot()
    local d = dict()
    if not d then
        return {}
    end
    local ok, hints = pcall(ledger_mod.new_ledger(d).gpu_hints)
    if ok and type(hints) == "table" then
        return hints
    end
    return {}
end

_M.gpu_hint_store = { read_all = _M.gpu_hint_snapshot }

-- -------------------------------------------------------------- probe transport

---GET one URL, decoded by classify() through the same fetch contract the tests use.
---@param timeout_ms number
---@return function @ (url) -> status, body, err
local function make_fetch(timeout_ms)
    local hb = require "resty.luarouter.hb"
    return function(url)
        return hb.http_get(url, timeout_ms)
    end
end

---Probes through a bounded pool of coroutines.
---
---The daemon used a 16-thread pool; a serial pass would spend the whole interval on a
---host with a hundred listeners (each hanging probe costs probe_timeout). ngx.thread
---gives the same concurrency for free because every cosocket wait yields. Without ngx
---(unit tests) the caller falls back to a serial loop.
---@param urls string[]
---@param opts table @ classify options (fetch injected here)
---@param fanout number|nil
---@return table @ url -> info|nil
---@return table @ url -> classify() rejection reason (nil when the probe itself raised)
local function probe_pool(urls, opts, fanout)
    local results, reasons, next_index = {}, {}, 0
    local function one(url)
        local info, reason = _M.classify(url, opts)
        results[url] = info
        reasons[url] = reason
    end
    if not has_ngx or type(ngx.thread) ~= "table" or #urls == 0 then
        for i = 1, #urls do
            one(urls[i])
        end
        return results, reasons
    end
    local width = math.max(1, math.min(fanout or 8, #urls))
    local threads = {}
    for _ = 1, width do
        threads[#threads + 1] = ngx.thread.spawn(function()
            while true do
                next_index = next_index + 1
                local index = next_index
                if index > #urls then
                    return
                end
                local ok, err = pcall(one, urls[index])
                if not ok then
                    -- A cosocket that raises mid-probe is a transport unknown, not a
                    -- verdict about the service: the reason is what reconcile's split
                    -- reads, so leaving it nil (=> unknown) is the honest answer.
                    reasons[urls[index]] = "probe raised: " .. tostring(err)
                    ngx.log(ngx.WARN, "luarouter: watcher probe of ", urls[index],
                        " failed: ", tostring(err))
                end
            end
        end)
    end
    for i = 1, #threads do
        pcall(ngx.thread.wait, threads[i])
    end
    return results, reasons
end

-- ----------------------------------------------------------- registry adapters

---registry.add in the POST /workers body shape (registry.lua:620).
---@param conf table @ router config providing the health-check defaults
---@return function @ (url, model_id, entry) -> worker_id|nil, err
local function make_register(conf)
    local registry = require "resty.luarouter.registry"
    local ok_policy, policy = pcall(require, "resty.luarouter.policy")
    return function(url, model_id, entry)
        local labels = {
            ["managed-by"] = _M.MANAGED_BY,
            engine = entry.engine or "openai",
        }
        if entry.gpu then
            labels.gpu = entry.gpu
        end
        if entry.source then
            labels.discovery = entry.source
        end
        local req = {
            url = url,
            model_id = model_id,
            labels = labels,
            -- The registry records provenance in its own field, copied from the
            -- watcher label so GET /workers shows who wrote the row.
            discovery = _M.MANAGED_BY,
        }
        -- Same rule as the daemon: a service with no /health must not be marked
        -- unhealthy by a sweep that can never succeed.
        if entry.has_health == false then
            req.disable_health_check = true
        end
        local result, err = registry.add(req, conf)
        if not result then
            return nil, err
        end
        -- The /workers handlers bump the policy generation after a registry write;
        -- a direct add has to as well, or every stateful policy keeps seeding from
        -- the worker list it was built with (mesh needs nothing here: registry.add
        -- mirrors the record itself).
        if ok_policy then
            policy.bump_generation()
        end
        return result.id
    end
end

---@return function @ (worker_id) -> boolean ok
local function make_unregister()
    local registry = require "resty.luarouter.registry"
    local ok_policy, policy = pcall(require, "resty.luarouter.policy")
    return function(worker_id)
        local id = tostring(worker_id or "")
        if id == "" then
            return false
        end
        -- Guard 4, second half: only delete an id that still names a live record.
        -- The id is sha224(url), so a stale id can never have been re-claimed by a
        -- different URL, but a hand DELETE already removed it, and re-checking here
        -- keeps the ledger honest about what actually happened.
        local info = registry.get(id)
        if not info then
            return false
        end
        -- Backstop for the loop-level immunity above (and for any future call
        -- site): a config_store member is never deleted through the watcher,
        -- whatever the ledger believes about it.
        if info.discovery == "config" then
            ngx.log(ngx.DEBUG, "luarouter: watcher refused to remove config-declared ",
                "upstream ", id)
            return false
        end
        local result, err = registry.remove(id)
        if not result then
            ngx.log(ngx.WARN, "luarouter: watcher remove ", id, " failed: ",
                tostring(err))
            return false
        end
        -- Same two steps delete_worker_handler does: forget the load bookkeeping of
        -- the departed url, then let the stateful policies re-seed.
        if ok_policy then
            local inst = policy.default
            if inst and type(inst.on_remove) == "function" then
                inst:on_remove({ url = result.url })
            end
            policy.bump_generation()
        end
        return true
    end
end

---Current pool as url -> {id, model_id, is_healthy} (the daemon's GET /workers).
---@return table
local function actual_pool()
    local registry = require "resty.luarouter.registry"
    local records = registry.records()
    local out = {}
    for i = 1, #records do
        local record = records[i]
        local key = _M.normalize_url(record.url) or record.url
        out[key] = {
            id = record.id,
            url = record.url,
            model_id = record.model_id or "unknown",
            is_healthy = registry.is_healthy(record.id),
            -- labels 随行带出：GPU 归属补给要按「这条记录自己有没有说过卡号」决定要不要
            -- 写（reconcile 的 row_gpu），而 records() 是本函数唯一的池读取口 —— 在这里
            -- 补一列，比让补给路径去 registry.get 逐行摸一次 shdict 便宜，且读到的必然是
            -- 同一轮快照的字节。只带 labels 这一个只读视图，不带上任何判定用的字段。
            labels = record.labels,
            -- Provenance for the config-member immunity below (guard 4's twin:
            -- upstreams declared through config_store belong to nobody but the
            -- document). registry.records() is the only pool read here, so the
            -- field comes from the raw record rather than a second lookup.
            discovery = record.discovery or "",
        }
    end
    return out
end

---labels 补给的写入接缝：registry 侧既有的「合并 labels」写路径（PUT /workers 的
---registry.update 的 labels 支 → registry/records.lua 的 patch_record），不另开一条。
---
---刻意复用 registry.update 而不是直接调 records.patch_record：那条 PUT 就是 labels 的
---既有写入口（router/control.lua 的 update_worker_handler 底下走的正是它），合并语义、
---with_lock、mesh 镜像、K_HSEL 重算全在现成的那一份里；本文件里 make_register /
---make_unregister 与 POST/DELETE /workers 的关系也是同一种形状。update 的 model_id /
---models 忽略门只对**非 config 行**生效，而这里的补丁只带 labels 一个字段，那条门根本不参与。
---@return function @ (url, worker_id, gpu) -> boolean ok, string|nil err
local function make_patch_labels()
    local registry = require "resty.luarouter.registry"
    return function(url, worker_id, gpu)
        local id = tostring(worker_id or "")
        if id == "" then
            -- 纯层夹具之外的真实情况：actual 行没有 id 就没法定位记录。当作「没标上」。
            return false, "no worker id"
        end
        -- 贴着写入前对**现值**再判一次，而不是只信本轮 actual 的快照。两判都必要：
        --   * config 归属可能在这一轮读取之后才落定（config_store 的 upstreams reconcile
        --     与本轮 actual 快照之间没有锁），而 registry.update 对 config 行是
        --     labels_replace 语义 —— 那条路径会把声明层的 label 集整表换掉，绝不让
        --     watcher 的一次监控补齐去触发它；
        --   * 卡号也可能在快照之后被别人写上（操作员 PUT /workers，或另一个进程的
        --     discovery 路径）。「已有值绝不覆盖」只有贴着写入那一刻判才算真。
        -- registry.record 是现成的只读口（facade 导出 records.record）：一次 shdict 读，
        -- 只在「确实要写」的分支上才付这个代价。
        local current = registry.record and registry.record(id)
        if type(current) ~= "table" then
            return false, "worker record not found"
        end
        if current.discovery == "config" then
            return false, "config-declared upstream"
        end
        if _M.row_gpu(current) ~= nil then
            return false, "already labelled"
        end
        -- registry.update 的第二返回值是错误串（string），第三返回值才分 "validation" /
        -- "not_found"。两者都不许冒到 reconcile 去，调用方拿到的永远只是 ok + 一行原因。
        -- 这里刻意**不**跟一次 policy.bump_generation()，与 PUT /workers 的 handler
        -- （router/control.lua 的 update_worker_handler）不同，理由说清楚：
        --   * 那个 handler 补 generation 是因为操作员写的 label 里可能是 labels.policy ——
        --     candidates_for 把它当作按模型的策略提示读（router/candidates.lua），一次
        --     改写必须让有状态策略重新播种，否则新提示被旧实例盖住；
        --   * 本接缝一次只写 labels.gpu 这一个键，而 labels.gpu 不在任何选路输入里：
        --     candidates_for 按 model_id 筛、按 labels.policy 取提示，逐卡归属只被
        --     gpu_load 的读数归属与 /_ui 的徽章读（gpu_load/cards.lua 的 worker_card、
        --     props.lua）。bump 的代价在这里是真金白银：refresh_generation 会把 seeded
        --     清掉，下一次 select 走 prepare() 的 init_workers **整表重建**每棵亲和树
        --     （policies/cache_aware.lua 的 init_workers 注释「会重建每池的租户集合」），
        --     一台八个实例的机器会因八次「补个卡号」丢掉八次学到的前缀亲和 —— 那是
        --     调度质量层面的副作用，而这条路径的红线恰恰是「纯 label 补充不许影响任何
        --     判定」。ledger 的 g| 提示那条既有通路同样是写归因数据而不惊动策略层。
        --   * 若将来真有策略开始读 labels.gpu，再在此处补 bump；届时本函数是 labels.gpu
        --     唯一的 watcher 写入口，改动点只有一处。
        local ok, err = pcall(function()
            local result, uerr = registry.update(id, { labels = { gpu = gpu } })
            if not result then
                error(tostring(uerr or "worker update refused"), 0)
            end
        end)
        if not ok then
            return false, tostring(err)
        end
        return true
    end
end

-- ------------------------------------------------------------------ one pass

---Run one reconcile pass against the live registry.
---@param cfg table @ watcher config from new_config
---@param opts table|nil @{reader, fanout} (tests inject the /proc reader)
---@return table|nil stats, string|nil err
function _M.run_pass(cfg, opts)
    opts = opts or {}
    local d = dict()
    if not d then
        return nil, "lua_shared_dict " .. DICT_NAME .. " is not declared"
    end
    local conf = require("resty.luarouter").config()
    local ledger = _M.new_ledger(d)
    local now = ngx.now()
    local candidates = _M.collect(cfg, opts.reader)

    -- Probe every candidate once, concurrently, and hand reconcile the memo: the
    -- pure layer calls probe(url) per candidate, and a second HTTP round trip per
    -- URL would double the cost of a pass.
    local urls = {}
    for i = 1, #candidates do
        -- Filter before dialing. reconcile() applies the same two tests, so this is
        -- only about what a pass costs - and skipping the router's own listeners is
        -- not cosmetic: probing them from a timer every interval would add two
        -- requests per pass to the router's own smg_http_requests_total, and a
        -- /metrics scrape would then be counting the watcher watching itself.
        local cand = candidates[i]
        if cand and cand.url and not _M.is_self_url(cand.url, cfg.self_ports)
            and not _M.is_excluded(cand.url, cfg.exclude_patterns) then
            urls[#urls + 1] = candidates[i].url
        end
    end
    local fetch = make_fetch(math.floor((cfg.probe_timeout_secs or 4) * 1000))
    local probed, reasons = probe_pool(urls, {
        fetch = fetch,
        require_health = cfg.require_health,
        max_models = cfg.max_models,
        allow_models_only = cfg.allow_models_only,
    }, opts.fanout)

    local state = {
        cfg = cfg,
        ledger = ledger,
        now = now,
        actual = actual_pool(),
        candidates = candidates,
        model_map = _M.effective_map(cfg),
        entry_ttl = math.max(3600, (cfg.remove_grace_secs or 300) * 10
            + (cfg.keep_last_grace_secs or 1800)),
        probe = function(url)
            -- Second return value is the classify() rejection reason: reconcile
            -- cannot decide what to do with a "no" unless it knows which "no" it was.
            return probed[url], reasons[url]
        end,
        register = make_register(conf),
        unregister = make_unregister(),
        -- GPU 归属补给的唯一写入接缝（reconcile 的 annotate_gpu_labels 用）。
        patch_gpu_label = make_patch_labels(),
        stats = {
            reconciles = 0, adds = 0, add_fails = 0, removes = 0,
            discovered = 0, adds_stuck_released = 0,
            probe_failures = 0, probe_removes = 0, probe_fuse_skips = 0,
            -- 逐卡归属补给的观测量（observability 不新增 series：这俩只在 pass 日志与
            -- 探针里看，Grafana 那边 lr_watch_* 家族的口径不动）。
            gpu_labels_patched = 0, gpu_label_fails = 0,
        },
        log = function(level, message)
            if level == "warn" then
                ngx.log(ngx.WARN, message)
            elseif level == "debug" then
                ngx.log(ngx.DEBUG, message)
            else
                ngx.log(ngx.NOTICE, message)
            end
        end,
    }
    local stats = _M.reconcile(state)
    _M.publish_metrics(stats, state)
    return stats
end

-- ------------------------------------------------------------------- metrics

---Registration points for the watcher families (doc/gap-watcher-merge.md). Only
---observability.counter/gauge calls: the exporter renders whatever is in lr_stats,
---so nothing existing is touched.
---@param stats table
---@param state table
function _M.publish_metrics(stats, state)
    local ok_obs, observability = pcall(require, "resty.luarouter.observability")
    if not ok_obs then
        return false
    end
    local owned, protected = 0, 0
    for _ in pairs(state.ledger.owned_urls()) do
        owned = owned + 1
    end
    for _ in pairs(state.ledger.protected_urls()) do
        protected = protected + 1
    end
    local map_entries = 0
    for _ in pairs(state.model_map or {}) do
        map_entries = map_entries + 1
    end
    observability.record_watch_pass(stats, owned, protected, map_entries)
    return true
end

-- ---------------------------------------------------------------- the timer

local timer_running = false

---Count the pool once so the pass log line says what the watcher did.
local function tick(premature, cfg)
    if premature then
        timer_running = false
        return
    end
    local lock_mod = require "resty.lock"
    -- Single-flight: a pass that outlives the interval (a host with a thousand
    -- listeners, a daemon that hangs) must not stack a second one behind it.
    local lock, lerr = lock_mod:new(LOCK_DICT, { timeout = 0, exptime = 120 })
    local held = false
    if lock then
        held = lock:lock(TICK_LOCK)
        if not held then
            -- The previous pass is still running; skip quietly, the next interval
            -- retries. busy is the normal answer on a slow host, not an error.
            local again, aerr = ngx.timer.at(cfg.interval_secs, tick, cfg)
            if not again then
                timer_running = false
                ngx.log(ngx.ERR, "luarouter: watcher timer stopped: ", tostring(aerr))
            end
            return
        end
    end
    local ok, err = pcall(_M.run_pass, cfg)
    if not ok then
        ngx.log(ngx.WARN, "luarouter: watcher pass failed: ", tostring(err))
    end
    if lock and held then
        pcall(function() lock:unlock() end)
    end
    local again, aerr = ngx.timer.at(cfg.interval_secs, tick, cfg)
    if not again then
        timer_running = false
        ngx.log(ngx.ERR, "luarouter: watcher timer not rescheduled: ",
            tostring(aerr))
    end
end

---Start the reconcile timer (worker 0 only; init.lua owns that gate).
---@param cfg table|nil @ watcher config; built from the environment when omitted
---@param self_ports table|nil @ this router's own listener ports
---@return boolean ok, string|nil err
function _M.start(cfg, self_ports, metrics_port)
    if not has_ngx then
        return false, "no ngx (watcher needs OpenResty)"
    end
    if not cfg then
        local conf = require("resty.luarouter").config()
        cfg = _M.new_config(os.getenv,
            self_ports or conf.port,
            metrics_port or conf.metrics_port)
    end
    captured_config = cfg
    if not cfg.enabled then
        return false, "disabled (set SMG_WATCHER_ENABLED=1)"
    end
    if not dict() then
        return false, "lua_shared_dict " .. DICT_NAME .. " is not declared"
    end
    if #cfg.targets == 0 and not cfg.scan_docker and not cfg.scan_proc
        and next(cfg.allow_ports) == nil then
        return false, "no discovery source enabled (SMG_WATCHER_TARGETS / _DOCKER /"
            .. " _PROC_SCAN / _ALLOW_PORT)"
    end
    if timer_running then
        return true
    end
    timer_running = true
    local ok, err = ngx.timer.at(0, tick, cfg)
    if not ok then
        timer_running = false
        return false, err
    end
    ngx.log(ngx.NOTICE, "luarouter: watcher enabled (interval ",
        cfg.interval_secs, "s, sources",
        (#cfg.targets > 0) and " targets" or "",
        cfg.scan_docker and " docker" or "",
        cfg.scan_proc and " proc" or "",
        ")")
    return true
end

-- Read-only handles for watcher/modelmap.lua, which used the same file-
-- locals in the monolith.  Not facade members: the original _M never
-- carried a dict() or captured_config entry.
M.dict = dict
M.captured = function() return captured_config end

return M
