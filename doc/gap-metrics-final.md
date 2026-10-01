# C1 收尾：Prometheus 家族权威清单与 PD pool gauge 修复

> 范围：`observability.lua`（渲染器 / HELP 表 / 派生 gauge）、`service_discovery.lua`
> （layer-4 打点）、`test/test_lua_router.sh`（observability 节）、
> `test/integration/e2e_grpc.py`、`test/integration/e2e_discovery_dp.py`。
> 不改 `router.lua`、history、grpc 模板。本文是家族覆盖率的唯一权威口径，
> [feature-gap.md](feature-gap.md) 旧 §3.5 的 28/48 口径以本文为准更正（feature-gap 已在最终门禁后
> 重写为 A/B/C/D 四档，指标摘要在它的新 §4.5）。
>
> 状态复核（2026-09-30 最终门禁）：本文 §5.1 记的 **15 门禁全绿**之后又新增一个门禁
> `e2e_responses_store`（14/0），最终一轮 **16 passed / 0 failed / 0 skipped**
> （`/data/tmp/lr-gates/gates-20260930-165530.log`，契约仍 795/0/2，代码树 `router.lua` md5 `c41ef30f…`）。
> 再之后 `e2e_grpc`（59/0）与 `e2e_history_redis`（44/0）也纳入了 `GATE_ORDER`，门禁 **18/18**
> （`gates-20260930-190905.log`，`router.lua` 仍是同一棵树），下表「需单独跑」的括注已过期。
> 全量矩阵见 [verification-final.md](verification-final.md)。§6 那条
> 「表 C 剩余的 `smg_http_inflight_request_age_count`」已于本轮闭合：`lr_stats` 里 1024 槽定长表
> 存每请求 `start_ms`，worker 0 定时器快照年龄分布，真实采样（见 doc/gap-inflight-age.md）。
> 登记/注销两处（`router.lua` 进出）与 log 阶段兜底都已接线，契约新增 `inflight_age` 节 32 项。

## 1. 分母：Rust 到底注册了多少家族

口径来自 `gateway/src/observability/metrics.rs`（去掉 `#[cfg(test)]` 之后的生产代码）：

| 口径 | 数量 | 说明 |
|---|---|---|
| `smg_*` 字面量（全仓，去掉 target/ 与单测） | 49 | 含 2 条注释里的名字 |
| 注释-only 死名字 | 2 | `smg_request_dist`、`smg_worker_dist`（只在 `gauge_histogram.rs:29,306` 的示例注释里） |
| **Rust 已注册家族** | **47** | `init_metrics()` 里 `describe_*` 43 条 + 只写不 describe 4 条 |
| 只写不 describe | 4 | `smg_manual_policy_branch_total`、`smg_consistent_hashing_policy_branch_total`、`smg_prefix_hash_policy_branch_total`、`smg_worker_routing_keys_active` |
| **Rust 注册但永不产生样本** | **7** | 见 §2 表 A：有 `Metrics::set_*/record_*` 包装函数，但全仓（含 `routers/`、`policies/`、`middleware.rs`）没有调用点 |
| **Rust 实际会渲染的家族** | **40** | 47 − 7，这是「仪表盘真的能查到数据」的分母 |

复现脚本口径（`/data/tmp/fams_final.py` 逻辑，接手者可直接重跑）：

- describe：`describe_(counter|gauge|histogram)!\(\s*"smg_[a-z0-9_]+"`；
- 只写不 describe：把 `metrics.rs` 按 `pub fn` 切块，块内出现 `histogram!("smg_…")` /
  `gauge!("smg_…")` / `counter!("smg_…")` 但不在 describe 名单里的名字；
- 是否有真实调用点：取出写该家族的 `pub fn` 名字，在 `metrics.rs` 之外的 `*.rs` 里
  搜 `\bfnname\s*\(`（`smg_http_inflight_request_age_count` 特殊，它走
  `inflight_tracker.rs` 的 `GaugeHistogramVec`，算「有调用点」）。

## 2. 缺口三分类（本轮闭合后的终态）

### 表 A：Rust 侧 describe-only 死代码（6 条，两边都拿不到数据）

Rust 自己也不渲染，所以「Lua 缺它」不构成任何仪表盘行为差异，**不实现**：

| 家族 | Rust 包装函数 | 状态 |
|---|---|---|
| `smg_db_operations_total` | `record_db_operation` | 无调用点（且 Lua 没有独立 DB 后端，见 §4） |
| `smg_db_operation_duration_seconds` | `record_db_operation_duration` | 同上 |
| `smg_db_connections_active` | `set_db_connections_active` | 同上 |
| `smg_db_items_stored` | `increment_db_items_stored` | 同上 |
| `smg_router_stage_duration_seconds` | `record_router_stage_duration` | 无调用点（gRPC 流水线阶段计时的残留） |
| `smg_worker_connections_active` | `set_worker_connections_active` | 无调用点（Rust 没有到上游的连接池计数） |

注：`smg_discovery_sync_duration_seconds` 也在这批里（Rust 只 describe 不调用），
本轮被 Lua **反向补齐**，见 §3。

### 表 B：TODO 子系统（4 条，明确不注册）

MCP 四条 —— `smg_mcp_servers_active`、`smg_mcp_tool_calls_total`、
`smg_mcp_tool_duration_seconds`、`smg_mcp_tool_iterations_total`。
用户指示（2026-09-30）MCP / wasm / Postgres / Oracle 不实现。Lua 侧 `mcp_manager.rs`
对应物不存在，`/wasm` 三条路由保持 501。**口径**：子系统不实现 ⇒ 家族不注册，
`/metrics` 里既不出现 `# HELP` 也不出现样本行；`wasm` 在 Rust 侧本来就没有家族，
Postgres / Oracle 落在表 A 的 `smg_db_*`（Rust 死代码）。档位记录见
[todo-deferred.md](todo-deferred.md)。

### 表 C：已实现子系统但缺指标（本轮处理后清零，1 条已补）

| 家族 | 本轮结论 |
|---|---|
| `smg_router_tpot_seconds` | **已补**（§3） |
| `smg_router_generation_duration_seconds` | **已补**（§3） |
| `smg_http_connections_active` | **已补**（§3，nginx `stub_status`） |
| `smg_worker_routing_keys_active` | **已补**（§3，lr_policy sticky 映射派生） |
| `smg_discovery_sync_duration_seconds` | **已补**（§3，Rust 侧本来不产样本） |
| `smg_http_inflight_request_age_count` | **已补（真实采样）**：`lr_stats` 里 1024 槽定长表存 `"<start_ms>|<token>"`（TTL = `LR_INFLIGHT_TTL_SECS`，默认 3600 s），登记在 `observability.record_http_request`（对齐 Rust `HttpMetricsLayer` 的先于 auth、先于并发上限），注销在 `router.lua` 的 `finish_request` 与 `init.lua` 的 log 阶段，worker 0 定时器每 `LR_INFLIGHT_SAMPLE_SECS`（默认 20 s，0 关掉整条家族）快照一次分布。**语义偏差**：Rust 是 `(gt, le]` 非累积 gauge、边界 30 s…86400 s、无 `_sum`/`_count`；Lua 渲染成**累积直方图**、沿用 `SMG_PROMETHEUS_DURATION_BUCKETS` 阶梯、带 `_sum`/`_count`，`_count` 数的是**样本数**（每 tick 每个在途请求各 1），不是已完成请求数。约 `f^4` 概率丢新登记（256 并发 ≈ 0.4%），由 Lua 独有超集 `smg_http_inflight_request_age_dropped_total` 与 `..._age_slots_active` 记账。全量设计/实测见 [gap-inflight-age.md](gap-inflight-age.md)。 |

## 3. 本轮改动

### 3.1 `smg_worker_pool_size`：从写死 0 改为按注册表派生（C1 硬缺陷）

旧实现（本任务接手前）固定渲染三行，`prefill` / `decode` 恒为 0，`regular` 是
`#records`（把 grpc、PD 记录也算进 regular）：PD 上线后这个家族整体在说谎。

新实现（`observability.lua`，`pool_size_counts` / `pool_labels_for`，渲染在
`prometheus_text()` 内）：

- 维度 = **每个唯一的 `(worker_type, connection_mode, model)` 三元组一条序列**，
  与 Rust `set_worker_pool_size`（`metrics.rs:807`）一致；计数口径同
  `register.rs:63-83` 的 `get_workers_filtered(..., healthy_only = false)`，
  即**注册表成员数**，不是健康数（worker 只是探针失败时序列保留，值不变）。
- `worker_type` 走 `pd.pool_of`：`pool` > `worker_type` > `labels.worker_type|pool`，
  未知塌缩 `regular`（`pd.lua:61`）。
- `connection_mode` 归一对齐 `ConnectionMode::as_metric_label()`（`worker.rs:452`）：
  `http` → `http`，`grpc` 与 `grpcs` → `grpc`（TLS 与普通 gRPC 共用一条序列）。
- `model` 取 `record.model_id`，缺省 `unknown`。
- **空组合不渲染**：Rust 只对注册时见过的组合调用 setter，因此没有 prefill worker
  就不该出现 `worker_type="prefill" 0` 那行（渲染 0 会被仪表盘读成「有一个活的
  prefill 池」）。这与旧实现「永远三行」相反，是行为变更，契约里有对应断言。
- `HELP` 文案改成 Rust 原文 `Current worker pool size by worker_type, connection_mode, model`。

`registry.lua` **零改动**：`pd.pool_of` 与 `registry.records()` 已经是纯只读接口，
派生放在导出器里就够，不新增公共 API。

实测（真实容器，`SMG_GRPC=1`，5 类 worker 混池）：

```
smg_worker_pool_size{connection_mode="grpc",model="grpc-model",worker_type="regular"} 1
smg_worker_pool_size{connection_mode="grpc",model="pd-model",worker_type="decode"} 2
smg_worker_pool_size{connection_mode="grpc",model="pd-model",worker_type="prefill"} 1
smg_worker_pool_size{connection_mode="http",model="http-model",worker_type="regular"} 1
```

标签顺序按字母序输出（`connection_mode,model,worker_type`），与 Rust exporter 的
渲染顺序一致，Prometheus 对标签顺序不敏感。

### 3.2 补齐的家族

| 家族 | 数据源 | 位置 | 与 Rust 的差异 |
|---|---|---|---|
| `smg_router_tpot_seconds` | `record_router_duration` 内派生 `(duration − ttft) / (output_tokens − 1)`，仅当 `ngx.ctx.lr_ttft` 存在且 `completion > 1`，用 `math.max(0, …)` 做 Rust 的 saturating 减法 | `observability.lua` | Rust 由 `record_streaming_metrics` 写入并用独立 generation 计时器；Lua 侧没有第三个计时器，用请求总时长替代（与 `router.lua` 里 `tok_per_s` 用的是同一个 decode 窗口）。标签同 Rust（`router_type,backend_type,model,endpoint`）。 |
| `smg_router_generation_duration_seconds` | 同一路径直接 observe 请求总时长 | `observability.lua` | Rust 该家族是 gRPC streaming 专用；Lua HTTP 面用它承载同一语义。 |
| `smg_http_connections_active` | `ngx.var.connections_reading + connections_writing`（nginx `stub_status` 计数器，两个出厂镜像都编译了该模块），模块缺失或变量取不到时整条序列消失 | `observability.lua` `http_connections_active()` | Rust 用原子计数在 request future 进入/退出时增减（`middleware.rs:929`），看不见 idle keep-alive；因此这里刻意**减去 `connections_waiting`**，两边测同一件事。Rust 无 label，此处也无。 |
| `smg_worker_routing_keys_active` | 扫 `lr_policy` 里 `manual:` 前缀键，按 `urls[1]`（当前绑定的 worker）计数，scrape 时派生 | `observability.lua` `manual_routing_key_counts()` | Rust 是 per-worker 的 `WorkerRoutingKeyLoad`，只在 `WorkerLoadGuard` 存活期间计数（`worker.rs:89-130`）；Lua 的 manual 策略把绑定持久化在共享字典里并靠 `max_idle_secs` 老化，所以这里数的是**粘性绑定数**而不是在途请求数。语义差别已在 HELP 文案与本表登记：`Active routing keys per worker`（Rust 该家族没有 describe 文本，无原文可抄）。同一份映射也是 `smg_manual_policy_cache_entries` 的来源，两者一致性有契约断言。 |
| `smg_discovery_sync_duration_seconds` | `poll_once` 拆出 `sync()`，只有真正发起了 list 才计时（`api_server()` 判定 disabled 的那条早退路径不记） | `service_discovery.lua` `observe_sync()` | Rust describe 了它但全仓没有调用点，因此 Lua 是**唯一真正产出样本**的一侧。标签 `source`，值域与其余 layer-4 家族相同（`kubernetes`）。 |

### 3.3 discovery 家族的 result 值域对齐

`registrations_total{result}` 的 Rust 值域是 `success | failed | duplicate`
（`metrics.rs:424-426`）。旧 Lua 只有 success/failed，且把「URL 已存在」这类重复注册
记成 failed。现在 `registration_result(err)` 把 `registry.add` 返回的
`already exists` 归到 `duplicate`（与 `register.rs` 的幂等分支同语义），其余错误仍是
`failed`。`deregistrations_total{reason}` 保持 `pod_deleted`（与 Rust
`DEREGISTRATION_POD_DELETED` 同），Lua 的 reconcile 没有 Rust 的 tracked-pod 去重路径，
所以 `duplicate` 只在 add 冲突时出现。

### 3.4 HELP / TYPE 完整性

- `HELP` 表从 29 条涨到 42 条，**每个代码里出现的家族都有 HELP**（脚本核对：
  `rendered-without-HELP = []`；`smg_otel_self_test` 是 span 名而非家族名，不计）。
- 与 Rust 同名的 32 条家族，HELP 文本逐字取自对应的 `describe_*`，脚本核对只剩 4 处
  刻意差异并已在源码注释里说明：`smg_router_ttft_seconds` / `smg_router_tpot_seconds` /
  `smg_router_tokens_total` / `smg_router_generation_duration_seconds` 去掉 Rust 的
  `(gRPC only)` 尾注（Lua 在 HTTP 流式面上也记这三条，保留该尾注就是假声明）。
  其余 28 条与 Rust 文本完全一致（本轮把 `Total HTTP responses by …`、
  `outcome (success/failure)`、`0=closed, 1=open, 2=half_open`、
  `Current consecutive …`、`Total retry attempts …`、
  `Requests that exhausted all retries …` 六处旧译文改回 Rust 原文）。
- 渲染器新增「空家族不渲染」守卫：一个家族若 `counters/gauges/histograms` 全空，
  就不再输出孤零零的 `# TYPE x untyped`（与 Rust 一致，也避免把只是暂时没样本的
  gauge 误标成 untyped）。

### 3.5 OTel 自监控

`smg_otel_requests_total` / `smg_otel_spans_total` / `smg_otel_exports_total` /
`smg_otel_export_failures_total` 四条已存在且已有 HELP，本轮只核对未改：Rust 侧
`metrics.rs` 里没有任何 tracing-self 家族，因此这四条属于 **Lua 超集**，
不计入 47 分母（`smg_otel_self_test` 是 span 名，同样不计）。

## 4. 覆盖率前后

分母 47 = Rust 已注册家族；括号内给 40 的口径（Rust 实际会渲染的家族），
后者才代表「仪表盘可用性」。

| 口径 | 本轮前 | 本轮后 |
|---|---|---|
| Lua 代码级家族名（`lualib/`，不含 span 名） | 37 | 43 |
| 与 Rust 47 的交集 | **31（66.0%）** | **37（78.7%）** |
| 对 Rust 40 实渲染家族的覆盖率 | 31/40（77.5%） | 36/40（90.0%） |
| 未注册缺口 | 16 | 10（表 A 6 + MCP 4） |
| 其中「子系统已实现但缺指标」 | 6 | **0** |
| Lua 独有超集 | 6（2 个 gauge + 4 个 otel） | 8（新增 `..._age_dropped_total`、`..._age_slots_active`） |

本轮净增 5 条：`smg_router_tpot_seconds`、`smg_router_generation_duration_seconds`、
`smg_http_connections_active`、`smg_worker_routing_keys_active`、
`smg_discovery_sync_duration_seconds`。下一波（本轮）再补 1 条 ——
`smg_http_inflight_request_age_count`，真实采样，设计见 [gap-inflight-age.md](gap-inflight-age.md)。
剩余 10 条的逐条理由见 §2 的三张表；
`smg_manual_policy_branch_total` / `smg_consistent_hashing_policy_branch_total` /
`smg_prefix_hash_policy_branch_total` 在 Rust 是只写不 describe，Lua 早已埋点，
本轮补上了它们的 HELP，交集里早已计入。

**给仪表盘的一句话结论**：`smg_worker_pool_size` 现在 PD 上线后数值正确，
`worker_type` 三值齐全；表 C 已清零 —— `smg_http_inflight_request_age_count` 现在是真实采样的一条
（语义是累积直方图 + 样本数口径，读法见 gap-inflight-age.md §3）；剩余 10 条在 Rust 侧同样拿不到样本
（6 条 Rust 死代码 + 4 条 MCP 未实现）。

## 5. 测试

| 门禁 | 新增断言 | 说明 |
|---|---|---|
| `contract`（`test_lua_router.sh` observability 节，全节 55 项） | 16 | 专用实例 `lr-metrics-*`（两个 http+regular worker，两个 model）：HELP/TYPE 每家族唯一 + 全样本可解析；pool = `regular/http/sink-model=1 regular/http/test-model=1`；pool 序列条数 == `/workers` 数量；无 PD worker 时**不得**出现 `worker_type="prefill"` / `"decode"`；DELETE 后 pool 跟随消失；`smg_http_connections_active` 为非负整数；未开 discovery 时 `^smg_discovery_` 为 0 行；tpot 家族出现且 histogram 满足累积/+Inf 不变量。`lr-rk-*` 实例（`SMG_POLICY=manual`）：routing keys 按 worker 计数、只有一条 HELP/TYPE、与 `smg_manual_policy_cache_entries` 在一个 eviction tick 内相等、worker 删除后键仍归属原 worker。 |
| `e2e_grpc` | 7 | 注册节（group 1）四断言：pool 序列与 `expected_pool(/workers)` **全量相等**（不是子集）、该拓扑确实同时含 prefill/decode/regular-grpc/regular-http 四类、`grpcs` 不以任何形式出现在 `connection_mode` 里、导出的序列条数 == 组合数；PD 节（group 7）三断言：五元组全量相等（含 `decode/grpc/pd-model=1`、`prefill/grpc/pd-model=1`）、没有 0 值序列、decode 池探针挂掉后序列仍在（成员数≠健康数）。期望值统一由 `expected_pool()` 从 `/workers` 现算，避免元数据扫描改写 `model_id` 造成的假失败。 |
| `e2e_discovery_dp` | 8 | layer-4 家族**逐条**校验：`registrations_total` / `workers_discovered` / `sync_duration_seconds` 各自在第一次出现样本后必须恰好一条 HELP + 一条 TYPE 且类型与 Rust 对齐（counter / gauge / histogram），`deregistrations_total` 在第一次 pod 撤收后再校验一次，最后一条汇总断言四家族的类型集合恰好是 `counter,counter,histogram,gauge`。逐条而非一次到位，是因为渲染器现在对空家族整体不出行（§3.4）——一次性断言四家族会把这个正确行为误判成缺 TYPE。同步直方图另加两条：`_count >= 1`（Rust 从不写这条，Lua 是唯一有样本的一侧）、bucket 行 21 条（默认 20 个上界 + `+Inf`）且 `+Inf == _count`。 |
| `contract`（`test_lua_router.sh` inflight_age 节，全节 32 项，本轮新增） | 32 | 专用实例 `lr-age-*`（`LR_INFLIGHT_SAMPLE_SECS=1` + 6 s mock）：首个 tick 后家族出现且空闲读全 0；age 桶集与 duration 桶集逐 `le` 相等；单条慢请求在途时 `_count>=1`、`_sum>0`、年龄落在有限桶（le=1/le=2.5）且 `slots_active == smg_http_inflight_requests`；24 并发时 `_count>=20`、`dropped_total` 不出现、全 exposition `unique=ok parseable=ok`、`hist(smg_http_inflight_request_age_count)=ok`；结束后（含 `curl -m 0.3` 打断的三个请求，只有 log 阶段收尾）桶/`_sum`/`_count` 全部回 0、无 `lua entry thread aborted`；`lr-agettl-*`（`LR_INFLIGHT_TTL_SECS=1`）证明 TTL 是硬上界（在途但 `_count` 已回 0）；`lr-ageoff-*`（`LR_INFLIGHT_SAMPLE_SECS=0`）证明关闭时三个 age 序列整体缺席、并发仪表不受影响。 |
| 辅助脚本 | — | `$TMP_DIR/metrics_check.py`（由 `write_metrics_check` 落在 TMP_DIR）做唯一性 / 语法 / pool / histogram 不变量判定，契约断言只比对它输出的字符串。 |

`registry.lua` 未改动，因此 `unit` 与 PD 纯函数单测口径不变。

### 5.1 回归数字（同机同镜像，`bash test/final_gates.sh`）

**15 个门禁全绿：15 passed / 0 failed / 0 skipped。**

| 门禁 | 本轮前 | 本轮后 |
|---|---|---|
| `contract` 全量 | 780 项 | **795 项**（observability 节 55 项） |
| `e2e_discovery_dp` | 72 项 | **80 项** |
| `e2e_grpc`（不在 `GATE_ORDER` 里，需单独跑） | 52 项 | **59 项，0 failed** |
| 其余 11 个门禁 | unit 9 个模块、probes 25、e2e_stateful 43、e2e_policies 65、e2e_ui_bridge 19、e2e_errors 10、e2e_effort 4、e2e_jwt 48、head_routes 120、mesh_http 47、e2e_otel 119 | 数字不变，全部 0 failed |

日志：`/data/tmp/lr-gates/gates-20260930-161747.log`（15/15 全绿，镜像与交付树
`md5sum` 一致的最终轮）与 `/data/tmp/lr-c1/grpc_final.log`（59/59）。中途两轮
`gates-20260930-160644.log`（e2e_stateful `[prefix_hash] workers healthy`）与
`disc.log`（`[dpfail] still exactly one candidate`）各有一次 FAIL，两次都是我当时
并发手跑另一套容器密集套件造成的端口/容器名争用（`/workers` 落到别的进程上返回
非 200，`urls()` 因此返回 `None`），与本轮改动无关；串行单独重跑均 PASS。
教训记在这里：`final_gates.sh` 与两套 e2e 都是 host 网络 + 固定容器名前缀，**不可并发**。

## 6. 风险与遗留

- `smg_http_connections_active` 依赖 `stub_status` 模块与 `connections_*` 变量：镜像里没有该模块时序列整体消失（不是渲染 0）。`conf/nginx.conf.template` 与测试 conf 都没有额外声明这两个变量，`ngx.var` 在 OpenResty 里对核心变量可直接读，已验证 authz 与 lua-router 两个镜像都能取到。
- `smg_worker_routing_keys_active` 的语义差（粘性绑定数 vs 在途 guard 数）会在长空闲后放大：Lua 的 sticky 键活到 `max_idle_secs`（缺省 4 h），Rust 的 guard 随响应结束就减。若仪表盘要的是「此刻有多少条 routing key 压在 worker 上」，这条序列会偏高，§3.2 已登记。
- `smg_router_tpot_seconds` 用请求总时长替代 generation 时长：非流式或极短流式请求的 tpot 会偏小；`decode_s` 为 0 时仍记录（Rust 同样 saturate），首个 bucket 会吸收这类样本。
- `smg_worker_pool_size` 数的是**注册表记录数**，因此一个 DP 引擎展开成的
  `url@rank` 记录各计一条（`regular/http/<model>=dp_size`），与 Rust
  `get_workers_filtered().len()` 对 worker 列表计数一致；另外 `model_id` 会被
  `registry.discover` 从引擎的 `/model_info` 学到并改写，注册时写 `unknown` 的
  worker 在首次探针后可能整条序列换到真实 model 名下。因此测试里的期望值一律由
  `expected_pool(/workers)` 现算，不写死（`e2e_grpc.py` 即如此）。
- 表 C 的 `smg_http_inflight_request_age_count` 已闭合（`router.lua` 进出两处 + log 阶段兜底都登记了）：登记不是全局无损的，负载因子 f 下约 f^4 概率丢**新**登记（1024 槽、4 次探针），由 `..._age_dropped_total` 记账；`_count` 是样本数而非完成数，`rate()`/`increase()` 对它无意义。
