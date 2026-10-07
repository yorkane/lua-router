# 21.k 的 watcher 探测降噪清单（doc/gap-cpu-idle-burn.md 交付项 4）

日期：2026-10-07　对象：21.k（gpu-pro6000-1，128 核）上跑
`SMG_WATCHER_ENABLED=1 SMG_WATCHER_PROC_SCAN=1` 的 lua-router 实例（8801/8802）。

## 问题

进程内 watcher 每 15s 一轮，把 `/proc/net/tcp` + `/proc/net/tcp6` 里所有 LISTEN 端口当作
候选，每个候选最多 6 次串行 GET（`/v1/models`、`/server_info`、`/get_server_info`、
`/props`、`/metrics`、`/health`），单次超时由 `SMG_WATCHER_PROBE_TIMEOUT_SECS` 决定（缺省
4s）。21.k 实测有 65 个 LISTEN 端口，而内置 `watcher/env.lua:DEFAULT_DENY_PORTS` 只有 23
条、与本机实际监听只交叠 8 条，于是每轮要拨 40-60 个不可能成为 worker 的端口。这是单
worker 进程里的常驻成本，与业务流量无关（同机 up 46h 的 8801 实测 0.85 核、inflight 0）。

## 每次部署前重跑一遍核对，别把这份清单当真理

    ssh 21.k "cat /proc/net/tcp /proc/net/tcp6 | awk '\\$4==\\"0A\\"{print \\$2}' \\
      | sed 's/.*://' | sort -u | while read h; do printf '%d\\n' 0x\\$h; done | sort -n"

## 2026-10-07 实测的 LISTEN 端口与归类

| 端口 | 归属 | 处置 |
|---|---|---|
| 22 25 53 111 135 139 445 631 1433 | sshd / smtp / dns / rpcbind / rpc / netbios / smb / cups / mssql | deny（缺省表已覆盖大部分） |
| 80 443 3000 8080 8888 9876 | apisix 前端、容器 https、web、dcgm-exporter 之类 | deny；8080/3000 是推理服务常用口，deny 前先确认这台机上它们确实是网关 |
| 2379 2380 | apisix-etcd | deny |
| 6443 18443 | k3s / 容器 api | deny（6443 缺省表已含） |
| 7889 7890 | iw-proxy | deny |
| 8800 8801 8802 | 同机的其它 lua-router / llm-router 实例 | **必须 deny**：它们也答 `/v1/models`，会被注册成 worker；`self_ports` 只覆盖本实例自己的两个监听口 |
| 8876 18977 29876 29881-29886 | 实验/调试残留口 | deny（本次实验容器已清；端口再出现说明有人又在起实验） |
| 9080 9090 9091 9092 9115 9180 9100 | apisix / prometheus / prometheus-alert / prometheus(9092) / cadvisor / grafana / node-exporter | deny（9100 缺省表已含） |
| 10150 10151 | gpustack-worker | deny |
| 15000 15004 15010 15012 15020 15021 15051 15090 | 宿主上的非池内推理/评测服务 | deny |
| 11211 | memcached | 缺省表已含 |
| 8012 8021 8022 8023 8024 8025 8026 8027 | 真 worker（q38fn-pennyroyal / pennyroyal-orca 的 sglang 实例） | **绝对不要 deny** |

## 建议写进 compose 的值

缺省表是**并集**语义（`discover.lua:743-749`：操作员写的 deny 与缺省表取并集；只有显式
给了 `SMG_WATCHER_ALLOW_PORT` 时缺省表才不参与），所以只需要补本机特有的那些：

    SMG_WATCHER_ENABLED: "1"
    SMG_WATCHER_DOCKER: "1"
    SMG_WATCHER_PROC_SCAN: "1"
    SMG_WATCHER_DENY_PORT: >-
      25,80,443,2379,2380,3000,7889,7890,8080,8800,8801,8802,8876,8888,
      9080,9090,9091,9092,9115,9180,9876,10150,10151,15000,15004,15010,
      15012,15020,15021,15051,15090,18443,18977,29876,29881,29882,29883,
      29884,29885,29886
    SMG_WATCHER_MAX_CANDIDATES: "24"
    SMG_WATCHER_PASS_BUDGET_SECS: "4"
    SMG_WATCHER_PROBE_TIMEOUT_SECS: "2"

## 为什么三条预算比 deny 清单更重要

deny 清单是白名单式的手工劳动：它会腐烂（这台机一周起三个临时服务），漏一条就又是一轮
6 次串行 GET。预算是结构性的上界：

- `SMG_WATCHER_MAX_CANDIDATES`（缺省 32）限制一轮探测多少个**新**候选。台账里的活体
  worker 永远全探（它们排在探测队列的**豁免前缀**里，条数与 deadline 都切不到），所以这条不会让
  摘除判定饿着 ——   被切掉的恰好是「不可能成为 worker 的那批噪音」，正是 deny 清单该干而干不全的部分。
- `SMG_WATCHER_PASS_BUDGET_SECS`（缺省 5，被 `interval_secs` 封顶）限制一轮的墙钟。
  没有它，一个连上但不答的端口就是 6×4s；40 个这样的端口能让一轮跑满整个 interval，
  于是 15s 的定时器实际变成连续占用 —— 这就是 8801 的形状。
- `SMG_WATCHER_PROBE_TIMEOUT_SECS` 从 4s 降到 2s：真 worker 的 `/v1/models` 在同一台机
  上是毫秒级（本实验对 mock 与真 sglang 都实测 <50ms），4s 只帮到噪音。

被预算切掉的候选**不算探针失败**：`live.lua` 交给它 `probe skipped: pass budget` 这条
理由，`probe.lua:probe_verdict` 把它归到「与对方无关」那一档 —— 既不计 `probe_fails`
滞回、也不推进 `missing_since` 宽限。否则网关自己被限流就会把健康的 worker 摘干净。
盯 `lr_watch_probe_budget_skips_total`：它持续上涨说明该补 deny 清单了。

## 更彻底的档位（worker 池本来就静态播种时）

21.k 的 8 台 worker 全部由 `SMG_WORKER_URLS` 播种，watcher 的自动发现对它们只做两件事：
补 `labels.gpu`，以及在容器消失时摘除。关掉进程扫描能立刻拿回那部分核：

    SMG_WATCHER_PROC_SCAN: "0"     # 保留 docker 源（读容器元数据，不拨端口）
    SMG_WATCHER_DOCKER: "1"

本实验的 W0（`SMG_WATCHER_ENABLED=0`）测到严格 0.000 核、RSS 斜率减半，也就是说在这台
机上 watcher 是烧核的主要来源之一。代价是失去端口级自动发现，需要操作员维护
`SMG_WORKER_URLS`。
