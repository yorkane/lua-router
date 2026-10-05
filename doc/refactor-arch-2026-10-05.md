# 重构架构设计书（2026-10-05）——模块拆分 + UI 改造 + 入口迁移

> 本文是本轮重构的**执行契约**。所有 worker 子智能体必须逐条遵守；任何偏离先上报 root。
> 设计输入：五份测绘报告（/data/tmp/lr-map-{router,config-store,registry-policy,bg-obs,ui}.md）。

## 0. 总目标与不变量

**目标**：把 7 个 2000+ 行的大文件拆成「facade + 子模块」层级，抽出公共模块，UI 三页改造，
入口迁移 /u/ 与 /a/。**对外行为零变化**是唯一验收口径。

**不可违反的不变量**（违反任何一条 = 重做）：

1. **HTTP 面逐字节不变**：所有端点状态码、响应体字节、头部（除本文明示的入口迁移外）。
2. **`_M` 导出契约不变**：每个被拆模块的 `_M` 导出名集合、函数签名、返回值形状逐名保留
   （facade 上 re-export）。单测按名钉住的空壳（profile_policy/profile_effort/virtual_ctx_cap 等）原样保留。
3. **shdict 键格局与写者不变**：8 个字典、每键的写者集合不增不减（尤其 `luarouter_config` 唯一写者仍是
   config_store 域；lr_workers 旁路写者 hb/init/router 三处不变）。
4. **调用语义不变**：原文件内 `local function` 直调 → 拆分后子模块间直 require 调用；
   原文经 `_M.x()` 的自调 → 拆分后必须仍经 facade 表调用（保持单测换桩可拦截性逐点一致）。
5. **热路径零新增开销**：不得引入新的每请求 require 解析失败路径、新的 shdict 往返、新的字符串拼表。
   调用期惰性 require 只允许出现在冷路径或模块加载期。
6. **AGENTS.md 全部硬规则照旧**（字节透传、输出预算透传、探针分档、缺省零行为变化等），拆分不是改行为的机会。

## 1. 目标布局

    lualib/resty/luarouter/
      httpc.lua                  新增公共模块：cosocket 连接池 + HTTP 原语
                                 （自 registry 的 E 块提升；registry 保留 re-export，
                                  router/config_store/hb/mesh/watcher/gpu_load 的既有借用点全部不动）
      router.lua                 facade：路由表 + _M.handle + re-export（≤400 行）
      router/
        jsonutil.lua             P9 顶层改写族 + P1 DP rank 注入 + P6 文本抽取 + P12 usage
                                 + P13/P15 SSE 工具 + P14 session 指纹（纯函数为主）
        respond.lua              P3 错误应答 + P4 CORS + P5 request id
        profiles.lua             P8 profile 读层缝（含两条恒 nil 停用缝，原样保留）
        candidates.lua           P11 候选装配 candidates_for 三门 + 组门 + card_key 族（热路径）
        pump.lua                 P16 cosocket 泵（connect/read head/send_attempt/discard/read body）
        forward.lua              P17 streaming 泵 + P18 重试环 + P19 forward 主循环
        inference.lua            P20 推理面 + P21 公开面
        models_api.lua           P22-P24 /v1/models 合成 + 广告开关 + handlers
        metrics_ep.lua           P25 metrics 聚合渲染 + engine_metrics/model_info
        control.lua              P26 控制面 + P27 观测/mesh handler + P28 请求日志收尾
      config_store.lua           facade（≤200 行）
      config_store/
        lexicon.lua              P2-P6 helper/词表/JSON 小工具
        env.lua                  P5 ENV_NAMES/capture_env/env + P13 env 层装配 + LMR_UPSTREAMS_FILE 种子
        profiles.lua             P8-P10 池/候选/绑定/组装配 + profile 装配 + 别名链守卫
        upstreams.lua            P11 声明层校验脱敏 + P29 drift/patch/reconcile
        snapshot.lua             P1 空快照语义 + P12 new_cfg/sync_virtual_view/new_card
                                 + P14 snapshot_of + P15 merge/validate + P16 cfg_from_document
        persistence.lua          P17-P21 dict/store 惰性解析 + 三层读写 + CAS 冲突 + persist + migrate_once
                                 【硬边界：全模块只有本文件碰 shdict/后端/文件 IO】
        readers.lua              P22-P26 current/ctx_cap 族/modalities/policy 热路径读/虚拟视图/effort 查表
        mutators.lua             P27-P28 apply_* 家族 + P30 整表写
        httpc.lua                P31 raw_request（复用公共 httpc 的薄封装，保持池参数原值）
        handlers.lua             P32-P35 watcher 桥 + document/models_document + 10 个 handle_config_*
      registry.lua               facade（≤250 行）
      registry/
        keys.lua                 A 键格局 + B shdict 懒解析/with_lock + C worker id + G ids 名单
        url.lua                  D url 解析族（normalize/strip_rank/rank_of/split_url/tls_handshake）
        caps.lua                 J 上游能力采集（620 行自包含纯域）
        records.lua              H 规格解析 + I models 助手 + L add/remove + M 读出/视图 + P patch_record
        health.lua               N 健康位与熔断（含 open 到 half_open 唯一恢复 CAS）
        loads.lua                O 负载折叠 + capacity_exclusion 上限判定（读数未知到不排除，原样）
        discovery.lua            Q 探针/覆盖度 + R PUT update + S 元数据发现 + T DP 展开 + U/V 作业队列/bootstrap
      watcher.lua                facade（≤200 行）
      watcher/
        env.lua                  26 枚 SMG_WATCHER_* new_config + URL 规范化 + 自端口
        modelmap.lua             model map 解析 + effective_map/apply_model_map
        probe.lua                严格探针 classify/probe_verdict 三档判定（分档语义逐行原样）
        discover.lua             三源发现纯层 + docker unix_get/collect
        ledger.lua               台账 new_ledger
        reconcile.lua            reconcile 整体 + 摘除分档 + 保险丝【内部不许再拆】
        live.lua                 live 入口 + make_fetch/probe_pool + registry 适配 + run_pass/tick/start
      gpu_load.lua               facade（≤150 行）
      gpu_load/
        parse.lua                exposition 解析族
        cards.lua                卡归属与折叠（四路口径逐行原样）
        prom.lua                 Prom 客户端
        seams.lua                9 个 default_* live seams + effective_load + warn_dedup
        runpass.lua              run_pass + one/one_power 提为模块级（stats 字段口径单点定义）
        export.lua               指标导出 + 定时器 start/stop
      mesh.lua                   facade（≤200 行）
      mesh/
        crdt.lua                 时钟/编解码/LWW/版本向量 + 成员身份底座 + new() 六张 store
                                 + 成员表操作 + 分区检测 + observe_* + 快照合并
                                 【幻影键修复正确性依赖这些同域，不许再拆】
        wire.lua                 wire encode/decode
        rate.lua                 限流窗口
        handlers.lua             内部端点 + /ha/* 13 条
        sync.lua                 cosocket http_request + sync_with + start + ROUTES/dispatch/from_env + 单例
      observability.lua          facade：写侧原语 + record_* + HELP 表 + prometheus_text
                                 【写侧原语与导出器必须同域，键文法是隐式契约】
      observability/
        inflight.lua             在飞年龄 tracker（1024 槽）
        logstore.lua             环形缓冲 + 查询 DSL + /_ui/logs 三 handler + stats()
      policy.lua + policies/     【不动】已足够模块化

## 2. Facade 模式规范

每个被拆模块的 facade 形状：

    local _M = {}
    package.loaded["resty.luarouter.router"] = _M  -- 预登记，子模块加载期可回指
    local jsonutil = require "resty.luarouter.router.jsonutil"
    _M.set_top_field = jsonutil.set_top_field
    -- 或保持函数包装（仅当原导出存在运行期替换路径时）：
    function _M.candidates_for(...) return candidates.for(...) end
    return _M

规则：

- **默认直接赋值**（`_M.x = sub.x`）；仅当原代码存在运行期替换该 `_M` 成员的测试/生产路径时
  用包装函数。worker 必须逐导出查 test/ 里的桩替换点（package.loaded 换桩与 `_M.x =` 覆写）决定形态。
- **子模块间依赖**：能构成无环图就直 require（加载期解析）；有环处（如 records 与 health 互调）用
  「调用期 facade 解析」，且只在函数体内调用，加载期不触碰。
- **facade 自调保持**：原 `_M.x()` 自调 → 子模块内经 `require "resty.luarouter.router"` 拿到
  同一张 facade 表（靠预登记），调用期解析成员。

## 3. 测试侧联动（拆分时必须同 commit 完成）

1. **六个字符串锚点单测**（test_integration/test_caps_routing/test_models_shape/test_models_advertise/
   test_effort_layers/test_profiles）：它们按字符串切 router.lua 源码配桩。代码搬到哪里，
   锚点的**文件路径**就改到哪里，锚点字符串本身不变（代码逐字搬家）。worker 必须逐个核对锚点仍能匹配。
2. 单测的 `package.loaded["resty.luarouter.X"]` 整体换桩不受影响（facade 名字不变）。
3. 新增子模块文件若在 test/conf/nginx-lua-router.conf 的 /klib/load 预热名单有对应要求，必须登记。

## 4. 验证阶梯（每个 worker 完成时自查）

1. `luajit -bl` 全部改动文件语法过。
2. 相关单测直跑（不经 final_gates.sh，避免 flock 串行冲突；命令从 final_gates.sh unit 段抄）。
3. root 整合后统一跑门禁：quick 到 full（22 门 0 skipped）。
4. 提交纪律：每 worker 只 `git add` 自己名下的文件，一个子模块拆分一个 commit。

## 5. UI 改造契约（frontend worker）

### 5.1 虚拟模型条目化（models.html，最高优先）

- 现状（改造前）：虚拟条目是常驻编辑面（行内逐字段 input 网格）。
- 目标：改成「条目列表 + 点击编辑弹表单」，**样板照抄两处既有实现**：
  `ui/admin/models.html` 的卡片编辑对话框（q-dialog + dialog-fields + form-grid-2）与
  `ui/admin/workers.html` 的 `saveDecls` 整表链路（先取新鲜整表、mutate 只替换目标条目、
  整表 POST；改名用打开对话框时的自键定位）。引用一律按名称不按行号。
- 列表行展示：入口名 + targets 摘要 chip + context_window + 操作（编辑/删除）。
- 编辑对话框承载现有全部字段：model、context_window、targets 子表、effort_map 子表、
  六个三态 select + modalities、广告范围块（advertise 开关族）。
- 保存链路不变：`configVirtual`（POST /_ui/config/virtual 整表）。**请求形状逐字节不变**
  （`test/integration/e2e_profiles.py` 钉着）。
- 校验逻辑（`validateVirtualRow` / `virtualCtxOverflow` / 提交前的 Blocking 判据）原样保留，搬进对话框提交流程。

### 5.2 控件密度与 radio 化

- `ui/admin/logs.html` 的 `filters.status`（4 选项）→ q-btn-toggle（inline、dense），选项顺序与值不变；
  顺手清除 path 筛选死代码（同文件内的 path 过滤分支与相关字段）。
- workers.html：add 对话框 modelsText+labelsText 组 form-grid-2；decl 对话框同；
  decl 的两个 toggle（disable_health_check/clearKey）并排一行；edit 对话框 labels 与 toggle 两列。
- routing.html：全局策略卡与「生效链说明」卡合并为一卡两列（preview-fields），消除独占行。
- app.css 新增 .form-grid-3（需要三列处），并在 820px media 段补单列回落。
- 原则：**4 个及以下选项的 q-select 一律 radio/q-btn-toggle**；8 选项的 policy select 不动。

### 5.3 入口迁移（/u/ 与 /a/）

- webui：`/u/` 提供静态 + **/u/ 前缀的全套 webui API 别名**（照 ui.conf 的 /_ui 块机械复制改前缀，
  exact `=` 纪律不变，防 shadow 静态文件）。
- **根路径补齐 webui 所需端点**（用户裁定：为原版 webui 零修改集成）：
  /slots、/tools、/models/load、/models/unload、/models/sse、/v1/stream、
  /v1/streams/lookup、/v1/chat/completions/control、/properties（已存在的 /props、/v1/* 不动）。
  handler 直接复用 ui.lua 现有函数（empty_array/unsupported/model_load/...）。
- `/_ui` → 302 `/u/`；`/_ui/` 前缀（非精确 API 别名）→ 302 到 `/u/` 对应路径；
  `/_ui/admin` 与 `/_ui/admin/` → 302 `/a/`。**/_ui/* 的精确 API 别名全部保留**
  （当前 bundle 硬编码 + e2e 钉着）。
- `/a/` 提供 admin 静态；admin-inject.js 注入链接改指 `/a/`。
- admin API（/_ui/config|logs|stats|props）不动。
- 测试联动：test_lua_router.sh 的 ui_fixed 段断言改写为：/_ui → 302 到 /u/、/u/ → 200 html、
  /_ui/admin → 302 到 /a/、/a/ → 200 html、四个旧页面仍 404；e2e_ui_bridge.py 不动。
- 全仓 grep `/_ui/` 与 `/_ui/admin` 的引用点（README、doc、admin-inject.js、app.js、i18n.js）
  逐点判定：API 引用保留，页面入口引用改新路径。

## 6. 波次与所有权

| 波次 | worker | 名下文件（独占） | 依赖 |
|---|---|---|---|
| W1 | w_router | router.lua、router/、test 六锚点文件 | 测绘 lr-map-router.md |
| W1 | w_config | config_store.lua、config_store/ | lr-map-config-store.md |
| W1 | w_registry | registry.lua、registry/、httpc.lua | lr-map-registry-policy.md |
| W1 | w_bg | watcher.lua、watcher/、gpu_load.lua、gpu_load/ | lr-map-bg-obs.md |
| W1 | w_meshobs | mesh.lua、mesh/、observability.lua、observability/ | lr-map-bg-obs.md |
| W1 | w_ui_models | ui/admin/models.html | lr-map-ui.md |
| W1 | w_ui_density | ui/admin/logs.html workers.html routing.html、app.css、i18n.js | lr-map-ui.md |
| W2 | w_ui_entry | conf/*、ui/admin/index.html app.js api.js、ui/admin-inject.js、test_lua_router.sh 断言段 | W1 全部完成 |
| W3 | root | 整合 + quick/full 门禁 | W1-W2 |
| W4 | t_8802 | 21.k:8802 部署与真机验证 | W3 全绿 |

冲突禁令：W1 期间任何人不碰 conf/、ui/admin/index.html、app.js、api.js、init.lua。
init.lua 的 require 预登记若需调整，由 root 在 W3 统一处理。

## 7. 顺带发现（登记 backlog，本轮不修）

1. write_snapshot 镜像写绕过 store_dispatcher.mirror_to_file → mirror_failed 指标永不增长。
2. LMR_MODEL_TOOL_USE 不在 ENV_NAMES 名册（与硬规则 11 同形隐患，待核实是否在 worker 阶段读）。
3. observability.record_worker_attempt 全仓无调用点（attempt 口径只有 entry 半边）。
4. gpu_load 五族指标不在 HELP 表（只出 TYPE 不出 HELP）。

## 8. 8802 验证清单（W4 执行）

- 镜像构建 → ACR push（pub/lua-router:8802-20261005-N）→ 21.k compose 换镜像 up -d。
- /health OK；/workers 8/8 healthy；chat 200（q38fn）；虚拟模型 1 对多请求落点正确。
- /u/ 200（webui）；/a/ 200（管理台）；/_ui → 302 /u/；/_ui/admin → 302 /a/；/_ui/config GET 200。
- playwright 截图：/a/ 模型管理页（虚拟模型条目列表 + 编辑对话框打开态）、服务池、路由策略、日志页。
- 8801 全程不碰。

---

## 9. 执行结果（2026-10-05 落地实况）

**门禁锚点**：`/data/tmp/lr-gates/gates-20261005-190411.log` —— `GATE_TIER=full`、`KEEP_GOING=1`、
`SKIP_ENV=none`，末行 `== summary: 22 passed, 0 failed, 0 skipped (tier=full) ==`。本文与本仓各处
文档的模块行数与门禁计数一律以这份全绿日志为锚（AGENTS.md 硬规则 1）。契约随之从 650 项升到
**666 项 / 23 段**（`ui_fixed` 段 60 → 69：入口迁移新增 `/u/`、`/a/` 的 302 / 200 / 404 断言），
README 基线表同步。

### 9.1 实测计数（wc -l）

实测命令：

```bash
cd /home/aigc/ChatGPT/lua-router
find lualib -name '*.lua' | wc -l                  # → 75
find lualib -name '*.lua' | xargs wc -l | tail -1  # → 32419 total
for d in router config_store registry watcher gpu_load mesh observability policies; do
  wc -l lualib/resty/luarouter/$d/*.lua | tail -1
done
wc -l lualib/resty/luarouter/*.lua | tail -1       # 顶层 20 个文件 → 7435
git log --oneline -1                              # → 48b7f6a
```

结果：`lualib/` 75 个 .lua / 32 419 行，HEAD `48b7f6a`。按域展开（数字即上面命令的输出）：

| 域 | facade | 子模块数 | 子模块合计 | 设计书预算 |
|---|---:|---:|---:|---|
| router | 364 | 12 | 5858 | facade ≤400 ✓ |
| config_store | 132 | 10 | 4697 | facade ≤200 ✓ |
| registry | 169 | 7 | 3778 | facade ≤250 ✓ |
| watcher | 65 | 7 | 2541 | facade ≤200 ✓ |
| gpu_load | 80 | 6 | 2398 | facade ≤150 ✓ |
| mesh | 59 | 5 | 2552 | facade ≤200 ✓ |
| observability | 1318（写侧原语 + HELP 表 + 导出器同域） | 2 | 846 | 设计即如此 |
| policies（未拆） | — | 6 | 2314 | 不动 ✓ |

其余单文件：hash.lua 964 / policy.lua 901 / init.lua 547 / hb.lua 417 / config.lua 394 /
ui.lua 348 / httpc.lua 181（新增公共传输库）/ props.lua 225 / limit.lua 209 /
store_dispatcher.lua 328 / store_file.lua 227 / store_sqlite.lua 318 / store_postgres.lua 189。

拆分前后对照（同一 wc -l 口径，前值取自拆分前的 HEAD `90353e9`，全仓含 store_*）：
router 5692 → 364+5858，config_store 4465 → 132+4697，registry 3617 → 169+3778，
watcher 2470 → 65+2541，gpu_load 2361 → 80+2398，mesh 2525 → 59+2552，
observability 2101 → 1318+846。同一口径的全仓总量 25 文件 / 30 612 行 → 75 文件 / 32 419 行；
净增约 1800 行来自 facade 的 re-export 名册与各子模块的文件头注释，函数体逐字未动。

### 9.2 偏离记录（三条，均已落地并验证）

1. **`w_ui_entry`：`/_ui/` 静态「双活」而不是全量 302**。设计书 §5.3 的原口径是「`/_ui/` 前缀
   （非精确 API 别名）→ 302 到 `/u/` 对应路径」；落地改成 `conf/ui.conf` 里 `^~ /_ui/` 与 `^~ /u/`
   **两个 alias 静态块并存**（同一 `LMR_UI_DIR` 根，只差 alias 末段）。理由是当前 bundle 里有硬编码的
   `/_ui/...` 资源引用，全量 302 会让「改了壳没改 bundle」的部署直接白屏；双活把风险压成零，代价只是
   旧入口继续可用（已删的 `/_ui/logs.html` 等照样 404，契约钉住）。契约段同时断言
   「`/_ui/` serves the SPA」与「`/_ui/` static miss is 404」。
2. **`w_config2`：persistence 的越界读数落位**。`policy_revision` / `upstreams_revision` /
   `upstreams_reconcile_due` 这三枚 token 的读点按名册属 readers 域，实际落在
   `config_store/persistence.lua`——「同域纪律」优先于按名册分派：它们读的正是 persistence 拥有的那枚
   shdict 的伴生键，拆去 readers 会让第二个文件碰 shdict，破坏「全模块只有 persistence 碰
   shdict / 后端 / 文件 IO」这条硬边界（该文件头注已把这次越界写明）。
3. **`router/host.lua` 是设计书 §1 没有的新落点**。`cfg()` / `limit()` / `store()` 这三个「懒取一次、
   进程级缓存」的访问器原本是全体函数共享的上文，拆成 12 个子模块后需要公共落点。它是**内部模块**：
   facade 不 re-export、不进 `_M` 契约，只被子模块 require，缓存语义与原文件一致（同一进程同一份
   config / limiter / config_store 表）。

另有两处补齐值得记一笔：设计书说根挂载「已存在的 /props 不动」，实测根名从未注册过（只有
`/_ui/props` 与 `/u/props` 两个别名），于是 `conf/ui.conf` 补了 `location = /props`（与 `/properties`
同一 handler）；`router/pump.lua` 首轮漏 export `send_attempt` / `discard_body` / `read_response_body`
三个名字，`router/forward.lua` 加载期捕获 nil 导致转发一律 500，由 **contract 门**抓获并修在
`48b7f6a`——这条已升格为 agent-handover.md §3 纪律第 8 条：静态的逐字审计够不着加载期的 nil 捕获，
**接线完整性的最终判官是 contract / e2e 门**。

### 9.3 §7 发现登记：四条 backlog 本轮全部未修，复核仍在

| # | 登记项 | 复核证据（当前树） |
|---|---|---|
| 1 | `write_snapshot` 镜像写绕过 `store_dispatcher.mirror_to_file` → `mirror_failed` 指标永不增长 | 成立：`mirror_to_file` 全仓零调用点；`config_store/persistence.lua` 直接 `pcall(require, store_file)` 后调 `fmod.mirror(...)`（4 处），绕过了 dispatcher 里那两条 `note_save("mirror_failed")` |
| 2 | `LMR_MODEL_TOOL_USE` 不在 `ENV_NAMES` 名册 | 成立且比登记更硬：`config_store/snapshot.lua` 的 `cfg_from_env` 用 `CS_ENV.env("LMR_MODEL_TOOL_USE")` 现读，而 `config_store/env.lua` 的 `ENV_NAMES` 里没有这一枚；`capture_env` 只按名册抓、nginx 又把未登记的 env 从 worker 剥掉，所以这个 env 层在 worker 里恒为 nil（与 AGENTS.md 硬规则 11 同形） |
| 3 | `observability.record_worker_attempt` 全仓无调用点 | 成立：除 `observability.lua` 的函数定义与一条注释外无任何引用；attempt 口径仍只有 entry 半边 |
| 4 | gpu_load 五族指标不在 HELP 表 | 成立且**是六族**：`gpu_load/export.lua` 导出的 `lr_gpu_load`、`lr_gpu_load_pass_total`、`lr_gpu_load_failures_total`、`lr_gpu_load_unmatched_total`、`lr_gpu_load_workers`、`lr_gpu_load_power_per_card_workers` 都不在 `observability.lua` 的 HELP 权威表里（表里只有 `lr_gpu_load_power_*` 那六枚功率族），只出 TYPE 不出 HELP |

四条刻意留作 backlog：本轮验收口径是「对外行为零变化」，每一条动出去都是行为/口径变更
（#1 会让 `lr_config_store_saves_total{result="mirror_failed"}` 第一次开始增长，#2 会让一个从未生效的
env 忽然生效），必须单独走一轮门禁。

### 9.4 门禁与部署侧的配套改动

- 六个字符串锚点单测（test_integration / test_caps_routing / test_models_shape /
  test_models_advertise / test_effort_layers / test_profiles）改指新源码路径，锚点字符串逐字未动，
  35 个锚点实跑核对（`cea48f4`）。
- `e2e_policy_parity` 的 Rust 对照实例启动等待预算 90s → **240s**（`2feab96`）：并行门禁
  （`GATE_JOBS=6`）下 Rust 首轮健康周期实测 75–120s，90s 在机器忙时误红。
- `conf` 的 CORS 段注释同步 `/u/` `/a/` 预检覆盖面（`bfe558a`）。
- 真机验证只在 21.k:8802 上做（清单见 §8），镜像 `lua-router:8802-20261005-2`：容器内
  `resty/luarouter/router/` 与 `httpc.lua` 都在，即跑的是重构树。
- **生产尚未吃这版**：`/data/app/lua-router/docker-compose.yml` 钉的是
  `lua-router:8800-20261005-1`（构建于 13:19，早于本轮 17:29 之后的拆分 commit），实测该镜像内没有
  `router/` 等子模块目录，所以 235.t:8800 此刻跑的仍是**拆分前的树**；21.k:8801 同样未动
  （现有 tag 最新到 `8801-20261005-6`，与该 8800 tag 同一镜像 ID）。推 8800 / 8801 属于生产替换，
  按 AGENTS.md 须用户确认后另走一轮（构建新 tag → compose 换镜像 → 全量门禁/真机清单）。
