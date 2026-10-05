local cjson = require "cjson.safe"

local _M = require "resty.luarouter.gpu_load"

-- gpu_load/parse.lua -- metric names and numbers, the host identity keys
-- and the exposition parsers: the split_sample character scan, the
-- max-gauge reductions, the 0..1 normalisation, and the absolute-watt
-- channel.  power_watt screens NaN / <=0 / >= MAX_PLAUSIBLE_WATTS and a
-- missing or implausible reading answers nil -- never a guessed number.
-- This is where the missing-reading discipline starts: no usable reading
-- writes no key, the TTL expires the old one back to nil, and the router
-- reads nil as unknown -> do not exclude.  Moved verbatim.

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

return _M
