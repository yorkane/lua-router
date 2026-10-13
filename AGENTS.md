# AGENTS.md（lua-router）

完整交接说明读 [doc/agent-handover.md](doc/agent-handover.md)。

## 项目定位与重点（用户裁定 2026-10-01）

本项目的主要目的，按优先级：

1. **更灵活的模型服务调度策略**：在现有 8 策略骨架上继续演进——策略可按模型/入口名粒度组合，
   感知健康、熔断、负载与 GPU 利用率；新调度能力的落点是 `policies/` 与 `policy.lua`。
   已落地的两块即按此形状走：**虚拟模型是对下游的服务主入口，1 对多**（一个入口用 `targets` 映射
   一组实际模型，这些模型可以来自不同的上游实例；策略实例按**入口名**建，一入口一棵亲和树，由它在
   整组里选路，逐实例的 `candidates` 绑定名必须落在组内、否则 400，转发体的 model 用选中候选的
   绑定名）。条目级只允许**声明位**覆盖：`context_window` / `max_output_tokens` / `default_effort` 与
   `effort_map` / `modalities` / `hidden` / `disabled` / `api_key`（清单与三态语义见
   doc/gap-virtual-models.md §2，`policy` 不在其中）。这些都是对外声明与准入位，不改写转发体的输出
   预算；`context_window` 尤其只是**对外声明的上下文总窗口（输入+输出）**，作用只是让客户端更早触发
   压缩，**不参与任何 max_tokens 计算**（用户裁定 2026-10-04，见本节末）。第二块是每服务并发/利用率
   上限（`max_concurrency` / `max_gpu_util` 在 `router.candidates_for` 装配候选时**硬排除**，即使
   cache_aware 亲和命中也迁走；**GPU 利用率读数未知 → 不排除**；功率/瓦特一族已于 2026-10-09
   整体移除）。两块都刻意做到 `policies/` 零改动，口径见 doc/gap-worker-caps.md 与
   doc/gap-virtual-models.md §1–§4。
2. **覆盖与弥补下游请求的配置**：网关侧对请求做顶层改写与补齐（入口名解析成落点的实际模型名、
   effort 卡片、`stream_options`），让不完美或欠配置的
   客户端请求也能被正确调度——改写一律走 `set_top_field` 式顶层精确改写，不整表重编码。
   **输出预算不在补齐之列**：`max_tokens` / `max_completion_tokens` / `max_output_tokens` 原样透传，
   调用方给多少转发多少，没给时网关也不替它决定（用户裁定 2026-10-04）。
   别名级的 `policy` / `effort` 覆盖已停用：策略归路由页的 `policy` / `model_policies`（按**入口名**配），
   落点档位归模型卡片（按选中候选的绑定名查）；入口对外的档位清单自 2026-10-11 裁定 A 起由条目层的
   `effort_map` 推导。对外声明与转发改写是两层，各画各的：转发链上按**模型卡片 → 虚拟条目 → 全局**
   三层逐 `from` 查表，第一个给了这条映射的层赢（`default_effort` 同理取第一个非 nil 的层，
   `model_effort` 强制行在所有层之上），三层都没给就原样透传；条目层没声明时只查卡片与全局两层，
   转发字节与接线前一致。见 doc/gap-virtual-models.md §2。
3. **UI 的配置与可视化**：站点根 `/` 的管理台四页（2026-10-08 admin 迁根；`/_ui/*` 已全部取消、落 404 sink）按使用频度排序：**模型管理**（虚拟模型入口页，
   这是最常用的配置，入口卡片在页面最上面）、服务池、路由策略、日志监控。原「远程服务 / 服务接入」页
   已并入服务池：运行态 `GET /workers` 与声明层 `/config` 的 upstreams 段按规范化 URL 全外合并，
   一个地址一行，`/config` 的 JSON 视图是权威面（管理面过 Basic Auth，见硬规则 5）。是第一公民；新增配置面必须同步落到可视化，
   而不是只给 env。
4. **JSON 格式的 API 修改与保存**：`/config` 的 JSON 查看/编辑/保存、`LMR_CONFIG_FILE`
   原子落盘与 reload 恢复是核心链路；配置变更走 `config_store` 热配置（免重启生效）。


> 用户裁定 2026-10-02（补充）：虚拟模型条目上的 `policy` / `effort` 在停用期间「字段仍被接受、仍
> 往返落盘、解析时 warn、热路径不读」是刻意的兼容行为，让老配置文档继续通过校验与回显，
> **不要当 bug 修掉**。

> **用户裁定 2026-10-04（现行）**：
> 1. **网关不改写调用方的输出预算**：`max_tokens` / `max_completion_tokens` / `max_output_tokens`
>    一律原样透传，调用方给多少转发多少；调用方没给时网关也不替它填一个数。
> 2. **`context_window` 是对外声明的上下文总窗口（输入+输出）**，作用只是让客户端更早触发压缩；
>    它不参与输出预算计算，也不与模型卡片的 `max_output_tokens` 做大小比较。字段自身仍按配置 schema
>    校验，并保留解析 / 落盘 / 往返 / UI 展示；它不改写任何转发字节。
> 3. **模型卡片字段 `max_output_tokens`**（原名 `context_limit`，2026-10-08 改名）＝**声明给下游 agent 的
>    单次最大输出 token 数**，是一份**纯对外 advertisement**：唯一去处是 `/v1/models` 的
>    `capabilities.max_output_tokens`（操作员声明压过引擎自报），**不参与任何校验、钳制或 max_tokens 运算**，
>    也不声称引擎的真实能力。平铺写法 `model_max_output_tokens`、env `LMR_MODEL_MAX_OUTPUT_TOKENS`，
>    卡片优先于平铺层；写了卡片就清掉同模型的平铺行。
>    `capabilities.context_length` 与此无关，只由两档决定：操作员声明的窗口（卡片 `ctx` / 平铺
>    `model_ctx`，经 `config_store.ctx_cap`）**优先于**引擎自报，两者都没有就整个键省略。
> 4. **不做「声明窗口 vs 输出上限」的大小比较校验**：条目的 `context_window` 是**上下文总窗口**，卡片的
>    `max_output_tokens` 是**单次输出预算**，两个量不可比；字段各自仍按配置 schema 校验，
>    `context_window` 不用于拒绝或改写请求。
>    口径见 doc/gap-virtual-models.md §4。

新功能与排期优先对齐以上四点；本仓的行为口径以本文与 doc/ 现行文档为准，不与任何邻居实现对拍。

以下是不可违反的硬规则：

1. **测试纪律**：测试门禁支持**跨独立 run 并发**；隔离依赖冻结源码快照/镜像 manifest、每 run/gate 命名空间、共享机器端口台账及声明式资源锁，不依赖人工串行。跑前仍检查已有测试和端口占用，确保资源账本可用。详细可复制流程和各验证维度见 [doc/testing-workflow.md](doc/testing-workflow.md)。默认 `GATE_JOBS` 为 `min(8, CPU 数)`，`GATE_JOBS=1` 是显式串行；各 run 同时受本机 Docker/CPU 资源限制。
   精确 kill 自己拥有的 PID，禁止 `pkill`；只清理由本 run 名册记录的容器、文件和 ledger 行，**禁止全局清理 `lr-*`**——收尾按**本 run 的容器名册**核对归零，不是全机 `lr-*` 计数（并发下别人的 run 也在用这个前缀）。
   改动按最小面验证（doc/testing-workflow.md §6 的矩阵：UI 走 `GATE_GROUP=ui`、声明层走 config、路由走 routing、跨组件接线必须带 `contract`），不要默认每次都跑 full。
   门禁两档：`GATE_TIER=quick`（build/conf/unit/contract/probes 五门）供快速反馈；发版与生产镜像替换要求完整 22 门 full 锚点。分组聚合只可在同一版本身份（同 `fingerprint` + 同 `image_id`/`authz_id`/`build_base_id`）下补齐 22 门且无 skip/missing/invalid 时成立，且聚合必须显式 `--tier full`（`full_anchor_eligible` 只在 full 档判定）。
   **并行委派纪律**：root 先 `prepare` 出一份 manifest 并随任务下发；每个 agent 只认领互不重叠的文件所有权，回报 run id、fingerprint、tier/group 与 `report.json` 路径；不同源码快照/不同镜像的结果禁止混进同一次聚合。
2. **临时文件一律 /data/tmp/**；生产验证文档更新进 doc/。
3. **生产容器白名单**：本仓只许动 `lua-router-8800`（compose 在 /data/app/lua-router/）；
   **所有 8800 都是生产**（本机 `lua-router-8800`、21.k:8800、217.t:8800），未经用户明确要求一律不得更新；
   **21.k 的 8801 / 8802 是测试环境**——改动先部署到这两个测试实例验证（compose 在 /data1/app/lua-router-8801 等），用户确认后才推生产；
   `authz`、`searxng-*`、`qdrant-faces`、`face-*`、`va-*`、`pg18-video`、`n8nc`、`resdown-*`、
   `wx-liushi-monitor` 及一切名字不带 lr- 的容器不许碰。已退役的 `llm-watcher`（Exited）不要重启。
4. **设计红线**：推理体字节透传（顶层精确改写，不整表重编码）；**调用方的输出预算永远原样透传**
   ——`max_tokens` / `max_completion_tokens` / `max_output_tokens` 网关一个都不改写、缺失时也不代填
   （用户裁定 2026-10-04，见上面的裁定块）；流式不缓冲；跨请求状态只走 shdict；
   新开关缺省零行为变化；**探针失败按分档定性，后果不同**——转发路径上的探测（hb 健康巡检、gpu_load 抓
   `/metrics` 与远程 Prom）失败只损失精度，绝不摘 worker；watcher 严格探针按用户裁定（2026-10-01 立，
   2026-10-09 改 reject 档的后果）分档处置：**reject 三档**（对方答了 HTTP 却读不出 `/v1/models`
   的 `data[].id`、命中 router 自指纹、超 `max_models`）**当轮临时禁用保行**——registry 行不动，只打
   `td:` 键让候选装配排除它，探针恢复轮显式清位立刻回池，不进保险丝计数，`SMG_WATCHER_PROBE_TEMP_DISABLE=0`
   退回旧的当轮删行；**物理摘除只留两个信号**：传输层未知（连不上／超时／无应答）累计到
   `SMG_WATCHER_PROBE_FAILURES`（缺省 2）才摘，与「发现源不再报它」走 remove-grace/keep-last 宽限；
   `no probe transport` 与 `require_health` 未通过属「不触发处置」档，既不摘也不计数；摘除档同受单轮摘除
   保险丝（`SMG_WATCHER_PROBE_FUSE`）约束，同轮另有「禁用即摘」（条目 `disabled` 走同一个 `release()` 出口）。
   完整口径见 doc/gap-watcher-merge.md §1.1（十条守卫与探针分档处置）。**不得把这行红线写回成
   「凡探测失败都不摘 worker」的一刀切表述**（照它改会把摘除守卫连根拔掉）。
5. **信任边界**：**全局调用方鉴权已于 2026-10-05 的范围裁剪停用**（doc/scope-trim.md；恢复只能 git revert 对应 commit，不要在 main 上重写，见硬规则 6）——推理面 `/v1/*` `/generate`、`/props`、`/ha` 与 `/_mesh/internal/*` 保持匿名，本服务只许部署在 authz 边缘之后或可信内网。**鉴权只有两处例外**：下面这条管理面 Basic Auth，与**按虚拟入口**的 api-key 门槛（`api_key` 三态，只认 `Authorization: Bearer <key>`，缺键与错键同一个 401；它是下游准入门，不是全局鉴权，未配密钥的入口照旧匿名）。除这两处外不得再加鉴权层。
   **管理面自 2026-10-12 起有一道独立的 Basic Auth**（用户裁定：不走 authz，网关自己校验；口径与落点见 doc/gap-admin-auth.md）：入口文档与 `*.html`、根数据面 `/config*` `/logs*` `/stats` `/slots` `/tools`、`/u/config*` 别名族，以及 klib 控制面 `/workers` `/model-map` `/flush_cache` 都在门内（单点 `admin_auth.lua`，三个挂点 `guard` / `guard_static` / `guard_klib`）。
   两条豁免：`SMG_ADMIN_AUTH_PASS` 未配置或空串 = 整道门关闭（缺省逐字节零行为变化，硬规则 4）；来源 loopback 免凭据。一条**前置否决**（用户裁定 2026-10-12，推翻按值还原的 v1 实现）：`X-Real-IP` / `X-Forwarded-For` / `Forwarded` 任一头名一出现就收回 loopback 豁免，**值一概不解析**——反代与网关同机时 remote_addr 恒 127.0.0.1，按值还原等于让 `-H 'X-Real-IP: 127.0.0.1'` 绕过整道门（21.k:8802 测试实例实测踩实，生产 8800 同链路取证）。名单是 `PROXY_ORIGIN_HEADERS`，扩名字要同步扩单测。
   `SMG_ADMIN_AUTH_PASS` 与 `LMR_CONFIG_STORE_*` 同一条登记纪律：三份 conf 的 `env` 白名单（模板 / 裸 conf / 测试 conf）必须同步，漏登记 = nginx 从 worker 剥掉 = 门静默不生效（硬规则 11-3）。口令走明文 base64，只在 HTTPS 或可信内网下启用。`/metrics` `/v1/loads` `/ha/*` `/_mesh/internal/*` 刻意不进 klib 清单（抓取、健康判定链、集群互联必须匿名），清单因此是 fail-open 的：新增受管路径要显式添一行。
6. **TODO 不实现**：wasm、MCP（doc/todo-deferred.md）；已停用平面（gRPC/PD、history、tokenizer/parse、
   auth、K8s discovery、OTel）恢复只能 git revert 对应 commit，不要在 main 上重写。
7. **提交与推送**：user.name=yorkane / yorkane@users.noreply.github.com；main 直推 GitHub
   （github.com/yorkane/lua-router）。文档计数改动必须与一次全绿门禁日志同锚。
8. 子智能体 provider 偶发半截返回：验收以盘上文件与日志为准；派活时给文件所有权边界。
9. **`/v1/models` 的对外形状有三件不可自作主张的事**（字段表与来源优先级见 README〈`/v1/models` 的模型对象形状〉、
   doc/gap-virtual-models.md §5）：① **官方四字段 `id` / `object` / `created` / `owned_by` 都是 required**，每个模型
   对象必须带齐；`created` 取不到上游读数时用常量 `MODEL_CREATED_UNKNOWN = 0`（`router/models_api.lua` 顶部），**不塞
   `ngx.time()`**——那会让同一条目每次请求产出不同字节，打掉客户端缓存与前后对比。② 扩展字段（`capabilities`
   命名空间与旁挂的 `supports_reasoning_effort` / `reasoning_effort` / `reasoning_efforts`，都不是官方字段）的来源
   优先级固定为**操作员 config 声明 > 引擎自报（`registry.model_caps`）> 整个键省略**，**宁可不报也不猜**；省略是删键，
   不写 `null`、不写空数组冒充「支持零个」。③ **`data[].id` 的取值集合与 `owned_by` 语义是老契约**——`owned_by`
   **全表恒为 `"lua-router"`**（用户裁定 2026-10-11：不向任何能读 `/v1/models` 的客户端暴露上游模型名；
   引擎自报的归属仍采进 `registry.model_caps` 留档，但不上外）。入口行与真实行
   的区分：客户端不许再拿 `owned_by` 当判别位（全表同值），也**不能把 `created==0` 当入口的充分判据**——入口行恒 0，真实行取不到上游读数时同样落 `MODEL_CREATED_UNKNOWN = 0`，0 只说明「这行没有引擎读数背书」；要区分入口行按 id 查声明层名册（`/config` 的 `virtual_models`）。`data[].id` 取值集合与
   `created` 契约不变；registry 的 worker 判定、watcher 的覆盖探针全按 id 建。管理台 picker
   （`/u/v1/models`，即 `ui.lua` 的 `ui.models()`）与 `/v1/models` **同口径指 `owned_by` 恒 `lua-router`**（2026-10-12 起）。
   两者的 `created` 不是一回事：picker 每行恒 0（它不采上游读数），`/v1/models` 的真实行取上游读数、取不到才落
   `MODEL_CREATED_UNKNOWN = 0`，入口行恒 0——别把「同口径」写成「两条连 created 都一样」。
   另注：registry 采集能力时刻意**不读上游条目的顶层 `context_window`**——那是本网关配置层的字段名，
   配置层字段不冒充引擎能力读数。
10. **门禁里的统计断言不许用「拟合优度没拒绝」当「等价成立」的证据。** χ² 检验的 `E[χ²] = df = k-1`，
   **公式里没有样本量**，所以 `P(χ² > 5.991) = 5.00%` 与 N 无关——**α=0.05 等于每轮全量门禁自带约 5% 的
   红概率预算，加大 N 一分不减**（实测 N=240→4800 稳定在 4.9%~5.1%）。要「证明与均匀不可区分」就得用
   **TOST 等价性检验**（`e2e_policy_parity.py` 的 `tost_uniform`），它的假红率随 N 变窄。两条配套纪律：
   ① **等价边界 d 要按「实测到过的最差真实行为」定**，不是按统计最优定；现取 `d=0.065`。
   ② **单侧阈值同样要标定**：阈值太松等于没检（旧口径在 N=240 下放过约 1/5 份额的真退化）。
   新增或调阈值前先算尾概率，别拍脑袋。
   顺带：TOST 的软肋是**过散**（批相关 ρ），所以它红了先怀疑环节流漂移，**加大 N 只会更糟**，对策是放宽 d。
11. **配置持久化有三条不可自作主张的事**（设计与取舍见 doc/gap-config-store.md）：
    ① **db 是权威源，`LMR_CONFIG_FILE` 是只读镜像**，不是第二个权威源。镜像的 revision 由 db 钉住，
       镜像被外部替换时由内容摘要判定并采纳；**摘要比对是「谁赢」的唯一依据**，不要改成优先级排序。
    ② **CAS 冲突拒绝并报错（409，带当前 revision），不用 LWW**——一次被静默吞掉的配置编辑会让操作员
       面对「磁盘一套、机器另一套」。只有「后端连不上」才走降级到 file 的老路径，两者不要混。
    ③ **`LMR_CONFIG_STORE_*` 全族必须在 `config_store.ENV_NAMES` 里**——nginx 会把未登记的 env 从 worker
       里剥掉，`capture_env` 也只按名册抓；漏登记的现象是「配了但静默走未配置降级」，极难查。
    另：**做任何持久化验证前先看 `lr_config_store_backend{backend="sqlite"} == 1`**，否则你验的是文件路径。
