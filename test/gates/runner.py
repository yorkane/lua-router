#!/usr/bin/env python3
"""Gate runner CLI. Invoked by test/final_gates.sh; also usable directly.

modes
  plan       print the selection/group/lock plan, execute nothing
  prepare    freeze the source snapshot, build the image once per fingerprint,
             print the prepared manifest (and write it with --manifest-out)
  run        schedule the selected gates (needs a manifest: --manifest, or a
             fresh prepare unless --prepared-only is implied by --manifest)
  aggregate  re-decide a finished run from its result dir (same-version rules)
  body       run one gate body (what --gate-body in final_gates.sh lands on)

Environment (compat with the historical script):
  GATE_TIER=quick|full (default quick)   GATE_JOBS=N (default: min(8, cpu);
                                         1 = explicit serial, in GATE_ORDER)
  GATE_ONLY=<gate>  GATE_GROUP=a,b  SKIP_ENV=a,b  KEEP_GOING=1  GATE_DRY_RUN=1
  LR_GATE_LOG=<file> merged log path   LR_GATE_LOG_DIR=<dir> state root
  LR_RUN_ID=<id> reuse a run id        LR_MANIFEST=<path> prepared manifest
"""

import argparse
import json
import os
import subprocess
import sys
import time

if __package__ in (None, ""):                       # allow plain-path invocation
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from gates import catalog, context, results, scheduler
else:
    from . import catalog, context, results, scheduler


def _truthy(val):
    return str(val or "").lower() in ("1", "true", "yes", "on")


def _split(val):
    return [p for p in str(val or "").replace(",", " ").split() if p]


def head_sha(repo):
    r = subprocess.run(["git", "-C", repo, "rev-parse", "--short", "HEAD"],
                       capture_output=True)
    return r.stdout.decode().strip() if r.returncode == 0 else "no-git"


def _write(fh, line):
    print(line)
    if fh:
        fh.write(line + "\n")
        fh.flush()


def include_cold_build_dependency(run_names, skip_names, manifest, explicit_skips=()):
    """Close a cold image-gate selection over the build dependency.

    Group/GATE_ONLY selections intentionally omit gates outside their scope.
    Correct for warm prepared manifests; on a cold manifest an image-dependent
    selection (GATE_GROUP=ui, GATE_ONLY=e2e_caps) reaches the scheduler with its
    declared build edge outside the selection and tries a derived image tag that
    was never built. Add only the prerequisite this selection needs: unit-only and
    warm selections stay build-free. An operator who asked for SKIP_ENV=build keeps
    that choice, visible as a recorded skip.
    """
    run_names, skip_names = list(run_names), list(skip_names)
    if manifest.get("image_id") or not any(
            catalog.BY_NAME[n].needs_image for n in run_names):
        return run_names, skip_names, None
    if "build" in run_names or "build" in skip_names:
        return run_names, skip_names, None
    if "build" in set(explicit_skips):
        skip_names.append("build")
        skip_names.sort(key=catalog.GATE_ORDER.index)
        return run_names, skip_names, "explicitly skipped"
    run_names.append("build")
    run_names.sort(key=catalog.GATE_ORDER.index)
    return run_names, skip_names, "cold image dependency"


def cmd_plan(args, out=None):
    skips = _split(args.skip or os.environ.get("SKIP_ENV"))
    groups = _split(args.group or os.environ.get("GATE_GROUP")) or None
    for line in catalog.plan_lines(args.tier, groups, args.gate_only, skips, args.jobs):
        _write(out, line)
    return 0


def cmd_prepare(args, out=None):
    manifest = context.prepare(repo=args.repo, tag=args.image, log=lambda m: _write(out, m))
    _write(out, json.dumps({k: manifest[k] for k in
                            ("fingerprint", "files", "snapshot", "image_tag", "image_id",
                             "authz_id", "resty_id", "prepared")}, indent=2))
    if args.manifest_out:
        with open(args.manifest_out, "w") as fh:
            json.dump(manifest, fh)
        _write(out, "manifest: %s" % args.manifest_out)
    return 0


def cmd_run(args, out=None):
    skips = _split(args.skip or os.environ.get("SKIP_ENV"))
    groups = _split(args.group or os.environ.get("GATE_GROUP")) or None
    tier = args.tier
    only = args.gate_only
    try:
        run_names, skip_names = catalog.selected(tier, groups, only, skips)
    except KeyError as exc:
        print("gate runner: %s" % (exc,), file=sys.stderr)
        return 2
    if not run_names and not skip_names:
        print("gate runner: selection is empty", file=sys.stderr)
        return 2
    manifest = None
    if args.manifest:
        manifest = context.load_manifest(args.manifest)
    if manifest is None:
        # Freeze only: the image is produced by the build GATE, so the gates that
        # need no image (conf/unit/contract/probes) never wait for a docker build.
        manifest = context.freeze(repo=args.repo, tag=args.image)
    run_names, skip_names, auto_build = include_cold_build_dependency(
        run_names, skip_names, manifest, explicit_skips=skips)
    # CLI normalisation at the RunContext boundary: --run-id defaults to ""
    # (the LR_RUN_ID lookup falls back to ""), and the identity layer reads an
    # explicit "" as a CLAIM on the empty run name -- a runs/"" tree that every
    # listing tool hides. The empty default must arrive as None ("no claim,
    # generate one"); a non-empty malformed claim (whitespace, bad chars,
    # over-length) is passed through unchanged so the hard-error rule survives
    # the CLI boundary intact.
    run_id = args.run_id if args.run_id else None
    ctx = context.RunContext(manifest, run_id=run_id, keep_tmp=_truthy(
        os.environ.get("LR_GATE_KEEP_TMP")), groups=groups)
    merged = os.environ.get("LR_GATE_LOG") or ctx.log_path
    stamps = ("lua-router gate runner  %s\n"
              "repo=%s head=%s\n"
              "tier=%s jobs=%s group=%s only=%s skip=%s\n"
              "run_id=%s fingerprint=%s image=%s authz=%s resty=%s\n"
              "auto_build=%s\n"
              "snapshot=%s\n" % (
                  time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  manifest["repo"], head_sha(manifest["repo"]), tier, args.jobs,
                  ",".join(groups) if groups else "all", only or "-",
                  ",".join(skip_names) or "none", ctx.run_id,
                  manifest["fingerprint"][:12],
                  (manifest["image_id"] or "pending-build")[:19],
                  (manifest["authz_id"] or "-")[:19], (manifest["resty_id"] or "-")[:19],
                  auto_build or "no",
                  manifest["snapshot"]))
    with open(merged, "a") as fh:
        fh.write(stamps)
    # Skipped gates are part of the scheduled list: the scheduler records a skip
    # row for each and the report's expected set includes them, so a skipped gate
    # is visible in the summary instead of vanishing from it -- a green run must
    # never read as a shrunk one.
    selected = [catalog.BY_NAME[n] for n in run_names + skip_names]
    sched = scheduler.Scheduler(ctx, manifest, selected, skips=skip_names,
                                jobs=args.jobs, print=lambda m: _write(out, m),
                                on_build=context.manifest_with_built_image)
    with open(merged, "a") as fh:
        for g in selected:
            fh.write("\n===== gate: %s  queued =====\n" % g.name)
    interrupted = None
    try:
        sched.run()
    except (KeyboardInterrupt, SystemExit) as exc:      # Ctrl-C / SIGTERM handler
        interrupted = exc
        sched.abort("interrupted")
    # Aggregate against the manifest the run ENDED on: the build GATE fills in
    # the image id, and every record must agree with it.
    manifest = sched.manifest
    ok, report = results.aggregate(ctx.result_dir, manifest, tier=tier,
                                   expected=run_names + skip_names)
    lines = ["", "----------------------------------------"] + results.report_lines(report)
    lines.append("run=%s  results=%s  logs=%s" % (ctx.run_id, ctx.result_dir, ctx.log_dir))
    for line in lines:
        _write(out, line)
    with open(merged, "a") as fh:
        for g in selected:
            path = os.path.join(ctx.log_dir, g.name + ".log")
            if os.path.exists(path):
                fh.write("\n===== gate: %s  body log =====\n" % g.name)
                with open(path, errors="replace") as src:
                    fh.write(src.read())
        fh.write("\n" + "\n".join(lines) + "\n")
    # manifest.json: reuse this run identity for a later --manifest run, and
    # for --aggregate across the result dirs of independent group runs.
    with open(os.path.join(ctx.root, "manifest.json"), "w") as fh:
        json.dump(sched.manifest, fh)
    with open(os.path.join(ctx.root, "report.json"), "w") as fh:
        json.dump({"report": report, "manifest": manifest, "run_id": ctx.run_id,
                   "selection": run_names, "skips": skip_names, "tier": tier,
                   "jobs": args.jobs, "merged_log": merged}, fh, indent=2,
                  default=str)
    if not args.keep_tmp:
        context_cleanup(ctx)
    if interrupted is not None:
        print("gate runner: interrupted (%s); results are partial by construction"
              % (interrupted,), file=sys.stderr)
        return 130
    return 0 if ok else 1


def context_cleanup(ctx):
    """Remove the run tmp tree (moved to /data/.trash, never hard-deleted)."""
    if ctx.keep_tmp:
        return
    trash = "/data/.trash"
    try:
        if os.path.isdir(ctx.tmp) and os.path.isdir(trash):
            os.rename(ctx.tmp, os.path.join(trash, "lr-run-tmp-" + ctx.run_id))
    except OSError:
        pass


def cmd_aggregate(args, out=None):
    manifest = context.load_manifest(args.manifest)
    dirs = _split(args.results)
    if not dirs:
        print("aggregate: --results needs at least one result dir", file=sys.stderr)
        return 2
    # Multiple dirs = the same-version aggregate the user asked for: independent
    # group runs against one frozen fingerprint and one image, reported as one
    # release decision. results.aggregate refuses any record that disagrees.
    ok, report = results.aggregate(dirs[0], manifest, tier=args.tier,
                                   expected=_split(args.gates) or None,
                                   extra_dirs=dirs[1:])
    for line in results.report_lines(report):
        _write(out, line)
    return 0 if ok else 1


def build_parser():
    p = argparse.ArgumentParser(prog="gates.runner")
    p.add_argument("mode", choices=("plan", "prepare", "run", "aggregate"))
    p.add_argument("--tier", default=os.environ.get("GATE_TIER", "quick"))
    p.add_argument("--group", default="")
    p.add_argument("--gate-only", default=os.environ.get("GATE_ONLY", ""))
    p.add_argument("--skip", default="")
    p.add_argument("--jobs", type=int, default=int(os.environ.get("GATE_JOBS", "0") or 0)
                   or scheduler.default_jobs())
    p.add_argument("--repo", default=context.REPO)
    p.add_argument("--image", default=os.environ.get("LR_IMAGE", "lua-router:integration"))
    p.add_argument("--manifest", default=os.environ.get("LR_MANIFEST", ""))
    p.add_argument("--manifest-out", default="")
    p.add_argument("--results", default="")
    p.add_argument("--gates", default="")
    p.add_argument("--run-id", default=os.environ.get("LR_RUN_ID", ""))
    p.add_argument("--keep-tmp", action="store_true")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.tier not in ("quick", "full"):
        print("GATE_TIER must be quick or full (got %s)" % args.tier, file=sys.stderr)
        return 2
    if args.jobs < 1:
        print("GATE_JOBS must be >= 1", file=sys.stderr)
        return 2
    if args.mode == "plan":
        return cmd_plan(args)
    if args.mode == "prepare":
        return cmd_prepare(args)
    if args.mode == "aggregate":
        if not args.manifest or not args.results:
            print("aggregate needs --manifest and --results", file=sys.stderr)
            return 2
        return cmd_aggregate(args)
    if os.environ.get("GATE_DRY_RUN") and _truthy(os.environ.get("GATE_DRY_RUN")):
        return cmd_plan(args)
    return cmd_run(args)


if __name__ == "__main__":
    sys.exit(main())
