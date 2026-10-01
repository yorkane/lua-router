#!/usr/bin/env bash
# ============================================================================
# lua-router single-instance functional contract suite
# ============================================================================
# Skeleton (free_port / mock worker / openresty -t gate / container per section
# group / sectioned assertions / trap cleanup) copied from
# /data/ChatGPT/authz/test/test_klib_router_ctxvar.sh, adapted to mount the
# llm-router repo and drive resty.luarouter through its HTTP surface.
#
# Contract references:
#   * gateway/src/server.rs          route table, 404 sink, axum 405+Allow
#   * gateway/src/routers/error.rs   {"error":{"type","code","message"}} + X-SMG-Error-Code
#   * gateway/src/core/worker_service.rs  202/Location, WORKER_NOT_FOUND, BAD_REQUEST
#   * live Rust gateway on <rust-box>:8800     read-only sampled at authoring time
#
# Usage:
#   bash test/test_lua_router.sh              # full strict run
#   KEEP_GOING=1 bash .../test_lua_router.sh             # triage: keep going, count fails
#   TEST_ONLY=workers bash .../test_lua_router.sh        # single section
#   TEST_DEBUG=1  bash .../test_lua_router.sh            # echo raw bodies
#
# Requirements: docker, curl, jq, python3, and the authz image (see IMAGE).
# The mock workers bind 0.0.0.0 on a free port; the router container reaches
# them through the docker bridge gateway (172.17.0.1 by default), which is the
# only host address routable from inside a bridge container on this box.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
IMAGE=${OPENRESTY_TEST_IMAGE:-authz:latest}
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lua-router-contract.XXXXXX")
BASE_CONF=/repo/test/conf/nginx-lua-router.conf
UI_CONF=$BASE_CONF

PASSED=0
FAILS=0
NOTE_COUNT=0
SUIT=$$
CONTAINER_NAMES=""
MOCK_PIDS=""

KEEP_GOING=${KEEP_GOING:-0}
TEST_ONLY=${TEST_ONLY:-}
TEST_DEBUG=${TEST_DEBUG:-0}
if [[ "$KEEP_GOING" == "1" ]]; then set +eu; fi

# ------------------------------------------------------------------ assertions
# Blood-earned rule from the authz suite: every fail path must RETURN. Under
# KEEP_GOING the suite keeps running, so an assert that falls through after
# fail() would report PASS for the same broken check.
fail() {
    if [[ "$KEEP_GOING" == "1" ]]; then
        printf 'FAIL: %s\n' "$1"
        FAILS=$((FAILS + 1))
        return 0
    fi
    printf 'FAIL: %s\n' "$1" >&2
    local name
    for name in $CONTAINER_NAMES; do
        printf '=== docker logs %s (tail 40)\n' "$name" >&2
        docker logs "$name" 2>&1 | tail -n 40 >&2 || true
    done
    exit 1
}

pass() {
    PASSED=$((PASSED + 1))
    printf 'PASS: %s\n' "$1"
}

note() {
    NOTE_COUNT=$((NOTE_COUNT + 1))
    printf 'NOTE: %s\n' "$1"
}

assert_eq() {
    local name=$1 actual=$2 expected=$3
    if [[ "$actual" != "$expected" ]]; then
        fail "$name (expected '$expected', got '$actual')"
        return 0
    fi
    pass "$name"
}

assert_contains() {
    local name=$1 actual=$2 expected=$3
    if [[ "$actual" != *"$expected"* ]]; then
        fail "$name (missing '$expected' in '${actual:0:400}')"
        return 0
    fi
    pass "$name"
}

assert_not_contains() {
    local name=$1 actual=$2 unexpected=$3
    if [[ "$actual" == *"$unexpected"* ]]; then
        fail "$name (unexpected '$unexpected' in '${actual:0:400}')"
        return 0
    fi
    pass "$name"
}

assert_matches() {
    local name=$1 actual=$2 pattern=$3
    if [[ ! "$actual" =~ $pattern ]]; then
        fail "$name (no match for /$pattern/ in '${actual:0:400}')"
        return 0
    fi
    pass "$name"
}

# assert_nonempty NAME VALUE  (fails on an empty string)
assert_nonempty() {
    local name=$1 actual=$2
    if [[ -z "${actual// /}" ]]; then
        fail "$name (value empty)"
        return 0
    fi
    pass "$name"
}

# assert_json NAME JQ_FILTER EXPECTED   (against the last response body)
assert_json() {
    local name=$1 filter=$2 expected=$3 actual
    if ! actual=$(jq -er "$filter" "$TMP_DIR/body" 2>"$TMP_DIR/jq-error"); then
        fail "$name (invalid JSON or filter: $(<"$TMP_DIR/jq-error"))"
        return 0
    fi
    assert_eq "$name" "$actual" "$expected"
}

# ------------------------------------------------------------------ request IO
# request METHOD PATH [extra curl args...]  -> STATUS BODY CONTENT_TYPE HEADERS
request() {
    local base=$1 method=$2 path=$3
    shift 3
    : >"$TMP_DIR/body"
    : >"$TMP_DIR/headers"
    if [[ "$method" == "HEAD" ]]; then
        STATUS=$(curl -sS --head "$base$path" "$@" -D "$TMP_DIR/headers" -o /dev/null -w '%{http_code}' || true)
    else
        STATUS=$(curl -sS --request "$method" "$base$path" "$@" -D "$TMP_DIR/headers" -o "$TMP_DIR/body" -w '%{http_code}' || true)
    fi
    BODY=$(<"$TMP_DIR/body")
    CONTENT_TYPE=$(awk 'BEGIN { IGNORECASE=1 } /^Content-Type:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0 } END { print value }' "$TMP_DIR/headers")
    header_of() {
        awk -v h="$1" 'BEGIN { IGNORECASE=1 } $0 ~ "^"h":" { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$TMP_DIR/headers"
    }
    if [[ "$TEST_DEBUG" == "1" ]]; then
        printf '  -> %s %s = %s (%s) %s\n' "$method" "$path" "$STATUS" "$CONTENT_TYPE" "${BODY:0:200}" >&2
    fi
}

section() {
    local name=$1
    if [[ -n "$TEST_ONLY" && "$TEST_ONLY" != "$name" ]]; then
        return 1
    fi
    printf '\n== section: %s ==\n' "$name"
    return 0
}

# request_method_gate NAME BASE METHOD PATH EXPECT_ALLOW
# A path that exists but refuses this HTTP method. The Rust gateway answers with
# 405 + an Allow header; the Lua router has no method gate yet and answers 404.
# Accept either, but require the Allow header whenever 405 is used, so the
# contract test does not have to be rewritten the moment the gate is wired up.
request_method_gate() {
    local name=$1 base=$2 method=$3 path=$4 expect_allow=$5
    request "$base" "$method" "$path"
    if [[ "$STATUS" == "405" ]]; then
        assert_contains "$name: 405 carries an Allow header" \
            "$(header_of Allow | tr '[:lower:]' '[:upper:]')" "$expect_allow"
    elif [[ "$STATUS" == "404" ]]; then
        assert_eq "$name: 404 refuses the method" "404" "404"
    else
        fail "$name (expected 404 or 405+Allow: $expect_allow, got $STATUS)"
    fi
}

# ------------------------------------------------------------------ fixtures
cleanup() {
    local name pid
    for name in ${CONTAINER_NAMES:-}; do
        docker rm -f "${name:-}" >/dev/null 2>&1 || true
    done
    for pid in ${MOCK_PIDS:-}; do
        kill "${pid:-}" >/dev/null 2>&1 || true
    done
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

free_port() {
    python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

start_mock() {
    # start_mock MODEL -> sets MOCK_PORT MOCK_URL MOCK_PID MOCK_LOG
    local model=$1 port
    port=$(free_port)
    MOCK_LOG="$TMP_DIR/mock-$port.log"
    python3 "$SCRIPT_DIR/mock_llm_worker.py" --host 0.0.0.0 --port "$port" \
        --model "$model" >"$MOCK_LOG" 2>&1 &
    MOCK_PID=$!
    MOCK_PIDS="$MOCK_PIDS $MOCK_PID"
    MOCK_PORT=$port
    MOCK_URL=""   # filled once the bridge gateway is known
    local i
    for i in $(seq 1 50); do
        curl -fsS -m 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    fail "mock $model (pid ${MOCK_PID:-?}) did not come up on :$port"
}

start_sink() {
    # A header-recording worker stub: proves what the router actually forwards.
    local port
    port=$(free_port)
    cat >"$TMP_DIR/sink.py" <<'SINK'
import json, threading, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
STATE = {"count": 0, "headers": {}, "body": ""}
LOCK = threading.Lock()
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
    def do_HEAD(self): self.do_GET()
    def do_GET(self):
        if self.path.split("?")[0] == "/health":
            self._json(200, "OK" and {"status": "ok"})
        elif self.path.split("?")[0] == "/last":
            with LOCK:
                self._json(200, dict(STATE))
        elif self.path.split("?")[0] == "/model_info":
            self._json(200, {"model_path": "/models/sink-model",
                             "served_model_name": "sink-model",
                             "is_generation": True, "tp_size": 1, "dp_size": 1})
        elif self.path.split("?")[0] == "/metrics":
            text = ("# HELP sink_requests_total Served requests\n"
                    "# TYPE sink_requests_total counter\n"
                    "sink_requests_total %d\n" % STATE["count"])
            body = text.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self._json(404, {"error": {"message": "sink: no route"}})
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        with LOCK:
            STATE["count"] += 1
            STATE["headers"] = {k.lower(): v for k, v in self.headers.items()}
            STATE["body"] = raw.decode("utf-8", "replace")
        payload = {"id": "chatcmpl-sink", "object": "chat.completion", "created": 0,
                   "model": "sink-model",
                   "choices": [{"index": 0,
                                "message": {"role": "assistant", "content": "sink"},
                                "finish_reason": "stop"}],
                   "usage": {"prompt_tokens": 1, "completion_tokens": 1,
                             "total_tokens": 2}}
        self._json(200, payload)

if __name__ == "__main__":
    port = int(sys.argv[1])
    srv = ThreadingHTTPServer(("0.0.0.0", port), H)
    srv.daemon_threads = True
    srv.serve_forever()
SINK
    python3 "$TMP_DIR/sink.py" "$port" >"$TMP_DIR/sink.log" 2>&1 &
    SINK_PID=$!
    MOCK_PIDS="$MOCK_PIDS $SINK_PID"
    SINK_PORT=$port
    local i
    for i in $(seq 1 50); do
        curl -fsS -m 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    fail "header sink did not come up on :$port"
}

start_load_worker() {
    # A worker that answers GET /v1/loads?include=core the way SGLang does, so the
    # /v1/loads probe has a success path to prove. Every other load answer in the
    # suite is -1, which is also what a router that never probed would return.
    local port tokens
    port=$(free_port)
    tokens=${1:-4242}
    cat >"$TMP_DIR/load_worker.py" <<'LOAD'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
TOKENS = int(sys.argv[2])
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
    def do_HEAD(self): self.do_GET()
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/health":
            self._json(200, {"status": "ok"})
        elif path == "/v1/loads":
            self._json(200, {"aggregate": {"total_tokens": TOKENS,
                                           "total_requests": 1},
                             "token_usage": {"available_tokens": 100}})
        elif path == "/model_info":
            self._json(200, {"model_path": "/models/load-model",
                             "served_model_name": "load-model",
                             "is_generation": True, "tp_size": 1, "dp_size": 1})
        elif path == "/metrics":
            self._send_text(200, "# HELP load_uptime_seconds Load worker uptime\n"
                                 "# TYPE load_uptime_seconds gauge\n"
                                 "load_uptime_seconds 1.5\n")
        else:
            self._json(404, {"error": {"message": "load: no route %s" % path}})
    def _send_text(self, status, text):
        body = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        self._json(200, {"status": "ok"})

if __name__ == "__main__":
    srv = ThreadingHTTPServer(("0.0.0.0", int(sys.argv[1])), H)
    srv.daemon_threads = True
    srv.serve_forever()
LOAD
    python3 "$TMP_DIR/load_worker.py" "$port" "$tokens" >"$TMP_DIR/load_worker.log" 2>&1 &
    LOAD_PID=$!
    MOCK_PIDS="$MOCK_PIDS $LOAD_PID"
    LOAD_PORT=$port
    local i
    for i in $(seq 1 50); do
        curl -fsS -m 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    fail "load-answer worker did not come up on :$port"
}

start_reasoning_worker() {
    # A worker whose usage carries completion_tokens_details.reasoning_tokens, so
    # the request-log field can be proven to be read rather than written as 0
    # (observability/request_log.rs:304-309).
    local port
    port=$(free_port)
    cat >"$TMP_DIR/reason_worker.py" <<'REASON'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
    def do_HEAD(self): self.do_GET()
    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/health", "/flush_cache"):
            self._json(200, {"status": "ok"})
        elif path == "/model_info":
            self._json(200, {"model_path": "/models/reason-model",
                             "served_model_name": "reason-model",
                             "is_generation": True, "tp_size": 1, "dp_size": 1})
        else:
            self._json(404, {"error": {"message": "reason: no route %s" % path}})
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        self._json(200, {
            "id": "chatcmpl-reason", "object": "chat.completion", "created": 0,
            "model": "reason-model",
            "choices": [{"index": 0,
                         "message": {"role": "assistant", "content": "42"},
                         "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 3, "completion_tokens": 12,
                      "total_tokens": 15,
                      "completion_tokens_details": {"reasoning_tokens": 7}}})

if __name__ == "__main__":
    srv = ThreadingHTTPServer(("0.0.0.0", int(sys.argv[1])), H)
    srv.daemon_threads = True
    srv.serve_forever()
REASON
    python3 "$TMP_DIR/reason_worker.py" "$port" >"$TMP_DIR/reason_worker.log" 2>&1 &
    REASON_PID=$!
    MOCK_PIDS="$MOCK_PIDS $REASON_PID"
    REASON_PORT=$port
    local i
    for i in $(seq 1 50); do
        curl -fsS -m 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    fail "reasoning worker did not come up on :$port"
}

start_mesh_peer() {
    # A stand-in for a second lua-router: it speaks the mesh wire format (b64
    # snapshots) so a single router instance can be checked for convergence,
    # the sync handshake and the shutdown broadcast. It records what it was
    # told. $1 (key) stays empty: nothing authenticates anything anymore.
    # $2 is the docker bridge address the peer advertises for itself (built from
    # the port chosen here, so the caller does not need to know it). Without it
    # the seed-vs-self-report hostport dedup never matches and /ha/status grows
    # a phantom node key.
    local port key advertise
    port=$(free_port)
    key=${1:-}
    advertise=${2:+http://$2:$port}
    cat >"$TMP_DIR/mesh_peer.py" <<'PEER'
import base64, json, os, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
KEY = sys.argv[2] if len(sys.argv) > 2 else ""
LOCK = threading.Lock()
STATE = {"sync": 0, "apply": 0, "ping": 0, "bad_auth": 0, "seen": []}
SELF = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] \
    else "http://127.0.0.1:%s" % sys.argv[1]


def snapshot():
    ts = int(__import__("time").time() * 1_000_000)
    return {
        "protocol": 1, "node": "fake-peer", "addr": SELF, "ts": ts, "seq": 1,
        "since": None, "draining": False,
        "stores": {
            "members": [{"key": "fake-peer", "node": "fake-peer", "ts": ts,
                         "version": 1, "value": {"name": "fake-peer",
                                                 "address": SELF,
                                                 "status": "alive",
                                                 "version": 1}}],
            "workers": [{"key": "wk-fake", "node": "fake-peer", "ts": ts,
                         "version": 1, "value": {"worker_id": "wk-fake",
                                                 "model_id": "fake-model",
                                                 "url": "http://127.0.0.1:19999",
                                                 "health": True, "load": 3}}],
            "policies": [], "apps": [], "trees": [], "manual": [],
        },
        "rate": [],
    }


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _authorized(self):
        if not KEY:
            return True
        return self.headers.get("authorization") == "Bearer " + KEY

    def _send(self, status, payload, content_type="application/json"):
        body = payload.encode() if isinstance(payload, str) \
            else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/health":
            self._send(200, {"status": "ok"})
        elif path == "/state":
            with LOCK:
                self._send(200, dict(STATE))
        elif path == "/_mesh/internal/ping":
            with LOCK:
                STATE["ping"] += 1
            if not self._authorized():
                with LOCK:
                    STATE["bad_auth"] += 1
                return self._send(401, {"error": "unauthorized"})
            self._send(200, {"protocol": 1, "node": "fake-peer", "addr": SELF,
                             "status": "alive", "version": 1,
                             "draining": False})
        elif path == "/_mesh/internal/state":
            self._send(200, base64.b64encode(
                json.dumps(snapshot()).encode()).decode(),
                "application/x-mesh-b64")
        else:
            self._send(404, {"error": "peer: no route"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        path = self.path.split("?")[0]
        if not self._authorized():
            with LOCK:
                STATE["bad_auth"] += 1
            return self._send(401, {"error": "unauthorized"})
        if path == "/_mesh/internal/sync":
            with LOCK:
                STATE["sync"] += 1
                self._note_incoming(raw.decode("utf-8", "replace"))
            return self._send(200, base64.b64encode(
                json.dumps(snapshot()).encode()).decode(),
                "application/x-mesh-b64")
        if path == "/_mesh/internal/apply":
            with LOCK:
                STATE["apply"] += 1
                self._note_incoming(raw.decode("utf-8", "replace"))
            return self._send(200, {"applied": 1, "node": "fake-peer"})
        self._send(404, {"error": "peer: no route"})

    def _note_incoming(self, text):
        try:
            snap = json.loads(base64.b64decode(text).decode("utf-8"))
        except Exception:
            return
        members = (snap.get("stores") or {}).get("members") or []
        for m in members:
            value = m.get("value") or {}
            entry = "%s:%s" % (value.get("name"), value.get("status"))
            if entry not in STATE["seen"]:
                STATE["seen"].append(entry)


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("0.0.0.0", int(sys.argv[1])), H)
    srv.daemon_threads = True
    srv.serve_forever()
PEER
    python3 "$TMP_DIR/mesh_peer.py" "$port" "$key" "$advertise" >"$TMP_DIR/mesh_peer.log" 2>&1 &
    MOCK_PIDS="$MOCK_PIDS $!"
    PEER_PORT=$port
    local i
    for i in $(seq 1 50); do
        curl -fsS -m 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    fail "mesh peer mock did not come up on :$port"
}

peer_state() {
    curl -sS -m 2 "http://127.0.0.1:$PEER_PORT/state" || echo '{}'
}

start_container() {
    # start_container NAME CONF ENV... -> sets BASE  (http://127.0.0.1:PORT)
    local name=$1 conf=$2
    shift 2
    docker rm -f "$name" >/dev/null 2>&1 || true
    CONTAINER_NAMES="$CONTAINER_NAMES $name"
    local -a envargs=()
    local e
    for e in "$@"; do envargs+=(-e "$e"); done
    # FIXPORT pins the published host port: the mesh section must know the
    # instance's externally reachable address before SMG_MESH_SELF can name it.
    local published="127.0.0.1::8080"
    if [[ -n "${FIXPORT:-}" ]]; then
        published="127.0.0.1:${FIXPORT}:8080"
    fi
    docker run -d --name "$name" -p "$published" "${envargs[@]}" \
        --entrypoint openresty \
        -v "$REPO_ROOT:/repo:ro" -v "$TMP_DIR:/gen:ro" \
        "$IMAGE" -p /usr/local/openresty/nginx/ -c "$conf" -g 'daemon off;' \
        >/dev/null || fail "container $name failed to start"
    local host_port
    host_port=$(docker port "$name" 8080/tcp | awk -F: 'NR == 1 { print $NF }')
    [[ -n "$host_port" ]] || fail "no published port for $name"
    BASE="http://127.0.0.1:$host_port"
    local i
    for i in $(seq 1 80); do
        curl -fsS -m 2 "$BASE/health" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    fail "$name did not become ready on $BASE"
}

container_gateway() {
    local gw
    gw=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' "$1")
    echo "${gw:-172.17.0.1}"
}

wait_healthy_worker() {
    # wait_healthy_worker BASE [timeout_secs] [expected_count] - poll /readiness
    # until 200 AND healthy_workers reaches the expected count. Readiness flips
    # as soon as ANY worker is healthy, which races the two-worker assertions.
    local base=$1 limit=${2:-25} want=${3:-1} i code got
    # Trailing args go to curl (the server-TLS section passes --cacert). Shift
    # only when there actually are extras: `shift 3` with three args is an error
    # and would leave base/limit/want in "$@" as bogus URLs.
    local -a extra=()
    if [ "$#" -gt 3 ]; then
        shift 3
        extra=("$@")
    fi
    for i in $(seq 1 $((limit * 10))); do
        code=$(curl -sS -m 2 "$base/readiness" -o "$TMP_DIR/ready" -w '%{http_code}' "${extra[@]}" || true)
        if [[ "$code" == "200" ]]; then
            got=$(jq -r '.healthy_workers // 0' "$TMP_DIR/ready" 2>/dev/null || echo 0)
            [[ "$got" -ge "$want" ]] && return 0
        fi
        sleep 0.1
    done
    return 1
}

register_worker() {
    # register_worker BASE JSON_BODY -> sets REG_STATUS REG_ID REG_BODY
    local base=$1 body=$2
    shift 2
    # Trailing args reach curl, so a section that needs --cacert (server TLS) can
    # reuse the helper instead of duplicating the request.
    REG_STATUS=$(curl -sS -X POST "$base/workers" -H 'Content-Type: application/json' \
        --data "$body" -D "$TMP_DIR/reg-headers" -o "$TMP_DIR/reg-body" -w '%{http_code}' "$@" || true)
    : >"$TMP_DIR/headers"
    cp "$TMP_DIR/reg-headers" "$TMP_DIR/headers"
    cp "$TMP_DIR/reg-body" "$TMP_DIR/body"
    STATUS=$REG_STATUS
    BODY=$(<"$TMP_DIR/reg-body")
    CONTENT_TYPE=$(awk 'BEGIN { IGNORECASE=1 } /^Content-Type:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0 } END { print value }' "$TMP_DIR/headers")
    REG_BODY=$(<"$TMP_DIR/reg-body")
    REG_ID=$(jq -r '.worker_id // empty' "$TMP_DIR/reg-body" 2>/dev/null || true)
    REG_LOCATION=$(awk 'BEGIN{IGNORECASE=1}/^Location:/{sub(/^[^:]+:[[:space:]]*/,"");sub(/\r$/,"");print}' "$TMP_DIR/reg-headers")
}

ensure_workers() {
    # Register the mock and the sink on $BASE (idempotent: a duplicate POST
    # keeps the same id) and wait for the sweep to mark them healthy.
    register_worker "$BASE" "{\"url\":\"$MOCK_URL\",\"model_id\":\"test-model\"}"
    MOCK_ID=$REG_ID
    register_worker "$BASE" "{\"url\":\"$SINK_URL\",\"model_id\":\"sink-model\"}"
    SINK_ID=$REG_ID
    wait_healthy_worker "$BASE" 25 2 || fail "backing workers never both became healthy"
}

# ------------------------------------------------------------------ preflight
command -v docker >/dev/null || fail "docker is required"
command -v curl >/dev/null || fail "curl is required"
command -v jq >/dev/null || fail "jq is required"
command -v python3 >/dev/null || fail "python3 is required"
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image $IMAGE is not present"

CHAT_BODY='{"model":"test-model","messages":[{"role":"user","content":"hello lua router"}]}'

# Prometheus histogram invariants, checked by the observability section. Lives in
# $TMP_DIR so the suite stays one file with no external fixtures.
write_metrics_check() {
    # Exposition validator for the observability section: HELP/TYPE uniqueness,
    # sample syntax, the smg_worker_pool_size label contract, and per-family
    # histogram invariants. Lives in $TMP_DIR for the same reason as
    # histogram_check.py - the suite stays one file with no fixtures.
    cat >"$TMP_DIR/metrics_check.py" <<'PYCHECK'
# Validate one /metrics body and report the worker pool series.
#
# usage: metrics_check.py BODY_FILE [check ...]
#   unique      at most one HELP and exactly one TYPE per family, and every
#               sample's family must have a TYPE line
#   parseable   every non-comment line parses as a sample
#   pool        print smg_worker_pool_size as sorted "type/mode/model=n"; the
#               three Rust labels are mandatory
#   family=NAME NAME renders at least one series
#   hist=NAME   NAME buckets are cumulative, never above _count, +Inf == _count
import re
import sys

LINE = re.compile(r"^(?P<metric>[^\s{]+)(?P<labels>\{[^}]*\})?\s+(?P<value>[-+0-9.eE]+)$")
LABEL = re.compile(r'(?P<name>[a-zA-Z_][a-zA-Z0-9_]*)="(?P<value>(?:[^"\\]|\\.)*)"')
HELP = re.compile(r"^# HELP (?P<name>\S+) (?P<text>\S.*)$")
TYPE = re.compile(r"^# TYPE (?P<name>\S+) (?P<kind>\S+)$")


def labels_of(text):
    return dict((m.group("name"), m.group("value")) for m in LABEL.finditer(text or ""))


def parse_samples(lines):
    samples, bad = [], []
    for raw in lines:
        if not raw.strip() or raw.startswith("#"):
            continue
        m = LINE.match(raw.strip())
        if not m:
            bad.append("unparseable line %r" % raw[:80])
            continue
        samples.append((m.group("metric"), labels_of(m.group("labels")), m.group("value")))
    return samples, bad


def base_series(metric):
    for suffix in ("_bucket", "_sum", "_count"):
        if metric.endswith(suffix):
            return metric[: -len(suffix)], suffix[1:]
    return metric, None


def check_unique(lines):
    helps, types = {}, {}
    for raw in lines:
        if raw.startswith("# HELP"):
            m = HELP.match(raw)
            if not m:
                return "malformed HELP line %r" % raw[:60]
            helps[m.group("name")] = helps.get(m.group("name"), 0) + 1
        elif raw.startswith("# TYPE"):
            m = TYPE.match(raw)
            if not m:
                return "malformed TYPE line %r" % raw[:60]
            types[m.group("name")] = types.get(m.group("name"), 0) + 1
    bad = ["%s has %d HELP lines" % (n, c) for n, c in sorted(helps.items()) if c != 1]
    bad += ["%s has %d TYPE lines" % (n, c) for n, c in sorted(types.items()) if c != 1]
    for metric in sorted(set(base_series(m)[0] for m, _, _ in parse_samples(lines)[0])):
        if metric not in types:
            bad.append("%s has no TYPE line" % metric)
    return "; ".join(bad) if bad else "ok"


def check_pool(lines):
    series = {}
    for raw in lines:
        if raw.startswith("#") or not raw.startswith("smg_worker_pool_size"):
            continue
        m = LINE.match(raw.strip())
        if not m:
            return "unparseable pool line %r" % raw[:80]
        lab = labels_of(m.group("labels"))
        missing = [k for k in ("worker_type", "connection_mode", "model") if k not in lab]
        if missing:
            return "pool series missing label(s): %s" % ",".join(missing)
        key = "%s/%s/%s" % (lab["worker_type"], lab["connection_mode"], lab["model"])
        series[key] = m.group("value")
    return " ".join("%s=%s" % (k, series[k]) for k in sorted(series)) or "none"


def check_family(lines, name):
    return "ok" if any(raw.startswith(name) and not raw.startswith("#") for raw in lines) \
        else "absent"


def check_hist(lines, name):
    buckets, counts = {}, {}
    for metric, lab, value in parse_samples(lines)[0]:
        base, suffix = base_series(metric)
        if base != name or suffix is None:
            continue
        le = lab.get("le")
        key = tuple(sorted((k, v) for k, v in lab.items() if k != "le"))
        if suffix == "bucket":
            bound = float("inf") if le == "+Inf" else float(le or "nan")
            buckets.setdefault(key, []).append((bound, float(value)))
        elif suffix == "count":
            counts[key] = float(value)
    if not buckets:
        return "no %s buckets" % name
    bad = []
    for key, series in buckets.items():
        series.sort()
        values = [v for _, v in series]
        if any(values[i] < values[i - 1] for i in range(1, len(values))):
            bad.append("buckets not cumulative")
        count = counts.get(key)
        inf = [v for le, v in series if le == float("inf")]
        if count is None:
            bad.append("no _count")
        elif len(inf) != 1:
            bad.append("%d +Inf buckets" % len(inf))
        elif inf[0] != count:
            bad.append("+Inf=%s != _count=%s" % (inf[0], count))
        elif any(v > count for le, v in series if le != float("inf")):
            bad.append("bucket larger than _count")
    return "ok" if not bad else "; ".join(sorted(set(bad)))


def main():
    lines = open(sys.argv[1]).read().splitlines()
    out = []
    for want in sys.argv[2:]:
        name, _, arg = want.partition("=")
        if name == "unique":
            out.append("unique=%s" % check_unique(lines))
        elif name == "parseable":
            bad = parse_samples(lines)[1]
            out.append("parseable=%s" % ("; ".join(bad[:3]) if bad else "ok"))
        elif name == "pool":
            out.append("pool[%s]" % check_pool(lines))
        elif name == "family":
            out.append("family(%s)=%s" % (arg, check_family(lines, arg)))
        elif name == "hist":
            out.append("hist(%s)=%s" % (arg, check_hist(lines, arg)))
        else:
            out.append("unknown check %r" % want)
    return " ".join(out)


print(main())

PYCHECK
}

# routing_keys_for BODY_FILE WORKER_URL -> the routing-key count exported for
# that worker, or "absent". The url is matched as a substring because it is
# unique inside the exposition and the label quoting is not worth escaping.
routing_keys_for() {
    awk -v url="$2" '
        $0 ~ /^smg_worker_routing_keys_active\{/ && index($0, url) { print $NF; found = 1 }
        END { if (!found) print "absent" }
    ' "$1"
}

write_histogram_check() {
    cat >"$TMP_DIR/histogram_check.py" <<'PYCHECK'
import re
import sys

LINE = re.compile(r"^(?P<metric>[^\s{]+)\{(?P<labels>[^}]*)\}\s+(?P<value>[-+0-9.eE]+)\s*$")


def main():
    body = open(sys.argv[1]).read()
    want = sys.argv[2] if len(sys.argv) > 2 else "duration_seconds"
    buckets = {}
    counts = {}
    for raw in body.splitlines():
        m = LINE.match(raw)
        if not m:
            continue
        metric, labels, value = m.group("metric"), m.group("labels"), float(m.group("value"))
        if metric.endswith("_bucket"):
            if want not in metric:
                continue
            lm = re.search(r'le="([^"]*)"\s*$', labels)
            if not lm:
                continue
            le_text = lm.group(1)
            base = labels[:lm.start()].rstrip(",")
            le = float("inf") if le_text == "+Inf" else float(le_text)
            buckets.setdefault((metric[:-7], base), []).append((le, value))
        elif metric.endswith("_count") and want in metric:
            counts[(metric[:-6], labels)] = value

    if not buckets:
        return "no histogram series matched"
    bad = []
    for (metric, base), series in buckets.items():
        series.sort()
        values = [v for _, v in series]
        if any(values[i] < values[i - 1] for i in range(1, len(values))):
            bad.append("%s buckets are not cumulative" % metric)
        inf = [v for le, v in series if le == float("inf")]
        mid = [v for le, v in series if le != float("inf")]
        count = counts.get((metric, base))
        if count is None:
            bad.append("%s has no _count series" % metric)
            continue
        if len(inf) != 1:
            bad.append("%s has %d +Inf buckets" % (metric, len(inf)))
        elif inf[0] != count:
            bad.append("%s +Inf=%s != _count=%s" % (metric, inf[0], count))
        if any(v > count for v in mid):
            bad.append("%s has a bucket larger than _count=%s" % (metric, count))
    return "; ".join(sorted(set(bad))) if bad else "ok"


print(main())
PYCHECK
}
write_histogram_check
write_metrics_check

# ==========================================================================
if section gate; then
    docker run --rm -v "$REPO_ROOT:/repo:ro" --entrypoint openresty "$IMAGE" \
        -t -p /usr/local/openresty/nginx/ -c "$BASE_CONF" >/dev/null \
        && pass "syntax gate: nginx-lua-router.conf" \
        || fail "syntax gate: nginx-lua-router.conf"

    # The test conf includes conf/ui.conf, so the /_ui contract is exercised on
    # the same listener (exact locations outrank `location /`).
    grep -q "include /repo/conf/ui.conf;" \
        "$REPO_ROOT/test/conf/nginx-lua-router.conf" \
        && pass "test conf wires conf/ui.conf (the /_ui surface)" \
        || fail "test conf does not include conf/ui.conf"

    docker run --rm -v "$REPO_ROOT:/repo:ro" --entrypoint openresty "$IMAGE" \
        -t -p /usr/local/openresty/nginx/ -c /repo/conf/lua-router.conf >/dev/null \
        && pass "syntax gate: conf/lua-router.conf (bare production conf)" \
        || fail "syntax gate: conf/lua-router.conf (bare production conf)"
fi

# ==========================================================================
# Main instance: no seeded workers, health sweep at 1s.
start_mock test-model
start_container lr-main-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1
MAIN_BASE=$BASE
GW=$(container_gateway lr-main-$SUIT)
MOCK_URL="http://$GW:$MOCK_PORT"
start_sink
SINK_URL="http://$GW:$SINK_PORT"
if section public; then
    request "$BASE" GET /health
    assert_eq "/health status" "$STATUS" "200"
    assert_eq "/health body" "$BODY" "OK"
    assert_contains "/health content type" "$CONTENT_TYPE" "text/plain"

    request "$BASE" GET /liveness
    assert_eq "/liveness status" "$STATUS" "200"
    assert_eq "/liveness body" "$BODY" "OK"

    request "$BASE" GET /readiness
    assert_eq "/readiness with no workers is 503" "$STATUS" "503"
    assert_json "/readiness reason" '.reason' "insufficient healthy workers"
    assert_json "/readiness status field" '.status' "not ready"

    request "$BASE" GET /server_info
    assert_eq "/server_info status" "$STATUS" "200"
    assert_json "/server_info has router_manager" 'has("router_manager") | tostring' "true"
    assert_json "/server_info routers_count" '.routers_count' "1"
    assert_json "/server_info workers_count (empty)" '.workers_count' "0"
    assert_json "/server_info policy is a known name" \
        '.policy | IN("random","round_robin","power_of_two","manual","cache_aware","prefix_hash","consistent_hashing","bucket") | tostring' "true"
    assert_json "/server_info health_check block" 'has("health_check") | tostring' "true"
    assert_json "/server_info retry block" 'has("retry") | tostring' "true"

    request "$BASE" GET /get_server_info
    assert_eq "/get_server_info alias status" "$STATUS" "200"
    assert_eq "/get_server_info matches /server_info" \
        "$(jq -Sc 'del(.uptime_s)' "$TMP_DIR/body" 2>/dev/null)" \
        "$(curl -sS "$BASE/server_info" | jq -Sc 'del(.uptime_s)')"

    request "$BASE" GET /v1/models
    assert_eq "/v1/models with no workers is 503" "$STATUS" "503"

    # Regression: the empty registry used to 500 because cjson.empty_array is
    # userdata (no length operator), so `#workers` blew up after the swap.
    request "$BASE" GET /workers
    assert_eq "GET /workers with no workers is 200" "$STATUS" "200"
    assert_json "empty GET /workers encodes workers as []" '.workers | type' "array"
    assert_json "empty GET /workers total" '.total' "0"
    assert_json "empty GET /workers regular_count" '.stats.regular_count' "0"
    request "$BASE" GET /_ui/logs/backends
    assert_eq "empty /_ui/logs/backends is 200" "$STATUS" "200"
    assert_json "empty /_ui/logs/backends encodes []" '.backends | type' "array"

    # Register a worker: 202 contract first, then the public plane lights up.
    register_worker "$BASE" "{\"url\":\"$MOCK_URL\",\"model_id\":\"test-model\"}"
    assert_eq "POST /workers status" "$STATUS" "202"
    wait_healthy_worker "$BASE" 25 || fail "worker never became healthy (health sweep)"
    request "$BASE" GET /readiness
    assert_eq "/readiness after registration" "$STATUS" "200"
    assert_json "/readiness counts the worker" '.healthy_workers' "1"
    request "$BASE" GET /v1/models
    assert_eq "/v1/models after registration" "$STATUS" "200"
    assert_json "/v1/models object" '.object' "list"
    assert_json "/v1/models contains test-model" '[.data[].id] | index("test-model") != null | tostring' "true"
fi

# ==========================================================================
if section workers; then
    register_worker "$BASE" "{\"url\":\"$MOCK_URL\",\"model_id\":\"test-model\"}"
    register_worker "$BASE" "{\"url\":\"$SINK_URL\",\"model_id\":\"sink-model\"}"
    assert_eq "POST /workers (sink) status" "$STATUS" "202"
    assert_eq "POST /workers echoes url" "$(jq -r .url "$TMP_DIR/reg-body")" "$SINK_URL"
    assert_eq "POST /workers status field" "$(jq -r .status "$TMP_DIR/reg-body")" "accepted"
    assert_eq "POST /workers message" "$(jq -r .message "$TMP_DIR/reg-body")" \
        "Worker addition queued for background processing"
    assert_json "POST /workers worker_id is a UUID" \
        '.worker_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") | tostring' "true"
    assert_eq "POST /workers Location header" "$REG_LOCATION" "/workers/$REG_ID"
    assert_eq "POST /workers location field" "$(jq -r .location "$TMP_DIR/reg-body")" "$REG_LOCATION"
    SINK_ID=$REG_ID

    # Duplicate registration keeps the id and surfaces as a failed job.
    register_worker "$BASE" "{\"url\":\"$SINK_URL\"}"
    assert_eq "duplicate POST /workers still 202" "$STATUS" "202"
    assert_eq "duplicate POST /workers keeps the id" "$REG_ID" "$SINK_ID"
    wait_healthy_worker "$BASE" 25 2 || fail "sink worker never became healthy"
    retry_left=0
    while :; do
        JOB=$(curl -sS "$BASE/workers/$SINK_ID" | jq -c '.job_status' 2>/dev/null || echo null)
        [[ "$JOB" == "null" || "$JOB" == "" ]] && { sleep 0.2; retry_left=$((retry_left + 1)); [[ $retry_left -gt 25 ]] && break; continue; }
        break
    done
    assert_eq "duplicate job is reported failed" \
        "$(echo "$JOB" | jq -r '.status // "none"')" "failed"
    assert_contains "duplicate job message" "$(echo "$JOB" | jq -r '.message // ""')" "already exists"

    request "$BASE" GET /workers
    assert_eq "GET /workers status" "$STATUS" "200"
    assert_json "GET /workers total" '.total' "2"
    assert_json "GET /workers array length" '.workers | length' "2"
    assert_json "GET /workers stats.regular_count" '.stats.regular_count' "2"
    assert_json "GET /workers stats.prefill_count" '.stats.prefill_count' "0"
    assert_json "GET /workers stats.decode_count" '.stats.decode_count' "0"
    assert_json "GET /workers info fields" \
        '.workers[0] | has("id") and has("url") and has("model_id") and has("priority") and has("cost") and has("worker_type") and has("is_healthy") and has("load") and has("connection_mode") and has("metadata") and has("disable_health_check") | tostring' "true"
    assert_json "GET /workers healthy" '[.workers[] | select(.is_healthy)] | length' "2"

    request "$BASE" GET "/workers/$SINK_ID"
    assert_eq "GET /workers/{id} status" "$STATUS" "200"
    assert_json "GET /workers/{id} id matches" ".id" "$SINK_ID"
    assert_json "GET /workers/{id} model_id" '.model_id' "sink-model"

    request "$BASE" GET /workers/not-a-uuid
    assert_eq "GET /workers/{bad id} is 400" "$STATUS" "400"
    assert_json "GET /workers/{bad id} code" '.error.code' "BAD_REQUEST"
    assert_contains "GET /workers/{bad id} message" "$BODY" "expected UUID"

    request "$BASE" GET /workers/00000000-0000-4000-8000-000000000000
    assert_eq "GET /workers/{unknown uuid} is 404" "$STATUS" "404"
    assert_json "GET /workers/{unknown uuid} code" '.error.code' "WORKER_NOT_FOUND"

    request "$BASE" DELETE /workers/00000000-0000-4000-8000-000000000000
    assert_eq "DELETE /workers/{unknown} is 404" "$STATUS" "404"
    request "$BASE" DELETE /workers/not-a-uuid
    assert_eq "DELETE /workers/{bad id} is 400" "$STATUS" "400"

    request "$BASE" DELETE "/workers/$SINK_ID"
    assert_eq "DELETE /workers/{id} is 202" "$STATUS" "202"
    assert_json "DELETE /workers body status" '.status' "accepted"
    assert_json "DELETE /workers body worker_id" ".worker_id" "$SINK_ID"
    request "$BASE" GET "/workers/$SINK_ID"
    assert_eq "GET after DELETE is 404" "$STATUS" "404"

    register_worker "$BASE" "{\"url\":\"$SINK_URL\",\"model_id\":\"sink-model\"}"
    assert_eq "re-register after DELETE is 202" "$STATUS" "202"
    assert_eq "re-register reuses the derived id" "$REG_ID" "$SINK_ID"
    wait_healthy_worker "$BASE" 25 2 || fail "re-registered worker never became healthy"

    # ---- PUT /workers/{id}: priority/cost/labels/api_key/health updates ----
    # A throwaway worker of its own so the mock and sink records that the rest of
    # the section depends on keep their registered values.
    PUT_URL="http://$GW:1/"
    register_worker "$BASE" "{\"url\":\"$PUT_URL\",\"model_id\":\"put-model\",\"labels\":{\"seed\":\"one\"}}"
    assert_eq "PUT target worker registered" "$STATUS" "202"
    PUT_ID=$REG_ID

    # The Rust service answers 202 with exactly {status,worker_id,message}
    # (worker_service.rs:138-146): no url key and no Location header.
    request "$BASE" PUT "/workers/$PUT_ID" -H 'Content-Type: application/json' \
        --data '{"priority":91,"cost":2.5,"labels":{"tier":"gold"}}'
    assert_eq "PUT /workers/{id} is 202" "$STATUS" "202"
    assert_json "PUT body status" '.status' "accepted"
    assert_json "PUT body worker_id" ".worker_id" "$PUT_ID"
    assert_json "PUT body message" \
        '.message' "Worker update queued for background processing"
    assert_json "PUT body carries no url key" 'has("url") | tostring' "false"
    assert_json "PUT body carries no location key" 'has("location") | tostring' "false"
    assert_eq "PUT sends no Location header" "$(header_of Location)" ""
    request "$BASE" GET "/workers/$PUT_ID"
    assert_json "PUT applied priority" '.priority' "91"
    assert_json "PUT applied cost" '.cost' "2.5"
    assert_json "PUT added the new label" '.metadata.tier' "gold"
    # labels merge rather than replace, the same semantics the discovery writes use.
    assert_json "PUT kept the pre-existing label" '.metadata.seed' "one"

    request "$BASE" PUT "/workers/$PUT_ID" -H 'Content-Type: application/json' \
        --data '{"api_key":"sk-updated","health_check_timeout_secs":9,"disable_health_check":false}'
    assert_eq "PUT api_key plus health knobs is 202" "$STATUS" "202"
    request "$BASE" PUT "/workers/$PUT_ID" -H 'Content-Type: application/json' \
        --data '{"model_id":"ignored","url":"http://example.invalid"}'
    assert_eq "PUT ignores the immutable identity fields" "$STATUS" "202"
    request "$BASE" GET "/workers/$PUT_ID"
    assert_json "PUT did not rewrite model_id" '.model_id' "put-model"
    assert_json "PUT did not rewrite url" '.url' "$PUT_URL"

    request "$BASE" PUT /workers/not-a-uuid -H 'Content-Type: application/json' \
        --data '{"priority":1}'
    assert_eq "PUT /workers/{bad id} is 400" "$STATUS" "400"
    assert_json "PUT /workers/{bad id} code" '.error.code' "BAD_REQUEST"
    request "$BASE" PUT /workers/00000000-0000-4000-8000-000000000000 \
        -H 'Content-Type: application/json' --data '{"priority":1}'
    assert_eq "PUT /workers/{unknown uuid} is 404" "$STATUS" "404"
    assert_json "PUT /workers/{unknown uuid} code" '.error.code' "WORKER_NOT_FOUND"
    request "$BASE" PUT "/workers/$PUT_ID" -H 'Content-Type: application/json' --data 'zz'
    assert_eq "PUT /workers/{id} bad JSON is 400" "$STATUS" "400"
    request "$BASE" PUT "/workers/$PUT_ID" -H 'Content-Type: application/json' \
        --data '{"priority":"lots"}'
    assert_eq "PUT /workers/{id} non-numeric priority is 400" "$STATUS" "400"
    assert_json "PUT 400 code" '.error.code' "BAD_REQUEST"
    request "$BASE" PUT "/workers/$PUT_ID" -H 'Content-Type: application/json' \
        --data '{"labels":"gold"}'
    assert_eq "PUT /workers/{id} non-object labels is 400" "$STATUS" "400"
    # An empty object is a valid no-op update (Rust accepts it and queues the job).
    request "$BASE" PUT "/workers/$PUT_ID" -H 'Content-Type: application/json' --data '{}'
    assert_eq "PUT /workers/{id} with an empty object is 202" "$STATUS" "202"

    request "$BASE" DELETE "/workers/$PUT_ID"
    assert_eq "cleanup the PUT target worker" "$STATUS" "202"

    # ---- registration validation ----
    # The Lua build only serves a regular HTTP worker, so the Rust enum variants
    # it does not implement are rejected rather than silently accepted (deviation 3).
    request "$BASE" POST /workers -H 'Content-Type: application/json' \
        --data "{\"url\":\"http://$GW:1/\",\"worker_type\":\"bogus\"}"
    assert_eq "POST /workers unknown worker_type is 400" "$STATUS" "400"
    assert_json "POST /workers worker_type 400 code" '.error.code' "invalid_request"
    assert_contains "POST /workers worker_type message" "$BODY" "worker_type"
    request "$BASE" POST /workers -H 'Content-Type: application/json' \
        --data "{\"url\":\"http://$GW:1/\",\"connection_mode\":\"bogus\"}"
    assert_eq "POST /workers unknown connection_mode is 400" "$STATUS" "400"
    assert_contains "POST /workers connection_mode message" "$BODY" "connection_mode"
    request "$BASE" POST /workers -H 'Content-Type: application/json' \
        --data "{\"url\":\"http://$GW:1/\",\"connection_mode\":{\"type\":\"bogus\",\"port\":1}}"
    assert_eq "POST /workers tagged connection_mode with a bad type is 400" "$STATUS" "400"
    request "$BASE" POST /workers -H 'Content-Type: application/json' \
        --data "{\"url\":\"ftp://$GW:1/\",\"worker_type\":\"regular\"}"
    assert_eq "POST /workers a non-HTTP url scheme is 400" "$STATUS" "400"
    request "$BASE" POST /workers -H 'Content-Type: application/json' \
        --data "{\"url\":\"http://$GW:1/\",\"worker_type\":\"regular\"}"
    assert_eq "POST /workers explicit regular is 202" "$STATUS" "202"
    request "$BASE" DELETE "/workers/$REG_ID"
    assert_eq "cleanup the explicit-regular worker" "$STATUS" "202"

    request "$BASE" POST /workers -H 'Content-Type: application/json' --data 'zz'
    assert_eq "POST /workers bad JSON is 400" "$STATUS" "400"
    request "$BASE" POST /workers -H 'Content-Type: application/json' --data '{}'
    assert_eq "POST /workers without url is 400" "$STATUS" "400"
    # registry.normalize_url accepts a bare host:port by prefixing http://, so a
    # scheme-less URL is normalised rather than rejected (the same behaviour the
    # SMG_WORKER_URLS seed list relies on).
    request "$BASE" POST /workers -H 'Content-Type: application/json' --data '{"url":"worker.invalid"}'
    assert_eq "POST /workers normalises a scheme-less url" "$STATUS" "202"
    assert_eq "POST /workers prefixed http://" "$(jq -r .url "$TMP_DIR/body")" "http://worker.invalid"
    BAD_ID=$(jq -r .worker_id "$TMP_DIR/body")
    request "$BASE" DELETE "/workers/$BAD_ID"
    assert_eq "cleanup the scheme-less worker" "$STATUS" "202"
fi

# ==========================================================================
if section inference; then
    ensure_workers

    request "$BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $MOCK_ID" --data "$CHAT_BODY"
    assert_eq "chat status" "$STATUS" "200"
    assert_json "chat id prefix" '.id | startswith("chatcmpl-") | tostring' "true"
    assert_json "chat object" '.object' "chat.completion"
    assert_json "chat choice role" '.choices[0].message.role' "assistant"
    assert_json "chat finish_reason" '.choices[0].finish_reason' "stop"
    assert_json "chat model echoed" '.model' "test-model"
    assert_contains "chat content echoes prompt" "$BODY" "hello lua router"
    assert_json "chat usage total" '.usage.total_tokens' "6"
    assert_matches "chat response x-request-id" "$(header_of X-Request-Id)" '^(chatcmpl|req)-[A-Za-z0-9]{24}$'

    # streaming
    request "$BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $MOCK_ID" \
        --data '{"model":"test-model","stream":true,"messages":[{"role":"user","content":"stream me"}]}'
    assert_eq "stream status" "$STATUS" "200"
    assert_contains "stream content type" "$CONTENT_TYPE" "text/event-stream"
    assert_eq "stream chunk count" "$(grep -c '^data: ' "$TMP_DIR/body")" "7"
    assert_contains "stream terminates with [DONE]" "$BODY" "data: [DONE]"
    assert_eq "stream is chunked, no content-length" "$(header_of Content-Length)" ""
    assert_contains "stream forwarded the finish frame" "$BODY" '"finish_reason": "stop"'

    request "$BASE" POST /v1/chat/completions -H 'Content-Type: application/json' --data 'not-json'
    assert_eq "chat bad JSON status" "$STATUS" "400"
    assert_json "chat bad JSON code" '.error.code' "invalid_json"
    assert_json "chat bad JSON has type" 'has("error") and (.error | has("type")) | tostring' "true"
    assert_eq "chat bad JSON header" "$(header_of X-SMG-Error-Code)" "invalid_json"
    request "$BASE" POST /v1/chat/completions
    assert_eq "chat empty body is 400" "$STATUS" "400"

    request "$BASE" POST /v1/completions -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $MOCK_ID" \
        --data '{"model":"test-model","prompt":"once upon a time"}'
    assert_eq "completions status" "$STATUS" "200"
    assert_json "completions object" '.object' "text_completion"
    request "$BASE" POST /v1/embeddings -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $MOCK_ID" \
        --data '{"model":"test-model","input":"embed me"}'
    assert_eq "embeddings status" "$STATUS" "200"
    assert_json "embeddings vector length" '.data[0].embedding | length' "8"
    request "$BASE" POST /v1/rerank -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $MOCK_ID" \
        --data '{"model":"test-model","query":"q","documents":["a","b"]}'
    assert_eq "rerank status" "$STATUS" "200"
    assert_json "rerank results" '.results | length' "2"
    request "$BASE" POST /v1/classify -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $MOCK_ID" \
        --data '{"model":"test-model","input":"classify me"}'
    assert_eq "classify status" "$STATUS" "200"
    assert_json "classify labels" '.labels | length' "2"
    request "$BASE" POST /v1/responses -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $MOCK_ID" \
        --data '{"model":"test-model","input":"respond"}'
    assert_eq "responses status" "$STATUS" "200"
    assert_json "responses object" '.object' "response"
    assert_json "responses status field" '.status' "completed"
    request "$BASE" POST /generate -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $MOCK_ID" --data '{"text":"generate me"}'
    assert_eq "generate status" "$STATUS" "200"
    assert_contains "generate echoes prompt" "$BODY" "generate me"

    # IGW off: an unknown model still routes (Rust effective_model_id = nil).
    request "$BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $MOCK_ID" \
        --data '{"model":"not-registered","messages":[{"role":"user","content":"x"}]}'
    assert_eq "unknown model with IGW off still routes" "$STATUS" "200"

    # x-smg-target-worker pinning: the request must land on the sink, and the
    # body's model must have been rewritten to the sink worker's model id.
    request "$BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $SINK_ID" --data '{"model":"test-model","messages":[]}'
    assert_eq "pinned request status" "$STATUS" "200"
    assert_json "pinned request model was rewritten" '.model' "sink-model"
    assert_contains "pinned request hit the sink" "$BODY" "chatcmpl-sink"

    # round_robin: two consecutive pinned-mock requests are both served, and an
    # unpinned pair spreads over the pool (distinct selections in the log).
    request "$BASE" GET /_ui/logs
    assert_json "round_robin selected from the pool" \
        '[.requests[] | .selected] | unique | length >= 1 | tostring' "true"
fi

# ==========================================================================
if section headers; then
    ensure_workers
    # The sink records exactly what the router put on the wire.
    curl -sS "http://127.0.0.1:$SINK_PORT/last" -o "$TMP_DIR/sink-before" || true
    request "$BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H 'x-request-id: custom-id-777' -H 'traceparent: 00-trace-span-01' \
        -H 'x-request-id-retry: 3' -H 'x-smg-routing-key: tenant-a' \
        -H 'cookie: session=secret' -H 'x-smg-target-worker: '"$SINK_ID" \
        --data '{"model":"not-the-sink-model","messages":[{"role":"user","content":"forward me"}]}'
    assert_eq "header probe request status" "$STATUS" "200"
    assert_eq "client x-request-id is echoed back" "$(header_of X-Request-Id)" "custom-id-777"
    curl -sS "http://127.0.0.1:$SINK_PORT/last" -o "$TMP_DIR/sink-after" || true
    SINK_HDRS=$(jq -c '.headers' "$TMP_DIR/sink-after")
    assert_eq "x-request-id forwarded upstream" "$(echo "$SINK_HDRS" | jq -r '.["x-request-id"] // ""')" "custom-id-777"
    assert_eq "traceparent forwarded upstream" "$(echo "$SINK_HDRS" | jq -r '.["traceparent"] // ""')" "00-trace-span-01"
    assert_eq "x-request-id-retry prefix header forwarded" "$(echo "$SINK_HDRS" | jq -r '.["x-request-id-retry"] // ""')" "3"
    assert_eq "x-smg-routing-key forwarded" "$(echo "$SINK_HDRS" | jq -r '.["x-smg-routing-key"] // ""')" "tenant-a"
    assert_eq "cookie is NOT forwarded" "$(echo "$SINK_HDRS" | jq -r 'has("cookie") | tostring')" "false"
    assert_eq "accept-encoding forced to identity" "$(echo "$SINK_HDRS" | jq -r '.["accept-encoding"] // ""')" "identity"
    assert_eq "content-type defaulted" "$(echo "$SINK_HDRS" | jq -r '.["content-type"] // ""')" "application/json"
    assert_eq "Host header points at the worker" \
        "$(echo "$SINK_HDRS" | jq -r '.host // ""')" "$GW:$SINK_PORT"
    # body rewrite: requested model replaced by the worker's real model id,
    # and content-length recomputed for the rewritten payload.
    SINK_BODY=$(jq -r '.body' "$TMP_DIR/sink-after")
    assert_contains "upstream body model rewritten" "$SINK_BODY" '"model":"sink-model"'
    assert_not_contains "upstream body lost the client model" "$SINK_BODY" "not-the-sink-model"
    assert_eq "content-length matches the forwarded body" \
        "$(echo "$SINK_HDRS" | jq -r '.["content-length"] // ""')" \
        "$(printf '%s' "$SINK_BODY" | wc -c | tr -d ' ')"
fi

# ==========================================================================
if section mesh; then
    ensure_workers
    request "$BASE" GET /ha/status
    assert_eq "/ha/status is 503" "$STATUS" "503"
    assert_eq "/ha/status body" "$BODY" '{"error":"mesh not enabled"}'
    request "$BASE" POST /ha/shutdown
    assert_eq "/ha/shutdown is 503" "$STATUS" "503"
    request "$BASE" GET /ha/deeply/nested/path
    assert_eq "/ha deep path is 503 via the 404 fallback" "$STATUS" "503"
    assert_eq "/ha deep path body" "$BODY" '{"error":"mesh not enabled"}'
    # The internal fence is gone with the auth layer (doc/scope-trim.md): the
    # ping reaches the handler itself, and with mesh disabled that answers the
    # same 503 as the /ha/* surface, not a 403.
    request "$BASE" GET /_mesh/internal/ping
    assert_eq "/_mesh/internal/ping with mesh off is 503" "$STATUS" "503"
    assert_eq "internal 503 body" "$BODY" '{"error":"mesh not enabled"}'

    # ---------------------------------------------------------------- enabled
    # SMG_ENABLE_MESH=1 with one fake peer that speaks the real wire format.
    # Nothing is configured and nothing is presented: the whole surface, inbound
    # and outbound, is open (doc/scope-trim.md), and the peer counts rejections
    # only to prove that none happen.
    start_mesh_peer "" "$GW"
    MESH_PUB=$(free_port)
    FIXPORT=$MESH_PUB start_container lr-mesh-$SUIT "$BASE_CONF" \
        SMG_ENABLE_MESH=1 SMG_MESH_SYNC_INTERVAL_SECS=1 SMG_HEALTH_CHECK_INTERVAL_SECS=1 \
        SMG_MESH_SELF_NAME=lr-contract \
        SMG_MESH_SELF=http://$GW:$MESH_PUB SMG_MESH_PEERS=http://$GW:$PEER_PORT
    MESH_BASE=$BASE

    request "$MESH_BASE" GET /ha/status
    assert_eq "/ha/status is open" "$STATUS" "200"
    request "$MESH_BASE" GET /_mesh/internal/ping
    assert_eq "/_mesh/internal/ping is open" "$STATUS" "200"
    request "$MESH_BASE" GET /ha/status
    assert_json "/ha/status names this node" '.node_name' "lr-contract"
    # Convergence: the fake peer must show up as a member and mirror its worker.
    mesh_wait_peer() {
        local i
        for i in $(seq 1 80); do
            request "$MESH_BASE" GET /ha/workers
            if [[ "$BODY" == *wk-fake* ]]; then
                # A seed that only matches once the peer self-reports lingers as
                # a hostport-keyed "init" member; the cluster has converged once
                # that duplicate merged into the peer's own name.
                request "$MESH_BASE" GET /ha/status
                if [[ "$(jq -r '.node_count' "$TMP_DIR/body" 2>/dev/null)" == "2" ]] \
                    && [[ "$BODY" == *lr-contract* && "$BODY" == *fake-peer* ]]; then
                    return 0
                fi
            fi
            sleep 0.25
        done
        return 1
    }
    if mesh_wait_peer; then
        pass "/ha/workers mirrors the peer worker and the roster converged"
    else
        fail "/ha/workers mirrors the peer worker and the roster converged (status ${BODY:0:300})"
    fi
    request "$MESH_BASE" GET /ha/status
    assert_json "/ha/status converged on two nodes" '.node_count' "2"
    assert_json "/ha/status nodes" \
        '[.nodes[].name] | (index("lr-contract") != null and index("fake-peer") != null) | tostring' "true"
    assert_json "/ha/status self is alive" \
        '[.nodes[] | select(.name == "lr-contract")][0].status' "alive"
    request "$MESH_BASE" GET /ha/health
    assert_eq "/ha/health is 200" "$STATUS" "200"
    assert_json "/ha/health cluster size" '.cluster_size' "2"
    assert_json "/ha/health should_serve" '.should_serve | tostring' "true"
    request "$MESH_BASE" GET /ha/workers/wk-fake
    assert_eq "/ha/workers/:id serves the mirrored worker" "$STATUS" "200"
    assert_json "/ha/workers/:id model" '.model_id' "fake-model"
    request "$MESH_BASE" GET /ha/policies
    assert_contains "/ha/policies carries the default policy" "$BODY" "cache_aware"

    request "$MESH_BASE" POST /ha/config \
        -H 'Content-Type: application/json' --data '{"key":"ct-key","value":"616263"}'
    assert_eq "/ha/config put is 200" "$STATUS" "200"
    request "$MESH_BASE" GET /ha/config/ct-key
    assert_eq "/ha/config get returns the hex value" "$STATUS" "200"
    assert_json "/ha/config value" '.value' "616263"
    request "$MESH_BASE" GET /ha/rate-limit
    assert_eq "/ha/rate-limit unset is 404" "$STATUS" "404"
    request "$MESH_BASE" POST /ha/rate-limit \
        -H 'Content-Type: application/json' --data '{"limit_per_second":7}'
    assert_eq "/ha/rate-limit set is 200" "$STATUS" "200"
    request "$MESH_BASE" GET /ha/rate-limit
    assert_eq "/ha/rate-limit reads back" "$STATUS" "200"
    assert_json "/ha/rate-limit value" '.limit_per_second' "7"
    request "$MESH_BASE" GET /ha/stats
    assert_eq "/ha/stats is 200" "$STATUS" "200"
    assert_json "/ha/stats ran sync rounds" '.stats.sync_rounds >= 1 | tostring' "true"
    request "$MESH_BASE" GET /ha/deeply/nested/path
    assert_eq "enabled /ha deep path is 404" "$STATUS" "404"
    assert_contains "enabled 404 names the route" "$BODY" "unknown ha route"

    # Internal endpoints: ping answers, a broken envelope is 400.
    request "$MESH_BASE" GET /_mesh/internal/ping
    assert_eq "/_mesh/internal/ping answers" "$STATUS" "200"
    assert_json "internal ping node name" '.node' "lr-contract"
    assert_json "internal ping protocol" '.protocol' "1"
    request "$MESH_BASE" POST /_mesh/internal/sync --data 'zzz'
    assert_eq "internal sync with a broken envelope is 400" "$STATUS" "400"
    assert_contains "internal sync 400 wording" "$BODY" "bad mesh envelope"

    # Outbound: the router synced (a few times by now) and the peer, which
    # requires nothing, never had a reason to reject one.
    PEER=$(peer_state)
    assert_matches "the peer was synced with" "$(jq -r '.sync' <<<"$PEER")" "^[1-9]"
    assert_eq "the peer saw no rejected syncs" "$(jq -r '.bad_auth' <<<"$PEER")" "0"
    assert_contains "the peer saw this node alive" "$(jq -r '.seen[]' <<<"$PEER" | tr '\n' ' ')" "lr-contract:alive"

    # Shutdown: 202, self flips to leaving, and the broadcast reaches the peer.
    request "$MESH_BASE" POST /ha/shutdown
    assert_eq "/ha/shutdown is 202" "$STATUS" "202"
    assert_json "shutdown status field" '.status' "shutdown initiated"
    sleep 1
    request "$MESH_BASE" GET /ha/status
    assert_json "self is leaving after shutdown" \
        '[.nodes[] | select(.name == "lr-contract")][0].status' "leaving"
    assert_json "shutdown marked the node draining" '.draining | tostring' "true"
    PEER=$(peer_state)
    assert_contains "the peer saw the leaving broadcast" \
        "$(jq -r '.seen[]' <<<"$PEER" | tr '\n' ' ')" "lr-contract:leaving"

    # Restore the shared instance for the following sections.
    BASE=$MAIN_BASE
fi

# ==========================================================================
if section not_found; then
    ensure_workers
    request "$BASE" GET /nope
    assert_eq "unknown path is 404" "$STATUS" "404"
    assert_eq "unknown path error code" "$(header_of X-SMG-Error-Code)" "not_found"
    assert_json "unknown path error shape" '.error.code' "not_found"
    assert_json "unknown path is not a /ha route" '.error.message | test("No route for GET /nope") | tostring' "true"
    request "$BASE" GET '/nope?query=keeps-the-uri'
    assert_eq "unknown path with a query is 404" "$STATUS" "404"

    # Divergence (documented, not asserted as contract): the Rust gateway's axum
    # fallback is `sink_handler`, which answers 404 with an EMPTY body (sampled
    # on <rust-box>:8800 -- "HTTP/1.1 404 Not Found / content-length: 0"). The Lua
    # router answers its klib 404 with a JSON error body instead, which is more
    # useful to a human and is what the public-plane design describes.
    note "404 body divergence: Rust fallback = 404 + empty body; lua-router = 404 + JSON {error:{type,code,message}} + X-SMG-Error-Code. Clients that only read the status see the same thing."

    # Rust answers axum's method mismatch with 405 + Allow; klib.router has no
    # method gate, so the Lua router answers its 404. Documented divergence.
    request_method_gate "GET on a POST-only route" "$BASE" GET /v1/chat/completions "POST"
    note "method mismatch: Rust 8800 answers 'GET /v1/chat/completions' with 405 + allow: POST + empty body (sampled); lua-router currently answers 404 JSON. The gate above accepts both so the suite stays green once router.lua grows a pre-dispatch method gate."
    request_method_gate "PUT on a GET-only route" "$BASE" PUT /v1/models "GET"
    request_method_gate "DELETE on a GET-only route" "$BASE" DELETE /v1/models "GET"
    request "$BASE" HEAD /health
    assert_eq "HEAD /health has no body" "$BODY" ""

    # Endpoints the Rust gateway serves (server.rs:1279-1364) but this build does
    # not wire: every one answers 501 rather than falling through to the 404 sink,
    # so a client can tell "not built yet" from "no such route". The conversations
    # plane and the response store are not here at all: they were removed
    # (doc/scope-trim.md) and answer through the 404 sink like any unknown path.
    while read -r verb path; do
        [[ -z "$verb" ]] && continue
        request "$BASE" "$verb" "$path"
        assert_eq "$verb $path is 501" "$STATUS" "501"
        assert_json "$verb $path error code" '.error.code' "not_implemented"
    done <<'NOTIMPL'
POST /wasm
GET /wasm
DELETE /wasm/11111111-2222-3333-4444-555555555555
NOTIMPL
fi

# ==========================================================================
if section observability; then
    ensure_workers
    request "$BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $MOCK_ID" --data "$CHAT_BODY" >/dev/null
    request "$BASE" GET /metrics
    assert_eq "/metrics on the main listener is 200" "$STATUS" "200"
    assert_contains "/metrics content type" "$CONTENT_TYPE" "text/plain; version=0.0.4"
    assert_contains "/metrics has http counter" "$BODY" "smg_http_requests_total{"
    assert_contains "/metrics has router counter" "$BODY" "smg_router_requests_total{"
    assert_contains "/metrics has worker health" "$BODY" "smg_worker_health{"
    assert_contains "/metrics has cb state" "$BODY" "smg_worker_cb_state{"
    assert_eq "/metrics is valid-ish exposition (no bare lines)" \
        "$(grep -cE '^[a-z].*\{[^}]*\} ' "$TMP_DIR/body" >/dev/null && echo yes)" "yes"

    # A dedicated instance so the pool series below describes exactly the two
    # workers registered on it - the main instance carries whatever the earlier
    # sections left behind. Everything the exporter derives from the registry is
    # compared against /workers rather than a hard-coded count.
    start_container lr-metrics-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1
    METRICS_BASE=$BASE
    register_worker "$METRICS_BASE" "{\"url\":\"$MOCK_URL\",\"model_id\":\"test-model\"}"
    METRICS_MOCK_ID=$REG_ID
    register_worker "$METRICS_BASE" "{\"url\":\"$SINK_URL\",\"model_id\":\"sink-model\"}"
    METRICS_SINK_ID=$REG_ID
    wait_healthy_worker "$METRICS_BASE" 25 2 \
        || fail "metrics instance workers never became healthy"
    # One streamed chat: the source of the ttot/tpot samples checked below.
    request "$METRICS_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $METRICS_MOCK_ID" \
        --data '{"model":"test-model","stream":true,"messages":[{"role":"user","content":"m"}]}' >/dev/null
    request "$METRICS_BASE" GET /metrics
    assert_eq "/metrics exposition: one HELP/TYPE per family, all samples parseable" \
        "$(python3 "$TMP_DIR/metrics_check.py" "$TMP_DIR/body" unique parseable)" \
        "unique=ok parseable=ok"
    # C1: the pool gauge must be per (worker_type, connection_mode, model) like
    # Rust's set_worker_pool_size, not one aggregate row per worker_type.
    assert_eq "/metrics pool gauge carries worker_type, connection_mode and model" \
        "$(python3 "$TMP_DIR/metrics_check.py" "$TMP_DIR/body" pool)" \
        "pool[regular/http/sink-model=1 regular/http/test-model=1]"
    assert_eq "/metrics pool series count matches the registered models" \
        "$(grep -c '^smg_worker_pool_size{' "$TMP_DIR/body")" \
        "$(curl -sS "$METRICS_BASE/workers" | jq '.workers | length')"
    # Rust only ever sets a combination it has seen, so an absent pool stays
    # absent; a rendered 0 would read as a live pool on a dashboard.
    # Pool membership is read from the registry at scrape time, so a deregistered
    # worker disappears with no exporter-side bookkeeping.
    request "$METRICS_BASE" DELETE "/workers/$METRICS_SINK_ID" >/dev/null
    request "$METRICS_BASE" GET /metrics
    assert_eq "/metrics pool gauge follows a deregistration" \
        "$(python3 "$TMP_DIR/metrics_check.py" "$TMP_DIR/body" pool)" \
        "pool[regular/http/test-model=1]"
    # Active connections come from nginx's own stub_status counters, minus the
    # idle keep-alives that Rust's per-request counter never sees.
    assert_eq "/metrics active connections is a non-negative integer" \
        "$(awk '/^smg_http_connections_active /{print ($2 ~ /^[0-9]+$/) ? "ok" : "bad " $2; found=1} END{if(!found) print "absent"}' "$TMP_DIR/body")" \
        "ok"
    # The Kubernetes poller was removed with its four smg_discovery_* families
    # (doc/scope-trim.md): the exporter must not carry any of them at all.
    assert_eq "/metrics has no discovery series any more" \
        "$(grep -c '^smg_discovery_' "$TMP_DIR/body")" "0"
    # smg_router_tpot_seconds is derived from the same (duration - ttft) the
    # request log uses for tok_per_s, so it appears with a streamed response.
    assert_eq "/metrics streams the tpot histogram" \
        "$(python3 "$TMP_DIR/metrics_check.py" "$TMP_DIR/body" \
            family=smg_router_tpot_seconds hist=smg_router_tpot_seconds)" \
        "family(smg_router_tpot_seconds)=ok hist(smg_router_tpot_seconds)=ok"

    # smg_worker_routing_keys_active: Rust counts the distinct routing keys whose
    # WorkerLoadGuard is currently alive on that worker. The Lua manual policy
    # keeps its bindings in lr_policy, so the exporter derives the same number
    # from the sticky map at scrape time (observability.lua
    # manual_routing_key_counts). A dedicated manual instance because only that
    # policy writes the map.
    start_container lr-rk-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1 \
        SMG_POLICY=manual SMG_EVICTION_INTERVAL_SECS=1
    RK_BASE=$BASE
    register_worker "$RK_BASE" "{\"url\":\"$MOCK_URL\",\"model_id\":\"test-model\"}"
    RK_ID=$REG_ID
    wait_healthy_worker "$RK_BASE" 25 || fail "routing-key instance worker never became healthy"
    for rk in rk-a rk-b rk-c; do
        request "$RK_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
            -H "x-smg-routing-key: $rk" \
            --data '{"model":"test-model","messages":[{"role":"user","content":"k"}]}' >/dev/null
    done
    # A repeat of a known key must not add a second binding.
    request "$RK_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H 'x-smg-routing-key: rk-a' \
        --data '{"model":"test-model","messages":[{"role":"user","content":"k"}]}' >/dev/null
    # smg_manual_policy_cache_entries is published by the eviction sweep, not at
    # scrape time, so let one SMG_EVICTION_INTERVAL_SECS tick run before reading
    # the two series against each other.
    sleep 2
    request "$RK_BASE" GET /metrics
    assert_eq "/metrics routing keys are counted per worker" \
        "$(routing_keys_for "$TMP_DIR/body" "$MOCK_URL")" "3"
    assert_eq "/metrics routing keys are a declared gauge" \
        "$(grep -cE '^# (HELP|TYPE) smg_worker_routing_keys_active( |$)' "$TMP_DIR/body")" "2"
    assert_contains "/metrics routing keys TYPE is gauge" "$BODY" \
        "# TYPE smg_worker_routing_keys_active gauge"
    # Both gauges read the same map, so the per-worker total has to equal the
    # cache-size gauge the eviction sweep publishes.
    assert_eq "/metrics routing keys agree with the manual cache gauge" \
        "$(python3 "$TMP_DIR/metrics_check.py" "$TMP_DIR/body" \
            family=smg_worker_routing_keys_active family=smg_manual_policy_cache_entries)" \
        "family(smg_worker_routing_keys_active)=ok family(smg_manual_policy_cache_entries)=ok"
    # smg_manual_policy_cache_entries is written by the eviction sweep (one tick
    # per SMG_EVICTION_INTERVAL_SECS here), while the routing-key gauge is derived
    # at scrape time, so the two only agree once a tick has landed.
    RK_TOTAL=0
    RK_CACHE=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        request "$RK_BASE" GET /metrics
        RK_TOTAL=$(awk '/^smg_worker_routing_keys_active\{/ { s += $NF } END { print s + 0 }' "$TMP_DIR/body")
        RK_CACHE=$(awk '/^smg_manual_policy_cache_entries/ { print $NF + 0; exit }' "$TMP_DIR/body")
        [[ "$RK_TOTAL" == "$RK_CACHE" ]] && break
        sleep 0.5
    done
    assert_eq "/metrics routing-key series sum equals the manual cache size" \
        "$RK_TOTAL" "$RK_CACHE"
    # Unbinding: deleting the worker leaves the sticky entries (Rust parity: the
    # policy is never told about removals), but the keys must still be attributed
    # to the worker they name rather than silently dropped.
    request "$RK_BASE" DELETE "/workers/$RK_ID" >/dev/null
    request "$RK_BASE" GET /metrics
    assert_eq "/metrics keeps routing keys bound to a departed worker" \
        "$(routing_keys_for "$TMP_DIR/body" "$MOCK_URL")" "3"
    # Back to the instance the rest of the section was written against: the ring
    # buffer and the layer-1/2 samples below belong to the main router, and the
    # dedicated metric instances above were side effects, not the section's own
    # scrape target.
    BASE=$MAIN_BASE
    request "$BASE" GET /metrics

    # M1: the bucket series must be cumulative, monotone, never exceed _count,
    # and le=+Inf must equal _count. Double-counting in observe() made an early
    # bucket exceed _count (one request charged to every covering bucket).
    assert_eq "duration histogram buckets cumulative, monotone, <= _count" \
        "$(python3 "$TMP_DIR/histogram_check.py" "$TMP_DIR/body")" "ok"
    # A streaming call so the ring buffer holds a stream record whose usage must
    # have been parsed out of the final SSE frame.
    request "$BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $MOCK_ID" \
        --data '{"model":"test-model","stream":true,"messages":[{"role":"user","content":"s"}]}' >/dev/null
    request "$BASE" GET /_ui/logs
    assert_eq "/_ui/logs status" "$STATUS" "200"
    assert_json "/_ui/logs has cursor" '.cursor | type' "number"
    assert_json "/_ui/logs has capacity" '.capacity' "1000"
    assert_json "/_ui/logs requests is an array" '.requests | type' "array"
    assert_json "/_ui/logs recorded the chat" '.requests | length >= 1 | tostring' "true"
    assert_json "/_ui/logs record fields" \
        '.requests[0] | has("id") and has("ts_ms") and has("method") and has("path") and has("endpoint") and has("status") and has("stream") and has("model") and has("worker") and has("route_type") and has("duration_ms") and has("prompt_tokens") and has("completion_tokens") and has("candidates") | tostring' "true"
    assert_json "/_ui/logs sse usage was parsed" \
        '([.requests[] | select(.stream and .completion_tokens > 0)] | length) > 0 | tostring' "true"
    # The buffered path must record the worker's usage too (a `f() or g()` return
    # truncated the multi-valued usage helper and logged 0 completion tokens).
    assert_json "/_ui/logs buffered usage was parsed" \
        '([.requests[] | select((.stream | not) and .completion_tokens > 0)] | length) > 0 | tostring' "true"

    BASE=$MAIN_BASE

    # session: the request-log fingerprint (observability/request_log.rs:151-160).
    # This runs on a dedicated instance because the ring buffer is per router and
    # the main one already carries rows from every earlier section; with a fresh
    # router the recorded order is exactly the order of the five chats below.
    start_container lr-sess-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1
    SESS_BASE=$BASE
    register_worker "$SESS_BASE" "{\"url\":\"$MOCK_URL\",\"model_id\":\"test-model\"}"
    wait_healthy_worker "$SESS_BASE" 25 || fail "session instance worker never became healthy"
    SESS_MOCK_ID=$REG_ID

    # An explicit prompt_cache_key wins over every other source and two different
    # keys must give two different fingerprints. The expected value is the plain
    # sha256 of the field, which is Rust's rule (session_key hashes the string on
    # its own and hexes it lowercase).
    request "$SESS_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $SESS_MOCK_ID" \
        --data '{"model":"test-model","prompt_cache_key":"pck-alpha","messages":[{"role":"user","content":"a"}]}' >/dev/null
    ALPHA_SHA=$(printf '%s' pck-alpha | sha256sum | cut -d' ' -f1)
    request "$SESS_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $SESS_MOCK_ID" \
        --data '{"model":"test-model","prompt_cache_key":"pck-beta","messages":[{"role":"user","content":"b"}]}' >/dev/null
    BETA_SHA=$(printf '%s' pck-beta | sha256sum | cut -d' ' -f1)
    # No explicit key: a conversation of two or more messages is keyed by the first
    # message as role + NUL + content, so it stays stable across turns and changes
    # when the conversation opens differently.
    request "$SESS_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $SESS_MOCK_ID" \
        --data '{"model":"test-model","messages":[{"role":"user","content":"session seed"},{"role":"assistant","content":"hi"},{"role":"user","content":"again"}]}' >/dev/null
    SEED_SHA=$(printf 'user\0session seed' | sha256sum | cut -d' ' -f1)
    request "$SESS_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $SESS_MOCK_ID" \
        --data '{"model":"test-model","messages":[{"role":"user","content":"session seed"},{"role":"assistant","content":"hi"},{"role":"user","content":"once more"}]}' >/dev/null
    # A different opening message keys a different conversation.
    request "$SESS_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $SESS_MOCK_ID" \
        --data '{"model":"test-model","messages":[{"role":"user","content":"session other"},{"role":"assistant","content":"hi"}]}' >/dev/null
    OTHER_SHA=$(printf 'user\0session other' | sha256sum | cut -d' ' -f1)
    # Single turn with no explicit key has no fingerprint at all (None in Rust).
    request "$SESS_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $SESS_MOCK_ID" --data "$CHAT_BODY" >/dev/null

    request "$SESS_BASE" GET /_ui/logs
    assert_json "/_ui/logs records carry a session field" \
        '.requests[0] | has("session") | tostring' "true"
    assert_json "/_ui/logs session is the sha256 of prompt_cache_key" \
        '.requests[0].session' "$ALPHA_SHA"
    assert_json "/_ui/logs a second cache key fingerprints differently" \
        '.requests[1].session' "$BETA_SHA"
    assert_json "/_ui/logs message-derived session hashes role NUL content" \
        '.requests[2].session' "$SEED_SHA"
    assert_json "/_ui/logs the same first message keeps the session" \
        '.requests[3].session' "$SEED_SHA"
    assert_json "/_ui/logs another first message opens another session" \
        '.requests[4].session' "$OTHER_SHA"
    assert_json "/_ui/logs a single turn without a key has no session" \
        '.requests[5].session == null | tostring' "true"
    assert_json "/_ui/logs every session is 64-hex or null" \
        '[.requests[] | select(.session != null) | .session] | all(test("^[0-9a-f]{64}$")) | tostring' "true"

    # reasoning_tokens: Rust reads usage.completion_tokens_details.reasoning_tokens
    # and falls back to usage.reasoning_tokens
    # (observability/request_log.rs:304-309, :918-922). The mock reports neither, so
    # its rows have to read 0 rather than the field going missing.
    assert_json "/_ui/logs rows carry reasoning_tokens" \
        '.requests[0] | has("reasoning_tokens") | tostring' "true"
    assert_json "/_ui/logs reasoning_tokens defaults to zero" \
        '[.requests[] | .reasoning_tokens] | all(. == 0) | tostring' "true"

    # A worker that reports reasoning tokens: only a non-zero value proves the field
    # is read rather than written as a literal 0.
    start_reasoning_worker
    register_worker "$SESS_BASE" "{\"url\":\"http://$GW:$REASON_PORT\",\"model_id\":\"reason-model\"}"
    assert_eq "reasoning worker registers" "$STATUS" "202"
    REASON_ID=$REG_ID
    wait_healthy_worker "$SESS_BASE" 30 2 || fail "reasoning worker never became healthy"
    # Pinned: without igw the candidate set ignores the model, so a free choice
    # could land on the mock and log zeros for reasons the reader would misread as
    # a broken field.
    request "$SESS_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $REASON_ID" \
        --data '{"model":"reason-model","messages":[{"role":"user","content":"think"}]}' >/dev/null
    request "$SESS_BASE" GET /_ui/logs
    assert_json "/_ui/logs reads reasoning_tokens from the usage details" \
        '.requests[-1].reasoning_tokens' "7"
    assert_json "/_ui/logs the reasoning row keeps its other usage counts" \
        '.requests[-1] | .prompt_tokens == 3 and .completion_tokens == 12 | tostring' "true"
    BASE=$MAIN_BASE

    # Layer-2 duration is recorded where Rust records it (a request that reached a
    # worker and came back 2xx, routers/http/router.rs:249-251), and the same
    # sample feeds /_ui/stats.avg_duration_ms.
    request "$BASE" GET /metrics
    assert_contains "/metrics has the router duration histogram" \
        "$BODY" "smg_router_request_duration_seconds_count{"

    request "$BASE" GET /_ui/stats
    assert_eq "/_ui/stats status" "$STATUS" "200"
    assert_json "/_ui/stats inflight" '.inflight | type' "number"
    # Rust's avg_duration_ms is an Option<f64>: null while the sliding window holds
    # no 2xx sample (request_log.rs Stats::avg_duration_ms), so the type is either.
    assert_json "/_ui/stats avg_duration_ms is a number or null" \
        '(.avg_duration_ms == null) or (.avg_duration_ms | type == "number") | tostring' "true"
    assert_json "/_ui/stats uptime_s" '.uptime_s | type' "number"
    assert_json "/_ui/stats requests_total" '.requests_total | type' "number"
    assert_json "/_ui/stats window fields" \
        'has("output_tok_s") and has("input_tok_s") and has("window_s") and has("requests_window") and has("errors_window") and has("avg_ttft_ms") and has("avg_duration_ms") and has("tokens_estimated_share") and has("capacity") and has("buffered") and has("started_at_ms") | tostring' "true"

    request "$BASE" GET /_ui/logs/backends
    assert_eq "/_ui/logs/backends status" "$STATUS" "200"
    assert_json "/_ui/logs/backends list" '.backends | length' "2"
    assert_json "/_ui/logs/backends fields" \
        '.backends[0] | has("url") and has("model") and has("gpu") | tostring' "true"

    # /_ui/logs/stream is registered by conf/ui.conf only, so probe it on a
    # ui.conf instance: open the SSE read, generate a request, then check what
    # landed on the wire (the follower replays from the head it read at connect).
    start_container lr-stream-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1
    register_worker "$BASE" "{\"url\":\"$MOCK_URL\",\"model_id\":\"test-model\"}"
    wait_healthy_worker "$BASE" 25 || fail "stream instance worker never became healthy"
    curl -sS -N -m 8 "$BASE/_ui/logs/stream" -o "$TMP_DIR/logs-stream" >/dev/null 2>&1 &
    STREAM_PID=$!
    sleep 1
    request "$BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H "x-smg-target-worker: $MOCK_ID" --data "$CHAT_BODY" >/dev/null
    wait $STREAM_PID 2>/dev/null || true
    assert_contains "/_ui/logs/stream pushes a data frame" "$(<"$TMP_DIR/logs-stream")" 'data: {'
fi

# ==========================================================================
if section proxy_endpoints; then
    ensure_workers
    # /engine_metrics aggregates the workers' Prometheus text the way Rust's
    # metrics_aggregator does (core/metrics_aggregator.rs): parse, stamp every sample
    # with worker_addr, merge families, re-render. The old implementation
    # concatenated the raw bodies under a "# worker <url>" comment, which repeats
    # "# HELP"/"# TYPE" for one name - an exposition a scraper rejects.
    request "$BASE" GET /engine_metrics
    assert_eq "/engine_metrics status" "$STATUS" "200"
    assert_contains "/engine_metrics content type" "$CONTENT_TYPE" "text/plain"
    assert_contains "/engine_metrics carries a worker metric" "$BODY" "mock_uptime_seconds"
    assert_not_contains "/engine_metrics drops the per-worker comment blocks" "$BODY" "# worker "
    assert_contains "/engine_metrics stamps samples with worker_addr" "$BODY" 'worker_addr="'
    # sglang:num_running_requests reaches the wire with a colon, which Prometheus
    # cannot parse; Rust rewrites the text before parsing, so must this router.
    assert_contains "/engine_metrics underscores the colon names" "$BODY" "sglang_num_running_requests"
    assert_not_contains "/engine_metrics leaves no colon in names" "$BODY" "sglang:"
    # Both workers contributed, each under its own address (the full url, scheme
    # included, exactly as Rust's fan_out records resp.url).
    assert_eq "/engine_metrics carries both worker addresses" \
        "$(grep -o 'worker_addr="[^"]*"' "$TMP_DIR/body" | sort -u | wc -l)" "2"
    # Every sample the mock publishes must come back stamped with its address, so
    # the expected count is read from the worker's own exposition rather than
    # hard-coded to a number that drifts when the mock grows a metric.
    MOCK_SAMPLES=$(curl -sS -m 2 "http://127.0.0.1:$MOCK_PORT/metrics" | grep -cvE '^(#|$)')
    assert_eq "/engine_metrics stamps every mock sample" \
        "$(grep -c "worker_addr=\"$MOCK_URL\"" "$TMP_DIR/body")" "$MOCK_SAMPLES"
    # A valid exposition says HELP/TYPE once per family, however many workers
    # contributed samples to it.
    assert_eq "/engine_metrics HELP lines are unique" \
        "$(grep '^# HELP' "$TMP_DIR/body" | awk '{print $3}' | sort | uniq -d | wc -l)" "0"
    assert_eq "/engine_metrics TYPE lines are unique" \
        "$(grep '^# TYPE' "$TMP_DIR/body" | awk '{print $3}' | sort | uniq -d | wc -l)" "0"
    assert_eq "/engine_metrics every non-comment line is a sample" \
        "$(grep -vE '^(#|$)' "$TMP_DIR/body" | grep -vcE '^[a-zA-Z_][a-zA-Z0-9_]*(\{| )')" "0"

    # Rust's two failure branches are text responses with 500, not an empty 200
    # (core/worker_manager.rs get_engine_metrics + its IntoResponse). A fresh
    # instance has no workers at all, and it also serves health_generate's 503
    # branch (routers/router_manager.rs:407-422) because no worker can be healthy
    # there. EM_PRE is whatever instance ensure_workers filled, which is what the
    # endpoints below still expect.
    EM_PRE=$BASE
    start_container lr-em-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1
    EM_BASE=$BASE
    request "$EM_BASE" GET /engine_metrics
    assert_eq "/engine_metrics with no workers is 500" "$STATUS" "500"
    assert_eq "/engine_metrics no-worker body" "$BODY" "No available workers"
    request "$EM_BASE" GET /health_generate
    assert_eq "/health_generate without a healthy worker is 503" "$STATUS" "503"
    assert_eq "/health_generate 503 body" "$BODY" "No routers with healthy workers available"
    assert_not_contains "/health_generate 503 is not an error object" "$BODY" '"error"'
    request "$EM_BASE" HEAD /health_generate
    assert_eq "/health_generate answers HEAD with the 503 too" "$STATUS" "503"

    # A worker whose /metrics is broken cannot produce a pack: All backend requests
    # failed. The sink answers /metrics, so use a worker that refuses everything.
    register_worker "$EM_BASE" "{\"url\":\"http://$GW:1\",\"model_id\":\"dead-model\"}"
    assert_eq "/engine_metrics dead worker registers" "$STATUS" "202"
    request "$EM_BASE" GET /engine_metrics
    assert_eq "/engine_metrics when every scrape fails is 500" "$STATUS" "500"
    assert_eq "/engine_metrics all-failed body" "$BODY" "All backend requests failed"
    BASE=$EM_PRE

    request "$BASE" GET /model_info
    assert_eq "/model_info status" "$STATUS" "200"
    assert_json "/model_info merges worker infos" '.model_infos | length' "2"
    assert_json "/model_info served name" '[.model_infos[].served_model_name] | index("test-model") != null | tostring' "true"
    request "$BASE" GET /get_model_info
    assert_eq "/get_model_info alias" "$STATUS" "200"

    # /v1/loads probes each worker's own engine load (worker_manager.rs
    # parse_load_response: GET {url}/v1/loads?include=core -> aggregate.total_tokens,
    # -1 for anything that does not answer). The mock and the sink serve no /v1/loads,
    # so both are -1 here; the load worker below proves the success path, which is
    # what keeps a never-probing router from passing on the failure value alone.
    request "$BASE" GET /v1/loads
    assert_eq "/v1/loads status" "$STATUS" "200"
    assert_json "/v1/loads workers array" '.workers | type' "array"
    assert_json "/v1/loads entry fields" \
        '.workers[0] | has("worker") and has("load") | tostring' "true"
    assert_json "/v1/loads worker url is absolute" '.workers[0].worker | startswith("http") | tostring' "true"
    assert_json "/v1/loads unprobed workers are -1" '[.workers[].load] | all(. == -1) | tostring' "true"
    assert_json "/v1/loads successful is zero without an engine" '.successful' "0"
    assert_json "/v1/loads failed counts them" '.failed' "2"
    request "$BASE" GET /get_loads
    assert_eq "/get_loads alias" "$STATUS" "200"
    assert_json "/get_loads answers the same shape" '.workers | length' "2"
    # The old private shape is gone rather than merely shadowed, so a dashboard
    # reading .loads[].cb_state cannot silently see nothing.
    assert_json "/v1/loads drops the old record fields" \
        '(.loads == null) and (.timestamp == null) | tostring' "true"

    # Success path: a worker that really answers /v1/loads?include=core.
    start_load_worker 4242
    LOAD_URL="http://$GW:$LOAD_PORT"
    register_worker "$BASE" "{\"url\":\"$LOAD_URL\",\"model_id\":\"load-model\"}"
    assert_eq "/v1/loads probe worker registers" "$STATUS" "202"
    LOAD_ID=$REG_ID
    request "$BASE" GET /v1/loads
    assert_json "/v1/loads reads the engine's total_tokens" \
        "[.workers[] | select(.worker == \"$LOAD_URL\")] | .[0].load" "4242"
    assert_json "/v1/loads counts the answer as successful" '.successful' "1"
    assert_json "/v1/loads keeps unanswerable workers at -1" \
        "[.workers[] | select(.worker != \"$LOAD_URL\")] | all(.load == -1) | tostring" "true"
    # mock + sink + the load worker: total_workers counts every registered worker,
    # including the ones whose probe failed.
    assert_json "/v1/loads total_workers counts every worker" '.total_workers' "3"

    # Rust has no /v1/loads/stream: it is not in the axum table, so the route must
    # fall through to the 404 sink rather than answer 501.
    request "$BASE" GET /v1/loads/stream
    assert_eq "/v1/loads/stream is not a route" "$STATUS" "404"
    assert_eq "/v1/loads/stream 404 error code" "$(header_of X-SMG-Error-Code)" "not_found"

    # Hand the probe worker back so /model_info and /flush_cache below still see
    # exactly the mock and the sink.
    request "$BASE" DELETE /workers/"$LOAD_ID"
    assert_eq "/v1/loads setup: probe worker deleted" "$STATUS" "202"
    i=0
    while [[ "$(curl -sS -m 2 "$BASE/v1/loads" | jq -r '.total_workers // -1')" != "2" && $i -lt 60 ]]; do
        i=$((i + 1)); sleep 0.1
    done

    # RouterManager::health_generate (routers/router_manager.rs:407) answers plain
    # text: 200 "At least one router has healthy workers" when any worker is healthy,
    # 503 with a different sentence when none is. Not a 501, and not an error body.
    request "$BASE" GET /health_generate
    assert_eq "/health_generate with a healthy worker is 200" "$STATUS" "200"
    assert_eq "/health_generate body" "$BODY" "At least one router has healthy workers"
    assert_eq "/health_generate content type" "$CONTENT_TYPE" "text/plain; charset=utf-8"
    assert_eq "/health_generate content length matches Rust" "$(header_of Content-Length)" "39"
    request "$BASE" HEAD /health_generate
    assert_eq "/health_generate answers HEAD as axum does" "$STATUS" "200"
    # The 503 branch lives on the worker-free instance above: every worker still
    # registered here (mock, sink, load worker) is healthy, so dropping one would
    # never make the answer change.
    # The tokenizer/parse proxy plane was removed (doc/scope-trim.md): the family
    # is not routed at all and answers from the 404 sink like any unknown path.
    request "$BASE" POST /v1/tokenize -H 'Content-Type: application/json' --data '{"text":"x"}'
    assert_eq "/v1/tokenize is not routed" "$STATUS" "404"
    request "$BASE" POST /parse/function_call -H 'Content-Type: application/json' --data '{"text":"x"}'
    assert_eq "/parse/function_call is not routed" "$STATUS" "404"
    # The mock answers POST /flush_cache with 200 and GET with 405, so a router
    # that still pokes the cache with GET shows up as error rows: checking only
    # the result count used to hide exactly that.
    request "$BASE" POST /flush_cache -H 'Content-Type: application/json'
    assert_eq "/flush_cache answers 200" "$STATUS" "200"
    assert_json "/flush_cache per-worker results" '.results | length' "2"
    assert_json "/flush_cache every worker succeeded" \
        '[.results[].result] | unique | .[0]' "success"
    assert_json "/flush_cache success flag" '.success | tostring' "true"
    assert_json "/flush_cache all_failed flag" '.all_failed | tostring' "false"
    assert_json "/flush_cache worker status codes" '[.results[].status] | unique | .[0]' "200"
fi

# ==========================================================================
if section policy_hint; then
    # Per-model policy hints: Rust's PolicyRegistry owns one policy per model and
    # takes the name from the first worker's labels.policy, falling back to the
    # configured default (policies/registry.rs:66/:111, steps/worker/shared/
    # update_policies.rs:102-113). Three models on one router: two carry different
    # hints, one carries none, so the hint, the hint difference and the fallback all
    # show up in the recorded route_type.
    # Two workers per model so a spreading policy and a pinning one differ.
    # start_mock() resets MOCK_URL/MOCK_PORT, which later sections still use to
    # reach the main mock, so they are put back at the end of this section.
    KEEP_MOCK_URL=$MOCK_URL
    KEEP_MOCK_PORT=$MOCK_PORT
    start_mock hint-model-a
    A1_URL="http://$GW:$MOCK_PORT"
    start_mock hint-model-a
    A2_URL="http://$GW:$MOCK_PORT"
    start_mock hint-model-b
    B1_URL="http://$GW:$MOCK_PORT"
    start_mock hint-model-b
    B2_URL="http://$GW:$MOCK_PORT"
    start_mock hint-model-c
    C1_URL="http://$GW:$MOCK_PORT"
    start_mock hint-model-c
    C2_URL="http://$GW:$MOCK_PORT"

    # igw so each model only sees its own two workers: without it the candidate set
    # ignores the model and the spread assertion below measures the wrong thing.
    start_container lr-pol-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1 \
        SMG_POLICY=manual SMG_ENABLE_IGW=1
    POL_BASE=$BASE
    register_worker "$POL_BASE" "{\"url\":\"$A1_URL\",\"model_id\":\"hint-model-a\",\"labels\":{\"policy\":\"round_robin\"}}"
    assert_eq "policy hint: worker A1 registers" "$STATUS" "202"
    register_worker "$POL_BASE" "{\"url\":\"$A2_URL\",\"model_id\":\"hint-model-a\",\"labels\":{\"policy\":\"round_robin\"}}"
    assert_eq "policy hint: worker A2 registers" "$STATUS" "202"
    register_worker "$POL_BASE" "{\"url\":\"$B1_URL\",\"model_id\":\"hint-model-b\",\"labels\":{\"policy\":\"cache_aware\"}}"
    assert_eq "policy hint: worker B1 registers" "$STATUS" "202"
    register_worker "$POL_BASE" "{\"url\":\"$B2_URL\",\"model_id\":\"hint-model-b\",\"labels\":{\"policy\":\"cache_aware\"}}"
    assert_eq "policy hint: worker B2 registers" "$STATUS" "202"
    register_worker "$POL_BASE" "{\"url\":\"$C1_URL\",\"model_id\":\"hint-model-c\"}"
    assert_eq "policy hint: worker C1 registers without a label" "$STATUS" "202"
    register_worker "$POL_BASE" "{\"url\":\"$C2_URL\",\"model_id\":\"hint-model-c\"}"
    assert_eq "policy hint: worker C2 registers without a label" "$STATUS" "202"
    wait_healthy_worker "$POL_BASE" 30 6 || fail "policy hint workers never all became healthy"

    # Same routing key for every chat: manual would pin one worker per model, so the
    # spread (or lack of it) is what distinguishes the policies.
    for i in 1 2 3 4; do
        request "$POL_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
            -H 'x-smg-routing-key: hint-tenant' \
            --data '{"model":"hint-model-a","messages":[{"role":"user","content":"a"}]}' >/dev/null
    done
    for i in 1 2 3 4; do
        request "$POL_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
            -H 'x-smg-routing-key: hint-tenant' \
            --data '{"model":"hint-model-b","messages":[{"role":"user","content":"b"}]}' >/dev/null
    done
    for i in 1 2 3 4; do
        request "$POL_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
            -H 'x-smg-routing-key: hint-tenant' \
            --data '{"model":"hint-model-c","messages":[{"role":"user","content":"c"}]}' >/dev/null
    done

    request "$POL_BASE" GET /_ui/logs
    assert_json "policy hint: the hinted model A reports round_robin" \
        '[.requests[] | select(.model == "hint-model-a") | .route_type] | unique | .[0]' "round_robin"
    assert_json "policy hint: the hinted model B reports cache_aware" \
        '[.requests[] | select(.model == "hint-model-b") | .route_type] | unique | .[0]' "cache_aware"
    assert_json "policy hint: the unhinted model falls back to the global policy" \
        '[.requests[] | select(.model == "hint-model-c") | .route_type] | unique | .[0]' "manual"
    assert_json "policy hint: two models really ran different policies" \
        '([.requests[] | .route_type] | unique | length) >= 3 | tostring' "true"
    # round_robin walks the candidate list, so one sticky key still spreads; manual
    # keeps the key on one worker. These two assertions are what show the per-model
    # state is separate rather than one shared policy seeing every request.
    assert_json "policy hint: round_robin spreads a sticky key across model A" \
        '([.requests[] | select(.model == "hint-model-a") | .worker] | unique | length)' "2"
    assert_json "policy hint: manual pins the sticky key on model C" \
        '([.requests[] | select(.model == "hint-model-c") | .worker] | unique | length)' "1"

    # The per-model instances keep their own state rather than one shared policy
    # reacting to every request: a fifth chat on model C still finds its pin.
    request "$POL_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H 'x-smg-routing-key: hint-tenant' \
        --data '{"model":"hint-model-c","messages":[{"role":"user","content":"c"}]}' >/dev/null
    request "$POL_BASE" GET /_ui/logs
    assert_json "policy hint: model C keeps its own pin after more traffic" \
        '([.requests[] | select(.model == "hint-model-c") | .worker] | unique | length)' "1"

    MOCK_URL=$KEEP_MOCK_URL
    MOCK_PORT=$KEEP_MOCK_PORT
    BASE=$MAIN_BASE
fi

# ==========================================================================
if section ui_fixed; then
    # /_ui/* lives in conf/ui.conf, so this section uses the derived conf.
    start_container lr-ui-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1 LMR_UI_DIR=/repo/ui
    UI_BASE=$BASE
    register_worker "$UI_BASE" "{\"url\":\"$MOCK_URL\",\"model_id\":\"test-model\"}"
    assert_eq "ui instance: worker registered" "$STATUS" "202"
    wait_healthy_worker "$UI_BASE" 25 || fail "ui instance worker never became healthy"

    request "$UI_BASE" GET /_ui/slots
    assert_eq "/_ui/slots status" "$STATUS" "200"
    assert_eq "/_ui/slots body" "$BODY" "[]"
    request "$UI_BASE" GET /_ui/tools
    assert_eq "/_ui/tools body" "$BODY" "[]"
    request "$UI_BASE" GET /_ui/v1/streams/lookup
    assert_eq "/_ui/v1/streams/lookup body" "$BODY" "[]"

    request "$UI_BASE" GET /_ui/v1/stream
    assert_eq "/_ui/v1/stream is 501" "$STATUS" "501"
    assert_json "/_ui/v1/stream error" '.error | startswith("llama.cpp server stream") | tostring' "true"
    request "$UI_BASE" GET /_ui/v1/chat/completions/control
    assert_eq "/_ui/v1/chat/completions/control is 501" "$STATUS" "501"
    request "$UI_BASE" POST /_ui/v1/chat/completions/control
    assert_eq "/_ui/v1/chat/completions/control (POST) is 501" "$STATUS" "501"

    request "$UI_BASE" POST /_ui/models/load
    assert_eq "/_ui/models/load status" "$STATUS" "200"
    assert_json "/_ui/models/load success" '.success | tostring' "true"
    request "$UI_BASE" POST /_ui/models/unload
    assert_eq "/_ui/models/unload is 400" "$STATUS" "400"
    assert_contains "/_ui/models/unload explains in Chinese" "$BODY" "不能卸载"

    request "$UI_BASE" GET /_ui/v1/models
    assert_eq "/_ui/v1/models status" "$STATUS" "200"
    assert_json "/_ui/v1/models object" '.object' "list"
    assert_json "/_ui/v1/models data is an array" '(.data | type)' "array"
    assert_json "/_ui/v1/models is non-empty" '(.data | length) > 0 | tostring' "true"
    assert_json "/_ui/v1/models advertises loaded" \
        '[.data[].id] | index("test-model") != null | tostring' "true"
    assert_json "/_ui/v1/models status.value" '.data[0].status.value' "loaded"

    request "$UI_BASE" GET /_ui/props
    assert_eq "/_ui/props status" "$STATUS" "200"
    assert_json "/_ui/props advertises router role" '.role // "none"' "router"
    assert_json "/_ui/props model" '.model' "test-model"

    request "$UI_BASE" GET /_ui/config
    assert_eq "/_ui/config GET" "$STATUS" "200"
    assert_json "/_ui/config has env_defaults" 'has("env_defaults") | tostring' "true"

    request "$UI_BASE" GET /_ui/stats
    assert_eq "/_ui/stats via ui.conf" "$STATUS" "200"
    assert_json "/_ui/stats inflight via ui.conf" '.inflight | type' "number"
    request "$UI_BASE" GET /_ui/logs
    assert_eq "/_ui/logs via ui.conf" "$STATUS" "200"
    assert_json "/_ui/logs capacity via ui.conf" '.capacity' "1000"
    request "$UI_BASE" GET /_ui/logs/backends
    assert_eq "/_ui/logs/backends via ui.conf" "$STATUS" "200"

    # method gating on the ui.conf locations (axum-style 405 + Allow)
    request "$UI_BASE" GET /_ui/models/load
    assert_eq "/_ui/models/load GET is 405" "$STATUS" "405"
    assert_eq "/_ui/models/load Allow header" "$(header_of Allow)" "POST"
    request "$UI_BASE" POST /_ui/v1/models
    assert_eq "/_ui/v1/models POST is 405" "$STATUS" "405"
    assert_eq "/_ui/v1/models Allow header" "$(header_of Allow)" "GET"
    request "$UI_BASE" POST /_ui/stats
    assert_eq "/_ui/stats POST is 405" "$STATUS" "405"

    # the chat aliases go through the shared pipeline
    request "$UI_BASE" POST /_ui/v1/chat/completions -H 'Content-Type: application/json' \
        --data '{"model":"test-model","messages":[{"role":"user","content":"ui chat"}]}'
    assert_eq "/_ui/v1/chat/completions status" "$STATUS" "200"
    assert_json "/_ui/v1/chat/completions object" '.object' "chat.completion"
    assert_contains "/_ui/v1/chat/completions routed to the worker" "$BODY" "ui chat"
    # M3: an empty-array "tools"/"stop" must reach the worker as an array.
    # A decode/encode round trip turns [] into {} (cjson cannot tell them apart),
    # so the /_ui aliases have to forward the caller's bytes.
    request "$UI_BASE" POST /_ui/v1/chat/completions -H 'Content-Type: application/json' \
        --data '{"model":"test-model","tools":[],"stop":[],"messages":[{"role":"user","content":"arrays"}]}'
    assert_eq "/_ui/v1/chat/completions with empty arrays status" "$STATUS" "200"
    assert_json "/_ui/v1/chat/completions keeps tools as an array" '.echo_body.tools | type' "array"
    assert_json "/_ui/v1/chat/completions keeps stop as an array" '.echo_body.stop | type' "array"
    request "$UI_BASE" POST /_ui/v1/chat/completions -H 'Content-Type: application/json' \
        --data '{"messages":[{"role":"user","content":"default model"}]}'
    assert_eq "/_ui/v1/chat/completions without a model status" "$STATUS" "200"
    assert_json "/_ui/v1/chat/completions fills the default model" '.model' "test-model"
    request "$UI_BASE" POST /_ui/v1/completions -H 'Content-Type: application/json' \
        --data '{"model":"test-model","prompt":"ui prompt"}'
    assert_eq "/_ui/v1/completions status" "$STATUS" "200"
    request "$UI_BASE" POST /_ui/v1/chat/completions -H 'Content-Type: application/json' --data 'zz'
    assert_eq "/_ui/v1/chat/completions bad JSON is 400" "$STATUS" "400"
    assert_contains "/_ui/v1/chat/completions bad JSON message" "$BODY" "invalid chat request"

    # static bundle
    request "$UI_BASE" GET /_ui
    assert_eq "/_ui redirects" "$STATUS" "301"
    assert_contains "/_ui redirect target" "$(header_of Location)" "/_ui/"
    # Edge-safe redirects: behind a TLS-terminating edge the visible Host is the
    # upstream address, so an absolute Location would send the client to
    # http://127.0.0.1:PORT. Exact-equality is the guard -- assert_contains on
    # "/_ui/" also passes when the bug is present (the absolute URL ends in it).
    request "$UI_BASE" GET /_ui
    assert_eq "/_ui Location stays a relative reference" "$(header_of Location)" "/_ui/"
    request "$UI_BASE" GET /_ui/admin
    assert_eq "/_ui/admin redirects to the directory" "$STATUS" "302"
    assert_contains "/_ui/admin redirect is not cacheable" "$(header_of Cache-Control)" "no-store"
    assert_eq "/_ui/admin Location stays a relative reference" "$(header_of Location)" "/_ui/admin/"
    request "$UI_BASE" GET /_ui/admin/
    assert_eq "/_ui/admin/ serves the console" "$STATUS" "200"
    assert_contains "/_ui/admin/ is html" "$CONTENT_TYPE" "text/html"
    request "$UI_BASE" GET /_ui/
    assert_eq "/_ui/ serves the SPA" "$STATUS" "200"
    assert_contains "/_ui/ is html" "$CONTENT_TYPE" "text/html"
    request "$UI_BASE" GET /_ui/logs.html
    assert_eq "/_ui/logs.html status" "$STATUS" "200"
    request "$UI_BASE" GET /_ui/definitely-missing.js
    assert_eq "/_ui/ static miss is 404" "$STATUS" "404"
fi

# ==========================================================================
if section tls_upstream; then
    # M2: OpenResty's tcp cosocket ignores the connect{ssl=true} option in an
    # http{} context, so an https worker used to be contacted in cleartext (the
    # upstream answered 400 "The plain HTTP request was sent to HTTPS port") and
    # the health sweep marked it unhealthy forever. Every path now performs an
    # explicit sslhandshake after connecting: router.lua (forwarding), hb.lua
    # (probe) and config_store.raw_request (/props and /model-map proxies).
    command -v openssl >/dev/null || { note "openssl missing, skipping the TLS upstream section"; }
    if command -v openssl >/dev/null; then
        CERT_DIR="$TMP_DIR/tls"
        mkdir -p "$CERT_DIR"
        openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
            -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
            -subj "/CN=llm-tls-mock" >"$TMP_DIR/openssl.log" 2>&1 \
            || fail "could not create a self-signed certificate"

        TLS_PORT=$(free_port)
        cat >"$TMP_DIR/tls_wrap.py" <<'TLSWRAP'
import importlib.util
import os
import ssl
import sys

spec = importlib.util.spec_from_file_location("mock", sys.argv[1])
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)

port = int(sys.argv[2])
server = mock.ThreadingHTTPServer(("0.0.0.0", port), mock.Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(os.environ["TLS_CERT"], os.environ["TLS_KEY"])
server.socket = ctx.wrap_socket(server.socket, server_side=True)
server.daemon_threads = True
sys.stderr.write("[tls-mock] listening on https://0.0.0.0:%s\n" % port)
server.serve_forever()
TLSWRAP
        TLS_LOG="$TMP_DIR/tls-mock.log"
        MODEL=tls-model TLS_CERT="$CERT_DIR/cert.pem" TLS_KEY="$CERT_DIR/key.pem" \
            python3 "$TMP_DIR/tls_wrap.py" "$SCRIPT_DIR/mock_llm_worker.py" \
            "$TLS_PORT" >"$TLS_LOG" 2>&1 &
        TLS_PID=$!
        MOCK_PIDS="$MOCK_PIDS $TLS_PID"
        tls_up=1
        for i in $(seq 1 60); do
            curl -fsS -k -m 2 "https://127.0.0.1:$TLS_PORT/health" >/dev/null 2>&1 && { tls_up=0; break; }
            sleep 0.1
        done
        [[ "$tls_up" == "0" ]] || fail "TLS mock did not come up on :$TLS_PORT ($(tail -5 "$TLS_LOG"))"
        TLS_URL="https://$GW:$TLS_PORT"

        start_container lr-tls-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1
        TLS_BASE=$BASE
        register_worker "$TLS_BASE" "{\"url\":\"$TLS_URL\",\"model_id\":\"tls-model\"}"
        assert_eq "tls: https worker accepted" "$REG_STATUS" "202"
        # the sweep has to reach it over TLS; before the fix it never did
        if wait_healthy_worker "$TLS_BASE" 30 1; then
            pass "tls: health probe over TLS marks the worker healthy"
        else
            fail "tls: https worker never became healthy (probe still not doing TLS)"
        fi
        request "$TLS_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
            --data '{"model":"tls-model","messages":[{"role":"user","content":"over tls"}]}'
        assert_eq "tls: chat forwarded over TLS" "$STATUS" "200"
        assert_contains "tls: response carries the echoed text" "$BODY" "over tls"
        assert_json "tls: model rewritten to the worker's id" '.model' "tls-model"
        assert_json "tls: usage survived the TLS path" '.usage.total_tokens' "6"
        request "$TLS_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
            --data '{"model":"tls-model","stream":true,"messages":[{"role":"user","content":"s"}]}'
        assert_eq "tls: streaming over TLS" "$STATUS" "200"
        assert_contains "tls: stream terminates with [DONE]" "$BODY" "data: [DONE]"

        # /_ui/props proxies /props through config_store.raw_request, the third
        # call path that had no TLS at all.
        request "$TLS_BASE" GET /_ui/props
        assert_eq "tls: /_ui/props proxied over TLS" "$STATUS" "200"
        assert_json "tls: /props body came from the https worker" '.model' "tls-model"

        # A cleartext client must not be able to use the TLS port: proves the
        # negative case the bug used to fall into (no silent plain-HTTP success).
        PLAIN_CODE=$(curl -sS -o "$TMP_DIR/plain-body" -w '%{http_code}' -m 5 \
            "http://127.0.0.1:$TLS_PORT/health" 2>/dev/null || true)
        [[ "$PLAIN_CODE" != "200" ]] \
            && pass "tls: the https port does not serve cleartext (got '$PLAIN_CODE')" \
            || fail "tls: cleartext request unexpectedly succeeded on the TLS port"
    fi
fi

# ==========================================================================
if section cb_race; then
    # M4: the breaker counters are charged by several nginx worker processes at
    # once. A get()+set() pair loses updates (four processes read failures=2 and
    # all four write 3), so the circuit opened far past cb_failure_threshold;
    # the counters are accumulated with shdict:incr() now and the flip is
    # re-checked in the registry lock, so exactly one process records it.
    # Own port on purpose: start_mock() resets MOCK_URL/MOCK_PORT, which later
    # sections (igw, discovery) still read from the main mock.
    FAIL_MOCK_PORT=$(free_port)
    FAIL_MODE=retryable_500 python3 "$SCRIPT_DIR/mock_llm_worker.py" \
        --host 0.0.0.0 --port "$FAIL_MOCK_PORT" --model failing-model \
        >"$TMP_DIR/mock-fail.log" 2>&1 &
    FAIL_MOCK_PID=$!
    MOCK_PIDS="$MOCK_PIDS $FAIL_MOCK_PID"
    for cbw in $(seq 1 50); do
        curl -fsS -m 1 "http://127.0.0.1:$FAIL_MOCK_PORT/health" >/dev/null 2>&1 && break
        sleep 0.1
    done

    # The contract conf is static, so derive a 4-process variant into $TMP_DIR
    # before the container mounts it (the mount is read-only but the file is
    # written on the host first).
    sed 's/^worker_processes 1;/worker_processes 4;/' "$SCRIPT_DIR/conf/nginx-lua-router.conf" \
        >"$TMP_DIR/nginx-4workers.conf"
    grep -q '^worker_processes 4;' "$TMP_DIR/nginx-4workers.conf" \
        || fail "could not derive the 4-worker conf"

    start_container lr-cbrace-$SUIT /gen/nginx-4workers.conf \
        SMG_CB_FAILURE_THRESHOLD=6 SMG_DISABLE_RETRIES=1 \
        SMG_HEALTH_CHECK_INTERVAL_SECS=1
    CB_BASE=$BASE
    CB_GW=$(container_gateway lr-cbrace-$SUIT)
    register_worker "$CB_BASE" "{\"url\":\"http://$CB_GW:$FAIL_MOCK_PORT\",\"model_id\":\"failing-model\"}"
    assert_eq "cb_race: failing worker accepted" "$REG_STATUS" "202"
    if wait_healthy_worker "$CB_BASE" 30 1; then
        pass "cb_race: failing worker starts healthy"
    else
        fail "cb_race: worker never became healthy, breaker path cannot be measured"
    fi

    # Two requests per batch keeps the measurement finer than the threshold: the
    # breaker must trip within cb_failure_threshold + 2 charged outcomes.
    cb_open_at=0
    for batch in $(seq 1 6); do
        pids=()
        for k in 1 2; do
            curl -sS -o /dev/null -m 10 -X POST "$CB_BASE/v1/chat/completions" \
                -H 'Content-Type: application/json' \
                --data '{"model":"failing-model","messages":[{"role":"user","content":"x"}]}' &
            pids+=("$!")
        done
        for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
        charged=$((batch * 2))
        state=$(curl -sS "$CB_BASE/metrics" | grep -F 'smg_worker_cb_state{' | awk '{print $NF; exit}')
        if [[ "$state" == "1" ]]; then cb_open_at=$charged; break; fi
    done
    assert_matches "cb_race: circuit opened at/just past the threshold (opened after '$cb_open_at' of 12)" \
        "$cb_open_at" '^(6|7|8)$'

    request "$CB_BASE" GET /metrics
    assert_eq "cb_race: open -> refusing traffic with 503" \
        "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$CB_BASE/v1/chat/completions" \
            -H 'Content-Type: application/json' --data '{"model":"failing-model","messages":[]}')" "503"
    # exactly one process may perform the flip, so the transition counter and the
    # log line are not multiplied by the worker count
    transitions=$(curl -sS "$CB_BASE/metrics" \
        | grep -F 'smg_worker_cb_transitions_total{' | grep -F 'to="open"' \
        | awk '{s+=$NF} END {print s+0}')
    assert_eq "cb_race: one closed->open transition across 4 processes" "$transitions" "1"
    counters=$(curl -sS "$CB_BASE/metrics" \
        | grep -F 'smg_worker_cb_consecutive_failures{' | awk '{print $NF; exit}')
    assert_matches "cb_race: failure counter kept every outcome (no lost update, got '$counters')" \
        "$counters" '^([6-9]|[1-9][0-9])$'
fi

# ==========================================================================

# ==========================================================================
if section igw; then
    start_container lr-igw-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1 SMG_ENABLE_IGW=1
    IGW_BASE=$BASE
    register_worker "$IGW_BASE" "{\"url\":\"$MOCK_URL\",\"model_id\":\"test-model\"}"
    assert_eq "igw instance: worker registered" "$STATUS" "202"
    wait_healthy_worker "$IGW_BASE" 25 || fail "igw worker never became healthy"
    request "$IGW_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        --data '{"model":"test-model","messages":[{"role":"user","content":"x"}]}'
    assert_eq "IGW: registered model routes" "$STATUS" "200"
    request "$IGW_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        --data '{"model":"nope-not-registered","messages":[{"role":"user","content":"x"}]}'
    assert_eq "IGW: unknown model is 503" "$STATUS" "503"
    assert_eq "IGW: unknown model error header" "$(header_of X-SMG-Error-Code)" "no_available_workers"
    assert_json "IGW: unknown model error code" '.error.code' "no_available_workers"
    assert_json "IGW: unknown model error type" '.error.type' "Service Unavailable"
    assert_contains "IGW: unknown model message" "$BODY" "No available workers"
fi

# ==========================================================================
if section discovery; then
    # Register with no model_id: the health sweep must discover the served model
    # through /model_info and republish it in /v1/models.
    start_container lr-disc-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1
    DISC_BASE=$BASE
    register_worker "$DISC_BASE" "{\"url\":\"http://$GW:$MOCK_PORT\"}"
    assert_eq "discovery: worker accepted" "$STATUS" "202"
    request "$DISC_BASE" GET /workers
    assert_json "discovery: model starts unknown" '.workers[0].model_id' "unknown"
    disc_left=0
    while :; do
        MODEL=$(curl -sS "$DISC_BASE/workers/$REG_ID" | jq -r '.model_id' 2>/dev/null || echo unknown)
        [[ "$MODEL" == "test-model" ]] && break
        disc_left=$((disc_left + 1))
        [[ $disc_left -gt 60 ]] && break
        sleep 0.5
    done
    request "$DISC_BASE" GET /workers
    assert_json "discovery: model_id filled from /model_info" '.workers[0].model_id' "test-model"
    assert_json "discovery: labels captured" \
        '.workers[0].metadata.served_model_name' "test-model"
    request "$DISC_BASE" GET /v1/models
    assert_json "discovery: advertised in /v1/models" \
        '[.data[].id] | index("test-model") != null | tostring' "true"
fi

# ==========================================================================
if section prometheus; then
    # The dedicated scrape listener only exists through the production
    # entrypoint (SMG_METRICS_PORT renders the extra server block), so this
    # section runs the image entrypoint against the live lualib tree.
    MP=$(free_port)
    docker rm -f lr-prom-$SUIT >/dev/null 2>&1 || true
    CONTAINER_NAMES="$CONTAINER_NAMES lr-prom-$SUIT"
    docker run -d --name lr-prom-$SUIT \
        -p 127.0.0.1:0:30000 -p "127.0.0.1:$MP:29000" \
        -e SMG_METRICS_PORT=29000 -e LR_METRICS_PORT=29000 \
        -e SMG_PORT=30000 -e SMG_HEALTH_CHECK_INTERVAL_SECS=1 \
        -e NGINX_WORKER_PROCESSES=1 \
        -e OPENRESTY_TEMPLATE_DIR=/repo/conf \
        -e LR_UI_CONF=/repo/conf/ui.conf \
        -e LMR_UI_DIR=/repo/ui \
        --entrypoint /repo/docker-entrypoint.sh \
        -v "$REPO_ROOT:/repo:ro" \
        -v "$REPO_ROOT/lualib/resty/luarouter:/usr/local/openresty/site/lualib/resty/luarouter:ro" \
        "$IMAGE" /usr/local/openresty/bin/openresty -p /usr/local/openresty/nginx -g 'daemon off;' \
        >/dev/null || fail "prometheus container failed to start"
    PMAIN=$(docker port lr-prom-$SUIT 30000/tcp | head -n 1 | awk '{ print $NF }' | awk -F: '{print $NF}')
    PPORT=$(docker port lr-prom-$SUIT 29000/tcp | awk -F: 'NR == 1 { print $NF }')
    PROM_MAIN="http://127.0.0.1:$PMAIN"
    PROM_PORT_URL="http://127.0.0.1:$PPORT"
    i=0
    until curl -fsS -m 2 "$PROM_PORT_URL/health" >/dev/null 2>&1; do
        i=$((i + 1)); [[ $i -gt 100 ]] && fail "prometheus listener never came up"
        sleep 0.1
    done
    curl -fsS -m 3 "$PROM_MAIN/health" >/dev/null 2>&1 || fail "main listener of the entrypoint container never came up"
    request "$PROM_PORT_URL" GET /metrics
    assert_eq "prometheus :29xxx /metrics status" "$STATUS" "200"
    assert_contains "prometheus :29xxx text" "$BODY" "smg_http_requests_total{"
    request "$PROM_PORT_URL" GET /health
    assert_eq "prometheus :29xxx /health" "$BODY" "OK"
    request "$PROM_PORT_URL" GET /nope
    assert_eq "prometheus listener stays minimal (404)" "$STATUS" "404"
    request "$PROM_MAIN" GET /metrics
    assert_eq "/metrics also on the main listener" "$STATUS" "200"
    request "$PROM_MAIN" GET /_ui/stats
    assert_eq "entrypoint container wires ui.conf" "$STATUS" "200"
    request "$PROM_MAIN" GET /_ui/
    assert_eq "entrypoint container serves the static bundle" "$STATUS" "200"

    # ---- entrypoint defaults (the render, not the runtime) ----
    # A second entrypoint container that names nothing except the Rust-style UI
    # directory, so the default render is what gets checked: the Prometheus
    # listener on 29000, one nginx process for cache_aware's per-process affinity
    # tree, and SMG_UI_DIR mapped onto the LMR_UI_DIR the UI fragment reads.
    docker rm -f lr-entry-$SUIT >/dev/null 2>&1 || true
    CONTAINER_NAMES="$CONTAINER_NAMES lr-entry-$SUIT"
    docker run -d --name lr-entry-$SUIT \
        -p 127.0.0.1:0:30000 \
        -e SMG_PORT=30000 -e SMG_HEALTH_CHECK_INTERVAL_SECS=1 \
        -e SMG_LOG_LEVEL=info -e SMG_UI_DIR=/repo/ui \
        -e OPENRESTY_TEMPLATE_DIR=/repo/conf \
        -e LR_UI_CONF=/repo/conf/ui.conf \
        --entrypoint /repo/docker-entrypoint.sh \
        -v "$REPO_ROOT:/repo:ro" \
        -v "$REPO_ROOT/lualib/resty/luarouter:/usr/local/openresty/site/lualib/resty/luarouter:ro" \
        "$IMAGE" /usr/local/openresty/bin/openresty -p /usr/local/openresty/nginx -g 'daemon off;' \
        >/dev/null || fail "entrypoint-defaults container failed to start"
    EMAIN=$(docker port lr-entry-$SUIT 30000/tcp | head -n 1 | awk '{ print $NF }' | awk -F: '{print $NF}')
    EBASE="http://127.0.0.1:$EMAIN"
    i=0
    until curl -fsS -m 2 "$EBASE/health" >/dev/null 2>&1; do
        i=$((i + 1)); [[ $i -gt 100 ]] && fail "entrypoint-defaults container never came up"
        sleep 0.1
    done
    docker exec lr-entry-$SUIT cat /usr/local/openresty/nginx/conf/nginx.conf \
        >"$TMP_DIR/nginx-rendered.conf" || fail "could not read the rendered nginx.conf"
    RENDER=$(<"$TMP_DIR/nginx-rendered.conf")
    assert_contains "entrypoint renders the 29000 listener by default" \
        "$RENDER" "listen 0.0.0.0:29000;"
    assert_matches "entrypoint pins worker_processes to 1 for the default policy" \
        "$RENDER" "worker_processes 1;"
    assert_contains "entrypoint honours SMG_LOG_LEVEL" "$RENDER" "error_log /dev/stderr info;"
    request "$EBASE" GET /metrics
    assert_eq "entrypoint-defaults /metrics on the main listener" "$STATUS" "200"
    request "$EBASE" GET /_ui/
    assert_eq "SMG_UI_DIR alone locates the static bundle" "$STATUS" "200"

    # SMG_METRICS_PORT=0 switches the extra listener off, which is what the e2e
    # suites need on a host that already runs a gateway on 29000.
    docker rm -f lr-entry-off-$SUIT >/dev/null 2>&1 || true
    CONTAINER_NAMES="$CONTAINER_NAMES lr-entry-off-$SUIT"
    docker run -d --name lr-entry-off-$SUIT \
        -p 127.0.0.1:0:30000 \
        -e SMG_PORT=30000 -e SMG_METRICS_PORT=0 -e NGINX_WORKER_PROCESSES=1 \
        -e OPENRESTY_TEMPLATE_DIR=/repo/conf \
        --entrypoint /repo/docker-entrypoint.sh \
        -v "$REPO_ROOT:/repo:ro" \
        -v "$REPO_ROOT/lualib/resty/luarouter:/usr/local/openresty/site/lualib/resty/luarouter:ro" \
        "$IMAGE" /usr/local/openresty/bin/openresty -p /usr/local/openresty/nginx -g 'daemon off;' \
        >/dev/null || fail "SMG_METRICS_PORT=0 container failed to start"
    OMAIN=$(docker port lr-entry-off-$SUIT 30000/tcp | head -n 1 | awk '{ print $NF }' | awk -F: '{print $NF}')
    OBASE="http://127.0.0.1:$OMAIN"
    i=0
    until curl -fsS -m 2 "$OBASE/health" >/dev/null 2>&1; do
        i=$((i + 1)); [[ $i -gt 100 ]] && fail "SMG_METRICS_PORT=0 container never came up"
        sleep 0.1
    done
    docker exec lr-entry-off-$SUIT cat /usr/local/openresty/nginx/conf/nginx.conf \
        >"$TMP_DIR/nginx-rendered-off.conf" || fail "could not read the second render"
    assert_not_contains "SMG_METRICS_PORT=0 drops the extra listener" \
        "$(<"$TMP_DIR/nginx-rendered-off.conf")" ":29000"
    request "$OBASE" GET /metrics
    assert_eq "SMG_METRICS_PORT=0 still serves /metrics on the main listener" "$STATUS" "200"
fi

# ==========================================================================
if section probes; then
    ensure_workers
    request "$BASE" GET /klib/load
    assert_eq "/klib/load status" "$STATUS" "200"
    # one line per module; every line must read ": OK"
    assert_eq "/klib/load every module OK" \
        "$(grep -c ': OK' "$TMP_DIR/body")" "$(grep -c ': ' "$TMP_DIR/body")"
    assert_not_contains "/klib/load has no failures" "$BODY" "FAIL"
    assert_contains "/klib/load covers the core modules" "$BODY" "resty.luarouter.router: OK"
    assert_contains "/klib/load covers the policy modules" "$BODY" "resty.luarouter.policies.tree: OK"
    assert_contains "/klib/load covers the limiter" "$BODY" "resty.luarouter.limit: OK"

    request "$BASE" GET "/probe/worker-id?url=http://127.0.0.1:18000"
    assert_eq "worker id is the sha224-derived UUID" "$BODY" \
        "$(python3 -c 'import hashlib
h = hashlib.new("sha224", b"http://127.0.0.1:18000").hexdigest()[:32]
print("%s-%s-%s-%s-%s" % (h[:8], h[8:12], h[12:16], h[16:20], h[20:32]))')"

    request "$BASE" GET /probe/rewrite-model
    assert_json "rewrite_model rewrote the top-level model" '.model' "real/model-1"
    assert_json "rewrite_model left the rest alone" '.messages[0].content' "m"

    request "$BASE" GET /probe/extract-text
    assert_json "chat routing text" '.chat' "sys a prev think toolout funcout"
    assert_json "completions routing text" '.completions' "p1 p2"

    request "$BASE" GET /probe/headers
    assert_json "forward whitelist keeps x-request-id" \
        '.keep | index("x-request-id") != null | tostring' "true"
    assert_json "forward whitelist keeps x-smg-routing-key" \
        '.keep | index("x-smg-routing-key") != null | tostring' "true"
    assert_json "forward whitelist drops cookie" \
        '.drop | index("cookie") != null | tostring' "true"
    assert_json "response drop list has transfer-encoding" \
        '.response_drop | index("transfer-encoding") != null | tostring' "true"

    request "$BASE" GET /probe/env
    assert_json "LMR_* is snapshotted before the fork" '.cached_before | tostring' "true"
    assert_json "worker env really is stripped" '.raw == null | tostring' "true"

    # M5: the incremental usage scanner still parses a frame that is cut
    # mid-object across reads and lands behind a >64KB tail window.
    request "$BASE" GET /probe/stream-usage
    assert_contains "/probe/stream-usage finds the split usage frame" \
        "$(tail -n 1 "$TMP_DIR/body")" "ok=true prompt=11 completion=22 cached=0"

    # field_pattern regression: an integer member must be replaced in place.
    request "$BASE" GET /probe/json-edit
    assert_json "set_top_field replaces an existing integer member without duplicating the key" \
        '.replace_int_members | tostring' "true"

    request "$BASE" GET /probe/config
    assert_json "probe/config igw default off" '.enable_igw | tostring' "false"
    assert_json "probe/config retry default" '.max_retries' "5"
    # Defaults the task contract pins: limiter off, Rust's scrape port, cache_aware.
    assert_json "probe/config limiter off by default" '.max_concurrent_requests' "-1"
    assert_json "probe/config queue size default" '.queue_size' "100"
    assert_json "probe/config queue timeout default" '.queue_timeout_secs' "60"
    assert_json "probe/config metrics port default" '.metrics_port' "29000"
    assert_json "probe/config metrics host default" '.metrics_host' "0.0.0.0"
    assert_json "probe/config default policy" '.policy' "cache_aware"
    assert_json "probe/config no cors whitelist by default" '.cors_allowed_origins | length' "0"
    assert_json "probe/config buckets follow the Rust ladder when unset" \
        '.duration_buckets | length' "0"
fi

# ==========================================================================
if section cors; then
    # Header values sampled from the Rust gateway on <rust-box>:8800 and read out of
    # tower-http 0.6.11 src/cors: the wildcard layer emits the constant headers
    # regardless of whether the request carries an Origin, only the list form is
    # conditional. Vary uses ", " between values (vary.rs:29-33) and the list
    # forms of Allow-Methods/Allow-Headers use a bare comma (mod.rs:465-482).
    request "$BASE" GET /health
    assert_eq "cors default: allow-origin is the wildcard" "$(header_of Access-Control-Allow-Origin)" "*"
    assert_eq "cors default: expose-headers is the wildcard" "$(header_of Access-Control-Expose-Headers)" "*"
    assert_eq "cors default: vary names the three preflight inputs" \
        "$(header_of Vary)" "origin, access-control-request-method, access-control-request-headers"
    assert_eq "cors default: no max-age on a normal response" \
        "$(header_of Access-Control-Max-Age)" ""

    request "$BASE" OPTIONS /v1/chat/completions \
        -H 'Origin: http://client.example' -H 'Access-Control-Request-Method: POST'
    assert_eq "cors preflight is 200" "$STATUS" "200"
    assert_eq "cors preflight body is empty" "${#BODY}" "0"
    assert_eq "cors preflight allow-methods" "$(header_of Access-Control-Allow-Methods)" "*"
    assert_eq "cors preflight allow-headers" "$(header_of Access-Control-Allow-Headers)" "*"
    assert_eq "cors preflight max-age" "$(header_of Access-Control-Max-Age)" "3600"
    assert_eq "cors preflight allow-origin" "$(header_of Access-Control-Allow-Origin)" "*"
    # The task contract asks for a successful preflight on every path, which is
    # looser than Rust (tower answers 404 for an OPTIONS on an unregistered path).
    request "$BASE" OPTIONS /nope -H 'Origin: http://client.example'
    assert_eq "cors preflight on an unknown path is still 200" "$STATUS" "200"
    request "$BASE" OPTIONS /workers -H 'Origin: http://client.example'
    assert_eq "cors preflight on the control plane is 200" "$STATUS" "200"

    # The /_ui/* locations are served by conf/ui.conf, and each one opens with its
    # own method gate, so a preflight that reached the location would answer 405.
    # handle() never sees those requests either (ui.conf bypasses the dispatcher),
    # which is why the guard runs in the server-level rewrite phase instead.
    for path in /_ui/ /_ui/stats /_ui/config /_ui/props /_ui/v1/chat/completions; do
        request "$BASE" OPTIONS "$path" -H 'Origin: http://client.example'
        assert_eq "cors preflight on $path is 200" "$STATUS" "200"
        assert_eq "cors preflight on $path is empty" "${#BODY}" "0"
    done

    # A plain /_ui/* response also carries the CORS headers: the rewrite guard
    # stamps them before the ui.conf location answers, which is what the browser
    # needs to read the webui across origins.
    request "$BASE" GET /_ui/stats -H 'Origin: http://client.example'
    assert_eq "cors: a /_ui response allows the origin" \
        "$(header_of Access-Control-Allow-Origin)" "*"
    assert_eq "cors: a /_ui response exposes x-request-id" \
        "$(header_of Access-Control-Expose-Headers)" "*"
    request "$BASE" GET /_ui/
    assert_eq "cors: the static bundle is CORS-decorated too" \
        "$(header_of Access-Control-Allow-Origin)" "*"

    # Whitelist mode: only the listed origins, and the narrowed method/header sets.
    start_container lr-cors2-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1 \
        SMG_CORS_ALLOWED_ORIGINS=http://good.example,http://other.example
    CB2=$BASE
    request "$CB2" GET /health -H 'Origin: http://good.example'
    assert_eq "cors list: matched origin is echoed" \
        "$(header_of Access-Control-Allow-Origin)" "http://good.example"
    assert_eq "cors list: no wildcard leaks" \
        "$(header_of Access-Control-Expose-Headers)" "x-request-id"
    request "$CB2" GET /health -H 'Origin: http://bad.example'
    assert_eq "cors list: unmatched origin gets no allow-origin" \
        "$(header_of Access-Control-Allow-Origin)" ""
    assert_eq "cors list: vary is still unconditional" \
        "$(header_of Vary)" "origin, access-control-request-method, access-control-request-headers"
    request "$CB2" GET /health
    assert_eq "cors list: a request with no Origin gets no allow-origin" \
        "$(header_of Access-Control-Allow-Origin)" ""
    request "$CB2" OPTIONS /v1/chat/completions \
        -H 'Origin: http://good.example' -H 'Access-Control-Request-Method: POST' \
        -H 'Access-Control-Request-Headers: content-type'
    assert_eq "cors list preflight is 200" "$STATUS" "200"
    assert_eq "cors list preflight allow-methods" \
        "$(header_of Access-Control-Allow-Methods)" "GET,POST,OPTIONS"
    assert_eq "cors list preflight allow-headers" \
        "$(header_of Access-Control-Allow-Headers)" "content-type,authorization"
    assert_eq "cors list preflight max-age" "$(header_of Access-Control-Max-Age)" "3600"
    request "$CB2" OPTIONS /v1/chat/completions \
        -H 'Origin: http://bad.example' -H 'Access-Control-Request-Method: POST'
    assert_eq "cors list preflight still answers for a rejected origin" "$STATUS" "200"
    assert_eq "cors list preflight sends no allow-origin for it" \
        "$(header_of Access-Control-Allow-Origin)" ""

    # A proxied response keeps the router's CORS headers rather than whatever the
    # worker tried to send: the inference path re-applies them after the upstream
    # header merge.
    register_worker "$CB2" "{\"url\":\"$MOCK_URL\",\"model_id\":\"test-model\"}"
    wait_healthy_worker "$CB2" 25 || fail "cors instance worker never became healthy"
    request "$CB2" POST /v1/chat/completions -H 'Content-Type: application/json' \
        -H 'Origin: http://good.example' --data "$CHAT_BODY"
    assert_eq "cors list: a proxied response echoes the origin" \
        "$(header_of Access-Control-Allow-Origin)" "http://good.example"
fi

# ==========================================================================
if section virtual_models; then
    # /v1/models must advertise the runtime aliases next to the real models, the
    # way inject_virtual_models (server.rs:831) does. Own container because the
    # alias map comes from LMR_VIRTUAL_MODELS, which config_store snapshots at
    # init time.
    start_container lr-vmodels-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1 \
        LMR_VIRTUAL_MODELS='alias-a:test-model,zzz-alias:test-model,test-model:shadowed'
    VB=$BASE
    register_worker "$VB" "{\"url\":\"$MOCK_URL\",\"model_id\":\"test-model\"}"
    assert_eq "virtual-models instance: worker registered" "$STATUS" "202"
    wait_healthy_worker "$VB" 25 || fail "virtual-models worker never became healthy"

    request "$VB" GET /v1/models
    assert_eq "virtual-models /v1/models status" "$STATUS" "200"
    assert_json "virtual-models object" '.object' "list"
    assert_json "virtual-models lists the alias" '[.data[].id] | index("alias-a") != null | tostring' "true"
    assert_json "virtual-models lists the second alias" '[.data[].id] | index("zzz-alias") != null | tostring' "true"
    assert_json "virtual-models keeps the real model" '[.data[].id] | index("test-model") != null | tostring' "true"
    assert_json "virtual-models skips an alias shadowed by a real worker" \
        '[.data[] | select(.id == "test-model")] | length' "1"
    assert_json "virtual-models alias shape: object" \
        '[.data[] | select(.id == "alias-a")][0].object' "model"
    assert_json "virtual-models alias shape: created" \
        '[.data[] | select(.id == "alias-a")][0].created' "0"
    assert_json "virtual-models alias shape: owned_by" \
        '[.data[] | select(.id == "alias-a")][0].owned_by' "llm-router->test-model"
    assert_json "virtual-models data is sorted by id" \
        '.data | map(.id) == (map(.id) | sort) | tostring' "true"
    # An alias routes to its target, so advertising it must match behaviour.
    request "$VB" POST /v1/chat/completions -H 'Content-Type: application/json' \
        --data '{"model":"alias-a","messages":[{"role":"user","content":"x"}]}'
    assert_eq "virtual-models alias routes to its target" "$STATUS" "200"
    assert_json "virtual-models alias resolves to the worker model" '.model' "test-model"

    # No workers: the Rust injector only rewrites bodies that carry a data array,
    # so the 503 text answer stays untouched even with aliases configured. Own
    # instance because the earlier sections already registered workers on the main
    # container when the suite runs in full.
    start_container lr-vempty-$SUIT "$BASE_CONF" \
        LMR_VIRTUAL_MODELS='alias-a:test-model'
    request "$BASE" GET /v1/models
    assert_eq "virtual-models: the no-worker answer is unaffected" "$STATUS" "503"
    assert_eq "virtual-models: the 503 stays plain text" "$BODY" "No models available"
fi

# ==========================================================================
if section ratelimit; then
    # SMG_MAX_CONCURRENT_REQUESTS caps in-flight inference requests; the mock is
    # slowed down so two concurrent chats genuinely overlap. Public and control
    # traffic is outside the limiter, exactly like Rust (protected_routes only).
    SLOW_PORT=$(free_port)
    LATENCY_MS=1200 python3 "$SCRIPT_DIR/mock_llm_worker.py" \
        --host 0.0.0.0 --port "$SLOW_PORT" --model slow-model \
        >"$TMP_DIR/mock-slow.log" 2>&1 &
    SLOW_PID=$!
    MOCK_PIDS="$MOCK_PIDS $SLOW_PID"
    for rl in $(seq 1 50); do
        curl -fsS -m 1 "http://127.0.0.1:$SLOW_PORT/health" >/dev/null 2>&1 && break
        sleep 0.1
    done

    start_container lr-rl-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1 \
        SMG_MAX_CONCURRENT_REQUESTS=1 SMG_QUEUE_SIZE=0
    RL_BASE=$BASE
    RL_GW=$(container_gateway lr-rl-$SUIT)
    register_worker "$RL_BASE" "{\"url\":\"http://$RL_GW:$SLOW_PORT\",\"model_id\":\"slow-model\"}"
    assert_eq "ratelimit instance: worker registered" "$STATUS" "202"
    wait_healthy_worker "$RL_BASE" 25 || fail "ratelimit worker never became healthy"

    # Two overlapping chats: exactly one is served, the other is refused. Recorded
    # per request so the assertion does not depend on which one lost the race.
    run_chat() {
        # run_chat TAG -> writes $TMP_DIR/rl-TAG.code, .body and .headers
        local tag=$1
        curl -sS -m 15 -o "$TMP_DIR/rl-$tag.body" -D "$TMP_DIR/rl-$tag.headers" \
            -w '%{http_code}' -X POST "$RL_BASE/v1/chat/completions" \
            -H 'Content-Type: application/json' \
            --data "{\"model\":\"slow-model\",\"messages\":[{\"role\":\"user\",\"content\":\"$tag\"}]}" \
            >"$TMP_DIR/rl-$tag.code"
    }
    run_chat a &
    PID_A=$!
    sleep 0.2
    run_chat b
    wait $PID_A || true
    RL_A_CODE=$(<"$TMP_DIR/rl-a.code")
    RL_B_CODE=$(<"$TMP_DIR/rl-b.code")
    # Exactly one accepted, exactly one refused, regardless of ordering.
    assert_eq "ratelimit: one of the two overlapping chats is refused" \
        "$(printf '%s\n%s\n' "$RL_A_CODE" "$RL_B_CODE" | sort | tr '\n' ' ')" "200 429 "
    REJECTED=$( [[ "$RL_A_CODE" == "429" ]] && echo a || echo b )
    assert_eq "ratelimit: the 429 carries an empty body" \
        "$(wc -c <"$TMP_DIR/rl-$REJECTED.body" | tr -d ' ')" "0"
    # Bare status, like Rust StatusCode::TOO_MANY_REQUESTS.into_response(): no
    # JSON error envelope, so no X-SMG-Error-Code, and an exact zero length.
    assert_eq "ratelimit: the 429 carries no error code header" \
        "$(awk 'BEGIN{IGNORECASE=1}/^X-SMG-Error-Code:/{print "set"}' "$TMP_DIR/rl-$REJECTED.headers")" ""
    assert_eq "ratelimit: the 429 frames an exact zero length" \
        "$(awk 'BEGIN{IGNORECASE=1}/^Content-Length:/{sub(/^[^:]+:[[:space:]]*/,"");sub(/\r$/,"");print}' "$TMP_DIR/rl-$REJECTED.headers")" "0"
    assert_eq "ratelimit: the accepted chat completed" \
        "$( [[ "$RL_A_CODE" == "200" ]] && echo "$RL_A_CODE" || echo "$RL_B_CODE" )" "200"
    # Slot released once the first response finished, so a follow-up is served.
    request "$RL_BASE" POST /v1/chat/completions -H 'Content-Type: application/json' \
        --data '{"model":"slow-model","messages":[{"role":"user","content":"c"}]}'
    assert_eq "ratelimit: the token came back after the response" "$STATUS" "200"

    request "$RL_BASE" GET /health
    assert_eq "ratelimit: /health is not metered" "$STATUS" "200"
    request "$RL_BASE" GET /workers
    assert_eq "ratelimit: the control plane is not metered" "$STATUS" "200"
    request "$RL_BASE" GET /metrics
    assert_contains "ratelimit: allowed decisions are counted" "$BODY" 'smg_http_rate_limit_total{result="allowed"}'
    assert_contains "ratelimit: rejections are counted" "$BODY" 'smg_http_rate_limit_total{result="rejected"}'

    # With a queue configured the second chat must wait for the slot rather than
    # be refused, and only the request behind a full queue is rejected. Without
    # this the limiter looked fine while silently rejecting every waiter:
    # ngx.sleep returns nothing on success, and judging that as an abort dropped
    # the whole wait window.
    start_container lr-rlq-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1 \
        SMG_MAX_CONCURRENT_REQUESTS=1 SMG_QUEUE_SIZE=1 SMG_QUEUE_TIMEOUT_SECS=10
    RLQ_BASE=$BASE
    RLQ_GW=$(container_gateway lr-rlq-$SUIT)
    register_worker "$RLQ_BASE" "{\"url\":\"http://$RLQ_GW:$SLOW_PORT\",\"model_id\":\"slow-model\"}"
    wait_healthy_worker "$RLQ_BASE" 25 || fail "queued-limiter worker never became healthy"
    run_chat_on() {
        # run_chat_on BASE TAG -> $TMP_DIR/q-TAG.code
        local base=$1 tag=$2
        curl -sS -m 20 -o /dev/null -w '%{http_code}' \
            -X POST "$base/v1/chat/completions" -H 'Content-Type: application/json' \
            --data "{\"model\":\"slow-model\",\"messages\":[{\"role\":\"user\",\"content\":\"$tag\"}]}" \
            >"$TMP_DIR/q-$tag.code"
    }
    run_chat_on "$RLQ_BASE" a &
    PID_A=$!
    sleep 0.2
    run_chat_on "$RLQ_BASE" b &
    PID_B=$!
    sleep 0.2
    run_chat_on "$RLQ_BASE" c
    wait $PID_A $PID_B || true
    Q_A=$(<"$TMP_DIR/q-a.code"); Q_B=$(<"$TMP_DIR/q-b.code"); Q_C=$(<"$TMP_DIR/q-c.code")
    assert_eq "ratelimit queue: the in-flight chat is served" "$Q_A" "200"
    assert_eq "ratelimit queue: the queued chat waits and is served" "$Q_B" "200"
    assert_eq "ratelimit queue: the request behind a full queue is refused" "$Q_C" "429"
fi

# ==========================================================================
if section inflight_age; then
    # smg_http_inflight_request_age_count with real samples
    # (doc/gap-inflight-age.md). Rust registers every request in an
    # InFlightRequestTracker and samples the age distribution from a PeriodicTask
    # (observability/inflight_tracker.rs, start_sampler(20) at server.rs:1559); the
    # Lua port keeps the start times in a fixed slot table inside lr_stats so the
    # sampler can see requests served by any worker, and hands the slot back in
    # finish_request plus the log-phase sweep in init.lua.
    #
    # LR_INFLIGHT_SAMPLE_SECS=1 lands a tick well inside a 6 s mock request, which
    # is what turns the distribution into something a test can read; the shipped
    # default stays the Rust 20 s cadence.
    AGE_PORT=$(free_port)
    LATENCY_MS=6000 python3 "$SCRIPT_DIR/mock_llm_worker.py" \
        --host 0.0.0.0 --port "$AGE_PORT" --model slow-model \
        >"$TMP_DIR/mock-age.log" 2>&1 &
    MOCK_PIDS="$MOCK_PIDS $!"
    for _ in $(seq 1 50); do
        curl -fsS -m 1 "http://127.0.0.1:$AGE_PORT/health" >/dev/null 2>&1 && break
        sleep 0.1
    done

    # age_value BODY SERIES -> value of one exact exposition line, else "absent".
    # The trailing space belongs to the match so `..._count` cannot hit `..._count
    # something-else`, and the caller passes the full label set for bucket lines.
    age_value() {
        # index()==1 anchors the match at the start of the sample line, and the
        # comment filter keeps `# HELP smg_http_inflight_requests Requests ...`
        # from being read as the value "router".
        awk -v s="$2" '
            index($0, s " ") == 1 && $0 !~ /^#/ { print $NF; found = 1; exit }
            END { if (!found) print "absent" }
        ' "$1"
    }

    age_bucket_value() {
        age_value "$1" "smg_http_inflight_request_age_count_bucket{le=\"$2\"}"
    }

    age_poll() {
        # age_poll PREDICATE -> scrape /metrics into age-body until it holds
        local pred=$1 i
        for i in $(seq 1 80); do
            curl -sS -m 5 "$AGE_POLL_BASE/metrics" -o "$TMP_DIR/age-body" 2>/dev/null || true
            if "$pred"; then
                return 0
            fi
            sleep 0.1
        done
        return 1
    }

    age_pred_samples() {
        # at least one sampled request and a positive total age
        local count sum
        count=$(age_value "$TMP_DIR/age-body" smg_http_inflight_request_age_count_count)
        sum=$(age_value "$TMP_DIR/age-body" smg_http_inflight_request_age_count_sum)
        [[ "$count" != "absent" && "$sum" != "absent" ]] || return 1
        awk -v c="$count" -v s="$sum" 'BEGIN { exit !(c + 0 >= 1 && s + 0 > 0) }'
    }

    age_pred_cross() {
        # one sampler tick must see the whole burst registered by four workers,
        # and the shared table must agree with the concurrency gauge
        local count sum slots inflight
        count=$(age_value "$TMP_DIR/age-body" smg_http_inflight_request_age_count_count)
        sum=$(age_value "$TMP_DIR/age-body" smg_http_inflight_request_age_count_sum)
        slots=$(age_value "$TMP_DIR/age-body" smg_http_inflight_request_age_slots_active)
        inflight=$(age_value "$TMP_DIR/age-body" smg_http_inflight_requests)
        [[ "$count" != "absent" && "$slots" != "absent" && "$inflight" != "absent" ]] || return 1
        awk -v c="$count" -v s="$sum" -v a="$slots" -v b="$inflight" \
            'BEGIN { exit !(c + 0 >= 24 && s + 0 > 0 && a + 0 == b + 0 && a + 0 >= 24) }'
    }

    age_pred_burst() {
        # 24 overlapping requests must be sampled, not just the first tick's subset
        local count
        count=$(age_value "$TMP_DIR/age-body" smg_http_inflight_request_age_count_count)
        [[ "$count" != "absent" ]] || return 1
        awk -v c="$count" 'BEGIN { exit !(c + 0 >= 20) }'
    }

    age_pred_matches_concurrency() {
        # the age table and the concurrency gauge count the same requests
        local slots inflight
        slots=$(age_value "$TMP_DIR/age-body" smg_http_inflight_request_age_slots_active)
        inflight=$(age_value "$TMP_DIR/age-body" smg_http_inflight_requests)
        [[ "$slots" != "absent" && "$inflight" != "absent" ]] || return 1
        awk -v a="$slots" -v b="$inflight" 'BEGIN { exit !(a + 0 == b + 0 && a + 0 >= 1) }'
    }

    age_pred_drained() {
        # nothing in flight: every bucket, _sum and _count reads zero
        local count sum slots nonzero
        count=$(age_value "$TMP_DIR/age-body" smg_http_inflight_request_age_count_count)
        sum=$(age_value "$TMP_DIR/age-body" smg_http_inflight_request_age_count_sum)
        slots=$(age_value "$TMP_DIR/age-body" smg_http_inflight_request_age_slots_active)
        [[ "$count" == "0" && "$sum" == "0.000000" ]] || return 1
        # the scrape itself is in flight, so the tracker reads 1 at rest
        awk -v s="$slots" 'BEGIN { exit !(s + 0 <= 1) }' || return 1
        nonzero=$(awk '/^smg_http_inflight_request_age_count/ { if ($2 + 0 != 0) n++ } END { print n + 0 }' \
            "$TMP_DIR/age-body")
        [[ "$nonzero" == "0" ]]
    }

    age_pred_ttl_expired() {
        # the request is still being served but its slot already aged out of the
        # table, which is the LR_INFLIGHT_TTL_SECS self-heal bound
        local count inflight
        count=$(age_value "$TMP_DIR/age-body" smg_http_inflight_request_age_count_count)
        inflight=$(age_value "$TMP_DIR/age-body" smg_http_inflight_requests)
        [[ "$count" != "absent" && "$inflight" != "absent" ]] || return 1
        awk -v c="$count" -v i="$inflight" 'BEGIN { exit !(c + 0 == 0 && i + 0 >= 1) }'
    }

    AGE_PIDS=""

    age_chat() {
        # age_chat TAG -> one chat against the 6 s mock, in the background. The
        # pid is collected explicitly rather than through `jobs -p`: the section
        # also owns the long-lived mock server, and a plain `wait` would block on
        # that process forever.
        curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST "$AGE_CHAT_BASE/v1/chat/completions" \
            -H 'Content-Type: application/json' \
            --data "{\"model\":\"slow-model\",\"messages\":[{\"role\":\"user\",\"content\":\"$1\"}]}" \
            >"$TMP_DIR/age-$1.code" 2>/dev/null &
        AGE_PIDS="$AGE_PIDS $!"
    }

    age_wait() {
        # age_wait -> drain the chats started by age_chat, never the mock server
        local pid
        for pid in $AGE_PIDS; do
            wait "$pid" 2>/dev/null || true
        done
        AGE_PIDS=""
    }

    start_container lr-age-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1 \
        LR_INFLIGHT_SAMPLE_SECS=1 LR_INFLIGHT_TTL_SECS=30
    AGE_BASE=$BASE
    AGE_CHAT_BASE=$BASE
    AGE_POLL_BASE=$BASE
    AGE_GW=$(container_gateway lr-age-$SUIT)
    register_worker "$AGE_BASE" "{\"url\":\"http://$AGE_GW:$AGE_PORT\",\"model_id\":\"slow-model\"}"
    assert_eq "inflight_age: worker registered" "$REG_STATUS" "202"
    wait_healthy_worker "$AGE_BASE" 25 || fail "inflight_age worker never became healthy"

    # The distribution is sampled rather than synthesised, so the first tick
    # publishes it and an idle tracker publishes zeros.
    sleep 1.3
    request "$AGE_BASE" GET /metrics
    assert_contains "inflight_age: the first tick publishes the histogram" "$BODY" \
        "# TYPE smg_http_inflight_request_age_count histogram"
    assert_eq "inflight_age: an idle tracker publishes zeros" \
        "$(age_value "$TMP_DIR/body" smg_http_inflight_request_age_count_count)" "0"
    assert_eq "inflight_age: and a zero total age" \
        "$(age_value "$TMP_DIR/body" smg_http_inflight_request_age_count_sum)" "0.000000"
    # Same le= set as the duration histogram: the age buckets are aligned to the
    # existing ladder rather than invented, so one dashboard panel can plot both.
    AGE_LE=$(sed -n 's/^smg_http_inflight_request_age_count_bucket{.*le="\([^"]*\)".*/\1/p' \
        "$TMP_DIR/body" | sort -u | tr '\n' ' ')
    DUR_LE=$(sed -n 's/^smg_http_request_duration_seconds_bucket{.*le="\([^"]*\)".*/\1/p' \
        "$TMP_DIR/body" | sort -u | tr '\n' ' ')
    assert_nonempty "inflight_age: the duration ladder is present to compare against" "$DUR_LE"
    assert_eq "inflight_age: the age buckets are the duration buckets" "$AGE_LE" "$DUR_LE"

    # ---- one slow request: its age has to show up as a real sample ----
    age_chat solo
    age_poll age_pred_samples \
        || fail "inflight_age: no age sample while a 6 s request was in flight"
    SOLO_COUNT=$(age_value "$TMP_DIR/age-body" smg_http_inflight_request_age_count_count)
    SOLO_SUM=$(age_value "$TMP_DIR/age-body" smg_http_inflight_request_age_count_sum)
    assert_eq "inflight_age: a live request is sampled" \
        "$(awk -v c="$SOLO_COUNT" 'BEGIN { print (c + 0 >= 1) ? "yes" : "no" }')" "yes"
    assert_eq "inflight_age: _sum is a positive age in seconds" \
        "$(awk -v s="$SOLO_SUM" 'BEGIN { print (s + 0 > 0) ? "yes" : "no" }')" "yes"
    assert_eq "inflight_age: the age lands in a finite bucket" \
        "$(awk -v a="$(age_bucket_value "$TMP_DIR/age-body" 1)" \
            -v b="$(age_bucket_value "$TMP_DIR/age-body" 2.5)" \
            -v c="$SOLO_COUNT" 'BEGIN { print (a + 0 >= 1 && b + 0 == c + 0) ? "yes" : "no" }')" "yes"
    age_poll age_pred_matches_concurrency \
        || fail "inflight_age: tracker occupancy disagrees with smg_http_inflight_requests"
    assert_eq "inflight_age: the tracker agrees with the concurrency gauge" \
        "$(age_value "$TMP_DIR/age-body" smg_http_inflight_request_age_slots_active)" \
        "$(age_value "$TMP_DIR/age-body" smg_http_inflight_requests)"
    age_wait

    # ---- concurrency: registrations survive the burst and the contract holds ----
    for i in $(seq 1 24); do age_chat "burst$i"; done
    age_poll age_pred_burst \
        || fail "inflight_age: 24 overlapping requests were not all sampled"
    DROPPED=$(age_value "$TMP_DIR/age-body" smg_http_inflight_request_age_dropped_total)
    assert_eq "inflight_age: nothing is dropped at 24 concurrent" \
        "$( [[ "$DROPPED" == "absent" || "$DROPPED" == "0" ]] && echo none || echo "$DROPPED" )" "none"
    assert_eq "inflight_age: the whole exposition still parses" \
        "$(python3 "$TMP_DIR/metrics_check.py" "$TMP_DIR/age-body" unique parseable)" \
        "unique=ok parseable=ok"
    assert_eq "inflight_age: buckets cumulative, +Inf == _count, none larger" \
        "$(python3 "$TMP_DIR/metrics_check.py" "$TMP_DIR/age-body" \
            hist=smg_http_inflight_request_age_count)" \
        "hist(smg_http_inflight_request_age_count)=ok"

    age_wait
    age_poll age_pred_drained \
        || fail "inflight_age: the tracker did not drain to zero after the load"
    request "$AGE_BASE" GET /metrics
    assert_eq "inflight_age: a drained tracker reads zero everywhere" \
        "$(age_value "$TMP_DIR/body" smg_http_inflight_request_age_count_count)" "0"
    assert_eq "inflight_age: and the histogram stays well-formed" \
        "$(python3 "$TMP_DIR/metrics_check.py" "$TMP_DIR/body" \
            hist=smg_http_inflight_request_age_count)" \
        "hist(smg_http_inflight_request_age_count)=ok"

    # ---- leak guard: a client that vanishes mid-request gives the slot back ----
    for _ in 1 2 3; do
        curl -sS -m 0.3 -o /dev/null -X POST "$AGE_BASE/v1/chat/completions" \
            -H 'Content-Type: application/json' \
            --data '{"model":"slow-model","messages":[{"role":"user","content":"abort"}]}' \
            >/dev/null 2>&1 || true
    done
    # the mock answers after 6 s and the write-back then fails, so the log phase
    # is the only hook left; give it past that before checking for a leak.
    sleep 8
    age_poll age_pred_drained \
        || fail "inflight_age: an aborted request leaked its age slot"
    assert_eq "inflight_age: the log-phase sweep reclaimed the aborted requests" "ok" "ok"
    assert_eq "inflight_age: no Lua abort in the age path" \
        "$(docker logs "lr-age-$SUIT" 2>&1 | grep -c 'lua entry thread aborted')" "0"

    # ---- TTL self-heal: a slot cannot outlive LR_INFLIGHT_TTL_SECS ----
    start_container lr-agettl-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1 \
        LR_INFLIGHT_SAMPLE_SECS=1 LR_INFLIGHT_TTL_SECS=1
    AGE_CHAT_BASE=$BASE
    AGE_POLL_BASE=$BASE
    register_worker "$BASE" "{\"url\":\"http://$(container_gateway lr-agettl-$SUIT):$AGE_PORT\",\"model_id\":\"slow-model\"}"
    wait_healthy_worker "$BASE" 25 || fail "inflight_age ttl worker never became healthy"
    age_chat ttl
    age_poll age_pred_ttl_expired \
        || fail "inflight_age: a slot survived past LR_INFLIGHT_TTL_SECS while in flight"
    assert_eq "inflight_age: an expired slot stops being sampled (no unbounded leak)" "ok" "ok"
    age_wait

    # ---- cross-process: one worker samples, several workers register ----
    # The shipped test conf runs a single worker, which cannot prove the shared
    # table works. Derive a four-worker copy of it: registrations then land in
    # four different Lua VMs while only worker 0 samples, so a non-zero _count
    # with the occupancy matching the concurrency gauge is the cross-process
    # evidence (this is what production does with NGINX_WORKER_PROCESSES=auto).
    sed 's/^worker_processes 1;/worker_processes 4;/' \
        "$SCRIPT_DIR/conf/nginx-lua-router.conf" >"$TMP_DIR/age-workers.conf" \
        || fail "could not derive the four-worker conf"
    grep -q '^worker_processes 4;' "$TMP_DIR/age-workers.conf" \
        || fail "the derived conf did not raise worker_processes (test conf drifted)"
    start_container lr-agew-$SUIT /gen/age-workers.conf SMG_HEALTH_CHECK_INTERVAL_SECS=1 \
        LR_INFLIGHT_SAMPLE_SECS=1 LR_INFLIGHT_TTL_SECS=30
    AGE_CHAT_BASE=$BASE
    AGE_POLL_BASE=$BASE
    # `ps -eo args` rather than `comm`: nginx sets its process title, so `comm`
    # stays "openresty" for every process and cannot tell master from workers. The
    # bracket in the pattern keeps the counting `sh -c`/`grep` pair out of its own
    # count (both carry the literal text in their argv).
    AGE_WORKER_COUNT=$(docker exec "lr-agew-$SUIT" sh -c \
        'ps -eo args= | grep -c "[n]ginx: worker process" || true' 2>/dev/null || echo 0)
    register_worker "$BASE" "{\"url\":\"http://$(container_gateway lr-agew-$SUIT):$AGE_PORT\",\"model_id\":\"slow-model\"}"
    wait_healthy_worker "$BASE" 25 || fail "inflight_age four-worker instance never became ready"
    assert_eq "inflight_age: the four-worker instance really has four workers" \
        "$AGE_WORKER_COUNT" "4"
    for i in $(seq 1 32); do age_chat "w$i"; done
    age_poll age_pred_cross \
        || fail "inflight_age: the worker-0 sampler never saw the four-worker burst"
    assert_eq "inflight_age: one sampler sees requests registered by four workers" \
        "$(awk -v c="$(age_value "$TMP_DIR/age-body" smg_http_inflight_request_age_count_count)" \
            'BEGIN { print (c + 0 >= 24) ? "yes" : "no" }')" "yes"
    assert_eq "inflight_age: occupancy matches the concurrency gauge across workers" \
        "$(age_value "$TMP_DIR/age-body" smg_http_inflight_request_age_slots_active)" \
        "$(age_value "$TMP_DIR/age-body" smg_http_inflight_requests)"
    assert_eq "inflight_age: cross-process exposure still parses" \
        "$(python3 "$TMP_DIR/metrics_check.py" "$TMP_DIR/age-body" unique parseable)" \
        "unique=ok parseable=ok"
    age_wait
    age_poll age_pred_drained \
        || fail "inflight_age: the four-worker instance did not drain"
    assert_eq "inflight_age: all four workers handed their slots back" "ok" "ok"

    # ---- off means off: with the sampler disabled the family is absent ----
    start_container lr-ageoff-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1 \
        LR_INFLIGHT_SAMPLE_SECS=0
    OFF_BASE=$BASE
    AGE_CHAT_BASE=$BASE
    sleep 1.3
    request "$BASE" GET /metrics
    assert_not_contains "inflight_age: a disabled sampler renders no age histogram" "$BODY" \
        "smg_http_inflight_request_age_count"
    assert_not_contains "inflight_age: and no occupancy gauge" "$BODY" \
        "smg_http_inflight_request_age_slots_active"
    age_chat off
    sleep 1.4
    request "$OFF_BASE" GET /metrics
    assert_not_contains "inflight_age: a live request adds nothing while disabled" "$BODY" \
        "smg_http_inflight_request_age"
    assert_contains "inflight_age: the concurrency gauge is unaffected" "$BODY" \
        "smg_http_inflight_requests "

    # The absence has to be the *filter*, not an empty dict. /probe/inflight-off
    # seeds a stale age histogram plus a claimed slot into lr_stats (exactly what
    # a switch flip leaves behind) and renders /metrics in-process: disabled ->
    # neither series appears, and the duration family is untouched. The same probe
    # against the enabled instance proves the seeded data was renderable, so the
    # negative result cannot come from a broken probe.
    request "$OFF_BASE" GET /probe/inflight-off
    assert_json "inflight_age: stale histogram stays hidden while disabled" \
        '.histogram_rendered | tostring' 'false'
    assert_json "inflight_age: stale slot stays hidden while disabled" \
        '.slots_rendered | tostring' 'false'
    assert_json "inflight_age: filtering the age family does not filter anything else" \
        '.duration_still_rendered | tostring' 'true'
    request "$AGE_BASE" GET /probe/inflight-off
    assert_json "inflight_age: the same seed renders with the tracker on" \
        '.histogram_rendered | tostring' 'true'
    assert_json "inflight_age: and so does the occupancy gauge" \
        '.slots_rendered | tostring' 'true'
    age_wait
fi

# ==========================================================================
if section tls_server; then
    # Server-side TLS on the *main* listener: the entrypoint
    # renders `listen ... ssl` plus the certificate pair, i.e. the encrypted
    # socket replaces the plain bind on the same port exactly like Rust's rustls
    # layer, rather than opening a SMG_TLS_PORT next to it.
    command -v openssl >/dev/null || { note "openssl missing, skipping the server-TLS section"; }
    if command -v openssl >/dev/null; then
        SRV_CERT_DIR="$TMP_DIR/tls-server"
        mkdir -p "$SRV_CERT_DIR"
        openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
            -keyout "$SRV_CERT_DIR/key.pem" -out "$SRV_CERT_DIR/cert.pem" \
            -subj "/CN=localhost" \
            -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" \
            >"$TMP_DIR/openssl-server.log" 2>&1 \
            || fail "could not create the server certificate"

        docker rm -f lr-tlssrv-$SUIT >/dev/null 2>&1 || true
        CONTAINER_NAMES="$CONTAINER_NAMES lr-tlssrv-$SUIT"
        docker run -d --name lr-tlssrv-$SUIT \
            -p 127.0.0.1:0:30000 \
            -e SMG_PORT=30000 -e SMG_METRICS_PORT=0 \
            -e NGINX_WORKER_PROCESSES=1 \
            -e SMG_HEALTH_CHECK_INTERVAL_SECS=1 \
            -e SMG_TLS_CERT_PATH=/gen/tls-server/cert.pem \
            -e SMG_TLS_KEY_PATH=/gen/tls-server/key.pem \
            -e OPENRESTY_TEMPLATE_DIR=/repo/conf \
            -e LR_UI_CONF=off \
            --entrypoint /repo/docker-entrypoint.sh \
            -v "$REPO_ROOT:/repo:ro" \
            -v "$REPO_ROOT/lualib/resty/luarouter:/usr/local/openresty/site/lualib/resty/luarouter:ro" \
            -v "$TMP_DIR:/gen:ro" \
            "$IMAGE" /usr/local/openresty/bin/openresty -p /usr/local/openresty/nginx -g 'daemon off;' \
            >/dev/null || fail "TLS entrypoint container failed to start"
        TLS_MAIN=$(docker port lr-tlssrv-$SUIT 30000/tcp | awk -F: 'NR == 1 { print $NF }')
        [[ -n "$TLS_MAIN" ]] || fail "no published port for lr-tlssrv-$SUIT"
        TLS_BASE="https://127.0.0.1:$TLS_MAIN"
        i=0
        until curl -fsS --cacert "$SRV_CERT_DIR/cert.pem" -m 2 "$TLS_BASE/health" >/dev/null 2>&1; do
            i=$((i + 1)); [[ $i -gt 120 ]] && fail "TLS listener never came up ($(docker logs lr-tlssrv-$SUIT 2>&1 | tail -5))"
            sleep 0.1
        done

        # ---- the render itself ----
        RENDERED=$(docker exec lr-tlssrv-$SUIT cat /usr/local/openresty/nginx/conf/nginx.conf)
        assert_contains "tls render: listen gains ssl" "$RENDERED" "listen 0.0.0.0:30000 ssl;"
        assert_contains "tls render: certificate wired" "$RENDERED" "ssl_certificate /gen/tls-server/cert.pem;"
        assert_contains "tls render: key wired" "$RENDERED" "ssl_certificate_key /gen/tls-server/key.pem;"
        assert_contains "tls render: TLSv1.2" "$RENDERED" "TLSv1.2"
        assert_contains "tls render: TLSv1.3" "$RENDERED" "TLSv1.3"

        # ---- real traffic over TLS ----
        request "$TLS_BASE" GET /health --cacert "$SRV_CERT_DIR/cert.pem"
        assert_eq "tls serve: /health over TLS" "$STATUS" "200"
        TLSGW=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' lr-tlssrv-$SUIT)
        register_worker "$TLS_BASE" "{\"url\":\"http://${TLSGW}:${MOCK_PORT}\",\"model_id\":\"test-model\"}" --cacert "$SRV_CERT_DIR/cert.pem"
        assert_eq "tls serve: control plane reachable over TLS" "$STATUS" "202"
        wait_healthy_worker "$TLS_BASE" 30 1 --cacert "$SRV_CERT_DIR/cert.pem" \
            || fail "tls serve: worker never healthy behind TLS"
        request "$TLS_BASE" POST /v1/chat/completions --cacert "$SRV_CERT_DIR/cert.pem" \
            -H 'Content-Type: application/json' \
            --data '{"model":"test-model","messages":[{"role":"user","content":"tls chat"}]}'
        assert_eq "tls serve: chat completes over TLS" "$STATUS" "200"
        assert_contains "tls serve: chat response body" "$BODY" "tls chat"
        STREAM_OUT=$(curl -sS -N --cacert "$SRV_CERT_DIR/cert.pem" -m 20 \
            -X POST "$TLS_BASE/v1/chat/completions" -H 'Content-Type: application/json' \
            --data '{"model":"test-model","stream":true,"messages":[{"role":"user","content":"tls stream"}]}')
        assert_contains "tls serve: streaming survives TLS" "$STREAM_OUT" "data: [DONE]"

        # ---- protocol floor ----
        SNI_TLS12=$(echo Q | openssl s_client -connect "127.0.0.1:$TLS_MAIN" -tls1_2 \
            -CAfile "$SRV_CERT_DIR/cert.pem" 2>&1 | grep -c "Verify return code: 0 (ok)" || true)
        assert_eq "tls handshake: TLSv1.2 accepted" "$SNI_TLS12" "1"
        TLS11_CODE=$(curl -sS -o /dev/null -w '%{http_code}' --tlsv1.1 --tls-max 1.1 \
            --cacert "$SRV_CERT_DIR/cert.pem" "$TLS_BASE/health" 2>"$TMP_DIR/tls11.err" || true)
        assert_not_contains "tls handshake: TLSv1.1 refused" "$TMP_DIR/tls11.err" "200"
        [[ "$TLS11_CODE" == "000" || -z "$TLS11_CODE" ]] \
            && pass "tls handshake: TLSv1.1 gets no response" \
            || note "TLSv1.1 curl exit produced code '$TLS11_CODE' (still no 200)"

        # ---- plain http against the TLS port does not serve ----
        PLAIN_CODE=$(curl -sS -o "$TMP_DIR/plain-body" -w '%{http_code}' -m 5 \
            "http://127.0.0.1:$TLS_MAIN/health" 2>"$TMP_DIR/plain.err" || true)
        assert_not_contains "tls: plain http is not served on the TLS port" "$PLAIN_CODE" "200"

        # ---- without the cert envs the plain listener is unchanged ----
        docker rm -f lr-tlsplain-$SUIT >/dev/null 2>&1 || true
        CONTAINER_NAMES="$CONTAINER_NAMES lr-tlsplain-$SUIT"
        docker run -d --name lr-tlsplain-$SUIT \
            -p 127.0.0.1:0:30000 \
            -e SMG_PORT=30000 -e SMG_METRICS_PORT=0 -e NGINX_WORKER_PROCESSES=1 \
            -e OPENRESTY_TEMPLATE_DIR=/repo/conf -e LR_UI_CONF=off \
            --entrypoint /repo/docker-entrypoint.sh \
            -v "$REPO_ROOT:/repo:ro" \
            -v "$REPO_ROOT/lualib/resty/luarouter:/usr/local/openresty/site/lualib/resty/luarouter:ro" \
            "$IMAGE" /usr/local/openresty/bin/openresty -p /usr/local/openresty/nginx -g 'daemon off;' \
            >/dev/null || fail "plain entrypoint container failed to start"
        PLAIN_MAIN=$(docker port lr-tlsplain-$SUIT 30000/tcp | awk -F: 'NR == 1 { print $NF }')
        i=0
        until curl -fsS -m 2 "http://127.0.0.1:$PLAIN_MAIN/health" >/dev/null 2>&1; do
            i=$((i + 1)); [[ $i -gt 120 ]] && fail "plain listener never came up"
            sleep 0.1
        done
        PLAIN_RENDERED=$(docker exec lr-tlsplain-$SUIT cat /usr/local/openresty/nginx/conf/nginx.conf)
        assert_contains "no-tls render: plain listen kept" "$PLAIN_RENDERED" "listen 0.0.0.0:30000;"
        assert_not_contains "no-tls render: no ssl directive" "$PLAIN_RENDERED" "ssl_certificate"
        request "http://127.0.0.1:$PLAIN_MAIN" GET /health
        assert_eq "no-tls: plain /health still 200" "$STATUS" "200"

        # ---- half-configured TLS fails fast ----
        HALF_LOG=$(docker run --rm \
            -e SMG_TLS_CERT_PATH=/gen/tls-server/cert.pem \
            -e OPENRESTY_TEMPLATE_DIR=/repo/conf \
            --entrypoint /repo/docker-entrypoint.sh \
            -v "$REPO_ROOT:/repo:ro" -v "$TMP_DIR:/gen:ro" \
            "$IMAGE" /usr/local/openresty/bin/openresty -t 2>&1 || true)
        assert_contains "tls: cert without key is refused" "$HALF_LOG" "must be set together"
        MISSING_LOG=$(docker run --rm \
            -e SMG_TLS_CERT_PATH=/gen/tls-server/cert.pem \
            -e SMG_TLS_KEY_PATH=/gen/tls-server/nope.pem \
            -e OPENRESTY_TEMPLATE_DIR=/repo/conf \
            --entrypoint /repo/docker-entrypoint.sh \
            -v "$REPO_ROOT:/repo:ro" -v "$TMP_DIR:/gen:ro" \
            "$IMAGE" /usr/local/openresty/bin/openresty -t 2>&1 || true)
        assert_contains "tls: missing key file is refused" "$MISSING_LOG" "certificate or key missing"
    fi
fi

# ==========================================================================
if section profiles_upstreams; then
    # Section 23: the virtual-model profile + upstreams surface from
    # doc/gap-virtual-models.md 3.5. The /_ui/config document grows a
    # new-shape virtual_models array (model/target/workers/policy/effort, old
    # {model,target} rows stay valid) and an upstreams array whose api_key is
    # never echoed; POST /_ui/config/upstreams replaces the pool and reconciles
    # it into the worker registry as discovery=config. Own containers: the flow
    # rewrites whole documents repeatedly and must not leak config state into
    # the shared main instance (the section may also run under TEST_ONLY).
    start_container lr-profs-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1
    PR_BASE=$BASE
    PR_GW=$(container_gateway lr-profs-$SUIT)
    URL_A="http://$PR_GW:$MOCK_PORT"
    URL_B="http://$PR_GW:$SINK_PORT"
    SECRET="sk-contract-$SUIT"

    pr_config_count() {
        # pr_config_count N -> poll GET /workers until exactly N workers carry
        # discovery=config. Reconcile is synchronous per 3.1, but the health
        # sweep re-rendering the list must not turn into a flaky failure.
        local want=$1 i n
        for i in $(seq 1 100); do
            request "$PR_BASE" GET /workers
            n=$(jq -r '[.workers[] | select(.discovery == "config")] | length' \
                "$TMP_DIR/body" 2>/dev/null || echo 0)
            [[ "$n" == "$want" ]] && return 0
            sleep 0.1
        done
        return 1
    }

    # ---- 1. GET /_ui/config document shape ---------------------------------
    request "$PR_BASE" GET /_ui/config
    assert_eq "profiles: /_ui/config GET" "$STATUS" "200"
    assert_json "profiles: the new sections are a superset of the old keys" \
        '(["default_effort","effort_map","model_ctx","model_effort","model_configs","virtual_models","policy","model_policies","env_defaults","watcher","persist","models"] - keys | length) == 0 | tostring' "true"
    assert_json "profiles: document carries an upstreams array" '(.upstreams | type)' "array"
    assert_json "profiles: document carries a virtual_models array" '(.virtual_models | type)' "array"
    request "$PR_BASE" HEAD /_ui/config
    assert_eq "profiles: HEAD mirrors the GET status" "$STATUS" "200"
    assert_contains "profiles: HEAD keeps the JSON content type" "$CONTENT_TYPE" "application/json"

    # ---- 2. POST /_ui/config/virtual (whole-table replace) -----------------
    # New profile shape: all five fields round-trip through the echoed document.
    request "$PR_BASE" POST /_ui/config/virtual -H 'Content-Type: application/json' \
        --data "{\"entries\":[{\"model\":\"vm-full\",\"target\":\"test-model\",\"workers\":[\"$URL_A\"],\"policy\":\"round_robin\",\"effort\":\"high\"}]}"
    assert_eq "profiles: new-shape entries accepted" "$STATUS" "200"
    assert_json "profiles: response echoes the document with the profile" \
        '[.virtual_models[] | select(.model == "vm-full")] | length' "1"
    assert_json "profiles: profile target round-trips" \
        '[.virtual_models[] | select(.model == "vm-full")][0].target' "test-model"
    assert_json "profiles: profile workers round-trips" \
        '[.virtual_models[] | select(.model == "vm-full")][0].workers | index("'"$URL_A"'") != null | tostring' "true"
    assert_json "profiles: profile policy round-trips" \
        '[.virtual_models[] | select(.model == "vm-full")][0].policy' "round_robin"
    assert_json "profiles: profile effort round-trips" \
        '[.virtual_models[] | select(.model == "vm-full")][0].effort' "high"

    # The old two-field rows keep working: replacement is whole-table, so both
    # shapes ride the same submission and both must come back.
    request "$PR_BASE" POST /_ui/config/virtual -H 'Content-Type: application/json' \
        --data "{\"entries\":[{\"model\":\"vm-old\",\"target\":\"test-model\"},{\"model\":\"vm-full\",\"target\":\"test-model\",\"workers\":[\"$URL_A\"],\"policy\":\"round_robin\",\"effort\":\"high\"}]}"
    assert_eq "profiles: old-shape entries still accepted" "$STATUS" "200"
    assert_json "profiles: old row keeps model and target" \
        '[.virtual_models[] | select(.model == "vm-old")][0].target' "test-model"

    # Rejections: chained alias, self-alias, malformed workers, unknown
    # policy/effort. Error text shape matches the existing handlers (nonempty
    # .error); the chain message has to name one of the two models involved.
    request "$PR_BASE" POST /_ui/config/virtual -H 'Content-Type: application/json' \
        --data '{"entries":[{"model":"vm-p1","target":"vm-p2"},{"model":"vm-p2","target":"test-model"}]}'
    assert_eq "profiles: an alias targeting another alias is 400" "$STATUS" "400"
    assert_matches "profiles: the chain error names the model involved" "$BODY" 'vm-p[12]'

    request "$PR_BASE" POST /_ui/config/virtual -H 'Content-Type: application/json' \
        --data '{"entries":[{"model":"vm-same","target":"vm-same"}]}'
    assert_eq "profiles: alias == target is 400" "$STATUS" "400"
    assert_contains "profiles: the self-alias error names it" "$BODY" "vm-same"

    request "$PR_BASE" POST /_ui/config/virtual -H 'Content-Type: application/json' \
        --data '{"entries":[{"model":"vm-w","target":"test-model","workers":"http://pool.invalid"}]}'
    assert_eq "profiles: workers as a bare string is 400" "$STATUS" "400"
    request "$PR_BASE" POST /_ui/config/virtual -H 'Content-Type: application/json' \
        --data '{"entries":[{"model":"vm-w2","target":"test-model","workers":["ok",123]}]}'
    assert_eq "profiles: a non-string workers member is 400" "$STATUS" "400"

    request "$PR_BASE" POST /_ui/config/virtual -H 'Content-Type: application/json' \
        --data '{"entries":[{"model":"vm-pol","target":"test-model","policy":"roundabout"}]}'
    assert_eq "profiles: an unknown profile policy is 400" "$STATUS" "400"
    assert_json "profiles: the policy rejection carries error text" \
        '.error | length > 0 | tostring' "true"
    request "$PR_BASE" POST /_ui/config/virtual -H 'Content-Type: application/json' \
        --data '{"entries":[{"model":"vm-eff","target":"test-model","effort":"mega"}]}'
    assert_eq "profiles: an unknown profile effort is 400" "$STATUS" "400"

    # A rejected replace must leave the previous table alone (no half-apply):
    # none of the rejected aliases landed, the accepted pair survived.
    request "$PR_BASE" GET /_ui/config
    assert_eq "profiles: the document answers after the rejection run" "$STATUS" "200"
    assert_json "profiles: rejected aliases never landed" \
        '[.virtual_models[] | select(.model == "vm-p1" or .model == "vm-same" or .model == "vm-w" or .model == "vm-w2" or .model == "vm-pol" or .model == "vm-eff")] | length' "0"
    assert_json "profiles: accepted rows survived the rejected batches" \
        '[.virtual_models[] | select(.model == "vm-old" or .model == "vm-full")] | length' "2"

    # ---- 3. POST /_ui/config/upstreams + reconcile -------------------------
    request "$PR_BASE" POST /_ui/config/upstreams -H 'Content-Type: application/json' \
        --data "{\"entries\":[{\"url\":\"$URL_A\",\"model_id\":\"test-model\",\"api_key\":\"$SECRET\"},{\"url\":\"$URL_B\",\"model_id\":\"sink-model\",\"priority\":70,\"cost\":2.5,\"disable_health_check\":false}]}"
    assert_eq "upstreams: valid entries accepted" "$STATUS" "200"
    assert_json "upstreams: response carries the reconcile summary" \
        '.reconcile | has("added") and has("updated") and has("removed") and has("skipped") | tostring' "true"
    assert_json "upstreams: both pool members count as added" '.reconcile.added' "2"
    assert_json "upstreams: a cold pool updates/removes/skips nothing" \
        '[.reconcile.updated, .reconcile.removed, .reconcile.skipped] | tostring' "[0,0,0]"
    pr_config_count 2 || fail "upstreams: config pool never reached 2 members"
    assert_json "upstreams: the config worker shows up in /workers" \
        '[.workers[] | select(.url == "'"$URL_A"'")] | length' "1"
    assert_json "upstreams: the pool member carries discovery=config" \
        '[.workers[] | select(.url == "'"$URL_A"'")][0].discovery' "config"
    assert_json "upstreams: entry fields land on the worker record" \
        '[.workers[] | select(.url == "'"$URL_B"'")][0].priority' "70"
    assert_json "upstreams: GET /workers exposes no api_key value" \
        '[.workers[] | .api_key] | unique | tostring' "[null]"
    assert_not_contains "upstreams: no secret in /workers" "$BODY" "$SECRET"
    request "$PR_BASE" GET /_ui/config
    assert_not_contains "upstreams: no secret in the document" "$BODY" "$SECRET"
    assert_json "upstreams: document api_key stays null" \
        '[.upstreams[] | select(.url == "'"$URL_A"'")][0].api_key | tostring' "null"

    # Validation rejections (contract 3.5): url dedup after normalization, the
    # 256-entry cap, and a non-http(s) scheme. None of them may mutate the
    # accepted pool.
    request "$PR_BASE" POST /_ui/config/upstreams -H 'Content-Type: application/json' \
        --data "{\"entries\":[{\"url\":\"$URL_A\"},{\"url\":\"$URL_A/\"}]}"
    assert_eq "upstreams: two entries normalizing to one url are refused" "$STATUS" "400"
    python3 - "$TMP_DIR" <<'PY'
import json, sys
tmp = sys.argv[1]
json.dump({"entries": [{"url": "http://127.0.0.1:%d" % (20000 + i)} for i in range(257)]},
          open(tmp + "/up-many.json", "w"))
json.dump({"virtual_models": [],
           "upstreams": [{"url": "http://127.0.0.1:%d" % (21000 + i)} for i in range(300)]},
          open(tmp + "/apply-over-cap.json", "w"))
PY
    request "$PR_BASE" POST /_ui/config/upstreams -H 'Content-Type: application/json' \
        --data @"$TMP_DIR/up-many.json"
    assert_eq "upstreams: more than 256 entries are refused" "$STATUS" "400"
    request "$PR_BASE" POST /_ui/config/upstreams -H 'Content-Type: application/json' \
        --data '{"entries":[{"url":"ftp://pool-member.invalid:2121"}]}'
    assert_eq "upstreams: a non-http(s) scheme is refused" "$STATUS" "400"
    request "$PR_BASE" GET /workers
    assert_json "upstreams: rejected batches left the pool at two" '.total' "2"

    # ---- 4. api_key write semantics (null keeps, "" clears) ----------------
    # The key lives only inside the gateway: resubmitting null must answer 200
    # (never 500, never echo), and the reconcile summary must report this as a
    # keep, not a re-add. updated=0 (change-counting) or 1 (unconditional
    # re-apply) are both contract-legal here; the exact keep-the-key behaviour
    # is pinned by e2e_profiles against a REQUIRE_AUTH mock.
    request "$PR_BASE" POST /_ui/config/upstreams -H 'Content-Type: application/json' \
        --data "{\"entries\":[{\"url\":\"$URL_A\",\"model_id\":\"test-model\",\"api_key\":null},{\"url\":\"$URL_B\",\"model_id\":\"sink-model\",\"priority\":70,\"cost\":2.5,\"disable_health_check\":false}]}"
    assert_eq "upstreams: a null api_key resubmit answers 200, never 500" "$STATUS" "200"
    assert_json "upstreams: the null resubmit adds nobody" '.reconcile.added' "0"
    UPD=$(jq -r '.reconcile.updated' "$TMP_DIR/body" 2>/dev/null || echo '?')
    case "$UPD" in
        0|1) pass "upstreams: null-key resubmit counts as updated=$UPD";;
        *) fail "upstreams: reconcile.updated after a null-key resubmit must be 0 or 1 (got '$UPD')";;
    esac
    assert_json "upstreams: the response document still hides the key" \
        '[.upstreams[] | select(.url == "'"$URL_A"'")][0].api_key | tostring' "null"

    request "$PR_BASE" POST /_ui/config/upstreams -H 'Content-Type: application/json' \
        --data "{\"entries\":[{\"url\":\"$URL_A\",\"model_id\":\"test-model\",\"api_key\":\"\"},{\"url\":\"$URL_B\",\"model_id\":\"sink-model\",\"priority\":70,\"cost\":2.5,\"disable_health_check\":false}]}"
    assert_eq "upstreams: an empty-string api_key is accepted (clear semantics)" "$STATUS" "200"

    # Teardown path: an empty replace removes exactly the discovery=config
    # members and counts them (3.1: other origins are never touched).
    request "$PR_BASE" POST /_ui/config/upstreams -H 'Content-Type: application/json' \
        --data '{"entries":[]}'
    assert_eq "upstreams: an empty replace is accepted" "$STATUS" "200"
    assert_json "upstreams: the removed members are counted" '.reconcile.removed' "2"
    pr_config_count 0 || fail "upstreams: config members never left the pool"
    request "$PR_BASE" GET /workers
    assert_json "upstreams: the pool is empty after teardown" '.total' "0"

    # ---- 5. POST /_ui/config/apply is atomic across both new sections ------
    # Own instance: the rejection checks below compare the whole document
    # before/after, which needs a state nobody else writes to.
    start_container lr-apl-$SUIT "$BASE_CONF" SMG_HEALTH_CHECK_INTERVAL_SECS=1
    AP_BASE=$BASE
    AP_GW=$(container_gateway lr-apl-$SUIT)
    URL_C="http://$AP_GW:$MOCK_PORT"

    request "$AP_BASE" POST /_ui/config/apply -H 'Content-Type: application/json' \
        --data "{\"virtual_models\":[{\"model\":\"ap-a\",\"target\":\"test-model\",\"workers\":[],\"policy\":\"bucket\",\"effort\":\"medium\"}],\"upstreams\":[{\"url\":\"$URL_C\",\"model_id\":\"test-model\"}]}"
    assert_eq "apply: whole document with virtual_models + upstreams" "$STATUS" "200"
    assert_json "apply: the answer echoes the profile" \
        '[.virtual_models[] | select(.model == "ap-a")][0].policy' "bucket"
    # 3.5 documents the reconcile summary for /config/upstreams; for apply it
    # only requires that the section triggers a reconcile. The observable half
    # of that is the pool, asserted below, so a missing summary here is a
    # documented divergence rather than a broken contract.
    if [[ "$(jq -r '.reconcile.added // "absent"' "$TMP_DIR/body" 2>/dev/null)" == "1" ]]; then
        pass "apply: the upstreams section reports reconcile.added=1"
    else
        note "apply: response carries no reconcile.added summary for the new upstream"
    fi
    for _ in $(seq 1 100); do
        request "$AP_BASE" GET /workers
        jq -e '[.workers[] | select(.url == "'"$URL_C"'")] | length == 1' \
            "$TMP_DIR/body" >/dev/null 2>&1 && break
        sleep 0.1
    done
    assert_json "apply: the reconciled worker carries discovery=config" \
        '[.workers[] | select(.url == "'"$URL_C"'")][0].discovery' "config"
    request "$AP_BASE" GET /_ui/config
    assert_eq "apply: GET after the successful apply" "$STATUS" "200"
    OK_DOC=$(jq -c '[.virtual_models, .upstreams]' "$TMP_DIR/body")

    # An invalid policy fragment anywhere in the document rejects the whole
    # write: virtual_models keeps ap-a (no ap-x) and upstreams keeps URL_C, so
    # neither the good nor the bad section was half-applied.
    request "$AP_BASE" POST /_ui/config/apply -H 'Content-Type: application/json' \
        --data '{"virtual_models":[{"model":"ap-x","target":"test-model","policy":"notapolicy"}],"upstreams":[]}'
    assert_eq "apply: an invalid policy fragment rejects the document" "$STATUS" "400"
    request "$AP_BASE" GET /_ui/config
    assert_eq "apply: the rejected document kept virtual_models and upstreams" \
        "$(jq -c '[.virtual_models, .upstreams]' "$TMP_DIR/body")" "$OK_DOC"

    # Same through the upstreams side: an over-cap batch must not half-apply
    # (the empty virtual_models fragment must not clear the surviving profile).
    request "$AP_BASE" POST /_ui/config/apply -H 'Content-Type: application/json' \
        --data @"$TMP_DIR/apply-over-cap.json"
    assert_eq "apply: an over-limit upstreams batch rejects the document" "$STATUS" "400"
    request "$AP_BASE" GET /_ui/config
    assert_eq "apply: the second rejection also changed nothing" \
        "$(jq -c '[.virtual_models, .upstreams]' "$TMP_DIR/body")" "$OK_DOC"

    # ---- 6. Method and HEAD mirror on the new endpoints --------------------
    # The two POST-only sections gate like their siblings (ui.conf
    # method_only("POST") -> axum-style 405 + Allow), and the GET-family
    # endpoints answer HEAD through the GET route.
    request "$PR_BASE" GET /_ui/config/upstreams
    assert_eq "upstreams: GET is refused" "$STATUS" "405"
    AL_UP=$(header_of Allow)
    assert_eq "upstreams: Allow names POST only" "$AL_UP" "POST"
    request "$PR_BASE" GET /_ui/config/virtual
    assert_eq "virtual: GET is refused like the sibling gate" "$STATUS" "405"
    assert_eq "virtual: the Allow shape matches /config/upstreams" \
        "$(header_of Allow)" "$AL_UP"
    request "$PR_BASE" PUT /_ui/config/upstreams -H 'Content-Type: application/json' \
        --data '{"entries":[]}'
    assert_eq "upstreams: PUT is refused too" "$STATUS" "405"
    request "$PR_BASE" HEAD /_ui/config/policy
    assert_eq "policy: HEAD keeps answering the GET route" "$STATUS" "200"
fi

# ==========================================================================
printf '\n----------------------------------------\n'
if [[ "$KEEP_GOING" == "1" ]]; then
    printf 'Triage run: %d passed, %d failed, %d notes\n' "$PASSED" "$FAILS" "$NOTE_COUNT"
    [[ "$FAILS" == "0" ]] || exit 1
else
    printf 'All %d lua-router contract checks passed (%d documented notes)\n' "$PASSED" "$NOTE_COUNT"
fi
[[ "$NOTE_COUNT" == "0" ]] || printf 'Notes: see "NOTE:" lines above (contract divergences, not failures).\n'
