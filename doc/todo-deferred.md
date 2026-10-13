# Deferred TODO：MCP / wasm

**用户指示（2026-09-30）：MCP、wasm 两项登记为 TODO，除非用户明确指定，否则不实现。**

本文是这两项的唯一口径。它们**既不是已完成，也不是进行中**：仓库里没有一行代码在朝
这两个方向走，引用时不要写成「在接」「排期中」「下一波」。

| 项 | 当前对外行为 |
|---|---|
| MCP server 调用 | 无路由：`tools[].type == "mcp"` 的请求体原样透传给上游，网关不解释 |
| wasm 中间件 | `POST /wasm`、`GET /wasm`、`DELETE /wasm/{module_uuid}` 固定 501 `not_implemented`，契约里钉着这条断言 |

曾经的第三项 **Postgres / Oracle history 已随 history 平面一起删除**（scope-trim，2026-10-01）：
`/v1/conversations*` 等路径不注册、`SMG_HISTORY_BACKEND` 一族 env 残留无效果。
要恢复整个平面走 git revert 对应 trim commit，不要在 main 上重写。

## 1. MCP

- 无实现、无配置项：`lualib/` 与 `conf/` 没有任何 MCP 相关条目，也没有调用方依赖网关侧的
  MCP 能力。
- 两条替代路径：调用方自己做工具循环（把工具结果按 function tool 回填进 chat/completions
  或 responses），或在网关前面挂一个 MCP→普通 function tool 的代理。
- 若将来用户明确指定，最小档的形状是：显式开关默认关（关闭时请求体逐字节透传）、只支持
  Streamable HTTP transport、只做非流式（`stream: true` 回 501）、不做出站改写、工具循环轮次
  上限 10、落点 `lualib/resty/luarouter/mcp.lua` 新文件。

## 2. wasm

三条路由固定 501，诚实对外。历史上的可行性结论是：中间件要生效就得整包缓冲请求与响应体，
直接抵消「真实节流流式」这条性能结论，因此**推荐保持不支持**。若将来启用，走独立的 wasm
sidecar 进程 + 网关反代，不要由 LuaJIT FFI 自己实现 Component Model ABI。

## 3. 引用口径

- 「MCP / wasm 到底做了没」→ **没有，用户已指示登记为 TODO**，给本文；不要说「快做了」「在接」。
- 「能不能顺手把 wasm 接上」→ 不能顺手：先拿到用户明确指定，再按 §2 的 sidecar 方案立项。
- 本文不改动任何 Lua / conf / test，也不改 501 的对外契约形状。
