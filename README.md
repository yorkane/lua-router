# lua-router

> 独立仓库：本项目原在 llm-router 工作区内作为子目录开发（对拍对象为该仓的 Rust 网关 `gateway/`，2026-09-30 起拆出独立开发）。**当前定位是纯调度网关**：按 doc/scope-trim.md 删掉了 gRPC/PD、history 存储、tokenizer/parse 代理、网关自身鉴权、Kubernetes 服务发现与 OTel 追踪六个平面（mesh 按用户裁定保留）。`test/local.env.example` 机制仍在，当前门禁不再需要任何外部依赖覆盖项。


`llm-router` 的 **OpenResty / Lua 重写版**。目标是在 authz 网关镜像（OpenResty 1.31.1.1 +
klib.router + LuaJIT）上复刻 Rust 版 `smg` 网关（`gateway/`）的**路由行为与对外契约**，
复用同一套 `/_ui` 前端与 `watcher/` 运维链路，而不是复刻它的每一个子系统。

它只做转发：不加载模型、不做推理、不数 token、不存会话。上游是任意 OpenAI 兼容实例
（llama.cpp / vLLM / SGLang），只接受 `http://` 与 `https://`：注册表把 `connection_mode`
与 `worker_type` 收成单值（其它拼写回 400），`/v1/tokenize`、`/parse/*`、`/v1/conversations*`
这些路径不再注册，落进 404 sink。

与 Rust 版的关系是**行为对拍**（同请求 → 同状态码 / 同错误体形状 / 同策略指标），
不是逐字节一致。状态分四档写在 [doc/feature-gap.md](doc/feature-gap.md)：
**A 已实现并钉进契约**、**B 已文档化的有意偏差或架构限制**、**C 剩余可行动缺口**、
**D 按用户指示登记为 TODO 的项**（MCP / wasm，唯一口径见
[doc/todo-deferred.md](doc/todo-deferred.md)；Postgres·Oracle history 随 history 平面一起删除，
已不在 TODO 名单里）。
逐条证据在 doc/parity-*.md 与 doc/gap-*.md，全量验证汇总见
[doc/verification-final.md](doc/verification-final.md)。

## 当前基线（2026-10-01 03:41–03:48 UTC 全量门禁，裁剪后）

权威日志：`/data/tmp/lr-gates/full-final.log`（2026-10-01 03:41:24→03:48 UTC，串行独占，
**`== summary: 15 passed, 0 failed, 0 skipped ==`**，单轮全绿）。代码树关键 md5（与
`lua-router:integration` 镜像内副本核对一致）：`router.lua`
`0d35b0b8f8298c4d4188af3527d1a927`、`mesh.lua` `e424e6586121c27bdafe414829572284`、
`registry.lua` `86729a8c81ff78e7ecfffca2393847fd`。门禁脚本已仓库化：`test/final_gates.sh`。

按 doc/scope-trim.md 执行模块裁剪后，门禁 21 → 15：删掉 `e2e_grpc`、`e2e_history_redis`、
`e2e_otel`、`e2e_responses_store`、`e2e_discovery_dp`、`e2e_jwt` 六道门（对应平面已删除），
DP 展开的断言整体迁入 `e2e_stateful`（60 → 91 项）。`preflight` 不再检查宿主机 grpcio，
`test/local.env` 不再有必需项。剩下的耦合只有一条：门禁不可并发（host 网络 + 固定容器名前缀）。

| 门禁 | 结果 | 覆盖 |
|---|---|---|
| build | successful | `docker build -t lua-router:integration`，构建期跑一次 `openresty -t` |
| conf | 2/2 syntax ok | `test/conf/nginx-lua-router.conf` + `conf/lua-router.conf` |
| unit | luajit 4 + resty 4 口径全绿 | luajit 侧 tree 67 / policies 118 / hash 795 / mesh 391；resty 侧 tree 67 / policies 118 / hash 795 / integration 66（全部 0 failed） |
| contract | **580 passed / 0 failed / 2 notes** | 22 段（分段计数见下）。与 `test_hash` 的 795 只是数值接近，两者无关 |
| probes | 25 / 0 | 策略工厂、配置旋钮、map 切分、裸 JSON 改写 |
| e2e_stateful | **91 / 0** | bucket / prefix_hash / manual / failback / 快照 / 多进程 / add worker / responses C2+C4（含断开语义）+ **DP 展开 31 项**（dp_size 展开、rank 推理、单 rank 撤收、`/server_info` 500 不展开、关时不展开） |
| e2e_policies | 65 / 0 | 各策略真流量 + `LMR_MODEL_CTX` clamp |
| e2e_ui_bridge | 25 / 0 | `/v1` 与 `/_ui` 两条路径改写一致 |
| e2e_errors | 10 / 0 | `/_ui` 的 503 / 502 / 上游 4xx 契约 |
| e2e_effort | 4 / 0 | `LMR_MODEL_EFFORT` 强制与 per-model 卡片 |
| head_routes | **108 / 0** | HEAD 镜像每个 GET 路由 |
| mesh_http | **47 / 0** | mesh enabled 的真实 HTTP：对端 apply/sync、worker 镜像、`/ha/policies`、内部端点 |
| e2e_policy_parity | **47 / 0** | prefix_hash / bucket / power_of_two / random 与 Rust 的量化对拍 |
| mesh_two | **37 / 0** | 双真 router 容器互 seed：收敛到 2 alive 无幽灵键、双向 worker 镜像、18 s 长稳零抖动、`docker stop` 分区与恢复、`/ha/shutdown` retire 广播 |
| e2e_tls_chain | **112 / 0 / 2 notes** | 运行时 PKI（根→中间→叶）、四类握手负例（过期/rogue-CA/非 CA 签发/自签）、RSA+ECDSA×TLS1.2/1.3、SNI 同端口双证书指纹、证书/私钥不配对 fail-closed |

契约 580 的 22 段构成：gate 3、public 30、workers 75、inference 38、headers 13、**mesh 44**、
not_found 15、**observability 53**、proxy_endpoints 56、policy_hint 13、ui_fixed 51、
tls_upstream 11、cb_race 6、igw 7、discovery 5、prometheus 14、probes 29、cors 37、
virtual_models 15、ratelimit 14、**inflight_age 32**、tls_server 19 = 580。
其中 `discovery` 段测的是 **`/model_info` 元数据发现**（registry 健康扫描自动补 model_id），与已删除的
Kubernetes 服务发现无关，是保留段。
裁剪前基线为 841 项 / 27 段（`6d2103a~1`），删除的 5 段与被裁掉的断言对应：history_crud 100、
tokenizer_plane 80、ui_auth 34、auth_rbac 33、jwt_gate 11，另有 workers / observability / mesh /
not_found 段的局部断言随各自平面收敛（逐步 841 → 840 → 740 → 659 → 580，见 git log 的六个 trim commit）。

## 目录

| 路径 | 内容 |
|---|---|
| `conf/nginx.conf.template` | 生产模板，由入口脚本 envsubst 渲染（listen / worker 数 / 日志 / 注入点 / `TLS_SERVER_EXTRA`） |
| `conf/lua-router.conf` | 同一套配置的裸字面量版本，不经入口脚本直接 `openresty -c` 用它做验证与最小部署 |
| `conf/ui.conf` | 全部 `/_ui/*` location（API 别名 + 静态 SPA），由入口脚本按存在性 include 进 server{} |
| `docker-entrypoint.sh` | env 校验 → envsubst → `openresty -t` → exec；缺省策略 `cache_aware`；cache_aware 或 mesh 开启且未显式给 `NGINX_WORKER_PROCESSES` 时把 worker 数收到 1；渲染独立 metrics 监听（缺省 `:29000`，`SMG_METRICS_PORT=0` 关闭）；`SMG_LOG_LEVEL`/`SMG_UI_DIR` 与 Lua 侧名字双认 |
| `Dockerfile` | `FROM authz:latest`，COPY lualib / 模板 / entrypoint / ui.conf / `../ui/`→`/usr/local/share/llama-ui`，构建期跑一次 `-t` gate |
| `lualib/resty/luarouter/` | 实现（裁剪后 13 个模块）：`config` `registry` `hb` `policy` `router` `observability` `ui` `props` `config_store` `hash` `limit` `mesh` `init` + `policies/{tree,cache_aware,bucket,consistent_hashing,prefix_hash,utils}`。**全部已接进 `router.lua` / `init.lua` / 生产模板**；DP 展开（`expand_dp` / `url@rank`）与 rank 注入（`inject_dp_rank`）在裁剪时分别内联进 `registry.lua` 与 `router.lua`，语义逐字节不变 |
| `test/final_gates.sh` | 15 门禁串行硬门（`SKIP_ENV` / `GATE_ONLY` / `KEEP_GOING`），见上面的基线表 |
| `test/test_lua_router.sh` | 契约套件（严格模式，第一个 FAIL 即退出），22 段 |
| `test/conf/nginx-lua-router.conf` | 独立测试 conf：`listen 8080`、`/klib/load` 模块探针、`/probe/*` 内省端点 |
| `test/unit/` | 纯 Lua 单测 5 个文件（tree / hash / policies / integration / mesh），`luajit`(authz) 与 `resty`(apisix) 两个口径 |
| `test/integration/` | 真容器 e2e：stateful（含 DP 断言）/ policies / ui_bridge / errors / effort / probes / head_routes / mesh_http / mesh_two / policy_parity / tls_chain |
| `test/mock_llm_worker.py` | 纯标准库 mock worker，含 `echo_body` / `echo_headers` 取证 |
| `doc/` | 实现说明 + 对拍报告 + 真实上游评测 + 逐项补齐报告（`gap-*.md`）+ 缺口清单 + 最终验证汇总。**已删除平面的 gap-*.md（grpc-pd / grpc-proto / history / history-redis / tokenizer-parse / dp-jwt / auth-tls 的 JWT 部分 / discovery-dp / discovery-watch / otel）保留为历史证据，不再与当前代码一致** |

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

按需再开的开关（裁剪后只剩这几个，语义与限制在下面的环境变量表与对应 `doc/gap-*.md`）：
`SMG_ENABLE_MESH=1`+`SMG_MESH_PEERS`（集群 mesh）、`SMG_DP_AWARE=1`（DP 展开 + rank 注入）、
`SMG_TLS_CERT_PATH`+`SMG_TLS_KEY_PATH`（服务端 TLS）。全部缺省关闭，关掉时对外行为与不接这些功能时逐字节一致。
gRPC/PD、history 存储、tokenizer/parse 代理、网关鉴权、K8s 服务发现与 OTel 的 env 已全部移除，
容器环境里残留这些名字不再有任何效果。

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
| 推理面 | `/v1/chat/completions` `/v1/completions` `/v1/embeddings` `/v1/rerank` `/v1/classify` `/v1/responses` `/generate` | 字节透传 + 顶层 `model` 定点改写；受 `SMG_MAX_CONCURRENT_REQUESTS` 限流（拒绝回 **429 空体**）；`/v1/responses` 是非流式 2xx 补齐请求侧元数据的纯透传路由，不入库 |
| 控制面 | `POST /workers`（202 + Location）、`PUT /workers/{id}`（202，三键 `{status,worker_id,message}`）、`GET /workers[/{id}]`、`DELETE /workers/{id}`、`POST /flush_cache` | `PUT` 可改 priority / cost / labels（合并）/ api_key / 健康旋钮，身份字段忽略；非 UUID → 400、未知 → 404、坏 JSON → 400。`/flush_cache` 只挂 POST。`worker_type` 与 `connection_mode` 收成单值：只有 `regular` 与 `http`（或其 serde 对象拼写、缺省）被接受，其它值一律 400（gRPC/PD 平面已删除） |
| ~~会话与 tokenizer 面~~ | `/v1/conversations*`、`/v1/responses/{id}*`（GET/DELETE/cancel/input_items）、`/_ui/history`、`/v1/tokenize` `/v1/detokenize`、`/v1/tokenizers*`、`/parse/*` | **整面已删除**（doc/scope-trim.md）：路径不注册，与任意未知路径一样落进 404 sink `{"error":{"type":"Not Found","code":"not_found",…}}` |
| mesh / HA 面 | `/ha/{status,health,workers[/id],policies[/id],config[/key],rate-limit,rate-limit/stats,stats,shutdown}` 共 13 条 + `/_mesh/internal/{ping,sync,apply,state}` = `mesh.ROUTES` 的 17 条（`/ha/stats` 是 Lua 超集，Rust 表里没有） | `SMG_ENABLE_MESH` 未设（缺省）→ 全部固定 503 `{"error":"mesh not enabled"}`，与接线前逐字节一致；开启后委托 `mesh.dispatch`；鉴权层删除后 `/_mesh/internal/*` 不再有 loopback 围栏，**信任边界就是网络本身**——只把该端口暴露给可信对端 |
| `/_ui` | 别名全家 + 静态 SPA | **无鉴权**（网关鉴权层已删除，所有端点开放）；方法门未实现，已注册路径的错误方法按 404 sink 回答 |

诚实表示「这实现没做」的路由只剩 **wasm 三条**：`POST /wasm`、`GET /wasm`、
`DELETE /wasm/{module_uuid}` → `501 {"error":{"type":"Not Implemented","message":"not implemented in the Lua router","code":"not_implemented"}}`。
另有 4 条 `/_ui/v1/*`（`/stream`、`/chat/completions/control` 各 GET+POST）也回 501，Rust 对它们同样回
`v1_ui_unsupported`，不构成缺口。裁剪前挂在 501 表的 tokenize / detokenize / tokenizers /
conversations / responses / parse 六块随各自平面一起删除，改由 404 sink 应答。

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
| `SMG_MAX_PAYLOAD_SIZE` | `512m` | 裸数字自动补 `m` |
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

**信任边界**：网关自身的鉴权层（数据面/控制面 key、多 key + 角色、审计日志、控制面 JWT）已整体
删除，`/workers`、`/flush_cache`、`/_ui/*`、`/ha/*`、`/_mesh/internal/*` 与推理面一样开放。
部署时必须由边缘（authz 网关）或网络隔离决定谁能连到这个端口。
worker 记录里的 `api_key` 字段保留 —— 那是本路由向**上游**出示的凭据，不是挡在自己前面的门。

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
`lr_request_log 20m`、`lr_locks 1m`、`lr_limit 64k`、`luarouter_config 1m`。（history 平面的 `lr_history 10m` 已随该平面删除，三个 conf 里都不再声明。）
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

### mesh / HA 集群（`SMG_ENABLE_MESH`，缺省关）

`SMG_ENABLE_MESH=1|true|yes|on`，配 `SMG_MESH_PEERS`（逗号分隔）、`SMG_MESH_SELF`/`_SELF_ADDR`、
`SMG_MESH_SELF_NAME`、`SMG_MESH_SYNC_INTERVAL_SECS`（2）、`SMG_MESH_UNREACHABLE_TIMEOUT_SECS`（30）、
`SMG_MESH_SUSPECT_THRESHOLD`（2）、`SMG_MESH_MIN_CLUSTER_SIZE`（3）、`SMG_MESH_QUORUM`、
`SMG_MESH_RPC_TIMEOUT_MS`（2000）、`SMG_MESH_SNAPSHOT_MAX_BYTES`、`SMG_MESH_RATE_WINDOW_SECS`（1）。开启且未显式给 worker 数时入口钉成 1（mesh 状态在进程内存）。
无 peers 时打 WARN 且 `/ha/*` 保持 503（实例级降级而不是崩）。设计见
[doc/gap-mesh.md](doc/gap-mesh.md)。鉴权层删除后 `/_mesh/internal/{ping,sync,apply,state}` 不再
要求 token、也没有 loopback 围栏，所以 mesh 端口只能开在可信网络里；单实例部署保持缺省关闭即可。

### DP 展开（`SMG_DP_AWARE`，缺省关）

`SMG_DP_AWARE=1` 时，一个 `/server_info` 报 `dp_size > 1` 的引擎展开成 `dp_size` 条
`<base>@<rank>` 记录（每条独立健康计数），转发前给请求体注入顶层 `data_parallel_rank`
（深度感知的 JSON 拼接，不改嵌套同名字段）。`dp_size` 拿不到（`/server_info` 非 200 / 无该字段）
时保持单条记录，探测有上限（`registry.MAX_DP_ATTEMPTS` = 20），关时逐字节不变。
Kubernetes pod 轮询（`SMG_SERVICE_DISCOVERY` 一族）已删除；展开所需的三个纯决策函数与 rank 注入
分别内联进 `registry.lua` 与 `router.lua`，与删除前的输出逐字节一致（12 例拼接对拍）。历史设计见
[doc/gap-discovery-dp.md](doc/gap-discovery-dp.md)。

## 测试

```bash
cd /path/to/lua-router

# 全量门禁（15 项，串行，首个失败即退出）
bash test/final_gates.sh
GATE_ONLY=contract bash test/final_gates.sh      # 单门禁
SKIP_ENV=mesh_http bash test/final_gates.sh      # 显式跳过（会记进日志）
KEEP_GOING=1 bash test/final_gates.sh            # 跑完并计数
LR_GATE_LOG=/data/tmp/lr-gates/my.log bash test/final_gates.sh

# 契约套件单独调试（严格模式，独占约 2.5 min，起 4 个容器）
bash test/test_lua_router.sh
TEST_ONLY=workers bash test/test_lua_router.sh   # 单段调试（mesh / observability / inflight_age …）
KEEP_GOING=1 bash test/test_lua_router.sh        # 跑完并计数

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
各模块单测与 `head_routes` / `mesh_http` / `e2e_policy_parity` / `mesh_two` / `e2e_tls_chain`，
并改成首个失败即退出，峰值 21 门。doc/scope-trim.md 的裁剪把与被删平面绑定的六门
（`e2e_grpc` / `e2e_history_redis` / `e2e_otel` / `e2e_responses_store` / `e2e_discovery_dp` / `e2e_jwt`）
一并撤下，DP 断言并入 `e2e_stateful`，现在是 15 门，preflight 也不再检查 grpcio 与 Redis。
**门禁不可并发**：所有套件都是 host 网络 + 固定容器名
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
与 `e2e_policy_parity` 门（第 13 门）量化对拍：Rust HTTP 面 prefix_hash 恒 503、bucket 不可选、
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

**指标覆盖（口径以 [doc/gap-metrics-final.md](doc/gap-metrics-final.md) 为历史基线，当前数字如下）**
Rust 注册 47 个 `smg_*` 家族，其中 7 个在 Rust 侧 describe-only（永不产生样本），
真正会被仪表盘查到的是 40 个。裁剪后 Lua 代码级 38 个家族名、HELP 表 37 条，与 Rust 交集 33，
对那 40 个的覆盖 **33/40 = 82.5%**：掉的三条全部是 discovery 家族
（`smg_discovery_registrations_total` / `_deregistrations_total` / `_workers_discovered`），
随 Kubernetes 服务发现一起删除，属于「子系统不实现 ⇒ 家族不注册」。
`smg_http_inflight_request_age_count` 仍由 1024 槽表 + worker 0 定时器真实采样（语义偏差与实测见
[doc/gap-inflight-age.md](doc/gap-inflight-age.md)）。
Lua 独有超集剩 4 条（`smg_http_inflight_requests`、`..._age_dropped_total`、`..._age_slots_active`、
`smg_cache_aware_tenant_count`），四条 `smg_otel_*` 自监控随 OTel 一起删除。
契约 `prometheus` 段（14 项）钉住当前 exposition 的家族名与 HELP 完整性。

## 已知限制索引

[doc/feature-gap.md](doc/feature-gap.md) 的 A/B/C/D 四档写于裁剪之前，它对已删除平面的
「已实现并钉进契约」判定**已失效**，只在追溯历史时参考。当前速查：

- **保留并钉进契约**：HTTP 推理面 7 条路由 + 8 策略 + 控制面（含 `PUT /workers/{id}`）+
  `/_ui` 全家 + 观测（Prometheus  exposition + `/_ui/logs` 请求日志）+ CORS + 全局并发限流 +
  虚拟别名 + effort/ctx 卡片 + HTTPS 上游 + 服务端 TLS + mesh/HA + DP 展开与
  `data_parallel_rank` 注入 + 在途请求年龄采样 + 独立 metrics 监听。
- **已删除（doc/scope-trim.md，用户裁定 2026-10-01）**：gRPC 传输面与 PD 双池、
  history / conversations / responses 存储（含 redis 后端）、tokenizer / parse 代理、
  网关自身鉴权（数据面/控制面 key、多 key + 角色、审计日志、控制面 JWT/JWKS）、
  Kubernetes 服务发现、OTel 追踪（W3C 生成/回写/导出）。
  这些平面的代码、env、单测与门禁全部移除，对应路径落 404 sink。
- **有意偏差 / 架构限制**：`/flush_cache` 与 `/v1/loads` 响应形状、404 带 JSON 体、
  `/v1/*` 与已注册路径的错误方法是 404 而 axum 是 405+Allow、CORS 覆盖面比 Rust 宽、
  排队超时回 429 而 Rust 回 408、`PUT` 同步生效、`cost` 编不出 `1.0`、`/ha` 深路径 404 措辞、
  cache_aware 基数树 per-process（多 worker 时亲和率按进程数摊薄）、
  `smg_worker_routing_keys_active` 与 `smg_router_tpot_seconds` 的语义差。
- **剩余可行动缺口**：① Lua 非流式 1.54x CPU 回退的**修复落地**（定责已完成，
  parity-cpu-ablation：P1+P2 ≈45–65%，剩 R0 重测与按嫌疑榜修复）；② TLS 入口对证书/私钥不配对与
  leaf 缺中间证书的预检（现状 `openresty -t` 放行、握手才失败，路线在 gap-tls-chain §5/§6）；
  ③ mTLS 客户端证书鉴权未实现（e2e_tls_chain 已实测：不发 client-CA 名单、带客户端证书仍 200）。
  旧 C 项里随平面删除而消失的：Redis 可达性耦合、K8s watch/分页、gRPC PD body 注入。
- **D TODO（用户指示 2026-09-30，除非明确指定否则不实现）**：MCP server 调用、wasm 中间件。
  唯一口径 [doc/todo-deferred.md](doc/todo-deferred.md)，
  wasm 可行性研究见 [doc/wasm-feasibility.md](doc/wasm-feasibility.md)。
  引用时不要写成「在接」「排期中」：`/wasm` 三条路由仍固定 501，`smg_mcp_*` 四条家族刻意不注册。
  （Postgres/Oracle history 曾经是第三项，history 平面删除后它不再是本仓库的 TODO。）

判定某个模块是否真的接进了请求路径，最快的一条命令（本文的接线档位由它复核）：

```bash
grep -rn 'require "resty.luarouter.<模块>"' lualib/resty/luarouter/router.lua \
  lualib/resty/luarouter/init.lua conf/
```

## 文档索引

标记 **（历史）** 的条目描述的是 doc/scope-trim.md 之前的实现，代码、env 与门禁已随对应平面删除，
只作为决策与实测证据留档，不再与当前树一致。

| 文档 | 内容 |
|---|---|
| [doc/verification-final.md](doc/verification-final.md) | **（历史）** 裁剪前的最终验证汇总：目标、实现范围、测试矩阵、四类对比结论、已知偏差与后续建议、文件索引 |
| [doc/scope-trim.md](doc/scope-trim.md) | 范围收敛判定书：新范围下的模块 KEEP/DELETE/TRIM、量化收益、测试面影响与执行顺序 |
| [doc/architect.md](doc/architect.md) | 架构总览：运行时模型、请求生命周期、模块地图、共享状态、策略、集成、部署与测试框架（模块清单为裁剪前快照） |
| [doc/feature-gap.md](doc/feature-gap.md) | 功能缺口清单，A/B/C/D 四档，含路由面探针判据与「怎么引用这份清单」 |
| [doc/todo-deferred.md](doc/todo-deferred.md) | TODO / Deferred 档（MCP、wasm）的唯一口径；文中关于 Postgres/Oracle history 的段落写于 history 平面删除之前 |
| [doc/impl-core.md](doc/impl-core.md) / [impl-policies.md](doc/impl-policies.md) / [impl-hash.md](doc/impl-hash.md) / [impl-ui.md](doc/impl-ui.md) / [impl-tests.md](doc/impl-tests.md) | 第一波实现说明：推理/控制/公开面、8 策略与基数树、BLAKE3 与两个 hash 策略、`/_ui` 与 props、契约套件 |
| [doc/fix-majors.md](doc/fix-majors.md) | M1–M6 + usage 截断回归的根因与证据（266 → 322） |
| [doc/gap-core.md](doc/gap-core.md) | 核心缺口两波的补齐清单与 8 条有意偏差（322 → 474 的出处） |
| [doc/gap-http-semantics.md](doc/gap-http-semantics.md) | HTTP 语义与观测对齐清单 1–7 + 4 个测试门 bug（659 → 717） |
| [doc/gap-integration.md](doc/gap-integration.md) | **（历史）** history / tokenizer+parse / mesh 三条接线记录（474 → 659） |
| [doc/gap-auth-tls.md](doc/gap-auth-tls.md) | 控制面多 key/角色/审计（**已删除**）与服务端 TLS（保留，`tls_server` 19 项仍在契约） |
| [doc/gap-dp-jwt.md](doc/gap-dp-jwt.md) | `data_parallel_rank` 注入（保留）与控制面 JWT/JWKS（**已删除**，`jwt_gate` 11 撤下） |
| [doc/gap-discovery-dp.md](doc/gap-discovery-dp.md) | DP 展开（保留）与 K8s service discovery（**已删除**）的差异与取舍 |
| [doc/gap-mesh.md](doc/gap-mesh.md) | mesh / HA 的 CRDT 设计、带宽代价与鉴权围栏 |
| [doc/gap-mesh-final.md](doc/gap-mesh-final.md) | `/ha/status` 幻影键根因与真修（sync_with 身份统一）+ 双真节点 e2e（mesh_two 门 38/0） |
| [doc/gap-discovery-watch.md](doc/gap-discovery-watch.md) | **（历史）** K8s watch 四个失败的修复（dereg 计数、router pod 进 mesh、retire 语义，117/0） |
| [doc/gap-tls-chain.md](doc/gap-tls-chain.md) | 证书链 / SNI / 四类握手负例门（e2e_tls_chain 112/0/2）与入口预检缺口 |
| [doc/gap-grpc-proto.md](doc/gap-grpc-proto.md) | **（历史）** gRPC PD 原生 proto body 注入（field 10 原位替换，单测 373 / e2e 90） |
| [doc/parity-cpu-ablation.md](doc/parity-cpu-ablation.md) | 1.54x CPU 回退定责（P1+P2 ≈45–65%）与消融实验计划 |
| [doc/gap-history.md](doc/gap-history.md) | **（历史）** history 对象模型、后端抽象、游标翻页 |
| [doc/gap-history-redis.md](doc/gap-history-redis.md) | **（历史）** redis 后端：RESP2、数据结构、三场景 e2e |
| [doc/gap-tokenizer-parse.md](doc/gap-tokenizer-parse.md) | **（历史）** tokenizer 注册表与 tool/reasoning 解析（L1：不实现 BPE，只代理） |
| [doc/gap-grpc-pd.md](doc/gap-grpc-pd.md) | **（历史）** gRPC + PD 的镜像能力实证、接线定案、与 Rust 的差异、遗留限制 |
| [doc/gap-otel.md](doc/gap-otel.md) | **（历史）** OTel 追踪（span 模型、批量、采样、故障路径） |
| [doc/gap-metrics-final.md](doc/gap-metrics-final.md) | Prometheus 家族覆盖率口径的**裁剪前基线**（当前数字见上面的「指标覆盖」）+ `smg_worker_pool_size` 修复 |
| [doc/gap-responses-final.md](doc/gap-responses-final.md) | `/v1/responses` 七字段元数据 patch（保留，纯出站改写）与条件流式持久化（**已删除**） |
| [doc/gap-test-gates.md](doc/gap-test-gates.md) | 门禁仓库化 + HEAD / mesh 盲区补齐 |
| [doc/parity-contract.md](doc/parity-contract.md) / [parity-routing.md](doc/parity-routing.md) / [parity-perf.md](doc/parity-perf.md) / [parity-perf-v2.md](doc/parity-perf-v2.md) | 四份对拍原始报告；性能以 v2 为准 |
| [doc/real-eval.md](doc/real-eval.md) | 真实上游端到端评测与 prefix cache 调度准确性 |
| [doc/wasm-feasibility.md](doc/wasm-feasibility.md) | wasm 可行性研究（结论：保持不支持） |
| [doc/verification-run3.md](doc/verification-run3.md) | 第 3 波全量复测的历史记录（基线已过时四代，只作证据留档） |
