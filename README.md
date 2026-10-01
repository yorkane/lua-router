# lua-router

LLM 推理网关的 OpenResty/Lua 实现：**多 GPU 服务的服务发现与请求调度器**。上游是任意
OpenAI 兼容实例（llama.cpp / vLLM / SGLang），只接受 `http://` 与 `https://`。它只做转发：
不加载模型、不做推理、不存会话；流式响应零缓冲透传，推理体只做顶层精确改写（model /
stream_options / profile 收窄），不整表重编码。

与 Rust 版 `smg` 网关（llm-router 仓库 `gateway/`）的关系是**行为对拍**（同请求 → 同状态码 /
同错误体形状 / 同策略指标），对拍报告见 doc/parity-*.md 与 doc/real-eval.md。2026-10-01 按用户
裁定执行范围裁剪（[doc/scope-trim.md](doc/scope-trim.md)）：gRPC/PD、history 存储、tokenizer/parse
代理、网关自身鉴权、Kubernetes 服务发现、OTel 六个平面整体删除（git 历史可恢复）；mesh、
DP 展开、服务端 TLS 保留。TODO 不实现：wasm、MCP（唯一口径 [doc/todo-deferred.md](doc/todo-deferred.md)）。

**信任边界**：网关层零鉴权——`/workers`、`/_ui`、`/model-map`、`/ha` 与推理面全部开放，
只可部署在 authz 边缘之后或可信内网。worker 记录里的 `api_key` 是本路由向**上游**出示的
凭据，不是挡在自己前面的门。

## 当前基线

全量门禁权威日志：`/data/tmp/lr-gates/gates-20261001-145420.log`（串行独占，**20 passed /
0 failed / 0 skipped**）。代码基线：Lua 22 057 行 / 15 个模块 + policies/ 6 文件、单测 9 文件。

| 门禁 | 计数 | 覆盖 |
|---|---|---|
| build / conf | — / 2 语法 OK | 镜像构建（含一次 `openresty -t`）；生产模板 + 裸 conf 双语法门 |
| unit | luajit 8 + resty 1 口径 | luajit 侧 tree 67 / policies 118 / hash 795 / mesh 391 / watcher 267 / gpu_load 274 / routing_dyn 122 / profiles 421；resty 侧 integration 125（全部 0 failed） |
| contract | **650 / 0 failed / 2 notes** | 23 段 wire 契约（分段构成见 `test/test_lua_router.sh` 头部；`discovery` 段测的是 `/model_info` 元数据发现，与已删除的 K8s 发现无关） |
| probes | 25 / 0 | 策略工厂、配置旋钮、map 切分、裸 JSON 改写 |
| e2e_stateful | 91 / 0 | bucket / prefix_hash / manual / failback / 快照 / 多进程 / add worker / responses 元数据回填与断开语义 + DP 展开 31 项 |
| e2e_policies | 65 / 0 | 各策略真流量 + `LMR_MODEL_CTX` clamp |
| e2e_ui_bridge | 25 / 0 | `/v1` 与 `/_ui` 两条路径改写一致 |
| e2e_errors / e2e_effort | 10 / 4 | `/_ui` 的 503/502/上游 4xx 契约；effort 强制与 per-model 卡片 |
| head_routes | 108 / 0 | HEAD 镜像每个 GET 路由 |
| mesh_http / mesh_two | 47 / 37 | mesh 真实 HTTP（对端 apply/sync、worker 镜像、/ha/policies）；双真容器互 seed 收敛、docker stop 分区恢复、retire 广播 |
| e2e_policy_parity | 47 / 0 | prefix_hash / bucket / power_of_two / random 与 Rust 的量化对拍 |
| e2e_watcher | 65 / 0 | 内建 watcher：targets/proc/docker 三源发现、九条守卫逐条断言、model-map 改名、容器重启重发现 |
| e2e_profiles | 97 / 0 | 虚拟 model profile 与 upstreams：白名单 / per-alias policy / api_key 三态与脱敏 / 30s 自愈 / apply 原子性 |
| e2e_token_accounting | 62 / 0 | 流式 include_usage 透明注入+剥帧、四类 token 指标、400 兜底 sticky |
| e2e_gpu_load | 58 / 0 | GPU 负载双源：worker /metrics 抓取与远程 Prometheus 查询写入 registry |
| e2e_routing_dyn | 51 / 0 | 路由动态变更：全局与 per-model 策略热切换免重启、非法名 400 不生效 |
| e2e_tls_chain | 112 / 0 / 2 notes | 运行时 PKI、四类握手负例、RSA+ECDSA×TLS1.2/1.3、SNI 同端口双证书、证书/私钥不配对 fail-closed |

契约 650 的 23 段构成：gate 3、public 30、workers 75、inference 38、headers 13、mesh 44、
not_found 15、observability 53、proxy_endpoints 56、policy_hint 13、ui_fixed 57、tls_upstream 11、
cb_race 6、igw 7、discovery 5、prometheus 14、probes 29、cors 37、virtual_models 15、ratelimit 14、
inflight_age 32、tls_server 19、profiles_upstreams 64。

## 目录

| 路径 | 内容 |
|---|---|
| `conf/nginx.conf.template` | 生产模板，由入口脚本 envsubst 渲染（listen / worker 数 / 日志 / 注入点 / `TLS_SERVER_EXTRA`） |
| `conf/lua-router.conf` | 同一套配置的裸字面量版本，不经入口脚本直接 `openresty -c` 用于验证与最小部署 |
| `conf/ui.conf` | 全部 `/_ui/*` location（API 别名 + 静态 SPA），由入口脚本按存在性 include 进 server{} |
| `docker-entrypoint.sh` | env 校验 → envsubst → `openresty -t` → exec；缺省策略 `cache_aware`；cache_aware 或 mesh 开启且未显式给 `NGINX_WORKER_PROCESSES` 时把 worker 数收到 1；渲染独立 metrics 监听（缺省 `:29000`，`SMG_METRICS_PORT=0` 关闭） |
| `Dockerfile` | `FROM authz:latest`，COPY lualib / 模板 / entrypoint / ui.conf / `ui/`→`/usr/local/share/llama-ui`，构建期跑一次 `-t` 门 |
| `lualib/resty/luarouter/` | 实现（15 模块 + policies/ 6 文件）：router / init / registry / watcher / gpu_load / policy / hb / config_store / config / observability / mesh / hash / limit / ui / props，全部接进请求路径 |
| `ui/` | 原版 llama.cpp webui（`/_ui/`）+ `ui/admin/`（Quasar UMD 管理台四页，中英双语）；`logs-inject.js` 向原版 webui 注入 Logs/Admin 入口 |
| `test/final_gates.sh` | 20 门串行硬门（`SKIP_ENV` / `GATE_ONLY` / `KEEP_GOING`） |
| `test/test_lua_router.sh` | 契约套件（严格模式，第一个 FAIL 即退出），23 段 |
| `test/unit/` | 纯 Lua 单测 9 个文件，`luajit`(authz) 与 `resty`(apisix) 两个口径 |
| `test/integration/` | 真容器 e2e：stateful / policies / ui_bridge / errors / effort / probes / head_routes / mesh_http / mesh_two / policy_parity / tls_chain / watcher / token_accounting / gpu_load / routing_dyn / profiles |
| `test/mock_llm_worker.py` | 纯标准库 mock worker，含 `echo_body` / `echo_headers` 取证 |
| `doc/` | 现状文档 20 份（架构 / 交接 / 裁剪判定 / 各能力设计与对拍报告），索引见文末；裁剪前平面的历史留档已于 2026-10-01 清理，git 历史可查 |

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

这条路径用的 conf 是 `test/conf/nginx-lua-router.conf`（worker_processes 1、已 include
`conf/ui.conf`、带 `/klib/load` 与 `/probe/*`）。改 Lua 文件后 `docker restart lrtest` 即生效。

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

`SMG_WORKER_URLS` 可以留空，改由 `POST /workers` 或内建 watcher（`SMG_WATCHER_ENABLED=1`）动态
发现注册。入口脚本会校验渲染结果（`openresty -t`），坏配置直接起不来而不是 crash-loop。

按需再开的开关（全部缺省关闭，关掉时对外行为与不接这些功能时逐字节一致）：
`SMG_ENABLE_MESH=1`+`SMG_MESH_PEERS`（集群 mesh）、`SMG_DP_AWARE=1`（DP 展开 + rank 注入）、
`SMG_WATCHER_ENABLED=1`（内建服务发现，[doc/gap-watcher-merge.md](doc/gap-watcher-merge.md)）、
`SMG_TLS_CERT_PATH`+`SMG_TLS_KEY_PATH`（服务端 TLS）。已删平面的 env（gRPC/PD、history、
tokenizer、鉴权、K8s discovery、OTel 一族）残留不再有任何效果。

裸 conf 的最小部署（不经入口脚本，值全是字面量）：

```bash
docker run -d --name lua-router --network host \
  -e SMG_WORKER_URLS=http://127.0.0.1:18001 lua-router:latest \
  /docker-entrypoint.sh openresty -p /usr/local/openresty/nginx \
    -c /usr/local/openresty/nginx/conf/lua-router/lua-router.conf -g 'daemon off;'
```

## 端点面速查

| 面 | 路由 | 回答 |
|---|---|---|
| 公开面 | `/health` `/liveness` `/readiness` `/v1/models` `/model_info` `/server_info`（各有 GET 与 HEAD 别名）、`/metrics`、`/engine_metrics`、`/health_generate` | 200；`/readiness`、`/v1/models`、`/health_generate`、`/engine_metrics` 在无可用 worker 时分别回 503 / 503 / 503 / 500（`/engine_metrics` 的 500 是契约钉住的 worker-free 形态）。`/v1/models` 会把 `LMR_VIRTUAL_MODELS` 的别名一起广告出去（`created: 0`、`owned_by: llm-router-><target>`、按 id 升序、不覆盖真实 id） |
| 推理面 | `/v1/chat/completions` `/v1/completions` `/v1/embeddings` `/v1/rerank` `/v1/classify` `/v1/responses` `/generate` | 字节透传 + 顶层 `model` 定点改写；受 `SMG_MAX_CONCURRENT_REQUESTS` 限流（拒绝回 **429 空体**）。`/v1/responses` 是纯透传路由：非流式 2xx 时对响应顶层回填请求侧元数据六字段（`previous_response_id` / `instructions` / `metadata` / `store` / `model` / `safety_identifier`；`conversation` 不回显，它只对已删除的存储平面有意义），只做出站改写、不入库；流式只透传 |
| 控制面 | `POST /workers`（202 + Location）、`PUT /workers/{id}`（202，三键 `{status,worker_id,message}`）、`GET /workers[/{id}]`、`DELETE /workers/{id}`、`POST /flush_cache`、`GET /v1/loads` | `PUT` 可改 priority / cost / labels（合并）/ api_key / 健康旋钮，身份字段忽略；非 UUID → 400、未知 → 404、坏 JSON → 400。`worker_type` 与 `connection_mode` 收成单值：只有 `regular` 与 `http`（或其 serde 对象拼写、缺省）被接受，其它值一律 400。`/flush_cache` 向全部 worker POST `{}`（5s 超时），回 `{results:[{worker,status,result}], success, all_failed}`；`/v1/loads` 回 `{workers:[{worker,load}], total_workers, successful, failed}`（worker 侧非 2xx / 超时 / 缺字段记 -1）——两者与 Rust 形状不同，有意偏差 |
| mesh / HA 面 | `/ha/{status,health,workers[/id],policies[/id],config[/key],rate-limit,rate-limit/stats,stats,shutdown}` + `/_mesh/internal/{ping,sync,apply,state}` | `SMG_ENABLE_MESH` 未设（缺省）→ `/ha/*` 全部固定 503 `{"error":"mesh not enabled"}`；开启后委托 `mesh.dispatch`，未知的深路径回 404 `{"error":"unknown ha route: <METHOD> <path>"}`。`/_mesh/internal/*` 无鉴权无 loopback 围栏，**信任边界就是网络本身** |
| `/_ui` | 别名全家 + 静态 SPA + `/_ui/admin/` 管理台 | **无鉴权**；已注册路径的错误方法按 404 sink 回答 |
| 404 sink | 任意未注册路径（含已删的 `/v1/conversations*`、`/v1/tokenize`、`/parse/*` 等） | `{"error":{"type":"Not Found","code":"not_found",…}}` |

诚实表示「这实现没做」的路由只剩 **wasm 三条**：`POST /wasm`、`GET /wasm`、
`DELETE /wasm/{module_uuid}` → 501 `not_implemented`。另有 4 条 `/_ui/v1/*` 也回 501，Rust 对它们
同样回 `v1_ui_unsupported`，不构成缺口。

**CORS**：缺省全放开（常量响应头，与是否带 `Origin` 无关）；`SMG_CORS_ALLOWED_ORIGINS` 给列表后
只在 origin 命中时回显并收窄 Allow-Methods/Headers。预检 `OPTIONS` 在任何路由（含未注册路径）
都回 200，由 conf 的 server 级 `rewrite_by_lua_block` 在选定 location 之前提前应答——未注册路径的
预检在 Rust 侧是 404，这条保留为有意偏差。`/_ui` 也在 CORS 覆盖面里，比 Rust 宽。

## 环境变量

行为开关全部在 init 阶段读环境变量，模板里只有 nginx 解析期需要的量。默认值取自 Rust CLI 的
实际默认（不是 struct 默认）。

### server / 部署

| 变量 | 默认 | 说明 |
|---|---|---|
| `SMG_HOST` / `SMG_PORT` | `0.0.0.0` / `30000` | 监听地址。`SMG_PORT` 非数字或越界 = 启动失败 |
| `NGINX_WORKER_PROCESSES` | `auto` | **未显式设置且 `SMG_POLICY=cache_aware` 或 mesh 开启时入口改成 1**（基数树与 mesh 状态都是 per-process） |
| `NGINX_WORKER_CONNECTIONS` | `4096` | 同时决定 `worker_rlimit_nofile = 2×` |
| `SMG_MAX_PAYLOAD_SIZE` | `512m` | 裸数字自动补 `m` |
| `SMG_TLS_CERT_PATH` / `SMG_TLS_KEY_PATH` | 空 = 不启 TLS | 两者必须同时给且文件非空，否则启动失败；TLS 替换主监听的明文（同端口 `listen ... ssl`，TLSv1.2/1.3）。**独立 metrics 监听保持明文**，需要 TLS scrape 自行加反代 |
| `LR_UI_CONF` | 镜像内 ui.conf | 改成 `off` 关闭 `/_ui` include（路由面照常启动） |
| `LR_HTTP_INCLUDE` / `LR_SERVER_INCLUDE` | 空 | 额外 include 注入点 |
| `LR_ERROR_LOG_PATH` / `LR_LOG_LEVEL` | `/dev/stderr` / `warn` | `SMG_LOG_LEVEL` 是 Rust 名，优先于 `LR_LOG_LEVEL`，`trace` 归一到 `debug` |
| `SMG_PROMETHEUS_HOST` | `0.0.0.0` | 独立 metrics 监听的 bind 地址（IPv6 字面量由入口脚本加方括号） |
| `SMG_METRICS_PORT` / `LR_METRICS_PORT` | `29000`（Rust 名优先） | **缺省即开**独立抓取 server，只挂 `/metrics` 与 `/health`；`0` 关闭，`/metrics` 仍在主监听上 |
| `SMG_PROMETHEUS_DURATION_BUCKETS` | 空 = Rust 阶梯 | 逗号/空格分隔秒数。**进程生命周期内只读一次**：改桶宽后 `observe()` 在新宽度下重建（`_sum`/`_count` 仍正确） |
| `LR_INFLIGHT_SAMPLE_SECS` | `20` | 在途请求年龄采样间隔；`0` 关掉整个 tracker（不起定时器、三个 age 序列不渲染）。仅 worker 0 采样。见 [doc/gap-inflight-age.md](doc/gap-inflight-age.md) |
| `LR_INFLIGHT_TTL_SECS` | `3600` | 年龄槽位 TTL，即泄漏硬上界 |
| `AUTHZ_DNS_RESOLVER` | `/etc/resolv.conf` 首个 | 上游用域名时必须可达 |

### 策略

| 变量 | 默认 | 说明 |
|---|---|---|
| `SMG_POLICY` | `cache_aware` | 8 个合法值：`random` `round_robin` `power_of_two` `manual` `cache_aware` `bucket` `consistent_hashing` `prefix_hash`；**未知值静默归一到默认** |
| `SMG_CACHE_THRESHOLD` | `0.3` | cache_aware 前缀命中率门槛，越低越粘 |
| `SMG_BALANCE_ABS_THRESHOLD` / `SMG_BALANCE_REL_THRESHOLD` | `64` / `1.5` | 负载失衡双阈值，触发时暂时放弃亲和 |
| `SMG_MAX_TREE_SIZE` | `67108864` | 基数树容量上限 |
| `SMG_PREFIX_TOKEN_COUNT` / `SMG_PREFIX_HASH_LOAD_FACTOR` | `256` / `1.25` | prefix_hash（Lua 按字符数截断，Rust 按 token 数——已知口径差） |
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
| `SMG_POOL_IDLE_TIMEOUT_SECS` / `SMG_POOL_MAX_IDLE_PER_HOST` / `SMG_TCP_KEEPALIVE_SECS` | `50` / `500` / `30`（上游 cosocket 连接池；四键任一 <1 回落默认，`max_idle_per_host` 是每进程上限，N worker ⇒ N×M） |
| `SMG_REQUEST_ID_HEADERS` | 空（额外认作 request id 的请求头） |

按 worker 记录生效的健康旋钮只有三个：`SMG_HEALTH_FAILURE_THRESHOLD` / `_SUCCESS_THRESHOLD` /
`SMG_DISABLE_HEALTH_CHECK`（PUT /workers 可逐 worker 覆盖）；interval / timeout / endpoint 是全局
探测参数，worker 记录里只存不作用。

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
| `LMR_UI_DIR` / `LMR_UI_ROUTER_MODE` | 静态 SPA 目录（默认 `/usr/local/share/llama-ui`）/ 路由模式开关。`SMG_UI_DIR` 由入口脚本映射到 `LMR_UI_DIR`（两者同时给出时 `LMR_` 优先），裸 conf 直跑只认 `LMR_UI_DIR` |
| `LMR_REQUEST_LOG_CAPACITY` / `LMR_LOGS_BUFFER` | 请求日志环形缓冲容量，**`0` = 关闭，四个 `/_ui/logs*`/`stats` 转 503** |
| `LR_STATS_WINDOW_S` | `/_ui/stats` 的聚合窗口（缺省 10s）；空窗口的 `avg_*` 为 null |
| `LMR_PRICE_IN_PER_MTOK` / `LMR_PRICE_OUT_PER_MTOK` | `/_ui/stats` 与日志里的成本折算 |
| `LMR_TEST_PIPELINE` / `LMR_TEST_WORKERS` | 仅单测内省用 |

共享字典（conf 内声明，不能用 env 调）：`lr_workers 2m`、`lr_policy 20m`、`lr_stats 5m`、
`lr_request_log 20m`、`lr_locks 1m`、`lr_limit 64k`、`lr_watch`、`luarouter_config 1m`。
三个 conf（模板 / 裸 conf / 测试 conf）声明同一套。

### 并发限流与 CORS（默认全部关闭 / 全放开）

| 变量 | 默认 | 说明 |
|---|---|---|
| `SMG_MAX_CONCURRENT_REQUESTS` | `-1` | **`<=0` = 完全关闭限流**。>0 时是推理面 7 条路由的并发上限，`lr_limit` 计数，多 nginx 进程下是全局上限 |
| `SMG_QUEUE_SIZE` | `100` | 满额后允许排队的请求数；再满即拒。`0` = 不排队 |
| `SMG_QUEUE_TIMEOUT_SECS` | `60` | 排队等待上限，等待者 10 ms 轮询 |
| `SMG_RATE_LIMIT_TOKENS_PER_SECOND` | `0` = 跟随容量 | 令牌回补速率 |
| `SMG_CORS_ALLOWED_ORIGINS` | 空 = 全放开 | 空时常量头；给列表后只在 origin 命中时回显 |

限流只管推理面：公开面、控制面、`/_ui/*` 都不占令牌。拒绝回 **429 + 空体**；令牌在
`finish_request`（流式 pump 完）与 `on_log`（客户端中途断开）双点归还。

### watcher 服务发现（`SMG_WATCHER_ENABLED`，缺省关）

开启后 worker 0 定时器每 `SMG_WATCHER_INTERVAL_SECS`（15）做一轮 discover→probe→reconcile：
发现源三选可独立开关 `SMG_WATCHER_TARGETS`（逗号分隔 URL，可远程）/ `SMG_WATCHER_DOCKER`=1
（cosocket 读 /var/run/docker.sock）/ `SMG_WATCHER_PROC_SCAN`=1（纯 Lua 读 /proc/net/tcp）；
探针要求 `GET /v1/models` 回 OpenAI JSON 才注册。九条守卫与原 Python 版逐条等价，对照表与
偏差在 [doc/gap-watcher-merge.md](doc/gap-watcher-merge.md)。`POST /model-map` 兼容原版四种
body 形态做注册时改名。其余旋钮：`SMG_WATCHER_PROBE_TIMEOUT_SECS`(4)、
`SMG_WATCHER_REMOVE_GRACE_SECS`(300)、`SMG_WATCHER_MAX_MODELS`(8)、
`SMG_WATCHER_KEEP_LAST_GRACE_SECS`(1800)。指标：`lr_watch_*` 家族。

### mesh / HA 集群（`SMG_ENABLE_MESH`，缺省关）

`SMG_ENABLE_MESH=1|true|yes|on`，配 `SMG_MESH_PEERS`（逗号分隔）、`SMG_MESH_SELF`/`_SELF_ADDR`、
`SMG_MESH_SELF_NAME`、`SMG_MESH_SYNC_INTERVAL_SECS`（2）、`SMG_MESH_UNREACHABLE_TIMEOUT_SECS`（30）、
`SMG_MESH_SUSPECT_THRESHOLD`（2）、`SMG_MESH_MIN_CLUSTER_SIZE`（3）、`SMG_MESH_QUORUM`、
`SMG_MESH_RPC_TIMEOUT_MS`（2000）、`SMG_MESH_SNAPSHOT_MAX_BYTES`、`SMG_MESH_RATE_WINDOW_SECS`（1）。
开启且未显式给 worker 数时入口钉成 1（mesh 状态在进程内存）。无 peers 时打 WARN 且 `/ha/*`
保持 503（实例级降级而不是崩）。设计见 [doc/gap-mesh.md](doc/gap-mesh.md)。mesh 端口只能开在
可信网络里；单实例部署保持缺省关闭即可。

### DP 展开（`SMG_DP_AWARE`，缺省关）

`SMG_DP_AWARE=1` 时，一个 `/server_info` 报 `dp_size > 1` 的引擎展开成 `dp_size` 条
`<base>@<rank>` 记录（每条独立健康计数），转发前往请求体注入顶层整数成员 `data_parallel_rank`
（深度感知的 JSON 拼接，不改嵌套同名字段；顶层已存在则原位覆盖，不留重复键）。
`dp_size` 拿不到（`/server_info` 非 200 / 无该字段）时保持单条记录，探测有上限
（`registry.MAX_DP_ATTEMPTS` = 20）。展开发生在健康探测 2xx 之后——注册后的首个巡检周期内
engine 仍是单条 base 记录。关时逐字节不变。

## 测试

```bash
cd /path/to/lua-router
bash test/final_gates.sh                     # 快速档（缺省）：build/conf/unit/contract/probes，约 3 分钟
GATE_TIER=full bash test/final_gates.sh      # 全量 20 门（串行 12–17 分钟）
GATE_ONLY=contract bash test/final_gates.sh  # 单门（不受档位限制）；GATE_ORDER 见脚本头
KEEP_GOING=1 bash test/final_gates.sh        # 跑完并计数

bash test/test_lua_router.sh                 # 契约套件单独调试（独占约 2.5 min）
TEST_ONLY=workers bash test/test_lua_router.sh   # 单段调试
```

**门禁不可并发**：所有套件都是 host 网络 + 固定容器名前缀，两套房同跑会端口/容器名争用出假失败。
跑之前 `ps` 查一遍；测试容器名带 `lr-` 前缀，收尾 `docker ps -a | grep lr-` 清零。已知 flake：
`e2e_policy_parity` 的 random χ² 检验约 5% 假阳率（临界 5.991），失败先单独重跑该门。生产机上
proc 扫描会把门禁轮的 mock 短暂注册进生产池，跑完清一次（`GET /workers` 找 unhealthy 测试模型名
→ `DELETE /workers/{id}`）。

快速档绿只证明核心面（语法、单测、wire 契约、探针）；README/交接文档的计数更新、发版与生产
镜像替换必须以 `GATE_TIER=full` 的全绿日志为锚点。

单测两个口径（门禁已包含，用于调试单个模块）：

```bash
docker run --rm -v "$PWD:/repo:ro" -w /repo --entrypoint /usr/bin/resty \
  apache/apisix:3.11.0-debian -e 'package.path="/repo/lualib/?.lua;"..package.path
    dofile("/repo/test/unit/test_tree.lua")'     # 同法换其它文件
docker run --rm -v "$PWD:/repo:ro" -w /repo \
  -e LUA_TEST_LIB=/repo/lualib --entrypoint /usr/local/openresty/luajit/bin/luajit \
  authz:latest test/unit/test_mesh.lua           # 不依赖 ngx 的模块可 luajit 直跑
```

## 对拍与评测结论摘要

完整报告在 doc/parity-*.md 与 doc/real-eval.md，这里只给可直接引用的结论。

- **契约**（[doc/parity-contract.md](doc/parity-contract.md)）：33 组逐字段对拍，修后 MATCH 10 /
  DIFF 20 / INFO 3；其中 6 条是 Rust 侧不对（`/v1/rerank` 丢客户端 model、typed body round-trip
  丢未知字段等），Lua 不跟着改错。
- **路由行为**（[doc/parity-routing.md](doc/parity-routing.md) /
  [doc/parity-policy-extra.md](doc/parity-policy-extra.md)）：consistent_hashing 逐 key 落点完全
  相同（blake3 环位逐位兼容）；`worker_processes=4` 时 cache_aware 亲和率 1.000 → 0.625（树是
  per-process）；Rust HTTP 面 prefix_hash 恒 503、bucket 不可选属 Rust 侧缺陷，Lua 单边不变量全过。
- **性能**（[doc/parity-perf-v2.md](doc/parity-perf-v2.md)）：真实节流的流式三目标完全打平
  （差 <0.6%，净开销 ≤0.35 ms）；非流式高并发下 Rust 吞吐上限更高（Lua 约 85%）。**Lua 当前代码
  相较出厂镜像有 1.54x 的每请求 CPU 回退，已定责**（[doc/parity-cpu-ablation.md](doc/parity-cpu-ablation.md)：
  P1 请求日志行容量 0 仍整行构建 + P2 worker 记录表每请求 shdict 重建 5 次，合计约 45–65%）；
  修复排期前必须先跑同文 §8 的 R0 重测。内存：Lua 4 worker 69–91 MiB、`auto` 144 worker
  1.36–2.13 GB；Rust 110–146 MiB。所有组 err=0。
- **真实上游**（[doc/real-eval.md](doc/real-eval.md)）：三个真实模型 18/18 通过；prefix cache
  调度准确性成立（cache_aware 选工 52/52 无漂移，`cached_tokens`/prompt ≈ 97–99%）。限制：单
  worker URL 场景粘滞结论偏弱；真实上游的 token 字段对账在 usage 修复后没有重跑过。
- **指标覆盖**（基线 [doc/gap-metrics-final.md](doc/gap-metrics-final.md)）：对 Rust 实渲染 40 个
  家族覆盖 33（82.5%），缺的三条全是随 K8s 发现删除的 discovery 家族；Lua 独有超集 4 条。
  契约 `prometheus` 段（14 项）钉住家族名与 HELP 完整性。

## 已知限制索引

- **有意偏差 / 架构限制**：`/flush_cache` 与 `/v1/loads` 响应形状、404 带 JSON 体、
  `/v1/*` 与已注册路径的错误方法是 404 而 axum 是 405+Allow、CORS 覆盖面比 Rust 宽、排队超时
  回 429 而 Rust 回 408、`PUT` 同步生效、`cost` 编不出 `1.0`、`/ha` 深路径 404 措辞、
  cache_aware 基数树 per-process（多 worker 时亲和率按进程数摊薄）、
  `smg_worker_routing_keys_active` 与 `smg_router_tpot_seconds` 的语义差。
- **剩余可行动缺口**：① 非流式 1.54x CPU 回退的修复落地（定责完成，剩 R0 重测与按嫌疑榜修复）；
  ② TLS 入口对证书/私钥不配对与 leaf 缺中间证书的预检（现状 `openresty -t` 放行、握手才失败，
  路线在 [doc/gap-tls-chain.md](doc/gap-tls-chain.md) §5/§6）；③ mTLS 客户端证书鉴权未实现
  （e2e_tls_chain 已实测）；④ watcher 扫描污染根治（proc 扫描需要端口黑白名单或 GPU 负载门禁
  标签，以区分测试 mock）；⑤ UI 会话历史页（history 平面已删，原版 webui 的会话页待下次 UI
  升级摘除）；⑥ GPU↔worker 映射靠 host（同机独立多卡会共享读数，见
  [doc/gap-gpu-load.md](doc/gap-gpu-load.md)）。
- **TODO 不实现**（用户指示 2026-09-30）：MCP server 调用、wasm 中间件，唯一口径
  [doc/todo-deferred.md](doc/todo-deferred.md)。引用时不要写成「在接」「排期中」：`/wasm` 三条
  路由固定 501，`smg_mcp_*` 四条家族刻意不注册。

判定某个模块是否真的接进了请求路径，最快的一条命令：

```bash
grep -rn 'require "resty.luarouter.<模块>"' lualib/resty/luarouter/router.lua \
  lualib/resty/luarouter/init.lua conf/
```

## 文档索引

doc/ 现状文档 20 份。裁剪前平面的历史留档（feature-gap、verification、impl-*、fix-majors、
gap-{grpc,history,tokenizer,otel,discovery-watch,dp-jwt,auth-tls,http-semantics,core,integration,
test-gates}、wasm-feasibility、parity-perf v1）已于 2026-10-01 随文档精简删除，需要时查 git 历史。

| 文档 | 内容 |
|---|---|
| [doc/agent-handover.md](doc/agent-handover.md) | **agent 交接说明**：现状速览、测试纪律、设计红线、生产操作清单、缺口与文档地图（新接手先读它） |
| [doc/architect.md](doc/architect.md) | 架构总览：运行时模型、请求生命周期、模块地图、共享状态、策略、部署与测试框架 |
| [doc/scope-trim.md](doc/scope-trim.md) | 范围收敛判定书：模块 KEEP/DELETE/TRIM、量化收益、执行记录 |
| [doc/todo-deferred.md](doc/todo-deferred.md) | TODO 档（MCP、wasm）的唯一口径与启用时的最小方案 |
| [doc/gap-mesh.md](doc/gap-mesh.md) | mesh / HA 的 CRDT 设计、带宽代价与围栏 |
| [doc/gap-mesh-final.md](doc/gap-mesh-final.md) | `/ha/status` 幻影键根因与真修 + 双真节点 e2e |
| [doc/gap-watcher-merge.md](doc/gap-watcher-merge.md) | watcher 合并入进程：三源发现、九条守卫对照、env 映射与偏差 |
| [doc/gap-gpu-load.md](doc/gap-gpu-load.md) | GPU 负载源：metrics 抓取与远程 Prom 查询两路、优先级与 TTL |
| [doc/gap-routing-dyn.md](doc/gap-routing-dyn.md) | 路由动态变更：policy/model_policies 热配置与优先级链 |
| [doc/gap-token-accounting.md](doc/gap-token-accounting.md) | 流式 token 核算：include_usage 注入/剥帧、四类 token 指标 |
| [doc/gap-inflight-age.md](doc/gap-inflight-age.md) | 在途请求年龄采样：槽表、TTL 与 Rust 语义偏差 |
| [doc/gap-metrics-final.md](doc/gap-metrics-final.md) | Prometheus 家族覆盖率口径基线 + `smg_worker_pool_size` 修复 |
| [doc/gap-tls-chain.md](doc/gap-tls-chain.md) | 证书链 / SNI / 握手负例门与入口预检缺口 |
| [doc/gap-virtual-models.md](doc/gap-virtual-models.md) | 虚拟 model profile 与 upstreams 持久化接入 |
| [doc/parity-cpu-ablation.md](doc/parity-cpu-ablation.md) | 1.54x CPU 回退定责与消融实验计划 |
| [doc/parity-contract.md](doc/parity-contract.md) | 契约对拍原始报告（33 组） |
| [doc/parity-routing.md](doc/parity-routing.md) | 路由行为对拍原始报告 |
| [doc/parity-policy-extra.md](doc/parity-policy-extra.md) | prefix_hash/bucket/power_of_two/random 对拍原始报告 |
| [doc/parity-perf-v2.md](doc/parity-perf-v2.md) | 性能对拍原始报告（当前代码口径） |
| [doc/real-eval.md](doc/real-eval.md) | 真实上游端到端评测与 prefix cache 调度准确性 |
