#!/usr/bin/env python3
"""Per-gate result records and same-version aggregation.

Statuses (the point of this module is that a missing record is a status, not an
absence):
  pass / fail / timeout   the body ran and reported
  crash                   the body process exited without writing its result
                          file, or died on a signal
  skip                    SKIP_ENV named this gate (recorded, never silent)
  invalid                 a record exists but is unusable: unreadable json, a
                          gate that is not in the catalog, a foreign fingerprint,
                          a record that names no version, a status/rc pair a body
                          cannot honestly produce, a subset run sold as a whole
                          gate

Coverage (schema 3: the axis this module grew):
  A record used to say only "unit pass". That is a lie for a UI-only group run,
  whose unit body executes the node UI badge test and nothing else: the record
  was indistinguishable from a whole-tree unit pass, so aggregating that run
  with the other 21 gates of the same snapshot produced a false full green whose
  unit stood for one node test. Every record now carries the scope the body
  ACTUALLY covered:
    coverage: "full" | "subset"
    scope:    "<gate>:<descriptor>"   e.g. unit:full, unit:ui-node
  The descriptor is derived from the run context (RunContext.ui_only) or from a
  scheduler that states the scope it scheduled -- never from a caller that wants
  a wider claim, and never guessed. A record with no coverage descriptor is
  INVALID for release: a legacy schema-2 result is not promoted to a full gate
  by default, because "the body ran" is not the same statement as "the body ran
  everything".

Aggregation rules, in the order they are checked:
  1. every record must name its version (source fingerprint, image tag, base
     image id) and agree with the run being aggregated on every identity field
     the run knows, including the built image id; an image-dependent gate that
     reports no image id certifies no artifact and is refused;
  2. every gate of the requested selection must have a record -- a missing one
     counts as crash, so an interrupted run cannot read as a partial success;
  3. any skip / invalid / crash / fail blocks release, and a SUBSET-scope record
     blocks release for its gate: a UI-only unit pass stays green for the ui
     selection (selection_green) and is never release-quality unit coverage;
  4. duplicate records for one gate -- the shape an overlapping group selection
     produces, since unit is in both base and ui -- are merged only when the
     strongest record is a PASS and no record for that gate is a
     fail/skip/crash/timeout/invalid. A later pass never overwrites a failure.
     Provenance of every merged copy is kept in the record;
  5. only all 22 gates at full scope, all green, on a manifest whose build
     metadata is complete, is eligible as a full green anchor. A targeted run
     (group / GATE_ONLY / quick tier) may be green and is reported as such, and
     is explicitly marked as NOT a full anchor.
"""

import json
import os
import tempfile
import time

from . import catalog

PASS, FAIL, TIMEOUT, CRASH, SKIP, INVALID = (
    "pass", "fail", "timeout", "crash", "skip", "invalid")
STATUSES = (PASS, FAIL, TIMEOUT, CRASH, SKIP, INVALID)
BLOCKING = (FAIL, TIMEOUT, CRASH, SKIP, INVALID)
# HARD is what no run may survive, targeted ones included. SKIP sits only in
# BLOCKING: an explicit skip blocks a release anchor, and a group subset is
# allowed to produce skips legitimately (its bodies report rc=5).
HARD = (FAIL, TIMEOUT, CRASH, INVALID)
SCHEMA = 3
COVERAGE_FULL, COVERAGE_SUBSET = "full", "subset"
# The fields a record must NAME to certify a version at all. A record without
# them is not "a pass of unknown provenance"; it is a record that certifies
# nothing, and the aggregate says so out loud.
IDENTITY_FIELDS = ("fingerprint", "image_tag", "authz_id",
                   "build_base_id", "cache_key")
# Only the three fields a pre-build-gate manifest always names are REQUIRED to
# be present. build_base_id and cache_key are compared strictly when the run's
# manifest knows them (a context that pins the build base), and a record that
# omits them while the manifest carries them fails the VERSION_FIELDS match
# below -- so two runs of one tree on two bases can never merge, without
# invalidating every record written before the context layer grew those keys.
IDENTITY_REQUIRED = ("fingerprint", "image_tag", "authz_id")
# Fields whose value must equal the run manifest's, whenever the manifest knows
# it. authz_id is the immutable base id: two runs of one source tree on two
# different bases are two environments, not one version.
VERSION_FIELDS = ("fingerprint", "image_tag", "authz_ref", "authz_id",
                  "resty_ref", "resty_id", "build_base_id", "cache_key")
# (status, rc) pairs a body can honestly produce. Anything else is a broken
# writer, and a broken writer is not evidence of green.
_SIGNALS = tuple(range(-64, 0))
_ALLOWED_RC = {
    PASS: (0,),
    FAIL: tuple(range(1, 128)) + _SIGNALS,
    TIMEOUT: (None, 124) + tuple(range(1, 128)),
    CRASH: (None, 0) + tuple(range(1, 128)) + _SIGNALS,
    SKIP: (None, 5),
    INVALID: (None,),
}
# The subset scopes that exist, per gate. This is the single place that knows
# them, so a body cannot talk its way into a wider claim by naming a scope.
SUBSET_SCOPES = {
    "unit": {"ui-node": "UI-only run: the node UI badge test only"},
}


def _fsync_dir(path):
    """Persist the rename itself; a missing record already aggregates as a
    crash, so this is durability, not correctness."""
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


# --------------------------------------------------------------------- coverage
def coverage_for(gate, ctx=None, manifest=None):
    """Return (coverage, scope) for a gate body as it was scheduled.

    Deliberately derived, not requested: a caller that asks to "record this
    subset run as full" is the exact lie this field exists to stop. The inputs
    are the gate, the run context (RunContext.ui_only, set when the selection is
    the ui group alone) and the manifest flag a scheduler may carry.
    """
    name = gate.name if hasattr(gate, "name") else str(gate)
    ui_only = (bool(getattr(ctx, "ui_only", False))
               or bool(getattr(ctx, "groups", None)
                       and set(ctx.groups) == {"ui"})
               or bool((manifest or {}).get("unit_ui_only")))
    if name == "unit" and ui_only:
        return COVERAGE_SUBSET, "unit:ui-node"
    return COVERAGE_FULL, "%s:full" % name


def _invalid(rec, reason):
    rec = dict(rec)
    rec["status"] = INVALID
    rec["detail"] = ((rec.get("detail") or "") + (" | " if rec.get("detail") else "")
                     + reason)[:400]
    return rec


def _validate(rec):
    """Rewrite a record that cannot be trusted into status=invalid + reason.

    A record already invalid (unreadable file, missing keys, unknown gate) keeps
    the diagnosis it arrived with: the first reason is the useful one.
    """
    if rec.get("status") == INVALID:
        return rec
    problems = []
    missing = [k for k in ("gate", "status", "coverage", "scope")
               if rec.get(k) in (None, "")]
    if missing:
        problems.append("record lacks %s" % ", ".join(missing))
    status = rec.get("status")
    if status not in STATUSES:
        problems.append("unknown status %r" % (status,))
    try:
        schema = int(rec.get("schema") or 0)
    except (TypeError, ValueError):
        schema = 0
    if not problems and schema < SCHEMA:
        # A pre-coverage record says "gate pass" and nothing about what the body
        # covered. That is not promotable: refusing it is the whole point.
        problems.append("legacy schema %s record: no coverage descriptor" % schema)
    cov, scope = rec.get("coverage"), rec.get("scope")
    if cov not in (COVERAGE_FULL, COVERAGE_SUBSET):
        if cov is not None and cov != "":
            problems.append("unknown coverage %r" % (cov,))
    elif scope:
        gname, _, desc = str(scope).partition(":")
        if cov == COVERAGE_FULL and scope != "%s:full" % gname:
            problems.append("full-scope record carrying a subset descriptor: %s"
                            % (scope,))
        elif cov == COVERAGE_SUBSET:
            if gname != rec.get("gate"):
                problems.append("scope %s names a different gate" % (scope,))
            elif desc not in SUBSET_SCOPES.get(gname, {}):
                problems.append("unknown subset scope %r for gate %s" % (desc, gname))
    checks = rec.get("checks")
    if checks is not None and (isinstance(checks, bool)
                               or not isinstance(checks, int) or checks < 0):
        problems.append("checks must be a non-negative integer, got %r" % (checks,))
    rc = rec.get("rc")
    allowed = _ALLOWED_RC.get(status)
    if allowed is not None and rc not in allowed:
        problems.append("status %s with rc=%r is not a recordable result"
                        % (status, rc))
    if problems:
        return _invalid(rec, "; ".join(problems))
    return rec


# ----------------------------------------------------------------------- io
def path_for(result_dir, gate):
    return os.path.join(result_dir, gate + ".json")


def write(result_dir, record):
    """Atomically publish one gate record (write to tmp, fsync, rename)."""
    os.makedirs(result_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=record["gate"] + ".", suffix=".json.part",
                               dir=result_dir, text=True)
    with os.fdopen(fd, "w") as fh:
        json.dump(record, fh, sort_keys=True)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path_for(result_dir, record["gate"]))
    _fsync_dir(result_dir)
    return path_for(result_dir, record["gate"])


def read(path):
    try:
        with open(path) as fh:
            rec = json.load(fh)
    except (OSError, ValueError) as exc:
        return {"gate": os.path.basename(path).rsplit(".", 1)[0], "status": INVALID,
                "detail": "unreadable result file: %s" % (exc,)}
    if not isinstance(rec, dict) or "gate" not in rec or "status" not in rec:
        return {"gate": os.path.basename(path).rsplit(".", 1)[0], "status": INVALID,
                "detail": "result file lacks gate/status"}
    return rec


def make_record(gate, ctx, manifest, status, rc, duration, log_path, detail="",
                pid=None, container_ns=None, swept_containers=0,
                coverage=None, scope=None, checks=None):
    """Build the record for one gate as the runner observed it.

    coverage/scope are optional: a scheduler that KNOWS what it scheduled (a
    narrowed selection) states it here; a caller that leaves them out gets the
    scope derived from the run context. Both paths end in the same table, so
    there is no way to ask for a wider claim than the run earned.
    """
    d_cov, d_scope = coverage_for(gate, ctx, manifest)
    # Narrowing is allowed (a scheduler knows it scheduled a subset); widening is
    # not. If the run context says the body was narrowed, no caller argument can
    # buy back the wider claim.
    if d_cov == COVERAGE_SUBSET:
        coverage, scope = d_cov, d_scope
    elif coverage not in (COVERAGE_FULL, COVERAGE_SUBSET):
        coverage = d_cov
    if not scope:
        scope = d_scope
    rec = {
        "schema": SCHEMA,
        "gate": gate.name,
        "group": gate.group,
        "status": status,
        "rc": rc,
        "duration": round(duration, 2),
        "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "run_id": ctx.run_id if ctx else None,
        "pid": pid,
        "log": log_path,
        "detail": (detail or "")[:2000],
        "fingerprint": manifest.get("fingerprint"),
        "image_id": manifest.get("image_id"),
        "image_tag": manifest.get("image_tag"),
        "authz_ref": manifest.get("authz_ref"),
        "authz_id": manifest.get("authz_id"),
        "build_base_id": manifest.get("build_base_id"),
        "cache_key": manifest.get("cache_key"),
        "resty_ref": manifest.get("resty_ref"),
        "resty_id": manifest.get("resty_id"),
        "locks": list(gate.locks),
        "timeout": gate.timeout,
        # What the body ACTUALLY covered. The UI-only unit body runs one node
        # test and is recorded as a subset, so no later aggregate can let it
        # stand in for a whole unit gate.
        "coverage": coverage,
        "scope": scope,
        # The exact namespace this gate's containers carry (run namespace +
        # gate label). The stored string is the sanitised value the runner
        # INJECTED into the body, not a re-hash: the suites write the label from
        # that literal, so report and label stay in the same spelling. Only the
        # gate-level token is hashed, inside container_ns.
        "container_ns": container_ns,
        "swept_containers": swept_containers,
    }
    if checks is not None:
        rec["checks"] = checks
    return rec


# ------------------------------------------------------------------- version
def _version_check(rec, manifest):
    """Apply the same-version rules to one record (INVALID on any disagreement)."""
    gate = rec.get("gate")
    gdef = catalog.BY_NAME.get(gate)
    if gdef is None:
        return _invalid(rec, "unknown gate %r in results" % (gate,))
    if rec.get("status") == SKIP:
        return rec
    missing = [f for f in IDENTITY_REQUIRED if not rec.get(f)]
    if missing:
        return _invalid(rec, "record carries no %s: it certifies no version"
                        % ", ".join(missing))
    for field in VERSION_FIELDS:
        want = manifest.get(field)
        if want and rec.get(field) != want:
            return _invalid(rec, "mixed version: %s is %s, run is %s"
                            % (field, rec.get(field), want))
    # Gates that boot the built image must name the artifact they booted. The
    # build gate fills image_id into the manifest, so a null here means the body
    # ran before/without the build landing -- which is not a check of this build.
    if gdef.needs_image and not rec.get("image_id"):
        return _invalid(rec, "image-dependent gate %s recorded no image_id: it"
                           " cannot certify the built artifact" % (gate,))
    if rec.get("image_id") and manifest.get("image_id") \
            and rec["image_id"] != manifest["image_id"]:
        return _invalid(rec, "mixed version: image_id is %s, run is %s"
                        % (rec["image_id"], manifest["image_id"]))
    return rec


def load(result_dir, manifest):
    """Every record in a run dir, validated and version-checked at read."""
    out = []
    for name in sorted(os.listdir(result_dir)):
        if not name.endswith(".json"):
            continue
        rec = _validate(read(os.path.join(result_dir, name)))
        if manifest:
            rec = _version_check(rec, manifest)
        out.append(rec)
    return out


# -------------------------------------------------------------- duplicates
def _identity(rec):
    return tuple(rec.get(f) for f in ("fingerprint", "image_tag", "authz_id", "build_base_id",
                                      "cache_key", "resty_id", "image_id"))


def merge_duplicates(gate, recs):
    """Collapse the duplicate records of one gate, or refuse the duplicate.

    recs is [(source, record), ...] in directory order. Safe dedup: every copy
    is a PASS, they certify one version, and at least one is full scope -- a
    subset pass is evidence the gate is alive, not a rival claim, and a full pass
    subsumes it. Any non-pass in the set wins over any pass: the merged record is
    that failure, marked invalid, so an overlapping selection can never let a
    late pass erase a fail, a skip, a crash, or an invalid.
    """
    if len(recs) <= 1:
        return (recs[0][1] if recs else None), None
    srcs = ", ".join(str(s) for s, _ in recs)
    blocking = [(s, r) for s, r in recs if r.get("status") != PASS]
    if blocking:
        order = {INVALID: 0, CRASH: 1, TIMEOUT: 2, FAIL: 3, SKIP: 4}
        blocking.sort(key=lambda p: order.get(p[1].get("status"), 9))
        src, worst = blocking[0]
        merged = _invalid(worst, "duplicate records for %s include a %s (from %s):"
                          " a pass does not overwrite it"
                          % (gate, worst.get("status"), src))
        merged["duplicate_sources"] = srcs
        return merged, "conflict"
    full = [r for _, r in recs if r.get("coverage") == COVERAGE_FULL]
    subset = [r for _, r in recs if r.get("coverage") == COVERAGE_SUBSET]
    if not full and not subset:
        merged = _invalid(recs[0][1], "duplicate records for %s carry no coverage"
                          " descriptor" % (gate,))
        merged["duplicate_sources"] = srcs
        return merged, "conflict"
    base = full[0] if full else subset[0]
    others = (full[1:] + subset) if full else subset[1:]
    for r in others:
        for f in IDENTITY_FIELDS:
            if r.get(f) != base.get(f):
                merged = _invalid(base, "duplicate passes for %s certify different"
                                  " versions (%s: %s vs %s)"
                                  % (gate, f, r.get(f), base.get(f)))
                merged["duplicate_sources"] = srcs
                return merged, "conflict"
    merged = dict(base)
    merged["duplicate_sources"] = srcs
    if subset:
        merged["detail"] = ((merged.get("detail") or "") + " | also passed at subset"
                            " scope: %s" % ", ".join(sorted(set(r.get("scope")
                                                               for r in subset)))).strip()
    return merged, "deduped"


# --------------------------------------------------------------- aggregation
def aggregate(result_dir, manifest, tier="full", expected=None, extra_dirs=()):
    """Decide a run. Returns (ok, report).

    ok is the RELEASE decision for the selection: no blocking status, no
    duplicate conflict, and no subset-scope record. A selection that is
    legitimately partial stays green for itself -- report["selection_green"] --
    and a runner uses THAT for its exit code, so a group run keeps an honest rc
    while never being citable as release green.
    """
    dirs = [result_dir] + [d for d in extra_dirs if d]
    expected = list(expected if expected is not None else catalog.GATE_ORDER)
    for name in expected:
        if name not in catalog.BY_NAME:
            raise KeyError("unknown gate %r" % name)
    seen = {}
    for d in dirs:
        for rec in load(d, manifest):
            seen.setdefault(rec.get("gate"), []).append((d, rec))
    records = {}
    deduped, conflicts = [], []
    for gate, recs in seen.items():
        merged, kind = merge_duplicates(gate, recs)
        records[gate] = merged
        if kind == "deduped":
            deduped.append(gate)
        elif kind == "conflict":
            conflicts.append(gate)
    rows = []
    counts = {k: 0 for k in STATUSES}
    for name in expected:
        rec = records.get(name)
        if rec is None:
            rec = {"gate": name, "status": CRASH, "detail": "no result record",
                   "duration": None, "log": None, "rc": None, "schema": SCHEMA,
                   "group": catalog.BY_NAME[name].group, "fingerprint": None,
                   "coverage": COVERAGE_FULL, "scope": "%s:full" % name}
        counts[rec["status"]] = counts.get(rec["status"], 0) + 1
        rows.append(rec)
    # A record for a gate outside this selection is shown, never quietly
    # dropped: it means a scheduler wrote results the caller does not know
    # about, which is the shape of a mixed run.
    for name in sorted(set(records) - set(expected)):
        stray = _invalid(records[name], "record outside selection")
        counts[INVALID] += 1
        rows.append(stray)
    # A dedup of same-version full passes is not a problem: it is the shape an
    # overlapping group selection produces (unit is in base AND in ui), and the
    # task is to let those aggregate. Only a REFUSED duplicate blocks.
    counts["duplicate"] = len(deduped) + len(conflicts)
    counts["deduped"] = len(deduped)
    counts["duplicate_conflicts"] = len(conflicts)
    for gate in sorted(conflicts):
        rows.append({"gate": gate, "status": INVALID,
                     "detail": "duplicate records refused: a pass does not"
                               " overwrite a failure",
                     "duration": None, "log": None, "rc": None, "schema": SCHEMA,
                     "group": "-", "fingerprint": None, "coverage": COVERAGE_FULL,
                     "scope": "%s:full" % gate})
    counts["missing"] = sum(1 for r in rows if r["status"] == CRASH
                           and r.get("detail") == "no result record")
    subset = sorted(set(r.get("gate") for r in rows
                        if r.get("coverage") == COVERAGE_SUBSET))
    blocking = [k for k in BLOCKING if counts.get(k)]
    hard = [k for k in HARD if counts.get(k)]
    # A full anchor also needs the RUN to certify the artifact it ran on: a
    # manifest with no image id means the build metadata never landed, so the
    # report can list gates but cannot say what they booted.
    manifest_complete = bool(manifest and manifest.get("fingerprint")
                             and manifest.get("image_id")
                             and manifest.get("authz_id")
                             and manifest.get("image_tag"))
    complete = (tier == "full" and len(expected) == len(catalog.GATE_ORDER)
                and not counts["skip"] and not counts["invalid"]
                and not counts["missing"]
                and not counts["duplicate_conflicts"]
                and not subset and manifest_complete)
    # A partial selection (any group / GATE_ONLY / quick run) is expected to be
    # partial: its CLI exit code must keep saying "the gates I ran are green",
    # so a subset-scope record does not break rc there. It DOES keep release_green
    # false, which is the field a release decision reads.
    partial_selection = len(expected) < len(catalog.GATE_ORDER)
    release_ok = not blocking and not subset
    ok = release_ok if not partial_selection else not blocking
    selection_ok = not hard
    report = {
        "tier": tier,
        "expected": len(expected),
        "partial_selection": partial_selection,
        "counts": counts,
        "rows": rows,
        "release_green": release_ok,
        "selection_green": selection_ok,
        "full_anchor_eligible": bool(ok and complete),
        "manifest_complete": manifest_complete,
        "subset_gates": subset,
        "deduped_gates": sorted(deduped),
        "reason": ("ok" if ok else
                   ("blocked by: %s" % ", ".join("%s=%d" % (k, counts[k])
                                                 for k in blocking) if blocking else "")
                   + ("; subset scope: %s" % ", ".join(subset) if subset else "")),
    }
    return ok, report


def report_lines(report):
    lines = []
    for r in report["rows"]:
        dur = "-" if r.get("duration") is None else "%.0fs" % r["duration"]
        cov = "" if r.get("coverage") in (None, COVERAGE_FULL) else "  [%s]" % r.get("scope")
        lines.append("  %-24s %-14s %-8s %5s rc=%-4s %s%s" % (
            r["gate"], r.get("group", "-"), r["status"], dur,
            "-" if r.get("rc") is None else r["rc"],
            (r.get("detail") or "")[:70], cov))
    c = report["counts"]
    lines.append("  totals: %d pass, %d fail, %d timeout, %d crash, %d invalid,"
                 " %d skip, %d missing" % (
                     c.get(PASS, 0), c.get(FAIL, 0), c.get(TIMEOUT, 0),
                     c.get(CRASH, 0), c.get(INVALID, 0), c.get(SKIP, 0),
                     c.get("missing", 0)))
    lines.append("  release_green=%s  full_anchor_eligible=%s  (%s)" % (
        report["release_green"], report["full_anchor_eligible"], report["reason"]))
    lines.append("  selection_green=%s  (%d gate(s) in this selection, %d skipped"
                 " by group subset)" % (
                     report.get("selection_green"), report["expected"],
                     report["counts"].get(SKIP, 0)))
    if report.get("subset_gates"):
        lines.append("  subset scope (not release coverage): %s"
                     % ", ".join(report["subset_gates"]))
    if report.get("deduped_gates"):
        lines.append("  deduped (one version, all passes, provenance in the"
                     " record): %s" % ", ".join(report["deduped_gates"]))
    if not report.get("manifest_complete", True):
        lines.append("  manifest has no image/base id: this report cannot certify"
                     " the artifact the gates ran on.")
    if report["release_green"] and not report["full_anchor_eligible"]:
        lines.append("  NOTE: this run is green for its selection only; it is NOT a"
                     " full 22-gate anchor and must not be cited as one.")
    return lines
