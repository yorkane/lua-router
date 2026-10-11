# 执行契约：虚拟服务 api-key + /v1/models 能力字段推导（2026-10-11 用户裁定）

## 需求原文（用户裁定，优先级高于 AGENTS.md 的旧口径）

**需求 A：虚拟服务的 API 密钥**
1. 虚拟服务增加 API 密钥的 UI，并保存。
2. **虚拟服务只能经过 api-key 访问**（配了 key 的条目，没带 key 就拒）。

**需求 B：/v1/models 的能力字段**
模型对象根路径下增加：
```
"supports_reasoning": true,                        // 只要有 effort 配置（除了 none 以外）就必须加上
"supported_reasoning_efforts": ["none","minimal","low","medium","xhigh","max"],
"default_reasoning_effort": "low",                 // 根据配置来
"supports_reasoning_effort": true,                 // 只要有 effort 配置（除了 none 以外）就必须加上
```
外加三条口径：
- 默认所有思考都要支持，直接在虚拟服务中配置强度映射（**默认使用原始值**）。
- 原有的很多配置可以去除，**根据 effort 映射来推断**。
- 视觉能力**通过 image、video 这些判断来推断**。

## 与既有硬规则的关系（root 已裁决，按此执行）

- AGENTS.md 硬规则 5「网关层零鉴权」指的是**没有全局鉴权平面**；本轮引入的是**虚拟服务条目级**的
  key 门，只保护配了 key 的那些条目，不恢复被删的 auth 平面（auth 平面已按 2026-10-01 裁定删除）。
- AGENTS.md 硬规则 9② 说扩展字段「操作员声明 > 引擎自报 > 省略，宁缺勿猜」。用户本轮明确要求**从
  effort 映射推断**，这覆盖了 9② 的一小部分：**只对这四个 reasoning 字段**按 effort 映射推导，
  其余扩展字段继续按 9② 的「宁缺勿猜」不变。推导规则必须是**确定的**（同一配置每次出同一字节），
  不能有猜测成分。
- 硬规则 9① 的四字段 required、`created` 恒 0 等照旧不变。

## 已勘察到的现状（事实，省一轮）

- effort 词表在 `config_store/lexicon.lua:20`：
  `{"none","minimal","low","medium","high","xhigh","max","ultra"}`（8 档）。
  用户示例给的是 6 档（无 high / ultra），**以配置里实际出现的值为准**，不要硬编码示例那张表。
- effort 配置形态：卡片层 `effort_map`（`{from=to}` 的数组形态，handlers.lua:205-215 序列化）、
  条目层 `default_effort`；落在 `model_configs` / `virtual_profiles` 上。
- 现有 capabilities 生成在 `router/models_api.lua`：`row.reasoning`（:494，来自引擎/声明）、
  `row.declared_effort_support`（:560，卡片→条目读数）、`entry.supports_reasoning_effort`（:729）、
  组内共识（:814）。视觉 modalities 在 `card.modalities` / `profile.modalities`（snapshot.lua:289/368）。
- api_key 目前**只存在于 upstreams 声明层**（上游实例），虚拟服务条目没有；
  脱敏与三态（keep/clear/set）在 `config_store/upstreams.lua:78` 与 snapshot.lua:392-426。
- 鉴权面：`ui.lua` / `router.lua` 的分发链；网关当前无任何鉴权中间件。

## 波次与所有权（撞车即停手上报，不要硬扛）

| 波 | worker | 名下文件（独占） |
|---|---|---|
| W1 | w_apikey_cfg | config_store/{profiles,snapshot,readers,handlers}.lua |
| W2 | w_apikey_guard | router.lua / router/ 下分发与鉴权接缝、config_store/handlers 的 401 面 |
| W3 | w_models_caps | router/models_api.lua、registry/caps.lua |
| W4 | w_models_ui | ui/admin/models.html、ui/admin/i18n.js |
| W5 | w_effort_tests | test/unit/test_models_shape.lua、test_models_advertise.lua、test_profiles.lua、test_lua_router.sh、新单测 |
| W6 | root | 整合 + 全量门禁 + 21.k:8802 部署验证 |

W1 与 W3 文件不重叠可并行；W2 依赖 W1 的字段形状；W4 依赖 W1（表单字段）与 W3（广告面展示）；
W5 最后做（依赖前四者的最终形状）。

## 验收（三条硬判据，任何一条不绿都不算完成）

1. **api-key**：给某个虚拟服务条目配 key 后，不带 key 的请求被拒（状态码与文案按设计书），
   带正确 key 的请求 200；不带 key 的其他条目**不受影响**（默认零行为变化）。key 的 GET 回显是掩码，
   永不回显明文（沿用 upstreams 层已有的三态纪律）。
2. **能力字段**：只要 effort 配置里出现过 `none` 以外的档位，`supports_reasoning` 与
   `supports_reasoning_effort` 必须为 true、`supported_reasoning_efforts` 列出**实际出现的档位**、
   `default_reasoning_effort` 取配置值；没有 effort 配置时这四个键**整体省略**（不写 null、不写空数组）。
3. **视觉推断**：modalities 含 image/video 时才报对应视觉能力；不含就不报。

## 纪律

- 禁止重启/杀掉承载本会话的基础设施：codex-desktop-gateway、3737 网关及其依赖服务
  （含 systemctl restart / kill / systemctl stop 等一切形式）。
- 所有 8800 都是生产，不许动；21.k 的 8801/8802 是测试环境但本轮 root 统一部署，子 agent 不许碰。
- 不许跑 final_gates.sh 全量（root 统一跑）。临时文件放 /data/tmp/。用 kill 不用 pkill。
- 被钉的文案家族与断言逐字保留；要改先上报。
- 不 git 提交（root 统一提）。

## 用户最终裁定（2026-10-11，追加在上面需求之上的口径）

1. **选 A**：虚拟服务上**只保留一张 effort 强度映射表**（默认使用原始值，即 from==to 的恒等映射
   就是「全档位原样透传」）；`supports_reasoning` / `supported_reasoning_efforts` /
   `default_reasoning_effort` / `supports_reasoning_effort` 四个字段**全部由这张表推导**。
   虚拟服务上原有的独立布尔位（`supports_reasoning` / `supports_reasoning_effort` / 
   `supports_vision` / `supports_streaming` / `supports_tool_use` 等）**从 UI 与配置层一并去掉**
   ——避免「显式声明说 false、effort 映射又说 true」这种自相矛盾。
   注意：这只针对**虚拟服务条目**；模型卡片（model_configs）上的既有字段不在本轮拆除范围内，
   除非它同时被这套推导取代——遇到这种情况在报告里写清，不要自行扩大拆除面。
2. **401 Unauthorized**：虚拟服务配了 api-key 而请求没带（或带错）→ 401 + 明确文案。
3. **视觉能力**：`modalities` 里含 `image` 或 `video` 就直接判 `视觉能力为 true`，
   无论这个 modalities 是引擎自报的还是操作员手填的。
4. **supported_reasoning_efforts 列的是配置里实际出现过的档位**（按 lexicon 的
   EFFORT_LEVELS 顺序排序：`none,minimal,low,medium,high,xhigh,max,ultra`），
   不是硬编码用户示例里那张 6 档表。恒等映射（全档位）时列全部 8 档。
5. **四个字段的省略规则**：该条目**完全没有** effort 配置（含 default_effort 与 effort_map 都
   为空）→ 四个键**整体省略**（删键，不写 null、不写空数组）。有配置但只出现 `none` →
   按需求原文「除了 none 以外才算」，四个键同样省略。
