#!/usr/bin/env luajit
-- otel.lua 纯逻辑单测（W3C 上下文、端点归一化、OTLP/JSON 编码、批量与丢弃计数）。
--   运行（cwd 取 lua-router/）：
--   docker run --rm -v "$PWD/lua-router:/r:ro" -w /r authz:latest \
--     /usr/local/openresty/luajit/bin/luajit test/unit/test_otel.lua
--
-- 一个最小 ngx 替身就够：configure / begin / finish / encode_request 只用到
-- ngx.now、ngx.ctx、ngx.status、ngx.var、ngx.req、ngx.header、ngx.log；导出路径通过
-- otel.set_exporter 换成记录器，因此不需要 cosocket，也不需要真容器。
local root = os.getenv("LUA_TEST_LIB") or "./lualib"
package.path = root .. "/?.lua;" .. package.path

local passed, failed = 0, 0
local failures = {}

local function check(cond, name, detail)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = name .. (detail and (" -> " .. tostring(detail)) or "")
    end
end

local function eq(actual, expect, name)
    check(actual == expect, name,
        actual ~= expect and ("got " .. tostring(actual) .. " want " .. tostring(expect)) or nil)
end

local function new_case(name)
    io.write("  case: " .. name .. "\n")
end

--------------------------------------------------------------------------
-- ngx 替身
--------------------------------------------------------------------------
local NOW = 1700000000.5
local fake = {
    ctx = {},
    status = 200,
    header = {},
    var = { uri = "/v1/chat/completions", request_uri = "/v1/chat/completions" },
    now = function() return NOW end,
    log = function() end,
    sleep = function() end,
    req = { get_method = function() return "POST" end, get_headers = function() return {} end },
    timer = { at = function() return false, "no timers in a probe" end },
    worker = { pid = function() return 4242 end },
    shared = {},
}
_G.ngx = fake

local cjson = require "cjson.safe"
local otel = require "resty.luarouter.otel"

---Reset the per-request state the way nginx would between requests.
local function fresh_request(headers)
    fake.ctx = {}
    fake.status = 200
    fake.header = {}
    fake.req.get_headers = function() return headers or {} end
end

--------------------------------------------------------------------------
new_case("endpoint parsing")
eq(otel.DEFAULT_ENDPOINT, "http://127.0.0.1:4318/v1/traces", "默认端点是 OTLP/HTTP 4318")
local t = otel.parse_endpoint("http://collector:4318/v1/traces")
check(t and t.host == "collector" and t.port == 4318 and t.path == "/v1/traces"
    and t.tls == false, "完整 http URL", t and (t.host .. ":" .. t.port))
t = otel.parse_endpoint("https://collector:4319")
check(t and t.tls == true and t.port == 4319 and t.path == "/v1/traces",
    "https host:port 用默认路径", t and tostring(t.tls))
t = otel.parse_endpoint("localhost:4317")
check(t and t.host == "localhost" and t.port == 4317 and t.tls == false,
    "Rust 的 host:port 写法被接受", t and (t.host .. ":" .. tostring(t.port)))
t = otel.parse_endpoint("http://[::1]:4318/v1/traces")
check(t and t.host == "::1" and t.port == 4318, "IPv6 字面量", t and tostring(t.host))
t = otel.parse_endpoint("http://host.example/otlp/v1/traces")
check(t and t.path == "/otlp/v1/traces", "反代前缀路径被保留", t and t.path)
local _, reason = otel.parse_endpoint("http://:4318")
check(reason == "host part cannot be empty", "空 host 报出 Rust 的措辞", reason)
_, reason = otel.parse_endpoint("collector:0")
check(reason and reason:find("host>:<port", 1, true), "端口越界给出格式提示", reason)
_, reason = otel.parse_endpoint("collector")
check(reason ~= nil, "无端口且无 scheme 时拒绝", reason)
_, reason = otel.parse_endpoint("ftp://host:21")
check(reason and reason:find("unsupported scheme"), "未知协议被拒绝", reason)
_, reason = otel.parse_endpoint("")
check(reason == "empty endpoint", "空串视为未配置", reason)

--------------------------------------------------------------------------
new_case("configure")
otel.configure({})
local conf = otel.config()
eq(conf.enabled, false, "SMG_ENABLE_TRACE 未设置即关闭")
eq(conf.normalized, "http://127.0.0.1:4318/v1/traces", "未设置端点时归一化到默认值")
eq(conf.batch_size, 64, "批量大小默认 64（Rust max_export_batch_size）")
eq(conf.interval_ms, 500, "批量间隔默认 500ms（Rust scheduled_delay）")
eq(conf.sample_ratio, 1.0, "采样率默认 1（Rust parentbased_always_on）")
otel.configure({ enable = "yes", endpoint = "collector:4317", batch_size = "3",
                 interval_ms = "10", timeout_ms = "50", sample_ratio = "0.5" })
conf = otel.config()
eq(conf.enabled, true, "yes 打开追踪")
eq(conf.normalized, "http://collector:4317/v1/traces", "host:port 归一化成 http URL")
eq(conf.batch_size, 3, "batch_size 生效")
eq(conf.max_queue, 256, "max_queue 不小于 256 的下界")
check(otel.transport_warning(conf) ~= nil, "指向 4317 时给出 gRPC 提示")
otel.configure({ enable = "1", endpoint = "http://127.0.0.1:4318/v1/traces" })
check(otel.transport_warning() == nil, "正常 4318 端点无警告")
otel.configure({ enable = "1", endpoint = "collector:0" })
eq(otel.config().enabled, false, "端点不可用时追踪自行关闭")
eq(otel.config().invalid_reason, "expected format <host>:<port>, e.g. otel-collector:4318",
    "不可用原因被记录")
otel.configure({ enable = "1", sample_ratio = "5" })
eq(otel.config().sample_ratio, 1, "采样率上界钳到 1")
otel.configure({ enable = "1", sample_ratio = "-1" })
eq(otel.config().sample_ratio, 0, "采样率下界钳到 0")

--------------------------------------------------------------------------
new_case("traceparent parsing")
local ctx = otel.parse_traceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
check(ctx and ctx.trace_id == "0af7651916cd43dd8448eb211c80319c"
    and ctx.span_id == "b7ad6b7169203331" and ctx.sampled == true, "合法 traceparent")
ctx = otel.parse_traceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00")
check(ctx and ctx.sampled == false, "flags 位决定 sampled")
ctx = otel.parse_traceparent("02-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01-extra")
check(ctx ~= nil and ctx.version == "02", "更高版本带额外字段仍被接受")
eq(otel.parse_traceparent("ff-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"), nil,
    "版本 ff 无效")
eq(otel.parse_traceparent("00-00000000000000000000000000000000-b7ad6b7169203331-01"), nil,
    "全零 trace id 无效")
eq(otel.parse_traceparent("00-0af7651916cd43dd8448eb211c80319c-0000000000000000-01"), nil,
    "全零 parent id 无效")
eq(otel.parse_traceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b716920-01"), nil,
    "span id 长度不足无效")
eq(otel.parse_traceparent("00-trace-span-01"), nil, "契约测试里的占位值不被当上下文")
eq(otel.parse_traceparent(nil), nil, "缺失即无上下文")
eq(otel.render_traceparent({ trace_id = "a", span_id = "b", flags = "01" }), "00-a-b-01",
    "渲染固定 version=00")

--------------------------------------------------------------------------
new_case("begin / inject / finish")
otel.reset_stats()
otel.configure({ enable = "1", endpoint = "http://127.0.0.1:4318/v1/traces",
                 sample_ratio = 1, batch_size = 64, interval_ms = 500 })
fresh_request({ ["traceparent"] = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" })
local trace = otel.begin()
check(trace ~= nil, "继承上下文时建 span")
eq(trace.trace_id, "0af7651916cd43dd8448eb211c80319c", "trace id 继承上游")
eq(trace.parent_span_id, "b7ad6b7169203331", "上游 span id 成为 parent")
check(trace.span_id ~= trace.parent_span_id and #trace.span_id == 16,
    "自身 span id 是新造的 16 位 hex")
eq(trace.sampled, true, "上游采样决策被继承")
eq(trace.source, "inherited", "来源标记为继承")
local headers = otel.inject({ ["traceparent"] = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
                              ["tracestate"] = "k=v" })
eq(headers["traceparent"], "00-0af7651916cd43dd8448eb211c80319c-" .. trace.span_id .. "-01",
    "注入覆盖为自身 span（Rust insert 语义）")
eq(headers["tracestate"], "k=v", "tracestate 原样保留")

fresh_request({})
trace = otel.begin()
check(trace ~= nil and #trace.trace_id == 32 and trace.is_root, "无 traceparent 时生成根上下文")
check(trace.parent_span_id == nil, "自建的根上下文没有 parent_span_id")
eq(#otel.render_traceparent(trace), 55, "生成的 traceparent 是 55 字节")
check(otel.parse_traceparent(trace.traceparent) ~= nil, "自造的 traceparent 自身合法")
local ids = {}
for i = 1, 20 do
    fake.ctx = {}
    local t2 = otel.begin()
    ids[t2.trace_id] = (ids[t2.trace_id] or 0) + 1
    check(#t2.trace_id == 32 and t2.trace_id:match("^[0-9a-f]+$") ~= nil,
        "trace id 形态合法")
end
local distinct = 0
for _ in pairs(ids) do distinct = distinct + 1 end
eq(distinct, 20, "20 次生成的 trace id 互不相同")

--------------------------------------------------------------------------
new_case("sampling")
otel.reset_stats()
otel.configure({ enable = "1", sample_ratio = 0 })
fresh_request({})
trace = otel.begin()
check(trace ~= nil and trace.sampled == false, "ratio 0 生成未采样上下文")
eq(otel.finish(0.1), true, "未采样请求仍可关闭")
eq(otel.pending(), 0, "未采样不落任何 span")
otel.configure({ enable = "1", sample_ratio = 1 })
fresh_request({})
trace = otel.begin()
eq(trace.sampled, true, "ratio 1 全采样")
otel.configure({ enable = "1", sample_ratio = 0.5 })
fresh_request({ ["traceparent"] = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00" })
trace = otel.begin()
eq(trace.sampled, false, "继承 flags=00 时本地采样率不再起作用")
otel.configure({ enable = "0", sample_ratio = 1 })
fresh_request({})
eq(otel.begin(), nil, "关闭时 begin 直接返回 nil")
eq(otel.finish(0.1), false, "关闭时 finish 无事可做")
otel.configure({ enable = "1", sample_ratio = 1 })
fresh_request({})
local root = otel.begin()
check(root.parent_span_id == nil, "生成路径不写 parent_span_id")

--------------------------------------------------------------------------
new_case("OTLP/JSON encoding")
otel.reset_stats()
local payloads = {}
otel.set_exporter(function(_, body)
    payloads[#payloads + 1] = body
    return nil
end)
fresh_request({ ["traceparent"] = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" })
fake.status = 502
trace = otel.begin()
otel.child_end(otel.child_start("upstream_forward"), {}, 502)
eq(otel.finish(1.234), true, "请求 span 落队")
eq(otel.pending(), 1, "关闭后队列里有 1 条")
otel.flush()
eq(#payloads, 1, "一次导出一个请求")
local doc = cjson.decode(payloads[1])
local rs = doc.resourceSpans and doc.resourceSpans[1]
check(rs ~= nil, "resourceSpans 结构存在")
local res_attrs = rs.resource and rs.resource.attributes or {}
local function res_value(key)
    for i = 1, #res_attrs do
        if res_attrs[i].key == key then return res_attrs[i].value.stringValue end
    end
end
eq(res_value("service.name"), "smg", "resource service.name=smg（对齐 Rust）")
eq(res_value("telemetry.sdk.language"), "lua", "resource 标明 lua 实现")
local scope = rs.scopeSpans and rs.scopeSpans[1] and rs.scopeSpans[1].scope
eq(scope and scope.name, "smg", "instrumentation scope 名为 smg（Rust tracer(\"smg\")）")
local spans_entry = rs.scopeSpans and rs.scopeSpans[1]
local spans = spans_entry and spans_entry.spans or {}
eq(#spans, 2, "父 span 加一个子 span")
local parent, child
for i = 1, #spans do
    if spans[i].name == "http_request" then parent = spans[i] end
    if spans[i].name == "upstream_forward" then child = spans[i] end
end
check(parent ~= nil, "span 名为 http_request（Rust RequestSpan）")
eq(parent.traceId, "0af7651916cd43dd8448eb211c80319c", "OTLP traceId 为原 hex")
eq(parent.parentSpanId, "b7ad6b7169203331", "parentSpanId 指向调用方")
eq(#parent.spanId, 16, "spanId 16 位 hex")
eq(parent.kind, 2, "SERVER=2")
eq(child.kind, 3, "CLIENT=3")
eq(child.parentSpanId, parent.spanId, "子 span 挂在请求 span 下")
eq(parent.flags, 1, "OTLP flags 带上 sampled 位")
eq(child.flags, 1, "子 span 不借用父的 root 位（root 是 span 的属性）")
check(parent.startTimeUnixNano ~= nil and #parent.startTimeUnixNano <= 19,
    "startTimeUnixNano 以字符串编码（JSON 映射要求）", parent.startTimeUnixNano)
eq(otel.to_ns(1700000000500), "1700000000500000000", "ns 由字符串拼接（避免 2^53 精度损失）")
eq(parent.endTimeUnixNano, otel.to_ns(trace.started_ms + 1234), "end-start = duration")
check(parent.startTimeUnixNano:sub(-6) == "000000", "毫秒时间戳的纳秒低位补零", parent.startTimeUnixNano)
eq(parent.status.code, 2, "5xx 标 STATUS_CODE_ERROR")
local function attr(name, from)
    for i = 1, #from do
        if from[i].key == name then return from[i].value end
    end
end
eq(attr("method", parent.attributes).stringValue, "POST", "属性 method")
eq(attr("uri", parent.attributes).stringValue, "/v1/chat/completions", "属性 uri")
eq(attr("module", parent.attributes).stringValue, "smg", "属性 module=smg（Rust 同名字段）")
eq(attr("status_code", parent.attributes).intValue, "502", "属性 status_code 为字符串整数")
eq(attr("latency", parent.attributes).intValue, "1234000", "latency 用微秒（Rust 同名字段）")
eq(attr("error", parent.attributes).stringValue, "error", ">=400 时带 error 字段")
eq(attr("model", parent.attributes).stringValue, "unknown", "无模型时 model=unknown")
eq(attr("status_code", child.attributes).intValue, "502", "子 span 带上游状态")
eq(attr("error", child.attributes).stringValue, "backend_error", "5xx 子 span 标错误")
eq(otel.stats().dropped, 0, "导出成功不丢弃")
eq(otel.stats().exports_ok, 1, "成功计数 +1")

--------------------------------------------------------------------------
new_case("batch, failure and drop accounting")
payloads = {}
otel.reset_stats()
otel.configure({ enable = "1", batch_size = 2, sample_ratio = 1,
                 endpoint = "http://127.0.0.1:4318/v1/traces" })
for i = 1, 5 do
    fresh_request({})
    otel.begin()
    otel.finish(0.01)
end
eq(otel.pending(), 5, "5 条 span 排队")
otel.flush()
eq(#payloads, 3, "batch_size=2 时 5 条分 3 个批量导出")
eq(#cjson.decode(payloads[1]).resourceSpans[1].scopeSpans[1].spans, 2, "第一批 2 条")
eq(#cjson.decode(payloads[3]).resourceSpans[1].scopeSpans[1].spans, 1, "第三批 1 条")
eq(otel.pending(), 0, "导出后队列清空")

payloads = {}
otel.reset_stats()
otel.set_exporter(function(_, body)
    payloads[#payloads + 1] = body
    return "collector answered 503"
end)
fresh_request({})
otel.begin()
otel.finish(0.01)
otel.flush()
local st = otel.stats()
eq(st.exports_fail, 1, "失败计数 +1")
eq(st.export_retries, 1, "每批量重试一次（共两次尝试）")
eq(st.dropped, 1, "两次都失败的批量被丢弃并计数")
eq(st.fail_streak, 1, "失败连击计数")
check(st.last_error ~= nil and tostring(st.last_error):find("503") ~= nil,
    "最后一次错误可见", st.last_error)
eq(#payloads, 2, "确实尝试了两次")
otel.set_exporter(function()
    return "connect failed: connection refused"
end)
for _ = 1, 3 do
    fresh_request({})
    otel.begin()
    otel.finish(0.01)
    otel.flush()
end
st = otel.stats()
check(st.fail_streak >= 4, "连击继续累加", st.fail_streak)
eq(otel.next_delay_ms(), 500 * 8, "连击后定时器退避到 8 倍间隔")
otel.reset_stats()
eq(otel.next_delay_ms(), 500, "连击清零后回到常态间隔")

payloads = {}
otel.set_exporter(function(_, body) payloads[#payloads + 1] = body; return nil end)
otel.reset_stats()
otel.configure({ enable = "1", batch_size = 64, max_queue = 256, sample_ratio = 1 })
for i = 1, 260 do
    fresh_request({})
    otel.begin()
    otel.finish(0.001)
end
eq(otel.pending(), 256, "超过 max_queue 的 span 被丢弃")
eq(otel.stats().dropped, 4, "丢弃数量计入 stats")
otel.set_exporter(nil)
otel.reset_stats()

--------------------------------------------------------------------------
new_case("disabled module leaves requests alone")
otel.reset_stats()
otel.configure({ enable = "0" })
fresh_request({ ["traceparent"] = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" })
eq(otel.begin(), nil, "关闭时 begin 返回 nil")
local untouched = otel.inject({ ["traceparent"] = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" })
eq(untouched["traceparent"], "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
    "关闭时 traceparent 原样透传（契约测试钉住的行为）")
eq(otel.current(), nil, "关闭时无当前上下文")
eq(otel.child_start("upstream_forward"), nil, "关闭时不建子 span")
eq(otel.pending(), 0, "关闭时队列为空")

io.write("otel: " .. passed .. " passed, " .. failed .. " failed\n")
if failed > 0 then
    for i = 1, #failures do
        io.write("  FAIL " .. failures[i] .. "\n")
    end
    os.exit(1)
end
