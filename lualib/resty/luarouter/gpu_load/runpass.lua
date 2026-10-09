local _M = require "resty.luarouter.gpu_load"
local seams = require "resty.luarouter.gpu_load.seams"

-- A worker's /metrics is usually tens of KB; above this the pass gives up on the
-- body rather than parse a megabyte-scale exposition every interval.
local MAX_BODY_BYTES = 4 * 1024 * 1024

-- gpu_load/runpass.lua -- one pass over the configured source.  The two
-- per-query closures (one / one_util) are module-level functions here
-- with an explicit ctx, so the stats口径 stays single-point (new_stats)
-- and the per-card / fallback distinction cannot be split or misread.
-- The three source branches, the 采集不到 -> 什么都不写 branches and the
-- skip / failed / unmatched accounting moved verbatim.

---The pass stats table, defined in exactly one place so every field
---keeps its 口径 here (doc/gap-gpu-load.md 6/9).  util_per_card and
---util_fallback are deliberately their own counters: without them,
---all-per-card and all-machine-max grow the same shape on /metrics, which
---is how 21.k 342.371 stayed unnoticed.
local function new_stats(cfg)
    return {
        source = cfg.load_source or "none", probed = 0, matched = 0,
        failed = 0, unmatched = 0, skipped = 0, errors = 0,
        -- GPU 利用率通道（doc/caps-redesign-2026-10-06.md §5，registry 的 gu: 键）的独立
        -- 计数：probed = metrics 路「正文可用并被扫过」的 worker 数 /
        -- prom 路「成功执行的利用率查询」数；matched = 真正写进 gu: 的读数数；failed =
        -- 扫过却取不到可用读数；errors = 查询没做成 / 响应不可解析 / 存储失败；rejected =
        -- registry 拒收；skipped = worker url 解析不出 host、压根没法问。
        -- util_per_card 与 util_fallback 是这一族的存在理由：只
        -- 有 matched 一个数的话，「八台各归各卡」与「八台共用一个整机 max」在 /metrics 上
        -- 完全同形——区分「全逐卡命中」与「全回退整机 max」正是 342.371 那一课的处方。
        -- 认不出卡时利用率**回退**整机 max（保守方向，见 cards.lua
        -- assign_util 上方）而不是留空，所以回退必须有一个不被静默吞掉的计数，
        -- util_fallback 就是那一声。
        util_enabled = false, util_probed = 0, util_matched = 0,
        util_failed = 0, util_rejected = 0, util_errors = 0,
        util_unmatched = 0, util_skipped = 0,
        util_per_card = 0, util_fallback = 0,
    }
end

local function one(ctx, query, target)
            local ok_call, status, body, err = pcall(ctx.post, ctx.endpoint, ctx.timeout_ms,
                ctx.headers, _M.query_body(query))
            if not ok_call then
                ctx.stats.errors = ctx.stats.errors + 1
                _M.warn_dedup("prom-raise", target, tostring(status), ctx.stamp())
                return
            end
            local code = tonumber(status) or 0
            if code < 200 or code >= 300 or type(body) ~= "string" then
                ctx.stats.failed = ctx.stats.failed + 1
                _M.warn_dedup("prom", target, err or ("status " .. tostring(status)),
                    ctx.stamp())
                return
            end
            local rows, perr = _M.parse_prom_response(body)
            if not rows then
                ctx.stats.failed = ctx.stats.failed + 1
                _M.warn_dedup("prom", target, perr, ctx.stamp())
                return
            end
            local folded = _M.host_values(rows)
            for host, load in pairs(folded) do
                if ctx.by_host[host] == nil or load > ctx.by_host[host] then
                    ctx.by_host[host] = load
                end
            end
            ctx.stats.probed = ctx.stats.probed + 1
        end

---One prom-path utilization query (the third PromQL).
---
---数值走 util_fraction()（经由 host_card_utils），而不是负载那一路的 normalize()。
---这是纪律要求的差别，不是笔误：利用率这条 vector 喂的是准入门，不能被
---normalize() 的「>1 就当百分数、越界一律夹到 1」的打分启发式折一遍
---（doc/caps-redesign-2026-10-06.md §5 点名的缺口正是这一条）。
---
---它有自己独立的 vector、自己的逐卡表与自己的 card_hosts 集合：利用率
---查询是与负载查询**分开的**第二条 PromQL，两者永不合并（gauge 家族与聚合口径常常不同，
---一条写坏时不能把另一路一起拖走）。
local function one_util(ctx, query, target)
    local ok_call, status, body, err = pcall(ctx.post, ctx.endpoint, ctx.timeout_ms,
        ctx.headers, _M.query_body(query))
    if not ok_call then
        ctx.stats.util_errors = ctx.stats.util_errors + 1
        _M.warn_dedup("util-prom-raise", target, tostring(status), ctx.stamp())
        return false
    end
    local code = tonumber(status) or 0
    if code < 200 or code >= 300 or type(body) ~= "string" then
        ctx.stats.util_errors = ctx.stats.util_errors + 1
        _M.warn_dedup("util-prom", target,
            err or ("status " .. tostring(status)), ctx.stamp())
        return false
    end
    local rows, perr = _M.parse_prom_response(body)
    if not rows then
        -- 正文不是合法 PromQL 响应（404 页面、query 语法错被代理成 200）：这是「解析
        -- 失败」，单独计数，供 lr_gpu_load_util_parse_failures_total 观测。
        ctx.stats.util_errors = ctx.stats.util_errors + 1
        _M.warn_dedup("util-prom", target, perr, ctx.stamp())
        return false
    end
    -- 逐卡展开（机器/卡的身份规则见 cards.lua 的 util_fold 上方）。
    local folded, cards, card_hosts_of_query = _M.host_card_utils(rows)
    for host, util in pairs(folded) do
        if ctx.by_util[host] == nil or util > ctx.by_util[host] then
            ctx.by_util[host] = util
        end
    end
    for key, util in pairs(cards) do
        -- {host} 模板会发多条查询，同一个 host+gpu 键取最大：与 host 键同做法，也保证
        -- 结果与查询到达顺序无关（同一份输入跑两遍必须逐字节相同）。
        if ctx.by_card_util[key] == nil or util > ctx.by_card_util[key] then
            ctx.by_card_util[key] = util
        end
    end
    for host in pairs(card_hosts_of_query) do
        ctx.util_card_hosts[host] = true
    end
    ctx.stats.util_probed = ctx.stats.util_probed + 1
    return true
end

---Metrics-path utilization scan for one worker's /metrics body.
---
---由 pass 用 pcall 包住调用，所以这里的任何意外都吃不到同一 tick 的负载读数
---（两通道互不影响）。它只碰传进来的正文与自己名下的那几个计数。
---@param ctx table @ {record, body, stats, names, hints, stamp, ttl_secs, write_util}
local function scan_util_metrics(ctx)
    local stats = ctx.stats
    local record, body = ctx.record, ctx.body
    stats.util_probed = stats.util_probed + 1
    -- 一次正文扫出「整机最热」与「逐卡」两张表（同一个正文、同一次拨号）。取哪张由这个
    -- worker 认不认得自己的卡决定；认不出时回退整机 max **并计入 fallback**（口径见
    -- assign_util 上方：利用率侧的整机 max 是保守方向，代价是少用一台机器而不是让满载的
    -- 卡继续接活，所以可以回退，但绝不静默降级）。
    local whole, by_card, have_cards = _M.util_by_card(body, ctx.names)
    if whole == nil then
        -- 采不到：什么都不写。旧的 gu: 键会在自己的 TTL 后消失，registry 侧读成「未知 ->
        -- 不排除」。写 0 或沿用上一次的旧值都会让一个坏 exporter 把这台 worker 永久顶在
        -- 利用率上限之外（或永远不受限），那是监控系统故障吃掉容量。
        stats.util_failed = stats.util_failed + 1
        _M.warn_dedup("util-nogauge", record.url,
            "no gpu utilization gauge in " .. #body .. "B", ctx.stamp())
        return
    end
    local util
    if have_cards then
        local gpu = _M.worker_card(record, ctx.hints)
        if gpu ~= nil then
            util = by_card[gpu]
            if util ~= nil then
                stats.util_per_card = stats.util_per_card + 1
            end
        end
    end
    if util == nil then
        -- 认不出卡 / 该卡无 series / 源根本没有逐卡标签：用整机最热卡的利用率，并计一次
        -- 回退。三种情形不在日志里分开，利用率侧的归因由
        -- lr_gpu_load_util_fallback_total 与 per_card 的差承担——那才是运维要看的数。
        util = whole
        stats.util_fallback = stats.util_fallback + 1
    end
    local stored, why = ctx.write_util(record.id, util, ctx.stamp(), ctx.ttl_secs,
        record.url)
    if stored then
        stats.util_matched = stats.util_matched + 1
    elseif why == "rejected" then
        stats.util_rejected = stats.util_rejected + 1
    elseif why == "no-registry" then
        -- 同 prom 路：registry 还没有 gu: 的读者，不是 exporter 的错。
        stats.util_failed = stats.util_failed + 1
        _M.warn_dedup("util-noregistry", record.url,
            "registry has no set_gpu_util (gu: reader missing): utilization collected"
            .. " a reading nobody can store", ctx.stamp())
    else
        stats.util_errors = stats.util_errors + 1
    end
end

---Prom-path utilization channel: query (deduped), fold, assign, write.
---
---与负载那一路在构造上互不牵连：自己的 ctx 表、自己的计数，且整个函数在调用点被
---pcall 包住，这一路炸了也不会带走另一路的这一 tick。
---@param ctx table @ prom context (by_util / by_card_util / util_card_hosts / util ...)
local function run_util_prom(ctx)
    local stats = ctx.stats
    if _M.query_needs_host(ctx.util.query) then
        local queried = {}
        for i = 1, #ctx.workers do
            local record = ctx.workers[i]
            local uq = _M.render_query(ctx.util.query, record)
            if uq then
                if not queried[uq] then
                    queried[uq] = true
                    one_util(ctx, uq, record.url)
                end
            else
                -- 这条 worker 的 url 解析不出 host，模板没法展开：与负载那一路的
                -- skipped 同义（是「这个 worker 没法问」而不是「监控系统没给出读数」），
                -- 混进 failed 会让 lr_gpu_load_util_parse_failures_total 随坏 url 的个数
                -- 放大，指错排障方向。
                stats.util_skipped = stats.util_skipped + 1
            end
        end
    else
        one_util(ctx, ctx.util.query, ctx.endpoint)
    end

    local url_for_util = {}
    for i = 1, #ctx.workers do
        url_for_util[ctx.workers[i].id] = ctx.workers[i].url
    end
    -- 按 worker 各自的卡分发（四路口径见 cards.lua 的 assign_util 上方注释）。逐卡命中数
    -- 与回退数由 assign_util 一并给出，不在这里二次推断——同一件事在两处算只会
    -- 长出口径分歧。
    local u_assigned, u_unmatched, u_per_card, u_fallback = _M.assign_util(
        ctx.workers, ctx.by_util, ctx.by_card_util, ctx.util_card_hosts, ctx.gpu_hints)
    stats.util_unmatched = u_unmatched
    stats.util_per_card = u_per_card
    stats.util_fallback = u_fallback
    -- 查询本身成功却一个可用读数都没有（gauge 名写错、那批机器没起 dcgm、整表都是 NaN）：
    -- 与 metrics 路的 no-gauge 同义，记一次 failed 并留一条去重 WARN。放在这里而不是
    -- one_util 内，是因为按 host 展开时会有多次查询，只有折叠完才知道整个 vector 到底有
    -- 没有可用读数。
    if next(ctx.by_util) == nil and (stats.util_errors or 0) == 0 then
        stats.util_failed = stats.util_failed + 1
        _M.warn_dedup("util-prom-nogauge", tostring(ctx.util.query),
            "utilization query returned no usable gpu-util series", ctx.stamp())
    elseif next(u_assigned) == nil and next(ctx.by_util) ~= nil then
        -- 查得到读数、一个 worker 都没配上：几乎只会是标签口径对不上（比如 by(Hostname)
        -- 折出的机器名与注册成 IP:port 的 worker url 永不在同一把键上相遇）。这是「利用率
        -- 上限看着在生效、其实一台都没进」最隐蔽的一种，只靠 util_unmatched 太容易漏看。
        _M.warn_dedup("util-prom-unassigned", tostring(ctx.util.query),
            "gpu-util series matched no pooled worker (" ..
            tostring(stats.util_unmatched) .. " hosts unmatched)", ctx.stamp())
    end
    for id, util in pairs(u_assigned) do
        local stored, why = ctx.write_util(id, util, ctx.stamp(), ctx.ttl_secs,
            url_for_util[id])
        if stored then
            stats.util_matched = stats.util_matched + 1
        elseif why == "rejected" then
            stats.util_rejected = stats.util_rejected + 1
        elseif why == "no-registry" then
            -- registry 还不认得 gu: 键（网关版本比这条通道旧，或 w_caps_registry 那一波还
            -- 没落地）：这不是 exporter 撒谎、也不是本机共享字典不够，而是「这条通道此刻没有
            -- 读者」。计一次 failed（这一路确实没有产出读数）并留一条去重 WARN 指名配置项，
            -- 比静默强，也比 error 诚实。
            stats.util_failed = stats.util_failed + 1
            _M.warn_dedup("util-prom-noregistry", tostring(ctx.util.query),
                "registry has no set_gpu_util (gu: reader missing): SMG_LOAD_UTIL_QUERY"
                .. " collected a reading nobody can store", ctx.stamp())
        else
            stats.util_errors = stats.util_errors + 1
        end
    end
end

---Run one pass of the configured source. Every failure mode is a counter, not an
---error: the sweep owns health, and a monitoring system that is behind must never
---cost a worker its place in the pool.
---@param cfg table @ router config (load_* fields)
---@param opts table|nil @ injected seams: {workers, get, post, write, now, publish}
---@return table stats
function _M.run_pass(cfg, opts)
    cfg = cfg or {}
    opts = opts or {}
    local stats = new_stats(cfg)
    if stats.source == "none" then
        stats.skipped = 1
        -- 唯一需要在「负载源关着」时说的话：利用率是**搭载**在负载源上的（同一个
        -- 定时器），source=none 时它根本不启动。缺省串人人都有，不足以说明操作员
        -- 想用这一路，所以只有他**显式**写过 SMG_LOAD_UTIL_QUERY 才值得留话——那时
        -- max_gpu_util 会安静地一直按「未知 -> 不排除」放行，正是最容易以为在生效、
        -- 其实没有的那种配置。
        local want_util = _M.util_config(cfg)
        if want_util.on and want_util.explicit_query then
            _M.warn_dedup("util-source-none", "none",
                "utilization query configured but SMG_LOAD_SOURCE=none: no timer runs,"
                .. " set it to metrics or prom")
        end
        return stats
    end

    local get = opts.get or seams.default_get
    local post = opts.post or seams.default_post
    local list_workers = opts.workers or seams.default_workers
    local write = opts.write or seams.default_write
    local write_util = opts.write_util or seams.default_write_util
    local stamp = opts.now or seams.now_ms
    local timeout_ms = math.max(250, (tonumber(cfg.load_timeout_secs) or 4) * 1000)
    local ttl_secs = tonumber(cfg.load_stale_secs)
    if not ttl_secs or ttl_secs <= 0 then
        -- Three intervals: one Prometheus blip, one slow scrape or one worker that
        -- briefly refuses a connection must not drop the pool to in-flight-only, and
        -- the TTL is still short enough that a dead source stops counting for real
        -- within a minute of its last good sample.
        ttl_secs = 3 * (tonumber(cfg.load_interval_secs) or 15)
    end
    local scale = tonumber(cfg.load_scale) or 100
    stats.stale_secs = ttl_secs
    stats.scale = scale
    -- The selection path reads the weight off the registry (never the environment)
    -- so that a hot edit to SMG_LOAD_SCALE reaches power_of_two on the next tick.
    local registry = seams.registry_mod()
    if registry and type(registry.set_load_scale) == "function" then
        pcall(registry.set_load_scale, scale)
    end

    local workers = list_workers() or {}
    stats.workers = #workers

    -- 利用率通道（缺省启用，doc/caps-redesign-2026-10-06.md §5）。它的判定开关不在这里：
    -- 采集只把读数写进 registry 的 gu: 键，只有 worker 记录上显式配了 max_gpu_util 才会有
    -- 人读它，所以缺省开不改变任何现有部署的选路行为（「读数未知 -> 不排除」）。prom 路是
    -- 否**多发**这条查询见下面 util_enabled 的口径。
    local util = _M.util_config(cfg)
    -- 「这一路真的在跑」的口径。metrics 路只认 util.on：同一份正文多扫一遍，不新增
    -- 拨号，缺省开是纯赚。prom 路只认**操作员的显式意图**（写了 SMG_LOAD_UTIL_QUERY）：
    -- 缺省串人人都有（util.query 恒非空），拿它当意图的话，每个只配了负载查询的部署
    -- 都会凭空多出一条没人要求的 POST——那是「缺省零行为变化」这条红线
    -- （caps-redesign §0 第 3 条）直接否掉的形状，单测里「一条 PromQL = 一个 tick
    -- 一个 POST」的钉也一起塌掉。它同时挡住一种误导性的导出：util_enabled 为真却
    -- 导出 util_workers=0 / samples_total=0，看板读起来像「利用率在生效但一台都没
    -- 采到」，而真相是这条根本不该有读数。
    local util_runs_prom = util.on and util.query ~= nil and util.explicit_query
    if stats.source == "metrics" then
        stats.util_enabled = util.on
    elseif stats.source == "prom" then
        stats.util_enabled = util_runs_prom
    else
        stats.util_enabled = false
    end

    if stats.source == "metrics" then
        local names = _M.metric_key_list(cfg.load_metrics_keys)
        local util_names = _M.metric_key_list(util.keys)
        -- 逐卡归属用的卡号快照（watcher 台账 g| 键，见 default_gpu_hints）。一次 pass
        -- 读一次，不在 worker 循环里摸共享字典。opts.gpu_hints 是测试注入面。
        local hints = opts.gpu_hints
        if hints == nil then
            hints = seams.default_gpu_hints()
        end
        -- 编成查找索引一次（exact + host:port 两级），worker 循环里只查不编。
        hints = _M.hint_index(hints)
        for i = 1, #workers do
            local record = workers[i]
            stats.probed = stats.probed + 1
            local url = record.url .. (cfg.load_metrics_path or "/metrics")
            local ok_call, status, body, err = pcall(get, url, timeout_ms,
                seams.worker_headers(record))
            if not ok_call then
                -- get() itself raised (a broken seam, an unexpected cosocket
                -- error): same treatment as a timeout, silently.
                stats.errors = stats.errors + 1
                _M.warn_dedup("metrics-raise", record.url, tostring(status), stamp())
            else
                local code = tonumber(status) or 0
                if code < 200 or code >= 300 or type(body) ~= "string" then
                    stats.failed = stats.failed + 1
                    _M.warn_dedup("metrics", record.url,
                        err or ("status " .. tostring(status)), stamp())
                elseif #body > MAX_BODY_BYTES then
                    stats.failed = stats.failed + 1
                    _M.warn_dedup("metrics", record.url,
                        "body over " .. MAX_BODY_BYTES .. " bytes", stamp())
                else
                    local raw = _M.max_gauge(body, names)
                    local load = _M.normalize(raw)
                    if load == nil then
                        -- A /metrics that answers 200 but carries none of the
                        -- gauges (a llama.cpp build with no CUDA, an exporter on
                        -- the wrong port) is a configuration gap, not an unhealthy
                        -- worker: no sample this tick, and no health charge.
                        stats.failed = stats.failed + 1
                        _M.warn_dedup("metrics-nogauge", record.url,
                            "no gauge in " .. #body .. "B", stamp())
                    else
                        write(record.id, load, stamp(), ttl_secs, record.url)
                        stats.matched = stats.matched + 1
                    end
                    -- 利用率用**同一次 GET 的正文**再扫一遍（第二个读数，第二遍扫描）：
                    -- 位置纪律很关键——排在负载那一路的 if/else 之后、独立记账，所以
                    -- 一个正文里没有负载 gauge 却带 gpu-util gauge 的 exporter
                    -- （dcgm-exporter 本体就是这种）仍然要交出利用率读数；反过来取不到
                    -- 利用率也不影响负载那一路。抓取失败（非 2xx / 超正文上限）只算进
                    -- 负载的 failed，这里连 probed 都不加（没有正文就没什么可扫的），
                    -- 再记一次 failure 会把同一个故障数成两遍。整个扫描包在 pcall 里：
                    -- 一条通道出我们没预料的错，代价只能是它自己的读数。
                    if util.on then
                        local ok_util, err_util = pcall(scan_util_metrics, {
                            record = record, body = body, stats = stats,
                            names = util_names, hints = hints, stamp = stamp,
                            ttl_secs = ttl_secs, write_util = write_util,
                        })
                        if not ok_util then
                            stats.util_errors = stats.util_errors + 1
                            _M.warn_dedup("util-crash", record.url,
                                tostring(err_util), stamp())
                        end
                    end
                end
            end
        end
    elseif stats.source == "prom" then
        local endpoint = _M.query_endpoint(cfg.load_prom_url)
        local template = cfg.load_prom_query
        if not endpoint or type(template) ~= "string" or template == "" then
            -- 没配负载查询：以前这里整轮 skip，于是「只想从 Prometheus 要利用率读数」
            -- 这种完全合理的部署永远采不到读数，max_gpu_util 一直按「未知 -> 不排除」
            -- 放行，操作员却以为上限在生效。现在负载那一路自己 skip，利用率那一路照常
            -- 执行；两条查询共用同一个 SMG_LOAD_PROM_URL，所以 endpoint 缺失仍然是整轮
            -- skip。**缺省串**不构成意图：否则每个漏配负载查询的部署都会悄悄多打一条
            -- POST，「配置缺口」也被一个没人要求过的缺省值吞掉。
            if endpoint and (util.on and util.explicit_query) then
                local running = {}
                running[#running + 1] = "utilization"
                _M.warn_dedup("prom-config", tostring(cfg.load_prom_url),
                    "SMG_LOAD_PROM_QUERY empty: running the "
                    .. table.concat(running, " + ") .. " query only", stamp())
            else
                stats.skipped = 1
                _M.warn_dedup("prom-config", tostring(cfg.load_prom_url),
                    "SMG_LOAD_PROM_URL/SMG_LOAD_PROM_QUERY incomplete", stamp())
                return stats
            end
        end
        local has_load_query = type(template) == "string" and template ~= ""
        local headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
        local prom_ctx = {
            post = post, endpoint = endpoint, timeout_ms = timeout_ms,
            headers = headers, stats = stats,
            by_host = {},
            -- 利用率通道的独立表（第二条查询自己的 vector / 逐卡表 / 逐卡源标记），
            -- 以及它需要的 worker 名册、卡号提示快照与写 seam。两通道共用一次 pass 的
            -- ctx 容器但各用各的字段，一个通道的表读写不到另一个通道的账上。
            by_util = {}, by_card_util = {}, util_card_hosts = {},
            stamp = stamp,
            workers = workers, util = util, write_util = write_util,
        }

        -- 利用率这一路（第二条查询）。整段包在 pcall 里：一个 tick 里两通道互不影响，
        -- util 采集出任何我们没预料的错，代价只能是 util 自己的读数，不能拖垮已经
        -- 跑完的负载 vector。
        if stats.util_enabled and util.query then
            local u_hints = opts.gpu_hints
            if u_hints == nil then
                u_hints = seams.default_gpu_hints()
            end
            prom_ctx.gpu_hints = _M.hint_index(u_hints)
            local ok_util, err_util = pcall(run_util_prom, prom_ctx)
            if not ok_util then
                stats.util_errors = (stats.util_errors or 0) + 1
                _M.warn_dedup("util-crash", tostring(util.query),
                    tostring(err_util), stamp())
            end
        end

        if not has_load_query then
            -- 负载这一路本轮没有查询可发（template 是 nil/空），下面的循环必须整个
            -- 跳过——否则会拿空串去 POST 一条 PromQL，既浪费一次拨号又记进 failed。
            stats.skipped = stats.skipped + 1
        elseif _M.query_needs_host(template) then
            -- A {host}-templated PromQL is one query per *machine*: the template is
            -- written against a single host, and several workers can live on one
            -- (the ranks of a DP engine, two engines on one GPU box). Rendering is
            -- memoized by query text, so four ranks of the same host cost one POST.
            local queried = {}
            for i = 1, #workers do
                local record = workers[i]
                local query = _M.render_query(template, record)
                if query then
                    if not queried[query] then
                        queried[query] = true
                        one(prom_ctx, query, record.url)
                    end
                    local host = _M.split_host(record.url)
                    local load = host and prom_ctx.by_host[host]
                    if load ~= nil then
                        write(record.id, load, stamp(), ttl_secs, record.url)
                        stats.matched = stats.matched + 1
                    end
                else
                    stats.skipped = stats.skipped + 1
                end
            end
        else
            one(prom_ctx, template, endpoint)
            local url_for_id = {}
            for i = 1, #workers do
                url_for_id[workers[i].id] = workers[i].url
            end
            local assigned, unmatched = _M.assign(prom_ctx.by_host, workers)
            stats.unmatched = unmatched
            for id, load in pairs(assigned) do
                write(id, load, stamp(), ttl_secs, url_for_id[id])
                stats.matched = stats.matched + 1
            end
        end
    else
        stats.skipped = 1
        _M.warn_dedup("source", stats.source, "unknown SMG_LOAD_SOURCE", stamp())
    end

    _M.publish_metrics(stats)
    return stats
end

return _M
