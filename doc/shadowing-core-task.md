# w_shadow_core2 任务书（config_store 侧）

你接替一个连续两次空转的任务。**这是纯实现任务，事实已全部查清，没有任何需要你重新调查的可行性问题——直接写实现、写完验完再回报。**

仓库 /home/aigc/ChatGPT/lua-router。执行契约全文 /home/aigc/ChatGPT/lua-router/doc/shadowing-2026-10-07.md，
链路勘察 /data/tmp/lr-map-shadow-01-parse.md，受影响测试清单 /data/tmp/lr-map-shadow-03-tests.md。

## 目标语义（用户裁定 2026-10-07 方案 A）

入口 X 与真实模型 X 同名时**入口赢**：所有 model=X 的请求走入口 X 的 targets；真实 X 不再单独可达，
只作为 targets 落点。实际模型仍可经虚拟入口配置（effort/ctx/容量三字段配在入口上）。

**广告面（router/models_api.lua + ui.lua）已由另一个 worker 完成并全绿**，你只做 config_store 侧。

## 你独占的文件（其他任何文件一律不许碰）

lualib/resty/luarouter/config_store/profiles.lua、config_store/snapshot.lua、config_store/readers.lua

## 要改的四处守卫（行号是今天的盘上位置，profiles.lua）

1. `profiles.lua:491-493` 写过的 target 不得等于入口名：
   `if target ~= nil and alias == target then return nil, string.format("virtual model %s must differ from its target", alias) end`
2. `profiles.lua:565-567` 派生代表值同判（candidates-only 入口自指）。
3. `profiles.lua:696-707`（build_profiles 的组循环）+ `assert_no_alias_chain` `:711-718`：
   `if built[target] ~= nil then return string.format("virtual model %s target must not be another virtual model: %s", alias, target) end`
   —— 今天连「自己」都拦（built 里有本批自己），且只看本批 built 表、不看存量、不看 registry。
4. `profiles.lua:787-803` assert_bindings_no_alias：绑定名自指 + existing 查存量。

## 放开的前提：判据必须是「引擎背书」，不能是「操作员声明」

取 registry 侧既有接口（config_store 通过 lexicon.store_registry() 惰性取 registry，lexicon.lua:276，
有测试钩子 lexicon._reset_pool_module_caches 可重置）：

- `registry.all_models()`（records.lua:780）—— 返回池内全部已注册 worker 的所有 model_id（models_of 展开、已排序）。
- `registry.models_are_verified(record)`（records.lua:937）—— 该 record 的 models_verified == true，即引擎亲口答过 /v1/models。

判据设计：**只有当名字 X 出现在 all_models() 里、且提供它的那条 record 是 verified（models_are_verified 为真）时，
才把「alias == target」当作合法的同名遮蔽放行**；否则维持今天的一致拒绝。
理由（写进注释）：手填的配置声明不是引擎陈述；没探过的实例也不算背书。这与 records.lua:951-973
candidate_allows_model 的「宁缺勿猜、缺省方向是仍可路由」同源。

注意 all_models() 返回的是模型名集合，不带来源；要拿到「哪个 record 提供它且是否 verified」，
需要遍历 registry.records() 自行匹配 models_of(record) —— 该函数是否已导出请自行确认（records.lua 里 models_of 有导出与否），
导出就用导出的、没导出就用 records() + record.models 自行拼，但**不许改 registry 文件**。

## 还要改的一处死配置

`readers.lua:79-88` ctx_cap：`if cfg.virtual_profiles[model] ~= nil or cfg.virtual_models[model] ~= nil then return nil end`
—— 入口名对卡片隐身，导致「给同名入口 X 配模型卡」永不生效。按契约「配置配在入口上、落到选中实例」，
同名入口 X 的卡片必须能被读到（X 既是入口又是真实模型名时，卡片该对入口生效）。

## 派生表自洽

`sync_virtual_view`（snapshot.lua:66-95，只在三条写路径调用：snapshot.lua:201 env、:704 cfg_from_document、
mutators.lua:161 apply_profiles）要确认同名场景下派生表不产生自映射环；代表值取组头这条不变。
`readers.resolve_model`（:362 `cfg.virtual_models[model] or model`）与 `virtual_models_list`（:372）按新语义自洽即可。

## 硬约束

- 被钉文案家族不许改：profiles.lua 约 22 条报错格式串（勘察报告第 4 点有清单）。你要放行的是「引擎背书的同名」，
  其余错误路径的文案逐字保留。新增文案（如需要）在报告里说明并给出会红的单测行。
- AGENTS.md 全部硬规则照旧：本轮只改「谁能被访问」，不碰转发字节透传、输出预算原样透传、探针分档、容量三字段语义。
- 禁止重启/杀掉承载本会话的基础设施：codex-desktop-gateway、3737 网关及其依赖服务（含 systemctl restart / kill / systemctl stop 等一切形式）。
- 不许启动/重启 lua-router 的 8800/8801 实例。不许跑 final_gates.sh 全量（root 统一跑）。不 git 提交。

## 验证（必须做完再回报）

1. luajit -bl 三个文件（authz:latest，-v /home/aigc/ChatGPT/lua-router:/repo:ro）。
2. 直跑单测（命令从 test/final_gates.sh 的 run_unit_luajit 抄）：test_profiles、test_routing_dyn、test_effort_layers、
   test_models_shape、test_models_advertise。红了先判断是「你改坏」还是「它钉的正是本轮要取代的旧行为」——
   后者**不许改测试**（那是后续波次），在报告写清「X 行需从旧语义改成新语义」。前者必须修绿。
3. 契约单段：`TEST_ONLY=virtual_models bash test/test_lua_router.sh`（全绿是加分项，跑不动就说明原因）。
4. 写 /data/tmp/ 下的探针，用真实现 + 假 registry 验证四条验收判据里属于你的部分：
   a. 「入口 X + targets:[X]」在 X 被引擎背书时**能建成**、不被背书时**仍拒**；
   b. 同名入口 X 的模型卡可被 ctx_cap 读到；
   c. 派生表（virtual_models / virtual_profiles）在同名场景不自环；
   d. 非同名场景逐字节不变（老行为零变化）。探针输出贴进报告。

## 回报要求

先写完、验完，再一次性回报：改动函数清单、判据如何落地（怎么区分「另一个入口」与「引擎背书的同名真实模型」）、
探针输出、单测结果、留给后续波次的测试点。不要中途发进度。偏离契约停下报证据，不要自行换设计。

## 补充事实（root 已替你核实，省你一轮）

- `models_of`（records.lua:300）是 **file-local，未导出**。能用的既有导出只有：
  `registry.all_models()`(:780，名字集合，已排序)、`registry.records()`(全池 record 列表)、
  `registry.record(id)`、`registry.models_are_verified(record)`(:937)、`registry.candidate_allows_model(record, model)`(:961)。
- 所以判据实现建议：`all_models()` 拿名字集合判断「X 是不是池里的模型名」；要确认「引擎是否背书」
  再遍历 `records()`，用 `record.models`（all_models 内部就是 models_of(record)，等价字段）与
  `models_are_verified(record)` 配对。**不许改 registry 任何文件**。
- config_store 取 registry 的既有通道：`CS_LEXICON.store_registry()`（lexicon.lua:276，pcall require + 缓存，
  registry 缺席时返回 nil）。单测里用 `lexicon._reset_pool_module_caches()` 重置缓存后打桩。
## 再补一条（root 读 sync_virtual_view 全文后确认）

sync_virtual_view（snapshot.lua:66-86）今天的行为：map[alias] = rep，rep = 显式写了 targets 就取组头
（profile.targets[1]，要求非空字符串），否则用 profile.target。同名场景下 map[X] 会等于 X 自己
（组头就是 X），而 readers.resolve_model（readers.lua:362 的 cfg.virtual_models[model] or model）
会让 X 返回 X —— 这一步是自洽的（不构成环，因为引擎认识 X）。你不需要改 resolve_model 或
sync_virtual_view 的主逻辑，只需保证「放行入口名==组内同名真实模型」之后派生表不报错、不产生自环
即可（验收判据 c）。
