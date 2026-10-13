#!/usr/bin/env python3
"""Pure tests for the run-identity layer: no docker daemon, no HTTP, no ports.

Every docker call is a fake, so these check the contract the gate runner leans
on and the real gates cannot demonstrate: a snapshot is a closed tree (no
operator secrets, no run products, no symlinks), a tree that moves under a
publish is rejected rather than published under a stale digest, prepare and
freeze resolve identity through ONE core, and the image cache is keyed by the
source fingerprint plus the base the build ACTUALLY ran on -- the base named by
the snapshot's own Dockerfile, not the test image in OPENRESTY_TEST_IMAGE -- so
an image built on an older base can never serve a run that reports a new one.

Run: python3 test/test_gate_context.py
"""

import hashlib
import json
import os
import shutil
import sys
import tempfile
import threading
import re

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gates import context   # noqa: E402

CHECKS = []
DOCKERFILE = "FROM authz:latest\nCOPY lualib/ /usr/local/openresty/site/lualib/\n"
AUTHZ_REF, AUTHZ_ID = "authz:latest", "sha256:aaa"
RESTY_REF, RESTY_ID = "apache/apisix:3.11.0-debian", "sha256:bbb"
# Explicit tag: the fixture asserts on the REQUESTED tag, and the production
# default reads LR_IMAGE -- which the gate runner legitimately sets in a
# worker environment (the derived tag lives in LR_IMAGE there, not the
# integration tag). Passing it keeps the assertions env-independent.
ENV_KW = {"authz": AUTHZ_REF, "resty": RESTY_REF,
          "tag": "lua-router:integration"}


def check(name, cond, detail=""):
    CHECKS.append((bool(cond), name, "" if cond else str(detail)[:400]))
    print(("PASS  " if cond else "FAIL  ") + name
          + ("" if cond else "   | " + str(detail)[:300]))
    return bool(cond)


def write(path, text):
    with open(path, "w") as fh:
        fh.write(text)


def make_repo(root, note="one"):
    """A tree shaped like the repo for the paths the gates read."""
    for d in ("lualib/resty", "conf", "test/integration", "ui"):
        os.makedirs(os.path.join(root, *d.split("/")), exist_ok=True)
    write(os.path.join(root, "lualib", "resty", "a.lua"), "-- " + note + "\n")
    write(os.path.join(root, "conf", "nginx.conf.template"), "worker_processes 1;\n")
    write(os.path.join(root, "test", "integration", "e2e_x.py"), "x = 1\n")
    write(os.path.join(root, "ui", "index.html"), "<html></html>\n")
    write(os.path.join(root, "Dockerfile"), DOCKERFILE)
    write(os.path.join(root, "docker-entrypoint.sh"), "#!/bin/sh\n")
    return root


def tree_of(root):
    names = []
    for dirpath, dirnames, filenames in os.walk(root):
        for fn in filenames:
            names.append(os.path.relpath(os.path.join(dirpath, fn), root))
    return sorted(names)


class FakeDocker:
    """Maps refs to ids and records what the identity layer asked docker to do."""

    def __init__(self, ids=None):
        self.ids = dict(ids or {})
        # Ids pinned here are reported as MISSING, which is how a test simulates
        # a pruned image: an immutable id is its own proof of existence.
        self.absent = set()
        self.builds = []
        self.tags = []
        self.built = []       # (tag, buildfile text) pairs the build consumed
        self.pin_ids = {}     # pin tag -> base id, sampled DURING the build
        self.calls = []
        self.buildfiles = []

    def image_id(self, ref):
        self.calls.append(("inspect", ref))
        if ref in self.absent:
            return None
        if ref in self.ids:
            return self.ids[ref]
        return ref if str(ref).startswith("sha256:") else None

    def run(self, argv, **kw):
        self.calls.append(tuple(argv[:3]))
        if argv[:2] == ["docker", "build"]:
            tag = argv[argv.index("-t") + 1]
            buildfile = argv[argv.index("-f") + 1]
            with open(buildfile) as fh:
                text = fh.read()
                self.built.append((tag, text))
                m = re.search(r"(?mi)^FROM\s+(\S+)", text)
                if m:
                    self.pin_ids[m.group(1)] = self.image_id(m.group(1))
            self.builds.append(tag)
            self.ids[tag] = "sha256:built%d" % (len(self.builds) + 1)
        elif argv[:2] == ["docker", "tag"]:
            self.tags.append((argv[2], argv[3]))
            self.ids[argv[3]] = self.image_id(argv[2])
        elif argv[:2] == ["docker", "rmi"]:
            self.ids.pop(argv[2], None)
        return _Completed(argv)

    def inspect(self, argv):
        iid = self.image_id(argv[-1])
        return _Completed(argv, stdout=(iid or "").encode(),
                          returncode=0 if iid else 1)


class _Completed:
    returncode = 0
    stderr = b""

    def __init__(self, argv, stdout=b"", returncode=0):
        self.stdout = stdout
        self.returncode = returncode


class _Subprocess:
    """Stands in for the subprocess module: run() plus the inspect probe."""

    def __init__(self, docker):
        self.docker = docker

    def run(self, argv, **kw):
        if argv[:3] == ["docker", "image", "inspect"]:
            return self.docker.inspect(argv)
        return self.docker.run(argv, **kw)


class Env:
    """A private snapshot root + fake docker for one test."""

    def __init__(self, ids=None):
        self.root = tempfile.mkdtemp(prefix="lr-ctx-test.")
        self.snap_root = os.path.join(self.root, "snapshots")
        os.makedirs(self.snap_root, exist_ok=True)
        self.repo = make_repo(os.path.join(self.root, "repo"))
        self.docker = FakeDocker(dict({"authz:latest": AUTHZ_ID,
                                      RESTY_REF: RESTY_ID}, **(ids or {})))
        self.lock_dir = os.path.join(self.root, "locks")
        os.makedirs(self.lock_dir, exist_ok=True)
        self.saved = {}

    def __enter__(self):
        self.saved = {"SNAPSHOT_ROOT": context.SNAPSHOT_ROOT,
                      "BASE": context.BASE,
                      "REPO": context.REPO,
                      "image_id": context.image_id,
                      "subprocess": context.subprocess}
        context.SNAPSHOT_ROOT = self.snap_root
        context.BASE = self.root
        context.REPO = self.repo
        context.image_id = self.docker.image_id
        context.subprocess = _Subprocess(self.docker)
        self.saved_env = os.environ.get("LR_GATE_LOCK_DIR")
        os.environ["LR_GATE_LOCK_DIR"] = self.lock_dir
        # The identity layer reads a few env defaults; a runner environment sets
        # them for real (LR_IMAGE = the derived gate tag), so the fixture
        # isolates them and restores on exit.
        self.saved_defaults = {}
        for name in ("LR_IMAGE", "OPENRESTY_TEST_IMAGE", "LR_RESTY_IMAGE",
                     "LR_GATE_UI_ONLY"):
            self.saved_defaults[name] = os.environ.get(name)
            os.environ.pop(name, None)
        return self

    def __exit__(self, *exc):
        for name, value in self.saved.items():
            setattr(context, name, value)
        if self.saved_env is None:
            os.environ.pop("LR_GATE_LOCK_DIR", None)
        else:
            os.environ["LR_GATE_LOCK_DIR"] = self.saved_env
        for name, value in self.saved_defaults.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
        shutil.rmtree(self.root, ignore_errors=True)


def fingerprint_with_note(repo, note):
    """A fingerprint of the tree with lualib/resty/a.lua replaced by NOTE."""
    rows = []
    for rel in context.SNAPSHOT_PATHS:
        full = os.path.join(repo, rel)
        if os.path.isfile(full):
            rows.append((rel, context._sha256_file(full)))
        elif os.path.isdir(full):
            for dirpath, dirnames, filenames in os.walk(full):
                for fn in filenames:
                    p = os.path.join(dirpath, fn)
                    r = os.path.relpath(p, repo)
                    if context.snapshot_excluded(r):
                        continue
                    if r == "lualib/resty/a.lua":
                        sha = hashlib.sha256(("-- " + note + "\n").encode()).hexdigest()
                    else:
                        sha = context._sha256_file(p)
                    rows.append((r, sha))
    rows.sort()
    digest = hashlib.sha256()
    for r, sha in rows:
        digest.update(("%s %s\n" % (r, sha)).encode())
    return {"fingerprint": digest.hexdigest(), "files": len(rows),
            "manifest": [{"path": r, "sha256": s} for r, s in rows]}


def test_snapshot_is_a_closed_tree():
    with Env() as env:
        repo = env.repo
        os.makedirs(os.path.join(repo, "test", "integration", "__pycache__"))
        write(os.path.join(repo, "test", "integration", "__pycache__", "x.pyc"), "bc\n")
        write(os.path.join(repo, "test", "integration", "e2e_y.pyc"), "bc\n")
        write(os.path.join(repo, "test", "local.env"), "LMR_ADMIN_AUTH_PASS=s3cr3t\n")
        write(os.path.join(repo, "test", "local.env.example"), "LMR_ADMIN_AUTH_PASS=\n")
        os.makedirs(os.path.join(repo, "test", "logs"))
        write(os.path.join(repo, "test", "logs", "gate.log"), "line\n")
        os.makedirs(os.path.join(repo, "test", "tmp"))
        write(os.path.join(repo, "test", "tmp", "scratch"), "scratch\n")
        os.makedirs(os.path.join(repo, "test", "results"))
        write(os.path.join(repo, "test", "results", "unit.json"), "{}\n")
        os.makedirs(os.path.join(repo, "test", "integration", "fixtures", "tls"))
        write(os.path.join(repo, "test", "integration", "fixtures", "tls", "server.key"),
              "PRIVATE KEY\n")
        write(os.path.join(repo, "test", "integration", "fixtures", "tls", "server.crt"),
              "CERT\n")

        fp = context.source_fingerprint(repo)
        paths = [row["path"] for row in fp["manifest"]]
        check("local.env is not fingerprinted", "test/local.env" not in paths, paths[:5])
        check("a private key is not fingerprinted",
              not any(p.endswith(".key") for p in paths), paths[:5])
        check("bytecode is not fingerprinted",
              not any(p.endswith(".pyc") for p in paths), paths[:5])
        check("run products are not fingerprinted",
              not any(p.startswith(("test/logs/", "test/tmp/", "test/results/"))
                      for p in paths), paths[:5])
        check("the public TLS cert fixture IS fingerprinted",
              "test/integration/fixtures/tls/server.crt" in paths, paths[:5])

        snap = context._publish_snapshot(repo, fp)
        names = tree_of(snap)
        check("local.env is not copied into the snapshot",
              "test/local.env" not in names, names)
        check("a private key is not copied into the snapshot",
              not any(n.endswith(".key") for n in names), names)
        check("no bytecode is copied into the snapshot",
              not any(n.endswith(".pyc") for n in names), names)
        check("no run products are copied into the snapshot",
              not any(n.startswith(("test/logs/", "test/tmp/", "test/results/"))
                      for n in names), names)
        check("the copy keeps a byte-identical fingerprint",
              context._fingerprint_of_copy(snap, repo)["fingerprint"]
              == fp["fingerprint"])
        check("the published snapshot has no symlinks",
              not [n for n in names if os.path.islink(os.path.join(snap, n))], names)

        write(os.path.join(env.root, "outside.txt"), "live tree\n")
        os.symlink(os.path.join(env.root, "outside.txt"),
                   os.path.join(repo, "lualib", "link-out.lua"))
        try:
            context._materialise_snapshot(repo, fp, os.path.join(env.root, "d1"))
            check("a symlinked file in the source tree is refused", False, "copied")
        except RuntimeError as exc:
            check("a symlinked file in the source tree is refused",
                  "symlink" in str(exc), exc)
        os.unlink(os.path.join(repo, "lualib", "link-out.lua"))
        os.symlink(env.root, os.path.join(repo, "lualib", "loop"))
        try:
            context._materialise_snapshot(repo, fp, os.path.join(env.root, "d2"))
            check("a symlinked directory in the source tree is refused", False, "copied")
        except RuntimeError as exc:
            check("a symlinked directory in the source tree is refused",
                  "symlink" in str(exc), exc)
        os.unlink(os.path.join(repo, "lualib", "loop"))

        os.makedirs(os.path.join(repo, "lualib", "resty", "tmp"))
        write(os.path.join(repo, "lualib", "resty", "tmp", "junk"), "junk\n")
        check("a nested tmp directory is outside the tree",
              context.snapshot_excluded("lualib/resty/tmp/junk"))
        check("a nested generated directory is outside the tree",
              context.snapshot_excluded("lualib/resty/__pycache__/a.pyc"))
        check("an ordinary module is inside the tree",
              not context.snapshot_excluded("lualib/resty/a.lua"))


def test_repo_under_tmp_freezes_the_whole_tree():
    """The tmp component rule must not prune a repo that LIVES under /tmp."""
    with Env():
        outer = tempfile.mkdtemp(prefix="lr-under-tmp.", dir="/tmp")
        try:
            repo = make_repo(os.path.join(outer, "repo"))
            fp = context.source_fingerprint(repo)
            check("a repo under /tmp fingerprints its real file count",
                  fp["files"] == len(tree_of(repo)), (fp["files"], tree_of(repo)))
            check("a repo under /tmp keeps its lualib files in the digest",
                  any(row["path"] == "lualib/resty/a.lua" for row in fp["manifest"]),
                  fp["manifest"][:4])
            snap = context._publish_snapshot(repo, fp)
            check("a repo under /tmp publishes a complete snapshot",
                  len(tree_of(snap)) == len(tree_of(repo)) + 2,
                  (len(tree_of(snap)), len(tree_of(repo))))
        finally:
            shutil.rmtree(outer, ignore_errors=True)


def test_docs_only_change_does_not_move_the_fingerprint():
    with Env() as env:
        repo = env.repo
        before = context.source_fingerprint(repo)["fingerprint"]
        os.makedirs(os.path.join(repo, "doc"))
        write(os.path.join(repo, "doc", "notes.md"), "prose\n")
        write(os.path.join(repo, "README.md"), "prose\n")
        write(os.path.join(repo, "AGENTS.md"), "prose\n")
        check("a docs-only edit leaves the source fingerprint alone",
              context.source_fingerprint(repo)["fingerprint"] == before)
        write(os.path.join(repo, "lualib", "resty", "a.lua"), "-- two\n")
        moved = context.source_fingerprint(repo)["fingerprint"]
        check("a lualib edit moves it", moved != before)
        write(os.path.join(repo, "test", "local.env"), "LMR_ADMIN_AUTH_PASS=rotated\n")
        check("rotating the operator secret leaves the fingerprint alone",
              context.source_fingerprint(repo)["fingerprint"] == moved)


def test_edit_during_copy_is_rejected_not_published():
    with Env() as env:
        saved = context.SNAPSHOT_RETRIES
        context.SNAPSHOT_RETRIES = 1
        real = context.source_fingerprint
        state = {"n": 0}

        def moving(repo, paths=context.SNAPSHOT_PATHS):
            state["n"] += 1
            return fingerprint_with_note(repo, "attempt-%d" % state["n"])

        context.source_fingerprint = moving
        try:
            target = fingerprint_with_note(env.repo, "attempt-0")
            try:
                context._publish_snapshot(env.repo, target)
                check("a tree that moves during publish is rejected", False,
                      "publish returned")
            except RuntimeError as exc:
                check("a tree that moves during publish is rejected",
                      "retries exhausted" in str(exc), exc)
            check("nothing is published under the pre-edit digest",
                  not os.path.exists(os.path.join(env.snap_root,
                                                  target["fingerprint"])),
                  os.listdir(env.snap_root))
            check("the rejection is loud, not a silent success",
                  state["n"] >= 2, state["n"])
            check("no temp tree survives the rejection",
                  not [d for d in os.listdir(env.snap_root)
                       if d.startswith(".tmp-")], os.listdir(env.snap_root))
        finally:
            context.source_fingerprint = real
            context.SNAPSHOT_RETRIES = saved
    with Env() as env:
        n = {"i": 0}
        real = context.source_fingerprint

        def settle(repo, paths=context.SNAPSHOT_PATHS):
            n["i"] += 1
            return fingerprint_with_note(repo, "one" if n["i"] > 3 else "moving")

        context.source_fingerprint = settle
        try:
            snap = context._publish_snapshot(
                env.repo, fingerprint_with_note(env.repo, "stale"))
            check("a tree that settles is published at its own digest",
                  os.path.basename(snap) == real(env.repo)["fingerprint"],
                  (snap, real(env.repo)["fingerprint"]))
        finally:
            context.source_fingerprint = real


def test_concurrent_first_publish_copies_are_independent():
    with Env() as env:
        got = {}
        barrier = threading.Barrier(4)

        def worker(i):
            barrier.wait()
            fp = context.source_fingerprint(env.repo)
            got[i] = context._publish_snapshot(env.repo, fp)

        ts = [threading.Thread(target=worker, args=(i,)) for i in (0, 1, 2)]
        [t.start() for t in ts]
        barrier.wait()
        [t.join(60) for t in ts]
        snaps = sorted(set(got.values()))
        check("three concurrent first freezes publish one snapshot",
              len(snaps) == 1 and len(got) == 3, snaps)
        check("every caller gets the same content-addressed directory",
              all(os.path.isdir(s) for s in snaps), snaps)
        check("no temp tree is left behind",
              not [d for d in os.listdir(env.snap_root) if d.startswith(".tmp-")],
              os.listdir(env.snap_root))
        check("no build Dockerfile is left behind",
              not [d for d in os.listdir(env.snap_root) if d.startswith(".build-")],
              os.listdir(env.snap_root))
        check("the snapshot passes integrity validation",
              context._valid_snapshot(snaps[0], os.path.basename(snaps[0])), snaps[0])


def test_concurrent_prepare_builds_once():
    with Env() as env:
        box = {"manifests": [], "error": []}
        barrier = threading.Barrier(3)

        def worker():
            barrier.wait()
            try:
                box["manifests"].append(
                    context.prepare(repo=env.repo, log=lambda m: None, **ENV_KW))
            except Exception as exc:            # noqa: BLE001
                box["error"].append(exc)

        ts = [threading.Thread(target=worker) for _ in range(2)]
        [t.start() for t in ts]
        barrier.wait()
        [t.join(120) for t in ts]
        check("two concurrent prepares of one tree both succeed",
              not box["error"] and len(box["manifests"]) == 2, box["error"])
        check("one tree builds once; the peer adopts the registry entry",
              len(env.docker.builds) == 1, env.docker.builds)
        m = box["manifests"][0]
        check("both manifests name the same image",
              {x["image_id"] for x in box["manifests"]} == {m["image_id"]},
              [x["image_id"] for x in box["manifests"]])
        check("the manifest names the base the build ran on",
              m["build_base_id"] == AUTHZ_ID and m["build_base_ref"] == AUTHZ_REF, m)
        check("the cache key covers fingerprint + build base",
              m["cache_key"] == context.base_key(m["fingerprint"], AUTHZ_ID, AUTHZ_ID),
              m["cache_key"])
        check("the resty identity is recorded as environment, not base",
              m["resty_id"] == RESTY_ID, m)
        check("the image tag is the derived content tag, not the requested one",
              m["image_tag"].startswith("lua-router:gate-")
              and m["requested_tag"] == "lua-router:integration", m)
        check("prepare wrote the run identity next to the snapshot",
              os.path.isfile(os.path.join(m["snapshot"], ".gate", "prepared.json")))
        check("the pinned Dockerfile is trashed, not left in the store",
              not [d for d in os.listdir(env.snap_root) if d.startswith(".build-")],
              os.listdir(env.snap_root))


def test_freeze_and_prepare_agree_on_one_identity():
    with Env() as env:
        real = context.source_fingerprint
        calls = {"n": 0}

        def counting(repo=None, paths=context.SNAPSHOT_PATHS):
            calls["n"] += 1
            return real(repo or env.repo, paths)

        context.source_fingerprint = counting
        try:
            f = context.freeze(repo=env.repo, **ENV_KW)
            builds_after_freeze = list(env.docker.builds)
            p = context.prepare(repo=env.repo, log=lambda m: None, **ENV_KW)
            f2 = context.freeze(repo=env.repo, **ENV_KW)
        finally:
            context.source_fingerprint = real
        keys = ("fingerprint", "image_tag", "authz_id", "build_base_id",
                "build_base_ref", "cache_key", "resty_id", "snapshot")
        check("freeze resolves the same identity prepare resolves",
              all(f[k] == p[k] for k in keys), {k: (f[k], p[k]) for k in keys})
        check("one core hashes once per entry point (publish adds its before/after pair)",
              calls["n"] == 5, calls["n"])
        check("freeze does not build", builds_after_freeze == [], builds_after_freeze)
        check("prepare builds exactly once",
              len(env.docker.builds) == 1, env.docker.builds)
        gate_tags = [t for src, t in env.docker.tags
                     if t.startswith("lua-router:gate-")]
        check("the next freeze finds the image and re-tags without a build",
              len(env.docker.builds) == 1 and len(gate_tags) == 1
              and f2["image_id"] == p["image_id"],
              (env.docker.builds, env.docker.tags, f2["image_id"], p["image_id"]))
        check("the second freeze is the same identity, not a re-frozen tree",
              all(f2[k] == p[k] for k in keys + ("image_id",)),
              {k: (f2[k], p[k]) for k in keys})
        check("both entry points carry the same schema",
              f["schema"] == p["schema"] == 3, (f["schema"], p["schema"]))
        check("a prepared manifest is loadable",
              context.load_manifest(
                  os.path.join(p["snapshot"], ".gate", "prepared.json"))
              ["fingerprint"] == p["fingerprint"])


def test_the_build_base_is_the_dockerfile_not_the_test_image():
    """OPENRESTY_TEST_IMAGE may name a different image; the build key follows FROM."""
    alt = "apisix-retagged:test"
    with Env(ids={alt: "sha256:zzz"}) as env:
        m = context.prepare(repo=env.repo, log=lambda m: None,
                            authz=alt, resty=RESTY_REF)
        check("the env test image identity is recorded",
              m["authz_ref"] == alt and m["authz_id"] == "sha256:zzz", m)
        check("the build base is the Dockerfile FROM image",
              m["build_base_id"] == AUTHZ_ID and m["build_base_ref"] == AUTHZ_REF, m)
        check("the cache key is derived from the build base, not the env image",
              m["cache_key"] == context.base_key(m["fingerprint"], AUTHZ_ID, AUTHZ_ID)
              and m["cache_key"] != context.base_key(m["fingerprint"], "sha256:zzz",
                                                     "sha256:zzz"), m["cache_key"])
        tag, text = env.docker.built[0]
        pin = re.search(r"(?mi)^FROM\s+(\S+)", text).group(1)
        check("the build consumed exactly one pinned Dockerfile",
              len(env.docker.built) == 1, env.docker.built)
        check("the FROM line is pinned to a private tag, not the mutable ref",
              "authz:latest" not in text and pin.startswith("lua-router-gate-base:pin-"),
              text[:160])
        check("the pin tag resolves to the FROM-resolved base id",
              env.docker.pin_ids.get(pin) == AUTHZ_ID,
              (pin, env.docker.pin_ids))
        check("the pin tag is removed after the build",
              pin not in env.docker.ids, sorted(env.docker.ids))
    with Env() as env2:
        snap = context._publish_snapshot(env2.repo,
                                         context.source_fingerprint(env2.repo))
        path, pin = context.immutable_buildfile(snap, AUTHZ_REF, "sha256:pinned")
        with open(path) as fh:
            text = fh.read()
        check("the pinned Dockerfile FROM names the pin tag",
              text.split("FROM ")[1].startswith(pin)
              and AUTHZ_REF not in text, text[:160])
        check("the pin tag is bound to the immutable id",
              env2.docker.ids.get(pin) == "sha256:pinned", env2.docker.ids.get(pin))
        context.release_build_pin(path, pin)
        check("the pinned Dockerfile is removed after use", not os.path.exists(path))
        check("the pin tag is released with the build",
              pin not in env2.docker.ids, sorted(env2.docker.ids))
        write(os.path.join(snap, "Dockerfile"),
              "FROM authz:latest AS a\nFROM authz:latest AS b\n")
        try:
            context.dockerfile_base(snap)
            check("a multi-stage snapshot Dockerfile is refused", False, "resolved")
        except RuntimeError as exc:
            check("a multi-stage snapshot Dockerfile is refused",
                  "non-scratch FROM" in str(exc), exc)


def test_base_change_cannot_reuse_the_old_image():
    with Env(ids={"authz:latest": "sha256:old-base"}) as env:
        p1 = context.prepare(repo=env.repo, log=lambda m: None, **ENV_KW)
        check("the first prepare built on the resolved base",
              p1["build_base_id"] == "sha256:old-base" and len(env.docker.builds) == 1,
              (p1["build_base_id"], env.docker.builds))
        env.docker.ids["authz:latest"] = "sha256:new-base"
        check("registry_lookup on the new base is a MISS",
              context.registry_lookup(p1["fingerprint"], "sha256:new-base",
                                      "sha256:new-base") is None)
        p2 = context.prepare(repo=env.repo, log=lambda m: None, **ENV_KW)
        check("a new base forces a fresh build for one fingerprint",
              len(env.docker.builds) == 2, env.docker.builds)
        check("the two runs have distinct cache keys",
              p1["cache_key"] != p2["cache_key"], (p1["cache_key"], p2["cache_key"]))
        check("the derived tag moves with the base",
              p1["image_tag"] != p2["image_tag"], (p1["image_tag"], p2["image_tag"]))
        check("the old image id is gone from the new manifest",
              p2["image_id"] != p1["image_id"], (p1["image_id"], p2["image_id"]))
        entry = context._registry_entry(p2, "sha256:img")
        env.docker.ids["sha256:img"] = "sha256:img"
        entry.pop("build_base_id")
        context._registry_put(entry)
        check("a legacy row is read through authz_id",
              context.registry_lookup(p2["fingerprint"], p2["authz_id"]) is not None)
        check("a legacy row on a foreign base is still a miss",
              context.registry_lookup(p2["fingerprint"], "sha256:other") is None)
        check("resty never participates in the build key",
              context.base_key(p2["fingerprint"], "sha256:new-base")
              == p2["cache_key"]
              and context.gate_image_tag(p2["fingerprint"], "sha256:new-base")
              == p2["image_tag"])
        env.docker.absent.add("sha256:img")
        check("registry_lookup refuses an image the daemon no longer has",
              context.registry_lookup(p2["fingerprint"], p2["authz_id"],
                                      p2["build_base_id"]) is None)


def test_load_manifest_refuses_a_contaminated_snapshot():
    with Env() as env:
        m = context.prepare(repo=env.repo, log=lambda m: None, **ENV_KW)
        path = os.path.join(m["snapshot"], ".gate", "prepared.json")
        check("a clean manifest loads",
              context.load_manifest(path)["fingerprint"] == m["fingerprint"])
        # Image-level refusals come first: the checks below deliberately
        # contaminate this snapshot, and the digest check fires first.
        gone = dict(m, image_id="sha256:deleted")
        env.docker.absent.add("sha256:deleted")
        gp = os.path.join(env.root, "gone.json")
        write(gp, json.dumps(gone))
        try:
            context.load_manifest(gp)
            check("a manifest naming a deleted image is refused", False, "loaded")
        except RuntimeError as exc:
            check("a manifest naming a deleted image is refused",
                  "not present" in str(exc), exc)
        nobase = dict(m, build_base_id="sha256:ghost")
        env.docker.absent.add("sha256:ghost")
        nb = os.path.join(env.root, "nobase.json")
        write(nb, json.dumps(nobase))
        try:
            context.load_manifest(nb)
            check("a manifest naming an absent build base is refused", False, "loaded")
        except RuntimeError as exc:
            check("a manifest naming an absent build base is refused",
                  "build base" in str(exc), exc)
        write(os.path.join(m["snapshot"], "lualib", "resty", "a.lua"),
              "-- edited after publication\n")
        try:
            context.load_manifest(path)
            check("a snapshot edited after publication is refused", False, "loaded")
        except RuntimeError as exc:
            check("a snapshot edited after publication is refused",
                  "digest" in str(exc) or "match" in str(exc), exc)
        problem = context.load_manifest(path, verify=False)["_verify_problem"]
        check("the forensic mode names the problem instead of hiding it",
              "digest" in problem or "match" in problem, problem)
        os.unlink(os.path.join(m["snapshot"], "lualib", "resty", "a.lua"))
        try:
            context.load_manifest(path)
            check("a snapshot with a deleted file is refused", False, "loaded")
        except RuntimeError as exc:
            check("a snapshot with a deleted file is refused",
                  "manifest" in str(exc) or "digest" in str(exc), exc)
        forged = os.path.join(env.snap_root, "f" * 64)
        os.makedirs(os.path.join(forged, ".gate"))
        write(os.path.join(forged, ".ready"), "f" * 64 + "\n")
        bad = dict(m, snapshot=forged, fingerprint="f" * 64)
        bad_path = os.path.join(env.root, "forged.json")
        write(bad_path, json.dumps(bad))
        try:
            context.load_manifest(bad_path)
            check("a forged .ready without a manifest is refused", False, "loaded")
        except RuntimeError as exc:
            check("a forged .ready without a manifest is refused",
                  "manifest" in str(exc), exc)
        for field in ("schema", "fingerprint", "snapshot", "image_tag", "authz_id",
                      "build_base_id"):
            stripped = dict(m)
            stripped.pop(field)
            p2 = os.path.join(env.root, "strip-%s.json" % field)
            write(p2, json.dumps(stripped))
            try:
                context.load_manifest(p2)
                check("a manifest without %s is refused" % field, False, "loaded")
            except RuntimeError as exc:
                check("a manifest without %s is refused" % field,
                      "missing" in str(exc), exc)


def test_registry_and_manifest_io_are_atomic():
    with Env() as env:
        base = context._registry_entry(
            {"fingerprint": "f" * 64, "authz_id": AUTHZ_ID,
             "build_base_ref": AUTHZ_REF, "build_base_id": AUTHZ_ID,
             "cache_key": "k", "resty_id": RESTY_ID,
             "image_tag": "lua-router:gate-k"}, "sha256:img")
        env.docker.ids["sha256:img"] = "sha256:img"
        context._registry_put(base)
        context._registry_put_locked(dict(base, fingerprint="b" * 64))
        doc = json.load(open(context._registry_path()))
        check("a put preserves a peer row", len(doc) == 2, sorted(doc))
        check("no temp litter survives a registry write",
              not [f for f in os.listdir(env.snap_root) if ".tmp." in f],
              os.listdir(env.snap_root))
        snap = os.path.join(env.snap_root, "prepared")
        os.makedirs(os.path.join(snap, ".gate"))
        context._write_prepared(snap, {"a": 1})
        context._write_prepared(snap, {"a": 2})
        check("prepared.json is replaced atomically",
              json.load(open(os.path.join(snap, ".gate", "prepared.json"))) == {"a": 2})
        check("no .part litter survives an atomic write",
              not [f for f in os.listdir(os.path.join(snap, ".gate"))
                   if ".part" in f], os.listdir(os.path.join(snap, ".gate")))
        m = context.prepare(repo=env.repo, log=lambda m: None, **ENV_KW)
        env.docker.ids[m["image_tag"]] = "sha256:gate-image"
        out = context.manifest_with_built_image(m)
        check("the build gate backfill keeps the manifest base identity",
              out["build_base_id"] == m["build_base_id"]
              and out["cache_key"] == m["cache_key"], (out, m))
        check("the backfilled image is recorded in the registry",
              context.registry_lookup(m["fingerprint"], m["authz_id"],
                                      m["build_base_id"])["image_id"]
              == "sha256:gate-image")
        naked = dict(m)
        naked.pop("build_base_id")
        try:
            context.manifest_with_built_image(naked)
            check("a manifest with no build base cannot certify an image", False, "ok")
        except RuntimeError as exc:
            check("a manifest with no build base cannot certify an image",
                  "build base" in str(exc), exc)




def test_build_for_manifest_pins_the_frozen_base_after_a_retag():
    """The build GATE builds on the base the MANIFEST pinned, not the live tag.

    This is the mixed-version window the shell body cannot see: freeze resolves
    authz:latest to id A, something retags the name to B, and a plain
    `docker build -f Dockerfile` inside the snapshot would build on B while the
    run reports A. build_for_manifest probes only the immutable ids the manifest
    names, so it pins A and records A.
    """
    with Env() as env:
        m = context.freeze(repo=env.repo, **ENV_KW)
        env.docker.ids["authz:latest"] = "sha256:retagged-B"
        out = context.build_for_manifest(m, log=lambda x: None)
        check("the build ran once", len(env.docker.builds) == 1, env.docker.builds)
        check("the returned identity is the manifest identity",
              out["image_tag"] == m["image_tag"]
              and out["cache_key"] == m["cache_key"]
              and out["build_base_id"] == AUTHZ_ID and out["built"] is True, out)
        pin = re.search(r"(?mi)^FROM\s+(\S+)", env.docker.built[0][1]).group(1)
        check("the FROM line is pinned to the FROZEN base id, not the retagged name",
              env.docker.pin_ids.get(pin) == AUTHZ_ID,
              (pin, env.docker.pin_ids, env.docker.ids["authz:latest"]))
        check("the retagged live tag was never consulted for the build",
              "sha256:retagged-B" not in set(env.docker.pin_ids.values()),
              env.docker.pin_ids)
        row = context._registry_read(m["fingerprint"])
        check("the registry row is keyed to the frozen base",
              row["build_base_id"] == AUTHZ_ID and row["authz_id"] == AUTHZ_ID,
              row)
        check("the registry row records the image the build produced",
              row["image_id"] == out["image_id"], row)
        check("the pin tag is gone and no Dockerfile litter remains",
              pin not in env.docker.ids
              and not [d for d in os.listdir(env.snap_root)
                       if d.startswith(".build-")], os.listdir(env.snap_root))
        # A second call on the same manifest adopts the registry image: no build.
        builds_before = len(env.docker.builds)
        out2 = context.build_for_manifest(m, log=lambda x: None)
        check("the same manifest reuses the recorded image without a build",
              len(env.docker.builds) == builds_before
              and out2["image_id"] == out["image_id"] and out2["built"] is False,
              (env.docker.builds, out2))


def test_build_for_manifest_refuses_a_contaminated_snapshot():
    with Env() as env:
        m = context.prepare(repo=env.repo, log=lambda x: None, **ENV_KW)
        path = os.path.join(m["snapshot"], ".gate", "prepared.json")
        write(os.path.join(m["snapshot"], "lualib", "resty", "a.lua"),
              "-- edited after publication\n")
        builds_before = len(env.docker.builds)
        try:
            context.build_for_manifest(path, log=lambda x: None)
            check("a contaminated snapshot is refused before any build", False,
                  "built")
        except RuntimeError as exc:
            check("a contaminated snapshot is refused before any build",
                  "integrity" in str(exc) or "match" in str(exc)
                  or "digest" in str(exc), exc)
        check("the refusal built nothing",
              len(env.docker.builds) == builds_before, env.docker.builds)


def test_build_for_manifest_requires_the_pinned_base():
    with Env() as env:
        m = context.freeze(repo=env.repo, **ENV_KW)
        for field in ("fingerprint", "snapshot", "image_tag",
                      "build_base_id", "cache_key"):
            naked = dict(m)
            naked.pop(field)
            try:
                context.build_for_manifest(naked, log=lambda x: None)
                check("build_for_manifest refuses a manifest without %s" % field,
                      False, "built")
            except RuntimeError as exc:
                check("build_for_manifest refuses a manifest without %s" % field,
                      field in str(exc), exc)
        check("none of the refusals touched docker build",
              env.docker.builds == [], env.docker.builds)
        # A manifest naming an absent base id is refused: no live-tag fallback.
        ghost = dict(m, build_base_id="sha256:ghost",
                     cache_key=context.base_key(m["fingerprint"], AUTHZ_ID,
                                                "sha256:ghost"))
        env.docker.absent.add("sha256:ghost")
        try:
            context.build_for_manifest(ghost, log=lambda x: None)
            check("an absent build base is refused", False, "built")
        except RuntimeError as exc:
            check("an absent build base is refused",
                  "not present" in str(exc), exc)
        check("an absent base never falls back to the live tag",
              env.docker.builds == [], env.docker.builds)


def test_run_context_exposes_the_gate_manifest():
    """The run writes its manifest to disk and names it in the gate env, so a
    shell build body can pin the run base with one CLI call and no re-resolve.
    """
    with Env() as env:
        from gates import catalog
        m = context.freeze(repo=env.repo, **ENV_KW)
        ctx = context.RunContext(m, log_dir=env.root)
        env_out = ctx.gate_env(catalog.BY_NAME["build"])
        path = env_out.get("LR_GATE_MANIFEST")
        check("the gate env names a run manifest",
              bool(path) and path == ctx.manifest_path, (path, ctx.manifest_path))
        check("the run manifest exists and loads under the full integrity rules",
              context.load_manifest(path)["fingerprint"] == m["fingerprint"], path)
        check("the gate env still points LR_IMAGE at the derived tag",
              env_out["LR_IMAGE"] == m["image_tag"], env_out["LR_IMAGE"])
        # LR_IMAGE by gate: the BUILD body tags the derived tag (it produces
        # this run's image); every other gate gets the resolved image id, and
        # a pre-build manifest (image_id not yet filled) falls back to the tag.
        check("the build gate keeps the derived tag",
              env_out["LR_IMAGE"] == m["image_tag"], env_out["LR_IMAGE"])
        env_unit = ctx.gate_env(catalog.BY_NAME["unit"])
        check("a non-build gate on a cold manifest falls back to the tag",
              env_unit["LR_IMAGE"] == m["image_tag"], env_unit["LR_IMAGE"])
        built = dict(m, image_id="sha256:built")
        ctx.update_manifest(built)
        env_unit2 = ctx.gate_env(catalog.BY_NAME["unit"])
        check("a non-build gate on a built manifest gets the built image id",
              env_unit2["LR_IMAGE"] == "sha256:built", env_unit2["LR_IMAGE"])
        check("the build gate keeps the tag after the id is known",
              ctx.gate_env(catalog.BY_NAME["build"])["LR_IMAGE"] == m["image_tag"],
              ctx.gate_env(catalog.BY_NAME["build"])["LR_IMAGE"])
        env.docker.ids[m["image_tag"]] = "sha256:built"
        check("update_manifest rewrites the on-disk run manifest atomically",
              context.load_manifest(ctx.manifest_path).get("image_id")
              == "sha256:built", ctx.manifest_path)
        # The three base/test slots carry the manifest's RESOLVED ids, not the
        # requested refs: a run must not let a body re-resolve a mutable tag.
        check("the gate env injects the resolved authz id for OPENRESTY_TEST_IMAGE",
              env_out["OPENRESTY_TEST_IMAGE"] == m["authz_id"] == AUTHZ_ID,
              env_out.get("OPENRESTY_TEST_IMAGE"))
        check("the gate env injects the resolved resty id for LR_RESTY_IMAGE",
              env_out["LR_RESTY_IMAGE"] == m["resty_id"] == RESTY_ID,
              env_out.get("LR_RESTY_IMAGE"))
        check("the gate env injects the resolved authz id for LR_BASE_IMAGE",
              env_out["LR_BASE_IMAGE"] == m["authz_id"] == AUTHZ_ID,
              env_out.get("LR_BASE_IMAGE"))
        check("no gate-env base slot is a mutable ref",
              AUTHZ_REF not in (env_out["OPENRESTY_TEST_IMAGE"],
                                env_out["LR_RESTY_IMAGE"],
                                env_out["LR_BASE_IMAGE"])
              and RESTY_REF not in (env_out["OPENRESTY_TEST_IMAGE"],
                                    env_out["LR_RESTY_IMAGE"],
                                    env_out["LR_BASE_IMAGE"]),
              {k: env_out[k] for k in ("OPENRESTY_TEST_IMAGE", "LR_RESTY_IMAGE",
                                       "LR_BASE_IMAGE")})
        ctx.cleanup()


def test_backfill_requires_base_evidence():
    """manifest_with_built_image validates against the registry, not a claim.

    A gate that built without the pin helper produced an image of unknown base;
    filling build_base_id in from the manifest would be the writer asserting the
    very fact it failed to establish, so the backfill refuses it.
    """
    with Env() as env:
        m = context.freeze(repo=env.repo, **ENV_KW)
        env.docker.ids[m["image_tag"]] = "sha256:gate-image"
        try:
            context.manifest_with_built_image(m)
            check("a backfill with no registry row is refused", False, "recorded")
        except RuntimeError as exc:
            check("a backfill with no registry row is refused",
                  "base evidence" in str(exc) or "no registry row" in str(exc), exc)
        out = context.build_for_manifest(m, log=lambda x: None)
        built = dict(m, image_id=out["image_id"])
        env.docker.ids[m["image_tag"]] = out["image_id"]
        rec = context.manifest_with_built_image(built)
        check("a backfill over a pinned build records the same base",
              rec["build_base_id"] == AUTHZ_ID and rec["image_id"] == out["image_id"],
              rec)
        drift = dict(rec, build_base_id="sha256:different-base")
        try:
            context.manifest_with_built_image(drift)
            check("a backfill whose base contradicts the registry is refused",
                  False, "recorded")
        except RuntimeError as exc:
            check("a backfill whose base contradicts the registry is refused",
                  "evidence" in str(exc), exc)



def test_requested_tag_honours_a_preset_env():
    """Production semantics, pinned: LR_IMAGE is RECORDED as the requested tag,
    and the derived content tag the run builds/uses is computed independently.
    """
    with Env() as env:
        os.environ["LR_IMAGE"] = "lua-router:gate-runner-placeholder"
        try:
            m = context.freeze(repo=env.repo, authz=AUTHZ_REF, resty=RESTY_REF)
        finally:
            os.environ.pop("LR_IMAGE", None)
        check("a runner-preset LR_IMAGE is recorded as the requested tag",
              m["requested_tag"] == "lua-router:gate-runner-placeholder", m)
        check("the derived content tag is unaffected by the requested tag",
              m["image_tag"].startswith("lua-router:gate-")
              and m["image_tag"] != m["requested_tag"],
              (m["image_tag"], m["requested_tag"]))
        check("the cache key ignores the requested tag entirely",
              m["cache_key"] == context.base_key(m["fingerprint"], AUTHZ_ID, AUTHZ_ID),
              m["cache_key"])




def test_explicit_run_id_is_an_exclusive_claim():
    """Two independent RunContexts naming one run id: the second refuses.

    This is the clobber-and-kill window the old rule left open: the first run
    had no report.json yet, so a second RunContext with the same explicit id
    shared the tree -- logs and results overwritten, and the first run's label
    sweep (one namespace, derived from that id) tore down the second's
    containers. The claim is a mkdir, so it holds whether or not a report was
    ever written.
    """
    with Env() as env:
        m = context.freeze(repo=env.repo, **ENV_KW)
        runs = os.path.join(env.root, "runs")
        a = context.RunContext(m, run_id="gate-A", log_dir=env.root)
        # The first context created its dirs under the claimed name.
        check("the claim creates the run tree",
              os.path.isdir(os.path.join(runs, "gate-A", "results"))
              and os.path.isfile(os.path.join(runs, "gate-A", "gate-manifest.json")))
        b = context.RunContext(m, run_id="gate-B", log_dir=env.root)
        check("a different explicit id claims its own tree",
              b.run_id == "gate-B" and b.root != a.root, (b.run_id, b.root))
        # The dangerous case: same id, first run still ALIVE (no report.json).
        try:
            context.RunContext(m, run_id="gate-A", log_dir=env.root)
            check("reusing a live run id is refused", False, "second context built")
        except RuntimeError as exc:
            check("reusing a live run id is refused",
                  "already claimed" in str(exc), exc)
        # ... and the reported case: report.json present is equally refused
        # (no suffix laundering into gate-A-2 any more).
        write(os.path.join(runs, "gate-A", "report.json"), "{}\n")
        try:
            context.RunContext(m, run_id="gate-A", log_dir=env.root)
            check("reusing a reported run id is refused, not suffixed",
                  False, "second context built")
        except RuntimeError as exc:
            check("reusing a reported run id is refused, not suffixed",
                  "already claimed" in str(exc), exc)
        check("no suffix directory was quietly created",
              not os.path.exists(os.path.join(runs, "gate-A-2")),
              sorted(os.listdir(runs)))
        check("the refused attempt left no half-created tree",
              os.path.isfile(os.path.join(runs, "gate-A", "report.json")))
        # Namespace derives from the FINAL claimed id: gate-A and gate-B sweep
        # independently, so a cleanup on one cannot touch the other.
        check("distinct claimed ids get distinct namespaces",
              a.namespace != b.namespace, (a.namespace, b.namespace))
        check("the namespace names the claimed id, not a paraphrase",
              a.namespace == context.container_namespace("gate-A"), a.namespace)
        a.cleanup()
        b.cleanup()


def test_concurrent_first_claim_has_exactly_one_winner():
    with Env() as env:
        m = context.freeze(repo=env.repo, **ENV_KW)
        runs = os.path.join(env.root, "runs")
        box = {"ok": [], "err": []}
        # 2 workers + the main thread: three parties on the barrier, so the
        # release is simultaneous (a 2-party barrier with 3 arrivals deadlocks).
        barrier = threading.Barrier(3)

        def worker():
            barrier.wait()
            try:
                box["ok"].append(
                    context.RunContext(m, run_id="gate-race", log_dir=env.root))
            except RuntimeError as exc:
                box["err"].append(exc)

        ts = [threading.Thread(target=worker) for _ in range(2)]
        [t.start() for t in ts]
        barrier.wait()
        [t.join(30) for t in ts]
        check("two concurrent claims of one run id admit exactly one winner",
              len(box["ok"]) == 1 and len(box["err"]) == 1,
              (len(box["ok"]), len(box["err"]), [str(e)[:60] for e in box["err"]]))
        check("the loser says already claimed",
              box["err"] and "already claimed" in str(box["err"][0]), box["err"])
        check("exactly one run tree exists",
              os.path.isdir(runs) and os.listdir(runs) == ["gate-race"],
              os.listdir(runs) if os.path.isdir(runs) else None)
        check("the winner owns the claimed id and its namespace",
              len(box["ok"]) == 1
              and box["ok"][0].run_id == "gate-race"
              and box["ok"][0].namespace == context.container_namespace("gate-race"),
              box["ok"] and (box["ok"][0].run_id, box["ok"][0].namespace))
        for ctx in box["ok"]:
            ctx.cleanup()


def test_generated_run_ids_are_unique_and_claimed():
    with Env() as env:
        m = context.freeze(repo=env.repo, **ENV_KW)
        ctxs = [context.RunContext(m, log_dir=env.root) for _ in range(6)]
        ids = [c.run_id for c in ctxs]
        check("generated run ids are unique per context, not per second",
              len(set(ids)) == len(ids), ids)
        check("each generated id claims its own tree",
              len(set(c.root for c in ctxs)) == len(ids),
              sorted(c.root for c in ctxs))
        check("the namespace matches the final claimed id for every run",
              all(c.namespace == context.container_namespace(c.run_id) for c in ctxs))
        check("a generated run tree carries the manifest and the subdirs",
              all(os.path.isfile(c.manifest_path) and os.path.isdir(c.result_dir)
                  and os.path.isdir(c.log_dir) and os.path.isdir(c.tmp)
                  for c in ctxs), ids)
        for c in ctxs:
            c.cleanup()


def test_evil_run_ids_are_refused():
    with Env() as env:
        m = context.freeze(repo=env.repo, **ENV_KW)
        runs = os.path.join(env.root, "runs")
        # Snapshot the parent: sibling tests legitimately created generated-run
        # trees, so the honest claim is "a refusal adds nothing", not "the
        # parent is empty".
        before = sorted(os.listdir(runs)) if os.path.isdir(runs) else []
        evil = ["", " ", "/", "//", "..", "../escape", "a/b", "a\\b", ".",
                "x" * 65, "with space", "a.b", "tab\there", "caf\u00e9"]
        for bad in evil:
            try:
                context.RunContext(m, run_id=bad, log_dir=env.root)
                check("run id %r is refused" % bad, False, "accepted")
            except RuntimeError as exc:
                check("run id %r is refused" % bad, "not safe" in str(exc), exc)
        after = sorted(os.listdir(runs)) if os.path.isdir(runs) else []
        check("a refused id created nothing under the runs parent",
              after == before, (before, after))
        check("nothing escaped the runs parent",
              not os.path.exists(os.path.join(env.root, "escape")))
        ok = context.RunContext(m, run_id="A_b-9_20261012-230107", log_dir=env.root)
        check("the documented safe alphabet is accepted",
              ok.run_id == "A_b-9_20261012-230107" and os.path.isdir(ok.result_dir),
              ok.run_id)
        ok.cleanup()
        # Generation is None-only: an empty string is a claim on the empty name,
        # and runs/"" is a tree no listing tool shows.
        for blank in ("", " "):
            try:
                context.RunContext(m, run_id=blank, log_dir=env.root)
                check("run id %r is refused, not generated" % blank, False, "accepted")
            except RuntimeError as exc:
                check("run id %r is refused, not generated" % blank,
                      "not safe" in str(exc), exc)
        n = context.RunContext(m, run_id=None, log_dir=env.root)
        check("None is the only generate signal", bool(n.run_id), n.run_id)
        n.cleanup()


def main():
    for fn in (test_snapshot_is_a_closed_tree,
               test_repo_under_tmp_freezes_the_whole_tree,
               test_docs_only_change_does_not_move_the_fingerprint,
               test_edit_during_copy_is_rejected_not_published,
               test_concurrent_first_publish_copies_are_independent,
               test_concurrent_prepare_builds_once,
               test_freeze_and_prepare_agree_on_one_identity,
               test_the_build_base_is_the_dockerfile_not_the_test_image,
               test_base_change_cannot_reuse_the_old_image,
               test_load_manifest_refuses_a_contaminated_snapshot,
               test_registry_and_manifest_io_are_atomic,
               test_build_for_manifest_pins_the_frozen_base_after_a_retag,
               test_build_for_manifest_refuses_a_contaminated_snapshot,
               test_build_for_manifest_requires_the_pinned_base,
               test_run_context_exposes_the_gate_manifest,
               test_backfill_requires_base_evidence,
               test_requested_tag_honours_a_preset_env,
               test_explicit_run_id_is_an_exclusive_claim,
               test_concurrent_first_claim_has_exactly_one_winner,
               test_generated_run_ids_are_unique_and_claimed,
               test_evil_run_ids_are_refused):
        fn()
    failed = [c for c in CHECKS if not c[0]]
    print("\n=== %d checks, %d failed ===" % (len(CHECKS), len(failed)))
    for _, name, detail in failed:
        print("FAILED: %s | %s" % (name, detail))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
