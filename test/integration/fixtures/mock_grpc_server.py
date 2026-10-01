#!/usr/bin/env python3
"""gRPC worker stand-in for the lua-router gRPC/PD plane (repository copy).

Landed here from the prototype transcript in doc/gap-grpc-pd.md so the e2e suite
(test/integration/e2e_grpc.py) is reproducible from the repo alone. No .proto is
needed: nginx's grpc_pass forwards raw HTTP/2 frames, so every method uses the
identity (de)serializer and the payload is just bytes. probe.Echo exposes unary /
server-stream / bidi / error / slow / large methods plus metadata introspection,
which is what the checks assert on.

The Sglang/Generate method additionally *parses* its request as sglang's
GenerateRequest, because that is the point of the PD body carrier: the router
writes DisaggregatedParams (field 10) into the message, and only a decoder can
prove the bytes. Two independent decoders run side by side:

  * google.protobuf, with descriptors built at import time -- a real third-party
    implementation, so it validates the router's encoder rather than agreeing
    with it by construction;
  * a small hand-rolled wire scanner, which is what reports the *positions* the
    google.protobuf path cannot see (unknown fields kept verbatim, field order).

A field-level verdict goes into the response body as `|pb-*=value`, which is what
e2e_grpc.py asserts on. Payloads that are not a parsable message (the plain
`echo:` checks send bare bytes) report `|pb=none` and are echoed untouched.

--health-port additionally serves HTTP/1.1 /health so a worker registered as
"http url + labels.grpc_port" can be probed by the router's normal sweep, and
killing the process makes it go unhealthy the way a real engine does.
"""
import argparse
import concurrent.futures
import os
import sys
import threading
import time
import traceback

import grpc


def identity(b):
    return b if b is not None else b""


def md(request_context, key):
    for k, v in (request_context.invocation_metadata() or ()):
        if k.lower() == key:
            return v
    return None


def seen_md(request_context):
    """Dump the metadata nginx actually delivered, into the response body."""
    pairs = sorted(
        (k.lower(), v) for k, v in (request_context.invocation_metadata() or ())
    )
    return pairs


# ---------------------------------------------------------------- protobuf
# Field numbers/types straight from the vendored schema the Rust gateway builds
# (crates.io smg-grpc-client-1.0.0/proto/sglang_scheduler.proto): GenerateRequest
# carries disaggregated_params = 10, and DisaggregatedParams is
# {bootstrap_host=1 string, bootstrap_port=2 int32, bootstrap_room=3 int32}.
# 101/102/103 are the lua-router's own decode-peer extensions; a stock worker
# skips them as unknown fields.
DISAGG_FIELDS = {1: "bootstrap_host", 2: "bootstrap_port", 3: "bootstrap_room",
                 101: "decode_host", 102: "decode_port", 103: "prefill_dp_rank"}
GEN_FIELDS = {1: "request_id", 2: "tokenized", 3: "mm_inputs", 4: "sampling_params",
              5: "return_logprob", 6: "logprob_start_len", 7: "top_logprobs_num",
              8: "token_ids_logprob", 9: "return_hidden_states",
              10: "disaggregated_params", 11: "custom_logit_processor",
              12: "timestamp", 13: "log_metrics", 14: "input_embeds",
              15: "lora_id", 16: "data_parallel_rank", 17: "stream"}


def decode_varint(buf, pos):
    value = 0
    shift = 1
    for _ in range(10):
        if pos >= len(buf):
            raise ValueError("truncated varint")
        byte = buf[pos]
        pos += 1
        value += (byte & 0x7F) * shift
        shift <<= 7
        if not byte & 0x80:
            return value, pos
    raise ValueError("overlong varint")


def scan(buf):
    """Independent field walk: returns [(field, wire, payload_bytes)]."""
    out = []
    pos = 0
    n = len(buf)
    while pos < n:
        tag, pos = decode_varint(buf, pos)
        field, wire = tag >> 3, tag & 7
        if field == 0:
            raise ValueError("field zero")
        if wire == 0:
            start = pos
            _, pos = decode_varint(buf, pos)
            out.append((field, wire, buf[start:pos]))
        elif wire == 2:
            size, pos = decode_varint(buf, pos)
            if pos + size > n:
                raise ValueError("truncated length-delimited field")
            out.append((field, wire, buf[pos:pos + size]))
            pos += size
        elif wire == 5:
            if pos + 4 > n:
                raise ValueError("truncated fixed32")
            out.append((field, wire, buf[pos:pos + 4]))
            pos += 4
        elif wire == 1:
            if pos + 8 > n:
                raise ValueError("truncated fixed64")
            out.append((field, wire, buf[pos:pos + 8]))
            pos += 8
        else:
            raise ValueError("unsupported wire type %d" % wire)
    return out


def decode_int32(payload):
    """Decode a varint field as a signed int32.

    Negative int32 values are sign-extended to 64 bits on the wire (ten bytes),
    which is what prost emits and what the router's encoder writes.
    """
    value, _ = decode_varint(payload, 0)
    if value >= 1 << 63:
        value -= 1 << 64
    if not -2147483648 <= value <= 2147483647:
        raise ValueError("varint field outside int32")
    return value


def build_pb_classes():
    """Dynamic GenerateRequest/DisaggregatedParams from google.protobuf.

    Returns None when the runtime is unavailable; the scanner-only verdict is
    still useful, and the e2e check reports which validator answered.
    """
    try:
        from google.protobuf import descriptor_pb2, descriptor_pool, message_factory
    except Exception:
        return None
    fdp = descriptor_pb2.FieldDescriptorProto
    spec = descriptor_pb2.FileDescriptorProto()
    spec.name = "sglang_probe.proto"
    spec.syntax = "proto3"
    disagg = spec.message_type.add()
    disagg.name = "DisaggregatedParams"
    for name, number, kind in (("bootstrap_host", 1, "TYPE_STRING"),
                               ("bootstrap_port", 2, "TYPE_INT32"),
                               ("bootstrap_room", 3, "TYPE_INT32"),
                               ("decode_host", 101, "TYPE_STRING"),
                               ("decode_port", 102, "TYPE_INT32"),
                               ("prefill_dp_rank", 103, "TYPE_INT32")):
        fd = disagg.field.add()
        fd.name = name
        fd.number = number
        fd.type = fdp.Type.Value(kind)
        fd.label = fdp.Label.Value("LABEL_OPTIONAL")
    gen = spec.message_type.add()
    gen.name = "GenerateRequest"
    fd = gen.field.add()
    fd.name = "request_id"
    fd.number = 1
    fd.type = fdp.Type.Value("TYPE_STRING")
    fd.label = fdp.Label.Value("LABEL_OPTIONAL")
    fd = gen.field.add()
    fd.name = "disaggregated_params"
    fd.number = 10
    fd.type = fdp.Type.Value("TYPE_MESSAGE")
    fd.label = fdp.Label.Value("LABEL_OPTIONAL")
    fd.type_name = ".DisaggregatedParams"
    pool = descriptor_pool.DescriptorPool()
    pool.Add(spec)
    return {
        "GenerateRequest": message_factory.GetMessageClass(
            pool.FindMessageTypeByName("GenerateRequest")),
        "DisaggregatedParams": message_factory.GetMessageClass(
            pool.FindMessageTypeByName("DisaggregatedParams")),
    }


PB_CLASSES = build_pb_classes()


def _fmt_fields(fields):
    """Render [(field, wire, ...)] as b"10:2,1:0" so a check can read the layout."""
    return b",".join(("%d:%d" % (f[0], f[1])).encode() for f in fields)


def pb_report(payload):
    """Parse a GenerateRequest body into `|pb-*=...` assertions.

    Bytes that are not a message (the plain byte-echo checks) yield |pb=none;
    the caller still echoes the payload untouched either way.
    """
    if not payload:
        return b"|pb=empty"
    try:
        outer = scan(payload)
    except Exception as exc:
        return b"|pb=unparsable:" + str(exc).encode()[:60]
    disagg = [f for f in outer if f[0] == 10 and f[1] == 2]
    parts = [b"|pb=ok"]
    rid = [f for f in outer if f[0] == 1 and f[1] == 2]
    if rid:
        parts.append(b"|pb-rid=" + rid[-1][2])
    # Every outer field number and wire type, in wire order: proves a rewrite
    # neither reorders nor drops what the router does not know about.
    parts.append(b"|pb-fields=" + _fmt_fields(outer))
    parts.append(b"|pb-unknown=" + _fmt_fields(
        [f for f in outer if f[0] not in GEN_FIELDS]))
    for field, wire, body in outer:
        if field in (20, 21):
            # Echo at most a snippet: the large-body check carries megabytes in
            # field 21, and streaming that back would trip the client's
            # max_receive_message_length. The length still proves it survived.
            shown = body if len(body) <= 64 else (b"len:%d:%s" % (
                len(body), body[:16]))
            parts.append(b"|pb-keep%d=" % field + shown)
    if not disagg:
        parts.append(b"|pb-disagg=absent")
        return b"".join(parts)
    inner = scan(disagg[-1][2])
    index = {}
    for field, wire, body in inner:
        if field in DISAGG_FIELDS:
            index[DISAGG_FIELDS[field]] = (wire, body)

    def text(name):
        wire, body = index.get(name, (None, None))
        return body if wire == 2 else b"-"

    def number(name):
        wire, body = index.get(name, (None, None))
        return str(decode_int32(body)).encode() if wire == 0 else b"-"

    parts.append(b"|pb-order=" + _fmt_fields(inner))
    parts.append(b"|pb-host=" + text("bootstrap_host"))
    parts.append(b"|pb-port=" + number("bootstrap_port"))
    parts.append(b"|pb-room=" + number("bootstrap_room"))
    parts.append(b"|pb-decode-host=" + text("decode_host"))
    parts.append(b"|pb-decode-port=" + number("decode_port"))
    parts.append(b"|pb-dp-rank=" + number("prefill_dp_rank"))
    # Fields 101/102/103 are the router's own: a schema-faithful reader must see
    # them as unknown, i.e. anything but 1/2/3.
    parts.append(b"|pb-extra=" + _fmt_fields(
        [f for f in inner if f[0] not in (1, 2, 3)]))
    if PB_CLASSES is not None:
        try:
            msg = PB_CLASSES["GenerateRequest"]()
            msg.ParseFromString(payload)
            dp = msg.disaggregated_params
            parts.append(b"|pb-gp=host=%s,port=%d,room=%d" % (
                dp.bootstrap_host.encode(), dp.bootstrap_port, dp.bootstrap_room))
            # Re-encode through a real implementation and compare *fields*, not
            # bytes: an implementation is free to reorder and to park unknown
            # fields wherever it likes, so byte equality would be a false test.
            # Equality of the (field, wire, payload) multiset is the honest claim.
            again = msg.SerializeToString()
            same = sorted(scan(again)) == sorted(scan(payload))
            parts.append(b"|pb-gp-roundtrip=%s" % (b"yes" if same else b"no"))
        except Exception as exc:
            parts.append(b"|pb-gp=error:" + str(exc).encode()[:80])
    else:
        parts.append(b"|pb-gp=runtime-missing")
    return b"".join(parts)


class EchoServicer:
    def Say(self, request, context):
        want = bytes(request or b"")
        parts = [b"echo:" + want]
        parts.append(b"|auth=" + (md(context, "authorization") or "-").encode())
        parts.append(b"|xcustom=" + (md(context, "x-custom-md") or "-").encode())
        parts.append(b"|grpc-timeout=" + (md(context, "grpc-timeout") or "-").encode())
        parts.append(b"|te=" + (md(context, "te") or "-").encode())
        # The :authority nginx puts on the upstream request: it is the router's
        # own bind address, not the worker's, because the address travels in
        # grpc_pass's variable rather than in an upstream{} name. Asserted only to
        # pin that behaviour down, since a worker keying on authority would misroute.
        try:
            parts.append(b"|authority=" + (str(context.auth_context() or "-")).encode())
        except Exception:
            pass
        ctx = md(context, "x-lr-ctx")
        # custom trailing metadata: does nginx propagate it?
        parts.append(b"|ctx=" + (ctx or "-").encode())
        # which model this call was routed for, and this worker's id, so the e2e
        # checks can tell the two mocks apart and prove model steering happened
        parts.append(b"|model=" + (md(context, "x-smg-model") or "-").encode())
        parts.append(b"|self=" + (os.environ.get("LR_MOCK_ID") or "-").encode())
        # echo back the whole delivered header set so we can prove what nginx
        # keeps (te/content-length are hop-by-hop and must be rewritten by nginx)
        dump = ";".join(f"{k}={v}" for k, v in seen_md(context))
        parts.append(b"|md=" + dump.encode())
        try:
            context.initial_metadata().append(("x-mock-header", "1"))
        except Exception:
            pass
        return b"".join(parts)

    def Generate(self, request, context):
        """sglang's Generate: unary request, server-stream response.

        Registered on /sglang.grpc.scheduler.SglangScheduler/Generate with the
        identity serializers, and the one method whose body the router rewrites in
        PD body mode. One chunk carries the pb verdict plus the echo, which is all
        the e2e needs; the stream shape is what matters (sglang's Generate returns
        a stream, so a body rewrite must survive a method whose *response* streams
        while its request does not).
        """
        want = bytes(request or b"")
        # The payload is not echoed back: the large-body check sends megabytes,
        # and the verdict the suite needs is the parsed field set, not the bytes.
        out = b"gen:len=%d" % len(want) + pb_report(want)
        out += b"|self=" + (os.environ.get("LR_MOCK_ID") or "-").encode()
        out += b"|bootstrap-room-md=" + (md(context, "x-lr-bootstrap-room") or "-").encode()
        yield out

    def Tell(self, request, context):
        n = int(bytes(request or b"3") or b"3")
        for i in range(n):
            yield b"chunk-%d@%.3f" % (i, time.time())
            time.sleep(0.3)

    def Chat(self, request_iterator, context):
        for msg in request_iterator:
            yield b"echo:" + bytes(msg)

    def Trailers(self, request, context):
        try:
            context.set_trailing_metadata((("x-custom-trailer", "yes"),
                                           ("grpc-trailings-debug-data", "dbg")))
        except Exception as exc:
            return b"set_trailing_metadata unsupported: %s" % str(exc).encode()
        return b"trailers-set"

    def Fail(self, request, context):
        context.abort(grpc.StatusCode.NOT_FOUND, "not found")

    def FailMsg(self, request, context):
        # non-ASCII message: grpc percent-encodes non-ASCII in grpc-message
        context.abort(grpc.StatusCode.INVALID_ARGUMENT, "参数错误 bad input")

    def Slow(self, request, context):
        time.sleep(7)
        return b"late"

    def Large(self, request, context):
        payload = bytes(request or b"")
        return b"srv-saw-%d" % len(payload) + b"|echo:%d" % len(payload)

    def Big(self, request, context):
        return b"R" * (5 * 1024 * 1024)


def serve(port, tls=False):
    server = grpc.server(
        concurrent.futures.ThreadPoolExecutor(max_workers=16),
        options=[
            ("grpc.max_receive_message_length", 64 * 1024 * 1024),
            ("grpc.max_send_message_length", 64 * 1024 * 1024),
        ],
    )
    servicer = EchoServicer()
    rpc = grpc.method_handlers_generic_handler(
        "probe.Echo",
        {
            "Trailers": grpc.unary_unary_rpc_method_handler(servicer.Trailers, identity, identity),
            "Say": grpc.unary_unary_rpc_method_handler(servicer.Say, identity, identity),
            "Tell": grpc.unary_stream_rpc_method_handler(servicer.Tell, identity, identity),
            # sglang's real PD method, under its real service name so the router's
            # path check is exercised rather than a stand-in.
            "Generate": grpc.unary_stream_rpc_method_handler(servicer.Generate, identity, identity),
            "Chat": grpc.stream_stream_rpc_method_handler(servicer.Chat, identity, identity),
            "Fail": grpc.unary_unary_rpc_method_handler(servicer.Fail, identity, identity),
            "FailMsg": grpc.unary_unary_rpc_method_handler(servicer.FailMsg, identity, identity),
            "Slow": grpc.unary_unary_rpc_method_handler(servicer.Slow, identity, identity),
            "Large": grpc.unary_unary_rpc_method_handler(servicer.Large, identity, identity),
            "Big": grpc.unary_unary_rpc_method_handler(servicer.Big, identity, identity),
        },
    )
    sglang_rpc = grpc.method_handlers_generic_handler(
        "sglang.grpc.scheduler.SglangScheduler",
        {"Generate": grpc.unary_stream_rpc_method_handler(servicer.Generate,
                                                         identity, identity)},
    )
    server.add_generic_rpc_handlers((rpc, sglang_rpc))
    if tls:
        cert = os.environ.get("LR_TLS_CERT", "/data/tmp/lr-grpc/tls/server.crt")
        key = os.environ.get("LR_TLS_KEY", "/data/tmp/lr-grpc/tls/server.key")
        with open(key, "rb") as g, open(cert, "rb") as f:
            creds = grpc.ssl_server_credentials([(g.read(), f.read())])
        server.add_secure_port("127.0.0.1:%d" % port, creds)
    else:
        server.add_insecure_port("127.0.0.1:%d" % port)
    server.start()
    print("mock listening on %s:%d" % ("tls" if tls else "plain", port), flush=True)
    return server


def serve_health(port):
    """Minimal HTTP/1.1 /health 200 for the router's health sweep."""
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            body = b'{"ok":true}'
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    httpd = HTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    print("health listening on %d" % port, flush=True)
    return httpd


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=19600)
    ap.add_argument("--tls-port", type=int, default=0)
    ap.add_argument("--health-port", type=int, default=0)
    args = ap.parse_args()
    servers = [serve(args.port)]
    if args.health_port:
        serve_health(args.health_port)
    if args.tls_port:
        try:
            servers.append(serve(args.tls_port, tls=True))
        except Exception:
            traceback.print_exc()
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        for s in servers:
            s.stop(0)
