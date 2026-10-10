# 配置持久化（sqlite / postgres / file）

> 落地：2026-10-04/05。决策人：用户。基线提交 `c727cfa`（接线）、`89adbbe`（四个缺陷修复）、
> `283c9ee`（env 名册）、`f7296dd`（可观测性）。全量门禁 22 门全绿。

## 1. 为什么做

配置原本只落 `LMR_CONFIG_FILE` 指向的一个 JSON 文件。三个问题：

**多实例无从共享。** 8801 与 8802 在同一台机器却各写一份文件、各存一份 shdict，改一边另一边不知道。

**并发写静默吞掉编辑。** `policy_revision` 只活在 shdict、当失效令牌用，磁盘快照里没有任何版本列，
两个写者并发整表替换 = 后写者全赢，先写者的编辑**无声消失**。

**没有可观测性。** 配置写到哪、因为什么降级、存没存进去，外部一概看不见。

## 2. 后端与选择

`LMR_CONFIG_STORE_BACKEND` = `sqlite`（缺省）/ `postgres` / `file`。

**sqlite** 面向**单机单实例**（用户 2026-10-05 定案）。复用基座镜像里 `resty/authz/db/driver.lua`
的 FFI 形状（`open_v2` + WAL + `busy_timeout` + 参数化 bind）——**那是 authz 项目跑在生产上的代码**，
不是我们自己发明的。

**postgres** 面向**多实例共享**。驱动是 pgmoon。

**file** 是**显式回滚路径**，必须能逐字节复现存储层引入之前的行为。

entrypoint 层的缺省（用户 2026-10-09）：`docker-entrypoint.sh` 对「既不设 `LMR_CONFIG_FILE`
也不设 `LMR_CONFIG_STORE_PATH`」的裸容器注入默认 `LMR_CONFIG_FILE=/data/lua-router/runtime.json`
（并建父目录），使缺省 sqlite 真正开起来——后端缺省一直是 sqlite，缺的只是「有没有可派生的
db 路径」这一步。操作员**显式** `LMR_CONFIG_STORE_BACKEND=file` 时不注入任何路径，保持老的
「无落盘＝纯内存态」；这也是 e2e_routing_dyn scenario E（docker restart 钉「重启即丢」）走的
口径。默认落点不挂 volume 仍在容器可写层，跨重建耐久须把 `/data/lua-router` 挂成 volume（生产
compose 已如此）。

选 sqlite 缺省不是顺手，是权衡：21.k 与 235.t 之间访问不到 `/nas2`，一个 `.db` 文件跨不了机，
而 shdict 已经覆盖了同机多 worker。sqlite 换来的**跨重启耐久**与**原子提交**是真需求，多机共享不是。

## 3. 数据形状：db 权威 + JSON 只读镜像

**db 承载 revision 与 CAS**，是唯一权威源。

**JSON 是镜像**（`store_file.mirror`），对人仍然有用：能读、能 `git diff`、能手改。

镜像**不是**第二个权威源。它的 revision 被**钉成 db 的值**，不自己递增，否则两个计数器会分叉。

`runtime.json.rev` 这个 sidecar 存 `revision + 内容摘要`（djb2 mod 2^32，纯 Lua 5.1 无位运算；
`h*33` 落在 double 精确整数范围内所以取模精确）。**revision 不放进 JSON 正文**——配置文档要保持
人能读，sidecar 是元数据。

## 4. 谁赢：db 还是文件

靠**摘要比对**，不是靠「谁优先」这种模糊规则。

| 情形 | 判定 | 结果 |
|---|---|---|
| 网关自己写过，摘要与文件一致 | 不是外部编辑 | **db 赢**。经 API 删掉的段不会被镜像捞回 |
| 摘要与文件当前内容不符 | 外部编辑（操作员/测试换了文件） | **文件赢**，采纳进 db |
| 文件 revision 高于 db | 别的实例写的 | 文件赢 |

「db 赢」与「文件赢」同时成立，靠的是摘要的先后而不是优先级排序。

**采纳外部编辑后必须回写镜像**，否则 sidecar 的摘要永远对不上，每次读都重新采纳并重写存储——
在请求路径上反复写库。

## 5. CAS 与冲突语义

写时带**期望 revision**，不匹配则拒绝。**不用 LWW**：配置编辑是低频、人手发起的动作，重试只花几秒；
一次被静默吞掉的编辑会让操作员面对「磁盘上写的是一套、机器跑的是另一套」，和 2026-10-04 那次
`context_window` 事故是同一类故障形态。冲突以 **409** 返回，带当前 revision，**UI 无需改动**。

「只是后端连不上」不是冲突，走既有降级路径，不要混为一谈。

**启动期回放豁免**：bootstrap 阶段的写不能因 revision 冲突被拒，否则后端临时不可达会把网关卡在启动失败。

## 6. 首次迁移与幂等

db 为空且 `LMR_CONFIG_FILE` 有内容 → 导入。**幂等**靠「db 已有 revision 就不导」。
留一份 `runtime.json.pre-<backend>.<ts>.json` 备份。

**空快照按「没说」处理**：`{}` 那种形状不导入，`read_snapshot` 见到空也继续往下走 env。
否则 `cfg_from_document({})` 会产出一份空 cfg，而 `current()` 是**整层二选一而非逐字段 merge**，
env 整层再没有机会生效——连「删掉文件回到 env 缺省」这条老逃生门也会失效。

## 7. 降级：网关必须能起来

任何后端打不开（没驱动、主机不可达、表不存在）→ 降级到 file + 一条 `warn_once`，**不抛异常**。
「网关因为配置存储不可用而起不来」比「网关退回旧后端」糟糕得多。

## 8. 可观测性（这三个指标是必需的）

| 指标 | 回答什么 |
|---|---|
| `lr_config_store_backend{backend="sqlite\|postgres\|file"}` | **这个实例此刻在写哪个后端**。一个实例在写 file 而不是 sqlite，必须能一眼看出来 |
| `lr_config_store_degradations_total{reason=...}` | 降级发生过几次、什么原因 |
| `lr_config_store_saves_total{result="ok\|conflict\|unavailable\|mirror_failed"}` | 保存结果分布。`mirror_failed` 最危险：db 提交了但镜像没写成 |

`/health` 是常量 200，**db 全挂也绿**，所以它不能承担这个职责。

## 9. 接线的两个陷阱（都踩过）

**`ENV_NAMES` 必须登记全族。** nginx 会把未登记的 env 从 worker 里剥掉，`capture_env` 也只按名册抓。
漏了 `LMR_CONFIG_STORE_*` 整族的后果是：postgres 配置面和自定义 sqlite 路径**在 worker 里永远读不到**，
而现象是「配了但静默走未配置降级」——极难查。两种拼写（带/不带 `PG_` 前缀）都登记了，
因为 `store_postgres` 会先读带前缀的、再回退到短的。

**`store()` 只能在 worker 阶段解析。** `config_store` 首次被调用在 `init_by_lua`，那时 `ngx.worker`
**是个 table 不是 nil**（`ngx.worker.id()` 返回 0），所以 `not (ngx and ngx.config and ngx.worker)`
这个守卫从来没生效过。必须用 `ngx.get_phase() == "init"` 显式排除。

代价是主进程打开的 `sqlite3*` 句柄会被 fork 给所有 worker，8 worker 实测 6 个开局 `database is locked`
并永久降级到 file，**同一容器一半写库一半写文件**。`store_sqlite` 里那道「连接不属于别人」的守卫
因 `opened_path` 同被继承而形同不存在。

## 10. 验证口径

**做任何持久化验证前，先看 `lr_config_store_backend` 确认在写 db**，否则你验的是文件路径。

必过的五条：

1. API 写 → `docker restart` → 仍在（持久化本体）
2. 经 API 删除 → 重启 → **不被镜像复活**（必须成对测，单独测「删除」会漏掉镜像回灌）
3. 外部换文件 → 文件内容赢
4. db 不可写 → 降级，**health 仍 OK、配置面仍可读**
5. `/metrics` 上 `lr_config_store_backend{backend="sqlite"} 1`

第 2 条务必给删除与重启之间留 settle 时间（删除后 ≥3s、重启后 ≥20s），否则会得到**间歇性假失败**。
实测「删除后 sleep 1 立刻重启」会假红，「sleep 3 + sleep 25」连过三轮。**这个假信号排查花了不少时间，
先怀疑自己的脚本。**

## 11. 已知遗留（勿当已解决）

1. **PostgreSQL 在 21.k 上无法验证**：无实例，镜像里也没有 pgmoon。「驱动缺失」与「连不上」目前是同一条降级路径。
2. **两个实例各写各的 db**（`lua-router-8801.db` / `lua-router-8802.db`），配置互不同步。共享靠 PG 那条路。
3. **两实例共享同一 `LMR_CONFIG_FILE` 但各有独立 db = 不支持的形态**，会跨实例串写。
4. **worker caps 的 CAS 基准是 per-process 的**（`_M._store_rev`），只在读穿透时刷新。当前实测 worker 数=1
   （`docker-entrypoint.sh` 在 cache_aware 下钉 1），所以还是单写者；**一旦显式设 `NGINX_WORKER_PROCESSES`
   或换策略，就进入多写者状态**。
5. **`store_dispatcher.reset()` 全仓无调用者**，纯运维/测试钩子。
6. `migrate_once` 的 `_migrated` 是**进程内**的，多 worker 各迁一次，靠 `migrate_from_file` 的幂等兜住；
   副作用是 N 份 `.pre-*.json` 备份。

## 12. 代码位置

| 文件 | 职责 |
|---|---|
| `store_dispatcher.lua` | 后端选择、降级阶梯、迁移、replay 豁免 |
| `store_file.lua` | 文件后端：原子写、sidecar、摘要、`edited_externally`、`mirror` |
| `store_sqlite.lua` | SQLite：建表、参数化写、guarded UPDATE |
| `store_postgres.lua` | PostgreSQL（pgmoon），连接失败即不可用 |
| `config_store.lua` 的 `store()` | 惰性解析 + init 阶段排除 |
| `config_store.lua` 的 `read_snapshot` / `write_snapshot` | 三层读、durable-first 写、镜像同步 |
| `config_store.lua` 的 `migrate_once` | 每进程一次的首次导入 |
