# mesh / HA 状态同步（现行口径）

实现：`lualib/resty/luarouter/mesh.lua`（facade）+ `mesh/{crdt,wire,rate,handlers,sync}.lua`。
接线在 `router.lua`（路由表）与 `init.lua`（env 捕获、实例构造、镜像定时器）。

## 1. 配置

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `SMG_ENABLE_MESH` | 关（缺省零行为变化） | 总开关（`1/true/yes/on`）。关闭时 `/ha/*` 与 `/_mesh/internal/*` 一律 503 固定体 `{"error":"mesh not enabled"}`；`/ha` 与两个前缀的未命中路径由 404 兜底收进同一固定体 |
| `SMG_MESH_PEERS` | 空 | 种子对等端 base url，逗号/空格分隔；`SMG_ENABLE_MESH` 开着但 peers 为空 → 一条 WARN + 表面保持 503（环境遗留 peers 不构成启用） |
| `SMG_MESH_SELF` | 无 | 本实例地址（base url）；兼容名 `SMG_MESH_SELF_ADDR` 仅在其缺省时读 |
| `SMG_MESH_SELF_NAME` | `hostport(SMG_MESH_SELF)` | 显式节点名 |
| `SMG_MESH_SYNC_INTERVAL_SECS` | 2 | 全对等同步周期 |
| `SMG_MESH_UNREACHABLE_TIMEOUT_SECS` | 30 | 超过这个时间没被同步证实的成员算不可达 |
| `SMG_MESH_SUSPECT_THRESHOLD` | 2 | 连续同步失败几次后 `alive → suspect`（一次抖动不判死） |
| `SMG_MESH_QUORUM` | `floor(N/2)+1` | N = 配置成员数 + 自己；只写自己一个时 quorum=1，单实例不会自己把自己判成分区 |
| `SMG_MESH_MIN_CLUSTER_SIZE` | 3 | 已知成员不足此数时不裁仲裁（§3.4） |
| `SMG_MESH_RATE_WINDOW_SECS` | 1 | 全局限流窗口宽度 |
| `SMG_MESH_RPC_TIMEOUT_MS` | 2000 | 单次对等端请求超时 |
| `SMG_MESH_SNAPSHOT_MAX_BYTES` | 3 MiB | 单条 cache_aware 树快照 blob 上限，超限跳过不发送 |

`mesh.from_env(getenv)` 一次装配；`mesh.init()` / `mesh.instance()` 管进程内单例。
`SMG_MESH_*` 全族不在 conf 的 env 白名单里：`init_by_lua` 在主进程捕获这些值、经参数显式传给
`mesh.init`（nginx fork 会重建 worker 环境，捕获即登记）。

## 2. 线协议

内部端点全挂业务端口（安全边界见 §6）：

| 端点 | 方法 | 请求体 | 响应 |
|---|---|---|---|
| `/_mesh/internal/ping` | GET | — | `{protocol,node,addr,status,version,draining}` |
| `/_mesh/internal/sync` | POST | 本节点快照（b64） | 对端快照（b64），`Content-Type: application/x-mesh-b64` |
| `/_mesh/internal/apply` | POST | 对端快照（b64） | `{applied,node}` |
| `/_mesh/internal/state` | GET | — | 本节点快照（b64），排障用 |

一轮 tick = 对每个 peer 一次 `POST /_mesh/internal/sync`：请求体带自己的全量快照（推送本地
写入），响应体带对端快照（拉取远端写入），一次往返完成双向收敛。`apply` 给「只广播不拉回」
的场景（`/ha/shutdown`、`/ha/rate-limit` 写后广播），也便于从 curl 注入状态。快照
`protocol` 字段不匹配直接 400，不静默吞包。

快照正文 = `base64(JSON)`（纯 Lua base64，不依赖 `ngx.encode_base64`，luajit 与 resty 两层
同一套编解码）。`stores.members/workers/policies/apps` 每条是 LWW 记录（`ts`/`version`/`node`）；
`stores.trees` 额外带 `vec`（版本向量）；`stores.manual` 协议有位、本实例不主动写入（§4.2、§7.7）；
`rate` 是 PNCounter 窗口列表（`{key,window_s,current,windows[{id,pos,neg}]}`）。`seq` 是本地
写入计数、`since` 是增量同步预留位——本实现永远发全量（§7.2）。

## 3. 收敛语义

### 3.1 LWW 三级决胜

`ts`（微秒）→ `version` → `node` 名字典序，任意合并顺序收敛到同一胜者。并发写入的胜者由对等端
时钟偏移直接决定——集群依赖 NTP，偏移超过一个请求间隔的先修时钟。

### 3.2 树快照：版本向量 + LWW 兜底

cache_aware 快照是 blob，带 `vec[node] = version`。合并先判因果：一方包含另一方全部写入且更多
→ 采纳更多方；并发不可比 → 退回 LWW。只传整棵快照、不传操作日志：无法增量，每轮带宽与树大小
成正比。`SMG_MESH_SNAPSHOT_MAX_BYTES` 是**单条**上限，整包没有总量上限（模型数 × 每模型一棵树）。

删除写成 `{_deleted=true}` 墓碑并推进 `ts`/`version`，读取面过滤；旧快照不能复活已删记录。

### 3.3 成员身份与 hostport 规范化

`SMG_MESH_PEERS` 是种子不是视图：每节点先自报 `alive`、种子记 `init`（未经证实，带
`first_seen` 宽限期），之后每轮交换完整成员表，只写部分对等端的三角配置也能收敛。配置里把
自己写进 peers 不算错：peers 与成员表都按 hostport 过滤自身，不会长出幻影键把单节点集群自己
判成 degraded。

身份以节点自报为准：

- 只采纳「`item.node == member.name`」的自报记录来新建成员；第三方转发的记录只补地址不建键；
  带**本实例地址**的转发记录不采纳（防自节点幻影键）。
- 种子先前按 hostport 记过账而对端自报了别的名字时，`unify_identity` → `migrate_member` 把观测
  时间/失败计数迁到自报名下并删旧键——成员表不会「同一节点两个身份」把 quorum 抬高。
- hostport 判定做规范化：主机名小写、IPv6 展开成 8 组四位十六进制、端口去前导零，解析不了退回
  小写原样。**`localhost` 与 `127.0.0.1` 是两个不同写法**（合并需要 DNS 语义，宁可退化成文本
  比较）：运维上 SELF 与 PEERS 统一用 IP 或统一用名字。
- `addr_keys`（规范 hostport → 成员键的别名索引）+ `used_addr`（成员键 → 最近一次同步成功的
  写法，进程内状态）让身份迁移后寻址不断线。每轮每个成员键只发一次请求，候选顺序：验证过的
  地址 > 表内地址 > 映射到该键的种子。
- 同步重试只在**拨号层失败**（拿不到 HTTP 状态）时换下一个写法；对方答了（含 4xx/5xx）就停——
  鉴权与状态都是节点级结论，换写法重问只会把一轮开销乘以写法数。
- `status` 生命周期：`init → alive`（同步成功）、`alive → suspect`（连续 `suspect_threshold`
  次失败）、`suspect → down`（且已超过 `unreachable_s`）、任意态回 `alive`（重新同步成功）。
  自己 `POST /ha/shutdown` 后的 `leaving` 无条件被采纳，不被「它还回 HTTP」洗白。

### 3.4 分区检测

`partition_state()` 基于已知成员（成员表里除 `leaving` 的全部节点）按序判定：

1. 已知成员数 < `min_cluster_size` → 永远 `normal`（两节点集群不裁仲裁——`quorum=2` 的集群
   任一台掉线就停服太激进）；
2. 没有过期成员 → `normal`；
3. 可达数 ≥ quorum → `partitioned_with_quorum`（继续服务）；
4. 否则 → `partitioned_without_quorum`，`should_serve() = false`（`draining` 是停服的另一独立条件）。

被降级成 `down`/`suspect` 的成员与 `alive` 一样计入期望集，分区判定不因降级而失明；从未被同步
证实的种子停在 `init`，同样计入期望集——配置里写一个永远起不来的对等端，本节点会长期停在
`degraded`（有 quorum 时仍继续服务），这是刻意的：静默接受「配置里有节点连不上」会让运维以为
集群健康。要摆脱就删那行配置或调小 `min_cluster_size`。两节点集群（成员数 < 3）恒 `normal`，
验证分区行为要数 `unreachable` / `nodes[].status`，不能拿 `partition` 标签作证词。

### 3.5 限流窗口

`windows[id] = {pos={node=n}, neg={node=n}}`，per-actor 取 max 合并（PNCounter 语义），窗口总量 =
当前窗口的 `sum(pos) - sum(neg)`。滚窗只是 `current` 换指向的 id，旧桶保留一个窗口宽度后丢弃——
无 reset 竞态、无需负值。任何节点都记自己的份（`rate_owner()` 只是 `/ha/rate-limit/stats` 的展示
字段）。只算当前窗口：时钟落后不到一个窗口的节点，其增量本轮不计入（宁可少限几笔）。

## 4. router 接线（现状）

### 4.1 路由与启动接线

`router.lua` 的 `build()` 遍历 `mesh.ROUTES` 整表注册——17 条一张表全带：13 条 `/ha/*`
（status / health / workers / workers/:worker_id / policies / policies/:model_id /
config/:key / POST config / rate-limit GET+POST / rate-limit/stats / shutdown / stats）+
4 条 `/_mesh/internal/*`。有实例时由 `mesh.dispatch` 应答；拿不到实例时同一 handler 落固定
503（与接入前的旧契约逐字节一致）。klib.router 的 `:param` 只吃一段路径，两段路径逐条列出，
参数名 `worker_id`/`model_id`/`key` 与 router 侧一致、`params` 原样透传。

启动侧（`init.lua`）：`init_by_lua` 捕获 env 并构造进程内实例（每个 worker 都要对象，`/ha/*`
handler 要读表）；`worker_init` 里只有 worker 0 `inst:start()` 起同步定时器，并按驱逐周期
重镜像 policy/树快照（§4.2）。

### 4.2 本地状态写入（复制的入口）

mesh 只被动记录，写入挂在既有事件点：

| 事件 | 调用 | 落点 |
|---|---|---|
| worker 注册/更新/健康与熔断状态 | `observe_worker(id, record, state)` | `router/control.lua` `mesh_observe_worker`（POST/PUT `/workers` 处）+ `registry/keys.lua`（健康巡检刷新） |
| worker 删除 | `remove_worker(id)` | `router/control.lua` `mesh_forget_worker`（DELETE `/workers` 处） |
| policy 与 cache_aware 树快照 | `observe_policy` / `observe_tree` | `init.lua` `mirror_mesh_state`：worker_init 首镜像 + 按驱逐周期定时器重镜像（快照落 `lr_policy` 后才重写，policy.lua 内无需钩子） |

`observe_*` 全是本地内存写 + 计数自增，不阻塞请求。`manual:<key>` **刻意不镜像**：条目数没有
上限（`lr_policy` 可被吃到 20m），全量镜像会把每轮同步正文推到几十 MB；要镜像只取活跃集合
并做开关，默认关。

### 4.3 对等端写入落地

`apply_snapshot` 只把远端记录合并进 mesh 表，**不**改本地 registry 或策略对象——避免「谁都能
给我塞后端」的故障模式。`/ha/workers` 因此回答**集群视图**（mesh store），与本地
`GET /workers` 可以不同。

### 4.4 多 worker 进程

状态表在 Lua 进程内存里，不在 `ngx.shared.DICT`。`worker_processes > 1` 时只有 worker 0 同步
并持有集群视图（其余进程答本地写入 + reload 残留），全局限流计数按进程数放大。现行落法是
**路线 1**：`SMG_ENABLE_MESH` 打开时 `docker-entrypoint.sh` 把 `WORKER_PROCESSES` 钉成 1
（显式 `NGINX_WORKER_PROCESSES` 优先），与 cache_aware 的同一条 if 规则。挪表进
`lua_shared_dict`（写放大 + 锁）或独立 mesh 端口 + 专用单 worker server 块是未采用的两条路线。

## 5. `/ha/*` 对外语义（启用后）

- `/ha/status`：本节点名 + 成员数组（name/address/status/version，按名排序）+ `partition` +
  可达/不可达计数 + `draining` + `stores` 真实计数（membership/worker/policy/app）。
- `/ha/health`：`normal` 且非 draining → `healthy`；分区/失去 quorum/draining → `degraded`；
  带 `should_serve`、`cluster_size`、`unreachable`。
- `/ha/policies`、`/ha/policies/{model}`、`/ha/config/{key}`、`POST /ha/config`
  （`{key,value}`，value 须为 hex，校验失败 400）、`/ha/rate-limit`（GET 配置 / POST 设定）、
  `/ha/rate-limit/stats`（`current_count` + `rate_owner`）。
- `/ha/shutdown`：标 `draining` + 成员置 `leaving` + 向对等端广播，202 `{peers_notified}`；
  **不退出进程**（进程生命周期归 supervisor/容器）。
- `/ha/stats`：成员/存活/可达/不可达名单 + 每对等端 sync_fail + 各 store 计数 + `local_version`。
- 未启用时以上全部落 §1 的固定 503。

## 6. 信任边界

`/ha/*` 与 `/_mesh/internal/*` 无鉴权，且**刻意不进管理面 Basic Auth 清单**——健康判定链与
集群互联必须匿名（AGENTS.md 硬规则 5 的 klib 清单同源口径）。能连上业务端口就能读全量集群状态
（含 worker URL、树快照）、`POST /_mesh/internal/apply` 注入伪造快照、`POST /ha/shutdown` 置
draining。部署边界 = 可信内网 / authz 边缘之后（与 doc/scope-trim.md 同一条）。要收紧的第一条
路线是给 mesh 单独监听端口 + 内网白名单；未实现。

## 7. 边界与未实现

1. 鉴权见 §6。
2. **每轮全量同步**：`since`/`seq` 是增量预留位，未实现。3–5 节点内没问题，节点数上去后每轮
   代价 O(N × 状态大小)；多模型 + 大树要先解决增量与整包上限。
3. **mTLS 未实现**：https 对等端走 `registry.tls_handshake` 单向服务端校验，没有客户端证书。
4. **无动态发现**：成员只能来自 `SMG_MESH_PEERS`；无 K8s annotation、无稀疏拓扑切换、无同步限速。
5. **启动即服务**：无就绪门，冷启动窗口 `/ha/workers` 可能不完整。
6. `used_addr` 是进程内状态：mesh 开着时 `worker_processes` 恒 1（§4.4），换 worker 后第一轮
   重学写法。
7. manual 复制：协议有位，本地不写入（§4.2）。
8. **全局限流是能力面，不是热路径**：窗口复制/合并/配置/统计齐备，转发路径不调用
   `check_global_rate_limit`；接入转发前要先定标签与失败语义。

## 8. 验证

```bash
# 纯 Lua 层（luajit）与带真实 ngx 的 resty 层：同一份断言两层都要全过
docker run --rm -v "$PWD:/repo:ro" --entrypoint /usr/local/openresty/luajit/bin/luajit authz:latest \
  -e 'package.cpath="/usr/local/openresty/lualib/?.so;"..package.cpath
      package.path="/repo/lualib/?.lua;"..package.path
      dofile("/repo/test/unit/test_mesh.lua")'
docker run --rm -v "$PWD:/repo:ro" -w /repo --entrypoint /usr/bin/resty apache/apisix:3.11.0-debian \
  -e 'package.path="/repo/lualib/?.lua;"..package.path
      dofile("/repo/test/unit/test_mesh.lua")'

TEST_ONLY=mesh        bash test/test_lua_router.sh   # 关闭 503 形状 + 启用后开放面
GATE_ONLY=mesh_http   bash test/final_gates.sh       # 真 HTTP + 说真线格式的假对等端
GATE_ONLY=mesh_two    bash test/final_gates.sh       # 双真 router：收敛/长稳/分区/恢复/retire
```

单测覆盖面：成员收敛与身份统一（幻影键回归、自记录守卫、IPv6/大小写/前导零端口等价、第三方
转发记录不建键）、自引用 peer 过滤、LWW 三级决胜与双向收敛、tombstone、workers/policies/apps
三类状态复制、树快照因果/并发合并、限流跨机合并与滚窗、分区四态、内部端点协议与 protocol 门、
`/ha/*` 响应形状、shutdown 语义、路由表 17 条与固定体、`from_env` 装配、cosocket 替身的
失败/恢复记账。

`mesh_two` 用「SELF 写 loopback、PEERS 写本机 LAN 地址」的互 seed 形状（最容易出幻影键的组合）；
分区窗口的证词取 `unreachable` / `nodes[].status`（两节点 < `min_cluster_size` 时标签恒 `normal`）。
