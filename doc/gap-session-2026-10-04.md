# 2026-10-04/05 这一轮的六块改动与踩过的坑

> 给接手重构的 agent。**这一份记录的是「为什么」，代码只记录「是什么」**。
> 21 个提交，门禁 22 门全绿，已部署到 21.k:8801 / 21.k:8802 / 235.t:8800。

## 1. 上下文窗口语义翻转（最容易被下一个人搞错）

时间线：

1. 2026-10-02 用户裁定：虚拟模型条目只允许配 `context_window`，作为**对下游统一的 max_tokens 钳制**。
2. 生产炸了。21.k:8801 上 Codex 长上下文请求稳定 400：
   `175218 输入 + 350000 输出 > 524288`，且 completion 恒为 350000、只有 input 在变。
3. 根因：`apply_ctx_cap` 的字段表只有 `{max_tokens, max_completion_tokens}`，**漏了 `/v1/responses`
   用的 `max_output_tokens`**。走 responses 入口时 `body.max_tokens` 恒 nil，命中「nil 就凭空写入 cap」
   那一支，网关替每个 responses 请求造了一个 `max_tokens = 350000`。
4. 2026-10-04 用户**亲自推翻**该裁定。

**现在的三概念分离**：

| 概念 | 谁负责 | 网关动不动它 |
|---|---|---|
| 引擎上下文窗口 | SGLang 启动参数 | 不动 |
| 对外声明窗口（`context_window`） | 操作员声明，供客户端决定何时压缩 | **不参与任何 max_tokens 计算** |
| 单次输出预算 | 调用方给，网关不代填、不改写 | 原样透传 |

配了 `context_limit`（模型卡片，= 服务真实能力）时，配置期校验 `context_window < context_limit`，
违反**拒绝保存**。组内多个 `context_limit` 取**最小值**判定（一组由入口不控制的引擎提供）。

相关：[gap-virtual-models.md](gap-virtual-models.md)。

## 2. `/v1/models` 的形状

**官方标准只有四个字段且全部 required**：`id` / `object` / `created` / `owned_by`。
我们之前**漏了 `created`**，是不合规，已修。

`capabilities` / `reasoning_effort(s)` / `max_output_tokens` **都不是官方字段**，是 vLLM、opencodex
这类服务器自加的生态扩展，放在 `capabilities` 命名空间里与官方四字段物理隔离，官方 SDK 只读它认识的。

四个 `supports_*` 位（tool_use / streaming / reasoning / vision）+ 顶层 `supports_reasoning_effort`
**全部可配**，三态（true / false / **键缺席**），优先级 **config 声明 > 引擎自报 > 整个键省略**。

**三态必须逐分支判，不能写 `declared or engine`**——Lua 里 `false or engine` 取的是 engine，
操作员明确说的「不支持」会被引擎的 `true` 顶掉。

虚拟入口的组内聚合：数值取最窄、支持位要求每台一致、picker 要求序列完全一致、判定面取交集，
**任何一支凑不齐就删键**。`models_virtual_only` 开关**只影响对外广告，不影响路由**。

相关：[gap-virtual-models.md](gap-virtual-models.md) §5。

## 3. effort 三层继承

卡片 → 虚拟条目 → 全局，**逐字段、逐 from 查表**，第一个命中的赢。

旧实现是「卡片一存在就整层屏蔽全局映射」——同一份全局映射，对配了卡片的模型无效、对没配卡片的模型有效。
这是真 bug，已修。

`default_effort` **允许为空 = 完全不覆盖**（网关一个字都不动，交给引擎自选）。
`effort_map` 是**无论 default 空不空都生效**的映射。

## 4. per-GPU 功率

生产现象：8 个 worker 的 `power_w` **全是 342.371**，而真实 GPU 功率是 94/84/284/208/89/94/431/95 W。
`power_of_two` 与 `max_power_w` 硬排除全靠这个信号，零区分度 = 失效。

根因是 PromQL 的 `max by (Hostname,instance)` **把 8 张卡折成 1 条 series**。改成
`max by (Hostname, instance, gpu)`。per-GPU 数据本来就在（DCGM 逐卡带 `gpu`/`UUID`/`pci_bus_id`），
**不需要新 exporter、不需要改部署**。

**严格降级**：认不出卡 / 该卡无 series → **不写键**，回落「未知 → 不排除」。
**不回落整机 max**——源已逐卡时，整机 max 就是**邻居那张卡**的瓦数，写进来等于让空闲 worker 因
邻居满载被排除。代价是认不出卡的 worker 不受功率上限约束，可观测靠 `lr_gpu_load_power_per_card_workers`。

## 5. worker caps 跨重启

`max_concurrency` 配了重启就没。**不是被清掉，是从来没进过任何持久层**：worker 记录只活在
`lr_workers` 内存 shdict，`SMG_WORKER_URLS` 播种只传 url。

第二层更隐蔽：声明层也救不了。两道闸门叠加——`registry.add` 遇已存在 url 直接 return；
`config_store.reconcile` 只碰 `discovery == "config"` 的行，env 播种的行是 `dynamic`/nil，整行跳过。

**裁定**：protected 行现在允许**调度旋钮**（caps）投影，但**身份与健康判定仍受保护**。
旧表述「protected 行整行不许碰」是落地时的过度收紧，会让下一个人继续绕开 caps，而红线原意只是
「手填配置不能凭它判死一个健康实例」——caps 根本不判死，只在超限时迁走请求。

相关：[gap-worker-caps.md](gap-worker-caps.md)。

## 6. 配置存储层

见 [gap-config-store.md](gap-config-store.md)。

## 7. 这一轮踩过的坑（不看文档一定会重犯）

**模板引用了但 setup 没导出 = 整块 UI 静默消失。** Vue 对 undefined 调函数抛 TypeError，
界面上没有任何提示。`fmtOne` 漏导出让日志页顶部少了一张卡。**这个坑一个人踩了三次**，
是本仓最反复的 UI 故障模式。改 `ui/admin/*.html` 时**必须**跑「模板标识符 ⊆ setup return」差集自检，
更该加一条 CI 门禁。

**在裸 luajit 里探测 cosocket 模块必然得到假阴性。** `pgmoon` 曾报「缺 luafilesystem 的 `mime`」，
实际那条 `require("mime")` 只在**无 `ngx` 全局**的 else 分支里执行，而那次探测就跑在裸 luajit 里。
真实 OpenResty 环境下 `require pgmoon` 成功。

**「必须先核实可行性」这个任务书措辞会让 agent 真的只做核实。** 同一条线上连续三个 agent 停在
可行性报告、没写一行实现。改成「结论若为不可行，说明原因即可、**不必写代码**；若可行，
**继续写完、验完、提交完再回报**」，并显式写「**不要中途发进度消息**」。

**`send_message` 只投递不唤醒。** 目标 agent 停在 completed 态时，消息会静静躺在收件箱里永远不被执行。
要继续干活必须用 `followup_task`。而且**第二次只发进度就结束时，换个新 agent 比催第三次有效**。

**LuaJIT 是 5.1，没有位运算符。** 摘要函数用 djb2 而不是 FNV（`~` 编不过）。

**χ² 检验的期望与 N 无关。** `E[χ²] = df = k-1`，所以 `P(χ² > 5.991) = 5.00%` 是个常数，
**加大 N 一分不减**。原口径「没超临界值 = 退化成立」是无证据即无罪。改用 TOST 等价性检验。
选等价边界 d 要按**实测到过的最差真实行为**定，不是按统计最优。

**并行化门禁是可行的。** `GATE_JOBS=N` 把 22 门从 822s 压到 387s（2.12 倍），全量档实测 22/22 绿。
三门必须留串行：`e2e_watcher`（拍 docker 端口快照再拼排除表）、`mesh_two`（18 秒稳定窗内验名册）、
`e2e_tls_chain`（硬编码 31337）。**缺省不设 `GATE_JOBS` 时行为与原来逐字节一致。**

**长任务用 `setsid nohup ... &` 启动。** 用户输入会打断会话并带走子进程——门禁跑到一半被杀过两次。
