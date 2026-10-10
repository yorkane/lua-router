# 每服务容量三态：并发上下限 + GPU 利用率上限（gap-worker-caps）

日期：2026-10-01 立项（root 裁定），**2026-10-06 容量语义重设计**（用户裁定）。本轮把「两个上限字段」
换成「三字段 + 三态 + 绿灯优先 + 全池到顶 429」，并让**每服务上限不再看瓦特**。设计书（三条需求的
原始裁定与逐节口径）在 [caps-redesign-2026-10-06.md](caps-redesign-2026-10-06.md)，本文是它的
**实现口径与陷阱记录**；两者冲突时以设计书 + 盘上代码为准。旧的「并发上限 + 功率上限」两字段口径
已被覆盖，本文不再复述。

需求来自「更灵活的模型服务调度策略」（AGENTS.md 项目定位第 1 条），2026-10-06 补上操作员当场说的
三件事：并发要有**下限**（低于它就该优先接活）、上限到顶不该报「服务不可用」而该报「暂时不接单」、
以及**功率不能当容量判据**——21.k 实测八个 sglang 实例的 GPU 功率读数完全相同（整机最热卡口径，
八台同值约 271 W），一个所有实例都读同一个数的指标没有资格区分谁该被摘出候选集。

实现文件（一律「文件 + 函数名」，不钉行号；2026-10-05 的 facade 拆分让旧行号全部漂移）：

- [registry/loads.lua](../lualib/resty/luarouter/registry/loads.lua)：`cap_limit` 与 `util_limit`
  （两把归一尺子，为什么分开见 §2）、`inflight_requests`、私有的 `capacity_verdict`（唯一判定体）、
  公开导出的 `capacity_state`（红绿灯）与 `capacity_exclusion`（硬排除门）、
  `set_gpu_util` / `gpu_util` / `clear_gpu_util`（`gu:` 键的读写）
- [registry/keys.lua](../lualib/resty/luarouter/registry/keys.lua)：`K_GPU_UTIL`（`gu:`）的键格局注释——
  `gu:` 为什么**不能**复用 `xl:` 写在该注释里
- [registry/records.lua](../lualib/resty/luarouter/registry/records.lua)：`add`（三字段只在真声明了才落）、
  `info`（`/workers` 的 `load_state` + 三个上限 + 两个实测读数）
- [registry/discovery.lua](../lualib/resty/luarouter/registry/discovery.lua)：`UPDATE_NUMBER_FIELDS`
  （PUT 白名单含三字段、**不含** `max_power_w`）
- [router/candidates.lua](../lualib/resty/luarouter/router/candidates.lua)：`candidates_for` 的硬排除门 +
  绿灯优先裁剪（`why.capped` / `why.idle` / `why.stepped_aside`）
- [router/forward.lua](../lualib/resty/luarouter/router/forward.lua)：`forward` 的 429 兜底与 503 原文案分支、
  显式 pin 读 `why.stepped_aside`
- [config_store/upstreams.lua](../lualib/resty/luarouter/config_store/upstreams.lua)：`CAP_FIELDS` /
  `cap_normalize` / `cap_clear_value` / protected 行的 caps-only 投影
- [gpu_load/](../lualib/resty/luarouter/gpu_load)：利用率通道的 `parse.util_by_card` /
  `cards.assign_util` / `cards.host_card_utils` / `cards.util_config` /
  `runpass.scan_util_metrics` / `runpass.run_util_prom` / `seams.default_write_util` /
  `export.publish_worker_util_gauge`
- [observability.lua](../lualib/resty/luarouter/observability.lua)：HELP 名册里的
  `smg_worker_capacity_excluded_total` 与 `smg_worker_capacity_preferred_idle_total`
- 设计关联：[gap-gpu-load.md](gap-gpu-load.md)（负载 / 利用率两通道，功率通道 2026-10-09 已移除）、
  [gap-virtual-models.md](gap-virtual-models.md)（绑定与组门）

测试：单测 [test_caps_routing.lua](../test/unit/test_caps_routing.lua)、
[e2e_caps.py](../test/integration/e2e_caps.py)（S1–S8，含 S2 三态、S3/S3b 利用率与逐卡、
S5 全池到顶 429、S5d 声明层边界、S8 caps 跨重启存活）、契约 `caps` 段。
计数由一次全绿门禁日志统一刷新，本文不登记任何数字。

---

## 0. 三条红线（2026-10-01 立项定的，2026-10-06 一条都没松）

1. **上限是选路信号，不是健康信号**：不摘 worker、不改 `is_healthy`、不进熔断、不进 keep-last、
   不进保险丝。颜色只是 UI 徽章 + `/workers` 的一个只读字段。
2. **读数未知 → 不排除**：`gu:` 缺席（监控挂了）绝不能变成容量排除，代价只能是精度。这条决定了
   `gu:` 用 TTL 而不是 last-value-wins、写侧宁可不写也不写 0。
3. **缺省零行为变化**：三个字段全部缺席时行为与 2026-10-01 之前逐字节一致（`max_concurrency`
   缺席 = 不限、`min_concurrency` 缺席 = 1、`max_gpu_util` 缺席 = 不限），而且判定与裁剪在
   「三门全 nil」时**一次 shdict 读都不发**。

## 1. 为什么是「硬排除」而不是负载打分

根裁定 2026-10-01：到了上限的 worker 必须**离开候选集**，即使 `cache_aware` 的亲和树本来要把它留下。
这是一条「不许」而不是「不太想」的规则，所以它的实现位置也不允许是一个可被别的项抵销的打分项。

打分承担不了这件事，原因写在策略自己的代码里。策略自带的负载逃逸（`balance_abs` / `balance_rel`
双阈值、`power_of_two` 的低负载分支）只把「更忙」变成「更不优先」；而 `cache_aware` 命中亲和时按
URL 直接从树里取 tenant、**完全不看负载**（[policies/cache_aware.lua](../lualib/resty/luarouter/policies/cache_aware.lua)
的两个分支都会 `tree:insert` 续亲和）。结果就是「超限但粘人」的 worker 恰好把这条规则想搬走的流量
原样留下：前缀命中得越好，它越不可能被负载项挤下去。

唯一不会与之打架的地方是候选集装配。排除发生在 `router.candidates_for`，在 `policy:select` 之前——
策略看见的是一份已经把 full 成员摘掉的列表，它再怎么排也排不出一个不存在的候选。因此
`policies/` 一字未动，八个策略的 Rust 对拍语义也就没有被动过。

树里因此残留的脏租户不由这里管：策略既有的脏租户清理，加上下一轮亲和重建，会自然把亲和落到存活
候选上。在这一层去动树，等于把选路规则和数据结构的生命周期绑在一起。

还有一件事要说清楚：被排除的 worker 的**健康位与熔断状态不变、不摘 worker、不进 keep-last、不进
保险丝**。这是「这一轮不给它派活」，不是「它坏了」。把两者混起来，一台卡暂时吃满的机器就会被监控
判成故障机，而它下一秒就会回来。2026-10-06 的 429（§5）之所以能成立，正是靠这条分界先把「容量到顶」
与「实例故障」在实现上彻底分开。

## 2. 三个字段：`min_concurrency` / `max_concurrency` / `max_gpu_util`

| 字段 | 单位 | 比较对象 | 谁写的 | 缺省 |
|---|---|---|---|---|
| `min_concurrency` | 个请求 | 本网关在飞计数 `lo:<id>` | 操作员 | 缺席 = 1 |
| `max_concurrency` | 个请求 | 同上 | 操作员（阈值）/ router（读数） | 缺席 = 不限 |
| `max_gpu_util` | 百分数 0..100 | 该 worker 自己那张卡的利用率 `gu:<id>` | 操作员（阈值）/ gpu_load（读数） | 缺席 = 不限 |

**归一是两把尺子，不是一把。** 两个并发档走 `registry.cap_limit`（缺省、空、非数字、NaN、±inf、
`<= 0` 全部塌成 **nil = 不限**；整数档向下取整——2.5 个槽位有「最多 2 个」和「第 3 个也行」两种读法，
「最多 2 个」是两者的安全交集）；利用率档走 `registry.util_limit`，它**不能**复用 `cap_limit`，因为
利用率尺度上 **0 是一个有意义的读数**：`max_gpu_util = 0` 是合法的最严档（有任何新鲜读数即 full），
被 `<=0 → nil` 折叠掉就等于操作员写了一道门、网关替他把门拆了。于是 util 档的「未说」是**缺席或任何
负数**，清除一道存量上限的拼写是 **-1**（`cap_clear_value` 的 per-tier 哨兵），而并发档仍用 0。
利用率档向下取整到整数百分比；非数 / NaN / ±inf 同样是 nil。

配置期校验住在声明层（`config_store/upstreams.lua`），三条路的严格度是刻意的不对称：

- `max_concurrency` 沿用今天的宽读法（控制台一直发显式 0 表示「不限」、2.5 表示「最多 2」，五个读者
  共享同一套折叠，声明层不许单方面把 legacy 拼写变成 400），唯一硬拒的是大于 32 的整数——
  **上限最高 32** 是用户裁定写死的（下限的范围因此是 1..31，给 max=32 留出一个合法拼写）。
- `min_concurrency` 是新字段，没有 legacy 读法要迁就：不是 1..31 的整数就是打错字，**400**。一个被网关
  悄悄丢掉的绿色门 = 操作员以为门关着。上限缺席时它没有门可违反，故合法。
- `max_gpu_util`：负数 / 非数 = 「没说」（nil，与读侧折叠结果一致）；101 或 55.5 这种**不可能是整数百分比**
  的数字 = 打错字，**400**；0 通过（最严档不是缺席）。
- 两者都声明时要求 `min_concurrency < max_concurrency`，否则 idle 与 full 重叠（或反序），池子里的三态
  判定就变成任意的。

判定式全部收在 `registry/loads.lua` 的私有 `capacity_verdict` 里，公开的两个门面读同一份：

```
full  ⟺  inflight >= max_concurrency                        reason = "concurrency_max"
full  ⟺  gu:<id> 存在 且 milli >= max_gpu_util * 10          reason = "gpu_util"
idle  ⟺  非 full 且 inflight < (min_concurrency or 1)
busy  ⟺  其余
nil   ⟺  三门全未声明（一次 shdict 读都不发）
```

整数算术：`gu:` 存的是「百分数 × 10」的毫整数，上限是百分数，所以 `milli >= max_u * 10` 就是同一次
比较而不引入浮点除法——亚 0.1 % 的 gauge 噪声也因此不会改变键的数值类型。

`lo:` 是**本网关自己的在飞计数**，由 router 的 hold/release 用 `shdict:incr` 维护，天然跨 nginx 进程，
也是 `smg_worker_requests_active` 导出的同一个原始计数。`inflight_requests()` 只读 `lo:`，一个加数都不混。
刻意**不**用 `registry.load()`：那是打分通道（在飞 + 外部 GPU 项的混合体），拿混合值去比一个定义在
「请求数」上的阈值，会让「忙但没满」的 worker 撞上一个它本来无关的门槛。

`gu:` 同理**不复用 `xl:`**（用户裁定的直接后果，也是最容易被下一个人「顺手合并」的一条）：`xl:` 被
`load_scale` 折成「在飞请求单位」，那是**打分**不是**准入**。拿利用率上限去比 `xl:`，等于让操作员拧
`SMG_LOAD_SCALE` 这个打分旋钮时悄悄挪动了一道准入门。口径与后果写在
[registry/keys.lua](../lualib/resty/luarouter/registry/keys.lua) 的 `K_GPU_UTIL` 注释里，采集侧见
[gap-gpu-load.md](gap-gpu-load.md)。

**读数未知 → 不排除**（红线 2）。`gu:` 缺席时 util 门**放行**。缺失意味着「未知」而不是 0：
`set_gpu_util` 直接拒收负数 / NaN / ±inf（**只在上方**夹到 1——0 % 是合法读数，21.k 的 dcgm 空载就报
`DCGM_FI_DEV_GPU_UTIL{gpu="0"} 0`；负数是坏 exporter，夹成 0 等于给它发免检牌——一个撒谎的 exporter
会永远「远低于任何上限」）。gpu_load 只在真采到可用读数时才写，采不到就什么都不写、靠 TTL 自然过期
回到 nil——**绝不写 0、绝不沿用上一次旧值**。代价不对称：监控系统挂掉的代价只能是精度，不能是容量；
坏 exporter 被读成「0 % 忙」等于给那台 worker 发免检牌，被读成上一次的高值则会把一个健康服务踢出
候选集。这也是 key 用 TTL 而不是 last-value-wins 的全部理由：TTL 到点自动回到「未知」，
last-value-wins 会把最后一次读数变成永久事实。

**缺省不限同时要保证新旧记录兼容。** 没声明过上限的记录保持改动前的形状——`add` 里三个字段只在可用
上限存在时才落，于是老部署升级后不会凭空长出三个键，判定也不会为它多发一次 shdict 读。
`GET /workers` 里未声明的上限字段同样**缺席**而不是 0：0 会被不懂归一规则的读者读成「零槽位、
永不可选」，而利用率档的 0 恰恰是**最严**的门——控制台必须分得清「不限」和「配了 0」。

配置入口四条齐全，都走 `registry._M.add`（因此四条路径落库形状一致）：`POST /workers`、
`SMG_WORKER_URLS` 种子、watcher 注册、config 声明层（upstreams reconcile）；DP rank 继承基记录。
热改走 `PUT /workers/{id}`，白名单 `UPDATE_NUMBER_FIELDS`（registry/discovery.lua）含这三个字段，
**契约应答是 202 不是 200**——它与 priority/cost 走同一条队列化的更新路径，为它单独造一个状态码会把
契约里 worker_service 那一整段断言拆散。**`max_power_w` 已从这张名单里删除（功率通道 2026-10-09 整体移除）**：PUT 里带它现在和任何
未知字段一样被忽略——契约不再单独为退役键留断言（原「PUT ignored the retired max_power_w」
与「the retired max_power_w is not echoed anywhere」两条 caps 段断言已随通道移除）。

config 声明层删除某项时把值写成该档的**清除哨兵**（并发档 0、利用率档 -1），配合上面的归一，
「删掉这行声明」与「明确不限」在池侧收敛成同一个不限。刻意**只在存量行真带上限时**才发哨兵——
无条件发会让每个没被封顶的 config worker 凭空长出键（形状变化就是这一层承诺要避免的事）。

## 3. 三态判定的唯一归属：registry 判定，UI 只显示

`registry.capacity_state(record, d)` → "idle" | "busy" | "full" | nil，是**唯一**的红绿灯计算点。两个读者：

- `registry/records.lua` 的 `info` 把它输出成 `/workers` 的只读字段 `load_state`；
- `router/candidates.lua` 的绿灯优先拿同一份判定裁剪候选数组。

于是控制台的颜色和选路的决策**不可能各自长成一套定义**。因此有一条硬纪律：**前端不许自己重算**。
（现状 `ui/admin/workers.html` 的三态徽章只读 `load_state`，不认识的值一律呈中性灰；历史上那是
`capExceeded` 的纯前端判定且零测试覆盖，属缺陷而非先例，本轮按设计书废弃。`load_state` 缺席 =
这台实例没声明任何上限 = 无门，呈中性灰，**不许画成绿**：绿是一个判定结论，不是「反正没门」。）

`capacity_state` 天生不计数：它只回一个字符串，唯一计费者是 `router/forward.lua` 的选路那趟经
`capacity_exclusion` 的 counted pass。一个 N 台池子若让两个进程都算都计，同一件事会被记两遍。

`capacity_exclusion` 只对 **full** 返回表（其余一律 nil = 可选），reason 的新拼写是
"concurrency_max"（并发触顶，带 `inflight` / `max_concurrency`）与 "gpu_util"（利用率触顶，带
`gpu_util` / `max_gpu_util`），调用方拿这两个数写 debug 日志与计数。旧的 "concurrency" / "power" 两个
字符串随功率上限一起退役，契约与 e2e 都有反向断言钉它们不再出现。调用方的 pcall 与「谓词缺席 =
没有门」的 fail-open 姿态留在 candidates 侧——被剥掉的单测探针或旧构建必须得到「今天的行为」，
而不是全池被摘。

## 4. 绿灯优先：候选集层面的裁剪，不是第四道门

现门序不变（**健康与池成员 → 白名单/绑定 → IGW 模型门 → 容量硬排除(full) → 组门**），2026-10-06 在
**落地段之前**追加一次子集裁剪：

```
若存活者里有 idle：只把 idle 子集交给策略（黄灯让位），why.idle = 被让位数
否则：原数组整体交给策略（池里最闲的也已到下限，此时黄灯继续接活直到触达上限）
```

三条规矩，各对应一种「听起来一句话、写松了就坏掉」的读法：

- **位置在组门与绑定解析之后**：组入口按一整池定价（一入口一棵树、一个子集），操作员逐候选写的
  绑定名绝不会因为一盏灯被撤销。
- **只有已知的 "busy" 让位**。nil 意味着这台没声明上限或问不到，把 nil 挤走就等于让一台未封顶的
  worker 因为某个封顶的同伴恰好是绿的而饿死——红线 2 说读数拿不到不许损失容量，e2e_caps 的 S2 会
  当场死在那儿（那里未封顶的 Y 必须吃下全部 6 个并发请求）。
- **没有任何 idle 时数组一字不动**：全 busy、全未知、或干脆没人活着。此时黄灯继续接单，这正是用户
  要的第 3 条（「超过下限为黄，仅当池内全黄时继续接」）。

让位**不排除**任何 worker：被让开的成员仍是健康的、仍在它自己的上限之下，只是不如绿的可选。因此它
**不计入** `why.capped`，也不进 429 的判据——429 说的是「每一台都抵在硬上限上」，把一次让位记成一次
cap 会让一个只是在「优先选绿」的池子答出容量耗尽的诊断。计数走独立家族
`smg_worker_capacity_preferred_idle_total`（一次 counted pass 最多一个样本；请求日志的二次读取
`counted=false`，既不计排除也不计让位）。

计价成本被刻意夹住：硬 gate 已经摘掉的候选永远不会被问第二遍；未声明上限的候选**零** shdict 读
（registry 在碰字典之前就对「三门全 nil」短路）；只有真写了 min/max/util 的候选才付一次 `lo:` 读
（配了 util 再多一次 `gu:`）。shdict 句柄是 `registry/keys.lua` 的 `shdict` 里 memo 化的 upvalue，
所以省略 `d` 形参也不额外付一次查找。

被让开的记录留在 `why.stepped_aside` 上，唯一读者是 `router/forward.lua` 的**显式 pin** 分支：
`x-smg-target-worker` 指名实例的请求不是在做负载均衡，不该因为别人绿了就被悄悄改投。它照样被盖上
`healthy` 与 `lr_bound_model`（转发要用），但**不盖** `load`——只有策略读那个字段，而被 pin 的请求
永远走不到策略，于是这些台只付出它们的容量判定那两次 shdict 读。**反向对照**：显式 pin 救不回一个
full 的 worker（e2e_caps S3 钉这条），hard gate 没有逃生口。

## 5. 全池到顶答 429，熔断/不健康仍 503

**用户裁定 2026-10-06 覆盖 2026-10-01 的「全到顶 503」口径**（实现在 `router/forward.lua` 的 `forward`）：

| 情形 | 状态码 | code | message |
|---|---|---|---|
| 全部候选因 `why.capped > 0` 被摘空 | **429** | `no_available_workers` | `No available workers (N at their concurrency or GPU-util limit)` |
| 熔断打开 / 巡检判下（健康但不可用） | 503 | `no_available_workers` | `No available workers (all circuits open or unhealthy)`（原句一字未动） |
| 组入口被健康引擎一致拒绝整组模型名 | 503 | `no_available_workers` | `No available workers (N healthy engines serve none of the mapped models)` |
| 空白名单把候选清成空集 | 503 | `no_available_workers` | 原句（不带 cap 措辞，e2e 有反向断言） |

理由（写进代码注释，用户裁定 2026-10-06）：容量到顶不是「服务不可用」，是「暂时没法接单」。中途任何
时候有别的实例可接就转过去——hard gate 与绿灯优先保证了这一点，只有整组一个不剩才落 429。这也让
客户端的重试语义与真实原因对齐（429 可退避重试，503 常被当宕机），并与本机并发闸（`limit.lua`）对
超限请求答 429 的姿态一致。

`code` 刻意仍然钉在 `no_available_workers`：契约与 UI 的键都挂在这个码上，改动面最小；`error.type` 随
状态码走（"Too Many Requests"，见 `router/respond.lua` 的 STATUS_TEXT），message 精确匹配（契约 caps 段
与 e2e_caps S5 各钉一条）。

**也不放宽**：既不排队等槽位，也不回退到超限 worker。回退会恰好复现这套上限要消除的行为，而且是在
负载下复现——那正是它最疼的时候。

## 6. 功率通道的退役与移除（历史）

退役的是**判定**，随后整条通道一并移除。

退役的理由（2026-10-06 实测，21.k 生产）：八个实例的 GPU 功率读数完全相同（约 271 W）。这是 `pw:` 的
**整机最热卡口径**的必然结果——引擎进程看得见整机所有卡，折叠规则取最大，同机 worker 就共享同一
读数。一个把所有实例都读成同一个数的指标，在「这一台到顶了、那一台没有」这个问题上**零区分度**：
给它配上限，等价于给同机全部实例同时按下限（[deploy-fleet.md](deploy-fleet.md) 的功率上限一节留了当时的
真机证据：给三台配 `max_power_w=50`（实测 95.98 W）→ 三台一起被摘）。2026-10-04 的 342.371 事故
（[gap-session-2026-10-04.md](gap-session-2026-10-04.md)）是同一口径的另一面：查询把 `gpu` 标签聚合掉，
八台共用一个数，长期无人察觉。

换利用率而不是继续换阈值：DCGM 的 `DCGM_FI_DEV_GPU_UTIL` **带 `gpu="0".."7"` 标签**，能逐卡区分，于是
「谁的卡忙」变成可判的问题。采集侧的口径与陷阱见 [gap-gpu-load.md](gap-gpu-load.md)。

**旧配置的处理**：声明层里还写着 `max_power_w` 的行，解析时**按未知字段直接丢弃**
（功率通道 2026-10-09 移除后，退役期那套 warn-once 逻辑也一并删了；历史上它必须先 warn-once
再丢，因为 `current()` 每请求重解析整份快照，逐条 warn 会把 error.log 写满），
`/config` 的 GET 如实不返回它，容量判定不读它。
**不做迁移**：新字段里没有与瓦特等价的东西，替操作员猜一个瓦特→利用率的换算等于替他决定一道门开多大。

**2026-10-09 用户裁定**把剩余的观测链（`pw:` 键、`lr_gpu_load_power_*` 六族、`/workers` 的 `power_w`
字段、`SMG_LOAD_POWER_*` 三个 env）一并移除；本节保留的是退役决策的推理记录。

## 7. 逐卡归属与「读数未知」在这里怎么落地

容量判定读的是 `gu:<id>`，而 `gu:` 的写入要回答一个不 trivial 的问题：**这个 worker 的读数是整机最热的
那张卡，还是它自己那张卡？** 答案不靠猜（四路口径的唯一判定点在 `gpu_load/cards.lua` 的 `assign_util`，
注释即口径）：

- 源本身没有逐卡标签（node_exporter、操作员写成 `by (Hostname)` 的查询、只报一个整机 gauge 的引擎）
  → 整机最热卡的利用率，**与改动前逐字节一致**，因为这是老数据源唯一可能的口径。「老源」的判据取自
  **源**，永远不取自 worker（否则一个不带卡标签的 exporter 会被读成「这个 worker 认不出自己的卡」，
  几种情形塌成一条无法区分的日志）。
- worker 认得出自己那张卡 + vector 里有该卡的 series → 写它自己那张卡的利用率（`util_per_card++`）。这是
  342.371 的修复在利用率侧的对应物：同机八台不再共用一个数。
- worker 认不出卡 → **回退整机 max**（`util_fallback++`）。
- 卡认得出但 vector 没有该卡 series → **回退整机 max**（`util_fallback++`）。

**认不出卡时回退整机 max 是刻意选择**（不是笔误，设计书 §5 钉死）：利用率读「这张卡忙不忙」，整机 max
在它的语义下是**保守方向**（本机有任何一张卡忙就把这台 worker 当忙看，代价是少用一台机器，而不是让
满载的卡继续接新请求）。所以**允许**回退——但绝不允许**静默**：每次回退都进
`lr_gpu_load_util_fallback_total`，与 `lr_gpu_load_util_per_card_workers` 并排读就是逐卡覆盖率。前者为 0
而后者非 0 = 逐卡归属一台都没接上（卡号没解析出来，或 `SMG_LOAD_UTIL_QUERY` 把 `gpu` 聚合掉了），
这正是 342.371 的处方。

worker 与卡的对应关系由 watcher 供给（`watcher/env.lua` 的 `gpu_from_name` / `gpu_from_cmdline` 与
`watcher/discover.lua` 的 socket→pid→cmdline 标注，经 `watcher/reconcile.lua` 落到台账 `g|<url>` 与记录
`labels.gpu`）：21.k 的八个实例由 compose 从 `SMG_WORKER_URLS` 播种（不带 labels）且首接触即被守卫 3
protect，而卡号写在**容器名**里（`qwen38-27b-dflash-tgt-gpu0` 在 8012、`pennyroyal-orca-gpu1` 在 8021、
`q38fn-pennyroyal-gpu2..7` 在 8022–8027），所以本轮让 watcher 从容器名解析并**补** `labels.gpu`。它是纯
label：不进排除、不进摘除、不进探针、不进宽限，**已有值绝不覆盖**，也不 bump generation（那会把前缀
亲和一起打掉）。管理台上它就是实例名后的 GPU 徽章。

TTL 沿用负载口径：`cfg.load_stale_secs`（`SMG_LOAD_STALE_SECS`，0/未设 → `3 × SMG_LOAD_INTERVAL_SECS`，
缺省 interval=15 ⇒ 45 s），`registry.stale_ttl` 再夹到 5..3600。TTL 是全部的清理机制：过期即回到 nil，
不需要清扫定时器。

## 8. 可观测性

`smg_worker_capacity_excluded_total{reason="concurrency_max"|"gpu_util"}`：**只在选路那一次调用计数**。
`candidates_for` 同一个过滤器会被响应后的请求日志二次调用（用 `counted` 形参区分），二次读取不计账，
否则每次请求把排除计两遍，计数就读不通了。两个 reason 是不同种类的量（本网关自有的请求数 vs 外部
采到的利用率），所以一条 HELP 同时点名两者，免得 Grafana 图例把这一族读成一种无差别的故障。

`smg_worker_capacity_preferred_idle_total`（2026-10-06 新增，Lua 独有超集）：发生绿灯优先让位的选路
pass 数。它**刻意不是**上面那族的一部分——「池子拒绝了流量」与「池子另有偏好」是两件必须分得开的事。

利用率家族（只在启用时渲染；`SMG_LOAD_SOURCE=none` 时连定时器都不跑，缺省关闭的实例一个 series 都不写）：

| 指标 | 类型 | 含义 |
|---|---|---|
| `lr_gpu_load_util_samples_total` | counter | 写进 `gu:` 成功的利用率样本数 |
| `lr_gpu_load_util_parse_failures_total` | counter | 拨通/查询发出了却拿不到可用读数（正文无 gpu-util gauge / 响应非合法向量 / registry 还没有 `gu:` 读者） |
| `lr_gpu_load_util_rejected_total` | counter | registry 主动拒收（近乎恒 0，非 0 = exporter 在撒谎） |
| `lr_gpu_load_util_unmatched_total` | counter | 命名了「池里没有 worker 的机器」的 series 数 |
| `lr_gpu_load_util_fallback_total` | counter | 整机 max 回退次数（不做静默降级） |
| `lr_gpu_load_util_workers` | gauge | 有新鲜利用率读数的 worker 数 |
| `lr_gpu_load_util_per_card_workers` | gauge | 其中真正按自己那张卡拿到读数的台数（与上一行的差 = 覆盖率） |
| `lr_gpu_load_util_gpu{worker="url"}` | gauge | 该 worker 的 0..1 纯利用率（准入门的数据源） |

**`lr_gpu_load_util_gpu` 与 0..1 的 `lr_gpu_load` 分族**是刻意的：后者是打分（`xl:`，被 `load_scale` 折进
在飞请求单位），前者是准入判定的数据源（`gu:`）。今天两族读的是同一批 gauge，但口径与生命周期各自
独立（`xl:` 的名册含 KV-cache 用量，`gu:` 刻意不含），画在同一个 series 名下会让人以为「打分与准入看的
是同一个数」——那正是本轮要拆开的两件事。

Rust 侧没有每服务容量这个能力，`smg_worker_capacity_*` 是 **Lua 独有超集**，对齐 Rust 时不许把它「对齐掉」。

## 9. 与其它子系统的相互位置

- **与 cache_aware**：见 §1 与 §4。排除与让位都发生在候选集装配，不动亲和树，不改 `policies/`。
- **与熔断 / 健康**：容量决策不碰健康位、不碰熔断计数。因超限被排除的 worker 在 `/workers` 里仍
  `is_healthy=true`——这是「这一轮不给它派活」与「它坏了」的分界，也是 429 与 503 可区分的原因。
- **与 429 并发闸**：`limit.lua` 的全局闸门管「本网关同时接多少请求」（超限 429 空体、可排队），每服务
  上限管「某个实例还能不能进候选」。全池到顶的 429 与闸门的 429 是两套计数、两条路径，共同的姿态是
  「超限就明确说不接单」。**没有**「等一个槽位释放」的语义：需要削峰平滑的负载应该配并发闸 + 上游
  重试，而不是靠 `max_concurrency` 兜。
- **与多绑定**：同一 worker 在 `candidates` 里绑两个不同模型由 config 层拒绝 400
  （`config_store/profiles.lua` 的 `build_candidate_bindings`：重复提交同一模型静默去重）；容量上限按
  **worker** 计、不按绑定计——同一实例被两个 alias 共用时，两个 alias 共享同一个在飞计数。限的是真实
  资源（一个进程、一张卡），不是一个名字。
- **与 IGW 的分工**：显式绑定是操作员点名，不受探针背书否决（绑定存在的意义就是用引擎未必携带的名字
  寻址该实例）；IGW 只收窄**未绑定**候选。
- **与 effort/ctx 卡片**：per-attempt 按 `router/candidates.lua` 的 `card_key_for` 解析，绑定名优先——同一
  alias 落到两台实例时，不能一个拿 A 的卡一个拿 B 的卡。容量不参与卡片解析，卡片也不参与容量判定。
- **与组门**：绿灯优先在组门之后按「整组一池」定价（§4），所以一个跨两个模型的入口不会分裂成两棵树
  各自的半池。

## 10. UI 与配置面

两块能力都按 AGENTS.md 重点 3/4 落到可视化与 JSON 面，不是只给 env：

- `ui/admin/workers.html`（服务池，规范入口 `/`（站点根））：**状态列**的第二枚徽章读 `load_state`（idle 绿 /
  busy 黄 / full 红 + 满员图标；缺席 = 中性灰），**capacity 列**两段——第一段并发区间 `min–max`
  （min 缺席按 1、max 缺席 = 不限），第二段 GPU 利用率上限（0..100 整数百分比，缺席 = 不限），每段后面
  跟只读的实测（`inflight_requests` / `gpu_util`）。阈值与实测分行且视觉区分：实测一旦被当成配置回写，
  就等于让监控采样替操作员改选路规则。读数为 nil 显示「未采集」而不是 0（缺席 = 未知；显示 0 会把
  「没采到」渲染成「远低于上限」）。实例名后的 **GPU 徽章**读 `metadata.gpu`（数据源就是 `/workers`
  的记录，零新增请求），无该 label 时不显示。
- 三个对话框（add / decl / edit）的容量区：并发下限（预填 1，必填 1..31）、并发上限（预填 8，必填 1..32，
  须 > 下限）、GPU 利用率上限（0..100，可空 = 不限），并排两列省垂直空间。表单三态与后端归一严格对齐：
  **并发档**空串 = 省略、`0` = 清除、`>0` = 设定；**利用率档**空串 = 省略，`0` = 最严档而不是清除。
- `cap_owner === 'declared'` 的行（声明层是上限的事实来源）隐藏运行态编辑入口，归属与漂移在 capacity
  列以徽章显形，理由见 [gap-pool-merge.md](gap-pool-merge.md)。
- `ui/admin/logs.html` 的日志页同期改造（2026-10-06）：inflight / 窗口请求·错误 / 缓冲三卡合并成一条
  紧凑统计条，腾出的整块给**输入/输出 tok/s（60s 均值）**大字卡；列序改为「时间 → 状态 → …… → CACHE →
  模型」；刷新零抖动（`:loading` 只在首屏空表时进、非首屏失败不清空 rows、cursor 无变化跳过整段替换、
  轮询定时器在 SSE 连上后降档）。
- `/config` 的 JSON 视图无损读写三字段（含 protected 行的 caps-only 投影）；退役的 `max_power_w` 在
  GET 里如实不返回（该字段与整条功率通道已于 2026-10-09 移除）。

## 11. 已知限制与残余缺口

1. `disable_health_check` 的 worker **永不进 discover**，因此永不经 `refresh_models`，永远不会获得引擎
   背书（`models_verified` 不会为真）；它要多模型绑定只能靠 config 行显式声明 `models`，而那只是备注、
   不构成否决依据。
2. watcher 注册当刻只交 `models[1]`（`watcher/reconcile.lua` 里三处取 `entry.models[1]`），全量覆盖靠下一
   轮 `registry.refresh_models` 补齐；预算：薄列表每轮问一次、上限 `MAX_MPROBE` = 20 次，完整列表按
   `MODELS_REFRESH_COOLDOWN_SECS` = 300 s 冷却。
3. **mesh 集群视图不同步 `models` / `models_verified` 与三个上限**：`mesh/crdt.lua` 的 `observe_worker`
   只镜像 `{worker_id, model_id, url, health, load}`，对端 `GET /ha/workers` 看不见这些字段。上限是
   **每网关独立**的（在飞计数是本网关的，利用率是本网关采的），跨网关不聚合——两个网关各看一份在飞数、
   各摘各的候选，这是当前形态，不是待修的 bug。
4. 手工 `POST /workers` 与 `SMG_WORKER_URLS` 种子进来的行属 protected（`discovery ~= config`），watcher
   不摘；严格探针的确定性否定对它们同样不生效——这是「手填配置不能凭它判死一个健康实例」这条红线的
   延伸。**但红线保护的对象是「身份与健康判定」**——discovery、`is_healthy`、探活结论、判死逻辑，以及
   `model_id` / `models` 这两份引擎读数，声明层一个字都改不动。**它不覆盖调度旋钮**：三个上限字段
   **允许**投影到 protected 行（`config_store/upstreams.lua` 的 caps-only 分支，2026-10-05 提交 `3728821`
   立的口径，本轮把字段名册换成三字段）。理由是 caps 从不判死、只在超限时把请求迁走，下发它们不触碰
   「不能凭配置判死健康实例」这件事；而在此之前 protected 行整行不许碰的落地口径，会让操作员**没有任何
   能活过重启的上限配法**（e2e_caps S8 钉「caps 跨声明层与跨重启存活」）。

   **控制面设的上限现在也持久化（用户裁定 2026-10-09，推翻本节旧口径「上限只进内存 shdict，重启即
   蒸发」）。** 旧口径不是 bug，是当时只做了声明层那一半：`PUT /workers/{id}` 与 `POST /workers`
   只写 `lr_workers`（全仓零落盘路径），容器一重建就由 `SMG_WORKER_URLS` 重新播种成裸记录，操作员在
   服务池页那个「编辑 worker」弹窗里填的并发/利用率上限当场蒸发。现行做法是**镜像**：控制面写成功
   后，把 body 里显式出现的三档上限行级 upsert 进声明层的 `upstreams` 段（`config_store.apply_upstream_caps`），
   重启后由 reconcile 的 protected 分支（`upstream_caps_only_patch`）原样贴回。要点四条：

   * **只镜像、不认领**：镜像行只有 url 加三档上限，reconcile 因此走的是 caps-only 分支，protected 行的
     `discovery` / 身份 / 探活结论一个字都不动。判据 `caps_only_row`（`config_store/upstreams.lua`）刻意把
     **默认值视为没说**——`snapshot_of` 会给每一行物化出 `priority=50` / `cost=1.0` / `labels={}` /
     `disable_health_check=false` / `api_key_state="keep"`，落盘一次之后镜像行看着像"什么都写了"，按原始键
     是否存在来判就会当场认不出，清理链静默失效（`test/unit/test_caps_persist.lua` 第 3 节用真磁盘往返钉死）。
   * **尽力而为的写，绝不让 202 变 500**：内存更新才是 202 契约钉住的那一半（Rust 版压根没有落盘层），
     所以镜像失败（CAS 被拒、存储不可用、值被校验挡下）只写一条 WARN 让它显形，响应体保持
     `{status,worker_id,message}` 逐字节不变，内存里已经生效的上限也不回滚。失败的后果是窄而诚实的：
     这道门现在有效、但活不过重建。
   * **删除即清除 + 孤儿不复活**：`DELETE /workers/{id}` 连带摘掉**纯镜像**行（带别的操作员字段的声明行
     保留——删一个活 worker 是池操作，不是抹掉人家声明的许可证）。只靠删除钩子不够：探针摘行走
     `watcher/live.lua` 的 `make_unregister`，它直接调 `registry.remove`、不经过控制面，留下的孤儿镜像会被
     reconcile 的 add 分支当成"操作员新建的一条声明"建成 `discovery="config"` —— 既复活又翻归属。因此 add
     分支现在对 caps-only 行**沉默**（计入 skipped），这条守卫是主、删除钩子是补（e2e_caps S9 把两条各自
     钉一遍：孤儿镜像不复活，与删 worker 后 `GET /config` 里不留残行）。
   * **归属反过来也成立**：`discovery=="config"` 的行**不走镜像**。控制面 PUT 改的是运行时读数，声明层
     那个数保持操作员写下的值 —— 若让 PUT 顺手改了声明，`upstream_patch` 的清除哨兵会在下一次自愈时
     反过来把闸门静默打开。这条拒绝同样只在日志里显形（`caps mirror skipped`），202 不变。

   caps 那侧的旧纪律不变：**只下发不清除**（从声明里删掉一个上限不会立刻摘掉存量上限，下次重启自然
   消失，要当场摘用 `PUT /workers/{id}` 写该档的清除哨兵：并发 0 / 利用率 -1）。镜像因此也不引入新的
   清除语义——它写的就是控制面那次 PUT 的读时归一结果（并发档过 `declared_cap`、利用率档过
   `declared_util`，两档不能共用一个归一器，理由见本文 §1）。身份红线一个字没动：caps 从不判死，
   `registry.update` 里那道 `discovery == "config"` 的门仍替所有非 config 行挡掉身份字段。
   验证：`test/unit/test_caps_persist.lua`（判定层，70 checks）+ e2e_caps S9（端到端，37 checks，
   含真 `docker restart` 后「上限当场真的挡住流量」的流量判据）。
5. `registry/records.lua` 的 `all_models()` / `worker_models()` / `record_models()` 目前**暂无消费者**。
   写了但没接线这件事要登记在这里，别让人以为已经有读者。两条模型列表链各自用的是：对外
   `GET /v1/models` 走 `models()`（Rust 对拍钉住的那一列，`router/models_api.lua` 的 `models_handler`）；
   管理台 `GET /u/v1/models` 走 `ui.lua` → `props.http_workers()`。两者都不吃上面那三个 reader。
6. 全池到顶是 **429 而非排队**（§5）：没有「等一个槽位释放」的语义（与并发闸门的排队能力是两套东西）。
7. `lr_workers` 2m 容量竞争：`gu:` 写失败只在 `set_gpu_util` 的 shdict 写分支
   WARN 一行，后果是该 worker 在该采样 TTL 内退化成「无上限」。方向仍是「宁可少一层保护，也不因监控
   自身抖动丢容量」，但它意味着容量告警要同时看 `lr_workers` 的占用。
8. **利用率三个 env 走 `config.lua` 装配**（全表见 [gap-gpu-load.md](gap-gpu-load.md)）：
   `SMG_LOAD_UTIL_ENABLED` / `_QUERY` / `_KEYS` 在 fork 前解析，天然进 `/probe/config`，
   三份 conf 的 env 声明只是给 `util_config` 的 `os.getenv` 兜底分支放行，两条路都通。
   （功率那三个 env 随通道已于 2026-10-09 移除，当年的「没进 config.lua」欠账一并销账。）
9. **利用率准入门是逐卡的，但「哪张卡归谁」目前只有 21.k 这一种已验证形状**（容器名带 `gpuN`，或命令行
   带 `--device-id` / `CUDA_VISIBLE_DEVICES`）。两者都不带的部署，逐卡归属只能靠 `lr_gpu_load_util_fallback_total`
   显形——覆盖率看 `lr_gpu_load_util_per_card_workers` 与它的差；覆盖率不是 100 % 时利用率上限仍生效，只是
   读的是整机最热卡（保守方向）。

10. **单 worker 的 gauge 序列不随 worker 消失（既有设计特性，本轮利用率 gauge 继承了它）**：
    `observability` 的 gauge 没有 TTL 也没有删除原语——`observability.gauge` 就是 `lr_stats` 上一次
    `set("g|<metric>|<label 串>", value)`（不带 TTL），导出口 `prometheus_text` 又按 `get_keys(0)` 全量枚举，于是
    worker 被 `DELETE /workers/{id}` 或 watcher 摘除之后，它名下的 `lr_gpu_load_util_gpu{worker=...}`
    序列会**永久**留在 `/metrics` 上。本轮在 21.k:8802
    实测到：已经删掉的 mock（端口 18301–18303）序列仍在导出，label 里的 worker 名也还在。
    这不是本轮新引入的缺陷——util gauge 沿用了 observability 从一开始就有的那套导出机制。
    **影响**：`/metrics` 面板会累积僵尸序列，按 worker 聚合或做 topk 的图会被陈旧 label 误导（一个
    已经不存在的实例仍然带最后一次的读数占位），长期跑下来序列数只增不减。转发面不受影响：判定读的是
    `gu:` / `lo:` shdict 键（有 TTL，会自己过期），不看 gauge。
    **建议（后续收，本轮不做）**：给 observability 加一个 `delete_gauge`／prune 原语（按 name + label
    集移除注册项），或在 `registry.remove` / watcher 摘除路径上顺带清掉该 worker 的 util 序列。二者取其一
    即可让面板与在册 worker 对齐（`g|` + metric + label 串的键格局本身可寻址，删除就是显式 delete 那一个键）；
    更彻底的做法是把这类 per-worker 序列改成导出时从 registry 实时派生——注册表不再存量保存，worker
    一消失序列自然消失（`smg_worker_health` 一族就是这么导出的）。那是独立一轮的活，本轮只登记。
