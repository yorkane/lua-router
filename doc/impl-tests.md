# lua-router 单实例功能契约测试

套件文件：`test/test_lua_router.sh`
骨架来源：`/data/ChatGPT/authz/test/test_klib_router_ctxvar.sh`（free_port / mock worker /
`openresty -t` gate / 容器随机端口 / 分段断言 / `trap cleanup EXIT`），改造为挂载本仓库、
通过 HTTP 驱动 `resty.luarouter`。

契约基准（写断言时的依据）：

- `gateway/src/server.rs`：路由表、404 sink、axum 的 405 + Allow
- `gateway/src/routers/error.rs`：`{"error":{"type","code","message"}}` + `X-SMG-Error-Code`
- `gateway/src/core/worker_service.rs`：202 + Location、`WORKER_NOT_FOUND`、`BAD_REQUEST`
- 生产 Rust 实例 `<dev-box>:8800`：写作时做过只读 GET 采样对照（未压测、未写入）

> **状态**：套件结构与运行方式仍有效；**「覆盖清单」的计数与「最近一次全量严格运行」已过期**。
> **日期**：写作 2026-09-29，状态复核 2026-09-30（UTC）。
> **证据强度**：A（2026-09-30 02:15 UTC 本机复跑，耗时 42 s）。
>
> 事实校正（契约对拍 F1–F7 + fix-majors M1–M6 新增断言之后）：
> - **最近一次全量严格运行 = 322 passed / 0 failed / 3 notes**（原 266；+56 条来自 M1–M6）。
> - 分段计数现为：gate 3、public 30、workers 40、inference 38、headers 13、mesh 5、not_found 9、
>   **observability 25**（原 23）、proxy_endpoints 20、**ui_fixed 51**（原 48）、
>   **tls_upstream 11**、**cb_race 6**、**ui_auth 33**、igw 7、discovery 5、prometheus 7、
>   **probes 19**（原 18）。下表已补 tls_upstream / cb_race / ui_auth 三行，细节见 [fix-majors.md](fix-majors.md)。
> - 「已知跳过项」里的 **HTTPS/TLS 上游**一条已不成立：tls_upstream 段用自签证书 +
>   `tls_wrap.py` 覆盖注册→探测→转发→流式→反向断言；仍**未**覆盖正式证书链与 mTLS。
>   「多 nginx worker 进程下的共享内存竞争」也部分失效：cb_race 段用 4 进程 conf 专测熔断计数；
>   仍没覆盖的是 load 计数一致性与淘汰后的快照行为。
> - 404 body / 405 门控 / `/v1/loads` 形状三条 NOTE 依旧成立（逐字未变）。
> - 另有两轮**不在本套件**的 e2e 现在是红的：`e2e_policies` 65/1、`e2e_ui_bridge` 19/1，
>   同因 `set_top_field` 的 number 分支 bug，见 feature-gap.md §5.1。

## 运行方式

```bash
cd /path/to/lua-router
bash test/test_lua_router.sh                 # 全量严格模式（默认）
TEST_ONLY=workers bash test/test_lua_router.sh   # 单段调试
KEEP_GOING=1 bash test/test_lua_router.sh    # triage：失败后继续，最后计数
TEST_DEBUG=1 bash test/test_lua_router.sh    # 打印每次请求的原始 body 前 200 字节
```

严格模式下第一个 `FAIL` 即退出并 dump 全部容器 `docker logs`；`KEEP_GOING` 只用于定位，
跑完会打印 `Triage run: N passed, M failed, K notes`，`M != 0` 时退出码非 0。

### 依赖

- `docker`、`curl`、`jq`、`python3`
- OpenResty 镜像 `authz:latest`（可用 `OPENRESTY_TEST_IMAGE=<image>` 覆盖）。该镜像只提供
  openresty 二进制与 LuaJIT，lua-router 的 lualib 与 conf 全部以只读 bind mount 注入，
  因此测的是工作区当前代码，不需要重新构建镜像。
- 全量约 35 秒（含 4 个容器的启停）。

### 环境注意点（踩过坑）

- **容器访问宿主机上的 mock worker 必须走 docker bridge 网关**（脚本用 `docker inspect`
  取 Gateway，本机是 `172.17.0.1`）。本 box 的 FORWARD 链是 DROP，`-p 127.0.0.1:xx` 映射的
  端口从容器内不可达，mock 一律 `--host 0.0.0.0` 绑定。
- 随机宿主端口用 `-p 127.0.0.1:0:30000` 这种显式写法；`-p 127.0.0.1::8080` 与同一命令里的
  固定端口映射混用会让 docker 报 `invalid IP address: 127.0.0.1:`。
- 容器名带 `-$SUIT`（脚本 PID）后缀，多个套件并发跑时互不 `docker rm -f`。
- 断言原语的铁律（沿用 authz 套件）：`fail()` 后必须 `return`，否则 `KEEP_GOING` 模式下同一个
  坏检查会接着报 PASS。

## 覆盖清单

分段与 `TEST_ONLY` 段名一致，最后一列是最近一次全量严格运行的通过数。

| 段名 | 断言 | 覆盖内容 |
| --- | --- | --- |
| `gate` | 3 | `openresty -t` 语法门禁：`test/conf/nginx-lua-router.conf`、生产 `conf/lua-router.conf`，并校验测试 conf 里 `include conf/ui.conf` 恰好生效一次 |
| `public` | 30 | `/health` 200+`OK`+`text/plain`；`/liveness`；`/readiness` 无 worker 时 503（`reason: insufficient healthy workers`、`status: not ready`）、注册后转 200；`/server_info` 含 `router_manager`、`routers_count`、`workers_count`、policy 名合法；`/get_server_info` 别名；`/v1/models` 空时 503、注册后含 `test-model` 及 `object: list` 形状 |
| `workers` | 40 | POST 202 契约（`status/worker_id/url/location/message` + `Location` 头、worker_id 为 UUID）；重复 POST 同 url 复用 id 且 `job_status.status=failed` + `already exists`；`GET /workers` 的 `total`/`stats.{regular,prefill,decode}_count`/`workers[]` 字段全集；`GET /workers/{id}`；`GET /workers/not-a-uuid` → 400 `BAD_REQUEST`+"expected UUID"；未知 uuid → 404 `WORKER_NOT_FOUND`；DELETE 202 + 删后 GET 404 + 重新注册复用派生 id；POST 坏 JSON / 缺 url → 400；无 scheme 的 url 被 normalize 成 `http://…` |
| `inference` | 38 | 非流式 chat：200、`id` 前缀 `chatcmpl-`、`object`、`choices[0].message.role`、`finish_reason`、model 回显、content 回显 prompt、`usage.total_tokens`、响应头 `X-Request-Id` 形状；流式：`text/event-stream`、多 chunk、`[DONE]` 结尾、chunked 无 content-length、finish 帧透传；坏 JSON/空 body → 400 且错误体 `{"error":{"type","code","message"}}` + `X-SMG-Error-Code`；`/v1/completions`、`/v1/embeddings`、`/v1/rerank`、`/v1/classify`、`/v1/responses`、`/generate` 最小转发；`x-smg-target-worker` 钉住 + 上游 body 里 model 被改写；round_robin 从池子里选 |
| `headers` | 13 | 用记录型 sink 断言转发头：客户端 `x-request-id` 回显、`x-request-id`/`traceparent`/`x-request-id-retry-*`/`x-smg-routing-key` 透传、`cookie` 不透传、`accept-encoding` 强制 identity、缺省补 `content-type`、`Host` 指向 worker；上游 body 的 model 被改写、原 client model 消失、`content-length` 与实际转发 body 一致 |
| `mesh` | 5 | `/ha/*` 一律 503 + `{"error":"mesh not enabled"}`（含深层嵌套路径经 404 fallback 仍然命中） |
| `not_found` | 9 | 未知路径 404 + `X-SMG-Error-Code: not_found` + `.error.code` + message 形如 `No route for GET /nope`；带 query 仍 404；方法不匹配走 `request_method_gate`（见下）；`HEAD /health` 无 body |
| `observability` | 25 | 主端口 `/metrics` 200、`text/plain; version=0.0.4`、`smg_http_requests_total{`/`smg_router_requests_total{`/`smg_worker_health{`/`smg_worker_cb_state{`、exposition 无裸行；`/_ui/logs`（cursor/capacity/requests、记录字段、SSE usage 解析）；`/_ui/stats`（inflight/uptime_s/requests_total/窗口字段）；`/_ui/logs/backends`；`/_ui/logs/stream` 推 data 帧 |
| `proxy_endpoints` | 20 | `/engine_metrics` 代理（状态、content-type、逐 worker 分块并带 worker 标签）；`/model_info` 与别名 `/get_model_info`（合并各 worker infos、served name）；`/v1/loads` 与别名 `/get_loads`（loads 数组、条目字段、timestamp）；`/health_generate` 501；`/v1/tokenize` 501；`/flush_cache` 200 + 逐 worker 结果 + `all_failed` |
| `ui_fixed` | 51 | `/_ui/slots`、`/_ui/tools`、`/_ui/v1/streams/lookup` → `[]`；`/_ui/v1/stream`、`/control`（GET+POST）→ 501；`/_ui/models/load` → `success`，GET → 405 + `Allow: POST`；`/_ui/models/unload` → 400 中文错误；`/_ui/v1/models` 形状（object/data 非空/loaded 标记/`status.value`）、POST → 405 + Allow；`/_ui/stats`、`/_ui/logs`、`/_ui/logs/backends` 经 ui.conf 的路由别名（含 inflight/capacity 字段）；`/_ui/props`、`/_ui/config`（含 `env_defaults`）；`/_ui/v1/chat/completions`（含缺 model 时补默认、坏 JSON 400）、`/_ui/v1/completions`；`/_ui` → `/_ui/` 重定向、SPA 首页为 html、`logs.html`、静态缺失 404 |
| `tls_upstream` | 11 | 自签证书 + `tls_wrap.py` 把 mock 包成 https：注册→探测 healthy→chat 转发（含 model 重写与 usage）→流式 `[DONE]`→`/_ui/props` 代理，外加「443 端口不发明文」反向断言（M2） |
| `cb_race` | 6 | `worker_processes 4` 的派生 conf 下并发打故障 mock：阈值 6 打开、打开后 503、`closed->open` transition 恰 1、failure 计数不丢（M4） |
| `ui_auth` | 33 | 带/不带 `SMG_API_KEY` 双实例：9 个受保护 `/_ui` 端点无 key 全 401 且空 body、只认 `Bearer` 前缀（小写 `bearer` 拒）、错误 key 401、带 key 200、logs/stats/config/静态直通（M6） |
| `igw` | 7 | 另起 `SMG_ENABLE_IGW=1` 实例：已注册 model 正常路由；未知 model → 503 + `X-SMG-Error-Code: no_available_workers` + `.error.code`/`.error.type`（`Service Unavailable`）+ message 含 `No available workers`，与 Rust 行为一致 |
| `discovery` | 5 | 注册时不带 `model_id`：先 `unknown`，健康巡检通过 `/model_info` 自动发现 `test-model`，回填到 `GET /workers`、`metadata.served_model_name`，并在 `/v1/models` 里广告 |
| `prometheus` | 7 | 走真实 `docker-entrypoint.sh` + `SMG_METRICS_PORT=29000`，校验独立 29xxx 抓取端口：`/metrics` 200 且含计数器、`/health` 为 `OK`、其余路径保持最小（404）；同时 `/metrics` 在主端口也可用，entrypoint 容器正确挂上 ui.conf 与静态 SPA 资源 |
| `probes` | 19 | 测试专用内省端点：`/klib/load` 逐模块 `: OK`（覆盖 router 与 policies）；`/probe/worker-id` 与 Python `sha224[:32]` UUID 派生一致；`/probe/rewrite-model`；`/probe/extract-text`（chat/completions 路由文本）；`/probe/headers`（转发白名单与响应丢弃表）；`/probe/env`（LMR_* 在 fork 前快照、worker env 已剥离）；`/probe/config`（`enable_igw` 默认关、`max_retries` 默认 5） |

最近一次全量严格运行：**322 passed / 0 failed**（42 秒，3 条 NOTE，见下；2026-09-30 复跑）。
基线从 266 涨到 322 的 56 条增量来自 fix-majors M1–M6，分布：observability 2、ui_fixed 3、
tls_upstream 11、cb_race 6、ui_auth 33、probes 1。

## 已知跳过项与记录在案的契约偏差

这些是有意不覆盖的，不是遗漏：

- **方法不匹配（405 门控）**：Rust 的 axum 对已存在路径的错误方法回 `405 + allow: POST` 且空体
  （在 <dev-box>:8800 实测）；klib.router 没有方法门控，lua-router 目前回 404 JSON。套件用
  `request_method_gate` 同时接受 404 或「405 且 Allow 含期望方法」，所以现在就全绿，等
  `router.lua` 补上门控也不会破。`/_ui/*` 的路由已由 `ui.conf` 正确返回 405 + Allow，那部分
  是硬断言。
- **404 响应体**：Rust 的 fallback sink 是空体 404；lua-router 返回 JSON 错误体并带
  `X-SMG-Error-Code`。只看状态码的客户端行为一致，`doc/impl-core.md` 描述的是 Lua 侧行为。
- **`/v1/loads` 形状**：Rust 是
  `{workers:[{worker,load}],total_workers,successful,failed}`（load 从引擎探得，取不到时 -1）；
  Lua 是 `{loads:[{worker_id,url,model_id,load,is_healthy,cb_state,...}],timestamp}`。信息量更全
  但字段名不同，仪表盘需要先统一形状，套件按 Lua 实际形状断言并记一条 NOTE。
- **HTTPS/TLS 上游**：`tls_upstream` 段已覆盖自签证书 + SNI 握手（明文反向断言含在内）；
  仍未覆盖的是正式证书链、证书名不匹配与 mTLS。
- **多 nginx worker 进程下的共享内存竞争**：`cb_race` 段用 sed 派生的 `worker_processes 4` conf
  专测熔断计数的跨进程原子性；其余共享状态（load 计数、registry 锁竞争、淘汰后的快照）
  仍由单进程实例覆盖，多进程一致性不在范围内。
- **超时/大 body/断流**：未做上游超时、超大 payload、流中途截断等故障注入，那需要
  mock 支持可控延迟与主动断连。
- **Prometheus 抓取端口的真实采集**：只断言 `/metrics`  exposition 的格式与关键指标存在，
  不接真实 Prometheus 做 scrape 校验。

## 并发与偶发失败

同一仓库里可以同时跑多份套件（容器名带 `-$SUIT` 后缀，各自只清理自己的容器）。但本轮运行中
出现过一次 `FAIL: worker never became healthy (health sweep)`，`docker logs` 显示
`No such container: lr-main-<pid>`，同时刻有另外的 agent 在跑同一套件——是主实例容器被外部
`docker rm -f` 掉了，不是 lua-router 的实现问题。判断方法：先 `docker ps -a` / `docker events`
看容器是不是被销毁，再重跑；只有容器活着仍不健康，才是真的实现 bug。

## 套件在测什么代码

- `test/conf/nginx-lua-router.conf`：单 server、监听 8080，`include /repo/conf/ui.conf`，
  外加 `probes` 段用到的内省 location。
- `lualib/resty/luarouter/**` 与 `conf/**` 以只读 bind mount 覆盖镜像内的
  site lualib，因此每次运行都测的是工作区当前内容。
- mock worker 复用现成的 `test/mock_llm_worker.py`（`--host 0.0.0.0 --port $PORT --model M`，
  提供 `/v1/models`、`/model_info`、`/metrics` 与各推理端点）；`headers`/`inference` 段另起一个
  记录型 sink，把收到的转发头与 body 落盘供断言。
