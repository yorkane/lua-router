# lua-router 部署记录：21.k:8801（2026-10-01）

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
