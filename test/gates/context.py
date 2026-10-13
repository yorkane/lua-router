#!/usr/bin/env python3
"""Run identity: frozen source snapshot, fingerprints, images, dirs, cleanup.

Why a snapshot at all: every suite mounts the repo into its containers, so a
parallel agent editing lualib/ mid-run silently changes the bytes under a gate
that already started, and the green log then describes a tree that never
existed. prepare copies the parts of the tree the gates read (lualib, conf, ui,
test, Dockerfile, docker-entrypoint.sh) into a content-addressed directory and
every gate body runs with that directory as REPO. A run therefore verifies one
immutable source fingerprint.

Cache rule (deliberate): the snapshot cache and the image cache are keyed by
that fingerprint, so a second run of the same tree reuses the copy and the
image. That reuse covers PREPARATION ONLY. No gate result is ever reused from
the cache: results live in the per-run directory and the run always executes
every selected gate. Aggregate-green therefore always means "these gates ran".
"""

import fcntl
import hashlib
import json
import os
import atexit
import re
import secrets
import threading
import shutil
import signal
import subprocess
import sys
import time

GATES_DIR = os.path.dirname(os.path.abspath(__file__))
TEST_DIR = os.path.dirname(GATES_DIR)
REPO = os.path.dirname(TEST_DIR)

# Imported after the path constants so the module works BOTH ways: as
# `gates.context` inside the package (the runner), and as a direct script
# (`python3 test/gates/context.py build --manifest M`) from a shell gate body.
if __package__:
    from . import locks as _gate_locks
else:
    sys.path.insert(0, GATES_DIR)
    import locks as _gate_locks

BASE = os.environ.get("LR_GATE_LOG_DIR", "/data/tmp/lr-gates")
SNAPSHOT_ROOT = os.path.join(BASE, "snapshots")
LEDGER = os.environ.get("LR_PORT_RESERVE") or os.path.join(BASE, "ports.reserved")

# The paths the gates read. Anything a suite mounts through /repo has to be in
# here, otherwise the snapshot would be a partial tree and a green run would be
# a lie about a subset.
SNAPSHOT_PATHS = ("lualib", "conf", "ui", "test", "Dockerfile", "docker-entrypoint.sh")
SNAPSHOT_EXCLUDED_FILES = {"test/local.env", "test/local.env.example",
                           "test/integration/fixtures/tls/server.key"}
# The directory names that never belong to the gate-visible tree. Matched as
# PATH COMPONENTS, not substrings: the substring form tested "/tmp/" against an
# absolute path, so freezing a repo checked out under /tmp pruned the whole
# tree and the fingerprint came back empty (hard rule: a snapshot is a fact,
# never an accident of where the repo lives).
SNAPSHOT_SKIP_DIRS = ("__pycache__", "node_modules", ".git", ".gate",
                      "logs", "results", "tmp")

# How many times the publish path retries when the tree moves under it. A tree
# that edits continuously is a build loop, not a gate subject; fail loudly.
SNAPSHOT_RETRIES = int(os.environ.get("LR_SNAPSHOT_RETRIES", "3"))


def snapshot_excluded(rel):
    """One predicate decides what is outside the gate-visible tree.

    The copy, the fingerprint, and the integrity re-hash all call this, so a
    file cannot be copied under one rule and hashed under another. Three
    families, all component/name tests (never a substring of an absolute path):
    generated and run-product directories, bytecode, and operator secrets --
    local.env* (gateway credentials) and private keys, which are loaded by the
    live entry before a snapshot is ever taken.
    """
    parts = rel.split(os.sep)
    name = parts[-1]
    return (any(p in SNAPSHOT_SKIP_DIRS for p in parts)
            or name.endswith(".pyc")
            or name.endswith(".key")
            or rel in SNAPSHOT_EXCLUDED_FILES
            or rel.startswith("test/local.env."))


def _copy_ignore(rel):
    """shutil.copytree ignore predicate for one snapshot path."""
    def _ignore(_root, names):
        out = []
        for name in names:
            relpath = os.path.join(rel, name) if rel else name
            if snapshot_excluded(relpath):
                out.append(name)
        return out
    return _ignore

_RUN_SEQ = [0]


def _uniq():
    _RUN_SEQ[0] += 1
    return (_RUN_SEQ[0] * 7919 + os.getpid()) & 0xFFFF



def _sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def source_fingerprint(repo=REPO, paths=SNAPSHOT_PATHS):
    """Manifest + digest of the gate-visible source tree.

    The harness itself (test/gates/*, test/final_gates.sh, test/port_allocator.py)
    is inside test/, so the fingerprint covers code and harness together: a run
    cannot be green under one harness and be reported against another.
    """
    rows = []
    for rel in paths:
        root = os.path.join(repo, rel)
        if os.path.isfile(root):
            rows.append((rel, _sha256_file(root)))
        elif os.path.isdir(root):
            for dirpath, dirnames, filenames in os.walk(root):
                dirnames[:] = sorted(
                    d for d in dirnames
                    if not snapshot_excluded(
                        os.path.relpath(os.path.join(dirpath, d), repo)))
                for fn in sorted(filenames):
                    full = os.path.join(dirpath, fn)
                    rel = os.path.relpath(full, repo)
                    if snapshot_excluded(rel):
                        continue
                    rows.append((rel, _sha256_file(full)))
    if not rows:
        raise RuntimeError("fingerprint is empty: %s does not look like the repo" % repo)
    rows.sort()
    digest = hashlib.sha256()
    for rel, sha in rows:
        digest.update(("%s %s\n" % (rel, sha)).encode())
    return {"fingerprint": digest.hexdigest(), "files": len(rows),
            "manifest": [{"path": rel, "sha256": sha} for rel, sha in rows]}


def image_id(ref):
    """Immutable image id for a tag, or None when the image is absent."""
    r = subprocess.run(["docker", "image", "inspect", "-f", "{{.Id}}", ref],
                       capture_output=True)
    if r.returncode != 0:
        return None
    return r.stdout.decode().strip() or None


def build_image(snapshot, tag, buildfile=None):
    """Build the gate image from a frozen snapshot; return its image id.

    buildfile defaults to the snapshot's own Dockerfile; prepare/freeze pass a
    copy whose FROM is pinned to the resolved base image id, so the image a run
    reports is built on the base the manifest names, not on whatever
    authz:latest points at when docker resolves the line.
    """
    r = subprocess.run(["docker", "build", "-t", tag, "-f",
                        buildfile or "Dockerfile", "."],
                       cwd=snapshot, capture_output=True)
    if r.returncode != 0:
        tail = (r.stderr.decode() + r.stdout.decode())[-4000:]
        raise RuntimeError("docker build failed (rc=%s):\n%s" % (r.returncode, tail))
    iid = image_id(tag)
    if not iid:
        raise RuntimeError("build reported success but %s has no image id" % tag)
    return iid


def dockerfile_base(snapshot):
    """(ref, id) for the base the SNAPSHOT's Dockerfile actually names.

    This is the build base, and it is read from the Dockerfile rather than from
    OPENRESTY_TEST_IMAGE: the env var names the image the unit suites run their
    containers on, which is a test-environment identity and may legitimately be
    a different image (on 21.k it is a retagged apisix). Keying the build on it
    would let a manifest claim a base the image was not built from.
    """
    with open(os.path.join(snapshot, "Dockerfile")) as fh:
        text = fh.read()
    refs = [m.group(1) for m in re.finditer(r"(?mi)^FROM\s+(\S+)", text)]
    refs = [r for r in refs if r.lower() != "scratch"]
    if len(refs) != 1:
        raise RuntimeError("expected exactly one non-scratch FROM in %s, found %d"
                           % (os.path.join(snapshot, "Dockerfile"), len(refs)))
    base = image_id(refs[0])
    if not base:
        raise RuntimeError("Dockerfile base %s is not present in the daemon" % refs[0])
    return refs[0], base


def immutable_buildfile(snapshot, base_ref, base_id):
    """Make a temporary Dockerfile whose FROM is pinned to the resolved base.

    The pin is a FRESH UNIQUE TAG aimed at the immutable image id (docker tag
    by id resolves locally, no network), not a bare 'FROM sha256:<id>' line:
    BuildKit parses a bare sha256 token as a remote repository name and tries
    to pull it, which fails on an air-gapped box. The pin tag names exactly one
    image id for the whole build, cannot be moved by a peer (nobody else knows
    it), and is removed by release_build_pin, so 'FROM authz:latest' can never
    resolve to a retagged base mid-build.

    Returns (dockerfile_path, pin_tag); the caller must release both.
    """
    source = os.path.join(snapshot, "Dockerfile")
    with open(source) as fh:
        dockerfile = fh.read()
    # The snapshot Dockerfile may carry a stage name (FROM authz:latest AS
    # final) and a trailing comment; the pin rewrites only the image token and
    # keeps the rest of the line intact.
    pattern = (r"(?mi)^(FROM\s+)" + re.escape(base_ref)
               + r"(\s+AS\s+\w+)?\s*(?:#.*)?$")
    pin = "lua-router-gate-base:pin-" + secrets.token_hex(8)
    replaced, n = re.subn(pattern,
                          lambda m: m.group(1) + pin + (m.group(2) or ""),
                          dockerfile, count=1)
    if n != 1:
        raise RuntimeError("expected exactly one FROM %s in snapshot Dockerfile"
                           % base_ref)
    r = subprocess.run(["docker", "tag", base_id, pin], capture_output=True)
    if r.returncode != 0:
        raise RuntimeError("cannot pin base image %s: %s"
                           % (base_id, r.stderr.decode()[-200:]))
    # Unique per invocation: concurrent prepares of one fingerprint must not
    # share the pinned Dockerfile (one writer would truncate the other's).
    path = os.path.join(SNAPSHOT_ROOT,
                        ".build-" + secrets.token_hex(8) + ".Dockerfile")
    with open(path, "w") as fh:
        fh.write(replaced)
    return path, pin


def release_build_pin(buildfile, pin_tag):
    """Drop the pin tag (the image id itself stays) and trash the Dockerfile."""
    subprocess.run(["docker", "rmi", pin_tag], capture_output=True)
    _trash(buildfile)


def build_for_manifest(manifest_or_path, log=print):
    """Build (or adopt from the registry) the image for ONE frozen manifest.

    This is the build entry point the build GATE calls, so the shell body can
    pin the same base prepare() pinned -- without it, 'docker build -f
    Dockerfile' inside the snapshot re-resolves the mutable FROM tag at build
    time, and a base retagged between freeze and build silently builds on the
    new base while the manifest reports the old one.

    Contract (deliberately narrow):
      * the manifest's identity is taken as GIVEN and VALIDATED, never
        re-resolved: no source re-fingerprint, no FROM-tag inspection. The ONLY
        docker reads are existence probes of the immutable ids the manifest
        names -- a live tag (authz:latest) is not consulted, because on a shared
        box that tag moves.
      * inside the build lock for this cache key, the registry is consulted
        first: a peer that built the same (fingerprint, base) wins and this
        call adopts its image (docker tag, no build).
      * the build itself pins FROM to a private tag bound to the manifest's
        build_base_id, so the built layers derive from exactly that base.
      * the registry row written here is the base EVIDENCE the run reports
        (ref, immutable id, cache key). A row for this fingerprint under a
        different base is not a collision -- the registry keeps the current
        (base, image) pair and registry_lookup already refused to reuse it --
        so this build overwrites the row, which is how a retagged base rotates.

    Accepts a manifest dict (validated by the caller's load path) or a path
    (load_manifest's full integrity rules apply). Returns
    {"image_id", "image_tag", "cache_key", "build_base_id", "built"}.
    """
    if isinstance(manifest_or_path, dict):
        manifest = manifest_or_path
    else:
        manifest = load_manifest(manifest_or_path)
    for field in ("fingerprint", "snapshot", "image_tag",
                  "build_base_id", "cache_key"):
        if not manifest.get(field):
            raise RuntimeError("build manifest is missing %r" % field)
    fp, snap = manifest["fingerprint"], manifest["snapshot"]
    base_id, gate_tag = manifest["build_base_id"], manifest["image_tag"]
    cache_key = manifest["cache_key"]
    if not _valid_snapshot(snap, fp):
        raise RuntimeError("build refuses snapshot %s: integrity validation failed"
                           % snap)
    with _gate_locks.FileLock(name="build-" + cache_key[:32]):
        entry = registry_lookup(fp, manifest.get("authz_id"), base_id)
        if entry:
            _ensure_tag(entry["image_id"], gate_tag)
            log("image cache hit %s (base %s)"
                % (entry["image_id"][:19], base_id[:19]))
            return {"image_id": entry["image_id"], "image_tag": gate_tag,
                    "cache_key": cache_key, "build_base_id": base_id,
                    "built": False}
        # A row for this fingerprint on a DIFFERENT base is not a collision: the
        # registry is keyed by fingerprint and holds the CURRENT (base, image)
        # pair, and registry_lookup already refused to reuse it. Building here
        # overwrites that row, which is exactly how a retagged base rotates.
        if not image_id(base_id):
            raise RuntimeError("manifest build base %s is not present in the daemon"
                               % base_id)
        base_ref = manifest.get("build_base_ref")
        if not base_ref:
            base_ref = dockerfile_base(snap)[0]
        t0 = time.time()
        buildfile, pin = immutable_buildfile(snap, base_ref, base_id)
        try:
            image = build_image(snap, gate_tag, buildfile)
        finally:
            release_build_pin(buildfile, pin)
        _registry_put(_registry_entry(manifest, image))
        _write_prepared(snap, dict(manifest, image_id=image))
        log("built %s on base %s in %.0fs"
            % (image[:19], base_id[:19], time.time() - t0))
        return {"image_id": image, "image_tag": gate_tag, "cache_key": cache_key,
                "build_base_id": base_id, "built": True}


def base_key(fingerprint, authz_id, build_base_id=None):
    """Cache key: source fingerprint + the base the build ACTUALLY ran on.

    build_base_id defaults to authz_id because that is the image the snapshot
    Dockerfile's FROM names. It is a separate field so a manifest can record
    the two identities apart, and the key is derived from the build base: a
    build on a newer base must never reuse an image made from an older one.
    """
    base = build_base_id or authz_id
    return hashlib.sha256((fingerprint + "\n" + base).encode()).hexdigest()


def gate_image_tag(fingerprint, authz_id, build_base_id=None):
    return "lua-router:gate-" + base_key(fingerprint, authz_id, build_base_id)[:24]


def _registry_path():
    return os.path.join(SNAPSHOT_ROOT, "registry.json")


def _registry_read(fingerprint):
    """The raw registry row for one fingerprint (no base filter, no liveness
    probe): the base evidence manifest_with_built_image validates a backfill
    against, and what a reader audits a reported identity against."""
    try:
        with open(_registry_path()) as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return None
    row = doc.get(fingerprint) if isinstance(doc, dict) else None
    return row if isinstance(row, dict) else None


def _registry_put(entry):
    """Record fingerprint -> image, under a dedicated flock.

    Two runs finishing a build at the same moment would otherwise read-
    modify-write the same document and drop each other's entry: a pid-named
    tmp file protects the file, not the merge.
    """
    with open(_registry_path() + ".lock", "a+") as meta:
        fcntl.flock(meta, fcntl.LOCK_EX)
        try:
            return _registry_put_locked(entry)
        finally:
            fcntl.flock(meta, fcntl.LOCK_UN)


def _registry_put_locked(entry):
    """Record fingerprint -> image in a registry keyed by both identities."""
    os.makedirs(SNAPSHOT_ROOT, exist_ok=True)
    path = _registry_path()
    doc = {}
    try:
        with open(path) as fh:
            doc = json.load(fh)
        if not isinstance(doc, dict):
            doc = {}
    except (OSError, ValueError):
        doc = {}
    doc[entry["fingerprint"]] = entry
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as fh:
        json.dump(doc, fh)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    return path


def registry_lookup(fingerprint, authz_id, build_base_id=None):
    """The recorded image for (fingerprint, build base), or None.

    The comparison is against the base the build ran on (build_base_id,
    defaulting to the FROM-resolved authz_id; a pre-schema-3 entry is read
    through its authz_id). An entry recorded on a different base is a MISS:
    reusing it would let a retagged authz:latest silently serve gates that
    report the new base id. The image must also still exist in the daemon.
    """
    try:
        with open(_registry_path()) as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return None
    entry = doc.get(fingerprint) if isinstance(doc, dict) else None
    if not isinstance(entry, dict):
        return None
    entry_base = entry.get("build_base_id") or entry.get("authz_id")
    if entry_base != (build_base_id or authz_id):
        return None
    image = entry.get("image_id")
    if not image:
        return None
    return entry if image_id(image) else None


def _materialise_snapshot(repo, fp, dest):
    """Copy the gate-visible paths into dest and verify the copy against the
    manifest it is named for. The fingerprint is taken from this copy, so what
    a gate mounts is exactly what was hashed: no 'hash the live tree, then copy
    a tree that moved in between' window."""
    _assert_no_source_symlinks(repo)
    os.makedirs(dest)
    for rel in SNAPSHOT_PATHS:
        src = os.path.join(repo, rel)
        if os.path.isfile(src):
            if snapshot_excluded(rel):
                continue
            shutil.copy2(src, os.path.join(dest, rel))
        elif os.path.isdir(src):
            shutil.copytree(src, os.path.join(dest, rel), symlinks=False,
                            ignore=_copy_ignore(rel))
    _prune_excluded(dest)
    _assert_no_symlinks(dest)
    return dest


def _assert_no_source_symlinks(repo):
    """Refuse a live tree whose gate-visible paths contain a symlink.

    copytree(symlinks=False) copies a linked DIRECTORY as a real one, which is
    how a link back into the live tree (or a link cycle) would be baked into a
    snapshot the manifest claims is closed. Refusing the source is the only
    safe half of the rule; the post-copy check catches the rest.
    """
    for rel in SNAPSHOT_PATHS:
        root = os.path.join(repo, rel)
        if os.path.islink(root):
            raise RuntimeError("snapshot source is a symlink: %s" % root)
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
            for name in list(dirnames) + filenames:
                full = os.path.join(dirpath, name)
                if os.path.islink(full):
                    raise RuntimeError("snapshot source contains a symlink: %s"
                                       % full)


def _assert_no_symlinks(dest):
    """A snapshot is a closed tree: nothing inside it may resolve to a path
    outside the snapshot, and a link is the only way that happens."""
    for dirpath, dirnames, filenames in os.walk(dest):
        for name in list(dirnames) + filenames:
            if os.path.islink(os.path.join(dirpath, name)):
                raise RuntimeError("snapshot contains a symlink: %s"
                                   % os.path.join(dirpath, name))


def _prune_excluded(dest):
    for rel in sorted(SNAPSHOT_EXCLUDED_FILES):
        victim = os.path.join(dest, rel)
        if os.path.isfile(victim):
            os.unlink(victim)


def _fingerprint_of_copy(dest, repo, paths=SNAPSHOT_PATHS):
    """Fingerprint computed FROM the copy, with the tree layout of repo.

    Paths are the ones the suites address as repo-relative, and the digest is
    the same function the manifest uses, so 'snapshot == fingerprint' is a
    verified property of the published directory, not a claim.
    """
    rows = []
    for rel in paths:
        root = os.path.join(dest, rel)
        if os.path.isfile(root):
            rows.append((rel, _sha256_file(root)))
        elif os.path.isdir(root):
            for dirpath, dirnames, filenames in os.walk(root):
                dirnames[:] = sorted(
                    d for d in dirnames
                    if not snapshot_excluded(
                        os.path.relpath(os.path.join(dirpath, d), dest)))
                for fn in sorted(filenames):
                    full = os.path.join(dirpath, fn)
                    rel = os.path.relpath(full, dest)
                    if snapshot_excluded(rel):
                        continue
                    rows.append((rel, _sha256_file(full)))
    rows.sort()
    digest = hashlib.sha256()
    for rel, sha in rows:
        digest.update(("%s %s\n" % (rel, sha)).encode())
    return {"fingerprint": digest.hexdigest(), "files": len(rows),
            "manifest": [{"path": rel, "sha256": sha} for rel, sha in rows]}


def _publish_snapshot(repo, fp):
    """Content-addressed publish: copy to a UNIQUE temp dir, fingerprint the
    copy, and rename it onto its own digest. Two runners freezing the same tree
    race only on the rename, which is atomic; nobody deletes anybody's temp."""
    snap = os.path.join(SNAPSHOT_ROOT, fp["fingerprint"])
    os.makedirs(SNAPSHOT_ROOT, exist_ok=True)
    if _valid_snapshot(snap, fp["fingerprint"]):
        return snap
    # Serialised publish: the copy/verify/rename sequence is a read-modify-
    # write on a content-addressed store, and two runners publishing the same
    # digest at the same moment must not interleave their temp trees.
    with open(os.path.join(SNAPSHOT_ROOT, ".publish.lock"), "a+") as meta:
        fcntl.flock(meta, fcntl.LOCK_EX)
        try:
            if _valid_snapshot(snap, fp["fingerprint"]):
                return snap          # the peer that held the lock published it
            return _publish_snapshot_locked(repo, fp, snap)
        finally:
            fcntl.flock(meta, fcntl.LOCK_UN)


def _publish_snapshot_locked(repo, fp, snap):
    tmp = os.path.join(SNAPSHOT_ROOT,
                       ".tmp-" + fp["fingerprint"][:12] + "-" + secrets.token_hex(6))
    try:
        for attempt in range(max(1, SNAPSHOT_RETRIES)):
            before = source_fingerprint(repo)
            if before["fingerprint"] != fp["fingerprint"]:
                fp = before
                snap = os.path.join(SNAPSHOT_ROOT, fp["fingerprint"])
                if _valid_snapshot(snap, fp["fingerprint"]):
                    return snap
            _materialise_snapshot(repo, fp, tmp)
            copied = _fingerprint_of_copy(tmp, repo)
            after = source_fingerprint(repo)
            if (before["fingerprint"] != after["fingerprint"]
                    or copied["fingerprint"] != before["fingerprint"]):
                # Reject this tree: the copy is not the digest we meant to
                # publish. Nothing is renamed, the temp goes to the trash, and
                # the next attempt re-hashes -- a moved tree can never be
                # published under the digest of the tree that existed before.
                _move_to_trash(tmp)
                if attempt + 1 == max(1, SNAPSHOT_RETRIES):
                    raise RuntimeError("source changed during snapshot copy; retries exhausted")
                tmp = os.path.join(SNAPSHOT_ROOT,
                                   ".tmp-" + after["fingerprint"][:12]
                                   + "-" + secrets.token_hex(6))
                fp = after
                snap = os.path.join(SNAPSHOT_ROOT, fp["fingerprint"])
                if _valid_snapshot(snap, fp["fingerprint"]):
                    return snap
                continue
            os.makedirs(os.path.join(tmp, ".gate"), exist_ok=True)
            _atomic_json(os.path.join(tmp, ".gate", "manifest.json"), copied)
            with open(os.path.join(tmp, ".ready"), "w") as fh:
                fh.write(copied["fingerprint"] + "\n")
                fh.flush(); os.fsync(fh.fileno())
            if os.path.exists(snap):
                if not _valid_snapshot(snap, fp["fingerprint"]):
                    _move_to_trash(snap)
                else:
                    _move_to_trash(tmp)
                    return snap
            os.rename(tmp, snap)
            if not _valid_snapshot(snap, fp["fingerprint"]):
                raise RuntimeError("published snapshot failed integrity validation")
            return snap
    except Exception:
        if os.path.exists(tmp):
            _move_to_trash(tmp)
        raise
    raise RuntimeError("could not publish source snapshot")


def _atomic_json(path, value):
    tmp = path + ".part." + secrets.token_hex(6)
    with open(tmp, "w") as fh:
        json.dump(value, fh, sort_keys=True)
        fh.flush(); os.fsync(fh.fileno())
    os.replace(tmp, path)


def _valid_snapshot(snap, expected):
    try:
        with open(os.path.join(snap, ".ready")) as fh:
            if fh.read().strip() != expected:
                return False
        with open(os.path.join(snap, ".gate", "manifest.json")) as fh:
            recorded = json.load(fh)
        actual = _fingerprint_of_copy(snap, REPO)
        return recorded == actual and actual["fingerprint"] == expected
    except (OSError, ValueError, RuntimeError):
        return False


def _move_to_trash(path):
    if not os.path.exists(path):
        return
    trash = "/data/.trash"
    os.makedirs(trash, exist_ok=True)
    target = os.path.join(trash, "lr-gate-" + os.path.basename(path) + "-" + secrets.token_hex(4))
    os.rename(path, target)


def _trash(path):
    """Move a temporary file into the required trash; never unlink it."""
    if os.path.exists(path):
        _move_to_trash(path)


def _base_ids(authz, resty):
    authz_id, resty_id = image_id(authz), image_id(resty)
    if not authz_id:
        raise RuntimeError("image %s is not present (conf/unit/contract need it)" % authz)
    if not resty_id:
        raise RuntimeError("image %s is not present (resty unit runs need it)" % resty)
    return authz_id, resty_id


def _resolve(repo, tag, authz, resty):
    """Shared front half of prepare/freeze: one fingerprint, one publish, one
    registry lookup. Both entry points go through here so their identity rules
    cannot drift: freeze never re-hashes a second tree, prepare never builds
    against a base the manifest does not name."""
    requested_tag = tag or os.environ.get("LR_IMAGE", "lua-router:integration")
    authz = authz or os.environ.get("OPENRESTY_TEST_IMAGE", "authz:latest")
    resty = resty or os.environ.get("LR_RESTY_IMAGE", "apache/apisix:3.11.0-debian")
    authz_id, resty_id = _base_ids(authz, resty)
    fp = source_fingerprint(repo)
    snap = _publish_snapshot(repo, fp)
    # Re-derive identity from the published copy: a concurrent edit that landed
    # between hashing and publishing is resolved HERE, not silently shipped.
    fp = _published_fingerprint(snap, fp)
    # The build base is what the snapshot's own Dockerfile names -- not the test
    # image in OPENRESTY_TEST_IMAGE. Both go in the manifest: the build key takes
    # the FROM id, the test environment keeps its own ref/id.
    build_base_ref, build_base_id = dockerfile_base(snap)
    gate_tag = gate_image_tag(fp["fingerprint"], authz_id, build_base_id)
    entry = registry_lookup(fp["fingerprint"], authz_id, build_base_id)
    return {"schema": 3, "fingerprint": fp["fingerprint"], "files": fp["files"],
            "snapshot": snap, "repo": repo,
            "image_tag": gate_tag, "requested_tag": requested_tag,
            "image_id": entry["image_id"] if entry else None,
            "authz_ref": authz, "authz_id": authz_id,
            "build_base_ref": build_base_ref, "build_base_id": build_base_id,
            "cache_key": base_key(fp["fingerprint"], authz_id, build_base_id),
            "resty_ref": resty, "resty_id": resty_id,
            "prepared": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}


def prepare(repo=REPO, tag=None, authz=None, resty=None, log=print):
    """Freeze the tree, build the image for (fingerprint, build base id), and
    write the manifest.

    The image cache is keyed by source fingerprint AND the immutable base the
    build ran on: authz:latest is a mutable tag, and reusing an image built on
    an older base while reporting the new id is exactly the mixed-version lie
    the results layer refuses. Resty is recorded as the unit-gate environment
    identity; it is not a Dockerfile base and must not key the build.
    """
    manifest = _resolve(repo, tag, authz, resty)
    snap = manifest["snapshot"]
    build_base_id = manifest["build_base_id"]
    gate_tag = manifest["image_tag"]
    image = manifest["image_id"]
    if image:
        log("image cache hit %s (base %s)" % (image[:19], build_base_id[:19]))
        _ensure_tag(image, gate_tag)
    else:
        # One shared build path with the build GATE: same cache-key lock, same
        # registry-first adoption, same pinned FROM. Two concurrent prepares of
        # one tree build once; the loser adopts the winner's registry entry.
        built = build_for_manifest(manifest, log=log)
        manifest["image_id"] = built["image_id"]
    _write_prepared(snap, manifest)
    return manifest


def freeze(repo=REPO, tag=None, authz=None, resty=None):
    """Freeze source and resolve base image IDs without building lua-router.

    The run path uses this so conf/unit/contract/probes start while the build
    GATE runs; prepare() is the same resolve plus a build, for reuse by later
    group runs. The image tag is the fingerprint+base derived tag prepare()
    uses, and a recorded image is honoured only when its build base matches the
    base this run resolved. One shared core (_resolve) computes both, so the two
    entry points cannot report a different identity for one tree.
    """
    manifest = _resolve(repo, tag, authz, resty)
    if manifest["image_id"]:
        # Cache hit: re-tag the already-built image (a daemon metadata write,
        # not a build), so the image gates run on what prepare() would have
        # produced and the run still executes every gate.
        _ensure_tag(manifest["image_id"], manifest["image_tag"])
    return manifest


def _registry_entry(manifest, image_id_value):
    """The registry row for a manifest, carrying the base identities the cache
    key is built from so a later lookup can audit what the image was built on."""
    return {"fingerprint": manifest["fingerprint"],
            "authz_id": manifest.get("authz_id"),
            "build_base_ref": manifest.get("build_base_ref"),
            "build_base_id": manifest.get("build_base_id"),
            "cache_key": manifest.get("cache_key"),
            "resty_id": manifest.get("resty_id"),
            "image_id": image_id_value, "tag": manifest["image_tag"],
            "built": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}


def _ensure_tag(image, tag):
    """Point the derived tag at an already-built immutable image id.

    docker tag is a daemon metadata write, not a base-changing operation: it
    re-points a name at an existing content-addressed image. It is idempotent
    and safe to run concurrently; a build, by contrast, writes to the layer
    cache for this key and is serialized by the build lock.
    """
    subprocess.run(["docker", "tag", image, tag], capture_output=True)


def _published_fingerprint(snap, fallback):
    path = os.path.join(snap, ".gate", "manifest.json")
    try:
        with open(path) as fh:
            doc = json.load(fh)
        if doc.get("fingerprint"):
            return doc
    except (OSError, ValueError):
        pass
    return fallback


def _write_prepared(snap, manifest):
    """Atomically record the run identity next to the snapshot it describes."""
    _atomic_json(os.path.join(snap, ".gate", "prepared.json"), manifest)


def manifest_with_built_image(manifest):
    """Record the image the build GATE produced, and make it reusable.

    Reuse covers PREPARATION only: the build GATE runs on every run, so a run
    never inherits a PASS from an earlier one. What is reused is the artifact --
    docker's layer cache makes the build a few seconds, and a later prepare()
    skips it entirely -- and the identity (fingerprint -> immutable image id) is
    written down so a manifest can be handed to --manifest / --aggregate.
    """
    iid = image_id(manifest["image_tag"])
    if not iid:
        raise RuntimeError("build gate reported success but %s has no image id"
                           % manifest["image_tag"])
    manifest = dict(manifest)
    manifest["image_id"] = iid
    # The base identity is EVIDENCE, not a claim the writer can fill in: the
    # registry row that build_for_manifest wrote during this build is the proof
    # of what base the layers derive from. A manifest that disagrees with that
    # row (or has no row: the gate built without the pin helper) certifies
    # nothing, and saying so here is what stops a run reporting an image built
    # on a base it never pinned.
    if not manifest.get("build_base_id"):
        raise RuntimeError("manifest names no build base: it cannot certify an image")
    row = _registry_read(manifest["fingerprint"])
    if not row:
        raise RuntimeError(
            "no registry row for fingerprint %s: the build gate did not record "
            "a base-pinned build, so this image has no base evidence"
            % manifest["fingerprint"][:12])
    row_base = row.get("build_base_id") or row.get("authz_id")
    if row_base != manifest["build_base_id"]:
        raise RuntimeError("registry base evidence %s != manifest build base %s"
                           % (row_base, manifest["build_base_id"]))
    if row.get("tag") and row["tag"] != manifest["image_tag"]:
        raise RuntimeError("registry tag evidence %s != manifest image_tag %s"
                           % (row["tag"], manifest["image_tag"]))
    if not manifest.get("cache_key"):
        manifest["cache_key"] = base_key(manifest["fingerprint"],
                                         manifest.get("authz_id"),
                                         manifest.get("build_base_id"))
    _registry_put(_registry_entry(manifest, iid))
    _write_prepared(manifest["snapshot"], manifest)
    return manifest


def _manifest_required(manifest):
    """(ok, problem): the fields a manifest must name, and the snapshot marker.

    A manifest that points at a tree which is not there, or whose .ready digest
    is not the fingerprint the manifest carries, certifies nothing: it is the
    same forged-ready shape the publish path refuses to write.
    """
    for field in ("schema", "fingerprint", "snapshot", "image_tag", "authz_id",
                  "build_base_id"):
        if not manifest.get(field):
            return False, "manifest is missing %r" % field
    snap = manifest["snapshot"]
    if not os.path.isdir(snap):
        return False, "snapshot directory %s does not exist" % snap
    try:
        with open(os.path.join(snap, ".ready")) as fh:
            if fh.read().strip() != manifest["fingerprint"]:
                return False, "snapshot .ready does not match manifest fingerprint"
    except OSError as exc:
        return False, "snapshot .ready unreadable: %s" % exc
    return True, ""


def _verify_images(manifest):
    """Every image the manifest names must exist, and the build base with it.

    A manifest that points at a deleted image cannot be a run identity: the gate
    bodies would run against a tag the daemon resolves to nothing, and the
    report would claim an artifact that is not on the machine.
    """
    base = manifest.get("build_base_id")
    if base and not image_id(base):
        return False, "build base %s is not present in the daemon" % base
    for field in ("image_id", "authz_id", "resty_id"):
        value = manifest.get(field)
        if value and not image_id(value):
            return False, "%s %s is not present in the daemon" % (field, value)
    tag = manifest.get("image_tag")
    if tag and manifest.get("image_id") and image_id(tag) != manifest["image_id"]:
        return False, "image tag %s does not resolve to the manifest image id" % tag
    return True, ""


def _verify_snapshot(manifest):
    """Re-hash the snapshot on disk and compare it to the manifest identity.

    Same integrity function the publish path used, so a snapshot that was
    edited, partially deleted, or assembled by hand after publication cannot be
    loaded as a trustworthy run identity.
    """
    snap = manifest["snapshot"]
    try:
        recorded = _published_fingerprint(snap, None)
        if not recorded:
            return False, "snapshot %s has no .gate/manifest.json" % snap
        actual = _fingerprint_of_copy(snap, REPO)
        if recorded != actual:
            return False, "snapshot manifest does not match the files on disk"
        if actual["fingerprint"] != manifest["fingerprint"]:
            return False, "snapshot digest %s != manifest %s" % (
                actual["fingerprint"][:12], manifest["fingerprint"][:12])
    except (OSError, ValueError, RuntimeError) as exc:
        return False, str(exc)
    return True, ""


def load_manifest(path, verify=True):
    """Read and validate a manifest; refuse a snapshot whose digest drifted.

    A manifest is the run's identity: it pins the source fingerprint, the base
    image, and the image tag every gate body runs against, so loading one is not
    a parse step. Set verify=False only to inspect a manifest for forensics; the
    dict then carries _verify_problem and nothing enforces it.
    """
    with open(path) as fh:
        manifest = json.load(fh)
    if not isinstance(manifest, dict):
        raise RuntimeError("manifest %s is not a json object" % path)
    ok, problem = _manifest_required(manifest)
    if ok:
        ok, problem = _verify_snapshot(manifest)
        if ok:
            ok, problem = _verify_images(manifest)
    if not ok:
        if not verify:
            quiet = dict(manifest)
            quiet["_verify_problem"] = problem
            return quiet
        raise RuntimeError("refusing manifest %s: %s" % (path, problem))
    return manifest


def sanitize_namespace(value, limit=64):
    """The container-name/label alphabet, applied to a runner namespace."""
    return re.sub(r"[^A-Za-z0-9_.-]", "", value)[:limit]


def container_namespace(run_id):
    """The run-level label value: one namespace per run, shared by its gates.

    The suites stamp it on every container they start (test/integration/_lib.py
    _label_args, test_lua_router.sh LR_LABEL_ARGS), which is what lets the
    runner sweep strays by exact label match. Name-suffix matching is only ever
    a fallback: mesh_two spells its containers lr-mesh2a-<pid>, so a pid-suffix
    rule would miss them, and a cross-run concurrent verify once left ten
    mesh2a containers behind a cleanup that trusted the name.
    """
    return sanitize_namespace("run-" + run_id)


RUN_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def _claim_run_dir(parent, run_id):
    """Atomically claim runs/<run-id>: os.mkdir fails if the tree exists.

    Two runners naming one run id must not share a directory tree: the second
    would overwrite the first's logs and results, and the first's cleanup (a
    label sweep on the shared namespace) would kill the second's containers.
    mkdir is the claim -- no read-then-write window, no suffix laundering that
    quietly moves one run's evidence into a directory nobody asked for.
    """
    os.makedirs(parent, exist_ok=True)
    root = os.path.join(parent, run_id)
    os.mkdir(root)
    return root


def gate_tag_of(gate):
    """The label value the suites stamp for a gate: the same sanitisation
    _lib.py applies to LR_GATE_TAG, computed here so the sweep filter matches
    the label the suite wrote, not a paraphrase of it."""
    return sanitize_namespace(gate.name.replace("_", "-").lower(), 14)


def gate_namespace(run_id, gate, secret="lr-runner"):
    """Stable per-(run, gate) token: the exact-sweep key recorded in each result.

    sha256 over a domain-separating prefix, so the value cannot be forged from
    a bare concatenation, truncated to 16 hex chars so it fits a label.
    """
    digest = hashlib.sha256((secret + "\0" + run_id + "\0" + gate).encode()).hexdigest()
    return digest[:16]


def _run_garbage(run_id, namespaces):
    """Remove every lr-* container labelled with one of these run namespaces.

    Exact label match (docker --filter label= is equality), never a name glob,
    and never a global lr- sweep: a concurrent run's containers carry a
    different namespace value and are outside the filter.
    """
    targets = []
    for ns in sorted(n for n in namespaces if n):
        r = subprocess.run(["docker", "ps", "-aq",
                            "--filter", "label=lr-runner.namespace=" + ns,
                            "--filter", "name=lr-"],
                           capture_output=True)
        targets += [t for t in r.stdout.decode().split() if t]
    targets = sorted(set(targets))
    if targets:
        subprocess.run(["docker", "rm", "-f", *targets], capture_output=True)
    return targets


class RunContext:
    """Per-run identity: dirs, env, child bookkeeping, and exact cleanup."""

    def __init__(self, manifest, run_id=None, log_dir=None, keep_tmp=False,
                 groups=None):
        self.manifest = manifest
        # A UI-only selection narrows the shared unit gate to the node UI badge
        # test (LR_GATE_UI_ONLY below): group selection has to be real, not a
        # label that quietly runs the whole tree anyway.
        self.ui_only = bool(groups) and set(groups) == {"ui"}
        # An explicit run id is a CLAIM, not a hint: it names a run, so the
        # alphabet is the container-label-safe set, and a tree that exists is
        # an error. Silently suffixing (the old rule) let one run write into
        # "myname-2" while the caller's --manifest/--results bookkeeping still
        # pointed at "myname" -- evidence and its filename disagreeing is the
        # same mixed-version shape the results layer refuses. A generated id
        # (the default) is unique per RunContext object, not per process+second,
        # and retries on the (astronomically unlikely) collision.
        parent = os.path.join(log_dir or BASE, "runs")
        # Only None generates. An empty string is a CLAIM on the empty name --
        # it would name runs/"" (a dotdir-shaped tree every listing tool hides),
        # and a caller that meant "generate" must pass None, not "". A runner
        # that parses --run-id into "" normalises to None at ITS boundary; the
        # identity layer refuses to launder the difference.
        if run_id is not None:
            if not RUN_ID_RE.match(run_id):
                raise RuntimeError(
                    "run id %r is not safe: use 1-64 chars of [A-Za-z0-9_-]"
                    % run_id)
            self.run_id = run_id
            try:
                root = _claim_run_dir(parent, self.run_id)
            except FileExistsError:
                raise RuntimeError(
                    "run id %r is already claimed at %s; start the run with a "
                    "new --run-id (runs are never reused or suffixed)"
                    % (run_id, os.path.join(parent, run_id)))
        else:
            root = None
            for _attempt in range(64):
                candidate = (time.strftime("%Y%m%d-%H%M%S", time.gmtime())
                             + "-%d-%04x" % (os.getpid(), _uniq())
                             + "-" + secrets.token_hex(3))
                try:
                    root = _claim_run_dir(parent, candidate)
                except FileExistsError:
                    continue
                self.run_id = candidate
                break
            if root is None:
                raise RuntimeError("could not claim a unique run directory")
        self.root = root
        # The namespace is derived from the FINAL claimed id, exactly once: a
        # renamed run must not carry the label of the id it was going to use,
        # because cleanup sweeps by that label.
        self.namespace = container_namespace(self.run_id)
        self.log_dir = os.path.join(root, "logs")
        self.result_dir = os.path.join(root, "results")
        self.tmp = os.path.join(root, "tmp")
        for d in (self.log_dir, self.result_dir, self.tmp):
            os.makedirs(d, exist_ok=True)
        self.log_path = os.path.join(root, "gates.log")
        self.keep_tmp = keep_tmp
        # The manifest this run's gate bodies build against, on disk the moment
        # the run starts: the build GATE calls
        # `python3 test/gates/context.py build --manifest $LR_GATE_MANIFEST`
        # so the shell body builds on the base THIS manifest pins, never on a
        # live tag. Written atomically; bodies treat it as read-only.
        self.manifest_path = os.path.join(root, "gate-manifest.json")
        _atomic_json(self.manifest_path, manifest)
        self.children = []
        self.removed = []
        self.swept = set()
        self._cleaned = False
        self._install_signals()

    # -- env ---------------------------------------------------------------
    def gate_env(self, gate):
        """Environment for one gate body: run-scoped, gate-namespaced, ledger shared."""
        m = self.manifest
        env = dict(os.environ)
        env["LR_RUN_ID"] = self.run_id
        env["LR_GATE_TAG"] = gate.name.replace("_", "-")[:14]
        env["LR_TEST_TMP"] = os.path.join(self.tmp, gate.name)
        env["LR_GATE_LOG"] = self.log_path
        env["LR_RESULT_DIR"] = self.result_dir
        # The labels the suites stamp and the sweep filters on. Inject the
        # sanitised value itself: the suites write the label from this string
        # verbatim, so runner and harness cannot drift by a character.
        env["LR_CONTAINER_NAMESPACE"] = self.namespace
        env["LR_GATE_NAMESPACE"] = gate_namespace(self.run_id, gate.name)
        env["LR_GATE_LABEL"] = gate_tag_of(gate)
        # Read at call time: a caller (or the shell entry) may point the run at a
        # different ledger, and every gate of one run must share it.
        env["LR_PORT_RESERVE"] = (os.environ.get("LR_PORT_RESERVE")
                                  or m.get("port_ledger") or LEDGER)
        # The gate bodies get the RESOLVED image id, not the derived tag: the
        # tag is a cache handle any later build can re-point, and a suite that
        # resolves it at docker-run time can land on an image the run never
        # verified. The build gate is the exception -- it is the gate that
        # PRODUCES this run's image, so it must keep the tag it builds and
        # tags. Before the build gate runs there is no id to hand out, and
        # every image-booting gate depends on build, so no other body ever
        # sees the None branch.
        env["LR_IMAGE"] = (m["image_tag"] if gate.name == "build"
                           else m.get("image_id") or m["image_tag"])
        env["LR_GATE_MANIFEST"] = self.manifest_path
        # Bodies get the manifest's RESOLVED ids, not the requested refs:
        # authz:latest is a mutable tag, and a run whose containers re-resolve
        # it at docker-run time can silently land on a retagged base while the
        # results bind the old digest. An id is its own proof of existence and
        # cannot move under a running gate. The fallback to ref only fires for
        # legacy manifests that carry no id for that slot, and keeps gate_env
        # from injecting a None into the subprocess environment.
        env["OPENRESTY_TEST_IMAGE"] = m.get("authz_id") or m["authz_ref"]
        env["LR_RESTY_IMAGE"] = m.get("resty_id") or m["resty_ref"]
        env["LR_BASE_IMAGE"] = m.get("authz_id") or m["authz_ref"]
        env["LR_REPO"] = m["snapshot"]
        if self.ui_only:
            env["LR_GATE_UI_ONLY"] = "1"
        os.makedirs(env["LR_TEST_TMP"], exist_ok=True)
        return env

    def gate_namespace(self, gate):
        """The exact label pair this gate's containers carry.

        Returned as the (namespace, gate) filter pair; the value stored in the
        result record is the joined form, so a report line says exactly which
        containers the sweep keyed on.
        """
        return self.namespace + "/" + gate_tag_of(gate)

    def update_manifest(self, manifest):
        """Adopt the manifest the build GATE filled in (image_id + provenance).

        gate_env reads self.manifest at launch time, so every gate that starts
        AFTER the build must see the built image id, not the pending-build
        placeholder. The on-disk run manifest (self.manifest_path, which shell
        bodies pin their base from via build --manifest) is rewritten in the
        same breath, atomically: a gate env naming an id while the file it
        points at names none is the evidence/filename disagreement the run-id
        claim rule refuses. The context owns this file, so the scheduler calls
        through here instead of writing it itself.
        """
        self.manifest = manifest
        _atomic_json(self.manifest_path, manifest)

    def sweep_gate(self, gate, grace=1.0):
        """Remove containers labelled namespace=<run ns> and gate=<gate tag>.

        The suite gets grace seconds to reap its own children first (its EXIT
        trap is the normal path); only strays are removed. Exact label equality,
        so a peer run is untouchable.
        """
        time.sleep(grace)
        r = subprocess.run(["docker", "ps", "-aq",
                            "--filter", "label=lr-runner.namespace=" + self.namespace,
                            "--filter", "label=lr-runner.gate=" + gate_tag_of(gate)],
                           capture_output=True)
        targets = sorted(set(t for t in r.stdout.decode().split() if t))
        if targets:
            subprocess.run(["docker", "rm", "-f", *targets], capture_output=True)
        with _CHILD_LOCK:
            self.swept.update(targets)
        return targets

    # -- children ----------------------------------------------------------
    def register_child(self, proc):
        """Track a gate body so an interrupted run can stop exactly its own work.

        Without this list the abort path has no pids to kill, and containers
        outlive a suite whose parent died mid-suite: the docker daemon owns them,
        not the process group.
        """
        with _CHILD_LOCK:
            self.children.append(proc)

    def unregister_child(self, proc):
        with _CHILD_LOCK:
            self.children = [p for p in self.children if p is not proc]

    def child_pids(self):
        with _CHILD_LOCK:
            return [p.pid for p in self.children]

    # -- cleanup -----------------------------------------------------------
    def _install_signals(self):
        def handler(signum, _frame):
            self.abort("signal %s" % signum)
            raise SystemExit(130)
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                signal.signal(sig, handler)
            except (ValueError, OSError):
                pass
        # An exception that escapes the runner must not leave containers behind
        # either. atexit runs on normal exit too; cleanup is idempotent.
        atexit.register(self.cleanup)

    def kill_children(self, grace=1.0):
        """SIGTERM every tracked process group, wait grace, SIGKILL the rest.

        Same contract the suites use for their own mocks, so a killed gate tears
        down its docker children the same way the suite would.
        """
        pids = self.child_pids()
        for pid in pids:
            _signal_group(pid, signal.SIGTERM)
        deadline = time.time() + grace
        alive = [p for p in pids if _group_alive(p)]
        while alive and time.time() < deadline:
            time.sleep(0.1)
            alive = [p for p in alive if _group_alive(p)]
        for pid in alive:
            _signal_group(pid, signal.SIGKILL)
        return pids

    def cleanup_containers(self):
        return _run_garbage(self.run_id, [self.namespace])

    def cleanup(self):
        """Idempotent: kill this run's children, then sweep its namespace."""
        if self._cleaned:
            return self.removed
        self._cleaned = True
        self.kill_children()
        self.removed = self.cleanup_containers()
        return self.removed

    def abort(self, reason=""):
        self.cleanup()

    def remove_containers(self, pids=()):
        """Label sweep first; pid-suffix names only as the fallback."""
        targets = self.cleanup_containers()
        if pids:
            targets = sorted(set(targets) | set(_by_pid_suffix(pids)))
            if targets:
                subprocess.run(["docker", "rm", "-f", *targets], capture_output=True)
        return targets

    def summary(self, text):
        with open(self.log_path, "a") as fh:
            fh.write(text.rstrip("\n") + "\n")


_CHILD_LOCK = threading.Lock()


def _signal_group(pid, sig):
    try:
        os.killpg(pid, sig)
    except OSError:
        try:
            os.kill(pid, sig)
        except OSError:
            pass


def _group_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _by_pid_suffix(pids):
    owners = set(str(p) for p in pids)
    r = subprocess.run(["docker", "ps", "-a", "--format", "{{.ID}} {{.Names}}"],
                       capture_output=True)
    out = []
    for line in r.stdout.decode().splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        cid, name = parts
        if name.startswith("lr-") and name.rsplit("-", 1)[-1] in owners:
            out.append(cid)
    if out:
        subprocess.run(["docker", "rm", "-f", *out], capture_output=True)
    return out


def tail(path, n=25):
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - 64 * 1024))
            lines = fh.read().decode("utf-8", "replace").splitlines()
        return lines[-n:]
    except OSError:
        return ["<no log>"]


def cli_main(argv):
    """Module CLI. `build --manifest PATH` is the build GATE's entry point:
    it calls build_for_manifest, so a shell body (test/final_gates.sh gate_build)
    can pin the run's base without re-implementing any of this. Bare invocation
    keeps the historical behavior: prepare the current tree and print it."""
    if argv[:2] == ["build", "--manifest"]:
        if len(argv) < 3:
            print("build --manifest needs a path", file=sys.stderr)
            return 2
        out = build_for_manifest(argv[2])
        print(json.dumps(out, indent=2, sort_keys=True))
        return 0
    print(json.dumps(prepare(log=lambda *a: None), indent=2, sort_keys=True)[:2000])
    return 0


if __name__ == "__main__":
    sys.exit(cli_main(sys.argv[1:]))
