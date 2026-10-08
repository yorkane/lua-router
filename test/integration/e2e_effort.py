#!/usr/bin/env python3
"""effort 的转发链：强制层（原有）+ 三层继承（卡片 → 条目 → 全局）过一遍真 HTTP。

跑法（门禁纪律：lr- 前缀容器 + host 侧 mock，门与门严禁并发；本文件自己抢
/data/tmp/lr-e2e.lock，抢不到就排队等）：
    python3 test/integration/e2e_effort.py

与 test/unit/test_effort_layers.lua 的分工（那份纯 luajit，无端口、可并发）：单测钉**三层
查表的语义**与 router 的**接线形状**（能造「卡片只管 ctx」「脏档位」「未知 from」这些真
HTTP 里造不出来的形状，也能直接看 profile_entry_fallback 交出去的那份读数）；这份钉**整条
链真的把条目层送到了转发体上**——条目声明要经 /config/virtual 落盘、进 shdict 快照、
被 profile_for_alias 取回、交给 config_store.request_effort_for 的第三参，最后由
set_top_field 写进转发体。任何一环断掉，转发的 reasoning_effort 就少改一次，而网关一声不
吭（1e57618 的提交信息里点名的正是这种静默失效）。

判别性（LR_EFFORT_LEGACY_LUALIB=<改动前的 lualib 目录> 把那份树盖在 /repo/lualib 上，同一
组断言跑在旧实现上）。两份旧实现分别是：a) 1e57618 之前的整棵 lualib（三层查表与条目声明
位都不存在）；b) 新 config_store + 030dab5 之前的 router（语义有了，转发链接线没有）：
  判据  S2 / S6      a、b 都红（卡片屏蔽与条目缺省档，正是要修的两个 bug）
        S3           a 红（全局映射被卡片屏蔽）；b 绿（该支路只依赖查表口径）
        S7           a 红（条目位根本没被收下）；b 红（收下了但热路径不读）
  守卫  S0 / S1 / S4 / S5   a、b 都该绿——它们钉既有行为与「新开关缺省零行为变化」，
        绿在旧版正是应有的样子（S5 尤其如此：它是接线前后的字节等式守卫，不是判据）。
每条判据的「实现写错必然红」写在各自场景的 docstring 里。

配置面（三层各自实测可用的声明途径，键名照此）：
  全局层  env LMR_EFFORT_MAP=from>to,...（多条逗号分隔）/ LMR_DEFAULT_EFFORT=<档位>
          等价 HTTP 面：POST /config/effort {effort_map:[{from,to}], default_effort}
  卡片层  env LMR_MODEL_EFFORT_MAP=<model>:<from>><to>（**只有它会建卡片**）、
          LMR_MODEL_CTX / LMR_MODEL_EFFORT；卡片的 default_effort 没有 env 层，只能
          POST /config/model {model, default_effort}
  条目层  env 表达不出来（LMR_VIRTUAL_MODELS 只有 alias:target 一种形状），走
          POST /config/virtual {entries:[{model,target,default_effort,
          effort_map:[{from,to}]}]}
"""
import fcntl
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (RUN, RESULTS, REPO, CONTAINERS, free_port, http, check,
                  start_mock, logs, cleanup)

# 与 e2e_caps / e2e_models_advertisement 同一形态：跑**盘上的 lualib**（CONF_TEST 的
# lua_package_path 第一位就是 /repo/lualib），不必重建镜像，也不会把并行 agent 未完成的
# 改动烧进镜像层。亲和树是每进程的，钉成 1 个 worker 进程才有确定性。
BASE_ENV = {
    "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
    "NGINX_WORKER_PROCESSES": "1",
    "SMG_LOG_LEVEL": "warn",
}
GATEWAY_FALLBACK = "172.17.0.1"
BASE_IMAGE = os.environ.get("OPENRESTY_TEST_IMAGE", "authz:latest")
LEGACY_LUALIB = os.environ.get("LR_EFFORT_LEGACY_LUALIB",
                               os.environ.get("LR_LEGACY_LUALIB", ""))
LOCK_PATH = "/data/tmp/lr-e2e.lock"

MODEL = "effmod"
ALIAS = "eff-alias"
PROBE = "effort probe"


# ------------------------------------------------------------------ 容器与工具

def acquire_gate_lock(seconds=600):
    """抢门禁全局锁（AGENTS.md 硬规则 1：门与门严禁并发）。抢不到就排队等。

    句柄必须一直持有到进程结束（flock 归持有进程），所以调用方保存返回值。超时返回 None。
    """
    os.makedirs(os.path.dirname(LOCK_PATH), exist_ok=True)
    handle = open(LOCK_PATH, "a+")
    deadline = time.time() + seconds
    while True:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return handle
        except OSError:
            if time.time() >= deadline:
                handle.close()
                return None
            time.sleep(2)


def start_conf(env, tag):
    """Serve test/conf/nginx-lua-router.conf; return (port, name, gw)."""
    name = "lr-%s-%s" % (tag[:24], RUN)
    full = dict(BASE_ENV)
    full.update({k: str(v) for k, v in (env or {}).items()})
    args = ["docker", "run", "-d", "--name", name,
            "-p", "127.0.0.1::8080", "-v", REPO + ":/repo:ro"]
    if LEGACY_LUALIB:
        # 判别性通道：把改动前的整棵 lualib 盖在盘上那份之上。
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


def post_json(port, path, body):
    st, text, _ = http("POST", "http://127.0.0.1:%d%s" % (port, path), body)
    try:
        return st, json.loads(text)
    except ValueError:
        return st, text


def post_virtual(port, entries):
    return post_json(port, "/config/virtual", {"entries": entries})


def post_model(port, patch):
    return post_json(port, "/config/model", patch)


def workers_by_url(port):
    st, body, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
    if st != 200:
        return {}
    return {w.get("url"): w for w in json.loads(body).get("workers", [])}


def wait_healthy(port, url, timeout=40):
    deadline = time.time() + timeout
    while time.time() < deadline:
        row = workers_by_url(port).get(url)
        if row is not None and row.get("is_healthy"):
            return True
        time.sleep(0.3)
    return False


def send(port, model, effort=None, content=PROBE):
    """一条 chat 请求；返回 (status, 网关实际转发的 echo_body)。

    请求体里放三个诱饵：消息内嵌套的同名 reasoning_effort、顶层 metadata 里的同名成员、
    以及把档位名写进 stop 数组。改写必须只动**顶层那一个键**（硬规则 4：字节透传，顶层
    精确改写不整表重编码），诱饵被碰到就会红。
    """
    body = {"model": model,
            "messages": [{"role": "user", "content": content,
                          "reasoning_effort": "nested-keep"}],
            "metadata": {"reasoning_effort": "nested-keep"},
            "tools": [], "stop": ["reasoning_effort"], "temperature": 0.5}
    if effort is not None:
        body["reasoning_effort"] = effort
    st, text, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port, body)
    if st != 200:
        return st, {}
    try:
        return st, (json.loads(text).get("echo_body") or {})
    except ValueError:
        return st, {}


def decoys_intact(echo):
    """诱饵原位：嵌套同名成员、stop 数组、tools 空数组都不许多被改动。"""
    messages = echo.get("messages") or [{}]
    return (messages[-1].get("reasoning_effort") == "nested-keep"
            and (echo.get("metadata") or {}).get("reasoning_effort") == "nested-keep"
            and echo.get("stop") == ["reasoning_effort"]
            and echo.get("tools") == [])


def boot(env, tag, cards=None, entries=None, model_name=MODEL, want_model=None):
    """起一台网关 + 一个 mock 并声明好配置；失败返回 None（失败原因自己已经 check 过）。

    注册走 POST /workers（dynamic 行），声明走 /config 的写入面；两者都必须在发请求
    之前完成，否则第一发会读到半套配置。want_model 用来核对 mock 真的服务了那个名字。
    """
    pm = free_port()
    start_mock(pm, model_name)
    port, name, gw = start_conf(env, tag)
    url = "http://%s:%d" % (gw, pm)
    st, doc = post_json(port, "/workers", {"url": url, "model_id": model_name})
    if not check("[%s] worker registered" % tag, st in (200, 202),
                 "%s %s" % (st, json.dumps(doc)[:200])):
        stop(name)
        return None
    if not check("[%s] worker healthy" % tag, wait_healthy(port, url), logs(name)[:400]):
        stop(name)
        return None
    for patch in (cards or []):
        st, doc = post_model(port, patch)
        if not check("[%s] POST /config/model %s 被接受" % (tag, patch.get("model")),
                     st == 200, "%s %s" % (st, json.dumps(doc)[:250])):
            stop(name)
            return None
    if entries is not None:
        st, doc = post_virtual(port, entries)
        if not check("[%s] POST /config/virtual 被接受" % tag, st == 200,
                     "%s %s" % (st, json.dumps(doc)[:300])):
            stop(name)
            return None
    return port, name, pm, url


def no_abort(tag, name):
    text = logs(name)
    check("[%s] 网关日志无 lua entry thread aborted" % tag,
          "lua entry thread aborted" not in text, text[-400:])


# ==================================================== S0 强制层（原有 4 条，守卫）

def scenario_forced():
    """LMR_MODEL_EFFORT 强制层与「卡片按**落点名**查」——改动前就有的行为，逐条保留。"""
    tag = "S0-forced"
    got = boot({"SMG_POLICY": "round_robin",
                "LMR_MODEL_EFFORT": "alpha:none",
                "LMR_DEFAULT_EFFORT": "high",
                "LMR_VIRTUAL_MODELS": "alias-a:alpha"},
               tag, model_name="alpha")
    if not got:
        return
    port, name, pm, url = got
    check("[%s] healthy" % tag, wait_healthy(port, url), logs(name)[:300])
    st, echo = send(port, "alpha", effort="ultra")
    check("[model effort] LMR_MODEL_EFFORT overrides the request",
          st == 200 and echo.get("reasoning_effort") == "none", json.dumps(echo)[:200])
    # per-model lookups key off the resolved target (Rust rewrites payload.model first)
    st, echo = send(port, "alias-a")
    check("[model effort] alias inherits the target's forced effort",
          st == 200 and echo.get("reasoning_effort") == "none"
          and echo.get("model") == "alpha", "%s %s" % (st, json.dumps(echo)[:200]))
    check("[model effort] no lua errors",
          "lua entry thread aborted" not in logs(name), logs(name)[-300:])
    stop(name)


# ==================================================== S1 三层齐全，卡片赢（守卫）

def scenario_card_wins():
    """同一个 from 三层都写了 → 卡片赢（落点引擎说的话压过入口与全局）。

    守卫：卡片命中自己声明过的 from 时新旧实现走同一条支路，它守的是新实现**内部**的优先
    级——把卡片映射改成条目优先，这一条立刻红。
    """
    tag = "S1-card"
    got = boot({"SMG_POLICY": "round_robin",
                "LMR_EFFORT_MAP": "high:high",                    # 全局 high -> high
                "LMR_MODEL_EFFORT_MAP": MODEL + ":high>low"},     # 卡片 high -> low
               tag, entries=[{"model": ALIAS, "target": MODEL,
                              "effort_map": [{"from": "high", "to": "medium"}]}])
    if not got:
        return
    port, name, pm, url = got
    st, echo = send(port, ALIAS, effort="high")
    check("[%s] 三层都写 high：转发体用的是卡片的 low（既不是条目的 medium 也不是全局的 high）"
          % tag, st == 200 and echo.get("reasoning_effort") == "low",
          "%s %s" % (st, json.dumps(echo)[:300]))
    check("[%s] 转发名仍是落点实际模型（改写没顺手改 model）" % tag,
          echo.get("model") == MODEL, json.dumps(echo)[:200])
    check("[%s] 只动顶层一个键：嵌套同名 / metadata / stop / tools 原位" % tag,
          decoys_intact(echo), json.dumps(echo)[:300])
    no_abort(tag, name)
    stop(name)


# ============================================ S2 卡片存在但缺这条 from → 落到条目

def scenario_card_missing_from():
    """【判据·最关键的一条】卡片存在但**没有这条 from** → 必须落到上层。

    旧实现：命中卡片分支后 `card.effort_map[level]` 查不到就 `return level` 原样透传，条目
    与全局的 high>medium 永远问不到 → 转发体是客户端点名的 high，本条红。未接线的 router
    （030dab5 之前）同样红：条目层根本没交给 store。
    """
    tag = "S2-entry"
    got = boot({"SMG_POLICY": "round_robin",
                "LMR_MODEL_EFFORT_MAP": MODEL + ":medium>low"},   # 卡片只声明 medium
               tag, entries=[{"model": ALIAS, "target": MODEL,
                              "effort_map": [{"from": "high", "to": "medium"}]}])
    if not got:
        return
    port, name, pm, url = got
    st, echo = send(port, ALIAS, effort="high")
    check("[%s] 卡片没有 high 这条 from：必须下沉到条目的 high>medium（旧实现在这里透传 high）"
          % tag, st == 200 and echo.get("reasoning_effort") == "medium",
          "%s %s" % (st, json.dumps(echo)[:300]))
    st, echo2 = send(port, ALIAS, effort="medium")
    check("[%s] 卡片自己声明过的 from 仍卡片赢（不是把卡片整层跳过）" % tag,
          st == 200 and echo2.get("reasoning_effort") == "low", json.dumps(echo2)[:300])
    check("[%s] 两次改写都只动顶层 reasoning_effort（诱饵原位）" % tag,
          decoys_intact(echo) and decoys_intact(echo2),
          json.dumps([echo, echo2])[:400])
    no_abort(tag, name)
    stop(name)


# ============================================ S3 卡片与条目都缺这条 from → 落到全局

def scenario_global_fallback():
    """【判据】卡片与条目都没写这条 from → 落到全局。

    1e57618 点名要修的静默失效：操作员在全局页填的 high>minimal，此前只要该模型有一张卡片
    （哪怕只管 ctx）就整层失效 → 旧实现原样透传 high，本条红。
    """
    tag = "S3-global"
    got = boot({"SMG_POLICY": "round_robin",
                "LMR_EFFORT_MAP": "high:minimal",                 # 全局 high -> minimal
                "LMR_MODEL_EFFORT_MAP": MODEL + ":medium>low"},   # 卡片没有 high
               tag, entries=[{"model": ALIAS, "target": MODEL,
                              "effort_map": [{"from": "low", "to": "xhigh"}]}])
    if not got:
        return
    port, name, pm, url = got
    st, echo = send(port, ALIAS, effort="high")
    check("[%s] 卡片与条目都没写 high：全局的 high>minimal 必须生效（旧实现在这里透传 high）"
          % tag, st == 200 and echo.get("reasoning_effort") == "minimal",
          "%s %s" % (st, json.dumps(echo)[:300]))
    st, echo2 = send(port, ALIAS, effort="low")
    check("[%s] 条目写过的 low>xhigh 压过全局：顺序仍是卡片→条目→全局" % tag,
          st == 200 and echo2.get("reasoning_effort") == "xhigh", json.dumps(echo2)[:300])
    no_abort(tag, name)
    stop(name)


# ================================================ S4 三层全空 → 转发体不带那个键

def scenario_no_layer():
    """【守卫】三层全空且请求没点名 → 转发体**不带** reasoning_effort 键。

    判的是「键缺席」（`not in echo`），不是「等于某个值」——写成 == None 会被 null 或空串
    冒充骗过。卡片在场但只有 context_limit 读数（没有任何 effort 位）时同样不许凭空造一个
    键：这正是 2026-10-04 那次「网关替客户端造数」事故的 effort 版本。
    """
    tag = "S4-empty"
    got = boot({"SMG_POLICY": "round_robin"}, tag,
               cards=[{"model": MODEL, "ctx": 8192, "context_limit": 8192}],
               entries=[{"model": ALIAS, "target": MODEL}])
    if not got:
        return
    port, name, pm, url = got
    st, echo = send(port, ALIAS)
    check("[%s] 三层全空 + 没点名：转发体里没有 reasoning_effort 这个键（缺席，不是等于某值）"
          % tag, st == 200 and "reasoning_effort" not in echo, json.dumps(echo)[:400])
    check("[%s] 除 model 外转发体与请求逐字段相同（一个键没多、一个键没少）" % tag,
          echo.get("messages") == [{"role": "user", "content": PROBE,
                                    "reasoning_effort": "nested-keep"}]
          and echo.get("metadata") == {"reasoning_effort": "nested-keep"}
          and echo.get("tools") == [] and echo.get("stop") == ["reasoning_effort"]
          and echo.get("temperature") == 0.5, json.dumps(echo)[:400])
    st, echo3 = send(port, ALIAS, effort="turbo")
    check("[%s] 客户端亲口的未知档位原样透传（没人规定改写就不改）" % tag,
          st == 200 and echo3.get("reasoning_effort") == "turbo", json.dumps(echo3)[:200])
    no_abort(tag, name)
    stop(name)


# ============================================ S5 条目层完全未声明（接线前的逐字节一致）

def scenario_entry_undeclared_guard():
    """【守卫】条目层完全没声明时结果与接线前逐字节一致。

    期望写成**死的字段表**（点名过的按卡片/全局改写、没点名的用全局缺省档、未知档位透传），
    而不是「和另一次请求一样」这种恒真比较。这条在改动前的实现上也该绿——绿在旧版正是
    「新开关缺省零行为变化」应有的样子，所以它是守卫不是判据。
    """
    tag = "S5-guard"
    got = boot({"SMG_POLICY": "round_robin",
                "LMR_DEFAULT_EFFORT": "medium",
                "LMR_EFFORT_MAP": "high:low"},
               tag, entries=[{"model": ALIAS, "target": MODEL}])
    if not got:
        return
    port, name, pm, url = got
    expected = {"high": "low", "low": "low", "medium": "medium", "ultra": "ultra"}
    for wanted, want in sorted(expected.items()):
        st, echo = send(port, ALIAS, effort=wanted)
        check("[%s] 点名 %s → 转发 %s（条目层不在场，字节与接线前一致）" % (tag, wanted, want),
              st == 200 and echo.get("reasoning_effort") == want
              and echo.get("model") == MODEL and decoys_intact(echo),
              "%s %s" % (st, json.dumps(echo)[:300]))
    st, echo = send(port, ALIAS)
    check("[%s] 没点名 → 用全局缺省档 medium" % tag,
          st == 200 and echo.get("reasoning_effort") == "medium", json.dumps(echo)[:300])
    no_abort(tag, name)
    stop(name)


# ================================================ S6 条目缺省档 vs 卡片缺省档

def scenario_entry_default_effort():
    """【判据】卡片存在但没声明缺省档 → 必须让位条目的 default_effort。

    旧实现的卡片分支查不到 card.default_effort 就 `return cfg.default_effort`，条目层整个
    被跳过 → 转发体是全局的 low，本条红。成对的第二条（卡片登记了缺省档则卡片优先）防的是
    修过头把卡片整层废掉。
    """
    tag = "S6-default"
    got = boot({"SMG_POLICY": "round_robin",
                "LMR_DEFAULT_EFFORT": "low",
                "LMR_MODEL_EFFORT_MAP": MODEL + ":high>minimal"},
               tag, entries=[{"model": ALIAS, "target": MODEL,
                              "default_effort": "xhigh"}])
    if not got:
        return
    port, name, pm, url = got
    st, echo = send(port, ALIAS)
    check("[%s] 卡片存在却没声明缺省档：条目的 default_effort 压过全局的 low"
          "（旧实现在这里给 low）" % tag,
          st == 200 and echo.get("reasoning_effort") == "xhigh",
          "%s %s" % (st, json.dumps(echo)[:300]))
    st, doc = post_model(port, {"model": MODEL, "default_effort": "none"})
    check("[%s] 卡片登记 default_effort 被接受" % tag, st == 200,
          "%s %s" % (st, json.dumps(doc)[:250]))
    st, echo = send(port, ALIAS)
    check("[%s] 卡片声明了缺省档时卡片优先（条目让位）" % tag,
          st == 200 and echo.get("reasoning_effort") == "none", json.dumps(echo)[:300])
    no_abort(tag, name)
    stop(name)


# ================================================ S7 条目层的落盘、回显与非法值

def scenario_declaration_round_trip():
    """条目声明位必须真的落盘、回显、被热路径读到（HTTP 权威面的证据）。

    判别性：这条先于转发改写一步钉住「有没有落盘」，红的时候能区分「写侧就没收下这个字段」
    与「收下了但热路径不读」（后者由 S2/S3/S6 红、这一条绿来定位）。非法值必须 400 并点名
    到具体字段，而不是静默当成「没写」。
    """
    tag = "S7-roundtrip"
    got = boot({"SMG_POLICY": "round_robin"}, tag,
               entries=[{"model": ALIAS, "target": MODEL,
                         "effort_map": [{"from": "high", "to": "medium"},
                                        {"from": "minimal", "to": "low"}],
                         "default_effort": "xhigh"}])
    if not got:
        return
    port, name, pm, url = got
    st, text, _ = http("GET", "http://127.0.0.1:%d/config" % port)
    check("[%s] GET /config 200" % tag, st == 200, "%s %s" % (st, str(text)[:200]))
    rows = [e for e in (json.loads(text).get("virtual_models") or [])
            if e.get("model") == ALIAS]
    entry = rows[0] if rows else {}
    check("[%s] 条目层的 effort_map / default_effort 往返落盘" % tag,
          sorted([(m.get("from"), m.get("to")) for m in (entry.get("effort_map") or [])])
          == [("high", "medium"), ("minimal", "low")]
          and entry.get("default_effort") == "xhigh", json.dumps(entry)[:300])
    st, echo = send(port, ALIAS, effort="minimal")
    check("[%s] 落盘的条目映射确实被热路径读到（minimal>low）" % tag,
          st == 200 and echo.get("reasoning_effort") == "low", json.dumps(echo)[:300])
    st, echo = send(port, ALIAS)
    check("[%s] 落盘的条目 default_effort 被热路径读到（没点名 → xhigh）" % tag,
          st == 200 and echo.get("reasoning_effort") == "xhigh", json.dumps(echo)[:300])
    # 非法值必须 400 并点名到具体字段，而不是静默当成「没写」；且被拒的批次一份都不生效
    # （apply_virtual_models 是整表替换，静默收下坏批次会同时抹掉好的那一层）。
    st, doc = post_virtual(port, [{"model": ALIAS, "target": MODEL,
                                   "effort_map": [{"from": "high", "to": "nope"}]}])
    check("[%s] 条目 effort_map 的非法 to 被拒绝保存" % tag, st == 400,
          "%s %s" % (st, json.dumps(doc)[:250]))
    st, doc = post_virtual(port, [{"model": ALIAS, "target": MODEL,
                                   "default_effort": "nope"}])
    check("[%s] 条目 default_effort 的非法档位被拒绝保存" % tag, st == 400,
          "%s %s" % (st, json.dumps(doc)[:250]))
    st, echo = send(port, ALIAS, effort="minimal")
    check("[%s] 两个被拒批次没有改动生效配置（minimal 仍 → low）" % tag,
          st == 200 and echo.get("reasoning_effort") == "low", json.dumps(echo)[:250])
    # legacy 的条目 effort 位仍是「接受 + 往返 + 热路径不读」（用户裁定 2026-10-02）：
    # 新名字与它并存互不干扰，这一条钉住 1e57618 刻意不动的那半边。整表替换会把
    # effort_map 换掉，所以此处只判 legacy 位不驱动改写、新位照常生效。
    st, doc = post_virtual(port, [{"model": ALIAS, "target": MODEL,
                                   "effort": "max", "default_effort": "xhigh"}])
    check("[%s] legacy 条目 effort 与新 default_effort 并存被接受" % tag, st == 200,
          "%s %s" % (st, json.dumps(doc)[:250]))
    rows = [e for e in ((json.loads(http("GET", "http://127.0.0.1:%d/config" % port)[1])
                        .get("virtual_models") or [])) if e.get("model") == ALIAS]
    check("[%s] legacy effort=max 照旧往返落盘（不与新位互相覆盖）" % tag,
          bool(rows) and rows[0].get("effort") == "max"
          and rows[0].get("default_effort") == "xhigh", json.dumps(rows)[:300])
    st, echo = send(port, ALIAS, effort="high")
    check("[%s] legacy 条目 effort=max 不参与改写：没人规定 high 就原样透传" % tag,
          st == 200 and echo.get("reasoning_effort") == "high", json.dumps(echo)[:250])
    st, echo = send(port, ALIAS)
    check("[%s] 同一条目的新 default_effort 仍生效（xhigh）" % tag,
          st == 200 and echo.get("reasoning_effort") == "xhigh", json.dumps(echo)[:250])
    no_abort(tag, name)
    stop(name)


def main():
    handle = acquire_gate_lock()
    if handle is None:
        print("SKIP: /data/tmp/lr-e2e.lock held by another gate for >10 min; "
              "no container started in this run")
        sys.exit(2)
    print("mode: %s" % (("LEGACY lualib = " + LEGACY_LUALIB) if LEGACY_LUALIB
                        else "HEAD (盘上 lualib)"))
    failed = []
    try:
        scenario_forced()
        scenario_card_wins()
        scenario_card_missing_from()
        scenario_global_fallback()
        scenario_no_layer()
        scenario_entry_undeclared_guard()
        scenario_entry_default_effort()
        scenario_declaration_round_trip()
    finally:
        failed = [r for r in RESULTS if not r[0]]
        print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
        for _, name, detail in failed:
            print("FAILED: %s | %s" % (name, str(detail)[:400]))
        cleanup()
        try:
            fcntl.flock(handle, fcntl.LOCK_UN)
        finally:
            handle.close()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
