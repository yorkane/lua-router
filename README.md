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

**信任边界**：网关层零鉴权——`/workers`、`/_ui`、`/model-map`、`/ha` 与推理面全部开放，
只可部署在 authz 边缘之后或可信内网。worker 记录里的 `api_key` 是本路由向**上游**出示的
凭据，不是挡在自己前面的门。

## 当前基线

全量门禁权威日志：`/data/tmp/lr-gates/gates-20261003-034756.log`（串行独占，**21 passed /
0 failed / 0 skipped**）。代码基线：Lua 24 417 行 / 15 个模块 + policies/ 6 文件、单测 10 文件。

> 锚点取在 2026-10-03 的代码上。2026-10-04 的三笔改动（网关不再改写输出预算 `75ecc37`、模型卡片
> 新增 `context_limit` 与配置期校验 `aa9f7a3`、管理台口径同步 `e2ba8ba`）之后全量门禁**尚未重跑**，
> 所以下表计数与本仓各文档的模块行数都仍停在 10-03 锚点上。同时 `test/integration/_lib.py` 的两条
> `[ctx cap]` 断言（夹断、缺失补齐）随裁定失效，测试侧更新后需要重新取锚。

| 门禁 | 计数 | 覆盖 |
|---|---|---|
| build / conf | — / 2 语法 OK | 镜像构建（含一次 `openresty -t`）；生产模板 + 裸 conf 双语法门 |
| unit | luajit 8 + resty 1 口径 | luajit 侧 tree 67 / policies 118 / hash 795 / mesh 391 / watcher 267 / gpu_load 274 / routing_dyn 122 / profiles 619 / caps_routing 64；resty 侧 integration 125（全部 0 failed） |
| contract | **653 / 0 failed / 2 notes** | 23 段 wire 契约（分段构成见 `test/test_lua_router.sh` 头部；`discovery` 段测的是 `/model_info` 元数据发现，与已删除的 K8s 发现无关） |
| probes | 25 / 0 | 策略工厂、配置旋钮、map 切分、裸 JSON 改写 |
| e2e_stateful | 91 / 0 | bucket / prefix_hash / manual / failback / 快照 / 多进程 / add worker / responses 元数据回填与断开语义 + DP 展开 31 项 |
| e2e_policies | 65 / 0 | 各策略真流量 + 虚拟别名与 effort 注入（该套件自述的 ctx cap 一项随 2026-10-04 裁定失效，见下方 `LMR_MODEL_CTX`） |
| e2e_ui_bridge | 25 / 0 | `/v1` 与 `/_ui` 两条路径改写一致 |
| e2e_errors / e2e_effort | 10 / 4 | `/_ui` 的 503/502/上游 4xx 契约；effort 强制与 per-model 卡片 |
| head_routes | 108 / 0 | HEAD 镜像每个 GET 路由 |
| mesh_http / mesh_two | 47 / 37 | mesh 真实 HTTP（对端 apply/sync、worker 镜像、/ha/policies）；双真容器互 seed 收敛、docker stop 分区恢复、retire 广播 |
| e2e_policy_parity | 47 / 0 | prefix_hash / bucket / power_of_two / random 与 Rust 的量化对拍 |
| e2e_watcher | 108 / 0 | 内建 watcher：三源发现、九条原守卫逐条断言 + 第 10 条守卫（探针确认不可用即摘除，含滞回与单轮保险丝）、model-map 改名、容器重启重发现 |
| e2e_profiles | 110 / 0 | 虚拟服务入口与 upstreams：白名单 / 入口名走按模型策略（`model_policies[入口名]` 是别名级 policy 停用后的替代入口）/ 停用字段仍接受、仍落盘、解析时 warn 而热路径不读 / api_key 三态与脱敏 / 30s 自愈 / apply 原子性 |
| e2e_token_accounting | 62 / 0 | 流式 include_usage 透明注入+剥帧、四类 token 指标、400 兜底 sticky |
| e2e_gpu_load | 58 / 0 | GPU 负载双源：worker /metrics 抓取与远程 Prometheus 查询写入 registry |
| e2e_routing_dyn | 51 / 0 | 路由动态变更：全局与 per-model 策略热切换免重启、非法名 400 不生效 |
| e2e_caps | 120 / 0 | 虚拟模型入口映射一组实际模型（不同上游的相同/不同模型、IGW 开关两路、candidates 与 workers 交集语义）+ 每服务并发/功率上限（到限即迁走、读数缺失不排除、上限不摘健康、缺省零变化） |
| e2e_tls_chain | 112 / 0 / 2 notes | 运行时 PKI、四类握手负例、RSA+ECDSA×TLS1.2/1.3、SNI 同端口双证书、证书/私钥不配对 fail-closed |

契约 653 的 23 段构成：gate 3、public 30、workers 75、inference 38、headers 13、mesh 44、
not_found 15、observability 53、proxy_endpoints 56、policy_hint 13、ui_fixed 60、tls_upstream 11、
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
| `ui/` | 原版 llama.cpp webui（`/_ui/`）+ `ui/admin/`（Quasar UMD 管理台四页：模型管理 / 服务池 / 路由策略 / 日志监控，中英双语；原「远程服务 / 服务接入」页已并入服务池）；`admin-inject.js` 向原版 webui 注入 Admin 入口（旧根目录工具页 logs/metrics/config 已移除，差异见 `doc/ui-trim-legacy-pages.md`） |
| `test/final_gates.sh` | 22 门硬门（`GATE_TIER` / `SKIP_ENV` / `GATE_ONLY` / `KEEP_GOING` / `GATE_JOBS` / `GATE_DRY_RUN`） |
| `test/test_lua_router.sh` | 契约套件（严格模式，第一个 FAIL 即退出），23 段 |
| `test/unit/` | 纯 Lua 单测 10 个文件，`luajit`(authz) 与 `resty`(apisix) 两个口径 |
| `test/integration/` | 真容器 e2e：stateful / policies / ui_bridge / errors / effort / probes / head_routes / mesh_http / mesh_two / policy_parity / tls_chain / watcher / token_accounting / gpu_load / routing_dyn / profiles / caps / models_advertisement（`models_advertisement` 钉 `/v1/models` 的对外形状，2026-10-04 随第 22 门加入 GATE_ORDER） |
| `test/mock_llm_worker.py` | 纯标准库 mock worker，含 `echo_body` / `echo_headers` 取证 |
| `doc/` | 现状文档 23 份（架构 / 交接 / 裁剪判定 / 各能力设计与对拍报告），索引见文末；裁剪前平面的历史留档已于 2026-10-01 清理，git 历史可查 |

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
| 推理面 | `/v1/chat/completions` `/v1/completions` `/v1/embeddings` `/v1/rerank` `/v1/classify` `/v1/responses` `/generate` | 字节透传 + 顶层 `model` 定点改写（虚拟入口转发的是选中候选的绑定名，不是入口名）；**输出预算三写法一律原样透传**——`max_tokens` / `max_completion_tokens` / `/v1/responses` 用的 `max_output_tokens` 都由调用方决定，网关既不改小也不在缺失时代填（用户裁定 2026-10-04），所以引擎拒的一定是调用方自己要的数；受 `SMG_MAX_CONCURRENT_REQUESTS` 限流（拒绝回 **429 空体**）。请求日志行的 `model` 是入口代表值，**实际落点模型看 `forwarded_model`**，调用方给的那个输出预算记在日志行的 `output_budget`（修复后恒等于请求原值）；组入口（显式写过 `targets`）被健康引擎一致拒绝整组模型名时，503 message 是「No available workers (N healthy engines serve none of the mapped models)」，与「全部熔断或不健康」分开定性。`/v1/responses` 是纯透传路由：非流式 2xx 时对响应顶层回填请求侧元数据六字段（`previous_response_id` / `instructions` / `metadata` / `store` / `model` / `safety_identifier`；`conversation` 不回显，它只对已删除的存储平面有意义），只做出站改写、不入库；流式只透传 |
| 控制面 | `POST /workers`（202 + Location）、`PUT /workers/{id}`（202，三键 `{status,worker_id,message}`）、`GET /workers[/{id}]`、`DELETE /workers/{id}`、`POST /flush_cache`、`GET /v1/loads` | `PUT` 可改 priority / cost / labels（合并）/ api_key / 健康旋钮 / **每服务上限 `max_concurrency` 与 `max_power_w`**，身份字段忽略；非 UUID → 400、未知 → 404、坏 JSON → 400。`GET /workers` 每条带 `models`（该实例真实广告过的模型，主模型恒居首）、`inflight_requests`（纯在飞数，并发上限的比较对象）、`power_w`（新鲜瓦特读数，**缺席=未知**）与两个已归一的上限；未声明的上限字段**缺席而不是 0**。`worker_type` 与 `connection_mode` 收成单值：只有 `regular` 与 `http`（或其 serde 对象拼写、缺省）被接受，其它值一律 400。`/flush_cache` 向全部 worker POST `{}`（5s 超时），回 `{results:[{worker,status,result}], success, all_failed}`；`/v1/loads` 回 `{workers:[{worker,load}], total_workers, successful, failed}`（worker 侧非 2xx / 超时 / 缺字段记 -1）——两者与 Rust 形状不同，有意偏差 |
| mesh / HA 面 | `/ha/{status,health,workers[/id],policies[/id],config[/key],rate-limit,rate-limit/stats,stats,shutdown}` + `/_mesh/internal/{ping,sync,apply,state}` | `SMG_ENABLE_MESH` 未设（缺省）→ `/ha/*` 全部固定 503 `{"error":"mesh not enabled"}`；开启后委托 `mesh.dispatch`，未知的深路径回 404 `{"error":"unknown ha route: <METHOD> <path>"}`。`/_mesh/internal/*` 无鉴权无 loopback 围栏，**信任边界就是网络本身** |
| `/_ui` | 别名全家 + 静态 SPA + `/_ui/admin/` 管理台（模型管理 / 服务池 / 路由策略 / 日志监控四页，按使用频度排序） | **无鉴权**；已注册路径的错误方法按 404 sink 回答 |
| 404 sink | 任意未注册路径（含已删的 `/v1/conversations*`、`/v1/tokenize`、`/parse/*` 等） | `{"error":{"type":"Not Found","code":"not_found",…}}` |

诚实表示「这实现没做」的路由只剩 **wasm 三条**：`POST /wasm`、`GET /wasm`、
`DELETE /wasm/{module_uuid}` → 501 `not_implemented`。另有 4 条 `/_ui/v1/*` 也回 501，Rust 对它们
同样回 `v1_ui_unsupported`，不构成缺口。

**CORS**：缺省全放开（常量响应头，与是否带 `Origin` 无关）；`SMG_CORS_ALLOWED_ORIGINS` 给列表后
只在 origin 命中时回显并收窄 Allow-Methods/Headers。预检 `OPTIONS` 在任何路由（含未注册路径）
都回 200，由 conf 的 server 级 `rewrite_by_lua_block` 在选定 location 之前提前应答——未注册路径的
预检在 Rust 侧是 404，这条保留为有意偏差。`/_ui` 也在 CORS 覆盖面里，比 Rust 宽。

## `/v1/models` 的模型对象形状

实现是 `router.lua` 的 `models_handler`（`router.lua:4108`）→ `advertise_real_model`
（`router.lua:3974`）/ `advertise_virtual_entry`（`router.lua:3998`）→ `fill_model_fields`
（`router.lua:3949`）。对外列表里的模型名来自 `registry.models()`（`registry.lua:1831`）——它是 Rust 对拍钉住的那一列，
只取每条 worker 的**主模型** `model_id`，因此一台引擎广告多个名字时只有主模型出现在这里
（多广告的那些走 `all_models()` / `worker_models()`，目前无人消费，见 doc/gap-worker-caps.md §8）。
虚拟入口由 `inject_virtual_models`（`router.lua:4065`）追加：入口名与某个真实 worker 同名则丢弃别名，
最后整表按 id 升序。无可用 worker 时整个响应是 503 纯文本 `No models available`（不是 JSON——Rust 侧只重写带
`data` 数组的响应，这个文本答案原样透传，`router.lua:4111-4114`）。

### 第一层：官方四字段，四个都是 required

OpenAI 官方 `/v1/models` 的模型对象**只有** `id` / `object` / `created` / `owned_by`，四个都 required。
真实模型那一支以前只有三个（整个漏了 `created`），属于不合规，现在每条带齐。`created` 取上游答里的
读数，取不到用常量 `MODEL_CREATED_UNKNOWN = 0`（`router.lua:3579`）表示「未知」，与虚拟入口一直的写法
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
| `capabilities` | `context_length` | 上下文**总窗口（输入+输出）** |
| `capabilities` | `max_output_tokens` | 单次输出预算上限，**只有引擎自报这一档**（config 层无对应声明字段，`router.lua:3753` 直取 `caps.max_output_tokens`）。它只是把上游给的数往外报，绝不构成网关改写调用方预算的依据——输出预算三写法原样透传（用户裁定 2026-10-04） |
| `capabilities` | `input_modalities` / `output_modalities` | 去重的非空字符串数组 |
| `capabilities` | `supports_tool_use` / `supports_streaming` / `supports_reasoning` / `supports_vision` | 支持位，三态：`true` / `false` / 整个键省略 |
| `capabilities` | `reasoning_effort` | 引擎**接受**的档位判定面，字符串数组（与顶层同名字段是两个含义，各画各的） |
| 顶层 | `owned_by_models` | 多目标入口的整组模型名数组 |

档位在上游有两种拼写、两个含义，registry 刻意各留一份、输出面各画各位：picker 的阶梯带 label 与
`default`，判定面是下游真正接受的集合。**不把阶梯里的档位虚构进判定面**——判定面优先用引擎亲口给的
`reasoning_effort_values`，只有它缺席时才退到阶梯序列（`router.lua:3814`）。实测样例里两份就不一致：
阶梯 `low/medium/high/max`，判定面只有 `low/high/max`；取交集会连 `medium` 身上那个 `default=true` 一起
丢掉，客户端反而没有缺省档可用，取并集又会报出下游可能不接受的名字，所以两份都留、各画各位。
单目标入口透传引擎原话（含「缺省档不在判定面里」这种上游自带的自相矛盾）；多目标入口的判定面取交集，
交集把缺省档挤掉就整个删键（`common_acceptance` `router.lua:3914`）。

### 填充纪律：宁可不报，不要猜

数据源优先级固定为 **操作员 config 声明 > 引擎自报 > 整个键省略**。「省略」是**删键**——不输出 `null`，
也不输出空数组冒充「支持零个」（`[]` 是一份肯定答复，而这里要表达的是不知道）。整行一个读数都没有时，
条目就退回官方那四个 required 字段。每个维度独立取源，所以「操作员只声明了模态」不会连带把引擎报的
上下文丢掉。

两个数据源：

1. **操作员声明层**（`config_store` 快照，`router.lua` 的 `resolve_model_caps`
   `router.lua:3744`）：模型卡片 `context_limit`＝引擎真实能力，操作员按引擎启动参数抄录，平铺写法
   `model_context_limit` / env `LMR_MODEL_CONTEXT_LIMIT`，卡片优先于平铺层（`declared_context_limit`
   `router.lua:3649`）；卡片 `modalities`（`config_store.modalities_for`）；缺省档位由
   `model_effort` 强制行 → 卡片 `default_effort` → 全局 `default_effort` 给出。`context_length` 这一维
   还多一个来源：先问 `store_mod.ctx_cap`（卡片 `ctx` / 平铺 `model_ctx`，`router.lua:3747`），它排在
   `context_limit` **之前**；两者都只是对外声明的读数，**不参与任何 max_tokens 计算**（用户裁定 2026-10-04）。
2. **引擎自报层**：worker 自己 `GET /v1/models` 的回答，由 `registry.probe_advertised_entries()`
   （`registry.lua:2913`）连覆盖探针一起采——**一次 GET 两份读数**，「探到了哪些模型」与「它们各自能干什么」
   永远来自同一份回答。原文经 `registry.model_caps_from_listing()`（`registry.lua:1137`）→
   `model_caps_from_entry()`（`registry.lua:1020`）归一，跨 worker 汇总走 `registry.model_caps()`
   （`registry.lua:2966`）：字段互补则两边都留，值冲突则取信息最全的那份**整条**读数，定序只看内容与
   完整度、不看写入顺序，避免对外读数随调度抖动。SGLang 只报 `max_model_len`（映射成 `context_length`），
   opencodex 报整套 `capabilities`。能力读数只认「引擎亲口答过」那一枚印章（`models_verified`，
   `registry.record_model_caps` `registry.lua:2937`），配置声明的名字不贡献读数。

`capabilities` 内部还有一层来源序（同一字段多处都有时）：`capabilities.*` > 条目顶层同名字段 >
`max_model_len`。这个顺序是「上游说得有多明确」，不是「我更喜欢哪个」。类型不对的读数一律按「这台没说清」
处理（`context_length` 写成数组、写成布尔都算没有读数），整条解析失败即跳过。

**registry 侧刻意不读上游条目的顶层 `context_window`**：那是**本网关配置层**的字段名（入口对外声明的
总窗口，见 `doc/gap-virtual-models.md` §4），把它和引擎读数混成一个字段，就等于重犯 2026-10-04 那次
context_window 事故——把声明的总窗口当成单次输出预算写进 `max_tokens`。

`supports_vision` 的正负向不对称（`router.lua:3781-3787`）：registry 归一层**从不**反推它（引擎少写一列很常见，
据此替上游编话不如少一个字段，`registry.lua:1016`）；输出层只允许**正向**反推——模态里列了 `image`/`video`
就报 `true`，无论这份模态来自引擎还是操作员；**负向**（报 `false`）只在操作员声明时给，因为只有卡片的模态是
穷尽列表（写入路径把 `text` 常开，显式提交空列表也落成只含 `text` 的一份，`config_store.lua:1529`）；
「操作员没列 image」才是「不收图」这句话，引擎自报的列表缺 image 只能读作「没说」。

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

注意 `GET /_ui/v1/models`（`ui.lua` 的 `ui.models()`，`ui.lua:198`）是管理台模型选择器用的**另一份**列表，
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
| `LMR_MODEL_CTX` | 每模型上下文上限，模型卡片 `model_configs[].ctx` 的平铺写法（同一份文档里叫 `model_ctx`）。**只用于展示，不参与转发改写**（用户裁定 2026-10-04，见下一行与 doc/gap-virtual-models.md §4）：网关不再拿它去动 `max_tokens` / `max_completion_tokens`。它现在的读者只有展示面两处：`/_ui/props` 的 `props.with_ctx` 用它覆盖回显的 `n_ctx` / `n_ctx_train`，让 llama.cpp webui 显示操作员声明的窗口；另一处是 `/v1/models` 的合成层——`resolve_model_caps`（`router.lua:3744`）先问 `store_mod.ctx_cap` 拿它当 `capabilities.context_length` 的**声明层**读数（这一层里它排在卡片 `context_limit` **之前**），见〈`/v1/models` 的模型对象形状〉 |
| `LMR_MODEL_CONTEXT_LIMIT` | 每模型**服务实际上下文限制**＝引擎真实能力（操作员按引擎启动参数抄录）。`model=value` 形状，与上一项同一解析口径；卡片写法是 `model_configs[].context_limit`，卡片优先于这一平铺层。**两个用途**：① 配置期校验——虚拟入口声明的 `context_window` 必须**严格小于**组内各卡片 `context_limit` 的最小值，否则 `/_ui/config` 拒绝保存（`config_store.validate_declared_context_windows`，挂在 `apply_profiles` / `apply_document` 两条写入路径）。② `/v1/models` 对外 `capabilities.context_length` 的**声明层**兜底读数——卡片 `context_limit` 缺席时由 `declared_context_limit` 读它，见〈`/v1/models` 的模型对象形状〉。两个用途都**不参与**转发改写与任何 max_tokens 计算；新 env 必须进 `config_store.ENV_NAMES`，否则 nginx 把它从 worker 环境里剥掉 |
| `LMR_MODEL_EFFORT` / `LMR_MODEL_EFFORT_MAP` | 每模型覆盖，优先级高于上两项 |
| `LMR_VIRTUAL_MODELS` | 虚拟服务入口的 env 形态 `alias:real`（逗号 / 分号 / 换行分隔多对），只能生成单 target 条目；1 对多的 `targets` 组、逐实例 `candidates` 绑定与条目级 `context_window` 只能经 `/_ui/config` 写。条目级 `context_window` 是**对外声明的上下文总窗口（输入+输出）**，作用只是让客户端更早触发压缩；它不是输出预算，也不参与 max_tokens 计算，且必须严格小于组内 `context_limit` 的最小值 |
| `LMR_MODEL_MODALITIES` | `/_ui/props` 广告的能力位（`text,image`） |
| `LMR_CONFIG_FILE` | RuntimeConfig 原子落盘路径，reload/重建后恢复；未设 = 内存态 |
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

### GPU 负载源与每服务上限（`SMG_LOAD_*`，缺省全关）

负载两路源（`none|metrics|prom`）的 env 表在 [doc/gap-gpu-load.md](doc/gap-gpu-load.md) §5；
下面是**每服务并发/功率上限**那三个开关（[doc/gap-worker-caps.md](doc/gap-worker-caps.md) §4）。

| 变量 | 默认 | 说明 |
|---|---|---|
| `SMG_LOAD_POWER` | 关 | `SMG_LOAD_SOURCE=metrics` 时是否顺带扫功率 gauge |
| `SMG_LOAD_POWER_KEYS` | `DCGM_FI_DEV_POWER_USAGE` | 功率 gauge 名单（逗号/空格分隔）。`node_hwmon_*` 是整机口径，配「取最大」会把同机 worker 全体顶穿上限，故刻意不进缺省 |
| `SMG_LOAD_POWER_QUERY` | 空 = 不采功率 | `SMG_LOAD_SOURCE=prom` 时的第二条 PromQL（须保留 `instance` 标签，否则机器归属退化成采不到） |

每服务上限本身是 **worker 记录上的字段**，不是 env：`max_concurrency`（在飞请求数上限，`<=0`/非数字
= 不限，向下取整）与 `max_power_w`（瓦特上限，`<=0`/非数字 = 不限），可经 `POST/PUT /workers`、
`upstreams` 声明、config 声明层配置。到顶即在候选集层面**硬排除**（即使 cache_aware 亲和命中也迁走），
不摘 worker、不改健康；**功率读数未知时不排除**；全场都在上限上时 503 `no_available_workers`
不放宽，message 追加「N at their configured concurrency/power cap」。指标：
`smg_worker_capacity_excluded_total{reason="concurrency|power"}`（Lua 独有超集）与
`lr_gpu_load_power_*` 六族。

⚠ 这三个名字由 `gpu_load` 自己 `os.getenv` 现读、**没进 `config.lua`**：必须三份 conf 都显式
`env` 声明（漏一份就静默失效）、**不可热改**（worker 环境 fork 时固定）、也进不了 `/_ui/config`
的 JSON 视图与管理台。

### watcher 服务发现（`SMG_WATCHER_ENABLED`，缺省关）

开启后 worker 0 定时器每 `SMG_WATCHER_INTERVAL_SECS`（15）做一轮 discover→probe→reconcile：
发现源三选可独立开关 `SMG_WATCHER_TARGETS`（逗号分隔 URL，可远程）/ `SMG_WATCHER_DOCKER`=1
（cosocket 读 /var/run/docker.sock）/ `SMG_WATCHER_PROC_SCAN`=1（纯 Lua 读 /proc/net/tcp）；
探针要求 `GET /v1/models` 回带 `data[].id` 的 OpenAI JSON 才注册。前九条守卫与原 Python 版逐条
等价，第 10 条是本地新增的摘除策略（按探针失败原因分档：确定性否定当轮摘、传输层未知连续失败
`SMG_WATCHER_PROBE_FAILURES`（缺省 2）次才摘），对照表与
偏差在 [doc/gap-watcher-merge.md](doc/gap-watcher-merge.md)。`POST /model-map` 兼容原版四种
body 形态做注册时改名（watcher 在进程内，`/_ui/config/model-map` 与管理台的改名直接调这个模块，无外部 watcher 地址需要配置）。其余旋钮：`SMG_WATCHER_PROBE_TIMEOUT_SECS`(4)、
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
  升级摘除）；⑥ GPU↔worker 映射靠 host（同机独立多卡会共享读数，见
  [doc/gap-gpu-load.md](doc/gap-gpu-load.md)）。
  ⑦ 每服务上限的两个残余缺口（mesh 不同步 `models`/上限→上限每网关独立；`disable_health_check` 的
  worker 永不获得引擎背书，组入口的模型背书只能靠 config 行声明），见
  [doc/gap-worker-caps.md](doc/gap-worker-caps.md) §8；⑧ 功率三开关未进 `config.lua`/JSON/UI
  （`SMG_LOAD_POWER` 一族由 gpu_load 现读 env，不可热改、管理台看不见）；⑨ `registry.info()` 不输出
  `models_verified`，管理台的「引擎已验证」徽章与模型页的已验证计数恒不生效（补一个字段即通）。
- **TODO 不实现**（用户指示 2026-09-30）：MCP server 调用、wasm 中间件，唯一口径
  [doc/todo-deferred.md](doc/todo-deferred.md)。引用时不要写成「在接」「排期中」：`/wasm` 三条
  路由固定 501，`smg_mcp_*` 四条家族刻意不注册。

判定某个模块是否真的接进了请求路径，最快的一条命令：

```bash
grep -rn 'require "resty.luarouter.<模块>"' lualib/resty/luarouter/router.lua \
  lualib/resty/luarouter/init.lua conf/
```

## 文档索引

doc/ 现状文档 22 份。裁剪前平面的历史留档（feature-gap、verification、impl-*、fix-majors、
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
| [doc/gap-watcher-merge.md](doc/gap-watcher-merge.md) | watcher 合并入进程：三源发现、九条原守卫对照 + 第 10 条摘除守卫、env 映射与偏差 |
| [doc/gap-gpu-load.md](doc/gap-gpu-load.md) | GPU 负载源：metrics 抓取与远程 Prom 查询两路、优先级与 TTL |
| [doc/gap-routing-dyn.md](doc/gap-routing-dyn.md) | 路由动态变更：policy/model_policies 热配置与优先级链 |
| [doc/gap-token-accounting.md](doc/gap-token-accounting.md) | 流式 token 核算：include_usage 注入/剥帧、四类 token 指标 |
| [doc/gap-inflight-age.md](doc/gap-inflight-age.md) | 在途请求年龄采样：槽表、TTL 与 Rust 语义偏差 |
| [doc/gap-metrics-final.md](doc/gap-metrics-final.md) | Prometheus 家族覆盖率口径基线 + `smg_worker_pool_size` 修复 |
| [doc/gap-tls-chain.md](doc/gap-tls-chain.md) | 证书链 / SNI / 握手负例门与入口预检缺口 |
| [doc/gap-virtual-models.md](doc/gap-virtual-models.md) | 虚拟模型服务主入口（1 对多 `targets` + 条目级 `context_window`＝对外声明的上下文总窗口 + 卡片 `context_limit` 配置期校验）与 upstreams 持久化接入 |
| [doc/gap-pool-merge.md](doc/gap-pool-merge.md) | 服务池页：运行态与声明态的统一视图、归属徽章、上限的事实来源 |
| [doc/gap-worker-caps.md](doc/gap-worker-caps.md) | 每服务并发/功率上限：候选集硬排除、最热卡功率口径、功率通道与残余缺口 |
| [doc/parity-cpu-ablation.md](doc/parity-cpu-ablation.md) | 1.54x CPU 回退定责与消融实验计划 |
| [doc/parity-contract.md](doc/parity-contract.md) | 契约对拍原始报告（33 组） |
| [doc/parity-routing.md](doc/parity-routing.md) | 路由行为对拍原始报告 |
| [doc/parity-policy-extra.md](doc/parity-policy-extra.md) | prefix_hash/bucket/power_of_two/random 对拍原始报告 |
| [doc/parity-perf-v2.md](doc/parity-perf-v2.md) | 性能对拍原始报告（当前代码口径） |
| [doc/real-eval.md](doc/real-eval.md) | 真实上游端到端评测与 prefix cache 调度准确性 |
