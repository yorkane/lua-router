# 并发测试工作流（2026-10-12 裁定改写）

> 本文是测试与多代理并行验证的**唯一操作口径**。用户裁定 2026-10-12 推翻了旧规则「门与门之间严禁并发 /
> 同一时刻只允许一份门禁在跑」：那条规则的意图是隔离（端口、容器名册、被中途编辑的源码树），而隔离现在由
> 实现提供，所以约束从「人工串行」换成「同 manifest 的独立 run 可以并发」。
> [doc/operations-lessons-20261012.md](operations-lessons-20261012.md) §4 的旧文案按本文替换，不改写历史。

## 1. 隔离由谁提供（实现位置，按「文件 + 函数名」引用）

| 机制 | 落点 | 它替掉了什么 |
|---|---|---|
| 冻结源码快照 | `test/gates/context.py`：`source_fingerprint` / `freeze` / `prepare`（快照根 `/data/tmp/lr-gates/snapshots/<fingerprint>/`） | 「A 门跑一半 B agent 改了 lualib，绿日志描述的树根本不存在」 |
| 不可变镜像 + manifest | 同上 `build_image` / `manifest_with_built_image`，tag 是 `lua-router:gate-<指纹前20>`，**不是**共享可变的 `lua-router:integration` | 两个并发 run 互相 retag、下游套件 boot 到别人的镜像 |
| 每 run / 每门命名空间 | `context.RunContext.gate_env`：`LR_RUN_ID` / `LR_GATE_TAG` / `LR_TEST_TMP` / `LR_RESULT_DIR`；容器名由 `test/integration/_lib.py` 的 `RUN` 与 `test/test_lua_router.sh` 的 `SUIT` 拼出 | 全局 `lr-*` 清理互踩、PID 同余撞目录 |
| 机器级端口台账 | `test/port_allocator.py`：`free_port` / `reserve` / `release_pid`（`/data/tmp/lr-gates/ports.reserved`，flock + pid 存活回收 + 绑定探针） | bash 契约段与 python e2e 各拿各的端口 |
| 声明式资源锁 | `test/gates/locks.py`：`acquire_gate_locks`；写者优先的观测窗 `obs:shared` / `obs:exclusive`，构建准备锁 `build:exclusive` | 「阶段栅栏 + 串行尾巴」 |
| watcher 的 docker.sock 只读代理 | `test/integration/docker_test_proxy.py`：`DockerTestProxy.for_run` / `socket_path_for` / `allow` | watcher 独占机器观测窗（旧串行三门里的一个理由） |
| 结果记录与聚合 | `test/gates/results.py`：`write` / `load` / `aggregate` / `report_lines` | 「跳过的门在报告里消失」= 假绿 |

两条要点：**缓存只覆盖准备阶段**（快照与镜像按指纹复用），门结果永不复用——每个 run 都真跑被选中的每一门。
**没有全局「同时只跑一份门禁」的 flock 了**（`test/final_gates.sh` 头部明写），`/data/tmp/lr-gates/.gates.lock` 是旧实现留下的空文件，不再被任何代码持有。

## 2. 先冻结，再并发：prepare 一次，多 agent 共用一份 manifest

```bash
cd /home/aigc/ChatGPT/lua-router
bash test/final_gates.sh prepare --manifest-out /data/tmp/lr-gates/manifest-${FINGERPRINT}.json
```

prepare 是**冻结源码 + 当场构建镜像**（`context.prepare` = resolve + build），构建结果进内容寻址缓存，
后续同指纹的 run 与聚合直接复用它，不再重复构建。
输出里的 `fingerprint` / `image_id` / `authz_id` / `resty_id` 就是这一轮所有 agent 的**共同版本身份**：
root 下发任务时必须带上 manifest 路径，执行方在自己的报告里先记 fingerprint（`head -6` 任一 run 的
`gates.log` 就有），结果才可聚合。manifest 是内容清单核版本，不是 `git rev-parse HEAD` 字符串——
`source_fingerprint` 覆盖 `lualib` / `conf` / `ui` / `test` / `Dockerfile` / `docker-entrypoint.sh`
（门禁可见源码 + 测试装置），**纯 doc/ 与 script/ 改动不改指纹**（`test/test_gate_runner.py` 有这条断言）。

不带 manifest 直接跑只自动 `freeze`（冻结源码 + 记录镜像**身份**，`image_id` 为 null，镜像留给 build 门在
调度中现场构建），只是失去与别人共享镜像的便利。run 目录里的两个身份文件不是一回事：
`gate-manifest.json` 在 build 之前 `image_id` 可以为空；build 成功后 scheduler 经
`context.manifest_with_built_image` 取镜像 id，再经 `RunContext.update_manifest` 把 image id 与 provenance
补齐并原子回写这份文件；run 结束时 runner 把完成态身份写进 run 根的 `manifest.json`。
**聚合与复跑用 build 之后的 manifest**（prepare 产物、run 根的 `manifest.json`，或 build 已补齐的
`gate-manifest.json`）；拿 build 之前那份去核版本，等于拿一个还没有镜像的身份去聚合：

```bash
bash test/final_gates.sh                                    # 缺省 quick 档 + 缺省池宽
GATE_TIER=full bash test/final_gates.sh                     # 全量 22 门
GATE_JOBS=1 bash test/final_gates.sh                        # 显式串行，顺序即 GATE_ORDER
bash test/final_gates.sh run --manifest /data/tmp/lr-gates/manifest-<fp>.json
bash test/final_gates.sh plan                               # 只打印选择/锁/依赖
GATE_DRY_RUN=1 GATE_TIER=full bash test/final_gates.sh      # 同上，兼容旧写法
```

池宽缺省 `min(8, CPU)`（`test/gates/scheduler.py` 的 `default_jobs`；本机 144 核 → 8）。
池饱和点在 docker daemon 与 CPU，再宽不买到东西；`GATE_JOBS=1` 是留给「复现一个只在串行下出现的红」的显式档。

## 3. 按维度选门（分组是真旋钮，不再写死在脚本里）

选择面：`GATE_TIER=quick|full`、`GATE_GROUP=a,b`、`GATE_ONLY=<门>`（不受档位限制）、`SKIP_ENV=a,b`（记录在案，不隐身）。
下面是 `bash test/final_gates.sh plan` 的真值，逐维度的可复制命令由它派生：

| 维度 | 门 | 一条命令 |
|---|---|---|
| base（源码树 / conf 渲染 / wire 契约） | build conf unit contract | `GATE_TIER=full GATE_GROUP=base bash test/final_gates.sh` |
| config（声明层、旋钮、持久化、对外广告） | probes e2e_profiles e2e_models_advertisement e2e_token_accounting | `GATE_TIER=full GATE_GROUP=config bash test/final_gates.sh` |
| routing（策略行为、改写、容量） | e2e_stateful e2e_policies e2e_policy_parity e2e_routing_dyn e2e_caps e2e_effort e2e_errors | `GATE_TIER=full GATE_GROUP=routing bash test/final_gates.sh` |
| observability（指标 / HEAD 镜像 / 桥） | e2e_ui_bridge head_routes e2e_gpu_load | `GATE_TIER=full GATE_GROUP=observability bash test/final_gates.sh` |
| discovery（内建 watcher） | e2e_watcher | `GATE_TIER=full GATE_GROUP=discovery bash test/final_gates.sh` |
| mesh | mesh_http mesh_two | `GATE_TIER=full GATE_GROUP=mesh bash test/final_gates.sh` |
| tls | e2e_tls_chain | `GATE_TIER=full GATE_GROUP=tls bash test/final_gates.sh` |
| ui（管理台纯函数 + 桥端点） | unit 的 node 子集 + e2e_ui_bridge | `GATE_TIER=full GATE_GROUP=ui bash test/final_gates.sh` |

`GATE_GROUP=ui` 是**真子集**不是标签：`LR_GATE_UI_ONLY=1` 让 `gate_unit` 只跑 `test/unit/test_ui_merge.mjs`，
`gate_contract` 以 rc=5 上报 → 记为 skip（两者由 `test/final_gates.sh` 的 `gate_unit` / `gate_contract`
里的 `LR_GATE_UI_ONLY=1` 分支实现）。
新增门要在 `test/gates/catalog.py` 的 `GATES` 里声明 group / tier / locks / depends / timeout，
`catalog` 与 `HISTORICAL_ORDER` 的一致性由模块内的 assert 把住（漏归类直接报错，不 fail-open）。

## 4. 并发纪律（跑前 / 跑中 / 收尾）

- **跑前**：`ps -ef | grep '[f]inal_gates.sh'` 看有没有别人的 run 在跑（有就并发跑，不排队——并发是本轮裁定），
  但要确认台账活着：`wc -l /data/tmp/lr-gates/ports.reserved`（行数是瞬时值，随 run 结束归零）。
- **锁只锁真正共享的东西**：HTTP 门共享观测窗（`obs:shared`），构建走独立的准备锁（`build:exclusive`，
  conf/unit/contract/probes 不等构建）；`e2e_watcher` 声明**零锁**，因为它读的是只读代理的过滤名册。
  `mesh_two` 的 18 秒稳定窗与 `e2e_tls_chain` 的 31337 场景（`openresty -t` 渲染、从不 bind）已审计进共享池，
  逐门耗时就是核查处（`results/<gate>.json` 的 `duration` 字段）。
- **清理边界**：每个 run 只杀自己的进程组、只按名字删自己名册里的容器、只释放自己 pid 的 ledger 行、
  只把自己的临时树移进 `/data/.trash`（`context.RunContext.abort` / `remove_containers`、
  `test/test_lua_router.sh` 的 `cleanup`）。**禁止 `pkill`、禁止全局 `lr-*` 清扫**——那正是并发下最贵的误伤。
- **生产边界**：门禁只碰 `lr-*` 测试容器。所有 8800 是生产（本机 `lua-router-8800`、21.k:8800、217.t:8800），
  21.k 的 8801 / 8802 是测试环境；用户数据与生产实例不是测试写面，逐条按 AGENTS.md 硬规则 3 判，不自行扩大。
- 已知现象：生产机的 proc 扫描会把门禁轮的 mock（alpha/beta 等模型名）短暂注册进生产池。处置属于生产写面，
  按 AGENTS.md 硬规则 3 逐条判，不在本文给出口头命令；结构性根治（端口黑白名单策略）未做。

## 5. 什么算绿：三个标志、同版本聚合、full 锚点

报告里有三个绿色标志（`test/gates/results.py` 的 `aggregate`），**别把它们当一个**：

| 标志 | 判据 | 能用来做什么 |
|---|---|---|
| `selection_green` | 选择内无 hard 诊断（fail / timeout / crash / invalid）；记录在案的 skip 与子集覆盖都不算 hard | 只说明「选择内没有硬错误」。发版不能引它，**它也不是进程退出码**（见下） |
| `release_green` | 无任何 blocking 状态（含 skip），且无子集覆盖记录 | 该选择可作发版证据的**必要条件**；定向全 pass 时它也会是 True |
| `full_anchor_eligible` | `tier == full` + 22 门齐 + 无 skip/missing/invalid + 无重复冲突 + 无子集 + manifest 身份完整（`fingerprint`/`image_id`/`authz_id`/`image_tag`） | 唯一可引用的 full 锚点 |

**进程退出码是 aggregate 的 `ok`，不是 `selection_green`**：定向（partial）选择也要求**无 blocking**，
所以显式 `SKIP_ENV` 会让 run 退出码非零，而 `GATE_GROUP=ui` 的 unit 子集（记录里只有 `coverage=subset`，
没有 skip 行）可以退出 0 却 `release_green=False`。两个坑：`--tier` 缺省取 `GATE_TIER`，而 `GATE_TIER` 缺省 `quick`，所以 **`full_anchor_eligible` 硬性要求聚合显式
`--tier full`**（quick 档聚合就算 22 份结果全齐也只报 False）；UI-only 的 unit 是 `coverage=subset`，
它让自己的选择保持绿、让 `release_green` 变 False，永远买不回完整的 unit 覆盖。

- **发版、文档计数更新、生产镜像替换**：要么一次 `GATE_TIER=full` 全绿，要么跨独立 run 的分组聚合
  **补齐全部 22 门**后由 `aggregate` 判定等价（同一 manifest、同一镜像身份，缺门按 crash 计，混版本直接拒收）：

```bash
bash test/final_gates.sh aggregate --tier full \
  --manifest /data/tmp/lr-gates/manifest-<fp>.json \
  --results "/data/tmp/lr-gates/runs/<run-A>/results /data/tmp/lr-gates/runs/<run-B>/results"
# --tier full 不能省（见上表）；--manifest 用 prepare 的产物或某个 run 的 manifest.json，
#   不要用 run 目录里 build 之前的 gate-manifest.json（那份 image_id 可能为 null）
# 只核一份报告时补 --gates "contract e2e_watcher"（缺 expected 集 = 22 门全量）
```

  实测形状（本轮，同一 fingerprint `9d34ff48fcd5` + 同一镜像 `sha256:46ce63e2a113`，三门分属三个 run）：
  三目录聚合（未显式 `--tier full`）→ `3 pass` / `release_green=True` / `full_anchor_eligible=False`，退出码 0；
  把 expected 写成两门只喂一个目录 → `1 pass + 1 crash(no result record)`、`selection_green=False`、退出码 1。
  少一门不会让聚合变绿，这是这套报告存在的理由。
- **`SKIP_ENV` 出现在发版锚里就是假绿**（历史上外部依赖门被 SKIP 掩盖过 require 失败）：跳过只用于
  「该门被无关改动确定阻塞」，且必须写进报告。

## 6. 改动 → 验证矩阵（协议，缺省按最小面）

| 改动面 | 跑什么 |
|---|---|
| 纯 docs（含本文与 README 索引） | `python3 script/check_docs_index.py` + `git diff --check`；不动门禁计数时不需要跑门 |
| UI 纯函数 / 管理台页 | `GATE_GROUP=ui`（node 单测 + `e2e_ui_bridge`） |
| config / 声明层 / `config_store` | `GATE_GROUP=config` + 相关 base（`conf`、`unit`） |
| router / 策略选择 / 改写链 | `GATE_GROUP=routing` + `contract` |
| 跨组件接线（facade + re-export、auth、mesh 协议） | 相关分组全跑 + `contract`（接线完整性只有真跑请求的门能证明，见 §3 教训） |
| 发版 / 构建脚本 / 生产镜像替换 | `GATE_TIER=full` 全 22 门，或同快照分组聚合的等价证明 |

**不要自动追加测试范围**：文档 + 小面积可逆改动反复跑 full / contract 是本轮点名的慢因。
一次修改跑最小相关面，红了定位后只重跑受影响的门（`GATE_ONLY=<门>`），跑完整轮才更新计数锚点。

## 7. 实测记录与未测项

本轮已实测的并发样本（三 run 同一秒启动，`GATE_TIER=full GATE_JOBS=1`，各自 `GATE_ONLY`）：

| 门 | checks | 结果 | 耗时 |
|---|---|---|---|
| contract | 765 / 2 notes | pass | 155.2s |
| e2e_watcher | 125 | pass | 103.3s |
| e2e_models_advertisement | 262 | pass | 65.8s |

墙钟 156 秒（最长门 155.2s），三门串行相加 324s；watcher 在旁有 24 个外来 `lr-` 容器时读的是过滤后的代理名册，
125 项照旧全绿。三份逐门记录：`/data/tmp/lr-gates/runs/20261012-185138-3257449-d358`（contract）、
`…-3257453-d35c`（models_advertisement）、`…-3257457-d360`（watcher）的 `report.json`。
收尾核对是**本 run 的容器名册归零**（按注入的 `LR_CONTAINER_NAMESPACE` 过滤，判据见 §4 清理边界）：
当时顺带观测到全机 `docker ps -a --filter name=lr-` 恰好为 0——那是各 run 收尾后的瞬时状态，**不是判据**，
并发下全机前缀计数既判不了对错也不许当清理依据。`/data/tmp/lr-gates/ports.reserved` 0 行。

**这组数据只证明隔离机制生效 + 三门可并发**，不构成 full 档加速比。

fullbench（现行实现的 22 门全绿锚点，2026-10-13 root 补测）：

```bash
# run 20261013-024250-896404-cc83-21d091  GATE_TIER=full，池宽取缺省 jobs=8，无 group/only/skip 过滤
#   （命令清场后跑：env -u GATE_JOBS -u GATE_GROUP -u GATE_ONLY -u SKIP_ENV GATE_TIER=full bash test/final_gates.sh）
# 合并日志 /data/tmp/lr_final_anchor_20261013.log；计时 /data/tmp/lr_final_anchor_20261013.json
# 外层单调时钟墙钟 167.529s（84118.927 -> 84286.456），rc=0
# fingerprint 1428f21eff54…（跑前跑后一致）；镜像 sha256:46ce63e2a113…
# report.json：22 pass / 0 fail / 0 timeout / 0 crash / 0 skip / 0 invalid / 0 missing
#   release_green=True  selection_green=True  full_anchor_eligible=True
# 逐门前六：contract 167.1  e2e_policy_parity 107.1  e2e_caps 105.8  e2e_watcher 104.8
#   e2e_profiles 74.3  e2e_models_advertisement 72.5；逐门 duration 之和 1005.5s
# 历史留档（不同实现，不与上面换算加速比）：旧串行 917s（gates-20261012-164729.log）、
#   旧并行池 GATE_JOBS=6 447s（gates-20261012-160634.log）
```

逐门之和 1005.5s 对外层墙钟 167.5s 是 6.0x 的池内并行聚合，**不是加速比口径**：最长的 contract
一门 167.1s 几乎等于整轮墙钟，这一轮的瓶颈就是它。要再压 full 档墙钟，先动 contract
（`test_lua_router.sh` 的 24 段并行化），池宽再宽不买到东西。新实现的 `GATE_JOBS=6` 未单独测过，
本文不宣称任何目标时间。
