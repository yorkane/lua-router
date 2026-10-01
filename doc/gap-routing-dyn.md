# 路由策略动态变更（免重启）

日期：2026-10-01 · 子任务：feat_routing_dyn · 基线 HEAD：f1122d2

## 1. 问题与结论

scope-trim 之后，选路策略由 `config.lua` 的 `one_of("SMG_POLICY", "cache_aware",
POLICIES)` 在 init 阶段一次性读入，`policy.new` 按它建实例；想换策略必须改环境变量
再重启容器。本特性把策略（全局 + per-model）接入 `config_store.lua` 已有的热配置
通道（LMR_CONFIG_FILE 快照 + shdict），提供 `/_ui/config/policy` 的 GET/PUT 端点，
并在管理控制台新增「路由策略」页 `ui/admin/routing.html`。改完策略，**下一次选路
就走新策略**；不配时行为与改造前逐字节一致。

## 2. 配置 schema（RuntimeConfig 新增两段）

快照（disk / `ngx.shared.luarouter_config` 的 `runtime_config`）新增：

| 段 | 形状 | 语义 |
| --- | --- | --- |
| `policy` | 字符串 \| null | 全局策略覆盖。8 个合法名之外一律 400；`null`/`""`/`"auto"`/`"null"` = 清除 |
| `model_policies` | `[{model, policy}]` 数组 | per-model 覆盖整表。行的 policy 为 null/空 = 该行不存在（跟随上级） |

合法策略名与 `config.lua` 的 `POLICIES` 一致：`random, round_robin, cache_aware,
power_of_two, prefix_hash, manual, bucket, consistent_hashing`。三份名单
（config.lua POLICIES、config_store POLICY_NAMES、api.js 展示）必须同步维护。

写入通道与其它热段完全相同：`apply_policy` → 校验 → `snapshot_of(cfg)` →
`write_snapshot`（shdict set + LMR_CONFIG_FILE 原子落盘 + revision incr）。校验失败
在任何写入之前返回，配置保持原样（对应 HTTP 400）。

### 端点

- `GET  /_ui/config/policy` → 策略链文档：`{policies[8], policy, env_policy,
  effective_default, model_policies[], models[{model, registered, override, hint,
  effective, source}], revision, persist}`
- `PUT|POST /_ui/config/policy`，body 三段任意组合（一次原子写）：
  - `{policy: "random"|null}` 改/清全局
  - `{model_policies: [{model, policy}, ...]}` 整表替换
  - `{model_policy: {model, policy|null}}` 单行 upsert/删除（保留其它行）
  - 全部缺省 → 400 "nothing to apply"；未知策略名 → 400 且不生效
  - 响应 = 最新文档，页面用它做「保存后确认生效回显」
- 方法门仿 axum：其它方法 405 + Allow。

## 3. 优先级链（policy 读取链）

```
                ┌─ config_store.model_policies[model] ──→ 该模型专用策略   [source=model]
 选路请求 ──────┼─ config_store.policy（全局覆盖）      ──→ 全局路径策略   [source=global]
                ├─ worker labels.policy（registry hint） ─→ 该模型策略      [source=hint]
                └─ env SMG_POLICY（config.lua cfg.policy）→ 全局策略        [source=env]
                      └─ 都没有 → round_robin（实例内兜底，与从前一致）
```

- 链条只在 `config_store.resolve_policy` 一处实现；`policy.lua`（数据面）与
  `policy_document`（管理页）调用同一函数，页面显示与实际选路不可能分叉。
- **运营覆盖优先于 worker hint**：路由页说什么，什么就路由。
- 任何一层给出的未知名字仍然塌回 `round_robin`（`policy.new` 从前的行为）。
- 缺省零行为变化：两段都不存在时（shdict 旧快照无 policy 键 → decode 后 nil），
  `resolve_policy` 退化为 hint → cfg.policy → round_robin，即改造前的
  `for_model` / `new` 逻辑；`stamp_global` 在未配置任何覆盖时是一次 memo 布尔判断
  直接返回，实例对象不被触碰。

## 4. 生效机制与多 worker 可见性（shdict）

策略变更要在 `worker_processes > 1` 时对所有 nginx 进程即时生效，靠三层：

1. **快照层**（既有）：`write_snapshot` 先写 `ngx.shared.luarouter_config`
   （请求路径读取的第一层，跨进程即时可见），再原子落盘 `LMR_CONFIG_FILE`
   （0.5s TTL 的进程内 memo 兜底）。缺失 lua_shared_dict 时退化为纯文件层，
   新鲜度由 TTL 限界——与模块既有文档口径一致。
2. **失效令牌**（新增）：`write_snapshot` 末尾 `incr policy_revision`。
   `policy.lua` 的热路径读取（`policy_override_active`）经 `policy_state()` memo：
   memo 只在「revision token 未变 且 距上次读 < 0.5s」时复用，其余情况重解码。
   revision 是一次 shdict get，无 JSON 解码，选路热路径开销可忽略。写方进程用
   `_policy_view_dirty` 立即失效自己的 memo（它的 token 还没被别的进程读到）。
3. **实例落位**（新增，均在 policy.lua 内部，router.lua 未动）：
   - 全局实例：`router.policy_for` 每条请求都会调 `policy_mod.start_eviction()`
     （幂等），该入口顺带 `stamp_global(policy.default)`——把共享的默认实例
     **原地换装**（`reconfigure`）为链上解析出的策略。原地换装是因为
     `router.policy_for` 把实例缓存在 file-local 变量里，换新表会让旧引用失效。
     `select()` 入口再用 `ctx.model` 补盖一次，保证「决定由谁做出」与
     「日志记的谁」一致（同一协程内 select 前无 yield，粘性/计数不会错行）。
   - per-model 实例：`for_model` 每次按链解析名字再查 `_M.instances` 缓存——名字变
     即换实例（新亲和树，等价重启后的该模型），名字没变仍复用（树不被清）。
     **不需要清 cache_aware 树**：切走再切回 cache_aware 时，`reconfigure` 从
     `lr_policy` 的 `snapshot:<policy>:<model>:<worker>` dump 恢复原树。
   - 换装会 `seeded=false` 让下一次 select 重新 seed 当前 worker 列表，并把
     `_next_adjust` 清零（bucket 立即重划边界），与 `bump_generation` 的语义一致。

### 与 worker_processes 的相互作用（已知限制）

`docker-entrypoint.sh` 在 `SMG_POLICY=cache_aware` 且未显式指定
`NGINX_WORKER_PROCESSES` 时把进程数钉到 1（树是进程内 Lua 内存）。运行时把全局
策略从 random **改到** cache_aware 时，进程数不会跟着变——多进程下每个进程各自
一棵树，命中率打折（与 Rust 多进程部署同样本限制一致，页面文案已提示）。反向
（cache_aware→random 再多进程）没有额外问题。要完整语义请在 compose 里显式设定
进程数或使用 LMR_CONFIG_FILE 持久化后重启。

## 5. 管理页 ui/admin/routing.html

仿 workers/models/logs 三页的 iframe 页模式（Quasar UMD，页面级 JS 内联在 HTML
底部，文案全部走 i18n.js 的 `routing` 块，中英双语）：

- **生效链卡**：展示 env 层当前值（`env_policy`）与全局路径当前生效
  （`effective_default`）+ 配置修订号（revision）+ 持久化文件。
- **全局策略卡**：下拉 = 后端 `policies` 数组（8 项，含中文描述），clearable =
  回落到 SMG_POLICY；保存前 Quasar.Dialog 二次确认（文案含目标策略名；从
  cache_aware 切走时追加「负载将重新分布」的危险提示）；保存后直接渲染 PUT 响应
  的文档做生效回显。
- **按模型表**：行集 = 已注册模型 ∪ 已配置覆盖；列 = 覆盖（下拉，留空=跟随上级）、
  实例 hint、当前生效、来源徽章（model/global/hint/env 四色）；行内「恢复」按钮清
  单行；底部整表一次提交（后端 `model_policies` 全量替换语义），diff 出
  新增/修改/删除数量再确认。
- 校验失败（非法策略名）：后端 400 → Notify.negative 显示错误 → 自动重读文档，
  界面回滚到后端真实状态。
- 壳接线：`app.js` pages 数组加 `routing.html?v=1`（插在 models 与 logs 之间），
  `groups` 网关管理组加 `routing` 菜单项（mdi-call-split），`syncFrameTitle`
  同步；`index.html` 的 i18n/api/app 版本号 +1；`api.js` 增
  `configPolicy()/configPolicyApply()`。

## 6. 测试

- `test/unit/test_routing_dyn.lua`（luajit 口径，122 checks）：normalize/8 策略集、
  缺省链与改造前逐条对拍（hint/未知名/兜底）、apply_policy 三种 patch 形状、
  非法名 400 语义（错误信息 + 不 bump revision + 旧值保留）、快照往返与
  cfg_from_document 再校验、for_model 链解析与实例缓存键、reconfigure 原地换装
  （表身份不变、registry 重键、清覆盖后回 env 而非粘住最后一次）、shdict revision 令牌变化、policy_document 行与来源徽章。
- 回归：luajit 五件（tree 67 / policies 118 / hash 795 / mesh 391 / watcher 267）
  与 resty 四件（tree / policies / hash / integration 66）全绿；
  `openresty -t` 过 test conf（含 ui.conf 新 location）。
- `test/integration/e2e_routing_dyn.py`（**本轮只写不跑**）：
  A cache_aware→random 分布变化（同前缀 10/10 → 摊开 + selection 计数器佐证）；
  B 非法策略 400 且粘性基线不动、空 patch/类型错 400、方法门 405+Allow；
  C per-model 优先于全局与 hint（含 labels.policy 行 source=global）；
  D worker_processes=4 时 PUT consistent_hashing 后同 key 12/12 落同一实例
  （shdict 跨进程一致性）+ revision 单调；E 无 LMR_CONFIG_FILE 时 docker
  restart 回 env 缺省；F 清空覆盖回链条。

## 7. 已知限制

1. 运行时切到 cache_aware 不改变进程数（见 §4，entrypoint 只在启动时判定）。
2. `router.policy_for` 的 file-local 缓存意味着「路由日志的 route_type」与
   「实际做出选择的策略」之间理论窗口内若发生跨协程换装（stamp 后被别的请求改写），
   前者可能是上一次的值——两端的 stamp 都发生在各自调用前一行，仅影响一条日志行
   的字段，不影响选路本身。
3. per-model 覆盖清掉后，为覆盖策略建过的实例留在 `_M.instances`（实例按
   policy×model 有界；同模型同策略重新启用时复用旧树，这是特性不是缺陷）。
4. hint 行只在注册期 labels.policy 存在时出现；改标签需要重新注册 worker。
5. 与 Rust 网关的 RuntimeConfig 兼容性：Rust 端没有 policy 段；同一份
   config.json 两边共用时，Rust 解码器按 serde 行为可能拒绝或忽略未知字段，
   跨实现共用文件前先在 Rust 侧验证。
6. mesh 部署（SMG_ENABLE_MESH）下 `mirror_mesh_state` 读到的是本进程被盖章后的
   策略名，与对端进程各自的覆盖可能不同——mesh 本就要求单进程，风险同 §4。

## 8. 文件清单

| 文件 | 变更 |
| --- | --- |
| lualib/resty/luarouter/config_store.lua | POLICY_NAMES、normalize_policy、ENV_NAMES+SMG_POLICY、new_cfg/cfg_from_document/snapshot_of 的 policy 段、revision 令牌、resolve_policy 链、policy_document、apply_policy、handle_config_policy* |
| lualib/resty/luarouter/policy.lua | require config_store（pcall）、chain_name、new/for_model 走链、reconfigure 原地换装、stamp_global（start_eviction + select 两个入口） |
| lualib/resty/luarouter/ui.lua | config_policy_get / config_policy 桥 |
| conf/ui.conf | location = /_ui/config/policy（GET/HEAD 读，PUT/POST 写，其余 405+Allow） |
| ui/admin/routing.html | 新页 |
| ui/admin/app.js, i18n.js, api.js, index.html | 菜单项 + routing 词典块 + API + 版本号 |
| test/unit/test_routing_dyn.lua | 新单测（122 checks，含 ui.lua 端点桥的 400/200/回显语义） |
| test/integration/e2e_routing_dyn.py | 新 e2e（只写未跑） |
| doc/gap-routing-dyn.md | 本文 |
