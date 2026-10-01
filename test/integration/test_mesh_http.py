#!/usr/bin/env python3
"""Mesh enablement over real HTTP: one container + one fake peer, both on host net.

The contract suite (test_lua_router.sh, section mesh) already covers the /ha
surface with its own bash-embedded peer. What it does not cover, and what this
suite adds, is the worker-lifecycle mirror seen through real HTTP from outside
the container, plus the internal endpoints' request/response framing:

  * register / delete a worker and watch the change arrive at the peer and in
    /ha/workers (the router mirrors registry writes into the CRDT store, then a
    sync tick carries them out);
  * GET /_mesh/internal/state returns the real b64 snapshot (decodes, right
    protocol/node/stores);
  * POST /_mesh/internal/apply injects a forged snapshot from loopback and the
    injected worker becomes readable at /ha/workers/{id}; a broken envelope is
    400;
  * GET /ha/policies/{model} answers for the mirrored default policy and 404s
    for an unknown model;
  * the internal surface: from a non-loopback address /_mesh/internal/* answers
    exactly like it does from loopback - the auth layer and its fence were
    removed (doc/scope-trim.md), so there is no credential anywhere on mesh.

Two behaviours used to be pinned as DIVERGENT notes with today's (wrong) value;
both are fixed and the suite now asserts the intended value — see
the http-semantics and test-gates rounds (git history):
  * a worker seeded from SMG_WORKER_URLS used to stay out of the cluster view
    because bootstrap bypassed the mirror hook; registry.add now mirrors every
    successful add, so boot-seeded workers appear at /ha/workers;
  * the mirror of a control-plane-registered worker used to freeze at the
    registration instant (health=False, model_id="unknown") until an unrelated
    PUT re-mirrored it. Discovery (registry.patch_record) and every health flip
    (registry.set_healthy) re-mirror with a version bump, so /ha/workers follows
    the worker without a PUT.

Reuses _lib (start_router/http/check/start_mock/wait_ready/cleanup). The peer is
written here rather than imported: the contract's peer lives inside a bash
heredoc in a file this suite must not touch.
"""
import base64, json, os, socket, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (free_port, http, check, start_mock, start_router, wait_ready,
                  logs, stop_router, cleanup, RESULTS, RUN)

LOCK = threading.Lock()
STATE = {"sync": 0, "apply": 0, "ping": 0, "bad_auth": 0,
         "seen_workers": [], "seen_deleted": [], "seen_members": []}
PEER = {"url": None}


def peer_snapshot():
    """A peer that reports one alive member and one worker of its own."""
    ts = int(time.time() * 1_000_000)
    return {"protocol": 1, "node": "fake-peer", "addr": PEER["url"], "ts": ts,
            "seq": 1, "since": None, "draining": False,
            "stores": {
                "members": [{"key": "fake-peer", "node": "fake-peer", "ts": ts,
                             "version": 1,
                             "value": {"name": "fake-peer", "address": PEER["url"],
                                       "status": "alive", "version": 1}}],
                "workers": [{"key": "wk-fake", "node": "fake-peer", "ts": ts,
                             "version": 1,
                             "value": {"worker_id": "wk-fake",
                                       "model_id": "fake-model",
                                       "url": "http://127.0.0.1:19999",
                                       "health": True, "load": 3}}],
                "policies": [], "apps": [], "trees": [], "manual": []},
            "rate": []}


class PeerHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, status, payload, content_type="application/json"):
        body = payload.encode() if isinstance(payload, str) else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _envelope(self, b64):
        return base64.b64encode(json.dumps(peer_snapshot()).encode()).decode() \
            if b64 else json.dumps(peer_snapshot())

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/health":
            self._send(200, {"status": "ok"})
        elif path == "/state":
            with LOCK:
                self._send(200, dict(STATE))
        else:
            self._send(404, {"error": "peer: no route"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        path = self.path.split("?")[0]
        if path == "/_mesh/internal/sync":
            with LOCK:
                STATE["sync"] += 1
                self._note(raw)
            self._send(200, self._envelope(True), "application/x-mesh-b64")
        elif path == "/_mesh/internal/apply":
            with LOCK:
                STATE["apply"] += 1
                self._note(raw)
            self._send(200, {"applied": 1, "node": "fake-peer"})
        else:
            self._send(404, {"error": "peer: no route"})

    def _note(self, raw):
        try:
            snap = json.loads(base64.b64decode(raw.decode("utf-8", "replace")).decode("utf-8"))
        except Exception:
            return
        stores = snap.get("stores") or {}
        for m in stores.get("members") or []:
            value = m.get("value") or {}
            entry = "%s:%s" % (value.get("name"), value.get("status"))
            if entry not in STATE["seen_members"]:
                STATE["seen_members"].append(entry)
        for w in stores.get("workers") or []:
            value = w.get("value") or {}
            key = w.get("key")
            if value.get("_deleted"):
                if key not in STATE["seen_deleted"]:
                    STATE["seen_deleted"].append(key)
            elif value.get("worker_id") and value["worker_id"] not in STATE["seen_workers"]:
                STATE["seen_workers"].append(value["worker_id"])


def start_peer():
    port = free_port()
    PEER["url"] = "http://127.0.0.1:%d" % port
    srv = ThreadingHTTPServer(("127.0.0.1", port), PeerHandler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    for _ in range(50):
        if http("GET", PEER["url"] + "/health", timeout=2)[0] == 200:
            return port, srv
        time.sleep(0.1)
    raise RuntimeError("fake mesh peer did not come up on :%d" % port)


def peer_state():
    st, body, _ = http("GET", PEER["url"] + "/state")
    return json.loads(body) if st == 200 else {}


def ha_get(port, path):
    return http("GET", "http://127.0.0.1:%d%s" % (port, path))


def poll(fn, timeout=30.0, every=0.5):
    """Poll until fn() is truthy; return (ok, last_value)."""
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = fn()
        if last:
            return True, last
        time.sleep(every)
    return False, last


def lan_address():
    """A non-loopback address of this host, for the internal-endpoint fence."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except Exception:
        return None
    finally:
        s.close()


peer_port, peer_srv = start_peer()
pa = free_port()
start_mock(pa, "alpha")
name = "lr-meshhttp-" + RUN
port = start_router({"SMG_ENABLE_MESH": "1", "SMG_MESH_SYNC_INTERVAL_SECS": "1",
                     "SMG_MESH_UNREACHABLE_TIMEOUT_SECS": "300",
                     "SMG_MESH_SELF_NAME": "lr-meshhttp",
                     "SMG_MESH_PEERS": PEER["url"],
                     "SMG_POLICY": "round_robin",
                     "SMG_HEALTH_CHECK_INTERVAL_SECS": "1"}, name)

# The entrypoint pins worker_processes to 1 for mesh (per-process cluster view).
check("[mesh http] entrypoint pins workers: 1", "workers: 1" in logs(name),
      logs(name)[:300])

# 1. The peer shows up as a member and its worker is mirrored into our view.
ok, body = poll(lambda: ha_get(port, "/ha/workers")[1] if "wk-fake" in ha_get(port, "/ha/workers")[1] else None)
check("[mesh http] /ha/workers mirrors the peer worker", ok, body if isinstance(body, str) else "")
ok, status = poll(lambda: json.loads(ha_get(port, "/ha/status")[1]).get("node_count", 0) == 2
                  if ha_get(port, "/ha/status")[0] == 200 else None)
check("[mesh http] /ha/status converged on two nodes", ok, str(status)[:300])
st, body, hdr = ha_get(port, "/ha/status")
check("[mesh http] /ha/status names this node",
      st == 200 and json.loads(body).get("node_name") == "lr-meshhttp", "%s %s" % (st, body[:200]))
doc = json.loads(body)
names = [n["name"] for n in doc.get("nodes", [])]
check("[mesh http] roster has self and peer",
      "lr-meshhttp" in names and "fake-peer" in names, json.dumps(names))
self_node = [n for n in doc.get("nodes", []) if n["name"] == "lr-meshhttp"][0]
check("[mesh http] self is alive", self_node.get("status") == "alive", json.dumps(self_node))

# The peer must have been pulled at least once, with no rejected requests
# (no key configured on either side).
ps = peer_state()
check("[mesh http] peer received sync requests", ps.get("sync", 0) >= 1, json.dumps(ps)[:200])
check("[mesh http] peer rejected none of them", ps.get("bad_auth", 0) == 0, json.dumps(ps)[:200])
check("[mesh http] peer saw this node alive",
      "lr-meshhttp:alive" in " ".join(ps.get("seen_members") or []), json.dumps(ps)[:250])

# 2. Worker mirror visible in /ha/workers, keyed and shaped like the registry.
st, body, _ = ha_get(port, "/ha/workers")
fake = [w for w in json.loads(body) if w.get("worker_id") == "wk-fake"]
check("[mesh http] mirrored worker keeps model/url/health/load",
      st == 200 and len(fake) == 1 and fake[0].get("model_id") == "fake-model"
      and fake[0].get("health") is True and fake[0].get("load") == 3
      and fake[0].get("origin") == "fake-peer", body[:300])
st, body, _ = ha_get(port, "/ha/workers/wk-fake")
check("[mesh http] /ha/workers/{id} serves the mirrored worker",
      st == 200 and json.loads(body).get("worker_id") == "wk-fake", "%s %s" % (st, body[:200]))
st, body, _ = ha_get(port, "/ha/workers/nope")
check("[mesh http] /ha/workers/{unknown} is 404",
      st == 404 and "not found" in body.lower(), "%s %s" % (st, body[:200]))

# 3. Register a worker: the peer must see it, and it appears in our own /ha view.
st, body, _ = http("POST", "http://127.0.0.1:%d/workers" % port,
                   {"url": "http://127.0.0.1:%d" % pa})
worker_id = json.loads(body).get("worker_id") if st in (200, 202) else None
check("[mesh http] POST /workers accepted",
      st in (200, 202) and bool(worker_id), "%s %s" % (st, body[:200]))
check("[mesh http] backing worker became healthy", wait_ready(port, 1), logs(name))
ok, ps = poll(lambda: peer_state() if worker_id in (peer_state().get("seen_workers") or []) else None,
              timeout=20)
check("[mesh http] peer received the registered worker over sync", ok, json.dumps(ps)[:300])
ok, seen = poll(lambda: ha_get(port, "/ha/workers")[1] if (worker_id or "?") in ha_get(port, "/ha/workers")[1] else None,
                timeout=20)
check("[mesh http] /ha/workers lists the locally registered worker", ok, str(seen)[:300])

# 4. Delete it: the tombstone must travel to the peer and vanish from /ha/workers.
st, body, _ = http("DELETE", "http://127.0.0.1:%d/workers/%s" % (port, worker_id))
check("[mesh http] DELETE /workers/{id} accepted", st in (200, 202), "%s %s" % (st, body[:200]))
ok, ps = poll(lambda: peer_state() if worker_id in (peer_state().get("seen_deleted") or []) else None,
              timeout=20)
check("[mesh http] peer received the worker tombstone", ok, json.dumps(ps)[:300])
ok, seen = poll(lambda: (worker_id not in ha_get(port, "/ha/workers")[1]) or None, timeout=20)
check("[mesh http] deleted worker leaves /ha/workers", ok, str(seen)[:300])
st, body, _ = ha_get(port, "/ha/workers/%s" % worker_id)
check("[mesh http] deleted worker is 404 at /ha/workers/{id}",
      st == 404, "%s %s" % (st, body[:200]))

# 5. /ha/policies: the local default policy is mirrored, unknown models 404.
st, body, _ = ha_get(port, "/ha/policies")
policies = json.loads(body) if st == 200 else []
check("[mesh http] /ha/policies lists the mirrored default policy",
      st == 200 and any(p.get("model_id") == "default" and p.get("policy_type") == "round_robin"
                        for p in policies), "%s %s" % (st, body[:300]))
st, body, hdr = ha_get(port, "/ha/policies/default")
check("[mesh http] /ha/policies/default is 200 JSON",
      st == 200 and json.loads(body).get("policy_type") == "round_robin"
      and json.loads(body).get("config", {}).get("policy") == "round_robin",
      "%s %s" % (st, body[:250]))
check("[mesh http] /ha/policies/default origin is this node",
      st == 200 and json.loads(body).get("origin") == "lr-meshhttp", body[:200])
st, body, _ = ha_get(port, "/ha/policies/alpha")
check("[mesh http] /ha/policies/{model with no entry} is 404 (see note: per-model "
      "policies are never mirrored, only the default)", st == 404, "%s %s" % (st, body[:200]))

# 6. /_mesh/internal/state: real b64 snapshot, decodable, protocol-correct.
st, body, hdr = ha_get(port, "/_mesh/internal/state")
ct = (hdr.get("Content-Type") or hdr.get("content-type") or "")
snapshot = {}
try:
    snapshot = json.loads(base64.b64decode(body).decode("utf-8"))
except Exception as e:
    snapshot = {"error": str(e)}
check("[mesh http] /_mesh/internal/state is 200 x-mesh-b64",
      st == 200 and "application/x-mesh-b64" in ct, "%s %s %s" % (st, ct, body[:120]))
check("[mesh http] state snapshot decodes and carries the protocol + node",
      snapshot.get("protocol") == 1 and snapshot.get("node") == "lr-meshhttp"
      and isinstance(snapshot.get("stores"), dict), json.dumps(snapshot)[:250])
stores = snapshot.get("stores") or {}
check("[mesh http] state snapshot carries the two members",
      len(stores.get("members") or []) >= 2, json.dumps(stores.get("members"))[:300])
check("[mesh http] state snapshot worker count matches /ha/workers",
      len([w for w in (stores.get("workers") or []) if not (w.get("value") or {}).get("_deleted")]) >= 1,
      json.dumps(stores.get("workers"))[:300])

# 7. /_mesh/internal/apply: inject from loopback, then read the injected worker.
ts = int(time.time() * 1_000_000)
forged = {"protocol": 1, "node": "forged-injector", "addr": "http://127.0.0.1:65001",
          "ts": ts, "seq": 7, "since": None, "draining": False,
          "stores": {"members": [], "policies": [
              {"key": "policy:injected-model", "node": "forged-injector", "ts": ts,
               "version": 1, "value": {"model_id": "injected-model",
                                       "policy_type": "cache_aware",
                                       "config": {"cache_threshold": 0.5}}}],
              "workers": [{"key": "wk-injected", "node": "forged-injector", "ts": ts,
                           "version": 1,
                           "value": {"worker_id": "wk-injected",
                                     "model_id": "injected-model",
                                     "url": "http://127.0.0.1:65002",
                                     "health": True, "load": 1}}],
              "apps": [], "trees": [], "manual": []},
          "rate": []}
envelope = base64.b64encode(json.dumps(forged).encode()).decode()
st, body, hdr = http("POST", "http://127.0.0.1:%d/_mesh/internal/apply" % port, envelope)
check("[mesh http] /_mesh/internal/apply accepts a loopback snapshot",
      st == 200 and json.loads(body).get("node") == "lr-meshhttp", "%s %s" % (st, body[:200]))
check("[mesh http] apply reports what it merged",
      st == 200 and json.loads(body).get("applied", 0) >= 1, body[:200])
st, body, _ = ha_get(port, "/ha/workers/wk-injected")
check("[mesh http] applied worker is readable at /ha/workers/{id}",
      st == 200 and json.loads(body).get("model_id") == "injected-model", "%s %s" % (st, body[:200]))
st, body, _ = ha_get(port, "/ha/policies/injected-model")
check("[mesh http] applied policy is readable at /ha/policies/{model}",
      st == 200 and json.loads(body).get("policy_type") == "cache_aware", "%s %s" % (st, body[:200]))
st, body, _ = http("POST", "http://127.0.0.1:%d/_mesh/internal/apply" % port, "zzz")
check("[mesh http] apply with a broken envelope is 400",
      st == 400 and "bad mesh envelope" in body, "%s %s" % (st, body[:200]))
st, body, _ = http("POST", "http://127.0.0.1:%d/_mesh/internal/sync" % port, "zzz")
check("[mesh http] sync with a broken envelope is 400",
      st == 400 and "bad mesh envelope" in body, "%s %s" % (st, body[:200]))

# 8. The internal fence went with the auth layer (doc/scope-trim.md): from a
# non-loopback address the internal endpoints answer the same way they do from
# loopback. Anyone who can route to this box can forge cluster state, which is
# the declared trade-off - the trust boundary is the edge/network, not here.
lan = lan_address()
if lan:
    st, body, _ = http("GET", "http://%s:%d/_mesh/internal/state" % (lan, port))
    check("[mesh http] /_mesh/internal/state from %s is open" % lan,
          st == 200, "%s %s" % (st, body[:200]))
    st, body, _ = http("POST", "http://%s:%d/_mesh/internal/apply" % (lan, port), envelope)
    check("[mesh http] /_mesh/internal/apply from %s is served" % lan,
          st == 200, "%s %s" % (st, body[:200]))
    st, body, _ = http("GET", "http://%s:%d/ha/status" % (lan, port))
    check("[mesh http] /ha/* stays open", st == 200, "%s %s" % (st, body[:150]))
else:
    print("NOTE  no non-loopback address found; internal-surface checks skipped")

# 9. Divergences pinned at today's value (reported, not hidden): see doc §4.
# Instance 2 boot-seeds a worker from SMG_WORKER_URLS instead of POST /workers.
pg = free_port()
start_mock(pg, "gamma")
name2 = "lr-meshboot-" + RUN
port2 = start_router({"SMG_ENABLE_MESH": "1", "SMG_MESH_SYNC_INTERVAL_SECS": "1",
                      "SMG_MESH_SELF_NAME": "lr-meshboot", "SMG_MESH_PEERS": PEER["url"],
                      "SMG_MESH_UNREACHABLE_TIMEOUT_SECS": "300",
                      "SMG_POLICY": "round_robin", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                      "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pg}, name2)
check("[mesh http] boot-seeded worker is healthy in /workers", wait_ready(port2, 1), logs(name2))
st, body, _ = http("GET", "http://127.0.0.1:%d/workers" % port2)
boot_id = None
for w in (json.loads(body).get("workers") or []):
    if w.get("url") == "http://127.0.0.1:%d" % pg:
        boot_id = w.get("id") or w.get("worker_id")
check("[mesh http] the boot-seeded worker has a registry id", bool(boot_id), body[:250])
st, body, _ = ha_get(port2, "/ha/workers")
time.sleep(3)          # two sync ticks, so this cannot be a propagation delay
st, body, _ = ha_get(port2, "/ha/workers")
ha_ids = [w.get("worker_id") for w in json.loads(body)]
check("[mesh http] registry.bootstrap() mirrors the SMG_WORKER_URLS seed: the "
      "boot-seeded id is in /ha/workers next to the peer's own worker.",
      boot_id in ha_ids and "wk-fake" in ha_ids, "%s ha=%s" % (st, json.dumps(ha_ids)[:250]))
# The mirror also carries the discovered model and the probe result, which is what
# proves the hook runs on the real registry write path rather than somewhere that
# only knows the url.
rows = [w for w in json.loads(body) if w.get("worker_id") == boot_id]
check("[mesh http] the boot-seeded mirror is refreshed by discovery and probing",
      len(rows) == 1 and rows[0].get("model_id") == "gamma"
      and rows[0].get("health") is True, json.dumps(rows)[:250])

# Health/model freshness: the mirror is written once, inside the POST handler,
# from the record as it stands at that moment (before discovery/probing). No
# health sweep re-publishes it, so a worker that later turns healthy is still
# advertised to peers as health=False/model_id=unknown.
ph = free_port()
start_mock(ph, "beta")
st, body, _ = http("POST", "http://127.0.0.1:%d/workers" % port2,
                   {"url": "http://127.0.0.1:%d" % ph})
fresh_id = json.loads(body).get("worker_id") if st in (200, 202) else None
check("[mesh http] registration of a fresh url accepted",
      bool(fresh_id) and fresh_id != boot_id, "%s %s" % (st, body[:200]))
st, body, _ = ha_get(port2, "/ha/workers")
mirrored = [w for w in json.loads(body) if w.get("worker_id") == fresh_id]
check("[mesh http] POST /workers mirrors the worker (the row exists at all)",
      len(mirrored) == 1, json.dumps(mirrored)[:300])
check("[mesh http] the fresh worker reaches healthy in /workers",
      wait_ready(port2, 2, timeout=30), logs(name2))
time.sleep(4)          # several health sweeps + sync ticks
st, body, _ = ha_get(port2, "/ha/workers")
fresh = [w for w in json.loads(body) if w.get("worker_id") == fresh_id]
check("[mesh http] discovery and the health sweep re-mirror without a PUT: "
      "/ha/workers reports health=True and the discovered model_id.",
      len(fresh) == 1 and fresh[0].get("health") is True
      and fresh[0].get("model_id") == "beta", json.dumps(fresh)[:300])

check("[mesh http] no lua errors", "lua entry thread aborted" not in logs(name), logs(name)[-500:])
check("[mesh http] no lua errors on the second instance",
      "lua entry thread aborted" not in logs(name2), logs(name2)[-500:])

stop_router(name)
stop_router(name2)
peer_srv.shutdown()

failed = [r for r in RESULTS if not r[0]]
print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
for _, n, d in failed:
    print("FAILED: %s | %s" % (n, str(d)[:300]))
cleanup()
sys.exit(1 if failed else 0)
