#!/usr/bin/env python3
""" /v1/responses metadata patching and conditional streaming persistence."""
import json, os, socket, struct, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import check, cleanup, http, register, start_router, stop_router, wait_ready, RESULTS

MODEL = "alpha"
STATE = {"completed": set(), "requests": 0}
LOCK = threading.Lock()
DELAY = float(os.environ.get("RESPONSES_STORE_DELAY", "0.12"))
UPSTREAM_PORT = 0


def response_document(rid, status="completed", model=None):
    return {
        "id": rid,
        "object": "response",
        "created_at": 1790000000,
        "status": status,
        **({"model": model} if model is not None else {}),
        "output": [{
            "type": "message", "id": "msg_" + rid, "role": "assistant",
            "content": [{"type": "output_text", "text": "stored", "annotations": []}],
        }],
        "output_text": "stored",
        "tools": [],
        "safety_identifier": None,
        "metadata": None,
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def json(self, status, value):
        raw = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/health":
            self.json(200, {"status": "ok"})
        elif path == "/v1/models":
            self.json(200, {"object": "list", "data": [
                {"id": MODEL, "object": "model", "owned_by": "local"}]})
        elif path == "/model_info":
            self.json(200, {"model_path": "/models/alpha", "served_model_name": MODEL})
        elif path == "/stats":
            with LOCK:
                self.json(200, {"completed": sorted(STATE["completed"]),
                                "requests": STATE["requests"]})
        else:
            self.json(404, {"error": "not found"})

    def read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            return json.loads(raw)
        except Exception:
            return {}

    def chunk(self, text):
        raw = text.encode()
        self.wfile.write(b"%x\r\n" % len(raw))
        self.wfile.write(raw)
        self.wfile.write(b"\r\n")
        self.wfile.flush()

    def event(self, name, value):
        self.chunk("event: %s\ndata: %s\n\n" % (name, json.dumps(value)))
        time.sleep(DELAY)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        body = self.read_body()
        with LOCK:
            STATE["requests"] += 1
        if path != "/v1/responses":
            self.json(404, {"error": "not found"})
            return
        rid = body.get("metadata", {}).get("rid", "resp_unknown")
        mode = body.get("metadata", {}).get("mode", "full")
        if body.get("stream") is not True:
            # Missing model/instructions/previous_response_id and null metadata
            # exercise every patch_response_with_request_metadata branch.
            self.json(200, response_document(rid))
            with LOCK:
                STATE["completed"].add(rid)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            self.event("response.created", {
                "type": "response.created",
                "response": response_document(rid, "in_progress"),
            })
            item = response_document(rid)["output"][0]
            # The OpenAI/Rust event name is "response.output_item.done"
            # (openai-protocol event_types.rs::OutputItemEvent::DONE). The bare
            # "output_item.done" spelling is the other shape the router accepts, so
            # both are exercised: mode picks which one this stream uses.
            item_name = ("output_item.done" if mode == "bare_item"
                         else "response.output_item.done")
            self.event(item_name, {
                "type": item_name, "output_index": 0, "item": item,
            })
            # A "no_completed" stream ends after the item, so the persisted row can
            # only come from the accumulator's synthesized fallback response.
            if mode != "no_completed":
                self.event("response.completed", {
                    "type": "response.completed",
                    "response": response_document(rid),
                })
            self.chunk("data: [DONE]\n\n")
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            with LOCK:
                STATE["completed"].add(rid)
        except (BrokenPipeError, ConnectionResetError):
            pass


def aborting_client(port, rid, **extra):
    """Send a streaming request, read the first bytes, then RST the connection."""
    payload = {"model": MODEL, "input": "disconnect me", "stream": True,
               "metadata": {"rid": rid}}
    payload.update(extra)
    body = json.dumps(payload).encode()
    req = ("POST /v1/responses HTTP/1.1\r\nHost: localhost\r\n"
           "Content-Type: application/json\r\nContent-Length: %d\r\n\r\n"
           % len(body)).encode() + body
    s = socket.create_connection(("127.0.0.1", port), timeout=3)
    s.sendall(req)
    s.recv(1024)
    # Linger with a zero timeout turns close() into RST, so the router sees the
    # client as gone rather than draining a graceful FIN.
    s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    s.close()


def upstream_completed(rid, timeout=8.0):
    """Poll the mock's own counter: did it write the whole stream?"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        st, body, _ = http("GET", "http://127.0.0.1:%d/stats" % UPSTREAM_PORT)
        if st == 200 and rid in json.loads(body).get("completed", []):
            return True
        time.sleep(0.1)
    return False


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    upstream_port = server.server_address[1]
    global UPSTREAM_PORT
    UPSTREAM_PORT = upstream_port
    name = "lr-resp-store-%d" % os.getpid()
    port = start_router({"SMG_POLICY": "round_robin",
                         "SMG_HEALTH_CHECK_INTERVAL_SECS": "1"}, name)
    try:
        st, body = register(port, "http://127.0.0.1:%d" % upstream_port)
        check("[responses store] worker registered", st == 202, "%s %s" % (st, body))
        check("[responses store] worker healthy", wait_ready(port, 1))

        request = {
            "model": MODEL, "input": "non-stream", "store": False,
            "previous_response_id": "prev-123", "instructions": "be brief",
            "metadata": {"rid": "resp_non", "tag": "x"}, "user": "u-1",
            "conversation": "conv-1", "tools": [],
        }
        st, body, _ = http("POST", "http://127.0.0.1:%d/v1/responses" % port, request)
        check("[responses patch] non-stream 200", st == 200, "%s %s" % (st, body[:250]))
        doc = json.loads(body) if st == 200 else {}
        check("[responses patch] request metadata returned to client",
              doc.get("previous_response_id") == "prev-123"
              and doc.get("instructions") == "be brief"
              and doc.get("metadata", {}).get("tag") == "x"
              and doc.get("store") is False
              and doc.get("model") == MODEL
              and doc.get("safety_identifier") == "u-1"
              and doc.get("conversation", {}).get("id") == "conv-1",
              json.dumps(doc)[:400])
        check("[responses patch] arrays stay arrays", doc.get("tools") == [],
              json.dumps(doc.get("tools")))
        st, body, _ = http("GET", "http://127.0.0.1:%d/v1/responses/resp_non" % port)
        stored = json.loads(body) if st == 200 else {}
        check("[responses patch] stored copy carries the same metadata",
              st == 200 and stored.get("previous_response_id") == "prev-123"
              and stored.get("store") is False
              and stored.get("conversation", {}).get("id") == "conv-1",
              "%s %s" % (st, body[:300]))

        def stream_req(rid, **kw):
            # A caller-supplied metadata dict extends the default instead of
            # replacing it, so the mock always finds its rid.
            doc = {"model": MODEL, "input": "stream", "stream": True,
                   "metadata": {"rid": rid}}
            meta = kw.pop("metadata", None)
            doc.update(kw)
            if isinstance(meta, dict):
                doc["metadata"] = {**meta, "rid": rid}
            return doc
        st, raw, hdrs = http("POST", "http://127.0.0.1:%d/v1/responses" % port,
                             stream_req("resp_stream_no"))
        ctypes = [v for k, v in hdrs.items() if k.lower() == "content-type"]
        check("[responses stream] no-store SSE passes through",
              st == 200 and any("text/event-stream" in v for v in ctypes)
              and raw.count("event: response.completed") == 1
              and raw.endswith("data: [DONE]\n\n"), "%s %r" % (st, raw[-160:]))
        st, _, _ = http("GET", "http://127.0.0.1:%d/v1/responses/resp_stream_no" % port)
        check("[responses stream] no-store and no conversation is not persisted", st == 404, st)

        for rid, extra in (("resp_stream_store", {"store": True}),
                           ("resp_stream_conv", {"conversation": "conv-stream"})):
            st, raw, _ = http("POST", "http://127.0.0.1:%d/v1/responses" % port,
                               stream_req(rid, **extra))
            check("[responses stream] %s streamed 200" % rid,
                  st == 200 and "response.completed" in raw and "data: [DONE]" in raw,
                  "%s %r" % (st, raw[-160:]))
            st, body, _ = http("GET", "http://127.0.0.1:%d/v1/responses/%s" % (port, rid))
            doc = json.loads(body) if st == 200 else {}
            check("[responses stream] %s persisted with patched metadata" % rid,
                  st == 200 and doc.get("store") == (rid == "resp_stream_store")
                  and doc.get("model") == MODEL
                  and doc.get("metadata", {}).get("rid") == rid
                  and isinstance(doc.get("output"), list),
                  "%s %s" % (st, body[:300]))

        # Persistence branch (Rust streaming.rs:574-610): a client that hangs up
        # stops the WRITES but not the READS. The router keeps draining upstream,
        # the mock therefore finishes the whole stream, and the completed response
        # is patched and stored as if the client had stayed.
        aborting_client(port, "resp_stream_abort", store=True)
        check("[responses stream] disconnect still drains upstream to completion",
              upstream_completed("resp_stream_abort"))
        st, body, _ = http("GET", "http://127.0.0.1:%d/v1/responses/resp_stream_abort" % port)
        doc = json.loads(body) if st == 200 else {}
        check("[responses stream] store=true persists after client disconnect",
              st == 200 and doc.get("id") == "resp_stream_abort"
              and doc.get("status") == "completed" and doc.get("store") is True
              and isinstance(doc.get("output"), list)
              and len(doc.get("output") or []) == 1,
              "%s %s" % (st, body[:300]))

        # Non-persistence branch: without store/conversation there is nothing to
        # store, so the pump must tear down the moment the client goes away.
        aborting_client(port, "resp_stream_abort_nostore")
        time.sleep(1.2)
        st, _, _ = http("GET", "http://127.0.0.1:%d/v1/responses/resp_stream_abort_nostore" % port)
        check("[responses stream] no-store disconnect persists nothing", st == 404, st)

        # C4 gate equals Rust's Option<String>::is_some(): an empty-string
        # conversation enables persistence and still writes the (empty) id back.
        # Rust would refuse "" inside the item-linking lookup and warn, skipping
        # only the link, so "row stored, nothing linked" is the same outcome here.
        st, raw, _ = http("POST", "http://127.0.0.1:%d/v1/responses" % port,
                          stream_req("resp_stream_empty_conv", conversation=""))
        st2, body, _ = http("GET",
                            "http://127.0.0.1:%d/v1/responses/resp_stream_empty_conv" % port)
        doc = json.loads(body) if st2 == 200 else {}
        check("[responses stream] empty-string conversation persists",
              st == 200 and "response.completed" in raw and st2 == 200
              and doc.get("conversation") == {"id": ""}
              and doc.get("conversation_id") == ""
              and doc.get("status") == "completed",
              "%s %s %s" % (st, st2, body[:250]))

        # The accumulator fallback: with no response.completed in the stream the
        # stored row is response.created plus the collected items. Both accepted
        # event spellings must land the item.
        for suffix, mode in (("prefixed", "response.output_item.done"),
                             ("bare", "bare_item")):
            rid = "resp_fallback_" + suffix
            st, raw, _ = http("POST", "http://127.0.0.1:%d/v1/responses" % port,
                              stream_req(rid, store=True,
                                         metadata={"rid": rid, "mode": mode}))
            st2, body, _ = http("GET", "http://127.0.0.1:%d/v1/responses/resp_fallback_%s"
                                % (port, suffix))
            doc = json.loads(body) if st2 == 200 else {}
            check("[responses stream] %s item name builds the fallback response" % suffix,
                  st == 200 and st2 == 200
                  and doc.get("status") == "completed"
                  and [i.get("id") for i in doc.get("output") or []] == ["msg_resp_fallback_" + suffix]
                  and doc.get("metadata", {}).get("mode") == mode,
                  "%s %s %s" % (st, st2, body[:300]))
    finally:
        stop_router(name)
        server.shutdown()
        server.server_close()
        cleanup()

    failed = sum(1 for ok, _, _ in RESULTS if not ok)
    print("\n=== e2e_responses_store: %d checks, %d failed ===" % (len(RESULTS), failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
