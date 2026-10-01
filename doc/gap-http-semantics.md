# HTTP 语义与观测对齐（feature_gap_audit2 清单 1-7 + test_gates 追加 4 bug）

范围：`router.lua`、`registry.lua`、`policy.lua`、`config.lua`、`hb.lua`、`mesh.lua`、
`config_store.lua`、`conf/ui.conf`（仅 `/_ui/config` HEAD 分支）、`test/test_lua_router.sh`、
`test/integration/test_head_routes.py`、`test/integration/test_mesh_http.py`。
基线契约 659 passed / 0 failed / 3 notes → 本轮 **717 passed / 0 failed / 2 notes**
（`bash test/test_lua_router.sh` 严格模式）。

逐项如下，每项给「修改点 / 证据 / 剩余差异」。

---

## 1. `/health_generate` 真实语义

**修改点**（`router.lua:1827` `health_generate_handler`，注册在 `:3173-3174` 的 `app:get` + `app:head`）

原来该路由答复 501 `not_implemented`。现在遍历 `registry.records()`，任一
`registry.is_healthy(id)` 为真即 `200 "At least one router has healthy workers"`
（`text/plain; charset=utf-8`，Content-Length 39），否则
`503 "No routers with healthy workers available"`。`text_response()` 会打印 body，
HEAD 由 axum 的行为决定也必须注册，所以补了 `app:head` 孪生。

**证据**：`gateway/src/routers/router_manager.rs:407-422`（两条文案逐字节，
`:416` OK、`:420` SERVICE_UNAVAILABLE），并在线上 Rust 网关核对：
`curl -i <dev-box>:8800/health_generate` → `200 text/plain; charset=utf-8`、
`content-length` 未发但 body 39 字节、`HEAD` 同样 200。契约 `proxy_endpoints` 段：
200/文案/Content-Type/Content-Length=39/HEAD=200，503 分支在「零 worker 的实例」上验
（`lr-em-$SUIT`），并断言 503 body 不含 `"error"`（不是 JSON 错误壳）。

**剩余差异**：Rust 判据是 `Router::has_healthy_workers()`（含 router 内部 worker 视图）；
Lua 侧只有一个 registry，因此「至少一个 router」等价于「至少一个 worker」，与
`/readiness` 用的是同一个 `is_healthy` 口径。Rust 的 503 走
`StatusCode::SERVICE_UNAVAILABLE` + 纯文本，这里也是纯文本而非 `{"error":...}`。

---

## 2. request-log 的 session 字段与 reasoning_tokens

**修改点**（`router.lua`）

- `sha256_hex`（`:859`）：逐字节小写 hex，与 Rust `hex_lower`
  （`observability/request_log.rs:140-149`）同形状；摘要走 `resty.openssl.digest`，
  取不到（纯 Lua 单测环境）时返回 nil 而不是抛错。
- `router_session_key(body)`（`:898`）：`prompt_cache_key` → `user` → `conversation` →
  `session_id` 取第一个非空字符串单独 sha256；四个字段全缺时，若 `messages` 长度 ≥2，
  以 `first.role .. "\0" .. content` 做 sha256，其中 content 为字符串或多模态 parts 的
  `text` 无分隔拼接；首条 content 为空串 → nil。单轮且无显式键 → nil。
- `route_inference`（`:1677`）把结果放进 `ngx.ctx.lr_session`，
  `log_inference_request`（`:3005`）写 `session = ngx.ctx.lr_session or cjson.null`。
- `usage_from_object`（`:793`）新增第 4 个返回值 reasoning：
  `usage.completion_tokens_details.reasoning_tokens`，回退 `usage.reasoning_tokens`；
  `usage_from_body`、SSE 末帧 `sse_usage`、stream pump、`ngx.ctx.lr_tokens[5]`
  一路带通，`:3001` 写 `reasoning_tokens = reasoning`（原来写死 0）。
- `/_ui/logs` 与 stats/UI 消费链未改结构：`ui/logs.html` 已经在读
  `r.session`（会话列 + 「筛选日志」按钮）和 `r.reasoning_tokens`，两端字段名一致。

**证据**：`observability/request_log.rs:151-200`（`session_key`，含 `[0u8]` 分隔与
`join("")`）、`:304-309` 与 `:918-922`（两处 reasoning 读取）。契约 `observability` 段用
**独立实例** `lr-sess-$SUIT` 跑六次 chat，逐行断言 `.requests[i].session` 等于
`printf | sha256sum` 在宿主机算出的期望值：两个不同 `prompt_cache_key`、role+NUL 拼接的
两种 message 会话、同首条消息复现同一 session、单轮无键为 null。reasoning 用一个内嵌
Python worker（`start_reasoning_worker`，usage 带
`completion_tokens_details.reasoning_tokens: 7`）断言 `.reasoning_tokens == 7` 且同行
`prompt_tokens==3 / completion_tokens==12`，其余行必须为 0。

**剩余差异**：Rust 的 session 字段在 request-log 行里叫 `session`，这里同名；Rust 侧
`/v1/responses` 的 conversation 派生路径（`conversations/…`）不参与 session_key，Lua 也只读
body 的这四个键。session 计算发生在路由阶段（body 还在手），因此对**被拒/未转发**的请求
不会落 session——与 Rust 只在产生 request-log 行时才计算一致。

---

## 3. `/engine_metrics` 改成合法 Prometheus exposition

**修改点**（`router.lua:2186-2560`）

旧实现把各 worker 的 `/metrics` 原文拼在 `# worker <url>` 注释下，同一个 name 出现多条
`# HELP`/`# TYPE`，任何抓取器都会拒绝。新实现照 `core/metrics_aggregator.rs` 的语义重写：

| 步骤 | Lua | Rust |
|---|---|---|
| 冒号改名 | `underscore_colons`（整段 `:`→`_`，`string.gsub`） | `metrics_text.replace(":", "_")`（`:20`） |
| 解析 | `parse_prometheus` + `scan_labels`（逐字符，支持值内 `,"{` 与转义引号） | `openmetrics_parser::prometheus::parse_prometheus` |
| 打标签 | `render_sample` 用 `label_insert_index` 复刻 `with_labels` 的 `binary_search` 插入位（`public/model.rs:105-125`），每个 sample 带自己的 `worker_addr`（值为完整 url，含 scheme，等同 `fan_out` 记录的 `resp.url`） | `transform_metrics`（`:41-49`） |
| 合并 | `merge_pack`（family 首现顺序保留，HELP/TYPE 取首个非空） | `merge_exposition`/`merge_family`（`:51-72`） |
| 渲染 | `render_exposition`：每 family 一条 HELP、一条 TYPE，family 间空行，sample 逐行 | `Display for MetricsExposition`（`model.rs:315-330`） |

失败分支按 `core/worker_manager.rs`：0 worker → `500 "No available workers"`；全部抓取失败
→ `500 "All backend requests failed"`；成功 → 200。抓取超时是 reqwest 固定的 5s
（`worker_manager.rs:25 REQUEST_TIMEOUT`），不是 `health_check_timeout_secs`，worker 的
`api_key` 以 bearer 呈现。

**证据**：`core/metrics_aggregator.rs` 全文 + `core/worker_manager.rs:25-60,70-83`。契约断言：
200、`text/plain`、含 `mock_uptime_seconds`、不含 `# worker `、含 `worker_addr="`、
含 `sglang_num_running_requests` 且不含 `sglang:`、恰好两个不同地址、mock 的 sample 条数
与 `HELP`/`TYPE` 去重（`uniq -d` = 0）、所有非注释行都是合法 sample；失败两分支在
worker-free 实例上验 500 + 两条文案。聚合器另有一份离线单测（双 worker 合并、histogram
折叠进声明族、timestamp 原样、`worker_addr` 插在 `le`/`model_name` 之后）。

**剩余差异**：Rust 用 openmetrics-parser 的强类型 family（gauge/counter/histogram/summary）
并会在 label 集合不一致时**整族合并失败**（`merge_family` 的 `ensure!`）；Lua 侧对同族
label 名不一致只是逐 sample 原样渲染，不会丢族。Rust 的 `Display` 对未知 type 会省略
`# TYPE`，Lua 一致（`type == "unknown"` 时不输出）。histogram 的 `le` 标签值本身若含冒号，
两侧都会被 `replace(":", "_")` 波及——这是照抄的 Rust 怪癖。

---

## 4. `/v1/loads` 真探引擎 + 删除 `/v1/loads/stream`

**修改点**（`router.lua:2780` `loads_handler`，注册 `:3187-3190`；`v1/loads/stream` 路由删除）

每个 worker 发 `GET {url}/v1/loads?include=core`（5s 超时 + bearer），取
`aggregate.total_tokens`；非 http 连接模式、超时、非 2xx、缺字段一律 `-1`。返回
`{workers:[{worker,load}], total_workers, successful, failed}`。旧私有形状（`loads[]` 带
`cb_state`、`timestamp`）已删除。

**证据**：`core/worker_manager.rs:96-205`（含 `parse_load_response`）。契约
`proxy_endpoints` 段：形状与字段、mock+sink 全 `-1` 且 `successful=0`/`failed=2`、
`start_load_worker 4242` 的成功路径读出 4242、`successful=1`、其余仍 `-1`、
`total_workers=3`、`.loads == null and .timestamp == null`、`GET /v1/loads/stream` →
404 `not_found`（Rust axum 表里没有这条）。探测 worker 用完即删，后面的
`/model_info`/`/flush_cache` 仍看到两个 worker。

**剩余差异**：线上 Rust 网关（<dev-box>:8800，实测）`/v1/loads` 的 wire 形状**只有**
`{"workers":[{"worker","load"}]}`——`WorkerLoadsResult` 里的
`total_workers`/`successful`/`failed` 是内部计算值，`IntoResponse` 不输出它们。
本实现把这三个计数一起发到 wire 上，属于**同形状内的超集**（lua-router 的
`/_ui` 读它们），已在 `loads_handler` 注释与本文件记录；Rust 在
`include=core` 之外的详细字段（`token_usage` 等）不做透传。另外 Rust 的
`WorkerLoadInfo` 还带 `worker_type`（prefill/decode 时出现），本 router 只支持
regular worker，因此该键恒不出现。
`README.md:98` 与 `doc/feature-gap.md:131` 仍把 `/v1/loads/stream` 记为超集——那两个文件不在
本轮所有权内，需要后续删除该描述（此处标注移交）。

---

## 5. 出站连接池（cosocket pool）

**新增配置**（`config.lua:202-205`，全部走 `SMG_*`）

| 键 | 默认 | Rust 对应 |
|---|---|---|
| `SMG_CONNECT_TIMEOUT_SECS` | 10 | `config/types.rs:9-13` |
| `SMG_POOL_IDLE_TIMEOUT_SECS` | 50 | `pool_idle_timeout` |
| `SMG_POOL_MAX_IDLE_PER_HOST` | 500 | `max_idle_per_host` |
| `SMG_TCP_KEEPALIVE_SECS` | 30 | `tcp_keepalive` |

`validate()`（`config.lua:259-274`）把这四键 `<1` 时回落到 Rust 默认值。

**连接侧**（`registry.lua`）

- `pool_name(kind,url)` → `lr:<kind>:<c|s>:host:port`，`pool_opts(cfg,kind,url)` 返回
  `{pool, pool_size, so_keepalive={idle,interval,count=3,always_send=true}}`，
  `pool_idle_ms(cfg)` 给 `setkeepalive` 的 TTL（`:205-253`）。
- `release(sock,cfg,reusable,kind,url)`：可复用才 `setkeepalive(idle_ms, pool_size)`，
  否则 `close()`（`:330`）。
- `response_reusable(headers,complete)`：body 未读尽、或对端回了 `Connection: close`
  → 不可复用（`:306`）。
- `pump_chunked(sock,collect)` → `body, complete`：读完最后 chunk 的 CRLF 与 trailer 块。
  这是之前所有 helper 静默丢掉 keepalive 的根因——socket 里还剩字节时
  `setkeepalive` 直接返回 "unread data in buffer"。
- `tls_handshake(sock,host,tls)`（`:179`）：http{} 语境 `connect` 不做 TLS，https 必须显式握手。

**调用点**：`router.lua` `send_attempt`（`:1024`，forward 用 kind `forward`/`stream`）、
`read_response_body`（`:1115`，返回 `body,complete`）、`stream_response`（`:1150`，手写分帧
泵——SSE 不能整包缓冲，末尾按 complete 决定入池）、非流式成功路径 `registry.release`
（替换原来裸 `setkeepalive(request_timeout_secs*1000)`）；`hb.http_request`（kind `hb`，
**含本轮补回的 TLS 握手**）、`mesh.http_request`（kind `mesh`，
`mesh_config()` 取不到配置时不入池以保住纯 Lua 单测路径）、
`config_store.raw_request`（lua-resty-http 分支 `keepalive=true` +
`keepalive_timeout/keepalive_pool`；cosocket 回退分支 kind `store`）。三条手写 HTTP 路径
都去掉了 `Connection: close`——带池 socket 上那个头等于让对端关掉 `setkeepalive` 正要复用的连接。
`discard_body`（`:1089`）保持 `close` 并注释了原因。

**实测结论**（用宿主 mock 计数 accept 得到，容器与脚本已清理）：命名池 + `setkeepalive`
生效——明文 4 次请求 1 次 accept，TLS 5 次请求 2 次 accept；`sock:connect()` 第三返回值
（reused）在此镜像恒为 nil，**不能**用来判断复用，但已握手 socket 上重复 `sslhandshake`
立即返回成功，所以 hb/mesh/config_store 无条件握手是安全的；`so_keepalive` 四元组被接受；
上游先关时复用的首次 `receive` 返回 nil（重试路径覆盖）；池必须 TLS/明文与调用类别分池。

**`max_idle_per_host` 的近似语义（必须知道）**：nginx 的 cosocket 池是**每 nginx 进程**一份，
`pool_size` 是该进程内该 pool 名的空闲上限，而 reqwest 的 `max_idle_per_host` 是全客户端共享。
因此 `SMG_POOL_MAX_IDLE_PER_HOST=N` 在 `worker_processes=M` 下的真实上限是 `N×M`；
`openresty` 也没有把「池已满」暴露出来，超出的 socket 由内核与对端 TTL 收敛。
`pool_idle_timeout` 是精确映射（`setkeepalive` 的 timeout 参数）。

---

## 6. per-model policy hint

**修改点**

- `registry.policy_hint_for_model(model_id)` → `hint, count`（`:360`）：扫该模型的 worker
  记录，取第一个 `labels.policy`，同时返回该模型的 worker 数。
- `policy.lua`：`_M.instances`（`:64`，`new()` 末尾按 `name_instance()` 登记）+
  `_M.for_model(cfg, model, hint, has_workers)`（`:371`）——该模型最后一个 worker 消失时
  清掉它的实例并回落 default；否则 `new(cfg,{model,name})` 建实例并 `restore_snapshot()`。
  `manual_key(inst,rk)` → `manual:<model>|<rk>`（`:141`），新增 `group_key(inst,url)` →
  `group:<model>|<url>`（`:146`，min_group 计数同样按模型隔离），4 处调用点改用它们；
  `on_remove` 会删掉该 url 的 per-model group 键；`sweep_max_idle` 遍历 `_M.instances`
  而不只是 default。
- `router.policy_for(model)`（`:82`）：有 hint 且该模型有 worker →
  `policy_mod.for_model(conf, model, hint, count>0)`；无 hint → 共享的 `default_policy`。

**为什么 manual/cache_aware 的状态必须带 model**：manual 的 sticky 映射与 cache_aware 的
基数树都放在全局 shdict 里，键不带 model 时，一个在模型 A 上钉住的会话会在模型 B 上被
命中。Rust 侧是 `PolicyRegistry` 每模型一个策略对象，天然隔离。

**证据**：`policies/registry.rs:66,111,162,172`（`on_worker_added` →
`determine_policy_for_model`，最后一个 worker 掉注册）、
`core/steps/worker/shared/update_policies.rs:102-113`（hint 取自 labels.policy）。
契约新增 `policy_hint` 段：`SMG_POLICY=manual SMG_ENABLE_IGW=1` 的实例上注册三个模型
（A=`round_robin`、B=`cache_aware`、C 无标签，每模型两个 worker），同一
`x-smg-routing-key` 各打四轮，从 `/_ui/logs` 断言 A 的 `route_type` 唯一为
`round_robin`、B 为 `cache_aware`、C 回退 `manual`，三者至少三种；再加行为断言：
`round_robin` 把 sticky key 摊到 A 的两个 worker（unique worker = 2），`manual` 把 C 钉在
一个 worker（= 1），继续打流量后 C 仍是 1——这才证明状态是按模型分开的实例而不是一个全局
策略在看所有请求。

**剩余差异**：Rust 的首个 worker 决定策略后对该模型**粘住**（后续 worker 换 hint 不改）；
这里同样取第一个，但「第一个」是 registry id 顺序而非注册时间戳，同一模型上混放不同 hint
时两者可能选到不同的名字。Rust 的 per-model 策略在 `last worker gone` 时删对象，这里删
Lua 实例并清 sticky/group 键（shdict 侧靠 `max_idle_secs` TTL 收敛）。`consistent_hashing`
/`prefix_hash`/`bucket` 的实例同样按 model 建，但其内部 shdict 键本就带 worker/前缀维度，
未再加 model 前缀。

---

## 追加 bug 1-4（test_gates 发现）

1. **`registry.bootstrap()` 绕过 mesh 镜像** → `mesh_mirror(id)` / `mesh_forget(id)` 现在是
   `registry.lua:489/507` 的局部函数，挂在**写路径**上：`add()` 成功末尾、`remove()` 返回前、
   `patch_record()`（覆盖 discovery 与 PUT）、`set_healthy()`（健康翻转）。bootstrap 走
   `add()`，因此种子 worker 自动入镜像，无需单独补。
   ⚠️ 局部函数必须定义在**第一个调用点之前**——本轮曾因定义晚于调用而全站 500
   `attempt to call global 'mesh_mirror'`（contract run1 的 73 个 FAIL 全是它）。
2. **mesh 镜像冻结在注册瞬间** → 同上，`patch_record`（discovery 写 model_id/labels）与
   `set_healthy`（每次健康翻转）都重镜像，`observe_worker` 内部递增 version，因此
   `/ha/workers` 会跟到 `health=true` + 真实 `model_id`，不再需要一次 PUT 才刷新。
3. **`/_ui/config` HEAD 400** → `conf/ui.conf:165` 分支改为 `method == "GET" or method == "HEAD"`
   → `ui.config_get()`（已授权范围内）。
4. **`/_ui/history` HEAD 404** → `router.lua:3207` 补 `app:head("_ui/history", exact_json(ui_history_handler))`。

**证据**：`test/integration/test_head_routes.py` 第 6 节两条 DIVERGENT 断言翻成正向
（`/_ui/config` 与 `/_ui/history` 的 HEAD 都要求 200 + 与 GET 的 header parity，覆盖未减少）；
`test/integration/test_mesh_http.py` 第 9 节改为断言 boot-seeded id **在** `/ha/workers`、
镜像由 discovery + 健康扫描刷新为 `health is True` / `model_id == "beta"`（原先「必须 PUT 才刷新」
的对照断言改成「无需 PUT 已刷新」）。

**契约里的 `avg_duration_ms`**：`observability` 段改为 number-or-null
（`(.avg_duration_ms == null) or (.avg_duration_ms|type=="number")`）。Rust 的
`Stats::avg_duration_ms` 是 `Option<f64>`，10s 滑窗无 2xx 样本时为 null，原来的
`| type == "number"` 会偶发红。

---

## 回归数字

| 门禁 | 结果 |
|---|---|
| `test_lua_router.sh`（严格） | **717 passed / 0 failed / 2 notes**（基线 659/0/3） |
| `final_gates.sh` | 12 门全绿（见 `gates.log`） |
| 单测 luajit 口径 | tree 67 / policies 118 / hash 795 / history 731 / mesh 361 / pd 219 |
| 单测 resty 口径 | tree 67 / policies 118 / hash 795 / integration 66 / tokenizer_parse 316 |
| e2e | probes、stateful、policies、ui_bridge、errors、effort、head_routes、mesh_http 均通过 |

新增/改动的契约断言位置：`observability` 段（session 6 条 + reasoning 2 条 + avg_duration_ms）、
`proxy_endpoints` 段（engine_metrics 全套、worker-free 实例的 500/503、loads 新形状与成功路径、
loads/stream 404、health_generate 200/HEAD）、`policy_hint` 段（per-model hint 12 条）。

## 本轮改动自己引入、并被门禁抓到的两个缺陷

这两个都值得记下来，因为它们都不在契约的可见面上：

1. **`sweep_max_idle` 遍历了 key 而不是实例**。`for inst in pairs(_M.instances)` 里
   `inst` 是字符串键，`inst.impl` / `inst.name` 全取到 nil，于是整个 per-instance
   清扫（cache_aware 的 `evict_all`/`adjust_all`/snapshot 写回）与两个 gauge
   （`smg_manual_policy_cache_entries`、`smg_cache_aware_tenant_count`）静默不再执行。
   没有任何日志。抓它的是 `e2e_stateful` 的
   `[manual] branch counter + cache gauge published` 与
   `[snapshot] cache_aware tenant gauge published`。
   已改为 `for _, inst in pairs(...)`（`policy.lua:664`）。
2. **`hb.http_request` 丢了 TLS 握手**：见下节。

教训：把单例改成实例表之后，所有遍历点必须复核 `pairs` 的两个返回值；契约看不到
「gauge 消失」这类退化，只有 e2e 的 metrics 断言看得到，所以 final_gates 全量比
只跑 contract 更值得跑。

## 顺带修掉的一个真实缺陷

`hb.http_request` 在接入连接池时丢掉了 `registry.tls_handshake` 调用（`tls` 变量解析出来却没
用过），导致 https worker 被明文探测而永远不健康——契约 `tls_upstream` 段
（`tls: https worker never became healthy`）抓到并已由
`lualib/resty/luarouter/hb.lua:71-75` 修复。教训：手写 HTTP 路径的 TLS 升级必须逐点核对，
`connect` 的 `ssl=true` 在 http{} 语境不生效。
