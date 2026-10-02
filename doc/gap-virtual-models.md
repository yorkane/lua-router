# 虚拟模型（服务入口）· 服务接入(upstreams) · JSON 编辑

日期：2026-10-01 首版；**2026-10-02 语义反转重写**。决策人：用户。

## 1. 语义（用户裁定，以此为准）

> 虚拟模型是**日常服务的主入口**，可以**映射多个实际模型提供服务**，通过**调度策略**调度到不同的
> 实际模型上，是 **1 对多**的关系，**只能配置模型上下文长度覆盖（context-window）**，以便对下游保持统一。

三点含义，缺一不可：

1. **虚拟名是对下游暴露的服务入口**，客户端只认它。它是**最常用的配置**，UI 上放在导航第一位
   （页面名「模型管理」）。
2. **1 对多**：一个虚拟名映射一组实际模型（`targets[]`）。这些实际模型可以来自**不同的上游服务**
   （同机不同实例、跨机远程都行）。流量由**调度策略在这一组内选路**——不是按绑定名硬选一个。
3. **条目级只允许配 `context_window`**：对下游统一的 `max_tokens` 钳制。这是**唯一**的条目级覆盖字段。

per-alias 的 `policy` 与 `effort` **已停用**（2026-10-02）：仍接受、仍落盘、解析时 warn，
但**热路径不读**。理由：
- effort 阶梯描述的是**引擎**，一个入口跨 N 个引擎时配在入口上对哪个都不诚实——档位归各模型卡
  （`model_effort` / `model_configs`）。
- policy 归 `model_policies`（按**虚拟入口名**配，策略实例的 key 就是入口名）或全局 `policy`。
  见 §7 兼容周期。

## 2. 数据模型

### virtual_models 条目

| 字段 | 类型 | 必填 | 语义 |
|---|---|---|---|
| `model` | string | 是 | 虚拟名 = 对下游暴露的服务入口 |
| `targets` | string[] | 否 | **主字段**：该入口映射的一组实际模型名（1..N） |
| `target` | string | 否 | 旧单值代表值，等价于 `targets` 长度为 1 的特例 |
| `candidates` | `{worker, model?}[]` | 否 | 把某个实际模型显式绑到某个实例；`model` 必须在组内 |
| `workers` | string[] | 否 | 旧实例白名单，与 `candidates` 取**交集** |
| `context_window` | 正整数 | 否 | **唯一允许的条目级覆盖**，对下游统一的 max_tokens 钳制 |
| `policy` / `effort` | string | 否 | **已停用**：仍接受、仍落盘、解析 warn、热路径不读 |

`targets` 与 `candidates` 至少要有一个，否则 400。

### 内部旗标（不外露、不参与磁盘字节）

- `explicit_targets`：**只有操作员真写过 `targets` 才为真**。它是「组模式」的唯一开关。
  没写它的行（纯 `{model,target}`、candidates-only、env 种子）一律走 legacy 路径，
  **行为逐字节不变**。
- `explicit_target`：区分「写过的 target」与「从候选推的代表值」。快照只回写写过的——
  这是「派生值不落盘」的实现，磁盘文档不会长出没人声明过的 `targets` 或 `target`。

### 派生组优先级（`target_group_of`）

1. 显式 `targets`
2. `target` 与各 `candidates[].model` 的**并集**（`target` 恒在首位）
3. nil（非组模式）

第 2 条是必须的：上一轮 `{target, candidates[...]}` 的多绑定形状本来就用不同模型名，
折成单元素会把那些绑定误判成非法。

`candidates[].model` 缺省时的继承源**只能是操作员亲口写过的名字**（written `target`，
或 written `targets[1]`），不能退到派生组组头——否则某条没写 model 的绑定会去继承
**兄弟候选**的模型名，同配置换顺序得到不同落点。

## 3. 选路

```
route(body):
  requested  <- body.model                      # 客户端只认入口名
  profile    <- store.profile_for_alias(requested)
  group      <- profile_model_group(profile)    # 只认 explicit_targets == true
  key_model  <- group_key_name(profile, model) or resolved   # 组入口用入口名
  inst       <- policy_for(key_model, profile)
                 组模式: hint/live 取自整组 worker（group_policy_hint）
                 legacy: 逐字节旧行为（hint 问 registry 的该模型名）
  candidates_for(model, profile):
    for record in records:
      keep = is_available(id)                             # 健康 + 熔断
      keep &= 白名单 ∩ 绑定（legacy workers 与 candidates）
      if keep and binding == nil and igw and not group:   # 组模式整门让位
          keep = candidate_may_serve(record, model)
      if keep: keep = not capacity_exclusion(record)       # 上限硬排除，位置不变
      if keep and group:
          serving = [m for m in group if candidate_allows_model(record, m)]
          if serving == []: refuse+1; drop                  # 引擎背书过才判死
          else: binding = 显式绑定 or record.model_id(在组内) or serving[0]
      if keep:
          record.lr_bound_model = binding                  # 转发名
          if group: record.model_id = 入口名               # 策略树 key 归一
          push record
  worker = pinned(id) or inst:select(candidates)
  forward(rewrite_model(raw, worker.lr_bound_model))       # 恒为真实引擎名
```

### 策略 key 为什么用虚拟名

**一个虚拟入口一棵树。** 实现方式是在 `candidates_for` 里把存活组候选的 `record.model_id`
盖成入口名，于是 `policies/` **零改动**：cache_aware 的 `make_tree_key`、prefix_hash /
consistent_hashing 的 ring key、bucket 的桶键全部自动收敛成「整组一个池」。

若沿用落点模型名做 key，1 对多正是「不同模型」的形态，策略实例会按模型分桶退化成 N 棵互不相识的树，
**跨模型的亲和与负载逃逸全部失效**——那不是「一个入口调度到多个模型」，是「N 个入口各自调度」。

租约粒度仍是 **worker URL**（cache_aware 的原生语义：URL 即租户）。同一 worker 提供多个被映射
模型时，两条显式绑定是**两个独立候选行**，各自带正确的 `lr_bound_model`。

### 转发名恒为真实引擎名

组候选必有 `lr_bound_model`，所以 `rewrite_model` 用的名字**绝不可能是入口名**。
手动 pin（`x-smg-target-worker`）在候选集上按 id 匹配，发生在策略之前、与 key 无关。

## 4. context_window 优先级

```
1. 显式 context_window                          -> 直接生效，完全不看选中实例
2. 未显式 且 组 >= 2                            -> 整组各模型卡片的最小值
3. explicit_targets != true 或 #group < 2      -> nil，走旧的「按落点模型卡」路径
```

第 1 条是**「对下游保持统一」的硬要求**：按选中实例查卡会让同一个请求因落到不同实例而得到不同的
max_tokens，直接违背用户原话。

第 2 条取**最小值**：组由网关控制不了的引擎提供服务，取最宽会让最窄的那个拒 body，而取值随落点
漂移就不是「统一」了。保守常量是唯一同时满足安全与统一的读法。

`ctx_cap()` 另有一道守卫：**入口名命中 virtual_profiles / virtual_models 时返回 nil**，
禁止有人用入口名写卡片把 per-pick 方差重新打开。

## 5. /v1/models 广告

- **单模型行**保持 `owned_by = "llm-router->"..<model>`（契约钉死的 legacy 形状，逐字节不变）。
- **多模型行**改标 `owned_by = "llm-router"` + `owned_by_models`（整组），供 UI 展示。
- 「与真实 worker 同名则丢弃别名」这条规则守的是**入口自己的 id**，不会因为某个被映射的模型名
  与入口重名而误伤。

## 6. upstreams 声明层

一条 upstream 行 = 一个持久化的池成员：

| 字段 | 说明 |
|---|---|
| `url` | http(s)://host[:port]，`registry.normalize_url` 规范化后作为稳定身份 |
| `model_id` | 上游主模型 id（缺省 unknown） |
| `models` | 该实例对外提供的模型名数组（非数组 400）。drift 判定用**子集**而非相等——registry 是折叠写，相等判定会让 30s 自愈每轮重写、永不安定 |
| `api_key` | 回显恒为 null；写入三态：缺席/null=保持、""=清除、非空=设置 |
| `priority` / `cost` / `labels` / `disable_health_check` | 同 POST /workers |
| `max_concurrency` / `max_power_w` | 每服务容量上限，见 [gap-worker-caps.md](gap-worker-caps.md) |

**reconcile**（写请求内同步 + worker 0 定时器 30s 自愈，按 config revision 比对）：
- url 不存在 → `registry.add({..., discovery=config})`
- url 存在且 `discovery==config` → 更新上述字段
- url 存在但来源不是 config（watcher / 手工 / bootstrap）→ **不覆盖**，摘要报 skipped
- 从 upstreams 移除 → 只删 `discovery==config` 的池成员，其余永远不碰

**上限的事实来源是声明层**：`upstream_drifts` 会把 `max_*` 连同 priority/cost/labels 一并比较，
所以运行态 `PUT /workers` 改的值会在 30 秒自愈里被声明值写回。UI 侧已把声明态行的运行态编辑
入口整体锁死并用徽章明示，避免「改了却被撤销还找不到原因」。

## 7. 兼容周期

per-alias `policy` / `effort` 的停用是**读侧**的（热路径不读），**写侧照旧接受并往返**。
这样导出的旧配置不会立刻失效，同时新语义下它们不生效；解析时 warn 让操作员看得见。

全局与模型级的那套**不受影响**，优先级更高：
- effort：`model_effort`（按落点模型名）→ 模型卡 `model_configs[].effort`
- policy：`model_policies`（**按虚拟入口名**，因为策略实例的 key 就是入口名）→ 全局 `policy`

## 8. JSON 编辑（config.html）

`/\_ui/config` 的 JSON 视图是权威面：
- `vmRow` **不再白名单取键**，未知键与形状非法的已知键一律进 `row.extra` 原样带回——
  否则「打开 JSON 视图 → 应用」会静默清空新字段。
- `targets` chip 编辑器 + `context_window` 输入；per-alias policy/effort 的编辑器已撤除，
  但**序列化仍无损**。
- 提交前只做中文体检（越组绑定、别名撞自身 target、`context_window` 非正整数等）**只报错不改数据**，
  后端仍是权威。

## 9. 已知限制

1. 组内某模型「一台已验证实例都没有」时，选中它的请求会 503，文案点名
   `healthy engines serve none of the mapped models`。预防要靠注册侧强制 `/v1/models` 背书，
   属 watcher 纪律。
2. 入口名与它映射的真实模型名**可以同名**（只禁入口名等于自己组内的名字、或等于另一个入口名）。
   两个入口共享同一组模型能正确分树，但给其中一个配 per-model 覆盖时只命中入口名那一行——
   语义正确但容易看错。
3. `LMR_VIRTUAL_MODELS` env **未扩展**多 target 语法（`alias=target` 逗号对无法无歧义表达多值，
   宁可不提供也不静默忽略）。env 用户拿 1 对多只能走 `LMR_CONFIG_FILE`。
4. `disable_health_check` 的 worker（含全局关巡检）永不进 `discover()`，永不获得引擎背书 →
   多绑定只能靠 config 行显式声明 `models`。
5. watcher 注册当刻只有主模型（全量 `models` 靠下一轮 `discover` 的 `refresh_models` 补齐）。
6. mesh 集群视图不同步 `models`，多网关下各节点的覆盖度可能不一致。
7. `/\_ui/config/apply` 是**整表替换**：只发一段会把其它段清空。生产验证时踩过这个坑。
8. 入口级策略覆盖的替代入口是 `model_policies`（按入口名）。`policy_document` 已把虚拟入口名
   补进行集，否则路由策略页永远列不出入口那一行。

