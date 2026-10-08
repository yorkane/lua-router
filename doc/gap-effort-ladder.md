# 档位阶梯：探测 + 手动勾选（2026-10-08 执行契约）

> 用户诉求（2026-10-08）：「探测上游模型允许的 `reasoning_effort`: [low, medium, high, xhigh, max]，
> 允许手动修改添加或者取消 checkbox，反馈到 `/v1/models` 信息中」。
> 本节是这条诉求的实现口径；对外形状与优先级的一般纪律仍以 AGENTS.md 硬规则 9 与
> doc/gap-virtual-models.md §5 为准，README〈档位阶梯：探测 + 手动勾选〉是面向操作员的一节。

## 1. 三份读数，各有其主

| 记号 | 是什么 | 存在哪 | 谁读 |
|---|---|---|---|
| **detected** | 引擎原话：健康巡检顺带 `GET /v1/models` 采到的阶梯与判定面 | `registry.model_caps()`（`registry/caps.lua` 归一，跨 worker 按「整条最完整」合并） | 勾选框基线、判定面的唯一来源 |
| **declared** | 操作员勾选的档位表（成员 + 顺序 + 至多一枚预选） | 模型卡片 `model_configs[].reasoning_efforts`（平铺 env `LMR_MODEL_EFFORT_LEVELS`） | 对外 picker |
| **advertised** | `/v1/models` 合成结果 | 不落盘，逐请求算 | 客户端 |

**基线只能取 detected。** 这是本节唯一容易写错、且写错后不会有任何报错的地方：advertised 一旦被勾就是勾选
结果，若前端拿它当基线，操作员上一轮的勾选会伪装成「引擎说的」回来，于是**取消勾选永远回不到引擎原始那一组**
——表现是「怎么取消都还留着」，而每一格看起来都合理。所以 `/_ui/config` 的 `models[]` 同时带
`reasoning_efforts`（declared，null = 没勾过）与 `detected_reasoning_efforts`（引擎原话），两者永不合并，
前端只在打开卡片对话框时用后者铺基线（`ui/admin/models.html` 的 `openCard` / `detectedLadder`）。

## 2. 勾选接管 picker，判定面只收窄

档位在上游本来就有两份含义（doc/gap-virtual-models.md §5：实测样例里阶梯是 `low/medium/high/max` 而
`capabilities.reasoning_effort` 只有 `low/high/max`），勾选之后仍然各画各的：

* **picker（顶层 `reasoning_efforts`）= declared 整条替换**，成员与顺序都是操作员的。这是诉求里
  「手动添加」那一半：引擎没报 `xhigh` 也能勾上它，让欠配置的上游被网关侧补齐。
* **判定面（`capabilities.reasoning_effort`）= 引擎说过 ∩ 勾选集合**，只收窄不扩面。
  收窄是把引擎说过的事情少报一件（与旁边「组内取最窄」「宁可删键」同方向的保守），而扩面是替引擎宣称它接受
  一个它从没提过的档位名——硬规则 9 第 2 条明令禁止的那种猜。所以手动加的 `xhigh` 进 picker、不进判定面。
  引擎压根没给判定面时，判定面退到勾选序列（与改动前「退到阶梯序列」同一支路，只是序列换成了操作员那份）。
* **label 由引擎决定**：勾选只决定成员与顺序，每一档的 `label` 仍从 detected 的同名档位继承（一次勾选不该
  毁掉另一个字段），detected 没给过的名字不编 label。实现：`overlay_effort_ladder`。
* **预选（`default`）的定序**：`model_effort` 强制行 → 卡片 `default_effort` → **勾选表上操作员标的预选** →
  引擎自报字符串 → 阶梯自带的标记。勾选表上那枚是模型作用域的操作员声明，所以压过全局 `default_effort`；
  但两条**专职**字段赢它——它们就是为「哪档预选」这个具体问题存在的。勾选表一个预选都没标时，才继承引擎标的
  那一档（前提是该档仍在勾选集合里）。实现：`card_default_rung` 插在 `resolve_model_caps` 的 or 链里，
  收口仍由 `apply_default_ladder_rung` 保证「至多一枚 true」。

## 3. 三态与形状（写入层）

卡片字段 `reasoning_efforts` 与 `ctx` / `context_limit` / `default_effort` / 五个 `supports_*` 同一套写入语义：
**absent = 别动**，**null = 清除回自动**，**数组 = 整条替换**。值的形状由 `config_store/lexicon.lua` 的
`normalize_effort_ladder` 判定，两种拼法都接受并归一成 detected 阶梯的形状（`{value, label?, default}`）——
归一成同一形状的意义是对外读数里「操作员说的」与「引擎自报的」在客户端不可区分，客户端不必知道这个数字是谁给的：

* 字符串数组 `["low","high","max"]`（管理台勾选框发的就是这个）；
* 对象数组 `[{value,label,default}, ...]`（从 `/v1/models` 抄回来的那份）。

逐条：

* **未知档位名整条拒绝**（400，文案点名 `reasoning_efforts` 与八档词表），不悄悄丢档。一个拼错的名字会被客户端
  原样发给引擎并在那里 400，比保存失败难查得多；被拒的批次绝不落盘。
* **顺序按输入，不按词表重排**：阶梯是客户端 picker 的显示顺序，替他重排等于改他的声明。
* **重复名字去重**；重复条目上带 `default` 而已在表里的那份没带时，把标记补到已有那一档（丢标记会让 picker
  没有预选，补标记才是重排输入的本意）。
* **空数组折回 nil（= 自动），磁盘上不留 `[]`**。判定这条的理由是「同一份配置只能说一种话」：热路径
  `card_ladder` 对空表答的就是 nil（与 `clean_string_list` / `clean_effort_ladder` 同一口径——报 `[]` 是一份
  「一个都不支持」的肯定答复，而这里没有任何肯定可报），若写入层把 `[]` 存下来，磁盘上是一份、对外读数是另一份。
  因此「把勾全消掉」等同「从没勾过」，管理台也照这个口径把空勾选发成 `null`（`saveCard`），前端 chip 行与
  勾选框恒等。归一化器本身仍**保留** `{}`（`false` 只留给形状错误），把「形状判定」与「这一族的三态语义」分开，
  后者由唯一写入者 `merge_model_patch` 收口。
* **env 层**（`LMR_MODEL_EFFORT_LEVELS`）形状照 `LMR_MODEL_MODALITIES`：`model:low+medium+high`，多模型逗号
  分隔；值侧统一按「非字母」切（档位名只含字母，所以逗号 / 分号 / 空白 / 竖线都容忍，也不必操心转义）。
  整行洗不出任何档位 = 没说，不建卡；单个拼错的名字整件丢弃（env 层的垃圾值历来是忽略，不替操作员猜近似名）。
  该名字必须留在 `config_store/env.lua` 的 `ENV_NAMES` 里 —— 硬规则 11③：漏登记的现象是「配了但静默走未配置」，
  `test/integration/probes.py` 有一条断言专门钉它在 worker 里真的通。

## 4. 虚拟入口（1 对多）不变的那条仲裁

勾选不改组内口径：成员间阶梯序列不一致 → 入口行的 picker 整个删键（`common_ladder` 原有规则，并起来会造出
「在另一台上会被拒」的选项，勾不勾选都一样）；判定面逐成员按 §2 收窄后再取交集（`common_acceptance`）。
入口行的 `supports_reasoning_effort` 仍走 `common_declared_effort_support`：任何一位成员明确说 `false` 就是
`false`，要 `true` 则人人说 `true`，否则回到派生。

## 5. UI（`ui/admin/models.html` 卡片对话框）

* 一组 checkbox（`q-option-group type=checkbox`，与旁边模态同一控件）承载勾选；候选全集 = detected ∪ 本卡已勾 ∪
  八档词表，所以「手动添加引擎没报的档位」是能直接勾到的，而不是只能靠手改 JSON。
* checkbox 上方一行 badge 是**基线读数**：探测来的档位绿底、手动加的蓝底带 `+`、被取消的灰底标「已取消」。
  badge 的 ticked 一律读**当前勾选模型**而不是「自动态」标志位——自动态下模型里铺的就是引擎原话，此时把每一档
  标成「已取消」是谎话（操作员什么都没动）。
* 「设为缺省档」下拉只列当前勾选集合里的档位；取消预选所在那一档时把预选一起清掉（`syncEffortDefault`），
  否则界面上写的预选与磁盘上被后端收口后的预选会分家。
* 「恢复自动」发 `null`，并把勾选框重铺成引擎原话（不是清空——清空会被读成「操作员说要零档位」）。
* 卡片表新增一列：未勾过写「档位跟随上游」，勾过则画 chip（引擎来源绿底 / 手动加蓝底），空集合显式画出。
* 与 `supports_*` 那五位的区别要说清：那五位是**三态布尔**，必须用三态下拉（checkbox 的 `false` 与未填同值，
  画不出「不知道」）；这一族是**集合**，checkbox 恰好是对的控件，「不知道」由 `null` / 「恢复自动」表达。

## 6. 与转发链的关系：一个字节都不动

勾选只改 `/v1/models` 的对外声明与 `/_ui/config` 的编辑面。转发链上 `reasoning_effort` 的处理
（`router/inference.lua` 的三层查表改写、`ui.lua` 的空串清理）一律不读 `card.reasoning_efforts`：客户端照
picker 发什么，网关就照它的既有规则转什么，勾了引擎其实不收的档位，收到的是引擎自己的 400。这与 2026-10-04
裁定「网关不改写调用方的输出预算 / 意图」同向，也复用了 `ui/admin` 里已有的能力位披露话术（`declarationDisclosure`）。

## 7. 测试

| 层 | 位置 | 钉什么 |
|---|---|---|
| 存储 | `test/unit/test_profiles.lua` 12b 节（L1–L5，34 项） | absent/null/数组 三态写入；两种拼法归一；顺序不被词表重排；`default` 至多一枚 + 重复条目补标记；未知名整条拒且不落半截；空数组折回 nil；磁盘往返 + `card_effort_ladder` 返回拷贝；env 层装配 + `ENV_NAMES` 在册 |
| 输出 | `test/unit/test_models_shape.lua` G11 节（20 项） | picker = 勾选表（含顺序）；label 继承 / 不编；预选定序与专职字段压过勾选；判定面只收窄、手动加的档不进判定面；引擎无读数时勾选成为唯一来源；清除回自动后与 G4 同形；组内一台勾过 → 入口行删键、不牵连成员行 |
| 真 HTTP | `test/integration/e2e_models_advertisement.py` S12（20 项） | detected 经采集链路真的出现在 `/_ui/config` 卡片行（勾选框唯一的基线来源）；POST 勾选后对外字节真的变；400 不留半截状态；null 清除后逐字节退回引擎原话 |
| env 名册 | `test/integration/probes.py` | `LMR_MODEL_EFFORT_LEVELS` 穿透到 worker（漏登记 `ENV_NAMES` 即红） |

判别性（AGENTS.md 的「断言真会红」纪律）：同一组 G11 断言跑在改动前的 lualib 树
（`/data/tmp/lr-legacy-s12-a`，`git archive HEAD lualib`）上 **14/20 红** —— picker 仍是引擎那 4 档、
组行不删键、判定面不收窄。自动态那几条（G11「卡片没勾 = 跟随引擎」等）在旧实现下**应当**绿：它们钉的是
不许被坏掉的老契约，与 S7 那九档同理。

## 8. 明确不做的

* **不做条目级（虚拟入口）勾选**：组内一致口径已经决定入口行能说什么，条目级再开一张勾选表只会造出
  「入口勾了但组内成员各自不同」的第三种状态。档位是**落点引擎自己的说法**，与 `default_effort` /`context_limit`
  一样住在卡片。
* **不做 per-request 的档位校验 / 400**：见 §6。
* **不替引擎补 label、不替引擎扩判定面、不按词表重排顺序**（§2 三条 `不猜`）。
* 不改 `props.lua` 的 `with_thinking`：那是 webui 的 picker 显示开关（chat_template 里有没有那个旋钮），
  与网关自己的 `/v1/models` 声明不是一条链。
