# gap-mesh 收尾：/ha/status 幻影成员键的根因、修复与双真节点 e2e

日期 2026-09-30。归属文件：`lualib/resty/luarouter/mesh.lua`、
`test/unit/test_mesh.lua`、`test/integration/test_mesh_two.py`（新建）、
`test/final_gates.sh`（仅注册 `mesh_two` 一门）、本文档。
未触碰 `service_discovery` / `router.lua` / `test_mesh_http.py` / `test_lua_router.sh`。

---

## 1. 现象与根因

`/ha/status` 的 `node_count` 比真实实例数多一，多出来的那条永远是
`"<lan ip>:<port>": "init"`，并且永不自愈：`/ha/health` 长期
`degraded`、`cluster_size` 虚高，超时后那条幽灵被算进 `unreachable`，
分区判定跟着失真。

根因是**记账时机**，不是合并规则。成员表先按种子写键：

```
SMG_MESH_PEERS = http://<dev-box-ip>:18002   ->  键 "<dev-box-ip>:18002"
```

对端在快照里自报的身份却是 `SMG_MESH_SELF` / `SMG_MESH_SELF_NAME`，
容器里几乎必然写成 loopback：

```
SMG_MESH_SELF  = http://127.0.0.1:18002
```

原先的迁移只发生在 `apply_snapshot`，而它只能用**自报地址**回找旧键
（`member_key_for_address(declared.address, snap.node)`）。种子写法与自报
写法不是同一个 hostport，回找必然落空，于是那个 `init` 键留在表里 —— 与
历史接线轮（gap-integration §5.3，见 git 历史）记的实测一致。
只有 `sync_with` 同时知道「我们拨的是哪个 url」和「对方报的是哪个名字」，
而它当时什么都没做。

同一次排查里另外挖出两个同源幻影：

1. **自节点幻影**：第三方转发的记录里带**我们自己的地址**（例如 K8s pod 名
   写法与我们的 SELF 写法不同）。`merge_membership` 按名字建键，于是给
   自己长出第二个成员键。
2. **写法不等价**：`hostport_from_url` 只做小写，IPv6 缩写与全量、
   前导零端口、大小写主机名会被认成两个监听点，迁移同样找不到目标。

---

## 2. 修复形态（全部在 mesh.lua）

| 位置 | 改动 | 作用 |
| --- | --- | --- |
| `canonical_hostport` / `expand_ipv6`（新增）、`hostport_from_url` | 主机名小写、IPv6 补成 8 组四位十六进制、端口去前导零；解析不了就小写原样返回 | 「同一地址的两种写法」落到同一个字符串 |
| `new()` | 新增 `addr_keys`（规范 hostport → 成员键的别名索引）与 `used_addr`（成员键 → 最近一次同步成功的地址） | 让身份迁移找得到目标，并且迁移后不复发 |
| `note_address_key`（新增），由 `put_member`、`sync_with`、`apply_snapshot` 调用 | 每次成员写入 / 每次拨号 / 每次采纳自报地址都登记别名 | 别名跟着地址走，不会只在一处记账 |
| `member_key_for_address` | 先查别名索引，再退回原来的地址扫描 | 键被迁移、地址被换网卡后仍然可寻 |
| `migrate_member` | 别名整体改指 `to`，并把 `used_addr[from]` 交给 `to` | 并键之后同步仍能发起 |
| `peer_candidates` / `peer_bases`（重写） | 一个成员键只出一个同步目标：验证过的地址 > 表里的地址 > 映射到该键的种子；完全没别名记录的老种子仍带上 | 不再每轮对同一节点发两次请求，也不会把另一种写法降级成 suspect |
| `unify_identity`（新增）+ `sync_with` 末尾调用 | 把「拨号地址」认到「对端自报名」下，发现旧键就 `migrate_member` | 幻影键的真修点 |
| `sync_with` 的重试口径 | 只有拨号层失败（拿不到 HTTP 状态）才换下一种写法；对方答了（含 4xx/5xx）就停 | 每轮开销不随写法数放大，也不会用换地址绕过鉴权结论 |
| `merge_membership` 的入口守卫 | 带**我们自己的地址**的第三方/转发记录不采纳 | 掐掉自节点幻影 |

修复前的复现（`/data/tmp/mesh_final/probe2.lua`，纯 Lua  fabric）：两侧
`node_count 3`，`10.0.0.x:1830x:init` 常驻。修复后同一拓扑 1 轮就收敛到
`node_count 2`，5 轮后仍是 2（`/data/tmp/mesh_final/probe4.out`，含三节点
混合写法与中间节点分区/恢复）。

---

## 3. 验证与数字

单测 `test/unit/test_mesh.lua`（新增 4 个 case，共 30 条新断言，
361 → 391）：

* 幻影键回归：loopback SELF + 网卡 IP 种子 —— 一轮并键、`node_count 2`、
  `used_addr` 记住连通写法、表里保留自报的 loopback 地址、每节点每轮恰好
  一次请求、5 轮不复活、`/ha/health` 不再被幽灵拖成 degraded；
* 自节点幻影：第三方转发的「本实例记录」不采纳，只有 relay 自报名进表；
* 写法规范：IPv6 缩写/全量、大小写、前导零端口等价，并且 IPv6 集群也收敛到 2；
* 第三方转发的未知节点只补地址，绝不新建键。

两种口径都过：`authz:latest` 的 luajit、`apache/apisix:3.11.0-debian` 的
`resty`，均 `all 391 checks passed`。

新 e2e `test/integration/test_mesh_two.py`：**38 项断言，0 失败**
（日志 `/data/tmp/mesh_final/e2e_mesh_two.log`，gate 单跑
`/data/tmp/mesh_final/gate_mesh_two.log`，28 s）。两个真 router 容器
host-network 互 seed（SELF 写 loopback、PEERS 写本机 LAN 地址，正是历史上
出问题的形状），带控制面 key（LAN 发起的内部同步需要它；数据面仍不设
`SMG_API_KEY`）。覆盖：收敛到 2 个 alive 且无 hostport 幽灵键、A 保留 B 的
loopback 自报地址、双向 worker 镜像、18 s 长稳（≥10 轮同步、零抖动、窗口内
零 sync 失败）、`docker stop` 制造分区窗口（幸存者 `unreachable_names`
恰好是 `lr-mesh2b`、成员降级 suspect/down、仍答 chat）、`docker start`
恢复后重新收敛、`POST /ha/shutdown` 的 retire 广播（202 + `peers_notified`，
A 在一拍内看到 `leaving`，表仍无幻影）、两个容器无 Lua abort。

分区窗口这里不看 `partition` 标签而看 `unreachable`/`nodes[].status`：
成员数不足 `min_cluster_size`（默认 3）时两节点集群按设计永远是 `normal`
（`partition_state` 的规则 1，doc/gap-mesh.md §3），标签本身不能作证词。

回归：`test_mesh_http.py` **47 项 0 失败**
（`/data/tmp/mesh_final/e2e_mesh_http.log`）。

门禁注册：`final_gates.sh` 的 `GATE_ORDER` 从 19 门变 20 门，`mesh_two`
插在 `e2e_policy_parity` 之后、`e2e_tls_chain` 之前；同时补了 header 门列表
与「跳过代价」两行。`GATE_ONLY=mesh_two` 单跑通过；
`SKIP_ENV=mesh_bogus` 仍被校验拒绝。**全量门禁按 root 的要求没有再跑**
—— 上一轮 19/19 全绿（`/data/tmp/lr-gates/full-mine4.log`，
`gates-20260930-215157.log`）属于 root，之后只有这一门的改动由我单独验证。

有效性验证（把修复点摘掉，看断言是否真的会红）：

| 摘掉的点 | 单测结果 | 新 e2e 结果 |
| --- | --- | --- |
| 全部三点（`unify_identity` 调用、自记录守卫、hostport 规范化） | —— | 38 项中 **14 红**：`cluster_size 3`、`<dev-box-ip>:<port>:init` 常驻、两侧 degraded、`partitioned_with_quorum`、恢复不收敛（`/data/tmp/mesh_final/e2e_mesh_two_prefix.log`） |
| 只摘 `unify_identity` | 383/391，**8 红**（`node_count 3`、幽灵不迁移、每轮两发请求） | —— |
| 只摘自记录守卫 | 389/391，**2 红** | —— |
| 只摘 hostport 规范化 | 385/391，**6 红**（IPv6 缩写/全量、前导零端口不等价） | —— |

变异镜像 `lua-router:mesh-mut` 已删除。

---

## 4. 已知边界

* `localhost` 与 `127.0.0.1` 仍是两个不同的 hostport 写法：解析成回环再合并
  需要 DNS 语义，而 mesh 只用它做身份判定，宁可退化成文本比较也不要把看不
  懂的地址认成另一个节点。运维上 SELF 与 PEERS 请统一用 IP 或统一用名字。
* `used_addr` 是**进程内**状态。多 worker 部署（mesh 打开时 entrypoint 已把
  `worker_processes` 钉成 1）不受影响；换 worker 后第一轮会重新学习写法。
* 重试只在**拨号层失败**时换写法。对端回 401/403 不会换地址重问 —— 鉴权是
  节点级结论，换写法只会把一轮同步的开销乘以写法数。
* 种子写法若与对端自报身份永不相交（对端既不改 SELF 也无可达地址），该成员
  停在 `init` 直到超时降级；这是配置错误，不是代码能替运维补的信息。
