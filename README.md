# lua-router

LLM 推理网关的 OpenResty/Lua 实现：**多 GPU 服务的服务发现与请求调度器**。上游是任意
OpenAI 兼容实例（llama.cpp / vLLM / SGLang），只接受 `http://` 与 `https://`。它只做转发：
不加载模型、不做推理、不存会话；流式响应零缓冲透传，推理体只做顶层精确改写（model /
stream_options / effort），不整表重编码。调用方给的输出预算（`max_tokens` /
`max_completion_tokens` / 以及 `/v1/responses` 用的 `max_output_tokens`）原样透传，网关既不改写
也不替它决定（用户裁定 2026-10-04）。虚拟模型入口是对下游的服务主入口，一个入口用 `targets`
1 对多映射一组实际模型，由调度策略在整组内选路。

与 Rust 版 `smg` 网关（llm-router 仓库 `gateway/`）的关系是**行为对拍**（同请求 → 同状态码 /
同错误体形状 / 同策略指标），对拍报告见 doc/parity-*.md 与 doc/real-eval.md。2026-10-01 按用户
裁定执行范围裁剪（[doc/scope-trim.md](doc/scope-trim.md)）：gRPC/PD、history 存储、tokenizer/parse
代理、网关自身鉴权、Kubernetes 服务发现、OTel 六个平面整体删除（git 历史可恢复）；mesh、
DP 展开、服务端 TLS 保留。TODO 不实现：wasm、MCP（唯一口径 [doc/todo-deferred.md](doc/todo-deferred.md)）。

**信任边界**：网关层零鉴权——`/workers`、根数据面（`/config` `/logs` `/stats` `/props`）、`/model-map`、`/ha` 与推理面全部开放，
只可部署在 authz 边缘之后或可信内网。worker 记录里的 `api_key` 是本路由向**上游**出示的
凭据，不是挡在自己前面的门。

## 当前基线

全量门禁权威日志：`/data/tmp/lr-gates/gates-20261008-080618.log`（tier=full、`KEEP_GOING=1`、
`SKIP_ENV=none`，**22 passed / 0 failed / 0 skipped**，代码基线 `71ac5d4`）。代码基线：
`lualib/` **75 个 Lua 文件 / 36 110 行**（七个域拆成 facade + 子模块，见 doc/architect.md §3）、
单测 16 文件、契约 **691 项 / 24 段**、文档 30 份。

> 锚点取在 2026-10-05 的重构树上：facade + 子模块拆分（router / config_store / registry /
> watcher / gpu_load / mesh / observability）+ 公共传输库 `httpc.lua` + UI 入口迁移
> （`/_ui/`→`/u/`、`/_ui/admin/`→`/a/`）全部计入同一份全绿日志，见
> [doc/refactor-arch-2026-10-05.md](doc/refactor-arch-2026-10-05.md)。上一版锚点（2026-10-03）
> 遗留的 `[ctx cap]` 断言失效问题也已随 2026-10-04 裁定在测试侧清干净。
> 2026-10-08 admin 迁根（用户裁定，现役口径见下文页面入口表）：管理台入口是站点根 `/`，由 `conf/nginx.conf.template` 的 `location /` 提供（root 落到 `<LMR_UI_DIR>/admin/`，try_files 未命中回落 `@lmr_klib`）；旧 `/a`、`/a/` 各 302 到 `/`。
> `/u/` webui 一行未动；`/_ui/*` 全部取消（落 404 sink，唯一例外是 klib 路由表里的 `/_ui/logs`、`/_ui/stats`、`/_ui/logs/backends`）；管理台数据面搬到根：`/config*`、`/logs*`、`/stats`、`/props`。
>
> 当前锚点（2026-10-06）在重构树之上再叠一轮**容量语义重设计**（用户裁定）：并发上下限三态 +
> GPU 利用率上限取代功率上限 + 绿灯优先选路 + 全池到顶 429，契约新增 `caps` 段（25 项）。执行契约见
> [doc/caps-redesign-2026-10-06.md](doc/caps-redesign-2026-10-06.md)，实现口径见
> [doc/gap-worker-caps.md](doc/gap-worker-caps.md)。

| 门禁 | 计数 | 覆盖 |
|---|---|---|
| build / conf | — / 2 语法 OK | 镜像构建（含一次 `openresty -t`）；生产模板 + 裸 conf 双语法门 |
| unit | luajit 15 + resty 4 口径 | luajit 侧 tree 67 / tree_bounds 44 / state_bounds 51 / observability 35 / policies 118 / hash 795 / mesh 391 / watcher 425 / gpu_load 402 / routing_dyn 122 / profiles 907 / caps_routing 157 / models_shape 124 / models_advertise 74 / effort_layers 32；resty 侧 tree 67 / policies 118 / hash 795 / integration 125（全部 0 failed） |
| contract | **691 / 0 failed / 2 notes** | 24 段 wire 契约（分段构成见 `test/test_lua_router.sh` 头部；`discovery` 段测的是 `/model_info` 元数据发现，与已删除的 K8s 发现无关） |
| probes | 26 / 0 | 策略工厂、配置旋钮、map 切分、裸 JSON 改写、卡片档位 env 层穿透 worker |
| e2e_stateful | 101 / 0 | bucket / prefix_hash / manual / failback / 快照 / 多进程 / add worker / responses 元数据回填与断开语义 + DP 展开 31 项 |
| e2e_policies | 65 / 0 | 各策略真流量 + 虚拟别名与 effort 注入 |
| e2e_ui_bridge | 26 / 0 | `/v1` 与 `/u/` 两条路径改写一致 |
| e2e_errors | 10 / 0 | `/u/` 别名的 503/502/上游 4xx 契约 |
| e2e_effort | 65 / 0 | effort 强制、per-model 卡片、档位三层继承与停用字段的往返 |
| head_routes | 108 / 0 | HEAD 镜像每个 GET 路由 |
| mesh_http / mesh_two | 47 / 37 | mesh 真实 HTTP（对端 apply/sync、worker 镜像、/ha/policies）；双真容器互 seed 收敛、docker stop 分区恢复、retire 广播 |
| e2e_policy_parity | 47 / 0 | prefix_hash / bucket / power_of_two / random 与 Rust 的量化对拍（Rust 启动等待预算 240s） |
| e2e_watcher | 108 / 0 | 内建 watcher：三源发现、九条原守卫逐条断言 + 第 10 条守卫（探针确认不可用即摘除，含滞回与单轮保险丝）、model-map 改名、容器重启重发现 |
| e2e_profiles | 110 / 0 | 虚拟服务入口与 upstreams：白名单 / 入口名走按模型策略（`model_policies[入口名]` 是别名级 policy 停用后的替代入口）/ 停用字段仍接受、仍落盘、解析时 warn 而热路径不读 / api_key 三态与脱敏 / 30s 自愈 / apply 原子性 |
| e2e_token_accounting | 62 / 0 | 流式 include_usage 透明注入+剥帧、四类 token 指标、400 兜底 sticky |
| e2e_gpu_load | 58 / 0 | GPU 负载双源：worker /metrics 抓取与远程 Prometheus 查询写入 registry（mock 的 /metrics 带 `gpu` 标签，利用率通道走同一条路；逐卡归属与容量判定的断言在 e2e_caps S3/S3b） |
| e2e_routing_dyn | 51 / 0 | 路由动态变更：全局与 per-model 策略热切换免重启、非法名 400 不生效 |
| e2e_caps | 175 / 0 | 虚拟模型入口映射一组实际模型（不同上游的相同/不同模型、IGW 开关两路、candidates 与 workers 交集语义）+ 每服务容量三态（S2 三态与 `load_state`、S3/S3b GPU 利用率上限与**逐卡归属**、S4 亲和被打断、S5 全池到顶 **429**、S5b 对照 503、S5c 缺省零变化、S5d 声明层三字段边界、S6 功率通道开关可见性、S8 caps 跨重启存活；读数缺失不排除、上限不摘健康） |
| e2e_models_advertisement | 210 / 0 | `/v1/models` 对外形状（官方四字段 required、扩展字段来源优先级、组内聚合与「缺读数即删键」）+ 「只广告虚拟入口」开关 + S12 卡片档位勾选（探测基线 / 勾选接管 / 判定面只跟引擎说过的） |
| e2e_tls_chain | 112 / 0 / 2 notes | 运行时 PKI、四类握手负例、RSA+ECDSA×TLS1.2/1.3、SNI 同端口双证书、证书/私钥不配对 fail-closed |

契约 691 的 24 段构成：gate 3、public 34、workers 75、inference 38、headers 13、mesh 44、
not_found 15、observability 53、proxy_endpoints 56、policy_hint 13、ui_fixed 69、tls_upstream 11、
cb_race 6、igw 7、caps 25、discovery 5、prometheus 14、probes 29、cors 37、virtual_models 15、
ratelimit 14、inflight_age 32、tls_server 19、profiles_upstreams 64。

## 目录

| 路径 | 内容 |
|---|---|
| `conf/nginx.conf.template` | 生产模板，由入口脚本 envsubst 渲染（listen / worker 数 / 日志 / 注入点 / `TLS_SERVER_EXTRA`） |
| `conf/lua-router.conf` | 同一套配置的裸字面量版本，不经入口脚本直接 `openresty -c` 用于验证与最小部署 |
| `conf/ui.conf` | 全部 UI location：`/u/*` 的精确 API 别名与 `/u/` 静态 + 302、`/a`、`/a/` 的兼容 302、管理台数据面在根上的 exact 别名族（`/config*`、`/logs*`、`/stats`）、原版 webui 所需端点的根挂载，由入口脚本按存在性 include 进 server{}；admin 静态本体在 `conf/nginx.conf.template` 的 `location /`（root = `<LMR_UI_DIR>/admin/`，try_files 未命中回落 `@lmr_klib` 走 klib 路由表） |
| `docker-entrypoint.sh` | env 校验 → envsubst → `openresty -t` → exec；缺省策略 `cache_aware`；cache_aware 或 mesh 开启且未显式给 `NGINX_WORKER_PROCESSES` 时把 worker 数收到 1；渲染独立 metrics 监听（缺省 `:29000`，`SMG_METRICS_PORT=0` 关闭） |
| `Dockerfile` | `FROM authz:latest`，COPY lualib / 模板 / entrypoint / ui.conf / `ui/`→`/usr/local/share/llama-ui`，构建期跑一次 `-t` 门 |
| `lualib/resty/luarouter/` | 实现（75 个 .lua / 36 110 行，`wc -l` 实测）：七个域是「facade + 同名子目录」——router(364)+12 子模块、config_store(133)+10、registry(174)+7、watcher(65)+7、gpu_load(80)+6、mesh(59)+5、observability(1469)+2，另有公共传输库 httpc.lua 与未拆的单文件（policy / policies 6 文件 / hash / hb / init / config / ui / props / limit / store_*），全部接进请求路径；模块地图见 doc/architect.md §3 |
| `ui/` | 原版 llama.cpp webui（规范入口 `/u/`）+ `ui/admin/`（Quasar UMD 管理台四页，规范入口 `/`（站点根，由模板的 `location /` 提供）：模型管理 / 服务池 / 路由策略 / 日志监控，中英双语；原「远程服务 / 服务接入」页已并入服务池）；`admin-inject.js` 向原版 webui 注入 Admin 入口（href 指 `/`；旧根目录工具页 logs/metrics/config 已移除，差异见 `doc/ui-trim-legacy-pages.md`）。控件纪律：本仓 vendor 的 Quasar UMD 里 QToggle / QOptionGroup 不经 BaseField 渲染，`:hint` 不生成 `.q-field__bottom`，说明文字只能并进 `:label` |
| `test/final_gates.sh` | 22 门硬门（`GATE_TIER` / `SKIP_ENV` / `GATE_ONLY` / `KEEP_GOING` / `GATE_JOBS` / `GATE_DRY_RUN`） |
| `test/test_lua_router.sh` | 契约套件（严格模式，第一个 FAIL 即退出），24 段 |
| `test/unit/` | 纯 Lua 单测 16 个文件，`luajit`(authz) 与 `resty`(apisix) 两个口径（tree/policies/hash 双跑） |
| `test/integration/` | 真容器 e2e：stateful / policies / ui_bridge / errors / effort / probes / head_routes / mesh_http / mesh_two / policy_parity / tls_chain / watcher / token_accounting / gpu_load / routing_dyn / profiles / caps / models_advertisement（`models_advertisement` 钉 `/v1/models` 的对外形状，2026-10-04 随第 22 门加入 GATE_ORDER） |
| `test/mock_llm_worker.py` | 纯标准库 mock worker，含 `echo_body` / `echo_headers` 取证 |
| `doc/` | 现状文档 30 份（架构 / 交接 / 裁剪判定 / 各能力设计与对拍报告），索引见文末；裁剪前平面的历史留档已于 2026-10-01 清理，git 历史可查 |

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
| 公开面 | `/health` `/liveness` `/readiness` `/v1/models` `/model_info` `/server_info`（各有 GET 与 HEAD 别名）、`/metrics`、`/engine_metrics`、`/health_generate` | 200；`/readiness`、`/v1/models`、`/health_generate`、`/engine_metrics` 在无可用 worker 时分别回 503 / 503 / 503 / 500（`/engine_metrics` 的 500 是契约钉住的 worker-free 形态）。`/v1/models` 每条带齐官方四字段，另附 `capabilities` 扩展（形状、字段来源与优先级见下文〈`/v1/models` 的模型对象形状〉）；虚拟服务入口一并广告：单模型入口 `owned_by: llm-router-><model>`、多模型入口 `owned_by: llm-router` + `owned_by_models`，按 id 升序、不覆盖真实 id |
| 推理面 | `/v1/chat/completions` `/v1/completions` `/v1/embeddings` `/v1/rerank` `/v1/classify` `/v1/responses` `/generate` | 字节透传 + 顶层 `model` 定点改写（虚拟入口转发的是选中候选的绑定名，不是入口名）；**输出预算三写法一律原样透传**——`max_tokens` / `max_completion_tokens` / `/v1/responses` 用的 `max_output_tokens` 都由调用方决定，网关既不改小也不在缺失时代填（用户裁定 2026-10-04），所以引擎拒的一定是调用方自己要的数；受 `SMG_MAX_CONCURRENT_REQUESTS` 限流（拒绝回 **429 空体**）。请求日志行的 `model` 是入口代表值，**实际落点模型看 `forwarded_model`**，调用方给的那个输出预算记在日志行的 `output_budget`（修复后恒等于请求原值）；组入口（显式写过 `targets`）被健康引擎一致拒绝整组模型名时，503 message 是「No available workers (N healthy engines serve none of the mapped models)」，与「全部熔断或不健康」分开定性。**全池都抵在容量上限上**时（每台都 `load_state=full`、一个候选都不剩）答 **429**：`error.code` 仍是 `no_available_workers`、`error.type` 随状态码为 `Too Many Requests`、message 精确为「No available workers (N at their concurrency or GPU-util limit)」——容量到顶是「暂时不接单」不是「服务不可用」（用户裁定 2026-10-06），熔断/不健康/组不服务仍是 503 原句，两种处置相反（抬上限 vs 查实例）。`/v1/responses` 是纯透传路由：非流式 2xx 时对响应顶层回填请求侧元数据六字段（`previous_response_id` / `instructions` / `metadata` / `store` / `model` / `safety_identifier`；`conversation` 不回显，它只对已删除的存储平面有意义），只做出站改写、不入库；流式只透传 |
| 控制面 | `POST /workers`（202 + Location）、`PUT /workers/{id}`（202，三键 `{status,worker_id,message}`）、`GET /workers[/{id}]`、`DELETE /workers/{id}`、`POST /flush_cache`、`GET /v1/loads` | `PUT` 可改 priority / cost / labels（合并）/ api_key / 健康旋钮 / **每服务容量三字段 `min_concurrency`（并发调度下限，整数 1..31）/ `max_concurrency`（并发调度上限，整数 1..32）/ `max_gpu_util`（GPU 利用率上限，整数百分比 0..100）**，身份字段忽略；非 UUID → 400、未知 → 404、坏 JSON → 400；退役的 `max_power_w` 与任何未知字段一样被忽略。`GET /workers` 每条带 `models`（该实例真实广告过的模型，主模型恒居首）、`inflight_requests`（纯在飞数，并发档的比较对象）、`gpu_util`（该 worker 自己那张卡的 0..1 新鲜利用率，**缺席=未知**）、`power_w`（新鲜瓦特读数，**缺席=未知**；纯观测，不参与任何容量判定）、三个已归一的上限，以及**判定结果本身** `load_state`（`idle`/`busy`/`full`，由 `registry.capacity_state` 一处算出；**这台没声明任何上限时该键整个缺席**，不是 null——前端只读不重算）；未声明的上限字段**缺席而不是 0**（利用率档的 0 是最严档，不是清除）。`metadata` 里带 watcher 解析出的 `gpu` 卡号（容器名 `…-gpu0`..`…-gpu7` 或进程 `--device-id` / `CUDA_VISIBLE_DEVICES`），管理台据此在实例名后画 GPU 徽章。`worker_type` 与 `connection_mode` 收成单值：只有 `regular` 与 `http`（或其 serde 对象拼写、缺省）被接受，其它值一律 400。`/flush_cache` 向全部 worker POST `{}`（5s 超时），回 `{results:[{worker,status,result}], success, all_failed}`；`/v1/loads` 回 `{workers:[{worker,load}], total_workers, successful, failed}`（worker 侧非 2xx / 超时 / 缺字段记 -1）——两者与 Rust 形状不同，有意偏差 |
| mesh / HA 面 | `/ha/{status,health,workers[/id],policies[/id],config[/key],rate-limit,rate-limit/stats,stats,shutdown}` + `/_mesh/internal/{ping,sync,apply,state}` | `SMG_ENABLE_MESH` 未设（缺省）→ `/ha/*` 全部固定 503 `{"error":"mesh not enabled"}`；开启后委托 `mesh.dispatch`，未知的深路径回 404 `{"error":"unknown ha route: <METHOD> <path>"}`。`/_mesh/internal/*` 无鉴权无 loopback 围栏，**信任边界就是网络本身** |
| `/`、`/u/` 与 `/a` | 页面入口：`/` = 管理台四页（模型管理 / 服务池 / 路由策略 / 日志监控，按使用频度排序；由 `conf/nginx.conf.template` 的 `location /` 提供，root 指向 `<LMR_UI_DIR>/admin/`，try_files 未命中回落 `@lmr_klib` 走 klib 路由表），`/u/` = 原版 llama.cpp webui（入口不变）。旧入口 `/a` 与 `/a/` 各 302 到 `/`（相对引用 + no-store）；**`/_ui/*` 全部取消**：无 302、无别名、无静态块，落 404 sink（唯一例外：`/_ui/logs`、`/_ui/stats`、`/_ui/logs/backends` 仍在 klib 路由表里）。管理台数据面在根上的 exact 别名族：`/config`、`/config/{effort,ctx,model,virtual,upstreams,policy,apply,model-map}`、`/logs`、`/logs/stream`、`/logs/backends`、`/stats`。原版 webui 所需端点已**根挂载**：`/props` `/slots` `/tools` `/models/load` `/models/unload` `/models/sse` `/v1/stream` `/v1/streams/lookup` `/v1/chat/completions/control` `/properties` | **无鉴权**；已注册路径的错误方法按 404 sink 回答 |
| 404 sink | 任意未注册路径（含已删的 `/v1/conversations*`、`/v1/tokenize`、`/parse/*` 等） | `{"error":{"type":"Not Found","code":"not_found",…}}` |

诚实表示「这实现没做」的路由只剩 **wasm 三条**：`POST /wasm`、`GET /wasm`、
`DELETE /wasm/{module_uuid}` → 501 `not_implemented`。另有 4 条 webui 端点（`/v1/stream`、`/v1/chat/completions/control` 及其 `/u/` 同名别名）也回 501，Rust 对它们
同样回 `v1_ui_unsupported`，不构成缺口。

**CORS**：缺省全放开（常量响应头，与是否带 `Origin` 无关）；`SMG_CORS_ALLOWED_ORIGINS` 给列表后
只在 origin 命中时回显并收窄 Allow-Methods/Headers。预检 `OPTIONS` 在任何路由（含未注册路径）
都回 200，由 conf 的 server 级 `rewrite_by_lua_block` 在选定 location 之前提前应答——未注册路径的
预检在 Rust 侧是 404，这条保留为有意偏差。根数据面（`/config*` `/logs*` `/stats`）与 `/u/*` 也在 CORS 覆盖面里，比 Rust 宽。

## `/v1/models` 的模型对象形状

实现是 `router/models_api.lua` 的 `models_handler` → `advertise_real_model` /
`advertise_virtual_entry` → `fill_model_fields`。对外列表里的模型名来自 `registry/records.lua` 的
`models()`——它是 Rust 对拍钉住的那一列，
只取每条 worker 的**主模型** `model_id`，因此一台引擎广告多个名字时只有主模型出现在这里
（多广告的那些走同文件的 `all_models()` / `worker_models()`，目前无人消费，见 doc/gap-worker-caps.md §11）。
虚拟入口由同文件的 `inject_virtual_models` 追加：入口名与某个真实 worker 同名则丢弃别名，
最后整表按 id 升序。无可用 worker 时整个响应是 503 纯文本 `No models available`（不是 JSON——Rust 侧只重写带
`data` 数组的响应，这个文本答案原样透传，见 `models_handler` 的 worker-free 分支）。

### 第一层：官方四字段，四个都是 required

OpenAI 官方 `/v1/models` 的模型对象**只有** `id` / `object` / `created` / `owned_by`，四个都 required。
真实模型那一支以前只有三个（整个漏了 `created`），属于不合规，现在每条带齐。`created` 取上游答里的
读数，取不到用 `router/models_api.lua` 顶部的常量 `MODEL_CREATED_UNKNOWN = 0` 表示「未知」，与虚拟入口一直的写法
相同；**刻意不塞 `ngx.time()`**——那会让同一条目每次请求产出不同字节，把客户端缓存和前后对比全打掉。

### 第二层：`capabilities` 命名空间 + 顶层三个 effort 键（都不是官方字段）

`capabilities` / `reasoning_effort` / `reasoning_efforts` / `max_output_tokens` / `owned_by_models`
是 vLLM、opencodex 这类服务器自加的生态扩展，各家形状还不一样。收在 `capabilities` 下面是与官方四字段的
物理隔离，官方 SDK 只读它认识的四个；顶层那三个（`supports_reasoning_effort` / `reasoning_effort` /
`reasoning_efforts`）沿用 opencodex 已经在用的位置，让照它写死的客户端继续照旧读。

| 位置 | 键 | 含义 |
|---|---|---|
| 顶层 | `supports_reasoning_effort` | 有任一份档位读数（阶梯 / 判定面 / 缺省档）才是 `true`，否则整个键省略 |
| 顶层 | `reasoning_effort` | 缺省档位（picker 预选那一档），字符串 |
| 顶层 | `reasoning_efforts` | 客户端 picker 的档位阶梯 `[{value,label,default}]`；`label` 只在引擎给了才写，`default` 恒唯一 |
| 顶层 | （勾选接管） | 同一位置的成员与顺序可由**模型卡片 `reasoning_efforts`** 决定：操作员勾了哪几档就报哪几档，顺序即勾选顺序；`label` 仍逐档继承引擎说过的那份，引擎没提过的名字（手动补的 `xhigh`）不编 label。见〈档位阶梯：探测 + 手动勾选〉 |
| `capabilities` | `context_length` | 上下文**总窗口（输入+输出）**，两档来源：操作员声明的窗口（卡片 `ctx` / 平铺 `model_ctx`，经 `store_mod.ctx_cap`）**优先于**引擎自报，两者都没有就整个键省略（用户裁定 2026-10-08：原卡片字段 `context_limit` 不再冒充这一维） |
| `capabilities` | `max_output_tokens` | **声明给下游 agent 的单次最大输出 token 数**＝纯对外 advertisement：操作员声明（卡片 `model_configs[].max_output_tokens` > 平铺 `model_max_output_tokens`，`router/models_api.lua` 的 `declared_max_output_tokens`）**优先于**引擎自报 `caps.max_output_tokens`，两边都没说就整个键省略。它不参与任何校验、钳制或 max_tokens 运算，也绝不构成网关改写调用方预算的依据——输出预算三写法原样透传（用户裁定 2026-10-04） |
| `capabilities` | `input_modalities` / `output_modalities` | 去重的非空字符串数组 |
| `capabilities` | `supports_tool_use` / `supports_streaming` / `supports_reasoning` / `supports_vision` | 支持位，三态：`true` / `false` / 整个键省略 |
| `capabilities` | `reasoning_effort` | 引擎**接受**的档位判定面，字符串数组（与顶层同名字段是两个含义，各画各的）；操作员勾过时它是「引擎说过 ∩ 勾选集合」——**只收窄不扩面**，勾选表里引擎没提过的名字不会在这里被替它宣称接受 |
| 顶层 | `owned_by_models` | 多目标入口的整组模型名数组 |

档位在上游有两种拼写、两个含义，registry 刻意各留一份、输出面各画各位：picker 的阶梯带 label 与
`default`，判定面是下游真正接受的集合。**不把阶梯里的档位虚构进判定面**——判定面优先用引擎亲口给的
`reasoning_effort_values`，只有它缺席时才退到阶梯序列（`router/models_api.lua` 的 `fill_model_fields`）。实测样例里两份就不一致：
阶梯 `low/medium/high/max`，判定面只有 `low/high/max`；取交集会连 `medium` 身上那个 `default=true` 一起
丢掉，客户端反而没有缺省档可用，取并集又会报出下游可能不接受的名字，所以两份都留、各画各位。
单目标入口透传引擎原话（含「缺省档不在判定面里」这种上游自带的自相矛盾）；多目标入口的判定面取交集，
交集把缺省档挤掉就整个删键（同文件的 `common_acceptance`）。

### 档位阶梯：探测 + 手动勾选（用户诉求 2026-10-08）

上游允许的 `reasoning_effort` 档位（`low` / `medium` / `high` / `xhigh` / `max` …）先由网关**探测**出来，
再由操作员在管理台**逐档勾选**增删，勾选结果反馈进 `/v1/models` 的对外声明。三份读数各有其主，不可互换：

| 读数 | 来源 | 谁读它 |
|---|---|---|
| 引擎原话 | `registry.model_caps()`（健康巡检顺带 `GET /v1/models` 采到的 `reasoning_efforts` / `capabilities.reasoning_effort`） | 管理台勾选框的**基线**（`/config` 的 `models[].detected_reasoning_efforts`）、判定面的唯一来源 |
| 操作员勾选 | 模型卡片 `model_configs[].reasoning_efforts`（平铺 env `LMR_MODEL_EFFORT_LEVELS`） | 决定对外 `reasoning_efforts`（picker）的成员与顺序 |
| 对外读数 | `/v1/models` 合成结果 | 客户端看到的 picker、`supports_reasoning_effort` 的派生、`capabilities.reasoning_effort` 判定面 |

基线**必须**取引擎原话而不是对外那份读数：对外读数一旦被勾就是勾选结果，拿它当基线会把操作员上一轮的
勾选误读成「引擎说的」，于是取消勾选永远回不到引擎原始那一组。这是 `detected_reasoning_efforts` 与
`reasoning_efforts` 在 `/config` 里分家存在的全部理由。

**勾选接管的是 picker，不是判定面。** 判定面（`capabilities.reasoning_effort`）取「引擎说过 ∩ 勾选集合」，
只能收窄不能扩面：勾掉一档是把引擎说过的事情少报一件（与旁边「组内取最窄」同方向的保守），而把引擎从没提过的
名字（手动补的 `xhigh`）写进判定面，等于替引擎宣称它接受一个它没说过的档位——那正是硬规则 9 第 2 条禁止的猜。
这种名字照旧进 picker（用户要的就是给欠配置的上游补档位），只是不进判定面。引擎压根没给判定面时，判定面退到
勾选序列（与原来「退到阶梯序列」同一支路，序列换成了操作员那份）。

三态与形状的其余口径：

* 卡片没这张卡 / 键沉默 = 「没说」，两份读数全部让位引擎自报（与 `supports_*` 那五位同一条声明链）。
  `null` = 清除回自动（管理台的「恢复自动」发的是它），数组 = 整条替换。
* **空数组折回「没说」**：勾选全部取消等同从没勾过，对外退回引擎那一组，磁盘上不落 `[]`。热路径对空表答的
  也是「没说」（`card_ladder` 与 `clean_string_list` / `clean_effort_ladder` 同一口径——报一份 `[]` 是一份
  「一个都不支持」的肯定答复），若磁盘留 `[]` 就成了同一份配置两种说法。
* `label` 由**引擎**决定：勾选只决定成员与顺序，每一档的 `label` 仍从引擎那份同名档位继承（一次勾选不该毁掉
  别的字段），引擎没给过的名字不编 label。
* `default` 至多一枚：勾选表上的预选（管理台「设为缺省档」下拉）优先，但让位 `model_effort` 强制行与卡片
  `default_effort` 这两条专职字段；勾选表没标预选时继承引擎自己标的那一档（前提是该档仍在勾选集合里）。
* 顺序按**勾选顺序**，后端不按词表重排：阶梯就是客户端 picker 的显示顺序，替他重排等于改他的声明。
* 未知档位名（`turbo`）整条拒绝并 400，不悄悄丢档——一个拼错的名字会被客户端原样发给引擎并在那里 400，
  比保存失败难查得多。
* 虚拟入口（1 对多）仍按组内一致口径仲裁：成员间勾选表序列不一致 → 入口行的 picker 整个删键（`common_ladder`
  原有的规则，勾选不放宽它）；判定面照旧逐成员收窄后取交集。
* 勾选只改对外声明，**不改转发**：客户端照这里发 `reasoning_effort`，网关原样转给引擎；勾了引擎其实不收的
  档位，收到的是引擎自己的 400（与 2026-10-04「网关不改写调用方意图」同向）。

实现落点：解析与往返在 `config_store/lexicon.lua`（`normalize_effort_ladder`）+ `config_store/snapshot.lua`
（`new_card` / `merge_model_patch` / `snapshot_of` / env 装配）；回显在 `config_store/handlers.lua`
（`models_document` 的 `reasoning_efforts` + `detected_reasoning_efforts`）；接管点集中在
`router/models_api.lua` 的四个文件级 local（`card_ladder` / `overlay_effort_ladder` /
`intersect_strings` / `card_default_rung`），由 `resolve_model_caps` 在算档位那一支调用；
勾选 UI 在 `ui/admin/models.html` 的卡片对话框。

### 填充纪律：宁可不报，不要猜

数据源优先级固定为 **操作员 config 声明 > 引擎自报 > 整个键省略**。「省略」是**删键**——不输出 `null`，
也不输出空数组冒充「支持零个」（`[]` 是一份肯定答复，而这里要表达的是不知道）。整行一个读数都没有时，
条目就退回官方那四个 required 字段。每个维度独立取源，所以「操作员只声明了模态」不会连带把引擎报的
上下文丢掉。

两个数据源：

1. **操作员声明层**（`config_store` 快照，读数经 `router/models_api.lua` 的 `resolve_model_caps`
   取）：模型卡片 `max_output_tokens`＝**声明给下游 agent 的单次最大输出 token 数**（原名
   `context_limit`，用户裁定 2026-10-08 改名并改语义），平铺写法 `model_max_output_tokens` / env
   `LMR_MODEL_MAX_OUTPUT_TOKENS`，卡片优先于平铺层（同文件的 `declared_max_output_tokens`），
   唯一去处是 `capabilities.max_output_tokens`；卡片 `modalities`（`config_store.modalities_for`）；缺省档位由
   `model_effort` 强制行 → 卡片 `default_effort` → 全局 `default_effort` 给出；档位阶梯（picker 内容与顺序）另由卡片 `reasoning_efforts` 接管（见〈档位阶梯：探测 + 手动勾选〉）。`context_length` 这一维
   只由 `store_mod.ctx_cap`（卡片 `ctx` / 平铺 `model_ctx`）**优先于**引擎自报决定——输出预算的读数
   与上下文总窗口是两个不可比的量，谁也不冒充谁；两者都只是对外声明的读数，
   **不参与任何 max_tokens 计算**（用户裁定 2026-10-04 / 2026-10-08）。
2. **引擎自报层**：worker 自己 `GET /v1/models` 的回答，由 `registry/discovery.lua` 的
   `probe_advertised_entries()` 连覆盖探针一起采——**一次 GET 两份读数**，「探到了哪些模型」与「它们各自能干什么」
   永远来自同一份回答。原文经 `registry/caps.lua` 的 `model_caps_from_listing()` →
   `model_caps_from_entry()` 归一，跨 worker 汇总走 `registry/discovery.lua` 的 `model_caps()`：
   字段互补则两边都留，值冲突则取信息最全的那份**整条**读数，定序只看内容与
   完整度、不看写入顺序，避免对外读数随调度抖动。SGLang 只报 `max_model_len`（映射成 `context_length`），
   opencodex 报整套 `capabilities`。能力读数只认「引擎亲口答过」那一枚印章（`models_verified`，
   同文件的 `record_model_caps`），配置声明的名字不贡献读数。

`capabilities` 内部还有一层来源序（同一字段多处都有时）：`capabilities.*` > 条目顶层同名字段 >
`max_model_len`。这个顺序是「上游说得有多明确」，不是「我更喜欢哪个」。类型不对的读数一律按「这台没说清」
处理（`context_length` 写成数组、写成布尔都算没有读数），整条解析失败即跳过。

**registry 侧刻意不读上游条目的顶层 `context_window`**：那是**本网关配置层**的字段名（入口对外声明的
总窗口，见 `doc/gap-virtual-models.md` §4），把它和引擎读数混成一个字段，就等于重犯 2026-10-04 那次
context_window 事故——把声明的总窗口当成单次输出预算写进 `max_tokens`。

`supports_vision` 的正负向不对称（`router/models_api.lua` 的 `fill_model_fields`）：registry 归一层
**从不**反推它（引擎少写一列很常见，据此替上游编话不如少一个字段，见 `registry/caps.lua` 的归一分支）；输出层只允许**正向**反推——模态里列了 `image`/`video`
就报 `true`，无论这份模态来自引擎还是操作员；**负向**（报 `false`）只在操作员声明时给，因为只有卡片的模态是
穷尽列表（写入路径把 `text` 常开，显式提交空列表也落成只含 `text` 的一份）；
「操作员没列 image」才是「不收图」这句话，引擎自报的列表缺 image 只能读作「没说」
（卡片模态的穷尽性由 `config_store/snapshot.lua` 与 `config_store/profiles.lua` 的归一保证：`text` 常开）。

### 虚拟入口那一行

入口本身没有引擎，能力一律从组内的**实际模型**聚合，并且只在整组口径一致时才对外声明：数值取最窄、
支持位要求每台都报且一致、picker 要求每台档位序列完全一致、判定面取交集；任何一支凑不齐就删键。
单成员入口就是那台引擎本身，读数原样透传，免得同一个模型在它的真实行与入口行上说出两种能力。
对外声明的 `capabilities.context_length` 优先取条目自己写的 `context_window`（作用只是让客户端更早触发
压缩），其次才是组内各实际模型读数的最小值。

**「取最窄」的前置是每台都有读数，任何一台没有就整个删键**——这与 `config_store.virtual_ctx_cap` 判的
不是同一件事，别混用：`virtual_ctx_cap` 判的是**操作员声明之间的冲突**（每台都给了数、只是数值不一致，
于是取最窄）；`/v1/models` 这里判的是**引擎能力未知**（不知道那台到底装得下多少），跳过它就会把已知的
那些当成全部，广告出一个比部分成员能承受的**更大**的窗口。线上实证：235.t:8800 的 `Qn`
（组 = `Q38-Flash-Next` + `kimi-code/k3`）曾报 `context_length: 1000000`——那是 kimi 的读数，
`Q38-Flash-Next` 那一半当时没有读数。入口**自己显式声明**的 `context_window` 不受这条约束，
那是操作员说的话，是权威声明。

`owned_by` 的两套口径是**不能改的老契约**，有客户端在读它：真实模型恒 `"local"`（引擎自报的 owned_by 是
各家上游的说法，不上外）；单目标入口 `"llm-router-><model>"`，多目标入口 `"llm-router"` 加整组的
`owned_by_models`。`data[].id` 的取值集合、排序与别名遮蔽规则同样不变——registry 的 worker 判定、
watcher 的覆盖探针和客户端的模型选择全按 id 建，动了会连带影响选路。

注意 `GET /u/v1/models`（`ui.lua` 的 `ui.models()`）是管理台模型选择器用的**另一份**列表，
形状与本节无关：每条恒 `created: 0`、`owned_by: "llm-router"`，另带 `status.value`，只用来枚举候选名。

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
| `LR_UI_CONF` | 镜像内 ui.conf | 改成 `off` 关闭 UI/数据面 include（路由面照常启动） |
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
| `SMG_MAX_TREE_NODES` | `200000` | **每棵**基数树的节点数上限（doc/gap-cpu-idle-burn.md）。`SMG_MAX_TREE_SIZE` 的语义是「每租户＝每 worker URL 的字符数」，同一批 worker 可以合法地各背满它，也没有任何一维约束节点个数；真正把单转发核与 RSS 压垮的是节点数。`<=0` 关掉这一维 |
| `SMG_EVICT_BUDGET` | `0` | 单拍最多弹多少个叶子（增量淘汰的硬上界，`0`＝缺省 2000）。树已经失控时，没有预算的那一拍本身就能占秒级核时 |
| `SMG_POLICY_INSTANCE_TTL_SECS` | `1800` | 策略实例空闲多久**之后**可被回收（只回收「worker 池与热配置都不再声明该名字」的实例；`0` 关闭回收）。历史上 `_M.instances` 只加不减：`router/candidates.lua` 的 profile-forced 路径绕过 `for_model` 的回收分支 |
| `SMG_PREFIX_TOKEN_COUNT` / `SMG_PREFIX_HASH_LOAD_FACTOR` | `256` / `1.25` | prefix_hash（Lua 按字符数截断，Rust 按 token 数——已知口径差） |
| `SMG_BUCKET_ADJUST_INTERVAL_SECS` | `5` | bucket 边界重算节拍 |
| `SMG_EVICTION_INTERVAL_SECS` / `SMG_MAX_IDLE_SECS` | `120` / `14400` | 淘汰定时器 / manual 粘性映射闲置回收 |
| `SMG_ASSIGNMENT_MODE` | `random` | manual 的分配模式，另有 `min_load` `min_group` |
| `LR_SNAPSHOT_MAX_BYTES` | `3 MiB` | cache_aware 树快照写入 `lr_policy` 的上限，超限跳过 |
| `LR_MODEL_LABEL_CAP` | `300` | `lr_stats` 里 distinct `model` 标签值的上限。`lr_stats` 的 c|h|g| 行全仓没有任何 delete，而 model 的取值空间由客户端决定；越预算的新名字并进同一个 `other=` 行。`0` 关闭（原名照落）。当前基数看 `smg_model_label_cardinality` |
| `LR_METRICS_SCAN_LIMIT` | `20000` | `/metrics` 与功率读数一次共享字典扫描的行数上限（`get_keys(0)` 是整字典同步遍历，在 `worker_processes 1` 的进程里每 10～15s 的 scrape 都要付一次）。被截断时 `smg_dict_scan_truncated{dict=...}=1`，不会静默变少 |

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

### 运行时配置（`/config` 可改，`LMR_CONFIG_FILE` 落盘）

| 变量 | 说明 |
|---|---|
| `SMG_ENABLE_IGW` | 按 `model` 查表路由；开启后未知 model → 503 `no_available_workers` |
| `SMG_WORKER_URLS` | 逗号分隔的启动播种 worker 列表 |
| `LMR_DEFAULT_EFFORT` / `LMR_EFFORT_MAP` | 八档 effort 阶梯的默认值与改写表（`low:medium,high:xhigh`） |
| `LMR_MODEL_CTX` | 每模型上下文上限，模型卡片 `model_configs[].ctx` 的平铺写法（同一份文档里叫 `model_ctx`）。**只用于展示，不参与转发改写**（用户裁定 2026-10-04，见下一行与 doc/gap-virtual-models.md §4）：网关不再拿它去动 `max_tokens` / `max_completion_tokens`。它现在的读者只有展示面两处：`/props` 的 `props.with_ctx` 用它覆盖回显的 `n_ctx` / `n_ctx_train`，让 llama.cpp webui 显示操作员声明的窗口；另一处是 `/v1/models` 的合成层——`router/models_api.lua` 的 `resolve_model_caps` 先问 `store_mod.ctx_cap` 拿它当 `capabilities.context_length` 的**声明层**读数（这一层压过引擎自报），见〈`/v1/models` 的模型对象形状〉 |
| `LMR_MODEL_MAX_OUTPUT_TOKENS` | 每模型**声明给下游 agent 的单次最大输出 token 数**（用户裁定 2026-10-08；原名 `LMR_MODEL_CONTEXT_LIMIT`，那版说的是「服务实际能承受的上下文限制」——两个量不可比，名字与语义一起改）。`model=value` 形状，与上一项同一解析口径；卡片写法是 `model_configs[].max_output_tokens`，卡片优先于这一平铺层，且写卡片时清掉同模型的平铺行。**唯一去处**是 `/v1/models` 的 `capabilities.max_output_tokens`（`router/models_api.lua` 的 `declared_max_output_tokens`，操作员声明压过引擎自报），是一份纯对外声明：**不参与任何校验、钳制或 max_tokens 运算**，也不参与转发改写，也不声称引擎真实能力。原先挂在它身上的配置期校验（`config_store.validate_declared_context_windows`：条目 `context_window` 必须严格小于组内各卡片该读数的最小值，挂在 `apply_profiles` / `apply_document` 两条写入路径）已随本次改名**移除**，UI 侧同款前端预校验同步删除——入口的 `context_window` 是总窗口，卡片的输出上限是单次预算，拿一个判另一个等于重犯 2026-10-04 那次把三个量当一个数的错误。新 env 必须进 `config_store.ENV_NAMES`，否则 nginx 把它从 worker 环境里剥掉 |
| `LMR_MODEL_EFFORT` / `LMR_MODEL_EFFORT_MAP` | 每模型覆盖，优先级高于上两项 |
| `LMR_MODEL_EFFORT_LEVELS` | 每模型**对外声明的允许档位**＝卡片 `model_configs[].reasoning_efforts` 的平铺 env 写法，形状照 `LMR_MODEL_MODALITIES`：`model:low+medium+high`（多模型逗号分隔；值侧统一按「非字母」切，逗号 / 分号 / 空白 / 竖线都可）。档位名一律过八档词表，拼错的那一档整件丢弃——env 层的垃圾值历来是忽略，不替操作员猜一个近似名；空 value（`model=`）= 整行没说，不建卡。作用与卡片完全同一条：决定 `/v1/models` 的 picker 内容与顺序，判定面只收窄不扩面（见〈档位阶梯：探测 + 手动勾选〉与 doc/gap-effort-ladder.md）。已在 `config_store.ENV_NAMES` 登记（漏登记 = nginx 把它从 worker 环境剥掉，配了也不响） |
| `LMR_VIRTUAL_MODELS` | 虚拟服务入口的 env 形态 `alias:real`（逗号 / 分号 / 换行分隔多对），只能生成单 target 条目；1 对多的 `targets` 组、逐实例 `candidates` 绑定与条目级 `context_window` 只能经 `/config` 写。条目级 `context_window` 是**对外声明的上下文总窗口（输入+输出）**，作用只是让客户端更早触发压缩；它不是输出预算，也不参与 max_tokens 计算，网关与 UI 都不拿它跟卡片的 `max_output_tokens` 做比较（用户裁定 2026-10-08） |
| `LMR_MODEL_MODALITIES` | `/props` 广告的能力位（`text,image`） |
| `LMR_CONFIG_FILE` | RuntimeConfig 原子落盘路径，reload/重建后恢复；未设 = 内存态 |
| `LMR_UI_DIR` / `LMR_UI_ROUTER_MODE` | 静态 SPA 目录（默认 `/usr/local/share/llama-ui`）/ 路由模式开关。`SMG_UI_DIR` 由入口脚本映射到 `LMR_UI_DIR`（两者同时给出时 `LMR_` 优先），裸 conf 直跑只认 `LMR_UI_DIR` |
| `LMR_REQUEST_LOG_CAPACITY` / `LMR_LOGS_BUFFER` | 请求日志环形缓冲容量，**`0` = 关闭，四个 `/logs*`、`/stats` 转 503** |
| `LR_STATS_WINDOW_S` | `/stats` 的聚合窗口（缺省 10s）；空窗口的 `avg_*` 为 null |
| `LMR_PRICE_IN_PER_MTOK` / `LMR_PRICE_OUT_PER_MTOK` | `/stats` 与日志里的成本折算 |
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

限流只管推理面：公开面、控制面、UI 与根数据面都不占令牌。拒绝回 **429 + 空体**；令牌在
`finish_request`（流式 pump 完）与 `on_log`（客户端中途断开）双点归还。

### GPU 负载源与每服务容量上限（`SMG_LOAD_*`）

负载两路源（`none|metrics|prom`）的 env 表在 [doc/gap-gpu-load.md](doc/gap-gpu-load.md) §5；容量判定
（三态 / 绿灯优先 / 429）的完整口径在 [doc/gap-worker-caps.md](doc/gap-worker-caps.md)。

**每服务上限是 worker 记录上的三个字段，不是 env**（用户裁定 2026-10-06）：
`min_concurrency`（并发调度**下限**，整数 1..31，缺席等价 1；在飞低于它 = 绿灯）、
`max_concurrency`（并发调度**上限**，整数 1..32，`<=0`/非数字 = 不限，向下取整；达到即红灯）、
`max_gpu_util`（**GPU 利用率上限**，整数百分比 0..100；缺席 = 不限，**0 是合法的最严档**而不是清除，
清除用负数或删键）。可经 `POST/PUT /workers`、`upstreams` 声明、config 声明层配置。

三态：`full` = 在飞 ≥ 上限，或**新鲜**利用率读数 ≥ `max_gpu_util`；`idle` = 未 full 且在飞 < 下限；
其余 `busy`。判定只在一处（`registry.capacity_state`），`/workers` 的 `load_state` 与选路的绿灯优先
裁剪读的是同一次判定。`full` 在候选集层面**硬排除**（即使 cache_aware 亲和命中也迁走）；
有 idle 时黄灯**让位**（是裁剪不是排除，计 `smg_worker_capacity_preferred_idle_total`）；
全池没有 idle 时黄灯继续接活直到触自己的上限。**不摘 worker、不改健康**。两条读数各自的
「未知」语义：`inflight` 是本网关自有计数（缺键 = 0，从不「未知」）；`gpu_util` 是外部采样，
**缺席 = 未知 → 不排除**（监控挂掉只许损失精度，不许损失容量）。

**全池都抵在上限上**（`capped > 0` 且候选为空）答 **429**
`no_available_workers` +「No available workers (N at their concurrency or GPU-util limit)」；
熔断 / 不健康 / 组不服务保持 **503** 与原句不动。

指标：`smg_worker_capacity_excluded_total{reason="concurrency_max|gpu_util"}`
与 `smg_worker_capacity_preferred_idle_total`（Lua 独有超集），加利用率族 `lr_gpu_load_util_*`。

**`max_power_w`（瓦特上限）已退役**：声明层读到 warn 一次并丢弃、`PUT` 忽略、`/workers` 不回显、
容量判定不读。**功率采集链保留**为纯观测（`pw:` 键、`lr_gpu_load_power_*` 六族、`power_w` 字段），
换掉它的理由是 21.k 实测八个实例的功率读数完全相同（整机最热卡口径，八台同值），零区分度；
DCGM 的 `DCGM_FI_DEV_GPU_UTIL` 带 `gpu="0".."7"` 标签才能逐卡区分。见
[doc/gap-worker-caps.md](doc/gap-worker-caps.md) §6。

| 变量 | 默认 | 说明 |
|---|---|---|
| `SMG_LOAD_UTIL_ENABLED` | **开（1）** | 利用率通道（`gu:` 键，容量判定的数据源）是否采集。缺省开 = 零选路行为变化：判定只在记录显式配了 `max_gpu_util` 时发生 |
| `SMG_LOAD_UTIL_QUERY` | 空 = 缺省串 | prom 路的第三条 PromQL。缺省 `max by (Hostname,instance,gpu) (DCGM_FI_DEV_GPU_UTIL)`——**`gpu` 必须留在 by 里**，聚合掉它 = 八台 worker 共用一个数 |
| `SMG_LOAD_UTIL_KEYS` | 空 = 内置名册 | metrics 路的利用率 gauge 名册。内置含 `dcgm_fi_dev_gpu_util`（DCGM 真名）+ nvidia/dcgm 两个同量纲写法，**刻意不含 KV-cache 用量名** |

这三个名字走 `config.lua` 装配（fork 前解析，天然进 `/probe/config`），三份 conf 也一并 `env` 声明
（给 `util_config` 的 `os.getenv` 兜底分支放行）。仍**不可热改**：worker 环境 fork 时固定，生效方式是
重启容器。

| 变量 | 默认 | 说明 |
|---|---|---|
| `SMG_LOAD_POWER` | 关 | （纯观测）`SMG_LOAD_SOURCE=metrics` 时是否顺带扫功率 gauge |
| `SMG_LOAD_POWER_KEYS` | `DCGM_FI_DEV_POWER_USAGE` | 功率 gauge 名单（逗号/空格分隔）。`node_hwmon_*` 是整机口径，配「取最大」会把同机 worker 全体读成同一个数，故刻意不进缺省 |
| `SMG_LOAD_POWER_QUERY` | 空 = 不采功率 | prom 路的第二条 PromQL（须保留 `instance` 标签，否则机器归属退化成采不到） |

⚠ 功率这三个名字由 `gpu_load` 自己 `os.getenv` 现读、**没进 `config.lua`**：必须三份 conf 都显式
`env` 声明（漏一份就静默失效）、**不可热改**、也进不了 `/config` 的 JSON 视图与管理台。
四组通道（负载 / 功率 / 利用率）**全部搭载**在负载源上：`SMG_LOAD_SOURCE=none` 时定时器根本不启动，
设了任何开关都不会有读数（registry 侧一律按「未知 → 不排除」放行，留去重 WARN）。

**GPU 归属标注**：watcher 从容器名解析 `gpu<N>`（`gpu_from_name`），并对 proc 一路发现的候选补一次
socket→pid→cmdline 解析（`gpu_from_cmdline` 读 `--device-id N`，其次 `CUDA_VISIBLE_DEVICES=N`），
只在原值为空时填充、已有值绝不覆盖，落进台账 `g|<url>` 与记录 `labels.gpu`，于是 `/workers` 的
`metadata.gpu` 有值、管理台实例名后亮出 GPU 徽章，`gu:` 的逐卡归属也有了地址。它是**纯 label**：
不进排除、不进摘除、不进探针、不进宽限，任何一步失败一律降级为没有标注，服务发现本身一个字节
都不受影响（21.k 的形状：`qwen38-27b-dflash-tgt-gpu0` 在 8012、`pennyroyal-orca-gpu1` 在 8021、
`q38fn-pennyroyal-gpu2..7` 在 8022–8027）。

### watcher 服务发现（`SMG_WATCHER_ENABLED`，缺省关）

开启后 worker 0 定时器每 `SMG_WATCHER_INTERVAL_SECS`（15）做一轮 discover→probe→reconcile：
发现源三选可独立开关 `SMG_WATCHER_TARGETS`（逗号分隔 URL，可远程）/ `SMG_WATCHER_DOCKER`=1
（cosocket 读 /var/run/docker.sock）/ `SMG_WATCHER_PROC_SCAN`=1（纯 Lua 读 /proc/net/tcp）；
探针要求 `GET /v1/models` 回带 `data[].id` 的 OpenAI JSON 才注册。前九条守卫与原 Python 版逐条
等价，第 10 条是本地新增的摘除策略（按探针失败原因分档：确定性否定当轮摘、传输层未知连续失败
`SMG_WATCHER_PROBE_FAILURES`（缺省 2）次才摘），对照表与
偏差在 [doc/gap-watcher-merge.md](doc/gap-watcher-merge.md)。`POST /model-map` 兼容原版四种
body 形态做注册时改名（watcher 在进程内，`/config/model-map` 与管理台的改名直接调这个模块，无外部 watcher 地址需要配置）。其余旋钮：`SMG_WATCHER_PROBE_TIMEOUT_SECS`(4)、
`SMG_WATCHER_REMOVE_GRACE_SECS`(300)、`SMG_WATCHER_MAX_MODELS`(8)、
`SMG_WATCHER_KEEP_LAST_GRACE_SECS`(1800)。指标：`lr_watch_*` 家族。

每轮探测的三条硬预算（doc/gap-cpu-idle-burn.md CPU 线第 1 条）：`SMG_WATCHER_MAX_CANDIDATES`(32)
限制一轮探测多少个**新**候选（台账里的活体 worker 排在探测队列的豁免前缀，永远全探，
摘除判定不会被预算饿到）、
`SMG_WATCHER_PASS_BUDGET_SECS`(5，被 `interval_secs` 封顶)限制一轮的墙钟、
`SMG_WATCHER_PROBE_FANOUT`(8，1..32)是探测协程池宽度。被切掉的候选算「网关本轮什么都没说」
而不是「服务不可达」（不计 `probe_fails`、不推进 `missing_since`），规模看
`lr_watch_probe_budget_skips_total`。21.k 这类 65 个 LISTEN 端口的机器上的完整
`SMG_WATCHER_DENY_PORT` 建议清单见 [doc/gap-watcher-deny-21k.md](doc/gap-watcher-deny-21k.md)。

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
GATE_TIER=full bash test/final_gates.sh      # 全量 22 门（串行 13–14 分钟）
GATE_TIER=full GATE_JOBS=6 bash test/final_gates.sh   # 全量并行（实测 6.5 分钟，2.12 倍）
GATE_DRY_RUN=1 GATE_JOBS=6 bash test/final_gates.sh  # 只打印分组计划，不执行
GATE_ONLY=contract bash test/final_gates.sh  # 单门（不受档位限制）；GATE_ORDER 见脚本头
KEEP_GOING=1 bash test/final_gates.sh        # 跑完并计数

bash test/test_lua_router.sh                 # 契约套件单独调试（独占约 2.5 min）
TEST_ONLY=workers bash test/test_lua_router.sh   # 单段调试
```

**两套门禁脚本不能同时跑**（`flock` 锁写死在 `/data/tmp/lr-gates/.gates.lock`，第二份直接 `exit 3`）。
单份内部的**门与门**已经可以并行：各门的容器名、端口台账、临时目录与日志都按 RUN 隔离，
`GATE_JOBS=N` 即可。跑之前 `ps` 查一遍；测试容器名带 `lr-` 前缀，收尾 `docker ps -a | grep lr-` 清零。

分组是**写死在脚本里的表，不是旋钮**——新增门若未归类，脚本 fail-closed 直接 `exit 2`，
所以加门时必须同时决定它进 pool-1 / pool-2 / serial-only。**这三门必须留串行**，理由各不相同，
是下一个人加门时的判断依据：

| 门 | 为什么不能并行 |
|---|---|
| `e2e_watcher` | 先拍 `docker ps` 端口快照再拼排除表并挂 docker.sock；快照之后别人起的容器是没被排除的发布口，「恰好一个 worker」会因无关原因红 |
| `mesh_two` | 18 秒稳定窗 + stop/heal 分区窗内验名册；机器上有别的 router 应答时，名册和收敛时间都没有意义 |
| `e2e_tls_chain` | 硬编码 `SMG_PORT=31337` 并在该口上验 SNI |

生产机上 proc 扫描会把门禁轮的 mock 短暂注册进生产池，跑完清一次（`GET /workers` 找 unhealthy
测试模型名 → `DELETE /workers/{id}`）。

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
  升级摘除）；⑥ **打分**那一路的 GPU↔worker 映射仍靠 host（同机独立多卡共享 `xl:` 读数；准入门用的
  `gu:` 有逐卡归属，见 [doc/gap-gpu-load.md](doc/gap-gpu-load.md) §8 / §10）。
  ⑦ 每服务上限的残余缺口（mesh 不同步 `models`/三个上限→上限每网关独立；`disable_health_check` 的
  worker 永不获得引擎背书，组入口的模型背书只能靠 config 行声明；`lr_gpu_load_util_gpu` /
  `lr_gpu_load_power_watts` 这类 gauge 无 TTL，worker 删除后旧序列留在 `/metrics`），见
  [doc/gap-worker-caps.md](doc/gap-worker-caps.md) §11；⑧ 功率三开关未进 `config.lua`/JSON/UI
  （`SMG_LOAD_POWER` 一族由 gpu_load 现读 env，不可热改、管理台看不见；利用率那三个已走
  `config.lua`）；⑨ `registry/records.lua` 的 `info()` 不输出 `models_verified`，管理台的
  「引擎已验证」徽章与模型页的已验证计数恒不生效（补一个字段即通）。
- **TODO 不实现**（用户指示 2026-09-30）：MCP server 调用、wasm 中间件，唯一口径
  [doc/todo-deferred.md](doc/todo-deferred.md)。引用时不要写成「在接」「排期中」：`/wasm` 三条
  路由固定 501，`smg_mcp_*` 四条家族刻意不注册。

判定某个模块是否真的接进了请求路径，最快的一条命令（拆分后接线在 facade 与各子模块上，
所以要扫整个目录）：

```bash
grep -rn 'require *"resty\.luarouter\.<模块>"' lualib/resty/luarouter \
  lualib/resty/luarouter/*.lua conf/
```

## 文档索引

doc/ 现状文档 30 份。裁剪前平面的历史留档（feature-gap、verification、impl-*、fix-majors、
gap-{grpc,history,tokenizer,otel,discovery-watch,dp-jwt,auth-tls,http-semantics,core,integration,
test-gates}、wasm-feasibility、parity-perf v1）已于 2026-10-01 随文档精简删除，需要时查 git 历史。

| 文档 | 内容 |
|---|---|
| [doc/agent-handover.md](doc/agent-handover.md) | **agent 交接说明**：现状速览、测试纪律、设计红线、生产操作清单、缺口与文档地图（新接手先读它） |
| [doc/architect.md](doc/architect.md) | 架构总览：运行时模型、请求生命周期、模块地图（facade + 子模块树）、共享状态、策略、部署与测试框架 |
| [doc/refactor-arch-2026-10-05.md](doc/refactor-arch-2026-10-05.md) | 本轮重构的执行契约 + 执行结果：七个域的 facade + 子模块拆分、UI 三页改造、/u/ 与 /a/ 入口迁移、实测计数表与偏离记录 |
| [doc/gap-session-2026-10-04.md](doc/gap-session-2026-10-04.md) | 上下文窗口语义翻转、/v1/models 形状、effort 三层继承、per-GPU 功率与踩坑记录（接手前建议先读） |
| [doc/gap-config-store.md](doc/gap-config-store.md) | 配置持久化：sqlite/postgres/file 三态后端、CAS、镜像与采纳 |
| [doc/ui-trim-legacy-pages.md](doc/ui-trim-legacy-pages.md) | 管理台相对原版 webui 的页面差异与旧工具页移除记录 |
| [doc/deploy-state.md](doc/deploy-state.md) | 三实例部署现状、生效后端怎么查、已知配置漂移与死代码清单 |
| [doc/deploy-fleet.md](doc/deploy-fleet.md) | 21.k:8801 与 235.t:8800 的 fleet 部署与验证记录（含部署后验证清单） |
| [doc/scope-trim.md](doc/scope-trim.md) | 范围收敛判定书：模块 KEEP/DELETE/TRIM、量化收益、执行记录 |
| [doc/todo-deferred.md](doc/todo-deferred.md) | TODO 档（MCP、wasm）的唯一口径与启用时的最小方案 |
| [doc/gap-mesh.md](doc/gap-mesh.md) | mesh / HA 的 CRDT 设计、带宽代价与围栏 |
| [doc/gap-mesh-final.md](doc/gap-mesh-final.md) | `/ha/status` 幻影键根因与真修 + 双真节点 e2e |
| [doc/gap-watcher-merge.md](doc/gap-watcher-merge.md) | watcher 合并入进程：三源发现、九条原守卫对照 + 第 10 条摘除守卫、env 映射与偏差 |
| [doc/gap-gpu-load.md](doc/gap-gpu-load.md) | GPU 负载源：metrics 抓取与远程 Prom 查询两路、优先级与 TTL；功率观测通道（纯观测）与逐卡利用率准入门 |
| [doc/gap-routing-dyn.md](doc/gap-routing-dyn.md) | 路由动态变更：policy/model_policies 热配置与优先级链 |
| [doc/gap-token-accounting.md](doc/gap-token-accounting.md) | 流式 token 核算：include_usage 注入/剥帧、四类 token 指标 |
| [doc/gap-inflight-age.md](doc/gap-inflight-age.md) | 在途请求年龄采样：槽表、TTL 与 Rust 语义偏差 |
| [doc/gap-metrics-final.md](doc/gap-metrics-final.md) | Prometheus 家族覆盖率口径基线 + `smg_worker_pool_size` 修复 |
| [doc/gap-tls-chain.md](doc/gap-tls-chain.md) | 证书链 / SNI / 握手负例门与入口预检缺口 |
| [doc/gap-virtual-models.md](doc/gap-virtual-models.md) | 虚拟模型服务主入口（1 对多 `targets` + 条目级 `context_window`＝对外声明的上下文总窗口；卡片输出预算读数 `max_output_tokens` 与其配置期校验已于 2026-10-08 移除／改名）与 upstreams 持久化接入 |
| [doc/gap-effort-ladder.md](doc/gap-effort-ladder.md) | 档位阶梯：探测 + 手动勾选（卡片 `reasoning_efforts` / env `LMR_MODEL_EFFORT_LEVELS`）——三份读数（引擎原话 / 操作员勾选 / 对外读数）各有其主、勾选接管 picker 而判定面只收窄、空数组折回「没说」的三态口径、UI 契约与测试锚点 |
| [doc/gap-pool-merge.md](doc/gap-pool-merge.md) | 服务池页：运行态与声明态的统一视图、归属徽章、上限的事实来源 |
| [doc/caps-redesign-2026-10-06.md](doc/caps-redesign-2026-10-06.md) | 容量语义重设计的执行契约：三条裁定、字段/三态/绿灯优先/429 的逐节口径、UI 契约与波次文件所有权 |
| [doc/gap-worker-caps.md](doc/gap-worker-caps.md) | 每服务容量三态：并发上下限 + GPU 利用率上限、候选集硬排除与绿灯优先、全池到顶 429、功率上限退役与残余缺口 |
| [doc/parity-cpu-ablation.md](doc/parity-cpu-ablation.md) | 1.54x CPU 回退定责与消融实验计划 |
| [doc/parity-contract.md](doc/parity-contract.md) | 契约对拍原始报告（33 组） |
| [doc/parity-routing.md](doc/parity-routing.md) | 路由行为对拍原始报告 |
| [doc/parity-policy-extra.md](doc/parity-policy-extra.md) | prefix_hash/bucket/power_of_two/random 对拍原始报告 |
| [doc/parity-perf-v2.md](doc/parity-perf-v2.md) | 性能对拍原始报告（当前代码口径） |
| [doc/real-eval.md](doc/real-eval.md) | 真实上游端到端评测与 prefix cache 调度准确性 |
