#!/usr/bin/env python3
"""Machine-shared loopback port allocator for the lua-router test harness.

One allocator, two front ends: the python suites import free_port(), the bash
contract suite shells out to this file. Both write the same ledger, so a python
e2e gate and a bash container section stop being two allocators that never hear
about each other -- which is exactly the window where two suites used to be
handed the same port microseconds apart.

Ledger: the LR_PORT_RESERVE environment variable when a runner sets it (one
file per gate run), otherwise the machine-wide /data/tmp/lr-gates/ports
.reserved. The fallback is deliberate: the suites are routinely run standalone
(TEST_ONLY=x, python3 e2e_x.py) with no runner in front of them, and a ledger
that only exists inside a gate run protects nothing in that mode.

Rows are '<owner_pid> <port>'. The owner is the LONG-LIVED process holding the
reservation for the whole suite, not the short-lived interpreter that ran the
probe -- a pid that already exited expires the row immediately and turns the
ledger back into a bind(0) with extra steps. The contract suite passes its own
bash $$ through LR_PORT_OWNER_PID; a runner does not set that variable, so a
python suite owns its ports as itself.

A port is handed out only when both conditions hold: no live owner has it in
the ledger, and a fresh probe bind succeeds. The probe is what makes one shared
file safe across concurrent gate runs and manual invocations -- a port bound by
an outside process is skipped even if the ledger never saw it, so a row can
never make a busy port look free.

The band sits below net.ipv4.ip_local_port_range (32768+ on this box) on
purpose: the docker daemon picks its own '-p 127.0.0.1::8080' publishes from
the ephemeral range and is not in the ledger, so disjoint-by-construction is
the only thing that keeps a publish from landing on a reserved number.

Ledger failures are fatal. The pre-pool behaviour silently fell back to an
unreserved port when the file was unreadable, which converts a broken harness
into a rare port-collision red several gates later -- the worst failure mode
for a mechanism whose only job is to make collisions impossible.
"""
import fcntl
import os
import random
import socket
import sys
import tempfile

PORT_START = 20001
PORT_STOP = 32000                      # exclusive, and below the ephemeral range
DEFAULT_LEDGER = "/data/tmp/lr-gates/ports.reserved"
# 29000: the Rust gateway's scrape listener on this box.
# 30000: the in-container SMG_PORT that the contract suite publishes.
# 31337: the literal the TLS render-only scenario names (never bound; see
#        e2e_tls_chain.py section 7). Kept so no allocator can collide with it
#        if that scenario ever learns to bind.
AVOID_PORTS = frozenset({29000, 30000, 31337})


class LedgerError(RuntimeError):
    """The ledger is unusable. Never allocate outside it in this state."""


def ledger_path(ledger=None):
    return ledger or os.environ.get("LR_PORT_RESERVE") or DEFAULT_LEDGER


def owner_pid(owner=None):
    value = owner if owner is not None else os.environ.get("LR_PORT_OWNER_PID")
    try:
        pid = os.getpid() if value in (None, "") else int(value)
    except (TypeError, ValueError):
        raise LedgerError("port owner pid is not a pid: %r" % (value,))
    if pid <= 0:
        raise LedgerError("port owner pid must be positive, got %r" % (value,))
    return pid


def _alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True                     # exists, owned by somebody else
    except OSError as exc:
        if exc.errno == 3:              # ESRCH where the subclass is absent
            return False
        raise LedgerError("cannot probe owner pid %d: %s" % (pid, exc))
    return True


def _parse(line):
    parts = line.split()
    if len(parts) != 2:
        raise LedgerError("malformed ledger row %r" % (line.rstrip("\n"),))
    try:
        pid, port = int(parts[0]), int(parts[1])
    except ValueError:
        raise LedgerError("non-numeric ledger row %r" % (line.rstrip("\n"),))
    if pid <= 0:
        raise LedgerError("non-positive owner pid in row %r" % (line.rstrip("\n"),))
    if not PORT_START <= port < PORT_STOP:
        raise LedgerError("ledger port out of band in row %r" % (line.rstrip("\n"),))
    return pid, port


def _read_live(path):
    """Every row whose owner is still alive. Raises LedgerError on a bad file."""
    rows, taken = [], set()
    src = None
    try:
        src = open(path, "r", encoding="ascii")
    except FileNotFoundError:
        return rows, taken
    except OSError as exc:
        raise LedgerError("cannot read ledger %s: %s" % (path, exc))
    with src:
        for line in src:
            if not line.strip():
                continue
            pid, port = _parse(line)
            if not _alive(pid):
                continue                # dead owner -> the port is public again
            rows.append((pid, port))
            taken.add(port)
    return rows, taken


def _read_live_quarantine(path):
    """As _read_live, but unparseable rows are dropped instead of raising.

    Only for the release path: a suite's EXIT trap must not wedge on a ledger
    that some other run corrupted, and dropping an unreadable row can only ever
    make a port available, never claim a busy one (the bind probe is the gate).
    """
    rows, taken = [], set()
    try:
        lines = open(path, "r", encoding="ascii").readlines()
    except FileNotFoundError:
        return rows, taken
    except OSError as exc:
        raise LedgerError("cannot read ledger %s: %s" % (path, exc))
    for line in lines:
        if not line.strip():
            continue
        try:
            pid, port = _parse(line)
        except LedgerError:
            continue
        if not _alive(pid):
            continue
        rows.append((pid, port))
        taken.add(port)
    return rows, taken


def _write_atomic(path, parent, rows):
    """Rewrite the ledger under the lock via a temp file + rename.

    The flock lives on a separate .lock inode, so replacing the data file can
    never split the lock domain between two processes holding different inodes.
    """
    fd, tmp = tempfile.mkstemp(prefix=".ports.", dir=parent, text=True)
    try:
        with os.fdopen(fd, "w", encoding="ascii") as out:
            for pid, port in rows:
                out.write("%d %d\n" % (pid, port))
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def _lock(path, parent):
    try:
        os.makedirs(parent, exist_ok=True)
    except OSError as exc:
        raise LedgerError("cannot create ledger dir %s: %s" % (parent, exc))
    lock_path = path + ".lock"
    try:
        return open(lock_path, "a+")
    except OSError as exc:
        raise LedgerError("cannot open ledger lock %s: %s" % (lock_path, exc))


def _claim(path, me, port):
    """Take the named port for me; False when a live owner already holds it."""
    parent = os.path.dirname(os.path.abspath(path))
    with _lock(path, parent) as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            rows, taken = _read_live(path)
            if port in taken:
                return False
            rows.append((me, port))
            _write_atomic(path, parent, rows)
            return True
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def _bindable(port):
    """True when nothing on this box has the port bound right now.

    The bind probe is what makes ONE ledger file safe to share across concurrent
    gate runs and manual invocations: a port held by a live service, or by a
    docker publish proxy, is skipped even if the ledger never saw it. A ledger
    row can only ever ADD a reservation, never mask a busy port.
    """
    probe = socket.socket()
    try:
        probe.bind(("127.0.0.1", port))
    except OSError:
        return False
    finally:
        probe.close()
    return True


def reserve(port, ledger=None, owner=None):
    """Claim exactly one port. Ledger trouble raises; a taken port raises ValueError.

    A taken port is a ValueError and not a LedgerError on purpose: the ledger is
    healthy, it just said no, and a caller scanning the band must keep scanning.
    """
    path = ledger_path(ledger)
    me = owner_pid(owner)
    if not PORT_START <= port < PORT_STOP:
        raise LedgerError("requested port %d outside %d-%d"
                          % (port, PORT_START, PORT_STOP - 1))
    # Both gates apply to an explicit request as well: the ledger alone would
    # happily hand out a number a live service (or a docker publish proxy) owns
    # right now -- a row can only ever ADD a reservation, it must never mask a
    # busy port. Without this probe the contract suite's pinned FIXPORT and every
    # reserve() caller share the ledger's bookkeeping but not its safety.
    if not _bindable(port):
        raise ValueError("port %d is bound by a live process" % port)
    if not _claim(path, me, port):
        raise ValueError("port %d is reserved by a live owner" % port)
    return port




def free_port(ledger=None, owner=None):
    """Reserve one free loopback port from the shared band."""
    ports = list(range(PORT_START, PORT_STOP))
    random.SystemRandom().shuffle(ports)
    for port in ports:
        if port in AVOID_PORTS:
            continue
        if not _bindable(port):
            continue                    # live service, or a docker publish proxy
        me = owner_pid(owner)
        if _claim(ledger_path(ledger), me, port):
            return port
    raise RuntimeError("no unbound port available in %d-%d"
                       % (PORT_START, PORT_STOP - 1))


def release_pid(pid, ledger=None):
    """Drop every row owned by pid: the suite is finishing, hand its ports back."""
    path = ledger_path(ledger)
    parent = os.path.dirname(os.path.abspath(path))
    with _lock(path, parent) as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            try:
                rows, _ = _read_live(path)
            except LedgerError:
                rows, _ = _read_live_quarantine(path)
            keep = [(p, q) for p, q in rows if p != pid]
            _write_atomic(path, parent, keep)
            return len(rows) - len(keep)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def main(argv):
    """CLI for the bash side.

    port_allocator.py                   reserve and print one port
    port_allocator.py --release PID     drop every row owned by PID
    port_allocator.py --ledger PATH     use this ledger for this call
    """
    argv = list(argv)
    ledger = None
    if "--ledger" in argv:
        i = argv.index("--ledger")
        if i + 1 >= len(argv):
            sys.stderr.write("--ledger needs a path\n")
            return 2
        ledger = argv[i + 1]
        del argv[i:i + 2]
    if argv[:1] == ["--release"]:
        if len(argv) < 2:
            sys.stderr.write("--release needs a pid\n")
            return 2
        release_pid(int(argv[1]), ledger=ledger)
        return 0
    if argv:
        sys.stderr.write("unknown argument: %s\n" % argv[0])
        return 2
    print(free_port(ledger=ledger))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
