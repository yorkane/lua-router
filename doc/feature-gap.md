# lua-router 功能缺口清单（vs Rust `gateway/`）

状态：**现行有效**（最终门禁 21 门全过之后刷新）。日期：2026-09-30（UTC）。
对端 = `gateway/` 工作树（Cargo version 0.3.2）。代码树 = `router.lua` md5
`9d8901937b7e033bdeaa0db7210708fc` + `mesh.lua` `e424e658…` + `grpc_proxy.lua` `70e9366c…`
（三者均已与 `lua-router:integration` 镜像内副本核对一致；本文、README 与
verification-final 的计数同源于这一棵稳定树）。

证据强度：**A（本轮实测）** = 在 <dev-box> 本机跑的门禁 / 契约 / 单测 / e2e / 路由面探针；
**B（对拍报告）** = doc/parity-*.md、doc/real-eval.md、doc/fix-majors.md 里有原始数据留档的结论。

权威日志：`/data/tmp/lr-gates/gates-20260930-230302.log`（23:03–23:15 UTC，单轮
**21 passed / 0 failed / 0 skipped**）；拆轮留档：`gates-live.log`（20/0/1，SKIP_ENV=mesh_two）+
`gates-20260930-225653.log`（GATE_ONLY=mesh_two PASS）；
历史留档 `final-stable-20260930.log`（19/19，早于 mesh_two / e2e_tls_chain / proto body 注入）。
路由面探针在这棵树上复跑、结果逐行一致：`/data/tmp/lr-docsfinal/route_probe_final.txt`（上一版留档）
与 `/data/tmp/lr-docsfinal/route_probe_stable_8000cfb6.txt`（本文 §3 判据）。
计数历史：契约 266 → 322（fix-majors）→ 474（核心第二波）→ 659（history/tokenizer/mesh 接线，
[gap-integration.md](gap-integration.md)）→ 717（HTTP 语义，
[gap-http-semantics.md](gap-http-semantics.md)）→
780（DP 注入 + JWT，[gap-dp-jwt.md](gap-dp-jwt.md)）→
795（Prometheus 家族收尾，[gap-metrics-final.md](gap-metrics-final.md)）→
**841**（在 809 的基础上新增 `inflight_age` 段 32 项 —— `smg_http_inflight_request_age_count`
的真实采样，doc/gap-inflight-age.md）。

> **结论先行**
>
> **不能再引用上一版的三句话**：「gRPC / PD / K8s discovery / OTel 未上线」、「六个模块已备待接线」、
> 「指标覆盖 28/48」。这三句在 2026-09-30 之后的代码树上已经不成立：
>
> 1. `router.lua` 现在 require `history` / `mesh` / `parse` / `tokenizer` / `otel` / `jwks`
>    （`router.lua:28-52`），`init.lua` 里 wire `history_redis` 与 `service_discovery`，
>    gRPC + PD 由入口脚本渲染独立 listener（`conf/grpc-server.conf.template` +
>    `conf/grpc-readiness.conf`，`SMG_GRPC_PORT>0` 时 include）。判定命令：
>    `grep -rn 'require "resty.luarouter.<模块>"' lualib/resty/luarouter/router.lua lualib/resty/luarouter/init.lua conf/ | grep -v prototype`
>    → 除 `wasm` / `mcp` / `history_postgres` / `history_oracle` 外全部命中。
> 2. 门禁面：契约 **841 passed / 0 failed / 2 notes**，19 个门禁全绿（含 e2e_stateful 60、
>    e2e_discovery_dp 117、e2e_jwt 48、head_routes 120、mesh_http 47、**e2e_grpc 59**、
>    **e2e_history_redis 44**、e2e_otel 119、e2e_responses_store 18、**e2e_policy_parity 47**）。
> 3. 指标覆盖率：对 Rust **实际会渲染的 40 个家族**覆盖 **36/40 = 90.0%**（唯一新补齐的是
>    `smg_http_inflight_request_age_count`，真实采样，见 doc/gap-inflight-age.md）；对 Rust 注册的 47 个
>    交集 37。分母口径与逐条理由以 gap-metrics-final.md 为唯一权威（本文 §4.5 只做摘要）。
>
> 仍然成立的事实：HTTP 推理面与 8 个策略的行为对拍通过；路由面对 Rust 的 85 条 path+method
> 配对**一条不缺**（§3 探针复跑）；对外契约有 **B 档**的偏差与架构限制清单（§4），消费方需要逐条评估；
> **D 档**三项（MCP / wasm / Postgres·Oracle）按用户指示（2026-09-30）登记为 TODO，除非明确指定否则不实现，
> 唯一口径 [todo-deferred.md](todo-deferred.md)。
> **能替换生产 Rust 实例**的判据是「调用方不踩 §4 的偏差 + 不依赖 §4.5 未覆盖的家族」，先读 §4 再判。
>
> 本文档的章节号在本次重写里变了。旧引用对照：旧 §3.4（六个模块的接线状态）→ 本文 §2.6；
> 旧 §3.5（缺失的 Prometheus 家族）→ 本文 §4.5；旧 §5.5（第二波的 8 条有意偏差）→ 本文 §4.1；
> 旧 §5.1/§5.2（`set_top_field` 与注释债）→ 本文 §6.1 / §6.2；旧 §2（部分实现）已按档位并到 §2 与 §4。

## 1. 档位定义

| 档 | 含义 | 判定方法 |
|---|---|---|
| **A 已实现** | 有代码、已接进请求路径、且有门禁断言钉住对外行为 | 对应门禁 / 契约段绿（本文各表给出门禁名与计数） |
| **B 已文档化偏差 / 架构限制** | 功能在，但对外形状或实现机制与 Rust 不同，且是刻意的（含环境决定的架构限制） | 逐条写进本文 §4，消费方需评估 |
| **C 剩余可行动缺口** | 还能做、值得做，本文列明落点 | 本文 §5 |
| **D TODO（不实现）** | 用户指示 2026-09-30 登记，除非明确指定否则不写代码 | [todo-deferred.md](todo-deferred.md)，本文 §7 |

「单测绿」不再等于「已备待接线」：接线完成的判据是**有对外路由走到它 + 有契约/e2e 断言**。

## 2. A 档：已实现并有门禁

### 2.1 推理面与流式

| 能力 | Lua 位置 | 证据 | 强度 |
|---|---|---|---|
| OpenAI 推理面 7 条路由（chat / completions / embeddings / rerank / classify / responses / generate） | `router.lua` 推理 pipeline，字节透传 + 顶层 `model` 定点改写 | 契约 `inference` 38 项；parity-contract #1–#6 逐字段（含 SSE 7 帧、`[DONE]`、`x-accel-buffering`） | A/B |
| 流式转发（增量、不缓冲、无 content-length） | `body_filter` + `ngx.print`/`ngx.flush` | parity-contract #2/#2b（chunk_count 8/8）；parity-perf-v2 真实节流流式三方打平（677.8 vs 681.8 RPS） | A/B |
| 8 个路由策略全进分发 | `config.lua` `POLICIES` 8 值 + `policy.lua` `MODULE_SPECS` | probes 25/0（工厂八策略逐条）、e2e_policies 65/0、e2e_stateful 60/0、契约 `/klib/load` 清单 | A |
| consistent_hashing 逐 key 落点兼容 | 完整 BLAKE3（官方 19 向量）+ 同构造环 | parity-routing #2/#2b：摘 1/5 → unchanged 0.80、collateral 0，两侧逐 key 相同 | B |
| cache_aware 亲和 + 失衡逃逸 + 淘汰 + 快照 | `policies/{tree,cache_aware}.lua`，快照写 `lr_policy` | parity-routing #4 亲和率 1.000；e2e_stateful `[snapshot]` / `[snapshot max_bytes]` | A/B |
| 熔断（跨进程原子计数） | `registry.charge_cb` / `flip_cb` + `shdict:incr` | 契约 `cb_race` 6 项（4 nginx 进程，transition 恰 1） | A |
| 健康巡检 + 自动恢复 + 元数据发现 | `hb.lua` 周期探测，`/model_info`→`/v1/models` 回填 | 契约 `discovery` 5 项 | A |
| HTTPS 上游（SNI，不验证书） | `registry.tls_handshake`（router / hb / config_store 三处） | 契约 `tls_upstream` 11 项；真实 llm-248 端到端 PASS（real-eval §0） | A/B |
| 重试 + 指数退避 + jitter | `hb.is_retryable_status` | 契约 `inference` 重试段；impl-core §6 | A |
| 头白名单转发 / hop-by-hop 剔除 | `FORWARD_HEADERS` | 契约 `headers` 13 项 | A |
| IGW 语义（缺 model→`unknown`→503、非字符串 model→400） | `route_inference` | 契约 `igw` 7 项 + parity-contract F1/F2 | A/B |
| 全局并发限流 + 队列 + `smg_http_rate_limit_total` | `limit.lua` + `lr_limit 64k` | 契约 `ratelimit` 14 项 | A |
| 虚拟别名 `LMR_VIRTUAL_MODELS` | 路由期解析并折进 worker 真实 model_id | 契约 `virtual_models` 15 项 | A |
| 请求日志与 `/_ui/logs*` / `/_ui/stats` | `observability` 环形缓冲 | 契约 `ui_fixed` 51 项；fix-majors 附加项（非流式 usage）已修 | A |

### 2.2 控制面、鉴权与 TLS

| 能力 | 证据 | 强度 |
|---|---|---|
| `POST /workers`（202+Location）/ `GET` / `PUT` / `DELETE` / 幂等复用 id | 契约 `workers` 74 项（`PUT` 三键形状、校验、labels 合并、身份字段忽略全钉） | A |
| `POST /flush_cache` 只挂 POST | 契约 `workers` 段内；响应形状是 B 档偏差（§4.1 第 5 条） | A |
| API key（数据面 / 控制面，`x-api-key` 与 Bearer 都认） | 契约 `ui_auth` 34 项 | A |
| 多 key + 角色（`SMG_CONTROL_PLANE_API_KEYS` = `id:name:role:key`）+ 审计日志 | 契约 `auth_rbac` 33 项（admin 200 / user 403 / 匿名 401 / key 值不落入日志） | A |
| 控制面 JWT / JWKS（`SMG_JWT_JWKS_URI`）：RSA-2048 + EC P-256、issuer/audience/role claim/leeway/kid 缓存 | `test/unit/test_jwks.lua` 120/0；`e2e_jwt.py` 48/0；契约 `jwt_gate` 11 项 | A |
| 服务端 TLS（`SMG_TLS_CERT_PATH`/`_KEY_PATH`）+ fail-fast 校验 | 契约 `tls_server` 19 项（渲染断言 + 明文不通 + 缺 key 被拒） | A |
| `/_ui` 别名全家 + 静态 SPA + RuntimeConfig 落盘 | 契约 `ui_fixed` / `ui_auth`；`e2e_ui_bridge` 19/0 | A |
| HEAD 镜像每个 GET 路由（axum `get()` 的隐式 HEAD） | `test_head_routes.py` 120/0 | A |

### 2.3 观测

| 能力 | 证据 | 强度 |
|---|---|---|
| Prometheus 文本 exposition（按需渲染、HELP/TYPE 完整、空家族不出行） | 契约 `prometheus` 14 + `observability` 55 项；`metrics_check.py` 做唯一性/语法/histogram 不变量判定 | A |
| `smg_worker_pool_size` 按 `(worker_type, connection_mode, model)` 三元组真实派生 | 契约 `observability` + `e2e_grpc` 注册节/PD 节 7 条全量相等断言 | A |
| discovery layer-4 家族（含 Rust 侧只 describe 的 `sync_duration_seconds`，Lua 是唯一有样本的一侧）与 watch/router-pod 家族 | `e2e_discovery_dp` 117/0 逐条校验 HELP/TYPE/值域 | A |
| OTel：W3C trace 生成/继承/回写、OTLP/HTTP 导出、批量、采样率、采集器故障与恢复、优雅退出前 flush | `test/unit/test_otel.lua` 131/0；`e2e_otel.py` 119/0（A–I 九组） | A |
| 独立 metrics 监听（缺省 `:29000`，`SMG_METRICS_PORT=0` 关闭） | 入口脚本渲染 + 契约 `observability` | A |
| `/_ui/history` 存储统计 | 契约 `history_crud` 100 项内 | A |

### 2.4 上一版记为「未接线」，现在全部 A 档

| 能力 | 接线形态 | 证据 |
|---|---|---|
| mesh / HA 集群面 | `router.lua` require `mesh`，`mesh.ROUTES` 17 条（13 条 `/ha/*` + 4 条 `/_mesh/internal/*`）注册进路由表；`SMG_ENABLE_MESH` 未设时同一 handler 回固定 503（与接线前逐字节一致），开启后走 `mesh.dispatch` | 契约 `mesh` **46 项**（disabled 与 enabled 两态都钉）；`test_mesh` 361/0；`test_mesh_http.py` **47/0**（真实 HTTP：worker 生命周期镜像、`/_mesh/internal/state` 快照解码、伪造 apply、深路径 404、loopback 门 403） |
| conversations / responses 持久存储 | `router.lua` require `history`；`/v1/conversations*` 8 条 + `/v1/responses/{id}` 面 4 条 + `/_ui/history` 全部委托 `history.lua`；后端 `memory` / `none` / `redis` | 契约 `history_crud` **100 项**；`test_history` 731/0；`test_history_redis.lua` luajit 101/0(+1 skip)、resty 110/0；`e2e_history_redis.py` **44/0**（真实公共 Redis；门禁内以 `LR_REDIS_REQUIRED=1` 跑，不可达即 FAIL） |
| `/v1/responses` 请求元数据 + 流式条件入库 | `patch_response_metadata`（七字段字节级 splice，不整表重编码）+ `StreamingResponseAccumulator` 复刻；persistence 分支 = `store=true` **或** `conversation` 为字符串（含空串），只有这一支启用累加器；其余 SSE 零缓冲直通。**断开语义**：persistence 分支客户端断开后继续 drain 上游、上游干净结束时入库；非持久化分支立即拆泵、不入库；上游读取错误两分支都不入库 | `e2e_responses_store.py` **18/0**（非流式七字段、数组保形、存储副本一致、无 store/conversation 的 SSE 不入库、`store` 与 `conversation` 两种流式入库、断开后上游完整 drain 且 `store=true` 落库 / no-store 不落库、空字符串 `conversation` 入库、两种 item 事件名各自合成回退终态）；`e2e_stateful.py` 第 5 节（**60/0**，比上一版 +17）里再钉 17 条 responses 断言（C2 四条 + C4 十条 + 注册/健康/无报错三条）；逐条语义见 [gap-responses-final.md](gap-responses-final.md) |
| tool-call / reasoning 解析 | `router.lua` require `parse`；`POST /parse/function_call`、`POST /parse/reasoning` 委托 `parse_mod`，auth 经 `parse_mod.auth_checks` 显式注入 | 契约 `tokenizer_plane` **80 项**；`test_tokenizer_parse` 316/0 |
| tokenizer 注册表 + tokenize/detokenize 代理 | `router.lua` require `tokenizer`；`POST /v1/tokenize`、`/v1/detokenize`（数据面 key）、`/v1/tokenizers[/{id}[/status]]`（控制面 key，含 HEAD 别名） | 同上 `tokenizer_plane` 80 项。L1 限制保持：**不实现 BPE/SentencePiece，只代理**；无声明后端回 501 `tokenizer_unavailable`（Rust 是 400 措辞，§4.1） |
| gRPC 路由 | `SMG_GRPC_PORT>0` 渲染独立 listener（`conf/grpc-server.conf.template`），`grpc_proxy.route()` 挂 `access_by_lua_block`；`:path` 原样透传，模型取自 `x-smg-model` | `e2e_grpc.py` **90/0**（真实 nginx + 真实 grpcio）；`test_pd` **373/0**；镜像能力实证 gap-grpc-pd §1 |
| PD 分离（gRPC）+ **原生 proto body 注入** | 主请求选 prefill；bootstrap 三元组缺省写进 sglang 原生 `GenerateRequest.disaggregated_params`（field 10，与 Rust `helpers.rs` 同字段同编码；单例 message 必须**原位替换而非追加**，否则 merge 语义会串房）；decode 落点走扩展字段 101/102/103；`LR_GRPC_PD_METADATA=on` 退回旧 metadata 载体、`=off` 不注入、body 无法安全改写时自动回退 metadata；`/readiness` 由 `conf/grpc-readiness.conf` 覆盖 | `e2e_grpc` PD 节含 `[pd-body]/[md-mode]/[md-off]` 27 条（google.protobuf 动态描述符 + 手写扫描器双解码器对拍、5 MB 溢写仍改写、9 MiB 回退、幂等）；`test_pd` wire 编解码 373/0（protoc 参考字节逐字相等）；差分 270/270；详见 [gap-grpc-proto.md](gap-grpc-proto.md) |
| PD 分离（HTTP `pd_router`） | `registry` 在 `SMG_GRPC` 开启时接受 `worker_type=prefill|decode`（含 `bootstrap_port`）；关闭时按旧契约回 400（§4.1 第 6 条） | 契约 `workers` 段两类状态；`e2e_discovery_dp` `[k8s-pdg]` 组（prefill 连 `sglang.ai/bootstrap-port` 注解一起注册） |
| K8s service discovery + watch + router pod | `init.lua` → `service_discovery.lua`，list/watch 双模式（`SMG_SERVICE_DISCOVERY_WATCH`）、resourceVersion 续传、410 relist、fieldSelector、router selector 只进 mesh 不进 worker池 | `test_service_discovery.lua` **298/0**；`e2e_discovery_dp` **117/0**（watch ADDED/MODIFIED/DELETED、断线续传、410、router pod adopt/retire、DP×K8s） |
| dp_aware（DP 展开 + `data_parallel_rank` 注入） | `registry.expand_dp()` 展开成 `<base>@<rank>`；`router.lua:1911` 调 `discovery().inject_dp_rank(payload, worker)` 注入请求体 | `e2e_discovery_dp` DP 组（dp_size=4 → 4 条 rank 候选、rank 上推理可用、单 rank 撤收、`/server_info` 500 不展开、关时不展开、交叉组 pod url 4 rank） |

### 2.5 与 Rust 契约对齐的公开面

`/health` `/liveness` `/readiness` `/v1/models` `/model_info` `/server_info`（各有 `get_*` 与 HEAD 别名）、
`/metrics`、`/engine_metrics`、`/health_generate`、`/v1/loads`、`/flush_cache`、`/parse/*`、`/_ui/*`
全家、`/ha/*`、`/_mesh/internal/*`、`/wasm`。Rust `gateway/src/server.rs` 的 **85 条 path+method 配对
一条不缺**（§3 探针复跑）。

`/health_generate` **不再是固定 501**：现在按 Rust 的 `RouterManager::health_generate` 回
纯文本 200 "At least one router has healthy workers" / 503 "No routers with healthy workers available"，
并挂 HEAD 别名（上一版 §2 那一行「Lua 固定 501」已过期）。

### 2.6 模块清单（接线判据速查）

`router.lua` 直接 require：`hb` `observability` `otel` `policy` `registry` `history` `mesh` `parse`
`tokenizer` `jwks` +（懒加载）`limit` `service_discovery` `config_store`。
`init.lua` 负责 wire：`history.configure`、`wire_history_redis()`、`wire_otel()`、mesh 状态捕获、
`service_discovery` 启停。`registry.lua` 在 `SMG_GRPC` 开启时接受 grpc/PD 枚举。
入口脚本负责渲染 gRPC listener。**没有代码的只有四个方向**：wasm、MCP、`history_postgres`、
`history_oracle`。

## 3. 路由面探针（判据与本轮复跑结果）

**判据**：用括号配对从 `gateway/src/server.rs` 抽出全部 **85 条 `.route(path, methods)`**
（72 个不同 path；`get().post().delete()` 按方法各计一条），逐条打一个无 worker 的干净 Lua 实例 →
**90 次探针**（`any` 按 GET+POST 各一次）。脚本 `/data/tmp/lr-docs3/route_probe3.py`，
本轮复跑副本 `/data/tmp/lr-docsfinal/route_probe3.py`，结果 `route_probe_final.txt`；
`8000cfb6…` 稳定树（= 交付镜像）上的重跑留档 `route_probe_stable_8000cfb6.txt`，逐项相同。

本轮（代码树 `8000cfb6…`，对着 `lua-router:integration` 镜像、`SMG_METRICS_PORT=0` 的干净实例复跑，
结果与上一版逐行一致）：

| 状态码 | 次数 | 归类 |
|---|---|---|
| 200 | 30 | 公开面 + `/_ui` 读面 + `/metrics` + `/_ui/history` |
| 400 | 10 | 存在的路由做入参校验（`POST /workers` 缺 url、`/v1/tokenize` 缺 prompt、`/parse/*` 缺 text、`/v1/tokenizers` 缺 name、`/v1/conversations/{id}/items` 缺 items、`/_ui/config/*` 形状） |
| **404** | **16** | **全部是业务 404**（未知 `/workers/{uuid}` 3 条 + 不存在的 conversation / response / tokenizer id 13 条）。**路由一条都没缺** |
| 501 | 7 | wasm 三条（**TODO 档**）+ `/_ui/v1/stream`、`/_ui/v1/chat/completions/control` 各 GET+POST（Rust 对这四条同样回 `v1_ui_unsupported`，不计缺口） |
| 503 | 25 | `/ha/**` 12 条（mesh 缺省关闭，与接线前逐字节一致）+ 13 条「无 worker」正常回包（推理面 7 条、`/_ui/v1/*` 2 条、`/readiness`、`/health_generate`、`/v1/models`、`/_ui/config/model-map` 未配 watcher） |
| 500 | 1 | `/engine_metrics` 无 worker（契约 `proxy_endpoints` 钉住的形态） |
| ERR | 1 | `GET /_ui/logs/stream` 需要长连接，探针不计 |

对照上一版（`c0570b84…`，接线之前）：诚实 501 共 29 次、其中对齐 Rust 的 25 次。**这 25 次里有 22 次
随着 history / tokenizer / parse 接线消失**（变成 200 / 400 / 业务 404），只剩 wasm 3 条 +
Rust 自己也 501 的 4 条 `/_ui`。这是本次刷新最实质的变化：
**「501 清单」已经从「一整个子系统」收缩成「三条 wasm 路由」**。

历史（仅存档）：`c96b6556…` 那一波有 15 条 path+method **连路由都没挂、直接裸 404**
（`/parse/*`、`/wasm*`、`/v1/tokenizers/{id}[/status]`、`/v1/conversations/{id}/items[/{item_id}]`、
`/v1/responses/{id}/input_items`）。核心第二波先统一收编成诚实 501，接线波再把它们各自接到实现上。
`/v1/loads/stream` 的档位也已变更：不再是「Lua 自己多挂的 501」，契约现在钉它是 404
`not_found`（`test/test_lua_router.sh:2318`），与 Rust 的 axum 表一致。

复现：`bash /data/tmp/lr-docsfinal/route_probe3.py` 前先 `echo <port> > /data/tmp/lr-docsfinal/probe_port.txt`。
变量替换表：`{response_id}`→`resp-1`、`{conversation_id}`→`conv-1`、`{item_id}`→`item-1`、
`{worker_id}`/`{module_uuid}`→任意 UUID、`{tokenizer_id}`→`7`、`{key}`→`smg`。

## 4. B 档：已文档化的有意偏差与架构限制

### 4.1 对外可观察的契约偏差（消费方需逐条评估）

推导在 [gap-core.md](gap-core.md) §四 与
[gap-integration.md](gap-integration.md) §5；编号已被 README 引用，改动需同步。

1. `PUT /workers/{id}` **同步落库**立即生效（Rust 是异步 job，`job_status` 里能看到 update 作业）。
2. per-worker 健康参数只部分生效：`health_failure_threshold` / `_success_threshold` /
   `disable_health_check` 按 worker 读；`health_check_timeout_secs` / `_interval_secs` 只存不作用。
   Rust 更绝对：per-worker 一概忽略。
3. 排队超时回 **429**，Rust 回 408；且 release 直接返还令牌、等待者 10 ms 内被放行，缺省配置几乎走不到。
4. CORS 覆盖面比 Rust **更宽**：`/_ui/*` 也能预检并带回 CORS 头；未注册路径的 `OPTIONS` 回 200
   （Rust 的 tower 层实际回 404）。预检不进 `smg_http_requests_total`、不带 `x-request-id`（与 Rust 一致）。
5. `/flush_cache` 响应形状 `{results,success,all_failed}`，Rust 是 `{successful,failed,total_workers,http_workers,message}`。
6. `worker_type=prefill|decode` 与 `connection_mode=grpc|grpcs` 在 **`SMG_GRPC` 关闭时回 400**
   （Rust 分别塌缩为 Regular / 真支持）。`SMG_GRPC_PORT>0` 打开平面后两类注册正常接受。
   刻意保留严格值域：未知 `worker_type` 值一律 400，不学 Rust 的静默塌缩。
7. `smg_http_rate_limit_total` 只在限流启用时有样本（Rust 同样只在挂中间件时计数）。
8. `SMG_PROMETHEUS_DURATION_BUCKETS` 进程生命周期内只读一次；改桶宽时 `observe()` 在新宽度下重建
   直方图（n/s 保留，`_sum`/`_count` 仍正确）。
9. 404 响应体：Lua 回 JSON 错误体 + `X-SMG-Error-Code`，Rust fallback 是空体 404（契约 NOTE 之一）。
   只看状态码的客户端无差异。
10. 方法门控：`/_ui/*` 已正确 405+Allow（硬断言）；`/v1/*` 与公开面仍 404 JSON。契约用
    `request_method_gate` 同时接受两种，所以套件绿但没对齐（契约 NOTE 之二）。
11. `/workers` 值型：字段名集合全等，但 `cost` 是 int、`metadata` 是 `{}`（Lua 5.1 cjson 编不出 `1.0`）；
    `metadata.served_model_name` 在 Rust 的 metadata 里，Lua 放在 record 顶层。
12. `/v1/loads` 形状：Lua 自出一套 `{loads:[…],timestamp}`（信息量更全），Rust 是
    `{workers:[{worker,load}],total_workers,successful,failed}`。契约记 NOTE 未统一。
13. tokenizer 无声明后端：Lua 回 **501 `tokenizer_unavailable`**，Rust 回 400
    "No tokenizers available. Use POST /v1/tokenizers to add one."（状态码与措辞都不同）。
14. `/ha` 深路径：disabled 503 `{"error":"mesh not enabled"}`（保持旧契约）、enabled 404
    `{"error":"unknown ha route: ..."}`；Rust 两种情况都是 axum fallback 404 空体。
15. `/_mesh/internal/*` 端口归并：Rust 放独立 mesh 端口（39527）、靠网络隔离；Lua 放业务端口，
    用「有 key 时要求控制面 key、无 key 时仅 loopback」的更严门补偿（401/403 有契约断言）。
16. `SMG_HISTORY_MAX_ITEMS_PER_REQUEST` 缺省 100（Rust 硬编码 20）。
17. `POST /v1/responses` 非流式 2xx **无条件入库**，是 Rust OpenAI-mode 行为的超集（Rust 的
    Regular/PD 不存路径在本路由不存在）。流式分两支：**persistence 分支**（`store=true`，或
    `conversation` 是字符串——含空串，对齐 Rust `Option<String>::is_some()`）启用累加器，客户端断开后
    **继续 drain 上游**，上游**干净结束**时照常回填并入库；**非持久化分支**（既无 `store=true` 也无可判定的
    `conversation`）客户端断开立即拆泵、**不入库**。两种分支下**上游读取错误都不入库**（对齐 Rust 的
    `upstream_failed`）。Lua 不改写下发给客户端的 SSE 事件本身，只在内部累加终态后入库。逐条语义与
    代价（每个提前离开的客户端最坏占住一条上游连接直到 `lua_socket_read_timeout`）以
    [gap-responses-final.md](gap-responses-final.md) 为准。
18. `/server_info` 与 `/model_info` 是**有意超集**：3 个共享键全在 + 自身配置摘要；`/model_info`
    是 fan-out 聚合（Rust 代理单 worker）。
19. 独立 metrics server 只挂 `/metrics` 与 `/health`，与主监听不共用路由表（刻意的最小实现）。
20. `/engine_metrics` 无 worker 时回 500（契约钉住的形态），Rust 侧是另一套代理语义。
21. 会话面错误体：`/v1/conversations*` 用 `{"error":"<msg>"}` + `X-SMG-Error-Code`，
    `/v1/responses*` 用 openai 形 `{"error":{type,code,param,message}}`（分别对齐 Rust 两侧）。

### 4.2 架构限制：gRPC / PD（不是「未完成」）

**根因**：`ngx_http_grpc_module` 每 gRPC 调用开一条上游 HTTP/2 连接，**不做 h2 multiplex**；
Rust 侧 tonic 每 worker 复用一条连接。实测（`/data/tmp/lr-grpc/`，同一台机器）：

```
in-flight=100  established-to-upstream-19600=100  established-from-client-19500=1
upstream 无 keepalive ：60 并发慢调用，峰值上游 TCP = 92
upstream keepalive 32：60 并发慢调用，峰值上游 TCP = 60
```

下行 1 条、上行 100 条；`keepalive` 只把连接数压到「并发数」，压不到 1。
推论：`worker_rlimit_nofile` 与握手开销要按 **in-flight RPC 数**乘，不能按上游实例数估。
这是模块级限制，不是接线缺失；细节见
[gap-grpc-pd.md](gap-grpc-pd.md) §1.4 / §8。

同族的其他 gRPC/PD 架构限制（同一根因链，全部已实测）：

- **PD 无 prefill/decode 并发双发，decode 落点走扩展字段**：bootstrap 三元组的**原生 proto body
  注入已做**（A 档，gap-grpc-proto.md）；仍缺的是 Rust `execute_dual_dispatch` 那种同请求克隆双发
  （nginx 每请求只有一个 `grpc_pass` 上游，decode 靠 prefill 中继），以及 stock 引擎对扩展字段
  101/102/103 的读取（proto3 未知字段被跳过，中继需后端配合）。
- **nginx 层 gRPC 重试不可用**：`error_page 502 = @retry` 实测第二次请求丢 body（后端报
  UNIMPLEMENTED "requires exactly one request message"），变量式上游不参与 `grpc_next_upstream`。
  换 worker 发生在**下一请求**（Lua 选择 + 熔断器收敛）。
- **上游形态选变量式 `grpc_pass $lr_grpc_scheme://$lr_grpc_peer`**：`balancer.set_current_peer()`
  不接受域名（实测 `balancer: no host allowed`）；变量式白得 `http{} resolver` 的域名支持，
  两种形态 p50 0.9ms vs 0.8ms（噪声内）。
- **模型只认 `x-smg-model` metadata**：字节代理不解析 body，没有别的携带点；点名不中 → UNAVAILABLE
  而不是悄悄换模型。
- **裸 `grpc://` 记录无探活**：镜像里不会说 `grpc.health.v1`，注册即 `disable_health_check`，
  存活由熔断器从真实调用学习；因此 PD worker 必须带 http(s) url 注册（否则 400），且
  `/readiness` 用 `pd_available`（健康+熔断器）而不是 `is_healthy`。
- **gRPC 面不跑 HTTP 侧的策略栈**：cache_aware 等的亲和状态 key 是 HTTP url，塞 grpc 记录会污染
  前缀树；gRPC 面只实现 round_robin / sticky（routing-key→blake3 环）/ power_of_two。
- **gRPC listener 只讲 HTTP/2**：HTTP/1.1 打它得到 502。就绪探针、控制面、UI 永远指向主端口。

### 4.3 架构限制：mesh 与进程模型

mesh 的状态表在 **Lua 进程内存**（不在 `ngx.shared.DICT`，原因见 gap-mesh.md §4.4），所以
`worker_processes>1` 时只有 worker 0 同步、其余读到自己那份表。补偿：入口脚本在 mesh 真值且未显式
`NGINX_WORKER_PROCESSES` 时钉成 1。同一限制也适用于 cache_aware（树是 per-process，
parity-routing #6：4 进程亲和率 1.000 → 0.625）与 bucket，出厂模板缺省 `auto`，所以这两条都靠
入口脚本收敛。**Rust 单进程天然无此问题**，这是本实现的环境差异而非策略缺陷。

其他：树快照跨进程搬运有 `LR_SNAPSHOT_MAX_BYTES`（3 MiB）上限，超限跳过；mesh 的 `/ha/status`
在 seed peer 与对端自报名不同时短暂出现第 3 个 `init` 成员（幻影键，收敛后合并，契约用轮询而非直断）。

### 4.4 架构限制：K8s discovery 与 tokenizer

- **list 轮询而非 watch**（无长连接 chunked 读取封装）。后果：两次轮询之间出现又消失的 pod
  不会被看到，也没有 `resourceVersion` 续传。对长驻推理服务无实际后果。
- **只做 list 权限、不带 `field-selector`**（Rust 也没用），phase 判定在本地做；PD 模式一次 list
  全取、客户端按三组 selector 分类。
- **router pod 发现（Rust `router_selector` / mesh 端口注解）未实现**（归 mesh 范围，见 §5）。
- **`SMG_GRPC` 关闭时 PD pod 注册失败并计入 failed + WARN**，不静默降级成 regular（Rust 会建成
  Regular）。要 PD 就得开 gRPC 平面 —— 这是 §4.1 第 6 条的 discovery 侧后果。
- **tokenizer 面只代理、不实现 BPE/SentencePiece**：舰队里没有支持 `/v1/tokenize` 的后端时
  （llama.cpp 就没有）这条链只能 501。Rust 侧 `apply_effort_policy` / `prefix_hash` 的 token 口径
  本来就在 impl-hash.md 偏差 6 里改成了字符数。

### 4.5 指标覆盖率（摘要，权威口径在 gap-metrics-final.md）

分母口径（**旧版「28/48」作废**）：Rust `smg_*` 字面量 49（含 2 条注释里的死名字）→
注册家族 **47** → 其中 **7 条在 Rust 侧 describe-only、永不产生样本** → 仪表盘真能查到的是 **40**。

| 口径 | 上一波 | 本轮 |
|---|---|---|
| Lua 代码级家族名 | 37 | **43** |
| 与 Rust 47 的交集 | 31（66.0%） | **37（78.7%）** |
| 对 Rust 实渲染 40 的覆盖 | 31/40（77.5%） | **36/40（90.0%）**（`inflight_request_age` 见 doc/gap-inflight-age.md） |
| 「子系统已实现但缺指标」 | 6 | **0** |
| Lua 独有超集 | 6 | 8（`smg_http_inflight_requests`、`smg_http_inflight_request_age_dropped_total`、`..._age_slots_active`、`smg_cache_aware_tenant_count`、四条 `smg_otel_*`） |

剩余 11 条的构成：**表 A（Rust 侧死代码，两边都拿不到数据，不实现）6 条** ——
`smg_db_operations_total`、`smg_db_operation_duration_seconds`、`smg_db_connections_active`、
`smg_db_items_stored`、`smg_router_stage_duration_seconds`、`smg_worker_connections_active`；
**表 B（D 档 TODO）4 条** —— `smg_mcp_servers_active`、`smg_mcp_tool_calls_total`、
`smg_mcp_tool_duration_seconds`、`smg_mcp_tool_iterations_total`；
**表 C 0 条** —— `smg_http_inflight_request_age_count` 已用真实采样闭合（槽表 + worker 0 定时器，
见 doc/gap-inflight-age.md），语义偏差（累积直方图 over duration 阶梯、`_count` 数的是样本数）记在同文件 §3。

本轮补齐的 5 条及其语义差：`smg_router_tpot_seconds`（用请求总时长派生，非流式或极短流会偏小）、
`smg_router_generation_duration_seconds`（同一语义搬到 HTTP 面）、`smg_http_connections_active`
（读 nginx `stub_status` 的 reading+writing，刻意减掉 waiting 以对齐 Rust 的原子计数；模块缺失时整条
序列消失而不是渲染 0）、`smg_worker_routing_keys_active`（数的是 `lr_policy` 里的**粘性绑定数**，
Rust 数的是 `WorkerLoadGuard` 在途数 → 长空闲后这条序列会偏高）、`smg_discovery_sync_duration_seconds`
（Rust 只 describe，Lua 是唯一有样本的一侧）。

`smg_worker_pool_size` 的旧实现在 PD 上线后**整体在说谎**（`prefill`/`decode` 恒 0、`regular` 把
grpc 与 PD 记录也算进去）：现在按注册表派生三元组序列、空组合不渲染、`connection_mode` 归一
（`grpc` 与 `grpcs` 共用一条序列）、计数口径 = 注册表成员数而非健康数。

复现口径（别手抄）：`grep -rhoE '"smg_[a-z0-9_]+"' --include=*.rs gateway/ | sort -u`；
`grep -rhoh "smg_[a-z0-9_]*" lualib/ | sort -u` → 53 个 token；去掉 `"smg_"`/`"smg_discovery_"`/
`"smg_mcp_"` 三个前缀字面量与 `"smg_http_inflight_request_age"`（渲染器用来匹配家族名前缀的串）= **49 个**
名字（`smg_otel_self_test` 是 span 名，`..._age_dropped_total` 与 `..._age_slots_active` 是本轮新增的
Lua 独有超集，所以代码级家族数记 43）。

### 4.6 未做对拍的面（别当成已验证）

- `prefix_hash` / `bucket` / `power_of_two` / `random` 已由 `e2e_policy_parity`（47/0）与
  [parity-policy-extra.md](parity-policy-extra.md) 量化对拍：
  Rust HTTP 面 prefix_hash 恒 503、bucket 不可选、power_of_two 在 worker 无 `/v1/loads` 时退化为随机
  均为实测权威结论；Lua 侧单边不变量全绿。
- 契约的 TLS 段是自签 + 明文反向断言：正式证书链、SNI 不匹配、mTLS 未覆盖。
- `worker_processes>1` 时 cache_aware 亲和率退化到 0.625（4 进程）：生产要用 cache_aware 必须
  显式或隐式收到 1（入口脚本已处理；`conf/lua-router.conf` 是硬编码 1）。
- 非流式 usage 的补验收在 fix-majors 修复后由契约断言覆盖，但**没有在真实上游重跑 token 字段对账**。
- mesh 两个真节点互 seed 的长稳/分区窗口未进契约；router pod 发现已用双真实 router 实例验证收敛，
  fake peer 覆盖 apply/sync/广播三要素。

## 5. C 档：剩余可行动缺口

按建议处理顺序。已完成的旧 C 项（inflight age、gRPC/Redis 门禁、K8s watch、router pod 发现、
四策略量化对拍、注释债）已移入 A 档，不要再当缺口引用。

1. **Lua 非流式每请求 CPU 的 1.54x 回退——修复落地**（定责已完成，见
[parity-cpu-ablation.md](parity-cpu-ablation.md)）：
   P1 请求日志行在容量为 0 时仍整行构建 + P2 worker 记录表每请求从 shdict 重建 5 次（出厂 2 次），
   合计 ≈45–65%，残差里没有语义必需项。剩余动作 = R0 重测当前树比值（1.54x 量于旧树 `5b60aae9…`，
   当前树更贵）→ 按同文 §8 的嫌疑榜顺序修 → 复测。
2. **TLS 入口预检**：证书/私钥不配对与 leaf 缺中间证书时 `openresty -t` 均放行、握手才失败且默认日志
   无因（gap-tls-chain §5/§6 有路线：Lua 侧 openssl 或 vendored 二进制）。
3. **mTLS 客户端证书鉴权**：未实现。e2e_tls_chain 已实测钉住现状（不发 client-CA 名单、带客户端
   证书仍 200）；若要支持属独立立项。
4. **门禁对公共 Redis 的可达性耦合**：不可达即红，需显式 skip 或本地 redis（运维口径，非遗憾）。

本轮已收口的旧 C 项（不要再当缺口引用）：

- **mesh 双真节点长稳/分区 e2e**：`mesh_two` 门 38/0（收敛 / 18 s 长稳 / `docker stop` 分区 /
  恢复 / retire 广播），见 [gap-mesh-final.md](gap-mesh-final.md)。
- **`/ha/status` 幻影键**：根因 = 种子写法与自报身份的记账时机；真修在 `sync_with` 身份统一 +
  hostport 规范化 + 自记录守卫，变异验证摘掉修复点 14/8/2/6 条断言转红（gap-mesh-final §2–§3）。
- **正式证书链 / SNI**：`e2e_tls_chain` 门 112/0/2（根→中间→叶、四类握手负例、RSA/ECDSA×TLS1.2/1.3、
  SNI 同端口双证书指纹），mTLS 拆为上面第 3 条。
- **gRPC PD proto body 注入**：已实现并进门禁（`e2e_grpc` 90/0、`test_pd` 373/0），见
  [gap-grpc-proto.md](gap-grpc-proto.md)。


## 6. 本轮与上一轮的发现记录

### 6.1 `set_top_field` 的 number 分支不匹配普通整数（已修，回归转绿）

`field_pattern` 的 JSON number 分支指数组没加 `?`
（`-?[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)`），普通整数一律不匹配，`set_top_field` 把「成员存在」
判成「不存在」，改为头部插入并留下重复键：

```
IN   {"max_tokens":99999,"n":1}
OUT  {"max_tokens":128,"max_tokens":99999,"n":1}     -- 按 RFC 8259 后者胜出，clamp 实际失效
```

受影响的调用点是 ctx cap（`max_tokens` / `max_completion_tokens`）；`model`、`reasoning_effort`
走字符串分支所以没暴露。修法是把指数组改成 `(?:[eE][-+]?[0-9]+)?`；`e2e_policies` 65/0、
`e2e_ui_bridge` 19/0 两条红同时转绿，并补了防回归断言
`set_top_field replaces an existing integer member without duplicating the key`
（旧 `probes.py` 的 `[json-edit] number member replaced` 是插入形状，曾经掩盖这条路径）。
这条断言现在也在 `set_top_field` 的字节改写纪律上继续生效：`/v1/responses` 的七字段 patch 与
`data_parallel_rank` 注入都走同一条原位 splice，不做整表 JSON 重编码，因此 `tools: []`、未知字段、
数字格式与键序都不变。

### 6.2 注释债（本轮已清）

`router.lua` 顶部原先写 "Deliberately absent: gRPC, prefill/decode disaggregation, wasm and
Kubernetes discovery"，与 §2.4 矛盾（gRPC/PD 走独立 listener、K8s discovery 已在门禁内）。现在那段
改成：这三者已接线（`SMG_GRPC_PORT` / `SMG_SERVICE_DISCOVERY` / `SMG_MESH_PEERS` + 未 opt-in 时
`/ha/*` 固定 503 的契约），真正没做的只有 wasm 中间件（D 档 TODO，三条 `/wasm` 路由答 501，可行性
见 doc/wasm-feasibility.md）与未注册的四条 `smg_mcp_*`，并指向 doc/feature-gap.md 与
doc/todo-deferred.md。`impl-core.md` 的同一句话也已不存在（该文档只保留一处"刻意的最小实现"，与
gRPC listener 相关且仍成立）。


### 6.3 门禁并发教训

`final_gates.sh` 与所有 e2e 都是 host 网络 + 固定容器名前缀，**不可并发**。
`gates-20260930-160644.log`（e2e_stateful `[prefix_hash] workers healthy`）与
`disc.log`（`[dpfail] still exactly one candidate`）各有一次 FAIL，两次都是同时手跑另一套容器密集
套件造成的端口/容器名争用（`/workers` 落到别的进程上返回非 200），串行单独重跑均 PASS。
18:21–18:33 那轮（`gates-20260930-182100.log`）16/16、19:09–19:14（`gates-20260930-190905.log`）
18/18，以及最终 21:13–21:22（`final-stable-20260930.log`）19/19 全绿，都是独占机时跑出来的。

### 6.4 已修完、不要再当缺口引用的历史项

- `probes.py` 钉旧缺省策略的那条红（`round_robin` → `cache_aware`）已随门禁仓库化一并修掉，
  现在 25/0，且在 `GATE_ORDER` 里。上一版 §5.6 那条「测试陈旧」记录作废。
- 上一版「`router.lua` 的 `not_implemented_routes` 25 条」已收缩到 3 条（wasm）。
- 上一版「mesh 面 12 条固定 503 = 未实现」：现在 mesh 是真实现，503 是**缺省关闭时的契约形态**，
  开启路径有 46 项契约 + 47 项真实 HTTP e2e。
- 上一版「`history.lua` 706/2 failed」早已修平（现在 731/0）。
- 上一版「Redis / Postgres / Oracle 已知未实现」：redis **已实现**，只有 Postgres / Oracle 是 D 档。

### 6.5 本文档对应的代码树（稳定树）

本文与 README / verification-final 的所有计数对应 `router.lua` md5
`9d8901937b7e033bdeaa0db7210708fc` + `mesh.lua` `e424e658…` + `grpc_proxy.lua` `70e9366c…`
—— 即 `lua-router:integration` 镜像内副本、`/data/tmp/lr-grpc-proto/gates-live.log`（22:45–22:53）
20/0/1（SKIP_ENV=mesh_two）+ `gates-20260930-225653.log`（GATE_ONLY=mesh_two PASS）合并
**21 门全过** 的树。
`/v1/responses` 流式持久化的客户端断开语义已在这一棵树上落地并被门禁钉住（§2.4 / §4.1 第 17 条），
断言同时存在于 `e2e_responses_store.py`（18/0）与 `e2e_stateful.py` 第 5 节（60/0）。

计数变化相对上一版：契约 795 → 809 → **841**（新增 `inflight_age` 段 32 项）；上一版的
809 = `history_crud` 段 86 → 100（新增 14 项 = 七字段 patch 的
出站/存储直连断言 9 项 + 空字符串 `conversation` 契约 5 项），`e2e_stateful` 43 → **60**
（第 5 节新增 17 条 responses 断言：C2 四条 + C4 十条 + 注册/健康/无报错三条），
`e2e_responses_store` 14 → **18**；`e2e_discovery_dp` 80 → **117**（watch/router pod）；并新增
`e2e_policy_parity` **47/0** 为第 19 门。本轮再叠三笔：`test_mesh` 361 → **391** 与 `mesh_two` 门
**38/0**（幻影键真修 + 双真节点）、`test_pd` 262 → **373** 与 `e2e_grpc` 59 → **90**（原生 proto body
注入）、`e2e_tls_chain` 门 **112/0/2**（证书链），门禁总数 19 → **21**。引用这三份文档的数字时按同一棵树取用；
换树以后请重跑 `bash test/final_gates.sh` 再引用。

## 7. D 档：TODO / Deferred（用户指示 2026-09-30，不实现）

| 项 | 对外行为 | 唯一口径 |
|---|---|---|
| MCP server 调用 | 无路由（Rust 侧 MCP 藏在 Responses API 内部，同样没有独立 HTTP 端点）；`smg_mcp_*` 四条家族刻意不注册 | [todo-deferred.md](todo-deferred.md) §1 |
| wasm 中间件 | `POST /wasm`、`GET /wasm`、`DELETE /wasm/{module_uuid}` 固定 501 `not_implemented` | todo-deferred.md §2；研究见 [wasm-feasibility.md](wasm-feasibility.md) |
| Postgres / Oracle history | `SMG_HISTORY_BACKEND=postgres|oracle` 读写回 501 `history_backend_unsupported`（不塌回 memory 假装成功）；将来入口是既有的 `history.register_backend(name, impl)`，调用点零改动 | todo-deferred.md §3 |

**不在此列**，别顺手标成 TODO：`memory` / `none` / `redis` 三个 history 后端（redis 已实现，
`init.lua` 的 `wire_history_redis()` 在 fork 前注册）、tokenizer 面（只代理，见 §4.4）、
mesh（已实现，缺省关闭）。

引用时不要写成「在接」「排期中」「下一波」：这三项**没有一行代码在朝它们走**，
`grep -rni mcp lualib/ conf/` 只命中 `history.lua` 的 item 类型前缀（那是转发客户端写好的 item）。

## 8. 怎么引用这份清单

- 问「契约对不对」→ §2 + 契约 **841 / 0 / 2**（两条 NOTE 是 §4.1 第 9、10 条），带 e2e 计数与
  `verification-final.md` 的矩阵。
- 问「xxx 是不是已经实现了」→ 先查 §2（A 档）与 §2.6 的接线判据命令；查到实现 + 门禁才说「已实现」。
  **`test_pd` / `test_mesh` / `test_history` 之类单测绿只是必要条件**，不是判据。
- 问「gRPC / PD / K8s / OTel / mesh / tokenizer 上线了没」→ **上线了**（§2.4），
  限制在 §4.2 / §4.3 / §4.4；`SMG_GRPC_PORT` 缺省 0 表示平面缺席，这是部署选择不是实现缺失。
- 问「指标够不够」→ §4.5 摘要 + [gap-metrics-final.md](gap-metrics-final.md)
  的三张表；对实渲染家族 **36/40 = 90.0%**，「已实现子系统缺指标」已清零（§5 第 2 条闭合，
  doc/gap-inflight-age.md）。
- 问「性能会不会退化」→ [parity-perf-v2.md](parity-perf-v2.md)：
  高并发 json Rust 上限更高（auto 形态 Lua ≈ 85%），真实节流流式三方打平，
  Rust 44 ms 即时流 stall 已定界到 Rust 下游 socket 缺 `TCP_NODELAY`（与 Lua 无关），
  **Lua 相对出厂镜像 1.54x CPU 回退未定责 = §5 第 1 条**。旧报告 parity-perf.md 的 stall
  归因段已被取代，不要引它。
- 问「MCP / wasm / Postgres·Oracle 做没做」→ 一律回答**没做，已按用户指示登记 TODO，除非明确指定
  否则不实现**，引 §7 与 todo-deferred.md。
- 问「能不能换成 Lua」→ 路由面没有 404 缺口（§3 复跑），所以先查调用方是否踩 §4.1 的 21 条偏差、
  是否依赖 §4.2 的 gRPC 连接模型或 §4.5 未覆盖的家族，再查 §4.6 的未对拍面是否在它的策略集合里。
- 问「还剩什么能做」→ §5 的 11 条（编号列表），按那个顺序。
