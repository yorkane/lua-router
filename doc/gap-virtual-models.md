# 虚拟 model id · 服务接入(upstreams) · JSON 编辑（gap-virtual-models）

日期：2026-10-01。决策人：用户。root 定架构，worker A/B/C/D/E 并行实现。

## 1. 需求（用户原话拆解）

1. 可以建立虚拟的 model id，后端选择「不同的上游模型 + 服务实例」。
2. 可以增加本地服务实例，以及远程服务接口 API（含 api key）。
3. 全部可以通过 API 建立和修改。
4. 提供 JSON 切换编辑界面。

## 2. 现状与缺口

- 虚拟模型：config_store.virtual_models 只有 alias 到 target 的字符串映射（resolve_model、inject_virtual_models、handle_config_virtual）。不能限定候选实例，不能带 per-alias policy/effort。
- 加 worker：POST /workers 已支持 url/model_id/api_key/priority/cost/labels；但记录只活在 lr_workers shdict，容器重启即丢（init bootstrap 只回放 SMG_WORKER_URLS 与 watcher 发现）。
- 远程 key：worker.api_key 已在转发时注入 Bearer（collect_forward_headers / props / health），缺持久化与脱敏回显。
- 清账风险：watcher KEEP_LAST/清账 会摘除它不认识来源的条目；新增的配置层 worker 必须免疫。
- JSON 编辑：config.html 已有 表单/JSON 双视图 + POST /_ui/config/apply 整体替换；editable 子集不含 upstreams。

## 3. 架构决策

### 3.1 两段新配置，全部落进 runtime-config 文档（LMR_CONFIG_FILE 原子持久化）

不在 profile 里内联 url/key——远程端点统一登记为 upstreams（池的持久化声明层），profile 用规范化 url 引用池成员。一个 worker 模型、一条健康环路、一套 metrics 维度。

文档新增两段（数组形状，与 snapshot 一致）：

virtual_models 条目（新形状，向后兼容旧 model+target）:
- model       string   虚拟 id（客户端请求里的名字）
- target      string   上游真实 model id（禁止指向另一个 alias，校验拒绝）。**2026-10-01 起变为可选**，
               见 §8（candidates 多绑定）；本节其余段落描述的是当时的形状
- workers     string[] 候选实例白名单（规范化 url 或 worker id）；空/缺省 = 全池
- policy      string   可选，8 个策略名之一；覆盖 model_policies/全局/env
- effort      string   可选，8 个 effort 之一；覆盖模型卡/全局
- candidates  object[] 可选，**2026-10-01 新增**，每项 {worker, model?}：逐实例绑定模型名，见 §8

upstreams 条目:
- url      string   http(s)://host[:port]，registry.normalize_url 规范化后作为稳定身份
- model_id string   上游模型 id（缺省 unknown，同 POST /workers）
- api_key  string   回显永远 null；写入语义见 3.4
- priority number   默认 50
- cost     number   默认 1.0
- labels   object   字符串 map（同 POST /workers）
- disable_health_check boolean
- max_concurrency / max_power_w  number 可选，每服务并发/功率上限（声明进池记录；见
                 doc/gap-worker-caps.md §2）
- models         string[] 可选，声明该端点覆盖哪些模型（**只是备注**，不构成引擎背书，见 §8.3）

- upstreams 的 reconcile：document 应用后同步声明层进 lr_workers 池：
  - url 不存在：registry.add({...req, discovery=config})（worker_id_for_url 决定 id，重启幂等）。
  - url 已存在且 record.discovery==config：update model_id/api_key/priority/cost/labels/disable_health_check。
  - url 已存在但 discovery 不是 config（watcher/手工/bootstrap）：不覆盖字段，摘要报 skipped。
  - 从 upstreams 移除：只删除 discovery==config 的池成员；其余永远不碰。
- 触发点：写请求内同步 reconcile；worker 0 init_worker 后异步补做；worker 0 定时器（30s）对比 config revision 与 shdict lr:upstreams_rev，落后即补 reconcile（自愈重启与误删）。

### 3.2 watcher / mesh 免疫

- watcher 清账与 DP 收缩删除前查 record.discovery==config：跳过（不清账、不改 model_id）。
- model-map 改名同样跳过 discovery==config 的 worker。
- mesh：config worker 走既有 worker 广播（mesh_observe_worker 已带 discovery），对端镜像行为不变。

### 3.3 路由热路径（router.lua）

- 解析顺序不变：客户端 model=alias 时 resolve_model 得 target；候选集、policy 状态、effort 卡、转发 payload 用 target；请求日志/metrics 记 alias 原值。
- 候选过滤：candidates_for(target) 之后，若该 alias 的 profile.workers 非空，只保留规范化 url 或 id 命中的 worker；命中集为空走既有 503 no_available_workers。
- policy 优先级：profile.policy 高于 model_policies[resolved]，再高于 labels.policy hint，再高于全局 policy，再高于 env。
- effort 优先级：model_effort[forced] 高于 profile.effort（alias 与 resolved 双键，先命中先用），再高于模型卡，再高于全局。
- 每请求成本：热路径 map 读走 config_store 现有快照（SNAPSHOT_TTL），不加 shdict 往返。

### 3.4 api key 读写与脱敏

- 所有 GET（document、/workers、props）不回显 api_key；upstreams 条目 api_key 字段恒 null。
- 写入语义：字段缺失或 null 保留现有 key；空串清除；非空设置。JSON 编辑器提交 null 不会洗掉 key。

### 3.5 HTTP 面

- GET /_ui/config：document 增含新形状 virtual_models + upstreams（脱敏）。
- POST /_ui/config/virtual：entries 数组（新形状）整体替换（兼容旧形状）。
- POST /_ui/config/upstreams：entries 整体替换 + 立即 reconcile；响应 document 加 reconcile 摘要 added/updated/removed/skipped。
- POST /_ui/config/apply：整文档替换；virtual_models 或 upstreams 任一存在即触发 reconcile；无效整体拒绝（半应用禁止，沿用现有校验风格）。
- POST/PUT/DELETE /workers 不变；discovery=config 成员会出现在 GET /workers（info 无 key）。
- 上限：upstreams 256 条，url 规范化后去重；校验失败 400 且 error 为文本，形状与现有 handler 一致。
- 信任边界不变：控制面无鉴权（scope-trim），只允许在 authz 边缘后暴露。

## 4. UI（quasar-umd 规则）

- ui/config.html：虚拟模型卡片升级为多列行（alias / target / 候选实例多选（GET /workers 填候选）/ policy 下拉 / effort 下拉 / 删除），保存走 ./config/virtual；JSON 视图可编辑子集加入 upstreams 与新 virtual_models 字段（提交 ./config/apply）。
- ui/admin 新增 upstreams.html（仿 workers.html 的 Quasar UMD 页）：表格 + 添加/编辑对话框（url、model_id、api_key password 输入提示「留空保持不变」、勾选清除才发送空串、priority、cost、labels JSON、disable_health_check），删除需确认；api.js 加 configUpstreams；i18n.js 加 zh-CN/en-US 词典；app.js 与 index.html 菜单加「服务接入」项；虚拟模型区展示 profile 字段。

## 5. 模块接口（并行不漂移的锚点，A 提供、B/C/D 消费）

config_store.lua（A 实现；B/C 按此签名调用）:
- _M.profile_for(model) 返回 table 或 nil：形状 target/workers/policy/effort；非 alias 返回 nil
- _M.resolve_model(model) 不变，alias 到 target
- _M.virtual_models_list() 保持旧签名（pair 数组），另加 _M.profiles_list() 返回按 alias 排序的 profile 对象数组
- _M.apply_profiles(entries) 返回 snapshot,err：校验并写 virtual_models 段
- _M.apply_upstreams(entries) 返回 summary,err：校验+写+reconcile（内部 require registry）；summary 含 added/updated/removed/skipped 计数数组
- _M.reconcile_upstreams() 幂等；读 current().upstreams
- _M.handle_config_virtual / handle_config_upstreams / handle_config_apply
- _M.document 与 snapshot_of 输出含 upstreams 数组（api_key 恒 null）与新形状 virtual_models
- _M.env_upstreams() 读 LMR_UPSTREAMS_FILE 指向的 JSON（可选 bootstrap 种子文件，缺省无）
registry（A 调用，B 微调）:
- add 已支持 req.discovery；update 已支持 patch.api_key/model_id/priority/cost/labels；remove(id) 存在
- B 需要：_M.info 输出补 discovery 字段（GET /workers 可见来源），并确保 update 的 patch 允许 labels 对象
router.lua（B）: candidates_for 可选第二参 profile；policy_for(model, profile)；apply_effort_policy 增 profile 参数。
watcher.lua（B）: 清账/改名循环跳过 record.discovery==config。
init.lua（B）: worker0 reconcile 接线（见 3.1 触发点）。

## 6. 文件所有权（越界即冲突，禁止碰他人文件）

- A 配置核心：lualib/resty/luarouter/config_store.lua、test/unit/test_profiles.lua（新）。
- B 路由/池：router.lua、registry.lua、watcher.lua、init.lua。
- C UI 面：conf/ui.conf、lualib/resty/luarouter/ui.lua、ui/config.html、ui/admin 下 api.js,app.js,i18n.js,upstreams.html,index.html。
- D 门禁：test/integration/e2e_profiles.py（新）、test/mock_llm_worker.py（加 REQUIRE_AUTH 模式：环境变量设置后 /v1 路径无 Authorization 头回 401）、test/final_gates.sh（新 gate e2e_profiles）。
- E 契约：test/test_lua_router.sh 新增 virtual/upstreams 契约段（可写不可跑容器；luajit 冒烟允许）。

纪律（对所有子智能体）：只许 luajit 语法检查与纯单测；容器/契约/e2e 全部由 root 串行统一跑，禁止 docker 起停；临时文件放 /data/tmp/lr-vm/；kill 精确 PID 禁 pkill；不动生产容器 lua-router-8800 / authz / SearXNG；不要 git commit，root 集成后统一提交。

## 7. 验收（root 串行执行）

1. GATE_ONLY=unit 绿（含 test_profiles.lua）。
2. e2e_profiles.py：alias 端到端只落白名单实例；per-alias policy 生效；per-alias effort 改写 reasoning_effort；REQUIRE_AUTH mock 验证远程 key 注入与 GET 不回显；upstreams CRUD 与 apply 整文档以及 key 保留语义（null 不洗 key、空串清除）；重启容器后 upstream 与 alias 复活（LMR_CONFIG_FILE 恢复）；watcher 清账不误删 config worker。
3. final_gates 全绿：原 19 门加 e2e_profiles 共 20 门；契约新增一段。

---

## 8. 追加（2026-10-01）：候选可各自绑定不同上游的相同或不同模型

决策人：用户。对应「更灵活的模型服务调度策略」（AGENTS.md 重点 1）。落地在
[config_store.lua](../lualib/resty/luarouter/config_store.lua) 的 `build_candidate_bindings` :432 与
[router.lua](../lualib/resty/luarouter/router.lua) 的 `profile_bindings` :1294 / `card_key_for` :1348 /
`candidates_for` :1498；测试见 [e2e_caps.py](../test/integration/e2e_caps.py) 的 S1 与
[test_caps_routing.lua](../test/unit/test_caps_routing.lua)。

### 8.1 为什么放宽

§3.1 的形状里一个别名整体指向一个 `target`，于是「217 那两个实例服务 A 模型、21.k 那个实例服务
B 模型」这种真实拓扑配不出来：要么把整池收窄成一个名字，要么所有候选共用一个名字、把 B 的实例
排除在外。候选各带自己的 `model` 后，转发体里的 `model` 由**选中的那个候选**决定，绑定就与
「上游恰好同构」解耦了。

### 8.2 新形状与校验（`virtual_models` 条目）

- `target` **变为可选**：全池共用的目标模型。旧形状 `{model, target}` 一字未动地继续工作。
- `candidates` **新增**：数组，每项 `{worker = 规范化 url 或 worker id, model = 该候选自己的模型名}`
  （`url` 收作 `worker` 的同义字段：候选描述的就是一个池成员，UI 那一列历来叫 url，不该有两种语义）。
- `workers`：§3.1 的纯字符串实例白名单，语义未动，**可与 `candidates` 共存**。
- `target` 与 `candidates` **至少有一个**，都没有 → 400（`profile_from_entry`）。
- `candidates[].model` 缺省继承 `target`；无 `target` 可继承 → 400，而不是在请求期猜一个名字。
- 同一 worker 出现两次：同一条绑定重复提交（UI 往返、运维手粘）静默去重；绑到两个**不同**模型
  → 400。「最后一条说了算」会让一次误粘配置悄悄改变路由。
- `target` 与任一 `candidates[].model` 都不得指向另一个 alias（`assert_bindings_no_alias` :655），
  防别名链；派生出来的代表 target 也受同一条规则约束，同一个错误只有一种措辞。
- `candidates` 与 `workers` 同时给出时取**交集**。绑定说「这个实例用哪个名字寻址」，白名单说
  「这个实例到底可不可以在这里出现」；让新字段盖掉旧字段，等于操作员刚写下一条限制就被静默放宽——
  **新字段永远不许放宽旧字段已经限制住的东西**。
- 快照只回写**写过的**字段：`candidates`-only 的配置不会在磁盘上长出一个没人声明过的 `target`
  （`profile.explicit_target` 记下这个区别 :575，快照侧按它决定回写 :1044）。派生值一旦落盘，所有读者
  （effort 卡、policy hint、`/v1/models`）都会跟着那个幻影名字找配置。
- 全部候选绑同一个模型时，策略实例按那个名字建；绑多个模型时按请求解析出的名字
  （`profile_policy_model` :1378），并且这个答案在选路前与选路时必须是同一个函数——否则一个 alias
  的亲和树会随池子涨跌在键之间跳，那就是一个比随机更差的 cache_aware。

### 8.3 worker 记录上的两个新字段

- `models`：该实例真实提供的模型列表，**主模型恒居首**（`registry.add` :871 起经 `norm_models` 规范化写入；
  `unknown` 占位符永不进入列表——它是「还没探到」的记号，不是引擎会广告的名字，进了列表就会把
  真实流量路由到一个假名字上）。
- `models_verified`：**只有引擎 `/v1/models` 亲口答过的列表才盖章**（`patch_record` 的
  `models_replace` :2144）。POST /workers 手填的、config 行声明的都不盖章。改名（主模型变化）时
  标记清零：围绕旧身份学到的覆盖度不能继续充当引擎亲口答过的凭证，等下一轮观测重新盖章。

为什么判定必须是三值而不是布尔：`worker_serves_model` :1350 答 `true` / `false` / `nil`，而
`false` 只在**已盖章**时才允许拿来做排除（`candidate_allows_model` :1413 把这条规则合成一个函数，
免得调用方只调一半就把 `false` 当死刑用）。「从没探到」与「列表只是某人填的备注」都必须保持可路由。
这不是精度问题而是安全性问题：一个健康实例不能因为一条手填的配置或一次没答上来的巡检就被判死
（与 agent-handover.md §4 第 10 条守卫是同一条红线在选路上的形态）。

### 8.4 与 IGW 的分工（不许合并的两件事）

- **显式绑定不受探针否决**。绑定的全部意义就是「用引擎未必携带的那个名字寻址这台实例」（第二个
  服务名、改名后的 checkpoint、映射名字的代理），拿广告列表去 veto 它会让跨绑定不可配置。
- IGW 只收窄**未绑定**候选，且只在引擎亲口答过的列表上收窄（`candidate_may_serve` router.lua:1417）。
  主模型仍是 `unknown` 的行照旧答复任何名字——「还没看」不许变成「这台坏了」，它也是未带 model 的
  请求唯一能落到的行。
- 卡片解析（effort / ctx）跟着选中候选的绑定名走（`card_key_for` :1348，per-attempt 而非 per-request，
  重试换机就换卡），别名级配置留作兜底：操作员把两台实例绑两个模型就意味着两台引擎，各用自己的卡。
  无绑定时逐字节等于改动前的表达式，`/generate` 不参与改写。

### 8.5 向后兼容（门禁与契约钉住的性质）

- 旧 `{model, target}` 条目、旧 `workers` 白名单、旧 env 形状 `LMR_VIRTUAL_MODELS=alias:real` 全部
  原样读取；不写 `candidates` 时选路路径与改动前一致（`e2e_caps.py` 的 S5c 就是钉这条）。
- `GET /_ui/config` 的 document 里 `virtual_models` 条目按需带 `candidates`；`profile_for` 已导出
  绑定形状，前端尚未完全认得（见 gap-worker-caps.md §7 的欠账登记）。
