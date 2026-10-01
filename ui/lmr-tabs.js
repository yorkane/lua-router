/* llm-router /_ui/ 工具页共享标签条（Logs / Config / Metrics）。
   用法：<script defer src="./lmr-tabs.js" data-active="logs"></script>
   页面在 <div id="lmr-tabs-anchor"></div> 处插入；缺失锚点则挂到 body 开头。
   样式与 logs.html / config.html 的暗色变量一致，页面没定义时退到内置值。 */
(function () {
  'use strict';
  var TABS = [
    { id: 'logs',    label: 'Logs',    href: './logs.html' },
    { id: 'config',  label: 'Config',  href: './config.html' },
    { id: 'metrics', label: 'Metrics', href: './metrics.html' }
  ];
  function boot() {
    if (document.getElementById('lmr-tabs')) return;
    var self = document.querySelector('script[data-active]');
    var active = self ? self.getAttribute('data-active') : '';
    var host = document.createElement('nav');
    host.id = 'lmr-tabs';
    host.className = 'lmr-tabs';
    host.innerHTML =
      '<a class="back" href="./">&larr; 返回聊天</a>' +
      '<span class="seg">' +
      TABS.map(function (t) {
        return '<a class="tab' + (t.id === active ? ' on' : '') + '" href="' + t.href + '">' + t.label + '</a>';
      }).join('') +
      '</span>';
    var style = document.createElement('style');
    style.textContent = [
      '.lmr-tabs{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:14px}',
      '.lmr-tabs .back{color:var(--muted,#9aa4b2);text-decoration:none;font-size:13px;' +
        'border:1px solid var(--border,#2b3340);border-radius:999px;padding:5px 12px}',
      '.lmr-tabs .back:hover{color:var(--fg,#e6edf3);border-color:var(--fg,#e6edf3)}',
      '.lmr-tabs .seg{display:inline-flex;border:1px solid var(--border,#2b3340);' +
        'border-radius:999px;overflow:hidden}',
      '.lmr-tabs .tab{padding:5px 16px;font-size:13px;color:var(--muted,#9aa4b2);' +
        'text-decoration:none;border-left:1px solid var(--border,#2b3340)}',
      '.lmr-tabs .tab:first-child{border-left:none}',
      '.lmr-tabs .tab:hover{color:var(--fg,#e6edf3)}',
      '.lmr-tabs .tab.on{background:var(--surface,#1b212b);color:var(--fg,#e6edf3);font-weight:600}'
    ].join('\n');
    document.head.appendChild(style);
    var anchor = document.getElementById('lmr-tabs-anchor');
    if (anchor && anchor.parentNode) anchor.parentNode.replaceChild(host, anchor);
    else document.body.insertBefore(host, document.body.firstChild);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
