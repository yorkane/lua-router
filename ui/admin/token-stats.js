/*
  lua-router 管理控制台 · token 窗口统计（纯算术共享模块，2026-10-08 由 logs.html 抽出）

  为什么有这个文件：主壳侧栏的「实时吞吐」面板与日志监控页必须给同一组 tok/s 读数，
  所以两处调用同一个 summarizeWindow，口径只有一个来源，不许各写一套算术。

  既有裁定（2026-10-05，见 logs.html refreshStats 的注释）：tok/s 不信任后端 /_ui/stats
  的 tok/s——后端用采样桶数当分母，稀疏流量时 elapsed 极小，外推出夸张的瞬时值；因此
  壳层自己拉 /_ui/logs 的日志行用它现算。inflight/buffered/uptime 这类实时计数器仍从后端取。

  下面 BEGIN/END 标记之间是从 logs.html 逐字节搬来的原段（探针按这两个标记切段做纯函数
  对比），段内保持纯函数：不引用 Vue / window / locale / Date / Math.random|now，也不依赖
  函数提升去调段外的东西。window 赋值只出现在段外的导出块里。
*/
(function () {

    // ── BEGIN token-window-stats（纯算术，无 Date / 无随机 / 无顺序依赖）──
    // 探针按字节切这一段（见 /data/tmp/probe_tok_stats.js），所以这段里不许引用
    // Vue、window、locale 等任何外部标识符，也不许依赖函数提升去调外面的东西。
    const STATS_WINDOW_MS = 60000

    // 完成时刻 = ts_ms + duration_ms。ts_ms 是 lr_started（router.lua 的入站时刻），
    // 按它切窗口会把「60 秒前开始、刚在这 60 秒里结束」的长请求整条漏掉。
    // duration_ms 缺失/非法时退回 ts_ms，即对那一行保持旧的按开始时刻语义——
    // 宁可少算 0 秒偏移，也不要把未知时长当成无穷大把它永久挤出窗口。
    function completionMs (row) {
      const ts = Number(row && row.ts_ms)
      if (!Number.isFinite(ts)) return null
      const dur = Number(row && row.duration_ms)
      if (!Number.isFinite(dur) || dur < 0) return ts
      return ts + dur
    }

    function tokenInt (value) {
      const n = Number(value)
      if (!Number.isFinite(n) || n < 0) return 0
      return n
    }

    // 单行口径：cached 是 prompt 的子集，越界（引擎报 cached > prompt）按 prompt 钳住，
    // 否则副行那个「引擎实际 prefill」（fresh = prompt - cached）会变成负数。
    // 注意：主值「输入 tok/s」只用 prompt，与本函数的 cached / fresh 无关。
    function rowTokens (row) {
      const prompt = tokenInt(row && row.prompt_tokens)
      const cached = Math.min(prompt, tokenInt(row && row.cached_tokens))
      return { prompt: prompt, cached: cached, fresh: prompt - cached, completion: tokenInt(row && row.completion_tokens) }
    }

    // 汇总：token 类总量只统计引擎自报 usage 的行（tokens_estimated 为真值时剔除——那种行的
    // prompt 是估算出来的，混进分母会让输入输出两个 tok/s 一起失真）；请求数/错误数仍算全部行，
    // 因为那是真实发生的请求，只是它的 token 读数不可信。
    function summarizeWindow (list, now, windowMs) {
      const span = Number(windowMs) > 0 ? Number(windowMs) : STATS_WINDOW_MS
      const seconds = span / 1000
      let n = 0
      let errors = 0
      let estimatedRows = 0
      let prompt = 0
      let cached = 0
      let completion = 0
      const durations = []
      const ttfts = []
      for (let i = 0; i < list.length; i++) {
        const row = list[i]
        const done = completionMs(row)
        if (done === null) continue
        const age = Number(now) - done
        if (!(age >= 0) || !(age <= span)) continue
        n += 1
        const status = Number(row.status)
        if (Number.isFinite(status) && status >= 400) errors += 1
        const dur = Number(row.duration_ms)
        if (Number.isFinite(dur) && dur >= 0) durations.push(dur)
        const ttft = Number(row.ttft_ms)
        if (Number.isFinite(ttft) && ttft >= 0) ttfts.push(ttft)
        if (row.tokens_estimated) { estimatedRows += 1; continue }
        const tk = rowTokens(row)
        prompt += tk.prompt
        cached += tk.cached
        completion += tk.completion
      }
      const fresh = prompt - cached
      return {
        n: n,
        errors: errors,
        estimatedRows: estimatedRows,
        promptTokens: prompt,
        cachedTokens: cached,
        freshTokens: fresh,
        completionTokens: completion,
        inputTokS: Math.round(prompt / seconds),
        inputFreshTokS: Math.round(fresh / seconds),
        outputTokS: Math.round(completion / seconds),
        cacheHitPct: prompt > 0 ? cached / prompt * 100 : null,
        avgDurationMs: durations.length ? durations.reduce((a, b) => a + b, 0) / durations.length : null,
        avgTtftMs: ttfts.length ? ttfts.reduce((a, b) => a + b, 0) / ttfts.length : null,
        windowS: seconds
      }
    }
    // 旧口径（按开始时刻切 + 盲加 prompt）留在文件里给探针复现用，热路径不再调它。
    function summarizeWindowLegacy (list, now, windowMs) {
      const span = Number(windowMs) > 0 ? Number(windowMs) : STATS_WINDOW_MS
      const win = list.filter(row => {
        const ts = Number(row && row.ts_ms)
        return Number.isFinite(ts) && (Number(now) - ts) < span
      })
      let prompt = 0
      let completion = 0
      for (let i = 0; i < win.length; i++) {
        prompt += tokenInt(win[i] && win[i].prompt_tokens)
        completion += tokenInt(win[i] && win[i].completion_tokens)
      }
      return {
        n: win.length,
        promptTokens: prompt,
        inputTokS: Math.round(prompt / (span / 1000)),
        outputTokS: Math.round(completion / (span / 1000))
      }
    }
    // ── END token-window-stats ──
  // 壳（app.js 侧栏面板）与 logs 页业务代码统一从这里取函数，保证同一口径。
  window.lmrTokenStats = {
    STATS_WINDOW_MS: STATS_WINDOW_MS,
    completionMs: completionMs,
    rowTokens: rowTokens,
    summarizeWindow: summarizeWindow,
    summarizeWindowLegacy: summarizeWindowLegacy
  }
})()
