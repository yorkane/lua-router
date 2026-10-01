# lua-router vs Rust llm-router 性能对拍 v2（perf-v2）

对拍日期 2026-09-30（UTC，窗口 11:30–12:43）。数据目录 `/data/tmp/parity/perf-v2/`。
本报告只覆盖**吞吐/延迟/资源**与其归因；行为契约见
[parity-contract.md](parity-contract.md)，
v1 报告已随 2026-10-01 文档精简删除（git 历史可查）。

> **状态**：权威矩阵有效（主矩阵 + 慢流修正 + 同机 A/B 共 kept 63 行 / excluded 6 行、
> 9 230 484 次请求、err=0；消融 40 行 5 966 718 请求、auto 组 24 行 3 263 416 请求，同样 err=0）。
> **v1 §4.1 的 Rust 44 ms stall 已定界**（§9）；**Lua 相对出厂镜像的 1.54x CPU 差距未定责**（§7，候选已列明）。
> **日期**：对拍 2026-09-30，报告 2026-09-30（UTC）。
> **证据强度**：A-（`results_v2.json` / `results_v2_slow2.json` / `results_v2_ab.json` /
> `results_v2_abl.json` / `results_v2_auto.json` / `results_nagle.json` 原始 JSON，
> 逐轮 RPS 与 loadavg before/after 全部留档；被排除的组带原因保留，不静默丢弃）。

两条最容易被误读的事实，放在最前面：

1. v1 的头条「出厂镜像 `worker_processes auto` 下 Lua 24.6k ≈ Rust 25.7k」测的是**旧代码**
   （出厂镜像内置 router.lua，md5 `1d48f333…`）。v2 的 Lua 行测的是**工作树**
   （md5 `5b60aae9…`，含 gap 接线与上游连接池），两者不是同一份代码，
   任何 v1↔v2 的跨轮直接相减都不成立。可比数字全部来自 v2 内部的同窗口交替 A/B（§6、§7）。
2. Lua 侧 4 worker 在 json C=64 被钉在 **CPU 400%**（`docker stats` 401.95%）——
   即那格是 worker 数饱和，不是代码上限。因此报告同时给 **µs/req**（与 worker 数无关）
   和 **`worker_processes auto`** 的生产形态（§8 的 auto 组），否则「Lua 只有 Rust 45%」会被读成代码结论。

## 0. 结论摘要

| 维度 | 结论 | 依据 |
| --- | --- | --- |
| 非流式吞吐（4 worker） | json C=64：直连 28 731 / **Rust 26 411（92%）** / **Lua 12 010（42%）**；C=16 Rust 12 482（90%）/ Lua 9 972（72%） | §3 §4 |
| 非流式净开销 p50 | C=1 Lua +0.39 / Rust +0.38；C=16 Lua +0.32 / Rust +0.13；C=64 **Lua +2.86 / Rust +0.22** ms | §4 |
| 每请求 CPU（µs/req，json） | 矩阵窗口 Lua 333–419 / Rust 368–387；auto 组 Lua 4w 342–427、auto 454；**出厂镜像同窗口只花 201–307**：同格比工作树高 37–65%，且越并发差得越多（C=1 +37~45%、C=16 +38%、C=64 +61~65%） | §4 §6 §8 |
| 生产形态（auto） | 工作树 `worker_processes auto`（144 worker）json C=64 **22 207 RPS / CPU 1009% / 454 µs/req**，同格 Rust 26 088 / 975% / 374 µs/req —— 同等 CPU 预算下 Lua 少约 15% 吞吐 | §8 |
| 即时流式（mock 一次写完） | Rust 恒定 **44 ms/响应**（358 RPS，达成率 3%），Lua 8 294 RPS；**已定界为 Rust 下游 accepted socket 缺 `TCP_NODELAY`**，客户端 busy-QUICKACK 把 357→4 861/7 245 RPS、p50 44.0→3.0/2.0 ms | §3 §9 |
| 真实解码流式（chunk 20 ms × 10） | 三目标完全打平：直连 681.8 / Lua 677.8 / Rust 678.4 RPS（差 <0.6%），p50 186.97/187.32/187.08 ms，净开销 Lua +0.35 / Rust +0.11 ms | §3 §4 |
| Lua 相对出厂镜像的差距 | json C=64：出厂/工作树 = **1.64x**；同时关掉请求日志与 server 级 CORS 预检后仍有 **1.54x**（这两项合计只解释 ~6%） | §7 |
| 内存 | Lua 4 worker 69–91 MiB（`/proc` 各 worker 求和；矩阵行 77.7–81.3，`docker stats` 单容器口径 25–46 MiB），Rust 110–146 MiB（146–147 线程常驻），出厂 4 worker Lua 67–69 MiB，**工作树 auto 144 worker 1.36–2.13 GB** | §1 §8 |
| 错误 | 权威矩阵与 A/B、消融、auto 组全部 err=0 | §2 |

一句话：**非流式下 Rust 上限更高、每请求 CPU 更省；Lua 的差距里，能明确归因的只有 CORS 预检 +
请求日志这 ~6%，剩下 1.54x 是「工作树新增模块接线 + 上游连接池」这一大包改动的整体代价，尚未逐项定责；
带真实 chunk 节流的流式（最接近生产解码）三目标打平；即时流式的 Rust 44 ms 是下游 socket 没设
`TCP_NODELAY`，与 Lua 无关。**

## 1. 环境与口径

- 机器：本机 <dev-box>，144 逻辑核，同机有 GPU 服务与网关租户。整轮 load1 在 **17.7–28.9** 之间漂移，
  每行都记录 before/after loadavg（§10）。
- 实例（全部 `--network host`，端口见 `ports.json`，与 v1 完全不复用）：

| 用途 | 容器 | 端口 | 代码 | worker |
| --- | --- | --- | --- | --- |
| 权威矩阵 Lua | `perf2-lua` | 55742 | 工作树 `5b60aae9…` | 4 |
| 权威矩阵 Rust | `perf2-rust` | 55752（prom 55762） | `ghcr.io/yorkane/llm-router:local-vm-f4a25ac` | — |
| 慢流专用 | `perf2-lua-slow` / `perf2-rust-slow` | 55744 / 55754 | 同上 | 4 / — |
| 出厂基线 | `perf2-lua-ref` | 55746（metrics 55747） | `lua-router:latest` 镜像内置 `1d48f333…` | 4（`NGINX_WORKER_PROCESSES=4`） |
| 消融 B1 | `perf2-lua-abl1` | 55758 | 工作树，`LMR_REQUEST_LOG_CAPACITY=0` | 4 |
| 消融 B2 | `perf2-lua-abl2` | 55749 | 工作树，日志 off **且** 去掉 server 级 CORS 预检 | 4 |
| 生产形态 | `perf2-lua-auto` | 55768 | 工作树 `4bc500b0…`（12:14 之后的新副本，见 §10） | auto=144 |
| 上游 mock | `mock_fast.py` × 4 | 55722/55723（fast，`--stream-batch`）、55732/55733（slow，`--model slow-model --chunk-ms 20 --chunk-count 10`） | 起于 11:33:56 / 11:47:57 | — |

- 策略两侧 `round_robin`，健康检查各自 2 s（Lua `SMG_HEALTH_CHECK_INTERVAL_SECS=2`，
  Rust `--health-check-interval-secs 2`，endpoint `/health`）。
- 请求：`POST /v1/chat/completions`，body `{"model":"test-model","messages":[{"role":"user","content":"hi"}]}`，
  流式加 `"stream":true`；慢流组用 `model:"slow-model"` 只打两个节流 mock。每格 15 s 闭环，客户端 keep-alive。
- **客户端进程拆分**（v1 M3 的教训，总并发守恒）：C=1→1 proc，C=16→2×8，C=64→4×16，C=128→8×16；RPS 求和、延迟取中位数。
- 目标**按 rep 反向交替**（rep1 `mockpair→lua→lua_ref→rust`，rep2 反过来），跨轮取中位数，避免固定时钟偏移。
- CPU 读 `/proc/<pid>/stat` 的 utime+stime（含 worker 子进程）折算**占单核%**；
  RSS 取 `statm` 汇总。表里同时保留 `docker stats` 的单容器口径，两者不可互换（Lua 4 worker：77–81 vs 25–46 MiB）。
- 上游 mock CPU 单独记列并折算 µs/req，避免把上游成本记到 router 头上（v1 M5 的口径）。

## 2. 采用 / 排除的数据组

纳入结论的数据（`mkreport_v2.py` 的机械规则：仅当 `warmup_failed`、errors > 该格请求数 0.5%、
或行被显式标记 `invalid` 时排除；kept 63 / excluded 6）：

| 文件 | 窗口（UTC） | 行数 | 用途 | 状态 |
| --- | --- | ---: | --- | --- |
| `results_v2.json`（`json`+`stream`） | 11:34–11:46 | 33 | 权威矩阵 §3 | 全部采用，err=0 |
| `results_v2.json`（`slow_stream`） | 11:34–11:46 | 6 | — | **排除**，见下 D1 |
| `results_v2_slow2.json` | 11:49–11:50 | 6 | 慢流 §3 | 采用（D1 的修正重跑） |
| `results_v2_ab.json` | 11:57–12:04 | 24 | 同机出厂 A/B §6 | 采用，err=0 |
| `results_v2_abl.json` | 12:14–12:25 | 40 | 消融 §7 | 采用，err=0 |
| `results_v2_auto.json` | 12:31–12:38 | 24 | 生产形态 auto §8 | 采用，err=0（C=64 仅 1 rep） |
| `results_nagle.json` / `results_quickack*.json` | 12:09–12:29 | 8/12+… | stall 定界 §9 | 采用（诊断组，不进吞吐矩阵） |
| `run_v2_ab.contaminated.log` | ~11:52–11:56 | 14 | — | **排除**，见下 D2 |
| `results_v2_abl.contaminated.json` / `.log` | 12:08–12:13 | 16 | — | **排除**，见下 D3 |

- **D1 慢流首轮无效（模型池混流）**：`register_slow.sh` 把两个 20 ms 节流 mock 注册进主容器后，
  它们与两个即时 mock 落进了**同一个 model 池**，`model="slow-model"` 的 round_robin 实际混打 0 ms 与 20 ms 上游，
  于是 Lua 1352.25 / Rust 1253.05 RPS 反而接近直连 680.05 的两倍（p50 95.45/115.78 ms 是混池平均的直接指纹）。
  原始行留在 `results_v2.json`（raw 里无标记，`invalid` 是 `mkreport_v2.py` 在读入时给
  `group == "slow_stream"` 加上的），修正方式：mock 侧补 `--model slow-model` 重启（11:47，
  见 `mock_5573x.slowfix.log`），并改用**只注册慢 mock 的独立容器** `perf2-lua-slow` / `perf2-rust-slow` 重跑 → `slow_stream2`。
  同一原因也污染了 A/B 的第一轮（D2）。
- **D2 A/B 首轮**：那一轮 `perf2-lua` / `perf2-rust` 的池里还挂着两个 20 ms 慢 mock，
  四家 mock 均摊流量（C=1 的 lua 行 `mock55722/23/32/33` 各 ~4% CPU），于是 lua 行 1259.5、
  rust 行 1491.3 被慢上游拖住；同一轮的 `lua_ref` 行（容器只注册了快 mock，`mock55732/33` = 0.1%）
  给出 1741.9 / 1735.6 —— 这个反差就是池污染的判别证据。JSON 未落盘，只有
  `run_v2_ab.contaminated.log`（14 行）保留，不进任何结论。
- **D3 消融首轮**：12:08–12:13 那 16 行是消融脚本第一次跑，只做单 rep、顺序未反向交替，
  随后被 12:14 起的 40 行复跑覆盖；旧文件按 `.contaminated` 重命名保留。它未进结论，仅作方向一致性参考
  （C=64：lua 10 053.6 / abl_log 11 972.1 / abl_both 12 462.8 / lua_ref 18 142.7 / mockpair 25 103.9，
  与复跑同序）。
- 另有 `summary_v2.json`（只有一句 `{"note": "see results_v2.json raw"}`，无数据）与
  `results_v2_slow2.json` 之外的中间 probe（`res_probe3.py` 等），只作为脚本证据。

## 3. 权威矩阵

RPS 为多客户端进程合计；延迟单位 ms；`router CPU` 为容器合计占单核%；`RSS` 为 `/proc` 汇总 MiB；
`mock CPU` 为该格参与 mock 的合计占单核%。跨轮取中位数，`轮次RPS` 给出原始逐轮值。

| 模式 | 并发 | 目标 | RPS | p50 | p90 | p99 | TTFB p50 | err | router CPU | RSS | docker stats CPU | docker RSS | 线程 | mock CPU | 轮次RPS |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| json | 1 | mock 直连 | 3689.4 | 0.27 | 0.32 | 0.39 | — | 0 | — | — | — | — | — | 29.1 | 3689.4, 3635.6, 3691.2 |
| json | 1 | Lua 4w | 1408.1 | 0.66 | 0.84 | 1.45 | — | 0 | 59.1 | 77.7 | 60.16% | 24.73 | 5 | 15.9 | 1408.1, 1407.1, 1421.8 |
| json | 1 | Rust | 1508.4 | 0.65 | 0.75 | 0.91 | — | 0 | 55.6 | 109.5 | 52.82% | 31.09 | 147 | 16.8 | 1498.2, 1526.9, 1508.4 |
| json | 16 | mock 直连 | 13875.5 | 1.09 | 1.32 | 1.45 | — | 0 | — | — | — | — | — | 92.0 | 13875.5, 13806.2, 13982.6 |
| json | 16 | Lua 4w | 9972.2 | 1.41 | 2.85 | 4.91 | — | 0 | 353.3 | 78.1 | 379.54% | 33.43 | 5 | 78.0 | 9616.0, 9972.2, 10012.1 |
| json | 16 | Rust | 12481.5 | 1.22 | 1.56 | 1.90 | — | 0 | 469.8 | 115.4 | 442.44% | 42.42 | 147 | 96.8 | 12489.7, 12086.8, 12481.5 |
| json | 64 | mock 直连 | 28731.3 | 2.10 | 2.50 | 3.21 | — | 0 | — | — | — | — | — | 166.1 | 28868.3, 28731.3, 28547.2 |
| json | 64 | Lua 4w | 12010.2 | 4.96 | 7.97 | 11.14 | — | 0 | 399.7 | 78.5 | 401.95% | 35.13 | 5 | 93.1 | 12010.2, 12180.1, 11407.4 |
| json | 64 | Rust | 26410.8 | 2.32 | 3.08 | 4.01 | — | 0 | 1026.3 | 126.9 | 1107.47% | 70.02 | 146 | 174.6 | 26410.8, 26546.0, 25109.7 |
| stream（即时） | 16 | mock 直连 | 12372.3 | 1.22 | 1.46 | 1.87 | 1.21 | 0 | — | — | — | — | — | 115.3 | 12263.5, 12481.1 |
| stream（即时） | 16 | Lua 4w | 8294.4 | 1.73 | 2.88 | 4.70 | 1.73 | 0 | 376.1 | 81.3 | 379.18% | 38.05 | 5 | 87.2 | 8193.0, 8395.8 |
| stream（即时） | 16 | Rust | **358.4** | **44.03** | 47.99 | 48.49 | **1.06** | 0 | 21.3 | 127.9 | 20.53% | 114.40 | 146 | 5.8 | 357.8, 359.0 |
| slow_stream2 | 128 | mock 直连 | 681.8 | 186.97 | 188.93 | 191.47 | 1.31 | 0 | — | — | — | — | — | 43.4 | 683.1, 680.5 |
| slow_stream2 | 128 | Lua 4w | 677.8 | 187.32 | 188.91 | 194.41 | 1.57 | 0 | 61.0 | 80.0 | 60.64% | 42.89 | 5 | 33.2 | 679.1, 676.5 |
| slow_stream2 | 128 | Rust | 678.35 | 187.08 | 188.86 | **236.24** | 1.81 | 0 | 74.7 | 79.25 | 75.52% | 57.04 | 146 | 46.8 | 678.5, 678.2 |

三行需要单独说明：

- **Rust 即时流的 TTFB 正常（1.06 ms）而总延迟 44.03 ms**：44 ms 落在首字节之后，且 CPU 只用 21%、
  mock 只被驱动 5.8%（同格 Lua 用 376% / 87%）——它是「等」，不是「忙」。定界见 §9。
- **Rust 慢流的 p99 = 236.24 ms 是中位数假象**：两个 rep 的 p99 分别是 **275.747** 与 196.74 ms，
  Lua 两 rep 为 195.873 / 192.952，直连 191.714 / 191.236。也就是说 RPS/p50 三方打平，
  但 Rust 有一个 rep 出现了 275 ms 的尾（比基线多约 85 ms ≈ 4 个 chunk 的停顿），**尾部尚未复核**（§11 建议 5）。
- **Lua 即时流的 TTFB 等于总延迟 p50（1.73 ms）**：nginx 的 SSE 路径在这一格里没有引入分段停顿。
  工作树上游连接池对流式是净收益，但这条要靠同格对比才成立（§6：C=16 工作树 465 µs/req vs 出厂 501，
  且上游 mock CPU 从 179.7 核% 降到 87.1 核%）；v1 的 stream µs/req 是 C=1 格，不能跨并发相减。

## 4. 净开销、达成率与每请求成本

净开销 = 同格 router p50 − mock 直连 p50（ms）；达成率 = router RPS / 同格直连 RPS。

| 模式 | 并发 | 直连 p50 | Lua 净开销 | Rust 净开销 | Lua 达成率 | Rust 达成率 |
|---|---:|---:|---:|---:|---:|---:|
| json | 1 | 0.27 | +0.39 | +0.38 | 38% | 41% |
| json | 16 | 1.09 | +0.32 | +0.13 | 72% | 90% |
| json | 64 | 2.10 | +2.86 | +0.22 | 42% | 92% |
| stream（即时） | 16 | 1.22 | +0.51 | +42.81（stall，§9） | 67% | 3%（stall） |
| slow_stream2 | 128 | 186.97 | +0.35 | +0.11 | 99% | 99% |

每请求成本（µs/req = router 占单核% × 10000 / RPS；上游 mock 侧单列）：

| 模式 | 并发 | router Lua | router Rust | 上游 mock 直连 | Lua 路径 | Rust 路径 |
|---|---:|---:|---:|---:|---:|---:|
| json | 1 | 419 | 368 | 79 | 113 | 111 |
| json | 16 | 354 | 376 | 66 | 78 | 78 |
| json | 64 | 333 | 387 | 58 | 78 | 66 |
| stream（即时） | 16 | 453 | 594（被 stall 摊薄，不可比） | 93 | 105 | 162 |
| slow_stream2 | 128 | 900 | 1100 | 638 | 490 | 690 |

> `tables_v2.md` 的「CPU µs/req」小节（主矩阵段与 A/B 段两处）有**列互换**：`cpu_per_req()` 的打印顺序是
> `cells[0], cells[2], cells[1]`，而表头写的是「Lua / Lua ref / Rust」，所以印在「Lua ref」列的一直是
> **Rust** 的值、印在「Rust」列的一直是 **lua_ref** 的值（主矩阵里没有 lua_ref，那一列就成了 `—`）。
> 例：主矩阵 json C=1 的「Lua ref 369」其实是 Rust，A/B 段的「Lua ref 366 / Rust 307」应读作 Rust 366 / lua_ref 307。
> 本报告全部按原始 JSON 的 `cpu_pct_one_core` 与 `rps_total` 重算（`calc_mock_us.txt` 的 `router_us` 一致），不受该 bug 影响。

要点：

- C=1 两侧 p50 净开销 0.39 / 0.38 ms，与 v1 的 0.31 / 0.37 同量级（v1 的 mock 是另一批实例，只比量级）。
  C=1 那一格的直连 mock 只有 55722 在跑（`mock55723` CPU 为 0），所以它的「达成率 38%」是
  双 mock 基线除单 mock 流量，**C=1 的达成率不可读**，只有净开销可用。
- json C=64 的 Lua +2.86 ms 是 4 worker 饱和后的排队尾部（p90 7.97 / p99 11.14），不是单次转发成本：
  同格 µs/req（333）反而低于 C=1（419）。
- 慢流式（最接近真实解码）两侧净开销 0.35 / 0.11 ms，达成率同为 99% —— 这一格两侧都贴着上游 200 ms 的节奏跑。
- 上游 mock 侧成本三方同量级（非流式 58–79 µs/req），说明 Lua 没有把额外压力推给上游；
  Rust 在即时流那一格 mock 只花 162 µs/req、共 5.8% CPU，因为它根本没跑起来。

## 5. 与 v1 的差异

跨轮只比**同形态、同镜像**的行（v1 的 mock 与本轮不同实例，绝对值差 1–2% 属正常）：

| 对比项 | v1（9-29 窗口） | v2（本轮） | 判读 |
| --- | --- | --- | --- |
| 直连基线 json C=64 | 29 046 RPS，p50 2.08，mock 58 µs/req | 28 731 RPS，p50 2.10，mock 58 µs/req | 环境未漂移，跨轮可比 |
| Rust json C=64 | 25 575 RPS / 399 µs/req（`:latest`，0.3.2 构建） | 26 411 RPS / 387 µs/req（`local-vm-f4a25ac`） | 同量级；**tag 不同**，严格说是两次构建 |
| Lua 工作树 4w json C=64 | 17 080 RPS / 234 µs/req / p50 3.61 | 12 010 RPS / 333 µs/req / p50 4.96 | **-30% RPS、+42% µs/req**，两行 CPU 都记到 399.7%（4 worker 饱和），差距是每请求成本而不是核数 |
| Lua 出厂 4w json C=64 | 未测（v1 出厂只测 auto 145 进程） | 18 873–19 777 RPS / 201–212 µs/req | 出厂代码比 **v1 的工作树还快** |
| Lua 工作树 auto json C=64 | — | 22 207 RPS / 454 µs/req | 对比 v1 出厂 auto 24 607 / 269 µs/req |
| 即时流 Rust C=16 | 358 RPS / p50 44.02 | 358.4 RPS / p50 44.03 | 完全复现，本轮已定界（§9） |
| 慢流 C=128 | 直连/Lua/Rust 677.9–679.8，p50 ≈187 | 681.8 / 677.8 / 678.4，p50 186.97–187.32 | 复现「无可测差异」 |
| Lua 即时流 C=16 µs/req | 589 是 **C=1** 格，与本轮 C=16 不同格，只能看方向 | 453（矩阵）/ 465（A/B 同格） | 与出厂同格 501 比才是净收益（§6），跨并发不可减 |

关键判读：**v1 → v2 Lua 的 30% 吞吐下降不是机器变慢**。同格直连基线一模一样、出厂镜像在这一轮跑得比 v1 的工作树还快，
两侧同时排除了环境漂移；差异全部落在「工作树 router.lua 从 `c96b6556…` 变成 `5b60aae9…`」这段代码上
（parity-contract/gap-* 接线 + 上游连接池）。这段代价有多少能归因到具体模块，见 §7。

## 6. 同机 A/B：出厂镜像 vs 工作树（同一对 mock，交替执行）

`lua_ref` = 发布镜像 `lua-router:latest`（`268960883acd`，内置 router.lua md5 `1d48f333…`，
容器无 `/repo` 挂载，已复核）= 无上游连接池、无 server 级 CORS 预检、无请求日志存储、无 gap 模块接线。
`lua` = 工作树 `5b60aae9…`。窗口 11:57–12:04，rep1 `lua_ref→lua→rust`、rep2 反向。

| 模式 | 并发 | 目标 | RPS | p50 | p90 | p99 | TTFB p50 | err | router CPU | RSS | 线程 | mock CPU | µs/req |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| json | 1 | Lua 工作树 | 1411.2 | 0.66 | 0.83 | 1.47 | — | 0 | 59.2 | 90.6 | 5 | 16.1 | 420 |
| json | 1 | Lua 出厂 | 1681.9 | 0.56 | 0.70 | 1.10 | — | 0 | 51.6 | 68.4 | 5 | 18.2 | 307 |
| json | 1 | Rust | 1530.0 | 0.64 | 0.74 | 0.89 | — | 0 | 56.0 | 141.7 | 147 | 17.2 | 366 |
| json | 16 | Lua 工作树 | 9855.4 | 1.44 | 2.41 | 4.46 | — | 0 | 355.2 | 90.7 | 5 | 81.5 | 360 |
| json | 16 | Lua 出厂 | 11 733.9 | 1.22 | 2.05 | 3.43 | — | 0 | 299.5 | 68.5 | 5 | 94.5 | 255 |
| json | 16 | Rust | 12 778.5 | 1.18 | 1.47 | 1.88 | — | 0 | 486.1 | 141.5 | 147 | 101.9 | 380 |
| json | 64 | Lua 工作树 | 11 693.1 | 5.09 | 8.69 | 11.68 | — | 0 | 399.7 | 90.8 | 5 | 96.6 | 342 |
| json | 64 | Lua 出厂 | 18 873.4 | 3.19 | 4.60 | 6.40 | — | 0 | 399.6 | 68.8 | 5 | 138.6 | 212 |
| json | 64 | Rust | 24 746.3 | 2.44 | 3.42 | 5.12 | — | 0 | 986.9 | 143.7 | 147 | 174.6 | 399 |
| stream | 16 | Lua 工作树 | 8094.1 | 1.78 | 2.95 | 4.86 | 1.77 | 0 | 376.6 | 88.2 | 5 | 87.1 | 465 |
| stream | 16 | Lua 出厂 | 7021.3 | 2.09 | 3.43 | 4.81 | 2.09 | 0 | 351.1 | 67.9 | 5 | 179.7 | 501 |
| stream | 16 | Rust | 357.7 | 44.04 | 48.00 | 48.52 | 1.17 | 0 | 22.8 | 144.2 | 147 | 6.2 | 636 |

- 非流式：出厂 Lua 在 C=1/16/64 分别快 **1.19x / 1.19x / 1.61x**，µs/req 307→255→212 对比工作树 420→360→342。
  C=64 两行的 router CPU 都是 400%，所以差距是「每请求更贵」，不是「核不够」。
- 流式反向：工作树 8094 比出厂 7021 快 15%，且出厂路径的上游 mock 多花一倍 CPU（179.7 vs 87.1 核%，
  256 vs 108 µs/req）—— 与 v1 §5「Lua 流式每请求重连上游」一致，工作树的连接池在流式上是净收益。
- 这组同时说明：**Lua 的成本集中在非流式的每请求固定开销**，流式路径反而是工作树更优。

## 7. 消融：CORS 与请求日志只解释 ~6%

同一窗口（12:14–12:25）、同一对 mock、四个目标按 rep 反向交替：

| 目标 | 容器 | 相对工作树的差异 |
| --- | --- | --- |
| `lua` | `perf2-lua` | 全开（基线） |
| `abl_log` | `perf2-lua-abl1` | 关请求日志存储（`LMR_REQUEST_LOG_CAPACITY=0`） |
| `abl_both` | `perf2-lua-abl2` | 日志 off **+** 去掉 server 级 CORS 预检（`preflight_guard()` 的 `rewrite_by_lua_block` 移除） |
| `lua_ref` | `perf2-lua-ref` | 出厂代码（同时缺以上全部 + 连接池 + gap 接线） |

| 模式 | 并发 | lua | abl_log | abl_both | lua_ref | 直连 |
|---|---:|---:|---:|---:|---:|---:|
| json | 1 | RPS 1363.8 / p50 0.68 / 438 µs | 1427.6 / 0.65 / 409 | 1402.9 / 0.66 / 404 | 1612.3 / 0.58 / 302 | 3610.6 / 0.27 |
| json | 16 | 9458.7 / 1.44 / 370 | 10 031.2 / 1.40 / 358 | 9569.5 / 1.46 / 355 | 11 532.6 / 1.29 / 268 | 12 966.9 / 1.22 |
| json | 64 | 11 788.6 / 5.12 / 340 | 12 060.1 / 5.75 / 330 | 12 549.3 / 5.07 / 318 | 19 382.2 / 3.05 / 206 | 27 685.9 / 2.20 |
| stream | 16 | 8435.5 / 1.71 / 447 | 8523.7 / 1.68 / 439 | 8698.1 / 1.65 / 430 | 7345.9 / 2.01 / 481 | 12 272.3 / 1.21 |

json C=64 的比值链（同一窗口，可复算）：

```
lua_ref 19382.2 / lua 11788.6          = 1.64x   全部差距
lua_ref 19382.2 / abl_both 12549.3     = 1.54x   关掉 CORS+日志后仍剩
abl_both 12549.3 / lua 11788.6         = 1.06x   CORS+日志解释的部分（~6%）
```
（C=16 同序：1.22x / 1.21x / 1.01x；C=1：1.18x / 1.15x / 1.03x。µs/req 侧同向：340 → 330 → 318 → 206。）

也就是说：**请求日志存储与 server 级 CORS 预检两个开关合计只解释 ~6%（C=64）/ ~1%（C=16）；
剩余 ~1.54x 未定责。** 工作树相对出厂镜像的差量是 2270 行 diff，尚未逐项消融的候选：

1. **上游 cosocket 连接池**（`registry.pool_opts` / 池 key 分类 forward|stream|https / release 前的
   body-complete 判定与手工 pump）——每请求新增路径，收益在流式（§6），代价可能在非流式。
2. **per-model policy 选择**：`policy_for(model)` 从常量变成 `registry.policy_hint_for_model` +
   `policy_mod.for_model(...)` 的查找。
3. **新接线的四个模块进入请求路径**：`history`（conversations/response store，`persist_response`）、
   `limit`（每请求限压）、`tokenizer`、`parse`、`mesh`（`mesh_observe_worker` / `mesh_forget_worker`）。
4. **parity-contract 批次**（v1 之后才写的那轮修复）：header/body 改写、`set_top_field`、状态码与错误体归一。
5. 每请求 `cfg()` / 配置读取与 JSON 解析次数的变化。

**本节不写结论**：上面五项都还没有各自的开关（只有 `LMR_REQUEST_LOG_CAPACITY` 这类现成 env），
在补齐逐项开关之前，任何「就是连接池」的归因都超出数据支持范围（对应 §11 建议 1）。

## 8. 生产形态：`worker_processes auto`

v1 的头条数字来自**旧代码**的 auto，所以生产口径必须在 v2 重取。窗口 12:31–12:38，
`perf2-lua-auto` = 工作树（此容器 12:31:04 新起，加载 **12:14 之后**的 `4bc500b0…`，与其它 Lua 行不同副本，见 §10）
+ `worker_processes auto`（144 worker），C=64 只有 1 rep，且该组未跑直连基线（「对直连」列的取法见本节末尾）。

| 模式 | 并发 | 目标 | RPS | p50 | p99 | router CPU | µs/req | 对直连 |
|---|---:|---|---:|---:|---:|---:|---:|---:|
| json | 1 | Lua auto（144w） | 1387.7 | 0.66 | 1.51 | 60.6 | 436 | 38% |
| json | 1 | Lua 4w | 1399.3 | 0.66 | 1.47 | 59.8 | 427 | 38% |
| json | 1 | Lua 出厂 4w | 1721.6 | 0.55 | 1.07 | 51.7 | 300 | 47% |
| json | 1 | Rust | 1516.2 | 0.64 | 0.88 | 55.8 | 368 | 41% |
| json | 16 | Lua auto（144w） | 11 156.6 | 1.32 | 3.49 | 476.9 | 427 | 80% |
| json | 16 | Lua 4w | 10 121.3 | 1.40 | 4.47 | 366.8 | 362 | 73% |
| json | 16 | Lua 出厂 4w | 12 157.5 | 1.20 | 3.11 | 317.1 | 261 | 88% |
| json | 16 | Rust | 12 668.6 | 1.18 | 2.00 | 461.1 | 364 | 91% |
| json | 64 | Lua auto（144w） | 22 207.4 | 2.50 | 7.36 | 1008.7 | 454 | 78% |
| json | 64 | Lua 4w | 11 700.2 | 4.58 | 17.76 | 399.7 | 342 | 41% |
| json | 64 | Lua 出厂 4w | 19 776.7 | 3.01 | 6.34 | 398.1 | 201 | 70% |
| json | 64 | Rust | 26 087.9 | 2.40 | 3.88 | 975.3 | 374 | 92% |
| stream | 16 | Lua auto（144w） | 9494.1 | 1.53 | 4.08 | 495.2 | 522 | 77% |
| stream | 16 | Lua 4w | 8363.2 | 1.72 | 4.70 | 375.4 | 449 | 68% |
| stream | 16 | Lua 出厂 4w | 7156.7 | 2.06 | 4.63 | 350.3 | 489 | 58% |
| stream | 16 | Rust | 357.6 | 44.05 | 48.50 | 21.3 | 594 | 3%（stall） |

- **生产形态下 Lua 追回到 Rust 的 ~85%（22 207 vs 26 088，各花 ~1000% CPU）**，v1「同档」的量级仍然成立，
  但不再是 96%——差距从代码侧（§7）继承过来。
- 4 worker 那一格（11 700 RPS / CPU 400%）说明 **Lua 侧任何「达成率」结论都必须带 worker 数**，
  否则读到的是 worker 数而不是代码。
- auto 的 µs/req 明显高于 4 worker（454 vs 342）：144 worker 在同机 load1 ~22 的环境里付出了跨核调度与
  内存带宽代价，但换来 1.9x 的 RPS。
- **auto 形态的内存代价要一起报**：`perf2-lua-auto` 的 RSS 是 **1355.5–2125.6 MiB**
  （`/proc` 各 worker 求和，共享页按进程各计一次，所以每 worker 摊到 ~14 MiB；`docker stats` 的 cgroup
  口径同期是 298–822 MiB）。同代码 4 worker 只有 69–91 MiB，Rust 常驻 110–146 MiB。
  这与 v1 §6 出厂 auto 的 1.95–2.03 GB 同量级，是 Lua 侧选 worker 数时真正的约束。
- C=1 时 Lua auto 与 Lua 4w 完全一致（1387.7 / 1399.3），确认单请求路径与 worker 数无关。
- 「对直连」列一律借用主矩阵同格的直连基线（C=1 3689.4 / C=16 13 875.5 / stream C=16 12 372.3；
  json C=64 用主矩阵 28 731 与消融窗口 27 686 的均值 ≈ 28 200），因为 auto 组本身没跑直连行。
  C=1 那一格的直连只压了一台上游（§4），所以它的百分比只能横向比大小，不是真实达成率。

## 9. Rust 44 ms 即时流 stall 的定界（v1 §4.1 的闭合）

**定界结论：落点在 Rust 的下游（accepted）socket —— 它没有设 `TCP_NODELAY`，
最后一个小的 SSE 写被 Nagle 扣住，等客户端的延迟 ACK（本机 ~40 ms）才发出。**
上游跳（mock）已排除：本轮四个 mock 进程在起进程之前就已带 `TCP_NODELAY`
（`mock_fast.py:90-95`，文件 11:30:48 写入；mock 起于 11:33:56 / 11:47:57），
且 `--stream-batch` 把整个 body 一次 write，不产生小段序列。

决定性证据是把「客户端立刻 ACK」这一侧当开关，其余不变（C=16 keep-alive 裸 socket，交替 rep）：

| 组 | 目标 | QUICKACK | RPS | p50 | p90 | p99 | err |
|---|---|---|---:|---:|---:|---:|---:|
| `results_nagle.json` rep1 | Rust | 关 | 357.4 | 44.03 | 48.01 | 48.35 | 0 |
| `results_nagle.json` rep1 | Rust | **开（每 ~200 µs 重 arm）** | **4860.8** | **3.01** | 5.36 | 8.21 | 0 |
| `results_nagle.json` rep2 | Rust | 关 | 358.9 | 44.01 | 47.99 | 48.16 | 0 |
| `results_nagle.json` rep2 | Rust | **开** | **7245.1** | **2.04** | 3.47 | 5.13 | 0 |
| `results_nagle.json` | Lua（对照） | 关 | 9215.9 / 9379.0 | 1.61 / 1.55 | 2.36 / 2.32 | 4.36 / 4.42 | 84 / 85（裸 socket 重连计数） |
| `results_nagle.json` | mock 直连（对照） | 关 | 13 907.3 / 13 447.3 | 1.14 / 1.15 | 1.19 / 1.24 | 1.30 / 2.04 | 0 |
| `results_quickack_c.json` | Rust | 每请求 arm 一次 | 355.0 / 354.6（关）· 356.8 / 361.7（开） | 44.06 / 44.10 · 44.04 / 44.00 | 48.05 / 48.08 · 48.02 / 44.70 | 48.41 / 48.49 · 48.34 / 48.25 | 0 |

要点：

1. **忙重 arm**（每 200 µs 重设一次 `TCP_QUICKACK`）把 Rust 从 358 RPS / p50 44 ms 拉到 4861–7245 RPS / p50 2.0–3.0 ms，
   同 rep 的 Lua 与 mock 直连都不受影响 —— 客户端握手不变、mock 不变、Rust 二进制不变，只改了 ACK 时机。
2. **每请求 arm 一次无效**（`results_quickack_c.json`：开与关都是 355–362 RPS、p50 44.0）。原因是响应期间内核
   发出过一个正常 ACK 之后就把 `TCP_QUICKACK` 清了，最后一个段又落回延迟 ACK；只有持续重 arm 才压得住。
   这解释了为什么早期单 arm 版本「看起来没效果」，也正是它当时没被定界的原因。
3. **C=1 时 QUICKACK 不改变结果**（rust 1.076 → 1.122 ms，lua/mock 同样持平）：单连接没有 unacked 小包堆积，
   Nagle 不触发。这与 stall 的形状一致 —— 只在并发 ≥16 时出现。
4. **静态证据一致**：Rust 仓库里 `tcp_nodelay` 只出现在上游 reqwest client
   （`gateway/src/app_context.rs:336`，本机 `f4a25ac` 工作树同），全局没有对下游 accepted socket 的 `set_nodelay`；
   而 nginx/OpenResty 默认 `tcp_nodelay on`，这解释了 E2「同一 mock、同一写法下 Lua 毫无 stall」。
5. **v1 遗留的两个候选里，上游跳（E5）被排除**：v1 的 mock 进程起于 00:45 / 00:52，而 `TCP_NODELAY`
   那行是 01:04 才写进文件的，也就是 v1 测的那批 mock **不带** nodelay；本轮 mock 起于 11:33 / 11:47，
   文件 11:30 就已带 nodelay，**带与不带 stall 一模一样复现**，所以 stall 不依赖上游跳的 nodelay 状态。
   v1 E4「更早的 mock 构建没有 stall」因此归到 mock 的分帧/写法差异，而不是 nodelay 缺失。
6. **没有做的对照**：v1 E6（客户端每请求 `Connection: close`）在 v2 未跑；N1「大 body 撑过 MSS」的分支
   在 `res_nagle.py` 里实现了但那一轮只跑了 `pad=False`（`results_nagle.json` 8 行全部 `pad=false`），
   所以「把响应撑大让 stall 消失」这一路旁证仍是空缺（见 §11 建议 2）。
   修复动作本身（`gateway` 下游 socket 显式 `set_nodelay(true)` 后复测）也**未执行**，
   所以 §9 的表述是「已定界到客户端 ACK 依赖 + 源码缺 nodelay」，二进制的因果验证仍待补做。

生产影响：真实解码（§3 慢流两行）下 stall 不出现，Rust 与直连打平；受影响的只有「上游一次写完 SSE」
这类形态（例如聚合器把整段回答一次性 flush、或压测 mock）。

## 10. 混杂因素（读任何单个数字前先看这节）

**代码 md5 混杂。** 本轮 Lua 侧出现了三份不同的 router.lua，不能互相替代：

| md5 | 位置 | 被哪些行使用 |
| --- | --- | --- |
| `5b60aae9…` | 矩阵时刻的工作树（`ref/integration_router.lua` 快照，11:51）| 主矩阵、A/B、消融的全部 `lua` / `abl_*` 行，以及两对慢流容器（11:48 起） |
| `1d48f333…` | `lua-router:latest` 镜像内置（`ref/latest_router.lua`） | 全部 `lua_ref` 行（容器无挂载，已复核） |
| `4bc500b0…` | 12:14 之后磁盘上的工作树 | 只有 `perf2-lua-auto`（12:31:04 起）的 auto 组 |

OpenResty 默认 `lua_code_cache on`（本轮所有 conf 都未关闭它），代码在 worker 启动时加载一次；
已复核各容器的 nginx worker 进程存活时间与容器启动时间一致（4 worker 1h22m、abl 47m、ref 1h03m、auto 24m，
当前 12:55），**没有 reload**。因此 12:14 的改动只影响 auto 组，其余 Lua 行仍是 `5b60aae9…`。
推论：§8 的 auto 行与 §3/§6/§7 的 `lua` 行严格说是不同副本 —— auto 组只用于「worker 数与生产形态」的量级判断，
不与 4w 行做逐百分比差值比较。v1 的同类陷阱（出厂镜像 ≠ 工作树）在 §5 已经用 v2 内部 A/B 消掉。

**同机负载漂移。** 整轮 load1 在 **17.7–28.9**（GPU 服务 + 网关租户），单格 before/after 之差可到 ±1.5。
因此所有结论只使用「同窗口交替执行」的对比（A/B、消融、auto 都做了 rep 反向），跨窗口的绝对值只用于
说明环境未漂移（直连基线 v1 29 046 vs v2 28 731，差 1.1%）。消融首轮 load1 爬到 25–26 也一并记录在
`.contaminated.log` 里（§2 D3）。

**镜像 tag。** Rust 本轮是 `ghcr.io/yorkane/llm-router:local-vm-f4a25ac`（45 小时前构建），
与 v1 的 `:latest`（0.3.2，9-28 构建）不是同一构建；所以 v1↔v2 的 Rust 对比只当同量级参考。
Lua 侧 `authz:latest`（`908a07e62816`，只读挂载 `/repo` 的 lualib）提供 OpenResty 与 klib，`lua-router:latest`（`268960883acd`）只用于 `lua_ref`。

**RSS 口径。** `RSS` 列是宿主机 `/proc/<pid>/statm` 对各 worker 求和，共享页按进程各计一次；
`docker stats` 是 cgroup 口径，只计一次（同格 4 worker Lua：77–81 vs 25–46 MiB）。两者不能混用。

**mock 生命周期。** 55722/55723 的 pid 文件写的是 2217587/2217588，实际监听进程是 2217206/2217207
（11:33:56）—— `mock_55722.log` 里有 `Errno 98 address already in use`，说明第一次拉起失败、由后续启动覆盖。
清理阶段因此按**实际监听 pid** + pid 文件双路精确 kill（§12）。

**未跑的对照（汇总）**：Rust 补 `set_nodelay` 后的复测、大 body（pad）分支、客户端 `Connection: close`、
Lua 逐项开关消融（§7 五项）、`abl_both` 单独关 CORS 的第四组、C=128 慢流 × 消融、
`perf2-lua-slow` / `perf2-rust-slow` 的 CPU 只有 61% / 75% 时的 worker 饱和确认。

## 11. 结论与后续优化建议

**结论**

1. 非流式（json）：Rust 在同机同 mock 下吞吐上限更高、每请求 CPU 更省
   （C=64 达成率 92% / ~374–399 µs/req），Lua 4 worker 只有 41–42% 达成率，但那一格 CPU 钉在 400%，
   是 worker 数饱和；生产形态（`worker_processes auto`，144 worker）Lua 22 207 RPS / CPU 1009%，
   对 Rust 26 088 / 975% 约为 85%。
2. Lua 的每请求成本从出厂的 201–307 µs/req 涨到工作树的 333–454 µs/req（json，跨矩阵/消融/auto 三窗口），
   同格增幅 37–65%（C=64 最重）；其中**可归因的只有 CORS 预检 + 请求日志这 ~6%**，剩余 ~1.54x 尚未定责（§7 五项候选）。
   这是本轮最重要的待办：它直接决定「gap 接线要不要按开关编译掉」。
3. 真实解码流式（chunk 20 ms，C=128）三方打平（RPS 677.8–681.8，净开销 ≤0.35 ms），
   路由层在解码路径上不是瓶颈，选型不必为此格付代价。
4. 即时流式的 Rust 44 ms 已定界到**下游 socket 缺 `TCP_NODELAY`**（忙重 QUICKACK 358→4861/7245 RPS 的决定性证据 +
   源码 grep 的静态证据），与 Lua 无关；上游 mock 侧假设已排除。
5. 流式路径上工作树的连接池是净收益：µs/req 453–465 vs 出厂 481–501，且上游 mock CPU 从 180 核% 降到 87 核%。

**后续优化建议（按收益排序）**

1. **Lua 非流式成本逐项消融**：给上游连接池、`persist_response`/history、`limit`、
   per-model `policy_for`、`tokenizer`/`parse` 各加一个 env 开关，在 A/B 脚本上按单开关复跑 C=64。
   当前 1.54x 未定责 = 优化目标不明确，这一步是所有后续工作的成本地基。
2. **`gateway` 下游 accepted socket 显式 `set_nodelay(true)`**（对齐 nginx 默认），
   补跑 §9 未做的 pad 分支与 `Connection: close` 对照，把 §9 从「已定界」升到「已验证修复」。
   同时复查 Rust 慢流 rep1 的 p99 = 275.7 ms 是否随 nodelay 消失。
3. **Lua 侧 worker 数口径入文档**：压测与容量规划一律写 worker 数（生产 = `auto`），
   4 worker 的数字只用于 per-request 成本比较，避免再被读成代码结论。
4. **auto 组补测**：直连基线、rep 2、以及 `worker_processes` 取 16/32 的中间点
   （454 µs/req vs 342 µs/req 的调度代价需要一条曲线来定位最优点）。
5. **Rust 慢流尾部**：p99 在 rep 间 196.7 / 275.7 ms 摆动，需要单独复跑 2–3 rep 判定是偶发还是稳态。
6. **把 mock 的分帧写进测试夹具**：`--stream-batch` / `--stream-single` / 逐条 write 三种模式对
   Rust 的结果差一个量级，任何未来的对拍都必须显式声明用了哪一种。

## 12. 清理记录

- 容器（8 个，全部 `docker rm -f`）：`perf2-lua`、`perf2-rust`、`perf2-lua-slow`、`perf2-rust-slow`、
  `perf2-lua-ref`、`perf2-lua-abl1`、`perf2-lua-abl2`、`perf2-lua-auto`。
- mock：pid 文件里 55732/55733（2255887 / 2255888）直接 `kill`；55722/55723 的 pid 文件已失效
  （写的是 2217587 / 2217588，进程早退），改按 `ss -ltnp` 取实际监听 pid（2217206 / 2217207）精确 `kill`。
  未使用 `pkill`。清理后 `ps` 无 `mock_fast.py` 残留，5572x/5573x 端口全部释放。
- 生产服务验证（只读 curl，清理后）：`http://127.0.0.1:8800/health` = 200、`/v1/models` = 200、
  `http://127.0.0.1:8080/` = 200；`docker ps -a` 无 `perf2-*` 残留。
- 数据目录保留在 `/data/tmp/parity/perf-v2/`（原始 JSON、conf 副本、代码快照 `ref/`、逐轮日志），
  仅关闭进程。
