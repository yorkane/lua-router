# Agent 交接说明（lua-router）

> 写给接手本仓库的 agent：目标是用最少考古成本进入正确的工作状态。本文只写**当前事实**与**操作纪律**，
> 设计推导在 git 历史与保留文档里（§7 地图）。最后核对：2026-10-01（契约 650/23 段，
> 全量门禁日志锚点见 README 基线节）。

## 0. 30 秒速览

lua-router 是 LLM 推理网关的 OpenResty/Lua 实现（原 Rust smg 的功能移植 + 裁剪 + 扩展）。当前形态：
**多 GPU 服务的服务发现与请求调度器**——8 策略选路、健康/熔断/限流、DP 展开、mesh HA、进程内 watcher
（原独立 llm-watcher 容器已合并退役）、GPU 负载双源 + 功率通道、路由策略热切换、token 核算、
虚拟模型＝**对下游暴露的服务主入口**、1 对多映射一组实际模型（`targets[]`，由调度策略在这一整组里选路；
条目级**只允许 `context_window`** 一个覆盖字段，per-alias `policy`/`effort` 已停用）、持久化 upstreams、
每服务并发/功率上限（候选集硬排除）、Quasar UMD 管理控制台（/_ui/admin/：**服务池**（运行态池 + 声明层同页，
原「远程服务」页已并入）/ **模型管理** / **路由策略** / **日志**）。

已删面（git 历史可恢复）：gRPC/PD、history 存储、tokenizer/parse 代理、网关鉴权（全开放）、K8s 发现、OTel。
TODO 不实现：wasm、MCP（doc/todo-deferred.md）。

基线（2026-10-01）：**21 门禁全绿**（含契约 650/23 段）、Lua 24 417 行 / 15 个模块 + policies/6 文件、
单测 10 文件、文档 20 份。仓库：github.com/yorkane/lua-router（public，main 直推）。

## 1. 仓库与生产

| 项 | 值 |
|---|---|
| 本机路径 | /home/aigc/ChatGPT/lua-router（独立 git 仓） |
| 生产实例 | 235.t 容器 `lua-router-8800`，主口 8800，metrics 29000，镜像 `lua-router:8800-20261001-5` |
| 编排 | /data/app/lua-router/docker-compose.yml（host 网络、unless-stopped、watcher 全开、docker.sock ro 挂载、配置持久化 /data/app/lua-router/config） |
| 回滚 | `docker stop lua-router-8800 && docker start llm-router-8800`（Rust 版容器已停保留） |
| 隧道 | https://8800-235.ai-t.wtvdev.com 经 authz 登录墙；直连 http://10.252.25.235:8800 或本机 127.0.0.1:8800 无墙 |
| 信任边界 | 网关层**零鉴权**（auth 已删）：/workers、/_ui、/model-map 全开放，只许 authz 边缘之后/可信内网 |
| 勿碰 | authz 容器、SearXNG(8080)、qdrant-faces(6334 gRPC 口)、face-*/va-*/pg18/n8nc/resdown/wx-liushi-monitor 等生产容器 |

## 2. 代码地图

```
lualib/resty/luarouter/  15 模块 + policies/（6 个复杂策略文件；random/rr/pot/manual 内联 policy.lua）
  router.lua(4722)   入口总装：klib.router 分发、转发泵、重试、熔断、指标/_ui/mesh/model-map 挂载
                     组门 candidates_for(router.lua:1723)：组条目改问「这一组里有没有你能服务的」，IGW 那道门让位
                     （router.lua:1693 的 `and not group`）；**一入口一棵树**——策略实例 key 用入口名
                     （policy_for 的组分支 router.lua:284-293 + group_key_name router.lua:1549），组候选盖
                     record.model_id=入口名（router.lua:1775）只服务策略分桶，转发名另存 lr_bound_model
  init.lua           fork 前接线：env 快照、hb/watcher/mesh/负载定时器（worker0 + lr_locks 单飞）、on_log 兜底
  registry.lua       worker 注册表（lr_workers shdict）、健康态、DP 展开、负载字段折叠
                     新增：每服务上限判定 capacity_exclusion（lo:/pw: 两个读数）+ models/models_verified 覆盖度
  watcher.lua(~2.2k 行，描述性)  进程内服务发现：targets/docker/proc 三源、严格 /v1/models 探针、
                     十条守卫（1-9 移植自 Python 守护进程；第 10 条=探针按分档摘除不可用条目，
                     见 §4 与 gap-watcher-merge.md §1.1）、ledger、model-map
  gpu_load.lua(1721) GPU 负载源：worker /metrics 抓取 + 远程 Prom 查询，写 registry 负载字段
                     第三条通道：同一轮顺带采回绝对瓦特写 pw:（只服务 max_power_w，不参与打分）
  policy.lua+policies/  8 策略；cache_aware=亲和树+负载逃逸（per-process 树，多 worker 亲和率衰减）
  hb.lua             健康巡检 + 熔断计数 + /v1/loads 扇出 + gpu_load 定时器挂载点
  config_store.lua   热配置：虚拟模型/upstreams/effort/ctx/policy（LMR_CONFIG_FILE 原子落盘+shdict）
                     虚拟模型条目主字段 targets:["A","B"]（1 对多，build_target_group config_store.lua:491）
                     + 唯一覆盖字段 context_window（config_store.lua:555）；派生组三档回退=显式 targets >
                     单值 target > 各 candidates 的去重模型名（target_group_of config_store.lua:527，target 恒首位）；
                     explicit_target/explicit_targets（config_store.lua:719/:723）决定快照只回写操作员写过的字段；
                     **virtual_models 已降级为从 virtual_profiles 派生的只读视图**（sync_virtual_view
                     config_store.lua:1144，写过 targets 的条目代表值取组头）；LMR_VIRTUAL_MODELS env 只能生成
                     单元素组（config_store.lua:1212）；upstreams 可声明 max_concurrency/max_power_w/models
  observability.lua  Prometheus 家族渲染、请求日志环形缓冲（/_ui/logs 源）、inflight 年龄槽表
  mesh.lua(2525)     HA gossip（用户裁定保留；/_mesh/internal/* 无鉴权=信任边界=网络）
  limit.lua / hash.lua / ui.lua / props.lua / config.lua
ui/                  原版 llama.cpp webui（/_ui/）+ ui/admin/（Quasar UMD 管理台四页，中英双语：
                     模型管理/服务池/路由策略/日志；upstreams.html 只剩重定向占位，服务池同页呈现
                     运行态池 + 声明层，上限以声明为准、cap_owner==='declared' 的行隐藏运行态编辑入口）
  admin-inject.js    向原版 webui 左导航注入 Admin 入口（MutationObserver 防抖判重模式，别破坏；
                     旧 Logs 入口随根目录工具页移除，差异记录见 doc/ui-trim-legacy-pages.md）
conf/                nginx.conf.template（生产模板，envsubst）+ lua-router.conf（裸部署字面量）+ ui.conf
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

**命令**：

```bash
cd /home/aigc/ChatGPT/lua-router
bash test/final_gates.sh                     # 快速档（缺省 5 门，约 3 分钟）——普通修改够用
GATE_TIER=full bash test/final_gates.sh      # 全量 21 门（串行 12–17 分钟）——发版/计数/生产替换
GATE_ONLY=contract bash test/final_gates.sh  # 单门（不受档位限制）；GATE_ORDER 见脚本头
TEST_ONLY=inflight_age bash test/test_lua_router.sh   # 契约单段
```

**21 门**：build conf unit contract probes e2e_stateful e2e_policies e2e_ui_bridge e2e_errors
e2e_effort head_routes mesh_http e2e_policy_parity e2e_watcher e2e_token_accounting e2e_gpu_load
e2e_routing_dyn e2e_profiles e2e_caps mesh_two e2e_tls_chain。

**已知 flake/坑**：

- `e2e_policy_parity` 的 random χ² 检验有约 5% 假阳率（临界 5.991）——失败先看是不是贴线抖动，单独重跑该门即可。
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
- **每服务上限是「候选集层面的硬排除」，并且「读数未知 → 不排除」**（用户裁定 2026-10-01，新增的安全性地基）：
  worker 记录上的 `max_concurrency` / `max_power_w` 到顶时该 worker 必须**从候选数组里剔除**，
  **即使 cache_aware 的亲和命中也照样迁走**（判定在 `registry.capacity_exclusion`，接入在
  `router.candidates_for`、`policy:select` 之前，`policies/` 零改动）。不许把它实现成策略里的一个负载
  打分项：亲和命中按 URL 直取 tenant、完全不看负载，打分挪不走它想挪的流量。它同时**不摘 worker、
  不改健康位与熔断状态**——这是「这一轮不给它派活」，不是「它坏了」。另一半地基是**功率读数未知时
  绝不排除**：`pw:` 缺席=「未知」而非 0，`set_power_w` 拒收负值/NaN/±inf，采不到就什么都不写、靠 TTL
  过期回到 nil，**绝不写 0、绝不沿用上一次旧值**。理由与下面的探针红线同源：监控系统挂掉的代价只能是
  精度，不能是容量。全场都在上限上时 fail-closed 503 `no_available_workers` 不放宽（只给 message 加一个
  「N at their configured concurrency/power cap」从句，让操作员分清「池子空了」与「池子满了」）。
  完整口径见 [gap-worker-caps.md](gap-worker-caps.md) §1–§3。
- **per-alias `policy` / `effort` 停用是刻意的兼容行为，不要当 bug 修**（用户裁定 2026-10-02，虚拟模型语义反转）：
  这两个字段**仍被接受、仍往返落盘、解析时 warn**（`config_store.lua:754` / `:774` 各一条 warn），
  但**热路径一律不读**——为的是旧文档导出再导入仍然通过校验，同时不让一行没人删的字段继续执行一条
  已经退役的规则。`profile_policy_name`（`router.lua:782`）与 `profile_effort_value`（`router.lua:828`）
  这两个**恒返回 nil** 的函数是有意保留的命名接缝（`policy_for` 每请求都调它们），不许顺手删掉、
  也不许把它们改回读字段：别名级覆盖一旦回来，整组就会按落点模型裂成多棵亲和树。
  **反向陷阱**：`_M.profile_policy` / `_M.profile_effort`（`config_store.lua:2325` / `:2341`）这两个 store
  reader 还活着、还能返回别名上写的值，但**热路径已无调用者**（只剩单测在钉它们不驱动转发），
  属活着的死代码——看到它们还在就以为别名级覆盖生效，是最容易犯的误判。
  「给这个入口换策略」唯一的路是 `model_policies` 按**入口名**配（入口名因此也进 `policy_document`，
  `config_store.lua:1991`）；effort 归模型卡（按落点模型名），ctx 归条目级 `context_window`。
- **转发体的 model 恒为选中候选的绑定名**（用户裁定 2026-10-02）：`lr_bound_model` 是唯一合法的转发名
  来源（读 `router.lua:2915`，写进转发体在 `router.lua:2926` 的 `rewrite_model(raw_body, bound or worker.model_id)`；
  `router.lua:2931` 的 `ngx.ctx.lr_forwarded_model` 只是日志字段，不参与任何转发决策）。组模式下 `record.model_id` 被盖成**入口名**
  （`router.lua:1775`）只服务策略分桶，**绝不许拿它当转发名**——那等于向引擎发一个它不认识的虚拟名。
  同理 `entry_ctx_cap`（`router.lua:3203`）与 `apply_ctx_cap` 的第四参（`router.lua:3228`）是「条目级优先且
  独占」：条目说话时不再叠加按落点模型的卡；`_M.ctx_cap`（`config_store.lua:1795`）对虚拟名本身恒返回 nil，
  防的就是条目名泄漏进卡路径。
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
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8800/_ui/admin/   # 200
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
   `models`（只是备注，不构成否决依据）。另有一处前后端断点：`registry.info()` 不输出
   `models_verified`，`GET /workers` 因此拿不到它，管理台的「引擎已验证」徽章与
   `ui/admin/models.html` 的已验证计数恒不生效（后端补一个字段即通）。
8. **功率三个 env 没进 config.lua/JSON/UI**（`SMG_LOAD_POWER` / `_KEYS` / `_QUERY` 由 gpu_load
   自己 `os.getenv`）：不可热改、进不了 `/_ui/config`，与 AGENTS.md 重点 3/4 的口径不符（收尾项）。
9. **虚拟模型 1 对多的残余缺口**（2026-10-02 本轮登记，口径见 doc/gap-virtual-models.md §9 与
   doc/gap-pool-merge.md §6）：
   ① **组里某个模型没有任何已验证实例时，落到它的请求 503**——组门用的是 registry 的 fail-open
      谓词 `candidate_allows_model`（`registry.lua:1413`），没被探过的行允许进候选；但一旦某行已盖章
      （`models_verified`）且列表不含该名就会被拒，全组都不含时整入口 503，文案点名
      `healthy engines serve none of the mapped models`（`router.lua:2892-2903`）。要预防只能靠注册侧
      强制 `/v1/models` 背书（watcher 纪律），网关不做二次猜测。
   ② **入口名可以与被映射的真实模型名同名**：后端只拒「组里出现另一个别名」（`assert_no_alias_chain`
      `config_store.lua:842` + `build_profiles` 的逐名检查 `config_store.lua:827-835`），同名由
      `ui/admin/models.html` 本地拦、后端不拦。后果是给其中一个配 per-model 覆盖时只命中入口名那一行，
      语义正确但容易看错。
   ③ **`disable_health_check` 的 worker 永不获得引擎背书**——它不进 discover，因此永不经
      `registry.refresh_models`，`models_verified` 不会为真；这类行要多模型绑定只能靠 config 行显式声明
      `models`，而 `models` 只是备注、**不构成组门的判据**（组门只认 `candidate_allows_model` 的三档回答）。
   ④ **`LMR_VIRTUAL_MODELS` env 未扩展多 target 语法**（`config_store.lua:1212` 只能生成单元素组）：
      `alias=target` 逗号对无法无歧义表达多值，宁可不提供也不静默忽略；env 用户要 1 对多只能走
      `LMR_CONFIG_FILE`。
   ⑤ **`GET /workers` 仍不输出 `models_verified`**（`registry.info()` `registry.lua:1058` 缺该字段）：
      管理台的「引擎已验证」徽章与 `ui/admin/models.html` 的已验证计数恒不生效，后端补一个字段即通
      （与 §6.7 同一处断点，组模式下更影响预览的可信度）。
   ⑥ **mesh 不镜像组信息**：`mesh.observe_worker`（`mesh.lua:1214`）仍只镜像
      `{worker_id, model_id, url, health, load}`，`models` / 两个上限 / 组与入口信息都不过去，
      入口与上限因此都是**每网关独立**，多网关下同一入口的可见性不一致。

## 7. 文档地图（doc/，22 份）

**现行权威**：README（入口）、architect.md（架构总览）、scope-trim.md（裁剪判定书+执行记录）、
agent-handover.md（本文）、todo-deferred.md（TODO 口径）、gap-mesh.md、gap-mesh-final.md、
gap-watcher-merge.md、gap-gpu-load.md、gap-routing-dyn.md、gap-token-accounting.md、
gap-inflight-age.md、gap-metrics-final.md、gap-tls-chain.md、gap-virtual-models.md、
gap-worker-caps.md（每服务并发/功率上限：候选集硬排除、最热卡口径、功率通道）、
parity-cpu-ablation.md。

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
