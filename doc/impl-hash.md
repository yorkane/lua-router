# hash / consistent_hashing / prefix_hash 实现说明

对端参考实现：`gateway/src/core/worker_registry.rs`（HashRing）、
`gateway/src/policies/consistent_hashing.rs`、`gateway/src/policies/prefix_hash.rs`、
`gateway/src/routers/header_utils.rs`，以及 BLAKE3 官方
`reference_impl/reference_impl.rs`。

> ARCHITECTURE.md 缺失：接到任务时 `lua-router/` 目录还不存在，
> `doc/ARCHITECTURE.md` 也没有（本仓库 doc/ 下只有 impl-policies.md）。
> 因此契约取自 Rust 侧源码 + 任务规格。接口形态（`policy.new(cfg, rng)` /
> `select_worker(workers, info)` / `name()` / `needs_request_text()` /
> worker 访问器走 `policies/utils.lua`）对齐已落地的 cache_aware / bucket，
> 若 ARCHITECTURE.md 后续另有规定需要复核。

> **状态**：仍有效。**日期**：写作 2026-09-29，状态复核 2026-09-30（UTC）。
> **证据强度**：A（单测计数本轮复跑确认）。
>
> 事实校正：文中「当前结果 hash: 791 passed」已过时，现为 **hash 795 passed, 0 failed**
> （两个镜像口径均 exit 0）；同批 tree 62→67、policies 116→118。
> consistent_hashing 与 prefix_hash 已在 `policy.lua` 的 `MODULE_SPECS` 里、`config.lua` 的
> `POLICIES` 白名单接受这两个值，`SMG_POLICY=consistent_hashing|prefix_hash` 不再被归一成
> round_robin；真实流量下的行为验证见 parity-routing #2/#2b（逐 key 落点与 Rust 相同）与
> e2e_stateful 的 prefix_hash 段。
> 偏差 6（按字符不按 token）与偏差 7（blake3 ≠ xxh3，与 Rust 无可移植映射）仍然成立，
> 见 [feature-gap.md](feature-gap.md) §5.3。

## 算法 → 文件映射

| 内容 | Rust | Lua |
| --- | --- | --- |
| BLAKE3（完整实现）+ 环构建 / 二分 / 顺时针查找 | `core/worker_registry.rs` | `lualib/resty/luarouter/hash.lua` |
| 一致性哈希策略（target-worker / routing-key / 隐式 key / 随机） | `policies/consistent_hashing.rs` | `policies/consistent_hashing.lua` |
| 前缀哈希策略（前缀哈希 + load_ok 有界负载） | `policies/prefix_hash.rs` | `policies/prefix_hash.lua` |
| 单测 | `#[cfg(test)]` 内联 | `test/unit/test_hash.lua` |

## 与 Rust 的偏差（全部已确认取舍）

### 1. BLAKE3 是完整实现，不是降级方案（无偏差）

规格允许「完整 BLAKE3」或「结构简化 + 写文档」。这里交付的是**完整 BLAKE3**：
上游 `test_vectors.json` 的 19 个长度（0/1/2/3/4/7/8/63/64/65/1023/1024/1025/
2048/2049/3072/3073/4096/4097）逐个通过，含跨 chunk（>1024B）触发父节点合并的
树形分支；`blake3("abc")` 与 `blake3` Python 绑定逐字节相同；环位置（前 8 字节
小端 u64）与 `struct.unpack('<Q', blake3(...).digest()[:8])` 一致。

没有实现 `keyed_hash` / `derive_key` / XOF 变长输出——router 只用 `blake3::hash`
（32 字节摘要）这一条路径。需要时 compress 内核已具备（改 flags 即可）。

**踩过的两个坑，记录以免回归**：

* chunk 内**每个块**的 compress counter 都是 `chunk_counter`，不是
  `chunk_counter + block_index`（`reference_impl.rs:208` 与 `:232` 都传
  `self.chunk_counter`）。按块递增计数器会让所有 >64B 的输入算错。
* `compress` 的输出后半段是 `state[8+i] ^ chaining_value[i]`。若 out 与 cv 是
  同一张表（早期写法就是这样），异或会读到已被循环覆盖的值——**静默**算错，
  且只有 ≤64B 的单块输入看起来是对的。现在 compress 用多个返回值输出，
  彻底不存在别名。

### 2. u64 环位置按 (hi, lo) 两个 32 位数表示

LuaJIT 的 number 是 double，`2^53` 以上装不下精确 u64。Rust 用 `u64` 排序/二分，
这里排序键改成 `(hi, lo)` 字典序，`hash.search` 在 hi 相等时比 lo。语义与 Rust 的
`u64` 全序一致，且**不丢位**。`_M.position_u64` 返回单个 number，只供日志/断言，
环内部不用它比较。

### 3. 环缓存挂在策略实例上，不挂 registry 快照

Rust 把环存在 `WorkerRegistry.hash_rings`（DashMap<model_id, Arc<HashRing>>），
由 `register` / `remove` 触发重建。Lua 侧目前没有常驻 registry（`registry.lua` 是
worker 注册的 HTTP 控制面，不持环），所以每个策略实例按 `pool::model` 各存一份环，
用 **URL 列表签名**（`#urls .. "\n" .. concat(urls, "\n")`）判定拓扑是否变化：
签名不变就直接复用同一个环对象（每请求零分配），变了才重建
（6 worker / 900 虚拟节点约 2 ms）。

* 与 cache_aware / bucket 一致：环是 **per nginx worker 进程**的，不做跨进程共享。
* 6 worker 重建 1.5–2.4 ms，只在增删 worker 时发生一次，不影响请求路径。
* 框架若能提供常驻 registry，把 `hash.ring_cached(state, urls)` 的 `state` 换成
  registry 快照里的槽位即可，策略层不用改（`invalidate_rings()` 也可显式清）。

### 4. 健康判定向「更严」一侧对齐：额外过熔断器

Rust 的 consistent_hashing / prefix_hash 只看 `w.is_healthy()`
（`consistent_hashing.rs:78/121/153/162`、`prefix_hash.rs:140`），不含熔断器；
cache_aware / bucket 才走 `is_healthy() && circuit_breaker().can_execute()`。
这里两个策略统一用 `utils.healthy_indices`（含 `worker_can_execute`），
与 Lua 侧其它策略一致。框架不填 `circuit_breaker` 字段时默认放行，此时行为与
Rust 完全相同；填了则本策略会多摘掉熔断打开的 worker。要逐位对齐 Rust 的话，
把这两处换成只看 `utils.worker_healthy` 即可。

### 5. 不实现 Rust 的「无环退化 modulo」路径

`consistent_hashing.rs:100-113` 在 `info.hash_ring == None` 时退化成
`blake3(key) % 健康下标数`。这里环由 `ring_for` 现场构建，不存在「没有环」的请求，
所以没有实现这条分支（实现它只会引入一个和环语义不同的第二套映射）。
`ring.count == 0`（worker 列表为空）仍然返回 nil。

### 6. prefix_hash 的哈希对象：文本前缀，不是 token

Rust 在 HTTP 路径**永远拿不到 tokens**——`router.rs:176` 与 `pd_router.rs:1092`
都写死 `tokens: None, // HTTP doesn't have tokens, use gRPC for PrefixHash`，
而 `prefix_hash.rs` 在 tokens 为 None/空时直接返回 `NoTokens`。也就是说 Rust 的
prefix_hash 在 HTTP 模式下恒不选 worker。

本实现改为对 **`utils.utf8_head(request_text, prefix_token_count)`** 求哈希：

* `prefix_token_count`（默认 256）现在数的是**字符**（UTF-8 码点），不是 token。
  对齐 utils.lua 已有的码点计数口径。
* `request_text` 由框架用 `utils.extract_text_for_routing(body)` 提供，
  因此 `needs_request_text()` 返回 `true`（Rust 返回 `false`——它不需要文本，
  因为它不需要 token）。
* 文本为空/缺失 → 返回 nil（`no_tokens` 分支），对齐 Rust 的 `None` 语义。
  不给空串兜底，否则所有无文本请求会全挤到同一个 worker。

近似代价：字符数 ≠ token 数（尤其中文，1 字符常 > 1 token），所以「前 256 字符」
与「前 256 token」覆盖的内容长度不同，分组粒度比 Rust 粗或细都可能；且同一句话
在 Rust 侧按 token 序列（u32 数组的字节表示）哈希、这边按 UTF-8 字节哈希，
**worker 选择结果不可能与 Rust 逐个对齐**。共享同一前缀的请求仍然共享同一
worker，这才是 KV 亲和真正依赖的性质。

### 7. prefix_hash 的哈希函数：blake3 而非 xxh3_64

规格写「xxh3_64 或降级 sha224」。两个都不选，直接用本模块的 blake3：

* xxh3_64 要再写一份纯 Lua 实现，而 blake3 已经在手；
* 镜像里 `resty.sha224` 在 authz:latest 上**加载即报错**
  （`Symbol not found: SHA224_Init`，lua-resty-openssl 与静态 libcrypto 符号不匹配），
  拿它做主哈希等于把策略绑在一个装不上的模块上；
* 环本身已经是 blake3，复用同一个内核，`compute_prefix_hash` 每请求只 1 次哈希。

做法：`hash.position(prefix)` → 前 8 字节小端 u64，用 `_M.position_hex` 渲染成
16 位小写 hex（与 Rust `format!("{:016x}", xxh3_64(...))` 同宽同基数）。
实现里没有真的「hex 字符串再哈希一次」，而是把 (hi, lo) 位置直接交给
`hash.lookup_position`——这与 Rust 的 `ring.find_healthy_url(&format!("{:016x}", h))`
等价（Rust 那边对 hex 串再 blake3 一次），并**省掉一次哈希**。

后果：**与 Rust 的 prefix_hash 没有可移植的 worker 映射**（xxh3 ≠ blake3）。
Rust 侧的 `x-smg-routing-key` 语义不受影响——consistent_hashing 那条链路的
哈希是逐位一致的 blake3，两边可以互相迁。

### 8. prefix_hash 的负载均衡：一次全表扫描，不顺时针走环

Rust 文档串写 "walk clockwise to the next worker"，代码实际做的是
「首站过载 → 在满足 load_ok 的健康 worker 里取 `min_by_key(load)`；
全都过载 → 仍用首站」（`prefix_hash.rs:176-191`）。这里跟代码走：
同样是一次 O(n) 扫描，同样以 `load_ok` 为闸门，全过载同样回落首站。
并列时取**下标最小**者（严格 `<` 扫描），对齐 `min_by_key` 取首个最小值；
Rust 那边并列取的是 `healthy_workers` 顺序里的首个，两者都是「输入顺序里第一个最小」。

`load_ok` 逐位对齐：`total == 0 || n == 0` 直接放行，否则
`load <= (total + 1) / n * load_factor`（+1 表示正在路由的这条请求）。

环不可用（count==0）→ 健康 worker 里取最小负载（`fallback_least_load`），对齐
`prefix_hash.rs:196-203`。

### 9. `worker_count()` 语义

Rust 的 `HashRing::worker_count()` 是 `entries.len() / 150`（整除）。这里环表带
`worker_count` 字段，直接是构建时的 worker 数，两者在正常拓扑下相等。

## 分支名（供 metrics 接线）

两个策略的 `select_worker_impl` 都返回 `下标, 分支名`，分支名与 Rust 的
`Branch::as_str()` 逐字对应：

* consistent_hashing：`no_healthy_workers` / `target_worker_hit` /
  `target_worker_miss` / `routing_key_hit` / `random_fallback`
* prefix_hash：`no_healthy_workers` / `no_tokens` / `ring_hit` /
  `load_balance_walk` / `fallback_least_load`

`parse_index` 会先剥掉前导零再判长度，所以 `"0000...0001"` 与 Rust 一样解析成 1；
剥零后仍超过 15 位的值按解析失败处理（Rust 能解析，但这种下标在任何真实拓扑里
都越界，两边结果都是 `target_worker_miss`）。

`select_worker` 只返回下标（和 cache_aware / bucket 一样），框架要记 metrics 就调
`select_worker_impl`。

## 性能

`authz:latest` 的 LuaJIT（`/usr/local/openresty/luajit/bin/luajit`），预热 3 万次
后取 10000 次：

| 操作 | 未展开（本实现） | 朴素循环+表 port |
| --- | --- | --- |
| `hash.position` ×10000（短 key） | **5.0–5.8 ms**（约 550 ns/次） | 72 ms |
| `hash.hex` ×10000 | 32–73 ms | 93–96 ms |
| `hash.new_ring`（6 worker / 900 节点） | 1.5–2.4 ms | — |
| `hash.lookup` ×10000 | 9–14 ms | — |
| consistent_hashing `select_worker_impl` ×10000 | 32–36 ms | — |

规格预算「10000 次 blake3 < 100 ms」通过，余量约 17 倍。朴素实现（压缩函数走
循环、状态放 table）单独测是 72 ms/万次，仍然过线但只剩 1.4 倍余量——unroll 的
必要性在这里，不在「能不能跑进 100ms」。

`hash.hex` 明显贵于 `position`（64 ms vs 5.8 ms，同一个一万次循环）：多出来的是
8 个 word 各拼 4 段两位 hex 的字符串工作。热路径只用 `position`，不影响请求延迟。

单次 `select_worker`（consistent_hashing，routing-key 路径）约 3.3 µs，其中
1 次 blake3（~0.55 µs）+ 二分 + 若干次健康判定 + 每次一个 `tried` 小表。

## 单元自测怎么跑

宿主机没有 luajit / perl，用镜像里的解释器。被测逻辑纯 Lua、不依赖 ngx，
所以两个镜像都通（`resty` CLI 在 authz:latest 里因为镜像无 perl 不可用，
apisix 镜像里可用）：

```bash
cd /path/to/lua-router
# authz 镜像的 luajit
docker run --rm -v "$PWD:/repo:ro" -w /repo \
  --entrypoint /usr/local/openresty/luajit/bin/luajit authz:latest \
  -e 'package.path="/repo/lualib/?.lua;"..package.path
      dofile("/repo/test/unit/test_hash.lua")'
# apisix 镜像的 resty（真实 ngx 环境）
docker run --rm -v "$PWD:/repo:ro" -w /repo \
  --entrypoint /usr/bin/resty apache/apisix:3.11.0-debian \
  -e 'package.path="/repo/lualib/?.lua;"..package.path
      dofile("/repo/test/unit/test_hash.lua")'
```

当前结果：`hash: 795 passed, 0 failed`（两个镜像均 exit 0；初版写作时是 791），
`tree: 67 passed` / `policies: 118 passed` 不受影响。

覆盖点：19 个官方向量 + 127/128/129 抽样、`abc` 逐字节；
环位置 (hi,lo) 与 Python 参考一致、vnode 位置（`url#le64(vnode)`）与
`HashRing::new` 的输入构造一致、`u64_le_bytes`；
10000 key 落 8 桶的 χ²（α=0.01、df=7、临界 18.4753，实测 high3 = 9.16、
low3 = 4.56，对应 p ≈ 0.24 / 0.71）；
二分边界（命中首/末条目、低于全部、高于全部）、回绕、只留 1 个健康 worker、
全不健康 → nil；
一致性：移除 6 个里的 2 个（1/3）时保留 worker 上的 key **0 个迁移**、
约 1/3 key 原本站在被摘 worker 上；加 1 个 worker 时 1000 key 搬 124 个（理想 143）；
策略层面 600 key 摘 2/6 worker 后其它 key 0 迁移；
`ring_cached` 拓扑不变复用同一对象、集合或顺序变化即重建；
prefix_hash 的策略结果与「直接拿前缀位置查环」逐位相同（`lookup_position` 布线检查）；
target-worker 的 0-based 下标、`+N`、前导零（`000`→0、`0001`→1）、越界/不健康不回退、
`-1`/`1.5`/` 1`/`1 `/`a`/`+`/`1e2`/`0x1`/`2,3` 全部拒（对齐 `str::parse::<usize>`）、
16 位以上纯数字按解析失败处理（Rust 能解析但必然越界，结果同为 miss）、
空串按「无此 header」落后续分支；
routing-key 稳定性与分散度（200 key → 75/63/62）、显式 key 优先于隐式 key、
隐式 key 三级优先、无 key 随机且跳过不健康；
prefix_hash 的 load_ok 边界（30/31/31.5625/32 @ total100/n4、3/4 @ total10/n4、
factor 1.0 的 11<=11 边界、total==0 与 n==0 放行）、无文本/空文本 → nil、
同前缀同 worker、CJK 按字符截断、超 256 字符不影响、首站过载改选最小负载、
全过载仍用首站、不健康 worker 不计负载也不被选、空环退化最小负载、
配置字符串数字强制转换与未知 key 忽略、`invalidate_rings` 后位置不变。
