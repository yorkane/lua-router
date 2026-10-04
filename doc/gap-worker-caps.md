# 每服务并发/功率上限：候选集层面的硬排除（gap-worker-caps）

日期：2026-10-01（UTC）。决策人：用户（root 裁定 2026-10-01）。

需求来自「更灵活的模型服务调度策略」（AGENTS.md 项目定位第 1 条）：一张顶到功率墙的卡解码
明显变慢，而在飞请求数和 GPU 利用率两个数字都看不见这件事——于是调度器既不知道它慢，也没有
任何一条规则不许继续往它身上派活。

实现文件：

- [registry.lua](../lualib/resty/luarouter/registry.lua)：`cap_limit` :1673、
  `inflight_requests` :1695、`capacity_exclusion` :1721、`set_power_w` :1759、
  `power_w` :1786、`power_samples` :1798、`clear_power_w` :1819、
  `UPDATE_NUMBER_FIELDS` :2262
- [router.lua](../lualib/resty/luarouter/router.lua)：`candidates_for` :1491（容量门的注释与调用在
  :1498 与 :1546 附近，代码里的交叉引用也写在这一带），503 文案 :2666-2681
- [gpu_load.lua](../lualib/resty/luarouter/gpu_load.lua)：功率通道 `power_watt` :468、
  `max_power_watts` :486、`host_powers` :544、`power_config` :652、导出族 :1536-1566
- [observability.lua](../lualib/resty/luarouter/observability.lua)：HELP :1109
  （`smg_worker_capacity_excluded_total`）、:1168-1173（power 六族）
- 设计关联：[doc/gap-gpu-load.md](gap-gpu-load.md)（负载同源）、
  [doc/gap-virtual-models.md](gap-virtual-models.md)（绑定与 models 背书）

测试：单测 [test_caps_routing.lua](../test/unit/test_caps_routing.lua)、
e2e [e2e_caps.py](../test/integration/e2e_caps.py)（S1–S6）。计数由一次全绿门禁日志统一刷新，
本文不登记任何数字。

---

## 1. 为什么是「硬排除」而不是负载打分

根裁定 2026-10-01：到了配置上限的 worker 必须**离开候选集**，即使 `cache_aware` 的亲和树本来
要把它留下。这是一条「不许」而不是「不太想」的规则，所以它的实现位置也不允许是一个可被别的
项抵销的打分项。

打分承担不了这件事，原因写在策略自己的代码里。策略自带的负载逃逸（`balance_abs` /
`balance_rel` 双阈值、`power_of_two` 的低负载分支）只把「更忙」变成「更不优先」；而
`cache_aware` 命中亲和时按 URL 直接从树里取 tenant、**完全不看负载**
（[policies/cache_aware.lua](../lualib/resty/luarouter/policies/cache_aware.lua) :195-206，
两个分支都会 `tree:insert` 续亲和）。结果就是「超限但粘人」的 worker 恰好把这条规则想搬走的
流量原样留下：前缀命中得越好，它越不可能被负载项挤下去。

唯一不会与之打架的地方是候选集装配。排除发生在 `router.candidates_for`
（[router.lua](../lualib/resty/luarouter/router.lua) :1491），在 `policy:select` 之前——
策略看见的是一份已经把超限成员摘掉的列表，它再怎么排也排不出一个不存在的候选。因此
`policies/` 一字未动，八个策略的 Rust 对拍语义也就没有被动过。

树里因此残留的脏租户不由这里管：策略既有的脏租户清理，加上下一轮亲和重建，会自然把亲和落到
存活候选上。在这一层去动树，等于把选路规则和数据结构的生命周期绑在一起，改一轮亲和就得多背
一条不变量。

还有一件事要说清楚：被排除的 worker 的**健康位与熔断状态不变、不摘 worker、不进 keep-last、
不进保险丝**。这是「这一轮不给它派活」，不是「它坏了」。把两者混起来，一台卡暂时吃满的机器
就会被监控判成故障机，而它下一秒就会回来。

## 2. 两个字段：`max_concurrency` / `max_power_w`

| 字段 | 单位 | 比较对象 | 谁写的 |
|---|---|---|---|
| `max_concurrency` | 个请求 | 本网关的在飞计数 `lo:<id>` | 操作员 |
| `max_power_w` | 瓦 | 该 worker 本机最热卡的采样值 `pw:<id>` | 操作员（阈值）/ gpu_load（读数） |

两者都缺省不限。归一只做一处（`cap_limit`，registry.lua:1673）：缺省、空、非数字、NaN、
±inf、`<= 0` 全部塌成 **nil = 不限**；并发档向下取整——2.5 个槽位有「最多 2 个」和「第 3 个
也行」两种读法，「最多 2 个」是两者的安全交集。因为归一在写入与读取时都同一套，选路侧因此
只需 `cap ~= nil`，不必重复读环境或再校验形状。

判定式（`capacity_exclusion`，registry.lua:1721）：

```
concurrency 排除  ⟺  d:get("lo:"..id) >= max_concurrency
power      排除  ⟺  d:get("pw:"..id) >= max_power_w * 1000
两者都 nil → 一次 shdict 读都不发（未配上限的 worker 零成本）
```

`lo:` 是**本网关自己的在飞计数**，由 router 的 hold/release 用 `shdict:incr` 维护，天然跨
nginx 进程，也是 `smg_worker_requests_active` 导出的同一个原始计数。刻意**不**用
`registry.load()`：那是打分通道（在飞 + 外部 GPU 项的混合体），拿混合值去比一个定义在
「请求数」上的阈值，会让「忙但没满」的 worker 撞上一个它本来无关的门槛。
`inflight_requests()`（registry.lua:1695）就是为此存在——它只读 `lo:`，一个加数都不混。

`pw:` 存**毫瓦整数**（`floor(w*1000+0.5)`），这样亚瓦特级的 gauge 噪声不会改变 key 的数值
类型；唯一写入点是 `registry.set_power_w`（:1759），`power_w()`（:1786）是读侧，nil 表示
「没有新鲜读数」。

**读数未知 → 不排除**，这是本节的地基结论。 `pw:` 缺席时 power 门**放行**。缺失意味着
「未知」而不是 0：`set_power_w` 直接拒收负数 / NaN / ±inf，gpu_load 只在真采到可用正瓦特时
才写，采不到就什么都不写、靠 TTL 自然过期回到 nil——**绝不写 0、绝不沿用上一次旧值**。理由
是代价不对称：监控系统挂掉的代价只能是精度，不能是容量。一个坏 exporter 被读成「0 W」等于给
那台 worker 发免检牌（它永远不会被排除），被读成上一次的高瓦数则会把一个健康服务踢出候选集。
这条与负载采样同源，也正是 key 用 TTL 而不是 last-value-wins 的原因：TTL 到点自动回到「未知」，
而 last-value-wins 会把最后一次读数变成永久事实。

缺省不限同时要保证新旧记录兼容。没声明过上限的记录保持改动前的形状——`add` 里两个字段只在
可用上限存在时才落（registry.lua:888-896 的注释即为此），于是老部署升级后不会凭空长出两个键。
`GET /workers` 里未声明的上限字段同样**缺席**而不是 0（`registry.info()` :1058）：0 会被不
懂归一规则的读者读成「零槽位、永不可选」，而控制台必须分得清「不限」和「配了 0」。

配置入口四条齐全，都走 `registry._M.add`（因此四条路径落库形状一致）：`POST /workers`、
`SMG_WORKER_URLS` 种子、watcher 注册、config 声明层（upstreams reconcile）；DP rank 继承基
记录。热改走 `PUT /workers/{id}`，白名单 `UPDATE_NUMBER_FIELDS`（registry.lua:2262）含这两
个字段，**契约应答是 202 不是 200**——它与 priority/cost 走同一条队列化的更新路径，为它单独
造一个状态码会把契约里那一整段 worker_service 断言拆散。

config 声明层删除某项时把值写成 0（[config_store.lua](../lualib/resty/luarouter/config_store.lua)
:2135 附近），配合 `cap_limit` 的 `<=0 → nil`，「删掉这行声明」与「明确不限」在池侧收敛成
同一个不限。这是刻意的收敛：两者如果留下不同形状，一个只在 JSON 里消失的字段就会变成一个
无法从 `GET /workers` 区分来源的幽灵配置。

## 3. 多卡口径：比较的是「本机最热那张卡」

这一节单列，因为它最容易被下一个改代码的人写错。

`max_power_w` 比的是该 worker **所在整台机器上最热那张卡的绝对瓦特**，不是它独占那张卡的
瓦特。两处实现同此口径：`gpu_load.max_power_watts()` 的 `watts > best`
（[gpu_load.lua](../lualib/resty/luarouter/gpu_load.lua):486）与 `host_powers()` 的
`watts > by_host[host]`（:544）。

为什么取最大而不是取和、取平均：一台 worker 的引擎进程往往看得见整机所有卡。取和会让
「一张满载七张空闲」的机器看起来仍然很闲（八张卡的和顶到天也只有一张卡的量级），取平均会把
最热那张稀释掉；而选路真正要避免的事是「把请求塞给一张已经顶到 TDP 的卡」，那是一张卡的性质，
就得用一张卡的数字来判。

推论是同机 worker **共享同一读数**，多卡共机时按此排除比「只看自己那张卡」更保守。这是有意的
取舍：**宁可少打一份流量，也不把请求塞给一张已顶到 TDP 的卡。**

因此，要给单卡配 TDP 阈值，必须先把 worker 与 GPU 一一对应（`CUDA_VISIBLE_DEVICES` 级别的
隔离），让每台 worker 只看得见自己那张卡，否则阈值会提前触发——表现为「明明只用了两张卡，
另外六台的 worker 全被排除了」。

与负载那一路的区别（防抄错）：`host_values()` 走 `normalize()` 把数字折成 0..1，功率这路
**必须不走 normalize**。照抄的那一行会把 96 W 夹成 1.0，于是功率通道输出的「1」既不是瓦特也
不是负载，拿它去比 `max_power_w` 永远不成立——功能会静默失效而不报错，因为一切看起来都在跑。

## 4. 功率采集：两路源、指标名、TTL、失败语义

采集**搭载在既有负载源上**，不新建定时器：同一个 tick、同一次抓取、同一把 `resty.lock`。
代价是 `SMG_LOAD_SOURCE=none` 时压根没有定时器，此时就算设了功率开关也不会有任何读数，而
`max_power_w` 会安静地一直按「未知 → 不排除」放行——这正是最容易以为自己在生效、其实没有的
那种配置。所以模块在这种情况下打一条去重 WARN `power-source-none`
（gpu_load.lua:1148-1152），而不是悄悄静默。

两路源的取数方式不同，且这个不同是有意的：

- **metrics 路**：复用**同一次** `GET {worker.url}{SMG_LOAD_METRICS_PATH}` 的正文，在负载
  解析之外顺带扫功率 gauge，不额外发一次 HTTP。功率和负载来自同一份快照，两者不会出现时间差。
- **prom 路**：走**第二条独立 PromQL**（`SMG_LOAD_POWER_QUERY`），不与负载查询合并。两条口径
  根本不同（绝对瓦特 vs 0..1 利用率），要能分别归因；而且 operator 常常需要
  `max by (Hostname)(...)` 这种只属于功率的聚合，塞进负载查询里会同时改坏两边的语义。
  metrics 路上设了 `SMG_LOAD_POWER_QUERY` 不生效（那边没有 Prometheus 可问），另有去重 WARN
  `power-query-ignored`。

缺省功率指标名只有 `DCGM_FI_DEV_POWER_USAGE` 一个（dcgm-exporter 每卡瓦特）。实测 sglang 引擎
自己的 `/metrics` 里**没有**功率指标，vLLM 同理，所以缺省名单不放引擎指标——放进去只会让每轮
都落到「解析失败」。另有一个**故意不进缺省**的名字：`node_hwmon_power_average_watt`
（node_exporter，只有整机口径）。理由是折叠规则是取最大：整机口径配上 `max_power_w`，会让
「这台机器上所有 worker 永久高于上限」，等于监控系统自己把容量吃掉。确实要按机器配阈值的场景，
请显式写进 `SMG_LOAD_POWER_KEYS`——那时取最大是操作员自己的选择，不是缺省在替他猜。

单条读数的三筛（`power_watt()` :468），每一道都对应一种会把判定带偏的真实读数：

1. 非数 / NaN / ±inf（与 `parse_number()` 同口径）；
2. `<= 0`：本 fleet 的卡空载也有 80–90 W，读到 0 只可能是 exporter 把「没有这个字段」渲染成
   了 0；
3. `>= MAX_PLAUSIBLE_WATTS` = 5000：几乎只会是被误配进名单的能量计数器
   `DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION`（那是焦耳，会爬到 1e7），或整机 / UPS 读数。

三筛的取向统一：**宁可回 nil（未知 → 不排除），也不猜。** 与负载的 `normalize()` 用夹取兜住
5% 取整误差是两种态度，因为这里判的是硬排除：夹错一个方向就会永久摘掉一个候选。

`max_power_watts()` 与负载的 `max_gauge()` 形状相同但归约规则不同——值先过 `power_watt()`
再比大小。因此一个「一条诚实 96 W + 一条误喂的 1.2e7 能量计数器」的正文仍答 96 W 而不是被污染；
`max_gauge()` 做不到这点，它在 `normalize()` 见到之前就在原始值上归约。

prom 路的机器名折叠在 `host_powers()`（:544），是本模块最容易写错的一段，如实登记口径：
标签键先小写化（dcgm 的机器名标签是**大写** `Hostname`）；机器名类标签
（Hostname / hostname / nodename / host / node / pod / name）与 `instance` **两把键同时登记**，
因为生产上 worker url 常是 `http://127.0.0.1:80xx`，而 dcgm 的 `instance` 是
`127.0.0.1:9400`，两边要在 `127.0.0.1` 这个键上相遇；环回 `instance` 只有在「共享它的整批
series 同属一台机器」时才有资格当键，否则整批不采纳（→ 采不到 → 什么都不写，绝不猜）；被
instance 键完全代表的机器名键会被删掉，否则 `lr_gpu_load_power_unmatched_total` 会随机器数
稳定增长、把排障的人指向一个根本不存在的原因。这套宽一档的匹配只作用于功率通道，负载那一路的
匹配语义保持原样。

TTL 沿用负载的口径：`cfg.load_stale_secs`（`SMG_LOAD_STALE_SECS`，0/未设 →
`3 × SMG_LOAD_INTERVAL_SECS`，缺省 interval=15 ⇒ 45 s），`registry.stale_ttl` :1847 再夹到
5..3600。TTL 是全部的清理机制：过期即回到 nil，不需要清扫定时器。

失败语义一句话：所有失败（拨不通、非 2xx、正文无功率 gauge、PromQL 响应不是合法向量、host
解析不出）**一律只损失读数**，不写 0、不清零别人、不影响健康与熔断。坏 url 归 `skipped`
单列，不进「解析失败」——它是配置问题，数量随坏 url 线性增长，混进去会淹没真故障。

| env | 作用 | 缺省 |
|---|---|---|
| `SMG_LOAD_POWER` | metrics 路是否顺带扫功率 gauge | 关 |
| `SMG_LOAD_POWER_KEYS` | 覆盖功率 gauge 名单（逗号/空格分隔） | `DCGM_FI_DEV_POWER_USAGE` |
| `SMG_LOAD_POWER_QUERY` | prom 路的第二条 PromQL | 空 = 不采功率 |

这三个名字与其余 `SMG_LOAD_*` 不同等待遇，三条警示不许含混：

1. 它们由 gpu_load 自己 `os.getenv` 现读，**没进 `config.lua`**，因此三份 conf 必须显式
   `env` 声明（`conf/lua-router.conf`、`conf/nginx.conf.template`、
   `test/conf/nginx-lua-router.conf`），漏一处就静默失效——nginx 按 `env` 白名单重建 worker
   环境，本仓库踩过这个坑，集成测试用的那份 conf 尤其容易漏（漏了它，e2e 里设
   `SMG_LOAD_POWER=1` 形同虚设）。
2. worker 环境在 fork 时固定、全仓没有 setenv/putenv，所以这三项**不可热改**；生效方式是重启
   容器 / 重下 compose。别把它们承诺成可热改的能力。
3. 它们因此进不了 `/_ui/config` 的 JSON 视图与 UI 配置面。把这三项并进 config.lua / JSON / UI
   是收尾项（AGENTS.md 重点 3/4 的欠账，如实登记，见 §7 末）。另外 prom 功率查询必须保留
   `instance` 标签，否则机器归属会退化成「采不到」。

## 5. 可观测性

`smg_worker_capacity_excluded_total{reason="concurrency"|"power"}`（HELP
observability.lua:1109）：**只在选路那一次调用计数**。`candidates_for` 同一个过滤器会被响应后
的请求日志二次调用（用 `counted` 形参区分），二次读取不计账，否则每次请求把排除计两遍，计数
就读不通了。两个 reason 是不同种类的量（本网关自有的请求数 vs 外部采到的瓦特），所以一条 HELP
同时点名两者，免得 Grafana 图例把这一族读成一种无差别的故障。

功率家族（HELP :1168-1173）：

| 指标 | 含义 |
|---|---|
| `lr_gpu_load_power_samples_total` | 写入成功的瓦特样本数 |
| `lr_gpu_load_power_parse_failures_total` | 拨通了、查询发出去了，却拿不到可用瓦数：正文无该 gauge，或响应不是合法 PromQL 向量 |
| `lr_gpu_load_power_rejected_total` | 被 registry 主动拒收的读数（负值 / NaN / ±inf） |
| `lr_gpu_load_power_unmatched_total` | 命名了「池里没有 worker 的机器」的 series 数（采得到、配不上 worker，需要 operator 看到的信号） |
| `lr_gpu_load_power_workers` | 有新鲜瓦特读数的 worker 数（gauge，覆盖率） |
| `lr_gpu_load_power_watts{worker="<url>"}` | 该 worker 本机最热卡的**绝对瓦特** |

`rejected` 这条近乎恒为 0，**而且必须如此**：gpu_load 在写之前就按同一个谓词（`power_watt()`）
筛过一遍，能走到 registry 的值本来就不该被拒（`default_write_power` :1067 先自己筛，再把
registry 的 false 重新定性）。它非 0 的含义不是「没数据」而是「exporter 在撒谎」——要查的是
exporter 而不是网络；「没数据」那一种显示为 `parse_failures`。这条分账是刻意做的：
`set_power_w` 返回 false 有两种原因（数值不可用 / 共享字典没空间），前者是 exporter 的问题、
后者是本网关内存的问题，混成一个计数器就会把人送去查错的那个。内部统计里它们分别是
`power_rejected` 与 `power_errors`，对外都归到 `lr_gpu_load_power_` 族：`rejected` 只收前者，
后者与 `power_failed`（拨通但拿不到可用瓦数）一起计入 `parse_failures_total`——也就是说
`parse_failures` 非 0 时要看 error log 的去重 WARN 才能分清是 exporter 空、查询坏了，还是
`lr_workers` 满了（后者会另外自己 WARN 一行，见 §8 第 7 条）。

`lr_gpu_load_power_watts` 与 0..1 的 `lr_gpu_load*` 刻意分成两族：一个是绝对瓦特、一个是归一
分数，同一个坐标轴载不动两者，读的人也不可拿一族解释另一族。

缺省关闭时一个 power series 都不导出：`stats.power_enabled` 为假时整族不渲染（metrics 路只认
`SMG_LOAD_POWER=1`、prom 路只认给了 query），`/metrics` 与接这功能之前逐字节一致，契约的
prometheus 段不会多出一族没人解释的指标。

Rust 侧没有每服务上限这个能力，`smg_worker_capacity_excluded_total` 是 **Lua 独有超集**，
对齐 Rust 时不许把它「对齐掉」。

## 6. 与其它子系统的相互位置

- **与 cache_aware**：见 §1。排除发生在候选集装配，不动亲和树，也不改 `policies/`。
- **与熔断 / 健康**：容量排除不碰健康位、不碰熔断计数。因超限被排除的 worker 在 `/workers`
  里仍 `is_healthy=true`——这是「这一轮不给它派活」与「它坏了」的分界所在，也是排障时唯一
  需要先看的一眼。
- **与 429 并发闸**：全场都在上限上时**保持 503 `no_available_workers` 不放宽**
  （router.lua:2666-2681），与邻近并发闸的 fail-closed 取向一致。回退到超限 worker 会恰好复现
  这套上限要消除的行为，而且是在负载下复现——那正是它最疼的时候。
- **503 message 只加一个从句**：`No available workers (N at their configured concurrency/power
  cap)`，让操作员一眼分清「池子空了」和「池子满了」——两种处置相反（加实例 vs 抬上限）。
  `X-SMG-Error-Code` 仍钉在 `no_available_workers`（契约与 UI 键在这个码上）；健康但不可用
  （熔断打开 / 巡检判下）的候选保持**原句不动**，改动前的 503 读起来跟以前完全一样。
- **与多绑定**：同一 worker 在 `candidates` 里绑两个不同模型由 config 层拒绝 400
  （[config_store.lua](../lualib/resty/luarouter/config_store.lua):432
  `build_candidate_bindings`：重复提交同一模型静默去重）；容量上限按 **worker** 计、不按绑定计
  ——同一实例被两个 alias 共用时，两个 alias 共享同一个在飞计数。这条与 §3 的「同机共享读数」
  是同一取向：限的是真实资源（一个进程、一张卡），不是一个名字。
- **与 IGW 的分工**：显式绑定是操作员点名，不受探针背书否决（绑定存在的意义就是用引擎未必携带
  的名字寻址该实例）；IGW 只收窄**未绑定**候选。
- **与 effort/ctx 卡片**：per-attempt 按 `card_key_for`（router.lua:1348）解析，绑定名优先——
  同一 alias 落到两台实例时，不能一个拿 A 的卡一个拿 B 的卡。

## 7. UI 与配置面

两块能力都按 AGENTS.md 重点 3/4 落到了可视化与 JSON 面，不是只给 env：

- `ui/admin/workers.html`：「上限 / 实测」列。配置值与实测值分行且视觉区分——实测只读，一旦被
  当成配置回写，就等于让监控采样替操作员改选路规则。超限标红；`power_w` 缺席显示「—」而不是 0
  （缺席 = 未知，显示 0 会把「没采到」渲染成「远低于上限」）。表单三态与后端 `cap_limit` 归一严格
  对齐：空串 = 省略该字段、`0` = 明确清除上限、`>0` = 设定。
- `ui/admin/upstreams.html`：阈值列 + 声明式 `models` 逗号输入（声明该端点覆盖哪些模型）；三态同上。
- `ui/admin/models.html`：虚拟模型行的 `candidates` 逐条编辑（加/删/改模型名），候选下拉用池成员的
  `models` 实际覆盖度填（该实例覆盖的模型排在前面），并有「离线 / 未经引擎验证 / 需要模型名」的备注。
- ~~`ui/config.html`~~（2026-10-03 已移除，JSON 视图迁至 `ui/admin/models.html` 的「配置 JSON」对话框，
  见 doc/ui-trim-legacy-pages.md）：JSON 视图无损读写 `candidates` 与 `upstreams` 的新字段（含两个上限），表单页
  不画 candidates 编辑区，靠 raw 原样带回——**后端把整表替换当成事实来源**，所以任何一次提交漏掉
  `candidates` 就等于把它抹掉，这条容错读法（形状不对整条丢弃、空数组整体缺席而不是写 `[]`）是必须的。

**唯一的前后端断点（登记为缺口，不是已完成）**：`registry.info()`（:1058，`GET /workers` 的数据源）
输出 `models` 但**不输出 `models_verified`**，于是 `ui/admin/workers.html:336` 的「引擎已验证」徽章
在真实网关上恒不显示（前端已按 `true`/`false`/缺失三态写好，缺字段时宁可什么都不显示也不猜），
`ui/admin/models.html:523` 的「有几台真的能服务该模型」也永远走「没人证明过」那条分支。后端补一个
字段即全线打通——这是本功能剩下的最大 UI 欠账。§4 那三个功率 env 同样还没进 `config.lua` /
`/_ui/config` / 管理台，与它一起计入 AGENTS.md 重点 3/4 的待办。

## 8. 已知限制与残余缺口

1. `disable_health_check` 的 worker **永不进 discover**，因此永不经 `refresh_models`，永远不会
   获得引擎背书（`models_verified` 不会为真）；它要多模型绑定只能靠 config 行显式声明
   `models`，而那只是备注、不构成否决依据。
2. watcher 注册当刻只交 `models[1]`（[watcher.lua](../lualib/resty/luarouter/watcher.lua) :1400 /
   :1440 / :1457 都取 `entry.models[1]`），全量覆盖靠下一轮 `registry.refresh_models` 补齐；预算：
   薄列表每轮问一次、上限 `MAX_MPROBE` = 20 次，完整列表按 `MODELS_REFRESH_COOLDOWN_SECS` =
   300 s 冷却（registry.lua:2193-2202）。
3. **mesh 集群视图不同步 `models` / `models_verified` 与两个上限**：`mesh.observe_worker`
   （[mesh.lua](../lualib/resty/luarouter/mesh.lua):1214）只镜像
   `{worker_id, model_id, url, health, load}`，对端 `GET /ha/workers` 看不见这些字段。上限是
   **每网关独立**的（在飞计数是本网关的，瓦特采样是本网关采的），跨网关不聚合——两个网关各看
   一份在飞数、各摘各的候选，这是当前形态，不是待修的 bug。
4. 手工 `POST /workers` 与 `SMG_WORKER_URLS` 种子进来的行属 protected（`discovery ~= config`），
   watcher 不摘；严格探针的确定性否定对它们同样不生效——这是「手填配置不能凭它判死一个健康
   实例」这条红线的延伸。
5. `registry.all_models()`（`registry.lua:1853`）/ `worker_models()`（`registry.lua:1873`）/
   `record_models()`（`registry.lua:1885`）目前**暂无消费者**。写了但没接线这件事要登记在这里，
   别让人以为已经有读者。两条模型列表链各自用的是：对外 `GET /v1/models` 走 `registry.models()`
   （Rust 对拍钉住的那一列，`models_handler` `router.lua:4108`）；管理台 `GET /_ui/v1/models` 走
   `props.http_workers()`（`ui.lua:198`）。两者都不吃上面那三个 reader。
6. 全场封顶是 503，不是排队：没有「等一个槽位释放」的语义（与 429 闸门的排队能力是两套东西）。
   需要削峰平滑的负载应该配并发闸 + 上游重试，而不是靠 `max_concurrency` 兜。
7. `lr_workers` 2m 容量竞争：`pw:` 写失败只在 `set_power_w` 的 shdict 写分支 WARN 一行
   （registry.lua:1769-1775），后果是该 worker
   在该采样 TTL 内退化成「无上限」。方向仍是「宁可少一层保护，也不因监控自身抖动丢容量」，
   但它意味着容量告警要同时看 `lr_workers` 的占用。
