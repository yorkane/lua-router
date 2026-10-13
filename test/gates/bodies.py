#!/usr/bin/env python3
"""Gate bodies: name -> argv.

A gate body is NOT re-implemented here. It stays a shell function in
test/final_gates.sh, and the body argv re-enters that script in the hidden
--gate-body mode, running the copy that lives inside the frozen snapshot. Two
consequences worth stating:

  * the 22 bodies keep their exact historical shell semantics (docker lines,
    timeouts, luajit/resty/node invocations) -- the runner adds scheduling,
    locking, namespacing and result recording, nothing else;
  * because the re-entry target is the snapshot copy, REPO_ROOT inside the body
    resolves to the snapshot, so every -v $REPO_ROOT:/repo mount and every
    python3 test/integration/*.py runs against the frozen tree.

LR_GATE_FAKE=<python file> swaps the bodies for a fake backend, which is how
test/test_gate_runner.py exercises selection, dedup, dependencies, locking,
namespaces, child crashes and result aggregation without touching docker,
containers, ports or the network.
"""

import os

ENV_FAKE = "LR_GATE_FAKE"


def body_argv(manifest, gate, repo=None):
    """Argv for one gate body: the fake backend, or the snapshot's own shell body."""
    fake = os.environ.get(ENV_FAKE)
    if fake:
        return ["python3", fake, gate.name]
    script = os.path.join(manifest["snapshot"] if manifest else (repo or ""),
                          "test", "final_gates.sh")
    return ["bash", script, "--gate-body", gate.name]


def describe(manifest, gate):
    fake = os.environ.get(ENV_FAKE)
    if fake:
        return "python3 %s %s" % (fake, gate.name)
    return "bash <snapshot>/test/final_gates.sh --gate-body %s" % gate.name
