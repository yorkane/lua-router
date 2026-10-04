#!/usr/bin/env python3
"""e2e：/v1/models 的对外形状过一遍真 HTTP（采集链路 + 输出合成的接线证明）。

跑法（门禁纪律：host 网络 + lr- 前缀容器，严禁与其它门禁并发；跑前 ps 查）：
    python3 test/integration/e2e_models_advertisement.py

与 test/unit/test_models_shape.lua 的分工：那份钉**输出层的纪律**（把真源码切出来配桩
加载，无端口、可并发），这份钉**采集链路真的把上游原文留住了**——mock 的富形状要经过
registry 的探针 + 归一化 + shdict 落盘 + router 的合成，任何一环断掉，扩展字段就整体
缺席。只有 unit 那份会漏掉"探针根本没调 model_caps_from_listing"这类接线错误。

判别性（LR_LEGACY_LUALIB=<改动前的 lualib 目录> 时把那份旧树挂到 /repo/lualib 上跑同一
组断言；预期 S1 的 created / S2 全部 / S3 的负断言假绿 / S4 全部 / S5 的能力聚合全红）：
  S1  官方 required 四字段：真实模型行与入口行**每一行**都必须带齐
      id/object/created/owned_by。改动前真实模型那一支整个漏了 created（本次修的真 bug），
      所以"逐行 has(...)"这一条在旧实现下必然红。
  S2  扩展字段被真正填上：mock 报的 context_length / max_output_tokens / 模态 /
      supports_* / 档位阶梯（含 default:true 那一档）/ 判定面，网关必须**如实**透出。
      判别性的另一半：同一个场景跑两遍，mock 分别报 1000000 与 262144，断言跟着变，
      证明这个数是引擎给的而不是网关造的。
  S3  省略而不是 null：引擎没说的字段必须**键不存在**，不是 null、也不是 [] 冒充。
  S4  优先级：操作员 config 声明（卡片 ctx / context_limit）压过引擎自报，且引擎那个值
      在响应里**一个字都不出现**。
  S5  虚拟入口的老口径不坏：单目标 owned_by == llm-router-><名>、多目标 == llm-router +
      owned_by_models、created 恒 0；入口行的能力来自组内聚合。
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (RUN, RESULTS, REPO, TMP, PIDS, CONTAINERS, free_port, http, check,
                  logs, cleanup)

# conf 的 listen 写死 8080，端口靠 -p 127.0.0.1::8080 随机发布；亲和树是每进程的，
# 钉成 1 个 worker 进程才有确定性。与 e2e_caps 同一形态：跑**盘上的 lualib**。
BASE_ENV = {
    "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
    "SMG_HEALTH_CHECK_IDLE_SECS": "0",   # 空闲跳探会让"引擎改了口"永远传不上来
    "NGINX_WORKER_PROCESSES": "1",
    "SMG_LOG_LEVEL": "warn",
}
GATEWAY_FALLBACK = "172.17.0.1"
BASE_IMAGE = os.environ.get("OPENRESTY_TEST_IMAGE", "authz:latest")
LEGACY_LUALIB = os.environ.get("LR_LEGACY_LUALIB", "")


def start_mock_env(port, model, env=None):
    """Boot mock_llm_worker.py with extra env (MODELS_RICH / MODELS_CAPS_JSON)."""
    log = open("%s/mock-%s.log" % (TMP, port), "w")
    merged = dict(os.environ, LR_MOCK_LOG="1", MODEL=model)
    merged.update({k: str(v) for k, v in (env or {}).items()})
    p = subprocess.Popen([sys.executable, REPO + "/test/mock_llm_worker.py",
                          "--host", "0.0.0.0", "--port", str(port), "--model", model],
                         stdout=log, stderr=subprocess.DEVNULL, env=merged)
    PIDS.append(p)
    for _ in range(80):
        st, _, _ = http("GET", "http://127.0.0.1:%d/health" % port, timeout=2)
        if st == 200:
            return p
        time.sleep(0.1)
    raise RuntimeError("mock %s never came up" % port)


def start_conf(env, tag):
    """Serve test/conf/nginx-lua-router.conf; return (port, name, gw)."""
    name = "lr-%s-%s" % (tag[:26], RUN)
    full = dict(BASE_ENV)
    full.update({k: str(v) for k, v in (env or {}).items()})
    args = ["docker", "run", "-d", "--name", name,
            "-p", "127.0.0.1::8080", "-v", REPO + ":/repo:ro"]
    if LEGACY_LUALIB:
        # 判别性通道：把改动前的整棵 lualib 盖在盘上那份之上（lua_package_path 第一位
        # 就是 /repo/lualib），同一组断言跑在旧实现上。
        args += ["-v", LEGACY_LUALIB + ":/repo/lualib:ro"]
    for k, v in full.items():
        args += ["-e", "%s=%s" % (k, v)]
    args += ["--entrypoint", "openresty", BASE_IMAGE,
             "-p", "/usr/local/openresty/nginx/", "-c", "/repo/test/conf/nginx-lua-router.conf",
             "-g", "daemon off;"]
    subprocess.run(args, check=True, capture_output=True)
    CONTAINERS.append(name)
    hostport = None
    for _ in range(60):
        out = subprocess.run(["docker", "port", name, "8080"],
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
            break
        time.sleep(0.2)
    out = subprocess.run(
        ["docker", "inspect", "-f",
         "{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}", name],
        capture_output=True)
    gw = out.stdout.decode().strip() or GATEWAY_FALLBACK
    return hostport, name, gw


def stop(name):
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)


def workers_by_url(port):
    st, body, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
    if st != 200:
        return {}
    return {w.get("url"): w for w in json.loads(body).get("workers", [])}


def wait_healthy(port, urls, timeout=40):
    deadline = time.time() + timeout
    while time.time() < deadline:
        rows = workers_by_url(port)
        if all(u in rows and rows[u].get("is_healthy") for u in urls):
            return True
        time.sleep(0.3)
    return False


def models_doc(port):
    st, body, _ = http("GET", "http://127.0.0.1:%d/v1/models" % port)
    if st != 200:
        return st, None, body
    return st, json.loads(body), body


def row(doc, model_id):
    for entry in (doc or {}).get("data", []):
        if entry.get("id") == model_id:
            return entry
    return None


REQUIRED = ("id", "object", "created", "owned_by")
EXTENSION_KEYS = ("capabilities", "reasoning_efforts", "reasoning_effort",
                  "supports_reasoning_effort")


def caps_of(entry):
    caps = (entry or {}).get("capabilities")
    return caps if isinstance(caps, dict) else {}


def wait_caps(port, model_id, timeout=30):
    """等采集链路把该模型的 capabilities 送到对外表面。

    采集发生在健康巡检里（interval=1 s），异步于注册，所以"第一次请求就有"不是可依赖
    的事实；不等到就断言字段缺席，测的会是时序而不是实现。返回是否等到，调用方必须
    把它并进断言（否则"没采到"会被后面的缺席断言当成通过）。
    """
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        st, doc, last = models_doc(port)
        if doc and caps_of(row(doc, model_id)):
            return True
        time.sleep(0.4)
    print("    (wait_caps gave up on %s; last body=%s)" % (model_id, str(last)[:300]))
    return False


# ============================================================ S1 required 四字段
def scenario_required_fields():
    """一个普通 worker（mock 不报任何能力）：每一行都必须带齐官方四个字段。"""
    tag = "S1-required"
    pm = free_port()
    start_mock_env(pm, "plain-model")
    port, name, gw = start_conf({}, tag)
    url = "http://%s:%d" % (gw, pm)
    st, _ = post_worker(port, url, "plain-model")
    check("[%s] worker registered" % tag, st in (200, 202), str(st))
    check("[%s] worker healthy" % tag, wait_healthy(port, [url]), logs(name)[:400])
    # 入口行也要一起判：它没有引擎，created 的取值来源完全不同。
    st, doc = post_json(port, "/_ui/config/virtual",
                        {"entries": [{"model": "vm-plain", "target": "plain-model"}]})
    check("[%s] virtual entry accepted" % tag, st == 200, "%s %s" % (st, str(doc)[:200]))
    st, doc, raw = models_doc(port)
    check("[%s] /v1/models 200" % tag, st == 200, "%s %s" % (st, raw[:200]))
    data = (doc or {}).get("data", [])
    check("[%s] 列表非空且含真实行与入口行" % tag,
          len(data) >= 2 and row(doc, "plain-model") and row(doc, "vm-plain"), raw[:300])
    missing = {e.get("id"): [k for k in REQUIRED if k not in e] for e in data
               if [k for k in REQUIRED if k not in e]}
    check("[%s] 每一行都带齐 id/object/created/owned_by（逐行，不只第一条）" % tag,
          not missing, json.dumps(missing))
    check("[%s] created 是非负整数" % tag,
          all(isinstance(e.get("created"), int) and e["created"] >= 0 for e in data),
          json.dumps([e.get("created") for e in data]))
    check("[%s] object 恒为 model" % tag,
          all(e.get("object") == "model" for e in data),
          json.dumps([e.get("object") for e in data]))
    # 省略纪律的另一半：没有数据源时**只有**四个键（多出来的键必须来自某个数据源）。
    extra = {e.get("id"): sorted(set(e) - set(REQUIRED)) for e in data
             if set(e) - set(REQUIRED)}
    check("[%s] 无能力数据时该行只有 required 四个键" % tag, not extra, json.dumps(extra))
    check("[%s] 响应里搜不到 JSON null" % tag, "null" not in raw, raw[:300])
    check("[%s] 真实行 owned_by 仍是 local" % tag,
          (row(doc, "plain-model") or {}).get("owned_by") == "local", raw[:200])
    check("[%s] 入口行 owned_by 走老口径 llm-router->plain-model" % tag,
          (row(doc, "vm-plain") or {}).get("owned_by") == "llm-router->plain-model",
          raw[:200])
    check("[%s] 入口行 created 恒 0" % tag,
          (row(doc, "vm-plain") or {}).get("created") == 0, raw[:200])
    check_no_abort(tag, name)
    stop(name)


def post_worker(port, url, model_id):
    return post_json(port, "/workers", {"url": url, "model_id": model_id})


def post_json(port, path, body):
    st, text, _ = http("POST", "http://127.0.0.1:%d%s" % (port, path), body)
    try:
        return st, json.loads(text)
    except ValueError:
        return st, text


def check_no_abort(tag, name):
    r = subprocess.run(["docker", "logs", name], capture_output=True)
    text = r.stderr.decode() + r.stdout.decode()
    check("[%s] 网关日志无 lua entry thread aborted" % tag,
          "lua entry thread aborted" not in text, text[-400:])


# ================================================== S2 采集链路把能力带出来
def scenario_capabilities(advertised_ctx):
    """mock 报富形状，网关必须如实透出；advertised_ctx 变化时对外读数跟着变。

    判别性：同一份断言在 advertised_ctx = 1000000 / 262144 两次跑里期望值不同。
    写死一个数、或者网关自己造一个数，两次必有一次红。
    """
    tag = "S2-ctx%s" % advertised_ctx
    pm = free_port()
    caps_json = {"capabilities": {"context_length": advertised_ctx}}
    start_mock_env(pm, "rich-model",
                   {"MODELS_RICH": "1", "MODELS_CAPS_JSON": json.dumps(caps_json)})
    port, name, gw = start_conf({}, tag)
    url = "http://%s:%d" % (gw, pm)
    st, _ = post_worker(port, url, "rich-model")
    check("[%s] worker registered" % tag, st in (200, 202), str(st))
    check("[%s] worker healthy" % tag, wait_healthy(port, [url]), logs(name)[:400])
    got_caps = wait_caps(port, "rich-model")
    st, doc, raw = models_doc(port)
    e = row(doc, "rich-model") or {}
    caps = caps_of(e)
    check("[%s] 采集链路把 capabilities 带出来了" % tag, bool(caps) and got_caps,
          raw[:400])
    check("[%s] context_length = 引擎报的 %d" % (tag, advertised_ctx),
          caps.get("context_length") == advertised_ctx,
          "%r of %s" % (caps.get("context_length"), raw[:300]))
    check("[%s] max_output_tokens = 引擎报的 128000" % tag,
          caps.get("max_output_tokens") == 128000, json.dumps(caps)[:300])
    check("[%s] input_modalities 如实透出且顺序保留" % tag,
          caps.get("input_modalities") == ["text", "image"], json.dumps(caps)[:300])
    check("[%s] output_modalities 如实透出" % tag,
          caps.get("output_modalities") == ["text"], json.dumps(caps)[:300])
    check("[%s] 四个 supports_* 都是 true" % tag,
          all(caps.get(k) is True for k in ("supports_tool_use", "supports_streaming",
                                            "supports_reasoning", "supports_vision")),
          json.dumps(caps)[:300])
    ladder = e.get("reasoning_efforts") or []
    check("[%s] picker 阶梯 = 引擎给的 4 档且带 label" % tag,
          [r.get("value") for r in ladder] == ["low", "medium", "high", "max"]
          and ladder[0].get("label") == "Low Effort", json.dumps(ladder)[:300])
    marked = [r.get("value") for r in ladder if r.get("default") is True]
    check("[%s] 阶梯里恰好一个 default:true 且落在 medium" % tag,
          marked == ["medium"], json.dumps(ladder)[:300])
    check("[%s] 顶层 reasoning_effort 与阶梯的 default 自洽" % tag,
          e.get("reasoning_effort") == "medium", json.dumps(e)[:300])
    check("[%s] 顶层 supports_reasoning_effort 为 true" % tag,
          e.get("supports_reasoning_effort") is True, json.dumps(e)[:300])
    # 判定面与 picker 是两个含义：引擎自己就给的不一致（阶梯 4 档、判定面 3 档），
    # 网关把 medium 抬进判定面就是过度声称，这一条专门钉它。
    check("[%s] 判定面 = 引擎亲口说的 3 档，不掺阶梯里的 medium" % tag,
          caps.get("reasoning_effort") == ["low", "high", "max"],
          json.dumps(caps)[:300])
    check("[%s] created 用引擎的读数而不是 0" % tag, e.get("created") == 1700000000,
          json.dumps(e)[:200])
    check("[%s] 真实行的 owned_by 仍是 local（引擎自报不上外）" % tag,
          e.get("owned_by") == "local", json.dumps(e)[:200])
    check("[%s] 响应里没有 JSON null" % tag, "null" not in raw, raw[:300])
    check_no_abort(tag, name)
    stop(name)


# ================================================== S3 省略而不是 null
def scenario_omission():
    """引擎把几个维度删掉后，对外必须是键不存在，不是 null、也不是 [] / {} 冒充。"""
    tag = "S3-omit"
    pm = free_port()
    # Every capability the rich template advertises is deleted, INCLUDING the three
    # top-level effort keys: the gateway must not resurrect any of them from nowhere.
    # created stays (the engine really said when the model was made), so this row
    # proves "we captured something and it carried no capability" rather than "we
    # never probed at all" -- the two look identical from outside and only the first
    # is the omission rule under test.
    override = {"capabilities": {"context_length": None, "max_output_tokens": None,
                                 "input_modalities": None, "output_modalities": None,
                                 "supports_vision": None, "supports_tool_use": None,
                                 "supports_streaming": None,
                                 "supports_reasoning": None,
                                 "reasoning_effort": None},
                "reasoning_efforts": None,
                "reasoning_effort": None,
                "supports_reasoning_effort": None}
    start_mock_env(pm, "sparse-model",
                   {"MODELS_RICH": "1", "MODELS_CAPS_JSON": json.dumps(override)})
    port, name, gw = start_conf({}, tag)
    url = "http://%s:%d" % (gw, pm)
    st, _ = post_worker(port, url, "sparse-model")
    check("[%s] worker registered" % tag, st in (200, 202), str(st))
    check("[%s] worker healthy" % tag, wait_healthy(port, [url]), logs(name)[:400])
    # 采集窗口：让巡检至少跑一轮（interval=1 s），否则"字段缺席"可能只是探针还没答完。
    time.sleep(3.0)
    st, doc, raw = models_doc(port)
    e = row(doc, "sparse-model") or {}
    caps = caps_of(e)
    check("[%s] 行仍在且 required 四字段齐" % tag,
          all(k in e for k in REQUIRED) and e.get("id") == "sparse-model",
          raw[:300])
    leaked = {k: e[k] for k in EXTENSION_KEYS if k in e}
    check("[%s] 没有任何一行凭空长出扩展键" % tag, not leaked, json.dumps(e)[:300])
    check("[%s] capabilities 整块缺席（引擎没说 = 不报，而不是报空）" % tag,
          "capabilities" not in raw, raw[:300])
    # An empty array/object is a POSITIVE answer ("supports nothing"), which is not
    # what "the engine never said" means, so neither spelling may appear. Compact
    # first: the encoder's whitespace is not part of the contract.
    compact = raw.replace(" ", "").replace("\n", "")
    check("[%s] 没有用 [] / {} 冒充「这个维度没有数据」" % tag,
          ":[]" not in compact and ":{}" not in compact, raw[:400])
    check("[%s] 整份响应里没有 null" % tag, "null" not in raw, raw[:400])
    check_no_abort(tag, name)
    stop(name)


# ================================================== S4 config 声明压过引擎
def scenario_config_priority():
    """操作员卡片的读数必须压过引擎自报，且引擎那个数在响应里一个字都不出现。"""
    tag = "S4-priority"
    pm = free_port()
    start_mock_env(pm, "rich-model",
                   {"MODELS_RICH": "1",
                    "MODELS_CAPS_JSON": json.dumps(
                        {"capabilities": {"context_length": 1000000}})})
    port, name, gw = start_conf({}, tag)
    url = "http://%s:%d" % (gw, pm)
    st, _ = post_worker(port, url, "rich-model")
    check("[%s] worker registered" % tag, st in (200, 202), str(st))
    check("[%s] worker healthy" % tag, wait_healthy(port, [url]), logs(name)[:400])
    wait_caps(port, "rich-model")
    st, doc, raw = models_doc(port)
    engine = caps_of(row(doc, "rich-model")).get("context_length")
    check("[%s] 写入前引擎读数确实是 1000000" % tag, engine == 1000000,
          "%r of %s" % (engine, raw[:300]))
    st, doc = post_json(port, "/_ui/config/model",
                        {"model": "rich-model", "ctx": 524288,
                         "context_limit": 300000, "modalities": ["text", "image", "video"],
                         "default_effort": "high"})
    check("[%s] POST /_ui/config/model 卡片被接受" % tag, st == 200,
          "%s %s" % (st, str(doc)[:300]))
    # 快照有 0.5 s 的 worker 侧 TTL，给一次重试窗口而不是直接判死。
    deadline = time.time() + 12
    st, doc, raw = models_doc(port)
    e = row(doc, "rich-model") or {}
    while time.time() < deadline and caps_of(e).get("context_length") != 524288:
        time.sleep(0.5)
        st, doc, raw = models_doc(port)
        e = row(doc, "rich-model") or {}
    caps = caps_of(e)
    check("[%s] 卡片 ctx 压过引擎：对外 context_length = 524288" % tag,
          caps.get("context_length") == 524288, json.dumps(e)[:400])
    check("[%s] 引擎自报的 1000000 在整份响应里一个字都不出现" % tag,
          "1000000" not in raw, raw[:400])
    check("[%s] 卡片模态压过引擎模态" % tag,
          caps.get("input_modalities") == ["text", "image", "video"],
          json.dumps(caps)[:300])
    check("[%s] 卡片 default_effort 决定对外缺省档" % tag,
          e.get("reasoning_effort") == "high", json.dumps(e)[:300])
    ladder = e.get("reasoning_efforts") or []
    marked = [r.get("value") for r in ladder if r.get("default") is True]
    check("[%s] default:true 只落在 high 那一档" % tag, marked == ["high"],
          json.dumps(ladder)[:300])
    # 每个维度独立取源：操作员没声明 max_output_tokens，它必须仍是引擎那个数。
    check("[%s] 操作员没声明的维度仍取引擎读数" % tag,
          caps.get("max_output_tokens") == 128000, json.dumps(caps)[:300])
    check_no_abort(tag, name)
    stop(name)


# ================================================== S5 虚拟入口形状
def scenario_virtual_entries():
    """入口行的老口径（有客户端在读）与组内聚合能力。"""
    tag = "S5-entry"
    pa, pb = free_port(), free_port()
    start_mock_env(pa, "alpha", {"MODELS_RICH": "1"})
    start_mock_env(pb, "beta", {"MODELS_RICH": "1"})
    port, name, gw = start_conf({}, tag)
    url_a, url_b = "http://%s:%d" % (gw, pa), "http://%s:%d" % (gw, pb)
    st, _ = post_worker(port, url_a, "alpha")
    st2, _ = post_worker(port, url_b, "beta")
    check("[%s] both workers registered" % tag,
          st in (200, 202) and st2 in (200, 202), "%s/%s" % (st, st2))
    check("[%s] both healthy" % tag, wait_healthy(port, [url_a, url_b]), logs(name)[:400])
    got_a = wait_caps(port, "alpha")
    got_b = wait_caps(port, "beta")
    check("[%s] 两台引擎的能力读数都被采到了" % tag, got_a and got_b, logs(name)[:300])
    st, doc = post_json(port, "/_ui/config/virtual", {"entries": [
        {"model": "vm-one", "target": "alpha"},
        {"model": "vm-group", "targets": ["alpha", "beta"]}]})
    check("[%s] both entries accepted" % tag, st == 200, "%s %s" % (st, str(doc)[:300]))
    st, doc, raw = models_doc(port)
    one = row(doc, "vm-one")
    grp = row(doc, "vm-group")
    check("[%s] 两个入口都在广告里" % tag, one is not None and grp is not None, raw[:300])
    check("[%s] 单目标 owned_by == llm-router->alpha" % tag,
          (one or {}).get("owned_by") == "llm-router->alpha", json.dumps(one)[:250])
    check("[%s] 单目标不列 owned_by_models" % tag,
          "owned_by_models" not in (one or {}), json.dumps(one)[:250])
    check("[%s] 单目标 created 恒 0" % tag, (one or {}).get("created") == 0,
          json.dumps(one)[:250])
    check("[%s] 多目标 owned_by == llm-router" % tag,
          (grp or {}).get("owned_by") == "llm-router", json.dumps(grp)[:250])
    check("[%s] 多目标 owned_by_models 是组内目标列表" % tag,
          (grp or {}).get("owned_by_models") == ["alpha", "beta"], json.dumps(grp)[:250])
    check("[%s] 多目标 created 恒 0（不继承成员）" % tag,
          (grp or {}).get("created") == 0, json.dumps(grp)[:250])
    for which, entry in (("单目标", one), ("多目标", grp)):
        check("[%s] %s入口行也带齐 required 四字段" % (tag, which),
              entry is not None and all(k in entry for k in REQUIRED),
              json.dumps(entry)[:250])
    caps = caps_of(grp)
    check("[%s] 入口行能力来自组内聚合（context_length 1000000）" % tag,
          caps.get("context_length") == 1000000, json.dumps(grp)[:400])
    check("[%s] 入口行 picker 与成员一致" % tag,
          [r.get("value") for r in (grp or {}).get("reasoning_efforts") or []]
          == ["low", "medium", "high", "max"], json.dumps(grp)[:400])
    # 单成员入口就是那台引擎本身：同一模型在真实行与入口行不许说两种能力。
    real = caps_of(row(doc, "alpha"))
    check("[%s] 单目标入口与真实行口径一致（同一台引擎不许两套说法）" % tag,
          caps_of(one).get("context_length") == real.get("context_length")
          and caps_of(one).get("max_output_tokens") == real.get("max_output_tokens"),
          json.dumps([caps_of(one), real])[:400])
    check("[%s] 响应里没有 JSON null" % tag, "null" not in raw, raw[:300])
    # id 的取值集合不许被入口行污染：真实行 + 两个入口，一共三行。
    check("[%s] data 行数 = 真实模型 2 + 入口 2" % tag,
          len((doc or {}).get("data", [])) == 4,
          json.dumps([d.get("id") for d in (doc or {}).get("data", [])])[:250])
    check_no_abort(tag, name)
    stop(name)


def main():
    print("[e2e_models_advertisement] legacy tree = %s" % (LEGACY_LUALIB or "off"))
    scenario_required_fields()
    scenario_capabilities(1000000)
    scenario_capabilities(262144)
    scenario_omission()
    scenario_config_priority()
    scenario_virtual_entries()
    failed = [r for r in RESULTS if not r[0]]
    print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
    for _, name, detail in failed:
        print("FAILED: %s | %s" % (name, detail[:400]))
    cleanup()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
