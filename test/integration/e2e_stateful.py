#!/usr/bin/env python3
"""Round 2: snapshot write-back + reload restore, bucket/prefix_hash traffic,
empty-array preservation through the raw edits, manual regression."""
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

# ---------- 5. /v1/responses C2 patch + C4 conditional stream persistence ----------
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
      and doc.get("safety_identifier") == "u-9"
      and doc.get("conversation", {}).get("id") == "conv-c2",
      "%s %s" % (st, body[:300]))
check("[responses C2] empty model falls back to the request model",
      doc.get("model") == RESP_MODEL, body[:200])
check("[responses C2] empty arrays stay arrays through the patch",
      doc.get("tools") == [], json.dumps(doc.get("tools")))
st, stored, _ = http("GET", "http://127.0.0.1:%d/v1/responses/resp_c2" % port)
sdoc = json.loads(stored) if st == 200 else {}
check("[responses C2] stored copy is the patched bytes",
      st == 200 and sdoc.get("previous_response_id") == "prev-7"
      and sdoc.get("store") is False and sdoc.get("tools") == [],
      "%s %s" % (st, stored[:300]))

# 5.2 C4: store=true stream is retrievable once it completes
st, raw, hdrs = resp_post(port, stream_doc("resp_s1", store=True))
ctypes = [v for k, v in hdrs.items() if k.lower() == "content-type"]
check("[responses C4] store=true stream passed through",
      st == 200 and any("text/event-stream" in v for v in ctypes)
      and raw.count("event: response.completed") == 1, "%s %r" % (st, raw[-120:]))
st, got, _ = http("GET", "http://127.0.0.1:%d/v1/responses/resp_s1" % port)
check("[responses C4] store=true stream persisted",
      st == 200 and json.loads(got).get("id") == "resp_s1", "%s %s" % (st, got[:200]))

# 5.3 C4: conversation alone also enables persistence
st, raw, _ = resp_post(port, stream_doc("resp_s2", conversation="conv-s2"))
check("[responses C4] conversation-only stream persisted",
      st == 200 and "response.completed" in raw, str(st))
st, got, _ = http("GET", "http://127.0.0.1:%d/v1/responses/resp_s2" % port)
sdoc = json.loads(got) if st == 200 else {}
check("[responses C4] conversation-only stream is retrievable",
      st == 200 and sdoc.get("conversation", {}).get("id") == "conv-s2"
      and sdoc.get("conversation_id") == "conv-s2", "%s %s" % (st, got[:250]))

# 5.4 C4: store=false with no conversation keeps the zero-change pass-through,
# including chunk-by-chunk arrival timing (the pump must not buffer).
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
check("[responses C4] store=false without conversation is not persisted", st == 404, st)

# 5.5 C4 persistence branch: a client that drops after the first read stops the
# WRITES but not the READS (streaming.rs:574-610 sets receiver_connected=false and
# keeps draining), so the upstream finishes and the response is still stored.
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
st, got, _ = http("GET", "http://127.0.0.1:%d/v1/responses/resp_abort" % port)
check("[responses C4] store=true drains and persists after client disconnect",
      st == 200 and json.loads(got).get("id") == "resp_abort"
      and json.loads(got).get("status") == "completed", "%s %s" % (st, str(got)[:200]))

# 5.6 C4 non-persistence branch: without store or conversation there is nothing
# to accumulate, so the pump must tear down the moment the client goes away and
# must leave no row behind (streaming.rs:661-722 cancels the upstream request).
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

# 5.7 C4 gate is Rust's Option<String>::is_some(): an empty conversation string
# still enables persistence and still writes the (empty) id back. Rust would
# reject it later in item linking with a conversation-not-found warning, which is
# the same observable outcome here (the row stores, nothing links).
st, raw, _ = resp_post(port, stream_doc("resp_empty_conv", conversation=""))
st2, got, _ = http("GET", "http://127.0.0.1:%d/v1/responses/resp_empty_conv" % port)
edoc = json.loads(got) if st2 == 200 else {}
check("[responses C4] empty-string conversation enables persistence",
      st == 200 and "response.completed" in raw and st2 == 200
      and edoc.get("conversation") == {"id": ""}
      and edoc.get("conversation_id") == "", "%s %s %s" % (st, st2, str(got)[:250]))

check("[responses] no lua errors", "lua entry thread aborted" not in logs(name),
      logs(name)[-500:])
stop_router(name)
resp_server.shutdown()
resp_server.server_close()

failed = [r for r in RESULTS if not r[0]]
print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
for _, n, d in failed:
    print("FAILED: %s | %s" % (n, str(d)[:400]))
cleanup()
sys.exit(1 if failed else 0)
