# K8s discovery 的 watch / resourceVersion / fieldSelector 与 router pod 发现

实现文件：
[service_discovery.lua](../lualib/resty/luarouter/service_discovery.lua)（watch 传输、
fieldSelector、router pod 发现）、
[mesh.lua](../lualib/resty/luarouter/mesh.lua)（`adopt_member` / `retire_member` /
`suspect_member` / `find_member`）、
[config.lua](../lualib/resty/luarouter/config.lua)（5 个新旋钮）。
单测：[test_service_discovery.lua](../test/unit/test_service_discovery.lua)（298 checks）。
e2e：[e2e_discovery_dp.py](../test/integration/e2e_discovery_dp.py) 的 group D/E（新增 37 条断言）。

对应 Rust：`gateway/src/service_discovery.rs`（`kube::watcher` + `start_router_discovery`）、
`gateway/src/main.rs:1087`、`gateway/src/config/types.rs:375`。
本文只写与 Rust 的差异与取舍；相同部分按“已按上述文件复刻”处理。
前置文档：[gap-discovery-dp.md](gap-discovery-dp.md)（poll 形态与 pod→worker 规则）、
[gap-mesh.md](gap-mesh.md)（成员表 CRDT 与同步语义）。

---

## 1. watch（`SMG_SERVICE_DISCOVERY_WATCH`，默认 false）

### 1.1 为什么仍然默认关

Rust 无条件 watch；这里 watch 是可选的，因为**已验收的 poll 契约是默认行为**
（`gap-discovery-dp.md` §2 与 contract 套件的断言按 poll 语义写的）。开关只影响
`start()` 里选哪条循环：`discovery_watch` 关 → 原 poll `tick`；开 → `start_watch`。
两条循环共用同一个 `reconcile_infos()`，所以「一个 pod 变成什么」在两处必然一致。
`SMG_SERVICE_DISCOVERY_CHECK_INTERVAL_SECS` 在 watch 模式下不失效：它是 relist 的
兜底周期、stream 正常结束后的重连延迟，也是 watch 撑不住时退回 list 的节奏。

### 1.2 请求形状

```
GET /api/v1[/namespaces/<ns>]/pods?watch=true&allowWatchBookmarks=true
        [&labelSelector=...][&fieldSelector=...][&resourceVersion=...]
```

参数顺序固定，便于 grep 与断言。`resourceVersion` 只要已知就发（`0` 也发，不省略），
`allowWatchBookmarks` 恒开——bookmark 是静默期里唯一能让续传点保持新鲜的帧。
Authorization 头与 poll 完全一样（SA token，或 `SMG_KUBE_API_SERVER` 明示 http 时空手）。

### 1.3 不占请求协程、也不占 timer 协程

watch 是一条永不结束的 chunked 响应。若把它放在一个 timer 协程里循环读，nginx 停服时
`premature` 只能送到**新一次**排程，送不进已经在 cosocket 读取里阻塞的协程，于是这个
worker 会拖到 read timeout 才退出。因此结构是：

```
watch_tick (timer, 每次一跳)
  └─ watch_pass(): 必要时先 LIST → open_watch() → consume_watch() → 返回「下次延迟秒数」
```

一条流的寿命 = 一次 timer 调用。`consume_watch()` 每次 `sock:receive()` 都带
read timeout（§1.6），所以 timer 协程最长只阻塞这么久，之后重新排程；`premature` 到了
就正常退出，`watch.running` 复位。cosocket **不进连接池**（`connect_opts.pool=nil`），
出口路径一律 `sock:close()`：一条被握住的流没有消息边界可以归还，被别的调用借走会读到
上一个 watch 的事件。

流读取本身：`read_response_headers()` 读状态行 + 头，然后按 `Transfer-Encoding` 分两种
framing——
* chunked：逐 chunk 取 size 行、按长度取 body、吃掉 CRLF，**攒进行缓冲**再逐行 decode。
  chunk 边界不带语义（API server 会把多个事件塞进一个 chunk，也会把一个事件切成多段），
  所以不能按 chunk 解码；行分隔符也不能省（§5 记的实测假服务器 bug）。
* 非 chunked：逐行读。真实 API server 不这么发 watch，但中间隔一层代理时可能遇到，
  支持它的成本是零。

### 1.4 增量维护与 reconcile 时机

模块级 `watch = {rv, tracked, backoff, streams}`（`watch.tracked` = pod name → pod_info）。
`apply_watch_event()` 把一帧折进 tracked：

| 事件 | tracked 变化 | 说明 |
|---|---|---|
| ADDED / MODIFIED | `pod_from_api()` 结果写入；返回 nil 则**删除**该键 | 标签不再匹配、变成 router pod、丢掉 podIP 与「pod 没了」等价处理 |
| DELETED | 删键 | 未知名字视为无需处理（不计数、不触发 reconcile） |
| BOOKMARK | 不动集合，只推进 `watch.rv` | |
| ERROR | 停止本条流 | 见 §1.5 的 410 |

不健康（Ready=False）的 pod **留在** tracked 里：它还存在于集群中，只是不该接流量，
reconcile 会把它的 worker 摘掉而不会把 pod 忘掉。这与 Rust 的 `applied_objects()`
（按 `PodInfo::is_healthy` 过滤后才注册）等价。

每个事件都立刻 `reconcile_infos()`，而不是攒到流断掉再一次性落地。Rust 是「pod 出现即注册」，
攒批会让新写的 watch 比它替代的 poll 更慢（最坏慢一个 interval）。

### 1.5 resourceVersion 续传、410 与退避

| 情况 | 动作 | 计数 |
|---|---|---|
| 无 rv（首启 / 410 之后） | 先 LIST，取 `metadata.resourceVersion`，用整表覆盖 tracked | |
| LIST 响应没有 rv 字段 | 记 WARN，退回每 interval 一次 LIST（不开流：从「现在」开流会静默漏掉 list 与流之间的那段变化） | |
| 流断开（eof / idle timeout / 对端关闭） | 保留 rv，回到 §1.3 排下一次 pass，**带 rv 重连**；不 relist | 第 2 条及以后的流算 reconnect |
| LIST 或 watch 响应 410 | `rv=nil`、清空 tracked、延迟 1s 重开（即 relist） | `errors_total{kind="gone"}` |
| 流内 `{"type":"ERROR","object":{"reason":"Expired"或"code":410}}` | 同上（200 已经发出去了，所以流中的 410 只能以此形式到达） | `errors_total{kind="stream"}` |
| 非 200 响应 | 退避重连 | `errors_total{kind="status"}` |
| connect / TLS / send / 读头失败 | 退避重连 | `errors_total{kind="transport"}` |
| chunk framing 解析失败 | 退避重连 | `errors_total{kind="transport"}` |
| LIST 401/403 | 不动现有 worker，一条 WARN（RBAC 提示），按 interval 重试 | `registrations{result="failed"}` |

退避：1s → ×2 → 上限 300s（`WATCH_MAX_BACKOFF`，与 Rust 的
`service_discovery.rs` 一致）；一次成功的流（哪怕只是 idle 到期）把退避清回 1s。

### 1.6 指标

| 指标 | 标签 | 语义 |
|---|---|---|
| `smg_discovery_watch_events_total` | `source`,`type`=added/modified/deleted/bookmark | 折进 tracked 的帧数 |
| `smg_discovery_watch_reconnects_total` | | 第 2 条及以后打开的流（首次开流不计） |
| `smg_discovery_watch_errors_total` | `kind`=gone/status/transport/stream | 410、非 200、传输失败、流内 ERROR |

Rust 的 watcher 只有 `Error in Kubernetes watcher` 一条日志，没有这三个族；这是 Lua 侧
超集（`observability.lua` 的 `HELP` 表不在本次所有权内，所以新族只有 `# TYPE`，
见 §6.7）。原有的 `smg_discovery_registrations_total` / `deregistrations_total` /
`sync_duration_seconds` / `workers_discovered` 在 watch 模式下照常写：`sync_duration`
只有真正发起过 list 才记样（流本身不是「一次 sync」，把它算进去会让 p50 失去意义）。

---

## 2. fieldSelector（`SMG_KUBE_FIELD_SELECTOR`）

`parse_field_selector()` 只认等值：`k=v` 与 `k==v`，逗号或空格分隔。发送前先
`field_selector_text()` 规范化，且**每一项都在 `pod_from_api()` 里本地复核**
（`field_matches`），假 API server 或语义不同的服务端都无法因此放宽集合。

支持字段与 Kubernetes 一致的那个子集：`metadata.name`、`metadata.namespace`、
`status.phase`、`status.podIP`、`spec.nodeName`。其余一律判**不匹配**，而不是忽略：

* `!=`、`>`、`<`、裸词 → 该项标 `unsupported`，任何 pod 都不匹配它；
* 未知字段名（如 `status.hostIP`）→ 同样不匹配。

理由与 `gap-discovery-dp.md` §2 的 labelSelector 一样：真实 API server 对不支持的
fieldSelector 是 400 拒绝，客户端若「忽略未知字段」会把结果放宽成全集，比拒绝更糟。
为了让这个选择可见，`start()` 在启动时打一条 WARN 点名第一个不支持的项
（"it matches nothing, so no pod will be discovered"）。poll 与 watch 两条路径共用
`stream_opts()`，所以 fieldSelector 对两种模式都生效。

---

## 3. router pod 发现（`SMG_ROUTER_SELECTOR`）

### 3.1 分工：只改 mesh 成员，绝不注册 worker

`pod_from_api()` 在算 worker 之前先判 router_selector：命中就直接返回 nil。因此
router pod 不可能进入 `desired_workers()`，即使 `SMG_SELECTOR` 与它的标签**完全相同**
（e2e 就是故意让两个 selector 相等来钉这条）。router pod 的视图由另一个纯函数
`router_pod_from_api()` 产出（name/ip/phase/ready/deleting + mesh_port），两条路径不共享
中间状态——把 gateway 自己当推理候选负载均衡，是这类功能最贵的错误。

循环与 worker discovery 分开：`router_tick()` 独立 timer，周期同为
`SMG_SERVICE_DISCOVERY_CHECK_INTERVAL_SECS`，每轮一次
`GET /api/v1/pods?labelSelector=<router_selector>`。

### 3.2 地址来源

`http://<status.podIP>:<注解端口>`，注解默认 `sglang.ai/mesh-port`
（`SMG_ROUTER_MESH_PORT_ANNOTATION` 覆盖），注解缺失/非 1..65535 整数时退回
`SMG_SERVICE_DISCOVERY_PORT`（`SMG_SERVICE_DISCOVERY_CHECK_*` 那个端口旋钮）。

Rust 自己对注解名有两套答案：`config/types.rs:380` 是 `sglang.ai/mesh-port`，
`main.rs:947` 与 `service_discovery.rs:65` 是 `sglang.ai/ha-port`。取 types.rs，因为它是
shipped 配置的默认值，且 `main.rs:1096` 在缺 router_config 时也回落到它。旧 chart 标注的
集群用环境变量改一下即可。

### 3.3 成员写入：三种事件 + 缺席

对应 Rust `start_router_discovery`（`service_discovery.rs:622`）的分支，外加 poll 特有的
一条：

| 观察 | mesh 写入 | 备注 |
|---|---|---|
| `deletionTimestamp` 非空 | `retire_member()` → down | 记录保留（还要靠同步告诉对端） |
| Running + Ready + podIP | `adopt_member()` → alive | 键先用 pod name，对端自报后迁成它的身份 |
| 不健康 | `suspect_member()` → suspect | **仅当条目已存在**：从没见过且不健康的 pod 不该凭空成为成员（Rust 同规则） |
| 本轮 list 里缺席（且之前 adopt 过） | `retire_member()` → down | poll 没有 DELETED 可学，只能推断；watch 模式也不改这条（router 列表很小，见 §3.5） |

`adopt_member()` 有三条不写表的情况，都是为 LWW 服务的：
`self`（本实例那台 pod）、`unchanged`（同址且已 alive/suspect）、`invalid`（无名或无址）。
轮询每周期都会重放同一批 pod，若每次都写就把版本推高一格，成员表在两个节点之间永远互相
覆盖。地址没变但状态是 suspect 时也不写——那是同步失败判定的结论，不该被「K8s 说它还在」
这条独立证据推翻。

### 3.4 self 识别

按 `host:port` 文本比对 `SMG_MESH_SELF`。命中 self 时**既不 adopt 也不进 tracked**：
tracked 是「缺席 retire」的候选集，把自家写进去会在某轮 list 恰好不含自己时把自己 retire
掉。`result.skipped_self` 单独计数，便于区分「找到了自己」和「谁都没找到」。

### 3.5 动态成员与 mesh 既有语义的关系

* **quorum 不变**：`SMG_MESH_PEERS`（种子）在 `new()` 里进成员表并参与 quorum 计算；
  发现来的成员只进成员表。所以 quorum 仍是「启动时的配置」语义（`gap-mesh.md` §3.3）。
* **三方转发不覆盖动态成员**：`merge_membership()` 对第三方转发的记录只补 address、
  绝不新建键（防止一个节点长出两个身份）。因此每台 router 必须自己查 K8s ——
  这也是 Rust 的形态（每个 gateway 自己 watch pods）。
* **同步记账键**：pod 名会被 `apply_snapshot` → `migrate_member` 迁成对端自报名，
  所以 `retire_member`/`suspect_member` 都带 address 兜底（`find_member(name, address)`）。

### 3.6 启动条件与 mesh 未启用

router 发现要求三件事同时成立：`SMG_SERVICE_DISCOVERY=1`（有 API server 可问）、
`SMG_ENABLE_MESH=1` 且 `SMG_MESH_PEERS` 非空（mesh 实例存在）、`SMG_ROUTER_SELECTOR` 非空。
mesh 实例不存在时只打**一次** WARN：`router selector configured but mesh is not enabled
(SMG_ENABLE_MESH/SMG_MESH_PEERS); skipping router discovery`。

第一次发现到对等端时 `adopt_member()` 会顺手 `self:start()` 拉起同步定时器：
只写了 `SMG_MESH_PEERS=<自身 URL>` 的实例在 `init.lua` 的 `inst:start()` 那里会拿到
`no mesh peers`，这一句把「静态列表里只有自己」的实例接回 gossip。init.lua 的接线本身
由 inflight 任务持有，本模块只在 `start(cfg)` 内部自启动，另导出
`_M.start_watch(cfg)` / `_M.start_router_discovery(cfg)` 供接线复用。

---

## 4. 配置项

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `SMG_SERVICE_DISCOVERY_WATCH` | `false` | 用 watch 流维护 pod 集合（poll 仍是 fallback 与兜底） |
| `SMG_SERVICE_DISCOVERY_WATCH_IDLE_TIMEOUT_SECS` | `120` | 一次流读取允许静默多久；到点丢弃并从 rv 重连 |
| `SMG_KUBE_FIELD_SELECTOR` | 无 | 等值 fieldSelector，poll/watch 都生效 |
| `SMG_ROUTER_SELECTOR` | 无 | 命中它的 pod 进 mesh 成员表，不进 worker 表 |
| `SMG_ROUTER_MESH_PORT_ANNOTATION` | `sglang.ai/mesh-port` | router pod 的 mesh 端口注解 |

env 声明三处：`conf/nginx.conf.template`、`conf/lua-router.conf`、
`test/conf/nginx-lua-router.conf`（缺 `env` 声明时 OpenResty 会把它挡在 Lua 之外，
表现为「配了没生效」）。

RBAC：watch 需要 `pods`（或 `namespaces/<ns>/pods`）的 **watch** 动词，不只是
list/get；namespace 参数决定资源形状。缺 watch 权限时 `open_watch` 收到 403，
计入 `errors_total{kind="status"}` 并退避重连，现有 worker 不受影响。

---

## 5. 验证与数字

| 层面 | 命令 | 结果 |
|---|---|---|
| 单测（luajit 口径） | `docker run … authz:latest test/unit/test_service_discovery.lua` | **298 passed, 0 failed**（本次新增 137 条） |
| mesh 单测 | 同上 `test_mesh.lua` | 361 checks passed（未回退） |
| 其余 luajit 单测 | test_tree/policies/hash/history/pd/jwks/otel | 67/118/795/731/262/120/131 全过 |
| resty 口径单测 | test_tree/policies/hash/integration/tokenizer_parse | 67/118/795/66/316 全过 |
| conf | `openresty -t` 两份配置 | syntax ok / test successful |
| 全量门禁 | `GATE_ONLY=… test/final_gates.sh` | build / unit / contract（**841 条，0 failed**）/ e2e_discovery_dp（**117 checks, 0 failed**）/ mesh_http 全过；e2e 全量 18 gates 亦 0 failed |
| e2e 组 D（watch） | 同上 | 23 checks：ADDED 注册、MODIFIED→Ready=False 摘除、MODIFIED 回来、DELETED 摘除（且只摘它）、事件计数、dereg 计数、断线后按 rv 续传（list 调用数不增）、reconnect 计数、每条重连都带 rv、410→relist→集合不丢、流恢复、gauge、watch 下推理仍通 |
| e2e 组 D（fieldSelector，与上同组） | 同上 | 2 checks：参数到达 API server + 本地复核只留命名 pod |
| e2e 组 E（router pod） | 同上 | 12 checks：只写自身 peers 的两台从 pod 列表收敛成 2 成员、地址=podIP+注解端口、两边 view 一致、**selector 相同也不注册 worker**、/workers 空、adopt 后 gossip 真的起来、缩容后 down 且稳定、记录不被删、自家不 retire、存活节点继续服务 |

假 API server（`e2e_discovery_dp.py` 的 `K8sHandler`）是真 chunked 流：每个连接按自己请求
里的 `resourceVersion` 在事件日志里定位游标（否则重连窗口里的事件会被上一个还在拆的流抢走），
`gone_rv` 只对持有该版本的 watch 请求返回 410，list 一律把版本推进一格并清掉 410 标记。

验证期间发现并修掉的三个真问题（都不是测试断言问题）：

1. `reconcile_infos(cfg, opts, infos, {})` 里 `result.removed + 1` 对 nil 做算术。
   watch 每事件传一个空表进来，于是**先抛错、后抛指标**：worker 已经被摘掉，
   `smg_discovery_deregistrations_total` 与 `workers_discovered` 没写，
   registry 与 /metrics 悄悄不一致，而且只在 watch 模式发生。已给四个计数器补默认值，
   并加了一条 stub registry/observability 的单测把这条钉住。
2. `config.lua` 缺 `discovery_watch_idle_secs` 的取值定义（代码与三处 `env` 声明都有，
   只有 config 里没有 → 旋钮恒为 nil，退化成 `2 × interval`）。已补，默认 120s。
3. 假 API server 的 chunk 里没带行分隔符（真 API server 的 watch 是 newline-delimited
   JSON），客户端的行缓冲因此永不 flush、事件全部静默丢失。测试侧修 framing。

---

## 6. 与 Rust 的偏差与限制

1. **watch 默认关**。Rust 总是 watch。这里是 opt-in，为的是保住已验收的 poll 契约
   （§1.1）。开与关共用同一个 reconcile，所以不会有两套 pod→worker 判定。
2. **watch 的降级不是热切换**。LIST 响应没有 `resourceVersion`、或 list 本身失败时，
   这一条循环退回按 interval list（等价于 poll），不会因此丢 worker；但它不会把
   `discovery_watch` 改掉，日志里 "(watch)" 与 "(poll, not watch)" 只反映启动时的选择。
3. **idle read timeout 回收流**。`SMG_SERVICE_DISCOVERY_WATCH_IDLE_TIMEOUT_SECS` 内
   没有任何字节（包括 bookmark）就断流重连，所以一个「连上了但什么都不发」的
   API server 表现为周期重连而不是永久挂死；代价是每窗口一条 reconnect 计数。
4. **一条流覆盖全部 selector**。PD 模式（`SMG_PREFILL_SELECTOR` +
   `SMG_DECODE_SELECTOR`）下 labelSelector 发不出去（两个标签集合无法合成一个等值串），
   于是整表 list + 本地过滤，与 poll 一致（Rust 是两条 watch 流）。
5. **router pod 只 poll，不 watch**。Rust 对 router pod 也用 watcher。router 数量是几个
   实例，多开一条长连接没有收益，却会让「K8s 侧的 router 视图」与 worker 视图共用一套
   流管理代码；间隔粒度（默认 60s，测试里 1s）足够。
6. **缺席 retire 是推断**。poll 看不到「在两个周期之间出现又消失」的 router pod，
   也就不会为它写过 down；反过来，一次 API server 返回的**不完整 list**（分页未跟随、
   权限收窄到部分 namespace）会被当成「pod 都走了」而 retire 掉成员。当前实现不分页，
   所以大集群（>500 pod）下这条是真实风险：请用 namespace 作用域
   （`SMG_SERVICE_DISCOVERY_NAMESPACE`）和精确 selector 限定 list 范围。
7. **动态成员的 status 由两方写**：发现写 alive/suspect/down，对端自报快照也写自己的
   status，而 `merge_membership` 让自报优先（`gap-mesh.md` §3.3 的既有规则，
   `/ha/shutdown` 契约依赖它）。因此**只有当对端进程真的不在了**，discovery 的 down
   才会稳定成立；进程还活着而 pod 被从列表删掉时，成员会在下一个 sync 周期被洗回
   alive。e2e 组 E 显式测的是前者，并把 `SMG_MESH_SUSPECT_THRESHOLD`/
   `SMG_MESH_UNREACHABLE_TIMEOUT_SECS` 抬高，确保 down 只能由 discovery 写。
8. **纯动态起步需要一个自身地址**。`mesh.from_env` 在 `SMG_MESH_PEERS` 为空时不建实例
   （这是 `SMG_MESH_PEERS 为空 = 不启用 mesh` 的既有契约），所以「完全不写 peers、
   全靠 K8s 拼集群」目前要写成 `SMG_MESH_PEERS=<本实例 URL>`。放宽它需要改 mesh 的
   启用条件与 /ha/* 503 契约，不在本次范围。
9. **self 识别是文本比较**：`http://localhost:<同一个端口>` 与 `SMG_MESH_SELF` 的写法
   不同就会被当成另一个节点。pod IP 与 `SMG_MESH_SELF` 都取自 `status.podIP` 时不会踩到。
10. **新指标没有 `# HELP`**：`HELP` 表在 `observability.lua`（本次所有权之外），
    因此只有 `# TYPE`。渲染逻辑对有 series 的族类型判定正确，promtool 不会因此报错。
11. **字段选择器等值子集**：`!=`、`>`、`<`、存在性语法都不支持（§2），写出来会匹配不到
    任何 pod 并在启动时点名的 WARN 里说明。
12. **watch 与 poll 不同时跑**。`start()` 二选一；同时跑会出现两套 reconcile 抢 registry
    （这与 `gap-discovery-dp.md` §2 里「discovery 只在 worker 0 跑」的理由同源）。
13. **需要 root 接线的部分**：无。`service_discovery.start(cfg)` 内部完成两条新循环的
    启动，`init.lua` 未改动；模块导出 `start_watch` / `start_router_discovery` 以便
    接线方显式控制（当前调用点在 `start()` 里，与 poll 同位置）。
