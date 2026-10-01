# 缺口闭合：`smg_http_inflight_request_age_count` 真实采样

对应 `doc/feature-gap.md` §5 第 2 条与 `doc/gap-metrics-final.md` 表 C 唯一一行。
实现落点：`observability.lua`（登记表 + 采样 + 渲染）、`init.lua`（采样定时器 + log 阶段兜底）、
`router.lua`（`finish_request` 注销 + 顶部注释债）。契约段 `inflight_age`（32 项）。

## 1. Rust 侧在做什么

`gateway/src/observability/inflight_tracker.rs`：

| 环节 | Rust 实现 |
|---|---|
| 登记 | `HttpMetricsLayer::call` 内 `tracker.track()` → `DashMap<u64, Instant>` 插 `request_id → Instant::now()`（`middleware.rs:931`） |
| 注销 | `InFlightGuard::drop` → `requests.remove(&request_id)`（`middleware.rs:936`，`drop(guard)` 在 `inner.call(req).await` 之后、记 duration 之前） |
| 采样 | `PeriodicTask::spawn(20, …)`（`server.rs:1559`）→ `compute_bucket_counts()` 用 `Instant::now()` 逐个求 `as_secs()` → `handle.set_counts(&counts)` |
| 渲染 | `gauge_histogram.rs`：**非累积** gauge，桶是 `(gt, le]` 成对标签，边界 `[30,60,180,300,600,1200,3600,7200,14400,28800,86400]`（11 个边界 = 12 个桶），**没有 `_sum`/`_count`** |
| 空集 | `set_counts(&[0;12])`：全 0 而非隐藏 |
| 观测面 | `tracker.len()` 只在测试里断言（`tests/inflight_tracker_test.rs`），不导出为指标 |

关键点有三条。其一，Rust 只有一个进程、一份 DashMap、一个 `PeriodicTask`。其二，`track()` 在
`route_layer`（auth）与 `RequestBodyLimitLayer`（并发上限）**之外**，所以被 401/429 拒掉的请求
也有年龄；Lua 侧对应 `record_http_request` 的位置，同样先于 auth 与限流。其三，
`start_sampler(20)` 只在 `config.prometheus_config.is_some()` 时调用（server.rs:1558）——
Rust 的"采样器随导出器开"在 Lua 里就是 `LR_INFLIGHT_SAMPLE_SECS=0`：导出面不需要年龄家族时，
采样器与登记表一起关掉。

## 2. Lua 侧的形状差与选型

nginx 是多进程：请求由任意 worker 接管，登记表必须是共享的；没有 `Drop`，注销要挂在
`finish_request` 与 log 阶段两处。共享 dict 里的候选结构：

| 方案 | 结论 |
|---|---|
| 每请求一个 key（`i|<uuid>`） | 语义最直白，但 `lr_stats` 同时装全部 `c|*`/`h|*` 计数器；高并发下每请求两次 key 增删会把线契约推进 LRU 淘汰半径，而 `get_keys(0)` 每次抓取都要把整张表拷成 Lua 表。**不用。** |
| **定长槽表（采用）** | 1024 个 key，`i|0` … `i|1023`，key 数量恒定。分配用 `add()`（只在空槽写入 → 跨进程原子，无 read-modify-write 窗口），值 = `"<start_ms>|<6hex token>"`，带 TTL。约 120 KB / 5m `lr_stats`。 |
| `lr_stats` 里每请求一个 slot 序号 | 需要额外的分配器 key，等价于上面的原子性问题，收益为零。 |

采样成本被表大小固定住：每 tick 一次 1024 次 `get`，每次抓取（occupancy 仪表）再一次 1024 次
`get`。Rust 的 `collect_ages()` 同样是全表遍历，只是它的表会长大。

### 2.1 探针丢失：近似是有界的、可见的

`add()` 从随机槽起步，连续探测 4 个槽（`INFLIGHT_PROBES`）。全部被占则放弃登记，
并 `smg_http_inflight_request_age_dropped_total += 1`（Lua 独有超集，让"丢样本"不是静默的）。
负载因子 `f` 下丢失概率约 `f^4`：

| 并发 | f | 单请求丢失概率 | 期望丢失数 |
|---|---|---|---|
| 64 | 0.0625 | 0.000015 | ≈0.001 |
| 256 | 0.25 | 0.39% | ≈1 |
| 512 | 0.5 | 6.25% | ≈32 |
| 1024 | 1.0 | — | 表满，全部丢失并计入 dropped |

实测（本机 `authz:latest`，mock 9 s 延迟、`LR_INFLIGHT_SAMPLE_SECS=1`、`worker_connections 4096`、
单 worker）：一次放 200 条并发聊天，159 条被上游接纳、41 条因池内无空位立刻 503。抓取时刻
`smg_http_inflight_requests 160 == ..._age_slots_active 160`（159 条在途 + 抓取自身），
`_count 159`、`_sum 372.944`、全部样本落在 `le="2.5"` 起的有限桶里，`dropped_total` 无序列（即 0）。
负载因子 0.195 时理论丢失率 ~0.15%，与"0 条丢失"一致。饱和信号看
`smg_http_inflight_request_age_slots_active / 1024`，这条仪表是**实时扫描槽表**得来的，
不可能和直方图口径打架。

### 2.2 为什么 `forcible` 要撤销

`add()` 返回 `forcible=true` 表示 dict 已满、nginx 挤掉了别人的 key。登记表的全部意义就是
不与线契约争抢，所以此时把手写回：`get(key) == token` 才 `delete`（否则槽位已被别人合法占用，
我们的写入早已失效，不能删别人的活请求）。这条分支不可通过 HTTP 触发，代码路径由
`luajit -bl` 语法门 + 评审覆盖。

## 3. 语义映射：gauge histogram → 累积直方图

这是本任务最大的一处**刻意偏差**，理由与后果都要写清：

| 维度 | Rust | Lua（本实现） |
|---|---|---|
| 家族名 | `smg_http_inflight_request_age_count` | 同名 |
| 桶 | 11 边界 `[30…86400]`，`(gt, le]` 非累积 | **沿用 `SMG_PROMETHEUS_DURATION_BUCKETS`**（默认 20 档 0.001…240），累积 `le` |
| `_sum` / `_count` | 不导出 | 导出 |
| `_count` 的含义 | — | **样本数**：每个 tick 每个在途请求各计 1 次，不是"已完成请求数" |
| 更新方式 | `set_counts()` 覆盖 | 同样覆盖（快照，非累加）→ 请求结束后桶会**回落到 0** |
| 空集 | 渲染全 0 | 首个 tick 起渲染全 0；**tick 之前整个家族缺席** |
| 采样者 | 单进程单任务 | **仅 worker 0** 的 `ngx.timer`（表是共享的，N 个采样者会把 `_count` 乘以 N） |
| 时钟 | 每条 `Instant::now()` | 每 tick 一次 `ngx.now()`，整批同一时刻 |
| 年龄精度 | 整数秒（`as_secs()` 向下取整） | 毫秒差 / 1000，浮点 |

选累积直方图而不是照抄 `gt/le` gauge 的原因：现渲染器只对 histogram 类型做前缀和与
`histogram_quantile`，累积 + `_sum`/`_count` 让这条家族能被 Grafana 的 heatmap/percentile 面板
直接消费；照抄 gauge 语义则需要为 gauge 造一套桶标签渲染，收益是零可查询性。
桶沿用 duration 阶梯（而不是 Rust 的 30s…24h）是为了让同一块面板能并排画"在途年龄"与"已完成时长"；
副作用是亚秒桶永远是 0，读图时按"有限桶里最早出现的非零档"理解即可。

**读数纪律**：`rate()` / `increase()` 对这条家族无意义（快照会上下跳），要用 instantaneous 值；
`_sum / _count` 是"当前在途请求的平均年龄"，不是分位数的替代物。

## 4. 生命周期与防泄漏

| 阶段 | 动作 |
|---|---|
| `record_http_request`（与 `smg_http_requests_total`、`inflight_add(1)` 同处） | `inflight_track()` 登记；位置对齐 Rust 的 `HttpMetricsLayer`，即先于 auth、先于并发上限，401/429 也有年龄 |
| `finish_request`（`limit().release()` 之后） | `inflight_untrack()` 注销，对齐 Rust `drop(guard)` 的位置 |
| `log_by_lua`（`init.lua` `on_log`） | 再 `inflight_untrack()`：客户端中途消失时 `finish_request` 不会执行，log 是唯一还会跑的阶段 |
| 兜底 | 槽位 TTL = `LR_INFLIGHT_TTL_SECS`（默认 3600）：连 log 都没跑到（worker 被杀、Lua abort）时，最迟 TTL 后不再被采样 |

`inflight_untrack()` 幂等：先清 `ngx.ctx` 里的 key/token 再删表；表里已经是别人的 token 时不动手。

### 4.1 跨进程证据

测试 conf 默认 `worker_processes 1`，单进程跑不出共享表的意义。契约用 `sed` 派生一份
四 worker 的 conf（并先断言派生成功，防止测试 conf 漂移后静默退回单进程），
`NGINX_WORKER_PROCESSES` 无关，靠 `ps -eo args= | grep -c "[n]ginx: worker process"`
确认容器里真有四个 worker。32 条并发聊天散在四个 VM 里登记，只有 worker 0 采样：
`_count >= 24` 且 `slots_active == smg_http_inflight_requests` 才算通过 —— 这正是
"任意进程写、单进程读"的证据。

实测验证（契约 `inflight_age` 段）：24 并发打满后 `_count`/全部桶/`_sum` 归 0、
`slots_active` 回到"抓取本身"的 1；`curl -m 0.3` 打断 3 个请求（上游 6 s 才回，写回必然失败，
只有 log 阶段能收尾）后同样归零；`LR_INFLIGHT_TTL_SECS=1` 时请求仍在途但 `_count` 已回 0
（证明 TTL 是硬上界）。全程无 `lua entry thread aborted`。

## 5. 开关

| 名字 | 默认 | 作用 |
|---|---|---|
| `LR_INFLIGHT_SAMPLE_SECS` | 20 | 采样间隔；**0 = 整个 tracker 关闭**：不起定时器、不登记槽位，且 `prometheus_text()` 里按家族名前缀过滤，三个 age 序列全部不渲染（缺席而非造零） |
| `LR_INFLIGHT_TTL_SECS` | 3600 | 槽位 TTL，即泄漏上界 |

两个名字在 `init_by_lua` 里 fork 之前抓取（`init.lua` `wire_inflight_tracker` →
`observability.configure_inflight`），与 `SMG_MESH_*` / `SMG_TRACE_*` 同一模式；
`conf/nginx.conf.template`、`conf/lua-router.conf`、`test/conf/nginx-lua-router.conf`
三处都补了 `env` 声明，这样请求期的 `os.getenv` 也能读到。**没有新增 shared dict**（槽位借用
`lr_stats`），所以无需任何 dict 容量变更。

### 5.1 关闭态是「过滤」而不是「表恰好空」

`LR_INFLIGHT_SAMPLE_SECS=0` 只保证不再产生新样本；`lr_stats` 里可能留着开关拨动之前的一次
快照（histogram key）与未过期槽位。所以渲染路径显式过滤家族名前缀
`smg_http_inflight_request_age`，关闭时整族缺席。

这条过滤最初写成了 `string.find(name, "^" .. prefix, 1, true)` —— `plain=true` 时脱字符是
**字面量**，分支永远不成立，是死代码。为它补了探针 `/probe/inflight-off`（test conf 里的
only-probe location）：手动往 `lr_stats` 塞一份 `n=7` 的 age 直方图和一个已占用的槽位，
再原地渲染 `/metrics`；关闭态必须两条都不出现且 duration 家族不受影响，开启态必须两条都出现
（否则负例可能只是探针自己坏了）。探针读写都恢复原值，可以插在段中间不影响后续断言。

## 6. 复现

```bash
cd /path/to/lua-router

# 单段契约（32 项：直方图不变量、桶对齐、并发登记、跨进程采样、打断回收、TTL 自愈、关闭即缺席、关闭过滤探针）
TEST_ONLY=inflight_age bash test/test_lua_router.sh

# 手工看一次真实采样
LATENCY_MS=6000 python3 test/mock_llm_worker.py --port 18099 --model slow-model &
docker run -d --name lr-age -p 127.0.0.1::8080 \
  -e SMG_HEALTH_CHECK_INTERVAL_SECS=1 -e LR_INFLIGHT_SAMPLE_SECS=1 \
  --entrypoint openresty -v "$PWD/..":/repo:ro authz:latest \
  -p /usr/local/openresty/nginx/ -c /repo/test/conf/nginx-lua-router.conf -g 'daemon off;'
BASE=http://127.0.0.1:$(docker port lr-age 8080/tcp | awk -F: 'NR==1{print $NF}')
curl -X POST $BASE/workers -H 'Content-Type: application/json' \
  --data '{"url":"http://172.17.0.1:18099","model_id":"slow-model"}'
sleep 3; (for i in $(seq 1 24); do curl -m 30 -s -o /dev/null -X POST $BASE/v1/chat/completions \
  -H 'Content-Type: application/json' --data '{"model":"slow-model","messages":[{"role":"user","content":"x"}]}' & done)
sleep 2; curl -s $BASE/metrics | grep '^smg_http_inflight'
```

## 7. 已知边界（别当成已验证）

- **登记不是全局无损的**：`f^4` 概率丢新登记（见 §2.1），已登记的不会丢。饱和时 `_count` 偏低、
  `dropped_total` 上升，这是设计意图而不是 bug。
- 1024 槽是编译期常量，不随 `worker_connections` 伸缩；需要更大表要改 `INFLIGHT_SLOTS`。
- 年龄按"墙钟" `ngx.now()` 算，系统时钟被 NTP 往回拨会让年龄偏大（`age` 已对负值饱和为 0，
  不会渲染负样本）。Rust 用单调 `Instant`，无此敏感面。
- 亚秒桶恒为 0 是桶沿用的直接后果，不是采样缺失。
- `LR_INFLIGHT_SAMPLE_SECS` 改不了已烘焙的桶阶梯（`buckets_cache`），与 duration 家族同理。
- `dropped_total` / `slots_active` 是本机加的两个 Lua 独有超集序列，Rust 侧无对应物；
  跨实现比对时只对齐 `_bucket`/`_sum`/`_count` 三个后缀。
- **测试放在契约段而不是 `e2e_stateful.py`**：年龄分布的判据要读 `/metrics` 的精确样本行、要控制
  采样间隔与 mock 延迟，这些能力契约段已经有（`metrics_check.py` / `histogram_check.py` /
  `mock_llm_worker.py` 的 `LATENCY_MS`），而 `e2e_stateful.py` 的 fixture 是两 worker + 默认 20 s
  采样——一条 6 s 慢请求根本等不到 tick。跨进程语义改用四 worker 派生 conf 就地覆盖。
- 不变量判定只用 `metrics_check.py hist=…`（按家族名精确匹配 + `_count` 对齐 +Inf），没有复用
  `histogram_check.py`：它的第二个参数是"指标名子串"，传 `inflight_request_age` 能过，但同一段里
  已经有一条 `unique/parseable` 全量判定，多跑一个脚本只增加噪音。

## 8. 本改动的代码树（供上层文档引用）

本节数字（契约 841 / 0 / 2、`inflight_age` 段 32 项、`== summary: 19 passed, 0 failed, 0 skipped ==`）
对应这一棵树，门禁权威日志 `/data/tmp/lr-gates/gates-inflight-auth2.log`（21:22:06 起跑，串行独占）：

```
router.lua            9d8901937b7e033bdeaa0db7210708fc   （顶部注释债 + finish_request 注销）
observability.lua     f928d19a9fb761176ce51bf56bb5fbdb
init.lua              7898c7f677355cf36e2f9b382969c9f3
test/test_lua_router.sh 4b0e304eabc8f0ab8cb814174ab3dea4
test/conf/nginx-lua-router.conf fc85a0279313b3a3d6056cd868c714c5
conf/nginx.conf.template / conf/lua-router.conf  各自 +2 行 env 声明
```

`router.lua` 的 md5 已经从旧稳定树的 `8000cfb6…` 变了（本次动了顶部注释与 `finish_request`），
所以 README / feature-gap / verification-final 头部那句「三份文档同源于 `8000cfb6…`」在本轮之后
不再准确。本文件不动那三处头部（同一时间窗内 `service_discovery.lua`、`e2e_discovery_dp.py` 也被
其它改动触碰过，稳定树指针归上层统一改写），只在 §6 的复现命令里给出可自证的方式。
