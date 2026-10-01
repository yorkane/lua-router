#!/usr/bin/env python3
"""End-to-end checks for DP-aware expansion and Kubernetes pod discovery.

Topology, all on the host network:

    [router: hb sweep -> registry.discover -> expand_dp] --HTTP--> DP mock worker
    [router: discovery timer -> poll_once]  --HTTP--> fake K8s API server (fixtures/k8s/*.json)

Both peers are in-file stdlib servers rather than test/mock_llm_worker.py: the DP
mock has to answer /server_info with a configurable dp_size (and sometimes with a
500, or without the field at all), and the API server has to switch pod sets and
error codes between phases of one router's lifetime. Each mock stamps its own id
and echoes the request body, so "which rank served this call" is observable from the
client side through the injected data_parallel_rank member.

Pod IPs use 127.0.0.1 and 127.0.0.2, both loopback on Linux, and the discovery
port points at one mock: a second address is a second worker without needing a
second listener.

Groups, in run order:
  A. DP-aware: dp_size=4 expands into four "<base>@<rank>" candidates that all
     turn healthy, keep the model id and labels, and serve inference; removing one
     rank takes only that rank; dp_size=1 stays one entry; an unusable
     /server_info keeps one entry; /get_server_info is honoured; with
     SMG_DP_AWARE off a dp_size=4 engine stays one worker.
  B. Kubernetes: 403 registers nothing and is counted; recovery registers with
     pod labels; pod added; label flip deregisters (the fake API server always
     ignores labelSelector, so this proves the client-side recheck); Ready=False
     deregisters; Ready again re-registers; API 500 changes nothing; the SA token
     is presented as a bearer token; PD selectors keep the SMG_GRPC-off 400
     contract; discovery off never calls the API server; enabled with no cluster
     logs that discovery is disabled.
  C. The smg_discovery_* families on /metrics.
  D. Watch transport (SMG_SERVICE_DISCOVERY_WATCH): the same pod set maintained by
     ADDED/MODIFIED/DELETED frames over a chunked stream, resume-from-resourceVersion
     after the server hangs up, full relist after a 410, and fieldSelector sent plus
     rechecked. The fake API server streams real chunks (one event per chunk) and
     replays from the requested version, so a reconnect cannot lose a change.
  E. Router-pod discovery (SMG_ROUTER_SELECTOR): two routers whose SMG_MESH_PEERS
     names only themselves converge on a two-member cluster from the pod list, the
     peer is a real sync target, a peer that leaves the list is marked down, and no
     router is ever registered as a worker even though SMG_SELECTOR matches it.

The forwarded body carries `data_parallel_rank` for a rank worker: router.lua calls
service_discovery.inject_dp_rank on the rewritten payload, so the engine can tell
which shard a call belongs to (doc/gap-dp-jwt.md, and doc/gap-discovery-dp.md 1.5
for the gap this closes). Workers without a rank keep their body byte-identical,
which the dp_size=1 group asserts.

Run: python3 test/integration/e2e_discovery_dp.py
Requires the image built (final_gates.sh `build` gate).
"""
import json, os, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (free_port, http, check, logs, RESULTS, RUN, IMAGE)

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures", "k8s")
TMP = os.environ.get("LR_TEST_TMP", "/data/tmp/lr")
os.makedirs(TMP, exist_ok=True)

SERVERS = []
CONTAINERS = []

# Container names this suite owns. An aborted run (killed before its finally ran)
# leaves routers behind that keep polling their discovery endpoint, and once the
# host recycles that port they land on the next run's fake API server.
OWNED_PREFIXES = ("lr-dp4-", "lr-dp1-", "lr-dpfail-", "lr-dpmissing-", "lr-dplegacy-",
                  "lr-dpoff-", "lr-dpk8s-", "lr-k8s-", "lr-k8ssa-", "lr-k8spd-",
                  "lr-k8spdg-", "lr-k8soff-", "lr-k8snone-",
                  "lr-k8sw-", "lr-k8sf-", "lr-rpod1-", "lr-rpod2-")


def sweep_leaked():
    listing = subprocess.run(["docker", "ps", "-a", "--format", "{{.Names}}"],
                             capture_output=True).stdout.decode().split()
    stale = [n for n in listing if n.startswith(OWNED_PREFIXES)]
    for name in stale:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True)
    return stale


# ------------------------------------------------------------------ harness
def start_router_local(env, name, volumes=(), port=None):
    """_lib.start_router plus -v mounts (the service-account test needs one).

    port= pins SMG_PORT: the router-pod group has to know each node's address
    before either is up, because the pod annotation carries the other's port."""
    if port is None:
        port = free_port()
    args = ["docker", "run", "-d", "--name", name]
    for k, v in env.items():
        args += ["-e", "%s=%s" % (k, v)]
    for src, dst in volumes:
        args += ["-v", "%s:%s:ro" % (src, dst)]
    args += ["-e", "SMG_PORT=%d" % port, "--network", "host", "-e", "SMG_METRICS_PORT=0",
             "--entrypoint", "/docker-entrypoint.sh", IMAGE,
             "/usr/local/openresty/bin/openresty", "-p", "/usr/local/openresty/nginx",
             "-g", "daemon off;"]
    subprocess.run(args, check=True, capture_output=True)
    CONTAINERS.append(name)
    for _ in range(120):
        st, _, _ = http("GET", "http://127.0.0.1:%d/health" % port, timeout=2)
        if st == 200:
            return port
        time.sleep(0.25)
    raise RuntimeError("router %s never came up:\n%s" % (name, logs(name)))


def stop(name):
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)


def workers(port):
    st, body, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
    if st != 200:
        return None
    return json.loads(body).get("workers", [])


def urls(port):
    ws = workers(port)
    return sorted(w["url"] for w in ws) if ws is not None else None


def wait_urls(port, want, timeout=40):
    want = sorted(want)
    for _ in range(int(timeout / 0.5)):
        if urls(port) == want:
            return True
        time.sleep(0.5)
    return False


def wait_workers(port, want_n, timeout=40):
    for _ in range(int(timeout / 0.5)):
        ws = workers(port)
        if ws is not None and len(ws) == want_n:
            return True
        time.sleep(0.5)
    return False


def wait_healthy(port, n, timeout=40):
    for _ in range(int(timeout / 0.5)):
        ws = workers(port) or []
        if sum(1 for w in ws if w.get("is_healthy")) >= n:
            return True
        time.sleep(0.5)
    return False


def metrics(port):
    st, body, _ = http("GET", "http://127.0.0.1:%d/metrics" % port)
    return body if st == 200 else ""


def wait_for_text(port, needle, timeout=30):
    """Poll /metrics until one line starts with `needle` (histogram series only
    exist once something observed, so this is how a family gets waited for)."""
    for _ in range(int(timeout / 0.5)):
        body = metrics(port)
        if any(line.startswith(needle) for line in body.splitlines()):
            return body
        time.sleep(0.5)
    return None


def wait_metric(port, name, label_substr="", timeout=30):
    for _ in range(int(timeout / 0.5)):
        value = metric_value(metrics(port), name, label_substr)
        if value is not None:
            return value
        time.sleep(0.5)
    return None


def metric_value(text, name, label_substr=""):
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


def wait_missing(port, gone, timeout=30):
    for _ in range(int(timeout / 0.5)):
        current = urls(port)
        if current is not None and gone not in current:
            return True
        time.sleep(0.5)
    return False


def wait_present(port, want, timeout=30):
    for _ in range(int(timeout / 0.5)):
        current = urls(port)
        if current is not None and want in current:
            return True
        time.sleep(0.5)
    return False


# ------------------------------------------------------------------ DP mock worker
class QuietHandler(BaseHTTPRequestHandler):
    """BaseHTTPRequestHandler that swallows client resets.

    The router's cosockets close without a clean shutdown (and the readiness probe
    above connects before the port is listening), so a reset mid-request is expected
    here; the stdlib default prints a full traceback for each one, which buries the
    check lines this suite's verdict is read from.
    """

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except (ConnectionResetError, BrokenPipeError):
            self.close_connection = True

    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError):
            pass



class DPHandler(QuietHandler):
    server_version = "DPMock/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, status, payload):
        body = payload.encode() if isinstance(payload, str) else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        cfg = self.server.cfg
        if path == "/health":
            self._send(200, {"status": "ok"})
        elif path == "/model_info":
            self._send(200, {"model_path": "/models/%s" % cfg["model"],
                             "served_model_name": cfg["model"], "is_generation": True})
        elif path in ("/server_info", "/get_server_info"):
            if cfg["server_info_mode"] == "fail":
                self._send(500, {"error": "engine not ready"})
            elif cfg["only_legacy"] and path == "/server_info":
                self._send(404, {"error": "no route"})
            elif cfg["server_info_mode"] == "missing":
                self._send(200, {"model_path": "/models/%s" % cfg["model"], "tp_size": 1})
            else:
                self._send(200, {"model_path": "/models/%s" % cfg["model"],
                                 "served_model_name": cfg["model"],
                                 "tp_size": 1, "dp_size": cfg["dp_size"]})
        elif path == "/metrics":
            self._send(200, "# HELP mock_probe counter\n# TYPE mock_probe counter\n"
                            "mock_probe 1\n")
        elif path == "/v1/models":
            self._send(200, {"object": "list",
                             "data": [{"id": cfg["model"], "object": "model"}]})
        else:
            self._send(404, {"error": {"message": "no route %s" % path}})

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw.decode() or "{}")
        except ValueError:
            body = {}
        cfg = self.server.cfg
        if self.path.split("?", 1)[0] == "/v1/chat/completions":
            self._send(200, {
                "id": "dp-%s" % self.server.id,
                "object": "chat.completion",
                "model": cfg["model"],
                "choices": [{"index": 0,
                             "message": {"role": "assistant",
                                         "content": "echo[%s]" % cfg["model"]}}],
                # What the router actually sent: both the model rewrite and the
                # injected data_parallel_rank are observable from here.
                "echo_body": body,
                "worker": self.server.id,
            })
        else:
            self._send(404, {"error": {"message": "no route %s" % self.path}})


def start_dp(mock_id, dp_size=4, model="dp-model", mode="ok", only_legacy=False):
    port = free_port()
    srv = ThreadingHTTPServer(("0.0.0.0", port), DPHandler)
    srv.daemon_threads = True
    srv.id = mock_id
    srv.cfg = {"model": model, "dp_size": dp_size, "server_info_mode": mode,
               "only_legacy": only_legacy}
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    SERVERS.append(srv)
    for _ in range(80):
        st, _, _ = http("GET", "http://127.0.0.1:%d/health" % port, timeout=2)
        if st == 200:
            return srv, port
        time.sleep(0.1)
    raise RuntimeError("dp mock %s never came up" % mock_id)


# ------------------------------------------------------------------ fake K8s API
class K8sHandler(QuietHandler):
    """Serves a pod list (fixture or pushed doc) or an error, and streams watch events.

    labelSelector and fieldSelector are deliberately ignored on the list path: a
    fake that filtered would let the router pass by asking the server to do the
    work, and the client-side recheck (the part that decides which workers exist)
    would never be exercised. Every request path is recorded instead, so the suite
    can assert the parameters were actually sent.

    The watch branch is a real chunked stream: one newline-terminated JSON event
    per chunk (the framing the API server uses - the client reads lines, not
    chunks), the socket held open until the suite retires it
    (k8s_watch_close_streams) or the client goes away. Each connection keeps its own cursor into the event log, so a stream
    that is still being torn down cannot steal the events meant for its successor -
    which is exactly the window a reconnect has to survive.
    """
    server_version = "FakeK8s/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, status, payload):
        body = payload.encode() if isinstance(payload, str) else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass

    def _chunk(self, text):
        """One HTTP chunk. Note the trailing newline inside the payload: a real
        API server frames a watch as newline-delimited JSON, and the client only
        decodes a line once its terminator has arrived. A chunk that carries a
        bare object would sit in the client's line buffer forever - so the fake
        has to produce the same framing, not merely the same JSON."""
        body = text + "\n"
        try:
            self.wfile.write(("%x\r\n%s\r\n" % (len(body), body)).encode())
            self.wfile.flush()
            return True
        except OSError:
            return False

    def _serve_watch(self, seq, cond, want_rv):
        state = self.server.k8s
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        self.close_connection = True
        # Each connection replays from the resourceVersion it asked for, the way a
        # real API server does. A cursor taken at connect time would silently lose
        # whatever changed while the client was between two streams, which is the
        # exact window a reconnect has to survive.
        cursor = len(state["watch_log"])
        if want_rv and want_rv.isdigit():
            cursor = 0
            for i, evt in enumerate(state["watch_log"]):
                stamped = str(((evt.get("object") or {}).get("metadata") or {})
                              .get("resourceVersion") or "")
                if stamped.isdigit() and int(stamped) <= int(want_rv):
                    cursor = i + 1
        deadline = time.time() + 150
        while time.time() < deadline and not state["shutdown"]:
            with cond:
                while (len(state["watch_log"]) <= cursor and state["stream_seq"] == seq
                        and not state["shutdown"] and time.time() < deadline):
                    cond.wait(0.2)
                if state["stream_seq"] != seq or state["shutdown"]:
                    return
                events = state["watch_log"][cursor:]
                cursor = len(state["watch_log"])
            for evt in events:
                if evt["type"] == "__close__":
                    # Bare hang-up: no terminating chunk, no ERROR frame. The
                    # client has to notice with its own read timeout or not at all.
                    return
                if not self._chunk(json.dumps(evt)):
                    return

    def do_GET(self):
        from urllib.parse import urlparse, parse_qs
        state = self.server.k8s
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        watching = query.get("watch", [""])[0] == "true"
        with state["lock"]:
            state["calls"] += 1
            # discovery_calls is the number a "was the API server touched at all"
            # check has to use: calls counts every request, and a router left behind
            # by another suite can hit this port with a health-sweep /v1/models.
            if parsed.path.startswith("/api/v1"):
                state["discovery_calls"] += 1
            state["last_path"] = self.path
            # Every path, not just the last one: this box runs several routers on
            # the host network, and a container left behind by another suite can hit
            # a recycled port (its health sweep probes <worker>/v1/models). A check
            # on "the last request" would then fail for a request that has nothing
            # to do with this router.
            state["paths"].append(self.path)
            auth = self.headers.get("authorization") or ""
            state["last_auth"] = auth
            # The bearer-token check reads this rather than last_auth: several
            # polls can be in flight, and one that arrives without the file
            # readable must not erase the evidence that another one carried it.
            state["auths"].append(auth)
            mode, fixture, doc = state["mode"], state["fixture"], state["doc"]
            seq = state["stream_seq"]
            cond = state["watch_cond"]
            if watching:
                state["watch_requests"].append(self.path)
                gone_rv = state["gone_rv"]
                want_rv = (query.get("resourceVersion") or [""])[0]
            else:
                state["list_calls"] += 1
                if parsed.path.startswith("/api/v1"):
                    # A list always reports a newer version, which is what a watch
                    # resumes from - and it clears the 410 marker, since relisting
                    # is precisely the recovery from "that version is gone".
                    state["gone_rv"] = None
                    state["rv"] = str(int(state["rv"]) + 1)
                    doc = dict(doc) if doc is not None else doc
                rv = state["rv"]

        if watching and parsed.path.startswith("/api/v1"):
            if gone_rv and want_rv == gone_rv:
                self._send(410, {"kind": "Status", "apiVersion": "v1", "metadata": {},
                                 "status": "Failure", "reason": "Gone", "details": {},
                                 "code": 410,
                                 "message": "too old resource version: %s" % want_rv})
                return
            self._serve_watch(seq, cond, want_rv)
            return

        if mode == "forbidden":
            self._send(403, {"kind": "Status", "status": "Failure", "code": 403,
                             "reason": "Forbidden",
                             "message": "pods is forbidden: no RBAC list permission"})
            return
        if mode == "error":
            self._send(500, {"kind": "Status", "status": "Failure", "code": 500,
                             "reason": "InternalError", "message": "fake api server"})
            return
        if doc is not None:
            payload = dict(doc)
            payload["metadata"] = {"resourceVersion": rv}
            self._send(200, payload)
            return
        self._send(200, json.load(open(os.path.join(FIXTURES, fixture))))


def start_k8s(mode="ok", fixture="pods_single.json"):
    """Note: the readiness probe below is a request of its own, so a caller that
    counts API-server calls has to reset the counter (see reset_api_calls)."""
    port = free_port()
    srv = ThreadingHTTPServer(("0.0.0.0", port), K8sHandler)
    srv.daemon_threads = True
    lock = threading.Lock()
    srv.k8s = {"mode": mode, "fixture": fixture, "calls": 0, "discovery_calls": 0,
               "last_path": "", "last_auth": "", "auths": [], "paths": [], "lock": lock,
               # watch plumbing: one event log, one cursor per stream
               "watch_cond": threading.Condition(lock), "watch_log": [],
               "watch_requests": [], "stream_seq": 0, "gone_rv": None,
               "list_calls": 0, "rv": "1000", "doc": None, "shutdown": False}
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    SERVERS.append(srv)
    for _ in range(80):
        st, _, _ = http("GET", "http://127.0.0.1:%d/api/v1/pods" % port, timeout=2)
        if st in (200, 403, 500):
            return srv, port
        time.sleep(0.1)
    raise RuntimeError("fake k8s api server never came up")


def k8s_watch_push(srv, evt_type, obj):
    """Queue one watch event for every open stream. The object's resourceVersion
    becomes the client's resume point, so it is stamped here rather than by hand."""
    with srv.k8s["lock"]:
        srv.k8s["rv"] = str(int(srv.k8s["rv"]) + 1)
        obj = dict(obj)
        obj["metadata"] = dict(obj.get("metadata") or {})
        obj["metadata"]["resourceVersion"] = srv.k8s["rv"]
        srv.k8s["watch_log"].append({"type": evt_type, "object": obj})
        srv.k8s["watch_cond"].notify_all()


def k8s_watch_close_streams(srv):
    """Hang up every open watch (an apiserver restart or a compacted stream does
    this). Streams opened afterwards are unaffected."""
    with srv.k8s["lock"]:
        srv.k8s["stream_seq"] += 1
        srv.k8s["watch_cond"].notify_all()


def k8s_watch_gone(srv):
    """Answer 410 Gone to the next watch that asks for the version the server is at,
    which is what a healthy client holds. Cleared by the next list, as in a real
    cluster where a fresh list re-establishes a readable version."""
    with srv.k8s["lock"]:
        srv.k8s["gone_rv"] = str(srv.k8s["rv"])
        # A stream parked on the current version has to be dropped for the client to
        # ask again; a live connection never gets the 410.
        srv.k8s["stream_seq"] += 1
        srv.k8s["watch_cond"].notify_all()


def k8s_watch_requests(srv):
    with srv.k8s["lock"]:
        return list(srv.k8s["watch_requests"])


def k8s_list_calls(srv):
    with srv.k8s["lock"]:
        return srv.k8s["list_calls"]


def watch_rv_of(path):
    """resourceVersion carried by one watch request, or None when it sent none."""
    from urllib.parse import urlparse, parse_qs
    got = parse_qs(urlparse(path).query).get("resourceVersion")
    return got[0] if got else None


def wait_watch_matching(srv, needles, timeout=40):
    """Wait for a watch request whose path contains every needle. The first stream
    opens a beat after the list lands, so snapshotting watch_requests() races it."""
    for _ in range(int(timeout / 0.25)):
        for path in k8s_watch_requests(srv):
            if all(n in path for n in needles):
                return path
        time.sleep(0.25)
    return None


def wait_watch_streams(srv, more_than, timeout=40):
    """Wait until the server has seen `more_than` watch requests (counted at open),
    and return the newest one. Counting streams - not scanning a snapshot - is what
    makes "the stream came back" a statement about the stream after the reset."""
    for _ in range(int(timeout / 0.25)):
        paths = k8s_watch_requests(srv)
        if len(paths) > more_than:
            return paths[-1]
        time.sleep(0.25)
    return None


def wait_watch_request(srv, with_rv=True, timeout=45):
    """Wait for a watch request that carries (or lacks) a resourceVersion."""
    for _ in range(int(timeout / 0.25)):
        for path in k8s_watch_requests(srv):
            if (watch_rv_of(path) is not None) == bool(with_rv):
                return path
        time.sleep(0.25)
    return None


def ha_stats(port):
    st, body, _ = http("GET", "http://127.0.0.1:%d/ha/stats" % port, timeout=5)
    if st != 200:
        return None
    return json.loads(body)


def wait_ha_stats(port, pred, timeout=40):
    """Poll /ha/stats until pred(doc) is true; returns the doc, not the sub-table."""
    for _ in range(int(timeout / 0.5)):
        doc = ha_stats(port)
        if doc is not None and pred(doc):
            return doc
        time.sleep(0.5)
    return None


def ha_doc(port):
    st, body, _ = http("GET", "http://127.0.0.1:%d/ha/status" % port, timeout=5)
    if st != 200:
        return None
    return json.loads(body)


def ha_address_status(doc, address):
    if not doc:
        return None
    for node in doc.get("nodes", []):
        if (node.get("address") or "").rstrip("/") == address.rstrip("/"):
            return node.get("status")
    return None


def wait_ha_member(port, address, want_status=None, timeout=45):
    for _ in range(int(timeout / 0.5)):
        doc = ha_doc(port)
        if doc is not None:
            got = ha_address_status(doc, address)
            if got is not None and (want_status is None or got == want_status):
                return doc
        time.sleep(0.5)
    return None


def k8s_paths(srv):
    with srv.k8s["lock"]:
        return list(srv.k8s["paths"])


def k8s_doc(srv, doc, rv=None):
    """Replace the list response. The resourceVersion is what a watch resumes from,
    so it is set here rather than left in the fixture."""
    with srv.k8s["lock"]:
        srv.k8s["doc"] = doc
        if rv is not None:
            srv.k8s["rv"] = str(rv)
        srv.k8s["gone_rv"] = None


def reset_api_calls(srv):
    with srv.k8s["lock"]:
        srv.k8s["calls"] = 0
        srv.k8s["discovery_calls"] = 0
        srv.k8s["last_path"] = ""
        srv.k8s["last_auth"] = ""
        srv.k8s["auths"] = []
        srv.k8s["paths"] = []


def k8s_state(srv):
    with srv.k8s["lock"]:
        return dict(srv.k8s)


def set_k8s(srv, mode=None, fixture=None):
    with srv.k8s["lock"]:
        if mode:
            srv.k8s["mode"] = mode
        if fixture:
            srv.k8s["fixture"] = fixture


def wait_api_calls(srv, at_least=1, timeout=20):
    for _ in range(int(timeout / 0.25)):
        if k8s_state(srv)["calls"] >= at_least:
            return True
        time.sleep(0.25)
    return False


# ---------------------------------------------------------------- new helpers

def pod_obj(name, ip, labels=None, ready=True, phase="Running", port_annotation=None,
            rv=None, deleting=False, namespace="team-a"):
    """One Pod object in the shape /api/v1/pods items[] uses."""
    meta = {"name": name, "namespace": namespace, "labels": labels or {"app": "sglang"}}
    if rv is not None:
        meta["resourceVersion"] = str(rv)
    if port_annotation:
        meta["annotations"] = port_annotation
    if deleting:
        meta["deletionTimestamp"] = "2026-09-30T00:00:00Z"
    return {"metadata": meta,
            "status": {"phase": phase, "podIP": ip,
                       "conditions": [{"type": "Ready",
                                       "status": "True" if ready else "False"}]}}


def pod_doc(items, rv):
    return {"apiVersion": "v1", "kind": "PodList",
            "metadata": {"resourceVersion": str(rv)}, "items": items}


# --------------------------------------------------------------------- group A
def group_dp():
    srv, wport = start_dp("dp4", dp_size=4, model="dp-model")
    base = "http://127.0.0.1:%d" % wport
    ranks = ["%s@%d" % (base, i) for i in range(4)]
    name = "lr-dp4-%s" % RUN
    port = start_router_local({"SMG_DP_AWARE": "1", "SMG_POLICY": "round_robin",
                               "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                               "SMG_HEALTH_CHECK_TIMEOUT_SECS": "3",
                               "SMG_WORKER_URLS": base}, name)

    check("[dp4] /server_info dp_size=4 expands into 4 rank candidates",
          wait_urls(port, ranks, timeout=30), urls(port))
    ws = workers(port) or []
    check("[dp4] the base entry is gone once the ranks exist",
          base not in [w["url"] for w in ws], urls(port))
    check("[dp4] every rank becomes healthy", wait_healthy(port, 4, timeout=30),
          json.dumps(workers(port)))
    ws = workers(port) or []
    check("[dp4] ranks inherit the model id learned from the probe",
          all(w.get("model_id") == "dp-model" for w in ws), json.dumps(ws))
    check("[dp4] rank metadata carries dp_rank and dp_size",
          sorted(w.get("metadata", {}).get("dp_rank") for w in ws) == ["0", "1", "2", "3"]
          and all(w["metadata"].get("dp_size") == "4" for w in ws),
          json.dumps([w.get("metadata") for w in ws]))
    check("[dp4] ranks have distinct ids (separate health, load and breaker)",
          len({w["id"] for w in ws}) == 4, json.dumps(ws))
    doc = json.loads(http("GET", "http://127.0.0.1:%d/workers" % port)[1])
    check("[dp4] /workers reports four regular workers",
          doc.get("total") == 4 and doc.get("stats", {}).get("regular_count") == 4,
          json.dumps(doc)[:300])

    st, body, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                       {"model": "dp-model", "messages": [{"role": "user", "content": "dp probe"}]})
    echoed = json.loads(body).get("echo_body", {}) if st == 200 else {}
    check("[dp4] inference against a rank url works (rank stripped for dialing)",
          st == 200 and "echo[dp-model]" in body, "%s %s" % (st, body[:200]))
    check("[dp4] the model rewrite still reaches the engine",
          echoed.get("model") == "dp-model", json.dumps(echoed)[:200])
    # Body injection: with round_robin the four ranks take the requests in turn, so
    # four calls are enough to see every rank's value come back in its own body. The
    # assertion is a set match rather than a per-call sequence because the candidate
    # order comes from the registry dict and is not rank order; what matters is that
    # each rank's calls carry exactly its own number.
    seen = []
    for _ in range(8):
        st, body, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                           {"model": "dp-model",
                            "messages": [{"role": "user", "content": "rank probe"}]})
        if st == 200:
            seen.append(json.loads(body).get("echo_body", {}).get("data_parallel_rank"))
    check("[dp4] every rank's calls carry its own data_parallel_rank",
          set(seen) == {0, 1, 2, 3}, json.dumps(seen))
    check("[dp4] injection is an integer member, not a string",
          all(isinstance(r, int) for r in seen), json.dumps(seen))
    check("[dp4] the model rewrite and the injected rank coexist in one body",
          echoed.get("model") == "dp-model"
          and isinstance(echoed.get("data_parallel_rank"), int), json.dumps(echoed)[:200])
    # A body that already names the field gets rewritten, not duplicated: two
    # members with the same key would make the engine's pick undefined.
    st, body, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                       {"model": "dp-model", "data_parallel_rank": 99,
                        "messages": [{"role": "user", "content": "override"}]})
    pre = json.loads(body).get("echo_body", {}) if st == 200 else {}
    check("[dp4] a client-sent data_parallel_rank is overwritten, not duplicated",
          st == 200 and isinstance(pre.get("data_parallel_rank"), int)
          and pre["data_parallel_rank"] != 99, json.dumps(pre)[:200])

    # Per-rank health state is what expansion buys, and it is only observable if
    # the fan-out and the sweep can still dial a url that carries the suffix.
    text = metrics(port)
    ranks_in_metrics = sum(1 for line in text.splitlines()
                           if line.startswith("smg_worker_health{") and "@rank" not in line
                           and line.count("@") >= 1)
    check("[dp4] /metrics reports one health series per rank",
          ranks_in_metrics == 4, "%d series" % ranks_in_metrics)
    # /engine_metrics concatenates the path onto record.url (router.lua's
    # engine_metrics_handler), so it is the case where the rank suffix is not at the
    # end of the string that gets dialed: "http://h:p@2/metrics".
    st, merged, _ = http("GET", "http://127.0.0.1:%d/engine_metrics" % port)
    check("[dp4] the path-concatenating /engine_metrics fan-out dials rank urls",
          st == 200 and "mock_probe" in merged, "%s %s" % (st, merged[:200]))

    # --- one rank can be torn down on its own -------------------------------
    before = urls(port)
    victim = before[0]
    victim_id = [w for w in (workers(port) or []) if w["url"] == victim][0]["id"]
    st, body, _ = http("DELETE", "http://127.0.0.1:%d/workers/%s" % (port, victim_id))
    check("[dp4] DELETE a rank answers 202", st == 202, "%s %s" % (st, body[:200]))
    check("[dp4] rank teardown removes only that rank",
          wait_missing(port, victim, timeout=20)
          and sorted((urls(port) or [])) == sorted(before[1:]), urls(port))

    # --- and the rank comes back without re-expanding -----------------------
    st, body, _ = http("POST", "http://127.0.0.1:%d/workers" % port, {"url": victim})
    check("[dp4] a removed rank re-registers as a rank", st == 202, "%s %s" % (st, body[:200]))
    check("[dp4] no nested expansion: still exactly 4 ranks",
          wait_urls(port, ranks, timeout=25), urls(port))
    stop(name)

    # --- dp_size=1 ----------------------------------------------------------
    _, wp1 = start_dp("dp1", dp_size=1, model="solo")
    name = "lr-dp1-%s" % RUN
    port = start_router_local({"SMG_DP_AWARE": "1", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                               "SMG_WORKER_URLS": "http://127.0.0.1:%d" % wp1}, name)
    check("[dp1] dp_size=1 does not expand", wait_workers(port, 1, timeout=25), urls(port))
    check("[dp1] the single entry keeps the plain url",
          urls(port) == ["http://127.0.0.1:%d" % wp1], urls(port))
    check("[dp1] it becomes healthy and serves", wait_healthy(port, 1, timeout=20),
          json.dumps(workers(port)))
    st, body, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                       {"model": "solo", "messages": [{"role": "user", "content": "solo"}]})
    check("[dp1] non-expanded worker answers", st == 200 and "echo[solo]" in body,
          "%s %s" % (st, body[:150]))
    check("[dp1] a worker without dp_rank gets the body untouched (no injection)",
          "data_parallel_rank" not in json.loads(body).get("echo_body", {}),
          json.dumps(json.loads(body).get("echo_body", {}))[:200])
    stop(name)

    # --- /server_info 500 ---------------------------------------------------
    _, wp2 = start_dp("dpfail", dp_size=4, model="broken", mode="fail")
    name = "lr-dpfail-%s" % RUN
    port = start_router_local({"SMG_DP_AWARE": "1", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                               "SMG_WORKER_URLS": "http://127.0.0.1:%d" % wp2}, name)
    stay = ["http://127.0.0.1:%d" % wp2]
    check("[dpfail] a failing /server_info does not expand",
          wait_workers(port, 1, timeout=20), urls(port))
    check("[dpfail] the base worker is kept and becomes healthy",
          wait_healthy(port, 1, timeout=20), json.dumps(workers(port)))
    time.sleep(4)
    check("[dpfail] still exactly one candidate after more sweeps",
          urls(port) == stay, urls(port))
    stop(name)

    # --- /server_info 200 without dp_size -----------------------------------
    _, wp3 = start_dp("dpmissing", dp_size=4, model="nodoc", mode="missing")
    name = "lr-dpmissing-%s" % RUN
    port = start_router_local({"SMG_DP_AWARE": "1", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                               "SMG_WORKER_URLS": "http://127.0.0.1:%d" % wp3}, name)
    check("[dpmissing] /server_info without a usable dp_size does not expand",
          wait_workers(port, 1, timeout=20), urls(port))
    check("[dpmissing] the worker is still routable",
          (workers(port) or [{}])[0].get("model_id") == "nodoc", json.dumps(workers(port)))
    stop(name)

    # --- /get_server_info fallback ------------------------------------------
    _, wp4 = start_dp("dplegacy", dp_size=2, model="legacy", only_legacy=True)
    name = "lr-dplegacy-%s" % RUN
    port = start_router_local({"SMG_DP_AWARE": "1", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                               "SMG_WORKER_URLS": "http://127.0.0.1:%d" % wp4}, name)
    base4 = "http://127.0.0.1:%d" % wp4
    check("[dplegacy] the /get_server_info spelling expands dp_size=2",
          wait_urls(port, ["%s@0" % base4, "%s@1" % base4], timeout=25), urls(port))
    stop(name)

    # --- SMG_DP_AWARE off ---------------------------------------------------
    _, wp5 = start_dp("dpoff", dp_size=4, model="off")
    name = "lr-dpoff-%s" % RUN
    port = start_router_local({"SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                               "SMG_WORKER_URLS": "http://127.0.0.1:%d" % wp5}, name)
    check("[dpoff] SMG_DP_AWARE unset leaves a dp_size=4 engine as one worker",
          wait_workers(port, 1, timeout=20), urls(port))
    stop(name)


# --------------------------------------------------------------------- group B
def group_k8s():
    _, p1 = start_dp("pod0", dp_size=1, model="pod-model")
    _, p2 = start_dp("pod1", dp_size=1, model="pod-model")
    url1, url2 = "http://127.0.0.1:%d" % p1, "http://127.0.0.2:%d" % p1

    api, api_port = start_k8s(mode="forbidden")
    name = "lr-k8s-%s" % RUN
    env = {"SMG_SERVICE_DISCOVERY": "1",
           "SMG_SELECTOR": "app=sglang",
           "SMG_KUBE_API_SERVER": "http://127.0.0.1:%d" % api_port,
           "SMG_SERVICE_DISCOVERY_PORT": str(p1),
           "SMG_SERVICE_DISCOVERY_NAMESPACE": "team-a",
           "SMG_SERVICE_DISCOVERY_CHECK_INTERVAL_SECS": "1",
           "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
           "SMG_HEALTH_CHECK_TIMEOUT_SECS": "3"}
    port = start_router_local(env, name)

    check("[k8s] 403 from the API server registers no workers",
          wait_api_calls(api, 3, timeout=25) and urls(port) == [], urls(port))
    check("[k8s] a failed list is counted in smg_discovery_registrations_total",
          wait_metric(port, "smg_discovery_registrations_total", 'result="failed"') is not None,
          metrics(port)[:400])
    check("[k8s] the 403 names the permission to fix",
          "403" in logs(name) or "Forbidden" in logs(name), logs(name)[-400:])
    paths = k8s_state(api)["paths"]
    check("[k8s] the poll uses the namespaced list path with a labelSelector",
          any("/api/v1/namespaces/team-a/pods" in path and "labelSelector" in path
              for path in paths), json.dumps(paths[-3:]))
    check("[k8s] no service account token means no Authorization header",
          k8s_state(api)["last_auth"] == "", repr(k8s_state(api)["last_auth"]))

    set_k8s(api, mode="ok", fixture="pods_single.json")
    check("[k8s] the set recovers once the API server answers",
          wait_present(port, url1, timeout=30), urls(port))
    def wait_model(want_url, want_model, timeout=30):
        for _ in range(int(timeout / 0.5)):
            found = [w for w in (workers(port) or []) if w["url"] == want_url]
            if found and found[0].get("model_id") == want_model:
                return found[0]
            time.sleep(0.5)
        return (workers(port) or [])
    check("[k8s] the worker carries the pod labels (gpu)",
          url1 in (urls(port) or []) and wait_model(url1, "pod-model").get("model_id") == "pod-model",
          json.dumps(workers(port)))
    found = wait_model(url1, "pod-model")
    check("[k8s] the worker is marked as kubernetes-discovered",
          found.get("metadata", {}).get("discovered") == "kubernetes", json.dumps(found))
    check("[k8s] the pod's model is learned from the engine by the metadata sweep",
          found.get("model_id") == "pod-model", json.dumps(found))
    check("[k8s] the discovered worker becomes healthy",
          wait_healthy(port, 1, timeout=25), json.dumps(workers(port)))
    st, body, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                       {"model": "pod-model", "messages": [{"role": "user", "content": "k8s probe"}]})
    check("[k8s] chat is routed to the discovered pod",
          st == 200 and "echo[pod-model]" in body, "%s %s" % (st, body[:200]))
    check("[k8s] successful registrations counted",
          wait_metric(port, "smg_discovery_registrations_total", 'result="success"') is not None,
          metrics(port)[:400])
    check("[k8s] the discovered-worker gauge is exported",
          wait_metric(port, "smg_discovery_workers_discovered") is not None, metrics(port)[:400])

    # C1: every layer-4 family that has samples must be *declared*, not just
    # counted. Rust describes all four in init_metrics, and a text file whose
    # family has no TYPE line is rejected by a strict scraper; the missing HELP
    # lines were the gap gap-discovery-dp.md 2.5 flagged. Checked family by family
    # as each one first gets a sample, because an empty family is deliberately
    # absent here (the renderer does not emit `# TYPE x untyped` over nothing),
    # so asserting all four at once would be asserting the wrong contract.
    declared = {}

    def described(family, want_type, timeout=30):
        """Poll until `family` renders exactly one HELP and one TYPE of kind
        want_type; returns the first failure string or ""."""
        detail = ""
        for _ in range(int(timeout / 0.5)):
            body = metrics(port)
            helps = [l for l in body.splitlines() if l.startswith("# HELP " + family + " ")]
            types = [l for l in body.splitlines() if l.startswith("# TYPE " + family + " ")]
            ok = (len(helps) == 1 and len(types) == 1
                  and types[0] == "# TYPE %s %s" % (family, want_type))
            if ok:
                declared[family] = types[0]
                return ""
            detail = "helps=%d types=%s" % (len(helps), types)
            time.sleep(0.5)
        return detail

    check("[k8s] the sync-duration histogram is recorded by the poll",
          wait_for_text(port, "smg_discovery_sync_duration_seconds_count{") is not None,
          metrics(port)[-400:])
    for fam, kind in (("smg_discovery_registrations_total", "counter"),
                      ("smg_discovery_workers_discovered", "gauge"),
                      ("smg_discovery_sync_duration_seconds", "histogram")):
        why = described(fam, kind)
        check("[k8s] %s is described once as a %s (Rust parity)" % (fam, kind),
              why == "", why)
    # The histogram is the one family Rust declares but never reaches (its watch
    # loop has no equivalent timer), so the Lua poll is the gateway that actually
    # populates it: one sample per list attempt, labelled by source.
    text = metrics(port)
    samples = [line for line in text.splitlines()
               if line.startswith("smg_discovery_sync_duration_seconds_count{")]
    check("[k8s] the poll records its own sync duration",
          len(samples) == 1 and 'source="kubernetes"' in samples[0]
          and float(samples[0].rsplit(" ", 1)[-1]) >= 1, "\n".join(samples) or text[-300:])
    # The default ladder is 20 bounds and the exporter adds the +Inf series, so a
    # populated histogram is 21 bucket lines per label set with +Inf == _count.
    buckets = [line for line in text.splitlines()
               if line.startswith('smg_discovery_sync_duration_seconds_bucket{source="kubernetes"')]
    inf = [line for line in buckets if 'le="+Inf"' in line]
    count = metric_value(text, "smg_discovery_sync_duration_seconds_count",
                         'source="kubernetes"')
    check("[k8s] the sync histogram carries the full bucket ladder and +Inf == _count",
          len(buckets) == 21 and len(inf) == 1 and count is not None
          and float(inf[0].rsplit(" ", 1)[-1]) == count,
          "%d buckets, inf=%s count=%s" % (len(buckets), inf[:1], count))

    set_k8s(api, fixture="pods_two.json")
    check("[k8s] a new Ready pod is registered",
          wait_urls(port, [url1, url2], timeout=30), urls(port))

    # The fake API server ignores labelSelector, so removal can only come from the
    # router re-checking the labels it received.
    set_k8s(api, fixture="pods_selector_flip.json")
    check("[k8s] a pod whose labels stop matching is deregistered",
          wait_missing(port, url1, timeout=30) and wait_urls(port, [url2], timeout=20),
          urls(port))
    check("[k8s] deregistration counted with reason=pod_deleted",
          wait_metric(port, "smg_discovery_deregistrations_total", 'reason="pod_deleted"') is not None,
          metrics(port)[:400])
    why = described("smg_discovery_deregistrations_total", "counter")
    check("[k8s] the deregistration counter appears and is described once",
          why == "", why)
    check("[k8s] all four layer-4 families are declared with the Rust types",
          all(f in declared for f in ("smg_discovery_registrations_total",
                                       "smg_discovery_deregistrations_total",
                                       "smg_discovery_workers_discovered",
                                       "smg_discovery_sync_duration_seconds"))
          and [declared.get(f) for f in sorted(declared)] == [
              "# TYPE smg_discovery_deregistrations_total counter",
              "# TYPE smg_discovery_registrations_total counter",
              "# TYPE smg_discovery_sync_duration_seconds histogram",
              "# TYPE smg_discovery_workers_discovered gauge"],
          json.dumps(declared))

    set_k8s(api, fixture="pods_unready.json")
    check("[k8s] a pod that stops being Ready is deregistered",
          wait_urls(port, [url2], timeout=25), urls(port))

    set_k8s(api, fixture="pods_two.json")
    check("[k8s] a pod that becomes Ready again is re-registered",
          wait_urls(port, [url1, url2], timeout=30), urls(port))

    set_k8s(api, mode="error")
    time.sleep(3)
    check("[k8s] an API server 500 leaves the current workers untouched",
          urls(port) == [url1, url2], urls(port))
    set_k8s(api, mode="ok", fixture="pods_two.json")

    victim = (workers(port) or [{}])[0]["id"]
    http("DELETE", "http://127.0.0.1:%d/workers/%s" % (port, victim))
    check("[k8s] a manually deleted pod worker is re-registered while the pod lives",
          wait_workers(port, 2, timeout=20), urls(port))
    stop(name)

    # --- service account token ---------------------------------------------
    sa_dir = os.path.join(TMP, "lr-sa-%s" % RUN)
    os.makedirs(sa_dir, exist_ok=True)
    with open(os.path.join(sa_dir, "token"), "w") as f:
        f.write("sa-token-for-lua-router\n")
    api2, api2_port = start_k8s(mode="ok", fixture="pods_single.json")
    name = "lr-k8ssa-%s" % RUN
    env2 = dict(env)
    env2["SMG_KUBE_API_SERVER"] = "http://127.0.0.1:%d" % api2_port
    port = start_router_local(env2, name,
                              volumes=[(sa_dir, "/var/run/secrets/kubernetes.io/serviceaccount")])
    check("[k8s] discovery works against a cluster with a mounted service account",
          wait_present(port, url1, timeout=30), urls(port))
    # The token file is read per poll (a rotation must be picked up), so the
    # evidence is "some poll presented it", not "the last one did".
    bearer = "Bearer sa-token-for-lua-router"
    seen_bearer = False
    for _ in range(60):
        if bearer in k8s_state(api2)["auths"]:
            seen_bearer = True
            break
        time.sleep(0.5)
    check("[k8s] the SA token is presented as a bearer token", seen_bearer,
          repr(k8s_state(api2)["auths"][-3:]))
    stop(name)

    # --- PD selectors, SMG_GRPC off: the existing 400 contract is kept -------
    api3, api3_port = start_k8s(mode="ok", fixture="pods_prefill.json")
    name = "lr-k8spd-%s" % RUN
    env3 = dict(env2)
    env3["SMG_KUBE_API_SERVER"] = "http://127.0.0.1:%d" % api3_port
    env3["SMG_PREFILL_SELECTOR"] = "component=prefill"
    env3["SMG_DECODE_SELECTOR"] = "component=decode"
    env3.pop("SMG_SELECTOR", None)
    port = start_router_local(env3, name)
    check("[k8s-pd] PD pods are claimed (and refused) while SMG_GRPC is off",
          wait_metric(port, "smg_discovery_registrations_total", 'result="failed"') is not None,
          metrics(port)[:400])
    check("[k8s-pd] no prefill worker is stored without the gRPC plane",
          all("prefill" not in json.dumps(w) or w.get("worker_type") != "prefill"
              for w in (workers(port) or [])), urls(port))
    check("[k8s-pd] the refusal names the registry contract",
          "worker_type" in logs(name), logs(name)[-500:])
    stop(name)

    # --- PD selectors with SMG_GRPC on: prefill lands with its bootstrap port -
    grpc_port = free_port()
    api5, api5_port = start_k8s(mode="ok", fixture="pods_prefill.json")
    name = "lr-k8spdg-%s" % RUN
    env5 = dict(env3)
    env5["SMG_KUBE_API_SERVER"] = "http://127.0.0.1:%d" % api5_port
    env5["SMG_GRPC"] = "1"
    env5["SMG_GRPC_PORT"] = str(grpc_port)
    port = start_router_local(env5, name,
                              volumes=[(sa_dir, "/var/run/secrets/kubernetes.io/serviceaccount")])
    ok = wait_present(port, url1, timeout=30)
    ws = [w for w in (workers(port) or []) if w["url"] == url1]
    check("[k8s-pdg] with SMG_GRPC on, a prefill pod registers as a prefill worker",
          ok and ws and ws[0].get("worker_type") == "prefill", json.dumps(workers(port)))
    check("[k8s-pdg] the bootstrap port comes from the sglang annotation",
          ws and str(ws[0].get("bootstrap_port")) == "8998", json.dumps(ws))
    stop(name)

    # --- discovery off ------------------------------------------------------
    api4, api4_port = start_k8s(mode="ok", fixture="pods_two.json")
    name = "lr-k8soff-%s" % RUN
    env4 = {"SMG_SELECTOR": "app=sglang",
            "SMG_KUBE_API_SERVER": "http://127.0.0.1:%d" % api4_port,
            "SMG_SERVICE_DISCOVERY_PORT": str(p2),
            "SMG_SERVICE_DISCOVERY_CHECK_INTERVAL_SECS": "1",
            "SMG_HEALTH_CHECK_INTERVAL_SECS": "1"}
    reset_api_calls(api4)
    port = start_router_local(env4, name)
    time.sleep(4)
    check("[k8soff] SMG_SERVICE_DISCOVERY unset registers no pods",
          urls(port) == [], urls(port))
    check("[k8soff] and the API server is never polled",
          k8s_state(api4)["discovery_calls"] == 0, k8s_state(api4))
    stop(name)

    # --- enabled with no cluster: explicit disabled log ---------------------
    name = "lr-k8snone-%s" % RUN
    env6 = {"SMG_SERVICE_DISCOVERY": "1", "SMG_SELECTOR": "app=sglang",
            "SMG_SERVICE_DISCOVERY_CHECK_INTERVAL_SECS": "1",
            "SMG_HEALTH_CHECK_INTERVAL_SECS": "1"}
    port = start_router_local(env6, name)
    time.sleep(3)
    log = logs(name)
    check("[k8snone] enabled without an API server says discovery is disabled",
          "discovery is disabled" in log
          and "KUBERNETES_SERVICE_HOST is unset" in log, log[-600:])
    check("[k8snone] and the router still serves",
          http("GET", "http://127.0.0.1:%d/health" % port)[0] == 200)
    stop(name)


# ----------------------------------------------------- group C: discovery + DP
def group_discovery_dp():
    """A data-parallel engine discovered through Kubernetes.

    Discovery speaks in pod urls while the engine is stored as "<pod url>@<rank>"
    entries, so the reconcile has to treat the ranks as covering their pod. If it
    does not, every poll deletes the ranks and re-expands them: the counter check
    below is what catches that, because a flapping reconcile registers the pod
    once per interval and deregisters four workers per interval.
    """
    _, wport = start_dp("dpk8s", dp_size=4, model="dpk-model")
    api, api_port = start_k8s(mode="ok", fixture="pods_single.json")
    name = "lr-dpk8s-%s" % RUN
    env = {"SMG_SERVICE_DISCOVERY": "1",
           "SMG_SELECTOR": "app=sglang",
           "SMG_DP_AWARE": "1",
           "SMG_KUBE_API_SERVER": "http://127.0.0.1:%d" % api_port,
           "SMG_SERVICE_DISCOVERY_PORT": str(wport),
           "SMG_SERVICE_DISCOVERY_CHECK_INTERVAL_SECS": "1",
           "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
           "SMG_HEALTH_CHECK_TIMEOUT_SECS": "3"}
    port = start_router_local(env, name)

    base = "http://127.0.0.1:%d" % wport
    ranks = ["%s@%d" % (base, i) for i in range(4)]
    check("[dpk8s] a discovered DP engine expands into ranks of the pod url",
          wait_urls(port, ranks, timeout=35), urls(port))
    check("[dpk8s] the ranks turn healthy", wait_healthy(port, 4, timeout=30),
          json.dumps(workers(port)))

    # Six further intervals: enough that a flapping reconcile would show up as a
    # rising registration counter.
    time.sleep(8)
    check("[dpk8s] no flapping: still exactly the four ranks",
          urls(port) == ranks, urls(port))
    text = metrics(port)
    added = metric_value(text, "smg_discovery_registrations_total", 'result="success"') or 0
    gone = metric_value(text, "smg_discovery_deregistrations_total", 'reason="pod_deleted"') or 0
    check("[dpk8s] the pod was registered once, not once per poll",
          added == 1, "registrations=success is %s" % added)
    check("[dpk8s] nothing was deregistered while the pod kept running",
          gone == 0, "deregistrations=pod_deleted is %s" % gone)
    st, body, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                       {"model": "dpk-model", "messages": [{"role": "user", "content": "dp+k8s"}]})
    check("[dpk8s] inference works on a discovered rank", st == 200 and "echo[dpk-model]" in body,
          "%s %s" % (st, body[:200]))

    # The pod goes away: all four ranks leave with it, in one reconcile.
    set_k8s(api, fixture="pods_none.json")
    check("[dpk8s] a vanished pod tears down every rank",
          wait_workers(port, 0, timeout=30), urls(port))
    gone = metric_value(metrics(port), "smg_discovery_deregistrations_total",
                        'reason="pod_deleted"') or 0
    check("[dpk8s] the rank teardown is counted as pod deletion", gone >= 4,
          "deregistrations=pod_deleted is %s" % gone)

    # And it comes back: registered once, then expanded again.
    set_k8s(api, fixture="pods_single.json")
    check("[dpk8s] the pod returns and is expanded again",
          wait_urls(port, ranks, timeout=40), urls(port))
    added = metric_value(metrics(port), "smg_discovery_registrations_total", 'result="success"') or 0
    check("[dpk8s] the returning pod was registered once, not once per rank",
          added == 2, "registrations=success is %s" % added)
    stop(name)


# --------------------------------------------------------------------- group D
def group_k8s_watch():
    """Watch transport: incremental events, resume-after-drop, 410 relist, fieldSelector."""
    _, wport = start_dp("watchpod", dp_size=1, model="watch-model")
    url1, url2 = "http://127.0.0.1:%d" % wport, "http://127.0.0.2:%d" % wport

    pod_a = pod_obj("sglang-watch-0", "127.0.0.1")
    api, api_port = start_k8s()
    k8s_doc(api, pod_doc([pod_a], 1001))
    name = "lr-k8sw-%s" % RUN
    env = {"SMG_SERVICE_DISCOVERY": "1",
           "SMG_SERVICE_DISCOVERY_WATCH": "1",
           "SMG_SELECTOR": "app=sglang",
           "SMG_KUBE_API_SERVER": "http://127.0.0.1:%d" % api_port,
           "SMG_SERVICE_DISCOVERY_PORT": str(wport),
           "SMG_SERVICE_DISCOVERY_CHECK_INTERVAL_SECS": "1",
           "SMG_SERVICE_DISCOVERY_WATCH_IDLE_TIMEOUT_SECS": "3",
           "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
           "SMG_HEALTH_CHECK_TIMEOUT_SECS": "3"}
    port = start_router_local(env, name)

    check("[watch] the initial list registers the pod it contains",
          wait_present(port, url1, timeout=40), urls(port))
    check("[watch] the stream is opened with watch=true",
          wait_watch_matching(api, ["watch=true"]) is not None,
          json.dumps(k8s_watch_requests(api)[-3:]))
    check("[watch] the stream resumes from the list's resourceVersion",
          wait_watch_matching(api, ["watch=true", "resourceVersion="]) is not None,
          json.dumps(k8s_watch_requests(api)[-3:]))
    check("[watch] the label selector is sent on the stream, not only on the list",
          wait_watch_matching(api, ["watch=true", "labelSelector=app%3Dsglang"]) is not None,
          json.dumps(k8s_watch_requests(api)[-3:]))
    # --- ADDED -----------------------------------------------------------------
    k8s_watch_push(api, "ADDED", pod_obj("sglang-watch-1", "127.0.0.2"))
    check("[watch] an ADDED pod is registered without another list",
          wait_present(port, url2, timeout=30), urls(port))
    listed_after_add = k8s_list_calls(api)
    text = metrics(port)
    check("[watch] the ADDED event is counted",
          (metric_value(text, "smg_discovery_watch_events_total", 'type="added"') or 0) >= 1,
          text and [l for l in text.splitlines() if "watch_events" in l])

    # --- MODIFIED to unready --------------------------------------------------
    k8s_watch_push(api, "MODIFIED", pod_obj("sglang-watch-1", "127.0.0.2", ready=False))
    check("[watch] a MODIFIED pod that stops being Ready is deregistered",
          wait_missing(port, url2, timeout=30), urls(port))
    check("[watch] the MODIFIED event is counted",
          (metric_value(metrics(port), "smg_discovery_watch_events_total",
                        'type="modified"') or 0) >= 1,
          [l for l in metrics(port).splitlines() if "watch_events" in l])
    check("[watch] deregistration is counted as pod deletion",
          (metric_value(metrics(port), "smg_discovery_deregistrations_total",
                        'reason="pod_deleted"') or 0) >= 1,
          [l for l in metrics(port).splitlines() if "deregistrations" in l])

    # --- MODIFIED back to ready ----------------------------------------------
    k8s_watch_push(api, "MODIFIED", pod_obj("sglang-watch-1", "127.0.0.2", ready=True))
    check("[watch] a MODIFIED pod that becomes Ready again is re-registered",
          wait_present(port, url2, timeout=30), urls(port))

    # --- DELETED --------------------------------------------------------------
    k8s_watch_push(api, "DELETED", pod_obj("sglang-watch-1", "127.0.0.2"))
    check("[watch] a DELETED pod is deregistered",
          wait_missing(port, url2, timeout=30), urls(port))
    check("[watch] the DELETED event is counted",
          (metric_value(metrics(port), "smg_discovery_watch_events_total",
                        'type="deleted"') or 0) >= 1,
          [l for l in metrics(port).splitlines() if "watch_events" in l])
    check("[watch] only the deleted pod's worker went away",
          urls(port) == [url1], urls(port))

    # --- resume after the server hangs up ------------------------------------
    before_lists = k8s_list_calls(api)
    k8s_watch_close_streams(api)
    k8s_watch_push(api, "ADDED", pod_obj("sglang-watch-2", "127.0.0.3"))
    check("[watch] the pod added while disconnected arrives after the reconnect",
          wait_present(port, "http://127.0.0.3:%d" % wport, timeout=45), urls(port))
    check("[watch] resuming used the resourceVersion, not a fresh list",
          k8s_list_calls(api) == before_lists,
          "list calls %d -> %d" % (before_lists, k8s_list_calls(api)))
    check("[watch] the reconnect is counted",
          (metric_value(metrics(port), "smg_discovery_watch_reconnects_total") or 0) >= 1,
          [l for l in metrics(port).splitlines() if "watch_reconnects" in l])
    resumed = [p for p in k8s_watch_requests(api)
               if "watch=true" in p and watch_rv_of(p) is not None]
    check("[watch] every reconnect carries a resume point",
          len(resumed) >= 2, json.dumps(k8s_watch_requests(api)[-3:]))

    # --- 410 Gone -> relist --------------------------------------------------
    # The list is made authoritative first, exactly as a real API server's would
    # be: everything the stream already reported is in etcd, so the relist has to
    # reproduce the same worker set rather than lose the watched pods.
    pod_c = pod_obj("sglang-watch-2", "127.0.0.3")
    url3 = "http://127.0.0.3:%d" % wport
    k8s_doc(api, pod_doc([pod_a, pod_c], None))
    before_lists = k8s_list_calls(api)
    k8s_watch_gone(api)
    check("[watch] a 410 is counted as a gone error",
          wait_metric(port, "smg_discovery_watch_errors_total", 'kind="gone"') is not None,
          [l for l in metrics(port).splitlines() if "watch_errors" in l])
    relisted = False
    for _ in range(80):
        if k8s_list_calls(api) > before_lists:
            relisted = True
            break
        time.sleep(0.25)
    check("[watch] a 410 resets the resume point and forces a fresh list",
          relisted, "list calls %d -> %d" % (before_lists, k8s_list_calls(api)))
    check("[watch] the relist rebuilds the same worker set (nothing lost to the reset)",
          sorted(urls(port) or []) == sorted([url1, url3]), urls(port))
    streams_before = len(k8s_watch_requests(api))
    reopened = wait_watch_streams(api, streams_before)
    check("[watch] the stream comes back after the relist",
          reopened is not None and "watch=true" in reopened,
          "streams %d -> %d, last %s" % (streams_before, len(k8s_watch_requests(api)),
                                         json.dumps(k8s_watch_requests(api)[-1])))

    # The gauge still reports both pods, which is what the poll path exports too.
    gauge = metric_value(metrics(port), "smg_discovery_workers_discovered")
    check("[watch] the discovered-pod gauge tracks the watched set",
          gauge is not None and gauge >= 2, "gauge=%s" % gauge)
    check("[watch] watch mode still serves inference",
          http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
               {"model": "watch-model",
                "messages": [{"role": "user", "content": "watched"}]})[0] == 200,
          logs(name)[-300:])
    stop(name)

    # --- fieldSelector on the poll path (the parameter, and the local recheck) --
    api2, api2_port = start_k8s(fixture="pods_two.json")
    name = "lr-k8sf-%s" % RUN
    env = {"SMG_SERVICE_DISCOVERY": "1",
           "SMG_SELECTOR": "app=sglang",
           "SMG_KUBE_FIELD_SELECTOR": "metadata.name=sglang-regular-0",
           "SMG_KUBE_API_SERVER": "http://127.0.0.1:%d" % api2_port,
           "SMG_SERVICE_DISCOVERY_PORT": str(wport),
           "SMG_SERVICE_DISCOVERY_CHECK_INTERVAL_SECS": "1",
           "SMG_HEALTH_CHECK_INTERVAL_SECS": "1"}
    port = start_router_local(env, name)
    check("[fieldSelector] the parameter reaches the API server",
          wait_api_calls(api2, 2, timeout=25)
          and any("fieldSelector=metadata.name%3Dsglang-regular-0" in p
                  for p in k8s_paths(api2)),
          json.dumps(k8s_paths(api2)[-3:]))
    # The fake ignores the selector and returns both pods, so only the client-side
    # recheck can make this assertion pass: pod sglang-regular-1 must not be kept.
    check("[fieldSelector] the recheck keeps only the named pod",
          wait_present(port, url1, timeout=30) and urls(port) == [url1], urls(port))
    stop(name)


# --------------------------------------------------------------------- group E
def group_router_mesh():
    """Router-pod discovery: K8s builds the mesh membership, and no router becomes a worker."""
    p1 = free_port()
    p2 = free_port()
    self1 = "http://127.0.0.1:%d" % p1
    self2 = "http://127.0.0.2:%d" % p2

    def router_pod(name, ip, mesh_port, ready=True):
        return pod_obj(name, ip, labels={"app": "lua-router"}, ready=ready,
                       port_annotation={"sglang.ai/mesh-port": str(mesh_port)})

    both = pod_doc([router_pod("lua-router-1", "127.0.0.1", p1),
                    router_pod("lua-router-2", "127.0.0.2", p2)], 2001)
    api, api_port = start_k8s()
    k8s_doc(api, both)

    # SMG_MESH_PEERS names only this instance: the second member can only have come
    # from the pod list. That is the whole point of the feature - the static list is
    # no longer what defines the cluster.
    common = {"SMG_ENABLE_MESH": "1",
              "SMG_MESH_SYNC_INTERVAL_SECS": "1",
              # A dead peer is normally declared unreachable by the sync timeout.
              # Raise both knobs out of the way so the down state below can only
              # have been written by the pod-list retire.
              "SMG_MESH_SUSPECT_THRESHOLD": "1000",
              "SMG_MESH_UNREACHABLE_TIMEOUT_SECS": "300",
              "SMG_SERVICE_DISCOVERY": "1",
              "SMG_SELECTOR": "app=lua-router",
              "SMG_ROUTER_SELECTOR": "app=lua-router",
              "SMG_KUBE_API_SERVER": "http://127.0.0.1:%d" % api_port,
              "SMG_SERVICE_DISCOVERY_CHECK_INTERVAL_SECS": "1",
              "SMG_HEALTH_CHECK_INTERVAL_SECS": "1"}
    r1 = "lr-rpod1-%s" % RUN
    r2 = "lr-rpod2-%s" % RUN
    env1 = dict(common, SMG_MESH_SELF=self1, SMG_MESH_PEERS=self1)
    env2 = dict(common, SMG_MESH_SELF=self2, SMG_MESH_PEERS=self2)
    port1 = start_router_local(env1, r1, port=p1)
    port2 = start_router_local(env2, r2, port=p2)

    doc1 = wait_ha_member(port1, self2, "alive")
    check("[router pod] a discovered peer joins the mesh without a static peer entry",
          doc1 is not None, json.dumps(ha_doc(port1) or {})[:400])
    doc2 = wait_ha_member(port2, self1, "alive")
    check("[router pod] both routers converge on the same two-member view",
          doc2 is not None and doc1.get("node_count") == 2 and doc2.get("node_count") == 2,
          "%s / %s" % (json.dumps(doc1 or {})[:200], json.dumps(doc2 or {})[:200]))
    # The member name is not asserted: once the peer reports its own identity over
    # gossip, the key migrates from the pod name to the hostport it calls itself
    # (mesh.apply_snapshot -> migrate_member). The address is the stable handle, and
    # it only takes that value because the annotation supplied the port.
    check("[router pod] the peer address comes from the podIP plus the mesh-port annotation",
          doc1 is not None and ha_address_status(doc1, self2) == "alive",
          json.dumps(doc1.get("nodes"))[:300] if doc1 else "")

    # B.2: a router pod is never an inference worker, even though SMG_SELECTOR (the
    # worker selector) matches its labels exactly.
    check("[router pod] routers are not registered as workers (selector matches anyway)",
          urls(port1) == [] and urls(port2) == [],
          "%s / %s" % (urls(port1), urls(port2)))
    check("[router pod] the worker list stays empty on both",
          (json.loads(http("GET", "http://127.0.0.1:%d/workers" % port1)[1]).get("total") == 0)
          and (json.loads(http("GET", "http://127.0.0.1:%d/workers" % port2)[1]).get("total") == 0),
          http("GET", "http://127.0.0.1:%d/workers" % port1)[1][:200])

    # The adopted peer has to be a real sync target, not just a table entry.
    # Both sides adopt independently out of the same pod list, so the two-member
    # view proves nothing about the timer: the counter that does is the node's own
    # sync accounting, which starts one interval after the first adoption.
    synced = wait_ha_stats(port1, lambda d: (d.get("stats") or {}).get("sync_rounds", 0)
                                                  + (d.get("stats") or {}).get("sync_failures", 0) > 0)
    check("[router pod] adopting starts the gossip timer (this node tried to sync)",
          synced is not None,
          json.dumps((ha_stats(port1) or {}).get("stats") or {}))

    # The peer goes away - and it has to actually go. While the process is still
    # answering, its snapshot self-declares "alive", and mesh gives a node's own
    # declaration precedence over a peer's observation (merge_membership, and the
    # same rule the /ha/shutdown contract rests on): the down-mark would be
    # overwritten within one sync interval. Scale-down in Kubernetes is the other
    # case - container stops and the pod leaves the list - and there the mark is
    # what survives. SMG_MESH_SUSPECT_THRESHOLD/UNREACHABLE_TIMEOUT are raised so
    # that gossip timeouts cannot produce the down state: only discovery can.
    stop(r2)
    k8s_doc(api, pod_doc([router_pod("lua-router-1", "127.0.0.1", p1)], 2002))
    doc1 = wait_ha_member(port1, self2, "down")
    check("[router pod] a peer that leaves the pod list is marked down",
          doc1 is not None, json.dumps(ha_doc(port1) or {})[:400])
    check("[router pod] retiring does not delete the record (the peer must be told)",
          ha_address_status(ha_doc(port1), self2) == "down",
          json.dumps((ha_doc(port1) or {}).get("nodes"))[:300])
    # It has to *stay* down: a member that flaps back is a membership the operator
    # cannot read, and the retire sweep runs every interval.
    time.sleep(3)
    check("[router pod] the down verdict is stable across further polls",
          ha_address_status(ha_doc(port1), self2) == "down",
          json.dumps((ha_doc(port1) or {}).get("nodes"))[:300])
    check("[router pod] the retiring node keeps serving (a 2-node cluster has no quorum to lose)",
          (ha_doc(port1) or {}).get("partition") == "normal",
          json.dumps(ha_doc(port1) or {})[:300])
    check("[router pod] this node never marks itself down when its own peer entry shrinks",
          ha_address_status(ha_doc(port1), self1) == "alive",
          json.dumps((ha_doc(port1) or {}).get("nodes"))[:300])
    check("[router pod] and the surviving router still serves",
          http("GET", "http://127.0.0.1:%d/health" % port1)[0] == 200)
    stop(r1)


def main():
    leaked = sweep_leaked()
    if leaked:
        print("cleaned up leaked routers from an earlier run: %s" % ", ".join(leaked))
    try:
        group_dp()
        group_k8s()
        group_discovery_dp()
        group_k8s_watch()
        group_router_mesh()
    finally:
        for srv in SERVERS:
            try:
                # A parked watch handler holds its thread until its deadline, so the
                # fake API server has to be told to let go or an aborted run sits for
                # two and a half minutes before the process exits.
                if hasattr(srv, "k8s"):
                    with srv.k8s["lock"]:
                        srv.k8s["shutdown"] = True
                        srv.k8s["watch_cond"].notify_all()
                srv.shutdown()
                srv.server_close()
            except Exception:
                pass
        for c in CONTAINERS:
            stop(c)
    failed = [name for ok, name, _ in RESULTS if not ok]
    print("\n%d checks, %d failed" % (len(RESULTS), len(failed)))
    for name in failed:
        print("FAIL " + name)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
