# /v1/responses 请求元数据回填与条件流式持久化（最终审计 C2 / C4）

状态：已实现（2026-09-30）。文件只涉及 `lualib/resty/luarouter/router.lua`
与集成测试，`observability.lua` / `service_discovery.lua` 未改动。

## C2 非流式字段回填

参照 Rust `gateway/src/routers/openai/responses/utils.rs:39-98`
（`patch_response_with_request_metadata`）。非流式 `/v1/responses` 命中 2xx 时，
先对上游 JSON 做一次顶层回填，回填后的同一份 bytes 既作为出站 body，也交给
`persist_response` 入库；两次消费看到的是同一对象，和 Rust 只改一份
`Value` 再序列化一次等价。

规则逐条对齐（`missing_or_empty` = 成员不存在 / null / 空串）：

| 字段 | 条件 | 写入值 |
| --- | --- | --- |
| `previous_response_id` | 请求为非空 string，且响应 missing/null/空串且不是对象/数组 | 请求值 |
| `instructions` | 同上 | 请求值 |
| `metadata` | 请求带对象，且响应 missing/null/空串且不是对象/数组 | 请求对象 |
| `store` | 无条件 | `body.store == true`（缺省 false） |
| `model` | 响应 missing/null/空串且不是对象/数组 | 请求 `model`，请求缺失时 `unknown` |
| `safety_identifier` | 仅响应该键存在且值为 null，且请求 `user` 为 string | 请求 `user` |
| `conversation` | 请求为非空 string | 覆盖为 `{"id": ...}` |

与 Rust 的 serde 语义对齐的两处细节：

1. Rust 的 `is_missing_or_empty` 只对 object/array 返回 false，因此
   `"metadata": {}` 视为已存在、不被请求覆盖；`top_field_value` 的正则只识别
   标量成员，会漏看这类结构值。新增 `struct_value_span` + `member_is_struct`
   做顶层感知的结构成员判定（带 PCRE 预筛，避免对大响应逐字符扫描），
   既补上判定，也保证 `set_top_field` 不会在结构成员后面追加同名重复键。
2. `ResponsesRequest.model` 是 `#[serde(default = default_model)] String`
   （openai-protocol `common.rs`，`UNKNOWN_MODEL_ID = "unknown"`），所以请求
   没有 `model` 时 Rust 仍写入 `"unknown"`；`user` 同理是 `Option<String>`，
   JSON null 解出来是 `cjson.null` 而非 Lua 字符串，不参与回填。

回填仍然走 `set_top_field` 式手工 splice，不整表重编码，所以 `"tools": []`
等空数组、未知字段、数字格式与键序保持字节不变（cjson 会把空表编成 `{}`，
这是本文件一贯避开重编码的原因）。

## C4 流式持久化

参照 Rust `routers/openai/responses/streaming.rs:553-660` 与
`accumulator.rs`。累加器的门是 Rust 的
`need_persistence = should_store || persist_needed`：`store == true`，或
`conversation` 是**非 null 字符串**（Rust 读 `Option<String>::is_some()`，
空字符串同样算“存在”，JSON null 在 Lua 侧解成 `cjson.null` 而不是字符串，
与 Rust 的 `None` 对应）。其余 SSE 请求继续走原有零缓冲直通，代码路径不变。

空 `conversation` 这一格与 Rust 逐处对齐：`patch_response_with_request_metadata`
写出 `conversation: {"id": ""}`，存储行带上 `conversation_id: ""`，条目链接因为
查不到该会话而跳过（Rust 在 `persist_conversation_items` 里 warn 后 skip，
这里 `history.create_response` 的 `get_conversation` 判定同一形态）。

累加器移植 `ChunkProcessor` + `StreamingResponseAccumulator`：

- CRLF 归一为 LF，且跨块的孤立 `\r` 先进 `carry` 等下一个字节，避免半个 CRLF
  把事件块切开；
- 以空行（`\n\n`）切块，纯空白块跳过，流结束时残留的非空白也送进解析；
- 每块 `event:` 行优先，否则取 `data.type`；多行 `data:` 以 `\n` 连接；
- `response.created` 只认第一次，`response.completed` 后到覆盖；item 事件按
  `output_index` 收集，事件名同时认 `response.output_item.done`
  （openai-protocol `event_types.rs:41` `OutputItemEvent::DONE`，真实 OpenAI
  SSE 与 Rust 常量都是这一种）和不带前缀的 `output_item.done`（worker 只转
  `data:` 负载、没有 `event:` 行时，`get_event_type()` 回落到 `data.type`，
  只匹配带前缀形态会静默丢掉这些 item）；
- 终态优先 `response.completed` 的 `response`；否则用 created 对象加
  `status = "completed"` 与按 index 排序的 output 数组合成（空数组保持 `[]`）。

入库条件是"上游干净结束"：`stream_ok` 为真才 `accumulator_finish`，终态再走
C2 的同一个回填函数与 `persist_response`。此时 `stream_ok` 描述的是**上游**而不是
客户端——传入累加器时 `stream_response` 里的 `ok` 已经改义。

**persistence 分支：客户端断开后继续 drain 并入库。** `emit` 里 `ngx.print`
失败时置 `client_gone`，此后不再 print / flush，但三个读取循环的条件都放宽成
`ok or client_gone`，累加器继续接收每一块，上游走到 `0\r\n\r\n` 或 EOF 后照常
`accumulator_finish` + 回填 + 入库（Rust 在同一位置置 `receiver_connected = false`
并 "continuing to drain upstream for storage"，streaming.rs:574-610）。断开的那条
连接因此不会被放回上游连接池（`reusable` 仍要求 `ok`）。

**非持久化分支：客户端断开立即拆泵、不入库。**没有累加器时 `ngx.print` 失败即
`ok = false`，与改动前逐字节一致（Rust 的非持久化分支用 `select!` 竞速，客户端断开
就丢掉上游连接，streaming.rs:661-722；工具拦截分支同样主动放弃，streaming.rs:737-749）。

上游读取错误（`ok = false`）在两种分支下都不入库，对齐 Rust 的 `upstream_failed`
跳过持久化并 warn。

## 验证

`test/integration/e2e_stateful.py` 第 5 节新增标准库自写的 responses-SSE worker
（CRLF 分块、event 行、带 `output_index` 的 done 事件、块间 0.12s 延迟），
覆盖：非流式七字段回填与出站数组保形、入库副本与出站一致、`store=true` 流式
可检索、仅 `conversation` 流式可检索、`store=false` 不入库且分块时序不变、
`store=true` 时以 RST 断开后上游仍被完整读到最后一条事件且该响应可 GET、
无 store/conversation 时以 RST 断开不落库、空字符串 `conversation` 也入库、
无 lua 报错。整轮 **60 checks / 0 failed**。

`test/integration/e2e_responses_store.py` 用 mock 自带的 `/stats` 计数证明"上游被
读完了"（不是靠时序猜），并覆盖两种 item 事件名在没有 `response.completed` 时
各自合成的回退终态。整轮 **18 checks / 0 failed**。

`test/test_lua_router.sh` 的 responses 契约段新增出站直连断言：null 的
`instructions` / `previous_response_id` 被请求值填上、`store` 被无条件改写为
请求 false、非空 `metadata: {}` 保持不动、`conversation.id` 挂上、
`tools: []` 不变形，并断言存储副本同样带着回填后的 `store` / `instructions`；
另加一条空字符串 `conversation` 的契约：出站 `conversation.id` 为空串、存储行
`conversation_id` 为空串且该响应可检索可删除。`TEST_ONLY=history_crud` 整轮
**100 checks / 0 failed**。

纯字符串路径另有 luajit/resty 沙箱用例（patch 32 checks、累加器 13 checks），
与仓库既有 `test_integration.lua` 抽取 `set_top_field` 的做法同一口径。

## 已知差异

- Lua 不改写下发给客户端的 SSE 事件本身，只在内部累加终态后入库；Rust 的
  persistence 分支会先 `rewrite_streaming_block` 再喂 accumulator。在本仓库
  现有 mock/真实上游下，客户端看到的事件内容一致，差异只在事件内的
  `store`/`conversation` 字段是否被就地改写过。
- 客户端断开后：persistence 分支继续 drain 上游到结束并入库，非持久化分支立即
  拆泵、不入库——这一条与 Rust 一致，不再是差异。代价是每个提前离开的客户端最坏
  会占住一条上游连接直到 `lua_socket_read_timeout`（默认 60s），Rust 接受同一代价。
  连 connection-delimited 的上游也把 `timeout` 当作干净结束，所以上游若停住，
  persistence 分支会把已经收到的部分作为回退终态入库（Rust 此时按 `into_final_response()`
  的结果处理，形态可能不同）。
- 流式入库的 bytes 是终态表 `json_encode` 后再回填的结果，不是上游原始字节；
  非流式仍是原始字节 splice。
- MCP / tool 拦截不在本实现范围（已登记 TODO）。
