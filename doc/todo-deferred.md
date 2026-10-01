# Deferred TODO：MCP / wasm

**用户指示（2026-09-30）：MCP、wasm 两项登记为 TODO，除非用户明确指定，否则不实现。**

本文是这两项的唯一口径。它们**既不是已完成，也不是进行中**：仓库里没有一行代码在朝这两个方向走，
引用时不要写成「在接」「排期中」「下一波」。

| 项 | 当前对外行为 | 本文 |
|---|---|---|
| MCP server 调用 | 无路由（Rust 侧同样没有独立的 MCP HTTP 端点，MCP 藏在 Responses API 内部） | §1 |
| wasm 中间件 | `POST /wasm`、`GET /wasm`、`DELETE /wasm/{module_uuid}` 固定 501 `not_implemented`，契约里钉着这条断言 | §2 |

曾经的第三项 **Postgres / Oracle history 已随 history 平面一起删除**（scope-trim，2026-10-01）：
`/v1/conversations*`、`/_ui/history` 等路径不注册、`SMG_HISTORY_BACKEND` 一族 env 残留无效果。
要恢复整个平面走 git revert 对应 trim commit，不要在 main 上重写。

## 1. MCP server 调用

- 用户指示日期：2026-09-30；除非明确指定否则不实现。

**当前现状**：Lua 侧零代码，`lualib/` 与 `conf/` 里没有任何 MCP 相关配置项，没有调用方依赖
网关侧的 MCP 能力。替代路径两条：调用方自己做工具循环（把 MCP server 的工具结果按 function
tool 回填进 chat/completions 或 responses），或者在网关前面挂一个 MCP→普通 function tool 的代理。

**已研究结论**（读的是 Rust 侧 `gateway/src/routers/{mcp_utils.rs,openai/responses/*}` 与
`smg-mcp-1.0.0`）：

1. Rust 侧的 MCP 只覆盖 Responses API（挂点 `openai/responses/{non_streaming,streaming,mcp}.rs`
   加 gRPC 路径）；chat/completions、embeddings、rerank 完全不碰。真实缺口只有
   `tools[].type == "mcp"` 这一种请求。
2. 完整等价要做三块，每块都和 lua-router 的定位对撞：(a) MCP 客户端本体（Stdio/Sse/Streamable
   三种 transport、连接池 100/300s、tool inventory TTL 300s、oauth 本地回调端口）；
   (b) 请求内工具循环（Rust `max_iterations` 缺省 10——把网关变成 agent runtime）；
   (c) 流式要在 SSE 里注入 `response.mcp_call.*` 事件并出站改写 body——这等于推翻
   「推理体字节透传 + 顶层定点改写」的 design red line。
3. 指标不构成理由：`smg_mcp_*` 四条家族在 Rust 侧只有 gRPC responses 路径与注册 step 写，
   HTTP 的 openai responses 路径自己都不写；做了 HTTP 最小档也不会自然对齐。

**结论：完整等价不建议做**。若将来用户明确指定，按这个最小档谈：

1. 显式开关 `LMR_MCP_ENABLED` **默认关**，关掉时请求体逐字节透传（契约补「关 = 原样转发」断言）；
2. 只支持 Streamable HTTP transport（Stdio 拉子进程、SSE 已被上游淘汰，都不做）；
3. 只做非流式：`stream: true` 的 MCP 请求直接 501 `mcp_streaming_unsupported`；
4. 不做 `mask_tools_as_mcp` 出站改写，`type:"mcp"` 原样留在响应里；
5. 工具循环上限照 Rust 的 10 轮，超限回错误；连接复用用 `resty.http` + `lrucache`（worker 本地）；
6. 落点 `lualib/resty/luarouter/mcp.lua` 新文件，`inference_handler` 里 `limit().acquire()` 之后、
   上游转发之前分派，保持「无 ngx 也能 require」以便纯 luajit 单测。

## 2. wasm 中间件

- 用户指示日期：2026-09-30；除非明确指定否则不实现。

**当前现状**：三条 wasm 路由固定 501，诚实对外；本文不改变任何契约形状。

**可行性结论**（原 wasm-feasibility 研究的要点）：Rust 侧是 `smg-wasm 1.0.0` = wasmtime +
Component Model（`on-request`/`on-response` 两个 attach point，返回 continue/reject/modify），
且 `--enable-wasm` 在 Rust 侧同样缺省关闭。关键代价：`wasm_middleware` 挂了模块就**整包缓冲**
请求体与响应体，直接抵消「真实节流流式三目标打平」的性能结论；Rust `metrics.rs` 里没有任何
wasm 家族，不做 wasm 对指标覆盖零影响。

**结论：推荐保持不支持。** 若将来启用：复用 `smg-wasm` 作独立 sidecar 进程，Lua 侧只做
`/wasm` 三条路由的反向代理 + 按 attach point 调它的 call-out filter；**不要走 LuaJIT FFI 自己
实现 Component Model canonical ABI**。

## 3. 引用口径

- 「MCP / wasm 到底做了没」→ **没有，用户已指示登记为 TODO**，给本文；不要说「快做了」「在接」。
- 「能不能顺手把 wasm 接上」→ 不能顺手：先拿到用户明确指定，再按 §2 的 sidecar 方案立项。
- 本文不改动任何 Lua / conf / test，也不改 501 的对外契约形状。

