local cjson = require "cjson.safe"

local _M = require "resty.luarouter.gpu_load"

-- gpu_load/parse.lua -- metric names and numbers, the host identity keys
-- and the exposition parsers: the split_sample character scan, the
-- max-gauge reductions, the 0..1 normalisation, and the GPU-utilisation
-- channel.  util_fraction screens NaN / negative / implausible readings and a
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

-- 利用率通道（doc/caps-redesign-2026-10-06.md §5）的 gauge 名册。它与上面的**负载**名册
-- 是两份，且刻意不包含两个 KV-cache 用量名：KV cache 占用率量的是「引擎装了多少 token」，
-- 不是「卡有多忙」，把它喂给 GPU 利用率上限判定 = 一个把缓存塞满但卡闲着的引擎被当成满载
-- 摘出候选集。准入判据只认 GPU 利用率这一族。
--   * dcgm_fi_dev_gpu_util   21.k 上的**真名**：dcgm-exporter :9400 写的是
--       DCGM_FI_DEV_GPU_UTIL{gpu="0",...,Hostname="gpu-pro6000-1"} 0（样本
--       /data/tmp/dcgm-metrics-9400.txt，测绘 lr-map-gpuload-2026.md §3.1）。这条是本轮
--       新增：名册里原来只有 dcgm_gpu_utilization，那是另一个 exporter 的写法，与 DCGM 的
--       真名对不上，所以 21.k 上「用 metrics 路取利用率」其实一直没生效，生产读数全靠 prom
--       路那条 SMG_LOAD_PROM_QUERY。旧写法保留——别的数据源还在用它。
--   * nvidia_gpu_utilization / dcgm_gpu_utilization  其余 exporter 的同量纲写法（0..100）。
-- 量纲两种都有（DCGM/nvidia 是 0..100 百分数），所以读数一律过 util_fraction()，
-- 不复用 normalize() 那条「>1 就当百分数」的启发式——理由见该函数上方。
local DEFAULT_UTIL_METRIC_KEYS = {
    "dcgm_fi_dev_gpu_util",
    "nvidia_gpu_utilization",
    "dcgm_gpu_utilization",
}
_M.DEFAULT_UTIL_METRIC_KEYS = DEFAULT_UTIL_METRIC_KEYS

-- prom 路利用率查询的缺省 PromQL（SMG_LOAD_UTIL_QUERY 缺省值）。它是**唯一权威**的一份
-- 字面量：config.lua 装配 + cards.util_config() 的回落都指向这里，两处不再各抄一遍。
-- gpu 必须留在 by 里（lr-map-gpuload-2026.md §2.2）：把它聚合掉 = 21.k 八台 worker
-- 共用一个数（342.371）的复刻，逐卡归属当天就退化回整机 max。
-- Hostname 与 instance 也都留在 by 里：cards.lua 的 util_fold 靠这两个标签在「一台
-- Prometheus 抓了多台机器的本机 exporter」时识破归属冲突，而本机 worker 全
-- 注册成 http://127.0.0.1:80xx，只有 exporter 的抓取地址能把读数交回本机。
local DEFAULT_UTIL_QUERY = "max by (Hostname,instance,gpu) (DCGM_FI_DEV_GPU_UTIL)"
_M.DEFAULT_UTIL_QUERY = DEFAULT_UTIL_QUERY

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
    -- per-card utilisation channel reads gpu="6" from (the first return drops
    -- the braces, and the max-gauge readers never wanted them). Existing
    -- callers take two values, so this is additive.
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

------------------------------------------------------------- util (0..1 busy)

-- 一个还能被当成「单卡 GPU 利用率」的原始读数上限（百分数量纲）。DCGM 的
-- DCGM_FI_DEV_GPU_UTIL 定义域是 0..100（'# HELP ... GPU utilization (in %).'），
-- 驱动舍入到 105 仍算满载；而 1000 以上的读数几乎只会是被误配进名册的**计数器**
-- （运行时长、能量焦耳、token 累计……），那种数字喂给利用率上限判定，会让这一路
-- worker 永久高于任何 0..100 的上限而整个从候选集消失——一个配错的 gauge 名单独
-- 干掉一个实例，与负载那一路的名册筛的是同一类事故。宁可回「未知」。
local MAX_PLAUSIBLE_UTIL_PERCENT = 1000
_M.MAX_PLAUSIBLE_UTIL_PERCENT = MAX_PLAUSIBLE_UTIL_PERCENT

---Usable single-GPU **utilization** reading normalized to 0..1, or nil.
---
---利用率是准入门（registry 的 gu: 键 -> capacity_state/capacity_exclusion）的读数，
---所以它不复用 normalize() 那条「>1 就当百分数、越界一律夹到 1」的打分启发式——
---lr-map-gpuload-2026.md §3.2 点名的缺口就在这一条：作为打分可以，作为准入太软。
---本函数的口径（doc/caps-redesign-2026-10-06.md §5 钉死）：
---  * 非数 / NaN / ±inf：同 parse_number() 的口径，nil。
---  * **负数 -> nil**（绝不夹到 0）：0 % 是合法读数（21.k 的 dcgm 空载就报
---    DCGM_FI_DEV_GPU_UTIL{gpu="0"} 0），而负数是坏 exporter；夹成 0 等于给一台
---    撒谎的 exporter 发免检牌——它永远「远低于任何上限」。坏读数一律当未知，
---    绝不夹成一个看起来安全的数。
---  * 0..1（含端点）：按分数收。恰好 1 = 满载（与 normalize() 对负载的口径一致，
---    xl: 与 gu: 两把键对「1」必须同义，否则同一个 exporter 在打分与准入两路读出
---    两种世界）。百分数量纲里 1 % 的真读数被当满载是**过判**——过判只会少用一台
---    worker（还能被 per_card/fallback 计数与日志看见），漏判会让满载卡继续接活，
---    两害相权取过判。
---  * 1..MAX_PLAUSIBLE_UTIL_PERCENT：按百分数收，/100 后夹到 1（105 % 仍是满载）。
---  * 超出上限：nil（未知 -> 不排除），理由见 MAX_PLAUSIBLE_UTIL_PERCENT 上方。
---@param value number|string|nil
---@return number|nil util @ normalized 0..1
function _M.util_fraction(value)
    local number = _M.parse_number(value)
    if number == nil or number < 0 then
        return nil
    end
    if number <= 1 then
        return number
    end
    if number > MAX_PLAUSIBLE_UTIL_PERCENT then
        return nil
    end
    local util = number / 100
    if util > 1 then
        util = 1
    end
    return util
end

---Per-card **utilization** readings for one /metrics exposition (the metrics
---path's util scan).
---
---一次正文扫出两路归约（whole = 整机最热卡，by_card[gpu] = 该卡）。筛子是
---util_fraction()：合法的 0 必须保留（DCGM 空载就报 0 %，那是「远低于任何上限」
---的诚实读数，不能当成缺数拒掉），名册默认 DEFAULT_UTIL_METRIC_KEYS（不含
---KV-cache 用量名）。gpu 标签只认纯数字（"0".."7"）。
---@param text string|nil @ the exposition body
---@param names table[]|string|nil @ gauge names to keep (default DEFAULT_UTIL_METRIC_KEYS)
---@return number|nil whole @ hottest card on the machine, 0..1
---@return table @ by_card @ gpu id -> 0..1
---@return boolean @ have_cards @ any usable series named a card
function _M.util_by_card(text, names)
    local whole, by_card, have_cards = nil, {}, false
    if type(text) ~= "string" or text == "" then
        return whole, by_card, have_cards
    end
    local wanted = {}
    local list = _M.metric_key_list(names)
    if #list == 0 then
        list = _M.metric_key_list(DEFAULT_UTIL_METRIC_KEYS)
    end
    for i = 1, #list do
        wanted[list[i]] = true
    end
    for line in string.gmatch(text, "[^\r\n]+") do
        if string.byte(line, 1) ~= 35 then
            local identity, value_text, labelled = split_sample(line)
            local name = canon(identity)
            if name and wanted[name] then
                local util = _M.util_fraction(value_text)
                if util then
                    if whole == nil or util > whole then
                        whole = util
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
                        if by_card[gpu] == nil or util > by_card[gpu] then
                            by_card[gpu] = util
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
---per-card utilisation channel needs gpu="6", so the name is returned together with the
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
