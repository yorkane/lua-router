# lua-router fleet 部署记录（2026-10-01）

两个实例的部署与验证记录：21.k:8801（验证环境，21.254.220.248）与 235.t:8800（生产，10.252.25.235）。
「部署明细」「访问路径」「网络事实」几节只针对 21.k；235.t 见文末对应小节。

## 结论

lua-router 已部署在 21.k（gpu-pro6000-1，21.254.220.248）的 **8801** 端口，与既有 Rust 版
sglang-router-all（:8800）并行运行，互不影响。全量验证通过：8/8 worker healthy、IGW 模型路由
真实 chat 打通、Prometheus 指标增长、admin UI 200。

## 访问路径

- **边缘入口（推荐）**：https://8801-248.ai-t.wtvdev.com/ → 统一入口 10.252.25.252 → 21.254.220.248:8801，
  经 authz 登录墙。满足信任边界红线（网关层零鉴权，必须在 authz 之后）。
- 21.k 本机：http://127.0.0.1:8801
- **不要用 10.252.25.21:8801**——21.k 没有这个地址（box 记录里的旧信息）；业务 IP 是 21.254.220.248。

## 网络事实（2026-10-01 实测）

- 从 10.252.25.x 网段到 21.254.220.248：**只放行 22/ICMP**，所有业务口（80/443/8800/8801…）入向
  SYN 被丢。21.k 主机层无过滤（iptables INPUT ACCEPT、firewalld inactive、nft 仅 docker 规则），
  阻塞点在主机之外（交换机 ACL/安全组）。8800 同样如此，非本次部署引入。
- 因此统一入口 10.252.25.252 → 21.k 的反代通路是独立放行的（用户侧可达已验证）。
- 备用路径：SSH 隧道 `ssh -L 8801:127.0.0.1:8801 21.k` 后访问 http://127.0.0.1:8801。

## 部署明细

| 项 | 值 |
|---|---|
| 容器 | lua-router-8801，host 网络，unless-stopped |
| 编排 | /data1/app/lua-router-8801/docker-compose.yml |
| 镜像 | lua-router:8801-20261001-1（= ACR pub/lua-router:20261001-5 = 235.t 生产 lua-router:8800-20261001-5，ID 77cddc1c5a17） |
| 镜像分发 | 21.k 不通 /nas2，走 ACR push/pull（78.7MB） |
| 指标 | :29001（旧 8801 惯例口；8800 的 29000 不动） |
| 配置持久化 | /data1/app/lua-router-8801/config/runtime.json |
| 种子 worker | 8012（qwen3.8-27b-w8a16）+ 8021-8027（pennyroyal，q38fn-kv8 / q38fn / Q38-Flash-Next / qwen38-flashnext-orca-nvfp4），只填部署时刻确认监听的实例 |
| 服务发现 | watcher 三源：TARGETS 空、DOCKER=1、PROC_SCAN=1 |
| 策略 | cache_aware（threshold 0.2 / abs 32 / rel 1.5），IGW 开 |

### watcher 噪声治理（与 235.t 的差异）

SMG_WATCHER_DENY_PORT = 22,80,111,443,3000,5432,9080,9091,9092,9100,9180,9443,9912,11022,14389,15012,2379,2380,42209

- 80/443/9080/9180/9443/9091 = authz/apisix 边缘（会代理 /v1/*，不 deny 会被误注册成 worker）
- 15012 = gpustack 内嵌 istio pilot-discovery gRPC（accept 后 RST）
- 3000/9092/9100/9912 = grafana/prometheus/node-exporter/llm-watcher-metrics

SMG_WATCHER_CONTAINER_IPS=0：docker 发现分支不过 DENY_PORT（deny 只在 proc 扫描分支生效，见
`watcher/discover.lua` 的 `collect`——拆分前那是 `watcher.lua` 里的 proc 扫描分支），会探测容器
EXPOSE 端口；21.k 所有 LLM 服务都有宿主映射口，关掉无损。

## 已知事项

1. **探针 error 噪声未根治**：docker logs 仍每 ~16s 一行 `recv() failed (104: Connection reset by peer),
   context: ngx.timer`。实测全机只有 111（rpcbind）与 15012（pilot-discovery）accept 后 RST，两者均在
   deny 名单；lo 与 docker bridge 的 tcpdump 抓不到对应 RST，conntrack 事件未命中。功能零影响
   （8/8 healthy、转发正常），后续可用 iptables LOG 规则或 strace nginx worker 0 定位。
2. worker 8010/10045/8812-8814 当前未监听，watcher 会在其恢复监听后自动入池。

## 验证记录（2026-10-01）

- GET /health → OK；GET /workers → 8/8 healthy；/a/ → 200（管理台规范入口）；/u/ → 200
  （原版 webui）；/_ui/config/policy → cache_aware 链正常
  （口径 2026-10-05：页面入口是 /a/ 与 /u/；旧页面入口 /_ui/admin/、/_ui 由 conf 各 302
  过去，/_ui/* 的精确 API 别名——config / logs / stats / props——照旧 200）
  （口径 2026-10-08 admin 迁根，现役：管理台入口是 /（站点根）、/u/ 不变；旧 /a、/a/
  各 302 到 /；/_ui/* 全部取消、落 404 sink；数据面在根：/config /logs /stats /props）
- POST /v1/chat/completions（model=q38fn-kv8）→ 200，usage 与 smg_router_tokens_total 对账一致
  （prompt=14 / completion=16 / reasoning=17）
- 边缘入口 https://8801-248.ai-t.wtvdev.com/a/ → 200（再验旧入口 /_ui/admin/ 应回 302）

## 回滚

```bash
ssh 21.k 'cd /data1/app/lua-router-8801 && docker compose down'   # 完全移除
# 8800 的 Rust 版全程未动，无级联影响
```

## 升级到 lua-router:8801-20261001-2（2026-10-01 22:3x）

镜像换成含「虚拟模型多绑定 + 每服务并发/功率上限」的那版。回滚到旧版：

`bash
ssh 21.k 'cd /data1/app/lua-router-8801 && sed -i "s#8801-20261001-2#8801-20261001-1#" docker-compose.yml && docker compose up -d'
`

compose 追加了 GPU 负载通道（DCGM exporter 在本机 9400，Prometheus 在 9092；当时的
`SMG_LOAD_POWER_QUERY` 行已随功率通道于 2026-10-09 移除，不再需要配）：

```
SMG_LOAD_SOURCE: "prom"
SMG_LOAD_PROM_URL: "http://127.0.0.1:9092"
SMG_LOAD_PROM_QUERY: "max by (Hostname) (DCGM_FI_DEV_GPU_UTIL)"
SMG_LOAD_INTERVAL_SECS: "10"
SMG_LOAD_STALE_SECS: "30"
```

**负载与利用率查询必须带 instance**：只写 by (Hostname) 时采样侧拿到的是机器名
gpu-pro6000-1，而 21.k 的 worker 全部注册为 127.0.0.1:8012 这类 IP，两侧命名对不上，
lr_gpu_load_util_unmatched_total 会稳定增长而 lr_gpu_load_util_workers 恒为 0。加 instance
之后两者被判定为同一台机器并折叠，读数才落得到池成员上；`SMG_LOAD_UTIL_QUERY` 还必须
保留 `gpu` 标签（`max by (Hostname,instance,gpu) (DCGM_FI_DEV_GPU_UTIL)`），聚合掉它八台就共用一个数。

### 真机验证结论

- 功率通道（**历史记录，功率通道已 2026-10-09 移除**）：8/8 worker 采到真实瓦数
  （lr_gpu_load_power_watts = 96.46，与 DCGM 原始值
  一致），unmatched 归零。八个 worker 读数相同——功率是**整机最热卡**口径，共享是预期行为
  （正是它零区分度、后来被逐卡利用率取代的原因）。
- 虚拟模型多绑定：mixed-route 绑 8025/Q38-Flash-Next 与
  8021/qwen38-flashnext-orca-nvfp4 两个**不同上游的不同模型**，请求按绑定名转发并返回
  对应模型；only-orca 单候选同样正确。两条都是 apply 后**要等一拍**再发第一个请求，
  热配置是异步生效的。
- 并发上限：给 8026 配 max_concurrency=1，并发压上去之后
  smg_worker_capacity_excluded_total{reason="concurrency"} 真实增长，流量迁到 8025/8027，
  而 8026 本身仍留在池中——上限是选路信号而不是健康信号，不摘 worker。
- 功率上限（**⚠️ 旧口径历史记录，已被 2026-10-06 的 `max_gpu_util`（GPU 利用率上限）取代**）：
  给 8025 配 max_power_w=50（实测 96W）后
  smg_worker_capacity_excluded_total{reason="power"} 增长，该 worker 被跳过、请求仍成功。
  判定现在读的是**逐卡利用率**，功率整条链已于 2026-10-09 整体移除（用户裁定）；本条与下面两段
  功率段落保留为当时（2026-10-01）记录的事实，现行口径见文末〈2026-10-06 容量新口径部署提示〉与
  [gap-worker-caps.md](gap-worker-caps.md)。
- 验证完已把两个 worker 的上限与全部虚拟模型配置清回（workers with caps: 0 / 8，
  health OK，推理 200）。

### 亲和被上限打断（决定性验证，2026-10-01 23:0x）

上一条「并发上限」只证明了排除计数会涨，**没有直接证明亲和被打断**。补做了这个实验，
取证用上游自己的 `sglang:num_requests_total{is_streaming="false"}` 计数（网关日志行不带落点字段，
靠它才能确凿知道请求去了哪台上）：

1. 同一前缀连发 4 次 → 全部落在 8026，亲和建立（Q38-Flash-Next 有 8025/8026/8027 三实例，
   策略 cache_aware）。
2. 给 8026 配 `max_concurrency=1`，然后**真并发**发 8 个同前缀请求（max_tokens 拉到 600
   让它们在飞时间足够长）：

   ```text
   在飞分布: 8025=1, 8026=1, 8027=6
   上游计数:  8026 +1, 8027 +6
   smg_worker_capacity_excluded_total{reason="concurrency"}: 3 -> 10
   8 个请求全部 200，无一失败
   ```

   **8026 只接了 1 个（正好等于上限），第 2 个起被排除，流量迁到 8027** —— 亲和确实被打断。

3. 解除上限后用**新前缀**发 6 个 → 8026 +6、8027 +0，8026 立即重新可选。

两个必须记下的判定经验：

- **串行发请求测不出这件事**。第一轮用串行连发 6 个测，8026 delta=6、8027 delta=0，
  看着像「上限没生效」；实际是串行下 inflight 早已归零，压根到不了 `inflight >= cap`。
  排除判据比较的是**当前在飞数**，要验证必须让并发真的堆上去。
- **解除上限后原前缀不会立刻回切**。亲和树的租约仍指向 8027，同前缀匹配率超阈值所以稳定命中它；
  回切要等前缀失配（新会话）。这是 cache_aware 的既有语义，与容量上限无关，
  别误判成「上限没摘干净」。
### 功率上限的真机形态（2026-10-01 23:1x）

> ⚠️ 旧口径历史记录：功率上限（`max_power_w`）已于 2026-10-06 被 `max_gpu_util`（GPU 利用率上限）取代——
> 判定改读逐卡利用率，功率通道已于 2026-10-09 整体移除（用户裁定）。以下保留为当时（2026-10-01）记录的事实，
> 现行口径见文末〈2026-10-06 容量新口径部署提示〉与 [gap-worker-caps.md](gap-worker-caps.md)。

**这台机器上功率是整机共享读数**（8/8 worker 的 lr_gpu_load_power_watts 完全相同，95.982W），
所以给单个 worker 配 max_power_w 会连带排除同机全部实例——这不是 bug，是「最热卡口径」的
必然结果，也正是该口径在单卡隔离部署（CUDA_VISIBLE_DEVICES 级）下才有区分度的原因。
真机上因此只能验「全池被功率排除」这一形态：

- 给 Q38 的三个实例都配 max_power_w=50（实测 95.98W）→ 请求回 503，且错误信息把原因说清楚：
  "No available workers (3 at their configured concurrency/power cap)"，
  code=no_available_workers。这与熔断导致的 "all circuits open" 是**可区分**的，
  排障时能一眼看出是容量上限而不是实例故障。
- smg_worker_capacity_excluded_total{reason="power"} 同步增长。
- 上限清回 0 后立刻恢复（workers with caps: 0 / 8，推理 200）。

**不能在这台机器上验证的**：「功率超限只迁走这一台、流量落到同机另一台」——共享读数下不成立。
要验那条语义需要一台多机部署或做了卡级隔离的机器；e2e_caps 用 mock 做了这一形态的覆盖
（功率超限 → 迁到另一 worker、读数缺失 → 不排除），真机这边只能给出共享口径的证据。

### 清限的一个操作坑

> ⚠️ 旧口径历史记录：功率上限（`max_power_w`）已于 2026-10-06 被 `max_gpu_util`（GPU 利用率上限）取代——
> 判定改读逐卡利用率，功率通道已于 2026-10-09 整体移除（用户裁定）。以下保留为当时（2026-10-01）记录的事实，
> 现行口径见文末〈2026-10-06 容量新口径部署提示〉与 [gap-worker-caps.md](gap-worker-caps.md)。

> 本段「PUT 写 0 = 清回不限」是**当时的清除拼法**，已随功率上限退役；现行清除哨兵见文末：
> 并发两档写 0 即清除，利用率档写 0 是**最严档**、清除要写负数或删键。

PUT max_power_w=0 / max_concurrency=0 是「清回不限」，但**连续对多个 worker 快速发
PUT 时，后两条可能不生效**（update 走后台队列，间隔太近会挤在一起）。表现为 /workers 里
上限仍在、请求继续 503，但单独重发一次就立刻清掉。批量清限时每条之间 sleep 1s 再复核一遍
/workers 的 max_concurrency/max_power_w 字段，别默认「202 就是已生效」。

## 生产 235.t :8800 部署 lua-router:8800-20261001-8（2026-10-01 23:5x）

把 21.k 上验证过的同一版能力推到 235.t 生产实例。compose 在 /data/app/lua-router/，
部署前镜像为 8800-20261001-7，回滚就是把它改回去再 compose up -d。

compose 本轮**只换镜像**，没有新增任何 env——功率通道（历史记录，已 2026-10-09 移除）当时未
在 235.t 启用（上游是远程的 217.t 那几个，不在这次部署范围内）。

### 部署效果：第 10 条守卫当场治好了僵尸池

/workers 从 **61 → 2**。清掉的是 59 条 router-watch 僵尸记录：模型名是 alpha / beta /
hinted 之类，端口是高位随机数，进程早已不存在（ps 查 mock_llm_worker 进程数为 0），
但 shdict 里的记录被 keep-last 宽限一直兜着。它们正是今天跑门禁时 watcher 的 proc 扫描
把测试 mock 短暂注册进生产池留下的。部署前基线快照：
/data/tmp/lr-baseline/workers-8800-before.json，部署后 workers-8800-final.json。

剩下的 2 条是真实上游：
- http://127.0.0.1:10100（discovery=dynamic，聚合网关，探针拿到 16 个模型）
- https://llm-248.ai-t.wtvdev.com（discovery=config，upstreams 声明进来）

### 验收

- GET /health → OK
- smg_worker_health 两个上游都是 1；smg_worker_cb_state 都是 0（closed）
- POST /v1/chat/completions model=q38fn → 200
- 虚拟模型多绑定：prod-mixed 绑 10100/zai/glm-5.3 与 217/q38fn 两个不同上游的不同模型，
  请求正确路由到 zai/glm-5.3 并按绑定名转发（验证后已把该虚拟模型清回，生产不留示例配置）

### 两条要记下的事实

1. **重启后 30s 内会有暂态 503**。健康巡检间隔 30s，重启后第一个周期未完成时请求会回
   503 all circuits open or unhealthy，但上游其实是好的。等一个巡检周期即恢复——
   排查时别把这个当成部署失败。
2. **10100 那个聚合网关只对部分模型名真正转发**。用 gpt-6-sol / llm-248/Q38-Flash-Next
   等名字请求它，直连与经网关都返回 "The 'gpt-6-sol' model is not supported when using
   Codex with a ChatGPT account"——直连同样报，所以是上游自身约束（该账号不支持这些模型），
   不是网关改写出的问题。它 /v1/models 广告的 16 个模型里只有一部分可实际调用。

## 生产 235.t :8800 部署 lua-router:8800-20261002-9（2026-10-02）

虚拟模型语义反转（服务入口 1 对多）+ 服务池页合并上线。compose 只换镜像，**没有新增任何
env**（功率通道当时未启用；该通道已于 2026-10-09 移除）。回滚：把 compose 镜像改回
`lua-router:8800-20261002-8`（或更早的 `8800-20261001-8`）再 compose up -d。

### 真机验证：1 对多与 context_window 统一口径

生产 `virtual_models` 部署前是空数组，所以这次可以自由构造。建了一个入口：

    {"model":"team-chat","targets":["q38fn","llm-248/Q38-Flash-Next"],"context_window":32000}

- **1 对多组内选路**：6 个请求全部 200，落点在两个**不同上游的不同实际模型**之间调度
  （4 次 Q38-Flash-Next、2 次 q38fn），正是「虚拟名是主入口、策略在组内选」的语义。
- **context_window 对下游统一**（决定性证据）【**历史记录，该行为已于 2026-10-04 废止**——
  当时网关会把 `context_window` 写进 `max_tokens` 钳制下游；现行口径是 `context_window` 仅为对外声明的
  上下文总窗口，网关不改写任何输出预算，详见 [gap-virtual-models.md](gap-virtual-models.md) §4】：
  把入口的 context_window 改成 8，再用
  max_tokens=999999 请求，三次全部 `finish_reason=length` 且恰好输出 8 token
  —— 无论落到组内哪台实例，钳制都是 8。这就是「对下游保持统一」：同一个入口、同一个
  上限，与选中哪个实际模型无关。改回 32000 后恢复正常。
- `/\_ui/logs` 的 `forwarded_model` 字段生效：同一个入口的行能看到各自落在哪个实际模型上
  （`model` 列是组头代表值，`forwarded_model` 是真实落点）。
- 配置回显无损：`targets` 两项与 `context_window` 原样返回，**没有长出幻影 `target`**。
- 验证完已把 `team-chat` 清回，生产不留示例配置（`virtual_models: []`，upstreams 保持
  217 那条原有声明，q38fn 推理 200）。

### 验收

health OK；2 个 worker 全部 `smg_worker_health=1`、`cb_state=0`；q38fn 推理 200；
管理台 / 模型管理页 / 服务池页均 200；旧的 upstreams.html 走重定向也是 200（不 404）。

### 又一次踩到：重启后需等一个巡检周期

`SMG_HEALTH_CHECK_INTERVAL_SECS=30` + `health_success_threshold=2`，所以重启后第一个
巡检周期内请求会回 503。上游直连 health 200、熔断 closed、容器日志无 error——别把这个
当成部署失败，等约 60s 再判断。

本轮没有再出现 61 → 2 那种僵尸池大清理：第 10 条守卫已在 `-8` 那轮把测试 mock 残留清掉，
这次部署前后都是 2 个真实上游。

## 健康巡检优化 + 日志查询过滤（lua-router:8801-20261002-6，2026-10-02）

两个改动一起上线：

### 1. 健康巡检跳过最近有流量的服务

- registry 新增 last_active_at（K_ACTIVE 键，请求完成时 touch）
- check_all 跳过 SMG_HEALTH_CHECK_IDLE_SECS（缺省 300s）内有流量的 worker
- 流量就是健康的证明：有请求经过的 worker 不需要额外探活
- 设为 0 或负数 = 不跳过（兼容旧行为）
- 探活开关仍是 SMG_DISABLE_HEALTH_CHECK，未改动

### 2. /logs 查询过滤（旧名 /_ui/logs，2026-10-08 迁根）

带过滤参数时返回完整元信息：returned / total_matched / earliest_seq / latest_seq /
truncated_buffer / truncated_page。不带过滤参数时返回体逐字节不变。

过滤参数（全部精确匹配，非法值 400）：
model（虚拟入口名，匹配 requested_model 或 model）、forwarded_model、worker、
status（精确码或 4xx 类）、route_type、stream、since_ms/until_ms、session。

**踩过的坑**：/logs 被 conf/ui.conf 的 location 接管，调用的是 observability.handle_logs()，
不是 router.lua 的 ui_logs_handler。改 handler 没用，必须改 handle_logs()。

## 2026-10-06 容量新口径部署提示

上面「功率上限」那几段是**历史记录**。本轮（2026-10-06，HEAD `66a891f`，全量门禁锚点
`/data/tmp/lr-gates/gates-20261006-051452.log`：22/22 绿、0 skipped）每服务上限换成三个字段，
判定从「瓦特」改读「逐卡 GPU 利用率」。部署时要用的口径都收在这一节。

### 三个字段怎么配

配在 worker 记录 / `upstreams` 声明行上（`POST|PUT /workers`、`/config` 的 JSON、config 声明层三条路都通）：

| 字段 | 取值域 | 缺席时 | 清除（已配过之后） |
|---|---|---|---|
| `min_concurrency` | 整数 1..31（并发调度**下限**，绿灯线） | 等价 1 | `PUT /workers` 写 0（声明层只认 1..31，写 0 是 400） |
| `max_concurrency` | 整数 1..32（并发调度**上限**） | 不限 | 写 0（PUT 与声明层都折叠为不限） |
| `max_gpu_util` | 整数百分比 0..100（GPU 利用率**上限**） | 不限 | 写**负数**（如 -1）或删键 |

注意**声明层删键不等于当场摘门**：`upstreams` 里的 caps 只下发不清除，从声明里删掉要等下次重启
才消失；要当场摘，用 `PUT /workers/{id}` 写该档的清除哨兵（并发两档 0、利用率档 -1）。

- `max_gpu_util=0` 是**合法的最严档**，不是清除：任何新鲜读数（>=0）都判 `full`——0 的语义是
  「这台一点都不许接」。这也是它的清除哨兵跟并发两档不一样的原因：并发档 `<=0` 一律折叠成「不限」，
  利用率档只有「缺失 / 非数字 / 负数」才是「不限」。`config_store` 声明期还钉住
  `min_concurrency < max_concurrency`，写反了 400。
- `max_power_w` 已退役：声明层里还写着它的行，解析时 **warn 一次并丢弃该键**；`PUT` 带它和带任何
  未知字段一样被忽略；`GET /workers` 不再回显。老配置不用手改，它会自己变干净，但别指望改回来还生效。
- 功率链的后续（历史）：**2026-10-09 用户裁定把剩余的观测链一并移除**——`pw:` 键、
  `lr_gpu_load_power_*` 六族、`/workers` 的 `power_w` 字段、`SMG_LOAD_POWER` /
  `SMG_LOAD_POWER_KEYS` / `SMG_LOAD_POWER_QUERY` 三个 env 全部下线；当时的 compose 里的
  `SMG_LOAD_POWER_QUERY` 行现在可以直接删掉。负载只剩利用率（逐卡）与在途数两个口径。

### 读数未知 = 不排除

`gu:<worker_id>` 是 gpu_load 利用率通道写的 0..1 毫整数（带 TTL）。这条键**缺席就是未知**，未知一律
不排除——监控挂掉、Prom 查询写错、worker 自己 `/metrics` 拉不到，后果都只是「这一档闸门暂时不生效」，
绝不允许变成「这台不接活」。所以部署完先确认 `lr_gpu_load_util_workers`（有几台拿到读数）与
`lr_gpu_load_util_gpu{worker=...}` 真有值，再谈配 `max_gpu_util`；配了闸门而读数一条都没有，等于没配。

利用率三件套走 `config.lua` 装配（缺省即开）：`SMG_LOAD_UTIL_ENABLED=1`、`SMG_LOAD_UTIL_KEYS`
（空 = 内置名册，含 DCGM 真名 `dcgm_fi_dev_gpu_util`，刻意不含 KV-cache 用量名）、`SMG_LOAD_UTIL_QUERY`
（空 = `max by (Hostname,instance,gpu) (DCGM_FI_DEV_GPU_UTIL)`）。**prom 路的 `gpu` 标签必须留在 `by` 里**：
聚合掉它，同机 8 台就共用一个数，逐卡归属当场作废（2026-10-04 的 342.371 事故就是这个形状）。判断自己
是逐卡还是整机口径，看 `lr_gpu_load_util_per_card_workers` 与 `lr_gpu_load_util_fallback_total` 的差——
回退是**计数**的，不静默。两个通道（负载 / 利用率）全部搭载在 `SMG_LOAD_SOURCE` 上，它设成
`none` 时定时器根本不启动，其他开关设了也不会有读数。

### 选路行为，部署后该怎么验

- `full`（在飞 >= `max_concurrency` **或** 新鲜 `gu:` >= `max_gpu_util`）在候选集装配时**硬排除**，
  cache_aware 亲和命中也迁走；不摘 worker、不改健康、不进熔断。
- 有 `idle`（未 full 且在飞 < `min_concurrency`）时只把 idle 子集交给策略，`busy` 让位
  （`smg_worker_capacity_preferred_idle_total`）；全池没有 idle 时黄灯继续接活直到触自己的上限。
  让位是**裁剪**不是排除：显式 `x-smg-target-worker` 钉人时 `busy` 仍在名单里（`why.stepped_aside`），
  但 `full` 也救不回来。
- **全池都到顶**（每台都 `full`、候选为空）答 **429**：`error.code=no_available_workers`、
  `error.type=Too Many Requests`、message 精确为「No available workers (N at their concurrency or
  GPU-util limit)」。熔断 / 不健康 / 组不服务仍是 **503** 原句（all circuits open or unhealthy、
  healthy engines serve none of the mapped models）。排障时两条处置相反：429 抬上限或减并发，
  503 查实例本身。上面 2026-10-01 那几段记录的 503 是**当时**的口径，别照抄到新版排障。
- 排除计数器只有两个 reason：`smg_worker_capacity_excluded_total{reason="concurrency_max"}` 与
  `{reason="gpu_util"}`。上面历史段落里的 `reason="concurrency"` 与 `reason="power"` 是**当时的标签名**，
  新版查不到它们——瓦特那一档随 `max_power_w` 一起退场，不再有对应的排除计数。

验的时候按老规矩：串行发请求测不出上限（在飞早归零），必须真并发把在飞堆起来；批量清限时每条 PUT
之间 sleep 1s 并复核 `/workers`，别把 202 当已生效。

### GPU 标注与 21.k 现状

21.k 实测：8 个 sglang 实例的**功率读数完全相同**（整机最热卡口径，8 台同值约 271 W），也就是说
功率这个读数额外区分不了任何两个实例；能区分的是 DCGM 的 `DCGM_FI_DEV_GPU_UTIL`，它带
`gpu="0".."7"` 标签，逐卡一条序列。本轮 watcher 会从**容器名**解析卡号（`gpu_from_name`：
`…-gpu0`..`…-gpu7`），proc 一路发现的候选再补一次 socket→pid→`/proc` 命令行解析
（`gpu_from_cmdline` 读 `--device-id N`，其次 `CUDA_VISIBLE_DEVICES=N`），只在原值为空时填、已有值绝不
覆盖，落进台账与记录 `labels.gpu`，于是 `/workers` 的 `metadata.gpu` 有值、管理台在实例名后亮出 GPU 徽章，
`gu:` 的逐卡归属也同时有了地址。它是**纯 label**：不进排除、不进摘除、不进探针、不进宽限，任何一步失败
一律降级为「没有标注」，服务发现本身一个字节都不受影响。21.k 的名册：
`qwen38-27b-dflash-tgt-gpu0` 在 8012、`pennyroyal-orca-gpu1` 在 8021、`q38fn-pennyroyal-gpu2..7` 在
8022–8027。容器名不带 `gpuN` 且命令行也没有卡号的部署，逐卡归属只能靠
`lr_gpu_load_util_fallback_total` 显形（覆盖率看 `lr_gpu_load_util_per_card_workers` 与它的差）。

最后一条纪律：这些改动只在 **21.k:8802（测试）** 上验，8801 是生产，未经用户明确要求不得更新。

> 另记一条已知残留：`observability` 的 gauge 没有 TTL 也没有删除原语，worker 被删掉之后它的
> `lr_gpu_load_util_gpu{worker=...}` 会永久留在 `/metrics`
> （本轮在 8802 实测到已删 mock 18301–18303 的序列仍在）。登记与后续修法见
> [gap-worker-caps.md](gap-worker-caps.md) §11 第 10 条。
