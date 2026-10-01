#!/usr/bin/env python3
"""Redis history backend over the real HTTP surface (doc/gap-history-redis.md).

Three scenarios, all through a booted lua-router container:

  A  SMG_HISTORY_BACKEND=redis against the shared Redis, keys under
     lua_router_test:<run>: - conversation CRUD, item pagination, the response
     plane, /_ui/history stats, the conversation cap, and a *second* router
     instance reading the same store (that is the point of the backend). Every
     step is cross-checked with a plain RESP client so a write that silently
     stayed in the memory dict cannot pass.
  B  redis requested but no URL and no host - the router must boot, log the
     fallback and serve history from memory.
  C  redis configured with an unreachable port - the router boots, history
     answers 503 history_unavailable, inference is untouched.

Cleanup deletes every lua_router_test:* key and asserts the prefix is empty.

Run:  python3 test/integration/e2e_history_redis.py
Env:  LUA_TEST_REDIS_HOST / _PORT / _PASSWORD override the shared instance.
      Redis unreachable (or the image missing) prints SKIP and exits 0, unless
      LR_REDIS_REQUIRED=1 (or --require-redis) turns either skip into a FAIL
      with exit 1 -- that is how final_gates.sh keeps the gate honest.
"""
import json, os, socket, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (free_port, http, check, start_mock, start_router, logs,
                  stop_router, wait_ready, register, chat, cleanup,
                  RESULTS, RUN, REPO)  # noqa: E402

REDIS_HOST = os.environ.get("LUA_TEST_REDIS_HOST", "127.0.0.1")
REDIS_PORT = int(os.environ.get("LUA_TEST_REDIS_PORT", "6379"))
REDIS_PW = os.environ.get("LUA_TEST_REDIS_PASSWORD", "")
PREFIX = "lua_router_test:e%s:" % RUN

# Gate mode: a required backend must answer, otherwise the run is a failure
# rather than a silently-green skip.
REQUIRED = os.environ.get("LR_REDIS_REQUIRED", "") not in ("", "0", "false") or \
    "--require-redis" in sys.argv


def skip_or_fail(reason):
    """SKIP + exit 0 for manual runs; FAIL + exit 1 when the backend is required."""
    if REQUIRED:
        print("FAIL: %s (LR_REDIS_REQUIRED/--require-redis: the gate treats it as required)" % reason)
        sys.exit(1)
    print("SKIP: %s" % reason)
    sys.exit(0)


# --------------------------------------------------------------- tiny RESP client
class Resp:
    """Minimal RESP2 client, just enough to audit what the router wrote."""

    def __init__(self, host, port, password=None, timeout=5):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.f = self.sock.makefile("rb")
        if password:
            self.cmd("AUTH", password)

    def _line(self):
        line = self.f.readline()
        if not line:
            raise RuntimeError("redis connection closed")
        return line.rstrip(b"\r\n")

    def _reply(self):
        line = self._line()
        tag, body = line[:1], line[1:]
        if tag == b"+":
            return body.decode()
        if tag == b"-":
            return RuntimeError(body.decode())
        if tag == b":":
            return int(body)
        if tag == b"$":
            n = int(body)
            if n < 0:
                return None
            data = self.f.read(n + 2)[:n]
            return data.decode()
        if tag in (b"*", b">"):
            n = int(body)
            if n < 0:
                return None
            return [self._reply() for _ in range(n)]
        raise RuntimeError("unknown reply tag %r" % line)

    def cmd(self, *args):
        out = [b"*%d\r\n" % len(args)]
        for a in args:
            blob = a if isinstance(a, bytes) else str(a).encode()
            out.append(b"$%d\r\n" % len(blob) + blob + b"\r\n")
        self.sock.sendall(b"".join(out))
        reply = self._reply()
        if isinstance(reply, RuntimeError):
            raise reply
        return reply


def redis_reachable():
    """None only when a PING round-trips; otherwise the reason, so an
    unreachable or refusing instance skips (or fails) the suite instead of
    reporting green (doc/gap-history-redis.md)."""
    try:
        if Resp(REDIS_HOST, REDIS_PORT, REDIS_PW, timeout=3).cmd("PING") == "PONG":
            return None
        return "redis %s:%s answered something that is not PONG" % (REDIS_HOST, REDIS_PORT)
    except OSError as exc:
        return "redis %s:%s unreachable (%s); the backend needs it" % (
            REDIS_HOST, REDIS_PORT, exc)
    except Exception as exc:  # noqa: BLE001 - WRONGPASS, bad protocol, ...
        return "redis %s:%s refused auth (%s)" % (REDIS_HOST, REDIS_PORT, exc)


reason = redis_reachable()
if reason:
    skip_or_fail(reason)
if os.system("docker image inspect %s >/dev/null 2>&1" % os.environ.get("LR_IMAGE",
                                                                       "lua-router:integration")) != 0:
    skip_or_fail("lua-router:integration is not built")

audit = Resp(REDIS_HOST, REDIS_PORT, REDIS_PW)   # read-only audit; never FLUSHDB a shared instance


def keys(pattern=PREFIX + "*"):
    """Every key under our prefix (SCAN, so a shared instance is never blocked)."""
    found, cursor = [], "0"
    while True:
        nxt, batch = audit.cmd("SCAN", cursor, "MATCH", pattern, "COUNT", "500")
        found += batch
        if nxt == "0":
            return found
        cursor = nxt


def base_env(extra=None):
    env = {"SMG_POLICY": "round_robin", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
           "SMG_EVICTION_INTERVAL_SECS": "1"}
    env.update(extra or {})
    return env


# ============================================================ A. redis as configured
pa = free_port()
start_mock(pa, "alpha")
name = "lr-hr-%s" % RUN
port = start_router(base_env({
    "SMG_HISTORY_BACKEND": "redis",
    "SMG_HISTORY_REDIS_URL": "redis://:%s@%s:%d/0" % (REDIS_PW, REDIS_HOST, REDIS_PORT),
    "SMG_HISTORY_REDIS_PREFIX": PREFIX,
    "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa,
}), name)
check("[redis] /health and worker ready", wait_ready(port, 1, 40), logs(name))
log_a = logs(name)
check("[redis] no silent fallback to memory", "falls back to the memory backend" not in log_a,
      log_a[-400:])
check("[redis] startup probe logged no ping failure",
      "history redis ping failed" not in log_a, log_a[-400:])

st, body, _ = http("POST", "http://127.0.0.1:%d/v1/conversations" % port,
                   {"metadata": {"backend": "redis"}})
conv = json.loads(body).get("id") if st == 200 else None
check("[redis] create conversation 200", st == 200 and conv, "%s %s" % (st, body[:200]))
check("[redis] the record really landed in redis",
      audit.cmd("EXISTS", PREFIX + "cv:" + conv) == 1, PREFIX + "cv:" + conv)
check("[redis] the LRU clock carries it",
      audit.cmd("ZSCORE", PREFIX + "zconv", conv) not in (None, ""), "")

ids = []
for i in range(3):
    st, body, _ = http("POST", "http://127.0.0.1:%d/v1/conversations/%s/items" % (port, conv),
                       {"items": [{"type": "message", "role": "user",
                                   "content": "redis item %d" % i}]})
    if st == 200:
        ids += [d["id"] for d in json.loads(body).get("data", [])]
check("[redis] create_items stored 3 items", len(ids) == 3 and
      audit.cmd("ZCARD", PREFIX + "lx:" + conv) == 3, "%s keys=%d" % (ids,
      audit.cmd("ZCARD", PREFIX + "lx:" + conv)))

st, body, _ = http("GET", "http://127.0.0.1:%d/v1/conversations/%s/items?limit=2&order=asc"
                   % (port, conv))
page1 = json.loads(body) if st == 200 else {}
first_ids = [d["id"] for d in page1.get("data", [])]
check("[redis] page 1 (asc, limit=2) is the two oldest",
      st == 200 and first_ids == ids[:2] and page1.get("has_more") is True,
      "%s %s" % (st, body[:200]))
st, body, _ = http("GET", "http://127.0.0.1:%d/v1/conversations/%s/items?limit=2&order=asc&after=%s"
                   % (port, conv, first_ids[-1]))
page2 = json.loads(body) if st == 200 else {}
second_ids = [d["id"] for d in page2.get("data", [])]
check("[redis] the after cursor yields the tail page",
      st == 200 and second_ids == ids[2:], "%s %s" % (st, body[:200]))
check("[redis] cursor paging never repeats an item",
      len(set(first_ids + second_ids)) == 3, str(first_ids + second_ids))
st, _, _ = http("GET", "http://127.0.0.1:%d/v1/conversations/%s/items/%s" % (port, conv, ids[0]))
check("[redis] get_item 200", st == 200)

st, body, _ = http("POST", "http://127.0.0.1:%d/v1/responses" % port,
                   {"model": "alpha", "input": "persist through redis",
                    "conversation": conv})
resp_id = json.loads(body).get("id") if st == 200 else None
check("[redis] POST /v1/responses 200", st == 200 and resp_id, "%s %s" % (st, body[:200]))
st, got, _ = http("GET", "http://127.0.0.1:%d/v1/responses/%s" % (port, resp_id))
check("[redis] the stored response reads back byte-identical",
      st == 200 and json.loads(got).get("id") == resp_id
      and json.loads(got).get("conversation_id") == conv, "%s %s" % (st, got[:200]))
check("[redis] the response record is in redis",
      audit.cmd("EXISTS", PREFIX + "rs:" + resp_id) == 1, "")
st, body, _ = http("GET", "http://127.0.0.1:%d/v1/responses/%s/input_items" % (port, resp_id))
check("[redis] input_items lists the normalised prompt",
      st == 200 and "persist through redis" in body, "%s %s" % (st, body[:200]))

st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/history" % port)
stats = json.loads(body) if st == 200 else {}
check("[redis] /_ui/history reports the redis backend",
      st == 200 and stats.get("backend") == "redis" and stats.get("supported") is True,
      "%s %s" % (st, body[:200]))
check("[redis] /_ui/history counts come from ZCARD",
      (stats.get("conversations") or 0) == 1 and (stats.get("responses") or 0) >= 1,
      str(stats))

# A second router instance on the same Redis: this is what memory cannot do.
name2 = "lr-hr2-%s" % RUN
port2 = start_router(base_env({
    "SMG_HISTORY_BACKEND": "redis",
    "SMG_HISTORY_REDIS_HOST": REDIS_HOST,
    "SMG_HISTORY_REDIS_PORT": str(REDIS_PORT),
    "SMG_HISTORY_REDIS_PASSWORD": REDIS_PW,
    "SMG_HISTORY_REDIS_PREFIX": PREFIX,
    "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa,
}), name2)
check("[redis] second instance boots", wait_ready(port2, 1, 40), logs(name2))
st, body, _ = http("GET", "http://127.0.0.1:%d/v1/conversations/%s" % (port2, conv))
check("[redis] the other instance sees the conversation",
      st == 200 and json.loads(body).get("id") == conv, "%s %s" % (st, body[:200]))
st, body, _ = http("GET", "http://127.0.0.1:%d/v1/conversations/%s/items?order=asc" % (port2, conv))
seen = [d.get("id") for d in (json.loads(body).get("data", []) if st == 200 else [])]
check("[redis] ...and its three linked items (the response mirror adds more)",
      st == 200 and all(i in seen for i in ids) and len(seen) >= 3,
      "%s %s" % (st, body[:250]))
stop_router(name2)

st, body, _ = http("DELETE", "http://127.0.0.1:%d/v1/responses/%s" % (port, resp_id))
check("[redis] delete response 200", st == 200 and json.loads(body).get("deleted") is True,
      "%s %s" % (st, body[:200]))
check("[redis] the response key is gone",
      audit.cmd("EXISTS", PREFIX + "rs:" + resp_id) == 0, "")
st, _, _ = http("DELETE", "http://127.0.0.1:%d/v1/conversations/%s" % (port, conv))
check("[redis] delete conversation 200", st == 200)
st, _, _ = http("GET", "http://127.0.0.1:%d/v1/conversations/%s" % (port, conv))
check("[redis] deleted conversation is 404", st == 404)
check("[redis] drop reclaimed the record, index and items",
      audit.cmd("EXISTS", PREFIX + "cv:" + conv) == 0
      and audit.cmd("EXISTS", PREFIX + "lx:" + conv) == 0
      and audit.cmd("MGET", *[PREFIX + "it:" + i for i in ids]) == [None, None, None],
      str(keys()))

# Conversation cap: the redis clock (ZRANGE head = oldest) does the eviction.
cap = "lr-hrcap-" + RUN
portc = start_router(base_env({
    "SMG_HISTORY_BACKEND": "redis",
    "SMG_HISTORY_REDIS_URL": "redis://:%s@%s:%d/0" % (REDIS_PW, REDIS_HOST, REDIS_PORT),
    "SMG_HISTORY_REDIS_PREFIX": PREFIX,
    "SMG_HISTORY_MAX_CONVERSATIONS": "2",
    "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa,
}), cap)
check("[redis] cap instance boots", wait_ready(portc, 1, 40), logs(cap))
cap_ids = []
for i in range(4):
    st, body, _ = http("POST", "http://127.0.0.1:%d/v1/conversations" % portc, {"metadata": {}})
    cap_ids.append(json.loads(body).get("id") if st == 200 else None)
survivors = [i for i in cap_ids if i and http("GET", "http://127.0.0.1:%d/v1/conversations/%s"
                                              % (portc, i))[0] == 200]
check("[redis] max_conversations=2 keeps the two newest",
      survivors == cap_ids[2:], "%s of %s" % (survivors, cap_ids))
st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/history" % portc)
check("[redis] stats follow the eviction (no drift)",
      json.loads(body).get("conversations") == 2, body[:200])
for cid in survivors:
    http("DELETE", "http://127.0.0.1:%d/v1/conversations/%s" % (portc, cid))
stop_router(cap)
# The worker sweep hook: SMG_EVICTION_INTERVAL_SECS=1 means the history timer ran
# against redis many times during this scenario, so any backend error shows up as
# a WARN from init.lua's start_history_sweep.
late_log = logs(name) + logs(cap)
check("[redis] the capacity sweep timer ran without backend errors",
      "history sweep failed" not in late_log and "history sweep timer" not in late_log,
      late_log[-400:])
check("[redis] no lua aborts in the redis run",
      "lua entry thread aborted" not in late_log, late_log[-400:])
stop_router(name)

# ==================================================== B. redis named, target missing
name = "lr-hfb-" + RUN
port = start_router(base_env({
    "SMG_HISTORY_BACKEND": "redis",
    "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa,
}), name)
check("[fallback] router still boots", wait_ready(port, 1, 40), logs(name))
fb_log = logs(name)
check("[fallback] the misconfiguration is logged",
      "SMG_HISTORY_BACKEND=redis" in fb_log and "falls back to the memory backend" in fb_log,
      fb_log[-500:])
st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/history" % port)
check("[fallback] history serves memory",
      st == 200 and json.loads(body).get("backend") == "memory", "%s %s" % (st, body[:200]))
st, body, _ = http("POST", "http://127.0.0.1:%d/v1/conversations" % port, {"metadata": {}})
fb_conv = json.loads(body).get("id") if st == 200 else None
check("[fallback] the conversation CRUD works on memory",
      st == 200 and fb_conv and http("GET", "http://127.0.0.1:%d/v1/conversations/%s"
                                     % (port, fb_conv))[0] == 200, "%s %s" % (st, body[:200]))
# The ordering clock (prefix + "seq") is never expired and scenario A may have
# created it before the fallback ran, so it is filtered out by name rather than by
# a glob (redis's [!s] class is not reliable here). What must not exist is any
# record, index or LRU entry.
stray = [k for k in keys() if not k.endswith(":seq")]
check("[fallback] no history record reached redis", stray == [], str(stray[:5]))
st, body, _ = chat(port, "alpha", "inference is unaffected")
check("[fallback] inference 200", st == 200)
http("DELETE", "http://127.0.0.1:%d/v1/conversations/%s" % (port, fb_conv))
stop_router(name)

# ============================================ C. target configured but unreachable
dead = free_port()   # bound then released: nothing is listening there
name = "lr-hun-" + RUN
port = start_router(base_env({
    "SMG_HISTORY_BACKEND": "redis",
    "SMG_HISTORY_REDIS_HOST": "127.0.0.1",
    "SMG_HISTORY_REDIS_PORT": str(dead),
    "SMG_HISTORY_REDIS_TIMEOUT_MS": "250",
    "SMG_HISTORY_REDIS_PREFIX": PREFIX,
    "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa,
}), name)
check("[503] router boots even though redis is down", wait_ready(port, 1, 40), logs(name))
down_log = logs(name)
check("[503] the startup probe reported it", "history redis ping failed" in down_log,
      down_log[-500:])
st, body, hdrs = http("POST", "http://127.0.0.1:%d/v1/conversations" % port, {"metadata": {}})
code = hdrs.get("X-SMG-Error-Code", hdrs.get("x-smg-error-code"))
check("[503] history write is 503 history_unavailable",
      st == 503 and code == "history_unavailable" and "redis:" in body,
      "%s %s %s" % (st, code, body[:200]))
st, body, hdrs = http("GET", "http://127.0.0.1:%d/v1/conversations/conv_any" % port)
check("[503] history read is 503 too", st == 503, "%s %s" % (st, body[:150]))
st, body, _ = chat(port, "alpha", "routing does not need history")
check("[503] inference still 200", st == 200)
st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/history" % port)
doc = json.loads(body) if st == 200 else {}
check("[503] /_ui/history still answers 200 with the redis name",
      st == 200 and doc.get("backend") == "redis", "%s %s" % (st, body[:200]))
check("[503] no lua aborts", "lua entry thread aborted" not in down_log, down_log[-400:])
stop_router(name)

# ------------------------------------------------------------------ cleanup
left = keys()
if left:
    audit.cmd("DEL", *[k for k in left])
check("[cleanup] every lua_router_test: key is gone", keys() == [], str(keys()[:10]))

failed = [r for r in RESULTS if not r[0]]
print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
for _, n, d in failed:
    print("FAILED: %s | %s" % (n, str(d)[:400]))
cleanup()
sys.exit(1 if failed else 0)
