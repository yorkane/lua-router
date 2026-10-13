# Agent 交接说明（lua-router）

> 写给接手本仓库的 agent：目标是用最少考古成本进入正确的工作状态。本文只写**当前事实**与**操作纪律**，
> 设计推导在 git 历史与保留文档里（§7 文档索引指针）。最后核对：2026-10-12（管理面 Basic Auth 落地后首份全量门禁
> **22/22 全绿**，权威锚点 `/data/tmp/lr-gates/gates-20261012-164729.log`；同码并行轮 160634 逐门计数一致，
> tier=full，代码树 `69b5d53`）。
>
> **本文引用代码的口径：文件 + 函数名，不钉行号。** 2026-10-05 把七个 2000+ 行的大文件拆成
> facade + 子模块，旧树里所有「文件:行号」引用随之全部漂移（同一个行号在拆分前后指向不同函数），
> 全部作废。这是本轮留下的教训，写进 §3。

## 0. 30 秒速览

lua-router 是 LLM 推理网关的 OpenResty/Lua 实现（原 Rust smg 的功能移植 + 裁剪 + 扩展）。当前形态：
**多 GPU 服务的服务发现与请求调度器**——8 策略选路、健康/熔断/限流、DP 展开、mesh HA、进程内 watcher
（原独立 llm-watcher 容器已合并退役）、GPU 负载双源 + 利用率准入、路由策略热切换、token 核算、
虚拟模型＝**对下游暴露的服务主入口**、1 对多映射一组实际模型（`targets[]`，由调度策略在这一整组里选路；
条目级只允许**声明位**覆盖（`context_window` / `max_output_tokens` / `default_effort`+`effort_map` / `modalities` / `hidden` / `disabled` / `api_key`，清单见 doc/gap-virtual-models.md §2；per-alias `policy`/`effort` 已停用））、持久化 upstreams、
每服务并发/利用率上限（候选集硬排除）、Quasar UMD 管理控制台（页面入口 **/**（站点根，2026-10-08 admin 迁根），原版 webui 入口 **/u/**（不变）；旧入口 /a 与 /a/ 各 302 到 /，**/_ui/* 全部取消**；
管理台四页按使用频度：**模型管理**（虚拟模型入口页，最常用的配置）/ **服务池**（运行态池 + 声明层同页，原「远程服务」页已并入）/
**路由策略** / **日志**）。

已删面（git 历史可恢复）：gRPC/PD、history 存储、tokenizer/parse 代理、网关鉴权（全开放；
2026-10-12 起管理面加回 Basic Auth，见 doc/gap-admin-auth.md）、K8s 发现、OTel。
TODO 不实现：wasm、MCP（doc/todo-deferred.md）。

基线（2026-10-12，代码树 `69b5d53`；到 `ac2600c` 为止只动 doc/ 与 script/）：**全量门禁 22/22 全绿 / 0 skipped**
（tier=full，权威日志 `/data/tmp/lr-gates/gates-20261012-164729.log`，同码并行轮 160634 逐门计数一致；
含契约 **765 项 / 24 段**、`e2e_caps` **199 checks**、
`test_caps_routing` **157 checks**、`test_caps_persist` **150 checks**、`test_gpu_load` **489 checks**、
`e2e_models_advertisement` **262 checks**（S12 卡片档位勾选）、`test_models_shape` **146**、
`test_models_advertise` **74**、`test_profiles` **907**、`test_watcher` **461**、`test_admin_auth` **191**、
`test_effort_layers` **32**、`e2e_watcher` **125**、`e2e_profiles` **146**、`e2e_tls_chain` **112**）。

**代码规模与文档份数不在本文钉**（facade 拆分后每轮都在动，钉住就是下一轮的第一处过期）：
`find lualib -name "*.lua" | wc -l` / `find lualib -name "*.lua" | xargs wc -l` / `ls test/unit/`；
**文档面不靠计数**——README〈文档索引〉是唯一完整索引，用 `python3 script/check_docs_index.py` 双向比对（§7）；
七个域 = facade + 子模块，其余单文件。上面对数的那批 checks 与门禁日志同锚，才是本文的口径来源。
2026-10-12 一轮清理把六份**已完成任务书**与两组**已废止口径的 8802 取证截图**移出工作树
（`cap-put-ceiling-task` / `cap-put-test-task` / `efforts-maxtok-task` / `shadowing-core-task` /
`shadowing-test-task` / `shadowing-verify-task` 六份 .md，`verify-8802-20261003/` 两张、
`verify-8802-20261004-ctx/` 四张 PNG），需要时查 git 历史（`git log --diff-filter=D`）；
判据：任务书全部有落地 commit + 测试证据，指导价值已被代码与本文列出的现行规格吸收；
`verify-8802-20261004-ctx` 那组截图所证的「配置期校验」UI 已被用户裁定废止，留着主动误导。
保留在 `doc/` 的历史类文档不归档：parity-* / real-eval.md（数据留档）、`shadowing-2026-10-07.md`
（遮蔽裁定原文，现行判据的唯一出处）、两份 `deploy-*20261012-proxy-auth.md`
（生产回滚依据，fleet 记录吸收前暂留）。`effort-apikey-2026-10-11.md` 走的是另一条判据：五条最终裁定
**先并入 doc/docs-cleanup-2026-10-12.md §1.1 再移除**，引它时引并入后的那份。
仓库：github.com/yorkane/lua-router（public，main 直推）。

## 1. 仓库与生产

| 项 | 值 |
|---|---|
| 本机路径 | /home/aigc/ChatGPT/lua-router（独立 git 仓） |
| 生产实例 | 235.t 容器 `lua-router-8800`，主口 8800，metrics 29000，镜像 `…cr.aliyuncs.com/pub/lua-router:20261011-fc037af`（容器 running，StartedAt 2026-10-12T03:23Z）。镜像命名于 2026-10-12 起统一为 `pub/lua-router:YYYYMMDD-<短sha>`，发布脚本 `script/build-image.sh`（绿锚点直构建推 ACR）。fleet 现状（权威表 doc/deploy-state.md，2026-10-12 实测）：只有 21.k:8800（生产）与 21.k:8802（**测试**）滚到 `20261012-69b5d53` 并配了口令；21.k:8801（测试环境的并行旧实例，硬规则 3）、217.t:8800 与本机 235.t:8800（生产）仍在 `fc037af` / `89f0ad0`——那两版没有 `admin_auth.lua`，**配了口令也不生效**；顺序永远是 8802 测试通过才推生产；部署与回滚记录见 doc/deploy-8802-20261012-proxy-auth.md（测试）与 doc/deploy-8800prod-20261012-proxy-auth.md（生产） |
| 编排 | /data/app/lua-router/docker-compose.yml（host 网络、unless-stopped、watcher 全开、docker.sock ro 挂载、配置持久化 /data/app/lua-router/config） |
| 回滚 | `docker stop lua-router-8800 && docker start llm-router-8800`（Rust 版容器已停保留） |
| 隧道 | https://8800-235.ai-t.wtvdev.com 经 authz 登录墙；直连 http://10.252.25.235:8800 或本机 127.0.0.1:8800 无墙 |
| 信任边界 | 管理面（`/`、`*.html`、`/config*`、`/logs*`、`/stats`、`/slots`、`/tools`、`/u/config*` 九条别名，以及 klib 控制面 `/workers` `/model-map` `/flush_cache`）在配了 `SMG_ADMIN_AUTH_PASS` 时要 Basic 凭据（用户名恒 `lua-router`；loopback 直连免凭据，但请求里出现 `X-Real-IP`/`X-Forwarded-For`/`Forwarded` 任一头名就取消该豁免；未配/空串=整道门关闭，缺省零行为变化）。数据面 `/v1/*` 与公开面 `/health` `/metrics` `/v1/models` `/v1/loads` `/ha/*` `/_mesh/internal/*` 与 `/u/` 对话面**仍然开放**。完整口径见 doc/gap-admin-auth.md。只许 authz 边缘之后/可信内网 |
| 勿碰 | authz 容器、SearXNG(8080)、qdrant-faces(6334 gRPC 口)、face-*/va-*/pg18/n8nc/resdown/wx-liushi-monitor 等生产容器 |

## 2. 代码地图

```
lualib/resty/luarouter/  （文件数与行数现测：find lualib -name '*.lua' | xargs wc -l）：七个域是「facade + 同名子目录」，
  其余仍是单文件。facade 只做 require + _M re-export（预登记 package.loaded 让子模块回指同一张表），
  对外契约 = facade 的 _M 名册，逐名保留（单测换桩、conf 的 *_by_lua、五方借用点都按原名取）。

  router.lua(374) facade：klib 路由表 build() + handle() + preflight + 全量 re-export
    router/candidates.lua(847)  热路径：policy_for + candidates_for 门序（健康→白名单/绑定→
        模型许可→容量硬排除→组门）+ group_key_name + group_policy_hint + card_key 族
    router/jsonutil.lua(1000)   顶层精确改写族 set_top_field / rewrite_model / merge_top_object
        / patch_response_metadata + DP rank 注入 + 路由文本抽取 + usage + SSE + 会话指纹
    router/forward.lua(880)     streaming 泵 + 重试环 + forward 主循环；转发名读 worker.lr_bound_model
        后交给 jsonutil.rewrite_model（整组一致拒绝的 503 文案「healthy engines serve none of the
        mapped models」也在这里）
    router/models_api.lua(1599)  /v1/models 对外形状：models_handler / advertise_real_model /
        advertise_virtual_entry / fill_model_fields / inject_virtual_models / resolve_model_caps /
        common_acceptance / declared_max_output_tokens（AGENTS.md 硬规则 9 全在此文件）
    router/inference.lua(608)   推理面（别名解析、effort 三层继承、output_budget_of 纯读、
        apply_ctx_cap / entry_ctx_cap 两条恒「无改写」空壳）+ 公开面 health 族
    router/profiles.lua(305)    config_store 之上的 profile 读层缝：profile_model_group +
        两条恒 nil 停用缝 profile_policy_name / profile_effort_value（刻意保留，不是死代码）
    router/pump.lua(189)        cosocket 泵：connect_target / read_response_head / send_attempt /
        discard_body / read_response_body（本轮漏 export 的三个名字就是它，见 §3 教训）
    router/respond.lua(318)     错误应答 / CORS / request id / 请求头与标签白名单
    router/metrics_ep.lua(430)  metrics 聚合渲染 + engine_metrics / model_info（load-safe）
    router/control.lua(616)     控制面 workers CRUD / flush_cache / v1/loads / model-map +
        观测与 mesh handler + server 级 preflight_guard
    router/reqlog.lua(167)      log_inference_request 组装一条 RequestRecord + finish_request 收尾
    router/host.lua(45)         进程级惰性访问器 cfg() / limit() / store()——不进导出契约
  config_store.lua(165) facade：require + 逐名 re-export（导出面 79 枚，实测 grep -c '^_M.'；facade 头注释自述的 68 是拆分当时的数）
    config_store/persistence.lua(540)  硬边界：全模块只有本文件碰 shdict / 后端 / 文件 IO
        （三层读写 + CAS 冲突 409 + persist + migrate_once + 四枚 revision token 读点）
    config_store/snapshot.lua(936)     空快照语义 + sync_virtual_view / new_card / snapshot_of /
        cfg_from_document / cfg_from_env（原配置期校验 validate_declared_context_windows
        已于 2026-10-08 移除：声明窗口与单次输出预算是两个不可比的量，不再互校）
    config_store/profiles.lua(1216)    组装配：build_target_group / target_group_of /
        build_context_window / profile_from_entry（停用的 per-alias policy/effort 各在此 warn 一次）
        + assert_no_alias_chain 别名链守卫；explicit_target / explicit_targets 旗标同在此文件
    config_store/upstreams.lua(867)    声明层校验脱敏 + upstream_drifts / patch / reconcile_upstreams
    config_store/readers.lua(831)      current / ctx_cap / virtual_ctx_cap / 模态 / policy 热路径读 /
        policy_document（入口名也进行集）/ effort 三层查表
    config_store/mutators.lua(641)     apply_* 家族 + 整表写 + profile_policy / profile_effort
        （活着的死 reader，热路径无调用者）
    config_store/handlers.lua(522)     watcher 桥 + document / models_document + 10 个 handle_config_*
    config_store/lexicon.lua(440)      helper、词表、JSON 形状小工具、对端模块惰性取用
    config_store/httpc.lua(155)        raw_request（唯一生产读者是 props 的 /props 代理）
    config_store/env.lua(120)          ENV_NAMES 名册 + capture_env / env + LMR_UPSTREAMS_FILE 种子
        （新 env 漏进这里 = 静默走未配置降级，AGENTS.md 硬规则 11）
  registry.lua(173) facade：把 keys/url/caps/records/health/loads/discovery + 公共 httpc 按原名 re-export
    registry/records.lua(1138)  规格解析 + models 助手族 + add/remove + 读出视图 + info +
        candidate_allows_model（组门的 fail-open 谓词）+ patch_record
    registry/discovery.lua(833) 探针与覆盖度 probe_advertised_entries / refresh_models / model_caps /
        record_model_caps（models_verified 那枚印章）+ PUT update + 元数据发现 + DP 展开 + 作业队列 + 种子
    registry/caps.lua(647)      上游能力采集（自包含纯域：model_caps_from_listing / from_entry / merge）
    registry/loads.lua(708)     负载折叠 + capacity_exclusion 每服务上限判定（lo:/gu: 两个读数；
        读数未知→不排除，set_gpu_util 拒收负值/NaN/±inf）
    registry/keys.lua(346)      lr_workers 键格局 + shdict 懒解析 + resty.lock + worker id + 名单 + mesh 写钩子
                                + 临时禁用位 K_TEMP_DISABLE（`td:` 键，探针分档用，见 §4）
    registry/health.lua(273)    健康位与熔断（open→half_open 唯一恢复 CAS 在此，charge 用 incr、flip 锁内重查）
    registry/url.lua(118)       url 规范化与拨号助手
  httpc.lua(181)  本轮新增的公共传输库：cosocket 连接池 + HTTP 原语（自旧 registry 的 E 块提升）。
    只有 registry.lua require 它，其余五方借用点按原名经 registry 借，零改动。
  watcher.lua(65) facade
    watcher/reconcile.lua(938)  内部不许再拆：十条守卫的唯一判定点 + 探针分档摘除 + 单轮保险丝（§4）
    watcher/discover.lua(784)   三源发现纯层 + docker unix_get/collect；DENY_PORT 只在 proc 扫描分支
                                生效（就在 collect 的 deny 装配处），docker 分支不过它 → SMG_WATCHER_CONTAINER_IPS=0
    watcher/live.lua(690)       live 入口 + make_fetch/probe_pool + registry 适配 + run_pass/tick/start
    watcher/env.lua(519)        SMG_WATCHER_* new_config 名册（含 PROBE_TEMP_DISABLE）+ URL 规范化 + 自端口
    watcher/modelmap.lua(251)   model-map 解析 + effective_map/apply_model_map
    watcher/ledger.lua(229)     台账 new_ledger
    watcher/probe.lua(181)      严格探针 classify/probe_verdict 三档判定（分档语义逐行原样）
  gpu_load.lua(72) facade
    gpu_load/parse.lua(646)  exposition 解析族 + 利用率解析（util_fraction 0..100→0..1 /
        util_by_card 逐卡归约）· cards.lua(617) 卡归属与利用率折叠，含四路口径 assign_util
        （认不出卡回退整机 max 并计 lr_gpu_load_util_fallback_total）
    gpu_load/runpass.lua(637) run_pass 主循环（stats 字段口径单点定义）· seams.lua(325) 九枚 live seams
    gpu_load/export.lua(266) 指标导出 + 定时器（两通道：负载 xl: / 利用率 gu: 供 max_gpu_util）
    gpu_load/prom.lua(209)   Prom 客户端
  mesh.lua(59) facade
    mesh/crdt.lua(1368)  不拆：时钟/LWW/版本向量 + 成员表 + 分区检测 + observe_worker + 快照合并
                         （幻影键修复的正确性依赖这些同域）
    mesh/sync.lua(481)   cosocket http_request + sync_with + ROUTES/dispatch + SMG_MESH_* + 单例
    mesh/handlers.lua(425) /_mesh/internal/* 四条 + 13 条 /ha/* · wire.lua(151) 编解码 · rate.lua(127) 限流窗
  observability.lua(1448) facade：写侧原语（counter/observe/gauge + 键文法）+ record_* + HELP 权威表 +
    prometheus_text —— 与导出器同域不拆（键文法是隐式契约，契约门只测最终文本）
    observability/logstore.lua(600)  请求日志环形缓冲 + 查询 DSL + /logs 三 handler + stats()
    observability/inflight.lua(246)   在飞年龄 tracker（lr_stats 的 1024 定长槽）
  单文件（未拆）：admin_auth.lua(260) 管理面 Basic Auth（2026-10-12 用户裁定新增；password / is_loopback /
    has_proxy_origin_header / required / check_header / challenge / guard / guard_static /
    klib_challenge_worthy / guard_klib；口径见 §1 信任边界与 doc/gap-admin-auth.md）
    · hash.lua(964) BLAKE3 环位/ketama/粘滞键 · policy.lua(1138) 策略分发（random/rr/pot/manual 内联）
    · init.lua(547) fork 前接线（env 快照 + hb/watcher/mesh/负载定时器 + on_log 兜底）
    · hb.lua(431) 健康巡检 + 熔断计数 + /v1/loads 扇出 + gpu_load 挂载点
    · config.lua(457) env→配置对象 · ui.lua(356) 根数据面与 /u 的 API 别名 handler 族
    · props.lua(225) /props 快照与引擎代理（with_ctx 是 ctx_cap——模型卡 ctx / 平铺 model_ctx——的
      唯一生产读者，只换回显的 n_ctx / n_ctx_train）
    · limit.lua(209) 全局并发闸门 + 排队 · store_*{dispatcher,file,sqlite,postgres} 配置后端(328/227/318/189)
    · policies/（6 文件 2567 行）tree/cache_aware/bucket/consistent_hashing/prefix_hash + utils
  单测 test/unit/ 19 个 .lua + 1 个 .mjs：门禁跑 luajit 17（tree/tree_bounds/state_bounds/observability/
  policies/hash/mesh/watcher/gpu_load/routing_dyn/profiles/caps_persist/caps_routing/models_shape/
  models_advertise/effort_layers/admin_auth）+ resty 4（tree/policies/hash/integration，其中
  integration 125 检查，tree/policies/hash 与 luajit 口径双跑各一次）+ node 1
  （test/unit/test_ui_merge.mjs 128 检查，从盘上 html 抽真函数）。test_cb_stream.lua 不在门禁名单里。

ui/                  原版 llama.cpp webui（规范入口 /u/）+ ui/admin/（Quasar UMD 管理台四页，
                     规范入口 /（站点根，由 conf/nginx.conf.template 的 `location /` 提供，try_files 未命中回落
                     @lmr_klib 走 klib 路由表）：模型管理/服务池/路由策略/日志；upstreams.html 只剩重定向占位，
                     服务池同页呈现运行态池 + 声明层，上限以声明为准、cap_owner==='declared' 的行
                     隐藏运行态编辑入口）。旧入口 /a 与 /a/ 各 302 到 /（相对引用 + no-store）；
                     /_ui/* 全部取消：无 302、无别名、无静态块，落 404 sink（klib 路由表里残留的 /_ui/logs、
                     /_ui/stats、/_ui/logs/backends 三条注册也随 7e8bfff 一并删除，/ 之前那句「唯一例外」
                     已作废；三个 handler 本体仍在 observability.lua 导出，供根别名与单测按原名取用）。
                     管理台数据面在根上的
                     exact 别名族：/config* /logs* /stats /props。
                     控件纪律：本仓 vendor 的 Quasar UMD 里 QToggle / QOptionGroup 不经 BaseField
                     渲染，实测 :hint 不生成 .q-field__bottom，toggle / option-group 的说明文字
                     只能并进 :label（声明对话框的两个 toggle 即按此实现）。
  admin-inject.js    向原版 webui 左导航注入 Admin 入口（href 绝对路径 /；MutationObserver 防抖
                     判重模式，别破坏；旧 Logs 入口随根目录工具页移除，差异见 doc/ui-trim-legacy-pages.md）
conf/                nginx.conf.template（生产模板，envsubst）+ lua-router.conf（裸部署字面量）+
                     ui.conf（/u 的精确 API 别名 + /u/ 静态与 302 + /a、/a/ 兼容 302 + 管理台数据面的根
                     exact 别名族（/config* /logs* /stats）+ webui 根挂载九端点；exact `=` 纪律：
                     前缀 location 会 shadow 同名静态文件）
```

## 3. 测试工作流（最重要，先读这节）

**纪律**：

1. **门禁支持跨独立 run 并发（用户裁定 2026-10-12，推翻本条旧话「门禁/e2e/契约绝不并发」）**：隔离由实现提供——
   `prepare` 冻结源码快照 + 不可变镜像 manifest、每 run/每门命名空间、机器级端口台账、声明式资源锁；
   跑之前 `ps` 查一遍是了解现状，不是排队条件。口径与实测记录见 doc/testing-workflow.md。
2. luajit/resty/node 单测（无端口绑定）可并发；`e2e_watcher` 的 docker 名册经 `test/integration/docker_test_proxy.py`
   只读代理过滤，已进共享池（原 125 项断言不变）。
3. 精确 kill 自己拥有的 PID，禁止 pkill；清理只限本 run 名册记录的容器/文件/ledger 行（`lr-*` 前缀不变），
   **禁止全局 `lr-*` 清扫**——并发下那是最贵的误伤。收尾核对是**本 run 容器名册归零**（按注入的
   `LR_CONTAINER_NAMESPACE` / `LR_GATE_LABEL` 过滤），不是全机 `docker ps -a --filter name=lr-` 的计数：
   并发时别人的 run 也在用这个前缀，全机计数既判不了对错，也不许拿它当清理依据去删别人的容器。
4. 临时产物一律 /data/tmp/；本仓代码改动每步一个 commit。
5. 改完先过语法门（luajit -bl / openresty -t），再按改动面跑**最小相关门**（doc/testing-workflow.md §6 矩阵：
   UI 纯函数 → `GATE_GROUP=ui`；声明层 / config_store → config + base；路由与改写 → routing + `contract`；
   facade / re-export 这类跨组件接线 → 相关分组 + `contract`）。红了定位后只重跑受影响那一门（`GATE_ONLY=<门>`）。
   **full 不是日常动作**：只在发版、文档计数更新、生产镜像替换时跑（或由同 manifest 的分组聚合补齐）——
   每改一处就跑 full 是本轮点名的慢因。
6. **full 锚点只认 0 skipped**：发版锚里出现 `SKIP_ENV` 就是假绿（历史上外部依赖门禁被 SKIP 掩盖过
   require 失败的先例）。定向选择（如 `GATE_GROUP=ui`）会合法地把范围外的门记成 skip：它对自己的选择可以绿
   （`selection_green=True`），但那份记录不是 full 锚。底线是「记进报告」，问题只出现在静默消失。
7. 两档门禁：缺省 quick（build/conf/unit/contract/probes 五门，约 3 分钟）；发版、文档计数更新、
   生产镜像替换必须有 full 锚点：一次 `GATE_TIER=full` 全部 22 门绿，或由 `aggregate --tier full` 在同一
   manifest（同 fingerprint + 同 `image_id`/`authz_id`/`build_base_id`）下补齐 22 门且无 skip/missing/invalid 后判定等价。
   `--tier full` 不能省：`full_anchor_eligible` 只在 full 档判定，quick 档聚合 22 门齐也只报 False。
   快速档日志与定向绿（报告自带 `full_anchor_eligible=False`）都不作全绿锚点。
8. **文档与代码的锚定纪律（2026-10-05 教训）**：引用代码一律「文件 + 函数名」，不钉行号。
   本轮把七个 2000+ 行文件拆成 facade + 子模块后，旧文档里 60 多处「文件:行号」全部漂移到
   错误的位置，只能按函数名重写。**拆分后跨模块接线遗漏**（`router/pump.lua` 漏 export
   `send_attempt` / `discard_body` / `read_response_body`，`router/forward.lua` 加载期捕获到 nil、
   转发一律 500）被 **contract 门**抓获（修复 `48b7f6a`）——静态的逐字审计够不着「模块表里少了
   一个名字」这类加载期缺陷，**contract/e2e 门是接线完整性的最终判官**：任何 facade + re-export
   形状的改动，验收必须落到真跑请求的门禁上，不能停在「逐字搬家核对通过」。

**命令与可复制流程**：见 doc/testing-workflow.md（按维度选门、prepare/manifest、聚合与实测记录都在那）。速查：
```bash
bash test/final_gates.sh prepare --manifest-out /data/tmp/lr-gates/manifest-<fp>.json   # 冻结一次，多 agent 共用一份 manifest
bash test/final_gates.sh                                    # 快速档（缺省五门）
GATE_TIER=full bash test/final_gates.sh                     # 全量 22 门（池宽缺省 min(8,CPU)）
GATE_TIER=full GATE_GROUP=routing bash test/final_gates.sh  # 按维度选门（base/config/routing/observability/discovery/mesh/tls/ui）
GATE_JOBS=1 bash test/final_gates.sh                        # 显式串行（复现只在串行下出现的红）
bash test/final_gates.sh plan                               # 只打印选择/锁/依赖，不执行
GATE_ONLY=contract bash test/final_gates.sh  # 单门（不受档位限制）；GATE_ORDER 见脚本头
TEST_ONLY=inflight_age bash test/test_lua_router.sh   # 契约单段
```
分组并发跑完后，发版口径用聚合判定（`--tier full` 不能省：`full_anchor_eligible` 只在 full 档判定；`--manifest` 用 build 之后的身份文件，判据见 doc/testing-workflow.md §5）：
```bash
bash test/final_gates.sh aggregate --tier full \
  --manifest /data/tmp/lr-gates/manifest-<fp>.json \
  --results "/data/tmp/lr-gates/runs/<run-A>/results /data/tmp/lr-gates/runs/<run-B>/results"
```

**22 门**：build conf unit contract probes e2e_stateful e2e_policies e2e_ui_bridge e2e_errors
e2e_effort head_routes mesh_http e2e_policy_parity e2e_watcher e2e_token_accounting e2e_gpu_load
e2e_routing_dyn e2e_profiles e2e_caps e2e_models_advertisement mesh_two e2e_tls_chain。

并发模型（2026-10-12 改写，取代旧的三段波次表 + 串行尾巴 + 「三门必须串行」）：池宽缺省 `min(8, CPU)`，只按依赖边调度——`conf`/`unit`/`contract`/`probes` 不等镜像构建，boot 镜像的套件等的是 **build 门**（依赖边）不是栅栏；锁按声明取（HTTP 门共享观测窗 `obs:shared`，构建取独立准备锁 `build:exclusive`，`e2e_watcher` 声明零锁）。旧串行三门的理由已各自消解：`e2e_watcher` 读的是 `docker_test_proxy.py` 过滤后的名册（原 125 项断言不变，实测见 doc/testing-workflow.md §7）；`mesh_two` 的 Lua mesh 是静态对端表、无 gossip 发现，外来 router 结构上进不了名册，18 秒稳定断言原样保留；`e2e_tls_chain` 的 31337 是 `openresty -t` 渲染场景、从不绑定，端口号在台账里持续规避。
新增门在 `test/gates/catalog.py` 声明 group/tier/locks/depends/timeout，未归类则加载期 assert
直接失败——fail-closed 的纪律没变，只是从脚本里的三档表变成 catalog 的必填字段。

**已知 flake/坑**：

- `e2e_policy_parity` 的 **χ² 已从判据降为报告项**（AGENTS.md 硬规则 10）：拟合优度检验的
  `E[χ²] = df`，公式里没有样本量，`P(χ² > 5.991) = 5.00%` 与 N 无关——α=0.05 等于每轮全量门禁自带
  约 5% 的红概率预算，**加大 N 一分不减**（实测 N=240→4800 稳定在 4.9%–5.1%）。现行判据是
  **TOST 等价性检验**（`e2e_policy_parity.py` 的 `tost_uniform`），等价边界 `d=0.065`
  （`LR_PP_TOST_D`，N=1200；按「实测到过的最差真实行为」定，不是按统计最优——d=0.055 在实测最差行为上
  仍红 4.4%，发版门禁不能接受），random 轮用 `LR_PP_TOST_D_RANDOM=0.008`。TOST 的软肋是**过散**
  （β-binomial ρ）：iid 下假红 3.8e-10，但 ρ=0.01 时 N=1200 上红率升到 0.17，所以它红了先怀疑环节流漂移，
  **加大 N 只会更糟**，对策是放宽 d。配套纪律：单侧阈值同样要标定，`Rust with-loads` 旧的
  `share < 0.30` 在 N=240 下放过真退化 0.187（约 1/5），等于没检——新增或调阈值前先算尾概率。
- `e2e_policy_parity` 的 Rust 对照实例启动等待预算已 90s→**240s**（`2feab96`）：**并行门禁下
  （`GATE_JOBS=6`）Rust 首轮健康周期实测 75–120s**，90s 会在机器忙时误红。红之前先看日志里
  Rust 侧等待用了多久，再怀疑产品代码。
- 新写的 e2e 套件首跑大概率红（前提/解包类错误），不要怀疑产品代码，先核对场景前提。
- 生产机的 proc 扫描会把门禁轮的 mock（alpha/beta 等模型名）短暂注册进生产池。清理事件属于生产写面，
  按 AGENTS.md 硬规则 3 逐条判（不在本文给出口头命令）。结构性根治（端口黑白名单策略）未做。
- watcher 探针读到「接受 TCP 后不回 HTTP」的口（qdrant gRPC 6334 类）会被 nginx 记 [error]；
  消音手段是 `SMG_WATCHER_DENY_PORT`（lua_socket_log_errors off 在 timer 阶段挡不住），机制见
  doc/gap-watcher-merge.md 偏差 13。
- 写 watcher 相关用例时记住 §4 的分档：**还在发现源里但 `/v1/models` 答不出 `data[].id`**（确定性否定）
  的实例会在下一轮（`SMG_WATCHER_INTERVAL_SECS`，缺省 15 s）被临时禁用——退出选路、registry 行保留，
  不等 grace（2026-10-09 起默认不物理删行，`SMG_WATCHER_PROBE_TEMP_DISABLE=0` 才退回当轮删行）；
  **连不上／无应答**（传输层未知）要连够 `SMG_WATCHER_PROBE_FAILURES`（缺省 2）轮才摘，中途成功即清零；
  **从发现源消失**才走 `SMG_WATCHER_REMOVE_GRACE_SECS`(300)/`KEEP_LAST_GRACE_SECS`(1800)。物理摘除还受单轮
  保险丝（超过 owned 一半则只 warn，`SMG_WATCHER_PROBE_FUSE=0` 关闭）约束——临时禁用不计入保险丝——
  写「一批全摘」的用例时记得它。想让一个不答 `/v1/models` 的 mock 留在池里测别的维度，得把它从发现源里
  摘掉（而不是让它继续被报出来），或置 `SMG_WATCHER_ALLOW_REMOVE=0`（此时只警告一次、不删），
  见 gap-watcher-merge.md §1.1。

## 4. 设计红线（改动前必读）

- **推理体字节透传**：只允许 set_top_field 式顶层精确改写（model/stream_options/profile 收窄），不整表
  重编码；流式不缓冲（token 核算的 usage 帧剥除是唯一的帧级编辑，有 MAX_SSE_FRAME 上界）。
- **跨请求状态一律 shdict**（lr_workers/lr_policy/lr_stats/lr_request_log/lr_limit/lr_locks/lr_watch/
  luarouter_config）；进程内可变状态只许 cache_aware 树、bucket 计数、mesh 成员表（三者都已钉 worker=1 或有衰减文档）。
- **缺省零行为变化**：所有新开关（SMG_WATCHER_ENABLED、SMG_LOAD_SOURCE、policy 覆盖）缺省时对外行为
  与旧版逐字节一致，这是门禁判据的一部分。
- **管理面这道门的覆盖面必须等于它声称的范围**（用户裁定 2026-10-12，改这块前读 doc/gap-admin-auth.md）：
  首版只挂根数据面，留下两个绕过洞——`/u/config*` 是同一批 handler 的别名族（匿名可写同一份配置）、
  klib 控制面 `/workers` 匿名可改运行态名册。**门的覆盖面小于声称范围 = 门形同虚设**，两族现在都进门。
  三个挂点各司其职，少一个就是洞：`guard()` 挂在 `conf/ui.conf` 的 24 条 exact location（前缀 location 会
  shadow 同名静态文件，exact 纪律不破）；`guard_static()` 挂 `location /`（access 阶段跑在 try_files 之前，
  整块一拦会把本该由 `@lmr_klib` 回答的 `/v1/*` `/health` `/metrics` 一起锁死，所以只对 `/` 与 `*.html` 发挑战，
  浏览器拿到 401 后会对同源后续请求带凭据，js/css 这类无秘密资源放行不减弱保护）；`guard_klib()` 是
  `router.lua` 的 `handle()` 里**单点**挂（逐 handler 挂要动 15 个注册点、漏一条就是一个洞，而且挂不到
  OPTIONS 短路之后——预检从不带凭据，预检过门会把跨域管理台整体变成 401）。
  klib 清单刻意 **fail-open**（默认放行、名单内才拦），判据是后果不对称：数据面/公开面被误拦 = 推理流量与
  监控当场断，管理面漏拦 = 多一条匿名路。所以**新增受管路径要在 `KLIB_ADMIN_PREFIXES` 显式添一行**，
  `/metrics` `/v1/loads` `/ha/*` `/_mesh/internal/*` `/wasm*` 与 404 sink 是名单外的既定成员（抓取必须匿名、
  健康链 hb 逐秒读 `/v1/loads`、节点间 401 会被记成对端故障）。前缀匹配带斜杠边界（`/workersfoo` 不拦）。
  代理来源前置否决按**头名出现与否**判定，**值一概不解析**：`X-Real-IP`/`X-Forwarded-For`/`Forwarded`
  的语义是「上一跳说了算」，而 nginx 层没有 `set_real_ip_from` 受信网段保证那一跳写了什么；一旦去解析值，
  就得回答「信哪条头、XFF 取哪段、畸形算不算、重复头取哪个」，每个答案都是新的绕过面（`-H 'X-Real-IP: 127.0.0.1'`
  在按值还原的实现里直接拿到豁免，这就是被推翻的 v1）。要让经反代的本机操作员继续匿名，正确做法是在反代剥头
  或用受信网段 realip，把信任决策留在唯一知道链路的那一层，不是在网关里解析代理头。
  401 的信息量必须为零：非 Basic/解不开/缺分隔/用户名错/密码错同一个 401，比对走常量时间；realm 是不带秘密的
  文案位。口令只走 env（`SMG_ADMIN_AUTH_PASS`），三份 conf 的 `env` 白名单必须同步登记（与硬规则 11-3 同一条纪律，
  漏登记的现象是「配了但静默不生效」）。
  **接线完整性只有清单断言拦得住**：`test_admin_auth.lua` 逐行扫 `conf/ui.conf` 钉 24 条 guard 挂载，
  判定函数全对但漏挂一条 location 正是洞 1 的成因；六段变异反证（删口令豁免/删 loopback 豁免/空串当口令/
  klib 清单摘掉 `/workers`/去掉斜杠边界/换成数据面前缀）必须红。
- **每服务容量是「三态 + 候选集层面的硬排除」，并且「读数未知 → 不排除」**（用户裁定 2026-10-01 立基，
  2026-10-06 重设计为三字段三态）：worker 记录上的 `min_concurrency`（下限，缺席=1）/ `max_concurrency`
  （上限，≤32）/ `max_gpu_util`（GPU 利用率上限 0..100，**0 是最严档不是清除**）。`registry.capacity_state`
  一处判 `idle`（在飞<下限）/ `busy` / `full`（在飞≥上限 **或** 新鲜 `gu:`≥利用率上限）/ nil（三门全缺席
  =无门）。`capacity_exclusion` 只对 full 命中，在 `router.candidates_for` 组门+绑定之后**硬排除**，
  **即使 cache_aware 的亲和命中也照样迁走**（`policies/` 零改动）。不许把它实现成策略里的负载打分项：
  亲和命中按 URL 直取 tenant、完全不看负载，打分挪不走它想挪的流量。
  **绿灯优先**：有 idle 候选时黄灯让位（子集裁剪，非排除，计 `smg_worker_capacity_preferred_idle_total`）；
  全池都 ≥ 下限时黄灯可继续接直到触达上限——这正是「让 GPU 更均衡」的落点。它**不摘 worker、不改健康位与
  熔断状态**——这是「这一轮不给它派活」，不是「它坏了」。另一半地基是**读数未知时绝不排除**：`gu:`
  缺席=「未知」而非 0，采不到就什么都不写、靠 TTL 过期回到 nil，**绝不写 0、绝不沿用上一次旧值**。
  理由与下面的探针红线同源：监控系统挂掉的代价只能是精度，不能是容量。
  **全池都到顶时答 429**（用户裁定 2026-10-06，取代 2026-10-01 的 503 口径）：`error.code` 仍是
  `no_available_workers`、`error.type` 为 `Too Many Requests`、message 精确为
  「No available workers (N at their concurrency or GPU-util limit)」——容量到顶是「暂时不接单」不是
  「服务不可用」。熔断/不健康/组不服务仍 503 原句，两者处置相反（抬上限 vs 查实例）。
  旧 `max_power_w` 已退役（读到 warn 一次并丢弃、`/workers` 不回显、判定不读），功率通道 2026-10-09 已
  整体移除（用户裁定；21.k 实测 8 台读数同值——整机最热卡口径，无法区分实例，这也是改用逐卡利用率的原因）。
  完整口径见 [gap-worker-caps.md](gap-worker-caps.md)。
- **GPU 归属标注是纯 label，不许借它改路由身份**（2026-10-06 新增）：watcher 从**容器名**
  （`q38fn-pennyroyal-gpu3` → gpu=3）或**进程启动参数**（`--device-id N` / `CUDA_VISIBLE_DEVICES=N`）
  解析卡号，补进 `labels.gpu`，经 `/workers` 的 `metadata.gpu` 回显，管理台据此画 GPU 徽章。
  三条纪律：① 守卫 3（首接触快照）保护下的 worker **只补 labels.gpu 这一个键**，绝不改 URL /
  model_id / 健康位 / 熔断 / 优先级 / DP 展开 / 容量字段——那些是操作员与环境声明过的东西；
  ② 已有值绝不覆盖（docker 容器名优先于进程参数）；③ **刻意不跟 `policy.bump_generation()`**——
  `labels.gpu` 不进任何选路输入，而 bump 会让下一次 select 走整表重建亲和树，一台八实例的机器会因
  八次「补个卡号」丢掉学到的前缀亲和。**采集失败一律降级为无标注**（不抛错、不影响发现/探针/摘除）。
  21.k 实测：8 台 env 播种 + 守卫 3 保护的实例，一轮 tick 内全部补齐 gpu0..gpu7。
- **per-alias `policy` / `effort` 停用是刻意的兼容行为，不要当 bug 修**（用户裁定 2026-10-02，虚拟模型语义反转）：
  这两个字段**仍被接受、仍往返落盘、解析时 warn**（`config_store/profiles.lua` 的 `profile_from_entry` 里各一条 warn），
  但**热路径一律不读**——为的是旧文档导出再导入仍然通过校验，同时不让一行没人删的字段继续执行一条
  已经退役的规则。`router/profiles.lua` 的 `profile_policy_name` 与 `profile_effort_value`
  这两个**恒返回 nil** 的函数是有意保留的命名接缝（`router/candidates.lua` 的 `policy_for` 每请求都调它们），不许顺手删掉、
  也不许把它们改回读字段：别名级覆盖一旦回来，整组就会按落点模型裂成多棵亲和树。
  **反向陷阱**：facade 上的 `_M.profile_policy` / `_M.profile_effort`（实现住在 `config_store/mutators.lua`）这两个 store
  reader 还活着、还能返回别名上写的值，但**热路径已无调用者**（只剩单测在钉它们不驱动转发），
  属活着的死代码——看到它们还在就以为别名级覆盖生效，是最容易犯的误判。
  「给这个入口换策略」唯一的路是 `model_policies` 按**入口名**配（入口名因此也进 `config_store/readers.lua` 的
  `policy_document`）；effort 归模型卡（按落点模型名），ctx 归条目级 `context_window`。
- **转发体的 model 恒为选中候选的绑定名**（用户裁定 2026-10-02）：`lr_bound_model` 是唯一合法的转发名
  来源（`router/forward.lua` 的 `forward` 里读 `worker.lr_bound_model`，写进转发体是同函数的
  `rewrite_model(raw_body, bound or worker.model_id)`，改写函数住在 `router/jsonutil.lua`；
  同函数写的 `ngx.ctx.lr_forwarded_model` 只是日志字段——由 `router/reqlog.lua` 的
  `log_inference_request` 取用——不参与任何转发决策）。组模式下 `record.model_id` 被盖成**入口名**
  （`router/candidates.lua` 的 `candidates_for` 组分支）只服务策略分桶，**绝不许拿它当转发名**——
  那等于向引擎发一个它不认识的虚拟名。同理 `router/inference.lua` 的 `entry_ctx_cap` 与
  `apply_ctx_cap` 的第四参是「条目级优先且独占」：条目说话时不再叠加按落点模型的卡（两者现为恒
  「无改写」空壳，见 AGENTS.md 裁定块）；`config_store/readers.lua` 的 `ctx_cap` 对虚拟名本身恒返回
  nil，防的就是条目名泄漏进卡路径。
- **探针失败分档，后果不同**（用户裁定 2026-10-01 立基，2026-10-09 commit `9bf3c07` 改了 reject 档的后果；
  改这块前先读；完整口径与表格见 gap-watcher-merge.md §1.1，本节与它必须逐字同义）：
  - **转发路径上的探测**（hb 健康巡检、gpu_load 抓 /metrics 与远程 Prom）失败只损失精度——降级、keep-last、
    grace、纯在飞计数，绝不让监控故障拖垮转发，也不因单次探测失败摘 worker。健康判定本来就是
    连续失败到 failure_threshold 才翻健康位，翻位也只是退出选路，不删行。
  - **watcher 严格探针**（每轮 `classify()` 读 `GET /v1/models` 的 `data[].id`）按「对方到底答没答」分三档：
    - **确定性否定（reject 档）**——探针拨通并拿到了 HTTP 回答，但内容不合要求（读不出 `data[].id`、
      `/server_info` 命中 router 自指纹、模型数超 `max_models`）：**默认不再物理删行，改为临时禁用保行**。
      registry 行原样留着，只写 `td:` 键（`registry/keys.lua` 的 `K_TEMP_DISABLE`，TTL = 3×interval），
      `router/candidates.lua` 在候选装配时排除它，探针恢复轮显式 `clear_temp_disable` 立刻回池；
      每轮 warn 一次（`entry.warned` 静音），**不进保险丝计数**（它永不删行）。
      开关 `SMG_WATCHER_PROBE_TEMP_DISABLE=0` 退回旧的「当轮立即 `release()`、跳过
      `SMG_WATCHER_REMOVE_GRACE_SECS`(300) 与 `SMG_WATCHER_KEEP_LAST_GRACE_SECS`(1800)」。
      新指标 `smg_worker_temp_disabled_total`。同轮还落了一条「禁用即摘」：条目带 `disabled` 的已注册行
      走同一个 `release()` 出口退出池子。
      物理摘除自此只留两个信号：发现源不再报它（走守卫 5/6 的 grace + keep-last）与传输层未知累计到阈值。
      AGENTS.md 硬规则 4 的该行已按本口径同步（2026-10-12），两份话术一致。
    - **传输层未知**——连不上／超时／TLS 失败／接受 TCP 后无应答：计入该 owned 条目的连续失败数，
      达到 `SMG_WATCHER_PROBE_FAILURES`（缺省 2）才摘；未达阈值保留原行，任一轮成功即清零。
    - **不触发摘除**——`no probe transport`（网关自身缺 fetch）与 `require_health` 未通过（注册准入
      开关，不是摘除理由）：既不摘也不计数。
  - 两档物理摘除（发现源消失走 grace + keep-last、传输层未知累计到阈值）都受**单轮保险丝**约束：一次
    reconcile 内被探针摘掉的 owned 条目超过 owned 总数一半时降级为只 warn 不摘（防网关自身故障一次清空
    全池），`SMG_WATCHER_PROBE_FUSE=0` 关闭。临时禁用档不计入保险丝。
  - 都不放宽原有守卫：config upstream 与守卫 3 首接触快照的 protected 条目仍不由 watcher 删除，
    `SMG_WATCHER_ALLOW_REMOVE=false` 时只警告一次、不删。恢复无旁路：下一轮读到真实 `data[].id` 就按新
    服务同一套门槛重新注册，但 `registry.add` 会重置健康位与外部负载读数，重新接流要等
    `health_success_threshold` 个巡检周期。
  - 关键区分是**「探针失败」≠「发现源消失」**：本轮仍被发现源报告、探针也执行了，才谈得上上面三档；
    发现源不再报它（进程停、容器删）走的是 remove-grace + keep-last 宽限，以免短暂重启清空服务池。
    注意 `/metrics` 与 `/health` 双 5xx 那条判据归「传输层未知」而不是确定性否定：vLLM／llama.cpp 的身份
    标签正来自 `/metrics` 正文，`/metrics` 一 5xx 引擎就退回 `openai` 而使判据成立，健康引擎也会被说服。
- **生产 worker 池清理**：删 worker 走 DELETE /workers/{id}；watcher 会自动重发现仍在监听的（这是设计）。
- **镜像约束**：authz 基础镜像没有 `resty.http`（也没有 python3/perl），转发 / 健康检查 / watcher
  全部手写 cosocket，新代码不要 `require "resty.http"`；shdict 无原子 cas，「检查再翻转」的路径
  （熔断 state、registry 整表写）必须在 `resty.lock` 内重读后再写——charge 用 `shdict:incr`
  原子累加、flip 在锁内重查 expect，跨进程恰好记一次 transition。
- **随机数**：`math.randomseed` 只能在 worker_init 按 pid 混入；init_by_lua 播种会让全部 worker
  同序列（random / power_of_two 每轮同步选同一目标）。
- **cjson / shdict 纪律**：空数组必须显式 `cjson.empty_array`（改全局 array_mt 污染整进程）；
  直方图桶预填 0、读取侧 `tonumber`（`cjson.null` 参与算术会崩）；shdict 写满会静默 LRU
  驱逐旧键（计数漂移、不报错），容量按业务上限给。

## 5. 生产操作清单

```bash
# 构建（现行发布路径）：script/build-image.sh——要求 HEAD 是绿锚点且已跟踪文件干净，
# 标签 YYYYMMDD-<短sha>，推 ACR pub/，收尾 manifest inspect 自检。
cd /home/aigc/ChatGPT/lua-router && script/build-image.sh
docker pull <上面输出的镜像名>   # 或本机直接 build
sed -i 's#pub/lua-router:[0-9a-z-]*#pub/lua-router:YYYYMMDD-<短sha>#' /data/app/lua-router/docker-compose.yml
cd /data/app/lua-router && docker compose up -d --force-recreate
# 验证清单（全绿才算完）：
curl -s http://127.0.0.1:8800/health                       # OK
curl -s http://127.0.0.1:8800/workers                      # Q38 healthy，无测试残留
# /workers 与 /config/policy 两条：配了 SMG_ADMIN_AUTH_PASS 的实例要带 -u lua-router:<pass>；
# 直连 127.0.0.1 且请求里不带 X-Real-IP / X-Forwarded-For / Forwarded 任一头名才免凭据。
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8800/               # 200（管理台，admin 在根；旧 /a/ 302）
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8800/u/             # 200（原版 webui，入口不变）
curl -s http://127.0.0.1:8800/config/policy                # 生效链 JSON（数据面在根）
# 一条真实流式 chat + 指标确认 tokens_total 增长；日志 grep '\[error\]' 应为 0
# 切换前后各读一次 revision，相等 = 配置零漂移。
```

**切换前必做的两条取证**（21.k:8800 生产实测的形状，2026-10-12；细节见 doc/deploy-8800prod-20261012-proxy-auth.md）：

1. **备份要能恢复**。compose 与 `config/` 整目录拷进带时间戳的 `backup-<UTC>/`。配置权威是 **db**（`LMR_CONFIG_FILE` 是只读镜像，硬规则 11-1），所以要导 **WAL 安全的一致性快照**，不要直接 cp 活动库：用 `python3` 的 `sqlite3.Connection.backup()` 从活动库导出，导完 `PRAGMA integrity_check` 必须 ok。WAL 模式下 cp 出来的 `.db` 不是事务一致的：只能当证据，不能当恢复源。恢复时覆盖 `runtime.json.db*` 三件套再重建容器。
2. **先确认验的是 db 不是文件降级**：`/metrics` 上必须见到 `lr_config_store_backend{backend="sqlite"} 1`（硬规则 11 的「另」条）。升级窗口内不做任何配置写操作——CAS 409 在 reload 期会变成噪声源。切换前后各读一次 `GET /config` 的 `revision`，相等 = 配置零漂移。

**管理面口令的三条运维事实**（用户裁定 2026-10-12，口径 doc/gap-admin-auth.md）：

1. 21.k:8800/8802 现在跑的是**测试口令**。正式化 = 在 compose 里改 `SMG_ADMIN_AUTH_PASS` 的值后 `docker compose up -d`。口令值不落文档、不进配置 db（只走 env 是刻意的：`/config` 那份 JSON 可以被读出来广播）。
2. **经反代访问管理台不再匿名**，这是修复的目的不是副作用：21.k 的域名链路（APISIX → `127.0.0.1:880x`）实测写 `X-Real-IP` / `X-Forwarded-For`，前置否决据此收回 loopback 豁免。要给本机操作员留匿名，正确做法是在反代剥这三个头（APISIX `proxy-rewrite`）或用受信网段 realip，**不是在网关里解析代理头**。
3. 浏览器验证的已知现象（**非网关缺陷**）：凭据嵌在页面 URL 里时，页面内相对 `fetch("/config")` 被浏览器拒（URL 带凭据不可构造），侧栏显示「网关不可达」；弹框输凭据与 `curl -u` 两条正常路径都 200。playwright 无头环境弹不了凭据框，看到 `ERR_INVALID_AUTH_CREDENTIALS` 是 401 挑战到达浏览器的证据，不是渲染故障。

**fleet 对齐的顺序与风险**（2026-10-12 只读评估的结论，别重做一遍）：只为拿这道门而升级生产**不划算**——未配口令时整道门关闭，升级只带来 UI 与 `/v1/models` 形状的回归面。要滚 fleet 就一起滚：顺序是 **8802 测试通过才推生产**，验证矩阵按 doc/deploy-8800prod-20261012-proxy-auth.md 逐行复刻（匿名面不缩水 + `OPTIONS` 预检 200 + 伪造来源头 401 是硬三项）。**唯一真实的下游兼容风险是还有客户端拿 `owned_by` 判别入口行/真实行**（硬规则 9③ 已禁止该用法）。**没有等价替代判别位**：`created==0` 不是入口的充分判据（真实行无上游读数时也是 0），要判入口只能按 id 查声明层 `/config` 的 `virtual_models` 名册。旧 tag 保留在同机与 ACR，回滚是一条 sed 换镜像行 + `compose up -d`，秒级；回滚到无此功能的旧镜像时顺手删掉 `SMG_ADMIN_AUTH_PASS` 行（留着无害，按原样回滚）。

## 6. 活跃缺口与后续方向（按优先级）

1. **CPU 回退消融**：非流式每请求 CPU 约为出厂 1.54x，已定责（P1 请求日志行容量 0 仍整行构建 +
   P2 worker 记录表每请求 shdict 重建 5 次 ≈45–65%），动手前必须先跑 doc/parity-cpu-ablation.md §8 的
   R0 重测（1.54x 量于旧树，当前树更贵）。
2. **TLS 入口预检**：证书/私钥不配对与缺中间证书时 openresty -t 放行、握手才失败（gap-tls-chain §5/§6 有路线）。
3. **mTLS** 客户端证书鉴权未实现。
4. **watcher 扫描污染根治**：proc 扫描需要端口黑白名单策略（或 GPU 负载门禁标签）以区分测试 mock。
5. **UI 会话历史页**：history 平面已删，原版 webui 里的会话页需要下次 UI 升级时摘除。
6. **GPU↔worker 映射靠 host**：同机独立多卡会共享读数（gap-gpu-load.md §限制）。
7. **每服务上限的两个残余缺口**（gap-worker-caps.md §8）：① **mesh 集群视图不同步** ——
   `mesh.observe_worker` 只镜像 `{worker_id, model_id, url, health, load}`，`models` /
   `models_verified` 与两个上限都不过去，对端 `GET /ha/workers` 看不见，上限因此是**每网关独立**；
   ② **`disable_health_check` 的 worker 永不获得引擎背书** —— 它不进 discover，因此永不经
   `registry.refresh_models`，`models_verified` 不会为真，要多模型绑定只能靠 config 行显式声明
   `models`（只是备注，不构成否决依据）。另有一处前后端断点：`registry/records.lua` 的 `info()` 不输出
   `models_verified`，`GET /workers` 因此拿不到它，管理台的「引擎已验证」徽章与
   `ui/admin/models.html` 的已验证计数恒不生效（后端补一个字段即通）。
8. **虚拟模型 1 对多的残余缺口**（2026-10-02 本轮登记，口径见 doc/gap-virtual-models.md §9 与
   doc/gap-pool-merge.md §6）：
   ① **组里某个模型没有任何已验证实例时，落到它的请求 503**——组门用的是 registry 的 fail-open
      谓词 `registry/records.lua` 的 `candidate_allows_model`，没被探过的行允许进候选；但一旦某行已盖章
      （`models_verified`）且列表不含该名就会被拒，全组都不含时整入口 503，文案点名
      `healthy engines serve none of the mapped models`（`router/forward.lua` 的 `forward`）。要预防只能靠注册侧
      强制 `/v1/models` 背书（watcher 纪律），网关不做二次猜测。
   ② **入口名可以与被映射的真实模型名同名**：后端只拒「组里出现另一个别名」（`config_store/profiles.lua` 的 `assert_no_alias_chain`
      + 同文件 `build_profiles` 的逐名检查），同名由
      `ui/admin/models.html` 本地拦、后端不拦。后果是给其中一个配 per-model 覆盖时只命中入口名那一行，
      语义正确但容易看错。
   ③ **`disable_health_check` 的 worker 永不获得引擎背书**——它不进 discover，因此永不经
      `registry.refresh_models`，`models_verified` 不会为真；这类行要多模型绑定只能靠 config 行显式声明
      `models`，而 `models` 只是备注、**不构成组门的判据**（组门只认 `candidate_allows_model` 的三档回答）。
   ④ **`LMR_VIRTUAL_MODELS` env 未扩展多 target 语法**（`config_store/snapshot.lua` 的
      `cfg_from_env` 只能生成单元素组）：
      `alias=target` 逗号对无法无歧义表达多值，宁可不提供也不静默忽略；env 用户要 1 对多只能走
      `LMR_CONFIG_FILE`。
   ⑤ **`GET /workers` 仍不输出 `models_verified`**（`registry/records.lua` 的 `info()` 缺该字段）：
      管理台的「引擎已验证」徽章与 `ui/admin/models.html` 的已验证计数恒不生效，后端补一个字段即通
      （与 §6.7 同一处断点，组模式下更影响预览的可信度）。
   ⑥ **mesh 不镜像组信息**：`mesh/crdt.lua` 的 `observe_worker` 仍只镜像
      `{worker_id, model_id, url, health, load}`，`models` / 两个上限 / 组与入口信息都不过去，
      入口与上限因此都是**每网关独立**，多网关下同一入口的可见性不一致。

## 7. 文档索引

本仓 **唯一完整的文档索引在 README〈文档索引〉**（一份表覆盖全部 `doc/*.md`，逐份一行），本节不维护逐份清单、不钉份数，只做指针：新增/移动文档只改 README 那一处，改完跑
`python3 script/check_docs_index.py`（逐份枚举 `doc/*.md`，漏收即退出 1；README 表内目标文件不存在同样
退出 1），不靠计数对计数。

下面两段是索引表承载不了的信息：粗粒度主题指针（**不是清单，逐份以 README 表为准**）与清理史。

**按任务取文档**：调度与容量 → gap-worker-caps / gap-gpu-load / gap-routing-dyn / gap-effort-ladder；
入口与请求改写 → gap-virtual-models / gap-session-2026-10-04；配置持久化 → gap-config-store；
管理面鉴权 → gap-admin-auth；发现与探针 → gap-watcher-merge / gap-watcher-deny-21k；
集群与观测 → gap-mesh / gap-mesh-final / gap-metrics-final / gap-token-accounting / gap-inflight-age；
TLS → gap-tls-chain；发布与运维 → deploy-state / deploy-fleet / operations-lessons-20261012
与本轮清理记录 docs-cleanup-2026-10-12（**已移除文档的逐份落地 commit 与现行口径去处**见其 §1 表，
2026-10-11 那五条 api-key 与能力字段裁定的并入文本见其 §1.1）；对拍数据 → parity-* / real-eval.md（引用前注意树龄）。

**历史留档已清理（2026-10-01）**：裁剪前平面的 26 份文档（feature-gap、verification-*、impl-*、
fix-majors、wasm-feasibility、parity-perf v1 与已删平面的 gap-*）已随文档精简删除，需要时查
git 历史；仍生效的结论已折进 README / architect / todo-deferred。恢复已删平面走 git revert
对应 trim commit，不要在 main 上重写。

## 8. 环境事实（235.t）

- 真实上游验证服务：https://llm-248.ai-t.wtvdev.com/v1（APISIX 边缘 + SGLang；文档里写作
  <real-upstream-host>）；公共视觉模型 http://10.252.25.217:8800/v1。
- 公共 Redis 10.252.25.241:6379 与本仓无关（history 平面已删）；test/local.env 机制保留为通用本地覆盖。
- gh 已登录 yorkane（repo scope），push 用 https 到 GitHub；镜像不推远端仓库（本机使用）。
- 子智能体 provider 偶发半截返回/无声停止：交付验收以**盘上文件 + 日志证据**为准，别信口头进度。
- 本机有多用户裸 openresty 进程是**容器内进程**（宿主 ps 可见，cwd 读不到属正常），别误杀。
- llm-watcher 独立容器已退役（Exited，保留镜像可回滚）；它的原仓库在 /home/aigc/ChatGPT/llm-router/watcher/。
- authz 镜像无 python3/perl：要在容器里跑脚本时先落盘再 `docker exec`；`mock_llm_worker.py`
  复用连接会吞 ~44ms 级延迟，测流式延迟必须每次新建连接（对拍轮实测教训）。
