# Agent 交接说明（lua-router）

> 写给接手本仓库的 agent：目标是用最少考古成本进入正确的工作状态。本文只写**当前事实**与**操作纪律**，
> 设计推导在历史文档里（§8 地图）。最后核对：2026-10-01（HEAD `715e58b`）。

## 0. 30 秒速览

lua-router 是 LLM 推理网关的 OpenResty/Lua 实现（原 Rust smg 的功能移植 + 裁剪 + 扩展）。当前形态：
**多 GPU 服务的服务发现与请求调度器**——8 策略选路、健康/熔断/限流、DP 展开、mesh HA、进程内 watcher
（原独立 llm-watcher 容器已合并退役）、GPU 负载双源、路由策略热切换、token 核算、虚拟模型 profile 与
持久化 upstreams、Quasar UMD 管理控制台（/_ui/admin/）。

已删面（git 历史可恢复）：gRPC/PD、history 存储、tokenizer/parse 代理、网关鉴权（全开放）、K8s 发现、OTel。
TODO 不实现：wasm、MCP（doc/todo-deferred.md）。

基线（2026-10-01）：**20 门禁全绿**（含契约 580/22 段）、Lua 22 057 行 / 15 个模块 + policies/6 文件、
单测 9 文件、文档 45 份。仓库：github.com/yorkane/lua-router（public，main 直推）。

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
  router.lua(3208+)  入口总装：klib.router 分发、转发泵、重试、熔断、指标/_ui/mesh/model-map 挂载
  init.lua           fork 前接线：env 快照、hb/watcher/mesh/负载定时器（worker0 + lr_locks 单飞）、on_log 兜底
  registry.lua       worker 注册表（lr_workers shdict）、健康态、DP 展开、负载字段折叠
  watcher.lua(2024)  进程内服务发现：targets/docker/proc 三源、严格探针、九条守卫、ledger、model-map
  gpu_load.lua(1102) GPU 负载源：worker /metrics 抓取 + 远程 Prom 查询，写 registry 负载字段
  policy.lua+policies/  8 策略；cache_aware=亲和树+负载逃逸（per-process 树，多 worker 亲和率衰减）
  hb.lua             健康巡检 + 熔断计数 + /v1/loads 扇出 + gpu_load 定时器挂载点
  config_store.lua   热配置：别名/profile/upstreams/effort/ctx/policy（LMR_CONFIG_FILE 原子落盘+shdict）
  observability.lua  Prometheus 家族渲染、请求日志环形缓冲（/_ui/logs 源）、inflight 年龄槽表
  mesh.lua(2525)     HA gossip（用户裁定保留；/_mesh/internal/* 无鉴权=信任边界=网络）
  limit.lua / hash.lua / ui.lua / props.lua / config.lua
ui/                  原版 llama.cpp webui（/_ui/）+ ui/admin/（Quasar UMD 管理台四页，中英双语）
  logs-inject.js     向原版 webui 左导航注入 Logs/Admin 入口（MutationObserver 防抖判重模式，别破坏）
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

**命令**：

```bash
cd /home/aigc/ChatGPT/lua-router
bash test/final_gates.sh                     # 全量 20 门（串行约 12 分钟）
GATE_ONLY=contract bash test/final_gates.sh  # 单门；GATE_ORDER 见脚本头
TEST_ONLY=inflight_age bash test/test_lua_router.sh   # 契约单段
```

**20 门**：build conf unit contract probes e2e_stateful e2e_policies e2e_ui_bridge e2e_errors
e2e_effort head_routes mesh_http e2e_policy_parity e2e_watcher e2e_token_accounting e2e_gpu_load
e2e_routing_dyn e2e_profiles mesh_two e2e_tls_chain。

**已知 flake/坑**：

- `e2e_policy_parity` 的 random χ² 检验有约 5% 假阳率（临界 5.991）——失败先看是不是贴线抖动，单独重跑该门即可。
- 新写的 e2e 套件首跑大概率红（前提/解包类错误），不要怀疑产品代码，先核对场景前提。
- 生产机的 proc 扫描会把门禁轮的 mock（alpha/beta 等模型名）短暂注册进生产池：跑完门禁后清一次
  （`GET /workers` 找 unhealthy 的测试模型名 → `DELETE /workers/{id}`）。结构性根治（端口黑白名单策略）未做。
- watcher 探针读到「接受 TCP 后不回 HTTP」的口（qdrant gRPC 6334 类）会被 nginx 记 [error]；
  消音手段是 `SMG_WATCHER_DENY_PORT`（lua_socket_log_errors off 在 timer 阶段挡不住），机制见
  doc/gap-watcher-merge.md 偏差 13。

## 4. 设计红线（改动前必读）

- **推理体字节透传**：只允许 set_top_field 式顶层精确改写（model/stream_options/profile 收窄），不整表
  重编码；流式不缓冲（token 核算的 usage 帧剥除是唯一的帧级编辑，有 MAX_SSE_FRAME 上界）。
- **跨请求状态一律 shdict**（lr_workers/lr_policy/lr_stats/lr_request_log/lr_limit/lr_locks/lr_watch/
  luarouter_config）；进程内可变状态只许 cache_aware 树、bucket 计数、mesh 成员表（三者都已钉 worker=1 或有衰减文档）。
- **缺省零行为变化**：所有新开关（SMG_WATCHER_ENABLED、SMG_LOAD_SOURCE、policy 覆盖）缺省时对外行为
  与旧版逐字节一致，这是门禁判据的一部分。
- **失败不摘 worker**：watcher/gpu_load 的探测失败只损失精度（keep-last/grace/降级纯在飞），绝不让
  监控故障拖垮转发。
- **生产 worker 池清理**：删 worker 走 DELETE /workers/{id}；watcher 会自动重发现仍在监听的（这是设计）。

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

## 7. 文档地图（doc/，45 份）

**现行权威**：README（入口）、architect.md（架构总览）、scope-trim.md（裁剪判定书+执行记录）、
agent-handover.md（本文）、todo-deferred.md（TODO 口径）、gap-watcher-merge.md、gap-gpu-load.md、
gap-routing-dyn.md、gap-token-accounting.md、gap-inflight-age.md、gap-metrics-final.md、
gap-mesh-final.md、gap-tls-chain.md、parity-cpu-ablation.md。

**对拍与真实评测（数据留档，引用前注意树龄）**：parity-contract/routing/policy-extra/perf/perf-v2、
real-eval.md（prefix cache 97–99% 命中实证）。

**裁剪前平面的历史留档（只读，不要当现状引用）**：feature-gap.md 与 verification-final.md 的计数仍是
裁剪前 841/21 门口径（README 已刷新到 580/20 门，这两份待归档或重写）；gap-history*.md、
gap-grpc-*.md、gap-dp-jwt.md、gap-discovery-*.md、gap-otel.md、gap-responses-final.md、gap-integration.md、
gap-http-semantics.md、gap-core.md、gap-auth-tls.md、gap-test-gates.md、impl-*.md、fix-majors.md、
verification-run3.md、wasm-feasibility.md。

## 8. 环境事实（235.t）

- 真实上游验证服务：https://llm-248.ai-t.wtvdev.com/v1（APISIX 边缘 + SGLang；文档里写作
  <real-upstream-host>）；公共视觉模型 http://10.252.25.217:8800/v1。
- 公共 Redis 10.252.25.241:6379 与本仓无关（history 平面已删）；test/local.env 机制保留为通用本地覆盖。
- gh 已登录 yorkane（repo scope），push 用 https 到 GitHub；镜像不推远端仓库（本机使用）。
- 子智能体 provider 偶发半截返回/无声停止：交付验收以**盘上文件 + 日志证据**为准，别信口头进度。
- 本机有多用户裸 openresty 进程是**容器内进程**（宿主 ps 可见，cwd 读不到属正常），别误杀。
- llm-watcher 独立容器已退役（Exited，保留镜像可回滚）；它的原仓库在 /home/aigc/ChatGPT/llm-router/watcher/。

