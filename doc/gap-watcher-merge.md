# 内建 watcher：发现、注册与探针分档处置

实现：`watcher.lua` facade；逻辑在 [env.lua](../lualib/resty/luarouter/watcher/env.lua)（配置）、[ledger.lua](../lualib/resty/luarouter/watcher/ledger.lua)（台账）、[probe.lua](../lualib/resty/luarouter/watcher/probe.lua)（探针）、[discover.lua](../lualib/resty/luarouter/watcher/discover.lua)（发现）、[reconcile.lua](../lualib/resty/luarouter/watcher/reconcile.lua)（协调）、[live.lua](../lualib/resty/luarouter/watcher/live.lua)（定时器）、[modelmap.lua](../lualib/resty/luarouter/watcher/modelmap.lua)（改名表）。接线在 [init.lua](../lualib/resty/luarouter/init.lua)（worker 0）和 [router.lua](../lualib/resty/luarouter/router.lua)（`/model-map`）。三份 conf 登记 env 并声明 `lr_watch 64k`。单测 [test_watcher.lua](../test/unit/test_watcher.lua)，e2e [e2e_watcher.py](../test/integration/e2e_watcher.py)。计数以同一版本门禁日志为准，本文不钉数字。

watcher 在 router 进程内直接调用 `registry.add/remove`，状态放 shdict `lr_watch`。发现源 `TARGETS`、Docker、proc scan 默认均关闭；`SMG_WATCHER_ENABLED` 是总闸。worker 0 按周期 reconcile。

## 1. 十条守卫

守卫编号 1-9 保持原号：①自端口及 router 指纹阻止自注册；②只接受 `/v1/models` 中有 `data[].id` 的端点；③首次 reconcile 快照既有池为 protected；④仅删除台账 owned 项，并复核 id 仍指向该 URL；⑤发现源不再报告时走 remove-grace；⑥按健康同模型覆盖保护最后一台，keep-last grace 为 0 时永久保护、负值关闭；⑦台账有而池中无的 pending add 超时释放；⑧每轮用池中实际 id 刷新台账，重启后重新发现；⑨只读 HTTP、Docker 容器列表与 proc 文件，不控制服务、不读 GPU、不启子进程。

活动探针（真实生成 token）未实现，因此无法发现“模型列表正常但不能生成”的僵尸服务。

### 1.1 第 10 条守卫：探针分档处置（2026-10-01 裁定立，2026-10-09 `9bf3c07` 改 reject 档后果）

**reject 三档**：发现源本轮仍报告该 URL，探针拿到 HTTP 回答，但模型列表没有 `data[].id`、命中 router 自指纹或超过 `max_models`。缺省**临时禁用保行**：registry 行和健康状态不清，写 `td:` 临时键，候选装配排除；恢复轮清键立即回池，不进保险丝计数。键 TTL 为 3 × interval。设 `SMG_WATCHER_PROBE_TEMP_DISABLE=0` 才退回当轮删行。

**传输层未知**：连接失败、超时、TLS 失败或 TCP 后无 HTTP 状态行。连续失败达到 `SMG_WATCHER_PROBE_FAILURES`（默认 2）才摘除；成功清零。摘除后下一轮按正常准入重新注册，健康位及负载读数重置，须重新经过健康成功阈值才接流。

**不触发摘除**：网关缺 fetch（`no probe transport`）与 `require_health` 未通过都保留原行、不计连续失败。探针根本没运行、发现源不再报告该 URL 时仍走 remove-grace 与 keep-last。

`SMG_WATCHER_PROBE_FUSE` 默认开启：同一轮探针摘除数超过 owned 总数一半且至少 2 条时，该轮只告警不摘；不影响 grace 删除。设为 0 关闭。reject 禁用与 fuse、`SMG_WATCHER_ALLOW_REMOVE=false` 正交；后者只阻止删除，reject 仍会临时禁用。`allow_remove=false` 时传输失败仅首轮告警，恢复后重新告警。模型卡片或虚拟入口声明 `disabled=true` 时，该已注册行走 reconcile 的共同 `release()` 出口物理摘除（禁用即摘，2026-10-09 裁定）；判据只有 config_store 的 `model_is_disabled` 一份。protected 项与 config_store 声明 upstream 由 `is_config_member` 保护，不由 watcher 摘除。

`/health` 和 `/metrics` 同时 5xx 的判据属于传输层未知：metrics 探测失败可能使引擎识别退回 openai，故须累计失败，不能当轮定罪。只代理 `/v1` 的裸 OpenAI 接口可设 `SMG_WATCHER_ALLOW_MODELS_ONLY=1` 放行注册准入。本节分档话术是全仓唯一口径：AGENTS.md 硬规则 4、[agent-handover.md](agent-handover.md)〈30 秒速览〉的探针条、`watcher.lua` 文件头注释与日志文案必须与之同义；改探针理由字符串时同步更新本节与单测用例名。

## 2. env

下表是 `watcher/env.lua:new_config` 缺省；三份 conf 的 nginx env 白名单必须同步。

| env 后缀 | 默认 | 语义 |
|---|---:|---|
| `ENABLED` | off | 总闸 |
| `TARGETS` | 空 | 远程 URL 清单 |
| `DOCKER` / `PROC_SCAN` | off / off | 本机发现源，需显式开启 |
| `CONTAINER_IPS` | on | 仅 Docker 发现使用 |
| `DOCKER_SOCKET` | `/var/run/docker.sock` | Docker socket |
| `INTERVAL_SECS` / `PROBE_TIMEOUT_SECS` | 15 / 4 | 周期与单探针超时，均至少 1 秒 |
| `MAX_CANDIDATES` | 32 | 每轮新候选上限；已在台账的活体 worker 不受限，始终全探以免摘除判定饿死；0 不限 |
| `PASS_BUDGET_SECS` | 5 | 探针轮墙钟预算，最大钳到 interval；预算耗尽而跳过的候选不记作失败、不惩罚 worker；0 不限 |
| `PROBE_FANOUT` | 8 | 探针协程并发，钳到 1..32 |
| `MAX_MODELS` | 8 | 每端点模型数上限；0 关闭 |
| `REQUIRE_HEALTH` / `ALLOW_MODELS_ONLY` | off / off | 注册准入控制 |
| `ALLOW_REMOVE` | on | off 时探针结论不删除，只首轮警告；reject 临时禁用照常 |
| `PROBE_FAILURES` / `PROBE_FUSE` / `PROBE_TEMP_DISABLE` | 2 / on / on | 传输失败连续阈值、单轮保险丝、reject 保行开关 |
| `REMOVE_GRACE_SECS` / `KEEP_LAST_GRACE_SECS` | 300 / 1800 | 发现源消失宽限；最后实例保护宽限，0 永久保护 |
| `KEEP_LAST` | on | false 将 keep-last grace 设为 -1 |
| `ADD_CONFIRM_TIMEOUT_SECS` | 180 | pending add 超时 |
| `SHORT_MODEL_NAMES` | off | `/models/x.gguf` 简写为 x |
| `MODEL_MAP` | 空 | `orig:new,...`，兼容读取 `LMR_MODEL_MAP` |
| `EXCLUDE` | 空 | Lua pattern；无效 pattern 退为字面子串 |
| `ALLOW_PORT` / `DENY_PORT` | 空 | 端口或范围清单 |

allow/deny 规则：allow 清单为空时，deny 为操作员清单与 `DEFAULT_DENY_PORTS` 的并集；allow 非空时只采用显式 deny；显式 allow 端口优先于两份 deny。它们只决定是否拨号，不改变探针分类或台账；allow/deny 只作用于 proc 扫描分支，docker 发现分支不过这道名单（`discover.lua` 的 `collect`）。内置 deny 已含不提供 HTTP 的 qdrant gRPC 端口 6334；不要在此复制机器专属旧端口快照。

## 3. /model-map

挂 router 主端口，受管理面 Basic Auth 控制（见 [gap-admin-auth.md](gap-admin-auth.md) §6）。支持 JSON 对象、`{"map": object}`、`a:b,c:d`、`{"map":"a:b,c:d"}` 四种 body；POST 合并而非替换，空值删除映射。watcher 关闭时仍可读写映射；定时 reconcile 未运行时改名不作用于池子。

## 4. 当前限制与验证面

台账是 shdict，随 router 重启清零；`lr_workers` 也清零后由静态 worker 配置与重新发现恢复。设计按一 URL 一模型，不展开 DP rank。Docker 发现只读 `/containers/json`。候选按 `record.model_id` 过滤，不需要 mixed-model 警告。`disable_health_check` 来自健康探针是否可用，健康参数仍由 router 全局配置。

单测覆盖 env 默认与钳制、三源候选和端口过滤、IPv4/IPv6 与模型名解析、台账续期、九条守卫时序、探针三档、保险丝、临时禁用恢复、改名映射与坏输入。e2e 覆盖目标/proc/Docker 发现、真实注册路由、grace/keep-last、重启恢复和探针处置。以测试代码和当前门禁配置为准；具体 check 数不在本文重复。
