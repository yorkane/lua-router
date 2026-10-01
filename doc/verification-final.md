# lua-router 最终验证汇总（final verification）

日期：2026-09-30（UTC）。执行机：<dev-box>。权威日志（单轮串行、独占机时）：
`/data/tmp/lr-gates/gates-20260930-230302.log`（23:03–23:15 UTC；
**`== summary: 21 passed, 0 failed, 0 skipped ==`**）。拆轮留档（同树同镜像）：`gates-live.log`
（20/0/1，SKIP_ENV=mesh_two）+ `gates-20260930-225653.log`（GATE_ONLY=mesh_two PASS）。历史留档：
`final-stable-20260930.log`（19/19，早于 mesh_two / e2e_tls_chain / proto body 注入）与
`gates-20260930-190905.log`（18 门）。代码树：`router.lua` md5
`9d8901937b7e033bdeaa0db7210708fc`、`mesh.lua` `e424e658…`、`grpc_proxy.lua` `70e9366c…`，
均与交付镜像 `lua-router:integration` 内副本 `md5sum` 一致（构建期 `openresty -t` gate 亦绿）。
本文、README「当前基线」与 feature-gap 头部的计数同源于这一棵稳定树。
对端 = `gateway/` 工作树（Cargo version 0.3.2）。

## 1. 目标与判定标准

在 authz 网关镜像（OpenResty 1.31.1.1 + klib.router + LuaJIT）上复刻 Rust 版 `smg` 网关的
**路由行为与对外契约**，复用同一套 `/_ui` 前端与 `watcher/` 运维链路。判定标准不是逐字节一致，
而是**行为对拍**：同请求 → 同状态码 / 同错误体形状 / 同策略指标 / 同 Prometheus 家族语义。

三条验收判据：

1. **路由面完整**：Rust `gateway/src/server.rs` 的 85 条 path+method 配对，Lua 一条不缺（探针实测，§4.1）。
2. **契约钉死**：所有已实现能力的对外形状都有断言，且门禁严格模式（首个 FAIL 即退出）全绿。
3. **偏差可引用**：与 Rust 不同的地方必须落在 B 档（已文档化的有意偏差 / 架构限制），
   不允许「未记录的差异」。档位定义在
   [feature-gap.md](feature-gap.md) §1。

明确不做的三件事（用户指示 2026-09-30 登记 TODO）：MCP server 调用、wasm 中间件、
Postgres/Oracle history 后端。见 [todo-deferred.md](todo-deferred.md)。

## 2. 实现范围

| 平面 | 已实现内容 | 开关（缺省） |
|---|---|---|
| HTTP 推理 | 7 条路由字节透传 + 顶层 `model` 定点改写；流式零缓冲；DP rank 与 ctx cap / effort / 虚拟别名改写 | 常开 |
| 路由策略 | random / round_robin / power_of_two / manual / cache_aware / bucket / consistent_hashing / prefix_hash | `SMG_POLICY=cache_aware` |
| worker 控制面 | POST / GET / PUT / DELETE `/workers[/{id}]`、`POST /flush_cache`、幂等复用 id | 常开 |
| 鉴权 | 数据面 / 控制面 API key、多 key + admin/user 角色 + 审计日志、控制面 JWT/JWKS | key 空 = 开放；`SMG_JWT_JWKS_URI` 未给 = JWT 分支关闭 |
| 传输 | 上游 https（SNI，不验证书）、服务端 TLS、上游 cosocket 连接池、CORS 三件套、全局并发限流 + 队列 | `SMG_TLS_*` 空、`SMG_MAX_CONCURRENT_REQUESTS=-1` |
| 观测 | Prometheus 文本 exposition（42 家族名）、`/_ui/logs*` 请求日志、OTel W3C trace + OTLP/HTTP 导出、独立 metrics 监听 | metrics `:29000`；`SMG_ENABLE_TRACE` 未设 = 追踪关 |
| 存储 | history 后端 memory / none / redis（纯 Lua RESP2）；conversations 面 8 条 + responses 管理面 4 条 + `/v1/responses` 元数据 patch 与条件流式入库 | `SMG_HISTORY_BACKEND=memory` |
| 集群 | mesh / HA：CRDT 状态同步、`/ha/*` 13 条 + `/_mesh/internal/*` 4 条、全局 rate-limit、优雅停机、worker 生命周期镜像 | `SMG_ENABLE_MESH` 未设 = 固定 503（与接线前逐字节一致） |
| gRPC / PD | 独立 gRPC listener（变量式 `grpc_pass`）、round_robin/sticky/power_of_two 选择、PD 双池 + bootstrap metadata 注入、`/readiness` PD 判据 | `SMG_GRPC_PORT=0` = 整平面缺席 |
| 服务发现 | K8s pod list/watch（selector / namespace / fieldSelector / SA token / resourceVersion 续传 / 410 relist）、router pod 进 mesh、DP engine 展开成 `<base>@<rank>` | `SMG_SERVICE_DISCOVERY=0`、`SMG_SERVICE_DISCOVERY_WATCH=0`、`SMG_DP_AWARE=0` |
| tokenizer / parse | `/v1/tokenize`、`/v1/detokenize`、`/v1/tokenizers[/{id}[/status]]` 管理面、`/parse/function_call`、`/parse/reasoning`（只代理，不实现 BPE） | 常开 |
| `/_ui` | 别名全家 + 静态 SPA + RuntimeConfig 落盘 + watcher 代理 | `LR_UI_CONF=off` 关闭 include |

**没有代码的只有四个方向**：wasm、MCP、`history_postgres`、`history_oracle`。
上一版文档里的「六个模块已备待接线」这个档位已经不存在 —— 接线判据见 feature-gap §2.6。

## 3. 测试矩阵

### 3.1 `test/final_gates.sh`：21 门禁全过（0 failed、0 例外）

| 门禁 | checks | failed | 覆盖点 |
|---|---|---|---|
| build | — | 0 | `docker build -t lua-router:integration`，构建期 `openresty -t` |
| conf | 2 | 0 | `test/conf/nginx-lua-router.conf` + `conf/lua-router.conf` 两份都 syntax ok |
| unit | 9 luajit + 5 resty | 0 | tree 67 / policies 118 / hash 795 / history 731 / mesh **391** / pd+grpc_proxy **373** / service_discovery 298 / jwks 120 / otel 131（luajit）；tree 67 / policies 118 / hash 795 / integration 66 / tokenizer+parse 316（resty） |
| contract | **841** | 0 | 27 段 wire 契约，严格模式（§3.2 分解）；2 条 NOTE 是已文档化偏差 |
| probes | 25 | 0 | 八策略工厂与未知值归一、配置旋钮与 Rust CLI 缺省、map 切分、裸 JSON 改写（含 number 分支防回归） |
| e2e_stateful | **60** | 0 | bucket / prefix_hash / manual / failback / 树快照 / `LR_SNAPSHOT_MAX_BYTES` / 多进程 / 运行中 add worker + 第 5 节 responses C2/C4（新增 17 条：非流式 patch 四条、两种流式入库、断开后 drain 与不落库、空 `conversation`、健康与无报错） |
| e2e_policies | 65 | 0 | 各策略真流量分布 + `LMR_MODEL_CTX` clamp 生效 |
| e2e_ui_bridge | 19 | 0 | `/v1` 与 `/_ui` 两条路径改写逐字节一致 |
| e2e_errors | 10 | 0 | `/_ui` 的 503 / 502 / 上游 4xx 契约 |
| e2e_effort | 4 | 0 | `LMR_MODEL_EFFORT` 强制与 per-model 卡片 |
| e2e_discovery_dp | **117** | 0 | DP 展开、K8s list/watch（ADDED/MODIFIED/DELETED、resourceVersion 续传、断线重连、410 relist、fieldSelector）、router pod 进 mesh（adopt/retire、不进 worker 池）、DP×discovery、discovery 家族与 routing keys |
| e2e_jwt | **48** | 0 | 5 容器分组：RSA-2048 与 EC P-256 签发的 JWS、issuer/audience/exp/leeway、role claim 与映射、kid 轮换与缓存命中、JWKS 端点故障路径 |
| head_routes | **120** | 0 | 每个 GET 路由的 HEAD 镜像（状态码同、body 由 nginx 剥） |
| mesh_http | **47** | 0 | mesh enabled 真实 HTTP：worker 注册/删除到达对端与 `/ha/workers`、`/_mesh/internal/state` 快照可解码、伪造 apply 生效、坏 envelope 400、`/ha/policies/{model}` 命中与 404、非 loopback 无 key 403 |
| e2e_grpc | **90** | 0 | gRPC 面注册（`grpc://` 裸 url 与 `connection_mode` serde tag、端口缺失 400、`worker_type` 值域严格）、unary 与 server-streaming 节奏、metadata 透传与 `grpc-status`/自定义 trailer、grpcs TLS、健康收敛与熔断 UNAVAILABLE、PD 双池 + bootstrap 三元组 + `/readiness` 三态、`smg_worker_pool_size` 五元组全量相等、第二 router 的 sticky 与 router 侧 deadline、**PD bootstrap 原生 proto body 注入**（field 10 原位替换、google.protobuf 动态描述符 + 手写扫描器双解码器、5 MB 溢写仍改写 / 9 MiB 回退 / 幂等 / metadata·off 模式回归，+31 条） |
| e2e_history_redis | **44** | 0 | 共享 Redis 上的 conversations/items/responses/`/_ui/history` 全链（每步用独立 RESP 客户端复核）+ 第二实例同读 + `max_conversations` 淘汰 + 缺 url 回落 memory + redis 不可达时 503 `history_unavailable` 且推理不受影响（门禁内 `LR_REDIS_REQUIRED=1`，Redis 不可达即 FAIL） |
| e2e_otel | **119** | 0 | A–I 九组：trace 生成/继承、`traceparent` 回写、子 span、批量与 60s 间隔下的优雅退出 flush、采样率（ratio=0 一条不导、0.25 部分导出且集合 ⊆ 客户端所见）、`/metrics` 计入未采样请求、SSE 带 traceparent、4xx 标 `STATUS_CODE_ERROR`、采集器不存在时请求照常 + 失败计数 + WARN + 恢复后继续导出、全程无 Lua 崩溃 |
| e2e_responses_store | **18** | 0 | 非流式七字段元数据 patch（含数组保形、存储副本与客户端字节一致）、无 store/conversation 的 SSE 不入库、`store=true` 与带 conversation 两种流式入库、断开后上游完整 drain 且 `store=true` 落库 / no-store 不落库、空字符串 `conversation` 入库、两种 item 事件名各自合成回退终态 |
| e2e_policy_parity | **47** | 0 | prefix_hash（Rust HTTP 恒 503 权威实测、Lua 粘滞/截断/摘除恢复）、bucket（边界 1365、失衡逃逸、Rust 不可选）、power_of_two（有/无 loads 双场景，Rust no-loads 退化为随机）、random（N=10000 χ² 双侧过检） |
| mesh_two | **38** | 0 | 双真 router 容器互 seed（SELF 写 loopback、PEERS 写 LAN，历史出幻影键的形状）：收敛到 2 alive 无 hostport 幽灵、双向 worker 镜像、18 s 长稳（≥10 轮同步、零抖动、零 sync 失败）、`docker stop` 分区窗口（幸存者 unreachable 恰为对端、仍答 chat）、恢复再收敛、`/ha/shutdown` 202 + `peers_notified`、retire 后 roster 无幻影、两侧无 Lua abort |
| e2e_tls_chain | **112** | 0 | 运行时 PKI（根 RSA3072 → EC-P384 中间 → 叶，SAN 含 DNS+IP）：只信根 200、链深度 2、四类握手负例（expired/rogue-CA/非 CA 签发/自签，curl/python/s_client 三方同因）、RSA 与 ECDSA×TLS1.2/1.3、SNI 同端口双证书按 ServerName 指纹路由、证书/私钥不配对 fail-closed（`-t` 放行但每次握手 alert 40）、TLSv1.1 拒、全实例无崩溃（2 NOTE 见 §3.3 附注） |

### 3.2 契约 841 的段构成（逐段 PASS 求和 = 841，0 FAIL，2 NOTE）

| 段 | checks | 段 | checks | 段 | checks |
|---|---|---|---|---|---|
| gate | 3 | public | 30 | workers | 74 |
| inference | 38 | headers | 13 | **mesh** | **46** |
| **history_crud** | **100** | **tokenizer_plane** | **80** | not_found | 15 |
| **observability** | **55** | proxy_endpoints | 56 | policy_hint | 13 |
| ui_fixed | 51 | tls_upstream | 11 | cb_race | 6 |
| ui_auth | 34 | igw | 7 | discovery | 5 |
| prometheus | 14 | probes | 29 | cors | 37 |
| virtual_models | 15 | ratelimit | 14 | **auth_rbac** | **33** |
| **jwt_gate** | **11** | tls_server | 19 | **inflight_age** | **32** | |

两条 NOTE（不是失败）：`404 body divergence`（Rust fallback 空体 vs Lua JSON + `X-SMG-Error-Code`）、
`method mismatch`（axum 对方法不符回 405+Allow，Lua 的 `/v1` 与公开面回 404 JSON，门同时接受两种）。
都是 B 档偏差（feature-gap §4.1 第 9、10 条）。

计数历史：266 → 322（fix-majors，M1–M6）→ 474（核心第二波：CORS / 限流 / 虚拟别名 / 501 收编 /
`PUT /workers`）→ 659（history + tokenizer/parse + mesh 接线）→ 717（HTTP 语义与观测清单 1–7）→
780（`data_parallel_rank` 注入 + 控制面 JWT）→ 795（Prometheus 家族收尾，`observability` 段 55 项）→
**809**（`/v1/responses` 七字段 patch 的出站/存储直连断言 9 项 + 空字符串 `conversation` 契约 5 项，
全部落在 `history_crud` 段：86 → 100）→ **841**（新增 `inflight_age` 段 32 项：真实年龄采样、桶对齐、
并发登记、跨进程采样、打断回收、TTL 自愈、关闭即缺席与关闭过滤探针，doc/gap-inflight-age.md）。

### 3.3 门禁内新增的两条外部依赖套件（原「需要单独跑」）

| 套件 | checks | 前置条件与门禁形态 | 纳入前的单跑留档 |
|---|---|---|---|
| `e2e_grpc.py` | **90 / 0** | 宿主机 grpcio（`preflight` 用 `python3 -c 'import grpc'` 硬检查，缺失 exit 2）+ 两个 mock 端口；真实 nginx + 真实 grpcio 客户端 | `/data/tmp/lr-c1/grpc_final.log`（59/0，proto body 注入之前）；本轮 90/0 在 `gates-live.log` 门内段 |
| `e2e_history_redis.py` | **44 / 0** | 公共 Redis `<shared-redis:6379>`；门禁以 `LR_REDIS_REQUIRED=1` 跑，不可达 FAIL + exit 1（脚本另有 `--require-redis`）；手动不带该变量仍是 SKIP + exit 0 | 稳定树上重跑同为 44/0：`/data/tmp/lr-docfix/redis_stable.log`；单测口径另 `test_history_redis.lua`：luajit 101/0(+1 skip)、resty 110/0 |

两条都验证过「失败会真的红」：`LUA_TEST_REDIS_PORT=6399 GATE_ONLY=e2e_history_redis bash
test/final_gates.sh` → `0 passed, 1 failed`（rc=1，不是 skip）；
`PYTHONPATH=<含抛 ImportError 的假 grpc.py> GATE_ONLY=e2e_grpc bash …` → preflight exit 2。

`e2e_grpc` 覆盖：gRPC 面注册（`grpc://` 裸 url 与 `connection_mode` serde tag、端口缺失 400、
`worker_type` 值域严格）、server-streaming 与 bidi、metadata 注入（bootstrap 三元组 + decode 落点）、
`grpc-timeout` 解析/收紧、PD 双池选择与故障切换、`/readiness` 三态、trailers-only 的
`content-length: 0` 形状、`smg_worker_pool_size` 五元组全量相等（注册节 4 条 + PD 节 3 条）、
grpcs 不塌进 `connection_mode`、熔断器记账规则。**这些现在都在门禁内**（`e2e_grpc` 是第 15 门），
所以「21 门全绿」可以直接支撑「gRPC/PD 面（含原生 proto body 注入）无回归」；旧口径「另跑 e2e_grpc 59/0」自 2026-09-30 起作废。

### 3.4 计数口径说明

本表一律取**最终门禁日志里的末轮计数**（`gates-live.log` + `gates-20260930-225653.log`，见头部）。各补齐报告在写作当时记录的
数字与末轮不一致，是因为后续轮次增删过断言而不是矛盾；差值来源那一列只有契约与 e2e_grpc、
e2e_discovery_dp 三条是报告里写明由谁加的，其余是据修复清单的推断，接手时若在意请自行核对：

| 套件 | 补齐报告里的值 | 本轮末轮值 | 差值来源 |
|---|---|---|---|
| `head_routes` | 118（gap-test-gates.md 新建时） | **120** | 推断：HTTP 语义轮把 `/_ui/config`、`/_ui/history` 两条 DIVERGENT 断言翻成「200 + 与 GET 的 header parity」两条硬断言（gap-http-semantics.md 修复清单第 3/4 项） |
| `mesh_http` | 48（gap-test-gates.md 新建时） | **47** | 推断：第 9 节把「必须 PUT 才刷新」的对照断言换成单条「无需 PUT 已刷新」（同一份 gap-http-semantics.md） |
| `e2e_discovery_dp` | 68 → 72 → 80 | **117** | watch + fieldSelector + router pod 发现（gap-discovery-watch.md） |
| `test_pd` | 219（gap-grpc-pd.md §5） | **262** | 接线波补的注册表门禁 / metadata 发布 / `pd_preferred` 断言 |
| `e2e_grpc` | 52（gap-grpc-pd.md §5.1 表） | **59** | gap-metrics-final §5 的 `smg_worker_pool_size` 7 条 |
| `test_history_redis.lua` | luajit 101(+1 skip) / resty 110 | 同左 | 网络段在 luajit 口径不可跑，属正常差异 |
| 契约 | 474 / 659 / 717 / 780 / 795 / 809（各波报告） | **841** | 见 §3.2 的计数链 |
| `e2e_stateful` | 43（gap-test-gates.md / 上一版本文件） | **60** | 第 5 节新增 17 条 responses 断言（C2 四条 + C4 十条 + 3 条健康/无报错），含断开与空 `conversation` 用例（gap-responses-final.md） |
| `e2e_responses_store` | 14（上一版本文件） | **18** | 断开语义拆成 drain + `store=true` 落库 + no-store 不落库三条、空串 `conversation`、两种 item 事件名的回退终态 |

### 3.5 门禁纪律

`final_gates.sh` 严格模式（首个失败即退出），`SKIP_ENV` 必须写门禁名（未知名直接 exit 2），
跳过会被记进日志尾部的 `skipped:` 行，所以绿跑不可能被偷偷缩水。**所有套件都是 host 网络 +
固定容器名前缀，不可并发**：`gates-20260930-160644.log` 与 `/data/tmp/lr-c1/disc.log` 各有一次
FAIL，实为同时手跑另一套容器密集套件造成的端口/容器名争用（`/workers` 落到别的进程上返回非 200），
串行单独重跑均 PASS。上表 21 门（`gates-live.log` 20/0/1 + `GATE_ONLY=mesh_two` 补跑）是独占机时串行跑出来的；
纳入的两条各约 21 s / 9 s。

## 4. 对比测试结论

### 4.1 路由面完整性（探针复跑，本轮新增）

脚本 `/data/tmp/lr-docs3/route_probe3.py`（本轮副本 `/data/tmp/lr-docsfinal/route_probe3.py`）：
从 `gateway/src/server.rs` 括号配对抽出 **85 条 path+method 配对**（72 个不同 path），
代参后打一个无 worker 的干净实例 → **90 次探针**（`any` 按 GET+POST 各一次）。

结果（`route_probe_final.txt`）：**200 30 次、400 10 次、404 16 次、501 7 次、503 25 次、500 1 次、
长连接 ERR 1 次**。

- 16 次 404 **全是业务 404**（未知 `/workers/{uuid}` 3 条 + 不存在的 conversation / response /
  tokenizer id 13 条）→ **路由一条都没缺**。
- 7 次 501 = wasm 3 条（D 档 TODO）+ 4 条 `/_ui/v1/*`（Rust 同样回 `v1_ui_unsupported`）。
- 25 次 503 = `/ha/**` 12 条（mesh 缺省关闭，逐字节等于接线前的契约形态）+ 13 次「无 worker」正常回包。
- 1 次 500 = `/engine_metrics` 无 worker（契约 `proxy_endpoints` 钉住的形态）。
- 10 次 400 都是入参校验（缺 url / prompt / text / name / items、`/_ui/config/*` 形状）。

**与接线前的对照**：上一轮同样的探针有 29 次诚实 501，其中对齐 Rust 的 25 条覆盖
tokenize / detokenize / tokenizers / conversations / responses / parse / wasm 七个方向；
这 25 条里有 22 条随 history / tokenizer / parse 接线消失（变成 200 / 400 / 业务 404）。
「501 清单」从「一整个子系统」收缩成「三条 wasm 路由」。

### 4.2 契约对拍（[parity-contract.md](parity-contract.md)）

33 组逐字段（两侧 headers/body 原始件留档 `/data/tmp/parity/contract/`，另有 2 组机制探针不计入表），
外加 <dev-box>:8800 生产实例仲裁。Lua 侧修掉 7 类偏差：IGW 缺 model 语义、非字符串 model、错误体
content-type、`x-request-id` 覆盖、chunked vs content-length、转发白名单里的 pin 头、HEAD 别名。
修后 **MATCH 10 / DIFF 20 / INFO 3**；DIFF 里 10 行是任务书已认偏差、4 行 Lua 有意超集、
3 行 serde 措辞、2 行 mock 回显面。另有 6 条**是 Rust 侧不对**（`/v1/rerank` 丢客户端 model、
typed body round-trip 丢未知字段、JSON 响应打 `text/plain` 等），Lua 不跟着改错。

### 4.3 路由行为对拍（[parity-routing.md](parity-routing.md)）

比的是行为特性（均匀性、粘滞性、重分布比例、亲和率、负载逃逸），不是逐次同一 worker。

- `round_robin`：分布与 Rust 同档。
- `consistent_hashing`：**两侧逐 key 落点完全相同**（blake3 环位逐位兼容，摘 1/5 时
  unchanged 0.80、collateral 0；摘除前落点一致率 60/60，每 worker 计数逐位相同，χ² 3.467）。
- `manual`：粘滞成立；「worker 恢复后回切」原本背离，已修复并保持。
- `cache_aware`：亲和率 1.000（单进程）。**已量化偏差**：`worker_processes=4` 退化到 0.625
  （基数树 per-process），consistent_hashing 不受进程数影响；负载逃逸方向一致、Lua 略弱（0.100 vs 0.058）。
- **未对拍**：`prefix_hash` / `bucket` / `power_of_two` / `random`。`prefix_hash` 与 Rust 没有可移植的
  worker 映射（blake3 ≠ xxh3），跨实现对齐落点这件事本身不成立。

### 4.4 性能（[parity-perf-v2.md](parity-perf-v2.md) = 当前代码的权威；[parity-perf.md](parity-perf.md) 的数据仍可用但代码树早于接线波）

数据规模：主矩阵 + 慢流修正 + 同机 A/B 共 kept 63 行 / excluded 6 行、9 230 484 次请求，
消融 40 行 5 966 718 请求，auto 组 24 行 3 263 416 请求，**全部 err=0**。被排除的组带原因保留。

| 维度 | 结论 |
|---|---|
| 非流式 json（同机同 mock） | Rust 吞吐上限更高、每请求 CPU 更省：C=64 达成率 92%（26 411 RPS）、~374–399 µs/req；Lua 4 worker 42%（12 010 RPS）但那一格 CPU 钉在 400%，是 **worker 数饱和而不是代码上限** |
| 生产形态 `worker_processes auto` | Lua 22 207 RPS / CPU 1009% / 454 µs/req vs Rust 26 088 / 975% / 374 µs/req → **同等 CPU 预算下 Lua 少约 15% 吞吐** |
| 真实节流流式（chunk 20 ms × 10，C=128） | **三目标完全打平**：直连 681.8 / Lua 677.8 / Rust 678.4 RPS（差 <0.6%），p50 186.97 / 187.32 / 187.08 ms，净开销 Lua +0.35 / Rust +0.11 ms → 路由层在解码路径上不是瓶颈 |
| 即时流式（mock 一次写完） | Rust 恒定 44 ms/响应（358 RPS，达成率 3%），Lua 8 294 RPS。**已定界**：落点在 Rust 的下游 accepted socket 缺 `TCP_NODELAY`（客户端 busy-QUICKACK 把 357 → 4 861 / 7 245 RPS，p50 44.0 → 3.0 / 2.0 ms）—— 与 Lua 无关，v1 §4.1 的「归因未闭合」已闭合 |
| Lua 自身回退 | 工作树每请求 CPU 从出厂的 201–307 µs/req 涨到 333–454（同格 +37~65%，越并发差得越多）；关掉请求日志 + server 级 CORS 预检后仍有 **1.54x** → **已定责**（parity-cpu-ablation.md：P1 日志行容量 0 仍整行构建 + P2 worker 记录表每请求 shdict 重建 5 次 vs 出厂 2 次，合计 ≈45–65%，无语义必需项）；修复落地前须先跑同文 §8 的 R0 重测（1.54x 量于旧树 `5b60aae9…`） |
| 流式连接池 | 接线波的上游连接池是净收益：µs/req 453–465 vs 出厂 481–501，且上游 mock CPU 从 180 核% 降到 87 核% |
| 内存 | Lua 4 worker 69–91 MiB；`auto`（144 worker）1.36–2.13 GB —— **worker 数是 Lua 侧任何容量结论的必带参数**；Rust 110–146 MiB（146–147 线程常驻） |

### 4.5 真实上游（[real-eval.md](real-eval.md)）

经 `<real-upstream-host>`（APISIX 边缘 + SGLang 后端）三个真实模型：

- **18/18 通过**（功能矩阵 15 + 实例启动 / TLS 验收 / 控制面轮换），5 题语义与直连等价，
  负样本模型 `q38fn-pennyroyal`（无 worker）的 503 契约对齐。全程低频串行、请求间隔 ≥2 s，未压测。
- **prefix cache 调度准确性成立**：cache_aware 选工 52/52 无漂移，`cached_tokens`/prompt ≈
  **97–99%**（首轮 null、第 2 轮起命中、乱序重放命中不掉、interleave 打散不掉），router 侧无实例打散。
- 前提事实：HTTPS 上游的显式 `sock:sslhandshake` 是这次评测期间落地的（旧实现明文发 443，
  APISIX 回 "The plain HTTP request was sent to HTTPS port"，健康探测 33/33 failure）。
- 边界：单 worker URL 场景下粘滞结论偏弱（router 侧无打散动作可做）；上游页粒度 1600 token，
  短会话拿不到命中；非流式 usage 的修复**没有在真实上游重跑 token 字段对账**（feature-gap §4.6）。

### 4.6 指标覆盖率（[gap-metrics-final.md](gap-metrics-final.md) 是唯一权威口径）

Rust `smg_*` 字面量 49（含 2 条注释里的死名字）→ 注册家族 **47** → 其中 **7 条 Rust 侧
describe-only、全仓无调用点** → 仪表盘真能查到的是 **40**。Lua 代码级 43 个家族名，与 Rust 交集 37，
对 40 的覆盖 **36/40 = 90.0%**；「子系统已实现但缺指标」已清零 ——
`smg_http_inflight_request_age_count` 由槽表 + worker 0 定时器真实采样（登记/注销在 `router.lua`
进出两处 + log 阶段兜底），语义偏差与实测见 [gap-inflight-age.md](gap-inflight-age.md)。
Lua 独有超集 8 条（`smg_http_inflight_requests`、`..._age_dropped_total`、`..._age_slots_active`、
`smg_cache_aware_tenant_count`、四条 `smg_otel_*` 自监控）。**旧版「28/48 家族」口径作废。**

`smg_worker_pool_size` 的 C1 硬缺陷（PD 上线后 `prefill`/`decode` 恒 0、`regular` 把 grpc 记录也算进去）
已按注册表派生修好，并有契约 + `e2e_grpc` 的 7 条全量相等断言钉住（期望值由 `/workers` 现算，不写死）。

## 5. 已知偏差与后续建议

### 5.1 偏差

全部落在 feature-gap 的 B 档：对外契约偏差 21 条（feature-gap §4.1，含 `/flush_cache` 与 `/v1/loads` 形状、
404 带 JSON 体、`/v1` 方法门 404 而 axum 405、CORS 覆盖面更宽、排队超时 429 而 Rust 408、
`PUT` 同步生效、`cost` 编不出 `1.0`、tokenizer 无后端 501 而 Rust 400、`/ha` 深路径措辞、
`/_mesh/internal/*` 端口归并、`MAX_ITEMS_PER_REQUEST` 100 而 Rust 20、
`/v1/responses` 非流式无条件入库是超集等），架构限制 4 组（feature-gap §4.2 gRPC/PD、§4.3 mesh
与进程模型、§4.4 K8s 与 tokenizer、§4.5 指标语义差）。

最需要被下游知道的四条：

1. **`nginx grpc_pass` 每 RPC 一条上游连接、无 h2 multiplex**（实测 in-flight=100 → 上游 100 条 established）。
   `worker_rlimit_nofile` 要按峰值并发 RPC 数乘，不能按上游实例数估。这是模块级限制，不是接线缺失。
2. **PD bootstrap 走 metadata 而非 proto body**，后端需读 `x-lr-bootstrap-*` / `x-lr-decode-peer`；
   sglang 原生的 `DisaggregatedParams` 要另立项目引入 proto 编解码。
3. **nginx 层 gRPC 重试不可用**（两条 nginx 路实测都不可用），换 worker 发生在下一请求。
4. **mesh / cache_aware / bucket 都是 per-process 状态** → 生产必须 `worker_processes 1`（入口脚本已收敛），
   代价是这些场景下 Lua 用不上多核；`auto` 形态下 cache_aware 亲和率 1.000 → 0.625。

### 5.2 后续建议（按收益排序，与 feature-gap §5 同一份清单）

1. **Lua 非流式 1.54x CPU 回退逐项消融**：给上游连接池、`persist_response`/history、`limit`、
   per-model `policy_for`、`tokenizer`/`parse` 各加 env 开关，单开关复跑 C=64。它决定
   「接线要不要按开关编译掉」，是后续所有优化的成本地基。
2. **`gateway` 下游 socket 显式 `set_nodelay(true)`**（对齐 nginx 默认），把 §4.4 的 stall 从「已定界」
   升到「已验证修复」，并复查 Rust 慢流 p99 在 rep 间 196.7 / 275.7 ms 的摆动是否随之消失。
3. ~~**把 `e2e_grpc` / `e2e_history_redis` 纳入门禁**~~ 已完成（2026-09-30）：两者进入
   `GATE_ORDER`（`mesh_http` 之后、`e2e_otel` 之前），前者加 grpcio 前置检查，后者在门禁内以
   `LR_REDIS_REQUIRED=1` 让 Redis 不可达真的失败。剩余的是「门禁与公共 Redis 可达性耦合」这一
   运维口径（见 §3.3 与 feature-gap §5 第 3 条）。
4. ~~**`smg_http_inflight_request_age_count`** 需要 `router.lua` 进出两处登记请求 id（跨文件工作）~~
   已完成：槽表登记 + worker 0 采样 + log 阶段兜底 + TTL 自愈，契约 `inflight_age` 段 32 项，
   见 [gap-inflight-age.md](gap-inflight-age.md)。
5. **容量规划口径入文档**：Lua 侧任何吞吐/达成率结论必须带 `worker_processes`，4 worker 的数字只用于
   per-request 成本比较；`auto` 组还缺直连基线、rep 2 与 16/32 worker 的中间点曲线。
6. **补 mesh 双真节点长稳/分区 e2e**、正式证书链 / SNI 不匹配 / mTLS、真实上游 token 对账复跑。
   prefix_hash/bucket/power_of_two/random 的 Rust 量化对拍已完成（`e2e_policy_parity` 47/0）。
7. ~~**清 `router.lua` 顶部注释债**~~ 已完成（2026-09-30）：头部注释与 feature-gap §6.2 对齐，
   不再写 "Deliberately absent"。

## 6. 文件索引

| 类别 | 文件 |
|---|---|
| 门禁与套件 | `test/final_gates.sh`（21 门禁）、`test/test_lua_router.sh`（契约 27 段 841）、`test/unit/*.lua`（12 个）、`test/integration/*.py`（16 个）、`test/conf/nginx-lua-router.conf`、`test/mock_llm_worker.py` |
| 实现 | `lualib/resty/luarouter/`：`router` `registry` `hb` `policy` `config` `config_store` `observability` `otel` `jwks` `limit` `hash` `history` `history_redis` `mesh` `tokenizer` `parse` `pd` `grpc_proxy` `service_discovery` `ui` `props` + `policies/`（tree / cache_aware / bucket / consistent_hashing / prefix_hash / utils） |
| 部署 | `conf/nginx.conf.template`、`conf/lua-router.conf`、`conf/ui.conf`、`conf/grpc-server.conf.template`、`conf/grpc-readiness.conf`、`conf/grpc-prototype.conf`（历史探针）、`docker-entrypoint.sh`、`Dockerfile` |
| 状态与口径 | `doc/feature-gap.md`（A/B/C/D 四档）、`doc/todo-deferred.md`（TODO 唯一口径）、本文件 |
| 实现与接线报告 | `doc/gap-core.md`、`doc/gap-http-semantics.md`、`doc/gap-integration.md`、`doc/gap-auth-tls.md`、`doc/gap-dp-jwt.md`、`doc/gap-discovery-dp.md`、`doc/gap-discovery-watch.md`、`doc/gap-mesh.md`、`doc/gap-history.md`、`doc/gap-history-redis.md`、`doc/gap-tokenizer-parse.md`、`doc/gap-grpc-pd.md`、`doc/gap-otel.md`、`doc/gap-inflight-age.md`、`doc/gap-metrics-final.md`、`doc/gap-responses-final.md`、`doc/gap-test-gates.md`、`doc/fix-majors.md`、`doc/wasm-feasibility.md` |
| 第一波实现说明 | `doc/impl-core.md`、`doc/impl-policies.md`、`doc/impl-hash.md`、`doc/impl-ui.md`、`doc/impl-tests.md` |
| 对拍与评测 | `doc/parity-contract.md`、`doc/parity-routing.md`、`doc/parity-policy-extra.md`、`doc/parity-perf.md`（v1，stall 归因已被 v2 §9 取代）、`doc/parity-perf-v2.md`（权威）、`doc/real-eval.md`、`doc/verification-run3.md`（历史记录） |
| 原始证据目录 | `/data/tmp/lr-gates/`（门禁日志）、`/data/tmp/lr-c1/grpc_final.log`（e2e_grpc）、`/data/tmp/lr-docsfinal/`（本轮路由探针）、`/data/tmp/parity/{contract,routing,perf,perf-v2}/`、`/data/tmp/real-eval/`、`/data/tmp/lr-grpc/`（gRPC 镜像能力实证）、`/data/tmp/gapint/`（接线波） |

## 7. 本文对应的代码树（稳定树）

本文（以及 README「当前基线」与 feature-gap 头部）的所有计数对应 `router.lua` md5
`9d8901937b7e033bdeaa0db7210708fc` + `mesh.lua e424e658…` + `grpc_proxy.lua 70e9366c…` —— 也就是 `gates-live.log`（22:45–22:53 UTC）
那轮（+`GATE_ONLY=mesh_two` 补跑）**21 门全过** 的树、以及 `lua-router:integration` 镜像里的副本
（两者 `md5sum` 逐字节一致）。三处文档同源，可以直接交叉引用同一批数字。

`/v1/responses` 流式持久化的**客户端断开语义**已经在这一棵树上落地并被门禁钉住：persistence 分支
（`store=true`，或 `conversation` 为字符串、含空串）在客户端断开后继续 drain 上游、上游干净结束时
入库；非持久化分支立即拆泵、不入库；上游读取错误两分支都不入库。断言同时存在于
`e2e_responses_store.py`（18/0）与 `e2e_stateful.py` 第 5 节（60/0），逐条语义与代价见
[gap-responses-final.md](gap-responses-final.md)。

路由面探针（§4.1）在这棵树上重跑过：对着 `lua-router:integration` + `SMG_METRICS_PORT=0` 的干净
实例，90 次探针的分布与上一版逐行一致（原始件
`/data/tmp/lr-docsfinal/route_probe_stable_8000cfb6.txt`）。换树以后引用这些数字之前，先重跑
`bash test/final_gates.sh` 并同步刷新本文 §3、README「当前基线」、feature-gap 头部与 §6.5。
