# 长上下文会话在 cache_aware 下亲和失效、被 LRU 淘汰甩到另一台引擎

日期：2026-10-11　对象：21.k:8800 生产入口 Q38-Flash-Next → swift-1.5-qwen3.8-flash-next-nvfp4（8034/8035）

## 结论（一句话）

「swift1.5 经过 Q38 虚拟服务后速度大幅下降」不是网关转发本身扣速度，而是
cache_aware 亲和在长上下文（Codex 那种几十万字节的会话）下失效：网关每 120 秒一轮的
亲和树 LRU 淘汰，把超过「每租户字符上限」的会话叶子清掉；下一回合 match_rate 掉到
阈值以下 → 落进 min_load 并列分支 → 两台引擎 load 相等时**随机并列**把同一会话甩到另一台
→ 该引擎前缀缓存里没有这段上下文 → 整段重新 prefill。表现为「同样一句话直连 200+ tok/s、
走网关掉到几十 tok/s」。

## 直接病灶（一行配置）

生产 compose /data1/app/lua-router-8800/docker-compose.yml 里
`SMG_MAX_TREE_SIZE: "50000"`。这个量的语义是「每个 worker URL（租户）在亲和树里最多保留多少
字符的路由文本」（policies/tree.lua:508 over_limit/evict_tenant_by_size 的 max_size，逐叶子 LRU）。
代码缺省是 67,108,864（config.lua:186）。一个 Codex 回合的 extract_text_for_routing 文本常有
十几万到几十万字符（整段对话历史拼接），**单条就 > 50000**，于是每被插入就在下一拍淘汰里
被弹掉，亲和根本攒不住。

## 因果链（逐环有证据）

1. extract_text_for_routing 把整段 messages 拼成一个长字符串做亲和键（policies/utils.lua:289、
   jsonutil.lua:189 chat_text），route_type=cache_aware 每请求都带这个 text。
2. cache_aware:select_worker 用 `match_rate = matched_chars / input_chars` 与 `SMG_CACHE_THRESHOLD`
   （生产 0.2）比较；命中才按 tenant URL 定位、否则走 min_load 并列随机（policies/cache_aware.lua:217-247、
   utils.lua:443 min_load_index / :428 choose）。
3. 定时 sweep_standalone → evict_all → 每树 evict_tenant_by_size(max_size=cfg.max_tree_size,...)
   按每租户字符数做叶子 LRU 淘汰（policy.lua:870-890、tree.lua:512）。max_size=50000 时，
   一个 >50000 字符的会话叶子属于「必然超标」的那批，每 120s 被弹。
4. 弹掉后该会话前缀从树里消失 → 下回合 matched_chars≈0 → match_rate≈0 < 0.2 → min_load 分支
   → 两台 load 读数相等（见下）→ 随机 → 有 50% 概率换引擎。
5. 换引擎 = 该引擎 ninfer context_cache 冷 → cache_n=0 → 整段 prompt 重新 prefill →
   用户侧 tok_per_s 从 150-200 掉到 <50。

### 佐证一：真实流量画像（21.k:8800 /logs，近 1000 条）

- 同一 session 的连续回合，**落在同一台**：中位 74.6 tok/s、cache>0 占 50%；
  **换到另一台**：中位 21.2 tok/s、cache>0 仅 19%（跳一次 = 缓存作废）。
- 主力会话 241 发里 100 发发生了跨实例跳转（41%）。
- prompt 越大越明显：10万+ token 档中位 24 tok/s（全池被跨引擎重 prefill 拖垮）。
- 直连 8034/8035 同一条 prompt：212 / 87 tok/s，且引擎侧 timings 的 predicted_per_second
  （纯解码段）恒 130-235，说明引擎本身没慢，慢在 prefill 与排队。

### 佐证二：决定性 A/B（8801 vs 8802，同一对 8034/8035 引擎，110k 字符长会话）

| 实例 | SMG_MAX_TREE_SIZE | 空闲两轮淘汰扫树后 | 引擎 cache_n |
|---|---|---|---|
| 8801 | 50000（= 生产） | 第一发从 8034 **跳到 8035** | B0=0（重 prefill），B1/B2 在 8035 重新热 |
| 8802 | 未设→缺省 64M | 6 发全程**钉在 8034** | 全程 20460，一次都没冷 |

唯一变量是字符上限。8802 phase-A 之所以一上来就 cache_n=20460，是因为 8801 刚在同一对引擎上
跑热了这段前缀——这恰好反证 8801 的 B0 是被淘汰甩到**冷**的 8035。

## 次要因素（都不是本次「大幅变慢」的主因，但会叠加）

- **min_load 并列随机**：load_with = inflight + external*load_scale/1000（loads.lua:88）。两台 ninfer
  引擎 discovery=proc、engine=openai，无本地 /metrics（实测 :8034/metrics 404），外部 GPU-util 走
  Prom 的 host-max（SMG_LOAD_SOURCE=prom，DCGM_FI_DEV_GPU_UTIL）。空闲时外部读数缺失→load 落回
  inflight；两台 inflight 都为 0 时**完全并列**→choose 随机。这放大了淘汰甩引擎的概率（本可粘住
  的那一半也被随机打散）。
- **max_concurrency=10 vs 引擎真实 2**：upstreams 声明 8034/8035 max_concurrency=10，但 ninfer-serve
  是 `--max-concurrency 2`。网关不会替引擎把在途压到 2（capacity 闸按声明值判「full」，10 远未触顶），
  于是第 3 个并发请求在引擎侧排队（引擎 request_log queue_wait p90 达 30-90s）。这是**并发**变慢的
  来源，与亲和跨引擎是两条独立的路。
- **effort 注入 medium**：卡片 default_effort=medium，请求不带 reasoning_effort 时网关填 medium
  （inference.lua:105 apply_effort_policy）。实测同 prompt 不带 effort（引擎默认重思考）比 medium 慢，
  所以这个注入是**帮**用户变快的，不是变慢主因；但 high→medium 的 effort_map 改写值得让用户知情。
- **/v1/responses 入口 400**：走 responses 且请求带 effort 时上游回
  `unknown parameter: reasoning_effort`。但生产 UA（node/Bun/WorkBuddy）全走 chat，responses 的
  400 是本机探针造成的，非生产故障。（若未来有 responses 客户端需注意这个字段名不兼容。）

## 修复建议（都是配置面，不改网关逻辑）

按 AGENTS.md：先上测试实例 8801 验证、用户确认后才推 8800 生产。

1. **提高亲和树字符上限**（治本，直击主因）：
   - `SMG_MAX_TREE_SIZE: "8000000"`（8M 字符 ≈ 单租户可容纳 ~15 个 50万字节的长会话叶子；
     给 Codex 这种超长上下文留足）。节点数维度（max_tree_nodes 缺省 200000）+ 增量淘汰
     （evict_budget）仍在兜内存与烧核，调大字符维度不会重蹈 2026-10-07 那次烧核。
   - 或更直接：**删掉这条 env**，回到代码缺省 67M（8802 就是这么跑的，A/B 证明它不留冷、也没烧核）。
   - 验证：把 8801 的 SMG_MAX_TREE_SIZE 改成 8000000（或删行）→ `docker compose up -d` →
     复跑本仓 script/verify-affinity-eviction.py，期望 8801 phase-B 不再跳引擎、cache_n 不塌 0。

2. **让并发闸与引擎真实容量对齐**（治并发变慢）：upstreams 里 8034/8035 的 max_concurrency 从 10
   改成 2（=ninfer-serve 的 --max-concurrency），或干脆让 discovery 从引擎读。这样全池满时答 429
   让客户端退避，而不是把第 3、4 个请求塞进引擎内部 30-90s 的长队。

3. （可选）**load 感知**：给 ninfer 引擎加 /metrics 或 /v1/loads 自报负载，让 min_load 不再空并列，
   从根上减少「亲和命中却因并列随机被迁走」。短期不阻塞上面两条。

## 现场只读复现命令

见本仓 script/verify-affinity-eviction.py（8801 vs 8802 A/B；只读 GET /logs /workers /metrics +
自造请求，不碰任何配置/容器状态）。

## 关联

- doc/gap-cpu-idle-burn.md：10-07 那次是把 max_tree_size 从「永不触发的 67M」调到 50000 治烧核，
  同时新增了 max_nodes 与增量淘汰；**但 50000 对长上下文业务过紧，今天这侧的反噬即源于此**。
  治标（50000 防烧核）与治本（节点数+增量淘汰防烧核）已都在，字符维度可以安全放宽回去。
- doc/gap-virtual-models.md：入口 1 对多、按入口名一棵亲和树。本例入口名 Q38-Flash-Next 与其唯一
  target 同名模型共用一棵树（requested_model 全是 Q38-Flash-Next），不存在树分裂问题。


## 追记 2026-10-11（同日下午）：引擎侧 KV 留存（ninfer 的类 HiCache）

网关亲和修好后暴露的第二层：长会话空闲 ~4 分钟回来，ninfer 引擎 cache_n=0（8/8 全冷）。
查 lkarlslund/ninfer6000 源码与部署二进制 --help：ninfer 的 context cache 是 device(GPU)+host(DRAM)
两级（对应 SGLang HiCache 的 L1/L2），CLI 七个容量旋钮（docs/serving.md:794-799）：

| 旋钮 | 语义 | 默认 | 现场(改前→改后) |
|---|---|---|---|
| --max-concurrency | 活跃请求数，同时决定 device KV 规模（kv-capacity auto 按 max-context×concurrency） | 1 | 2→2 |
| --device-state-slots | GPU 侧额外 checkpoint StateImage 槽（活跃车道之外） | =concurrency | 2→2 |
| --host-state-slots | 钉到 DRAM 的 StateImage 槽数（**闲置会话驻留数上限**） | 8 | **8→32** |
| --host-kv-mib | host 层 KV 字节容量（MiB，Main+Backend 共享） | 8192 | **16384→65536** |
| --max-private-continuations | 私有 continuation 描述符容量（**能同时留住几条会话**） | 2×concurrency | 4(默认)→**12** |
| --max-shared-prefixes | 引擎级共享前缀描述符容量 | max(concurrency,4)=4 | 4(默认)→**8** |
| --max-long-anchors-per-continuation | 每条续写长锚点上限 | 2 | 2→2 |

要点：
- 实测 server_start 账本：host_kv_capacity 16GiB 时 host 占用峰值 6.03GiB、host_state_slots 占用=8（**饱和**），
  max_private_continuations=4 —— 生产并发活跃会话数超过它，闲置会话的 host 驻留描述符先被挤光，
  这才是"空闲 4 分钟回来 cache_n=0"的直接原因；把 host-kv-mib 从 8GiB 提到 16GiB 并没起作用（当时字节不是瓶颈）。
- host KV 实测是普通匿名内存：容器 memlock 软限只有 64KB 却成功钉住 64GiB——不是 cudaHostAlloc 锁页，
  所以 /dev/shm 与 memlock 都不是约束，真正的预算是主机 DRAM（21.k 空闲 574GB，4×64GiB 绰绰有余）。
  shm_size 8g→32g 属保险性放宽，实测不依赖它。
- 21.k 的 4 台 ninfer（swift gpu4/5、radixark gpu6/7，125B 双卡各占 91.7/95.7 GiB 显存）已于
  2026-10-11 逐台健康滚动（备份 /data/app/ninfer6000/docker-compose.yml.bak-20261011-hikv）：
  --host-state-slots 32 --host-kv-mib 65536 --max-private-continuations 12 --max-shared-prefixes 8。
  四台 server_start 读数确认生效（hostKV=64GiB hostSlots=32 privCont=12 sharedPfx=8），
  引擎健康 200、router /workers 全 healthy、显存占用无变化。
- 复跑 verify-tree-capacity（6 条 60 万字符长会话经 8801、空闲两轮淘汰扫树）验证续留效果。

注：SGLang 侧（q38fn-kv8，8022/8023）不用动——PENNY_HICACHE_SIZE_GB=32 + SGLANG_HICACHE_NIXL_MAX_CACHE_GB=2048
自带 L2/L3（cached_tokens_total{cache_source="host"} 持续计数），这也是"同样被甩机、kv8 不慢"的兜底层。


复验（改后同场景 6x600k 字符会话经 8801、空闲 260s 两轮淘汰）：RESULT switched=0 cold=3/6。
网关亲和 6/6 全部回到原实例（0 跳机，30M 生效）；引擎冷丢失 8/8 -> 3/6。
改后 host 层占用峰值仅 10/32 槽、11/64 GiB（不再饱和）；剩余冷发生在 device 页池
（spill_pages 峰值 ~5700，单条 109k-token 会话占 kv_capacity 393216 的 28%，并发即挤出 GPU）。
再压冷率的下一档：--device-state-slots 2->4（GPU checkpoint 池）或 --host-kv-mib 65536->131072，
属显存预算权衡，暂缓。真实 Codex 流量回合间隔远短于 260s，命中路径已通。
