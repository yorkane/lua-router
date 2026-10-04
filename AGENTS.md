# AGENTS.md（lua-router）

完整交接说明读 [doc/agent-handover.md](doc/agent-handover.md)。

## 项目定位与重点（用户裁定 2026-10-01）

本项目的主要目的，按优先级：

1. **更灵活的模型服务调度策略**：在现有 8 策略骨架上继续演进——策略可按模型/入口名粒度组合，
   感知健康、熔断、负载与 GPU 利用率；新调度能力的落点是 `policies/` 与 `policy.lua`。
   已落地的两块即按此形状走：**虚拟模型是对下游的服务主入口，1 对多**（一个入口用 `targets` 映射
   一组实际模型，这些模型可以来自不同的上游实例；策略实例按**入口名**建，一入口一棵亲和树，由它在
   整组里选路，逐实例的 `candidates` 绑定名必须落在组内、否则 400，转发体的 model 用选中候选的
   绑定名；条目级只允许 `context_window` 一个覆盖字段——它是**对外声明的上下文总窗口（输入+输出）**，
   作用只是让客户端更早触发压缩，**不参与任何 max_tokens 计算**（用户裁定 2026-10-04，见本节末），
   网关也不做任何条目级的输出预算改写），以及每服务并发/功率上限
   （`max_concurrency` / `max_power_w` 在 `router.candidates_for` 装配候选时**硬排除**，即使 cache_aware
   亲和命中也迁走；**功率读数未知 → 不排除**）。两者都刻意做到 `policies/` 零改动，口径见
   doc/gap-worker-caps.md 与 doc/gap-virtual-models.md §1–§4。
2. **覆盖与弥补下游请求的配置**：网关侧对请求做顶层改写与补齐（入口名解析成落点的实际模型名、
   effort 卡片、`stream_options`），让不完美或欠配置的
   客户端请求也能被正确调度——改写一律走 `set_top_field` 式顶层精确改写，不整表重编码。
   **输出预算不在补齐之列**：`max_tokens` / `max_completion_tokens` / `max_output_tokens` 原样透传，
   调用方给多少转发多少，没给时网关也不替它决定（用户裁定 2026-10-04）。
   别名级的 `policy` / `effort` 覆盖已停用：策略归路由页的 `policy` / `model_policies`（按**入口名**配），
   档位归模型卡片（按选中候选的绑定名查）。
3. **UI 的配置与可视化**：`/_ui/admin/` 管理台四页按使用频度排序：**模型管理**（虚拟模型入口页，
   这是最常用的配置，入口卡片在页面最上面）、服务池、路由策略、日志监控。原「远程服务 / 服务接入」页
   已并入服务池：运行态 `GET /workers` 与声明层 `/_ui/config` 的 upstreams 段按规范化 URL 全外合并，
   一个地址一行，`/_ui/config` 的 JSON 视图是权威面。是第一公民；新增配置面必须同步落到可视化，
   而不是只给 env。
4. **JSON 格式的 API 修改与保存**：`/_ui/config` 的 JSON 查看/编辑/保存、`LMR_CONFIG_FILE`
   原子落盘与 reload 恢复是核心链路；配置变更走 `config_store` 热配置（免重启生效）。


> 用户裁定 2026-10-02（补充）：虚拟模型条目上的 `policy` / `effort` 在停用期间「字段仍被接受、仍
> 往返落盘、解析时 warn、热路径不读」是刻意的兼容行为，让老配置文档继续通过校验与回显，
> **不要当 bug 修掉**。

> ~~用户裁定 2026-10-02：条目级 `context_window` 是对下游统一的 max_tokens 钳制~~ —— **该定义已于
> 2026-10-04 废止，由用户亲自推翻**（同一条裁定里 per-alias `policy` / `effort` 停用的部分仍然有效）。
> 旧口径是：条目级 `context_window` 显式配置恒定生效、与策略选中哪台实例无关，未配置时取整组模型卡
> `ctx` 的最小值，转发前用它钳制 `max_tokens`。废止的原因是它把三个不同的量当成了同一个数——
> `context_window` 的本意是入口对外声明的**上下文总窗口（输入+输出）**，却被当作**单次输出预算**写进
> `max_tokens`。生产 21.k:8801 的故障即由此而来：转发链上的 `apply_ctx_cap` 字段表只有
> `{ max_tokens, max_completion_tokens }`，漏了 `/v1/responses` 用的 `max_output_tokens`，于是走 responses
> 入口时 `body.max_tokens` 恒为 nil，命中「nil 就凭空写入 cap」那一支，网关替每一个 responses 请求造了
> 一个 `max_tokens = 350000`（那条入口声明的 `context_window`），而服务的真实窗口只有 262144；
> 524288 − 350000 = 174288 正好是失败阈值，故障体里「350000 tokens for the completion」恒定不变、只有
> input 在变。这段历史刻意保留：`context_window` 这个字段名与散落各处文档的钳制话术还在，下一个人需要
> 知道它为什么长这样、以及哪些说法已经作废。转发链上作废的实现是 `router.apply_ctx_cap`
> （`router.lua:3256`）与 `entry_ctx_cap`（`router.lua:3263`），两者现为恒「无改写」的空壳导出，只为
> 保住 `_M` 导出契约而留；`config_store._M.ctx_cap`（`config_store.lua:1937`）与
> `_M.virtual_ctx_cap`（`config_store.lua:1970`）实现原样保留但**热路径无调用者**，
> `ctx_cap` 的唯一生产读者是 `/_ui/props` 的 `props.with_ctx`（`props.lua:133`），作用只是把回显的
> `n_ctx` / `n_ctx_train` 换成操作员声明的值，不影响任何转发字节）。

> **用户裁定 2026-10-04（现行，推翻上一条对 `context_window` 的定义）**：
> 1. **网关不再改写调用方的输出预算**：`max_tokens` / `max_completion_tokens` / `max_output_tokens`
>    一律原样透传，调用方给多少转发多少；调用方没给时网关也不替它填一个数。
> 2. **`context_window` 回归本义**：入口**对外声明的上下文总窗口（输入+输出）**，作用是让客户端更早
>    触发压缩；不参与任何 max_tokens 计算，只保留解析 / 落盘 / 往返 / UI 展示。
> 3. **新增模型卡片字段 `context_limit`**＝**服务实际能承受的上下文限制**（引擎真实能力，操作员按引擎
>    启动参数抄录）；平铺写法 `model_context_limit`、env `LMR_MODEL_CONTEXT_LIMIT`，卡片优先于平铺层。
> 4. **配置期校验**：条目的 `context_window` 必须**严格小于**组内各卡片 `context_limit` 的最小值，否则
>    拒绝保存；组内没有任何卡片声明读数 = 不知道引擎能力 = 不校验也不报错。实现
>    `config_store.validate_declared_context_windows`（只挂在 `apply_profiles` / `apply_document` 两条入口
>    写入路径上：磁盘快照的读路径不判，否则一份已落盘的配置会在下次 reload 整体退回 env 默认；
>    单卡写入的 `apply_model_config` 也不判，那正是操作员登记引擎读数的动作）。口径见
>    doc/gap-virtual-models.md §4。

与 Rust 版的行为对拍是护住既有行为的手段，不是目标；排期与新功能优先对齐以上四点。

以下是不可违反的硬规则：

1. **测试纪律**：`test/final_gates.sh` / `test/test_lua_router.sh` / `test/integration/e2e_*.py` 全部
   host 网络 + 容器名前缀，**严禁并发**（跑前 `ps` 查）；luajit/resty 单测（无端口绑定）可并发。
   精确 kill PID，禁止 pkill。测试容器全部 `lr-*` 前缀，收尾必须清零。门禁两档：
   `GATE_TIER=quick`（缺省，build/conf/unit/contract/probes 约 3 分钟）供普通修改快速验证；
   发版、文档计数更新、生产镜像替换必须 `GATE_TIER=full` 全量 21 门全绿（快速档绿不算全绿锚点）。
2. **临时文件一律 /data/tmp/**；生产验证文档更新进 doc/。
3. **生产容器白名单**：本仓只许动 `lua-router-8800`（compose 在 /data/app/lua-router/）；
   **21.k:8801 是生产，未经用户明确要求不得更新**——改动只在 21.k:8802（测试）上验证，用户确认后才推 8801；
   `authz`、`searxng-*`、`qdrant-faces`、`face-*`、`va-*`、`pg18-video`、`n8nc`、`resdown-*`、
   `wx-liushi-monitor` 及一切名字不带 lr- 的容器不许碰。已退役的 `llm-watcher`（Exited）不要重启。
4. **设计红线**：推理体字节透传（顶层精确改写，不整表重编码）；**调用方的输出预算永远原样透传**
   ——`max_tokens` / `max_completion_tokens` / `max_output_tokens` 网关一个都不改写、缺失时也不代填
   （用户裁定 2026-10-04，见上面的裁定块）；流式不缓冲；跨请求状态只走 shdict；
   新开关缺省零行为变化；**探针失败按分档定性，后果不同**——转发路径上的探测（hb 健康巡检、gpu_load 抓
   `/metrics` 与远程 Prom）失败只损失精度，绝不摘 worker；watcher 严格探针按用户裁定（2026-10-01）分档
   摘除：确定性否定（对方答了 HTTP 却读不出 `/v1/models` 的 `data[].id`、命中 router 自指纹、超
   `max_models`）当轮立即摘并跳过 remove-grace/keep-last；传输层未知（连不上／超时／无应答）累计到
   `SMG_WATCHER_PROBE_FAILURES`（缺省 2）才摘；`no probe transport` 与 `require_health` 未通过属
   「不触发摘除」档，既不摘也不计数；两档摘除同受单轮摘除保险丝（`SMG_WATCHER_PROBE_FUSE`）约束。
   完整口径见 doc/agent-handover.md §4 与 doc/gap-watcher-merge.md §1.1。**不得把这行红线写回成
   「凡探测失败都不摘 worker」的一刀切表述**（那是第 10 条守卫之前的旧文案，照它改就会把守卫连根拔掉）。
5. **信任边界**：网关层零鉴权（已按用户裁定删除），本服务只许部署在 authz 边缘之后或可信内网。
6. **TODO 不实现**：wasm、MCP（doc/todo-deferred.md）；已删平面（gRPC/PD、history、tokenizer/parse、
   auth、K8s discovery、OTel）恢复只能 git revert 对应 commit，不要在 main 上重写。
7. **提交与推送**：user.name=yorkane / yorkane@users.noreply.github.com；main 直推 GitHub
   （github.com/yorkane/lua-router）。文档计数改动必须与一次全绿门禁日志同锚。
8. 子智能体 provider 偶发半截返回：验收以盘上文件与日志为准；派活时给文件所有权边界。
9. **`/v1/models` 的对外形状有三件不可自作主张的事**（字段表与来源优先级见 README〈`/v1/models` 的模型对象形状〉、
   doc/gap-virtual-models.md §5）：① **官方四字段 `id` / `object` / `created` / `owned_by` 都是 required**，每个模型
   对象必须带齐；`created` 取不到上游读数时用常量 `MODEL_CREATED_UNKNOWN = 0`（`router.lua:3579`），**不塞
   `ngx.time()`**——那会让同一条目每次请求产出不同字节，打掉客户端缓存与前后对比。② 扩展字段（`capabilities`
   命名空间与旁挂的 `supports_reasoning_effort` / `reasoning_effort` / `reasoning_efforts`，都不是官方字段）的来源
   优先级固定为**操作员 config 声明 > 引擎自报（`registry.model_caps`）> 整个键省略**，**宁可不报也不猜**；省略是删键，
   不写 `null`、不写空数组冒充「支持零个」。③ **`data[].id` 的取值集合与 `owned_by` 语义是老契约**——真实模型恒
   `"local"`，单目标入口 `"llm-router-><model>"`、多目标入口 `"llm-router"` + 整组 `owned_by_models`；registry 的
   worker 判定、watcher 的覆盖探针与客户端的模型选择全按 id 与 owned_by 建，改动前必须先想清楚。
   另注：registry 采集能力时刻意**不读上游条目的顶层 `context_window`**（那是本网关配置层的字段名，混进引擎读数
   就是重犯 2026-10-04 那次把声明总窗口当单次输出预算的事故）。
