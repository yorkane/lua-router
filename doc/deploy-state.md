# 三实例部署现状（2026-10-05 实测）

> 本文只记**当前事实**，设计推导在 [gap-config-store.md](gap-config-store.md) 与
> [gap-session-2026-10-04.md](gap-session-2026-10-04.md)。
> 行号一律可能漂移，**引用前请 `rg` 复核**。

## 0. 三实例一览

| | 21.k:8801（生产） | 21.k:8802（测试） | 235.t:8800 |
|---|---|---|---|
| 镜像 | `pub/lua-router:8801-20261005-6` | 同左（同一 imgid） | `lua-router:8800-20261005-1`（同一 imgid） |
| compose | `/data1/app/lua-router-8801/` | `/data1/app/lua-router-8802/` | `/data/app/lua-router/` |
| 配置目录 | `.../config/` | `.../config/` | `/data/app/lua-router/config/` |
| metrics 口 | 29001 | 29002 | 29000 |
| 策略 / worker | `cache_aware` / **1** | `cache_aware` / **1** | `cache_aware` / **1** |
| 生效后端 | sqlite | sqlite | sqlite |
| 声明层配置 | 2 虚拟入口 + 3 张模型卡 | **全空**（纯 env + watcher） | 1 虚拟入口 + 1 upstream |

**注意 21.k 的落盘根是 `/data1/app/`，不是 `/data/app/`**；`/data/app/` 下没有 lua-router。

`cache_aware` 下 `docker-entrypoint.sh` 把 `worker_processes` 钉成 1，三实例实测都只有 master + 1 个 worker。
这正是**当前仍是单写者**的原因（见 gap-config-store.md §11 第 4 条）。

## 1. 验证任何持久化行为之前先做这一步

```
curl -s http://127.0.0.1:<port>/metrics | grep lr_config_store_backend
```
必须看到 `{backend="sqlite"} 1`。**否则你验的是文件路径，不是存储层。**

`lr_config_store_degradations_total` / `lr_config_store_saves_total` **没有 series 是正常的**——
计数器只在事件发生那一拍才写，缺 series = 自启动以来一次都没发生。

## 2. 已知配置漂移（两个实例调度精度不同）

8801 与 8802 的负载查询串**不一样**：

| 实例 | `SMG_LOAD_PROM_QUERY` |
|---|---|
| 8801 | `max by (Hostname,instance) (DCGM_FI_DEV_GPU_UTIL)` |
| 8802 | `max by (Hostname) (DCGM_FI_DEV_GPU_UTIL)` |

实测表现为 8801 的 `lr_gpu_load_workers` 为 8、8802 为 0。**两台在同一天被改成不一致，是漂移不是设计。**
要对齐的话把 8802 改成和 8801 一样。

## 3. 功率通道：两台的查询串都缺 `gpu`

两个实例的 `SMG_LOAD_POWER_QUERY` 都是：

```
max by (Hostname,instance) (DCGM_FI_DEV_POWER_USAGE)     # ← 缺 gpu，这就是 8 台同值的根因
```

实测 `lr_gpu_load_power_per_card_workers 0`、`lr_gpu_load_power_watts{worker=...} 8 台完全同值`。
**改成 `max by (Hostname, instance, gpu) (DCGM_FI_DEV_POWER_USAGE)`** 才会有逐卡区分。
代码侧已经支持（`store_sqlite` 那次之外的 per-card 分支已落地），**缺的只是 compose 里的这个串**。

`doc/deploy-fleet.md` 里的示例也还是旧的 `max by (Hostname,instance)`，**照抄会复刻 342.371 故障**。

## 4. 需要清理的残留（实测发现）

8802 的配置目录里有我这轮验证留下的探针文件，建议清掉：

* `runtime.json.keep` / `runtime.json.keep2`（含 `store-probe` / `ghost` 之类的测试入口）
* `runtime.json.db-wal` 已涨到 **2.7MB**，三实例里最大（WAL 没 checkpoint；不修也会自限，但值得看一眼）

另注意 `runtime.json.keep2` 里用的是**单数 `target`**，与现行 schema（复数 `targets`）不一致——
**那是历史探针，不要当现行形状写进任何文档**。

## 5. 两个同名函数，别搞混

`config_store.lua` 和 `router.lua` 里**各有一个 `local function store()`**，语义完全不同：

* `config_store` 的：解析后端 dispatcher，有缓存、有 init 阶段排除
* `router` 的：拿 config_store 模块本身，**无缓存**

调试时看到 `store()` 要先看是哪个文件的。

## 6. 死代码与未收敛项（重构时可清）

* `config_store._M.models_virtual_only()` **零调用者**。UI 直接读 document 的 `models_virtual_only` 键，
  router 有自己一份从磁盘读原文的实现。**是双实现 + 一处死代码，不是「两处协同」**。
* `legacy_snapshot_is_empty` **这个函数不存在**，只活在一条注释里（`migrate_once` 实际用 `snapshot_is_hollow`）。
* CAS marker `revision conflict` 在 `store_dispatcher.lua` 里有**两份独立字面量**，没走 `config_store` 的
  共享常量，且 `find` 都没加 plain 标志。
* `lr_gpu_load_power_per_card_workers` 有写入但 `observability.lua` 的 HELP 表里漏了它。

## 7. 行号锚点大面积漂移

代码在这轮提交里整体下移，**doc 与 AGENTS.md 里的行号大多已失效**。实测偏移示例：
`MODEL_CREATED_UNKNOWN` 3579→**3634**、`models_handler` 4108→**4457**、
`apply_ctx_cap` 3256→**3311**、`_M.ctx_cap` 1937→**2716**、
`validate_declared_context_windows` 1574→**1951**、`build_context_window` 561→**648**。

仍然准确的少数：`router.lua` 的 `profile_model_group`、`registry.lua` 的 update 门、
`mesh.lua` 的 `observe_worker`。

**新写文档请写函数名与语义，少写行号。**
