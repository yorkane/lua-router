# GPU 负载源：两路外部负载采样 + 功率观测通道 + 利用率准入门通道

日期：2026-10-01（UTC）。对应 `doc/scope-trim.md` §5.1 的第 1 条缺口（"GPU 负载源"）
与 `doc/architect.md` §5（lr_workers 共享态）/§6（策略消费端）。

**本文主体（§1–§8）讲的是 0..1 的负载打分通道。**同一次抓取顺带采回另外两个读数：
**绝对瓦特**（§9）与**逐卡 GPU 利用率**（§10）。两者都不改变 `registry.load()`——打分只吃
`xl:` 这一条通道。差别在谁在用它们：2026-10-06 起**瓦特不再服务任何容量上限**
（`max_power_w` 退役，功率整条链保留为纯观测），容量判定读的是**利用率**（`gu:` 键 →
`registry.capacity_state`）。判定侧的口径与陷阱自成一篇：
[gap-worker-caps.md](gap-worker-caps.md)（本文只登记搭载方式、env 与指标名）。

实现文件（2026-10-05 拆分后是 facade + 子模块，本文一律「文件 + 函数名」，不钉行号）：
[gpu_load.lua](../lualib/resty/luarouter/gpu_load.lua) facade +
[gpu_load/parse.lua](../lualib/resty/luarouter/gpu_load/parse.lua)（exposition 解析族：
`max_gauge` / `power_watt` / `max_power_watts` / `util_fraction` / `util_by_card`）、
[gpu_load/cards.lua](../lualib/resty/luarouter/gpu_load/cards.lua)（卡归属与折叠：
`assign` / `assign_power` / `assign_util` / `host_powers` / `host_card_powers` /
`host_card_utils` / `power_config` / `util_config`）、
[gpu_load/runpass.lua](../lualib/resty/luarouter/gpu_load/runpass.lua)（`run_pass` 主循环与
三通道计数 `new_stats`）、[gpu_load/seams.lua](../lualib/resty/luarouter/gpu_load/seams.lua)
（live seams：`default_write` / `default_write_power` / `default_write_util`）、
[gpu_load/export.lua](../lualib/resty/luarouter/gpu_load/export.lua)（指标导出 + 定时器）、
[gpu_load/prom.lua](../lualib/resty/luarouter/gpu_load/prom.lua)（Prom 客户端）、
[registry/loads.lua](../lualib/resty/luarouter/registry/loads.lua)（`xl:` / `pw:` / `gu:` 三键的读写）、
[hb.lua](../lualib/resty/luarouter/hb.lua)（定时器接线）、
[config.lua](../lualib/resty/luarouter/config.lua)（env 装配，含利用率那三个）。
单测：[test_gpu_load.lua](../test/unit/test_gpu_load.lua)。
e2e：[e2e_gpu_load.py](../test/integration/e2e_gpu_load.py)。计数由一次全绿门禁日志统一刷新，
本文不登记任何数字。

负载通道的消费端零改动：`power_of_two`（policy.lua 取 `registry.load(id)`）、`cache_aware`
的负载逃逸（`utils.worker_load` 读 `router/candidates.lua` 注入的 `record.load` 快照）、
`/workers` 的 `load` 字段（`registry/records.lua` 的 `info`）——三个负载输入
（metrics 路 / prom 路 / 引擎自报）都穿过同一个 `registry.load()`，所以负载源只需要改变
那一个函数。（2026-10-06 新增的利用率通道**不进** `registry.load()`：它写 `gu:` 独立键，
只被容量准入门读，见 §10。）

---

## 1. 为什么需要它，以及它改变的是什么

在此之前 worker 的"负载"只有一个来源：本进程的在飞请求计数（`lo:<id>`）。这个数字
看不见 GPU——一台卡在跑别人的队列（另一个 router 进程、另一个 router 实例、同机
的第二个引擎、同 DP engine 的另一条 rank）时，它的在飞计数照样是 0，于是
`power_of_two` 会把它当成两个随机候选里更优的那个，`cache_aware` 的逃逸条件
（`max-min > balance_abs_threshold && max > min * balance_rel_threshold`）
永远不成立。

本模块把外部真实压力采回来，写成 `xl:<id>`（带 TTL 的千分位整数），并让
`registry.load()` 在求值时把它折进同一个数字：

```
load = inflight + milli * load_scale / 1000
```

单位仍是"在飞请求数"，所以两个既有阈值旋钮（`SMG_BALANCE_ABS_THRESHOLD` 缺省 64、
`SMG_LOAD_SCALE` 缺省 100）落在同一个数量级里：0.01 的 GPU 利用率差 ≈ 1 个在飞请求，
逃逸在缺省配置下就是可触发的，而不是需要重新调参。

`source=none`（缺省）时：不建定时器、不发一次 HTTP、不写 registry 任何一个 key、
`lr_stats` 里不出现任何 `lr_gpu_load*` 序列。没显式开启的机器跑的仍是改动前的那条
代码路径——这是第 1 号 e2e 场景钉住的性质。

## 2. 模块分层与接线位置

形状照抄 `watcher.lua` / `mesh.lua`：

- 纯逻辑层（前半，不 require registry、不碰 ngx）：exposition 文本解析、PromQL
  模板渲染、vector→worker 映射、负载合成、Warn 去重的判定部分。全部通过注入的
  seams（`workers` / `get` / `post` / `write` / `now`）驱动，所以单测能在 luajit 下
  直接断言语义，不需要 nginx、不需要端口。
- live 层（后半）：cosocket 抓取（复用 `hb.http_get` / `hb.http_request(..., "probe")`
  与它的连接池分类）、共享字典写入、自己的 `ngx.timer.at` 自续约定时器、
  `resty.lock` 单飞。

定时器挂在 `hb.start()` 而不是 `init.lua`：`init.lua` 不在本任务的文件所有权里，
而 `init_worker` 的 `ngx.worker.id() ~= 0` 闸门已经由 `hb.start()` 站在正确位置——
它已经是"一个进程按时钟拨遍每个 worker"的那个模块。挂载点在
`disable_health_check` 早返回**之前**：`SMG_DISABLE_HEALTH_CHECK` 说的是"不要用探测
评判 worker"，一个从不触碰健康判定的采样没有理由跟着扫描一起关掉。`gpu_load` 保留
自己的 interval 与失败语义，健康扫描的 shape 一字未变。

`observability.lua` 也不在所有权里，因此指标登记只用它的既有原语
（`observability.counter` / `observability.gauge`）：导出器渲染 `lr_stats` 里出现的
任何键，所以模块自己写键、不动导出器，`source=none` 时一个键都不写。

## 3. 两路源的语义

### 3.1 `source=metrics`（本地，抓后端自带 exporter）

对每个在池 worker `GET {worker.url}{SMG_LOAD_METRICS_PATH}`（缺省 `/metrics`），
纯 Lua 解析 Prometheus 文本协议，在 `SMG_LOAD_METRICS_KEYS` 给的 gauge 名集合里
取**最大值**，归一化到 0..1。

解析细节（都是单测直接钉住的用例）：

- 样本行按字符扫描切分，不是"第一个空格分name/value"——标签值可以含空格、逗号、
  花括号和转义引号（`a{x="1 2"} 3` 必须解析对）。
- `#` 首字节即 HELP/TYPE，直接跳过（metric 名不允许以 `#` 开头）。
- 名字归一：trim + 小写 + `:`→`_`。一条 env 值同时命中 vLLM 实际写出的
  `vllm:gpu_cache_usage_perc` 与聚合器改写后的下划线拼写，也就是本仓库
  `/engine_metrics` 那条路径的写法。
- `NaN` / `+Inf` / `-Inf` / 空串是合法 exposition 但都是"这里没有可用数字"，一律
  解析成 nil。尤其 NaN：它与任何值比较都是 false，放进 max 归约会静默吞掉整条线。
- 多标签序列（每个 GPU 一条）取最大值：两卡 85/90 的答案是 90，不是均值、也不是
  最后一条。
- 归一化：`>1` 视为百分数除以 100，`≤1` 视为分数。负数返回 nil；`>100%` 夹到 1。
  超过 100% 是夹取而不是丢弃——驱动把利用率四舍五入到 105%，或者调度器把 cache
  用量顶过自身容量，都仍然是"这张卡很忙"，为了 5% 的取整丢掉样本会让最忙的卡变成
  "没有读数"。

缺省 gauge 候选（`SMG_LOAD_METRICS_KEYS` 为空时使用）：`nvidia_gpu_utilization`、
`dcgm_gpu_utilization`、`gpu_cache_usage_perc`、`vllm:gpu_cache_usage_perc`——前两个
是百分数，后两个是 0..1 分数，两种量纲靠上面的推断统一。

worker 的 `api_key` 会作为 `Authorization: Bearer` 带上，与 `hb` 的探针、
`loads_handler` 拉 `/v1/loads` 时的行为一致。

抓取是 **serial**（`check_all` 也是 serial），没有并发 fan-out：一轮 pass 的最坏
耗时是 `N × timeout`，而 `timeout` 被夹到不超过 `interval/2`，并且 tick 前有
`lr_locks` 单飞锁，抢不到就跳过而不是叠轮次。大池子下"跳过"是慢机器上的正常答案，
因此它不产生 WARN。

### 3.2 `source=prom`（远程，同步抓既有监控）

每轮向 `SMG_LOAD_PROM_URL` 的 `/api/v1/query` 发 `POST`，表单体
`query=<urlencoded SMG_LOAD_PROM_QUERY>`，只读 `data.result[].value` 这一种形状。

- `resultType` 明确不是 `vector` 时算错误而非空结果：matrix / scalar 没有可映射回
  worker 的 per-series 身份。
- 主机标签按 `HOST_LABELS` 顺序取第一个非空：`instance`、`host`、`hostname`、`node`、
  `pod`、`name`。前一个是 exporter 被抓时的 `host:port`，其余覆盖 SD 产生的标签集
  （kubernetes_pod / node / docker compose）。标签值会先剥掉 URL 前缀、路径、rank
  后缀 `@N` 再归一，所以 `"http://h:p/metrics"` 与 `"h:p"` 得到同一个键。
- 一台机上的多个 worker（DP engine 的 4 条 rank、同机两个引擎）共享同一条读数：
  GPU 才是共享资源，共享读数才是诚实读数。vector 里出现池中没有的机器 → 计入
  `unmatched`，绝不凭空安到某个 worker 上。
- 同一 host 多条序列取最热的一条。
- `{host}` / `{instance}` 占位符：模板里没有占位符 → 一轮 pass 一次 POST（远程源
  便宜的全部理由）；有占位符 → 按**渲染后的查询文本**去重，每轮每个不同查询一次
  POST，因此同机多条 rank 折叠成一次。替换走 `gsub` 的函数形式，主机名里的 `%` 保持
  字面量。
- 缺 `SMG_LOAD_PROM_URL` 或 `SMG_LOAD_PROM_QUERY` → 直接跳过本轮并 WARN 一次，
  不去猜。

## 4. 优先级：外部源 > `/v1/loads` 自报

`registry.load()` 的求值次序（唯一决策点在 `registry.load_with`，`gpu_load.effective_load`
是同一条规则的纯函数版本）：

1. 本进程在飞计数 `lo:<id>`：永远加进去。只有 router 自己知道刚把一个请求交给某个
   worker 且它还没服务完，也是唯一能在毫秒内对突发做出反应的值。丢掉它会让一次突发
   在下一个负载 tick 之前看起来是平的。
2. `xl:<id>`（外部 GPU 样本）：有则用。它是唯一读到共享硬件的信号——见 §1。
3. `sl:<id>`（引擎自报）：**仅在 `xl:` 不存在时**才读。

两路不互踩，靠三件事保证：

- **分键**：`xl:` 与 `sl:` 是两个键，"谁说了算"写在数据模型里，而不是靠调用顺序。
  同一个 tick 里外部样本存在时，自报值被完整忽略，反之自报值兜底——两个写者永远不会
  争同一个字段。
- **本仓库的 `/v1/loads` 从不回写 registry**。`router.lua` 的 `loads_handler` 仍是
  按需拉取 `GET {url}/v1/loads?include=core` 并把 `aggregate.total_tokens` 直接放进
  响应，一次 `set_self_reported_load` 都不调用。`sl:` 键位是为它保留的，等哪天真要加
  自报 fan-out，它是第二个写者而不会与第一个撞车。第 2 号 e2e 场景把这个不变量变成
  可观测：同一 worker 的 `/v1/loads` 返回 4242，而 `/workers` 的 `load` 里 4242
  必须不出现。
- **`xl:` 的唯一写者是 `gpu_load.lua`**（单测除外），所以排序是可判定的，不是先到先得到。

另外两个设计点：

- TTL 就是全部的清理机制。样本过期→读取返回 nil→负载退回纯在飞，不需要清扫定时器，
  也不会把一台监控挂掉的机器永久钉在高负载上。`SMG_LOAD_STALE_SECS=0` 时取 3 倍间隔：
  一次 Prometheus 抖动、一次慢抓取或一次拒接连接不会让整池退回在飞计数，同时上一份
  好样本之后一分钟内失效就是真的失效。
- 全局共享标志 `xany` 让"这台机器现在有没有外部样本"是一次进程内 memo 的 shdict 读
  （1 秒窗口），而不是每 worker 一次 `get`。它是必要的：选路路径每请求每候选都要算一次
  负载，若每次都为"外部键"多打一个 shdict 往返，就是在 CPU 归因里已经点名过的
  per-request shdict 往返上再加价。写者写样本时顺带给 `xany` 上同样的 TTL，键过期即
  标志退役；从未存过样本的负载源根本不会写这个键。
- `load_scale` 不能只由 worker 0 的 Lua local 持有：定时器只在 0 号进程跑，其余进程会
  停在缺省值上，于是同一对 worker 在不同进程里被排出不同结果。因此 `current_load_scale()`
  懒读一次 `config.load_scale`（env 快照在每个进程里一致），只被显式 `set_load_scale`
  覆盖，`run_pass` 每 tick 重新发布一次，改 env 后下一个 tick 生效。
- `/metrics` 的 `smg_worker_requests_active` 仍喂**原始在飞计数**（`registry.cb_state()`
  里那行注释），它的 Rust 对端计数就是每 worker 的 running requests；把 GPU 样本折进去
  会让这个 gauge 与 router 自己的并发计数器打架，却没有任何调度收益。
  与之相对，`/workers` 的 `load` 用 `load_with()`，让控制台看到的正是策略实际排序用的数。

上游 `/v1/loads` 的现行解析形状：{workers:[{worker,load}], total_workers,
successful, failed}；非 2xx / 超时 / 缺字段一律记 -1（`/v1/loads/stream` 随平面删除，404）。

## 5. env 表

全部在 `config.lua` 的 workers 段之后、`load_*` 命名空间下，缺省值即"关闭"。

| env | 缺省 | 含义 | 校验 |
|---|---|---|---|
| `SMG_LOAD_SOURCE` | `none` | `none\|metrics\|prom`；`none` = 无定时器、无抓取、无 registry 写 | `one_of` 折叠非法值为 `none` |
| `SMG_LOAD_INTERVAL_SECS` | `15` | 采样周期 | 夹到 `1..3600` |
| `SMG_LOAD_TIMEOUT_SECS` | `4` | 单次抓取/查询超时 | 夹到 `1..60`，且再夹到不超过 `interval/2`（否则叠轮次） |
| `SMG_LOAD_PROM_URL` | 空 | Prometheus base（`http://prom:9090`；给到 `/api/v1/query` 也接受） | 空则 prom 源跳过本轮 |
| `SMG_LOAD_PROM_QUERY` | 空 | PromQL 模板，支持 `{host}` / `{instance}` 占位 | 空则 prom 源跳过本轮 |
| `SMG_LOAD_METRICS_KEYS` | 空 | 逗号/空格分隔的 gauge 名集合，空=内置四个候选，取最大值 | 冒号折成下划线、统一小写 |
| `SMG_LOAD_METRICS_PATH` | `/metrics` | 本地源抓取路径 | 补前导 `/` |
| `SMG_LOAD_STALE_SECS` | `0` | 一个样本算"新鲜"多久，`0`=`3×interval` | registry 侧再夹到 `5..3600` |
| `SMG_LOAD_SCALE` | `100` | 满载（1.0）折算成多少个在飞请求（**只作用于打分**，`gu:` 不过这里） | `≤0` 回落 100 |
| `SMG_LOAD_UTIL_ENABLED` | **`1`（开）** | 利用率通道（`gu:` 键）是否采集 | `0/false/no/off` 关；缺省开 = 零选路行为变化（判定只在记录显式配了 `max_gpu_util` 时发生），见 §10 |
| `SMG_LOAD_UTIL_QUERY` | 空 = 缺省串 | prom 路的**第三条** PromQL | 空 = `parse.lua` 的 `DEFAULT_UTIL_QUERY`（`max by (Hostname,instance,gpu) (DCGM_FI_DEV_GPU_UTIL)`，**带 gpu 标签才有逐卡**） |
| `SMG_LOAD_UTIL_KEYS` | 空 = 内置名册 | 覆盖 metrics 路的利用率 gauge 名册 | 逗号/空格分隔；内置名册 = `dcgm_fi_dev_gpu_util` 真名 + nvidia/dcgm 两个同量纲写法，**刻意不含 KV-cache 用量名** |

这三枚利用率开关与本表其余名字**同等待遇**（`config.lua` 的 `load_util_*` 字段，`init_by_lua` 里装配），
差别只在与功率那三个的对比上：`SMG_LOAD_POWER` / `SMG_LOAD_POWER_KEYS` / `SMG_LOAD_POWER_QUERY`
**不在本表**——它们没进 `config.lua`，由 `gpu_load` 自己现读环境变量，因此不可热改、进不了
`/_ui/config`，并且必须三份 conf 都显式 `env` 声明（差异与后果见 §9）。利用率那三个走
`config.lua`，天然进 `/probe/config`；三份 conf 也一并声明它们，是给 `util_config` 的
`os.getenv` 兜底分支放行（两条路都通，见 §10）。**两组共同的不可热改**：worker 环境在 fork 时固定，
全仓没有 setenv/putenv，生效方式是重启容器 / 重下 compose。

## 6. 可观测性

`source=none` 时 `lr_stats` 里没有任何 `lr_gpu_load*` 键，导出面与改动前逐字节相同。
开启后每轮 pass 写：

| 指标 | 类型 | 含义 |
|---|---|---|
| `lr_gpu_load_pass_total` | counter | 完成的 pass 数（证明定时器真在跑） |
| `lr_gpu_load_failures_total` | counter | 被记账的失败（非 2xx、非法正文、无 gauge） |
| `lr_gpu_load_unmatched_total` | counter | prom vector 里落到池外主机的序列数 |
| `lr_gpu_load_workers` | gauge | 最近一轮真正存下样本的 worker 数（覆盖率） |
| `lr_gpu_load{worker="url"}` | gauge | 单个 worker 的归一化样本 0..1 |

日志侧只有一条 WARN 通道，按 `(失败类别, 目标)` 去重，窗口 1 小时：`metrics`（非 2xx）、
`metrics-nogauge`（200 但没有目标 gauge）、`prom`、`prom-config`、`prom-raise` /
`metrics-raise`（seam 抛错）、`source`（未知源名）。去重是必须的而不是修饰性的：
挂掉的 Prometheus 会以每 tick 一次的频率把 error log 写满。

利用率通道的指标自成第**四**族（`lr_gpu_load_util_*`，只在启用时渲染，全表见 §10），
它与本表和 §9 那两族的分界线是**口径**而不是数值：`lr_gpu_load` 是打分（`xl:`，被 `load_scale`
折进在飞请求单位），`lr_gpu_load_util_gpu` 是准入判定的数据源（`gu:`），
`lr_gpu_load_power_watts` 是绝对瓦特（纯观测）。三条都画在同一个 series 名下会让人以为
「打分与准入看的是同一个数」——那正是 2026-10-06 要拆开的两件事。

功率通道的 WARN 类别另有一族（`power-source-none` / `power-query-ignored` / `power-nogauge` /
`power-prom` / `power-prom-raise` / `power-prom-nogauge` / `power-prom-unassigned`），
利用率通道又有自己的一族（`util-nogauge` / `util-noregistry` / `util-prom` /
`util-prom-raise` / `util-prom-nogauge` / `util-prom-unassigned`），
同一套 1 小时去重机制，见 §9 / §10 与 [gap-worker-caps.md](gap-worker-caps.md) §7–§8。

## 7. 测试

单测（无端口绑定，可并发跑）：

```
docker run --rm -v "$PWD:/repo:ro" -w /repo \
  --entrypoint /usr/local/openresty/luajit/bin/luajit -e LUA_TEST_LIB=/repo/lualib \
  authz:latest /repo/test/unit/test_gpu_load.lua
```

计数以一次全绿门禁日志为锚点，本文只登记覆盖面。

2026-10-06 为利用率通道新增的一组（本文第 7 节里最该先看的部分）：
`util_fraction`（负 → nil 而非夹 0、0 是合法读数、恰好 1 = 满载、105 → 1、超
`MAX_PLAUSIBLE_UTIL_PERCENT` → nil）、`util_by_card`（同一份正文扫出整机最热 + 逐卡两张表、
`gpu` 标签只认纯数字、内置名册不含 KV-cache 用量名）、`host_card_utils` / `util_fold`
（机器名与 instance 双键、环回 instance 的采纳条件、被 instance 完全代表的机器名键删除、
归属冲突整台不采纳）、`assign_util`（四路口径 + `per_card` / `fallback` 两个计数）、
`util_config`（缺省开、显式查询与缺省串的分岔、`explicit_query` 判据）、
`seams.default_write_util`（拒收 / 字典满 / 无读者三种定性）、`runpass` 的 util 计数族、
以及「利用率这一路炸了不带走负载与功率的本 tick」的 pcall 隔离。

其余覆盖面（Phase A 在 `_G.ngx = nil` 下验纯逻辑，Phase B 用假 `ngx` + 假 `shdict` 验
TTL 与 registry 写入）：metric 名归一、`parse_number` 对 NaN/Inf、样本行切分（标签内
空格/逗号/引号、坏尾行）、`max_gauge`（多卡取最大、缺失、NaN）、`normalize`
（93→0.93、1→1、400→1、负→nil）、`split_host`（rank 后缀、userinfo、IPv6、FQDN 尾点）、
占位符渲染、`query_endpoint`、`query_body` 的精确 percent-encoding、
`parse_prom_response`（vector 通过、matrix/scalar 拒绝、NaN）、`host_values`、
`assign`（同 host 共享、未知 instance 计 unmatched）、
`one host's reading never bleeds onto its neighbours' workers`（三 worker 三台机器、热机器带
88/5 两条序列、第三台只有 NaN：88 不许串到邻居，NaN-only 主机一个样本都不留）——该 case
用变异测试反向验证过：把 NaN 改成沿用上一条值 → 4 条红；把所有行折叠到第一个 host 键 → 6 条红。
`effective_load`、registry 的
优先级与 TTL 过期、`to_milli`、`stale_ttl`、`source=none` 零副作用、metrics 源
（404 不摘 worker、无 gauge、超大正文、抛错、bearer、keys 限制）、prom 源（单 POST、
`{host}` 每 worker 一次、DP rank 去重、未知 instance、down/垃圾正文、缺配置跳过）、
WARN 1 小时去重、`publish_metrics`、`start` 的各拒绝分支、定时器起停、
抢不到锁时跳过。

回归（同口径并跑，用于证明 registry/hb 的改动没有碰坏别人）：`test_watcher`、`test_mesh`、
`test_policies`、`test_hash`、`test_caps_routing`；改动的 Lua 文件 `luajit -bl` 语法检查、
`openresty -t` 对 `conf/lua-router.conf` 与 `test/conf/nginx-lua-router.conf`。

`test/integration/e2e_gpu_load.py`（与 e2e_caps 分属两道门，严禁并发）把单测结构上看不到的
东西交给真容器：定时器真的在 nginx 里跑、样本跨进程落到 `lr_workers`、`/workers` 与 `/metrics`
把它暴露出来、`power_of_two` 与 `cache_aware` 因它改变行为。mock 的 `/metrics` 导出带 `gpu`
标签的两条 `nvidia_gpu_utilization` 卡序列，所以利用率通道也在真容器里过一遍。分工写在文件
docstring 里：解析/映射/优先级/TTL/去重的语义属于单测，此处只验证接线与消费。
**逐卡归属与容量判定（含 429）的断言不在这里，在
[e2e_caps.py](../test/integration/e2e_caps.py) 的 S3 / S3b**（同一形状的两个方向）。

## 8. 已知限制

1. **打分那一路的 GPU↔worker 映射完全靠 host**。`split_host(worker.url)` 得到主机名，prom 的
   标签值归一后比对。同一台机器上跑两个 router、或 worker 用不同 DNS 名指向同一台机器
   （`worker-a.internal` vs `10.0.0.5`），会被判成两台机器；反之同机的两个 worker 一定
   共享读数——这在 GPU 是共享资源时是对的，在同机两张独立卡上则会过度惩罚。
   **负载（`xl:`）这一路至今没有卡级归属**：它是打分，过度惩罚只是排序偏保守。
   2026-10-06 起的**利用率准入通道（`gu:`）有逐卡归属**（`cards.assign_util` 的四路口径，
   卡号来自 watcher 的容器名 / 命令行解析），因为准入判错方向的代价不是保守而是丢容量——
   详见 §10 与 [gap-worker-caps.md](gap-worker-caps.md) §7。
2. **远程 prom 的拓扑假设**：一个 Prometheus 覆盖全部 worker 主机，导出的 gauge 名由
   操作者写进 PromQL，而且该查询的答案对"每台机器一个可比较的利用率数字"负责。查询
   返回什么本模块不校验（返回 `node_loadavg` 也会被当成负载照收），只有 vector 结构与
   0..1/百分数量纲的推断兜着。基数也要操作者负责：一条查询返回 per-GPU per-pod 的
   几百条序列，会按"同 host 取最大"折叠成每台机器一个数。
3. **metrics 路是 serial 的**。大池 + 慢 exporter 下一轮 pass 可以远大于 interval；
   保护只有单飞锁（抢不到就跳过，不 WARN）和被夹到 `≤ interval/2` 的单次超时。它只影响
   样本新鲜度，不影响转发路径。
4. **失败一律不摘 worker，也因此不产生任何"负载源坏了"的健康信号**。唯一证据是
   `lr_gpu_load_failures_total` 与 WARN 去重后的日志。404 与"没有目标 gauge"在语义上
   是配置缺失而不是 worker 故障，这是刻意的。
5. `lr_workers` 只有 2m（`doc/architect.md` §5），`xl:`/`sl:`/`xany` 与后来的 `pw:`、
   `gu:` 这几类小数值键都与之竞争容量。写入未做 no-enough-space 的特殊校验：shdict 写失败
   时该 tick 无样本（`set_external_load` / `set_power_w` / `set_gpu_util` 返回 false），
   不会崩，但负载侧会安静地退化成纯在飞计数（覆盖率看 `lr_gpu_load_workers`），准入侧会让
   那台的上限静默失效（覆盖率看 `lr_gpu_load_util_workers`，写失败各 WARN 一行）。方向仍是
   「宁可少一层保护，也不因监控自身抖动丢容量」，代价是容量告警要同时看 `lr_workers` 的占用。
6. `SMG_DISABLE_HEALTH_CHECK=1` 时负载源仍照常跑。它不评判 worker，只写数字；这个
   组合是被有意支持的，不是漏洞。
7. 单进程内 WARN 去重表是 Lua local，进程重启即清空，多进程各有一份；这是日志噪音
   抑制，不是计数器，不承担可审计性（可审计性在 `lr_gpu_load_failures_total`）。

## 9. 第三条通道：绝对功率（搭载在本模块上，2026-10-06 起为**纯观测**）

2026-10-01 追加，**2026-10-06 重新定性**。同一轮 pass 顺带把 GPU 的**绝对瓦特**采回来，写成
`pw:<id>`。它从来**不是**第四个负载输入：`registry.load()` 的求值次序（§4）一字未动，功率不
参与打分。它曾经服务 `worker.max_power_w` 这个每服务上限——**该上限已于 2026-10-06 退役**
（用户裁定；为什么退役见 [gap-worker-caps.md](gap-worker-caps.md) §6，一句话版：21.k 实测八个
实例的功率读数完全相同，整机最热卡口径下它区分不出谁忙谁闲）。**采集整条链保留**：`pw:` 键、
`set_power_w` / `power_w` / `power_samples`、本节的六族指标、`/workers` 的 `power_w` 字段都还在，
仍然有读者（看板与逐卡覆盖率），只是**再没有任何容量决策读它**。

为什么留着而不是删掉：删采集要动六族指标 + e2e 断言，收益不抵风险；用户要换的是「上限用哪个
判定指标」，不是「瓦特这个观测量」。旧配置里还写着 `max_power_w` 的行由声明层 warn 一次并丢弃，
不迁移（见 gap-worker-caps.md §6）。因此下面这一节里的「上限」一律读作「观测口径」，历史取舍
原样保留——它们是这套折叠规则的由来，仍是 §10 利用率通道的结构模板。

**搭载方式**

- 不新建定时器、不额外发 HTTP：`source=metrics` 复用**同一次** `GET` 抓到的同一份 exposition 正文，
  在负载解析之外再跑一遍功率解析（`max_power_watts`）；`source=prom` 发**第二条独立 PromQL**
  （`SMG_LOAD_POWER_QUERY`），不合并进负载查询——两条量纲不同（绝对瓦特 vs 0..1）、要能分别归因，
  且功率常需要 `max by (Hostname)(...)` 这种只属于它的聚合。
- `SMG_LOAD_SOURCE=none` 时压根没有定时器，因此设了功率开关也不会有任何读数。这不是 bug（不给
  一个没在跑的模块装门面），但必须让人看见：该组合打一条去重 WARN `power-source-none`。
- 功率折叠用 `host_powers()` 而**不是** `host_values()`：后者走 `normalize()`，照抄会把
  96 W 夹成 1.0，于是读数永远落在 0..1 里出不来。这一条与「本机最热那张卡」的口径由来，
  见 [gap-worker-caps.md](gap-worker-caps.md) §6–§7（那里同时写了上限退役之后这套折叠为什么还留着）。

**env（与本文 §5 那批不同等待遇，不要混为一谈）**

| env | 缺省 | 含义 |
|---|---|---|
| `SMG_LOAD_POWER` | 关 | `source=metrics` 是否顺带扫功率 gauge |
| `SMG_LOAD_POWER_KEYS` | `DCGM_FI_DEV_POWER_USAGE` | 功率 gauge 名单（逗号/空格分隔） |
| `SMG_LOAD_POWER_QUERY` | 空 = 不采功率 | `source=prom` 的第二条 PromQL |

这三个名字由 `gpu_load` 自己 `os.getenv` 现读，**没有进 `config.lua`**（§5 那张表覆盖不到它们）。
三点后果：① nginx 按 `env` 白名单重建 worker 环境，`conf/lua-router.conf`、
`conf/nginx.conf.template`、`test/conf/nginx-lua-router.conf` **三份都要显式声明**，漏一份就静默
失效（本仓库踩过）；② worker 环境在 fork 时固定，**不可热改**；③ 因此它们进不了 `/_ui/config`
的 JSON 视图与管理台，与 AGENTS.md 重点 3/4 的口径不符，并进 config.lua 是收尾项。

**缺省指标只有一个名字的理由**：实测 sglang 引擎自己的 `/metrics` 里没有功率指标（grep 0 行），
vLLM 同理；`node_hwmon_power_average_watt` 只有整机口径，配「取最大」的折叠规则会把整台机器上的
所有 worker 永久顶到上限之上，等于监控系统自己吃掉容量，所以**故意不进缺省名单**（确实要按机器配
请显式写进 `SMG_LOAD_POWER_KEYS`，那时取最大是操作员的选择）。

**新增指标（只在功率启用时渲染；缺省关闭时 `/metrics` 与本文 §6 描述的形态逐字节相同）**

| 指标 | 类型 | 含义 |
|---|---|---|
| `lr_gpu_load_power_samples_total` | counter | 写进 registry 成功的瓦特样本数 |
| `lr_gpu_load_power_parse_failures_total` | counter | 拨通了却拿不到可用瓦数（正文无该 gauge / 响应非合法向量） |
| `lr_gpu_load_power_rejected_total` | counter | 被 registry 主动拒收的读数（近乎恒 0，非 0 = exporter 在撒谎） |
| `lr_gpu_load_power_unmatched_total` | counter | 命名了「池里没有 worker 的机器」的 series 数 |
| `lr_gpu_load_power_workers` | gauge | 有新鲜瓦特读数的 worker 数 |
| `lr_gpu_load_power_watts{worker="url"}` | gauge | 该 worker 本机最热卡的绝对瓦特（与 0..1 的负载族刻意分开，两者不可互解） |

失败语义沿用本文 §8 第 4 条：**一律只损失读数，不摘 worker、不碰健康与熔断**。功率这路还留着
一条硬约束（退役前它是准入判据，退役后它约束的是观测的真实性）——采不到时**什么都不写**，让
TTL（`SMG_LOAD_STALE_SECS`，同 §5）自然过期回到「`power_w()` 返回 nil」，绝不写 0、绝不沿用旧值：
一个 0 W 或过期的旧值都不是观测，是编造。

（瓦特侧的**逐卡**归属与 §10 的利用率逐卡归属共享同一套卡号来源与台账提示；
`lr_gpu_load_power_per_card_workers` 与 `lr_gpu_load_power_workers` 的差就是瓦特侧的逐卡覆盖率。）

## 10. 第四通道：GPU 利用率（`gu:` 键，容量准入门的数据源）

2026-10-06 追加（[caps-redesign-2026-10-06.md](caps-redesign-2026-10-06.md) §5）。它服务的是每 worker 的
`max_gpu_util` **准入门**，判定式与全部取舍在 [gap-worker-caps.md](gap-worker-caps.md) §2 / §7；本节只登记
它与本模块的搭载关系、env 与指标名，以及那条「为什么不用功率」的实测教训。

**为什么从瓦特换成利用率（21.k 实测）**：这台机器上八个 sglang 实例的功率读数**完全相同**（整机最热卡
口径，八台同值约 271 W）。这不是采集坏了，是 §9 那套折叠规则的必然结果——引擎进程看得见整机所有卡，
「取最大」让同机 worker 共享同一个数。一个把所有实例都读成同一个数的指标，在「这一台到顶了、那一台
没有」这个问题上零区分度：给它配上限，等价于给同机全部实例同时按下限（当时的真机证据留在
[deploy-fleet.md](deploy-fleet.md) 的功率上限一节：三台一起被摘）。DCGM 的 `DCGM_FI_DEV_GPU_UTIL` **带
`gpu="0".."7"` 标签**，能逐卡区分，「谁的卡忙」于是变成可判的问题——换的是判定指标，不是采集：
§9 的功率通道整条留下来做观测。

**为什么不复用 `xl:`（最容易写错的一条）**：`xl:` 是打分通道，`registry.load_with` 把它经 `load_scale` 折进
在飞计数——它被保存和被消费的单位是「在飞请求数」。拿一个利用率上限去比它，等于让操作员拧
`SMG_LOAD_SCALE` 这个**打分旋钮**时悄悄挪动了一道**准入门**。所以利用率必须有一个从未穿过 `load_scale` 的
读数，即独立的 `gu:` 键（口径同时写在 [registry/keys.lua](../lualib/resty/luarouter/registry/keys.lua) 的
`K_GPU_UTIL` 注释里，两处必须同义）。两个量纲也各自独立：`xl:` 的名册含 KV-cache 用量
（`vllm:gpu_cache_usage_perc` 等），`gu:` 的内置名册**刻意不含**——KV cache 占用率量的是「引擎装了多少
token」，不是「卡有多忙」，喂给利用率判定 = 一个缓存塞满但卡闲着的引擎被当成满载摘出候选集。

**读数筛子也不复用**：利用率走 `gpu_load/parse.lua` 的 `util_fraction()`，不走打分侧的 `normalize()`。
差别在负数：`normalize()` 为打分可以把越界一律夹进 0..1，准入门不能——**负数 → nil**（绝不夹到 0）。
0 % 是合法读数（21.k 的 dcgm 空载就报 `DCGM_FI_DEV_GPU_UTIL{gpu="0"} 0`），而负数只可能是坏 exporter；
夹成 0 等于给一台撒谎的 exporter 发免检牌——它永远「远低于任何上限」。反向的越界（驱动把利用率舍到
105 %）仍然夹到 1，因为「这张卡很忙」这件事不会因为 5 % 的舍入变成假话。超出
`MAX_PLAUSIBLE_UTIL_PERCENT` = 1000 判 nil：那几乎只会是被误配进名册的**计数器**（运行时长、能量焦耳、
token 累计），那种数字会让这一路 worker 永久高于任何 0..100 的上限而整个从候选集消失——一个配错的
gauge 名单独干掉一个实例，与功率侧 `MAX_PLAUSIBLE_WATTS` 防的是同一类事故。取向统一：**宁可回 nil
（未知 → 不排除），也不猜**。

**内置名册补了真名**：`DEFAULT_UTIL_METRIC_KEYS` = `dcgm_fi_dev_gpu_util`（21.k 的 dcgm-exporter :9400
实际写出的名字）+ `nvidia_gpu_utilization` / `dcgm_gpu_utilization`（其余 exporter 的同量纲写法）。
名册原来只有 `dcgm_gpu_utilization`，那是另一个 exporter 的拼写，与 DCGM 的真名对不上——所以「用 metrics
路取利用率」在 21.k 上其实一直没生效，生产读数全靠 prom 路那条查询。旧写法保留，别的数据源还在用它。

**搭载方式**：不新建定时器、不额外发 HTTP 轮次。`source=metrics` 复用**同一次** `GET` 抓到的同一份 exposition
正文，在负载解析与功率解析之外再跑一遍 `util_by_card()`（整机最热 + 逐卡两张表）；`source=prom` 发
**第三条独立 PromQL**（`SMG_LOAD_UTIL_QUERY`），不与负载/功率查询合并——三条口径根本不同（0..1 打分 /
绝对瓦特 / 0..1 准入），要能分别归因，一条写坏不许把另外两路一起拖走。`SMG_LOAD_SOURCE=none` 时压根没有
定时器，设了利用率开关也不会有任何读数（registry 侧「未知 → 不排除」），这条留去重 WARN。

**逐卡归属：四路口径（唯一判定点 `gpu_load/cards.lua` 的 `assign_util`，结构与 `assign_power` 平行）**

```
源没有逐卡标签            -> 整机最热卡的利用率（与改动前逐字节一致，老源的唯一可能口径）
worker 认得出卡 + 有该卡 series -> 它自己那张卡的读数（util_per_card++）
worker 认不出卡            -> 回退整机 max（util_fallback++）
卡认得出但 vector 没有该卡  -> 回退整机 max（util_fallback++）
```

卡号复用现成的 `worker_card()` / `hint_index()` / `card_key()` / `parse_labels()` 那套设施，一处不改：
watcher 台账的 `g|<url>` 提示优先、registry 记录的 `labels.gpu` 第二来源。21.k 的卡号来自**容器名**
（`qwen38-27b-dflash-tgt-gpu0` 在 8012、`pennyroyal-orca-gpu1` 在 8021、`q38fn-pennyroyal-gpu2..7` 在
8022–8027），本轮由 watcher 从容器名解析并补进 `labels.gpu`（纯 label，见 [gap-worker-caps.md](gap-worker-caps.md) §7）。

**后两支利用率回退、功率不回退，是刻意差别而不是笔误**（设计书 §5 钉死）。功率读绝对瓦特：整机 max 会
把邻居的热度算到一台空闲 worker 头上而把它摘出候选集——一个监控缺口吃掉容量，正是那一路最不肯犯的错，
所以它宁可什么都不写（§9）。利用率读「这张卡忙不忙」：整机 max 在它的语义下是**保守方向**——本机只要
有任何一张卡忙就把这台 worker 当忙看，代价是少用一台机器（吞吐），而不是让满载的卡继续接新请求（排队
与延迟）。「不知道哪张卡归它」时按最热的算，比当它永远不忙诚实。但允许 ≠ 静默：每次回退都计数，看板上
`lr_gpu_load_util_per_card_workers` 与 `lr_gpu_load_util_workers` 一比就知道有多少 worker 还骑在整机 max 上，
前者为 0 而后者非 0 = 逐卡归属一台都没接上（卡号没解析出来，或 `SMG_LOAD_UTIL_QUERY` 把 `gpu` 聚合掉了）。
这正是 342.371 那一课的处方（同一形状在功率侧的完整复盘见 §9 与 [gap-session-2026-10-04.md](gap-session-2026-10-04.md)）。

**prom 缺省查询串**（唯一权威是 `parse.lua` 的 `DEFAULT_UTIL_QUERY`，别处只引用不复制）：

```
max by (Hostname,instance,gpu) (DCGM_FI_DEV_GPU_UTIL)
```

- `gpu` 必须留在 by 里：聚合掉它 = 八台 worker 共用一个数（342.371 的利用率复刻），而
  `lr_gpu_load_util_per_card_workers` 会诚实地停在 0。
- `Hostname` 留在 by 里：让 `util_fold` 在「一台 Prometheus 抓了多台机器的本机 exporter」时识破归属冲突，
  宁可整台不采纳，也不把 A 机最热的卡挂到 B 机头上。
- `instance` 留在 by 里：本 fleet 的 worker 全注册成 `http://127.0.0.1:80xx`，机器名与 IP 之间没有可用
  映射，只有 exporter 的抓取地址能把读数交回本机 worker。
- 用 `max` 而不是 `sum`/`avg`：`sum` 会把同一张卡的多份副本相加（利用率没有「大于 100 %」这一档），
  `avg` 会把「一张满载七张空闲」折成很闲——准入门要的是最热那张卡的读数。

**env（与 §5 那批同等待遇，与 §9 功率那三个不同）**

| env | 缺省 | 含义 |
|---|---|---|
| `SMG_LOAD_UTIL_ENABLED` | **1（开）** | 利用率这一路是否采集；`0/false/no/off` 关
| `SMG_LOAD_UTIL_KEYS` | 空 = 内置名册 | 覆盖 metrics 路的利用率 gauge 名册（逗号/空格分隔） |
| `SMG_LOAD_UTIL_QUERY` | 空 = 缺省串 | prom 路的第三条 PromQL |

这三个名字**走 `config.lua` 装配**（`load_util_enabled` / `_query` / `_keys` 在 `init_by_lua` 里解析，fork
之前完成），因此天然进 `/probe/config` 与管理台可见面（AGENTS.md 重点 3）；三份 conf 也一并 `env` 声明了
它们，那是给 `cards.lua` 的 `util_config()` 的 `os.getenv` 兜底分支放行（两条路都通，漏一份 env 声明时
「手搓 cfg 表」的调用面仍能读到）。与功率那一路相同的两点：每 tick 现读并不比 init 期读一次更「热」，
worker 环境 fork 时固定、全仓没有 setenv/putenv，生效方式是重启容器，**不可热改**；而「prom 路这条查询
要不要多发」看的是**操作员有没有显式写过它**（`util_config` 的 `explicit_query` 口径），否则每个只配了负载
查询的部署都会多打一条没人要求的 POST。

**缺省开的理由**（与功率缺省关相反，值得说清楚）：功率缺省关是因为它会多打一条查询、并喂一个可能没人用
的准入门；利用率缺省开的理由是它的**判定**不由这个开关决定——采集只是把读数写进 registry 的 `gu:` 键，
只有记录上显式配了 `max_gpu_util` 才会有人读它，所以缺省开不会改变任何现有部署的选路行为（红线「缺省零
行为变化」由判定侧的「没配上限 → 零 shdict 读」与「读数未知 → 不排除」保证）。反过来缺省关的代价，是
操作员要多记一个开关才知道利用率上限为什么一直按「未知」放行。

**写入侧的三段式定性**（`gpu_load/seams.lua` 的 `default_write_util`，与功率同形）：registry 返回 false 有
两种原因（数值不可用 / 共享字典没空间），seam 自己再按同一个谓词复筛一遍来分清是哪种——前者计入
`util_rejected`（exporter 在撒谎，要查的是 exporter 不是网络），后者计入 `util_errors`（本网关内存的问题，
`registry/loads.lua` 的 `set_gpu_util` 自己 WARN 一行）。第三种是 registry 还没有 `gu:` 的读者（旧构建或
模块被剥桩），计 `util_failed` 并留一条去重 WARN 指名配置项，比静默强、也比 error 诚实。
