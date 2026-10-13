#!/usr/bin/env python3
"""Cross-process locks for the gate runner.

All state lives under /data/tmp/lr-gates/locks/ (LR_GATE_LOCK_DIR overrides).

  obs (RW, writer-preferring)  the machine-observation window. Ordinary HTTP
      gates take it shared. The writer-preferring queue exists so a long-lived
      shared pool cannot starve an exclusive gate: a queued writer blocks NEW
      readers, and every slot carries the pid of its owner, so a run killed
      mid-flight has its slots pruned by the next acquire instead of wedging
      the box.

  build (mutex)                the prepare lock for docker build. Independent of
      obs, which is what lets conf/unit/contract/probes run while the image is
      still being built.

  There is deliberately NO global 'one gate run at a time' lock any more. Runs
      are made independent instead: unique run id, per-run temp/log/result dirs,
      per-gate namespace, and one machine-wide port ledger.

State rows are `kind pid token`, rewritten under one meta flock:
    r <pid> <token>   shared holder
    w <pid> <token>   writer queued for the exclusive window
    x <pid> <token>   exclusive holder
The token is mandatory, not decoration: a scheduler runs its gates in THREADS
of ONE process, so several lock instances legitimately share a pid. Release
matches on the token, so one gate leaving the window can never drop the slots
of the gates that are still inside it (the pid-only scheme did exactly that,
which is why an 'exclusive' window could be entered while shared holders ran).
"""

import errno
import fcntl
import os
import time

LOCK_DIR = os.environ.get("LR_GATE_LOCK_DIR", "/data/tmp/lr-gates/locks")

_TOKEN_SEQ = [0]


def current_lock_dir():
    """Current lock root, read at call time -- not frozen at import.

    The runner and the pure-runner harness point a run at its own lock root by
    setting LR_GATE_LOCK_DIR in-process, after this module is imported. Reading
    the constant only at import made that override apply just to a fresh
    process, so a caller that believed it was testing a private lock root was in
    fact queueing on the shared one: the same silent-override-loss shape as an
    unregistered env var under nginx.
    """
    return os.environ.get("LR_GATE_LOCK_DIR") or LOCK_DIR


def _new_token():
    _TOKEN_SEQ[0] += 1
    return "%d-%d-%04x" % (os.getpid(), _TOKEN_SEQ[0],
                            (os.getpid() * 31 + _TOKEN_SEQ[0] * 7919) & 0xFFFF)


def _live(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


class LockTimeout(RuntimeError):
    pass


class _State:
    """The lock slots, pruned of dead owners, rewritten under a meta flock."""

    def __init__(self, name, lock_dir=None):
        self.path = os.path.join(lock_dir or current_lock_dir(), name + ".state")
        self.meta_path = self.path + ".meta"
        os.makedirs(os.path.dirname(self.path), exist_ok=True)

    def _read(self, lines):
        out = []
        for line in lines:
            parts = line.split()
            if len(parts) != 3:
                continue              # a row from an older format: ignore it
            kind, pid, token = parts[0], parts[1], parts[2]
            if kind in ("r", "w", "x"):
                try:
                    pid_num = int(pid)
                except ValueError:
                    continue
                if _live(pid_num):
                    out.append((kind, pid_num, token))
        return out

    def mutate(self, fn):
        """Run fn(rows) -> (rows_out, result) atomically; return result."""
        with open(self.meta_path, "a+") as meta:
            fcntl.flock(meta, fcntl.LOCK_EX)
            try:
                rows = []
                if os.path.exists(self.path):
                    with open(self.path) as fh:
                        rows = self._read(fh)
                rows, result = fn(rows)
                tmp = "%s.tmp.%d-%d" % (self.path, os.getpid(), _TOKEN_SEQ[0])
                with open(tmp, "w") as fh:
                    for kind, pid, token in rows:
                        fh.write("%s %d %s\n" % (kind, pid, token))
                    fh.flush()
                    os.fsync(fh.fileno())
                os.replace(tmp, self.path)
                return result
            finally:
                fcntl.flock(meta, fcntl.LOCK_UN)


class RWLock:
    def __init__(self, name="obs", timeout=3600, poll=0.1, lock_dir=None):
        self.st = _State(name, lock_dir)
        self.timeout = timeout
        self.poll = poll
        self.pid = os.getpid()
        self.token = _new_token()
        self.kind = None

    def _mine(self, row, kinds):
        return row[2] == self.token and row[0] in kinds

    def _count(self, rows, kind):
        return sum(1 for r in rows if r[0] == kind)

    def acquire_shared(self):
        deadline = time.time() + self.timeout
        while True:
            def take(rows):
                if self._count(rows, "w") == 0 and self._count(rows, "x") == 0:
                    return (rows + [("r", self.pid, self.token)], True)
                return (rows, False)
            if self.st.mutate(take):
                self.kind = "r"
                return True
            if time.time() >= deadline:
                raise LockTimeout("shared obs lock held past %ss" % self.timeout)
            time.sleep(self.poll)

    def acquire_exclusive(self):
        deadline = time.time() + self.timeout

        def take(rows):
            if self._count(rows, "r") == 0 and self._count(rows, "x") == 0:
                rows = [r for r in rows if not self._mine(r, ("w",))]
                return (rows + [("x", self.pid, self.token)], True)
            if not any(self._mine(r, ("w",)) for r in rows):
                rows = rows + [("w", self.pid, self.token)]   # queue: new r blocked
            return (rows, False)

        while True:
            if self.st.mutate(take):
                self.kind = "x"
                return True
            if time.time() >= deadline:
                self._release()
                raise LockTimeout("exclusive obs lock busy past %ss" % self.timeout)
            time.sleep(self.poll)

    def _release(self):
        def drop(rows):
            # token-exact: never touch another instance's slot, same pid included
            return ([r for r in rows if not self._mine(r, (self.kind, "w"))], None)
        self.st.mutate(drop)
        self.kind = None

    def release(self):
        self._release()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.release()


class FileLock:
    """Plain mutex on a lock file (the build prepare lock)."""

    def __init__(self, name="build", timeout=3600, poll=0.2, lock_dir=None):
        self.path = os.path.join(lock_dir or current_lock_dir(), name + ".lock")
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self.timeout = timeout
        self.poll = poll
        self.fh = None

    def acquire(self):
        deadline = time.time() + self.timeout
        fh = open(self.path, "a+")
        while True:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.fh = fh
                return True
            except OSError as e:
                if e.errno not in (errno.EAGAIN, errno.EACCES):
                    fh.close()
                    raise
                if time.time() >= deadline:
                    fh.close()
                    raise LockTimeout("lock %s busy past %ss" % (self.path, self.timeout))
                time.sleep(self.poll)

    def release(self):
        if self.fh is not None:
            fcntl.flock(self.fh, fcntl.LOCK_UN)
            self.fh.close()
            self.fh = None

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, *exc):
        self.release()


def acquire_gate_locks(gate, timeout=None, lock_dir=None):
    """Take every lock the gate declares, in a fixed order, and return them."""
    handles = []
    for spec in gate.locks:
        kind, _, mode = spec.partition(":")
        tmo = timeout if timeout is not None else 3600
        if kind == "obs":
            lk = RWLock("obs", timeout=tmo, lock_dir=lock_dir)
            (lk.acquire_shared if mode == "shared" else lk.acquire_exclusive)()
        elif kind == "build":
            lk = FileLock("build", timeout=tmo, lock_dir=lock_dir)
            lk.acquire()
        else:
            raise KeyError("unknown lock family %r" % spec)
        handles.append(lk)
    return handles


def release_gate_locks(handles):
    for lk in reversed(handles or []):
        try:
            lk.release()
        except Exception:                              # noqa: BLE001
            pass
