-- metrics 聚合渲染（自 router.lua 逐字搬来，只调整了 require 接线）。
--
-- P25 Prometheus 移植：exposition 解析 / 合并 / 渲染 + /engine_metrics +
-- /model_info。load-safe：无 ngx 请求态也能 require 与调用（docker-entrypoint 的
-- 独立 metrics 进程按这个纪律直调 router facade 的 metrics_handler）。
local cjson = require "cjson.safe"

local hb = require "resty.luarouter.hb"
local registry = require "resty.luarouter.registry"

local host = require "resty.luarouter.router.host"
local inference = require "resty.luarouter.router.inference"

local _M = {}
package.loaded["resty.luarouter.router.metrics_ep"] = _M

local json_decode = cjson.decode
local cfg = host.cfg
-- 公开面的纯文本应答（router/inference.lua）。
local text_response = inference.text_response
-- ------------------------------------------------------------------ metrics
--
-- Prometheus text aggregation, ported from core/metrics_aggregator.rs.
--
-- Rust parses each worker's /metrics with openmetrics-parser, stamps every family
-- with the extra label worker_addr (the full worker url), merges the expositions
-- family by family, and re-renders the result. Doing it in Lua the same way is
-- what makes the endpoint scrapable at all: the old implementation concatenated
-- the per-worker bodies under a "# worker <url>" comment, so the same name
-- appeared with two "# HELP" / "# TYPE" lines, which a Prometheus scraper rejects.

---openmetrics-parser rejects colons in metric names, so Rust rewrites the whole
---text before parsing (metrics_aggregator.rs:20). It is a blanket replace and
---therefore touches label values and help text too; only labels added after
---parsing keep their colons, which is why worker_addr still reads http://host:port.
---Ported literally, quirks included.
---@param text string
---@return string
local function underscore_colons(text)
    return (string.gsub(text, ":", "_"))
end

---Scan a label list `a="1",b="x\"y"` starting at the opening brace.
---
---A character loop rather than a pattern because a Prometheus label value may
---contain commas, braces and escaped quotes, which no single pattern handles.
---Returns nil on a malformed list so the caller drops the sample instead of
---corrupting the family.
---@param text string
---@param start number @ index of the "{"
---@return table|nil labels @ {{name, value}, ...}, number|nil next index
local function scan_labels(text, start)
    local labels = {}
    local n = #text
    local pos = start + 1
    while pos <= n do
        local c = text:sub(pos, pos)
        if c == "}" then
            return labels, pos + 1
        end
        if c == "," then
            pos = pos + 1
        end
        local name_start = pos
        local eq = nil
        while pos <= n do
            local ch = text:sub(pos, pos)
            if ch == "=" then
                eq = pos
                break
            end
            if ch == "}" or ch == "," or ch == '"' then
                return nil
            end
            pos = pos + 1
        end
        if not eq then
            return nil
        end
        local name = text:sub(name_start, eq - 1):gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then
            return nil
        end
        pos = eq + 1
        if text:sub(pos, pos) ~= '"' then
            return nil
        end
        pos = pos + 1
        local value = {}
        local closed = false
        while pos <= n do
            local ch = text:sub(pos, pos)
            if ch == "\\" then
                local nxt = text:sub(pos + 1, pos + 1)
                if nxt == "n" then
                    value[#value + 1] = "\n"
                elseif nxt == "\\" then
                    value[#value + 1] = "\\"
                elseif nxt == '"' then
                    value[#value + 1] = '"'
                else
                    value[#value + 1] = nxt
                end
                pos = pos + 2
            elseif ch == '"' then
                pos = pos + 1
                closed = true
                break
            else
                value[#value + 1] = ch
                pos = pos + 1
            end
        end
        if not closed then
            return nil
        end
        labels[#labels + 1] = { name, table.concat(value) }
        if pos > n then
            return nil
        end
        if text:sub(pos, pos) == "}" then
            return labels, pos + 1
        end
    end
    return nil
end

-- Suffixes that belong to a histogram/summary family rather than to a metric of
-- their own, and the label the parser treats as part of the sample rather than of
-- the family (openmetrics-parser PrometheusType::get_ignored_labels plus the
-- summary/histogram handlers in prometheus/parsers.rs).
local SAMPLE_SUFFIXES = { "bucket", "count", "sum", "max", "min" }
local VALUE_RE = "^[-+0-9.eE]+$"

---Parse one Prometheus exposition into families.
---
---Family identity follows the declared type where one exists: SGLang writes
---"# TYPE sglang_x histogram" and then samples named sglang_x_bucket/_count/_sum,
---and those have to land in one family rather than three. Sample lines keep their
---own name, label list and value text verbatim, so nothing is re-formatted and a
---histogram stays a histogram on the wire.
---@param text string @ already colon-underscored
---@return table families @ name -> {name, help, type, samples}
---@return string[] order @ first-appearance order
local function parse_prometheus(text)
    local families = {}
    local order = {}
    local declared = {}

    local function family(name)
        local f = families[name]
        if not f then
            f = { name = name, samples = {} }
            families[name] = f
            order[#order + 1] = name
        end
        return f
    end

    for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
        local line = raw
        if line:sub(-1) == "\r" then
            line = line:sub(1, -2)
        end
        if line ~= "" and line:sub(1, 1) == "#" then
            local kind, name, rest = string.match(line,
                "^#%s+(%a+)%s+([%w_]+)%s*(.*)$")
            if kind and name then
                local upper = string.upper(kind)
                if upper == "HELP" or upper == "TYPE" then
                    local f = family(name)
                    declared[name] = true
                    if upper == "HELP" then
                        if f.help == nil then
                            f.help = rest
                        end
                    elseif f.type == nil then
                        f.type = rest
                    end
                end
            end
        elseif line ~= "" then
            local name, after = string.match(line, "^([%w_]+)(.*)$")
            if name then
                local labels = {}
                local tail = after
                if after:sub(1, 1) == "{" then
                    local scanned, next_pos = scan_labels(after, 1)
                    if not scanned then
                        goto continue
                    end
                    labels = scanned
                    tail = after:sub(next_pos or (#after + 1))
                end
                tail = tail:gsub("^%s+", ""):gsub("%s+$", "")
                -- Value or timestamp+value; the first field decides whether the line
                -- is a sample at all.
                local value = string.match(tail, "^(%S+)")
                if not value or not string.match(value, VALUE_RE) then
                    goto continue
                end
                -- A suffixed sample folds into the family that declared the base
                -- name; anything else keeps its own family (a TYPE-less scrape).
                local fname = name
                if not declared[name] then
                    for base in pairs(declared) do
                        if name ~= base and name:sub(1, #base + 1) == base .. "_" then
                            local suffix = name:sub(#base + 2)
                            for i = 1, #SAMPLE_SUFFIXES do
                                if SAMPLE_SUFFIXES[i] == suffix then
                                    fname = base
                                    break
                                end
                            end
                        end
                        if fname ~= name then
                            break
                        end
                    end
                end
                local f = family(fname)
                f.samples[#f.samples + 1] = {
                    name = name,
                    labels = labels,
                    tail = tail,
                }
            end
            ::continue::
        end
    end
    return families, order
end

---Position Rust's with_labels() gives an extra label: binary_search over the
---sample's label names (openmetrics-parser public/model.rs:105-125). Rust searches
---a list that is only sorted when the source happens to sort it, so the insert
---position has to come from the same algorithm rather than from a sorted insert.
---@param names string[]
---@param key string
---@return number @ 1-based insert position
local function label_insert_index(names, key)
    local lo, hi = 1, #names + 1
    while lo < hi do
        local mid = lo + math.floor((hi - lo) / 2)
        if names[mid] < key then
            lo = mid + 1
        else
            hi = mid
        end
    end
    return lo
end

---Render one sample with the aggregator's extra label folded in. Values are
---escaped for the wire (the only two characters that would break the line).
local function render_sample(sample, extra_name, extra_value)
    local labels = sample.labels
    local names = {}
    for i = 1, #labels do
        names[i] = labels[i][1]
    end
    local insert_at = label_insert_index(names, extra_name)
    local parts = {}
    local placed = false
    for i = 1, #labels do
        if not placed and i >= insert_at then
            parts[#parts + 1] = extra_name .. '="' .. extra_value .. '"'
            placed = true
        end
        local value = labels[i][2]:gsub("\\", "\\\\"):gsub('"', '\\"')
        parts[#parts + 1] = labels[i][1] .. '="' .. value .. '"'
    end
    if not placed then
        parts[#parts + 1] = extra_name .. '="' .. extra_value .. '"'
    end
    local text = sample.name
    if #parts > 0 then
        text = text .. "{" .. table.concat(parts, ",") .. "}"
    end
    return text .. " " .. sample.tail
end

---Merge one pack's families into the accumulator, stamping each sample with the
---pack's worker address (Rust stamps the family before merging, so a sample never
---travels without it).
local function merge_pack(acc, acc_order, families, order, label_value)
    for i = 1, #order do
        local name = order[i]
        local incoming = families[name]
        local target = acc[name]
        if not target then
            acc[name] = { name = name, help = incoming.help, type = incoming.type,
                samples = {} }
            acc_order[#acc_order + 1] = name
            target = acc[name]
        end
        if target.help == nil and incoming.help then
            target.help = incoming.help
        end
        if target.type == nil and incoming.type then
            target.type = incoming.type
        end
        for j = 1, #incoming.samples do
            target.samples[#target.samples + 1] = incoming.samples[j]
        end
        -- The stamp travels with the sample list, not the family, because two packs
        -- carry different addresses: keep the address alongside the samples.
        target.pack = target.pack or {}
        target.pack[#target.pack + 1] = {
            label_value = label_value,
            count = #incoming.samples,
            first = #target.samples - #incoming.samples + 1,
        }
    end
end

---Render the merged exposition: one HELP and one TYPE line per family, each sample
---carrying the worker_addr of the pack it came from, families separated by a blank
---line as Rust's Display for MetricsExposition does (model.rs:315-330).
---@param acc table
---@param acc_order string[]
---@return string
local function render_exposition(acc, acc_order)
    local blocks = {}
    for i = 1, #acc_order do
        local f = acc[acc_order[i]]
        local lines = {}
        if f.help and f.help ~= "" then
            lines[#lines + 1] = "# HELP " .. f.name .. " " .. f.help
        end
        if f.type and f.type ~= "" and f.type ~= "unknown" then
            lines[#lines + 1] = "# TYPE " .. f.name .. " " .. f.type
        end
        local stamps = {}
        for p = 1, #(f.pack or {}) do
            local entry = f.pack[p]
            for s = entry.first, entry.first + entry.count - 1 do
                stamps[s] = entry.label_value
            end
        end
        for s = 1, #f.samples do
            lines[#lines + 1] = render_sample(f.samples[s], "worker_addr",
                stamps[s] or "")
        end
        blocks[#blocks + 1] = table.concat(lines, "\n")
    end
    return table.concat(blocks, "\n\n")
end

_M.underscore_colons = underscore_colons
_M.merge_pack = merge_pack
_M.parse_prometheus = parse_prometheus
_M.render_exposition = render_exposition
_M.label_insert_index = label_insert_index

---Fan out a GET to every worker, returning the raw per-worker results.
local function fan_out_get(path, timeout_ms)
    local records = registry.records()
    local out = {}
    for i = 1, #records do
        local status, body = hb.http_get(records[i].url .. path, timeout_ms)
        out[#out + 1] = { worker = records[i].url, status = status or 0, body = body }
    end
    return out
end



---GET /engine_metrics - the workers' Prometheus text, aggregated.
---
---Rust's two error branches are part of the contract (core/worker_manager.rs
---get_engine_metrics plus its IntoResponse): no workers at all and every scrape
---failing both answer 500 with a plain-text reason, never an empty 200. The scrape
---timeout is reqwest's fixed 5s per worker (worker_manager.rs:25 REQUEST_TIMEOUT),
---not health_check_timeout_secs, and a worker's api_key is presented as a bearer
---token exactly as fan_out does.
local function engine_metrics_handler()
    local records = registry.records()
    if #records == 0 then
        return text_response(500, "No available workers")
    end

    local merged, merged_order = {}, {}
    local packs = 0
    for i = 1, #records do
        local record = records[i]
        local headers
        if record.api_key then
            headers = { Authorization = "Bearer " .. record.api_key }
        end
        local status, body = hb.http_get(record.url .. "/metrics", 5000, headers)
        if status and status >= 200 and status < 300 and body and body ~= "" then
            local families, order = parse_prometheus(underscore_colons(body))
            packs = packs + 1
            merge_pack(merged, merged_order, families, order, record.url)
        end
    end

    if packs == 0 then
        return text_response(500, "All backend requests failed")
    end
    return text_response(200, render_exposition(merged, merged_order),
        "text/plain; version=0.0.4; charset=utf-8")
end

local function model_info_handler()
    local merged = {}
    local results = fan_out_get("/model_info", cfg().health_check_timeout_secs * 1000)
    local merged_count = 0
    for i = 1, #results do
        if results[i].status == 200 then
            local decoded = json_decode(results[i].body)
            if type(decoded) == "table" then
                merged_count = merged_count + 1
                merged[merged_count] = decoded
            end
        end
    end
    if merged_count == 0 then
        merged = cjson.empty_array
    end
    return { model_infos = merged }
end
-- 跨模块接线（拆分新增；文末；原处 underscore_colons / merge_pack /
-- parse_prometheus / render_exposition / label_insert_index 的就近导出留在上面
-- 原样，赋的是本模块 _M）。
_M.fan_out_get = fan_out_get
_M.engine_metrics_handler = engine_metrics_handler
_M.model_info_handler = model_info_handler
return _M
