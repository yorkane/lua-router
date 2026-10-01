# Deferred TODO：MCP / wasm / Postgres·Oracle history

**用户指示（2026-09-30）：MCP、wasm、Postgres/Oracle history 三项登记为 TODO，
除非用户明确指定，否则不实现。**

本文是这三项的唯一口径。它们**既不是已完成，也不是进行中**：仓库里没有一行代码在朝这三个方向走，
`router.lua` 的对应行为保持原样（wasm 面固定 501、history 面走 memory / none / redis），
引用时不要写成「在接」「排期中」「下一波」。涉及这三项的其他表述 —— `feature-gap.md` 的 D 档（§7）与
§4.5 / §5、
README「已知缺口索引」、`doc/gap-history.md`、`doc/gap-history-redis.md` —— 一律指向本文。

| 项 | 档位 | 当前对外行为 | 本文 |
|---|---|---|---|
| MCP server 调用 | TODO · 不实现 | 无路由（Rust 侧同样没有独立的 MCP HTTP 端点，MCP 藏在 Responses API 内部） | §1 |
| wasm 中间件 | TODO · 不实现 | `POST /wasm`、`GET /wasm`、`DELETE /wasm/{module_uuid}` 固定 501 `not_implemented` | §2 |
| Postgres / Oracle history | TODO · 不实现 | `SMG_HISTORY_BACKEND=postgres`（或 `oracle`）读写回 501 `history_backend_unsupported` | §3 |

对照一下**不在此列**的东西，别顺手把它们也标成 TODO：`history_redis.lua` 的 Redis 后端**已实现**
（纯 Lua RESP2 + `init.lua` 的 `wire_history_redis()` 在 fork 前注册），memory / none 后端已接线并有
契约 `history_crud` 段守着；tokenizer / parse / mesh 三条**已接线并在门禁内**（与这三项无关），
见 feature-gap §2.4 与 [verification-final.md](verification-final.md) §3。

## 1. MCP server 调用

- 用户指示日期：2026-09-30；除非明确指定否则不实现。

当前现状 / 替代：Lua 侧零代码，`grep -rni mcp lualib/ conf/` 只命中 `history.lua` 里 item 类型表
（`mcp_call` / `mcp_list_tools` 的 id 前缀与抬平字段），那是**转发客户端已经写好的 item**，不是网关自己调 MCP。
替代路径两条：调用方自己做工具循环（把 MCP server 的工具结果按 function tool 回填进 chat/completions 或
responses），或者在网关前面挂一个 MCP→普通 function tool 的代理，把 MCP 关在路由职责之外。
本仓库与 fleet 的部署面（`conf/`、`deploy/`、`docker-entrypoint.sh`）里没有任何 MCP 相关配置项，
所以当前没有调用方依赖网关侧的 MCP 能力。

已研究结论摘要（读的是 `gateway/src/routers/{mcp_utils.rs,openai/responses/*}` 与 `smg-mcp-1.0.0`）：

1. **Rust 侧的 MCP 只覆盖 Responses API**。挂点是 `routers/openai/responses/{non_streaming,streaming,mcp}.rs`
   加 gRPC 的 `regular/harmony/responses/*`；`chat/completions`、embeddings、rerank 完全不碰 MCP。
   所以「Lua 不做 MCP」的真实缺口只有 `tools[].type == "mcp"` 这一种请求。
2. 完整等价要做三块，每块都和 lua-router 的定位对撞：(a) MCP 客户端本体 —— `McpTransport` 有
   Stdio / Sse / Streamable 三种、连接池（`max_connections` 100、idle TTL 300s）、tool inventory
   （TTL 300s + 60s 后台刷新 + 出错即刷）、`oauth.rs` 还要起本地回调端口；
   (b) 请求内工具循环 —— `McpLoopConfig.max_iterations` 缺省 10（`mcp_utils.rs:21`），
   把 MCP tool 摊平成 function tool 发上游、本地执行、回填、再发一轮，这是让网关变成 agent runtime；
   (c) 流式 —— 要在 SSE 里注入 `response.mcp_list_tools.*` / `response.mcp_call.*` 事件，
   出站再 `mask_tools_as_mcp` 改写 body。本仓库的推理面是**字节透传 + 顶层 `model` 定点改写**，
   (c) 等于推翻这个不变量。
3. **指标不构成理由**。`smg_mcp_*` 四条家族的写入点在 Rust 侧只有
   `core/steps/mcp_registration.rs`（`set_mcp_servers_active`）和 `routers/grpc/{regular,harmony}/responses/*`
   （`record_mcp_tool_*`）—— HTTP 的 openai responses 路径自己都不写这四条。
   即便将来做 HTTP 面的最小档，这四条也不会自然对齐，feature-gap §4.5 表 B 的缺失登记要留着。

结论：**完整等价不建议做**（越出「只做转发」的定位，且成本主体是 agent 循环而不是协议）。
当前只保持指标与文档 TODO。

若将来启用的建议入口（用户明确指定时按这个最小档谈）：

1. 显式开关 `LMR_MCP_ENABLED` **默认关**，关掉时请求体逐字节透传 —— 契约里补一条「关 = 原样转发」断言，
   保证零回归；
2. 只支持 Streamable HTTP transport（Stdio 要在 router 进程里拉起子进程、SSE 是被上游淘汰的形态，都不做）；
3. **只做非流式**：`stream: true` 的 MCP 请求直接 501 `mcp_streaming_unsupported`，不碰 SSE 事件注入；
4. 不做 `mask_tools_as_mcp` 的出站改写，`type:"mcp"` 原样留在响应里（客户端能容忍，因为它自己发出去的）；
5. 工具循环上限照 Rust 的 10 轮，超限回错误而不是继续；连接复用用 `resty.http` + `lrucache`，
   池上限/idle TTL 对齐 100/300s，但放在 worker 本地，不引共享字典；
6. 落点选 `lualib/resty/luarouter/mcp.lua` 新文件 + `inference_handler` 里在 `limit().acquire()` 之后、
   上游转发之前分派，照 history 模块的写法保持「无 ngx 也能 require」以便纯 luajit 单测。

## 2. wasm 中间件

- 用户指示日期：2026-09-30；除非明确指定否则不实现。

当前现状：`not_implemented_routes`（`router.lua:3465`）里三条 wasm 路由固定回
`501 {"error":{...,"code":"not_implemented"}}`。这是诚实的对外形状，**不随本文改变**，契约里钉它的断言继续有效。

已研究结论摘要（完整推导见 [wasm-feasibility.md](wasm-feasibility.md)）：
Rust 侧是 `smg-wasm 1.0.0` = wasmtime + Component Model + `interface/spec.wit` 定义的
`on-request` / `on-response` 两个 attach point，返回 `continue | reject(status) | modify(...)`，
配线程池、pooling allocator 和 epoch interruption 做超时；`--enable-wasm` **在 Rust 侧也缺省关闭**
（`main.rs:486` / `types.rs:553`）。关键代价是 `wasm_middleware` 挂了模块就整包缓冲请求体与响应体，
直接抵消 parity-perf 里「真实节流流式四目标打平」那组结论；`metrics.rs` 里没有任何 wasm 家族，
不做 wasm 对指标覆盖没有影响（Rust `metrics.rs` 里没有 wasm 家族；覆盖率口径见
[gap-metrics-final.md](gap-metrics-final.md)）。

结论：**推荐保持不支持**（见 feature-gap §7 同一行）。

若将来启用的建议入口：**复用 `smg-wasm` 作独立 sidecar 进程**，Lua 侧只做 `/wasm` 三条路由的反向代理 +
按 attach point 调它的 call-out filter；**不要走 LuaJIT FFI 自己实现 Component Model canonical ABI**。

## 3. Postgres / Oracle history

- 用户指示日期：2026-09-30；除非明确指定否则不实现。

当前现状：现有 `memory`（缺省）/ `none` / `redis` 三个后端**已满足当前范围**，跨实例共享会话这件
memory 做不到的事已经由 redis 覆盖（见 `doc/gap-history-redis.md`）。postgres / oracle 由
`history.lua` 的 `UNSUPPORTED_BACKENDS` 门控，读写一律 501 `history_backend_unsupported`、
message 直接建议改用 memory 或 none；不是塌回 memory 假装成功。
`_M.register_backend(name, impl)` 是既有的、唯一将来入口：注册表在 501 门控**之前**查，
装上实现则 `backend_supported()` 与 `stats()` 同时转可用，摘掉又回 501，**调用点零改动**。

已研究结论摘要：Rust 的这两个后端来自 `data-connector-1.0.0` 的 `postgres.rs`
（tokio-postgres + deadpool-postgres 连接池）与 `oracle.rs`（`oracle 0.6.3`，ODPI-C/libclntsh 的 C 驱动），
外加 `config/validation.rs` 一组必填校验（`oracle.username` / `password` / `connect_descriptor` 非空、
`pool_min >= 1`、`pool_max >= pool_min`、`pool_timeout_secs > 0`），env 名是 `ATP_WALLET_PATH` /
`ATP_TNS_ALIAS` / `ATP_DSN` / `ATP_USER` / `ATP_PASSWORD` / `ATP_POOL_*`。
Lua 侧的可行性差异很大：Postgres 尚可（`authz` 镜像里已确认**没有** pgmoon / pgsql 类库，
要纯 Lua 自写 wire protocol；SCRAM-SHA-256 认证所需的 HMAC/PBKDF2 镜像里有 `resty.openssl`，
但本仓库目前只在 `jwks.lua` 里 `pcall(require, "resty.openssl.pkey")` 用过一次，等于是新依赖面）；
Oracle 必须先往镜像里塞 ODPI-C 客户端库再 FFI 绑定，体积与构建链代价超出一个转发网关该承担的量级。
指标同样不构成理由：`smg_db_connections_active` / `smg_db_items_stored` /
`smg_db_operation_duration_seconds` / `smg_db_operations_total` 四条在 Rust 侧是 describe-only
（全仓 grep 没有 `Metrics::record_db_operation` 等调用点，data-connector 自身不发 `smg_` 指标），
做了这两个后端也不会改变指标覆盖率（对 Rust 实渲染 40 个家族的 36/40，见
[gap-metrics-final.md](gap-metrics-final.md) §4）。

结论：**TODO，不实现**。

若将来启用的建议入口：先做 Postgres 一档，照 `history_redis.lua` 的形状写
`history_postgres.lua`（同名 store 函数表、同一套 503/501 错误映射、`install()` 里
`history.register_backend("postgres", _M)`），并复用它的三场景 e2e 骨架
（A 后端生效 / B 缺目标自动回落 memory + WARN / C 目标不可达逐请求 503）；
Oracle 除非有硬需求，否则不排期。

## 4. 引用口径

- 有人问「MCP / wasm / postgres 到底做了没」→ 答：**没有，用户已指示登记为 TODO，除非明确指定不实现**，
  并给本文。不要说「快做了」「在接」。
- 有人问「history 后端缺 postgres 是不是 bug」→ 答：不是，501 是刻意的门控，且 redis 已覆盖共享场景。
- 有人问「能不能顺手把 wasm 接上」→ 不能顺手：先拿到用户的明确指定，再按 §2 的 sidecar 方案立项。
- 本文不改动任何 Lua / conf / test，也不改 501 / 503 的对外契约形状。
