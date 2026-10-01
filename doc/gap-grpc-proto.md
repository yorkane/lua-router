# gRPC PD 原生 proto body 注入（lua-router）

结论先行：**已实现并接线**。PD 的 bootstrap 三元组现在写进 sglang 的原生 proto 字段
（`GenerateRequest.disaggregated_params`，field 10），与 Rust 网关
`gateway/src/routers/grpc/common/stages/helpers.rs:inject_bootstrap_metadata` 写的是同一批
字节，stock sglang 不需要读任何 `x-lr-*` 头。旧的 metadata 载体保留为可切换模式
（`LR_GRPC_PD_METADATA=on`），并在 body 无法安全改写时自动回退。

## 1. 字段号与类型（来自 vendored schema，非推测）

Rust 侧唯一的 PD gRPC 写入点：

```rust
// gateway/src/routers/grpc/common/stages/helpers.rs
let disagg_params = DisaggregatedParams {
    bootstrap_host: hostname.to_string(),
    bootstrap_port: bootstrap_port as i32,      // unwrap_or(8998)
    bootstrap_room: room_id,                    // random_range(0..i32::MAX)
};
request.as_sglang_mut().disaggregated_params = Some(disagg_params);
```

它的类型定义来自 `smg-grpc-client-1.0.0`（`gateway/Cargo.toml:113` 钉住 `=1.0.0`）。
schema 原文在 crate 目录里，生成物在 `gateway/target/debug/build/*/out/sglang.grpc.scheduler.rs`：

```
~/.cargo/registry/src/index.crates.io-*/smg-grpc-client-1.0.0/proto/sglang_scheduler.proto
```

| message | 字段 | 号 | proto 类型 | wire type |
|---|---|---|---|---|
| `GenerateRequest` | `request_id` | 1 | string | 2 (len) |
| `GenerateRequest` | `sampling_params` | 4 | message | 2 |
| `GenerateRequest` | **`disaggregated_params`** | **10** | `DisaggregatedParams` | 2 |
| `DisaggregatedParams` | `bootstrap_host` | 1 | string | 2 |
| `DisaggregatedParams` | `bootstrap_port` | 2 | int32 | 0 (varint) |
| `DisaggregatedParams` | `bootstrap_room` | 3 | int32 | 0 |

生成路径（tonic 客户端与服务端用的是同一份常量）：
`/sglang.grpc.scheduler.SglangScheduler/Generate`。模板注释里出现的
`/sglang.grpc.model_service.ModelService/Generate` 是另一套服务命名，同样以 `/Generate`
结尾，因此路径判定只看最后一段方法名。

`vllm_engine.proto` 里没有 `DisaggregatedParams`（vLLM 不支持 PD），所以注入只对 sglang
的 Generate 有意义 —— 与 Rust 的 `as_sglang_mut()` 会 panic 于 vLLM 是同一个前提。

## 2. decode peer 没有原生字段：扩展 101/102/103

Rust 不需要把 decode 落点写进 body：`request_execution.rs:execute_dual_dispatch` 把同一份
proto 请求 **克隆两份并发**给 prefill 与 decode 两个 client，两边各自看到同一个 room id 就
配对完成。nginx 的 `grpc_pass` 一个请求只有一个上游，做不到双发（这条限制原样保留），
所以本路由把调用只发给 prefill，由 prefill 中继给 decode。

vendored schema 里没有任何承载 decode 地址的字段（全仓 grep `decode_host|decode_peer|
prefill_endpoint` 只命中 `DisaggregationMetrics` 的队列统计，与请求无关）。因此定义三个
**路由扩展字段**，与 1/2/3 同处 `DisaggregatedParams`：

| 扩展字段 | 号 | 类型 | 语义 |
|---|---|---|---|
| `decode_host` | 101 | string | 选中的 decode worker 主机 |
| `decode_port` | 102 | int32 | 其 gRPC 端口 |
| `prefill_dp_rank` | 103 | int32 | prefill url 带 `@rank` 时写入 |

101 起跳是为了远离 vendored schema 已占用的 1–3（同一 message 未来若补原生字段，冲突概率
最低）。proto3 的未知字段被跳过，所以 stock sglang 读到它们不会报错，只会忽略 ——
**decode 中继仍需后端配合**（读 101/102 或继续读 `x-lr-decode-peer`）。这一点是本实现与
Rust 的真实差异，不是可以靠编码消掉的。

## 3. 编解码实现（`grpc_proxy.lua`）

只实现这项任务需要的 wire 子集，并且**每个字段的原始字节都保留**，包括 router 不认识的字段：

- `encode_varint` / `encode_int32`：负 int32 按 prost/protoc 的符号扩展写成 10 字节
  （`-1` → `ff ff ff ff ff ff ff ff ff 01`）。
- `decode_varint` / `skip_varint`：超过 2^53 直接报错而不是浮点截断。
- `parse_message`：把 message 拆成 `{field, wire, raw, payload}`。**未知字段照原样存 raw**；
  fixed32/fixed64 的 tag 是变长的，raw 必须从 tag 起点算到 payload 末尾（实现时这里错过一次，
  由单测钉住）。group（wire 3/4）**报错**而不是猜测 —— 报错的调用走 metadata 回退，比改坏
  body 安全。
- `serialize_fields` / `replace_field` / `find_field`：字段顺序在 wire 上没有语义，但"原位
  替换 + 末尾追加"使改写结果可读、幂等（重复注入不会累积第二个 field 10）。
- `inject_disaggregated_params(message, params)`：在 `GenerateRequest` 上写 field 10，其余字段
  逐字节不动；已存在的 field 10 解析后合并（保留其未知字段），再整体替换。
- `rewrite_generate_body(body, params)`：处理 gRPC 帧（1 字节 flag + 4 字节大端长度）。只有
  **单条、未压缩**消息才改写；两条以上（客户端流式）、压缩帧、帧不完整一律报错回退。
- `is_generate_path(path)`：路径最后一段必须是 `Generate`。
- `pd_carrier()`：`LR_GRPC_PD_METADATA` → `body`（缺省）/ `metadata` / `none`。

`pd_publish(pair)` 在 `route()` 的 PD 分支里取代原先写死 metadata 的代码。回退条件（每种都
在 error_log 记一行原因，因为 bootstrap 缺失的后果是请求在 sglang 侧卡满 300 s 超时）：
非 Generate 方法、body 读不出来、帧不是单条未压缩消息、message 解析失败、整体 pcall 出错。
超过 `PD_MAX_BODY_BYTES`（8 MiB）时不读临时文件，直接走 metadata。

### 为什么必须在 access 阶段读 body（实证）

`authz:latest` 上最小配置实测：`ngx.req.read_body()` + `ngx.req.set_body_data()` 之后，
grpc_pass 转发的是**改写后**的字节，且二进制安全（`\x00\xff\x01...` 原样到达后端），
nginx 自己重算了 `content-length`：

```
后端 echo: b'echo:\x00\xff\x01PRBHELLO\xfe|...|md=content-length=17;...'
```

### 用哪个变量判定方法

`is_generate_path` 读 `ngx.var.uri`，不是 `ngx.var.request_uri`。实测三种位置形态：

```
location /            uri=[/sglang...SglangScheduler/Generate] request_uri=[同]
location /passthru/（rewrite ^/passthru(/.*)$ $1 break）
                      uri=[/probe.Echo/Say]        request_uri=[/passthru/probe.Echo/Say]
```

即 `uri` 是 rewrite 之后、grpc_pass 实际转发的 `:path`（§1.3 那条「不 rewrite 就
UNIMPLEMENTED」的坑正是这件事），`request_uri` 是客户端原始路径。判定必须跟着转发走，
否则带前缀的 location 会永远判不中。

另一条实测：对**响应流式**的方法（sglang 的 Generate 正是 unary-stream）在 access 阶段读
body 不会挂 —— 客户端发完一条消息就 half-close，nginx 拿到完整 body 后才进 access；
真正会长期挂的是 bidi（客户端 3 s 后才发第二条），本实现只认 `/Generate`，碰不到。

## 4. 与 Rust 的差异

| 维度 | Rust | 本实现 |
|---|---|---|
| bootstrap 三元组 | tonic 结构化赋值 | 手写 wire 编解码，写入 field 10，逐字节等价 |
| room 范围 | `random_range(0..i32::MAX)` | 同一函数 `pd.room_id_i32` |
| 端口缺省 | `unwrap_or(8998)` | 同一常量 `pd.DEFAULT_BOOTSTRAP_PORT` |
| decode 落点 | 双发同一 proto 给两个 worker | 单发给 prefill + 扩展字段 101/102（中继需后端配合） |
| 双发 | 有 | **仍无**（nginx 每请求一个上游，限制不变） |
| 失败重试 | tonic 层 | 仍无（限制不变） |

## 5. 测试

### 5.1 单测 `test/unit/test_pd.lua`：262 → **373 passed / 0 failed**

本任务新增 82 项（同一文件里并行任务又补了重复 field 10 的合并语义、多帧 body 整体拒绝等），关键是**用真实 protoc 生成的期望字节做参照**（不是自我印证）：

- `encode_int32` 对 9 组边界值（0/1/127/128/300/8998/i32::MAX/-1/-128/-8998/i32::MIN）与
  python protobuf 的输出逐字节相等；
- 首次注入结果 == `0a02723152100a0831302e302e302e3110a64618b960`（protoc 对同一输入的序列化）；
- 原位替换 + 未知字段（fixed64 20 / len 22 / message 4）**逐字节保留**、幂等；
- 输入校验：空 host、room 超 int32、已损坏的 field 10 一律拒绝改写；
- 帧层：压缩帧、双消息、截断帧、空 body 全部拒绝；
- `is_generate_path` 五例；carrier 开关七例（含无法识别的值回到 body 而不是静默不发）。

### 5.2 端到端 `test/integration/e2e_grpc.py`：59 → **90 checks / 0 failed**

mock 后端新增 `/sglang.grpc.scheduler.SglangScheduler/Generate`（identity 序列化 +
`unary_stream`），用**两个独立解码器**报告字段：

1. `google.protobuf` 动态描述符（真第三方实现，验证 router 的编码器而不是跟它同构）；
2. 手写 wire 扫描器，报告 google.protobuf 看不到的位置信息与未知字段原文。

本任务新增 `[pd-body]` 20 条 + `[md-mode]` 5 条 + `[md-off]` 2 条，覆盖：三元组落在
field 1/2/3、field 10 恰好一份、扩展字段 101/102 对 schema 是未知的、客户端其余字段
（含两个未知字段）原文保留、`google.protobuf` 再序列化后字段集合不变、重复调用不累积、
5 MB（溢出到临时文件）body 仍被改写、9 MB（超上限）回退 metadata、非 message body 不动且
回退 metadata、DP-aware prefill url（`@2`）额外写 field 103、`LR_GRPC_PD_METADATA=on` 时
body **一个字节都不改**且 metadata 照发、`=off` 时两者都不发。`on`/`off`/DP-aware 三种配置各起
一个独立 router，避免污染第一个 router 对 `smg_worker_pool_size` 的精确序列断言。

### 5.3 差分验证（一次性脚本，非仓库门禁）

`/data/tmp/lr-pb/fuzz.lua` 生成 270 个编码输出（5 host × 9 port × 6 room，含 i32::MIN 与
300 字符 host，外层夹两个未知字段），`validate.py` 逐个用 `google.protobuf` 解析并断言：
值正确、field 10 只有一份、未知字段 20/22 原文保留、扩展字段对 schema 未知、二次解码稳定。
**结果 270/270 通过，0 错误，且每个输出重复注入幂等。**

### 5.4 门禁 `test/final_gates.sh`

`e2e_grpc` 已在 `GATE_ORDER`（`mesh_http` 之后），所以 body 注入与 TLS/PD 回归被完整门禁覆盖：
`build / conf / unit / contract / probes / e2e_stateful / e2e_policies / e2e_ui_bridge /
e2e_errors / e2e_effort / e2e_discovery_dp / e2e_jwt / head_routes / mesh_http / e2e_grpc /
e2e_history_redis / e2e_otel / e2e_responses_store / e2e_policy_parity` 全绿。`[tls]` 那条
grpcs 自签 worker 检查同时证明 body 改写与 TLS 上游不冲突：改写发生在 access 阶段，加密在其后。

## 6. 运维

- 默认即原生 body，无需配置。
- 后端只认 `x-lr-*`（既有改造版）时设 `LR_GRPC_PD_METADATA=on`，行为与引入 proto 编解码之前
  逐字节一致。
- `LR_GRPC_PD_METADATA=off` 什么都不注入，纯转发。
- 判断当前调用走了哪条载体：mock/日志里 PD 请求若带 `x-lr-bootstrap-room` 即 metadata 模式；
  error_log 中 `lr-grpc: PD body injection unavailable (<reason>)` 是自动回退的直接证据。
