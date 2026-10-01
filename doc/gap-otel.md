# 补齐 OpenTelemetry 追踪（Lua 侧实现）

对应 Rust 侧：`gateway/src/observability/otel_trace.rs`（初始化、批量导出、
`inject_trace_context_http` / `inject_trace_context_grpc`、`flush_spans_async` /
`shutdown_otel`）、`gateway/src/middleware.rs`（`RequestSpan` 的 span 名与字段、
`ResponseLogger` 记录的 `status_code` / `latency`）、`gateway/src/server.rs:1437`
（启动时 `otel_tracing_init`）、`gateway/src/routers/http/router.rs:382`（每次转发前注入）、
`gateway/src/main.rs:556-568`（`--enable-trace` / `--otlp-traces-endpoint`）。

本文只写与 Rust 的差异与取舍；相同部分按“已按上述文件复刻”处理。

实现落在 `lualib/resty/luarouter/otel.lua`（新，约 1350 行），`router.lua` / `init.lua`
只加 hook，`conf` 三处只加 `env` 声明。

## 1. 开关（`SMG_TRACE_*`）

| env | 默认 | Rust 对应 | 说明 |
| --- | --- | --- | --- |
| `SMG_ENABLE_TRACE` | 未设 = 关 | `--enable-trace`（`main.rs:559`，默认 false） | `1/true/yes/on` 视为开 |
| `SMG_OTLP_TRACES_ENDPOINT` | `http://127.0.0.1:4318/v1/traces` | `--otlp-traces-endpoint`（`main.rs:563`，默认 `localhost:4317`） | 见 §2 |
| `SMG_TRACE_BATCH_SIZE` | 64 | `with_max_export_batch_size(64)`（`otel_trace.rs:118`） | 单次 OTLP 请求的最大 span 数 |
| `SMG_TRACE_BATCH_INTERVAL_MS` | 500 | `with_scheduled_delay(500ms)`（`otel_trace.rs:117`） | 批量定时器周期 |
| `SMG_TRACE_TIMEOUT_MS` | 2000 | 无（tonic 默认） | 单批连接的 send/connect 超时 |
| `SMG_TRACE_SAMPLE_RATIO` | 1.0 | 无（SDK 的 parentbased 采样恒采样） | 仅对**自建** trace 生效 |
| `SMG_TRACE_MAX_QUEUE` | `max(256, batch×16)` | `BatchConfig` 的 max_queue_size（SDK 默认 2048） | 队列上限，超出丢最旧并计数 |
| `SMG_TRACE_UPSTREAM_CHILD` | 开 | 无（Rust 不发 HTTP 子 span） | `0/false/no/off` 关掉子 span |

三个 `conf`（`conf/nginx.conf.template`、`conf/lua-router.conf`、
`test/conf/nginx-lua-router.conf`）都加了这 8 行 `env` 声明。值的抓取在
`init_by_lua`（`init.lua:155 wire_otel()`），照 `SMG_MESH_*` 的“先抓后传”模式显式传给
`otel.configure(opts)`，不经 `config.lua`（那不在本次所有权内）；`env` 声明是为了
worker 里的 `os.getenv` 兜底路径和探针能读到同名值。

**endpoint 解析**：接受完整 URL（`http://`、`https://`，以及 OTel 的 `grpc://` /
`grpcs://` 写法，折成 HTTP），也接受 Rust 的裸 `host:port`（补成 `http://host:port/v1/traces`），
所以运维可以直接粘贴 Rust 那套值。空 host、端口越界这类 Rust `validate_trace()` 会拒绝的
输入，这里**不**拒绝启动：tracing 自己关掉、路由不受影响、原因进日志（`init.lua:195`）。
Rust 是 boot 失败；Lua 侧一个观测性拼写错误不该把数据面拉下来，这与其他软配置错误的处理一致。

## 2. 传输差异：OTLP/HTTP JSON（4318）vs Rust 的 OTLP/gRPC（4317）

这是本实现唯一实质性的偏离，需要运维配合改一行 collector 配置：

- Rust：`opentelemetry-otlp` 的 `Protocol::Grpc` + tonic（`Cargo.toml:65` 只编了
  `grpc-tonic` feature），默认 `localhost:4317`，body 是 protobuf 二进制。
- Lua：OTLP/HTTP，body 是 protobuf 的 JSON 映射（OTLP/JSON spec），POST 到
  `SMG_OTLP_TRACES_ENDPOINT`，默认 `127.0.0.1:4318/v1/traces` —— 即 collector `otlp` receiver
  的 `http` 端点。要在同一个 collector 上收两边，receiver 需要同时开：

  ```yaml
  receivers:
    otlp:
      protocols:
        grpc:   { endpoint: 0.0.0.0:4317 }
        http:   { endpoint: 0.0.0.0:4318 }
  ```

  只开 gRPC 的部署（很多默认 compose 只写 4317）会表现为 Lua 侧一直连不上，
  `smg_otel_export_failures_total{stage="connect"}` 单调增长；启动日志里
  `transport_warning()` 会提前点名：endpoint 写 4317 或 `grpc://` 时打一条 WARN，
  说明这里走 HTTP/JSON、要指向 4318。

- **为什么不做 gRPC**：OTLP/gRPC 要 HTTP/2 连接前置、HPACK 头表、gRPC 帧（5 字节前缀）
  加 protobuf wire format，而 OpenResty 的 cosocket 是裸 TCP，`resty.http` 系只有 HTTP/1.1。
  手写这套协议栈放在数据面同进程里，收益只是省一次 JSON 编码，风险是任何一处编码错误就
  变成静默丢全部 trace。JSON 与 protobuf 在 collector 侧解码成同一套 `ExportTraceServiceRequest`
  语义，字段完全一致，因此先交付 JSON，protobuf 不做（`otel.lua` 里 `_M.TRANSPORT` /
  `_M.RUST_TRANSPORT` 两个常量把这个事实写进 `/probe` 输出，避免读代码才发现）。
- **默认端口不同是刻意的**：`SMG_OTLP_TRACES_ENDPOINT` 不设时用 4318，因为那才是本实现
  真的会说的协议；照抄 Rust 的 4317 会让“开箱即用”变成静默失效。
- 时间戳精度：nginx 的缓存时钟是毫秒，`startTimeUnixNano` / `endTimeUnixNano` 是
  `ms × 1e6`，因此末六位恒为 0；`latency` 属性保持 Rust 的微秒口径，末三位恒为 0。
  Rust 报真纳秒。补零用字符串拼接而不是 `ms * 1e6`：毫秒时间戳乘 1e6 约 1.7e18，
  远超 Lua number 的 2^53 精确整数上限，算出来的低位是脏的（这条有单测钉住）。

## 3. W3C 上下文

- **入站解析**（`otel.parse_traceparent`）按 spec 严格判非法：版本 `ff` 拒绝、
  trace-id/span-id 长度不对或全零拒绝、flags 必须两位 hex；版本大于 `00` 允许（前向兼容，
  重渲染时钉回 `00`）。非法值当“没有上下文”，路由自建一条 trace —— 不会把调用方的垃圾
  往上游传。契约套件里既有的 `traceparent: 00-trace-span-01` 透传检查（关闭 tracing 时）
  仍然通过：关闭时 `inject()` 不改 header，值原样带上游。
- **继承**：入站合法 → 同 trace-id，`parent_span_id` = 调用方 span-id，flags（含 sampled 位）
  原样带下去，本地采样率不再起作用（这是 OTel 的 parent-based 语义，也是 Rust SDK 的行为）。
- **自建**：trace-id 16B、span-id 8B 随机（`openssl` 随机，退化时 `ngx.now()`+pid 混合），
  采样在 head 上按 `SMG_TRACE_SAMPLE_RATIO` 决定一次，之后只随 flags 传播。随机源失败时
  直接关掉 tracing 并计数，而不是造一个会跨 worker 撞号的确定性 id。
- **上游注入**（`otel.inject`）= Rust `inject_trace_context_http`（`otel_trace.rs:212`）：
  用 `insert` 语义写 `traceparent`，即**覆盖**调用方留下的值，让 worker 把 router 当父。
  挂点在 `router.lua:965 collect_forward_headers` 的末尾，和 Rust 在 `router.rs:382`
  每次 `route_typed_request_once` 里 clone header 后注入是同一位置。Rust 关闭时
  该函数直接 return，Lua 也一致（`current()` 返回 nil → header 不动）。
- **`tracestate` 不特殊处理**：Rust 的 `TraceContextPropagator` 只写 `traceparent`
  （`otel_trace.rs:232` 的 injector 只被 propagator 调用一次，没有额外构造 state），
  而 `routers/header_utils.rs:214` 早就把 `tracestate` 列为转发 header。Lua 侧同样靠
  通用 header 转发带过去，两边行为一致。
- **gRPC 面**：`otel.inject_grpc` 是 `inject` 的别名（`grpc_proxy.lua` 不在本次所有权内，
  未接线）。Rust 对应 `inject_trace_context_grpc`（`otel_trace.rs:239`），语义同为 insert。
- **响应头回显（Lua 侧新增）**：`begin_trace()`（`router.lua:425`）把 router 自己的
  traceparent 写进响应头，`apply_response_headers`（`router.lua:1606`）在上游 header 拷回来
  之后重新盖章，覆盖 worker 可能带回的值。Rust 完全不回显 traceparent（`middleware.rs` 只
  记录不出头，也没有 `OtelAxumLayer`），所以这是**刻意的偏离**：没有它，调用方只能从 router
  日志里反查自己的 trace-id，`curl -i` 看不到任何关联，验证成本过高。
  走 `/_ui` 聊天别名（`ui_pipeline`，`router.lua:3562`）的请求不建自己的 span，
  只 `echo_request_traceparent()` 原样回显调用方合法值 —— 那条路径不经过 klib 分发器，
  没有 begin 的时机，回显至少让链路可关联。

## 4. Span 与属性

请求 span：名字 `http_request`，`kind = SPAN_KIND_SERVER(2)`，对齐 Rust
`RequestSpan::make_span`（`middleware.rs:277` 的 `info_span!`，字段 method/uri/version/
request_id/status_code/latency/error/module="smg"）与 `ResponseLogger::on_response`
（`middleware.rs:343-345`：`status_code` 为 u16、`latency` 为微秒）。

Lua 侧在同一份 `collect_attrs()` 里额外写了 `path`、`model`、`endpoint`、`stream`、
`worker`、`route_type`、`prompt_tokens`、`completion_tokens`，取值全部来自 `ngx.ctx.lr_*`
—— 也就是 `/_ui/logs` 那行记录用的同一批字段，因此 trace 与日志行、Prometheus 计数不会
对同一个请求给出矛盾答案。Rust 把这些放在 request-log 行里（`router.rs:352`
`ingest.set_route_type(policy.name())`）而不是 span 上；span 上没有的字段在这里加上，
是为了让 trace 单独可诊断（`error` 同理：Rust 只在 status ≥ 500 / 4xx 时 `warn!/error!`
一条事件、不 `record("error")`，Lua 直接把 `ngx.ctx.lr_error_code` 写成 `error` 属性）。
`version` 写死 `HTTP/1.1`（Rust 用 `?request.version()`，`$server_protocol` 在这个
router 上恒为 1.1）。

子 span：`upstream_forward`，`kind = SPAN_KIND_CLIENT(3)`，每次上游尝试一个（带
worker/worker_id/method/path/attempt，结束时补 status_code 或连接错误文本）。Rust 的
HTTP 面**没有**子 span —— 它在父 span 内发 `RequestSentEvent` / `RequestReceivedEvent`
两个 tracing event（`router.rs:379`、`events.rs`），只有 gRPC 面有真的子 span
`grpc_generate`（`request_execution.rs:92`）。collector 不渲染 span event，所以这里用
子 span 表达同一条信息（"请求确实发出去了 / 上游回了什么"），并用
`SMG_TRACE_UPSTREAM_CHILD=0` 提供完全对齐 Rust 形态的开关。父子必须同批导出
（`enqueue` 只入父 span，子 span 挂在父的 `children` 上，编码时展开），否则 collector
会看到孤儿 span。

Resource：`service.name="smg"`（对齐 `otel_trace.rs:126`），
`telemetry.sdk.{name,language,version}` 是 Rust `Resource::default()` 带进来的同形状三元组，
值写 `lua-router` / `lua`，用来区分两条实现。Instrumentation scope 名 `smg`
（对齐 `provider.tracer("smg")`，`otel_trace.rs:137`）。

`OTLP Span.flags`：bit0 取 traceparent 的 sampled 位，bit8（RootedSpan）只在
`parentSpanId` 不存在时置位 —— 即"root"是 span 的属性而不是 trace 的属性，子 span 借用
父 flags 会在 collector 里被误判成第二个根。继承来的上下文不置 bit8。

`status.code`：HTTP ≥ 400 → `STATUS_CODE_ERROR(2)`，其余 `OK(1)`。Rust 不写
`SpanRef::set_status`，失败只体现为 `error!` / `warn!` 事件；collector 的错误视图按
status code 过滤，所以 Lua 侧补上，`error` 属性同时保留（两个信号来源不冲突）。

## 5. 批量导出与退出 flush

每个 worker 一条 `ngx.timer.at` 自续链（`otel.start_timer()`，`init.lua:213
start_trace_exporter()` 在 `worker_init` 里启动），周期 `SMG_TRACE_BATCH_INTERVAL_MS`；
队列达到 `SMG_TRACE_BATCH_SIZE` 时额外用 `ngx.timer.at(0)` 立刻唤醒。唤醒与定时器都受
`flushing` 合并，突发流量不会堆叠导出任务、也不会重复导出同一批。

- 请求路径只做一次 Lua 表 append：`otel.finish()` 不碰 socket，所以 tracing 不可能给
  请求加延迟，也不可能让请求失败。导出全在 timer 上下文里。
- OpenResty 1.31.1.1 **没有 `ngx.on_exit`**（实测确认），所以进程退出 flush 靠两处：
  定时器链发现 `ngx.worker.exiting()` 后补一次 flush，以及（关键的一条）
  `docker stop` 发 SIGQUIT 时所有挂起的定时器会以 `premature=true` 回调 ——
  这条分支现在也做一次有界 flush。`SMG_TRACE_BATCH_INTERVAL_MS=60000` 的部署被
  `docker stop` 时，span 正是从 premature 分支而不是 exiting 分支出去的
  （e2e 的 I 组钉住这点）。硬 SIGKILL 两个分支都到不了，队列丢失，这与 Rust 的
  `BatchSpanProcessor` 相同。
- `flush_spans_async()` / `shutdown_otel()`（`otel_trace.rs:183`、`:200`）在 Lua 侧对应
  `otel.flush()`，e2e 与运维探针都能手工调用。

## 6. 失败与丢弃

一批最多两次尝试（间隔 `ngx.sleep(0.05)`，只在 timer 里），仍失败则整批丢弃并计数，
`fail_streak ≥ 3` 后下一个 tick 拉长 8 倍（上限 30s），死 collector 从每 interval 一次
连接变成约每 4s 一次。编码失败不重试（同样字节重试只会死循环），直接丢弃计数。
每批一条 WARN（`otel export dropped N spans: <原因>`），不带堆栈。

指标（`observability.lua` 注册 HELP，标签形状沿用 `{ "k","v" }` 对）：

- `smg_otel_requests_total{sampled,source}`：拿到上下文的请求数，source = inherited / generated；
  未采样的请求也计数，这样 `SMG_TRACE_SAMPLE_RATIO=0` 时能从 `/metrics` 看出流量仍在被处理。
- `smg_otel_spans_total{result=exported|dropped}`
- `smg_otel_exports_total{result=success|failure}`
- `smg_otel_export_failures_total{stage=connect|send|collector|timeout|encode|...}`（错误串首词）

Rust 侧没有这组自监控指标（只有 `tracing` 的 eprintln），属于 Lua 侧补充：没有它们，
"导出静默失败"与"确实没有流量"在 `/metrics` 上无法区分。

## 7. 测试

- `test/unit/test_otel.lua`（新，**131 checks / 0 fail**，luajit 口径，已并入 `unit` 门）：
  endpoint 解析（含 `host:port`、`grpc://`、端口越界、空值）、`configure` 的取值与夹紧、
  traceparent 解析矩阵（`ff`、全零、长度错、高版本、大小写）、begin/继承/覆盖注入/finish、
  采样（ratio 0 / 0.25 / 1）、OTLP/JSON 编码（resource、scope、kind、flags、纳秒补零、
  parentSpanId、status code）、批量与失败/丢弃计数、关闭时完全不动 header。传输用
  `set_exporter()` 测试缝替换成 spy，不需要 socket。
- `test/integration/e2e_otel.py`（新，**119 checks / 0 fail**，9 组）：文件内 stdlib
  fake OTLP/HTTP collector（收 JSON、按批计数、可切 500 拒收），mock worker 的
  `echo_headers` 证明上游收到的 traceparent。
  - A 默认关闭：响应不吐 traceparent，入站合法值原样透传（钉住既有契约），collector 零收，
    `/metrics` 无 otel 计数。
  - B 自建：响应头 `00-<32hex>-<16hex>-01`，上游 trace-id 相同、span-id 是 router 自己的
    （insert 语义），collector 收到父+子，根 span 无 `parentSpanId`。
  - C 继承：同 trace-id 回显与上传、新 span-id、`parentSpanId` 指向调用方、flags 无 root 位；
    `flags=00` 仍传播且不导出；`00-trace-span-01` 非法 → 自建并正常导出。
  - D span 内容：`service.name=smg`、scope `smg`、kind 2/3、method/uri/path/module/
    status_code/model/endpoint/stream/worker/request_id/route_type、latency≈duration_ms×1000、
    纳秒字符串末六位补零、end≥start、2xx 不标 ERROR、子 span 带 worker/attempt/上游状态、
    `SMG_TRACE_UPSTREAM_CHILD=0` 时不生成子 span。
  - E 批量：`batch_size=2` × 8 请求 → 每批 ≤2、总数恰 8、≥4 批、8 条 span 属 8 条 trace、队列排空。
  - F 采样：ratio=0 五请求全 200 且 flags=00、上游仍收到上下文、零导出、`sampled="false"` 计数；
    ratio=0.25 四十请求全 200，导出集合 ⊆ 客户端见过的集合、且未全导出。
  - G 流式与错误：SSE 出 span 且 `stream=true`；worker 回 4xx 时 span 标 `STATUS_CODE_ERROR`
    并带 `error` 属性，非法 JSON → 400 也出 span，全程无 `lua entry thread aborted`。
  - H 采集器失联：四请求全 200 且带头，`export_failures_total` / `spans_total{dropped}` /
    `exports_total{failure}` 全部增长，WARN 有记录、无 Lua 错误、无 `[error]` 级日志；
    同一 router 上把 collector 起回来即恢复导出（不需要重启）。
  - I 优雅退出：`interval=60s` 时请求 span 仍在队列里，`docker stop` 后 collector 收到该
    trace 的父与子（= Rust `shutdown_otel()` → `force_flush()` 的对应物）。
- `final_gates.sh`：14 门 → **15 门**，新增 `e2e_otel`（注册在 `mesh_http` 之后，超时 1500s），
  `unit` 门的 luajit 列表加 `test_otel`。头部 gate 表与 skip 代价表同步。

一个环境事实值得记进测试里：这台机器上跑着 host 网络的 `llm-watcher` 容器，它会轮询本机
所有 router 的 `/workers`、`/v1/models`、`/server_info`。这些请求在 tracing 打开后各自产生
合法 span，因此 E/F/C 组凡是"数 span"的断言都必须按本次测试自己发出的 trace-id 过滤，
直接数 collector 缓冲区会把无关流量算进来（第一版就是在这里误报 9≠8）。

## 8. 已知限制

1. 传输是 OTLP/HTTP JSON，只连 4318；collector 只开 gRPC 时必须自己加 `http` receiver（§2）。
2. `traceparent` 响应头是 Rust 没有的行为（§3 末）。如果某个下游把它当上游网关的证据，
   需注意它来自 router。
3. 时间戳毫秒精度（末六位补零），`latency` 微秒末三位为零。子 span 的时长靠
   `ngx.update_time()` 刷新缓存时钟才不是恒 0ms，但仍是毫秒粒度。
4. 采样是 head-based 的本地决策，只作用于自建 trace；Rust 交给 SDK sampler（等价于恒采样）。
   `SMG_TRACE_SAMPLE_RATIO` 因此是 Lua 侧独有的旋钮，设成非 1 时 Rust 与 Lua 行为分叉。
5. 不做 `tracestate` 的合并/校验，不做 W3C baggage，不做 OTLP 压缩（`Content-Encoding` 不设）。
6. gRPC 转发面（`grpc_proxy.lua`）未接注入，`otel.inject_grpc` 是留给它的别名；Rust 侧
   `routers/grpc/client.rs:76` 的 `OtelTraceInjector` 那条链在 Lua 侧仍是缺口。
7. 队列是 per-worker Lua 表：worker 数 × `SMG_TRACE_MAX_QUEUE` 才是进程级上限，且
   `docker stop -t` 太短（来不及跑完一次导出）时最后一段 span 仍会丢。
8. 子 span `upstream_forward` 是 Rust 没有的形状（§4），要逐字段对齐 Rust 就设
   `SMG_TRACE_UPSTREAM_CHILD=0`。
