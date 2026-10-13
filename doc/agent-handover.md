# Agent 交接说明（lua-router）

先读仓库根目录 [AGENTS.md](../AGENTS.md)：它是项目目标、设计红线、测试纪律与部署授权的权威规则。本文只保留进入工作状态所需的仓库地图、稳定语义和经源码核实的边界。测试以 [testing-workflow.md](testing-workflow.md) 为准，部署以 [deploy.md](deploy.md) 为准，fleet 实测以 [deploy-state.md](deploy-state.md) 为准，架构以 [architect.md](architect.md) 为准。

## 30 秒速览

lua-router 是 OpenResty/LuaJIT 推理网关：服务发现、健康与熔断、策略选路、流式转发、容量准入、配置持久化、管理台与指标观测。虚拟入口是一对多的服务主入口，策略按入口名在整组真实模型里选路。

动手前记住：

- 推理体只允许顶层精确改写（`set_top_field` 族），不整表重编码；流式响应不缓冲。
- `max_tokens` / `max_completion_tokens` / `max_output_tokens` 一律透传，缺省时网关不代填。
- 跨请求状态只走 shdict；新开关缺省零行为变化。
- 管理面 Basic Auth 与虚拟入口 Bearer key 按各自清单工作，不新增全局推理鉴权。
- watcher 严格探针、健康巡检、GPU 采样的失败后果不同（分档见 AGENTS.md 硬规则 4 与 [gap-watcher-merge.md](gap-watcher-merge.md) 的探针处置小节）。
- `context_window` 是对外声明的总上下文窗口，`max_output_tokens` 是对外声明的单次输出上限；两者都不参与预算计算。
- 代码引用一律写「文件 + 函数名」，不钉行号。

## 仓库地图

- 源码：`lualib/resty/luarouter/`（facade + 同名子目录）
- Nginx 配置与启动：`conf/`、`docker-entrypoint.sh`
- 管理台：`ui/admin/`；原版 webui：`ui/`
- 测试：`test/unit/`、`test/integration/`、`test/gates/`

| 路径 | 职责 |
|---|---|
| `router.lua`、`router/` | klib 路由表、请求准入、候选装配、推理转发、`/v1/models` |
| `config_store.lua`、`config_store/` | 配置解析、热配置、持久化、管理 API |
| `registry.lua`、`registry/` | worker 记录、健康、熔断、容量与模型覆盖度 |
| `policy.lua`、`policies/` | 策略分发与策略实现 |
| `watcher.lua`、`watcher/` | 发现、探针、reconcile（reconcile 内部不再拆分） |
| `gpu_load.lua`、`gpu_load/` | 负载与逐卡利用率采样、导出 |
| `mesh.lua`、`mesh/` | 可选集群状态同步 |
| `observability.lua`、`observability/` | 指标、请求日志、inflight 状态 |
| `admin_auth.lua` | 管理面 Basic Auth |
| `init.lua`、`hb.lua`、`limit.lua`、`ui.lua`、`props.lua` | 初始化与定时器、健康巡检、限流、UI 与属性接口 |

## 改动流程

1. `git status --short` 看清共享工作树里他人的改动；只碰分配给自己的文件。
2. 顺调用路径读现行实现与对应文档。文档与代码冲突时先确认当前产品行为，再改文档，不延续已废止口径。
3. 按改动面跑最小相关门（矩阵见 testing-workflow.md §6）。门禁支持跨独立 run 并发，前提是 prepare 冻结快照 + 各自 manifest / 命名空间 / 端口台账；收尾只按本 run 容器名册核对，禁止全局 `lr-*` 清扫。
4. 任何 facade / re-export 形状的改动，验收必须落到真跑请求的门（contract 是接线完整性的最终判官），静态逐字核对不算过。
5. 文档只写当前可复用事实。门禁数量、check 数、镜像 tag、fleet 状态、生产验收清单和裁定过程都不进文档，它们各有权威落点。

提交与推送、生产容器范围、口令与配置存储权威源等约束以 AGENTS.md 为准；生产变更需用户明确授权，不从文档推断。

## 稳定语义速查

- 虚拟入口：`targets` 声明真实模型组，`candidates` 把 worker 绑定到组内模型名；入口策略在路由策略页按**入口名**配置。当前允许的条目声明字段与三态语义见 [gap-virtual-models.md](gap-virtual-models.md) §2。
- per-alias `policy` / `effort` 处于停用兼容态（接受、往返、warn、热路径不读），不要当 bug 修，也不要接回热路径。
- 容量：`max_concurrency` / `max_gpu_util` 到顶时在候选装配阶段**硬排除**（亲和命中也迁走），全池到顶返回 429；容量不改健康位。**利用率读数未知 → 不排除**（缺席 = 未知，绝不写 0）。
- 配置持久化：数据库是权威源，`LMR_CONFIG_FILE` 是镜像；CAS 冲突报 409，不静默覆盖。验证任何持久化行为前先看 `lr_config_store_backend{backend="sqlite"} == 1`。
- `/v1/models`：`owned_by` 全表恒为 `lua-router`。不要用 `owned_by` 区分入口行与真实行，也不要把 `created == 0` 当入口的充分判据；判入口按 id 查声明层 `/config` 的 `virtual_models` 名册。

## 经源码核实的边界

以下都会随实现变化，动之前重新核对调用图：

- `LMR_VIRTUAL_MODELS` 只支持 `alias=target` 单目标语法（`config_store/snapshot.lua` 的 `cfg_from_env`）；1 对多入口只能走配置文档。
- `GET /workers` 输出观测到的 `models`，**不输出** `models_verified`（`registry/records.lua` 的 `info` 缺该字段），因此管理台的「引擎已验证」徽章与模型页的已验证计数不生效。
- mesh 的 worker 镜像只含 `worker_id` / `model_id` / `url` / `health` / `load`（`mesh/crdt.lua` 的 `observe_worker`）；模型覆盖度与两个容量上限**不进集群视图**，上限因此是每网关独立。
- GPU 打分负载（`xl:`）和利用率准入读数（`gu:`）都经 `gpu_load/cards.lua` 的 `assign_load` / `assign_util` 按卡归属：能识别 worker 卡且源有对应卡读数时采用逐卡值，无法对应时回退整机 max 并计 fallback；不能概括为所有同 host worker 共用一个数。两条通道用途与量纲仍不同，细节见 [gap-gpu-load.md](gap-gpu-load.md) 与 [gap-worker-caps.md](gap-worker-caps.md)。
- watcher 的 `SMG_WATCHER_ALLOW_PORT` / `SMG_WATCHER_DENY_PORT` 只作用于 proc 扫描分支，docker 发现分支不过这道名单（`watcher/discover.lua` 的 `collect`）。
- cache_aware 亲和树与 bucket 计数是进程内状态；入口脚本默认只对 cache_aware 和 mesh 收敛 worker 数，bucket 多 worker 下状态不共享，不要假定其计数跨进程一致。

## 已核实的实现清理项

- `registry.records.remove` 没有删除 `gu:` 利用率键；若后续复用 worker id，需评估旧样本残留风险。
- `store_dispatcher.mirror_to_file` 当前只有定义、没有生产调用点；数据库权威与镜像写路径改动前确认实际调用链。
- `LMR_MODEL_TOOL_USE` 被 `config_store.snapshot.cfg_from_env` 读取，但未登记在 `config_store.env.ENV_NAMES`；OpenResty worker 环境捕获可能因此拿不到它。
- `observability.record_worker_attempt` 当前没有生产调用者。
- `gpu_load.export` 发布的若干 `lr_gpu_load*` 家族在 observability HELP 表里没有对应描述；核对导出契约时同时检查 HELP/TYPE 行。

## 文档索引

完整索引只维护在 README 的〈文档索引〉一节：新增/移动文档改那一处，并跑 `python3 script/check_docs_index.py` 做双向比对。按主题取文档时从那张表出发，常用落点：配置持久化 [gap-config-store.md](gap-config-store.md)、虚拟入口与模型广告 [gap-virtual-models.md](gap-virtual-models.md)、管理面认证 [gap-admin-auth.md](gap-admin-auth.md)、watcher [gap-watcher-merge.md](gap-watcher-merge.md)、容量与 GPU 利用率 [gap-worker-caps.md](gap-worker-caps.md) 与 [gap-gpu-load.md](gap-gpu-load.md)。

本文不维护文档清理记录与已关闭缺口历史；需要考古查 git log。
