#!/usr/bin/env python3
"""Mock OpenAI-compatible LLM worker for lua-router tests.

Pure stdlib (http.server, ThreadingHTTPServer). Implements only what the lua
router exercises: health, discovery, props/metrics, header echo and the
OpenAI-ish POST endpoints, including SSE streaming and injectable failures.

Environment knobs:
  MODEL      served model id (also --model, default test-model)
  PORT       listen port (also --port, default 18000)
  HOST       bind address (also --host, default 0.0.0.0)
  CHUNK_MS   delay between SSE chunks in ms (default 0)
  LATENCY_MS delay before responding to a completion (default 0)
  FAIL_MODE  no_retry_4xx | retryable_500 | retry_once_500
  FAIL_KEEP  for retry_once_500: keep failing after the 1st failure (default 0)

Streaming usage knobs (doc/gap-token-accounting.md). These exist so a test can
reproduce what the real engines actually do — an OpenAI-compatible backend sends
a usage frame only when the request asked for one — instead of always sending it:
  USAGE_MODE            always | on_request | never (default always, which is
                        what every pre-existing suite saw)
                        on_request: send the final usage frame only when
                                    stream_options.include_usage is truthy
  USAGE_ON_FINISH_CHUNK 1: attach usage to the chunk that also carries
                        finish_reason "stop" (the llama.cpp shape) instead of a
                        usage-only frame after it
  USAGE_DETAILS         1: put cached_tokens and reasoning_tokens into the usage
                        object, as SGLang and the thinking engines do
  REJECT_STREAM_OPTIONS 1: answer 400 quoting stream_options whenever a request
                        carries stream_options (an engine that never learned the
                        field)
  SSE_HEARTBEAT         1: interleave a ": ping" comment frame, which a strip-capable
                        pump must forward untouched
"""

import argparse
import json
import os
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {
    "model": os.environ.get("MODEL", "test-model"),
    "chunk_ms": float(os.environ.get("CHUNK_MS", 0) or 0),
    "latency_ms": float(os.environ.get("LATENCY_MS", 0) or 0),
    "fail_mode": os.environ.get("FAIL_MODE", "") or "",
    "started": time.time(),
    "requests": 0,
    "fail_once_used": False,
    # Streaming usage shape; see the module docstring for the contract.
    "usage_mode": (os.environ.get("USAGE_MODE", "always") or "always").lower(),
    "usage_on_finish_chunk": os.environ.get("USAGE_ON_FINISH_CHUNK", "") == "1",
    "usage_details": os.environ.get("USAGE_DETAILS", "") == "1",
    "reject_stream_options": os.environ.get("REJECT_STREAM_OPTIONS", "") == "1",
    "sse_heartbeat": os.environ.get("SSE_HEARTBEAT", "") == "1",
}
LOCK = threading.Lock()

CONTENT_TYPE_JSON = "application/json"


def env_float(name, default=0.0):
    try:
        return float(os.environ.get(name, default) or 0)
    except ValueError:
        return default


def now_ms():
    return int(time.time() * 1000)


class Handler(BaseHTTPRequestHandler):
    server_version = "MockLLMWorker/1.0"
    protocol_version = "HTTP/1.1"

    # ---------------------------------------------------------------- plumbing
    def log_message(self, fmt, *args):  # keep the test output readable
        sys.stderr.write("[mock %s] %s\n" % (STATE["model"], fmt % args))

    def _note_request(self, path):
        """One compact line per request on stdout (LR_MOCK_LOG=1).

        Lets a sticky-routing check count hits per instance from separate log
        files without parsing the access-log format.
        """
        if os.environ.get("LR_MOCK_LOG") == "1":
            sys.stdout.write("%s %s\n" % (self.command, path))
            sys.stdout.flush()

    def _read_body(self):
        length = self.headers.get("Content-Length")
        if length:
            try:
                raw = self.rfile.read(int(length))
            except (ValueError, OSError):
                return b"", None
        else:
            raw = b""
        if not raw:
            return raw, None
        try:
            return raw, json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return raw, None

    def _send(self, status, payload, ctype=CONTENT_TYPE_JSON, extra=None):
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (extra or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_text(self, status, text, ctype="text/plain; charset=utf-8", extra=None):
        self._send(status, text.encode(), ctype, extra)

    def _failure(self):
        """Apply FAIL_MODE. Returns True when a failure response was emitted."""
        mode = STATE["fail_mode"]
        if not mode:
            return False
        if mode == "no_retry_4xx":
            self._send(400, {"error": {"message": "mock non-retryable 400",
                                       "type": "invalid_request_error", "code": "MOCK_400"}})
            return True
        if mode == "retryable_500":
            self._send(500, {"error": {"message": "mock retryable 500",
                                       "type": "server_error", "code": "MOCK_500"}})
            return True
        if mode == "retry_once_500":
            with LOCK:
                already = STATE["fail_once_used"]
                if not already:
                    STATE["fail_once_used"] = True
            if not already:
                self._send(500, {"error": {"message": "mock first-call 500",
                                           "type": "server_error", "code": "MOCK_500"}})
                return True
            if os.environ.get("FAIL_KEEP") == "1":
                self._send(500, {"error": {"message": "mock sticky 500",
                                           "type": "server_error", "code": "MOCK_500"}})
                return True
        return False

    # --------------------------------------------------------------------- GET
    def do_GET(self):
        self._handle_get()

    def do_HEAD(self):
        self._handle_get()

    def _handle_get(self):
        with LOCK:
            STATE["requests"] += 1
        path = self.path.split("?", 1)[0]
        self._note_request(path)
        if path == "/health":
            self._send_text(200, "OK")
        elif path == "/health_generate":
            self._send_text(200, "OK")
        elif path == "/flush_cache":
            # Method guard: a router that pokes the cache with GET must be reported
            # as failing, not as succeeding against a lenient stub.
            self._send(405, {"error": {"message": "mock: flush_cache is POST only",
                                       "type": "method_not_allowed",
                                       "code": "METHOD_NOT_ALLOWED"}})
        elif path == "/v1/models":
            self._send(200, {"object": "list", "data": [
                {"id": STATE["model"], "object": "model", "created": int(STATE["started"]),
                 "owned_by": "local"}]})
        elif path in ("/server_info", "/get_server_info"):
            self._send(200, {
                "app_name": "mock-llm-worker",
                "version": "0.0.1-mock",
                "model_path": "/models/%s" % STATE["model"],
                "worker_count": 1,
                "tp_size": 1,
                "dp_size": 1,
                "max_total_num_tokens": 32768,
                "max_prefill_tokens": 8192,
                "chunked_prefill_size": 8192,
                "page_size": 1,
                "enable_metrics": True,
                "uptime_s": int(time.time() - STATE["started"]),
            })
        elif path in ("/model_info", "/get_model_info"):
            self._send(200, {
                "model_path": "/models/%s" % STATE["model"],
                "served_model_name": STATE["model"],
                "is_generation": True,
                "prefill_count": 1,
                "decode_count": 1,
                "tp_size": 1,
                "dp_size": 1,
            })
        elif path == "/props":
            # llama.cpp web-ui style server properties
            self._send(200, {
                "role": "mock",
                "model_path": "/models/%s" % STATE["model"],
                "model": STATE["model"],
                "humaneval_tokenization": False,
                "n_ctx": 8192,
                "n_gpu_layers": 999,
                "total_slots": 4,
                "slot_default": [{"id": 0, "n_ctx": 8192}, {"id": 1, "n_ctx": 8192},
                                 {"id": 2, "n_ctx": 8192}, {"id": 3, "n_ctx": 8192}],
                "add_bos_token": True,
                "tokenizer.ggml.pre": "default",
                "general.architecture": "qwen3moe",
                "build_info": "mock",
                "ui_config": {},
            })
        elif path == "/metrics":
            uptime = max(0.001, time.time() - STATE["started"])
            with LOCK:
                seen = STATE["requests"]
            lines = [
                "# HELP mock_uptime_seconds Process uptime",
                "# TYPE mock_uptime_seconds gauge",
                "mock_uptime_seconds %.3f" % uptime,
                "# HELP mock_requests_total Received requests",
                "# TYPE mock_requests_total counter",
                "mock_requests_total %d" % seen,
                "# HELP sglang:num_running_requests In-flight requests",
                "# TYPE sglang:num_running_requests gauge",
                'sglang:num_running_requests{model_name="%s"} 0' % STATE["model"],
                "# HELP sglang:token_usage Used KV cache fraction",
                "# TYPE sglang:token_usage gauge",
                "sglang:token_usage 0.00",
            ]
            self._send_text(200, "\n".join(lines) + "\n",
                            ctype="text/plain; version=0.0.4; charset=utf-8")
        elif path == "/identity":
            headers = {k.lower(): v for k, v in self.headers.items()}
            self._send(200, {
                "method": self.command,
                "path": self.path,
                "version": self.request_version,
                "headers": headers,
                "header_count": len(headers),
                "model": STATE["model"],
            })
        elif path == "/state":
            with LOCK:
                snapshot = dict(STATE)
            self._send(200, snapshot)
        elif path == "/reset":
            with LOCK:
                STATE["fail_once_used"] = False
                STATE["requests"] = 0
            self._send(200, {"status": "reset"})
        else:
            self._send(404, {"error": {"message": "mock: no route %s" % path,
                                       "type": "not_found", "code": "NOT_FOUND"}})

    # -------------------------------------------------------------------- POST
    def do_POST(self):
        with LOCK:
            STATE["requests"] += 1
        path = self.path.split("?", 1)[0]
        self._note_request(path)
        raw, body = self._read_body()
        if not isinstance(body, dict):
            body = {}
        if STATE["latency_ms"] > 0:
            time.sleep(STATE["latency_ms"] / 1000.0)
        if self._failure():
            return
        if (STATE["reject_stream_options"] and isinstance(body.get("stream_options"), dict)
                and path in ("/v1/chat/completions", "/v1/completions", "/v1/responses")):
            # The shape a vLLM/SGLang build without the field answers with, so a
            # gateway that injects it unconditionally sees a real refusal.
            self._send(400, {"error": {
                "message": "Streaming error: Unexpected value stream_options with "
                           "input {'include_usage': True}. Enable the feature first.",
                "type": "invalid_request_error", "code": "Bad Request"}})
            return

        if path == "/v1/chat/completions":
            self._chat_completions(body)
        elif path == "/v1/completions":
            self._completions(body)
        elif path == "/v1/embeddings":
            self._embeddings(body)
        elif path == "/v1/rerank":
            self._rerank(body)
        elif path == "/v1/classify":
            self._classify(body)
        elif path == "/v1/responses":
            self._responses(body)
        elif path in ("/generate", "/encode"):
            # stream/stream_options ride along so a /generate stream has the same
            # byte shape as /v1/completions (the gateway excludes /generate from
            # its usage injection; doc/gap-token-accounting.md 5).
            forwarded = {"prompt": body.get("text") or body.get("prompt") or "",
                         "model": body.get("model", STATE["model"])}
            if body.get("stream"):
                forwarded["stream"] = True
            if isinstance(body.get("stream_options"), dict):
                forwarded["stream_options"] = body["stream_options"]
            self._completions(forwarded)
        elif path == "/flush_cache":
            # SGLang's cache flush is a POST route; answering 200 here is what lets
            # the contract suite tell a real success apart from a 405-turned-error.
            self._send(200, {"success": True})
        else:
            self._send(404, {"error": {"message": "mock: no route %s" % path,
                                       "type": "not_found", "code": "NOT_FOUND"}})

    # -------------------------------------------------------- endpoint bodies
    def _echo_text(self, body):
        """Best-effort text echo used as generated content."""
        parts = []
        model = body.get("model") or STATE["model"]
        parts.append("echo[%s]" % model)
        messages = body.get("messages")
        if isinstance(messages, list):
            for msg in messages:
                if not isinstance(msg, dict):
                    continue
                content = msg.get("content")
                if isinstance(content, list):
                    content = " ".join(
                        str(seg.get("text", "")) for seg in content
                        if isinstance(seg, dict) and seg.get("type") == "text")
                if content:
                    parts.append("%s:%s" % (msg.get("role", "user"), content))
        prompt = body.get("prompt")
        if isinstance(prompt, list):
            prompt = " ".join(str(x) for x in prompt)
        if prompt:
            parts.append("prompt:" + str(prompt))
        return " ".join(parts)

    def _echo_headers(self):
        """Lowercased request headers as received — proves router forwarding and
        stripping without needing a GET /identity through the router."""
        return {k.lower(): v for k, v in self.headers.items()}

    def _completion_id(self):
        return "chatcmpl-" + uuid.uuid4().hex[:24]

    def _usage(self):
        usage = {"prompt_tokens": 1, "completion_tokens": 5, "total_tokens": 6}
        if STATE["usage_details"]:
            usage["prompt_tokens_details"] = {"cached_tokens": 1}
            usage["completion_tokens_details"] = {"reasoning_tokens": 2}
        return usage

    def _wants_usage(self, body):
        """Did the request ask for a usage frame?

        Mirrors the OpenAI-compatible engines: stream_options.include_usage is
        the switch, and without it the stream carries no usage at all. An
        explicit false counts as "did not ask".
        """
        options = body.get("stream_options")
        if not isinstance(options, dict):
            return False
        return bool(options.get("include_usage"))

    def _stream_sends_usage(self, body):
        mode = STATE["usage_mode"]
        if mode == "never":
            return False
        if mode == "on_request":
            return self._wants_usage(body)
        return True

    def _chat_completions(self, body):
        created = int(time.time())
        cid = self._completion_id()
        text = self._echo_text(body)
        if body.get("stream"):
            if not self._start_sse():
                return
            pieces = ["echo[", str(body.get("model") or STATE["model"]), "] ", text, " done"]
            pieces = [p for p in pieces if p != ""]
            while len(pieces) < 5:
                pieces.append(".")
            # A comment frame: SSE keeps them out of the data stream, and a pump
            # that drops "unrecognised" frames would eat the client's heartbeat.
            if STATE["sse_heartbeat"] and not self._sse_write(": ping\n\n"):
                return
            # The default (always) keeps the historical byte shape -- usage on the
            # closing chunk next to finish_reason -- so every pre-existing suite
            # sees the stream it has always seen. on_request / never model what a
            # real OpenAI-compatible engine does, and with USAGE_ON_FINISH_CHUNK
            # the counts ride the finish chunk the way llama.cpp sends them.
            sends_usage = self._stream_sends_usage(body)
            for idx, piece in enumerate(pieces):
                chunk = {
                    "id": cid, "object": "chat.completion.chunk", "created": created,
                    "model": body.get("model") or STATE["model"],
                    "choices": [{"index": 0,
                                 "delta": ({"role": "assistant", "content": piece} if idx == 0
                                 else {"content": piece}),
                                 "finish_reason": None}],
                }
                if not self._sse_write("data: %s\n\n" % json.dumps(chunk)):
                    return
                if STATE["chunk_ms"] > 0:
                    time.sleep(STATE["chunk_ms"] / 1000.0)
            last = {
                "id": cid, "object": "chat.completion.chunk", "created": created,
                "model": body.get("model") or STATE["model"],
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                "echo_body": body,
            }
            # The llama.cpp shape (USAGE_ON_FINISH_CHUNK=1) and the historical
            # default both put the counts on the closing chunk; on_request sends
            # the OpenAI shape instead, a usage-only frame with empty choices.
            on_finish_chunk = (STATE["usage_mode"] == "always"
                               or STATE["usage_on_finish_chunk"])
            if sends_usage and on_finish_chunk:
                # The gateway must keep this frame -- dropping it would eat the
                # finish_reason the client needs -- while still reading counts.
                last["usage"] = self._usage()
            if not self._sse_write("data: %s\n\n" % json.dumps(last)):
                return
            if sends_usage and not on_finish_chunk:
                closing = {
                    "id": cid, "object": "chat.completion.chunk", "created": created,
                    "model": body.get("model") or STATE["model"],
                    "choices": [], "usage": self._usage(),
                }
                if not self._sse_write("data: %s\n\n" % json.dumps(closing)):
                    return
            self._sse_write("data: [DONE]\n\n")
            self._sse_finish()
            return
        payload = {
            "id": cid, "object": "chat.completion", "created": created,
            "model": body.get("model") or STATE["model"],
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": text, "reasoning_content": ""},
                "finish_reason": "stop",
            }],
            "usage": self._usage(),
            # What the router actually forwarded: proves model rewrites,
            # reasoning_effort injection and ctx clamps without a /identity probe.
            "echo_body": body,
            "echo_headers": self._echo_headers(),
        }
        self._send(200, payload)

    def _completions(self, body):
        text = self._echo_text(body)
        if body.get("stream"):
            self._completions_stream(body, text)
            return
        prompt = body.get("prompt")
        n = 1
        if isinstance(prompt, list):
            n = max(1, len(prompt))
        self._send(200, {
            "id": "cmpl-" + uuid.uuid4().hex[:24], "object": "text_completion",
            "created": int(time.time()), "model": body.get("model") or STATE["model"],
            "choices": [{"index": i, "text": text, "finish_reason": "stop", "logprobs": None}
                        for i in range(n)],
            "usage": self._usage(),
            "echo_body": body,
            "echo_headers": self._echo_headers(),
        })

    def _completions_stream(self, body, text):
        """POST /v1/completions?stream — the text_completion.chunk shape, with the
        same usage contract as the chat stream (the caller in forward() injects
        stream_options for this route too)."""
        if not self._start_sse():
            return
        cid = "cmpl-" + uuid.uuid4().hex[:24]
        created = int(time.time())
        model = body.get("model") or STATE["model"]
        for idx, piece in enumerate(["echo[", str(model), "] ", text, " done"]):
            if piece == "":
                continue
            chunk = {"id": cid, "object": "text_completion", "created": created,
                     "model": model,
                     "choices": [{"index": 0, "text": piece,
                                  "finish_reason": None, "logprobs": None}]}
            if not self._sse_write("data: %s\n\n" % json.dumps(chunk)):
                return
            if STATE["chunk_ms"] > 0:
                time.sleep(STATE["chunk_ms"] / 1000.0)
        last = {"id": cid, "object": "text_completion", "created": created,
                "model": model,
                "choices": [{"index": 0, "text": "", "finish_reason": "stop",
                             "logprobs": None}],
                "echo_body": body}
        sends_usage = self._stream_sends_usage(body)
        on_finish_chunk = (STATE["usage_mode"] == "always"
                           or STATE["usage_on_finish_chunk"])
        if sends_usage and on_finish_chunk:
            last["usage"] = self._usage()
        if not self._sse_write("data: %s\n\n" % json.dumps(last)):
            return
        if sends_usage and not on_finish_chunk:
            closing = {"id": cid, "object": "text_completion", "created": created,
                       "model": model, "choices": [], "usage": self._usage()}
            if not self._sse_write("data: %s\n\n" % json.dumps(closing)):
                return
        self._sse_write("data: [DONE]\n\n")
        self._sse_finish()

    def _embeddings(self, body):
        inp = body.get("input")
        items = inp if isinstance(inp, list) else [inp]
        data = []
        for i, item in enumerate(items):
            dim = 8
            seed = len(str(item)) % dim
            vec = [0.0] * dim
            vec[seed] = 1.0
            data.append({"object": "embedding", "index": i, "embedding": vec})
        self._send(200, {
            "object": "list", "data": data,
            "model": body.get("model") or STATE["model"],
            "usage": {"prompt_tokens": 1, "total_tokens": 1},
        })

    def _rerank(self, body):
        docs = body.get("documents") or []
        results = [{"index": i, "relevance_score": round(1.0 / (i + 2), 6),
                    "document": {"text": d}} for i, d in enumerate(docs)]
        self._send(200, {
            "id": "rerank-" + uuid.uuid4().hex[:16], "model": body.get("model") or STATE["model"],
            "results": results, "usage": self._usage(),
        })

    def _classify(self, body):
        text = body.get("input") or body.get("text") or ""
        labels = body.get("labels") or ["positive", "negative"]
        probs = [round(1.0 / len(labels), 6) for _ in labels]
        self._send(200, {
            "id": "classify-" + uuid.uuid4().hex[:16],
            "model": body.get("model") or STATE["model"],
            "labels": labels, "probs": probs,
            "classification": {"label": labels[0], "probs": probs},
            "data": [{"label": labels[0], "probs": probs, "text": str(text)}],
            "usage": self._usage(),
        })

    def _responses(self, body):
        text = self._echo_text(body)
        if body.get("stream"):
            self._responses_stream(body, text)
            return
        rid = "resp_" + uuid.uuid4().hex[:24]
        inp = body.get("input")
        self._send(200, {
            "id": rid, "object": "response", "created_at": int(time.time()),
            "status": "completed", "model": body.get("model") or STATE["model"],
            "output": [{"type": "message", "id": "msg_" + uuid.uuid4().hex[:12],
                        "role": "assistant",
                        "content": [{"type": "output_text", "text": text, "annotations": []}]}],
            "output_text": text, "usage": self._usage(),
            "error": None, "incomplete_details": None, "instructions": None,
            "parallel_tool_calls": True, "previous_response_id": None,
            "store": True, "temperature": body.get("temperature", 1.0),
            "tool_choice": "auto", "tools": [], "truncation": "disabled",
            "user": None, "metadata": {}, "service_tier": "default",
            "echo": inp,
        })

    def _responses_stream(self, body, text):
        """POST /v1/responses?stream — the real Responses SSE shape: every frame
        carries an `event:` field, so a gateway that strips usage frames must
        leave them alone (they are protocol), including the completed event that
        carries the usage object."""
        if not self._start_sse():
            return
        rid = "resp_" + uuid.uuid4().hex[:24]

        def doc(status, usage=None):
            payload = {
                "id": rid, "object": "response", "created_at": int(time.time()),
                "status": status, "model": body.get("model") or STATE["model"],
                "output": [{"type": "message", "id": "msg_" + rid, "role": "assistant",
                            "content": [{"type": "output_text", "text": text,
                                         "annotations": []}]}],
                "output_text": text,
            }
            if usage is not None:
                payload["usage"] = usage
            return payload

        def event(name, value):
            return self._sse_write("event: %s\ndata: %s\n\n"
                                   % (name, json.dumps(value)))

        if not event("response.created", {"type": "response.created",
                                         "response": doc("in_progress")}):
            return self._sse_finish()
        if not event("response.output_text.delta",
                     {"type": "response.output_text.delta", "delta": text}):
            return self._sse_finish()
        sends_usage = self._stream_sends_usage(body)
        usage = self._usage() if sends_usage else None
        if usage is not None:
            # The Responses spelling of the details objects.
            if STATE["usage_details"]:
                usage = {"input_tokens": usage["prompt_tokens"],
                         "output_tokens": usage["completion_tokens"],
                         "input_tokens_details": {"cached_tokens": 1},
                         "output_tokens_details": {"reasoning_tokens": 2}}
        if not event("response.completed", {"type": "response.completed",
                                            "response": doc("completed", usage)}):
            return self._sse_finish()
        self._sse_write("data: [DONE]\n\n")
        self._sse_finish()

    # ---------------------------------------------------------------- SSE bits
    def _start_sse(self):
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("X-Accel-Buffering", "no")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            return True
        except OSError:
            return False

    def _sse_write(self, text):
        data = text.encode()
        try:
            self.wfile.write(b"%x\r\n" % len(data))
            self.wfile.write(data)
            self.wfile.write(b"\r\n")
            self.wfile.flush()
            return True
        except OSError:
            return False

    def _sse_finish(self):
        try:
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except OSError:
            pass


def main():
    parser = argparse.ArgumentParser(description="Mock OpenAI-compatible LLM worker")
    parser.add_argument("--model", default=STATE["model"])
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", 18000)))
    parser.add_argument("--host", default=os.environ.get("HOST", "0.0.0.0"))
    parser.add_argument("--chunk-ms", type=float, default=None)
    parser.add_argument("--latency-ms", type=float, default=None)
    parser.add_argument("--fail-mode", default=None,
                        choices=[None, "no_retry_4xx", "retryable_500", "retry_once_500"])
    args = parser.parse_args()

    STATE["model"] = args.model
    STATE["chunk_ms"] = args.chunk_ms if args.chunk_ms is not None else env_float("CHUNK_MS")
    STATE["latency_ms"] = (args.latency_ms if args.latency_ms is not None
                           else env_float("LATENCY_MS"))
    if args.fail_mode:
        STATE["fail_mode"] = args.fail_mode

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    sys.stderr.write("[mock] model=%s listening on %s:%s fail_mode=%s chunk_ms=%s\n" % (
        STATE["model"], args.host, args.port, STATE["fail_mode"] or "-", STATE["chunk_ms"]))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
