/*
  lua-router：在官方 llama.cpp webui（/_ui/）左侧导航里注入 Admin 管理台入口。
  由 index.html 以 <script src="./admin-inject.js" defer></script> 引入。

  历史：本文件原名 logs-inject.js，同时注入 Logs 与 Admin 两个入口。根目录下的
  /_ui/logs.html、/_ui/metrics.html、/_ui/config.html 三个工具页已移除（功能与
  /_ui/admin/ 重叠，差异记录见 doc/ui-trim-legacy-pages.md），Logs 入口随之删除，
  只保留 Admin。

  入口迁移（doc/refactor-arch-2026-10-05.md §5.3）：管理台从 /_ui/admin/ 迁到 /a/，
  webui 的规范入口是 /u/（旧 /_ui/ 照旧可用）。注入链接因此用绝对
  路径 /a/：页面无论从 /_ui/ 还是 /u/ 打开，都落到同一个规范入口。

  为什么需要 MutationObserver：导航容器（aside div[class*="px-2"][class*="flex-col"][class*="gap-1"]）
  由 Svelte 持有 children 引用，点「Expand navigation」展开/折叠侧栏会触发该区域重渲染，
  注入节点会被清掉（已实测）。因此除了首次注入，还要靠 observer 在每次重渲染后补回。
  observer 回调必须防抖 + 判重，否则「注入自身触发 mutation → 再注入」会死循环。

  官方 webui 升级后如何恢复：本文件不在 SvelteKit 产物与 sw.js precache 列表里，升级 ui/ 目录后
  只需重打 index.html 的注入行（本文件这一行）。若升级导致导航类名变化，
  下面 NAV_SELECTORS 的第一条是实测锚点，退化策略会自动去找「含 New chat 按钮的同类容器」。

  约束：零第三方依赖；不修改页面其它内容；任何异常静默失败（不影响聊天页）。
*/
(function () {
  'use strict';
  try {
    if (window.__lmrAdminInject) return;             // 同一页面重复引入时只跑一次
    window.__lmrAdminInject = true;

    var MARK = 'data-lmr-inject';                    // 幂等判重标记
    var NAV_SELECTORS = [
      'aside div[class*="px-2"][class*="flex-col"][class*="gap-1"]',   // 实测可用
      'aside div[class*="flex-col"][class*="gap-1"]'
    ];
    /* 与既有 New chat / Search / Settings 按钮完全同一套类名，尺寸天然一致
       （折叠态 36x36 圆形：p-0 h-9 w-9 rounded-full hover:bg-accent） */
    var BTN_CLASS = 'inline-flex items-center justify-center shrink-0 gap-2 p-0 h-9 w-9 rounded-full hover:bg-accent text-sm font-medium';
    var SVG_ADMIN = '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none"' +
      ' stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide h-4 w-4">' +
      '<rect width="7" height="9" x="9" y="3" rx="1"/><rect width="7" height="5" x="14" y="16" rx="1"/>' +
      '<rect width="7" height="5" x="3" y="16" rx="1"/><path d="M21 16v-2a2 2 0 0 0-2-2h-3"/>' +
      '<path d="M7 16V8a2 2 0 0 1 2-2h7"/></svg>';
    /* Admin（Quasar 管理控制台）新开标签页，避免丢掉当前会话状态。
       href 用绝对路径 /a/（管理台的新入口，refactor-arch §5.3），
       不再相对于页面落在 /_ui/admin/ 那个旧位置。 */
    var ENTRIES = [
      { mark: 'admin', label: 'Admin', icon: SVG_ADMIN, href: '/a/', blank: true }
    ];

    function findNav() {
      for (var i = 0; i < NAV_SELECTORS.length; i++) {
        var n = document.querySelector(NAV_SELECTORS[i]);
        if (n) return n;
      }
      // 退化：从已有的 New chat 按钮往上找它的父容器（每个按钮外层是一个裸 div）
      var probe = document.querySelector('aside button[aria-label="New chat"], aside button[aria-label="Settings"]');
      if (probe && probe.parentElement && probe.parentElement.parentElement) {
        var host = probe.parentElement.parentElement;
        if (host.querySelectorAll('button').length >= 2) return host;
      }
      return null;
    }

    function inject() {
      try {
        var nav = findNav();
        if (!nav) return;
        for (var k = 0; k < ENTRIES.length; k++) {
          var entry = ENTRIES[k];
          if (nav.querySelector('[' + MARK + '="' + entry.mark + '"]')) continue;   // 逐项幂等判重
          var wrap = document.createElement('div');              // 与既有项一致：外层裸 div + button
          wrap.setAttribute(MARK, entry.mark);
          var btn = document.createElement('button');
          btn.type = 'button';
          btn.className = BTN_CLASS;
          btn.setAttribute('aria-label', entry.label);
          btn.title = entry.label;
          btn.innerHTML = entry.icon;                            // 图标是本文内联常量，不含外部内容
          btn.addEventListener('click', (function (href, blank) {
            return function () {
              // 用 baseURI 解析，保证在 /_ui/ 与 /_ui/index.html 两种 URL 下都指向 /_ui/<页>
              try {
                var url = new URL(href, document.baseURI).href;
                if (blank) {
                  var w = window.open(url, '_blank', 'noopener');
                  if (w) return;                                // 被拦截时退回同页跳转
                }
                window.location.assign(url);
              } catch (e) {}
            };
          })(entry.href, entry.blank === true));
          wrap.appendChild(btn);
          nav.appendChild(wrap);
        }
      } catch (e) { /* 静默：不能影响聊天页 */ }
    }

    inject();

    var queued = false;
    var obs = new MutationObserver(function () {
      if (queued) return;                                        // 防抖：合并同一批 mutation，避免注入自触发死循环
      queued = true;
      setTimeout(function () { queued = false; inject(); }, 0);
    });
    obs.observe(document.body, { childList: true, subtree: true });
  } catch (e) { /* 整体静默失败 */ }
})();
