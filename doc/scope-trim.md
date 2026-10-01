# 范围收敛与模块裁剪分析（scope-trim.md）

> 用户裁定的新范围（2026-10-01）：本项目只做 **多 GPU 服务的服务发现与请求调度**，
> 需要监控本地 GPU 负载（或从远程监控同步抓取），允许配置远程 LLM 服务加入服务池；
> 不考虑 gRPC、MCP、本地推理、模型管理。服务动态添加、路由动态变更、配置映射改写、
> 流量性能监控、UI 可观察可配置是重点。
>
> 本文是裁剪判定书：逐模块给 KEEP / DELETE / TRIM 与理由，量化收益，列出测试面影响与
> 新能力缺口。**未执行任何删除**；执行按 §6 顺序单独成 PR。基础计数对应 `9f82a2d` 树
>（28 个 Lua 模块 / 28 215 行、契约 841、21 门禁）。

## 1. 判定总表

| 模块/面 | 行数 | 判定 | 理由 |
|---|---:|---|---|
| router.lua | 4059 | KEEP+TRIM | 核心分发/转发/重试/限流/观测全在这；随删除模块裁掉对应路由段（§2） |
| registry.lua | 1893 | KEEP | 服务池本体：动态增删、健康态、**DP 展开（url@rank）在这里，不随 K8s 删**；裁掉 grpc/grpcs 与 prefill/decode 双池门禁 |
| hb.lua | 374 | KEEP+扩展 | 健康巡检+熔断+/v1/loads 扇出；GPU 负载源的新接入点（§5.1） |
| policy.lua + policies/* | ~3150 | KEEP | 请求调度核心（8 策略全保留，均为 HTTP 面） |
| hash.lua | 964 | KEEP | 环位哈希基础 |
| config.lua / config_store.lua | 1645 | KEEP+扩展 | 配置映射改写（别名/effort/ctx cap/热配置文件）；路由动态变更要落到这里（§5.2） |
| limit.lua | 209 | KEEP | 全局并发闸门（流量管理） |
| observability.lua | 1340 | KEEP | 流量性能监控核心：Prometheus 家族、请求日志环形缓冲、inflight 年龄；裁掉 gRPC 家族的写点 |
| /engine_metrics（proxy_endpoints 段） | — | KEEP | worker Prometheus 文本聚合（Rust metrics_aggregator 等价）——这是监控强化点，不是删点 |
| ui.lua / props.lua / ui.conf | ~840 | KEEP+TRIM | UI 可观察可配置的载体；裁掉 /_ui/models/load、/_ui/models/unload（模型管理面） |
| grpc_proxy.lua | 1756 | **DELETE** | gRPC 面整体移出（用户裁定） |
| pd.lua | 455 | **DELETE** | PD prefill/decode 分离属高级推理拓扑，随 gRPC 一起出范围 |
| history.lua | 2119 | **DELETE** | 会话/消息/responses 持久化不是调度器职责；/v1/responses 仍作为推理端点**纯透传**保留 |
| history_redis.lua | 881 | **DELETE** | 随 history（跨实例共享会话场景一并移出） |
| tokenizer.lua | 1039 | **DELETE** | tokenizer 注册表/代理属模型管理面 |
| parse.lua | 515 | **DELETE** | function-call/reasoning 解析代理属模型管理面 |
| jwks.lua | 705 | **DELETE** | 控制面认证收敛为内建多 key RBAC（auth_rbac）+ authz 边缘；JWT/JWKS 面向企业多租户，超出范围 |
| service_discovery.lua | 2038 | **DELETE** | K8s list/watch 集群发现移出：本机发现由 llm-watcher 承担、远程接入由 /workers+配置承担；DP 展开不在此模块本体 |
| mesh.lua | 2525 | **DELETE** | /ha gossip 多路由器 HA 不在单调度器范围；watcher+unless-stopped 已提供自愈。若未来要多活再从 git 历史恢复 |
| otel.lua | 1381 | DELETE（待确认） | 分布式追踪默认关闭、耦合低；若流量监控只需要 Prometheus 可删，需要跨服务链路追踪再留 |
| wasm / MCP / postgres·oracle | — | 维持 TODO | 用户指示不变（todo-deferred.md 口径） |

## 2. router.lua 与配置面的内部裁剪点

删除（随模块）：jwks 认证段（:50 require + 路由）、history 持久化（/v1/responses 累加器、
patch_metadata 的历史部分、conversation 链接）、tokenizer/parse 分发段、/ha/* 路由段、
gRPC policy hint；conf/ 删 grpc-server.conf.template、grpc-readiness.conf、grpc-prototype.conf
三个文件，entrypoint 删 GRPC_EXTRA 渲染段与 SMG_GRPC_* 校验，Dockerfile 删对应 COPY。

保留：wasm 三条 501（诚实 TODO 形态，3 行）、/v1/responses 透传路由、igw 语义、
/flush_cache、/v1/loads、/engine_metrics、/_ui/logs 与 SSE、全部策略面。

注意：/_ui/history 端点与 UI 里的会话历史页随 history 删除——预构建 SPA 里该页会拿不到数据，
需要一次 UI 重构建移除入口（短期可接受 404，不影响其它页）。

## 3. 量化收益

| 维度 | 前 | 后 |
|---|---|---|
| Lua 模块 | 28 | 20（删 8：grpc_proxy/pd/history/history_redis/tokenizer/parse/jwks/service_discovery/mesh 中 8 个 + otel 待定） |
| Lua 行数 | 28 215 | ≈16 200（-43%）；若删 otel ≈14 800（-48%） |
| 单测文件 | 12 | 4（tree/hash/policies/integration；删 pd/mesh/history/history_redis/jwks/otel/tokenizer_parse/service_discovery） |
| 契约 | 841 / 27 段 | ≈599 / 22 段（删 history_crud 100、tokenizer_plane 80、mesh 46、jwt_gate 11、discovery 5） |
| 门禁 | 21 | ≈13（删 e2e_grpc、e2e_history_redis、e2e_jwt、mesh_http、mesh_two、e2e_discovery_dp、e2e_otel、e2e_responses_store；DP 断言并入 e2e_stateful，responses 透传断言留在 e2e_ui_bridge） |
| conf 文件 | 6 | 3 |

运行时收益：启动面更小（无 gRPC listener/mesh 定时器/history 后端 wire），生产攻击面与
心智负担同步下降；llm-watcher 端口扫描污染面不变（与被删模块无关）。

## 4. 删除风险与边界

- **DP 展开必须活下来**：data_parallel_rank 注入与 url@rank 展开在 registry/router，
  e2e_discovery_dp 里的 DP 组断言要迁走，这是多 GPU 调度的关键能力，不能随 K8s 段误删。
- **/v1/responses 变纯透传**后，客户端若依赖 conversation 链接/存取会失效——确认调用方
  （当前生产只有 opencodex 走 chat/completions，无 responses 持久化使用）。
- **mesh 删除是单向门**：多路由器 HA、router pod 互发现都没了；单实例 + watcher + 
  unless-stopped 是既定生产形态，风险可接受，但要在 README 声明。
- **otel 若删**：跨网关请求的链路追踪没了（当前生产未启用，默认关）。

## 5. 新范围的能力缺口（要新增的，不是删除）

1. **GPU 负载源**：hb 现在只有 /health 与 /v1/loads。新增 load source 抽象：
   (a) 抓后端 /metrics 里的 DCGM/nvidia 指标（本地 GPU 服务）；(b) 远程 Prometheus 查询
   （从现有监控同步抓取）。写入 registry 的负载字段，power_of_two 与 cache_aware 逃逸已是消费端。
2. **路由动态变更**：policy 目前是 env 一次性读入；把全局与 per-model policy 纳入
   config_store 热配置，/_ui 提供切换页，改后免重启生效（现有热配置通道复用）。
3. **远程服务接入体验**：POST /workers 与 LMR_CONFIG_FILE 种子已有；补 UI 表单、
   连通性/模型预检与一键下线。
4. **UI 面板**：GPU 负载、策略分布、请求日志已有底座（/_ui/logs、/engine_metrics、props）。

## 6. 执行顺序建议（每步一个 commit，独立可回退）

1. gRPC+PD（最独立：listener/conf/entrypoint/grpc_proxy/pd + e2e_grpc + test_pd）
2. history（history/history_redis + responses 持久化分支 + history_crud + 两门）
3. tokenizer/parse（模块 + tokenizer_plane + test_tokenizer_parse）
4. jwks（模块 + jwt_gate + e2e_jwt）
5. service_discovery（模块 + discovery 段 + e2e_discovery_dp 拆分保 DP）
6. mesh（模块 + mesh 段 + mesh_http/mesh_two 两门 + /ha 路由）
7. otel（待确认后）
8. 每步跑对应门禁子集；全部完成后全量门禁 + 刷新 README/architect.md 计数 + 重建生产镜像。

