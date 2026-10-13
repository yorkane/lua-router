#!/usr/bin/env python3
"""Dependency-aware scheduler: one pool, no phase barrier.

The old script had three hard-coded waves: a portless pool, a shared-pool, and a
serial tail, with a barrier between each. Barriers are the wrong shape for this
gate set -- build takes 3s here while contract takes 155s, so a build barrier
threw away two minutes of wall clock, and the serial tail was justified by
reasons that an audit showed to be about observation windows, not about waves.

What this scheduler does instead:

  * one pool, GATE_JOBS wide. Default is min(8, cpu): the box has 144 cores, and
    the audit measured that the pool saturates on docker-daemon and CPU work
    well before 8 concurrent container suites, so a bigger number buys nothing.
    GATE_JOBS=1 is the explicit serial run, in GATE_ORDER.
  * dependency edges only. conf/unit/contract/probes start immediately; every
    suite that boots the image waits for the build GATE, not for a wave. A red
    build marks its dependents invalid rather than launching 15 suites that would
    all fail for the same unrelated reason.
  * per-gate locks (see locks.py): ordinary HTTP gates share the observation
    window, the build takes a prepare lock of its own. e2e_watcher declares NO
    lock: its machine-scan hazard is neutralised suite-side by the test-side
    docker.sock proxy (test/integration/docker_test_proxy.py), so it pools like
    any other gate -- the property the serial tail used to buy is now provided
    by the harness, not by the schedule.
  * a gate is only green when its body both exited 0 and published its result
    marker. A child that dies on a signal, is killed, exits without the marker,
    or disappears, is recorded as crash and the run never hangs on it.
"""

import os
import subprocess
import threading
import time

from . import bodies, catalog, locks, results

ENV_RESULT = "LR_GATE_RESULT"


def default_jobs():
    try:
        n = os.cpu_count() or 4
    except OSError:
        n = 4
    return max(1, min(8, n))


class Scheduler:
    def __init__(self, ctx, manifest, gates, skips=(), jobs=None, print=print,
                 on_build=None):
        self.ctx = ctx
        self.manifest = manifest
        self.gates = list(gates)
        self.skips = set(skips)
        self.jobs = jobs if jobs is not None else default_jobs()
        self.print = print
        self.on_build = on_build
        self.lock = threading.Lock()
        self.live = []                    # (gate, Popen)
        self.records = {}
        self.states = {}                  # name -> pending/running/done
        self.wake = threading.Semaphore(0)
        self.stop = threading.Event()
        # Set by abort(): an rc<0 death that follows a runner-initiated kill must
        # say so. 'killed by signal 9' alone reads as the body crashing, and the
        # point of the abort path is that the killer was us.
        self.abort_reason = ""

    # -- readiness ---------------------------------------------------------
    def _ready(self, gate):
        selected = set(g.name for g in self.gates)
        for dep in gate.depends:
            if dep in self.skips:
                continue                  # an explicit skip does not block
            st = self.states.get(dep)
            if dep not in selected:
                continue                  # dependency outside this selection
            if st == "done":
                rec = self.records.get(dep)
                if not rec or rec["status"] not in (results.PASS, results.SKIP):
                    return "blocked"      # dependency red/crashed/invalid
                continue                  # dependency green: this edge is satisfied
            elif st in ("pending", "running"):
                return "waiting"          # in flight: the outcome is not decided
            # st is None: the dependency never entered this scheduler, so the
            # edge cannot be satisfied. Block it; waiting would be a hang.
            return "blocked"
        return "ready"

    def _next_ready(self):
        for g in self.gates:
            if self.states[g.name] == "pending" and self._ready(g) == "ready":
                return g
        return None

    def _blocked_by_deps(self, gate):
        for dep in gate.depends:
            if dep in self.skips or dep not in set(g.name for g in self.gates):
                continue
            rec = self.records.get(dep)
            if self.states.get(dep) == "done" and (not rec or rec["status"]
                                                   not in (results.PASS,
                                                           results.SKIP)):
                return dep
            if self.states.get(dep) not in ("done", "running", "pending"):
                return dep
        return None

    # -- one gate ----------------------------------------------------------
    def run_gate(self, gate):
        self.states[gate.name] = "running"
        log_path = os.path.join(self.ctx.log_dir, gate.name + ".log")
        env = self.ctx.gate_env(gate)
        marker = os.path.join(self.ctx.tmp, gate.name + ".result")
        env[ENV_RESULT] = marker
        open(log_path, "a").close()
        argv = bodies.body_argv(self.manifest, gate)
        # LR_GATE_MANIFEST is injected by the run context (ctx.manifest_path: the
        # manifest this run froze, which the build body pins its base from). The
        # context owns that file, so the scheduler never writes it -- two writers
        # on one identity document is exactly the drift this split prevents.
        # Lock queue time is not gate execution time.
        t0 = None
        status, rc, detail, pid = results.CRASH, None, "", None
        handles = []
        proc = None
        try:
            handles = locks.acquire_gate_locks(gate)
            t0 = time.time()
            with open(log_path, "ab") as logfh:
                proc = subprocess.Popen(argv, cwd=self.manifest["snapshot"], env=env,
                                        stdout=logfh, stderr=subprocess.STDOUT,
                                        start_new_session=True,
                                        stdin=subprocess.DEVNULL)
            pid = proc.pid
            with self.lock:
                self.live.append((gate, proc))
            # Registered with the run context so an interrupt (signal, escaping
            # exception) can stop exactly this run's bodies. Containers outlive a
            # killed parent -- the daemon owns them -- so the context also
            # label-sweeps this run's namespace on cleanup.
            register = getattr(self.ctx, "register_child", None)
            if register:
                register(proc)
            deadline = t0 + gate.timeout if gate.timeout else None
            while True:
                try:
                    rc = proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    if self.stop.is_set():
                        status = results.CRASH
                        detail = "aborted by the runner"
                        _kill_group(proc.pid)
                        try:
                            proc.wait(timeout=2.0)
                        except subprocess.TimeoutExpired:
                            pass
                        break
                    if deadline and time.time() > deadline:
                        status = results.TIMEOUT
                        detail = "timeout after %ss; process group killed" % gate.timeout
                        _kill_group(proc.pid)
                        try:
                            proc.wait(timeout=2.0)
                        except subprocess.TimeoutExpired:
                            pass
                        break
                    continue
                break
            with self.lock:
                self.live = [(g, p) for g, p in self.live if p is not proc]
            unregister = getattr(self.ctx, "unregister_child", None)
            if unregister:
                unregister(proc)
            if status != results.TIMEOUT:
                if rc == 0 and not os.path.exists(marker):
                    status = results.CRASH
                    detail = ("exit 0 without a result marker (%s): the body died"
                              " on a signal, was killed, or bypassed its tail" % marker)
                elif rc == 5:
                    # The body decided this gate is not part of the selection
                    # (the contract gate reports 5 under a UI-only group filter).
                    # rc=5 means SKIP: recorded, visible, and it does not block
                    # the run. The historical e2e_effort lock printed SKIP and
                    # was counted FAIL; that contradiction ends here.
                    status = results.SKIP
                    detail = "body reported skip (rc=5)"
                elif rc < 0:
                    status = results.CRASH
                    detail = "killed by signal %d" % -rc
                    if self.abort_reason:
                        detail += " (runner abort: %s)" % self.abort_reason
                elif rc == 124:
                    status = results.TIMEOUT
                    detail = "timeout wrapper fired (rc=124)"
                elif rc == 0:
                    status = results.PASS
                    detail = ""
                else:
                    status = results.FAIL
                    detail = "body exited rc=%d" % rc
        except locks.LockTimeout as exc:
            status = results.CRASH
            detail = "lock: %s" % (exc,)
        except OSError as exc:
            status = results.CRASH
            detail = "spawn failed: %s" % (exc,)
        finally:
            locks.release_gate_locks(handles)
            if proc is not None:
                with self.lock:
                    self.live = [(g, p) for g, p in self.live if p is not proc]
                unregister = getattr(self.ctx, "unregister_child", None)
                if unregister:
                    unregister(proc)
        dur = time.time() - (t0 if t0 is not None else time.time())
        # A timeout, a SIGKILL, or a crash before the suite's own trap leaves
        # containers behind, and a leftover published port is what makes the NEXT
        # gate red for an unrelated reason. Sweep by this gate's exact namespace
        # label (never a global lr- sweep), and only for a gate that did not pass
        # -- a green suite already cleaned up after itself, and sweeping a green
        # gate's namespace would mean trusting the suite's own teardown.
        swept = []
        if status != results.PASS:
            sweep = getattr(self.ctx, "sweep_gate", None)
            if sweep:
                try:
                    swept = sweep(gate)
                except Exception as exc:                       # noqa: BLE001
                    detail = (detail + "; sweep failed: %s" % (exc,))[-500:]
        # The record is written against the manifest the body ACTUALLY ran under.
        # For the build gate that means the image id the build just produced, so
        # every aggregate can bind the whole run to one immutable image.
        if (gate.name == "build" and status == results.PASS and self.on_build
                and rc == 0):
            try:
                self.manifest = self.on_build(self.manifest)
                # The ctx owns the gate env and the on-disk run manifest, and
                # gate_env is read at launch time: after the build filled in
                # the image id, every gate that launches next must be handed
                # the BUILT id, and the file the shell bodies pin from must
                # say the same. Sync through the ctx so its manifest_path is
                # rewritten in the same breath (the context owns that file;
                # the scheduler writing it directly is the two-writer drift
                # this split prevents).
                sync = getattr(self.ctx, "update_manifest", None)
                if sync:
                    sync(self.manifest)
            except Exception as exc:                       # noqa: BLE001
                status = results.FAIL
                detail = "build succeeded but its image id is unresolvable: %s" % (exc,)
        rec = results.make_record(gate, self.ctx, self.manifest, status, rc, dur,
                                  log_path, detail, pid=pid,
                                  container_ns=_gate_ns(self.ctx, gate),
                                  swept_containers=len(swept))
        results.write(self.ctx.result_dir, rec)
        with self.lock:
            self.records[gate.name] = rec
            self.states[gate.name] = "done"
        self._emit(rec)
        self.wake.release()
        return rec

    def _emit(self, rec):
        tag = rec["status"].upper()
        self.print("== gate: %-24s %-8s (%3.0fs) %s" % (
            rec["gate"], tag, rec["duration"], (rec.get("detail") or "")[:80]))
        if rec["status"] in results.BLOCKING and rec.get("log"):
            from . import context as _ctx
            for line in _ctx.tail(rec["log"], 25):
                self.print("   | " + line)

    def _record_skip(self, gate):
        rec = results.make_record(gate, self.ctx, self.manifest, results.SKIP, None,
                                  0.0, None, "SKIP_ENV")
        results.write(self.ctx.result_dir, rec)
        self.records[gate.name] = rec
        self.states[gate.name] = "done"
        self.print("== gate: %-24s SKIPPED (SKIP_ENV)" % gate.name)

    def _record_blocked(self, gate, dep):
        rec = results.make_record(gate, self.ctx, self.manifest, results.INVALID,
                                  None, 0.0, None,
                                  "not started: dependency %s is not green" % dep)
        results.write(self.ctx.result_dir, rec)
        self.records[gate.name] = rec
        self.states[gate.name] = "done"
        self.print("== gate: %-24s INVALID  dependency %s not green" % (gate.name, dep))

    # -- pool --------------------------------------------------------------
    def run(self):
        for g in self.gates:
            self.states[g.name] = "pending"
            if g.name in self.skips:
                self._record_skip(g)
        if self.jobs <= 1:
            self._serial()
        else:
            self._pool()
        # Drain what the pool left behind. A gate can still be pending when the
        # pool's last wave finished (its dependency only became green in that
        # wave), so this is a real pass, not an error path: re-run the ready
        # gates and record the blocked ones. Bounded, and any residue at the end
        # is recorded as blocked rather than left out of the report -- a missing
        # gate must never be able to read as a passing one.
        for _round in range(4):
            pending = [g for g in self.gates if self.states[g.name] == "pending"]
            if not pending:
                break
            progressed = False
            for g in pending:
                state = self._ready(g)
                if state == "ready":
                    self.run_gate(g)
                    progressed = True
                elif state == "blocked":
                    self._record_blocked(g, self._blocked_by_deps(g)
                                         or "dependency not green")
                    progressed = True
            if not progressed:
                break
        for g in self.gates:
            if self.states[g.name] != "done":
                self._record_blocked(g, self._blocked_by_deps(g)
                                     or "no ready slot (scheduler drained)")
        return self.records

    def _serial(self):
        for g in self.gates:
            if self.states[g.name] != "pending":
                continue
            state = self._ready(g)
            if state == "blocked":
                self._record_blocked(g, self._blocked_by_deps(g))
            elif state == "ready":
                self.run_gate(g)

    def _pool(self):
        running = []
        while True:
            if self.stop.is_set():
                break
            running = [t for t in running if t.is_alive()]
            started = False
            while len(running) < self.jobs:
                g = self._next_ready()
                if g is None:
                    break
                t = threading.Thread(target=self.run_gate, args=(g,),
                                     name="gate-" + g.name, daemon=True)
                self.states[g.name] = "running"
                running.append(t)
                t.start()
                started = True
            pending = [g for g in self.gates if self.states[g.name] == "pending"]
            if not pending and not running:
                break
            if not started and not running:
                # Nothing running, pending gates exist, none ready: dependencies
                # are red. Record them and keep draining.
                for g in list(pending):
                    if self._ready(g) == "blocked":
                        self._record_blocked(g, self._blocked_by_deps(g))
                if all(self.states[g.name] != "pending" for g in pending):
                    continue
                break
            self.wake.acquire(timeout=1.0)
            for t in running:
                t.join(0)

    def abort(self, reason=""):
        self.stop.set()
        self.abort_reason = reason or "aborted"
        with self.lock:
            snapshot = list(self.live)
        for gate, proc in snapshot:
            _kill_group(proc.pid)
        self.ctx.abort(reason)


def _gate_ns(ctx, gate):
    fn = getattr(ctx, "gate_namespace", None)
    return fn(gate) if fn else None


def _kill_group(pid):
    import signal
    try:
        os.killpg(os.getpgid(pid), signal.SIGKILL)
    except OSError:
        try:
            os.killpg(pid, signal.SIGKILL)
        except OSError:
            pass
