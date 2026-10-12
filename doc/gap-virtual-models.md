# 虚拟模型（服务入口）· 服务接入(upstreams) · JSON 编辑

日期：2026-10-01 首版；**2026-10-02 语义反转重写**；**2026-10-04 改输出预算口径**（§1 第 3 条、
§2 字段表、§4 整节重写）；**2026-10-04 再扩容 §5**（`/v1/models` 的官方四字段与 `capabilities` 扩展，字段表与两个数据源另见 README〈`/v1/models` 的模型对象形状〉）。决策人：用户。
**2026-10-12 收尾**：按锚定纪律（doc/agent-handover.md §3 第 8 条）清全文「文件:行号」锚点、改「文件 + 函数名」；
§2 按现行代码扩条目声明位表（2026-10-11 裁定 A）；§5.2 / §8 / §4.2 的接口名统一到 admin 迁根后的根路径。

## 1. 语义（用户裁定，以此为准）

> 虚拟模型是**日常服务的主入口**，可以**映射多个实际模型提供服务**，通过**调度策略**调度到不同的
> 实际模型上，是 **1 对多**的关系，**只能配置模型上下文长度覆盖（context-window）**，以便对下游保持统一。
>
> 2026-10-04 澄清（用户）：这里的「统一」是**声明**统一——同一个入口对外广告同一个窗口读数；**不是**
> 把调用方的 `max_tokens` 改成统一值。网关对输出预算一个字段都不改写，现行规则见 §4。
>
> 2026-10-11 之后这句「只能配置 context-window」的原始表述已扩：条目上可写的是一组**声明位**（见 §1 第 3 条与 §2 表），
> 其中参与窗口广告的仍只有 `context_window`；被排除的一直是 `policy`（会裂亲和树）。

三点含义，缺一不可：

1. **虚拟名是对下游暴露的服务入口**，客户端只认它。它是**最常用的配置**，UI 上放在导航第一位
   （页面名「模型管理」）。
2. **1 对多**：一个虚拟名映射一组实际模型（`targets[]`）。这些实际模型可以来自**不同的上游服务**
   （同机不同实例、跨机远程都行）。流量由**调度策略在这一组内选路**——不是按绑定名硬选一个。
3. **条目级只允许「声明位」，`policy` 不在其中**：条目上可写的是一组对外**声明**——`context_window`
   （入口对外声明的上下文总窗口，输入+输出，客户端据此决定何时压缩）以及 `max_output_tokens` /
   `default_effort` / `effort_map` / `modalities` / `hidden` / `disabled` / `api_key`，逐字段口径见 §2 的表。
   `context_window` 是「对下游保持统一」的那个统一量：同一个入口，无论策略选中组内哪台实例，广告出去的
   窗口都是同一个数；**它不参与任何 max_tokens 计算**（2026-10-04 裁定；旧口径与废止理由见 §4）。
   条目位一律不改写转发字节。**为什么 `policy` 被排除**：策略实例的 key 就是入口名、一入口一棵亲和树，
   条目里再嵌一份 policy 会让同一个入口长出两棵树（裂亲和树）；effort 不建树，所以 2026-10-04 裁定以
   映射表的形式放行到入口，2026-10-11 裁定 A 之后它是入口上唯一的一张 effort 强度映射表。

per-alias 的 `policy` 与 `effort` **已停用**（2026-10-02，**别当 bug 修**）：仍接受、仍落盘、解析时 warn，
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
| `context_window` | 正整数 | 否 | 入口对外声明的上下文总窗口（输入+输出），供客户端决定何时压缩；条目声明位里**唯一参与「窗口广告」**的一位。**不改写任何输出预算**（2026-10-04 裁定）；原先挂在它身上的配置期校验（须严格小于组内各卡片读数）已于 2026-10-08 移除，前后端都只做正整数校验 |
| `max_output_tokens` | 正整数 | 否 | 2026-10-11 用户裁定新增的**入口级单次输出预算声明**位：纯对外 advertisement，**不参与任何校验、钳制或 max_tokens 运算**（口径与卡片格一致，见 §4 第 3 条）。**当前配置可解析、可落盘往返，但广告链尚未消费此声明**：入口行的 `capabilities.max_output_tokens` 只由组内聚合得出（`router/models_api.lua` 的 `advertise_virtual_entry` 走 `narrowest_number(rows, "max_output_tokens")`），真实模型行的 `declared_max_output_tokens` 只读取卡片与平铺声明；条目层的 `max_output_tokens` 尚未接入广告链。因此这是尚待接线的实现缺口，**不是**与 `policy` / `effort` 同款的刻意兼容行为（后两者「接受、往返、解析 warn、热路径不读」有 2026-10-02 用户裁定，不能据此推定本字段的状态）。接线前，配置该条目字段不会改变 `capabilities.max_output_tokens` 的输出；未来如何安排接线与优先级需另行设计，本文不预设顺序。 |
| `default_effort` / `effort_map` | string / 映射表 | 否 | 2026-10-04 裁定把 effort 放行到入口；2026-10-11 裁定 A 之后入口**只保留这一张强度映射表**：对外的 reasoning 声明全部由这张表推导，缺省即 from==to 恒等透传。推导落点以源码为准（`router/models_api.lua` 的 `effort_advertise.derive` 与 `fill_model_fields`）：根路径 `supports_reasoning` / `supports_reasoning_effort` / `default_reasoning_effort` 三个位 + 顶层 `reasoning_efforts`（picker 形状）+ `capabilities.reasoning_effort`（判定面）；需求原文点名的根路径 `supported_reasoning_efforts` 已由 `9d8ea2b` 移除，引这条裁定时别照抄那张旧字段表（见 [docs-cleanup-2026-10-12.md §1.1](docs-cleanup-2026-10-12.md) 第 1 条） |
| `modalities` | string[] | 否 | 模态声明，参与 `capabilities.supports_vision` 的正/负向推导（不对称口径见 §5.1） |
| `hidden` / `disabled` | 三态布尔 | 否 | 2026-10-09 裁定：`hidden` = 这个名字不进 `/v1/models`（照常服务），`disabled` = 这台实例连被发现的资格都没有。**不是对外能力读数**，读法只有 `config_store/readers.lua` 的 `model_is_hidden` / `model_is_disabled` |
| `api_key` | string | 否 | 条目级密钥三态：缺席 = 保持、`""` = 清除、非空 = 设置。明文只活在 profile 里，回显抹掩码，比对在库内（`readers.entry_api_key_matches`）。五条裁定的并入文本见 [docs-cleanup-2026-10-12.md §1.1](docs-cleanup-2026-10-12.md) |
| `policy` / `effort` | string | 否 | **已停用**（2026-10-02 裁定，别当 bug 修）：仍接受、仍往返落盘、解析 warn、热路径不读 |

`targets` 与 `candidates` 至少要有一个，否则 400。

上表的声明位由 `config_store/profiles.lua` 的 `build_entry_declarations` 统一装配（`context_window` 与
`max_output_tokens` 走 `profile_from_entry` 里的 `build_context_window` / `build_max_output_tokens`）：
**缺键 / null = 不覆盖**（与「说了 false」严格分开，装配路上绝不合并），写了非法值整条入口 **400**，
逐字段往返无损。

**入口层的五张独立 `supports_*` 布尔位已于 2026-10-11 裁定 A 拆除**：`supports_tool_use` /
`supports_streaming` / `supports_reasoning` / `supports_vision` / `supports_reasoning_effort` 从配置层与
解析里一并去掉，**不留「接受但忽略」的兼容支**（与上面 `policy` / `effort` 那两位的裁定刻意相反），
老配置残留的布尔会在下一次落盘时自然消失。拆的理由是「显式声明说 false、effort 映射又说 true」这种
自相矛盾不该存在：对外读数改由 **effort 映射表与 `modalities` 推导**（推导事实见 `config_store/profiles.lua`
的 `effort_facts`，字段合成在 `router/models_api.lua`），保留一条能覆盖推导的旁路等于给每条推导再配一个开关。
**卡片层（`model_configs`）的同名字段不在拆除范围**：它说的是落点引擎自己，继续按「声明 > 引擎自报 > 省略」说话。

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

**现行规则（用户裁定 2026-10-04 推翻 2026-10-02 的「统一钳制」定义；第 3 / 4 条由用户裁定 2026-10-08 改写）**：

1. **网关不改写调用方的输出预算。** `max_tokens` / `max_completion_tokens` / `/v1/responses` 用的
   `max_output_tokens` 一律原样透传：调用方给多少转发多少，调用方没给时网关也不替它填一个数。
   引擎因此拒掉的，一定是调用方自己要的数，不会是网关造的数。
2. **`context_window` 是入口对外声明的上下文总窗口（输入+输出）**，作用是让客户端更早触发压缩。
   它不参与任何 max_tokens 计算，只保留解析（`config_store/profiles.lua` 的 `build_context_window`，
   由同文件的入口装配 `profile_from_entry` 调用）、落盘、往返与 UI 展示。
3. **模型卡片上的输出预算声明**（用户裁定 2026-10-08：字段名 `context_limit` → `max_output_tokens`，
   旧名那句「服务实际能承受的上下文限制」连同它冒充上下文窗口的用途一起作废）＝**声明给下游 agent 的
   单次最大输出 token 数**，是一份纯对外 advertisement：唯一去处是 `/v1/models` 的
   `capabilities.max_output_tokens`（操作员声明压过引擎自报），**不参与任何校验、钳制或 max_tokens 运算**，
   也不声称引擎的真实能力。卡片写法 `model_configs[].max_output_tokens`，平铺写法
   `model_max_output_tokens` / env `LMR_MODEL_MAX_OUTPUT_TOKENS`，卡片优先于平铺层（写了卡片就清掉同模型的平铺行）。
   `context_length` 与此无关：它只由两档决定——操作员声明的窗口（卡片 `ctx` / 平铺 `model_ctx`，经
   `config_store.ctx_cap`）**优先于**引擎自报，两者都没有就整个键省略。
4. **不再有「声明窗口 vs 输出上限」这类配置期校验**（用户裁定 2026-10-08）：条目的 `context_window` 是
   上下文总窗口，卡片的 `max_output_tokens` 是单次输出预算，两个量不可比，拿一个判另一个就是重犯下面 §4.2
   那次把三个量当一个数的错误。原 `config_store.validate_declared_context_windows`（挂在 `apply_profiles` /
   `apply_document` 两条写入路径上）连同 UI 侧同款前端预校验已一并移除：`context_window` 只做解析 / 落盘 /
   往返 / 展示，网关与 UI 都不据它拒绝任何东西。

### 4.1 校验的实现口径（该校验已于 2026-10-08 移除，以下保留以说明它当初的口径）

以下段落里的 `context_limit` / `model_context_limit` / `LMR_MODEL_CONTEXT_LIMIT` 都是**当时的字段名**：
该字段已于 2026-10-08 改名 `max_output_tokens`（平铺 `model_max_output_tokens` / env
`LMR_MODEL_MAX_OUTPUT_TOKENS`），语义也从「服务实际能承受的上下文限制」改为「声明给下游 agent 的单次最大
输出 token 数」。原样保留只为说明这道已删校验当初读的是什么。

`validate_declared_context_windows`（函数本体已随裁定删除，当初住在 `config_store` 内）：

- 判定范围 = 这个入口的服务组；没有组的单绑定行退到代表值 `target`。
- 读数与 `ctx_cap` 同形状：卡片 `context_limit` 优先，其次平铺 `cfg.model_context_limit`；env 层
  `LMR_MODEL_CONTEXT_LIMIT` 在 env 装配 `cfg_from_env`（`config_store/snapshot.lua`）里抓取，且必须列进
  名册 `ENV_NAMES`（`config_store/env.lua`），否则 nginx 把它从 worker 环境里剥掉、worker 读到 nil。
- 组内多个读数取**最小值**：一组由该入口不控制的引擎提供服务，只有按最窄那台才算安全。
- 比较是**严格小于**：声明值等于真实限制同样拒绝（整窗占满 = 没有余量）。
- 只在两条**入口写入**路径上调用：`apply_profiles` 与 `apply_document`（两条都住在
  `config_store/mutators.lua`）。两处刻意不判：`cfg_from_document`
  同时是磁盘快照的读路径，在那里拒绝会让一份已落盘的配置在下次 reload 整体退回 env 默认；
  `apply_model_config`（`config_store/mutators.lua` 的卡片写入）是操作员**登记引擎真实读数**的动作，拦下它就等于
  「因为有坏入口所以永远记不下它能装多少」，把修复顺序堵死。
- 卡片与平铺行是同一个读数的两种拼法：`apply_model_config` 写了卡片的 `context_limit` 就清掉平铺那行
  （同一次 `apply_model_config` 内的互斥清理），避免日后卡片清成 null 时校验悄悄改用一条没人再看作生效的旧数字。

UI 侧过去（`ui/admin/models.html`）复刻同一读数口径（卡片优先、平铺层兜底）做**保存前**提示：
声明窗口 ≥ 组内最小时让该字段报错并禁用「保存入口表」，卡片表另有一列「服务实际限制」，生效预览显示
「声明窗口 / 服务实际限制（组内最小值）」两行对比。**这套比较式预校验已于 2026-10-08 随上述后端硬拦一并移除**：
入口的 `context_window` 是对外声明的上下文总窗口，卡片那一格是单次输出 token 上限，两量不可比。现行 UI 里
卡片字段叫 `max_output_tokens`（输入框与表格列都是「最大输出 token 数」，读数口径 `maxOutputTokensOf`，与后端
`declared_max_output_tokens` 一致），它只作为对外广告读数回显与落盘，UI 不再拿它和 `context_window` 做任何比较，
`context_window` 本身只保留正整数校验。

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

代码现状：`apply_ctx_cap` 与 `entry_ctx_cap` 住在 `router/inference.lua`，保留为恒「无改写」的空壳导出
（`_M` 导出就在同文件末尾的 `_M.apply_ctx_cap` / `_M.entry_ctx_cap` 两行，`router.lua` 的 facade 原样
re-export），只为不破坏按名字引用它们的 UI 与文档契约；`config_store` 的 `ctx_cap` 与 `virtual_ctx_cap`
实现住在 `config_store/readers.lua`，由 `config_store.lua` 的 facade re-export，实现原样保留、
`test/unit/test_profiles.lua` 仍钉着它们，但**热路径已无调用者**。
转发热路径上只剩 `router/inference.lua` 的 `apply_effort_policy` 还在改写请求体。

`ctx_cap` 的读者只在展示面两处：`/props`（管理台读法在 `/u/props`，2026-10-08 admin 迁根）的
`props.with_ctx`（`lualib/resty/luarouter/props.lua`）用它覆盖回显的 `n_ctx` / `n_ctx_train`，
让 llama.cpp webui 显示操作员声明的窗口；另一处是 §5 的 `/v1/models`
合成层——`router/models_api.lua` 的 `resolve_model_caps` 调 `store_mod.ctx_cap` 拿它当 `context_length`
的**声明层**读数（操作员声明优先于引擎自报。用户裁定 2026-10-08：卡片那一格已改名 `max_output_tokens`、
只走 `capabilities.max_output_tokens`，不再参与 `context_length` 的决定，原先排在它之后的兜底环已删）。
两处都不影响任何转发字节。同理 `_M.ctx_cap` 里那道「入口名命中 virtual_profiles / virtual_models 时返回 nil」
的守卫仍在函数内，随它一起降级为只读用途：没有人再拿它决定转发体的数字。

## 5. /v1/models 广告（2026-10-04 形状扩容）

> 完整字段表、两个数据源与优先级见 README〈`/v1/models` 的模型对象形状〉。本节只登记**入口那一行**的口径
> （采集 commit 5978f28 + 合成 commit 5417bb8）。

- **官方四字段是 required**：每条（真实模型行与入口行）都带齐 `id` / `object` / `created` / `owned_by`。
  改之前真实模型那一支只有 `{id, object, owned_by}`，整个漏了 `created`，属于不合规。`created` 取上游答里的读数，
  取不到用常量 `MODEL_CREATED_UNKNOWN = 0`（`router/models_api.lua` 顶部），入口行恒 0；**不塞 `ngx.time()`**——同一条目每次请求
  产出不同字节，等于打掉客户端缓存与前后对比。
> **2026-10-11 用户裁定推翻下面两条对 `owned_by` 的定义（现行口径见本节末）：**单模型行
> `llm-router-><model>`、多模型行 `llm-router` + `owned_by_models` 均已退役，原文保留只为留痕。

- ~~**单模型行**保持 `owned_by = "llm-router->"..<model>`（契约钉死的 legacy 形状，逐字节不变）。~~
- ~~**多模型行**改标 `owned_by = "llm-router"` + `owned_by_models`（整组），供 UI 展示。真实模型行恒 `"local"`：
  引擎自报的 `owned_by` 是各家上游的说法，而有客户端在按 `"local"` 判「这是我方实例」。~~
- **扩展字段收在 `capabilities` 命名空间**，旁挂 `supports_reasoning_effort` / `reasoning_effort` /
  `reasoning_efforts` 三个 opencodex 位置上的键（都不是官方字段，官方 SDK 只读那四个 required）。填充纪律是
  **操作员 config 声明 > 引擎自报 > 整个键省略**；省略是删键——不写 `null`、不写空数组（`[]` 是一份「一个都不支持」
  的肯定答复，而这里要表达的是不知道）。
- **入口的能力从组内实际模型聚合，只在整组口径一致时对外声明**（`router/models_api.lua` 的 `advertise_virtual_entry`，
  同一个安全理由：一组由该入口**不控制**的引擎提供服务）。**数值取最窄（`narrowest_number`），且任何一台
  没有读数就整个删键**——注意这与 `virtual_ctx_cap` 判的不是同一件事：`virtual_ctx_cap` 判的是**操作员声明
  之间的冲突**（每台都给了数、只是不一致）；这里判的是**引擎能力未知**。跳过没读数的那台，就会把已知的那些
  当成全部，广告出比部分成员能承受的更大窗口。线上实证：235.t:8800 的 `Qn`（组 = `Q38-Flash-Next` +
  `kimi-code/k3`）曾报 `context_length: 1000000`，而 `Q38-Flash-Next` 那一半没有读数（`0bcda68` 修复）；
  支持位要求每台都报且一致（`common_boolean`）；picker 阶梯要求每台**序列完全一致**（`common_ladder`——并起来会
  造出「在另一台上会被拒」的选项）；判定面取交集且必须含缺省档（`common_acceptance`）。任何一支凑不齐就删键。
  **单成员入口例外**：它就是那台引擎本身，读数原样透传（含上游自己「缺省档不在判定面里」那种自相矛盾），
  免得同一个模型在它的真实行与入口行上说出两种能力。
- 入口对外声明的 `context_length` 优先取条目自己写的 `context_window`（§1 第 3 条：让客户端更早触发压缩
  的总窗口，**不参与任何 max_tokens 计算**），其次才是组内各实际模型读数取最窄。`context_length` 现在**两份并存**
  （用户裁定 2026-10-08）：模型对象根层一份（给直接读顶层的客户端），`capabilities` 内一份，同取一个读数来源、
  值必然一致；`max_output_tokens` 仍只在 `capabilities` 内。
- **档位在上游有两种拼写、两个含义，各画各的**：picker 的 `reasoning_efforts`（带 `label` / `default`）画在顶层，
  判定面 `capabilities.reasoning_effort` 画在命名空间里，用引擎亲口说的可接受集合，**不把阶梯里的档位虚构进判定面**
  （实测样例两份就不一致：阶梯 low/medium/high/max，判定面只有 low/high/max）。
- 「与真实 worker 同名则丢弃别名」这条规则守的是**入口自己的 id**，不会因为某个被映射的模型名
  与入口重名而误伤。

**现行口径（2026-10-11 用户裁定，推翻本节上面两条划线项）**：`owned_by` 全表恒为网关自身
`"lua-router"`——真实模型行、单目标入口行、多目标入口行同一常量，不带目标名，也不再有
`owned_by_models`（整个字段退役：入口对外只以 `id`（入口名）表达，覆盖哪几个实际模型是网关侧
路由知识，由 `/workers` 与声明层负责）。理由：`llm-router-><model>` 与 `owned_by_models` 会把
池子里的模型名直接泄给任何能读 `/v1/models` 的客户端。引擎自报的 `owned_by`（含 `local`）
依旧采进 `registry.model_caps` 留档，只是永不上外。判别位迁移：入口行与真实行的区分只剩
`created`（入口恒 0）与能力读数来源，客户端**不许**再拿 `owned_by` 当判别位。
入口行的能力聚合口径不受影响：被遮蔽引擎的读数仍经组内聚合成 `capabilities`，删掉的只是归属信息。

### 5.1 能力数据的两个来源，以及 registry 侧为什么不读上游的 `context_window`

- **操作员声明层**（`router/models_api.lua` 的 `resolve_model_caps` 读 `config_store` 快照）：模型卡片
  `max_output_tokens`＝**声明给下游 agent 的单次最大输出 token 数**（原名 `context_limit`，用户裁定 2026-10-08 改名；
  平铺写法 `model_max_output_tokens` / env `LMR_MODEL_MAX_OUTPUT_TOKENS`，卡片优先于平铺层，读数经同文件的
  `declared_max_output_tokens`）。它是纯对外 advertisement，**唯一去处**是 `capabilities.max_output_tokens`，
  不参与校验、钳制或 max_tokens 运算，也不声称引擎真实能力。
  卡片 `modalities`（`config_store` 的 `modalities_for`，实现在 `config_store/readers.lua`）；缺省档位取 `model_effort` 强制行 →
  卡片 `default_effort` → 全局 `default_effort`。
  `context_length` 这一维与此无关，只由两档决定：操作员声明的窗口（卡片 `ctx` / 平铺 `model_ctx`，经
  `store_mod.ctx_cap`）**优先于**引擎自报，两者都没有就整个键省略（原「卡片 `context_limit` 兜住引擎读数」那一环
  随改名删除——输出预算读数不再冒充上下文总窗口）。
- **引擎自报层**：worker 自己 `GET /v1/models` 的回答。`registry.probe_advertised_entries()`（`registry/discovery.lua`）
  与覆盖探针**共用一次 GET**——「探到了哪些模型」与「它们各自能干什么」永远来自同一份回答，不会出现
  「列表说三条、能力说一条」的分裂。原文经 `model_caps_from_listing()` →
  `model_caps_from_entry()`（两者在 `registry/caps.lua`）归一，跨 worker 汇总走 `registry.model_caps()`（`registry/discovery.lua`）：
  字段互补两边都留，值冲突取信息最全的**整条**读数，定序只看内容与完整度、不看写入顺序（否则对外读数随调度抖动）。
  SGLang 只报 `max_model_len`（映射成 `context_length`），opencodex 报整套 `capabilities`。字段级来源序是
  `capabilities.*` > 条目顶层同名字段 > `max_model_len`——顺序按「上游说得有多明确」排，不是按「我更喜欢哪个」。
- **能力读数只认证「引擎亲口答过」**：`model_caps` 与 `models` 同批落地、共用 `models_replace` 那枚印章
  （`registry/records.lua`），取用侧先过 `record_model_caps`（`registry/discovery.lua`）里的 `models_are_verified` 判定
  （`registry/records.lua`）。**配置声明的名字不贡献能力读数**——否则操作员在配置里写的一个名字会被当成引擎的能力
  陈述往外报。
- **刻意不读上游条目的顶层 `context_window`**（`registry/caps.lua` 的注释钉住）：那是**本网关配置层**的字段名
  （入口对外声明的总窗口，见 §4 与 AGENTS.md 2026-10-04 裁定块）。把它和引擎读数混成一个字段，等于重犯
  「把三个不同的量当成同一个数」的那次生产事故（`context_window=350000` 被凭空写进 `max_tokens`，而服务真实窗口
  262144）。
- **`supports_vision` 的正负向不对称**：registry 归一层**从不**反推它（`registry/caps.lua` 的 `model_caps_from_entry`——引擎少写一列很常见，
  据此替上游编话不如少一个字段）；输出层（`router/models_api.lua` 的 `resolve_model_caps`）只允许**正向**反推——模态里列了 `image`/`video`
  就报 `true`，这份模态来自引擎还是操作员都一样；**负向**（报 `false`）只在操作员声明时给，因为只有卡片的模态是
  穷尽列表（写入路径把 `text` 常开、空列表落成 `{"text"}`，在 `config_store/mutators.lua` 的 `apply_model_config`），此时「没列 image」才是操作员
  说了「不收图」。引擎自报的列表缺 image 只能读作「没说」。
- 采集失败不改健康位、不摘 worker（AGENTS.md 硬规则 4：转发路径上的探测只损失精度）。整表读不出东西时
  `model_caps()` 返回空表，输出面的扩展字段整体省略，条目退回官方那四个 required 字段。

### 5.2 别和 `GET /u/v1/models` 搞混

`ui.models()`（`lualib/resty/luarouter/ui.lua`，挂载点 `GET /u/v1/models`）是管理台模型选择器用的**另一份**列表：每条恒 `created: 0`、
`owned_by: "lua-router"`（2026-10-12 起与 `/v1/models` 同口径；旧值 `"llm-router"` 与入口行的
`llm-router-><model>` / `owned_by_models` 一并退役，picker 不再携带任何上游模型名），
另带 `status.value`，只用来枚举候选名，**不承载本节任何能力读数**。
admin 迁根（2026-10-08）后 `/_ui/*` 全部落 404 sink：`/_ui/v1/models` 回 404、`/u/v1/models` 回 200（生产 8800 实测）。

## 6. upstreams 声明层

一条 upstream 行 = 一个持久化的池成员：

| 字段 | 说明 |
|---|---|
| `url` | http(s)://host[:port]，`registry.normalize_url` 规范化后作为稳定身份 |
| `model_id` | 上游主模型 id（缺省 unknown） |
| `models` | 该实例对外提供的模型名数组（非数组 400）。drift 判定用**子集**而非相等——registry 是折叠写，相等判定会让 30s 自愈每轮重写、永不安定 |
| `api_key` | 回显恒为 null；写入三态：缺席/null=保持、""=清除、非空=设置 |
| `priority` / `cost` / `labels` / `disable_health_check` | 同 POST /workers |
| `min_concurrency` / `max_concurrency` / `max_gpu_util` | 每服务容量上限（现行三字段），见 [gap-worker-caps.md](gap-worker-caps.md) §2 与 §6。功率通道（`max_power_w`）已于 2026-10-09 整体移除（用户裁定：21.k 实测八实例瓦特读数恒同值、零区分度）；声明层残留的 `max_power_w` 按未知字段丢弃 |

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
> 本节的 JSON 视图整体迁到管理台模型管理页；`GET /config` 与 `POST /config/apply` 的语义不变。
> 2026-10-08 admin 迁根后这两个端点在站点根上（`/_ui/*` 无 302、无别名，一律落 404 sink）。

`/config` 的 JSON 视图是权威面：
- `vmRow` **不再白名单取键**，未知键与形状非法的已知键一律进 `row.extra` 原样带回——
  否则「打开 JSON 视图 → 应用」会静默清空新字段。
- `targets` chip 编辑器 + `context_window` 输入（口径：对外声明的上下文总窗口，不是钳制，只做正整数校验，
  不与任何读数比较）；模型卡对话框另有 `max_output_tokens` 输入（「最大输出 token 数」，用户裁定 2026-10-08，
  原名 `context_limit`「服务实际上下文限制」）与卡片表的「最大输出 token 数」列，语义是**声明给下游 agent 的
  单次最大输出 token 数**——纯对外 advertisement，只进 `/v1/models` 的 `capabilities.max_output_tokens`，
  不参与任何校验或钳制；读数口径 `maxOutputTokensOf`（卡片优先、平铺 `model_max_output_tokens` 兜底）与后端
  `declared_max_output_tokens` 一致；per-alias policy/effort 的编辑器已撤除，但**序列化仍无损**。
- 提交前只做中文体检（越组绑定、别名撞自身 target、`context_window` 非正整数等）**只报错不改数据**，
  后端仍是权威。原先的「声明窗口 ≥ 组内卡片输出上限最小值」这项前端体检与它对应的后端配置期硬拦
  （原 `validate_declared_context_windows`）已于 2026-10-08 一并移除（两量不可比，见 §4 第 4 条）。
  JSON 对话框的可编辑段含 `model_max_output_tokens`。

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
7. `/config/apply` 是**整表替换**：只发一段会把其它段清空。生产验证时踩过这个坑。
8. 入口级策略覆盖的替代入口是 `model_policies`（按入口名）。`policy_document` 已把虚拟入口名
   补进行集，否则路由策略页永远列不出入口那一行。
