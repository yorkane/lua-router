# Agent 交接说明（lua-router）

> 写给接手本仓库的 agent：目标是用最少考古成本进入正确的工作状态。本文只写**当前事实**与**操作纪律**，
> 设计推导在 git 历史与保留文档里（§7 地图）。最后核对：2026-10-06（容量语义重设计后首份全量门禁
> **22/22 全绿**，锚点 `/data/tmp/lr-gates/gates-20261006-051452.log`，tier=full）。
>
> **本文引用代码的口径：文件 + 函数名，不钉行号。** 2026-10-05 把七个 2000+ 行的大文件拆成
> facade + 子模块，旧树里所有「文件:行号」引用随之全部漂移（同一个行号在拆分前后指向不同函数），
> 全部作废。这是本轮留下的教训，写进 §3。

## 0. 30 秒速览

lua-router 是 LLM 推理网关的 OpenResty/Lua 实现（原 Rust smg 的功能移植 + 裁剪 + 扩展）。当前形态：
**多 GPU 服务的服务发现与请求调度器**——8 策略选路、健康/熔断/限流、DP 展开、mesh HA、进程内 watcher
（原独立 llm-watcher 容器已合并退役）、GPU 负载双源 + 功率通道、路由策略热切换、token 核算、
虚拟模型＝**对下游暴露的服务主入口**、1 对多映射一组实际模型（`targets[]`，由调度策略在这一整组里选路；
条目级**只允许 `context_window`** 一个覆盖字段，per-alias `policy`/`effort` 已停用）、持久化 upstreams、
每服务并发/功率上限（候选集硬排除）、Quasar UMD 管理控制台（页面入口 **/a/**，原版 webui 入口 **/u/**，旧入口 302 过来；
管理台四页：**服务池**（运行态池 + 声明层同页，原「远程服务」页已并入）/ **模型管理** /
**路由策略** / **日志**）。

已删面（git 历史可恢复）：gRPC/PD、history 存储、tokenizer/parse 代理、网关鉴权（全开放）、K8s 发现、OTel。
TODO 不实现：wasm、MCP（doc/todo-deferred.md）。

基线（2026-10-06，树 HEAD `66a891f`）：**全量门禁 22/22 全绿 / 0 skipped**（tier=full，锚点
`/data/tmp/lr-gates/gates-20261006-051452.log`；含契约 **691 项 / 24 段**（新增 `caps` 段 25 项）、
`e2e_caps` **175 checks**、`test_caps_routing` **157 checks**、`test_gpu_load` **402 checks**）。代码：
**`lualib/` 75 个 Lua 文件 / 34 608 行**（七个域 = facade + 子模块，其余单文件；行数口径
`find lualib -name '*.lua' | xargs wc -l`），单测 13 个文件（门禁 luajit 12 + resty 4 口径）。
文档 29 份。仓库：github.com/yorkane/lua-router（public，main 直推）。

## 1. 仓库与生产

| 项 | 值 |
|---|---|
| 本机路径 | /home/aigc/ChatGPT/lua-router（独立 git 仓） |
| 生产实例 | 235.t 容器 `lua-router-8800`，主口 8800，metrics 29000，镜像 `lua-router:8800-20261005-1`（容器 running；**该 tag 构建于 13:19，早于本轮 17:29 之后的拆分 commit**，实测容器内无 `router/` 等子模块目录，即生产此刻跑的是**拆分前的树**，重构版尚未推 8800——本轮验证只在 21.k:8802 上做，见 doc/refactor-arch-2026-10-05.md §9.4） |
| 编排 | /data/app/lua-router/docker-compose.yml（host 网络、unless-stopped、watcher 全开、docker.sock ro 挂载、配置持久化 /data/app/lua-router/config） |
| 回滚 | `docker stop lua-router-8800 && docker start llm-router-8800`（Rust 版容器已停保留） |
| 隧道 | https://8800-235.ai-t.wtvdev.com 经 authz 登录墙；直连 http://10.252.25.235:8800 或本机 127.0.0.1:8800 无墙 |
| 信任边界 | 网关层**零鉴权**（auth 已删）：/workers、/_ui、/model-map 全开放，只许 authz 边缘之后/可信内网 |
| 勿碰 | authz 容器、SearXNG(8080)、qdrant-faces(6334 gRPC 口)、face-*/va-*/pg18/n8nc/resdown/wx-liushi-monitor 等生产容器 |

## 2. 代码地图

```
lualib/resty/luarouter/  75 个 .lua / 32 419 行（wc -l 实测）：七个域是「facade + 同名子目录」，
  其余仍是单文件。facade 只做 require + _M re-export（预登记 package.loaded 让子模块回指同一张表），
  对外契约 = facade 的 _M 名册，逐名保留（单测换桩、conf 的 *_by_lua、五方借用点都按原名取）。

  router.lua(364) facade：klib 路由表 build() + handle() + preflight + 全量 re-export
    router/candidates.lua(576)  热路径：policy_for + candidates_for 门序（健康→白名单/绑定→
        模型许可→容量硬排除→组门）+ group_key_name + group_policy_hint + card_key 族
    router/jsonutil.lua(1000)   顶层精确改写族 set_top_field / rewrite_model / merge_top_object
        / patch_response_metadata + DP rank 注入 + 路由文本抽取 + usage + SSE + 会话指纹
    router/forward.lua(850)     streaming 泵 + 重试环 + forward 主循环；转发名读 worker.lr_bound_model
        后交给 jsonutil.rewrite_model（整组一致拒绝的 503 文案「healthy engines serve none of the
        mapped models」也在这里）
    router/models_api.lua(969)  /v1/models 对外形状：models_handler / advertise_real_model /
        advertise_virtual_entry / fill_model_fields / inject_virtual_models / resolve_model_caps /
        common_acceptance / declared_context_limit（AGENTS.md 硬规则 9 全在此文件）
    router/inference.lua(526)   推理面（别名解析、effort 三层继承、output_budget_of 纯读、
        apply_ctx_cap / entry_ctx_cap 两条恒「无改写」空壳）+ 公开面 health 族
    router/profiles.lua(305)    config_store 之上的 profile 读层缝：profile_model_group +
        两条恒 nil 停用缝 profile_policy_name / profile_effort_value（刻意保留，不是死代码）
    router/pump.lua(189)        cosocket 泵：connect_target / read_response_head / send_attempt /
        discard_body / read_response_body（本轮漏 export 的三个名字就是它，见 §3 教训）
    router/respond.lua(318)     错误应答 / CORS / request id / 请求头与标签白名单
    router/metrics_ep.lua(430)  metrics 聚合渲染 + engine_metrics / model_info（load-safe）
    router/control.lua(483)     控制面 workers CRUD / flush_cache / v1/loads / model-map +
        观测与 mesh handler + server 级 preflight_guard
    router/reqlog.lua(167)      log_inference_request 组装一条 RequestRecord + finish_request 收尾
    router/host.lua(45)         进程级惰性访问器 cfg() / limit() / store()——不进导出契约
  config_store.lua(132) facade：require + 68 个导出逐名 re-export
    config_store/persistence.lua(540)  硬边界：全模块只有本文件碰 shdict / 后端 / 文件 IO
        （三层读写 + CAS 冲突 409 + persist + migrate_once + 四枚 revision token 读点）
    config_store/snapshot.lua(801)     空快照语义 + sync_virtual_view / new_card / snapshot_of /
        cfg_from_document / cfg_from_env + 配置期校验 validate_declared_context_windows
    config_store/profiles.lua(783)     组装配：build_target_group / target_group_of /
        build_context_window / profile_from_entry（停用的 per-alias policy/effort 各在此 warn 一次）
        + assert_no_alias_chain 别名链守卫；explicit_target / explicit_targets 旗标同在此文件
    config_store/upstreams.lua(563)    声明层校验脱敏 + upstream_drifts / patch / reconcile_upstreams
    config_store/readers.lua(542)      current / ctx_cap / virtual_ctx_cap / 模态 / policy 热路径读 /
        policy_document（入口名也进行集）/ effort 三层查表
    config_store/mutators.lua(452)     apply_* 家族 + 整表写 + profile_policy / profile_effort
        （活着的死 reader，热路径无调用者）
    config_store/handlers.lua(389)     watcher 桥 + document / models_document + 10 个 handle_config_*
    config_store/lexicon.lua(355)      helper、词表、JSON 形状小工具、对端模块惰性取用
    config_store/httpc.lua(155)        raw_request（唯一生产读者是 props 的 /props 代理）
    config_store/env.lua(117)          ENV_NAMES 名册 + capture_env / env + LMR_UPSTREAMS_FILE 种子
        （新 env 漏进这里 = 静默走未配置降级，AGENTS.md 硬规则 11）
  registry.lua(169) facade：把 keys/url/caps/records/health/loads/discovery + 公共 httpc 按原名 re-export
    registry/records.lua(1122)  规格解析 + models 助手族 + add/remove + 读出视图 + info +
        candidate_allows_model（组门的 fail-open 谓词）+ patch_record
    registry/discovery.lua(803) 探针与覆盖度 probe_advertised_entries / refresh_models / model_caps /
        record_model_caps（models_verified 那枚印章）+ PUT update + 元数据发现 + DP 展开 + 作业队列 + 种子
    registry/caps.lua(647)      上游能力采集（自包含纯域：model_caps_from_listing / from_entry / merge）
    registry/loads.lua(479)     负载折叠 + capacity_exclusion 每服务上限判定（lo:/pw: 两个读数；
        读数未知→不排除，set_power_w 拒收负值/NaN/±inf）
    registry/keys.lua(336)      lr_workers 键格局 + shdict 懒解析 + resty.lock + worker id + 名单 + mesh 写钩子
    registry/health.lua(273)    健康位与熔断（open→half_open 唯一恢复 CAS 在此，charge 用 incr、flip 锁内重查）
    registry/url.lua(118)       url 规范化与拨号助手
  httpc.lua(181)  本轮新增的公共传输库：cosocket 连接池 + HTTP 原语（自旧 registry 的 E 块提升）。
    只有 registry.lua require 它，其余五方借用点按原名经 registry 借，零改动。
  watcher.lua(65) facade
    watcher/reconcile.lua(575)  内部不许再拆：十条守卫的唯一判定点 + 探针分档摘除 + 单轮保险丝（§4）
    watcher/discover.lua(458)   三源发现纯层 + docker unix_get/collect；DENY_PORT 只在 proc 扫描分支
                                生效（就在 collect 的 deny 装配处），docker 分支不过它 → SMG_WATCHER_CONTAINER_IPS=0
    watcher/live.lua(437)       live 入口 + make_fetch/probe_pool + registry 适配 + run_pass/tick/start
    watcher/env.lua(415)        26 枚 SMG_WATCHER_* new_config + URL 规范化 + 自端口
    watcher/modelmap.lua(251)   model-map 解析 + effective_map/apply_model_map
    watcher/ledger.lua(229)     台账 new_ledger
    watcher/probe.lua(176)      严格探针 classify/probe_verdict 三档判定（分档语义逐行原样）
  gpu_load.lua(80) facade
    gpu_load/parse.lua(629)  exposition 解析族 · cards.lua(492) 卡归属与四路功率口径
    gpu_load/runpass.lua(526) run_pass 主循环（stats 字段口径单点定义）· seams.lua(305) 九枚 live seams
    gpu_load/parse.lua(765) 利用率解析（util_fraction 0..100→0..1 / util_by_card 逐卡归约）
    gpu_load/cards.lua(848) 四路利用率口径 assign_util（认不出卡回退整机 max 并计 lr_gpu_load_util_fallback_total）
    gpu_load/export.lua(304) 指标导出 + 定时器（三通道：负载 / 功率 pw: 纯观测 / 利用率 gu: 供 max_gpu_util）
    gpu_load/prom.lua(209)   Prom 客户端
  mesh.lua(59) facade
    mesh/crdt.lua(1368)  不拆：时钟/LWW/版本向量 + 成员表 + 分区检测 + observe_worker + 快照合并
                         （幻影键修复的正确性依赖这些同域）
    mesh/sync.lua(481)   cosocket http_request + sync_with + ROUTES/dispatch + SMG_MESH_* + 单例
    mesh/handlers.lua(425) /_mesh/internal/* 四条 + 13 条 /ha/* · wire.lua(151) 编解码 · rate.lua(127) 限流窗
  observability.lua(1318) facade：写侧原语（counter/observe/gauge + 键文法）+ record_* + HELP 权威表 +
    prometheus_text —— 与导出器同域不拆（键文法是隐式契约，契约门只测最终文本）
    observability/logstore.lua(600)  请求日志环形缓冲 + 查询 DSL + /_ui/logs 三 handler + stats()
    observability/inflight.lua(246)   在飞年龄 tracker（lr_stats 的 1024 定长槽）
  单文件（未拆）：hash.lua(964) BLAKE3 环位/ketama/粘滞键 · policy.lua(901) 策略分发（random/rr/pot/manual 内联）
    · init.lua(547) fork 前接线（env 快照 + hb/watcher/mesh/负载定时器 + on_log 兜底）
    · hb.lua(417) 健康巡检 + 熔断计数 + /v1/loads 扇出 + gpu_load 挂载点
    · config.lua(394) env→配置对象 · ui.lua(348) /_ui 与 /u 的 API 别名 handler 族
    · props.lua(225) /props 快照与引擎代理（with_ctx 是 ctx_cap——模型卡 ctx / 平铺 model_ctx——的
      唯一生产读者，只换回显的 n_ctx / n_ctx_train）
    · limit.lua(209) 全局并发闸门 + 排队 · store_*{dispatcher,file,sqlite,postgres} 配置后端
    · policies/（6 文件 2314 行）tree/cache_aware/bucket/consistent_hashing/prefix_hash + utils
  单测 test/unit/ 13 个文件：门禁跑 luajit 12（tree/policies/hash/mesh/watcher/gpu_load/routing_dyn/
  profiles/caps_routing/models_shape/models_advertise/effort_layers）+ resty 4（tree/policies/hash/
  integration），其中 tree/policies/hash 双口径各跑一次。

ui/                  原版 llama.cpp webui（规范入口 /u/）+ ui/admin/（Quasar UMD 管理台四页，
                     规范入口 /a/：模型管理/服务池/路由策略/日志；upstreams.html 只剩重定向占位，
                     服务池同页呈现运行态池 + 声明层，上限以声明为准、cap_owner==='declared' 的行
                     隐藏运行态编辑入口）。旧入口 /_ui 与 /_ui/admin/ 各 302 到新入口，
                     /_ui/* 精确 API 别名与 /_ui/ 静态双活保留（当前 bundle 硬编码不受影响）。
                     控件纪律：本仓 vendor 的 Quasar UMD 里 QToggle / QOptionGroup 不经 BaseField
                     渲染，实测 :hint 不生成 .q-field__bottom，toggle / option-group 的说明文字
                     只能并进 :label（声明对话框的两个 toggle 即按此实现）。
  admin-inject.js    向原版 webui 左导航注入 Admin 入口（href 绝对路径 /a/；MutationObserver 防抖
                     判重模式，别破坏；旧 Logs 入口随根目录工具页移除，差异见 doc/ui-trim-legacy-pages.md）
conf/                nginx.conf.template（生产模板，envsubst）+ lua-router.conf（裸部署字面量）+
                     ui.conf（/_ui 与 /u 的精确 API 别名 + /u/ 与 /a/ 静态 + 旧入口 302 + webui
                     根挂载九端点；exact "=" 纪律：前缀 location 会 shadow 同名静态文件）
docker-entrypoint.sh env 校验→envsubst→openresty -t→exec；cache_aware/mesh 时未显式给 worker 数则钉 1
```

## 3. 测试工作流（最重要，先读这节）

**纪律**：

1. 门禁/e2e/契约**绝不并发**（host 网络 + 容器命名；两套房同跑必出假失败）。跑之前 `ps` 查一遍。
2. luajit/resty 单测（docker run --rm，无端口绑定）可以并发。
3. 精确 kill PID，禁止 pkill；测试容器名带 `lr-<套件>-<pid5>` 前缀，收尾 `docker ps -a | grep lr-` 清零。
4. 临时产物一律 /data/tmp/；本仓代码改动每步一个 commit。
5. 改完先语法门（luajit -bl / openresty -t）再跑对应门禁子集，最后 root 全量。
6. 门禁验收只认 **0 skipped**：日志里出现 `SKIP_ENV` 就是假绿（历史上外部依赖门禁被 SKIP
   掩盖过 require 失败的先例）。
7. 两档门禁：缺省 quick（build/conf/unit/contract/probes，约 3 分钟）；发版、文档计数更新、
   生产镜像替换必须 GATE_TIER=full 全量绿——快速档日志不作全绿锚点。
8. **文档与代码的锚定纪律（2026-10-05 教训）**：引用代码一律「文件 + 函数名」，不钉行号。
   本轮把七个 2000+ 行文件拆成 facade + 子模块后，旧文档里 60 多处「文件:行号」全部漂移到
   错误的位置，只能按函数名重写。**拆分后跨模块接线遗漏**（`router/pump.lua` 漏 export
   `send_attempt` / `discard_body` / `read_response_body`，`router/forward.lua` 加载期捕获到 nil、
   转发一律 500）被 **contract 门**抓获（修复 `48b7f6a`）——静态的逐字审计够不着「模块表里少了
   一个名字」这类加载期缺陷，**contract/e2e 门是接线完整性的最终判官**：任何 facade + re-export
   形状的改动，验收必须落到真跑请求的门禁上，不能停在「逐字搬家核对通过」。

**命令**：

```bash
cd /home/aigc/ChatGPT/lua-router
bash test/final_gates.sh                     # 快速档（缺省 5 门，约 3 分钟）——普通修改够用
GATE_TIER=full bash test/final_gates.sh      # 全量 22 门（串行 13–14 分钟）——发版/计数/生产替换
GATE_ONLY=contract bash test/final_gates.sh  # 单门（不受档位限制）；GATE_ORDER 见脚本头
TEST_ONLY=inflight_age bash test/test_lua_router.sh   # 契约单段
```

**22 门**：build conf unit contract probes e2e_stateful e2e_policies e2e_ui_bridge e2e_errors
e2e_effort head_routes mesh_http e2e_policy_parity e2e_watcher e2e_token_accounting e2e_gpu_load
e2e_routing_dyn e2e_profiles e2e_caps e2e_models_advertisement mesh_two e2e_tls_chain。

门与门之间**已支持并行**：`GATE_TIER=full GATE_JOBS=6 bash test/final_gates.sh` 实测 6.5 分钟
（串行 13.7 分钟，2.12 倍）；**不设 `GATE_JOBS` 时行为与原来逐字节一致**。`GATE_DRY_RUN=1` 只打印
分组计划。新增门若未归入 pool-1 / pool-2 / serial-only，脚本 fail-closed 直接 `exit 2`——
`e2e_watcher`（拍 docker 端口快照再拼排除表）、`mesh_two`（名册跨 18s 稳定窗）、`e2e_tls_chain`
（硬编码 `SMG_PORT=31337`）这三门必须留串行，理由见 README〈测试〉。

**已知 flake/坑**：

- `e2e_policy_parity` 的 random χ² 检验有约 5% 假阳率（临界 5.991）——失败先看是不是贴线抖动，单独重跑该门即可。
- `e2e_policy_parity` 的 Rust 对照实例启动等待预算已 90s→**240s**（`2feab96`）：**并行门禁下
  （`GATE_JOBS=6`）Rust 首轮健康周期实测 75–120s**，90s 会在机器忙时误红。红之前先看日志里
  Rust 侧等待用了多久，再怀疑产品代码。
- 新写的 e2e 套件首跑大概率红（前提/解包类错误），不要怀疑产品代码，先核对场景前提。
- 生产机的 proc 扫描会把门禁轮的 mock（alpha/beta 等模型名）短暂注册进生产池：跑完门禁后清一次
  （`GET /workers` 找 unhealthy 的测试模型名 → `DELETE /workers/{id}`）。结构性根治（端口黑白名单策略）未做。
- watcher 探针读到「接受 TCP 后不回 HTTP」的口（qdrant gRPC 6334 类）会被 nginx 记 [error]；
  消音手段是 `SMG_WATCHER_DENY_PORT`（lua_socket_log_errors off 在 timer 阶段挡不住），机制见
  doc/gap-watcher-merge.md 偏差 13。
- 写 watcher 相关用例时记住 §4 的分档：**还在发现源里但 `/v1/models` 答不出 `data[].id`**（确定性否定）
  的实例会在下一轮（`SMG_WATCHER_INTERVAL_SECS`，缺省 15 s）被直接摘除，不等 grace；**连不上／无应答**
  （传输层未知）要连够 `SMG_WATCHER_PROBE_FAILURES`（缺省 2）轮才摘，中途成功即清零；**从发现源消失**才走
  `SMG_WATCHER_REMOVE_GRACE_SECS`(300)/`KEEP_LAST_GRACE_SECS`(1800)。探针摘除还受单轮保险丝（超过 owned
  一半则只 warn，`SMG_WATCHER_PROBE_FUSE=0` 关闭）约束，写「一批全摘」的用例时记得它。想让一个不答
  `/v1/models` 的 mock 留在池里测别的维度，得把它从发现源里摘掉（而不是让它继续被报出来），或置
  `SMG_WATCHER_ALLOW_REMOVE=0`（此时只警告一次、不删），见 gap-watcher-merge.md §1.1。

## 4. 设计红线（改动前必读）

- **推理体字节透传**：只允许 set_top_field 式顶层精确改写（model/stream_options/profile 收窄），不整表
  重编码；流式不缓冲（token 核算的 usage 帧剥除是唯一的帧级编辑，有 MAX_SSE_FRAME 上界）。
- **跨请求状态一律 shdict**（lr_workers/lr_policy/lr_stats/lr_request_log/lr_limit/lr_locks/lr_watch/
  luarouter_config）；进程内可变状态只许 cache_aware 树、bucket 计数、mesh 成员表（三者都已钉 worker=1 或有衰减文档）。
- **缺省零行为变化**：所有新开关（SMG_WATCHER_ENABLED、SMG_LOAD_SOURCE、policy 覆盖）缺省时对外行为
  与旧版逐字节一致，这是门禁判据的一部分。
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
  旧 `max_power_w` 已退役（读到 warn 一次并丢弃、`/workers` 不回显、判定不读），功率采集链 `pw:` 保留为
  **纯观测**（21.k 实测 8 台读数同值——整机最热卡口径，无法区分实例，这也是改用逐卡利用率的原因）。
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
- **探针失败分档，后果不同**（用户裁定 2026-10-01，改这块前先读；完整口径与表格见
  gap-watcher-merge.md §1.1，本节与它必须逐字同义）：
  - **转发路径上的探测**（hb 健康巡检、gpu_load 抓 /metrics 与远程 Prom）失败只损失精度——降级、keep-last、
    grace、纯在飞计数，绝不让监控故障拖垮转发，也不因单次探测失败摘 worker。健康判定本来就是
    连续失败到 failure_threshold 才翻健康位，翻位也只是退出选路，不删行。
  - **watcher 严格探针**（每轮 `classify()` 读 `GET /v1/models` 的 `data[].id`）按「对方到底答没答」分三档：
    - **确定性否定**——探针拨通并拿到了 HTTP 回答，但内容不合要求（读不出 `data[].id`、`/server_info`
      命中 router 自指纹、模型数超 `max_models`）：当轮立即 `release()`，跳过
      `SMG_WATCHER_REMOVE_GRACE_SECS`(300) 与 `SMG_WATCHER_KEEP_LAST_GRACE_SECS`(1800)。
    - **传输层未知**——连不上／超时／TLS 失败／接受 TCP 后无应答：计入该 owned 条目的连续失败数，
      达到 `SMG_WATCHER_PROBE_FAILURES`（缺省 2）才摘；未达阈值保留原行，任一轮成功即清零。
    - **不触发摘除**——`no probe transport`（网关自身缺 fetch）与 `require_health` 未通过（注册准入
      开关，不是摘除理由）：既不摘也不计数。
  - 两档摘除都受**单轮保险丝**约束：一次 reconcile 内被探针摘掉的 owned 条目超过 owned 总数一半时降级为
    只 warn 不摘（防网关自身故障一次清空全池），`SMG_WATCHER_PROBE_FUSE=0` 关闭。
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
# 构建 + 替换（当前树）：
cd /home/aigc/ChatGPT/lua-router && docker build -t lua-router:8800-$(date +%Y%m%d)-N -t lua-router:latest .
sed -i 's#lua-router:8800-[0-9-]*#lua-router:8800-YYYYMMDD-N#' /data/app/lua-router/docker-compose.yml
cd /data/app/lua-router && docker compose up -d --force-recreate
# 验证清单（全绿才算完）：
curl -s http://127.0.0.1:8800/health                       # OK
curl -s http://127.0.0.1:8800/workers                      # Q38 healthy，无测试残留
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8800/a/            # 200（管理台；旧 /_ui/admin/ 302）
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8800/u/             # 200（原版 webui；旧 /_ui 302）
curl -s http://127.0.0.1:8800/_ui/config/policy            # 生效链 JSON
# 一条真实流式 chat + 指标确认 tokens_total 增长；日志 grep '\[error\]' 应为 0
```

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
8. **功率三个 env 没进 config.lua/JSON/UI**（`SMG_LOAD_POWER` / `_KEYS` / `_QUERY` 由 gpu_load
   自己 `os.getenv`）：不可热改、进不了 `/_ui/config`，与 AGENTS.md 重点 3/4 的口径不符（收尾项）。
9. **虚拟模型 1 对多的残余缺口**（2026-10-02 本轮登记，口径见 doc/gap-virtual-models.md §9 与
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

## 7. 文档地图（doc/，28 份）

**现行权威**：README（入口）、architect.md（架构总览）、scope-trim.md（裁剪判定书+执行记录）、
agent-handover.md（本文）、todo-deferred.md（TODO 口径）、gap-mesh.md、gap-mesh-final.md、
gap-watcher-merge.md、gap-gpu-load.md、gap-routing-dyn.md、gap-token-accounting.md、
gap-inflight-age.md、gap-metrics-final.md、gap-tls-chain.md、gap-virtual-models.md、
gap-worker-caps.md（每服务并发/功率上限：候选集硬排除、最热卡口径、功率通道）、
gap-config-store.md（配置持久化：sqlite/postgres/file 三态后端、CAS、镜像与采纳）、
gap-session-2026-10-04.md（上下文窗口语义翻转、/v1/models 形状、effort 三层继承、per-GPU 功率、
以及这一轮踩过的坑——**接手前建议先读这一份**）、
refactor-arch-2026-10-05.md（**本轮 facade + 子模块拆分 + UI 入口迁移的执行契约与落地结果**，
含实测计数表与四条 backlog 登记）、
deploy-state.md（三实例部署现状、生效后端怎么查、已知配置漂移与死代码清单）、
ui-trim-legacy-pages.md（管理台相对原版 webui 的页面差异）、parity-cpu-ablation.md。

**对拍与真实评测（数据留档，引用前注意树龄）**：parity-contract/routing/policy-extra/perf-v2、
real-eval.md（prefix cache 97–99% 命中实证）。

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
