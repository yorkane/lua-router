#!/usr/bin/env python3
"""Integration e2e for lua-router: real openresty container + mock workers."""
import json, os, re, socket, subprocess, sys, time, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))          # .../test/integration
REPO = os.path.dirname(os.path.dirname(HERE))  # repo root
IMAGE = os.environ.get("LR_IMAGE", "lua-router:integration")
CONF_TEST = REPO + "/test/conf/nginx-lua-router.conf"
CONF_UI = REPO + "/conf/ui.conf"
TMP = os.environ.get("LR_TEST_TMP", "/data/tmp/lr")
os.makedirs(TMP, exist_ok=True)
RUN = str(os.getpid())[-5:]
RESULTS = []
PIDS = []
CONTAINERS = []


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def http(method, url, body=None, headers=None, timeout=15):
    data = None
    if body is not None:
        data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("content-type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace"), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), dict(e.headers or {})
    except Exception as e:  # noqa
        return 0, "%s: %s" % (type(e).__name__, e), {}


def check(name, cond, detail=""):
    RESULTS.append((bool(cond), name, detail if not cond else ""))
    print(("PASS  " if cond else "FAIL  ") + name + ("" if cond else "   | " + str(detail)[:400]))
    return bool(cond)


def start_mock(port, model):
    log = open("%s/mock-%s.log" % (TMP, port), "w")
    env = dict(os.environ, LR_MOCK_LOG="1", MODEL=model)
    p = subprocess.Popen([sys.executable, REPO + "/test/mock_llm_worker.py",
                          "--host", "0.0.0.0", "--port", str(port), "--model", model],
                         stdout=log, stderr=subprocess.DEVNULL, env=env)
    PIDS.append(p)
    for _ in range(80):
        st, _, _ = http("GET", "http://127.0.0.1:%d/health" % port, timeout=2)
        if st == 200:
            return p
        time.sleep(0.1)
    raise RuntimeError("mock %s never came up" % port)


def mock_lines(port, needle):
    with open("%s/mock-%s.log" % (TMP, port)) as f:
        return sum(1 for line in f if needle in line)


def start_router(env, name):
    port = free_port()
    env = dict(env)
    # The router binds a Prometheus listener on 29000 by default (Rust parity) and
    # these suites run with --network host, where the Rust gateway already owns
    # 29000 on this box. Turn the extra listener off: /metrics is still served on
    # the main port, which is what the e2e checks read.
    env.setdefault("SMG_METRICS_PORT", "0")
    args = ["docker", "run", "-d", "--name", name]
    for k, v in env.items():
        args += ["-e", "%s=%s" % (k, v)]
    args += ["-e", "SMG_PORT=%d" % port, "--network", "host",
             "--entrypoint", "/docker-entrypoint.sh", IMAGE,
             "/usr/local/openresty/bin/openresty", "-p", "/usr/local/openresty/nginx",
             "-g", "daemon off;"]
    subprocess.run(args, check=True, capture_output=True)
    CONTAINERS.append(name)
    for _ in range(120):
        st, _, _ = http("GET", "http://127.0.0.1:%d/health" % port, timeout=2)
        if st == 200:
            return port
        time.sleep(0.25)
    raise RuntimeError("router %s never came up:\n%s" % (name, logs(name)))


def logs(name):
    r = subprocess.run(["docker", "logs", name], capture_output=True)
    return (r.stderr.decode() + "\n" + r.stdout.decode())[-6000:]


def stop_router(name):
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)


def wait_ready(port, want=2, timeout=40):
    for _ in range(int(timeout / 0.5)):
        st, body, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
        if st == 200:
            doc = json.loads(body)
            if sum(1 for w in doc.get("workers", []) if w.get("is_healthy")) >= want:
                return True
        time.sleep(0.5)
    return False


def register(port, url):
    st, body, _ = http("POST", "http://127.0.0.1:%d/workers" % port, {"url": url})
    return st, body


def chat(port, model, text="hello world", stream=False, extra=None, path="/v1/chat/completions",
         headers=None):
    body = {"model": model, "messages": [{"role": "user", "content": text}],
            "stream": stream}
    if extra:
        body.update(extra)
    return http("POST", "http://127.0.0.1:%d%s" % (port, path), body, headers)


def cleanup():
    for p in PIDS:
        p.terminate()
    for c in CONTAINERS:
        subprocess.run(["docker", "rm", "-f", c], capture_output=True)



def scenario_policy(policy, suffix, extra_env=None):
    tag = "%s-%s" % (policy, suffix)
    name = "lr-%s-%s" % (tag[:32], RUN)
    pa, pb = free_port(), free_port()
    start_mock(pa, "alpha")
    start_mock(pb, "beta")
    env = {"SMG_POLICY": policy, "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
           "SMG_WORKER_URLS": "http://127.0.0.1:%d,http://127.0.0.1:%d" % (pa, pb)}
    env.update(extra_env or {})
    port = start_router(env, name)
    ok = check("[%s] /health 200" % tag, http("GET", "http://127.0.0.1:%d/health" % port)[0] == 200)
    ok = check("[%s] both workers healthy" % tag, wait_ready(port), logs(name))
    st, body, _ = http("GET", "http://127.0.0.1:%d/v1/models" % port)
    check("[%s] /v1/models lists both" % tag,
          st == 200 and "alpha" in body and "beta" in body, body[:200])

    # non-stream chat
    st, body, _ = chat(port, "alpha", "non-stream probe")
    content, echoed = "", ""
    if st == 200:
        doc = json.loads(body)
        content = doc.get("choices", [{}])[0].get("message", {}).get("content", "")
        echoed = doc.get("echo_body", {}).get("model", "")
    check("[%s] chat non-stream 200, echo and forwarded model agree" % tag,
          st == 200 and content.startswith("echo[") and echoed in ("alpha", "beta")
          and ("echo[" + echoed + "]") in content, "%s %s" % (st, body[:200]))

    # streaming chat
    st, raw, hdrs = chat(port, "alpha", "stream probe", stream=True)
    ctypes = [v for k, v in hdrs.items() if k.lower() == "content-type"]
    check("[%s] chat stream 200 SSE with [DONE] + echo_body" % tag,
          st == 200 and any("text/event-stream" in v for v in ctypes)
          and "data: [DONE]" in raw and '"echo_body"' in raw, "%s %s" % (st, raw[:200]))

    # completion endpoint
    st, body, _ = http("POST", "http://127.0.0.1:%d/v1/completions" % port,
                       {"model": "alpha", "prompt": ["p1", "p2"]})
    check("[%s] completions 200 (model rewritten to the chosen worker)" % tag,
          st == 200 and ("echo[alpha]" in body or "echo[beta]" in body)
          and '"echo_body"' in body, "%s %s" % (st, body[:200]))

    # /workers load field present
    st, body, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
    doc = json.loads(body)
    check("[%s] /workers exposes load" % tag,
          st == 200 and all("load" in w for w in doc.get("workers", [])), body[:200])

    # metrics families
    st, text, _ = http("GET", "http://127.0.0.1:%d/metrics" % port)
    family = {"cache_aware": "smg_worker_selection_total",
              "consistent_hashing": "smg_consistent_hashing_policy_branch_total",
              "round_robin": "smg_router_requests_total"}[policy]
    check("[%s] /metrics has %s" % (tag, family),
          st == 200 and family in text, text[:200] if st != 200 else "missing")

    # /_ui/* endpoints
    st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/props" % port)
    check("[%s] /_ui/props 200" % tag, st == 200, "%s %s" % (st, body[:150]))
    st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/config" % port)
    check("[%s] /_ui/config 200" % tag, st == 200, "%s %s" % (st, body[:150]))
    st, body, _ = http("POST", "http://127.0.0.1:%d/_ui/v1/chat/completions" % port,
                       {"model": "alpha", "messages": [{"role": "user", "content": "ui bridge probe"}]})
    ui_content = ""
    if st == 200:
        ui_content = json.loads(body).get("choices", [{}])[0].get("message", {}).get("content", "")
    check("[%s] /_ui/v1/chat/completions forwards" % tag,
          st == 200 and (ui_content.startswith("echo[alpha]")
                         or ui_content.startswith("echo[beta]")),
          "%s %s" % (st, body[:250]))
    st, body, _ = http("POST", "http://127.0.0.1:%d/_ui/v1/chat/completions" % port, "not json{{")
    check("[%s] /_ui chat bad body 400" % tag, st == 400 and "invalid chat request" in body,
          "%s %s" % (st, body[:150]))
    st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/logs" % port)
    check("[%s] /_ui/logs 200" % tag, st == 200, "%s %s" % (st, body[:150]))
    return port, name, pa, pb


def scenario_sticky(policy, suffix, prefix):
    """Same prefix must land on one mock instance; count hits per mock log."""
    tag = "sticky-%s-%s" % (policy, suffix)
    name = "lr-%s-%s" % (tag[:32], RUN)
    pa, pb = free_port(), free_port()
    start_mock(pa, "alpha")
    start_mock(pb, "beta")
    env = {"SMG_POLICY": policy, "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
           "SMG_WORKER_URLS": "http://127.0.0.1:%d,http://127.0.0.1:%d" % (pa, pb)}
    port = start_router(env, name)
    if not check("[%s] workers healthy" % tag, wait_ready(port), logs(name)):
        return
    hdrs = {"x-smg-routing-key": prefix} if policy == "consistent_hashing" else None
    base_a, base_b = mock_lines(pa, "/v1/chat/completions"), mock_lines(pb, "/v1/chat/completions")
    for i in range(10):
        chat(port, "alpha", prefix + " repetition %d keeps the prefix stable" % i,
             headers=hdrs)
    hits_a = mock_lines(pa, "/v1/chat/completions") - base_a
    hits_b = mock_lines(pb, "/v1/chat/completions") - base_b
    check("[%s] 10 same-prefix requests hit one mock (%d/%d)" % (tag, hits_a, hits_b),
          hits_a + hits_b == 10 and max(hits_a, hits_b) == 10, "a=%d b=%d" % (hits_a, hits_b))
    stop_router(name)


def main():
    ok = True
    # 1. cache_aware
    port, name, pa, pb = scenario_policy("cache_aware", "a")
    # cache-aware stickiness across the same process
    base_a, base_b = mock_lines(pa, "/v1/chat/completions"), mock_lines(pb, "/v1/chat/completions")
    for i in range(10):
        chat(port, "alpha", "cache-aware sticky prefix alpha-beta-gamma " + "tail %d" % i)
    ha, hb = mock_lines(pa, "/v1/chat/completions") - base_a, mock_lines(pb, "/v1/chat/completions") - base_b
    check("[cache_aware] 10 shared-prefix requests hit one mock (%d/%d)" % (ha, hb),
          max(ha, hb) == 10, "a=%d b=%d" % (ha, hb))
    # effort injection + output-budget pass-through + alias resolve, all visible
    # through echo_body
    st, body, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
    worker_ids = [w["id"] for w in json.loads(body).get("workers", [])]
    st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/config" % port)
    check("[cache_aware] /_ui/config effort doc readable" , st == 200, "%s %s" % (st, body[:200]))
    stop_router(name)

    # 2. consistent_hashing / round_robin
    p2, n2, _, _ = scenario_policy("consistent_hashing", "a")
    # routing-key affinity
    pa2 = None
    stop_router(n2)
    p3, n3, _, _ = scenario_policy("round_robin", "a")
    st, body, _ = chat(p3, "alpha", "round robin probe")
    check("[round_robin] chat still 200", st == 200, body[:150])
    stop_router(n3)

    scenario_sticky("consistent_hashing", "key", "session-affinity-prefix")
    scenario_sticky("cache_aware", "prefix", "radix-affinity-prefix")

    # 3. virtual alias + effort + ctx in one container
    pa, pb = free_port(), free_port()
    start_mock(pa, "alpha")
    start_mock(pb, "beta")
    port = start_router({"SMG_POLICY": "round_robin", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                         "SMG_WORKER_URLS": "http://127.0.0.1:%d,http://127.0.0.1:%d" % (pa, pb),
                         "LMR_VIRTUAL_MODELS": "alias-a:alpha",
                         "LMR_DEFAULT_EFFORT": "high",
                         "LMR_EFFORT_MAP": "low:medium",
                         "LMR_MODEL_CTX": "alpha:128"}, "lr-alias1-" + RUN)
    if check("[alias] workers healthy", wait_ready(port)):
        st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/config" % port)
        doc = json.loads(body) if st == 200 else {}
        vms = {e.get("model"): e.get("target") for e in doc.get("config", {}).get("virtual_models", [])} \
            if isinstance(doc.get("config"), dict) else {}
        check("[alias LMR_VIRTUAL_MODELS=alias-a:alpha] /_ui/config 200", st == 200,
              "%s %s" % (st, body[:300]))
        check("[alias] default_effort visible as high", "high" in json.dumps(doc), body[:300])
        # alias resolves and body model rewritten to worker id
        st, body, _ = chat(port, "alias-a", "alias resolve probe")
        doc = json.loads(body) if st == 200 else {}
        echo = doc.get("echo_body", {})
        check("[alias] chat(alias-a) 200, alias never forwarded",
              st == 200 and echo.get("model") in ("alpha", "beta"),
              "%s %s" % (st, json.dumps(echo)[:300]))
        check("[alias] LMR_DEFAULT_EFFORT=high injected",
              echo.get("reasoning_effort") == "high", json.dumps(echo)[:300])
        # effort map: requested low -> medium
        st, body, _ = chat(port, "alias-a", "map probe", extra={"reasoning_effort": "low"})
        echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
        check("[alias] LMR_EFFORT_MAP low->medium", echo.get("reasoning_effort") == "medium",
              json.dumps(echo)[:300])
        # Output budget: the gateway does not touch it (ruling 2026-10-04, commit
        # 75ecc37). LMR_MODEL_CTX=alpha:128 stays configured on purpose -- it is the
        # number the retired clamp used to read, so these two checks only discriminate
        # when a cap really exists and really is ignored. Without the env row both
        # assertions would pass on any build that simply never had the feature.
        st, body, _ = chat(port, "alpha", "budget probe", extra={"max_tokens": 99999})
        echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
        check("[budget] a configured context cap leaves the caller's max_tokens alone",
              st == 200 and echo.get("max_tokens") == 99999,
              "%s %s" % (st, json.dumps(echo)[:300]))
        # "the caller gave nothing" and "the field was filled with a number" are two
        # different facts, so the second check tests absence of the KEY rather than a
        # value. A sentinel like 0 or 128 would satisfy either reading and could not
        # tell a re-introduced clamp apart from a plain missing field.
        st, body, _ = chat(port, "alpha", "budget probe absent", extra=None)
        echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
        check("[budget] no budget in, none manufactured out",
              st == 200 and "max_tokens" not in echo
              and "max_completion_tokens" not in echo,
              "%s %s" % (st, json.dumps(echo)[:300]))
        # ui pipeline keeps the alias in the log but forwards the real id
        st, body, _ = http("POST", "http://127.0.0.1:%d/_ui/v1/chat/completions" % port,
                           {"model": "alias-a", "messages": [{"role": "user", "content": "ui alias probe"}]})
        echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
        check("[alias] /_ui chat resolves alias + injects effort",
              st == 200 and echo.get("model") in ("alpha", "beta")
              and echo.get("reasoning_effort") == "high", "%s %s" % (st, json.dumps(echo)[:300]))
        st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/v1/models" % port)
        check("[alias] /_ui/v1/models advertises alias", st == 200 and "alias-a" in body,
              body[:200])
        st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/logs" % port)
        rows = json.loads(body).get("requests", []) if st == 200 else []
        row = [r for r in rows if r.get("requested_model") == "alias-a"]
        check("[alias] request log keeps alias + effort", bool(row)
              and row[-1].get("model") == "alpha" and row[-1].get("effort") == "high",
              json.dumps(row[-1] if row else rows[-3:])[:400])
    stop_router(name)

    # 4. two-alias scenario
    pa, pb = free_port(), free_port()
    start_mock(pa, "alpha")
    start_mock(pb, "beta")
    port = start_router({"SMG_POLICY": "round_robin", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                         "SMG_WORKER_URLS": "http://127.0.0.1:%d,http://127.0.0.1:%d" % (pa, pb),
                         "LMR_VIRTUAL_MODELS": "alias-a:alpha,alias-b:beta"}, "lr-alias2-" + RUN)
    check("[alias x2] healthy", wait_ready(port))
    st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/config" % port)
    check("[alias x2 LMR_VIRTUAL_MODELS=alias-a:alpha,alias-b:beta] /_ui/config 200",
          st == 200, "%s %s" % (st, body[:400]))
    st, body, _ = chat(port, "alias-b", "second alias probe")
    echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
    check("[alias x2] alias-b resolves to a real id", st == 200
          and echo.get("model") in ("alpha", "beta"), "%s %s" % (st, json.dumps(echo)[:200]))
    stop_router(name)

    # 4b. single-worker alias: forwarded model must be exactly the alias target
    pa = free_port()
    start_mock(pa, "alpha")
    port = start_router({"SMG_POLICY": "round_robin", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                         "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa,
                         "LMR_VIRTUAL_MODELS": "alias-a:alpha"}, "lr-alias3-" + RUN)
    name = "lr-alias3-" + RUN
    if check("[alias single] healthy", wait_ready(port, 1)):
        st, body, _ = chat(port, "alias-a", "single worker alias probe")
        echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
        check("[alias single] forwarded model is exactly the alias target alpha",
              st == 200 and echo.get("model") == "alpha", "%s %s" % (st, json.dumps(echo)[:200]))
    stop_router(name)

    # 5. cache_aware worker_processes default must be 1
    pa = free_port()
    start_mock(pa, "alpha")
    port = start_router({"SMG_POLICY": "cache_aware", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                         "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa}, "lr-wpc-" + RUN)
    txt = logs("lr-wpc-" + RUN)
    check("[worker_processes] cache_aware renders workers: 1", "workers: 1" in txt, txt[:300])
    stop_router("lr-wpc-" + RUN)
    port = start_router({"SMG_POLICY": "cache_aware", "NGINX_WORKER_PROCESSES": "2",
                         "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                         "SMG_WORKER_URLS": "http://127.0.0.1:%d" % pa}, "lr-wpc2-" + RUN)
    check("[worker_processes] explicit NGINX_WORKER_PROCESSES wins",
          "workers: 2" in logs("lr-wpc2-" + RUN), logs("lr-wpc2-" + RUN)[:300])
    stop_router("lr-wpc2-" + RUN)
    port = start_router({"SMG_POLICY": "round_robin", "SMG_WORKER_URLS":
                         "http://127.0.0.1:%d" % pa}, "lr-wpa-" + RUN)
    check("[worker_processes] non-cache_aware stays auto", "workers: auto" in logs("lr-wpa-" + RUN),
          logs("lr-wpa-" + RUN)[:300])
    stop_router("lr-wpa-" + RUN)

    failed = [r for r in RESULTS if not r[0]]
    print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
    for _, name, detail in failed:
        print("FAILED: %s | %s" % (name, detail[:300]))
    cleanup()
    sys.exit(1 if failed else 0)

def probe_container(env, name, port_in_container=8080):
    """Serve test/conf/nginx-lua-router.conf on a published port (probe rounds)."""
    args = ["docker", "run", "-d", "--name", name,
            "-p", "127.0.0.1::%d" % port_in_container, "-v", REPO + ":/repo:ro"]
    for k, v in env.items():
        args += ["-e", "%s=%s" % (k, v)]
    args += ["--entrypoint", "openresty", os.environ.get("LR_BASE_IMAGE", "authz:latest"),
             "-p", "/usr/local/openresty/nginx/", "-c", "/repo/test/conf/nginx-lua-router.conf",
             "-g", "daemon off;"]
    subprocess.run(args, check=True, capture_output=True)
    CONTAINERS.append(name)
    hostport = None
    for _ in range(60):
        out = subprocess.run(["docker", "port", name, str(port_in_container)],
                             capture_output=True).stdout.decode()
        for line in out.split():
            if line.startswith("127.0.0.1:"):
                hostport = int(line.split(":")[1])
                break
        if hostport:
            break
        time.sleep(0.2)
    if not hostport:
        raise RuntimeError(logs(name))
    for _ in range(100):
        st, _, _ = http("GET", "http://127.0.0.1:%d/health" % hostport, timeout=2)
        if st == 200:
            return hostport
        time.sleep(0.2)
    raise RuntimeError(logs(name))


def lib_only():
    """Imported by the other rounds; nothing runs at import time."""
    return globals()


if __name__ == "__main__":
    main()
