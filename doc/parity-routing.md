# lua-router vs Rust llm-router 路由行为对拍（routing）

对拍日期 2026-09-29。比较的是**行为特性**（均匀性、粘滞性、重分布比例、亲和率、负载逃逸），
不是逐次选中同一个 worker——两边的策略状态（radix tree / hash ring / sticky map）各自独立演化。
数据目录 `/data/tmp/parity/routing/`，脚本 `harness.py` + `t1..t8c*.py`，原始结果 `t*_*.json`。

> **状态**：结论仍有效。**日期**：对拍 2026-09-29，状态复核 2026-09-30（UTC）。
> **证据强度**：B（`/data/tmp/parity/routing/` 的 harness 与原始 JSON；t1–t4 已由
> [verification-run3.md](verification-run3.md)
> 在 2026-09-29 23:00 全量重建后复现一遍）。
>
> 「未覆盖」一节里的 **prefix_hash / bucket / power_of_two / random 未纳入对拍**仍然成立，
> 别把这几条当成与 Rust 行为对齐（`prefix_hash` 尤其：blake3 vs xxh3，见 impl-hash.md 偏差 7）。
> manual 回切（#3）与 cache_aware 多进程衰减（#6，1.000→0.625）两条结论保持。
> 口径更新：本报告为了让 Rust 进入 consistent_hashing 用的是 per-model label hint；
> Lua 侧现在 `SMG_POLICY=consistent_hashing|prefix_hash|bucket` 已直接进分发
> （`config.lua` `POLICIES` 8 值 + `policy.lua` `MODULE_SPECS`），不再需要绕路。

## 结论摘要

| # | 策略 | 指标 | Lua | Rust | 判定 |
| --- | --- | --- | --- | --- | --- |
| 1 | round_robin | 30 请求 / 3 worker，max/min、χ² | 10/10/10，1.0，0.0 | 10/10/10，1.0，0.0 | 一致 |
| 1b | round_robin | 4 nginx 进程下均匀性 | 40/40/40，χ² 0.0 | 单进程 atomic（无对应） | 一致（Lua 用共享字典游标，跨进程不退化） |
| 2 | consistent_hashing | 同 key 10 次是否恒定同 worker | 20/20 | 20/20 | 一致 |
| 2 | consistent_hashing | 摘 1 worker 后其余 key 不动比例 | 0.80（16/20 未动） | 0.80 | 一致，且**逐 key 落点完全相同** |
| 2b | consistent_hashing | 60 key 扩样，落点一致率 / 重分布 | 60/60 一致，moved 16=全部来自被摘 worker，collateral 0 | 同 | 一致（blake3 环位实现逐位兼容） |
| 3 | manual | 同 key 粘滞 | 12/12 | 12/12 | 一致 |
| 3 | manual | 摘除后 failover 是否只动被摘 key | collateral 0 | collateral 0 | 一致 |
| 3 | manual | **恢复后回切原 worker** | **修复前 0/6 回切，修复后 12/12** | 12/12 | **背离，已定位并修复** |
| 4 | cache_aware | 8 会话 × 6 轮亲和率 | 1.000（0 次切换） | 1.000（0 次切换） | 一致 |
| 5 | cache_aware | 负载逃逸（1 个 400ms 慢 worker，C=8） | 慢节点占比 0.100 | 0.058 | 方向一致，Lua 逃逸略弱 |
| 5b | cache_aware | 同前缀强制走 cache 分支后逃逸（C=8） | 0.037 | 0.031 | 基本一致 |
| 6 | cache_aware | `worker_processes=4` 时亲和率 | 0.625（14 次切换） | 单进程（无对应） | 已文档化偏差，本次量化 |
| 6 | consistent_hashing | `worker_processes=4` 时粘滞 | 20/20，与单进程落点全同 | — | 环可重建，不受进程数影响 |

除 manual 回切这一条外，Lua 侧行为特性与 Rust 对齐。

## 测试口径（差异较大的两条必须先读）

**consistent_hashing 的进入方式不对称。** Rust CLI 的 `--policy` 只接受
`random|round_robin|cache_aware|power_of_two|prefix_hash|manual`，传 `consistent_hashing` 直接被
clap 拒绝（`gateway/src/main.rs:150` 的 `value_parser`）。
**这个镜像里根本没有配置文件入口**：`smg launch --help` 没有任何 config-file 选项，
`gateway/src/{main,server,app_context}.rs` 也没有读 RouterConfig 的 `fs::read`；
`LMR_CONFIG_FILE` 持久化的只是 runtime_config（effort / ctx / 虚拟模型别名），不含 policy。
所以线上唯一可用的入口是 worker label hint。本次改用
`POST /workers` 带 `labels.policy="consistent_hashing"` 的 per-model hint 把 Rust 侧驱动到该策略
（`gateway/src/core/steps/worker/shared/update_policies.rs:102` 读 hint →
`gateway/src/policies/registry.rs:169` `determine_policy_for_model`）。事后用
`smg_worker_selection_total{model="mch",policy="consistent_hashing"}` 计数器确认命中，
不是猜测。Lua 侧走 `SMG_POLICY=consistent_hashing`。两侧因此是同一策略、不同注册路径。

**RUST_BASE(8920) 实际是 round_robin，不是 env.sh 注释写的 cache_aware。**
`docker inspect rust-router` 的启动参数是 `--policy round_robin --cache-threshold 0.2`。
本对拍没有复用这个实例，而是按 policy 各起独立实例（见下节拓扑），避免共享状态互相污染。

**观察手段。** 自建 mock（`routing/mock_id.py`）把自己的 `wid` 写进每个响应体，
客户端直接读出选中 worker，不依赖 router 日志；test 1 额外用两侧 `/_ui/logs` 的
`selected` 字段交叉核对，结果与 `wid` 完全一致。

**实例拓扑。** Lua 侧复用 `authz:latest` + `test/conf/nginx-lua-router.conf`（改监听端口，
`worker_processes 1`）；Rust 侧 `ghcr.io/yorkane/llm-router:latest --network host --enable-igw`。

| 策略 | Lua | Rust | worker 池 |
| --- | --- | --- | --- |
| round_robin | 46101 | 8921 | mrr = 47721/47722/47723 |
| consistent_hashing | 46102 | 8921（labels hint，model=mch） | mch = 47725/47726/47727/47740 |
| manual | 46103 | 8922 | mma = 47728/47729/47730 |
| cache_aware（默认阈值） | 46104 | 8923 | mca = 47731/47732/47733 |
| cache_aware（abs=2 rel=1.5） | 46106 | 8926 | mlc = 47734(400ms)/47735/47736 |
| 4 进程偏差 | 46111 / 46112 / 46113 | — | 同上 |

## 1. round_robin

3 worker 同模型，各 30 请求，串行间隔 10ms。

```
lua  {'rrA': 10, 'rrB': 10, 'rrC': 10}  max/min 1.0  chi2 0.0  order rrC rrA rrB rrC rrA rrB
rust {'rrA': 10, 'rrB': 10, 'rrC': 10}  max/min 1.0  chi2 0.0  order rrA rrB rrC rrA rrB rrC
```

χ²=0（df=2 的临界值 5.991）。起点相位不同属计数器初值差异，不构成行为差异。
`/_ui/logs` 的 `selected` 与 `route_type` 均为 `round_robin`，与响应体 `wid` 计数一致。

补测 `worker_processes=4` + 4 线程 120 请求：`40/40/40`，χ² 0.0。
Lua 的游标在 `lr_policy` 共享字典（`policy.lua:98` `dict():incr(key,1,0)`），
跨 nginx 进程不会退化成 N 个独立游标，等价于 Rust 的进程全局 atomic。

## 2. consistent_hashing

20 个 key × 每 key 10 次请求，4 worker。

```
lua  sticky 20/20  dist chA30 chB60 chC70 chD40  → 摘 chD 后 chA40 chB80 chC80  moved 4  unchanged 0.80
rust sticky 20/20  dist chA30 chB60 chC70 chD40  → 摘 chD 后 chA40 chB80 chC80  moved 4  unchanged 0.80
```

不止是统计特性一致：**20/20 个 key 的落点逐一相同**，摘除后的新落点也是 20/20 相同。
扩样到 60 key 复现（`t2b_ring_scale.json`）：

- 摘除前落点一致率 60/60，每 worker 计数逐位相同（chA10 chB16 chC20 chD14，χ² 3.467）
- 重分布 16/60 = 0.2667，`moved_that_were_on_dropped` 16，`collateral` 0
  ——只有原本落在被摘 worker 上的 key 移动，其余 key 完全不动
- 摘除后落点一致率仍 60/60

说明 `hash.lua` 的 blake3 环位与 `worker_registry.rs` 的 `HashRing`（150 vnode/worker，blake3）
在实现层面兼容，不是巧合。

## 3. manual（发现并修复一处行为背离）

12 个 key × 10 次，3 worker，摘 maC 再恢复。粘滞与 failover 隔离性两侧本来就一致
（12/12 粘滞，collateral 0）。差异在**恢复后回切**：

```
修复前  lua  returned_to_original 6/12   （6 个曾 failover 的 key 全部没有回切）
        rust returned_to_original 12/12
修复后  lua  returned_to_original 12/12
```

Rust 会回切、Lua 不会，Lua 侧 `manual` 的会话在 worker 重启/摘除后再也回不到原实例。
定位到两处叠加缺陷，均在 `lualib/resty/luarouter/policy.lua`。

**缺陷 1 — 候选顺序颠倒（`policy.lua:193` `policies.manual`）。**
Rust 用 `Node::push_bounded`（`gateway/src/policies/manual.rs:87`）：从已记录列表出发，
达到 `MAX_CANDIDATES=2` 才从头 pop，然后 **追加** 新选择。所以列表始终是 old-first，
`occupied_hit` 顺序扫描时优先命中最初那个 worker——这正是 failover 后能回切的原因。
Lua 原来写 `local updated = { chosen.url }` 再把旧 url 补在后面，变成 new-first，
`occupied_hit` 永远先撞 failover 目标，回切在结构上不可能发生——尽管原注释
（"keep the tail so a returning worker can take over again later"）声称的行为恰恰相反。

**缺陷 2 — `on_remove` 主动清理粘性表（`policy.lua:488` `_M:on_remove`）。**
只修顺序仍然 6/12：Lua 的 `on_remove` 会把被摘 URL 从每个 `manual:*` 条目里删掉，
worker 回来后表里已经没有它。而 Rust 的 `ManualPolicy` **从不接收 worker 摘除通知**——
`remove_from_policy_registry.rs` 只调 `remove_worker_from_cache_aware`，
`on_worker_removed` 仅在一个模型的 worker 清零时丢掉 policy 映射，
都不碰 `routing_map`。表项只按 `max_idle_secs` 老化。所以 Rust 能回切是"记录了已消失的候选、
命中时靠候选列表查不到该 URL 而走 `occupied_miss`"，Lua 的清理动作把这个前提抹掉了。

修复：候选更新改成逐行照搬 `push_bounded`（先填旧列表、`while #updated >= MAX_CANDIDATES`
再 `table.remove(updated,1)`、最后追加）；`on_remove` 对 manual 只删 `group:` 负载计数，
不再改写 `manual:*` 条目，老化仍交给 `max_idle_secs`，与 Rust 的 eviction task 等价。

修复后 `moved_during_drop` 只剩原本在被摘 worker 上的 key（`{'man-09':['maC','maB'],
'man-10':['maC','maA']}`），failover 期间每 key 目标唯一（无抖动），恢复后 12/12 回到原 worker，
与 Rust 行为完全对齐。

**边界确认：连续两次 failover（`t8c_double_failover.json`）。** 同一个 key 连续失去两次
worker（`MAX_CANDIDATES=2` 的窗口会挤掉最初的候选），再把两个 worker 都恢复：

```
lua  maB → maC → maA   恢复后 → maC   （不回最初，回窗口内更早的那个）
rust maB → maA → maC   恢复后 → maA   （同上）
```

两侧都不回已被挤出窗口的原始 worker，都回窗口内存活时间更长的那个，逐位一致。
`push_bounded` 的 2 槽语义被完整复刻，不是只把 happy path 修好。

回归：`test_policies 118 passed / 0 failed`、`test_tree 67/0`、`test_hash 795/0`；
`test/integration/e2e_stateful.py` 43 checks 0 failed；`test/test_lua_router.sh` 全量
266 passed / 0 failed（3 条 NOTE 为既有契约差异说明：404 body、405 vs 404、`/v1/loads` shape，
与本次改动无关）。（266 是 manual 修复当时的基线，2026-09-30 复跑现为 322。）

原有测试集对 `manual` 的覆盖只有「同 key 粘住」——`test/test_lua_router.sh` 里 "manual"
只出现在 `/server_info` 的 policy 枚举断言中，没有任何 manual 流量用例——
所以上面两个缺陷都没有守卫。已在 `test/integration/e2e_stateful.py` 增加 `[manual failback]`
段（6 key / 3 worker，摘掉被粘住的 worker → 断言只有它的 key 迁移 → 重新注册 →
断言这些 key 回到原 worker、旁观 key 全程不动），共 8 个 check。
回灌验证：把 `policy.lua` 还原成修复前的两处实现并重建镜像重跑，只有
`[manual failback] failed-over keys return to their original worker` 一条失败
（`expected 38787 got {"fb-0": 36203, "fb-2": 57329, "fb-3": 36203, "fb-5": 36203}`
——4 个迁移出去的 key 一个都没回来），粘滞、迁移隔离、旁观 key 不动等 check 全过；
换回修复后的实现则 43/43 全过。

## 4. cache_aware 亲和率

8 个会话，每会话固定 6 条消息前缀（system + 5 轮），第 3 轮起才追加 tail 保证前缀占主导，共 6 轮 48 请求。
两侧均为默认阈值 `cache_threshold=0.3, abs=64, rel=1.5`，`worker_processes=1`。

```
lua  affinity 1.000  dist caA30 caB0  caC18  每会话切换次数全 0
rust affinity 1.000  dist caA0  caB6  caC42  每会话切换次数全 0
```

亲和率都是 1.000，48/48 请求全部命中该会话首次选中的 worker，一次切换都没有。
分布集中度不同（Rust 8 个会话里 7 个挤在 caC）来自冷启动 `min_load` 并列时的随机 tie-break
与 tree 播种顺序，属于状态独立演化，不是策略能力差异。

## 5. 负载逃逸

一个 400ms 慢 worker（lcA）+ 两个快 worker（lcB 1ms / lcC 6ms），闭环 8 线程 240 请求，
`balance_abs_threshold=2`、`balance_rel_threshold=1.5`（两侧同参），同前缀集合作对照组。

```
cache_aware   lua  lcA 24  lcB 157 lcC 59   slow_share 0.100   26.0 req/s
cache_aware   rust lcA 14  lcB 127 lcC 99   slow_share 0.058   45.8 req/s
round_robin   lua  lcA 80  lcB 80  lcC 80   slow_share 0.333   （对照组，符合预期）
round_robin   rust lcA 80  lcB 80  lcC 80   slow_share 0.333
```

两边都明显偏离 1/3 基线，说明逃逸分支都被触发。Lua 慢节点占比是 Rust 的 1.7 倍，
但这个数字不能直接读成"Lua 逃逸能力差"：闭环压测吞吐受 router 自身开销影响，
cache_aware 每请求要抽路由文本并走 radix tree。同环境实测串行单请求延迟
（0 延迟 worker，`t5b_spill_matched.json`）：

```
lua  p50 1.72ms  p95 45.43ms
rust p50 1.87ms  p95 45.53ms
```

转发开销基本相同（p95 那 45ms 是 mock 的健康检查/keepalive 噪声，两侧同时出现）。
C=2 时两侧都还没进逃逸分支（`max-min` 未超过 abs=2），只是各自冷启动随机选中的 min-load worker
被 cache 分支钉住——`cache_aware/lua` 全给 lcC、`cache_aware/rust` 全给 lcA，
这是并列随机初值不同，不是逃逸差异。

为把逃逸分支单独量出来，改用**全部请求同一前缀**（cache 分支必然全部钉到同一 tenant，
只有逃逸分支能把请求挪走），C=8/160 请求：

```
lua  lcA 6  lcB 115 lcC 39   slow_share 0.037   79.6 req/s
rust lcA 5  lcB 118 lcC 37   slow_share 0.031   95.2 req/s
```

差异收敛到 0.037 vs 0.031，逃逸分支行为一致。C=8 那组 0.100 vs 0.058 的差距主要来自
两侧 tree 学到的 tenant 分布不同（Lua 把会话摊到 3 个 worker、Rust 摊到 2 个），
摊得更开的 Lua 更容易把某个 session 的亲和 worker 恰好放在慢节点上。属于状态演化差异。

吞吐数字（Lua 26 vs Rust 45.8 req/s）在本轮**未做等并发对齐**，不能当作 Lua 的转发性能结论。

## 6. 多进程对策略状态的影响（已文档化偏差的量化）

`doc/impl-policies.md` 偏差 1 记录 cache_aware 的 tree 是 per-process 状态；
`docker-entrypoint.sh` 因此在 `SMG_POLICY=cache_aware` 且未显式指定时把
`worker_processes` 压到 1。这里量化不压的后果（`worker_processes=4`）：

```
cache_aware       亲和率 0.625（48 请求里 14 次会话内切换），单进程时 1.000
consistent_hashing 粘滞 20/20，且与单进程落点 20/20 全同
round_robin       40/40/40，χ² 0.0
```

cache_aware 亲和率随进程数按约 1/N 退化，与文档说法吻合。
consistent_hashing 和 round_robin 不受影响：前者环由 worker URL 列表确定性重建（`hash.ring_cached`
按拓扑签名判定），后者游标在共享字典。
**部署结论：cache_aware 必须 `worker_processes 1`（或接受 1/N 亲和率）；其余策略可放开。**

## 复现步骤

```bash
bash /data/tmp/parity/routing/setup_pools.sh      # 起 mock 池（setsid 保活，勿用 nohup 裸跑）
bash /data/tmp/parity/routing/start_rust.sh       # pr-rr/pr-manual/pr-ca/pr-load
bash /data/tmp/parity/routing/gen_lua_conf.sh ... # 生成各端口 conf
bash /data/tmp/parity/routing/start_lua.sh        # pl-rr/pl-manual/pl-ca/pl-load
bash /data/tmp/parity/routing/register_all.sh     # 两侧注册同一批 worker（Rust ch 走 labels hint）
python3 /data/tmp/parity/routing/t1_round_robin.py
python3 /data/tmp/parity/routing/t2_consistent_hash.py
python3 /data/tmp/parity/routing/t2b_ring_scale.py
python3 /data/tmp/parity/routing/t3_manual.py
python3 /data/tmp/parity/routing/t4_cache_aware.py
python3 /data/tmp/parity/routing/t5_load_escape.py
python3 /data/tmp/parity/routing/t5b_spill_matched.py
python3 /data/tmp/parity/routing/t6_multiproc_degradation.py
python3 /data/tmp/parity/routing/t7_imbalance_branch.py
python3 /data/tmp/parity/routing/t1c_rr_4proc.py      # 需先起 pl-rr4b（worker_processes 4）
python3 /data/tmp/parity/routing/t8c_double_failover.py
```

改过 `policy.lua` 后要 `docker restart` 对应 pl-* 容器（`/repo` 是 ro bind，重启才重载字节码），
并重新 `register_all.sh`（重启清空 lr_workers）。

## 未覆盖

- 流式（`stream=true`）下的路由选择未单独测；选择逻辑与阻塞式同路径，逃逸的时序会不同。
- Lua 侧 cache_aware 快照（`lr_policy` 写回/reload 恢复）只由 e2e 的 `[snapshot]` 段覆盖，
  没有和 Rust 做跨重启亲和率对比（Rust 无磁盘树）。
- `prefix_hash` / `bucket` / `power_of_two` / `random` 未纳入本次范围。
- Rust 的 gRPC / PD 分离路径不参与（Lua 明确不实现）。
- manual 的 `min_load` / `min_group` assignment mode 未测（默认 `random`）。
- test 5 的吞吐对比未做等并发对齐，只可作方向参考。

## 本次遗留的进程与清理

对拍新建的实例（`lua-router` / `rust-router` 两个原始实例未动）：

```
docker rm -f pl-rr pl-ch pl-manual pl-ca pl-load pl-ca2 pl-rr4 pl-rr4b pl-ch4 pl-ca4 \
             pr-rr pr-manual pr-ca pr-load pr-ca2
kill $(awk '{print $3}' /data/tmp/parity/routing/pools.pids)
```

mock 池的实际 pid 以 `ps -eo pid,args | grep mock_id.py` 为准（`pools.pids` 只记录首轮启动，
后续补起的进程不在其中）。
