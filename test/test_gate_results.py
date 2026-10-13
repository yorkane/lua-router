#!/usr/bin/env python3
"""Pure tests for the coverage/scope layer of gate result records.

Everything here is file-only: no docker, no ports, no HTTP, no containers. The
module under test is test/gates/results.py (schema 3). These tests are
independent of test/test_gate_runner.py -- that file exercises the scheduler
with the fake backend; this one pins the record contract the aggregate decides
on:

  1. a UI-only unit pass is recorded as a SUBSET (unit:ui-node) and blocks
     release, while staying green for its own selection;
  2. a full-scope unit pass on the same version subsumes the subset record
     (overlapping group selections aggregate cleanly);
  3. mixed versions (fingerprint, base id, build base / cache key) are refused;
  4. duplicate passes dedup with provenance; a fail never loses to a pass;
  5. an image-dependent gate that records no image id certifies nothing;
  6. legacy schema-2 records, unknown statuses, impossible status/rc pairs and
     forged coverage descriptors are all INVALID.

Run: python3 test/test_gate_results.py
"""

import copy
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gates import catalog, context, results   # noqa: E402

CHECKS = []


def check(name, cond, detail=""):
    CHECKS.append((bool(cond), name, "" if cond else str(detail)[:400]))
    print(("PASS  " if cond else "FAIL  ") + name
          + ("" if cond else "   | " + str(detail)[:300]))
    return bool(cond)


def stub_manifest(**over):
    m = {"schema": 2, "fingerprint": "f" * 64, "files": 1,
         "snapshot": os.path.dirname(HERE), "repo": os.path.dirname(HERE),
         "image_tag": "lua-router:gate-test", "image_id": "sha256:aaaa",
         "authz_ref": "authz:latest", "authz_id": "sha256:bbbb",
         "resty_ref": "apache/apisix:3.11.0-debian", "resty_id": "sha256:cccc",
         "build_base_id": "sha256:bbbb", "cache_key": "k" * 64}
    m.update(over)
    return m


def ctx_for(manifest, groups=None, run_id=None):
    root = tempfile.mkdtemp(prefix="lr-results-test.")
    return context.RunContext(manifest, run_id=run_id, log_dir=root, groups=groups)


def rec(gate, manifest, status="pass", rc=0, ctx=None, **kw):
    return results.make_record(catalog.BY_NAME[gate], ctx, manifest, status, rc,
                               1.0, None, **kw)


def write_all(d, manifest, gates, **kw):
    for g in gates:
        results.write(d, rec(g, manifest, **kw))


ALL = list(catalog.GATE_ORDER)
NON_UNIT = [g for g in ALL if g != "unit"]


def row_of(report, gate):
    rows = [r for r in report["rows"] if r["gate"] == gate]
    return rows[0] if rows else None


# --------------------------------------------------------------------- tests
def test_record_shape():
    m = stub_manifest()
    r = rec("conf", m)
    check("record carries schema 3", r["schema"] == results.SCHEMA, r["schema"])
    check("record names its coverage", r["coverage"] == "full"
          and r["scope"] == "conf:full", (r["coverage"], r["scope"]))
    for f in results.IDENTITY_FIELDS:
        check("record carries %s" % f, r.get(f) == m.get(f), (r.get(f), m.get(f)))
    r2 = rec("unit", m, ctx=ctx_for(m, groups=["ui"]))
    check("a UI-only run records unit as a subset",
          r2["coverage"] == "subset" and r2["scope"] == "unit:ui-node",
          (r2["coverage"], r2["scope"]))
    r3 = rec("unit", m, ctx=ctx_for(m), coverage="full", scope="unit:full")
    check("an explicit full scope on a whole run stays full",
          r3["coverage"] == "full" and r3["scope"] == "unit:full")
    r4 = rec("unit", m, ctx=ctx_for(m, groups=["ui"]),
             coverage="full", scope="unit:full")
    check("a caller cannot widen a subset run back to full",
          r4["coverage"] == "subset" and r4["scope"] == "unit:ui-node",
          (r4["coverage"], r4["scope"]))
    r5 = rec("conf", m, checks=125)
    check("a body may report its check count", r5["checks"] == 125, r5)


def test_ui_subset_blocks_release():
    m = stub_manifest()
    ui = ctx_for(m, groups=["ui"])
    d = tempfile.mkdtemp(prefix="lr-results-test.")
    write_all(d, m, NON_UNIT)
    results.write(d, rec("unit", m, ctx=ui))
    ok, rep = results.aggregate(d, m, tier="full", expected=ALL)
    check("UI-only unit + 21 passes is NOT release green", ok is False, rep["reason"])
    check("the subset gate is named in the report",
          rep["subset_gates"] == ["unit"], rep["subset_gates"])
    check("the selection itself is green", rep["selection_green"] is True,
          rep["reason"])
    check("a subset run is never a full anchor",
          rep["full_anchor_eligible"] is False)
    check("the reason says subset, not a fake failure",
          "subset" in rep["reason"], rep["reason"])
    check("the subset row shows its scope",
          row_of(rep, "unit")["coverage"] == "subset", row_of(rep, "unit"))
    check("the report line marks the subset scope",
          any("unit:ui-node" in ln for ln in results.report_lines(rep)),
          results.report_lines(rep)[-4:])


def test_full_pass_subsumes_subset():
    m = stub_manifest()
    dirA = tempfile.mkdtemp(prefix="lr-results-test.")
    dirB = tempfile.mkdtemp(prefix="lr-results-test.")
    # dirA: a UI-only group run (subset unit + the ui-carrier suite)
    ui = ctx_for(m, groups=["ui"])
    results.write(dirA, rec("unit", m, ctx=ui))
    results.write(dirA, rec("e2e_ui_bridge", m))
    # dirB: the base run carries the whole unit gate and the rest
    write_all(dirB, m, ["unit"] + [g for g in ALL if g not in ("unit",
                                                               "e2e_ui_bridge")])
    results.write(dirB, rec("e2e_ui_bridge", m))
    ok, rep = results.aggregate(dirA, m, tier="full", expected=ALL, extra_dirs=[dirB])
    check("full unit + 21 others aggregates to release green", ok is True,
          rep["reason"])
    check("the merged unit record is the FULL pass",
          row_of(rep, "unit")["coverage"] == "full", row_of(rep, "unit"))
    check("the merge keeps provenance of both dirs",
          dirA in (row_of(rep, "unit").get("duplicate_sources") or "")
          and dirB in (row_of(rep, "unit").get("duplicate_sources") or ""),
          row_of(rep, "unit").get("duplicate_sources"))
    check("the subset pass is visible in the merged detail",
          "subset" in (row_of(rep, "unit").get("detail") or ""),
          row_of(rep, "unit").get("detail"))
    c = rep["counts"]
    check("both overlapping gates deduped, nothing conflicted",
          c["duplicate"] == 2 and c["deduped"] == 2
          and c["duplicate_conflicts"] == 0 and c["invalid"] == 0, c)
    check("a same-version 22-gate aggregate is anchor eligible",
          rep["full_anchor_eligible"] is True, rep["reason"])


def test_duplicate_pass_does_not_mask_failure():
    m = stub_manifest()
    dirA = tempfile.mkdtemp(prefix="lr-results-test.")
    dirB = tempfile.mkdtemp(prefix="lr-results-test.")
    results.write(dirA, rec("unit", m, status="fail", rc=1, detail="red suite"))
    results.write(dirB, rec("unit", m))
    ok, rep = results.aggregate(dirA, m, tier="quick", expected=["unit"],
                                extra_dirs=[dirB])
    row = row_of(rep, "unit")
    check("a late pass never overwrites a fail",
          ok is False and row["status"] == "invalid", row)
    check("the conflict keeps the fail's own detail",
          "red suite" in (row.get("detail") or ""), row.get("detail"))
    check("the conflict names both sources",
          dirA in (row.get("duplicate_sources") or "")
          and dirB in (row.get("duplicate_sources") or ""),
          row.get("duplicate_sources"))
    check("the conflict is not counted as a dedup",
          rep["counts"]["duplicate"] == 1 and rep["counts"]["deduped"] == 0,
          rep["counts"])
    # skip is also a non-pass: it must win over a pass the same way
    dirC = tempfile.mkdtemp(prefix="lr-results-test.")
    results.write(dirC, rec("unit", m, status="skip", rc=None, detail="SKIP_ENV"))
    ok2, rep2 = results.aggregate(dirB, m, tier="quick", expected=["unit"],
                                  extra_dirs=[dirC])
    check("a recorded skip is never erased by a pass",
          ok2 is False and row_of(rep2, "unit")["status"] == "invalid",
          row_of(rep2, "unit"))


def test_subset_failure_is_never_erased():
    """A red subset run and a green full run of the same gate: the failure is
    evidence about the gate, and the task is explicit that a partial failure
    cannot be抹 by a later whole pass."""
    m = stub_manifest()
    ui = ctx_for(m, groups=["ui"])
    dirA = tempfile.mkdtemp(prefix="lr-results-test.")
    dirB = tempfile.mkdtemp(prefix="lr-results-test.")
    results.write(dirA, rec("unit", m, ctx=ui, status="fail", rc=1,
                           detail="node badge red"))
    results.write(dirB, rec("unit", m))
    ok, rep = results.aggregate(dirA, m, tier="full", expected=ALL,
                                extra_dirs=[dirB])
    row = row_of(rep, "unit")
    check("a subset fail + full pass of one gate is a conflict",
          ok is False and row["status"] == "invalid", row)
    check("the conflict names the subset source",
          dirA in (row.get("duplicate_sources") or ""), row.get("duplicate_sources"))
    check("the conflict keeps the subset detail",
          "node badge red" in (row.get("detail") or ""), row.get("detail"))


def test_duplicates_of_different_versions_refused():
    m = stub_manifest()
    other = stub_manifest(fingerprint="b" * 64)
    dirA = tempfile.mkdtemp(prefix="lr-results-test.")
    dirB = tempfile.mkdtemp(prefix="lr-results-test.")
    write_all(dirA, m, NON_UNIT)
    results.write(dirA, rec("unit", m, ctx=ctx_for(m, groups=["ui"])))
    results.write(dirB, rec("unit", other))
    ok, rep = results.aggregate(dirA, m, tier="full", expected=ALL, extra_dirs=[dirB])
    check("a full pass of a foreign fingerprint is refused in the merge",
          ok is False and row_of(rep, "unit")["status"] == "invalid",
          row_of(rep, "unit"))


def test_mixed_versions_refused():
    m = stub_manifest(fingerprint="f" * 64)
    d = tempfile.mkdtemp(prefix="lr-results-test.")
    results.write(d, rec("conf", m))
    results.write(d, rec("unit", stub_manifest(fingerprint="b" * 64)))
    m2 = copy.deepcopy(m)
    m2["image_id"] = "sha256:deadbeef"
    results.write(d, rec("contract", m2))
    m3 = copy.deepcopy(m)
    m3["authz_id"] = "sha256:other-base"
    m3["build_base_id"] = "sha256:other-base"
    results.write(d, rec("probes", m3))
    ok, rep = results.aggregate(d, m, tier="quick",
                                expected=["conf", "unit", "contract", "probes"])
    rows = dict((r["gate"], r) for r in rep["rows"])
    check("a foreign fingerprint is refused", rows["unit"]["status"] == "invalid",
          rows["unit"])
    check("a foreign image id is refused",
          rows["contract"]["status"] == "invalid", rows["contract"])
    check("a foreign build base id is refused",
          rows["probes"]["status"] == "invalid", rows["probes"])
    check("the base-id refusal names the field",
          "build_base_id" in (rows["probes"].get("detail")
                              or rows["probes"].get("detail", ""))
          or "authz_id" in (rows["probes"].get("detail") or ""),
          rows["probes"].get("detail"))
    check("mixed results block the run", ok is False, rep["reason"])
    check("the same-version record stays valid", rows["conf"]["status"] == "pass")


def test_identity_required():
    m = stub_manifest()
    d = tempfile.mkdtemp(prefix="lr-results-test.")
    results.write(d, rec("conf", m))
    nofp = rec("unit", m)
    nofp["fingerprint"] = None
    results.write(d, nofp)
    ok, rep = results.aggregate(d, m, tier="quick", expected=["conf", "unit"])
    row = row_of(rep, "unit")
    check("a record naming no fingerprint certifies no version",
          ok is False and row["status"] == "invalid"
          and "certifies no version" in (row.get("detail") or ""), row)
    # e2e gate with no image id: it booted nothing verifiable
    d2 = tempfile.mkdtemp(prefix="lr-results-test.")
    noid = rec("e2e_caps", m)
    noid["image_id"] = None
    results.write(d2, noid)
    ok2, rep2 = results.aggregate(d2, m, tier="full", expected=["e2e_caps"])
    check("an image-dependent gate with a null image id is refused",
          ok2 is False and "image_id" in (row_of(rep2, "e2e_caps").get("detail") or ""),
          row_of(rep2, "e2e_caps"))
    # the same null is legitimate for conf (needs no image)
    d3 = tempfile.mkdtemp(prefix="lr-results-test.")
    c = rec("conf", m)
    c["image_id"] = None
    results.write(d3, c)
    ok3, rep3 = results.aggregate(d3, m, tier="quick", expected=["conf"])
    check("a non-image gate may predate the build landing",
          ok3 is True, rep3["reason"])
    # a manifest with no image id cannot anchor a full report: the records
    # carry the id the build produced, the aggregation manifest does not know it
    mp = stub_manifest(image_id=None)
    d4 = tempfile.mkdtemp(prefix="lr-results-test.")
    write_all(d4, m, ALL)
    ok4, rep4 = results.aggregate(d4, mp, tier="full", expected=ALL)
    check("an aggregate on an unbuilt manifest is not anchor-eligible",
          ok4 is True and rep4["full_anchor_eligible"] is False
          and rep4["manifest_complete"] is False,
          (rep4["full_anchor_eligible"], rep4["manifest_complete"]))


def test_legacy_and_broken_records_invalid():
    m = stub_manifest()
    d = tempfile.mkdtemp(prefix="lr-results-test.")
    legacy = rec("conf", m)
    legacy["schema"] = 2
    legacy.pop("coverage")
    legacy.pop("scope")
    results.write(d, legacy)
    ok, rep = results.aggregate(d, m, tier="quick", expected=["conf"])
    check("a legacy schema-2 record is INVALID, never promoted to full",
          ok is False and "coverage" in (row_of(rep, "conf").get("detail") or ""),
          row_of(rep, "conf"))
    # missing coverage on schema 3
    d2 = tempfile.mkdtemp(prefix="lr-results-test.")
    r = rec("conf", m)
    r.pop("coverage")
    results.write(d2, r)
    ok2, rep2 = results.aggregate(d2, m, tier="quick", expected=["conf"])
    check("a schema-3 record without coverage is invalid",
          ok2 is False and "coverage" in (row_of(rep2, "conf").get("detail") or ""),
          row_of(rep2, "conf"))
    # forged subset descriptor
    d3 = tempfile.mkdtemp(prefix="lr-results-test.")
    f = rec("conf", m)
    f["coverage"] = "subset"
    f["scope"] = "conf:ui-node"
    results.write(d3, f)
    ok3, rep3 = results.aggregate(d3, m, tier="quick", expected=["conf"])
    check("an unlisted subset scope is refused",
          ok3 is False and "unknown subset scope"
          in (row_of(rep3, "conf").get("detail") or ""), row_of(rep3, "conf"))
    # full coverage carrying a subset descriptor
    d4 = tempfile.mkdtemp(prefix="lr-results-test.")
    g = rec("unit", m)
    g["scope"] = "unit:ui-node"
    results.write(d4, g)
    ok4, rep4 = results.aggregate(d4, m, tier="quick", expected=["unit"])
    check("full coverage with a subset descriptor is refused",
          ok4 is False and "subset descriptor"
          in (row_of(rep4, "unit").get("detail") or ""), row_of(rep4, "unit"))
    # unknown status
    d5 = tempfile.mkdtemp(prefix="lr-results-test.")
    u = rec("conf", m)
    u["status"] = "green"
    u["rc"] = 0
    results.write(d5, u)
    ok5, rep5 = results.aggregate(d5, m, tier="quick", expected=["conf"])
    check("an unknown status is refused",
          ok5 is False and "unknown status"
          in (row_of(rep5, "conf").get("detail") or ""), row_of(rep5, "conf"))
    # status/rc contradiction: pass with rc=1
    d6 = tempfile.mkdtemp(prefix="lr-results-test.")
    p1 = rec("conf", m, status="pass", rc=1)
    results.write(d6, p1)
    ok6, rep6 = results.aggregate(d6, m, tier="quick", expected=["conf"])
    check("a pass with rc=1 is not a recordable result",
          ok6 is False and "not a recordable result"
          in (row_of(rep6, "conf").get("detail") or ""), row_of(rep6, "conf"))
    # unreadable file
    d7 = tempfile.mkdtemp(prefix="lr-results-test.")
    with open(os.path.join(d7, "conf.json"), "w") as fh:
        fh.write("{not json")
    ok7, rep7 = results.aggregate(d7, m, tier="quick", expected=["conf"])
    check("an unreadable record is invalid",
          ok7 is False and row_of(rep7, "conf")["status"] == "invalid")


def test_partial_selection_keeps_honest_rc():
    """A group run's exit code stays "the gates I ran are green"; release is the
    field that says more than that, and it says no."""
    m = stub_manifest()
    ui = ctx_for(m, groups=["ui"])
    d = tempfile.mkdtemp(prefix="lr-results-test.")
    results.write(d, rec("unit", m, ctx=ui))
    results.write(d, rec("e2e_ui_bridge", m))
    ok, rep = results.aggregate(d, m, tier="full", expected=["unit", "e2e_ui_bridge"])
    check("a UI group run exits green for its own selection", ok is True,
          rep["reason"])
    check("the same run is NOT release green", rep["release_green"] is False,
          rep["subset_gates"])
    check("the report marks the selection partial",
          rep["partial_selection"] is True)
    ok2, rep2 = results.aggregate(d, m, tier="full", expected=ALL)
    check("the same records as a full selection are blocked", ok2 is False,
          rep2["counts"])


def test_roundtrip_write_read():
    m = stub_manifest()
    d = tempfile.mkdtemp(prefix="lr-results-test.")
    ui = ctx_for(m, groups=["ui"])
    src = rec("unit", m, ctx=ui, checks=42)
    results.write(d, src)
    got = results.read(results.path_for(d, "unit"))
    check("the coverage fields survive the json round trip",
          got["coverage"] == "subset" and got["scope"] == "unit:ui-node"
          and got["checks"] == 42, got)
    recs = results.load(d, m)
    check("load keeps a subset pass live (it is a status, not corruption)",
          recs[0]["status"] == "pass", recs[0])


def main():
    for fn in (test_record_shape, test_ui_subset_blocks_release,
               test_full_pass_subsumes_subset,
               test_duplicate_pass_does_not_mask_failure,
               test_subset_failure_is_never_erased,
               test_duplicates_of_different_versions_refused,
               test_mixed_versions_refused, test_identity_required,
               test_legacy_and_broken_records_invalid,
               test_partial_selection_keeps_honest_rc, test_roundtrip_write_read):
        fn()
    failed = [c for c in CHECKS if not c[0]]
    print("\n=== %d checks, %d failed ===" % (len(CHECKS), len(failed)))
    for _, name, detail in failed:
        print("FAILED: %s | %s" % (name, detail))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
