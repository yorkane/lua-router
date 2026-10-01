# wasm 可行性研究（结论：保持不支持，登记 TODO）

日期：2026-09-30。状态：**TODO / Deferred，不实现**（用户指示，见
[todo-deferred.md](todo-deferred.md) §2）。
本文只留研究结论，不代表任何排期，也不意味着「下一步就做」。

研究对象：Rust 对端 `gateway/`（Cargo version 0.3.2）+ `smg-wasm 1.0.0`（`~/.cargo/registry/src/*/smg-wasm-1.0.0`），
以及本仓库 `router.lua` 现有的中间件链形状。

## 1. Rust 侧到底是什么

| 组成 | 位置 | 事实 |
|---|---|---|
| 开关 | `main.rs:486`（`--enable-wasm`）、`config/types.rs:553` | **缺省 false**，不开时 `wasm_middleware` 第一行直接 `next.run(request)` 短路 |
| 运行时 | `smg-wasm/src/runtime.rs` | wasmtime + `component-model` feature，`InstanceAllocationStrategy::Pooling`（每 worker `total_core_instances(20)`、`max_memory_size` / `max_component_instance_size` 由 `max_memory_pages` 推） |
| 超时 | 同上 | `epoch_interruption(true)` + epoch incrementer 线程，`max_execution_time_ms` 缺省 1000 ms，上限 300000 ms |
| 执行模型 | 同上 + `thread_pool_size` | 每个 wasm 调用被投到**独立 OS 线程池**（缺省按 CPU 数封顶）执行，异步收结果 |
| 接口 | `interface/spec.wit` | WIT `package smg:gateway`，`middleware-on-request.on-request(req) -> action` 与 `middleware-on-response.on-response(resp) -> action`；`action = continue \| reject(u16) \| modify(modify-action)` |
| 模块管理 | `src/module_manager.rs` + `gateway/src/wasm/route.rs` | `POST /wasm` 上传模块（走 job queue，`wait_for_job_completion` 100 ms→2 s 指数轮询）、`GET /wasm` 列出 + metrics、`DELETE /wasm/{uuid}` |
| 挂载点 | `server.rs:1313-1322` | wasm 层在 protected routes 上，声明顺序 concurrency → auth → wasm；axum 的 `route_layer` 后声明者在外，所以 **wasm 是最外层**，开着且挂了模块时未鉴权请求也会进 wasm 沙箱（lua-router 若要仿这条链，顺序得自己想清楚） |
| 容量 | `config.rs` | `max_body_size` 缺省 10 MiB、上限 100 MiB |
| 指标 | `observability/metrics.rs` | **没有任何 wasm 家族**（全文件 grep `wasm` = 0 命中）。所以 Lua 不做 wasm 不影响 28/48 覆盖 |

`middleware.rs:1010 wasm_middleware` 的实际行为值得单独记：OnRequest 阶段 `axum::body::to_bytes(request.into_body(), max_body_size)`
**把请求体整包读进内存**，OnResponse 阶段同样 `to_bytes(response.into_body(), ...)` 把响应体整包读进来。
也就是说 Rust 侧只要挂了任一 OnResponse 模块，SSE 流式就不再逐帧透传，而是先缓冲完再回放。
Rust 仓库专门有一条 `benches/wasm_middleware_latency.rs::bench_wasm_middleware_buffering`，
mock 的 next 是「首帧立即 + 500 ms 后第二帧」，测的就是「拿到第一帧要多久」—— 这条 benchmark 的存在
本身就说明缓冲退化是已知问题，不是我的推断。

对 lua-router 的直接影响：本仓库最硬的卖点是 `body_filter` + `ngx.print`/`ngx.flush` 的字节透传，
parity-perf 里「带真实 chunk 节流的流式四个目标完全打平（C=128 RPS 677.9/679.4/679.2/679.8，p50 全 187 ms）」
就是靠这个拿到的。任何在 nginx 侧缓冲整个响应的中间件都会把它打掉，而且 parity-perf 的结论要整段重测。

## 2. 三条实现路线的代价

**路线 A：LuaJIT FFI + 自己实现 canonical ABI。不推荐。**
wasm Component Model 的 host 侧要做的事不是「调一个 wasm 函数」那么简单：canonical ABI 规定
`record request` / `variant action` 这类高级类型如何降级成 `list<u8>`、`option<...>`、`s32` 平坦参数、
`realloc`/`post-return` 回调、lift/lower 时的内存所有权与 UTF-8 校验，`interface types` 还要经 adapter
与 component type-checking（wasmtime 里是 `Component::deserialize` + `Linker` + resource tables）。
用 LuaJIT FFI 从零实现等于把 wasmtime 的核心重新写一遍，且没有任何现成 Lua 生态可复用
（`authz` 镜像里连 wasm 相关的 ngx 模块都没有，`nginx -V` 只有 brotli 这类附加模块）。这条路的风险
不是「慢」而是「做不到正确」，且做出来也没有第二个人能审。

**路线 B：嵌 wasmtime 的 C API + LuaJIT FFI 薄绑定。** 比 A 小一个数量级（不用自己实现 ABI），
但要动 `authz` 基础镜像：wasmtime 是 Rust 静态库、要带 V8/cranelift 与线程池，进 nginx 进程等于
在 worker 里放一个可执行任意用户字节码的 JIT。超时只能靠 epoch 信号打断 worker 事件循环，
与 OpenResty 的单线程 cosocket 模型对撞。另外 wasm 模块崩溃在 nginx worker 内就是 502/worker 重启，
隔离性不如进程外。

**路线 C：复用 `smg-wasm` 作 sidecar，Lua 只做反向代理 + call-out。若将来必须做，走这条。**
具体形状：把 smg-wasm 的 runtime + module manager 包成一个小 HTTP/gRPC 服务（模块上传、列出、删除、
`POST /call {attach_point, request|response}` 返回 action），Lua 侧只在 `body_filter`/`header_filter`
之前把它当一次普通上游调用；`/wasm` 三条路由从 501 改成 sidecar 的反向代理，契约里那 30 条 501 断言换成
代理形状断言。好处是 wasm 崩溃、超时、内存上限全部由 sidecar 承担，Lua 侧维持零依赖；
代价是多一跳网络（同机 loopback 约几十 µs，可接受）与一个额外的部署单元。
注意即使走 C，**OnResponse 阶段的响应体缓冲问题仍然存在**，所以必须先定「只允许 OnRequest 挂点」
还是「允许 OnResponse 但对推理面禁用」。

## 3. 结论

1. **保持不支持**：`/wasm` 三条路由继续固定 501，`--enable-wasm` 在 Rust 侧也是缺省关；
   本仓库的部署面（`conf/`、`docker-entrypoint.sh`）也没有任何 wasm 相关配置项，即没有调用方依赖它。
   不做 wasm 对指标覆盖零影响（Rust 侧 wasm 家族数 = 0）。
2. wasm 与本仓库「只做转发」的定位冲突点在**必须缓冲才能改写 body**，而不是 wasm 本身难部署。
   如果只是要「按 header/路径改写请求」，Lua 正则 + `set_top_field` 那条路已经覆盖，不需要 wasm。
3. 若用户将来明确要做：**走路线 C（复用 smg-wasm 的 sidecar），不要 LuaJIT FFI canonical ABI**；
   并且先约定 OnResponse 只对非流式启用，否则 parity-perf 的流式结论作废重测。

## 4. 未覆盖的部分

Rust 的 `WasmModuleAttachPoint` 除了 `Middleware(OnRequest|OnResponse)` 之外是否有其他挂点
（例如 per-worker / per-router 级别），本轮只读了 `middleware.rs` 用到的两个变体，没有穷举
`smg-wasm/src/module.rs` 的全部枚举值。如果将来立项，第一步应该把 `module.rs` 的 attach point
全集与 `AppContext` 里的模块生命周期读一遍 —— 这不影响「保持不支持」的结论，只影响 sidecar 协议的覆盖面。
