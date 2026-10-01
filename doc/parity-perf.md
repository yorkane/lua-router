# lua-router vs Rust llm-router 性能对拍（perf）

对拍日期 2026-09-29 ~ 09-30。数据目录 `/data/tmp/parity/perf/`（原始 JSON、逐轮日志、
压测脚本、各实例 conf）。本报告只覆盖**吞吐/延迟/资源**，行为契约见
[parity-contract.md](parity-contract.md)，
路由策略见 [parity-routing.md](parity-routing.md)。

> **状态**：数据有效，**§4.1 归因未闭合**（stall 未定界，E5/E6 两个决定性对照都没跑完）。
> **日期**：对拍 2026-09-29 ~ 09-30，状态复核 2026-09-30（UTC）。
> **证据强度**：B（`/data/tmp/parity/perf/` 原始 JSON；json 只取 rep1、stream 取两 rep 中位数；
> 脏 mock 的 A/B/C/F 组只作方法论证据，不进任何结论）。
>
> 两条最容易被误读的事实，放在最前面：
> 1. Lua 行测的是**工作树**（含 parity-contract 那批未提交的 router.lua 修复），
>    T6 出厂镜像不含 —— 两者差异不能全归因到 worker 数。
> 2. 「Lua 吞吐只有 Rust 的 60%」是**单 worker** 数出来的（1w 被钉在一核 4.6k）；
>    出厂 `worker_processes auto` 下 Lua 24.6k vs Rust 25.7k（C=64 json），同一档。
>
> 与当前代码的关系：本轮基线的 router.lua（md5 `c96b6556…`）与 perf 所测路径一致；
> `set_top_field` 的整数分支 bug 当时就存在，但 perf 的 body 不带 `max_tokens`、策略是
> round_robin，所以本报告结论不受它影响。

## 0. 结论摘要

| 维度 | 结论 | 依据 |
| --- | --- | --- |
| 非流式（json）吞吐 | 单 worker 的 Lua 被钉在一核（4.5–4.6k RPS），**4 worker 才追平量级**：C=64 Rust 25.6k vs Lua4 17.1k；**出厂镜像（worker_processes auto）Lua 24.6k ≈ Rust 25.7k** | T1 / T6 |
| 非流式净开销 | p50 增量都很小：C=1 Lua +0.31 / Rust +0.37；C=64 Lua4 +1.54 / Rust +0.33（Lua 1w 因单核排队 +11.70） | T2 |
| 真实解码流式（chunk 间隔 20ms） | **无可测差异**：C=128 四目标 RPS 677.9/679.4/679.2/679.8，p50 全部 187 ms（差 <1%） | T5 |
| 即时流式（mock 一次写完） | Rust 出现恒定 ~44 ms/响应 的固定 stall（23–1.4k RPS），Lua 不受影响；机制与取证见 §4.1，未定界 | T1 stream 行 |
| 每请求 CPU | **Lua 更省**：json 216–328 µs/req vs Rust 364–399 µs/req；Rust 靠更多核换更高吞吐上限 | T4 |
| 每请求上游 CPU | 非流式同量级（直连 58–80 / Lua4 76–117 / Rust 68–112 µs）；**流式直连 78–160 → Lua 200–441 → Rust 125–190 µs/req**，因 Lua 流式路径每请求重连上游 + 每 chunk 一次 flush | T4、§5 |
| 内存 | Lua 1w 26–27 MiB、4w 70–74 MiB（≈14 MiB/进程）、出厂 auto 145 进程 1.95 GB；Rust 45–110 MiB（146 线程常驻） | T1 / T6 |
| 错误 | 权威矩阵全部 err=0（整矩阵 ≈4.0 M 请求，C=64 档 ≈2.4 M） | T1 |

一句话：**非流式下 Rust 吞吐上限更高但每请求 CPU 更贵，Lua 必须开多 worker 才不掉队（出厂配置已默认如此）；
低并发（C=1）两侧 p50 净开销 0.31 / 0.37 ms，高并发时 Lua4 +1.54 vs Rust +0.33 ms；
带真实 chunk 节流的流式（最接近生产解码）四目标完全打平，RPS/p50 差 <1%、净开销 0.2–1.6 ms。**

## 1. 环境与口径

- 机器：本机 <dev-box>，144 逻辑核；同机有 GPU 服务与网关租户（收尾时 loadavg 8–10，见 §8）。
- 镜像：Rust `ghcr.io/yorkane/llm-router:latest`（构建 2026-09-28，`gateway/Cargo.toml` version 0.3.2）；
  Lua `authz:latest`（openresty/1.31.1.1）+ 只读挂载本仓库 `/repo` 直读工作树 lualib（git f4a25ac，
  **契约对拍那批 router.lua 修复尚未提交**，所以 Lua 行测的是工作树代码）；
  另用发布镜像 `lua-router:latest` 单独跑一组出厂配置（§6）。
- 上游 mock：`mock_fast.py`（asyncio 单进程，手写 HTTP/1.1，响应体与仓库
  `test/mock_llm_worker.py` 一致）。**每组用独立 mock 实例，行与行之间不共享上游**。
  注意它当前的 `TCP_NODELAY` 是在 01:04 才加进文件的，T1/T6 用的实例（00:29 / 00:45 起）
  不带该改动——这影响 §4.1 的归因，见 E5。
- 实例与端口（`--network host`）：

| 用途 | Lua 实例（端口） | Rust 实例（端口） | 上游 mock |
| --- | --- | --- | --- |
| 权威矩阵（§3） | perf-lua-f1 43800（1w）、perf-lua-f4 43810（4w） | perf-rust-f 43820 | 43241/43242（`--stream-batch`） |
| 慢流式（§4） | perf-lua-s1 43500、perf-lua-s4 43600 | perf-rust-s 43510 | 43211/43212（`--chunk-ms 20 --chunk-count 10`） |
| 出厂配置（§6） | perf-lua-def 43700（`worker_processes auto` → 145 进程） | perf-rust-f | 43201/43202 |
| 早期矩阵（§3 附） | perf-lua2 43300、perf-lua4 43400 | perf-rust2 43310 | 43201/43202 |
| 父级实例（本报告未取数） | perf-lua 43100 | perf-rust 43110 | 43101/43102（仓库脏 mock） |

- 策略两侧 round_robin；健康检查各自默认口径（Lua `SMG_HEALTH_CHECK_INTERVAL_SECS=1`，
  Rust `--health-check-interval-secs 2`，endpoint `/health`）。
- 请求：`POST /v1/chat/completions`，body `{"model":"test-model","messages":[{"role":"user","content":"hi"}]}`，
  流式加 `"stream":true`。每格 15 s 闭环，客户端每连接 keep-alive。
- 目标交替执行（mockpair→lua→lua4→rust 轮序），跨轮取**中位数**。
- **数据有效性**：`results_final.json` 共 48 行 = 2 rep × 24 格。**rep2 的 12 行 json 全部 rps=0
  （warm-up 未通过，驱动直接返回 503 占位，见 `run_final.log` 第 25–36 行），故 json 只取 rep1**；
  stream 两个 rep 均有效，取中位数。`run_final2.log` 是随后被中止的重复运行（lua 行 err=77287、
  rust 行 cpu=-2267 等明显异常），**未写入 JSON，不参与任何结论**。

## 2. 测量学发现（先看这节，否则数字会被误读）

| # | 现象 | 处理 |
| --- | --- | --- |
| M1 | 仓库自带 `test/mock_llm_worker.py`（ThreadingHTTPServer）在**客户端复用连接**时给几乎每个响应扣 ~44 ms：A 组直连该 mock，C=1 只有 22 RPS / p50 44.0，C=16 356 / 44.1，C=64 1376 / 46.3；同一 mock 换客户端短连接（C 组）立刻回到 1173 RPS / p50 0.83、1607 / 2.43。形状是典型的 Nagle × 延迟 ACK 交互（机制未单独定界，能定界的是「只在连接复用时出现」） | 换 `mock_fast.py`（asyncio，每响应一次 write + 明确 Content-Length），A/B/C/F 组废弃。`results_abc.json` / `results_f.json` / `results_clean.json` 只作方法论证据，**不作性能结论** |
| M2 | 该伪影专门惩罚**复用上游连接**的一方：Rust（reqwest 连接池）在脏 mock 下 313 RPS，而 Lua 流式每请求新建上游连接，反而 1179 RPS（B 组）。同理 C 组短连接下 Lua/Rust 掉到 38 RPS 而直连 1173 RPS | 同一格内两侧必须走同一 mock 同一模式，否则结论反向 |
| M3 | **单进程 python 客户端自限 ~6.9k RPS**（闭环）：`client_ceiling.json` 1 proc 6855 / 2 proc 13425 / 4 proc 27707。因此早期 C=16/64 所有目标都挤在 5–7k，完全分不出 router 差距（`tables.md` 上半段） | 总并发守恒地拆成 2/4 个客户端进程（C=16→2×8，C=64→4×16），RPS 求和、延迟取中位数 |
| M4 | `docker stats` 在 144 核机上把 router CPU 显示成 0.0–1.8%，读数无意义（`tables.md` A 组、`run_clean.log` 的 `cpu=0.1`） | 改读 `/proc/<pid>/stat` 的 utime+stime（含 worker 子进程）折算**占单核%**，RSS 取 `statm` |
| M5 | 上游 mock 的 CPU 与 router 强相关（见 T4 的 mock µs/req 列）：非流式三目标同量级（直连 58–80 / Lua4 76–117 / Rust 68–112）；流式直连基线 78–160，Lua 路径 200–441，Rust 路径 125–190 | 每格同时采 mock 进程 CPU，把「上游成本」与「router 成本」分开列（T4），避免把 mock 的额外开销记到 router 头上 |
| M6 | 即时 SSE（mock 一次写完全部事件）会让 Rust 落入 44 ms/响应平台，掩盖 router 自身开销；带 20 ms chunk 节流后该 stall 消失 | 流式结论以 §4 慢流式组为准；即时流式组单列并在 §4.1 取证 |

## 3. 权威矩阵（T1）

数据 `results_final.json`；RPS 为多客户端进程合计；延迟单位 ms；CPU 为 router 容器合计占单核%；
上游 mock CPU 为该格参与 mock 的合计占单核%。

| 模式 | 并发 | 目标 | RPS | p50 | p90 | p99 | 错误 | router CPU | RSS(MiB) | 线程 | 上游 mock CPU | 样本 |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| json | 1 | mock 直连（双实例） | 3703 | 0.26 | 0.30 | 0.36 | 0 | — | — | — | 29.6 | 1 |
| json | 1 | Lua 1 worker | 1645 | 0.57 | 0.71 | 1.07 | 0 | 53.9 | 26.4 | 2 | 18.7 | 1 |
| json | 1 | Lua 4 worker | 1633 | 0.57 | 0.72 | 1.15 | 0 | 52.7 | 66.4 | 5 | 19.1 | 1 |
| json | 1 | Rust router | 1548 | 0.63 | 0.73 | 0.84 | 0 | 56.4 | 44.6 | 147 | 17.4 | 1 |
| json | 16 | mock 直连（双实例） | 13230 | 1.14 | 1.40 | 1.66 | 0 | — | — | — | 92.3 | 1 |
| json | 16 | Lua 1 worker | 4548 | 3.18 | 4.67 | 5.40 | 0 | 99.9 | 26.7 | 2 | 40.5 | 1 |
| json | 16 | Lua 4 worker | 11705 | 1.25 | 2.08 | 3.42 | 0 | 330.1 | 70.1 | 5 | 93.6 | 1 |
| json | 16 | Rust router | 12310 | 1.26 | 1.60 | 1.94 | 0 | 465.0 | 61.4 | 146 | 97.1 | 1 |
| json | 64 | mock 直连（双实例） | 29046 | 2.08 | 2.47 | 3.00 | 0 | — | — | — | 167.4 | 1 |
| json | 64 | Lua 1 worker | 4627 | 13.77 | 15.05 | 17.41 | 0 | 100.0 | 27.4 | 2 | 40.0 | 1 |
| json | 64 | Lua 4 worker | 17080 | 3.61 | 5.29 | 6.86 | 0 | 399.7 | 71.3 | 5 | 129.3 | 1 |
| json | 64 | Rust router | 25575 | 2.40 | 3.24 | 4.07 | 0 | 1020.0 | 106.3 | 146 | 174.5 | 1 |
| stream | 1 | mock 直连（双实例） | 2981 | 0.33 | 0.39 | 0.46 | 0 | — | — | — | 47.6 | 2 |
| stream | 1 | Lua 1 worker | 976 | 0.97 | 1.15 | 1.38 | 0 | 52.4 | 27.4 | 2 | 43.0 | 2 |
| stream | 1 | Lua 4 worker | 942 | 1.00 | 1.20 | 1.49 | 0 | 55.5 | 72.8 | 5 | 40.8 | 2 |
| stream | 1 | Rust router | **23** | **43.99** | 47.99 | 48.05 | 0 | 2.2 | 107.7 | 146 | 17.2 | 2 |
| stream | 16 | mock 直连（双实例） | 12058 | 1.23 | 1.54 | 1.86 | 0 | — | — | — | 112.8 | 2 |
| stream | 16 | Lua 1 worker | 2561 | 6.80 | 8.82 | 10.48 | 0 | 99.7 | 27.4 | 2 | 79.8 | 2 |
| stream | 16 | Lua 4 worker | 7926 | 1.85 | 2.96 | 4.25 | 0 | 342.1 | 72.6 | 5 | 188.9 | 2 |
| stream | 16 | Rust router | **358** | **44.02** | 48.00 | 48.38 | 0 | 21.4 | 108.2 | 147 | 6.8 | 2 |
| stream | 64 | mock 直连（双实例） | 24716 | 2.55 | 2.90 | 3.44 | 0 | — | — | — | 193.7 | 2 |
| stream | 64 | Lua 1 worker | 2491 | 30.27 | 34.91 | 39.20 | 0 | 99.7 | 27.4 | 2 | 76.8 | 2 |
| stream | 64 | Lua 4 worker | 9833 | 6.12 | 10.18 | 14.28 | 0 | 384.5 | 73.5 | 5 | 196.4 | 2 |
| stream | 64 | Rust router | **1439** | **44.02** | 47.64 | 48.54 | 0 | 74.0 | 109.2 | 147 | 18.1 | 2 |

流式三行的 TTFB：mock 直连 1.23/2.55（C=16/64），Lua 1w 6.78/30.26，Lua4 1.84/6.11，
Rust **1.08/0.98（TTFB 正常）**但总延迟 p50 44.02；44 ms 的落点见 §4.1。

C=1 另有独立复测组（单客户端进程即可，`results_c1.json`）：json Lua 1485 / Lua4 1517 / Rust 1405，
p50 0.63 / 0.62 / 0.69；stream Lua 886 / 894 / Rust 1003，p50 1.05 / 1.05 / 1.00。
这一组的 Rust 流式没有 stall，与 T1 差一个量级，差别只来自 mock 的写法版本（§4.1 E4）。
T1 的 json/stream 量级与此组一致。

### 3.1 净开销（T2，router p50 − 直连 p50，ms）

| 模式 | 并发 | 直连 p50 | Lua 1w | Lua 4w | Rust |
|---|---:|---:|---:|---:|---:|
| json | 1 | 0.26 | **+0.31** | **+0.31** | **+0.37** |
| json | 16 | 1.14 | **+2.03** | **+0.10** | **+0.11** |
| json | 64 | 2.08 | **+11.70** | **+1.54** | **+0.33** |
| stream | 1 | 0.33 | **+0.64** | **+0.67** | +43.66（stall，见 §4） |
| stream | 16 | 1.23 | **+5.57** | **+0.61** | +42.79（同上） |
| stream | 64 | 2.55 | **+27.72** | **+3.56** | +41.47（同上） |

### 3.2 吞吐达成率（T3，对同格直连基线）

| 模式 | 并发 | Lua 1w | Lua 4w | Rust |
|---|---:|---:|---:|---:|
| json | 1 | 44% | 44% | 42% |
| json | 16 | 34% | 88% | 93% |
| json | 64 | 16% | 59% | 88% |
| stream | 1 | 33% | 32% | 1%（stall） |
| stream | 16 | 21% | 66% | 3%（stall） |
| stream | 64 | 10% | 40% | 6%（stall） |

### 3.3 每请求 CPU（T4，µs/req；router 自身与上游 mock 分开）

| 模式 | 并发 | router：Lua 1w | Lua 4w | Rust | 上游 mock：直连 | Lua 1w | Lua 4w | Rust |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| json | 1 | 328 | 323 | 364 | 80 | 114 | 117 | 112 |
| json | 16 | 220 | 282 | 378 | 70 | 89 | 80 | 79 |
| json | 64 | 216 | 234 | 399 | 58 | 86 | 76 | 68 |
| stream | 1 | 537 | 589 | —（被 stall 摊薄） | 160 | 441 | 433 | — |
| stream | 16 | 389 | 432 | —（同上） | 94 | 312 | 238 | 190 |
| stream | 64 | 400 | 391 | —（同上） | 78 | 309 | 200 | 125 |

非流式（C=16/64）：**Lua 每请求 CPU 只有 Rust 的 0.6–0.8 倍**（Lua4 234–323 vs Rust 364–399 µs），但 Rust 在 C=64 用 ~2.5 倍核心数（1020% vs 400% 单核）把吞吐顶到 25.6k。
流式的 Rust 列因吞吐被 stall 压到 1/30，router µs/req 无意义；这一组里可比的是上游 mock 侧成本（直连 78–160 / Lua 200–441 / Rust 125–190 µs/req，其中 Lua 的高值来自每请求重连上游）。

## 4. 慢流式（T5）—— 最接近生产解码的一组

mock 每 SSE chunk 间隔 20 ms × 10 delta（≈11 条记录，总响应 ~187 ms），
数据 `results_slowstream.json` / `run_slow3.log`，C=16/64/128 分别用 2/4/8 个客户端进程。

| 并发 | 目标 | RPS | p50 | p99 | TTFB p50 | TTFB p99 | 错误 | router CPU | RSS(MiB) | 线程 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 16 | mock 直连 | 85.5 | 186.9 | 190.5 | 1.61 | 3.67 | 0 | — | — | — |
| 16 | Lua 1w | 84.7 | 188.6 | 192.1 | 2.10 | 5.95 | 0 | 7.3 | 28.6 | 2 |
| 16 | Lua 4w | 84.8 | 188.4 | 191.7 | 2.14 | 4.38 | 0 | 8.8 | 70.2 | 5 |
| 16 | Rust | 84.8 | 188.7 | 191.2 | 2.60 | 4.35 | 0 | 10.6 | 49.2 | 146 |
| 64 | mock 直连 | 338.9 | 187.3 | 191.9 | 1.42 | 5.42 | 0 | — | — | — |
| 64 | Lua 1w | 338.8 | 187.4 | 196.8 | 1.54 | 10.75 | 0 | 25.2 | 29.1 | 2 |
| 64 | Lua 4w | 340.3 | 187.9 | 193.0 | 1.75 | 6.64 | 0 | 30.1 | 71.7 | 5 |
| 64 | Rust | 338.3 | 187.1 | 231.8 | 1.78 | 46.22 | 0 | 38.7 | 61.3 | 147 |
| 128 | mock 直连 | 677.9 | 187.2 | 194.3 | 1.39 | 6.59 | 0 | — | — | — |
| 128 | Lua 1w | 679.4 | 186.9 | 204.8 | 1.84 | 18.58 | 0 | 48.1 | 30.3 | 2 |
| 128 | Lua 4w | 679.2 | 187.2 | 193.9 | 1.69 | 7.44 | 0 | 56.5 | 73.9 | 5 |
| 128 | Rust | 679.8 | 187.1 | 194.0 | 1.89 | 9.01 | 0 | 76.3 | 82.0 | 147 |

四个目标在三个并发档上 RPS 与 p50 全部对齐到 1% 以内，err=0。
**真实解码节律下两个 router 都无可测开销**（相对直连 p50 净增 0.2–1.6 ms，主要落在 TTFB 那一跳）。
Rust 的 44 ms stall 在这里完全不出现；C=64 那格 p99 231.8 / TTFB p99 46.2 是偶发单点，非系统项。
资源上 Lua 4w 用 56.5% 单核，Rust 用 76.3%。

### 4.1 即时流式 stall 的取证（未定界）

现象：mock 把整个 SSE body 一次写完时，Rust 每响应固定 ~44 ms（p50 44.0、p99 48.0，
与并发无关，CPU 只用 2–74% 单核，err=0）。并发 ≥16 时 TTFB 正常（1.08 / 0.98 ms）、
44 ms 落在首字节之后；**C=1 时连 TTFB 都是 43.99 ms**，即首个事件就被扣住。Lua 同场景 1.0–6.8 ms。

| 证据 | 内容 | 数据 |
| --- | --- | --- |
| E1 | 与 mock 的**分帧方式**无关：`--stream-single`（整个 body 一条 chunked 记录）与 `--stream-batch`（多条记录一次 write）下 Rust 都是 23–24 RPS / p50 43.99；Lua 同一组里都是 940–965 RPS / p50 ~0.97 | `results_framing.json` |
| E2 | 只有 Rust 中招：同一 mock、同一写法下 Lua 流式路径（每请求新建上游连接，首写立即发出）毫无 stall | `results_final.json` stream 行、`results_framing.json` |
| E3 | Rust 仓库里 `tcp_nodelay(true)` 只出现在**上游 reqwest client**（`gateway/src/app_context.rs:336`），全局 grep 没有对下游 accepted socket 的 `set_nodelay`；而 nginx 默认 `tcp_nodelay on` | 源码 grep |
| E4 | 更早的 mock 构建（43201/43202，00:09 与 00:25 两轮）跑同样的即时流式，Rust **没有** stall：C=16 5922 RPS / p50 2.62，C=64 13073 RPS / p50 4.81（同格 Lua4 8208 / 10367），C=1 甚至 1003 RPS / p50 1.00。也就是说 stall 随 mock 的一次改写而「出现」，但 `mock_fast.py` 是就地改写的，旧版本没有留存，无法逐字对比差异 | `results_multiproc.json`、`run_res3.log`、`results_c1.json` |
| E5 | **上游侧 Nagle 没有被形式排除**：mock 的流式响应分两次 write（先响应头再 body，`mock_fast.py:115-131`），而给 accepted socket 加 `TCP_NODELAY` 的这一行是 01:04 才写进文件的；T1 用的 43241/43242 起于 00:45、framing 组用的 43261 起于 00:52，进程里都没有这个改动。为排除它专门起了 43251/43252（01:06 起）+ `res_nodelay.py`，但那一轮在写 JSON 之前被中止，`results_nodelay_stream.json` 至今不存在 | `ls`/`ps` 时间戳、缺失的输出文件 |
| E6 | 原计划的第二个对照——客户端每请求 `Connection: close`——脚本 `res_close.py` 因驱动签名不兼容报错（`TypeError: run() got an unexpected keyword argument 'force_close'`），**该对照组没有数据** | `run_close.log` |

推断（**标注为假设，不是结论**）：~44 ms 的形状是「小写遇到延迟 ACK」的典型值，但候选有两跳——
一是 mock 自己把响应头与 body 分两次 write（E5，上游跳），二是 Rust 把每个 SSE 事件单独写向客户端
（E3，下游跳）。E2/E3 更偏向下游跳，E4 又说明它是被上游的一次改写「触发」的，两个方向都没排掉。
两个决定性对照（带 `TCP_NODELAY` 的 mock 复测 E5、客户端每请求 `Connection: close` 复测 E6）
都没做完，所以本节只把现象与量级写清楚，不做归因。生产经真实网络（RTT > 0、真实 chunk 间隔几十 ms，
§4 已验证 stall 不出现）预期影响很小；要定界需要补：给 `gateway` 下游 socket 显式
`set_nodelay(true)` 复测、把 mock 的 header/body 合成一次 write 复测、客户端短连接复测。

## 5. 两侧实现差异导致的可测代价

| 项 | Lua（router.lua 工作树） | Rust | 观测 |
| --- | --- | --- | --- |
| 上游连接复用 | 非流式 `setkeepalive`（router.lua:1140），流式路径读完即 `sock:close()`（router.lua:938） | reqwest 连接池，两种模式都复用 | 流式每请求上游 CPU：Lua1w 309–441 / Lua4 200–433 µs vs Rust 125–190 µs，直连基线 78–160 µs（T4） |
| 并行模型 | 多 worker 进程 + 共享字典游标（round_robin 跨进程不退化，见 parity-routing #1b） | 单进程 146 线程 | 单 worker Lua C=64 被钉在 100% 单核 → 4.6k；4 worker 17.1k；auto（145 进程）24.6k |
| 转发方式 | `ngx.print` + `ngx.flush(true)` 逐块（router.lua:884） | hyper body stream | 流式下 mock 侧 µs/req 从直连 78–160 涨到 Lua 路径 200–441（每 chunk 唤醒 + 每请求重连），Rust 路径 125–190 |
| 内存 | 1w 26 MiB（master+worker）、4w 71 MiB（≈14 MiB/进程）；auto 145 进程 → 1.95 GB | 45–110 MiB 常驻（含 146 线程栈） | T1 / T6 |

## 6. 出厂镜像配置（T6）

发布镜像 `lua-router:latest` 的 entrypoint 渲染 `worker_processes auto`（容器内 145 个 nginx 进程），
这是**部署时真正会跑到的形态**；其 `luarouter` 是镜像内副本，与工作树不同（对拍修复未提交）。
数据 `results_default_workers.json` / `run_def.log`，上游 mock 43201/43202（per-record write）。

| 模式 | 并发 | 目标 | RPS | p50 | p99 | TTFB p50 | 错误 | router CPU | RSS(MiB) | 线程 |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| json | 16 | mock 直连 | 13585 | 1.12 | 1.69 | — | 0 | — | — | — |
| json | 16 | Lua 出厂（auto） | 12616 | 1.21 | 2.04 | — | 0 | 403.3 | 1954 | 145 |
| json | 16 | Rust | 12716 | 1.18 | 1.97 | — | 0 | 463.2 | 126 | 146 |
| json | 64 | mock 直连 | 28760 | 2.12 | 2.95 | — | 0 | — | — | — |
| json | 64 | Lua 出厂（auto） | 24607 | 2.49 | 4.42 | — | 0 | 661.0 | 1967 | 145 |
| json | 64 | Rust | 25657 | 2.37 | 3.74 | — | 0 | 1020.6 | 129 | 147 |
| stream | 16 | mock 直连 | 11947 | 1.31 | 1.78 | 1.30 | 0 | — | — | — |
| stream | 16 | Lua 出厂（auto） | 7297 | 1.98 | 4.68 | 1.98 | 0 | 401.6 | 2016 | 145 |
| stream | 16 | Rust | 357 | 44.02 | 48.45 | 1.08 | 0 | 22.0 | 128 | 146 |
| stream | 64 | mock 直连 | 21918 | 2.81 | 4.90 | 2.81 | 0 | — | — | — |
| stream | 64 | Lua 出厂（auto） | 9935 | 6.01 | 15.38 | 5.99 | 0 | 568.4 | 2032 | 145 |
| stream | 64 | Rust | 1440 | 44.02 | 48.62 | 1.05 | 0 | 81.2 | 127 | 147 |

非流式出厂 Lua 与 Rust 基本同档（C=16 99.2%、C=64 95.9% 的 RPS），
p50 差 0.03–0.12 ms，且 Lua 每请求 CPU 更低（319 / 269 µs vs 364 / 398 µs）。
流式两行 Rust 同样受 §4 stall 支配，不可与 Lua 直接比大小。

## 7. 资源占用汇总

| 目标 | 进程/线程 | RSS | C=16 CPU | C=64 CPU | 备注 |
| --- | --- | --- | ---: | ---: | --- |
| Lua 1 worker | 2 进程 | 26–27 MiB | 99.9% 单核（饱和） | 100.0%（饱和） | 单核是硬上限 |
| Lua 4 worker | 5 进程 | 70–74 MiB | 330% | 400% | 未饱和 |
| Lua 出厂 auto | 145 进程 | 1.95–2.03 GB | 403% | 661% | RSS ≈ 13.5 MiB/进程 × 145 |
| Rust router | 1 进程 / 146–147 线程 | 45–110 MiB | 437–465% | 930–1020% | 高并发时吃核最猛 |

## 8. 局限性

1. **上游是 python mock**：mock 进程自身在 C=64 时占用 83–99% 单核，吞吐上限部分由 mock 决定，
   直连基线 29k RPS 不是真实 worker 的上限；因此「达成率」只能横向比较，不代表绝对容量。
2. **单机 loopback**：router 与客户端、上游同机，跨机 RTT、网卡、TLS 握手、连接数上限全部缺席；
   §4.1 的 stall 只在 loopback 上出现过，换真实网络（RTT > 0、chunk 有真实间隔）预期不出现，
   但本轮无法证明，慢流式组只是没有再观察到它。
3. **共享盒**：<dev-box> 上有 GPU 服务与网关租户，背景 loadavg 8–10；已用交替执行 + 多 rep 中位数压漂移，
   但 json 只有 rep1 有效（见 §1 数据有效性），单 rep 格子的 ±5% 抖动需要保留判断。
4. **客户端预算**：python 客户端闭环上限 ~6.9k RPS/进程（M3），C=64 用 4 进程；
   Rust 的 25.6k 已接近 mock+客户端合计可达的 29k，因此 Lua/Rust 的 C=64 差距可能小于真实差距。
5. **只测 round_robin**：cache_aware / prefix_hash 的每请求开销不同（Lua 的树维护与 shared dict 写回），未覆盖。
6. **Lua 行混用两个来源**：T1/T5 用工作树（含未提交的对拍修复），T6 用发布镜像（不含）；
   两者 CPU 差异不能直接归因到 worker 数以外的因素。
7. **健康检查口径不同**（Lua 1 s / Rust 2 s），以及 15 s 窗口不足以观测 breaker/backoff 的长时行为。
8. **§4.1 未定界**：两个决定性对照都没有数据——带 `TCP_NODELAY` 的上游 mock 复测（E5）在写 JSON 前被中止，
   客户端短连接对照（E6）脚本失败；「Rust 下游 socket 未设 TCP_NODELAY」目前只有源码 grep 与时序推断支撑。
9. 报告生成时按父级指令中止了重复运行（`run_final2.log` 半途中断、`res_close.py` 报错），
   这两份日志只用于说明口径调整过程，数据未采用。

## 9. 复现

```bash
cd /data/tmp/parity/perf
# 无伪影 mock（每响应一次 write；--stream-batch/--stream-single/--chunk-ms 控制 SSE 写法）
for p in 43241 43242; do python3 mock_fast.py --port $p --stream-batch >/dev/null 2>&1 & done
# Lua：conf 由 test/conf/nginx-lua-router.conf 改 listen + worker_processes 后放 /perfconf
docker run -d --name perf-lua-f1 --network host -v /data/tmp/parity/perf:/perfconf:ro \
  -v /path/to/lua-router:/repo:ro -e SMG_HEALTH_CHECK_INTERVAL_SECS=1 authz:latest \
  -p /usr/local/openresty/nginx/ -c /perfconf/lua-perf-f1.conf -g daemon off;
# Rust：--prometheus-port 必须显式给未占用端口（默认 29000 与 <dev-box>:8800 生产实例冲突会 panic）
docker run -d --name perf-rust-f --network host ghcr.io/yorkane/llm-router:latest launch \
  --host 0.0.0.0 --port 43820 --prometheus-port 43990 --policy round_robin \
  --worker-urls http://127.0.0.1:43241 http://127.0.0.1:43242 \
  --health-check-interval-secs 2 --health-check-endpoint /health
curl -s http://127.0.0.1:43800/readiness          # 200 后再压
# Lua 实例的 worker 需要 POST /workers 注册（Rust 走 --worker-urls 自动发现）
python3 res_final.py > run_final.log 2>&1         # 权威矩阵（含 CPU/RSS/threads）
python3 res_probe6.py > run_slow3.log 2>&1        # 慢流式
python3 res_probe7.py > run_def.log 2>&1          # 出厂配置
python3 res_frame.py > /dev/null 2>&1             # stall 分帧取证（E1）
python3 mkreport_final2.py > T_final.md           # 本报告 T1–T6 全部表格
python3 mkfinal.py > tables_final.md              # 早期口径的汇总表
```

两个待补的对照（§4.1 定界用，脚本已就位、没跑完）：`res_nodelay.py`（mock 带 `TCP_NODELAY`）、
`res_close.py`（客户端每请求 `Connection: close`，需要给 `res_probe3.run()` 加 `force_close` 形参）。

驱动 `res_probe3.py`：N 个客户端子进程共享总并发（`--worker <target> <port> <per_proc_conc> <dur> <stream>`），
父进程用 `/proc/<pid>/stat` 与 `statm` 在**测量窗口两端**取差分，避免 warm-up 稀释 CPU。

原始数据（全部在 `/data/tmp/parity/perf/`）：

| 文件 | 内容 |
| --- | --- |
| `results_final.json` / `run_final.log` | 权威矩阵 T1–T4（本报告主数据） |
| `results_slowstream.json` / `run_slow3.log` | 慢流式 T5 |
| `results_default_workers.json` / `run_def.log` | 出厂配置 T6 |
| `results_multiproc.json`、`results_c1.json`、`results_repeat.json` | 早期矩阵、C=1 复测、2-rep 重复性 |
| `results_framing.json` | stall 分帧取证（E1） |
| `client_ceiling.json` | 客户端自限（M3） |
| `resources.json`、`resources_worker4.json` | 单客户端口径下的 CPU/RSS/线程 |
| `results_abc.json`、`results_f.json`、`results_clean.json` | 脏 mock 组：仅方法论证据（M1/M2） |
| `bench.py`、`bench_clean.py`、`res_probe*.py`、`res_final.py`、`mock_fast.py`、`lua-perf*.conf` | 压测器与实例配置 |
| `T_final.md`、`mkreport_final2.py` | 本报告表格的生成结果与脚本 |
| `run_final2.log`、`run_close.log` | 中止/报错的对照组（数据未采用） |

## 10. 遗留实例与清理

本报告数据已采集完毕，以下实例是本对拍新建的，可直接回收
（**父级管理的 perf-lua 43100 / perf-rust 43110 与 mock 43101、43102 不在其中，不要动**）：

```bash
docker rm -f perf-lua2 perf-lua4 perf-rust2 perf-lua-s1 perf-lua-s4 perf-rust-s \
             perf-lua-def perf-lua-f1 perf-lua-f4 perf-rust-f
kill 4157929 4157968 4147521 4147963 21159 21481 21679 38606 68606 68623   # mock_fast 43201/43202/43211/43212/43221/43241/43242/43261/43251/43252
```

pid 以 `ps -eo pid,args | grep mock_fast.py` 实时结果为准（上表按 2026-09-30 01:12 快照）。
