-- observability.logstore —— 请求日志环形缓冲（lr_request_log 的 head/q:<seq>）+
-- /_ui/logs 查询 DSL + /_ui/logs*、/_ui/stats 的 HTTP handler 与滑窗汇总。
--
-- 与 lr_stats 写侧零共享：只用门面的 cfg()/logdict() 私有把手与滑窗读出
-- read_window()。conf/ui.conf 的 /_ui 块按名字转发这四个 handler（契约面），
-- 所以它们经门面表调用 _M.log_enabled/_M.snapshot/_M.query/_M.stats 等。
local _M = require "resty.luarouter.observability"
local internal = require "resty.luarouter.observability._internal"

local cjson = require "cjson.safe"

local json_encode = cjson.encode
local json_decode = cjson.decode

local cfg = internal.cfg
local logdict = internal.logdict
local read_window = internal.read_window

-- ------------------------------------------------------------------ request log

---Append one RequestRecord to the ring buffer.
---@param record table
---@return number seq
function _M.append_request(record)
    if not _M.log_enabled() then
        record.seq = 0
        return 0
    end
    local d = logdict()
    local seq = d:incr("head", 1, 0) or 0
    record.seq = seq
    local encoded = json_encode(record)
    if encoded then
        d:set("q:" .. seq, encoded)
    end
    local stale = seq - cfg().request_log_capacity
    if stale > 0 then
        d:delete("q:" .. stale)
    end
    return seq
end

---Read records newer than `cursor`, oldest first.
---@param cursor number
---@param limit number
---@return number head, table[] records
function _M.snapshot(cursor, limit)
    local d = logdict()
    local head = d:get("head") or 0
    local capacity = cfg().request_log_capacity
    cursor = tonumber(cursor) or 0
    limit = tonumber(limit) or 500
    if limit < 1 then
        limit = 1
    elseif limit > 2000 then
        limit = 2000
    end
    local start = cursor + 1
    if head - capacity >= start then
        start = head - capacity + 1
    end
    if head - start + 1 > limit then
        start = head - limit + 1
    end
    local out = {}
    for seq = start, head do
        local raw = d:get("q:" .. seq)
        if raw then
            local record = json_decode(raw)
            if type(record) == "table" then
                out[#out + 1] = record
            end
        end
    end
    return head, out
end

function _M.log_capacity()
    return cfg().request_log_capacity
end

---Mirror of the Rust `RequestLogStore::current()` check: capacity 0 means the
---store was never installed, so every /_ui/logs* route reports itself disabled.
---@return boolean
function _M.log_enabled()
    return cfg().request_log_capacity > 0
end

function _M.log_buffered()
    local head = logdict():get("head") or 0
    return math.min(head, cfg().request_log_capacity)
end



-- ------------------------------------------------------------------ query

-- 合法的状态类前缀只认这四档；其余（6xx/1xx…）是拼写错误，必须 400 而不是
-- 悄悄返回空表——「没有匹配」和「参数写错了」要在 HTTP 层就能区分开。
local STATUS_CLASSES = { ["2xx"] = 2, ["3xx"] = 3, ["4xx"] = 4, ["5xx"] = 5 }
-- 布尔过滤的取值集合，全部小写比较。
local TRUTHY = { ["true"] = true, ["1"] = true, ["yes"] = true }
local FALSY = { ["false"] = false, ["0"] = false, ["no"] = false }

---Normalize one raw query value: single non-empty string, or nil, or an error.
---nginx 的 get_args 对重复键会给数组，空串会匹配不上任何记录；两种情况都当参数
---写错处理，而不是静默忽略。
---@param value any
---@param name string @ 报错文案里的参数名
---@return string|nil, string|nil err
local function query_text(value, name)
    if value == nil then
        return nil
    end
    if type(value) == "table" then
        value = value[1]
    end
    if type(value) ~= "string" then
        return nil, name .. " must be a string"
    end
    if value == "" then
        return nil, name .. " must not be empty"
    end
    return value
end

---Strict non-negative integer (rejects "1.5", "10x" and negatives).
---@param value any
---@param name string
---@return integer|nil, string|nil err
local function query_int(value, name)
    if value == nil then
        return nil
    end
    if type(value) == "table" then
        value = value[1]
    end
    if type(value) == "number" then
        if value ~= math.floor(value) or value < 0 then
            return nil, name .. " must be a non-negative integer"
        end
        return value
    end
    if type(value) ~= "string" or not string.match(value, "^%d+$") then
        return nil, name .. " must be a non-negative integer"
    end
    return tonumber(value)
end

local function truthy(value)
    if type(value) ~= "string" then
        return nil
    end
    local key = value:lower()
    if TRUTHY[key] ~= nil then
        return TRUTHY[key]
    end
    if FALSY[key] ~= nil then
        return FALSY[key]
    end
    return nil
end

---Parse and validate the /_ui/logs query into a reusable filter.
---
--- 过滤语义全部是**精确相等**，刻意不做子串匹配：入口名之间有包含关系
--- （glm 是 zai/glm-5.3 的子串），子串匹配会让用户以为过滤坏了。多个条件之间 AND。
---
--- 未知参数一律忽略而不是 400：前端会在同一 URL 上带自己的状态位（自动刷新、
--- 分页控件），网关不认识它们不代表用户写错了。
---
---@param query table|nil @ req.get_query() 的原始值
---@return table|false, string|nil err
---  filter 为 false 表示「没有任何过滤参数」，调用方应当走 snapshot 老路径，
---  这样不带过滤的返回体才能逐字节维持原契约。
function _M.parse_query(query)
    query = query or {}
    local filter = {}
    local found = false

    -- 约定：返回 (true) 继续，返回 (false, err) 中止并向上抛 400 文案。写成
    -- 「返回 err 字符串」会被 if ok then 当成真值继续往下跑，所以显式带 succeed 位。
    local function text_field(name, dest)
        if query[name] == nil then
            return true
        end
        local value, err = query_text(query[name], name)
        if err then
            return false, err
        end
        filter[dest] = value
        found = true
        return true
    end

    -- model 匹配 requested_model 或 model：1 对多之后入口名与实际模型名不同是
    -- 常态，按入口查的人和按实际模型查的人都期望命中。
    local ok, res = text_field("model", "model")
    if ok then
        ok, res = text_field("forwarded_model", "forwarded_model")
    end
    if ok then
        ok, res = text_field("route_type", "route_type")
    end
    if ok then
        ok, res = text_field("session", "session")
    end
    if ok then
        -- worker 的规范化（去 scheme / id 换成 url）由调用方做，这里只保证非空。
        ok, res = text_field("worker", "worker")
    end
    if ok and query.status ~= nil then
        local raw, err = query_text(query.status, "status")
        if err then
            ok, res = false, err
        else
            local cls = STATUS_CLASSES[raw:lower()]
            local exact = tonumber(raw)
            if cls then
                -- 状态类只与记录里的数字状态码比较；与字符串 "4" 比会误命中。
                filter.status_class = cls
            elseif exact and exact == math.floor(exact) and exact >= 100 and exact <= 599 then
                filter.status_exact = exact
            else
                ok, res = false,
                    "status must be an HTTP code (100-599) or one of 2xx/3xx/4xx/5xx"
            end
            found = true
        end
    end
    if ok and query.stream ~= nil then
        local raw, err = query_text(query.stream, "stream")
        if err then
            ok, res = false, err
        else
            local bool = truthy(raw)
            if bool == nil then
                ok, res = false, "stream must be one of true/false/1/0/yes/no"
            else
                filter.stream = bool
            end
            found = true
        end
    end
    if ok and (query.since_ms ~= nil or query.until_ms ~= nil) then
        local since, serr = query_int(query.since_ms, "since_ms")
        local until_ms, uerr = query_int(query.until_ms, "until_ms")
        if serr then
            ok, res = false, serr
        elseif uerr then
            ok, res = false, uerr
        elseif since and until_ms and since > until_ms then
            -- 区间反过来一定是手误：返回空数组会让人以为那段时间没有流量。
            ok, res = false, "since_ms must not be greater than until_ms"
        else
            filter.since_ms = since
            filter.until_ms = until_ms
        end
        found = true
    end

    if not ok then
        return false, res
    end
    if not found then
        return false
    end
    return filter
end

---One record passes only if it satisfies every field present in the filter.
---@param record table
---@param filter table @ as produced by parse_query (worker already normalized)
---@return boolean
local function matches(record, filter)
    if filter.model then
        -- 缺字段解码后是 nil 或 cjson.null（lightuserdata），都不等于字符串，
        -- 所以缺字段的记录天然被过滤掉，不必特判。
        if record.requested_model ~= filter.model and record.model ~= filter.model then
            return false
        end
    end
    if filter.forwarded_model and record.forwarded_model ~= filter.forwarded_model then
        return false
    end
    if filter.worker then
        local url = record.worker or record.selected
        if type(url) ~= "string" then
            return false
        end
        local stripped = string.gsub(url, "^https?://", "")
        if stripped ~= filter.worker then
            return false
        end
    end
    if filter.route_type and record.route_type ~= filter.route_type then
        return false
    end
    if filter.session and record.session ~= filter.session then
        return false
    end
    if filter.stream == true and record.stream ~= true then
        return false
    end
    if filter.stream == false and record.stream == true then
        return false
    end
    local status = tonumber(record.status)
    if filter.status_exact and status ~= filter.status_exact then
        return false
    end
    if filter.status_class
        and (not status or math.floor(status / 100) ~= filter.status_class) then
        return false
    end
    local ts = tonumber(record.ts_ms)
    if filter.since_ms and (not ts or ts < filter.since_ms) then
        return false
    end
    if filter.until_ms and (not ts or ts > filter.until_ms) then
        return false
    end
    return true
end

---Filtered, paginated read of the ring buffer: filter **before** the limit.
---
--- 与 snapshot 的关键差别是顺序：先扫完整个游标区间、把命中计数做全，再按 limit
--- 截取。先截断再过滤的话，一页 500 条里过滤掉 490 条，页面就缩成一排空行，而计
--- 数还会谎报「还有下一页」。所以 total_matched 必须是整段扫描的结论。
---
--- 游标语义与 snapshot 一致：从 cursor+1 起向 head 取，最旧优先；被环形缓冲覆盖的
--- 部分直接当作不存在，earliest_seq 反映真实保留范围。
---
---@param filter table @ as produced by parse_query
---@param cursor number
---@param limit number
---@return table doc @ {cursor, capacity, requests, returned, total_matched,
---  earliest_seq, latest_seq, truncated_buffer, truncated_page, next_cursor}
function _M.query(filter, cursor, limit)
    local d = logdict()
    local head = d:get("head") or 0
    local capacity = cfg().request_log_capacity
    cursor = tonumber(cursor) or 0
    if cursor < 0 then
        cursor = 0
    end
    limit = tonumber(limit) or 500
    if limit < 1 then
        limit = 1
    elseif limit > 2000 then
        limit = 2000
    end

    local earliest = math.max(1, head - capacity + 1)
    local start = cursor + 1
    if start < earliest then
        start = earliest
    end

    local doc = {
        cursor = head,
        capacity = capacity,
        requests = {},
        returned = 0,
        total_matched = 0,
        earliest_seq = earliest,
        latest_seq = head,
        -- 写入量超过容量 = 有比 earliest_seq 更早的行被覆盖掉过。
        truncated_buffer = head > capacity,
        truncated_page = false,
        -- 翻页游标：把它原样当 cursor 传回来就是「下一页」。只有 truncated_page
        -- 为真时才有意义，但缺了它，前端拿到「还有下一页」也无处可去。
        next_cursor = start - 1,
    }
    if start > head then
        -- 游标越过保留区（缓冲被覆盖，或 head 仍是 0）：保留区塌成空，避免 UI 画出
        -- earliest > latest 这种反着的区间；next_cursor 保持调用方给的游标，
        -- 不后退（后退会让无脑循环把同一段重读一遍）。
        doc.earliest_seq = head
        doc.next_cursor = cursor
        doc.requests = {}
        return doc
    end

    -- 扫描区间 = min(游标之后, 环形缓冲保留量)，上界就是 LMR_REQUEST_LOG_CAPACITY
    -- （缺省 1000，config.lua clamp 到 >=0），所以成本与峰值内存按容量线性，而不是
    -- 按匹配数。每行只 get + decode 一次并把解码结果复用给响应体，因此峰值内存
    -- 约为「区间内全部匹配行的 Lua 表」+「一次整体 JSON 编码出的响应字符串」。
    for seq = start, head do
        local raw = d:get("q:" .. seq)
        if raw then
            local record = json_decode(raw)
            if type(record) == "table" and matches(record, filter) then
                doc.total_matched = doc.total_matched + 1
                if doc.returned < limit then
                    doc.returned = doc.returned + 1
                    doc.requests[doc.returned] = record
                    doc.next_cursor = seq
                else
                    -- 命中数已经越过本页页长：后面还有，前端据 next_cursor 续问。
                    doc.truncated_page = true
                end
            end
        end
    end
    if doc.returned == 0 then
        doc.requests = cjson.empty_array
    end
    return doc
end



-- ------------------------------------------------------------------ _ui/stats

---Sliding-window counters for the logs page summary strip.
---@return table
function _M.stats()
    local conf = cfg()
    local window_s = conf.stats_window_s or 10
    local sample = read_window(window_s)
    local elapsed_s = math.max(1, (sample.buckets * 200)) / 1000
    local function rate(value)
        return value / elapsed_s
    end
    local function average(sum, count)
        if count <= 0 then
            return cjson.null
        end
        return sum / count
    end
    local requests = logdict():get("head") or 0
    return {
        inflight = _M.inflight(),
        uptime_s = ngx.now() - conf.started_at_ms / 1000,
        requests_total = requests,
        output_tok_s = rate(sample.out_tok),
        input_tok_s = rate(sample.in_tok),
        window_s = elapsed_s,
        requests_window = sample.req,
        errors_window = sample.err,
        avg_ttft_ms = average(sample.ttft_ms, sample.ttft_n),
        avg_duration_ms = average(sample.dur_ms, sample.dur_n),
        tokens_estimated_share = sample.req > 0 and (sample.est / sample.req) or 0,
        price_in_per_mtok = conf.price_in_per_mtok or cjson.null,
        price_out_per_mtok = conf.price_out_per_mtok or cjson.null,
        capacity = conf.request_log_capacity,
        buffered = _M.log_buffered(),
        started_at_ms = conf.started_at_ms,
    }
end

-- ------------------------------------------------------- /_ui HTTP entrypoints
--
-- ui.conf forwards /_ui/logs, /_ui/logs/stream, /_ui/logs/backends and
-- /_ui/stats here by name (see the _ui stats contract), so these
-- names are the bridge contract. The router registers the same handlers on its
-- own route table, which means both entry points behave identically.

local function respond_json(status, payload)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json; charset=UTF-8"
    local encoded = json_encode(payload)
    if encoded then
        ngx.print(encoded)
    end
    return ""
end

---Rust request_log_disabled(): the store is off, so say so instead of an empty
---200 that the UI would render as "no requests".
local function log_disabled()
    return respond_json(ngx.HTTP_SERVICE_UNAVAILABLE,
        { error = "request log not enabled" })
end

--- GET /_ui/logs?cursor=&limit=
function _M.handle_logs()
    if not _M.log_enabled() then
        return log_disabled()
    end
    local query = ngx.req.get_uri_args()
    local filter, bad_param, bad_msg = _M.parse_query(query)
    if bad_param then
        return respond_json(ngx.HTTP_BAD_REQUEST, {
            error = bad_param .. ": " .. tostring(bad_msg),
        })
    end
    if filter then
        local doc = _M.query(filter, query.cursor, query.limit)
        if type(doc.requests) ~= "table" or #doc.requests == 0 then
            doc.requests = cjson.empty_array
        end
        return respond_json(ngx.HTTP_OK, doc)
    end
    local cursor = tonumber(query.cursor) or 0
    local limit = tonumber(query.limit) or 500
    local head, requests = _M.snapshot(cursor, limit)
    if #requests == 0 then
        requests = cjson.empty_array
    end
    return respond_json(ngx.HTTP_OK, {
        cursor = head,
        capacity = _M.log_capacity(),
        requests = requests,
    })
end

--- GET /_ui/stats
function _M.handle_stats()
    if not _M.log_enabled() then
        return log_disabled()
    end
    return respond_json(ngx.HTTP_OK, _M.stats())
end

--- GET /_ui/logs/backends - provider column on the Logs page.
function _M.handle_backends()
    if not _M.log_enabled() then
        return log_disabled()
    end
    local registry = require "resty.luarouter.registry"
    local out = {}
    local records = registry.records()
    for i = 1, #records do
        local gpu = (type(records[i].labels) == "table"
            and records[i].labels.gpu) or cjson.null
        out[#out + 1] = {
            url = records[i].url,
            model = records[i].model_id,
            gpu = gpu,
        }
    end
    if #out == 0 then
        out = cjson.empty_array
    end
    return respond_json(ngx.HTTP_OK, { backends = out })
end

--- GET /_ui/logs/stream - SSE fan-out of finished requests with a 15s ping,
--- matching the Rust keep_alive interval.
---
--- Rust pushes through a tokio broadcast channel; there is no cross-worker
--- channel here, so the stream polls the shared ring buffer by sequence number.
--- The buffer lives in lr_request_log, which every worker writes, so a follower
--- still sees requests served by other processes. A client that falls behind
--- jumps forward (the Rust stream drops frames the same way and lets the browser
--- re-sync with a cursor poll).
function _M.handle_logs_stream()
    if not _M.log_enabled() then
        return log_disabled()
    end
    local d = logdict()
    ngx.status = ngx.HTTP_OK
    ngx.header["Content-Type"] = "text/event-stream"
    ngx.header["Cache-Control"] = "no-cache"
    ngx.header["X-Accel-Buffering"] = "no"
    ngx.flush(true)

    local cursor = d:get("head") or 0
    local capacity = _M.log_capacity()
    local PING_S = 15
    local POLL_S = 0.5
    local since_ping = 0

    while true do
        local head = d:get("head") or 0
        if head - capacity > cursor then
            -- Fell behind the ring: skip to the oldest retained record.
            cursor = head - capacity
        end
        while cursor < head do
            cursor = cursor + 1
            local raw = d:get("q:" .. cursor)
            if raw then
                local ok = pcall(ngx.print, "data: " .. raw .. "\n\n")
                if not ok then
                    return ngx.exit(ngx.HTTP_OK)
                end
            end
        end
        since_ping = since_ping + POLL_S
        if since_ping >= PING_S then
            since_ping = 0
            local ok = pcall(ngx.print, ": ping\n\n")
            if not ok then
                return ngx.exit(ngx.HTTP_OK)
            end
        end
        if not pcall(ngx.flush, true) then
            return ngx.exit(ngx.HTTP_OK)
        end
        if not pcall(ngx.sleep, POLL_S) then
            return ngx.exit(ngx.HTTP_OK)
        end
    end
end

return { priv = {} }
