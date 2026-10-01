# lua-router vs Rust llm-router 契约对拍（golden diff）

日期 2026-09-29。原始数据 `/data/tmp/parity/contract/`（33 组 × 两侧 headers/body 原始件、
comparison.json、analyze 输出、机制取证、回归日志、router.lua 修复 diff）。
本报告行数为 **33**（另 2 组机制探针不计入表内）。

> **状态**：结论仍有效，但 **§1 那批 router.lua 修复至今未 commit**（parity-perf §1 同样记录），
> 发布镜像 `lua-router:latest` 不含它们。
> **日期**：对拍 2026-09-29，状态复核 2026-09-30（UTC）。
> **证据强度**：B（两侧实例逐字段对比 + <dev-box>:8800 生产仲裁；原始件在 `/data/tmp/parity/contract/`）。
>
> 计数更新：文中「回归 266/266 全绿 ×4 轮」是修复当时的基线，**现为 322 passed / 0 failed / 3 notes**
> （M1–M6 又加 56 条断言）。
> §4「Lua 侧未修注记」4 条（400 措辞、`/health_generate` 501、`/workers` 值型、
> `/server_info`+`/model_info` 超集）全部仍未修，已归入
> 历史 feature-gap 的「部分实现」档（文档已删）。
> 口径盲区：本报告只打「两边都存在」的 33 组接口，**没有覆盖 Lua 根本没挂路由的 15 条端点**
> （parse / wasm / tokenizers/{id} / conversations items），那部分缺口大多随平面删除（scope-trim）。
>
> 勘误（2026-10-01 文档精简轮）：#21 `/health_generate` 的 501 口径已被后续轮次取代，
> 现状是 200/503 纯文本双文案（以 README 端点表为准）。

## 0. 环境与口径

- LUA_BASE=http://127.0.0.1:46089（authz:latest + 本仓库 /repo:ro 直读），
  RUST_BASE=http://127.0.0.1:8920（ghcr.io/yorkane/llm-router:latest，
  `--enable-igw --policy round_robin`），同一 8 mock worker 池（alpha..theta）。
- 环境修正两处（影响公平性，先行处理）：
  1. mock 池原跑的是精简版 mock_worker_pool.py（无 /identity、无 embeddings/rerank/responses）。
     换回仓库 `test/mock_llm_worker.py`，并按任务书授权给它补了 `echo_headers`
     （chat/completions 响应回显收到的请求头，用于头转发/剔除取证）。
  2. lua-router 容器没有任何 SMG_* 环境变量（enable_igw=false），而 Rust 侧开了 IGW。
     按原容器的 binds/cmd 重建并加 `SMG_ENABLE_IGW=1`（另按 AGENTS.md 补
     `--restart unless-stopped`），两侧 IGW 对齐后重注册 8 worker。
- diff 忽略易变字段：id/created/x-request-id 值/date/server/content-length 值/耗时头，
  以及 Rust 恒带的 CORS 三件套（vary / access-control-allow-origin / access-control-expose-headers）。
- 仲裁采样：<dev-box>:8800 生产实例（只 GET /health /v1/models /server_info /model_info
  /health_generate / HEAD /health），结论见各行证据与 mechanism-notes.txt。
- 已知偏差按任务书不重复展开：404 body 形状、405 method gate、/v1/loads 形状。
  表内出现时只标「已知」。

## 1. 新发现并已修复（Lua 侧，router.lua 最小 diff，回归 266/266 全绿 ×4 轮 —— 现基线 322）

修复 diff：`/data/tmp/parity/contract/router.lua.parity-fixes.diff`（约 196 行，含注释）。

| # | 偏差（修复前） | 修复 | 证据 |
|---|---|---|---|
| F1 | IGW 开 + 请求缺 `model` → Lua 200（落到任意 worker） | 缺 model 时按 Rust 的 serde default 走 `"unknown"` 查表 → 503 no_available_workers | Rust :8920 同请求 503；修复后双方逐字段一致（04c MATCH） |
| F2 | `model:null`/数字 → Lua 200 转发 null | 非字符串 model → 400 invalid_json | Rust（含 <dev-box>:8800 生产）400 json_parse_error；修复后同为 400 |
| F3 | forward() 内 503/502 用默认 text/plain content-type；Lua 全部 JSON 响应带 `charset=UTF-8` 后缀（Rust/axum 只发 `application/json`） | 503/502 显式 application/json；5 处 charset 后缀统一去掉 | 04a/04c/04f MATCH；05_readiness MATCH |
| F4 | 自发响应（/health /v1/models /readiness /错误体…）缺 `x-request-id`（Rust middleware 全响应恒有） | handle() 入口统一 `ngx.header["X-Request-Id"]=request_id()`，代理路径沿用原覆盖 | 05_health/05_liveness/05_readiness MATCH；01/04x 的 x-request-id 差异消除 |
| F5 | 自发缓冲响应 nginx 默认 `Transfer-Encoding: chunked`（Rust 恒 `content-length`）；代理回包同样 chunked | send_error/text_response/route_inference 打印前显式 Content-Length；表返回 handler 经 exact_json() 自编码（readiness/models/server_info/model_info/workers/create_worker/loads/flush_cache） | 03b/03d/embeddings、05 组由 chunked-DIFF 转 MATCH；流式路径不受影响（02 仍 chunked 且无 content-length，符合 suite 断言） |
| F6 | `x-smg-target-worker` 在转发白名单里（Rust header_utils.rs 白名单无此项，pin 只供路由器自用） | 从 FORWARD_HEADERS 移除 | mock echo：Lua 修复前 worker 收到该头，修复后不再收到；pin 功能不受影响 |
| F7 | HEAD 打 GET-only 路由 → 404（axum get() 自动附带 HEAD，Rust /health /v1/models /workers /readiness /server_info HEAD 全 200；<dev-box>:8800 HEAD /health 200 仲裁一致） | 只读路由补 app:head 别名（health/liveness/readiness/v1/models/model_info/server_info/engine_metrics/metrics/workers/loads） | 08_HEAD_health 由 DIFF 转 MATCH |

## 2. 差异表（33 行）

verdict 用对拍后终值。LUA=46089 RUST=8920。

| # | 路径 / 用例 | 结果 | 证据摘要 |
|---|---|---|---|
| 1 | POST /v1/chat/completions 非流式 | 偏差(仅回显面) | 状态 200、choices/usage/finish_reason 形状、响应头集合一致；差在 mock 回显：Rust 转发体是 typed round-trip（补 9 个默认字段、丢未知字段 vendor_ext），Lua 字节透传（保未知字段）；Lua 强制 `accept-encoding: identity`，Rust(reqwest) 发 `accept: */*` |
| 2 | POST /v1/chat/completions 流式（缓冲读全） | 一致 | 7 帧、全 `data: ` 前缀、`[DONE]` 尾帧、text/event-stream、无 content-encoding、x-accel-buffering:no、cache-control:no-cache 两侧逐项相等 |
| 2b | 流式原 socket 分块时序 | 信息 | 两侧均增量转发（chunk_count 8/8，首字节 1.7 vs 0.8ms），无缓冲堆积 |
| 3 | POST /v1/completions | 偏差(仅回显面) | 同 #1：状态/形状/头一致，差 typed round-trip 与 accept-encoding |
| 4 | POST /v1/embeddings | 一致 | 200、shape、Content-Length 全等 |
| 5 | POST /v1/rerank | 偏差(Rust侧) | Lua 200+results；Rust IGW 下 503 no_available_workers（非 IGW 复现 500 rerank_response_build_failed）：V1RerankReqInput 丢客户端 model、塞 "unknown"。Lua 行为正确，不修 |
| 6 | POST /v1/responses | 一致 | 200、形状与头全等 |
| 7 | 错误: 未知 model（IGW） | 一致 | 503 + x-smg-error-code:no_available_workers + `{"error":{"type":"Service Unavailable","code","message"}}` 逐字段等（F1/F3 修后） |
| 8 | 错误: 坏 JSON `{not json` | 偏差(措辞) | 400 一致；Rust code=json_parse_error/type=invalid_request_error、无 X-SMG-Error-Code 头；Lua code=invalid_json/type=Bad Request、多带该头；serde 报错文本无法逐字复刻 |
| 9 | 错误: 缺 model（IGW） | 一致 | 双方 503 no_available_workers（F1 修后） |
| 10 | 错误: 空 body | 偏差(措辞) | 同 #8（400 一致，代码/头差异同上） |
| 11 | 错误: model:null | 偏差(措辞) | 400 一致（F2 修后）；#8 同款 code/措辞差 |
| 12 | 错误: 池中不存在的 model | 一致 | 503 no_available_workers 全等 |
| 13 | GET /health | 一致 | 200 `OK` text/plain; charset=utf-8、x-request-id、Content-Length:2（F4/F5 修后） |
| 14 | GET /readiness | 一致 | 200 三键 JSON、application/json、长度 56（修复前 Lua 是 chunked+charset 后缀） |
| 15 | GET /liveness | 一致 | 同 /health |
| 16 | GET /v1/models | 偏差(Rust侧) | 8 模型集合逐条相等（排序后全等）；仅 content-type：Lua `application/json` vs Rust `text/plain; charset=utf-8`（router_manager `.to_string()` 框架行为，<dev-box>:8800 生产同样 text/plain）。Lua 更正确，不改成错 |
| 17 | GET /server_info | 偏差(设计超集) | Rust 只有 3 键 {router_manager,routers_count,workers_count}（text/plain）；Lua 3 个共享键全在 + 自身配置摘要（policy/health_check/circuit_breaker/retry/uptime/models/enable_igw…、UI 依赖）。框架不同 + 有意超集 |
| 18 | GET /get_server_info | 同上 | 别名行为与 17 相同 |
| 19 | GET /model_info | 偏差(设计超集) | Rust 代理单个 worker（<dev-box>:8800 仲裁同为单对象）；Lua fan-out 聚合成 `{model_infos:[...]}`。共享键集合包含关系成立 |
| 20 | GET /get_model_info | 同上 | 别名同 19 |
| 21 | GET /health_generate | 偏差(已知方向) | Rust 200 text "At least one router has healthy workers"（router_manager IGW 就绪语义，prod 一致）；Lua 501 not_implemented（suite 明确断言 501，属既定设计）。未修，见 §4 |
| 22 | 头转发: chat 带 9 个头 | 信息 | authorization/x-request-id/x-correlation-id/traceparent/tracestate/x-smg-routing-key 六个白名单头两侧均转发且值原样；cookie 与 x-custom-header、user-agent 两侧均剔除；x-request-id 客户端值两侧均原样回显在响应头（F4/F6 修后仅剩 Lua accept-encoding:identity、Rust accept:*/* 的 transport 差，见 #1） |
| 23 | GET /workers 字段集合 | 信息 | top keys {workers,total,stats}、worker 11 字段名、stats 3 键全等；值型差异 2 处：cost Lua int(1) vs Rust float(1.0)；metadata Rust 带 served_model_name、Lua 为 {}（cjson 空表）。见 §4 |
| 24 | GET /v1/chat/completions | 已知 | 405+Allow:POST(空体) vs Lua 404 JSON —— 任务书已知 method gate 偏差 |
| 25 | GET /v1/completions | 已知 | 同上 |
| 26 | GET /v1/embeddings | 已知 | 同上 |
| 27 | DELETE /v1/rerank | 已知 | 同上 |
| 28 | POST /health | 已知 | Rust 405+Allow:GET,HEAD vs Lua 404 |
| 29 | PUT /v1/models | 已知 | Rust 405+Allow:GET,HEAD vs Lua 404 |
| 30 | GET /nope | 已知 | 双方 404；body 形状差（任务书已知 404 偏差） |
| 31 | HEAD /health | 一致 | 200、头集合全等（F7 修后） |
| 32 | GET /v1/chat/completions?x=1 | 已知 | 同 24（带 query 不改变门控行为） |

汇总：MATCH 10，DIFF 20（其中 Rust 侧 2 行、设计超集 4 行、措辞类 3 行、已知偏差 10 行、
回显面/transport 类 2 行——01/03a 与 05 组部分行有交叉归类，以主因计），INFO 3。

## 3. Rust 侧偏差清单（本任务不修 gateway/，供上游决策）

1. **/v1/rerank 丢 model**（行为退化）：`V1RerankReqInput{query,documents}` 转换时
   `model: default_model()` 覆盖客户端值 → IGW 下恒 503、非 IGW 下响应解析 500。
   证据：raw/03c_rerank.rust.body（503）+ mechanism-notes.txt 的 :8941 复现（500）。
2. typed body round-trip：转发体补 ~9 个 sglang 私有默认字段、丢客户端未知字段
   （`vendor_ext` 等），Lua 字节透传保留。对 SGLang 后端是特性，对第三方 worker 是丢信息。
3. JSON 响应打 `content-type: text/plain; charset=utf-8`（/v1/models、/server_info、
   /health_generate——String into_response 框架行为，prod 8800 同样）。
4. ValidatedJson 400 不带 `X-SMG-Error-Code` 头（与 error.rs 路径不一致）。
5. 无 `accept-encoding` 干预（reqwest 默认），mock 见 `accept: */*`。
6. metrics 只在独立 prom 端口（:29099），主端口 /metrics 404；Lua 主端口也提供。部署口径差。

## 4. Lua 侧未修注记（判定为不值得改 / 需产品决策）

1. **400 措辞**：Lua `invalid_json`/`Bad Request` vs Rust `json_parse_error`/
   `invalid_request_error`（+ serde 列号文本），且 Lua 多带 X-SMG-Error-Code 头。
   复刻 serde 文本无意义；头是超集、无害。
2. **/health_generate 501**：Rust 语义是「至少一个健康 worker」的 IGW 就绪探针，
   Lua suite 现有断言把它钉死为 501（test_lua_router.sh:794）。要对齐需连同契约套件一起改，属行为决策，留给人裁。
3. **/workers 值型**：cost int vs 1.0 float（Lua 5.1 cjson 无法把 1.0 编码成 "1.0"，
   需字符串 hack）；metadata 缺 served_model_name（Lua 存在 record 顶层非 metadata）。
   字段名集合完全一致，仪表盘按字段消费则无影响。
4. **/server_info、/model_info 超集**：见 §2 表 17–20，属已文档化的功能超集。

## 5. 复现

```bash
source /data/tmp/parity/env.sh
bash /data/tmp/parity/restart_mocks.sh          # 仓库版 mock ×8（含 echo_headers）
bash /data/tmp/parity/run_lua_cmd.sh            # IGW 对齐的 lua-router 容器
bash /data/tmp/parity/register.sh               # 8 worker 注册
python3 /data/tmp/parity/driver.py              # 33 组 → contract/raw + comparison.json
python3 /data/tmp/parity/analyze.py             # 人类可读 diff
bash ../test/test_lua_router.sh   # 当时 266/266 全绿；现基线 322 passed / 3 notes
```
