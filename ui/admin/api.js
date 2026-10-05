/*
  lua-router 管理控制台 · 请求层（仿 authz/admin/api.js）

  所有端点都用绝对路径。页面挂在 /a/ 下（refactor-arch-2026-10-05.md §5.3 从 /_ui/admin/ 迁来），因此：
    · 网关自带 API 走 /_ui/*（conf/ui.conf 的精确 location）
    · 控制面 API 走根路径 /workers（router.lua 的 klib 路由表）
  全部无鉴权（网关鉴权层已随 doc/scope-trim.md 删除），所以不带 credentials / CSRF。

  错误体有两种形状，都要解出人类可读信息：
    · {"error":{"type":…,"code":…,"message":…}}   router.lua error_body()
    · {"error":"文本"}                              ui.lua / config_store.lua
  抛出的 Error 带 status / code，页面据此提示。
*/
(function () {
  const UI_BASE = '/_ui'
  const API_BASE = ''

  async function request (path, options, base) {
    const prefix = base === undefined ? API_BASE : base
    const { values, headers, ...fetchOptions } = options || {}
    const response = await fetch(prefix + path, {
      headers: {
        Accept: 'application/json',
        ...(values !== undefined ? { 'Content-Type': 'application/json' } : {}),
        ...(headers || {})
      },
      ...(values !== undefined ? { body: JSON.stringify(values) } : {}),
      ...fetchOptions
    })

    const contentType = response.headers.get('content-type') || ''
    let payload = null
    if (response.status !== 204 && contentType.includes('application/json')) {
      try { payload = await response.json() } catch (err) { payload = null }
    } else if (response.status !== 204) {
      const text = await response.text().catch(() => '')
      try { payload = JSON.parse(text) } catch (err) { payload = null }
    }

    if (!response.ok) {
      const error = new Error(errorMessage(payload) || `HTTP ${response.status}`)
      error.status = response.status
      error.code = (payload && payload.error && payload.error.code) || ''
      throw error
    }
    return payload
  }

  function errorMessage (payload) {
    if (!payload || typeof payload !== 'object') return ''
    const error = payload.error
    if (typeof error === 'string') return error
    if (error && typeof error === 'object') return error.message || error.code || ''
    return payload.message || payload.error_message || ''
  }

  const get = (path, base) => request(path, { method: 'GET' }, base)
  const post = (path, values, base) => request(path, { method: 'POST', values }, base)
  const put = (path, values, base) => request(path, { method: 'PUT', values }, base)
  const del = path => request(path, { method: 'DELETE' })

  window.lmrApi = {
    // ── 服务池（根路径控制面） ──
    workers: () => get('/workers'),
    worker: id => get(`/workers/${encodeURIComponent(id)}`),
    addWorker: spec => post('/workers', spec),
    updateWorker: (id, patch) => put(`/workers/${encodeURIComponent(id)}`, patch),
    removeWorker: id => del(`/workers/${encodeURIComponent(id)}`),

    // ── 模型覆盖（/_ui/config 家族，均返回整份 document） ──
    config: () => get('/config', UI_BASE),
    configEffort: patch => post('/config/effort', patch, UI_BASE),
    configCtx: (model, ctx) => post('/config/ctx', { model, ctx }, UI_BASE),
    configModel: card => post('/config/model', card, UI_BASE),
    configVirtual: entries => post('/config/virtual', { entries }, UI_BASE),
    // 服务接入池（doc/gap-virtual-models.md 3.5）：整表替换 + 立即 reconcile
    configUpstreams: entries => post('/config/upstreams', { entries }, UI_BASE),
    configApply: document => post('/config/apply', document, UI_BASE),
    // 模型改名映射（直接调 /model-map）；body 支持 {"orig":"new"} 形状，空值即删除
    configModelMap: mapping => post('/model-map', mapping),

    // ── 路由策略（/_ui/config/policy，doc/gap-routing-dyn.md） ──
    // GET 返回策略链文档（候选策略 + 全局 + per-model 行），PUT 提交变更并回显新文档。
    configPolicy: () => get('/config/policy', UI_BASE),
    configPolicyApply: patch => put('/config/policy', patch, UI_BASE),

    // ── 日志与统计 ──
    logs: (cursor, limit) => get(`/logs?cursor=${cursor || 0}&limit=${limit || 500}`, UI_BASE),
    stats: () => get('/stats', UI_BASE),
    logBackends: () => get('/logs/backends', UI_BASE),
    logsStreamUrl: () => `${UI_BASE}/logs/stream`,

    // ── 概览 ──
    props: model => get(model ? `/props?model=${encodeURIComponent(model)}` : '/props', UI_BASE),
    models: () => get('/v1/models', UI_BASE),

    effortLevels: ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'],
    modalityLevels: ['text', 'image', 'video', 'audio'],
    errorMessage
  }
})()
