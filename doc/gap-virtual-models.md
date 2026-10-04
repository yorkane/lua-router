# 虚拟模型（服务入口）· 服务接入(upstreams) · JSON 编辑

日期：2026-10-01 首版；**2026-10-02 语义反转重写**；**2026-10-04 改输出预算口径**（§1 第 3 条、
§2 字段表、§4 整节重写）；**2026-10-04 再扩容 §5**（`/v1/models` 的官方四字段与 `capabilities` 扩展，字段表与两个数据源另见 README〈`/v1/models` 的模型对象形状〉）。决策人：用户。

## 1. 语义（用户裁定，以此为准）

> 虚拟模型是**日常服务的主入口**，可以**映射多个实际模型提供服务**，通过**调度策略**调度到不同的
> 实际模型上，是 **1 对多**的关系，**只能配置模型上下文长度覆盖（context-window）**，以便对下游保持统一。
>
> 2026-10-04 澄清（用户）：这里的「统一」是**声明**统一——同一个入口对外广告同一个窗口读数；**不是**
> 把调用方的 `max_tokens` 改成统一值。网关对输出预算一个字段都不改写，现行规则见 §4。

三点含义，缺一不可：

1. **虚拟名是对下游暴露的服务入口**，客户端只认它。它是**最常用的配置**，UI 上放在导航第一位
   （页面名「模型管理」）。
2. **1 对多**：一个虚拟名映射一组实际模型（`targets[]`）。这些实际模型可以来自**不同的上游服务**
   （同机不同实例、跨机远程都行）。流量由**调度策略在这一组内选路**——不是按绑定名硬选一个。
3. **条目级只允许配 `context_window`**：入口**对外声明的上下文总窗口（输入+输出）**，客户端据此决定
   何时压缩。它是**唯一**的条目级覆盖字段，也是「对下游保持统一」的那个统一量：同一个入口，无论策略
   选中组内哪台实例，广告出去的窗口都是同一个数。**它不参与任何 max_tokens 计算**（2026-10-04 裁定；
   旧口径与废止理由见 §4）。

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
| `context_window` | 正整数 | 否 | **唯一允许的条目级覆盖**：入口对外声明的上下文总窗口（输入+输出），供客户端决定何时压缩。**不改写任何输出预算**（2026-10-04 裁定）；配置期必须**严格小于**组内各卡片 `context_limit` 的最小值，否则拒绝保存 |
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





## 4. context_window：对外声明的上下文总窗口（2026-10-04 改口径）

**现行规则（用户裁定 2026-10-04，推翻 2026-10-02 的「统一钳制」定义）**：

1. **网关不改写调用方的输出预算。** `max_tokens` / `max_completion_tokens` / `/v1/responses` 用的
   `max_output_tokens` 一律原样透传：调用方给多少转发多少，调用方没给时网关也不替它填一个数。
   引擎因此拒掉的，一定是调用方自己要的数，不会是网关造的数。
2. **`context_window` 是入口对外声明的上下文总窗口（输入+输出）**，作用是让客户端更早触发压缩。
   它不参与任何 max_tokens 计算，只保留解析（`build_context_window` `config_store.lua:561`，
   调用点 `config_store.lua:730` / `:732`）、落盘、往返与 UI 展示。
3. **`context_limit`（模型卡片）= 服务实际能承受的上下文限制**，即引擎真实能力，由操作员按引擎启动
   参数抄录（网关不从引擎自动读，也不校验抄得对不对）。卡片写法 `model_configs[].context_limit`，
   平铺写法 `model_context_limit` / env `LMR_MODEL_CONTEXT_LIMIT`，卡片优先于平铺层。
4. **配置期校验**：条目的 `context_window` 必须**严格小于**组内各卡片 `context_limit` 的最小值，
   否则**拒绝保存**；组内没有任何卡片声明读数 = 不知道引擎能力 = 不校验也不报错。

### 4.1 校验的实现口径

`validate_declared_context_windows`（`config_store.lua:1574`）：

- 判定范围 = 这个入口的服务组；没有组的单绑定行退到代表值 `target`。
- 读数与 `ctx_cap` 同形状：卡片 `context_limit` 优先，其次平铺 `cfg.model_context_limit`；env 层
  `LMR_MODEL_CONTEXT_LIMIT` 在 `config_store.lua:1201` 装配，且必须列进 `_M.ENV_NAMES`
  （`config_store.lua:216`），否则 nginx 把它从 worker 环境里剥掉、worker 读到 nil。
- 组内多个读数取**最小值**：一组由该入口不控制的引擎提供服务，只有按最窄那台才算安全。
- 比较是**严格小于**：声明值等于真实限制同样拒绝（整窗占满 = 没有余量）。
- 只在两条**入口写入**路径上调用：`apply_profiles`（`config_store.lua:2384`，调用点 `:2395`）与
  `apply_document`（`config_store.lua:2903`，调用点 `:2909`）。两处刻意不判：`cfg_from_document`
  同时是磁盘快照的读路径，在那里拒绝会让一份已落盘的配置在下次 reload 整体退回 env 默认；
  `apply_model_config`（`config_store.lua:2346`）是操作员**登记引擎真实读数**的动作，拦下它就等于
  「因为有坏入口所以永远记不下它能装多少」，把修复顺序堵死。
- 卡片与平铺行是同一个读数的两种拼法：`apply_model_config` 写了卡片的 `context_limit` 就清掉平铺那行
  （`config_store.lua:2367`），避免日后卡片清成 null 时校验悄悄改用一条没人再看作生效的旧数字。

UI 侧（`ui/admin/models.html`）复刻同一读数口径做**保存前**提示：`contextLimitOf`
（`ui/admin/models.html:1026`，卡片优先、平铺层兜底）。声明窗口 ≥ 组内最小时该字段报错并禁用「保存入口表」，
卡片表多一列「服务实际限制」，生效预览显示「声明窗口 / 服务实际限制（组内最小值）」两行对比，
不再有复刻钳制的推算。

### 4.2 已废止的旧口径（保留以解释现状）

2026-10-02 到 2026-10-04 之间，`context_window` 被定义为「对下游统一的 max_tokens 钳制」：显式条目值
恒定生效、完全不看选中实例，未配置且组 ≥2 时取整组卡片 `ctx` 的最小值，转发前用它改写 `max_tokens`。
废止原因不是它算得不一致，而是它把三个不同的量当成了同一个数：`context_window` 是总窗口，
`max_tokens` 是单次输出预算。

生产 21.k:8801 的故障形状：入口声明 `context_window=350000`，而该组引擎真实只装得下 262144
（SGLang 自报 `context_length` 524288，但反复告警 derived context_length 262144，模型 config 的
`original_max_position_embeddings` 同为 262144）。旧实现 `router.apply_ctx_cap` 的字段表只有
`{ max_tokens, max_completion_tokens }`，漏了 `/v1/responses` 的 `max_output_tokens`，于是 responses
入口上 `body.max_tokens` 恒为 nil → 命中「nil 就凭空写入 cap」那一支 → 每一个 responses 请求都被网关
塞进 `max_tokens=350000`；524288 − 350000 = 174288 恰好是失败阈值，故障体里
「350000 tokens for the completion」恒定不变、只有 input 在变。

代码现状：`router.apply_ctx_cap`（`router.lua:3256`）与 `router.entry_ctx_cap`（`router.lua:3263`）
保留为恒「无改写」的空壳导出（`_M` 导出在 `router.lua:4801` / `:4802`），只为不破坏按名字引用它们的
UI 与文档契约；`config_store._M.ctx_cap`（`config_store.lua:1937`）与 `_M.virtual_ctx_cap`
（`config_store.lua:1970`）实现原样保留、`test/unit/test_profiles.lua` 仍钉着它们，但**热路径已无调用者**。
转发热路径上只剩 `apply_effort_policy`（`router.lua:3160`）还在改写请求体。

`_M.ctx_cap` 的读者只在展示面两处：`/_ui/props` 的 `props.with_ctx`（`props.lua:129`，取值在 `props.lua:133`）
用它覆盖回显的 `n_ctx` / `n_ctx_train`，让 llama.cpp webui 显示操作员声明的窗口；另一处是 §5 的 `/v1/models`
合成层——`resolve_model_caps`（`router.lua:3744`）调 `store_mod.ctx_cap` 拿它当 `capabilities.context_length`
的**声明层**读数，而且排在卡片 `context_limit` **之前**（顺序见 §5.1）。两处都不影响任何转发字节。同理 `_M.ctx_cap` 里那道「入口名命中 virtual_profiles / virtual_models 时返回 nil」
的守卫仍在函数内，随它一起降级为只读用途：没有人再拿它决定转发体的数字。

## 5. /v1/models 广告（2026-10-04 形状扩容）

> 完整字段表、两个数据源与优先级见 README〈`/v1/models` 的模型对象形状〉。本节只登记**入口那一行**的口径
> （采集 commit 5978f28 + 合成 commit 5417bb8）。

- **官方四字段是 required**：每条（真实模型行与入口行）都带齐 `id` / `object` / `created` / `owned_by`。
  改之前真实模型那一支只有 `{id, object, owned_by}`，整个漏了 `created`，属于不合规。`created` 取上游答里的读数，
  取不到用常量 `MODEL_CREATED_UNKNOWN = 0`（`router.lua:3579`），入口行恒 0；**不塞 `ngx.time()`**——同一条目每次请求
  产出不同字节，等于打掉客户端缓存与前后对比。
- **单模型行**保持 `owned_by = "llm-router->"..<model>`（契约钉死的 legacy 形状，逐字节不变）。
- **多模型行**改标 `owned_by = "llm-router"` + `owned_by_models`（整组），供 UI 展示。真实模型行恒 `"local"`：
  引擎自报的 `owned_by` 是各家上游的说法，而有客户端在按 `"local"` 判「这是我方实例」。
- **扩展字段收在 `capabilities` 命名空间**，旁挂 `supports_reasoning_effort` / `reasoning_effort` /
  `reasoning_efforts` 三个 opencodex 位置上的键（都不是官方字段，官方 SDK 只读那四个 required）。填充纪律是
  **操作员 config 声明 > 引擎自报 > 整个键省略**；省略是删键——不写 `null`、不写空数组（`[]` 是一份「一个都不支持」
  的肯定答复，而这里要表达的是不知道）。
- **入口的能力从组内实际模型聚合，只在整组口径一致时对外声明**（`advertise_virtual_entry` `router.lua:3998`，
  同一个安全理由：一组由该入口**不控制**的引擎提供服务）。**数值取最窄（`narrowest_number`），且任何一台
  没有读数就整个删键**——注意这与 `virtual_ctx_cap` 判的不是同一件事：`virtual_ctx_cap` 判的是**操作员声明
  之间的冲突**（每台都给了数、只是不一致）；这里判的是**引擎能力未知**。跳过没读数的那台，就会把已知的那些
  当成全部，广告出比部分成员能承受的更大窗口。线上实证：235.t:8800 的 `Qn`（组 = `Q38-Flash-Next` +
  `kimi-code/k3`）曾报 `context_length: 1000000`，而 `Q38-Flash-Next` 那一半没有读数（`0bcda68` 修复）；
  支持位要求每台都报且一致（`common_boolean`）；picker 阶梯要求每台**序列完全一致**（`common_ladder`——并起来会
  造出「在另一台上会被拒」的选项）；判定面取交集且必须含缺省档（`common_acceptance`）。任何一支凑不齐就删键。
  **单成员入口例外**：它就是那台引擎本身，读数原样透传（含上游自己「缺省档不在判定面里」那种自相矛盾），
  免得同一个模型在它的真实行与入口行上说出两种能力。
- 入口对外声明的 `capabilities.context_length` 优先取条目自己写的 `context_window`（§1 第 3 条：让客户端更早触发压缩
  的总窗口，**不参与任何 max_tokens 计算**），其次才是组内各实际模型读数取最窄。
- **档位在上游有两种拼写、两个含义，各画各的**：picker 的 `reasoning_efforts`（带 `label` / `default`）画在顶层，
  判定面 `capabilities.reasoning_effort` 画在命名空间里，用引擎亲口说的可接受集合，**不把阶梯里的档位虚构进判定面**
  （实测样例两份就不一致：阶梯 low/medium/high/max，判定面只有 low/high/max）。
- 「与真实 worker 同名则丢弃别名」这条规则守的是**入口自己的 id**，不会因为某个被映射的模型名
  与入口重名而误伤。

### 5.1 能力数据的两个来源，以及 registry 侧为什么不读上游的 `context_window`

- **操作员声明层**（`resolve_model_caps` `router.lua:3744` 读 `config_store` 快照）：模型卡片 `context_limit`＝引擎
  真实能力（操作员按启动参数抄录；平铺写法 `model_context_limit` / env `LMR_MODEL_CONTEXT_LIMIT`，卡片优先于
  平铺层，`declared_context_limit` `router.lua:3649`）；卡片 `modalities`（`config_store.modalities_for`
  `config_store.lua:2002`）；缺省档位取 `model_effort` 强制行 → 卡片 `default_effort` → 全局 `default_effort`。
  注意 `context_length` 这一维**先问 `store_mod.ctx_cap`**（卡片 `ctx` / 平铺 `model_ctx`），它排在 `context_limit`
  之前（`router.lua:3747-3753`）：同一份声明层里 `ctx` 说话更响，`context_limit` 只在没有 `ctx` 时兜住引擎读数。
- **引擎自报层**：worker 自己 `GET /v1/models` 的回答。`registry.probe_advertised_entries()`（`registry.lua:2913`）
  与覆盖探针**共用一次 GET**——「探到了哪些模型」与「它们各自能干什么」永远来自同一份回答，不会出现
  「列表说三条、能力说一条」的分裂。原文经 `model_caps_from_listing()`（`registry.lua:1137`）→
  `model_caps_from_entry()`（`registry.lua:1020`）归一，跨 worker 汇总走 `registry.model_caps()`（`registry.lua:2966`）：
  字段互补两边都留，值冲突取信息最全的**整条**读数，定序只看内容与完整度、不看写入顺序（否则对外读数随调度抖动）。
  SGLang 只报 `max_model_len`（映射成 `context_length`），opencodex 报整套 `capabilities`。字段级来源序是
  `capabilities.*` > 条目顶层同名字段 > `max_model_len`——顺序按「上游说得有多明确」排，不是按「我更喜欢哪个」。
- **能力读数只认证「引擎亲口答过」**：`model_caps` 与 `models` 同批落地、共用 `models_replace` 那枚印章
  （`registry.lua:2729`），取用侧先过 `record_model_caps`（`registry.lua:2937`）里的 `models_are_verified` 判定
  （`registry.lua:2010`）。**配置声明的名字不贡献能力读数**——否则操作员在配置里写的一个名字会被当成引擎的能力
  陈述往外报。
- **刻意不读上游条目的顶层 `context_window`**（`registry.lua:1013` 的注释钉住）：那是**本网关配置层**的字段名
  （入口对外声明的总窗口，见 §4 与 AGENTS.md 2026-10-04 裁定块）。把它和引擎读数混成一个字段，等于重犯
  「把三个不同的量当成同一个数」的那次生产事故（`context_window=350000` 被凭空写进 `max_tokens`，而服务真实窗口
  262144）。
- **`supports_vision` 的正负向不对称**：registry 归一层**从不**反推它（`registry.lua:1016`——引擎少写一列很常见，
  据此替上游编话不如少一个字段）；输出层（`router.lua:3781-3787`）只允许**正向**反推——模态里列了 `image`/`video`
  就报 `true`，这份模态来自引擎还是操作员都一样；**负向**（报 `false`）只在操作员声明时给，因为只有卡片的模态是
  穷尽列表（写入路径把 `text` 常开、空列表落成 `{"text"}`，`config_store.lua:1529`），此时「没列 image」才是操作员
  说了「不收图」。引擎自报的列表缺 image 只能读作「没说」。
- 采集失败不改健康位、不摘 worker（AGENTS.md 硬规则 4：转发路径上的探测只损失精度）。整表读不出东西时
  `model_caps()` 返回空表，输出面的扩展字段整体省略，条目退回官方那四个 required 字段。

### 5.2 别和 `GET /_ui/v1/models` 搞混

`ui.models()`（`ui.lua:198`）是管理台模型选择器用的**另一份**列表：每条恒 `created: 0`、`owned_by: "llm-router"`，
另带 `status.value`，只用来枚举候选名，**不承载本节任何能力读数**。

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

## 8. JSON 编辑（现位于 `ui/admin/models.html` 的「配置 JSON」对话框）

> 2026-10-03：原 `ui/config.html` 已随根目录工具页移除（doc/ui-trim-legacy-pages.md），
> 本节的 JSON 视图整体迁到管理台模型管理页；`GET /_ui/config` 与 `POST /_ui/config/apply` 不变。

`/\_ui/config` 的 JSON 视图是权威面：
- `vmRow` **不再白名单取键**，未知键与形状非法的已知键一律进 `row.extra` 原样带回——
  否则「打开 JSON 视图 → 应用」会静默清空新字段。
- `targets` chip 编辑器 + `context_window` 输入（口径：对外声明的上下文总窗口，不是钳制）；模型卡
  对话框另有 `context_limit` 输入（「服务实际上下文限制」）与卡片表的「服务实际限制」列，读数口径
  `contextLimitOf`（`ui/admin/models.html:1026`）与后端校验一致；per-alias policy/effort 的编辑器已撤除，
  但**序列化仍无损**。
- 提交前只做中文体检（越组绑定、别名撞自身 target、`context_window` 非正整数、声明窗口 ≥ 组内
  `context_limit` 最小值等）**只报错不改数据**，后端仍是权威（配置期硬拦在
  `validate_declared_context_windows` `config_store.lua:1574`）。JSON 对话框的可编辑段含
  `model_context_limit`。

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
