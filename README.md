# lua-router

> 独立仓库：本项目原在 llm-router 工作区内作为子目录开发（对拍对象为该仓的 Rust 网关 `gateway/`，2026-09-30 起拆出独立开发）。Redis 相关门禁需要可达实例：`cp test/local.env.example test/local.env` 后填入 `LUA_TEST_REDIS_HOST/PASSWORD`（local.env 不入库）。


`llm-router` 的 **OpenResty / Lua 重写版**。目标是在 authz 网关镜像（OpenResty 1.31.1.1 +
klib.router + LuaJIT）上复刻 Rust 版 `smg` 网关（`gateway/`）的**路由行为与对外契约**，
复用同一套 `/_ui` 前端与 `watcher/` 运维链路，而不是复刻它的每一个子系统。

它只做转发：不加载模型、不做推理、不自己实现 tokenizer（`/v1/tokenize` 那几条是对上游的
字节代理）。上游是任意 OpenAI 兼容实例（llama.cpp / vLLM / SGLang），支持 `http://`、`https://`
与 `grpc://` / `grpcs://`。

与 Rust 版的关系是**行为对拍**（同请求 → 同状态码 / 同错误体形状 / 同策略指标），
不是逐字节一致。状态分四档写在 [doc/feature-gap.md](doc/feature-gap.md)：
**A 已实现并钉进契约**、**B 已文档化的有意偏差或架构限制**、**C 剩余可行动缺口**、
**D 按用户指示登记为 TODO 的项**（MCP / wasm / Postgres·Oracle，唯一口径见
[doc/todo-deferred.md](doc/todo-deferred.md)）。
逐条证据在 doc/parity-*.md 与 doc/gap-*.md，全量验证汇总见
[doc/verification-final.md](doc/verification-final.md)。

## 当前基线（2026-09-30 21:13–21:22 UTC 全量门禁）

权威日志：`/data/tmp/lr-gates/gates-20260930-230302.log`（2026-09-30 23:03→23:15 UTC，串行独占，
**`== summary: 21 passed, 0 failed, 0 skipped ==`**，单轮全绿）。同树同镜像的拆轮留档：
`/data/tmp/lr-grpc-proto/gates-live.log`（20/0/1，SKIP_ENV=mesh_two）+ `gates-20260930-225653.log`（GATE_ONLY=mesh_two PASS）。代码树关键 md5（已与
`lua-router:integration` 镜像内副本逐个核对一致）：`router.lua`
`9d8901937b7e033bdeaa0db7210708fc`、`mesh.lua` `e424e6586121c27bdafe414829572284`、
`grpc_proxy.lua` `70e9366c7e6418145265542360e90f65`。门禁脚本已仓库化：`test/final_gates.sh`。

门禁 19 → 21：第 20 门 `mesh_two`（双真 router 容器：收敛 / 长稳 / 分区 / 恢复 / retire，
钉住 `/ha/status` 幻影键回归）与第 21 门 `e2e_tls_chain`（运行时 PKI、四类握手负例、
RSA/ECDSA×TLS1.2/1.3、SNI 双证书）已纳入 `GATE_ORDER`。
两条新门禁的前置条件是**硬门**：宿主机 grpcio 由 `preflight` 检查（不可 import 直接 exit 2），
公共 Redis 不可达则该门禁 FAIL（门禁内以 `LR_REDIS_REQUIRED=1` 跑，不再 SKIP+exit 0）。

| 门禁 | 结果 | 覆盖 |
|---|---|---|
| build | successful | `docker build -t lua-router:integration`，构建期跑一次 `openresty -t` |
| conf | 2/2 syntax ok | `test/conf/nginx-lua-router.conf` + `conf/lua-router.conf` |
| unit | 9 个 luajit + 5 个 resty 口径全绿 | tree 67 / policies 118 / hash 795 / history 731 / mesh 391 / pd+grpc_proxy 373 / service_discovery 298 / jwks 120 / otel 131；resty 侧 tree 67 / policies 118 / hash 795 / integration 66 / tokenizer+parse 316（全部 0 failed） |
| contract | **841 passed / 0 failed / 2 notes** | 27 段（分段计数见下）。与 `test_hash` 的 795 只是数值接近，两者无关 |
| probes | 25 / 0 | 策略工厂、配置旋钮、map 切分、裸 JSON 改写 |
| e2e_stateful | **60 / 0** | bucket / prefix_hash / manual / failback / 快照 / 多进程 / add worker / responses C2+C4（含断开语义） |
| e2e_policies | 65 / 0 | 各策略真流量 + `LMR_MODEL_CTX` clamp |
| e2e_ui_bridge | 19 / 0 | `/v1` 与 `/_ui` 两条路径改写一致 |
| e2e_errors | 10 / 0 | `/_ui` 的 503 / 502 / 上游 4xx 契约 |
| e2e_effort | 4 / 0 | `LMR_MODEL_EFFORT` 强制与 per-model 卡片 |
| e2e_discovery_dp | **117 / 0** | DP 展开 + K8s list/watch/fieldSelector + router pod 进 mesh + layer-4 指标家族 |
| e2e_jwt | **48 / 0** | 控制面 JWT/JWKS（RSA-2048 与 EC P-256） |
| head_routes | **120 / 0** | HEAD 镜像每个 GET 路由 |
| mesh_http | **47 / 0** | mesh enabled 的真实 HTTP：对端 apply/sync、worker 镜像、`/ha/policies`、内部端点 |
| e2e_grpc | **90 / 0** | gRPC / PD 面（真实 nginx + 真实 grpcio 客户端）：注册值域、unary/streaming、metadata 透传、grpcs TLS、PD 双池与 `/readiness`、`smg_worker_pool_size` 五元组、**PD bootstrap 原生 proto body 注入**（field 10 原位替换、双解码器对拍、metadata/off 模式回归） |
| e2e_history_redis | **44 / 0** | redis history 后端：共享实例 CRUD + 第二实例同读、缺 url 回落 memory、redis 挂时 503 `history_unavailable` |
| e2e_otel | **119 / 0** | W3C trace 传播、OTLP/HTTP 导出、批量、采样、采集器故障与恢复 |
| e2e_responses_store | **18 / 0** | `/v1/responses` 元数据 patch 与条件流式持久化（含空 `conversation`、两种 item 事件名的回退终态） |
| e2e_policy_parity | **47 / 0** | prefix_hash / bucket / power_of_two / random 与 Rust 的量化对拍；Rust HTTP 面 prefix_hash 恒 503、bucket 不可选、power_of_two 无 loads 退化均为实测结论 |
| mesh_two | **38 / 0** | 双真 router 容器互 seed（SELF 写 loopback、PEERS 写 LAN，历史上出幻影键的形状）：收敛到 2 alive 无幽灵键、双向 worker 镜像、18 s 长稳零抖动、`docker stop` 分区与恢复、`/ha/shutdown` retire 广播 |
| e2e_tls_chain | **112 / 0 / 2 notes** | 运行时 PKI（根→中间→叶，SAN 含 DNS+IP，RSA3072+EC-P384 跨签）、四类握手负例（过期/rogue-CA/非 CA 签发/自签）、RSA+ECDSA×TLS1.2/1.3、SNI 同端口双证书指纹、证书/私钥不配对 fail-closed |

本文与 [doc/feature-gap.md](doc/feature-gap.md)、
[doc/verification-final.md](doc/verification-final.md)
的计数**同源于上文这棵稳定树（`router.lua 9d890193…` + `mesh.lua e424e658…` + `grpc_proxy.lua 70e9366c…`）**：`/v1/responses` 流式持久化的断开语义已落地并被门禁钉住
（persistence 分支客户端断开后继续 drain 上游并在干净结束时入库；非持久化分支立即拆泵、不入库），
逐条语义见 feature-gap §2.4 / §4.1 第 17 条与
[doc/gap-responses-final.md](doc/gap-responses-final.md)。

`e2e_grpc` 与 `e2e_history_redis` 在纳入门禁之前各自单独跑过（计数同源，纳入后由门禁每轮复现）：
`/data/tmp/lr-c1/grpc_final.log`、`/data/tmp/lr-docfix/grpc_stable_8000cfb6.log`、
`/data/tmp/lr-docfix/redis_stable.log`。**纳入之后「21 门全绿」已经覆盖 gRPC / PD 面（含原生 proto body 注入）、redis
history 后端、四策略量化对拍、双真节点 mesh 与证书链**，不再需要「另跑 e2e_grpc」这句限定；剩下的耦合是运维口径：grpcio 与公共 Redis
必须可达，否则门禁会如实跑红（可用 `SKIP_ENV=e2e_grpc,e2e_history_redis` 显式跳过，日志会记 skipped）。
手动单跑 `e2e_history_redis.py` 时不带 `LR_REDIS_REQUIRED`，Redis 不可达仍是 SKIP + exit 0。

契约 841 的 27 段构成：gate 3、public 30、workers 74、inference 38、headers 13、**mesh 46**、
**history_crud 100**、**tokenizer_plane 80**、not_found 15、**observability 55**、proxy_endpoints 56、
policy_hint 13、ui_fixed 51、tls_upstream 11、cb_race 6、ui_auth 34、igw 7、discovery 5、prometheus 14、
probes 29、cors 37、virtual_models 15、ratelimit 14、**inflight_age 32**、**auth_rbac 33**、**jwt_gate 11**、tls_server 19 = 841。
计数历史 266 → 322（fix-majors）→ 474（核心第二波）→ 659（history/tokenizer/mesh 接线）→ 717（HTTP 语义）→
780（DP 注入 + JWT）→ 795（Prometheus 家族收尾）→
**809**（`/v1/responses` 七字段 patch 的出站/存储直连断言 9 项 + 空 `conversation` 契约 5 项，
`history_crud` 段 100 项）→ **841**（新增 `inflight_age` 段 32 项：真实年龄采样、桶对齐、并发登记、跨进程采样、
打断回收、TTL 自愈、关闭即缺席 + 关闭态过滤探针）。

## 目录

| 路径 | 内容 |
|---|---|
| `conf/nginx.conf.template` | 生产模板，由入口脚本 envsubst 渲染（listen / worker 数 / 日志 / 注入点 / `GRPC_EXTRA` / `TLS_SERVER_EXTRA`） |
| `conf/lua-router.conf` | 同一套配置的裸字面量版本，不经入口脚本直接 `openresty -c` 用它做验证与最小部署 |
| `conf/ui.conf` | 全部 `/_ui/*` location（API 别名 + 静态 SPA），由入口脚本按存在性 include 进 server{} |
| `conf/grpc-server.conf.template` + `conf/grpc-readiness.conf` | gRPC listener 与 `/readiness` 覆盖片段，`SMG_GRPC_PORT>0` 时由入口脚本渲染并 include；=0 时整平面缺席 |
| `conf/grpc-prototype.conf` | 接线之前的能力探针（balancer vs 变量式 `grpc_pass`、trailers 取证），保留作历史证据，不参与部署 |
| `docker-entrypoint.sh` | env 校验 → envsubst → `openresty -t` → exec；缺省策略 `cache_aware`；cache_aware 或 mesh 开启且未显式给 `NGINX_WORKER_PROCESSES` 时把 worker 数收到 1；渲染独立 metrics 监听（缺省 `:29000`，`SMG_METRICS_PORT=0` 关闭）与 gRPC listener；`SMG_LOG_LEVEL`/`SMG_UI_DIR` 与 Lua 侧名字双认 |
| `Dockerfile` | `FROM authz:latest`，COPY lualib / 模板 / entrypoint / ui.conf / `../ui/`→`/usr/local/share/llama-ui`，构建期跑一次 `-t` gate |
| `lualib/resty/luarouter/` | 实现：`config` `registry` `hb` `policy` `router` `observability` `otel` `ui` `props` `config_store` `hash` `limit` `jwks` `service_discovery` `history` `history_redis` `mesh` `tokenizer` `parse` `pd` `grpc_proxy` + `policies/{tree,cache_aware,bucket,consistent_hashing,prefix_hash,utils}`。**这些模块全部已接进 `router.lua` / `init.lua` / 生产模板**（gRPC 与 PD 走独立 listener，由 `SMG_GRPC_PORT` 开关）；只有 wasm、MCP、Postgres/Oracle 三个 TODO 项没有代码 |
| `test/final_gates.sh` | 21 门禁串行硬门（`SKIP_ENV` / `GATE_ONLY` / `KEEP_GOING`），见上面的基线表 |
| `test/test_lua_router.sh` | 契约套件（严格模式，第一个 FAIL 即退出），26 段 |
| `test/conf/nginx-lua-router.conf` | 独立测试 conf：`listen 8080`、`/klib/load` 模块探针、`/probe/*` 内省端点 |
| `test/unit/` | 纯 Lua 单测，`luajit`(authz) 与 `resty`(apisix) 两个口径 |
| `test/integration/` | 真容器 e2e：stateful / policies / ui_bridge / errors / effort / probes / discovery_dp / jwt / head_routes / mesh_http / otel / responses_store / grpc / history_redis |
| `test/mock_llm_worker.py` | 纯标准库 mock worker，含 `echo_body` / `echo_headers` 取证 |
| `doc/` | 实现说明 + 对拍报告 + 真实上游评测 + 逐项补齐报告（`gap-*.md`）+ 缺口清单 + 最终验证汇总 |

## 快速启动

### A. 只读工作树跑起来（测试 / 调试用，不需要构建镜像）

`authz:latest` 自带 openresty 与 klib，把仓库只读挂进去就能直读工作区的 `lualib/`：

```bash
cd /path/to/lua-router
docker run -d --name lrtest --entrypoint openresty \
  -v "$PWD":/repo:ro -p 127.0.0.1::8080 \
  -e SMG_HEALTH_CHECK_INTERVAL_SECS=1 authz:latest \
  -p /usr/local/openresty/nginx/ \
  -c /repo/test/conf/nginx-lua-router.conf -g 'daemon off;'
docker port lrtest 8080/tcp          # 取宿主端口
curl -s http://127.0.0.1:<port>/health
```

这条路径下的 conf 是 `test/conf/nginx-lua-router.conf`（`worker_processes 1`、已 include
`conf/ui.conf`、带 `/klib/load` 与 `/probe/*`）。改 Lua 文件后 `docker restart lrtest` 即生效
（`/repo` 是 ro bind，重启才重载字节码）。

### B. 生产入口（发布形态）

```bash
# 构建上下文是仓库根，因为 Dockerfile 要 COPY 同级的 ui/
docker build -t lua-router:latest -f Dockerfile .

docker run -d --name lua-router --network host --restart unless-stopped \
  -e SMG_PORT=8801 \
  -e SMG_POLICY=cache_aware \
  -e SMG_ENABLE_IGW=true \
  -e SMG_WORKER_URLS=http://10.x.x.217:8100,http://10.x.x.217:8101 \
  -e SMG_HEALTH_CHECK_ENDPOINT=/health \
  -e LMR_CONFIG_FILE=/data/lua-router/runtime.json \
  -v /data/app/lua-router:/data/lua-router \
  lua-router:latest
curl -s http://127.0.0.1:8801/readiness
```

`SMG_WORKER_URLS` 可以留空，改由 `POST /workers` 或 `watcher/` 动态注册。
入口脚本会校验渲染结果（`openresty -t`），坏配置直接起不来而不是 crash-loop。

按需再开的平面（每条的语义与限制在下面的环境变量表与对应 `doc/gap-*.md`）：
`SMG_GRPC_PORT=50051`（gRPC + PD listener）、`SMG_ENABLE_MESH=1`+`SMG_MESH_PEERS`、
`SMG_HISTORY_BACKEND=redis`+`SMG_HISTORY_REDIS_HOST`、`SMG_ENABLE_TRACE=1`+`SMG_OTLP_TRACES_ENDPOINT`、
`SMG_SERVICE_DISCOVERY=1`+`SMG_SELECTOR`、`SMG_DP_AWARE=1`、`SMG_JWT_JWKS_URI`、
`SMG_TLS_CERT_PATH`+`SMG_TLS_KEY_PATH`。全部缺省关闭，关掉时对外行为与不接这些功能时逐字节一致。

裸 conf 的最小部署（不经入口脚本，值全是字面量）：

```bash
docker run -d --name lua-router --network host \
  -e SMG_WORKER_URLS=http://127.0.0.1:18001 lua-router:latest \
  /docker-entrypoint.sh openresty -p /usr/local/openresty/nginx \
    -c /usr/local/openresty/nginx/conf/lua-router/lua-router.conf -g 'daemon off;'
```

## 端点面速查

按「对外回答什么」分类。逐条证据在 doc/feature-gap.md §2–§3，路由面的实测状态码见
doc/verification-final.md §4。

| 面 | 路由 | 回答 |
|---|---|---|
| 公开面 | `/health` `/liveness` `/readiness` `/v1/models` `/model_info` `/server_info`（各有 `get_*` 与 `HEAD` 别名）、`/metrics`、`/engine_metrics`、`/health_generate` | 200；`/readiness`、`/v1/models`、`/health_generate`、`/engine_metrics` 在无可用 worker 时分别回 503 / 503 / 503 / 500（`/engine_metrics` 的 500 是契约钉住的 worker-free 形态）。`/v1/models` 会把 `LMR_VIRTUAL_MODELS` 的别名一起广告出去（`created: 0`、`owned_by: llm-router-><target>`、按 id 升序、不覆盖真实 id） |
| 推理面 | `/v1/chat/completions` `/v1/completions` `/v1/embeddings` `/v1/rerank` `/v1/classify` `/v1/responses` `/generate` | 字节透传 + 顶层 `model` 定点改写；受 `SMG_MAX_CONCURRENT_REQUESTS` 限流（拒绝回 **429 空体**）；`/v1/responses` 非流式 2xx 会补齐请求侧元数据并入库 |
| 控制面 | `POST /workers`（202 + Location）、`PUT /workers/{id}`（202，三键 `{status,worker_id,message}`）、`GET /workers[/{id}]`、`DELETE /workers/{id}`、`POST /flush_cache` | `PUT` 可改 priority / cost / labels（合并）/ api_key / 健康旋钮，身份字段忽略；非 UUID → 400、未知 → 404、坏 JSON → 400。`/flush_cache` 只挂 POST。`worker_type=prefill|decode` 与 `connection_mode=grpc|grpcs` 在 `SMG_GRPC` 关闭时回 400（Rust 分别塌缩为 Regular / 真支持，登记为偏差） |
| 会话与 tokenizer 面 | `POST /v1/conversations`、`/v1/conversations/{id}[/items[/{item_id}]]`（GET/POST/DELETE）、`/v1/responses/{id}`（GET/DELETE）、`/v1/responses/{id}/cancel`、`/v1/responses/{id}/input_items`、`/_ui/history`；`POST /v1/tokenize` `/v1/detokenize`、`/v1/tokenizers[/{id}[/status]]`、`POST /parse/function_call` `/parse/reasoning` | 由 `history` / `tokenizer` / `parse` 模块应答。会话不存在回 404 `{"error":"Conversation not found"}`；tokenizer 无声明后端回 501 `tokenizer_unavailable`、缺字段回 400；parse 无后端回 503 `Tool parser factory not initialized`。数据面/控制面 key 分组与 Rust 一致 |
| mesh / HA 面 | `/ha/{status,health,workers[/id],policies[/id],config[/key],rate-limit,rate-limit/stats,stats,shutdown}` 共 13 条 + `/_mesh/internal/{ping,sync,apply,state}` = `mesh.ROUTES` 的 17 条（`/ha/stats` 是 Lua 超集，Rust 表里没有） | `SMG_ENABLE_MESH` 未设（缺省）→ 全部固定 503 `{"error":"mesh not enabled"}`，与接线前逐字节一致；开启后委托 `mesh.dispatch`，鉴权走 `mesh_control_auth`（配 key 时控制面 key，无 key 时内部端点仅 loopback） |
| gRPC 面 | `SMG_GRPC_PORT>0` 时的独立 listener，`:path` 原样透传 | 纯字节代理；模型取自 `x-smg-model` metadata；选择策略 `SMG_GRPC_POLICY`（`round_robin`/`sticky`/`power_of_two`）。HTTP/1.1 打它得到 502 —— 就绪探针、控制面、UI 永远指向主端口 |
| `/_ui` | 别名全家 + 静态 SPA | 已鉴权（`/_ui` API 只认 `Authorization: Bearer`），方法门是 405+Allow；`/_ui/history` 必须是 exact location（`^~ /_ui/` 静态前缀会吃掉它） |

诚实表示「这实现没做」的路由只剩 **wasm 三条**：`POST /wasm`、`GET /wasm`、
`DELETE /wasm/{module_uuid}` → `501 {"error":{"type":"Not Implemented","message":"not implemented in the Lua router","code":"not_implemented"}}`。
另有 4 条 `/_ui/v1/*`（`/stream`、`/chat/completions/control` 各 GET+POST）也回 501，Rust 对它们同样回
`v1_ui_unsupported`，不构成缺口。**上一版 README 列在 501 表里的 tokenize / detokenize / tokenizers /
conversations / responses / parse 六块已经全部接到实现**，见上面的「会话与 tokenizer 面」。

**CORS**：缺省全放开，`access-control-allow-origin: *`、`access-control-allow-methods: *`、
`access-control-headers: *`、`access-control-expose-headers: *` 与 `vary: origin,
access-control-request-method, access-control-request-headers` 是**常量头**（与是否带 `Origin` 无关，对齐
tower-http 0.6.11）；`SMG_CORS_ALLOWED_ORIGINS` 给列表后只在 origin 命中时回显。预检 `OPTIONS`
在任何路由（含 `/_ui/*`，**也含未注册的未知路径**）都回 200，由 conf 的 server 级
`rewrite_by_lua_block` 在选定 location 之前提前应答；代价是未注册路径的预检在 Rust 那边其实是 404，
这条保留为偏差（feature-gap §4.1 第 4 条）。预检不进 `smg_http_requests_total`、不带
`x-request-id`（这点与 Rust 的 CorsLayer 一致）。**`/_ui` 也在 CORS 覆盖面里**，这比 Rust 宽。

## 环境变量

行为开关全部在 init 阶段由 `resty.luarouter.config` / `config_store` / `init.lua` 读环境变量，
模板里只有 nginx 解析期需要的量。默认值取自 Rust CLI 的实际默认（不是 struct 默认）。

### server / 部署

| 变量 | 默认 | 说明 |
|---|---|---|
| `SMG_HOST` / `SMG_PORT` | `0.0.0.0` / `30000` | 监听地址。`SMG_PORT` 非数字或越界 = 启动失败 |
| `NGINX_WORKER_PROCESSES` | `auto` | 渲染期决定。**未显式设置且 `SMG_POLICY=cache_aware` 或 mesh 开启时入口改成 1**（基数树与 mesh 状态都是 per-process） |
| `NGINX_WORKER_CONNECTIONS` | `4096` | 同时决定 `worker_rlimit_nofile = 2×` |
| `SMG_MAX_PAYLOAD_SIZE` | `512m` | 裸数字自动补 `m`；gRPC listener 复用同一上限 |
| `SMG_API_KEY` / `SMG_CONTROL_PLANE_API_KEY` | 空 | 数据面 / 控制面 key；后者缺省回落到前者。只认 `Authorization: Bearer` 与 `x-api-key` |
| `SMG_CONTROL_PLANE_API_KEYS` | 空 | 多 key + 角色：`id:name:role:key`（逗号或分号分隔，只在前三个冒号处切分，key 可含冒号），role 只认 `admin|user`（大小写不敏感）。非法条目跳过 + WARN，不会让实例起不来。审计日志默认开，`SMG_DISABLE_AUDIT_LOGGING=1` 关（key 值永不打印） |
| `SMG_TLS_CERT_PATH` / `SMG_TLS_KEY_PATH` | 空 = 不启 TLS | 两者必须同时给且文件非空，否则启动失败；渲染进主 server 的 `ssl_certificate*` |
| `LR_UI_CONF` | 镜像内 ui.conf | 改成 `off` 关闭 `/_ui` include（路由面照常启动） |
| `LR_HTTP_INCLUDE` / `LR_SERVER_INCLUDE` | 空 | 额外 include 注入点 |
| `LR_ERROR_LOG_PATH` / `LR_LOG_LEVEL` | `/dev/stderr` / `warn` | 空路径会让 nginx 写出名叫 `warn` 的日志文件，别留空。`SMG_LOG_LEVEL` 是 Rust 名，优先于 `LR_LOG_LEVEL`，`trace` 归一到 `debug`；两个都没给时**渲染进 `error_log` 的是 `warn`**。`config.lua` 自己读的 `log_level`（只用于 debug 采样开关）缺省是 `info`，两处缺省不同 |
| `SMG_PROMETHEUS_HOST` | `0.0.0.0` | 独立 metrics 监听的 bind 地址（IPv6 字面量由入口脚本加方括号） |
| `SMG_METRICS_PORT` / `LR_METRICS_PORT` | `29000`（Rust 名优先） | **缺省即开**独立抓取 server，只挂 `/metrics` 与 `/health`；`0` 关闭，`/metrics` 仍在主监听上 |
| `SMG_PROMETHEUS_DURATION_BUCKETS` | 空 = `observability.lua` 的 Rust 阶梯 | 逗号/空格分隔秒数。**进程生命周期内只读一次**：改桶宽会让旧 key 的 per-bucket 数组错位，所以 `observe()` 在新宽度下重建（n/s 保留，`_sum`/`_count` 仍正确） |
| `LR_INFLIGHT_SAMPLE_SECS` | `20` | `smg_http_inflight_request_age_count` 的采样间隔（Rust `start_sampler(20)` 同值）；`0` 关掉整个 tracker——不起定时器、不登记槽位，三个 age 序列整体不渲染。仅 worker 0 采样（槽表是共享的，多进程各自采样会把 `_count` 乘以 worker 数）。见 [doc/gap-inflight-age.md](doc/gap-inflight-age.md) |
| `LR_INFLIGHT_TTL_SECS` | `3600` | 年龄槽位的 TTL，即泄漏硬上界：连 log 阶段都没跑到（worker 被杀 / Lua abort）的请求最迟在此之后不再被采样 |
| `AUTHZ_DNS_RESOLVER` | `/etc/resolv.conf` 首个 | 上游用域名时必须可达 |

### 策略

| 变量 | 默认 | 说明 |
|---|---|---|
| `SMG_POLICY` | `cache_aware` | 8 个合法值：`random` `round_robin` `power_of_two` `manual` `cache_aware` `bucket` `consistent_hashing` `prefix_hash`；**未知值静默归一到默认**（与 Rust `--policy default_value_t = CacheAware` 一致，入口 banner 与 `/probe/config` 同源） |
| `SMG_CACHE_THRESHOLD` | `0.3` | cache_aware 前缀命中率门槛，越低越粘 |
| `SMG_BALANCE_ABS_THRESHOLD` / `SMG_BALANCE_REL_THRESHOLD` | `64` / `1.5` | 负载失衡双阈值，触发时暂时放弃亲和 |
| `SMG_MAX_TREE_SIZE` | `67108864` | 基数树容量上限 |
| `SMG_PREFIX_TOKEN_COUNT` / `SMG_PREFIX_HASH_LOAD_FACTOR` | `256` / `1.25` | prefix_hash（Lua 按字符数，见 impl-hash.md 偏差 6） |
| `SMG_BUCKET_ADJUST_INTERVAL_SECS` | `5` | bucket 边界重算节拍 |
| `SMG_EVICTION_INTERVAL_SECS` / `SMG_MAX_IDLE_SECS` | `120` / `14400` | 淘汰定时器 / manual 粘性映射闲置回收 |
| `SMG_ASSIGNMENT_MODE` | `random` | manual 的分配模式，另有 `min_load` `min_group` |
| `LR_SNAPSHOT_MAX_BYTES` | `3 MiB` | cache_aware 树快照写入 `lr_policy` 的上限，超限跳过 |

### 健康检查 / 熔断 / 重试 / 上游连接

| 变量 | 默认 |
|---|---|
| `SMG_HEALTH_CHECK_INTERVAL_SECS` / `_TIMEOUT_SECS` / `_ENDPOINT` | `60` / `5` / `/health`（测试与对拍常用 `1`） |
| `SMG_HEALTH_FAILURE_THRESHOLD` / `_SUCCESS_THRESHOLD` | `3` / `2` |
| `SMG_DISABLE_HEALTH_CHECK` | `false` |
| `SMG_CB_FAILURE_THRESHOLD` / `_SUCCESS_THRESHOLD` / `_TIMEOUT_DURATION_SECS` / `_WINDOW_DURATION_SECS` | `10` / `3` / `60` / `120` |
| `SMG_DISABLE_CIRCUIT_BREAKER` | `false` |
| `SMG_RETRY_MAX_RETRIES` | `5`（语义是**总尝试次数**，不是额外重试数） |
| `SMG_RETRY_INITIAL_BACKOFF_MS` / `_MAX_BACKOFF_MS` / `_BACKOFF_MULTIPLIER` / `_JITTER_FACTOR` | `50` / `30000` / `1.5` / `0.2` |
| `SMG_DISABLE_RETRIES` | `false` |
| `SMG_REQUEST_TIMEOUT_SECS` / `SMG_CONNECT_TIMEOUT_SECS` | `1800` / `10` |
| `SMG_POOL_IDLE_TIMEOUT_SECS` / `SMG_POOL_MAX_IDLE_PER_HOST` / `SMG_TCP_KEEPALIVE_SECS` | `50` / `500` / `30`（上游 cosocket 连接池） |
| `SMG_REQUEST_ID_HEADERS` | 空 | 额外认作 request id 的请求头 |

### 运行时配置（`/_ui/config` 可改，`LMR_CONFIG_FILE` 落盘）

| 变量 | 说明 |
|---|---|
| `SMG_ENABLE_IGW` | 按 `model` 查表路由；开启后未知 model → 503 `no_available_workers` |
| `SMG_WORKER_URLS` | 逗号分隔的启动播种 worker 列表 |
| `LMR_DEFAULT_EFFORT` / `LMR_EFFORT_MAP` | 八档 effort 阶梯的默认值与改写表（`low:medium,high:xhigh`） |
| `LMR_MODEL_CTX` | 每模型上下文上限，转发前 clamp `max_tokens` / `max_completion_tokens` |
| `LMR_MODEL_EFFORT` / `LMR_MODEL_EFFORT_MAP` | 每模型覆盖，优先级高于上两项 |
| `LMR_VIRTUAL_MODELS` | 虚拟别名 `alias:real`，在路由期解析并折进 worker 真实 model_id |
| `LMR_MODEL_MODALITIES` | `/_ui/props` 广告的能力位（`text,image`） |
| `LMR_CONFIG_FILE` | RuntimeConfig 原子落盘路径，reload/重建后恢复；未设 = 内存态 |
| `LMR_WATCHER_URL` | `/_ui/config/model-map` 代理到 watcher 的控制面；未配时该路由回 503 |
| `LMR_UI_DIR` / `LMR_UI_ROUTER_MODE` | 静态 SPA 目录（默认 `/usr/local/share/llama-ui`）/ 路由模式开关。Rust 名 `SMG_UI_DIR` 由入口脚本映射到 `LMR_UI_DIR`（两者同时给出时 `LMR_` 优先），裸 conf 直跑不经过入口脚本时只认 `LMR_UI_DIR` |
| `LMR_REQUEST_LOG_CAPACITY` / `LMR_LOGS_BUFFER` | 请求日志环形缓冲容量，**`0` = 关闭，四个 `/_ui/logs*`/`stats` 转 503** |
| `LMR_PRICE_IN_PER_MTOK` / `LMR_PRICE_OUT_PER_MTOK` | `/_ui/stats` 与日志里的成本折算 |
| `LMR_TEST_PIPELINE` / `LMR_TEST_WORKERS` | 仅单测内省用 |

共享字典（conf 内声明，不能用 env 调）：`lr_workers 2m`、`lr_policy 20m`、`lr_stats 5m`、
`lr_request_log 20m`、`lr_locks 1m`、`lr_limit 64k`、`lr_history 10m`、`luarouter_config 1m`。
三个 conf（模板 / 裸 conf / 测试 conf）都声明同一套。

### 并发限流与 CORS（默认全部关闭 / 全放开）

| 变量 | 默认 | 说明 |
|---|---|---|
| `SMG_MAX_CONCURRENT_REQUESTS` | `-1` | **`<=0` = 完全关闭限流**（Rust `app_context.rs:376` 同判据）。>0 时是给推理面 7 条路由的并发上限，`lr_limit` 计数，多 nginx 进程下是全局上限 |
| `SMG_QUEUE_SIZE` | `100` | 满额后允许排队的请求数；再满即拒。`0` = 不排队 |
| `SMG_QUEUE_TIMEOUT_SECS` | `60` | 排队等待上限，等待者 10 ms 轮询。缺省速率下几乎走不到这条分支 |
| `SMG_RATE_LIMIT_TOKENS_PER_SECOND` | `0` = 跟随容量 | 令牌回补速率 |
| `SMG_CORS_ALLOWED_ORIGINS` | 空 = 全放开 | 空时三件套常量头；给列表后只在 origin 命中时回显，Allow-Methods/Headers 收窄 |

限流只管推理面：公开面、控制面、`/_ui/*` 都不占令牌。拒绝回 **429 + 空体 + 无
`X-SMG-Error-Code`**；令牌在 `finish_request`（流式响应 pump 完）与 `on_log`（客户端中途断开）
双点归还，`smg_http_rate_limit_total{result="allowed|rejected"}` 只在限流启用时有样本。

### gRPC 与 PD 分离（`SMG_GRPC_PORT`，缺省 0 = 整平面缺席）

| 变量 | 默认 | 说明 |
|---|---|---|
| `SMG_GRPC_PORT` | `0` | >0 渲染独立 gRPC listener，**同时**导出 `SMG_GRPC=1` 打开注册表枚举（接受 `connection_mode=grpc|grpcs` 与 `worker_type=prefill|decode`）；0 时渲染、include、注册表三处同时不生效 |
| `SMG_GRPC_HOST` | 同 `SMG_LISTEN_HOST` | listener 绑定地址 |
| `SMG_GRPC_POLICY` | `round_robin` | gRPC 面选择：`round_robin`/`sticky`（routing-key→blake3 一致性环）/`power_of_two`；非法值启动即退 |
| `SMG_GRPC_READ_TIMEOUT_SECS` | `1800` | nginx `grpc_read_timeout`；真实上限是 Lua 按 `request_timeout_secs` 重算的 `grpc-timeout` |
| `LR_GRPC_PD_METADATA` | 缺省 = 原生 proto body | PD bootstrap 三元组的载体：缺省写进 sglang 原生 `DisaggregatedParams`（`GenerateRequest` field 10，与 Rust 同字段同编码）；`on` 退回旧的 `x-lr-*` metadata 注入（body 一字节不改）；`off` 什么都不注入。body 无法安全改写时自动回退 metadata，详见 [doc/gap-grpc-proto.md](doc/gap-grpc-proto.md) |

`SMG_GRPC` 关闭时上述四类注册请求的 400 文本与旧版逐字一致（契约钉着）。HTTP 推理面完全看不见
gRPC 记录（`registry.is_available()` 只放行 http+regular）。限制、复现与实测数据见
[doc/gap-grpc-pd.md](doc/gap-grpc-pd.md) §4/§7/§8。

### mesh / HA 集群（`SMG_ENABLE_MESH`，缺省关）

`SMG_ENABLE_MESH=1|true|yes|on`，配 `SMG_MESH_PEERS`（逗号分隔）、`SMG_MESH_SELF`/`_SELF_ADDR`、
`SMG_MESH_SELF_NAME`、`SMG_MESH_SYNC_INTERVAL_SECS`（2）、`SMG_MESH_UNREACHABLE_TIMEOUT_SECS`（30）、
`SMG_MESH_SUSPECT_THRESHOLD`（2）、`SMG_MESH_MIN_CLUSTER_SIZE`（3）、`SMG_MESH_QUORUM`、
`SMG_MESH_RPC_TIMEOUT_MS`（2000）、`SMG_MESH_SNAPSHOT_MAX_BYTES`、`SMG_MESH_RATE_WINDOW_SECS`（1）。开启且未显式给 worker 数时入口钉成 1（mesh 状态在进程内存）。
无 peers 时打 WARN 且 `/ha/*` 保持 503（实例级降级而不是崩）。设计见
[doc/gap-mesh.md](doc/gap-mesh.md)。

### history / conversations / responses 存储

| 变量 | 默认 | 说明 |
|---|---|---|
| `SMG_HISTORY_BACKEND` | `memory` | `memory` / `none` / `redis` 已实现；`postgres` / `oracle` 回 501 `history_backend_unsupported`（**TODO，不实现**，见 todo-deferred §3）；未知名坍缩为 memory（与 Rust clap 一致） |
| `SMG_HISTORY_MAX_CONVERSATIONS` / `_MAX_ITEMS_PER_CONVERSATION` / `_MAX_RESPONSES` / `_MAX_ITEMS_PER_REQUEST` | `10000` / `1000` / `10000` / `100` | Rust 的 `MAX_ITEMS_PER_REQUEST` 硬编码 20，这里可配 |
| `SMG_HISTORY_TTL_SECS` | `0` = 不过期 | 由 `eviction_interval_secs`（120）节拍跑 `history.sweep` |
| `SMG_HISTORY_REDIS_URL` 或 `_HOST`/`_PORT`/`_PASSWORD`/`_DB`/`_PREFIX`/`_TIMEOUT_MS`/`_TTL_SECS`/`_KEEPALIVE_MS`/`_KEEPALIVE_POOL` | 缺省 `127.0.0.1:6379`、前缀 `lrhist:`、超时 2500ms、keepalive 30000ms/池 8 | 纯 Lua RESP2。只给 `BACKEND=redis` 不给目标 → WARN + 回落 memory；目标不可达 → 该请求 503 `history_unavailable`，推理面不受影响。见 [doc/gap-history-redis.md](doc/gap-history-redis.md) |

`POST /v1/responses` 非流式 2xx 无条件入库（Rust OpenAI-mode 同行为，是本路由的既有语义）；流式仅在
`store=true` 或 `conversation` 为字符串（含空串）时入库：persistence 分支在客户端断开后**继续 drain
上游**，上游干净结束时照常入库；非持久化分支客户端断开立即拆泵、不入库；上游读取错误两种分支都不入库。
逐条语义以
[doc/gap-responses-final.md](doc/gap-responses-final.md) 为准。

### 控制面 JWT（Rust `smg_auth` 的对应物）

`SMG_JWT_JWKS_URI` 一旦给出即启用（未给时 JWT 整条分支关闭，只认 API key），配
`SMG_JWT_ISSUER` / `SMG_JWT_AUDIENCE` / `SMG_JWT_ROLE_CLAIM`（缺省 `roles`）/
`SMG_JWT_ROLE_MAPPING` / `SMG_JWT_LEEWAY_SECS`（30）/ `SMG_JWT_JWKS_CACHE_SECS`（300）。
JWKS 拉取走 cosocket + `resty.openssl.pkey`（EC P-256 与 RSA-2048），密钥缓存按 kid 命中。见
[doc/gap-dp-jwt.md](doc/gap-dp-jwt.md)。

### OpenTelemetry 追踪（缺省关）

`SMG_ENABLE_TRACE` + `SMG_OTLP_TRACES_ENDPOINT`，旋钮 `SMG_TRACE_BATCH_SIZE`（64）/
`SMG_TRACE_BATCH_INTERVAL_MS`（500）/ `SMG_TRACE_TIMEOUT_MS`（2000）/ `SMG_TRACE_SAMPLE_RATIO`（1.0）/
`SMG_TRACE_MAX_QUEUE`（1024）/ `SMG_TRACE_UPSTREAM_CHILD`（默认开，每次转发一个子 span）。
W3C `traceparent` 生成/继承/回写、OTLP/HTTP 导出、批量与优雅退出前 flush 全部实现；采集器不可达只计数、
不阻塞请求。自监控四条 `smg_otel_*`（Lua 超集，Rust 无）。见
[doc/gap-otel.md](doc/gap-otel.md)。

### Kubernetes 服务发现与 DP 展开（缺省关）

`SMG_SERVICE_DISCOVERY=1` + `SMG_SELECTOR` / `SMG_SERVICE_DISCOVERY_NAMESPACE` /
`SMG_SERVICE_DISCOVERY_PORT`（80）/ `SMG_SERVICE_DISCOVERY_CHECK_INTERVAL_SECS`（60）/
`SMG_PREFILL_SELECTOR` / `SMG_DECODE_SELECTOR` / `SMG_KUBE_API_SERVER` / `SMG_KUBE_SA_PATH`
（旧名 `SMG_KUBECONFIG` 兼容）。`SMG_DP_AWARE=1` 时一个 dp engine 展开成 `dp_size` 条 `<base>@<rank>`
记录，并在转发前给请求体注入 `data_parallel_rank`。list 轮询而非 watch（差异与后果见
[doc/gap-discovery-dp.md](doc/gap-discovery-dp.md)）。

## 测试

```bash
cd /path/to/lua-router

# 全量门禁（18 项，串行，首个失败即退出）
bash test/final_gates.sh
GATE_ONLY=contract bash test/final_gates.sh      # 单门禁
SKIP_ENV=mesh_http bash test/final_gates.sh      # 显式跳过（会记进日志）
KEEP_GOING=1 bash test/final_gates.sh            # 跑完并计数
LR_GATE_LOG=/data/tmp/lr-gates/my.log bash test/final_gates.sh

# 两条外部依赖套件（已在门禁内；这里单跑用于调试，串行约 25 s / 9 s）
python3 test/integration/e2e_grpc.py             # 需宿主机 grpcio，90 checks
python3 test/integration/e2e_history_redis.py    # 需公共 Redis；不带 LR_REDIS_REQUIRED 时不可达 SKIP+exit 0
LR_REDIS_REQUIRED=1 python3 test/integration/e2e_history_redis.py   # 门禁口径：不可达即 FAIL exit 1

# 契约套件单独调试（严格模式，独占约 42 s，起 4 个容器）
bash test/test_lua_router.sh
TEST_ONLY=history_crud bash test/test_lua_router.sh
KEEP_GOING=1 bash test/test_lua_router.sh

# 单测两个口径（门禁已包含，这里用于调试单个模块）
docker run --rm -v "$PWD:/repo:ro" -w /repo --entrypoint /usr/bin/resty \
  apache/apisix:3.11.0-debian -e 'package.path="/repo/lualib/?.lua;"..package.path
    dofile("/repo/test/unit/test_tree.lua")'     # 同法换其它文件
docker run --rm -v "$PWD:/repo:ro" -w /repo \
  -e LUA_TEST_LIB=/repo/lualib --entrypoint /usr/local/openresty/luajit/bin/luajit \
  authz:latest test/unit/test_mesh.lua                      # 不依赖 ngx 的模块可 luajit 直跑

# 语法门
docker run --rm -v "$PWD:/repo:ro" --entrypoint openresty authz:latest \
  -t -p /usr/local/openresty/nginx/ -c /repo/<conf/lua-router.conf|test/conf/nginx-lua-router.conf>
```

`test/final_gates.sh` 取代了旧的 `/data/tmp/lr-core2/final_gates.sh` 一次性脚本：补齐了
`probes.py`（那条钉旧缺省策略的陈旧断言也已改成 `cache_aware`）、`e2e_errors.py`、`e2e_effort.py`、
九个模块的单测与 `head_routes` / `mesh_http` / `e2e_discovery_dp` / `e2e_jwt` / `e2e_otel` /
`e2e_responses_store`，并改成首个失败即退出；后来又纳入 `e2e_grpc` 与 `e2e_history_redis`
（后又纳入 `mesh_two` 与 `e2e_tls_chain`，共 21 门；grpcio 由 preflight 硬检查，redis 门在门禁内以 `LR_REDIS_REQUIRED=1` 让「Redis 不可达」真失败）。**门禁不可并发**：所有套件都是 host 网络 + 固定容器名
前缀，两套房同时跑会造成端口/容器名争用并产生假失败（`/data/tmp/lr-gates/gates-20260930-160644.log`
与 `disc.log` 各踩过一次，串行重跑均 PASS）。

### `set_top_field` 的 number 分支（已修，两条红转绿）

上一波记录的缺陷：JSON number 分支写成 `-?[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)`，指数部分没变可选，
于是**任何普通整数都不匹配**，`set_top_field` 把「成员存在」判成「不存在」，改为在头部插入并产出重复键：

```
IN   {"max_tokens":99999,"n":1}
OUT  {"max_tokens":128,"max_tokens":99999,"n":1}   -- 按 RFC 8259 后者胜出，clamp 实际失效
```

现在指数组已改成 `(?:[eE][-+]?[0-9]+)?`，**`LMR_MODEL_CTX` 的 ctx cap 对显式带 `max_tokens` /
`max_completion_tokens` 的请求真正生效**，`/_ui` 与 `/v1` 两条路径同一条改写代码；契约 `probes` 段有
`set_top_field replaces an existing integer member without duplicating the key` 防回归。
完整推导在 [doc/feature-gap.md](doc/feature-gap.md) §6.1。

## 对拍与评测结论摘要

完整报告在 doc/parity-*.md 与 doc/real-eval.md，这里只给可直接引用的结论。

**契约（[doc/parity-contract.md](doc/parity-contract.md)）**
33 组逐字段对拍，Lua 侧修掉 7 类偏差（缺 model 的 IGW 语义、非字符串 model、错误体 content-type、
`x-request-id` 覆盖、chunked vs content-length、转发白名单里的 pin 头、HEAD 别名）。
修后 MATCH 10、DIFF 20（其中 10 行是任务书已认的偏差、4 行 Lua 有意超集、3 行 serde 措辞、2 行 mock 回显面）、INFO 3。
另有 6 条**是 Rust 侧不对**（`/v1/rerank` 丢客户端 model、typed body round-trip 丢未知字段、
JSON 响应打 `text/plain` 等），Lua 不跟着改错。

**路由行为（[doc/parity-routing.md](doc/parity-routing.md)）**
round_robin / consistent_hashing / manual / cache_aware 四条策略的均匀性、粘滞性、重分布比例、
亲和率与 Rust 对齐，其中 consistent_hashing 是**逐 key 落点完全相同**（blake3 环位逐位兼容，
摘 1/5 时 unchanged 0.80、collateral 0）。manual 的「worker 恢复后回切」原本背离，已修复并保持。
已量化偏差：`worker_processes=4` 时 cache_aware 亲和率 1.000 → 0.625（树是 per-process），
而 consistent_hashing 不受进程数影响。负载逃逸方向一致、Lua 略弱（0.100 vs 0.058）。
`prefix_hash` / `bucket` / `power_of_two` / `random` 已由 [doc/parity-policy-extra.md](doc/parity-policy-extra.md)
与第 19 门 `e2e_policy_parity` 量化对拍：Rust HTTP 面 prefix_hash 恒 503、bucket 不可选、
power_of_two 无 `/v1/loads` 时退化为随机；Lua 单边不变量全部通过。

**性能（[doc/parity-perf-v2.md](doc/parity-perf-v2.md)，当前代码）**
非流式 json：4 worker 下 Rust 达成率 92%、Lua 42%（那一格 CPU 钉在 400%，是 worker 数饱和）；
生产形态 `worker_processes auto`（144 worker）Lua 22 207 RPS / CPU 1009% / 454 µs/req，
对 Rust 26 088 / 975% / 374 µs/req 约 85%，即**高并发下 Rust 吞吐上限更高、每请求 CPU 更省**。
真实节流的流式（chunk 20 ms × 10，C=128，最接近生产解码）三目标完全打平：直连 681.8 /
Lua 677.8 / Rust 678.4 RPS，差 <0.6%，净开销 ≤0.35 ms。即时流式下 Rust 的恒定 44 ms/响应 stall
**已定界为 Rust 下游 accepted socket 缺 `TCP_NODELAY`**（客户端 busy-QUICKACK 把 357 → 4 861 RPS），
与 Lua 无关。**Lua 当前代码相较出厂镜像有 1.54x 的每请求 CPU 回退，已定责**（
[doc/parity-cpu-ablation.md](doc/parity-cpu-ablation.md)）：
P1 请求日志行在容量为 0 时仍整行构建 + P2 worker 记录表每请求从 shdict 重建 5 次（出厂 2 次），
合计约 45–65%，且残差里没有任何语义必需项（Rust 用常驻 `Arc` 持记录，可优化面 100% 在 Lua 侧）。
注意 1.54x 量于旧树 `5b60aae9…`，当前树更贵；修复排期前必须先跑同文 §8 的 R0 重测。
内存：Lua 4 worker 69–91 MiB、`auto` 144 worker 1.36–2.13 GB；Rust 110–146 MiB（146 线程常驻）。
所有组 err=0。旧版报告 [doc/parity-perf.md](doc/parity-perf.md)
的数据仍有效但代码树早于接线波，其 §4.1 的 stall 归因已被 v2 §9 取代。

**真实上游（[doc/real-eval.md](doc/real-eval.md)）**
经 `<real-upstream-host>` 三个真实模型 **18/18 通过**（功能矩阵 15 + 启动/TLS/控制面），
5 题语义与直连等价，负样本 503 契约对齐。prefix cache 调度准确性成立：cache_aware 选工 52/52 无漂移，
`cached_tokens`/prompt ≈ 97–99%（首轮 null、第 2 轮起命中、乱序重放命中不掉），上游侧无实例打散。
限制：单 worker URL 场景下粘滞结论偏弱；上游页粒度 1600 token，短会话拿不到命中；
真实上游的 token 字段对账在 usage 修复后**没有重跑过**。

**指标覆盖（[doc/gap-metrics-final.md](doc/gap-metrics-final.md)，唯一权威口径）**
Rust 注册 47 个 `smg_*` 家族，其中 7 个在 Rust 侧 describe-only（永不产生样本），
真正会被仪表盘查到的是 40 个。Lua 代码级 43 个家族名，与 Rust 交集 37，
对那 40 个的覆盖 **36/40 = 90.0%**；「子系统已实现但缺指标」**已清零** ——
`smg_http_inflight_request_age_count` 由 1024 槽表 + worker 0 定时器真实采样（语义偏差与实测见
[doc/gap-inflight-age.md](doc/gap-inflight-age.md)）。
Lua 另有 8 条超集（`smg_http_inflight_requests`、`..._age_dropped_total`、`..._age_slots_active`、
`smg_cache_aware_tenant_count`、四条 `smg_otel_*` 自监控）。
旧版 README 的「28/48 家族」口径作废，以本节为准。

## 已知限制索引

单一入口是 [doc/feature-gap.md](doc/feature-gap.md)，
它把每一面归进 A / B / C / D 四档。速查：

- **A 已实现并钉进契约**：HTTP 推理面 7 条路由 + 8 策略 + 控制面（含 `PUT /workers/{id}`）+
  `/_ui` 全家 + 观测（Prometheus / 请求日志 / OTel 追踪）+ CORS + 全局并发限流 + 虚拟别名 +
  HTTPS 上游 + 服务端 TLS + 多 key/RBAC + 控制面 JWT + mesh/HA + history（memory/none/redis）+
  conversations/responses 存储 + tokenizer/parse 代理 + DP 展开与 `data_parallel_rank` 注入 +
  K8s service discovery + gRPC/PD 分离（`SMG_GRPC_PORT` 开启）。gRPC、PD、mesh、tokenizer、
  parse、history、K8s discovery、dp_aware、OTel **都不是「未接线」**，接线报告见
  doc/gap-integration.md、doc/gap-metrics-final.md、doc/gap-responses-final.md。
- **B 已文档化的有意偏差 / 架构限制**：`/flush_cache` 与 `/v1/loads` 响应形状、404 带 JSON 体、
  `/v1/*` 方法门是 404 而 axum 是 405、CORS 覆盖面比 Rust 宽、排队超时回 429 而 Rust 回 408、
  `PUT` 同步生效、`cost` 编不出 `1.0`、tokenizer 无后端的措辞、`/ha` 深路径 404 措辞、
  **`nginx grpc_pass` 每 RPC 一条上游连接（无 h2 multiplex）**、PD 无 prefill/decode 并发双发与
  decode 落点只能走扩展字段 101/102/103（bootstrap 三元组的原生 proto body 注入已做，stock 引擎把
  扩展字段当未知字段跳过，decode 中继需后端配合）、nginx 层 gRPC 重试不可用、裸 `grpc://` 无探活、
  K8s 大集群 list 未分页可能误 retire / 动态成员不被三方转发学习（watch 本身已实现，
  见 doc/gap-discovery-watch.md）、
  `smg_worker_routing_keys_active` 与 `smg_router_tpot_seconds` 的语义差。完整列表在 feature-gap §4。
- **C 剩余可行动缺口**（较上一版大幅收敛）：① Lua 非流式 1.54x CPU 回退的**修复落地**——定责已完成
  （parity-cpu-ablation：P1+P2 ≈45–65%），剩 R0 重测与按嫌疑榜修复；② TLS 入口对证书/私钥不配对与
  leaf 缺中间证书的预检（现状 `openresty -t` 放行、握手才失败，路线在 gap-tls-chain §5/§6）；
  ③ mTLS 客户端证书鉴权未实现（e2e_tls_chain 已实测：不发 client-CA 名单、带客户端证书仍 200）；
  ④ 门禁对公共 Redis 的可达性耦合（不可达即红，需显式 skip 或本地 redis）。
  下列旧 C 项已收口：K8s watch/fieldSelector/router pod/resourceVersion（e2e_discovery_dp 117/0）、
  mesh 双真节点进契约（mesh_two 38/0）、四策略对拍（e2e_policy_parity 47/0）、
  正式证书链（e2e_tls_chain 112/0/2）、gRPC PD proto body 注入（e2e_grpc 90/0）、
  `/ha/status` 幻影键（真修 + 变异验证，见 gap-mesh-final）。
- **D TODO（用户指示 2026-09-30，除非明确指定否则不实现）**：MCP server 调用、wasm 中间件、
  Postgres/Oracle history 后端。唯一口径
  [doc/todo-deferred.md](doc/todo-deferred.md)，
  wasm 可行性研究见 [doc/wasm-feasibility.md](doc/wasm-feasibility.md)。
  引用时不要写成「在接」「排期中」：`/wasm` 三条路由仍固定 501，`SMG_HISTORY_BACKEND` 取
  `postgres` / `oracle` 仍固定 501 `history_backend_unsupported`，且 `smg_mcp_*` 四条家族刻意不注册。
  history 后端只有这两个是 TODO，`memory` / `none` / `redis` 不在此列。

判定某个模块是否真的接进了请求路径，最快的一条命令（本文与 feature-gap 的接线档位都由它复核）：

```bash
grep -rn 'require "resty.luarouter.<模块>"' lualib/resty/luarouter/router.lua \
  lualib/resty/luarouter/init.lua conf/ | grep -v prototype
```

## 文档索引

| 文档 | 内容 |
|---|---|
| [doc/verification-final.md](doc/verification-final.md) | **最终验证汇总**：目标、实现范围、测试矩阵、四类对比结论、已知偏差与后续建议、文件索引 |
| [doc/architect.md](doc/architect.md) | 架构总览：运行时模型、请求生命周期、模块地图、共享状态、策略、集成、部署与测试框架 |
| [doc/feature-gap.md](doc/feature-gap.md) | 功能缺口清单，A/B/C/D 四档，含路由面探针判据与「怎么引用这份清单」 |
| [doc/todo-deferred.md](doc/todo-deferred.md) | TODO / Deferred 档（MCP、wasm、Postgres/Oracle history）的唯一口径 |
| [doc/impl-core.md](doc/impl-core.md) / [impl-policies.md](doc/impl-policies.md) / [impl-hash.md](doc/impl-hash.md) / [impl-ui.md](doc/impl-ui.md) / [impl-tests.md](doc/impl-tests.md) | 第一波实现说明：推理/控制/公开面、8 策略与基数树、BLAKE3 与两个 hash 策略、`/_ui` 与 props、契约套件 |
| [doc/fix-majors.md](doc/fix-majors.md) | M1–M6 + usage 截断回归的根因与证据（266 → 322） |
| [doc/gap-core.md](doc/gap-core.md) | 核心缺口两波的补齐清单与 8 条有意偏差（322 → 474 的出处） |
| [doc/gap-http-semantics.md](doc/gap-http-semantics.md) | HTTP 语义与观测对齐清单 1–7 + 4 个测试门 bug（659 → 717） |
| [doc/gap-integration.md](doc/gap-integration.md) | history / tokenizer+parse / mesh 三条接线记录（474 → 659） |
| [doc/gap-auth-tls.md](doc/gap-auth-tls.md) | 控制面多 key/角色/审计与服务端 TLS（`auth_rbac` 33 + `tls_server` 19） |
| [doc/gap-dp-jwt.md](doc/gap-dp-jwt.md) | `data_parallel_rank` 注入与控制面 JWT/JWKS（`jwt_gate` 11，769 → 780） |
| [doc/gap-discovery-dp.md](doc/gap-discovery-dp.md) | DP 展开与 K8s service discovery 的差异、取舍与未做清单 |
| [doc/gap-mesh.md](doc/gap-mesh.md) | mesh / HA 的 CRDT 设计、带宽代价与鉴权围栏 |
| [doc/gap-mesh-final.md](doc/gap-mesh-final.md) | `/ha/status` 幻影键根因与真修（sync_with 身份统一）+ 双真节点 e2e（mesh_two 门 38/0） |
| [doc/gap-discovery-watch.md](doc/gap-discovery-watch.md) | K8s watch 四个失败的修复（dereg 计数、router pod 进 mesh、retire 语义，117/0） |
| [doc/gap-tls-chain.md](doc/gap-tls-chain.md) | 证书链 / SNI / 四类握手负例门（e2e_tls_chain 112/0/2）与入口预检缺口 |
| [doc/gap-grpc-proto.md](doc/gap-grpc-proto.md) | gRPC PD 原生 proto body 注入（field 10 原位替换，单测 373 / e2e 90） |
| [doc/parity-cpu-ablation.md](doc/parity-cpu-ablation.md) | 1.54x CPU 回退定责（P1+P2 ≈45–65%）与消融实验计划 |
| [doc/gap-history.md](doc/gap-history.md) | history 对象模型、后端抽象、游标翻页 |
| [doc/gap-history-redis.md](doc/gap-history-redis.md) | redis 后端（已实现）：RESP2、数据结构、三场景 e2e |
| [doc/gap-tokenizer-parse.md](doc/gap-tokenizer-parse.md) | tokenizer 注册表与 tool/reasoning 解析（L1：不实现 BPE，只代理） |
| [doc/gap-grpc-pd.md](doc/gap-grpc-pd.md) | gRPC + PD 的镜像能力实证、接线定案、与 Rust 的差异、遗留限制 |
| [doc/gap-otel.md](doc/gap-otel.md) | OTel 追踪（span 模型、批量、采样、故障路径） |
| [doc/gap-metrics-final.md](doc/gap-metrics-final.md) | **Prometheus 家族覆盖率的唯一权威口径** + `smg_worker_pool_size` 修复 |
| [doc/gap-responses-final.md](doc/gap-responses-final.md) | `/v1/responses` 七字段元数据 patch 与条件流式持久化 |
| [doc/gap-test-gates.md](doc/gap-test-gates.md) | 门禁仓库化 + HEAD / mesh 盲区补齐 |
| [doc/parity-contract.md](doc/parity-contract.md) / [parity-routing.md](doc/parity-routing.md) / [parity-perf.md](doc/parity-perf.md) / [parity-perf-v2.md](doc/parity-perf-v2.md) | 四份对拍原始报告；性能以 v2 为准 |
| [doc/real-eval.md](doc/real-eval.md) | 真实上游端到端评测与 prefix cache 调度准确性 |
| [doc/wasm-feasibility.md](doc/wasm-feasibility.md) | wasm 可行性研究（结论：保持不支持） |
| [doc/verification-run3.md](doc/verification-run3.md) | 第 3 波全量复测的历史记录（基线已过时四代，只作证据留档） |
