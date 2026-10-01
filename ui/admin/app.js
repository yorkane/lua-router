/*
  lua-router 管理控制台 · 主壳

  与 authz/admin 同构：左侧 q-drawer 菜单 + 右侧 iframe 承载独立应用页
  （workers.html / models.html / logs.html），页面自带内联逻辑，壳只负责
  导航、语言广播与网关健康摘要。零 Vue Router：#锚点 记录当前页，刷新可恢复。
*/
const { computed, onBeforeUnmount, onMounted, ref } = Vue

// 三个管理页 + 原版聊天界面（跳出壳，新标签打开）
const pages = ['workers.html?v=1', 'models.html?v=1', 'logs.html?v=1']

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
  return hit || ''
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
    let unsubscribeLocale
    let statusTimer

    const t = computed(() => {
      const dict = window.lmrI18n.messages[locale.value].shell
      return { ...dict, interval: healthInterval.value }
    })
    const chatHref = computed(() => '/_ui/')

    const groups = computed(() => {
      const dict = window.lmrI18n.messages[locale.value].shell
      return [
        {
          id: 'gateway',
          label: dict.groupManagement,
          items: [
            { id: 'workers', page: pages[0], icon: 'mdi-server-network', label: dict.workers, note: dict.workersTitle },
            { id: 'models', page: pages[1], icon: 'mdi-sitemap', label: dict.models, note: dict.modelsTitle },
            { id: 'logs', page: pages[2], icon: 'mdi-text-box-search-outline', label: dict.logs, note: dict.logsTitle }
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
      if (activeApp.value.startsWith(pages[0])) activeTitle.value = dict.workers
      else if (activeApp.value.startsWith(pages[1])) activeTitle.value = dict.models
      else if (activeApp.value.startsWith(pages[2])) activeTitle.value = dict.logs
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
