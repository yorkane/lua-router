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
-- 第三条通道：GPU **功率**（worker 记录上的 max_power_w 上限，判定在 registry 的
-- capacity_exclusion，本模块只负责喂读数）。它与上面
-- 两路共用同一次抓取（metrics 路复用同一个 /metrics 正文，prom 路各自多一条 PromQL），
-- 但走 registry 的独立键（pw:，毫瓦）而不是负载归一化那一路：
--   * 功率是**绝对瓦特**，不是 0..1 打分，所以绝不进 _M.normalize()（那会把 90 W
--     当成 90 % 折成满载），也不写进 load()/K_XLOAD。
--   * 读数优先按**卡**归属：worker 认得出自己那张卡（watcher 台账的 g|<url> 键，由
--     watcher 从容器名 pennyroyal-gpu7 → "7" 解析而来；registry 记录的 labels.gpu 只作
--     第二来源，理由见 worker_card() 上方）且数据源给了逐卡 series 时，写的是
--     **它自己那张卡**的瓦特。「认不出卡」与「该卡没有 series」两种情形**都不写键**，
--     不拿整机 max 顶替：源已经是逐卡的时候，整机 max 是邻居那张卡的瓦特，写进来就等于
--     让一张空闲 worker 因为邻居满载而被排除出候选集——那正是下面「绝不写 0、绝不沿用
--     旧值」要防的同一类事故（监控的一个缺口吃掉容量）。代价如实说明：认不出卡的 worker
--     不受功率上限约束，与 exporter 掉线时一模一样；要把它纳进上限判定，就把容器登记成
--     带 gpuN 的名字，并看 lr_gpu_load_power_per_card_workers 覆盖了几台。
--     只有「数据源根本没有逐卡标签」这一种才回落整机 max（node_exporter、operator 写
--     by(Hostname)、或引擎只报一个整机 gauge 的场景——那也是改动前的唯一口径，逐字节
--     保持不变，否则一直在用的数据源会在逐卡落地当天变黑）。两条通道在意的那条边界
--     始终一致：整机口径取 max 而不是取和/取平均（取和会让「一张满载七张空闲」
--     看起来仍然很闲）。
--     口径（router/文档/UI 必须按这一句写，运维按它配阈值）：per-worker 功率上限
--     max_power_w 比较的是「该 worker 自己那张卡的绝对瓦特」；数据源没有逐卡标签时是
--     「本机最热那张卡的绝对瓦特」；认不出卡或该卡无 series 时**没有读数**（不排除）。
--     21.k 生产上 8 个 worker 曾全部读到同一个数（245/246 的
--     max by (Hostname,instance) 把 8 张卡折成 1 条 series，逐卡标签在 Prometheus 侧就
--     丢了），power_of_two 与 max_power_w 因此零区分度；逐卡数据本身在 exporter 上一直
--     齐全（DCGM_FI_DEV_POWER_USAGE{gpu="6",...} 93.111），要的是查询别把它聚合掉，
--     默认查询串见 host_card_powers() 上方注释。
--   * 采不到就什么都不写，让 TTL 自然过期回到 registry.power_w() == nil，router 侧
--     「未知 -> 不排除」。写 0 或沿用上一次的旧值都会让一个坏掉的 exporter 把 worker
--     永久顶在功率上限之外，那是监控系统故障吃掉容量。
-- 缺省关闭：metrics 路要 SMG_LOAD_POWER=1 才扫功率，prom 路要 SMG_LOAD_POWER_QUERY
-- 非空才多发一条查询，两者都不设时本模块的抓取次数与写入的 key 和改动前逐个字节一致。
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
-- monolith, name by name.  The four-way power rule and the "missing reading writes no
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
