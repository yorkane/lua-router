#!/usr/bin/env python3
"""Two REAL lua-router containers, mutually seeded: converge, hold, partition,
heal, retire.

Why this file exists on top of test_mesh_http.py (which pairs one container
with a scripted fake peer): the phantom-member bug was only reachable between
two routers. Each container self-reports SMG_MESH_SELF as a loopback url while
SMG_MESH_PEERS seeds the other side through the host's LAN address, so the
seed key hostport(<lan>:<port>) and the self-declared identity never match
textually. Before the fix the roster grew a third ":init" member that
outlived every sync round and eventually counted as unreachable. This suite
pins the fixed behaviour over the real HTTP/cosocket stack:

  A. convergence: node_count 2 on both sides, roster holds only the two
     self-declared names (no hostport ghost), /ha/health healthy, cluster_size 2;
  B. worker mirror both ways + the data plane still answers /v1/models and chat;
  C. long stability (18 s of live sync ticks at interval 1 s): roster never
     flaps, stats.sync_failures stays 0, >=10 sync rounds observed;
  D. partition window: docker stop B. The survivor must (i) list lr-mesh2b in
     /ha/stats unreachable_names, (ii) degrade its own view of that member to
     suspect/down, (iii) report unreachable=1 in /ha/health, (iv) keep the
     roster at two entries -- and (v) keep serving chat;
  E. heal: docker start B, both reconverge to two alive members and the
     unreachable list clears;
  F. graceful retire: POST /ha/shutdown on B -> 202 with peers_notified>=1 and
     A learns status "leaving" within a tick (a broadcast, not a timeout),
     still phantom-free.

Note on the documented partition rule (mesh.lua partition_state, doc/gap-mesh.md):
a cluster whose known membership is below SMG_MESH_MIN_CLUSTER_SIZE (default 3)
always reports partition "normal" -- two nodes have no quorum to speak of. The
assertions therefore read /ha/stats and nodes[].status for the partition
window, not the partition label.

Both routers are launched on explicit ports because _lib.start_router allocates
its own: mutual seeds have to name a port that is already known.

A control-plane key is configured on both instances: the sync dials travel to
the LAN address (host network), and the internal fence (router.lua
mesh_control_auth) only waves loopback through when *no* key is configured at
all. With SMG_CONTROL_PLANE_API_KEY the client presents it as Bearer
(mesh.auth_token, init.lua), /ha/* and POST /workers need it too, and the data
plane stays open because SMG_API_KEY is deliberately unset.
"""
import json, os, socket, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (IMAGE, CONTAINERS, free_port, http, check, start_mock,
                  logs, stop_router, cleanup, RESULTS)


def start_router_at(env, name, port):
    """_lib.start_router with a caller-chosen port (mutual seeds need it)."""
    full = {"SMG_METRICS_PORT": "0"}
    full.update(env)
    full["SMG_PORT"] = str(port)
    args = ["docker", "run", "-d", "--name", name]
    for k, v in full.items():
        args += ["-e", "%s=%s" % (k, v)]
    args += ["--network", "host", "--entrypoint", "/docker-entrypoint.sh", IMAGE,
             "/usr/local/openresty/bin/openresty", "-p", "/usr/local/openresty/nginx",
             "-g", "daemon off;"]
    subprocess.run(args, check=True, capture_output=True)
    CONTAINERS.append(name)
    for _ in range(160):
        if http("GET", "http://127.0.0.1:%d/health" % port, timeout=2)[0] == 200:
            return port
        time.sleep(0.25)
    raise RuntimeError("router %s never came up:\n%s" % (name, logs(name)))


def lan_address():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except Exception:
        return None
    finally:
        s.close()


def poll(fn, timeout=45.0, every=0.5):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            last = fn()
        except Exception:
            last = None
        if last:
            return True, last
        time.sleep(every)
    return False, last


def ha(port, path):
    st, body, _ = http("GET", "http://127.0.0.1:%d%s" % (port, path),
                       headers=AUTH, timeout=5)
    if st != 200:
        return None
    try:
        return json.loads(body)
    except Exception:
        return None


def roster(doc):
    return {n["name"]: n["status"] for n in (doc or {}).get("nodes", [])}


def ghost_keys(doc, lan):
    return sorted(k for k in roster(doc) if k.startswith("%s:" % lan))


TAG = "[mesh two]"
CTL_KEY = "sk-mesh2-ctl"
AUTH = {"authorization": "Bearer " + CTL_KEY}
LAN = lan_address()
if not LAN:
    print("FATAL  no non-loopback address: the seed-vs-self spelling needs one")
    sys.exit(1)

MESH_ENV = {"SMG_ENABLE_MESH": "1",
            "SMG_MESH_SYNC_INTERVAL_SECS": "1",
            "SMG_MESH_UNREACHABLE_TIMEOUT_SECS": "5",
            "SMG_MESH_SUSPECT_THRESHOLD": "2",
            "SMG_POLICY": "round_robin",
            "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
            "SMG_CONTROL_PLANE_API_KEY": CTL_KEY}
pa = free_port()
start_mock(pa, "alpha")
port_a, port_b = free_port(), free_port()
name_a = "lr-mesh2a-" + str(os.getpid())[-5:]
name_b = "lr-mesh2b-" + str(os.getpid())[-5:]

# The reported shape: SELF loopback, seed by LAN address of the other instance.
start_router_at(dict(MESH_ENV, SMG_MESH_SELF_NAME="lr-mesh2a",
                     SMG_MESH_SELF="http://127.0.0.1:%d" % port_a,
                     SMG_MESH_PEERS="http://%s:%d" % (LAN, port_b)), name_a, port_a)
start_router_at(dict(MESH_ENV, SMG_MESH_SELF_NAME="lr-mesh2b",
                     SMG_MESH_SELF="http://127.0.0.1:%d" % port_b,
                     SMG_MESH_PEERS="http://%s:%d" % (LAN, port_a)), name_b, port_b)

check("%s both containers come up and pin worker_processes 1" % TAG,
      "workers: 1" in logs(name_a) and "workers: 1" in logs(name_b), logs(name_a)[:300])
st, _, _ = http("GET", "http://%s:%d/ha/status" % (LAN, port_a), timeout=5)
check("%s /ha/* from the lan address requires the control key" % TAG,
      st == 401, str(st))
st, _, _ = http("GET", "http://%s:%d/ha/status" % (LAN, port_a), headers=AUTH,
                timeout=5)
check("%s /ha/* answers with the control key" % TAG, st == 200, str(st))


def converged(port):
    d = ha(port, "/ha/status")
    r = roster(d)
    if d and set(r) == {"lr-mesh2a", "lr-mesh2b"} and d.get("node_count") == 2 \
            and all(s == "alive" for s in r.values()):
        return d
    return None


# --- A. convergence --------------------------------------------------------
ok_a, da = poll(lambda: converged(port_a))
check("%s A converges to exactly two alive members (no phantom :init key)" % TAG,
      ok_a, json.dumps(roster(da)) if da else "timeout")
ok_b, db = poll(lambda: converged(port_b))
check("%s B converges to the same two-node roster" % TAG, ok_b,
      json.dumps(roster(db)) if db else "timeout")
check("%s no hostport-spelling ghost survives in either roster" % TAG,
      not ghost_keys(da, LAN) and not ghost_keys(db, LAN),
      json.dumps([ghost_keys(da, LAN), ghost_keys(db, LAN)]))
b_row = [n for n in (da or {}).get("nodes", []) if n["name"] == "lr-mesh2b"]
check("%s A keeps B's declared loopback address (what used to defeat migration)" % TAG,
      bool(b_row) and b_row[0]["address"] == "http://127.0.0.1:%d" % port_b,
      json.dumps(b_row))
for who, port in (("A", port_a), ("B", port_b)):
    h = ha(port, "/ha/health")
    check("%s %s /ha/health healthy with cluster_size 2" % (TAG, who),
          h and h.get("status") == "healthy" and h.get("cluster_size") == 2
          and h.get("unreachable") == 0 and h.get("should_serve") is True,
          json.dumps(h))

# --- B. worker mirror + data plane -----------------------------------------
st, body, _ = http("POST", "http://127.0.0.1:%d/workers" % port_a,
                   {"url": "http://127.0.0.1:%d" % pa}, AUTH)
wid_a = json.loads(body).get("worker_id") if st in (200, 202) else None
check("%s registering a worker on A accepted" % TAG, bool(wid_a), "%s %s" % (st, body[:150]))
ok, seen = poll(lambda: wid_a in [w.get("worker_id") for w in
                                  (ha(port_b, "/ha/workers") or [])] or None)
check("%s A's worker mirrored into B's /ha/workers" % TAG, ok, str(seen)[:200])
pb = free_port()
start_mock(pb, "beta")
st, body, _ = http("POST", "http://127.0.0.1:%d/workers" % port_b,
                   {"url": "http://127.0.0.1:%d" % pb}, AUTH)
wid_b = json.loads(body).get("worker_id") if st in (200, 202) else None
ok, seen = poll(lambda: wid_b in [w.get("worker_id") for w in
                                  (ha(port_a, "/ha/workers") or [])] or None)
check("%s B's worker mirrored into A's /ha/workers" % TAG, ok, str(seen)[:200])
ok, models = poll(lambda: (lambda r: r if "alpha" in r[1] else None)(
    http("GET", "http://127.0.0.1:%d/v1/models" % port_a)))
check("%s A's /v1/models still serves its own registry (mesh did not eat it)" % TAG,
      bool(ok), str(models)[:200])


def healthy_count(port, want=1):
    """/workers is control-plane auth'd, so _lib.wait_ready cannot be used."""
    st, body, _ = http("GET", "http://127.0.0.1:%d/workers" % port, headers=AUTH,
                       timeout=5)
    if st != 200:
        return False
    try:
        doc = json.loads(body)
    except Exception:
        return False
    return sum(1 for w in doc.get("workers", []) if w.get("is_healthy")) >= want


ok, _ = poll(lambda: True if healthy_count(port_a) else None, timeout=60)
check("%s A's registered worker reaches healthy before the first chat" % TAG, ok,
      logs(name_a)[-300:])
ok, _ = poll(lambda: True if healthy_count(port_b) else None, timeout=60)
check("%s B's registered worker reaches healthy" % TAG, ok, logs(name_b)[-300:])


def chat(port, model, text):
    return http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                {"model": model, "messages": [{"role": "user", "content": text}]},
                timeout=25)


st, body, _ = chat(port_a, "alpha", "mesh2 probe")
check("%s chat through A 200 before the stability window" % TAG, st == 200,
      "%s %s" % (st, body[:150]))

# --- C. long stability -----------------------------------------------------
base = ha(port_a, "/ha/stats")
base_stats = (base or {}).get("stats") or {}
base_rounds, base_failures = base_stats.get("sync_rounds", 0), base_stats.get("sync_failures", 0)
flaps, worst_failures, last_stats = 0, base_failures, base_stats
deadline = time.time() + 18
while time.time() < deadline:
    ra, rb = roster(ha(port_a, "/ha/status")), roster(ha(port_b, "/ha/status"))
    if set(ra) != {"lr-mesh2a", "lr-mesh2b"} or set(rb) != {"lr-mesh2a", "lr-mesh2b"} \
            or any(s != "alive" for s in ra.values()) \
            or any(s != "alive" for s in rb.values()):
        flaps += 1
    last_stats = (ha(port_a, "/ha/stats") or {}).get("stats") or last_stats
    worst_failures = max(worst_failures, last_stats.get("sync_failures", 0))
    time.sleep(1)
rounds_in_window = last_stats.get("sync_rounds", 0) - base_rounds
check("%s 18 s window ran >=10 sync rounds on A" % TAG, rounds_in_window >= 10,
      "rounds in window=%d" % rounds_in_window)
check("%s roster never flapped over the window" % TAG, flaps == 0,
      "flap samples=%d" % flaps)
check("%s no new sync failure during the window" % TAG,
      worst_failures - base_failures == 0,
      "failures %d -> %d" % (base_failures, worst_failures))

# --- D. partition window: stop B -------------------------------------------
subprocess.run(["docker", "stop", "-t", "1", name_b], capture_output=True)
ok, st_a = poll(lambda: (lambda s: s if s and s.get("unreachable_names") else None)(
    ha(port_a, "/ha/stats")), timeout=30)
check("%s survivor lists the stopped peer in unreachable_names" % TAG, ok,
      json.dumps({"names": (st_a or {}).get("unreachable_names"),
                  "unreachable": (st_a or {}).get("unreachable")})[:300])
names = (st_a or {}).get("unreachable_names") or []
check("%s the unreachable member is exactly lr-mesh2b" % TAG, names == ["lr-mesh2b"],
      json.dumps(names))
fails = {f.get("node"): f.get("consecutive_failures")
         for f in ((st_a or {}).get("sync_fail") or [])}
check("%s survivor counts consecutive sync failures against lr-mesh2b" % TAG,
      fails.get("lr-mesh2b", 0) >= 1, json.dumps(fails))
da_p = ha(port_a, "/ha/status")
status_b = roster(da_p).get("lr-mesh2b")
check("%s survivor degrades its view of the dead peer to suspect/down" % TAG,
      status_b in ("suspect", "down"), "%s roster=%s" % (status_b, json.dumps(roster(da_p))))
check("%s roster still holds two entries while partitioned (no key invented)" % TAG,
      set(roster(da_p)) == {"lr-mesh2a", "lr-mesh2b"}, json.dumps(roster(da_p)))
h = ha(port_a, "/ha/health")
check("%s survivor reports unreachable=1 and keeps serving" % TAG,
      h and h.get("unreachable") == 1 and h.get("should_serve") is True,
      json.dumps(h))
st, body, _ = chat(port_a, "alpha", "island probe")
check("%s survivor still answers chat with the peer down" % TAG, st == 200,
      "%s %s" % (st, body[:150]))

# --- E. heal ---------------------------------------------------------------
subprocess.run(["docker", "start", name_b], capture_output=True)
ok, _ = poll(lambda: True if http("GET", "http://127.0.0.1:%d/health" % port_b,
                                  timeout=3)[0] == 200 else None, timeout=40)
check("%s B answers /health again after docker start" % TAG, ok)
ok, da2 = poll(lambda: converged(port_a), timeout=60)
check("%s A reconverges to two alive members after the heal" % TAG, ok,
      json.dumps(roster(da2)) if da2 else "timeout")
ok, st_a2 = poll(lambda: (lambda s: s if s and not s.get("unreachable_names") else None)(
    ha(port_a, "/ha/stats")), timeout=30)
check("%s survivor clears the unreachable peer after the heal" % TAG, ok,
      json.dumps({"names": (st_a2 or {}).get("unreachable_names")})[:200])
h = ha(port_a, "/ha/health")
check("%s survivor back to healthy" % TAG,
      h and h.get("status") == "healthy" and h.get("unreachable") == 0
      and h.get("cluster_size") == 2, json.dumps(h))
ok, _ = poll(lambda: True if healthy_count(port_a) else None, timeout=30)
check("%s A's worker healthy again after the heal" % TAG, ok, logs(name_a)[-300:])
st, body, _ = chat(port_a, "alpha", "post-heal probe")
check("%s chat through A still works after the heal" % TAG, st == 200,
      "%s %s" % (st, body[:150]))

# --- F. graceful retire ----------------------------------------------------
st, body, _ = http("POST", "http://127.0.0.1:%d/ha/shutdown" % port_b, {}, AUTH,
                   timeout=10)
try:
    doc = json.loads(body)
except Exception:
    doc = None
check("%s POST /ha/shutdown on B returns 202 with peers_notified" % TAG,
      st == 202 and doc and doc.get("node") == "lr-mesh2b"
      and isinstance(doc.get("peers_notified"), int) and doc["peers_notified"] >= 1,
      "%s %s" % (st, body[:200]))
ok, da3 = poll(lambda: (lambda d: d if roster(d).get("lr-mesh2b") == "leaving" else None)(
    ha(port_a, "/ha/status")), timeout=15)
check("%s A learns lr-mesh2b leaving within a tick (broadcast, not timeout)" % TAG,
      ok, json.dumps(roster(da3)) if da3 else "timeout")
check("%s retire keeps the roster at two entries and phantom-free" % TAG,
      da3 and da3.get("node_count") == 2 and not ghost_keys(da3, LAN),
      json.dumps(roster(da3)))
check("%s B's own status says draining/leaving after shutdown" % TAG,
      (ha(port_b, "/ha/health") or {}).get("draining") is True
      or roster(ha(port_b, "/ha/status")).get("lr-mesh2b") == "leaving",
      json.dumps(ha(port_b, "/ha/health")))

for who, cname in (("A", name_a), ("B", name_b)):
    lg = logs(cname)
    check("%s no lua errors on %s" % (TAG, who), "lua entry thread aborted" not in lg,
          lg[-400:])

stop_router(name_b)
stop_router(name_a)

failed = [r for r in RESULTS if not r[0]]
print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
for _, n, d in failed:
    print("FAILED: %s | %s" % (n, str(d)[:300]))
cleanup()
sys.exit(1 if failed else 0)
