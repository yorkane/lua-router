# gRPC 与 PD disaggregation 可行性（lua-router 缺口补齐）

结论先行：**两条路都可行，且不需要重新编译 OpenResty。** `authz:latest`
（OpenResty 1.31.1.1 / nginx 1.31.1）镜像里的 nginx 二进制自带
`ngx_http_grpc_module`，`grpc_pass` 能真正把 gRPC 调用代理到后端，包括
server-streaming 与 bidi-streaming；PD 的双池选择、bootstrap 注入与 readiness
判据已全部落成纯 Lua 并通过单测。

**当前状态：已接入生产（A 档：已实现并有门禁）。** `SMG_GRPC_PORT>0` 时入口脚本渲染独立 gRPC
listener（§7），注册表按平面开关接受 `connection_mode=grpc|grpcs` 与
`worker_type=prefill|decode`，HTTP 推理面语义不变（池门禁在
`registry.is_available` 内，`router.lua` 未被触碰）。端到端套件
`test/integration/e2e_grpc.py`（真实 nginx + 真实 grpcio）取代了本文早期的原型脚本；
原型产物仍在 `/data/tmp/lr-grpc/`。

### 状态头（2026-09-30 最终门禁刷新）

> 本节只刷新状态与索引，正文 §1–§8 的实测数据保持原样（未重跑）。
>
> - **原生 proto body 注入（2026-09-30，见 §9）**：PD 的 bootstrap 三元组写进 sglang 原生
>   proto 字段，载体开关改成三值（缺省 body）。刷新后的计数：`test_pd` **373 passed / 0 failed**、
>   `e2e_grpc` **90 checks / 0 failed**（`/data/tmp/lr-pdproto/e2e-run.log`）。下面那条 59 是
>   引入 proto 编解码**之前**的记录，保留作时间线。
> - **端到端计数曾涨到 59**：`e2e_grpc: 59 checks, 0 failed`
>   （`/data/tmp/lr-c1/grpc_final.log`）。§5.1 表里那 **52 项是更早一轮的记录**，多出的 7 项
>   来自 Prometheus 家族收尾（注册节 4 条 + PD 节 3 条 `smg_worker_pool_size` 全量相等断言，
>   推导见 [gap-metrics-final.md](gap-metrics-final.md) §3.1/§5）。
> - **`test_pd` 曾为 262 passed / 0 failed**（§5 记的 219 是接线前那一轮；两者都被同一条
>   门禁 `unit` 覆盖，当轮日志 `/data/tmp/lr-gates/gates-20260930-165530.log`；现值 373 见上）。
> - **`e2e_grpc` 不在 `test/final_gates.sh` 的 `GATE_ORDER` 里**（需要宿主机 grpcio 与 mock 端口），
>   需要单独跑。因此「门禁 16/16 全绿」这句话**不足以证明 gRPC/PD 面无回归**，引用时必须带上
>   「另跑 `e2e_grpc` 59/0」。**这条自 2026-09-30 起作废**：`e2e_grpc` 已进入 `GATE_ORDER`
>   （`mesh_http` 之后、`e2e_otel` 之前），宿主机 grpcio 由 `preflight` 硬检查，绿跑即覆盖 gRPC/PD 面。
> - §5.2 那轮 `final_gates.sh` 记的是 **12 门禁**；该脚本已扩到 **18 门禁**
>   （新增 `e2e_discovery_dp` / `e2e_jwt` / `e2e_otel` / `e2e_responses_store`），最终一轮
>   16/16 全绿见 [verification-final.md](verification-final.md) §3.1；
>   再之后纳入 `e2e_grpc` / `e2e_history_redis` 成 18 门，18/18 全绿的权威日志是
>   `/data/tmp/lr-gates/gates-20260930-190905.log`（同一棵 `router.lua`）。
> - **本文的限制清单不是「未完成」，而是 B 档（架构限制）**：根因是
>   `ngx_http_grpc_module` 每个 gRPC 调用开一条上游 HTTP/2 连接、不做 h2 multiplex（§1.4 实测
>   in-flight=100 → 上游 100 条 established），叠加 Lua 不做 proto 编解码。因此在 feature-gap 里
>   归 **B 档 §4.2**，不在 C 档。
>
> **已知限制索引**（逐条推导在 §4 与 §8，档位与后果在
> [feature-gap.md](feature-gap.md) §4.2）：
>
> | # | 限制 | 本文出处 |
> |---|---|---|
> | 1 | 每 gRPC 调用一条上游连接（无 h2 复用）；fd 与握手按 in-flight RPC 计，`keepalive` 只能压到并发数 | §1.4 |
> | 2 | nginx 层重试不可用（`error_page` 丢 body、变量式上游不参与 `grpc_next_upstream`）；换 worker 发生在下一请求 | §4、§8.1 |
> | 3 | ~~PD bootstrap 走 metadata 而非 proto body~~ **2026-09-30 已改为原生 proto body**：bootstrap 三元组写进 `GenerateRequest` field 10（`DisaggregatedParams{1,2,3}`），与 Rust 同字段同编码；**仍未做** prefill/decode 并发双发，decode 落点是路由扩展字段 101/102（中继需后端配合）。推导与实测见 [gap-grpc-proto.md](gap-grpc-proto.md)；`LR_GRPC_PD_METADATA=on` 保留旧 metadata 载体 | §4、§8.2、gap-grpc-proto.md |
> | 4 | 模型只认 `x-smg-model` metadata；点名不中 → UNAVAILABLE 而不换模型 | §8.4 |
> | 5 | 裸 `grpc://` 记录无探活（镜像不会说 `grpc.health.v1`），存活由熔断器学；故 `/readiness` 用 `pd_available` | §4、§8.5 |
> | 6 | 上游形态选变量式 `grpc_pass`：`balancer.set_current_peer()` 不接受域名 | §1.4 |
> | 7 | gRPC listener 只讲 HTTP/2（HTTP/1.1 → 502）；探针、控制面、UI 永远指向主端口 | §4、§7 |
> | 8 | gRPC 面不跑 HTTP 策略栈，只有 round_robin / sticky / power_of_two | §3 第 3 步 |
> | 9 | sticky 一致性环按 worker id，增删 worker 会重排；`/readiness` 的 PD 覆盖靠 exact-location 优先级 | §8.6 |

---

## 1. 镜像能力实证

### 1.1 模块是否编进镜像

`nginx -V` 的 configure 参数里**没有** `--with-http_grpc_module`，容易误读成"没编"。
实际上该模块在 nginx 里是默认开启的，只有显式 `--without-http_grpc_module` 才会关掉，
而 configure 参数里同样没有 `--without` 版本。直接查符号更权威：

```
docker run --rm --entrypoint sh authz:latest -c \
  'strings /usr/local/openresty/nginx/sbin/nginx | grep -iE "ngx_http_grpc|grpc_pass|grpc_read_timeout|grpc_ssl" | sort -u'
"grpc_ssl_certificate_cache" must have the "max" parameter
grpc_pass
grpc_pass_header
grpc_read_timeout
grpc_ssl_certificate
...
ngx_http_grpc_module
no "grpc_ssl_certificate_key" is defined for certificate "%V"
no grpc_ssl_trusted_certificate for grpc_ssl_verify
```

`configure` 参数相关片段（同一镜像）：

```
--with-http_v2_module --with-http_v3_module --with-http_ssl_module
--with-pcre-jit --with-threads --with-stream
```

模块在，接下来只需要证明它可用。

### 1.2 `listen http2` + `grpc_pass` 到 Python gRPC mock

镜像内没有 python3（`which python3` → not found），所以 mock 跑在宿主机侧的
`python:3.12-slim` 容器里（`--network host`，grpcio 1.84.0），OpenResty 容器同样
`--network host`，两者通过 127.0.0.1 相会。mock 不需要 `.proto`：`grpc_pass` 只转
HTTP/2 帧，不关心 schema，因此服务端用恒等序列化器注册
`probe.Echo/{Say,Tell,Chat,Fail,FailMsg,Slow,Large,Big,Trailers}`。

第一个坑，配置层级：

```
[emerg] "grpc_pass" directive is not allowed here in /p/probe.conf:9   # 写在 server{}
```

`grpc_pass` 只能出现在 `location{}`。改到 location 里之后 `-t` 通过，随后
`listen ... http2;` 也给出 deprecation 提示（1.31 起写 `listen` + `http2 on;`）。

### 1.3 端到端结果（客户端只打 nginx，从不直连 mock）

| 用例 | 期望 | 实测 | 判定 |
|---|---|---|---|
| unary `Say` 经 `/passthru/` | 回显 + 200 | `echo:hello\|auth=Bearer tok123\|xcustom=abc123` | PASS |
| 客户端 metadata 透传 | authorization / 自定义头到达后端 | `md=authorization=...;x-custom-md=abc123;x-lr-ctx=worker-7` | PASS |
| 错误码透传 | `NOT_FOUND` 不被改写成 502 | `code=StatusCode.NOT_FOUND details='not found'` | PASS |
| 非 ASCII `grpc-message` | 中文可解析 | `code=INVALID_ARGUMENT details='参数错误 bad input'` | PASS |
| server-streaming 不缓冲 | 分块到达 | chunk +0.002s / +0.302s / +0.602s（mock 每 0.3s 一个） | PASS |
| bidi streaming | 逐条 echo | out +0.002s / +0.402s / +0.803s | PASS |
| 自定义 trailing metadata | 到达客户端 | `x-custom-trailer: yes`（直连与经 nginx 一致） | PASS |
| `grpcs://` + 自签证书 | TLS 可用 | 后端 `transport_security_type=ssl`，握手 X25519MLKEM768 | PASS |
| `grpc_read_timeout 2s` | 掐断 7s 的 Slow | `UNAVAILABLE / Received http2 header with status: 504`，日志 `upstream timed out (110)` | PASS |
| 客户端 `grpc-timeout: 1S` | 后端在 1s 报 deadline | `DEADLINE_EXCEEDED` at +1.002s | PASS |
| 路由自算 deadline（客户端不发头，`x-lr-cap: 2`） | 后端 7s 的 Slow 在 2s 被掐 | `grpc-message: Deadline Exceeded`，real 2.012s | PASS |
| 5MB 上行 | 受 `client_max_body_size` 管 | 默认端口 413；`client_max_body_size 64m` 的 location 通过 | PASS |
| 5MB 下行 | 不被截断 | `srv-saw-...`/`R*5MB` 完整 | PASS |
| 非 gRPC 客户端（HTTP/1.1 GET） | 明确失败 | `502`，日志 `upstream rejected request with error 2` | 预期 |

`grpc-timeout` 只能按行为验证，不能按"后端收到了什么头"验证：gRPC 栈把它当控制头
消费掉，既不进 `invocation_metadata`（直连与经 nginx 都回 `-`，客户端显式发 `5S`
也一样），curl 侧也看不到。所以上表两行 deadline 用例都靠"几秒被掐"判定。同一套
判定下，客户端 1H + 路由 cap=3 → 3.013s 报 `Deadline Exceeded`；客户端 1S + cap=3 →
1.010s；客户端不发 + cap=2 → 2.012s。三条合起来证明路由写入的
`grpc_set_header grpc-timeout $lr_grpc_timeout` 确实覆盖了客户端头并到达后端。

`:path` 语义是个真坑：`grpc_pass` 不像 `proxy_pass` 会重写 URI，它把客户端的
`:path` 原样发给后端，所以带前缀的 location 会让后端收到 `/passthru/probe.Echo/Say`
并回 `UNIMPLEMENTED "Method not found!"`。加 `rewrite ^/passthru(/.*)$ $1 break;`
之后同一条请求就通了。这决定了生产接线要用 `location = /...` 精确匹配或显式 rewrite。

### 1.4 上游连接模型（最重要的一条限制）

`ngx_http_grpc_module` 不做上游 HTTP/2 多路复用。挂 100 个并发在途调用（后端每个
sleep 7s），同时数后端侧 established 连接：

```
in-flight=100  established-to-upstream-19600=100  established-from-client-19500=1
```

下行 1 条连接、上行 100 条。再给 upstream 加 `keepalive 32` 复测：

```
upstream 无 keepalive ：60 并发慢调用，峰值上游 TCP = 92
upstream keepalive 32：60 并发慢调用，峰值上游 TCP = 60
```

keepalive 只把连接数压到"并发数"，不会压到 1。也就是说 gRPC 侧的连接规模按
in-flight RPC 数算，`worker_rlimit_nofile` 要按峰值并发 RPC 直接乘，不能按 upstream
实例数估。

`balancer_by_lua` 的作用点是每请求而不是每连接。用 `x-marker` 把请求和 balancer 日志
对上：25 个请求（同一条客户端连接）→ access log 25 行、`balanced-to` 25 行；
`keepalive 32` 的 upstream 上连发 20 个请求 → 20 次 `KA-BAL`，marker 逐个不同。
所以逐请求选 worker 的语义在 gRPC 路径上成立。

但 `balancer.set_current_peer()` **不接受域名**，实测报
`balancer: no host allowed`；而变量式 `grpc_pass grpc://$peer` 会走 `http{} resolver`
解析域名，两者延迟差别在噪声内：

```
变量式 + 域名  p50=0.0009 p95=0.0012
静态域名       p50=0.0009 p95=0.0011
balancer + IP  p50=0.0008 p95=0.0009
```

因此生产形态选变量式：`grpc_pass $lr_grpc_scheme://$lr_grpc_peer`（两个变量都合法，
`-t` 与运行都通过），域名 worker 天然支持，TLS worker 自动切 `grpcs`。balancer 路径
保留给纯 IP fleet。

### 1.5 吞吐（同一台机器，grpcio 同步客户端）

| 目标 | conc=1 | conc=16 | conc=64 |
|---|---|---|---|
| 直连 mock（基线） | 1747 rps / p50 0.6ms | 3742 / 4.1ms | 3664 / 16.1ms |
| Lua 选择 + `grpc_pass` | 967 rps / p50 1.0ms | 2912 / 5.4ms | 2979 / 19.4ms |
| 纯 nginx `balancer_by_lua`（无 PD 逻辑） | 1141 / 0.9ms | 2989 / 5.3ms | 3073 / 17.9ms |

低并发下多一跳约 0.4ms，高并发掉约 20% rps。gRPC 真实负载是长生成，这个量级不构成
瓶颈；真要压平，成本在每调用一条上游连接上，而那是模块行为，Lua 层无从优化。

### 1.6 不需要改镜像

综合上面：模块在、`http2`/`http3` 在、`grpcs` 在。唯一做不到的事是"上游多路复用"，
而 nginx 本身没有 gRPC 上游连接池这种东西可开 —— 换 `--with-http_grpc_module`
显式重编也不会得到它。所以**不建议**为本功能动 Dockerfile 构建参数。若将来确实要重编，
改动是在 openresty 的 `NGX_ADD_MODULE_OPTS`/configure 里加
`--with-http_v2_module --with-http_grpc_module`，并确认 `--with-threads` 保留 —— 但按
本节证据，这条路不带来收益。

---

## 2. 已实现的纯 Lua 部分

### 2.1 `lualib/resty/luarouter/grpc_proxy.lua`（新）

可单测的部分（不依赖 ngx）：

- `parse_worker(url)` / `format_peer(host, port)`：吃 `grpc://`、`grpcs://`、
  `http(s)://`，剥 `@rank` 后缀与 path/query，IPv6 带方括号，scheme 缺省与端口缺省
  都有明确规则（`grpc://` 无端口时 50051）。
- `parse_grpc_timeout` / `format_grpc_timeout` / `resolve_timeout`：按 gRPC over
  HTTP/2 的"≤8 位数字 + 一个单位字符"编码，全程用整数纳秒比较，避免浮点误判；
  编码时选最粗的**精确**单位（1ms → `1m` 而不是 `1000u`）。`resolve_timeout`
  实现"客户端 deadline 与本地 `request_timeout_secs` 取更紧的那个"。
- `encapsulate` / `decapsulate`：Length-Prefixed-Message（1 字节 flag + 4 字节大端
  长度），给 cosocket 兜底路径和测试用。
- `build_metadata`：上游头集合。伪头与 hop-by-hop 头一律丢弃（`:method`
  `:path` `:scheme` `:authority` `host` `connection` `keep-alive`
  `proxy-*` `transfer-encoding` `upgrade` `content-length`），强制
  `content-type: application/grpc` 与 `te: trailers`，`grpc-timeout` 由路由层重算
  而不是照抄客户端，其余沿用 `router.lua` 的白名单
  （authorization、`x-request-id*`、traceparent、tracestate、x-smg-routing-key），
  因此两条传输面的租户与追踪可见性一致。
- `http_status_for_grpc` / `grpc_status_for_http`：让熔断器能用同一套
  `is_retryable_status` 规则看 gRPC 失败。
- `ip_literal(host)`：区分 IP 字面量与域名。这是 1.4 那条限制的落地 —— 只有字面量
  才能交给 `set_current_peer`。
- `plan(worker, opts)`：纯函数，产出 `{host, port, tls, scheme, peer, timeout,
  worker_id}`。`setup()` 只是它的发布层，写 `ngx.var` 时对每个变量 `pcall`，未声明
  的变量跳过并记 INFO，因此只 `set` 了部分变量的 location 也能用。
- `balancer()`：`balancer_by_lua_block` 里的手，把 plan 落成的 host/port 交给 nginx。

`setup()` 对未声明变量的容错单独验过（`/data/tmp/lr-grpc/guard.conf`，故意只 `set`
`lr_grpc_scheme` 与 `lr_grpc_peer`）：

```
err=nil
plan.peer=10.0.0.9:20000
plan.timeout=30M
peer-var=[10.0.0.9:20000]
[info] ... grpc_proxy.lua:571: setup(): lr-grpc: undeclared variable(s) skipped:
        lr_grpc_host,lr_grpc_port,lr_grpc_timeout,lr_grpc_worker
```

即缺变量不致命、该写的照常写进 `$lr_grpc_peer`，缺的几个在 error_log 里点名。
没有这层 `pcall` 时，第一次真实请求直接 500 在
`resty/core/var.lua:144 ... __newindex`（这是原型第一版的真实报错）。

`te: trailers` 必须是显式的。实测客户端不发 `te` 时，nginx 不会替它补，后端因此不发
trailer，客户端看到 `502`；而 `grpc_set_header TE "trailers"` 之后同一条 curl 请求
正常返回 `grpc-status: 0`。这条决定了 conf 片段必须自带该指令。

### 2.2 `lualib/resty/luarouter/pd.lua`（新）

对齐 Rust 侧 `routers/http/pd_router.rs` + `core/{worker,worker_registry}.rs` +
`policies/registry.rs` + `server.rs::readiness`：

- `pool_of` / `bootstrap_port_of` / `split_dp_rank` / `bootstrap_host_of`：worker 类型
  识别与 bootstrap 地址推导。`bootstrap_host_of` 复刻
  `parse_bootstrap_host_from_url`（先剥 `@rank`，再去 scheme，再去端口，IPv6 去方括号），
  空/nil 回 `localhost`，与 Rust 的 `unwrap_or("localhost")` 一致。
- `pools` / `counts`：按池分桶，`counts` 保留未健康的全量，用来解释"为什么 PD 不可用"。
- `pd_mode` / `select_pair`：`select` 每池各调一次并带上池名，这就是 Rust 的
  prefill-policy / decode-policy 分离；同一 policy 实例调两次也安全，因为
  `policies/utils.lua worker_pool` 让 cache_aware 的树 key 带上 pool，两池状态天然
  不串。错误码区分 `no_healthy_prefill_workers` /
  `no_healthy_decode_workers` / `no_pd_workers` / `pd_mode_disabled`。
- `room_id`（HTTP 路径，[0, 2^63-1]）与 `room_id_i32`（gRPC 路径，
  [0, 2^31-1]）：两个 Rust 实现本来就不一样 —— HTTP 用 `pd_types.rs`
  `generate_room_id`（`random::<u64>() & i64::MAX`），gRPC 用
  `helpers.rs inject_bootstrap_metadata` 的 `random_range(0..i32::MAX)` 填 proto
  int32 字段。`DEFAULT_BOOTSTRAP_PORT = 8998` 同样取自后者
  （`bootstrap_port().unwrap_or(8998)`），也就是 sglang
  `--disaggregation-bootstrap-port` 的默认值。
- `inject_bootstrap` / `inject_dp_rank_for_decode`：单请求写三字段，`batch_size`
  时三字段都变数组且 room 逐项不同（对齐 Rust 循环里逐项 `generate_room_id()`）；
  `disagg_prefill_dp_rank` 只加在 decode 副本上、且只在 prefill URL 带 `@rank` 时。
- `outcome(prefill_status)`：prefill 失败不给 decode 记过。Rust 的理由写在
  `execute_dual_dispatch_internal` 的注释里 —— decode 拿不到 KV 会一直卡在
  WaitingForInput 直到 300s 超时，所以 prefill 一挂就主动掐 decode，这时若再给
  decode 记一次失败，prefill 抖动就会把健康 decode 的熔断器打开。
- `readiness(records, opts)`：PD 判据是"两类池各至少一个健康 worker"；IGW 模式退化为
  "任意健康 worker"。PD 身份取自**注册全量**而非健康快照，对应 Rust 读
  `router_config.mode`（一次健康翻转不该改变集群形态判定）。

---

## 3. 接线记录（原计划 vs 实际落地）

原计划 6 步逐条对照（差异都是实测逼出来的，理由见括号）：

1. ~~resolver 进 `http{}`、变量进主 `server{}`~~ → **独立 listener**。
   `grpc_pass` 只允许出现在 `location{}`，且 gRPC 的 `:path` 是
   `/<pkg>.<svc>/<method>`，与主 server 的 klib.router 路由表不是一个形状；
   监听端口 `http2 on` 之后 HTTP/1.1 会被 502 拒掉，控制面必须留在主端口。
   落点：`conf/grpc-server.conf.template`（由入口脚本 envsubst 渲染，
   `GRPC_EXTRA` 注入 `http{}`），上游形态选**变量式 `grpc_pass
   $lr_grpc_scheme://$lr_grpc_peer`**而非 upstream+balancer（`set_current_peer`
   只吃 IP 字面量，域名 worker 直接不可用；实测两种形态 p50 0.9ms vs 0.8ms，
   变量式还白得 resolver 的域名支持）。原型里"剥前缀的 rewrite"不需要了：
   `location /` 下 `:path` 原样透传（实测 mock 端 `:path=/probe.Echo/Say`）。
2. ~~`router.lua` 推理面按 content-type 分流 + `ngx.exec("@grpc")`~~ →
   **HTTP 面完全不碰**。gRPC 流量只会出现在 gRPC listener 上（HTTP/1.1 客户端
   到不了它，gRPC 客户端不会打主端口的 `/v1/...`），分流交给端口本身，比在
   `router.lua` 里塞 content-type 分支少一个共享文件、少一类误伤面。
   `grpc_proxy.route()` 挂在 gRPC location 的 `access_by_lua_block`。
3. **已接**。选择逻辑 `registry.grpc_records()`（transport=grpc|grpcs、任一池、
   `pd_available`=健康+熔断器）+ `grpc_proxy.pools/pick`。gRPC 面不跑
   cache_aware 那套策略栈（它们的亲和状态 key 在 HTTP url 上，塞 grpc 记录会
   污染前缀树），只实现 round_robin / sticky（routing-key→blake3 一致性环）/
   power_of_two 三种，`SMG_GRPC_POLICY` 选择。模型来自
   `x-smg-model` metadata（字节代理不解析 body，没有别的携带点）。
4. PD 双发 → **metadata 方案**。nginx 单请求一个 `grpc_pass` 上游，双发要
   `ngx.timer` 开副路，收益未证实、复杂度实打实。实际做法：主请求选 prefill
   worker，decode 落点连同 bootstrap 三元组以 metadata 发布
   （`x-lr-bootstrap-host/port/room`、`x-lr-decode-peer`、`x-lr-prefill-dp-rank`），
   等后端从 proto 字段改读 header，或将来补 proto 编解码后收回
   （`LR_GRPC_PD_METADATA=off` 可整体关闭注入）。room 用 `room_id_i32` 重掷
   （对齐 helpers.rs 的 `random_range(0..i32::MAX)`，pd.select_pair 原 range 是
   2^63，塞不进 int32）。
5. `/readiness` → **exact-location 覆盖**。`router.lua` 不在所有权内，改用
   `conf/grpc-readiness.conf` 的 `location = /readiness`（精确匹配优先于
   klib.router 的 catch-all）调 `registry.readiness({})`→`pd.readiness`，判据
   用 `pd_available`（健康+熔断器）。池的 PD 身份取自注册全量而非健康快照，
   所以"完全没注册 PD"的舰队响应与 router.lua 原版逐字节一致；HEAD 同状态
   零 body（`test_head_routes.py` 的形状要求）。`/workers` 的
   `worker_type/grpc_port/grpc_tls/bootstrap_port` 已在 `registry.info()` 落地。
6. 观测 → **已接**。`smg_worker_selection_total{worker_type,pool,model,policy}`
   加 `connection_mode=grpc` 标签在 `route()` 里记；每调用结束在
   `log_by_lua` 里 `grpc_proxy.on_log()`：归还 load、按
   `grpc-status`/`$upstream_status` 给熔断器记账（`outcome()`：0=成功，
   1/2/3/5/6/7/9/10/11/12/16 归客户端不记过，其余与传输失败记过），PD 的
   decode 半边按 pd.outcome 规则**不**记账。gRPC listener 的 access_log 用独立
   `log_format lr_grpc`，每行带 worker/pool/peer/grpc_status，是"动态选择真的
   动了"的直接证据。

入口脚本侧：`SMG_GRPC_PORT`（默认 0=整平面缺席，渲染、include、注册表枚举
三处同时不生效）、`SMG_GRPC_HOST`、`SMG_GRPC_POLICY`、
`SMG_GRPC_READ_TIMEOUT_SECS`；端口撞主端口/metrics 或非法值 fail-fast 退出。
一个必须记住的坑：`conf/nginx.conf.template` 里要 `env SMG_GRPC;`——nginx
默认把 worker 的环境清掉，少了这行注册表永远回答"plane off"，所有 grpc 注册
400（实测排查耗时代价最大的一条）。

## 4. 与 Rust 的差异（有意保留）

| 维度 | Rust | lua-router 本阶段 | 影响 |
|---|---|---|---|
| gRPC 协议 | tonic 强类型，理解完整的 `GenerateRequest`/`ChatRequest` | 纯字节代理 + PD 所需的最小 wire 编解码子集（未知字段逐字节原文保留） | 能写 bootstrap 三元组，但读不懂也重建不了整条消息：不认识的结构只能原样搬运，改写点只有 `GenerateRequest` field 10 一处（§9） |
| PD bootstrap 载体 | gRPC 走 proto `DisaggregatedParams{bootstrap_host, bootstrap_port:int32, bootstrap_room:int32}`；HTTP 走 JSON 三字段 | **与 Rust 同字段**：gRPC 走手写 wire 编解码写进 proto body field 10（默认）；旧 metadata 载体保留为 `LR_GRPC_PD_METADATA=on` | decode 落点无原生字段，用扩展 101/102（对 schema 是未知字段）；见 gap-grpc-proto.md §2 |
| room 范围 | HTTP 2^63-1 / gRPC 2^31-1 | 两个函数分别为 `room_id`、`room_id_i32` | 无 |
| bootstrap 端口缺省 | HTTP 注 JSON null；gRPC 用 8998 | `bootstrap_port` 可为 nil；`DEFAULT_BOOTSTRAP_PORT=8998` 供 gRPC 路径使用 | 无 |
| PD 模式来源 | `--pd-disaggregation` 显式 CLI flag | 按**模型作用域内**的池推断（`grpc_proxy.pd_preferred`）：点名了由 PD worker 精确服务的模型走 PD，否则有 regular 池就走 regular | 混合舰队可用；代价是"没点名且恰好只有半套 PD 池"时按 PD 判、直接 UNAVAILABLE，而不是回落 |
| 上游连接 | tonic HTTP/2 多路复用，每 worker 一条连接 | 每 gRPC 调用一条上游连接（实测：并发 N 即 N 条连接，无复用） | 高并发时 fd 与握手开销按 in-flight RPC 计 |
| 失败重试 | tonic 层可配重试 | **nginx 层重试不可用**：`error_page 502 = @retry` 实测第二次请求丢 body（后端报 UNIMPLEMENTED "requires exactly one request message"），且变量式上游不参与 `grpc_next_upstream`。换 worker 由**下一请求**的 Lua 选择决定，配合熔断器收敛 | 单条 in-flight 调用不会自动换 worker；客户端重试即落到存活 worker（e2e 实测 attempts 收敛） |
| DP rank | `dp_rank()` 来自 worker 元数据 | 从 URL `@rank` 解析（与 Rust 解析 bootstrap host 时剥掉的同一后缀） | 语义等价 |
| 请求体编辑 | serde `Value` 结构化改写 | 顶层 JSON 原文编辑（沿用 `router.lua` 的 `set_top_field` 思路） | 本阶段 PD 只注顶层三字段，够用 |
| gRPC worker 探活 | tonic 原生说 `grpc.health.v1` | 不会说这个 proto：`grpc://` 裸 url 注册为**无探活**记录（`disable_health_check`），存活由熔断器从真实调用学习 | 无流量的裸 grpc worker 永远"健康"，这是 readiness 判据用 `pd_available`（含熔断器）而不是 `is_healthy` 的原因；PD worker 必须带 http(s) url 注册（否则 400），保证池的可探性 |
| 直连测试口径 | — | gRPC listener 只讲 HTTP/2：HTTP/1.1 打它得到 502 | 就绪探针、控制面、UI 永远指向主端口 |

## 5. 测试数字

单测 `test/unit/test_pd.lua`（纯 Lua，`luajit` 直跑；接线后覆盖注册表门禁、
池门禁、metadata 发布、`outcome` 分类、`pd_preferred` 的模型作用域推断、
`scope_named_model` 的"点名不中=空集"语义、记录级 `grpc_port` 优先于 labels）：

```
pd/grpc_proxy: 262 passed, 0 failed
```

覆盖双池选择与故障切换、bootstrap 单请求/批量注入、DP rank 注入、readiness 三态、
outcome 归属、grpc-timeout 解析/编码/收紧、帧编解码、头清理、IP/域名判别、
gRPC↔HTTP 状态映射。回归无影响：

```
tree: 67 passed, 0 failed
policies: 118 passed, 0 failed
hash: 795 passed, 0 failed
```

配置门禁（全部 real openresty `-t`）：

```
test/conf/nginx-lua-router.conf   syntax is ok / test is successful
conf/lua-router.conf              syntax is ok / test is successful
conf/grpc-prototype.conf          syntax is ok / test is successful
入口渲染 + openresty -t（容器内，-e SMG_GRPC_PORT=50051）  grpc: on 0.0.0.0:50051 -> successful
入口渲染 + openresty -t（默认）                            grpc: off           -> successful
SMG_GRPC_PORT=abc -> "error: SMG_GRPC_PORT must be numeric"（fail-fast，不 crash-loop）
```

契约套件（`test_lua_router.sh`，gRPC 平面 off 时 400 消息逐字保留）：
`All ... contract checks passed`；`final_gates.sh` 全量见 §5.2。

### 5.1 端到端 `test/integration/e2e_grpc.py`（真实 nginx 容器 + 真实 grpcio 客户端）

**52 项检查全过（0 failed）**，mock 用 `test/integration/fixtures/
mock_grpc_server.py`（仓库化，无需 .proto；`|self=` 回显让"哪个 worker 服务了
这一刀"在客户端可见）+ `fixtures/tls/server.{crt,key}`。分组与关键数字：

| 组 | 内容 | 结果 |
|---|---|---|
| 注册门禁 | bare grpc://、tagged grpc+port、prefill/decode、grpcs 收 202；裸 grpc 的 PD、非法枚举、无端口 grpc、decode 带 bootstrap_port 收 400 | 11/11 |
| 注册表形状 | connection_mode 计数（4 grpc+1 grpcs+1 http）、worker_type 计数（1 prefill/1 decode/4 regular）、全部变 selectable | 3/3 |
| 核心代理 | unary 回显、metadata 透传、`x-lr-worker` 落点戳 | 4/4 |
| streaming | server-streaming 3 块、paced≥0.55s（实测 3×0.3s 节奏透传，非缓冲） | 2/2 |
| 状态/ trailer | NOT_FOUND 不被改写成 502、自定义 trailing metadata 到达 | 2/2 |
| deadline | 7s 调用活过 1800s cap | 1/1 |
| 负载 | round_robin 8 刀 A/B 各≥3；模型点名 rr→A/B、tls→TLS、pd→PF | 4/4 |
| TLS | grpcs worker 同一 listener 服务（自签、verify off） | 1/1 |
| 健康切换 | 杀掉带 http 面的 worker → 健康翻 false → 6 刀收敛到存活 worker | 2/2 |
| 熔断器 | 裸 grpc（无探活）worker 杀掉 gRPC 口：端口确证失联、`is_healthy` 保持 true 而熔断器 closed→open、池耗尽回 UNAVAILABLE(`no_healthy_grpc_workers`) 而非挂死、非 refused-socket | 4/4 |
| PD | 双池注册、prefill 服务、bootstrap host/port(8998)/room(int32)/decode-peer metadata 全部落后端；readiness 200→杀 decode→503 且 503 点名缺失池；PD 坏不影响 plain grpc 池 | 11/11 |
| HTTP 面无回归 | chat 由 http worker 服务；grpc-only 模型也绝不落到 grpc 记录（池门禁） | 2/2 |
| 二号 router | sticky 同 key 稳定同 worker、无 key 回落 spread、2s cap 在 ~2s 掐断 7s 调用（deadline 是路由器的不是客户端的）、无 lua 错误 | 5/5 |

### 5.2 回归

`test/final_gates.sh` 全量（2026-09-30，lua-router@当前树，镜像由 Dockerfile
现场构建）：

```
build PASS (1s)  conf PASS (1s)  unit PASS (5s)  contract PASS (89s)
probes PASS (8s) e2e_stateful PASS (39s) e2e_policies PASS (18s)
e2e_ui_bridge PASS (6s) e2e_errors PASS (6s) e2e_effort PASS (1s)
head_routes PASS (3s) mesh_http PASS (16s)
final gates: 12 passed, 0 failed, 0 skipped
（gates-20260930-101028.log；改动前的对照运行 gates-20260930-100538.log 同样 12/12）
```

`test_pd`（262 项）在 unit gate 列表内；contract 套件在 gRPC 平面关闭口径下
跑，证明四类新枚举的 400 文案与旧版逐字一致。`e2e_grpc.py` 不在
final_gates.sh 列表里（本任务无权改该文件），单独跑 52/52。

原型时期（接线前）的端到端记录，保留作证据，规范口径见 §5.1：

（真实 nginx，`access_by_lua` 里跑 `pd.select_pair` + `grpc_proxy.setup`）：

```
127.0.0.1 POST /probe.Echo/Say  "worker=[p1] pool=[prefill]" "peer=[127.0.0.1:19600]" status=200 rt=0.001
127.0.0.1 POST /probe.Echo/Say  "worker=[p2] pool=[prefill]" "peer=[127.0.0.1:19602]" status=200 rt=0.002
```

即：PD 双池选择在请求路径上生效，换 worker 就换上游地址，后端收到的 metadata 里
`x-lr-worker=p2`、`x-lr-decode=d1` 同时可见。p2 的 mock 容器停掉之后：

```
connect() failed (111: Connection refused) while connecting to upstream,
    upstream: "grpc://127.0.0.1:19602"
... "worker=[p2]" "peer=[127.0.0.1:19602]" status=502 rt=0.001
... "worker=[p1]" "peer=[127.0.0.1:19600]" status=200 rt=0.001
```

被选中的 worker 挂掉时 nginx 明确报 502 且不重试别的地址 —— 与 HTTP 面一样，
重试/换池必须由 Lua 层做（`registry.charge_cb` + 既有 retry 循环），nginx 侧只有
`grpc_next_upstream`，而它在变量式上游下不参与池选择。

吞吐：Lua 选择 + grpc_pass 相对直连 mock 的代价，conc=1 约 +0.4ms p50，conc=64 约
-19% rps（2979 vs 3664）。

## 6. 复现

```bash
# mock（宿主机 python 有 grpcio；镜像内没有）
docker run -d --name lr-grpc-mock --network host -v /data/tmp/lr-grpc:/p:ro -w /p \
  -e LR_TLS_CERT=/p/tls/server.crt -e LR_TLS_KEY=/p/tls/server.key \
  python:3.12-slim sh -c 'pip install -i https://mirrors.aliyun.com/pypi/simple/ grpcio==1.84.0 \
    && python3 mock_grpc_server.py --port 19600 --tls-port 19601'
docker run -d --name lr-grpc-mock2 --network host -v /data/tmp/lr-grpc:/p:ro -w /p \
  python:3.12-slim sh -c 'pip install -i https://mirrors.aliyun.com/pypi/simple/ grpcio==1.84.0 \
    && python3 mock_grpc_server.py --port 19602'

# 原型
docker run -d --name lr-grpc-proto --network host -v $PWD:/repo:ro \
  --entrypoint /usr/local/openresty/bin/openresty authz:latest \
  -p /usr/local/openresty/nginx -c /repo/conf/grpc-prototype.conf -g 'daemon off;'

cd /data/tmp/lr-grpc && python3 mock_client.py --target 127.0.0.1:19500 --case all

# 单测
docker run --rm -v $PWD/lua-router:/r:ro -w /r --entrypoint \
  /usr/local/openresty/luajit/bin/luajit authz:latest test/unit/test_pd.lua
```

接线后的**规范复现**是仓库化套件（mock/TLS 证书都在
`test/integration/fixtures/`，宿主机只需 grpcio）：

```bash
# 镜像（build context 是仓库根）
cd .. && docker build -t lua-router:grpc -f Dockerfile . && cd lua-router
LR_IMAGE=lua-router:grpc python3 test/integration/e2e_grpc.py   # ~7-9 min, 52 checks

# 手工起一个带 gRPC 面的 router
docker run -d --name lr --network host -e SMG_GRPC_PORT=50051 lua-router:grpc
curl -s localhost:30000/workers -d '{"url":"grpc://127.0.0.1:19600","model_id":"m"}'
```

---

## 7. 接入形态（生产开关与语义）

| 开关 | 默认 | 作用 |
|---|---|---|
| `SMG_GRPC_PORT` | `0` | >0 渲染独立 gRPC listener 并**同时**打开注册表枚举（`SMG_GRPC=1` 导出给 worker）；0 时平面完全缺席 |
| `SMG_GRPC_HOST` | 同 `SMG_LISTEN_HOST` | listener 绑定地址 |
| `SMG_GRPC_POLICY` | `round_robin` | gRPC 面选择策略：`round_robin`/`sticky`/`power_of_two`（非法值启动即退） |
| `SMG_GRPC_READ_TIMEOUT_SECS` | `1800` | nginx `grpc_read_timeout`；真实上限仍是 Lua 按 `request_timeout_secs` 重算的 `grpc-timeout` |
| `LR_GRPC_PD_METADATA` | 缺省 = `body` | PD bootstrap/decode 三元组的**载体**：缺省写进 sglang 原生 proto 字段（`GenerateRequest` field 10，stock 引擎直接可读）；`on` 退回旧的 `x-lr-*` metadata 注入（body 一字节不改）；`off` 什么都不注入。body 无法安全改写时自动回退 metadata（§9.4） |

注册语义（仅平面开启）：

- `connection_mode` 接受 `"grpc"`/`"grpcs"` 字符串、serde tag
  `{"type":"grpc","port":N}`、以及 `grpc(s)://` url scheme；记录里 url 永远存
  http(s) 形式（健康探针/控制面/UI 都拼它），gRPC 落点在 `grpc_port`/`grpc_tls`。
- grpc 模式必须给出端口（tag 的 `port` / `grpc(s)://` url 的端口 /
  `labels.grpc_port`），否则 400。**http url 的端口不会被当成 gRPC 端口。**
- `grpc://` 裸 url 只能配 `worker_type=regular`（自动 `disable_health_check`，
  存活由熔断器学）；prefill/decode 必须带可探的 http(s) url，否则 400。
- `worker_type` 值域严格：未知值 400（Rust 会静默塌成 Regular，这里不学它）。
- 平面关闭时上述四类请求的 400 报错文本与旧版逐字一致（契约套件钉着它）。

HTTP 面保护：`registry.is_available()`（router.lua 每个候选都会调）多了一道池
门禁 —— 只有 http+regular 可选，gRPC 记录对推理面完全隐形；gRPC/PD 面用独立的
`pd_available()`（健康+熔断器）。`/readiness` 只有在存在任一 PD worker 时才要求
两池齐活，完全无 PD 的舰队与旧行为逐字节一致。

## 8. 遗留限制（接线后仍成立）

1. **不做 nginx 层重试。** 单条 in-flight 调用失败不会自动换 worker；换 worker
   发生在下一请求（Lua 选择 + 熔断器收敛）。`error_page`/`grpc_next_upstream`
   两条 nginx 路都实测不可用（第二条丢 body / 变量式上游不参与）。
2. **PD bootstrap 走 sglang 原生 proto body（2026-09-30 起）。** bootstrap 三元组写进
   `GenerateRequest.disaggregated_params`（field 10）内的 `DisaggregatedParams`
   `{bootstrap_host=1 string, bootstrap_port=2 int32, bootstrap_room=3 int32}`，stock sglang
   直接可读；编解码与字段号推导见
   [gap-grpc-proto.md](gap-grpc-proto.md)。
   仍成立的两条：**(a)** gRPC PD 未做 prefill/decode 并发双发（nginx 每请求只有一个
   `grpc_pass` 上游），调用只发给 prefill，decode 落点写在同一 message 的**扩展字段**
   101/102/103（vendored schema 没有原生字段承载它），中继仍需后端配合；
   **(b)** body 无法安全改写时（非 `/Generate` 方法、流式、压缩、超 8 MiB、解析失败）自动
   回退 `x-lr-*` metadata，`LR_GRPC_PD_METADATA=on` 强制 metadata、`off` 什么都不注入。
3. **每 gRPC 调用一条上游连接**（无 h2 复用），fd 与握手按 in-flight RPC 计。
4. **模型只认 `x-smg-model` metadata**；点名不中→UNAVAILABLE 而不是悄悄换模型；
   未点名时按"有 regular 池用 regular"推断 PD。
5. **裸 `grpc://` 记录无探活**，空闲 fleet 的死亡只能靠一次真实失败暴露；
   生产建议 sglang 约定（http url + `labels.grpc_port`）保留探针。
6. sticky 的一致性环按 worker id（增删 worker 会重排）；`/readiness` 的 PD 覆盖
   依赖 exact-location 优先级（若将来 router.lua 自己实现 PD readiness，删掉
   `conf/grpc-readiness.conf` 的 include 即可让位）。
7. 探针产物在 `/data/tmp/lr-grpc/`（含 trailers-only 的 `content-length: 0`
   实证转录），是历史证据而非依赖；仓库侧复现只用 §6 的规范套件。

## 9. 原生 proto body 注入（2026-09-30 补齐）

结论：PD 的 bootstrap 三元组现在写进 sglang 的**原生 proto 字段**，与 Rust 写的是同一批字节；
metadata 载体降级为可选模式。完整推导、实测与实现在
[gap-grpc-proto.md](gap-grpc-proto.md)，本节只记结论与依据。

### 9.1 字段号证据（vendored schema，非推测）

Rust 侧唯一的 gRPC PD 写入点是 `inject_bootstrap_metadata`，它给结构体赋值后交给 tonic 序列化：

```rust
// gateway/src/routers/grpc/common/stages/helpers.rs:15-35
let bootstrap_port = prefill_worker.bootstrap_port().unwrap_or(8998);   // :20
let room_id = rand::rng().random_range(0..i32::MAX);                    // :23
let disagg_params = DisaggregatedParams {                               // :26-30
    bootstrap_host: hostname.to_string(),
    bootstrap_port: bootstrap_port as i32,
    bootstrap_room: room_id,
};
sglang_request.disaggregated_params = Some(disagg_params);              // :35
```

调用点三处（regular/chat、regular/generate、harmony）：
`gateway/src/routers/grpc/regular/stages/generate/request_building.rs:102`、
`gateway/src/routers/grpc/regular/stages/chat/request_building.rs:107`、
`gateway/src/routers/grpc/harmony/stages/request_building.rs:188`。

schema 由 `gateway/Cargo.toml:113` 的 `smg-grpc-client = "=1.0.0"` 钉死，原文在
`~/.cargo/registry/src/index.crates.io-*/smg-grpc-client-1.0.0/proto/sglang_scheduler.proto`：

| message | 字段 | 号 | proto 类型 | wire type | proto 行号 |
|---|---|---|---|---|---|
| `GenerateRequest` | `disaggregated_params` | **10** | `DisaggregatedParams` | 2 (len) | `sglang_scheduler.proto:113` |
| `DisaggregatedParams` | `bootstrap_host` | 1 | string | 2 | `:84` |
| `DisaggregatedParams` | `bootstrap_port` | 2 | int32 | 0 (varint) | `:85` |
| `DisaggregatedParams` | `bootstrap_room` | 3 | int32 | 0 | `:86` |

**本实现没有写 `data_parallel_rank`（`GenerateRequest` field 16，`:129`）**：Rust 的 gRPC 路径不写它
（`grep -rn data_parallel_rank src/routers/grpc/` = 0 命中，只有 HTTP 路径的
`src/routers/http/router.rs:575` 与 `pd_router.rs:239-320` 写 JSON 同名字段）。DP rank 在本实现里
以扩展字段 103 携带，语义与 metadata 模式的 `x-lr-prefill-dp-rank` 一致。

`vllm_engine.proto` 无 `DisaggregatedParams`（vLLM 不支持 PD），这也是 Rust
`as_sglang_mut()` 允许直接 panic 的同一前提。

### 9.2 为什么不能「append 即覆盖」（任务书假设的修正）

任务书的前提是「protobuf 标量解析后写覆盖先写，所以只需在顶层追加 tag」。这条对**重复字段**成立，
对**单例 message 字段不成立**，而 field 10 正是单例 message。用 python protobuf 实测：

| 输入 | 解码结果 |
|---|---|
| field 3 出现两次（`111` 然后 `222`） | `bootstrap_room=222` —— 标量确实 last-wins |
| field 10 出现两次，第二条只有 `bootstrap_host="NEW"`，第一条是 `{host:"STALE", port:7777, room:8888}` | `host=NEW, port=7777, room=8888` —— **单例 message 字段是 merge，不是覆盖** |

即：无脑追加第二条 field 10 会让上一次注入的 `bootstrap_port` / `bootstrap_room` **泄漏进本次
请求**（proto3 解析器对单例 message 字段按字段号做合并）。因此实现做的是「解析 → 按字段号原位替换
→ 重编码」，输出永远只有一条 field 10，且不含任何旧值。`grpc_proxy.lua` 的 `replace_field` 承担这件事，
单测里 `输入已有两条 field 10：折叠成一条，旧值不泄漏` 一条钉住该行为（含 `旧 port 不残留` 的断言）。
未知字段（外层与内层都算）逐字节保留原文，所以合并只发生在已知字段号上。

`room` 的 int32 边界（与 python protobuf 逐字节对比，均在单测中）：2^27-1→`ffffff3f`、
2^27→`80808040`、2^28-1→`ffffff7f`、2^28→`8080808001`、i32::MAX→`ffffffff07`。
负数走 prost 的 10 字节符号扩展（`-1`→`ffffffffffffffffff01`），**不需要 zigzag**：
vendored 两个 proto 里 `sint32`/`sint64` 命中数为 0，int32 在 wire 上永远是 varint。

### 9.3 开关语义（默认值的理由）

| `LR_GRPC_PD_METADATA` | 载体 | 说明 |
|---|---|---|
| 未设置（缺省） | `body` | 原生 proto 字段 |
| `on`/`1`/`true`/`yes`/`metadata` | `metadata` | 引入编解码之前的行为，逐字节不变 |
| `off`/`0`/`false`/`no`/`none` | 无 | 纯转发，两者都不发 |
| 无法识别的值 | `body` | 回到缺省，而不是静默不注入 |

缺省取 `body` 的理由：Rust 网关就是写 body，真实 sglang 引擎只读 proto 字段 —— metadata 模式打不到
stock 引擎，把它留作缺省等于把「上线即不可用」设为默认状态。旧载体没有删除，因为已有部署可能被教成了
读 `x-lr-*`，而回退是免费的：`on` 一个环境变量即可，且 body 改写失败时本来就自动落到 metadata。

### 9.4 回退条件

以下任一情况 body 保持原字节、改用 metadata 载体，并在 error_log 记
`lr-grpc: PD body injection unavailable (<reason>)`：`:path` 最后一段不是 `Generate`；
body 读不出来；不是**单条未压缩**消息（流式多帧、压缩帧、帧截断）；message 解析失败
（含 group，wire 3/4 直接报错而不是猜）；body 在临时文件且超过 `PD_MAX_BODY_BYTES`（8 MiB）；
整体 `pcall` 出错。回退被记日志而不是静默，因为 bootstrap 缺失的后果是请求在 sglang 的
disaggregation 超时里卡满 300 s。

### 9.5 限制

1. decode 落点没有原生字段，走扩展 101/102/103：stock 引擎会当未知字段跳过，**中继仍需后端配合**。
2. 仍无 prefill/decode 并发双发（nginx 每请求一个 `grpc_pass` 上游），调用只发给 prefill。
3. 只理解 PD 所需的 wire 子集：路由不能读懂整条消息，也不会去改写别的字段。
4. 多帧（客户端流式）请求整体不改写 —— 这也保证首帧之后的帧永远不可能被动到。

### 9.6 数字

- 单测 `test/unit/test_pd.lua`：`pd/grpc_proxy: 373 passed, 0 failed`（262 → 344 是引入 wire 编解码那轮，
  344 → 373 是本轮补的边界与语义用例：大 varint 逐字节对照、重复 field 10 不泄漏旧值、
  未知内层字段保留、多帧 body 整体拒绝）。
- 端到端 `test/integration/e2e_grpc.py`：`e2e_grpc: 90 checks, 0 failed`
  （`/data/tmp/lr-pdproto/e2e-run.log`，2026-09-30 22:42 复跑，镜像 `lua-router:integration`
  现场重建）。mock 后端用 `google.protobuf` 动态描述符 + 手写 wire 扫描器两个独立解码器报告
  字段，请求体由 router 之外的代码构造，避免自我印证。其中 `[pd-body]` 组覆盖：三元组落在
  field 1/2/3、扩展字段 101/102/103 对 schema 未知、客户端其余字段（含两个未知字段）原文保留、
  **两条 field 10 折叠成一条且旧 port/room 不残留**（§9.2 的 merge 陷阱）、>4 MB 溢出到临时文件的
  body 仍被改写、超 8 MiB 上限回退 metadata、`on` 模式 body 一字节不改、`off` 两者都不发。
