#!/usr/bin/env python3
"""Round 3: textless requests, the webui completion/chat aliases (/u/*), effort
null handling and the model-less UI body.

The UI-layer behaviours (default-model fill, empty/null effort clean-up, the
405 + Allow method gate, the picker list with status.value) live in ui.lua and
are reached through conf/ui.conf, i.e. the /u/ family and the root-attached
names. The /_ui prefix went away with the 2026-10-08 admin-to-root move; the
root /v1/* names belong to the klib inference plane and answer differently.
"""
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

# 2. /u/v1/completions + model-less UI body + explicit null effort
pa = free_port(); start_mock(pa, "alpha")
name = "lr-uicpl-" + RUN
port = start_router({"SMG_POLICY": "cache_aware", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa,
                     "LMR_DEFAULT_EFFORT": "ultra"}, name)
check("[ui] healthy", wait_ready(port, 1), logs(name))
st, body, _ = http("POST", "http://127.0.0.1:%d/u/v1/completions" % port,
                   {"model": "alpha", "prompt": "ui completion prompt"})
echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
check("[ui] /u/v1/completions forwards + effort injected",
      st == 200 and echo.get("reasoning_effort") == "ultra" and "prompt" in echo,
      "%s %s" % (st, json.dumps(echo)[:250]))
# model-less body: ui.lua fills it from the worker list before the pipeline runs
st, body, _ = http("POST", "http://127.0.0.1:%d/u/v1/chat/completions" % port,
                   {"messages": [{"role": "user", "content": "no model given"}]})
echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
check("[ui] model-less body filled from the registry", st == 200 and echo.get("model") == "alpha",
      "%s %s" % (st, json.dumps(echo)[:250]))
# explicit null effort is dropped by the UI layer, then re-filled by the policy
st, body, _ = http("POST", "http://127.0.0.1:%d/u/v1/chat/completions" % port,
                   {"model": "alpha", "reasoning_effort": None,
                    "messages": [{"role": "user", "content": "null effort"}]})
echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
check("[ui] null effort cleaned then defaulted", echo.get("reasoning_effort") == "ultra",
      json.dumps(echo)[:250])
# empty-string effort takes the same path
st, body, _ = http("POST", "http://127.0.0.1:%d/u/v1/chat/completions" % port,
                   {"model": "alpha", "reasoning_effort": "",
                    "messages": [{"role": "user", "content": "empty effort"}]})
echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
check("[ui] empty-string effort defaulted", echo.get("reasoning_effort") == "ultra",
      json.dumps(echo)[:250])
# GET on the chat alias is a 405 with Allow, per the axum gating
st, body, hdrs = http("GET", "http://127.0.0.1:%d/u/v1/chat/completions" % port)
check("[ui] GET on chat alias 405 + Allow", st == 405
      and hdrs.get("Allow", hdrs.get("allow", "")) == "POST", "%s %s" % (st, body[:120]))
# The webui picker advertises the real model
st, body, _ = http("GET", "http://127.0.0.1:%d/u/v1/models" % port)
check("[ui] /u/v1/models 200", st == 200 and "alpha" in body, body[:150])
check("[ui] no lua errors", "lua entry thread aborted" not in logs(name), logs(name)[-400:])
stop_router(name)

# 3. inference-plane parity: the same body through /v1 and /u/ reaches one shape
pa = free_port(); start_mock(pa, "alpha")
name = "lr-parity-" + RUN
port = start_router({"SMG_POLICY": "round_robin", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "LMR_MODEL_CTX": "alpha:256",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa}, name)
check("[parity] healthy", wait_ready(port, 1), logs(name))
st1, b1, _ = chat(port, "alpha", "parity probe", extra={"max_tokens": 4096})
st2, b2, _ = http("POST", "http://127.0.0.1:%d/u/v1/chat/completions" % port,
                  {"model": "alpha", "messages": [{"role": "user", "content": "parity probe"}],
                   "stream": False, "max_tokens": 4096})
e1 = json.loads(b1).get("echo_body", {}) if st1 == 200 else {}
e2 = json.loads(b2).get("echo_body", {}) if st2 == 200 else {}
# Ruling 2026-10-04 (commit 75ecc37): the gateway forwards the caller's output budget
# verbatim, so both entries must hand the mock the 4096 that was sent -- not the 256
# that LMR_MODEL_CTX=alpha:256 used to clamp it to. The env row stays configured on
# purpose: it is the number a re-introduced clamp would read, which is what makes the
# 4096 assertion discriminate instead of passing vacuously.
check("[parity] /v1 and /u/ forward the caller's max_tokens untouched",
      st1 == 200 and st2 == 200 and e1.get("max_tokens") == 4096
      and e2.get("max_tokens") == 4096,
      "%s/%s %s %s" % (st1, st2, json.dumps(e1)[:160], json.dumps(e2)[:160]))
# Stronger than "both landed on the same number": the two forwarded bodies must be
# IDENTICAL. Two clamps that agree say nothing about the gateway staying out of the
# body; byte equality says the whole pipeline (model rewrite, effort ladder, usage
# injection) made the same -- or more precisely, no -- difference.
#
# Fields deliberately excluded from the comparison: none. echo_body is the request
# body as the mock received it, so it carries no id/created_at/request-id of its own
# (those live in the response envelope, not in echo_body), and both requests name the
# same single worker, so the model rewrite lands on the same "alpha". stream rides
# explicitly on the /u/ body because chat() always sends it -- that is the one shape
# difference the two entry points would otherwise show for reasons unrelated to the
# gateway. Nothing else may differ, and if a future gateway starts stamping a
# per-request field into the body, this check is where it gets caught.
check("[parity] both entries hand the worker the same bytes",
      st1 == 200 and st2 == 200 and e1 == e2 and bool(e1),
      "e1=%s e2=%s" % (json.dumps(e1)[:220], json.dumps(e2)[:220]))
rows = json.loads(http("GET", "http://127.0.0.1:%d/logs" % port)[1]).get("requests", [])
check("[parity] both paths land in the request log",
      len([r for r in rows if r.get("endpoint") == "chat"]) >= 2, json.dumps(rows[-2:])[:400])
rows = json.loads(http("GET", "http://127.0.0.1:%d/logs" % port)[1]).get("requests", [])
ui_rows = [r for r in rows if r.get("path", "").startswith("/u/")]
check("[parity] log row records the /u/ path", bool(ui_rows)
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

# 4. /u/ static bundle MIME types: browsers hard-fail ES module scripts served
#    as application/octet-stream (strict MIME checking per HTML spec). The http{}
#    block must include mime.types and add webmanifest/mjs mappings.
import re as _re
name = "lr-uimime-" + RUN
port = start_router({"SMG_POLICY": "cache_aware"}, name)
_mime_up = False
for _ in range(60):
    if http("GET", "http://127.0.0.1:%d/health" % port)[0] == 200:
        _mime_up = True
        break
    time.sleep(0.5)
check("[ui-mime] healthy", _mime_up, logs(name))
st, html, hdrs = http("GET", "http://127.0.0.1:%d/u/" % port)
check("[ui-mime] index is text/html (%s)" % st, st == 200 and
      hdrs.get("Content-Type", "").startswith("text/html"), hdrs.get("Content-Type", "?"))
js = _re.search(r'(?:src|href)="(?:\./|/u/)(_app/[^"]+\.js)"', html)
css = _re.search(r'(?:src|href)="(?:\./|/u/)(_app/[^"]+\.css)"', html)
if js:
    st, _, hdrs = http("GET", "http://127.0.0.1:%d/u/%s" % (port, js.group(1)))
    check("[ui-mime] module js served as javascript (%s)" % hdrs.get("Content-Type", "?"),
          st == 200 and hdrs.get("Content-Type", "") in
          ("application/javascript", "text/javascript"),
          "%s %s" % (st, hdrs.get("Content-Type", "?")))
else:
    check("[ui-mime] index references an _app js bundle", False, html[-200:])
if css:
    st, _, hdrs = http("GET", "http://127.0.0.1:%d/u/%s" % (port, css.group(1)))
    check("[ui-mime] css served as text/css", st == 200 and
          hdrs.get("Content-Type", "").startswith("text/css"),
          "%s %s" % (st, hdrs.get("Content-Type", "?")))
st, _, hdrs = http("GET", "http://127.0.0.1:%d/u/manifest.webmanifest" % port)
check("[ui-mime] webmanifest served as application/manifest+json",
      st == 200 and hdrs.get("Content-Type", "").startswith("application/manifest+json"),
      "%s %s" % (st, hdrs.get("Content-Type", "?")))
check("[ui-mime] no lua errors", "lua entry thread aborted" not in logs(name), logs(name)[-300:])
stop_router(name)

failed = [r for r in RESULTS if not r[0]]
print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
for _, n, d in failed:
    print("FAILED: %s | %s" % (n, str(d)[:300]))
cleanup()
sys.exit(1 if failed else 0)
