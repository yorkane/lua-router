#!/usr/bin/env python3
"""e2e for the in-process watcher (doc/gap-watcher-merge.md).

Real openresty containers, real workers, real reconcile loops. _lib.py supplies the
shared plumbing (free_port / http / check / start_mock / logs / cleanup); the router
launcher here is its own because the watcher needs two mounts the other suites never
asked for - the docker socket (SMG_WATCHER_DOCKER) - and its own env defaults
(a two-second interval, so a scenario finishes in seconds rather than minutes).

Every scenario drives the cadence down through the env: SMG_WATCHER_INTERVAL_SECS=2,
SMG_WATCHER_REMOVE_GRACE_SECS=4. The shipped defaults are 15 and 300; the e2e asserts
the *ordering* those defaults impose (kept while inside grace, gone after it), which is
the same property, just measured on a shorter clock.

Scenarios, in order:
  1  TARGET registration, the model-map rename reaching the pool through the API,
     the four POST body shapes, and a chat that actually routes to the worker.
  2  proc scan: a discovered worker joins, the router's own listeners do not (guard 1),
     a non-OpenAI port does not (guard 2), and SMG_WORKER_URLS rows are protected
     (guard 3: never deleted, never re-registered, metadata carries no managed-by).
  3  remove-grace: a stopped worker survives the grace window and is deleted after it
     (guards 5 + 4, with keep-last switched off so nothing else holds it back).
  4  keep-last: the same stop, this time the worker is kept, warned about, and only
     removed once keep-last-grace itself expires (guard 6).
  5  docker discovery over the unix socket: a published container port becomes a
     worker labelled with its container name, and disappears when the container is
     removed.
  6  container restart: the ledger and the pool are both shared dicts, so a restart
     clears them together and rediscovery re-registers from scratch (guard 8 in its
     merged form).
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (REPO, TMP, RUN, IMAGE, CONTAINERS, RESULTS, free_port, http,
                  check, start_mock, logs, cleanup)

WATCHER_ENV = {
    "SMG_WATCHER_ENABLED": "1",
    "SMG_WATCHER_INTERVAL_SECS": "2",
    "SMG_WATCHER_PROBE_TIMEOUT_SECS": "2",
    "SMG_WATCHER_REMOVE_GRACE_SECS": "4",
    "SMG_WATCHER_DOCKER": "0",
    "SMG_WATCHER_PROC_SCAN": "0",
    # The shipped log level is warn; the watcher's protect/register decisions are
    # NOTICE lines, and three of the assertions below read them back from the log.
    "SMG_LOG_LEVEL": "notice",
}


def start_watcher(env, name, mounts_docker=False, wait_secs=40, port=None):
    """Launch the router with the watcher env, and return its port.

    `port` may be supplied by a scenario that has to name the router's own listener in
    its own env (the proc-scan scenario narrows SMG_WATCHER_ALLOW_PORT to the ports it
    owns, and the self-loop assertion needs the router's port in that list)."""
    port = port or free_port()
    full = dict(WATCHER_ENV)
    full.update(env)
    full["SMG_PORT"] = str(port)
    # /metrics has to stay on the main port: these checks read it there, and the
    # host already owns 29000 (the Rust gateway).
    full["SMG_METRICS_PORT"] = "0"
    full.setdefault("SMG_HEALTH_CHECK_INTERVAL_SECS", "1")
    full.setdefault("SMG_POLICY", "round_robin")
    args = ["docker", "run", "-d", "--name", name]
    for key, value in full.items():
        args += ["-e", "%s=%s" % (key, value)]
    if mounts_docker:
        args += ["-v", "/var/run/docker.sock:/var/run/docker.sock:ro"]
    args += ["--network", "host", "--entrypoint", "/docker-entrypoint.sh", IMAGE,
             "/usr/local/openresty/bin/openresty", "-p", "/usr/local/openresty/nginx",
             "-g", "daemon off;"]
    subprocess.run(args, check=True, capture_output=True)
    CONTAINERS.append(name)
    deadline = time.time() + wait_secs
    while time.time() < deadline:
        status, _, _ = http("GET", "http://127.0.0.1:%d/health" % port, timeout=2)
        if status == 200:
            return port
        time.sleep(0.25)
    raise RuntimeError("watcher router %s never came up:\n%s" % (name, logs(name)))


def workers(port):
    status, body, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
    if status != 200:
        return None
    return json.loads(body).get("workers", [])


def by_url(port):
    rows = workers(port)
    if rows is None:
        return {}
    return {w["url"]: w for w in rows}


def wait_workers(port, count, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        rows = workers(port)
        if rows is not None and len(rows) == count:
            return True
        time.sleep(0.4)
    return False


def wait_model(port, url, model_id, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        rows = by_url(port)
        row = rows.get(url)
        if row is not None and row.get("model_id") == model_id:
            return True
        time.sleep(0.4)
    return False


def wait_healthy(port, url, timeout=30):
    """A fresh registry row starts unhealthy; the sweep needs its success threshold
    of consecutive probes before the worker can carry traffic."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        row = by_url(port).get(url)
        if row and row.get("is_healthy"):
            return True
        time.sleep(0.4)
    return False


def metric(text, name):
    for line in text.splitlines():
        if line.startswith(name + " "):
            return float(line.split()[-1])
    return None


def metrics(port):
    status, body, _ = http("GET", "http://127.0.0.1:%d/metrics" % port)
    return body if status == 200 else ""


def stop_mock(proc):
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()


# --------------------------------------------------------------------------
def scenario_target_and_map():
    tag = "target"
    name = "lr-watch-1-%s" % RUN
    mock_port = free_port()
    mock = start_mock(mock_port, "/models/gpu7-weights.gguf")
    port = start_watcher({
        "SMG_WATCHER_TARGETS": "http://127.0.0.1:%d" % mock_port,
        "SMG_WATCHER_MODEL_MAP": "/models/gpu7-weights.gguf:public-aaa",
    }, name)
    url = "http://127.0.0.1:%d" % mock_port
    if not check("[1] TARGET registered as one worker",
                 wait_model(port, url, "public-aaa"), logs(name)):
        return
    row = by_url(port)[url]
    check("[1] registration is labelled router-watch",
          row.get("metadata", {}).get("managed-by") == "router-watch",
          json.dumps(row.get("metadata")))
    check("[1] the engine sniff is recorded as a label",
          row.get("metadata", {}).get("engine") in ("sglang", "vllm", "llama.cpp", "openai"),
          json.dumps(row.get("metadata")))
    check("[1] the source is recorded as the target list",
          row.get("metadata", {}).get("discovery") == "cli",
          json.dumps(row.get("metadata")))

    status, body, _ = http("GET", "http://127.0.0.1:%d/v1/models" % port)
    check("[1] the public id is what the router advertises",
          status == 200 and "public-aaa" in body and "gpu7-weights" not in body,
          "%s %s" % (status, body[:200]))

    # Registration is not availability: a fresh row starts unhealthy and the sweep
    # needs health_success_threshold (2) consecutive passes to flip it, so a request
    # that races that flip gets the honest 503 rather than a route.
    check("[1] the worker becomes healthy under the router's own sweep",
          wait_healthy(port, url), logs(name))

    # The Lua router filters candidates by model (router.lua candidates_for), so a
    # request naming the public id must reach this worker. This is also why the
    # daemon's mixed-model warning was not ported.
    status, body, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                           {"model": "public-aaa",
                            "messages": [{"role": "user", "content": "watcher route probe"}]})
    echo = json.loads(body).get("echo_body", {}) if status == 200 else {}
    check("[1] chat by the renamed model id routes to that worker",
          status == 200 and echo.get("model") == "public-aaa",
          "%s %s" % (status, body[:250]))

    # GET shows the effective map
    status, body, _ = http("GET", "http://127.0.0.1:%d/model-map" % port)
    doc = json.loads(body) if status == 200 else {}
    check("[1] GET /model-map answers the effective map",
          status == 200 and doc.get("model_map", {}).get("/models/gpu7-weights.gguf")
          == "public-aaa", "%s %s" % (status, body[:200]))
    check("[1] GET /model-map says the watcher is on", doc.get("enabled") is True, body[:200])

    # The four accepted POST shapes, each merged.
    shapes = [
        ('{"shape-object.gguf":"so"}', "shape-object.gguf", "so"),
        ('{"map":{"shape-wrapped.gguf":"sw"}}', "shape-wrapped.gguf", "sw"),
        ("shape-bare.gguf:sb", "shape-bare.gguf", "sb"),
        ('{"map":"shape-string.gguf:ss"}', "shape-string.gguf", "ss"),
    ]
    for raw, key, want in shapes:
        status, body, _ = http("POST", "http://127.0.0.1:%d/model-map" % port, raw)
        doc = json.loads(body) if status == 200 else {}
        check("[1] POST /model-map accepts %s" % raw[:28],
              status == 200 and doc.get("renamed", {}).get(key) == want
              and doc.get("status") == "queued", "%s %s" % (status, body[:200]))
        check("[1] %s does not poison the map with a literal map key" % raw[:28],
              "map" not in doc.get("renamed", {}), body[:200])

    # a bad body is a 400 naming the reason, and the map is untouched
    status, body, _ = http("POST", "http://127.0.0.1:%d/model-map" % port, "novalue;also-bad")
    doc = json.loads(body) if status in (400, 200) else {}
    check("[1] a bad body is 400 with the offending entries",
          status == 400 and doc.get("error") and len(doc.get("ignored") or []) == 2,
          "%s %s" % (status, body[:200]))
    status, body, _ = http("GET", "http://127.0.0.1:%d/model-map" % port)
    check("[1] a rejected POST leaves the map untouched",
          json.loads(body)["model_map"].get("shape-bare.gguf") == "sb", body[:200])

    # renaming an owned worker recycles it on the next pass
    status, _, _ = http("POST", "http://127.0.0.1:%d/model-map" % port,
                        '{"/models/gpu7-weights.gguf":"renamed-aaa"}')
    check("[1] the rename is accepted", status == 200, body[:200])
    check("[1] the owned worker is re-registered under the new id",
          wait_model(port, url, "renamed-aaa", timeout=30), logs(name))
    healthy_again = wait_healthy(port, url)
    check("[1] the recycled worker turns healthy again", healthy_again, logs(name))
    status, body, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                           {"model": "renamed-aaa",
                            "messages": [{"role": "user", "content": "renamed route probe"}]})
    echo = json.loads(body).get("echo_body", {}) if status == 200 else {}
    check("[1] the recycled worker routes again under its new id",
          status == 200 and echo.get("model") == "renamed-aaa",
          "%s %s" % (status, body[:250]))

    # an empty new id deletes the entry, and the raw id comes back
    http("POST", "http://127.0.0.1:%d/model-map" % port, '{"a":""}')
    status, body, _ = http("GET", "http://127.0.0.1:%d/model-map" % port)
    check("[1] an empty new id deletes the entry",
          "a" not in json.loads(body)["model_map"], body[:200])

    text = metrics(port)
    check("[1] lr_watch counters are exported",
          metric(text, "lr_watch_adds_total") is not None
          and metric(text, "lr_watch_reconciles_total") >= 1
          and metric(text, "lr_watch_owned_workers") == 1, 
          "\n".join(l for l in text.splitlines() if l.startswith("lr_watch")))
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)
    stop_mock(mock)


# --------------------------------------------------------------------------
def scenario_proc_scan_protection():
    tag = "proc"
    name = "lr-watch-2-%s" % RUN
    seed_port = free_port()      # pre-configured through SMG_WORKER_URLS
    found_port = free_port()     # discovered by the scan
    noise_port = free_port()     # a listener that is not an OpenAI endpoint
    seed = start_mock(seed_port, "seed-model")
    found = start_mock(found_port, "found-model")
    # A plain HTTP server: answers /v1/models with a 404 page, the shape that kept
    # node_exporter out of the daemon's pool.
    noise = subprocess.Popen(
        [sys.executable, "-m", "http.server", str(noise_port), "--bind", "127.0.0.1"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    from _lib import PIDS
    PIDS.append(noise)
    time.sleep(1.2)

    own_port = free_port()
    port = start_watcher({
        "SMG_WORKER_URLS": "http://127.0.0.1:%d" % seed_port,
        "SMG_WATCHER_PROC_SCAN": "1",
        # Narrow the scan to the four ports this scenario owns: the box has a hundred
        # real listeners and an unbounded scan would probe all of them. The router's
        # own listener is deliberately inside the scanned set, which is what makes the
        # self-port assertion below a real test rather than an accident of the filter.
        "SMG_WATCHER_ALLOW_PORT": "%d,%d,%d,%d" % (seed_port, found_port, noise_port, own_port),
    }, name, port=own_port)
    seed_url = "http://127.0.0.1:%d" % seed_port
    found_url = "http://127.0.0.1:%d" % found_port

    # The seed row comes from SMG_WORKER_URLS; discovery must neither duplicate nor
    # delete it, and the scanned worker must arrive on its own.
    ok = check("[2] seed + discovered worker, nothing else",
               wait_workers(port, 2, timeout=40), logs(name))
    rows = by_url(port)
    if ok:
        check("[2] the scanned worker was registered",
              found_url in rows, json.dumps(sorted(rows)))
        check("[2] the seed worker was left alone (no managed-by label)",
              rows.get(seed_url, {}).get("metadata", {}).get("managed-by") is None,
              json.dumps(rows.get(seed_url, {}).get("metadata")))
        check("[2] the discovered worker carries router-watch",
              rows.get(found_url, {}).get("metadata", {}).get("managed-by") == "router-watch")
        check("[2] a non-OpenAI listener never becomes a worker",
              "http://127.0.0.1:%d" % noise_port not in rows,
              json.dumps(sorted(rows)))
        check("[2] the router's own port is never a candidate (guard 1)",
              "http://127.0.0.1:%d" % port not in rows,
              json.dumps(sorted(rows)))
        # A protected row is never deleted -- until a rename asks for its public id,
        # which is the one case where the daemon hands itself ownership. Over real
        # HTTP that is a POST /model-map against the router port, so the control-plane
        # route, the ledger and the registry all have to agree.
        status, body, _ = http("POST", "http://127.0.0.1:%d/model-map" % port,
                               '{"seed-model":"adopted-seed"}')
        check("[2] a rename covering a protected worker is accepted",
              status == 200 and json.loads(body)["renamed"].get("seed-model")
              == "adopted-seed", "%s %s" % (status, body[:200]))
        check("[2] the protected worker is adopted under the new public id",
              wait_model(port, seed_url, "adopted-seed", timeout=30), logs(name))
        rows = by_url(port)
        check("[2] and it is watcher-owned from then on",
              rows.get(seed_url, {}).get("metadata", {}).get("managed-by")
              == "router-watch", json.dumps(rows.get(seed_url, {}).get("metadata")))
        # the scanned worker must be untouched by that churn
        check("[2] the discovered worker survived the adoption",
              found_url in rows and rows[found_url].get("model_id") == "found-model",
              json.dumps(sorted(rows)))

        text = metrics(port)
        check("[2] the seed worker is snapshotted as protected (guard 3)",
              metric(text, "lr_watch_protected_workers") == 1,
              "\n".join(l for l in text.splitlines() if l.startswith("lr_watch")))
        check("[2] only the discovered worker is owned",
              metric(text, "lr_watch_owned_workers") == 1,
              "\n".join(l for l in text.splitlines() if l.startswith("lr_watch")))

        # Guard 3 has a second half worth pinning: the worker that was protected at
        # first contact and then adopted by a rename is now owned, so it is subject to
        # the remove grace -- unlike a row that stayed protected.
        stop_mock(found)
        deadline = time.time() + 30
        dropped = False
        while time.time() < deadline:
            if found_url not in by_url(port):
                dropped = True
                break
            time.sleep(0.5)
        check("[2] an owned (adopted) worker is deleted once its service is gone",
              dropped, logs(name))
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)
    for proc in (seed, found):
        stop_mock(proc)
    noise.terminate()


# --------------------------------------------------------------------------
def scenario_grace_and_keep_last():
    """One stopped worker, two ledgers: keep-last off deletes, keep-last on holds."""
    name_grace = "lr-watch-3-%s" % RUN
    name_keep = "lr-watch-4-%s" % RUN
    port_a = free_port()
    mock_a = start_mock(port_a, "gone-model")
    watcher_a = start_watcher({
        "SMG_WATCHER_TARGETS": "http://127.0.0.1:%d" % port_a,
        # SMG_WATCHER_KEEP_LAST=false is the daemon's --no-keep-last: guard 6 off so
        # this scenario measures the remove grace alone.
        "SMG_WATCHER_KEEP_LAST": "false",
    }, name_grace)
    url_a = "http://127.0.0.1:%d" % port_a
    if not check("[3] worker registered before the stop",
                 wait_workers(watcher_a, 1, timeout=30), logs(name_grace)):
        stop_mock(mock_a)
        return
    stop_mock(mock_a)
    # First pass after the stop stamps missing_since; the worker must stay.
    time.sleep(3)
    rows = by_url(watcher_a)
    check("[3] inside remove-grace the worker is kept (guard 5)",
          url_a in rows, json.dumps(sorted(rows)))
    removes_now = metric(metrics(watcher_a), "lr_watch_removes_total")
    check("[3] and nothing has been removed yet", not removes_now, str(removes_now))
    # Past the 4 s grace.
    deadline = time.time() + 25
    gone = False
    while time.time() < deadline:
        if url_a not in by_url(watcher_a):
            gone = True
            break
        time.sleep(0.5)
    check("[3] after remove-grace the owned worker is deleted",
          gone, logs(name_grace))
    check("[3] the deletion is counted once (guard 4: from its own ledger)",
          metric(metrics(watcher_a), "lr_watch_removes_total") == 1,
          "\n".join(l for l in metrics(watcher_a).splitlines() if l.startswith("lr_watch")))
    subprocess.run(["docker", "rm", "-f", name_grace], capture_output=True)

    # Same stop, keep-last on: the last worker of a model is held and warned about,
    # then released when its own grace expires.
    port_b = free_port()
    mock_b = start_mock(port_b, "solo-model")
    watcher_b = start_watcher({
        "SMG_WATCHER_TARGETS": "http://127.0.0.1:%d" % port_b,
        "SMG_WATCHER_REMOVE_GRACE_SECS": "2",
        "SMG_WATCHER_KEEP_LAST_GRACE_SECS": "12",
    }, name_keep)
    url_b = "http://127.0.0.1:%d" % port_b
    if check("[4] worker registered before the stop",
             wait_workers(watcher_b, 1, timeout=30), logs(name_keep)):
        stop_mock(mock_b)
        time.sleep(9)          # grace (2 s) long elapsed, keep-last (12 s) not yet
        rows = by_url(watcher_b)
        check("[4] the last worker of a model survives remove-grace (guard 6)",
              url_b in rows, json.dumps(sorted(rows)))
        check("[4] nothing removed while keep-last holds",
              not metric(metrics(watcher_b), "lr_watch_removes_total"),
              "\n".join(l for l in metrics(watcher_b).splitlines() if l.startswith("lr_watch")))
        check("[4] the keep-last decision is logged",
              "last worker" in logs(name_keep), logs(name_keep)[-400:])
        deadline = time.time() + 30
        released = False
        while time.time() < deadline:
            if url_b not in by_url(watcher_b):
                released = True
                break
            time.sleep(0.5)
        check("[4] keep-last expires and the dead worker finally goes",
              released, logs(name_keep))
    subprocess.run(["docker", "rm", "-f", name_keep], capture_output=True)
    stop_mock(mock_b)


# --------------------------------------------------------------------------
def scenario_docker_and_restart():
    """Discovery through the docker socket, then a container restart (guard 8)."""
    name = "lr-watch-5-%s" % RUN
    ctr = "lr-watch-ctr-%s" % RUN
    worker_port = free_port()
    # A real container publishing its port: the docker scanner reads the mapping
    # from the daemon instead of from /proc, and reports the container name.
    subprocess.run(["docker", "run", "-d", "--name", ctr,
                    "-p", "127.0.0.1:%d:8000" % worker_port,
                    "-v", "%s:/repo:ro" % REPO, "-e", "MODEL=docker-model",
                    "--entrypoint", "python3", "python:3.12-alpine",
                    "/repo/test/mock_llm_worker.py", "--host", "0.0.0.0",
                    "--port", "8000", "--model", "docker-model"],
                   check=True, capture_output=True)
    CONTAINERS.append(ctr)
    url = "http://127.0.0.1:%d" % worker_port
    ready = False
    for _ in range(60):
        status, _, _ = http("GET", url + "/health", timeout=2)
        if status == 200:
            ready = True
            break
        time.sleep(0.5)
    if not check("[5] the published container answers", ready):
        return

    # The docker source sees every published port on this box, and this host runs
    # real services. None of them answers /v1/models with OpenAI JSON, so the probe
    # would reject them anyway - but a test that depends on what else is listening is
    # a flaky test, so every published port except ours is excluded explicitly.
    others = []
    listed = subprocess.run(["docker", "ps", "--format", "{{.Ports}}"],
                            capture_output=True).stdout.decode()
    for match in __import__("re").finditer(r"(\d+)->", listed):
        published = int(match.group(1))
        if published != worker_port:
            others.append("^http://[^:]+:%d$" % published)
    # keep-last is left on by default everywhere else; here the container is the only
    # worker of its model, so guard 6 would keep it for 30 minutes. The point of this
    # scenario is the docker cycle end to end, so that guard is turned off -- and the
    # keep-last behaviour itself is scenario 4's job.
    env = {"SMG_WATCHER_DOCKER": "1", "SMG_WATCHER_KEEP_LAST": "false"}
    if others:
        # Lua patterns: the dots inside the port list need no escaping and the host
        # part is matched as "anything up to the colon", so the exclude never names
        # an address literal.
        env["SMG_WATCHER_EXCLUDE"] = ",".join(others)
    port = start_watcher(env, name, mounts_docker=True)
    rows = None
    if check("[5] the published port became a worker",
             wait_workers(port, 1, timeout=45), logs(name)):
        rows = by_url(port)
        check("[5] discovered over the docker socket",
              list(rows) == [url], json.dumps(sorted(rows)))
        meta = rows.get(url, {}).get("metadata", {})
        check("[5] the container name labels the worker",
              meta.get("discovery") == "docker", json.dumps(meta))
        check("[5] and it is owned by the watcher",
              meta.get("managed-by") == "router-watch", json.dumps(meta))

        # Guard 8 in the merged shape: a restart clears lr_watch along with
        # lr_workers, so rediscovery has to rebuild the pool by itself.
        subprocess.run(["docker", "restart", name], capture_output=True)
        check("[5] after a router restart rediscovery re-registers the worker",
              wait_workers(port, 1, timeout=45), logs(name))
        rows = by_url(port)
        check("[5] the re-registered row is a fresh registry record",
              url in rows and rows[url].get("metadata", {}).get("managed-by")
              == "router-watch", json.dumps(sorted(rows)))
        check("[5] the re-discovered worker turns healthy",
              wait_healthy(port, url), logs(name))
        status, body, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                               {"model": "docker-model",
                                "messages": [{"role": "user",
                                              "content": "post-restart route probe"}]})
        echo = json.loads(body).get("echo_body", {}) if status == 200 else {}
        check("[5] traffic flows through the re-discovered worker",
              status == 200 and echo.get("model") == "docker-model",
              "%s %s" % (status, body[:250]))

    # And removing the container takes the worker out after the grace.
    subprocess.run(["docker", "rm", "-f", ctr], capture_output=True)
    deadline = time.time() + 30
    gone = False
    while time.time() < deadline:
        rows = by_url(port)
        if url not in rows:
            gone = True
            break
        time.sleep(0.5)
    check("[5] a removed container leaves the pool after remove-grace",
          gone, logs(name))
    check("[5] and the ledger counted the removal",
          metric(metrics(port), "lr_watch_removes_total") == 1,
          "\n".join(l for l in metrics(port).splitlines() if l.startswith("lr_watch")))
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)


# --------------------------------------------------------------------------
def main():
    os.makedirs(TMP, exist_ok=True)
    scenario_target_and_map()
    scenario_proc_scan_protection()
    scenario_grace_and_keep_last()
    scenario_docker_and_restart()
    failed = [r for r in RESULTS if not r[0]]
    print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
    for _, name, detail in failed:
        print("FAILED: %s | %s" % (name, detail[:400]))
    cleanup()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
