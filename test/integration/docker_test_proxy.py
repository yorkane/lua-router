#!/usr/bin/env python3
"""A read-only Docker API proxy that isolates the watcher e2e from the rest of the box.

Why this exists. The in-process watcher discovers workers over the docker socket by
listing every running container and reading its published ports (watcher/discover.lua
docker_containers -> unix_get(cfg.docker_socket, "/containers/json?filters=...") ->
docker_candidates_from). Pointed at the real daemon, that list is the whole machine, so
any container a *neighbouring gate* publishes after the suite took its docker_watch_env
snapshot is an unaccounted candidate, and the gate has to own an exclusive
machine-observation lock to stay deterministic.

The proxy is the isolation the snapshot could not provide: the watcher container binds
this socket at /var/run/docker.sock instead of the real one, and the /containers/json
reply it reads is the real daemon's reply filtered down to the containers this suite
registered. Every field of a kept container is forwarded as the daemon sent it --
published ports, names, Labels, NetworkSettings, HostConfig -- so discovery stays the
real docker source over a real published port, and removing the fixture container still
takes its URL out of the list. Containers this suite did not register (a gate running
beside it, the router's own host-network container, every real service) are not in the
array, which is exactly the machine-scan window the exclusive lock guarded.

Read-only by construction: the only request it answers is the bare GET /containers/json
the product's own Lua client sends. Any other method, any other path -- the docker CLI's
version-prefixed form included, since no product client speaks it -- version ping,
/events stream, inspect, start/stop, exec, push -- is refused with 403. The runner's
sweeper talks to the real daemon, not to this socket, so the CLI dialect is not this
proxy's contract; kept strict, it stays a one-endpoint door.

Single-tenant by construction: one suite owns one proxy, on one socket under a bounded
private path. The allow-list grows as fixtures start; it is never a snapshot, so a
fixture started mid-run is visible the moment it is registered and a late neighbour is
never visible at all. Entries are container NAMES (the suite's fixtures, registered as
they start). The provenance labels are the RUNNER's protocol, applied at docker-run
time by the suite from _lib's CONTAINER_LABELS; the daemon's Labels map rides along in
every kept record untouched, so anything reading this list sees what the real daemon
reports for the same container.

Lifecycle: start() opens the listening socket; the serve loop runs on a daemon thread
the caller joins via stop(). stop closes the listener, joins the thread, and moves the
socket file to the trash -- this run's private artefact, trashed not rm'd, matching the
box's delete-by-move rule.
"""
import hashlib
import http.client
import json
import os
import socket
import threading

# The only request shape the product sends over the socket: the running-container list,
# bare path, GET only. Match it EXACTLY (a prefix match would let a traversal like
# /containers/json/../admin through the gate), and never widen it: every extra accepted
# shape is extra reach a parallel neighbour's fixtures would grant a test that talks to
# this socket.
_ALLOWED_PATH = "/containers/json"

# The fixed root that holds proxy sockets. A unix socket path must fit a sockaddr_un
# (107 bytes on Linux), and the suite's TMP is caller-controlled -- LR_TEST_TMP can put
# it arbitrarily deep -- so the socket deliberately does NOT live under TMP. A fixed
# short root plus a hash of the run identity bounds the path for any input, and hashing
# the run's FULL "TMP|RUN" (never a truncation of it) keeps one socket per run, so two
# concurrent runs can never share or clobber a listener.
SOCKET_ROOT = "/data/tmp/lr-dp"
_SOCKET_HASH_CHARS = 16


def socket_path_for(tmp_dir, run_id):
    digest = hashlib.sha256(("%s|%s" % (tmp_dir, run_id)).encode("utf-8")).hexdigest()
    return os.path.join(SOCKET_ROOT, "docker-%s.sock" % digest[:_SOCKET_HASH_CHARS])


class _UnixConn(http.client.HTTPConnection):
    """HTTPConnection that connects over a unix socket (the real daemon endpoint)."""

    def __init__(self, socket_path, timeout):
        super().__init__("localhost", timeout=timeout)
        self._socket_path = socket_path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self._socket_path)
        self.sock = sock


class DockerTestProxy:
    def __init__(self, socket_path, real_socket="/var/run/docker.sock",
                 forward_timeout=5.0):
        self.socket_path = socket_path
        self.real_socket = real_socket
        self.forward_timeout = forward_timeout
        self._allowed = set()          # fixture container names this suite owns
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._listener = None
        self._thread = None

    @classmethod
    def for_run(cls, tmp_dir, run_id, **kwargs):
        """A proxy on this run's bounded socket path (see socket_path_for)."""
        return cls(socket_path_for(tmp_dir, run_id), **kwargs)

    # -- allow-list ----------------------------------------------------------
    def allow(self, name):
        """Register one fixture container so its record survives the filter.

        Names come from the docker API with a leading slash (/lr-watch-...); the
        watcher strips it, so the registry normalises to the slash-less form and the
        comparison ignores the prefix either way.
        """
        with self._lock:
            self._allowed.add(name.lstrip("/"))

    def is_allowed(self, name):
        clean = name.lstrip("/")
        with self._lock:
            return clean in self._allowed

    # -- lifecycle -----------------------------------------------------------
    def start(self):
        parent = os.path.dirname(self.socket_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        if os.path.exists(self.socket_path):
            os.unlink(self.socket_path)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(self.socket_path)
        # The watcher container's root connects here; the socket lives under a root
        # this run owns, so mode 666 widens only the connect gate, not a directory.
        os.chmod(self.socket_path, 0o666)
        listener.listen(64)
        # A bounded accept timeout so stop() (which sets the flag, not the socket) can
        # break the loop within one tick instead of blocking until the next request.
        listener.settimeout(0.5)
        self._listener = listener
        self._thread = threading.Thread(target=self._serve,
                                        name="docker-test-proxy", daemon=True)
        self._thread.start()
        return self

    def stop(self):
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=5)
            self._thread = None
        if self._listener is not None:
            try:
                self._listener.close()
            except OSError:
                pass
            self._listener = None
        _trash(self.socket_path)

    # -- server loop ---------------------------------------------------------
    def _serve(self):
        while not self._stop.is_set():
            try:
                conn, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break               # listener closed by stop()
            try:
                self._handle(conn)
            finally:
                try:
                    conn.close()
                except OSError:
                    pass

    def _handle(self, conn):
        head = _read_head(conn)
        if not head:
            return
        lines = head.split("\r\n")
        parts = lines[0].split(" ")
        if len(parts) < 2:
            _respond(conn, 400, json.dumps({"message": "bad request line"}).encode())
            return
        method, target = parts[0], parts[1]
        # The path half must be the exact bare list endpoint (query string dropped for
        # the match, no dot-segment allowed), so /containers/json/../admin is refused
        # the same way /v1.45/containers/json and /containers/aaa/json are.
        path = target.split("?", 1)[0]
        if method != "GET" or path != _ALLOWED_PATH or ".." in target:
            # Refuse everything the product does not send, mutations above all.
            _respond(conn, 403, json.dumps(
                {"message": "docker-test-proxy: %s %s is not allowed"
                 % (method, target)}).encode())
            return
        self._forward_list(conn, target)

    def _forward_list(self, conn, target):
        """GET the real daemon, filter the array to the registered fixtures.

        The query string goes to the daemon UNPARSED -- the daemon does its own
        filtering, and this proxy adds exactly one thing on top: records this suite did
        not register are dropped. The product's query carries only a status filter, so
        discovery sees the name-registered fixtures and nothing else.
        """
        upstream = _UnixConn(self.real_socket, self.forward_timeout)
        try:
            upstream.request("GET", target, headers={"Accept": "*/*",
                                                     "Connection": "close"})
            resp = upstream.getresponse()
            status = resp.status
            body = resp.read()
        except (OSError, http.client.HTTPException) as exc:
            _respond(conn, 502, json.dumps(
                {"message": "docker-test-proxy: forward failed: %s" % exc}).encode())
            return
        finally:
            upstream.close()
        if status != 200:
            # Not a list we can filter (daemon error); relay the status, empty array.
            _respond(conn, status, b"[]")
            return
        _respond(conn, 200, self._filter(body), content_type="application/json")

    def _filter(self, body):
        try:
            containers = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return b"[]"
        if not isinstance(containers, list):
            return b"[]"
        kept = []
        for ctr in containers:
            if not isinstance(ctr, dict):
                continue
            names = ctr.get("Names")
            first = ""
            if isinstance(names, list) and names:
                first = str(names[0])
            elif isinstance(ctr.get("Id"), str):
                first = ctr["Id"]
            if self.is_allowed(first):
                kept.append(ctr)      # kept whole: every daemon field verbatim
        return json.dumps(kept).encode("utf-8")


# --------------------------------------------------------------------------
def _read_head(conn):
    """Read request bytes up to the blank line; the product sends no body."""
    chunks = []
    total = 0
    while total < 65536:
        try:
            piece = conn.recv(4096)
        except OSError:
            break
        if not piece:
            break
        chunks.append(piece)
        total += len(piece)
        if b"\r\n\r\n" in b"".join(chunks):
            break
    head = b"".join(chunks).decode("latin-1")
    return head.split("\r\n\r\n", 1)[0]


def _respond(conn, status, body, content_type="application/json"):
    reason = {200: "OK", 400: "Bad Request", 403: "Forbidden",
              502: "Bad Gateway"}.get(status, "Status")
    head = ("HTTP/1.1 %d %s\r\n"
            "Content-Type: %s\r\n"
            "Content-Length: %d\r\n"
            "Connection: close\r\n\r\n" % (status, reason, content_type, len(body)))
    try:
        conn.sendall(head.encode("latin-1") + body)
    except OSError:
        pass


def _trash(path):
    """Move the run's socket to /data/.trash (box rule: delete by move, not rm)."""
    if not path or not os.path.exists(path):
        return
    trash = "/data/.trash"
    try:
        os.makedirs(trash, exist_ok=True)
        # The parent directory goes into the trashed name: every run shares this one
        # trash directory, and a bare socket file name is a content hash, so two runs
        # trashing at once must not overwrite each other's artefact.
        parent = os.path.basename(os.path.dirname(path))
        stamp = "%s.%s" % (parent, os.path.basename(path)) if parent \
            else os.path.basename(path)
        os.replace(path, os.path.join(trash, stamp))
    except OSError:
        try:
            os.unlink(path)
        except OSError:
            pass

