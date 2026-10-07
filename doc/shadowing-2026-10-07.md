# 虚拟入口遮蔽同名实际模型（2026-10-07 用户裁定 · 方案 A）

> 三份勘察：/data/tmp/lr-map-shadow-01-parse.md、-02-advertise.md、-03-tests.md。先读这三份再动手。

## 裁定原文

虚拟服务可以覆盖同名的实际模型，屏蔽对实际模型的访问，但可以在虚拟服务中配置。方案 A =
**同名即遮蔽，入口赢**：入口名叫 X 时，所有 `model=X` 的请求一律走该入口的 targets；实际模型 X
不再单独可达，只作为 targets 的落点存在。实际模型仍可经虚拟入口配置（effort/ctx/容量三字段
都配在**入口**上，落到它选中的实例）。

## 今天的行为（勘察实证，方案 A 要消掉的）

1. 广告面真实模型赢：`models_api.lua:857` 的 `if not seen[alias]` —— `seen` 只被真实行填过，
   入口名撞上真实名就整行丢弃，无 warn 无指标。
2. 真 X 实例彻底不可达：请求 model=X 命中入口组门被筛空 → 503「healthy engines serve none
   of the mapped models」，而 /v1/models 还广告着它。**这是现网真实故障面。**
3. 写入层四处守卫会拒绝「入口名 == 目标名」：profiles.lua:492（写过的 target 不得等于入口名）、
   :565（派生代表值同判）、:696-707 + assert_no_alias_chain:711（组内任一成员不得是另一入口，
   含自己）、:787-803（绑定名）。
4. `readers.lua:79-88` ctx_cap 的入口名隐身守卫：给同名入口配卡片会变成永不生效的死配置。

## 目标语义

- 入口 X 与真实模型 X 同名时：**入口赢**。`model=X` 的请求按入口 X 的 targets 选路；真实 X
  实例只能作为 targets 的落点被入口调度，不能被客户端直接点名访问。
- 广告面：`/v1/models` 只广告**入口** X 一行（id=X，owned_by 按入口规则：单成员 llm-router-><m>、
  多成员 llm-router + owned_by_models），**不再单独广告真实 X**。`/workers` 仍能看见那台 worker
  （它是运行态事实，与「客户端不可达」是两件事）。
- 配置面：允许建这样的入口。需要一条「X 确实是引擎真实模型」的判据来区分「配置声明」与
  「引擎陈述」——**不得把操作员的声明当引擎背书**。判据取 registry 侧：`records.all_models()`
  （records.lua:780）∩ `models_are_verified`（records.lua:937，从没探过 = 不算）。探不着的名字
  仍按今天的严格语义处理。
- 转发名：入口赢之后，转发体的 model 仍必须是**真实引擎模型名**（`lr_bound_model`，forward.lua:678-689）。
  遮蔽下 binding 可以合法等于 X（引擎认识 X），但转发字节必须正确——这条不变量要在测试里钉死。
- 容量/档位/上下文窗口：全部配在**入口**上（这正是「可以在虚拟服务中配置」的落点），落到选中实例。

## 波次与所有权（撞车即停手上报，不要硬扛）

| 波 | worker | 名下文件（独占） |
|---|---|---|
| W1 | w_shadow_core | config_store/{profiles,snapshot,readers}.lua |
| W1 | w_shadow_advert | router/models_api.lua、lualib/resty/luarouter/ui.lua |
| W2 | w_shadow_tests | test/unit/{test_profiles,test_models_advertise,test_models_shape}.lua、test/integration/{e2e_profiles,e2e_models_advertisement}.py、test/test_lua_router.sh 容量/广告相关段 |
| W3 | w_shadow_ui | ui/admin/models.html、ui/admin/i18n.js（只在需要表达遮蔽语义时才动） |
| W4 | root | 整合 + 全量门禁 + 21.k 部署验证 |

W1 两个 worker 的文件不重叠，可并行。W2/W3 依赖 W1 的最终形状，等 W1 完成再派。

## 验收（三条硬判据，任何一条不绿都不算完成）

1. 同名入口 X 存在时，`model=X` 的请求 100% 落到入口 targets 指定的实例，**绝不**落到
   「正好在跑 X 的那台」——除非那台就是入口 targets 里的一员。
2. `/v1/models` 里 X 恰好一行，id=X，owned_by 是入口口径；真实 X 不再单独出现。
3. 入口 X 的 effort/ctx/容量三字段配置对选中实例**真实生效**（不是死配置）。

## 纪律

- 禁止重启/杀掉承载本会话的基础设施：codex-desktop-gateway、3737 网关及其依赖服务
  （含 systemctl restart / kill / systemctl stop 等一切形式）。
- 不许启动/重启 lua-router 的 8800/8801 实例。
- 不许跑 final_gates.sh 全量（root 统一跑），只跑单门或直跑单测。
- 被钉的文案家族（profiles.lua 约 22 条格式串 + 对应单测行号，见勘察报告第 4 点）**不许顺手改**，
  报错文案改动会让既有单测红。
