# 流经 token 核算：stream_options 注入 + usage 帧剥除 + 四路 token 指标

> 范围：`router/forward.lua`（转发泵 / 注入判定 / SSE 帧切分与剥除 / 400 兜底）、
> `router/jsonutil.lua`（`merge_top_object` / `sse_split` / `sse_event_droppable` /
> `usage_from_object` / `usage_from_chunk`）、`router/reqlog.lua`（log 相位记账）、
> `observability.lua`（`smg_router_tokens_total` 四类 token_type、
> `smg_router_usage_injection_total`）、`test/unit/test_integration.lua`（第 6 节）、
> `test/integration/e2e_token_accounting.py`、`test/mock_llm_worker.py`（流式 usage 形态开关）。
>
> 核心原则（本文一切取舍的出发点）：**网关不做 BPE**。精确值只来自后端自报的
> usage；事前预估、启发式计数一律不做（见 §8 已知限制）。网关要做的只有一件事：
> 把「客户端没要、后端因此也不发」的那帧 usage 拿回来，再把它从客户端流里
> 原样拿掉。

## 1. 缺口是什么

`usage_from_object`（router/jsonutil.lua，本仓库既有）早已能读后端自报的
prompt/completion/cached/reasoning（含 `prompt_tokens_details.cached_tokens`），
TTFT/TPOT/generation duration 指标也在（observability.lua 的 `smg_router_*`）。
非流式没有缺口：响应体整体缓冲，usage 就在 JSON 里。

缺口只在流式：OpenAI 兼容引擎（vLLM/SGLang/llama.cpp 的 /v1 面）只有在请求体带
`stream_options.include_usage` 时才发 usage 帧。普通客户端不设这个字段——于是
每一条流经网关的 chat/completions 流都以 byte/4 估算收尾（`tokens_estimated: true`），
计数器报的是网关的猜测而不是引擎的账。只有显式带 usage 的评测客户端才给得出精确的
cached/prompt 比值；生产客户端不带这个字段，精确性就整体蒸发。

## 2. 方案总览（三件事，全部在 `forward()` 一条路径上）

1. **注入**：请求满足「`stream:true` ∧ 路由 ∈ USAGE_ROUTES ∧ 客户端自己没要
   include_usage」时，转发体经 `merge_top_object(payload, "stream_options",
   "include_usage", true)` 补上该字段。字节保持（byte-preserving）编辑，客户端
   其余字节一个不动。
2. **捕获 + 剥除**：转发泵 `stream_response(..., strip_usage)` 把上游字节先喂给
   usage 扫描器（`note()`），再按 SSE 事件边界切帧；判定为「纯 usage 帧」的帧
   只进账、不出客户端。判定权在 `sse_event_droppable`（§4），宁漏剥不误剥。
3. **指标化**：泵返回的第 3–6 值（prompt/completion/cached/reasoning）连同
   「是否真剥掉了一帧」（第 7 值 `usage_stripped`）经 `ngx.ctx.lr_tokens` /
   `ngx.ctx.lr_usage_injection` 流到 `log_inference_request`，喂请求日志行与
   两个指标家族（§6）。

判定「客户端自己没要」的是 `client_wants_usage(body)`：只有 `stream_options`
是对象且 `include_usage` 为真值才算。显式 `false`/`null` 按「没要」处理——注入
并剥除后客户端看到的字节与它自己发起时一致（该帧本来就是它声明不要的）。

## 3. 注入的字节语义（merge_top_object）

`set_top_field` 只会顶层精确插入/替换，嵌套场景需要合成，规则（单测 6.1–6.8 钉死）：

| 客户端请求体现状 | 结果 |
|---|---|
| 没有 `stream_options` | 顶层插入 `"stream_options":{"include_usage":true}`，其余字节逐字保留 |
| 有对象、无 `include_usage` | 对象内合入该成员，兄弟成员（如 verbose）活着 |
| 有对象、`include_usage` 为 `false`/`null` | 改写为 `true` 并回报 changed（随后按「没要」剥帧） |
| 有对象、`include_usage` 已为真值 | `client_wants_usage` 先行短路：一个字都不改，帧归客户端 |
| `stream_options: null` | 视作「无选项」，填入对象 |
| `stream_options` 不是对象（字符串/数字） | 放弃注入：覆盖客户端为该名字选定的类型不是网关的权利 |
| 深层嵌套里同名 `stream_options` | 不受影响（`top_member_span` 的深度语义） |

嵌套编辑复用 `set_top_field` 于对象子串（其深度行走从该子串自己的首括号重启）；
判定「要不要改」以返回文本是否变化为准，杜绝「改了但客户端没要求」的静默改写。

## 4. 剥帧判定与 SSE 帧边界

### 4.1 帧边界（sse_split）

按 WHATWG eventsource：空行闭合事件。实现覆盖真实后端会产生的三种终止符，
最早者胜出——`\n\n`(2)、`\r\n\r\n`(4)、`\n\r\n`(3，header 后写 LF、正文里写
CRLF 的混拼服务)。两个候选不可能同索引打平（第二字节不同），`\r\n\r\n` 恒比
后起一字节的 `\n\r\n` 先赢。**事件文本连终止符一起保留**，泵逐字转发，客户端
重组出的字节（含终止符拼法）与上游完全一致。切剩下的不完整帧进 carry，下一批
字节续切；流终了仍有 carry，原样冲给客户端——吞半帧等于截断正文，比多放一帧
未剥的 usage 恶劣得多。

### 4.2 什么帧才许剥（sse_event_droppable）

一条帧必须**全部可见字节都是核算载荷**才判可剥，任何一条不满足即整帧放行：

- 恰有一条 `data:` 行。多行事件可能同时装着 `[DONE]`，剥掉客户端就等不到结束符；
- 无 `event:`/`id:`/`retry:` 字段。/v1/responses 的帧永远不是「纯 usage」（带
  event: 行的 completed 事件是客户端要解析的协议），带 id 的帧牵涉续传游标；
- 载荷可解码为对象，且 usage（顶层 `usage` 或 responses 形态嵌在 `response`
  下面的那份，`usage_from_chunk` 两种拼法都读）真实可读；
- `choices` 缺省或为空数组；每个元素 `delta` 空、无 `text`、
  `finish_reason` 为 null/缺省。最后这条专防 llama.cpp 形态：它把 usage 焊在
  收尾 chunk 上，剥掉就吃掉了客户端结束本轮所需的 finish_reason。该帧留在流里
  （客户端会见到一个没点过的 usage 对象），改帧内字节属于「改写载荷」，本网关
  不做这种手术。

心跳（`: ping` 注释行）、内容增量、`[DONE]`、不可解码载荷，一律原样透传。
单测 6.14–6.22 把这六类判定逐个钉死。

### 4.3 泵里的执行顺序（为什么剥帧不丢账）

`emit()` 里 `note(text)` 在剥除判定**之前**：上游字节永远先进 usage 扫描器，
无论客户端收不收得到。line 级扫描（含 "usage" 子母串才解码）与 frame 级切分
各司其职；扫描器见到可用 usage 后停机，帧切分器则全程在位——中途改开关会让
「note 已按行看到、帧边界尚未凑齐」的窗口把整帧漏给客户端（写入顺序竞态，
代码注释里有展开）。每批上游块一次 `ngx.print`+`ngx.flush`：逐帧下发会把一框
多帧变成多次往返，改变注入路径的延迟特征。

安全阀 `MAX_SSE_FRAME = 262144`：上游若永不给出事件终止符，carry 会随正文
无界增长并扣住客户端字节；超限即整段原样放行（代价是那一帧没法剥，两害相权）。

## 5. 注入面（USAGE_ROUTES）与不注入清单

| 路由 | 注入 | 理由 |
|---|---|---|
| /v1/chat/completions、/v1/completions | ✅ | OpenAI 兼容流，usage 帧就是为 include_usage 而生的可选项 |
| /v1/responses | ✅ | usage 藏在 completed 协议帧里：注入换来精确计数，帧本身因带 `event:` 行永不剥除——精确性归网关，可见性归客户端，两不亏欠 |
| /generate（SGLang 原生） | ❌ | SSE 走 `usage_metadata`，引擎默认就发，没有可请求的开关 |
| /v1/embeddings、/v1/rerank、/v1/classify | ❌ | 非生成路由，没有 usage 可要 |
| 非流式 | ❌ | 缓冲响应尾本来就解析 usage（既有路径），泵不掺和 |

## 6. 兜底与指标

### 6.1 后端不认 stream_options：一次性 WARN + sticky 免注入，不重试

契约明确禁止「400 后重试」。流式请求带注入得到 400 且响应体点名
`stream_options`/`include_usage`（`names_stream_options`）时：

- `lr_workers` 里 `sop:<worker.id>` 落一个 sticky 标记，该 worker 此后不再注入，
  流量照走（byte-原样）；
- 用 `add()`（非 `set()`）写标记：只有真正存下键的那个请求打一条 WARN，
  永久不支持该字段的引擎总共只花一行日志；
- 两档保留时长，赌注不对称地分开：
  - 后端点名了字段 → 86400s。这是真拒绝，每小时重测一次就白烧一条必死请求；
  - 400 未点名（大概率客户端自己的坏请求）→ 300s 弱保留。误判成本是每窗口一条
    失败请求加一天估算值，而误信「没点名」的代价是字段引用文案不同的引擎被永久
    逐出精确核算。
- 任何一次注入成功的流都会 `clear_stream_options_rejected`（运维换掉后端而 URL
  不变时，标记跟着自愈）。标记按 worker.id（sha224(url)）走，重注册同 id 共用
  标记，靠 TTL 兜底。
- 归属判定故意是证据门控：客户端自己的非法 JSON、坏参数触发的 400 不许连坐
  （未点名时也只进 300s 弱档，且那条请求已回 400 给客户端，不构成新伤害）。
- 已知代价：发现失败的那条请求本身没了（400 原样回给客户端，无重放）。契约
  禁止重试，这是本方案唯一花一条请求的地方，每 worker 一次。

### 6.2 指标家族

| 家族 | 标签 | 语义 |
|---|---|---|
| `smg_router_tokens_total`（既有，扩四类） | router_type, backend_type, model, endpoint, token_type=**prompt\|completion\|cached\|reasoning** | prompt/completion 沿用旧行为：估算行照记（行上有 `tokens_estimated` 与根上的 `/stats` 读数 `tokens_estimated_share` 可辨）；cached/reasoning 只可能来自后端 usage 对象，非零序列必是引擎亲报 |
| `smg_router_usage_injection_total` | model, endpoint, result=**stripped\|passed_through\|rejected** | 每条走了注入判定的流一行：帧读到了也剥掉了 / 帧留下（llama.cpp 融合帧或引擎压根没发）/ 该 worker 被 400 打回转入 sticky。它回答「这套 token 计数器可信吗」：stripped 占比就是精确核算覆盖率 |

标签词取 prompt/completion（本仓库先于该家族就导出这两个名，序列名稳定优先于
词对齐）；cached/reasoning 两路明细只在引擎亲报 usage 时产生。注入系列是本实现的
超集：从不注入的网关没有这一族。HELP 表两处都已登记。

### 6.3 数据通路（泵 → 日志/指标）

`stream_response` 返回 `(ok, tail, prompt, completion, cached, reasoning,
usage_stripped)`；`forward()` 把四类计数与 estimated 旗装进 `ngx.ctx.lr_tokens`
（第 4 槽 estimated 旗、第 5 槽 reasoning——沿用既有槽位约定），把注入结论装进
`ngx.ctx.lr_usage_injection`；`log_inference_request`（log_by_lua 相位，所有入口
汇流于 `finish_request`）读 ctx 记四路 `record_router_tokens` 与一路
`record_stream_usage_injection`。与缓冲路径同一套 ctx 机制，无新调度面。

`reasoning_tokens` 的来源链：`usage.completion_tokens_details.reasoning_tokens`，
回退 `usage.reasoning_tokens`，再回退 0。

## 7. 测试

- **单测**：`test/unit/test_integration.lua` 第 6 节，沙箱 `load()` 抽取转发面的纯函数
  （merge_top_object / usage_from_object / usage_from_chunk / sse_event_droppable /
  sse_split / client_wants_usage / names_stream_options 等，现居
  `router/jsonutil.lua` 与 `router/forward.lua`），钉死注入合并、帧判定、剥除边界、
  400 归属。
- **e2e**：`test/integration/e2e_token_accounting.py`（门已登记，
  `GATE_ONLY=e2e_token_accounting` 可单跑；期望 checks 数以文件头为准）。六个场景：
  注入并剥除+两种客户端自选、llama.cpp 融合帧保护、无 usage 后端估算回退+拒字段
  worker 的 sticky 与一次性 WARN、四路 token 明细、路由作用域含 /generate 与
  /v1/responses、增量下发不被缓冲化+心跳透传。
- **mock 侧**：`USAGE_MODE=always`（默认）逐字节保留朴素流形状，契约的
  `stream chunk count` 等既有断言不受扰；`on_request` 才是真实引擎形态。
  `USAGE_ON_FINISH_CHUNK=1`（融合帧）、`USAGE_DETAILS=1`（cached/reasoning 明细，
  含 responses 的 input/output 拼法）、`REJECT_STREAM_OPTIONS=1`（400 文案点名字段）、
  `SSE_HEARTBEAT=1`（`: ping` 帧）；/generate 流式分支透传 stream/stream_options，
  使「不注入 /generate」可被 e2e 用字节观测。

## 8. 已知限制（都记在这，不许藏）

1. **裸 /generate 无核算增强**：SGLang 原生流自带 usage_metadata，旧路径已读；
   「按模型从观测 usage 回归 chars/token、给裸 /generate 做可校准启发式预估」
   不实现，留作后续（预估行永远带 estimated 旗）。
2. **事前预算不做**：没有任何请求前的 token 预估/限流。
3. /v1/responses 的注入收益是「计数精确」，不是「字节不可见」：completed 帧是
   协议，客户端会见到 usage。要它消失得改协议帧，越权。
4. 发现 400 的那一条请求丢失（无重放），每 worker 一次；弱档下每 300s 最多一次。
5. sticky 标记与 worker.id 同寿：URL 复用即复用标记（靠 TTL 与成功清除自愈）；
   多 nginx worker 各自看同一份 shdict，无 per-worker 漂移。
6. 注入路径每帧多一次切分与一次 "usage" 子串测试；不带注入的流走零缓冲快路，
   与改动前逐字节相同。e2e 场景 6 对「不被缓冲化」立了 450ms 哨兵。
7. `ngx.ctx.lr_usage_injection` 只在注入判定成立时写入：客户端自选路由
   （opt-in true / include_usage:false 被剥）不进 result 序列，覆盖率口径是
   「网关代为索取的那些流」。
