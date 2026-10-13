# 路由策略动态变更（免重启）

现行实现落点：`config_store/`（lexicon / readers / mutators / handlers / persistence）、
`policy.lua`、`ui/admin/routing.html`、`conf/ui.conf` 的 `location = /config/policy`。
验证：`test/unit/test_routing_dyn.lua` + `test/integration/e2e_routing_dyn.py`（`GATE_GROUP=routing`）。

## 1. 行为

选路策略原先只在 init 阶段由 `config.lua` 的 `one_of("SMG_POLICY", "cache_aware", POLICIES)`
读一次，换策略必须改 env 重启。本特性把全局策略与 per-model 策略接入 `config_store` 已有的
热配置通道（shdict 快照 + `LMR_CONFIG_FILE` 原子落盘），提供策略端点的 GET/PUT，并在管理台
加「路由策略」页。改完策略，**下一次选路就走新策略**；两段都不配置时行为与改造前逐字节一致。

RuntimeConfig 新增两段：

| 段 | 形状 | 语义 |
| --- | --- | --- |
| `policy` | 字符串 \| null | 全局策略覆盖。8 个合法名之外一律 400；`null`/`""`/`"auto"`/`"null"` = 清除 |
| `model_policies` | `[{model, policy}]` 数组 | per-model 覆盖整表。行的 policy 为 null/空 = 该行不存在（跟随上级） |

合法策略名与 `config.lua` 的 `POLICIES` 一致：`random, round_robin, cache_aware,
power_of_two, prefix_hash, manual, bucket, consistent_hashing`。三份名单（`config.lua`
POLICIES、`config_store/lexicon.lua` POLICY_NAMES、`ui/admin/api.js` 展示）必须同步维护。

写入通道与其它热段完全相同：`apply_policy` → 校验 → `snapshot_of` → `write_snapshot`
（shdict set + 原子落盘 + revision incr）。校验失败在任何写入之前返回（HTTP 400），配置保持原样。

## 2. 端点

- `GET /config/policy` → 策略链文档：`{policies[8], policy, env_policy, effective_default,`
  `model_policies[], models[{model, registered, override, hint, effective, source}],`
  `revision, persist}`
- `PUT\|POST /config/policy`，body 三段任意组合（一次原子写）：
  - `{policy: "random"|null}` 改/清全局
  - `{model_policies: [{model, policy}, ...]}` 整表替换
  - `{model_policy: {model, policy|null}}` 单行 upsert/删除（保留其它行）
  - 全部缺省 → 400 "nothing to apply"；未知策略名 → 400 且不生效
  - 响应 = 最新文档，页面用它做「保存后确认生效回显」
- 其它方法 405 + Allow。

该 location 自 2026-10-12 起在管理面 Basic Auth 门内（`guard()`；`SMG_ADMIN_AUTH_PASS` 未配置时
整道门关闭），见 doc/gap-admin-auth.md。别名 `/u/config/policy` 同门；2026-10-08 admin 迁根后
`/_ui/*` 一律 404，旧路径不再可用。

## 3. 优先级链

```
                ┌─ config_store.model_policies[model] ──→ 该模型专用策略   [source=model]
 选路请求 ──────┼─ config_store.policy（全局覆盖）      ──→ 全局路径策略   [source=global]
                ├─ worker labels.policy（registry hint） ─→ 该模型策略      [source=hint]
                └─ env SMG_POLICY（config.lua cfg.policy）→ 全局策略        [source=env]
                      └─ 都没有 → round_robin（实例内兜底，与从前一致）
```

- 链条只在 `config_store.resolve_policy` 一处实现；`policy.lua`（数据面）与 `policy_document`
  （管理页）调同一函数，页面显示与实际选路不可能分叉。
- **运营覆盖优先于 worker hint**：路由页说什么，什么就路由。
- 任何一层给出的未知名字仍然塌回 `round_robin`。
- 缺省零行为变化：shdict 旧快照无 policy 键时解码为 nil，`resolve_policy` 退化为
  hint → cfg.policy → round_robin；未配置任何覆盖时 `stamp_global` 是一次 memo 布尔判断直接返回，
  实例对象不被触碰。

## 4. 生效机制与多 worker 可见性

1. **快照层**：`write_snapshot` 先写 `ngx.shared.luarouter_config`（请求路径读取的第一层，跨进程即时可见），
   再原子落盘 `LMR_CONFIG_FILE`（0.5s TTL 的进程内 memo 兜底）。缺失共享字典时退化为纯文件层，
   新鲜度由 TTL 限界。
2. **失效令牌**：`write_snapshot` 末尾 `incr policy_revision`。热路径的 `policy_override_active`
   经 memo：只在「revision token 未变 且 距上次读 < 0.5s」时复用，其余情况重解码。revision 是一次
   shdict get，无 JSON 解码，选路热路径开销可忽略。写方进程用自己的 dirty 位立即失效。
3. **实例落位**（均在 `policy.lua` 内部）：
   - 全局实例：每条请求的 `start_eviction()` 入口顺带 `stamp_global(policy.default)`，把共享默认实例
     **原地换装**（`reconfigure`）为链上解析出的策略——原地换装是因为实例被 file-local 缓存，换新表会让旧引用失效。
     `select()` 入口再用 `ctx.model` 补盖一次，保证「决定由谁做出」与「日志记的谁」一致。
   - per-model 实例：`for_model` 每次按链解析名字再查实例缓存——名字变即换实例（新亲和树，等价重启后的该模型），
     名字没变仍复用（树不被清）。切走再切回 cache_aware 时 `reconfigure` 从 `lr_policy` 的
     `snapshot:<policy>:<model>:<worker>` dump 恢复原树，**不需要清树**。
   - 换装会 `seeded=false` 让下一次 select 重新 seed 当前 worker 列表，并把 `_next_adjust` 清零
     （bucket 立即重划边界），与 `bump_generation` 语义一致。

## 5. 管理页 ui/admin/routing.html

Quasar UMD iframe 页，文案走 `i18n.js` 的 `routing` 块（中英双语）：生效链卡（env 层与全局生效值 +
revision + 持久化文件）、全局策略下拉（clearable = 回落到 SMG_POLICY，保存前二次确认，从 cache_aware
切走时追加「负载将重新分布」提示，保存后直接渲染 PUT 响应做回显）、按模型表（行集 = 已注册模型 ∪
已配置覆盖；列 = 覆盖 / hint / 当前生效 / 来源徽章 model-global-hint-env 四色；行内恢复清单行，
底部整表一次提交并 diff 出增删改数量）、400 → Notify.negative → 自动重读文档回滚界面。

## 6. 已知限制

1. 运行时切到 cache_aware 不改变进程数：`docker-entrypoint.sh` 只在启动时判定（未显式给
   `NGINX_WORKER_PROCESSES` 且策略是 cache_aware 时钉到 1，树是进程内 Lua 内存）。多进程下每进程各一棵树，
   命中率打折；要完整语义请在 compose 里显式设进程数，或持久化后重启。反向（cache_aware→random 再多进程）无额外问题。
2. `router.policy_for` 的 file-local 缓存意味着「路由日志的 route_type」与「实际做出选择的策略」之间，
   理论窗口内若发生跨协程换装，前者可能是上一次的值——仅影响一条日志行的字段，不影响选路本身。
3. per-model 覆盖清掉后，为覆盖策略建过的实例留在实例缓存里（按 policy×model 有界；同模型同策略重新启用时
   复用旧树，这是特性不是缺陷）。
4. hint 行只在注册期 `labels.policy` 存在时出现；改标签需要重新注册 worker。
5. mesh 部署（`SMG_ENABLE_MESH`）下 `mirror_mesh_state` 读到的是本进程被盖章后的策略名，与对端进程各自的
   覆盖可能不同——mesh 本就要求单进程，风险同第 1 条。
