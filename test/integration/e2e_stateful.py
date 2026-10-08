#!/usr/bin/env python3
"""Round 2: snapshot write-back + reload restore, bucket/prefix_hash traffic,
empty-array preservation through the raw edits, manual regression, the pure
/v1/responses pass-through contract, and the SMG_DP_AWARE expansion checks that
were migrated out of e2e_discovery_dp.py when the Kubernetes poller was removed
(doc/scope-trim.md)."""
import json, os, socket, struct, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (free_port, http, check, start_mock, mock_lines, start_router,
                  logs, stop_router, wait_ready, register, chat, cleanup,
                  probe_container, RESULTS, RUN, REPO)

# ---------- 1. bucket / prefix_hash with real traffic ----------
for policy in ("bucket", "prefix_hash"):
    pa, pb = free_port(), free_port()
    start_mock(pa, "alpha")
    start_mock(pb, "beta")
    name = "lr-%s-%s" % (policy[:10], RUN)
    port = start_router({"SMG_POLICY": policy, "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                         "SMG_EVICTION_INTERVAL_SECS": "1",
                         "SMG_WORKER_URLS": "http://127.0.0.1:%d,http://127.0.0.1:%d" % (pa, pb)}, name)
    if not check("[%s] workers healthy" % policy, wait_ready(port), logs(name)):
        stop_router(name)
        continue
    ok = True
    for i in range(6):
        st, body, _ = chat(port, "alpha", "traffic probe %d for the %s policy" % (i, policy))
        ok = ok and st == 200
    check("[%s] 6 chats all 200" % policy, ok)
    st, body, _ = chat(port, "alpha", "streaming through %s" % policy, stream=True)
    check("[%s] stream 200 + [DONE]" % policy, st == 200 and "data: [DONE]" in body)
    # bucket spreads load, prefix_hash sticks on a shared prefix
    base = {p: mock_lines(p, "/v1/chat/completions") for p in (pa, pb)}
    # prefix_hash hashes the whole first prefix_token_count characters, so the
    # affinity probe repeats an identical body; the other policies are seeded
    # with the same shared-prefix text.
    body_text = ("shared prefix that both policies should notice " * 4)[:200]
    for i in range(8):
        chat(port, "alpha", body_text)
    hits = {p: mock_lines(p, "/v1/chat/completions") - base[p] for p in (pa, pb)}
    spread = min(hits.values())
    check("[%s] 8 requests routed (%s)" % (policy, hits), sum(hits.values()) == 8, str(hits))
    if policy == "prefix_hash":
        check("[prefix_hash] identical prefix sticks to one worker", spread == 0, str(hits))
    stop_router(name)

# ---------- 2. manual sticky regression + empty-array preservation ----------
pa, pb = free_port(), free_port()
start_mock(pa, "alpha")
start_mock(pb, "beta")
name = "lr-manual-" + RUN
port = start_router({"SMG_POLICY": "manual", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "SMG_EVICTION_INTERVAL_SECS": "1",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d,http://127.0.0.1:%d" % (pa, pb)}, name)
check("[manual] healthy", wait_ready(port), logs(name))
who = {}
for key in ("alice", "bob", "carol"):
    base = {p: mock_lines(p, "/v1/chat/completions") for p in (pa, pb)}
    for i in range(3):
        chat(port, "alpha", "manual probe %s" % key, headers={"x-smg-routing-key": key})
    hits = {p: mock_lines(p, "/v1/chat/completions") - base[p] for p in (pa, pb)}
    who[key] = hits
check("[manual] routing-key stickiness intact",
      all(max(v.values()) == 3 for v in who.values()), json.dumps(who))
# empty arrays survive the raw JSON edits (the reason the payload is not re-encoded)
st, body, _ = chat(port, "alpha", "array preservation probe",
                   extra={"tools": [], "stop": [], "n": 1, "temperature": 0.5})
echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
check("[payload] empty arrays stay arrays through the raw edits",
      echo.get("tools") == [] and echo.get("stop") == [], json.dumps(echo)[:300])
check("[payload] untouched numbers survive", echo.get("n") == 1 and echo.get("temperature") == 0.5,
      json.dumps(echo)[:200])
time.sleep(2.0)
st, text, _ = http("GET", "http://127.0.0.1:%d/metrics" % port)
check("[manual] branch counter + cache gauge published", st == 200
      and "smg_manual_policy_branch_total" in text
      and "smg_manual_policy_cache_entries" in text, "%s %s" % (st, text[-300:]))
check("[manual] no lua errors", "lua entry thread aborted" not in logs(name), logs(name)[-400:])
stop_router(name)

# ---------- 2b. manual failover + failback (Rust parity) ----------
# Rust keeps up to 2 candidate URLs per routing key, appended through
# Node::push_bounded, and is NEVER told when a worker leaves (only cache_aware
# gets a removal notification). So a key remembers its departed worker and
# returns to it once that worker is back. lua-router used to store the failover
# target first and scrub the removed URL out of the map, which pinned every
# session to its failover worker forever.
pa, pb, pc = free_port(), free_port(), free_port()
for p, m in ((pa, "alpha"), (pb, "alpha"), (pc, "alpha")):
    start_mock(p, m)
name = "lr-manual-fb-" + RUN
port = start_router({"SMG_POLICY": "manual", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d,http://127.0.0.1:%d,"
                                        "http://127.0.0.1:%d" % (pa, pb, pc)}, name)
check("[manual failback] healthy", wait_ready(port, want=3), logs(name))

def key_worker(port, key, pool):
    """Which mock the routing key lands on, from per-mock hit deltas.
    Same observation channel the [manual] stickiness check above uses, so it
    does not depend on the request-log ordering."""
    base = {p: mock_lines(p, "/v1/chat/completions") for p in pool}
    for _ in range(3):
        st, _, _ = chat(port, "alpha", "failback probe",
                        headers={"x-smg-routing-key": key})
        if st != 200:
            return None
    hits = {p: mock_lines(p, "/v1/chat/completions") - base[p] for p in pool}
    got = [p for p, n in hits.items() if n > 0]
    # a key must not be spread across workers within one session
    if len(got) != 1 or hits[got[0]] != 3:
        return None
    return got[0]

POOL3 = (pa, pb, pc)
keys = ["fb-%d" % i for i in range(6)]
home = {k: key_worker(port, k, POOL3) for k in keys}
check("[manual failback] keys sticky before churn",
      all(home[k] for k in keys) and len({home[k] for k in keys}) >= 2,
      json.dumps(home))

victim = sorted({home[k] for k in keys})[0]
on_victim = [k for k in keys if home[k] == victim]
wid = [w["id"] for w in json.loads(http("GET", "http://127.0.0.1:%d/workers" % port)[1])["workers"]
       if w["url"].endswith(str(victim))][0]
http("DELETE", "http://127.0.0.1:%d/workers/%s" % (port, wid))
time.sleep(2.0)

alive = tuple(p for p in POOL3 if p != victim)
after = {k: key_worker(port, k, alive) for k in keys}
check("[manual failback] every key resolved and victim keys moved off it",
      all(after[k] for k in keys) and all(after[k] != victim for k in on_victim),
      json.dumps({k: (home[k], after[k]) for k in on_victim}))
bystanders = [k for k in keys if home[k] != victim]
check("[manual failback] only the victim's keys moved",
      all(after[k] == home[k] for k in bystanders),
      json.dumps({k: (home[k], after[k]) for k in bystanders
                  if after[k] != home[k]}))

http("POST", "http://127.0.0.1:%d/workers" % port,
     {"url": "http://127.0.0.1:%d" % victim, "model_id": "alpha"})
check("[manual failback] worker back and healthy", wait_ready(port, want=3), logs(name))
time.sleep(1.0)
back = {k: key_worker(port, k, POOL3) for k in keys}
check("[manual failback] failed-over keys return to their original worker",
      all(back[k] == victim for k in on_victim) and all(back[k] for k in keys),
      "expected %s got %s" % (victim, json.dumps({k: back[k] for k in on_victim})))
check("[manual failback] bystanders never moved",
      all(back[k] == home[k] for k in bystanders),
      json.dumps({k: (home[k], back[k]) for k in bystanders
                  if back[k] != home[k]}))
check("[manual failback] no lua errors", "lua entry thread aborted" not in logs(name),
      logs(name)[-500:])
stop_router(name)

# ---------- 3. cache_aware snapshot: write-back, reload restore, max_bytes skip ----------
pa, pb = free_port(), free_port()
start_mock(pa, "alpha")
start_mock(pb, "beta")
name = "lr-snap-" + RUN
port = start_router({"SMG_POLICY": "cache_aware", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "SMG_EVICTION_INTERVAL_SECS": "1",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d,http://127.0.0.1:%d" % (pa, pb)}, name)
check("[snapshot] healthy", wait_ready(port), logs(name))
for i in range(5):
    chat(port, "alpha", "snapshot prefix alpha-one-two " + "content %d" % i)
st, body, _ = chat(port, "alpha", "warm")
time.sleep(2.5)   # one eviction tick: the sweep must have written the snapshot
st, text, _ = http("GET", "http://127.0.0.1:%d/metrics" % port)
check("[snapshot] cache_aware tenant gauge published", st == 200
      and "smg_cache_aware_tenant_count" in text, "%s %s" % (st, text[-300:]))
check("[snapshot] selection metric carries the policy name",
      'policy="cache_aware"' in text, text[-200:])
# reload the nginx master: the shared dict survives, the trees do not, so the
# restored tree proves the write-back + init_worker read path.
subprocess.run(["docker", "exec", name, "sh", "-c",
                "kill -USR1 $(cat /usr/local/openresty/nginx/logs/nginx.pid) 2>/dev/null || "
                "kill -HUP 1"], capture_output=True)
time.sleep(4)
st, _, _ = http("GET", "http://127.0.0.1:%d/health" % port)
check("[snapshot] router alive after reload", st == 200, st)
st, body, _ = chat(port, "alpha", "snapshot prefix alpha-one-two content 0")
check("[snapshot] post-reload request 200", st == 200, body[:200])
base = {p: mock_lines(p, "/v1/chat/completions") for p in (pa, pb)}
for i in range(6):
    chat(port, "alpha", "snapshot prefix alpha-one-two " + "content %d" % i)
hits = {p: mock_lines(p, "/v1/chat/completions") - base[p] for p in (pa, pb)}
check("[snapshot] affinity survives reload (%s)" % hits, max(hits.values()) == 6, str(hits))
check("[snapshot] no lua errors", "lua entry thread aborted" not in logs(name), logs(name)[-500:])
# max_bytes guard: a snapshot over the budget must be skipped, not crash
stop_router(name)
name = "lr-snapmax-" + RUN
port = start_router({"SMG_POLICY": "cache_aware", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "SMG_EVICTION_INTERVAL_SECS": "1", "LR_SNAPSHOT_MAX_BYTES": "64",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa}, name)
check("[snapshot max_bytes] healthy", wait_ready(port, 1), logs(name))
for i in range(3):
    chat(port, "alpha", "oversized snapshot payload " + "x" * 400)
time.sleep(2.5)
txt = logs(name)
check("[snapshot max_bytes] oversized dumps skipped without errors",
      "lua entry thread aborted" not in txt and "snapshot write failed" not in txt, txt[-400:])
stop_router(name)

# ---------- 4. cache_aware on 2 processes: no key collision, no errors ----------
pa = free_port()
start_mock(pa, "alpha")
name = "lr-multi-" + RUN
port = start_router({"SMG_POLICY": "cache_aware", "NGINX_WORKER_PROCESSES": "2",
                     "SMG_HEALTH_CHECK_INTERVAL_SECS": "1", "SMG_EVICTION_INTERVAL_SECS": "1",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa}, name)
check("[multi-process] healthy", wait_ready(port, 1), logs(name))
for i in range(12):
    chat(port, "alpha", "multi process probe %d" % i)
time.sleep(2.5)
txt = logs(name)
check("[multi-process] no lua errors with 2 workers",
      "lua entry thread aborted" not in txt and "[error]" not in txt, txt[-600:])
st, body, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
check("[multi-process] load counters balanced", st == 200
      and json.loads(body)["workers"][0]["load"] == 0, body[:300])
stop_router(name)

# ---------- 4b. worker add/delete mid-flight re-seeds the policy ----------
pa, pb = free_port(), free_port()
start_mock(pa, "alpha")
name = "lr-addw-" + RUN
port = start_router({"SMG_POLICY": "cache_aware", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa}, name)
check("[add worker] healthy", wait_ready(port, 1), logs(name))
for i in range(3):
    chat(port, "alpha", "before the second worker existed %d" % i)
start_mock(pb, "beta")   # comes up after the router, discovered only via POST /workers
st, body = register(port, "http://127.0.0.1:%d" % pb)
check("[add worker] POST /workers 202", st == 202, "%s %s" % (st, body[:200]))
check("[add worker] second worker becomes healthy", wait_ready(port, 2), logs(name))
base = {p: mock_lines(p, "/v1/chat/completions") for p in (pa, pb)}
for i in range(8):
    chat(port, "alpha", "after registration prefix shared %d tail" % i)
hits = {p: mock_lines(p, "/v1/chat/completions") - base[p] for p in (pa, pb)}
check("[add worker] the new worker is reachable (%s)" % hits, sum(hits.values()) == 8, str(hits))
check("[add worker] no lua errors", "lua entry thread aborted" not in logs(name), logs(name)[-400:])
# and delete it again
wid = [w["id"] for w in json.loads(http("GET", "http://127.0.0.1:%d/workers" % port)[1])["workers"]
       if w["url"].endswith(str(pb))][0]
st, body, _ = http("DELETE", "http://127.0.0.1:%d/workers/%s" % (port, wid))
check("[add worker] DELETE 202", st == 202, "%s %s" % (st, body[:200]))
ok = True
for i in range(4):
    st, _, _ = chat(port, "alpha", "after the worker left %d" % i)
    ok = ok and st == 200
check("[add worker] traffic still 200 after delete", ok)
check("[add worker] still no lua errors", "lua entry thread aborted" not in logs(name),
      logs(name)[-500:])
stop_router(name)

# ---------- 5. /v1/responses C2 patch + pure pass-through ----------
# A dedicated stdlib worker so the SSE shapes (event: lines, output_index, CRLF)
# are under test control, not the shared mock's.
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RESP_MODEL = "alpha"
RESP_DELAY = 0.12


def resp_doc(rid, status="completed", model=None):
    doc = {
        "id": rid, "object": "response", "created_at": 1790000000,
        "status": status,
        "output": [{"type": "message", "id": "msg_" + rid, "role": "assistant",
                    "content": [{"type": "output_text", "text": "ok",
                                 "annotations": []}]}],
        "output_text": "ok",
        "tools": [], "instructions": None, "metadata": None,
        "previous_response_id": None, "safety_identifier": None,
    }
    if model is not None:
        doc["model"] = model
    return doc


class RespHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _json(self, status, value):
        raw = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/health":
            self._json(200, {"status": "ok"})
        elif path == "/v1/models":
            self._json(200, {"object": "list", "data": [
                {"id": RESP_MODEL, "object": "model", "owned_by": "local"}]})
        else:
            self._json(404, {"error": "not found"})

    def _chunk(self, text):
        raw = text.encode()
        self.wfile.write(b"%x\r\n" % len(raw))
        self.wfile.write(raw)
        self.wfile.write(b"\r\n")
        self.wfile.flush()

    def _event(self, name, value):
        # CRLF framing on purpose: the accumulator must normalize it.
        self._chunk("event: %s\r\ndata: %s\r\n\r\n" % (name, json.dumps(value)))
        time.sleep(RESP_DELAY)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            body = {}
        if self.path.split("?", 1)[0] != "/v1/responses":
            self._json(404, {"error": "not found"})
            return
        rid = (body.get("metadata") or {}).get("rid", "resp_unknown")
        if body.get("stream") is not True:
            # model absent entirely: exercises the model default branch too
            doc = resp_doc(rid)
            doc.pop("model", None)
            if (body.get("metadata") or {}).get("echo") is True:
                # Opt-in echo for the output-budget probes (5.7): the Responses answer
                # has no room for the request, and those probes must observe the bytes
                # the GATEWAY sent, not the bytes the client meant to send. Gated on a
                # marker so every pre-existing case here keeps the exact shape it had.
                doc["echo_body"] = body
            self._json(200, doc)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            self._event("response.created", {
                "type": "response.created",
                "response": resp_doc(rid, "in_progress")})
            item = resp_doc(rid)["output"][0]
            self._event("response.output_item.done", {
                "type": "response.output_item.done", "output_index": 0,
                "item": item})
            self._event("response.completed", {
                "type": "response.completed",
                "response": resp_doc(rid)})
            self._chunk("data: [DONE]\r\n\r\n")
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


resp_server = ThreadingHTTPServer(("127.0.0.1", 0), RespHandler)
resp_server.daemon_threads = True
threading.Thread(target=resp_server.serve_forever, daemon=True).start()
resp_up = resp_server.server_address[1]
name = "lr-resp-" + RUN
port = start_router({"SMG_POLICY": "round_robin",
                     "SMG_HEALTH_CHECK_INTERVAL_SECS": "1"}, name)
st, body = register(port, "http://127.0.0.1:%d" % resp_up)
check("[responses] worker registered", st == 202, "%s %s" % (st, str(body)[:120]))
check("[responses] worker healthy", wait_ready(port, 1), logs(name))


def resp_post(port, doc):
    return http("POST", "http://127.0.0.1:%d/v1/responses" % port, doc)


def stream_doc(rid, **extra):
    doc = {"model": RESP_MODEL, "input": "stream probe", "stream": True,
           "metadata": {"rid": rid}}
    doc.update(extra)
    return doc


# 5.1 C2: request metadata lands on the client body AND the stored copy
st, body, _ = resp_post(port, {
    "model": RESP_MODEL, "input": "patch probe", "store": False,
    "previous_response_id": "prev-7", "instructions": "be terse",
    "metadata": {"rid": "resp_c2", "tag": "x"}, "user": "u-9",
    "conversation": "conv-c2", "tools": []})
doc = json.loads(body) if st == 200 else {}
check("[responses C2] non-stream patch on the outbound bytes",
      st == 200 and doc.get("previous_response_id") == "prev-7"
      and doc.get("instructions") == "be terse"
      and doc.get("metadata", {}).get("tag") == "x"
      and doc.get("store") is False
      and doc.get("safety_identifier") == "u-9",
      "%s %s" % (st, body[:300]))
# The conversation link only ever meant "this stored response belongs to that
# conversation"; with the store removed (doc/scope-trim.md) the router no longer
# writes it back.
check("[responses C2] the conversation link is not echoed",
      "conversation" not in doc, json.dumps(doc)[:300])
check("[responses C2] empty model falls back to the request model",
      doc.get("model") == RESP_MODEL, body[:200])
check("[responses C2] empty arrays stay arrays through the patch",
      doc.get("tools") == [], json.dumps(doc.get("tools")))
st, _, _ = http("GET", "http://127.0.0.1:%d/v1/responses/resp_c2" % port)
check("[responses C2] nothing is stored: the family answers from the 404 sink",
      st == 404, st)

# 5.2 C4: store=true stream is retrievable once it completes
st, raw, hdrs = resp_post(port, stream_doc("resp_s1", store=True))
ctypes = [v for k, v in hdrs.items() if k.lower() == "content-type"]
check("[responses C4] store=true stream passed through",
      st == 200 and any("text/event-stream" in v for v in ctypes)
      and raw.count("event: response.completed") == 1, "%s %r" % (st, raw[-120:]))
st, _, _ = http("GET", "http://127.0.0.1:%d/v1/responses/resp_s1" % port)
check("[responses C4] store=true persists nothing", st == 404, st)

# 5.3 the zero-change pass-through, including chunk-by-chunk arrival timing (the
# pump must not buffer). With the store gone this is the rule for EVERY stream,
# whatever the client asked for.
sock = socket.create_connection(("127.0.0.1", port), timeout=10)
payload = json.dumps(stream_doc("resp_s3", store=False)).encode()
sock.sendall(("POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
              "Content-Type: application/json\r\nContent-Length: %d\r\n\r\n"
              % len(payload)).encode() + payload)
start = time.time()
arrivals = []
deadline = time.time() + 8
buf = b""
while time.time() < deadline:
    try:
        piece = sock.recv(4096)
    except OSError:
        break
    if not piece:
        break
    buf += piece
    if not arrivals:
        arrivals.append(time.time())      # first byte after the request
    if b"response.completed" in buf and len(arrivals) < 2:
        arrivals.append(time.time())      # the last event's chunk
    if b"data: [DONE]" in buf:
        break
sock.close()
text = buf.decode("utf-8", "replace")
check("[responses C4] no-store stream still completes",
      text.count("event: response.created") == 1
      and "event: response.completed" in text and "data: [DONE]" in text,
      text[-200:])
# The upstream sleeps RESPONSES (0.12s) between events, so a pass-through pump
# needs ~2*RESP_DELAY to deliver the whole body; a buffering pump would show no
# gap between the first byte and the completed event.
elapsed = (arrivals[1] - arrivals[0]) if len(arrivals) == 2 else -1
check("[responses C4] SSE chunks still arrive incrementally", elapsed >= 0.20,
      "first-to-completed=%.3f (expect >=%.2f)" % (elapsed, 2 * RESP_DELAY))
st, _, _ = http("GET", "http://127.0.0.1:%d/v1/responses/resp_s3" % port)
check("[responses C4] store=false is not persisted", st == 404, st)

# 5.4 a client that hangs up mid-stream tears the pump down. The persistence
# branch used to keep draining the upstream after a disconnect so the stored row
# would be complete; with the store gone there is nothing to complete, so the
# upstream read stops with the client and nothing is left behind either.
sock = socket.create_connection(("127.0.0.1", port), timeout=5)
payload = json.dumps(stream_doc("resp_abort", store=True)).encode()
sock.sendall(("POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
              "Content-Type: application/json\r\nContent-Length: %d\r\n\r\n"
              % len(payload)).encode() + payload)
sock.recv(1024)          # headers + the first event, then hang up
# Zero-timeout linger turns close() into RST so the router sees a gone client
# rather than a peer it can keep writing to.
sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
sock.close()
time.sleep(1.5)          # past the upstream's remaining event delays
st, _, _ = http("GET", "http://127.0.0.1:%d/v1/responses/resp_abort" % port)
check("[responses C4] a disconnected stream persists nothing", st == 404, st)

# 5.5 the plain non-persisted branch: the pump tears down the moment the client
# goes away (streaming.rs:661-722 cancels the upstream request the same way).
sock = socket.create_connection(("127.0.0.1", port), timeout=5)
payload = json.dumps(stream_doc("resp_abort_nostore")).encode()
sock.sendall(("POST /v1/responses HTTP/1.1\r\nHost: x\r\n"
              "Content-Type: application/json\r\nContent-Length: %d\r\n\r\n"
              % len(payload)).encode() + payload)
sock.recv(1024)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
sock.close()
time.sleep(1.2)
st, _, _ = http("GET", "http://127.0.0.1:%d/v1/responses/resp_abort_nostore" % port)
check("[responses C4] no-store disconnect persists nothing", st == 404, st)

# 5.6 an empty conversation string no longer has any meaning for the router: the
# stream is forwarded unattached and stores nothing.
st, raw, _ = resp_post(port, stream_doc("resp_empty_conv", conversation=""))
check("[responses C4] empty conversation still streams",
      st == 200 and "response.completed" in raw, str(st))
st, _, _ = http("GET", "http://127.0.0.1:%d/v1/responses/resp_empty_conv" % port)
check("[responses C4] empty conversation stores nothing", st == 404, st)

check("[responses] no lua errors", "lua entry thread aborted" not in logs(name),
      logs(name)[-500:])
stop_router(name)

# ---------- 5.7 the output budget on the /v1/responses entry point ----------
# The production defect of 2026-10-04 (commit 75ecc37). This entry point had NO output
# budget coverage at all, which is precisely where the retired clamp hid: its field
# table was { max_tokens, max_completion_tokens }, so a responses body -- whose budget
# field is max_output_tokens -- always read as "the caller asked for nothing", and the
# nil branch then *wrote* max_tokens = <the virtual entry's declared context_window>.
# Production declared 350000 against a 524288 engine, so every request above 174288
# input tokens got a 400 nobody asked for (524288-350000=174288 is the observed
# threshold, with the completion count frozen at a number no caller named).
#
# Ruling 2026-10-04: the gateway forwards the caller's budget verbatim and never picks
# one for it. These probes read the bytes the GATEWAY sent (metadata.echo makes the
# worker echo its request) rather than the bytes the client meant to send, and they
# reproduce BOTH clamp sources of the old code: the entry's context_window, and the
# model card behind LMR_MODEL_CTX. Every check below fails on the pre-75ecc37 build and
# must pass on the current one -- that is what makes them worth keeping.
#
# Own container (bud_* names): the C1-C4 shapes above must stay byte-identical, and the
# worker above is reused here so nothing about the SSE shapes changes.
bud_name = "lr-respbud-" + RUN
bud_port = start_router({"SMG_POLICY": "round_robin",
                         "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                         "LMR_MODEL_CTX": "alpha:128"}, bud_name)
st, body = register(bud_port, "http://127.0.0.1:%d" % resp_up)
check("[responses budget] worker registered", st == 202, "%s %s" % (st, str(body)[:120]))
check("[responses budget] worker healthy", wait_ready(bud_port, 1), logs(bud_name))
# The entry the operator wrote in production: one virtual name over the responses
# worker, declaring the same 350000. No card declares a context_limit anywhere in this
# container, so the configuration-time window validator (aa9f7a3) deliberately stays
# out of the way -- this section is about forwarding bytes, not about validation.
st, body, _ = http("POST", "http://127.0.0.1:%d/config/virtual" % bud_port,
                   {"entries": [{"model": "vm-bud", "target": "alpha",
                                  "context_window": 350000}]})
check("[responses budget] entry with context_window=350000 accepted", st == 200,
      "%s %s" % (st, str(body)[:250]))
time.sleep(0.6)  # past the store's SNAPSHOT_TTL memo, so the pick sees the new entry

BUDGET_FIELDS = ("max_tokens", "max_completion_tokens", "max_output_tokens")


def resp_budget_probe(bud_port, model, rid, **extra):
    """One non-stream /v1/responses whose answer carries the forwarded body back."""
    doc = {"model": model, "input": "budget probe " + rid,
           "metadata": {"rid": rid, "echo": True}}
    doc.update(extra)
    st, body, _ = resp_post(bud_port, doc)
    doc = json.loads(body) if st == 200 else {}
    return st, doc.get("echo_body", {})


def resp_log_row(bud_port, worker_needle):
    """The newest responses row of the request log (output_budget lives there)."""
    st, body, _ = http("GET", "http://127.0.0.1:%d/logs?limit=200" % bud_port)
    rows = json.loads(body).get("requests", []) if st == 200 else []
    rows = [r for r in rows if worker_needle in (r.get("worker") or "")
            and r.get("endpoint") == "responses"]
    return rows[-1] if rows else {}


resp_worker_needle = "127.0.0.1:%d" % resp_up

# (a) the caller named its budget with the responses spelling: it must go out verbatim
#     and the two chat spellings must NOT appear -- the old code wrote both of them, at
#     350000 each, on top of a body that already said what it wanted.
st, echo = resp_budget_probe(bud_port, "vm-bud", "resp_bud_1", max_output_tokens=4096)
check("[responses budget] max_output_tokens survives the entry's declared window",
      st == 200 and echo.get("max_output_tokens") == 4096
      and "max_tokens" not in echo and "max_completion_tokens" not in echo,
      "%s %s" % (st, json.dumps(echo)[:300]))
# (The forwarded MODEL name for an entry is pinned by e2e_caps/e2e_profiles, where the
 # bindings are explicit; asserting it here would additionally depend on when model-id
 # discovery first lands, which is not what this section is about.)
row = resp_log_row(bud_port, resp_worker_needle)
check("[responses budget] the log records the caller's number, not the cap",
      row.get("output_budget") == 4096, json.dumps(row)[:300])

# (b) the caller named nothing, so the gateway must name nothing either. Absence of the
#     KEYS is the assertion: 0 and 350000 both satisfy "a number is present", so only
#     "the key was never written" separates "no budget" from "budget manufactured for
#     the client" -- the exact mistake that shipped 350000 to a 524288 engine.
st, echo = resp_budget_probe(bud_port, "vm-bud", "resp_bud_2")
check("[responses budget] no budget in, none manufactured out",
      st == 200 and not [f for f in BUDGET_FIELDS if f in echo],
      "%s %s" % (st, json.dumps(echo)[:300]))
row = resp_log_row(bud_port, resp_worker_needle)
check("[responses budget] the log omits output_budget when the caller named none",
      "output_budget" not in row, json.dumps(row)[:300])

# (c) the other clamp source, on the same entry shape: a request naming a real model has
#     no entry above it, so the old code fell back to the LMR_MODEL_CTX card (128) and
#     wrote max_tokens = max_completion_tokens = 128 into a responses body.
st, echo = resp_budget_probe(bud_port, "alpha", "resp_bud_3", max_output_tokens=2048)
check("[responses budget] max_output_tokens survives the model card too",
      st == 200 and echo.get("max_output_tokens") == 2048
      and "max_tokens" not in echo and "max_completion_tokens" not in echo,
      "%s %s" % (st, json.dumps(echo)[:300]))

# (d) the chat spelling that the old table DID know, still on the responses entry (this
#     worker answers 404 for anything else, and the budget edit never looked at the
#     route): max_completion_tokens must survive the card verbatim instead of being
#     pulled down to 128, and max_tokens -- absent from the request -- must stay absent
#     rather than appear at the cap. The old code rewrote BOTH fields to 128 here.
st, echo = resp_budget_probe(bud_port, "alpha", "resp_bud_4", max_completion_tokens=6144)
check("[responses budget] max_completion_tokens survives the model card",
      st == 200 and echo.get("max_completion_tokens") == 6144
      and "max_tokens" not in echo, "%s %s" % (st, json.dumps(echo)[:300]))
check("[responses budget] no lua errors",
      "lua entry thread aborted" not in logs(bud_name), logs(bud_name)[-500:])
stop_router(bud_name)
resp_server.shutdown()
resp_server.server_close()


# ---------- 6. DP-aware expansion (migrated from e2e_discovery_dp.py) ----------
# The Kubernetes poller was removed (doc/scope-trim.md) but SMG_DP_AWARE is the
# scheduler's own feature: a data-parallel engine found through POST /workers or
# SMG_WORKER_URLS still expands into one "<base>@<rank>" entry per rank, each
# with its own health counters and its own injected data_parallel_rank. The mock
# is an in-file stdlib server because it has to answer /server_info with a
# configurable dp_size (or a 500, or without the field) and echo the forwarded
# body so the injected rank is observable from the client side.
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DP_SERVERS = []


class QuietHandler(BaseHTTPRequestHandler):
    """BaseHTTPRequestHandler that swallows client resets.

    The router's cosockets close without a clean shutdown, so a reset
    mid-request is expected here; the stdlib default prints a full traceback for
    each one, which buries the check lines this suite's verdict is read from."""

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
    DP_SERVERS.append(srv)
    for _ in range(80):
        st, _, _ = http("GET", "http://127.0.0.1:%d/health" % port, timeout=2)
        if st == 200:
            return srv, port
        time.sleep(0.1)
    raise RuntimeError("dp mock %s never came up" % mock_id)


def dp_workers(port):
    st, body, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
    if st != 200:
        return None
    return json.loads(body).get("workers", [])


def dp_urls(port):
    ws = dp_workers(port)
    return sorted(w["url"] for w in ws) if ws is not None else None


def dp_wait_urls(port, want, timeout=40):
    want = sorted(want)
    for _ in range(int(timeout / 0.5)):
        if dp_urls(port) == want:
            return True
        time.sleep(0.5)
    return False


def dp_wait_workers(port, want_n, timeout=40):
    for _ in range(int(timeout / 0.5)):
        ws = dp_workers(port)
        if ws is not None and len(ws) == want_n:
            return True
        time.sleep(0.5)
    return False


def dp_wait_healthy(port, n, timeout=40):
    for _ in range(int(timeout / 0.5)):
        ws = dp_workers(port) or []
        if sum(1 for w in ws if w.get("is_healthy")) >= n:
            return True
        time.sleep(0.5)
    return False


def dp_wait_missing(port, gone, timeout=30):
    for _ in range(int(timeout / 0.5)):
        current = dp_urls(port)
        if current is not None and gone not in current:
            return True
        time.sleep(0.5)
    return False


def dp_metrics(port):
    st, body, _ = http("GET", "http://127.0.0.1:%d/metrics" % port)
    return body if st == 200 else ""


srv, wport = start_dp("dp4", dp_size=4, model="dp-model")
base = "http://127.0.0.1:%d" % wport
ranks = ["%s@%d" % (base, i) for i in range(4)]
name = "lr-dp4-" + RUN
port = start_router({"SMG_DP_AWARE": "1", "SMG_POLICY": "round_robin",
                     "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "SMG_HEALTH_CHECK_TIMEOUT_SECS": "3",
                     "SMG_WORKER_URLS": base}, name)

check("[dp4] /server_info dp_size=4 expands into 4 rank candidates",
      dp_wait_urls(port, ranks, timeout=30), dp_urls(port))
ws = dp_workers(port) or []
check("[dp4] the base entry is gone once the ranks exist",
      base not in [w["url"] for w in ws], dp_urls(port))
check("[dp4] every rank becomes healthy", dp_wait_healthy(port, 4, timeout=30),
      json.dumps(dp_workers(port)))
ws = dp_workers(port) or []
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
text = dp_metrics(port)
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

# --- one rank can be torn down on its own ------------------------------------
before = dp_urls(port)
victim = before[0]
victim_id = [w for w in (dp_workers(port) or []) if w["url"] == victim][0]["id"]
st, body, _ = http("DELETE", "http://127.0.0.1:%d/workers/%s" % (port, victim_id))
check("[dp4] DELETE a rank answers 202", st == 202, "%s %s" % (st, body[:200]))
check("[dp4] rank teardown removes only that rank",
      dp_wait_missing(port, victim, timeout=20)
      and sorted((dp_urls(port) or [])) == sorted(before[1:]), dp_urls(port))

# --- and the rank comes back without re-expanding ----------------------------
st, body, _ = http("POST", "http://127.0.0.1:%d/workers" % port, {"url": victim})
check("[dp4] a removed rank re-registers as a rank", st == 202, "%s %s" % (st, body[:200]))
check("[dp4] no nested expansion: still exactly 4 ranks",
      dp_wait_urls(port, ranks, timeout=25), dp_urls(port))
stop_router(name)

# --- dp_size=1 ---------------------------------------------------------------
_, wp1 = start_dp("dp1", dp_size=1, model="solo")
name = "lr-dp1-" + RUN
port = start_router({"SMG_DP_AWARE": "1", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d" % wp1}, name)
check("[dp1] dp_size=1 does not expand", dp_wait_workers(port, 1, timeout=25), dp_urls(port))
check("[dp1] the single entry keeps the plain url",
      dp_urls(port) == ["http://127.0.0.1:%d" % wp1], dp_urls(port))
check("[dp1] it becomes healthy and serves", dp_wait_healthy(port, 1, timeout=20),
      json.dumps(dp_workers(port)))
st, body, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                   {"model": "solo", "messages": [{"role": "user", "content": "solo"}]})
check("[dp1] non-expanded worker answers", st == 200 and "echo[solo]" in body,
      "%s %s" % (st, body[:150]))
check("[dp1] a worker without dp_rank gets the body untouched (no injection)",
      "data_parallel_rank" not in json.loads(body).get("echo_body", {}),
      json.dumps(json.loads(body).get("echo_body", {}))[:200])
stop_router(name)

# --- /server_info 500 --------------------------------------------------------
_, wp2 = start_dp("dpfail", dp_size=4, model="broken", mode="fail")
name = "lr-dpfail-" + RUN
port = start_router({"SMG_DP_AWARE": "1", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d" % wp2}, name)
stay = ["http://127.0.0.1:%d" % wp2]
check("[dpfail] a failing /server_info does not expand",
      dp_wait_workers(port, 1, timeout=20), dp_urls(port))
check("[dpfail] the base worker is kept and becomes healthy",
      dp_wait_healthy(port, 1, timeout=20), json.dumps(dp_workers(port)))
time.sleep(4)
check("[dpfail] still exactly one candidate after more sweeps",
      dp_urls(port) == stay, dp_urls(port))
stop_router(name)

# --- /server_info 200 without dp_size ----------------------------------------
_, wp3 = start_dp("dpmissing", dp_size=4, model="nodoc", mode="missing")
name = "lr-dpmissing-" + RUN
port = start_router({"SMG_DP_AWARE": "1", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d" % wp3}, name)
check("[dpmissing] /server_info without a usable dp_size does not expand",
      dp_wait_workers(port, 1, timeout=20), dp_urls(port))
check("[dpmissing] the worker is still routable",
      (dp_workers(port) or [{}])[0].get("model_id") == "nodoc", json.dumps(dp_workers(port)))
stop_router(name)

# --- /get_server_info fallback -----------------------------------------------
_, wp4 = start_dp("dplegacy", dp_size=2, model="legacy", only_legacy=True)
name = "lr-dplegacy-" + RUN
port = start_router({"SMG_DP_AWARE": "1", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d" % wp4}, name)
base4 = "http://127.0.0.1:%d" % wp4
check("[dplegacy] the /get_server_info spelling expands dp_size=2",
      dp_wait_urls(port, ["%s@0" % base4, "%s@1" % base4], timeout=25), dp_urls(port))
stop_router(name)

# --- SMG_DP_AWARE off --------------------------------------------------------
_, wp5 = start_dp("dpoff", dp_size=4, model="off")
name = "lr-dpoff-" + RUN
port = start_router({"SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                     "SMG_WORKER_URLS": "http://127.0.0.1:%d" % wp5}, name)
check("[dpoff] SMG_DP_AWARE unset leaves a dp_size=4 engine as one worker",
      dp_wait_workers(port, 1, timeout=20), dp_urls(port))
stop_router(name)

for srv in DP_SERVERS:
    srv.shutdown()
    srv.server_close()

failed = [r for r in RESULTS if not r[0]]
print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
for _, n, d in failed:
    print("FAILED: %s | %s" % (n, str(d)[:400]))
cleanup()
sys.exit(1 if failed else 0)
