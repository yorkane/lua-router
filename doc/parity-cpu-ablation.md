# lua-router 非流式每请求 CPU 回退：静态定责与负载消融计划

> 任务来源：`doc/parity-perf-v2.md` §7 遗留项（「关闭 CORS + 请求日志后仍有 1.54x 未定责」）、
> §11 建议 1。本轮**纯静态**：只读代码 + 读 /data/tmp/parity/perf-v2/ 已归档数据，
> 另用 docker save 从 lua-router:latest 镜像里解出出厂 Lua 源码逐行比对（临时目录
> /data/tmp/lua-router-factory-inspect/）。**未跑任何压测/负载、未产生任何 microbenchmark 数据、
> 未启停任何压测容器**（仅两次秒级只读 docker run --rm 用于定位镜像内文件）。
> 所有 µs/req 数字都取自 parity-perf-v2 已归档的消融窗口，可复算。
> 报告日期 2026-09-30（UTC）。分析对象见 §0.1 —— **本轮最重要的方法论纠正：被量的那份代码不是当前工作树**。

## 0. 结论摘要

**嫌疑榜前 5 名（每条一句话，回收区间相对 113 µs 的未定责残差）**

1. **请求日志行在 `LMR_REQUEST_LOG_CAPACITY=0` 时仍然整行构建**（`log_inference_request` 无条件跑），
   它自带 1 次 `candidates_for` + 1 次 `policy_for` + 1 张 26 字段表 + 3 次 `compact_url` 正则 —— 预计回收残差的 25–40%。
2. **`registry.records()` 每请求被调 5 次（出厂 2 次），每次重新 shdict 读 + cjson 解码全部 worker 记录**；
   3 次来自 `policy_for` 里新增的 `policy_hint_for_model` —— 与第 1 条同源，合计预计回收 45–65%。
3. **`config_store.current()` 在无快照时走 `cfg_from_env()` 全量重建（无正向缓存），每请求 3 次**
   （`resolve_alias` / `apply_effort_policy` / `apply_ctx_cap` 各一次）—— 预计回收 3–10%；设了
   `LMR_CONFIG_FILE` 的生产形态更贵（每请求整份快照解码），那里区间上移。
4. **histogram / 滑窗写入的 decode-modify-encode 往返变多**（每请求 4 次 `note_window` + 2–3 次 `observe`，
   每次都把 20 桶直方图整块解码再编码回 shdict）—— 预计回收 6–15%。
5. **上游 cosocket 池的 Lua 侧新增路径**（`split_url` 每 attempt 被跑 3 遍 = 9 次正则、池名表、`setkeepalive`）
   —— 预计**净收益或≈0**（它省掉的是 syscall），列为嫌疑是为了把它从「代价」里排除掉。

**最可能的大头**：第 1、2 条是同一件事的两个入口 —— **worker 记录表每请求从共享字典重建 5 次（出厂 2 次）**，
P1+P2 合计按 45–65% 计（两项有重叠，不做加法）。依据三条：
① §2.2 —— 日志行的构建门与容量开关无关，所以 §7 的「日志只值 6%」是量错了对象；
② §2.7 —— 每请求 shdict 往返 44 → 66、cjson.decode 6 → 12，全部出自这一处；
③ §3.1 —— 残差比值随并发从 1.32x 升到 1.55x，指向共享内存往返而非纯算术。

**必须同时记录的坏消息**：1.54x 这个数是在 `5b60aae9…` 上量的，而当前工作树（`router.lua` md5 `9d890193…`）
在它之后又加进了 **otel 全链接线、in-flight 年龄追踪、JWT 控制面闸门、SSE accumulator、
`patch_response_metadata`**。也就是说**当前代码只会比 339 µs 更贵，不会更便宜**，任何消融实验
都必须在新基线上重取，不能沿用 §7 的比值。详见 §5。

**Rust 侧同样存在（语义必需）vs Lua 实现引入（可优化）** 的划分见 §6，结论是：
残差里**没有一项是语义新增**（出厂镜像本来就在跑同一套 Rust 契约），全部是实现形态问题。

---

## 0.1 三份代码的口径（本轮分析的地基）

`parity-perf-v2.md` §10 已经声明过 md5 混杂，但 §7 的消融结论读的是「工作树相对出厂镜像的差量 = 2270 行 diff」，
这句话把两份不同的代码当成了一份。本轮把三份代码全部取回来做了逐项 grep（出厂那份是从
`lua-router:latest` 镜像 `docker save` 解出来的，不是 `ref/latest_router.lua` 的猜测）：

| 代号 | md5（router.lua） | 来源 | 被哪些数字用到 |
| --- | --- | --- | --- |
| **出厂** | `1d48f333…` | `lua-router:latest`（`268960883acd`）镜像内置，实际路径 `/usr/local/openresty/site/lualib/resty/luarouter/router.lua`（1569 行） | `lua_ref` 全部行 |
| **被量工作树** | `5b60aae9…` | `ref/integration_router.lua` 快照（11:51）+ `ref/integration_registry.lua` | 主矩阵 / A/B / **§7 消融的全部 `lua` / `abl_*` 行** |
| **当前工作树** | `9d890193…` | `lualib/resty/luarouter/router.lua`（4059 行，21:34） | 本轮静态分析对象；**没有任何压测数字** |

关键后果（下一节逐条给证据）：**§7 未定责的 1.54x 里不含 otel、不含 in-flight 追踪、不含 JWT 闸门、
不含 accumulator、不含 `patch_response_metadata`** —— 这些父任务点名的候选在当时那份代码里
`grep -c "otel" = 0`、`grep -c "inflight_track" = 0`。它们是新成本，不是 1.54x 的解释。

---

## 1. 非流式请求热路径逐段清单（当前工作树，带行号）

入口链：`server` 级 `rewrite_by_lua_block` → `router.preflight_guard()`
（[nginx.conf.template](../conf/nginx.conf.template:163)）
→ `location /` → `content_by_lua_block` → `router.handle()`
（[router.lua](../lualib/resty/luarouter/router.lua:3972)）
→ klib.router 分发 → `inference_handler` → `route_inference` → `forward`
→ `finish_request` → `log_by_lua_block` → `init.on_log()`。

下面每段给「每请求执行什么 + 成本来源」，行号是当前工作树。

### 阶段 A —— server 级 rewrite（每个请求，含非 OPTIONS）

| # | 位置 | 内容 | 成本来源 |
| --- | --- | --- | --- |
| A1 | [router.lua:3418](../lualib/resty/luarouter/router.lua:3418) `preflight_guard` | 非 OPTIONS 分支仍调 `cors_apply()` | 3 次 `ngx.header[]` 写 + `cors_decision()`（`cfg().cors_allowed_origins` 空 → 不读 header，直接返回 `*`） |
| A2 | 同上 | OPTIONS 才走 `cors_preflight()` | 本压测不触发（客户端 keep-alive 直发 POST） |

出厂镜像**没有这一整个 rewrite 块**（出厂的 `nginx.conf.template` 只有 `location /` + `${SERVER_EXTRA}`，
无 `rewrite_by_lua_block`）。这就是 §7 里 CORS 那部分的真实形态：不是「预检贵」，是「每个请求多一次
server 级 Lua 调用 + 3 个头写」。

### 阶段 B —— `handle()`（[router.lua:3972](../lualib/resty/luarouter/router.lua:3972)）

| # | 行 | 内容 | 每请求成本 |
| --- | --- | --- | --- |
| B1 | 3975 | `ngx.now()` + 写 `ngx.ctx.lr_started` | 1 ctx 写 |
| B2 | 3980 | `observability.record_http_request` | **4 次 shdict**（counter incr + inflight incr + `note_window` 的 get+set）+ 被量树里 `note_window` 要整块 decode/encode 滑窗样本 |
| B3 | 3981 | `begin_trace()`（**仅当前树**） | otel off 时 = `otel.is_enabled()` 一次布尔；otel on 时 = 2 次 `random_hex` + traceparent 渲染 + 1 次 counter |
| B4 | 3986 | `otel.echo_request_traceparent()`（**仅当前树**） | otel off 时 1 次布尔判断 |
| B5 | 3989 | `ngx.header["X-Request-Id"] = request_id()` | `request_id()` 首次 → **`ngx.req.get_headers()` 整表构建** + `request_id_headers` 循环 + 未命中则 `generate_request_id()`：**24 次 `math.random` + 24 次 `sub` + `table.concat`** |
| B6 | 3992 | `cors_apply()` | 与 A1 重复（同一次请求里 CORS 头被写 2 遍） |
| B7 | 3998 | `instance:handle({})` | klib.router 位图分派：O(1)（`router_map[bits]`），路由条数从出厂 27 涨到 ~90 条，但分派不是线性扫描 → **可忽略** |

`generate_request_id` 是出厂/被量/当前三份都在跑的成本，**不进残差**。

### 阶段 C —— `inference_handler`（[router.lua:2439](../lualib/resty/luarouter/router.lua:2439)）

| # | 行 | 内容 | 每请求成本 |
| --- | --- | --- | --- |
| C1 | 2440 | `check_data_auth()` → `check_key(cfg().api_key)` | `api_key` 未配 → 立即 true，**0 成本**；配了才 `get_headers` + `constant_eq` 逐字节 |
| C2 | 2447 | `limit().acquire()` | `SMG_MAX_CONCURRENT_REQUESTS` 默认 -1 → `enabled()` 返回 false → **纯 no-op，不进 shdict** |
| C3 | 2456 | `ngx.req.read_body()` + `get_body_data()` | 与出厂相同 |
| C4 | 2470 | **`json_decode(raw)`** | **请求体第 1 次解码**（本夹具 ~55 字节，真实请求几 KB 起）—— 出厂也有 |

### 阶段 D —— `route_inference`（[router.lua:2363](../lualib/resty/luarouter/router.lua:2363)）：新增成本最密集的一段

| # | 行 | 内容 | 每请求成本（机制） |
| --- | --- | --- | --- |
| D1 | 2391 | `resolve_alias(model)` → `store()` → `config_store.resolve_model` | `store()` = **`pcall(require,...)` 每请求都跑**（4 个入口 ×1）；`resolve_model` → `_M.current()` → `read_snapshot()` → `dict():get("runtime_config")` **未命中** → `env("LMR_CONFIG_FILE")` 为 nil → **落到 `cfg_from_env()` 全量重建**（1 张 cfg + 5 张空表 + 7 次 `env()` + 7 次 `parse_pairs`） |
| D2 | 2397 | `apply_effort_policy` → `pcall(store_mod.request_effort_for,...)` | **第 2 次 `current()` 全量重建** + 1 次 `pcall`；结果无配置 → 不改 body |
| D3 | 2398 | `apply_ctx_cap` → `pcall(store_mod.ctx_cap,...)` | **第 3 次 `current()` 全量重建** + 1 次 `pcall`；无 cap → 不改 body |
| D4 | 2401 | `router_session_key(body)` | 本夹具 `#messages < 2` 且无 user/prompt_cache_key → **早退返回 nil**（几乎免费）；真实多轮会走 `sha256_hex` |
| D5 | 2402–2410 | 7 个 `ngx.ctx.*` 写 | 出厂只写 4 个 |
| D6 | 2412 | `policy_for(resolved)` | → **`registry.policy_hint_for_model` → `registry.records()`**：1 次 ids get + N 次 record get + **N 次 cjson.decode** |
| D7 | 2416 | `inst:needs_request_text()` | `round_robin` → false → **跳过 `text_for`**（`chat_text` 全文本拼接不跑） |
| D8 | 2417 | `forward(..., ngx.req.get_headers())` | 建一张 header 表 —— 与出厂等量（出厂在 forward 内部自己建），**不是新增** |
| D9 | 2419 | `patch_response_metadata` + `persist_response` | **仅 `/v1/responses`** → 本压测**不跑** |

### 阶段 E —— `forward`（[router.lua:2048](../lualib/resty/luarouter/router.lua:2048)）

| # | 行 | 内容 | 每请求成本 |
| --- | --- | --- | --- |
| E1 | 2063 | `record_router_request` | 1 次 counter incr（6 个 label 的 `label_pairs` 拼串） |
| E2 | 2071 | `candidates_for(model)` → **`registry.records()`（第 2 次）** | 1 + N get，**N decode**；再对每条 record 调 `is_available` |
| E3 | registry:1324 | `is_available(id)` | 被量/当前 = **3 次 shdict get**（health + `http_selectable` 的 K_HSEL + breaker cbstate）+ 选中后再 `registry.load` 1 次 get；**出厂只有 2 次 get**（health + cbstate） |
| E4 | 2082 | `policy_for(model):select(...)` → **`registry.records()`（第 3 次）** | 同 D6；`round_robin` 自身只 1 次 `dict():incr` |
| E5 | 2103 | `hold_load` → `change_load` | 1 次 `incr` + 1 张 `ngx.ctx.lr_held` 表（出厂也有） |
| E6 | 2106 | `rewrite_model(raw_body, worker.model_id)` | `json_encode(target)` + **1 次 `ngx.re.find`（PCRE 全文扫描请求体）** + 3 段字符串拼接（= 整份 body 复制 2 次）——出厂同款，不进残差 |
| E7 | 2117 | `collect_forward_headers` | 第 3 次 `get_headers()` + `pairs()` 全表遍历 + `should_forward_request_header`（每条 header 线性比 6 次）+ `otel.inject` |
| E8 | 2126 → 1495 | `send_attempt` | `connect_target`→`split_url`（**2 次正则**）、`pool_opts`→`split_url`（**再 2 次**）、`pool_name`→`split_url`（**又 2 次**）= **每 attempt 9 次 `ngx.re.match`**；出厂只 1 次 `split_url` = 3 次正则。出厂每请求 `sock:close()`，当前 `setkeepalive` |
| E9 | 2244 | `registry.release` + `response_reusable` | `setkeepalive` + 1 次 `ngx.re.find`（查 `Connection: close`） |
| E10 | 2247 | `hb.record_status` → `record_outcome` | 被量/当前 = `charge_cb`（1 set + 1 incr）+ `cb_state`（**10 次 shdict get**）+ `url_for`（1 get）+ `record_cb_outcome`（1 incr）≈ **14 次 shdict**；出厂 = `cb_state`(10) + `set_cb_counters`(2) + `url_for`(1) ≈ 13 次 → 只差 1 次，**不是大头** |
| E11 | 2259 | `usage_from_body` → **`json_decode(response_body)`（第 2 次解码）** | 出厂同样有 —— 不算新增 |

### 阶段 F —— `finish_request`（[router.lua:3764](../lualib/resty/luarouter/router.lua:3764)）

| # | 行 | 内容 | 每请求成本 |
| --- | --- | --- | --- |
| F1 | 3768 | `otel.finish()`（**仅当前树**） | otel off = 1 次布尔 |
| F2 | 3773 | `limit().release()` | ctx 标志位为 nil → 立即返回 false，**0 shdict** |
| F3 | 3778 | `observability.inflight_untrack()`（**仅当前树**） | ctx 无 key → 立即返回 false，**0 shdict** |
| F4 | 3779 | `record_http_duration` → `observe` | **shdict get + cjson.decode(20 桶) + 20 次 `tonumber` 补洞 + 增量 + encode + set** |
| F5 | 3782 | `record_http_response` | 1 incr |
| F6 | 3785 | `inflight_add(-1)` | 1 incr |
| F7 | 3789 | `record_router_duration`（**被量树新增**） | 第 2 次 `observe`（同上整套 decode/encode）；当前树内部还有第 3、4 次 observe |
| F8 | 3792 | `log_inference_request` | **见 §2 —— 本节的核心发现** |

### 阶段 G —— `init.on_log()`（[init.lua:602](../lualib/resty/luarouter/init.lua:602)）

log 阶段每请求再跑一次：`pcall(require otel)` + `otel.finish`（幂等）+ `pcall(require limit)` +
`limit.release` + `pcall(require observability)` + `inflight_untrack`（仅当前树）+ 泄漏 load 检查。
出厂的 `on_log` 只有最后一项（`held` 检查）。**当前树每请求多 3 次 `pcall(require)` + 2 次幂等空转**。

---

## 2. 逐项成本论证（机制，不是猜测）

### 2.1 每请求的共享字典往返与 cjson 次数（残差的主测量口径）

非流式、`round_robin`、2 个 worker、无 DP、无 mesh、otel 关。计数取自源码调用点，
「出厂」= 镜像内 `1d48f333`，「被量」= `5b60aae9`（`abl/base_resty` 的 registry/observability 与它同版），
「当前」= `9d890193`。

| 成本中心 | 出厂 | 被量 | 当前 | 说明 |
| --- | ---: | ---: | ---: | --- |
| `registry.records()` 调用次数 | **2** | **5** | **5** | `policy_hint_for_model` ×2（`route_inference` + `forward`）+ `candidates_for` ×2（选型 + 日志行）+ 日志行里的 `policy_for` |
| └ 由此产生的 shdict get（仅 `records()` 本身） | ~10 | ~31 | ~31 | 每次 = 1 次 ids + 每 worker 1 次 record get；`candidates_for` 另叠加 health/hsel/cbstate/load，完整累加见 2.7（该表把 `policy_for` 的 3 次调用各记 1 次 `records()`，合计 5 次） |
| └ 由此产生的 cjson.decode（**仅 worker 记录，不含请求/响应体**） | 4 | **10** | **10** | 每条记录整份 JSON 解码；含两个 body 后的总数是 6 → 12（见 2.7） |
| `ngx.req.get_headers()` 次数（推理路径实际执行） | 3 | 3 | 3 | factory: forward + collect_forward_headers + request_id；工作树: handle 的 request_id + route_inference 显式传参 + collect_forward_headers。**不是差异项，P6 撤销** |
| `observe()`（20 桶直方图 decode→encode） | 1 | 2 | **4** | http + router duration（当前树内部再加 tpot / generation） |
| `note_window()`（滑窗样本 decode→encode） | 4 | 5 | 5 | req / in_tok / out_tok / dur_ms / dur_n（`est` 为 0 时提前返回） |
| `note_duration()` | 无调用 | 1 | 1 | 日志行的平均时长 |
| `http_selectable` 的 K_HSEL get | 无此键 | 2/req | 2/req | 工作树新增的池门 |
| `config_store.current()` 次数 | 0 | 3 | 3 | 全部落到 `cfg_from_env()` 重建（见 2.4） |
| `pcall(require, "…config_store")` | 0 | 3 | 3 | `store()` 每请求重新 pcall |
| `pcall(require, …)` in `on_log` | 0 | 1 | **3** | otel / limit / observability |
| `inflight_track` shdict `add` | — | — | 1 | 仅当前树 |
| otel span 生命周期 | — | — | 2 次 `random_hex` + 渲染 | 仅当前树，**默认关** |
| `request_log` 行构建（表字面量 + 正则 ×3 + `policy_for` + `candidates_for`） | 有 | 有 | 有 | **`LMR_REQUEST_LOG_CAPACITY=0` 时仍然整段执行** —— 见 2.2 |

**结论（机制层面）**：把上表按 2 worker / 单 attempt / 成功 200 的路径逐项相加，
被量代码相对出厂 **shdict 往返 ≈44 → ≈66（1.50x）、`cjson.decode` 6 → 12（2.0x）、
`cjson.encode` ≈6 → ≈8、PCRE 调用 ≈8 → ≈15（+6 全部来自连接池的 `split_url`，
`config_store` 在未配置形态下不产生正则，见 2.4）**。
这几项是同一形态的成本（小对象、共享内存、无系统调用、纯 Lua/C 边界往返），
而且**几乎全部是新增模块「接线」带出来的副作用，不是新增功能本身需要的计算**。


### 2.7 上表「≈44 → ≈67」怎么数出来的（2 worker / 单 attempt / 200 / 非流式 / 无 DP / 无 mesh）

逐调用点累加，`records()` 记作「1 次 ids get + 每 worker 1 次 record get」：

| 调用点 | 出厂 | 被量工作树 |
| --- | ---: | ---: |
| `record_http_request`：counter 1 + inflight 1 + `note_window` get/set 2 | 4 | 4 |
| `candidates_for`（选型）= `records()` 3 + 2×`is_available` | 7 | 7 + 2(hsel) + 2(load) = 11 |
| `policy_for` → `policy_hint_for_model` → `records()`（route_inference） | 0 | 3 |
| `policy_for` → `records()`（forward 内 select 前） | 0 | 3 |
| `policy_for` → `records()`（日志行 `route_type`） | 0 | 3 |
| `round_robin` 游标 incr | 1 | 1 |
| `hold_load` / `release_load` incr | 2 | 2 |
| `record_router_upstream_response` incr | 1 | 1 |
| `hb.record_status`：`cb_state` 8 get + `set_cb_counters`/`charge_cb` 2–3 + `url_for` 1 + `record_cb_outcome` 1 | 11 | 12 |
| `candidates_for`（日志行） | 7 | 11 |
| `append_request` incr+set+delete | 3 | 3 |
| `note_tokens`（in_tok + out_tok，est 为 0 提前返回） | 4 | 4 |
| `note_duration`（被量树新增） | 0 | 2 |
| `record_http_duration` → `observe` get+set | 2 | 2 |
| `record_router_duration` → `observe`（被量树新增） | 0 | 2 |
| `record_http_response` + `inflight_add(-1)` | 2 | 2 |
| **合计 shdict 往返** | **44** | **66（1.50x）** |

同一份表下 cjson.decode：出厂 = 请求体 1 + 响应体 1 + worker 记录 2 次 `records()` × 2 = **6**；
被量 = 请求体 1 + 响应体 1 + worker 记录 **5 次 `records()` × 2 = 10** = **12**。

两处差异全部落在「同一份 worker 记录被反复从共享字典取出来解码」这一件事上，
与 §3 的残差量级（113 µs @ C=64）方向一致。

### 2.2 §7 消融为什么几乎没量到请求日志（本轮新发现）

§7 只关了 `LMR_REQUEST_LOG_CAPACITY`，而 [observability.lua:716](../lualib/resty/luarouter/observability.lua:716)
`append_request` 第一件事就是 `log_enabled()` → 容量 0 时**立刻返回**，只省掉
`incr(head)` + 1 次 encode + 1 次 set + 1 次 delete（≈4 次 shdict）。

但真正的成本在它的**上游调用方** [router.lua:3691](../lualib/resty/luarouter/router.lua:3691)
`log_inference_request`，而它**没有被关**：

```
local pool = candidates_for(ngx.ctx.lr_model_query)   -- registry.records() → 解码 → is_available → 再若干 get
route_type = policy_for(model):policy_name(),         -- registry.records()（第 5 次）+ policy_hint_for_model
worker     = compact_url(worker.url),                 -- ngx.re.gsub
selected   = compact_url(worker.url),                 -- ngx.re.gsub（同一个 URL 再算一遍）
candidates = {compact_url(...) per worker}            -- 每 worker 1 次正则
record = { ...26 个字段... }                            -- 表字面量 + request_id()
```

并且 [finish_request:3785](../lualib/resty/luarouter/router.lua:3785)
的门是 `if ngx.ctx.lr_endpoint then` —— **只跟路由是否发生有关，跟日志开关无关**。
所以 `abl_log` 只回收了 9.5 µs/req（339.5→330.0，2.8%），完全在噪声边缘：
**「请求日志只值 6%」这个结论是被量代码里根本没关掉请求日志的行构建**。

同一行还顺带解释了 CORS 那部分为什么「关不掉」：`abl_both` 移除的是 server 级
`rewrite_by_lua_block`，而 [apply_response_headers:1986](../lualib/resty/luarouter/router.lua:1986)
在转发路径尾部**还调了一次 `cors_apply()`**，B6 又调了一次 —— 关掉 server 块只消掉 1/3 的 CORS 头写。

### 2.3 `policy_hint_for_model`：两次全量记录重建，只为读一个 label

[registry.lua:427](../lualib/resty/luarouter/registry.lua:427)。
它的唯一读者是 `policy_for`，而 `policy_for` 每请求被调 **2 次**
（[router.lua:2412](../lualib/resty/luarouter/router.lua:2412) 判断
`needs_request_text`，[router.lua:2082](../lualib/resty/luarouter/router.lua:2082) 选型），
日志行里还有第 3 次。**本夹具 2 个 worker 都没 advertise `labels.policy`**，
所以这 3 次 records() 全量解码后**必然返回 nil hint**、必然落回 `default_policy`。

出厂镜像的 `policy_for(_model)` 是一句惰性建单例（`latest_router.lua:48`），零 shdict、零解码。
**这是残差里最干净的一处纯实现回退**：语义（Rust 的 per-model policy）完全可以在
worker 注册/删除时算一次并缓存（hint 本来就是「该模型第一个 worker 决定、最后一个 worker 清除」）。

### 2.4 `config_store.current()` 没有正向缓存

[config_store.lua:559](../lualib/resty/luarouter/config_store.lua:559)
`read_snapshot()`：`SNAPSHOT_TTL = 0.5` 的 TTL **只保护文件路径**（`_file_cache`），
共享字典未命中且 `LMR_CONFIG_FILE` 未设时**直接 fall through 到 `cfg_from_env()`**，
`current()` 每请求 3 次（`resolve_alias` / `apply_effort_policy` / `apply_ctx_cap` 各一次）。

**成本比初看小得多**（本稿第一版把它写成每请求 42 次 PCRE，是错的，已修正）：
`env()` 在值不存在时先 `return nil`、**不走 `trim()` 的正则**，`parse_pairs(nil)` 也直接返回空表
（[config_store.lua:125](../lualib/resty/luarouter/config_store.lua:125)）。
未配置形态的真实成本 = 3 张 `new_cfg()`（共 18 个小表）+ 21 次 `os.getenv` + 3 次 `pcall` 外壳
≈ 每请求 45 次小对象分配，**零 PCRE**。
**生产形态（设了 `LMR_CONFIG_FILE`）反而更贵**：dict 命中路径没有 TTL 缓存，
每请求 1 次 shdict get + 整份快照 `cjson.decode`
（[config_store.lua:561](../lualib/resty/luarouter/config_store.lua:561)）。

对压测夹具是纯浪费；对生产（设了 `LMR_CONFIG_FILE`）**也仍然是每请求一次 shdict get +
一次整份快照 cjson.decode**（dict 命中路径没有 TTL 缓存，见同文件 561–565）。
出厂镜像的 router.lua **完全不 require config_store**（grep=0）→ 100% 新增。

### 2.5 上游连接池：不是代价，是收益（把它从嫌疑里排除）

每 attempt 新增 `pool_opts` + `pool_name` 各带一次 `split_url`
（[registry.lua:272,289](../lualib/resty/luarouter/registry.lua:272)），
`split_url` 内含 3 次 `ngx.re.match` → **9 次正则/attempt vs 出厂 3 次**。
但它换来的是 `setkeepalive` 取代出厂的 `sock:close()`（每请求省 1 次 close + 下次请求省 1 次
connect / accept / TCP 握手），而且 §6 实测：**流式上工作树比出厂快 15%、上游 mock CPU 从
179.7 核% 降到 87.1 核%**。非流式那一格 mock CPU 反而从 138.6 升到 96.6（更低）说明
省下的对端成本是真实存在的。**结论：连接池应为净负成本（即省钱），除非 §4 的 P5 把它证伪。**

### 2.6 已排除 / 不适用（父任务点名但数据不支持的候选）

| 候选 | 判定 | 依据 |
| --- | --- | --- |
| 每请求多次 `cjson.decode` | **部分命中，但来源不是 body** | 请求体只 decode 1 次、响应体 1 次（出厂相同）；多出来的是 **worker 记录 10 次**（§2.1） |
| audit 同步写盘 | **不适用** | `cp_audit` 仅控制面（[router.lua:551](../lualib/resty/luarouter/router.lua:551)），走 `ngx.log(ngx.NOTICE)`，推理路径不经过；无文件 I/O |
| otel 默认开启 | **不成立，且不进 1.54x** | `SMG_ENABLE_TRACE` 默认关；被量树 grep `otel` = **0 次**，该功能当时不存在；当前树即使全关仍有每请求 2 次布尔 + `on_log` 3 次 pcall（§5） |
| limit 的 shdict 往返 | **不成立** | 默认 `SMG_MAX_CONCURRENT_REQUESTS = -1` → `acquire()` 首行返回 true，**0 次 shdict**（[limit.lua:93](../lualib/resty/luarouter/limit.lua:93)）；`release()` 靠 ctx 标志位提前返回 |
| history 检查 | **不成立** | 历史/会话只在 `/v1/responses` 与 `/_ui/history`；本夹具走 `/v1/chat/completions`，一行 history 代码都不跑 |
| worker selection 的表重建 | **命中（即 2.1/2.3）** | 表重建发生在 `registry.records()`，发生在选型路径（`policy_for`）与日志路径，两处都量到 |
| `finish_request` 清理成本 | **部分命中** | `otel.finish` / `inflight_untrack` / `limit.release` 全为 O(1) 空转，可忽略；真正的新增是 `record_router_duration` 的第 2 次 `observe` |
| CORS + request log | **§7 已量：RPS 口径 6% / µs 口径 15.7%** | 见 §3 的口径冲突说明 |

---

## 3. 把 1.54x 摊开算（消融窗口原始数据可复算）

`/data/tmp/parity/perf-v2/results_v2_abl.json`，json C=64，40 行 err=0，逐轮 RPS 与 loadavg 均留档：

```
µs/req（中位数）:  lua 339.5   abl_log 330.0   abl_both 318.5   lua_ref(出厂) 205.5
总回退           = 339.5 - 205.5 = 134.0 µs   (1.65x，与 §7 的 RPS 口径 1.64x 一致)
已归因(日志+CORs) = 339.5 - 318.5 =  21.0 µs   = 总回退的 15.7%   ← RPS 口径只有 6%
未归因残差        = 318.5 - 205.5 = 113.0 µs   = 1.54x，即 §7 的那个数
```

**口径冲突要写清楚**：C=64 那一格 Lua 两侧 CPU 都钉在 400%（4 worker 饱和），所以
RPS 比值（1.06x）被饱和压扁了，**µs/req 口径（15.7%）才是每请求成本的真相**；
§7 用 RPS 说「只解释 6%」偏保守。并发越低这个差越大：C=1 时 `lua` 438.5 / `abl_both` 404.5 /
出厂 302.0 → CORS+日志解释 34.0 µs（占 33%），残差 102.5 µs（1.34x）。

残差的 113 µs 与 §2.1 的机制对得上：每请求多出的 ~21 次 shdict get + ~6 次 cjson.decode +
~4 次 cjson.encode + 3 次配置表重建 + 42 次 PCRE，在 LuaJIT 上就是这个量级。

**排序后的嫌疑榜**（区间 = 预期可回收的**残差**百分比，不是总回退百分比；两者相差 1.19 倍）：

| 排名 | 嫌疑 | 预期回收残差 | 判据（消融看什么） |
| --- | --- | ---: | --- |
| P1 | 请求日志**行构建**未随容量关闭（`log_inference_request`） | 25–40% | `LMR_REQUEST_LOG_RECORD=0`（新开关）相对 `abl_log` 再降的 µs/req |
| P2 | `records()` 每请求 5 次（`policy_hint_for_model` ×3 + `candidates_for` ×2） | 20–35% | 进程内带 TTL 的 records 缓存开关，单开关即可 |
| P3 | `config_store.current()` 无正向缓存 ×3（未配置形态 ≈45 次小对象分配/请求、零正则） | 3–10% | 请求内 memo + 进程级正缓存；生产形态（设了 `LMR_CONFIG_FILE`）预期回收更高 |
| P4 | metrics：`observe` ×2→×4、`note_window` ×5 的 decode/encode | 6–15% | `SMG_PROMETHEUS_DURATION_BUCKETS` 缩到 2 档 + duration 族开关 |
| P5 | 连接池的 Lua 侧正则（`split_url` 每 attempt 跑 3 遍 = 9 次 `ngx.re.match`） | −5%~+5% | 池名缓存（`kind,url` → opts 表 memoize） |
| P6 | `get_headers()` 每请求 8 次 —— **已撤销**：逐路径复核后出厂与工作树都是 3 次，非差异项 | ≈0% | 不必再测 |
| P7 | `store()` 每请求 3 次 `pcall(require)` | 1–3% | 进程级 memo require |
| P8 | 熔断记账（`charge_cb`/`cb_state` 10 get/req） | 1–4% | `SMG_DISABLE_CIRCUIT_BREAKER=1`（现成开关，但注意只跳过部分路径） |
| P9 | 上游连接建立本身（出厂 close/新建 vs 工作树 keepalive） | 净收益方向 | 池 idle TTL 极小值（`SMG_POOL_IDLE_TIMEOUT_SECS=1`）复现出厂行为 |
| P10 | klib.router 路由条数 27→~90 | <1% | 位图分派 O(1)，预期 0；作对照跑一次 |

### 3.1 残差随并发增长（这是把矛头指向共享内存而非「代码多跑了几行」的证据）

同一消融窗口的三档并发（µs/req，中位数）：

| 并发 | 被量工作树 | `abl_both`（关了 CORS+日志写入） | 出厂 | 残差绝对值 | 残差比值 | 总比值 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| C=1 | 438.5 | 404.5 | 302.0 | 102.5 µs | **1.34x** | 1.45x |
| C=16 | 370.0 | 355.0 | 268.0 | 87.0 µs | **1.32x** | 1.38x |
| C=64 | 339.5 | 318.5 | 205.5 | 113.0 µs | **1.55x** | 1.65x |

两侧绝对 µs/req 都随并发下降（固定开销被摊薄），但**工作树相对出厂的比值在 C=64 反弹到 1.55x**。
纯「代码行数/多几段计算」的回退应当是随并发**递减**的比值（出厂也是同一段代码在高并发下更省），
比值反弹意味着新增成本里含**随并发放大的成分**：
共享字典是跨进程自旋锁保护的哈希表，往返次数 ×1.5 在 4 worker 争抢下会被放大；
同时每请求多出的 ~30 个小对象会抬高 LuaJIT GC 频率，GC 成本同样随分配率而非请求数放大。

**这条观察同时给出了一个必须做的判别实验**（排进 §4 的 R1b）：
固定 C=16、扫 `worker_processes` = 1 / 2 / 4 / 8。若比值随 worker 数上升 → 争抢主导（P2/P4 优先修）；
若比值恒定 → 纯 CPU 主导（P1/P3 优先修）。这个实验比单项开关更便宜，且能决定修复顺序。

---

## 4. 负载消融实验计划（只写不跑）

### 4.0 前提与硬约束

1. **必须在当前工作树上重取基线**（`9d890193…`），不能沿用 §7 的比值 —— §5 说明原因。
2. **C=64 那格的 RPS 不可用作判据**：4 worker 恒钉 400%，RPS 被 worker 数饱和压扁
   （同一现象在 §3、§6 各出现一次）。判据一律用 **CPU 时间差**（`/proc` utime+stime 差 ÷ 请求数）。
   建议主档 **C=16（CPU ≈355%，未饱和，信号最干净）** + 对照档 **C=64（饱和 + µs/req）** +
   **C=1（延迟敏感，验证固定开销）**。
3. **沿用 `res_v2_abl.py` 的交替法**：rep1 正序、rep2 反序，每格 15 s ×2 rep，
   `mockpair` 直连基线进每一轮（用来确认同窗口未漂移：直连 RPS 相对上一格变化 >5% 则整轮作废）。
4. 承 v2 §1 的教训：**每格记录 before/after loadavg 与 mock CPU**；本机 load1 在 17–29 漂移。
5. 所有容器 `--network host`、`NGINX_WORKER_PROCESSES=4`、`SMG_POLICY=round_robin`、
   mock 复用 `mock_fast.py --stream-batch`（新端口段，不与 557xx 复用）。

### 4.1 需要的开关（当前只有 4 个现成的，其余要新加）

| 开关 | 状态 | 关什么 |
| --- | --- | --- |
| `LMR_REQUEST_LOG_CAPACITY=0` | ✅ 现成 | 只关 `append_request` 的写入，**不关行构建**（§2.2） |
| `SMG_DISABLE_CIRCUIT_BREAKER=1` | ✅ 现成 | 熔断记账（注意 `record_outcome` 首行即返回，能整段跳过） |
| `SMG_PROMETHEUS_DURATION_BUCKETS=0.1,1,10` | ✅ 现成 | 把 20 桶压到 3 档，缩小 `observe` 的 decode/encode 体积 |
| `SMG_POOL_IDLE_TIMEOUT_SECS=1` / `SMG_POOL_MAX_IDLE_PER_HOST=1` | ✅ 现成 | 逼近出厂「每请求新建连接」的行为（P9 的反证） |
| `LMR_REQUEST_LOG_RECORD=0` | ❌ 需新增 | 在 `finish_request` 的 `if ngx.ctx.lr_endpoint` 门之前短路整个 `log_inference_request` |
| `LR_WORKER_RECORDS_TTL_MS=<n>` | ❌ 需新增 | `records()` 进程内缓存（含派生 hint）；0 = 关闭缓存 |
| `LR_RUNTIME_CONFIG_MEMO=0/1` | ❌ 需新增 | `config_store.current()` 正向缓存 + 请求内 memo；并让 `store()` 只 require 一次。**建议同时跑一格设了 `LMR_CONFIG_FILE` 的生产形态** —— 未配置与已配置的成本形态完全不同（见 2.4） |
| `LR_METRICS_LEVEL=basic\|full\|off` | ❌ 需新增 | 分级：off = 全部 metrics no-op；basic = 只留 counter、去掉 histogram / 滑窗 |
| `LR_HOT_PROFILE=1` | ❌ 需新增 | 阶段累计 CPU（`clock()`）写入 shdict，`/_ui/prof` 出 —— 只在最后一轮用，本身有成本 |

**开关的实现要求**：必须能在**不改变响应字节**的前提下切换（回归契约不能因此挂），
每个开关都要在 `final_gates.sh` 之外单独跑一次 `curl` 差分确认响应体一致。

### 4.2 轮次与判据

| 轮 | 目标 | 开关组合 | 判据 / 预期 |
| --- | --- | --- | --- |
| **R0 基线重取**（≈35 min） | 确认当前树相对出厂仍是 1.5x，且工作树自身可复现 | `lua_now` vs `lua_ref`（出厂），C=1/16/64，2 rep | 复现出 `µs/req(当前树) / µs/req(出厂) ∈ [1.4, 1.8]`；否则先解释漂移再做归因。同时给出「当前树 − 被量树」的差 = §5 的新增成本 |
| **R1b worker 数扫描**（约 25 min，判别力最高的一步） | 分辨残差是「共享字典跨进程争抢」还是「纯 CPU」 | 固定 C=16，`NGINX_WORKER_PROCESSES` = 1 / 2 / 4 / 8，各跑 `lua_now` + `lua_ref` | 看 `µs/req(工作树)/µs/req(出厂)` 的比值随 worker 数的斜率：上升 → 争抢主导，P2/P4 先修；平坦 → 纯 CPU 主导，P1/P3 先修（依据见 §3.1） |
| **R1 现成开关先扫一遍**（约 40 min） | 不动代码，先吃掉能吃的信息 | R0 两目标 + `abl_logcap`（现成日志关）+ `abl_metrics3`（桶缩到 3 档）+ `abl_no_cb`（关熔断）+ `abl_pool_off`（idle=1） | 每项的 `Δµs/req`；预期 metrics 与熔断各 <5%，池为 0 或负 |
| **R2 单开关逐项定责**（≈90 min） | 主实验 | 基线 + 4 个新开关**各单开一个**：`no_logrow` / `records_ttl` / `cfg_memo` / `metrics_off` | 每项 ≥8% 残差才算命中；<3% 判为噪声并记录 |
| **R3 累加与组合**（≈50 min） | 验证可加性、找交互 | 基线 → +P1 → +P1+P2 → +全部 4 个；`all_off` 与 `lua_ref` 直接对拍 | 累加值 ≥ 各项之和的 80% 视为无显著交互；`all_off` 若仍未逼近 `lua_ref`，说明残差还有未列项 → 转 R4 |
| **R4 定位未列项**（≈30 min） | 收口 | `LR_HOT_PROFILE=1` + LuaJIT `-jp` 采样（镜像内 luajit 可用，`perf` 本机未装） | top-10 自函数；与 R3 剩余差值对账 |
| **R5 修复复测**（≈40 min） | 确认修复而不是只确认归因 | 只开已定责项的修复，跑 R2 同矩阵 + 契约套件 | 目标：残差 ≤ 25%，且 C=64 的 RPS 相对当前树 +15% 以上；契约 err=0 |

**每轮的停止条件**：`mockpair` 漂移 >5%、任一格 err>0.5%、或 CPU 未打满却出现 RPS 反序 →
该轮标记 contaminated 重跑（沿用 §2 D1/D2/D3 的处理法：不静默丢弃，改名保留）。

**总时长**：35+25+40+90+50+30+40 ≈ **310 min（约 5 h10 m）**；含容器重建与开关落地等待，
建议排 **6 h 窗口**（R2/R3 可复用同一批容器，只换 `-e`）。
**若只能排一个短窗口**，优先 R0 + **R1b**（约 60 min）：worker 数斜率一个数字就能决定
「修共享字典缓存」还是「修冗余计算」，性价比高于逐项开关。

### 4.3 交叉验证（不靠单一口径）

- **CPU 时间口径**（主）：`Δ(utime+stime) / 请求数`，同 §1 口径。
- **µs/req**（辅助）：直接读 `calc_v2.txt` 的 `u` 字段，和 CPU 口径必须同向。
- **shdict 往返计数**（机制验证）：`lr_stats` / `lr_workers` 的 key 数不应变，但
  `/_ui/prof` 的阶段累计时间必须和开关命中项一致 —— 如果开关命中了 CPU 却没动阶段时间，判为误归因。
- **契约不破**：每轮最后跑一次 `final_gates.sh`（本轮**不修改**它），err=0 + 响应字节一致是硬门。

---

## 5. 当前工作树相对「被量工作树」又新加了什么（这些不在 1.54x 里）

`abl/base_resty`（≈被量）→ 当前工作树的 diff，按是否进热路径分：

| 新增 | 热路径成本（otel/mesh 全关时） | 归属 |
| --- | --- | --- |
| otel 全链接线（`begin_trace` / `echo_request_traceparent` / `otel.inject` / `otel_upstream_child` / `otel.finish`） | 每请求 2 次 `otel.is_enabled()` + `apply_response_headers` 内 1 次 `otel.current()` + 1 次 `os.getenv("SMG_TRACE_UPSTREAM_CHILD")`；**全关时不建 span** | 新成本，量级小（预期 <3%） |
| **in-flight 年龄追踪**（`inflight_track` 在 `record_http_request` 内） | `d:add` + 1 次 `math.random` ×2 + token 字符串拼接；**默认开**（`LR_INFLIGHT_SAMPLE_SECS` 默认 20 s） → 每请求 1 次 shdict add + `untrack` 1 get + 1 delete | 新成本，**必须进 R0 的差值里** |
| JWT 控制面闸门（`jwt_control_gate`） | 只在控制面，推理面 0 | 无关 |
| `patch_response_metadata` / `top_member_span` / `set_top_field` 的字节级 JSON 走查 | 只在 `/v1/responses`（本夹具 0）；**真实 Responses 流量下是 O(body) 逐字节扫描**，另计 | 与 chat 路径无关 |
| SSE `accumulator_*`（`/v1/responses` 流式 store） | 本夹具 0 | 无关 |
| `router_session_key` + `sha256_hex` | 夹具里 `#messages<2` → 早退；**真实多轮请求会跑 1 次 sha256 + 24 次 `string.format`** | 新成本，**只在生产形态可见**，需另设夹具量 |
| `log_inference_request` 多 3 个字段（`requested_effort` / `effort` / `session`） | 表字面量 +2 项 + 1 次 `policy_for` | 归入 P1 |
| `init.on_log` 多 3 次 `pcall(require)` + 2 次幂等空转 | 每请求 | 归入 P1 附近 |
| `service_discovery` / `mesh` / `history` / `tokenizer` / `parse` 的 require | 仅 init 阶段，每 worker 一次 | 无关（除非冷启动/reload） |

**推论**：当前树相对出厂的比值应当 ≥1.54x，R0 会给出这个数。**P1–P8 的归因结构不变，
只是分子变大**；同时 R0 必须包含一个 `LR_INFLIGHT_SAMPLE_SECS=0` 的格子，
把年龄追踪从新基线里剥出来。

---

## 6. 语义必需（Rust 同样存在）vs Lua 实现引入（可优化）

**语义必需 —— 出厂镜像也在跑，Rust 也在跑，不属于本次回退，也不该被「优化掉」**：

- `json_decode(request body)` ×1、`json_decode(response body)` ×1（Rust 用 `serde_json` 反序列化，等价）
- `rewrite_model` 的 PCRE + body 重拼（Rust 在解码后的 `Map` 上改 `payload["model"]`，语义相同、实现更省）
- `hold_load` / `release_load` / 熔断记账 / 健康位（Rust 是 `DashMap` + `AtomicUsize`，同样每请求一次）
- 三层 metrics 与请求日志行本身（Rust `smg_*` 族 + `RequestLogStore` 都在写）
- `limit` 队列（Rust `TokenGuard`）；本夹具下两侧都未启用
- 上游连接池（Rust reqwest 也有池；**工作树是向 Rust 对齐，不是新增**）

**Lua 实现引入 —— 可优化，且是残差的来源**：

| 项 | 为什么是实现问题 | 建议实现 |
| --- | --- | --- |
| `records()` 每请求 5 次全量解码 | Rust 用 `Arc<Worker>` 常驻内存 + `DashMap`，**不存在「每请求重新解码记录」这件事** | worker 表在进程内缓存（写路径 bump 版本），hint 在 add/remove 时算一次 |
| 日志行构建不随容量关闭 | 纯接线遗漏，与契约无关 | `log_inference_request` 入口加 `log_enabled()` 门 |
| `config_store.current()` 无正向缓存 | Rust 是 `RwLock<RuntimeConfig>` 常驻；这里每次都重建 | 正缓存 + 写路径失效（写侧本来就有 `_file_cache = nil`） |
| `observe()` 每观测 1 次 decode+encode 整块直方图 | Rust 是原子桶数组，O(1) 增量 | shdict 存裸字符串 / `incr` 每桶独立 key；或退化为进程内聚合、由采样器写共享 |
| `compact_url` 同一 URL 每请求算 2–4 次正则 | 纯冗余 | worker 记录里存一次 `short_url` |
| ~~`get_headers()` 每请求 3 张表~~ | 复核后**不是差异项**（出厂同为 3 次），已从嫌疑榜移除 | —（只在生产 header 很多时值得 memo） |
| `store()` / `on_log` 的每请求 `pcall(require)` | require 内部已有 package.loaded 短路，pcall 才是白交的成本 | 首次解析后存 upvalue |
| otel / in-flight / JWT / history 全部在推理路径留了恒真/恒假分支 | 默认关的功能不该每请求过一遍函数调用 | 一次性把 no-op 函数替换掉（在 init 阶段按开关注入空实现） |

---

## 7. 证据与可复算性

- 原始数据：`/data/tmp/parity/perf-v2/results_v2_abl.json`（40 行）、`results_v2_ab.json`（24 行）、
  `results_v2.json`、折算结果 `calc_v2.txt` / `calc_mock_us.txt`；容器→端口映射 `ports.json`。
- 三份代码快照：出厂 = 本轮从 `lua-router:latest` `docker save` 解出
  （`/data/tmp/lua-router-factory-inspect/layers/af2ea5d3…/usr/local/openresty/site/lualib/resty/luarouter/`，
  实测 `router.lua` md5 `1d48f333…`，与 §10 记载一致）；
  被量 = `/data/tmp/parity/perf-v2/ref/integration_router.lua`（md5 `5b60aae9…`）+
  `abl/base_resty/luarouter/`（registry `cceb302b…` = 当前工作树 registry，故 registry 侧计数可直接沿用）；
  当前 = 仓库工作树。
- 关键计数复核命令（只读）：
  `grep -c "registry.records()" <三份 router.lua>`、
  `grep -c "otel\." <ref/integration_router.lua>`（=0，证明 1.54x 与 otel 无关）、
  `grep -n "log_enabled\|append_request" lualib/resty/luarouter/observability.lua`、
  `grep -n "SNAPSHOT_TTL\|_file_cache" lualib/resty/luarouter/config_store.lua`。
- 本机 `perf` 未安装（`which perf` 为空、`/proc/sys/kernel/perf_event_paranoid = 4`），R4 只能走
  LuaJIT 自带 `-jp`（`docker run --rm --entrypoint /usr/local/openresty/luajit/bin/luajit authz:latest -v`
  确认可用）或 `LR_HOT_PROFILE` 打点。

## 8. 不确定性与可能推翻本结论的因素

1. **区间是机制推导，不是测量**。P1/P2 的 25–40% / 20–35% 来自「每请求 shdict 往返与 cjson 次数的增量比例」
   对 113 µs 的线性分摊，没有实测支撑 —— 这正是 R2 要证伪的东西。任何一项实测 <3% 都应视为我的归因偏了。
2. **worker 数效应**：2 个 worker 时 `records()` 的代价被压到最小；**生产 8–16 worker 时 P2 会被放大**
   （成本线性于 worker 数）。区间按 2 worker 给，生产值可能更高。
3. **C=16 未饱和但仍有同机噪声**：§10 记录单格 load1 before/after 可差 ±1.5，
   ±5% 以内的单项差值不足以定论，需要 2 rep 反向后取中位数。
4. **夹具偏小**：body ~55 B、响应 ~300 B。真实请求体下 `json_decode` 与 `rewrite_model` 的正则
   占比会上升，P1/P2/P3 的**相对**占比会下降 —— 建议 R3 加一格 pad（大 body）复测。
5. **R0 之前不能确定当前树的比值**：§5 列的 in-flight 追踪、`router_session_key` 等
   在这个夹具下大多早退，实际新增可能只有 2–4%，也可能因 `sha256` 分支未覆盖而被低估。
