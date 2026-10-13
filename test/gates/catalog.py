#!/usr/bin/env python3
"""The 22 logical gates: group, tier, locks, dependencies, timeouts.

Groups are the selection dimension requested on 2026-10-12: cover base / config
/ routing / observability / discovery / mesh / tls independently, instead of the
two historical tiers only. Tiers keep their exact meaning: quick = build conf
unit contract probes; full = all 22.

Locks replace the hard-coded phase tables of the old script:
  obs:shared       ordinary HTTP gates. They share the machine and coordinate
                   through the shared port ledger plus per-run namespaces.
  build:exclusive  the image build: an independent prepare lock. conf/unit/
                   contract/probes never wait for it; the e2e gates wait for the
                   build GATE (a dependency edge), not for a phase barrier.

  e2e_watcher declares NO lock. It used to be the one gate that had to own the
  machine: it snapshots the host port table over docker.sock (e2e_watcher.py:507,
  :862), and any publish appearing after that snapshot is an unaccounted port
  that turns its "exactly one worker" assertions red for an unrelated reason.
  That hazard is now removed suite-side instead of by scheduling: the snapshot
  ships test/integration/docker_test_proxy.py, which filters socket events down to
  this run's fixture containers while preserving the raw port fields, and
  e2e_watcher.py starts it via docker_test_proxy.socket_path_for. A lock would
  be scheduling paying for a problem the harness already fixed.

Why mesh_two and e2e_tls_chain joined the shared pool (audited 2026-10-12,
measured, not assumed): the Lua mesh is a static peer list with no gossip
discovery (mesh/crdt.lua: a statically configured all-to-peer list), so a
foreign router structurally cannot join a roster; and the "31337 listener" of
e2e_tls_chain is an "openresty -t" config render that never binds. What both
gates need is wall-clock fidelity, which is exactly what the per-gate durations
in the result JSON report.
"""

BASE = "base"
CONFIG = "config"
ROUTING = "routing"
OBSERVABILITY = "observability"
DISCOVERY = "discovery"
MESH = "mesh"
TLS = "tls"
UI = "ui"
GROUPS = (UI, BASE, CONFIG, ROUTING, OBSERVABILITY, DISCOVERY, MESH, TLS)

OBS_SHARED = ("obs:shared",)
OBS_EXCLUSIVE = ("obs:exclusive",)
BUILD_LOCK = ("build:exclusive",)


class Gate:
    def __init__(self, name, group, timeout, locks, quick=False, depends=(),
                 needs_image=False, note="", groups=None):
        self.name = name
        self.groups = tuple(groups or (group,))
        self.group = self.groups[0]          # first label retained for old summaries
        # Wall-clock ceiling for the whole body. Bodies that carry their own
        # `timeout N` get N + 120 here, so the inner, better-instrumented
        # timeout always fires first (rc=124) and the outer one only catches a
        # suite that hangs past its own budget.
        self.timeout = timeout
        self.locks = tuple(locks)
        self.quick = quick
        self.depends = tuple(depends)   # gate names that must be green first
        self.needs_image = needs_image  # boots the built image
        self.note = note


GATES = [
    # base: source tree, config render, wire contract
    Gate("build", BASE, 2400, BUILD_LOCK, quick=True,
         note="docker build from the frozen snapshot; every e2e gate depends on it"),
    Gate("conf", BASE, 300, OBS_SHARED, quick=True,
         note="openresty -t on both shipped configs; needs no built image"),
    Gate("unit", BASE, 2100, (), quick=True,
         note="luajit/resty/node pure unit runs; binds no host port",
         groups=(BASE, UI)),
    Gate("contract", BASE, 2520, OBS_SHARED, quick=True,
         note="test_lua_router.sh: the 24-section wire contract"),
    # config: declaration layer, knobs, persistence, advertisement
    Gate("probes", CONFIG, 2520, OBS_SHARED, quick=True,
         note="policy factory, config knobs, re_split, raw-JSON editor"),
    Gate("e2e_profiles", CONFIG, 1620, OBS_SHARED,
         note="virtual-model profiles, upstreams CRUD, config-file revival, self-heal"),
    Gate("e2e_models_advertisement", CONFIG, 1020, OBS_SHARED,
         note="the /v1/models advertisement shape over real HTTP"),
    Gate("e2e_token_accounting", CONFIG, 1020, OBS_SHARED,
         note="usage injection/strip, token counters, 400-fallback sticky"),
    # routing: policy behaviour, rewrites, capacity
    Gate("e2e_stateful", ROUTING, 2520, OBS_SHARED, note="stateful routing surface"),
    Gate("e2e_policies", ROUTING, 2520, OBS_SHARED, note="policy families over containers"),
    Gate("e2e_policy_parity", ROUTING, 1920, OBS_SHARED,
         note="prefix_hash/bucket/power_of_two/random parity (TOST equivalence)"),
    Gate("e2e_routing_dyn", ROUTING, 1020, OBS_SHARED,
         note="runtime policy switch with no restart"),
    Gate("e2e_caps", ROUTING, 1020, OBS_SHARED,
         note="alias binding, concurrency/GPU caps, pool-full 503"),
    Gate("e2e_effort", ROUTING, 2520, OBS_SHARED,
         note="effort layers + entry declarations; the runner takes no lock for it"),
    Gate("e2e_errors", ROUTING, 2520, OBS_SHARED, note="error shapes on the wire"),
    # observability
    Gate("e2e_gpu_load", OBSERVABILITY, 1020, OBS_SHARED,
         note="metrics/prom load sources into the registry"),
    Gate("e2e_ui_bridge", OBSERVABILITY, 2520, OBS_SHARED, note="UI bridge endpoints",
         groups=(UI, OBSERVABILITY)),
    Gate("head_routes", OBSERVABILITY, 1020, OBS_SHARED,
         note="HEAD mirror of the GET surface"),
    # discovery
    Gate("e2e_watcher", DISCOVERY, 1020, (),
         note="in-process watcher over docker.sock; the test-side socket proxy"
              " (docker_test_proxy.py) filters events to this run's fixture"
              " containers and preserves the raw port fields, which is why this"
              " gate pools lock-free"),
    # mesh
    Gate("mesh_http", MESH, 1020, OBS_SHARED, note="mesh enabled over real HTTP"),
    Gate("mesh_two", MESH, 1020, OBS_SHARED,
         note="two real routers: converge, stability, partition, heal, retire"),
    # tls
    Gate("e2e_tls_chain", TLS, 1620, OBS_SHARED,
         note="server-side TLS PKI; the 31337 scenario renders a config, never binds"),
]

BY_NAME = dict((g.name, g) for g in GATES)
# The historical run order, pinned: a green log's gate sequence is part of the
# contract, so grouping must never reshuffle it. Group membership is an
# attribute, not a sort key.
HISTORICAL_ORDER = ["build", "conf", "unit", "contract", "probes",
                    "e2e_stateful", "e2e_policies", "e2e_ui_bridge", "e2e_errors",
                    "e2e_effort", "head_routes", "mesh_http", "e2e_policy_parity",
                    "e2e_watcher", "e2e_token_accounting", "e2e_gpu_load",
                    "e2e_routing_dyn", "e2e_profiles", "e2e_caps",
                    "e2e_models_advertisement", "mesh_two", "e2e_tls_chain"]
assert sorted(HISTORICAL_ORDER) == sorted(BY_NAME), (
    "catalog and the historical gate roster disagree: %s"
    % (set(HISTORICAL_ORDER) ^ set(BY_NAME),))
GATES.sort(key=lambda g: HISTORICAL_ORDER.index(g.name))
GATE_ORDER = list(HISTORICAL_ORDER)
QUICK_GATES = [g.name for g in GATES if g.quick]

# Every suite that boots the built image depends on the build gate. conf/unit/
# contract/probes do not, and that is what removes the old phase-1 barrier.
_NO_IMAGE = ("build", "conf", "unit", "contract", "probes")
for _g in GATES:
    if _g.name not in _NO_IMAGE:
        _g.needs_image = True
    if _g.needs_image and _g.name != "build" and "build" not in _g.depends:
        _g.depends = tuple(list(_g.depends) + ["build"])


def selected(tier="quick", groups=None, only=None, skips=()):
    """Return (run_names, skip_names), both in GATE_ORDER.

    A singled-out gate (GATE_ONLY) ignores tier and group filters, matching the
    old script. Skips are recorded, never silently dropped, so a green run
    cannot read as a shrunk one.
    """
    wanted = set(skips)
    unknown = wanted - set(GATE_ORDER)
    if unknown:
        raise KeyError("unknown gate in skips: %s" % ", ".join(sorted(unknown)))
    bad_group = set(groups or ()) - set(GROUPS)
    if bad_group:
        raise KeyError("unknown group: %s (known: %s)"
                       % (", ".join(sorted(bad_group)), ",".join(GROUPS)))
    sel = []
    for name in GATE_ORDER:
        g = BY_NAME[name]
        if only and name != only:
            continue
        if groups and not set(g.groups).intersection(groups):
            continue
        if not only and tier == "quick" and not g.quick:
            continue
        sel.append(name)
    return ([n for n in sel if n not in wanted], [n for n in sel if n in wanted])


def plan_lines(tier="quick", groups=None, only=None, skips=(), jobs=1):
    run, skip = selected(tier, groups, only, skips)
    rows = ["lua-router gate plan (nothing executed)",
            "tier=%s jobs=%s groups=%s only=%s skips=%s" % (
                tier, jobs, ",".join(groups) if groups else "all",
                only or "-", ",".join(sorted(skips)) or "none"),
            "  %-24s %-6s %-14s %-16s %s" % ("gate", "state", "group", "locks", "deps")]
    for name in GATE_ORDER:
        g = BY_NAME[name]
        tag = "run" if name in run else ("skip" if name in skip else "off")
        rows.append("  %-24s %-6s %-14s %-16s %s" % (
            name, tag, ",".join(g.groups), ",".join(g.locks), ",".join(g.depends) or "-"))
    return rows
