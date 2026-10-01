# lua-router mesh / HA 状态同步（gap 补齐）

实现：[lualib/resty/luarouter/mesh.lua](../lualib/resty/luarouter/mesh.lua)
单测：[test/unit/test_mesh.lua](../test/unit/test_mesh.lua)（361 checks，luajit 与 resty 两种环境全绿）

本阶段只新增文件，`router.lua` / `conf/*` 未改，因此部署形态不变：
`/ha/*` 仍然由 router.lua 的 `mesh_disabled_handler` 返回固定 503。接线见 §4。

参考实现对照：
`gateway/src/routers/mesh/handlers.rs`、`gateway/src/server.rs:1393-1404`、
`smg-mesh-1.0.0/src/{stores,crdt,sync,partition,rate_limit_window,service}.rs`。

---

## 1. 配置

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `SMG_MESH_PEERS` | 空 | 逗号或空格分隔的对等端 base url，如 `http://10.0.0.1:30000,http://10.0.0.2:30000`。为空 = 不启用 mesh，`/ha/*` 全部固定 503。 |
| `SMG_MESH_SELF` | 无 | 本实例地址（base url）。节点名默认取它的 `host:port`。 |
| `SMG_MESH_SELF_NAME` | `hostport(SMG_MESH_SELF)` | 显式节点名。 |
| `SMG_MESH_SYNC_INTERVAL_SECS` | 2 | 全对等同步周期。 |
| `SMG_MESH_UNREACHABLE_TIMEOUT_SECS` | 30 | 超过这个时间没被同步证实的成员算不可达。 |
| `SMG_MESH_SUSPECT_THRESHOLD` | 2 | 连续同步失败几次后 `alive → suspect`。 |
| `SMG_MESH_QUORUM` | `floor(N/2)+1` | N = 配置成员数 + 自己。 |
| `SMG_MESH_MIN_CLUSTER_SIZE` | 3 | 已知成员不足此数时不裁仲裁（见 §3.3）。 |
| `SMG_MESH_RATE_WINDOW_SECS` | 1 | 全局限流窗口宽度（Rust `RateLimitWindow::window_seconds`）。 |
| `SMG_MESH_RPC_TIMEOUT_MS` | 2000 | 单次对等端请求超时。 |
| `SMG_MESH_SNAPSHOT_MAX_BYTES` | 3 MiB | 单个 cache_aware 树快照 blob 上限，超限跳过不发送。 |

`mesh.from_env(getenv)` 一次装配；`mesh.init()` / `mesh.instance()` 管进程内单例。

---

## 2. 协议

### 2.1 内部端点

全部挂在本实例的服务端口上（与 `/ha/*` 同端口，见 §6 的安全差异）：

| 端点 | 方法 | 请求体 | 响应 |
|---|---|---|---|
| `/_mesh/internal/ping` | GET | — | `{protocol,node,addr,status,version,draining}` |
| `/_mesh/internal/sync` | POST | 本节点快照（b64） | 对端快照（b64），`Content-Type: application/x-mesh-b64` |
| `/_mesh/internal/apply` | POST | 对端快照（b64） | `{applied,node}` |
| `/_mesh/internal/state` | GET | — | 本节点快照（b64），排障用 |

一轮 tick = 对每个 peer 一次 `POST /_mesh/internal/sync`：请求体带自己的完整快照（推送本地写入），
响应体带对方的完整快照（拉取远端写入）。一次往返完成双向收敛，比 Rust 的
ping + broadcast 两条 RPC 少一半往返。`/_mesh/internal/ping` 保留给外部探活与排障，
不计入同步。

`apply` 端点给「本节点只想广播、不想拉回」的场景（`/ha/shutdown`、`/ha/rate-limit` 写后
广播），也方便从别处（如 curl）注入状态。

### 2.2 快照格式

正文 = `base64(JSON)`。base64 是为了让树快照这类不透明 blob 在 JSON 里安全往返
（纯 Lua 实现，不依赖 `ngx.encode_base64`，两种环境同一套编解码）。

```jsonc
{
  "protocol": 1,          // 不匹配直接 400，不静默吞包
  "node": "alpha",        // 自报名
  "addr": "http://10.0.0.1:30000",
  "ts": 1790734611456789, // 微秒
  "seq": 12,              // 本地写入计数（预留水位）
  "since": null,          // 预留：本实现永远发全量
  "draining": false,
  "stores": {
    "members":  [ {"key","value","ts","version","node"} ],
    "workers":  [ ... ], "policies": [ ... ], "apps": [ ... ],
    "trees":    [ {"key","value","ts","version","node","vec"} ],
    "manual":   [ ... ]
  },
  "rate": [ {"key","window_s","current","windows":[{"id","pos","neg"}]} ]
}
```

`stores.*` 每条记录都带 LWW 元数据（`ts`/`version`/`node`），`trees` 额外带 `vec`
（版本向量）。store 与 Rust `stores.rs::StoreType`（5 个：Membership / App / Worker /
Policy / RateLimit）的对应关系：

| 本实现 | Rust | 说明 |
|---|---|---|
| `members` | `MembershipStore` | 同名同字段 |
| `workers` | `WorkerStore` | 字段名同 `WorkerState` |
| `policies` | `PolicyStore`（`policy:<model>`） | 字段名同 `PolicyState` |
| `apps` | `AppStore` | 字段名同 `AppState`，含 `global_rate_limit` 配置 |
| `trees` | `PolicyStore`（`tree_state_key(model)` = `tree:<model>`） | Rust 与 policy 共用一个 store；这里拆出来是因为它走版本向量而不是纯 LWW |
| `manual` | 无对应 | 本实现新增：把 manual 粘滞映射纳入复制（Rust 的 manual 状态留在进程里，不参与 mesh） |
| `rate` | `RateLimitStore` | PNCounter，见 §3.5 |

字段名与 Rust 对齐，`/ha/*` 的响应可以直接透出。

### 2.3 成员表收敛

`SMG_MESH_PEERS` 是**种子**，不是全部视图。每个节点先把自己写成 `alive`、把种子写成
`init`（未经证实），之后每轮同步交换完整成员表，于是每个节点只写部分对等端的三角配置
也能收敛到同一视图（单测覆盖）。

配置里把自己也写进 `SMG_MESH_PEERS`（或用另一个 hostport 指向本实例）不会自我同步：
`peer_bases` 与成员表都按 hostport 过滤掉自己的地址，成员表因此不会长出一个幻影键、
再把单节点集群自己判成 degraded。

身份以节点自报为准：`merge_membership` 只采纳「`item.node == member.name`」的自报记录来
新建成员；第三方转发的记录只补地址，不新建键。若种子先前按 `hostport(url)` 记过账而对端
自报了别的名字，`migrate_member` 会把观测时间/失败计数迁到自报名下并删掉旧键
（单测覆盖）。这样成员表不会出现「同一个节点两个身份」导致 quorum 虚高。

`status` 生命周期：`init → alive`（同步成功）、`alive → suspect`（连续
`suspect_threshold` 次失败）、`suspect → down`（且已超过 `unreachable_s`）、
`*/→ alive`（重新同步成功）。节点自己 POST `/ha/shutdown` 后自报 `leaving`，
该状态**无条件**被采纳且不被「它还回 HTTP」洗白。

---

## 3. 冲突策略与分区

### 3.1 LWW 三级决胜

`ts`（微秒）→ `version` → `node` 名字典序。Rust `LWWRegister::merge`
（`crdt.rs:87`）只比 `timestamp`、相等时比 `version`，两者都相等时谁都不换 —— 两个节点
会永久保留不同的值。补上 node id 决胜后，任意合并顺序都收敛到同一胜者（单测双向验证）。

`ts` 取各自机器的时钟（微秒），所以对等端之间的时钟偏移会直接决定并发写入的胜者。
这与 Rust 的 `SystemTime::now()` 一样依赖 NTP，没有引入新问题；偏移超过一个请求间隔
的集群应当先修时钟，而不是调代码。

### 3.2 版本向量 + LWW 兜底（树快照）

cache_aware 快照是 blob，带 `vec[node] = version`。合并时先用向量判因果：
一方包含另一方的全部写入且更多 → 采纳更多的一方；无法比较（并发写）→ 退回 LWW。
这修掉了 Rust `tree_ops` 操作日志缺失时「旧快照覆盖新快照」的问题。
本实现只传整棵快照、不传操作日志（任务书允许），代价是每轮带宽与树大小成正比。

### 3.3 分区检测

`partition_state()` 返回 `normal` / `partitioned_with_quorum` /
`partitioned_without_quorum`，判定基于**已知成员**（成员表里除 `leaving` 之外的全部节点）：

1. 已知成员数 < `min_cluster_size` → 永远 `normal`；
2. 没有过期成员 → `normal`；
3. 可达数 ≥ quorum → `partitioned_with_quorum`（继续服务）；
4. 否则 → `partitioned_without_quorum`（`should_serve() = false`）。

与 `partition.rs` 的两处差别：

* Rust 只把 `status == Alive` 的节点计入 `unreachable_count`，于是被自己降级成 `DOWN`
  的成员凭空消失、集群又显示 `normal`。这里 `down`/`suspect` 与 `alive` 一样是期望成员，
  降级后分区判定依然成立。
* 从未被同步证实的种子停在 `init`，同样会被计入期望成员。也就是说配置里写了一个
  永远起不来的对等端，本节点会长期停在 `degraded`（有 quorum 时仍继续服务）。
  这是刻意的：静默接受「配置里有节点连不上」会让运维以为集群健康。要摆脱就去掉那行
  配置或把 `min_cluster_size` 调小。
* Rust 定义了 `min_cluster_size` 却没在 `detect_partition` 里用它。两节点集群的
  `quorum=2`，任一对等端掉线就变成「无 quorum」而停服 —— 太激进。这里成员不足
  `min_cluster_size` 时不裁 quorum，并在 `should_serve()` 之外把 `draining` 单独作为
  停服条件。

### 3.4 tombstone

删除写成 `{_deleted=true}` 并推进 `ts`/`version`，`count_live`/`all` 过滤掉。
Rust `CRDTMap::remove` 是硬删，`merge` 会把对端残留的旧值复活（`sync.rs` 没有删除标记）；
这里加了墓碑（单测「旧快照不能复活已删 worker」覆盖）。

### 3.5 限流窗口

`windows[window_id] = {pos={node=n}, neg={node=n}}`，per-actor 取 max 合并
（PNCounter 语义），窗口总量 = 当前窗口的 `sum(pos) - sum(neg)`。滚窗只是 `current`
换 key，旧桶保留一个窗口宽度后丢弃。

与 Rust 的三处差别：

* **重置方式**：Rust 用「按当前值负增」绕过 PNCounter 不能 reset 的限制
  （`sync.rs:309` 源码自己标注是 workaround），reset 与新请求竞态会把计数打到负数。
  这里换窗口 id，无竞态、无需负值。
* **不要求 owner**：Rust `sync_rate_limit_inc` 只有 owner 才记（`sync.rs:249`），
  非 owner 的请求直接不计入全局限额。这里任何节点都记自己的份，`rate_owner()`
  仅用于 `/ha/rate-limit/stats` 的可观测字段。
* **只算当前窗口**：Rust 语义是「每秒」，所以跨窗口的旧桶不能累加，否则限额变成 2×。
  代价是时钟落后不到一个窗口的节点，它的增量本轮不被计入（宁可少限几笔）。

---

## 4. router 接线建议（本阶段未执行）

### 4.1 路由与启动接线

配置侧不需要新共享字典：mesh 的状态表在 Lua 进程内存里（原因见 4.4），
`conf/*` 保持原样即可。要改的只有 router.lua 的路由注册和 `worker_init`：

路由（与 router.lua 现有 `mesh_routes` 同处注册，把 handler 换掉即可）：

```lua
-- init_worker_by_lua（resty.luarouter.worker_init 里，紧接 hb.start()）
local mesh = require "resty.luarouter.mesh"
local inst, err = mesh.init()          -- 读 SMG_MESH_*，无 peers 返回 nil
if inst then
    if ngx.worker.id() == 0 then
        local ok, terr = inst:start()  -- 只有 worker 0 跑同步定时器
        if not ok then ngx.log(ngx.WARN, "mesh start failed: ", terr) end
    end
end
```

```lua
-- router.lua build(): 用 mesh.dispatch 取代 mesh_disabled_handler
local mesh = require "resty.luarouter.mesh"
for i = 1, #mesh.ROUTES do
    local r = mesh.ROUTES[i]
    app:register(r.path, function(params, ctx, req)
        local out = mesh.dispatch(mesh.instance(), r.method, "/" .. r.path, params, req)
        return out ~= nil and out or mesh.disabled_response()
    end, r.method)
end
-- 404 兜底保持现状：/ha/* 未命中仍然回固定体
```

`dispatch` 的返回约定与 handler 一致：在 content 相位里响应已由 `ngx.print` 写完、返回
空串 `""`；非请求相位（单测、`resty` 一次性脚本）返回 `{status=,body=,content_type=}`；
只有路径既不在 `mesh.ROUTES` 里也不以 `/ha/` 开头时才返回 `nil`，交回 router 自己的 404。
`mesh.ROUTES` 里 `:worker_id` / `:model_id` / `:key` 三段与 klib.router 的参数名一致，
`params` 原样透传即可。

路由条数与注册形状要和 router.lua 现状对齐：klib.router 的参数只吃一段路径，
`ha/rate-limit/stats` 这类两段路径必须像现有 `mesh_routes` 那样逐条列出，
`mesh.ROUTES` 已经是这个形状，直接遍历注册即可。

### 4.2 本地状态写入（复制的入口）

mesh 只被动记录，写入由 router 在既有事件点调用。建议的最小集：

| 事件 | 调用 | 位置 |
|---|---|---|
| worker 注册/健康/负载变化 | `inst:observe_worker(id, record, state)` | `registry.add` / `hb.apply_health_result` 之后 |
| worker 删除 | `inst:remove_worker(id)` | `registry.remove` |
| policy 配置变化 | `inst:observe_policy(model, name, cfg)` | `policy.new` / 配置热更新 |
| manual 粘滞映射写入 | `inst:observe_manual(key, urls)` | `policies.manual` 写 `manual:<key>` 之后 |
| cache_aware 快照落盘时 | `inst:observe_tree(model, text)` | `policy:save_snapshot()` 里紧随 `dict():set` |
| 全局限流判定 | `inst:check_global_rate_limit()` | 转发前（若接受全局限额） |

`observe_*` 全部是本地内存写 + 计数器自增，不阻塞请求；`ha_*` 读的是同一份表。

> 状态核对（2026-10-01）：manual 一行**未接线**——`observe_manual` 在 mesh.lua 已实现但全仓无
> 调用点，manual 粘滞映射当前**不参与**镜像；其余行已在 init/router 侧接线。

**接线时必须先想清楚的两件事**（都会直接影响每轮带宽）：

* `observe_manual` 的条目数没有上限，而 `lr_policy` 里的 manual 映射可以吃满 20m。
  如果每个 `manual:<key>` 写入都镜像进 mesh，一轮同步的正文就可能到几十 MB。建议
  接线时只镜像活跃集合（例如按 `group:` 计数取 top-N），或者把 manual 复制做成
  可选开关（Rust 就不复制 manual，见 §2.2 表）—— 默认不建议全量镜像。
* 树快照的 blob 上限（`SMG_MESH_SNAPSHOT_MAX_BYTES`）是**单条**上限，整包快照没有
  总量上限：N 个模型 × 每模型一份树。多模型 + 大树的场景要配合 §6.2 的增量同步才
  能上线。

### 4.3 对等端写入落地

`apply_snapshot` 只把远端记录合并进 mesh 表，**不会**改本地 registry 或策略对象。
这是刻意的：本地 worker 集合由本地 `SMG_WORKER_URLS` 与控制面决定，让远端快照反向改
路由表会引入「谁都能给我塞后端」的故障模式。`/ha/workers` 因此回答的是「集群看到的全部
worker」，与本地 `GET /workers` 可以不同 —— 与 Rust `get_worker_states` 的语义一致
（Rust 也是读 mesh store 而不是 registry）。

### 4.4 多 worker 进程

状态表在 Lua 进程内存里，不在 `ngx.shared.DICT`。所以 `worker_processes > 1` 时：

* 只有 worker 0 同步并持有集群视图，其余 worker 的 `/ha/*` 会答得偏空（本地写入 + 从未同步）；
* 每个 worker 一份表也意味着 `check_global_rate_limit` 的计数按 worker 数放大。

三条可选路线，按侵入性递增：

1. 像 cache_aware 一样，把入口脚本对 `SMG_MESH_PEERS` 存在时的 `worker_processes` 钉到 1
   （最小改动，和现有 cache_aware 规则同一条 if）；
2. 把 mesh 表挪进 `lua_shared_dict`（要序列化，写放大明显，LWW 合并仍需 `resty.lock`）；
3. 单独监听一个 mesh 端口 + 单 worker 的 server 块承载 `/ha/*`（与 Rust 的独立
   `--mesh-port` 最像，但要改容器端口）。

本阶段按任务书不改配置，路线 1 是接线的默认建议。

---

## 5. 与 Rust 的语义差异（汇总）

| 项 | Rust | 本实现 | 影响 |
|---|---|---|---|
| 成员发现 | gossip ping/broadcast，动态发现、K8s annotation 取端口 | 静态种子 + 全对等交换 | 只写部分对等端也能收敛，但没有自动发现；节点必须显式配置 |
| 传输 | gRPC（tonic），独立端口 `--mesh-port`（默认 39527） | HTTP/1.1 on cosocket，**与业务同端口** `/_mesh/internal/*` | 少一个监听端口，见 §6 安全 |
| 同步形态 | ping + 定向 state-sync 两条 RPC | 一次 `POST /_mesh/internal/sync` 双向带快照 | 往返减半；每轮全量，带宽 O(状态大小) |
| LWW 决胜 | `ts`、`version` | `ts`、`version`、`node` id | Rust 在 ts+version 全等时会永久分歧（`crdt.rs:87`） |
| 删除 | `CRDTMap::remove` 硬删 | tombstone + `ts` 推进 | 旧快照不再复活已删记录 |
| 树状态 | 操作日志（`tree_ops` insert/remove 流） | 整棵快照 blob + 版本向量 | 无法增量、带宽更大；语义上是幂等收敛 |
| 分区 | 只算 Alive 成员，`min_cluster_size` 未使用 | 降级成员仍计入期望集，`min_cluster_size` 生效 | 见 §3.3 |
| `/ha/health` | 恒 `status:"healthy"`、`stores_healthy:true`（源码 TODO） | 分区/失去 quorum/draining 时 `degraded` + `should_serve` | 见 §7 |
| `/ha/status` 的 `stores` 三个计数 | 硬编码 0（源码 TODO） | 真实计数 | 见 §7 |
| `/ha/shutdown` | `graceful_shutdown()` → 进程退出 | 标 `draining` + 成员置 `leaving` + 广播；**不退出进程** | 进程生命周期归 supervisor/容器 |
| 限流计数 | owner-only inc，reset 靠负增 | 任意节点 inc，滚窗换 key | 见 §3.5 |
| `update_app_config` 的 hex | 校验奇偶与字符集 | 同样校验（错误文案一致） | — |
| 树快照落盘 | 每模型一份 mesh 记录 | 每模型一份（`tree:<model>`），Rust 亦然 | — |

---

## 6. 未实现

1. **安全认证**（最要紧的一条）。`/_mesh/internal/*` 与 `/ha/*` 目前无任何鉴权：
   能连上业务端口就能读全量集群状态（含 worker URL、manual 粘滞映射、树快照），也能
   `POST /ha/shutdown` 让节点 draining、`POST /_mesh/internal/apply` 注入伪造状态。
   Rust 侧同样只有 `mtls.rs`（未接入 handlers），所以这不算回退，但上线前必须补：
   建议 (a) 内部端点走独立监听端口 + 内网白名单，(b) 共享 token 头
   `X-LMR-Mesh-Token` 或复用 `SMG_CONTROL_PLANE_API_KEY`，(c) `/ha/shutdown`、
   `/ha/config`、`/ha/rate-limit` 这三个写端点纳入控制面鉴权。**这一步需要改
   conf/router.lua，超出本阶段范围。**
2. **gossip 拓扑优化**：`topology.rs` 的 full/sparse 切换（>10 节点按 region/AZ 稀疏）、
   `flow_control.rs` 的限速、`incremental.rs` 的增量同步（快照里 `since`/`seq` 字段是
   为此预留）都未实现。当前形态在 3-5 节点内没问题，节点数上去后每轮全量的代价是
   O(N × 状态大小)。
3. **节点状态机 / 收敛配置**：`node_state_machine.rs` 的 `ConvergenceConfig`、
   `is_ready()`（就绪前不接流量）未实现；本实现启动即服务，冷启动窗口内 `/ha/workers`
   可能不完整。
4. **mTLS**：`mtls.rs` 无对应实现；https 对等端会走 `registry.tls_handshake` 建立 TLS，
   但只做单向服务端校验，没有客户端证书。
5. **K8s 自动发现**：`router_mesh_port_annotation`（`sglang.ai/mesh-port`）不支持，
   成员只能靠 `SMG_MESH_PEERS`。
6. **per-model 的 policy/worker 归属与所有权迁移**：`handle_node_failure` 的
   ownership transfer 只做了 `rate_owner` 展示，没有把计数器状态搬家的概念（因为不要求
   owner，本就不需要）。
7. `/ha/workers/{id}`、`/ha/policies/{model}` 之外的更细粒度查询（Rust 也没有）。

---

## 7. 有意的契约偏差（会影响现有测试）

`test/test_lua_router.sh:726-736` 的 mesh 段断言 `/ha/*` 一律 503 +
`{"error":"mesh not enabled"}`。接线后：

* `SMG_MESH_PEERS` 未设置时行为完全不变（本阶段就是这种状态，契约测试不动即可全过）；
* 设置后 `/ha/status` 与 `/ha/health` 返回 200（Rust 也返回 200），
  那一节需要按 Rust 行为改写为「未启用 503 / 已启用 200 + 字段形状」。
  `mesh.disabled_response()` 的 body 与现断言逐字节相同，就是为了让这条改写只剩加一个
  前置条件。

另外 `/ha/health` 的 `degraded` 与 `/ha/status` 的真实 store 计数是**新增字段值**，
Rust 侧对应位置是硬编码（`handlers.rs:96` 的 `stores_healthy: true // TODO`、
`worker_count: 0`）。若要做逐字段 parity 断言，这两处需要按 Rust 的字面值再谈。

---

## 8. 验证

```bash
cd /path/to/lua-router/lua-router

# 纯 Lua 层（luajit）
docker run --rm -v "$PWD:/repo:ro" --entrypoint /usr/local/openresty/luajit/bin/luajit authz:latest \
  -e 'package.cpath="/usr/local/openresty/lualib/?.so;"..package.cpath
      package.path="/repo/lualib/?.lua;"..package.path
      dofile("/repo/test/unit/test_mesh.lua")'

# 带真实 ngx 的环境（resty CLI）—— 同一份断言必须同样全过
docker run --rm -v "$PWD:/repo:ro" -w /repo \
  --entrypoint /usr/bin/resty apache/apisix:3.11.0-debian \
  -e 'package.path="/repo/lualib/?.lua;"..package.path
      dofile("/repo/test/unit/test_mesh.lua")'
```

单测覆盖的成员收敛、身份统一、自引用 peer 过滤、LWW 三级决胜与双向收敛、tombstone、三类状态复制、
树快照因果/并发、限流跨机合并与滚窗、分区四态、内部端点协议、`/ha/*` 响应形状、
shutdown 语义、路由表 17 条与固定体、`route_matches` 段级匹配表、`from_env` 装配、
cosocket 替身的失败/恢复记账。

### 8.1 真 cosocket / 真 HTTP 验证（手工，脚手架未进仓库）

用一份临时 nginx 配置在**同一个 OpenResty 进程**里起两个 mesh 节点
（alpha 监听 18701、beta 监听 18702，两者 `ngx.timer` 各自周期同步，
第三个假对等端指向黑洞端口 18799），走真 TCP 与真 HTTP/1.1。脚手架在
`/data/tmp/mesh_nginx/probe.conf`。结果（全部由定时器驱动，无手工 tick）：

| 观察点 | 结果 |
|---|---|
| 双向收敛 | 第 2 秒两侧 `stores.worker_count` 均为 2（各自注册 1 个 worker） |
| 限流窗口合并 | alpha 记 4 + beta 记 6 → 两侧 `rate_value` 都是 10，`/ha/rate-limit/stats` `current_count=10` |
| app 配置复制 | alpha `set_rate_limit_config(1000)` → beta `get_rate_limit_config()={limit_per_second=1000}` |
| manual / policy 复制 | 两侧 `manual=1`、`policy_count=1` |
| 黑洞对等端 | 该成员一直停在 `init`（从未被同步证实），超过 `unreachable_s=5` 后 `partition=partitioned_with_quorum`、`unreachable=1`、`/ha/health status=degraded`、`should_serve=true`；连续观测 16 秒（8 个 tick）状态稳定不抖动，进程无错误日志 |
| `alive → suspect → down` 降级阶梯 | 只在单测里用注入的传输层验证（test_mesh.lua 的「分区检测」与「sync_tick 的失败/恢复记账」两个 case）；真 HTTP 场景下黑洞成员从未到过 `alive`，走的是 `init` 直接判不可达这条路 |
| shutdown 广播 | alpha `POST /ha/shutdown` → 202 `{peers_notified:2}`；1.5 秒内 beta 的 `/probe` 看到 `alpha:leaving`（无手工 tick），alpha `should_serve=false` |
| `/ha/*` 全部路由（手工 curl，`/ha` 探针串行打完 6 条只读路由）| 在 content 相位实测：status / health / workers / workers{id} / policies / policies{id} / config{key} / config(POST) / rate-limit(GET+POST) / rate-limit/stats / shutdown 均按预期返回；未知 worker → 404 |
| 分相位安全 | 同一份模块在 `init_by_lua`（不能写响应、不能起定时器）里加载并调用 `ha_status()` / `start()` 不抛错，分别退化为返回表和 `false, "no request"` |

把它固化成 `test/integration/e2e_mesh.py`（与现有 e2e 同框架）是接线的自然下一步。

### 8.2 回归

现有单测与契约套件均未受影响：
`test_mesh` 361、`test_policies` 118、`test_tree` 67、`test_hash` 795、
`test_integration` 66，契约套件 `gate` 3、`mesh` 5、`not_found` 9 全过
（`SMG_MESH_PEERS` 未设置，`/ha/*` 仍是原来的固定 503）。
