#!/usr/bin/env python3
"""e2e：虚拟模型多绑定（需求 A）+ 每服务并发/功率上限（需求 B）。

跑法（门禁纪律：本文件全部是 lr- 前缀容器 + host 侧 mock，跑前必须确认没有别的门禁在
跑，严禁并发）：
    python3 test/integration/e2e_caps.py

为什么这份文件用 CONF_TEST(_lib.probe_container) 而不是 _lib.start_router：
  1. 本轮同时给 test/conf/nginx-lua-router.conf 补三条 SMG_LOAD_POWER* 的 env 声明。
     nginx 按 env 白名单重建 worker 环境，gpu_load 的功率开关又是在 worker 定时器里
     os.getenv 现读，所以声明漏了就静默失效——断言必须跑在**被改的那份 conf** 上才有
     意义，只有 CONF_TEST 容器能把这个失效照出来（与上次补 SMG_WATCHER_PROBE_FAILURES
     同一性质）。
  2. probe_container 把仓库只读挂在 /repo，lua_package_path 第一位就是 /repo/lualib，
     跑的是**盘上的 lualib**：不必重建镜像，也不会把并行 agent 未完成的改动烧进镜像层。
  3. CONF_TEST 的 resolver 是 127.0.0.11（docker 内嵌 DNS），只在 bridge 网络里存在，
     所以这里沿用契约套件同一形态：容器走 bridge + 随机发布端口，worker url 用 docker
     网桥网关地址（test_lua_router.sh 的 container_gateway 同一做法）。

七个场景（每个的"实现写错必然红"的判别性断言写在各自 docstring 里）：
  S1        一个别名绑两台实例的两个不同模型，IGW=1 与 IGW=0 两组都要两条路径各自服务、
            转发体 model 就是绑定名；未绑定的裸名请求仍被 IGW 收窄；同一 worker 绑两个
            模型 400；candidates-only 的文档不许长出没人声明的 target。
  S2        max_concurrency=1（三态断言）：长响应压出真并发，后续请求一条都不许多进
            那台；/workers 的 load_state 跟着判定变色（idle 在场、到顶 full、无门行
            **键缺席**而不是 null）；解除后可选。排除计数按 reason=concurrency_max，
            旧的 "concurrency"/"power" 两个 reason 拼写不再出现。
  S3        max_gpu_util：GPU 利用率读数超上限→迁走（连显式 pin 都带不走它）；读数
            缺失（两族 gauge 一起撤走=未知）→不排除。瓦特通道保留为纯观测：本场同时
            让无上限的 B 做全场最热瓦特台（300 W），实现若还按 pw: 做容量判定，B 被
            摘走 → 当场红。排除计数按 reason=gpu_util。
  S3b       同机逐卡归属（生产 342.371 的回归门，利用率口径）：同一份三卡正文
            （gpu 0/1/2 = 12/82/37 %）下三台 worker 各自 labels.gpu 指一张、各挂
            max_gpu_util=50，gpu_util 必须**精确**等于自己那张卡的读数
            （0.12/0.82/0.37）且三者互不相同；实现若取整机 max，三台全 0.82 全被排除
            → spread/pin 断言当场红。lr_gpu_load_util_per_card_workers 必须到 3
            （「各归各卡」与「共用整机 max」在 matched 一个数上同形，那是 342.371
            长期无人察觉的观测盲区）。反向断言：把某台的两族 gpu-util series 全撤
            → 该台 gpu_util 缺席（不是 0、不是整机 max、不是邻居那张卡的读数）→
            它必须恢复可选（pin 200 通流量）。
  S8        caps 跨声明层与跨重启存活（用户报的"max_concurrency 配了重启就没"）：
            两行都由 SMG_WORKER_URLS 播种成 protected 裸记录（记录层 discovery=nil），
            声明层下发 caps 必须落到 protected 行、且 caps-only（同一条声明里的 model_id
            被拒——身份红线不跟着放开）；docker restart 后 caps 自己回来并**当场挡住流量**。
  S4        cache_aware 亲和对抗：同前缀粘在 X 后把 X 打到上限，同前缀请求必须改投 Y；
            解除上限后 X 重新可选（pin 与全新前缀两条路径都验）。
  S5        全场上限→**429**（2026-10-06 §4 用户裁定，覆盖旧的"全到顶 503"），
            X-SMG-Error-Code 仍是 no_available_workers、error.type 变 Too Many
            Requests、message 精确等于 "No available workers (N at their concurrency
            or GPU-util limit)"；对照"非上限造成的 503"（熔断/不健康）文案保持原样。
  S5d       声明层三字段自动化（2026-10-06 §1 的 POST 面）：min>=max 拒、util=0 保留、
            util=101 拒、旧 max_power_w 被 warn 丢弃且不落盘——四条都必须过真 HTTP 的
            POST /_ui/config/upstreams（探针 lr_caps_store_probe.lua 的边界组上闸）。
  S5c       缺省配置（不设上限、不设 candidates）老行为零变化：spread 照旧、排除计数
            与绿灯优先让位计数都为 0。
  S1 交集    candidates 与旧 workers 同时存在时取交集（candidates_for 的 2026-10-01
            收紧）：白名单能收窄、能把候选清成空集（503 且不泄漏到绑定实例），
            两张表都在时结果 = 交集；新字段绝不放宽旧字段已经限制的权限。
  S7        IGW 模型门四条款里最尖锐的一条：config 声明行**改名**后，旧名必须
            非 200（patch_record 把 models_verified 清零 + refresh_models 的 300 s
            mp: 冷却让折叠残留不足以翻案）、新名必须 200。
  S6        功率通道开关可见性：启用后 lr_gpu_load_power_watts{worker=} 是绝对瓦特（>1）、
            lr_gpu_load_power_samples_total 随 tick 增长；缺省关闭时 lr_gpu_load_power*
            一个 series 都不出现，而负载族 lr_gpu_load 仍在（负断言的假绿对照）。
"""
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (RUN, RESULTS, free_port, http, check, start_mock, mock_lines,
                  logs, stop_router, cleanup, probe_container)

# 这份 conf 的 listen 写死 8080（没有 SMG_PORT 的位置），端口靠 -p 127.0.0.1::8080
# 随机发布；cache_aware 的亲和树是每进程的，钉成 1 个进程才有确定性。
BASE_ENV = {
    "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
    "NGINX_WORKER_PROCESSES": "1",
    "SMG_LOG_LEVEL": "warn",
}
GATEWAY_FALLBACK = "172.17.0.1"


def start_conf_container(env, tag):
    """Start test/conf/nginx-lua-router.conf as lr-<tag>-<RUN>; return (port, name, gw).

    gw 是容器眼里"宿主机"的地址：bridge 网络里 127.0.0.1 不是宿主机，mock 必须用
    docker 网桥网关地址注册，否则健康巡检与转发全部连不上。"""
    name = "lr-%s-%s" % (tag[:28], RUN)
    full = dict(BASE_ENV)
    full.update({k: str(v) for k, v in (env or {}).items()})
    port = probe_container(full, name)
    out = subprocess.run(
        ["docker", "inspect", "-f",
         "{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}", name],
        capture_output=True)
    gw = out.stdout.decode().strip() or GATEWAY_FALLBACK
    return port, name, gw


def docker_logs_full(name):
    r = subprocess.run(["docker", "logs", name], capture_output=True)
    return r.stderr.decode() + "\n" + r.stdout.decode()


def check_no_abort(tag, name):
    """网关日志里不许出现 lua entry thread aborted（看整段日志，不是 tail）。"""
    text = docker_logs_full(name)
    check("[%s] no 'lua entry thread aborted' in the gateway log" % tag,
          "lua entry thread aborted" not in text, text[-400:])


def start_mock_env(port, model, **flags):
    """start_mock with mock-side env knobs exported while it boots (LATENCY_MS 等)。"""
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


# ------------------------------------------------------------------ 请求与观测小工具

class Reply(object):
    """一次异步请求的结果：长响应场景要先挂住它，再放第二批流量。"""

    def __init__(self):
        self.status = 0
        self.body = ""


def _chat_body(model, text, extra):
    body = {"model": model, "messages": [{"role": "user", "content": text}],
            "stream": False}
    if extra:
        body.update(extra)
    return body


def chat_async(port, model, text, headers=None, timeout=60, extra=None):
    holder = Reply()

    def run():
        status, raw, _ = http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                              _chat_body(model, text, extra), headers, timeout=timeout)
        holder.status, holder.body = status, raw

    t = threading.Thread(target=run)
    t.daemon = True
    t.start()
    return t, holder


def chat_sync(port, model, text, headers=None, timeout=30, extra=None):
    return http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port,
                _chat_body(model, text, extra), headers, timeout=timeout)


def echo_of(status, raw):
    """从响应里取"网关到底转发了什么"：echo_body 是 mock 原样回显的转发体。"""
    if status != 200:
        return {}
    try:
        doc = json.loads(raw)
    except ValueError:
        return {}
    echo = doc.get("echo_body") or {}
    choices = doc.get("choices") or [{}]
    content = (choices[0].get("message") or {}).get("content") or ""
    return {"model": echo.get("model"), "content": content}


def workers_by_url(port):
    st, body, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
    if st != 200:
        return {}
    return {w.get("url"): w for w in json.loads(body).get("workers", [])}


def wait_urls(port, urls, timeout=40):
    deadline = time.time() + timeout
    while time.time() < deadline:
        rows = workers_by_url(port)
        if all(u in rows for u in urls) and all(rows[u].get("is_healthy") for u in urls):
            return True
        time.sleep(0.3)
    return False


def wait_inflight(port, url, want, timeout=20):
    """等网关自己的在途计数升到 want（并发上限比的就是这个数）。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        row = workers_by_url(port).get(url)
        if row is not None and (row.get("inflight_requests") or 0) >= want:
            return True
        time.sleep(0.1)
    return False


def wait_inflight_zero(port, url, timeout=40):
    deadline = time.time() + timeout
    while time.time() < deadline:
        row = workers_by_url(port).get(url)
        if row is not None and (row.get("inflight_requests") or 0) == 0:
            return True
        time.sleep(0.15)
    return False


def post_json(port, path, body):
    st, text, _ = http("POST", "http://127.0.0.1:%d%s" % (port, path), body)
    try:
        return st, json.loads(text)
    except ValueError:
        return st, text


def put_json(port, path, body):
    """PUT 与 POST 在 klib.router 的表里是两条路由（POST /workers/<id> 是 404），
    上限的运行时改口只有 PUT /workers/{id} 这一条，所以必须用 PUT 发。"""
    st, text, _ = http("PUT", "http://127.0.0.1:%d%s" % (port, path), body)
    try:
        return st, json.loads(text)
    except ValueError:
        return st, text


def post_virtual(port, entries):
    return post_json(port, "/_ui/config/virtual", {"entries": entries})


def post_upstreams(port, entries):
    """整表替换声明池（config_store 的 upstreams 层，contract 3.5）。

    改名场景必须走这条而不是 PUT /workers：只有 config 声明层的 reconcile 会经
    registry.update 写 model_id，而 patch_record 正是**在 model_id 变化时**把
    models_verified 清零（"换主模型就是换了一次身份陈述"），这条判定只有这条路能触发。
    """
    return post_json(port, "/_ui/config/upstreams", {"entries": entries})


def metric_lines(port, name):
    """/metrics 里某一族的全部 series（不含 # 注释行）。"""
    st, text, _ = http("GET", "http://127.0.0.1:%d/metrics" % port)
    if st != 200:
        return []
    return [line for line in text.splitlines()
            if not line.startswith("#") and (line.startswith(name + "{")
                                             or line.startswith(name + " "))]


def metric_value(port, name, needle=None):
    for line in metric_lines(port, name):
        if needle is None or needle in line:
            try:
                return float(line.rsplit(" ", 1)[-1])
            except ValueError:
                return None
    return None


def wait_metric_grows(port, name, timeout=12, needle=None):
    """等某个计数器在定时器驱动下真的增长，返回 (之前值, 之后值)。

    为什么必须等：功率计数器是按 tick 涨的（interval=1 s），抓一次快读就可能读到
    「还没到下一个 tick」的同一个值，写成一次性对比就是一条天生会红的断言；而定时器
    根本没跑（本场景真正要排除的失败模式）会一直不涨，poll 到超时恰好把它照出来。"""
    start = metric_value(port, name, needle)
    deadline = time.time() + timeout
    while time.time() < deadline:
        now = metric_value(port, name, needle)
        if start is not None and now is not None and now > start:
            return start, now
        time.sleep(0.4)
    return start, metric_value(port, name, needle)


def err_parts(st, raw, hdrs):
    code = hdrs.get("X-SMG-Error-Code") or hdrs.get("x-smg-error-code") or ""
    message = raw
    try:
        message = (json.loads(raw).get("error") or {}).get("message") or ""
    except ValueError:
        pass
    return st, code, message


# ------------------------------------------------------------------ 会报功率的 worker
#
# 共享 mock 的 /metrics 是固定正文（只有 mock_uptime/mock_requests/sglang 两族），没有
# 任何功率 gauge，也没有"运行时可改瓦数"的口子。功率场景要求瓦数能被测试随时抬高/清空
# （清空 = 采不到 = 未知，正是安全红线那一条），而 mock 不在我的文件所有权里，所以在
# 这里自带一个 worker。
# 正文形状是 dcgm 的**逐卡**形状（用户裁定 2026-10-04 之后的口径，见 gpu_load.assign_power
# 上方注释）：一台机器的每个 engine 端口都看得见整机所有卡，所以同一份正文会被该机上
# 每个 worker 各抓一次，而每个 worker 只该取走**自己那张卡**的瓦数。生产 342.371 那次
# 故障就是这一步做成了"整机最热"——8 个 worker 拿到同一个数，于是恒真的
# 100 <= power_w <= 500 检不出来。fixture 因此必须同机报**三个互不相同**的瓦数。

class PowerWorker(object):
    """A worker whose /metrics carries a DCGM-style per-card watt gauge."""

    def __init__(self, port, model, watts=88.0, cards=None, utils=None):
        self.port, self.model = port, model
        self.chats = 0
        self.last_model = None
        self.lock = threading.Lock()
        # self.utils is the per-card utilisation vector [(gpu_id, percent 0..100), ...]
        # in DCGM_FI_DEV_GPU_UTIL shape (the util channel of
        # doc/caps-redesign-2026-10-06.md section 5). util_mode: "plain" = the two
        # legacy nvidia_gpu_utilization series only (what every pre-feature scenario
        # saw, byte for byte); "dcgm" = plus the DCGM-named per-card utils; "off" =
        # neither family in the body (collected as unknown, the red-line branch).
        self.utils = None
        self.util_mode = "dcgm" if utils is not None else "plain"
        if utils is not None:
            self.utils = [(str(g), float(u)) for (g, u) in utils]
        # self.cards 是 [(gpu_id, watts), ...]；None = 正文里根本没有功率 gauge
        # （= exporter 掉线 = 采不到，另一条降级分支）。缺省沿用老的两卡形状，
        # 热的那张在 gpu="1"，所以 S3/S6 的既有断言口径不变。
        if cards is not None:
            self.cards = [(str(g), float(w)) for (g, w) in cards]
        elif watts is None:
            self.cards = None
        else:
            self.cards = [("0", 12.0), ("1", float(watts))]
        outer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt, *args):
                pass

            def _send(self, status, payload, ctype="application/json"):
                raw = payload.encode() if isinstance(payload, str) else json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                path = self.path.split("?", 1)[0]
                if path == "/health":
                    return self._send(200, {"ok": True})
                if path == "/v1/models":
                    return self._send(200, {"object": "list", "data": [
                        {"id": outer.model, "object": "model"}]})
                if path == "/metrics":
                    with outer.lock:
                        chats = outer.chats
                        cards = list(outer.cards) if outer.cards else None
                    lines = ["# HELP mock_requests_total received requests",
                             "# TYPE mock_requests_total counter",
                             "mock_requests_total %d" % chats]
                    if outer.util_mode != "off":
                        # Both the load roster and the util roster read
                        # nvidia_gpu_utilization; "off" withdraws BOTH families, so an
                        # "unknown reading" assertion cannot be falsified by the other
                        # channel answering for it.
                        lines += ["# TYPE nvidia_gpu_utilization gauge",
                                  'nvidia_gpu_utilization{gpu="0"} 3.0',
                                  'nvidia_gpu_utilization{gpu="1"} 5.0']
                    if outer.util_mode == "dcgm" and outer.utils:
                        lines += ["# TYPE DCGM_FI_DEV_GPU_UTIL gauge"]
                        for gpu, pct in outer.utils:
                            lines.append(
                                'DCGM_FI_DEV_GPU_UTIL{gpu="%s",Hostname="caps-e2e"} %s'
                                % (gpu, "%.1f" % pct))
                    if cards:
                        # dcgm 的真实写法就是全大写 + Hostname 标签，这里照抄形状。
                        # 每台 worker 都报**同一份**三卡正文：同机共享 exporter，
                        # 谁都不该看见邻居那张卡的瓦数被算到自己头上。
                        lines += ["# TYPE DCGM_FI_DEV_POWER_USAGE gauge"]
                        for gpu, watts in cards:
                            lines.append(
                                'DCGM_FI_DEV_POWER_USAGE{gpu="%s",Hostname="caps-e2e"} %s'
                                % (gpu, "%.1f" % watts))
                    return self._send(200, "\n".join(lines) + "\n",
                                       ctype="text/plain; charset=utf-8")
                if path == "/state":
                    with outer.lock:
                        return self._send(200, {"model": outer.model, "chats": outer.chats,
                                                "cards": outer.cards,
                                                "utils": outer.utils,
                                                "util_mode": outer.util_mode,
                                                "last_model": outer.last_model})
                return self._send(404, {"error": {"message": "no route " + path}})

            def do_POST(self):
                raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                try:
                    body = json.loads(raw.decode()) if raw else {}
                except ValueError:
                    body = {}
                if self.path.split("?", 1)[0] != "/v1/chat/completions":
                    return self._send(404, {"error": {"message": "no route"}})
                forwarded = body.get("model")
                with outer.lock:
                    outer.chats += 1
                    outer.last_model = forwarded
                return self._send(200, {
                    "id": "caps-%d" % outer.chats, "object": "chat.completion",
                    "model": forwarded,
                    "choices": [{"index": 0, "finish_reason": "stop",
                                 "message": {"role": "assistant",
                                             "content": "echo[%s] caps probe" % forwarded}}],
                    "echo_body": body,
                })

        self.server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def set_watts(self, watts):
        """整机热卡读数改写（None = 正文里的功率 gauge 全部撤走 = 采不到）。"""
        with self.lock:
            self.cards = None if watts is None else [("0", 12.0), ("1", float(watts))]

    def set_utils(self, utils):
        """Rewrite the per-card utilisation vector ("off" = both gauge families gone)."""
        with self.lock:
            if utils == "off":
                self.util_mode = "off"
                self.utils = None
            else:
                self.util_mode = "dcgm"
                self.utils = None if utils is None else [(str(g), float(u))
                                                          for (g, u) in utils]

    def drop_util_card(self, gpu):
        """Withdraw one card's utilisation series (the 'card known, no series' arm).

        Both families lose that gpu label: the util reader falls back to the whole-
        machine max (and counts a fallback) rather than writing nothing - the
        utilisation side's conservative direction, see cards.lua assign_util. Only
        set_utils("off") takes the reading to *unknown*.
        """
        with self.lock:
            if self.utils:
                self.utils = [(g, u) for (g, u) in self.utils if g != str(gpu)]
            self.util_mode = "plainnocard" if self.util_mode != "off" else "off"

    def drop_all_util(self):
        """Withdraw every gpu-utilisation series: the unknown arm of the gate."""
        with self.lock:
            self.util_mode = "off"
            self.utils = None

    def drop_card(self, gpu):
        """把某张卡从正文里摘掉：该卡 series 消失 = 这台机器再也答不出它的瓦数。

        这是「worker 认得自己的卡、但数据源没有那张卡的 series」那一支的注入手法
        （另一支"worker 认不出卡"用不带 labels.gpu 的注册行覆盖），两条都必须
        落到"不写键 → 未知 → 不排除"，绝不能拿邻居那张卡的瓦数顶替。
        """
        with self.lock:
            if self.cards:
                self.cards = [(g, w) for (g, w) in self.cards if g != str(gpu)]

    def hits(self):
        with self.lock:
            return self.chats

    def shutdown(self):
        self.server.shutdown()
        self.server.server_close()


# ============================================================ S1 多绑定不同模型（需求 A）

def scenario_bindings(igw):
    """一个别名绑两台实例的两个不同模型，两条路径都必须真能服务且各转各的名字。

    判别性（写错必然红）：
      * pinned(A) 必须 200 且 echo_body.model == alpha；pinned(B) 必须 200 且
        echo_body.model == beta。旧实现（没有 per-candidate 绑定这一层）在 IGW=1 下会
        按别名代表的模型名把候选筛空，B 那台要么 503、要么被 A 的名字糊过去 → 红。
      * 每条请求同时校验"哪个 mock 收到"与"转发体里的 model"，两者必须成对；只看 200
        会被"全部落到 A 且 A 收到 alpha"骗过去。
      * 未绑定的裸名请求（直接发 beta）在 IGW=1 下只许被 B 服务：钉住"绑定是操作员亲自
        命名、不走引擎模型门；客户端给的名字仍然要收窄"。
      * candidates-only 的文档回显不许长出没人声明的 target（隐式补名会让后续 reader
        跟着一个幻影模型名找 effort/ctx 卡）。
    """
    tag = "S1-igw%s" % igw
    pa, pb = free_port(), free_port()
    start_mock(pa, "alpha")
    start_mock(pb, "beta")
    env = {"SMG_POLICY": "round_robin"}
    if igw:
        env["SMG_ENABLE_IGW"] = "1"
    port, name, gw = start_conf_container(env, tag)
    url_a = "http://%s:%d" % (gw, pa)
    url_b = "http://%s:%d" % (gw, pb)
    st, body = post_json(port, "/workers", {"url": url_a, "model_id": "alpha"})
    st2, body2 = post_json(port, "/workers", {"url": url_b, "model_id": "beta"})
    if not check("[%s] both workers registered" % tag,
                 st in (200, 202) and st2 in (200, 202),
                 "%s %s / %s %s" % (st, body, st2, body2)):
        stop_router(name)
        return
    if not check("[%s] both bound workers healthy" % tag, wait_urls(port, [url_a, url_b]),
                 logs(name)[:400]):
        stop_router(name)
        return
    rows = workers_by_url(port)
    id_a, id_b = rows[url_a]["id"], rows[url_b]["id"]

    bindings = [{"worker": url_a, "model": "alpha"}, {"worker": url_b, "model": "beta"}]
    st, doc = post_virtual(port, [{"model": "vm-multi", "candidates": bindings}])
    check("[%s] POST /_ui/config/virtual candidates-only accepted (target derived)" % tag,
          st == 200, "%s %s" % (st, json.dumps(doc)[:300]))
    entry = [e for e in (doc.get("virtual_models") or []) if e.get("model") == "vm-multi"]
    check("[%s] document round-trips both bindings and invents no target" % tag,
          bool(entry) and "target" not in entry[0]
          and [(c.get("worker"), c.get("model")) for c in (entry[0].get("candidates") or [])]
          == [(url_a, "alpha"), (url_b, "beta")],
          json.dumps(entry)[:400])
    st, doc2 = post_virtual(port, [{"model": "vm-bad", "candidates": [
        {"worker": url_a, "model": "alpha"}, {"worker": url_a, "model": "beta"}]}])
    check("[%s] same worker bound to two models rejected 400" % tag, st == 400,
          "%s %s" % (st, json.dumps(doc2)[:300]))

    # 1) 显式 pin 每台：必须是那台收到，且转发名 = 绑定名
    for which, want_id, want_model, mock_port in (
            ("A", id_a, "alpha", pa), ("B", id_b, "beta", pb)):
        base = {p: mock_lines(p, "/v1/chat/completions") for p in (pa, pb)}
        other = pb if mock_port == pa else pa
        st, raw, _ = chat_sync(port, "vm-multi", "pinned binding probe " + want_model,
                               headers={"x-smg-target-worker": want_id})
        echo = echo_of(st, raw)
        hits_want = mock_lines(mock_port, "/v1/chat/completions") - base[mock_port]
        hits_other = mock_lines(other, "/v1/chat/completions") - base[other]
        check("[%s] pinned %s forwards model=%s" % (tag, which, want_model),
              st == 200 and echo.get("model") == want_model
              and echo.get("content", "").startswith("echo[" + want_model + "]"),
              "%s %s" % (st, json.dumps(echo)[:200]))
        check("[%s] pinned %s reached exactly that instance" % (tag, which),
              hits_want == 1 and hits_other == 0, "want=%d other=%d" % (hits_want, hits_other))

    # 2) 不 pin 的一批：两台都要被用到，且每条的落点与转发名成对
    base = {p: mock_lines(p, "/v1/chat/completions") for p in (pa, pb)}
    pairs = []
    ok_all = True
    for i in range(8):
        st, raw, _ = chat_sync(port, "vm-multi", "shared binding prefix tail %d" % i)
        if st != 200:
            ok_all = False
            break
        name_seen = echo_of(st, raw).get("model")
        cur = {p: mock_lines(p, "/v1/chat/completions") for p in (pa, pb)}
        delta = {p: cur[p] - base[p] for p in (pa, pb)}
        base = cur
        landed = [p for p in (pa, pb) if delta[p] > 0]
        if len(landed) != 1 or sum(delta.values()) != 1:
            ok_all = False
            break
        pairs.append(("A" if landed[0] == pa else "B", name_seen))
    check("[%s] 8 unpinned binding requests 200 with one landing each" % tag,
          ok_all and len(pairs) == 8, str(pairs))
    check("[%s] both bound instances actually served the alias" % tag,
          len(pairs) == 8 and {w for w, _ in pairs} == {"A", "B"}, str(pairs))
    check("[%s] every request forwards its own bound model name" % tag,
          all((w == "A" and m == "alpha") or (w == "B" and m == "beta") for w, m in pairs),
          str(pairs))

    # 3) 未绑定的裸名请求：IGW=1 时只许被声明了该名的实例服务
    base = {p: mock_lines(p, "/v1/chat/completions") for p in (pa, pb)}
    ok = True
    ok_any = True
    for i in range(4):
        st, raw, _ = chat_sync(port, "beta", "bare model name probe %d" % i)
        echo = echo_of(st, raw)
        # 转发的名字必须是"收到它那台自己的声明名"（mock 会 echo 收到的 model）：否则
        # mock 收到一个它没声明过的名字也算成功，这条就成了假绿。
        served = echo.get("model") in ("alpha", "beta") and \
            echo.get("content", "").startswith("echo[" + str(echo.get("model")) + "]")
        ok = ok and st == 200 and echo.get("model") == "beta"
        ok_any = ok_any and st == 200 and served
    hits_a = mock_lines(pa, "/v1/chat/completions") - base[pa]
    hits_b = mock_lines(pb, "/v1/chat/completions") - base[pb]
    if igw:
        check("[%s] IGW still narrows an unbound name (beta never reaches A)" % tag,
              ok and hits_a == 0 and hits_b == 4, "a=%d b=%d" % (hits_a, hits_b))
    else:
        # IGW 关掉就没有模型门：裸名 beta 可以落到任何一台，router 按 chosen worker 的
        # model_id 重写转发名，所以"落在谁那儿、转成谁的名字"都合法，只要求四条都被服务。
        check("[%s] IGW off: bare name served 200 four times, by anyone" % tag,
              ok_any and hits_a + hits_b == 4, "a=%d b=%d ok_any=%s" % (hits_a, hits_b, ok_any))

    check_no_abort(tag, name)
    stop_router(name)


# ================================================================ S2 并发上限

def scenario_candidates_intersect_workers():
    """candidates 与旧 workers 同时存在 → 取交集（candidates_for 的 2026-10-01 收紧）。

    为什么这条最值得钉：新字段 candidates 一旦"吞掉"旧白名单，就等于操作员刚写下的
    限制被一次配置新增悄悄取消——新字段放宽了旧字段管着的权限，方向完全反了。三档
    真 HTTP 判据（都用 mock 的落点计数 + echo_body.model 双证）：
      * candidates=[A,B] + workers=[B]：只剩 B。8 发全落 B 且转发名都是 beta；连显式
        pin A 都不许泄漏到 A（pin 只在候选数组里找，被白名单筛掉的台根本不在数组里）。
      * candidates=[A,B] + workers=[一条谁也匹配不上的 url]：候选集为空 → 503
        no_available_workers，且**两台绑定实例的命中计数都不许涨**（不许"绑定的先服务"）。
        这条同时要求文案保持原样、不带 cap 字样：它是模型门/白名单造成的空集，不是达上限。
      * candidates=[A,B] + workers=[A,B]：两条都在（spread 两台都用上，各自绑名）。
      * 对照组：只有 workers 没有 candidates（老形状）→ 仍按白名单收窄，老行为零变化。
    """
    tag = "S1x-intersect"
    pa, pb = free_port(), free_port()
    start_mock(pa, "alpha")
    start_mock(pb, "beta")
    port, name, gw = start_conf_container({"SMG_POLICY": "round_robin"}, tag)
    url_a, url_b = "http://%s:%d" % (gw, pa), "http://%s:%d" % (gw, pb)
    st, _ = post_json(port, "/workers", {"url": url_a, "model_id": "alpha"})
    st2, _ = post_json(port, "/workers", {"url": url_b, "model_id": "beta"})
    if not check("[%s] both workers registered" % tag,
                 st in (200, 202) and st2 in (200, 202), "%s %s" % (st, st2)):
        stop_router(name)
        return
    if not check("[%s] both healthy" % tag, wait_urls(port, [url_a, url_b]),
                 logs(name)[:400]):
        stop_router(name)
        return
    rows = workers_by_url(port)
    id_a, id_b = rows[url_a]["id"], rows[url_b]["id"]
    dead = "http://%s:%d" % (gw, free_port())   # 合法 url，只是匹配不上任何记录
    bindings = [{"worker": url_a, "model": "alpha"}, {"worker": url_b, "model": "beta"}]
    st, doc = post_virtual(port, [
        {"model": "vm-int-a", "candidates": bindings, "workers": [url_b]},
        {"model": "vm-int-empty", "candidates": bindings, "workers": [dead]},
        {"model": "vm-int-full", "candidates": bindings, "workers": [url_a, url_b]},
        {"model": "vm-legacy", "target": "beta", "workers": [url_b]},
    ])
    check("[%s] four profiles accepted (bindings + whitelist coexist)" % tag,
          st == 200, "%s %s" % (st, json.dumps(doc)[:300]))
    entry = [e for e in (doc.get("virtual_models") or []) if e.get("model") == "vm-int-a"]
    check("[%s] the document round-trips candidates AND workers (nothing swallowed)" % tag,
          bool(entry) and (entry[0].get("candidates") or []) == bindings
          and entry[0].get("workers") == [url_b], json.dumps(entry)[:400])

    # 1) 白名单收窄到 B：8 发全落 B，A 一次都不许多
    base = {p: mock_lines(p, "/v1/chat/completions") for p in (pa, pb)}
    ok = True
    for i in range(8):
        st, raw, _ = chat_sync(port, "vm-int-a", "intersect narrow probe %d" % i)
        echo = echo_of(st, raw)
        ok = ok and st == 200 and echo.get("model") == "beta"
    hits_a = mock_lines(pa, "/v1/chat/completions") - base[pa]
    hits_b = mock_lines(pb, "/v1/chat/completions") - base[pb]
    check("[%s] candidates=[A,B] + workers=[B]: all 8 land on B (%d/%d)"
          % (tag, hits_a, hits_b),
          ok and hits_a == 0 and hits_b == 8, "a=%d b=%d ok=%s" % (hits_a, hits_b, ok))
    # 显式 pin 被白名单筛掉的那台：不许泄漏（pin 只在候选数组里找）
    base = {p: mock_lines(p, "/v1/chat/completions") for p in (pa, pb)}
    st, raw, _ = chat_sync(port, "vm-int-a", "pinned onto whitelisted-out A",
                           headers={"x-smg-target-worker": id_a})
    hits_a = mock_lines(pa, "/v1/chat/completions") - base[pa]
    hits_b = mock_lines(pb, "/v1/chat/completions") - base[pb]
    check("[%s] a whitelisted-out binding cannot be resurrected by an explicit pin" % tag,
          st == 200 and hits_a == 0 and hits_b == 1,
          "%s a=%d b=%d" % (st, hits_a, hits_b))

    # 2) 白名单谁也匹配不上 → 空集 503，绑定实例一台都不许多拿流量
    base = {p: mock_lines(p, "/v1/chat/completions") for p in (pa, pb)}
    st, raw, hdrs = chat_sync(port, "vm-int-empty", "empty intersection probe")
    st_v, code, message = err_parts(st, raw, hdrs)
    hits_a = mock_lines(pa, "/v1/chat/completions") - base[pa]
    hits_b = mock_lines(pb, "/v1/chat/completions") - base[pb]
    check("[%s] a whitelist that matches nothing empties the set: 503, no leak (%d/%d)"
          % (tag, hits_a, hits_b),
          st_v == 503 and code == "no_available_workers" and hits_a == 0 and hits_b == 0,
          "%s %s %s a=%d b=%d" % (st_v, code, message[:160], hits_a, hits_b))
    check("[%s] an empty whitelist is not a cap exclusion (message keeps its wording)" % tag,
          "cap" not in message, message[:200])

    # 3) 两张表都全量 → 交集 = 两条都在
    base = {p: mock_lines(p, "/v1/chat/completions") for p in (pa, pb)}
    pairs = []
    ok_all = True
    for i in range(8):
        st, raw, _ = chat_sync(port, "vm-int-full", "intersect full probe %d" % i)
        if st != 200:
            ok_all = False
            break
        name_seen = echo_of(st, raw).get("model")
        cur = {p: mock_lines(p, "/v1/chat/completions") for p in (pa, pb)}
        delta = {p: cur[p] - base[p] for p in (pa, pb)}
        base = cur
        landed = [p for p in (pa, pb) if delta[p] > 0]
        if len(landed) != 1 or sum(delta.values()) != 1:
            ok_all = False
            break
        pairs.append(("A" if landed[0] == pa else "B", name_seen))
    check("[%s] candidates=[A,B] + workers=[A,B]: both survive (%s)" % (tag, pairs),
          ok_all and len(pairs) == 8 and {w for w, _ in pairs} == {"A", "B"}, str(pairs))
    check("[%s] each survivor is still forwarded under its own bound name" % tag,
          all((w == "A" and m == "alpha") or (w == "B" and m == "beta") for w, m in pairs),
          str(pairs))

    # 4) 老形状（只有 workers，没有 candidates）：白名单照旧生效，零行为变化
    base = {p: mock_lines(p, "/v1/chat/completions") for p in (pa, pb)}
    ok = True
    for i in range(4):
        st, raw, _ = chat_sync(port, "vm-legacy", "legacy whitelist probe %d" % i)
        ok = ok and st == 200
    hits_a = mock_lines(pa, "/v1/chat/completions") - base[pa]
    hits_b = mock_lines(pb, "/v1/chat/completions") - base[pb]
    check("[%s] the legacy workers-only whitelist still narrows to B (%d/%d)"
          % (tag, hits_a, hits_b),
          ok and hits_a == 0 and hits_b == 4, "a=%d b=%d ok=%s" % (hits_a, hits_b, ok))

    check_no_abort(tag, name)
    stop_router(name)


def scenario_config_rename_model_gate(igw):
    """config 声明行改名：旧名必须非 200、引擎亲口的名字在清章后也必须非 200、新名 200。

    为什么用 config 行而不是 POST /workers：只有 config 声明层的 reconcile 会经
    registry.update 写 model_id，而 patch_record **在 model_id 变化时**把 models_verified
    清零（换主模型=换了一次身份陈述，之前那份广告列表不能再当"引擎亲口答过"的凭证）。
    refresh_models 随后被 300 s 的 mp: 冷却挡住，所以这条判定跑的是真实窗口，不是 mock。

    判别性（IGW=1 那组）：
      * 先等 GET /workers 的 models 里出现"引擎亲口的名字"（real-*），这一步证明巡检真的
        探到过它并盖过章；否则后面的"清章"断言无从归因（可能只是从来没探到）。
      * 声明名 real 改成 renamed 后：GET /workers 里 models **仍然含 real**（折叠残留还在），
        但请求 real 必须非 200 —— 这条只有在"盖章被清掉"时成立，写成调
        candidate_allows_model（未盖章也放行）的实现必然红。
      * 旧声明名 gamma 也必须非 200（它既不是主名也没在列表里）。
      * 新名 gamma-renamed → 200，且转发的 model 就是新名（条款 2：model_id==want 放行）。
      * 503 的 code 仍是 no_available_workers，文案不许带 cap 字样（模型门排除≠达上限）。
    IGW=0 那组是因果对照：同一份池子、同样的改名，开关关掉后旧名照样 200，
    说明上面那三条红是 IGW 门带来的，不是健康度或超时造成的。
    """
    tag = "S7-rename-igw%s" % igw
    pa = free_port()
    start_mock(pa, "real-a")      # 引擎亲口的名字：real-a
    port, name, gw = start_conf_container({"SMG_POLICY": "round_robin",
                                          "SMG_ENABLE_IGW": "1" if igw else "0"}, tag)
    url_a = "http://%s:%d" % (gw, pa)
    st, doc = post_upstreams(port, [{"url": url_a, "model_id": "gamma"}])
    check("[%s] config upstream declared (model_id gamma)" % tag, st == 200,
          "%s %s" % (st, json.dumps(doc)[:250]))
    if not check("[%s] the config row is healthy" % tag, wait_urls(port, [url_a]),
                 logs(name)[:400]):
        stop_router(name)
        return
    # 等"引擎亲口的名字"进列表 = 巡检真探到过它（models_replace 的那次观测），
    # 同时也让 mp: 冷却落地，改名后的窗口才是 300 s 而不是下一次巡检就翻案。
    stamped = False
    deadline = time.time() + 30
    while time.time() < deadline:
        if "real-a" in ((workers_by_url(port).get(url_a) or {}).get("models") or []):
            stamped = True
            break
        time.sleep(0.4)
    check("[%s] the sweep learned the engine's own id (models contains real-a)" % tag,
          stamped, json.dumps(workers_by_url(port).get(url_a, {}))[:300])
    if not stamped:
        stop_router(name)
        return

    # 改名**之前**的两条正向前提：声明名（条款 2）与引擎亲口的名字（盖章后的条款 4）
    # 都必须能服务。少了这两条，改名后那两条"非 200"就可能只是这台从一开始就不可用。
    st_g, raw_g, _ = chat_sync(port, "gamma", "declared name before rename")
    check("[%s] premise: the declared name routes before the rename" % tag,
          st_g == 200, "%s %s" % (st_g, raw_g[:200]))
    st_r0, raw_r0, _ = chat_sync(port, "real-a", "engine id while stamped")
    check("[%s] premise: the engine's own id routes while the stamp holds" % tag,
          st_r0 == 200, "%s %s" % (st_r0, raw_r0[:200]))

    st, doc = post_upstreams(port, [{"url": url_a, "model_id": "gamma-renamed"}])
    # reconcile 是 apply_upstreams 里同步跑的，但 shdict 写与 mesh 镜像之间可能有半个
    # tick 的可见性延迟，所以这里 poll 到落定为止：拿"改没改成功"当断言会 flake。
    row = {}
    deadline = time.time() + 20
    while time.time() < deadline:
        row = workers_by_url(port).get(url_a) or {}
        if row.get("model_id") == "gamma-renamed":
            break
        time.sleep(0.3)
    check("[%s] the rename landed on the pool row" % tag,
          st == 200 and row.get("model_id") == "gamma-renamed",
          "%s %s" % (st, json.dumps(row)[:250]))
    # 关键前提：折叠残留还在列表里。残留不在就等于"列表本来就空"，那两条负断言会假绿。
    check("[%s] the old advertised list is still folded in (residue present)" % tag,
          "real-a" in (row.get("models") or []), json.dumps(row.get("models"))[:200])

    st_new, raw_new, _ = chat_sync(port, "gamma-renamed", "new name after rename")
    check("[%s] the new model_id routes 200 (clause: model_id == want)" % tag,
          st_new == 200 and echo_of(st_new, raw_new).get("model") == "gamma-renamed",
          "%s %s" % (st_new, raw_new[:200]))

    st_old, raw_old, hdrs_old = chat_sync(port, "gamma", "old declared name after rename")
    st_o, code_o, msg_o = err_parts(st_old, raw_old, hdrs_old)
    check("[%s] the old declared name stops routing%s" % (tag, "" if igw else " (igw off)"),
          (st_o != 200) if igw else (st_o == 200),
          "%s %s %s" % (st_o, code_o, msg_o[:160]))
    st_real, raw_real, hdrs_r = chat_sync(port, "real-a", "engine id after unstamping")
    st_r, code_r, msg_r = err_parts(st_real, raw_real, hdrs_r)
    check("[%s] an unstamped engine id cannot widen the row either%s"
          % (tag, "" if igw else " (igw off)"),
          (st_r != 200) if igw else (st_r == 200),
          "%s %s %s" % (st_r, code_r, msg_r[:160]))
    if igw:
        # 空候选集来自模型门（refused），不是达上限（capped），所以文案必须保持原样、
        # code 也仍是 no_available_workers —— 这条把"模型门"与"容量门"两种 503 分开钉。
        check("[%s] the refusal keeps code no_available_workers without the cap wording" % tag,
              st_o == 503 and code_o == "no_available_workers" and "cap" not in msg_o,
              "%s %s %s" % (st_o, code_o, msg_o[:200]))
    check_no_abort(tag, name)
    stop_router(name)


def scenario_concurrency():
    """max_concurrency=1 必须把并发请求赶到另一台，解除后又能回来。

    判别性：
      * 长响应（LATENCY_MS）+ pin 挂住 X，让网关自己的 inflight(X)>=1，再连发 6 条不带
        pin 的请求：这 6 条一条都不许多进 X。没有上限实现时 round_robin 会把它们摊一半
        给 X → 红。
      * GET /workers：X 回显 max_concurrency=1 与 inflight_requests>=1；未声明上限的那
        台必须是字段缺席而不是 0。
      * 解除（等在途归零）后再 pin X 必须 200：排除只由在途决定，没有把 worker 逐出池。
      * smg_worker_capacity_excluded_total{reason="concurrency"} 随排除增长。
    """
    tag = "S2-concurrency"
    pa, pb = free_port(), free_port()
    start_mock_env(pa, "alpha", LATENCY_MS=5000)
    start_mock(pb, "alpha")
    port, name, gw = start_conf_container({"SMG_POLICY": "round_robin"}, tag)
    url_a, url_b = "http://%s:%d" % (gw, pa), "http://%s:%d" % (gw, pb)
    st, _ = post_json(port, "/workers", {"url": url_a, "model_id": "alpha",
                                        "max_concurrency": 1})
    st2, _ = post_json(port, "/workers", {"url": url_b, "model_id": "alpha"})
    if not check("[%s] both registered (cap declared on X only)" % tag,
                 st in (200, 202) and st2 in (200, 202), "%s %s" % (st, st2)):
        stop_router(name)
        return
    if not check("[%s] both healthy" % tag, wait_urls(port, [url_a, url_b]), logs(name)[:400]):
        stop_router(name)
        return
    rows = workers_by_url(port)
    id_a = rows[url_a]["id"]
    check("[%s] /workers echoes the declared cap and omits undeclared ones" % tag,
          rows[url_a].get("max_concurrency") == 1
          and "max_concurrency" not in rows[url_b]
          and "min_concurrency" not in rows[url_b]
          and "max_gpu_util" not in rows[url_b]
          and "max_power_w" not in rows[url_b]
          and "load_state" not in rows[url_b],
          json.dumps({k: rows[url_b].get(k) for k in
                      ("min_concurrency", "max_concurrency", "max_gpu_util",
                       "max_power_w", "load_state", "inflight_requests")}))
    # Three-state echo (doc/caps-redesign-2026-10-06.md section 2): X declares only
    # max_concurrency=1 (min absent = 1), so at rest it is the green light, and the
    # *absence* of a gate on Y means the **key is missing**, not null: an explicit
    # null would make an uncapped row look like a state the gateway refused to name.
    check("[%s] /workers reports the gate's three states (idle at rest, absent without a gate)" % tag,
          rows[url_a].get("load_state") == "idle"
          and "load_state" not in rows[url_b]
          and rows[url_a].get("min_concurrency") is None
          and rows[url_a].get("max_gpu_util") is None,
          json.dumps([rows[url_a], rows[url_b]])[:300])

    before = metric_value(port, "smg_worker_capacity_excluded_total",
                          'reason="concurrency_max"') or 0
    base = {p: mock_lines(p, "/v1/chat/completions") for p in (pa, pb)}
    held_thread, held = chat_async(port, "alpha", "long response holds the slot",
                                   headers={"x-smg-target-worker": id_a})
    busy = wait_inflight(port, url_a, 1, timeout=20)
    inflight_seen = (workers_by_url(port).get(url_a) or {}).get("inflight_requests")
    check("[%s] gateway counts the in-flight request on X" % tag,
          busy and (inflight_seen or 0) >= 1,
          json.dumps(workers_by_url(port).get(url_a, {}))[:250])
    # The same row must read full while it is at the ceiling -- the /workers colour
    # and the gate are one verdict (registry.capacity_state), so a "still idle while
    # excluded" echo means someone re-derived the light at home.
    check("[%s] the at-cap row reads load_state=full while the burst runs" % tag,
          (workers_by_url(port).get(url_a) or {}).get("load_state") == "full",
          json.dumps(workers_by_url(port).get(url_a, {}))[:250])
    ok_batch = True
    for i in range(6):
        st, raw, _ = chat_sync(port, "alpha", "burst while X is saturated %d" % i)
        ok_batch = ok_batch and st == 200
    hits_a = mock_lines(pa, "/v1/chat/completions") - base[pa]
    hits_b = mock_lines(pb, "/v1/chat/completions") - base[pb]
    held_thread.join(timeout=30)
    check("[%s] premise: the held request landed on X and the burst is all 200" % tag,
          held.status == 200 and ok_batch and hits_a >= 1,
          "held=%s a=%d b=%d" % (held.status, hits_a, hits_b))
    check("[%s] over-cap X takes none of the 6 concurrent requests (a=%d)" % (tag, hits_a),
          hits_a == 1 and hits_b == 6, "a=%d b=%d" % (hits_a, hits_b))
    after = metric_value(port, "smg_worker_capacity_excluded_total",
                         'reason="concurrency_max"') or 0
    check("[%s] exclusion counted by reason=concurrency_max" % tag, after > before,
          "%s -> %s" % (before, after))
    # The retired spellings must never appear: an implementation that reintroduces
    # reason="concurrency" (or the watt-era "power") grows a *different* series and
    # leaves the pinned one at the pre-burst value above -- both halves together pin
    # the naming, which either check alone cannot.
    retired = [line for line in metric_lines(port, "smg_worker_capacity_excluded_total")
               if 'reason="concurrency"' in line or 'reason="power"' in line]
    check("[%s] the retired exclusion reasons never appear" % tag, not retired,
          json.dumps(retired)[:200])
    freed = wait_inflight_zero(port, url_a, timeout=40)
    check("[%s] in-flight drains once the long response ends" % tag, freed,
          json.dumps(workers_by_url(port).get(url_a, {}))[:250])
    st, raw, _ = chat_sync(port, "alpha", "X selectable again",
                           headers={"x-smg-target-worker": id_a})
    check("[%s] X selectable again once free" % tag, st == 200, "%s %s" % (st, raw[:200]))
    check_no_abort(tag, name)
    stop_router(name)


# ============================================================ S3/S6 功率上限与功率通道

def scenario_power():
    """GPU 利用率读数超上限→迁走；读数缺失（未知）→不得排除。外加观测面断言。

    2026-10-06 容量语义重设计（doc/caps-redesign-2026-10-06.md §1/§2/§5）把准入判据从
    **绝对瓦特**换成 **GPU 利用率百分比**：判定读的是 registry 的 gu: 键（0..1，逐卡归属，
    TTL'd），reason 是 "gpu_util"；瓦特通道（pw: 与 lr_gpu_load_power_*）刻意**原样保留**
    为纯观测——它仍有读者（看板、/workers 的 power_w 字段），只是不再参与任何容量判定。
    所以这一场同时钉两件事：利用率在管准入（写错的实现当场红），瓦特还在被采集但**不再
    咬人**（还按瓦特排除的实现当场红）。

    读数口径沿用 2026-10-04 之后的逐卡形状：gpu_load 写进 registry 的是**该 worker 自己
    那张卡**的读数，卡号来自记录上的 labels.gpu。不带卡号在数据源已是逐卡形状时不写键
    （功率侧）/回退整机 max 并计 fallback（利用率侧，保守方向，见 cards.lua assign_util），
    两种都不是"取整机最热冒充每台"。因此读数断言一律**精确等值**，不用区间——区间对
    "整机最热"与"每卡各自取"同样成立，正是 342.371 长期无人察觉的原因。

    判别性：
      * A 声明 max_gpu_util=60、正文里自己那张卡 65%：GET /workers 的 gpu_util **精确
        = 0.65**，load_state == "full"；未 pin 的 6 条全进 B（B 卡 8%、无上限、转发名
        beta）；连显式 pin A 都带不走 A。
      * **瓦特不再咬人**：B 同时是全场最热的瓦特台（300 W）且**没有**任何上限，它必须
        照常接满 6 条；实现若还留着 pw: 判定，B 会被摘走 → 红。
      * 利用率读数清空（两族 gauge 一起撤走）→ TTL 过期 → gpu_util 字段缺席 → A 必须
        恢复可选（pin A 200 且 A 计数涨）。这条是安全性红线：实现写成"取不到就按 0/沿用
        旧值"都会红。
      * 排除计数按 reason="gpu_util" 增长（"power"/"concurrency" 两个旧拼写不再出现）。
      * lr_gpu_load_util_gpu{worker=} 出现且值在 0..1（准入读数不是打分开的那个混算数）；
        lr_gpu_load_util_samples_total 随 tick 增长；瓦特族仍在（纯观测的存活证明）。
    """
    tag = "S3-util"
    wa, wb = free_port(), free_port()
    # A: own card hot in both units (65 % util / 280 W). B: hottest in watts (300 W, the
    # retired knob would have excluded it at cap 100) but cool in utilisation (8 %),
    # and it declares **no** ceiling at all.
    a = PowerWorker(wa, "alpha", watts=280.0, utils=[("0", 12.0), ("1", 65.0)])
    b = PowerWorker(wb, "beta", watts=300.0, utils=[("0", 12.0), ("1", 8.0)])
    # 利用率与功率都**搭载**在负载源上：SMG_LOAD_SOURCE=none 时定时器根本不启动。metrics
    # 路复用 worker 自己的 /metrics，是 e2e 里最省的一条注入（自带 worker 就能改读数）。
    # SMG_LOAD_POWER=1 留着：瓦特通道作为纯观测必须仍然被采集（下面的 power_w 断言）。
    port, name, gw = start_conf_container({"SMG_POLICY": "round_robin",
                                           "SMG_LOAD_SOURCE": "metrics",
                                           "SMG_LOAD_POWER": "1",
                                           "SMG_LOAD_INTERVAL_SECS": "1",
                                           "SMG_LOAD_TIMEOUT_SECS": "1",
                                           "SMG_LOAD_STALE_SECS": "3"}, tag)
    url_a, url_b = "http://%s:%d" % (gw, wa), "http://%s:%d" % (gw, wb)
    st, _ = post_json(port, "/workers", {"url": url_a, "model_id": "alpha",
                                        "max_gpu_util": 60,
                                        "labels": {"gpu": "1"}})
    st2, _ = post_json(port, "/workers", {"url": url_b, "model_id": "beta",
                                          "labels": {"gpu": "1"}})
    check("[%s] registered (max_gpu_util on A only)" % tag,
          st in (200, 202) and st2 in (200, 202), "%s %s" % (st, st2))
    if not check("[%s] both healthy" % tag, wait_urls(port, [url_a, url_b]), logs(name)[:400]):
        a.shutdown(); b.shutdown(); stop_router(name); return
    id_a = (workers_by_url(port).get(url_a) or {}).get("id")
    # 卡号必须真的落到记录上，否则后面的精确读数断言会因为"根本没有读数"而红。
    reg_meta = (workers_by_url(port).get(url_a) or {}).get("metadata") or {}
    check("[%s] POST /workers passes labels through to the record" % tag,
          reg_meta.get("gpu") == "1", json.dumps(reg_meta)[:200])
    row0 = workers_by_url(port).get(url_a) or {}
    check("[%s] /workers echoes the declared util ceiling as an integer percent" % tag,
          row0.get("max_gpu_util") == 60 and "max_power_w" not in row0
          and row0.get("max_concurrency") is None,
          json.dumps({k: row0.get(k) for k in
                      ("max_gpu_util", "max_power_w", "max_concurrency")}))

    def wait_field(url, key, timeout=25):
        end = time.time() + timeout
        seen = None
        while time.time() < end:
            seen = (workers_by_url(port).get(url) or {}).get(key)
            if seen is not None:
                return seen
            time.sleep(0.4)
        return seen

    # 精确等值而不是区间（342.371 的教训）：gpu_util 是 registry 的 gu: 键（0..1），
    # power_w 是 pw: 键（绝对瓦特），两条通道各归各卡。
    seen_util = wait_field(url_a, "gpu_util")
    check("[%s] gpu_load writes A's own card utilisation into the registry (exactly 0.65)" % tag,
          seen_util == 0.65, str(seen_util))
    seen_util_b = wait_field(url_b, "gpu_util")
    check("[%s] the co-located worker keeps its own reading, not A's (exactly 0.08)" % tag,
          seen_util_b == 0.08, str(seen_util_b))
    check("[%s] the two co-located workers do not share one util number" % tag,
          seen_util != seen_util_b, "%s == %s" % (seen_util, seen_util_b))
    check("[%s] the hot row is red and the cool row is not (load_state from the gateway)" % tag,
          (workers_by_url(port).get(url_a) or {}).get("load_state") == "full"
          and (workers_by_url(port).get(url_b) or {}).get("load_state") is None,
          json.dumps([(workers_by_url(port).get(url_a) or {}).get("load_state"),
                      (workers_by_url(port).get(url_b) or {}).get("load_state")]))
    # 瓦特通道作为纯观测仍然在跑（且**各归各卡**）：pw: 不再是判据，但它没被拆掉。
    seen_power = wait_field(url_a, "power_w")
    check("[%s] the watt channel still collects A's own card (exactly 280, observation only)" % tag,
          seen_power == 280.0, str(seen_power))
    gauge = metric_value(port, "lr_gpu_load_power_watts", 'worker="%s"' % url_a)
    check("[%s] /metrics still exposes lr_gpu_load_power_watts{worker=}" % tag,
          gauge == 280.0, str(gauge))
    util_gauge = metric_value(port, "lr_gpu_load_util_gpu", 'worker="%s"' % url_a)
    check("[%s] lr_gpu_load_util_gpu{worker=} is the 0..1 admission reading" % tag,
          util_gauge == 0.65, str(util_gauge))
    base_samples = metric_value(port, "lr_gpu_load_util_samples_total")
    check("[%s] lr_gpu_load_util_samples_total published (>0)" % tag,
          base_samples is not None and base_samples > 0, str(base_samples))

    # 定时器真的在跑，否则下面的"被排除"可能只是读到一条还没过期的旧样本。
    p_start, p_now = wait_metric_grows(port, "lr_gpu_load_pass_total")
    check("[%s] the gpu-load timer keeps taking passes" % tag,
          p_start is not None and p_now is not None and p_now > p_start,
          "%s -> %s" % (p_start, p_now))
    before = metric_value(port, "smg_worker_capacity_excluded_total",
                          'reason="gpu_util"') or 0
    a0, b0 = a.hits(), b.hits()
    ok = True
    for i in range(6):
        st, raw, _ = chat_sync(port, "alpha", "util-capped batch %d" % i)
        echo = echo_of(st, raw)
        ok = ok and st == 200 and echo.get("model") == "beta"             and echo.get("content", "").startswith("echo[beta]")
    check("[%s] over-ceiling batch served 200 by the uncapped instance, forwarded as beta" % tag,
          ok, str(ok))
    # B 是全场最热的瓦特台（300 W）：还按 pw: 做容量判定的实现会在这里把它一起摘走 → 红。
    check("[%s] the hottest-in-watts worker takes all 6 (watts no longer bite: a+= %d b+= %d)"
          % (tag, a.hits() - a0, b.hits() - b0),
          a.hits() - a0 == 0 and b.hits() - b0 == 6,
          "a+= %d b+= %d" % (a.hits() - a0, b.hits() - b0))
    for i in range(3):
        chat_sync(port, "alpha", "pinned onto util-capped A %d" % i,
                  headers={"x-smg-target-worker": id_a})
    check("[%s] an explicit pin cannot resurrect a capped worker" % tag,
          a.hits() - a0 == 0, "A hits+= %d" % (a.hits() - a0))
    after = metric_value(port, "smg_worker_capacity_excluded_total",
                         'reason="gpu_util"') or 0
    check("[%s] exclusion counted by reason=gpu_util" % tag, after > before,
          "%s -> %s" % (before, after))
    retired = [line for line in metric_lines(port, "smg_worker_capacity_excluded_total")
               if 'reason="power"' in line]
    check("[%s] the retired reason=power series never grows" % tag, not retired,
          json.dumps(retired)[:200])
    grown_start, grown = wait_metric_grows(port, "lr_gpu_load_util_samples_total")
    check("[%s] util samples keep counting across ticks" % tag,
          grown_start is not None and grown is not None and grown > grown_start,
          "%s -> %s" % (grown_start, grown))

    # 反向：两族 gpu-util gauge 一起撤走 → 采不到 → gu: 过期 → **未知而不是 0** →
    # A 恢复可选。写成"取不到按 0/沿用旧值"的实现，要么字段还在（前一条红），要么这里
    # pin 不进（读数被当成 0 反而永远可选——那用 set_utils(off) 之后 pin 通 + 字段缺席
    # 两条一起分辨）。
    a.drop_all_util()
    cleared = False
    deadline = time.time() + 25
    while time.time() < deadline:
        row = workers_by_url(port).get(url_a) or {}
        if row.get("gpu_util") is None and "load_state" in row:
            cleared = True
            break
        if row.get("gpu_util") is None and (row.get("max_gpu_util") or 0) == 0:
            cleared = True
            break
        time.sleep(0.4)
    cleared = (workers_by_url(port).get(url_a) or {}).get("gpu_util") is None and cleared
    check("[%s] a missing reading reads as unknown, not zero" % tag, cleared,
          json.dumps(workers_by_url(port).get(url_a, {}))[:250])
    a1 = a.hits()
    st, raw, _ = chat_sync(port, "alpha", "unknown util must still route",
                           headers={"x-smg-target-worker": id_a})
    check("[%s] unknown util never costs capacity: pinned A serves again" % tag,
          st == 200 and a.hits() - a1 == 1 and echo_of(st, raw).get("model") == "alpha",
          "%s hits+= %d" % (st, a.hits() - a1))
    check_no_abort(tag, name)
    stop_router(name)
    a.shutdown()
    b.shutdown()


def scenario_power_switch_off():
    """缺省关闭（不设 SMG_LOAD_POWER）：功率族一个 series 都不出现，而负载族照常在。

    这条负断言只有在"负载通道确实活着"时才有意义，否则"功率族缺席"可以是整个子系统没跑
    造成的假绿。它与 scenario_power 的正断言成对：conf 里若漏了 env SMG_LOAD_POWER 声明，
    正断言那侧就会全空，从而把静默失效照出来。
    """
    tag = "S6-power-off"
    wa = free_port()
    a = PowerWorker(wa, "alpha", watts=280.0)
    port, name, gw = start_conf_container({"SMG_POLICY": "round_robin",
                                           "SMG_LOAD_SOURCE": "metrics",
                                           "SMG_LOAD_INTERVAL_SECS": "1",
                                           "SMG_LOAD_STALE_SECS": "4"}, tag)
    url_a = "http://%s:%d" % (gw, wa)
    st, _ = post_json(port, "/workers", {"url": url_a, "model_id": "alpha"})
    if not check("[%s] worker registered" % tag, st in (200, 202), str(st)):
        a.shutdown(); stop_router(name); return
    load_seen = None
    deadline = time.time() + 20
    while time.time() < deadline:
        lines = metric_lines(port, "lr_gpu_load")
        if any('worker="%s"' % url_a in line for line in lines):
            load_seen = lines
            break
        time.sleep(0.4)
    check("[%s] load channel is alive (lr_gpu_load{worker=} present)" % tag,
          load_seen is not None, json.dumps(metric_lines(port, "lr_gpu_load"))[:300])
    time.sleep(2.0)
    st, text, _ = http("GET", "http://127.0.0.1:%d/metrics" % port)
    leaked = [line for line in text.splitlines()
              if not line.startswith("#") and line.startswith("lr_gpu_load_power")]
    check("[%s] default-off exports not a single lr_gpu_load_power* series" % tag,
          not leaked, json.dumps(leaked)[:300])
    check("[%s] no watt sample reaches the registry while the channel is off" % tag,
          (workers_by_url(port).get(url_a) or {}).get("power_w") is None,
          json.dumps(workers_by_url(port).get(url_a, {}))[:200])
    check_no_abort(tag, name)
    stop_router(name)
    a.shutdown()


# ============================================ S3b 同机逐卡归属（342.371 的回归门）

CARD_WATTS = [("0", 12.0), ("1", 280.0), ("2", 99.0)]
# 逐卡利用率（percent）。三张卡的读数刻意让**只有 gpu=1 那台**越过 50 的上限；
# 实现若把整机最热冒充每台，三台会一起被排除 → spread/pin 断言当场红（342.371 的
# 利用率复刻）。0.12/0.82/0.37 三个精确值互不相同，"取全机最大"会让三条精确断言
# 一起变成 0.82。
CARD_UTILS = [("0", 12.0), ("1", 82.0), ("2", 37.0)]


def scenario_power_per_card():
    """同机三台 worker 各自 pin 一张卡：gpu_util 必须精确等于自己那张卡的读数。

    这条是 342.371 故障的回归门，2026-10-06 之后按**利用率**口径钉（准入判据换到了
    gu: 键；瓦特仍是纯观测，同场次一并钉住各归各卡）。生产上 8 个 worker 的读数全是
    同一个 342.371，真实 GPU 是 94/84/284/208/89/94/431/95 W —— 根因是 PromQL 的
    max by (Hostname,instance) 把 8 张卡折成 1 条 series。恒真区间检不出这件事，
    所以这里换成**三台互不相同的精确值** + 只热一台的上限：取全机最大必三台全被排除。

    判别性（每条都对一种具体写错）：
      * A/B/C 挂同一份三卡正文（gpu 0/1/2 = 12/82/37 %），各自 labels.gpu 指一张，
        gpu_util 必须**精确** = 0.12 / 0.82 / 0.37 且互不相同；每台另挂一个只有最热
        那台才触发的 max_gpu_util=50。实现取整机 max → 三台全 0.82 全被排除 → 红。
      * 冷两台照常服务（spread 有流量），热的 B 连 pin 都带不走。
      * lr_gpu_load_util_per_card_workers 必须到 3（逐卡归属命中数）：只报一个 matched
        分不出「各归各卡」与「共用整机 max」，这正是 342.371 的观测面处方。
      * 反向断言：B 的两族 gpu-util series 全撤（drop_all_util）→ B 的 gpu_util 缺席
        （不是 0、不是整机 max、不是邻居那张卡的读数）→ B 必须恢复可选（pin 200 通
        流量、计数涨）。这条钉「未知 → 不排除」；功率侧的"认不出卡不写键"由 pw: 的
        精确断言继续覆盖（B 的卡还挂在瓦特正文里，两族的形状在这里分开）。
      * 邻居读不到不许波及另外两台：A、C 仍各自 0.12 / 0.37。
    """
    tag = "S3b-percard"
    wa, wb, wc = free_port(), free_port(), free_port()
    a = PowerWorker(wa, "alpha", cards=CARD_WATTS, utils=CARD_UTILS)
    b = PowerWorker(wb, "beta", cards=CARD_WATTS, utils=CARD_UTILS)
    c = PowerWorker(wc, "gamma", cards=CARD_WATTS, utils=CARD_UTILS)
    port, name, gw = start_conf_container({"SMG_POLICY": "round_robin",
                                           "SMG_LOAD_SOURCE": "metrics",
                                           "SMG_LOAD_POWER": "1",
                                           "SMG_LOAD_INTERVAL_SECS": "1",
                                           "SMG_LOAD_TIMEOUT_SECS": "1",
                                           "SMG_LOAD_STALE_SECS": "3"}, tag)
    url_a, url_b, url_c = ("http://%s:%d" % (gw, p) for p in (wa, wb, wc))
    # 三台各 pin 一张卡，且都声明一个「只有最热那张才会触发」的利用率上限：12 与 37
    # 都在 50 以下必须照常可选，只有 82 那台被排除。实现若取整机 max，三台都会因为
    # 82 > 50 一起被排除 → 下面的 spread 与 pin 断言全红。
    st1, _ = post_json(port, "/workers", {"url": url_a, "model_id": "alpha",
                                           "max_gpu_util": 50,
                                           "labels": {"gpu": "0"}})
    st2, _ = post_json(port, "/workers", {"url": url_b, "model_id": "beta",
                                           "max_gpu_util": 50,
                                           "labels": {"gpu": "1"}})
    st3, _ = post_json(port, "/workers", {"url": url_c, "model_id": "gamma",
                                           "max_gpu_util": 50,
                                           "labels": {"gpu": "2"}})
    if not check("[%s] three workers registered with distinct cards" % tag,
                 all(s in (200, 202) for s in (st1, st2, st3)),
                 "%s %s %s" % (st1, st2, st3)):
        for w in (a, b, c):
            w.shutdown()
        stop_router(name)
        return
    if not check("[%s] all three healthy" % tag,
                 wait_urls(port, [url_a, url_b, url_c]), logs(name)[:400]):
        for w in (a, b, c):
            w.shutdown()
        stop_router(name)
        return
    rows = workers_by_url(port)
    id_b = (rows.get(url_b) or {}).get("id")
    # 卡号真的进了记录（否则 "缺席" 会因为认不出卡而假绿，归因就错位到 fixture 上）。
    check("[%s] each record carries its own card id" % tag,
          all(((rows.get(u) or {}).get("metadata") or {}).get("gpu") == g
              for (u, g) in ((url_a, "0"), (url_b, "1"), (url_c, "2"))),
          json.dumps({u: (rows.get(u) or {}).get("metadata")
                      for u in (url_a, url_b, url_c)})[:300])

    def wait_utils(timeout=25):
        end = time.time() + timeout
        got = {}
        while time.time() < end:
            got = {u: (workers_by_url(port).get(u) or {}).get("gpu_util")
                   for u in (url_a, url_b, url_c)}
            if all(v is not None for v in got.values()):
                return got
            time.sleep(0.4)
        return got

    utils_seen = wait_utils()
    check("[%s] A pinned to gpu=0 reads exactly 12 %% (not the machine max)" % tag,
          utils_seen.get(url_a) == 0.12, str(utils_seen))
    check("[%s] B pinned to gpu=1 reads exactly 82 %%" % tag,
          utils_seen.get(url_b) == 0.82, str(utils_seen))
    check("[%s] C pinned to gpu=2 reads exactly 37 %%" % tag,
          utils_seen.get(url_c) == 0.37, str(utils_seen))
    check("[%s] the three co-located workers report three different utilisations" % tag,
          len({utils_seen.get(u) for u in (url_a, url_b, url_c)}) == 3, str(utils_seen))
    # 冷的那两台不许因为「同机有人满载」被排除（342.371 的容量事故正是这个形状）。
    ok_ac = True
    for i in range(4):
        st, raw, _ = chat_sync(port, "alpha", "cold card stays selectable %d" % i)
        ok_ac = ok_ac and st == 200
    check("[%s] the two cool workers keep serving while the hot one is capped" % tag,
          ok_ac and a.hits() >= 1 and c.hits() >= 1,
          "a=%d c=%d" % (a.hits(), c.hits()))
    b0 = b.hits()
    st, raw, _ = chat_sync(port, "beta", "hot card stays excluded",
                           headers={"x-smg-target-worker": id_b})
    check("[%s] the hot worker stays excluded even when pinned (82 > cap 50)" % tag,
          b.hits() - b0 == 0, "b+= %d status=%s" % (b.hits() - b0, st))
    # 观测面处方：逐卡命中数必须真是 3（只报 matched 分不出「各归各卡」与「共用整机
    # max」—— 那正是 342.371 长期无人察觉的观测盲区）。
    per_card = None
    deadline = time.time() + 20
    while time.time() < deadline:
        per_card = metric_value(port, "lr_gpu_load_util_per_card_workers")
        if per_card == 3.0:
            break
        time.sleep(0.4)
    check("[%s] lr_gpu_load_util_per_card_workers reaches three (per-card attribution is real)" % tag,
          per_card == 3.0, str(per_card))

    # ---- 反向断言：B 的利用率 series 全撤 → 读数缺席 → 恢复可选
    b.drop_all_util()
    cleared = False
    end = time.time() + 25
    while time.time() < end:
        if (workers_by_url(port).get(url_b) or {}).get("gpu_util") is None:
            cleared = True
            break
        time.sleep(0.4)
    check("[%s] dropping the util series leaves B without a reading (not 0, not the machine max)"
          % tag, cleared,
          json.dumps(workers_by_url(port).get(url_b, {}))[:250])
    b1 = b.hits()
    st, raw, _ = chat_sync(port, "beta", "unknown card must not cost capacity",
                           headers={"x-smg-target-worker": id_b})
    check("[%s] an unresolvable card never costs capacity: pinned B serves again" % tag,
          st == 200 and b.hits() - b1 == 1,
          "status=%s b+= %d" % (st, b.hits() - b1))
    # 邻居读不到卡不许波及同机另外两台。
    still = {u: (workers_by_url(port).get(u) or {}).get("gpu_util")
             for u in (url_a, url_c)}
    check("[%s] a neighbour's missing card leaves the other two readings intact" % tag,
          still.get(url_a) == 0.12 and still.get(url_c) == 0.37, str(still))
    check_no_abort(tag, name)
    stop_router(name)
    for w in (a, b, c):
        w.shutdown()


class ChatWorker(object):
    """A chat worker whose response delay is settable at *runtime*.

    为什么不用共享 mock：它的 LATENCY_MS/CHUNK_MS 只能在启动时用 env/argv 定死，运行时
    没有任何改口（/fault 只改 models_mode）。本场景必须先看清亲和挑中了哪一台、再把那一台
    变慢来占住在途槽位——"先决定哪台、再让它慢"这件事只有运行时可设的延迟能做到，否则另一
    台（延迟 0）永远占不住槽，wait_inflight 就成了看运气的前置条件。它同时把 8 发同前缀
    的请求保持在毫秒级（它们必须落在另一台），整个场景因此能在几秒内跑完而不是几分钟。
    """

    def __init__(self, port, model):
        self.port, self.model = port, model
        self.chats = 0
        self.delay_ms = 0.0
        self.lock = threading.Lock()
        outer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt, *args):
                pass

            def _send(self, status, payload, ctype="application/json"):
                raw = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                path = self.path.split("?", 1)[0]
                if path == "/health":
                    return self._send(200, {"ok": True})
                if path == "/v1/models":
                    return self._send(200, {"object": "list", "data": [
                        {"id": outer.model, "object": "model"}]})
                if path == "/metrics":
                    return self._send(200, "# TYPE mock_requests_total counter\n"
                                            "mock_requests_total 0\n",
                                       ctype="text/plain; charset=utf-8")
                return self._send(404, {"error": {"message": "no route " + path}})

            def do_POST(self):
                raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                try:
                    body = json.loads(raw.decode()) if raw else {}
                except ValueError:
                    body = {}
                if self.path.split("?", 1)[0] != "/v1/chat/completions":
                    return self._send(404, {"error": {"message": "no route"}})
                with outer.lock:
                    outer.chats += 1
                    delayed = outer.delay_ms
                forwarded = body.get("model")
                if delayed:
                    time.sleep(delayed / 1000.0)   # 占住网关的在途槽位
                return self._send(200, {
                    "id": "caps-%d" % outer.chats, "object": "chat.completion",
                    "model": forwarded,
                    "choices": [{"index": 0, "finish_reason": "stop",
                                 "message": {"role": "assistant",
                                             "content": "echo[%s] sticky" % forwarded}}],
                    "echo_body": body,
                })

        self.server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def set_delay_ms(self, ms):
        with self.lock:
            self.delay_ms = float(ms)

    def hits(self):
        with self.lock:
            return self.chats

    def shutdown(self):
        self.server.shutdown()
        self.server.server_close()


# ================================================ S8 caps 跨声明层 / 跨重启存活


def published_port(name, fallback=None):
    """重新读取发布端口：docker restart 会重新分配 -p ::8080 的宿主机端口。

    probe_container 拿的是 docker 随机分配的端口号，重启后可能换一个，于是继续敲旧
    端口会得到"网关没起来"的假失败。重启段之后一律以这里读回的端口为准。
    """
    out = subprocess.run(["docker", "port", name, "8080"], capture_output=True)
    for line in out.stdout.decode().split():
        if line.startswith("127.0.0.1:"):
            return int(line.split(":")[1])
    return fallback


def scenario_caps_persistence():
    """声明层给「非 config 行」下发 caps，并且 caps 能活过 docker restart。

    这是用户报的那个 bug 的唯一回归门：max_concurrency 配了重启就没。根因两条：
      (a) worker 记录只活在 lr_workers 内存 shdict，全仓零落盘路径，容器一重启就由
          SMG_WORKER_URLS 重新播种成**裸记录**（caps 蒸发）；
      (b) 声明层想把上限写回去，被 reconcile_upstreams 的 else 分支整行跳过——旧实现
          只对 discovery == "config" 的行动手，protected 行（bootstrap / watcher / 手工
          POST）连 caps 都拿不到。

    为什么这两行**必须**走 SMG_WORKER_URLS 播种而不是 POST /workers：用 POST 注册的行在
    重启后由声明层的 create 分支重建（那一支旧实现就带 caps），于是"重启存活"会在旧实现
    上假绿——它测的是 create 路径，根本没碰 else 分支。bootstrap 播种的行重启后仍是
    protected（discovery=nil），只能靠 else 分支拿回上限，旧实现当场红。这才是 21.k 生产
    那 8 台的形状。

    判别性（括号里是它在旧实现 3728821^ 上的实测结果）：
      * 播种行的 discovery 回显 "dynamic"（记录层是 nil，展示层折叠）：先确立"这确实是
        protected 行"，否则后面的下发无从归因。(两版都绿——前提检查)
      * 声明层给 protected 行下发 caps 成功，且**精确**回显（1 / 250，不是 0 或缺席）：
        0 会被读成"零个槽位"。(旧实现红：else 分支不动手)
      * 没声明并发上限的那一行保持字段**缺席**：这是"只下发不清除"的另一面。(两版绿——
        护栏)
      * 身份红线不许跟着放开：声明里给那行写一个不同的 model_id，protected 行必须保持
        原名（doc/gap-worker-caps.md 第 312 行第 4 项）。caps-only 补丁 + registry.update
        的 discovery 门两道保险。(两版绿——护栏，防未来有人复用 upstream_patch)
      * docker restart 后 caps 自己回来，并且**当场真的在管流量**：被限的那台一条都不
        许多进。只测字段回显不够——字段看得见却没人执行，正是本 bug 的形状。(旧实现红：
        播种成裸记录后没有任何路径能补回 caps)
    """
    tag = "S8-caps-restart"
    pa, pb = free_port(), free_port()
    start_mock_env(pa, "alpha", LATENCY_MS=4000)   # A = 被并发上限钉住的那台
    start_mock(pb, "alpha")                        # B = 对照（只挂一个用不上的利用率上限）
    cfg_file = "/tmp/lr-caps-%s.json" % RUN
    # A、B 都由 SMG_WORKER_URLS 播种成 protected 裸记录（见 docstring：这是判别性的关键）。
    # IGW 关掉：本场景验 caps 的下发与存活，转发名/模型门是 S1 的活；重启后行由声明层重建，
    # 留着模型门会让"流量落点"混进无关归因。
    # SMG_WORKER_URLS 必须在容器启动那一刻就写好，可 gw 是启动后才从 docker inspect
    # 读回来的：probe_container 不指定 --network，跑的就是 docker 默认 bridge，网关恒为
    # GATEWAY_FALLBACK（本文件顶部）。下面把"读回来的 gw 确实等于它"写成一条断言，
    # 前提不成立时当场红，而不是让 worker 静默注册到拨不通的地址上。
    gw0 = GATEWAY_FALLBACK
    seed_urls = "http://%s:%d,http://%s:%d" % (gw0, pa, gw0, pb)
    port, name, gw = start_conf_container({"SMG_POLICY": "round_robin",
                                           "SMG_ENABLE_IGW": "0",
                                           "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                                           "SMG_WORKER_URLS": seed_urls,
                                           # 声明层落盘的那一份：容器重启后 shdict 全清，
                                           # 只有这个文件能依赖。
                                           "LMR_CONFIG_FILE": cfg_file}, tag)
    url_a, url_b = "http://%s:%d" % (gw, pa), "http://%s:%d" % (gw, pb)
    if not check("[%s] both seeded from SMG_WORKER_URLS and healthy" % tag,
                 wait_urls(port, [url_a, url_b]), logs(name)[:400]):
        stop_router(name)
        return
    check("[%s] premise: the bridge gateway is the address seeded" % tag, gw == gw0,
          "inspect=%s seeded=%s" % (gw, gw0))
    rows = workers_by_url(port)
    # 播种行在展示层是 "dynamic"（记录层 nil）：先钉住"这确实是 protected 行"。
    check("[%s] both rows are protected (bootstrap-seeded, shown dynamic)" % tag,
          (rows.get(url_a) or {}).get("discovery") == "dynamic"
          and (rows.get(url_b) or {}).get("discovery") == "dynamic",
          json.dumps({u: (rows.get(u) or {}).get("discovery")
                      for u in (url_a, url_b)})[:200])
    check("[%s] neither row carries a cap before the declaration" % tag,
          "max_concurrency" not in (rows.get(url_a) or {})
          and "max_power_w" not in (rows.get(url_b) or {})
          and "max_gpu_util" not in (rows.get(url_b) or {})
          and "load_state" not in (rows.get(url_a) or {}),
          json.dumps([rows.get(url_a, {}), rows.get(url_b, {})])[:300])

    # 声明层整表替换：两行都是 protected。A 只写并发上限；B 写一个 GPU 利用率上限
    # （本场景没有负载源 -> 读数未知 -> 永不生效，只用来验字段下发）和一个冒充改名的
    # model_id。2026-10-06 §1：max_power_w 退役，声明层的新字段是 max_gpu_util。
    st, doc = post_json(port, "/_ui/config/upstreams", {"entries": [
        {"url": url_a, "model_id": "alpha", "max_concurrency": 1},
        {"url": url_b, "model_id": "renamed-by-declaration", "max_gpu_util": 60},
    ]})
    check("[%s] declaration layer accepts caps on protected rows (200)" % tag,
          st == 200, "%s %s" % (st, json.dumps(doc)[:250]))
    projected = False
    deadline = time.time() + 25
    while time.time() < deadline:
        r2 = workers_by_url(port)
        if ((r2.get(url_a) or {}).get("max_concurrency") == 1
                and (r2.get(url_b) or {}).get("max_gpu_util") == 60):
            projected = True
            break
        time.sleep(0.4)
    check("[%s] caps projected onto protected rows (nil and dynamic spellings)" % tag,
          projected,
          json.dumps([workers_by_url(port).get(url_a, {}),
                      workers_by_url(port).get(url_b, {})])[:400])
    # 没声明并发上限的行保持缺席，而不是被下发成 0。
    check("[%s] the row that declares no concurrency cap keeps the field absent" % tag,
          "max_concurrency" not in (workers_by_url(port).get(url_b) or {})
          and "min_concurrency" not in (workers_by_url(port).get(url_b) or {}),
          json.dumps(workers_by_url(port).get(url_b, {}))[:250])
    # load_state 的「无门时键缺席」在活行上也钉一遍：本场景没有任何负载源，B 的 util
    # 上限只会把 B 变成 busy/idle 之一或维持未知 —— 但它**绝不能**没有 load_state 键
    # 也没有值可查（A 至少并发=1 是可判定的）。
    row_a8 = workers_by_url(port).get(url_a) or {}
    check("[%s] the capped live row carries a load_state value" % tag,
          row_a8.get("load_state") in ("idle", "busy", "full"),
          json.dumps(row_a8)[:250])
    # 同一条声明里给 B 写的 model_id 必须被拒：protected 行的身份不归声明层管。
    kept_model = (workers_by_url(port).get(url_b) or {}).get("model_id")
    check("[%s] the identity red line still holds (declared model_id not applied)" % tag,
          kept_model == "alpha", str(kept_model))

    # ---- 重启前先把上限落实成"能挡住流量"，确认它不是只在 GET /workers 里好看
    id_a = (workers_by_url(port).get(url_a) or {}).get("id")
    base0 = {p: mock_lines(p, "/v1/chat/completions") for p in (pa, pb)}
    held0_thread, held0 = chat_async(port, "alpha", "pre-restart hold",
                                     headers={"x-smg-target-worker": id_a}, timeout=60)
    wait_inflight(port, url_a, 1, timeout=25)
    ok0 = True
    for i in range(3):
        st, raw, _ = chat_sync(port, "alpha", "pre-restart burst %d" % i, timeout=60)
        ok0 = ok0 and st == 200
    held0_thread.join(timeout=30)
    a0 = mock_lines(pa, "/v1/chat/completions") - base0[pa]
    check("[%s] pre-restart: the projected cap already gates traffic (A only the held)" % tag,
          ok0 and a0 == 1, "a=%d" % a0)

    # ---- 重启：shdict 清零，声明层是唯一能依赖的一层
    subprocess.run(["docker", "restart", name], capture_output=True)
    port = published_port(name, port)
    up = False
    deadline = time.time() + 60
    while time.time() < deadline:
        if http("GET", "http://127.0.0.1:%d/health" % port, timeout=2)[0] == 200:
            up = True
            break
        time.sleep(0.5)
    if not check("[%s] router back after the restart" % tag, up, logs(name)[-300:]):
        stop_router(name)
        return
    if not check("[%s] both rows back after the restart" % tag,
                 wait_urls(port, [url_a, url_b], timeout=60), logs(name)[:400]):
        stop_router(name)
        return
    survived = False
    deadline = time.time() + 40
    while time.time() < deadline:
        if (workers_by_url(port).get(url_a) or {}).get("max_concurrency") == 1:
            survived = True
            break
        time.sleep(0.5)
    check("[%s] the cap survived docker restart (record layer never persists)" % tag,
          survived, json.dumps(workers_by_url(port).get(url_a, {}))[:280])
    # 字段回来了还不够，得看它真的在管流量：A 挂一条 4 s 的长响应占住那个槽位，
    # 再连发 5 条，一条都不许多进 A（全进 B）。B 那个 60% 利用率上限此时必须保持惰性
    # （没有负载源 = 读数未知 = 不排除，红线 §0 第 2 条），否则 5 条无处可去、下面必红。
    id_a = (workers_by_url(port).get(url_a) or {}).get("id")
    # 基线必须在挂住 A 的那条长响应**之前**取：那条自己也落在 A 上，先取基线就把它
    # 算进基线里，于是 hits_a 恒为 0（本文件 S2 同一形状，照抄它的顺序）。
    base = {p: mock_lines(p, "/v1/chat/completions") for p in (pa, pb)}
    held_thread, held = chat_async(port, "alpha", "restart-held slot",
                                   headers={"x-smg-target-worker": id_a}, timeout=60)
    busy = wait_inflight(port, url_a, 1, timeout=25)
    ok_batch = True
    for i in range(5):
        st, raw, _ = chat_sync(port, "alpha", "burst after restart %d" % i, timeout=60)
        ok_batch = ok_batch and st == 200
    held_thread.join(timeout=30)
    hits_a = mock_lines(pa, "/v1/chat/completions") - base[pa]
    hits_b = mock_lines(pb, "/v1/chat/completions") - base[pb]
    check("[%s] the resurrected cap gates traffic (A takes only the held one)" % tag,
          busy and held.status == 200 and ok_batch and hits_a == 1 and hits_b == 5,
          "busy=%s held=%s a=%d b=%d" % (busy, held.status, hits_a, hits_b))
    check("[%s] the pool row stays protected, not reclaimed by the declaration" % tag,
          (workers_by_url(port).get(url_a) or {}).get("discovery") == "dynamic",
          json.dumps(workers_by_url(port).get(url_a, {}))[:200])
    check_no_abort(tag, name)
    stop_router(name)


# ================================================================ S4 亲和对抗

PFX = ("cache-aware sticky conversation prefix " * 12) + " with a long shared body "


def scenario_affinity_vs_cap():
    """cache_aware 的亲和命中不许把达上限的实例带回来。

    判别性：
      * 先确立前提：同一长前缀 10 发必须全落一台（10/0），否则后面的"迁走"没有对抗性
        （亲和根本没建立，谁迁走都绿）。
      * 粘住的那台声明 max_concurrency=1 并被一条 pin 住的长响应挂住 → 同前缀 8 发全投
        另一台。没有候选级排除时 cache_aware 的亲和命中读的是树里的租户 URL、不看负载
        （policies/cache_aware.lua），这 8 发会原封不动回到粘住的那台 → 红。
      * 解除上限后 X 重新可选，用两条独立证据：pin X 必须真落到 X；换全新前缀时 X 至少
        分到一发（亲和被迁走是正确行为，所以"回来"不能靠同前缀断言）。
    """
    tag = "S4-affinity"
    pa, pb = free_port(), free_port()
    # 两台都用可运行时改延迟的自带 worker：亲和先粘到谁，就把谁变慢占住在途槽位。
    wa = ChatWorker(pa, "alpha")
    wb = ChatWorker(pb, "alpha")
    port, name, gw = start_conf_container({"SMG_POLICY": "cache_aware"}, tag)
    url_a, url_b = "http://%s:%d" % (gw, pa), "http://%s:%d" % (gw, pb)
    st, _ = post_json(port, "/workers", {"url": url_a, "model_id": "alpha"})
    st2, _ = post_json(port, "/workers", {"url": url_b, "model_id": "alpha"})
    if not check("[%s] both registered" % tag, st in (200, 202) and st2 in (200, 202),
                 "%s %s" % (st, st2)):
        wa.shutdown(); wb.shutdown()
        stop_router(name)
        return
    if not check("[%s] both healthy" % tag, wait_urls(port, [url_a, url_b]), logs(name)[:400]):
        wa.shutdown(); wb.shutdown()
        stop_router(name)
        return

    # 落点判定用各自 worker 的计数器差值：自带 worker 不写共享 mock 的那份日志，
    # 拿 mock_lines 计数会永远读到 0，从而把"全都迁走了"读成假绿。
    for i in range(10):
        chat_sync(port, "alpha", PFX + " f%d" % i)
    warm_a = wa.hits()
    warm_b = wb.hits()
    check("[%s] premise: 10 same-prefix requests stick to one instance (%d/%d)"
          % (tag, warm_a, warm_b),
          warm_a + warm_b == 10 and max(warm_a, warm_b) == 10,
          "a=%d b=%d" % (warm_a, warm_b))
    if warm_a + warm_b != 10:
        wa.shutdown(); wb.shutdown()
        stop_router(name)
        return
    # X = 亲和选中的那台，上限加在它身上（PUT 是既有的调度旋钮更新路径）
    sticky, other = (wa, wb) if warm_a == 10 else (wb, wa)
    sticky_url = url_a if warm_a == 10 else url_b
    id_sticky = (workers_by_url(port).get(sticky_url) or {}).get("id")
    st3, doc3 = put_json(port, "/workers/%s" % id_sticky, {"max_concurrency": 1})
    # PUT /workers/{id} 的契约应答是 202（registry.update 排队 + router.lua 的
    # "Worker update queued for background processing"），不是 200。这里精确钉 202：
    # 上限字段若不被 PUT 接受会走 400/404，写成 in (200,202) 就把"实现根本没认这个字段"
    # 与"应答码写法不同"两件事混在一起了。
    check("[%s] cap declared on the affinity-chosen instance via PUT (202)" % tag,
          st3 == 202,
          "%s %s" % (st3, json.dumps(doc3)[:200]))
    if st3 != 202:
        wa.shutdown(); wb.shutdown()
        stop_router(name)
        return
    # 上限是记录上的字段，写进去就得看得见（看不见的话后面的"迁走"断言无从归因）
    echoed = (workers_by_url(port).get(sticky_url) or {}).get("max_concurrency")
    check("[%s] PUT really persisted the cap (GET /workers echoes 1)" % tag, echoed == 1,
          str(echoed))

    sticky.set_delay_ms(4000)   # 只有 X 变慢：把它的在途槽位钉住
    held_thread, held = chat_async(port, "alpha", PFX + " slot filler",
                                   headers={"x-smg-target-worker": id_sticky})
    busy = wait_inflight(port, sticky_url, 1, timeout=20)
    check("[%s] X is at its concurrency cap while the batch runs" % tag, busy,
          json.dumps(workers_by_url(port).get(sticky_url, {}))[:250])
    x0, y0 = sticky.hits(), other.hits()
    ok = True
    for i in range(8):
        st, raw, _ = chat_sync(port, "alpha", PFX + " follow-up %d" % i)
        ok = ok and st == 200
    hits_x = sticky.hits() - x0
    hits_y = other.hits() - y0
    held_thread.join(timeout=30)
    check("[%s] affinity cannot carry a capped worker: 8 same-prefix move to Y (%d/%d)"
          % (tag, hits_x, hits_y),
          ok and hits_x == 0 and hits_y == 8, "x=%d y=%d" % (hits_x, hits_y))
    sticky.set_delay_ms(0)
    freed = wait_inflight_zero(port, sticky_url, timeout=40)
    check("[%s] X frees up after the long response" % tag, freed,
          json.dumps(workers_by_url(port).get(sticky_url, {}))[:250])
    x1 = sticky.hits()
    st, raw, _ = chat_sync(port, "alpha", "back on X via pin",
                           headers={"x-smg-target-worker": id_sticky})
    check("[%s] once free, a request pinned to X is served by X" % tag, st == 200,
          "%s %s hits+= %d" % (st, raw[:200], sticky.hits() - x1))
    check("[%s] the pinned request really landed on X" % tag, sticky.hits() - x1 == 1,
          "hits+= %d" % (sticky.hits() - x1))
    x2, y2 = sticky.hits(), other.hits()
    for i in range(10):
        # 全新前缀（互相也不同）：亲和树里没有它们，落点只由候选集 + min load 决定，
        # 所以 X 必须重新出现在候选集里。
        chat_sync(port, "alpha", "brand new prefix %d " % i + ("x" * 120))
    back_x = sticky.hits() - x2
    back_y = other.hits() - y2
    check("[%s] fresh prefixes see X selectable again (%d/%d)" % (tag, back_x, back_y),
          back_x + back_y == 10 and back_x >= 1, "x=%d y=%d" % (back_x, back_y))
    check_no_abort(tag, name)
    stop_router(name)
    wa.shutdown()
    wb.shutdown()


# ================================================================ S5 全场上限 503 + 老行为

def scenario_all_capped_503():
    """全部因达上限被排除：**429** + code 不变 + message 精确；对照 503 文案与老行为。

    2026-10-06 容量语义重设计（doc/caps-redesign-2026-10-06.md §4，用户裁定覆盖
    2026-10-01 的"全到顶 503"口径）：全池抵在并发/GPU 利用率上限不是"服务不可用"，是
    "暂时没法接单"→ 429 Too Many Requests，error.type 随状态码变；code 沿用
    no_available_workers（契约改动面最小）。熔断/不健康/组不服务**仍是 503 原文案**。

    判别性：
      * 两台各 max_concurrency=1、各被一条 pin 的长响应挂住，第三条 → 429，
        X-SMG-Error-Code 仍是 no_available_workers，**error.type == "Too Many Requests"**
        （实现还答 503 的话这一族三条一起红），message **精确等于**
        "No available workers (2 at their concurrency or GPU-util limit)"——旧文案里的
        "configured concurrency/power cap" 字样必须消失（瓦特退役进了文案，实现漏改
        字符串也会被精确匹配当场抓住）。实现若放松成"都到顶就照旧转发"，这里不是
        429 → 红。
      * 对照组（一个死端口、没有任何上限）：**503** 文案保持原样、code 同、不许带
        cap/util 字样——容量到顶与服务不可用的两条路径必须分得开。
    """
    tag = "S5-all-capped"
    pa, pb = free_port(), free_port()
    start_mock_env(pa, "alpha", LATENCY_MS=5000)
    start_mock_env(pb, "alpha", LATENCY_MS=5000)
    port, name, gw = start_conf_container({"SMG_POLICY": "round_robin"}, tag)
    url_a, url_b = "http://%s:%d" % (gw, pa), "http://%s:%d" % (gw, pb)
    st, _ = post_json(port, "/workers", {"url": url_a, "model_id": "alpha",
                                        "max_concurrency": 1})
    st2, _ = post_json(port, "/workers", {"url": url_b, "model_id": "alpha",
                                         "max_concurrency": 1})
    if not check("[%s] both capped workers registered" % tag,
                 st in (200, 202) and st2 in (200, 202), "%s %s" % (st, st2)):
        stop_router(name)
        return
    if not check("[%s] both healthy" % tag, wait_urls(port, [url_a, url_b]), logs(name)[:400]):
        stop_router(name)
        return
    rows = workers_by_url(port)
    id_a, id_b = rows[url_a]["id"], rows[url_b]["id"]
    ta, ha = chat_async(port, "alpha", "filler A holds the only slot",
                        headers={"x-smg-target-worker": id_a})
    tb, hb = chat_async(port, "alpha", "filler B holds the only slot",
                        headers={"x-smg-target-worker": id_b})
    both_busy = wait_inflight(port, url_a, 1) and wait_inflight(port, url_b, 1)
    check("[%s] both workers sit at their cap" % tag, both_busy,
          json.dumps([workers_by_url(port).get(url_a, {}),
                      workers_by_url(port).get(url_b, {})])[:300])
    st, raw, hdrs = chat_sync(port, "alpha", "the request with nowhere to go")
    st_v, code, message = err_parts(st, raw, hdrs)
    etype = ""
    try:
        etype = (json.loads(raw).get("error") or {}).get("type") or ""
    except ValueError:
        pass
    check("[%s] pool full answers 429 (capacity, not unavailable)" % tag,
          st_v == 429, "%s %s" % (st_v, raw[:200]))
    check("[%s] code stays no_available_workers" % tag, code == "no_available_workers",
          "%s %s" % (code, raw[:200]))
    check("[%s] error.type follows the new status" % tag,
          etype == "Too Many Requests", "%s %s" % (etype, raw[:200]))
    check("[%s] message names the excluded count and the cap reason" % tag,
          message == "No available workers (2 at their concurrency or GPU-util limit)",
          message[:200])
    ta.join(timeout=30)
    tb.join(timeout=30)
    check_no_abort(tag, name)
    stop_router(name)

    # 对照：非上限造成的 503 保持原文案
    tag2 = "S5b-unhealthy"
    dead = free_port()
    port2, name2, gw2 = start_conf_container({"SMG_POLICY": "round_robin"}, tag2)
    url_dead = "http://%s:%d" % (gw2, dead)
    st, _ = post_json(port2, "/workers", {"url": url_dead, "model_id": "alpha"})
    check("[%s] dead-port worker accepted (it will never be healthy)" % tag2,
          st in (200, 202), str(st))
    # 等它被巡检判死（interval=1 s），否则第一次请求可能连"健康"都没被否定过
    deadline = time.time() + 20
    while time.time() < deadline:
        row = (workers_by_url(port2).get(url_dead) or {})
        if row and not row.get("is_healthy"):
            break
        time.sleep(0.4)
    st, raw, hdrs = chat_sync(port2, "alpha", "nothing healthy at all", timeout=30)
    st_v, code, message = err_parts(st, raw, hdrs)
    check("[%s] unhealthy 503 keeps the original wording and code" % tag2,
          st_v == 503 and code == "no_available_workers"
          and "cap" not in message and "GPU-util" not in message
          and "unhealthy" in message,
          "%s %s %s" % (st_v, code, message[:200]))
    check_no_abort(tag2, name2)
    stop_router(name2)


def scenario_declaration_bounds():
    """声明层三字段的边界组（2026-10-06 §1）过真 HTTP POST /_ui/config/upstreams。

    这四条此前只有 /data/tmp/lr_caps_store_probe.lua 那份一次性 luajit 探针覆盖，
    探针不进门禁 = 没有自动化。全部走声明层的整表替换（POST /_ui/config/upstreams，
    与 JSON 编辑器同一条 apply_upstreams 写入口），因为设计书钉的校验就挂在这两条
    入口（apply_profiles / apply_document）上：

      * min_concurrency >= max_concurrency → 400，且错误点名两个字段（"must be less
        than"）——绿灯阈与红格顶不许重叠或倒置；
      * max_gpu_util = 0 → 200 且**逐字段回显 0**（cap_limit 的 <=0 折叠会把它抹成
        缺席；util_limit 必须保住这一档）；GET /_ui/config 的 upstreams 行同样回显 0，
        投影进池行也是整数 0；
      * max_gpu_util = 101 → 400（它不可能是一个整数百分比）；
      * 旧行携带 max_power_w → 200（可读入、不 400），但该键被**丢弃**：文档回显、
        GET /_ui/config、GET /workers 都不许再有它，warn-once 日志点名 retired。

    判别性：写成"util=0 折成不限"的实现红在第 2 条（回显缺席而非 0）；不做 min<max
    校验的红在第 1 条（200 而非 400）；把 max_power_w 照旧接受/迁移的红在第 4 条
    （键还在文档里或池行里）。
    """
    tag = "S5d-decl-bounds"
    pa = free_port()
    start_mock(pa, "alpha")
    # SMG_WORKER_URLS must be written at container start, and the bridge gateway on
    # this file's default network is the fixed fallback (see the top of the file).
    port, name, gw = start_conf_container({"SMG_POLICY": "round_robin",
                                           "SMG_ENABLE_IGW": "0",
                                           "SMG_WORKER_URLS": "http://%s:%d"
                                               % (GATEWAY_FALLBACK, pa)}, tag)
    url_a = "http://%s:%d" % (gw, pa)
    if not check("[%s] worker seeded and healthy" % tag,
                 gw == GATEWAY_FALLBACK and wait_urls(port, [url_a]), logs(name)[:400]):
        stop_router(name)
        return

    def decl(entries):
        return post_upstreams(port, entries)

    # 1) min >= max 拒（两条拼写：相等与倒置）
    st, doc = decl([{"url": url_a, "model_id": "alpha",
                     "min_concurrency": 4, "max_concurrency": 4}])
    body = json.dumps(doc)[:300]
    check("[%s] min_concurrency == max_concurrency is refused 400" % tag,
          st == 400 and ("less than" in body or "min_concurrency" in body),
          "%s %s" % (st, body))
    st, doc = decl([{"url": url_a, "model_id": "alpha",
                     "min_concurrency": 9, "max_concurrency": 2}])
    check("[%s] min_concurrency > max_concurrency is refused 400" % tag, st == 400,
          "%s %s" % (st, json.dumps(doc)[:300]))

    # 2) util = 0 保留（极严档不是"没说"）
    st, doc = decl([{"url": url_a, "model_id": "alpha",
                     "min_concurrency": 1, "max_concurrency": 8,
                     "max_gpu_util": 0}])
    row = {}
    if isinstance(doc, dict):
        for u in (doc.get("upstreams") or []):
            if u.get("url") == url_a:
                row = u
    check("[%s] max_gpu_util=0 accepted and round-trips as 0, not absent" % tag,
          st == 200 and row.get("max_gpu_util") == 0
          and row.get("min_concurrency") == 1 and row.get("max_concurrency") == 8,
          "%s %s" % (st, json.dumps(row)[:250]))
    st, cfgtext, _ = http("GET", "http://127.0.0.1:%d/_ui/config" % port)
    try:
        cfgdoc = json.loads(cfgtext)
    except ValueError:
        cfgdoc = {}
    grows = {}
    for u in (cfgdoc.get("upstreams") or []):
        if u.get("url") == url_a:
            grows = u
    check("[%s] GET /_ui/config echoes the 0 gate verbatim (declared zero, not absent)" % tag,
          st == 200 and grows.get("max_gpu_util") == 0,
          "%s %s" % (st, json.dumps(grows)[:250]))
    deadline = time.time() + 25
    projected = False
    while time.time() < deadline:
        r2 = (workers_by_url(port).get(url_a) or {})
        if r2.get("max_gpu_util") == 0:
            projected = True
            break
        time.sleep(0.4)
    check("[%s] the 0 gate projects onto the pool row as an integer 0" % tag, projected,
          json.dumps(workers_by_url(port).get(url_a, {}))[:250])

    # 3) util = 101 拒
    st, doc = decl([{"url": url_a, "model_id": "alpha", "max_gpu_util": 101}])
    check("[%s] max_gpu_util=101 is refused 400" % tag, st == 400,
          "%s %s" % (st, json.dumps(doc)[:300]))

    # 4) 旧 max_power_w：读入不 400，键被 warn 丢弃、不迁移、不出现在任何回显里
    st, doc = decl([{"url": url_a, "model_id": "alpha",
                     "max_power_w": 250, "max_gpu_util": 60}])
    row4 = {}
    if isinstance(doc, dict):
        for u in (doc.get("upstreams") or []):
            if u.get("url") == url_a:
                row4 = u
    check("[%s] a legacy max_power_w row is accepted, not 400" % tag,
          st == 200, "%s %s" % (st, json.dumps(doc)[:250]))
    check("[%s] the retired key is dropped, not migrated (no phantom util number)" % tag,
          "max_power_w" not in row4 and row4.get("max_gpu_util") == 60,
          json.dumps(row4)[:250])
    st, cfgtext, _ = http("GET", "http://127.0.0.1:%d/_ui/config" % port)
    check("[%s] GET /_ui/config returns no max_power_w anywhere" % tag,
          st == 200 and "max_power_w" not in cfgtext,
          "%s %s" % (st, cfgtext[:150]))
    st, raw_w, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
    check("[%s] GET /workers stops echoing the retired cap" % tag,
          st == 200 and "max_power_w" not in raw_w,
          "%s %s" % (st, raw_w[:150]))
    txt = docker_logs_full(name)
    warned = "max_power_w" in txt and "retired" in txt
    deadline = time.time() + 10
    while not warned and time.time() < deadline:
        txt = docker_logs_full(name)
        warned = "max_power_w" in txt and "retired" in txt
        time.sleep(0.5)
    check("[%s] the retirement warns in the gateway log" % tag, warned, txt[-300:])

    check_no_abort(tag, name)
    stop_router(name)


def scenario_default_behaviour():
    """缺省配置（不设上限、不设 candidates）：老行为零变化。

    判别性：不设上限时三个容量字段（min_concurrency/max_concurrency/max_gpu_util）与
    退役的 max_power_w、以及 load_state 全部必须**缺席**（0 会被读成"零个槽位"、
    load_state 写成 null 会让无门行冒充一个网关拒绝命名的态）；round_robin 的 spread
    与改动前一致；smg_worker_capacity_excluded_total 与绿灯优先的
    smg_worker_capacity_preferred_idle_total 一个都不计（无门池里两条判据都不许花钱）。
    """
    tag = "S5c-default"
    pc, pd = free_port(), free_port()
    start_mock(pc, "alpha")
    start_mock(pd, "alpha")
    port3, name3, gw3 = start_conf_container({"SMG_POLICY": "round_robin"}, tag)
    url_c, url_d = "http://%s:%d" % (gw3, pc), "http://%s:%d" % (gw3, pd)
    st, _ = post_json(port3, "/workers", {"url": url_c, "model_id": "alpha"})
    st2, _ = post_json(port3, "/workers", {"url": url_d, "model_id": "alpha"})
    if not check("[%s] two uncapped workers healthy" % tag,
                 wait_urls(port3, [url_c, url_d]), logs(name3)[:400]):
        stop_router(name3)
        return
    rows3 = workers_by_url(port3)
    _ABSENT = ("max_concurrency", "min_concurrency", "max_gpu_util",
               "max_power_w", "load_state", "gpu_util")
    check("[%s] no cap declared means the fields are absent, not zero/null" % tag,
          all(all(k not in r for k in _ABSENT) for r in rows3.values()),
          json.dumps([sorted(r.keys()) for r in rows3.values()])[:400])
    base = {p: mock_lines(p, "/v1/chat/completions") for p in (pc, pd)}
    ok = True
    for i in range(8):
        st, raw, _ = chat_sync(port3, "alpha", "default behaviour probe %d" % i)
        ok = ok and st == 200
    hits_c = mock_lines(pc, "/v1/chat/completions") - base[pc]
    hits_d = mock_lines(pd, "/v1/chat/completions") - base[pd]
    check("[%s] round_robin still spreads 8 requests across both (%d/%d)"
          % (tag, hits_c, hits_d),
          ok and hits_c + hits_d == 8 and min(hits_c, hits_d) >= 1,
          "c=%d d=%d" % (hits_c, hits_d))
    excl = metric_value(port3, "smg_worker_capacity_excluded_total")
    check("[%s] nothing counted as capacity-excluded in a cap-free pool" % tag,
          excl in (None, 0), str(excl))
    # :1651 的无门零计数扩展到绿灯优先那一族：无门 = 三 cap 全 nil = capacity_state
    # 恒 nil = 裁剪根本不该发生，preferred_idle 计数也不许动（那是给"发生过让位"用的）。
    pref = metric_value(port3, "smg_worker_capacity_preferred_idle_total")
    check("[%s] nothing counted as preferred-idle in a cap-free pool" % tag,
          pref in (None, 0), str(pref))
    check_no_abort(tag, name3)
    stop_router(name3)


def main():
    scenario_bindings(1)
    scenario_bindings(0)
    scenario_candidates_intersect_workers()
    scenario_config_rename_model_gate(1)
    scenario_config_rename_model_gate(0)
    scenario_concurrency()
    scenario_power()
    scenario_power_switch_off()
    scenario_power_per_card()
    scenario_caps_persistence()
    scenario_affinity_vs_cap()
    scenario_all_capped_503()
    scenario_declaration_bounds()
    scenario_default_behaviour()
    failed = [r for r in RESULTS if not r[0]]
    print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
    for _, name, detail in failed:
        print("FAILED: %s | %s" % (name, detail[:400]))
    cleanup()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
