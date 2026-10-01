#!/usr/bin/env python3
"""HEAD coverage for the read-only surface router.lua mirrors with app:head.

Why this suite exists: axum's ``get()`` answers HEAD on the same route as GET,
and the live Rust gateway on <rust-box>:8800 confirms it — HEAD returns the GET
status with a zero-length body on /health, /liveness, /readiness, /v1/models,
/model_info, /get_model_info, /server_info, /get_server_info, /engine_metrics,
/metrics(404 there), /workers, /workers/{id}(400), /v1/loads, /get_loads,
/ha/status. router.lua mirrors each ``app:get`` with an explicit
``app:head``, and ui.lua's method gate folds HEAD into GET
(``m == "HEAD" and a == "GET"``). Before this suite the repo's only HEAD check
was ``HEAD /health has no body`` in test_lua_router.sh, so a missing app:head
alias — or an alias that drifted away from its GET twin — would ship green.

Per route:
  * GET answers the expected status (a HEAD pass cannot hide a dead GET);
  * HEAD answers the same status;
  * HEAD carries no body;
  * Content-Type is byte-identical to GET, and Content-Length too for routes
    whose payload is stable between two calls. Routes that embed a clock or a
    counter (uptime, load, metric series) are listed in DYNAMIC below and only
    their Content-Type is compared — their GET body length is not even stable
    against another GET.

Two routes used to be pinned at a divergent value and are now asserted at the
Rust one, which is what section 6 below checks:
  * /_ui/config  — HEAD used to answer 400 because ui.conf's exact location ran
    ``method_any("GET","POST")`` and then hard-picked ``ui.config_effort()`` for
    anything that was not the literal "GET", so HEAD reached the POST handler and
    its empty body was rejected. The branch now reads ``GET or HEAD``, matching
    axum's ``get(handler)``, so HEAD answers 200 with the GET headers.
  * /_ui/history went away with the conversation store (doc/scope-trim.md), so
    section 6 now only pins the /_ui/config HEAD/GET fold.
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (free_port, http, check, start_mock, start_router, wait_ready,
                  logs, stop_router, cleanup, RESULTS, RUN)

# Payloads that embed a clock or a live counter: two GETs of the same route do
# not even agree with each other, so Content-Length cannot be pinned.
DYNAMIC = {"/metrics", "/v1/loads", "/get_loads", "/server_info", "/get_server_info",
           "/_ui/stats", "/_ui/logs"}
# Per-request values that always differ between two requests.
ALWAYS_SKIP = {"date", "x-request-id"}


def norm(headers):
    return {k.lower(): v for k, v in headers.items()}


def head_case(port, path, get_status=200, head_status=None, chunked=False,
              label=None):
    """GET then HEAD on one route; assert status, empty body, header parity."""
    want = path if head_status is None else head_status
    want = head_status if head_status is not None else get_status
    tag = label or path
    g = http("GET", "http://127.0.0.1:%d%s" % (port, path))
    h = http("HEAD", "http://127.0.0.1:%d%s" % (port, path))
    ok = check("[HEAD %s] GET %s" % (tag, get_status), g[0] == get_status,
               "%s %s" % (g[0], g[1][:200]))
    ok = check("[HEAD %s] HEAD %s" % (tag, want), h[0] == want,
               "%s %s" % (h[0], h[1][:200])) and ok
    ok = check("[HEAD %s] HEAD body is empty" % tag, h[1] == "",
               "%d bytes: %r" % (len(h[1]), h[1][:120])) and ok
    # A deliberately divergent status means a different handler answered, so
    # header parity is only meaningful when both verbs took the same path.
    gh, hh = norm(g[2]), norm(h[2])
    if g[0] != h[0]:
        return ok
    skip = set(ALWAYS_SKIP)
    # A chunked answer legitimately loses Transfer-Encoding on HEAD, and nginx
    # answers those HEADs with no Content-Length at all.
    if chunked or path in DYNAMIC:
        skip |= {"transfer-encoding", "content-length"}
    diffs = {k: (gh.get(k), hh.get(k)) for k in set(gh) | set(hh)
             if k not in skip and gh.get(k) != hh.get(k)}
    ok = check("[HEAD %s] headers match GET" % tag, not diffs,
               json.dumps(diffs)[:300]) and ok
    return ok


pa = free_port()
start_mock(pa, "alpha")
name = "lr-head-" + RUN
port = start_router({"SMG_POLICY": "round_robin", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa}, name)
if not check("[HEAD] backing worker healthy", wait_ready(port, 1), logs(name)):
    cleanup()
    sys.exit(1)

# 1. The app:head mirror for the public + control-plane read routes.
for p in ("/health", "/liveness", "/readiness", "/v1/models", "/model_info",
          "/get_model_info", "/server_info", "/get_server_info", "/engine_metrics",
          "/workers", "/v1/loads", "/get_loads"):
    head_case(port, p, chunked=(p in DYNAMIC))
head_case(port, "/metrics", chunked=True)

# 2. Param routes: HEAD must survive the :worker_id capture.
st, body, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
workers = json.loads(body)["workers"]
ids = [w.get("id") or w.get("worker_id") for w in workers]
ids = [i for i in ids if i]
if not check("[HEAD] a worker id is listed", bool(ids), body[:200]):
    cleanup()
    sys.exit(1)
head_case(port, "/workers/%s" % ids[0])
# Unknown id: Rust answers 400 BAD_REQUEST (sampled), as does this router.
head_case(port, "/workers/does-not-exist", get_status=400)

# 3. Mesh surface with the feature off: HEAD rides the same 503 gate.
head_case(port, "/ha/status", get_status=503)

# 4. /_ui aliases from ui.conf (chunked JSON answers).
for p in ("/_ui/v1/models", "/_ui/props", "/_ui/logs", "/_ui/stats", "/_ui/slots",
          "/_ui/tools", "/_ui/logs/backends"):
    head_case(port, p, chunked=True)

# A POST-only /_ui alias must refuse HEAD the same way it refuses GET.
head_case(port, "/_ui/config/effort", get_status=405, chunked=True)

# 5. The route that used to diverge (doc/gap-test-gates.md §3, doc/gap-http-semantics.md):
# /_ui/config is read by ui.conf, whose exact location now folds HEAD into the GET
# branch. The check is the regression gate for that fold. (/_ui/history and the
# /v1/tokenizers trio were pinned here as well until the scope trim removed both
# planes; they now answer from the 404 sink, covered by section 6 below.)
head_case(port, "/_ui/config", get_status=200, chunked=True,
          label="/_ui/config HEAD follows the GET branch")

# 6. The 404 sink answers HEAD without a body. The sink's message embeds the
# request method, so the body length differs by the length of "HEAD" - only
# Content-Type and the error-code header are comparable.
g = http("GET", "http://127.0.0.1:%d/nope" % port)
h = http("HEAD", "http://127.0.0.1:%d/nope" % port)
check("[HEAD /nope] 404 sink answers HEAD with the same shape",
      g[0] == 404 and h[0] == 404 and h[1] == ""
      and norm(g[2]).get("content-type") == norm(h[2]).get("content-type")
      and norm(h[2]).get("x-smg-error-code") == "not_found",
      "%s/%s %r" % (g[0], h[0], h[1][:120]))

# 7. Static SPA root: HEAD on the served bundle.
head_case(port, "/_ui/", chunked=False)

check("[HEAD] no lua errors", "lua entry thread aborted" not in logs(name),
      logs(name)[-500:])

stop_router(name)

failed = [r for r in RESULTS if not r[0]]
print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
for _, n, d in failed:
    print("FAILED: %s | %s" % (n, str(d)[:300]))
cleanup()
sys.exit(1 if failed else 0)
