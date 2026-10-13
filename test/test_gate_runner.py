#!/usr/bin/env python3
"""Pure-runner tests for the gate scheduler: no docker, no HTTP, no ports.

This file is also the fake gate body: test/gates/bodies.py launches
python3 <this file> <gate> when LR_GATE_FAKE points here, and LR_FAKE_ACTIONS
decodes what each gate should do. That covers the parts the real gates cannot
show: selection (tier/group/single), unknown-name refusal, skip dedup,
dependency wiring without a phase barrier, result integrity (mixed versions,
missing records, swallowed failures, exit-0-without-marker, signal deaths),
run identity (per-gate namespace, shared ledger, no global run lock), and the
writer-preferring observation lock.

Run: python3 test/test_gate_runner.py
"""

import json
import os
import signal
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gates import bodies, catalog, context, locks, results, scheduler   # noqa: E402
from gates import runner                                          # noqa: E402

FAKE = os.path.abspath(__file__)
CHECKS = []
ACTIONS = json.loads(os.environ.get("LR_FAKE_ACTIONS", "{}"))
TRACE = os.environ.get("LR_FAKE_TRACE")
NS_DIR = os.environ.get("LR_FAKE_NS_DIR")


def check(name, cond, detail=""):
    CHECKS.append((bool(cond), name, "" if cond else str(detail)[:400]))
    print(("PASS  " if cond else "FAIL  ") + name
          + ("" if cond else "   | " + str(detail)[:300]))
    return bool(cond)


# ------------------------------------------------------------------ fake body
def fake_body(gate):
    action, nap = ACTIONS.get(gate, ("pass", 0.0))
    if NS_DIR:
        os.makedirs(NS_DIR, exist_ok=True)
        with open(os.path.join(NS_DIR, gate + ".env.json"), "w") as fh:
            json.dump({k: os.environ.get(k) for k in
                       ("LR_RUN_ID", "LR_GATE_TAG", "LR_TEST_TMP",
                        "LR_PORT_RESERVE", "LR_GATE_RESULT",
                        "LR_GATE_MANIFEST", "LR_IMAGE")}, fh)
    if TRACE:
        with open(TRACE, "a") as fh:
            fh.write("start %s %.3f\n" % (gate, time.time()))
    if action == "hang":
        time.sleep(nap or 600)
    elif nap:
        time.sleep(nap)
    if TRACE:
        with open(TRACE, "a") as fh:
            fh.write("end %s %.3f\n" % (gate, time.time()))
    marker = os.environ.get("LR_GATE_RESULT")
    if action == "pass":
        if marker:
            open(marker, "w").write("ok\n")
        return 0
    if action == "nomarker":
        return 0
    if action == "fail":
        print("fake body %s: deliberate failure" % gate)
        return 1
    if action == "fail_marker":
        if marker:
            open(marker, "w").write("ok\n")
        return 3
    if action == "skip":
        return 5
    if action == "signal":
        os.kill(os.getpid(), signal.SIGKILL)
        time.sleep(5)
        return 0
    raise SystemExit("fake body: unknown action %r" % action)


# ------------------------------------------------------------------ harness
def stub_manifest(fingerprint="f" * 64):
    return {"schema": 1, "fingerprint": fingerprint, "files": 1,
            "snapshot": os.path.dirname(HERE), "repo": os.path.dirname(HERE),
            "image_tag": "lua-router:gate-test", "image_id": "sha256:aaaa",
            "authz_ref": "authz:latest", "authz_id": "sha256:bbbb",
            "resty_ref": "apache/apisix:3.11.0-debian", "resty_id": "sha256:cccc"}


def run_gates(names, actions, jobs=4, skips=(), groups=None, extra_env=None,
              lock_dir=None, manifest=None, ctx_hook=None):
    """Schedule the named gates against the fake backend."""
    root = tempfile.mkdtemp(prefix="lr-runner-test.")
    manifest = manifest or stub_manifest()
    ctx = context.RunContext(manifest, log_dir=root, groups=groups)
    if ctx_hook:
        ctx_hook(ctx)
    os.environ["LR_GATE_FAKE"] = FAKE
    os.environ["LR_FAKE_ACTIONS"] = json.dumps(actions)
    os.environ["LR_GATE_LOCK_DIR"] = lock_dir or os.path.join(root, "locks")
    os.environ.update(extra_env or {})
    lines = []
    sched = scheduler.Scheduler(ctx, manifest,
                                [catalog.BY_NAME[n] for n in names],
                                skips=skips, jobs=jobs, print=lines.append)
    t0 = time.time()
    sched.run()
    wall = time.time() - t0
    recs = results.load(ctx.result_dir, manifest)
    report = results.aggregate(ctx.result_dir, manifest, tier="full",
                              expected=names)
    return {"records": dict((r["gate"], r) for r in recs), "ctx": ctx, "root": root,
            "manifest": manifest, "wall": wall, "out": "\n".join(lines),
            "ok": report[0], "report": report[1]}


# ------------------------------------------------------------------ tests
def test_selection():
    run, skip = catalog.selected("quick")
    check("quick tier = build conf unit contract probes",
          run == ["build", "conf", "unit", "contract", "probes"], run)
    run, _ = catalog.selected("full")
    check("full tier = all 22 gates", len(run) == 22 and len(catalog.GATE_ORDER) == 22)
    run, _ = catalog.selected("full", groups=["ui"])
    check("group ui selects the UI-carriers only",
          run == ["unit", "e2e_ui_bridge"], run)
    run, _ = catalog.selected("full", groups=["mesh", "tls"])
    check("group mesh+tls selects its three gates in run order",
          run == ["mesh_http", "mesh_two", "e2e_tls_chain"], run)
    run, skip = catalog.selected("full", skips=["conf", "conf"])
    check("skip dedups and is recorded, not dropped",
          "conf" not in run and skip == ["conf"], (run, skip))
    run, _ = catalog.selected("quick", only="e2e_caps")
    check("GATE_ONLY singles a gate out of the tier", run == ["e2e_caps"], run)
    try:
        catalog.selected("full", skips=["nope"])
        check("unknown gate name is refused", False, "no raise")
    except KeyError as exc:
        check("unknown gate name is refused", "nope" in str(exc), exc)
    try:
        catalog.selected("full", groups=["nope"])
        check("unknown group name is refused", False, "no raise")
    except KeyError as exc:
        check("unknown group name is refused", "nope" in str(exc), exc)
    for gate in catalog.GATES:
        for dep in gate.depends:
            if dep not in catalog.BY_NAME:
                check("dependency of %s resolves" % gate.name, False, dep)
                break
        else:
            continue
        break
    else:
        check("every dependency edge resolves", True)
    check("every image-booting gate depends on build",
          all("build" in catalog.BY_NAME[n].depends
              for n in catalog.GATE_ORDER
              if catalog.BY_NAME[n].needs_image and n != "build"))
    check("the catalog is exactly the 22 historical gates",
          catalog.GATE_ORDER == ["build", "conf", "unit", "contract", "probes",
                                 "e2e_stateful", "e2e_policies", "e2e_ui_bridge",
                                 "e2e_errors", "e2e_effort", "head_routes",
                                 "mesh_http", "e2e_policy_parity", "e2e_watcher",
                                 "e2e_token_accounting", "e2e_gpu_load",
                                 "e2e_routing_dyn", "e2e_profiles", "e2e_caps",
                                 "e2e_models_advertisement", "mesh_two",
                                 "e2e_tls_chain"], catalog.GATE_ORDER)


def test_ui_group_is_real():
    m = stub_manifest()
    ctx = context.RunContext(m, log_dir=tempfile.mkdtemp(prefix="lr-runner-test."),
                             groups=["ui"])
    env = ctx.gate_env(catalog.BY_NAME["unit"])
    check("UI-only selection marks the unit subset", env["LR_GATE_UI_ONLY"] == "1", env)
    ctx2 = context.RunContext(m, log_dir=tempfile.mkdtemp(prefix="lr-runner-test."))
    check("a full run leaves the unit gate whole",
          "LR_GATE_UI_ONLY" not in ctx2.gate_env(catalog.BY_NAME["unit"]))
    ctx3 = context.RunContext(m, log_dir=tempfile.mkdtemp(prefix="lr-runner-test."),
                              groups=["ui", "base"])
    check("a wider group does not narrow the unit gate",
          "LR_GATE_UI_ONLY" not in ctx3.gate_env(catalog.BY_NAME["unit"]))


def test_no_phase_barrier():
    # build is slow; the portless gates must not wait for it, and the suites
    # that need the image must start the moment build lands.
    acts = {"build": ("pass", 2.0), "conf": ("pass", 0.2), "unit": ("pass", 0.2),
            "contract": ("pass", 0.2), "e2e_caps": ("pass", 0.2),
            "e2e_gpu_load": ("pass", 0.2)}
    r = run_gates(["build", "conf", "unit", "contract", "e2e_caps",
                   "e2e_gpu_load"], acts, jobs=6)
    check("pool overlaps build: wall clock is build, not the sum",
          2.0 <= r["wall"] < 3.6, "%.2fs" % r["wall"])
    caps = r["records"]["e2e_caps"]
    build = r["records"]["build"]
    check("an image gate starts only after build is green",
          caps["status"] == "pass" and caps["duration"] < build["duration"] + 1.5,
          (caps["duration"], build["duration"]))


def test_red_build_blocks_dependents():
    acts = {"build": ("fail", 0.0), "conf": ("pass", 0.1), "unit": ("pass", 0.1),
            "e2e_caps": ("pass", 5.0), "e2e_gpu_load": ("pass", 5.0)}
    r = run_gates(["build", "conf", "unit", "e2e_caps", "e2e_gpu_load"], acts,
                  jobs=6)
    check("red build does not run the image suites",
          r["records"]["e2e_caps"]["status"] == "invalid"
          and r["records"]["e2e_gpu_load"]["status"] == "invalid",
          [(g, x["status"]) for g, x in r["records"].items()])
    check("a red build is reported as blocked by build",
          "build" in (r["records"]["e2e_caps"]["detail"] or ""),
          r["records"]["e2e_caps"]["detail"])
    check("the gates that do not need the image still ran",
          r["records"]["conf"]["status"] == "pass"
          and r["records"]["unit"]["status"] == "pass")
    check("blocked dependents never run (duration ~0)",
          r["records"]["e2e_caps"]["duration"] < 1.0,
          r["records"]["e2e_caps"]["duration"])
    check("a red build makes the run non-green", r["ok"] is False)
    check("blocked dependents are counted as invalid, not silent",
          r["report"]["counts"]["invalid"] == 2, r["report"]["counts"])


def test_failure_not_swallowed():
    acts = {"conf": ("pass", 0.0), "unit": ("fail", 0.0), "contract": ("pass", 0.0)}
    r = run_gates(["conf", "unit", "contract"], acts, jobs=3)
    check("a failing gate is FAIL, not skipped",
          r["records"]["unit"]["status"] == "fail", r["records"]["unit"]["status"])
    check("a failing gate blocks the run", r["ok"] is False)
    check("a failing gate does not stop the pool",
          r["records"]["conf"]["status"] == "pass"
          and r["records"]["contract"]["status"] == "pass")
    check("the red gate shows its own log tail",
          "deliberate failure" in r["out"], r["out"][:200])
    r2 = run_gates(["conf"], {"conf": ("fail_marker", 0.0)}, jobs=1)
    check("a marker written by a red body does not turn it green",
          r2["records"]["conf"]["status"] == "fail", r2["records"]["conf"])
    r3 = run_gates(["conf", "unit"], {"unit": ("skip", 0.0)}, jobs=2)
    check("a body that reports rc=5 is a recorded skip",
          r3["records"]["unit"]["status"] == "skip", r3["records"]["unit"]["status"])
    check("a body-reported skip blocks a release anchor", r3["ok"] is False)
    check("a body-reported skip is green for its own subset",
          r3["report"]["selection_green"] is True, r3["report"]["counts"])


def test_cold_selection_closes_the_build_edge():
    """A cold group/only selection must not launch image gates with no image.

    Group/GATE_ONLY selection is scoped by design; that is right for a warm
    prepared manifest and broken for a cold one -- the scheduler's dependency
    edge points at a gate outside the selection, so the gate boots a derived tag
    nobody built. runner.include_cold_build_dependency closes exactly that edge.
    """
    cold, warm = {"image_id": None}, {"image_id": "sha256:abcd"}
    ui_run, ui_skip = catalog.selected("full", groups=["ui"])
    run, skip, why = runner.include_cold_build_dependency(ui_run, ui_skip, cold)
    check("a cold ui group gains the build prerequisite",
          run[0] == "build" and "e2e_ui_bridge" in run, run)
    check("the auto-build is reported as a cold dependency, not a skip",
          why == "cold image dependency" and skip == [], (why, skip))
    run, skip, why = runner.include_cold_build_dependency(ui_run, ui_skip, warm)
    check("a warm prepared manifest stays exactly the requested subset",
          run == ui_run and why is None, (run, why))
    caps_run, caps_skip = catalog.selected("full", only="e2e_caps")
    run, _, why = runner.include_cold_build_dependency(caps_run, caps_skip, cold)
    check("GATE_ONLY of an image gate also closes its build edge",
          run == ["build", "e2e_caps"], run)
    unit_run, unit_skip = catalog.selected("full", only="unit")
    run, _, why = runner.include_cold_build_dependency(unit_run, unit_skip, cold)
    check("a selection with no image-booting gate gains no build",
          run == unit_run and why is None, (run, why))
    quick_run, quick_skip = catalog.selected("quick")
    run, _, why = runner.include_cold_build_dependency(quick_run, quick_skip, cold)
    check("a tier that already carries build is left alone",
          run == quick_run and why is None, (run[:3], why))
    run, skip, why = runner.include_cold_build_dependency(
        ui_run, ui_skip, cold, explicit_skips=["build"])
    check("SKIP_ENV=build is honoured and stays visible as a recorded skip",
          "build" in skip and "build" not in run and skip == ["build"], (run, skip))
    full_run, full_skip = catalog.selected("full")
    run, _, why = runner.include_cold_build_dependency(full_run, full_skip, cold)
    check("a full selection is untouched by the closure",
          run == full_run and why is None, run[:3])


def test_child_crash_never_hangs():
    r = run_gates(["conf"], {"conf": ("nomarker", 0.0)}, jobs=1)
    check("exit 0 without a result marker is a crash",
          r["records"]["conf"]["status"] == "crash", r["records"]["conf"]["status"])
    check("a crash blocks the run", r["ok"] is False)
    r2 = run_gates(["unit"], {"unit": ("signal", 0.0)}, jobs=1)
    check("a body killed by a signal is a crash",
          r2["records"]["unit"]["status"] == "crash", r2["records"]["unit"])
    check("the scheduler did not hang on it", r2["wall"] < 30, r2["wall"])
    gate = catalog.Gate("hangtest", catalog.BASE, 1, catalog.OBS_SHARED)
    catalog.BY_NAME["hangtest"] = gate
    catalog.GATES.append(gate)
    try:
        r3 = run_gates(["hangtest"], {"hangtest": ("hang", 60)}, jobs=1)
        check("a hung gate times out and is recorded",
              r3["records"]["hangtest"]["status"] == "timeout",
              r3["records"]["hangtest"]["status"])
        check("the timeout is prompt (gate budget + slack)", r3["wall"] < 10,
              r3["wall"])
    finally:
        catalog.BY_NAME.pop("hangtest", None)
        catalog.GATES.remove(gate)


def test_missing_record_is_a_crash():
    root = tempfile.mkdtemp(prefix="lr-runner-test.")
    m = stub_manifest()
    results.write(root, results.make_record(catalog.BY_NAME["conf"], None, m,
                                            "pass", 0, 1.0, None))
    ok, report = results.aggregate(root, m, tier="quick", expected=["conf", "unit"])
    check("a missing record blocks the run", ok is False, report["reason"])
    check("a missing record is counted as crash", report["counts"]["crash"] == 1,
          report["counts"])
    unit = [x for x in report["rows"] if x["gate"] == "unit"][0]
    check("the missing gate is reported by name",
          unit["status"] == "crash" and "no result" in unit["detail"], unit)
    with open(os.path.join(root, "probes.json"), "w") as fh:
        fh.write("{not json")
    ok2, report2 = results.aggregate(root, m, tier="quick", expected=["conf", "probes"])
    probes = [x for x in report2["rows"] if x["gate"] == "probes"][0]
    check("an unreadable result file is invalid", probes["status"] == "invalid", probes)
    check("an invalid record blocks the run", ok2 is False)
    results.write(root, {"gate": "made-up", "status": "pass",
                         "fingerprint": m["fingerprint"], "image_id": m["image_id"],
                         "rc": 0, "duration": 1, "group": "base", "detail": ""})
    ok3, report3 = results.aggregate(root, m, tier="quick", expected=["conf", "probes"])
    check("a stray record is flagged as outside the selection",
          any(x["gate"] == "made-up" and "outside selection" in x["detail"]
              for x in report3["rows"]), report3["rows"])
    try:
        results.aggregate(root, m, tier="quick", expected=["conf", "made-up"])
        check("an unknown gate in the selection is refused", False, "no raise")
    except KeyError as exc:
        check("an unknown gate in the selection is refused", "made-up" in str(exc), exc)
    check("a result for an unknown gate is invalid",
          ok3 is False and any(x["gate"] == "made-up" and x["status"] == "invalid"
                               for x in report3["rows"]), report3["counts"])


def test_partial_run_cannot_claim_full_green():
    root = tempfile.mkdtemp(prefix="lr-runner-test.")
    m = stub_manifest()
    quick = ["build", "conf", "unit", "contract", "probes"]
    for name in quick:
        results.write(root, results.make_record(catalog.BY_NAME[name], None, m,
                                                "pass", 0, 1.0, None))
    ok, rep = results.aggregate(root, m, tier="full", expected=list(catalog.GATE_ORDER))
    check("a partial run cannot claim full green",
          ok is False and rep["counts"]["crash"] == 17, rep["counts"])
    check("a partial run is not anchor-eligible", rep["full_anchor_eligible"] is False)
    ok2, rep2 = results.aggregate(root, m, tier="quick", expected=quick)
    check("the same five records are a complete quick run", ok2 is True, rep2["reason"])
    check("a quick run is never a 22-gate anchor",
          rep2["full_anchor_eligible"] is False)
    rep3 = results.aggregate(root, m, tier="quick", expected=quick + ["e2e_caps"])
    check("an expected gate with no record is missing, not ignored",
          rep3[0] is False and rep3[1]["counts"]["missing"] == 1, rep3[1]["counts"])
    skiproot = tempfile.mkdtemp(prefix="lr-runner-test.")
    for name in quick:
        status = "skip" if name == "probes" else "pass"
        results.write(skiproot, results.make_record(catalog.BY_NAME[name], None, m,
                                                    status, None if status == "skip" else 0,
                                                    1.0, None, "SKIP_ENV"))
    ok4, rep4 = results.aggregate(skiproot, m, tier="quick", expected=quick)
    check("a SKIP_ENV skip blocks release", ok4 is False, rep4["reason"])
    check("a skip keeps the run green for its own subset",
          rep4["selection_green"] is True, rep4["counts"])


def test_mixed_versions_refused():
    root = tempfile.mkdtemp(prefix="lr-runner-test.")
    m = stub_manifest("a" * 64)
    other = stub_manifest("b" * 64)
    results.write(root, results.make_record(catalog.BY_NAME["conf"], None, m,
                                            "pass", 0, 1.0, None))
    results.write(root, results.make_record(catalog.BY_NAME["unit"], None, other,
                                            "pass", 0, 1.0, None))
    m2 = dict(m)
    m2["image_id"] = "sha256:deadbeef"
    results.write(root, results.make_record(catalog.BY_NAME["contract"], None, m2,
                                            "pass", 0, 1.0, None))
    m3 = dict(m)
    m3["resty_id"] = "sha256:other"
    results.write(root, results.make_record(catalog.BY_NAME["probes"], None, m3,
                                            "pass", 0, 1.0, None))
    ok, report = results.aggregate(root, m, tier="quick",
                                   expected=["conf", "unit", "contract", "probes"])
    rows = dict((x["gate"], x) for x in report["rows"])
    check("a foreign source fingerprint is refused",
          rows["unit"]["status"] == "invalid", rows["unit"])
    check("a foreign image id is refused",
          rows["contract"]["status"] == "invalid", rows["contract"])
    check("a foreign resty image id is refused",
          rows["probes"]["status"] == "invalid", rows["probes"])
    check("mixed results block the run", ok is False, report["reason"])
    check("the same-version record stays valid", rows["conf"]["status"] == "pass",
          rows["conf"])
    check("the refusal says which field",
          "fingerprint" in rows["unit"]["detail"]
          and "image_id" in rows["contract"]["detail"],
          (rows["unit"]["detail"], rows["contract"]["detail"]))


def test_namespace_isolation():
    ns = tempfile.mkdtemp(prefix="lr-runner-ns.")
    ledger = os.path.join(ns, "machine-ports.reserved")
    r = run_gates(["conf", "unit", "contract"], {}, jobs=3,
                  extra_env={"LR_FAKE_NS_DIR": ns, "LR_PORT_RESERVE": ledger})
    seen = {}
    for fn in sorted(os.listdir(ns)):
        if fn.endswith(".env.json"):
            with open(os.path.join(ns, fn)) as fh:
                seen[fn] = json.load(fh)
    check("each gate gets a different LR_GATE_TAG",
          len(set(v["LR_GATE_TAG"] for v in seen.values())) == 3, seen)
    check("each gate gets a different LR_TEST_TMP",
          len(set(v["LR_TEST_TMP"] for v in seen.values())) == 3, seen)
    check("all gates share one run id",
          len(set(v["LR_RUN_ID"] for v in seen.values())) == 1, seen)
    check("all gates share the machine port ledger",
          len(set(v["LR_PORT_RESERVE"] for v in seen.values())) == 1
          and next(iter(seen.values()))["LR_PORT_RESERVE"] == ledger, seen)
    check("the runner does not set LR_PORT_OWNER_PID",
                    all("LR_PORT_OWNER_PID" not in v for v in seen.values()), seen)
    check("each gate temp includes only its own gate name",
          all(fn.replace(".env.json", "")[:-4] in v["LR_TEST_TMP"]
              for fn, v in seen.items()), seen)
    # The build gate pins its base from the manifest the RUN froze, so every
    # body must be handed that path and it must describe this run.
    paths = set(v.get("LR_GATE_MANIFEST") for v in seen.values())
    check("every gate body is handed the run manifest path",
          len(paths) == 1 and next(iter(paths)), seen)
    mp = next(iter(paths))
    check("the run manifest exists for the bodies",
          bool(mp) and os.path.exists(mp), mp)
    if mp and os.path.exists(mp):
        with open(mp) as fh:
            doc = json.load(fh)
        check("the published manifest carries this run's fingerprint",
              doc.get("fingerprint") == "f" * 64, doc.get("fingerprint"))
        check("the manifest names the gate image tag the bodies use",
              doc.get("image_tag") == stub_manifest()["image_tag"], doc.get("image_tag"))
    r2 = run_gates(["conf"], {}, jobs=1)
    r3 = run_gates(["conf"], {}, jobs=1)
    check("two overlapping run contexts have unique id/log/result/tmp dirs",
          r2["ctx"].run_id != r3["ctx"].run_id
          and r2["ctx"].root != r3["ctx"].root
          and r2["ctx"].tmp != r3["ctx"].tmp,
          (r2["ctx"].run_id, r3["ctx"].run_id))


def test_source_fingerprint():
    root = tempfile.mkdtemp(prefix="lr-fingerprint.")
    for rel in context.SNAPSHOT_PATHS:
        dst = os.path.join(root, rel)
        if rel in ("lualib", "conf", "ui", "test"):
            os.makedirs(dst, exist_ok=True)
            with open(os.path.join(dst, "one.txt"), "w") as fh:
                fh.write(rel + "\n")
        else:
            with open(dst, "w") as fh:
                fh.write(rel + "\n")
    first = context.source_fingerprint(root)
    second = context.source_fingerprint(root)
    check("fingerprint is reproducible", first["fingerprint"] == second["fingerprint"])
    with open(os.path.join(root, "test", "one.txt"), "a") as fh:
        fh.write("changed harness byte\n")
    third = context.source_fingerprint(root)
    check("harness changes change the source fingerprint",
          third["fingerprint"] != first["fingerprint"])
    # A docs-only path is outside the snapshot contract by construction.
    with open(os.path.join(root, "README.md"), "w") as fh:
        fh.write("docs")
    fourth = context.source_fingerprint(root)
    check("README/docs edits do not invalidate the gate source fingerprint",
          fourth["fingerprint"] == third["fingerprint"])


def _lock_writer(ld, entered, leave):
    w = locks.RWLock("obs", timeout=30, poll=0.05, lock_dir=ld)
    w.acquire_exclusive()
    entered.set()
    leave.wait(5)
    w.release()


def test_locks():
    ld = tempfile.mkdtemp(prefix="lr-locks.")
    a = locks.RWLock("obs", lock_dir=ld)
    b = locks.RWLock("obs", lock_dir=ld)
    a.acquire_shared()
    b.acquire_shared()
    check("shared readers overlap", True)
    b.release()
    a.release()
    w = locks.RWLock("obs", lock_dir=ld, poll=0.05)
    w.acquire_exclusive()
    r = locks.RWLock("obs", timeout=1.0, poll=0.05, lock_dir=ld)
    t0 = time.time()
    try:
        r.acquire_shared()
        check("an exclusive window blocks new readers", False, "acquired while held")
    except locks.LockTimeout:
        check("an exclusive window blocks new readers",
              time.time() - t0 >= 0.9, time.time() - t0)
    w.release()
    r.acquire_shared()
    check("the window opens once the writer releases", True)
    r.release()
    # writer preference: a reader holding the window must not admit a late
    # reader over a writer that queued in between
    h = locks.RWLock("obs", lock_dir=ld)
    h.acquire_shared()
    entered, leave = threading.Event(), threading.Event()
    wt = threading.Thread(target=_lock_writer, args=(ld, entered, leave), daemon=True)
    wt.start()
    time.sleep(0.3)
    late = locks.RWLock("obs", timeout=1.0, poll=0.05, lock_dir=ld)
    t0 = time.time()
    try:
        late.acquire_shared()
        check("a queued writer blocks new readers (no writer starvation)", False,
              "a late reader slipped in")
    except locks.LockTimeout:
        check("a queued writer blocks new readers (no writer starvation)",
              time.time() - t0 >= 0.9, time.time() - t0)
    leave.set()
    wt.join(5)
    h.release()
    # dead-owner pruning: a slot whose pid died must not wedge the lock
    st = locks._State("obs", ld)
    st.mutate(lambda rows: (rows + [("x", 999999, "dead-1"), ("r", 999998, "dead-2")],
                            None))
    z = locks.RWLock("obs", timeout=3, poll=0.05, lock_dir=ld)
    z.acquire_exclusive()
    check("slots of dead owners are pruned, not obeyed", True)
    z.release()
    bl = locks.FileLock("build", timeout=3, lock_dir=ld)
    bl.acquire()
    o = locks.RWLock("obs", timeout=3, poll=0.05, lock_dir=ld)
    o.acquire_shared()
    check("the build prepare lock does not block observation", True)
    o.release()
    bl.release()
    b1 = locks.FileLock("build", timeout=1, lock_dir=ld)
    b2 = locks.FileLock("build", timeout=1, lock_dir=ld)
    b1.acquire()
    try:
        b2.acquire()
        check("the build lock is a mutex", False, "both acquired")
    except locks.LockTimeout:
        check("the build lock is a mutex", True)
    b1.release()


def test_watcher_pools_without_a_lock():
    # The watcher's machine-scan hazard is now neutralised suite-side: the
    # snapshot ships test/integration/docker_test_proxy.py, which filters the
    # docker socket events to this run's fixture containers while keeping the
    # raw port fields, and the suite starts it through
    # e2e_watcher.py starts it via socket_path_for. The runner therefore gives the
    # watcher NO lock: it must pool like any other gate.
    gate = catalog.BY_NAME["e2e_watcher"]
    check("the watcher gate declares no scheduler lock", gate.locks == (), gate.locks)
    ld = tempfile.mkdtemp(prefix="lr-locks2.")
    trace = os.path.join(ld, "overlap.trace")
    acts = {"e2e_watcher": ("pass", 1.5), "conf": ("pass", 0.4),
            "unit": ("pass", 0.4), "contract": ("pass", 0.4),
            "probes": ("pass", 0.4)}
    r = run_gates(["conf", "unit", "contract", "probes", "e2e_watcher"], acts,
                  jobs=8, lock_dir=ld, extra_env={"LR_FAKE_TRACE": trace})
    spans = {}
    for line in open(trace):
        kind, name, ts = line.split()
        spans.setdefault(name, {})[kind] = float(ts)
    check("all five gates ran", len(spans) == 5, sorted(spans))
    w = spans["e2e_watcher"]
    overlap = [n for n, s in spans.items() if n != "e2e_watcher"
               and s["start"] < w["end"] and s["end"] > w["start"]]
    check("the watcher runs inside the pool, overlapping other gates",
          len(overlap) >= 1, overlap)
    check("the watcher gate is green",
          r["records"]["e2e_watcher"]["status"] == "pass")
    check("five gates in a width-8 pool overlap (wall < sum of durations)",
          r["wall"] < 3.0, r["wall"])
    check("the pool default is bounded by 8 even on a 144-core box",
          scheduler.default_jobs() <= 8, scheduler.default_jobs())
    check("an explicit serial width is honoured",
          scheduler.Scheduler(r["ctx"], stub_manifest(), [], jobs=1).jobs == 1)


def _hang_gate(name="hangtest", timeout=1):
    gate = catalog.Gate(name, catalog.BASE, timeout, catalog.OBS_SHARED)
    catalog.BY_NAME[name] = gate
    catalog.GATES.append(gate)
    return gate


def test_timeout_sweeps_the_gate_namespace():
    """A killed body leaves docker children behind: the sweep is label-exact."""
    swept = []

    def hook(ctx):
        # Instrumented in place: the scheduler calls ctx.sweep_gate(gate), and a
        # real sweep shells out to docker. What this test pins is that the
        # timeout/abort path CALLS it for this gate's namespace, at all.
        ctx.sweep_gate = lambda gate, grace=0.0: (swept.append(gate.name), [])[1]

    gate = _hang_gate()
    try:
        r = run_gates(["hangtest"], {"hangtest": ("hang", 60)}, jobs=1, ctx_hook=hook)
        check("a timed-out gate is recorded as timeout",
              r["records"]["hangtest"]["status"] == "timeout",
              r["records"]["hangtest"]["status"])
        check("the timeout sweeps exactly this gate's container namespace",
              swept == ["hangtest"], swept)
        check("the killed body is reaped, not left as a live child",
              ctx_children_empty(r["ctx"]), [p.pid for p in r["ctx"].children])
        pid = r["records"]["hangtest"]["pid"]
        check("the gate's process group is gone after the kill",
              not _pid_alive(pid), pid)
    finally:
        catalog.BY_NAME.pop("hangtest", None)
        catalog.GATES.remove(gate)


def test_abort_sweeps_and_records():
    """Ctrl-C must not leave the pool's children running."""
    swept = []

    def hook(ctx):
        ctx.sweep_gate = lambda gate, grace=0.0: (swept.append(gate.name), [])[1]
        ctx.cleanup_containers = lambda: []

    gate = _hang_gate("aborttest", timeout=300)
    try:
        root = tempfile.mkdtemp(prefix="lr-abort-test.")
        manifest = stub_manifest()
        ctx = context.RunContext(manifest, log_dir=root)
        hook(ctx)
        os.environ["LR_GATE_FAKE"] = FAKE
        os.environ["LR_FAKE_ACTIONS"] = json.dumps({"aborttest": ("hang", 60)})
        os.environ["LR_GATE_LOCK_DIR"] = os.path.join(root, "locks")
        sched = scheduler.Scheduler(ctx, manifest, [gate], jobs=1, print=lambda m: None)
        th = threading.Thread(target=sched.run, daemon=True)
        th.start()
        time.sleep(1.0)
        sched.abort("test interrupt")
        th.join(30)
        check("the aborted run finishes (no hang)", not th.is_alive())
        rec = results.read(results.path_for(ctx.result_dir, "aborttest"))
        check("an aborted gate is recorded, not missing", rec["status"] == "crash", rec)
        check("the abort detail names the runner as the killer",
              "abort" in (rec.get("detail") or "").lower(), rec.get("detail"))
        check("the abort path sweeps the run namespace", "aborttest" in swept, swept)
        check("no children left registered after abort",
              ctx_children_empty(ctx), [p.pid for p in ctx.children])
    finally:
        catalog.BY_NAME.pop("aborttest", None)
        catalog.GATES.remove(gate)


def test_lock_queue_time_is_not_gate_time():
    """The body budget starts when the locks are in hand.

    Counting the queue inside gate.timeout means a gate that waited 20 minutes
    for a neighbour is judged against a budget written for its own work, and the
    recorded duration blames the body for a scheduling wait.
    """
    ld = tempfile.mkdtemp(prefix="lr-lockqueue.")
    holder = locks.RWLock("obs", lock_dir=ld)
    holder.acquire_exclusive()
    box = {}

    def go():
        box.update(run_gates(["conf"], {"conf": ("pass", 0.0)}, jobs=1, lock_dir=ld))

    th = threading.Thread(target=go, daemon=True)
    th.start()
    time.sleep(2.0)
    holder.release()
    th.join(60)
    rec = box["records"]["conf"]
    check("the gate was green after waiting for the lock", rec["status"] == "pass", rec)
    check("the recorded duration excludes the lock queue",
          rec["duration"] < 1.0, rec["duration"])
    check("the run wall clock did pay for the queue", box["wall"] >= 2.0, box["wall"])


def ctx_children_empty(ctx):
    with context._CHILD_LOCK:
        return not ctx.children


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def test_build_manifest_syncs_the_run_context():
    """After the build gate, ctx, body env, disk, and records share the id.

    The scheduler swaps its manifest through on_build; the ctx owns gate_env
    and the on-disk run manifest, so the swap must propagate via
    ctx.update_manifest. A gate launched AFTER the build must be handed the
    built image id in LR_IMAGE -- not the cold derived tag -- and
    LR_GATE_MANIFEST must name a file that says the same, so the evidence a
    body can read cannot disagree with the record the run writes. The fake
    body snapshots its own env, so these are the values the bodies ACTUALLY
    ran with, not a paraphrase of them.
    """
    ns = tempfile.mkdtemp(prefix="lr-build-sync.")
    root = tempfile.mkdtemp(prefix="lr-runner-test.")
    manifest = stub_manifest()
    ctx = context.RunContext(manifest, log_dir=root)
    os.environ["LR_GATE_FAKE"] = FAKE
    os.environ["LR_FAKE_ACTIONS"] = json.dumps({"build": ("pass", 0.0),
                                                "conf": ("pass", 0.0)})
    os.environ["LR_GATE_LOCK_DIR"] = os.path.join(root, "locks")
    os.environ["LR_FAKE_NS_DIR"] = ns
    built = dict(manifest, image_id="sha256:bbbb")
    sched = scheduler.Scheduler(ctx, manifest,
                                [catalog.BY_NAME["build"], catalog.BY_NAME["conf"]],
                                jobs=1, on_build=lambda m: built,
                                print=lambda m: None)
    sched.run()
    check("the scheduler adopted the manifest the build filled",
          sched.manifest.get("image_id") == "sha256:bbbb",
          sched.manifest.get("image_id"))
    check("the ctx adopted the manifest the build filled",
          ctx.manifest.get("image_id") == "sha256:bbbb",
          ctx.manifest.get("image_id"))
    seen = {}
    for fn in os.listdir(ns):
        if fn.endswith(".env.json"):
            with open(os.path.join(ns, fn)) as fh:
                seen[fn.replace(".env.json", "")] = json.load(fh)
    check("the build body saw the derived tag (it produces this run image)",
          seen.get("build", {}).get("LR_IMAGE") == manifest["image_tag"],
          seen.get("build"))
    check("the post-build body saw the built image id",
          seen.get("conf", {}).get("LR_IMAGE") == "sha256:bbbb",
          seen.get("conf"))
    with open(ctx.manifest_path) as fh:
        disk = json.load(fh)
    check("the on-disk run manifest is updated in step",
          disk.get("image_id") == "sha256:bbbb", ctx.manifest_path)
    recs = dict((r["gate"], r) for r in results.load(ctx.result_dir, built))
    check("both gates green, records bound to the built image",
          recs["build"]["status"] == "pass" and recs["conf"]["status"] == "pass"
          and recs["conf"]["image_id"] == "sha256:bbbb",
          {k: (v["status"], v["image_id"]) for k, v in recs.items()})


def test_cli_run_id_normalisation():
    """--run-id's empty CLI default must reach RunContext as None (generate).

    build_parser defaults --run-id to "" when LR_RUN_ID is unset, and the
    identity layer reads an explicit "" as a claim on the empty run name and
    refuses it (runs/"" is a dotdir-shaped tree every listing tool hides). The
    runner must normalise at ITS boundary. A non-empty malformed claim ("   ",
    "bad id") passes through unchanged: the hard-error rule belongs to the
    identity layer, not to the CLI.
    """
    manifest = stub_manifest()
    calls = []

    class Sentinel(Exception):
        pass

    def fake_load(path, verify=True):
        return manifest

    def fake_ctx(m, run_id=None, log_dir=None, keep_tmp=False, groups=None):
        calls.append(run_id)
        raise Sentinel()

    def cli_args(run_id):
        return runner.build_parser().parse_args(
            ["run", "--tier", "quick", "--gate-only", "conf",
             "--manifest", "/nonexistent/manifest.json", "--run-id", run_id])

    real_load = context.load_manifest
    real_ctx = context.RunContext
    context.load_manifest = fake_load
    context.RunContext = fake_ctx
    try:
        for raw, want in (("", None), ("   ", "   "), ("my-run", "my-run"),
                          ("bad id", "bad id")):
            del calls[:]
            reached = False
            try:
                runner.cmd_run(cli_args(raw))
            except Sentinel:
                reached = True
            check("cli run-id %r arrives at RunContext as %r" % (raw, want),
                  reached and calls == [want], calls)
    finally:
        context.load_manifest = real_load
        context.RunContext = real_ctx
    # The tail of the chain: None generates a fresh safe id, so the empty CLI
    # default lands on a real run tree instead of dying on the empty claim.
    gen = context.RunContext(manifest,
                             log_dir=tempfile.mkdtemp(prefix="lr-runner-test."))
    check("the normalised empty default generates a safe run id",
          context.RUN_ID_RE.match(gen.run_id) is not None, gen.run_id)
    check("a real empty claim is still refused by the identity layer",
          _raises(lambda: context.RunContext(manifest, run_id="",
                                             log_dir=tempfile.mkdtemp())),
          "RunContext accepted run_id=''")


def _raises(fn):
    try:
        fn()
        return False
    except RuntimeError:
        return True


def main():
    for fn in (test_selection, test_ui_group_is_real, test_no_phase_barrier,
               test_red_build_blocks_dependents, test_failure_not_swallowed,
               test_child_crash_never_hangs, test_missing_record_is_a_crash,
               test_partial_run_cannot_claim_full_green, test_mixed_versions_refused,
               test_namespace_isolation, test_source_fingerprint, test_locks,
               test_watcher_pools_without_a_lock, test_timeout_sweeps_the_gate_namespace,
               test_abort_sweeps_and_records, test_lock_queue_time_is_not_gate_time,
               test_cold_selection_closes_the_build_edge,
               test_build_manifest_syncs_the_run_context,
               test_cli_run_id_normalisation):
        fn()
    failed = [c for c in CHECKS if not c[0]]
    print("\n=== %d checks, %d failed ===" % (len(CHECKS), len(failed)))
    for _, name, detail in failed:
        print("FAILED: %s | %s" % (name, detail))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    if len(sys.argv) == 2:                       # fake gate body mode
        sys.exit(fake_body(sys.argv[1]))
    main()
