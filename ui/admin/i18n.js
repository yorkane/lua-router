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
        brand: 'llm-router 控制台', brandSub: '服务池 / 模型覆盖 / 日志',
        groupManagement: '网关管理', groupEntry: '入口',
        workers: '服务池', workersTitle: '查看与增删推理实例',
        upstreams: '服务接入', upstreamsTitle: '远程服务接入池与 API Key 持久化',
        models: '模型覆盖', modelsTitle: '改名映射、虚拟别名与按模型档位/上下文',
        routing: '路由策略', routingTitle: '全局与按模型的选路策略，改完即刻生效',
        logs: '日志监控', logsTitle: '请求环形缓冲与实时流',
        chat: '聊天界面', chatTitle: '打开原版 llama.cpp webui',
        collapse: '收起菜单', expand: '展开菜单', language: 'English',
        online: '网关在线', offline: '网关不可达',
        healthySummary: '健康 {ok} / 共 {n}', propsLine: '{model} · n_ctx {ctx}',
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
        colUrl: '服务地址', colHealth: '健康', colLoad: '在途', colPriority: '优先级',
        colCost: '成本', colType: '类型', colLabels: '标签', colJob: '任务',
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
        colCapacity: '上限 / 实测',
        maxConcurrencyField: '并发上限（可选）', maxConcurrencyHint: '在飞请求数达到该值后即使有缓存亲和也不再选它；留空或 0 表示不限',
        maxPowerField: '功率上限 W（可选）', maxPowerHint: '该实例所在机器最热一张卡的瓦数达到该值后不再选它；留空或 0 表示不限',
        capUnlimited: '不限', capMeasured: '实测', capNoSample: '实测 —（无采样）',
        capRule: '请输入数字；留空或 0 表示不限',
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
        watcherHint: '标签含 managed-by 的实例由 watcher 维护，在前端摘除后可能被重新发现'
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
        maxConcurrencyField: '并发上限（可选）', maxConcurrencyHint: '在飞请求数达到该值后即使有缓存亲和也不再选它；留空或 0 表示不限',
        maxPowerField: '功率上限 W（可选）', maxPowerHint: '该实例所在机器最热一张卡的瓦数达到该值后不再选它；留空或 0 表示不限',
        modelsField: '模型列表（可选）', modelsPlaceholder: 'model-a, model-b', modelsHint: '逗号分隔，声明该端点覆盖哪些模型；留空则由 /v1/models 探针决定',
        capMeasured: '实测', capNoSample: '实测 —（无采样）',
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
        title: '模型覆盖配置', description: '改写上层的模型名与请求参数：watcher 改名映射、虚拟别名、按模型的档位与上下文上限。',
        persistHint: '配置落盘于 {file}', watcherReachable: 'watcher 在线', watcherUnreachable: 'watcher 不可达',
        watcherNotConfigured: '未配置 LMR_WATCHER_URL',
        globalSection: '全局档位策略', globalCopy: '没有按模型覆盖时对所有请求生效',
        defaultEffort: '默认推理强度', defaultEffortHint: '请求未指名档位时使用；留空表示交给引擎默认',
        effortMapTitle: '档位改写', effortMapCopy: '请求指定档位时的映射，例如 high → max',
        modelEffortTitle: '强制档位（旧字段）', modelEffortCopy: '对某个模型一律下发固定档位，优先级最高',
        mapFrom: '请求档位', mapTo: '下发档位', modelField: '模型 ID', effortField: '档位',
        addRow: '添加条目', rowsEmpty: '暂无条目',
        cardsSection: '按模型覆盖', cardsCopy: '上下文上限、默认档位、档位改写与能力位；卡片配置优先于全局',
        colModel: '模型', colRegistered: '来源', colCtx: '上下文上限', colDefaultEffort: '默认档位',
        colCardMap: '档位改写', colModalities: '能力位', colSources: '实例',
        registeredYes: '已注册', registeredNo: '仅配置',
        cardTitle: '编辑模型卡片', cardCopy: '{model}：留空的字段保持原值，清空表示恢复自动',
        ctxField: '上下文上限（token）', ctxHint: '钳制 max_tokens / max_completion_tokens',
        ctxRule: '必须是大于 0 的整数', cardEffortMapTitle: '该模型的档位改写',
        modalitiesTitle: '能力位（影响 /_ui/props 广告）', modalitiesHint: '清空 = 恢复自动；勾选后按选择广告',
        cardSave: '保存卡片', cardSaved: '已保存模型卡片 {model}', cardRemove: '清除该模型的全部覆盖', cardRemoveTitle: '清除模型覆盖',
        cardRemoveConfirm: '会同时删除模型卡片与旧的 ctx / 强制档位条目。',
        clearedNotice: '已清除 {model} 的覆盖配置',
        legacyCtxTitle: '旧版上下文上限（非卡片）', legacyCtxCopy: '仅在没有模型卡片时生效；模型卡片里的 ctx 优先',
        legacyEffortTitle: '旧版强制档位', legacyEffortCopy: '对某个模型一律下发固定档位，优先于卡片与全局',
        legacyModelField: '模型 ID', legacyCtxField: '上下文上限', legacyEffortField: '强制档位',
        legacySave: '保存旧字段', legacyDelete: '删除该行',
        virtualSection: '虚拟模型别名', virtualCopy: '上层用一个别名请求，网关换成真实模型；可以给不同实例各绑一个模型，也可以整池共用一个；整表覆盖提交',
        virtualAlias: '别名', virtualTarget: '真实模型（全池共用）', virtualAdd: '添加别名',
        virtualSave: '保存别名表', virtualSaved: '已保存虚拟别名', virtualDeleteHint: '删除该行后点击保存生效',
        virtualSame: '别名与真实模型不能相同',
        virtualRuleAlias: '别名不能为空',
        virtualBadge: '虚拟别名', virtualCandidates: '逐实例绑定', virtualCandidateAdd: '添加实例绑定',
        virtualWorkerField: '实例地址', virtualWorkerPlaceholder: 'http://10.252.25.217:8200',
        virtualCandidateModel: '该实例的模型', virtualInherit: '留空继承真实模型', virtualInheritTo: '继承',
        virtualWorkerPick: '选择实例', virtualWorkerPool: '在池内', virtualWorkerOffline: '不在当前服务池',
        virtualWorkerUnverified: '模型列表未经探针验证',
        virtualNeedEither: '真实模型与实例绑定至少填一个', virtualCandidateNeedsWorker: '该绑定还没填实例地址',
        virtualNeedsModel: '该实例没有自己的模型名，且没有可继承的真实模型',
        virtualDupWorker: '{worker} 绑了两个模型：{a} 与 {b}',
        virtualTargetNote: '留空表示模型名只由实例绑定决定',
        modelMapSection: '改名映射（watcher）', modelMapCopy: '把上游真实模型名换成对外暴露的名字：写入 watcher，会重建其实例',
        modelMapOriginal: '原始模型名', modelMapNew: '对外名称', modelMapAdd: '添加映射',
        modelMapDeleteHint: '留空对外名称即为删除', modelMapSaved: '已提交改名映射',
        modelMapDeleted: '已删除映射 {orig}', modelMapNeedWatcher: 'watcher 不可用时改名映射无法提交',
        previewSection: '生效预览', previewCopy: '本地静态推算，不发请求：模拟网关对同一个请求的改写结果',
        previewModel: '请求模型', previewEffort: '请求档位', previewEffortNone: '未指定',
        previewResultModel: '实际模型', previewResultEffort: '下发档位', previewResultCtx: '上下文钳制',
        previewPass: '不改写', previewAliasNote: '虚拟别名替换', previewMapNote: '改名映射只影响 watcher 注册的模型名，不改变这里的请求改写',
        previewCtxNote: 'max_tokens / max_completion_tokens 会被改成该值', previewNoCtx: '不钳制',
        previewServing: '可服务实例', previewServingYes: '{n} 台实例经 /v1/models 验证',
        previewServingNo: '没有已验证的实例提供该模型（请求会被拒）',
        previewServingUnverified: '实例列表未经探针验证，暂按可路由处理',
        previewServingNone: '服务池里没有该模型的实例',
        previewChainDefault: '全局默认档位', previewChainCard: '模型卡片', previewChainLegacy: '旧版强制档位',
        previewChainMap: '全局档位改写', previewChainNone: '无（引擎默认）',
        globalSave: '保存全局策略', globalSaved: '已保存全局档位策略'
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
        summaryOut: '输出 tok/s', summaryIn: '输入 tok/s', summaryTtft: '平均 TTFT',
        summaryDuration: '平均耗时', summaryUptime: '运行时长', summaryBuffer: '缓冲',
        bufferNote: '保留 {n} / {c} 条', windowNote: '{n} 秒窗口',
        filterPath: '路径', filterStatus: '状态码', filterModel: '模型', filterText: '搜索',
        filterTextPlaceholder: '请求 ID / 实例 / 会话 / 提供方',
        statusAll: '全部状态', status2xx: '2xx 成功', status4xx: '4xx 客户端', status5xx: '5xx 服务端',
        modelAll: '全部模型', clearFilters: '重置过滤', live: '实时追加', liveOn: '实时流已连接',
        liveOff: '实时流未连接', liveReconnecting: '实时流断开，正在重连',
        clear: '清空列表', clearHint: '只清空本地列表，不影响网关缓冲',
        colTime: '时间', colModel: '模型', colPath: '路径', colStatus: '状态',
        colDuration: '耗时', colTtft: 'TTFT', colTokens: 'Token 出/入', colRate: 'tok/s',
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
        brand: 'llm-router Console', brandSub: 'Workers / Model overrides / Logs',
        groupManagement: 'Gateway', groupEntry: 'Entry points',
        workers: 'Service pool', workersTitle: 'Inspect and manage inference workers',
        upstreams: 'Upstreams', upstreamsTitle: 'Remote service pool with persisted API keys',
        models: 'Model overrides', modelsTitle: 'Rename map, virtual aliases, per-model effort and context',
        routing: 'Routing policy', routingTitle: 'Global and per-model routing policy, live without restart',
        logs: 'Log monitor', logsTitle: 'Request ring buffer and live stream',
        chat: 'Chat UI', chatTitle: 'Open the stock llama.cpp webui',
        collapse: 'Collapse menu', expand: 'Expand menu', language: '中文',
        online: 'Gateway online', offline: 'Gateway unreachable',
        healthySummary: 'healthy {ok} of {n}', propsLine: '{model} · n_ctx {ctx}',
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
        colUrl: 'Service URL', colHealth: 'Health', colLoad: 'In flight', colPriority: 'Priority',
        colCost: 'Cost', colType: 'Type', colLabels: 'Labels', colJob: 'Job',
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
        colCapacity: 'Caps / live',
        maxConcurrencyField: 'Concurrency cap (optional)', maxConcurrencyHint: 'Once in-flight requests reach this number the worker is skipped even with cache affinity; blank or 0 means unlimited',
        maxPowerField: 'Power cap, W (optional)', maxPowerHint: 'Skipped once the hottest card on this machine reaches this wattage; blank or 0 means unlimited',
        capUnlimited: 'unlimited', capMeasured: 'live', capNoSample: 'live — (no sample)',
        capRule: 'Enter a number; blank or 0 means unlimited',
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
        watcherHint: 'Workers labelled managed-by belong to the watcher and may be re-discovered after removal'
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
        maxConcurrencyField: 'Concurrency cap (optional)', maxConcurrencyHint: 'Once in-flight requests reach this number the worker is skipped even with cache affinity; blank or 0 means unlimited',
        maxPowerField: 'Power cap, W (optional)', maxPowerHint: 'Skipped once the hottest card on this machine reaches this wattage; blank or 0 means unlimited',
        modelsField: 'Models (optional)', modelsPlaceholder: 'model-a, model-b', modelsHint: 'Comma separated; declares which models this endpoint covers. Blank leaves it to the /v1/models probe',
        capMeasured: 'live', capNoSample: 'live — (no sample)',
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
        title: 'Model overrides', description: 'Rewrite public model names and request parameters: watcher rename map, virtual aliases, per-model effort and context cap.',
        persistHint: 'Persisted to {file}', watcherReachable: 'watcher online', watcherUnreachable: 'watcher unreachable',
        watcherNotConfigured: 'LMR_WATCHER_URL not set',
        globalSection: 'Global effort policy', globalCopy: 'Applies to every request without a model override',
        defaultEffort: 'Default effort', defaultEffortHint: 'Used when the request names no effort; blank leaves the engine default',
        effortMapTitle: 'Effort rewrite', effortMapCopy: 'Applied when the request names an effort, e.g. high → max',
        modelEffortTitle: 'Forced effort (legacy)', modelEffortCopy: 'Pin one effort for a model; highest precedence',
        mapFrom: 'Requested', mapTo: 'Forwarded', modelField: 'Model ID', effortField: 'Effort',
        addRow: 'Add entry', rowsEmpty: 'No entries',
        cardsSection: 'Per-model overrides', cardsCopy: 'Context cap, default effort, effort rewrite and modalities; cards win over the global policy',
        colModel: 'Model', colRegistered: 'Origin', colCtx: 'Context cap', colDefaultEffort: 'Default effort',
        colCardMap: 'Effort rewrite', colModalities: 'Modalities', colSources: 'Workers',
        registeredYes: 'registered', registeredNo: 'configured only',
        cardTitle: 'Edit model card', cardCopy: '{model}: empty fields keep the current value, clearing restores auto',
        ctxField: 'Context cap (tokens)', ctxHint: 'Clamps max_tokens / max_completion_tokens',
        ctxRule: 'Must be an integer greater than zero', cardEffortMapTitle: 'Effort rewrite for this model',
        modalitiesTitle: 'Modalities (advertised by /_ui/props)', modalitiesHint: 'Clear to restore auto; the selection is advertised as-is',
        cardSave: 'Save card', cardSaved: 'Model card saved for {model}', cardRemove: 'Clear all overrides', cardRemoveTitle: 'Clear model overrides',
        cardRemoveConfirm: 'Removes the model card plus the legacy ctx and forced-effort rows.',
        clearedNotice: 'Overrides cleared for {model}',
        legacyCtxTitle: 'Legacy context caps', legacyCtxCopy: 'Only used when no model card exists; the card ctx wins',
        legacyEffortTitle: 'Legacy forced effort', legacyEffortCopy: 'Pins one effort per model and outranks cards and global policy',
        legacyModelField: 'Model ID', legacyCtxField: 'Context cap', legacyEffortField: 'Forced effort',
        legacySave: 'Save legacy rows', legacyDelete: 'Remove row',
        virtualSection: 'Virtual aliases', virtualCopy: 'Serve one public name and rewrite it to a real model; each instance can carry its own model, or the whole pool shares one; the table is replaced on save',
        virtualAlias: 'Alias', virtualTarget: 'Real model (whole pool)', virtualAdd: 'Add alias',
        virtualSave: 'Save aliases', virtualSaved: 'Virtual aliases saved', virtualDeleteHint: 'Remove the row, then save to apply',
        virtualSame: 'Alias and target must differ',
        virtualRuleAlias: 'Alias is required',
        virtualBadge: 'virtual alias', virtualCandidates: 'per-instance bindings', virtualCandidateAdd: 'Add instance binding',
        virtualWorkerField: 'Worker URL', virtualWorkerPlaceholder: 'http://10.252.25.217:8200',
        virtualCandidateModel: 'Model on this worker', virtualInherit: 'blank inherits the target', virtualInheritTo: 'inherits',
        virtualWorkerPick: 'Pick a worker', virtualWorkerPool: 'in pool', virtualWorkerOffline: 'not in the current pool',
        virtualWorkerUnverified: 'model list not probe-verified',
        virtualNeedEither: 'Provide a target model or at least one instance binding', virtualCandidateNeedsWorker: 'This binding has no worker URL',
        virtualNeedsModel: 'This binding needs its own model name and there is no target to inherit',
        virtualDupWorker: '{worker} is bound to two models: {a} and {b}',
        virtualTargetNote: 'Leave blank and the model name comes from the per-instance bindings',
        modelMapSection: 'Rename map (watcher)', modelMapCopy: 'Rename the upstream model id into a public name; written to the watcher, which recycles its workers',
        modelMapOriginal: 'Original model name', modelMapNew: 'Public name', modelMapAdd: 'Add mapping',
        modelMapDeleteHint: 'Leave the public name empty to delete the entry', modelMapSaved: 'Rename mapping submitted',
        modelMapDeleted: 'Mapping deleted for {orig}', modelMapNeedWatcher: 'The rename map cannot be submitted while the watcher is unavailable',
        previewSection: 'Effective preview', previewCopy: 'Derived locally, no request sent: what the gateway would rewrite for one request',
        previewModel: 'Requested model', previewEffort: 'Requested effort', previewEffortNone: 'not set',
        previewResultModel: 'Actual model', previewResultEffort: 'Forwarded effort', previewResultCtx: 'Context clamp',
        previewPass: 'unchanged', previewAliasNote: 'virtual alias', previewMapNote: 'The rename map only affects ids registered by the watcher, not this request rewrite',
        previewCtxNote: 'max_tokens / max_completion_tokens are rewritten to this value', previewNoCtx: 'no clamp',
        previewServing: 'Serving workers', previewServingYes: '{n} workers verified via /v1/models',
        previewServingNo: 'no verified worker serves this model (requests would be refused)',
        previewServingUnverified: 'worker model lists are not probe-verified; treated as routable',
        previewServingNone: 'no worker in the pool serves this model',
        previewChainDefault: 'global default effort', previewChainCard: 'model card', previewChainLegacy: 'legacy forced effort',
        previewChainMap: 'global effort rewrite', previewChainNone: 'none (engine default)',
        globalSave: 'Save global policy', globalSaved: 'Global effort policy saved'
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
        summaryOut: 'out tok/s', summaryIn: 'in tok/s', summaryTtft: 'Avg TTFT',
        summaryDuration: 'Avg duration', summaryUptime: 'Uptime', summaryBuffer: 'Buffer',
        bufferNote: '{n} of {c} kept', windowNote: '{n}s window',
        filterPath: 'Path', filterStatus: 'Status', filterModel: 'Model', filterText: 'Search',
        filterTextPlaceholder: 'request id / worker / session / provider',
        statusAll: 'Any status', status2xx: '2xx ok', status4xx: '4xx client', status5xx: '5xx server',
        modelAll: 'Any model', clearFilters: 'Reset filters', live: 'Live append', liveOn: 'Stream connected',
        liveOff: 'Stream offline', liveReconnecting: 'Stream lost, reconnecting',
        clear: 'Clear list', clearHint: 'Clears the local list only, the gateway buffer stays intact',
        colTime: 'Time', colModel: 'Model', colPath: 'Path', colStatus: 'Status',
        colDuration: 'Duration', colTtft: 'TTFT', colTokens: 'Tokens out/in', colRate: 'tok/s',
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
