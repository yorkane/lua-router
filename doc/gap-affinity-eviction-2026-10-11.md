# cache_aware 亲和树的容量口径与驱逐（现行机制）

本文是 cache_aware 亲和树的容量口径：为什么需要三闸、每闸管哪一维、长上下文业务下怎样定尺，以及仍然成立的结构性限制。fleet 的现值在 [deploy-state.md](deploy-state.md)。

## 1. 亲和键与驱逐节奏

- cache_aware 的亲和键是 `policies/utils.lua` 的 `extract_text_for_routing(body)`：把整段 messages 拼成一个
  **字符**串（本仓的树按字符计数，不是 token）。策略实例按**入口名**建，一入口一棵树。
- 命中判定在 `policies/cache_aware.lua`：`match_rate = matched_chars / input_chars` 与
  `SMG_CACHE_THRESHOLD`（`config.lua` 缺省 `0.3`；fleet 生产配 `0.2`）比较。命中才按租户（= worker URL）定位，
  否则落进 `utils.min_load_index` 的 min-load 分支，**并列时随机**（`utils.choose`）。
- 驱逐由 `policy.lua` 的 `sweep_standalone` 驱动，节奏 `SMG_EVICTION_INTERVAL_SECS`（缺省 120），每棵树调
  `policies/tree.lua` 的 `evict_tenant_by_size(max_size, max_nodes, budget)`。

## 2. 三个闸各管一维（缺一不可）

| env | 缺省 | 管的维度 | 备注 |
|---|---:|---|---|
| `SMG_MAX_TREE_SIZE` | 67,108,864 | **每租户（每个 worker URL）的字符上限** | 语义是"每租户"，不是全树：同一批 worker 可以各自背满它 |
| `SMG_MAX_TREE_NODES` | 200,000 | **全树节点数上限** | `<=0` 关闭这一维；钳到 5,000,000（再大等于没设，且单拍成本失控） |
| `SMG_EVICT_BUDGET` | 0（→ tree.lua 缺省 2000） | **单次淘汰弹多少个叶子**（增量上界） | 钳到 200,000；没有预算时"树已失控"的那一拍本身就能占秒级核时 |

**为什么字符闸不能当内存闸用**：`tree.lua` 的 `over_limit()` 是廉价前置判定，两个维度都在它内部——字符维度
按租户判，节点维度按 `live_nodes` 判，`node_count` 只涨不跌的话（叶子清空后父链未回收）节点闸就形同摆设，所以
回收与计数在同一处做（`detach_if_empty` 那条）。总占用 = 树数 × 租户数 × 字符上限，**没有任何一维约束节点个数**，
真正把转发核压住的是节点数（每节点一张表 + 一份 prompt 尾巴，量级约 200-400 B/节点，最坏约 60 MB/树）。

**字符闸设太小会反噬**：一个 Codex 回合的路由文本常有十几万到几十万字符。若 `max_tree_size` 小于单条会话长度，该叶子每被插入就在下一拍被弹掉 → 下回合 `matched_chars≈0` →
`match_rate` 低于阈值 → 落进 min_load 分支 → 两台 load 读数相等时**并列随机**有概率换引擎 → 该引擎前缀缓存里没有
这段上下文 → 整段重新 prefill。用户侧表现是"直连 200+ tok/s、走网关掉到几十"。所以定尺口径：

```
SMG_MAX_TREE_SIZE ≥ 单会话路由文本字符数 × 每租户并发会话数 × 余量
```

实测标定 **5.5 chars/token**（196,608-token 引擎窗口 ≈ 1.08M 字符）。fleet 现值 `100000000`（≈ 每租户容 12-18 条
满尺寸会话），放宽字符闸的安全前提是节点数闸与增量淘汰都在位。引擎侧 `--max-context` 决定单条请求的天花板：
超过就被引擎 400 拒（`context_length_exceeded`），失败的请求不进亲和树，不污染字符占用。

**快照预算**：`LR_SNAPSHOT_MAX_BYTES`（缺省 3 MB/实例）约束写进 `lr_policy` 的单棵树快照；超限跳过并 WARN。
后果只是 reload 后亲和冷启动重新 warm，运行期不受影响。

## 3. 仍有效的限制

1. **min_load 并列随机会放大驱逐的后果**。`load_with = inflight + external × load_scale / 1000`；引擎没有
   `/metrics` 也没有 `/v1/loads` 自报时，外部读数缺失 → load 落回 inflight → 空闲时两台完全并列 → 随机。
   这会把"本可粘住的那一半"也打散。给引擎加负载自报是消除它的正解（见
   [gap-gpu-load.md](gap-gpu-load.md) §8 第 1 条的 host 映射限制）。
2. **声明的 `max_concurrency` 必须等于引擎真实车道数**。网关按声明值判 full，声明 10 而引擎 `--max-concurrency 2`
   时，第 3 个并发请求不会被网关挡住，而是在引擎内部排长队。这是**并发**变慢的独立一条路，与亲和跨引擎无关；
   对齐后全池满时答 429 让客户端退避。
3. **sharedprefill 高并发塌方是结构性残留**：cache_aware 把几乎相同的 prompt 聚到同一台复用它的 prefix KV（正确
   行为），但该台的车道数就是硬顶，fan-out 一高即引擎内排队塌方。根治要么加同模型副本摊开（亲和能把同前缀
   fan-out 分到更多机器），要么降低单会话的并行 fan-out。把策略换成 `power_of_two` 实测更差（丢亲和命中），
   所以 `cache_aware` 保持不变。
4. **网关转发本身零额外损耗**：2026-10-11 的受控基准里，decode 负载下"经网关 cache_aware 调度"的双路聚合
   2.66x ≈ "轮流直连两台"理想基线 2.69x，TTFT 同量级；prefill 单路负扩展（0.10x 塌方）在双路下 3.06x 正扩展。
   遇到"走网关变慢"先查亲和驱逐与并发声明，不要先怀疑转发开销。

## 4. 复现与验证

`script/verify-affinity-eviction.py`（只读 `GET /logs /workers /metrics` + 自造请求，不碰配置与容器状态）：
两条入口同引擎对的 A/B，比较空闲两轮驱逐扫树后是否换实例、引擎侧前缀缓存计数是否塌 0。改闸后复跑它。

按 AGENTS.md：配置面改动先上 21.k:8801/8802 测试实例验证，用户确认后才推 8800 生产。

## 5. KV 留存是引擎能力，不是网关配置

网关亲和只做一件事：把同一会话送回同一台引擎。**该引擎把闲置会话的 KV 留多久，是引擎侧的事**，网关不代管、也不度量。长会话空闲回来后前缀缓存冷掉，要在引擎的缓存层级与容量旋钮上解决，不在网关上找开关：ninfer 是 device(GPU) + host(DRAM) 两级（闲置会话驻留数看 `--host-state-slots` / `--host-kv-mib` / `--max-private-continuations` / `--max-shared-prefixes`），SGLang 自带 L2/L3（`PENNY_HICACHE_SIZE_GB` + `SGLANG_HICACHE_NIXL_MAX_CACHE_GB`）。同一次跨引擎跳转的代价因此按引擎而不同。现场参数值属于引擎侧部署记录与 box 记录，本文不复述。

## 关联

- 空载烧核的治法是**节点数闸 + 增量淘汰**这两维，不是把字符闸调小：字符闸调小只压总量，代价是把长会话弹光；真约束内存与单拍成本的是节点数与每拍淘汰预算。**在两者都在位的前提下，字符维度才可以放大**。口径见 `config.lua` 的 `max_tree_nodes` / `evict_budget` 注释与 `policies/tree.lua` 的 `over_limit`。
- [gap-virtual-models.md](gap-virtual-models.md)：入口 1 对多、按入口名一棵亲和树。
- [gap-gpu-load.md](gap-gpu-load.md)：load 打分与 `min_load` 逃逸读的 `record.load` 从哪来。
