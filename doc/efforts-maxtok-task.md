# 任务书：reasoning_efforts 与 supported_reasoning_efforts 一致化 + 虚拟服务 max_output_tokens

仓库 /home/aigc/ChatGPT/lua-router。**纯实现任务，落点行号与语义全部已勘察，直接写、写完验完再回报。**

## 改动 1：reasoning_efforts 与 supported_reasoning_efforts 一致

### 现状（已勘察）

`/v1/models` 每行有两份档位字段：

- **旧三位**（`router/models_api.lua` fill_model_fields :1021-1024）：
  `entry.reasoning_effort = row.default_effort`、`entry.reasoning_efforts = row.ladder`——
  来自引擎 picker 阶梯 / 卡片勾选表，与 effort 映射推导无关。
- **新四位**（用户裁定 2026-10-11）：`entry.supports_reasoning` / `entry.supports_reasoning_effort`
  （两个 true 位）+ `entry.supported_reasoning_efforts`（推导档位列表）+
  `entry.default_reasoning_effort`（推导缺省档）——当 `row.effort_advertise` 非 nil 时写入（:954-962）。

**问题**：同一行上 `reasoning_efforts`（引擎 picker 档）与 `supported_reasoning_efforts`（映射推导档）
可能不一致，客户端无法判断该读哪一个。

### 要实现的

**当 `row.effort_advertise` 非 nil（即该条目配了 effort 映射）时**，旧两位必须与新两位**同值**：
- `entry.reasoning_efforts` = `advertised.levels`（与 `supported_reasoning_efforts` 相同的数组）；
- `entry.reasoning_effort` = `advertised.default`（与 `default_reasoning_effort` 相同的值）；
- 清单和缺省档都换成**新表**而不是 row 里那份引用（响应条目会被下游改，改了会把同一进程里下一份读数的字节带跑——fill_model_fields 上方已有这条注释，照抄那条纪律）。

**当 `row.effort_advertise` 为 nil（纯引擎自报，没配映射）时**，旧两位照旧用 `row.ladder` /
`row.default_effort`——逐字节不变，这是缺省零行为变化的红线。

具体改动：`fill_model_fields`（:1021-1024 附近）中 `if row.ladder then entry.reasoning_efforts = row.ladder end`
和 `if row.default_effort then entry.reasoning_effort = row.default_effort end` 这两行外面再套一层
「映射存在则用推导值，否则用引擎值」的优先级判断。

### 注意

`reasoning_efforts` 的形状是**带 label / default 标记的表数组**（每项 `{value=, label=, ["default"]=}`），
不是纯字符串数组——`supported_reasoning_efforts` 是纯字符串数组。两者保持各自的形状不变，
只是**档位的值列表**一致（旧名里每项的 `value` 等于新名里的对应字符串）。
如果引擎没给阶梯（`row.ladder` 为 nil）但映射推导有值，就用推导值构造与旧形状兼容的条目
（每项 `{value = name}`，无 label），让客户端读法不变。

## 改动 2：虚拟服务条目新增 `max_output_tokens` 字段

### 现状（已勘察）

`max_output_tokens`（原卡片字段 `context_limit`，2026-10-08 改名）目前只在**模型卡片**
（`model_configs`）上配置，来源：卡片 `max_output_tokens` > 平铺 `model_max_output_tokens`，
唯一去处是 `capabilities.max_output_tokens`（操作员声明压过引擎自报，models_api.lua:589）。

**虚拟服务条目（virtual_models entry）目前没有这个字段。**

### 要实现的

1. **虚拟服务条目支持 `max_output_tokens`**：profiles.lua `profile_from_entry`（:570 起）接受
   `max_output_tokens` 字段（正整数校验，照抄 context_window 的 build_context_window 纪律），
   落盘到 profile，snapshot.lua 的条目行输出段（:383-392 附近）写进 entry 行。
2. **对外取值优先级**：虚拟服务条目上声明了 `max_output_tokens` → `capabilities.max_output_tokens`
   用条目层的值（压过卡片/引擎自报）；条目上没配 → 沿用既有的卡片/引擎链路不变。
3. 虚拟服务上配了 effort 映射 → 新四字段照上一轮的逻辑推导，与 max_output_tokens 互不干扰。

## 你独占的文件（其他任何文件一律不许碰，撞车即停手上报不要硬扛）

- lualib/resty/luarouter/router/models_api.lua
- lualib/resty/luarouter/config_store/profiles.lua
- lualib/resty/luarouter/config_store/snapshot.lua
- test/unit/test_models_shape.lua（新增用例）

**不许碰**：其他 config_store/ 文件、registry/、ui/、conf/、doc/、其他 test 文件。

## 验证

- luajit -bl 你改的每个文件。
- 直跑：test_models_shape、test_models_advertise、test_profiles、test_routing_dyn、test_effort_layers
  （docker run --rm -v $PWD:/repo:ro -w /repo --entrypoint /usr/local/openresty/luajit/bin/luajit -e LUA_TEST_LIB=/repo/lualib authz:latest /repo/test/unit/<t>.lua）。
- 契约单段：`TEST_ONLY=virtual_models bash test/test_lua_router.sh`。
- 写 /data/tmp 下的探针验证四条：
  a. 有 effort 映射时 `reasoning_efforts` 与 `supported_reasoning_efforts` 同值；
  b. 无 effort 映射时旧值照旧（零变化）；
  c. 虚拟服务条目上配了 `max_output_tokens` 后 `capabilities.max_output_tokens` 用条目层的值；
  d. 条目上没配时沿用卡片/引擎链路不变。
  探针输出贴进报告。

## 纪律

- 禁止重启/杀掉承载本会话的基础设施：codex-desktop-gateway、3737 网关及其依赖服务
  （含 systemctl restart / kill / systemctl stop 等一切形式）。
- 所有 8800 都是生产，不许动；21.k 的 8801/8802 是测试环境但本轮 root 统一部署，子 agent 不许碰容器。
- 不许跑 final_gates.sh 全量（root 统一跑）。临时文件放 /data/tmp/。用 kill 不用 pkill。
- 不 git 提交（root 统一提）。

## 回报

先写完、验完，再一次性回报：改动函数清单、两条链的优先级怎么实现、探针输出、单测结果、
需要后续波次改的测试点清单。不要中途发进度。偏离任务书停下报证据，不自行换设计。
