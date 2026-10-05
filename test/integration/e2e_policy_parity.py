#!/usr/bin/env python3
"""量化行为对拍门禁：prefix_hash / bucket / power_of_two / random（Lua vs Rust）。

本文件是 policy-extra 对拍轮的仓库化版本（结论文档 doc/parity-policy-extra.md，
原始数据 /data/tmp/parity/policy-extra/）。三条口径必须先讲清楚：

  1. 对拍的是**不变量**，不是逐次落点。两边哈希不同（Lua = blake3 over 前 N 个
     字符，Rust = xxh3 over 前 N 个 token），bucket / power_of_two 的内部状态也
     各自独立演化，所以断言只取三类：同输入是否粘滞、前缀截断与长度分桶的边界
     是否成立、以及均匀性/偏斜检查。**均匀性判据是 TOST 等价性检验，χ² 已降级为报告项**
     （依据与标定见 tost_uniform 的注释：E[χ²]=df 与 N 无关，α=0.05 等于每轮门禁自带约 5% 红概率）。
  2. Rust 侧两个策略入口的可用性是**实测的权威结论**，这里固化成断言；上游一旦
     把入口修好，这几条会失败，那正是「需要重开对拍」的信号：
       - prefix_hash：CLI 接受 --policy prefix_hash，但 HTTP 面 tokens 恒为 None
         （gateway/src/routers/http/router.rs:176），策略返回 None 被调用方映射成
         503 no_available_workers（不是 501）；PD 面同样失败（pd_router.rs:1092）。
       - bucket：CLI 拒绝 --policy / --prefill-policy bucket；labels.policy hint 能
         装上 BucketPolicy，但桶表只由 init_pd_bucket_policies 填充，regular worker
         上恒 miss，bucket.rs:285 退化成均匀随机。
     所以这两个策略只对 Lua 侧断言算法，对 Rust 侧断言「入口不可用 / 退化」本身。
  3. power_of_two 是本轮唯一的**真背离**：Rust 的负载来自 LoadMonitor 轮询
     GET {worker}/v1/loads?include=core 的 aggregate.total_tokens，取不到时按 -1
     缓存，于是 load1 <= load2 恒成立、选择坍缩成「第一个随机候选」（等价 random）；
     Lua 用 registry 自己的 in-flight 计数，仍然避开慢 worker。两种情形分别断言。

观察通道是 mock 写进响应体的 wid，不依赖 router 日志；两侧再各读一次
smg_worker_selection_total{policy=...} 计数器，证明流量确实走在被命名的策略上。

Rust 镜像不存在时（离线构建机）Rust 断言整体跳过，Lua 不变量照常执行。
端口全部随机，不触碰生产 8800/29000。

Usage:
  python3 test/integration/e2e_policy_parity.py
Env knobs:
  LR_RUST_IMAGE=ghcr.io/yorkane/llm-router:latest   固定本地 tag，不做 pull
  LR_PP_N=10000            random 每侧样本数（下限 10000）
  LR_PP_CONC=16            closed-loop 并发
  LR_PP_POT_N=1200         power_of_two closed-loop 样本数（两类判据共用；假红率按这个
                           N 标定，调小等于换判据）
  LR_PP_WARMUP=40          正式计数前烧掉的冷启动请求数
  LR_PP_TOST_D=0.065       TOST 等价边界（每桶份额相对 1/3 的容许偏差，不含抽样噪声项）
  LR_PP_TH_AVOID_LUA=0.25  「仍避开慢 worker」的慢份额上限（Lua 有/无 loads 两条）
  LR_PP_TH_AVOID_RUST=0.28 「仍避开慢 worker」的慢份额上限（Rust 有 loads）
  LR_PP_TOST_D_RANDOM=0.008 random 轮的 TOST 等价边界（N=10000/侧，口径见 round_random）
  LR_PP_SLOW_MS=120        慢 worker 的时延
"""
import json, math, os, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from statistics import NormalDist

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (free_port, http, check, start_router, logs, stop_router, wait_ready,
                  cleanup, RESULTS, RUN)

RUST_IMAGE = os.environ.get("LR_RUST_IMAGE", "ghcr.io/yorkane/llm-router:latest")
N_RANDOM = max(10000, int(os.environ.get("LR_PP_N", 10000)))
CONC = int(os.environ.get("LR_PP_CONC", 16))
POT_N = int(os.environ.get("LR_PP_POT_N", 1200))
POT_WARMUP = int(os.environ.get("LR_PP_WARMUP", 40))
TOST_D = float(os.environ.get("LR_PP_TOST_D", 0.065))
TH_AVOID_LUA = float(os.environ.get("LR_PP_TH_AVOID_LUA", 0.25))
TH_AVOID_RUST_WITH = float(os.environ.get("LR_PP_TH_AVOID_RUST", 0.28))
SLOW_MS = float(os.environ.get("LR_PP_SLOW_MS", 120))
PREFIX_CHARS = 32
CHI2_P005, CHI2_P001 = 5.991, 9.210          # df = 2 (3 workers)；降为报告项，见 tost_uniform
P0_UNIFORM = 1.0 / 3.0                       # 3 workers 时的均匀份额
# TOST 由 6 个单侧检验拼成（3 桶 × 两侧边界），Bonferroni 后每侧 α = 0.05/6。
TOST_Z = NormalDist().inv_cdf(1.0 - 0.05 / 6.0)
TOST_D_RANDOM = float(os.environ.get("LR_PP_TOST_D_RANDOM", 0.008))  # random 轮，见 round_random
L_MAX = 4096                                  # Rust bucket.rs l_max
OUT_DIR = os.environ.get("LR_POLICY_EXTRA_OUT", "/data/tmp/parity/policy-extra")
REPORT = {}
RUST_CONTAINERS = []
MOCKS = []


# ---------------------------------------------------------------- statistics
def chi2(counts):
    n = float(sum(counts))
    if n == 0:
        return 0.0
    exp = n / len(counts)
    return sum((c - exp) ** 2 / exp for c in counts)


def tost_uniform(counts, d=None, n_total=None):
    """等价性检验（TOST）：断言每一桶份额与 1/3 的偏差都 <= tol。返回 (green, max_dev, tol)。

    为什么把 chi2 从**判据**降成**报告项**（这段是本次修改的全部依据，下一个人动这里之前先读完）：

    chi2 拟合优度检验的期望 E[chi2] = df = k-1 = 2，**公式里根本没有 N**，于是
        P(chi2 > 5.991 | 真均匀) = exp(-5.991/2) = 0.05001      <- 与样本量无关的常数
    标定实测（/data/tmp/chi2_power/，每格 15 万~40 万次抽样）：N=240/480/1200/2400/4800
    分别红 5.09%/4.95%/5.07%/5.05%/5.06%。所以「偶发红」既不是抖动也不是回归，
    **加大 N 一分不减**；它是 alpha=0.05 这个 tail cut 自身的性质——等于
    **每轮全量门禁自带约 5% 的红概率预算**，同一文件里多条 chi2 判据还各自独立再抽一次。
    门禁天天跑，这份预算迟早必中（本轮 3 次实测 chi2 = 0.475/4.825/6.400 就在这条尾部上跳）。

    方向也错了：「chi2 没超临界值」只等于**没能拒绝均匀**，样本不足时同样绿，属无证据即无罪。
    TOST 把假设反过来，绿的含义是**证明了与均匀不可区分**；其假红率 = P(任一台份额跳出 tol)，
    tol 的噪声项 Z*sd ~ 1/sqrt(N) 随 N 变窄，所以 N=1200 / d=0.065 下真均匀红率 3.0e-12
    （原判据 5%），检测力一侧也不损：真不再退化（慢份额 0.11）时 TOST 误判绿的概率 4.2e-35。

    **唯一真软肋是过散**。以上全部建立在 iid 抽样模型上：closed-loop 流量的逐轮状态
    （in-flight 计数、节流窗口、LoadMonitor 刷新时机）会在轮间漂移，形态等价于
    beta-binomial 的 rho。模拟给出 rho=0.001 时红率 4.7e-05、rho=0.01 时 0.17、rho=0.02 时 0.41，
    而**真实 rho 从未实测过**（标定全是抽样模型，没有真跑 router）。所以这条上线后若仍红，
    **优先怀疑环节流漂移而不是样本量；加 N 只会更糟**（N 越大 tol 越贴住真值、漂移越容易
    被判红），对策是放宽 d（LR_PP_TOST_D）。chi2 与 TOST 两个数每条都一起打印，
    结论矛盾时如实标出并一律按 TOST 定性，不挑好看的报。

    真实 rho 的实测证据（2026-10-04，**真跑了 router**：5 轮完整 e2e_policy_parity，
    N=1200、40 warmup，数据 /data/tmp/chi2_power_mine/reps/run*/）：把每个断言点的
    慢桶份额跨 5 轮的标准差和 iid 二项标准差做矩估计（beta-binomial），得
      rust no-loads（**本条判据所在点**） shares 0.3208~0.3517，sd=0.0123 vs iid 0.0136 → rho_hat≈0
      rust with-loads  sd 0.0146 vs 0.0108 → rho_hat≈0.0007
      Lua  with-loads  sd 0.0154 vs 0.0095 → rho_hat≈0.0014
      Lua  no-loads    sd 0.0175 vs 0.0095 → rho_hat≈0.0020
    也就是说**没有证据显示被门禁的这一点存在过散**（点估计贴 0，甚至略低于 iid）；
    真正有点过散迹象的是 Lua 那两点（rho≈0.002），而那两点跑的是 skew 判据（要求 dev **大于**
    tol），过散只会让它更不容易红，方向安全。5 轮实测 dev = 0.0067~0.0183，
    tol=0.0976，**最差的一轮也还在边界内 5.3 倍**；同点 iid 红率 3.3e-06。
    样本仍偏少（5 轮估 rho 的置信区间很宽），所以判断仍然只是「暂无风险信号」：
    REPORT["power_of_two"] 每轮都落 counts，攒够 30 轮重估；若 rho 逼近 0.008，
    对策是把 d 放宽到 0.080（rho=0.008 时红率从 6.8e-02 降到 2.8e-02），**不是**动 N
    """
    vals = list(counts.values()) if isinstance(counts, dict) else list(counts)
    n = float(sum(vals)) if n_total is None else float(n_total)
    if n == 0:
        return False, 1.0, 0.0
    d = TOST_D if d is None else float(d)
    tol = d + TOST_Z * math.sqrt(P0_UNIFORM * (1.0 - P0_UNIFORM) / n)
    dev = max(abs(c / n - P0_UNIFORM) for c in vals)
    return dev <= tol, dev, tol


def avoid_gate(counts, slow, th):
    """「仍避开慢 worker」判据：慢桶份额 <= th。返回 (green, share)。

    theta 与 N 一起标定（同一份 /data/tmp/chi2_power/ 口径，N=1200，按 40 请求 warmup
    burn 掉后的 depleted 分布算，比 iid 保守）：真随机（p=1/3）时误判绿的概率
    theta=0.25 -> 8.5e-10、0.26 -> 6.4e-08、0.27 -> 2.8e-06、0.28 -> 6.9e-05、0.30 -> 9.2e-03。
    两个方向的错误要显式权衡：**放过真退化的代价是生产事故，偶发红的代价是门禁天天误报**。
    裁定取**更怕偶发红**（门禁天天跑），所以宁可让 theta 留余量：Rust 有 loads 的实测慢份额
    区间 0.000~0.225（doc/parity-policy-extra.md 3.1 节），theta=0.27 时按 p=0.225 算偶发红
    1.7e-04、放过真退化 2.8e-06；theta=0.28 时偶发红 6.7e-06、放过 6.9e-05。取 **theta=0.28**：
    偶发红压到 1e-05 量级（约 15 万轮一遇），放过概率仍在 1e-04 以下。
    旧判据 N=240 / theta=0.30 的放过率是 **0.187（约 1/5）**，那条基本等于没检。
    Lua 侧实测份额 0.096~0.108，离 0.25 有 0.14 余量，theta=0.25 的 8.5e-10 已足够低，
    不必再收紧；数值不变，只是 N 从 240 提到 1200，放过真退化从 3.2e-03 降到 8.5e-10。
    """
    vals = list(counts.values()) if isinstance(counts, dict) else list(counts)
    n = float(sum(vals))
    sh = counts[slow] / n if n else 0.0
    return sh <= th, sh


def stat_line(tag, counts, chi2_value, tost_green, dev, tol, extra="", d=None):
    """每次都把 chi2 与 TOST 两个数摊开：让人看得出结论靠哪一侧支撑。"""
    chi2_green = chi2_value < CHI2_P005
    v = lambda g: ("绿" if g else "红")
    vals = list(counts.values()) if isinstance(counts, dict) else list(counts)
    msg = ("STAT   %-28s N=%-5d chi2=%7.3f(crit %.3f -> %s)  "
           "TOST max|share-1/3|=%.4f tol=%.4f (d=%.3f -> %s)"
           % (tag, sum(vals), chi2_value, CHI2_P005, v(chi2_green), dev, tol,
              TOST_D if d is None else float(d), v(tost_green)))
    if chi2_green != tost_green:
        msg += "  [两判据结论相反：按 TOST 定性，chi2 一侧只表示没能拒绝均匀]"
    if extra:
        msg += "  " + extra
    print(msg)
    return chi2_green


def stat_selftest():
    """判别性自测：真退化必须判红。只验「均匀时不红」是半个测试。

    纯算术、不联网、不占端口，所以在 main() 开头无条件跑；只在**判错方向**时计入 check，
    正常轮次一条都不加。
    """
    uni = [400, 400, 400]                 # 真均匀（= 退化成立）
    deg = [132, 534, 534]                 # 真不再退化：慢份额 0.11
    obs = [320, 400, 480]                 # 实测到过的最差真实行为：慢份额 0.267
    near = [335, 432, 433]                # 0.2792，贴在 theta=0.28 内侧
    bad = []
    g, dev, tol = tost_uniform(uni)
    if not g:
        bad.append("真均匀被判红：dev=%.4f tol=%.4f" % (dev, tol))
    g, dev, tol = tost_uniform(deg)
    if g:
        bad.append("真退化（慢份额 0.11）被 TOST 放过：dev=%.4f tol=%.4f" % (dev, tol))
    g, dev, tol = tost_uniform(obs)
    if not g:
        bad.append("实测最差真实行为 0.267 被 d=%.3f 判红：等价边界过紧 dev=%.4f tol=%.4f"
                   % (TOST_D, dev, tol))
    g, sh = avoid_gate(deg, 0, TH_AVOID_LUA)
    if not g:
        bad.append("真避开（0.11）没过 avoid 判据：share=%.4f" % sh)
    g, sh = avoid_gate(uni, 0, TH_AVOID_LUA)
    if g:
        bad.append("真随机（份额 1/3）被误判成避开：share=%.4f" % sh)
    g, sh = avoid_gate(near, 0, TH_AVOID_RUST_WITH)
    if not g:
        bad.append("0.279 应过 theta=0.28：share=%.4f" % sh)
    print("STAT   %-28s 判别性自测（真均匀绿 / 真退化红 / 最差观测 0.267 绿）: %s"
          % ("stat_selftest", "PASS" if not bad else "FAILED"))
    for b in bad:
        check("[power_of_two/stat-selftest] 判据方向正确", False, b)
    return not bad


def counts_of(wids, order):
    d = {w: 0 for w in order}
    for w in wids:
        if w in d:
            d[w] += 1
    return d


def share(d, key):
    total = float(sum(d.values()))
    return d[key] / total if total else 0.0


def selection_counter(text, model, policy):
    for line in text.splitlines():
        if (line.startswith("smg_worker_selection_total{") and 'model="%s"' % model in line
                and 'policy="%s"' % policy in line):
            return float(line.rsplit(" ", 1)[1])
    return None


def branch_counters(text, family):
    out = {}
    for line in text.splitlines():
        if line.startswith(family + "{") and 'branch="' in line:
            key = line.split('branch="')[1].split('"')[0]
            out[key] = out.get(key, 0.0) + float(line.rsplit(" ", 1)[1])
    return out


def docker_logs(name):
    r = subprocess.run(["docker", "logs", name], capture_output=True)
    return (r.stderr.decode() + r.stdout.decode())


# ------------------------------------------------------------ policy mock
# 独立的对拍 mock（不用 test/mock_llm_worker.py）：那个 mock 把状态放在模块级
# STATE，同一进程里起多个实例会互相覆盖 latency/model，而这里必须让三个 worker
# 拥有各自的时延。本 mock 每条响应带上 wid，并可选择性提供 SGLang 风格的
# GET /v1/loads?include=core（Rust LoadMonitor / power_of_two 的唯一负载来源）。
class PolicyMock:
    def __init__(self, port, model, wid, latency_ms=0.0, loads_on=True, tokens_per_req=64):
        self.model, self.wid = model, wid
        self.latency_ms, self.loads_on, self.tokens_per_req = latency_ms, loads_on, tokens_per_req
        self.inflight = 0
        self.lock = threading.Lock()
        outer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def _send(self, status, payload):
                body = payload.encode() if isinstance(payload, str) else json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(body)

            def do_GET(self):
                path = self.path.split("?", 1)[0]
                if path in ("/health", "/health_generate"):
                    self._text(200, "OK")
                elif path == "/v1/models":
                    self._send(200, {"object": "list", "data": [
                        {"id": outer.model, "object": "model", "created": int(time.time()),
                         "owned_by": "local"}]})
                elif path == "/v1/loads":
                    if not outer.loads_on:
                        self._send(404, {"error": {"message": "mock: loads disabled"}})
                        return
                    with outer.lock:
                        n = outer.inflight
                    self._send(200, {"aggregate": {"total_tokens": n * outer.tokens_per_req,
                                                  "num_running_requests": n}, "version": 1})
                else:
                    self._send(404, {"error": {"message": "mock: no route %s" % path}})

            def _text(self, status, t):
                self.send_response(status)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(t)))
                self.end_headers()
                self.wfile.write(t.encode())

            def do_POST(self):
                raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                try:
                    body = json.loads(raw.decode()) if raw else {}
                except Exception:
                    body = {}
                path = self.path.split("?", 1)[0]
                if path != "/v1/chat/completions":
                    self._send(404, {"error": {"message": "mock: no route %s" % path}})
                    return
                with outer.lock:
                    outer.inflight += 1
                try:
                    if outer.latency_ms > 0:
                        time.sleep(outer.latency_ms / 1000.0)
                finally:
                    with outer.lock:
                        outer.inflight -= 1
                content = body.get("messages", [{}])[0].get("content", "") if body.get("messages") else ""
                self._send(200, {
                    "id": "chatcmpl-" + os.urandom(12).hex(), "object": "chat.completion",
                    "created": int(time.time()), "model": body.get("model") or outer.model,
                    "wid": outer.wid,
                    "choices": [{"index": 0, "message": {"role": "assistant",
                                 "content": "echo[%s]" % outer.wid}, "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": max(1, len(content) // 4),
                              "completion_tokens": 5, "total_tokens": 6}})

        self.server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        MOCKS.append(self)


def make_pool(specs):
    """specs: [(model, wid, latency_ms, loads_on)] -> (ports, order, model)."""
    ports, order = {}, []
    model = specs[0][0]
    for m, wid, latency, loads_on in specs:
        p = free_port()
        PolicyMock(p, m, wid, latency_ms=latency, loads_on=loads_on)
        for _ in range(80):
            if http("GET", "http://127.0.0.1:%d/health" % p, timeout=2)[0] == 200:
                break
            time.sleep(0.1)
        ports[wid] = p
        order.append(wid)
    return ports, order, model


def url_list(ports, order):
    return ",".join("http://127.0.0.1:%d" % ports[w] for w in order)


# ---------------------------------------------------------------- sampling
def wid_of(status, body):
    if status != 200:
        return None
    try:
        return json.loads(body).get("wid")
    except Exception:
        return None


def sample(base, model, make_text, n, concurrency=CONC):
    """Closed-loop traffic -> observed wid list (None entries mean non-200)."""
    out, lock, idx = [], threading.Lock(), [0]

    def one():
        while True:
            with lock:
                i = idx[0]
                if i >= n:
                    return
                idx[0] += 1
            st, body, _ = http("POST", base + "/v1/chat/completions",
                               {"model": model,
                                "messages": [{"role": "user", "content": make_text(i)}]})
            w = wid_of(st, body)
            with lock:
                out.append(w)

    ts = [threading.Thread(target=one, daemon=True) for _ in range(max(1, concurrency))]
    [t.start() for t in ts]
    [t.join() for t in ts]
    return out


def serial_map(base, model, texts):
    return [probe(base, model, t)[0] for t in texts]


def probe(base, model, text):
    st, body, _ = http("POST", base + "/v1/chat/completions",
                       {"model": model, "messages": [{"role": "user", "content": text}]})
    return wid_of(st, body), st, body


def lua_workers(port):
    st, body, _ = http("GET", "http://127.0.0.1:%d/workers" % port)
    try:
        return json.loads(body).get("workers", [])
    except Exception:
        return []


def lua_healthy(port, ports_by_wid, want, timeout=60):
    """Poll until `want` of the given ports report is_healthy (Rust needs 2
    consecutive successes, so a fixed sleep is flaky)."""
    targets = {str(p) for p in ports_by_wid.values()}
    deadline = time.time() + timeout
    while time.time() < deadline:
        seen = {w["url"].rsplit(":", 1)[1] for w in lua_workers(port) if w.get("is_healthy")}
        if len(seen & targets) >= want:
            return True
        time.sleep(0.4)
    return False


def delete_lua_worker(port, wid_port):
    for w in lua_workers(port):
        if w["url"].endswith(":%d" % wid_port):
            return http("DELETE", "http://127.0.0.1:%d/workers/%s" % (port, w["id"]))
    return None, "", ""


# ============================================================== 1. prefix_hash
def round_prefix_hash(have_rust):
    ports, order, model = make_pool([("mpd", "pdA", 0, True), ("mpd", "pdB", 0, True),
                                     ("mpd", "pdC", 0, True)])
    name = "lr-pph-" + RUN
    lua = start_router({"SMG_POLICY": "prefix_hash", "SMG_PREFIX_TOKEN_COUNT": str(PREFIX_CHARS),
                        "SMG_HEALTH_CHECK_INTERVAL_SECS": "1", "SMG_EVICTION_INTERVAL_SECS": "30",
                        "SMG_WORKER_URLS": url_list(ports, order)}, name)
    base = "http://127.0.0.1:%d" % lua
    tag = "prefix_hash/Lua"
    ok = check("[%s] 3 workers healthy" % tag, lua_healthy(lua, ports, 3), logs(name)[:300])
    if not ok:
        stop_router(name)
        return

    pfx = "A" * PREFIX_CHARS
    sticky = serial_map(base, model, [pfx + " repetition %d common tail" % i for i in range(10)])
    check("[%s] 同前缀 10 次粘滞在同一 worker" % tag, len(set(sticky)) == 1 and sticky[0],
          json.dumps(sticky))
    trunc = serial_map(base, model, [pfx + " " + ("x" * (i + 3)) + " tail %d" % i for i in range(6)])
    check("[%s] 前缀截断成立：只取前 %d 字符，尾部不同不改落点" % (tag, PREFIX_CHARS),
          len(set(sticky + trunc)) == 1, json.dumps(trunc))

    dist300 = counts_of(sample(base, model, lambda i: "prefix-%06d-common-body" % i, 300), order)
    c300 = chi2(list(dist300.values()))
    tot300 = float(sum(dist300.values()))
    shares = {w: v / tot300 for w, v in dist300.items()}
    # 环落点由 blake3 决定，300 个 key 在 3 个 worker 上的份额会明显抖动（实测跨轮
    # χ² 从 0.14 到 7.62），所以这里只断言「不塌缩」：三桶都有份额且没有一桶吃掉一半以上。
    check("[%s] 300 个不同前缀不塌缩（每桶份额 %.3f~%.3f，χ²=%.3f）"
          % (tag, min(shares.values()), max(shares.values()), c300),
          all(0.15 < v < 0.60 for v in shares.values()),
          "%s chi2=%.3f" % (dist300, c300))

    keys = ["collide-%03d" % i for i in range(48)]
    place = lambda: {k: probe(base, model, k + "-body-of-request")[0] for k in keys}
    before = place()
    drop = order[-1]
    st_del, _, _ = delete_lua_worker(lua, ports[drop])
    time.sleep(1.5)
    after = place()
    moved = [k for k in keys if before[k] != after[k]]
    collateral = [k for k in moved if before[k] != drop]
    ratio = len(moved) / float(len(keys))
    check("[%s] DELETE worker 返回 2xx" % tag, st_del in (200, 202, 204), st_del)
    check("[%s] 摘除后 collateral 为 0：只有原本落在被摘 worker 上的 key 迁移" % tag,
          len(moved) > 0 and len(collateral) == 0,
          "moved=%d collateral=%d" % (len(moved), len(collateral)))
    check("[%s] 重分布比例 ~= 1/n（%.3f，期望 0.333±0.25）" % (tag, ratio),
          abs(ratio - 1.0 / len(order)) < 0.25, "ratio=%.3f" % ratio)

    st_re, _, _ = http("POST", base + "/workers",
                       {"url": "http://127.0.0.1:%d" % ports[drop], "model_id": model})
    back_healthy = lua_healthy(lua, ports, 3, timeout=90)
    after_readd = place()
    returned = sum(1 for k in keys if after_readd[k] == before[k])
    check("[%s] 恢复 worker 后 key 全部回落到原落点（环可重建，%d/%d）" % (tag, returned, len(keys)),
          returned == len(keys), "%d/%d returned (re-add %s, healthy %s)"
          % (returned, len(keys), st_re, back_healthy))

    st_e, body_e, _ = http("POST", base + "/v1/chat/completions",
                           {"model": model, "messages": [{"role": "user", "content": ""}]})
    check("[%s] 空文本走 NoTokens -> 503 no_available_workers（与 Rust 分支语义一致）" % tag,
          st_e == 503 and "no_available_workers" in body_e, "%s %s" % (st_e, body_e[:150]))

    cnt = selection_counter(http("GET", base + "/metrics")[1], model, "prefix_hash")
    check("[%s] worker_selection_total{policy=prefix_hash} 计数 > 0" % tag, (cnt or 0) > 0,
          "counter=%s" % cnt)

    REPORT["prefix_hash"] = {"lua": {"sticky_worker": sticky[0] if sticky else None,
                                    "distribution_300": dist300, "chi2_300": round(c300, 3),
                                    "churn_keys": len(keys), "churn_moved": len(moved),
                                    "churn_collateral": len(collateral),
                                    "redistribution_ratio": round(ratio, 4),
                                    "readd_returned": "%d/%d" % (returned, len(keys)),
                                    "empty_text_status": st_e, "selection_counter": cnt}}

    if have_rust:
        rname = "lr-pph-r" + RUN[-4:]
        try:
            r = RustRouter(rname, "prefix_hash", ports, order, model)
        except Exception as exc:
            check("[prefix_hash/Rust] 实例可启动", False, repr(exc)[:300])
            REPORT["prefix_hash"]["rust"] = "failed to start: %s" % repr(exc)[:200]
            stop_router(name)
            return
        ok = check("[prefix_hash/Rust] 实例可启动且 3 workers healthy", r.healthy(), logs(rname)[:300])
        probes = [http("POST", r.base + "/v1/chat/completions",
                       {"model": model, "messages": [{"role": "user", "content": pfx + " tail %d" % i}]})
                  for i in range(3)] if ok else []
        codes = sorted({p[0] for p in probes})
        br = branch_counters(r.metrics(), "smg_prefix_hash_policy_branch_total")
        check("[prefix_hash/Rust] HTTP 面恒 503 no_available_workers（tokens 硬编码 None，不是 501）",
              codes == [503] and probes and "no_available_workers" in probes[0][1],
              "%s %s" % (codes, probes[0][1][:180] if probes else "no probes"))
        check("[prefix_hash/Rust] 分支计数只有 no_tokens", br.get("no_tokens", 0) >= 3, json.dumps(br))
        REPORT["prefix_hash"]["rust"] = {"status_codes": codes, "branch_counters": br,
                                        "verdict": "unusable over HTTP: tokens None at router.rs:176"}
        r.stop()
    stop_router(name)


# ================================================================== 2. bucket
def round_bucket(have_rust):
    ports, order, model = make_pool([("mrb", "rbA", 0, True), ("mrb", "rbB", 0, True),
                                     ("mrb", "rbC", 0, True)])
    gap = L_MAX // len(order)
    # 冻结边界：abs 阈值不可达（不走失衡分支）+ adjust/eviction 极长（不重切）
    name = "lr-pbk-" + RUN
    lua = start_router({"SMG_POLICY": "bucket", "SMG_BALANCE_ABS_THRESHOLD": "100000000",
                        "SMG_BUCKET_ADJUST_INTERVAL_SECS": "3600",
                        "SMG_EVICTION_INTERVAL_SECS": "3600",
                        "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                        "SMG_WORKER_URLS": url_list(ports, order)}, name)
    base = "http://127.0.0.1:%d" % lua
    tag = "bucket/Lua"
    ok = check("[%s] 3 workers healthy" % tag, lua_healthy(lua, ports, 3), logs(name)[:300])
    if not ok:
        stop_router(name)
        return

    lens = (1, 100, gap - 1, gap, 2 * gap - 1, 2 * gap, 4095, 4096, 6000, 9000)
    seg = {}
    for L in lens:
        ws = set(sample(base, model, lambda i, L=L: "a" * L, 3, 1))
        seg[L] = sorted(ws)
    single = all(len(v) == 1 for v in seg.values())
    tgt = {L: (seg[L][0] if single else None) for L in lens}
    check("[%s] 每个字符长度都是单点落位（长度唯一决定 worker）" % tag, single,
          json.dumps({str(k): v for k, v in seg.items()}))
    groups = {tgt[1], tgt[gap], tgt[2 * gap]}
    check("[%s] 边界 = floor(4096/%d) = %d：三段区间各属不同 worker" % (tag, len(order), gap),
          len(groups) == 3 and tgt[1] == tgt[100] == tgt[gap - 1]
          and tgt[gap] == tgt[2 * gap - 1] and tgt[2 * gap] == tgt[6000] == tgt[9000]
          and len({tgt[1], tgt[gap], tgt[2 * gap]}) == 3,
          json.dumps({str(k): v for k, v in tgt.items()}))
    check("[%s] 4096 不是分桶边界（l_max=%d 被 %d 个 worker 均分，边界在 %d/%d）"
          % (tag, L_MAX, len(order), gap - 1, gap),
          tgt[4095] == tgt[4096] == tgt[2 * gap], json.dumps({str(k): v for k, v in tgt.items()}))

    same = {L: len(set(sample(base, model, lambda i: "b" * L, 8, 1))) == 1 for L in (300, 1500, 3000)}
    check("[%s] 同字符长度请求 8/8 落同一 worker" % tag, all(same.values()), json.dumps(same))

    # 失衡分支：abs / rel 用 Rust CLI 默认（64 / 1.5），窗口拉长到 3600s
    # （窗口长度 = bucket_adjust_interval_secs * 1000）使「谁最小」不随衰减抖动。
    # 必须同时把进程数钉成 1：chars_per_url 是 per-process 表（历史偏差 1；docker-entrypoint.sh 只为 cache_aware/mesh 自动降 1），多进程下每个
    # 进程各自计数，abs_diff 越不过 64，逃逸分支根本不会触发 —— 上面那条
    # 200/200 全落桶目标的对照组就是这件事的量化证据。
    name0 = "lr-pbk0-" + RUN
    lua0 = start_router({"SMG_POLICY": "bucket", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                         "SMG_BUCKET_ADJUST_INTERVAL_SECS": "3600", "NGINX_WORKER_PROCESSES": "1",
                         "SMG_WORKER_URLS": url_list(ports, order)}, name0)
    base0 = "http://127.0.0.1:%d" % lua0
    ok0 = check("[bucket/Lua 默认阈值] 3 workers healthy", lua_healthy(lua0, ports, 3),
                logs(name0)[:200])
    skew_wids = sample(base0, model, lambda i: "s" * 900, 200, 1) if ok0 else []
    skew = counts_of(skew_wids, order)
    # 窗口不衰减时逃逸序列是确定性的（实测周期 7：本桶 3 次、另两桶各 2 次），
    # 也就是「越界就改选当时 chars 最小者」这条分支真的在生效。
    total_skew = sum(skew.values()) if skew else 0
    hi, lo = (max(skew.values()), min(skew.values())) if skew else (0, 0)
    check("[bucket/Lua 默认阈值] 200 个同属一桶的请求被 is_imbalanced 摊开："
          "每个 worker >= 40 且最大桶 <= 110（abs=64/rel=1.5，单进程）",
          total_skew == 200 and lo >= 40 and hi <= 110, json.dumps(skew))
    check("[bucket/Lua 默认阈值] 改选目标是当时的 chars 最小者 -> 周期内近似均摊"
          "（max/min=%.2f <= 2.0）" % (hi / float(lo) if lo else 99),
          lo > 0 and hi <= 2.0 * lo, "%s" % json.dumps(skew))

    # 对照组：同一批请求打在阈值不可达的冻结实例上，必须 200/200 全落桶目标。
    frozen_skew = counts_of(sample(base, model, lambda i: "s" * 900, 60, 1), order)
    check("[bucket/Lua] 对照：阈值不可达时同桶请求 60/60 全落桶目标（逃逸未触发）",
          max(frozen_skew.values()) == 60, json.dumps(frozen_skew))

    cnt = selection_counter(http("GET", base + "/metrics")[1], model, "bucket")
    check("[%s] worker_selection_total{policy=bucket} 计数 > 0" % tag, (cnt or 0) > 0,
          "counter=%s" % cnt)
    REPORT["bucket"] = {"lua": {"l_max": L_MAX, "gap": gap, "step_target": {str(k): v for k, v in tgt.items()},
                                "same_length_sticky": same,
                                "imbalance_counts_default_thresholds": skew,
                                "frozen_control_60": frozen_skew,
                                "selection_counter": cnt},
                        "note": "chars_per_url 是 per-process 表：NGINX_WORKER_PROCESSES>1 时"
                                "abs_diff 被进程数摊薄，is_imbalanced 不触发（量化见"
                                "doc/parity-policy-extra.md）。"}

    if have_rust:
        rej, why = rust_cli_rejects("bucket")
        check("[bucket/Rust] CLI 拒绝 --policy bucket（HTTP 面无入口）", rej, why[:250])
        rname = "lr-pbk-r" + RUN[-4:]
        r = RustRouter(rname, "round_robin", ports, order, model, labels_policy="bucket")
        check("[bucket/Rust] hint 实例可启动且 3 workers healthy", r.healthy(), "counters below")
        d = counts_of(sample(r.base, model, lambda i: "c" * 500, 200), order)
        hint_cnt = selection_counter(r.metrics(), model, "bucket")
        log_txt = docker_logs(rname)
        no_bucket = log_txt.count("No bucket found for model")
        check("[bucket/Rust] labels.policy hint 确实装上 BucketPolicy（policy=bucket 计数增长）",
              (hint_cnt or 0) >= 200, "counter=%s" % hint_cnt)
        check("[bucket/Rust] 桶表未填充 -> 退化为均匀随机（三桶都有 + 日志 No bucket found）",
              all(v > 0 for v in d.values()) and no_bucket > 0,
              "%s loghits=%d" % (d, no_bucket))
        REPORT["bucket"]["rust"] = {"cli_rejects_policy": rej, "hint_selection_counter": hint_cnt,
                                   "distribution_200": d, "no_bucket_found_log_lines": no_bucket,
                                   "verdict": "no CLI entry point; hint installs the policy but "
                                              "buckets stay empty -> uniform random fallback"}
        r.stop()
    stop_router(name)
    stop_router(name0)


# =========================================================== 3. power_of_two
def round_power_of_two(have_rust):
    ports, order, model = make_pool([("msd", "sdA", SLOW_MS, True), ("msd", "sdB", 5, True),
                                     ("msd", "sdC", 5, True)])
    slow = order[0]
    name = "lr-pp2-" + RUN
    lua = start_router({"SMG_POLICY": "power_of_two", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                        "SMG_WORKER_URLS": url_list(ports, order)}, name)
    base = "http://127.0.0.1:%d" % lua
    tag = "power_of_two/Lua"
    ok = check("[%s] 3 workers healthy" % tag, lua_healthy(lua, ports, 3), logs(name)[:200])
    REPORT["power_of_two"] = {"slow_ms": SLOW_MS, "n": POT_N, "slow_worker": slow,
                              "warmup": POT_WARMUP,
                              "criteria": {"uniformity": "TOST(d=%.3f, Z=%.4f, alpha=0.05/6)"
                                           % (TOST_D, TOST_Z),
                                           "chi2": "report-only (crit %.3f)" % CHI2_P005,
                                           "avoid_theta": {"lua": TH_AVOID_LUA,
                                                           "rust_with_loads": TH_AVOID_RUST_WITH}}}
    if not ok:
        stop_router(name)
    else:
        sample(base, model, lambda i: "warm %d" % i, POT_WARMUP)   # exclude cold start
        dl = counts_of(sample(base, model, lambda i: "pot probe %d shared body text" % i, POT_N), order)
        cl = chi2(list(dl.values()))
        # avoid 判据（theta 标定见 avoid_gate）：慢桶份额必须 <= theta。
        gl_av, sh_l = avoid_gate(dl, slow, TH_AVOID_LUA)
        check("[%s] 两随机候选取低负载：避开 %dms 慢 worker（slow_share=%.3f <= %.2f，N=%d）"
              % (tag, SLOW_MS, sh_l, TH_AVOID_LUA, POT_N), gl_av,
              "%s share=%.3f theta=%.2f" % (dl, sh_l, TH_AVOID_LUA))
        # skew 判据 = TOST 的**反面**：dev 必须**超出** tol，才说明真在比负载而不是随机撒点。
        # 用同一个 tol 而不是 χ² 临界值，两侧共用一套口径。实测 Lua 份额 0.096~0.146
        # 对应 dev 0.19~0.23，是 tol=0.0976 的 2 倍，判红概率实测 0（60 万次抽样）。
        # 注意这条比旧 χ²>5.991 **更严**：旧判据在 share≈0.29 时仍绿（期望 χ²=10），
        # 新判据 share>0.237 就红。于是「仍在避开」的有效上限由这条的 0.237 决定，
        # 而不是 avoid_gate 的 θ=0.25 —— 方向是收紧、不是放松，Lua 实测离两者都远。
        gl_sk, dev_l, tol_l = tost_uniform(list(dl.values()))
        stat_line("power_of_two/Lua with-loads", list(dl.values()), cl, gl_sk, dev_l, tol_l,
                  "skew-assert: need dev>tol; slow_share=%.4f" % sh_l)
        check("[%s] 偏斜说明确实在比负载而不是随机撒点（max|share-1/3|=%.4f > tol=%.4f；"
              "报告项 χ²=%.3f vs 临界 %.3f）" % (tag, dev_l, tol_l, cl, CHI2_P005),
              dev_l > tol_l, "%s dev=%.4f tol=%.4f chi2=%.3f" % (dl, dev_l, tol_l, cl))
        cnt = selection_counter(http("GET", base + "/metrics")[1], model, "power_of_two")
        check("[%s] worker_selection_total{policy=power_of_two} 计数 > 0" % tag, (cnt or 0) > 0,
              "counter=%s" % cnt)
        REPORT["power_of_two"]["lua_with_loads"] = {"counts": dl, "chi2": round(cl, 3),
                                                   "slow_share": round(share(dl, slow), 4),
                                                   "selection_counter": cnt}
        stop_router(name)

    # 同一场景但 worker 不提供 /v1/loads（sglang-less 部署）
    nports, norder, nmodel = make_pool([("msdn", "pdN1", SLOW_MS, False), ("msdn", "pdN2", 5, False),
                                        ("msdn", "pdN3", 5, False)])
    nslow = norder[0]
    nname = "lr-pp2n-" + RUN
    lun = start_router({"SMG_POLICY": "power_of_two", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                        "SMG_WORKER_URLS": url_list(nports, norder)}, nname)
    lunb = "http://127.0.0.1:%d" % lun
    okn = check("[power_of_two/Lua no-loads] 3 workers healthy", lua_healthy(lun, nports, 3),
                logs(nname)[:200])
    if okn:
        sample(lunb, nmodel, lambda i: "warm %d" % i, POT_WARMUP)
        dn = counts_of(sample(lunb, nmodel, lambda i: "pot noloads %d shared body text" % i, POT_N), norder)
        gn_av, sh_n = avoid_gate(dn, nslow, TH_AVOID_LUA)
        _gn, _dev, _tol = tost_uniform(list(dn.values()))
        stat_line("power_of_two/Lua no-loads", list(dn.values()), chi2(list(dn.values())),
                  _gn, _dev, _tol, "slow_share=%.4f theta=%.2f" % (sh_n, TH_AVOID_LUA))
        check("[power_of_two/Lua no-loads] 仍用自己的 in-flight 计数，避开慢 worker"
              "（slow_share=%.3f <= %.2f，N=%d）" % (sh_n, TH_AVOID_LUA, POT_N), gn_av,
              "%s share=%.3f theta=%.2f" % (dn, sh_n, TH_AVOID_LUA))
        REPORT["power_of_two"]["lua_no_loads"] = {"counts": dn, "chi2": round(chi2(list(dn.values())), 3),
                                                 "slow_share": round(share(dn, nslow), 4)}
    stop_router(nname)

    if have_rust:
        rname = "lr-pp2-r" + RUN[-4:]
        r = RustRouter(rname, "power_of_two", ports, order, model, worker_urls=True)
        if check("[power_of_two/Rust] --worker-urls 启动后 3 workers healthy", r.healthy(),
                 logs(rname)[:250]):
            sample(r.base, model, lambda i: "warm %d" % i, POT_WARMUP)
            dr = counts_of(sample(r.base, model, lambda i: "pot probe %d shared body text" % i, POT_N), order)
            # θ 从 0.30 收到 0.28 并把 N 提到 1200：旧口径 N=240 / θ=0.30 在真随机
            # （p=1/3，即完全没避开）下**放过率 0.187，约 1/5**，等于没检。
            # 新口径放过率 6.9e-05、偶发红 6.7e-06（θ 的取舍见 avoid_gate 注释）。
            gr_av, sh_r = avoid_gate(dr, slow, TH_AVOID_RUST_WITH)
            _gr, _devr, _tolr = tost_uniform(list(dr.values()))
            stat_line("power_of_two/Rust with-loads", list(dr.values()), chi2(list(dr.values())),
                      _gr, _devr, _tolr, "slow_share=%.4f theta=%.2f" % (sh_r, TH_AVOID_RUST_WITH))
            check("[power_of_two/Rust] 有 /v1/loads 时同样避开慢 worker（slow_share=%.3f <= %.2f；"
                  "随机基线 0.333，N=%d）" % (sh_r, TH_AVOID_RUST_WITH, POT_N), gr_av,
                  "%s share=%.3f theta=%.2f" % (dr, sh_r, TH_AVOID_RUST_WITH))
            REPORT["power_of_two"]["rust_with_loads"] = {
                "counts": dr, "chi2": round(chi2(list(dr.values())), 3),
                "slow_share": round(share(dr, slow), 4),
                "selection_counter": selection_counter(r.metrics(), model, "power_of_two")}
        r.stop()

        r2name = "lr-pp2n-r" + RUN[-4:]
        r2 = RustRouter(r2name, "power_of_two", nports, norder, nmodel, worker_urls=True)
        if check("[power_of_two/Rust no-loads] 3 workers healthy", r2.healthy(), logs(r2name)[:250]):
            sample(r2.base, nmodel, lambda i: "warm %d" % i, POT_WARMUP)
            drn = counts_of(sample(r2.base, nmodel, lambda i: "pot noloads %d shared body text" % i,
                                   POT_N), norder)
            crn = chi2(list(drn.values()))
            log_txt = docker_logs(r2name)
            noloads_lines = log_txt.count("No loads fetched")
            # 判据 = TOST 等价性检验（绿 = **证明了**与均匀不可区分），χ² 只作报告项。
            # 旧判据 (share > 0.22 and χ² < 5.991) 的偶发红全部来自 χ² 那一侧：
            # E[χ²]=df=2 与 N 无关，P(χ²>5.991|真均匀)=exp(-5.991/2)=5.0%。
            # 实测跨轮 slow_share 0.271~0.362（基线 0.333）对应 dev <= 0.062，
            # 距 d=0.065 的边界 tol=0.0976 有 0.035 余量，所以 d 取 0.065 而不是标定的 0.055
            # —— d=0.055 在最差真实观测（0.267，counts 64/80/96）上仍红 4.4%。
            gn_de, dev_n, tol_n = tost_uniform(list(drn.values()))
            stat_line("power_of_two/Rust no-loads", list(drn.values()), crn, gn_de, dev_n, tol_n,
                      "degraded-assert: need dev<=tol; slow_share=%.4f floor>0.22"
                      % share(drn, nslow))
            check("[power_of_two/Rust no-loads] 背离复现：负载取不到时退化成均匀随机"
                  "（TOST max|share-1/3|=%.4f <= tol=%.4f，d=%.3f；慢份额 %.3f > 0.22；"
                  "报告项 χ²=%.3f vs 临界 %.3f）"
                  % (dev_n, tol_n, TOST_D, share(drn, nslow), crn, CHI2_P005),
                  gn_de and share(drn, nslow) > 0.22,
                  "%s share=%.3f dev=%.4f tol=%.4f chi2=%.3f"
                  % (drn, share(drn, nslow), dev_n, tol_n, crn))
            probe_loads = [http("GET", "http://127.0.0.1:%d/v1/loads?include=core" % nports[w],
                                timeout=3)[0] for w in norder]
            check("[power_of_two/Rust no-loads] 原因确认：worker 的 /v1/loads 全部 404（LoadMonitor "
                  "因此缓存 -1）；日志 \"No loads fetched\" 计数 %d 条仅作记录" % noloads_lines,
                  set(probe_loads) == {404}, "statuses=%s" % probe_loads)
            REPORT["power_of_two"]["rust_no_loads"] = {
                "counts": drn, "chi2": round(crn, 3), "slow_share": round(share(drn, nslow), 4),
                "no_loads_log_lines": noloads_lines,
                "verdict": "LoadMonitor caches total_tokens=-1, so load1 <= load2 always holds "
                           "and the pick collapses to the first random candidate"}
        r2.stop()
    else:
        REPORT["power_of_two"]["rust"] = "skipped (image missing)"


# ================================================================== 4. random
def round_random(have_rust):
    ports, order, model = make_pool([("mpo", "poA", 0, True), ("mpo", "poB", 0, True),
                                     ("mpo", "poC", 0, True)])
    name = "lr-prnd-" + RUN
    lua = start_router({"SMG_POLICY": "random", "SMG_HEALTH_CHECK_INTERVAL_SECS": "1",
                        "SMG_WORKER_URLS": url_list(ports, order)}, name)
    base = "http://127.0.0.1:%d" % lua
    tag = "random/Lua"
    ok = check("[%s] 3 workers healthy" % tag, lua_healthy(lua, ports, 3), logs(name)[:200])
    REPORT["random"] = {"n_per_side": N_RANDOM, "concurrency": CONC,
                        "chi2_crit_p005": CHI2_P005, "chi2_crit_p001": CHI2_P001}
    if ok:
        dl = counts_of(sample(base, model, lambda i: "random probe %d" % i, N_RANDOM), order)
        cl = chi2(list(dl.values()))
        vals = list(dl.values())
        exp = sum(vals) / float(len(vals))
        dev = 100.0 * max(abs(v - exp) for v in vals) / exp
        # 判据 = TOST（绿 = 证明了与均匀不可区分）。三条旧判据各自带内置红预算：
        # χ²<5.991 是 5%、χ²<9.210 是 1%、max_dev<3% 折成份额偏移只有 2.12 个 sd
        # （0.01 / 0.00471），3 桶取 max 后偶发红 **8.5%** —— 三条叠起来约 10%，
        # 所以这一轮在全量门禁里本来就是常态性贴线红（本轮实测 χ²=6.679、偏移 3.61%）。
        # 新口径 d_random=0.008 -> tol=0.0193（4.1 个 sd），真均匀下假红 1.7e-04，
        # 而任何有实际意义的偏斜（0.40/0.30/0.30，dev=0.0667）漏检概率 0。
        gl, gd, gt = tost_uniform(vals, d=TOST_D_RANDOM)
        stat_line(tag + " random", vals, cl, gl, gd, gt, d=TOST_D_RANDOM)
        check("[%s] N=%d 均匀性 TOST max|share-1/3|=%.4f <= tol=%.4f (d=%.3f)；"
              "报告项 chi2=%.3f vs %.3f/%.3f" % (tag, N_RANDOM, gd, gt, TOST_D_RANDOM,
                                                cl, CHI2_P005, CHI2_P001),
              gl, "%s dev=%.4f tol=%.4f chi2=%.3f" % (dl, gd, gt, cl))
        # 反向护栏：真 random 的 dev 不可能是 0。贴得太均匀 = 其实在严格轮转
        # （round_robin 的签名），这才是旧 max_dev 那条**没在管**的方向。
        # 实测 P(dev <= 0.0002 | 真 random) = 1.0e-03（150 万次抽样）。
        check("[%s] 不像被换成严格轮转：max|share-1/3|=%.4f > 0.0002"
              "（真 random 下该值 <=2e-04 的概率仅 1.0e-03）" % (tag, gd),
              gd > 0.0002, "%s dev=%.4f" % (dl, gd))
        check("[%s] 三桶都有份额且不塌缩（每桶 share %.4f~%.4f）"
              % (tag, min(vals) / float(sum(vals)), max(vals) / float(sum(vals))),
              all(0.20 < v / float(sum(vals)) < 0.47 for v in vals), json.dumps(dl))
        cnt = selection_counter(http("GET", base + "/metrics")[1], model, "random")
        check("[%s] worker_selection_total{policy=random} 计数 >= N" % tag, (cnt or 0) >= N_RANDOM,
              "counter=%s n=%d" % (cnt, N_RANDOM))
        st_lg, body_lg, _ = http("GET", base + "/_ui/logs?limit=5")
        routes = set()
        try:
            routes = {rec.get("route_type") for rec in json.loads(body_lg).get("requests", [])}
        except Exception:
            pass
        check("[%s] /_ui/logs route_type 全为 random" % tag, routes == {"random"}, str(routes))
        REPORT["random"]["lua"] = {"counts": dl, "chi2": round(cl, 3), "max_dev_pct": round(dev, 3),
                                   "selection_counter": cnt, "route_types": sorted(x or "-" for x in routes)}
    stop_router(name)

    if have_rust:
        rname = "lr-prnd-r" + RUN[-4:]
        r = RustRouter(rname, "random", ports, order, model)
        if check("[random/Rust] 3 workers healthy", r.healthy(), logs(rname)[:250]):
            dr = counts_of(sample(r.base, model, lambda i: "random probe %d" % i, N_RANDOM), order)
            vr = list(dr.values())
            cr = chi2(vr)
            expr = sum(vr) / float(len(vr))
            devr = 100.0 * max(abs(v - expr) for v in vr) / expr
            gr, gdr, gtr = tost_uniform(vr, d=TOST_D_RANDOM)
            stat_line("random/Rust", vr, cr, gr, gdr, gtr, d=TOST_D_RANDOM)
            check("[random/Rust] N=%d 均匀性 TOST max|share-1/3|=%.4f <= tol=%.4f (d=%.3f)；"
                  "两侧各自过检，不逐次比对；报告项 chi2=%.3f vs %.3f"
                  % (N_RANDOM, gdr, gtr, TOST_D_RANDOM, cr, CHI2_P005),
                  gr and gdr > 0.0002, "%s dev=%.4f tol=%.4f chi2=%.3f" % (dr, gdr, gtr, cr))
            cntr = selection_counter(r.metrics(), model, "random")
            check("[random/Rust] worker_selection_total{policy=random} 计数 >= N",
                  (cntr or 0) >= N_RANDOM, "counter=%s" % cntr)
            REPORT["random"]["rust"] = {"counts": dr, "chi2": round(cr, 3),
                                        "max_dev_pct": round(devr, 3), "selection_counter": cntr}
        r.stop()
    else:
        REPORT["random"]["rust"] = "skipped (image missing)"


# ------------------------------------------------------------- rust wrapper
def rust_available():
    return subprocess.run(["docker", "image", "inspect", RUST_IMAGE],
                          capture_output=True).returncode == 0


def rust_cli_rejects(policy):
    """`smg launch --policy X` with an unusable port: clap's verdict is the answer."""
    r = subprocess.run(["docker", "run", "--rm", "--entrypoint", "smg", RUST_IMAGE,
                        "launch", "--host", "127.0.0.1", "--port", "1", "--policy", policy],
                       capture_output=True, timeout=180)
    text = r.stderr.decode() + r.stdout.decode()
    return r.returncode != 0 and ("invalid value '%s' for '--policy" % policy) in text, text


class RustRouter:
    """A dedicated gateway per policy: shared instances would contaminate state
    (the routing round learned this the hard way)."""

    def __init__(self, name, policy, ports, order, model, labels_policy=None, worker_urls=False):
        self.name, self.ports, self.order, self.model = name, ports, order, model
        self.port, self.prom = free_port(), free_port()
        self.base = "http://127.0.0.1:%d" % self.port
        args = ["docker", "run", "-d", "--name", name, "--network", "host",
                "--entrypoint", "smg", RUST_IMAGE, "launch",
                "--host", "127.0.0.1", "--port", str(self.port),
                "--prometheus-port", str(self.prom),
                "--health-check-interval-secs", "1", "--worker-startup-check-interval", "1",
                "--request-timeout-secs", "30", "--enable-igw"]
        if policy:
            args += ["--policy", policy]
        if worker_urls:
            # measured: --policy power_of_two without --worker-urls refuses to boot
            # with IncompatibleConfig "Power-of-two policy requires at least 2 workers"
            args += ["--worker-urls"] + ["http://127.0.0.1:%d" % ports[w] for w in order]
        subprocess.run(args, check=True, capture_output=True)
        RUST_CONTAINERS.append(name)
        if not self.wait_listen():
            raise RuntimeError("rust gateway %s never opened %s:\n%s"
                               % (name, self.base, docker_logs(name)[-1500:]))
        if not worker_urls:
            for w in order:
                body = {"url": "http://127.0.0.1:%d" % ports[w], "model_id": model}
                if labels_policy:
                    body["labels"] = {"policy": labels_policy}
                http("POST", self.base + "/workers", body)

    def wait_listen(self, timeout=240):
        """The axum listener only comes up after the tokenizer warmup, so the
        control-plane POSTs have to wait for it: registering earlier just gets
        ECONNREFUSED and no worker ever appears. 90s was calibrated on a serial
        gate run; under GATE_JOBS parallel load the first health cycle + router
        ready handshake takes 75-120s on this box, so the ceiling is 240s. The
        assertion stays "boots at all" - the budget is not the check."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            if http("GET", self.base + "/health", timeout=2)[0] == 200:
                return True
            time.sleep(0.25)
        return False

    def worker_json(self):
        return json.loads(http("GET", self.base + "/workers")[1] or "{}").get("workers", [])

    def healthy(self, timeout=240):
        want = {str(self.ports[w]) for w in self.order}
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                seen = {w["url"].rsplit(":", 1)[1] for w in self.worker_json() if w.get("is_healthy")}
            except Exception:
                seen = set()
            if want <= seen:
                return True
            time.sleep(0.5)
        return False

    def metrics(self):
        return http("GET", "http://127.0.0.1:%d/metrics" % self.prom)[1]

    def stop(self):
        subprocess.run(["docker", "rm", "-f", self.name], capture_output=True)


def main():
    stat_selftest()
    have_rust = rust_available()
    print("rust image %s: %s" % (RUST_IMAGE, "present" if have_rust else
                                 "MISSING -> Rust-side checks skipped"))
    REPORT["image"] = {"rust": RUST_IMAGE if have_rust else None,
                       "rust_checks": "run" if have_rust else "skipped",
                       "lua": "in-container (lua-router:integration)"}
    for fn in (round_prefix_hash, round_bucket, round_power_of_two, round_random):
        # A gateway that fails to come up (port race, docker hiccup) must fail its
        # own round loudly, not abort the other three rounds' evidence.
        try:
            fn(have_rust)
        except Exception as exc:
            import traceback
            check("[%s] round completed without an internal error" % fn.__name__, False,
                  "%s\n%s" % (exc, traceback.format_exc()[-600:]))

    try:
        os.makedirs(OUT_DIR, exist_ok=True)
        path = os.path.join(OUT_DIR, "e2e_policy_parity.json")
        with open(path, "w") as f:
            json.dump(REPORT, f, indent=1, sort_keys=True, default=str)
        print("[saved] %s" % path)
    except Exception as e:
        print("[warn] report json not written: %s" % e)

    failed = [r for r in RESULTS if not r[0]]
    print("\n=== %d checks, %d failed ===" % (len(RESULTS), len(failed)))
    for _, name, detail in failed:
        print("FAILED: %s | %s" % (name, str(detail)[:300]))
    cleanup()
    for c in RUST_CONTAINERS:
        subprocess.run(["docker", "rm", "-f", c], capture_output=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
