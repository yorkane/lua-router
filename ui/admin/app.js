/*
  lua-router 管理控制台 · 主壳

  与 authz/admin 同构：左侧 q-drawer 菜单 + 右侧 iframe 承载独立应用页，页面自带内联逻辑，
  壳只负责导航、语言广播与网关健康摘要。零 Vue Router：#锚点 记录当前页，刷新可恢复。

  页序按使用频度排（root 裁定 2026-10-02）：模型管理 → 服务池 → 路由策略 → 日志监控。
  「远程服务/服务接入」已并入服务池（workers.html 同时呈现运行态池行与声明层条目），
  旧的 #upstreams.html 锚点仍接受，落到合并后的服务池页。
*/
const { computed, onBeforeUnmount, onMounted, ref } = Vue

// 四个管理页 + 原版聊天界面（跳出壳，新标签打开）
// 版本号由 index.html 注入（Dockerfile 构建时用 git hash 替换 __UI_VERSION__）
// 本地直开时 LMR_UI_VERSION 还是占位符，用时间戳保证每次刷新
const UI_V = (typeof window.LMR_UI_VERSION !== 'undefined' && window.LMR_UI_VERSION !== '__UI_VERSION__')
  ? window.LMR_UI_VERSION : Date.now().toString(36)
const pages = ['models.html?v=' + UI_V, 'workers.html?v=' + UI_V, 'routing.html?v=' + UI_V, 'logs.html?v=' + UI_V]
// 已合并页面的历史锚点：命中即落到合并后的页面，而不是 404 回首页
const legacyPages = { 'upstreams.html': pages[1] }

function hashTarget () {
  const raw = String(window.location.hash || '').replace(/^#/, '')
  if (!raw) return ''
  try { return decodeURIComponent(raw) } catch (err) { return raw }
}

function urlBase (url) {
  return String(url || '').split('?')[0]
}

function resolvePage (target) {
  if (!target) return ''
  const wanted = urlBase(target)
  const hit = pages.find(page => urlBase(page) === wanted)
  if (hit) return hit
  return legacyPages[wanted] || ''
}

const app = Vue.createApp({
  setup () {
    const drawerVisible = ref(true)
    const drawerMini = ref(window.innerWidth < 760)
    const activeApp = ref(pages[0])
    const activeTitle = ref('')
    const locale = ref(window.lmrI18n.getLocale())
    const online = ref(false)
    const workerSummary = ref('')
    const propsLine = ref('')
    const healthInterval = ref(30)
    // 侧栏「实时吞吐」面板的读数（模板见 index.html .menu-throughput）。
    // 口径裁定（2026-10-05，沿用日志监控页）：不信任后端 /_ui/stats 的 tok/s——
    // 后端拿采样桶数当分母，稀疏流量时外推出夸张瞬时值；壳层自己拉 /_ui/logs 的日志行，
    // 用 logs 页抽出的同一个 window.lmrTokenStats.summarizeWindow（./token-stats.js）现算，
    // 保证侧栏与日志页两个 tok/s 永远同函数同口径。null = 从未成功过（展示占位 —）。
    const throughput = ref(null)
    let unsubscribeLocale
    let statusTimer

    const t = computed(() => {
      const dict = window.lmrI18n.messages[locale.value].shell
      return { ...dict, interval: healthInterval.value }
    })
    // ── 侧栏吞吐面板的展示层：只做数字→字符串，算术全在 token-stats.js ──
    // 千分位口径与 logs.html 的 fmtThousands 等价（不跨页 import 那个函数）：
    // 速率用逗号千分位纯数字，不套 k 后缀。undefined/null 统一兜成 —。
    function fmtTok (value) {
      if (value === undefined || value === null) return t.value.dash
      const n = Number(value)
      if (!Number.isFinite(n)) return t.value.dash
      return n.toLocaleString('en-US')
    }
    function fmtPct (value) {
      // cacheHitPct 为 null = 窗口内 prompt 总量为 0（logs 页同口径：与「命中率 0%」区分开）
      if (value === undefined || value === null) return t.value.dash
      const n = Number(value)
      if (!Number.isFinite(n)) return t.value.dash
      return n.toFixed(1) + '%'
    }
    function fmtTtft (value) {
      if (value === undefined || value === null) return t.value.dash
      const n = Number(value)
      if (!Number.isFinite(n)) return t.value.dash
      return n >= 1000 ? (n / 1000).toFixed(2) + ' s' : Math.round(n) + ' ms'
    }
    const throughputLine = computed(() => {
      const tp = throughput.value
      if (!tp) return t.value.dash
      return window.lmrI18n.translate(locale.value, 'shell', 'throughputLine', {
        n: fmtTok(tp.requestsWindow),
        e: fmtTok(tp.errorsWindow),
        t: fmtTtft(tp.avgTtftMs)
      })
    })
    const throughputIn = computed(() => throughput.value ? fmtTok(throughput.value.inputTokS) : t.value.dash)
    const throughputOut = computed(() => throughput.value ? fmtTok(throughput.value.outputTokS) : t.value.dash)
    const throughputCache = computed(() => throughput.value ? fmtPct(throughput.value.cacheHitPct) : t.value.dash)
    const throughputHasErrors = computed(() => !!(throughput.value && Number(throughput.value.errorsWindow) > 0))
    // 原版聊天界面的规范入口（doc/refactor-arch-2026-10-05.md §5.3）：旧地址 /_ui/
    // 照旧可用，但壳里的链接统一指新入口 /u/。
    const chatHref = computed(() => '/u/')

    const groups = computed(() => {
      const dict = window.lmrI18n.messages[locale.value].shell
      return [
        {
          id: 'gateway',
          label: dict.groupManagement,
          items: [
            { id: 'models', page: pages[0], icon: 'mdi-sitemap', label: dict.models, note: dict.modelsTitle },
            { id: 'workers', page: pages[1], icon: 'mdi-server-network', label: dict.workers, note: dict.workersTitle },
            { id: 'routing', page: pages[2], icon: 'mdi-call-split', label: dict.routing, note: dict.routingTitle },
            { id: 'logs', page: pages[3], icon: 'mdi-text-box-search-outline', label: dict.logs, note: dict.logsTitle }
          ]
        },
        {
          id: 'entry',
          label: dict.groupEntry,
          items: [
            { id: 'chat', external: true, icon: 'mdi-chat-processing-outline', label: dict.chat, note: dict.chatTitle }
          ]
        }
      ]
    })

    const toggleIcon = computed(() => (drawerMini.value ? 'mdi-chevron-right' : 'mdi-chevron-left'))
    const toggleLabel = computed(() => (drawerMini.value ? t.value.expand : t.value.collapse))

    // 当前页所属分组：窄栏时展开它，其它收起（与 authz 的分组行为一致）
    const activeGroup = computed(() => {
      for (const group of groups.value) {
        if (group.items.some(item => item.page === activeApp.value)) return group.id
      }
      return ''
    })

    function select (item, event) {
      if (item.external) return openNewTab(chatHref.value, event)
      navigate(item.page)
    }

    function openNewTab (url, event) {
      const href = new URL(url, window.location.origin).href
      if (event && (event.ctrlKey || event.metaKey || event.shiftKey)) {
        window.open(href, '_blank', 'noopener')
        return
      }
      window.open(href, '_blank', 'noopener')
    }

    function navigate (page) {
      if (!page) return
      activeApp.value = page
      const target = urlBase(page)
      if (window.location.hash !== '#' + target) {
        window.history.pushState({ url: page }, '', '#' + target)
      }
      // iframe 的 hash 变化不会触发重新加载，所以直接改 src（同 URL 时浏览器复用）
      syncFrameTitle()
    }

    function syncFrameTitle () {
      const dict = window.lmrI18n.messages[locale.value].shell
      if (activeApp.value.startsWith(pages[0])) activeTitle.value = dict.models
      else if (activeApp.value.startsWith(pages[1])) activeTitle.value = dict.workers
      else if (activeApp.value.startsWith(pages[2])) activeTitle.value = dict.routing
      else if (activeApp.value.startsWith(pages[3])) activeTitle.value = dict.logs
      else activeTitle.value = dict.frameTitle
    }

    function applyHashTarget () {
      const page = resolvePage(hashTarget())
      if (page) {
        activeApp.value = page
        syncFrameTitle()
      }
    }

    function restoreFromHistory () {
      const url = window.location.hash
      const page = resolvePage(url)
      if (page) navigate(page)
    }

    function toggleDrawer () { drawerMini.value = !drawerMini.value }
    function syncDrawerState () { drawerMini.value = window.innerWidth < 760 }

    // 语言：写 localStorage 后广播给所有同源 iframe（新载入的页面自己读同一份）。
    // 注意主壳就是 window.top，lmrI18n.setLocale 的向上广播对自身是空转（storage 事件
    // 也不会回传给写入方），所以壳内切换要直接走 applyLocale，否则只有 iframe 变色。
    function toggleLocale () {
      const nextLocale = locale.value === 'zh-CN' ? 'en-US' : 'zh-CN'
      window.lmrI18n.setLocale(nextLocale)
      applyLocale(nextLocale)
    }

    function broadcastLocale (nextLocale) {
      document.querySelectorAll('iframe.app-frame').forEach(frame => {
        try {
          frame.contentWindow.postMessage({ type: window.lmrI18n.messageType, locale: nextLocale }, window.location.origin)
        } catch (err) { /* 跨源或未就绪：忽略 */ }
      })
    }

    async function loadStatus () {
      try {
        const result = await window.lmrApi.workers()
        const list = (result && result.workers) || []
        online.value = true
        const healthy = list.filter(worker => worker.is_healthy).length
        workerSummary.value = window.lmrI18n.translate(locale.value, 'shell', 'healthySummary', { ok: healthy, n: list.length })
        if (list.length === 0) propsLine.value = ''
      } catch (error) {
        online.value = false
        workerSummary.value = ''
        propsLine.value = ''
      }
      try {
        const props = await window.lmrApi.props()
        if (props && props.model) {
          propsLine.value = window.lmrI18n.translate(locale.value, 'shell', 'propsLine', {
            model: props.model_alias || props.model,
            ctx: props.n_ctx === undefined ? '?' : props.n_ctx
          })
        } else {
          propsLine.value = ''
        }
      } catch (error) {
        propsLine.value = ''
      }
      // 实时吞吐：跟着本函数每 10s 一起拉（复用 statusTimer，不新起第二个定时器）。
      // 日志整体关闭时 /_ui/logs 回 503，或 token-stats.js 意外缺失——都走 catch：
      // 保留上一次读数不清空（与 logs.html refreshStats 同一条策略），展示层把
      // 从未成功的 null 兜成占位 —，不弹错误。
      try {
        const logPage = await window.lmrApi.logs(0, 500)
        const rows = (logPage && logPage.requests) || []
        const agg = window.lmrTokenStats.summarizeWindow(rows, Date.now(), window.lmrTokenStats.STATS_WINDOW_MS)
        throughput.value = {
          inputTokS: agg.inputTokS,
          outputTokS: agg.outputTokS,
          cacheHitPct: agg.cacheHitPct,
          requestsWindow: agg.n,
          errorsWindow: agg.errors,
          avgTtftMs: agg.avgTtftMs
        }
      } catch (error) {
        // 保留上一次值；面板展示占位 —
      }
    }

    function applyLocale (nextLocale) {
      locale.value = nextLocale
      document.documentElement.lang = nextLocale
      window.lmrI18n.applyQuasarLang(nextLocale)
      syncFrameTitle()
      loadStatus()
      broadcastLocale(nextLocale)
    }

    onMounted(() => {
      applyHashTarget()
      syncFrameTitle()
      window.addEventListener('resize', syncDrawerState)
      window.addEventListener('popstate', restoreFromHistory)
      window.addEventListener('hashchange', restoreFromHistory)
      unsubscribeLocale = window.lmrI18n.subscribe(applyLocale)
      applyQuasarOnBoot()
      loadStatus()
      statusTimer = window.setInterval(loadStatus, 10000)
    })

    function applyQuasarOnBoot () {
      Quasar.Dark.set(true)
      window.lmrI18n.applyQuasarLang(locale.value)
      Quasar.IconSet.set(Quasar.IconSet.mdiV7)
    }

    onBeforeUnmount(() => {
      window.removeEventListener('resize', syncDrawerState)
      window.removeEventListener('popstate', restoreFromHistory)
      window.removeEventListener('hashchange', restoreFromHistory)
      window.clearInterval(statusTimer)
      if (unsubscribeLocale) unsubscribeLocale()
    })

    return {
      activeApp,
      activeGroup,
      activeTitle,
      chatHref,
      drawerMini,
      drawerVisible,
      groups,
      navigate,
      online,
      openChat: (event) => openNewTab(chatHref.value, event),
      propsLine,
      select,
      t,
      throughput,
      throughputCache,
      throughputHasErrors,
      throughputIn,
      throughputLine,
      throughputOut,
      toggleDrawer,
      toggleIcon,
      toggleLabel,
      toggleLocale,
      workerSummary
    }
  }
})

app.use(Quasar, { config: { dark: true } })
app.mount('#q-app')
