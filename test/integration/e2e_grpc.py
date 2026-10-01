#!/usr/bin/env python3
"""End-to-end checks for the lua-router gRPC / PD plane (real nginx, real grpcio).

Topology, all on the host network:

    grpc client --:SMG_GRPC_PORT--> [router: grpc_proxy.route -> grpc_pass] --grpc(s)--> mock workers

The mocks need no .proto (fixtures/mock_grpc_server.py registers probe.Echo with
identity serializers, because grpc_pass forwards HTTP/2 frames without ever
decoding a message), and each one stamps its own id into the echo body through the
LR_MOCK_ID environment, so "which worker served this call" is observable from the
client -- that is what the load-balancing, model-steering and failover checks read.

Groups, in run order:
  1. registration gate with the plane ON: prefill/decode and grpc/grpcs accepted,
     unknown enum values and a grpc mode with no port still 400;
  2. unary, metadata pass-through, server-streaming pacing, grpc-status and
     custom trailer pass-through, long call surviving the 1800 s cap;
  3. round_robin across two plain grpc workers, and model steering by
     x-smg-model (the proxy never *reads* a body -- it only injects field 10 -- so
     metadata is still the model carrier);
  4. health: kill one worker's HTTP /health face and watch the pool converge;
  5. grpcs (TLS, self-signed) worker through the same listener;
  6. breaker: kill the grpc port of a probe-disabled worker, calls fail, the
     circuit opens, and the plane answers UNAVAILABLE instead of hanging;
  7. PD: two pools, /readiness requires both, pair selection publishes the
     bootstrap triple + decode peer as metadata, room fits int32, a dead decode
     pool answers UNAVAILABLE;
  8. HTTP plane untouched: chat still balances only over http+regular workers;
  9. a second router with SMG_GRPC_POLICY=sticky and a 2 s cap: sticky key ->
     stable worker, and the router-computed deadline bites a 7 s call.
 10. PD *native proto body* carrier (the default): the mock parses the request as
     a real GenerateRequest and reports DisaggregatedParams field 10 -- the
     bootstrap triple lands in fields 1/2/3, the decode peer in router extensions
     101/102(/103 for a DP-aware prefill url), the client's other fields (two of
     them unknown to the schema) survive byte for byte, a duplicated field 10 is
     collapsed rather than merged, and a >4 MB body that nginx spilled to a temp
     file is still rewritten while one over the injector cap falls back.
 11. `LR_GRPC_PD_METADATA=on`: the pre-codec behaviour verbatim -- metadata
     published and the body untouched, not even a field 10 on Generate.
 12. `LR_GRPC_PD_METADATA=off`: neither carrier, pure forwarding.

Run: python3 test/integration/e2e_grpc.py
Requires the image built (final_gates.sh `build` gate) and grpcio on the host.
"""
import json, os, re, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (free_port, http, check, start_router, logs, stop_router,
                  cleanup, RESULTS, RUN, IMAGE)
import grpc
import re  # noqa: E402  (pool_sizes reads labels with it)

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "fixtures", "mock_grpc_server.py")
TMP = os.environ.get("LR_TEST_TMP", "/data/tmp/lr")
os.makedirs(TMP, exist_ok=True)

MOCKS = {}          # id -> {"p": subprocess, "grpc": port, "http": health port}


def start_mock(mid, grpc_port, health_port=0, tls_port=0):
    env = dict(os.environ, LR_MOCK_ID=mid)
    if tls_port:
        env["LR_TLS_CERT"] = os.path.join(HERE, "fixtures", "tls", "server.crt")
        env["LR_TLS_KEY"] = os.path.join(HERE, "fixtures", "tls", "server.key")
    log = open("%s/e2e-grpc-mock-%s.log" % (TMP, mid), "w")
    argv = [sys.executable, FIXTURE, "--port", str(grpc_port)]
    if health_port:
        argv += ["--health-port", str(health_port)]
    if tls_port:
        argv += ["--tls-port", str(tls_port)]
    MOCKS[mid] = {"p": subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT,
                                        env=env),
                  "grpc": grpc_port, "http": health_port, "tls": tls_port}
    return MOCKS[mid]


def mock_ready(mid, timeout=12):
    import socket
    m = MOCKS[mid]
    ports = [m["grpc"]] + ([m["http"]] if m["http"] else []) + ([m["tls"]] if m["tls"] else [])
    for port in ports:
        for _ in range(int(timeout / 0.2) * 2):
            try:
                s = socket.create_connection(("127.0.0.1", port), timeout=0.5)
                s.close()
                break
            except OSError:
                time.sleep(0.2)
        else:
            raise RuntimeError("mock %s port %d never came up" % (mid, port))


def kill_mock(mid):
    MOCKS[mid]["p"].terminate()
    MOCKS[mid]["p"] = subprocess.Popen([sys.executable, "-c", "pass"],
                                       stdout=subprocess.DEVNULL)


def chan(port):
    return grpc.insecure_channel("127.0.0.1:%d" % port)


def method(channel, path, streaming=False):
    if streaming:
        return channel.unary_stream(path, request_serializer=lambda b: b,
                                    response_deserializer=lambda b: b)
    return channel.unary_unary(path, request_serializer=lambda b: b,
                               response_deserializer=lambda b: b)


def call(channel, path, payload=b"x", md=(), timeout=8):
    """Returns (ok, body, error, trailing_metadata).

    with_call is its own method on the multi-callable (not a keyword of __call__),
    and the trailing metadata - where a gRPC client reads grpc-status - is only
    reachable through that call object.
    """
    try:
        body, call_state = method(channel, path).with_call(
            payload, metadata=md or (), timeout=timeout)
        trailing = tuple(call_state.trailing_metadata() or ())
        return True, body, None, trailing
    except grpc.RpcError as exc:
        return False, None, exc, tuple(exc.trailing_metadata() or ())


def body_field(body, name):
    """Pull `|name=value` out of the echo body the mock builds."""
    if not body:
        return None
    text = body.decode("utf-8", "replace")
    for chunk in text.split("|"):
        key, _, value = chunk.partition("=")
        if key == name:
            return value
    # metadata dump: |md=k=v;k2=v2
    marker = "|md="
    i = text.find(marker)
    if i >= 0:
        for pair in text[i + len(marker):].split(";"):
            key, _, value = pair.partition("=")
            if key == name:
                return value
    return None


GEN_PATH = "/sglang.grpc.scheduler.SglangScheduler/Generate"


def gen_request_bytes(request_id):
    """A GenerateRequest built *outside* the router, so the rewrite is tested
    against a message the router's codec had no part in writing.

    Layout (vendored sglang_scheduler.proto field numbers): 1 request_id string,
    4 sampling_params message, then two fields the router does not know (20
    fixed64, 21 length-delimited) that must survive the rewrite verbatim.
    """
    def varint(n):
        out = bytearray()
        while True:
            b = n & 0x7F
            n >>= 7
            out.append(b | (0x80 if n else 0))
            if not n:
                return bytes(out)

    def tag(field, wire):
        return varint(field * 8 + wire)

    def sfield(field, payload):
        return tag(field, 2) + varint(len(payload)) + payload
    rid = request_id.encode()
    return (sfield(1, rid)
            + sfield(4, b"\x0d\x00\x00\x80?")              # temperature = 1.0
            + tag(20, 1) + b"12345678"                        # unknown fixed64
            + sfield(21, b"keepme"))                          # unknown string


def generate(channel, payload=b"", md=(), timeout=8):
    """Call sglang's real Generate method: unary request, *streaming* response.

    The request body is the one the router rewrites in PD body mode, so this is
    the only way to see what the prefill worker actually parsed. Returns the
    first streamed chunk (the mock reports its verdict there).
    """
    try:
        stream = method(channel, GEN_PATH, streaming=True)(
            payload, metadata=md or (), timeout=timeout)
        return True, next(iter(stream), None), None
    except grpc.RpcError as exc:
        return False, None, exc


def body_fields(body, name):
    """Every `|name=value` in the mock's echo body, in order.

    Repeated protobuf fields are reported as repeated `|pb-keepNN=` markers, and
    body_field returns only the first, which is exactly the wrong thing when the
    point of a check is which of two same-numbered fields arrived.
    """
    if not body:
        return []
    text = body.decode("utf-8", "replace")
    needle = "|" + name + "="
    return [chunk[len(needle) - 1:] if chunk.startswith(needle[1:]) else chunk
            for chunk in text.split("|") if chunk.startswith(needle[1:])]


def grpc_status_of(exc):
    try:
        return exc.code()
    except Exception:  # noqa
        return None


def register(port, body):
    return http("POST", "http://127.0.0.1:%d/workers" % port, body)


def workers(port):
    st, b, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
    return json.loads(b) if st == 200 else {"workers": []}


def worker_by_url(port, needle):
    for w in workers(port).get("workers", []):
        if needle in (w.get("url") or ""):
            return w
    return None


def port_refused(port, timeout=10):
    """True once nothing accepts connections on `port` any more."""
    import socket
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=0.5)
        except OSError:
            return True
        s.close()
        time.sleep(0.2)
    return False


def cb_state_of(port, needle):
    """Breaker gauge for one worker from /metrics (0 closed, 1 open, 2 half_open)."""
    st, body, _ = http("GET", "http://127.0.0.1:%d/metrics" % port, timeout=5)
    if st != 200:
        return None
    for line in body.splitlines():
        if line.startswith("smg_worker_cb_state{") and needle in line:
            return int(float(line.rsplit(" ", 1)[-1]))
    return None


def pool_sizes(port):
    """smg_worker_pool_size as {(worker_type, connection_mode, model): size}."""
    st, body, _ = http("GET", "http://127.0.0.1:%d/metrics" % port, timeout=5)
    if st != 200:
        return None
    out = {}
    for line in body.splitlines():
        if not line.startswith("smg_worker_pool_size{"):
            continue
        labels = line[line.index("{") + 1:line.index("}")]
        value = float(line.rsplit(" ", 1)[-1])
        parts = dict(re.findall(r'(\w+)="([^"]*)"', labels))
        key = (parts.get("worker_type"), parts.get("connection_mode"), parts.get("model"))
        out[key] = int(value)
    return out


def wait_pool_sizes(port, want, timeout=30):
    for _ in range(int(timeout / 0.5)):
        if pool_sizes(port) == want:
            return True
        time.sleep(0.5)
    return False


def expected_pool(doc):
    """The pool series Rust would export for a /workers document: one row per
    unique (worker_type, connection_mode, model) triple, with grpcs folded onto
    grpc the way ConnectionMode::as_metric_label does (worker.rs:452).

    Derived from /workers instead of written out because the metadata sweep can
    replace a registered model_id with what the engine reports, and the census
    must be compared against the same registry view the exporter read.
    """
    want = {}
    for w in doc.get("workers", []):
        mode = str(w.get("connection_mode") or "http")
        if mode == "grpcs":
            mode = "grpc"
        key = (str(w.get("worker_type")), mode, str(w.get("model_id")))
        want[key] = want.get(key, 0) + 1
    return want


def pool_dump(d):
    """Render a pool census ({(type, mode, model): n}) as JSON.

    The tuple keys need flattening: json.dumps raises TypeError on them, and a
    detail argument that throws takes the whole suite down at the first check
    that has to report."""
    if not isinstance(d, dict):
        return repr(d)
    return json.dumps(["%s/%s/%s=%d" % (k[0], k[1], k[2], v)
                       for k, v in sorted(d.items())])


def wait_pool_matches_workers(port, timeout=45):
    """Poll until the exported census equals a back-to-back /workers read.

    Both sides are read per attempt: a model_id rewritten by the metadata sweep
    between two reads would otherwise be reported as a broken gauge."""
    for _ in range(int(timeout / 0.5)):
        want = expected_pool(workers(port))
        got = pool_sizes(port)
        if got and want and got == want:
            return got
        time.sleep(0.5)
    return pool_sizes(port)


def wait_workers(port, predicate, want, timeout=60):
    for _ in range(int(timeout / 0.5)):
        if sum(1 for w in workers(port).get("workers", []) if predicate(w)) >= want:
            return True
        time.sleep(0.5)
    return False


# ------------------------------------------------------------------ topology
# Every port is allocated once and used for exactly one purpose. The health
# listener of a worker that also serves gRPC has to be a *different* port: the
# grpc server binds the gRPC port, and the gRPC record url has to name the health
# port (that is the only face the probe can speak), so reusing one number for both
# would either fail the bind or make the probe dial a gRPC port with HTTP/1.1.
PA = free_port(); HA = free_port()          # plain grpc worker A (bare grpc://, unprobed)
PB = free_port(); HB = free_port()          # plain grpc worker B (http url + tagged grpc)
PPF = free_port(); HPF = free_port()        # prefill worker (same split)
PDEC = free_port(); HDEC = free_port()        # decode worker (probed on HDEC, served on PDEC)
PTLS = free_port(); PTLS_D = free_port()    # TLS worker: grpc + grpc(s) target
P_HTTP = free_port()                        # an HTTP+regular worker, for the no-regression face

start_mock("A", PA, health_port=HA)
start_mock("B", PB, health_port=HB)
start_mock("PF", PPF, health_port=HPF)
start_mock("DEC", PDEC, health_port=HDEC)
start_mock("TLS", PTLS, tls_port=PTLS_D)
for mid in ("A", "B", "PF", "DEC", "TLS"):
    mock_ready(mid)

# A real HTTP worker so the inference plane is exercised against a live backend.
http_mock_log = open("%s/e2e-grpc-httpmock.log" % TMP, "w")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
http_proc = subprocess.Popen(
    [sys.executable, os.path.join(REPO, "test/mock_llm_worker.py"),
     "--host", "0.0.0.0", "--port", str(P_HTTP), "--model", "http-model"],
    stdout=http_mock_log, stderr=subprocess.DEVNULL)

GRPC_PORT = free_port()
port = start_router({
    "SMG_GRPC_PORT": str(GRPC_PORT),
    "SMG_GRPC_POLICY": "round_robin",
    "SMG_POLICY": "round_robin",
    "SMG_HEALTH_CHECK_INTERVAL_SECS": "2",
    "SMG_HEALTH_SUCCESS_THRESHOLD": "1",
    "SMG_HEALTH_FAILURE_THRESHOLD": "2",
    "SMG_CB_FAILURE_THRESHOLD": "3",
    "SMG_CB_TIMEOUT_DURATION_SECS": "60",
    "SMG_REQUEST_TIMEOUT_SECS": "1800",
}, "lr-grpc-%s" % RUN)
name = "lr-grpc-%s" % RUN
print("router http=:%d grpc=:%d" % (port, GRPC_PORT))

# ---------------------------------------------------- 1. registration gate
st, b, _ = register(port, {"url": "grpc://127.0.0.1:%d" % PA, "model_id": "rr-model"})
check("[gate] bare grpc:// registration accepted with the plane on (202)", st == 202,
      "%s %s" % (st, b))
st, b, _ = register(port, {"url": "http://127.0.0.1:%d" % HB,
                           "connection_mode": {"type": "grpc", "port": PB},
                           "model_id": "rr-model"})  # probed on HB, served on PB
check("[gate] tagged grpc mode with an explicit port accepted (202)", st == 202,
      "%s %s" % (st, b))
st, b, _ = register(port, {"url": "http://127.0.0.1:%d" % HPF,
                           "worker_type": "prefill",
                           "connection_mode": {"type": "grpc", "port": PPF},
                           "labels": {"bootstrap_port": "8998"},
                           "model_id": "pd-model"})
check("[gate] prefill worker accepted (202)", st == 202, "%s %s" % (st, b))
st, b, _ = register(port, {"url": "http://127.0.0.1:%d" % HDEC,
                           "worker_type": "decode",
                           "connection_mode": {"type": "grpc", "port": PDEC},
                           "model_id": "pd-model"})
check("[gate] decode worker accepted (202)", st == 202, "%s %s" % (st, b))
st, b, _ = register(port, {"url": "grpc://127.0.0.1:%d" % PDEC, "worker_type": "prefill"})
check("[gate] a bare grpc:// PD worker is 400 (no probeable face => readiness could "
      "never judge the pool)", st == 400, "%s %s" % (st, b))
st, b, _ = register(port, {"url": "grpcs://127.0.0.1:%d" % PTLS_D,
                           "model_id": "tls-model"})
check("[gate] grpcs worker accepted (202)", st == 202, "%s %s" % (st, b))
st, b, _ = register(port, {"url": "http://127.0.0.1:%d" % P_HTTP,
                           "model_id": "http-model"})
check("[gate] http worker accepted (202)", st == 202, "%s %s" % (st, b))

st, b, _ = register(port, {"url": "http://127.0.0.1:1", "worker_type": "wizard"})
check("[gate] unknown worker_type is 400 even with the plane on", st == 400,
      "%s %s" % (st, b))
st, b, _ = register(port, {"url": "http://127.0.0.1:1",
                           "connection_mode": {"type": "carrier-pigeon"}})
check("[gate] unknown connection_mode is 400 even with the plane on", st == 400,
      "%s %s" % (st, b))
st, b, _ = register(port, {"url": "http://127.0.0.1:1", "connection_mode": {"type": "grpc"}})
check("[gate] grpc mode with no port anywhere is 400", st == 400, "%s %s" % (st, b))
st, b, _ = register(port, {"url": "grpc://127.0.0.1:1", "worker_type": "decode",
                           "bootstrap_port": 8998})
check("[gate] bootstrap_port on a decode worker is 400 (Rust type carries none)",
      st == 400, "%s %s" % (st, b))

doc = workers(port)
modes = {}
types = {}
for w in doc.get("workers", []):
    modes[str(w.get("connection_mode"))] = modes.get(str(w.get("connection_mode")), 0) + 1
    types[str(w.get("worker_type"))] = types.get(str(w.get("worker_type")), 0) + 1
check("[registry] grpc modes reported (4 grpc + 1 grpcs + 1 http)",
      modes.get("grpc", 0) == 4 and modes.get("grpcs", 0) == 1
      and modes.get("http", 0) == 1, json.dumps(modes))
check("[registry] worker types reported (2 prefill? no: 1 prefill, 1 decode)",
      types.get("prefill", 0) == 1 and types.get("decode", 0) == 1
      and types.get("regular", 0) == 4, json.dumps(types))

# smg_worker_pool_size is the family a PD dashboard is built on, and before the
# C1 fix it was one aggregate row per worker_type with prefill/decode hardcoded
# to 0 -- a fleet with a live PD pool therefore looked like a dead one. Now every
# unique (worker_type, connection_mode, model) triple out of lr_workers gets its
# own series, grpcs shares the grpc label, and nothing is rendered for a
# combination with no workers.
got_pool = wait_pool_matches_workers(port)
check("[metrics] pool size is one series per registered worker_type/connection_mode/model",
      got_pool == expected_pool(workers(port)),
      "got %s want %s" % (pool_dump(got_pool),
                          pool_dump(expected_pool(workers(port)))))
check("[metrics] the census covers all four combinations this fleet has",
      isinstance(got_pool, dict)
      and any(k[0] == "prefill" for k in got_pool) and any(k[0] == "decode" for k in got_pool)
      and any(k[0] == "regular" and k[1] == "grpc" for k in got_pool)
      and any(k[0] == "regular" and k[1] == "http" for k in got_pool), pool_dump(got_pool))
check("[metrics] grpcs collapses into the grpc label",
      isinstance(got_pool, dict) and not any(k[1] == "grpcs" for k in got_pool),
      pool_dump(got_pool))
st, text, _ = http("GET", "http://127.0.0.1:%d/metrics" % port, timeout=5)
series = [line for line in text.splitlines() if line.startswith("smg_worker_pool_size{")]
check("[metrics] exactly one series per registered combination, none invented",
      len(series) == len(got_pool or {}) and 'worker_type="prefill"' in text
      and 'worker_type="decode"' in text, "\n".join(series) or text[-200:])

grpc_workers = [w for w in doc["workers"]
                if str(w.get("connection_mode")).lower().startswith("grpc")]
check("[health] every grpc worker becomes selectable (probeless or via its http face)",
      wait_workers(port, lambda w: str(w.get("connection_mode", "")).lower().startswith("grpc")
                   and w.get("is_healthy"), 5, timeout=45),
      json.dumps([{k: w.get(k) for k in ("url", "is_healthy", "connection_mode")}
                  for w in grpc_workers]))

client = chan(GRPC_PORT)
say = lambda payload=b"x", md=(), timeout=8: call(client, "/probe.Echo/Say", payload, md, timeout)

# ------------------------------------------------------------ 2. core proxies
ok, body, err, _ = say(b"hello", (("x-custom-md", "abc123"), ("authorization", "Bearer tok123")))
check("[unary] Say returns 200 through grpc_pass", ok, str(err))
check("[unary] echo body intact", ok and body.startswith(b"echo:hello"), str(body)[:80])
check("[unary] client metadata forwarded", ok and body_field(body, "auth") == "Bearer tok123"
      and body_field(body, "xcustom") == "abc123", str(body)[:200])
check("[unary] router stamped the selected worker", ok and body_field(body, "x-lr-worker")
      not in (None, ""), str(body)[:250])

t0 = time.time()
stamps = []
try:
    it = method(client, "/probe.Echo/Tell", streaming=True)(b"3", timeout=10)
    for chunk in it:
        stamps.append(time.time() - t0)
    streamed, err = len(stamps) == 3, None
except grpc.RpcError as exc:
    streamed, err = False, exc
paced = (stamps[-1] - stamps[0]) if len(stamps) > 1 else 0
check("[stream] server-streaming delivered three chunks", streamed, str(err))
check("[stream] streaming is paced, not buffered (>=0.55s for 3 x 0.3s)", paced >= 0.55,
      "%.3fs gaps=%s" % (paced, [round(x, 3) for x in stamps]))

ok, _, err, _ = call(client, "/probe.Echo/Fail")
check("[status] NOT_FOUND survives the proxy (not rewritten to 502)",
      (not ok) and grpc_status_of(err) == grpc.StatusCode.NOT_FOUND, str(err))

ok, _, err, trailing = call(client, "/probe.Echo/Trailers")
names = [k for k, _ in trailing]
check("[trailer] custom trailing metadata reaches the client",
      "x-custom-trailer" in names, str(trailing))

ok, _, err, _ = call(client, "/probe.Echo/Slow", b"x", (), timeout=12)
check("[timeout] 7 s call survives the 1800 s router cap", ok, str(err))

# --------------------------------------------- 3. balancing + model steering
picks = []
for _ in range(8):
    ok, body, err, _ = say(b"rr", (("x-smg-model", "rr-model"),))
    if not ok:
        break
    picks.append(body_field(body, "self"))
counts = {m: picks.count(m) for m in set(picks)}
check("[lb] round_robin spreads across both plain grpc workers",
      len(picks) == 8 and counts.get("A", 0) >= 3 and counts.get("B", 0) >= 3,
      str(picks))

ok, body, err, _ = say(b"m", (("x-smg-model", "tls-model"),))
check("[model] x-smg-model steers to the model's worker",
      ok and body_field(body, "self") == "TLS", str(body)[:120] or str(err))
ok, body, err, _ = say(b"m", (("x-smg-model", "pd-model"),))
check("[model] a PD model's call lands on its prefill worker",
      ok and body_field(body, "self") == "PF", str(body)[:120] or str(err))

# -------------------------------------------------------------- 4. TLS worker
ok, body, err, _ = say(b"tls?", (("x-smg-model", "tls-model"),))
check("[tls] grpcs worker answers through the same listener",
      ok and b"echo:tls?" in (body or b""), str(err))

# ------------------------------------------------- 5. health-driven failover
# B keeps its HTTP /health face; killing it must drop it out of the pool.
kill_mock("B")
gone = wait_workers(port, lambda w: ":%d" % HB in (w.get("url") or "")
                    and not w.get("is_healthy"), 1, timeout=45)
check("[failover] dead worker's health flips to false", gone,
      json.dumps(worker_by_url(port, ":%d" % HB)))
after = []
for _ in range(6):
    ok, body, err, _ = say(b"rr", (("x-smg-model", "rr-model"),))
    if not ok:
        break
    after.append(body_field(body, "self"))
check("[failover] traffic converges onto the surviving worker",
      len(after) == 6 and set(after) == {"A"}, str(after))

# --------------------------- 6. breaker: probeless worker, hard port failure
ok, body, err, _ = say(b"pd?", (("x-smg-model", "pd-model"),))
seen = body_field(body, "x-lr-bootstrap-host") if ok else None
check("[pd] the PD call was served by the prefill worker (model steering)",
      ok and body_field(body, "self") == "PF", str(body)[:120] or str(err))
check("[pd] bootstrap host metadata reaches the prefill backend", seen == "127.0.0.1",
      str(body)[:300] or str(err))
check("[pd] bootstrap room is published and fits int32",
      ok and int(body_field(body, "x-lr-bootstrap-room") or "-1") >= 0
      and int(body_field(body, "x-lr-bootstrap-room")) < 2 ** 31,
      str(body)[:300])
check("[pd] decode peer metadata published",
      ok and body_field(body, "x-lr-decode-peer") == "127.0.0.1:%d" % PDEC,
      str(body)[:300])
check("[pd] bootstrap port defaults honoured (label 8998)",
      ok and body_field(body, "x-lr-bootstrap-port") == "8998", str(body)[:300])

# The five checks above rode as metadata because they were sent to
# /probe.Echo/Say, which is not an sglang Generate method -- that is the
# documented fallback (a body the router must not touch keeps the x-lr-* carrier).
# Below is the native path: the same pair, written into the proto message.
ok, gbody, gerr = generate(client, gen_request_bytes("req-42"),
                           (("x-smg-model", "pd-model"),))
check("[pd-body] Generate reaches the prefill worker",
      ok and body_field(gbody, "self") == "PF", str(gbody)[:200] or str(gerr))
check("[pd-body] the body arrived as a parsable GenerateRequest",
      ok and body_field(gbody, "pb") == "ok", str(gbody)[:200] or str(gerr))
check("[pd-body] bootstrap_host lands in DisaggregatedParams field 1",
      ok and body_field(gbody, "pb-host") == "127.0.0.1", str(gbody)[:300])
check("[pd-body] bootstrap_port lands in field 2 (label 8998)",
      ok and body_field(gbody, "pb-port") == "8998", str(gbody)[:300])
room = body_field(gbody, "pb-room") if ok else None
check("[pd-body] bootstrap_room lands in field 3 and fits int32",
      room is not None and 0 <= int(room) < 2 ** 31, str(room))
check("[pd-body] a real protobuf decoder reads the same three values",
      ok and body_field(gbody, "pb-gp")
      == "host=127.0.0.1,port=8998,room=%s" % room, str(body_field(gbody, "pb-gp")))
check("[pd-body] decode peer travels as extension fields 101/102",
      ok and body_field(gbody, "pb-decode-host") == "127.0.0.1"
      and body_field(gbody, "pb-decode-port") == str(PDEC), str(gbody)[:300])
check("[pd-body] the extension fields are unknown to the vendored schema",
      ok and body_field(gbody, "pb-extra") == "101:2,102:0", str(gbody)[:300])
check("[pd-body] disaggregated_params is field 10 of the request",
      ok and (body_field(gbody, "pb-fields") or "").endswith(",10:2"),
      str(body_field(gbody, "pb-fields")))
check("[pd-body] the client's other fields survive byte for byte",
      ok and body_field(gbody, "pb-rid") == "req-42"
      and body_field(gbody, "pb-unknown") == "20:1,21:2"
      and body_field(gbody, "pb-keep20") == "12345678"
      and body_field(gbody, "pb-keep21") == "keepme", str(gbody)[:300])
check("[pd-body] re-encoding through google.protobuf reproduces the same fields",
      ok and body_field(gbody, "pb-gp-roundtrip") == "yes", str(gbody)[:200])
check("[pd-body] metadata is not published in body mode",
      ok and body_field(gbody, "bootstrap-room-md") == "-", str(gbody)[:300])
# A second call must not accumulate a second field 10.
ok2, gbody2, gerr2 = generate(client, gen_request_bytes("req-43"),
                              (("x-smg-model", "pd-model"),))
check("[pd-body] repeated calls replace field 10 rather than appending",
      ok2 and (body_field(gbody2, "pb-fields") or "").count(",10:2") == 1
      and body_field(gbody2, "pb-rid") == "req-43", str(gbody2)[:200])
# A non-Generate method must never be touched, even with PD workers in scope.
ok3, gbody3, _ = generate(client, b"not-a-message", (("x-smg-model", "pd-model"),))
check("[pd-body] a body that is not a GenerateRequest is left alone and falls "
      "back to the metadata carrier",
      ok3 and body_field(gbody3, "pb") != "ok"
      and body_field(gbody3, "self") == "PF"
      and body_field(gbody3, "bootstrap-room-md") not in (None, "-"),
      str(gbody3)[:250])
# Past client_body_buffer_size (4m) nginx spills the body to a temp file, so this
# exercises the read-from-file branch, and PD still lands in the message.
def big_request(nbytes):
    """GenerateRequest whose field 21 is `nbytes` long: >4 MB pushes the gRPC
    frame into a nginx temp file, and >8 MB is past the injector's cap."""
    def varint(n):
        out = bytearray()
        while True:
            b = n & 0x7F
            n >>= 7
            out.append(b | (0x80 if n else 0))
            if not n:
                return bytes(out)
    payload = b"K" * nbytes
    return gen_request_bytes("big") + varint(21 * 8 + 2) + varint(len(payload)) + payload
ok4, gbody4, gerr4 = generate(client, big_request(5_000_000),
                              (("x-smg-model", "pd-model"),), timeout=30)
check("[pd-body] a file-spilled body (>4 MB) is still rewritten",
      ok4 and body_field(gbody4, "pb-host") == "127.0.0.1"
      and body_field(gbody4, "pb-rid") == "big"
      and body_fields(gbody4, "pb-keep21")[-1:] == ["len:5000000:%s" % ("K" * 16)],
      str(gbody4)[:200] or str(gerr4))
ok5, gbody5, gerr5 = generate(client, big_request(9_000_000),
                              (("x-smg-model", "pd-model"),), timeout=30)
check("[pd-body] a body over the injector cap keeps the metadata carrier",
      ok5 and body_field(gbody5, "pb-disagg") == "absent"
      and body_field(gbody5, "bootstrap-room-md") not in (None, "-"),
      str(gbody5)[:200] or str(gerr5))

st, body_r, _ = http("GET", "http://127.0.0.1:%d/readiness" % port)
doc_r = json.loads(body_r)
check("[pd] readiness 200 with both pools healthy", st == 200, "%s %s" % (st, body_r))
check("[pd] readiness reports per-pool counts",
      doc_r.get("prefill_workers", 0) == 1 and doc_r.get("decode_workers", 0) == 1,
      body_r)

# smg_worker_pool_size is the C1 gate: one series per unique
# (worker_type, connection_mode, model) triple, derived from the registry, with
# grpcs folded onto grpc the way Rust's ConnectionMode::as_metric_label does.
# A: bare grpc regular, B: tagged grpc regular (unhealthy but still registered),
# PF/DEC: the PD pair, TLS: grpcs regular, plus the one HTTP worker.
check("[metrics] pool gauge reports every pool by type, mode and model",
      wait_pool_sizes(port, {
          ("regular", "grpc", "rr-model"): 2,
          ("regular", "grpc", "tls-model"): 1,
          ("regular", "http", "http-model"): 1,
          ("prefill", "grpc", "pd-model"): 1,
          ("decode", "grpc", "pd-model"): 1,
      }, timeout=20), pool_dump(pool_sizes(port)))
check("[metrics] no pool is rendered as a zero series",
      all(v > 0 for v in (pool_sizes(port) or {}).values()), pool_dump(pool_sizes(port)))

# Kill the decode pool: PD must go not-ready and PD calls must say UNAVAILABLE.
kill_mock("DEC")
bad = False
for _ in range(50):
    st, body_r, _ = http("GET", "http://127.0.0.1:%d/readiness" % port)
    if st == 503:
        bad = True
        break
    time.sleep(0.5)
check("[pd] readiness 503 once any PD pool is empty", bad, body_r[:200])
# The decode record is still registered (its health probe is what died), so the
# pool keeps its series: registry membership, not availability, is what Rust
# counts in get_workers_filtered(..., healthy_only = false).
check("[metrics] a pool keeps its series while its worker is merely unhealthy",
      wait_pool_sizes(port, {
          ("regular", "grpc", "rr-model"): 2,
          ("regular", "grpc", "tls-model"): 1,
          ("regular", "http", "http-model"): 1,
          ("prefill", "grpc", "pd-model"): 1,
          ("decode", "grpc", "pd-model"): 1,
      }, timeout=10), pool_dump(pool_sizes(port)))
check("[pd] the 503 names the missing pool", "decode" in (body_r or ""), body_r[:200])
ok, _, err, _ = say(b"pd?", (("x-smg-model", "pd-model"),), timeout=5)
check("[pd] PD call with an empty decode pool -> UNAVAILABLE",
      (not ok) and grpc_status_of(err) == grpc.StatusCode.UNAVAILABLE, str(err))

# A non-PD model must still route while PD is broken: the pools are per model.
ok, body, err, _ = say(b"still-ok", (("x-smg-model", "rr-model"),))
check("[pd] a broken PD pool does not break the plain grpc pool",
      ok and body_field(body, "self") == "A", str(body)[:120] or str(err))

# Now kill the last plain grpc worker's gRPC port while its health stays good
# (A is a bare grpc:// record: probeless, so only the breaker can notice).
kill_mock("A")
# Wait for the port to actually stop answering. This is a shared box, and the
# loop below counts *failures*, so a stale socket or a different process that
# grabbed the freed ephemeral port would let one call succeed and reset the
# breaker counter -- the test would then be measuring the harness, not the
# circuit breaker.
released = port_refused(PA, timeout=15)
check("[breaker] the killed worker's gRPC port stops accepting", released,
      "port %d still answering (another process holds it?)" % PA)
tripped = False
last_err = None
attempts = []
stray = []
for _ in range(20):
    ok, body, err, _ = say(b"down", (("x-smg-model", "rr-model"),), timeout=5)
    if not ok:
        last_err = err
        attempts.append("F")
    else:
        attempts.append("S")
        # which worker answered, if any: pins an unexpected success to a record
        stray.append(body_field(body, "self"))
        break
    state = cb_state_of(port, ":%d" % PA)
    if state == 1:
        tripped = True
        break
    time.sleep(0.5)
# A is a bare grpc:// record, so it has no probeable face: the breaker is the only
# thing that can ever notice it died. is_healthy must stay true (nothing writes it)
# while the breaker itself walks closed -> open.
cb = worker_by_url(port, ":%d" % PA) or {}
check("[breaker] failures open the circuit while the health flag stays put",
      cb.get("is_healthy") is True and tripped,
      "attempts=%s stray=%s cb=%s worker=%s err=%s" % ("".join(attempts), stray,
                                       cb_state_of(port, ":%d" % PA),
                                       json.dumps(cb)[:220], str(last_err)))
ok, _, err, _ = say(b"down", (("x-smg-model", "rr-model"),), timeout=5)
msg = (err.details() or "") if err is not None else ""
check("[breaker] with the pool empty the call is UNAVAILABLE, not a hang",
      (not ok) and grpc_status_of(err) == grpc.StatusCode.UNAVAILABLE, str(err))
check("[breaker] the status comes from pool exhaustion, not a refused socket",
      "no_healthy_grpc_workers" in msg, msg[:120])

# ------------------------------------------------- 7. HTTP plane untouched
st, b, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                {"model": "http-model", "messages": [{"role": "user", "content": "hi"}]})
check("[http-face] chat answered by the http worker", st == 200, "%s %s" % (st, b[:160]))
# IGW is off here, so the HTTP plane does not filter by model at all (Rust does the
# same: effective_model_id is nil unless IGW is on) and "rr-model" is served by the
# one http worker. What proves the pool gate is *which* worker answered: a gRPC
# worker would either refuse the HTTP/1.1 request or answer on the wrong port, so a
# normal completion carrying the http worker's model id means the grpc/prefill/decode
# records were excluded from the candidate list.
st, b, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                {"model": "rr-model", "messages": [{"role": "user", "content": "hi"}]})
check("[http-face] a grpc-only model is served by the http worker, never by a grpc "
      "record (pool gate in registry.is_available)",
      st == 200 and '"model":"http-model"' in b.replace(" ", ""),
      "%s %s" % (st, b[:200]))

lg = logs(name)
check("[gate] no lua runtime errors in the router log", "lua entry thread aborted" not in lg,
      lg[-600:])
stop_router(name)

# ------------------- 8. second router: sticky policy + tight deadline cap
PA2, HA2, PB2, HB2 = free_port(), free_port(), free_port(), free_port()
start_mock("A2", PA2, health_port=HA2)
start_mock("B2", PB2, health_port=HB2)
mock_ready("A2")
mock_ready("B2")
GRPC2 = free_port()
port2 = start_router({
    "SMG_GRPC_PORT": str(GRPC2),
    "SMG_GRPC_POLICY": "sticky",
    "SMG_POLICY": "round_robin",
    "SMG_REQUEST_TIMEOUT_SECS": "2",
    "SMG_HEALTH_CHECK_INTERVAL_SECS": "2",
    "SMG_HEALTH_SUCCESS_THRESHOLD": "1",
}, "lr-grpc2-%s" % RUN)
name2 = "lr-grpc2-%s" % RUN
register(port2, {"url": "grpc://127.0.0.1:%d" % PA2, "model_id": "m2"})
register(port2, {"url": "grpc://127.0.0.1:%d" % PB2, "model_id": "m2"})
wait_workers(port2, lambda w: w.get("is_healthy"), 2, timeout=45)

client2 = chan(GRPC2)
say2 = lambda payload=b"x", md=(), timeout=8: call(client2, "/probe.Echo/Say", payload, md, timeout)
keys = {}
for _ in range(5):
    ok, body, err, _ = say2(b"sk", (("x-smg-routing-key", "user-42"),))
    if not ok:
        break
    keys[body_field(body, "self")] = keys.get(body_field(body, "self"), 0) + 1
check("[lb] sticky keeps one routing key on one worker",
      len(keys) == 1 and max(keys.values()) >= 4, json.dumps(keys))
spread = {}
for _ in range(6):
    ok, body, err, _ = say2(b"nk")
    if not ok:
        break
    spread[body_field(body, "self")] = spread.get(body_field(body, "self"), 0) + 1
check("[lb] sticky falls back to spread when no routing key is present",
      len(spread) >= 2, json.dumps(spread))
t0 = time.time()
ok, _, err, _ = call(client2, "/probe.Echo/Slow", b"x", (), timeout=10)
cut = time.time() - t0
check("[timeout] router cap 2 s cuts a 7 s call",
      (not ok) and cut < 4 and grpc_status_of(err) in (grpc.StatusCode.DEADLINE_EXCEEDED,
                                                       grpc.StatusCode.UNAVAILABLE),
      "rt=%.2f err=%s" % (cut, str(err)))
check("[timeout] the deadline is the router's, not the client's (no client timeout sent)",
      cut >= 1.9, "%.2fs" % cut)
check("[gate] second router has no lua errors", "lua entry thread aborted" not in logs(name2),
      logs(name2)[-600:])
stop_router(name2)

# ----- 9. third router: LR_GRPC_PD_METADATA=on keeps the pre-codec behaviour
# The switch is the escape hatch for a deployment whose workers were taught to
# read x-lr-* headers, so it has to keep working verbatim: metadata published and
# the request body untouched, even on a Generate method.
PP3 = free_port(); HP3 = free_port()
PD3 = free_port(); HD3 = free_port()
start_mock("P3", PP3, health_port=HP3)
start_mock("D3", PD3, health_port=HD3)
mock_ready("P3")
mock_ready("D3")
GRPC3 = free_port()
port3 = start_router({
    "SMG_GRPC_PORT": str(GRPC3),
    "SMG_GRPC_POLICY": "round_robin",
    "SMG_POLICY": "round_robin",
    "LR_GRPC_PD_METADATA": "on",
    "SMG_HEALTH_CHECK_INTERVAL_SECS": "2",
    "SMG_HEALTH_SUCCESS_THRESHOLD": "1",
}, "lr-grpc3-%s" % RUN)
name3 = "lr-grpc3-%s" % RUN
register(port3, {"url": "http://127.0.0.1:%d" % HP3, "worker_type": "prefill",
                 "connection_mode": {"type": "grpc", "port": PP3},
                 "labels": {"bootstrap_port": "8998"}, "model_id": "pd3-model"})
register(port3, {"url": "http://127.0.0.1:%d" % HD3, "worker_type": "decode",
                 "connection_mode": {"type": "grpc", "port": PD3},
                 "model_id": "pd3-model"})
wait_workers(port3, lambda w: w.get("is_healthy"), 2, timeout=45)

client3 = chan(GRPC3)
ok, body, err, _ = call(client3, "/probe.Echo/Say", b"mdmode",
                        (("x-smg-model", "pd3-model"),), timeout=8)
check("[md-mode] metadata carrier still serves the call",
      ok and body_field(body, "self") == "P3", str(body)[:200] or str(err))
check("[md-mode] the bootstrap triple is published as headers",
      ok and body_field(body, "x-lr-bootstrap-host") == "127.0.0.1"
      and body_field(body, "x-lr-bootstrap-port") == "8998"
      and int(body_field(body, "x-lr-bootstrap-room") or "-1") >= 0,
      str(body)[:300])
check("[md-mode] the decode peer is published as a header",
      ok and body_field(body, "x-lr-decode-peer") == "127.0.0.1:%d" % PD3,
      str(body)[:300])
ok, gbody3, gerr3 = generate(client3, gen_request_bytes("md-req"),
                             (("x-smg-model", "pd3-model"),))
check("[md-mode] Generate arrives untouched: no field 10 written",
      ok and body_field(gbody3, "pb") == "ok"
      and body_field(gbody3, "pb-disagg") == "absent"
      and body_field(gbody3, "pb-fields") == "1:2,4:2,20:1,21:2",
      str(gbody3)[:250] or str(gerr3))
check("[md-mode] and metadata still accompanies that call",
      ok and body_field(gbody3, "bootstrap-room-md") not in (None, "-"),
      str(gbody3)[:250])
check("[gate] third router has no lua errors",
      "lua entry thread aborted" not in logs(name3), logs(name3)[-600:])
stop_router(name3)

# ----- 10. LR_GRPC_PD_METADATA=off publishes nothing at all (pure forwarding)
# Reuses the third section's workers: the switch is three-valued now (body /
# metadata / none) and "none" is the state that could silently start injecting.
GRPC4 = free_port()
port4 = start_router({
    "SMG_GRPC_PORT": str(GRPC4),
    "SMG_GRPC_POLICY": "round_robin",
    "SMG_POLICY": "round_robin",
    "LR_GRPC_PD_METADATA": "off",
    "SMG_HEALTH_CHECK_INTERVAL_SECS": "2",
    "SMG_HEALTH_SUCCESS_THRESHOLD": "1",
}, "lr-grpc4-%s" % RUN)
name4 = "lr-grpc4-%s" % RUN
register(port4, {"url": "http://127.0.0.1:%d" % HP3, "worker_type": "prefill",
                 "connection_mode": {"type": "grpc", "port": PP3},
                 "labels": {"bootstrap_port": "8998"}, "model_id": "pd3-model"})
register(port4, {"url": "http://127.0.0.1:%d" % HD3, "worker_type": "decode",
                 "connection_mode": {"type": "grpc", "port": PD3},
                 "model_id": "pd3-model"})
wait_workers(port4, lambda w: w.get("is_healthy"), 2, timeout=45)
client4 = chan(GRPC4)
ok, gbody4, gerr4 = generate(client4, gen_request_bytes("off-req"),
                             (("x-smg-model", "pd3-model"),))
check("[md-off] the PD call still routes to the prefill worker",
      ok and body_field(gbody4, "self") == "P3", str(gbody4)[:200] or str(gerr4))
check("[md-off] nothing is injected: no field 10 and no x-lr-* bootstrap headers",
      ok and body_field(gbody4, "pb-disagg") == "absent"
      and body_field(gbody4, "bootstrap-room-md") == "-"
      and body_field(gbody4, "pb-fields") == "1:2,4:2,20:1,21:2",
      str(gbody4)[:250])
check("[gate] fourth router has no lua errors",
      "lua entry thread aborted" not in logs(name4), logs(name4)[-600:])
stop_router(name4)

# ----- 5b. body mode with a DP-aware prefill: extension field 103
# A prefill url that ends in @<rank> is the sglang DP convention (registry strips
# it before dialing, pd.split_dp_rank reads it back out), and it is the only way
# field 103 gets written. Kept in its own router because the pool-census metric
# checks above assert an exact series set.
GRPC5 = free_port()
port5 = start_router({
    "SMG_GRPC_PORT": str(GRPC5),
    "SMG_GRPC_POLICY": "round_robin",
    "SMG_POLICY": "round_robin",
    "SMG_HEALTH_CHECK_INTERVAL_SECS": "2",
    "SMG_HEALTH_SUCCESS_THRESHOLD": "1",
}, "lr-grpc5-%s" % RUN)
name5 = "lr-grpc5-%s" % RUN
register(port5, {"url": "http://127.0.0.1:%d@2" % HP3, "worker_type": "prefill",
                 "connection_mode": {"type": "grpc", "port": PP3},
                 "labels": {"bootstrap_port": "8998"}, "model_id": "pd3-model"})
register(port5, {"url": "http://127.0.0.1:%d" % HD3, "worker_type": "decode",
                 "connection_mode": {"type": "grpc", "port": PD3},
                 "model_id": "pd3-model"})
wait_workers(port5, lambda w: w.get("is_healthy"), 2, timeout=45)
client5 = chan(GRPC5)
ok, gbody5, gerr5 = generate(client5, gen_request_bytes("rank-req"),
                             (("x-smg-model", "pd3-model"),))
check("[pd-body] a DP-aware prefill url also writes field 103",
      ok and body_field(gbody5, "pb-dp-rank") == "2", str(gbody5)[:250] or str(gerr5))
check("[pd-body] and the request still parses after three extensions",
      ok and body_field(gbody5, "pb-extra") == "101:2,102:0,103:0",
      str(gbody5)[:250])
# A client that *appended* its own DisaggregatedParams (two occurrences of field
# 10) is the case where the naive "just append the tag, the last write wins" rule
# breaks: proto3 parses a duplicated singular message field by MERGING the
# occurrences, so a blind append leaks the previous bootstrap_port/room into this
# request (verified against python protobuf: {host:STALE,port:7777,room:8888} +
# {host:NEW} decodes as host=NEW port=7777 room=8888). The router parses and
# replaces, so exactly one field 10 leaves and it carries only the router's values.
def dup_field10_request(request_id):
    def varint(n):
        out = bytearray()
        while True:
            b = n & 0x7F
            n >>= 7
            out.append(b | (0x80 if n else 0))
            if not n:
                return bytes(out)
    def tag(field, wire):
        return varint(field * 8 + wire)
    def sfield(field, payload):
        return tag(field, 2) + varint(len(payload)) + payload
    stale = (sfield(1, b"STALE") + tag(2, 0) + varint(7777)
             + tag(3, 0) + varint(8888))
    partial = sfield(1, b"STALE2")          # host only: merge would keep 7777/8888
    return gen_request_bytes(request_id) + sfield(10, stale) + sfield(10, partial)

ok6, gbody6, gerr6 = generate(client5, dup_field10_request("dup-req"),
                              (("x-smg-model", "pd3-model"),))
fields6 = (body_field(gbody6, "pb-fields") or "") if ok6 else ""
check("[pd-body] a request that already carries two field 10 leaves with one",
      ok6 and fields6.count("10:2") == 1, "%s %s" % (fields6, str(gbody6)[:150]))
def _as_int(raw):
    """Mock placeholders ("-", "absent") must report FAIL, not raise at the check."""
    try:
        return int(raw)
    except (TypeError, ValueError):
        return None

room6 = _as_int(body_field(gbody6, "pb-room")) if ok6 else None
check("[pd-body] and the stale bootstrap_port/room do not survive the merge",
      ok6 and body_field(gbody6, "pb-host") == "127.0.0.1"
      and body_field(gbody6, "pb-port") == "8998"
      and room6 is not None and 0 <= room6 < 2 ** 31,
      str(gbody6)[:250] or str(gerr6))
check("[gate] fifth router still has no lua errors after the rewrite",
      "lua entry thread aborted" not in logs(name5), logs(name5)[-600:])
check("[gate] fifth router has no lua errors",
      "lua entry thread aborted" not in logs(name5), logs(name5)[-600:])
stop_router(name5)

http_proc.terminate()

failed = [r for r in RESULTS if not r[0]]
print("\n=== e2e_grpc: %d checks, %d failed ===" % (len(RESULTS), len(failed)))
for _, n, d in failed:
    print("FAILED: %s | %s" % (n, str(d)[:300]))
cleanup()
sys.exit(1 if failed else 0)
