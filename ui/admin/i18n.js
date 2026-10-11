/*
  lua-router 管理控制台 · 共享业务词典（仿 authz/admin/i18n.js）

  - 中英双语：所有用户可见文案（标题/菜单/表格列/按钮/占位符/校验/Notify/Dialog/空状态）
    都必须从 window.lmrI18n.messages[locale] 取，页面与内联脚本不得硬编码单一语言。
  - 语言偏好持久化在 localStorage（key: lmr_admin_locale），并通过 postMessage + storage
    事件在主壳与所有 iframe 之间同步：壳切换语言 → 已打开与之后加载的页面同时切换。
  - Quasar 组件内置文案（分页、日期、"No Rows"等）由各页面自己调用 Quasar.Lang.set 对齐。
*/
(function () {
  const STORAGE_KEY = 'lmr_admin_locale'
  const MESSAGE_TYPE = 'lmr-admin-locale-change'

  const messages = {
    'zh-CN': {
      common: {
        retry: '重试', refresh: '刷新', cancel: '取消', save: '保存', create: '创建',
        add: '添加', del: '删除', edit: '编辑', actions: '操作', status: '状态',
        model: '模型', url: '地址', none: '无', unset: '未设置', unknown: '未知',
        loading: '加载中', empty: '暂无数据', required: '必填字段', notNumber: '必须是数字',
        confirm: '确认', search: '搜索', copied: '已复制', openInTab: '新窗口打开',
        httpError: '请求失败', invalidJson: '响应不是合法 JSON',
        secondsUnit: '秒', timesUnit: '次', countUnit: '个', rowsUnit: '条'
      },
      shell: {
        brand: 'llm-router 控制台', brandSub: '模型管理 / 服务池 / 日志',
        groupManagement: '网关管理', groupEntry: '入口',
        workers: '服务池', workersTitle: '推理实例与接入声明统一视图',
        models: '模型管理', modelsTitle: '虚拟模型别名与按模型档位/上下文',
        routing: '路由策略', routingTitle: '全局与按模型的选路策略，改完即刻生效',
        logs: '日志监控', logsTitle: '请求环形缓冲与实时流',
        chat: '聊天界面', chatTitle: '打开原版 llama.cpp webui',
        collapse: '收起菜单', expand: '展开菜单', language: 'English',
        online: '网关在线', offline: '网关不可达',
        healthySummary: '健康 {ok} / 共 {n}', propsLine: '{model} · n_ctx {ctx}',
        // 侧栏实时吞吐面板（2026-10-08）：口径 = 日志页 summarizeWindow 的 60s 完成时刻窗口
        throughputTitle: '实时吞吐', throughputWindow: '60s 窗口',
        throughputIn: '入 tok/s（含 cache）', throughputOut: '出 tok/s', throughputCache: 'cache 命中',
        throughputLine: '窗口请求 {n} · 错误 {e} · 平均 TTFT {t}',
        dash: '—',
        frameTitle: '管理页面'
      },
      workers: {
        title: '服务池', description: 'llm-router 后面的推理实例：按模型分组、健康态与在途负载，可添加或摘除远程服务。',
        statWorkers: '实例总数', statHealthy: '健康实例', statModels: '模型数',
        statHealthyNote: '健康探测每 {n} 秒一轮', statModelsNote: '至少有一个实例的模型',
        poolTitle: '服务池',
        groupNote: '同模型多实例时由策略（cache_aware 等）选择',
        addWorker: '添加远程服务', searchPlaceholder: '筛选地址 / 模型 / 标签',
        autoRefresh: '自动刷新', autoRefreshOn: '每 3 秒',
        colUrl: '服务地址', colHealth: '健康', colInflight: '在途', colLoad: '负载', colPriority: '优先级',
        colCost: '成本', colType: '类型', colLabels: '标签', colJob: '任务',
        inflightHint: '该实例当前真实在途（尚未结束）的请求数', loadHint: '调度排名分 = 真实在途 + GPU 利用率 × 负载权重（缺省 100）；数值越高越忙，不是并发请求数',
        servedModels: '覆盖模型', modelsVerified: '引擎已验证', modelsDeclared: '按声明填写（未经探针验证）',
        healthHealthy: '健康', healthUnhealthy: '不可用', healthPending: '等待健康探测',
        healthDisabled: '已关闭健康检查',
        jobAddWorker: '注册', jobRemoveWorker: '摘除', jobPending: '排队中',
        jobProcessing: '处理中', jobCompleted: '已完成', jobFailed: '失败',
        addTitle: '添加远程服务', addSubmit: '提交注册', addCopy: '注册是异步的：网关先把实例排入队列，健康探测通过后才会开始接流量。',
        urlField: '服务地址', urlPlaceholder: 'http://10.252.25.217:8200',
        urlRule: '请填写以 http:// 或 https:// 开头的完整地址',
        modelField: '模型 ID（可选）', modelHint: '留空则由网关探测该实例的 /model_info、/server_info 自动填写',
        apiKeyField: 'API Key（可选）', apiKeyHint: '仅上游需要 Bearer 鉴权时填写',
        priorityField: '优先级', costField: '成本权重',
        priorityHint: '数值越小越先被选中，默认 50', costHint: '调度打分用的相对成本，默认 1',
        colCapacity: '容量上限 / 实测',
        // 三道门（doc/caps-redesign-2026-10-06.md §1）：并发下限、并发上限、GPU 利用率上限。
        // 留空的语义各不相同，hint 必须把「留空 = 什么」说准：下限留空等价 1，上限留空 = 不限
        // （不是 0），利用率留空 = 不限（0 是合法的极严档，任何新鲜读数都判满）。
        minConcurrencyField: '并发下限', minConcurrencyHint: '在飞请求数低于该值算「闲」（绿灯优先选它）；整数 1–31，必填，必须小于上限；留空按 1',
        maxConcurrencyField: '并发上限', maxConcurrencyHint: '在飞请求数达到该值后即使有缓存亲和也不再选它（硬排除）；整数 1–32，必须大于下限；留空 = 不限',
        maxGpuUtilField: 'GPU 利用率上限 %', maxGpuUtilHint: '该实例那张卡的利用率（0–100 整数）达到该值后不再选它；留空 = 不限，0 = 极严档（有任何新鲜读数即判满）',
        capUnlimited: '不限', capMeasured: '实测', capNoSample: '未采集',
        capNeedInteger: '必须是整数', capOutOfRange: '必须是 {min}–{max} 之间的整数', capMinBelowMax: '并发下限必须小于并发上限',
        capRequired: '必填：填 1 表示不设下限',
        capNoGate: '未设限',
        // 三态灯的文案：判定只来自后端 /workers 的 load_state，这里只负责说人话。
        loadIdle: '闲', loadBusy: '繁忙', loadFull: '满员', loadUnmanaged: '未设限',
        loadIdleHint: '在飞请求数还没到并发下限：绿灯优先档，选路会先只在这一档里挑。',
        loadBusyHint: '已越过并发下限、还没触到任何上限：可以继续接，直到触顶。',
        loadFullHint: '已触达并发上限或 GPU 利用率上限：此刻被选路硬排除，即使缓存亲和想留在本地也迁走。',
        loadUnmanagedHint: '这台实例没有声明任何容量上限（无门）：颜色不代表忙闲，只表示没人在管它。',
        gpuBadgeHint: '该实例独占的 GPU 卡号，来自服务发现的容器/进程标注；没有标注时不显示。',
        capRuntimeNote: '留空 = 本次不下发该字段（保持池里的现值）；并发上限填 0 撤门，利用率上限填 -1 撤门。',
        labelsField: '标签', labelsHint: '逗号分隔的 k=v，例如 gpu=0,engine=sglang',
        labelsRule: '标签格式为 k=v，多个用逗号分隔',
        disableHealth: '关闭健康检查', disableHealthHint: '关闭后该实例立即视为可用，不再探测 /health',
        addedNotice: '已提交注册：{url}', waitingHealth: '等待健康探测…',
        healthGreenNotice: '{url} 已变健康',
        healthTimeoutNotice: '{url} 在 {n} 秒内未通过健康探测，请确认地址与 /health 端点',
        deleteTitle: '摘除服务', deleteConfirm: '网关会停止把新请求转发到这里，正在进行的请求不受影响。',
        deletedNotice: '已提交摘除：{url}',
        updateTitle: '编辑实例', updateSubmit: '提交更新', updatedNotice: '已提交更新：{url}',
        editFieldsHint: '只提交需要改动的字段，留空表示保持不变',
        emptyPool: '服务池为空', emptyFilter: '没有匹配条件的实例',
        openWorker: '打开该服务', probeNow: '立即刷新列表',
        watcherHint: '标签含 managed-by 的实例由 watcher 维护，在前端摘除后可能被重新发现',
        // ── 实例行的「模型配置」对话框（用户诉求 2026-10-09）──
        // 卡片按**模型名**配（不是按实例名）：一行服务几个模型就几张卡片，字段形状与写入
        // 路径都和「模型管理」页的模型卡片一致（同一个 POST /config/model）。
        // ctx / 最大输出 / 默认档位 / 档位改写 / tool use 那一族的 label 复用 models 块的键
        // （页面里 mt() 取），这里只放服务池页新增的说法。
        mcButton: '配置模型',
        mcTitle: '模型配置',
        mcCopy: '{url}：这一行服务的每个模型各一张卡片，按模型名落盘。卡片是对外的声明（进 /v1/models 与 /props），网关不改写任何输出预算字段；留空 = 未声明（清回引擎自报），false 是结论，两者绝不互相冒充。',
        mcNoModels: '这一行还没有可配的模型名：等探针读到它的 /v1/models，或在「编辑声明条目」里填写模型与覆盖模型。',
        mcStaleRefuse: '配置文档读取失败：卡片此刻是空的或过期的，保存会把没读到的声明当成没人声明过。请重试，或关闭自动刷新后手动刷新一次。',
        mcVirtualNote: '清单还并入虚拟入口按地址或实例 id 绑定归进这一行的实际模型成员：改的就是同一份 model_configs，与「模型管理」页的卡片同源。',
        mcFromPool: '实例注册', mcFromVirtual: '入口归并',
        mcSectionDeclared: '已声明', mcSectionNone: '未声明', mcDirtyMark: '有未保存改动',
        mcSaveAll: '保存卡片', mcSavedAll: '已保存 {n} 张模型卡片', mcNoDirty: '没有需要保存的卡片改动',
        mcFieldRule: '{model}：{message}',
        mcStreamingField: '流式输出（streaming）',
        mcStreamingHint: '填了就以本卡片为准，压过入口与引擎自报；对外声明 supports_streaming。留空 = 不知道，退回引擎自报，两边都没读数时整个键省略。只影响对外声明，不影响转发。',
        mcReasoningField: '推理（reasoning）',
        mcReasoningHint: '填了就以本卡片为准，压过入口与引擎自报；对外声明 supports_reasoning。留空 = 不知道，退回引擎自报，两边都没读数时整个键省略。只影响对外声明，不影响转发。',
        mcVisionField: '视觉（vision）',
        mcVisionHint: '填了就以本卡片为准，压过入口与引擎自报；对外声明 supports_vision。留空 = 不知道，退回引擎自报（其次由卡片模态推断）。只影响对外声明，不影响转发：配了不支持，带图的请求照样转出去。',
        mcEffortSupportField: '档位支持（reasoning effort）',
        mcEffortSupportHint: '填了就以本卡片为准，压过入口与引擎自报；对外声明顶层 supports_reasoning_effort。留空 = 不知道，退回原有派生（有任一份档位读数才是 true）。只影响对外声明，不改任何档位改写。',
        mcHiddenField: '隐藏（不对外广告）',
        mcHiddenHint: '选「是」= 这个名字从 /v1/models 里消失，但照常服务：仍进候选池、仍被 watcher 保留、仍能被虚拟入口选作落点。留空 = 没说，照旧广告。',
        mcDisabledField: '禁用（不广告也不服务）',
        mcDisabledHint: '选「是」= 不广告、不进候选、watcher 摘除，是熔断级别的下线。留空 = 没说。被禁的名字被虚拟入口选中时该落点会被排除，慎用。',
        // 三态下拉的「支持 / 不支持」沿用 models 块那一族文案（toolUseYes / toolUseNo），这里不造第二份；
        // hidden / disabled 用的是「是 / 否」这一组。
        mcYes: '是', mcNo: '否',
        mcMapAdd: '添加改写',
        mcPending: '未保存 {pending} / 共 {total} 张卡片'
      },
      pool: {
        title: '服务池',
        description: '一个地址一行：运行态实例与声明层条目按 URL 合并，标记两者归属；上限与密钥以声明层为事实来源，可持久化并跨重启回放。',
        statDeclared: '声明条目', statDeclaredPending: '{n} 条待入池', statDeclaredOk: '声明全部在池中',
        poolTitle: '服务池', poolNote: '同一地址可能既有声明又有运行实例：徽章说明这份数据此刻归谁管',
        colOrigin: '来源', originDeclared: '声明+在池', originDeclOnly: '仅声明', originDynamic: '动态', originWatcher: 'watcher',
        badgeAlso: '也有声明', alsoHint: '该地址同时出现在声明层：上限与密钥按声明层的口径显示（见上限列的归属徽章）',
        healthNotInPool: '未入池',
        unsupportedNotice: '后端未返回 upstreams 段：当前网关版本过旧，声明层只读；运行态编辑不受影响。',
        autoRefreshOn: '池 3 秒 / 声明 20 秒',
        addTitle: '添加服务', addSubmitDeclared: '保存接入', addSubmitRuntime: '提交注册',
        modeDeclared: '写入声明层（持久化）', modeRuntime: '仅注册到运行池（不持久）',
        addCopyDeclared: '存进配置文档的 upstreams 段并立即同步入池：容器重启自动回放，watcher 清账不会摘除这里声明的实例。',
        addCopyRuntime: '走 POST /workers 直接注册：健康探测通过后接流量，但不写配置文档，重启或 watcher 清账后不会恢复。',
        editDeclared: '编辑声明条目', editRuntime: '编辑运行属性',
        declTitle: '编辑声明条目', declSubmit: '保存修改',
        declCopy: '密钥不回显、无法读出：留空表示保持不变，勾选「清除密钥」才会提交空值。未知字段原样保留，只改写这一条。',
        deleteDeclTitle: '移除声明条目',
        deleteDeclConfirm: '只删配置文档里的这一条：同地址的 watcher 发现实例或手工注册实例不会被摘除。',
        declAddedNotice: '已保存接入：{url}', declUpdatedNotice: '已保存声明修改：{url}', declDeletedNotice: '已移除声明：{url}',
        deletePoolWithDecl: '该地址仍有声明条目：30 秒内会被自愈重新拉回池中。要彻底下线请先移除声明。',
        reconcileNotice: '同步：新增 {added} · 更新 {updated} · 移除 {removed} · 跳过 {skipped}',
        capFromDecl: '按声明', capDrift: '等自愈 · 与声明不一致',
        capDriftHint: '上限的事实来源是声明层：自愈每 30 秒按声明值写回池记录，这个徽章表示池行还没跟上（或刚改完声明）。',
        // 徽章三档（用户裁定 2026-10-10，doc/gap-pool-merge.md §2/§4）：2026-10-04 起自愈对 protected
        // 行做 caps-only 投影（config_store/upstreams.lua 的 upstream_caps_only_patch），声明写了的三档
        // 上限会写进池记录并被执行面读到，所以「管不到」只关于 model_id/models/priority/cost/labels；
        // 旧 tooltip 那句「上限与模型此刻没有生效」的上半句是错的，必须跟着分档走。
        capProjected: '上限按声明 · 投影生效',
        capProjectedHint: '这行由 watcher/bootstrap 持有，声明管不到它的模型与身份字段（model_id/models/priority/cost/labels 此刻惰性）；但三档上限是例外：自愈每 30 秒把声明里写的上限投影进池记录（caps-only），活过容器重建，选路按池记录上这个数硬排除，此刻与声明一致、正在生效。',
        capProjectedDrift: '等自愈 · 上限未跟上',
        capProjectedDriftHint: '上限由自愈每 30 秒从声明以 caps-only 方式投影进池记录，这个徽章表示池行还没跟上（30 秒内会收敛，或刚改完声明）；若长期不动，检查该池行是否被探针摘除。同条目里的模型与身份类字段对这种行仍然惰性。',
        capShadowed: '声明管不到这行', capShadowedHint: '同地址的池行由 watcher/bootstrap 抢先持有，自愈不会覆盖它：声明里没写任何上限，模型与身份类字段（model_id/models/priority/cost/labels）此刻不生效，删掉同地址的动态实例后才会接管。上限若想生效，请写进声明的三档上限 —— 自愈会以 caps-only 方式投影进这一行。',
        capLockedHint: '该地址由声明层管理，上限请在「编辑声明条目」里改：在这里改会在 30 秒内被自愈按声明值覆盖。',
        labelsField: '标签', labelsHint: '逗号分隔的 k=v，例如 gpu=0,engine=sglang',
        labelsJsonPlaceholder: 'gpu=0,engine=sglang',
        // 合并页的两个标签输入框都是 k=v 文本（不是 JSON 对象），必须盖掉 upstreams 段
        // 那句「标签必须是合法的 JSON 对象」，否则报错提示与实际输入格式不符。
        labelsRule: '标签格式为 k=v，多个用逗号分隔',
        jsonButton: '声明 JSON', jsonTitle: '声明层 JSON（upstreams 段）',
        jsonCopy: '整段替换 upstreams：其余配置段由服务端保留。密钥不回显（api_key 恒为 null = 保持不变）；填 "" 清除，填值覆盖。',
        jsonPlaceholder: '[{ "url": "http://10.0.0.5:8000", "model_id": "glm", "max_concurrency": 4 }]',
        jsonSave: '保存整段', jsonReset: '放弃编辑', jsonSavedNotice: '声明层已按 JSON 整段保存',
        jsonMustBeArray: '顶层必须是数组', jsonRowBad: '第 {index} 条不是对象',
        jsonBadParse: 'JSON 解析失败：{message}',
        jsonRowUrl: '第 {index} 条缺少合法 url', jsonDupUrl: '第 {index} 条与前面重复：{url}',
        jsonNoKeyFields: '不要手写 api_key_state / api_key_stored：api_key 用 null（不动）/ ""（清除）/ 文本（设置）',
        keySetHint: '密钥存在这一行的声明条目里，并随它下发到转发路径',
        keySetInert: '密钥未生效', keySetInertHint: '声明条目里写了密钥，但同地址的池行由 watcher/bootstrap 持有，自愈不会覆盖它：此刻这条密钥没有下发，先摘掉同地址的动态实例才会生效。',
        deletePoolTitle: '摘除运行实例', deletePoolConfirm: '只摘这条池记录：网关停止把新请求转发到这里，正在进行的请求不受影响；同地址若还有声明，30 秒内会被自愈拉回来。',
        saveNeedsFreshList: '拿不到最新的声明层整表，已拒绝保存：整表替换下用旧快照或空表提交会删掉其它条目。请重试或关闭自动刷新后手动刷新。',
        jsonConfirmTitle: '整段保存会缩减声明层',
        jsonConfirmEmpty: '这份 JSON 是空数组：保存会删除全部 {n} 条声明，并回收对应的 config 池行。确定？',
        jsonConfirmShrink: '条目从 {before} 条减到 {after} 条：保存是整段替换，少掉的声明会连池行一起被回收。确定？'
      },
      upstreams: {
        title: '服务接入', description: '把远程 LLM 服务（含 API Key）登记进配置层接入池：写入配置文档并立即同步进服务池，容器重启自动回放，watcher 清账不会摘除这里声明的实例。',
        statTotal: '声明条目', statWithKey: '含密钥', statHealthy: '池中健康',
        statHealthyNote: '与服务池按地址比对',
        poolTitle: '接入清单', searchPlaceholder: '筛选地址 / 模型 / 标签',
        unsupportedNotice: '后端未返回 upstreams 段：当前网关版本过旧或该段不可用，页面只读。',
        autoRefreshOn: '每 5 秒',
        colUrl: '服务地址', colModel: '模型 ID', colStatus: '入池状态', colPriority: '优先级',
        colCost: '成本', colLabels: '标签', colKey: '密钥',
        keySet: '已设置', keyNone: '—',
        poolHealthy: '健康', poolUnhealthy: '不可用', poolPending: '等待探测', poolOut: '未入池',
        addUpstream: '添加远程服务', addTitle: '添加远程服务', addSubmit: '保存接入',
        addCopy: '保存走 POST /_ui/config/upstreams 整表替换：写入配置文档并立即同步进服务池，新实例先通过健康探测才接流量。',
        editTitle: '编辑接入条目', editSubmit: '保存修改',
        editCopy: '密钥不回显、无法读出：留空表示保持不变，勾选「清除密钥」才会提交空值。',
        urlField: '服务地址', urlPlaceholder: 'https://api.example.com:443',
        urlRule: '请填写以 http:// 或 https:// 开头的地址（到 host:port，不带路径）',
        modelField: '模型 ID（可选）', modelHint: '缺省 unknown；转发时用该模型 id 匹配上游',
        apiKeyField: 'API Key（可选）', apiKeyHint: '仅上游需要 Bearer 鉴权时填写；存储后不再回显',
        apiKeyKeep: '留空保持不变', clearKey: '清除密钥', clearKeyHint: '勾选后提交空值，网关会移除已存密钥',
        priorityField: '优先级', priorityHint: '数值越小越先被选中，默认 50',
        costField: '成本权重', costHint: '调度打分用的相对成本，默认 1',
        numberRule: '请输入数字',
        colCaps: '上限 / 实测',
        // 这一段会被合并页的 upstreams 覆盖 workers 段（见 workers.html 的 t computed），
        // 所以旧口径必须一起改：留空是「不限」而不是「0」，且不再有功率上限那一档。
        minConcurrencyField: '并发下限', minConcurrencyHint: '在飞请求数低于该值算「闲」（绿灯优先选它）；整数 1–31，必填，必须小于上限；留空按 1',
        maxConcurrencyField: '并发上限', maxConcurrencyHint: '在飞请求数达到该值后即使有缓存亲和也不再选它（硬排除）；整数 1–32，必须大于下限；留空 = 不限',
        maxGpuUtilField: 'GPU 利用率上限 %', maxGpuUtilHint: '该实例那张卡的利用率（0–100 整数）达到该值后不再选它；留空 = 不限，0 = 极严档（有任何新鲜读数即判满）',
          modelsField: '模型列表（可选）', modelsPlaceholder: 'model-a, model-b', modelsHint: '逗号分隔，声明该端点覆盖哪些模型；留空则由 /v1/models 探针决定',
        capMeasured: '实测', capNoSample: '未采集',
        labelsField: '标签（JSON）', labelsHint: '对象形状，例如 {"gpu":"0","engine":"sglang"}',
        labelsRule: '标签必须是合法的 JSON 对象',
        disableHealth: '关闭健康检查', disableHealthHint: '关闭后该实例立即视为可用，不再探测 /health',
        dupUrlNotice: '该地址已在接入清单中',
        addedNotice: '已提交接入：{url}', updatedNotice: '已提交修改：{url}',
        deletedNotice: '已提交移除：{url}',
        reconcileNotice: '同步：新增 {added} · 更新 {updated} · 移除 {removed} · 跳过 {skipped}',
        deleteTitle: '移除接入条目', deleteConfirm: '只影响这里声明的条目：watcher 或手工加入的同地址实例不会被摘除。',
        emptyPool: '还没有接入条目', emptyFilter: '没有匹配的条目',
        openWorker: '打开服务'
      },
      models: {
        title: '模型管理', description: '虚拟模型别名是日常服务的主入口：一个别名映射多个实际模型，由调度策略选路；这里只保留对下游统一的上下文声明与档位覆盖。',
        persistHint: '配置落盘于 {file}',
        mapFrom: '请求档位', mapTo: '下发档位', modelField: '模型 ID',
        effortField: '档位', addRow: '添加条目', rowsEmpty: '暂无条目', cardsSection: '按模型覆盖',
        cardsCopy: '声明上下文窗口、最大输出 token 数、默认档位、档位改写与能力位；卡片说的是落点引擎自己的说法，配了就以卡片为准，压过入口与全局', colModel: '模型', colRegistered: '来源', colCtx: '声明上下文窗口',
        colMaxOutputTokens: '最大输出 token 数',
        colDefaultEffort: '默认档位', colCardMap: '档位改写', colModalities: '能力位', colSources: '实例', registeredYes: '已注册',
        registeredNo: '仅配置', cardTitle: '编辑模型卡片', cardCopy: '{model}：留空的字段保持原值，清空表示恢复自动', ctxField: '声明上下文窗口（token）',
        ctxHint: '对外声明的上下文总窗口（输入+输出），供客户端决定何时压缩；网关不改写任何输出预算字段', ctxRule: '必须是大于 0 的整数', cardEffortMapTitle: '该模型的档位改写',
        maxOutputTokensField: '最大输出 token 数',
        maxOutputTokensHint: '声明给下游 agent 的单次最大输出 token 数，只进 /v1/models 的 capabilities.max_output_tokens；它是对外读数，不参与任何校验或钳制运算，也不代表引擎的真实能力。留空 = 不声明（对外那一格交给引擎自报）',
        maxOutputTokensUnknown: '未声明',
        modalitiesTitle: '能力位（影响 /_ui/props 广告）', modalitiesHint: '清空 = 恢复自动；勾选后按选择广告', cardSave: '保存卡片',
        // tool use 三态（卡片与入口共用一套词表）：nil = 不知道，false = 操作员说了不支持。
        // 两者在解析/落盘/往返里都不许合并，所以表单用三态下拉而不是勾选框。
        cardDefaultEffortHint: '该模型没点档位时下发这一档；卡片是落点引擎自己的说法，配了就覆盖入口与全局的同名字段',
        // ── 档位勾选（用户诉求 2026-10-08）：探测上游允许的档位 + 手动增删 ──
        effortLadderTitle: '允许的档位（对外声明）',
        effortLadderCopy: '上游自报 {detected}；勾选结果决定 /v1/models 对外的 reasoning_efforts。取消某一档 = 对外不再提供它；全部取消等同「从没勾过」，对外退回引擎自报那一组。',
        effortLadderDetected: '探测到 {n} 档',
        effortLadderDetectedNone: '未探测到档位读数',
        effortLadderManual: '已手动添加（上游未报）',
        effortLadderRemoved: '已取消（对外不再提供）',
        effortLadderSetDefault: '设为缺省档',
        effortLadderAutoChip: '档位跟随上游',
        effortLadderRestore: '恢复自动',
        effortLadderDisclosure: '勾选只改对外声明，不改转发：客户端按这里的档位发 reasoning_effort，网关把请求原样转给引擎；勾了引擎其实不收的档位（例如手动补的 xhigh），由引擎自己 400。',
        cardToolUseField: '工具调用（tool use）',
        cardToolUseHint: '填了就以本卡片为准，压过入口与全局；留空 = 不知道，对外声明退回引擎自己报的 supports_tool_use，两边都给不出读数时整个省略这个键',
        colToolUse: '工具调用', toolUseUnknown: '未知', toolUseYes: '支持', toolUseNo: '不支持',
        // ──「隐藏」与「禁用」（用户裁定 2026-10-09）：卡片层与入口层各一份，三态下拉共用一套词 ──
        // 两位都不是能力位：hidden 只关 /v1/models 广告面（照常服务与调度），disabled 是全套排除。
        // 留空 = 删键 = 没说，false 是结论，两者在解析/落盘/往返里绝不合并，所以控件用三态下拉。
        cardSwitchUnknown: '未声明',
        cardHiddenField: '隐藏（不对外广告但继续服务）',
        cardHiddenHint: '只从 /v1/models 里抹掉，仍可被虚拟服务使用和调度。留空 = 没说（照旧广告）；选「不支持」= 明确声明不隐藏，压过入口层的同名声明',
        cardDisabledField: '禁用（不被发现/服务/调度）',
        cardDisabledHint: '全套排除：不出现在 /v1/models、watcher 摘除、路由候选排除。留空 = 没说（照常服务）；被禁的名字按它发的请求会失败',
        declarationDisclosure: '能力位只影响对外声明，不影响转发：配了「不支持工具调用」，带 tools 的请求照样转给引擎，由它自己接受或 400；能力位不含 image，发图的请求也照样转。网关判不准「是否真需要视觉」，误杀代价大于漏放，所以一律放行（与 2026-10-04「网关不改写调用方意图」同向），由客户端按 /v1/models 的 capabilities 自己决定要不要发。',
        cardSaved: '已保存模型卡片 {model}', cardRemove: '清除该模型的全部覆盖', cardRemoveTitle: '清除模型覆盖',
        cardRemoveConfirm: '会同时删除模型卡片与旧的 ctx / 强制档位条目。', clearedNotice: '已清除 {model} 的覆盖配置',
        legacyEffortTitle: '旧版强制档位',
        legacyEffortCopy: '对某个模型一律下发固定档位，优先于卡片与全局', legacyModelField: '模型 ID', legacyCtxField: '声明上下文窗口',
        legacyEffortField: '强制档位', legacyDelete: '删除该行', virtualSection: '虚拟模型（服务入口）',
        virtualCopy: '一个虚拟名 = 一个日常服务入口，一对多映射一组实际模型，由调度策略在组内选路；条目保留对下游统一声明的上下文总窗口（输入+输出），外加档位与能力位的入口级声明。档位是三层继承：卡片 → 条目 → 全局，逐字段、逐 from 查表，第一个命中的赢，所以组内实际模型卡片配了就以卡片为准。调度策略只在「路由策略」页配。',
        virtualAlias: '虚拟名（对下游暴露）', virtualAdd: '添加服务入口', virtualSave: '保存入口表', virtualSaved: '已保存虚拟模型入口表',
        virtualDeleteHint: '删除该行后点击保存生效（整表覆盖提交）', virtualSame: '虚拟名不能与它自己的任何一个实际模型同名', virtualRuleAlias: '虚拟名不能为空',
        virtualBadge: '服务入口', virtualWorkerPlaceholder: 'http://10.252.25.217:8200',
        virtualDupWorker: '{worker} 绑了两个模型：{a} 与 {b}', virtualAliasPlaceholder: '例如 team-chat',
        virtualNothingToSave: '没有需要保存的入口：先添加虚拟名与实际模型', virtualNameUnset: '（未命名）', virtualTargetUnset: '（未填模型名）',
        virtualTargetsTitle: '实际模型组', virtualTargetsCopy: '这个入口对外提供的每个真实模型；绑定实例留空 = 任意能提供它的实例',
        virtualTargetModel: '实际模型名', virtualTargetModelPlaceholder: '例如 Ornith-35B-A3B',
        virtualTargetWorker: '绑定实例（可留空）', virtualTargetAdd: '添加一个实际模型', virtualAnyWorker: '任意实例',
        virtualNoTargets: '还没有实际模型：至少填一个', virtualGroupArrow: '实际模型', virtualCtxField: '声明上下文窗口（token）',
        virtualCtxHint: '留空 = 不声明（整组沿用各模型卡片的声明窗口）', virtualCtxCopy: '本入口对外统一声明的上下文总窗口（输入+输出），供客户端决定何时压缩；它不是输出预算：网关既不拿它改写任何输出预算字段，也不拿它跟卡片声明的「最大输出 token 数」做比较（用户裁定 2026-10-08）', virtualCtxCovered: '声明窗口',
        virtualCtxFollow: '未声明（跟随各模型卡片，整组取最小值）', virtualCtxRule: '声明上下文窗口必须是大于 0 的整数，或留空表示不声明',
        virtualEffortField: '入口缺省档位',
        virtualEffortHint: '留空 = 完全不覆盖：请求没点档位时网关一个字都不动 reasoning_effort，由引擎自选。组内实际模型的卡片配了缺省档位，就以卡片为准',
        virtualEffortCovered: '入口档位', virtualEffortFollow: '档位未覆盖（引擎自选）',
        virtualMapTitle: '入口档位改写',
        virtualMapCopy: '无论上面的缺省档位填没填，这张映射都生效（例如 high→medium）。逐条 from 查表：同一 from 卡片优先于入口、入口优先于全局，第一个给了的赢',
        virtualMapAdd: '添加改写', virtualMapCovered: '入口改写',
        virtualToolField: '工具调用（tool use）', virtualToolUnknown: '不知道（不声明）',
        virtualToolHint: '三态：支持 / 不支持 / 不声明。入口这一层当前只登记（落盘与回显），不改变对外的读数：入口行的 supports_tool_use 来自组内各模型卡片与引擎自报的共识，两者都没有时整个省略这个键；网关也不据此拦截任何请求',
        virtualModalitiesTitle: '入口能力位（vision 等）',
        virtualModalitiesHint: '入口这一层当前只登记（落盘与回显），不改变对外的读数：入口行的能力位取组内各模型卡片与引擎自报的交集，任何一台没开口就整个省略；取消全部勾选 = 不声明（不会写成「只收文本」）。网关也不会据此拒绝发图或发音视频的请求',
        virtualModalityCovered: '能力位', virtualEffortMapNeedsBoth: '档位改写要同时填「请求档位」与「下发档位」，缺一条后端会整条拒绝',
        virtualNeedTargets: '实际模型组不能为空：至少填写一个实际模型名', virtualTargetNeedsModel: '有一行只填了绑定实例、没填实际模型名',
        virtualTargetNotInGroup: '该绑定模型不在实际模型组里（后端会拒绝）', virtualDupAlias: '虚拟名 {alias} 重复：两张入口会互相覆盖，请改成不同的名字',
        virtualChainTarget: '{alias} 的实际模型 {model} 本身也是一个虚拟名：转发的名字没人认识，请先改成真实模型',
        virtualStaleTarget: '{alias} 的旧单值 target {target} 已不在模型组里，但仍是 /v1/models 注入与找卡用的代表值：请在 JSON 视图删掉它，或把它加回组里',
        virtualLegacyWorkers: '收窄到白名单实例', virtualLegacyPolicy: '停用：旧策略字段（热路径不读）',
        virtualLegacyEffort: '停用：旧档位字段（热路径不读）', virtualStaleTargetChip: '旧 target 仍是代表值，且不在组内',
        modelMapSaved: '已提交改名映射', modelMapDeleted: '已删除映射 {orig}', modelMapNeedWatcher: 'watcher 不可用时改名映射无法提交',
        previewSection: '生效预览', previewCopy: '本地静态推算，不发请求：模拟网关对同一个请求的改写结果', previewModel: '请求模型',
        previewEffort: '请求档位', previewEffortNone: '未指定', previewEffortGroupNote: '整组有多个模型：各落点模型按自己的卡片分别推算',
        previewResultModel: '实际模型', previewResultEffort: '下发档位', previewResultCtx: '声明上下文窗口', previewPass: '不改写',
        previewAliasNote: '虚拟别名替换', previewMapNote: '改名映射只影响 watcher 注册的模型名，不改变这里的请求改写',
        previewCtxNote: '对外声明的上下文总窗口（输入+输出），供客户端决定何时压缩；网关不改写任何输出预算字段',
        previewCtxFromEntry: '条目级声明（显式 context_window），与选中的实例无关', previewCtxFromGroupMin: '整组各模型卡片声明窗口的最小值，与选中的实例无关',
        previewCtxFromCard: '取自该模型自己卡片声明的窗口（整组只有一个模型，无条目级声明）', previewCtxGroupNone: '整组没有任何模型卡片给出声明窗口，由客户端与引擎自行约定',
        previewNoCtx: '未声明', previewGroupNote: '一组候选，落点由调度策略决定', previewServing: '可服务实例',
        previewServingYes: '{n} 台实例经 /v1/models 验证', previewServingNo: '没有已验证的实例提供该模型（请求会被拒）',
        previewServingUnverified: '实例列表未经探针验证，暂按可路由处理', previewServingNone: '服务池里没有该模型的实例',
        previewServingGroupGap: '{models} 没有已验证实例，选中它的请求会被拒', previewChainCard: '模型卡片', previewChainEntry: '虚拟条目', previewChainGlobal: '全局',
        previewChainLegacy: '旧版强制档位', previewChainNone: '无（引擎默认）', globalSave: '保存全局策略',
        // ── 虚拟模型「条目列表 + 编辑对话框」（refactor-arch 5.1，w_ui_models 2026-10-05）──
        virtualEntriesEmpty: '还没有虚拟模型入口：点击右上角「添加服务入口」新建一条',
        virtualEditTitle: '编辑服务入口', virtualNewTitle: '新增服务入口',
        // 入口层的两位与卡片层各自独立，判定按「或」汇合（任一说了 true 即命中）：入口可以只藏自己
        // 而组内模型照旧广告，也可以只禁这个入口而不动组内模型的其它落点。
        entryHiddenField: '隐藏（不对外广告但继续服务）',
        entryHiddenHint: '只把这个入口名从 /v1/models 里抹掉：按这个名字发的请求照样能转，组内模型仍进候选池、仍被 watcher 保留。留空 = 没说；卡片层勾了「隐藏」也算命中（两条判据是「或」）',
        entryDisabledField: '禁用（不被发现/服务/调度）',
        entryDisabledHint: '全套排除：这个入口名不出现在 /v1/models、按它发的请求没有候选（落回既有的「无候选」拒绝）、组内成员在候选装配里逐个按 disabled 收窄。留空 = 没说；这是熔断式开关，与只关广告面的「隐藏」分家',
        virtualEditCopy: '一条入口 = 一个对外名字 + 一组实际模型。没编辑过的字段保持磁盘原样；留空的声明位一律写成删键（让位卡片与引擎自报），false 是结论、留空是沉默，两者绝不合并。',
        virtualEntrySave: '保存条目',
        virtualSaveChainNote: '保存 = 先重取服务器整表、只替换这一条，其余条目原样带回（整表提交）',
        virtualAdvertiseEditHint: '对外广告范围在条目编辑对话框里改；卡片底部只回显配置文件里的磁盘状态与空入口告警。',
        virtualBusyJson: '请先关闭或放弃「配置 JSON」对话框，再保存条目：两处都写整份配置，同时编辑会互相覆盖。',
        virtualFreshFailed: '服务器配置读取失败：为避免用过期整表覆盖别人的改动，本次保存已取消',
        virtualEntryGone: '这条入口已不在服务器上（可能被别的会话删除）：请刷新后重试',
        virtualDeleteTitle: '删除服务入口',
        virtualDeleteConfirm: '将把 {alias} 从虚拟入口表中删除（整表提交）：入口对外消失，按这个名字发的请求会失败；它映射的真实模型与实例不受影响。',
        virtualEntrySaved: '已保存服务入口 {alias}', virtualEntryDeleted: '已删除服务入口 {alias}',
        globalSaved: '已保存全局档位策略', pageTitle: '模型管理'
      },
      routing: {
        title: '路由策略', description: '选路策略运行时可改：全局默认与按模型覆盖，保存后下一次选路即生效，无需重启。',
        chainTitle: '生效链', chainCopy: '按模型覆盖 > 全局覆盖 > 实例标签 hint > 环境变量 SMG_POLICY；左侧任一层的值决定该行实际策略',
        globalCard: '全局策略', globalCopy: '没有命中按模型覆盖与 hint 的模型都走这里；未设置时沿用容器环境变量 SMG_POLICY',
        globalField: '全局策略', globalUnset: '未设置（沿用环境变量 SMG_POLICY）', globalSave: '保存全局策略',
        globalSaved: '已保存全局策略：{name}', globalCleared: '已清除全局覆盖，回到 SMG_POLICY={name}',
        envLayer: '环境变量层当前值', effectiveDefault: '全局路径当前生效',
        tableTitle: '按模型策略', tableCopy: '行为已注册与已配置过的模型；「覆盖」下拉留空即跟随上级链条，保存整表一次提交',
        colModel: '模型', colRegistered: '已注册', colOverride: '覆盖', colHint: '实例 hint', colEffective: '当前生效', colSource: '来源',
        registeredYes: '在池', registeredNo: '未注册', inherit: '跟随上级',
        sourceModel: '按模型覆盖', sourceGlobal: '全局覆盖', sourceHint: '实例标签', sourceEnv: 'SMG_POLICY',
        addRow: '添加模型覆盖', modelField: '模型 ID', modelPlaceholder: '精确匹配解析后的模型名', modelRule: '请填写模型 ID',
        policyField: '策略', saveTable: '保存按模型表', tableSaved: '已保存 {n} 条按模型覆盖', tableEmpty: '还没有按模型覆盖，全部模型跟随全局',
        deleteRow: '删除该行', rowDeleted: '已删除 {model} 的覆盖',
        confirmTitle: '确认变更路由策略', confirmGlobal: '全部未命中覆盖与 hint 的流量都会立刻改走 {name}。',
        confirmTable: '将提交 {n} 条按模型覆盖（新增/修改 {changed} 条，删除 {removed} 条）。',
        confirmDanger: '该策略不保证同前缀粘住同一实例，正在使用 cache_aware 亲和性的负载可能整体重新分布。',
        confirmed: '确认切换', applyFailed: '保存失败：{msg}', loadedNote: '配置修订号 {rev}',
        policyDesc: {
          cache_aware: '缓存感知：同前缀请求粘住同一实例，最大化 KV cache 命中（默认）',
          round_robin: '轮询：跨进程共享游标，逐请求轮换实例',
          random: '随机：在候选集内均匀抽签',
          power_of_two: '二选一择低：随机取两实例，投给在途负载低的一方',
          prefix_hash: '前缀哈希：按请求前缀哈希到固定实例，实例增减时最小搬迁',
          consistent_hashing: '一致性哈希：按会话路由键定环，节点变化只搬动一小部分键',
          bucket: '分桶：按负载边界把实例切成桶再选桶内实例',
          manual: '手工：按显式键到实例的映射定向，适合灰度与租户绑定'
        },
        hintUnknown: '未知策略名，按 round_robin 运行', workersHint: '实例标签 policy 由注册时的 labels.policy 提供，运营覆盖优先于它'
      },
      logs: {
        title: '日志监控', description: '网关的请求环形缓冲：过滤、实时追加与逐条路由详情。',
        summaryInflight: '当前并发', summaryReqWindow: '窗口请求', summaryErrors: '窗口错误',
        summaryOut: '输出 tok/s', summaryIn: '输入 tok/s', summaryTokWindow: 'Tok 出/入(60s)', summaryTtft: '平均 TTFT',
        summaryWindow60: '（60s 均值）', summaryTokOut: 'Tok 出', summaryTokIn: '入',
        summaryDuration: '平均耗时', summaryUptime: '运行时长', summaryBuffer: '缓冲',
        bufferNote: '保留 {n} / {c} 条', windowNote: '{n} 秒窗口',
        filterPath: '路径', filterStatus: '状态码', filterModel: '模型', filterText: '搜索',
        filterTextPlaceholder: '请求 ID / 实例 / 会话 / 提供方',
        statusAll: '全部状态', status2xx: '2xx 成功', status4xx: '4xx 客户端', status5xx: '5xx 服务端',
        modelAll: '全部模型', clearFilters: '重置过滤', live: '实时追加', liveOn: '实时流已连接',
        liveOff: '实时流未连接', liveReconnecting: '实时流断开，正在重连',
        clear: '清空列表', clearHint: '只清空本地列表，不影响网关缓冲',
        colTime: '时间', colModel: '模型', colPath: '路径', colStatus: '状态',
        colDuration: '耗时', colTtft: 'TTFT', colTokens: 'Tok 出/入', colRate: 'tok/s',
        colWorker: '实例', colRoute: '策略', colDetail: '',
        expand: '展开详情', collapse: '收起详情',
        detailRequestedModel: '请求模型', detailEffort: '档位（请求 → 生效）',
        detailStream: '流式', detailProvider: '提供方', detailSession: '会话指纹',
        detailId: '请求 ID', detailSeq: '序号', detailCandidates: '候选实例',
        detailSelected: '选中实例', detailCached: '缓存命中 token', detailReasoning: '推理 token',
        detailEstimated: 'token 为估算', detailError: '错误', detailEndpoint: '端点',
        detailTs: '时间戳', yes: '是', no: '否',
        logsDisabled: '请求日志未启用：网关的 LMR_REQUEST_LOG_CAPACITY 为 0，四个日志接口都返回 503。',
        emptyLogs: '暂无请求', emptyFilter: '当前过滤条件下没有记录',
        loadMore: '加载更早', loadedAll: '已加载全部缓冲',
        truncated: '本地列表上限 {n} 条，更早的记录请用「加载更早」'
      }
    },
    'en-US': {
      common: {
        retry: 'Retry', refresh: 'Refresh', cancel: 'Cancel', save: 'Save', create: 'Create',
        add: 'Add', del: 'Delete', edit: 'Edit', actions: 'Actions', status: 'Status',
        model: 'Model', url: 'URL', none: 'none', unset: 'not set', unknown: 'unknown',
        loading: 'Loading', empty: 'No data', required: 'Required', notNumber: 'Must be a number',
        confirm: 'Confirm', search: 'Search', copied: 'Copied', openInTab: 'Open in new tab',
        httpError: 'Request failed', invalidJson: 'Response is not valid JSON',
        secondsUnit: 's', timesUnit: 'x', countUnit: '', rowsUnit: 'rows'
      },
      shell: {
        brand: 'llm-router Console', brandSub: 'Model manager / Service pool / Logs',
        groupManagement: 'Gateway', groupEntry: 'Entry points',
        workers: 'Service pool', workersTitle: 'Unified view of workers and declarations',
        models: 'Model manager', modelsTitle: 'Virtual model aliases, per-model effort and context',
        routing: 'Routing policy', routingTitle: 'Global and per-model routing policy, live without restart',
        logs: 'Log monitor', logsTitle: 'Request ring buffer and live stream',
        chat: 'Chat UI', chatTitle: 'Open the stock llama.cpp webui',
        collapse: 'Collapse menu', expand: 'Expand menu', language: '中文',
        online: 'Gateway online', offline: 'Gateway unreachable',
        healthySummary: 'healthy {ok} of {n}', propsLine: '{model} · n_ctx {ctx}',
        // Sidebar live-throughput panel (2026-10-08): same 60s completion-time window as the logs page summarizeWindow
        throughputTitle: 'Live throughput', throughputWindow: '60s window',
        throughputIn: 'in tok/s (incl. cache)', throughputOut: 'out tok/s', throughputCache: 'cache hit',
        throughputLine: 'requests {n} · errors {e} · avg TTFT {t}',
        dash: '—',
        frameTitle: 'Admin page'
      },
      workers: {
        title: 'Service pool', description: 'Inference workers behind the router, grouped by model, with health and in-flight load. Add or remove remote services.',
        statWorkers: 'Workers', statHealthy: 'Healthy', statModels: 'Models',
        statHealthyNote: 'Health probe every {n}s', statModelsNote: 'Models with at least one worker',
        poolTitle: 'Service pool',
        groupNote: 'For several workers of one model the policy (cache_aware, …) picks one',
        addWorker: 'Add remote service', searchPlaceholder: 'Filter URL / model / labels',
        autoRefresh: 'Auto refresh', autoRefreshOn: 'every 3s',
        colUrl: 'Service URL', colHealth: 'Health', colInflight: 'In flight', colLoad: 'Load', colPriority: 'Priority',
        colCost: 'Cost', colType: 'Type', colLabels: 'Labels', colJob: 'Job',
        inflightHint: 'Requests genuinely in flight on this worker (not yet finished)', loadHint: 'Scheduling rank score = real in-flight + GPU utilization x load weight (default 100); higher means busier, not a concurrency count',
        servedModels: 'Serves', modelsVerified: 'probe-verified', modelsDeclared: 'declared, not probe-verified',
        healthHealthy: 'Healthy', healthUnhealthy: 'Down', healthPending: 'Waiting for probe',
        healthDisabled: 'Health check disabled',
        jobAddWorker: 'register', jobRemoveWorker: 'remove', jobPending: 'queued',
        jobProcessing: 'processing', jobCompleted: 'done', jobFailed: 'failed',
        addTitle: 'Add remote service', addSubmit: 'Submit registration', addCopy: 'Registration is asynchronous: the worker is queued first and only takes traffic once its health probe passes.',
        urlField: 'Service URL', urlPlaceholder: 'http://10.252.25.217:8200',
        urlRule: 'Enter a full URL starting with http:// or https://',
        modelField: 'Model ID (optional)', modelHint: 'Leave blank and the router discovers it from /model_info and /server_info',
        apiKeyField: 'API key (optional)', apiKeyHint: 'Only for upstreams that need Bearer auth',
        priorityField: 'Priority', costField: 'Cost weight',
        priorityHint: 'Lower numbers are preferred, default 50', costHint: 'Relative cost used for scoring, default 1',
        colCapacity: 'Capacity caps / live',
        // Three ceilings (doc/caps-redesign-2026-10-06.md §1). Each blank means something
        // different, so the hints have to say exactly what: a blank floor equals 1, a blank
        // ceiling means unlimited (not 0), a blank utilisation ceiling means unlimited while
        // 0 is the legal strictest rung (any fresh reading counts as full).
        minConcurrencyField: 'Concurrency floor', minConcurrencyHint: 'Below this in-flight count the worker counts as idle (the green tier the scheduler prefers); integer 1-31, required, must stay below the ceiling; blank means 1',
        maxConcurrencyField: 'Concurrency cap', maxConcurrencyHint: 'Once in-flight requests reach this number the worker is skipped even with cache affinity; integer 1-32, must stay above the floor; blank means unlimited',
        maxGpuUtilField: 'GPU utilisation cap %', maxGpuUtilHint: 'Skipped once the utilisation of this worker\'s GPU card (integer 0-100) reaches the value; blank means unlimited, 0 is the strictest rung (any fresh reading counts as full)',
        capUnlimited: 'unlimited', capMeasured: 'live', capNoSample: 'no sample',
        capNeedInteger: 'Must be a whole number', capOutOfRange: 'Must be an integer between {min} and {max}', capMinBelowMax: 'The concurrency floor must be below the concurrency cap',
        capRequired: 'Required: enter 1 for no floor',
        capNoGate: 'no ceiling',
        // Traffic-light wording: the verdict comes from the backend load_state only, this just says it in words.
        loadIdle: 'idle', loadBusy: 'busy', loadFull: 'full', loadUnmanaged: 'uncapped',
        loadIdleHint: 'In-flight requests are still below the concurrency floor: the green tier, which the scheduler picks from first.',
        loadBusyHint: 'Past the concurrency floor but below every ceiling: it still takes traffic until something tops out.',
        loadFullHint: 'At or over the concurrency or GPU-utilisation ceiling: hard-excluded from routing right now, even against cache affinity.',
        loadUnmanagedHint: 'This worker declares no capacity ceiling at all: the colour says nothing about load, only that nobody gated it.',
        gpuBadgeHint: 'GPU card this worker owns, taken from the container/process annotation in service discovery; hidden when there is no annotation.',
        capRuntimeNote: 'Blank = do not send this field (keep the pooled value); 0 clears the concurrency cap, -1 clears the utilisation cap.',
        labelsField: 'Labels', labelsHint: 'Comma separated k=v pairs, e.g. gpu=0,engine=sglang',
        labelsRule: 'Labels must be k=v pairs separated by commas',
        disableHealth: 'Disable health checks', disableHealthHint: 'Treat the worker as available immediately and stop probing /health',
        addedNotice: 'Registration submitted: {url}', waitingHealth: 'Waiting for health probe…',
        healthGreenNotice: '{url} is now healthy',
        healthTimeoutNotice: '{url} did not pass its health probe within {n}s; check the URL and its /health endpoint',
        deleteTitle: 'Remove worker', deleteConfirm: 'The router stops sending new requests here; in-flight requests are unaffected.',
        deletedNotice: 'Removal submitted: {url}',
        updateTitle: 'Edit worker', updateSubmit: 'Submit update', updatedNotice: 'Update submitted: {url}',
        editFieldsHint: 'Only changed fields are sent; empty means keep as is',
        emptyPool: 'The pool is empty', emptyFilter: 'No worker matches the filter',
        openWorker: 'Open this service', probeNow: 'Refresh now',
        watcherHint: 'Workers labelled managed-by belong to the watcher and may be re-discovered after removal',
        // ── Per-worker "Model config" dialog (user request 2026-10-09) ──
        // Cards are keyed by *model name*, not by worker: a row that serves several models
        // gets one card each. Field shape and write path match the model cards on the
        // Model-manager page (same POST /config/model). The ctx / max-output / default-effort
        // / effort-rewrite / tool-use labels are reused from the models block via mt();
        // only the service-pool specific wording lives here.
        mcButton: 'Model config',
        mcTitle: 'Model configuration',
        mcCopy: '{url}: each model this row serves has its own card, stored by model name. A card is an outward advertisement (it lands in /v1/models and /props) and the gateway never rewrites an output budget field; blank means undeclared (clear back to the engine report) while false is a verdict, and the two never stand in for each other.',
        mcNoModels: 'This row has no model name to configure yet: wait for the probe to read its /v1/models, or fill in the model and served models under "Edit declaration".',
        mcStaleRefuse: 'The config document could not be read: the cards are empty or stale right now, so saving would treat declarations we never read as undeclared. Retry, or turn auto-refresh off and refresh manually once.',
        mcVirtualNote: 'The list also merges the real model members that a virtual entry binds into this row by URL or worker id: it is the same model_configs store, shared with the Model-manager cards.',
        mcFromPool: 'worker report', mcFromVirtual: 'entry merge',
        mcSectionDeclared: 'declared', mcSectionNone: 'not declared', mcDirtyMark: 'unsaved changes',
        mcSaveAll: 'Save cards', mcSavedAll: 'Saved {n} model cards', mcNoDirty: 'No card changes to save',
        mcFieldRule: '{model}: {message}',
        mcStreamingField: 'Streaming',
        mcStreamingHint: 'When set, this card wins over the entry and the engine report and advertises supports_streaming. Blank = unknown, so it falls back to the engine and the key is dropped when neither has a reading. Changes the advertisement only, never forwarding.',
        mcReasoningField: 'Reasoning',
        mcReasoningHint: 'When set, this card wins over the entry and the engine report and advertises supports_reasoning. Blank = unknown, so it falls back to the engine and the key is dropped when neither has a reading. Changes the advertisement only, never forwarding.',
        mcVisionField: 'Vision',
        mcVisionHint: 'When set, this card wins over the entry and the engine report and advertises supports_vision. Blank = unknown, so it falls back to the engine report and then to the card modalities. Changes the advertisement only: an image request still goes out when this says unsupported.',
        mcEffortSupportField: 'Effort support (reasoning effort)',
        mcEffortSupportHint: 'When set, this card wins over the entry and the engine report and advertises the top-level supports_reasoning_effort. Blank = unknown, so the existing derivation stays (true when any effort reading exists). Changes the advertisement only and rewrites no effort mapping.',
        mcHiddenField: 'Hide (stop advertising)',
        mcHiddenHint: '"Yes" removes the name from /v1/models while it keeps serving: it stays in the candidate pool, stays registered with the watcher and can still be picked by a virtual entry. Blank = never said, so it keeps being advertised.',
        mcDisabledField: 'Disable (no ads, no serving)',
        mcDisabledHint: '"Yes" means not advertised, excluded from candidates and removed by the watcher: this is an outage-level take-down. Blank = never said. A disabled name is skipped as a virtual-entry landing point, so use with care.',
        // The tri-state dropdown reuses toolUseYes / toolUseNo from the models block instead of a
        // second copy here; hidden / disabled use the yes/no pair.
        mcYes: 'yes', mcNo: 'no',
        mcMapAdd: 'Add rewrite',
        mcPending: '{pending} of {total} cards unsaved'
      },
      pool: {
        title: 'Service pool',
        description: 'One row per URL: runtime workers merged with declared upstreams, with badges saying which layer owns each field right now. Caps and keys are declaration-first, persisted and replayed after restart.',
        statDeclared: 'Declared', statDeclaredPending: '{n} waiting for the pool', statDeclaredOk: 'Every declared URL is in the pool',
        poolTitle: 'Service pool', poolNote: 'One URL can be both declared and running: the badges say who owns what right now',
        colOrigin: 'Origin', originDeclared: 'Declared + running', originDeclOnly: 'Declared only', originDynamic: 'Dynamic', originWatcher: 'watcher',
        badgeAlso: 'Also declared', alsoHint: 'This URL is declared too: caps and the key are shown from the declaration (see the ownership badge in the caps column)',
        healthNotInPool: 'Not in pool',
        unsupportedNotice: 'The gateway returned no upstreams section: the backend is too old, the declaration layer is read-only. Runtime editing still works.',
        autoRefreshOn: 'pool 3s / declarations 20s',
        addTitle: 'Add service', addSubmitDeclared: 'Save upstream', addSubmitRuntime: 'Submit registration',
        modeDeclared: 'Write to declarations (persisted)', modeRuntime: 'Register at runtime only (not persisted)',
        addCopyDeclared: 'Saved into the upstreams section of the config document and reconciled into the pool at once: replayed after restart, and immune to watcher sweeps.',
        addCopyRuntime: 'Posts to POST /workers and joins the pool directly: it takes traffic after a health probe, but nothing is written to the document, so a restart or a watcher sweep will not bring it back.',
        editDeclared: 'Edit declaration', editRuntime: 'Edit runtime fields',
        declTitle: 'Edit declaration', declSubmit: 'Save changes',
        declCopy: 'The key is never echoed back: leave it empty to keep it unchanged; tick "Clear key" to submit an empty value. Fields the form does not show are kept verbatim — only this row is rewritten.',
        deleteDeclTitle: 'Remove declaration',
        deleteDeclConfirm: 'Only the row in the config document is removed: same-URL workers from the watcher or a manual registration stay in the pool.',
        declAddedNotice: 'Upstream saved: {url}', declUpdatedNotice: 'Declaration saved: {url}', declDeletedNotice: 'Upstream removed: {url}',
        deletePoolWithDecl: 'This URL is still declared: the self-heal puts it back into the pool within 30s. Remove the declaration first to take it down for good.',
        reconcileNotice: 'Reconcile: +{added} · ~{updated} · -{removed} · skip {skipped}',
        capFromDecl: 'from declaration', capDrift: 'self-heal pending · differs',
        capDriftHint: 'The declaration owns the caps: the self-heal rewrites the pool row from it every 30s, so this badge only means the pool row has not caught up yet.',
        // Same three-tier badge as zh (user ruling 2026-10-10, doc/gap-pool-merge.md 2/4): since
        // 2026-10-04 the self-heal projects the declared caps onto protected rows via
        // upstream_caps_only_patch, so "cannot reach" is only about the identity fields; the old
        // wording that also declared the caps inert was half wrong.
        capProjected: 'caps as declared · projected',
        capProjectedHint: 'This row is held by the watcher/bootstrap, so the declaration cannot reach its model and identity fields (model_id/models/priority/cost/labels are inert here). The capacity caps are the exception: the self-heal projects whatever the declaration states into the pool record (caps only), surviving a container restart, and routing hard-excludes on that number. It currently matches the declaration and is in effect.',
        capProjectedDrift: 'self-heal pending · caps not caught up',
        capProjectedDriftHint: 'The caps are projected from the declaration into the pool record by the self-heal every 30s; this badge means the pool row has not caught up yet (it converges within 30s, or the declaration was just edited). If it never moves, check whether this pool row was withdrawn by a probe. The model and identity fields in the same entry stay inert for a protected row.',
        capShadowed: 'Declaration cannot reach this row', capShadowedHint: 'The pool row for this URL is held by the watcher/bootstrap, which the self-heal never overwrites: the declaration states no capacity cap at all, and the model/identity fields (model_id/models/priority/cost/labels) are inert until that dynamic row is gone. To make a cap take effect, write it into the three declared cap tiers -- the self-heal projects them onto this row caps-only.',
        capLockedHint: 'This URL is declaration-managed: set the caps under "Edit declaration". Anything sent here is overwritten by the self-heal within 30s.',
        labelsField: 'Labels', labelsHint: 'Comma separated k=v pairs, e.g. gpu=0,engine=sglang',
        labelsJsonPlaceholder: 'gpu=0,engine=sglang',
        // Same reason as zh: the merged page takes k=v text, not a JSON object, so the
        // upstreams-section wording ("valid JSON object") would misdescribe the input.
        labelsRule: 'Labels must be k=v pairs separated by commas',
        jsonButton: 'Declaration JSON', jsonTitle: 'Declaration layer JSON (upstreams section)',
        jsonCopy: 'Replaces the whole upstreams section; every other config section is preserved server-side. Keys are never echoed (api_key null = keep unchanged); "" clears, a value sets.',
        jsonPlaceholder: '[{ "url": "http://10.0.0.5:8000", "model_id": "glm", "max_concurrency": 4 }]',
        jsonSave: 'Save section', jsonReset: 'Discard edits', jsonSavedNotice: 'Declaration section saved from JSON',
        jsonMustBeArray: 'The top level must be an array', jsonRowBad: 'Row {index} is not an object',
        jsonBadParse: 'JSON parse failed: {message}',
        jsonRowUrl: 'Row {index} has no valid url', jsonDupUrl: 'Row {index} repeats an earlier URL: {url}',
        jsonNoKeyFields: 'Do not hand-write api_key_state / api_key_stored: use api_key null (keep) / "" (clear) / text (set)',
        keySetHint: 'The key lives in this row\'s declaration and is sent down the forwarding path with it',
        keySetInert: 'Key inert', keySetInertHint: 'The declaration does carry a key, but the pool row for this URL is held by the watcher/bootstrap, which the self-heal never overwrites: this key is not in effect. Remove the dynamic row for the same URL first.',
        deletePoolTitle: 'Evict runtime worker', deletePoolConfirm: 'Only this pool record is removed: the router stops sending new requests here and in-flight requests are unaffected; if the URL is still declared the self-heal pulls it back within 30s.',
        saveNeedsFreshList: 'The fresh declaration list could not be fetched, so the save was refused: posting a stale or empty list under whole-table replace semantics would delete other entries. Retry, or turn auto-refresh off and refresh manually.',
        jsonConfirmTitle: 'Saving this section shrinks the declarations',
        jsonConfirmEmpty: 'This JSON is an empty array: saving deletes all {n} declared entries and reclaims their config pool rows. Continue?',
        jsonConfirmShrink: 'The list goes from {before} to {after} entries: saving replaces the whole section, and the dropped declarations reclaim their pool rows too. Continue?'
      },
      upstreams: {
        title: 'Upstreams', description: 'Register remote LLM services (with API keys) in the config layer: saved into the runtime document and reconciled into the pool at once, replayed after restart, and immune to watcher sweeping.',
        statTotal: 'Declared', statWithKey: 'With key', statHealthy: 'Healthy in pool',
        statHealthyNote: 'Matched against the pool by URL',
        poolTitle: 'Upstream list', searchPlaceholder: 'Filter URL / model / labels',
        unsupportedNotice: 'Gateway returned no upstreams section: the backend is too old; page is read-only.',
        autoRefreshOn: 'Every 5s',
        colUrl: 'URL', colModel: 'Model ID', colStatus: 'Pool state', colPriority: 'Priority',
        colCost: 'Cost', colLabels: 'Labels', colKey: 'Key',
        keySet: 'Set', keyNone: '—',
        poolHealthy: 'Healthy', poolUnhealthy: 'Down', poolPending: 'Pending probe', poolOut: 'Not in pool',
        addUpstream: 'Add remote service', addTitle: 'Add remote service', addSubmit: 'Save upstream',
        addCopy: 'Saving posts the full list to POST /_ui/config/upstreams: the document is written and reconciled into the pool at once; new workers take traffic after a health probe.',
        editTitle: 'Edit upstream', editSubmit: 'Save changes',
        editCopy: 'The key is never echoed back: leave it empty to keep it unchanged; tick “Clear key” to submit an empty value.',
        urlField: 'URL', urlPlaceholder: 'https://api.example.com:443',
        urlRule: 'Enter an http:// or https:// base URL (host:port, no path)',
        modelField: 'Model ID (optional)', modelHint: 'Defaults to unknown; used to match the upstream when forwarding',
        apiKeyField: 'API Key (optional)', apiKeyHint: 'Only when the upstream needs Bearer auth; never echoed back once stored',
        apiKeyKeep: 'Leave empty to keep', clearKey: 'Clear key', clearKeyHint: 'Submits an empty value and removes the stored key',
        priorityField: 'Priority', priorityHint: 'Lower is preferred, default 50',
        costField: 'Cost weight', costHint: 'Relative cost for scheduling, default 1',
        numberRule: 'Must be a number',
        colCaps: 'Caps / live',
        // Same reason as zh: the merged page lets the upstreams section override the workers
        // section, so the stale wording has to be fixed here too. Blank means unlimited, not 0,
        // and there is no watt ceiling any more.
        minConcurrencyField: 'Concurrency floor', minConcurrencyHint: 'Below this in-flight count the worker counts as idle (the green tier the scheduler prefers); integer 1-31, required, must stay below the ceiling; blank means 1',
        maxConcurrencyField: 'Concurrency cap', maxConcurrencyHint: 'Once in-flight requests reach this number the worker is skipped even with cache affinity; integer 1-32, must stay above the floor; blank means unlimited',
        maxGpuUtilField: 'GPU utilisation cap %', maxGpuUtilHint: 'Skipped once the utilisation of this worker\'s GPU card (integer 0-100) reaches the value; blank means unlimited, 0 is the strictest rung (any fresh reading counts as full)',
          modelsField: 'Models (optional)', modelsPlaceholder: 'model-a, model-b', modelsHint: 'Comma separated; declares which models this endpoint covers. Blank leaves it to the /v1/models probe',
        capMeasured: 'live', capNoSample: 'no sample',
        labelsField: 'Labels (JSON)', labelsHint: 'A plain object, e.g. {"gpu":"0","engine":"sglang"}',
        labelsRule: 'Labels must be a valid JSON object',
        disableHealth: 'Disable health check', disableHealthHint: 'Treats the worker as available immediately, no /health probe',
        dupUrlNotice: 'This URL is already in the upstream list',
        addedNotice: 'Upstream submitted: {url}', updatedNotice: 'Changes submitted: {url}',
        deletedNotice: 'Upstream removed: {url}',
        reconcileNotice: 'Reconcile: +{added} · ~{updated} · -{removed} · skip {skipped}',
        deleteTitle: 'Remove upstream', deleteConfirm: 'Only this declared entry is affected: same-URL workers from the watcher or manual registration are untouched.',
        emptyPool: 'No upstream declared', emptyFilter: 'No row matches the filter',
        openWorker: 'Open service'
      },
      models: {
        title: 'Model manager',
        description: 'Virtual aliases are the everyday entry point: one alias maps to several real models and the policy picks one. This page keeps the downstream-uniform declared context window and effort overrides.',
        persistHint: 'Persisted to {file}',
        mapFrom: 'Requested', mapTo: 'Forwarded', modelField: 'Model ID', effortField: 'Effort', addRow: 'Add entry',
        rowsEmpty: 'No entries', cardsSection: 'Per-model overrides',
        cardsCopy: 'Declared context window, max output tokens, default effort, effort rewrite and modalities; a card is the landing engine speaking for itself, so it wins over the entry and the global policy',
        colModel: 'Model', colRegistered: 'Origin', colCtx: 'Declared window', colMaxOutputTokens: 'Max output tokens', colDefaultEffort: 'Default effort',
        colCardMap: 'Effort rewrite', colModalities: 'Modalities', colSources: 'Workers', registeredYes: 'registered',
        registeredNo: 'configured only', cardTitle: 'Edit model card',
        cardCopy: '{model}: empty fields keep the current value, clearing restores auto',
        ctxField: 'Declared context window (tokens)',
        ctxHint: 'The total window (input + output) this entry advertises downstream so clients know when to compress; the gateway never rewrites an output budget field',
        maxOutputTokensField: 'Max output tokens',
        maxOutputTokensHint: 'The single-turn output ceiling advertised to downstream agents; it only lands in capabilities.max_output_tokens of /v1/models. It is an advertisement: no validation, no clamping, and it does not state the engine capability. Blank = not declared (the cell then follows the engine report)',
        maxOutputTokensUnknown: 'not declared',
        ctxRule: 'Must be an integer greater than zero', cardEffortMapTitle: 'Effort rewrite for this model',
        modalitiesTitle: 'Modalities (advertised by /_ui/props)',
        modalitiesHint: 'Clear to restore auto; the selection is advertised as-is', cardSave: 'Save card',
        cardDefaultEffortHint: 'Effort forwarded when this model is asked without one; a card is the landing engine speaking for itself, so it overrides the entry and global field of the same name',
        // ── Effort ladder checkboxes (user request 2026-10-08) ──
        effortLadderTitle: 'Allowed efforts (advertised)',
        effortLadderCopy: 'Reported by the upstream: {detected}. The ticks decide reasoning_efforts in /v1/models. Unticking one rung removes it from what is advertised; unticking all of them equals "never ticked", so the advertisement follows the engine again.',
        effortLadderDetected: '{n} detected',
        effortLadderDetectedNone: 'no effort reading detected',
        effortLadderManual: 'added manually (not reported upstream)',
        effortLadderRemoved: 'unticked (no longer advertised)',
        effortLadderSetDefault: 'Set as default effort',
        effortLadderAutoChip: 'efforts follow upstream',
        effortLadderRestore: 'Restore auto',
        effortLadderDisclosure: 'The ticks change only what is advertised, never what is forwarded: the client sends reasoning_effort from this list and the gateway forwards the request untouched. An effort the engine actually rejects (for example a manually added xhigh) gets the engine\'s own 400.',
        cardToolUseField: 'Tool use',
        cardToolUseHint: 'When set, this card wins over the entry and the global policy; blank = unknown, so the advertised value falls back to what the engine reports as supports_tool_use, and the key is dropped entirely when neither side has a reading',
        colToolUse: 'Tool use', toolUseUnknown: 'unknown', toolUseYes: 'supported', toolUseNo: 'unsupported',
        // ── "Hidden" and "disabled" (root ruling 2026-10-09): card layer plus entry layer, one
        // shared tri-state wording. Neither is a capability flag: hidden only drops the name from
        // the /v1/models advertisement while it keeps serving, disabled is the full exclusion.
        // Blank = key deleted = the operator never spoke; false is a conclusion. Never merged, so
        // the control is a tri-state select rather than a checkbox.
        cardSwitchUnknown: 'not declared',
        cardHiddenField: 'Hidden (not advertised, still serving)',
        cardHiddenHint: 'Removes the name from /v1/models only: virtual entries can still use and schedule it. Blank = never spoken (advertised as before); "unsupported" = an explicit "do not hide", which outranks the entry-level claim of the same name',
        cardDisabledField: 'Disabled (not discoverable, not served, not scheduled)',
        cardDisabledHint: 'Full exclusion: absent from /v1/models, unregistered by the watcher, and removed from the routing candidates. Blank = never spoken (served as before); requests naming a disabled model will fail',
        declarationDisclosure: 'Capability flags only change what is advertised, never what is forwarded: a request with tools still goes to the engine even when tool use is set to unsupported, and an image request still goes when image is not ticked. The gateway cannot tell whether vision is really needed, and a false refusal costs more than a missed one, so everything is passed through (same direction as the 2026-10-04 ruling that the gateway does not rewrite caller intent); the client decides from capabilities in /v1/models.',
        cardSaved: 'Model card saved for {model}', cardRemove: 'Clear all overrides',
        cardRemoveTitle: 'Clear model overrides',
        cardRemoveConfirm: 'Removes the model card plus the legacy ctx and forced-effort rows.',
        clearedNotice: 'Overrides cleared for {model}',
        legacyEffortTitle: 'Legacy forced effort',
        legacyEffortCopy: 'Pins one effort per model and outranks cards and global policy',
        legacyModelField: 'Model ID', legacyCtxField: 'Declared window', legacyEffortField: 'Forced effort',
        legacyDelete: 'Remove row',
        virtualSection: 'Virtual models (service entries)',
        virtualCopy: 'One virtual name is one everyday service entry: it maps to a group of real models and the policy picks inside the group. The entry keeps the total context window (input + output) it declares downstream, plus entry-level effort and capability claims. Effort is inherited in three layers: card -> entry -> global, field by field and per from, first match wins, so a model card inside the group that sets a value wins over this field. Routing policy lives on the Routing page only.',
        virtualAlias: 'Virtual name (public)', virtualAdd: 'Add service entry', virtualSave: 'Save entries',
        virtualSaved: 'Virtual model entries saved',
        virtualDeleteHint: 'Remove the row, then save to apply (the table is replaced)',
        virtualSame: 'A virtual name cannot equal one of its own real models',
        virtualRuleAlias: 'Virtual name is required', virtualBadge: 'service entry',
        virtualWorkerPlaceholder: 'http://10.252.25.217:8200',
        virtualDupWorker: '{worker} is bound to two models: {a} and {b}', virtualAliasPlaceholder: 'e.g. team-chat',
        virtualNothingToSave: 'Nothing to save: add a virtual name and at least one real model first',
        virtualNameUnset: '(unnamed)', virtualTargetUnset: '(no model name)', virtualTargetsTitle: 'Real model group',
        virtualTargetsCopy: 'Every real model this entry serves; leave the worker blank to let any instance that provides it serve the request',
        virtualTargetModel: 'Real model name', virtualTargetModelPlaceholder: 'e.g. Ornith-35B-A3B',
        virtualTargetWorker: 'Bound worker (optional)', virtualTargetAdd: 'Add a real model',
        virtualAnyWorker: 'any instance', virtualNoTargets: 'No real models yet: add at least one',
        virtualGroupArrow: 'real models', virtualCtxField: 'Declared context window (tokens)',
        virtualCtxHint: 'blank = not declared (the group follows each model card)',
        virtualCtxCopy: 'The total context window (input + output) this entry advertises downstream so clients know when to compress; it is not an output budget — the gateway neither rewrites an output budget field with it nor compares it with the max output tokens declared on the cards (root ruling 2026-10-08)',
        virtualCtxCovered: 'declared window', virtualCtxFollow: 'not declared (follows each model card, group minimum)',
        virtualCtxRule: 'The declared context window must be an integer greater than zero, or blank for no declaration',
        virtualEffortField: 'Entry default effort',
        virtualEffortHint: 'blank = no override at all: when the request names no effort the gateway leaves reasoning_effort untouched and the engine picks. A model card inside the group that sets a default wins over this field',
        virtualEffortCovered: 'entry effort', virtualEffortFollow: 'effort not overridden (engine default)',
        virtualMapTitle: 'Entry effort rewrite',
        virtualMapCopy: 'This mapping applies whether or not the default effort above is set (for example high→medium). Looked up per from: card beats entry beats global, the first layer that provides a given from wins',
        virtualMapAdd: 'Add rewrite', virtualMapCovered: 'entry rewrite',
        virtualToolField: 'Tool use', virtualToolUnknown: 'unknown (not declared)',
        virtualToolHint: 'Tri-state: supported / unsupported / not declared. At the entry level this is recorded only (it persists and round-trips) and does not change the advertised reading: the entry supports_tool_use comes from what the group cards and the engines agree on, and the key is dropped when neither has one. The gateway also blocks nothing based on it',
        virtualModalitiesTitle: 'Entry modalities (vision, etc.)',
        virtualModalitiesHint: 'At the entry level this is recorded only (it persists and round-trips) and does not change the advertised reading: the entry modalities are the intersection over the group cards and engine reports, and the key is dropped when any member stays silent; ticking nothing = not declared (never written as text-only). The gateway still forwards image or media requests',
        virtualModalityCovered: 'modalities', virtualEffortMapNeedsBoth: 'An effort rewrite needs both the requested and the forwarded effort; the backend rejects a half-filled row',
        virtualNeedTargets: 'The real model group cannot be empty: add at least one model name',
        virtualTargetNeedsModel: 'A row binds a worker without naming its real model',
        virtualTargetNotInGroup: 'This bound model is not in the group (the backend would refuse it)',
        virtualDupAlias: 'Virtual name {alias} is duplicated: the two entries would overwrite each other, pick distinct names',
        virtualChainTarget: '{alias} lists {model} as a real model, but that name is itself a virtual entry and nothing upstream knows it; point the row at a real model first',
        virtualStaleTarget: '{alias} still carries the legacy single target {target}, which left the group yet remains the representative used for /v1/models and card lookups: drop it in the JSON view or put it back in the group',
        virtualLegacyWorkers: 'limited to allow-list workers',
        virtualLegacyPolicy: 'inactive: legacy policy field (not read)',
        virtualLegacyEffort: 'inactive: legacy effort field (not read)',
        virtualStaleTargetChip: 'legacy target still the representative and outside the group',
        modelMapSaved: 'Rename mapping submitted', modelMapDeleted: 'Mapping deleted for {orig}',
        modelMapNeedWatcher: 'The rename map cannot be submitted while the watcher is unavailable',
        previewSection: 'Effective preview',
        previewCopy: 'Derived locally, no request sent: what the gateway would rewrite for one request',
        previewModel: 'Requested model', previewEffort: 'Requested effort', previewEffortNone: 'not set',
        previewEffortGroupNote: 'the group has several models: each landing model uses its own card',
        previewResultModel: 'Actual model', previewResultEffort: 'Forwarded effort',
        previewResultCtx: 'Declared window', previewPass: 'unchanged', previewAliasNote: 'virtual alias',
        previewMapNote: 'The rename map only affects ids registered by the watcher, not this request rewrite',
        previewCtxNote: 'the total window advertised downstream; the gateway rewrites no output budget field',
        previewCtxFromEntry: 'entry-level declaration (explicit context_window), independent of the pick',
        previewCtxFromGroupMin: 'minimum of the declared windows over the group cards, independent of the pick',
        previewCtxFromCard: 'from the model card itself (single-model group, no entry-level declaration)',
        previewCtxGroupNone: 'no card in the group declares a window; client and engine settle it',
        previewNoCtx: 'not declared',
        previewGroupNote: 'candidate group, the policy picks the landing model', previewServing: 'Serving workers',
        previewServingYes: '{n} workers verified via /v1/models',
        previewServingNo: 'no verified worker serves this model (requests would be refused)',
        previewServingUnverified: 'worker model lists are not probe-verified; treated as routable',
        previewServingNone: 'no worker in the pool serves this model',
        previewServingGroupGap: 'no verified worker serves {models}; requests landing there would be refused',
        previewChainCard: 'model card', previewChainEntry: 'virtual entry', previewChainGlobal: 'global',
        previewChainLegacy: 'legacy forced effort',
        previewChainNone: 'none (engine default)', globalSave: 'Save global policy',
        // ── Virtual model entry list + edit dialog (refactor-arch 5.1, w_ui_models 2026-10-05) ──
        virtualEntriesEmpty: 'No service entries yet: use "Add service entry" at the top right',
        virtualEditTitle: 'Edit service entry', virtualNewTitle: 'New service entry',
        // Entry layer of the two switches: each layer is independent and the verdicts OR together
        // (either side saying true wins), so an entry can hide itself while its group models stay
        // advertised, or disable just this entry without touching other landing points.
        entryHiddenField: 'Hidden (not advertised, still serving)',
        entryHiddenHint: 'Removes this entry name from /v1/models only: requests by that name still forward, the group models still enter the candidate pool and stay registered with the watcher. Blank = never spoken; a card that claims hidden also wins (the two verdicts are an "or")',
        entryDisabledField: 'Disabled (not discoverable, not served, not scheduled)',
        entryDisabledHint: 'Full exclusion: the entry name disappears from /v1/models, requests by that name get no candidates (the existing "no candidates" refusal), and group members are filtered per member by disabled. Blank = never spoken; this is a circuit-breaker switch, kept apart from hidden, which only closes the advertisement',
        virtualEditCopy: 'One entry = one public name plus a group of real models. Fields you never touch stay byte-identical on disk; a blank declaration field is written as a deleted key (the card and the engine get to speak), and false is a conclusion while blank is silence — never merged.',
        virtualEntrySave: 'Save entry',
        virtualSaveChainNote: 'Save = re-fetch the whole table from the server, replace only this entry, and carry every other entry through unchanged',
        virtualAdvertiseEditHint: 'The advertisement scope is edited inside the entry dialog; the card footer only mirrors the disk state and the empty-entry warning.',
        virtualBusyJson: 'Close or discard the Config JSON dialog before saving the entry: both write the whole document, so editing them at the same time would overwrite each other.',
        virtualFreshFailed: 'Could not read the server configuration: the save was cancelled so a stale whole table cannot overwrite someone else',
        virtualEntryGone: 'This entry no longer exists on the server (another session may have deleted it): refresh and retry',
        virtualDeleteTitle: 'Delete service entry',
        virtualDeleteConfirm: '{alias} is removed from the virtual entry table (the whole table is submitted): the entry disappears from the advertisement and requests by that name will fail; the real models and workers it maps to are untouched.',
        virtualEntrySaved: 'Service entry {alias} saved', virtualEntryDeleted: 'Service entry {alias} deleted',
        globalSaved: 'Global effort policy saved', pageTitle: 'Model management'
      },
      routing: {
        title: 'Routing policy', description: 'Change the routing policy at runtime: global default and per-model overrides apply on the next selection, no restart.',
        chainTitle: 'Precedence chain', chainCopy: 'per-model override > global override > worker label hint > SMG_POLICY; the first layer with a value wins the row',
        globalCard: 'Global policy', globalCopy: 'Models without a per-model override or hint use this; unset keeps the container SMG_POLICY',
        globalField: 'Global policy', globalUnset: 'unset (follows SMG_POLICY)', globalSave: 'Save global policy',
        globalSaved: 'Global policy saved: {name}', globalCleared: 'Global override cleared, back to SMG_POLICY={name}',
        envLayer: 'Environment layer', effectiveDefault: 'Effective on the global path',
        tableTitle: 'Per-model policies', tableCopy: 'Rows cover registered and previously configured models; an empty override follows the chain above. The whole table is submitted at once.',
        colModel: 'Model', colRegistered: 'Registered', colOverride: 'Override', colHint: 'Worker hint', colEffective: 'Effective', colSource: 'From',
        registeredYes: 'in pool', registeredNo: 'unregistered', inherit: 'inherit',
        sourceModel: 'per-model', sourceGlobal: 'global', sourceHint: 'label', sourceEnv: 'SMG_POLICY',
        addRow: 'Add model override', modelField: 'Model ID', modelPlaceholder: 'Exact resolved model name', modelRule: 'Model ID is required',
        policyField: 'Policy', saveTable: 'Save per-model table', tableSaved: 'Saved {n} per-model overrides', tableEmpty: 'No per-model overrides yet; every model follows the global layer',
        deleteRow: 'Remove row', rowDeleted: 'Removed the override for {model}',
        confirmTitle: 'Confirm routing change', confirmGlobal: 'All traffic that matches no override or hint switches to {name} immediately.',
        confirmTable: 'Submitting {n} per-model overrides ({changed} new/changed, {removed} removed).',
        confirmDanger: 'This policy does not keep one prefix on one worker; workloads relying on cache_aware affinity will redistribute.',
        confirmed: 'Apply change', applyFailed: 'Save failed: {msg}', loadedNote: 'config revision {rev}',
        policyDesc: {
          cache_aware: 'Cache-aware: sticky per prefix to maximize KV cache hits (default)',
          round_robin: 'Round robin: cursor shared across processes, one worker per request',
          random: 'Random: uniform draw over the candidates',
          power_of_two: 'Power of two: pick two workers at random, send to the less loaded',
          prefix_hash: 'Prefix hash: hash the request prefix onto a fixed worker with minimal reshuffle',
          consistent_hashing: 'Consistent hashing: session routing key onto a hash ring, small key moves',
          bucket: 'Bucket: load-boundary buckets, then one worker inside the bucket',
          manual: 'Manual: explicit key-to-worker mapping, for canaries and tenant pinning'
        },
        hintUnknown: 'unknown policy name, running as round_robin', workersHint: 'The hint comes from the worker labels.policy at registration; operator overrides outrank it'
      },
      logs: {
        title: 'Log monitor', description: 'The gateway request ring buffer: filters, live append and per-request routing detail.',
        summaryInflight: 'In flight', summaryReqWindow: 'Requests', summaryErrors: 'Errors',
        summaryOut: 'out tok/s', summaryIn: 'in tok/s', summaryTokWindow: 'Tok out/in (60s)', summaryTtft: 'Avg TTFT',
        summaryWindow60: '(60s avg)', summaryTokOut: 'Tok out', summaryTokIn: 'in',
        summaryDuration: 'Avg duration', summaryUptime: 'Uptime', summaryBuffer: 'Buffer',
        bufferNote: '{n} of {c} kept', windowNote: '{n}s window',
        filterPath: 'Path', filterStatus: 'Status', filterModel: 'Model', filterText: 'Search',
        filterTextPlaceholder: 'request id / worker / session / provider',
        statusAll: 'Any status', status2xx: '2xx ok', status4xx: '4xx client', status5xx: '5xx server',
        modelAll: 'Any model', clearFilters: 'Reset filters', live: 'Live append', liveOn: 'Stream connected',
        liveOff: 'Stream offline', liveReconnecting: 'Stream lost, reconnecting',
        clear: 'Clear list', clearHint: 'Clears the local list only, the gateway buffer stays intact',
        colTime: 'Time', colModel: 'Model', colPath: 'Path', colStatus: 'Status',
        colDuration: 'Duration', colTtft: 'TTFT', colTokens: 'Tok out/in', colRate: 'tok/s',
        colWorker: 'Worker', colRoute: 'Policy', colDetail: '',
        expand: 'Show detail', collapse: 'Hide detail',
        detailRequestedModel: 'Requested model', detailEffort: 'Effort (requested → effective)',
        detailStream: 'Streaming', detailProvider: 'Provider', detailSession: 'Session key',
        detailId: 'Request ID', detailSeq: 'Sequence', detailCandidates: 'Candidates',
        detailSelected: 'Selected worker', detailCached: 'Cached tokens', detailReasoning: 'Reasoning tokens',
        detailEstimated: 'tokens estimated', detailError: 'Error', detailEndpoint: 'Endpoint',
        detailTs: 'Timestamp', yes: 'yes', no: 'no',
        logsDisabled: 'Request logging is disabled: LMR_REQUEST_LOG_CAPACITY is 0 and every log route answers 503.',
        emptyLogs: 'No requests yet', emptyFilter: 'No record matches the filters',
        loadMore: 'Load older', loadedAll: 'Whole buffer loaded',
        truncated: 'Local list capped at {n}; use “Load older” for earlier records'
      }
    }
  }

  function normalize (locale) {
    return locale === 'en-US' ? 'en-US' : 'zh-CN'
  }

  function getLocale () {
    let stored = null
    try { stored = window.localStorage.getItem(STORAGE_KEY) } catch (err) { stored = null }
    return normalize(stored)
  }

  // 在 iframe 内时通知主壳（window.top），同源的其它 tab 由 storage 事件收到。
  function setLocale (locale) {
    const nextLocale = normalize(locale)
    try { window.localStorage.setItem(STORAGE_KEY, nextLocale) } catch (err) { /* 隐私模式：仅本次会话 */ }
    try {
      if (window.top && window.top !== window) {
        window.top.postMessage({ type: MESSAGE_TYPE, locale: nextLocale }, window.location.origin)
      }
    } catch (err) { /* 跨域壳：忽略 */ }
    return nextLocale
  }

  function subscribe (callback) {
    const handleStorage = event => {
      if (event.key === STORAGE_KEY) callback(normalize(event.newValue))
    }
    const handleMessage = event => {
      if (event.origin === window.location.origin && event.data && event.data.type === MESSAGE_TYPE) {
        callback(normalize(event.data.locale))
      }
    }
    window.addEventListener('storage', handleStorage)
    window.addEventListener('message', handleMessage)
    return () => {
      window.removeEventListener('storage', handleStorage)
      window.removeEventListener('message', handleMessage)
    }
  }

  function applyQuasarLang (locale) {
    Quasar.Lang.set(locale === 'en-US' ? Quasar.Lang.enUS : Quasar.Lang.zhCN)
  }

  // 词典取值：插值 {name}，缺失的键回退到中文块，保证不出现空白文案。
  function translate (locale, block, key, values) {
    const dict = messages[locale] || messages['zh-CN']
    let text = (dict[block] && dict[block][key])
    if (text === undefined) {
      const fallback = messages['zh-CN']
      text = fallback[block] && fallback[block][key]
    }
    if (text === undefined) return key
    if (!values) return text
    return String(text).replace(/\{(\w+)\}/g, (match, name) => (values[name] === undefined ? match : String(values[name])))
  }

  window.lmrI18n = {
    getLocale, setLocale, subscribe, applyQuasarLang, translate, messages,
    storageKey: STORAGE_KEY, messageType: MESSAGE_TYPE
  }
})()
