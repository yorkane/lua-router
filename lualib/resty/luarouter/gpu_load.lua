-- GPU 负载源（doc/gap-gpu-load.md）。
--
-- 两路外部负载源，统一写进 registry 的 worker 负载字段，让 power_of_two 与
-- cache_aware 的负载逃逸吃到真实 GPU/队列压力：
--
--   * source=metrics  GET {worker.url}/metrics，纯 Lua 解析 Prometheus 文本协议，
--     在 SMG_LOAD_METRICS_KEYS 给的 gauge 名集合里取最大值，归一化到 0..1。
--   * source=prom     POST {SMG_LOAD_PROM_URL}/api/v1/query，用 SMG_LOAD_PROM_QUERY
--     这条 PromQL 从既有监控（Prometheus/VictoriaMetrics）同步抓取，解析
--     data.result[].value，按 instance/host 标签映射回在池 worker。
--   * source=none     缺省：没有定时器、没有抓取、registry 一个 key 都不写，
--     也就是零行为变化。
--
-- 第三条通道：GPU **利用率**（worker 记录上的 max_gpu_util 上限，判定在 registry 的
-- capacity_exclusion，本模块只负责喂读数）。它与上面两路共用同一次抓取（metrics 路
-- 复用同一个 /metrics 正文，prom 路各自多一条 PromQL），但走 registry 的独立键
-- （gu:，千分位 0..1）而不是负载归一化那一路：
--   * 利用率是**纯 busy 比例**，不是打分，所以绝不进 _M.normalize()（那条「>1 就当
--     百分数、越界夹到 1」的启发式适合打分、不适合准入），也不写进 load()/K_XLOAD。
--   * 读数优先按**卡**归属：worker 认得出自己那张卡（watcher 台账的 g|<url> 键，由
--     watcher 从容器名 pennyroyal-gpu7 → "7" 解析而来；registry 记录的 labels.gpu 只作
--     第二来源，理由见 worker_card() 上方）且数据源给了逐卡 series 时，写的是
--     **它自己那张卡**的利用率。「认不出卡」与「该卡没有 series」两种情形**回退整机
--     max 并计入 fallback**——利用率语义下整机 max 是保守方向（本机有任何一张卡忙就
--     把这台 worker 当忙看待），代价是少用一台机器而不是让满载的卡继续接活；回退绝不
--     静默，逐卡命中数与回退数一起导出，看这两个数就知道覆盖率。只有「数据源根本没
--     有逐卡标签」时整机 max 才是它的正常口径。整机口径一律取 max 而不是取和/取平均
--     （取和会让「一张满载七张空闲」看起来仍然很闲）。
--     口径（router/文档/UI 必须按这一句写，运维按它配阈值）：per-worker 利用率上限
--     max_gpu_util 比较的是「该 worker 自己那张卡的利用率」；数据源没有逐卡标签或认不
--     出卡时是「本机最热那张卡的利用率」；整机也没有可用读数时**没有读数**（不排除）。
--     逐卡读数在 exporter 上一直齐全（DCGM_FI_DEV_GPU_UTIL{gpu="6",...}），要的是查询
--     别把 gpu 标签聚合掉，默认查询串见 parse.lua 的 DEFAULT_UTIL_QUERY。
--   * 采不到就什么都不写，让 TTL 自然过期回到 registry.gpu_util() == nil，router 侧
--     「未知 -> 不排除」。写 0 或沿用上一次的旧值都会让一个坏掉的 exporter 把 worker
--     永久顶在利用率上限之外（或永远不受限），那是监控系统故障吃掉容量。
-- 采集缺省开（doc/caps-redesign-2026-10-06.md §5）：判定不由这个开关决定，只有记录上
-- 显式配了 max_gpu_util 才有人读 gu:，所以缺省开 = 现有部署零选路行为变化。
--
-- 分两层（与 watcher.lua / mesh.lua 同一形状）：
--   * 纯逻辑层（本文件前半）：Prometheus 文本解析、PromQL 模板渲染、vector 到 worker
--     的映射、负载合成。不碰 ngx、不 require registry，所以
--     test/unit/test_gpu_load.lua 能在 luajit 下直接断言这些语义。
--   * live 层（本文件后半）：cosocket 抓取（复用 hb 的 HTTP helper 与它的连接池
--     分类）、共享字典写入、Warn 去重、自己的 interval 定时器。定时器由 hb.start()
--     拉起（init.lua 不在本模块的所有权里，hb 已经有 worker 0 定时器模式可照抄）。
--
-- 失败语义：任何一路源的错误（连接失败、超时、非 2xx、正文不是合法 exposition、
-- PromQL 返回非法 JSON）都只是「这一 tick 没有样本」——不抛错、不记健康失败、
-- 绝不摘 worker，同一条 WARN 一小时内只说一次。

-- 2026-10-05 (doc/refactor-arch-2026-10-05.md, worker w_bg): the implementation moved
-- verbatim into lualib/resty/luarouter/gpu_load/ -- parse / cards / prom / seams /
-- runpass / export.  What is left here is the file-header contract and this _M facade.
-- Each submodule registers its own "function _M.x" against this pre-loaded table at
-- load time (design doc section 2), so the _M name set, the signatures and the call
-- semantics (including what a unit-test stub can intercept) are identical to the
-- monolith, name by name.  The four-way per-card rule and the "missing reading writes no
-- key -- never 0, never the old value, let the TTL expire it back to nil" discipline
-- are line-for-line intact, each with a single owner (cards.lua / runpass.lua).
local _M = { _VERSION = "0.1.0" }
package.loaded["resty.luarouter.gpu_load"] = _M


require "resty.luarouter.gpu_load.parse"
require "resty.luarouter.gpu_load.cards"
require "resty.luarouter.gpu_load.prom"
require "resty.luarouter.gpu_load.seams"
require "resty.luarouter.gpu_load.runpass"
require "resty.luarouter.gpu_load.export"

return _M
