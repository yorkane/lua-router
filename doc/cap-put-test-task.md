# 收尾：PUT 容量上限越界拒绝的测试（任务书）

仓库 /home/aigc/ChatGPT/lua-router。**产品代码已由上一轮 worker 写完并落盘（registry/loads.lua、
registry/discovery.lua、config_store/upstreams.lua 三个文件的改动在工作区，未提交）；你的任务是补测试
+ 验证，不改产品代码。**

先读 /home/aigc/ChatGPT/lua-router/doc/cap-put-ceiling-task.md（原始任务书：缺口与要实现的）。

## 当前状态（root 已核实）

产品侧已完工：
- `registry/loads.lua` 新增 `M.cap_range_refusal(field, value)` 与 `M.cap_range_wording(field)`——
  三档范围的**唯一判据**（min 1..31 / max 1..32 / util 0..100），从 cap_limit / util_limit 派生，
  清除哨兵（并发 0、util -1）豁免，非 cap 字段名一律放行。
- `registry/discovery.lua:324` 的 UPDATE_NUMBER_FIELDS 循环调用它，越界返回
  `nil, "field 'x' ...", "validation"`（既有错误形状，control.lua 映射到 400）。
- `config_store/upstreams.lua` 的 `cap_tiers_said` 经 `cap_rule()` 取同一份判据，registry 缺席时为 nil。

**但 6b 段 8 条断言红了**，root 已定位根因（不是产品逻辑错）：
`cap_rule()` 用 `pcall(require, "resty.luarouter.registry.loads")` 取判据，而该文件依赖 authz 基座
（`resty/core/base.lua` 要 `resty.authz.config`），**纯 Lua 单测环境 require 失败 → cap_rule() 返回 nil
→ cap_tiers_said 里 `rule and rule.cap_range_refusal(...)` 静默跳过校验 → 越界值 77 走进快照**。
生产容器里有 authz，所以生产侧的门是活的；单测里是死的。
test_caps_persist 的 `make_registry_stub()` 只 stub 了父模块 `resty.luarouter.registry`
（`use_registry` :204-208），没有 stub 子模块 `resty.luarouter.registry.loads`。

## 你要做的

1. **给单测桩补 `resty.luarouter.registry.loads` 子模块**：`use_registry` 里一并
   `package.loaded["resty.luarouter.registry.loads"] = { cap_limit=..., util_limit=...,
   cap_range_refusal=..., cap_range_wording=... }`，其中两个新函数用**判据本体**实现
   （文件里 :210 附近注释说「判据本体：本文件既用它做断言，也借它确认镜像行的认得」——顺着那段
   既有形状接，别另造一套规则）。补完 6b 必须回绿。
   **注意**：`_reset_pool_module_caches()`（store 的那个）要连带清掉 `config_store/upstreams.lua` 里
   `cap_rulebook` 的 memo，否则先前的 nil 判定会被缓存住。
2. **新增池侧 PUT 越界被拒的断言**（任务书要求，现在完全没有）：
   - 直接调 `registry.update(id, {max_concurrency=77})` → 返回 nil + validation 文案；
   - `registry.record(id)` 里 max_concurrency 保持原值（没被写进去）；
   - 合法边界（31 / 32 / 100）放行；非 cap 字段（priority=999、cost=1.5）不受影响；
     清除哨兵（并发 0、util -1）保持 202 语义。
3. **test_lua_router.sh 的 workers 段**加一条 HTTP 面断言：越界 PUT 得 400（不是 202），
   `GET /workers/{id}` 里该键缺席，既有配置仍可读。
4. **判别性反证**：临时回退 discovery.lua 里那处 `cap_range_refusal` 调用，步骤 2 的新断言必须红；
   再临时让桩里 cap_range_refusal 返回 nil，6b 必须红。两次都要恢复并复跑。

## 验证

- luajit -bl 你改的文件。
- 直跑：test_caps_persist、test_caps_routing、test_profiles、test_routing_dyn
  （docker run --rm -v $PWD:/repo:ro -w /repo --entrypoint /usr/local/openresty/luajit/bin/luajit
  -e LUA_TEST_LIB=/repo/lualib authz:latest /repo/test/unit/<t>.lua）。
- 契约单段：`TEST_ONLY=caps bash test/test_lua_router.sh`。
- **不许跑 final_gates.sh 全量**（root 统一跑）。
- 收尾：确认无 lr-* 容器残留、无遗留门禁进程、产品代码未被改动（`git diff --stat` 里 lualib/ 三行应与
  你开始时一致）。

## 你独占的文件

- test/unit/test_caps_persist.lua
- test/test_lua_router.sh

**lualib/ 下三个产品文件不许改**（它们是上一轮的成果，已完工）。撞车即停手上报。

## 纪律

- 禁止重启/杀掉承载本会话的基础设施：codex-desktop-gateway、3737 网关及其依赖服务
  （含 systemctl restart / kill / systemctl stop 等一切形式）。
- 不许启动或重启 lua-router 的 8800/8801/8802 实例（所有 8800 都是生产；8801/8802 是测试但本轮不部署）。
- 用 kill 不用 pkill；临时文件放 /data/tmp/。
- 不 git 提交（root 统一提）。

## 回报

先写完、验完，再一次性回报：桩怎么补的（含 memo 清理）、新增用例清单与各自钉住的语义、
4 步验证结果、两次判别性反证结果。不要中途发进度。偏离任务书停下报证据。
