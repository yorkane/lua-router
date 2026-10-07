# lua-router 单 worker 空载烧核 + 内存无界增长

日期：2026-10-07　对象：21.k 上 `lua-router-8801`（46h）与 `lua-router-8802`（30h）
仓库：`/home/aigc/ChatGPT/lua-router`　镜像：ACR `pub/lua-router:8801-20261005-6` / `:8802-20261006-1`

## 结论

不是流量压出来的，是**单 worker 进程里 LuaJIT 私有堆无界增长**，再由周期性定时任务把整棵累积结构反复全量遍历。

两个实例都是 `worker_processes 1`（PIDs=2 的签名），被 `docker-entrypoint.sh:22-24` 因为
`SMG_POLICY=cache_aware` 钉死——亲和树按进程私有，多开进程就变成 N 份各自残缺的树。所以这个核既是
全部业务流量的转发预算，也是全部周期任务的地盘；一旦堆涨上去，周期任务就把这唯一的核常年吃满。

## 现象与证据

### 1. 现状

| 容器 | CPU | RSS | PIDs | 起来多久 | 业务流量 |
|---|---|---|---|---|---|
| lua-router-8802 | 100.4% | 2.67 GiB | 2 | 30h | inflight 1-13，20s 级长流 |
| lua-router-8801 | 100.1%（重启前） | 1.86 GiB | 2 | 46h | **inflight 0**，46h 仅 6736 请求 |
| 235.t :8800 | 0.07% | 40 MiB | 2 | 45h | 无 |
| 同镜像同配置新建实例 | 0.00% | 20 MiB | 2 | 1min | 无 |

8801 是最干净的对照：**几乎没有流量，却照样烧 0.85 核**。

### 2. 内存长在 Lua 堆，不在共享字典

`smaps_rollup`（8801 worker）：

```
Rss:             1926992 kB
Private_Dirty:   1920540 kB
Shared_Dirty:       1756 kB     <- lr_workers/lr_policy/lr_stats 等共享字典合计
Anonymous:       1915744 kB
rw-p mappings:      2557
```

99.9% 是私有匿名内存。8802 的映射数 5021 恰是 8801（2557）的 2 倍，RSS 也是 2 倍关系 → 与堆里节点数线性相关。

### 3. 是连续饱和，不是定时尖峰

0.25s 分辨率采 300s：mean 0.82 核，78% 采样点 >0.8，最小 0.00。请求到达前的 200ms 窗口就已经是
`pre200ms=1.00`；`/health` 返回 2 字节也要 0.5-1.0s 核——因为核已被常驻任务占死，请求只是在排队。

### 4. 同样流量在健康实例上完全不涨（Phase 1 对照）

实验组 T 打流 38658 请求（8 个 model、stream=true），对照组 C 不打流，各约 40 分钟：

| | idle cores | RSS |
|---|---|---|
| T（38658 请求） | 0.001-0.006 | 28.6-29.9 MB |
| C（无流量） | 0.001-0.004 | 23.1-24.4 MB |

**流量形态不是成因。** 另在隔离容器里用 3KB 真实长 prompt 打 6000 请求，树只涨了 3 MB。

### 5. 重启即刻复位（因果闭环）

在 `inflight=0`、`worker_inflight=0` 的前提下重启 8801：

| | CPU | RSS | heap 映射数 | `/health` 墙钟 | idle cores |
|---|---|---|---|---|---|
| 重启前 | 100.11% | 1.86 GiB | 2566 | 0.5-1.0s（纯 CPU） | 0.85 |
| 重启后 | 0.03% | 25.6 MiB | 38 | 0.0003s | 0.015 |

RSS 不再是运行时长的函数，而是累积状态的函数；一重启就清空。

## 根因（两条线）

### CPU 线：周期任务遍历无界累积结构

单 worker 下所有周期任务与全部转发抢同一个核。已实测排除：

- `limit.lua:112-163` 10ms 轮询——`SMG_MAX_CONCURRENT_REQUESTS` 未设 = −1 = 限流器整体关闭（`config.lua:314`）
- `logstore.lua:567-597` / `ui.lua:288-302` SSE 轮询——`docker logs | grep -cE 'logs/stream'` = 0
- `mesh/sync.lua` 2s 同步——`SMG_ENABLE_MESH` 未设，`init.lua:307-310` 整块不启动

剩下的两个常驻来源：

1. **watcher pass（15s）**：21.k 有 **128 个 LISTEN 端口**（`/proc/net/tcp` 111 + `tcp6` 17），
   而 `SMG_WATCHER_DENY_PORT` 只覆盖约 39 个 → 每 tick 约 70-90 个候选，每个候选最多 6 次串行 GET
   （`watcher/probe.lua:36,65,75,76,77,116`），8 路并发（`watcher/live.lua:84-122`），单次超时 4s
   （`watcher/env.lua:441`）。20h 内 4172 条 `recv() failed (104: Connection reset by peer), context: ngx.timer`。
2. **policy 淘汰（120s）**：`policy.lua:816` `for _, inst in pairs(_M.instances)` 遍历**所有**策略实例，
   每实例一次全树 DFS 淘汰（`tree.lua:479-503`）+ `save_snapshot` 把整棵树 `cjson.encode` 成最多 3MB 字符串
   （`cache_aware.lua:254-267`）→ 峰值内存尖峰，且耗时随累积状态线性增长。

### 内存线：四个无界容器

| # | 容器 | 无界维度 | 清理路径 | file:line |
|---|---|---|---|---|
| S1 | cache_aware 亲和树 | **历史上每一个不同的 prompt 前缀**（每个叶子存整段剩余文本） | `evict_tenant_by_size` 阈值是**每租户字符数**且默认 67108864（`config.lua:186`）→ 实际永不触发；trie 长出来后 `detach_if_empty` 也不缩 | `tree.lua:166-257`、`tree.lua:431`、`config.lua:186` |
| S2 | `_M.instances` | 每个 `<policy>:<入口名>` 一条，每条背后一整棵 S1 的树 | 只在 `for_model` 的 `has_workers==false` 分支删（`policy.lua:395-404`）；`candidates.lua:56-66` 的 profile-forced 路径直接 `policy_mod.new` **绕过回收** → 只增不减 | `policy.lua:70/372/498` |
| S3 | observability 键 | 请求派生的 `model=` / `worker=` label | **全仓无 delete**（`:delete(` 只出现在 `logstore.lua:38` 与 `inflight.lua:120/145`）；`/metrics` 与 `publish_gauges` 每次 `get_keys(0)` 全表扫 | `observability.lua:160-220`、`policy.lua:672` |
| S4 | `gpu_load/seams.lua:336` `warned_at` | `class|<url>`，按失败过的目标数增长 | 只写不清，唯一清理是整表 `reset_warn_dedup()` | 同左 |

外加 S7：`registry/records.lua:540-545` 的删除清单**漏了 `act:`（`loads.lua:229`，无 TTL）与 `gu:`（`loads.lua:459`）**，
worker 轮换后旧键永久留在 `lr_workers`。

## 修复项（按性价比排序）

1. **给亲和树加真正的内存上界**（治本）：`max_tree_size` 现在是"每租户字符数"且默认 67,108,864，等于永不触发。
   改为同时限制**总节点数**与**总字符数**（新增 `SMG_MAX_TREE_NODES`），淘汰做成**增量**（每 tick 固定预算，
   避免单 tick 全树 DFS 卡死单核）；`save_snapshot` 改边走边估、超阈值立刻放弃，不要先 encode 整棵树再判长度。
2. **`_M.instances` 增加回收**：加最后使用时间，`sweep_standalone` 遍历时顺带回收超 TTL 且无对应 worker 的实例；
   forced 路径创建的实例纳入同一回收。保留 `has_workers==false` 既有语义，不改路由行为。
3. **observability 键基数封顶**：`model=` 维度归一到 `OTHER`（与 `observability.lua:477-488` 入口族已有归一风格一致），
   `get_keys(0)` 换成带上限的扫描。
4. **watcher 探测预算**：21.k 完整 deny 清单写进 doc（不要写死代码）；探测超时/串行 GET 数做成可配，
   让每 15s 一轮有硬预算上限。
5. **可观测性**：新增 `smg_cache_aware_tree_nodes` / `smg_cache_aware_tree_chars` / `smg_policy_instances`，
   下次能一眼看出"是不是又长大了"，不用再靠 smaps_rollup 猜。

## 运维处置

- **8801**：先在确认 `inflight=0` 且 `worker_inflight=0` 后重启止血（46h → 0.03% CPU /
  25.6 MiB / 8/8 健康），再随修复上线部署 `pub/lua-router:8801-20261007-2`，
  实测 idle 0.005-0.016 核、RSS 27-50 MB、8/8 健康，真实转发（非流式 + SSE + usage 计量）通过。
- **8802**：带真实流量，用 `docker compose up -d --timeout 60` 优雅重建（该实例未设
  `worker_shutdown_timeout`，在途 SSE 有 60s 跑完），部署 `pub/lua-router:8802-20261007-1`
  （与 8801 同一份代码、同一 digest）。100.35% CPU / 3.28 GiB / 5770 映射 → 0.00% CPU /
  34.7 MiB；8/8 健康后真实转发 200、`[DONE]` 正常收尾。420 个带唯一 nonce 的长请求压测
  全成功，核占用从 0.019 衰减到 0.002，RSS 30 → 36 MB。
- **复发判据**：新 gauge 已随本次部署上线。`smg_cache_aware_tree_nodes` 持续上升即代表 S1 仍在漏；
  实测 420 个长请求只让树长到个位数量级，说明这台机器上亲和树未必是内存增长的主导项，
  盯 `smg_cache_aware_tree_nodes` / `smg_model_label_cardinality` / `lr_watch_probe_budget_skips_total`
  一两天即可分辨是哪一项在长。重启仍是最快的临时缓解。
- 21.k 的 `kcompactd0/1` 各占约 80% 已跑 7 天，是这台机另一件事（内存回收压力），与本问题无关，不要混。

## 复现与验证位置

- 生产快照与中间产物：21.k `/data/tmp/lr21x/`（`out/phase1_*.jsonl` 是 T/C 对照原始数据）
- 重启前后对照脚本：`/data/tmp/lr21x/{before,restart,post,verify}.sh`
- 之前的网关天花板与后端容量报告：`doc/backend-ceiling-cpu.md`
