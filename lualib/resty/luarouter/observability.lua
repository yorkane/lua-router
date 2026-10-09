-- Request log ring buffer, sliding-window stats and Prometheus text export.
--
-- Field names and metric names are the wire contract with ui/admin/logs.html and
-- Grafana dashboards that already target the Rust gateway, so both are copied
-- from gateway/src/observability/{request_log,metrics}.rs rather than invented.
--
-- lr_request_log layout:
--   head      monotonic sequence (incr)
--   q:<seq>   one RequestRecord as JSON
-- lr_stats layout:
--   c|<metric>|<labels>      counter
--   h|<metric>|<labels>      histogram  {n,s,b1..bN} packed in one value
--   w|<bucket_ms>            one-millisecond window sample
-- Per-worker gauges (health / load / breaker state) are derived live from
-- lr_workers at scrape time and never stored, so a scrape can never disagree
-- with the registry.
--
-- Label pairs inside a key use \1 and \2 as separators: URLs and request paths
-- both contain commas, which would break a comma-joined key.

local cjson = require "cjson.safe"

local _M = { _VERSION = "0.1.0" }
-- 门面：写侧原语（counter/observe/gauge + 键文法 + b[i]/前缀和分工）、record_*
-- 登记点、HELP 权威表与 prometheus_text 导出器必须同域（契约门禁只测最终文本）；
-- 在飞年龄 tracker 与请求日志面搬到 observability/*，函数直接写在 _M 上，
-- 因此下面的 require 会让门面表长回拆分前的导出名集合。
package.loaded["resty.luarouter.observability"] = _M

local LOG_DICT = "lr_request_log"
local STATS_DICT = "lr_stats"
-- Read-only at scrape time: the manual policy sticky map, whose keys are the
-- only durable record of which routing key is bound to which worker.
local POLICY_DICT = "lr_policy"

---Upper bound for the shared-dict scans in the exporter and the scrape-time joins.
---Every get_keys call in this module is a read for *rendering*, never a correctness
---surface, so a bound trades completeness on an absurdly large dict for a hard cap on
---per-scrape cost inside the single forwarding worker (worker_processes 1 is the prod
---shape here). Production line counts measured 466-561 rows, so the bound is invisible
---until a dict has grown pathological -- exactly the case where a cheaper scrape is the
---point. LR_METRICS_SCAN_LIMIT overrides it; a truncated scan also publishes
---smg_dict_scan_truncated so the truncation is never silent.
local SCAN_LIMIT = tonumber(os.getenv("LR_METRICS_SCAN_LIMIT")) or 20000
if not SCAN_LIMIT or SCAN_LIMIT < 1 then
    SCAN_LIMIT = 20000   -- never let a typo turn the exporter into an empty page
end

---测试专用：改写扫描上限（线上没有调用点，配置靠 LR_METRICS_SCAN_LIMIT）。
---上限本身是加载期读一次的值，重读需要整个模块重载，所以留这一个窄口子给单测钉
---「扫描确实有界」这条断言。<=0 回到缺省。
---@param n number|nil
function _M.set_metrics_scan_limit(n)
    local v = tonumber(n)
    if not v or v < 1 then
        v = tonumber(os.getenv("LR_METRICS_SCAN_LIMIT")) or 20000
        if not v or v < 1 then v = 20000 end
    end
    SCAN_LIMIT = v
    return SCAN_LIMIT
end

local json_encode = cjson.encode
local json_decode = cjson.decode

local PAIR_SEP = "\1"
local KV_SEP = "\2"

-- Default duration buckets from the Rust Prometheus setup.
local DEFAULT_BUCKETS = {
    0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5,
    5.0, 10.0, 15.0, 30.0, 45.0, 60.0, 90.0, 120.0, 180.0, 240.0,
}

local config

local function cfg()
    if not config then
        config = require("resty.luarouter").config()
    end
    return config
end

-- SMG_PROMETHEUS_DURATION_BUCKETS is read once and cached: the bucket array is
-- baked into every stored histogram (b[i] is the count for bucket i alone), so
-- changing the ladder mid-life would need a re-bucket, not a new ladder.
local buckets_cache

---@return table buckets @ ascending upper bounds
---@return integer count
local function buckets()
    if not buckets_cache then
        local configured = cfg().duration_buckets
        if configured and #configured > 0 then
            local sorted = {}
            for i = 1, #configured do
                sorted[i] = configured[i]
            end
            table.sort(sorted)
            buckets_cache = sorted
        else
            buckets_cache = DEFAULT_BUCKETS
        end
    end
    return buckets_cache, #buckets_cache
end

-- _M.log_enabled is defined with the other accessors; append_request guards on
-- it through the table so declaration order does not matter.
local function logdict()
    return ngx.shared[LOG_DICT]
end

local function statsdict()
    return ngx.shared[STATS_DICT]
end

-- ------------------------------------------------------------------ key/value

local function label_text(labels)
    if type(labels) ~= "table" or #labels == 0 then
        return ""
    end
    return table.concat(labels, PAIR_SEP)
end


--- model 标签的基数闸门（doc/gap-cpu-idle-burn.md S3）。
--- lr_stats 的键是 c|/h|/g| + metric + labels，而全仓对这些行没有任何 delete
---（唯一的 delete 在 logstore.lua 与 inflight 自己的键上）。所以一个取值空间由客户端
---决定的标签，会把这个字典养到进程结束，/metrics 与每一趟 gauge 扫描都为它付费。
---入口族的指标早已有 known_name 归一，worker 级的那些没有 —— 这里补上。
---
---闸门放在 label_pairs 而不是各调用点：这是每个要落盘的键唯一的必经收口，
---新增一个带 model 标签的族就不可能因为忘了归一再把漏洞开回来。
---越过预算后新名字一律并进同一个 other 行：宁可少一维分辨率（它本来只用于人工排查），
---也不能让「客户端能编出来的每个字符串」换一行字典记录。
local OTHER_MODEL = "other"
local model_label_seen = {}
local model_label_count = 0
local model_label_cap

---上限只读一次（与桶阶梯同一纪律：这个数已经烘进写出去的键里，不是热开关）。
---<=0 关闭闸门、原名照落，等于回到改动之前的行为。
local function model_label_limit()
    if model_label_cap == nil then
        model_label_cap = tonumber(os.getenv("LR_MODEL_LABEL_CAP")) or 300
        if model_label_cap < 0 then
            model_label_cap = 0
        end
    end
    return model_label_cap
end

---测试/复位用：丢掉已登记的名字集合并重读上限（线上没有调用点）。
function _M.reset_model_label_cardinality()
    model_label_seen = {}
    model_label_count = 0
    model_label_cap = nil
end

---@return number @ 目前存下的 distinct model 标签值个数
function _M.model_label_cardinality()
    return model_label_count
end

---@param value any
---@return string @ 真正进标签的值
local function model_label(value)
    -- nil / empty / non-string, plus the two reserved buckets, short-circuit
    -- **ahead of** the registration. Written after it, an invalid value (or a
    -- client that literally sends model=other) would burn a budget slot while
    -- still costing one row: the ledger and the storage would disagree.
    if type(value) ~= "string" or value == "" then
        return "unknown"
    end
    if value == "unknown" or value == OTHER_MODEL then
        return value
    end
    if model_label_seen[value] then
        return value
    end
    local cap = model_label_limit()
    if cap == 0 then
        return value
    end
    if model_label_count >= cap then
        return OTHER_MODEL
    end
    model_label_seen[value] = true
    model_label_count = model_label_count + 1
    -- 只在计数变化时发一条 gauge：这道闸门的成本是「每个新名字一次字典写」，
    -- 不是「每个请求一次」。撞顶本身是运维想在 /metrics 开始对不上账之前看到的信号。
    _M.gauge("smg_model_label_cardinality", {}, model_label_count)
    if model_label_count == cap and ngx and ngx.log then
        ngx.log(ngx.WARN, "luarouter: model label cardinality hit ", cap,
            "; further model names collapse to ", OTHER_MODEL)
    end
    return value
end

--- Encode one label set: {"model","qwen","endpoint","chat"}.
local function label_pairs(pairs)
    local parts = {}
    for i = 1, #pairs do
        local name = pairs[i][1]
        local value = pairs[i][2]
        if name == "model" then
            value = model_label(value)
        end
        parts[#parts + 1] = name .. KV_SEP .. value
    end
    return table.concat(parts, PAIR_SEP)
end

-- The Prometheus text output uses these.
local function render_labels(text)
    if text == "" then
        return ""
    end
    local parts = {}
    for pair in string.gmatch(text, "([^" .. PAIR_SEP .. "]+)") do
        local name, value = string.match(pair, "^([^" .. KV_SEP .. "]+)"
            .. KV_SEP .. "(.*)$")
        if name then
            parts[#parts + 1] = name .. '="' .. _M.escape_label(value) .. '"'
        end
    end
    if #parts == 0 then
        return ""
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function render_bucket_labels(base, le)
    local le_text = (le == math.huge) and "+Inf" or string.format("%g", le)
    if base == "" then
        return '{le="' .. le_text .. '"}'
    end
    return "{" .. render_labels(base):sub(2, -2) .. ',le="' .. le_text .. '"}'
end

function _M.escape_label(value)
    value = tostring(value)
    local out = {}
    for i = 1, #value do
        local char = value:sub(i, i)
        if char == "\\" then
            out[#out + 1] = "\\\\"
        elseif char == '"' then
            out[#out + 1] = '\\"'
        elseif char == "\n" then
            out[#out + 1] = "\\n"
        else
            out[#out + 1] = char
        end
    end
    return table.concat(out)
end

local escape_label = _M.escape_label

-- ------------------------------------------------------------------ primitives

---Increase a Prometheus counter. `pairs` is a list of {name, value} pairs.
function _M.counter(metric, pairs, delta)
    local d = statsdict()
    local key = "c|" .. metric .. "|" .. label_pairs(pairs)
    local value = d:incr(key, delta or 1, 0)
    if not value then
        d:set(key, delta or 1)
    end
end

---Storage key of one packed histogram value. b[i] is the count for bucket i
---alone; the exporter prefix-sums it at render time.
local function histo_key(metric, pairs)
    return "h|" .. metric .. "|" .. label_pairs(pairs)
end

---Record one histogram observation.
function _M.observe(metric, pairs, seconds)
    local d = statsdict()
    local key = histo_key(metric, pairs)
    local raw = d:get(key)
    local hist
    if raw then
        hist = json_decode(raw)
        if type(hist) ~= "table" then
            hist = nil
        end
    end
    local current, count = buckets()
    if not hist then
        hist = { n = 0, s = 0, b = {} }
    end
    if type(hist.b) ~= "table" or #hist.b ~= count then
        -- Either a sparse array cjson rendered as nulls, or a histogram stored
        -- under the previous bucket ladder: rebuild at the current width. The
        -- per-bucket detail of an old ladder is lost, but n/s survive so
        -- _sum/_count stay correct.
        hist.b = {}
    end
    -- Every bucket must exist: lua-cjson turns a sparse numeric table into a
    -- JSON array full of nulls, and those decode back as cjson.null userdata.
    for i = 1, count do
        hist.b[i] = tonumber(hist.b[i]) or 0
    end
    hist.n = hist.n + 1
    hist.s = hist.s + seconds
    -- Buckets are ascending, so the first hit is the smallest le that covers the
    -- observation: b[i] stores the count for bucket i alone. The exporter
    -- prefix-sums it into the cumulative le= series (see render below); bumping
    -- every covering bucket here as well would count one request twice per
    -- bucket and make le=240 exceed _count.
    for i = 1, count do
        if seconds <= current[i] then
            hist.b[i] = hist.b[i] + 1
            break
        end
    end
    local encoded = json_encode(hist)
    if encoded then
        d:set(key, encoded)
    end
end

---Set a Prometheus gauge. Only for values that cannot be derived live.
function _M.gauge(metric, pairs, value)
    statsdict():set("g|" .. metric .. "|" .. label_pairs(pairs), value)
end

---------------------------------------------------------- config-store gauges
--
-- The one thing that has to be answerable from a scrape is "which backend is
-- this process actually writing to". Before these families existed a gateway
-- that silently fell back to the file backend looked exactly like a healthy
-- one from the outside: /health is a constant 200, and the only signal was
-- store_dispatcher.warn_once, which speaks once per process and then stays
-- quiet forever -- so a fallback at 03:00 was invisible unless somebody
-- happened to be grepping the boot minute of the log, and Prometheus had
-- nothing to alert on at all.
--
-- The cache behind publish_config_backend is per *process*. gauge() writes
-- lr_stats, which is shared by the workers of one instance only, so a second
-- gateway instance keeps its own series and the two can be compared in one
-- PromQL without overwriting each other. Cross-instance disagreement is the
-- failure worth alerting on: one replica on sqlite and its twin on file means
-- the authoritative snapshot has been split in two.

-- Fixed alphabets. Anything outside them collapses to "unknown" instead of
-- reaching the scrape as a raw string: backend reasons are derived from error
-- text, and an error message -- a path, a host, a driver's whole complaint --
-- is precisely what a Prometheus label must never be.
local CONFIG_BACKENDS = { sqlite = true, postgres = true, file = true }
local CONFIG_SAVE_RESULTS = {
    ok = true, conflict = true, unavailable = true, mirror_failed = true,
}
local CONFIG_DEGRADATION_REASONS = {
    driver_missing = true, probe_failed = true, unavailable = true,
    runtime_error = true, unknown_name = true,
}

local function config_label(value, allowed)
    return (type(value) == "string" and allowed[value]) and value or "unknown"
end

-- Which backend name this process last published, so re-resolving onto the
-- same backend costs zero shared-dict writes. Nil until the first publish,
-- which is what makes that first call always write.
local config_backend_published

---Publish the backend this process actually writes its config snapshot to.
---
---One series per known backend, the live one at 1 and the others at 0, so a
---scrape always answers the question with a number rather than with the
---absence of a line. NOTE for whoever writes the SQLite-down alert: a backend
---this process has never resolved to exports nothing at all until the first
---publish -- the family being absent is not evidence sqlite is down, since a
---gateway that has been writing to sqlite since last Tuesday also has no
---sqlite line before someone triggers a resolution. Alert on
---`lr_config_store_backend{backend="file"} == 1`, not on a missing series.
---@param backend_name string @ "sqlite" | "postgres" | "file"
function _M.publish_config_backend(backend_name)
    local name = config_label(backend_name, CONFIG_BACKENDS)
    if config_backend_published == name then
        return
    end
    config_backend_published = name
    for candidate in pairs(CONFIG_BACKENDS) do
        _M.gauge("lr_config_store_backend", { { "backend", candidate } },
            candidate == name and 1 or 0)
    end
end

---One backend resolution ended in a degradation: this process now writes
---somewhere other than what the operator asked for. `reason` is a fixed enum;
---a value outside it is reported as "unknown" rather than passed through.
---@param reason string @ driver_missing|probe_failed|unavailable|runtime_error|unknown_name
function _M.note_config_degradation(reason)
    _M.counter("lr_config_store_degradations_total",
        { { "reason", config_label(reason, CONFIG_DEGRADATION_REASONS) } })
end

---One config-store save attempt, classified by the caller.
---
---`mirror_failed` is the series that matters most, and it is the reason the
---result is a *parameter* rather than something inferred here: the database
---committed and the human-readable mirror did not, so the stale file is free
---to be adopted back over the newer db value by the external-edit path. The
---save still returned ok to its caller, so nothing on the request path will
---ever notice -- this counter is the only place it exists.
---@param result string @ ok|conflict|unavailable|mirror_failed
function _M.note_config_save(result)
    _M.counter("lr_config_store_saves_total",
        { { "result", config_label(result, CONFIG_SAVE_RESULTS) } })
end
-- ------------------------------------------------------------------ window

-- One key per 200ms bucket: a minute of history costs 300 keys, and the stats
-- window itself is cfg().stats_window_s (default 10s = 50 buckets).
local BUCKET_MS = 200
local BUCKET_TTL = 120

local function bucket_key(now_ms)
    return "w|" .. (math.floor(now_ms / BUCKET_MS) * BUCKET_MS)
end

local FIELDS = { "req", "err", "in_tok", "out_tok", "dur_ms", "dur_n",
                 "ttft_ms", "ttft_n", "est" }

local function note_window(field, value)
    if value == 0 then
        return
    end
    local d = statsdict()
    local key = bucket_key(ngx.now() * 1000)
    local sample
    local raw = d:get(key)
    if raw then
        sample = json_decode(raw)
        if type(sample) ~= "table" then
            sample = nil
        end
    end
    if not sample then
        sample = {}
        for i = 1, #FIELDS do
            sample[FIELDS[i]] = 0
        end
    end
    sample[field] = (sample[field] or 0) + value
    local encoded = json_encode(sample)
    if encoded then
        d:set(key, encoded, BUCKET_TTL)
    end
end

---Aggregate the window samples covering the last `window_s` seconds.
---@param window_s number
---@return table
local function read_window(window_s)
    local d = statsdict()
    local now_ms = ngx.now() * 1000
    local span = math.max(1, math.floor(window_s * 1000))
    local total = {}
    for i = 1, #FIELDS do
        total[FIELDS[i]] = 0
    end
    local buckets = math.ceil(span / BUCKET_MS)
    local seen = 0
    for offset = 0, buckets do
        local raw = d:get(bucket_key(now_ms - offset * BUCKET_MS))
        if raw then
            local sample = json_decode(raw)
            if type(sample) == "table" then
                seen = seen + 1
                for i = 1, #FIELDS do
                    total[FIELDS[i]] = total[FIELDS[i]] + (tonumber(sample[FIELDS[i]]) or 0)
                end
            end
        end
    end
    total.buckets = seen
    return total
end

-- ------------------------------------------------------------------ logging

---Lifecycle log line (registrations, breaker and health transitions).
function _M.log(message)
    ngx.log(ngx.NOTICE, "luarouter: ", message)
end

---Probe chatter and per-attempt detail, gated on SMG_LOG_LEVEL=debug.
function _M.log_debug(message)
    if cfg().log_level == "debug" then
        ngx.log(ngx.INFO, "luarouter: ", message)
    end
end

-- ------------------------------------------------------------------ inflight

---Concurrency-limiter outcome, same name and labels as the Rust
---smg_http_rate_limit_total (observability/metrics.rs:171, labels allowed/rejected).
---@param result string @ "allowed" or "rejected"
function _M.record_http_rate_limit(result)
    _M.counter("smg_http_rate_limit_total", { { "result", result } })
end

function _M.inflight_add(delta)
    local value = statsdict():incr("inflight", delta, 0)
    if not value or value < 0 then
        statsdict():set("inflight", math.max(0, value or 0))
    end
end

function _M.inflight()
    return statsdict():get("inflight") or 0
end

-- 写侧私有把手：inflight/logstore 子模块要用本文件的字典访问器、桶阶梯与
-- 滑窗读出，但这些名字不在 _M 导出面上（导出名集合是契约，不能增删）。
-- 走一张只在加载期存在的内部表：门面预登记，子模块按名取用。
package.loaded["resty.luarouter.observability._internal"] = {
    cfg = cfg,
    logdict = logdict,
    statsdict = statsdict,
    buckets = buckets,
    histo_key = histo_key,
    note_window = note_window,
    read_window = read_window,
}

require "resty.luarouter.observability.inflight"
require "resty.luarouter.observability.logstore"


-- ------------------------------------------------------------------ metric API

-- -------------------------------------------------- 入口 × 落点模型 × 服务维度
--
-- 既有族按 model 记，而 1 对多之后那个 model 是**入口的代表值**（组头）：同一个虚拟入口
-- 的 N 发请求在旧族里长得一模一样，「这个入口的流量有没有跑到预期的那台服务上」在指标
-- 上读不出来（日志行有 forwarded_model，指标族没有对应维度）。这六个族补的就是这一格：
-- entry 是客户端命名的服务入口，model 是选中候选的绑定名（实际落点），worker 是服务地址。
--
-- 两条口径刻意分开记账：worker 维度按 **attempt** 记（每次真实发出 +1，重试与熔断逃逸
-- 各算一发），entry 维度按**最终结果**只记一次（2xx）。两者相除才是重试/逃逸放大率，
-- 混进同一个口径这个数就永远算不出来。
--
-- 维度全部自取 ngx.ctx（lr_requested_model / lr_forwarded_model / lr_worker），router.lua
-- 只在 send_attempt 里加了一行 record_worker_attempt，其余入口都寄生在既有 record_* 上，
-- 所以这一组族的调用点与既有族完全一致，不存在「新族有数据、旧族没数据」的错位。

local ENTRY_FAMILY_PREFIX = "smg_entry_"
local ATTEMPT_FAMILY = "smg_worker_requests_total"

-- 逃生阀的状态：nil 表示还没读过环境。与 LR_INFLIGHT_* 同一顾虑 —— worker 环境在 fork
-- 之后被 nginx 重建，只有 conf 里 env 声明过的名字读得到（三份 conf 已声明 LR_MODEL_METRICS），
-- 缺省（未声明/未设）按开启处理，这样老部署的行为一字不变。
local model_metrics_conf = { enabled = nil }

---按入口/模型/服务聚合的六个族是否写。off 之外的一切取值都算开启（与 config.bool 相反，
---因为这里的语义是「例外关闭」而不是「显式打开」）。
---@return boolean enabled
function _M.model_metrics_enabled()
    if model_metrics_conf.enabled == nil then
        local value = os.getenv("LR_MODEL_METRICS")
        if type(value) == "string" then
            value = value:lower()
        end
        model_metrics_conf.enabled = not (value == "off" or value == "0"
            or value == "false" or value == "no")
    end
    return model_metrics_conf.enabled
end

---测试/复位用：清掉进程内的开关读数（线上没有调用点，关掉再打开开关要靠 reload）。
function _M.reset_model_metrics_switch()
    model_metrics_conf.enabled = nil
end

--- 归一（高基数的唯一防线）：model/entry 是**客户端可控**的字符串，直接进标签等于让它
--- 决定 series 数 —— 一个脚本轮换 1000 个假模型名就能把 lr_stats 的 LRU 打穿，连带把
--- 既有族的 counter 一起蒸发。所以只认「网关说过的名字」：虚拟入口名 ∪ 注册模型名，
--- 其余一律记 other。
---
--- 名字集合取 config_store.models_document()：那已经是「注册（引擎/配置报过的）∪ 卡片 ∪
--- 入口名」的合并视图，本模块自己不再拼一遍 registry 与 config 的两张表，也不再摆一层
--- 副本缓存（它是内存快照的读出，config_store 内部已有 SNAPSHOT_TTL 与 shdict 层）。
--- 落点模型必然出自这个集合（请求只能落在引擎承认的模型上），所以 other 只在客户端乱传
--- 名字时出现，它本身就是「这个入口收到了不认识的名字」的信号。
local OTHER = "other"

---本请求的已知名字集合。缓在 ngx.ctx 而不是模块变量：一个请求要为六个族做近十次归一，
---每来一次请求重新读一遍 config_store（reload 之后自然跟上新的入口/注册表）。
---@return table @ @[model] = true
local function known_name_set()
    local ctx = ngx and ngx.ctx
    if type(ctx) == "table" and type(ctx.lr_metric_names) == "table" then
        return ctx.lr_metric_names
    end
    local set = {}
    local ok, store = pcall(require, "resty.luarouter.config_store")
    if ok and type(store) == "table" and type(store.models_document) == "function" then
        local read_ok, rows = pcall(store.models_document)
        if read_ok and type(rows) == "table" then
            for i = 1, #rows do
                local row = rows[i]
                local name = type(row) == "table" and row.model or nil
                if type(name) == "string" and name ~= "" then
                    set[name] = true
                end
            end
        end
    end
    if type(ctx) == "table" then
        ctx.lr_metric_names = set
    end
    return set
end

---@param value any
---@return string
local function known_name(value)
    if type(value) ~= "string" or value == "" then
        return OTHER
    end
    local set = known_name_set()
    if set[value] then
        return value
    end
    return OTHER
end

---本请求的三个维度：入口名、落点模型（回退到入口代表值）、端点标签。
---@return table ctx, string entry, string model, string endpoint
local function request_dims()
    local ctx = ngx and ngx.ctx
    if type(ctx) ~= "table" then
        ctx = {}
    end
    local endpoint = type(ctx.lr_endpoint) == "string" and ctx.lr_endpoint or "other"
    return ctx, known_name(ctx.lr_requested_model),
        known_name(ctx.lr_forwarded_model or ctx.lr_model), endpoint
end

---一次**真实发出**的 upstream attempt（不是最终结果）：调用点是 router.lua 的 send_attempt，
---重试与熔断逃逸的每一发都在这里，因此 N 发 attempt 只对应一次 entry 记账。
---worker 用带 scheme 的完整 url，与 smg_worker_cb_* 的 worker 标签同一拼法，两个族才能在
---Grafana 里按同一个键叠在一起。
---@param worker table|nil @ 选中的记录（send_attempt 的参数）；缺失时回退 ngx.ctx.lr_worker
function _M.record_worker_attempt(worker)
    if not _M.model_metrics_enabled() then
        return
    end
    local ctx, _, model, endpoint = request_dims()
    local url = type(worker) == "table" and worker.url or nil
    if type(url) ~= "string" and type(ctx.lr_worker) == "table" then
        url = ctx.lr_worker.url
    end
    if type(url) ~= "string" or url == "" then
        return
    end
    _M.counter("smg_worker_requests_total", {
        { "endpoint", endpoint }, { "model", model }, { "worker", url },
    })
end

---入口维度的一次性记账，挂在 record_router_duration 上（router.lua 只在选中 worker 且
---2xx 时才调它，正好就是「最终成功服务」的口径）。
---@param seconds number
---@param endpoint string|nil @ 调用点传的端点标签，缺省回退 ngx.ctx
local function note_entry_request(seconds, endpoint)
    if not _M.model_metrics_enabled() then
        return
    end
    local ctx, entry, model, label = request_dims()
    if type(endpoint) == "string" and endpoint ~= "" then
        label = endpoint
    end
    _M.counter("smg_entry_requests_total", {
        { "endpoint", label }, { "entry", entry }, { "model", model },
        { "streaming", ctx.lr_stream == true and "true" or "false" },
    })
    _M.observe("smg_entry_request_duration_seconds",
        { { "entry", entry }, { "model", model } }, seconds)
    -- ttft 与 tpot 走同一批读数（lr_ttft / lr_tokens），和 smg_router_ttft_seconds 的
    -- 来源一致，区别只在标签：这里按 入口×落点 分，于是「换一台服务首字慢多少」可读。
    local ttft = tonumber(ctx.lr_ttft)
    if ttft then
        _M.observe("smg_entry_ttft_seconds",
            { { "entry", entry }, { "model", model } }, ttft)
        local tokens = ctx.lr_tokens
        local completion = type(tokens) == "table" and tonumber(tokens[2]) or 0
        if completion > 1 then
            -- 与既有 tpot 同式：(总时长 - ttft) / (输出 token - 1)，饱和相减。
            _M.observe("smg_entry_tpot_seconds",
                { { "entry", entry }, { "model", model } },
                math.max(0, seconds - ttft) / (completion - 1))
        end
    end
end

---Layer 1: a request hit the router.
function _M.record_http_request(method, path)
    _M.counter("smg_http_requests_total",
        { { "method", method }, { "path", path } })
    _M.inflight_add(1)
    -- Pair the concurrency counter with a start time. This is the position Rust
    -- takes the guard: HttpMetricsLayer is outside the route layers, so the
    -- request is tracked before auth and before the concurrency limiter
    -- (server.rs:1424) and an unauthenticated or 429'd request still has an age.
    _M.inflight_track()
    note_window("req", 1)
end

function _M.record_http_duration(method, path, seconds)
    _M.observe("smg_http_request_duration_seconds",
        { { "method", method }, { "path", path } }, seconds)
end

function _M.record_http_response(status, error_code)
    _M.counter("smg_http_responses_total",
        { { "status_code", tostring(status) }, { "error_code", error_code or "" } })
end

---Layer 2: one routed inference request.
function _M.record_router_request(model, endpoint, streaming)
    _M.counter("smg_router_requests_total", {
        { "router_type", "http" }, { "backend_type", "regular" },
        { "connection_mode", "http" }, { "model", model },
        { "endpoint", endpoint }, { "streaming", streaming and "true" or "false" },
    })
end

function _M.record_router_duration(model, endpoint, seconds)
    _M.observe("smg_router_request_duration_seconds", {
        { "router_type", "http" }, { "backend_type", "regular" },
        { "connection_mode", "http" }, { "model", model }, { "endpoint", endpoint },
    }, seconds)
    -- Time per output token, derived the way Rust's record_streaming_metrics
    -- does it (metrics.rs:750-764): (generation - ttft) / (output_tokens - 1),
    -- and only when there was a first token and more than one token after it.
    -- The Lua router has no separate generation timer, so the request duration
    -- plays that role - the same substitution finish_request already makes for
    -- the request log's tok_per_s column (router.lua decode_ms).
    -- Total generation time. Rust reaches it from the same streaming helper as
    -- ttft/tpot and only ever fills it on its non-HTTP plane; here the finished
    -- request duration *is* the generation window, so the family gets a real
    -- source instead of staying a name.
    _M.observe("smg_router_generation_duration_seconds", {
        { "router_type", "http" }, { "backend_type", "regular" },
        { "model", model }, { "endpoint", endpoint },
    }, seconds)
    local ttft = ngx.ctx.lr_ttft
    local tokens = ngx.ctx.lr_tokens
    -- 入口维度（新族）搭这同一班车：调用点 router.lua 已经保证「选中了 worker 且回 2xx」，
    -- 于是 smg_entry_requests_total 天然就是「最终成功服务」的口径，不需要在这里再看状态码。
    note_entry_request(seconds, endpoint)
    if ttft and type(tokens) == "table" and (tonumber(tokens[2]) or 0) > 1 then
        -- saturating subtract, as Rust does: a response whose last chunk lands in
        -- the same clock tick as the first records 0 rather than being skipped.
        local decode_s = math.max(0, seconds - ttft)
        _M.observe("smg_router_tpot_seconds", {
            { "router_type", "http" }, { "backend_type", "regular" },
            { "model", model }, { "endpoint", endpoint },
        }, decode_s / (tokens[2] - 1))
    end
end

function _M.record_router_error(model, endpoint, error_type)
    _M.counter("smg_router_request_errors_total", {
        { "router_type", "http" }, { "backend_type", "regular" },
        { "connection_mode", "http" }, { "model", model },
        { "endpoint", endpoint }, { "error_type", error_type },
    })
end

function _M.record_router_upstream_response(status, error_code)
    _M.counter("smg_router_upstream_responses_total", {
        { "router_type", "http" }, { "status_code", tostring(status) },
        { "error_code", error_code or "" },
    })
end

function _M.record_router_ttft(model, endpoint, seconds)
    _M.observe("smg_router_ttft_seconds", {
        { "router_type", "http" }, { "backend_type", "regular" },
        { "model", model }, { "endpoint", endpoint },
    }, seconds)
    note_window("ttft_ms", seconds * 1000)
    note_window("ttft_n", 1)
end

---Charge one token count to the family. `token_type` is prompt | completion |
---cached | reasoning.
---
---Two deliberate departures from Rust, both documented in
---doc/gap-token-accounting.md: the label values are prompt/completion (Rust uses
---input/output, and the Lua router already exported prompt/completion before this
---change, so the series names stay stable), and the two detail counts
---(cached/reasoning) exist at all because the Lua router reads
---prompt_tokens_details.cached_tokens and completion_tokens_details.reasoning_tokens
---where Rust only ever increments the input/output pair.
---
---prompt/completion are charged on every accounted row, including the byte/4
---fallback rows, exactly as before this file grew the extra types -- those rows
---carry tokens_estimated in the request log and a share in
---/_ui/stats.tokens_estimated_share, which is how a dashboard tells them apart.
---cached and reasoning only ever arrive from a backend usage object
---(usage_from_object reads prompt_tokens_details.cached_tokens and
---completion_tokens_details.reasoning_tokens), so a non-zero series on either is
---something the engine itself reported and never a gateway guess.
function _M.record_router_tokens(model, endpoint, token_type, count)
    if not count or count <= 0 then
        return
    end
    _M.counter("smg_router_tokens_total", {
        { "router_type", "http" }, { "backend_type", "regular" },
        { "model", model }, { "endpoint", endpoint }, { "token_type", token_type },
    }, count)
    -- 同一份读数的入口×落点视角：token_type 沿用 prompt/completion/cached/reasoning 的
    -- 既有取值（doc/gap-token-accounting.md 的口径），新族只换维度、不改统计口径。
    if _M.model_metrics_enabled() then
        local _, entry, entry_model, label = request_dims()
        _M.counter("smg_entry_tokens_total", {
            { "endpoint", endpoint or label }, { "entry", entry },
            { "model", entry_model }, { "token_type", token_type },
        }, count)
    end
end

---Did the gateway have to ask the backend for a usage frame on the client's
---behalf, and what happened to it? The answer to "can I trust the token counters
---on this deployment" question, per model and endpoint:
---  stripped          usage injected, frame read, frame removed from the client
---                    stream (the intended steady state for a client that asked
---                    for nothing)
---  passed_through    usage injected but nothing was removed -- either the engine
---                    sent no usage frame at all, or the only frame carrying one
---                    also carried content the client needs (a finish_reason), and
---                    sse_event_droppable refused to touch it
---  rejected          the worker answered 400 quoting stream_options, so the
---                    injection is disabled for it (doc/gap-token-accounting.md 6)
---Lua-side superset: the Rust gateway never injects, so it has no such series.
---@param model string
---@param endpoint string
---@param result string @ stripped | passed_through | rejected
function _M.record_stream_usage_injection(model, endpoint, result)
    _M.counter("smg_router_usage_injection_total", {
        { "model", model }, { "endpoint", endpoint }, { "result", result },
    })
end

---Layer 3: worker-level events. `worker_url` is the label value, as in Rust.
function _M.record_worker_selection(worker_url, model, policy)
    _M.counter("smg_worker_selection_total", {
        { "worker_type", "regular" }, { "connection_mode", "http" },
        { "model", model or "unknown" }, { "policy", policy or "round_robin" },
    })
end

function _M.record_worker_error(worker_url, error_type)
    _M.counter("smg_worker_errors_total", {
        { "worker_type", "regular" }, { "connection_mode", "http" },
        { "error_type", error_type },
    })
end

function _M.record_worker_retry(endpoint)
    _M.counter("smg_worker_retries_total",
        { { "worker_type", "regular" }, { "endpoint", endpoint } })
end

--- The Rust histogram is labelled only by attempt number (1..5, higher values
--- collapse to their own bucket), not by worker or endpoint.
function _M.record_worker_retry_backoff(attempt, seconds)
    if attempt < 1 then
        attempt = 1
    end
    _M.observe("smg_worker_retry_backoff_seconds",
        { { "attempt", tostring(attempt) } }, seconds)
end

function _M.record_worker_retries_exhausted(endpoint)
    _M.counter("smg_worker_retries_exhausted_total",
        { { "worker_type", "regular" }, { "endpoint", endpoint } })
end

function _M.record_health_check(worker_url, ok)
    _M.counter("smg_worker_health_checks_total", {
        { "worker_type", "regular" }, { "result", ok and "success" or "failure" },
    })
end

function _M.record_cb_transition(worker_url, from, to)
    _M.counter("smg_worker_cb_transitions_total", {
        { "worker", worker_url }, { "from", from }, { "to", to },
    })
end

function _M.record_cb_outcome(worker_url, outcome)
    _M.counter("smg_worker_cb_outcomes_total",
        { { "worker", worker_url }, { "outcome", outcome } })
end

-- ------------------------------------------------------------------ watcher
--
-- Registration points for the in-process watcher (doc/gap-watcher-merge.md). The
-- standalone daemon published these as llm_watcher_* on its own metrics port;
-- merged into the router they ride the normal exporter under lr_watch_*, and the
-- counters accumulate in lr_stats exactly like the smg_* families above - watcher.lua
-- calls this once per reconcile pass, and nothing here reads or reorganises the
-- existing logic.
---@param stats table @ the {reconciles, adds, add_fails, removes, discovered,
---                     adds_stuck_released, probe_failures, probe_removes,
---                     probe_fuse_skips} a pass produced
---@param owned number @ ledger-owned worker URLs
---@param protected number @ first-contact protected worker URLs
---@param map_entries number @ active model-map renames
function _M.record_watch_pass(stats, owned, protected, map_entries)
    _M.counter("lr_watch_reconciles_total", {}, stats.reconciles or 0)
    _M.counter("lr_watch_adds_total", {}, stats.adds or 0)
    _M.counter("lr_watch_add_fails_total", {}, stats.add_fails or 0)
    _M.counter("lr_watch_removes_total", {}, stats.removes or 0)
    _M.counter("lr_watch_adds_stuck_released_total", {},
        stats.adds_stuck_released or 0)
    -- The three probe-eviction families exist because lr_watch_removes_total alone
    -- cannot answer the question an operator actually asks when the pool drains: was
    -- it a service that really stopped being a worker, or the gateway's own probes
    -- failing? probe_removes is the subset of removes the strict probe caused, and
    -- probe_failures counts the transport-level unknowns that were *not* acted on
    -- yet - a rising probe_failures with flat probe_removes is a flapping upstream
    -- being correctly held by the hysteresis, while probe_removes climbing with it
    -- is the flapping winning.
    _M.counter("lr_watch_probe_failures_total", {}, stats.probe_failures or 0)
    _M.counter("lr_watch_probe_removes_total", {}, stats.probe_removes or 0)
    _M.counter("lr_watch_probe_fuse_skips_total", {}, stats.probe_fuse_skips or 0)
    -- Candidate probes this pass did not make because of SMG_WATCHER_MAX_CANDIDATES /
    -- SMG_WATCHER_PASS_BUDGET_SECS. This is the counter that says "the box has more
    -- listeners than the probe budget covers", which is the state 21.k was in; without
    -- it a budgeted pass is indistinguishable from a quiet host. Owned workers are
    -- never cut, so this rising does NOT mean discovery is being starved.
    _M.counter("lr_watch_probe_budget_skips_total", {},
        stats.probe_budget_skips or 0)
    _M.gauge("lr_watch_discovered_workers", {}, stats.discovered or 0)
    _M.gauge("lr_watch_owned_workers", {}, owned or 0)
    _M.gauge("lr_watch_protected_workers", {}, protected or 0)
    _M.gauge("lr_watch_model_map_entries", {}, map_entries or 0)
end



---Charge a finished request to the window (tokens, latency, estimate flag).
function _M.note_tokens(input_tokens, output_tokens, estimated)
    note_window("in_tok", input_tokens or 0)
    note_window("out_tok", output_tokens or 0)
    if estimated then
        note_window("est", 1)
    end
end

function _M.note_duration(seconds)
    note_window("dur_ms", seconds * 1000)
    note_window("dur_n", 1)
end

function _M.note_error()
    note_window("err", 1)
end


-- Family-name prefix of everything the tracker publishes. With the sampler off
-- (LR_INFLIGHT_SAMPLE_SECS=0) the exporter drops every key whose metric name
-- starts with this, so a snapshot left in lr_stats before the switch cannot be
-- scraped as if it were current.
local INFLIGHT_FAMILY = "smg_http_inflight_request_age"


-- ------------------------------------------------------------------ prometheus

-- Every string is copied from the matching describe_* macro in
-- gateway/src/observability/metrics.rs so one Grafana query reads the same
-- comment on either gateway. Families with no Rust counterpart are marked.
local HELP = {
    smg_http_requests_total = "Total HTTP requests by method and path",
    smg_http_request_duration_seconds = "HTTP request duration by method and path",
    smg_http_responses_total = "Total HTTP responses by status_code and error_code",
    -- Rust reads this from an atomic connection counter incremented in its
    -- metrics middleware (middleware.rs:929); the Lua value comes from nginx's
    -- own stub_status counters (see http_connections_active).
    smg_http_connections_active = "Currently active HTTP connections",
    smg_router_requests_total = "Total routed requests by router_type, backend_type, connection_mode, model, endpoint, streaming",
    smg_router_request_duration_seconds = "Router request duration by router_type, backend_type, connection_mode, model, endpoint",
    smg_router_request_errors_total = "Router errors by router_type, backend_type, connection_mode, model, endpoint, error_type",
    smg_router_upstream_responses_total = "Upstream backend HTTP responses by router_type, status_code, error_code",
    -- Rust marks these three describes as only filled on its non-HTTP plane,
    -- because its HTTP router never reaches the streaming-metrics helper. The
    -- Lua router records them for HTTP streaming as well, so that qualifier is
    -- dropped rather than repeated as a false claim about the series.
    smg_router_ttft_seconds = "Time to first token by router_type, backend_type, model, endpoint",
    smg_router_tpot_seconds = "Time per output token by router_type, backend_type, model, endpoint",
    smg_router_generation_duration_seconds = "Total generation time by router_type, backend_type, model, endpoint",
    smg_router_tokens_total = "Total tokens processed by router_type, backend_type, model, endpoint, token_type",
    -- Lua-side superset (doc/gap-token-accounting.md): Rust never injects
    -- stream_options.include_usage, so it has nothing to report about it.
    smg_router_usage_injection_total = "Streaming usage-frame injections by model, endpoint, result (stripped/passed_through/rejected)",
    smg_worker_selection_total = "Worker selection events by worker_type, connection_mode, model, policy",
    smg_worker_errors_total = "Worker-level errors by worker_type, connection_mode, error_type",
    smg_worker_retries_total = "Total retry attempts by worker_type and endpoint",
    smg_worker_retries_exhausted_total = "Requests that exhausted all retries by worker_type and endpoint",
    smg_worker_retry_backoff_seconds = "Retry backoff duration by attempt number",
    smg_worker_health_checks_total = "Health check results by worker_type and result",
    smg_worker_cb_transitions_total = "Circuit breaker state transitions by worker, from, to",
    smg_worker_cb_outcomes_total = "Circuit breaker outcomes by worker and outcome (success/failure)",
    smg_worker_health = "Worker health status (1=healthy, 0=unhealthy)",
    smg_worker_requests_active = "Currently running requests per worker",
    smg_worker_cb_state = "Circuit breaker state per worker (0=closed, 1=open, 2=half_open)",
    smg_worker_cb_consecutive_failures = "Current consecutive failure count per worker",
    smg_worker_cb_consecutive_successes = "Current consecutive success count per worker",
    -- Rust sets this per unique (worker_type, connection_mode, model) triple on
    -- every registry mutation (steps/worker/shared/register.rs:77); the Lua
    -- exporter derives the same series from lr_workers at scrape time, which is
    -- why an empty combination is simply absent rather than rendered as 0.
    smg_worker_pool_size = "Current worker pool size by worker_type, connection_mode, model",
    -- Lua-side superset: the Rust gateway has no per-worker capacity caps, so this
    -- family only exists here. The candidate filter (router/candidates.lua) emits it
    -- with reason=concurrency_max|gpu_util, and those two readings are different in
    -- kind (an in-flight count this gateway owns versus an external GPU-utilisation
    -- sample), so one HELP line naming both keeps a Grafana legend from reading the
    -- family as a single undifferentiated failure mode. Missing this entry is not
    -- cosmetic: the exporter prints the TYPE line with no HELP above it and the
    -- scraper is left with a blank description.
    -- (doc/caps-redesign-2026-10-06.md section 6: reason=power retired with the watt
    -- ceiling; the readings are now max_concurrency and max_gpu_util.)
    smg_worker_capacity_excluded_total = "Candidates removed from selection by their configured concurrency limit or GPU-utilisation limit by reason",
    -- Sibling of the family above, and deliberately *not* part of it: the green-light
    -- preference (doc/caps-redesign-2026-10-06.md section 3) hands the policy only the
    -- idle subset when one exists, so busy workers yield without being excluded -- they
    -- stay selectable and nothing about them is "removed". A separate family is what
    -- keeps "the pool refused traffic" (excluded_total) readable apart from "the pool
    -- preferred someone else" (this one); one counted sample per request pass that
    -- actually stepped a busy candidate aside.
    smg_worker_capacity_preferred_idle_total = "Selection passes where idle workers were preferred and busy workers yielded the choice",
    -- watcher 临时禁用（用户裁定 2026-10-09）：探针「其他情况」保行、候选装配按 td:
    -- 键排除时逐候选计一次。与 capacity 硬排除分开计,让操作员能从 /metrics 分辨
    -- "这台被判不是合格 worker 暂时屏蔽" 与 "这台容量到顶被排除"。
    smg_worker_temp_disabled_total = "Candidates excluded from selection by a watcher temporary-disable (td:) marker, distinct from the capacity ceiling",
    -- Lua-side superset: Rust has no tracing-self metrics and no in-flight gauge.
    smg_http_inflight_requests = "Requests currently being served by the router",
    -- Rust renders this family as non-cumulative gt/le gauges off a 30 s..86400 s
    -- ladder; the Lua exporter emits it as a cumulative histogram over the
    -- duration ladder because that is the shape a scraper can read with
    -- histogram_quantile here. See doc/gap-inflight-age.md.
    smg_http_inflight_request_age_count = "In-flight HTTP request ages in seconds, sampled on a fixed interval (cumulative buckets over the duration ladder)",
    -- Lua-side superset: the tracker's saturation signal, so the approximated
    -- ages above are auditable.
    smg_http_inflight_request_age_dropped_total = "In-flight age registrations dropped because every probed slot was taken",
    smg_http_inflight_request_age_slots_active = "In-flight requests currently held in the age tracker",
    smg_http_rate_limit_total = "Rate limiting decisions by result (allowed/rejected)",
    -- Policy-internal bookkeeping (resty.luarouter.policy).
    smg_manual_policy_branch_total = "Manual policy execution branch by branch",
    smg_consistent_hashing_policy_branch_total = "Consistent hashing policy execution branch by branch",
    smg_prefix_hash_policy_branch_total = "Prefix hash policy execution branch by branch",
    smg_manual_policy_cache_entries = "Number of routing entries in manual policy cache",
    smg_worker_routing_keys_active = "Active routing keys per worker",
    -- Lua-side superset: the Rust cache_aware tree exposes no tenant gauge.
    smg_cache_aware_tenant_count = "Tenants tracked by the cache_aware policy trees",
    -- Same superset, and the reason this branch exists: the 21.k incident could only be
    -- read off smaps_rollup's Private_Dirty, because nothing said how much affinity
    -- state the process was carrying. These three say it (doc/gap-cpu-idle-burn.md).
    smg_cache_aware_tree_count = "cache_aware affinity trees held by this process",
    smg_cache_aware_tree_nodes = "Live prefix-tree nodes across this process (the memory driver)",
    smg_cache_aware_tree_chars = "Prompt characters retained by the cache_aware trees",
    -- S2: instances are per <policy>:<model/entry>, each with its own trees. Before the
    -- reclaimer this grew with every name that ever appeared and never shrank.
    smg_policy_instances = "Policy instances alive in this process (per-model/entry)",
    -- Cardinality guard on the model label; reaching the cap means further names
    -- collapse to other=, i.e. per-model series stop being trustworthy.
    smg_model_label_cardinality = "Distinct model label values stored in lr_stats",
    -- A bounded exporter scan that hit its limit. The counterweight to SCAN_LIMIT:
    -- truncation must never be silent (label: which dict was scanned).
    smg_dict_scan_truncated = "1 when the last scrape truncated a shared-dict scan by dict",
    -- Lua-side superset: the in-process watcher (merged llm-watcher daemon), so a
    -- dashboard can see discovery churn without a second scrape target. Names
    -- mirror the daemon's llm_watcher_* families.
    lr_watch_reconciles_total = "Reconcile passes completed by the in-process watcher",
    lr_watch_adds_total = "Workers registered by the in-process watcher",
    lr_watch_add_fails_total = "Worker registrations the in-process watcher rejected",
    lr_watch_removes_total = "Workers removed by the in-process watcher",
    lr_watch_adds_stuck_released_total = "Stuck watcher registrations released",
    -- Subsets of the two families above, split out so a dashboard can tell "a worker
    -- really stopped being a worker" from "the router's probes could not read it":
    -- probe_failures is the hysteresis holding a transport-level unknown below the
    -- eviction threshold, probe_removes is the part of removes the strict probe
    -- caused, probe_fuse_skips is what one pass refused to delete when the probes
    -- condemned more than half the owned pool at once.
    lr_watch_probe_failures_total = "Probe rejections held by the watcher hysteresis instead of evicting",
    lr_watch_probe_removes_total = "Workers removed by the in-process watcher because their probe refused them",
    lr_watch_probe_fuse_skips_total = "Probe-driven removals a watcher pass skipped because its fuse tripped",
    lr_watch_probe_budget_skips_total = "Candidate probes a watcher pass cut because of its probe budget",
    lr_watch_discovered_workers = "Workers discovered by the last watcher pass",
    lr_watch_owned_workers = "Workers the in-process watcher currently owns",
    lr_watch_protected_workers = "Pre-existing workers the in-process watcher will never delete",
    lr_watch_model_map_entries = "Active watcher model-map renames",
    -- Config-store persistence (resty.luarouter.store_dispatcher). Before these
    -- existed, all 71 lr_* names were watch / gpu_load / inflight: a gateway that
    -- had silently degraded to the file backend exported nothing about it, so the
    -- split-brain shape (this replica writing db, its twin writing a file, each
    -- believing it is the authoritative source) had no signal anywhere.
    --   backend        = the one this process actually writes to, 1 across the
    --                    three known values with the others at 0, so "am I on
    --                    file?" is a read rather than the absence of a line
    --   degradations   = a resolution that ended on a weaker backend than the one
    --                    the operator asked for. reason is a fixed enum:
    --                    driver_missing (module/driver not in the image),
    --                    probe_failed (answers available() but cannot hand back a
    --                    revision), unavailable (openable but refused),
    --                    runtime_error (the backend broke mid-life), unknown_name
    --                    (LMR_CONFIG_STORE_BACKEND spelled something unrecognised)
    --   saves          = save attempts by result. conflict is a CAS rejection, and
    --                    unavailable is a save that could not reach the backend at
    --                    all -- both are counted where they happen, in the backend,
    --                    so a save path in another file cannot quietly drop them.
    --                    mirror_failed is the dangerous one: the db committed and
    --                    the file mirror did not, which leaves the stale file free
    --                    to be adopted back over the newer db value.
    lr_config_store_backend = "Config snapshot backend this process writes to (1=active) by backend (sqlite/postgres/file)",
    lr_config_store_degradations_total = "Config store resolutions that degraded to a weaker backend by reason",
    lr_config_store_saves_total = "Config snapshot save attempts by result (ok/conflict/unavailable/mirror_failed)",
    -- Power channel of the GPU load source (the per-worker max_power_w cap). Separate
    -- families from lr_gpu_load* on purpose: those are a 0..1 score, these are
    -- absolute watts, and one dashboard axis cannot carry both. They only appear
    -- when SMG_LOAD_POWER / SMG_LOAD_POWER_QUERY is on, so a box that never opted
    -- in exports exactly what it exported before.
    --   samples      = watt readings that reached the registry's `pw:` key
    --   parse_failures = the reading that should have been there and was not: no
    --                    power gauge in the body, the query failed, or the answer
    --                    was not a legal PromQL vector
    --   rejected     = a reading that reached registry.set_power_w and was refused
    --                    there as unusable. Near-zero by construction: this module
    --                    screens with power_watt() before calling, so a non-zero
    --                    count here means an exporter that answers with numbers
    --                    this gateway cannot trust (negative/NaN/inf) rather than
    --                    an exporter that is merely silent -- the latter shows up
    --                    as parse_failures, not here.
    --   unmatched    = series naming a host no pooled worker is behind
    lr_gpu_load_power_samples_total = "GPU watt samples stored by the load source",
    lr_gpu_load_power_parse_failures_total = "GPU watt readings the load source could not obtain or parse",
    lr_gpu_load_power_rejected_total = "GPU watt readings refused by the registry as unusable",
    lr_gpu_load_power_unmatched_total = "GPU watt series naming a host with no pooled worker",
    lr_gpu_load_power_workers = "Workers with a fresh GPU watt sample",
    lr_gpu_load_power_watts = "Hottest GPU power draw per worker in watts (absolute, not a 0..1 score)",
}

---Pool membership labels for one worker record, in the spelling Rust uses.
---
---`worker_type` is the record's own field (this gateway stores regular workers
---only, so the prefill/decode folding that pd.pool_of used to do is gone).
---`connection_mode` is the record's transport, which after the scope trim can
---only ever be http.
---@param record table
---@return string worker_type, string connection_mode, string model
local function pool_labels_for(record)
    local pool = record.worker_type
    if pool ~= "regular" then
        pool = "regular"
    end
    local mode = "http"
    local model = record.model_id
    if type(model) ~= "string" or model == "" then
        model = "unknown"
    end
    return pool, mode, model
end

---Count workers per unique (worker_type, connection_mode, model) triple.
---Label pairs are alphabetical so the rendered series text matches the order
---the Rust exporter prints them in.
---@param records table[]
---@return table[] @ { { labels = label_pairs text, value = n }, ... }
function _M.pool_size_counts(records)
    local seen = {}
    local out = {}
    for i = 1, #records do
        local pool, mode, model = pool_labels_for(records[i])
        local key = mode .. "\0" .. model .. "\0" .. pool
        local entry = seen[key]
        if not entry then
            entry = {
                labels = label_pairs({ { "connection_mode", mode },
                                       { "model", model },
                                       { "worker_type", pool } }),
                value = 0,
            }
            seen[key] = entry
            out[#out + 1] = entry
        end
        entry.value = entry.value + 1
    end
    return out
end

---Routing keys currently bound to each worker, derived from the manual policy
---sticky map in lr_policy.
---
---Rust measures the in-flight set: WorkerRoutingKeyLoad (core/worker.rs:72) is
---incremented by WorkerLoadGuard::new with the request's routing key and
---decremented when the guard drops, so an idle session holds nothing. The Lua
---manual policy has no per-request guard, and lr_policy is the durable state
---that survives across processes: `manual:<model>|<routing-key>` holds the
---candidate URL list Rust keeps in Node::candi_worker_urls, and occupied_hit
---walks that list in order, so the *first* url is the worker the key is pinned
---to while the tail is failback history. Attributing a key to its first url is
---therefore "which worker does this key currently belong to", the same question
---the Rust gauge answers, with one documented difference: the binding lives as
---long as the sticky entry does (SMG_MAX_IDLE_SECS) instead of as long as one
---request. A key whose worker has left keeps counting on that worker, which is
---exactly the failback state Rust never notices either (it is not told about
---removals).
---
---The scan is get_keys(0) over lr_policy, i.e. the same sweep
---policy.lua:publish_gauges() does for smg_manual_policy_cache_entries; a fleet
---with thousands of sticky keys pays one dict walk per scrape for it.
---@param d ngx.shared.Dict|nil
---@return table @{ [worker_url] = routing_key_count }
function _M.manual_routing_key_counts(d)
    d = d or (ngx and ngx.shared and ngx.shared[POLICY_DICT])
    local counts = {}
    if not d then
        return counts
    end
    -- Bounded: this runs at scrape time on every /metrics, and manual: rows age out
    -- only through max_idle_secs, so the scan length is set by how many rows the dict
    -- has ever held rather than by the routing keys that are live.
    local keys = d:get_keys(SCAN_LIMIT)
    for i = 1, #keys do
        local key = keys[i]
        if key:sub(1, 7) == "manual:" then
            local urls = json_decode(d:get(key) or "")
            -- cjson decodes [] as an empty table and a JSON null as userdata,
            -- so only a real string in slot 1 names a bound worker.
            if type(urls) == "table" and type(urls[1]) == "string" then
                counts[urls[1]] = (counts[urls[1]] or 0) + 1
            end
        end
    end
    return counts
end

---Active (non-idle) client connections from the stub_status counters, or nil
---when the module is absent. Read at scrape time, never stored.
---@return number|nil
function _M.http_connections_active()
    if not ngx or not ngx.var then
        return nil
    end
    local reading = tonumber(ngx.var.connections_reading)
    local writing = tonumber(ngx.var.connections_writing)
    if not reading or not writing then
        return nil
    end
    return reading + writing
end

---Prometheus exposition text for everything recorded so far.
---@return string
function _M.prometheus_text()
    local d = statsdict()
    local keys = d:get_keys(SCAN_LIMIT)

    local metrics = {}
    local function family(name)
        local f = metrics[name]
        if not f then
            f = { counters = {}, gauges = {}, histograms = {} }
            metrics[name] = f
        end
        return f
    end

    -- 截断必须可见，否则这是一次指标悄悄变少的故障。它不能只走 gauge()：那一行在取
    -- keys 的时刻还不存在，于是本轮渲染的永远是上一拍的答案。所以直接登记进 family，
    -- 同时 set 回字典给下一拍。
    local truncated = (#keys >= SCAN_LIMIT) and 1 or 0
    local truncated_label = label_pairs({ { "dict", STATS_DICT } })
    family("smg_dict_scan_truncated").gauges[truncated_label] = truncated
    d:set("g|smg_dict_scan_truncated|" .. truncated_label, truncated)

    local tracker_on = _M.inflight_enabled()
    for i = 1, #keys do
        local key = keys[i]
        local kind, name, rest = string.match(key, "^(%a)|([%w_]+)|(.*)$")
        if kind and name then
            -- With the tracker switched off (LR_INFLIGHT_SAMPLE_SECS=0) the whole
            -- age family stays out of the scrape, even if a value survived from a
            -- tick taken before the switch: a stale distribution has no right to a
            -- graph, and the contract is "no sampler, no family".
            -- string.find with plain=true would treat the leading caret as a
            -- literal, so the prefix test is a byte comparison instead.
            local age_off = not tracker_on
                and string.sub(name, 1, #INFLIGHT_FAMILY) == INFLIGHT_FAMILY
            if not age_off then
                local value = d:get(key)
                if kind == "c" then
                    family(name).counters[rest] = value
                elseif kind == "g" then
                    family(name).gauges[rest] = value
                elseif kind == "h" then
                    family(name).histograms[rest] = json_decode(value)
                end
            end
        end
    end

    -- Per-worker gauges come straight from the registry, never from lr_stats.
    local registry = require "resty.luarouter.registry"
    local records = registry.records()
    local health_f = family("smg_worker_health")
    local active_f = family("smg_worker_requests_active")
    local cb_state_f = family("smg_worker_cb_state")
    local cb_fail_f = family("smg_worker_cb_consecutive_failures")
    local cb_succ_f = family("smg_worker_cb_consecutive_successes")
    for i = 1, #records do
        local record = records[i]
        local label = label_pairs({ { "worker", record.url } })
        local state = registry.cb_state(record.id)
        health_f.gauges[label] = state.healthy and 1 or 0
        active_f.gauges[label] = state.load
        cb_state_f.gauges[label] = state.state
        cb_fail_f.gauges[label] = state.consecutive_failures
        cb_succ_f.gauges[label] = state.consecutive_successes
    end
    -- Pool sizes are counted per unique (worker_type, connection_mode, model)
    -- triple straight out of the registry, and a combination with no workers is
    -- absent (Rust only ever calls set_worker_pool_size for combinations it saw
    -- registered).
    local pool_sizes = _M.pool_size_counts(records)
    if #pool_sizes > 0 then
        local pool_f = family("smg_worker_pool_size")
        for i = 1, #pool_sizes do
            pool_f.gauges[pool_sizes[i].labels] = pool_sizes[i].value
        end
    end
    -- Routing-key footprint of the manual policy, one series per worker that
    -- currently holds a key (see manual_routing_key_counts).
    local routing_keys = _M.manual_routing_key_counts()
    if next(routing_keys) ~= nil then
        local keys_f = family("smg_worker_routing_keys_active")
        for worker_url, count in pairs(routing_keys) do
            keys_f.gauges[label_pairs({ { "worker", worker_url } })] = count
        end
    end
    -- Config-store backend: derived at scrape time from the dispatcher when that
    -- module is already loaded, so the series always names what the process is
    -- really doing even if lr_stats evicted the stored gauge. package.loaded (not
    -- a require) keeps the scrape side-effect free: a poll must never be the thing
    -- that opens the database, and a process that has not resolved a backend yet
    -- renders nothing here rather than an invented default -- the same honest
    -- absence the per-worker pool sizes follow.
    local dispatcher = package.loaded["resty.luarouter.store_dispatcher"]
    if type(dispatcher) == "table"
        and type(dispatcher.active_backend_name) == "function" then
        local resolved = dispatcher.active_backend_name()
        if type(resolved) == "string" and CONFIG_BACKENDS[resolved] then
            config_backend_published = resolved
            for candidate in pairs(CONFIG_BACKENDS) do
                family("lr_config_store_backend").gauges[
                    label_pairs({ { "backend", candidate } })
                ] = (candidate == resolved) and 1 or 0
            end
        end
    end
    family("smg_http_inflight_requests").gauges[""] = _M.inflight()
    -- The tracker's own occupancy, read from the slot table rather than stored,
    -- so it cannot disagree with the samples the histogram was built from. With
    -- the sampler off (LR_INFLIGHT_SAMPLE_SECS=0) neither it nor the histogram is
    -- rendered: a tracker that never ran has nothing to report.
    if _M.inflight_enabled() then
        family("smg_http_inflight_request_age_slots_active").gauges[""] =
            _M.inflight_slots_used()
    end
    -- nginx's stub_status counters, when the module is compiled in (it is in
    -- both shipped images). Rust counts connections whose request future is
    -- being polled, so idle keep-alive sockets - the "waiting" state - are
    -- excluded to keep the two gauges measuring the same thing.
    local connections = _M.http_connections_active()
    if connections then
        family("smg_http_connections_active").gauges[""] = connections
    end

    local names = {}
    for name in pairs(metrics) do
        names[#names + 1] = name
    end
    table.sort(names)

    local out = {}
    for _, name in ipairs(names) do
        local f = metrics[name]
        local has_counter = next(f.counters) ~= nil
        local has_gauge = next(f.gauges) ~= nil
        local has_hist = next(f.histograms) ~= nil
        -- A family with no series at all is a derived one whose source was empty
        -- (no workers, no discovery polls yet). Rust's exporter omits those
        -- entirely, and declaring `# TYPE x untyped` above nothing would both
        -- disagree with the Rust scrape and mis-type a gauge that is merely idle.
        if has_counter or has_gauge or has_hist then
            local type_name = has_counter and "counter"
                or (has_gauge and "gauge" or (has_hist and "histogram" or "untyped"))
            if HELP[name] then
                out[#out + 1] = "# HELP " .. name .. " " .. HELP[name]
            end
            out[#out + 1] = "# TYPE " .. name .. " " .. type_name

            local labels = {}
            for label in pairs(f.counters) do
                labels[#labels + 1] = label
            end
            table.sort(labels)
            for _, label in ipairs(labels) do
                out[#out + 1] = name .. render_labels(label) .. " " .. tostring(f.counters[label])
            end

            labels = {}
            for label in pairs(f.gauges) do
                labels[#labels + 1] = label
            end
            table.sort(labels)
            for _, label in ipairs(labels) do
                out[#out + 1] = name .. render_labels(label) .. " " .. tostring(f.gauges[label])
            end

            labels = {}
            for label in pairs(f.histograms) do
                labels[#labels + 1] = label
            end
            table.sort(labels)
            for _, label in ipairs(labels) do
                local hist = f.histograms[label]
                if type(hist) == "table" then
                    -- Prometheus bucket series is cumulative: le=x counts every
                    -- observation <= x. observe() keeps b[i] per-bucket, so the
                    -- prefix sum happens here and only here.
                    local current, count = buckets()
                    local cumulative = 0
                    for i = 1, count do
                        local bucket_count_i = tonumber(hist.b and hist.b[i]) or 0
                        cumulative = cumulative + bucket_count_i
                        out[#out + 1] = name .. "_bucket"
                            .. render_bucket_labels(label, current[i]) .. " "
                            .. tostring(cumulative)
                    end
                    out[#out + 1] = name .. "_bucket"
                        .. render_bucket_labels(label, math.huge) .. " "
                        .. tostring(hist.n or 0)
                    out[#out + 1] = name .. "_sum" .. render_labels(label) .. " "
                        .. string.format("%.6f", tonumber(hist.s) or 0)
                    out[#out + 1] = name .. "_count" .. render_labels(label) .. " "
                        .. tostring(tonumber(hist.n) or 0)
                end
            end
        end
    end
    return table.concat(out, "\n") .. "\n"
end

_M.render_labels = render_labels
_M.label_pairs = label_pairs

return _M
