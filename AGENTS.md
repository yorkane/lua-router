# AGENTS.md（lua-router）

完整交接说明读 [doc/agent-handover.md](doc/agent-handover.md)。

## 项目定位与重点（用户裁定 2026-10-01）

本项目的主要目的，按优先级：

1. **更灵活的模型服务调度策略**：在现有 8 策略骨架上继续演进——策略可按模型/入口名粒度组合，
   感知健康、熔断、负载与 GPU 利用率；新调度能力的落点是 `policies/` 与 `policy.lua`。
   已落地的两块即按此形状走：**虚拟模型是对下游的服务主入口，1 对多**（一个入口用 `targets` 映射
   一组实际模型，这些模型可以来自不同的上游实例；策略实例按**入口名**建，一入口一棵亲和树，由它在
   整组里选路，逐实例的 `candidates` 绑定名必须落在组内、否则 400，转发体的 model 用选中候选的
   绑定名；条目级只允许 `context_window` 一个覆盖字段——对下游统一的 max_tokens 钳制，与选中哪台
   无关），以及每服务并发/功率上限
   （`max_concurrency` / `max_power_w` 在 `router.candidates_for` 装配候选时**硬排除**，即使 cache_aware
   亲和命中也迁走；**功率读数未知 → 不排除**）。两者都刻意做到 `policies/` 零改动，口径见
   doc/gap-worker-caps.md 与 doc/gap-virtual-models.md §1–§4。
2. **覆盖与弥补下游请求的配置**：网关侧对请求做顶层改写与补齐（入口名解析成落点的实际模型名、
   effort/ctx 卡片、`stream_options`、条目级 `context_window` 统一钳制），让不完美或欠配置的
   客户端请求也能被正确调度——改写一律走 `set_top_field` 式顶层精确改写，不整表重编码。
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

与 Rust 版的行为对拍是护住既有行为的手段，不是目标；排期与新功能优先对齐以上四点。

以下是不可违反的硬规则：

1. **测试纪律**：`test/final_gates.sh` / `test/test_lua_router.sh` / `test/integration/e2e_*.py` 全部
   host 网络 + 容器名前缀，**严禁并发**（跑前 `ps` 查）；luajit/resty 单测（无端口绑定）可并发。
   精确 kill PID，禁止 pkill。测试容器全部 `lr-*` 前缀，收尾必须清零。门禁两档：
   `GATE_TIER=quick`（缺省，build/conf/unit/contract/probes 约 3 分钟）供普通修改快速验证；
   发版、文档计数更新、生产镜像替换必须 `GATE_TIER=full` 全量 21 门全绿（快速档绿不算全绿锚点）。
2. **临时文件一律 /data/tmp/**；生产验证文档更新进 doc/。
3. **生产容器白名单**：本仓只许动 `lua-router-8800`（compose 在 /data/app/lua-router/）；
   `authz`、`searxng-*`、`qdrant-faces`、`face-*`、`va-*`、`pg18-video`、`n8nc`、`resdown-*`、
   `wx-liushi-monitor` 及一切名字不带 lr- 的容器不许碰。已退役的 `llm-watcher`（Exited）不要重启。
4. **设计红线**：推理体字节透传（顶层精确改写，不整表重编码）；流式不缓冲；跨请求状态只走 shdict；
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
