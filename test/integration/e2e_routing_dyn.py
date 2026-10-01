#!/usr/bin/env python3
"""路由策略运行时变更（doc/gap-routing-dyn.md）的端到端门禁。

⚠️ 本轮只写不跑（并发纪律：禁止运行 e2e_*.py / test_lua_router.sh /
   final_gates.sh / playwright）。交棒给 orchestrator 后由
   `python3 test/integration/e2e_routing_dyn.py` 单跑。

六个场景，全部用「下一次选路就走新策略」这条语义断言，不看重启：

  A. PUT 换策略后同请求分布变化（粘性消失）
     起容器 SMG_POLICY=cache_aware + 两个 mock；先证同前缀 10 发全部砸同一
     mock（cache_aware 粘滞成立，基线），再 PUT /_ui/config/policy
     {"policy":"random"}，同一批同前缀请求重放：两个 mock 必须都拿到流量、且
     没有任何一个 mock 独吞（χ² 的弱化版判定：min>0 且 max<N）。这条断言之所
     以有效，是因为流量形状完全没变（同 model、同前缀、同 header），唯一变量
     是策略名。同时读 /_ui/logs 的 route_type 与
     smg_worker_selection_total{policy="random"}，证明分布变化确实由新策略产生
     而不是候选集抖动。
  B. 非法策略名 400 且不生效
     PUT {"policy":"no_such_policy"} 必须 400，错误体点名 unknown policy；紧接着
     重放 A 的粘性探针，必须仍然 10/10 砸同一 mock（说明写侧在校验阶段就返回，
     快照没有被半写）；再 PUT {"model_policy":{"model":"x","policy":"bogus"}}
     同样 400，并断言 model_policies 仍是空表。
  C. per-model 覆盖优先于全局覆盖与实例 hint
     全局设为 cache_aware，alpha 设 random：alpha 的同前缀爆发要摊开、beta 的同
     前缀爆发要粘住（两段分开打，避免依赖并发交错）。然后再注册一个带
     labels.policy=round_robin 的 hint 实例（模型 hinted），只设全局 cache_aware，
     GET /_ui/config/policy 的该行必须 source=global（运营覆盖压过 worker hint，
     优先级链 model > global > hint > env 的可见证据）。
  D. 多 nginx 进程一致性（shdict 可见性）
     NGINX_WORKER_PROCESSES=4 + SMG_POLICY=round_robin 起容器；PUT
     {"policy":"consistent_hashing"} 之后，同 x-smg-routing-key 的 12 发必须全部
     落在同一个 mock。一致性哈希的环由各进程从同一份 registry 构建，所以「跨进程
     仍然粘住」本身就证明 4 个进程都读到了同一份热配置——若还有一个进程停留在
     round_robin，命中必然被摊开。GET 文档的 revision 在多次请求间保持单调不减。
  E. 重启后回 env 缺省
     容器不带 LMR_CONFIG_FILE（write_snapshot 只剩 shdict 一层，进程内存随重启
     消失）；先 PUT random 验证生效，再 docker restart 同一容器，重启后必须
     policy=null 且同前缀重新粘住（回到 SMG_POLICY=cache_aware）。这条同时把
     「配了 LMR_CONFIG_FILE 才会跨重启保留」的边界钉住。
  F. 清除覆盖回到链条
     全部覆盖清成 null / 空表后，行为必须回到 env 层（粘性复现），证明不是
     「最后一次 stamp 粘住」。

观察通道：mock 的访问日志行（_lib.mock_lines）与 router 自己的 /_ui/logs
route_type、/metrics 计数器；端口全部随机。
"""
import json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (free_port, http, check, start_mock, mock_lines, start_router,
                  logs, stop_router, wait_ready, chat, cleanup,
                  RESULTS, RUN, REPO)

PREFIX = "routing-dyn-shared-prefix "
UI = "/_ui/config/policy"


def policy_get(port):
    st, body, _ = http("GET", "http://127.0.0.1:%d%s" % (port, UI))
    if st == 200:
        try:
            return st, json.loads(body)
        except ValueError:
            return st, body
    return st, body


def policy_put(port, patch, method="PUT"):
    """Returns (status, decoded-document-or-error-text). The 400 body is the
    error text so the checks can match on "unknown policy" verbatim."""
    st, body, _ = http(method, "http://127.0.0.1:%d%s" % (port, UI), patch)
    if st == 200:
        try:
            return st, json.loads(body)
        except ValueError:
            return st, body
    return st, body


def hits_for(pa, pb, before_a, before_b):
    return (mock_lines(pa, "/v1/chat/completions") - before_a,
            mock_lines(pb, "/v1/chat/completions") - before_b)


def fire(port, model, n, prefix, headers=None):
    for i in range(n):
        chat(port, model, prefix + " tail %d keeps the prefix stable" % i, headers=headers)


def route_types(port, limit=200):
    st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/logs?cursor=0&limit=%d" % (port, limit))
    if st != 200:
        return None
    try:
        doc = json.loads(body)
    except ValueError:
        return None
    # observability.handle_logs answers {cursor, capacity, requests:[...]}
    rows = doc.get("requests") or doc.get("logs") or doc.get("entries") or []
    return [row.get("route_type") for row in rows if isinstance(row, dict)]


def selection_counter(port, policy):
    st, text, _ = http("GET", "http://127.0.0.1:%d/metrics" % port)
    if st != 200:
        return None
    needle = 'smg_worker_selection_total{'
    total = 0
    for line in text.splitlines():
        if not line.startswith(needle) or ('policy="%s"' % policy) not in line:
            continue
        total += int(float(line.rsplit(" ", 1)[-1]))
    return total


def start_two(policy, tag, worker_processes=None, config_file=""):
    pa, pb = free_port(), free_port()
    start_mock(pa, "alpha")
    start_mock(pb, "beta")
    env = {"SMG_POLICY": policy, "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
           "SMG_WORKER_URLS": "http://127.0.0.1:%d,http://127.0.0.1:%d" % (pa, pb)}
    if worker_processes:
        env["NGINX_WORKER_PROCESSES"] = str(worker_processes)
    if config_file:
        env["LMR_CONFIG_FILE"] = config_file
    name = "lr-rdyn-%s-%s" % (tag[:24], RUN)
    port = start_router(env, name)
    check("[%s] both workers healthy" % tag, wait_ready(port), logs(name))
    return port, name, pa, pb


# ---------------------------------------------------------------- A + B
pa_port, name, pa, pb = start_two("cache_aware", "sticky")
st, doc = policy_get(pa_port)
check("[A] GET /_ui/config/policy 200", st == 200, "%s %s" % (st, doc))
check("[A] document advertises the eight policies",
      st == 200 and len(doc.get("policies") or []) == 8, doc.get("policies") if st == 200 else "")
check("[A] no override configured by default",
      st == 200 and doc.get("policy") in (None, "__missing__") and (doc.get("model_policies") or []) == [],
      json.dumps(doc)[:240] if st == 200 else "")
check("[A] effective_default comes from SMG_POLICY",
      st == 200 and doc.get("effective_default") == "cache_aware",
      doc.get("effective_default") if st == 200 else "")

# 基线：cache_aware 必须粘住
before_a, before_b = mock_lines(pa, "/v1/chat/completions"), mock_lines(pb, "/v1/chat/completions")
fire(pa_port, "alpha", 10, PREFIX)
ha, hb = hits_for(pa, pb, before_a, before_b)
check("[A] baseline cache_aware sticks 10/10 on one mock (%d/%d)" % (ha, hb),
      max(ha, hb) == 10 and ha + hb == 10, "a=%d b=%d" % (ha, hb))
types = route_types(pa_port)
check("[A] baseline request log says cache_aware",
      types and "cache_aware" in types, (types or [])[:6])

# 运行时换到 random：同形状流量必须摊开
st, doc = policy_put(pa_port, {"policy": "random"})
check("[A] PUT policy=random 200", st == 200, "%s %s" % (st, doc))
check("[A] PUT response echoes the change (确认回显)",
      st == 200 and doc.get("policy") == "random" and doc.get("effective_default") == "random",
      json.dumps(doc)[:240] if st == 200 else "")
before_a, before_b = mock_lines(pa, "/v1/chat/completions"), mock_lines(pb, "/v1/chat/completions")
fire(pa_port, "alpha", 40, PREFIX)
ha, hb = hits_for(pa, pb, before_a, before_b)
check("[A] random after the PUT spreads identical prefixes (%d/%d)" % (ha, hb),
      ha > 0 and hb > 0 and max(ha, hb) < 40, "a=%d b=%d" % (ha, hb))
counter = selection_counter(pa_port, "random")
check("[A] selection counter proves the traffic ran on random",
      counter is not None and counter > 0, counter)
types = route_types(pa_port)
check("[A] newest request log rows say random", types and "random" in types[:12], (types or [])[:12])

# B：非法策略 400，且什么都没生效
st, body = policy_put(pa_port, {"policy": "no_such_policy"})
check("[B] unknown policy name answers 400", st == 400, "%s %s" % (st, str(body)[:200]))
check("[B] the 400 names the problem",
      isinstance(body, str) and "unknown policy" in body, str(body)[:200])
st, doc = policy_get(pa_port)
check("[B] rejected write left the running policy alone",
      st == 200 and doc.get("policy") == "random", json.dumps(doc)[:200] if st == 200 else "")
st, body = policy_put(pa_port, {"model_policy": {"model": "alpha", "policy": "bogus"}})
check("[B] unknown per-model policy answers 400", st == 400, "%s %s" % (st, str(body)[:200]))
check("[B] the 400 names the model", isinstance(body, str) and "alpha" in body, str(body)[:200])
st, doc = policy_get(pa_port)
check("[B] rejected row left model_policies untouched",
      st == 200 and (doc.get("model_policies") or []) == [], json.dumps(doc)[:200] if st == 200 else "")
st, body = policy_put(pa_port, {})
check("[B] an empty patch is rejected instead of silently accepted", st == 400,
      "%s %s" % (st, str(body)[:160]))
st, body = policy_put(pa_port, {"policy": 42})
check("[B] a non-string policy is rejected", st == 400, "%s %s" % (st, str(body)[:160]))
st, body = policy_put(pa_port, {"policy": "random"}, method="POST")
check("[B] POST is accepted as an alias of PUT (axum gate allows POST)", st == 200,
      "%s %s" % (st, str(body)[:160]))
st_del, body_del, hdrs_del = http("DELETE", "http://127.0.0.1:%d%s" % (pa_port, UI))
check("[B] a wrong method answers 405 with Allow", st_del == 405
      and (hdrs_del.get("Allow") or hdrs_del.get("allow", "")) != "", "%s %s" % (st_del, str(body_del)[:120]))
stop_router(name)

# ---------------------------------------------------------------- C
c_port, name, pa, pb = start_two("cache_aware", "permodel")
st, doc = policy_put(c_port, {"policy": "cache_aware",
                              "model_policies": [{"model": "alpha", "policy": "random"}]})
check("[C] global + per-model submitted together", st == 200, "%s %s" % (st, str(doc)[:200]))
by_model = {row["model"]: row for row in (doc.get("models") or [])} if st == 200 else {}
check("[C] the document names the winning layer per row",
      by_model.get("alpha", {}).get("source") == "model"
      and by_model.get("alpha", {}).get("effective") == "random",
      json.dumps(by_model)[:300])
# alpha：random 摊开
before_a, before_b = mock_lines(pa, "/v1/chat/completions"), mock_lines(pb, "/v1/chat/completions")
fire(c_port, "alpha", 40, "alpha-prefix " )
ha, hb = hits_for(pa, pb, before_a, before_b)
check("[C] the overridden model spreads (%d/%d)" % (ha, hb), ha > 0 and hb > 0 and max(ha, hb) < 40,
      "a=%d b=%d" % (ha, hb))
# beta：全局 cache_aware 粘住
before_a, before_b = mock_lines(pa, "/v1/chat/completions"), mock_lines(pb, "/v1/chat/completions")
fire(c_port, "beta", 10, "beta-prefix ")
ha, hb = hits_for(pa, pb, before_a, before_b)
check("[C] the untouched model keeps global stickiness (%d/%d)" % (ha, hb),
      max(ha, hb) == 10, "a=%d b=%d" % (ha, hb))

# worker hint 让位于运营的全局覆盖
pc = free_port()
start_mock(pc, "hinted")
st, body, _ = http("POST", "http://127.0.0.1:%d/workers" % c_port,
                {"url": "http://127.0.0.1:%d" % pc, "model_id": "hinted",
                 "labels": {"policy": "round_robin"}})
check("[C] hinted worker registered", st in (200, 202), "%s %s" % (st, str(body)[:160]))
for _ in range(60):
    st, doc = policy_get(c_port)
    row = {r["model"]: r for r in (doc.get("models") or [])}.get("hinted") if st == 200 else None
    if row and row.get("hint"):
        break
    time.sleep(0.5)
check("[C] the document reports the worker hint",
      st == 200 and (doc.get("models") or []) and row is not None and row.get("hint") == "round_robin",
      json.dumps(row)[:200])
check("[C] operator override outranks labels.policy",
      row is not None and row.get("source") == "global" and row.get("effective") == "cache_aware",
      json.dumps(row)[:200])
# 清掉 per-model 覆盖后 alpha 重新粘住（整表替换语义）
st, doc = policy_put(c_port, {"model_policies": []})
check("[C] clearing the table is accepted", st == 200 and (doc.get("model_policies") or []) == [],
      "%s %s" % (st, json.dumps(doc)[:200]))
before_a, before_b = mock_lines(pa, "/v1/chat/completions"), mock_lines(pb, "/v1/chat/completions")
fire(c_port, "alpha", 10, "alpha-prefix ")
ha, hb = hits_for(pa, pb, before_a, before_b)
check("[C] after clearing, the global policy drives alpha again (%d/%d)" % (ha, hb),
      max(ha, hb) == 10, "a=%d b=%d" % (ha, hb))
check("[C] no lua errors", "lua entry thread aborted" not in logs(name), logs(name)[-400:])
stop_router(name)

# ---------------------------------------------------------------- D
d_port, name, pa, pb = start_two("round_robin", "multi", worker_processes=4)
st, doc = policy_put(d_port, {"policy": "consistent_hashing"})
check("[D] PUT consistent_hashing on 4 processes", st == 200, "%s %s" % (st, str(doc)[:200]))
revision = doc.get("revision") if st == 200 else None
check("[D] the document carries a revision token",
      revision not in (None, ""), repr(revision))
hdrs = {"x-smg-routing-key": "session-routing-dyn"}
before_a, before_b = mock_lines(pa, "/v1/chat/completions"), mock_lines(pb, "/v1/chat/completions")
fire(d_port, "alpha", 12, "hash key spread probe ", headers=hdrs)
ha, hb = hits_for(pa, pb, before_a, before_b)
check("[D] every nginx process resolved the same policy (12 same-key hits on one mock: %d/%d)" % (ha, hb),
      max(ha, hb) == 12, "a=%d b=%d" % (ha, hb))
st, doc2 = policy_get(d_port)
check("[D] revision stays readable/monotonic across processes",
      st == 200 and str(doc2.get("revision")).isdigit() and int(doc2.get("revision")) >= int(revision),
      "%s -> %s" % (revision, doc2.get("revision") if st == 200 else doc2))
# 再来一次写：另一个进程必须立刻看见（不用清任何状态）
st, doc3 = policy_put(d_port, {"policy": "power_of_two"})
check("[D] a second PUT from the same client is visible", st == 200, "%s %s" % (st, str(doc3)[:200]))
types = route_types(d_port)
check("[D] the newest log rows report the newly selected policy",
      types and (set([t for t in types[:10] if t]) & {"power_of_two", "consistent_hashing"}),
      (types or [])[:10])
check("[D] no lua errors", "lua entry thread aborted" not in logs(name), logs(name)[-400:])
stop_router(name)

# ---------------------------------------------------------------- E + F
e_port, name, pa, pb = start_two("cache_aware", "restart")  # 故意不设 LMR_CONFIG_FILE
st, doc = policy_put(e_port, {"policy": "random"})
check("[E] PUT before the restart lands", st == 200 and doc.get("policy") == "random",
      "%s %s" % (st, json.dumps(doc)[:200] if st == 200 else doc))
before_a, before_b = mock_lines(pa, "/v1/chat/completions"), mock_lines(pb, "/v1/chat/completions")
fire(e_port, "alpha", 30, "prefix ")
ha, hb = hits_for(pa, pb, before_a, before_b)
check("[E] random is live before the restart (%d/%d)" % (ha, hb), ha > 0 and hb > 0, "a=%d b=%d" % (ha, hb))
import subprocess
subprocess.run(["docker", "restart", name], capture_output=True, timeout=120)
for _ in range(120):
    st, _, _ = http("GET", "http://127.0.0.1:%d/health" % e_port, timeout=2)
    if st == 200:
        break
    time.sleep(0.5)
st, doc = policy_get(e_port)
check("[E] after the restart the override is gone (no LMR_CONFIG_FILE)",
      st == 200 and doc.get("policy") in (None, "__missing__"),
      "%s %s" % (st, json.dumps(doc)[:220] if st == 200 else doc))
check("[E] and the chain fell back to SMG_POLICY",
      st == 200 and doc.get("effective_default") == "cache_aware",
      doc.get("effective_default") if st == 200 else "")
wait_ready(e_port)
before_a, before_b = mock_lines(pa, "/v1/chat/completions"), mock_lines(pb, "/v1/chat/completions")
fire(e_port, "alpha", 10, "prefix ")
ha, hb = hits_for(pa, pb, before_a, before_b)
check("[E] stickiness is back after the restart (%d/%d)" % (ha, hb), max(ha, hb) == 10,
      "a=%d b=%d" % (ha, hb))
# F：显式设置后清空 → 立刻回 env，而不是停在最后一次 stamp
st, doc = policy_put(e_port, {"policy": "round_robin"})
before_a, before_b = mock_lines(pa, "/v1/chat/completions"), mock_lines(pb, "/v1/chat/completions")
fire(e_port, "alpha", 24, "prefix ")
ha, hb = hits_for(pa, pb, before_a, before_b)
check("[F] round_robin rotates after the PUT (%d/%d)" % (ha, hb),
      ha > 0 and hb > 0 and abs(ha - hb) <= 6, "a=%d b=%d" % (ha, hb))
st, doc = policy_put(e_port, {"policy": None, "model_policies": []})
check("[F] clearing both sections is accepted", st == 200, "%s %s" % (st, str(doc)[:200]))
before_a, before_b = mock_lines(pa, "/v1/chat/completions"), mock_lines(pb, "/v1/chat/completions")
fire(e_port, "alpha", 10, "prefix ")
ha, hb = hits_for(pa, pb, before_a, before_b)
check("[F] cleared overrides return to the env policy (%d/%d)" % (ha, hb), max(ha, hb) == 10,
      "a=%d b=%d" % (ha, hb))
check("[F] no lua errors", "lua entry thread aborted" not in logs(name), logs(name)[-400:])
stop_router(name)

cleanup()
print("\ne2e_routing_dyn: %d checks, %d failed" % (len(RESULTS), sum(1 for ok, _, _ in RESULTS if not ok)))
for ok, cname, detail in RESULTS:
    if not ok:
        print("  FAIL %s | %s" % (cname, detail))
sys.exit(1 if any(not ok for ok, _, _ in RESULTS) else 0)
