#!/usr/bin/env python3
"""虚拟 model profile + upstreams + 远程 key（doc/gap-virtual-models.md）的端到端门禁。

⚠️ 本轮只写不跑（并发纪律：容器/契约/e2e 由 root 串行统一跑）。本机验证方式：
   python3 -m py_compile test/integration/e2e_profiles.py
   bash -n test/final_gates.sh

四个场景，字段全部按 doc/gap-virtual-models.md 第 3/5 节 + root 对齐口径钉
（upstreams 条目 api_key 恒 null、存在性看 has_api_key；写响应顶层 reconcile =
{added,updated,removed,skipped}）：

  S1 whitelist   两个同模型 mock（alpha）+ 一个 REQUIRE_AUTH 远程（remote-g），
                 SMG_ENABLE_IGW=1 让候选按 model 收窄，一次 POST /_ui/config/virtual
                 写 5 条新形状 profile：
                   vm-w  白名单=worker1 规范化 url → 20 发只落 worker1；转发 body 的
                         model 是 target 真名 alpha
                   vm-i  白名单=worker2 的 id      → 12 发只落 worker2（id 形态）
                   vm-b  policy=prefix_hash        → root ruling 2026-10-02 起
                         per-alias policy 停用：字段仍被接受并在文档回显（后面那条
                         断言钉住），但热路径不许再看它——同形状 20 发必须像对照
                         模型一样摊开，route_type 全是当前生效策略，且解析期 warn
                   vm-gp 组入口（显式 targets）+ model_policy[入口名]=prefix_hash
                         → 停用字段的替代入口仍然生效：20 发全砸一个 mock、
                         route_type 全 prefix_hash、GET /_ui/config/policy 列出
                         入口那一行 source=model；同时 model=alpha 同形状流量必须
                         仍摊开（入口级覆盖不得泄漏到真实模型上）
                   vm-c  effort=high               → 同 ruling 停用：请求体不再被
                         注入 reasoning_effort；按引擎配 model_effort（模型卡）才是
                         注入的正确来源——配上则别名请求注入 high，清掉回到不注入
                   vm-g  target=remote-g           → POST /workers 带 api_key 的
                         gated worker 走白名单：200 + mock 的 /last_auth 记录
                         Authorization == "Bearer sk-G-123"
                 另测 /v1/models 广告全部别名、白名单全不命中 → 503
                 no_available_workers、GET /_ui/config 回显 workers/policy/effort。
  S1b env_seed   第二个容器只带 LMR_UPSTREAMS_FILE（无 POST、无 SMG_WORKER_URLS）：
                 种子条目必须被 bootstrap reconcile 投进池（discovery=config +
                 model_id），document 脱敏回显 has_api_key，转发注入种子 key。
  S2 keyctl      upstreams 全生命周期（IGW=1，清除 key 后的 401 才有判别力）。
                 POST /_ui/config/upstreams 是整表替换语义，所以每一步都提交完整
                 期望表：加带 key 的 R（reconcile.added==1）→ /workers 有
                 discovery=config 且不回显明文 → document 条目 api_key null +
                 has_api_key true（/_ui/config、/_ui/props 同样无明文）→ 转发注入
                 Bearer → key 三连：null 保留、覆盖新值、空串清除（401 透传 +
                 mock auth_denied 计数 + has_api_key 转 false）→ bootstrap url 混进
                 upstreams 只能 skipped（model_id 不被 hijacked 改写、流量正常）→
                 规范化后重复 url 整体 400（root 裁定 2）→ 尾斜杠单条规范化入档可服务
                 → 非数值 priority 整体 400（同车诱饵 url 与诱饵池成员都不许
                 出现）→ 257 条超上限 400 → 整表清空 removed==2 且 bootstrap
                 成员永远不碰。
  S3 immune      watcher 免疫 + LMR_CONFIG_FILE 复活。watcher interval 6 s
                 （timer.at(0) 的首跑只看得见 SMG_WORKER_URLS，config 成员在首跑
                 之后入池，因此走「非 owned 非 protected」这条账；重启后的首跑才
                 会把它们 protect——两种形态都必须活着）：
                   Ck  REQUIRE_AUTH mock：/v1/models 也 401，watcher classify
                        永远失败；Ck/C2 都不在扫描口内，watcher 对它们「不可见」。
                        免疫断言因此非平凡：一台从未被发现的 worker，若清账按
                        「本轮未扫到就删」实现，Ck 会在 remove-grace 后消失——
                        它必须活着跨过 ≥3 个完整回路（interval 6 s + grace 4 s）。
                   D   watcher 自己的 proc-scan 成员：先被扫入池（lr_watch_adds ≥1），
                       再杀掉 mock——KEEP_LAST=false 下 remove-grace 后被清账删除
                       （lr_watch_removes ≥1）。这条是防「watcher 根本没跑」把免疫
                       断言假绿的对照：同一个清账回路删得掉 D、就必须放过 Ck/C2。
                 docker restart 同一容器（shdict 清零，只剩文件层）：upstreams 与
                 alias 复活、has_api_key 保持、vm-imm 用持久化的 key 再次打穿 200。
                 契约 3.1 的误删自愈：手工 DELETE 掉一个 config 成员，等 30 s
                 定时器（代码常量，无 env knob）补回；不补回时用同表重提交做判别
                 探针，把缺口钉在「定时器没检出变更」还是「reconcile 本身坏」。
  S4 apply       POST /_ui/config/apply 一次写 virtual_models(新形状)+upstreams：
                 响应顶层 reconcile 摘要 + 文档回显 profile 字段 + vm-doc 端到端
                 打穿 gated mock；随后一次「无效整体拒绝」：坏条目（alias 指向
                 alias）与合法改动（G 带 api_key:"" 洗 key、诱饵 upstream）同车
                 提交 → 400，且 vm-doc 仍带 prefix_hash、G 的 key 未被洗
                 （再来一发 200 + Bearer sk-X-999）、池里无诱饵、文档无 vm-bad。
                 另测未知 profile policy 400 与旧形状 {model,target} 兼容。

观察通道：mock 计数、/last_auth 自省、GET /workers、GET /_ui/config、
/_ui/logs route_type、lr_watch_* 计数；端口全部随机；容器一律
NGINX_WORKER_PROCESSES=1（跨进程一致性是 e2e_routing_dyn 的门，这里不重复计费）。
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (TMP, RUN, IMAGE, CONTAINERS, free_port, http, check,
                  start_mock, mock_lines, start_router, logs, stop_router, chat,
                  wait_ready, cleanup, RESULTS)


def stop_mock(proc):
    """Terminate a host mock and reap it (cleanup would also take it, eventually)."""
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()

PFX = "profiles-shared-prefix "


def start_mock_env(port, model, **flags):
    """start_mock with mock-side env knobs exported while it boots.

    start_mock inherits os.environ (the container never sees these), so
    REQUIRE_AUTH must be set around the spawn."""
    saved = {}
    for k, v in flags.items():
        saved[k] = os.environ.get(k)
        os.environ[k] = str(v)
    try:
        return start_mock(port, model)
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def start_router_mounted(env, name, mounts=(), wait_secs=60):
    """start_router with read-only bind mounts (identical path inside the container).

    _lib.start_router has no mounts parameter and _lib is shared by the other
    suites, so the env-seed scenario brings its own launcher: the same shape
    e2e_watcher.start_watcher uses (host network, /docker-entrypoint.sh, random
    SMG_PORT, metrics listener off because the box owns 29000)."""
    port = free_port()
    full = dict(env)
    full.setdefault("SMG_METRICS_PORT", "0")
    args = ["docker", "run", "-d", "--name", name]
    for k, v in full.items():
        args += ["-e", "%s=%s" % (k, v)]
    for path in mounts:
        args += ["-v", "%s:%s:ro" % (path, path)]
    args += ["-e", "SMG_PORT=%d" % port, "--network", "host",
             "--entrypoint", "/docker-entrypoint.sh", IMAGE,
             "/usr/local/openresty/bin/openresty", "-p", "/usr/local/openresty/nginx",
             "-g", "daemon off;"]
    subprocess.run(args, check=True, capture_output=True)
    CONTAINERS.append(name)
    deadline = time.time() + wait_secs
    while time.time() < deadline:
        if http("GET", "http://127.0.0.1:%d/health" % port, timeout=2)[0] == 200:
            return port
        time.sleep(0.25)
    raise RuntimeError("router %s never came up:\n%s" % (name, logs(name)))


def write_upstreams_seed(rows):
    """Host JSON file for LMR_UPSTREAMS_FILE, mounted at the same absolute path."""
    path = "%s/upstreams-%s.json" % (TMP, RUN)
    with open(path, "w") as f:
        json.dump(rows, f)
    return path


def reset_mock(port):
    http("GET", "http://127.0.0.1:%d/reset" % port, timeout=5)


def last_auth(port):
    st, body, _ = http("GET", "http://127.0.0.1:%d/last_auth" % port, timeout=5)
    if st != 200:
        return None
    try:
        return json.loads(body)
    except ValueError:
        return None


def workers_by_url(port):
    st, body, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
    if st != 200:
        return {}
    return {w.get("url"): w for w in json.loads(body).get("workers", [])}


def wait_urls(port, urls, timeout=40):
    deadline = time.time() + timeout
    while time.time() < deadline:
        rows = workers_by_url(port)
        if all(u in rows for u in urls):
            return True
        time.sleep(0.4)
    return False


def wait_gone(port, url, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if url not in workers_by_url(port):
            return True
        time.sleep(0.4)
    return False


def wait_all_healthy(port, want=2, timeout=40):
    for _ in range(int(timeout / 0.5)):
        st, body, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
        if st == 200:
            rows = json.loads(body).get("workers", [])
            if len(rows) >= want and all(r.get("is_healthy") for r in rows):
                return True
        time.sleep(0.5)
    return False


def config_doc(port):
    st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/config" % port)
    if st != 200:
        return None, body
    doc = json.loads(body)
    cfg = doc.get("config") if isinstance(doc.get("config"), dict) else doc
    return doc, cfg


def as_list(v):
    """cjson renders an empty table as {}: accept both spellings as lists."""
    return v if isinstance(v, list) else []


def post_json(port, path, body):
    st, text, _ = http("POST", "http://127.0.0.1:%d%s" % (port, path), body)
    try:
        return st, json.loads(text)
    except ValueError:
        return st, text


def post_profiles(port, entries):
    return post_json(port, "/_ui/config/virtual", {"entries": entries})


def post_upstreams(port, entries):
    return post_json(port, "/_ui/config/upstreams", {"entries": entries})


def post_apply(port, doc):
    return post_json(port, "/_ui/config/apply", doc)


def post_effort(port, patch):
    return post_json(port, "/_ui/config/effort", patch)


def put_policy(port, patch):
    """PUT /_ui/config/policy {policy?, model_policies?, model_policy?}.

    The routing page is the *only* place a scheduling policy is configured since
    root ruling 2026-10-02 removed the per-alias override, so the replacement-entry
    case has to go through this endpoint rather than through virtual_models.
    """
    st, body, _ = http("PUT", "http://127.0.0.1:%d/_ui/config/policy" % port, patch)
    try:
        return st, json.loads(body)
    except ValueError:
        return st, body


def policy_rows(port):
    """GET /_ui/config/policy -> {model: row} of the per-model chain document."""
    st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/config/policy" % port)
    if st != 200:
        return {}
    try:
        doc = json.loads(body)
    except ValueError:
        return {}
    return {r.get("model"): r for r in as_list(doc.get("models"))}


def rc_count(resp, key):
    """reconcile.added/updated/removed/skipped -- number, or len of a name list."""
    rec = resp.get("reconcile") if isinstance(resp, dict) else None
    if not isinstance(rec, dict):
        return None
    v = rec.get(key)
    if isinstance(v, bool):
        return None
    if isinstance(v, list):
        return len(v)
    if isinstance(v, (int, float)):
        return int(v)
    return None


def chat_until(port, model, text, want=200, timeout=25):
    """chat() retried until the status matches or the budget is spent.

    A just-reconciled pool member is unhealthy until the first sweep (1 s
    interval here), so the request racing that window answers 503; the
    assertions below care about the steady state, not that race."""
    deadline = time.time() + timeout
    st, body = 0, ""
    while time.time() < deadline:
        st, body, _ = chat(port, model, text)
        if st == want:
            return st, body
        time.sleep(0.5)
    return st, body


def fire(port, model, n, prefix=PFX):
    for i in range(n):
        chat(port, model, prefix + "tail %d keeps the prefix stable" % i)


def hits(pa, pb, base_a, base_b):
    return (mock_lines(pa, "/v1/chat/completions") - base_a,
            mock_lines(pb, "/v1/chat/completions") - base_b)


def route_types(port, requested_model):
    st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/logs?cursor=0&limit=300" % port)
    if st != 200:
        return []
    try:
        doc = json.loads(body)
    except ValueError:
        return []
    rows = doc.get("requests") or doc.get("logs") or doc.get("entries") or []
    return [r.get("route_type") for r in rows
            if isinstance(r, dict) and r.get("requested_model") == requested_model]


def metric_int(port, name):
    st, text, _ = http("GET", "http://127.0.0.1:%d/metrics" % port)
    if st != 200:
        return None
    for line in text.splitlines():
        if line.startswith(name):
            try:
                return int(float(line.rsplit(" ", 1)[-1]))
            except (ValueError, IndexError):
                return None
    return None


def watch_metrics(port):
    st, text, _ = http("GET", "http://127.0.0.1:%d/metrics" % port)
    text = text if st == 200 else ""
    return "\n".join(l for l in text.splitlines() if l.startswith("lr_watch"))


def logs_all(name):
    """Whole container log, undecorated.

    _lib.logs() keeps the last 6000 characters, which is right for "did anything
    abort" but useless for a one-shot line the operator sees once per config write:
    every request also writes an access-log line, so a warn emitted at POST time is
    pushed out of that window by the traffic the scenario fires afterwards. Parse
    warnings are asserted against the full log for that reason."""
    r = subprocess.run(["docker", "logs", name], capture_output=True)
    return r.stderr.decode("utf-8", "replace") + "\n" + r.stdout.decode("utf-8", "replace")


# ==================================================== S1 whitelist / policy / effort
def scenario_whitelist():
    pa, pb, pg = free_port(), free_port(), free_port()
    start_mock(pa, "alpha")
    start_mock(pb, "alpha")
    start_mock_env(pg, "remote-g", REQUIRE_AUTH=1)
    url_a, url_b, url_g = ("http://127.0.0.1:%d" % p for p in (pa, pb, pg))
    # igw=1 keeps each model's candidate set honest: without it the whitelist
    # probes could leak round_robin traffic onto the gated row, and vm-b's
    # stickiness could "stick" on worker G.
    env = {"SMG_POLICY": "round_robin", "SMG_ENABLE_IGW": "1",
           "NGINX_WORKER_PROCESSES": "1",
           "SMG_PREFIX_TOKEN_COUNT": str(len(PFX)),
           "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
           "SMG_WORKER_URLS": "%s,%s" % (url_a, url_b)}
    name = "lr-prof-s1-%s" % RUN
    port = start_router(env, name)
    if not check("[S1] two alpha mocks healthy", wait_ready(port, 2), logs(name)[:300]):
        return
    st, wbody = post_json(port, "/workers", {"url": url_g, "model_id": "remote-g",
                                             "api_key": "sk-G-123"})
    check("[S1] POST /workers with api_key accepted", st in (200, 202),
          "%s %s" % (st, str(wbody)[:200]))
    check("[S1] gated worker joins", wait_urls(port, [url_g], 30), logs(name)[:300])
    # The igw filter only tightens once model_id is filled in; A/B arrive via
    # SMG_WORKER_URLS and learn "alpha" from the sweep.
    deadline = time.time() + 30
    while time.time() < deadline:
        rows = workers_by_url(port)
        if all((rows.get(u) or {}).get("model_id") == "alpha" for u in (url_a, url_b)):
            break
        time.sleep(0.5)

    id_b = (workers_by_url(port).get(url_b) or {}).get("id")
    profiles5 = [
        {"model": "vm-w", "target": "alpha", "workers": [url_a]},
        {"model": "vm-i", "target": "alpha", "workers": [id_b]},
        {"model": "vm-b", "target": "alpha", "workers": [], "policy": "prefix_hash"},
        {"model": "vm-c", "target": "alpha", "workers": [], "effort": "high"},
        {"model": "vm-g", "target": "remote-g", "workers": [url_g]},
    ]
    st, doc = post_profiles(port, profiles5)
    check("[S1] POST /_ui/config/virtual (new shape) 200", st == 200,
          "%s %s" % (st, str(doc)[:300]))
    st, body, _ = http("GET", "http://127.0.0.1:%d/v1/models" % port)
    check("[S1] /v1/models advertises the aliases",
          st == 200 and all(a in body for a in ("vm-w", "vm-i", "vm-b", "vm-c", "vm-g")),
          body[:250])

    ba, bb = mock_lines(pa, "/v1/chat/completions"), mock_lines(pb, "/v1/chat/completions")
    fire(port, "vm-w", 20)
    ha, hb = hits(pa, pb, ba, bb)
    check("[S1] vm-w url-whitelist pins all 20 to worker A (%d/%d)" % (ha, hb),
          ha == 20 and hb == 0, "a=%d b=%d" % (ha, hb))
    st, body, _ = chat(port, "vm-w", "forwarded model probe")
    echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
    check("[S1] vm-w forwards the real target id, never the alias",
          st == 200 and echo.get("model") == "alpha", "%s %s" % (st, json.dumps(echo)[:200]))

    ba, bb = mock_lines(pa, "/v1/chat/completions"), mock_lines(pb, "/v1/chat/completions")
    fire(port, "vm-i", 12)
    ha, hb = hits(pa, pb, ba, bb)
    check("[S1] vm-i id-whitelist pins all 12 to worker B (%d/%d)" % (ha, hb),
          ha == 0 and hb == 12, "a=%d b=%d" % (ha, hb))

    ba, bb = mock_lines(pa, "/v1/chat/completions"), mock_lines(pb, "/v1/chat/completions")
    fire(port, "alpha", 24)
    ca, cb = hits(pa, pb, ba, bb)
    check("[S1] control: global round_robin spreads identical prefixes (%d/%d)" % (ca, cb),
          ca > 0 and cb > 0, "a=%d b=%d" % (ca, cb))
    # ---- per-alias policy is retired (root ruling 2026-10-02) ------------------
    # vm-b still *declares* policy=prefix_hash. What the suite pins now is that the
    # hot path ignores it: identical-prefix traffic must spread exactly like the
    # round_robin control a few lines above, and every logged row must name the
    # *effective* policy (the env default), never the retired per-alias one. The
    # field's own survival is a separate check below (document echoes it), so the
    # pair together say "accepted, remembered, not obeyed".
    ba, bb = mock_lines(pa, "/v1/chat/completions"), mock_lines(pb, "/v1/chat/completions")
    fire(port, "vm-b", 20)
    ha, hb = hits(pa, pb, ba, bb)
    check("[S1] retired per-alias policy does not steer: vm-b spreads (%d/%d)" % (ha, hb),
          ha + hb == 20 and ha > 0 and hb > 0, "a=%d b=%d" % (ha, hb))
    types = route_types(port, "vm-b")
    check("[S1] vm-b rows report the effective policy, not prefix_hash",
          bool(types) and len(types) >= 15 and all(t == "round_robin" for t in types),
          json.dumps(types[:10]))
    check("[S1] the retired policy warns at parse time instead of dying silently",
          "declares policy=prefix_hash" in logs_all(name), logs_all(name)[-400:])

    # ---- the replacement entry still works: model_policies on the *entry* name --
    # Per-alias policy is gone, but "give this service entry its own policy" is a
    # legitimate demand and the routing page answers it: policy instances are keyed
    # by the entry name (router.group_key_name), so model_policies[entry] is what
    # steers a virtual model. Without this case the *capability* would be untested
    # the moment the old spelling stopped working.
    st, resp = post_profiles(port, profiles5 + [
        {"model": "vm-gp", "targets": ["alpha"], "workers": [url_a, url_b]}])
    check("[S1] a group entry (explicit targets) is accepted", st == 200,
          "%s %s" % (st, str(resp)[:250]))
    st, resp = put_policy(port, {"model_policy": {"model": "vm-gp", "policy": "prefix_hash"}})
    check("[S1] model_policies can pin the entry name to prefix_hash", st == 200,
          "%s %s" % (st, str(resp)[:250]))
    rows = policy_rows(port)
    gp_row = rows.get("vm-gp") or {}
    check("[S1] the routing page lists the entry row with source=model",
          gp_row.get("effective") == "prefix_hash" and gp_row.get("source") == "model",
          json.dumps(gp_row)[:250])
    ba, bb = mock_lines(pa, "/v1/chat/completions"), mock_lines(pb, "/v1/chat/completions")
    fire(port, "vm-gp", 20)
    ha, hb = hits(pa, pb, ba, bb)
    check("[S1] entry-level prefix_hash sticks 20/20 (%d/%d)" % (ha, hb),
          ha + hb == 20 and max(ha, hb) == 20, "a=%d b=%d" % (ha, hb))
    gp_types = route_types(port, "vm-gp")
    check("[S1] every logged vm-gp row says route_type prefix_hash",
          bool(gp_types) and len(gp_types) >= 15 and all(t == "prefix_hash" for t in gp_types),
          json.dumps(gp_types[:10]))
    # The override is scoped to the entry name: the real model under it must keep
    # routing on the env default, otherwise "one knob for one entry" is a lie and a
    # model-wide stickiness was smuggled in through the alias.
    ba, bb = mock_lines(pa, "/v1/chat/completions"), mock_lines(pb, "/v1/chat/completions")
    fire(port, "alpha", 24)
    ca, cb = hits(pa, pb, ba, bb)
    check("[S1] the entry override does not leak onto its own model (%d/%d)" % (ca, cb),
          ca > 0 and cb > 0, "a=%d b=%d" % (ca, cb))
    st, resp = put_policy(port, {"model_policy": {"model": "vm-gp", "policy": None}})
    check("[S1] clearing the entry override is accepted", st == 200,
          "%s %s" % (st, str(resp)[:200]))

    # ---- per-alias effort is retired; the model card is the live source ---------
    st, body, _ = chat(port, "vm-c", "effort probe")
    echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
    check("[S1] retired per-alias effort injects nothing",
          st == 200 and echo.get("reasoning_effort") in (None, ""), json.dumps(echo)[:250])
    check("[S1] the retired effort warns at parse time instead of dying silently",
          "declares effort=high" in logs_all(name), logs_all(name)[-400:])
    st, body, _ = chat(port, "alpha", "effort control")
    plain = json.loads(body).get("echo_body", {}) if st == 200 else {}
    check("[S1] control model carries no reasoning_effort",
          st == 200 and plain.get("reasoning_effort") in (None, ""), json.dumps(plain)[:250])
    # The ladder lives on the *engine* now (a virtual entry spans N engines, so one
    # per-entry effort cannot be honest about any of them): key it on the model the
    # request lands on and the same alias request must get the injection.
    st, resp = post_effort(port, {"model_effort": [{"model": "alpha", "effort": "high"}]})
    check("[S1] model_effort on the engine card is accepted", st == 200,
          "%s %s" % (st, str(resp)[:200]))
    st, body, _ = chat(port, "vm-c", "effort via card")
    echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
    check("[S1] the engine card injects reasoning_effort through the alias",
          st == 200 and echo.get("reasoning_effort") == "high", json.dumps(echo)[:250])
    st, resp = post_effort(port, {"model_effort": []})
    check("[S1] clearing the card turns the injection off again", st == 200,
          "%s %s" % (st, str(resp)[:200]))
    st, body, _ = chat(port, "vm-c", "effort after clear")
    echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
    check("[S1] with no card configured the alias request stays clean",
          st == 200 and echo.get("reasoning_effort") in (None, ""), json.dumps(echo)[:250])

    reset_mock(pg)
    st, body = chat_until(port, "vm-g", "remote key probe")
    echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
    la = last_auth(pg) or {}
    check("[S1] vm-g reaches the gated remote with the stored key",
          st == 200 and echo.get("model") == "remote-g", "%s %s" % (st, json.dumps(echo)[:200]))
    check("[S1] gated mock saw Authorization: Bearer sk-G-123",
          la.get("last_authorization") == "Bearer sk-G-123", json.dumps(la)[:200])

    st, doc = post_profiles(port, [{"model": "vm-dead", "target": "alpha",
                                    "workers": ["http://127.0.0.1:9"]}])
    check("[S1] profile with an unmatchable whitelist is accepted", st == 200,
          "%s %s" % (st, str(doc)[:200]))
    st, body, _ = chat(port, "vm-dead", "empty candidate probe")
    check("[S1] unmatched whitelist answers 503 no_available_workers",
          st == 503 and "no_available_workers" in body, "%s %s" % (st, body[:200]))

    st, doc = post_profiles(port, profiles5)
    check("[S1] re-post of the five profiles 200", st == 200, "%s %s" % (st, str(doc)[:200]))
    doc, cfg = config_doc(port)
    vms = {e.get("model"): e for e in as_list(cfg.get("virtual_models"))}
    check("[S1] document echoes vm-w workers=[url A]",
          vms.get("vm-w", {}).get("workers") == [url_a], json.dumps(vms.get("vm-w"))[:250])
    check("[S1] document echoes vm-b policy / vm-c effort",
          vms.get("vm-b", {}).get("policy") == "prefix_hash"
          and vms.get("vm-c", {}).get("effort") == "high",
          json.dumps([vms.get("vm-b"), vms.get("vm-c")])[:300])
    check("[S1] no lua errors (S1)", "lua entry thread aborted" not in logs(name),
          logs(name)[-300:])
    stop_router(name)


def scenario_env_seed():
    """S1b: LMR_UPSTREAMS_FILE is the boot-time declaration layer (root ruling 5).

    No POST /workers and no SMG_WORKER_URLS here: the only way the endpoint can
    reach the pool is env_upstreams() feeding current().upstreams and the worker-0
    reconcile projecting it, so the scenario is non-trivial by construction. The
    key is set in the seed file, which also makes the read-side masking and the
    forward-side injection observable at the same mock."""
    pg = PORT_SEED[0]
    start_mock_env(pg, "remote-seed", REQUIRE_AUTH=1)
    url_g = "http://127.0.0.1:%d" % pg
    seed_key = "sk-SEED-321"
    seed = write_upstreams_seed([{"url": url_g, "model_id": "remote-seed",
                                  "api_key": seed_key, "priority": 20,
                                  "labels": {"source": "env"}}])
    env = {"SMG_POLICY": "round_robin", "SMG_ENABLE_IGW": "1",
           "NGINX_WORKER_PROCESSES": "1", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
           "LMR_UPSTREAMS_FILE": seed}
    name = "lr-prof-s1seed-%s" % RUN
    port = start_router_mounted(env, name, [seed])
    if not check("[S1] router with LMR_UPSTREAMS_FILE boots",
                 http("GET", "http://127.0.0.1:%d/health" % port, timeout=3)[0] == 200,
                 logs(name)[-300:]):
        stop_router(name)
        return
    check("[S1] the seeded upstream is in the pool at boot",
          wait_urls(port, [url_g], 40), logs(name)[-400:])
    row = workers_by_url(port).get(url_g) or {}
    check("[S1] seeded row carries discovery=config and the declared model_id",
          row.get("discovery") == "config" and row.get("model_id") == "remote-seed",
          json.dumps(row)[:250])
    doc, cfg = config_doc(port)
    ups = {u.get("url"): u for u in as_list(cfg.get("upstreams"))}
    entry = ups.get(url_g) or {}
    check("[S1] document echoes the seed entry masked (api_key null, has_api_key true)",
          entry.get("api_key") is None and entry.get("has_api_key") is True,
          json.dumps(entry)[:250])
    st, wbody, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
    check("[S1] the seed key leaks on no read surface",
          seed_key not in wbody and seed_key not in json.dumps(doc),
          "%s %s" % (st, str(wbody)[:200]))
    st, resp = post_profiles(port, [{"model": "vm-seed", "target": "remote-seed",
                                      "workers": [url_g]}])
    check("[S1] an alias can whitelist the seeded member", st == 200,
          "%s %s" % (st, str(resp)[:200]))
    # Writing the profiles promotes current() (env layer + seed) into the dict
    # snapshot. If the seed had been read from env but not carried into cfg, this
    # is the write that would silently drop it, so re-check both layers here.
    doc, cfg = config_doc(port)
    ups = {u.get("url"): u for u in as_list(cfg.get("upstreams"))}
    check("[S1] the env seed survived the first config write into the dict layer",
          (ups.get(url_g) or {}).get("has_api_key") is True
          and url_g in workers_by_url(port),
          json.dumps([sorted(ups), sorted(workers_by_url(port))])[:300])
    reset_mock(pg)
    st, body = chat_until(port, "vm-seed", "seeded key probe", timeout=40)
    la = last_auth(pg) or {}
    check("[S1] the seeded api_key is injected upstream",
          st == 200 and la.get("last_authorization") == "Bearer " + seed_key,
          "%s %s %s" % (st, body[:120], json.dumps(la)[:200]))
    check("[S1] no lua errors (seed)", "lua entry thread aborted" not in logs(name),
          logs(name)[-300:])
    stop_router(name)


# ================================================================= S2 key lifecycle
def scenario_keyctl():
    pr, pb, pd = PORT_R[0], PORT_B[0], PORT_D[0]
    start_mock_env(pr, "remote-a", REQUIRE_AUTH=1)        # the keyed remote API
    start_mock(pb, "boot-model")                           # SMG_WORKER_URLS member
    start_mock(pd, "dup-m")                                # dedup probe target
    url_r, url_b, url_d = ("http://127.0.0.1:%d" % p for p in (pr, pb, pd))
    name = "lr-prof-s2-%s" % RUN
    env = {"SMG_POLICY": "round_robin", "SMG_ENABLE_IGW": "1", "NGINX_WORKER_PROCESSES": "1",
           "SMG_HEALTH_CHECK_INTERVAL_SECS": "1", "SMG_WORKER_URLS": url_b}
    port = start_router(env, name)
    if not check("[S2] bootstrap worker healthy", wait_ready(port, 1), logs(name)[:300]):
        return
    KEY_A, KEY_B = "sk-A-123", "sk-B-456"

    st, resp = post_upstreams(port, [{"url": url_r, "model_id": "remote-a",
                                       "api_key": KEY_A, "priority": 30,
                                       "labels": {"team": "gpu"}}])
    check("[S2] POST /_ui/config/upstreams 200", st == 200, "%s %s" % (st, str(resp)[:250]))
    check("[S2] reconcile.added == 1", st == 200 and rc_count(resp, "added") == 1,
          json.dumps(resp)[:300] if st == 200 else "")
    check("[S2] upstream worker enters the pool", wait_urls(port, [url_r], 30), logs(name)[:300])

    st, wbody, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
    row = workers_by_url(port).get(url_r) or {}
    check("[S2] /workers shows the config worker with discovery=config",
          st == 200 and row.get("discovery") == "config", json.dumps(row)[:250])
    check("[S2] /workers never leaks the key",
          KEY_A not in wbody and row.get("api_key") in (None, ""), wbody[:250])
    doc, cfg = config_doc(port)
    ups = {u.get("url"): u for u in as_list(cfg.get("upstreams"))}
    entry = ups.get(url_r) or {}
    check("[S2] document entry: api_key null + has_api_key true",
          entry.get("api_key") is None and entry.get("has_api_key") is True,
          json.dumps(entry)[:250])
    check("[S2] /_ui/config leaks no plaintext", KEY_A not in json.dumps(doc), "")
    st, pbody, _ = http("GET", "http://127.0.0.1:%d/_ui/props" % port)
    check("[S2] /_ui/props leaks no plaintext", st == 200 and KEY_A not in pbody,
          "%s %s" % (st, pbody[:200]))

    reset_mock(pr)
    st, body = chat_until(port, "remote-a", "keyed chat probe")
    la = last_auth(pr) or {}
    check("[S2] keyed request answers 200 through the gate", st == 200, "%s %s" % (st, body[:200]))
    check("[S2] remote key injected verbatim",
          la.get("last_authorization") == "Bearer " + KEY_A, json.dumps(la)[:250])

    # null 保留
    reset_mock(pr)
    st, resp = post_upstreams(port, [{"url": url_r, "model_id": "remote-a", "api_key": None}])
    check("[S2] api_key=null accepted", st == 200, "%s %s" % (st, str(resp)[:200]))
    st, body = chat_until(port, "remote-a", "null keeps key")
    la = last_auth(pr) or {}
    check("[S2] null does not wash the key away",
          st == 200 and la.get("last_authorization") == "Bearer " + KEY_A,
          "%s %s %s" % (st, body[:120], json.dumps(la)[:200]))

    # 非空覆盖
    reset_mock(pr)
    st, resp = post_upstreams(port, [{"url": url_r, "model_id": "remote-a", "api_key": KEY_B}])
    st2, body = chat_until(port, "remote-a", "overwritten key")
    la = last_auth(pr) or {}
    check("[S2] a new key replaces the old one",
          st == 200 and st2 == 200 and la.get("last_authorization") == "Bearer " + KEY_B,
          "%s %s %s" % (st, st2, json.dumps(la)[:250]))

    # 空串清除 → 401 透传 + 计数 + has_api_key 翻转
    reset_mock(pr)
    st, resp = post_upstreams(port, [{"url": url_r, "model_id": "remote-a", "api_key": ""}])
    check("[S2] api_key empty string accepted", st == 200, "%s %s" % (st, str(resp)[:200]))
    st, body = chat_until(port, "remote-a", "cleared key probe", want=401, timeout=20)
    la = last_auth(pr) or {}
    check("[S2] cleared key flips the remote to 401 (passthrough)",
          st == 401 and "missing Authorization" in body, "%s %s" % (st, body[:200]))
    check("[S2] the deny is counted at the mock", (la.get("auth_denied") or 0) >= 1,
          json.dumps(la)[:200])
    doc, cfg = config_doc(port)
    ups = {u.get("url"): u for u in as_list(cfg.get("upstreams"))}
    check("[S2] has_api_key false after clearing",
          (ups.get(url_r) or {}).get("has_api_key") is False, json.dumps(ups)[:250])

    # bootstrap url 混入 → 只能 skipped
    st, resp = post_upstreams(port, [{"url": url_r, "model_id": "remote-a", "api_key": ""},
                                      {"url": url_b, "model_id": "hijacked"}])
    check("[S2] a bootstrap url is skipped, never hijacked",
          st == 200 and (rc_count(resp, "skipped") or 0) >= 1, json.dumps(resp)[:300])
    row = workers_by_url(port).get(url_b) or {}
    st, body, _ = chat(port, "boot-model", "boot still routable")
    check("[S2] bootstrap record untouched (model_id kept, traffic fine)",
          row.get("model_id") == "boot-model" and st == 200,
          "%s %s" % (json.dumps(row)[:200], st))

    # 规范化后重复 = 整表拒绝（root 裁定 2）：同批 {url/, url} 必须 400 且 doc/pool 无痕
    st, resp = post_upstreams(port, [{"url": url_r, "model_id": "remote-a", "api_key": ""},
                                      {"url": url_d + "/", "model_id": "dup-m"},
                                      {"url": url_d, "model_id": "dup-m"}])
    check("[S2] duplicate urls after normalization reject the whole write",
          st == 400, "%s %s" % (st, str(resp)[:200]))
    st, wbody, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
    doc, cfg = config_doc(port)
    urls_now = [u.get("url") for u in as_list(cfg.get("upstreams"))]
    check("[S2] the rejected duplicate batch left neither doc nor pool touched",
          url_d not in urls_now and url_d + "/" not in urls_now
          and url_d not in wbody and url_d + "/" not in wbody,
          "doc=%s pool=%s" % (json.dumps(sorted(urls_now))[:200],
                              json.dumps(sorted(workers_by_url(port)))[:200]))

    # 尾斜杠单条（非重复）：规范化入档、入池、真的可服务
    st, resp = post_upstreams(port, [{"url": url_r, "model_id": "remote-a", "api_key": ""},
                                      {"url": url_d + "/", "model_id": "dup-m"}])
    check("[S2] a single trailing-slash url is accepted", st == 200,
          "%s %s" % (st, str(resp)[:200]))
    doc, cfg = config_doc(port)
    ups = {u.get("url"): u for u in as_list(cfg.get("upstreams"))}
    check("[S2] only the normalized spelling is stored",
          url_d in ups and url_d + "/" not in ups, json.dumps(sorted(ups))[:250])
    check("[S2] the pool row carries the normalized url",
          url_d in workers_by_url(port),
          json.dumps(sorted(workers_by_url(port)))[:250])
    check("[S2] the trailing-slash upstream actually serves",
          chat_until(port, "dup-m", "dup probe")[0] == 200, logs(name)[:200])

    # 更新语义：再提交同 url 改 model_id → updated，字段真的进池
    st, resp = post_upstreams(port, [{"url": url_r, "model_id": "remote-a", "api_key": ""},
                                      {"url": url_d, "model_id": "dup-renamed"}])
    check("[S2] re-posting an existing config upstream updates it (updated>=1)",
          st == 200 and (rc_count(resp, "updated") or 0) >= 1, json.dumps(resp)[:300])
    st, body, _ = chat(port, "dup-m", "old id after rename")
    check("[S2] the old model_id stopped routing under igw",
          st != 200, "%s %s" % (st, body[:160]))
    check("[S2] the updated model_id routes",
          chat_until(port, "dup-renamed", "new id probe")[0] == 200, logs(name)[:200])

    # 非法条目整体拒绝（半应用禁止：同车诱饵一个都不许落地）
    decoy = "http://127.0.0.1:%d" % free_port()
    st, resp = post_upstreams(port, [{"url": url_r, "model_id": "remote-a"},
                                      {"url": url_d, "model_id": "dup-m"},
                                      {"url": decoy, "model_id": "m", "priority": "abc"}])
    check("[S2] a non-numeric priority rejects the whole write",
          st == 400, "%s %s" % (st, str(resp)[:200]))
    doc, cfg = config_doc(port)
    urls_now = [u.get("url") for u in as_list(cfg.get("upstreams"))]
    check("[S2] rejected write left neither doc nor pool changed",
          decoy not in urls_now and decoy not in workers_by_url(port),
          json.dumps(sorted(urls_now))[:250])
    many = [{"url": "http://127.0.0.1:%d" % (20000 + i), "model_id": "flood"} for i in range(257)]
    st, resp = post_upstreams(port, many)
    check("[S2] the 256-entry cap answers 400", st == 400, "%s %s" % (st, str(resp)[:160]))

    # 整表清空：只删 config 成员，bootstrap 永远不碰
    st, resp = post_upstreams(port, [])
    ok_r = wait_gone(port, url_r)
    ok_d = wait_gone(port, url_d, timeout=15)
    check("[S2] clearing upstreams removes exactly the two config workers",
          st == 200 and ok_r and ok_d and (rc_count(resp, "removed") or 0) == 2,
          "%s %s r=%s d=%s" % (st, json.dumps(resp)[:200] if isinstance(resp, dict) else resp,
                               ok_r, ok_d))
    st, wbody, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
    # Substring matching against the raw body is broken by cjson's slash escaping
    # ("\/" in the payload), so judge membership off the parsed pool instead.
    check("[S2] the bootstrap worker survives every upstreams edit",
          url_b in workers_by_url(port), wbody[:250])
    check("[S2] no lua errors (S2)", "lua entry thread aborted" not in logs(name), logs(name)[-300:])
    stop_router(name)


# ================================================ S3 watcher immunity + restart
def scenario_immune():
    name = "lr-prof-s3-%s" % RUN
    pc, pc2, pd, pb = PORT_C[0], PORT_C2[0], PORT_DW[0], PORT_BB[0]
    start_mock_env(pc, "remote-c", REQUIRE_AUTH=1)       # keyed remote, unclassifiable
    start_mock(pc2, "config-model")                      # config member, scanned
    found = start_mock(pd, "watch-found")                # watcher-owned, must die
    start_mock(pb, "boot-model")                         # bootstrap control
    url_c, url_c2, url_d, url_b = ("http://127.0.0.1:%d" % p for p in (pc, pc2, pd, pb))
    env = {
        "SMG_POLICY": "round_robin", "NGINX_WORKER_PROCESSES": "1",
        "SMG_HEALTH_CHECK_INTERVAL_SECS": "1", "SMG_WORKER_URLS": url_b,
        "LMR_CONFIG_FILE": "/tmp/lr-profs-%s.json" % RUN,
        "SMG_WATCHER_ENABLED": "1", "SMG_WATCHER_INTERVAL_SECS": "6",
        "SMG_WATCHER_PROBE_TIMEOUT_SECS": "2", "SMG_WATCHER_DOCKER": "0",
        # the shipped default (300 s) is the remove-grace this scenario times;
        # e2e_watcher's cadence keeps it short enough to observe a real purge
        "SMG_WATCHER_REMOVE_GRACE_SECS": "4",
        "SMG_WATCHER_PROC_SCAN": "1",
        # The scan sees only D's port. Ck (keyed remote) and C2 (config member
        # that shares the model id with nothing) stay outside every discovery
        # channel: the watcher never owns, protects, or wants to delete them --
        # surviving >=3 full passes anyway is what pins the ledger-gated purge.
        "SMG_WATCHER_ALLOW_PORT": str(pd),
        # keep-last off so the D teardown below measures the remove grace alone
        # (scenario 4 of e2e_watcher owns guard 6).
        "SMG_WATCHER_KEEP_LAST": "false",
        "SMG_LOG_LEVEL": "notice",
    }
    port = start_router(env, name)
    if not check("[S3] bootstrap healthy", wait_ready(port, 1), logs(name)[:400]):
        return
    st, resp = post_upstreams(port, [
        {"url": url_c, "model_id": "remote-c", "api_key": "sk-C-789"},
        {"url": url_c2, "model_id": "config-idle"},
    ])
    check("[S3] both config upstreams accepted",
          st == 200 and (rc_count(resp, "added") or 0) == 2, "%s %s" % (st, str(resp)[:250]))
    st, doc = post_profiles(port, [{"model": "vm-imm", "target": "remote-c", "workers": [url_c]}])
    check("[S3] profile vm-imm accepted", st == 200, "%s %s" % (st, str(doc)[:200]))

    # 至少两轮回路（>6s*2）之后再看：config 成员必须在，D 必须被扫入
    seen = wait_urls(port, [url_d], timeout=60)
    check("[S3] proc scan discovered the watcher-owned worker D", seen,
          logs(name)[-300:] + "\n" + watch_metrics(port))
    adds = metric_int(port, "lr_watch_adds_total")
    check("[S3] the watcher itself added D (deletion loop is alive, adds=%s)" % adds,
          (adds or 0) >= 1, watch_metrics(port))
    rows = workers_by_url(port)
    check("[S3] config workers survive the watcher sweeps",
          url_c in rows and url_c2 in rows, json.dumps(sorted(rows))[:300])
    # >=3 further passes (interval 6 s, grace 4 s) with the keyed remote and the
    # config member still in the pool -- the ledger-gated immunity at runtime.
    deadline_immune = time.time() + 24
    while time.time() < deadline_immune:
        rows = workers_by_url(port)
        if url_c not in rows or url_c2 not in rows:
            break
        time.sleep(1)
    rows = workers_by_url(port)
    check("[S3] config workers still present after >=4 more passes",
          url_c in rows and url_c2 in rows, json.dumps(sorted(rows))[:300])
    check("[S3] config member fields were never rewritten (model_id kept)",
          (rows.get(url_c2) or {}).get("model_id") == "config-idle",
          json.dumps(rows.get(url_c2))[:250])
    reset_mock(pc)
    st, body = chat_until(port, "vm-imm", "keyed probe through immunity")
    la = last_auth(pc) or {}
    check("[S3] keyed remote routable after the sweeps",
          st == 200 and la.get("last_authorization") == "Bearer sk-C-789",
          "%s %s %s" % (st, body[:120], json.dumps(la)[:200]))

    # --- 契约 3.1 第三触发点：误删自愈。RECONCILE_INTERVAL_SECS 是代码常量
    # (init.lua:107，root 裁定不开 env knob)，所以预算 = 一个完整 tick + 余量。
    victim = (workers_by_url(port).get(url_c2) or {}).get("id")
    if not check("[S3] the config member exposes an id for the control plane",
                 bool(victim), json.dumps(workers_by_url(port).get(url_c2))[:200]):
        return
    st_del, del_body, _ = http("DELETE", "http://127.0.0.1:%d/workers/%s" % (port, victim))
    dropped = st_del in (200, 202) and wait_gone(port, url_c2, timeout=12)
    check("[S3] the manual DELETE really dropped the config member", dropped,
          "%s %s pool=%s" % (st_del, str(del_body)[:150],
                             json.dumps(sorted(workers_by_url(port)))[:200]))
    # The purge must not be attributed to the watcher: c2's port is outside
    # SMG_WATCHER_ALLOW_PORT, so the only writer that can bring it back is the
    # worker-0 upstreams timer (two 30 s ticks + margin).
    before = logs(name)
    back = wait_urls(port, [url_c2], 75)
    after = logs(name)
    fired = after.count("upstreams reconciled") - before.count("upstreams reconciled")
    check("[S3] the self-heal timer re-adds a hand-deleted config member", back,
          "pool=%s reconciled-lines=%d\n%s" % (json.dumps(sorted(workers_by_url(port)))[:250],
                                                fired, after[-500:]))
    if not back:
        # Discriminating probe: force the *apply-time* reconcile with the same
        # declaration. Landing the member here proves the projection works and
        # isolates the gap to the timer's change-detection (config revision vs
        # the applied token); failing here means reconcile itself is broken.
        post_upstreams(port, [{"url": url_c, "model_id": "remote-c", "api_key": None},
                              {"url": url_c2, "model_id": "config-idle"}])
        check("[S3] apply-time reconcile re-adds it (gap isolated to the timer)",
              wait_urls(port, [url_c2], 25), logs(name)[-400:])
    reset_mock(pc)
    st, body = chat_until(port, "vm-imm", "keyed probe after self-heal", timeout=40)
    la = last_auth(pc) or {}
    check("[S3] the self-healed pool still serves the keyed remote",
          st == 200 and la.get("last_authorization") == "Bearer sk-C-789",
          "%s %s %s" % (st, body[:120], json.dumps(la)[:200]))

    # 对照实证「清账真的会删」：杀掉 D，grace 之后必须消失
    stop_mock(found)
    gone = wait_gone(port, url_d, timeout=45)
    removes = metric_int(port, "lr_watch_removes_total")
    check("[S3] watcher deletion machinery works (D purged, removes=%s)" % removes,
          gone and (removes or 0) >= 1, "%s\n%s" % (json.dumps(sorted(workers_by_url(port))),
                                                    watch_metrics(port)))
    # Bring D back on its port: the post-restart rediscovery check below must
    # measure the watcher re-adding it from scratch, not a stale pool row.
    start_mock(pd, "watch-found")
    wait_urls(port, [url_d], timeout=90)

    # --- 重启：shdict 清零，只剩 LMR_CONFIG_FILE 这一层可依赖
    subprocess.run(["docker", "restart", name], capture_output=True)
    deadline = time.time() + 60
    up = False
    while time.time() < deadline:
        if http("GET", "http://127.0.0.1:%d/health" % port, timeout=2)[0] == 200:
            up = True
            break
        time.sleep(0.5)
    if not check("[S3] router back after the restart", up, logs(name)[-300:]):
        return
    back = wait_urls(port, [url_c, url_c2], timeout=60)
    check("[S3] upstreams resurrected from the persisted document", back, logs(name)[-400:])
    doc, cfg = config_doc(port)
    vms = {e.get("model"): e for e in as_list(cfg.get("virtual_models"))}
    ups = {u.get("url"): u for u in as_list(cfg.get("upstreams"))}
    check("[S3] alias + upstream entries survived the restart (has_api_key kept)",
          "vm-imm" in vms and (ups.get(url_c) or {}).get("has_api_key") is True,
          json.dumps([vms.get("vm-imm"), ups.get(url_c)])[:350])
    reset_mock(pc)
    st, body = chat_until(port, "vm-imm", "post-restart keyed probe", timeout=40)
    la = last_auth(pc) or {}
    check("[S3] the key survived persistence too (200 + correct bearer)",
          st == 200 and la.get("last_authorization") == "Bearer sk-C-789",
          "%s %s %s" % (st, body[:120], json.dumps(la)[:200]))
    check("[S3] watcher re-discovers D after the restart",
          wait_urls(port, [url_d], timeout=90),
          logs(name)[-300:] + "\n" + watch_metrics(port))
    check("[S3] no lua errors (S3)", "lua entry thread aborted" not in logs(name), logs(name)[-300:])
    stop_router(name)


# ================================================================= S4 apply document
def scenario_apply():
    name = "lr-prof-s4-%s" % RUN
    pg, p1, p2 = PORT_X[0], PORT_G1[0], PORT_G2[0]
    start_mock_env(pg, "remote-x", REQUIRE_AUTH=1)
    start_mock(p1, "gamma")
    start_mock(p2, "gamma")
    url_g, url_1, url_2 = ("http://127.0.0.1:%d" % p for p in (pg, p1, p2))
    env = {"SMG_POLICY": "round_robin", "SMG_ENABLE_IGW": "1", "NGINX_WORKER_PROCESSES": "1",
           "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
           "SMG_WORKER_URLS": "%s,%s" % (url_1, url_2)}
    port = start_router(env, name)
    if not check("[S4] gamma mocks healthy", wait_ready(port, 2), logs(name)[:300]):
        return
    deadline = time.time() + 30
    while time.time() < deadline:
        rows = workers_by_url(port)
        if all((rows.get(u) or {}).get("model_id") == "gamma" for u in (url_1, url_2)):
            break
        time.sleep(0.5)

    st, resp = post_apply(port, {
        "default_effort": None,
        "virtual_models": [{"model": "vm-doc", "target": "remote-x", "workers": [url_g],
                            "policy": "prefix_hash", "effort": "medium"}],
        "upstreams": [{"url": url_g, "model_id": "remote-x", "api_key": "sk-X-999"}],
    })
    check("[S4] apply with both new sections answers 200", st == 200, "%s %s" % (st, str(resp)[:250]))
    check("[S4] apply response carries the reconcile summary",
          st == 200 and (rc_count(resp, "added") or 0) == 1, json.dumps(resp)[:300])
    check("[S4] the applied upstream reaches the pool", wait_urls(port, [url_g], 30), logs(name)[:300])
    doc, cfg = config_doc(port)
    vms = {e.get("model"): e for e in as_list(cfg.get("virtual_models"))}
    ups = {u.get("url"): u for u in as_list(cfg.get("upstreams"))}
    check("[S4] document echoes profile fields + masked upstream",
          vms.get("vm-doc", {}).get("policy") == "prefix_hash"
          and vms.get("vm-doc", {}).get("workers") == [url_g]
          and (ups.get(url_g) or {}).get("has_api_key") is True
          and (ups.get(url_g) or {}).get("api_key") is None,
          json.dumps([vms.get("vm-doc"), ups.get(url_g)])[:350])
    reset_mock(pg)
    st, body = chat_until(port, "vm-doc", "apply end-to-end")
    echo = json.loads(body).get("echo_body", {}) if st == 200 else {}
    la = last_auth(pg) or {}
    check("[S4] vm-doc reaches the gated remote with the applied key",
          st == 200 and echo.get("model") == "remote-x"
          and la.get("last_authorization") == "Bearer sk-X-999",
          "%s %s %s" % (st, json.dumps(echo)[:150], json.dumps(la)[:200]))

    # 无效整体拒绝：坏 alias→alias 与「洗 key + 诱饵 upstream」同车 → 400 全无痕迹
    decoy = "http://127.0.0.1:%d" % free_port()
    st, resp = post_apply(port, {
        "virtual_models": [{"model": "vm-doc", "target": "remote-x", "workers": [url_g],
                            "policy": "prefix_hash", "effort": "medium"},
                           {"model": "vm-bad", "target": "vm-doc"}],
        "upstreams": [{"url": url_g, "model_id": "remote-x", "api_key": ""},
                      {"url": decoy, "model_id": "decoy-m"}],
    })
    check("[S4] alias pointing at another alias rejects the whole apply",
          st == 400, "%s %s" % (st, str(resp)[:250]))
    doc, cfg = config_doc(port)
    vms = {e.get("model"): e for e in as_list(cfg.get("virtual_models"))}
    ups = [u.get("url") for u in as_list(cfg.get("upstreams"))]
    st, wbody, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
    reset_mock(pg)
    st2, body2 = chat_until(port, "vm-doc", "key survives the rejected write", timeout=10)
    la = last_auth(pg) or {}
    check("[S4] rejected apply left no half-state anywhere",
          "vm-bad" not in vms and decoy not in ups and decoy not in wbody,
          json.dumps([sorted(vms), sorted(ups)])[:300])
    check("[S4] the co-committed key wash was rejected too (200 + old bearer)",
          st2 == 200 and la.get("last_authorization") == "Bearer sk-X-999",
          "%s %s" % (st2, json.dumps(la)[:200]))

    st, resp = post_apply(port, {"virtual_models": [{"model": "vm-x", "target": "gamma",
                                                     "policy": "bogus_policy"}]})
    check("[S4] an unknown profile policy is rejected 400", st == 400, "%s %s" % (st, str(resp)[:200]))
    st, resp = post_profiles(port, [{"model": "vm-legacy", "target": "gamma"}])
    st2, body2, _ = chat(port, "vm-legacy", "legacy alias probe")
    check("[S4] legacy {model,target} still accepted and routable",
          st == 200 and st2 == 200, "%s %s %s %s" % (st, str(resp)[:120], st2, body2[:120]))
    check("[S4] no lua errors (S4)", "lua entry thread aborted" not in logs(name), logs(name)[-300:])
    stop_router(name)


# ---------------------------------------------------------------------------
# Ports are chosen once so every helper above can reference them; the mocks are
# started inside the scenarios (host processes, cheap).
PORT_R, PORT_B, PORT_D = [free_port()], [free_port()], [free_port()]
PORT_C, PORT_C2, PORT_DW, PORT_BB = [free_port()], [free_port()], [free_port()], [free_port()]
PORT_X, PORT_G1, PORT_G2 = [free_port()], [free_port()], [free_port()]
PORT_SEED = [free_port()]


def main():
    os.makedirs(TMP, exist_ok=True)
    scenario_whitelist()
    scenario_env_seed()
    scenario_keyctl()
    scenario_immune()
    scenario_apply()
    failed = [r for r in RESULTS if not r[0]]
    print("\n=== e2e_profiles: %d checks, %d failed ===" % (len(RESULTS), len(failed)))
    for _, name, detail in failed:
        print("FAILED: %s | %s" % (name, (detail or "")[:400]))
    cleanup()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
