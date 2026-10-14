# 21.k lua-router-8800 CPU 排查

取证日期：2026-10-14；研究取证阶段保持只读，同日按用户授权先验证 8802，再向 8800 上线 SSE 断连修复。

## 修复上线与验收

- 代码提交 `fb6b0d0`，发布镜像 `pub/lua-router:20261014-fb6b0d0`，image ID `sha256:47b546c2c7aa…`，ACR digest `sha256:249bfcb5ad03…`。
- 修正两个真实 handler：检查受保护调用的成功状态和 print/flush 的真实返回值；先发送响应头，健康空闲连接可继续收到心跳；sleep 的正常无返回值不视为失败。未引入双实例、未改推理转发/输出预算/配置鉴权。
- full 锚点：run `20261014-041805-2711586-7f11-b3f6d5`，fingerprint `bc9d845d931b…`，22 pass，无 fail/skip/missing，`full_anchor_eligible=true`。原始报告 `/data/tmp/lr-gates/runs/20261014-041805-2711586-7f11-b3f6d5/report.json`，单元日志含 observability 57/0。
- 21.k:8802 先升级并验收：13/13 RST/FIN 日志 SSE 请求完成收尾，持续日志流心跳正常，3 个真实小推理请求均成功，CPU 没有随断连积累升高。HTTP/1.0 和 HTTP/1.1 的两条 SSE 路径均通过，模型流跨 30 秒心跳保持正常。报告 `/data/tmp/lr-sse-fix-1014/remote-probe/8802-approved.json` 与 `protocol-8802.json`。
- 然后将相同 image ID 替换 21.k:8800，SIGQUIT 退出窗口最多 60 秒。配置镜像摘要前后保持相同，sqlite backend=1，8/8 上游健康，模型/API/UI 和 Basic Auth 前置否决验收正常。
- 8800 上的生产复测为 CLEAN：13/13 RST/FIN 流收尾，持续健康流收到 3 次 ping，3 个小 chat 均成功；35 秒观察窗末 CPU 约 3.9%，初次替换后容器内存约 42MiB。更新前 CPU 约 100%、内存约 2.45GiB。CPU/RSS 会随正常推理流量变化，不把短窗读数当容量承诺。
- 备份（位于 21.k）：8802 `/data1/app/lua-router-8802/backup-sse-20261014-041953/`；8800 `/data1/app/lua-router-8800/backup-sse-20261014-042906/`。包含原 compose、镜像身份、runtime 镜像与 revision sidecar、通过 SQLite backup API 取得的一致性 DB；旧镜像 `20261012-69b5d53` 留在盘上。

本轮只替换上述两个指定实例，其余实例未升级。生产运行后的断连复测和 CPU/RSS 观察记录见 `/data/tmp/lr-sse-fix-1014/remote-probe/8800-approved.json`。

## 第二轮确认：根因在管理日志 SSE 的断连清理

进一步取调用栈、寄存器与请求元数据后，原先的“响应输出链热点”已收窄为：**`/logs/stream` 的客户端断开后，服务端 SSE 协程没有退出，继续向失败连接追加日志和 flush 节点；chunked busy 链无法回收，每次追加都要遍历长链，拖满唯一 nginx worker。**

这是管理日志流的生命周期缺陷，不能归因于模型推理流量或亲和树。

证据链：

1. 原镜像 `69b5d53` 的 20 秒 DWARF 复测，约 95.65% self 仍在同一链尾指令。调用点第五参数经生产 ELF 反汇编确认是 `ngx_http_chunked_filter_module`，对应响应 chunked 过滤器的 `ctx->busy`。`objdump` 展示的邻近导出名 `ngx_http_write_filter+...` 不能用来给 stripped 局部函数命名：该导出符号的大小不覆盖实际调用点。
2. 在热点寄存器中的 request/context 关联上，只读取元数据，不附着或暂停进程。五个采样请求的 URI 全部为 `/logs/stream`；对应连接 error 位已置 1，busy 链各读取到 10,000 个节点仍未到尾。链头 chunked framing buffer 仍有 3/5 字节未消费；读取范围内约 53%–80% 节点是零字节 flush。采样是并发、非原子快照；10,000 是下限，不是全链精确长度，也没有据此断言整链是否存在环。
3. `observability/logstore.lua` 的 `handle_logs_stream` 使用 `local ok = pcall(ngx.print, ...)`，只检查调用有没有抛异常；`pcall(ngx.flush, true)` 同样只检查第一个返回值。OpenResty 写失败通常返回 `nil, error`，不会抛 Lua 异常，因此 `pcall` 返回 `true, nil, error`，旧代码继续每 0.5 秒执行循环。`ui.lua` 的 `models_sse` 有同类错误，但本次五个热点样本属于日志流。
4. 原事故镜像上的最小 RST 断连 A/B：13 条客户端断连后，旧循环在约 20 秒内新增 537 圈；检查 `pcall` 状态与 print/flush 的真实返回值后，只运行 26 圈便全部退出。该近似实验确认错误处理与协程泄漏；其短窗口 CPU 很低，不能单独替代生产长链与热点证据。
5. 再直接加载从原镜像复制的真实 `logstore.lua` handler（原文件 SHA-256 `b87cb35c…`），只注入独立日志字典与配置测试依赖，以 1000 条合成日志/秒、13 条收到首帧后 RST 的客户端做 A/B。旧实现约 19 秒耗 11.63 CPU 秒，最后一段约占 0.82 核，13 条请求没有进入 log phase，失败 print 达 105,064 次；临时修正实现约 18 秒仅耗 0.147 CPU 秒，13 条全部进入 log phase，失败写计数停止在 13 次，后续轮询/输出计数不再增长。该对照闭合了“断连仍循环 → 失败输出积累 → CPU 逐步升高”的因果。修正实验同时先发送响应头，避免健康连接在尚无正文时被 `nothing to flush` 误关闭；没有改生产文件。

正常推理形状的隔离实验（13 并发、大量帧、快读/停读及 chunked 开关）没有复现同样的超线性成本。这个阴性结果与实际热点属于管理日志 SSE 相容；它不证明所有推理负载都没有输出开销。

修复应正确检查 print/flush 的第二返回值，同时覆盖 logs SSE 和 models SSE，并验证健康空闲连接不会因初始化的 `nothing to flush` 被误关。`ngx.sleep` 正常完成可以没有返回值，不能机械地把同一判据应用于 sleep。第一步是修生命周期；不通过攒帧、改输出预算或更换调度策略来处理本案。

双实例方案与一致性边界见 [design-dual-openresty.md](design-dual-openresty.md)。双实例未实施；研究阶段的临时原型验证后，SSE 修复按本文上线节部署。

## 首轮热点取证

生产镜像 `pub/lua-router:20261012-69b5d53`，容器 `lua-router-8800`。唯一 nginx worker PID 4131441 持续占满一核。78 秒 cgroup CPU 增量 77.63 秒（0.995 核），没有 CPU quota 或 throttling；采样期约 99.4% 为用户态。因此这是单线程处理瓶颈，并非容器配额不足。

使用临时解包的 perf（不安装软件包、不调整系统参数）对该 worker 采样：99 Hz、226.576 秒、22,147 个 cycles 样本、丢失样本为零。

| 热点 | Self | Children |
|---|---:|---:|
| nginx `ngx_chain_update_chains` | 97.27% | 97.58% |
| `memcpy` | 0.41% | 0.43% |

反汇编注释进一步定位：该函数内部约 99.32% 样本落在 `mov 0x8(%rax),%rax`，随后跳回循环继续读取链表的 next 指针；对应向 busy 缓冲链尾追加输出前的链尾遍历。**当前 CPU 的直接来源是 nginx 响应缓冲链尾遍历**。Lua 亲和树、JSON 解析和后台发现不是本次采样的主要 CPU 热点。

首轮仅凭 perf 还不能确定忙链积累的触发条件；第二轮通过请求路径、连接错误位与 handler 错误处理收窄为上述日志 SSE 生命周期缺陷。没有通过重启或加 worker 做归因实验。

## 业务与影响

54 秒指标差分：81 个流式 chat 请求（1.50/s）；累计 prompt 5,041,719 token，其中 cached 4,270,336（84.7%）；completion 50,059（927/s）。按窗口完成请求计算平均输入约 62k token，但 token/s 并不等于网关处理字节速率或 CPU 成本。

同机同镜像空载 8802 CPU 约 4.8–5.9%；生产 8800 持续约 100%。这支持问题与有业务时的输出处理相关；不是严格同负载 A/B。

本机直连探测 `/health` 返回 200 但耗时 1.468 秒，`/metrics` 在 3 秒限时内未返回，说明单 worker 事件循环拥堵影响管理与健康响应。

亲和树读数为 6 棵、224 个节点、约 97 万字符，不是此前百万节点堆积事故的规模。

## 独立发现：在途计数漏减

同一快照 HTTP inflight=472，而上游 active 请求合计=13、年龄槽位=13、活动连接=61。两次快照严格满足 inflight=requests_total-responses_total，因此 472 是累计登记残差，不能称为 472 条活跃推理流。

在 69b5d53 的 `router.handle` 中，`record_http_request` 先登记 +1，随后 `admin_auth.guard_klib` 可通过 `ngx.exit(401)` 早退，绕过 `reqlog.finish_request` 的 -1。`init.on_log` 清理年龄槽位和 worker load，但未补 HTTP inflight 的 -1。这是源码确认的计数漏减路径；历史 472 的全部构成未逐条对账。此问题与本次 CPU 热点分开处理。

## 原始后续方向与本轮进展

已核实 OpenResty 1.31.1.1 / ngx_lua 0.10.31rc5，历史 cosocket 共用 busy 链问题的修复已经在该版中，不能套用为本案根因。保留流式字节与延迟契约，优先修日志流断连退出，再用管理面独立实例隔离长期连接；不直接复制两套完整 router。

## 证据

- 本机运行证据：`/data/tmp/lr8800-cpu-21k-20261014/`。
- 本机 perf 原始数据与解读：`/data/tmp/lr8800-cpu-20261014/perf/`（`perf8800.data`、`perf_header.txt`、`perf_report_head.txt`、`perf_annotate_full.txt`）。
- 本机流量与独立审查：`/data/tmp/lr-cpu-20261014/traffic/report.md`、`/data/tmp/lr-cpu-20261014/review/report.md`。
- 21.k 原始 perf：`/data/tmp/lr8800-cpu-21k-20261014/perf8800.data`、`perf_report_head.txt`；同目录 `nginx.bin` 用于符号解析。
- 第二轮本机证据：`/data/tmp/lr-chain-1014/livecaller/`、`chain_meta.jsonl`、`request_meta.jsonl`、`uri_meta.jsonl`、`chain_regs3.txt`，以及 `source/`、`repro/`、`dual/`、`review/` 报告。元数据读取使用 `process_vm_readv`，没有 ptrace 附着、停止或写进程内存，也不交付请求正文。
- 真实 handler A/B：`/data/tmp/lr-chain-1014/root-abort/` 的 `run.py`、原版/修正 `logstore` 副本、`result-old.json`、`result-fixed.json`。验证以这些原始数据和本文汇总为准；旁支研究中未有原始证据支持的 GDB/reload/链长推算等描述未采纳。

上述取证阶段未修改生产代码；后续已按授权完成 full 门禁、8802 验证与 8800 发布，版本与备份身份见上线节。
## 235.t 部署

- 时间：2026-10-14 16:0x UTC，本机 235.t，生产容器 `lua-router-8800`（compose `/data/app/lua-router/docker-compose.yml`）。
- 镜像：`pub/lua-router:20261011-fc037af` → `pub/lua-router:20261014-fb6b0d0`（SSE 断连清理修复版）。compose 仅改 `image:` 一行，备份 `docker-compose.yml.bak-20261014-sse`，diff 确认单行变更。旧镜像 20261011-fc037af 保留未删。
- 容器状态：新容器 `de7f927663ee` Up (healthy)，`restart=unless-stopped` 不变。
- health：`GET /health` 连续 5 次 200，耗时 0.7–16 ms。
- 指标：`:29000/metrics` 有 16 条 `lr_` 指标；`lr_config_store_backend{backend="sqlite"}=1`（sqlite 后端为权威源）。
- 清单：`GET /v1/models` 正常返回 1 条（`startlux-decision-35b-a3b`，`owned_by=lua-router`）。`/workers` 显示 1 个健康 worker（127.0.0.1:18490，router-watch 发现）。
- SSE 断连验证：管理面未配置 `SMG_ADMIN_AUTH_PASS`，`GET /logs/stream` 匿名 200。两轮 `curl -N -m 3` 与 `-m 8` 拉流后主动断开，均正常退出。断连后 `docker stats --no-stream` 连续 3 次采样（间隔 5s）：0.03% / 0.10% / 0.02%；断连前基线采样 0.02% / 2.24% / 0.08%。无 nginx worker 持续 100% 现象。
- 冒烟：最小 chat completion（model=`startlux-decision-35b-a3b`，`max_tokens=8`）返回 200，正常 8 token 续写，309.6 tok/s decode。

## 217.t 部署

- 时间：2026-10-14 16:03 UTC，217.t（10.252.25.217），生产容器 `lua-router-8800`。
- 部署方式说明：该机 `/data/app/lua-router/` 原本**没有 compose 文件**（旧容器是 docker run 起的，目录里只有 config/）。本次按旧容器 `docker inspect` 逐项等价生成 `/data/app/lua-router/docker-compose.yml`（host 网络、restart=unless-stopped、双 bind：config→/data/lua-router:rw 与 docker.sock:ro、全量 env 31 项、shm 64MB、无 healthcheck——与线上完全一致），原 inspect 快照存 `inspect-8800-20261011-89f0ad0.json` 作备份。备份文件名按要求 `docker-compose.yml.bak-20261014-sse` 因无原文件可备份而不适用，以 inspect 快照 + 旧镜像保留代替回滚材料；回滚 = 把 image 行改回 `8800-20261011-89f0ad0` 后 `docker compose up -d`。
- 镜像：`pub/lua-router:8800-20261011-89f0ad0` → `pub/lua-router:20261014-fb6b0d0`（ACR 直接 pull 成功，digest sha256:249bfcb5…，已登录凭据在 ~/.docker/config.json）。旧镜像保留未删。
- 容器状态：新容器 Up，`restart=unless-stopped`；`docker compose ls` 已登记 /data/app/lua-router/docker-compose.yml。
- health：`GET /health` 200；`GET /v1/models` 正常（`Ornith-1.5-35B-A3B`，`owned_by=lua-router`，`created=0`）。`/workers` 显示 4 个 worker 全部 `is_healthy=true`（18490 startlux、18492 orca、8200/8201 Ornith）。
- 指标：`:29000/metrics` 有 16-17 条 `lr_` 指标（SMG_METRICS_PORT=29000 在 compose env 内）。
- SSE 断连验证：`SMG_ADMIN_AUTH_PASS` 未配置，`GET /logs/stream` 匿名 200。`curl -m 3` 拉流后断开，容器日志可见对应 `writev() failed (32: Broken pipe)` 收尾行后连接结束；断连后 `docker stats --no-stream` 连续 3 次（间隔 5s）：**0.30% / 0.03% / 0.35%**，全机 loadavg 0.37。无持续高 CPU。
- 冒烟：`POST /v1/chat/completions`（Ornith-1.5-35B-A3B，max_tokens=16）200 正常续写，309 tok/s decode；上游 8200 直连对照一致。
- 503 说明：刚替换的 16:03:48–16:04:31 窗口有 9 条 503（no_available_workers，来自 235 的 OpenAI/JS 客户端），为容器重启瞬间 worker 探针尚未恢复所致；16:04:38 起恢复 200，最近 3 分钟窗口 503 计数为 0、chat 200 计 13 条。属预期冷启动，非新缺陷。
- 未触碰：`lua-router-8802`（该机当前无此容器在运行，仅 /data/app 下有目录）、llm-router、strata-*、ninfer-* 等一切其它容器。

