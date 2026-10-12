# lua-router fleet 部署现状（2026-10-12 实测）

> 本文只记**当前事实**（全部实测取自 2026-10-12，只读探针：`docker inspect` + `GET /health`
> + `GET /workers` + `GET /config` + `GET /metrics` + compose 原文），设计推导在
> [gap-config-store.md](gap-config-store.md)、[gap-worker-caps.md](gap-worker-caps.md)、
> [gap-admin-auth.md](gap-admin-auth.md)。历次部署过程与真机取证在 [deploy-fleet.md](deploy-fleet.md)。
> **行号一律不写**（deploy-state 旧版第 7 节的结论继续生效：写函数名与语义，引用前 `rg` 复核）。

## 0. fleet 一览（五个实例）

| 实例 | 角色 | 镜像 | compose | metrics | 后端 | 池 | 管理面口令 |
|---|---|---|---|---|---|---|---|
| 235.t:8800 | **生产**（本机） | `pub/lua-router:20261011-fc037af` | `/data/app/lua-router/` | 29000 | sqlite | 306 条 / **20 healthy**（全 `router-watch`） | 无（匿名） |
| 21.k:8800 | **生产** | `pub/lua-router:20261012-69b5d53` | `/data1/app/lua-router-8800/` | 29000 | sqlite | 8 healthy / 8 | **已配** |
| 21.k:8801 | 生产（并行旧实例） | `pub/lua-router:20261011-fc037af` | `/data1/app/lua-router-8801/` | 29001 | sqlite | 9 | 无（匿名） |
| 21.k:8802 | **测试** | `pub/lua-router:20261012-69b5d53` | `/data1/app/lua-router-8802/` | 29002 | sqlite | 9 | **已配** |
| 217.t:8800 | 生产 | `pub/lua-router:8800-20261011-89f0ad0` | **无 compose（裸 docker run）** | 29000 | sqlite | 4 | 无（匿名） |

镜像来自 ACR `wasu-wtvdev-registry-test-registry.cn-hangzhou.cr.aliyuncs.com/pub/lua-router`。

- **21.k 的落盘根是 `/data1/app/`，不是 `/data/app/`**；`/data/app/` 下没有 lua-router。
- 三台的 `SMG_MAX_TREE_SIZE` 都是 `1e8`（2026-10-11 的 1M-token 长会话亲和定尺结论，不要缩）。
- 五台 `lr_config_store_backend{backend="sqlite"} == 1`：全部走 db 权威路径，没有一台在文件降级上。
- 口令列「已配」＝ compose 里有 `SMG_ADMIN_AUTH_PASS`。本轮用的是测试口令 `test123`，
  **操作员应换成正式口令后 `docker compose up -d`**（值不落文档）。「无」＝ 该env 缺席，
  整道 Basic Auth 门关闭、管理面匿名——缺省零行为变化，这是刻意的（见 gap-admin-auth.md）。

### 镜像命名规范变了

`20261012` 起用 `script/build-image.sh` 从绿锚点直构建推 ACR，tag 形如 `YYYYMMDD-<短sha>`
（不带端口前缀，一台一份镜像、多实例复用）。此前是 `8800-YYYYMMDD-N` / `8801-...` 那种
**每端口一个 tag** 的旧规范，所以现在 fleet 里同时存在两种形状：`20261012-69b5d53`（新）与
`8800-20261011-89f0ad0`（217.t，旧）。**同一构建在 fleet 里应使用同一个 tag**，别再为某台单独
打端口 tag——那正是 fleet 漂移的来源。

### 版本对齐现状（截至 2026-10-12）

- 最新锚点 `69b5d53`（代理来源头前置否决 v2「出现即认证」，full 门禁 22/0/0）：**只有 21.k 的 8800/8802 在跑**。
- 235.t:8800 与 21.k:8801 在 `fc037af`；217.t:8800 在 `89f0ad0`。
- `fc037af` / `89f0ad0` **不含** admin Basic Auth（`admin_auth.lua` 不存在于那两版），
  所以这两台上「配了口令也不生效」＝根本没有这道门。要拿到它必须滚到 `69b5d53`。
- `89f0ad0..69b5d53` 的非 auth 增量：`b5130da`（`owned_by` 恒 `lua-router`，硬规则第 9 条）、
  `9d8ea2b`/`4e6ffc9`/`717d87f`（capabilities 的 reasoning_efforts 形状与虚拟条目 `max_output_tokens`）、
  `8d63af2`（日志页模型列映射示意）。**235.t 的升级评估结论**（同 digest 只读评估已做）：
  仅为 auth 而升级不划算；要滚 fleet 对齐就一起滚，验证矩阵照 8802 报告复刻，
  唯一真实下游兼容风险是**还有客户端拿 `owned_by` 判别入口行/真实行**（裁定已禁止该用法）。

## 1. 逐实例要点

### 235.t:8800（本机生产，`/data/app/lua-router/`）

- 容器 `lua-router-8800`，host 网络，`unless-stopped`，healthcheck 打 `/health`。
- 配置挂载 `/data/app/lua-router/config:/data/lua-router`，`LMR_CONFIG_FILE=/data/lua-router/runtime.json`；
  `LR_HTTP_INCLUDE=/etc/lua-router/http-extra.conf`；docker.sock 只读挂载（watcher 的 docker 发现）。
- `SMG_WATCHER_DENY_PORT: 111,5432,11022,14389,42209`（rpcbind/postgres/本机注册口）。
- **无 `SMG_LOAD_*`**：负载通道未启用（`SMG_LOAD_SOURCE` 缺省 = 定时器根本不启动），
  `/metrics` 里 `lr_gpu_load*` 一条 series 都没有。这台的上游是远程/聚合网关，
  配 `max_gpu_util` 之前必须先补负载 env，否则闸门等于没配（口径见 gap-worker-caps.md）。
- 声明层现状：`virtual_models: []`、`upstreams: []`、`model_policies: []`，
  `model_configs` 只有一张卡 `qwen3.8-27b-coder390-fp8`（ctx 260000 / max_output_tokens 32000 /
  档位 low·medium·xhigh、缺省 low）。
  **这张卡是对外 advertisement，不钳制任何请求**（用户裁定 2026-10-04）；它的 ctx 应与引擎
  `--context-length` 保持一致，写错会诱导客户端发出引擎侧 400 的请求。
- 池 306 条**全部**是 `router-watch` 自动发现，只有 20 条 healthy：真实在听的上游是
  `127.0.0.1:10100`（聚合网关）、`18300` / `18301`（SGLang FP8 对）、`18490`（ninfer）；
  其余是门禁轮 mock 短暂注册进来的残留（模型名 `alpha` / `beta` / `rich-model` / `effmod` 之类，
  22xxx–60xxx 高位随机口）。**池计数随门禁轮波动，别当容量事实**；跑完门禁清一次
  （`DELETE /workers/{id}`，watcher 只会重发现真在监听的），keep-last 宽限也会自己收。
- **模型卡与引擎不自洽（10-12 实测，建议修）**：卡上声明 `ctx=260000`，而
  `18300` / `18301` 的 `get_server_info` 与 `/v1/models` 都报 `context_length` / `max_model_len` =
  **65536**（FP8 对当前按 64K 跑，64K 重定尺待 KV 复核）。卡是对外 advertisement、不钳制请求，
  但声明比引擎大 4 倍会诱导客户端发出引擎侧 400 的长上下文请求——旧事故口径见
  `/data/app/lua-router/config/runtime.json` 的 history 与本仓 memory。**卡的 ctx 应等于引擎
  `--context-length`**，重定尺落地时一起改。

### 21.k:8800（生产，2026-10-12 升级）

- 2026-10-08 由 lua-router 接管原 Rust `sglang-router-all` 的 8800；10-12 从 `8800-20261011-89f0ad0`
  滚到 `20261012-69b5d53`，并新增 `SMG_ADMIN_AUTH_PASS`（本轮 `test123`）。其余 env 逐字未动。
- 负载通道现役：`SMG_LOAD_SOURCE: prom` + `SMG_LOAD_PROM_URL: http://127.0.0.1:9092` +
  `SMG_LOAD_PROM_QUERY: max by (Hostname,instance,gpu) (DCGM_FI_DEV_GPU_UTIL)`（**带 `gpu` 与 `instance`**，
  逐卡口径的正解）→ `lr_gpu_load_workers 8`。
- 池 8/8 healthy，上游是 8012/8021-8027/8034 那组 sglang；`GET /config` 的 `upstreams` 有 7 条声明
  （8022-8027 + 8034），`virtual_models` 一条 `Q38-Flash-Next`，模型卡 4 张
  （`Q38-Flash-Next` / `q38fn-kv8` / `qwen38-flashnext-orca-nvfp4` / `swift-1.5-plefp8`）。
- 配置基线：rev `44 10504bd6`（升级窗口内零写入，前后一致）。
  切换前备份目录 `/data1/app/lua-router-8800/backup-20261012T163349Z/`（compose + config 全量 +
  SQLite 在线一致性快照 `runtime.sqlite-online`）。compose 目录里另有 8 份
  `docker-compose.yml.bak-*` 历史锚，回滚按 deploy-8800prod 报告那两条 sed。
- 真机取证与回滚手册：[deploy-8800prod-20261012-proxy-auth.md](deploy-8800prod-20261012-proxy-auth.md)；
  同 digest 在测试实例的先一轮：[deploy-8802-20261012-proxy-auth.md](deploy-8802-20261012-proxy-auth.md)。
- 生产域名链路实测：APISIX 在来源侧写 `X-Real-IP` / `X-Forwarded-For`（`8800-248.ai-t.wtvdev.com`
  与公网 `8800-248.ws.gatepro.cn:99` 两个入口都取证到），即旧版 loopback 豁免在反代下会被无条件触发——
  这就是 10-12 那轮前置否决要堵的洞。

### 21.k:8801（并行生产实例，本轮未动）

- 镜像停在 `20261011-fc037af`，metrics 29001（旧惯例口，避开 8800 的 29000）。
- 声明层：2 条虚拟入口 `q38fn-64k` / `qwen38fn-ab` + 3 张卡，`upstreams: []`（纯 env + watcher），rev `5`。
- 池 9 条，`lr_gpu_load_workers 9`——但查询串是 `max by (Hostname,instance)`，**缺 `gpu` 标签**，
  所以是整机口径、逐卡归属不成立，且 util 三件套（`lr_gpu_load_util_*`）完全无 series：
  这台跑的是**旧版负载查询语义**，新版 `SMG_LOAD_UTIL_QUERY` 缺省没被启用。
- compose 里仍留着已退役的 `SMG_LOAD_POWER_QUERY` 行（功率通道 2026-10-09 整体移除）：
  解析时被忽略、无功能影响，**该删**。

### 21.k:8802（测试实例，验证环境）

- 镜像 `20261012-69b5d53`，metrics 29002，与 8800 同一构建；改动先在这里验，用户确认后才推生产。
- 负载口径是**新版的正解**：`SMG_LOAD_UTIL_QUERY: max by (Hostname,instance,gpu) (DCGM_FI_DEV_GPU_UTIL)`
  → `lr_gpu_load_util_workers 9`、`lr_gpu_load_util_per_card_workers 8`、
  `lr_gpu_load_util_fallback_total 174`（回退是显式计数，不静默）。
  而 `SMG_LOAD_PROM_QUERY` 那条仍缺 `gpu`，于是旧口径 `lr_gpu_load_workers 0`——
  **两台都别再指望这个旧键**，逐卡判定看 `lr_gpu_load_util_*` 三件套。
- 声明层：1 条虚拟入口 `Q38-Flash-Next` + 4 张卡，`upstreams: []`，rev `744`（测试机写得多，正常）。
- `config/` 目录已干净：旧文档记录的 `runtime.json.keep` / `runtime.json.keep2` 探针文件**已不存在**，
  只剩 `runtime.json` / `.rev` / `.db` / `.db-shm` / `.db-wal` / `.bak-20261006-before-migrate`。
  §4 那条清理项**已结案**。
- **未结案**：`runtime.json.db-wal` 实测 **3.0 MB**（fleet 最大；8800 324 KB、8801 40 KB）——
  WAL 长期没 checkpoint。不修会自限，但下次在这台做持久化取证前值得先看一眼。

### 217.t:8800（生产，4090 池）

- 镜像 `pub/lua-router:8800-20261011-89f0ad0`，容器 `lua-router-8800`，metrics 29000，
  `restart=unless-stopped`，容器创建于 2026-10-11T16:16。
- **它是裸 `docker run` 起的，`docker inspect` 的 compose labels 为空**，`/data/app/lua-router/`
  下只有 `config/`，没有 compose 文件。这与仓库规则（compose + `unless-stopped`）不符，
  登记为待办：转 compose 编排时注意**别丢 env**——这台的关键 env 全在命令行上：
  `SMG_WATCHER_MODEL_MAP=Huihui-Ornith-1.5-35B-A3B-abliterated:Ornith-1.5-35B-A3B`、
  `LMR_MODEL_EFFORT=Ornith-1.5-35B-A3B:none,Huihui-Ornith-1.5-35B-A3B-abliterated:none`、
  `SMG_WATCHER_SHORT_MODEL_NAMES=false`、`SMG_WATCHER_PROBE_TIMEOUT_SECS=4`、
  `SMG_WATCHER_REMOVE_GRACE_SECS=300`。
  部署明细的历史记录在 [gap-watcher-deny-21k.md](gap-watcher-deny-21k.md) 之外的 217 记录里
  （git 历史 commit `fa9b61e`：`.tpl` 模板链与 Ornith 线）。
- 挂载只有 `config:/data/lua-router` 与 docker.sock（只读）——**没有 `http-extra.conf` 挂载**。
- 池 4 条：`127.0.0.1:18490`（startlux-decision-35b-a3b）与 `8200/8201/8202`（ninfer，
  `Ornith-1.5-35B-A3B` / `Huihui-Ornith-1.5-35B-A3B-abliterated`）。
- 无 `SMG_LOAD_*`（负载通道未启用）、无 `SMG_ADMIN_AUTH_PASS`（管理面匿名）。
- `/data/app/lua-router-8802/` 只剩一个空 `config/` 目录（2026-10-08 建目录后从未使用），
  **217.t 上没有 8802 实例**，别按端口表去找它。

## 2. 已知 fleet 漂移（当前真实差异，逐条给处置）

1. **管理面口令**：只有 21.k 的 8800/8802 配了 `SMG_ADMIN_AUTH_PASS`；235.t:8800、21.k:8801、
   217.t:8800 无口令＝管理面整道门关闭。直连 `127.0.0.1:8800/config` 与
   `127.0.0.1:8801/config`、`127.0.0.1:8802/config` 实测全 200（loopback 豁免不变，口令实例也一样）。
   给生产开口令的前置条件是先确认那台域名链路的代理头形状（21.k 已取证；235/217 未取证）。
2. **负载 env 三种形状并存**：21.k:8800 用 `PROM_QUERY` 带 `gpu`（旧键名、逐卡）；
   8802 用 `UTIL_QUERY` 带 `gpu` + `PROM_QUERY` 缺 `gpu`（新键名、逐卡，旧键读数为 0）；
   8801 用 `PROM_QUERY` 缺 `gpu`（整机口径）；235.t 与 217.t 完全没有负载 env。
   **要配 `max_gpu_util` 的机器，统一按 8802 那套写**（`SMG_LOAD_UTIL_QUERY` 带 `gpu` + `instance`）。
3. **已退役的 `SMG_LOAD_POWER_QUERY` 行**留在 8801 与 8802 的 compose 里（解析时 warn 一次并丢弃）。
   下一次动这两台的 compose 时顺手删掉。
4. **版本四代并存**（`69b5d53` / `fc037af` / `89f0ad0` 加上 tag 命名两套规范）。
   fleet 对齐需要一次显式裁定与一次统一发布（顺序：测试实例 → 生产 → 裸 docker run 那台）。

## 3. 验证任何持久化行为之前先做这一步

```
curl -s http://127.0.0.1:<port>/metrics | grep lr_config_store_backend
```

必须看到 `{backend="sqlite"} 1`。**否则你验的是文件路径，不是存储层。**

`lr_config_store_degradations_total` / `lr_config_store_saves_total` **没有 series 是正常的**——
计数器只在事件发生那一拍才写，缺 series = 自启动以来一次都没发生。

配置快照的安全取法（ fleet 通用）：sqlite 是权威，直接 `cp` 的 `.db` 不是事务一致的，
只能当证据不能当恢复源；要恢复源就走 WAL 安全路径（Python `sqlite3` 的 `Connection.backup()`，
或 `sqlite3 "file:...?mode=ro" ".backup '...'"`）。21.k:8800 的 10-12 备份即用此法。

## 4. 两个同名函数，别搞混

`config_store.lua` 和 `router.lua` 里**各有一个 `local function store()`**，语义完全不同：

* `config_store` 的：解析后端 dispatcher，有缓存、有 init 阶段排除
* `router` 的：拿 config_store 模块本身，**无缓存**

调试时看到 `store()` 要先看是哪个文件的。

## 5. 死代码与未收敛项（重构时可清）

* `config_store._M.models_virtual_only()` **零调用者**。UI 直接读 document 的 `models_virtual_only` 键，
  router 有自己一份从磁盘读原文的实现。**是双实现 + 一处死代码，不是「两处协同」**。
* `legacy_snapshot_is_empty` **这个函数不存在**，只活在一条注释里（`migrate_once` 实际用 `snapshot_is_hollow`）。
* CAS marker `revision conflict` 在 `store_dispatcher.lua` 里有**两份独立字面量**，没走 `config_store` 的
  共享常量，且 `find` 都没加 plain 标志。
* admin Basic Auth 的真机 28 项取证在仓库内没有独立 e2e 脚本（`test/integration` 里没有
  `e2e_admin_auth.py`），复现依赖现场操作——full 档要不要收它是个待裁定项。
* `PROXY_ORIGIN_HEADERS` 是硬编码三项名单（`X-Real-IP` / `X-Forwarded-For` / `Forwarded`），
  集中提示缺失：将来反代改写别的来源头（`CF-Connecting-IP` 之类）要同步扩名单 + 单测。
