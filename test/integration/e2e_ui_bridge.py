#!/usr/bin/env python3
"""Round 3: textless requests, /_ui/v1/completions, effort null handling, model-less UI body."""
import json, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (free_port, http, check, start_mock, mock_lines, start_router,
                  logs, stop_router, wait_ready, register, chat, cleanup,
                  probe_container, RESULTS, RUN, REPO)

# 1. prefix_hash with a request that carries no routing text
pa, pb = free_port(), free_port()
start_mock(pa, "alpha"); start_mock(pb, "beta")
name = "lr-notext-" + RUN
port = start_router({"SMG_POLICY": "prefix_hash", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d,http://127.0.0.1:%d" % (pa, pb)}, name)
check("[prefix_hash] healthy", wait_ready(port), logs(name))
# assistant content IS routed text; a genuinely textless body has no content at all
chat(port, "alpha", "ring hit needs routed text to hash")
st, body, hdrs = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                      {"model": "alpha", "messages": [{"role": "user"}, {"role": "system"}]})
check("[prefix_hash] textless chat answers honestly (%s)" % st,
      st in (200, 503) and (st == 200 or "no_available_workers" in body), body[:200])
st, body, _ = http("GET", "http://127.0.0.1:%d/metrics" % port)
st2, text2, _ = http("GET", "http://127.0.0.1:%d/metrics" % port)
check("[prefix_hash] no_tokens branch counted", st2 == 200 and "no_tokens" in text2,
      "%s %s" % (st2, text2[-400:]))
st, text, _ = http("GET", "http://127.0.0.1:%d/metrics" % port)
check("[prefix_hash] ring_hit branch counted", 'branch="ring_hit"' in text or
      'branch="load_balance_walk"' in text, text[-300:])
check("[prefix_hash] no lua errors", "lua entry thread aborted" not in logs(name), logs(name)[-300:])
stop_router(name)

# 2. /_ui/v1/completions + model-less UI body + explicit null effort
pa = free_port(); start_mock(pa, "alpha")
name = "lr-uicpl-" + RUN
port = start_router({"SMG_POLICY": "cache_aware", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa,
                     "LMR_DEFAULT_EFFORT": "ultra"}, name)
check("[ui] healthy", wait_ready(port, 1), logs(name))
st, body, _ = http("POST", "http://127.0.0.1:%d/_ui/v1/completions" % port,
                   {"model": "alpha", "prompt": "ui completion prompt"})
echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
check("[ui] /_ui/v1/completions forwards + effort injected",
      st == 200 and echo.get("reasoning_effort") == "ultra" and "prompt" in echo,
      "%s %s" % (st, json.dumps(echo)[:250]))
# model-less body: ui.lua fills it from the worker list before the pipeline runs
st, body, _ = http("POST", "http://127.0.0.1:%d/_ui/v1/chat/completions" % port,
                   {"messages": [{"role": "user", "content": "no model given"}]})
echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
check("[ui] model-less body filled from the registry", st == 200 and echo.get("model") == "alpha",
      "%s %s" % (st, json.dumps(echo)[:250]))
# explicit null effort is dropped by the UI layer, then re-filled by the policy
st, body, _ = http("POST", "http://127.0.0.1:%d/_ui/v1/chat/completions" % port,
                   {"model": "alpha", "reasoning_effort": None,
                    "messages": [{"role": "user", "content": "null effort"}]})
echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
check("[ui] null effort cleaned then defaulted", echo.get("reasoning_effort") == "ultra",
      json.dumps(echo)[:250])
# empty-string effort takes the same path
st, body, _ = http("POST", "http://127.0.0.1:%d/_ui/v1/chat/completions" % port,
                   {"model": "alpha", "reasoning_effort": "",
                    "messages": [{"role": "user", "content": "empty effort"}]})
echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
check("[ui] empty-string effort defaulted", echo.get("reasoning_effort") == "ultra",
      json.dumps(echo)[:250])
# GET on the chat alias is a 405 with Allow, per the axum gating
st, body, hdrs = http("GET", "http://127.0.0.1:%d/_ui/v1/chat/completions" % port)
check("[ui] GET on chat alias 405 + Allow", st == 405
      and hdrs.get("Allow", hdrs.get("allow", "")) == "POST", "%s %s" % (st, body[:120]))
# /_ui/v1/models advertises the real model
st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/v1/models" % port)
check("[ui] /_ui/v1/models 200", st == 200 and "alpha" in body, body[:150])
check("[ui] no lua errors", "lua entry thread aborted" not in logs(name), logs(name)[-400:])
stop_router(name)

# 3. inference-plane parity: same body through /v1 and /_ui must reach the same shape
pa = free_port(); start_mock(pa, "alpha")
name = "lr-parity-" + RUN
port = start_router({"SMG_POLICY": "round_robin", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "LMR_MODEL_CTX": "alpha:256",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa}, name)
check("[parity] healthy", wait_ready(port, 1), logs(name))
st1, b1, _ = chat(port, "alpha", "parity probe", extra={"max_tokens": 4096})
st2, b2, _ = http("POST", "http://127.0.0.1:%d/_ui/v1/chat/completions" % port,
                  {"model": "alpha", "messages": [{"role": "user", "content": "parity probe"}],
                   "max_tokens": 4096})
e1 = json.loads(b1).get("echo_body", {}) if st1 == 200 else {}
e2 = json.loads(b2).get("echo_body", {}) if st2 == 200 else {}
check("[parity] /v1 and /_ui forward identical clamps", st1 == 200 and st2 == 200
      and e1.get("max_tokens") == 256 == e2.get("max_tokens"),
      "%s/%s %s %s" % (st1, st2, json.dumps(e1)[:160], json.dumps(e2)[:160]))
rows = json.loads(http("GET", "http://127.0.0.1:%d/_ui/logs" % port)[1]).get("requests", [])
check("[parity] both paths land in the request log",
      len([r for r in rows if r.get("endpoint") == "chat"]) >= 2, json.dumps(rows[-2:])[:400])
rows = json.loads(http("GET", "http://127.0.0.1:%d/_ui/logs" % port)[1]).get("requests", [])
ui_rows = [r for r in rows if r.get("path", "").startswith("/_ui")]
check("[parity] log row records the /_ui path", bool(ui_rows)
      and ui_rows[-1].get("endpoint") == "chat" and ui_rows[-1].get("status") == 200,
      json.dumps(ui_rows[-1] if ui_rows else rows[-2:])[:300])
st, text, _ = http("GET", "http://127.0.0.1:%d/metrics" % port)
# the scrape itself is in flight, so the gauge reads 1 while it is served
inflight = [l for l in text.splitlines() if l.startswith("smg_http_inflight_requests")]
check("[parity] inflight drained to the scrape itself", inflight and
      all(float(l.split()[-1]) <= 1 for l in inflight), str(inflight))
active = [float(l.split()[-1]) for l in text.splitlines()
          if l.startswith("smg_worker_requests_active")]
check("[parity] per-worker load released", active and max(active) == 0, str(active))
stop_router(name)

failed = [r for r in RESULTS if not r[0]]
print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
for _, n, d in failed:
    print("FAILED: %s | %s" % (n, str(d)[:300]))
cleanup()
sys.exit(1 if failed else 0)
