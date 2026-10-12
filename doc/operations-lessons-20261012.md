# 运维与协作 lessons（2026-10-12 一轮沉淀）

来源：2026-10-12 这一轮（admin Basic Auth 落地 → 21.k:8802 验收 → 21.k:8800 生产升级 → 文档清理）。
只记**下次会重复踩**的操作性事实；设计口径不在此，指向 doc/gap-*.md。

## 1. 发布链：绿锚点 → 镜像 → compose 一行 → 测试实例 → 生产

- 四步链，每步都要有盘上证据，缺一环就不算发过版：
  1. 全量门禁绿：`GATE_TIER=full bash test/final_gates.sh`。本轮两份 full 全绿日志：16:06 的
     `/data/tmp/lr-gates/gates-20261012-160634.log`（`GATE_JOBS=6`，构建镜像 `20261012-69b5d53` 的发布锚）
     与 16:47 的 `gates-20261012-164729.log`（更晚一轮，同样 22 passed / 0 failed / 0 skipped、
     `KEEP_GOING=1`、`SKIP_ENV=none`）。**门禁日志头部记了哪些开关就引哪些**，别把并行跑的
     `GATE_JOBS` 记到没开它的日志上；
  2. 镜像：`script/build-image.sh` 以「当天日期-HEAD 短 sha」命名推 ACR `pub/`，脚本开头有 dirty 闸
     （已跟踪文件有未提交改动直接 exit 1）：发版镜像只从干净绿锚点构建，这条闸是硬的；
  3. compose 只换镜像行，其余 env 逐字未动（本轮 `SMG_MAX_TREE_SIZE: 1e8`、watcher DENY_PORT、
     prom 负载通道、`LR_HTTP_INCLUDE` 全部保留）；
  4. 顺序：测试实例（21.k:8802）先滚并跑完验收矩阵，同一 digest 才推生产（21.k:8800，需用户授权）。
     「测试与生产跑同一镜像」是本轮的验收前提，不是巧合。
- **角色按 AGENTS.md 硬规则 3 判，不要自己下结论**：那条写的是「所有 8800 都是生产（本机
  `lua-router-8800`、21.k:8800、217.t:8800），21.k 的 8801 / 8802 是测试环境，未经用户明确要求一律
  不得更新生产」。本轮据此动的只有 21.k:8800（用户明确授权）与测试实例 8802，8801 未动。
  教训的形状是反的：**把测试角色写宽 = 给人顺手动生产的措辞**（把 8801 说成生产会让人不敢热验证），
  把生产角色写宽 = 直接踩红线；照抄规则原文最省事。
- 版本真值不在本文维护：fleet 现状表、逐台回滚顺序与 217.t:8800 的当前镜像一律以
  `doc/deploy-state.md` 为准（本轮由 fleet 刷新代理实测维护）。
- 回滚锚分两层：**21.k:8800 的直接回滚锚是上一版构建 `pub/lua-router:20261012-b5130da`**（本次
  升级前的运行镜像，一跳回到旧构建）；生产报告里的 sed 手册把 image 行写回
  `pub/lua-router:8800-20261011-89f0ad0`，那是 10-11 那轮的生产基线（跨两跳，同时回到无 Basic Auth
  的旧树）。两者按「要回到哪一版的行为」选，别照抄第一条 sed。手册与备份目录见
  `doc/deploy-8800prod-20261012-proxy-auth.md`。

## 2. 配置备份：SQLite 是在线库，WAL 不能整目录 cp

- 切换前备份 = compose + 配置目录全量 + **在线一致性快照**：`runtime.sqlite-online` 由 Python
  `sqlite3.Connection.backup()` 从活动 WAL 库导出。直接 `cp` 出来的 `.db` 不是事务一致的，只能当
  证据不能当恢复源（只读用 `sqlite3 file:...?mode=ro` 的 `.backup` 走 WAL 安全路径）。
- 为什么必须走在线备份：**WAL 模式下 `-wal` 文件可能领先主库**，未 checkpoint 的页全在 `-wal` 里。
  只 `cp *.db`（不带 `-wal`）拿到的快照**会丢最后若干笔写入**，最坏是拿到写入中途的页：它表面完好、
  `integrity check` 也可能过，恢复出来才发现配置少了最近一次编辑。恢复源要么走 `Connection.backup()`
  / `.backup`，要么先 `PRAGMA wal_checkpoint(TRUNCATE)` 再冷拷；两个都不做就只有证据价值。
- 判「升级窗口内有没有写入」看配置 revision：本轮前后都是 `44 10504bd6` ⇒ 零漂移，配置 db 无需回滚。
  这是最省事的升级后自检项，比看日志快。
- 做任何持久化验证之前先看 `lr_config_store_backend{backend="sqlite"} == 1`，否则验的是文件降级路径。
  本轮 fleet 五台全部为 1，没有一台在文件路径上。

## 3. 管理面口令与门控的五条纪律

- **`SMG_ADMIN_AUTH_PASS` 只走 env，值不落文档**：验收矩阵只写「带正确口令 200」，不写值。本轮用过的
  临时测试口令已从四份部署文档抹平（deploy-state / deploy-fleet / 两份 deploy-*20261012-proxy-auth）。
- **env 登记名册是唯一入口**：与 `LMR_CONFIG_STORE_*` 同一条纪律：三份 conf 的 `env` 白名单必须同步，
  漏登记 = nginx 从 worker 剥掉 = 门静默不生效。现象是「配了口令但匿名照旧」，极难查。
- **「出现即认证」是从生产实测反推的**：反代与网关同机时 remote_addr 恒 `127.0.0.1`，按值还原来源等于
  让一个 `X-Real-IP: 127.0.0.1` 的请求头绕过整道门。APISIX 在来源侧确实写 `X-Real-IP` /
  `X-Forwarded-For`（8800 经 `8800-248.ai-t.wtvdev.com` 与公网 `ws.gatepro.cn:99` 两入口取证）。
  口径见 doc/gap-admin-auth.md；扩来源头名单要同步 `PROXY_ORIGIN_HEADERS` 与单测。
- **`SMG_ADMIN_AUTH_PASS` 「已配」不等于「门开着」**：fleet 表里那一列只说明 compose 有那个 env，它不证明这道门真的生效。
  三件独立的事分开核：**env 在不在三份 conf 的 `env` 白名单里**（漏登记 = nginx 从 worker 剥掉 = 配了也不生效）、
  **镜像版本含不含 `admin_auth.lua`**（`fc037af` / `89f0ad0` 没这道门，配了必不生效）、**来源头的 loopback
  豁免形状**（直连 loopback 免凭据，本机 `/config` 200 属预期通过，不构成「门没开」的证据）。验收判域名列
  （经反代、带来源头）的 401/200，别用 loopback 结果判。
- **`GET /workers` 的池条数是发现数，不是调度面**：cache_aware 下 `SMG_MAX_TREE_SIZE` 是**每租户**字符闸，
  树只给活跃前缀的落点投票；一台已发现、健康的实例可以长时间拿不到 cache_aware 流量。查「它在不在池里」
  看 `GET /workers`，查「它实际分到流量没有」要看 `smg_worker_selection_total{worker=..}`（按 policy 标签分
  家族）或逐实例的 inflight 读数，别用池条数证明调度均匀。本轮的 8801 就是 9 条发现、cache_aware 长期
  聚到少数几台：这是 cache_aware 的正常形状，不是故障。

## 4. 门禁的并发与串扰（AGENTS 第 1 条的落地细节）

- 同一时刻只跑**一份**门禁（脚本内 flock，第二个 run 直接被拒）。门与门严禁并发是因为端口/名册/快照
  互踩；`GATE_JOBS=6` 是脚本内部并行互不干扰的门，不违反这条。
- 注释里的门数会漂：本轮 `test/final_gates.sh` 注释写 `all 21 gates`，`GATE_ORDER` 实为 22 门。
  **以数组为准，不以注释为准**。改注释是零行为改动，可单独提交。
- 被钉的文案家族不许顺手改，**含注释里的文档引用行**：契约与单测把它们一并钉住。本轮两处测试注释
  指向已移除的任务书路径，按裁定保持原样（改注释会连带红断言，价值不抵回归成本）。
- 收尾 `docker ps --filter name=lr-` 必须为空；精确 kill PID，禁 `pkill`。

## 5. 文档维护的三条硬规律（本轮清理的根因）

- **人工计数清单必然落后**：README 与 agent-handover §7 各维护一份清单+计数，11 天双双落后（README
  写 30/39，实测 44），两份清单还各自漂移。对策分两层：**唯一完整索引只留 README〈文档索引〉**（handover §7 降级为指针，
  不维护逐份清单），完整性由 `script/check_docs_index.py` 双向逐份比对（盘上有未收 / 表内有断链
  都退出 1）——**刻意不用「行数 == 计数」的判据**，漏收一份同时多收一份会互相抵消，检不出来。
- **「文件:行号」锚在大文件拆分后全部失效**：2026-10-05 facade 拆分后 `router.lua:3256` 指向不存在的行
  （router.lua 现 374 行）。对策：引用一律「文件 + 函数名」；`deploy-state.md` 开头已自认这条债。
- **废止口径的取证图会主动误导**：`verify-8802-20261004-ctx/` 那组截图证明的正是被裁定推翻并删除的
  「配置期校验」UI，文件名 `01-over-limit` / `03-card-limit-field` 会诱导下一个人照图恢复旧校验。
  判据：任务书与取证一旦有落地 commit + 测试证据就移出工作树。本仓惯例是直接删除、不建
  `doc/archive/`（2026-10-01 那轮 46→20 就是删除），逐份去向与落地 commit 写进
  doc/docs-cleanup-2026-10-12.md 留索引。

## 6. 跨机可达性的现实

- 本机到 21.k 的**业务 HTTP 口不通是网络设备层的既成事实**（box 记录 `21.k.md`：10.252.25.x 到其
  管理网只放行 22/ICMP，8800/8801 业务口全丢；21.k 没有 10.252.25.21 这个地址，旧记录有误）。本轮
  `curl :8800/health` 返回 000 而同一时段 SSH 可用，就是这个形状。写 fleet 现状
  **用 SSH + docker inspect 取真值**；取不到就标「待现场复核」，不要把文档口径写成实测结论，
  也不要把一次 HTTP 超时解读成「机器掉线」。
- 未测项如实记录：本轮生产矩阵明写「217.t→21.k:8800 的 LAN 直连匿名 `/config` 未测（防火墙面未探测）」，
  数据面 LAN 转发正常。诚实记录未覆盖面比写「全绿」更有用。

## 7. 多代理并行的所有权边界

- 本轮四路并行（清点审计 / 入口文档刷新 / fleet 刷新 / 清理执行）靠**文件所有权边界**避免撞车：README 与
  agent-handover 归入口刷新，doc/gap-* 与 AGENTS.md 归清理执行，deploy-* 归 fleet 与清理（口令抹平）。
  撞车即停手上报，不硬扛。
- 归档位置这类可逆的形态选择（`doc/archive/` 建不建）先做后报会被推翻：本轮先建后按裁定改为直接删除。
  **仓库惯例是判据**（本仓从无归档目录惯例），下笔前先 `git log --diff-filter=D` 看上一轮怎么做的。

## 8. 容量与亲和：三个「不看就会出事」的旋钮

- **亲和字符闸不是内存闸**：`SMG_MAX_TREE_SIZE` 是**每租户**在亲和树里保留的字符上限，实测标定
  5.5 chars/token，所以它约束的是「多少条满尺寸会话能同时留在树上」。本轮定尺 1e8/租户（≈ 15-18 条
  并发长会话），**不要缩**。缩小的症状是 LRU 每 120s 弹光长会话 → cache_aware 甩机 →
  前缀缓存整段重 prefill，表现为「突然变慢」，OOM 轮不到它。真闸是节点数 `SMG_MAX_TREE_NODES`（缺省 200k/树）+
  `SMG_EVICT_BUDGET` 增量淘汰。口径见 doc/gap-affinity-eviction-2026-10-11.md。
- **每服务上限是候选集硬排除，不是打分权重**：`max_concurrency` / `max_gpu_util` 在装配候选时直接
  剔掉（亲和命中也迁走），全池到顶回 429；`max_gpu_util` 读不到数时**不排除**（缺省零行为变化）。
  功率/瓦特一族已于 2026-10-09 移除，别再往配置里塞。口径见 doc/gap-worker-caps.md。
- **越界的容量值在入口就被拒**：`PUT /workers/{id}` 传超限值现在直接 400（不再 202 后「活到重启为止」）。
  写运维脚本塞过大值的，从这版起会开始报错。
- **fleet 版本快照（`doc/deploy-state.md` §0，2026-10-12 实测，本文只引用不复述规则）**：只有 21.k 的
  8800 / 8802 在 `20261012-69b5d53`；235.t:8800 与 21.k:8801 在 `20261011-fc037af`，217.t:8800 在
  `8800-20261011-89f0ad0`。后两版**不含 `admin_auth.lua`**，那两台上「配了口令也不生效」是因为门根本
  不存在。这段区间的对外形状有三处变化，按目标客户端实际读的字段核：① `owned_by` 自 2026-10-11 恒为
  `lua-router`，不再携带上游模型名，`owned_by_models` 整个退役，拿它判别入口行/真实行的客户端会失效；
  ② `created` 契约不变：入口行恒 0，真实行取引擎读数、取不到用常量 `MODEL_CREATED_UNKNOWN = 0`
  （`router/models_api.lua`）；③ `capabilities` 的形状（`reasoning_efforts` 的 picker 拼法与
  `capabilities.reasoning_effort` 判定面由 effort 映射推导、`max_output_tokens` 改语义）。这三条是本轮
  fleet 评估查到的真实兼容面，逐条核比记「有风险」有用。
- **网关一律不改写调用方的输出预算**：`max_tokens` / `max_completion_tokens` / `max_output_tokens`
  原样透传，没给也不替它填。运维时看到引擎回了超窗口的 400，先查调用方发来的数，网关这层不会替你造数
  （AGENTS.md 用户裁定 2026-10-04）。
- **入口的 `context_window` 只是对外声明的总窗口**，让客户端决定何时压缩，**不参与任何 max_tokens
  计算**，也不再触发配置期校验（2026-10-08 移除）。别拿它和卡片的 `max_output_tokens` 比大小：一个是
  上下文总窗口、一个是单次输出预算，两个量不可比，比了就是重犯 2026-10-04 那次 21.k:8801（测试环境）
  把三个量当一个数的故障。
- **每服务上限的读数语义**：`max_gpu_util` 只在**有新鲜利用率读数**时才参与判定，读数未知→不排除
  （宁可放进来也不能凭「没数」摘机）；`max_concurrency` 越界当场 400、合法边界 31/32/100 放行。口径见
  doc/gap-worker-caps.md §4 与 doc/gap-gpu-load.md。
