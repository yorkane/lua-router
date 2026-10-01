# gap-core：核心功能缺口补齐（状态报告）

日期：2026-09-30。作者：/root/gap_core2（接手 /root/gap_core 的未完成清单）。

> **状态（文档刷新轮复核，2026-09-30 04:5x UTC）**：本文一~三节的 10 项**全部有效并已进工作树**，
> 数字与最终门禁一致 —— 契约 **474 / 0 / 3**、单测 67 / 118 / 795 / 66、
> e2e_stateful 43/0、e2e_policies 65/0、e2e_ui_bridge 19/0，两个 conf `openresty -t` successful，
> 镜像构建门 successful。权威日志 `/data/tmp/lr-core2/{FINAL_GATES,CONFIRM_contract,CONFIRM_e2e}.log`
> （代码树 = router.lua md5 `c0570b84…`；上一波是 `c96b6556…`）。对外行为已经写进
> [README](../README.md)（env / metrics / 501 / CORS / 限流四节）
> 与 [feature-gap.md](feature-gap.md)（§1 新增行、§3 重写、§5.5 偏差）。
>
> **本文尚未收的三条尾巴（不改代码，故只登记）**：
> 1. `test/integration/probes.py:34` 还断言「未知策略归一到 `round_robin`」，缺省已随
>    `config.lua` 对齐成 `cache_aware`，所以 `probes.py` 现在是 25 checks / **1 failed**；
>    它也不在 `final_gates.sh` 的门禁列表里（feature-gap §5.6）。
> 2. `router.lua:19-20` 的 "Deliberately absent" 注释与新的 501 清单不符（feature-gap §5.2）。
> 3. 注册校验回 400 挡住了 `connection_mode=grpc` 与 `worker_type=prefill/decode`，这是
>    grpc / PD 接线那一步必须先解决的点（本文偏差 3、feature-gap §3.4 / §5.5 第 6 条）。
>
> 引用本文 §四 的偏差时注意：feature-gap §5.5 把同一批偏差按「消费方先看哪条」重排了顺序，
> **两边条号不对应**（本文 1 是 flush_cache 形状，那边是 5；本文 3 是 prefill/grpc 400，那边是 6），
> 交叉引用以 feature-gap §5.5 的条号为准。
所有权范围：router.lua、registry.lua、hb.lua、config.lua、
lualib/resty/luarouter/limit.lua（新建）、conf/nginx.conf.template、
conf/lua-router.conf、docker-entrypoint.sh、test/conf/nginx-lua-router.conf、
test/test_lua_router.sh、test/mock_llm_worker.py、test/integration/_lib.py
（仅 metrics 端口注入）、lualib/resty/luarouter/init.lua（仅 on_log 归还）。
未动：history.lua / mesh.lua / tokenizer.lua / parse.lua / grpc_proxy.lua / pd.lua、
policies/*、conf/ui.conf、config_store.lua（只调用其 virtual_models_list）。

## 一、清单完成情况

| # | 项 | 状态 | 落点 |
|---|----|------|------|
| 1 | PUT /workers/{id} | 完成 | registry.lua `_M.update`（锁内复用 patch_record，labels 合并）+ router.lua `update_worker_handler`（`exact_json`） |
| 2 | /v1/models 虚拟别名 | 完成 | router.lua `inject_virtual_models`（去重、created 0、owned_by `llm-router-><target>`、按 id 升序） |
| 3 | 未实现端点统一 501 | 完成 | router.lua `not_implemented_routes` 25 条（含 conversations/items、responses/input_items、tokenizers/{id}[/status]、parse/*、wasm[/  :module_uuid]） |
| 4 | /flush_cache 走 POST | 完成 | hb.lua `http_request`（http_get 变薄包装）+ flush_cache_handler POST + mock 的 POST 路由与 GET 405 + 断言区分 success/error |
| 5 | CORS 对齐 Rust | 完成 | router.lua `cors_decision`/`cors_apply`/`cors_preflight`，handle() 里在路由分发前短路 OPTIONS，代理响应在 `apply_response_headers` 末尾重贴 |
| 6 | 并发限流 | 完成 | limit.lua（新建）+ `lua_shared_dict lr_limit 64k`（三个 conf）+ inference_handler acquire + finish_request/init.lua on_log 双点 release + `smg_http_rate_limit_total{result}` |
| 7 | metrics 独立监听 | 完成 | docker-entrypoint.sh：缺省 29000、`0` 关闭、host 取 SMG_PROMETHEUS_HOST、`METRICS_ADDR`；observability.lua buckets 惰性读 `cfg().duration_buckets` |
| 8 | duration 直方图接真实调用点 | 完成 | finish_request 内 2xx+已选 worker 时 `record_router_duration`；log_inference_request 内 `note_duration` → `/_ui/stats.avg_duration_ms` 为 number |
| 9 | 注册校验 | 完成 | registry.lua `check_worker_type`/`check_connection_mode`，`_M.add` 第三返回值 kind="validation" → handler 回 400 invalid_request |
| 10 | entrypoint env 双认 + worker_processes | 完成 | SMG_LOG_LEVEL/LR_LOG_LEVEL（trace→debug）、SMG_UI_DIR→LMR_UI_DIR 映射、`${SMG_POLICY:-cache_aware}` 覆盖缺省路径 |

### 关键实现取舍（源码依据）
- PUT 的 202 形状取自 `core/worker_service.rs:138-146`（`UpdateWorkerResult::into_response`）：
  只有 `status/worker_id/message` 三键，**没有** url、没有 Location，与 POST 不同。
  错误映射：非 UUID→400 `BAD_REQUEST`，未知→404 `WORKER_NOT_FOUND`，body 非对象/字段类型错→400。
  可改字段 = priority/cost/labels（合并）/api_key/health_check_* /disable_health_check；
  `model_id`/`url` 等身份字段忽略（契约断言确认不被改写）。
- CORS 逐条对齐 tower-http 0.6.11：`allow_origin/Methods/Headers/Expose` 的 wildcard 与列表形态都是
  **常量头**，与请求是否带 Origin 无关（`cors/allow_origin.rs` 的 to_header + 实测 <dev-box>:8800 无 Origin
  仍回 `access-control-allow-origin: *`）；只有列表模式的 origin 匹配是有条件的（未命中不发 ACAO）。
  Vary 用 `", "` 连接（`cors/vary.rs:29-33`），列表形态的 Allow-Methods/Headers 用 `,` 无空格
  （`cors/mod.rs:465-482`）。Max-Age 只随预检响应（`cors/mod.rs:681`）。
- 限流位置：Rust 的 concurrency_limit_middleware 只挂 protected_routes（server.rs:1314），且 route_layer
  声明顺序使 auth 先于限流执行 → Lua 在 `check_data_auth()` 之后 acquire；`/_ui/*` 与公开面/控制面不受限。
  令牌桶参数按 `app_context.rs:376`：`max_concurrent_requests<=0` 完全关闭；refill 速率缺省跟随容量。
- 归还链双保险：`finish_request`（正常路径，流式响应 pump 完才走到）+ `init.lua` 的 `on_log()`
  （客户端中途断开时唯一还会执行的阶段）。`limit.release()` 以 `ngx.ctx.lr_limit_token` 为幂等闸门。
  三层防泄漏：ctx 幂等闸门（重复调用不会多还）、on_log 兜底、以及 lr_limit 里 token/stamp 键带
  1h TTL —— 极端情况下（两个归还点都没跑到）计数过期后 refill 按满容量重来，预算自愈而不是永久被吃掉。

## 二、契约套件新增断言（严格模式）

- workers：PUT 202 三键 + 无 url/location + 无 Location 头；priority/cost/label 生效；labels 合并不覆盖；
  api_key+health 旋钮；身份字段不被改写；非 UUID→400、未知→404、坏 JSON→400、非数值 priority→400、
  labels 非对象→400、空对象→202；worker_type=prefill→400、connection_mode=grpc（字符串与 tagged 对象两种形态）
  →400、显式 regular→202。
- not_found：15 条 501 清单（verb+path 逐条，状态码与 error.code 双断言）。
- proxy_endpoints：flush_cache 断言从「结果条数」升级为「每条 result==success、status==200、
  success==true、all_failed==false」。
- observability：`smg_router_request_duration_seconds_count{`、`/_ui/stats.avg_duration_ms|type=="number"`。
- cors（新段，28 checks）：wildcard 模式三件套 + 预检全套头值 + 未知路径/控制面 OPTIONS 200；
  白名单模式回显命中 origin、`GET,POST,OPTIONS`、`content-type,authorization`、expose `x-request-id`、
  max-age 3600、未命中/无 Origin 不发 ACAO、代理响应保留 CORS 头。
- virtual_models（新段）：alias 出现在 data、shape（object/created=0/owned_by）、真实 id 不被覆盖、
  按 id 升序、alias 实际路由到目标、无 worker 时 503 文本不受注入影响。
- ratelimit（新段）：容量 1 + 慢 mock（LATENCY_MS=1200）并发 2 个 chat → 恰好 200/429 各一次；
  429 空体 + 无 X-SMG-Error-Code + Content-Length: 0；结束后再来一个 → 200（证明归还）；
  /health 与 /workers 不受计量；`smg_http_rate_limit_total{result="allowed"|"rejected"}` 两个采样都在。
- probes：`/klib/load` 覆盖 `resty.luarouter.limit: OK`；`/probe/config` 断言 max_concurrent_requests=-1、
  queue_size=100、queue_timeout_secs=60、metrics_port=29000、metrics_host=0.0.0.0、
  policy=cache_aware、cors_allowed_origins 长度 0、duration_buckets 长度 0。
- prometheus：entrypoint 缺省渲染含 `listen 0.0.0.0:29000;`、`worker_processes 1;`、
  `error_log /dev/stderr info;`（SMG_LOG_LEVEL 生效）、`SMG_UI_DIR` 单独即可定位静态包；
  `SMG_METRICS_PORT=0` 渲染中不含 `:29000` 且主端口 /metrics 仍 200。

## 三、回归数字（本轮实跑，全部硬门）

| 套件 | 结果 | 说明 |
|------|------|------|
| `openresty -t` test conf | successful | |
| `openresty -t` conf/lua-router.conf | successful | |
| entrypoint 渲染 + 镜像内 `openresty -t`（Dockerfile 构建门） | successful | `docker build -t lua-router:integration` 通过 |
| 单测 tree | 67 passed / 0 failed | |
| 单测 policies | 118 / 0 | |
| 单测 hash | 795 / 0 | |
| 单测 integration（apisix resty） | 66 / 0 | |
| **契约套件（严格模式）** | **474 passed / 0 failed / 3 notes** | 基线 322 → +152 新增断言 |
| e2e_stateful | 43 checks / 0 failed | |
| e2e_policies | 65 checks / 0 failed | 此前唯一的红 `[ctx cap] LMR_MODEL_CTX=alpha:128 clamps max_tokens` 转绿 |
| e2e_ui_bridge | 19 checks / 0 failed | 此前唯一的红 `[parity] /v1 and /_ui forward identical clamps` 转绿 |

数字来源：最终代码树定型后重跑一遍全套（契约 474/0/3、e2e 43/0 + 65/0 + 19/0），
与之前的连续门禁运行（build → 契约 → 三个 e2e → 四个单测 → 两个 conf `openresty -t`）数字一致；
logs 见 /data/tmp/lr-core2/{FINAL_GATES,CONFIRM_contract,CONFIRM_e2e}.log。

契约 474 条按 section 分布：gate 3、public 30、workers 74、inference 38、headers 13、mesh 5、
not_found 39、observability 27、proxy_endpoints 23、ui_fixed 51、tls_upstream 11、cb_race 6、
ui_auth 33、igw 7、discovery 5、prometheus 14、probes 29、cors 37、virtual_models 15、ratelimit 14。
3 条 NOTE 全是既有偏差（404 body、方法不匹配、/v1/loads 形状），未新增 note。

契约新增断言分布：workers（PUT + 注册校验）、not_found（501 清单 15 条 ×2 断言）、
proxy_endpoints（flush_cache 成功/错误可区分）、observability（duration 直方图 +
avg_duration_ms）、probes（limit 模块 + 新配置键缺省值）、prometheus（entrypoint 缺省渲染
/ SMG_LOG_LEVEL / SMG_UI_DIR / `SMG_METRICS_PORT=0`）、cors（新段 34 checks）、
virtual_models（新段）、ratelimit（新段）。

> e2e 的 check 总数以源码 `check(` 站点数为准（e2e_policies 65、e2e_ui_bridge 19）。
> 用旧日志（各 65/19 checks，含 1 红）与新日志逐条 check 名做 diff：名字集合完全一致，
> 少的 1 条只是旧日志末尾重复的 `FAILED:` 汇总行，没有 check 被跳过；两条此前失败的
> check（`[ctx cap] LMR_MODEL_CTX=alpha:128 clamps max_tokens`、
> `[parity] /v1 and /_ui forward identical clamps`）本轮都在 PASS 列表里。

另外本轮发现并修掉一个真实缺陷：`ngx.sleep` 成功时**不返回任何值**，
limit.lua 原先用 `ok == false or ok == nil` 判定中断，等于把每次健康 sleep 当成客户端断开，
导致开启队列时排队请求立刻 429（等待窗口失效）。改为 `pcall(ngx.sleep, …)` 后队列真正生效，
并补了队列契约用例（在跑的 200 + 排队的 200 + 队列满的 429）。

## 四、有意偏差登记

1. flush_cache 响应形状仍是 `{results,success,all_failed}`，Rust 为
   `{successful,failed,total_workers,http_workers,message}`。
2. 排队超时回 429（Rust middleware 回 408）。补充：Rust 的 `TokenBucket::acquire` 把等待时间算成
   `tokens_needed / refill_rate`，并与 `queue_timeout_secs` 取较小者；这里 release() 直接返还令牌，
   等待者在下一次轮询（10 ms）即被放行，所以缺省下排队几乎不会走到超时分支。要复现 Rust 的
   「按速率补充」延迟，需显式设一个小的 SMG_RATE_LIMIT_TOKENS_PER_SECOND。
3. `worker_type` prefill/decode、`connection_mode` grpc：Lua 回 400 拒绝（Rust 分别塌缩为 Regular / 真支持）。
4. OPTIONS 未注册路径回 200（Rust tower 层实际 404）——按任务书要求。
5. PUT /workers/{id} 是同步落库而非 Rust 的异步 job（立即生效，job_status 不出现 update 作业）。
   同一项的细化：PUT 可写的 health 参数里，`health_failure_threshold`/`health_success_threshold`
   与 `disable_health_check` 是**按 worker 生效**的（hb.check_all 读记录字段）；
   `health_check_timeout_secs` 与 `health_check_interval_secs` 只是存进记录，探测仍用全局值
   ——Rust 更极端，`build_health_config` 只看 router_config，per-worker 的健康参数一概忽略。
6. `smg_http_rate_limit_total` 只在限流实际启用时才有样本（Rust 同样只在挂中间件时计数）。
7. SMG_PROMETHEUS_DURATION_BUCKETS 在进程生命周期内只读一次：桶宽已烘进每个存储的直方图，
   改桶宽会让旧 key 的 per-bucket 数组错位，observe() 选择在新宽度下重建（n/s 保留，_sum/_count 仍正确）。
8. CORS 预检的覆盖面比 Rust 更宽：任务书要求「OPTIONS 全路由预检成功」，因此 conf 里加了
   server 级 `rewrite_by_lua_block` → `router.preflight_guard()`。nginx 在选定 location 之前执行
   server rewrite，所以 ui.conf 那些自带 axum 风格方法门的 `/_ui/*`（OPTIONS 本会 405）也统一回 200，
   并且普通 `/_ui/*` 响应同样带 CORS 头（handle() 看不到这些请求）。副作用：预检不进 `smg_http_requests_total`、
   不带 `x-request-id`（与 Rust 的 CorsLayer 行为一致）。`handle()` 内的 `cors_apply`/OPTIONS 短路保留，
   用于没有该 rewrite 指令的配置（如直接 conf/lua-router.conf 的旧用法）。

## 五、修改文件清单（本 agent 全部改动）

1. `lualib/resty/luarouter/registry.lua` — `_M.update`、worker_type/connection_mode 校验、`_M.add` 返回 kind
2. `lualib/resty/luarouter/router.lua` — PUT handler、models 别名注入、501 路由表、flush_cache POST、
   CORS 三函数与接线、限流 acquire/release、duration 记录、`object_body` 辅助
3. `lualib/resty/luarouter/limit.lua` — 新建
4. `lualib/resty/luarouter/init.lua` — on_log 里加令牌兜底归还（授权范围内）
5. `lualib/resty/luarouter/observability.lua` — buckets 惰性化 + `record_http_rate_limit` + HELP 条目
6. `conf/nginx.conf.template`、`conf/lua-router.conf`、`test/conf/nginx-lua-router.conf` — `lr_limit 64k`；
   test conf 的 `/klib/load` 覆盖 limit
7. `docker-entrypoint.sh` — metrics 监听缺省/关闭/host、SMG_LOG_LEVEL、SMG_UI_DIR、cache_aware 缺省规则；
   启动 banner 的 policy 缺省值同步改成 cache_aware（否则未设 SMG_POLICY 时日志自称 round_robin），
   并打印 metrics 监听状态
6b. 三个 conf 另加 server 级 `rewrite_by_lua_block`（`router.preflight_guard()`），见偏差 8
8. `test/mock_llm_worker.py` — POST /flush_cache 200、GET /flush_cache 405
9. `test/test_lua_router.sh` — 上述新断言 + cors/virtual_models/ratelimit 三个新段 + prometheus 扩展
10. `test/integration/_lib.py` — start_router 注入 `SMG_METRICS_PORT=0`（授权范围内）
11. `doc/gap-core.md` — 本文档
