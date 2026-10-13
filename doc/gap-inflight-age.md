# 在途请求年龄采样 `smg_http_inflight_request_age_count`

日期：2026-10-06 · 状态：已落地，无后继裁定推翻（现行口径就是本文）。

实现落点：`observability.lua`（登记表 + 采样 + 渲染）、`init.lua`（采样定时器 + log 阶段兜底）、
`router/reqlog.lua`（`finish_request` 注销）。契约段 `inflight_age`。

## 1. 这条家族在报什么

它报的是**抓取那一刻**在途请求的年龄分布，不是历史请求的耗时分布：每轮采样把登记表里每个在途请求
按年龄归桶，然后**覆盖**写入（快照语义，非累加），请求结束后对应桶会回落到 0。因此 `rate()` /
`increase()` 对它无意义，只能读 instantaneous 值；`_sum / _count` 是「当前在途请求的平均年龄」，
不是分位数的替代物。

导出形状是**累积直方图**（`le` 桶 + `_sum` + `_count`），桶沿用 `SMG_PROMETHEUS_DURATION_BUCKETS`
（默认 20 档 0.001…240）。选它的理由：现渲染器只对 histogram 类型做前缀和与 `histogram_quantile`，
累积 + `_sum`/`_count` 能被 Grafana 的 heatmap/percentile 面板直接消费，而且同一块面板能并排画
「在途年龄」与「已完成时长」。副作用是亚秒桶恒为 0，读图按「有限桶里最早出现的非零档」理解。

`_count` 的含义是**样本数**：每个 tick 每个在途请求各计 1 次，不是「已完成请求数」。
空集时首个 tick 起渲染全 0；`LR_INFLIGHT_SAMPLE_SECS=0` 关闭时整个家族缺席（不造零）。

## 2. 登记表形状与有界近似

nginx 是多进程：请求由任意 worker 接管，登记表必须是共享的；没有 `Drop`，注销挂在 `finish_request`
与 log 阶段两处。表是 `lr_stats` 里的**定长 1024 槽**（`i|0` … `i|1023`，key 数量恒定，约 120 KB / 5m），
分配用 `add()`（只在空槽写入 → 跨进程原子，无 read-modify-write 窗口），值 = `"<start_ms>|<6hex token>"`，带 TTL。

采样成本被表大小固定住：每 tick 一次 1024 次 `get`，occupancy 仪表同样一次全表扫描。

**丢失是可见且有界的**：`add()` 从随机槽起步，连续探测 4 个槽（`INFLIGHT_PROBES`），全被占则放弃登记，
并 `smg_http_inflight_request_age_dropped_total += 1`（Lua 独有超集，让丢样本不静默）。
负载因子 `f` 下丢失概率约 `f^4`：

| 并发 | f | 单请求丢失概率 |
|---|---|---|
| 64 | 0.0625 | 0.000015 |
| 256 | 0.25 | 0.39% |
| 512 | 0.5 | 6.25% |
| 1024 | 1.0 | 表满，全部丢失并计入 dropped |

饱和信号看 `smg_http_inflight_request_age_slots_active / 1024`，这条仪表是实时扫描槽表得来的，
不可能和直方图口径打架。饱和时 `_count` 偏低、`dropped_total` 上升是设计意图，不是 bug。

`add()` 返回 `forcible=true`（dict 满、nginx 挤掉了别人的 key）时必须撤销：登记表的全部意义就是不与
在线契约争抢，所以只有 `get(key) == token` 才 `delete`——槽位已被别人合法占用时我们的写入早已失效，
不能删别人的活请求。这条分支不可通过 HTTP 触发，由语法门 + 评审覆盖。

## 3. 生命周期与防泄漏

| 阶段 | 动作 |
|---|---|
| `record_http_request`（与 `smg_http_requests_total`、`inflight_add(1)` 同处） | 登记。位置先于 auth 与并发上限，因此 401/429 也有年龄 |
| `finish_request`（`limit().release()` 之后） | 注销 |
| `log_by_lua`（`init.lua` `on_log`） | 再注销一次：客户端中途消失时 `finish_request` 不会执行，log 是唯一还会跑的阶段 |
| 兜底 | 槽位 TTL = `LR_INFLIGHT_TTL_SECS`（默认 3600）：连 log 都没跑到时，最迟 TTL 后不再被采样 |

`inflight_untrack()` 幂等：先清 `ngx.ctx` 里的 key/token 再删表；表里已经是别人的 token 时不动手。

采样器**只跑在 worker 0**（表是共享的，N 个采样者会把 `_count` 乘以 N）。契约段用 `sed` 派生一份
四 worker 的 conf（并先断言派生成功，防止测试 conf 漂移后静默退回单进程），用 `ps` 数 worker 进程数，
并发请求散在四个 VM 里登记、只有 worker 0 采样，`_count` 达标且 `slots_active == smg_http_inflight_requests`
才算通过——这正是「任意进程写、单进程读」的证据。

## 4. 开关

| 名字 | 默认 | 作用 |
|---|---|---|
| `LR_INFLIGHT_SAMPLE_SECS` | 20 | 采样间隔；**0 = 整个 tracker 关闭**：不起定时器、不登记槽位，且 `prometheus_text()` 按家族名前缀过滤，三个 age 序列全部不渲染 |
| `LR_INFLIGHT_TTL_SECS` | 3600 | 槽位 TTL，即泄漏上界 |

两个名字在 `init_by_lua` 里 fork 之前抓取（`init.lua` `wire_inflight_tracker` → `observability.configure_inflight`），
`conf/nginx.conf.template`、`conf/lua-router.conf`、`test/conf/nginx-lua-router.conf` 三处都登记了 `env`。
**没有新增 shared dict**（槽位借用 `lr_stats`）。

关闭态是「显式过滤」而不是「表恰好空」：`lr_stats` 里可能留着开关拨动之前的快照与未过期槽位，
所以渲染路径按前缀 `smg_http_inflight_request_age` 过滤。这条过滤由契约里的探针 `/probe/inflight-off`
钉住：手动塞一份 age 直方图与一个已占用槽位后原地渲染 `/metrics`，关闭态两条都不出现且 duration 家族不受影响，
开启态两条都出现（否则负例可能只是探针自己坏了）。探针读写都恢复原值。

## 5. 已知边界（别当成已验证）

- 登记不是全局无损的：`f^4` 概率丢新登记（§2），已登记不会丢。
- 1024 槽是编译期常量，不随 `worker_connections` 伸缩；要更大表得改 `INFLIGHT_SLOTS`。
- 年龄按墙钟 `ngx.now()` 算，系统时钟被 NTP 往回拨会让年龄偏大（年龄对负值饱和为 0，不会渲染负样本）。
- 亚秒桶恒为 0 是桶沿用的直接后果，不是采样缺失。`LR_INFLIGHT_SAMPLE_SECS` 改不了已烘焙的桶阶梯
  （`buckets_cache`），与 duration 家族同理。
- `dropped_total` / `slots_active` 是 Lua 独有超集序列；跨实现比对时只对齐 `_bucket`/`_sum`/`_count`。
- 测试放在契约段而不是 `e2e_stateful.py`：判据要读 `/metrics` 的精确样本行、要控制采样间隔与 mock 延迟，
  这些能力契约段已有；`e2e_stateful.py` 的 fixture 是两 worker + 默认 20s 采样，一条 6s 慢请求等不到 tick。
- 不变量判定只用 `metrics_check.py hist=…`（按家族名精确匹配 + `_count` 对齐 +Inf）。

## 6. 复现

```bash
# 单段契约：直方图不变量、桶对齐、并发登记、跨进程采样、打断回收、TTL 自愈、关闭即缺席、关闭过滤探针
TEST_ONLY=inflight_age bash test/test_lua_router.sh
```
