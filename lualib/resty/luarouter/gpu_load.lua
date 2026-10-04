-- GPU 负载源（doc/gap-gpu-load.md）。
--
-- 两路外部负载源，统一写进 registry 的 worker 负载字段，让 power_of_two 与
-- cache_aware 的负载逃逸吃到真实 GPU/队列压力：
--
--   * source=metrics  GET {worker.url}/metrics，纯 Lua 解析 Prometheus 文本协议，
--     在 SMG_LOAD_METRICS_KEYS 给的 gauge 名集合里取最大值，归一化到 0..1。
--   * source=prom     POST {SMG_LOAD_PROM_URL}/api/v1/query，用 SMG_LOAD_PROM_QUERY
--     这条 PromQL 从既有监控（Prometheus/VictoriaMetrics）同步抓取，解析
--     data.result[].value，按 instance/host 标签映射回在池 worker。
--   * source=none     缺省：没有定时器、没有抓取、registry 一个 key 都不写，
--     也就是零行为变化。
--
-- 第三条通道：GPU **功率**（worker 记录上的 max_power_w 上限，判定在 registry 的
-- capacity_exclusion，本模块只负责喂读数）。它与上面
-- 两路共用同一次抓取（metrics 路复用同一个 /metrics 正文，prom 路各自多一条 PromQL），
-- 但走 registry 的独立键（pw:，毫瓦）而不是负载归一化那一路：
--   * 功率是**绝对瓦特**，不是 0..1 打分，所以绝不进 _M.normalize()（那会把 90 W
--     当成 90 % 折成满载），也不写进 load()/K_XLOAD。
--   * 读数优先按**卡**归属：worker 认得出自己那张卡（watcher 台账的 g|<url> 键，由
--     watcher 从容器名 pennyroyal-gpu7 → "7" 解析而来；registry 记录的 labels.gpu 只作
--     第二来源，理由见 worker_card() 上方）且数据源给了逐卡 series 时，写的是
--     **它自己那张卡**的瓦特。「认不出卡」与「该卡没有 series」两种情形**都不写键**，
--     不拿整机 max 顶替：源已经是逐卡的时候，整机 max 是邻居那张卡的瓦特，写进来就等于
--     让一张空闲 worker 因为邻居满载而被排除出候选集——那正是下面「绝不写 0、绝不沿用
--     旧值」要防的同一类事故（监控的一个缺口吃掉容量）。代价如实说明：认不出卡的 worker
--     不受功率上限约束，与 exporter 掉线时一模一样；要把它纳进上限判定，就把容器登记成
--     带 gpuN 的名字，并看 lr_gpu_load_power_per_card_workers 覆盖了几台。
--     只有「数据源根本没有逐卡标签」这一种才回落整机 max（node_exporter、operator 写
--     by(Hostname)、或引擎只报一个整机 gauge 的场景——那也是改动前的唯一口径，逐字节
--     保持不变，否则一直在用的数据源会在逐卡落地当天变黑）。两条通道在意的那条边界
--     始终一致：整机口径取 max 而不是取和/取平均（取和会让「一张满载七张空闲」
--     看起来仍然很闲）。
--     口径（router/文档/UI 必须按这一句写，运维按它配阈值）：per-worker 功率上限
--     max_power_w 比较的是「该 worker 自己那张卡的绝对瓦特」；数据源没有逐卡标签时是
--     「本机最热那张卡的绝对瓦特」；认不出卡或该卡无 series 时**没有读数**（不排除）。
--     21.k 生产上 8 个 worker 曾全部读到同一个数（245/246 的
--     max by (Hostname,instance) 把 8 张卡折成 1 条 series，逐卡标签在 Prometheus 侧就
--     丢了），power_of_two 与 max_power_w 因此零区分度；逐卡数据本身在 exporter 上一直
--     齐全（DCGM_FI_DEV_POWER_USAGE{gpu="6",...} 93.111），要的是查询别把它聚合掉，
--     默认查询串见 host_card_powers() 上方注释。
--   * 采不到就什么都不写，让 TTL 自然过期回到 registry.power_w() == nil，router 侧
--     「未知 -> 不排除」。写 0 或沿用上一次的旧值都会让一个坏掉的 exporter 把 worker
--     永久顶在功率上限之外，那是监控系统故障吃掉容量。
-- 缺省关闭：metrics 路要 SMG_LOAD_POWER=1 才扫功率，prom 路要 SMG_LOAD_POWER_QUERY
-- 非空才多发一条查询，两者都不设时本模块的抓取次数与写入的 key 和改动前逐个字节一致。
--
-- 分两层（与 watcher.lua / mesh.lua 同一形状）：
--   * 纯逻辑层（本文件前半）：Prometheus 文本解析、PromQL 模板渲染、vector 到 worker
--     的映射、负载合成。不碰 ngx、不 require registry，所以
--     test/unit/test_gpu_load.lua 能在 luajit 下直接断言这些语义。
--   * live 层（本文件后半）：cosocket 抓取（复用 hb 的 HTTP helper 与它的连接池
--     分类）、共享字典写入、Warn 去重、自己的 interval 定时器。定时器由 hb.start()
--     拉起（init.lua 不在本模块的所有权里，hb 已经有 worker 0 定时器模式可照抄）。
--
-- 失败语义：任何一路源的错误（连接失败、超时、非 2xx、正文不是合法 exposition、
-- PromQL 返回非法 JSON）都只是「这一 tick 没有样本」——不抛错、不记健康失败、
-- 绝不摘 worker，同一条 WARN 一小时内只说一次。

local cjson = require "cjson.safe"

local _M = { _VERSION = "0.1.0" }

---Whether this file is running inside nginx *right now*.
---
---Deliberately a predicate rather than the load-time snapshot watcher.lua and
---mesh.lua use: the pure-Lua half of this module is unit-tested under luajit with
---no ngx at all, and the live half (warn dedup, the metric families, the timer) has
---to be testable in the same file. Reading the global per call keeps both halves
---honest and costs one global lookup on paths that run once per worker per tick.
---@return table|nil @ the ngx global, or nil outside nginx
local function live_ngx()
    if type(ngx) ~= "table" then
        return nil
    end
    return ngx
end

local MAX_TIMER_DELAY = 3600
-- A worker's /metrics is usually tens of KB; above this the pass gives up on the
-- body rather than parse a megabyte-scale exposition every interval.
local MAX_BODY_BYTES = 4 * 1024 * 1024
-- One WARN line per (class, target) inside this window.
local WARN_DEDUP_SECS = 3600
local LOCK_DICT = "lr_locks"
local TICK_LOCK = "gpu-load-tick"
-- Gauge names tried when SMG_LOAD_METRICS_KEYS is unset: the DCGM/nvidia-exporter
-- utilization gauge (percent), and the two KV-cache gauges that report a fraction
-- (0..1). Both spellings of a name are matched colon-insensitively (see canon()).
local DEFAULT_METRIC_KEYS = {
    "nvidia_gpu_utilization",
    "dcgm_gpu_utilization",
    "gpu_cache_usage_perc",
    "vllm:gpu_cache_usage_perc",
}
_M.DEFAULT_METRIC_KEYS = DEFAULT_METRIC_KEYS

-- 功率 gauge 的候选名（SMG_LOAD_POWER_KEYS 为空时用）。列在这里的名字都是在
-- 21.k（8x RTX PRO 6000 Blackwell SE）上真实抓到的写法：
--   * DCGM_FI_DEV_POWER_USAGE        dcgm-exporter :9400 的每卡瓦特，
--       '# HELP DCGM_FI_DEV_POWER_USAGE Power draw (in W).'，样本
--       DCGM_FI_DEV_POWER_USAGE{gpu="0",Hostname="gpu-pro6000-1",...} 89.780000
--       （抓取：ssh 21.k 'curl -s 127.0.0.1:9400/metrics'，样本
--        /data/tmp/dcgm-metrics-9400.txt）。Prometheus :9092 里同名，标签
--       多出 instance="127.0.0.1:9400" / job="dcgm"。
--   * node_hwmon_power_average_watt  node_exporter 的 hwmon 功率，只有整机口径，
--       **故意不进缺省名单**。折叠规则是「取最大」，而 node_hwmon 给的是整机/电源
--       口径（一台 8 卡机能读到 700 W+），把它和每卡读数混在一起会让最热的卡被高估，
--       配上 max_power_w 就是「这台机器上的所有 worker 永久高于上限」——监控系统的一
--       个口径错误吃掉整台机器的容量，比没有读数糟得多。确实只有 node_exporter 的
--       机器请显式写进 SMG_LOAD_POWER_KEYS（那时取最大就是 operator 自己的选择）。
-- 推理引擎自己的 /metrics 一律**没有**功率：21.k 上的 sglang 8026 全文 87 KB 里
-- grep -iE 'power|watt' 命中 0 行（样本 /data/tmp/sglang-metrics-8026.txt），vLLM
-- 同样只有 gpu_cache_usage_perc 一类。所以 metrics 路只对「引擎与 dcgm-exporter
-- 同机、且 operator 把 SMG_LOAD_METRICS_PATH 指到 exporter」的情形有意义，
-- 跨机采集请用 prom 路。
local DEFAULT_POWER_METRIC_KEYS = {
    "dcgm_fi_dev_power_usage",
}
_M.DEFAULT_POWER_METRIC_KEYS = DEFAULT_POWER_METRIC_KEYS

-- 一个还能被当成「单卡功率」的读数上限。dcgm 的 DCGM_FI_DEV_POWER_USAGE 是每卡
-- 瞬时瓦特，本 fleet 里最大的卡（Blackwell SE / H200 级）功率墙也在 600-1000 W，
-- 取 5000 留五倍余量。超出的几乎只会是被误配进来的**能量计数器**（焦耳，例如
-- DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION 会爬到千万）、整机功耗或 UPS 读数——那种
-- 数字喂给功率上限判定，会让这一路 worker 永久高于上限而被整个摘出候选集，
-- 也就是一个配错的 gauge 名单独干掉一个实例。宁可回「未知」。
local MAX_PLAUSIBLE_WATTS = 5000
_M.MAX_PLAUSIBLE_WATTS = MAX_PLAUSIBLE_WATTS

-- Identity labels a Prometheus series can carry the machine in. `instance` is what
-- the exporters get scraped with (host:port), the rest cover the SD-produced label
-- sets (kubernetes_pod / node / docker compose).
local HOST_LABELS = { "instance", "host", "hostname", "node", "pod", "name" }
_M.HOST_LABELS = HOST_LABELS

-- ------------------------------------------------------------------ small utils

local function now_ms()
    local ngxm = live_ngx()
    if ngxm and ngxm.now then
        return ngxm.now() * 1000
    end
    return os.time() * 1000
end

---Canonical metric name: trimmed, lower-cased, colons folded to underscores.
---
---Colon folding is what lets one env value match both the wire name
---(`vllm:gpu_cache_usage_perc`, which is what vLLM actually writes) and the
---underscored spelling Prometheus renders after the aggregator's blanket
---`:`→`_` rewrite (router.lua's /engine_metrics path).
---@param name string|nil
---@return string|nil
local function canon(name)
    if type(name) ~= "string" then
        return nil
    end
    local trimmed = string.match(name, "^%s*(.-)%s*$")
    if trimmed == "" then
        return nil
    end
    return string.lower((string.gsub(trimmed, ":", "_")))
end
_M.canon = canon

---Accept a list table or a comma/space separated string and return the canon set.
---@param keys table|string|nil
---@return table[]
function _M.metric_key_list(keys)
    local out = {}
    if type(keys) == "string" then
        for item in string.gmatch(keys, "[^,%s]+") do
            local name = canon(item)
            if name then
                out[#out + 1] = name
            end
        end
        return out
    end
    if type(keys) ~= "table" then
        return out
    end
    for i = 1, #keys do
        local name = canon(keys[i])
        if name then
            out[#out + 1] = name
        end
    end
    return out
end

---Parse one Prometheus sample value.
---
---`NaN`, `+Inf`, `-Inf` and the empty string are legal exposition text and all
---mean "no usable number here"; a NaN in particular compares false against
---everything, so letting it through would silently poison a max() reduction.
---@param text string|number|nil
---@return number|nil
function _M.parse_number(text)
    if type(text) == "number" then
        if text ~= text or text == math.huge or text == -math.huge then
            return nil
        end
        return text
    end
    if type(text) ~= "string" then
        return nil
    end
    local trimmed = string.match(text, "^%s*(.-)%s*$")
    if trimmed == "" then
        return nil
    end
    -- tonumber() itself answers "nan"/"inf" on LuaJIT, so reject the words first.
    local lowered = string.lower(trimmed)
    if lowered == "nan" or lowered == "inf" or lowered == "+inf"
        or lowered == "-inf" then
        return nil
    end
    local value = tonumber(trimmed)
    if value == nil or value ~= value
        or value == math.huge or value == -math.huge then
        return nil
    end
    return value
end

------------------------------------------------------------------ url / host keys

---Authority split of an http(s) URL: host without the port, plus the port.
---
---The DP rank suffix (`http://h:p@2`, see registry.strip_rank) and any userinfo
---are dropped the same way the dial path drops them; a bracketed IPv6 authority
---keeps its address. Trailing dots are stripped so `gpu1.example.com.` matches the
---exporter's `gpu1.example.com:9100` instance.
---@param url string|nil
---@return string|nil host, number|nil port
function _M.split_host(url)
    if type(url) ~= "string" or url == "" then
        return nil
    end
    local rest = string.match(url, "^%a[%w+.-]*://(.*)$")
    if not rest then
        -- Not a url at all (an operator typo in SMG_WORKER_URLS, junk handed over by
        -- a test seam). Returning the text as a host would let a stray record own
        -- whatever the prometheus vector says about a machine of that name.
        return nil
    end
    local authority = string.match(rest, "^([^/?#]+)") or rest
    -- strip ":<port>" tail first only for the rank probe (a rank is always last)
    local rank = string.match(authority, "^(.-)@%d+$")
    if rank then
        authority = rank
    end
    local at = string.match(authority, "^.*@(.+)$")
    if at then
        authority = at
    end
    local host, port
    if string.sub(authority, 1, 1) == "[" then
        host = string.match(authority, "^%[(.-)%]")
        port = tonumber(string.match(authority, "%]:(%d+)$"))
    else
        local before, after = string.match(authority, "^(.-):(%d+)$")
        if before then
            host, port = before, tonumber(after)
        else
            host = authority
        end
    end
    if host == nil or host == "" then
        return nil
    end
    host = string.gsub(host, "%.$", "")
    return string.lower(host), port
end

---Normalise one identity-label value (an `instance`, a `node`, a pod name) into a
---host key comparable with split_host()'s answer for the worker url.
---@param value string|number|nil
---@return string|nil
function _M.host_from_label(value)
    if value == nil then
        return nil
    end
    local text = tostring(value)
    if text == "" then
        return nil
    end
    -- A url-ish label ("http://h:p/metrics") and an "h:p" both reduce to "h".
    text = string.match(text, "^%a[%w+.-]*://(.*)$") or text
    text = string.match(text, "^([^/?#]+)") or text
    local rank = string.match(text, "^(.-)@%d+$")
    if rank then
        text = rank
    end
    local host = _M.split_host("http://" .. text)
    return host
end

---Host key used to match a Prometheus series to a worker: the first identity label
---that is present and non-blank, in HOST_LABELS order.
---@param labels table|nil
---@return string|nil
function _M.host_of(labels)
    if type(labels) ~= "table" then
        return nil
    end
    for i = 1, #HOST_LABELS do
        local host = _M.host_from_label(labels[HOST_LABELS[i]])
        if host then
            return host
        end
    end
    return nil
end

------------------------------------------------------------------ prometheus text

---Split one exposition line into (metric identity, value text).
---
---A character scan rather than a pattern because a label value may contain
---whitespace, commas, braces and escaped quotes, so "the first space separates
---name from value" is wrong for `a{x="1 2"} 3`. Returns nil for anything that is
---not a sample line.
---@param line string
---@return string|nil identity, string|nil value_text
local function split_sample(line)
  -- A metric name may not begin with '#', so a HELP/TYPE line (or any other
  -- comment) answers "not a sample" here instead of relying on each caller
  -- to filter the exposition first.
  if string.sub(line, 1, 1) == "#" then
    return nil
  end
    local n = #line
    local i = 1
    local quoted, braced = false, false
    local split_at
    while i <= n do
        local c = string.sub(line, i, i)
        if quoted then
            if c == "\\" then
                i = i + 2
            else
                if c == '"' then
                    quoted = false
                end
                i = i + 1
            end
        elseif braced then
            if c == "\\" then
                i = i + 2
            elseif c == '"' then
                quoted = true
                i = i + 1
            elseif c == "}" then
                braced = false
                i = i + 1
            else
                i = i + 1
            end
        elseif c == "{" then
            braced = true
            i = i + 1
        elseif c == " " or c == "\t" then
            split_at = i
            i = n + 1
        else
            i = i + 1
        end
    end
    if not split_at then
        return nil
    end
    local identity = string.sub(line, 1, split_at - 1)
    if identity == "" then
        return nil
    end
    local brace = string.find(identity, "{", 1, true)
    if brace then
        identity = string.sub(identity, 1, brace - 1)
    end
    if identity == "" then
        return nil
    end
    local rest = string.sub(line, split_at + 1)
    local value = string.match(rest, "^%s*([^%s]+)")
    -- Third return: the identity *with* its label section, which is what the
    -- per-card power channel needs (split_sample()'s first return drops the
    -- braces, and the max-gauge readers never wanted them). Existing callers
    -- take two values, so this is additive.
    return identity, value, string.sub(line, 1, split_at - 1)
end
_M.split_sample = split_sample

---Max sample value over every wanted gauge name in one Prometheus exposition.
---
---Every label set of a matching name participates (an eight-GPU node exposes one
---series per GPU and the scheduler wants the hottest card), so this is a max over
---`name` x `labels`. The metric name is compared through canon(), i.e. colons and
---case do not matter; a `# HELP` / `# TYPE` line is skipped by its leading `#`, and
---a sample carrying an unparseable value (NaN, +Inf, truncation) is dropped rather
---than ending the parse.
---@param text string|nil @ the exposition body
---@param names table[]|string|nil @ gauge names to keep (default DEFAULT_METRIC_KEYS)
---@return number|nil raw_max @ the largest usable value, nil when none matched
function _M.max_gauge(text, names)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local wanted = {}
    local list = _M.metric_key_list(names)
    if #list == 0 then
        list = _M.metric_key_list(DEFAULT_METRIC_KEYS)
    end
    for i = 1, #list do
        wanted[list[i]] = true
    end
    local best
    for line in string.gmatch(text, "[^\r\n]+") do
        -- Skip blank and comment lines without a pattern: '#' is the first byte of
        -- both HELP and TYPE, and no metric name may start with it.
        if string.byte(line, 1) ~= 35 then
            local identity, value_text = split_sample(line)
            local name = canon(identity)
            if name and wanted[name] then
                local value = _M.parse_number(value_text)
                if value and (best == nil or value > best) then
                    best = value
                end
            end
        end
    end
    return best
end

---Normalize a raw gauge reading to a 0..1 load.
---
---Percent gauges (nvidia/dcgm utilization) and fraction gauges (the KV-cache
---usage family) share one field, so the scale is inferred from the reading:
---anything above 1 is a percent and is divided by 100. Values above 100 percent
---and negatives are unusable (a counter-style metric that someone pointed at
---this knob), as is NaN; nil means "no load for this worker this tick".
---@param value number|nil
---@return number|nil load @ normalized 0..1
function _M.normalize(value)
    local number = _M.parse_number(value)
    if number == nil then
        return nil
    end
    local load = number
    if load > 1 then
        load = load / 100
    end
    if load < 0 then
        return nil
    end
    -- The one clamp that is deliberate rather than defensive: a gauge that reports
    -- 105 % (a driver rounding utilization up, a cache gauge nudged over its own
    -- capacity by a scheduler) is still a busy worker, and dropping the sample over
    -- 5 % of rounding would make the busiest card look like it has no reading at all.
    -- A value so far out that the division cannot rescue it (1e6) is above, not at,
    -- the top of the range: it reads as fully busy, which is the safe direction for
    -- a scheduler.
    if load > 1 then
        load = 1
    end
    return load
end

--------------------------------------------------------------- power (absolute W)

---Usable single-GPU watt reading, or nil.
---
---三道筛子，每一道都对应一种「会把功率上限判定带偏」的真实读数：
---  * 非数 / NaN / ±inf：同 parse_number() 的口径。
---  * <= 0：本 fleet 的卡（RTX PRO 6000 SE）空载也有 80-90 W，读到 0 只可能是
---    exporter 把「没有这个字段」渲染成了 0。registry 允许存 0，而 0 会被判成
---    「远低于任何上限」，等于一个坏 exporter 给这台 worker 发了免检牌。
---  * >= MAX_PLAUSIBLE_WATTS：几乎只会是被误配进 SMG_LOAD_POWER_KEYS 的能量计数器
---    （DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION 是焦耳，会爬到 1e7 以上）或整机/UPS
---    功率。这种数字进池子会让该 worker 永久高于上限、整个从候选集消失。
---宁可回 nil（未知 → 不排除），也不猜。
---@param value number|string|nil
---@return number|nil watts
function _M.power_watt(value)
    local number = _M.parse_number(value)
    if number == nil or number <= 0 or number >= MAX_PLAUSIBLE_WATTS then
        return nil
    end
    return number
end

---Max **usable** watt reading over every power gauge in one exposition.
---
---Same shape as max_gauge() (any label set of any wanted name participates) but
---not the same reduction rule: values go through power_watt() first, so a body
---that carries one honest 96 W series and one mis-fed 1.2e7 energy counter still
---answers 96 W instead of poisoning the cap. max_gauge() cannot do this because
---it reduces over raw values before normalize() ever sees them.
---@param text string|nil @ the exposition body
---@param names table[]|string|nil @ gauge names to keep (default DEFAULT_POWER_METRIC_KEYS)
---@return number|nil watts
function _M.max_power_watts(text, names)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local wanted = {}
    local list = _M.metric_key_list(names)
    if #list == 0 then
        list = _M.metric_key_list(DEFAULT_POWER_METRIC_KEYS)
    end
    for i = 1, #list do
        wanted[list[i]] = true
    end
    local best
    for line in string.gmatch(text, "[^\r\n]+") do
        if string.byte(line, 1) ~= 35 then
            local identity, value_text = split_sample(line)
            local name = canon(identity)
            if name and wanted[name] then
                local watts = _M.power_watt(value_text)
                if watts and (best == nil or watts > best) then
                    best = watts
                end
            end
        end
    end
    return best
end

---Per-card watt readings for one /metrics exposition (the metrics path's power scan).
---
---The metrics path dials a worker's *own* /metrics, so every series in the body
---belongs to that machine: no host matching is involved (that is the prom path's
---problem, and host_powers() owns it). Two reductions come out of one pass:
---  * whole -> the max over every usable series: byte-for-byte what
---    max_power_watts() answers today, and the fallback whenever the card cannot be
---    named (a worker whose record carries no labels.gpu, or an exporter that
---    exposes no gpu label at all — node_exporter, a machine-level gauge).
---  * by_card[gpu] -> max over the series naming that card, only for series whose
---    gpu label is a pure digit.
---Both go through power_watt(), so a mis-fed energy counter is screened out before
---either reduction, exactly as in max_power_watts().
---@param text string|nil @ the exposition body
---@param names table[]|string|nil @ gauge names to keep (default DEFAULT_POWER_METRIC_KEYS)
---@return number|nil whole @ hottest card on the machine
---@return table @ by_card @ gpu id -> watts
---@return boolean @ have_cards @ any usable series named a card
function _M.power_watts_by_card(text, names)
    local whole, by_card, have_cards = nil, {}, false
    if type(text) ~= "string" or text == "" then
        return whole, by_card, have_cards
    end
    local wanted = {}
    local list = _M.metric_key_list(names)
    if #list == 0 then
        list = _M.metric_key_list(DEFAULT_POWER_METRIC_KEYS)
    end
    for i = 1, #list do
        wanted[list[i]] = true
    end
    for line in string.gmatch(text, "[^\r\n]+") do
        if string.byte(line, 1) ~= 35 then
            local identity, value_text, labelled = split_sample(line)
            local name = canon(identity)
            if name and wanted[name] then
                local watts = _M.power_watt(value_text)
                if watts then
                    if whole == nil or watts > whole then
                        whole = watts
                    end
                    local labels = _M.parse_labels(labelled)
                    local raw = labels and labels.gpu
                    local gpu = nil
                    if type(raw) == "string" or type(raw) == "number" then
                        local t = string.match(tostring(raw), "^%s*(.-)%s*$")
                        if t and string.match(t, "^%d+$") then
                            gpu = t
                        end
                    end
                    if gpu then
                        have_cards = true
                        if by_card[gpu] == nil or watts > by_card[gpu] then
                            by_card[gpu] = watts
                        end
                    end
                end
            end
        end
    end
    return whole, by_card, have_cards
end

---Split the label portion out of one sample identity ("name{k=\"v\"}").
---
---split_sample() drops the braces (max_gauge only needs the metric name), but the
---per-card power channel needs gpu="6", so the name is returned together with the
---label set parsed here. A malformed label section answers nil, which makes the row
---behave exactly like an unlabelled one (→ whole-machine reduction), never a guess.
---@param identity string @ text before the value, braces included
---@return table|nil labels @ keys lower-cased; nil when there is no usable pair
function _M.parse_labels(identity)
    if type(identity) ~= "string" then
        return nil
    end
    local open = string.find(identity, "{", 1, true)
    if not open then
        return nil
    end
    local body = string.sub(identity, open + 1)
    local close = #body + 1
    local quoted = false
    local i = 1
    while i <= #body do
        local c = string.sub(body, i, i)
        if quoted then
            if c == "\\" then
                i = i + 2
            else
                if c == '"' then
                    quoted = false
                end
                i = i + 1
            end
        elseif c == "\\" then
            i = i + 2
        elseif c == '"' then
            quoted = true
            i = i + 1
        elseif c == "}" then
            close = i
            break
        else
            i = i + 1
        end
    end
    local inner = string.sub(body, 1, close - 1)
    if inner == "" then
        return nil
    end
    local out = {}
    local pos = 1
    local n = #inner
    while pos <= n do
        local j = pos
        local q = false
        while j <= n do
            local c = string.sub(inner, j, j)
            if q then
                if c == "\\" then
                    j = j + 2
                else
                    if c == '"' then
                        q = false
                    end
                    j = j + 1
                end
            elseif c == "\\" then
                j = j + 2
            elseif c == '"' then
                q = true
                j = j + 1
            elseif c == "," then
                break
            else
                j = j + 1
            end
        end
        local pair = string.sub(inner, pos, j - 1)
        pos = j + 1
        local key, value = string.match(pair, "^%s*([%w_]+)%s*=%s*\"(.-)\"%s*$")
        if not key then
            key, value = string.match(pair, "^%s*([%w_]+)%s*=%s*([^%s,]+)%s*$")
        end
        if key and value ~= nil then
            out[string.lower(key)] = value
        end
    end
    if next(out) == nil then
        return nil
    end
    return out
end

---The card id a worker record carries, or nil.
---
---The registry keeps it at labels.gpu, written by the watcher out of the container
---name (pennyroyal-gpu7 -> "7"). A hand-rolled POST /workers body can put a number
---there, so it is stringified; only a pure-digit id counts as a card, because
---anything else ("all", "nvidia0", a UUID) can never match a DCGM gpu label and
---would turn "we know the card" into a lookup that silently always misses.
---@param record table|nil
---@return string|nil gpu
function _M.worker_gpu(record)
    if type(record) ~= "table" then
        return nil
    end
    local raw = type(record.labels) == "table" and record.labels.gpu or nil
    if raw == nil or raw == false or raw == cjson.null then
        return nil
    end
    local text = string.match(tostring(raw), "^%s*(.-)%s*$")
    if text == nil or not string.match(text, "^%d+$") then
        return nil
    end
    return text
end

---Separator for per-card keys: a control byte appears in neither a Prometheus label
---value (exporters escape it) nor a host key, so host..SEP..gpu cannot collide with
---either half, and a key can never be forged from ordinary text.
local CARD_SEP = "\001"
_M.CARD_SEP = CARD_SEP

---@param host string|nil
---@param gpu string|number
---@return string
function _M.card_key(host, gpu)
    return tostring(host or "") .. CARD_SEP .. tostring(gpu)
end

---The card id to attribute one worker's power reading to, or nil for "unknown".
---
---Two sources, checked in this order, and the order matters in production:
---  * the watcher ledger's g|<url> hint, which the watcher writes for **every**
---    candidate it discovers (reconcile), independent of whether that worker is a
---    protected pre-existing row;
---  * registry's labels.gpu, which only carries a value for workers the watcher
---    actually registered.
---The ledger first because 21.k:8801's eight workers are all seeded from
---SMG_WORKER_URLS (bootstrap -> registry.add({url=...}), no labels) and then
---permanently protected by the watcher's guard 3, so their record.labels stays
---empty forever -- registry.add's idempotent branch (registry.lua:1476) answers a
---duplicate url with a failed job and *does not touch the record*, so a later add
---can never back-fill labels either. Reading the ledger is what keeps this whole
---feature inside gpu_load.lua + watcher.lua: no registry change is required, and
---nothing here depends on labels ever arriving.
---@param record table|nil
---@param hints table|nil @ url -> gpu id (watcher ledger snapshot)
---@return string|nil gpu
function _M.worker_card(record, hints)
    if type(record) ~= "table" then
        return nil
    end
    local url = record.url
    if type(url) == "string" and type(hints) == "table" then
        local hint = hints[url]
        if type(hint) == "string" or type(hint) == "number" then
            local text = string.match(tostring(hint), "^%s*(.-)%s*$")
            if text and string.match(text, "^%d+$") then
                return text
            end
        end
    end
    return _M.worker_gpu(record)
end

---Map the power vector onto workers, preferring each worker's **own card**.
---
---The four-way rule, and why each branch is what it is:
---  * source exposes no gpu label at all (`source_has_cards` false) -> whole-machine
---    max for every worker. This is the legacy shape (node_exporter, or an operator's
---    `by (Hostname)` query, or the metrics path against an engine that reports one
---    machine-level gauge) and it must stay byte-for-byte today's behaviour, or a
---    data source that has always worked would go dark the day per-card attribution
---    ships. The test for "legacy source" is the **source**, never the worker: if it
---    were decided per worker, a cardless exporter would read as "this worker cannot
---    name its card" and all three failure modes below would collapse into one
---    indistinguishable log line.
---  * worker names a card and the vector has it -> that card's watts. This is the
---    342.371 fix: eight workers on one machine stop sharing one number.
---  * worker names **no** card -> write nothing. Not the machine max. Once the
---    source has proved it is per-card, the machine max is somebody *else's* card,
---    and spending it here would exclude an idle worker because its neighbour runs
---    hot -- a monitoring gap eating capacity, the same failure mode that makes this
---    channel refuse to write 0 or repeat a stale sample. The consequence is stated
---    plainly for whoever configures this: a worker whose card cannot be resolved is
---    not power-capped at all, exactly as if the exporter were down. Register the
---    container with a gpu<N> name (or the equivalent label) to bring it under the
---    cap; watch lr_gpu_load_power_per_card_workers to see how many are covered.
---  * worker names a card and the vector does **not** have it -> write nothing, same
---    reasoning (exporter dropped the card, the card passed through to another
---    container, a stale hint after a rename).
---  Both "write nothing" branches land on registry.power_w() == nil once the old pw:
---  sample TTLs out, and registry.capacity_exclusion reads nil as unknown -> keep.
---  用户裁定 2026-10-04 的降级纪律即此三条：解析不出 gpu / 没有该卡 series / series
---  缺失 -> 不写键，回落「未知 -> 不排除」，绝不摘 worker。
---  * worker names a card and the vector does **not** have it -> write nothing.
---    Deliberately *not* a fallback to the machine max: we know which card this is,
---    the source simply has no series for it (exporter dropped the card, a card
---    passed through to another container, a stale hint after a rename). Reporting
---    another card's watts as this card's reading would exclude an idle worker
---    because its neighbour is hot -- a monitoring gap eating capacity, which is the
---    exact failure this channel is built to avoid. Nothing written -> pw: TTLs ->
---    registry.power_w() == nil -> router's "unknown -> do not exclude".
---`claimed[host]` is set from host-level reachability, not from whether a watt value
---was produced, so power_unmatched keeps its current meaning ("this host's series
---matched no pooled worker") and a missing card cannot inflate it into a bogus label
---mismatch.
---@param workers table[]|nil
---@param by_host table|nil @ host -> whole-machine watts
---@param cards table|nil @ card_key(host, gpu) -> watts
---@param source_has_cards boolean|nil
---@param hints table|nil @ url -> gpu id
---@return table @ worker id -> watts
---@return number @ unmatched host count
function _M.assign_power(workers, by_host, cards, source_has_cards, hints)
    local out, unmatched = {}, 0
    if type(workers) ~= "table" then
        return out, unmatched
    end
    local claimed = {}
    for i = 1, #workers do
        local worker = workers[i]
        local host = worker and _M.split_host(worker.url)
        if host and type(by_host) == "table" and by_host[host] ~= nil then
            claimed[host] = true
            local watts
            if source_has_cards then
                local gpu = _M.worker_card(worker, hints)
                -- 认不出卡 或 该卡无 series -> 什么都不写（不是整机 max）。见上方
                -- 四路口径：源已经是逐卡的了，整机 max 就是**别人那张卡**的瓦特，
                -- 用它顶替会让一张空闲 worker 因为邻居发热而被排除。
                if gpu ~= nil and type(cards) == "table" then
                    watts = cards[_M.card_key(host, gpu)]
                end
            else
                watts = by_host[host]
            end
            if watts ~= nil and worker.id ~= nil then
                out[worker.id] = watts
            end
        end
    end
    if type(by_host) == "table" then
        for host in pairs(by_host) do
            if not claimed[host] then
                unmatched = unmatched + 1
            end
        end
    end
    return out, unmatched
end

---The watt identity rules, shared by both sources (prom rows and one /metrics body).
---
---Why this shape and not a plain group-by: the machine identity of a DCGM series is
---ambiguous by construction, and each of the two wrong answers has been paid for.
---  * dcgm-exporter's machine label is the **capitalised** Hostname, and host_of()
---    only reads lower-case keys, so labels are case-folded first. After folding,
---    Hostname sorts *behind* instance in HOST_LABELS, and every DCGM series carries
---    instance="127.0.0.1:9400" — the scrape address, not the machine. Copying
---    host_of()'s precedence would fold two machines' exporters onto that one value,
---    so A's hottest card pushes B's workers over their cap while unmatched stays 0
---    and no line is logged (cross-machine watt bleed).
---  * Aggregating by (Hostname) alone leaves only the machine name, while 21.k's
---    eight workers are all registered as http://127.0.0.1:80xx, so nothing matches.
---So both keys are registered at once:
---  * a machine-name label (Hostname / hostname / nodename / host / node / pod /
---    name) -> key = machine name;
---  * instance -> key = its host part, adopted only when it is a non-loopback address
---    (a real machine address), or when every series sharing that loopback instance
---    belongs to **one** machine. The latter is this fleet's normal shape (eight
---    workers on 127.0.0.1:80xx meeting DCGM's 127.0.0.1:9400 on the key
---    "127.0.0.1"); once two Hostnames appear behind one loopback instance, that
---    Prometheus scrapes several machines' local exporters and the loopback key has
---    no right to represent any of them -> nothing is adopted, and nothing is guessed.
---Only the power channel uses this; the load channel keeps host_of()'s semantics
---(changing it would move existing e2e assertions).
---@param rows table[]|nil @ parse_prom_response() rows (labels + value)
---@param expose_cards boolean|nil @ also fold per-card keys
---@return table @ host -> watts (whole-machine hottest, only usable readings)
---@return table @ host..CARD_SEP..gpu -> watts (empty unless expose_cards)
---@return table|nil @ host -> true for hosts with at least one card series
---@return boolean @ any usable series carried a numeric gpu label
function _M.power_fold(rows, expose_cards)
    local by_host, cards, card_hosts = {}, {}, {}
    local groups = {}
    local have_cards = false
    if type(rows) ~= "table" then
        return by_host, cards, card_hosts, have_cards
    end
    local function group(gpu)
        local g = groups[gpu]
        if not g then
            g = { host = {}, inst = {}, inst_machines = {} }
            groups[gpu] = g
        end
        return g
    end
    local function remember(target, key, watts)
        if target[key] == nil or watts > target[key] then
            target[key] = watts
        end
    end
    for i = 1, #rows do
        local row = rows[i]
        local watts = row and _M.power_watt(row.value)
        if watts and type(row.labels) == "table" then
            local lowered = {}
            for key, value in pairs(row.labels) do
                if type(key) == "string" then
                    lowered[string.lower(key)] = value
                end
            end
            local machine = _M.host_of({
                hostname = lowered.hostname or lowered.nodename or lowered.host,
                node = lowered.node, pod = lowered.pod, name = lowered.name,
            })
            local inst = _M.host_from_label(lowered.instance)
            -- "" = this series does not name a card. Those rows only feed the
            -- whole-machine map, and they are what keeps a machine-level source
            -- (node_exporter, an operator's by(Hostname) query) working exactly as
            -- it does today.
            local gpu = ""
            if expose_cards then
                local raw = lowered.gpu or lowered.devicename or lowered.gpu_id
                if type(raw) == "string" or type(raw) == "number" then
                    local text = string.match(tostring(raw), "^%s*(.-)%s*$")
                    if text and string.match(text, "^%d+$") then
                        gpu = text
                    end
                end
            end
            if gpu ~= "" then
                have_cards = true
            end
            local g = group(gpu)
            if machine then
                remember(g.host, machine, watts)
            end
            if inst then
                remember(g.inst, inst, watts)
                local seen = g.inst_machines[inst]
                if not seen then
                    seen = {}
                    g.inst_machines[inst] = seen
                end
                -- A series with no machine label cannot prove whose it is; the
                -- empty-string placeholder marks "attribution uncertain".
                seen[machine or ""] = true
            end
        end
    end
    for gpu, g in pairs(groups) do
        local adopted = {}
        for inst, watts in pairs(g.inst) do
            local distinct = 0
            for _ in pairs(g.inst_machines[inst] or {}) do
                distinct = distinct + 1
            end
            local loopback = (inst == "localhost" or inst == "::1"
                or string.sub(inst, 1, 4) == "127.")
            if (not loopback) or distinct <= 1 then
                adopted[inst] = watts
            end
        end
        -- Drop machine-name keys fully represented by an adopted instance key: the
        -- instance max already covers that machine's whole series set, so the
        -- machine-name key carries no extra reading and would only inflate
        -- power_unmatched_total (pointing the operator at a label mismatch that does
        -- not exist). A machine-name key kept on its own (by(Hostname)) *is* the
        -- "reachable but unassignable" signal the operator needs, so it stays.
        local kept = {}
        for machine, watts in pairs(g.host) do
            if adopted[machine] ~= nil or machine == "" then
                kept[machine] = watts
            else
                local redundant
                for inst, inst_watts in pairs(adopted) do
                    local seen = g.inst_machines[inst]
                    if seen and seen[machine] and inst_watts >= watts then
                        redundant = true
                        break
                    end
                end
                if not redundant then
                    kept[machine] = watts
                end
            end
        end
        for machine, watts in pairs(adopted) do
            remember(kept, machine, watts)
        end
        if gpu ~= "" then
            for host, watts in pairs(kept) do
                cards[_M.card_key(host, gpu)] = watts
                card_hosts[host] = true
            end
        end
        -- Whole-machine max: this is today's number, folded over *every* series of
        -- the machine regardless of card, so the fallback cannot drift from the
        -- behaviour that shipped before per-card attribution existed.
        for host, watts in pairs(kept) do
            remember(by_host, host, watts)
        end
    end
    return by_host, cards, card_hosts, have_cards
end

---Fold a result vector down to one **watt** reading per host (hottest card wins).
---
---host_values() 的功率版：唯一的区别是不走 normalize()。那是本模块最容易写错的
---一行——照抄 host_values() 会把 96 W 折成 1.0（96/100 夹到上限），于是功率通道
---输出的「1」既不是瓦特也不是负载，上限判定拿它去比 max_power_w 就永远不成立。
---多卡取最大而非取和/取平均：一台 worker 往往看得见整机所有卡，路由要避免把请求
---打到已经最热的那张卡上，取和会让「一张满载七张空闲」看起来仍然很闲。
---
---机器身份的判定规则（含环回 instance 的归属检查）整体在 _M.power_fold() 上说明；
---本函数保持改动前的对外契约（host -> 整机最热瓦特），逐卡展开请用
---_M.host_card_powers()。
---@param rows table[]|nil @ parse_prom_response() rows
---@return table @ host -> watts (only usable readings)
function _M.host_powers(rows)
    local by_host = _M.power_fold(rows, false)
    return by_host
end

---Fold a result vector into **per-card** watt readings as well as per-host.
---
---21.k 生产实况（2026-10-04）：8 个 worker 的 power_w 全是同一个 342.371，因为 compose
---里那条 SMG_LOAD_POWER_QUERY 写的是 max by (Hostname,instance) (DCGM_FI_DEV_POWER_USAGE)
---——Prometheus 侧就已经把 8 张卡折成 1 条 series，逐卡标签根本没能到达网关。逐卡读数
---在 exporter 上一直齐全（/data/tmp/dcgm-metrics-9400.txt：
---DCGM_FI_DEV_POWER_USAGE{gpu="0",...,Hostname="gpu-pro6000-1"} 96.161 … gpu="7" 309.834），
---所以这一路按 gpu 标签建 host+gpu 键，配 registry 记录的 labels.gpu（watcher 从容器名
---解析）把瓦数交回**它自己那张卡**。
---
---默认查询串（部署侧改 compose 的 SMG_LOAD_POWER_QUERY，本仓不改部署）：
---    max by (Hostname, instance, gpu) (DCGM_FI_DEV_POWER_USAGE)
---  * gpu 必须留在 by 里：把它聚合掉 = 回到 342.371 那个故障。
---  * Hostname 也留在 by 里：让 power_fold 能在「一台 Prometheus 抓了多台机器的本机
---    exporter」时识破归属冲突（环回 instance 键只在同批 series 只属一台机器时才采纳），
---    宁可整台不采纳也不会把 A 机最热的卡挂到 B 机头上。
---  * instance 留在 by 里：worker 全注册成 http://127.0.0.1:80xx，机器名与 IP 之间没有
---    可用映射，只有 exporter 的抓取地址能把读数交回本机 worker。
---  * 用 max 而不是 sum：sum 会把同一张卡的多次抓取/多标签副本相加；本模块的口径是
---    「取最热」，不是「取总和」。
---@param rows table[]|nil @ parse_prom_response() rows
---@return table @ host -> watts (whole-machine hottest)
---@return table @ host..CARD_SEP..gpu -> watts
---@return table @ host -> true (hosts exposing at least one card series)
---@return boolean @ any series carried a numeric gpu label
function _M.host_card_powers(rows)
    return _M.power_fold(rows, true)
end

--- Power knobs for this pass, read straight from the environment.
---
--- 为什么读 env 而不是 cfg：resty.luarouter.config 不在本轮改动范围内（它把每个开关都
--- 过一遍 clamp 与缺省归一化），所以这三个名字由本模块自己 os.getenv。三点后果如实写
--- 在这里，别让下一个读者误以为它们已经和其余 SMG_LOAD_* 同等待遇：
---   * nginx 按 `env` 白名单重建 worker 环境，漏声明就静默失效（本仓库踩过的坑），
---     所以三份 conf 都要声明：conf/lua-router.conf、conf/nginx.conf.template，以及集成
---     测试用的 test/conf/nginx-lua-router.conf（_lib.py 的 CONF_TEST 用的正是它，漏了它
---     e2e 里设 SMG_LOAD_POWER=1 会形同虚设）。
---   * worker 环境在 fork 时就固定，全仓没有任何 setenv/putenv，所以这里每 tick 现读并不
---     比 init 期读一次更“热”——真正的生效方式是重启容器 / 重下 compose。别把这三个开关
---     承诺成可热改的能力。
---   * 它们因此也进不了 config_store 的 JSON 文档与 /_ui/config，UI 上看不见也改不了。
---     并进 config.lua 的解析（从而被 JSON 保存链路与管理台覆盖，符合 AGENTS.md「新配置面
---     必须落到可视化」）是紧随其后的收尾项，需要 config 侧的文件所有权。
--- cfg.load_power* 优先于 env：给测试注入用，也是将来接进 config.lua 的天然入口。
---  * SMG_LOAD_POWER       metrics 路是否顺带扫功率（"1"/"true"/"yes"）
---  * SMG_LOAD_POWER_KEYS  覆盖功率 gauge 名单（逗号/空格分隔）
---  * SMG_LOAD_POWER_QUERY prom 路的第二条 PromQL；留空 = 不采功率
---@param cfg table|nil @ router config; cfg.load_power* wins when present
---@return table @ {on, keys, query}
function _M.power_config(cfg)
    cfg = cfg or {}
    local function env(name)
        if type(os.getenv) ~= "function" then
            return nil
        end
        local value = os.getenv(name)
        if type(value) ~= "string" or value == "" then
            return nil
        end
        return value
    end
    local on = cfg.load_power
    if on == nil then
        local raw = env("SMG_LOAD_POWER")
        if type(raw) == "string" then
            local lowered = string.lower(raw)
            on = lowered == "1" or lowered == "true" or lowered == "yes" or lowered == "on"
        else
            on = false
        end
    end
    local keys = cfg.load_power_keys
    if keys == nil or (type(keys) == "table" and #keys == 0)
        or (type(keys) == "string" and string.match(keys, "^%s*$")) then
        keys = env("SMG_LOAD_POWER_KEYS")
    end
    local query = cfg.load_power_query
    if query == nil or (type(query) == "string" and query == "") then
        query = env("SMG_LOAD_POWER_QUERY")
    end
    return {
        on = not not on,
        keys = keys,
        query = (type(query) == "string" and query ~= "") and query or nil,
    }
end

------------------------------------------------------------------ prom (remote)

---Render one PromQL out of the template.
---
---`{host}` becomes the worker's host and `{instance}` its host:port (the label
---value the exporter was scraped with, minus the port for {instance} templates
---that carry it). Neither brace is a Lua pattern metacharacter, but the
---substitution is done through a function so a hostname containing '%' stays
---literal. A template that asks for a host this worker cannot name is a task the
---caller must skip, not one to guess at.
---@param template string
---@param worker table|nil @ {url=...}
---@return string|nil query
function _M.render_query(template, worker)
    if type(template) ~= "string" or template == "" then
        return nil
    end
    local host, port = _M.split_host(worker and worker.url)
    -- An unparseable url still gets the template verbatim rather than nil: a query
    -- that names no machine is a valid (if useless) PromQL, and returning nil here
    -- would make run_pass report a config skip for what is really a bad worker url.
    -- The substitution below simply finds nothing to replace.
    
    local wants_host = string.find(template, "{host}", 1, true) ~= nil
        or string.find(template, "{instance}", 1, true) ~= nil
    if wants_host and not host then
        return nil
    end
    local out = template
    if host then
        out = string.gsub(out, "{host}", function() return host end)
        out = string.gsub(out, "{instance}", function()
            return port and (host .. ":" .. port) or host
        end)
    end
    return out
end

--- True when the template must be expanded once per worker.
---@param template string|nil
---@return boolean
function _M.query_needs_host(template)
    if type(template) ~= "string" then
        return false
    end
    return string.find(template, "{host}", 1, true) ~= nil
        or string.find(template, "{instance}", 1, true) ~= nil
end

---Full query URL for a Prometheus base address.
---@param base string|nil @ e.g. http://prom:9090 or http://prom:9090/api/v1/query
---@return string|nil
function _M.query_endpoint(base)
    if type(base) ~= "string" then
        return nil
    end
    local trimmed = string.gsub(base, "%s+$", "")
    trimmed = string.gsub(trimmed, "/+$", "")
    if trimmed == "" then
        return nil
    end
    if string.match(trimmed, "/api/v1/query$") then
        return trimmed
    end
    return trimmed .. "/api/v1/query"
end

---Percent-encode one form value (the same rule watcher.lua's uri_encode uses).
---@param text string
---@return string
local function uri_encode(text)
    return (string.gsub(text, "([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end
_M.uri_encode = uri_encode

---Form body for one PromQL evaluation (POST /api/v1/query, urlencoded).
---@param query string
---@return string
function _M.query_body(query)
    return "query=" .. uri_encode(query or "")
end

---Parse a Prometheus query response into rows.
---
---`{"status":"success","data":{"resultType":"vector","result":[{"metric":{...},
---"value":[<ts>,"<number>"]}]}}` is the only shape read: a matrix (range query) or
---a scalar has no per-series identity to map back to a worker, so it is an error
---rather than an empty result. Sample values go through parse_number(), so a
---"NaN" series is dropped here instead of becoming a zero load.
---@param body string|nil
---@return table[]|nil rows @ {{labels=table, value=number|nil}, ...}
---@return string|nil err
function _M.parse_prom_response(body)
    if type(body) ~= "string" or body == "" then
        return nil, "empty response"
    end
    local decoded = cjson.decode(body)
    if type(decoded) ~= "table" then
        return nil, "invalid json"
    end
    if decoded.status ~= "success" then
        return nil, "status " .. tostring(decoded.status)
    end
    local data = decoded.data
    if type(data) ~= "table" then
        return nil, "missing data"
    end
    if type(data.resultType) == "string" and data.resultType ~= "vector" then
        return nil, "unsupported resultType " .. data.resultType
    end
    local result = data.result
    if type(result) ~= "table" then
        -- cjson decodes {} as an empty table and [] as an empty table too, so a
        -- missing result key is the only way to get here; an empty vector is fine.
        return {}, nil
    end
    local rows = {}
    for i = 1, #result do
        local item = result[i]
        if type(item) == "table" then
            local labels = type(item.metric) == "table" and item.metric or {}
            local raw
            local value = item.value
            if type(value) == "table" then
                raw = value[2] ~= nil and value[2] or value[1]
            elseif value ~= nil then
                raw = value
            end
            rows[#rows + 1] = {
                labels = labels,
                value = _M.parse_number(raw),
            }
        end
    end
    return rows, nil
end

---Fold a result vector down to one load per host (hottest series wins).
---@param rows table[]|nil
---@return table @ host -> normalized load
function _M.host_values(rows)
    local by_host = {}
    if type(rows) ~= "table" then
        return by_host
    end
    for i = 1, #rows do
        local row = rows[i]
        local host = row and _M.host_of(row.labels)
        local load = _M.normalize(row and row.value)
        if host and load then
            if by_host[host] == nil or load > by_host[host] then
                by_host[host] = load
            end
        end
    end
    return by_host
end

---Map host -> load onto the in-pool workers.
---
---Several workers on one machine (four ranks of a DP engine, or two engines on one
---GPU box) all read the same host sample: the GPU is the shared resource, so the
---shared reading is the honest one. Series that name a host nobody in the pool
---serves are counted as unmatched and ignored, never invented into a worker.
---@param by_host table @ host -> normalized load
---@param workers table[] @ records ({id, url})
---@return table @ worker id -> normalized load
---@return number unmatched @ hosts with no worker behind them
function _M.assign(by_host, workers)
    local out, unmatched = {}, 0
    if type(workers) ~= "table" then
        return out, unmatched
    end
    local claimed = {}
    for i = 1, #workers do
        local worker = workers[i]
        local host = worker and _M.split_host(worker.url)
        if host and type(by_host) == "table" then
            local load = by_host[host]
            if load ~= nil then
                out[worker.id] = load
                claimed[host] = true
            end
        end
    end
    if type(by_host) == "table" then
        for host in pairs(by_host) do
            if not claimed[host] then
                unmatched = unmatched + 1
            end
        end
    end
    return out, unmatched
end

------------------------------------------------------------------ the priority rule

---Scheduling load for one worker: the router's own in-flight counter plus the
---external GPU sample when there is a fresh one.
---
---Why this is the priority order (doc/gap-gpu-load.md §4):
---  * The external source (metrics/prom) is the *only* writer of the GPU sample,
---    and it wins the definition of "load": a worker with no request in flight but
---    an 95 %-busy GPU must not look idle to power_of_two, and in-flight alone
---    cannot see a queue that another router process (or another router entirely)
---    filled.
---  * The in-flight term stays in the sum because the router is the only party
---    that knows what it just handed a worker and has not finished serving;
---    dropping it would make a burst look flat until the next load tick.
---  * The engine self-report path (`/v1/loads`, whose `aggregate.total_tokens` is
---    what Rust caches) deliberately does *not* feed this field: that endpoint
---    stays a live pull the router answers on demand (router.lua's loads_handler)
---    and never writes the registry, so the two channels cannot step on each
---    other. If a self-report fan-out is ever added, it has to write a *separate*
---    key and this function is the single place that decides the ranking: external
---    GPU sample first, self-report only as the fallback when there is none.
---  * `scale` exists because the two terms arrive in different units: the sample
---    is a 0..1 fraction while in-flight is a request count. Multiplying the
---    fraction by 100 (SMG_LOAD_SCALE) makes a 0.01 utilisation gap worth one
---    in-flight request, which keeps cache_aware's balance_abs_threshold (a
---    request-count-shaped knob, default 64) inside its usable range instead of
---    silently disabling the escape.
---@param external number|nil @ normalized 0..1, or nil when no fresh sample
---@param inflight number|nil
---@param scale number|nil @ value of a fully busy worker (default 100)
---@return number load
function _M.effective_load(external, inflight, scale)
    local pending = tonumber(inflight) or 0
    if pending < 0 then
        pending = 0
    end
    local sample = tonumber(external)
    if sample == nil then
        return pending
    end
    if sample < 0 then
        sample = 0
    elseif sample > 1 then
        sample = 1
    end
    local weight = tonumber(scale)
    if weight == nil then
        weight = 100
    end
    return pending + sample * weight
end

------------------------------------------------------------------ live layer

local function hb_mod()
    local ok, hb = pcall(require, "resty.luarouter.hb")
    if ok and type(hb) == "table" then
        return hb
    end
    return nil
end

local function registry_mod()
    local ok, registry = pcall(require, "resty.luarouter.registry")
    if ok and type(registry) == "table" then
        return registry
    end
    return nil
end

---In-pool workers, i.e. the ones the inference plane can actually be given. The
---health sweep has its own filter (it probes everything, including the workers
---registered with disable_health_check) and the load source wants the *pool*, so
---this asks registry.http_selectable and keeps workers the sweep skips.
---@return table[]
local function default_workers()
    local registry = registry_mod()
    if not registry then
        return {}
    end
    local out = {}
    local records = registry.records() or {}
    for i = 1, #records do
        local record = records[i]
        local selectable = true
        if type(registry.http_selectable) == "function" then
            local ok_sel, sel = pcall(registry.http_selectable, record.id)
            selectable = (not ok_sel) or sel ~= false
        end
        if selectable and type(record.url) == "string" then
            out[#out + 1] = record
        end
    end
    return out
end

---Per-card power reads the worker->gpu hint table off the watcher's ledger.
---
---Lazy pcall(require) like registry_mod()/hb_mod(): gpu_load must not require the
---watcher at load time (a require cycle watcher -> ... -> gpu_load would deadlock
---the first request that loads either), and outside nginx there is no lr_watch
---dict to read anyway. When the watcher is absent or its dict is not declared, the
---snapshot is empty and the per-card channel simply falls back to labels.gpu and
---then to the whole-machine max -- i.e. exactly the pre-feature behaviour. That is
---why this is a *hint* channel and not the source of truth: it can be entirely
---missing and the power cap stays as honest as it was before per-card attribution.
---@return table @ url -> gpu id
local function default_gpu_hints()
    local ok, watcher = pcall(require, "resty.luarouter.watcher")
    if not ok or type(watcher) ~= "table"
        or type(watcher.gpu_hint_snapshot) ~= "function" then
        return {}
    end
    local ok2, hints = pcall(watcher.gpu_hint_snapshot)
    if ok2 and type(hints) == "table" then
        return hints
    end
    return {}
end

local function default_get(url, timeout_ms, headers)
    local hb = hb_mod()
    if not hb then
        return nil, nil, "hb unavailable"
    end
    return hb.http_get(url, timeout_ms, headers)
end

local function default_post(url, timeout_ms, headers, body)
    local hb = hb_mod()
    if not hb then
        return nil, nil, "hb unavailable"
    end
    return hb.http_request("POST", url, timeout_ms, headers, body, "probe")
end

---Store one sample and publish its per-worker gauge. The gauge write is guarded
---because observability is not allowed to cost a load sample: the registry is the
---authority, the exporter is a copy.
---@param id string
---@param value number|nil @ normalized 0..1
---@param timestamp number @ ms clock (accepted for seam symmetry, unused here)
---@param ttl_secs number
---@param url string|nil @ only for the gauge label
---@return boolean written
local function default_write(id, value, timestamp, ttl_secs, url)
    local registry = registry_mod()
    if not registry or type(registry.set_external_load) ~= "function" then
        return false
    end
    local written = registry.set_external_load(id, value, ttl_secs)
    if written and url then
        _M.publish_worker_gauge(url, value)
    end
    return written
end

---Store one **watt** sample on the registry's independent `pw:` key.
---
---Why two return values rather than a boolean: the caller must distinguish "there
---was no reading to store" (nothing is written, the old sample simply TTLs out and
---the cap reads *unknown*) from "a reading registry refused" (a genuinely broken
---exporter, worth a counter), and both from a stored sample. This layer never
---writes 0 and never repeats the previous value — that is exactly what makes the
---power cap safe to leave switched on. registry.set_power_w() already rejects
---negatives/NaN/±inf; what is added here is the seam symmetry with
---default_write() and the per-worker gauge.
---@param id string
---@param watts number|nil @ absolute watts
---@param timestamp number @ ms clock (accepted for seam symmetry, unused here)
---@param ttl_secs number
---@param url string|nil @ only for the gauge label
---@return boolean stored, string reason
local function default_write_power_inner(id, watts, ttl_secs, url)
    local registry = registry_mod()
    if not registry or type(registry.set_power_w) ~= "function" then
        return false, "no-registry"
    end
    local stored = registry.set_power_w(id, watts, ttl_secs)
    if not stored then
        return false, "rejected"
    end
    if url then
        _M.publish_worker_power_gauge(url, watts)
    end
    return true, "stored"
end

---Store one watt sample, telling the two kinds of "not stored" apart.
---
---registry.set_power_w() answers false both when it refuses an unusable number
---(negative / NaN / ±inf) and when the shared dict simply had no room — the first
---means the exporter is lying, the second means this gateway is out of memory, and
---an operator reading one counter must not be sent looking at the wrong one. So
---the value is re-screened here with the same predicate the parsers use: if it is
---valid, a false from registry can only be the dict, which is counted as an error
---of *this* module rather than a rejection. (The "rejected" branch is therefore
---rare by construction — everything reaching here already passed power_watt().)
---@param id string
---@param watts number|nil @ absolute watts
---@param timestamp number @ ms clock (accepted for seam symmetry, unused here)
---@param ttl_secs number
---@param url string|nil @ only for the gauge label
---@return boolean stored, string reason
local function default_write_power(id, watts, timestamp, ttl_secs, url)
    if _M.power_watt(watts) == nil then
        return false, "rejected"
    end
    local stored, why = default_write_power_inner(id, watts, ttl_secs, url)
    if (not stored) and why == "rejected" then
        -- The number is usable, so registry's only remaining reason to refuse is
        -- the shared dict. It already logged the shdict error itself.
        return false, "store-failed"
    end
    return stored, why
end

-- One warn key per (class, target) so a Prometheus that is down does not spend the
-- error log; the window is the reason the key carries the class.
local warned_at = {}

---Warn once per WARN_DEDUP_SECS for one (class, target) pair.
---@param class string @ short failure family, e.g. "metrics" or "prom"
---@param target string @ worker url or prometheus url
---@param detail string|nil
---@param now number|nil @ ms clock (injected by the tests)
---@return boolean logged
function _M.warn_dedup(class, target, detail, now)
    local key = tostring(class) .. "|" .. tostring(target)
    local stamp = tonumber(now) or now_ms()
    local last = warned_at[key]
    if last and (stamp - last) < WARN_DEDUP_SECS * 1000 then
        return false
    end
    warned_at[key] = stamp
    local line = "gpu-load " .. class .. " " .. tostring(target)
        .. (detail and (": " .. tostring(detail)) or "")
    local ngxm = live_ngx()
    if ngxm and ngxm.log then
        ngxm.log(ngxm.WARN, "luarouter: ", line)
    end
    return true
end

---Clear the dedup window (tests, and an operator flipping SMG_LOAD_SOURCE).
function _M.reset_warn_dedup()
    warned_at = {}
end

local function worker_headers(record)
    if type(record) == "table" and type(record.api_key) == "string"
        and record.api_key ~= "" then
        return { Authorization = "Bearer " .. record.api_key }
    end
    return nil
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
    local stats = {
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

    local get = opts.get or default_get
    local post = opts.post or default_post
    local list_workers = opts.workers or default_workers
    local write = opts.write or default_write
    local write_power = opts.write_power or default_write_power
    local stamp = opts.now or now_ms
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
    local registry = registry_mod()
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
            hints = default_gpu_hints()
        end
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
                worker_headers(record))
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
        local by_host = {}
        local function one(query, target)
            local ok_call, status, body, err = pcall(post, endpoint, timeout_ms,
                headers, _M.query_body(query))
            if not ok_call then
                stats.errors = stats.errors + 1
                _M.warn_dedup("prom-raise", target, tostring(status), stamp())
                return
            end
            local code = tonumber(status) or 0
            if code < 200 or code >= 300 or type(body) ~= "string" then
                stats.failed = stats.failed + 1
                _M.warn_dedup("prom", target, err or ("status " .. tostring(status)),
                    stamp())
                return
            end
            local rows, perr = _M.parse_prom_response(body)
            if not rows then
                stats.failed = stats.failed + 1
                _M.warn_dedup("prom", target, perr, stamp())
                return
            end
            local folded = _M.host_values(rows)
            for host, load in pairs(folded) do
                if by_host[host] == nil or load > by_host[host] then
                    by_host[host] = load
                end
            end
            stats.probed = stats.probed + 1
        end

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
        local by_power = {}
        -- 逐卡表与「数据源到底认不认得卡」：后者是**整源**属性而不是逐 worker 判定，
        -- 因为它决定的是「这个数据源有没有逐卡形状」，用它区分「老数据源 → 整机 max
        -- （今天的行为）」与「有逐卡数据但这个 worker 认不出卡」。
        local by_card_power = {}
        local source_has_cards = false
        local function one_power(query, target)
            local ok_call, status, body, err = pcall(post, endpoint, timeout_ms,
                headers, _M.query_body(query))
            if not ok_call then
                stats.power_errors = stats.power_errors + 1
                _M.warn_dedup("power-prom-raise", target, tostring(status), stamp())
                return false
            end
            local code = tonumber(status) or 0
            if code < 200 or code >= 300 or type(body) ~= "string" then
                stats.power_errors = stats.power_errors + 1
                _M.warn_dedup("power-prom", target,
                    err or ("status " .. tostring(status)), stamp())
                return false
            end
            local rows, perr = _M.parse_prom_response(body)
            if not rows then
                -- 正文不是合法 PromQL 响应（404 页面、query 语法错被代理成 200）：
                -- 这是「解析失败」，单独计数，供 lr_gpu_load_power_parse_failures_total
                -- 观测。
                stats.power_errors = stats.power_errors + 1
                _M.warn_dedup("power-prom", target, perr, stamp())
                return false
            end
            -- 逐卡展开（= host_powers 的展开版；expose_cards=false 时两者逐字节同值，
            -- 所以只有 prom 路受益，且缺 gpu 标签时不会比今天少一个读数）。
            local folded, cards, _, have_cards = _M.host_card_powers(rows)
            for host, watts in pairs(folded) do
                if by_power[host] == nil or watts > by_power[host] then
                    by_power[host] = watts
                end
            end
            for key, watts in pairs(cards) do
                -- {host} 模板会发多条查询，同一个 host+gpu 键取最大：与 host 键同
                -- 做法，也保证结果与查询到达顺序无关（同一份输入跑两遍必须逐字节相同）。
                if by_card_power[key] == nil or watts > by_card_power[key] then
                    by_card_power[key] = watts
                end
            end
            if have_cards then
                source_has_cards = true
            end
            stats.power_probed = stats.power_probed + 1
            return true
        end
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
                            one_power(pq, record.url)
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
                one_power(power.query, endpoint)
            end

            local url_for_power = {}
            for i = 1, #workers do
                url_for_power[workers[i].id] = workers[i].url
            end
            local hints = opts.gpu_hints
            if hints == nil then
                hints = default_gpu_hints()
            end
            -- 按 worker 各自的卡分发（四路口径见 assign_power 上方注释：源无逐卡
            -- 标签 → 整机 max；认不出卡 → 整机 max；认得出且有该卡 series → 本卡
            -- 瓦特；认得出却没有该卡 series → 什么都不写，绝不拿邻居卡冒充）。
            local p_assigned, p_unmatched = _M.assign_power(workers, by_power,
                by_card_power, source_has_cards, hints)
            stats.power_unmatched = p_unmatched
            -- 「本 pass 里有多少 worker 真的按自己那张卡拿到读数」。没有这个计数，
            -- 「全部逐卡成功」与「全部悄悄退回整机 max」在 /metrics 上长得一模一样，
            -- 而后者正是 342.371 故障能一直活着的原因。
            local card_hits = 0
            if source_has_cards then
                for i = 1, #workers do
                    local w = workers[i]
                    if w and p_assigned[w.id] ~= nil
                        and _M.worker_card(w, hints) ~= nil then
                        card_hits = card_hits + 1
                    end
                end
            end
            stats.power_per_card = card_hits
            -- 查询本身成功却一个可用读数都没有（gauge 名写错、那批机器没起 dcgm、
            -- 整表都是 NaN）：与 metrics 路的 no-gauge 同义，记一次 failed 并留一条
            -- 去重 WARN。放在这里而不是 one_power 内，是因为按 host 展开时会有多次
            -- 查询，只有折叠完才知道「整个 vector 到底有没有可用读数」。
            if next(by_power) == nil and (stats.power_errors or 0) == 0 then
                stats.power_failed = stats.power_failed + 1
                _M.warn_dedup("power-prom-nogauge", tostring(power.query),
                    "power query returned no usable watt series", stamp())
            elseif next(p_assigned) == nil and next(by_power) ~= nil then
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
                        one(query, record.url)
                    end
                    local host = _M.split_host(record.url)
                    local load = host and by_host[host]
                    if load ~= nil then
                        write(record.id, load, stamp(), ttl_secs, record.url)
                        stats.matched = stats.matched + 1
                    end
                else
                    stats.skipped = stats.skipped + 1
                end
            end
        else
            one(template, endpoint)
            local url_for_id = {}
            for i = 1, #workers do
                url_for_id[workers[i].id] = workers[i].url
            end
            local assigned, unmatched = _M.assign(by_host, workers)
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
