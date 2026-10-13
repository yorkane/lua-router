# 范围收敛（scope-trim.md）

本文只保留两件事：当前范围裁定，以及已删平面的恢复机制。裁剪执行当日的判定表、
行数收益和分步顺序属于历史，见 git 历史与 commit 6d2103a→732dc0b。

## 1. 当前范围

用户裁定（2026-10-01）：本项目只做 **多 GPU 服务的服务发现与请求调度**。

- 需要监控本地 GPU 负载（或从远程监控同步抓取），允许配置远程 LLM 服务加入服务池；
- 不考虑 gRPC、MCP、本地推理、模型管理；
- 服务动态添加、路由动态变更、配置映射改写、流量性能监控、UI 可观察可配置是重点。

范围裁定之后的补充口径以 README 与 AGENTS.md 为准：管理台已从 `/_ui/*` 迁到站点根
`/`（2026-10-08，`/_ui/*` 一律落 404 sink）；全局调用方鉴权自 2026-10-05 停用，网关层
保持匿名，只部署在 authz 边缘之后或可信内网；自 2026-10-12 起管理面另有一道独立的
Basic Auth（口径见 doc/gap-admin-auth.md 与 AGENTS.md 硬规则 5）。

## 2. 已删平面与恢复机制

七次 commit（6d2103a→732dc0b）删掉六个平面：gRPC+PD、history（含 history_redis）、
tokenizer/parse、auth 全层（jwks / API key / RBAC / 审计）、K8s discovery、OTel。
mesh 在裁剪判定中原判 DELETE，用户改为 KEEP，现为受 `SMG_ENABLE_MESH` 开关的
多活同步面（行为见 doc/gap-mesh.md）。

两条与删除绑定的现行行为：

- `/v1/responses` 是纯透传推理端点：没有会话/消息持久化，`/v1/conversations*`、
  `/_ui/history` 等路径不注册，`SMG_HISTORY_BACKEND` 一族 env 残留无效果。
- `/wasm` 三条路由保留为固定 501（诚实 TODO 形态，见 doc/todo-deferred.md）。

**恢复机制**：已删平面一律只能 `git revert` 对应 trim commit，不得在 main 上重写
（AGENTS.md 硬规则 6）。
