# 虚拟模型（服务入口）· 服务接入(upstreams) · JSON 编辑

口径决策人：用户。本文只登记**现行规则**与实现落点（一律「文件 + 函数名」，不钉行号——
2026-10-05 的 facade 拆分让全部「文件:行号」锚漂移）。历史裁定链看 git log。

## 1. 语义

1. **虚拟名是对下游暴露的服务入口**，客户端只认它。它是**最常用的配置**，UI 上排在导航第一位
   （页面名「模型管理」）。
2. **1 对多**：一个虚拟名映射一组实际模型（`targets[]`）。这些实际模型可以来自**不同的上游服务**
   （同机不同实例、跨机远程都行）。流量由**调度策略在这一组内选路**——不是按绑定名硬选一个。
3. **条目级只允许「声明位」**：`context_window` / `max_output_tokens` / `default_effort` /
   `effort_map` / `modalities` / `hidden` / `disabled` / `api_key`，逐字段口径见 §2 的表。
   这些都是对外声明与准入门，**没有一个改写转发字节**。`context_window` 是「对下游保持统一」的
   那个统一量：同一个入口，无论策略选中组内哪台实例，广告出去的窗口都是同一个数。
   **`policy` 被排除在条目级之外**：策略实例的 key 就是入口名、一入口一棵亲和树，条目里再嵌一份
   policy 会让同一个入口长出两棵树。

legacy per-alias 的 `policy` 与 `effort` **已停用**（2026-10-02 裁定，**别当 bug 修**）：这两个字段仍被接受、
仍往返落盘、解析时 warn，但**热路径不读**。现行 policy 归路由页的 `model_policies`（按**入口名**配）
或全局 `policy`。这不影响表中现行的 `default_effort` / `effort_map`：它们推导入口**对外**的 reasoning
   声明，同时条目层也是转发链上 effort 改写的**中间一层**（落点卡片 → 条目映射 → 全局，见 §4 第 1 条）。
对外声明层与落点改写层读的是同一张映射表，画的是两份东西，详见 doc/gap-effort-ladder.md。

## 2. 数据模型

### virtual_models 条目

| 字段 | 类型 | 必填 | 语义 |
|---|---|---|---|
| `model` | string | 是 | 虚拟名 = 对下游暴露的服务入口 |
| `targets` | string[] | 否 | **主字段**：该入口映射的一组实际模型名（1..N） |
| `target` | string | 否 | 旧单值代表值，等价于 `targets` 长度为 1 的特例 |
| `candidates` | `{worker, model?}[]` | 否 | 把某个实际模型显式绑到某个实例；`model` 必须在组内 |
| `workers` | string[] | 否 | 旧实例白名单，与 `candidates` 取**交集** |
| `context_window` | 正整数 | 否 | 入口**对外声明的上下文总窗口（输入+输出）**，作用只是让客户端更早触发压缩；条目声明位里**唯一参与窗口广告**的一位。**不改写任何输出预算、不参与任何 max_tokens 计算、不与任何读数做配置期比较**（正整数校验是唯一硬校验）。对外去处：入口行的 `capabilities.context_length` 与根层 `context_length` 优先取它（§4、§5） |
| `max_output_tokens` | 正整数 | 否 | 入口级的**单次输出预算声明**位：纯对外 advertisement，**不参与任何校验、钳制或 max_tokens 运算**（口径与卡片格一致，§4 第 3 条）。**实现缺口（接线未做）**：广告链不消费条目层的这个值——入口行的 `capabilities.max_output_tokens` 只由组内聚合得出（`router/models_api.lua` 的 `advertise_virtual_entry` → `narrowest_number(rows, "max_output_tokens")`），真实行的 `declared_max_output_tokens` 只读卡片与平铺层。配置它不改变任何对外读数；将来如何接线与定优先级需另行设计，本文不预设。它与 `policy`/`effort` 的「刻意接受、热路径不读」是两件事，不要互相推定状态 |
| `default_effort` / `effort_map` | string / 映射表 | 否 | 入口上**唯一的一张** effort 强度映射表：对外的一切 reasoning 声明由这张表推导，缺省即 from==to 恒等透传。推导落点以源码为准（`router/models_api.lua` 的 `effort_advertise.derive` 与 `fill_model_fields`）：根路径 `supports_reasoning` / `supports_reasoning_effort` / `default_reasoning_effort` + 顶层 `reasoning_efforts`（picker 形状）+ `capabilities.reasoning_effort`（判定面）。同一张表在转发链上是三层改写的**中间一层**：落点卡片 → 条目映射 → 全局（§4 第 1 条）；对外声明与落点改写各画各的（doc/gap-effort-ladder.md） |
| `modalities` | string[] | 否 | 模态声明，参与 `capabilities.supports_vision` 的正/负向推导（不对称口径见 §5.1） |
| `hidden` / `disabled` | 三态布尔 | 否 | `hidden` = 这个名字不进 `/v1/models`（照常服务）；`disabled` = 这台实例连被发现的资格都没有。**不是对外能力读数**，读法只有 `config_store/readers.lua` 的 `model_is_hidden` / `model_is_disabled`。**可见性逐名字独立（用户裁定 2026-10-15）**：入口行的显隐只由入口自己那一位决定，组内成员被 hidden 既不抹入口行、也不退出入口的能力聚合（被藏的落点照常服务，读照常进）；成员被 disabled 才退出聚合，全组都被 disabled 时入口行不产出（那时它确实没有还能服务的落点）。旧口径「成员被藏 ⇒ 不进对外清单，整组被藏 ⇒ 入口整行消失」随 `owned_by_models` 退役（2026-10-11）已无对外载体，217.t 用它把「藏一台引擎」放大成「抹掉整个入口」，`router/models_api.lua` 的组门据此收窄为只认 disabled，回归钉在 test_models_shape G13 |
| `api_key` | string | 否 | 按入口的下游准入门密钥，三态见 §2.1 |
| `policy` / `effort` | string | 否 | **已停用**（2026-10-02 裁定，别当 bug 修）：仍接受、仍往返落盘、解析 warn、热路径不读 |

`targets` 与 `candidates` 至少要有一个，否则 400。

上表的声明位由 `config_store/profiles.lua` 的 `build_entry_declarations` 统一装配（`context_window`
与 `max_output_tokens` 走 `profile_from_entry` 里的 `build_context_window` / `build_max_output_tokens`）：
**缺键 / null = 不覆盖**（与「说了 false」严格分开，装配路上绝不合并），写了非法值整条入口 **400**，
逐字段往返无损。

**入口层没有独立的 `supports_*` 布尔位**（2026-10-11 裁定 A 拆除 `supports_tool_use` /
`supports_streaming` / `supports_reasoning` / `supports_vision` / `supports_reasoning_effort`，
配置层与解析一并去掉，**不留「接受但忽略」的兼容支**，与上面 `policy`/`effort` 那两位的裁定刻意相反）：
对外读数改由 **effort 映射表与 `modalities` 推导**（推导事实见 `config_store/profiles.lua` 的
`effort_facts`，字段合成在 `router/models_api.lua`）——「显式声明说 false、映射表又说 true」这种自相
矛盾不该存在，保留一条能覆盖推导的旁路等于给每条推导再配一个开关。老配置残留的布尔在下一次落盘时
自然消失。**卡片层（`model_configs`）的同名字段不在此范围**：它说的是落点引擎自己，继续按
「声明 > 引擎自报 > 省略」说话。

### 2.1 入口 api_key 三态

- 三态写入：缺席 = 保持原值、`""` = 清除、非空 = 设置。明文只活在 profile 里，`/config` 回显抹掩码，
  比对在库内（`config_store/readers.lua` 的 `entry_api_key_matches`，一次回 requires / matches 两个值）。
- 只认 `Authorization: Bearer <key>`；**缺键与错键同一个 401**（`router/inference.lua` 的
  `send_error(401, "api_key_required", ...)`，带 `WWW-Authenticate`），不区分子原因，密钥不裁剪空白
  （带空格的密钥与错键同一条 401）。
- 它是**按虚拟入口的下游准入门**，不是全局鉴权（全局调用方鉴权已停用，AGENTS.md 硬规则 5）：
  未配密钥的入口照旧匿名，除它与管理面 Basic Auth 外不得再加鉴权层。

### 内部旗标（不外露、不参与磁盘字节）

- `explicit_targets`：**只有操作员真写过 `targets` 才为真**。它是「组模式」的唯一开关。
  没写它的行（纯 `{model,target}`、candidates-only、env 种子）一律走 legacy 路径，**行为逐字节不变**。
- `explicit_target`：区分「写过的 target」与「从候选推的代表值」。快照只回写写过的——
  这是「派生值不落盘」的实现，磁盘文档不会长出没人声明过的 `targets` 或 `target`。

### 派生组优先级（`target_group_of`）

1. 显式 `targets`
2. `target` 与各 `candidates[].model` 的**并集**（`target` 恒在首位）
3. nil（非组模式）

第 2 条是必须的：`{target, candidates[...]}` 的多绑定形状本来就用不同模型名，折成单元素会把那些
绑定误判成非法。

`candidates[].model` 缺省时的继承源**只能是操作员亲口写过的名字**（written `target`，
或 written `targets[1]`），不能退到派生组组头——否则某条没写 model 的绑定会去继承**兄弟候选**的
模型名，同配置换顺序得到不同落点。

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

## 4. 两个声明量：context_window 与卡片的 max_output_tokens

现行裁定（2026-10-04 立，第 3 / 4 条由 2026-10-08 改写）：

1. **网关不改写调用方的输出预算。** `max_tokens` / `max_completion_tokens` / `/v1/responses` 用的
   `max_output_tokens` 一律原样透传：调用方给多少转发多少，调用方没给时网关也不替它填一个数。
   引擎因此拒掉的，一定是调用方自己要的数，不会是网关造的数。转发链上唯一还在改写请求体的是
   `router/inference.lua` 的 `apply_effort_policy`（effort 档位，见 doc/gap-effort-ladder.md §6）；
   `apply_ctx_cap` / `entry_ctx_cap` 保留为恒「无改写」的空壳导出，只为不破坏按名字引用它们的
   `_M` 契约（`router/inference.lua` 末尾的 `_M.apply_ctx_cap` / `_M.entry_ctx_cap`，`router.lua`
   facade 原样 re-export）。
   **effort 改写的层序（三层继承，2026-10-04 裁定：落点卡片 → 虚拟条目 → 全局）**：查表函数是
   `config_store/readers.lua` 的 `effort_layers` / `request_effort_for`，层序由它钉死——落点**模型卡片**
   （`model_configs[].effort_map` / `default_effort`，卡片按选中候选的绑定名解析，见
   `router/candidates.lua` 的 `card_key_for`）排第一，**虚拟条目层**排第二，**全局层**
   （`effort_map` / `default_effort`）排最后。点名了档位就逐层问「有没有人规定这档要改写成谁」，
   第一个命中的赢；没点名就逐层找第一个声明了缺省档的层，全空 = 完全不覆盖 = 不改写。
   条目层由 `router/profiles.lua` 的 `profile_entry_fallback` 装配：只取 `default_effort` / `effort_map`
   两位（条目的 `modalities` 等是对外形状聚合口径，不许漏进转发体），先按客户端给的名字查、
   查不到再按解析后的落点名查，legacy 别名因此不漏；条目什么都没写就返回 nil，转发链只剩卡片与
   全局两层，与放行条目层之前逐字节一致。`model_effort` 是**强制行**，它压过这三层（
   `request_effort_for` 之前先问它，见 `router/inference.lua` 的 `apply_effort_policy`）。

   对外声明层（§5 的 `capabilities` / `reasoning_efforts`）读的是同一张映射表，**不读层序**：
   入口行只由条目那张表推导，落点卡片只出现在真实模型行上。所以「入口映射表说支持某档」与
   「选中实例的卡片把它改成别的档」是两份各自成立的读数，客户端以引擎自己的 400 为最终裁决（
   网关不做 per-request 档位校验，见 doc/gap-effort-ladder.md §6）。
2. **`context_window` 是入口对外声明的上下文总窗口（输入+输出）**，作用是让客户端更早触发压缩。
   它不参与任何 max_tokens 计算，只保留解析（`config_store/profiles.lua` 的 `build_context_window`）、
   落盘、往返与 UI 展示。
3. **模型卡片上的输出预算声明** = 字段 `max_output_tokens`（原名 `context_limit`，2026-10-08 改名，
   连同「服务实际能承受的上下文限制」那句旧释义一起作废）＝**声明给下游 agent 的单次最大输出
   token 数**，是一份纯对外 advertisement：唯一去处是 `/v1/models` 的
   `capabilities.max_output_tokens`（操作员声明压过引擎自报），**不参与任何校验、钳制或 max_tokens
   运算**，也不声称引擎的真实能力。卡片写法 `model_configs[].max_output_tokens`，平铺写法
   `model_max_output_tokens` / env `LMR_MODEL_MAX_OUTPUT_TOKENS`，卡片优先于平铺层（写了卡片就清掉
   同模型的平铺行，免得留一条谁都不再看作生效的旧数字）。
   `capabilities.context_length` 与此无关：它只由两档决定——操作员声明的窗口（卡片 `ctx` / 平铺
   `model_ctx`，经 `config_store.ctx_cap`）**优先于**引擎自报，两者都没有就整个键省略。
4. **没有「声明窗口 vs 输出上限」这类配置期校验**：条目的 `context_window` 是上下文总窗口，卡片的
   `max_output_tokens` 是单次输出预算，两个量不可比。原 `config_store.validate_declared_context_windows`
   （曾挂在 `apply_profiles` / 整文档 `apply_document` 两条写入路径）与 UI 侧同款前端预校验（橙色徽章、
   编辑框报错、保存按钮禁用）已一并移除：`context_window` 只做解析 / 落盘 / 往返 / 展示，
   网关与 UI 都不据它拒绝任何东西。UI 的 JSON 提交前体检只剩结构性条目（越组绑定、别名撞自身 target、
   非正整数等），**只报错不改数据**，后端仍是权威。

`ctx_cap`（实现 `config_store/readers.lua`，`config_store.lua` facade re-export）的生产读者只有展示面两处，
两处都不影响任何转发字节：

- `props.lua` 的 `with_ctx`（挂载点 `/props` 与管理台读法 `/u/props`）把回显的 `n_ctx` /
  `n_ctx_train` 换成操作员声明值，让 llama.cpp webui 显示声明的窗口；
- `router/models_api.lua` 的 `resolve_model_caps` 拿它当 `capabilities.context_length` 的**声明层**
  读数（操作员声明优先于引擎自报）。

函数里那道「入口名命中 virtual_profiles / virtual_models 时返回 nil」的守卫仍在（入口名不是卡片名），
随它一起降级为只读用途。`virtual_ctx_cap` 实现原样保留、`test/unit/test_profiles.lua` 仍钉着，
**热路径无调用者**。

## 5. /v1/models 广告

> 完整字段表与来源优先级见 README〈`/v1/models` 的模型对象形状〉。本节登记**入口那一行**的口径。

- **官方四字段是 required**：每条（真实模型行与入口行）都带齐 `id` / `object` / `created` / `owned_by`。
  `created` 取上游答里的读数，取不到用常量 `MODEL_CREATED_UNKNOWN = 0`（`router/models_api.lua` 顶部），
  入口行恒 0；**不塞 `ngx.time()`**——同一条目每次请求产出不同字节，等于打掉客户端缓存与前后对比。
- **`owned_by` 全表恒为网关自身 `"lua-router"`**（2026-10-11 裁定）：真实模型行、单目标入口行、
  多目标入口行同一常量，不带目标名，也没有 `owned_by_models`（整个字段退役：入口对外只以 `id`
  表达，覆盖哪几个实际模型是网关侧路由知识，由 `/workers` 与声明层负责）。理由：带目标名的写法会把
  池子里的模型名泄给任何能读 `/v1/models` 的客户端。引擎自报的 `owned_by`（含 `local`）照旧采进
  `registry.model_caps` 留档，永不上外。**客户端不许拿 `owned_by` 当判别位**（全表同值），也不能把
  `created == 0` 当入口的充分判据（真实行取不到上游读数时同样落 0，0 只说明「这行没有引擎读数背书」）；
  要区分入口行按 `id` 查声明层名册（`/config` 的 `virtual_models`）。
- **扩展字段收在 `capabilities` 命名空间**，旁挂 `supports_reasoning_effort` / `reasoning_effort` /
  `reasoning_efforts` 三个 opencodex 位置上的键（都不是官方字段，官方 SDK 只读那四个 required）。
  填充纪律是 **操作员 config 声明 > 引擎自报 > 整个键省略**；省略是删键——不写 `null`、不写空数组
  （`[]` 是一份「一个都不支持」的肯定答复，而这里要表达的是不知道）。
- **入口的能力从组内实际模型聚合，只在整组口径一致时对外声明**（`router/models_api.lua` 的
  `advertise_virtual_entry`，安全理由：一组由该入口**不控制**的引擎提供服务）。数值取最窄
  （`narrowest_number`），**任何一台没有读数就整个删键**——跳过没读数的那台，就会把已知的那些当成
  全部，广告出比部分成员能承受的更大窗口。支持位要求每台都报且一致（`common_boolean`）；picker 阶梯
  要求每台**序列完全一致**（`common_ladder`——并起来会造出「在另一台上会被拒」的选项）；判定面取交集
  且必须含缺省档（`common_acceptance`）。任何一支凑不齐就删键。
  **单成员入口例外**：它就是那台引擎本身，读数原样透传（含上游自己「缺省档不在判定面里」那种自相矛盾），
  免得同一个模型在它的真实行与入口行上说出两种能力。
- 入口对外声明的 `context_length` 优先取条目自己写的 `context_window`（§4 第 2 条），其次才是组内各
  实际模型读数取最窄。`context_length` **两份并存**（模型对象根层一份给直接读顶层的客户端，
  `capabilities` 内一份，同一读数来源、值必然一致）；`max_output_tokens` 仍只在 `capabilities` 内。
- **档位在上游有两种拼写、两个含义，各画各的**：picker 的 `reasoning_efforts`（带 `label` / `default`）
  画在顶层，判定面 `capabilities.reasoning_effort` 画在命名空间里，用引擎亲口说的可接受集合，
  **不把阶梯里的档位虚构进判定面**（实测样例两份就不一致：阶梯 low/medium/high/max，判定面只有
  low/high/max）。

### 5.1 能力数据的两个来源，以及 registry 侧为什么不读上游的 `context_window`

- **操作员声明层**（`router/models_api.lua` 的 `resolve_model_caps` 读 `config_store` 快照）：卡片
  `max_output_tokens` 经同文件的 `declared_max_output_tokens`（卡片优先、平铺 `model_max_output_tokens`
  兜底）；卡片 `modalities`（`config_store` 的 `modalities_for`，实现在 `config_store/readers.lua`）；
  缺省档位取 `model_effort` 强制行 → 卡片 `default_effort` → 全局 `default_effort`。
  `context_length` 只由操作员声明（`store_mod.ctx_cap`）优先于引擎自报决定，两者都无则删键。
- **引擎自报层**：worker 自己 `GET /v1/models` 的回答。`registry.probe_advertised_entries()`
  （`registry/discovery.lua`）与覆盖探针**共用一次 GET**——「探到了哪些模型」与「它们各自能干什么」
  永远来自同一份回答，不会出现「列表说三条、能力说一条」的分裂。原文经 `model_caps_from_listing()` →
  `model_caps_from_entry()`（两者在 `registry/caps.lua`）归一，跨 worker 汇总走 `registry.model_caps()`
  （`registry/discovery.lua`）：字段互补两边都留，值冲突取信息最全的**整条**读数，定序只看内容与
  完整度、不看写入顺序（否则对外读数随调度抖动）。SGLang 只报 `max_model_len`（映射成
  `context_length`），opencodex 报整套 `capabilities`。字段级来源序是 `capabilities.*` >
  条目顶层同名字段 > `max_model_len`——按「上游说得有多明确」排。
- **能力读数只认证「引擎亲口答过」**：`model_caps` 与 `models` 同批落地、共用 `models_replace` 那枚
  印章（`registry/records.lua`），取用侧先过 `record_model_caps`（`registry/discovery.lua`）里的
  `models_are_verified` 判定。**配置声明的名字不贡献能力读数**——否则操作员写的一个名字会被当成
  引擎的能力陈述往外报。
- **刻意不读上游条目的顶层 `context_window`**（`registry/caps.lua` 的注释钉住）：那是**本网关配置层**
  的字段名（入口对外声明的总窗口，见 §4 与 AGENTS.md 2026-10-04 裁定块）。把它和引擎读数混成一个
  字段，就是把「对外声明的总窗口」当成「引擎的单次输出能力」，两者不可比。
- **`supports_vision` 的正负向不对称**：registry 归一层**从不**反推它（`registry/caps.lua` 的
  `model_caps_from_entry`——引擎少写一列很常见，据此替上游编话不如少一个字段）；输出层
  （`router/models_api.lua` 的 `resolve_model_caps`）只允许**正向**反推——模态里列了 `image`/`video`
  就报 `true`，这份模态来自引擎还是操作员都一样；**负向**（报 `false`）只在操作员声明时给，因为只有
  卡片的模态是穷尽列表（写入路径把 `text` 常开、空列表落成 `{"text"}`，在 `config_store/mutators.lua`
  的 `apply_model_config`），此时「没列 image」才是操作员说了「不收图」。引擎自报的列表缺 image
  只能读作「没说」。
- 采集失败不改健康位、不摘 worker（AGENTS.md 硬规则 4：转发路径上的探测只损失精度）。整表读不出东西时
  `model_caps()` 返回空表，输出面的扩展字段整体省略，条目退回官方那四个 required 字段。

### 5.2 别和 `GET /u/v1/models` 搞混

`ui.models()`（`lualib/resty/luarouter/ui.lua`，挂载点 `GET /u/v1/models`）是管理台模型选择器用的
**另一份**列表：每条恒 `created: 0`、`owned_by: "lua-router"`（与 `/v1/models` 同口径，不携带任何
上游模型名），另带 `status.value`，只用来枚举候选名，**不承载本节任何能力读数**。
两者 `created` 不是一回事：picker 每行恒 0（不采上游读数），`/v1/models` 的真实行取上游读数、
取不到才落 `MODEL_CREATED_UNKNOWN = 0`，入口行恒 0。
管理台在站点根 `/`（admin 迁根 2026-10-08）；`/_ui/*` 整片落 404 sink。

## 6. 同名遮蔽：入口名 == 某个实际模型名

现行规则（2026-10-07 裁定，**同名即遮蔽，入口赢**）：

- 入口名叫 X 时，所有 `model=X` 的请求一律走该入口的 `targets`；实际模型 X 不再单独可达，只作为
  targets 的落点被入口调度。广告面 `/v1/models` 里 X 恰好一行（入口行），真实 X 那行整行摘掉
  （`router/models_api.lua` 的遮蔽段：先按名册建「哪些名字是入口」的集合，再在同一处摘真实行、补入口行；
  判据是**纯查表**不用 `pairs()`，同一份配置连查两次产出逐字节相同的响应）。判据精确到 `id` 相等——
  组内成员名不参与，否则「Y 也被某入口映射」会误删 Y 那行。
- `/workers` 仍能看见那台 worker（运行态事实，与「客户端不可达」是两件事）。
- 转发体的 model 仍是**真实引擎模型名**（`lr_bound_model`）：遮蔽下 binding 可以合法等于 X
  （引擎认识 X），但转发字节必须正确。
- 配置面允许建这样的入口，判据是**引擎背书**而不是操作员打的字：`config_store/profiles.lua` 的
  `engine_attested_models` = 各记录 `record_models` ∩ `models_are_verified`（引擎亲口答过 `/v1/models`
  才算，没探过 = 不算），与选路侧 `candidate_allows_model` 同一套口径。四处写入守卫（写过的 target、
  派生代表值、组内成员、绑定名）共用唯一判据 `may_shadow_own_name`：**只放行自己的名字**
  （`name == alias` 且引擎背书），别人的入口名永远不放行（那仍是链式转发）。registry 缺席时返回空集，
  四处守卫逐字退回「探不着的名字按严格语义拒绝」。
- **磁盘快照的读路径不查引擎读数**（`new_shadow_context{reload=true}` 直接放行同名落点）：这条路径
  同时是「把已落盘的配置读回来」，在那里新增拒绝会让一份当年合法的配置在某次巡检空档后整体读不
  回来，而 `current()` 读不回配置就**整份退回 env 默认**——等于把全部配置抹平。判据只在写入侧
  （`apply_profiles` / 整文档 `apply_document`）说话。
- 遮蔽入口的容量/档位/上下文窗口全部配在**入口**上，落到选中实例。给同名入口写卡片不是死配置：
  `ctx_cap` 与四处写入守卫共用同一套引擎读数（`config_store/readers.lua` 注释钉住）。

## 7. upstreams 声明层

一条 upstream 行 = 一个持久化的池成员：

| 字段 | 说明 |
|---|---|
| `url` | http(s)://host[:port]，`registry.normalize_url` 规范化后作为稳定身份 |
| `model_id` | 上游主模型 id（缺省 unknown） |
| `models` | 该实例对外提供的模型名数组（非数组 400）。drift 判定用**子集**而非相等——registry 是折叠写，相等判定会让 30s 自愈每轮重写、永不安定 |
| `api_key` | 回显恒为 null；写入三态：缺席/null=保持、""=清除、非空=设置 |
| `priority` / `cost` / `labels` / `disable_health_check` | 同 POST /workers |
| `min_concurrency` / `max_concurrency` / `max_gpu_util` | 每服务容量三字段，见 [gap-worker-caps.md](gap-worker-caps.md) §2 |

**reconcile**（写请求内同步 + worker 0 定时器 30s 自愈，按 config revision 比对）：

- url 不存在 → `registry.add({..., discovery=config})`
- url 存在且 `discovery==config` → 更新上述字段
- url 存在但来源不是 config（watcher / 手工 / bootstrap）→ **不覆盖身份与调度意图字段**，摘要报
  skipped；三档上限走 caps-only 投影例外（gap-worker-caps.md §10 第 4 项）
- 从 upstreams 移除 → 只删 `discovery==config` 的池成员，其余永远不碰

**上限的事实来源是声明层**：`upstream_drifts` 会把 `max_*` 连同 priority/cost/labels 一并比较，
所以运行态 `PUT /workers` 改的值会在 30 秒自愈里被声明值写回。UI 侧已把声明态行的运行态编辑
入口整体锁死并用徽章明示，避免「改了却被撤销还找不到原因」。

## 8. 兼容周期

per-alias `policy` / `effort` 的停用是**读侧**的（热路径不读），**写侧照旧接受并往返**：
导出的旧配置不会立刻失效，同时新语义下它们不生效，解析时 warn 让操作员看得见。
全局与模型级的那套**不受影响**，优先级更高：

- effort：`model_effort`（按落点模型名）→ 模型卡 `model_configs[].effort`
- policy：`model_policies`（**按虚拟入口名**，因为策略实例的 key 就是入口名）→ 全局 `policy`

## 9. JSON 编辑（现位于 `ui/admin/models.html` 的「配置 JSON」对话框）

`/config` 的 JSON 视图是权威面：

- `vmRow` **不再白名单取键**，未知键与形状非法的已知键一律进 `row.extra` 原样带回——
  否则「打开 JSON 视图 → 应用」会静默清空新字段。
- `targets` chip 编辑器 + `context_window` 输入（对外声明的上下文总窗口，只做正整数校验，
  不与任何读数比较）；模型卡对话框另有 `max_output_tokens` 输入与卡片表同名列（「最大输出 token 数」，
  §4 第 3 条），读数口径 `maxOutputTokensOf`（卡片优先、平铺 `model_max_output_tokens` 兜底）与后端
  `declared_max_output_tokens` 一致；per-alias policy/effort 的编辑器已撤除，但**序列化仍无损**。
  JSON 对话框的可编辑段含 `model_max_output_tokens`。
- 提交前只做结构性中文体检（越组绑定、别名撞自身 target、`context_window` 非正整数等），
  **只报错不改数据**，后端仍是权威。

## 10. 已知限制

1. 组内某模型「一台已验证实例都没有」时，选中它的请求会 503，文案点名
   `healthy engines serve none of the mapped models`。预防要靠注册侧强制 `/v1/models` 背书，
   属 watcher 纪律。
2. 入口名与它映射的真实模型名**可以同名**（遮蔽，§6；只禁入口名等于自己组内**未被引擎背书**的名字、
   或等于另一个入口名）。两个入口共享同一组模型能正确分树，但给其中一个配 per-model 覆盖时只命中
   入口名那一行——语义正确但容易看错。
3. `LMR_VIRTUAL_MODELS` env **未扩展**多 target 语法（`alias=target` 逗号对无法无歧义表达多值，
   宁可不提供也不静默忽略）。env 用户拿 1 对多只能走 `LMR_CONFIG_FILE`。
4. `disable_health_check` 的 worker（含全局关巡检）永不进 `discover()`，永不获得引擎背书 →
   多绑定只能靠 config 行显式声明 `models`。
5. watcher 注册当刻只有主模型（全量 `models` 靠下一轮 `discover` 的 `refresh_models` 补齐）。
6. mesh 集群视图不同步 `models`，多网关下各节点的覆盖度可能不一致。
7. `/config/apply` 是**整表替换**：只发一段会把其它段清空。
8. 入口级策略覆盖的替代入口是 `model_policies`（按入口名）。`policy_document` 已把虚拟入口名
   补进行集，否则路由策略页永远列不出入口那一行。
9. 条目级 `max_output_tokens` 是**尚未接线的声明位**（§2 表内说明）：能配、能往返，广告链不读它。
