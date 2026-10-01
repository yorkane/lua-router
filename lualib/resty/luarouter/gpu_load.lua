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
    return identity, value
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
    }
    if stats.source == "none" then
        stats.skipped = 1
        return stats
    end

    local get = opts.get or default_get
    local post = opts.post or default_post
    local list_workers = opts.workers or default_workers
    local write = opts.write or default_write
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

    if stats.source == "metrics" then
        local names = _M.metric_key_list(cfg.load_metrics_keys)
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
                end
            end
        end
    elseif stats.source == "prom" then
        local endpoint = _M.query_endpoint(cfg.load_prom_url)
        local template = cfg.load_prom_query
        if not endpoint or type(template) ~= "string" or template == "" then
            stats.skipped = 1
            _M.warn_dedup("prom-config", tostring(cfg.load_prom_url),
                "SMG_LOAD_PROM_URL/SMG_LOAD_PROM_QUERY incomplete", stamp())
            return stats
        end
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
        if _M.query_needs_host(template) then
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
        if not _M.query_endpoint(cfg.load_prom_url)
            or type(cfg.load_prom_query) ~= "string" or cfg.load_prom_query == "" then
            return false, "source=prom needs SMG_LOAD_PROM_URL and SMG_LOAD_PROM_QUERY"
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
