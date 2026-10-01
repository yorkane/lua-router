# 范围收敛与模块裁剪分析（scope-trim.md）

> 用户裁定的新范围（2026-10-01）：本项目只做 **多 GPU 服务的服务发现与请求调度**，
> 需要监控本地 GPU 负载（或从远程监控同步抓取），允许配置远程 LLM 服务加入服务池；
> 不考虑 gRPC、MCP、本地推理、模型管理。服务动态添加、路由动态变更、配置映射改写、
> 流量性能监控、UI 可观察可配置是重点。
>
> **执行状态（2026-10-01 04:0x UTC）：已全部执行完毕。** 七个 commit（6d2103a→732dc0b）落地：
> gRPC+PD、history、tokenizer/parse、auth 全层、K8s discovery、OTel 六面删除；mesh 保留（md5 未变）、
> DP 展开保留并迁入 e2e_stateful。终态：15 门全绿（/data/tmp/lr-gates/full-final.log）、契约 580/22 段、
> 单测 5 文件、Lua 15 837 行（-44%）。用户裁定的最终差异：mesh 保留（本文原判 DELETE，用户改 KEEP）；
> discovery 契约段 5 项保留（测的是 /model_info 元数据发现，属 KEEP 面）。
>
> 同日追加：watcher 合并（`f87b04f`，`watcher.lua` 2024 行 + `e2e_watcher` 门 65/0 + 单测 253/0）与管理控制台 `/_ui/admin/`（`c79264c`，Quasar UMD 静态三页：服务池/模型覆盖/日志监控）已落地；独立 llm-watcher 容器退役。
> 
>> 本文是裁剪判定书：逐模块给 KEEP / DELETE / TRIM 与理由，量化收益，列出测试面影响与
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
| jwks.lua | 705 | **DELETE** | JWT/JWKS 控制面认证（用户裁定不需要） |
| API key / RBAC / 审计层（router.lua 内嵌 + ui.api_auth） | ~400 | **DELETE** | 用户裁定 auth 全部不需要：鉴权交给 authz 边缘与内网信任域，网关层全部端点开放（数据面/控制面/_ui） |
| service_discovery.lua | 2038 | **DELETE** | K8s list/watch 集群发现移出：本机发现由 llm-watcher 承担、远程接入由 /workers+配置承担；DP 展开不在此模块本体 |
| mesh.lua | 2525 | **DELETE** | /ha gossip 多路由器 HA 不在单调度器范围；watcher+unless-stopped 已提供自愈。若未来要多活再从 git 历史恢复 |
| otel.lua | 1381 | DELETE（待确认） | 分布式追踪默认关闭、耦合低；若流量监控只需要 Prometheus 可删，需要跨服务链路追踪再留 |
| wasm / MCP / postgres·oracle | — | 维持 TODO | 用户指示不变（todo-deferred.md 口径） |

## 2. router.lua 与配置面的内部裁剪点

删除（随模块）：jwks 与全部 API key/RBAC/审计认证段（数据面 key、控制面 key、角色、审计、ui.conf 各 alias 的 api_auth 调用）、history 持久化（/v1/responses 累加器、
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
| 契约 | 841 / 27 段 | ≈532 / 20 段（删 history_crud 100、tokenizer_plane 80、mesh 46、auth_rbac 33、ui_auth 34、jwt_gate 11、discovery 5） |
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
- **auth 全删是信任边界变更**：/workers、/_ui、/flush_cache 等控制端点在本网关层全开放，只能暴露在 authz 边缘之后或可信内网，绝不可直接公网（README 需声明信任边界；当前生产本就未配任何 key，行为零变化）。
- **otel 若删**：跨网关请求的链路追踪没了（当前生产未启用，默认关）。

- **cache_aware 不受任何删除影响**：依赖链 = policies/cache_aware + policies/tree + registry 负载字段 + /v1/loads（hb）+ lr_policy 字典，与 8 个删除模块零交集；GPU 负载源（§5.1）落地后其逃逸与亲和决策反而更准。
- **prefix cache 不依赖 tokenizer**：亲和键是**原始文本前缀**（cache_aware 用 tree:prefix_match_with_counts(text)，prefix_hash 用字符数截断——prefix_hash.lua:26 明注“字符数，Rust 侧是 token 数”），路由文本来自 extract_text_for_routing 的消息拼接，全程无分词；tokenizer 模块在 router.lua 只有 :3858-3876 的 /v1/tokenize 代理面注册，策略层零引用（grep 事实）。分词与块级 KV 匹配是后端（sglang/vLLM）的职责，网关只需要“同会话→同 worker”的稳定键，文本身份比分词 id 更稳（还能跨不同 tokenizer 的异构后端）。实证：real-eval 经本网关（从未实现 BPE）在真实上游测得 cached_tokens/prompt ≈97–99%、52/52 选工无漂移。

## 5. 新范围的能力缺口（要新增的，不是删除）

1. **GPU 负载源**：hb 现在只有 /health 与 /v1/loads。新增 load source 抽象：
   (a) 抓后端 /metrics 里的 DCGM/nvidia 指标（本地 GPU 服务）；(b) 远程 Prometheus 查询
   （从现有监控同步抓取）。写入 registry 的负载字段，power_of_two 与 cache_aware 逃逸已是消费端。
2. **路由动态变更**：policy 目前是 env 一次性读入；把全局与 per-model policy 纳入
   config_store 热配置，/_ui 提供切换页，改后免重启生效（现有热配置通道复用）。
3. **远程服务接入体验**：POST /workers 与 LMR_CONFIG_FILE 种子已有；补 UI 表单、
   连通性/模型预检与一键下线。
4. **UI 面板**：GPU 负载、策略分布、请求日志已有底座（/_ui/logs、/engine_metrics、props）。
5. **token 核算与性能计数（不需要 tokenizer）**：事后核算一律走后端自报的 usage——
   router.lua:1262 已有 usage_from_object（prompt/completion/cached/reasoning 四类，含
   prompt_tokens_details.cached_tokens），TTFT/TPOT/吞吐/时长指标已从 timing+usage 派生。
   唯一缺口是流式请求客户端未开 stream_options.include_usage 时后端不发 usage：在转发泵
   上游方向透明注入 include_usage=true、下游在末尾 usage 帧读完后按客户端原意决定透传或剥除。
   覆盖不到的裸 /generate 用可校准的启发式预估（chars/token 比值按模型从观测 usage 回归），
   标记为 estimate。事前预估（拒超长/预算）同用启发式；**不在网关实现 BPE，也不复活被删的
   tokenizer 代理模块**（它是客户端 /v1/tokenize 代理面，本来就不在热路径）。

## 6. 执行顺序建议（每步一个 commit，独立可回退）

1. gRPC+PD（最独立：listener/conf/entrypoint/grpc_proxy/pd + e2e_grpc + test_pd）
2. history（history/history_redis + responses 持久化分支 + history_crud + 两门）
3. tokenizer/parse（模块 + tokenizer_plane + test_tokenizer_parse）
4. jwks（模块 + jwt_gate + e2e_jwt）
5. service_discovery（模块 + discovery 段 + e2e_discovery_dp 拆分保 DP）
6. mesh（模块 + mesh 段 + mesh_http/mesh_two 两门 + /ha 路由）
7. otel（待确认后）
8. 每步跑对应门禁子集；全部完成后全量门禁 + 刷新 README/architect.md 计数 + 重建生产镜像。

