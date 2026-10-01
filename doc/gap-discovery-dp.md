# DP-aware 与 Kubernetes service discovery（Lua 侧实现）

对应 Rust 侧：`gateway/src/core/worker_builder.rs`（`DPAwareWorkerBuilder`）、
`gateway/src/core/worker.rs`（`BasicWorker::normalised_url`）、
`gateway/src/core/steps/worker/local/create_worker.rs`、
`gateway/src/service_discovery.rs`。

本文只写与 Rust 的差异与取舍；相同部分按“已按上述文件复刻”处理。

## 1. DP-aware（`SMG_DP_AWARE`，默认 false）

### 1.1 展开形态

一个 dp engine 在 registry 中是 **dp_size 条独立记录，url 为 `<base>@<rank>`**，与
Rust 完全一致（`format!("{}@{}", base_url, rank)`）。选择/健康/负载/熔断全部按 rank
独立，因此 cache_aware / manual / ring 这类按 url 建 tenant 的策略天然把 rank 当成
不同候选，不需要额外键。

`/workers` 形状对齐 Rust：rank 就是一条普通 WorkerInfo，`url` 带 `@rank`；Rust 侧
`worker_to_info` 把 `id` 设成 url，Lua 侧 `id` 仍是 sha224 UUID（既有差异，见
doc/gap-core.md）。rank 信息额外出现在 `metadata.dp_rank` / `metadata.dp_size`
（Rust 通过 url 后缀表达，标签里不重复）。

### 1.2 触发点

Rust 在 create_worker 的 workflow step 里展开；Lua 侧放在
`registry.discover()`（健康探测 2xx 后由 hb sweep 调用）里，`expand_dp()` 完成探测与
写库。这样做的原因：`router.lua` 由另一个 agent 持有，而展开必须发生在“worker 可达”
之后。副作用是**注册后的第一个 sweep 周期内 engine 仍是单条 base 记录**（Rust 是注册
即展开）。`SMG_HEALTH_CHECK_INTERVAL_SECS` 为默认 60 时这段窗口就是 60s。

防护：带 `dp_base_url` 的记录（已是 rank）、url 本身带 rank 后缀的记录（通过
`registry.rank_of` 判断）、以及 `dp_size` 已定的 base，都不会再展开。第三条覆盖
“rank 被 DELETE 后手工 POST 回来”的情况——它不带 dp_* 字段，若只靠字段判断会被再展
开成 `<base>@2@0..N`。

### 1.3 server_info 失败：不展开

按要求，`/server_info`（回退 `/get_server_info`）拿不到可用 `dp_size` 时**保留 base
单条记录**，不失败注册。Rust 是 step error（worker 建不出来）。实现上给了
`MAX_DP_ATTEMPTS = 20` 次重试预算（engine 冷启动期 /health 先通、/server_info 后通），
到上限后落 `dp_size = 1` 并打一条 WARN，之后不再重复探测。

### 1.4 同一 base 的健康状态：各 rank 独立

每个 rank 有自己的 `hl:/hf:/hs:/cbs:` 计数与熔断，因此同一监听地址会被探测 dp_size
次/秒。这是 Rust 的行为（rank 是独立 worker 对象），也是本功能的意义所在：DP engine
的某个 rank 可能排队严重而其他 rank 空闲，共享健康状态会把这种差别抹平。代价：
- 一个 rank 真死了不会拖累兄弟 rank（好），但 base 监听整个挂掉时 4 个 rank 要各自连
  败 3 次（`health_failure_threshold`）才全部摘掉，收敛比共享慢一个阈值宽度；
- 探测请求量 ×dp_size。默认 60s 间隔下可忽略；e2e 里用 1s 间隔才看得到。

### 1.5 转发：`data_parallel_rank` 尚未注入（已知限制）

Rust 在 `http/router.rs:575-617` 给 dp_aware worker 的请求体写入
`data_parallel_rank: <rank>`。**Lua 侧目前不注入**：写入点在 `router.lua` 的转发路径，
该文件不在本任务所有权内。

已提供纯函数 `service_discovery.inject_dp_rank(raw, record)`（顶层成员原位改写/插入，
与 `router.set_top_field` 同规则，能避开嵌套同名键、字符串内的花括号与转义），单测
`test/unit/test_service_discovery.lua` 的 `inject_dp_rank` 组覆盖。接线只需在
router.lua 改写 model 的同一处加一行：

```lua
raw_body = discovery.inject_dp_rank(raw_body, worker)[1]   -- worker 为选中记录
```

在接线之前，rank 只是**调度身份**：请求会打到正确的监听地址（`split_url` 剥后缀），
但 engine 无法区分这是发给哪个 rank 的，dp engine 会按自己的默认策略放置。因此
dp_size>1 时展开本身没有吞吐收益，只是把候选拆开了。这是必须写清楚的功能缺口。

e2e 用例 `[dp4] body injection still absent` 显式断言当前不注入，接线后把该断言改成
“值等于选中 rank”。

### 1.6 路径拼接处的 rank 剥离

`split_url` 只剥 **authority 末尾**的 `@<数字>`，因为调用方有两种形态：
`record.url .. "/metrics"`（`engine_metrics_handler`、`/v1/loads`）里 rank 不在字符
串末尾。userinfo `user:pw@host` 不受影响（`@` 后不是纯数字）。
`pool_name`/`normalize_url`/id 计算保留后缀，rank 才是不同租户。

## 2. Kubernetes discovery（`SMG_SERVICE_DISCOVERY`，默认 false）

### 2.1 poll 而不是 watch（最主要差异）

Rust 用 `kube::runtime::watcher`（长连接事件流 + 断线指数退避）。Lua 侧是定时器
轮询 list：

| | Rust | Lua |
|---|---|---|
| 机制 | watch 事件流 | `ngx.timer` 周期 list |
| 稳态开销 | 1 条长连接 | 每周期 1 次 `GET .../pods` |
| 收敛延迟 | 秒级事件 | ≤ `SMG_SERVICE_DISCOVERY_CHECK_INTERVAL_SECS`（默认 60s） |
| 断线处理 | 指数退避重建 watch | 单次失败即返回，下个周期自然重试 |
| 权限 | list + watch | 只需 list |

没有 watch 客户端（无长连接 HTTP/1.1 chunked 读取封装）是根本原因。默认 60s 直接取
Rust 自己的 `check_interval`（Rust 用同一值作 watcher 重启延迟）。

### 2.2 一次 list，不是两条 watch 流

PD 模式下 Rust 为 prefill/decode 各开一条 watch。Lua 侧一次 list 全取、在
`pod_from_api` 里按三组 selector 客户端分类；普通模式仍带 `labelSelector` 让服务端过
滤，**同时客户端再校验一遍标签**（fake API server 故意忽略 `labelSelector`，e2e 的
`pods_selector_flip` 因此只可能由客户端复检完成摘除）。

不带 `fieldSelector`（Rust 也没用），phase 判定在本地做。

### 2.3 PD worker_type 受 `SMG_GRPC` 约束（沿用既有契约）

`registry.parse_worker_type` 在 gRPC 面关闭时把 prefill/decode 判为 400，这是
`test/test_lua_router.sh` 里钉住的契约，未改动。因此 `SMG_GRPC` 关闭时，被 PD selector
命中的 pod 会**注册失败并计入 failed 指标 + WARN**，不会静默降级成 regular（Rust 会
无视 PD 直接建成 Regular，这是行为差异）。同时 `labels.worker_type` 仍写进记录，
`pd.pool_of` 读标签的那条路径保持可用。`SMG_GRPC=1` 时 prefill 连
`sglang.ai/bootstrap-port` 注解一起正常注册（e2e `[k8s-pdg]` 组）。

PD 模式的 IGW 规则照抄 `warn_if_misconfigured`：非 IGW 时 `--selector` 在 PD 模式被忽略
（`SMG_ENABLE_IGW` 打开则保留）。router pod 发现（`router_selector` / mesh 端口注解）
本模块完全未实现，属于 mesh 任务范围。

### 2.4 失败时的保守语义

- `401/403`：保留现有 worker 集合，只记 `result="failed"` + 一条 WARN（提示 RBAC list
  权限）。Rust 的 watch 崩掉后重建并重新事件回放，效果也是“不清空”。
- `500`/网络错误：同上，不清空。
- 只有 200 且带 items 的 list 才驱动增删。
- `labelSelector` 为空且 PD 选择器也为空时，`selector_matches({})` 恒 false（Rust 的
  `matches_selector` 同样对空 selector 返回 false），因此“开了 discovery 但没配
  selector”不会注册任何 pod，而不是注册全集群。
- `SMG_SERVICE_DISCOVERY=1` 但拿不到 API server（无 `KUBERNETES_SERVICE_HOST` 且未设
  `SMG_KUBE_API_SERVER`）：`init.lua` 里一条明确 WARN，discovery 保持 disabled，
  路由器照常服务。同类日志按内容去重，不会每周期刷一条。

### 2.5 指标

`observability` 已有通用 `counter/gauge` 原语，未改 observability.lua，因此
`/metrics` 里这几个族没有 `# HELP` 行（`# TYPE` 正常），这是与 Rust 的另一处差异。

- `smg_discovery_registrations_total{source="kubernetes",result="success"|"failed"}`
- `smg_discovery_deregistrations_total{source="kubernetes",reason="pod_deleted"}`
- `smg_discovery_workers_discovered{source="kubernetes"}`（gauge，被 selector 认领的
  pod 数，含未 Ready 的，与 Rust 的 tracked 集合口径一致）

Rust 还有 `smg_discovery_sync_duration_seconds` 直方图，未实现（poll 周期固定，耗时
信息价值低）。`duplicate` 这个 result 取值也未使用：registry.add 对重复 url 返回的是
成功语义的 job 记录，不会走到 failed 分支。

### 2.6 DP 与 discovery 的交叉

rank 记录继承来源标记：K8s 发现的 DP engine 展开出的 rank 带 `discovery=kubernetes`。
discovery 说的是 pod url（`http://<podIP>:<port>`，无后缀），而展开后 registry 里是
`<pod url>@<rank>`，两者字面不相等，所以对账必须按 **base url 键**
（`service_discovery.coverage_key`：rank 用 `dp_base_url`，普通记录用 `url`）：

- rank 视为“覆盖了它的 pod”，因此不会每个周期重新注册 base、删掉 rank 再展开一遍
  （不做这层会对账抖动，engine 每个周期重建、rank 健康态从 0 收敛）；
- pod 从列表消失时它的 **全部 rank 一起摘除**，不是只摘那条 pod url。

e2e 的 `[dpk8s]` 组用 `registrations_total{result="success"} == 1` 与
`deregistrations_total == 0` 钉住“注册一次、运行期间不摘”，用 pod 消失后
`>= 4` 次摘除钉住 rank 随 pod 撤收。

## 3. 配置项

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `SMG_DP_AWARE` | false | 打开 rank 展开 |
| `SMG_SERVICE_DISCOVERY` | false | 打开 K8s 轮询 |
| `SMG_SELECTOR` | 空 | 普通 worker 的 label selector（`k=v,k2=v2`） |
| `SMG_SERVICE_DISCOVERY_PORT` | 80 | pod 端口 |
| `SMG_SERVICE_DISCOVERY_NAMESPACE` | 空（全集群） | 命名空间 |
| `SMG_PREFILL_SELECTOR` / `SMG_DECODE_SELECTOR` | 空 | 任一非空即进入 PD 模式 |
| `SMG_KUBE_SA_PATH`（旧名 `SMG_KUBECONFIG`） | `/var/run/secrets/kubernetes.io/serviceaccount` | token/CA 挂载点 |
| `SMG_KUBE_API_SERVER` | 空 → 用 `KUBERNETES_SERVICE_HOST/PORT` 拼 https | 显式值允许 http（测试用） |
| `SMG_SERVICE_DISCOVERY_CHECK_INTERVAL_SECS` | 60 | 轮询周期（clamp ≥1，≤3600） |

Rust 的 `--service-discovery-port` 默认是 8000，这里按任务规定用 80；`_validate()`
会把越界端口退回 80。SA 的 `ca.crt` 未使用：走 `SMG_KUBE_API_SERVER` 的 http 覆盖时不
需要，集群内 https 目前也不校验服务端证书（与 worker 的 https 探测同一策略）。

## 4. 测试

- `test/unit/test_service_discovery.lua`：**161 项**，luajit 口径（`authz:latest`），
  覆盖 selector 解析/规范化、`@rank` 剥离（含 userinfo、IPv6、非数字尾巴）、dp_size
  解析（顶层/`server_args`/字符串/非法值）、展开决策四分支、展开请求构造、
  `inject_dp_rank`（原位改写、插入、嵌套同名、字符串内花括号与转义）、pod 过滤
  （Running/Ready/podIP/标签/bootstrap 注解/PD 分类）、期望集与 diff、pods_url 与
  labelSelector 编码、API server 解析（含 IPv6 bracket）、SA token 读取与 bearer 头、
  poll_opts 的 PD/IGW 规则、周期 clamp、DP 与 discovery 交叉时的 base 键对账。
- `test/integration/e2e_discovery_dp.py`：**68 项**，真实容器 + in-file mock（DP mock
  worker、fake K8s API server + `test/integration/fixtures/k8s/*.json` 五个 pod 列表
  fixture）。DP 组：dp_size=4 展开成 4 条 rank 候选、base 消失、全部转健康、继承
  model 与 dp_rank/dp_size 标签、id 互不相同、`/workers` 计数、rank 上推理可用、
  `/engine_metrics` 路径拼接形态可拨号、单 rank 撤收、撤收后重注册不重复展开；
  dp_size=1 不展开；`/server_info` 500 与缺字段不展开（多轮 sweep 后仍 1 条）；
  `/get_server_info` 回退；`SMG_DP_AWARE` 关时 dp_size=4 仍 1 条。K8s 组：403 不注册且
  计数、名字空间 list 路径与 labelSelector、无 token 不发头、恢复后注册并带 pod 标签、
  模型由后续 sweep 学到、路由可用、新增 pod 注册、标签翻转摘除、Ready=False 摘除、
  恢复 Ready 重注册、500 不清空、手工删除后被重新发现、SA token 作为 bearer 发出、
  PD selector 在 `SMG_GRPC` 关时按 400 契约拒绝并计数、`SMG_GRPC=1` 时 prefill +
  bootstrap_port 正常注册、discovery 关闭时完全不调用 API server、开了但无集群时给出
  disabled 日志且服务照常。交叉组：K8s 发现的 DP engine 展开成 pod url 的 4 个 rank、
  全部转健康、连续多个周期不抖动（注册计数恒为 1、摘除计数为 0）、rank 上推理可用、
  pod 消失带走全部 rank 并计数、pod 回来重新展开。

## 5. 尚未接线 / 未实现清单

1. `data_parallel_rank` 注入（§1.5）——接入点在 `router.lua`，需 root 单独接线。
2. K8s watch 事件流（§2.1）与 `field-selector` 过滤（§2.2）。
3. router pod 发现 / mesh 端口注解（Rust 的 `router_selector`）。
4. `smg_discovery_sync_duration_seconds` 直方图与新指标的 `# HELP` 行（§2.5）。
5. `SMG_GRPC` 关闭时 PD pod 的降级注册策略（§2.3）——需要改契约，留给 root 决定。
6. discovery 只做 list 轮询，没做 `resourceVersion` 续传：两次轮询之间发生又消失的
   pod 不会被看到（Rust 的 watch 会收到 Added/Deleted）。影响仅限“某个 pod 在两个
   周期之间短暂存在过”，对长驻推理服务无实际后果。
