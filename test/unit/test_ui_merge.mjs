// test_ui_merge.mjs —— 服务池页 mergeRows 的 node 单测（无端口、无容器，可与其它单测并发）。
//
// mergeRows 在 ui/admin/workers.html 里刻意抽成纯函数（见该文件"合并算法是纯函数"的注释：
// 为的就是能在 node 里钉住归属判定）。本文件从 html 源码里按名字抽出所需函数原样执行 ——
// 不复制实现：复制了就等于没测，实现改坏而测试还绿是最坏的结果。
//
// 钉的是「上限归属徽章」三档判定（用户裁定 2026-10-10，doc/gap-pool-merge.md §2/§4）：
// protected 行（inPool 且 discovery 不是 config）同地址有声明时，2026-10-04（提交
// 3728821）起后端 config_store/upstreams.lua 的 upstream_caps_only_patch + reconcile
// protected 分支每 30 秒把声明写了的三档上限投影进池记录，执行面（registry/loads.lua
// 的 capacity_verdict、router/candidates.lua 的硬排除）读池记录 —— 上限此刻生效，
// 红色「声明管不到这行」只留给「声明对三档一个字都没写」那一档。徽章渲染只按
// mergeRows 落的布尔位上色，所以钉布尔位就是钉徽章。
//
// 归一化口径与被测代码同一套读法：并发档 capNumber（<=0 折成不限 = 没说），利用率档
// utilNumber（0 是最严档、算主张）。一致性只比「声明写了话」的档 —— 后端对没写的档
// 保持沉默（既不投影也不清除），未写的档永远不会被自愈收敛。
//
// 运行：node test/unit/test_ui_merge.mjs（quick 档 gate_unit 内联调用）。
// 判别性通道（与 test_models_shape 的 LR_MODELS_TEST_LEGACY_SRC 同思路）：LR_UI_HTML=<改动前的
// workers.html> 可以把被测函数换成旧源码，用来手工核实「断言真会红」；缺省不设，门禁只跑 HEAD。
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const here = path.dirname(fileURLToPath(import.meta.url))
const htmlPath = process.env.LR_UI_HTML || path.join(here, '..', '..', 'ui', 'admin', 'workers.html')
const html = readFileSync(htmlPath, 'utf8')
const BACKTICK = String.fromCharCode(96)

// 从源码里按名字抽出完整函数体：字符串 / 行注释 / 块注释 / 模板串感知的花括号配对，
// 数不到字符串里的花括号上去（模板里那种写法一出现就会截错函数）。
function extractFunction (src, name) {
  const marker = 'function ' + name + ' '
  const start = src.indexOf(marker)
  if (start === -1) throw new Error('workers.html 里找不到函数：' + name)
  let depth = 0
  let quote = null
  let lineComment = false
  let blockComment = false
  let template = false
  let j = start
  while (j < src.length) {
    const ch = src[j]
    const next = src[j + 1]
    if (lineComment) { if (ch === '\n') lineComment = false }
    else if (blockComment) { if (ch === '*' && next === '/') blockComment = false }
    else if (quote) { if (ch === '\\') j++; else if (ch === quote) quote = null }
    else if (template) { if (ch === '\\') j++; else if (ch === BACKTICK) template = false }
    else if (ch === '/' && next === '/') lineComment = true
    else if (ch === '/' && next === '*') blockComment = true
    else if (ch === "'" || ch === '"') quote = ch
    else if (ch === BACKTICK) template = true
    else if (ch === '{') depth++
    else if (ch === '}') { depth--; if (depth === 0) { j++; break } }
    j++
  }
  return src.slice(start, j)
}

// 依赖表按真实源码补齐：mergeRows 用到下面全部六个纯函数，抽一个漏一个就是假绿。
const names = ['normUrl', 'normKey', 'normaliseLoadState', 'hasKey', 'capNumber', 'utilNumber', 'mergeRows']
const factory = new Function(names.map(n => extractFunction(html, n)).join('\n') + '\nreturn { mergeRows }')
const mergeRows = factory().mergeRows

let failures = 0
let checks = 0
function check (name, ok, detail) {
  checks++
  if (!ok) {
    failures++
    console.log('FAIL  ' + name + (detail === undefined ? '' : '  -> ' + JSON.stringify(detail)))
  }
}

// 复刻模板 body-cell-capacity 的徽章优先级（v-if / v-else-if 的换位由 S7 的另一组断言钉）。
function badgeOf (row) {
  if (row.cap_owner === 'declared' && row.inPool) {
    return (row.cap_drift[0] || row.cap_drift[1]) ? 'amber-declared' : 'teal-declared'
  }
  if (row.cap_projected) return 'teal-projected'
  if (row.cap_projected_drift) return 'amber-projected-drift'
  if (row.cap_shadowed) return 'red-shadowed'
  return 'none'
}

function only (rows, url) {
  const hits = rows.filter(row => row.url === url)
  check('行 ' + url + ' 恰好一条', hits.length === 1, rows.map(r => r.url))
  return hits[0] || {}
}

// 真实形状：/workers 的一行 + /_ui/config 的 upstreams 一条（对齐 21.k:8800 的 8012/8022/8023）。
function poolRow (over) {
  return Object.assign({
    url: 'http://10.0.0.5:8012', id: 'w-8012', worker_type: 'regular', model_id: 'qwen',
    models: ['qwen'], models_verified: true, is_healthy: true, load: 0, priority: 50, cost: 1,
    min_concurrency: 2, max_concurrency: 10, max_gpu_util: undefined,
    load_state: 'idle', inflight_requests: 0, gpu_util: null, metadata: {},
    job_status: null, disable_health_check: false, discovery: 'dynamic'
  }, over || {})
}
function declRow (over) {
  return Object.assign({ url: 'http://10.0.0.5:8012', min_concurrency: 2, max_concurrency: 10 }, over || {})
}

// ── S1 生产回归锚（用户报的现象）：protected + 声明写 2/10 且与池值一致 → 青，不得红 ──
for (const discovery of ['dynamic', 'router-watch', 'watcher', 'manual']) {
  const row = only(mergeRows([poolRow({ discovery })], [declRow()]), 'http://10.0.0.5:8012')
  check('S1 ' + discovery + ': cap_owner=runtime', row.cap_owner === 'runtime', row.cap_owner)
  check('S1 ' + discovery + ': 投影青徽章', badgeOf(row) === 'teal-projected', badgeOf(row))
  check('S1 ' + discovery + ': 不得出现红徽章', row.cap_shadowed !== true, row.cap_shadowed)
  // 显示值仍是池值：归属由徽章讲，不由显示值讲（对外契约不变）
  check('S1 ' + discovery + ': 显示值=池值', row.min_concurrency === 2 && row.max_concurrency === 10,
    [row.min_concurrency, row.max_concurrency])
  // 未入池判据没被顺手改坏：load_state 只搬运
  check('S1 ' + discovery + ': load_state 原样', row.load_state === 'idle', row.load_state)
}

// ── S2 protected + 声明写了上限但与池值不一致 → 琥珀，不得红 ──
{
  const row = only(mergeRows([poolRow({ discovery: 'watcher', min_concurrency: 4, max_concurrency: 8 })],
    [declRow({ min_concurrency: 2, max_concurrency: 10 })]), 'http://10.0.0.5:8012')
  check('S2 上限未跟上=琥珀', badgeOf(row) === 'amber-projected-drift', badgeOf(row))
  check('S2 不得红', row.cap_shadowed !== true, row.cap_shadowed)
}
{
  // util 一档：声明 0（最严档，算主张）而池行缺席 → 琥珀；池行也是 0 → 青。
  const drift = only(mergeRows([poolRow({ discovery: 'dynamic', max_gpu_util: undefined })],
    [declRow({ min_concurrency: undefined, max_concurrency: undefined, max_gpu_util: 0 })]), 'http://10.0.0.5:8012')
  check('S2b util 0 是主张且未跟上', badgeOf(drift) === 'amber-projected-drift', badgeOf(drift))
  const match = only(mergeRows([poolRow({ discovery: 'dynamic', max_gpu_util: 0 })],
    [declRow({ min_concurrency: undefined, max_concurrency: undefined, max_gpu_util: 0 })]), 'http://10.0.0.5:8012')
  check('S2b util 0 与池一致=青', badgeOf(match) === 'teal-projected', badgeOf(match))
}
{
  // 沉默档不参与收敛判定：声明只写 max_concurrency=10 且与池一致；池行另有 PUT 存量
  // min_concurrency=4（声明没写 = 后端保持沉默、永不投影）→ 仍按「一致」出青徽章。
  const row = only(mergeRows([poolRow({ discovery: 'router-watch', min_concurrency: 4, max_concurrency: 10 })],
    [declRow({ min_concurrency: undefined, max_concurrency: 10 })]), 'http://10.0.0.5:8012')
  check('S2c 未写的档不逼出琥珀', badgeOf(row) === 'teal-projected', badgeOf(row))
}
{
  // <=0 归一化：并发两档写 0 = 折成不限 = 没说；三档全无主张 → 红。
  const red = only(mergeRows([poolRow({ discovery: 'dynamic', min_concurrency: undefined, max_concurrency: undefined })],
    [declRow({ min_concurrency: 0, max_concurrency: 0, max_gpu_util: undefined, model_id: 'glm' })]), 'http://10.0.0.5:8012')
  check('S2d <=0 折成不限', badgeOf(red) === 'red-shadowed', badgeOf(red))
}

// ── S3 回归锚：protected + 声明对三档一个字没写 → 必须红 ──
{
  const row = only(mergeRows([poolRow({ discovery: 'dynamic', min_concurrency: undefined, max_concurrency: undefined, max_gpu_util: undefined })],
    [declRow({ min_concurrency: undefined, max_concurrency: undefined, max_gpu_util: undefined, model_id: 'glm', priority: 30 })]),
  'http://10.0.0.5:8012')
  check('S3 无上限主张=红', row.cap_shadowed === true, row.cap_shadowed)
  check('S3 徽章是红', badgeOf(row) === 'red-shadowed', badgeOf(row))
  check('S3 不投影不琥珀', row.cap_projected !== true && row.cap_projected_drift !== true,
    [row.cap_projected, row.cap_projected_drift])
  check('S3 cap_owner=runtime', row.cap_owner === 'runtime', row.cap_owner)
  // 身份类字段的既有搬运不许变：池行已有 model_id，声明的 model_id 不越权改写显示值
  check('S3 身份字段仍走池值', row.model_id === 'qwen', row.model_id)
}

// ── S4 discovery='config' 的行仍走 declared 青/琥珀（回归锚 c：既有渲染不许变）──
{
  const same = only(mergeRows([poolRow({ discovery: 'config' })], [declRow()]), 'http://10.0.0.5:8012')
  check('S4 config 一致=capFromDecl 青', badgeOf(same) === 'teal-declared', badgeOf(same))
  check('S4 config 不投影不红', same.cap_projected !== true && same.cap_projected_drift !== true
    && same.cap_shadowed !== true,
  [same.cap_projected, same.cap_projected_drift, same.cap_shadowed])
  const drift = only(mergeRows([poolRow({ discovery: 'config', max_concurrency: 8 })],
    [declRow({ max_concurrency: 10 })]), 'http://10.0.0.5:8012')
  check('S4 config 漂移=等自愈琥珀', badgeOf(drift) === 'amber-declared', badgeOf(drift))
  check('S4 declared 显示值=声明值', drift.max_concurrency === 10, drift.max_concurrency)
}

// ── S5 未入池的纯声明行：渲染字段不变（回归锚 d）──
{
  const row = only(mergeRows([], [declRow({ max_gpu_util: 40, model_id: 'glm' })]), 'http://10.0.0.5:8012')
  check('S5 未入池 cap_owner=declared', row.cap_owner === 'declared', row.cap_owner)
  check('S5 未入池无徽章', badgeOf(row) === 'none', badgeOf(row))
  check('S5 未入池 cap_drift 全 false', Array.isArray(row.cap_drift) && row.cap_drift.length === 2
    && row.cap_drift[0] === false && row.cap_drift[1] === false, row.cap_drift)
  check('S5 未入池显示值=声明值', row.min_concurrency === 2 && row.max_concurrency === 10 && row.max_gpu_util === 40,
    [row.min_concurrency, row.max_concurrency, row.max_gpu_util])
  check('S5 未入池三布尔位全灭', !row.cap_projected && !row.cap_projected_drift && !row.cap_shadowed,
    [row.cap_projected, row.cap_projected_drift, row.cap_shadowed])
  check('S5 未入池 load_state 缺席', row.load_state === undefined, row.load_state)
}

// ── S6 无声明的动态行：三徽章全灭（既有形状）──
{
  const row = only(mergeRows([poolRow({ discovery: 'dynamic' })], []), 'http://10.0.0.5:8012')
  check('S6 未声明 cap_owner=runtime', row.cap_owner === 'runtime', row.cap_owner)
  check('S6 未声明无徽章', badgeOf(row) === 'none', badgeOf(row))
  check('S6 未声明 cap_shadowed=false', row.cap_shadowed === false, row.cap_shadowed)
}

// ── S7 对外契约与形状 ──
{
  // cap_owner 取值域只有 'declared' | 'runtime'（:249 编辑入口开关、:370-386 弹窗 disable、
  // i18n capLockedHint 与 doc 都按它建 —— 新增的是行级布尔位，不许是新的 cap_owner 取值）。
  const cases = [
    [[poolRow({ discovery: 'dynamic' })], []],
    [[poolRow({ discovery: 'config' })], [declRow()]],
    [[], [declRow()]],
    [[poolRow({ discovery: 'watcher', min_concurrency: undefined, max_concurrency: undefined })],
      [declRow({ min_concurrency: undefined, max_concurrency: undefined, model_id: 'glm' })]],
    [[poolRow({ discovery: 'router-watch' })], [declRow({ max_gpu_util: 50 })]]
  ]
  cases.forEach((pair, i) => {
    for (const row of mergeRows(pair[0], pair[1])) {
      check('S7 cap_owner 取值域 (' + i + ')', row.cap_owner === 'declared' || row.cap_owner === 'runtime', row.cap_owner)
      const lit = [Boolean(row.cap_projected), Boolean(row.cap_projected_drift), Boolean(row.cap_shadowed)].filter(Boolean).length
      check('S7 徽章布尔位互斥 (' + i + ')', lit <= 1, [row.cap_projected, row.cap_projected_drift, row.cap_shadowed])
      // declared 行永不借用 protected 档的布尔位
      if (row.cap_owner === 'declared') {
        check('S7 declared 行三布尔位全灭 (' + i + ')', !row.cap_projected && !row.cap_projected_drift && !row.cap_shadowed,
          [row.cap_owner, row.inPool, row.cap_projected, row.cap_projected_drift, row.cap_shadowed])
      }
    }
  })
  // cap_drift 形状契约：恒为两元素布尔数组（模板按 [0]||[1] 判断，槽 0 并发 / 槽 1 利用率）。
  const shape = mergeRows(
    [poolRow({ discovery: 'config' }), poolRow({ url: 'http://10.0.0.9:1', id: 'w9', discovery: 'dynamic' })],
    [declRow(), { url: 'http://10.0.0.9:1', min_concurrency: 3 }])
  for (const row of shape) {
    check('S7 cap_drift 两槽 (' + row.url + ')', Array.isArray(row.cap_drift) && row.cap_drift.length === 2
      && typeof row.cap_drift[0] === 'boolean' && typeof row.cap_drift[1] === 'boolean', row.cap_drift)
  }
}

// ── S8 归一化对字符串数值同样成立（后端 cap_normalize 用 tonumber，前端用 Number）──
{
  const row = only(mergeRows([poolRow({ discovery: 'dynamic' })],
    [declRow({ min_concurrency: '2', max_concurrency: '10' })]), 'http://10.0.0.5:8012')
  check('S8 字符串数值等价', badgeOf(row) === 'teal-projected', badgeOf(row))
}

// ── S9 词典齐全性：容量徽章用到的每个键必须在 zh-CN 与 en-US 两侧都有非空文案 ──
// 徽章的 label/tooltip 全部走 t.<key>，缺一侧的键会由 translate 的中文回退兜住，
// 于是"只写了一种语言"在页面上不报错、只是英文用户看到中文 —— 只能在这里钉。
function loadI18n () {
  const i18nPath = path.join(here, '..', '..', 'ui', 'admin', 'i18n.js')
  const code = readFileSync(i18nPath, 'utf8')
  const fakeWindow = {}
  const runner = new Function('window', 'localStorage', 'Quasar', 'document', code + '\nreturn window.lmrI18n')
  return runner(fakeWindow, { getItem: () => null, setItem: () => {} }, {}, {})
}
{
  const capKeys = ['capFromDecl', 'capDrift', 'capDriftHint', 'capProjected', 'capProjectedHint',
    'capProjectedDrift', 'capProjectedDriftHint', 'capShadowed', 'capShadowedHint', 'capUnlimited',
    'capNoGate', 'capNoSample', 'capMeasured', 'capLockedHint']
  // 模板引用的键必须还在（改名 = 徽章空白）：从 html 的容量列里抓 t.xxx 与 {{ t.xxx }}。
  const capBlock = html.slice(html.indexOf('body-cell-capacity'), html.indexOf('body-cell-key'))
  const templateKeys = Array.from(new Set(Array.from(capBlock.matchAll(/t\.([A-Za-z0-9_]+)/g)).map(m => m[1])))
  check('S9 容量列确实引用了徽章键', templateKeys.includes('capProjected') && templateKeys.includes('capProjectedDrift')
    && templateKeys.includes('capShadowed') && templateKeys.includes('capFromDecl'), templateKeys)
  // 徽章的 v-if / v-else-if 顺序 = badgeOf 的优先级，两者必须一致：顺序写反（例如把
  // cap_shadowed 排到最前）会在布尔位全对的情况下仍然满屏红，而布尔位断言一条都不会红。
  const seq = [capBlock.indexOf('cap_owner'), capBlock.indexOf('props.row.cap_projected"'),
    capBlock.indexOf('props.row.cap_projected_drift"'), capBlock.indexOf('props.row.cap_shadowed"')]
  check('S9 徽章顺序与 badgeOf 一致', seq.every(k => k > -1) && seq[0] < seq[1] && seq[1] < seq[2] && seq[2] < seq[3], seq)
  // 配色档位一并钉死：投影=teal-4、漂移=amber-9、遮蔽=red-4 —— 颜色就是「等一下」与「不生效」的分界。
  check('S9 投影徽章是青色', /cap_projected[^>]*color=.teal-4./.test(capBlock))
  check('S9 漂移徽章是琥珀', /cap_projected_drift[^>]*color=.amber-9./.test(capBlock))
  check('S9 遮蔽徽章是红色', /cap_shadowed[^>]*color=.red-4./.test(capBlock))
  let dict
  try {
    dict = loadI18n().messages
  } catch (error) {
    check('S9 i18n.js 可加载', false, String(error))
  }
  if (dict) {
    for (const locale of ['zh-CN', 'en-US']) {
      // 页面的 t 是三段合并（workers + upstreams + pool，pool 覆盖同名键）：
      // 徽章键散落在 pool 段，只查 workers 段会全体假红。
      const workers = Object.assign({}, (dict[locale] || {}).workers || {},
        (dict[locale] || {}).upstreams || {}, (dict[locale] || {}).pool || {})
      for (const key of capKeys.concat(templateKeys)) {
        check('S9 ' + locale + ' 有 ' + key, typeof workers[key] === 'string' && workers[key].trim() !== '', workers[key])
      }
    }
    // 红色档的说法不许再包含"上限没生效"：那半句已被 2026-10-04 的 caps-only 投影推翻。
    const zhShadow = ((dict['zh-CN'] || {}).pool || {}).capShadowedHint || ''
    check('S9 红档 tooltip 可取到', zhShadow !== '', zhShadow)
    check('S9 红档 tooltip 不再宣称上限失效', !zhShadow.includes('上限与模型此刻没有生效'), zhShadow.slice(0, 60))
    check('S9 红档 tooltip 说清上限缺席', zhShadow.includes('没写任何上限'), zhShadow.slice(0, 60))
  }
}


if (failures > 0) {
  console.log('test_ui_merge: ' + failures + '/' + checks + ' FAILED')
  process.exit(1)
}
console.log('test_ui_merge: ' + checks + ' checks passed')
