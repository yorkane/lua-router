#!/usr/bin/env python3
"""Token accounting over a real container (doc/gap-token-accounting.md).

The gate this suite owns is the one no pure-Lua unit test can reach: whether the
gateway really asks an OpenAI-compatible backend for a usage frame, really reads
it, and really removes it again from the client's stream. The unit tests assert
the decisions (merge_top_object, sse_split, sse_event_droppable); this asserts
the bytes that reach the client and the two metric families they feed.

--------------------------------------------------------------------------------
EXPECTED CHECKS: 62, in six scenarios. The gate (root runs it serially via
test/final_gates.sh, GATE_ONLY=e2e_token_accounting) must report "62 checks, 0
failed". A different number means a scenario was skipped or a check was dropped.

 1. scenario_inject_and_strip ............ 24 checks
    A client that asked for nothing: the stream answers 200 and ends with [DONE];
    every content byte it was owed still arrives; no "usage" appears anywhere in
    what the client sees; the kept closing chunk still carries the worker's
    echo_body (proof the injection went upstream while its result did not); the
    frame count equals the un-injected stream; the content type stayed
    text/event-stream; the request-log row carries the backend's own
    prompt_tokens/completion_tokens, is accounted as a chat stream, and is not
    flagged estimated; smg_router_usage_injection_total{result="stripped"}
    advanced by exactly one; the echoed forwarded body names
    stream_options.include_usage. Then the client that DID set
    stream_options.include_usage keeps its frame verbatim with the counts inside,
    exactly one [DONE], an exact row, and no injection charged for it. Then a
    client that sent include_usage:false: the stream completes, the frame the
    gateway asked for is stripped anyway, and its row is still exact.

 2. scenario_finish_chunk ................. 9 checks
    A llama.cpp style worker (usage fused onto the chunk carrying
    finish_reason "stop"): that closing chunk survives for the client with its
    usage object intact, the stream ends, the counts were still read, nothing was
    flagged estimated, and the injection reports result="passed_through".
    Refusing to eat the client's finish_reason is the rule under test.

 3. scenario_backend_without_the_field ... 10 checks
    USAGE_MODE=never: the injection costs the client nothing (200, [DONE], no
    usage bytes) and the row falls back to the byte/4 estimate with
    tokens_estimated true. REJECT_STREAM_OPTIONS=1 (an engine that 400s on the
    field): the first request discovers the refusal and its body quotes
    stream_options, exactly one WARN line is emitted, and the next two requests
    flow un-injected with no further WARN (the sticky hold-off; no retry).

 4. scenario_detail_metrics ............... 6 checks
    USAGE_DETAILS=1 over two streams: smg_router_tokens_total carries all four
    token_type series with the backend's numbers -- prompt, completion, cached
    (prompt_tokens_details.cached_tokens) and reasoning
    (completion_tokens_details.reasoning_tokens), and both streams report
    result="stripped".

 5. scenario_routes ....................... 6 checks
    /v1/completions is injected and stripped with an exact endpoint=completions
    row; /generate (SGLang-native) is never injected and still streams; a
    /v1/responses stream gains exact accounting while its event: response.completed
    frame -- the protocol frame that carries the usage -- is left in place.

 6. scenario_incremental_delivery ......... 7 checks
    The mock sleeps 150 ms between chunks and interleaves a ": ping" comment
    frame: the first byte must arrive well before the body is complete (the
    frame-boundary buffering the stripper adds must not degrade into buffering
    the response), the stripped stream still ends with [DONE], carries the
    heartbeat through and reports no usage frame, the buffered non-stream row on
    the same instance is accounted exactly, the injection counter stays where
    the stream left it, and the container log is free of lua errors.

Byte-level pass-through of everything that is not a usage frame (heartbeats,
content deltas, /v1/responses event: frames) is asserted here over a real
container and decided in unit section 6 of test/unit/test_integration.lua.

Run:  python3 test/integration/e2e_token_accounting.py     (needs lua-router:integration)
"""
import json
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (free_port, http, check, start_mock, start_router, logs,
                  stop_router, wait_ready, chat, cleanup, RESULTS, RUN)

USAGE_MODEL = "alpha"
# The mock's own usage object (test/mock_llm_worker.py _usage): prompt 1,
# completion 5; USAGE_DETAILS=1 adds cached 1 and reasoning 2.
BACKEND_PROMPT = 1
BACKEND_COMPLETION = 5
BACKEND_CACHED = 1
BACKEND_REASONING = 2
# The chat stream's un-injected shape: 5 content pieces, one closing chunk,
# one [DONE] sentinel.
CHAT_FRAMES_UNINJECTED = 7


def raw_stream(port, payload, timeout=15):
    """POST once and hand back the exact response bytes.

    urllib is unusable here: the whole point is what the client sees at frame
    level, so the body must not be normalised by a helper.
    """
    data = payload.encode() if isinstance(payload, str) else json.dumps(payload).encode()
    sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    try:
        sock.sendall(("POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\n"
                      "Content-Type: application/json\r\nContent-Length: %d\r\n\r\n"
                      % len(data)).encode() + data)
        chunks = []
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                piece = sock.recv(65536)
            except OSError:
                break
            if not piece:
                break
            chunks.append(piece)
            if b"[DONE]" in b"".join(chunks):
                break
    finally:
        sock.close()
    raw = b"".join(chunks)
    head, _, body = raw.partition(b"\r\n\r\n")
    status = 0
    if head.startswith(b"HTTP/"):
        try:
            status = int(head.split(b" ", 2)[1])
        except Exception:
            status = 0
    return status, head.decode("utf-8", "replace"), body.decode("utf-8", "replace")


def sse_data(body):
    """The data: payloads of an SSE body, in order, [DONE] included."""
    out = []
    for line in body.replace("\r\n", "\n").split("\n"):
        if line.startswith("data:"):
            out.append(line[5:].lstrip())
    return out


def parsed_frames(body):
    """Decoded data: payloads of an SSE body, in order; [DONE]/undecodable skipped."""
    out = []
    for f in sse_data(body):
        if f == "[DONE]":
            continue
        try:
            doc = json.loads(f)
        except Exception:
            continue
        if isinstance(doc, dict):
            out.append(doc)
    return out


def has_usage_frame(body):
    """True when a data frame reports tokens to the client.

    Substring probes are unusable here: the worker echoes the forwarded request
    into the closing chunk's echo_body, and on the injected path that forwarded
    body legitimately names stream_options.include_usage -- the substring
    "usage" inside that key is not a usage report. What a client that did not
    opt in must not see is a frame whose own object carries a usage (or
    usage_metadata) member, and that is what this asks.
    """
    return any(("usage" in doc or "usage_metadata" in doc)
               for doc in parsed_frames(body))


def worker_row(port, needle=None):
    """The newest request-log row for a worker whose url contains `needle`."""
    st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/logs?limit=200" % port)
    if st != 200:
        return {}
    rows = json.loads(body).get("requests", [])
    if needle:
        rows = [r for r in rows if needle in (r.get("worker") or "")]
    return rows[-1] if rows else {}


def metric(port, family, labels=None):
    """Sum of one counter family's series, optionally filtered by label substrings."""
    st, text, _ = http("GET", "http://127.0.0.1:%d/metrics" % port)
    if st != 200:
        return None
    total = 0.0
    found = False
    for line in text.split("\n"):
        line = line.strip()
        if not line or line.startswith("#") or not line.startswith(family):
            continue
        rest = line[len(family):]
        if rest and rest[0] not in " {":
            continue
        if labels:
            series = rest.split("}", 1)[0]
            if not series.startswith("{") or not all(sub in series for sub in labels):
                continue
        try:
            total += float(line.rsplit(" ", 1)[1])
            found = True
        except Exception:
            continue
    return total if found else 0.0


def tokens_of(port, model, kind):
    return metric(port, "smg_router_tokens_total",
                  ['model="%s"' % model, 'token_type="%s"' % kind])


def injection_of(port, model, result):
    return metric(port, "smg_router_usage_injection_total",
                  ['model="%s"' % model, 'result="%s"' % result])


# start_mock runs the worker as a host process inheriting os.environ, and
# start_router only forwards its dict to the container -- so the knobs that
# configure the mock have to be set here as well, or every scenario would
# silently run the mock's defaults.
MOCK_KNOBS = ("USAGE_MODE", "USAGE_ON_FINISH_CHUNK", "USAGE_DETAILS",
              "REJECT_STREAM_OPTIONS", "SSE_HEARTBEAT", "CHUNK_MS")


def start_mock_env(port, env):
    """start_mock with the scenario's mock-side knobs exported while it boots."""
    saved = {}
    for k in MOCK_KNOBS:
        if k in env:
            saved[k] = os.environ.get(k)
            os.environ[k] = str(env[k])
    try:
        start_mock(port, USAGE_MODEL)
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def chat_stream(port, content, extra=None):
    payload = {"model": USAGE_MODEL, "stream": True,
               "messages": [{"role": "user", "content": content}]}
    payload.update(extra or {})
    return raw_stream(port, payload)


# --------------------------------------------------------------------------
def scenario_inject_and_strip():
    """1: the steady state for a client that asked for nothing, plus the two
    clients whose own stream_options must be honoured."""
    pa = free_port()
    env = {"SMG_POLICY": "round_robin",
           "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
           "SMG_DISABLE_RETRIES": "1",
           "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa,
           "USAGE_MODE": "on_request"}
    start_mock_env(pa, env)
    name = "lr-tokacc-" + RUN
    port = start_router(env, name)
    check("[inject] worker healthy", wait_ready(port, 1), logs(name))
    before = injection_of(port, USAGE_MODEL, "stripped")

    st, head, body = chat_stream(port, "accounting probe")
    frames = sse_data(body)
    reassembled = "".join(
        json.loads(f).get("choices", [{}])[0].get("delta", {}).get("content", "")
        for f in frames if f != "[DONE]")
    check("[inject] the stream answers 200 and ends with [DONE]",
          st == 200 and frames and frames[-1] == "[DONE]", "%s %r" % (st, frames[:2]))
    check("[inject] every content byte the client was owed still arrives",
          reassembled.startswith("echo[") and reassembled.endswith(" done"),
          repr(reassembled))
    check("[inject] no usage reaches a client that did not ask for it",
          not has_usage_frame(body), body[-400:])
    check("[inject] the frame count equals the un-injected stream",
          len(frames) == CHAT_FRAMES_UNINJECTED, "%d %r" % (len(frames), frames[-2:]))
    check("[inject] the response stayed text/event-stream",
          "text/event-stream" in head.lower(), head[:200])
    # The worker only emits a usage frame when the forwarded body asked for one
    # (USAGE_MODE=on_request), so a kept closing chunk that carries its echo_body
    # is direct proof the injection went upstream while its result did not.
    closing = [f for f in frames if '"echo_body"' in f]
    check("[inject] the kept closing chunk still carries the worker's echo_body",
          len(closing) == 1, "%d %r" % (len(closing), frames[-2:]))
    echoed = json.loads(closing[0]).get("echo_body", {}) if closing else {}
    check("[inject] the backend was asked: stream_options.include_usage arrived",
          echoed.get("stream_options", {}).get("include_usage") is True,
          json.dumps(echoed)[:220])

    row = worker_row(port, "127.0.0.1:%d" % pa)
    check("[inject] the row carries the backend's prompt_tokens",
          row.get("prompt_tokens") == BACKEND_PROMPT, json.dumps(row)[:250])
    check("[inject] the row carries the backend's completion_tokens",
          row.get("completion_tokens") == BACKEND_COMPLETION, json.dumps(row)[:250])
    check("[inject] an injected stream is not flagged estimated",
          row.get("tokens_estimated") in (False, None), json.dumps(row)[:250])
    check("[inject] the row is accounted as a chat stream",
          row.get("stream") is True and row.get("endpoint") == "chat",
          json.dumps(row)[:250])
    after = injection_of(port, USAGE_MODEL, "stripped")
    check("[inject] smg_router_usage_injection_total{result=\"stripped\"} grew by one",
          before is not None and after is not None and after - before == 1,
          "before=%s after=%s" % (before, after))
    check("[inject] the token family took the backend's counts, not an estimate",
          tokens_of(port, USAGE_MODEL, "completion") == BACKEND_COMPLETION,
          tokens_of(port, USAGE_MODEL, "completion"))

    # --- the client that asked for the frame keeps it
    st, head, body = chat_stream(port, "keep mine",
                                 {"stream_options": {"include_usage": True}})
    frames = sse_data(body)
    check("[client-usage] an opted-in client keeps its usage frame",
          st == 200 and any('"usage"' in f for f in frames), "%s %r" % (st, frames[-2:]))
    check("[client-usage] the kept frame carries the counts",
          any((doc.get("usage") or {}).get("completion_tokens") == BACKEND_COMPLETION
              for doc in parsed_frames(body)),
          frames[-2:] if frames else [])
    check("[client-usage] exactly one [DONE] survives",
          sum(1 for f in frames if f == "[DONE]") == 1, frames[-2:])
    row = worker_row(port, "127.0.0.1:%d" % pa)
    check("[client-usage] that row is accounted exactly too",
          row.get("prompt_tokens") == BACKEND_PROMPT
          and row.get("completion_tokens") == BACKEND_COMPLETION, json.dumps(row)[:250])
    check("[client-usage] the stream still ends with [DONE]",
          frames and frames[-1] == "[DONE]", frames[-1:] if frames else [])
    after2 = injection_of(port, USAGE_MODEL, "stripped")
    check("[client-usage] an opted-in request is not counted as an injection",
          after2 == after, "after=%s after2=%s" % (after, after2))

    # --- the client that explicitly refused the frame
    st, head, body = chat_stream(port, "no usage",
                                 {"stream_options": {"include_usage": False}})
    frames = sse_data(body)
    check("[client-usage-false] the stream still completes",
          st == 200 and frames and frames[-1] == "[DONE]", "%s %r" % (st, frames[-2:]))
    check("[client-usage-false] the frame the gateway asked for is stripped",
          not has_usage_frame(body), body[-300:])
    row = worker_row(port, "127.0.0.1:%d" % pa)
    check("[client-usage-false] the row is still exact",
          row.get("completion_tokens") == BACKEND_COMPLETION, json.dumps(row)[:250])

    check("[inject] no lua errors", "lua entry thread aborted" not in logs(name),
          logs(name)[-400:])
    stop_router(name)


# --------------------------------------------------------------------------
def scenario_finish_chunk():
    """2: usage fused onto the closing chunk must keep the chunk for the client."""
    pa = free_port()
    env = {"SMG_POLICY": "round_robin",
           "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
           "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa,
           "USAGE_MODE": "on_request",
           "USAGE_ON_FINISH_CHUNK": "1"}
    start_mock_env(pa, env)
    name = "lr-tokfin-" + RUN
    port = start_router(env, name)
    check("[finish-chunk] worker healthy", wait_ready(port, 1), logs(name))
    st, head, body = chat_stream(port, "fused usage")
    frames = sse_data(body)
    closing = [doc for doc in parsed_frames(body)
               if (doc.get("choices") or [{}])[0].get("finish_reason") == "stop"]
    check("[finish-chunk] the closing chunk survives for the client",
          st == 200 and len(closing) == 1, "%s %r" % (st, frames[-2:]))
    check("[finish-chunk] it keeps the usage object it arrived with",
          bool(closing) and (closing[0].get("usage") or {}).get("completion_tokens")
          == BACKEND_COMPLETION, closing[:1])
    check("[finish-chunk] the stream ends with [DONE]",
          frames and frames[-1] == "[DONE]", frames[-1:] if frames else [])
    row = worker_row(port, "127.0.0.1:%d" % pa)
    check("[finish-chunk] the counts were still read off that frame",
          row.get("prompt_tokens") == BACKEND_PROMPT
          and row.get("completion_tokens") == BACKEND_COMPLETION, json.dumps(row)[:250])
    check("[finish-chunk] nothing was flagged estimated",
          row.get("tokens_estimated") in (False, None), json.dumps(row)[:250])
    check("[finish-chunk] the injection reports passed_through",
          injection_of(port, USAGE_MODEL, "passed_through") == 1,
          injection_of(port, USAGE_MODEL, "passed_through"))
    check("[finish-chunk] nothing was reported stripped (the frame is not ours)",
          injection_of(port, USAGE_MODEL, "stripped") == 0,
          injection_of(port, USAGE_MODEL, "stripped"))
    check("[finish-chunk] no lua errors", "lua entry thread aborted" not in logs(name),
          logs(name)[-400:])
    stop_router(name)


# --------------------------------------------------------------------------
def scenario_backend_without_the_field():
    """3: a backend that never sends usage (injection must be free) and a backend
    that refuses the field (first request pays, the rest do not)."""
    pa = free_port()
    env = {"SMG_POLICY": "round_robin",
           "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
           "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa,
           "USAGE_MODE": "never"}
    start_mock_env(pa, env)
    name = "lr-toknone-" + RUN
    port = start_router(env, name)
    check("[no-usage-backend] worker healthy", wait_ready(port, 1), logs(name))
    st, head, body = chat_stream(port, "no usage at all")
    frames = sse_data(body)
    check("[no-usage-backend] the injection costs the client nothing",
          st == 200 and frames and frames[-1] == "[DONE]", "%s %r" % (st, frames[-2:]))
    check("[no-usage-backend] the stream carries no usage frame",
          not has_usage_frame(body), body[-300:])
    row = worker_row(port, "127.0.0.1:%d" % pa)
    check("[no-usage-backend] the row falls back to the estimate and says so",
          row.get("tokens_estimated") is True and (row.get("completion_tokens") or 0) > 0,
          json.dumps(row)[:250])
    stop_router(name)

    pb = free_port()
    env = {"SMG_POLICY": "round_robin",
           "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
           "SMG_DISABLE_RETRIES": "1",
           "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pb,
           "USAGE_MODE": "on_request",
           "REJECT_STREAM_OPTIONS": "1"}
    start_mock_env(pb, env)
    name = "lr-tokrej-" + RUN
    port = start_router(env, name)
    check("[reject] worker healthy", wait_ready(port, 1), logs(name))
    st, head, body = chat_stream(port, "first")
    check("[reject] the first request discovers the refusal",
          st == 400 and "stream_options" in body, "%s %s" % (st, body[:200]))
    check("[reject] the refusal is WARNed about once",
          logs(name).count("answered 400 to the ") == 1,
          [ln for ln in logs(name).split("\n") if "answered 400" in ln][:3])
    st, head, body = chat_stream(port, "second")
    check("[reject] the next request flows un-injected",
          st == 200 and sse_data(body)[-1:] == ["[DONE]"], "%s %s" % (st, body[:200]))
    st, head, body = chat_stream(port, "third")
    check("[reject] and the one after that", st == 200, st)
    check("[reject] no further WARN lines were emitted",
          logs(name).count("answered 400 to the ") <= 1,
          [ln for ln in logs(name).split("\n") if "answered 400" in ln][:3])
    stop_router(name)


# --------------------------------------------------------------------------
def scenario_detail_metrics():
    """4: the two detail counts the request log has always had, now on /metrics."""
    pa = free_port()
    env = {"SMG_POLICY": "round_robin",
           "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
           "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa,
           "USAGE_MODE": "on_request",
           "USAGE_DETAILS": "1"}
    start_mock_env(pa, env)
    name = "lr-tokdet-" + RUN
    port = start_router(env, name)
    check("[details] worker healthy", wait_ready(port, 1), logs(name))
    for _ in range(2):
        chat_stream(port, "details probe")
    kinds = dict((k, tokens_of(port, USAGE_MODEL, k))
                 for k in ("prompt", "completion", "cached", "reasoning"))
    check("[details] prompt series is the backend's count x2",
          kinds["prompt"] == BACKEND_PROMPT * 2, kinds)
    check("[details] completion series is the backend's count x2",
          kinds["completion"] == BACKEND_COMPLETION * 2, kinds)
    check("[details] cached series is the backend's cached_tokens x2",
          kinds["cached"] == BACKEND_CACHED * 2, kinds)
    check("[details] reasoning series is the backend's reasoning_tokens x2",
          kinds["reasoning"] == BACKEND_REASONING * 2, kinds)
    check("[details] every stream reported stripped",
          injection_of(port, USAGE_MODEL, "stripped") == 2,
          injection_of(port, USAGE_MODEL, "stripped"))
    stop_router(name)


# --------------------------------------------------------------------------
def scenario_routes():
    """5: injection is scoped to the OpenAI-shaped routes and leaves /generate alone."""
    pa = free_port()
    env = {"SMG_POLICY": "round_robin",
           "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
           "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa,
           "USAGE_MODE": "on_request"}
    start_mock_env(pa, env)
    name = "lr-tokrte-" + RUN
    port = start_router(env, name)
    check("[routes] worker healthy", wait_ready(port, 1), logs(name))

    st, body, _ = http("POST", "http://127.0.0.1:%d/v1/completions" % port,
                       {"model": USAGE_MODEL, "prompt": "accounting", "stream": True})
    frames = sse_data(body)
    check("[routes] completions stream is injected and stripped",
          st == 200 and frames[-1:] == ["[DONE]"] and not has_usage_frame(body),
          "%s %r" % (st, frames[-2:]))
    row = worker_row(port, "127.0.0.1:%d" % pa)
    check("[routes] the completions row is exact",
          row.get("endpoint") == "completions"
          and row.get("completion_tokens") == BACKEND_COMPLETION, json.dumps(row)[:250])

    st, raw, _ = http("POST", "http://127.0.0.1:%d/generate" % port,
                      {"model": USAGE_MODEL, "text": "no injection here",
                       "stream": True})
    check("[routes] /generate stream completes untouched", st == 200,
          "%s %s" % (st, str(raw)[:150]))

    st, raw, _ = http("POST", "http://127.0.0.1:%d/v1/responses" % port,
                      {"model": USAGE_MODEL, "input": "responses accounting",
                       "stream": True})
    row = worker_row(port, "127.0.0.1:%d" % pa)
    check("[routes] the responses stream is accounted exactly",
          st == 200 and row.get("prompt_tokens") == BACKEND_PROMPT
          and row.get("completion_tokens") == BACKEND_COMPLETION
          and row.get("endpoint") == "responses",
          "%s %s" % (st, json.dumps(row)[:250]))
    check("[routes] its response.completed event is not stripped",
          "event: response.completed" in str(raw) and "usage" in str(raw),
          str(raw)[-200:])
    stop_router(name)


# --------------------------------------------------------------------------
def scenario_incremental_delivery():
    """6: the stripper must not turn a streaming response into a buffered one."""
    pa = free_port()
    env = {"SMG_POLICY": "round_robin",
           "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
           "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa,
           "USAGE_MODE": "on_request",
           "CHUNK_MS": "150",
           # a comment frame interleaved with the content chunks: the stripper
           # buffers frames, and anything that is not a usage frame -- the
           # heartbeat included -- has to reach the client untouched.
           "SSE_HEARTBEAT": "1"}
    start_mock_env(pa, env)
    name = "lr-tokinc-" + RUN
    port = start_router(env, name)
    check("[incremental] worker healthy", wait_ready(port, 1), logs(name))

    payload = json.dumps({"model": USAGE_MODEL, "stream": True,
                          "messages": [{"role": "user", "content": "pace probe"}]}).encode()
    sock = socket.create_connection(("127.0.0.1", port), timeout=15)
    arrivals = []
    received = b""
    try:
        sock.sendall(("POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\n"
                      "Content-Type: application/json\r\nContent-Length: %d\r\n\r\n"
                      % len(payload)).encode() + payload)
        deadline = time.time() + 15
        while time.time() < deadline:
            try:
                piece = sock.recv(65536)
            except OSError:
                break
            if not piece:
                break
            if not arrivals:
                arrivals.append(time.time())
            received += piece
            if b"[DONE]" in received:
                arrivals.append(time.time())
                break
    finally:
        sock.close()
    spread = (arrivals[1] - arrivals[0]) if len(arrivals) == 2 else -1
    check("[incremental] the first byte arrives before the body is complete",
          spread >= 0.45, "first-to-last=%.3fs (expect >=0.45)" % spread)
    seen = received.decode("utf-8", "replace")
    check("[incremental] the stripped stream ends with [DONE], keeps the heartbeat, "
          "carries no usage frame",
          b"[DONE]" in received and ": ping" in seen and not has_usage_frame(seen),
          received[-200:])

    st, body2, _ = chat(port, USAGE_MODEL, "buffered accounting")
    row = worker_row(port, "127.0.0.1:%d" % pa)
    check("[incremental] the buffered row is accounted exactly",
          st == 200 and row.get("prompt_tokens") == BACKEND_PROMPT
          and row.get("completion_tokens") == BACKEND_COMPLETION
          and row.get("stream") is False, json.dumps(row)[:250])
    check("[incremental] the buffered path records no injection",
          injection_of(port, USAGE_MODEL, "stripped") == 1,
          injection_of(port, USAGE_MODEL, "stripped"))
    check("[incremental] the estimate share stayed clean for the stream",
          row.get("tokens_estimated") in (False, None), json.dumps(row)[:250])
    check("[incremental] no lua errors", "lua entry thread aborted" not in logs(name),
          logs(name)[-400:])
    stop_router(name)


# --------------------------------------------------------------------------
def main():
    scenario_inject_and_strip()
    scenario_finish_chunk()
    scenario_backend_without_the_field()
    scenario_detail_metrics()
    scenario_routes()
    scenario_incremental_delivery()
    failed = [r for r in RESULTS if not r[0]]
    print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
    for _, name, detail in failed:
        print("FAILED: %s | %s" % (name, str(detail)[:400]))
    cleanup()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
