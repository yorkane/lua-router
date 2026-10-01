#!/usr/bin/env python3
"""Round 4: LMR_MODEL_EFFORT forcing and per-model cards keyed on the alias target."""
import json, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (free_port, http, check, start_mock, mock_lines, start_router,
                  logs, stop_router, wait_ready, register, chat, cleanup,
                  probe_container, RESULTS, RUN, REPO)

pa = free_port(); start_mock(pa, "alpha")
name = "lr-meff-" + RUN
port = start_router({"SMG_POLICY": "round_robin", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "LMR_MODEL_EFFORT": "alpha:none",
                     "LMR_DEFAULT_EFFORT": "high",
                     "LMR_VIRTUAL_MODELS": "alias-a:alpha",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa}, name)
check("[model effort] healthy", wait_ready(port, 1), logs(name))
st, body, _ = chat(port, "alpha", "forced effort probe", extra={"reasoning_effort": "ultra"})
echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
check("[model effort] LMR_MODEL_EFFORT overrides the request",
      echo.get("reasoning_effort") == "none", json.dumps(echo)[:200])
# per-model lookups key off the resolved target (Rust rewrites payload.model first)
st, body, _ = chat(port, "alias-a", "alias with forced effort")
echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
check("[model effort] alias inherits the target's forced effort",
      echo.get("reasoning_effort") == "none" and echo.get("model") == "alpha",
      json.dumps(echo)[:200])
check("[model effort] no lua errors", "lua entry thread aborted" not in logs(name),
      logs(name)[-300:])
stop_router(name)

failed = [r for r in RESULTS if not r[0]]
print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
for _, n, d in failed:
    print("FAILED: %s | %s" % (n, str(d)[:300]))
cleanup()
sys.exit(1 if failed else 0)
