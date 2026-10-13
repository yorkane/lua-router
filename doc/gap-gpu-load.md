# GPU 负载源：两路外部负载采样 + 利用率准入门通道

实现文件（facade + 子模块，本文按「文件 + 函数名」引用）：[gpu_load.lua](../lualib/resty/luarouter/gpu_load.lua)、
[gpu_load/parse.lua](../lualib/resty/luarouter/gpu_load/parse.lua)（`max_gauge` / `util_fraction` / `util_by_card`）、
[gpu_load/cards.lua](../lualib/resty/luarouter/gpu_load/cards.lua)（卡归属与折叠：`assign_util` / `assign_load` / `host_card_utils` / `host_card_loads` / `util_config`）、
[gpu_load/runpass.lua](../lualib/resty/luarouter/gpu_load/runpass.lua)（`run_pass` 主循环）、
[gpu_load/seams.lua](../lualib/resty/luarouter/gpu_load/seams.lua)（`default_write` / `default_write_util`）、
[gpu_load/export.lua](../lualib/resty/luarouter/gpu_load/export.lua)（指标导出与定时器）、
[gpu_load/prom.lua](../lualib/resty/luarouter/gpu_load/prom.lua)（Prom 客户端与 host 映射：`render_query` / `query_endpoint` / `query_body` / `parse_prom_response` / `host_values` / `assign`）、
[registry/loads.lua](../lualib/resty/luarouter/registry/loads.lua)（`xl:` / `sl:` / `gu:` 三键读写）、
[hb.lua](../lualib/resty/luarouter/hb.lua)（定时器接线）、[config.lua](../lualib/resty/luarouter/config.lua)（env 装配）。
单测 [test_gpu_load.lua](../test/unit/test_gpu_load.lua)，e2e [e2e_gpu_load.py](../test/integration/e2e_gpu_load.py)。
判定侧口径见 [gap-worker-caps.md](gap-worker-caps.md)，本文只登记搭载方式、env 与指标名。

本模块只有两条通道：**0..1 负载打分**（`xl:`，折进在飞请求单位，参与排序）与**逐卡 GPU 利用率准入**
（`gu:`，只做容量准入门的数据源）。两者都不改变 `registry.load()` 的语义——打分穿过 `load_scale`，
利用率从不穿过。容量判定读的是利用率（`gu:` → `registry.capacity_state`）。

## 1. 它改变什么

worker 的"负载"原本只有一个来源：本进程在飞计数（`lo:<id>`）。这个数字看不见 GPU——一台卡在跑别人的
队列（另一个 router 进程、同机第二个引擎、同 DP engine 的另一条 rank）时，在飞计数照样是 0，于是
`power_of_two` 把它当成两个随机候选里更优的那个，`cache_aware` 的逃逸条件
（`max-min > balance_abs_threshold && max > min * balance_rel_threshold`）永不成立。

本模块把外部真实压力写进 `xl:<id>`（带 TTL 的千分位整数），`registry.load()` 求值时折进同一个数字：

```
load = inflight + milli * load_scale / 1000
```

单位仍是"在飞请求数"，两个既有阈值旋钮（`SMG_BALANCE_ABS_THRESHOLD` 缺省 64、`SMG_LOAD_SCALE` 缺省 100）
落在同一数量级：0.01 的利用率差 ≈ 1 个在飞请求，逃逸在缺省配置下就可触发。

`source=none`（缺省）时：不建定时器、不发 HTTP、不写任何 registry 键、`lr_stats` 里不出现任何
`lr_gpu_load*` 序列——没显式开启的机器跑的仍是改动前那条路径。

## 2. 分层与接线

纯逻辑层不 require registry、不碰 ngx，全部通过注入 seams（`workers` / `get` / `post` / `write` / `now`）驱动，
所以单测能在 luajit 下直接断言。live 层负责 cosocket 抓取（复用 `hb.http_get` / `hb.http_request(..., "probe")`）、
共享字典写入、自续约定时器、`resty.lock` 单飞。

定时器挂在 `hb.start()`，挂载点在 `disable_health_check` 早返回**之前**：`SMG_DISABLE_HEALTH_CHECK` 说的是
"不要用探测评判 worker"，一个从不触碰健康判定的采样没有理由跟着关掉。`source=none` 时压根没有定时器，
设了利用率开关也不会有任何读数。

消费端零改动：`power_of_two`（`registry.load(id)`）、`cache_aware` 的负载逃逸（`utils.worker_load` 读
`router/candidates.lua` 注入的 `record.load` 快照）、`/workers` 的 `load` 字段——三个负载输入（metrics 路 /
prom 路 / 引擎自报）都穿过同一个 `registry.load()`。利用率通道**不进** `registry.load()`：它写 `gu:` 独立键，
只被容量准入门读（§10）。

## 3. 两路源

### 3.1 `source=metrics`（本地，抓后端自带 exporter）

对每个在池 worker `GET {worker.url}{SMG_LOAD_METRICS_PATH}`，在 `SMG_LOAD_METRICS_KEYS` 给的 gauge 名集合里取
**最大值**，归一化到 0..1。解析细节由单测钉住：

- 样本行按字符扫描切分，不是"第一个空格分 name/value"——标签值可含空格、逗号、花括号与转义引号。
- `#` 首字节即 HELP/TYPE，跳过。
- 名字归一：trim + 小写 + `:`→`_`，一条 env 值同时命中 vLLM 写出的 `vllm:gpu_cache_usage_perc` 与聚合器改写
  后的下划线拼写。
- `NaN` / `+Inf` / `-Inf` / 空串一律解析成 nil。尤其 NaN：它与任何值比较都是 false，放进 max 归约会静默吞掉整条线。
- 多标签序列（每 GPU 一条）取最大值：两卡 85/90 的答案是 90。
- 归一化：`>1` 视为百分数除以 100，`≤1` 视为分数；负数 nil；`>100%` 夹到 1（驱动舍入到 105% 仍然"这张卡很忙"，
  为 5% 的取整丢样本会让最忙的卡变成"没有读数"）。

缺省 gauge 候选（`SMG_LOAD_METRICS_KEYS` 为空时）：`nvidia_gpu_utilization`、`dcgm_gpu_utilization`、
`gpu_cache_usage_perc`、`vllm:gpu_cache_usage_perc`。worker 的 `api_key` 作为 `Authorization: Bearer` 带上。

抓取是 **serial**：一轮最坏 `N × timeout`，`timeout` 夹到不超过 `interval/2`，tick 前有单飞锁，抢不到就跳过
而不是叠轮次。大池子下"跳过"是慢机器上的正常答案，因此不产生 WARN。

### 3.2 `source=prom`（远程，同步抓既有监控）

每轮向 `SMG_LOAD_PROM_URL` 的 `/api/v1/query` 发 `POST`，表单体 `query=<urlencoded SMG_LOAD_PROM_QUERY>`，
只读 `data.result[].value`。

- `resultType` 明确不是 `vector` 算错误而非空结果：matrix / scalar 没有可映射回 worker 的 per-series 身份。
- 主机标签按 `HOST_LABELS` 顺序取第一个非空：`instance`、`host`、`hostname`、`node`、`pod`、`name`。标签值先剥
  URL 前缀、路径、rank 后缀 `@N` 再归一。
- 一台机上的多个 worker（DP 的 4 条 rank、同机两个引擎）共享同一条读数：GPU 才是共享资源。vector 里出现池中
  没有的机器 → 计入 `unmatched`，绝不凭空安到某个 worker 上。同 host 多条序列取最热的一条。
- `{host}` / `{instance}` 占位符：模板无占位符 → 一轮一次 POST；有占位符 → 按**渲染后的查询文本**去重，
  同机多条 rank 折叠成一次。替换走 `gsub` 的函数形式，主机名里的 `%` 保持字面量。
- 缺 `SMG_LOAD_PROM_URL` 或 `SMG_LOAD_PROM_QUERY` → 跳过本轮并 WARN 一次，不去猜。

## 4. 优先级：外部源 > `/v1/loads` 自报

`registry.load()` 的求值次序（唯一决策点 `registry.load_with`；`gpu_load.effective_load` 是它的纯函数版本）：

1. 本进程在飞计数 `lo:<id>`：永远加进去。只有 router 知道刚把请求交给谁且它还没服务完，也是唯一能在毫秒内
   对突发做出反应的值。
2. `xl:<id>`（外部样本）：有则用。
3. `sl:<id>`（引擎自报）：**仅在 `xl:` 不存在时**才读。

两路不互踩靠三件事：**分键**（`xl:` 与 `sl:` 是两个键，"谁说了算"写在数据模型里）；**本仓库的 `/v1/loads` 从不
回写 registry**（`loads_handler` 按需拉 `GET {url}/v1/loads?include=core` 并把 `aggregate.total_tokens` 放进响应，
一次 `set_self_reported_load` 都不调用；`sl:` 键位是为它保留的）；**`xl:` 的唯一写者是 gpu_load**（单测除外），
所以排序可判定。

`/metrics` 的 `smg_worker_requests_active` 仍喂**原始在飞计数**：把外部样本折进去会让这个 gauge 与 router 自己的
并发计数器打架，却没有调度收益。`/workers` 的 `load` 用 `load_with()`，让控制台看到策略实际排序用的数。

TTL 是全部的清理机制：样本过期 → 读取 nil → 负载退回纯在飞。不需要清扫定时器，也不会把一台监控挂掉的机器
永久钉在高负载。`SMG_LOAD_STALE_SECS=0` 时取 3 倍间隔。全局共享标志 `xany` 让"这台机器现在有没有外部样本"
是一次带 1 秒窗口的进程内 memo，而不是每 worker 一次 shdict 读（选路每请求每候选都要算一次负载）。
`load_scale` 由 `current_load_scale()` 懒读 `config.load_scale`（env 快照每进程一致）并每 tick 重新发布，
所以 worker 0 之外的进程不会停在缺省值上。

## 5. env 表

`config.lua` 的 `load_*` 字段，缺省值即"关闭"。三份 conf 的 `env` 白名单必须同步登记（漏登记 = nginx 从 worker
剥掉 = 静默走未配置路径）。**不可热改**：worker 环境在 fork 时固定，生效方式是重启容器。

| env | 缺省 | 含义 | 校验 |
|---|---|---|---|
| `SMG_LOAD_SOURCE` | `none` | `none\|metrics\|prom` | `one_of` 折叠非法值为 `none` |
| `SMG_LOAD_INTERVAL_SECS` | `15` | 采样周期 | 夹到 `1..3600` |
| `SMG_LOAD_TIMEOUT_SECS` | `4` | 单次抓取/查询超时 | 夹到 `1..60`，且不超过 `interval/2` |
| `SMG_LOAD_PROM_URL` | 空 | Prometheus base（给到 `/api/v1/query` 也接受） | 空则 prom 源跳过本轮 |
| `SMG_LOAD_PROM_QUERY` | 空 | PromQL 模板，支持 `{host}` / `{instance}` | 空则 prom 源跳过本轮 |
| `SMG_LOAD_METRICS_KEYS` | 空 | gauge 名集合，空=内置四个候选 | 冒号折下划线、统一小写 |
| `SMG_LOAD_METRICS_PATH` | `/metrics` | 本地源抓取路径 | 补前导 `/` |
| `SMG_LOAD_STALE_SECS` | `0` | 样本新鲜期，`0`=`3×interval` | registry 侧夹到 `5..3600` |
| `SMG_LOAD_SCALE` | `100` | 满载折算成多少在飞请求（**只作用于打分**，`gu:` 不过这里） | `≤0` 回落 100 |
| `SMG_LOAD_UTIL_ENABLED` | **`1`（开）** | 利用率通道是否采集 | `0/false/no/off` 关 |
| `SMG_LOAD_UTIL_QUERY` | 空 = 缺省串 | prom 路的**第二条** PromQL | 空 = `parse.lua` 的 `DEFAULT_UTIL_QUERY` |
| `SMG_LOAD_UTIL_KEYS` | 空 = 内置名册 | 覆盖 metrics 路的利用率 gauge 名册 | 逗号/空格分隔 |

## 6. 可观测性

`source=none` 时导出面与改动前逐字节相同。开启后每轮 pass 写：

| 指标 | 类型 | 含义 |
|---|---|---|
| `lr_gpu_load_pass_total` | counter | 完成的 pass 数（证明定时器真在跑） |
| `lr_gpu_load_failures_total` | counter | 被记账的失败（非 2xx、非法正文、无 gauge） |
| `lr_gpu_load_unmatched_total` | counter | prom vector 里落到池外主机的序列数 |
| `lr_gpu_load_workers` | gauge | 最近一轮真正存下样本的 worker 数（覆盖率） |
| `lr_gpu_load{worker="url"}` | gauge | 单个 worker 的归一化样本 0..1 |

利用率自成第**二**族（`lr_gpu_load_util_*`，只在启用时渲染）：`lr_gpu_load_util_gpu`（准入门数据源）、
`lr_gpu_load_util_workers`、`lr_gpu_load_util_per_card_workers`、`lr_gpu_load_util_fallback_total`、
`lr_gpu_load_util_samples_total`、`lr_gpu_load_util_unmatched_total`、`lr_gpu_load_util_rejected_total`、
`lr_gpu_load_util_parse_failures_total`。两族的分界线是**口径**而不是数值：`lr_gpu_load` 是打分（`xl:`，被
`load_scale` 折进在飞请求单位），`lr_gpu_load_util_gpu` 是准入判定的数据源（`gu:`）。两条画进同一个 series 名下
会让人以为「打分与准入看的是同一个数」——那正是要拆开的两件事。

日志侧一条 WARN 通道，按 `(失败类别, 目标)` 去重、窗口 1 小时：`metrics`、`metrics-nogauge`、`prom`、
`prom-config`、`prom-raise` / `metrics-raise`、`source`，利用率一族另加 `util-nogauge` / `util-noregistry` /
`util-prom` / `util-prom-raise` / `util-prom-nogauge` / `util-prom-unassigned`。去重是必须的：挂掉的 Prometheus
会以每 tick 一次的频率写满 error log。

## 7. 测试

单测（无端口绑定，可并发跑）：

```
docker run --rm -v "$PWD:/repo:ro" -w /repo   --entrypoint /usr/local/openresty/luajit/bin/luajit -e LUA_TEST_LIB=/repo/lualib   authz:latest /repo/test/unit/test_gpu_load.lua
```

覆盖面（计数以一次全绿门禁日志为锚）：metric 名归一、`parse_number` 对 NaN/Inf、样本行切分（标签内空格/逗号/
引号、坏尾行）、`max_gauge`（多卡取最大、缺失、NaN）、`normalize`（93→0.93、1→1、400→1、负→nil）、
`split_host`（rank 后缀、userinfo、IPv6、FQDN 尾点）、占位符渲染、`query_endpoint`、`query_body` 的精确
percent-encoding、`parse_prom_response`（vector 通过、matrix/scalar 拒绝、NaN）、`host_values`、`assign`（同 host
共享、未知 instance 计 unmatched）、`one host's reading never bleeds onto its neighbours' workers`（三 worker 三台
机器，热机器带 88/5 两条序列、第三台只有 NaN：88 不许串到邻居，NaN-only 主机一个样本都不留）、`effective_load`、
registry 优先级与 TTL 过期、`to_milli`、`stale_ttl`、`source=none` 零副作用、metrics 源（404 不摘 worker、无 gauge、
超大正文、抛错、bearer、keys 限制）、prom 源（单 POST、`{host}` 每 worker 一次、DP rank 去重、未知 instance、
垃圾正文、缺配置跳过）、WARN 1 小时去重、`publish_metrics`、`start` 的各拒绝分支、抢不到锁时跳过。

利用率一组：`util_fraction`（负 → nil 而非夹 0、0 是合法读数、恰好 1 = 满载、105 → 1、超
`MAX_PLAUSIBLE_UTIL_PERCENT` → nil）、`util_by_card`（同一份正文扫出整机最热 + 逐卡两张表、`gpu` 标签只认纯数字、
内置名册不含 KV-cache 用量名）、`host_card_utils` / `util_fold`（机器名与 instance 双键、环回 instance 的采纳条件、
被 instance 完全代表的机器名键删除、归属冲突整台不采纳）、`assign_util`（四路口径 + `per_card` / `fallback` 两个
计数）、`util_config`（缺省开、显式查询与缺省串的分岔、`explicit_query` 判据）、`default_write_util`（拒收 / 字典满 /
无读者三种定性）、`runpass` 的 util 计数族、以及「利用率这一路炸了不带走负载的本 tick」的 pcall 隔离。

`e2e_gpu_load.py`（与 e2e_caps 分属两道门，严禁并发）验证接线：定时器真的在 nginx 里跑、样本跨进程落到
`lr_workers`、`/workers` 与 `/metrics` 暴露它、`power_of_two` 与 `cache_aware` 因它改变行为。逐卡归属与容量判定
（含 429）的断言在 `e2e_caps.py` 的 S3 / S3b。

## 8. 已知限制

1. **GPU↔worker 映射靠 host**（`split_host(worker.url)` 对 prom 标签值）。同机两个 router、或同一台机器用不同
   DNS 名注册，会被判成两台机器；反之同机两个 worker 在源没有逐卡标签时共享读数——GPU 是共享资源时这是对的，
   同机两张独立卡上则过度惩罚。两条通道都有逐卡归属：利用率走 `assign_util`（§10），打分走 `assign_load`，
   四路口径同形，覆盖率读数是 `lr_gpu_load_per_card_workers` 与 `lr_gpu_load_fallback_total` 并排。
2. **远程 prom 的拓扑假设**：一个 Prometheus 覆盖全部 worker 主机，gauge 名由操作者写进 PromQL，且该查询对
   "每台机器一个可比较的利用率数字"负责。查询返回什么本模块不校验（返回 `node_loadavg` 也照收），只有 vector
   结构与量纲推断兜着。基数也归操作者负责：per-GPU per-pod 的几百条序列会按"同 host 取最大"折叠。
3. **metrics 路 serial**：大池 + 慢 exporter 下一轮可远大于 interval，保护只有单飞锁与被夹住的超时。只影响
   样本新鲜度，不影响转发路径。
4. **失败一律不摘 worker**，也不产生"负载源坏了"的健康信号（404 与"没有目标 gauge"是配置缺失而非 worker 故障）。
   唯一证据是 `lr_gpu_load_failures_total` 与去重后的 WARN。这与 watcher 严格探针的分档处置是两套东西，
   见 [gap-watcher-merge.md](gap-watcher-merge.md) §1.1。
5. `lr_workers` 只有 2m，`xl:`/`sl:`/`xany`/`gu:` 这些小数键都与它竞争容量。shdict 写失败时该 tick 无样本：
   不会崩，但负载侧安静退化成纯在飞计数（覆盖率看 `lr_gpu_load_workers`），准入侧会让那台的上限静默失效
   （覆盖率看 `lr_gpu_load_util_workers`，写失败各 WARN 一行）。方向是「宁可少一层保护，也不因监控抖动丢容量」。
6. `SMG_DISABLE_HEALTH_CHECK=1` 时负载源仍照常跑：它不评判 worker，只写数字，这个组合是有意支持的。
7. 单进程内 WARN 去重表是 Lua local，进程重启即清空、多进程各一份；这是日志噪音抑制，不承担可审计性
   （可审计性在 `lr_gpu_load_failures_total`）。

## 9. 功率通道（已移除）

绝对瓦特读数曾作为第三条通道存在（`pw:` 键、`SMG_LOAD_POWER*` 三个 env、`lr_gpu_load_power_*` 指标族、
`/workers` 的 `power_w` 字段），**2026-10-09 连采集带指标带 env 整体删除（用户裁定）**。淘汰原因值得留一句：
21.k 实测八个实例的瓦特读数恒为同一值（整机最热卡口径 + "同 host 取最大"折叠的必然结果），对"这一台到顶了、
那一台没有"零区分度——给它配上限，等价于给同机全部实例同时按下限。负载口径从此只有 GPU 利用率（§10）与在途数。

## 10. 利用率通道（`gu:` 键，容量准入门的数据源）

服务的是每 worker 的 `max_gpu_util` **准入门**；判定式与全部取舍在 [gap-worker-caps.md](gap-worker-caps.md) §2 / §6，
本节只登记搭载方式、env 与指标名。

**为什么不用打分那条通道**：`xl:` 被 `load_scale` 折进在飞计数，被保存和消费的单位是"在飞请求数"。拿利用率上限
去比它，等于让操作员拧 `SMG_LOAD_SCALE` 这个**打分旋钮**时悄悄挪动一道**准入门**。所以利用率必须有一个从未穿过
`load_scale` 的读数，即独立的 `gu:` 键（口径同时写在 `registry/keys.lua` 的 `K_GPU_UTIL` 注释，两处必须同义）。
量纲名册也各自独立：`xl:` 含 KV-cache 用量（`vllm:gpu_cache_usage_perc` 等），`gu:` 的内置名册**刻意不含**——
KV cache 占用率量的是"引擎装了多少 token"，不是"卡有多忙"，喂给利用率判定 = 一个缓存塞满但卡闲着的引擎被当成
满载摘出候选集。

**读数筛子不复用**：利用率走 `util_fraction()`，不走打分侧的 `normalize()`。差别在负数——打分可以为排序把越界
一律夹进 0..1，准入门不能：**负数 → nil**（绝不夹到 0）。0 % 是合法读数（dcgm 空载就报 `{gpu="0"} 0`），而负数
只可能是坏 exporter；夹成 0 等于给一台撒谎的 exporter 发免检牌——它永远"远低于任何上限"。反向越界（驱动舍到
105 %）仍夹到 1，"这张卡很忙"不会因 5 % 舍入变成假话。超出 `MAX_PLAUSIBLE_UTIL_PERCENT` = 1000 判 nil：那几乎只会
是被误配进名册的**计数器**（运行时长、能量焦耳、token 累计），这种数字会让这一路 worker 永久高于任何 0..100 上限
而整个从候选集消失。取向统一：**宁可回 nil（未知 → 不排除），也不猜**。

**内置名册**：`DEFAULT_UTIL_METRIC_KEYS` = `dcgm_fi_dev_gpu_util`（dcgm-exporter 实际写出的真名）+
`nvidia_gpu_utilization` / `dcgm_gpu_utilization`（其余 exporter 的同量纲写法）。真名是 2026-10-06 补的：名册原来只有
`dcgm_gpu_utilization`，与 DCGM 真名对不上，所以"用 metrics 路取利用率"在 21.k 上一直没生效。旧写法保留。

**搭载方式**：不新建定时器、不额外发 HTTP 轮次。`source=metrics` 复用**同一次** GET 抓到的同一份 exposition 正文，
在负载解析之外再跑一遍 `util_by_card()`（整机最热 + 逐卡两张表）；`source=prom` 发**第二条独立 PromQL**
（`SMG_LOAD_UTIL_QUERY`），不与负载查询合并——两路口径根本不同，要能分别归因，一条写坏不许把另一路拖走。

**逐卡归属：四路口径（唯一判定点 `gpu_load/cards.lua` 的 `assign_util`）**

```
源没有逐卡标签                -> 整机最热卡的利用率（老源的唯一可能口径）
worker 认得出卡 + 有该卡 series -> 它自己那张卡的读数（util_per_card++）
worker 认不出卡                -> 回退整机 max（util_fallback++）
卡认得出但 vector 没有该卡     -> 回退整机 max（util_fallback++）
```

卡号复用现成的 `worker_card()` / `hint_index()` / `card_key()` / `parse_labels()`：watcher 台账的 `g|<url>` 提示优先，
registry 记录的 `labels.gpu` 第二来源（本 fleet 的卡号由 watcher 从容器名解析并补进 `labels.gpu`）。

**认不出卡时回退整机 max 是刻意选择**：利用率读"这张卡忙不忙"，整机 max 在它的语义下是**保守方向**——本机只要
有任何一张卡忙就把这台 worker 当忙看，代价是少用一台机器（吞吐），而不是让满载的卡继续接新请求（排队与延迟）。
"不知道哪张卡归它"时按最热的算，比当它永远不忙诚实。但允许 ≠ 静默：每次回退都计数，看板上
`lr_gpu_load_util_per_card_workers` 与 `lr_gpu_load_util_workers` 一比就知道有多少 worker 还骑在整机 max 上；
前者为 0 而后者非 0 = 逐卡归属一台都没接上（卡号没解析出来，或 `SMG_LOAD_UTIL_QUERY` 把 `gpu` 聚合掉了）。

**prom 缺省查询串**（唯一权威是 `parse.lua` 的 `DEFAULT_UTIL_QUERY`，别处只引用不复制）：

```
max by (Hostname,instance,gpu) (DCGM_FI_DEV_GPU_UTIL)
```

- `gpu` 必须留在 by 里：聚合掉它 = 同机全部 worker 共用一个数，而 `lr_gpu_load_util_per_card_workers` 会诚实地停在 0。
- `Hostname` 留在 by 里：让 `util_fold` 在"一台 Prometheus 抓了多台机器的本机 exporter"时识破归属冲突，宁可整台
  不采纳，也不把 A 机最热的卡挂到 B 机头上。
- `instance` 留在 by 里：本 fleet 的 worker 全注册成 `http://127.0.0.1:80xx`，机器名与 IP 之间没有可用映射，只有
  exporter 的抓取地址能把读数交回本机 worker。
- 用 `max` 而不是 `sum`/`avg`：`sum` 会把同一张卡的多份副本相加（利用率没有">100 %"这一档），`avg` 会把
  "一张满载七张空闲"折成很闲——准入门要的是最热那张卡的读数。

**缺省开的理由**：采集只是把读数写进 `gu:` 键，只有记录上显式配了 `max_gpu_util` 才会有人读它，所以缺省开不会
改变任何现有部署的选路行为（"缺省零行为变化"由判定侧的"没配上限 → 零 shdict 读"与"读数未知 → 不排除"保证）。
反过来缺省关的代价，是操作员要多记一个开关才知道利用率上限为什么一直按"未知"放行。

`SMG_LOAD_UTIL_*` 三个名字走 `config.lua` 装配（`init_by_lua` 前完成），因此天然进 `/probe/config` 与管理台可见面；
三份 conf 也一并 `env` 声明它们，是给 `cards.lua` 的 `util_config()` 的 `os.getenv` 兜底分支放行。"prom 路这条查询要不要
多发"看操作员有没有**显式**写过它（`util_config` 的 `explicit_query` 口径），否则每个只配了负载查询的部署都会多打
一条没人要求的 POST。

**写入侧三段式定性**（`gpu_load/seams.lua` 的 `default_write_util`）：registry 返回 false 有两种原因，seam 按同一个
谓词复筛分清是哪种——数值不可用计入 `util_rejected`（exporter 在撒谎，要查 exporter 不是网络），共享字典没空间计入
`util_errors`（本网关内存问题，`set_gpu_util` 自己 WARN 一行）。第三种是 registry 还没有 `gu:` 的读者（旧构建或模块
被剥桩），计 `util_failed` 并留一条去重 WARN 指名配置项。
