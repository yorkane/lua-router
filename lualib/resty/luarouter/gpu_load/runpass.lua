local _M = require "resty.luarouter.gpu_load"
local seams = require "resty.luarouter.gpu_load.seams"

-- A worker's /metrics is usually tens of KB; above this the pass gives up on the
-- body rather than parse a megabyte-scale exposition every interval.
local MAX_BODY_BYTES = 4 * 1024 * 1024

-- gpu_load/runpass.lua -- one pass over the configured source.  The two
-- per-query closures (one / one_power) are module-level functions here
-- with an explicit ctx, so the stats口径 stays single-point (new_stats)
-- and the power_per_card distinction cannot be split or misread.  The
-- three source branches, the 采集不到 -> 什么都不写 branches and the
-- skip / failed / unmatched accounting moved verbatim.

---The pass stats table, defined in exactly one place so every field
---keeps its 口径 here (doc/gap-gpu-load.md 6/9).  power_per_card is
---deliberately its own counter: without it, all-per-card and all-
---machine-max grow the same shape on /metrics, which is how 21.k
---342.371 stayed unnoticed.
local function new_stats(cfg)
    return {
        source = cfg.load_source or "none", probed = 0, matched = 0,
        failed = 0, unmatched = 0, skipped = 0, errors = 0,
        -- 功率通道的独立计数（每 worker 功率上限的采集侧）。全部从 0 起，未启用时保持
        -- 全 0 且不导出，缺省关闭的实例上 /metrics 与改动前逐字节一致。口径：
        -- probed = metrics 路是「被拨通过且正文可用」的 worker 数，prom 路是「成功
        -- 执行的功率查询」数；matched = 真正写进 pw: 的读数数；failed = 拨通了却取不
        -- 到可用瓦数；errors = 连查询都没做成/响应不可解析；rejected = registry 拒收。
        power_enabled = false, power_probed = 0, power_matched = 0,
        power_failed = 0, power_rejected = 0, power_errors = 0,
        power_unmatched = 0, power_skipped = 0,
        -- 本 pass 里**真正按自己那张卡**拿到瓦特的 worker 数（逐卡归属命中数）。它和
        -- power_matched 的差就是「悄悄退回整机 max」的台数；只有 matched 一个数的话，
        -- 「八张卡各归各」与「八张卡共用一个数」在 /metrics 上完全同形，而后者正是
        -- 21.k 的 342.371 能长期无人察觉的原因。
        power_per_card = 0,
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

local function one_power(ctx, query, target)
            local ok_call, status, body, err = pcall(ctx.post, ctx.endpoint, ctx.timeout_ms,
                ctx.headers, _M.query_body(query))
            if not ok_call then
                ctx.stats.power_errors = ctx.stats.power_errors + 1
                _M.warn_dedup("power-prom-raise", target, tostring(status), ctx.stamp())
                return false
            end
            local code = tonumber(status) or 0
            if code < 200 or code >= 300 or type(body) ~= "string" then
                ctx.stats.power_errors = ctx.stats.power_errors + 1
                _M.warn_dedup("power-prom", target,
                    err or ("status " .. tostring(status)), ctx.stamp())
                return false
            end
            local rows, perr = _M.parse_prom_response(body)
            if not rows then
                -- 正文不是合法 PromQL 响应（404 页面、query 语法错被代理成 200）：
                -- 这是「解析失败」，单独计数，供 lr_gpu_load_power_parse_failures_total
                -- 观测。
                ctx.stats.power_errors = ctx.stats.power_errors + 1
                _M.warn_dedup("power-prom", target, perr, ctx.stamp())
                return false
            end
            -- 逐卡展开（= host_powers 的展开版；expose_cards=false 时两者逐字节同值，
            -- 所以只有 prom 路受益，且缺 gpu 标签时不会比今天少一个读数）。
            local folded, cards, card_hosts_of_query = _M.host_card_powers(rows)
            for host, watts in pairs(folded) do
                if ctx.by_power[host] == nil or watts > ctx.by_power[host] then
                    ctx.by_power[host] = watts
                end
            end
            for key, watts in pairs(cards) do
                -- {host} 模板会发多条查询，同一个 host+gpu 键取最大：与 host 键同
                -- 做法，也保证结果与查询到达顺序无关（同一份输入跑两遍必须逐字节相同）。
                if ctx.by_card_power[key] == nil or watts > ctx.by_card_power[key] then
                    ctx.by_card_power[key] = watts
                end
            end
            for host in pairs(card_hosts_of_query) do
                ctx.card_hosts[host] = true
            end
            ctx.stats.power_probed = ctx.stats.power_probed + 1
            return true
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
        -- 唯一需要在「负载源关着」时说的话：功率是**搭载**在负载源上的（同一个
        -- 定时器、同一次抓取），source=none 时那个定时器根本不启动，于是设了
        -- SMG_LOAD_POWER / SMG_LOAD_POWER_QUERY 也不会有任何读数，而 max_power_w
        -- 会安静地一直按「未知 → 不排除」放行——正是最容易以为自己在生效、其实没有的
        -- 那种配置。留一条去重 WARN，比静默强。
        local want_power = _M.power_config(cfg)
        if want_power.on or want_power.query then
            -- 这里不能用手边的 stamp()：它在下面才赋值，此刻还是个 nil 全局。
            _M.warn_dedup("power-source-none", "none",
                "power requested but SMG_LOAD_SOURCE=none: no timer runs, set it to metrics or prom")
        end
        return stats
    end

    local get = opts.get or seams.default_get
    local post = opts.post or seams.default_post
    local list_workers = opts.workers or seams.default_workers
    local write = opts.write or seams.default_write
    local write_power = opts.write_power or seams.default_write_power
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

    -- 功率通道（缺省关闭）。放在两路分支之前统一算一次，metrics 路用它决定「同一个
    -- 正文要不要顺手扫功率」，prom 路用它决定「要不要多发一条查询」；两处都不启用时
    -- 下面两个分支的执行路径与改动前完全一致。
    local power = _M.power_config(cfg)
    -- 「这一路真的被启用了」而不是「操作员配过某个功率开关」：metrics 路只认 on，prom
    -- 路只认 query。否则会出现一种误导性的导出——source=metrics 却只设了
    -- SMG_LOAD_POWER_QUERY（那条查询在这条路上永远不执行，只有 WARN），power_enabled
    -- 为真于是导出 power_workers=0 / samples_total=0，看板读起来像「功率在生效但一台
    -- 都没采到」，而真相是这条根本不该有读数。
    if stats.source == "metrics" then
        stats.power_enabled = power.on
    elseif stats.source == "prom" then
        stats.power_enabled = power.query ~= nil
    else
        stats.power_enabled = false
    end

    if stats.source == "metrics" then
        local names = _M.metric_key_list(cfg.load_metrics_keys)
        local power_names = _M.metric_key_list(power.keys)
        -- 逐卡归属用的卡号快照（watcher 台账 g| 键，见 default_gpu_hints）。一次 pass
        -- 读一次，不在 worker 循环里摸共享字典。opts.gpu_hints 是测试注入面。
        local hints = opts.gpu_hints
        if hints == nil then
            hints = seams.default_gpu_hints()
        end
        -- 编成查找索引一次（exact + host:port 两级），worker 循环里只查不编。
        hints = _M.hint_index(hints)
        if power.query then
            -- 配了功率 PromQL 却把负载源设成 metrics：这条查询永远不会被执行。
            -- metrics 路没有 Prometheus 可问，只能扫 worker 自己的 /metrics。与其
            -- 静默失效（operator 会一直以为功率上限在生效），留一条去重 WARN。
            _M.warn_dedup("power-query-ignored", "metrics",
                "SMG_LOAD_POWER_QUERY set but SMG_LOAD_SOURCE=metrics; use source=prom",
                stamp())
        end
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
                    -- 功率用**同一次 GET 的正文**再扫一遍：一次抓取两个读数，不额外
                    -- 增加拨号次数（引擎的 /metrics 常有几十 KB，多打一轮是纯浪费）。
                    -- 位置很关键：它排在上面「负载 gauge 有没有采到」的 if/else **之后**
                    -- 而不是它的 else 分支里——一个正文里没有负载 gauge 却带功率 gauge
                    -- 的 exporter（dcgm-exporter 本体就是这种，只有 DCGM_* 没有
                    -- nvidia_gpu_utilization）仍然要交出功率读数，两个读数是独立的。
                    -- 反过来取不到功率也不影响负载那一路：stats.failed 与
                    -- power_failed 各自记账，抓取失败（非 2xx / 超正文上限）只算进
                    -- 负载的 failed，功率这边连 probed 都不加——没有正文就没什么可扫的，
                    -- 再记一次 failure 会把同一个故障数成两遍。
                    if power.on then
                        stats.power_probed = stats.power_probed + 1
                        -- 一次正文扫出「整机最热」与「逐卡」两张表；取哪张由这个 worker
                        -- 认不认得自己的卡决定（四路口径见 assign_power 上方注释）。
                        -- power_watts_by_card 的 whole 与 max_power_watts 逐字节同值
                        -- （同一套 power_watt 筛、同样对全部可用 series 取 max），所以
                        -- 认不出卡的老数据源不会因为这次改动少一个读数。
                        local whole, by_card, have_cards = _M.power_watts_by_card(
                            body, power_names)
                        -- 四路口径与 prom 路完全一致（见 assign_power 上方注释）：
                        -- 源没有逐卡标签 → 整机 max（老数据源一个读数不少）；源是逐卡
                        -- 的 → 只认这个 worker 自己那张卡，认不出卡或该卡没有 series
                        -- 都**不写键**，绝不拿整机 max 冒充——那时整机 max 是邻居卡的
                        -- 瓦特，用它会让一张空闲 worker 因为邻居发热而被排除。
                        local watts, miss_kind = whole, nil
                        if whole ~= nil and have_cards then
                            local gpu = _M.worker_card(record, hints)
                            if gpu == nil then
                                watts = nil
                                miss_kind = "identity"
                            else
                                watts = by_card[gpu]
                                if watts == nil then
                                    miss_kind = "series"
                                else
                                    stats.power_per_card = (stats.power_per_card or 0) + 1
                                end
                            end
                        end
                        if watts == nil then
                            -- 采不到：什么都不写。旧的 pw: 键会在自己的 TTL 后消失，
                            -- registry.power_w() 回到 nil，router 侧按「未知 → 不排除」
                            -- 处理。写 0 或沿用上一次的旧值都会让坏 exporter 把这台
                            -- worker 永久顶在功率上限之外。
                            stats.power_failed = stats.power_failed + 1
                            -- 三种「采不到」在排障上是三个不同的地方，必须分开说：
                            -- 整份正文没有功率 gauge（exporter 没起 / gauge 名单写错）、
                            -- 有 gauge 但这个 worker 认不出自己的卡（容器名不带 gpuN，
                            -- 台账没有 g| 提示）、卡认得出却没有对应 series（卡被直通给
                            -- 别的容器 / 改名后的残留卡号）。全都报 "no power gauge" 的
                            -- 话，运维会被送去查 exporter，而真相在容器命名上。
                            if whole == nil then
                                _M.warn_dedup("power-nogauge", record.url,
                                    "no power gauge in " .. #body .. "B", stamp())
                            elseif miss_kind == "identity" then
                                _M.warn_dedup("power-noident", record.url,
                                    "per-card power available but this worker names no card;"
                                    .. " left uncapped (machine max "
                                    .. string.format("%.1f", whole)
                                    .. " W is another card's reading)", stamp())
                            else
                                _M.warn_dedup("power-nocard", record.url,
                                    "per-card power available but no series for this worker's"
                                    .. " card; left uncapped (machine max "
                                    .. string.format("%.1f", whole)
                                    .. " W not used as a substitute)", stamp())
                            end
                        else
                            local stored, why = write_power(record.id, watts, stamp(),
                                ttl_secs, record.url)
                            if stored then
                                stats.power_matched = stats.power_matched + 1
                            elseif why == "rejected" then
                                stats.power_rejected = stats.power_rejected + 1
                            else
                                stats.power_errors = stats.power_errors + 1
                            end
                        end
                    end
                end
            end
        end
    elseif stats.source == "prom" then
        local endpoint = _M.query_endpoint(cfg.load_prom_url)
        local template = cfg.load_prom_query
        if power.on and not power.query then
            -- 反过来：metrics 路的功率开关对 prom 路没有意义（那里没有 /metrics
            -- 正文可扫），功率要靠第二条查询。同样只是提示，不改变行为。
            _M.warn_dedup("power-flag-ignored", "prom",
                "SMG_LOAD_POWER is the metrics-path switch; prom needs SMG_LOAD_POWER_QUERY",
                stamp())
        end
        if not endpoint or type(template) ~= "string" or template == "" then
            -- 只配功率查询、没配负载查询：以前这里整轮 skip，于是「只想从 Prometheus
            -- 拿功率」这种完全合理的部署永远采不到读数，max_power_w 一直按「未知 →
            -- 不排除」放行，操作员却以为上限在生效。现在负载那一路自己 skip，功率
            -- 那一路照常执行；两条查询共用同一个 SMG_LOAD_PROM_URL，所以 endpoint
            -- 缺失仍然是整轮 skip。
            if endpoint and power.query then
                _M.warn_dedup("prom-config", tostring(cfg.load_prom_url),
                    "SMG_LOAD_PROM_QUERY empty: running the power query only", stamp())
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
            by_host = {}, by_power = {}, by_card_power = {}, card_hosts = {},
            stamp = stamp,
        }

        -- 功率那一路复用同一个 endpoint、同一条 POST helper、同一套
        -- parse_prom_response / host 折叠，只是换成第二条 PromQL（独立配置项
        -- SMG_LOAD_POWER_QUERY，留空即不采），并把值交给 host_powers() 而不是
        -- host_values()——差的正是 normalize() 那一步。
        --
--- 为什么不与负载查询合并成一条 PromQL：两者的 gauge 家族、聚合口径常常不同
--- （负载 avg by (instance) (DCGM_FI_DEV_GPU_UTIL)，功率
--- max by (Hostname, instance) (DCGM_FI_DEV_POWER_USAGE)），拼成 or/vector(0)
--- 之类的花活会让一条写坏时两路一起失效，也没法分别归因。两次查询的代价是一个 tick
--- 多一个 POST，本 fleet 的 Prometheus 完全吃得住。
---
--- 写这条 PromQL 时请**保留 instance 标签**（by (Hostname, instance) 或直接裸查
--- DCGM_FI_DEV_POWER_USAGE）：本 fleet 的 worker 全部注册成 http://127.0.0.1:80xx，
--- 而机器名标签（Hostname）与 IP 之间没有任何映射可用，只有 exporter 的抓取地址
--- 127.0.0.1:9400 能把读数交回本机 worker。聚合时把 Hostname 一起 by 上，是为了让
--- host_card_powers() 在「同一台 Prometheus 抓了多台机器的本机 exporter」时仍能识破归属
--- 冲突、宁可整台不采纳，也不会把 A 机最热的卡挂到 B 机头上。
---
--- 而且必须把 gpu 留在 by 里（缺省查询串：
---     max by (Hostname, instance, gpu) (DCGM_FI_DEV_POWER_USAGE)
--- ）：245/246 那份 compose 写的 max by (Hostname,instance) 正是 21.k:8801 八个
--- worker 全部读到 342.371 的直接原因——聚合发生在 Prometheus 侧，逐卡标签根本没
--- 能到达网关，网关再怎么改也只是在一条已折平的 series 上做文章。逐卡读数在
--- exporter 上一直齐全（/data/tmp/dcgm-metrics-9400.txt 有 gpu="0"…"7" 八条），
--- 所以口径是「查询别聚合掉 gpu，网关按 worker 自己的卡分发」。
        -- 逐卡表，与「这一台机器的数据源到底是不是逐卡的」。后者取自 power_fold 自己
        -- 给出的 card_hosts（按 host 记），刻意**不是**一个全局布尔：prom 路一轮可以跨
        -- 多台机器，而一个 fleet 里「A 机跑 dcgm-exporter、B 机只有 node_exporter」是
        -- 常态。用全局标志的话，A 机有逐卡 series 会把 B 机一起拖进逐卡口径，于是 B 机
        -- 那些「本来就认不出卡」的 worker 一个读数都拿不到 —— 一台机器的监控形状把
        -- 另一台机器的功率通道关掉。
        -- 功率这一路：先把自己的 vector 拉回来（查询是否按 host 展开由**它自己的**
        -- 模板决定，与负载查询互不牵连），再交给 assign() 按 host 落到 worker 上。
        -- assign() 只按 split_host 取值、不碰数值语义，所以负载那一路的同一套映射
        -- 规则原样可用：同机多个 worker（DP rank、一机两引擎）自动共享同一个读数，
        -- series 找不到归属的记成 power_unmatched 而不是硬塞给谁。
        if power.query then
            if _M.query_needs_host(power.query) then
                local queried = {}
                for i = 1, #workers do
                    local record = workers[i]
                    local pq = _M.render_query(power.query, record)
                    if pq then
                        if not queried[pq] then
                            queried[pq] = true
                            one_power(prom_ctx, pq, record.url)
                        end
                    else
                        -- 这条 worker 的 url 解析不出 host，模板没法展开：与负载
                        -- 那一路的 skipped 同义——它不是「监控系统没给出读数」，而是
                        -- 「这个 worker 没法问」，混进 failed 会让 lr_gpu_load_power_
                        -- parse_failures_total 随坏 url 的个数放大，指错排障方向。
                        stats.power_skipped = stats.power_skipped + 1
                    end
                end
            else
                one_power(prom_ctx, power.query, endpoint)
            end

            local url_for_power = {}
            for i = 1, #workers do
                url_for_power[workers[i].id] = workers[i].url
            end
            local hints = opts.gpu_hints
            if hints == nil then
                hints = seams.default_gpu_hints()
            end
            hints = _M.hint_index(hints)
            -- 按 worker 各自的卡分发（四路口径见 assign_power 上方注释：源无逐卡标签
            -- → 整机 max；认得出且有该卡 series → 本卡瓦特；认不出卡 / 该卡无 series
            -- → 什么都不写，绝不拿邻居卡的整机 max 冒充）。
            local p_assigned, p_unmatched = _M.assign_power(workers, prom_ctx.by_power,
                prom_ctx.by_card_power, prom_ctx.card_hosts, hints)
            stats.power_unmatched = p_unmatched
            -- 「本 pass 里有多少 worker 真的按自己那张卡拿到读数」。没有这个计数，
            -- 「全部逐卡成功」与「全部悄悄退回整机 max」在 /metrics 上长得一模一样，
            -- 而后者正是 342.371 故障能一直活着的原因。
            local card_hits = 0
            for i = 1, #workers do
                local w = workers[i]
                local host = w and _M.split_host(w.url)
                if w and host and prom_ctx.card_hosts[host] and p_assigned[w.id] ~= nil
                    and _M.worker_card(w, hints) ~= nil then
                    card_hits = card_hits + 1
                end
            end
            stats.power_per_card = card_hits
            -- 查询本身成功却一个可用读数都没有（gauge 名写错、那批机器没起 dcgm、
            -- 整表都是 NaN）：与 metrics 路的 no-gauge 同义，记一次 failed 并留一条
            -- 去重 WARN。放在这里而不是 one_power 内，是因为按 host 展开时会有多次
            -- 查询，只有折叠完才知道「整个 vector 到底有没有可用读数」。
            if next(prom_ctx.by_power) == nil and (stats.power_errors or 0) == 0 then
                stats.power_failed = stats.power_failed + 1
                _M.warn_dedup("power-prom-nogauge", tostring(power.query),
                    "power query returned no usable watt series", stamp())
            elseif next(p_assigned) == nil and next(prom_ctx.by_power) ~= nil then
                -- 查得到读数、一个 worker 都没配上：几乎只会是标签口径对不上（比如
                -- by(Hostname) 折叠出的机器名与注册成 IP:port 的 worker url 永不在同
                -- 一把键上相遇）。这是「功率上限看着在生效、其实一台都没进」最隐蔽的
                -- 一种，只靠 power_unmatched 计数太容易漏看，所以补一条去重 WARN。
                _M.warn_dedup("power-prom-unassigned", tostring(power.query),
                    "power series matched no pooled worker (" ..
                    tostring(stats.power_unmatched) .. " hosts unmatched)", stamp())
            end
            for id, watts in pairs(p_assigned) do
                local stored, why = write_power(id, watts, stamp(), ttl_secs,
                    url_for_power[id])
                if stored then
                    stats.power_matched = stats.power_matched + 1
                elseif why == "rejected" then
                    stats.power_rejected = stats.power_rejected + 1
                else
                    stats.power_errors = stats.power_errors + 1
                end
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
