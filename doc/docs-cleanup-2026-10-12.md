# 文档清理执行记录（2026-10-12）

清理对象与判定依据：`/data/tmp/lr_doc_inventory.md`（HEAD `d3ae572` 的只读清单审计）+ 本轮 fleet
刷新后的盘上现状。执行者 `/root/docs_cleanup_execute`；README / agent-handover / architect 的入口与
计数刷新归 `/root/docs_entrypoints_refresh`，fleet 版本表刷新见 `doc/deploy-state.md` 与 `doc/deploy-fleet.md`。

## 1. 移出工作树（9 项：7 份 .md + 两组截图目录）

六份已完成任务书 + 一份并入后移除的裁定原文 + 两组一次性 UI 取证截图，从工作树移除后落在本机
`/data/.trash/lua-router-docs-20261012/doc/`。
**不建 `doc/archive/`** 是本轮裁定：本仓从无归档目录惯例，2026-10-01 那轮 46→20 就是直接删除，
`git log --diff-filter=D` 可复原。逐份落地证据：

| 移出物 | 落地 commit / 证据 | 现行口径去处 |
|---|---|---|
| `cap-put-ceiling-task.md` | fb56278 / fc037af（越界当场 400，一份判据两处用） | doc/gap-worker-caps.md §4；锚 `test/unit/test_caps_persist.lua` 第 8 段 + 契约 workers 段 |
| `cap-put-test-task.md` | 同上（测试收尾波） | 同上 |
| `efforts-maxtok-task.md` | 717d87f / 4e6ffc9 / 9d8ea2b | doc/gap-virtual-models.md §5、doc/gap-effort-ladder.md |
| `shadowing-core-task.md` | dc3a370（写入层四处守卫 + 引擎背书判据） | doc/gap-virtual-models.md §2/§9 第 2 条；裁定原文留 `doc/shadowing-2026-10-07.md` |
| `shadowing-test-task.md` | 9811ea3（T1–T11 判别用例） | 同上 |
| `shadowing-verify-task.md` | 真机验收 gates-20261007-170747.log（full 22/0/0） | 同上 |
| `effort-apikey-2026-10-11.md` | 89f0ad0 + 717d87f / 4e6ffc9 / 9d8ea2b | 五条最终裁定**已并入本文 §1.1**；现行口径 doc/gap-virtual-models.md §2 / §5 |
| `verify-8802-20261003/`（2 张） | 10-03 日志页 / 路由页形状取证 | 页面此后随 7e8bfff admin 迁根变化；doc/ui-trim-legacy-pages.md |
| `verify-8802-20261004-ctx/`（4 张） | **所证行为已废止** | 钳制口径由用户裁定 2026-10-04 推翻、比较式配置期校验与 UI 预校验于 2026-10-08 移除（7e8bfff）；doc/gap-virtual-models.md §4 / §4.1。文件名 `01-over-limit` / `03-card-limit-field` 记录的正是当日即被推翻的旧 UI，留在顶层会诱导下一个人照图恢复旧校验 |

判据三条：任务书有落地 commit + 测试证据；结论已被代码与顶层现行规格吸收；留在 `doc/` 会被下一个人
当成待办或现行口径。`effort-apikey-2026-10-11.md` 的处置走的是另一条判据：它含一段一次性用户裁定（五条
最终口径，代码里读不出「当初为什么这么定」），所以**先并入本文 §1.1 再移除**，理由不是「被代码吸收」。
保留在 `doc/` 的历史类文档：parity-* / real-eval.md（数据留档）、`shadowing-2026-10-07.md`（遮蔽裁定原文，
正文仍是现行判据的唯一出处）、两份真机验收报告 `deploy-*20261012-proxy-auth.md`（8800 下一次升级前的
回滚依据），全部不投入维护。

## 2. 锚点债（系统性，facade 拆分遗留）

2026-10-05 把七个 2000+ 行大文件拆成 facade + 子模块后，全部「文件:行号」锚漂移。本轮按
`doc/deploy-state.md` 自己声明的口径（「行号一律可能漂移，引用前 rg 复核」）改成**函数名锚**：

- `AGENTS.md`：裁定块的 `router.lua:3256` / `:3263` / `:3579` 与 `config_store.lua:1937` / `:1970` 五处
  → `router/inference.lua` 的 `apply_ctx_cap` / `entry_ctx_cap`、`router/models_api.lua` 的 `MODEL_CREATED_UNKNOWN`、
  `config_store/readers.lua` 的 `ctx_cap` / `virtual_ctx_cap`；AGENTS.md 全文数值锚清零。
- `doc/gap-virtual-models.md`：14 处四位数行号锚全部改「函数名 + 所在子模块」；§5.2 的 `ui.lua:198`
  → `ui.lua` 的 `ui.models()`。

不扫全仓：`doc/gap-inflight-age.md` §8 的 md5 代码树与 `parity-cpu-ablation.md` 的 20+ 行号锚属纯历史
测量，按「对拍是手段不是目标」的定位不投入维护。

## 3. 口径与数字修正

- `test/final_gates.sh` 注释两行 `all 21 gates` → `all 22 gates`（`GATE_ORDER` 实为 22 门，README 早就写对）。
- `doc/gap-session-2026-10-04.md` §1 末尾补废止标注：`context_limit` 配置期校验（违反拒绝保存）整条已由
  用户裁定 2026-10-08 废止，函数与 UI 预校验于 7e8bfff 移除；现行口径看该节 §4 与 gap-virtual-models.md §4。
- `doc/gap-effort-ladder.md` §3 的字段名 `context_limit` → `max_output_tokens`（原名括注保留）。
- `doc/gap-watcher-merge.md` §1.1 补 2026-10-09 用户裁定（9bf3c07）：reject 三档的后果由「当轮摘除」改
  「临时禁用保行」（`SMG_WATCHER_PROBE_TEMP_DISABLE=0` 退回旧行为），表头与「确定性否定」行同步。
- 入口面引用（`/_ui/*` → `/`、`/config`、`/u/*`）、信任边界补管理面 Basic Auth、文档份数改
  `ls doc/*.md | wc -l` 现测口径（清理后 39 = 44 − 7 份 .md（六份任务书 + 并入后移除的 effort-apikey 裁定原文）
  + 2 份新增（本记录与 operations-lessons-20261012.md）；截图目录不计入 .md 份数）：
落在 `doc/agent-handover.md` §0 / §7 与 README。

### 3.1 P1 复查轮（同一天的第二遍，依据 /data/tmp/lr_docs_review.md）

四路审查（链接索引 / 口径对代码 / 数字实测 / 结构文风）合并后的 P1 六条，本轮全部落地：

1. `AGENTS.md` 定位 1 的「条目级只允许 `context_window` 一个覆盖字段」落后两个裁定，改为「条目级只允许
   **声明位**覆盖」并列全清单（`context_window` / `max_output_tokens` / `default_effort` 与 `effort_map` /
   `modalities` / `hidden` / `disabled` / `api_key`，`policy` 不在其中），指向本文 §2 字段表；定位 2 的
   「档位归模型卡片」补一句「入口对外的档位清单由条目层 `effort_map` 推导」，消掉与条目层的自相矛盾。
2. `README.md` watcher 段的探针分档口径改为现行（reject 三档当轮临时禁用保行 + `SMG_WATCHER_PROBE_TEMP_DISABLE=0`
   退回旧删行），旧话术「确定性否定当轮摘」在 README 消失；`doc/gap-watcher-merge.md` 第 12 条的同一句
   改为指向 §1.1 的表作为唯一口径，并标注 10-09 的后果改写。
3. `doc/gap-virtual-models.md` §2 的条目级 `max_output_tokens` 行按实测改写为「配置可解析、可落盘往返，
   但广告链尚未消费此声明」（入口行走 `narrowest_number` 组内聚合，真实行走卡片 > 平铺两档，两者都不读
   条目层这一位）。它是**尚待接线的实现缺口**，刻意不写成与 `policy` / `effort` 同款的兼容行为——那两位的
   「接受、往返、不读」有 2026-10-02 用户裁定背书，本字段没有，接线与优先级顺序要另行设计。旧话术
   「唯一去处是 `capabilities.max_output_tokens`」只对卡片层成立；同节 `effort_map` 行的四字段名按
   `9d8ea2b` 后的现行落点重写。`doc/efforts-maxtok-task.md` 已随本轮清理移出，它记录的这条缺口以本节为锚。
4. `doc/caps-redesign-2026-10-06.md` 顶部加作废块：功率采集链 `pw:` 与 `lr_gpu_load_power_*`「保留（仍有读者）」
   已被 10-09 的整体移除推翻，`max_power_w` 也不再 warn-once 而是按未知字段静默忽略，现行容量口径只看
   `doc/gap-worker-caps.md`。
5. `doc/architect.md` 同文件两个契约数统一为 **765**（L19 与 L295 的 691 与 L6、README 的 24 段分解求和、
   两份全绿日志逐段核对不一致，765 可信）。
6. `doc/gap-routing-dyn.md` 顶部加端点迁移标注，正文四处 `/_ui/config/policy` 改正为根上的 `/config/policy`
   （别名 `/u/config/policy`），并写明 2026-10-12 起该 location 在管理面 Basic Auth 门内。

附带一条断链修复：`doc/gap-virtual-models.md` 的 api_key 行指向本轮移除的 `effort-apikey-2026-10-11.md`，
改指本文 §1.1。P2 / P3 未在本轮处理（重复承载收敛、代码注释旧口径、登记白名单补齐），清单留在
`/data/tmp/lr_docs_review.md`。

同轮顺手落掉的 P3 五条（同一份报告的第三节）：`doc/agent-handover.md` 的「69 个导出」改实测 79 枚（facade 头注释的 68 是拆分当时数）、§4 末尾「AGENTS 硬规则 4 同步待更新」改为已同步、§0 的「条目级只允许 context_window 一个覆盖字段」与定位 1 同批改写、「管理台四页」顺序改正为模型管理在前；`doc/architect.md` 的 `max_power_w` 措辞由「warn 一次并丢弃」改「按未知字段静默忽略」（warn-once 随通道删除）；`README.md` 契约 prometheus 段 14 → 17（与 24 段构成表一致）；`doc/deploy-fleet.md` 末条纪律的「8801 是生产」改正为测试实例，并写明角色真值只在 AGENTS 硬规则 3 与 deploy-state 两处维护。**未处理并登记**的两条：`SMG_WATCHER_PROBE_TEMP_DISABLE` 没进三份 conf 的 env 白名单（功能不坏——watcher 在 init 阶段抓 env，动 conf 要 full 门禁，留作下轮）；`final_gates.sh` 头部不记 HEAD sha（锚点与 commit 靠时间戳推断，属 test/ 面，越出本轮所有权）。重复承载收敛（同一口径全文复述 3 处以上）与代码注释旧口径（`watcher.lua` 守卫 10 注释、`watcher/probe.lua` 文件头与 `probe_verdict` 的 reject 段仍写 2026-10-01 语义，行为侧正确）也在清单里留着。

本轮码侧只改 §3.2 列的三处 watcher 注释（零转发字节），其余全在 AGENTS.md / README.md / doc/。文档计数的同锚全绿日志是
`/data/tmp/lr-gates/gates-20261012-174411.log`（tier=full、`GATE_JOBS=6`、`KEEP_GOING=1`、`SKIP_ENV=none`，
22 passed / 0 failed / 0 skipped；contract 门 `Triage run: 765 passed, 0 failed, 2 notes`，与 README L62/L81
的 24 段分解求和一致），收尾 `docker ps --filter name=lr-` 为空。它与 §4 的两份日志同源同码：
16:06 那份是镜像 `20261012-69b5d53` 的发布锚，16:47 那份是清理轮的计数锚，本轮（17:44）是 P1 复查轮的锚。

### 3.2 P2 / P3 顺手项（同一轮，报告的第二、三节）

- `doc/agent-handover.md`：「69 个导出」改实测 79 枚（facade 头注释自述的 68 是拆分当时数）；§4 末尾「AGENTS 硬规则 4 同步待更新」改已同步；§0 的「条目级只允许 context_window 一个覆盖字段」与定位 1 同批改写；管理台四页顺序改正为模型管理在前。
- `doc/architect.md`：§max_power_w 措辞由「warn 一次并丢弃」改「按未知字段静默忽略」（warn-once 自随功率通道删除）；文首不再钉代码文件数与行数，与 §3 既有的「引用前重取」纪律一致。
- `README.md`：契约 prometheus 段 14 → 17（与 24 段构成表一致）；watcher 段探针分档口径改现行；推导四件套的字段名按 `9d8ea2b` 后的现行落点重写（根路径无 `supported_reasoning_efforts`）。
- `doc/deploy-fleet.md`：末条纪律的「8801 是生产」改正为测试实例，并写明角色真值只在 AGENTS 硬规则 3 与 deploy-state 两处维护。
- **代码注释同步为分档新后果**（`gap-watcher-merge.md` §1.1 要求注释与话术一致）：`watcher.lua` 守卫 10 注释、`watcher/probe.lua` 文件头与 `probe_verdict` 的 reject 段、`watcher/reconcile.lua` 探测段注释，三处统一写成「分档不变，变的是这一档的后果：自 `9bf3c07` 起是临时禁用保行，`=0` 退回当轮删行」。零转发字节改动，三份 `luajit -bl` 通过。
- **未处理并登记**：`SMG_WATCHER_PROBE_TEMP_DISABLE` 未进三份 conf 的 env 白名单（功能不坏——watcher 在 init 阶段抓 env，动 conf 要 full 门禁，留作下轮）；`final_gates.sh` 头部不记 HEAD sha（锚点与 commit 靠时间戳推断，属 test/ 面，越出本轮所有权）；历史文档身份句（shadowing / gap-inflight-age / scope-trim / ui-trim / deploy-fleet 的「结论」节、gap-mesh 的 `/ha` 503 句）与重复承载收敛（同一口径复述 3 处以上）未在本轮动，清单留 `/data/tmp/lr_docs_review.md`。

## 4. 验证与门禁锚

`bash -n` `test/final_gates.sh` / `test/test_lua_router.sh` 通过；`luajit -bl` `test/unit/test_caps_persist.lua` 通过。
本轮代码侧只改 `test/final_gates.sh` 的两行注释（`all 21 gates` → `22`，与 `GATE_ORDER` 的 22 门对齐），
零转发字节改动。契约门在纯文档树上单门复跑绿：`GATE_ONLY=contract` →
`/data/tmp/lr-gates/gate-contract-cleanup.log`（1 passed / 0 failed，contract PASS 155s）；
文档计数改动的同锚全绿日志是 `/data/tmp/lr-gates/gates-20261012-164729.log`（tier=full、`KEEP_GOING=1`、
`SKIP_ENV=none`，22 passed / 0 failed / 0 skipped；16:47:29 起跑，当时 HEAD `d3ae572`——该树与
`69b5d53` 在 lualib / conf / ui / test / Dockerfile / entrypoint 上逐字节一致，差异只有 doc/ 与
`script/build-image.sh`）。16:06 那份 `gates-20261012-160634.log`（`GATE_JOBS=6`）是镜像
`20261012-69b5d53` 的发布锚，两份别混引：门禁日志头部记了哪些开关就引哪些。
收尾 `docker ps --filter name=lr-` 为空。

测试注释指向已移除路径的两处（`test/test_lua_router.sh` 的 cap-put 段、`test/unit/test_caps_persist.lua`
第 8 段）按裁定**保持原样**不改：契约与单测把注释里的文案一并钉住，改注释会连带红断言，
其价值不抵回归成本；两处指向的任务书 `git log --diff-filter=D` 可复原，现行口径在 doc/gap-worker-caps.md §4。

### 1.1 并入的裁定链：虚拟服务 api-key 与能力字段推导（2026-10-11，`effort-apikey-2026-10-11.md` 随并入移除）

该执行契约的落地物已在盘上（`89f0ad0` 管理台 api-key 三态输入与 effort 映射交互、`717d87f` / `4e6ffc9` /
`9d8ea2b` 能力字段推导），契约正文的勘察段与波次表随之失效；只有「用户最终裁定」那五条是下一个人会
需要的一次性判断依据，在此留全，原文与逐波文件所有权见 `git show` 该文件。现行实现口径见
doc/gap-virtual-models.md §2（字段表与 supports_* 拆除）与 §5（能力字段与来源优先级）。

1. **入口只保留一张 effort 强度映射表**（选 A）：默认使用原始值，`from == to` 的恒等映射就是「全档位
   原样透传」。推导必须是确定性的（同一配置每次出同一字节）。**现行对外字段以源码为准**
   （`router/models_api.lua` 的 `effort_advertise.derive` 与 `fill_model_fields`）：根路径产出
   `supports_reasoning` / `supports_reasoning_effort` / `default_reasoning_effort`，档位清单由顶层
   `reasoning_efforts`（picker 形状，含 `value`，缺省档标 `default=true`）与
   `capabilities.reasoning_effort` 两处承载；需求原文点名的根路径 `supported_reasoning_efforts`
   已由 `9d8ea2b` 移除。引这条裁定时按现行字段名引，别照抄需求原文那张表。
   入口上原有的独立布尔位（`supports_tool_use` / `supports_streaming` / `supports_reasoning` /
   `supports_vision` / `supports_reasoning_effort`）**从配置层与解析一并拆除，不留「接受但忽略」的兼容支**
   ——与同文档里 `policy` / `effort` 那两位「接受并落盘、热路径不读」的裁定刻意相反，理由是「显式声明说
   false、effort 映射又说 true」这种自相矛盾不该存在。拆除面**只到虚拟服务条目**：模型卡片
   （`model_configs`）上的同名字段说的是落点引擎自己，继续按「声明 > 引擎自报 > 省略」说话。
2. **api-key 门是条目级、不是全局平面**：配了 key 的入口，没带 key 或带错 key 一律 **401 Unauthorized**
   （两者同形，不区分）。这是 AGENTS.md 硬规则 5「网关零鉴权」之上的**条目级**门，不恢复被删的 auth 平面。
   key 的 GET 回显恒为掩码，明文永不回显；写入三态 keep / clear / set 沿用 upstreams 层已有纪律。
3. **视觉能力从 `modalities` 判**：含 `image` 或 `video` 就报 `supports_vision: true`，**不区分这份模态来自
   引擎自报还是操作员手填**。反向（报 `false`）只在操作员声明时给，因为只有卡片模态是穷尽列表。
4. **档位清单一律列配置里实际出现过的档位**（`4e6ffc9` / `9d8ea2b` 的落地语义）：来源是本层
   （卡片 / 条目）`effort_map` 的 from 侧 + 本层 `default_effort`（缺省档也算「配置里出现过」）；
   低层读数（`model_effort` 强制行、全局 `default_effort`）**只喂缺省档、不进清单**。按 lexicon 的
   `EFFORT_LEVELS` 规范序（`none,minimal,low,medium,high,xhigh,max,ultra`）排序，**不硬编码需求示例里
   那张 6 档表**，也**不按配置字节序**出（`pairs()` 收集的顺序会打掉「同一配置两次调用逐字节相同」这条
   既有纪律，`test_models_shape` G9 与 `e2e_models_advertisement` 钉着它）；恒等映射（全档位）时列全
   部 8 档。
5. **省略与缺省档（判据：清单为空或只剩 `none` 都算「没配」，`effort_advertise.derive` 返回 nil）**：
   - **没配（含只配了 `none`）**→ 四个键整体省略（删键，不写 `null`、不写空数组冒充「支持零个」），
     旧的三个 opencodex 顶层位（`supports_reasoning_effort` / `reasoning_effort` / `reasoning_efforts`）
     照旧走「声明 → 引擎自报 → 派生」那条未改动的链——纯引擎自报的行（现网大多数）逐字节不变。
     这是 AGENTS.md 硬规则 9②「宁缺勿猜」在本族字段上的落地，也是裁定第 5 条的字面语义。
   - **配置存在（`none` 以外的任意一档出现）**→ `supports_reasoning` 与 `supports_reasoning_effort`
     恒 true（不存在「配了表却报 false」那一支，那正是裁定要拆的自相矛盾）；`default_reasoning_effort`
     按转发链层序取操作员配置（`model_effort` 强制行 > 卡片 > 条目 > 全局，第一个说了的赢，与
     `readers.lua` 的 `effort_default_lookup` 同判据），操作员没显式给时缺省 `medium`（`4e6ffc9`）。
     缺省档**不要求落在清单里**：清单说「能点名哪些档」，缺省档说「没点名时发哪一档」，拿一个判另一个
     就是重演 2026-10-04 把三个量当一个数的事故。
   - 配了映射的那一行，四个推导字段是**纯增量**：紧随其后的旧三个顶层位（`supports_reasoning_effort` /
     `reasoning_effort` / `reasoning_efforts`）按既有链**照常无条件产出**，两处数据同源时值一致，
     引擎自报 `ladder` 在场时它覆盖推导出的 picker 清单（`fill_model_fields` 里的写入次序）。
     `capabilities.reasoning_effort` 在配了映射时取**推导档位**（`9d8ea2b`），没配时取引擎 `accepted`；
     引擎读数本身（`row.ladder` / `row.accepted`）始终照常采集，只是不再为它对外画第二份清单。
     注：`fill_model_fields` 的函数头注释写着「两组字段互斥、旧 picker 与缺省档位一并让位」，与
     `resolve_model_caps` 里 2026-10-11 那段「纯增量、不顶掉旧三位」的注释**互相矛盾**，按代码是以
     增量为准（旧链那块在推导支之后无条件执行）。下一人要动这块先以代码为判据，别照任一条注释写。
