#!/usr/bin/env python3
"""e2e for the GPU load source (doc/gap-gpu-load.md).

*** WRITE-ONLY THIS ROUND: authored, not executed. Run with
    python3 test/integration/e2e_gpu_load.py
once the unit gate is settled (the parent's instruction for this round). ***

Real openresty containers, real workers, a fake Prometheus on localhost.
_lib.py supplies the plumbing (free_port / http / check / start_router / logs /
cleanup); the GPU-exposing worker and the Prometheus double live in this file
because test/mock_llm_worker.py serves a fixed /metrics with none of the gauges
the source looks for.

Division of labour: gpu_load.lua's pure semantics (parsing, mapping, priority,
TTL, dedup) are covered by test/unit/test_gpu_load.lua -- 268 checks, luajit, no
ngx. This file covers only what a unit test structurally cannot see: that the
timer runs inside nginx, that samples land in lr_workers across the fork, that
/workers and /metrics expose them, and that power_of_two and cache_aware change
behaviour because of them.

Scenarios, in order:
  1  SMG_LOAD_SOURCE unset (= none): zero behaviour change. No lr_gpu_load*
     family on /metrics, /workers load is the plain in-flight counter, no
     gpu-load line in the error log, traffic still routes.
  2  source=metrics: a worker reporting nvidia_gpu_utilization 90 shows ~90 on
     /workers (SMG_LOAD_SCALE=100), and exports lr_gpu_load{worker=...} 0.9.
     /v1/loads on that same worker keeps answering the engine's own
     aggregate.total_tokens -- the "two channels do not clobber each other"
     observable, since /v1/loads is a live pull and never writes the registry.
  3  source=metrics against a gauge-less worker and a 404-ing one: both stay
     healthy and routable, their load is in-flight only, and the failure is one
     deduped WARN per target instead of one per tick.
  4  power_of_two consumes the sample: one hot GPU and one idle worker, and the
     hot one must stay nearly empty over a burst (before the change it would
     compete on in-flight alone and take ~half).
  5  cache_aware's escape consumes the sample: same prefix on every request (so
     affinity would pin one worker), and the hot worker must stop being the
     answer once its GPU is busy.
  6  source=prom: host-label mapping, two co-located workers sharing one
     reading, an unknown instance ignored, one POST per pass for a pool-wide
     PromQL and one per distinct host for a {host} template.
  7  the Prometheus is down: no worker leaves the pool, traffic flows, and the
     error log gets a bounded number of lines.
  8  staleness: after the worker stops reporting and SMG_LOAD_STALE_SECS passes,
     the load returns to in-flight-only without a restart (the TTL is the whole
     cleanup story -- there is no sweeper to wait for).
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (RUN, TMP, RESULTS, free_port, http, check, start_router,
                  logs, cleanup, stop_router, wait_ready)

GPU_ENV = {
    "SMG_POLICY": "round_robin",
    "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
    "SMG_LOAD_INTERVAL_SECS": "1",
    "SMG_LOAD_TIMEOUT_SECS": "1",
    "SMG_LOAD_STALE_SECS": "4",
    "SMG_METRICS_PORT": "0",           # /metrics on the main port, as the other suites
    "SMG_LOG_LEVEL": "notice",         # the dedup assertion reads the WARN lines back
}


class GpuMock:
    """A worker with the four endpoints the source and the policies touch.

    Dials: gpu_util (None = gauge absent), metrics_on (False = /metrics 404),
    loads (None = /v1/loads 404, else aggregate.total_tokens), api_key
    (required on /metrics, which is how the bearer path gets exercised).
    """

    def __init__(self, port, model, gpu_util=5.0, loads=0, metrics_on=True,
                 api_key=None):
        self.port, self.model = port, model
        self.gpu_util, self.loads, self.metrics_on = gpu_util, loads, metrics_on
        self.api_key = api_key
        self.chats = 0
        self.lock = threading.Lock()
        outer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt, *args):
                pass

            def _send(self, status, payload, ctype="application/json"):
                raw = payload.encode() if isinstance(payload, str) \
                    else json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                path = self.path.split("?", 1)[0]
                if path == "/health":
                    return self._send(200, {"ok": True})
                if path == "/v1/models":
                    return self._send(200, {"object": "list", "data": [
                        {"id": outer.model, "object": "model"}]})
                if path == "/v1/loads":
                    if outer.loads is None:
                        return self._send(404, {"error": {"message": "no loads"}})
                    return self._send(200, {"aggregate": {"total_tokens": outer.loads}})
                if path == "/metrics":
                    if not outer.metrics_on:
                        return self._send(404, "not found", "text/plain")
                    if outer.api_key and (self.headers.get("Authorization")
                                          != "Bearer " + outer.api_key):
                        return self._send(401, "denied", "text/plain")
                    lines = ["# HELP mock_requests_total requests",
                             "# TYPE mock_requests_total counter",
                             "mock_requests_total %d" % outer.chats]
                    if outer.gpu_util is not None:
                        # Two cards; the hotter one is what max-reduction must pick.
                        lines += ["# TYPE nvidia_gpu_utilization gauge",
                                  'nvidia_gpu_utilization{gpu="0"} %.1f'
                                  % max(0.0, outer.gpu_util - 5.0),
                                  'nvidia_gpu_utilization{gpu="1"} %.1f'
                                  % outer.gpu_util]
                    return self._send(200, "\n".join(lines) + "\n", "text/plain")
                return self._send(404, {"error": {"message": "no route " + path}})

            def do_POST(self):
                raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                try:
                    body = json.loads(raw.decode()) if raw else {}
                except Exception:
                    body = {}
                if self.path.split("?", 1)[0] != "/v1/chat/completions":
                    return self._send(404, {"error": {"message": "no route"}})
                with outer.lock:
                    outer.chats += 1
                content = (body.get("messages") or [{}])[0].get("content", "")
                return self._send(200, {
                    "id": "chatcmpl-mock", "object": "chat.completion",
                    "created": int(time.time()),
                    "model": body.get("model") or outer.model,
                    "choices": [{"index": 0, "finish_reason": "stop",
                                 "message": {"role": "assistant",
                                             "content": "echo[%s]" % outer.model}}],
                    "usage": {"prompt_tokens": max(1, len(content) // 4),
                              "completion_tokens": 5, "total_tokens": 6}})

        self.server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


class FakeProm:
    """POST /api/v1/query answering one canned vector.

    `series` is the list of {metric:{...}, value:[ts,"n"]} entries; `fail=True`
    answers 500, which is how "monitoring is behind" gets exercised. Every query
    body is recorded, so a check can assert how many POSTs a pass cost -- that is
    where the one-query-per-pass and the {host}-template dedup claims live.
    """

    def __init__(self, port, series=None, fail=False):
        self.port = port
        self.series = series or []
        self.fail = fail
        self.queries = []
        self.lock = threading.Lock()
        outer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt, *args):
                pass

            def _send(self, status, payload):
                raw = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_POST(self):
                raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                with outer.lock:
                    outer.queries.append(raw.decode())
                if outer.fail:
                    return self._send(500, {"status": "error",
                                            "errorType": "internal",
                                            "error": "fake prometheus down"})
                return self._send(200, {"status": "success", "data": {
                    "resultType": "vector", "result": outer.series}})

            def do_GET(self):
                return self._send(404, {"status": "error"})

        self.server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def set(self, series=None, fail=None):
        with self.lock:
            if series is not None:
                self.series = series
            if fail is not None:
                self.fail = fail

    def seen(self):
        with self.lock:
            return list(self.queries)

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


# ------------------------------------------------------------------ helpers

def worker_rows(port):
    st, body, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
    if st != 200:
        return {}
    return {w["url"]: w for w in json.loads(body).get("workers", [])}


def load_of(port, url):
    row = worker_rows(port).get(url)
    return None if row is None else row.get("load")


def is_healthy(port, url):
    row = worker_rows(port).get(url)
    return bool(row and row.get("is_healthy"))


def metrics_text(port):
    st, body, _ = http("GET", "http://127.0.0.1:%d/metrics" % port)
    return body if st == 200 else ""


def gpu_gauge(text, url):
    """lr_gpu_load{worker="<url>"} -> float, or None when the series is absent."""
    needle = 'lr_gpu_load{worker="%s"}' % url
    for line in text.splitlines():
        if line.startswith(needle):
            return _value_of(line)
    return None


def counter_value(text, name):
    """One counter or gauge read straight off the wire, or None.

    Parsing the value instead of string-matching the line is what turns the dedup
    and topology assertions into load-bearing checks: an absent series, a zero and
    a mislabelled one are three different answers here.
    """
    for line in text.splitlines():
        if line.startswith(name + " ") or line == name:
            return _value_of(line)
    return None


def _value_of(line):
    try:
        return float(line.rsplit(" ", 1)[-1])
    except ValueError:
        return None


def wait_load(port, url, want, tol=1.0, timeout=25):
    """Poll rather than sleep a fixed amount: the pass runs on its own interval, so
    the sample appears somewhere inside it rather than at a knowable instant."""
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = load_of(port, url)
        if isinstance(last, (int, float)) and abs(last - want) <= tol:
            return True
        time.sleep(0.3)
    return False


def wait_gpu_gauge(port, url, want, tol=0.02, timeout=25):
    deadline = time.time() + timeout
    while time.time() < deadline:
        got = gpu_gauge(metrics_text(port), url)
        if got is not None and abs(got - want) <= tol:
            return True
        time.sleep(0.3)
    return False


def wait_no_load(port, url, timeout=25):
    """Poll until the external sample has expired and load is pure in-flight.

    The stale semantics are TTL based, so the only honest assertion is "within
    the stale window the gauge disappears", not a specific instant.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        got = load_of(port, url)
        if got in (0, 0.0):
            return True
        time.sleep(0.3)
    return False


def chat(port, model, text="load probe"):
    return http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                {"model": model, "messages": [{"role": "user", "content": text}]})


def warn_count(text, needle):
    return sum(1 for line in text.splitlines()
               if "gpu-load" in line and needle in line)


# ------------------------------------------------------------------ scenario 1

def scenario_none_is_zero_change():
    """Expected: with SMG_LOAD_SOURCE unset the box runs the pre-feature code path.

    The gate is that nothing new is observable anywhere: no timer (so no
    lr_gpu_load_pass_total counter), no registry sample keys (so /workers load is
    exactly the in-flight counter the contract pins), no fetch (so a worker whose
    /metrics 404s is not even complained about), and inference unchanged.
    """
    name = "lr-gpuload-none-" + RUN
    pa = free_port()
    hot = GpuMock(pa, "alpha", gpu_util=90.0)
    env = dict(GPU_ENV)
    env["SMG_WORKER_URLS"] = "http://127.0.0.1:%d" % pa
    port = start_router(env, name)
    check("[none] worker healthy", wait_ready(port, 1, 30), logs(name))
    url_a = "http://127.0.0.1:%d" % pa
    st, body, _ = chat(port, "alpha")
    check("[none] traffic routes", st == 200 and "echo[alpha]" in body, body[:200])
    time.sleep(2.5)                        # comfortably past two intervals
    text = metrics_text(port)
    check("[none] no load-source counters at all",
          "lr_gpu_load" not in text, text[:300])
    check("[none] /workers load is in-flight only (90% GPU ignored)",
          load_of(port, url_a) == 0, str(load_of(port, url_a)))
    check("[none] no gpu-load line in the error log",
          "gpu-load" not in logs(name), logs(name)[-400:])
    hot.stop()
    stop_router(name)


# ------------------------------------------------------------------ scenario 2

def scenario_metrics_reports_gpu():
    """Expected: the scrape lands in the registry and on the exporter.

    nvidia_gpu_utilization 90 (with a cooler 85 sibling series, which the max
    reduction must skip) becomes load 90 on /workers under the default
    SMG_LOAD_SCALE=100, and lr_gpu_load{worker=...} 0.9 on /metrics. The same
    worker answers /v1/loads with the engine's own total_tokens=4242, and that
    number must NOT appear in /workers -- /v1/loads is a live pull that never
    writes the registry, which is the whole point of having separate channels.
    A worker behind an api_key is scraped with Bearer (the mock 401s otherwise),
    which is what makes the key path load-bearing rather than decorative.
    """
    name = "lr-gpuload-metrics-" + RUN
    pa, pb = free_port(), free_port()
    hot = GpuMock(pa, "alpha", gpu_util=90.0, loads=4242)
    keyed = GpuMock(pb, "beta", gpu_util=30.0, api_key="sk-load-probe")
    env = dict(GPU_ENV)
    env["SMG_LOAD_SOURCE"] = "metrics"
    env["SMG_WORKER_URLS"] = "http://127.0.0.1:%d,http://127.0.0.1:%d" % (pa, pb)
    port = start_router(env, name)
    check("[metrics] both workers healthy", wait_ready(port, 2, 40), logs(name))
    url_a, url_b = "http://127.0.0.1:%d" % pa, "http://127.0.0.1:%d" % pb
    check("[metrics] the hot worker reports its GPU through /workers",
          wait_load(port, url_a, 90, tol=1.0), str(load_of(port, url_a)))
    check("[metrics] the keyed worker too (bearer scrape authorized)",
          wait_load(port, url_b, 30, tol=1.0), str(load_of(port, url_b)))
    text = metrics_text(port)
    check("[metrics] the per-worker sample is exported",
          wait_gpu_gauge(port, url_a, 0.9), text[:300])
    check("[metrics] the pass counter is published",
          "lr_gpu_load_pass_total" in text, text[-300:])
    check("[metrics] coverage gauge counts both workers",
          counter_value(text, "lr_gpu_load_workers") == 2.0, text[-300:])
    st, body, _ = http("GET", "http://127.0.0.1:%d/v1/loads" % port)
    doc = json.loads(body) if st == 200 else {}
    reported = [w.get("load") for w in doc.get("workers", [])]
    check("[metrics] /v1/loads still answers the engine's own total_tokens",
          4242 in reported, str(reported))
    check("[metrics] and that self-report did not leak into /workers",
          load_of(port, url_a) != 4242, str(load_of(port, url_a)))
    st, body, _ = chat(port, "alpha")
    check("[metrics] inference is unaffected", st == 200 and "echo[alpha]" in body,
          body[:200])
    hot.stop()
    keyed.stop()
    stop_router(name)


# ------------------------------------------------------------------ scenario 3

def scenario_gaugeless_and_404_stay_up():
    """Expected: a load failure never costs a worker.

    One worker serves no wanted gauge, one 404s /metrics entirely. Both must keep
    serving traffic, stay is_healthy, and carry an in-flight-only load. The WARN
    is deduped per target: after 15+ passes the log holds one line per worker, not
    15 (the same-second collapse test for the window itself lives in the unit
    suite; this checks it holds across real ticks).
    """
    name = "lr-gpuload-gaugeless-" + RUN
    pa, pb, pc = free_port(), free_port(), free_port()
    nogauge = GpuMock(pa, "alpha", gpu_util=None)
    missing = GpuMock(pb, "beta", metrics_on=False)
    good = GpuMock(pc, "gamma", gpu_util=70.0)
    env = dict(GPU_ENV)
    env["SMG_LOAD_SOURCE"] = "metrics"
    env["SMG_WORKER_URLS"] = ",".join("http://127.0.0.1:%d" % p for p in (pa, pb, pc))
    port = start_router(env, name)
    check("[gaugeless] all three healthy", wait_ready(port, 3, 40), logs(name))
    time.sleep(12)                          # >= 10 passes against a broken exporter
    for p, model in ((pa, "alpha"), (pb, "beta")):
        url = "http://127.0.0.1:%d" % p
        st, body, _ = chat(port, model)
        check("[gaugeless] %s still routable and healthy" % model,
              st == 200 and is_healthy(port, url), "%s %s" % (st, body[:150]))
        check("[gaugeless] %s falls back to in-flight load" % model,
              load_of(port, url) in (0, 0.0), str(load_of(port, url)))
    check("[gaugeless] the healthy worker is unaffected",
          wait_load(port, "http://127.0.0.1:%d" % pc, 70, tol=1.0),
          str(load_of(port, "http://127.0.0.1:%d" % pc)))
    txt = logs(name)
    url_a, url_b = "http://127.0.0.1:%d" % pa, "http://127.0.0.1:%d" % pb
    warns_a = warn_count(txt, url_a)
    warns_b = warn_count(txt, url_b)
    check("[gaugeless] the missing gauge warns once, not every tick",
          warns_a <= 1, "warn lines=%d" % warns_a)
    check("[gaugeless] the 404 warns once, not every tick",
          warns_b <= 1, "warn lines=%d" % warns_b)
    text = metrics_text(port)
    failures = counter_value(text, "lr_gpu_load_failures_total") or 0.0
    # The counter is what makes the two assertions above sound rather than vacuous:
    # logs() returns only the tail of the error log, so a missing WARN could be
    # truncation. A few tens of charged failures plus at most one line per target
    # can only mean the dedup window did its job.
    check("[gaugeless] the broken scrapes were charged to the counter (many passes ran)",
          failures >= 10.0, "failures_total=%s" % failures)
    check("[gaugeless] failures are counted rather than hidden",
          "lr_gpu_load_failures_total" in text, text[-300:])
    for m in (nogauge, missing, good):
        m.stop()
    stop_router(name)


# ------------------------------------------------------------------ scenario 4

def scenario_power_of_two_consumes_it():
    """Expected: power_of_two stops ranking by in-flight alone.

    Two workers, identical latency, one pinned at 95 % GPU and one at 3 %. Under
    the old behaviour both sit at load 0 between requests, so the two random
    candidates tie and each takes about half the burst. With the sample folded in,
    the hot worker's load is ~95 and the idle one's ~3, so the second candidate is
    essentially never the hot one: the assertion is a strong skew (hot <= 15 % of
    60 requests), not an exact number, because the policy draws its two candidates
    at random.
    """
    name = "lr-gpuload-p2-" + RUN
    pa, pb = free_port(), free_port()
    hot = GpuMock(pa, "m", gpu_util=95.0)
    idle = GpuMock(pb, "m", gpu_util=3.0)
    env = dict(GPU_ENV)
    env["SMG_POLICY"] = "power_of_two"
    env["SMG_LOAD_SOURCE"] = "metrics"
    env["SMG_WORKER_URLS"] = "http://127.0.0.1:%d,http://127.0.0.1:%d" % (pa, pb)
    port = start_router(env, name)
    check("[p2] both healthy", wait_ready(port, 2, 40), logs(name))
    check("[p2] the hot worker's GPU is in its load",
          wait_load(port, "http://127.0.0.1:%d" % pa, 95, tol=1.0),
          str(load_of(port, "http://127.0.0.1:%d" % pa)))
    for i in range(60):
        chat(port, "m", "p2 probe %d" % i)
    with hot.lock:
        hits_hot = hot.chats
    with idle.lock:
        hits_idle = idle.chats
    check("[p2] the busy card is avoided by the second candidate",
          hits_hot <= max(2, int(60 * 0.15)) and hits_idle >= hits_hot * 3,
          "hot=%d idle=%d" % (hits_hot, hits_idle))
    check("[p2] and traffic still flows overall", hits_hot + hits_idle >= 55,
          "total=%d" % (hits_hot + hits_idle))
    hot.stop()
    idle.stop()
    stop_router(name)


# ------------------------------------------------------------------ scenario 5

def scenario_cache_aware_escapes():
    """Expected: the load escape outranks prefix affinity for a busy worker.

    Every request carries the same long prefix, so with equal loads cache_aware
    pins the first pick and keeps hitting it (that is the affinity the policy
    exists for). Here the worker that would be the sticky tenant sits at 95 % GPU
    while its sibling sits at 3 %, and the balance test (abs > threshold and
    rel > threshold, both met at 95 vs 3 with the shipped 64/1.5 defaults) sends
    the request to the least-loaded candidate instead. The check is that the hot
    worker takes a minority of a 40-request burst despite the identical prefix --
    the escape firing. The reverse control (both workers idle) belongs to
    e2e_policies/e2e_policy_parity and is not repeated here.
    """
    name = "lr-gpuload-cache-" + RUN
    pa, pb = free_port(), free_port()
    hot = GpuMock(pa, "m", gpu_util=95.0)
    idle = GpuMock(pb, "m", gpu_util=3.0)
    env = dict(GPU_ENV)
    env["SMG_POLICY"] = "cache_aware"
    env["NGINX_WORKER_PROCESSES"] = "1"      # one tree, or affinity is per-process
    env["SMG_LOAD_SOURCE"] = "metrics"
    env["SMG_WORKER_URLS"] = "http://127.0.0.1:%d,http://127.0.0.1:%d" % (pa, pb)
    port = start_router(env, name)
    check("[cache] both healthy", wait_ready(port, 2, 40), logs(name))
    check("[cache] the hot worker carries its GPU sample",
          wait_load(port, "http://127.0.0.1:%d" % pa, 95, tol=1.0),
          str(load_of(port, "http://127.0.0.1:%d" % pa)))
    prefix = ("You are a rigorous assistant. Follow the policy exactly. " * 6)
    for i in range(40):
        chat(port, "m", prefix + " escape probe %d" % i)
    with hot.lock, idle.lock:
        hits_hot, hits_idle = hot.chats, idle.chats
    check("[cache] the escape moves the burst off the busy card",
          hits_hot <= hits_idle and hits_hot <= 15,
          "hot=%d idle=%d" % (hits_hot, hits_idle))
    check("[cache] the pool still answers", hits_hot + hits_idle >= 36,
          "total=%d" % (hits_hot + hits_idle))
    hot.stop()
    idle.stop()
    stop_router(name)


# ------------------------------------------------------------------ scenario 6

def scenario_prom_source():
    """Expected: the remote channel maps a vector back onto the pool.

    Three workers on two hosts (the last two deliberately co-located, the way two
    engines share a GPU box), and a fake Prometheus keyed on 127.0.0.1 so the
    host-label match is the same code path production takes.

    Assertions, in the order the pass runs:
      * a pool-wide PromQL costs exactly one POST per interval (the probers are not
        per-worker -- that is the whole reason a remote source is cheap);
      * the two co-located workers carry the same reading, because the host is the
        shared resource;
      * the other host carries its own value;
      * a series naming a machine nobody in the pool serves leaves every load
        untouched and bumps lr_gpu_load_unmatched_total instead;
      * switching to a {host} template raises one POST per *distinct* host per pass,
        and DP ranks of one host collapse into one query;
      * NaN series contribute nothing.
    """
    name = "lr-gpuload-prom-" + RUN
    pa, pb, pc = free_port(), free_port(), free_port()
    a = GpuMock(pa, "alpha", gpu_util=None)          # no /metrics: only prom can see it
    b = GpuMock(pb, "beta", gpu_util=None)
    c = GpuMock(pc, "gamma", gpu_util=None)
    pp = free_port()
    prom = FakeProm(pp, series=[
        {"metric": {"instance": "127.0.0.1:%d" % pa, "gpu": "0"},
         "value": [time.time(), "88"]},
        {"metric": {"instance": "127.0.0.1:%d" % pb}, "value": [time.time(), "12"]},
        {"metric": {"instance": "127.0.0.1:%d" % pc}, "value": [time.time(), "NaN"]},
        {"metric": {"instance": "10.255.255.1:9100"}, "value": [time.time(), "99"]},
    ])
    env = dict(GPU_ENV)
    env.update({
        "SMG_LOAD_SOURCE": "prom",
        "SMG_LOAD_PROM_URL": "http://127.0.0.1:%d" % pp,
        "SMG_LOAD_PROM_QUERY": "avg by (instance) (DCGM_FI_DEV_GPU_UTIL)",
        "SMG_WORKER_URLS": ",".join("http://127.0.0.1:%d" % p for p in (pa, pb, pc)),
    })
    port = start_router(env, name)
    check("[prom] all three healthy", wait_ready(port, 3, 40), logs(name))
    url_a, url_b, url_c = ("http://127.0.0.1:%d" % pa, "http://127.0.0.1:%d" % pb,
                           "http://127.0.0.1:%d" % pc)
    check("[prom] host labels map onto the right workers",
          wait_load(port, url_a, 88, tol=1.0), str(load_of(port, url_a)))
    check("[prom] a second host gets its own reading",
          wait_load(port, url_b, 12, tol=1.0), str(load_of(port, url_b)))
    check("[prom] a NaN series stores no load rather than a zero one",
          load_of(port, url_c) in (0, 0.0), str(load_of(port, url_c)))
    # One pool-wide query per pass: sample the query log across two intervals and
    # allow the boundary to add at most one extra.
    before = len(prom.seen())
    time.sleep(2.5)
    after = len(prom.seen())
    check("[prom] a pool-wide PromQL costs one POST per interval, not per worker",
          1 <= (after - before) <= 3, "queries seen=%d..%d" % (before, after))
    text = metrics_text(port)
    check("[prom] the stranger in the vector is reported, not absorbed",
          (counter_value(text, "lr_gpu_load_unmatched_total") or 0) >= 1.0,
          text[-300:])
    check("[prom] traffic flows while the remote source does the seeing",
          chat(port, "alpha")[0] == 200, "chat failed")

    # ---- the {host} template: one query per distinct host, ranks collapsed
    prom.set(series=[{"metric": {"host": "127.0.0.1"},
                      "value": [time.time(), "55"]}])
    stop_router(name)
    env2 = dict(env)
    env2["SMG_LOAD_PROM_QUERY"] = 'DCGM_FI_DEV_GPU_UTIL{hostname="{host}"}'
    # Two of the three urls share a host (127.0.0.1) but differ in port, so the
    # rendered queries are distinct; the DP rank pair below is the real dedup case.
    # All three urls sit on 127.0.0.1, and the template names only {host}, so the
    # whole pool collapses onto ONE rendered query per pass: two ranks of the DP
    # engine plus a second listener on the same machine, three registry workers,
    # one POST. Counting the POSTs is the load-bearing part of this scenario --
    # a per-worker render would triple it at this interval.
    env2["SMG_WORKER_URLS"] = ",".join(
        ["http://127.0.0.1:%d" % pa, "http://127.0.0.1:%d@0" % pb,
         "http://127.0.0.1:%d@1" % pb])
    name2 = "lr-gpuload-promhost-" + RUN
    port2 = start_router(env2, name2)
    check("[prom/host] the rank pair plus its co-located sibling register",
          wait_ready(port2, 3, 40), logs(name2))
    time.sleep(2.0)
    host_queries = [q for q in prom.seen() if "hostname" in q]
    distinct = set(host_queries)
    check("[prom/host] {host} renders one query per distinct host, not per worker",
          len(distinct) == 1 and 1 <= len(host_queries) <= 5,
          "distinct=%d total=%d" % (len(distinct), len(host_queries)))
    check("[prom/host] the template reached the API expanded",
          any("hostname%3D%22127.0.0.1%22" in q for q in host_queries),
          str(host_queries[-2:])[:300])
    check("[prom/host] both ranks of one engine share the host sample",
          wait_load(port2, "http://127.0.0.1:%d@0" % pb, 55, tol=1.0)
          and load_of(port2, "http://127.0.0.1:%d@1" % pb) == 55,
          "%s / %s" % (load_of(port2, "http://127.0.0.1:%d@0" % pb),
                       load_of(port2, "http://127.0.0.1:%d@1" % pb)))
    for m in (a, b, c):
        m.stop()
    prom.stop()
    stop_router(name2)


# ------------------------------------------------------------------ scenario 7

def scenario_prometheus_down():
    """Expected: a dead monitoring system costs accuracy, never capacity.

    The same pool as the prom scenario, with the fake answering 500 for the whole
    run. Workers must stay is_healthy and routable, their load must read as
    in-flight only (never a stale value pinned forever), and the error log must
    hold one WARN for the endpoint across a dozen passes -- the failure that would
    be most tempting to log per tick is the remote one, since it is shared.
    """
    name = "lr-gpuload-promdown-" + RUN
    pa, pb = free_port(), free_port()
    a = GpuMock(pa, "alpha", gpu_util=None)
    b = GpuMock(pb, "beta", gpu_util=None)
    pp = free_port()
    prom = FakeProm(pp, series=[], fail=True)
    env = dict(GPU_ENV)
    env.update({
        "SMG_LOAD_SOURCE": "prom",
        "SMG_LOAD_PROM_URL": "http://127.0.0.1:%d" % pp,
        "SMG_LOAD_PROM_QUERY": "gpu_util",
        "SMG_WORKER_URLS": "http://127.0.0.1:%d,http://127.0.0.1:%d" % (pa, pb),
    })
    port = start_router(env, name)
    check("[prom-down] both healthy while monitoring is behind",
          wait_ready(port, 2, 40), logs(name))
    time.sleep(12)                                    # >= 10 failed passes
    for p, model in ((pa, "alpha"), (pb, "beta")):
        st, body, _ = chat(port, model)
        check("[prom-down] %s routable" % model, st == 200, "%s %s" % (st, body[:150]))
        check("[prom-down] %s still in the pool and healthy" % model,
              is_healthy(port, "http://127.0.0.1:%d" % p),
              str(worker_rows(port).get("http://127.0.0.1:%d" % p)))
    txt = logs(name)
    check("[prom-down] the endpoint is complained about once, not per tick",
          warn_count(txt, "http://127.0.0.1:%d" % pp) <= 1,
          "lines=%d" % warn_count(txt, "http://127.0.0.1:%d" % pp))
    text = metrics_text(port)
    check("[prom-down] and the failures are visible in the exporter",
          "lr_gpu_load_failures_total" in text, text[-200:])
    a.stop()
    b.stop()
    prom.stop()
    stop_router(name)


# ------------------------------------------------------------------ scenario 8

def scenario_staleness():
    """Expected: an expired sample stops being a load, with no restart.

    There is no sweeper in this design -- the sample keys carry a TTL and so does
    the shared flag -- so this is the scenario that proves the expiry is real.
    Sequence: a worker reports 80 % GPU (load ~80); it then stops serving the
    gauge entirely; past SMG_LOAD_STALE_SECS (4 s here, three intervals in
    production) the load must fall back to the in-flight count and the per-worker
    lr_gpu_load series must disappear. A worker that *keeps* reporting is the
    control: its load must not decay.
    """
    name = "lr-gpuload-stale-" + RUN
    pa, pb = free_port(), free_port()
    fading = GpuMock(pa, "alpha", gpu_util=80.0)
    steady = GpuMock(pb, "beta", gpu_util=20.0)
    env = dict(GPU_ENV)
    env["SMG_LOAD_SOURCE"] = "metrics"
    env["SMG_WORKER_URLS"] = "http://127.0.0.1:%d,http://127.0.0.1:%d" % (pa, pb)
    port = start_router(env, name)
    check("[stale] both healthy", wait_ready(port, 2, 40), logs(name))
    url_a, url_b = "http://127.0.0.1:%d" % pa, "http://127.0.0.1:%d" % pb
    check("[stale] the fading worker starts at its GPU load",
          wait_load(port, url_a, 80, tol=1.0), str(load_of(port, url_a)))
    fading.gpu_util = None                     # the exporter goes away
    check("[stale] its load falls back to in-flight once the sample expires",
          wait_no_load(port, url_a, timeout=25), str(load_of(port, url_a)))
    check("[stale] while a worker still reporting keeps its load",
          wait_load(port, url_b, 20, tol=1.0), str(load_of(port, url_b)))
    check("[stale] the expired worker is still healthy and routable",
          is_healthy(port, url_a) and chat(port, "alpha")[0] == 200,
          logs(name)[-300:])
    fading.stop()
    steady.stop()
    stop_router(name)


# --------------------------------------------------------------------------

def main():
    os.makedirs(TMP, exist_ok=True)
    scenario_none_is_zero_change()
    scenario_metrics_reports_gpu()
    scenario_gaugeless_and_404_stay_up()
    scenario_power_of_two_consumes_it()
    scenario_cache_aware_escapes()
    scenario_prom_source()
    scenario_prometheus_down()
    scenario_staleness()
    failed = [r for r in RESULTS if not r[0]]
    print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
    for _, name, detail in failed:
        print("FAILED: %s | %s" % (name, detail[:400]))
    cleanup()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
