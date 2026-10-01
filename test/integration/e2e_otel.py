#!/usr/bin/env python3
"""End-to-end checks for OpenTelemetry tracing (doc/gap-otel.md).

Topology, all on the host network:

    [client] --HTTP--> [router] --HTTP--> mock LLM worker (echo_headers proves
                            |                what traceparent arrived upstream)
                            +--OTLP/HTTP JSON--> fake collector (in-file server)

The collector is a stdlib HTTP server that decodes the OTLP/JSON body and keeps
every span, so propagation, span naming, attributes, batching and the failure
path are all observable from the client side. It can also be switched to
"refuse" mode (a port with no listener) to prove a dead collector cannot hurt a
request.

Groups, in run order:
  A. off by default: no response traceparent, the caller's value still forwarded
     verbatim (the 659-check contract), and nothing reaches the collector.
  B. context generation: no inbound traceparent -> response carries a legal
     00-<32hex>-<16hex>-01, the worker sees the same trace id with a *new* span
     id (Rust's insert semantics), the collector sees a parent + child pair.
  C. inheritance: inbound traceparent -> same trace id back and upstream, the
     sampled bit travels both ways, an inbound flags=00 records nothing.
  D. span content: resource service.name=smg, scope "smg", name http_request,
     kind SERVER/CLIENT, method/uri/path/status_code/model/latency/duration_ms/
     module/request_id/worker/endpoint/stream attributes, nanosecond timestamps
     built from milliseconds (six trailing zeros), child parentSpanId = request
     spanId, 4xx and 5xx marked STATUS_CODE_ERROR.
  E. batching: batch_size=2 with eight requests -> every export carries <=2
     spans, the totals add up, no span lost or duplicated.
  F. sampling: SMG_TRACE_SAMPLE_RATIO=0 keeps propagation alive (the worker still
     sees a trace id) but exports nothing, and requests are unaffected.
  G. streaming: an SSE request still produces its span pair.
  H. dead collector: requests keep answering 200, the failure counters move, the
     router logs no Lua error, and restarting the collector resumes export.
  I. graceful shutdown: with a 60s batch interval one request's span is still
     buffered when `docker stop` runs, and the collector receives it - the exit
     flush, i.e. Rust's shutdown_otel()/force_flush().

Run: python3 test/integration/e2e_otel.py
Requires the image built (final_gates.sh `build` gate).
"""
import json, os, re, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (free_port, http, check, start_mock, start_router, logs,
                  stop_router, wait_ready, chat, cleanup, RESULTS, RUN, PIDS)

TRACEPARENT = re.compile(r"^00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$")
HEX32 = re.compile(r"^[0-9a-f]{32}$")
HEX16 = re.compile(r"^[0-9a-f]{16}$")

COLLECTORS = []
STATE_LOCK = threading.Lock()


# ------------------------------------------------------------------ fake collector
class Collector:
    """A minimal OTLP/HTTP JSON receiver.

    mode "on" answers 200 with an empty ExportTraceServiceResponse; mode "off"
    makes the handler answer 500 so the exporter's retry + drop path runs while
    the port is still occupied (a closed port and a refusing one exercise the same
    code, and the refusal is the one an operator can flip without a restart).
    """

    def __init__(self, port):
        self.port = port
        self.spans = []
        self.batches = []
        self.requests = 0
        self.mode = "on"
        outer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt, *args):
                pass

            def do_POST(self):
                length = int(self.headers.get("content-length") or 0)
                raw = self.rfile.read(length) if length else b""
                with STATE_LOCK:
                    outer.requests += 1
                    if outer.mode == "off":
                        self.send_response(500)
                        self.send_header("content-length", "0")
                        self.end_headers()
                        return
                    try:
                        doc = json.loads(raw.decode("utf-8"))
                    except Exception as exc:            # noqa: BLE001
                        outer.batches.append({"error": str(exc), "raw": raw[:400]})
                        self.send_response(400)
                        self.send_header("content-length", "0")
                        self.end_headers()
                        return
                    count = 0
                    for resource in doc.get("resourceSpans", []):
                        for scope in resource.get("scopeSpans", []):
                            for span in scope.get("spans", []):
                                span["_resource"] = resource.get("resource", {})
                                span["_scope"] = scope.get("scope", {})
                                outer.spans.append(span)
                                count += 1
                    outer.batches.append({"count": count, "doc": doc})
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", "2")
                self.end_headers()
                self.wfile.write(b"{}")

        self.server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        COLLECTORS.append(self)

    def stop(self):
        try:
            self.server.shutdown()
            self.server_close()
        except Exception:                               # noqa: BLE001
            pass

    def server_close(self):
        self.server.server_close()

    def reset(self):
        with STATE_LOCK:
            self.spans = []
            self.batches = []
            self.requests = 0

    def wait(self, want, timeout=25):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with STATE_LOCK:
                if len(self.spans) >= want:
                    return True
            time.sleep(0.2)
        return False

    def wait_for(self, trace_ids, timeout=25):
        """Wait until every trace in `trace_ids` has its request span here."""
        wanted = set(trace_ids)
        deadline = time.time() + timeout
        while time.time() < deadline:
            with STATE_LOCK:
                seen = {s.get("traceId") for s in self.spans if s.get("kind") == 2}
            if wanted.issubset(seen):
                return True
            time.sleep(0.2)
        return False

    def by_name(self, name):
        with STATE_LOCK:
            return [s for s in self.spans if s.get("name") == name]

    def total(self):
        with STATE_LOCK:
            return len(self.spans)


def endpoint(collector):
    return "http://127.0.0.1:%d/v1/traces" % collector.port


# ------------------------------------------------------------------ assertions
def header_value(headers, name):
    for key, value in (headers or {}).items():
        if key.lower() == name.lower():
            return value
    return ""


def server_spans(collector, trace_ids=None):
    """Request spans (kind==SERVER).

    `trace_ids` matters more than it looks: this box runs a host-network
    llm-watcher container that polls every local router (/workers, /v1/models,
    /server_info), and every one of those polls is a real request that gets its own
    span. A batching or sampling assertion that counts the raw buffer therefore
    mixes foreign traffic in, so each count-sensitive check narrows the buffer to
    the traces the test itself issued.
    """
    out = [s for s in collector.by_name("http_request") if s.get("kind") == 2]
    if trace_ids is not None:
        wanted = set(trace_ids)
        out = [s for s in out if s.get("traceId") in wanted]
    return out


def server_span(collector, trace_ids=None):
    spans = server_spans(collector, trace_ids)
    return spans[0] if spans else {}


def children_of(collector, trace_ids):
    wanted = set(trace_ids)
    return [s for s in collector.by_name("upstream_forward") if s.get("traceId") in wanted]


def count_spans(collector, trace_ids=None):
    return len(server_spans(collector, trace_ids))


def mine_of(collector, trace_ids):
    """Every span (parent or child) belonging to the given traces."""
    wanted = set(trace_ids)
    return [s for s in collector.spans if s.get("traceId") in wanted]


def attr(span, key):
    for item in span.get("attributes", []):
        if item.get("key") == key:
            return item.get("value", {})
    return None


def attr_text(span, key):
    value = attr(span, key)
    return value.get("stringValue") if value else None


def attr_int(span, key):
    value = attr(span, key)
    if not value:
        return None
    text = value.get("intValue", value.get("stringValue"))
    try:
        return int(text)
    except (TypeError, ValueError):
        return None


def res_text(span, key):
    for item in (span.get("_resource") or {}).get("attributes", []):
        if item.get("key") == key:
            return item.get("value", {}).get("stringValue")
    return None


def parse_header(value):
    match = TRACEPARENT.match(value or "")
    if not match:
        return None
    return {"trace_id": match.group(1), "span_id": match.group(2), "flags": match.group(3)}


def mock_traceparent(port, model="alpha", extra_headers=None, path="/v1/chat/completions"):
    """One chat through the router; returns (status, body, response headers,
    the traceparent the worker saw, the parsed response traceparent)."""
    st, body, headers = chat(port, model, extra=None, path=path,
                             headers=extra_headers or None)
    sent = ""
    try:
        doc = json.loads(body)
        sent = (doc.get("echo_headers") or {}).get("traceparent", "")
    except Exception:                                    # pragma: no cover
        pass
    response_tp = header_value(headers, "traceparent")
    return st, body, headers, sent, parse_header(response_tp)


def metric(text, name, label_substr=""):
    for line in text.splitlines():
        if line.startswith("#") or not line.startswith(name):
            continue
        rest = line[len(name):]
        if not (rest.startswith("{") or rest.startswith(" ")):
            continue
        if label_substr and label_substr not in rest:
            continue
        try:
            return float(rest.rstrip().split(" ")[-1])
        except ValueError:
            pass
    return None


def metrics(port):
    st, body, _ = http("GET", "http://127.0.0.1:%d/metrics" % port)
    return body if st == 200 else ""


def wait_metric(port, name, label_substr="", want=1.0, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = metric(metrics(port), name, label_substr)
        if value is not None and value >= want:
            return value
        time.sleep(0.5)
    return None


def router_env(collector, extra=None):
    env = {"SMG_POLICY": "round_robin", "SMG_ENABLE_TRACE": "1",
           "SMG_OTLP_TRACES_ENDPOINT": endpoint(collector),
           "SMG_TRACE_BATCH_INTERVAL_MS": "150", "SMG_TRACE_BATCH_SIZE": "64",
           "SMG_TRACE_TIMEOUT_MS": "1500", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1"}
    env.update(extra or {})
    return env


# ------------------------------------------------------------------ group A
def group_off(collector, worker_port):
    name = "lr-otel-off-" + RUN
    env = {"SMG_POLICY": "round_robin", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
           "SMG_WORKER_URLS": "http://127.0.0.1:%d" % worker_port}
    port = start_router(env, name)
    check("[A] router up", wait_ready(port, 1, 40), logs(name)[-400:])
    st, _, headers, sent, parsed = mock_traceparent(port)
    check("[A] 关闭时请求正常", st == 200, "%s %s" % (st, _[:200]))
    check("[A] 响应不吐 traceparent", header_value(headers, "traceparent") == "", str(headers))
    check("[A] 无入站 traceparent 时上游也收不到", sent == "", repr(sent))
    st, _, _, sent2, _ = mock_traceparent(
        port, extra_headers={"traceparent": "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"})
    check("[A] 关闭时入站 traceparent 原样透传",
          sent2 == "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01", repr(sent2))
    time.sleep(0.6)
    check("[A] 关闭时采集器一条不收", collector.total() == 0, collector.total())
    check("[A] /metrics 无 otel 计数",
          metric(metrics(port), "smg_otel_requests_total") is None, metrics(port)[:200])
    stop_router(name)


# ------------------------------------------------------------------ group B
def group_generate(collector, worker_port):
    name = "lr-otel-gen-" + RUN
    port = start_router(router_env(collector, {
        "SMG_WORKER_URLS": "http://127.0.0.1:%d" % worker_port}), name)
    check("[B] router up", wait_ready(port, 1, 40), logs(name)[-400:])
    collector.reset()
    st, body, headers, sent, parsed = mock_traceparent(port)
    check("[B] 请求正常返回", st == 200, "%s %s" % (st, body[:200]))
    check("[B] 响应头是合法 traceparent", parsed is not None, str(headers))
    if not parsed:
        stop_router(name)
        return
    check("[B] 生成的 trace id 非全零", HEX32.match(parsed["trace_id"])
          and parsed["trace_id"] != "0" * 32, parsed["trace_id"])
    check("[B] 默认采样：flags=01", parsed["flags"] == "01", parsed["flags"])
    upstream = parse_header(sent.replace("00-", "00-", 1) if sent else "")
    sent_match = TRACEPARENT.match(sent or "")
    check("[B] 上游收到合法 traceparent", sent_match is not None, repr(sent))
    if sent_match:
        check("[B] 上游 trace id 与响应一致", sent_match.group(1) == parsed["trace_id"],
              "%s vs %s" % (sent, headers.get("traceparent")))
        check("[B] 上游 span id 是路由器自己的（覆盖而非透传）",
              sent_match.group(2) == parsed["span_id"],
              "%s vs %s" % (sent_match.group(2), parsed["span_id"]))
    check("[B] 采集器收到请求 span", collector.wait(1), collector.total())
    mine = [parsed["trace_id"]]
    parents = server_spans(collector, mine)
    check("[B] 每个请求恰有一个 SERVER 端 span", len(parents) == 1,
          [(x.get("name"), x.get("kind")) for x in collector.by_name("http_request")])
    parent = parents[0]
    check("[B] span traceId 与响应头一致", parent.get("traceId") == parsed["trace_id"],
          "%s vs %s" % (parent.get("traceId"), parsed["trace_id"]))
    check("[B] spanId 是 16 位 hex", HEX16.match(parent.get("spanId", "")) is not None,
          parent.get("spanId"))
    check("[B] 根 span 无 parentSpanId", not parent.get("parentSpanId"),
          str(parent.get("parentSpanId")))
    # OTLP Span.flags: bit0 sampled, bit8 "this span is a root". A generated trace
    # is a root, so both bits are set; a child must never carry bit8.
    check("[B] 根 span 的 flags = sampled|rooted (257)", parent.get("flags") == 257,
          parent.get("flags"))
    children = children_of(collector, mine)
    check("[B] 生成一个 upstream_forward 子 span", len(children) == 1, len(children))
    if children:
        check("[B] 子 span 挂在请求 span 下",
              children[0].get("parentSpanId") == parent.get("spanId"),
              "%s vs %s" % (children[0].get("parentSpanId"), parent.get("spanId")))
        check("[B] 子 span 与父同 trace", children[0].get("traceId") == parent.get("traceId"),
              children[0].get("traceId"))
        check("[B] 子 span 不借用父的 rooted 位", children[0].get("flags") == 1,
              children[0].get("flags"))
    stop_router(name)


# ------------------------------------------------------------------ group C
def group_inherit(collector, worker_port):
    inbound = "00-1234567890abcdef1234567890abcdef-fedcba0987654321-01"
    name = "lr-otel-inh-" + RUN
    port = start_router(router_env(collector, {
        "SMG_WORKER_URLS": "http://127.0.0.1:%d" % worker_port}), name)
    check("[C] router up", wait_ready(port, 1, 40), logs(name)[-400:])
    collector.reset()
    st, body, headers, sent, parsed = mock_traceparent(port, extra_headers={
        "traceparent": inbound, "tracestate": "rojo=00f067aa0ba902b7"})
    check("[C] 继承请求正常", st == 200, "%s %s" % (st, body[:200]))
    check("[C] 响应头同 trace id", parsed and parsed["trace_id"] == "1234567890abcdef1234567890abcdef",
          str(headers))
    check("[C] 响应头是新 span id", parsed and parsed["span_id"] != "fedcba0987654321",
          str(parsed))
    check("[C] 上游同 trace id + 我们的 span id", sent == "00-1234567890abcdef1234567890abcdef-%s-01"
          % (parsed["span_id"] if parsed else ""), repr(sent))
    check("[C] 采集器收到 span", collector.wait(1), collector.total())
    mine = [parsed["trace_id"]] if parsed else []
    parent = server_span(collector, mine)
    check("[C] parentSpanId 指向调用方",
          parent.get("parentSpanId") == "fedcba0987654321", str(parent.get("parentSpanId")))
    check("[C] 继承的 span 不算根（flags 无 root 位）", parent.get("flags") == 1,
          parent.get("flags"))

    # flags=00: propagate, record nothing.
    collector.reset()
    st, _, headers, sent, parsed = mock_traceparent(port, extra_headers={
        "traceparent": "00-1234567890abcdef1234567890abcdef-fedcba0987654321-00"})
    check("[C] 未采样入站仍返回 200", st == 200, str(st))
    check("[C] 未采样决策被继承到响应头", parsed and parsed["flags"] == "00", str(headers))
    check("[C] 未采样决策被传给上游", sent.endswith("-00"), repr(sent))
    unsampled = parsed["trace_id"] if parsed else ""
    time.sleep(0.8)
    # Scoped to this trace id: the box's llm-watcher keeps polling the router and
    # those foreign spans land in the same buffer.
    check("[C] 未采样不导出 span", not mine_of(collector, [unsampled]),
          [s.get("name") for s in collector.spans])

    # A malformed value is not a context: the router generates its own.
    collector.reset()
    st, _, headers, sent, parsed = mock_traceparent(port, extra_headers={
        "traceparent": "00-trace-span-01"})
    check("[C] 非法 traceparent 不致命", st == 200 and parsed is not None, str(headers))
    check("[C] 非法值被丢弃并自建 trace",
          parsed and parsed["trace_id"] != "trace" and HEX32.match(parsed["trace_id"]),
          str(headers))
    if parsed:
        collector.wait_for([parsed["trace_id"]], 10)
        rebuilt = server_span(collector, [parsed["trace_id"]])
        check("[C] 自建 trace 正常导出且不含入站的 id",
              bool(rebuilt) and not rebuilt.get("parentSpanId")
              and rebuilt.get("traceId") != "0af7651916cd43dd8448eb211c80319c",
              str(rebuilt)[:200])
    stop_router(name)


# ------------------------------------------------------------------ group D
def group_span_fields(collector, worker_port):
    name = "lr-otel-span-" + RUN
    port = start_router(router_env(collector, {
        "SMG_WORKER_URLS": "http://127.0.0.1:%d" % worker_port,
        "SMG_TRACE_UPSTREAM_CHILD": "1"}), name)
    check("[D] router up", wait_ready(port, 1, 40), logs(name)[-400:])
    collector.reset()
    st, body, chat_headers = chat(port, "alpha", text="otel field check")
    check("[D] chat 正常", st == 200, "%s %s" % (st, body[:200]))
    mine = [parse_header(header_value(chat_headers, "traceparent"))["trace_id"]]
    check("[D] span 到达", collector.wait(2), collector.total())
    parent = server_span(collector, mine)
    child = (children_of(collector, mine) + [{}])[0]
    check("[D] resource service.name=smg（对齐 Rust）",
          res_text(parent, "service.name") == "smg", json.dumps(parent.get("_resource")))
    check("[D] resource 标明 lua 实现",
          res_text(parent, "telemetry.sdk.language") == "lua", str(parent.get("_resource")))
    check("[D] instrumentation scope 名为 smg",
          (parent.get("_scope") or {}).get("name") == "smg", str(parent.get("_scope")))
    check("[D] kind=SERVER(2)", parent.get("kind") == 2, parent.get("kind"))
    check("[D] 子 span kind=CLIENT(3)", child.get("kind") == 3, child.get("kind"))
    check("[D] 属性 method", attr_text(parent, "method") == "POST", attr(parent, "method"))
    check("[D] 属性 uri 含完整请求路径",
          attr_text(parent, "uri") == "/v1/chat/completions", attr(parent, "uri"))
    check("[D] 属性 path", attr_text(parent, "path") == "/v1/chat/completions",
          attr(parent, "path"))
    check("[D] 属性 module=smg", attr_text(parent, "module") == "smg", attr(parent, "module"))
    check("[D] 属性 status_code=200", attr_int(parent, "status_code") == 200,
          attr(parent, "status_code"))
    check("[D] 属性 model", attr_text(parent, "model") == "alpha", attr(parent, "model"))
    check("[D] 属性 endpoint=chat", attr_text(parent, "endpoint") == "chat",
          attr(parent, "endpoint"))
    check("[D] 属性 stream=false", attr(parent, "stream") == {"boolValue": False},
          attr(parent, "stream"))
    check("[D] 属性 worker 指向 mock",
          ("127.0.0.1:%d" % worker_port) in (attr_text(parent, "worker") or ""),
          attr(parent, "worker"))
    check("[D] 属性 request_id 与响应头一致", (attr_text(parent, "request_id") or "") != "",
          attr(parent, "request_id"))
    check("[D] 属性 route_type 记录策略", attr_text(parent, "route_type") == "round_robin",
          attr(parent, "route_type"))
    latency, duration_ms = attr_int(parent, "latency"), attr_int(parent, "duration_ms")
    check("[D] latency 是微秒（Rust 同名字段）",
          latency is not None and duration_ms is not None
          and abs(latency - duration_ms * 1000) <= 1000,
          "%s vs %s" % (latency, duration_ms))
    check("[D] duration_ms 非负", (attr_int(parent, "duration_ms") or -1) >= 0,
          attr(parent, "duration_ms"))
    check("[D] 时间戳为字符串纳秒", isinstance(parent.get("startTimeUnixNano"), str)
          and parent.get("startTimeUnixNano", "").isdigit(), parent.get("startTimeUnixNano"))
    check("[D] 纳秒由毫秒补零（不经 2^53 精度损失）",
          str(parent.get("startTimeUnixNano", "")).endswith("000000"),
          parent.get("startTimeUnixNano"))
    check("[D] end >= start",
          int(parent.get("endTimeUnixNano", 0)) >= int(parent.get("startTimeUnixNano", 0)),
          "%s -> %s" % (parent.get("startTimeUnixNano"), parent.get("endTimeUnixNano")))
    check("[D] 2xx 不标 ERROR", parent.get("status", {}).get("code") != 2,
          json.dumps(parent.get("status")))
    check("[D] 子 span 带 worker / attempt",
          ("127.0.0.1:%d" % worker_port) in (attr_text(child, "worker") or "")
          and attr_int(child, "attempt") == 1, json.dumps(child.get("attributes")))
    check("[D] 子 span 记录上游 200", attr_int(child, "status_code") == 200,
          attr(child, "status_code"))

    # The child span is switchable.
    stop_router(name)
    name = "lr-otel-nochild-" + RUN
    port = start_router(router_env(collector, {
        "SMG_WORKER_URLS": "http://127.0.0.1:%d" % worker_port,
        "SMG_TRACE_UPSTREAM_CHILD": "0"}), name)
    check("[D] child-off router up", wait_ready(port, 1, 40), logs(name)[-400:])
    collector.reset()
    st, _, off_headers = chat(port, "alpha", text="no child")
    off_trace = [parse_header(header_value(off_headers, "traceparent"))["trace_id"]]
    collector.wait_for(off_trace, 8)
    check("[D] child-off 仍有请求 span", bool(server_span(collector, off_trace)),
          collector.total())
    time.sleep(0.6)
    check("[D] SMG_TRACE_UPSTREAM_CHILD=0 不生成子 span",
          len(children_of(collector, off_trace)) == 0,
          [c.get("traceId") for c in collector.by_name("upstream_forward")])
    stop_router(name)


# ------------------------------------------------------------------ group E
def group_batch(collector, worker_port):
    name = "lr-otel-batch-" + RUN
    port = start_router(router_env(collector, {
        "SMG_WORKER_URLS": "http://127.0.0.1:%d" % worker_port,
        "SMG_TRACE_BATCH_SIZE": "2", "SMG_TRACE_UPSTREAM_CHILD": "0",
        "SMG_TRACE_BATCH_INTERVAL_MS": "300"}), name)
    check("[E] router up", wait_ready(port, 1, 40), logs(name)[-400:])
    collector.reset()
    seen = []
    ok = True
    for i in range(8):
        st, body, headers = chat(port, "alpha", text="batch %d" % i)
        if st != 200:
            ok = False
            check("[E] 请求 %d 正常" % i, False, "%s %s" % (st, body[:120]))
            continue
        seen.append(parse_header(header_value(headers, "traceparent"))["trace_id"])
    check("[E] 八个请求全部 200", ok, "see per-request failures")
    check("[E] 8 个请求的 span 全部到达", collector.wait_for(seen, 30),
          "%d of %d" % (count_spans(collector, seen), len(seen)))
    time.sleep(1.2)
    # Count spans per batch for *our* traces: the box's llm-watcher polls the
    # router every few seconds and its requests are traced too.
    counts = [len([s for s in (b.get("doc") or {}).get("resourceSpans", [])
                   for sc in s.get("scopeSpans", [])
                   for sp in sc.get("spans", [])
                   if sp.get("traceId") in set(seen)])
              for b in collector.batches if "count" in b]
    check("[E] 每个导出不超过 batch_size", counts and max(counts) <= 2, counts)
    check("[E] 导出的 span 总数与请求数一致", sum(counts) == 8, sum(counts))
    check("[E] 至少分了 4 个批量", len([c for c in counts if c]) >= 4, counts)
    check("[E] 队列已排空", len(mine_of(collector, seen)) == 8,
          len(mine_of(collector, seen)))
    ids = {s.get("traceId") for s in mine_of(collector, seen)}
    check("[E] 8 条 span 分属 8 条 trace", len(ids) == 8, len(ids))
    stop_router(name)


# ------------------------------------------------------------------ group F
def group_sampling(collector, worker_port):
    name = "lr-otel-ratio0-" + RUN
    port = start_router(router_env(collector, {
        "SMG_WORKER_URLS": "http://127.0.0.1:%d" % worker_port,
        "SMG_TRACE_SAMPLE_RATIO": "0", "SMG_TRACE_BATCH_SIZE": "1"}), name)
    check("[F] router up", wait_ready(port, 1, 40), logs(name)[-400:])
    collector.reset()
    ok = 0
    for i in range(5):
        st, _, headers, sent, parsed = mock_traceparent(port)
        ok += 1 if (st == 200 and parsed and parsed["flags"] == "00") else 0
        if i == 0:
            check("[F] ratio=0 仍返回 traceparent（未采样）",
                  parsed is not None and parsed["flags"] == "00", str(headers))
            check("[F] ratio=0 仍向上游传播上下文", TRACEPARENT.match(sent or "") is not None,
                  repr(sent))
    check("[F] ratio=0 五个请求全 200", ok == 5, ok)
    time.sleep(1.0)
    # The raw buffer is the right thing to assert here: on a ratio=0 router even the
    # llm-watcher's own polls are unsampled, so any span at all would be a leak.
    check("[F] ratio=0 一条 span 也不导出", collector.total() == 0, collector.total())
    value = wait_metric(port, "smg_otel_requests_total", 'sampled="false"', 5)
    check("[F] /metrics 计入未采样请求", value is not None, metrics(port)[:200])
    stop_router(name)

    # A middling ratio still produces coherent traces: every exported span belongs
    # to a trace whose header the client saw.
    name = "lr-otel-ratio25-" + RUN
    port = start_router(router_env(collector, {
        "SMG_WORKER_URLS": "http://127.0.0.1:%d" % worker_port,
        "SMG_TRACE_SAMPLE_RATIO": "0.25", "SMG_TRACE_UPSTREAM_CHILD": "0"}), name)
    # Readiness has to be waited for: without it the first requests race the health
    # probe and answer 503, which is not a tracing result at all.
    check("[F] ratio=0.25 router up", wait_ready(port, 1, 40), logs(name)[-400:])
    for _ in range(60):
        if chat(port, "alpha", text="warm")[0] == 200:
            break
        time.sleep(0.5)
    collector.reset()
    seen = []
    for i in range(40):
        st, _, headers, sent, parsed = mock_traceparent(port)
        if st != 200 or parsed is None:
            check("[F] ratio=0.25 请求 %d 正常" % i, False, "%s %s" % (st, str(headers)[:120]))
            break
        seen.append(parsed["trace_id"])
    check("[F] ratio=0.25 四十个请求全部 200", len(seen) == 40, len(seen))
    check("[F] ratio=0.25 有 span 被导出", collector.wait(1, 20), collector.total())
    time.sleep(1.2)
    # Only this run's traces feed the ratio judgement: the box's llm-watcher keeps
    # generating its own sampled traces on this same router.
    exported = {s.get("traceId") for s in server_spans(collector, seen)}
    check("[F] 采样的 trace 都在客户端见过的集合里", bool(exported) and exported.issubset(set(seen)),
          list(exported)[:3])
    # 40 heads at ratio 0.25 has probability ~1e-24, so the strict "< 40" bound
    # would only be flaky with a broken RNG; 34 leaves room for one unlucky run.
    check("[F] 采样率生效（40 条未全导出）", 0 < len(exported) < 34, len(exported))
    stop_router(name)


# ------------------------------------------------------------------ group G
def group_stream_and_errors(collector, worker_port):
    name = "lr-otel-stream-" + RUN
    port = start_router(router_env(collector, {
        "SMG_WORKER_URLS": "http://127.0.0.1:%d" % worker_port}), name)
    check("[G] router up", wait_ready(port, 1, 40), logs(name)[-400:])
    collector.reset()
    st, body, headers = chat(port, "alpha", text="streamed", stream=True)
    parsed = parse_header(header_value(headers, "traceparent"))
    mine = [parsed["trace_id"]] if parsed else []
    check("[G] SSE 正常返回", st == 200 and "data:" in body, "%s %s" % (st, body[:120]))
    check("[G] SSE 响应头带 traceparent", parsed is not None, str(headers))
    check("[G] SSE 也产生 span", collector.wait_for(mine, 20), collector.total())
    parent = server_span(collector, mine)
    check("[G] span 标 stream=true", attr(parent, "stream") == {"boolValue": True},
          attr(parent, "stream"))
    check("[G] SSE 的 status_code=200", attr_int(parent, "status_code") == 200,
          attr(parent, "status_code"))

    # 4xx from the worker: error status on the span, plus the router's error code.
    # The worker itself answers 400 (fail-mode no_retry_4xx) so the 4xx is
    # deterministic instead of depending on how the router treats a missing model.
    stop_router(name)
    bad_port = free_port()
    log = open("%s/mock-%d.log" % (os.environ.get("LR_TEST_TMP", "/data/tmp/lr"), bad_port), "w")
    env = dict(os.environ, MODEL="alpha")
    proc = subprocess.Popen([sys.executable, os.environ["LR_MOCK"],
                             "--host", "0.0.0.0", "--port", str(bad_port),
                             "--model", "alpha", "--fail-mode", "no_retry_4xx"],
                            stdout=log, stderr=subprocess.DEVNULL, env=env)
    PIDS.append(proc)
    bad_up = False
    for _ in range(80):
        if http("GET", "http://127.0.0.1:%d/health" % bad_port, timeout=2)[0] == 200:
            bad_up = True
            break
        time.sleep(0.1)
    check("[G] 返回 4xx 的 worker 起得来", bad_up)
    name = "lr-otel-4xx-" + RUN
    port = start_router(router_env(collector, {
        "SMG_WORKER_URLS": "http://127.0.0.1:%d" % bad_port}), name)
    check("[G] 4xx router up", wait_ready(port, 1, 40), logs(name)[-400:])
    collector.reset()
    st, body, err_headers = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                                 {"messages": [{"role": "user", "content": "no model field ok"}]})
    check("[G] worker 的 4xx 透传给客户端", st in (200, 400), "%s %s" % (st, body[:120]))
    # 404 on an unknown model gives a deterministic 4xx span
    st, body, headers = chat(port, "no-such-model")
    parsed = parse_header(header_value(headers, "traceparent"))
    check("[G] 未知模型不炸", st in (200, 400, 404, 503), "%s %s" % (st, body[:120]))
    check("[G] 非 2xx 也回 traceparent", parsed is not None, str(headers))
    collector.reset()
    st, err_body, err_headers = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                                     "not json",
                                     headers={"content-type": "application/json"})
    check("[G] 非法 JSON -> 400", st == 400, "%s %s" % (st, err_body[:120]))
    bad_trace = [parse_header(header_value(err_headers, "traceparent"))["trace_id"]]
    check("[G] 错误请求仍产生 span", collector.wait_for(bad_trace, 20), collector.total())
    err_span = server_span(collector, bad_trace)
    check("[G] 4xx 标 STATUS_CODE_ERROR", err_span.get("status", {}).get("code") == 2,
          json.dumps(err_span.get("status")))
    check("[G] error 属性带上错误码",
          (attr_text(err_span, "error") or "") != "", attr(err_span, "error"))
    check("[G] 无 Lua 崩溃", "lua entry thread aborted" not in logs(name),
          logs(name)[-400:])
    proc.terminate()
    stop_router(name)


# ------------------------------------------------------------------ group H
def group_dead_collector(worker_port):
    dead_port = free_port()
    name = "lr-otel-dead-" + RUN
    port = start_router({"SMG_POLICY": "round_robin", "SMG_ENABLE_TRACE": "1",
                         "SMG_OTLP_TRACES_ENDPOINT": "http://127.0.0.1:%d/v1/traces" % dead_port,
                         "SMG_TRACE_BATCH_INTERVAL_MS": "150", "SMG_TRACE_TIMEOUT_MS": "800",
                         "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                         "SMG_WORKER_URLS": "http://127.0.0.1:%d" % worker_port}, name)
    check("[H] 采集器不存在时 router 正常起", wait_ready(port, 1, 40), logs(name)[-400:])
    ok = 0
    for i in range(4):
        st, body, headers, sent, parsed = mock_traceparent(port)
        ok += 1 if st == 200 and parsed is not None else 0
    check("[H] 采集器不存在时四个请求全部 200 且带头", ok == 4, ok)
    value = wait_metric(port, "smg_otel_export_failures_total", "", 1)
    check("[H] 导出失败被计数", value is not None, metrics(port)[:400])
    dropped = wait_metric(port, "smg_otel_spans_total", 'result="dropped"', 1)
    check("[H] 丢弃的 span 被计数", dropped is not None, str(dropped))
    exports = wait_metric(port, "smg_otel_exports_total", 'result="failure"', 1)
    check("[H] exports_total{failure} 增长", exports is not None, str(exports))
    # The failure path stays quiet in the error log (one WARN per batch, no trace).
    text = logs(name)
    check("[H] 失败有 WARN 记录", "otel export dropped" in text, text[-400:])
    check("[H] 采集器故障不产生 Lua 错误",
          "lua entry thread aborted" not in text and "[error]" not in text, text[-400:])
    # And recovery: the same router resumes exporting once a listener appears.
    revived = Collector(dead_port)
    revived.reset()
    mock_traceparent(port)
    check("[H] 采集器恢复后继续导出", revived.wait(1, 40), revived.total())
    revived.stop()
    stop_router(name)


# ------------------------------------------------------------------ group I
def group_shutdown_flush(collector, worker_port):
    name = "lr-otel-exit-" + RUN
    port = start_router(router_env(collector, {
        "SMG_WORKER_URLS": "http://127.0.0.1:%d" % worker_port,
        "SMG_TRACE_BATCH_INTERVAL_MS": "60000", "SMG_TRACE_BATCH_SIZE": "512"}), name)
    check("[I] router up", wait_ready(port, 1, 40), logs(name)[-400:])
    collector.reset()
    st, _, headers, _, parsed = mock_traceparent(port)
    check("[I] 请求 200", st == 200, str(st))
    time.sleep(1.0)
    mine = [parsed["trace_id"]] if parsed else []
    check("[I] 60s 批量间隔下这条 span 还没导出", not mine_of(collector, mine),
          collector.total())
    subprocess.run(["docker", "stop", name], capture_output=True, timeout=120)
    # Scoped to our trace: the queue also holds the llm-watcher's polls, and the
    # first span out of a shutdown flush is not necessarily ours.
    check("[I] 优雅退出前把队列导出（Rust force_flush 的对应物）",
          collector.wait_for(mine, 20), collector.total())
    check("[I] 退出前导出的请求 span 属于那条请求", bool(server_span(collector, mine)),
          collector.total())
    check("[I] 子 span 一起导出（父子同批）", len(children_of(collector, mine)) == 1,
          len(children_of(collector, mine)))
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)


def main():
    collector = Collector(free_port())
    worker_port = free_port()
    os.environ["LR_MOCK"] = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "mock_llm_worker.py")
    start_mock(worker_port, "alpha")
    try:
        group_off(collector, worker_port)
        group_generate(collector, worker_port)
        group_inherit(collector, worker_port)
        group_span_fields(collector, worker_port)
        group_batch(collector, worker_port)
        group_sampling(collector, worker_port)
        group_stream_and_errors(collector, worker_port)
        group_dead_collector(worker_port)
        group_shutdown_flush(collector, worker_port)
    finally:
        for c in COLLECTORS:
            try:
                c.stop()
            except Exception:                           # noqa: BLE001
                pass
    failed = [name for ok, name, _ in RESULTS if not ok]
    print("\n%d checks, %d failed" % (len(RESULTS), len(failed)))
    for name in failed:
        print("FAIL " + name)
    cleanup()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
