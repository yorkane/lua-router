# 遮蔽语义测试补齐任务书

仓库 /home/aigc/ChatGPT/lua-router，HEAD=dc3a370（config_store 侧）+ 733b386（广告面侧）已实现
「虚拟入口遮蔽同名实际模型」（用户裁定 2026-10-07 方案 A）。**你的任务是补测试**，不改产品代码。

## 背景：为什么必须补

三份勘察（/data/tmp/lr-map-shadow-01-parse.md、-02-advertise.md、-03-tests.md）一致指出：
**现有测试里没有一例「入口名 == 真实模型名」的构造**——test_profiles.lua 的六处 virtual_models_list 桩、
test_models_shape / test_models_advertise 的 cases 表，入口名全都不撞真实名。这是本轮语义最大的判别空白：
代码实现了「同名遮蔽」，但没有任何一条断言在钉它。

## 你独占的文件（其他任何文件一律不许碰；工作区里还有另一条任务线在改 watcher/policies/observability/门禁，撞车即停手上报）

- test/unit/test_profiles.lua（扩 stub + 新增用例段）
- test/unit/test_models_shape.lua（新增同名用例）
- test/unit/test_models_advertise.lua（新增同名用例）

产品代码已实现的行为（你要钉的判据）：
1. profiles.lua 的 engine_attested_models + may_shadow_own_name：入口名 == 组内/target 名时，
   **只有该名字被 registry 的 record_models ∩ models_are_verified 背书（引擎亲口答过 /v1/models）才放行**；
   否则逐字退回改动前的严格拒绝。手填配置声明不算背书、没探过的实例不算背书。
2. readers.lua 的 ctx_cap / virtual_ctx_cap：同名入口的模型卡**要被读到**（原来入口名一律隐身，是死配置）；
   纯虚拟名（组里不含自己）继续隐身。
3. 派生表 sync_virtual_view / resolve_model 主逻辑未改：同名场景下 resolve_model 自返回 X，自洽不报错。
4. 广告面（models_api.lua）：同名时只广告入口一行，id=X，owned_by 走入口口径（单成员 llm-router-><m>，
   多成员 llm-router + owned_by_models），真实 X 不再单独出现；created 恒 0。

## 必写的用例（缺一条都不算完成）

### test_profiles.lua
先扩 registry stub（当前 make_registry_stub 的 record 没有 models / models_verified 字段，
也没有 record_models / models_are_verified 方法——新判据需要它们；扩 stub 时**只加不改**既有方法行为）。
- T1 同名 + 引擎背书 → `apply_profiles({model=X, target=X})` 成功。
- T2 同名 + 引擎背书 → `apply_profiles({model=X, targets={X, Y}})` 组形态成功。
- T3 同名 + **引擎未背书**（models_are_verified=false）→ 仍拒绝，且**报错文案逐字等于改动前那条**
  （被钉文案家族，见勘察报告第 4 点；不许改文案，用断言把它钉住）。
- T4 名字根本不在池里 → 仍拒绝。
- T5 链守卫不被放宽：同批里 entry-b 的 target 是 entry-a（另一个虚拟入口）→ 仍拒绝；
  以及**存量**场景（先建 entry-a，再用整表换成只含 entry-b→entry-a 的批次）也仍拒绝。
- T6 同名入口的模型卡 ctx_cap 可读到（这是「可以在虚拟服务中配置」的直接断言）。
- T7 纯虚拟名（组里不含自己）继续隐身：ctx_cap 读不到它的卡片（per-pick 抖动那条裁定逐字成立）。
- T8 非同名场景**逐字节不变**（老行为零变化的红线）。

### test_models_shape.lua / test_models_advertise.lua
- T9 同名构造（入口名 == 某真实模型主名）下广告恰好一行、id=X、owned_by 是入口口径、created 恒 0。
- T10 入口声明的 context_window 在遮蔽后**仍生效**（压过引擎自己上报的读数）。
- T11 判别性反证：把产品代码的遮蔽改动临时回退（用 git stash 或直接注释那一处）后，
  T9/T10 必须红——证明这组断言真的会咬，不是恒绿。**测完务必恢复代码**。

## 验证
- 直跑三个单测（命令从 test/final_gates.sh 的 run_unit_luajit 抄）：
  `docker run --rm -v $PWD:/repo:ro -w /repo --entrypoint /usr/local/openresty/luajit/bin/luajit -e LUA_TEST_LIB=/repo/lualib authz:latest /repo/test/unit/<t>.lua`
- 契约单段：`TEST_ONLY=virtual_models bash test/test_lua_router.sh`。
- **不许跑 final_gates.sh 全量**（root 统一跑，且工作区有另一条任务线在改门禁文件）。

## 纪律
- 禁止重启/杀掉承载本会话的基础设施：codex-desktop-gateway、3737 网关及其依赖服务（含 systemctl restart / kill / systemctl stop 等一切形式）。
- 不许启动或重启 lua-router 的 8800/8801 实例。
- 不 git 提交（root 统一提）。
- 先写完、验完，再一次性回报：新增用例清单、每个用例钉住了什么语义、T11 反证结果、三个单测与契约单段的结果。不要中途发进度。
