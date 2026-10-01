# lua-router / core 实现说明（agent: worker_core）

对应 Rust 参照实现：`gateway/src/core/{worker,worker_registry,circuit_breaker,
retry,worker_service,job_queue}.rs`、`gateway/src/routers/{header_utils,error,mod}.rs`
+ `routers/http/router.rs`、`gateway/src/observability/{metrics,request_log}.rs`、
`gateway/src/{server,main,middleware}.rs`、`~/.cargo/.../openai-protocol-1.0.0/src/*`。

> **状态**：仍有效，但 §4.2 / §4.4 / §5.1 / §5.2 / §5.3 描述的缺口已在后续轮次闭合，以
> [feature-gap.md](feature-gap.md) 为准。
> **日期**：写作 2026-09-29（初版），状态复核 2026-09-30（UTC）。
> **证据强度**：B（写作时实跑；本轮只复核了文件清单与 §6 自测记录中的单测计数）。
>
> 写作时的事实已过期处（正文保留原样以便追溯）：
> - §5.1「聊天管线契约未实现」→ **已实现**：`router.do_chat` / `do_completion`（router.lua:1399/1404）
>   走 `ui_pipeline`，`POST /_ui/v1/chat/completions` 实测 200，契约 `ui_fixed` 有 3 条硬断言钉住。
> - §5.2「4 个新策略没进分发」→ **已接线**：`config.lua` 的 `POLICIES` 含全部 8 个值，
>   `policy.lua` 的 `MODULE_SPECS` 挂 cache_aware / bucket / consistent_hashing / prefix_hash，
>   快照读写与淘汰定时器同在 policy.lua。
> - §4.4「虚拟别名 / effort / ctx cap 未接进推理面」→ **已接线**：`resolve_alias` +
>   `apply_effort_policy` + `apply_ctx_cap` 都在 `route_inference` 里（`/generate` 按 Rust 跳过）。
>   但 ctx cap 有一条**新 bug 未修**，见 feature-gap.md §5.1。
> - §5.3「模板默认 auto 与 cache_aware 冲突」→ **已处理**：入口脚本在未显式指定且
>   `SMG_POLICY=cache_aware` 时把 worker 数收成 1。
> - §4.2 的指标覆盖数（20 / 48）→ 现为 **27 个同名家族 / Rust 49**，缺的 22 个全表在
>   feature-gap.md §3.5。
> - §5.4 的 `config_store.re_split` 崩溃 → **已修**（改用 `ngx.re.find` 取位置），
>   由 probes 轮次 `[re_split]` 4 项覆盖。
> - §6 的「`/klib/load` 9 个模块全 OK」是 core 初版的清单，现该端点枚举 **19 个模块**
>   （补进了 ui / props / config_store / hash 与 5 个 policies 模块），2026-09-30 实测 19 行全 OK。

## 0. 前置说明：ARCHITECTURE.md 缺失

任务书要求先读 `doc/ARCHITECTURE.md`。该文件在本 agent 整个执行期间
不存在（doc/ 目录当时为空，多次轮询无果）。因此「契约」全部按上面的 Rust 源码
逐项对照实现，共享字典、环境变量默认值、响应形状与头白名单以 Rust 行为为准。
若 ARCHITECTURE.md 后续落库且与本实现冲突，以它为准，需要复核的点见 §4。

## 1. 文件清单（本 agent 所有）

| 文件 | 内容 |
|---|---|
| `conf/nginx.conf.template` | envsubst 模板：worker/事件/http 骨架、5+1 个 shared dict、init/init_worker/log 阶段、`location /` → router、`${SERVER_EXTRA}`/`${HTTP_EXTRA}`/`${METRICS_EXTRA}` 注入点 |
| `conf/lua-router.conf` | 裸 conf（无占位符），同一套配置的直读版本，用于不经入口脚本的验证/最小部署 |
| `conf/ui.conf`、`lualib/resty/luarouter/{ui,props,config_store}.lua`、`policies/{cache_aware,consistent_hashing,prefix_hash,bucket,tree,utils}.lua`、`hash.lua`、`test/unit/*` | **UI / 策略 / 哈希 agent 的文件，本 agent 未修改**（接线需求见 §3） |
| `docker-entrypoint.sh` | env 解析与校验 → envsubst 渲染 → `openresty -t` → exec；`ui.conf` 存在才 include；可选 `SMG_METRICS_PORT` 独立端口 |
| `Dockerfile` | `FROM authz:latest AS final`，COPY lualib / 模板 / entrypoint / ui.conf / `ui/`→`/usr/local/share/llama-ui`，构建期跑 entrypoint 的 `-t` gate |
| `lualib/resty/luarouter/init.lua` | `init()`（含 `config_store.capture_env()`）/ `worker_init()`（播种 worker、起健康巡检与策略淘汰定时器）/ `on_log()`（归还泄漏的 load 计数） |
| `lualib/resty/luarouter/config.lua` | `SMG_*` / `LR_*` / `LMR_*` 全量 env 解析、默认值、`validate()` 收敛 |
| `lualib/resty/luarouter/registry.lua` | worker 注册表（lr_workers）：sha224→UUID 形式 id、url 归一化、add/remove/get/list/info、`is_available`（含 open→half_open 翻转）、load 计数、熔断与健康计数、url↔id 双向键、job 状态、`discover` 元数据、`bootstrap` |
| `lualib/resty/luarouter/hb.lua` | cosocket 手写 HTTP GET、周期健康巡检、阈值翻转与计数复位、熔断记账（4xx 不记罚，408/429 例外）、`is_retryable_status` |
| `lualib/resty/luarouter/policy.lua` | 策略框架 `new/select/on_add/on_remove/start_eviction` + `random`/`round_robin`/`power_of_two`/`manual` 四种（manual 走 lr_policy 粘性映射 + 淘汰定时器） |
| `lualib/resty/luarouter/router.lua` | klib.router 组织全部端点：推理面（读 body→抽 model+text→选 worker→改写 model→cosocket 转发→流式直写→重试/退避→头白名单）、控制面 workers/admin、公开面 health/readiness/liveness/models/server_info/metrics、`/ha/*` 固定 503 |
| `lualib/resty/luarouter/observability.lua` | lr_request_log 环形缓冲 + seq、lr_stats 计数器/仪表盘/直方图与 200ms 滑窗、`prometheus_text()`（smg_* 同名指标）、`handle_logs/handle_stats/handle_backends/handle_logs_stream`（impl-ui.md §6 的桥契约） |
| `test/conf/nginx-lua-router.conf` | 独立测试 conf：`listen 8080`，`lua_package_path` 指向 `/repo/lualib` 与 `/repo/../lualib`，`/klib/load` 逐模块加载探针 + `/probe/{worker-id,rewrite-model,extract-text,headers,env,config}` |
| `test/mock_llm_worker.py` | 纯标准库多线程 mock worker：`/health /v1/models /server_info /get_server_info /model_info /get_model_info /props /metrics /identity /state /reset`，`/v1/{chat/completions,completions,embeddings,rerank,classify,responses}`，SSE 5 chunk + `[DONE]`，`FAIL_MODE`/`LATENCY_MS`/`CHUNK_MS`/`--model` |
| `doc/impl-core.md` | 本文档 |

## 2. 关键决策

1. **不 require `resty.http`**：镜像里没有（uv.lock 的 resty-http 不在 authz 镜像内），
   转发与健康检查全部用 `ngx.socket.tcp` 手写 HTTP/1.1，含 Content-Length 与
   chunked 两种读体路径。
2. **worker id**：`sha224(url)` hex 取前 32 位，按 8-4-4-4-12 排成 UUID 外观。
   不要求与 smg 的 uuid 一致，只要求同 URL 稳定；`remove` 会同时删掉
   `url:<url>→id` 与 `u:<id>→url`，所以删掉后同 URL 可重新注册。
3. **POST 的 per-worker 健康参数被忽略**：照抄 Rust `build_health_config`
   ——它只读 `app_context.router_config`，因此请求体里的
   `health_failure_threshold` 等一律不生效，记录里存的是路由默认值。
4. **可用性判定只有一处**：`registry.is_available()` = 健康 且 熔断不为 open，
   并且 open 在超过 `cb_timeout_duration_secs` 后由它翻成 half_open。
   Rust 的 `is_available()` 会调 `circuit_breaker().can_execute()`，而
   `can_execute()` 内部做状态检查，所以语义一致；镜像里没有 shdict `cas`
   （实测 `type(d.cas) == nil`，require `resty.core` 后仍为 nil），
   单写者翻转借用 registry 的 `resty.lock`。
5. **熔断数值的 wire 编码跟 Rust 对齐**：`closed=0 / open=1 / half_open=2`
   （`core/circuit_breaker.rs` 的 STATE_*），Lua 侧一律用常量比较，
   不依赖数字大小顺序。
6. **转发头白名单**：请求向 `authorization, x-request-id, x-correlation-id,
   traceparent, tracestate, x-smg-routing-key, x-smg-target-worker` 加
   `x-request-id-*` 前缀；响应向删 hop-by-hop 与 `content-encoding`、`host`，
   另外删 `content-length`（我们自己重新分帧）。上游统一发
   `Accept-Encoding: identity`，字节原样透传。
7. **流式**：`ngx.ctx.lr_worker` 存目标 worker，状态行与头先落，再
   `body_filter` 直通（`ngx.header.X-Accel-Buffering` 不改、不缓冲），
   content 阶段什么都不做，读循环 `res:read_body` 分块 `ngx.print` + `ngx.flush`；
   熔断记账在流真正结束时才做，不看状态行。
8. **重试**：`is_retryable_status` = 408/429/500/502/503/504；退避
   `initial*mult^attempt` 上限 `max_backoff`，带 ±jitter；
   `SMG_RETRY_MAX_RETRIES=N` 表示 **N 次总尝试**（与 Rust `max = config.max_retries`
   一致，实测 mock 侧正好看到 5 次 POST），最后一次仍是可重试码时打
   `smg_worker_retries_exhausted_total`。
9. **文本抽取**：messages 顺序取 system/user/tool/developer 的 `content`，
   assistant 的 `content` + `reasoning_content`，function 的 `content`；
   数组 content 只拼 `{type:"text"}.text`；片段间单空格；无文本返回 nil。
   completions 用 `prompt`（数组空格 join）。
10. **请求头/错误响应**：`X-SMG-Error-Code` 与 `{"error":{"type","code","message"}}`
    同 Rust `routers/error.rs`；`type` 用 `canonical_reason()` 文案。
    request id 前缀按路径选（chatcmpl-/cmpl-/gnt-/resp-/req-）+ 24 位字母数字。
11. **`/_ui/logs*` 与 `/_ui/stats` 落在 observability**：impl-ui.md §6 规定
    ui.lua 桥接调用 `observability.handle_{logs,logs_stream,backends,stats}`
    这四个名字，因此它们必须在 observability.lua 里存在（早先只有数据函数
    `snapshot/stats`，桥拿不到 ⇒ 全量 503，现已补齐）。SSE 用轮询
    lr_request_log 序列号实现（没有跨 worker 的 broadcast channel），
    15s `: ping`，落后就跳到最旧保留记录。
12. **`LMR_REQUEST_LOG_CAPACITY=0` = 关闭请求日志**：与 Rust 的
    `capacity > 0` 才 install store 一致，此时四个 `/_ui/logs*`/`/_ui/stats`
    返回 503 `{"error":"request log not enabled"}`。
13. **正则一律 `ngx.re` + `"jo"`**，含 `]]` 的模式用 `[==[ ]==]` 长字符串界定。
14. **`math.randomseed` 放在 `worker_init`**（fork 之后、按 pid 混入），
    否则 init_by_lua 阶段播种会让所有 worker 拿到同一条随机序列，
    random / power_of_two 会同步选同一个 worker。

## 3. 与 UI / 策略 agent 的接线（core 侧已做的部分）

`impl-ui.md` §1 明确要求 core 做四件事，全部已落：

1. `init_by_lua` 里调一次 `config_store.capture_env()` —— 在
   `init.lua:_M.init()` 内以 pcall 完成。**实测确认**：worker 请求阶段
   `os.getenv("LMR_VIRTUAL_MODELS")` 与 `os.getenv("HOME")` 都是 nil
   （`/probe/env` 返回 `{"cached_before":true}`，即 init 已抓过快照）。
2. 声明 `lua_shared_dict luarouter_config 1m` —— template 与测试 conf 都加了。
3. `include .../conf/lua-router/ui.conf` —— 由 entrypoint 条件注入
   `${SERVER_EXTRA}`（`LR_UI_CONF` 可改路径，`LR_UI_CONF=off` 关闭）；
   裸 `conf/lua-router.conf` 不写这条（静态配置无法条件 include，写了会让
   `openresty -t` 在没有该文件时失败）。
4. `COPY ui/ /usr/local/share/llama-ui` —— Dockerfile 已加（9.8MB / 70 项）。

尚未由 core 提供的（见 §5）：`resty.luarouter.api`（或 `router.do_chat`
/`do_completion`）聊天管线契约。

## 4. 与 Rust / 契约的偏差

1. **ARCHITECTURE.md 缺失**（§0），环境变量表与字典尺寸按 Rust 默认值取。
2. **`smg_*` 指标只覆盖 20 个家族**（Rust 有 48 个）。缺的是本实现没有对应
   子系统的：`smg_db_*`、`smg_mcp_*`、`smg_discovery_*`、
   `smg_{consistent_hashing,prefix_hash,manual}_policy_branch_total`（除 manual
   已实现）、`smg_router_{request_,generation_,stage_,ttft,tpot}_*`（gRPC 面）、
   `smg_http_{connections_active,rate_limit_total,inflight_request_age_count}`、
   `smg_worker_{connections_active,routing_keys_active}`。
   额外多一个 Rust 没有的 `smg_http_inflight_requests`。
3. **`smg_worker_retry_backoff_seconds` 的桶**沿用全局 duration 桶，
   Rust 用 metrics 库默认桶；标签已改成 Rust 的 `attempt` 单标签。
4. **虚拟别名解析（`config_store.resolve_model`）尚未接进推理面**，
   `apply_effort_policy` / `apply_ctx_cap` 同理。目前推理面只做
   「把 body 里的 model 改写成选中 worker 的真实 model_id」，
   `LMR_VIRTUAL_MODELS=alias:real` 还不会把 alias 折到 real（这是 §5 的
   api 管线契约的一部分）。
5. **worker 元数据发现**用 `/model_info` + `/server_info`（llama.cpp 风格），
   没有时退回 OpenAI `/v1/models`；不查 sglang `/get_server_info` 的 DP 展开，
   也不做 dp_size>1 的多 worker 拆分。
6. **prometheus 文本的 histogram 是 cumulative 输出**，与 Rust 的
   `buckets` 累计语义一致；`+Inf` 用 `n` 直填。标签值做了最小长度/字符集
   约束（method/path/model 等），path 标签取自路由表而非原始 URI，
   避免高基数。
7. **`/ha/*` 全部固定 503** `{"error":"mesh not enabled"}`，含通过 404 兜底
   命中 `/ha/...` 深路径的情况（按任务书要求，mesh 不实现）。
8. **不实现**：gRPC、PD 分离、mesh/HA、wasm、tokenizers、K8s service
   discovery（任务书明确排除）。
9. 与任务的 `test/conf` 说明一致：监听 `8080`，`-p 127.0.0.1::8080` 可直接
   映射；跑测试容器需要 `--entrypoint openresty` 覆盖 authz 自带 entrypoint。

## 5. 已知未完成 / 需要决策的项

1. **聊天管线契约未实现**：`ui.lua` 找
   `resty.luarouter.api.chat/completion` → `router.do_chat/do_completion`
   → `LMR_TEST_PIPELINE`，三者都没有 ⇒ `POST /_ui/v1/{chat,completions}` 返回
   503 `invalid chat request: router pipeline not available`（实测）。
   `inference_handler` 目前是「读 body + forward」的内联形态，需要把
   body→(resolve alias)→(effort/ctx policy)→select→forward 抽成可复用入口。
   归属：core，但等 §4.4 的 effort/ctx 语义定稿后一起做更划算。
2. **策略 agent 的 4 个新策略没进分发**：`policy.lua` 的
   `policies` 表只有 `random/round_robin/power_of_two/manual`，
   `config.lua` 的 `POLICIES` 白名单同样只有这 4 个，因此
   `SMG_POLICY=cache_aware|consistent_hashing|prefix_hash|bucket` 会被
   归一成 `round_robin`。`policies/*.lua` 自带单测（tree 67、policies 118 全绿）
   但没被 core 调用。接线契约在 impl-policies.md §「快照如何接到 lr_policy」：
   `init_worker` 里 `policy:init_workers(workers)` + 读 `snapshot:<instance_id>`
   回放，淘汰定时器里 `evict_all()` → `encode_snapshot(3MB)` → 写 lr_policy。
   **这条接线需要 owner 确认由谁做（core 的 policy.lua 框架 vs 策略 agent 的适配层）。**
3. **`worker_processes auto` 与 cache_aware 的冲突**：impl-policies.md 自己
   建议 `worker_processes 1`（每进程一棵树，N 个 worker = N 份近似树的平均，
   亲和命中衰减）。core 目前模板默认 `auto`（本机会开很多 worker）。
   建议要么模板默认改 1，要么等 §5.2 接线时把快照/共享化做掉。
4. **`config_store.lua` 有崩溃 bug（UI agent 文件，本 agent 未改）**：
   `re_split`（第 60-72 行）假设 `ngx.re.gmatch` 的每个匹配是带 `start`/`stop`
   的 table，实际这个构建在无捕获组时返回的是**纯字符串**，`m.start` 为 nil。
   实测：`LMR_VIRTUAL_MODELS=alias-a:alpha`（单个 pair，正则不命中）时
   `/_ui/config` 200；`alias-a:alpha,alias-b:beta`（含分隔符）时 **500**
   `attempt to perform arithmetic on field 'start' (a nil value)`，
   调用链 `parse_pairs → env_defaults → current → document → handle_config_get`。
   影响面：所有用 `LMR_EFFORT_MAP`/`LMR_MODEL_CTX`/`LMR_MODEL_EFFORT`/
   `LMR_MODEL_EFFORT_MAP`/`LMR_VIRTUAL_MODELS`/`LMR_MODEL_MODALITIES` 多值
   配置的场合。修法是把 `re_split` 换成 `ngx.re.find(..., "jo")` 拿位置，
   或者直接用捕获组。已实测 `m` 就是分隔符字符串本身。
5. `smg_manual_policy_cache_entries` 依赖淘汰定时器发布；策略淘汰间隔
   `SMG_EVICTION_INTERVAL_SECS` 默认 120s，所以进程刚起的前两分钟该 gauge 缺失。
6. `LR_METRICS_PORT` 渲染的独立 metrics server 只挂了 `/metrics` 与 `/health`，
   没有跟主监听共用 `location /` 路由表（这是刻意的最小实现）。

## 6. 自测记录（全部在本机 authz:latest / lua-router:latest 实跑）

**语法 gate（两个 conf 都过）**

```
$ docker run --rm -v $PWD:/repo:ro --entrypoint openresty authz:latest \
    -t -p /usr/local/openresty/nginx/ -c /repo/test/conf/nginx-lua-router.conf
nginx: the configuration file /repo/test/conf/nginx-lua-router.conf syntax is ok
nginx: configuration file /repo/test/conf/nginx-lua-router.conf test is successful

$ docker run --rm -v $PWD:/repo:ro --entrypoint openresty authz:latest \
    -t -p /usr/local/openresty/nginx/ -c /repo/conf/lua-router.conf
nginx: the configuration file /repo/conf/lua-router.conf syntax is ok
nginx: configuration file /repo/conf/lua-router.conf test is successful
```

`ui.conf` 能否被 include 也单独验过（临时 conf + `include /repo/conf/ui.conf;`）：syntax ok。
`docker build` 的构建期 gate 实际抓到过多个真 bug（entrypoint 路径、cas 缺失等）。
逐模块加载：`/klib/load` 9 个模块全 OK。

**已验证的行为**

- 公开面：`/health` `/liveness` 200 "OK"；`/readiness` ready/not ready + 503 形状；
  `/v1/models` 按 worker 汇总去重；`/server_info`（含 policy / health_check /
  circuit_breaker / enable_igw / models / healthy_workers）。
- 控制面：`POST /workers` 202 + `worker_id`/`location`；重复注册返回 202 且
  `GET /workers/{id}` 的 `job_status.status="failed"`、
  message `Worker <url> already exists`；`DELETE` 后同 URL 可重新注册（202）；
  `GET /workers` 带 total/stats 分桶。
- 推理面：round_robin 轮转，`model` 被改写成 worker 真实 id（`alias-a`→beta/alpha）；
  流式 7 个 data 帧 + `[DONE]` 原样透传；`x-smg-target-worker` 钉住生效。
- 重试：`FAIL_MODE=retry_once_500` 下第一次 500 第二次 200（mock 侧日志正好 1 次 500）；
  `retryable_500` + `SMG_RETRY_MAX_RETRIES=3` 时 mock 恰好收到 3 次 POST，
  耗尽计数 +1、backoff 直方图 attempt 1/2/3 各 +1；`no_retry_4xx` 只发 1 次、
  原样回 400 且不记熔断罚。
- 熔断：`cb_failure_threshold=1`（`retry_once` 型）→ 4 次后 open（state=1）、
  随后请求 503 `no_available_workers` + `X-SMG-Error-Code`；
  超过 `cb_timeout_duration_secs` 后首个请求触发 `open→half_open` 并探测成功，
  到 `half_open→closed`，转译计数三条各自 +1。
- 健康巡检：kill 掉 worker 进程 → 连续失败达阈值后 `is_healthy=false`、
  `/readiness` not ready；重启 worker → 连续成功达阈值后自动恢复。
- 策略：`manual` 按 `x-smg-routing-key` 粘住（alice→beta×3、bob→alpha×3、
  carol→beta×3），branch 计数 vacant 3 / occupied_hit 6，
  `smg_manual_policy_cache_entries` 由定时器发布为 3；`random`/`power_of_two`
  分发路径经 `/probe` 与选择计数确认。
- 淘汰定时器：确认每个 worker 进程都会起（含 worker 1..N），且
  `publish_gauges` 修好后 manual 轮次无 Lua error。
- 观测：`/_ui/logs`（cursor/capacity/requests）、`/_ui/stats`、
  `/_ui/logs/backends`、`/_ui/logs/stream`（实测收到 3 条 data 帧）、
  `LMR_REQUEST_LOG_CAPACITY=0` 时四者 503；`/metrics` 文本含 smg_* 家族，
  histogram cumulative 与 `+Inf` 正确。
- 纯函数：`/probe/worker-id`、`/probe/rewrite-model`、`/probe/extract-text`
  （`"sys a prev think toolout funcout"` / `"p1 p2"`）、`/probe/headers`
  （keep/drop 与白名单一致）、`/probe/env`。
- 单测（策略 agent 提供，本 agent 只跑）：tree 67 passed 0 failed、
  policies 118 passed 0 failed。

**未测**

- 多 worker 进程下的并发一致性（load 计数、registry 锁竞争、淘汰后快照行为）。
- 大 body / 超时 / 上游半途断流的真实表现（只做了小 body 功能面）。
- `x-request-id-*` 前缀头在真实上游回环里的表现；`traceparent` 只做透传，未验证语义。
- TLS 上游（`https://` worker）—— `split_url` 支持但没实跑过。
- iOS/真实客户端 SSE 断线重连（`/_ui/logs/stream` 的落后跳转逻辑只做了正向验证）。

## 7. 本轮修掉的 bug（防回归）

1. `resty.lock.new(...)` → 必须是 `lock_mod:new(...)`（方法调用，首参 self），
   否则「dictionary not found」。
2. `hb.http_get` 状态行正则原为 `%s(%d%d%d)%s*$`（要求行尾）→
   `^HTTP/%d%.%d%s+(%d%d%d)`；之前健康探测一直静默失败。
3. lua-cjson 把稀疏数字表编码成 null 数组 ⇒ `prometheus_text` 里
   `cjson.null` 参与算术崩；所有直方图桶预填 0 + 读取侧 `tonumber()`。
4. 空表编码成 `{}` ⇒ `workers/requests/backends/loads/candidates/model_infos`
   改用 `cjson.empty_array`。
5. 提前返回的错误必须显式 `ngx.status = ...`，否则带错误体回 200。
6. entrypoint 里 `$OPENRESTY_PREFIX/sbin/openresty` 不存在（实际是
   `bin/openresty`）；补 `worker_rlimit_nofile ${NOFILE_LIMIT}` 与
   `NGINX_WORKER_CONNECTIONS` 的数字校验。
7. `ERROR_LOG_PATH` 只被引用、从未赋值 ⇒ 渲染出 `error_log  warn;`，
   nginx 把日志写进一个叫 `warn` 的文件，`docker logs` 完全看不到 Lua error；
   现在默认 `/dev/stderr`（可用 `LR_ERROR_LOG_PATH` 覆盖）。
8. request id 生成写成 `ID_ALPHABET:sub(math.random(n), math.random(n))`
   （两个独立随机量当起止下标，产出的是切片而非单字符，实测 200+ 字符）；
   改成先取一个下标再 `sub(i,i)`。
9. `observability.render_bucket_labels` 拼 `{` 缺失 ⇒
   `..._bucketmethod="GET",...` 非法 exposition。
10. `registry.is_available` 用 `d:cas(...)`（该镜像没有 cas）⇒ 改 registry 锁内
    重读判定；同时把「open 永不恢复」这一真 bug 修掉（原先 `hb.can_execute`
    是死代码，没有任何调用点）。
11. 熔断指标标签由 worker id 改成 worker URL（Rust 的 `metric_label` 是 URL），
    新增 `registry.url_for(id)`（带 `u:<id>` 反向键与记录回读兜底）。
12. `policy.publish_gauges` 声明为 `.` 但被 `inst:publish_gauges()` 调用
    ⇒ `self` 为 nil 崩在定时器里；改成 `_M:publish_gauges()`。
13. 淘汰定时器原先只在 worker 0 起且依赖 `_M.default`（worker_init 时尚未创建）
    ⇒ 从未真正启动；现在每个 worker 进程都建实例并起定时器。
14. 熔断状态数值由 `closed/half_open/open = 0/1/2` 改成 Rust 的
    `closed/open/half_open = 0/1/2`，并同步 HELP 文案。
15. `record_worker_retry_backoff` 标签由 (worker_type, endpoint) 改为
    Rust 的 `attempt` 单标签（1..5，更大值各自成桶）。
16. `LMR_REQUEST_LOG_CAPACITY=0` 之前被 `validate` 抬成 1（等于强制开日志），
    现在允许 0 并让四个 `/_ui/*` 端点走 503 分支。
