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

SMG_WATCHER_CONTAINER_IPS=0：docker 发现分支不过 DENY_PORT（deny 只在 proc 扫描分支生效，
watcher.lua:1729 附近），会探测容器 EXPOSE 端口；21.k 所有 LLM 服务都有宿主映射口，关掉无损。

## 已知事项

1. **探针 error 噪声未根治**：docker logs 仍每 ~16s 一行 `recv() failed (104: Connection reset by peer),
   context: ngx.timer`。实测全机只有 111（rpcbind）与 15012（pilot-discovery）accept 后 RST，两者均在
   deny 名单；lo 与 docker bridge 的 tcpdump 抓不到对应 RST，conntrack 事件未命中。功能零影响
   （8/8 healthy、转发正常），后续可用 iptables LOG 规则或 strace nginx worker 0 定位。
2. worker 8010/10045/8812-8814 当前未监听，watcher 会在其恢复监听后自动入池。

## 验证记录（2026-10-01）

- GET /health → OK；GET /workers → 8/8 healthy；/_ui/admin/ → 200；/_ui/config/policy → cache_aware 链正常
- POST /v1/chat/completions（model=q38fn-kv8）→ 200，usage 与 smg_router_tokens_total 对账一致
  （prompt=14 / completion=16 / reasoning=17）
- 边缘入口 https://8801-248.ai-t.wtvdev.com/_ui/admin/ → 200

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

compose 追加了功率通道（DCGM exporter 在本机 9400，Prometheus 在 9092）：

```
SMG_LOAD_SOURCE: "prom"
SMG_LOAD_PROM_URL: "http://127.0.0.1:9092"
SMG_LOAD_PROM_QUERY: "max by (Hostname) (DCGM_FI_DEV_GPU_UTIL)"
SMG_LOAD_POWER_QUERY: "max by (Hostname,instance) (DCGM_FI_DEV_POWER_USAGE)"
SMG_LOAD_INTERVAL_SECS: "10"
SMG_LOAD_STALE_SECS: "30"
```

**功率查询必须带 instance**：只写 by (Hostname) 时采样侧拿到的是机器名
gpu-pro6000-1，而 21.k 的 worker 全部注册为 127.0.0.1:8012 这类 IP，两侧命名对不上，
lr_gpu_load_power_unmatched_total 会稳定增长而 power_workers 恒为 0。加 instance
之后两者被判定为同一台机器并折叠，读数才落得到池成员上。

### 真机验证结论

- 功率通道：8/8 worker 采到真实瓦数（lr_gpu_load_power_watts = 96.46，与 DCGM 原始值
  一致），unmatched 归零。八个 worker 读数相同——功率是**整机最热卡**口径，共享是预期行为。
- 虚拟模型多绑定：mixed-route 绑 8025/Q38-Flash-Next 与
  8021/qwen38-flashnext-orca-nvfp4 两个**不同上游的不同模型**，请求按绑定名转发并返回
  对应模型；only-orca 单候选同样正确。两条都是 apply 后**要等一拍**再发第一个请求，
  热配置是异步生效的。
- 并发上限：给 8026 配 max_concurrency=1，并发压上去之后
  smg_worker_capacity_excluded_total{reason="concurrency"} 真实增长，流量迁到 8025/8027，
  而 8026 本身仍留在池中——上限是选路信号而不是健康信号，不摘 worker。
- 功率上限：给 8025 配 max_power_w=50（实测 96W）后
  smg_worker_capacity_excluded_total{reason="power"} 增长，该 worker 被跳过、请求仍成功。
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

PUT max_power_w=0 / max_concurrency=0 是「清回不限」，但**连续对多个 worker 快速发
PUT 时，后两条可能不生效**（update 走后台队列，间隔太近会挤在一起）。表现为 /workers 里
上限仍在、请求继续 503，但单独重发一次就立刻清掉。批量清限时每条之间 sleep 1s 再复核一遍
/workers 的 max_concurrency/max_power_w 字段，别默认「202 就是已生效」。

## 生产 235.t :8800 部署 lua-router:8800-20261001-8（2026-10-01 23:5x）

把 21.k 上验证过的同一版能力推到 235.t 生产实例。compose 在 /data/app/lua-router/，
部署前镜像为 8800-20261001-7，回滚就是把它改回去再 compose up -d。

compose 本轮**只换镜像**，没有新增任何 env——功率通道在 235.t 未启用（上游是远程的
217.t 那几个，功率口径要重新评估，不在这次部署范围内）。

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

