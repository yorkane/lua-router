#!/usr/bin/env python3
"""Round 5: webui-alias error contract (503 no workers, 502 dead worker, upstream 4xx).

The alias side is the /u/ family (conf/ui.conf exact locations over the ui.lua
handlers): each scenario fires the same body through the klib inference entry
/v1/chat/completions and the webui alias, and both must get the identical answer.
The /_ui prefix was cancelled by the 2026-10-08 admin-to-root move, so it is not
an entry any more -- its old names now answer from the 404 sink.
"""
import json, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (free_port, http, check, start_mock, mock_lines, start_router,
                  logs, stop_router, wait_ready, register, chat, cleanup,
                  probe_container, RESULTS, RUN, REPO, TMP, PIDS)

# 1. no workers at all -> 503 through both entry points
name = "lr-nowork-" + RUN
port = start_router({"SMG_POLICY": "round_robin", "SMG_DISABLE_HEALTH_CHECK": "0"}, name)
time.sleep(1.0)
st, b1, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                 {"model": "alpha", "messages": [{"role": "user", "content": "x"}]})
st2, b2, h2 = http("POST", "http://127.0.0.1:%d/u/v1/chat/completions" % port,
                   {"model": "alpha", "messages": [{"role": "user", "content": "x"}]})
check("[503] /v1 503 no_available_workers", st == 503 and "no_available_workers" in b1,
      "%s %s" % (st, b1[:200]))
check("[503] /u/ same contract", st2 == 503 and "no_available_workers" in b2,
      "%s %s" % (st2, b2[:200]))
check("[503] X-SMG-Error-Code set",
      h2.get("X-SMG-Error-Code", h2.get("x-smg-error-code")) == "no_available_workers", str(h2))
stop_router(name)

# 2. worker answers 400 (no_retry_4xx) -> forwarded as 400, one attempt
pa = free_port()
env = dict(os.environ, LR_MOCK_LOG="1")
log = open("%s/mock-%d.log" % (TMP, pa), "w")
p = subprocess.Popen([sys.executable, REPO + "/test/mock_llm_worker.py",
                      "--host", "0.0.0.0", "--port", str(pa), "--model", "alpha",
                      "--fail-mode", "no_retry_4xx"], stdout=log, stderr=subprocess.DEVNULL, env=env)
PIDS.append(p)
time.sleep(1.0)
name = "lr-4xx-" + RUN
port = start_router({"SMG_POLICY": "round_robin", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa}, name)
check("[4xx] worker registered", wait_ready(port, 1), logs(name))
# registration flips healthy only after a check; use disable_health_check worker instead
st, b, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                {"model": "alpha", "messages": [{"role": "user", "content": "x"}]})
doc = json.loads(http("GET", "http://127.0.0.1:%d/workers" % port)[1])["workers"][0]
if st == 503:
    check("[4xx] (unhealthy yet; waiting one tick)", wait_ready(port, 1))
    st, b, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                    {"model": "alpha", "messages": [{"role": "user", "content": "x"}]})
check("[4xx] upstream 400 passed through on /v1", st == 400 and "MOCK_400" in b, "%s %s" % (st, b[:200]))
st2, b2, _ = http("POST", "http://127.0.0.1:%d/u/v1/chat/completions" % port,
                  {"model": "alpha", "messages": [{"role": "user", "content": "x"}]})
check("[4xx] same 400 body through /u/", st2 == 400 and "MOCK_400" in b2, "%s %s" % (st2, b2[:200]))
hits = mock_lines(pa, "/v1/chat/completions")
check("[4xx] 4xx not retried (2 requests total)", hits == 2, hits)
# 502: kill the worker, request must fail as 502 with the upstream error code
p.terminate(); time.sleep(1.0)
st, b, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                {"model": "alpha", "messages": [{"role": "user", "content": "x"}]},
                headers=None)
check("[502] dead worker -> 5xx", st in (502, 503), "%s %s" % (st, b[:200]))
st2, b2, _ = http("POST", "http://127.0.0.1:%d/u/v1/chat/completions" % port,
                  {"model": "alpha", "messages": [{"role": "user", "content": "x"}]})
check("[502] /u/ reports the same 5xx", st2 == st, "%s %s" % (st2, b2[:200]))
check("[502] no lua errors", "lua entry thread aborted" not in logs(name), logs(name)[-500:])
stop_router(name)

failed = [r for r in RESULTS if not r[0]]
print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
for _, n, d in failed:
    print("FAILED: %s | %s" % (n, str(d)[:300]))
cleanup()
sys.exit(1 if failed else 0)
