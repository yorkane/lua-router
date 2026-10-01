# lua-router vs Rust llm-router 路由行为对拍（policy-extra：prefix_hash / bucket / power_of_two / random）

对拍日期 2026-09-30。承接 [parity-routing.md](parity-routing.md)
里「未覆盖」那一节：round_robin / consistent_hashing / manual / cache_aware 已在上一轮量化过，
本轮补齐剩下的四个策略。比较的是**行为特性**（粘滞性、分桶边界、负载逃逸、均匀性），
不是逐次选中同一个 worker —— prefix_hash 两侧哈希对象不同（Lua blake3 over 前 N 个字符 vs
Rust xxh3 over 前 N 个 token），bucket / power_of_two 的状态也各自独立演化。

> **证据强度**：B（`/data/tmp/parity/policy-extra/` 的 harness 与原始 JSON `t1..t5*.json`、
> `e2e_policy_parity.json`）；门禁化版本
> [test/integration/e2e_policy_parity.py](../test/integration/e2e_policy_parity.py)。
> 本轮**未改动 router/policies 实现**：唯一的行为分歧（power_of_two 无 loads 退化）出在 Rust 侧，
> 属于上游行为，记录而非修改。

## 结论摘要

| # | 策略 | 指标 | Lua | Rust | 判定 |
| --- | --- | --- | --- | --- | --- |
| 1 | prefix_hash | 同前缀 10 次是否恒定同 worker | 10/10 粘滞 | **HTTP 面不可用**（恒 503） | 只能单边验证 |
| 1 | prefix_hash | 前缀截断（只取前 32 字符） | 成立，尾部不同不改落点 | — | 单边 |
| 1 | prefix_hash | 300 distinct 前缀分布 | 每桶份额 0.27~0.39，χ² 0.14~7.62（环落点抖动） | — | 不塌缩 |
| 1 | prefix_hash | 60/48 key 摘 1 worker | moved=全部来自被摘 worker，**collateral 0**，ratio 0.29~0.38≈1/3 | — | 与 consistent_hashing 同环语义 |
| 1 | prefix_hash | 恢复 worker 后回切 | **48/48 回原落点**（环可重建） | — | 单边 |
| 1 | prefix_hash | 空路由文本 | 503 `no_available_workers`（NoTokens 分支） | 503 `no_available_workers` | **分支语义一致** |
| 2 | bucket | `--policy bucket` CLI | `SMG_POLICY=bucket` 直接生效 | clap 拒绝（无入口） | **Rust 不可选，权威结论** |
| 2 | bucket | 静态边界 | gap=floor(4096/3)=1365，`rbA[0,1364] rbB[1365,2729] rbC[2730,∞]` | 无入口，无对拍目标 | 与 Rust 公式逐位一致 |
| 2 | bucket | 同字符长度请求 | 300/1500/3000 各 8 次全部单点 | — | 单边 |
| 2 | bucket | 失衡改选最小（abs=64/rel=1.5，单进程） | 200 次同桶请求 → `86/57/57` | — | 分支生效 |
| 2b | bucket | 多进程下同一场景 | `200/200 全落桶目标`（逃逸不触发） | — | **新量化偏差**，见 §2.4 |
| 3 | power_of_two | 有 `/v1/loads`：120ms 慢 worker 占比 | 0.100（χ² 59） | 0.000~0.225（χ² 28~120） | 方向一致，都避开 |
| 3 | power_of_two | **无 `/v1/loads`** | 0.096~0.146（仍避开） | **0.271~0.362（χ² 0.3~4.2，等价 random）** | **真背离**，见 §3.2 |
| 3 | power_of_two | `--policy power_of_two` 启动约束 | 无此约束 | 不带 `--worker-urls` 直接拒绝启动 | 单边约束 |
| 4 | random | N=12000/侧 χ²（df=2） | 0.254（最大偏移 0.65%） | 1.780（最大偏移 1.55%） | 两侧各自过 0.05 与 0.01 检 |

一句话：**prefix_hash 与 bucket 在 Rust 的 HTTP 面上根本没有可用入口**（一个是
`tokens: None` 恒失败，一个是 CLI 直接拒绝 + hint 装上后桶表为空退化成随机），所以这两
个策略本轮只能「单边验证 Lua 算法 + 固化 Rust 的不可用事实」；power_of_two 出现一处
真背离（Rust 在 worker 不暴露 `/v1/loads` 时退化为 random）；random 两侧一致。

## 测试口径（先读这三条）

**入口不对称，而且是不可弥合的那种。** Rust `smg launch` 的 `--policy` 取值只有
`random|round_robin|cache_aware|power_of_two|prefix_hash|manual`（`gateway/src/main.rs`
的 `value_parser`，实测 `--policy bucket` 与 `--prefill-policy bucket` 都返回
`error: invalid value 'bucket'`，rc=2）。Lua 侧 `SMG_POLICY` 支持全部 8 个值
（`config.lua:122` `POLICIES` + `policy.lua:34` `MODULE_SPECS`），bucket / prefix_hash
都能直接进分发。Rust 的 per-model `labels.policy` hint 这条路本轮又实测了一遍：hint 确实
能把 `BucketPolicy` 装上（`smg_worker_selection_total{policy="bucket"}` 计数随流量增长），
但桶表 `buckets` 只由 `init_pd_bucket_policies` → `init_prefill_worker_urls` 填充，regular
worker 恒 miss，于是 `bucket.rs:285` 打 `No bucket found for model mrb, randomly selecting
healthy worker` 并退化成均匀随机（300 请求 χ²=0.38）。

**prefix_hash 的不可用不是 501 而是 503。** 直觉上「策略不支持 HTTP」应该报 501，实测
是 503：HTTP router 在构造 `SelectWorkerInfo` 时把 `tokens` 写死成 `None`
（`src/routers/http/router.rs:176`，注释即「HTTP doesn't have tokens, use gRPC for
PrefixHash」），`PrefixHashPolicy::select_worker` 走 `NoTokens` 分支返回 `None`，调用方
把 `None` 一律映射成 `service_unavailable`。PD 面同理（`pd_router.rs:1092`
`server_selection_failed "Policy prefix_hash failed to select a prefill worker"`）。
`--enable-igw` 下 `--prefill-policy` 连传都传不进去：`router_manager.rs:183-191` 用主
策略构造 PD router，实测 `--prefill-policy prefix_hash` 生效的是 `round_robin`。
证据：`t5_rust_entrypoints.json`（含 CLI 报错原文、branch 计数 `{no_tokens: 70}`、
503 响应体），`t1_prefix_hash.json`。

**观察手段。** 自建 mock（`/data/tmp/parity/policy-extra/mock_pol.py`，以及门禁自带的
`PolicyMock`）把自己的 `wid` 写进每个响应体，客户端直接读出选中 worker，不依赖 router
日志；同时对 mock 的 `GET /v1/loads?include=core` 提供 `aggregate.total_tokens`
（Rust `worker_manager.rs:212` 唯一读的字段），`--no-loads` 把它关掉以复现
「worker 不带引擎负载」的部署。两侧再各读一次 `smg_worker_selection_total{policy=...}`
确认流量确实走在被命名的策略上，避免「测了个默认策略」这类假绿。

**实例拓扑（对拍轮，全部同机、全部临时实例，未触碰生产 8800）。**

| 策略 | Lua | Rust | Rust prom | worker 池 |
| --- | --- | --- | --- | --- |
| prefix_hash（全快） | pxl-ph 46201 | px-ph 8931 | 29131 | mpd = 47824/47825/47826 |
| prefix_hash（含慢节点） | pxl-ph2 46207 | — | — | msd = 47830(120ms)/47831/47832 |
| bucket（默认阈值 abs64/rel1.5） | pxl-bk 46202 | px-bk 8932（hint） | 29132 | mrb = 47827/47828/47829 |
| bucket（冻结边界） | pxl-bk4 46209 | — | — | 同 mrb |
| bucket（adjust 漂移 8s） | pxl-bk6 46211 | — | — | 同 mrb |
| power_of_two（有 loads） | pxl-p2 46203 | px-p2 8933 | 29133 | msd |
| power_of_two（无 loads） | pxl-p2n 46205 | px-p2n 8937 | 29137 | msdn = 47836(120ms)/47837/47838 |
| random | pxl-rnd 46204 | px-rnd 8934 | 29134 | mpo = 47821/47822/47823 |
| PD 入口实验 | — | px-pd 8935 / px-pd2 8936 | 29135/29136 | mpd prefill+decode |

Lua 侧复用 `authz:latest` + `test/conf/nginx-lua-router.conf`（改监听端口，
`worker_processes 1`）。门禁版本改用 `lua-router:test/integration/_lib.py` 的
`start_router`（`lua-router:integration` 镜像 + 随机端口 + `SMG_METRICS_PORT=0`），
Rust 侧每策略一个独立实例、随机 `--port`/`--prometheus-port`。

## 1. prefix_hash（单边 + Rust 不可用事实）

**粘滞与截断。** 同前缀 10 次请求全部落在同一 worker；随后 6 次把前缀换成
「相同前 32 字符 + 各不相同的尾部」，落点不变 —— 说明参与哈希的只有前
`SMG_PREFIX_TOKEN_COUNT`（此处 32）个字符，与 Rust「只取 `tokens[..min(len,N)]`」的
截断语义同构（单位不同：字符 vs token）。

**分布不塌缩。** 300 个互不相同的前缀在 3 个 worker 上的份额每轮在 0.27~0.39 之间，
χ² 在 0.14~7.62 之间抖动（df=2 的 0.05 临界值 5.991）。这里不能用 χ² 当硬门禁：环落点由
blake3 决定，300 个 key 不是均匀随机撒点而是 300 次确定性映射，样本一换 χ² 就换。所以
门禁断言的是「每桶份额在 (0.15, 0.60) 内」这种不塌缩条件，χ² 只作记录。

**增删 worker 的 collateral。** 48~60 个稳定 key 先落位，然后 `DELETE /workers/{id}` 摘掉
pdC：

```
60 key（t1_prefix_hash.json）  moved 20  moved_from_dropped 20  collateral 0  ratio 0.3333
48 key（门禁）                  moved 14~18                              collateral 0  ratio 0.292~0.375
```

`collateral 0` 表示除原本落在被摘 worker 上的 key 之外，没有任何 key 换 worker —— 与
consistent_hashing 同一张环的重分布性质（`hash.ring_cached` + `hash.lookup_position`），
比例约等于 1/n。恢复 pdC 后 **48/48 key 全部回到原落点**，环可重建（对照上一轮 manual
#3 的回切 bug：这条路径没有同类问题）。

**与 Rust 的分支语义对齐。** 空路由文本在 Lua 侧返回 503 `no_available_workers`，在 Rust
侧（prefix_hash 策略、healthy worker 存在）同样返回 503 `no_available_workers`，两侧
branch 计数都是 `no_tokens`。这是 prefix_hash 唯一能逐点对齐的地方，而它对齐的恰恰是
「都拿不到 tokens」这件事。慢 worker 场景（msd 池 120ms 的 sdA）：`load_balance_walk`
分支被触发 15~33 次，sdA 占比降到 0.18~0.20（随机基线 0.333），说明
`(total+1)/n × load_factor(1.25)` 这条逃逸门在 Lua 侧工作正常。

## 2. bucket

### 2.1 Rust 侧：不可选是权威结论

三层证据链：

1. CLI 拒绝：`--policy bucket` 与 `--prefill-policy bucket` 都是
   `error: invalid value 'bucket' for '--policy <POLICY>'  [possible values: random,
   round_robin, cache_aware, power_of_two, prefix_hash, manual]`，rc=2（clap）。
2. hint 能装策略但桶表为空：`POST /workers` 带 `labels.policy="bucket"` 后
   `smg_worker_selection_total{model="mrb",policy="bucket"}` 随流量增长（对拍轮采到 303/603），
   说明 `update_policies.rs:102 → registry.rs:169 → factory.rs:83` 这条路走通了；
   但 `docker logs` 里 `No bucket found for model mrb, randomly selecting healthy worker`
   计数与请求数同量级（803 条），200/300 请求的分布是均匀随机（χ² 0.3~0.4）。
3. 原因在代码结构上闭合：`buckets` 只由 `init_prefill_worker_urls` / `add_prefill_url`
   写入，二者唯一调用点是 `init_pd_bucket_policies`，而它需要 prefill worker +
   bucket prefill policy —— 后者正是第 1 条里 CLI 拒绝的值。所以 regular worker 路径上
   桶表恒空。

结论：bucket 没有可比的 Rust 运行体，只能对 Lua 断言算法与 Rust 源码（`bucket.rs`）一致。

### 2.2 Lua 侧：静态边界公式逐位一致

冻结实例（`SMG_BALANCE_ABS_THRESHOLD=1e8` 关失衡分支 + `SMG_BUCKET_ADJUST_INTERVAL_SECS=3600`
关重切），按字符长度扫描：

```
len      1   100  1363  1364 | 1365  2728  2729 | 2730  4094  4095  4096  6000  9000
worker   rbA  rbA  rbA   rbA  | rbB   rbB   rbB  | rbC   rbC   rbC   rbC   rbC   rbC
```

gap = `floor(l_max / worker_cnt)` = `floor(4096/3)` = **1365**，区间
`rbA[0,1364]` / `rbB[1365,2729]` / `rbC[2730,usize::MAX]`，与 `bucket.rs`
`init_prefill_worker_urls` 的 `min=i*gap, max=(i+1)*gap-1`（最后一个桶上界 `usize::MAX`）
完全吻合。两个容易踩错的点值得记下来：真正的边界在 **1364/1365** 而不是 4096；
`l_max // n` 是 1365 不是 1364。同长度请求 8/8 单点落位（300/1500/3000 各一组）。

### 2.3 失衡改选最小

默认阈值（`balance_abs_threshold=64`、`balance_rel_threshold=1.5`，取 Rust CLI 默认）下
连发 200 个 900 字符请求 —— 长度恒定，桶目标恒为 rbA，但 `chars_per_url` 一旦拉开
（`abs_diff > 64` 且 `max > 1.5·min`）该请求就改投当时 chars 最小的 worker：

```
{rbA: 86, rbB: 57, rbC: 57}     （逃逸 114/200 = 0.57）
```

序列前 12 项 `A C B A C B A C B A A C`，周期 7（本桶 3 次 + 另两桶各 2 次）。这条分支在
Rust 是 `bucket.rs:243-256`，Lua 在 `bucket.lua:449-463`，判据与「取最小、并列取字典序」
都一致。

### 2.4 新量化偏差：多进程下逃逸不触发

同一批 200 个请求打在 `NGINX_WORKER_PROCESSES=auto`（本机 144 核）的实例上：
**200/200 全部落桶目标，逃逸一次都没发生**；钉成 1 进程才出现 `86/57/57`。原因不是 bug
而是已有偏差的必然后果：`chars_per_url` 是 per-process Lua 表，N 个进程各自累计，单进程
内的 `abs_diff` ≈ 全量的 1/N，越不过绝对阈值 64。`docker-entrypoint.sh` 只为
`cache_aware` / mesh 自动降到 1 进程，bucket 不在其列。这与上一轮 cache_aware 亲和率
1.000→0.625 是同一类衰减，bucket 侧此前未量化，本轮补上：

| 场景 | 逃逸流量占比 | 备注 |
| --- | --- | --- |
| `worker_processes=1` | 0.57（86/57/57） | 与 Rust 单进程语义一致 |
| `worker_processes=auto`（144） | 0.00（200/200 本桶） | abs 阈值被摊薄，分支不触发 |

生产含义：bucket 策略的失衡保护在多进程 Lua 部署下**名存实亡**。要么按文档把
`NGINX_WORKER_PROCESSES=1` 与 bucket 绑定，要么把 `chars_per_url` 搬进共享字典。本轮
只记录，不改实现（门禁里用对照组的两个 check 把这件事钉住）。

### 2.5 adjust_boundary 漂移（持续流量下可观测）

窗口长度恰为 `bucket_adjust_interval_secs * 1000`，且窗口空时直接 return
（Rust `if self.t_req_loads.is_empty() { return }` / Lua `bucket.lua:197`），所以**没有
持续流量就观测不到重切** —— 上一版探针（60 个预热请求后静默 7s）测到的「边界不动」是
窗口过期造成的假阴性。带持续流量的复测（`SMG_BUCKET_ADJUST_INTERVAL_SECS=8`，背景流量
1300 字符全打桶 0，t2c_bucket_adjust.json 时间线）：

```
t=0.0s   {1: rbA, 1365: rbA, 2730: rbA, 9000: rbA}   预热后边界已被压向桶 0
t=2.3s   {1: rbA, 1365: rbB, 2730: rbB, 9000: rbB}
t=10.0s  {1: rbA, 1365: rbB, 2730: rbC, 9000: rbC}   ← 回到静态边界
```

重切确实发生，且方向符合 Rust 语义：`adjust_boundary` 按**历史请求量的累积分布**（不是
按长度）重新切分，短请求把窗口塞满时长请求就被推到后面的桶。

## 3. power_of_two

### 3.1 有 loads：两侧都会避开慢 worker

worker 提供 `/v1/loads?include=core`（mock 按 in-flight×64 报 `aggregate.total_tokens`），
sdA 恒 120ms、其余 5ms，C=12 closed-loop 240 请求：

```
lua   {sdA: 24,  sdB: 109, sdC: 107}   slow_share 0.100   chi2 58.8
rust  {sdA: 0~42, sdB/C: ~104}         slow_share 0.000~0.225   chi2 27.7~120.2
```

两侧都远低于随机基线 0.333。Rust 侧波动大（负载缓存刷新周期与请求到达竞争），Lua 侧
用自己 registry 的 in-flight 计数，数值更稳。串行（C=1）对照：Lua χ²=13.5、Rust χ²=84
—— Rust 冷启动期间 cached_loads 还是 -1，这段偏斜正是 §3.2 那个退化的临时形态。

### 3.2 无 loads：Rust 退化成 random（真背离）

把 worker 的 `/v1/loads` 换成 404（sglang-less 部署的常见形态），两侧从同一个起点出发：

```
lua    {pdN1: 35,  pdN2: 98,  pdN3: 107}  slow_share 0.146  chi2 38.5   （pxl-p2n，独立实例）
rust   {pdN1: 81,  pdN2: 73,  pdN3: 86}   slow_share 0.338  chi2  1.1   （px-p2n，独立实例）
rust   {pdN1: 74,  pdN2: 85,  pdN3: 81}   slow_share 0.308  chi2  0.78  （门禁复跑）
rust   {pdN1: 65,  pdN2: 88,  pdN3: 87}   slow_share 0.271  chi2  4.23  （门禁另一轮）
```

Rust 的 χ² 从 28~120 掉到 0.3~4.2（df=2 的 0.05 临界值 5.991，即「与均匀不可区分」）、
慢 worker 份额回落到 0.271~0.362（基线 0.333）—— 这就是
`--policy random` 的签名。机制：`worker_manager.rs:350-378` 抓不到 loads 时把每个 worker
的 `total_tokens` 写成 -1 缓存，`power_of_two.rs:64-84` 比较 `load1 <= load2` 恒真，
于是永远取「第一个随机候选」，第二个候选白抽。Lua 的 `policies.power_of_two`
（`policy.lua:112-125`）比较 `registry.load(id)`（本网关自己的 in-flight 计数），与
worker 是否暴露 `/v1/loads` 无关，所以仍避开慢 worker。

**这是本轮唯一的真背离，且 Lua 侧行为更优。** 影响面：任何 worker 不提供 SGLang 风格
`/v1/loads` 的部署（llama.cpp、vLLM 老版本）里，Rust 的 power_of_two 实际等价 random，
Lua 不是。修复应在 Rust 侧（-1 应视为未知而非最小值），不在本轮范围内，因此不改实现。

### 3.3 启动约束

`smg launch --policy power_of_two` 不带 `--worker-urls` 直接拒绝启动：
`Error: IncompatibleConfig { reason: "Power-of-two policy requires at least 2 workers" }`
（px-p2n 首次踩坑）。Lua 侧无此约束（`SMG_WORKER_URLS` 可空、走 `POST /workers` 注册）。
门禁里 Rust 实例一律带 `--worker-urls`。

## 4. random

两侧各 12000（门禁默认 10000）请求、C=16，df=2：

```
lua   {poA: 3974, poB: 4014, poC: 4012}  chi2 0.254  max_dev 0.65%   pass 0.05 / 0.01
rust  {poA: 3995, poB: 4062, poC: 3943}  chi2 1.780  max_dev 1.55%   pass 0.05 / 0.01
```

临界值 5.991（0.05）与 9.210（0.01），两侧都过。两边都是无状态独立均匀抽样
（Rust `policies/random.rs:37-38` `rng.random_range` over healthy indices；
Lua `policy.lua:98-100` `math.random` over candidates），**不逐次比对**，只各自过检。
旁证：Lua `/_ui/logs` 的 `route_type` 全为 `random`；Rust
`smg_worker_selection_total{model="mpo",policy="random"}` = 12000。

## 5. 门禁化

`test/integration/e2e_policy_parity.py` 把上述结论变成 47 条 check
（`e2e_final.out`，47 checks / 0 failed，数据 `e2e_policy_parity.json`）：

- Lua 不变量（始终执行）：粘滞、前缀截断、不塌缩、collateral 0、恢复回切 48/48、
  空文本 503；bucket 单点落位、1365 边界、4096 非边界、同长度单点、失衡摊开 + 冻结对照；
  PoT 有/无 loads 的 slow_share 与 χ²；random 双阈值 χ² + 最大偏移 + route_type
  （`/_ui/logs` 的 route_type 也核对）。
- Rust 事实（镜像存在时执行，缺失时整体跳过）：`--policy bucket` 被拒、hint 装上但桶表空
  （日志 `No bucket found` + 均匀分布）、prefix_hash HTTP 面恒 503 且 branch 只有 `no_tokens`、
  PoT 无 loads 退化成 random（慢 worker 份额 > 0.22 且 χ² < 5.991）并确认 3 个 worker 的
  `/v1/loads` 确实全 404。
- 每轮读一次 `smg_worker_selection_total{policy=...}` 自证流量走的确实是被命名的策略。
- 全程随机端口（`_lib.free_port()`）、`SMG_METRICS_PORT=0`、Rust 独立实例独立端口，
  不依赖也不触碰生产 8800/29000。

门禁这一跑的实测数字（与上文对拍轮同量级，用作回归基线）：

| 项 | Lua | Rust |
| --- | --- | --- |
| prefix_hash 粘滞 / 截断 / 回切 | 10/10 粘 pdC，48/48 回切，collateral 0（moved 15，ratio 0.3125） | 503 ×3，branch `{no_tokens: 15}` |
| bucket 静态边界 | `rbA≤1364 / rbB 1365~2729 / rbC≥2730`，同长度 8/8 单点 | hint 计数 200、`No bucket found` 200 行、分布 65/65/70 |
| bucket 失衡（单进程） | `86/57/57`；冻结对照 `60/60 全本桶` | CLI 拒绝 |
| power_of_two（120ms 慢节点） | 0.104（χ² 56.7）/ 无 loads 0.096（χ² 61.1） | 0.167（χ² 30.0）/ 无 loads **0.313（χ² 0.525）** |
| random（N=10000/侧） | χ² 0.601，最大偏移 1.04% | χ² 3.065，最大偏移 2.35% |

跑法上有三个坑值得记下来（都已在脚本里处理）：Rust 的 axum 监听要等 tokenizer 预热
才打开，注册 POST 打早了只会拿到 ECONNREFUSED（`RustRouter.wait_listen()`）；
prefix_hash 的 300-key χ² 天生抖（0.14~7.62），不能当硬门禁；PoT 无 loads 的 Rust
slow_share 观测区间 0.271~0.362，判据取 0.22 而不是贴边的 0.28。

final_gates 注册行（等 gap_gate_expansion 扩完 e2e_grpc/history_redis 后由其插入，本轮未改
`final_gates.sh`）：

```
#   e2e_policy_parity integration/e2e_policy_parity.py (prefix_hash/bucket/power_of_two/random
#                  与 Rust 的量化对拍；Rust 镜像缺失时 Rust 侧断言自动跳过)
gate_e2e_policy_parity() { run_integration e2e_policy_parity.py 1800; }
...
gate e2e_policy_parity
```

跳过代价：这四个策略的行为特性没有其它门禁覆盖（contract 套件只验 wire 语义与分支计数，
不验分布与边界），bucket 的 per-process 摊薄与 PoT 的无-loads 退化都会被静默漏掉。

## 复现步骤

对拍轮（数据在 `/data/tmp/parity/policy-extra/`）：

```bash
cd /data/tmp/parity/policy-extra
bash setup_pools.sh && bash setup_pools2.sh          # 12 个 mock worker（含慢节点/--no-loads）
bash start_rust.sh                                    # px-ph/px-bk/px-p2/px-rnd
SMG_PREFIX_TOKEN_COUNT=32 bash start_lua.sh           # pxl-ph/bk/p2/rnd/p2n
bash register_all.sh
python3 t1_prefix_hash.py        # 粘滞/截断/分布/collateral/Rust 503
python3 t2_bucket.py             # 静态边界 + 失衡 + Rust hint 退化
python3 t2b_bucket_boundary.py   # 冻结边界逐长度扫描（1364/1365）
python3 t2c_bucket_adjust.py     # 持续流量下的 adjust 重切时间线
python3 t3_power_of_two.py       # 有/无 loads 双场景 + 串行对照
python3 t3b_pot_noloads_isolated.py  # 无 loads 用独立实例复测
python3 t4_random.py             # N=12000 χ²
python3 t5_rust_entrypoints.py   # CLI 入口权威结论（bucket 拒绝 / prefix_hash 503 / IGW 忽略 prefill-policy）
```

门禁轮：

```bash
python3 test/integration/e2e_policy_parity.py          # 全量（含 Rust）
LR_RUST_IMAGE=nonexistent:tag python3 .../e2e_policy_parity.py    # 仅 Lua 侧不变量
LR_PP_N=20000 python3 .../e2e_policy_parity.py                    # random 加大样本
```

## 本轮新增/修正的口径

1. **bucket 的失衡逃逸只在单进程生效**（§2.4）—— 上一轮只在 cache_aware 上量化过衰减，
   本轮证明它同样打击 bucket 的绝对阈值判据，且后果是「保护分支完全不触发」。
2. **power_of_two 的负载来源不同 ⇒ 无 loads 时行为分叉**（§3.2）—— 之前 doc 里只写了
   「Lua 用 in-flight 计数近似 token 负载」，没写清两侧在无 `/v1/loads` 部署下的结果差异；
   现在有量化数字（Rust 0.338/χ²1.1 vs Lua 0.146/χ²38.5）。
3. **Rust prefix_hash / bucket 的 HTTP 面不可用**首次给出完整三层证据（CLI 原文 +
   branch/selection 计数 + 网关日志），后续不必再猜。

## 未覆盖

- prefix_hash 的**逐 key 落点**与 Rust 比对：需要 gRPC 面（Rust 只在 gRPC 下传 tokens），
  本轮未做；环位一致性只在 consistent_hashing 那一轮证过。
- power_of_two 无 loads 退化的**修复验证**（Rust 侧把 -1 当未知）：属上游改动，未做。
- bucket 多进程摊薄的缓解方案（`chars_per_url` 入共享字典 / 与 cache_aware 一样钉 1 进程）：
  只记录，未实现。
- `worker_processes>1` 下的 prefix_hash 粘滞：上一轮已证 consistent_hashing 环可跨进程重建，
  prefix_hash 复用同一环，未单独复测。
