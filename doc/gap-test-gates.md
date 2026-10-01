# gap-test-gates：最终门禁仓库化 + HEAD / mesh 盲区补齐

日期：2026-09-30。作者：test/verification 子 agent。
基线代码树：`router.lua` md5 `d22d88777e16fab194c2d16b44d297b1`
（与 `lua-router:integration` 镜像内的副本一致），契约套件为
`test_lua_router.sh`（659 checks / 3 notes，本任务未修改该文件）。

改动范围（全部在本 agent 的所有权内）：

| 文件 | 动作 |
|---|---|
| `test/final_gates.sh` | 新建：12 个门禁串行、首失败退出、`SKIP_ENV` 白名单 |
| `test/integration/probes.py` | 修一条陈旧断言（`round_robin` → `cache_aware`） |
| `test/integration/test_head_routes.py` | 新建：HEAD 面 118 checks |
| `test/integration/test_mesh_http.py` | 新建：mesh enabled 真实 HTTP 48 checks |
| `doc/gap-test-gates.md` | 本文 |

`test_lua_router.sh`、`lualib/`、`conf/`、`docker-entrypoint.sh`、`Dockerfile` 零改动。
发现的实现问题全部记录在 §4，未顺手改核心文件。

---

## 1. final_gates.sh 覆盖什么

串行 12 个 gate，默认第一个失败即退出（`KEEP_GOING=1` 跑完并计数）。日志默认
`/data/tmp/lr-gates/gates-<UTC 时间戳>.log`，用 `LR_GATE_LOG` / `LR_GATE_LOG_DIR` 覆盖。

| gate | 内容 | 独占耗时 |
|---|---|---|
| `build` | `docker build -t lua-router:integration -f Dockerfile .`（含构建期 `openresty -t`） | ~1 s（缓存命中）/ 首次数分钟 |
| `conf` | `openresty -t` × `test/conf/nginx-lua-router.conf` 与 `conf/lua-router.conf` | ~2 s |
| `unit` | luajit 口径 `tree/policies/hash/history/mesh/pd` + resty 口径 `tree/policies/hash/integration/tokenizer_parse` | ~6 s |
| `contract` | `test_lua_router.sh` 严格全量（首 FAIL 即退出） | 42–80 s |
| `probes` | `integration/probes.py` | ~60 s |
| `e2e_stateful` | `integration/e2e_stateful.py` | ~150 s |
| `e2e_policies` | `integration/e2e_policies.py` | ~180 s |
| `e2e_ui_bridge` | `integration/e2e_ui_bridge.py` | ~60 s |
| `e2e_errors` | `integration/e2e_errors.py` | ~40 s |
| `e2e_effort` | `integration/e2e_effort.py` | ~25 s |
| `head_routes` | `integration/test_head_routes.py` | ~25 s |
| `mesh_http` | `integration/test_mesh_http.py` | ~90 s |

相对上一版一次性脚本（`/data/tmp/lr-core2/final_gates.sh`）的增量：
补 `probes.py`、`e2e_errors.py`、`e2e_effort.py`、未接线模块单测
（`test_history` 731 / `test_mesh` 361 / `test_pd` 219 / `test_tokenizer_parse` 316），
以及两个新套件 `head_routes` / `mesh_http`；旧脚本只跑 build → 契约 → 三个 e2e →
三个单测 → 两个 conf，且用 `tail -2` 吞掉退出码（任何一步失败都不会让脚本红）。

`unit` 里为什么同时跑两个镜像口径：`authz:latest` 只给 `luajit`（纯 Lua 模块），
`apache/apisix:3.11.0-debian` 给 `/usr/bin/resty`（需要 `_G.ngx` 的
`test_tokenizer_parse`、`test_integration`）。两个口径的 tree/policies/hash 重复跑是
有意的 —— 两份 openresty 版本（1.31.1.1 / 1.25.3.2）与两份 LuaJIT 都必须在门禁里绿。

## 2. SKIP_ENV 的语义与代价

`SKIP_ENV=<逗号或空格分隔的 gate 名>`。未知名字直接 `exit 2`，不会静默忽略。
每个被跳过的 gate 在 stdout 和日志里各留一行 SKIPPED，绿色运行无法偷偷缩水。

| gate | 跳过之后失去什么 |
|---|---|
| `build` | e2e / head_routes / mesh_http 只能对着可能过期的 `lua-router:integration` 跑（这三个套件用镜像里的 `lualib`，不是工作区） |
| `conf` | 两份出厂配置能否被 `openresty -t` 解析无人验证 |
| `unit` | tree/hash/policies/history/mesh/tokenizer_parse 是纯 Lua 模块，`router.lua` 只从 HTTP 面碰它们，HTTP 套件测不到分支回归 |
| `contract` | 659 条对外契约（状态码、错误体、头、指标家族）整体未验证 |
| `probes` | 策略工厂 / `SMG_*` 旋钮缺省值 / `LMR_*_MAP` 解析 / 原始 JSON 编辑器 |
| `e2e_stateful` | bucket / prefix_hash / manual / failback / 快照 / 多进程 / add worker |
| `e2e_policies` | 策略矩阵 + 虚拟别名 + effort 注入 + ctx 封顶 + worker_processes 规则 |
| `e2e_ui_bridge` | `/_ui/*` 与 `/v1/*` 的一致性（含 clamp 对拍） |
| `e2e_errors` | `/_ui` 的 503 / 502 / 上游 4xx 透传契约 |
| `e2e_effort` | `LMR_MODEL_EFFORT` 强制与 per-model 卡片 |
| `head_routes` | HEAD 面（Rust axum 的 `get()` 天然应答 HEAD，本实现逐条手工镜像） |
| `mesh_http` | mesh enabled 的真实 HTTP 面：worker 镜像、apply/sync、`/ha/policies/{model}`、`/_mesh/internal/{state,apply}`、非 loopback 门 |

只有一种情况允许 skip：某个 gate 被无关改动已知阻塞。跳过理由要写在运行记录里。

## 3. 新套件覆盖什么

### 3.1 test_head_routes.py（118 checks）

仓库里此前只有一条 HEAD 断言（`test_lua_router.sh` 的
`HEAD /health has no body`）。router.lua 为每条只读 GET 手工注册了 `app:head`
镜像，ui.lua 用 `m == "HEAD" and a == "GET"` 折叠方法门，这两处一旦漂移就没有
任何测试会红。本套件对每条路由做 GET/HEAD 成对比较：状态码一致、HEAD 无 body、
`Content-Type` 逐字节一致、`Content-Length` 一致。

覆盖的路由：`/health` `/liveness` `/readiness` `/v1/models` `/model_info`
`/get_model_info` `/server_info` `/get_server_info` `/engine_metrics` `/metrics`
`/workers` `/workers/{id}` `/workers/does-not-exist`(400) `/v1/loads` `/get_loads`
`/v1/tokenizers` `/v1/tokenizers/nope`(404) `/ha/status`(503) `/_ui/v1/models`
`/_ui/props` `/_ui/logs` `/_ui/stats` `/_ui/slots` `/_ui/tools`
`/_ui/logs/backends` `/_ui/config/effort`(405) `/_ui/`（静态 SPA）、`/nope`(404 sink)。

两个必要的放宽，都是量出来的而不是猜的：

- **动态负载不比 `Content-Length`**：`/metrics` `/v1/loads` `/get_loads`
  `/server_info` `/get_server_info` `/_ui/stats` `/_ui/logs` 的正文里带 uptime、
  inflight、指标序列，两次 GET 自身就不相等（实测 `/get_server_info` 的
  `Content-Length` 在两次请求间 503→502，因为 `uptime_s` 的小数位少了一位）。
- **状态码不同时不比头**：见下面两条 divergence，不同 handler 应答，头必然不同。

两条 **有意的 divergence，钉在当前值**（修好即红，逼人来更新期望）：

1. `/_ui/config`：GET 200，HEAD **400**（Rust 8800 实测 HEAD 200/0B）。
   原因在 `conf/ui.conf:155-162` —— exact location 里
   `ui.method_any("GET", "POST")` 之后按 `get_method() == "GET"` 二选一，
   HEAD 落到 POST 分支 `ui.config_effort()`，空 body 直接被 400 拒。
2. `/_ui/history`：GET 200，HEAD **404**。router.lua 只注册了
   `app:get("_ui/history")`（router.lua 的 `_ui/history` 那行），没有 `app:head`
   孪生；而 `test/conf/nginx-lua-router.conf:85` 的 exact location 又转发给
   `handle()`，于是 klib.router 用自己的 404 sink 应答 HEAD。这条严格说是
   **内部不一致**（Rust 也没有这条路由），比第 1 条更像漏接线。

`/_ui/config` 的 HEAD 400 会打出 `X-SMG-Error-Code`，`/_ui/history` 的 404 同理，
两条都在测试里以 label 明写 `DIVERGENT(...)`。

### 3.2 test_mesh_http.py（48 checks）

契约套件已有 mesh enabled 段（自带 fake peer），但它跑在 bash 里、只验 `/ha/*`
的应答形状。本套件补的是 **worker 生命周期经过真实 HTTP 的外向可见性**，以及
内部端点的报文成帧：

- 注册 / 删除 worker，断言变更到达 peer（`seen_workers` / `seen_deleted` 从
  解码后的 b64 快照里取）并反映到 `/ha/workers`；tombstone 之后
  `/ha/workers/{id}` 转 404。
- `GET /_mesh/internal/state` 返回真实 b64 快照：`Content-Type:
  application/x-mesh-b64`、能解码、`protocol==1`、`node` 等于 `SMG_MESH_SELF_NAME`、
  members ≥ 2、worker 条目数与 `/ha/workers` 一致。
- `POST /_mesh/internal/apply`（loopback）注入伪造快照，注入的 worker 与 policy
  随后可从 `/ha/workers/{id}`、`/ha/policies/{model}` 读到；坏 envelope → 400
  `bad mesh envelope`（`/sync` 同）。
- `GET /ha/policies/default` 200（`origin` 为本节点、`policy_type` 跟随
  `SMG_POLICY`），未知 model 404。
- 出站记账：peer 的 `sync` ≥ 1 且 `bad_auth` == 0。
- 非 loopback 门：取本机 LAN 地址访问 `/_mesh/internal/{state,apply}` → 403
  `forbidden`；同一地址访问 `/ha/status` 仍 200（无 key 时 `/ha/*` 开放）。
- 收尾断两台实例都没有 `lua entry thread aborted`。

mesh 用 `SMG_MESH_UNREACHABLE_TIMEOUT_SECS=300` 关掉不可达降级的时间噪声，
fake peer 在本文件内实现（契约套件的 peer 是 `test_lua_router.sh` 里的 heredoc，
本任务不动那个文件，所以不导入而是重写一份）。

## 4. 本轮新发现的实现问题（未改，只报告）

按严重度排序。前两条已由 `test_mesh_http.py` 以 DIVERGENT 断言钉住。

1. **`SMG_WORKER_URLS` 播种的 worker 不进集群视图**（mesh 数据面漏镜像）。
   `registry.bootstrap()`（registry.lua:1007）直接调 `registry.add`，绕过
   `create_worker_handler` 里唯一的 `mesh_observe_worker(result.id)` 调用点
   （router.lua:2043）。后果：只要 worker 是靠 env 播种的（容器默认用法），
   `/ha/workers` 就永远是空表，`/ha/status` 的 `stores.worker_count` 也是 0，
   对等端看不到任何 worker。`PUT /workers/{id}` 一次即可补上（证明镜像路径本身
   没问题，缺的是那次调用）。
   复现：`SMG_ENABLE_MESH=1 SMG_WORKER_URLS=http://…` → `GET /ha/workers` == `[]`，
   而 `GET /workers` 里该 worker `is_healthy: true`。
2. **镜像的 health / model_id 冻结在注册瞬间，永不刷新**。
   `mesh_observe_worker` 在 POST /workers 的 handler 里同步调用，此时 discovery
   还没跑，写进去的是 `health=false` / `model_id="unknown"`；健康检查把它转成
   healthy 之后没有任何地方重新镜像（`hb.lua` 不引用 mesh，`mirror_mesh_state`
   只镜像 policy + tree，且定时器跑在 `eviction_interval_secs`（缺省 120 s）上）。
   实测 t=0 写入 `(false,"unknown",version=1)`，t=20 s 完全不变，且 kill worker
   之后也不变（version 始终 1）。对等端因此把健康 worker 看成不健康。
   `test_mesh_http.py` 里那三条 DIVERGENT/修复证明成对出现：冻结 → PUT 后
   `health=true, model_id=beta`。
3. **`/_ui/config` 的 HEAD 走 POST 分支**、**`/_ui/history` 缺 `app:head` 孪生**
   （见 §3.1）。第 2 条是 router.lua 路由表自身的不对称：同一张表里
   `health/liveness/readiness/v1/models/model_info/server_info/engine_metrics/
   metrics/workers/v1/loads/get_loads` 全都有 `app:head`，只有
   `_ui/logs`、`_ui/stats`、`_ui/logs/backends`、`_ui/history` 四条没有 ——
   前三条被 ui.conf 的 exact location 兜住了（`method_any` 折叠 HEAD），
   `/_ui/history` 恰好是唯一一条「exact location 存在、但转给 router 后需要
   router 自己有 HEAD 注册」的，于是漏出来。
4. **契约套件里有一条断言会偶发失败（不是本轮引入，本轮抓到一次真实失败）**：
   `test_lua_router.sh` 的 `/_ui/stats avg_duration_ms is a number`。
   断言要求 `avg_duration_ms` 是 number，而实现只有一段时间样本进窗口时才给
   number：`observability.lua:525-530` 在 `dur_n == 0` 时返回 `cjson.null`，
   窗口宽度是 `LR_STATS_WINDOW_S`（缺省 10 s ≈ 51 个 200 ms 桶）。
   失败现场（`gates-20260930-065755.log`，当时本机有多个 agent 并发跑容器）：
   该 section 的 chat 与 `/_ui/stats` 都落在 06:58:28 同一秒，仍然拿到 `null`，
   也就是那两条 chat 的时间样本没有进到窗口里。
   能确定的是这条断言把「窗口非空」当成了不变量，而它并不是：实测同一实例上
   发 3 条 chat 后 `avg_duration_ms` = 12.33，t+4 s / t+8 s 仍是 12.33，
   **t+12 s 变成 `None`**（窗口干净过期）。也就是说只要读到 stats 的时刻离最后
   一条被记账的 chat 超过 10 s，这一条必然 FAIL。
   没能确定的是失败那一轮里为什么「同一秒」也算空 —— 排除了一个嫌疑：
   `record.duration_ms == 0` 被 skip（对齐 Rust `request_log.rs:586`）在空闲机上
   不会发生（连跑 120 条 chat，最短 `duration_ms` 9 ms，无 0）；4 个 observability
   section 并发自压也全过（27/27 ×4）。所以还差一个能稳定复现的路径，
   留给持有该文件的人顺着 `note_window` → `lr_stats` dict 写入失败
   （`d:set` 返回值被忽略）这条线继续查。
   两种改法都比现在好：断言改成 `type == "number" or . == null`
   （正好对齐 Rust —— `avg_duration_ms: Option<f64>`，`dur_n == 0` 时也是 `None`，
   `request_log.rs:327,608`）；或者在断言前补一条 chat，代价是永远看不到空窗口。
   本任务不动 `test_lua_router.sh`。

5. **两处 `Content-Length` 与正文长度差 1 的观察**（`/nope` 的 HEAD：85 vs 86；
   `/metrics` 的 HEAD：40415 vs 42343）不是 bug：404 sink 把请求方法写进了
   message（"No route for GET /nope" → "…HEAD /nope2"），`/metrics` 序列在两次
   请求之间增长。已在 head_routes 里按上面的规则处理。

## 5. 已知 skip / 覆盖边界

- `conf/grpc-prototype.conf` 不在门禁内。它是 gRPC 接线原型，未并入模板
  （README 目录表已注明），`openresty -t` 需要额外模块。
- `nginx.conf.template` 的渲染产物由 `build` gate 的构建期 `-t` 覆盖，脚本不单独跑。
- mesh 双真节点（两个容器互 seed）仍未进任何套件：本轮试过，A 节点在
  `--network host` 下拿不到自己的宿主端口（`start_router` 内部选端口，
  `SMG_MESH_SELF` 无法先验），而契约套件的 fake peer 已覆盖收敛 / 鉴权 / 广播
  三要素。这条与 `doc/gap-integration.md` §6 的遗留一致。
- `test_pd` / `test_history` / `test_mesh` 是未接线模块的单测，绿不代表 HTTP 面
  可用；接线状态以 `doc/feature-gap.md` §3.4 为准。
- `head_routes` 的 `/_ui/`（静态 SPA）只在 `ui/` 已构建进镜像时有内容；
  `SKIP_ENV=build` 且镜像过期时这一条可能因缺文件而 404。
- e2e 套件把 `SMG_METRICS_PORT` 默认置 0（`_lib.start_router`），因为本机
  29000 被 Rust 网关占用；独立 metrics 端口的行为由契约套件的 prometheus 段覆盖。

## 6. 本轮运行记录

日志：`/data/tmp/lr-gates/FULL_RUN_1.log`（`KEEP_GOING=1`，12 个 gate 全跑）、
`FINAL_STRICT.log` + `FINAL_STRICT.stdout`（默认严格模式，全绿）、
`gates-20260930-065755.log`（严格模式，抓到 §4.4 那条 flake 的一轮）。

| gate | 结果 | 计数 | 耗时 |
|---|---|---|---|
| build | PASS | 镜像 + 构建期 `openresty -t` | 1 s（缓存命中） |
| conf | PASS | 双 conf syntax OK | 1 s |
| unit | PASS | tree 67 / policies 118 / hash 795 / history 731 / mesh 361 / pd 219（luajit）；tree 67 / policies 118 / hash 795 / integration 66 / tokenizer_parse 316（resty） | 6 s |
| contract | PASS | **659 passed / 0 failed / 3 notes** | 78 s |
| probes | PASS | **25 checks / 0 failed**（此前 24 过 1 红） | 8 s |
| e2e_stateful | PASS | 43 / 0 | 38 s |
| e2e_policies | PASS | 65 / 0 | 18 s |
| e2e_ui_bridge | PASS | 19 / 0 | 6 s |
| e2e_errors | PASS | 10 / 0 | 6 s |
| e2e_effort | PASS | 4 / 0 | 2 s |
| head_routes | PASS | **118 / 0（新建）** | 2 s |
| mesh_http | PASS | **48 / 0（新建）** | 18 s |

合计 **12 gates passed / 0 failed / 0 skipped**（上表取自 `FULL_RUN_1`）。
严格模式那一轮同样 12/12 全绿，独占耗时 185 s（07:07:25 → 07:10:30）。检查项总数：659 + 25 + 43 + 65 + 19 + 10 + 4 +
118 + 48 = **991 条 HTTP/端到端断言**。纯 Lua 单测两个口径合计 3 653 条断言
（luajit 2 291 + resty 1 362），去掉 tree/policies/hash 在两边重复跑的 980 条，
唯一断言 2 623 条。

第一次严格跑（`gates-20260930-065755.log`，当时本机有其它 agent 并发跑容器）停在
contract 的 `/_ui/stats avg_duration_ms is a number`，即 §4.4；此后两轮都是 659/0/3。
该断言由套件持有者处理，本任务未碰那个文件。

`SKIP_ENV` 的三条行为都实测过：未知 gate 名 → `exit 2` 并列出已知名字；
`GATE_ONLY=conf` → 只跑 conf 且汇总记 1 passed；`SKIP_ENV=unit,build` →
两个 gate 各留一行 SKIPPED，汇总记 `0 passed, 0 failed, 2 skipped`。
