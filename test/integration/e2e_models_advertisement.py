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
  S6  组内**有一台没给长度读数**时入口行必须删键：入口对外广告的窗口是客户端决定塞多少
      token 的依据，而请求会被策略派给组内任意一台。一台没读数 = 网关不知道那台装得下多少
      （不等于「那台装得下且更宽」），此时照报另一台的读数就是替不知底细的引擎担保。
      2026-10-04 生产 235.t:8800 的 Qn 入口即由此对外广告了 1000000（组里 Q38 那一半当时
      一个长度读数都没有）。S6 里都有读数时照报最窄的对照断言与之成对，防止修过头。
  S7  /v1/models 的广告面开关 models_virtual_only（实现 030dab5）的**关闭态**：布尔 false、
      字符串 false/0/off、垃圾串、空串、数字 0、键缺失、键为 null 共九档，逐档要求响应
      字节与基准**逐字节相等**且非空。开关被写成「非假即真」、或 truthy 少认/多认一档，
      对应那一档就红（实测：把 truthy 改成 ~= "false" 的变异体下，字符串 0/off/垃圾串/空串
      四档一起红）。这组另带一条正向对照（同一份挂载里写 true 必须真的切成只广告入口），
      没有它，"九档全等于基准" 可能只是磁盘通道根本没通 = 一组恒真断言。
  S8  开关**开**：data[].id 恰为入口名列表，一条真实模型 id 都不许出现，且整份响应里
      owned_by == "local" 这个真实行指纹都不许残留（旁挂字段也算泄漏）。判别性靠同场景的
      反向对照钉住「只影响广告、不影响路由」：/workers 仍列出两台、按真实模型名直发
      /v1/chat/completions 仍 200、开关拨回 false 后真实行必须回来。
  S9  开关开但一条入口都装配不出来 -> 退回全量广告并 WARN 一行，绝不交空列表（静默清空
      等于让客户端以为整个服务消失了）。WARN 那条在旧实现下必红（它没有这个分支）；把
      only_data 的 nil 写成 {} 的变异体下，data[] 非空 / 真实行仍在 / 四字段齐 三条一起红。
  S10 两层读数是**优先级**而不是 OR：env=true + 磁盘=false 时真实模型行必须仍在；另一台
      容器只设 env（磁盘根本没有文件）则必须能只广告入口，钉住 LMR_MODELS_VIRTUAL_ONLY 在
      config_store.ENV_NAMES 里那行 —— 名册删了它，worker 里 os.getenv 读到 nil，这条红。
      写成 from_disk() or from_env() 那种 OR 的实现下第一条红（实测 data[].id 只剩入口）。
  S11 操作员**启动前**写好的那份配置文件单独就能决定对外广告什么（入口组 + 开关），全程
      不调任何配置写接口，并断言那份文件的字节没被网关改写。它是 S8 的补集：S8 是跑起来
      之后用 POST 建入口、最后拨开关，那份形状里 shdict 层先有内容。
  判别性总表（S7-S11 五个场景共 86 项，同一份断言跑在 LR_LEGACY_LUALIB 指向的六棵树上，
  盘上实现 0 红；变异体都是 /data/tmp 下的 lualib 副本，仓里源码未动）：
      改动前 router.lua（030dab5~1）      11 红（S7 正向对照×2、S8×4、S9 WARN、S10 env、S11×3）
      truthy 写成「非假即真」              4 红（S7 的 字符串 0/off/垃圾串/空串 四档）
      only_data 拿不到入口交空表            4 红（S9 全部）
      退回全量那一支改成交空 data           4 红（S9 全部）
      两层读数写成 OR                      1 红（S10 磁盘压过 env）
      config_store 不认这个键（3728821 前） 3 红（S10 env、S11 活过保存的磁盘半与对外半）
      旧实现下 S7 的九档与 S9 的三条守卫**应当**绿——它们钉的是不许被坏掉的老契约。
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
    st, doc = post_json(port, "/config/virtual",
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






def get_json_cfg(port):
    """GET /config -> (status, decoded document)."""
    st, body, _ = http("GET", "http://127.0.0.1:%d/config" % port)
    if st != 200:
        return st, None
    try:
        return st, json.loads(body)
    except ValueError:
        return st, None


def row_of_models_document(cfg):
    """{model: row} for the /config models section (one card per model)."""
    out = {}
    for entry in (cfg or {}).get("models", []):
        if isinstance(entry, dict) and entry.get("model"):
            out[entry["model"]] = entry
    return out


# ============================================ S12 卡片档位勾选（用户诉求 2026-10-08）
def scenario_card_effort_ladder():
    """探测到的档位进管理台面，操作员勾选的那份接管 /v1/models 的对外阶梯。

    这份与 unit 的 G11 分工不同：G11 在配桩的 registry 上测判定，这份钉**真 HTTP 采集链**
    ——档位必须真的从 mock 的 /v1/models 经 registry 探针落到 /config 的卡片行上
    （那是勾选框唯一的基线来源），再证明勾选/取消过一遍 POST 之后对外字节真的变了。
    接线错在这条链上的表现是「勾选框永远是空的」或「勾了但对外一个字没变」，两侧各一组
    断言把它夹住。
    """
    tag = "S12-card-ladder"
    pm = free_port()
    start_mock_env(pm, "ladder-model", {"MODELS_RICH": "1"})
    port, name, gw = start_conf({}, tag)
    url = "http://%s:%d" % (gw, pm)
    st, _ = post_worker(port, url, "ladder-model")
    check("[%s] worker registered" % tag, st in (200, 202), str(st))
    check("[%s] worker healthy" % tag, wait_healthy(port, [url]), logs(name)[:400])
    check("[%s] 采集链路把能力送到了外表面" % tag, wait_caps(port, "ladder-model"), logs(name)[:400])

    # ── 1. 探测：引擎原话同时出现在对外行与 /config 的卡片行上 ──
    st, doc, raw = models_doc(port)
    e = row(doc, "ladder-model") or {}
    ladder = e.get("reasoning_efforts") or []
    check("[%s] 未勾选时对外阶梯 = mock 报的 4 档" % tag,
          [r.get("value") for r in ladder] == ["low", "medium", "high", "max"],
          json.dumps(ladder)[:300])
    check("[%s] 未勾选时判定面 = mock 亲口说的 3 档（不掺 medium）" % tag,
          caps_of(e).get("reasoning_effort") == ["low", "high", "max"],
          json.dumps(caps_of(e))[:300])
    st, cfg = get_json_cfg(port)
    card_row = None
    deadline = time.time() + 12
    while time.time() < deadline:
        card_row = (row_of_models_document(cfg) or {}).get("ladder-model")
        if card_row and card_row.get("detected_reasoning_efforts"):
            break
        time.sleep(0.5)
        st, cfg = get_json_cfg(port)
    card_row = card_row or {}
    detected = card_row.get("detected_reasoning_efforts")
    check("[%s] /config 的卡片行带出**引擎原话**（勾选框的基线来源）" % tag,
          isinstance(detected, list) and [r.get("value") for r in detected]
          == ["low", "medium", "high", "max"], json.dumps(card_row)[:400])
    check("[%s] 未勾过时卡片行的 reasoning_efforts 是 null（= 自动，不与[] 混）" % tag,
          "reasoning_efforts" not in card_row or card_row["reasoning_efforts"] is None,
          json.dumps(card_row.get("reasoning_efforts"))[:120])

    # ── 2. 勾选：取消 medium、手动加引擎从没报过的 xhigh、预选挪到 high ──
    st, doc = post_json(port, "/config/model",
                        {"model": "ladder-model",
                         "reasoning_efforts": [{"value": "low"}, {"value": "high", "default": True},
                                               {"value": "xhigh"}]})
    check("[%s] POST /config/model 带勾选表被接受" % tag, st == 200, "%s %s" % (st, str(doc)[:300]))
    e = {}
    deadline = time.time() + 12
    while time.time() < deadline:
        st, doc, raw = models_doc(port)
        e = row(doc, "ladder-model") or {}
        if [r.get("value") for r in (e.get("reasoning_efforts") or [])] == ["low", "high", "xhigh"]:
            break
        time.sleep(0.5)
    ladder = e.get("reasoning_efforts") or []
    check("[%s] 对外阶梯 = 勾选的那 3 档（顺序 = 勾选顺序）" % tag,
          [r.get("value") for r in ladder] == ["low", "high", "xhigh"], json.dumps(ladder)[:300])
    check("[%s] 勾选档位的 label 仍从引擎那份继承（取消勾选没毁掉别的字段）" % tag,
          [r.get("label") for r in ladder] == ["Low Effort", "High Effort", None],
          json.dumps(ladder)[:300])
    check("[%s] 预选落在操作员标的 high（顶层 reasoning_effort 与它自洽）" % tag,
          [r.get("value") for r in ladder if r.get("default") is True] == ["high"]
          and e.get("reasoning_effort") == "high", json.dumps(e)[:300])
    check("[%s] 判定面 = 引擎说过 ∩ 勾选：medium 与 max 都不在，xhigh 不被虚构进去" % tag,
          caps_of(e).get("reasoning_effort") == ["low", "high"],
          json.dumps(caps_of(e))[:300])
    st, cfg = get_json_cfg(port)
    saved = (row_of_models_document(cfg) or {}).get("ladder-model") or {}
    check("[%s] 勾选表落进配置文档（下次打开对话框回显的是操作员说的）" % tag,
          [r.get("value") for r in (saved.get("reasoning_efforts") or [])] == ["low", "high", "xhigh"],
          json.dumps(saved)[:400])
    check("[%s] 基线与声明分家：detected 仍是引擎那 4 档（不随勾选漂移）" % tag,
          [r.get("value") for r in (saved.get("detected_reasoning_efforts") or [])]
          == ["low", "medium", "high", "max"], json.dumps(saved)[:400])

    # ── 3. 非法档位名整条拒绝，且不留下半截状态 ──
    st, doc = post_json(port, "/config/model",
                        {"model": "ladder-model", "reasoning_efforts": ["low", "turbo"]})
    check("[%s] 未知档位名被 400 拒绝" % tag, st == 400, "%s %s" % (st, str(doc)[:200]))
    st, doc, raw = models_doc(port)
    e = row(doc, "ladder-model") or {}
    check("[%s] 被拒的批次没改动对外阶梯（仍是我方勾过的 3 档）" % tag,
          [r.get("value") for r in (e.get("reasoning_efforts") or [])] == ["low", "high", "xhigh"],
          json.dumps(e.get("reasoning_efforts"))[:200])

    # ── 4. 清除回自动：null 之后阶梯整份退回引擎原话 ──
    st, doc = post_json(port, "/config/model",
                        {"model": "ladder-model", "reasoning_efforts": None})
    check("[%s] POST null 被接受（清除回自动）" % tag, st == 200, "%s %s" % (st, str(doc)[:200]))
    e = {}
    deadline = time.time() + 12
    while time.time() < deadline:
        st, doc, raw = models_doc(port)
        e = row(doc, "ladder-model") or {}
        if [r.get("value") for r in (e.get("reasoning_efforts") or [])] == ["low", "medium", "high", "max"]:
            break
        time.sleep(0.5)
    ladder = e.get("reasoning_efforts") or []
    check("[%s] 清除后阶梯退回引擎那 4 档（与勾选前逐字节同形）" % tag,
          [r.get("value") for r in ladder] == ["low", "medium", "high", "max"],
          json.dumps(ladder)[:300])
    check("[%s] 清除后判定面回到引擎那 3 档（xhigh 从未真的被接受过）" % tag,
          caps_of(e).get("reasoning_effort") == ["low", "high", "max"],
          json.dumps(caps_of(e))[:300])
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
    st, doc = post_json(port, "/config/model",
                        {"model": "rich-model", "ctx": 524288,
                         "context_limit": 300000, "modalities": ["text", "image", "video"],
                         "default_effort": "high"})
    check("[%s] POST /config/model 卡片被接受" % tag, st == 200,
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
    st, doc = post_json(port, "/config/virtual", {"entries": [
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


# ================================================== S6 组内缺读数必须删键
def scenario_group_missing_reading():
    """组里有一台没给长度读数时，入口行**整个键**都不许出现。

    线上症状（2026-10-04 生产 235.t:8800）：入口 Qn 的组是 Q38-Flash-Next +
    kimi-code/k3，kimi 报 context_length 1000000，Q38 那一半当时一个长度读数都没有，
    对外却广告出了 1000000 —— 客户端照这个值塞 token，请求被派到 Q38 那一半就炸。

    判别性（旧实现下"键不存在"那几条必红，它会报 1000000）：
      * beta 那一半**只删两个长度读数**，其余能力照旧富形状上报，这样"键不存在"测的是
        「这台没给窗口读数」而不是「这台整行都没被采到」——后者看起来一模一样，但不是
        同一条纪律（S3 已经钉了整行没读数的形状）。
      * 与"两台都有读数时报最窄"的对照断言**成对**：只留删键那一组会在"一律不报"的
        写错下全绿（G6/S5 的聚合断言也是这条对照的兄弟，这里把它放到真 HTTP 面上）。
    """
    tag = "S6-halfread"
    pa, pb, pc = free_port(), free_port(), free_port()
    # alpha：完整富形状（context_length 1000000 / max_output_tokens 128000）。
    start_mock_env(pa, "alpha", {"MODELS_RICH": "1"})
    # beta：只把两个长度读数从富形状里删掉，模态与档位全部照旧。
    start_mock_env(pb, "beta", {
        "MODELS_RICH": "1",
        "MODELS_CAPS_JSON": json.dumps(
            {"capabilities": {"context_length": None, "max_output_tokens": None}}),
    })
    # gamma：富形状但窗口是 262144，用来做"两台都开口 -> 取最窄"的对照。
    start_mock_env(pc, "gamma", {
        "MODELS_RICH": "1",
        "MODELS_CAPS_JSON": json.dumps(
            {"capabilities": {"context_length": 262144}}),
    })
    port, name, gw = start_conf({}, tag)
    urls = {}
    for model, mp in (("alpha", pa), ("beta", pb), ("gamma", pc)):
        urls[model] = "http://%s:%d" % (gw, mp)
        st, _ = post_worker(port, urls[model], model)
        check("[%s] %s registered" % (tag, model), st in (200, 202), "%s %s" % (model, st))
    check("[%s] 三台都健康" % tag, wait_healthy(port, list(urls.values())), logs(name)[:400])
    # 采集窗口：beta 的"键不存在"必须建立在**它确实被采到**之上，否则缺席测的是时序。
    got = {m: wait_caps(port, m) for m in ("alpha", "beta", "gamma")}
    check("[%s] 三台的 capabilities 都被采到（beta 只缺两个长度读数）" % tag,
          all(got.values()), json.dumps(got))
    st, doc = post_json(port, "/config/virtual", {"entries": [
        {"model": "vm-half", "targets": ["alpha", "beta"]},
        {"model": "vm-wide", "targets": ["alpha", "gamma"]}]})
    check("[%s] 两个入口都收下" % tag, st == 200, "%s %s" % (st, str(doc)[:300]))
    st, doc, raw = models_doc(port)
    half = row(doc, "vm-half")
    wide = row(doc, "vm-wide")
    check("[%s] 两个入口都在广告里" % tag, half is not None and wide is not None, raw[:300])
    # 前提：成员自己那行各说各话（beta 确实没长度读数，alpha 确实有）。
    beta_caps = caps_of(row(doc, "beta"))
    check("[%s] 前提：beta 自己那行没有 context_length（引擎没说）" % tag,
          "context_length" not in beta_caps, json.dumps(beta_caps)[:300])
    check("[%s] 前提：beta 自己那行仍有模态读数（不是整行没采到）" % tag,
          beta_caps.get("input_modalities") == ["text", "image"],
          json.dumps(beta_caps)[:300])
    check("[%s] 前提：alpha 自己那行照报 1000000" % tag,
          caps_of(row(doc, "alpha")).get("context_length") == 1000000,
          json.dumps(caps_of(row(doc, "alpha")))[:300])
    # 本次要修的：组内一台没给读数 -> 入口行两个长度键都必须不存在。
    half_caps = caps_of(half)
    check("[%s] 组内一台有读数一台没有 -> 入口行不许有 context_length" % tag,
          "context_length" not in half_caps, json.dumps(half_caps)[:400])
    check("[%s] 同一条入口行也不许有 max_output_tokens（同一条纪律）" % tag,
          "max_output_tokens" not in half_caps, json.dumps(half_caps)[:400])
    check("[%s] 删键不许顺带掉 required 四字段" % tag,
          half is not None and all(k in half for k in REQUIRED), json.dumps(half)[:300])
    check("[%s] 删键不许牵连其它一致口径的键（模态仍照报）" % tag,
          half_caps.get("input_modalities") == ["text", "image"],
          json.dumps(half_caps)[:400])
    check("[%s] 对照：两台都开口(1000000/262144) -> 入口行报最窄 262144" % tag,
          caps_of(wide).get("context_length") == 262144,
          json.dumps(caps_of(wide))[:400])
    check("[%s] 对照：两台都开口的 max_output_tokens 照报 128000" % tag,
          caps_of(wide).get("max_output_tokens") == 128000,
          json.dumps(caps_of(wide))[:400])
    check("[%s] 响应里没有 JSON null（删的是键而不是写 null）" % tag,
          "null" not in raw, raw[:300])
    check_no_abort(tag, name)
    stop(name)



# ============================================================ S7–S10 广告面开关
#
# 被测实现：router.lua 的 models_advertise 那一节（提交 030dab5）。/v1/models 多了一个
# 开关：开了就只对外广告虚拟入口，真实模型不再出现在 data[].id 里。四条纪律：
#   S7 开关「关」的每一档都必须与「磁盘上根本没有配置文件」逐字节一致（硬规则 9 第三条
#      钉住的老契约不许被新开关动一根手指）。
#   S8 开关「开」时 data[].id 只剩入口名；同时真实模型仍可路由、仍在 /workers ——
#      语义严格限定在「只广告」这一件事。
#   S9 开关开但一条入口都装配不出来 -> 退回全量广告 + WARN 一行，绝不交空列表。
#   S10 磁盘读数压过 env 读数（两档都是「说了才算」，不是 OR）。
#
# 开关怎么打开：读数两层，磁盘快照 LMR_CONFIG_FILE 里那一份优先，其次 env
# LMR_MODELS_VIRTUAL_ONLY，两边都没说过才是关。两层在这里都有实测（S7/S8 走磁盘 JSON
# 挂载，S10 同时走 env 与「磁盘 false 压过 env true」）。历史一笔：030dab5 当时 env 那一层
# 还没进 config_store.ENV_NAMES，只有磁盘这条路管用，router.lua 第 4160 行附近的注释如实
# 写了这条代价；3728821 把名册补齐之后两层都通，本组因此把**两层各自能开、且磁盘压过 env**
# 一起钉住 —— 名册那行以后被删掉，S10 的 env-only 探针会红。
#
# 顺序纪律（防御性，也是观测顺序）：S7/S8 都「先注册、先建入口，最后才写磁盘开关」，
# 因为拨开关之前必须先看见真实模型行在广告里，否则「真实行消失」可能从来就没出现过。
# 另一条纪律（开关活过配置保存）刻意放在 S11：那条走操作员真实工作流——文件在容器启动
# 时就带着这个键，之后才被配置写接口重写一遍。S7/S8 那种「跑起来之后再手写文件」的形状
# 测不到它：config_store 的 shdict 层里没有这个键，保存时按那份内存视图重刷磁盘。
CFG_MOUNT = "/cfg"


def start_conf_cfg(env, tag, cfg_dir):
    """start_conf 的磁盘快照版：额外把宿主机 cfg_dir 读写挂载进容器。"""
    name = "lr-%s-%s" % (tag[:22], RUN)
    full = dict(BASE_ENV)
    full.update({k: str(v) for k, v in (env or {}).items()})
    args = ["docker", "run", "-d", "--name", name,
            "-p", "127.0.0.1::8080", "-v", REPO + ":/repo:ro",
            "-v", cfg_dir + ":" + CFG_MOUNT]
    if LEGACY_LUALIB:
        # 判别性通道：同一组断言跑在改动前的 router.lua 上（见模块 docstring）。
        args += ["-v", LEGACY_LUALIB + ":/repo/lualib:ro"]
    for k, v in full.items():
        args += ["-e", "%s=%s" % (k, v)]
    args += ["--entrypoint", "openresty", BASE_IMAGE,
             "-p", "/usr/local/openresty/nginx/",
             "-c", "/repo/test/conf/nginx-lua-router.conf", "-g", "daemon off;"]
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


def make_cfg_dir(tag):
    """宿主机侧的磁盘快照目录，挂载进容器给网关读写。

    0o777 是刻意的：nginx 的 worker 不是本目录的属主，权限不够时 write_snapshot 会
    「persist to ... Permission denied」静默失败一行 WARN，磁盘永远保持我写的那份 —— 看
    起来全绿，其实把配置层的写路径整段跳过了（连"保存一次会不会抹掉这个键"都测不到）。
    """
    path = os.path.join(TMP, "cfg-%s-%s" % (RUN, tag))
    os.makedirs(path, exist_ok=True)
    os.chmod(path, 0o777)
    return path


def write_cfg(cfg_dir, text):
    """从宿主机写磁盘快照：整文件替换，模拟操作员手改 LMR_CONFIG_FILE。

    先 unlink 再建，不能直接 open(..., "w")：目录一旦对容器可写（见 make_cfg_dir），
    config_store 的 write_snapshot 会自己把快照落在那儿，文件属主变成容器里的 root，
    宿主机侧再 truncate 就是 EACCES。目录本身是 0777 且不带 sticky 位，删除永远有权。
    """
    path = os.path.join(cfg_dir, "config.json")
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


CFG_IN_CONTAINER = "%s/config.json" % CFG_MOUNT


def ids_of(doc):
    return [d.get("id") for d in (doc or {}).get("data", [])]


def poll_models(port, want, timeout=12, interval=0.4, settle=0.0):
    """轮询 /v1/models 直到 want(st, doc, raw) 成立或超时；返回最后一次的三元组。

    磁盘读数允许 0.5 s 的陈旧度（models_advertise.ttl_s 与 config_store 的 SNAPSHOT_TTL
    同档），所以「改完配置文件立刻查一次」不是可依赖的观测：不等到就断言，测的会是缓存
    时序而不是开关语义。

    settle 是给**关闭态**那组用的：write_cfg 是宿主机侧 truncate + write，网关可能正好
    读到写了一半的文件，那一次 io.open/decode 失败会被判成「磁盘没说」→ 关。want 是
    「等于基准」时，第一次请求正好命中那个瞬间就会立刻返回，九档全绿却什么都没测（恒真）。
    先静置一个 over-TTL 的窗口再开始判，关闭态才真的在判「这个写法算关」。
    """
    if settle:
        time.sleep(settle)
    deadline = time.time() + timeout
    st, doc, raw = models_doc(port)
    while time.time() < deadline and not want(st, doc, raw):
        time.sleep(interval)
        st, doc, raw = models_doc(port)
    return st, doc, raw


def wait_log(name, needle, timeout=12):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if needle in logs(name):
            return True
        time.sleep(0.4)
    return False


def chat_once(port, model):
    return http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                {"model": model,
                 "messages": [{"role": "user", "content": "advertise switch"}],
                 "stream": False})


def register_pair(port, gw, tag, specs):
    """specs = [(model, mock_port)]; 返回 {model: url}，并断言注册与健康都到位。"""
    urls = {}
    for model, mp in specs:
        urls[model] = "http://%s:%d" % (gw, mp)
        st, _ = post_worker(port, urls[model], model)
        check("[%s] %s registered" % (tag, model), st in (200, 202), "%s %s" % (model, st))
    check("[%s] 全部 worker 健康" % tag, wait_healthy(port, list(urls.values())),
          "urls=" + json.dumps(sorted(urls.values())))
    return urls


# ------------------------------------------------------- S7 关闭态逐字节不变
def scenario_switch_off_is_byte_identical():
    """S7：开关的每一档「关」都必须与「配置文件里没说过这件事」逐字节一致。

    基准取的是**写入任何配置文件之前**的响应字节，所以它同时钉住「磁盘文件存在但没这个
    键」与「磁盘上根本没有文件」是同一档。
    """
    tag = "S7-voff"
    pa, pb = free_port(), free_port()
    start_mock_env(pa, "solo-alpha", {"MODELS_RICH": "1"})
    start_mock_env(pb, "solo-beta", {"MODELS_RICH": "1"})
    cfg_dir = make_cfg_dir("off")
    port, name, gw = start_conf_cfg({"LMR_CONFIG_FILE": CFG_IN_CONTAINER}, tag, cfg_dir)
    register_pair(port, gw, tag, (("solo-alpha", pa), ("solo-beta", pb)))
    got = {m: wait_caps(port, m) for m in ("solo-alpha", "solo-beta")}
    check("[%s] 前提：两台的 capabilities 都被采到" % tag, all(got.values()), json.dumps(got))
    st, doc = post_json(port, "/config/virtual", {"entries": [
        {"model": "vm-solo-a", "target": "solo-alpha"},
        {"model": "vm-solo-group", "targets": ["solo-alpha", "solo-beta"]}]})
    check("[%s] 两个入口都收下" % tag, st == 200, "%s %s" % (st, str(doc)[:300]))
    st, doc, baseline = models_doc(port)
    # 基准取在「磁盘快照里还没有这个键」的那一刻：上面那次 POST 已经把 config_store 自己
    # 生成的快照写到挂载目录了（目录可写，见 make_cfg_dir），所以基准测的是「文件存在但对
    # 这个开关一个字都没说」，与后面九档里的「键缺失」是同一档。
    check("[%s] 基准（快照里还没这个键）200" % tag, st == 200,
          "%s %s" % (st, str(baseline)[:200]))
    check("[%s] 基准里真实模型与虚拟入口都在（老契约的取值集合）" % tag,
          sorted(ids_of(doc)) == ["solo-alpha", "solo-beta", "vm-solo-a", "vm-solo-group"],
          json.dumps(sorted(ids_of(doc))))
    check("[%s] 基准非空（否则后面的逐字节相等会被两份空响应骗过去）" % tag,
          bool(ids_of(doc)), str(baseline)[:200])
    off_spellings = [
        ("布尔 false", '{"models_virtual_only": false}'),
        ("字符串 false", '{"models_virtual_only": "false"}'),
        ("字符串 0", '{"models_virtual_only": "0"}'),
        ("字符串 off", '{"models_virtual_only": "off"}'),
        ("垃圾串", '{"models_virtual_only": "not-a-bool"}'),
        ("空串", '{"models_virtual_only": ""}'),
        ("数字 0", '{"models_virtual_only": 0}'),
        ("键缺失", '{"upstreams": []}'),
        ("键为 null", '{"models_virtual_only": null}'),
    ]
    # 这九档的判别性靠下面的正向对照撑起：先证明「同一台容器、同一个挂载点里写 true
    # 真的能改变广告」，否则「九档全等于基准」可能只是磁盘通道根本没通（文件读不到 =
    # 沉默 = 关），那是一组恒真断言。判别性实测：把 truthy 写成「非假即真」的变异体下，
    # "字符串 0 / off / 垃圾串 / 空串" 四档必须红（它们会被当成开）。
    for label, text in off_spellings:
        write_cfg(cfg_dir, text)
        st, doc2, raw2 = poll_models(
            port, lambda s, d, r: s == 200 and r == baseline and bool(ids_of(d)),
            settle=0.9)
        check("[%s] 开关写成 %s 时对外字节与基准逐字节一致" % (tag, label),
              st == 200 and raw2 == baseline and bool(ids_of(doc2)),
              "ids=%s len=%s/%s" % (json.dumps(ids_of(doc2))[:200],
                                    len(raw2 or ""), len(baseline or "")))
    # ---- 正向对照（本组判别性的来源，绝不允许悄悄退化成恒真）----
    write_cfg(cfg_dir, '{"models_virtual_only": true}')
    st, doc_on, raw_on = poll_models(
        port, lambda s, d, r: s == 200 and bool(ids_of(d))
        and not (set(ids_of(d)) & {"solo-alpha", "solo-beta"}), timeout=15)
    check("[%s] 正向对照：同一份挂载里写 true 确实切成只广告入口" % tag,
          ids_of(doc_on) == ["vm-solo-a", "vm-solo-group"], json.dumps(ids_of(doc_on)))
    check("[%s] 正向对照：开态的字节与基准**不同**（证明磁盘通道是通的）" % tag,
          raw_on != baseline and bool(raw_on), str(raw_on)[:200])
    write_cfg(cfg_dir, '{"models_virtual_only": false}')
    st, doc_off, raw_off = poll_models(
        port, lambda s, d, r: s == 200 and r == baseline and bool(ids_of(d)), settle=0.9)
    check("[%s] 正向对照：拨回 false 又逐字节回到基准（开关真是每请求读磁盘）" % tag,
          raw_off == baseline and bool(ids_of(doc_off)), json.dumps(ids_of(doc_off)))
    check_no_abort(tag, name)
    stop(name)


# ------------------------------------------------------- S8 只广告虚拟入口
def scenario_switch_on_advertises_only_entries():
    """S8：开关开 -> data[] 只剩入口行；真实模型不出现但照样可路由、可查。

    判别性（实测：旧实现即 030dab5 之前的 router.lua 下这组红四条）：那块开关被移开后
    models_handler 只剩「真实行 + 追加入口」一条路，于是"ids 恰为两个入口名"、
    "一条真实模型 id 都不许出现在 data[].id"、"响应里不许有 owned_by=local 这个真实行
    指纹"、"真实模型的扩展读数不许被整份搬进入口行"一起红。
    反向对照是**边界守卫**（旧实现下应当绿，红才说明开关越界）：/workers 仍列出两台、按
    真实模型名直发 chat 仍 200、开关拨回 false 后真实行必须回来（证明每请求读磁盘）。
    """
    tag = "S8-vonly"
    pa, pb = free_port(), free_port()
    start_mock_env(pa, "real-a", {"MODELS_RICH": "1"})
    start_mock_env(pb, "real-b", {"MODELS_RICH": "1"})
    cfg_dir = make_cfg_dir("on")
    write_cfg(cfg_dir, '{"upstreams": []}')
    port, name, gw = start_conf_cfg({"LMR_CONFIG_FILE": CFG_IN_CONTAINER}, tag, cfg_dir)
    urls = register_pair(port, gw, tag, (("real-a", pa), ("real-b", pb)))
    # 采集窗口必须在拨开关**之前**等到：开关一开，真实行不再出现在 /v1/models 里，
    # wait_caps 那种「看对外有没有 capabilities」的等法就永远等不到了。
    got = {m: wait_caps(port, m) for m in ("real-a", "real-b")}
    check("[%s] 前提：两台的 capabilities 都被采到" % tag, all(got.values()), json.dumps(got))
    st, doc = post_json(port, "/config/virtual", {"entries": [
        {"model": "gate-a", "target": "real-a"},
        {"model": "gate-ab", "targets": ["real-a", "real-b"]}]})
    check("[%s] 两个入口都收下" % tag, st == 200, "%s %s" % (st, str(doc)[:300]))
    # 前提：开开关之前先证明真实模型确实在广告里（否则"消失"可能从来就没出现过）。
    st, doc, raw_full = models_doc(port)
    check("[%s] 前提：拨开关之前真实模型两行都在" % tag,
          sorted(ids_of(doc)) == ["gate-a", "gate-ab", "real-a", "real-b"],
          json.dumps(sorted(ids_of(doc))))
    # 最后才写开关：见本节头的顺序纪律。「开关能活过 /config 保存」由 S11 专测。
    write_cfg(cfg_dir, '{"models_virtual_only": true}')
    st, doc, raw = poll_models(port, lambda s, d, r: s == 200 and not (set(ids_of(d)) & {"real-a", "real-b"}))
    check("[%s] 开关开后 /v1/models 200" % tag, st == 200, "%s %s" % (st, str(raw)[:200]))
    ids = ids_of(doc)
    check("[%s] data[].id 恰为两个入口名（不多不少）" % tag, ids == ["gate-a", "gate-ab"],
          json.dumps(ids))
    check("[%s] 一条真实模型 id 都不许出现在 data[].id 里" % tag,
          not (set(ids) & {"real-a", "real-b"}), json.dumps(ids))
    # 真实那一半的指纹是 owned_by == "local"（入口行是 llm-router* 一族），用它判泄漏
    # 而不是搜模型名：入口行的 owned_by / owned_by_models 本来就必须带上目标名，
    # 搜名字会把「入口行如实报组」也当成泄漏。
    compact = raw.replace(" ", "").replace("\n", "")
    check("[%s] 响应里没有任何一行是真实模型（owned_by=local 这个指纹不许出现）" % tag,
          '"owned_by":"local"' not in compact, compact[:400])
    check("[%s] 真实模型的扩展读数没被整份搬进入口行（行不是换名不换内容）" % tag,
          '"created":1700000000' not in compact.replace(" ", ""), compact[:400])
    check("[%s] 外层 object 仍是 list" % tag, (doc or {}).get("object") == "list",
          str(raw)[:200])
    for entry_id in ("gate-a", "gate-ab"):
        e = row(doc, entry_id)
        check("[%s] 入口行 %s 带齐 required 四字段" % (tag, entry_id),
              e is not None and all(k in e for k in REQUIRED), json.dumps(e)[:250])
        check("[%s] 入口行 %s created 恒 0" % (tag, entry_id),
              (e or {}).get("created") == 0, json.dumps(e)[:200])
    check("[%s] 单目标入口的 owned_by 老口径不因开关改变" % tag,
          (row(doc, "gate-a") or {}).get("owned_by") == "llm-router->real-a",
          json.dumps(row(doc, "gate-a"))[:250])
    check("[%s] 多目标入口的 owned_by + owned_by_models 不因开关改变" % tag,
          (row(doc, "gate-ab") or {}).get("owned_by") == "llm-router"
          and (row(doc, "gate-ab") or {}).get("owned_by_models") == ["real-a", "real-b"],
          json.dumps(row(doc, "gate-ab"))[:300])
    # 入口行的能力聚合口径不参与开关（开关只管广告哪几行，不管每行长什么样）。
    grp_caps = caps_of(row(doc, "gate-ab"))
    check("[%s] 开关开时入口行仍带组内聚合的 context_length" % tag,
          grp_caps.get("context_length") == 1000000, json.dumps(grp_caps)[:300])
    st, doc_again, raw_again = models_doc(port)
    check("[%s] 同一份配置连查两次字节一致（不塞 ngx.time、不引入抖动）" % tag,
          raw_again == raw, "%s vs %s" % (len(raw or ""), len(raw_again or "")))
    # 语义边界的另一半：只影响广告，不影响路由与运行态。
    rows = workers_by_url(port)
    check("[%s] /workers 仍列出两台真实 worker（开关不摘运行态）" % tag,
          set(urls.values()) <= set(rows), json.dumps(sorted(rows))[:300])
    # 边界守卫（两种版本下都该绿，不是本次要修的判别性断言）：开关只管广告哪几行，
    # 不许动路由。按真实模型名直发必须仍然 200 且拿到回显；具体落到组内哪一台由
    # cache_aware 的亲和与负载决定，与开关无关，所以这里刻意不断言「落到 real-a 自己」。
    st, body, _ = chat_once(port, "real-a")
    check("[%s] 广告里消失的真实模型仍可直呼其名路由" % tag,
          st == 200 and "echo[" in body, "%s %s" % (st, body[:200]))
    st, body2, _ = chat_once(port, "gate-ab")
    check("[%s] 入口名照旧可路由" % tag,
          st == 200 and ("echo[real-a]" in body2 or "echo[real-b]" in body2),
          "%s %s" % (st, body2[:200]))
    # 关掉要能回到全量：证明它是每请求读磁盘的开关，而不是一次性快照。
    write_cfg(cfg_dir, '{"models_virtual_only": false}')
    st, doc_back, _ = poll_models(port, lambda s, d, r: "real-a" in ids_of(d))
    check("[%s] 开关拨回 false 后真实模型行回来（且入口行不受影响）" % tag,
          sorted(ids_of(doc_back)) == ["gate-a", "gate-ab", "real-a", "real-b"],
          json.dumps(sorted(ids_of(doc_back))))
    check_no_abort(tag, name)
    stop(name)


# --------------------------------------------- S9 装配不出入口时退回全量广告
def scenario_switch_on_without_entries_falls_back():
    """S9：开关开却一条入口都装配不出来 -> 退回全量广告 + WARN，而不是交空列表。

    线上含义：静默清空 data[] 等于让客户端以为整个网关服务消失了（模型选择、按 id 建索引
    的客户端全断）。所以 router.lua 那条分支选择「如实退回全量 + WARN 一行」。

    判别性分两半：
      * WARN 那一条在旧实现下必红（旧实现连这个分支都没有，日志里搜不到这句话）。
      * data[] 非空 / 真实行仍在 这两条是回归守卫：它们绿在旧实现下正是应有的样子，
        红才说明新实现把「退回全量」写成了「返回空 data」。
    """
    tag = "S9-norows"
    pa = free_port()
    start_mock_env(pa, "lonely", {"MODELS_RICH": "1"})
    cfg_dir = make_cfg_dir("empty")
    write_cfg(cfg_dir, '{"upstreams": []}')
    port, name, gw = start_conf_cfg({"LMR_CONFIG_FILE": CFG_IN_CONTAINER}, tag, cfg_dir)
    register_pair(port, gw, tag, (("lonely", pa),))
    check("[%s] 前提：这台引擎的能力读数被采到（它有资格被广告，缺席不是没采到）" % tag,
          wait_caps(port, "lonely"), logs(name)[:300])
    st, doc, raw = models_doc(port)
    check("[%s] 前提：开关之前真实行在广告里" % tag, ids_of(doc) == ["lonely"], json.dumps(ids_of(doc)))
    write_cfg(cfg_dir, '{"models_virtual_only": true}')
    # 反复请求而不是只发一次：开关读数带 0.5 s 的 worker 侧缓存，上一次请求（上面的
    # 前提那次）刚把「关」缓存住，只发一次可能整轮都读不到新值，于是 WARN 永远不出现
    # ——那会被当成实现的错。want 里同时看日志，等到就是等到。
    st, doc, raw = poll_models(
        port, lambda s_, d_, r_: bool(ids_of(d_))
        and "models_virtual_only is on but no" in logs(name))
    ids = ids_of(doc)
    check("[%s] 开关开+零入口时 data[] 非空（绝不交空列表）" % tag,
          st == 200 and bool(ids), "%s %s" % (st, str(raw)[:250]))
    check("[%s] 退回的那份就是全量广告：真实模型行在" % tag, "lonely" in ids, json.dumps(ids))
    e = row(doc, "lonely")
    check("[%s] 退回的行仍带齐 required 四字段" % tag,
          e is not None and all(k in e for k in REQUIRED), json.dumps(e)[:250])
    check("[%s] 网关为这次退回 WARN 一行" % tag,
          wait_log(name, "models_virtual_only is on but no"), logs(name)[-500:])
    check_no_abort(tag, name)
    stop(name)


# --------------------------------------------- S10 两层读数：各自能开 + 磁盘压过 env
def scenario_disk_and_env_layers():
    """S10：磁盘与 env 两层读数各自都能打开开关，且磁盘那份**压过** env 那一份。

    判别性实测（同一份断言跑在四种实现上，红点各不相同）：
      * 把 enabled 写成 `from_disk() or from_env()` 那种 **OR** —— 「磁盘 false + env true
        仍广告真实模型」这条红（实测：data[].id 只剩 ["vm-env"]）。
      * 把 config_store.ENV_NAMES 里那行 LMR_MODELS_VIRTUAL_ONLY 删掉（3728821 补的）——
        env-only 那台容器的 worker 读不到 env，真实模型行留下，「env 单独能开」红。
      * 开关整个不存在（030dab5 之前）—— 两条都红。
    两条不变式顺带钉住：任何一种读数组合都不许把 data[] 清空；真实模型永远可路由。
    """
    tag = "S10-prec"
    pa = free_port()
    start_mock_env(pa, "env-model", {"MODELS_RICH": "1"})

    # ---- 台一：env 说 true，磁盘说 false —— 磁盘是结论，必须压过 env ----
    cfg_dir = make_cfg_dir("prec")
    write_cfg(cfg_dir, '{"models_virtual_only": false}')
    port, name, gw = start_conf_cfg({"LMR_CONFIG_FILE": CFG_IN_CONTAINER,
                                     "LMR_MODELS_VIRTUAL_ONLY": "true"}, tag, cfg_dir)
    register_pair(port, gw, tag, (("env-model", pa),))
    st, doc = post_json(port, "/config/virtual",
                        {"entries": [{"model": "vm-env", "target": "env-model"}]})
    check("[%s] 入口收下" % tag, st == 200, "%s %s" % (st, str(doc)[:200]))
    st, doc, raw = models_doc(port)
    ids = ids_of(doc)
    check("[%s] env=true + 磁盘=false -> 真实模型行仍在（磁盘压过 env，不是 OR）" % tag,
          st == 200 and "env-model" in ids and "vm-env" in ids, json.dumps(ids))
    check("[%s] 台一的 data[] 非空（任何组合都不许清空服务）" % tag, bool(ids), str(raw)[:250])
    st2, body, _ = chat_once(port, "env-model")
    check("[%s] 真实模型永远可路由" % tag, st2 == 200 and "echo[" in body,
          "%s %s" % (st2, body[:200]))
    check_no_abort(tag, name)
    stop(name)

    # ---- 台二：只有 env 说 true，磁盘上根本没有文件 ----
    tag2 = "S10-envonly"
    pb = free_port()
    start_mock_env(pb, "env-solo", {"MODELS_RICH": "1"})
    cfg_dir2 = make_cfg_dir("envonly")   # 刻意不写 config.json：磁盘层完全沉默
    port2, name2, gw2 = start_conf_cfg({"LMR_CONFIG_FILE": CFG_IN_CONTAINER,
                                        "LMR_MODELS_VIRTUAL_ONLY": "true"}, tag2, cfg_dir2)
    register_pair(port2, gw2, tag2, (("env-solo", pb),))
    st, doc = post_json(port2, "/config/virtual",
                        {"entries": [{"model": "vm-env2", "target": "env-solo"}]})
    check("[%s] 入口收下" % tag2, st == 200, "%s %s" % (st, str(doc)[:200]))
    st, doc, raw = poll_models(
        port2, lambda s, d, r: s == 200 and bool(ids_of(d))
        and not (set(ids_of(d)) & {"env-solo"}), timeout=15)
    check("[%s] 只设 env（磁盘无文件）也能切成只广告入口：ENV_NAMES 那行在 worker 里通" % tag2,
          ids_of(doc) == ["vm-env2"], json.dumps(ids_of(doc)))
    check("[%s] env-only 下真实模型仍在 /workers（env 通道同样只管广告）" % tag2,
          set(workers_by_url(port2)) == {"http://%s:%d" % (gw2, pb)},
          json.dumps(sorted(workers_by_url(port2)))[:200])
    st2, body2, _ = chat_once(port2, "env-solo")
    check("[%s] env-only 下真实模型仍可直呼其名路由" % tag2,
          st2 == 200 and "echo[" in body2, "%s %s" % (st2, body2[:200]))
    check_no_abort(tag2, name2)
    stop(name2)


# ------------------------------------------- S11 操作员声明的配置文件即权威来源
def scenario_declared_file_is_authoritative():
    """S11：操作员**在启动前**写好的那份配置文件，单独就能决定对外广告什么。

    与 S8 的分工：S8 是「跑起来之后用 POST 建入口、再拨开关」，那份形状里 config_store
    的 shdict 层已经有内容；这一组刻意**一次写接口都不调**——入口与开关全来自磁盘那一份
    JSON，worker 也只走 POST /workers（不碰配置层）。于是它钉的是「磁盘快照这一层自己能
    撑起整个广告面」，包括入口组、开关、以及「读的是文件不是别处」这条。

    最后一条断言判「文件字节没被网关改写过」：整个过程没有任何配置写接口被调过，网关
    只该读它。真把这条打红的是那种越界的实现——比如在请求路径上顺手 persist 一份自己
    生成的快照，把操作员手写的文件覆盖掉（030dab5 的注释里就写着这个已知代价：从
    /config 保存一次会抹掉这个键；那是写路径另一条线要收的，见本次回报）。
    """
    tag = "S11-file"
    pa, pb = free_port(), free_port()
    start_mock_env(pa, "declared-a", {"MODELS_RICH": "1"})
    start_mock_env(pb, "declared-b", {"MODELS_RICH": "1"})
    cfg_dir = make_cfg_dir("auth")
    declared = {"models_virtual_only": True,
                "virtual_models": [{"model": "declared-group",
                                    "targets": ["declared-a", "declared-b"]},
                                   {"model": "declared-one", "target": "declared-b"}]}
    declared_text = json.dumps(declared, sort_keys=True)
    write_cfg(cfg_dir, declared_text)
    port, name, gw = start_conf_cfg({"LMR_CONFIG_FILE": CFG_IN_CONTAINER}, tag, cfg_dir)
    urls = register_pair(port, gw, tag, (("declared-a", pa), ("declared-b", pb)))
    # 采集窗口只能等**入口行**的聚合能力：开关开着时真实行根本不出现在 /v1/models 里，
    # 用 wait_caps 等真实行那两条永远等不到（那测的是时序而不是实现）。入口行的能力来自
    # 组内成员，它出现就等于两台都被采到了。
    got = poll_models(port, lambda s_, d_, r_:
                      caps_of(row(d_, "declared-group")).get("context_length") == 1000000,
                      timeout=30)
    check("[%s] 前提：两台的 capabilities 都被采到（经入口行的聚合观测）" % tag,
          caps_of(row(got[1], "declared-group")).get("context_length") == 1000000,
          json.dumps(caps_of(row(got[1], "declared-group")))[:300])
    st, doc, raw = poll_models(
        port, lambda s_, d_, r_: s_ == 200 and bool(ids_of(d_)), timeout=20)
    check("[%s] 只靠磁盘那份声明就只广告入口（没有任何写接口被调过）" % tag,
          sorted(ids_of(doc)) == ["declared-group", "declared-one"], json.dumps(ids_of(doc)))
    check("[%s] 真实模型 id 一条都不出现" % tag,
          not (set(ids_of(doc)) & {"declared-a", "declared-b"}), json.dumps(ids_of(doc)))
    check("[%s] 入口的组仍来自文件里的 targets（多目标口径没退化成单目标）" % tag,
          (row(doc, "declared-group") or {}).get("owned_by_models")
          == ["declared-a", "declared-b"], json.dumps(row(doc, "declared-group"))[:300])
    check("[%s] 入口行带齐 required 四字段" % tag,
          all(all(k in e for k in REQUIRED) for e in (doc or {}).get("data", [])),
          json.dumps(ids_of(doc)))
    for entry_id in ("declared-group", "declared-one"):
        st2, body, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                            {"model": entry_id,
                             "messages": [{"role": "user", "content": "declared"}],
                             "stream": False})
        check("[%s] 文件里声明的入口 %s 可直接路由" % (tag, entry_id),
              st2 == 200 and "echo[" in body, "%s %s" % (st2, body[:160]))
    rows = workers_by_url(port)
    check("[%s] 真实 worker 仍在 /workers（广告收起来不等于下线）" % tag,
          set(urls.values()) <= set(rows), json.dumps(sorted(rows))[:300])
    after = open(os.path.join(cfg_dir, "config.json"), encoding="utf-8").read()
    check("[%s] 没人碰写接口时网关不改操作员那份文件" % tag, after == declared_text,
          "after=%s" % after[:250])
    # ---- 开关必须活过 /config 的一次保存 ----
    # 030dab5 的注释里写着这个已知代价：整表替换走 cfg_from_document -> snapshot_of，
    # 未知键在两端都没有落点，于是「从管理台保存一次」就把操作员手写的开关擦掉。正解是
    # 读侧认这个键、写侧回写它，两条必须同时有（3728821 收的那条线）。这里两半各钉一条：
    # 磁盘上那个键还在，并且对外仍然只广告入口。
    st, doc = post_json(port, "/config/virtual", {"entries": [
        {"model": "declared-group", "targets": ["declared-a", "declared-b"]},
        {"model": "declared-one", "target": "declared-b"},
        {"model": "declared-third", "target": "declared-a"}]})
    check("[%s] 开关开着再存一次入口被接受" % tag, st == 200, "%s %s" % (st, str(doc)[:200]))
    # settle 不可省：开关读数带 0.5 s 的 worker 侧缓存，保存刚落地的那一瞬仍可能拿着
    # 旧的「开」答出只广告入口，于是这条会在实现被写坏时也绿（实测过的那种假绿）。
    st, doc_sv, _ = poll_models(
        port, lambda s_, d_, r_: s_ == 200 and "declared-third" in ids_of(d_),
        timeout=20, settle=1.2)
    saved = open(os.path.join(cfg_dir, "config.json"), encoding="utf-8").read()
    # 前提：这次保存**真的落到了磁盘**（文件里得有刚加的那条入口），否则下面那条
    # 「键还在」会在「网关根本写不动这个文件」的情况下白绿 —— 那什么也没测。
    check("[%s] 前提：这次配置保存真的重写了磁盘文件（新入口在里面）" % tag,
          "declared-third" in saved, saved[:300])
    check("[%s] 活过配置保存的磁盘半：文件里 models_virtual_only 还在" % tag,
          "models_virtual_only" in saved, saved[:300])
    check("[%s] 活过配置保存的对外半：仍只广告入口，没退回全量" % tag,
          sorted(ids_of(doc_sv)) == ["declared-group", "declared-one", "declared-third"],
          json.dumps(sorted(ids_of(doc_sv))))
    check_no_abort(tag, name)
    stop(name)


# 判别性用的场景过滤器（只影响"跑哪几组"，不影响任何断言）：
#   LR_SCENARIOS=all  缺省，全跑（门禁口径）
#   LR_SCENARIOS=adv  只跑 S7-S10，即广告面开关那四组
# 存在的理由：配合 LR_LEGACY_LUALIB 把开关那四组单独跑在改动前的 router.lua 或某个变异体
# 上，不必为了看一组红而等其余六组跑完。缺省不设该变量时行为与原来逐字节一致。
SCENARIOS = (os.environ.get("LR_SCENARIOS", "all") or "all").strip().lower()


def _want(name):
    return SCENARIOS in ("all", "", name)


def main():
    print("[e2e_models_advertisement] legacy tree = %s, scenarios = %s"
          % (LEGACY_LUALIB or "off", SCENARIOS))
    # 过滤器写错也要响：LR_SCENARIOS 拼错时两组都不跑，RESULTS 为空，末尾那句
    # "0 failed" 会让门禁以为这份 e2e 全绿过。缺省（不设这个变量）的行为与原来一致。
    if SCENARIOS not in ("all", "", "core", "adv"):
        print("FAIL: LR_SCENARIOS must be all|core|adv (got: %s)" % SCENARIOS)
        cleanup()
        sys.exit(2)
    if _want("core"):
        scenario_required_fields()
        scenario_capabilities(1000000)
        scenario_capabilities(262144)
        scenario_omission()
        scenario_config_priority()
        scenario_card_effort_ladder()
        scenario_virtual_entries()
        scenario_group_missing_reading()
    if _want("adv"):
        scenario_switch_off_is_byte_identical()
        scenario_switch_on_advertises_only_entries()
        scenario_switch_on_without_entries_falls_back()
        scenario_disk_and_env_layers()
        scenario_declared_file_is_authoritative()
    failed = [r for r in RESULTS if not r[0]]
    if not RESULTS:
        print("FAIL: 一个断言都没跑（场景过滤器把两组都关掉了？）")
        cleanup()
        sys.exit(1)
    print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
    for _, name, detail in failed:
        print("FAILED: %s | %s" % (name, detail[:400]))
    cleanup()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
