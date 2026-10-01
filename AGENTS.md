# AGENTS.md（lua-router）

完整交接说明读 [doc/agent-handover.md](doc/agent-handover.md)。

## 项目定位与重点（用户裁定 2026-10-01）

本项目的主要目的，按优先级：

1. **更灵活的模型服务调度策略**：在现有 8 策略骨架上继续演进——策略可按模型/别名粒度组合，
   感知健康、熔断、负载与 GPU 利用率；新调度能力的落点是 `policies/` 与 `policy.lua`。
2. **覆盖与弥补下游请求的配置**：网关侧对请求做顶层改写与补齐（model 别名、effort/ctx 卡片、
   `stream_options`、per-alias policy/profile 收窄），让不完美或欠配置的客户端请求也能被正确
   调度——改写一律走 `set_top_field` 式顶层精确改写，不整表重编码。
3. **UI 的配置与可视化**：`/_ui/admin/` 管理台（服务池、模型覆盖、日志监控、路由策略四页）
   是第一公民；新增配置面必须同步落到可视化，而不是只给 env。
4. **JSON 格式的 API 修改与保存**：`/_ui/config` 的 JSON 查看/编辑/保存、`LMR_CONFIG_FILE`
   原子落盘与 reload 恢复是核心链路；配置变更走 `config_store` 热配置（免重启生效）。

与 Rust 版的行为对拍是护住既有行为的手段，不是目标；排期与新功能优先对齐以上四点。

以下是不可违反的硬规则：

1. **测试纪律**：`test/final_gates.sh` / `test/test_lua_router.sh` / `test/integration/e2e_*.py` 全部
   host 网络 + 容器名前缀，**严禁并发**（跑前 `ps` 查）；luajit/resty 单测（无端口绑定）可并发。
   精确 kill PID，禁止 pkill。测试容器全部 `lr-*` 前缀，收尾必须清零。
2. **临时文件一律 /data/tmp/**；生产验证文档更新进 doc/。
3. **生产容器白名单**：本仓只许动 `lua-router-8800`（compose 在 /data/app/lua-router/）；
   `authz`、`searxng-*`、`qdrant-faces`、`face-*`、`va-*`、`pg18-video`、`n8nc`、`resdown-*`、
   `wx-liushi-monitor` 及一切名字不带 lr- 的容器不许碰。已退役的 `llm-watcher`（Exited）不要重启。
4. **设计红线**：推理体字节透传（顶层精确改写，不整表重编码）；流式不缓冲；跨请求状态只走 shdict；
   新开关缺省零行为变化；探测失败绝不摘 worker。详见 doc/agent-handover.md §4。
5. **信任边界**：网关层零鉴权（已按用户裁定删除），本服务只许部署在 authz 边缘之后或可信内网。
6. **TODO 不实现**：wasm、MCP（doc/todo-deferred.md）；已删平面（gRPC/PD、history、tokenizer/parse、
   auth、K8s discovery、OTel）恢复只能 git revert 对应 commit，不要在 main 上重写。
7. **提交与推送**：user.name=yorkane / yorkane@users.noreply.github.com；main 直推 GitHub
   （github.com/yorkane/lua-router）。文档计数改动必须与一次全绿门禁日志同锚。
8. 子智能体 provider 偶发半截返回：验收以盘上文件与日志为准；派活时给文件所有权边界。
