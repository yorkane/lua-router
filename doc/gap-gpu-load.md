# GPU 负载源：两路外部负载采样接进 registry 的 worker 负载字段

日期：2026-10-01（UTC）。对应 `doc/scope-trim.md` §5.1 的第 1 条缺口（"GPU 负载源"）
与 `doc/architect.md` §5（lr_workers 共享态）/§6（策略消费端）。

实现文件：[gpu_load.lua](../lualib/resty/luarouter/gpu_load.lua)（新增，1102 行：纯逻辑层
+ live 层）、[registry.lua](../lualib/resty/luarouter/registry.lua)（负载字段读写，
+274/-5 行）、[hb.lua](../lualib/resty/luarouter/hb.lua)（定时器接线，+23/-1 行）、
[config.lua](../lualib/resty/luarouter/config.lua)（env，+58 行）。
单测：[test_gpu_load.lua](../test/unit/test_gpu_load.lua)（995 行，43 个 case，**268 checks**）。
e2e：[e2e_gpu_load.py](../test/integration/e2e_gpu_load.py)（762 行，8 个场景、51 处 check，
本轮**只写不跑**）。

消费端零改动：`power_of_two`（policy.lua 取 `registry.load(id)`）、`cache_aware`
的负载逃逸（`utils.worker_load` 读 router.lua 注入的 `record.load` 快照）、
`/workers` 的 `load` 字段（`registry.info()`）——三条通道都穿过同一个
`registry.load()`，所以负载源只需要改变那一个函数。`router.lua`、`policy.lua`、
`observability.lua`、`init.lua` 均无改动。

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
| `SMG_LOAD_SCALE` | `100` | 满载（1.0）折算成多少个在飞请求 | `≤0` 回落 100 |

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

## 7. 测试

单测（唯一被本轮允许运行的验证）：

```
docker run --rm -v "$PWD:/repo:ro" -w /repo \
  --entrypoint /usr/local/openresty/luajit/bin/luajit -e LUA_TEST_LIB=/repo/lualib \
  authz:latest /repo/test/unit/test_gpu_load.lua
→ === 268 checks, 0 failed ===   （43 个 case）
```

覆盖面（Phase A 在 `_G.ngx = nil` 下验纯逻辑，Phase B 用假 `ngx` + 假 `shdict` 验
TTL 与 registry 写入）：metric 名归一、`parse_number` 对 NaN/Inf、样本行切分（标签内
空格/逗号/引号、坏尾行）、`max_gauge`（多卡取最大、缺失、NaN）、`normalize`
（93→0.93、1→1、400→1、负→nil）、`split_host`（rank 后缀、userinfo、IPv6、FQDN 尾点）、
占位符渲染、`query_endpoint`、`query_body` 的精确 percent-encoding、
`parse_prom_response`（vector 通过、matrix/scalar 拒绝、NaN）、`host_values`、
`assign`（同 host 共享、未知 instance 计 unmatched）、`effective_load`、registry 的
优先级与 TTL 过期、`to_milli`、`stale_ttl`、`source=none` 零副作用、metrics 源
（404 不摘 worker、无 gauge、超大正文、抛错、bearer、keys 限制）、prom 源（单 POST、
`{host}` 每 worker 一次、DP rank 去重、未知 instance、down/垃圾正文、缺配置跳过）、
WARN 1 小时去重、`publish_metrics`、`start` 的各拒绝分支、定时器起停、
抢不到锁时跳过。

回归（同口径并跑，全绿，用于证明 registry/hb 的改动没有碰坏别人）：`test_watcher` 267、
`test_mesh` 391、`test_policies` 118、`test_hash` 795、`test_tree` 67；四份 Lua 文件
`luajit -bl` 语法检查通过；`openresty -t` 对 `conf/lua-router.conf` 与
`test/conf/nginx-lua-router.conf` 均成功。

`test/integration/e2e_gpu_load.py` 本轮**只写不跑**，`py_compile` 通过。8 个场景，
把单测结构上看不到的东西交给真容器：定时器真的在 nginx 里跑、样本跨进程落到
`lr_workers`、`/workers` 与 `/metrics` 把它暴露出来、`power_of_two` 与 `cache_aware`
因它改变行为。分工写在文件 docstring 里：解析/映射/优先级/TTL/去重的语义属于单测，
此处只验证接线与消费。

## 8. 已知限制

1. **GPU↔worker 的映射完全靠 host**。`split_host(worker.url)` 得到主机名，prom 的标签
   值归一后比对。同一台机器上跑两个 router、或 worker 用不同 DNS 名指向同一台机器
   （`worker-a.internal` vs `10.0.0.5`），会被判成两台机器；反之同机的两个 worker 一定
   共享读数——这在 GPU 是共享资源时是对的，在同机两张独立卡上则会过度惩罚。没有任何
   一层做 GPU 编号到 worker 的归属判定。
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
5. `lr_workers` 只有 2m（`doc/architect.md` §5），新增 `xl:`/`sl:`/`xany` 三类小数值键
   会与之竞争容量。写入未做 no-enough-space 的特殊校验：shdict 写失败时该 tick 无样本
   （`set_external_load` 返回 false），不会崩，但会安静地退化成纯在飞计数——覆盖率看
   `lr_gpu_load_workers`。
6. `SMG_DISABLE_HEALTH_CHECK=1` 时负载源仍照常跑。它不评判 worker，只写数字；这个
   组合是被有意支持的，不是漏洞。
7. 单进程内 WARN 去重表是 Lua local，进程重启即清空，多进程各有一份；这是日志噪音
   抑制，不是计数器，不承担可审计性（可审计性在 `lr_gpu_load_failures_total`）。
