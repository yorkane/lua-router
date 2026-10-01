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
- model    string   虚拟 id（客户端请求里的名字）
- target   string   上游真实 model id（禁止指向另一个 alias，校验拒绝）
- workers  string[] 候选实例白名单（规范化 url 或 worker id）；空/缺省 = 全池
- policy   string   可选，8 个策略名之一；覆盖 model_policies/全局/env
- effort   string   可选，8 个 effort 之一；覆盖模型卡/全局

upstreams 条目:
- url      string   http(s)://host[:port]，registry.normalize_url 规范化后作为稳定身份
- model_id string   上游模型 id（缺省 unknown，同 POST /workers）
- api_key  string   回显永远 null；写入语义见 3.4
- priority number   默认 50
- cost     number   默认 1.0
- labels   object   字符串 map（同 POST /workers）
- disable_health_check boolean

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
