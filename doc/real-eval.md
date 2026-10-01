# lua-router 真实上游端到端评测 + prefix cache 调度准确性验证

日期：2026-09-29/30（UTC）。执行人：real_eval。
上游：`<real-upstream-host>`（OpenAI 兼容，APISIX 边缘，SGLang 后端），模型
`Q38-Flash-Next` / `qwen3.8-27b` / `qwen38-flashnext-orca-nvfp4`；负样本 `q38fn-pennyroyal`（无 worker）。
原始数据：`/data/tmp/real-eval/`（`eval_a*.jsonl`、`sessions_router_final*.jsonl`、
`sessions_direct_probe_repeat.jsonl`、`baseline_direct.jsonl`、`logs_final.json`、脚本 `eval_a.py`/
`prefix_sessions.py`/`cache_probe.py`）。全程低频串行、请求间隔 ≥2s，未压测。

> **状态**：结论仍有效；**§2.5 关于非流式 usage 的限制已解除**。
> **日期**：评测 2026-09-29/30（UTC），状态复核 2026-09-30（UTC）。
> **证据强度**：B（`/data/tmp/real-eval/` 的 jsonl 留档；全程低频串行 ≥2 s 间隔，未压测）。
>
> 校正与提醒：
> - §2.5 的 `usage_from_body` 多返回值被 `or` 截断 → **已修**，并由契约断言
>   `/_ui/logs buffered usage was parsed` 钉住；非流式 `completion_tokens`/`cached_tokens` 恒 0
>   的现象不再成立。但 §3 第 4 条建议的那次**真实上游 token 对账仍未重跑**，别当成已验收。
> - §0 的前提「M2（https 上游 TLS）」已进主干（`registry.tls_handshake` 三处接入），
>   契约 `tls_upstream` 11 项覆盖自签场景；正式证书链与 mTLS 仍未覆盖。
> - 「A 通过 18/18」「B prefix cache 命中 97–99%」两条结论保持；B 的强度受**单 worker URL**
>   限制（router 侧无打散动作可做），多实例命中率对比仍未做。

## 0. 环境

- 实例：`lr-real-45093`（authz:latest + `test/conf/nginx-lua-router.conf` 复制改 `listen 45093`、
  resolver 改 127.0.0.53），`--network host`，`SMG_POLICY=cache_aware`
  `SMG_ENABLE_IGW=true` `SMG_HEALTH_CHECK_INTERVAL_SECS=2`。IGW 开启后
  `candidates_for` 按 model_id 过滤，配合「注册→测→DELETE 轮换」实现逐模型评测
  （同 URL 只能注册一个 worker，registry.add 按 URL 去重）。
- 启动前 `openresty -t` 通过，`/klib/load` 19 个模块全 OK。
- **前提：M2（https 上游 TLS）**。评测期间旧实现 `connect(..., {ssl=true})` 在 http{} cosocket
  被静默忽略 → 明文发 443 → APISIX 400 "The plain HTTP request was sent to HTTPS port"，
  健康探测 33/33 failure。23:43 `registry.tls_handshake`（显式 `sock:sslhandshake(nil, host,
  false)`，router.lua:708 / hb.lua:60 / config_store.lua:915 三处）落地后 reload：worker 转
  healthy=True，非流式/流式全通。**真实上游 TLS 验收 PASS。**

## 1. A 部分：真实模型端到端评测

### 1.1 功能矩阵（经 router）

| 检查项 | Q38-Flash-Next | qwen3.8-27b | orca-nvfp4 |
|---|---|---|---|
| 非流式 200 + choices/finish_reason/usage 完整 | PASS | PASS | PASS |
| 流式 `stream:true` SSE 帧 + 尾帧 usage | PASS（19 帧） | PASS（22 帧） | PASS（20 帧） |
| `x-request-id`（上游 chatcmpl-* 透传） | PASS | PASS | PASS |
| `reasoning_content` 存在（思考型） | PASS | PASS | PASS |
| 错误路径 `q38fn-pennyroyal` | PASS 503 | PASS 503 | PASS 503 |

负样本契约：经 router `503 {"error":{"message":"No available workers (all circuits open or
unhealthy)","type":"Service Unavailable","code":"no_available_workers"}}`，与 llm-248 直连
503 的 code/message 一致（字段顺序不同，JSON 等价）。

功能矩阵 15/15 项通过；含启动/注册/TLS 验收合计 **18 项全过**。

### 1.2 质量 5 问 + 直连对比（内容等价性，非逐字节）

Q38-Flash-Next 全 5 问、qwen3.8-27b 全 5 问经 router 与直连各发一次；orca 抽查 1 问。人工判定：

| 维度 | Q38（经 router） | 直连对比 | 27b | 判定 |
|---|---|---|---|---|
| 数学（1/6-1/8 注水） | 24 小时 | 同答案 | 24/1=24，同 | 等价 PASS |
| 代码（fizzbuzz） | 正确三目实现 | 同一实现 | 正确 | 等价 PASS |
| 翻译（工欲善其事） | 忠实直译 | 意译版，语义同 | 忠实直译 | 等价 PASS |
| 常识（起落架低空通场） | 传感器误报需外部目视确认 | 同一论点 | 同一论点+漏油细节 | 等价 PASS |
| 推理（三段论假前提） | 形式有效/前提假→结论不可靠 | 同一结论 | 同一结论 | 等价 PASS |

5 题全部「经 router ≈ 直连」，router 未改变语义内容（采样随机性导致的措辞差异属正常）。
`reasoning_content` 长度 80–800 字符不等，全程存在。

### 1.3 控制面与观测

- `POST /workers` 202 + Location；重复注册返回 failed job 但保持 202（幂等）。
  `DELETE /workers/{id}` 后再 `POST` 同 URL 复用同 worker_id——轮换通路可用。
- 健康翻转等待 ≤8s（interval=2s、success_threshold=2）后再发流量。
- TTFT（客户端首字节）：非流式 0.41–0.5s，流式 0.5–1.4s（生产共享服务，仅参考）。

## 2. B 部分：prefix cache 调度准确性

### 2.1 命中口径

- 任务书所说 `matched_st...` 实为 **`matched_stop`**（停止 token id，与 cache 无关，排除）。
- 命中信号 = `usage.prompt_tokens_details.cached_tokens`（SGLang radix cache 口径）。
  小前缀（<1.5k tok）恒 null；`cache_probe.py` 扫出页粒度：**cached 以 1600 为步长**
  （1600/3264/6592/13312），低于 ~1.6k token 的前缀不回填。B 主体因此用 ~2800 token 大前缀。
- 辅助口径：TTFT。

### 2.2 主序列（经 router，cache_aware，S1/S2/S3 ×4 轮完整历史重发）

| 会话 | 轮 | prompt | cached | 命中/前缀 |
|---|---|---|---|---|
| S1 | 1 | 2808 | null（冷） | — |
| S1 | 2 | 2835 | 2752 | 97.1% |
| S1 | 3 | 2860 | 2816 | 98.5% |
| S1 | 4 | 2885 | 2816 | 97.6% |
| S2 | 1 | 2807 | null | — |
| S2 | 2-4 | 2832/2859/2881 | 2752→2816→2816 | 97-98% |
| S3 | 1 | 2800 | null | — |
| S3 | 2-4 | 2825/2853/2874 | 2752→2816→2816 | 97-98% |
| interleave 对照 | S3→S2→S1 乱序 | 2901/2906/2910 | **2816/2880/2880** | 97-99% |

- 首轮 cached=null、第 2 轮起稳定 ≥2752，前缀增长则 cached 增长——**会话粘住换来真实命中**。
- 打散对照：轮次乱序重放命中不掉（2816-2880），证明命中跟「内容前缀」而非发送顺序；
  由于单 worker 候选集，router 侧无打散动作可做（见 2.4）。

### 2.3 router 层粘滞性（/_ui/logs）

`logs_final.json` 68 条推理记录（seq 17-68 全部 llm-248）：
`selected`/`worker` 全部 = `<real-upstream-host>`，`route_type=cache_aware`，
52/52 单一目标、0 次漂移。单 worker 下结论平凡，但选工-记录管线（含
`candidates`、`ttft_ms`、`cached_tokens` 字段）确认可用。

### 2.4 上游是否打散（关键结论）

同一 ~2800 token 前缀连续 4 次重放：

- 经 router：cached = 2752/2752/2752/2752（第 1 次是热身后，全程命中）
- 直连 llm-248：null → 2752 → 2752 → 2752

两种路径 cached 零方差、TTFT 随命中微降（0.93→0.82s）。**结论：llm-248 域名背后
不存在「同前缀被打到不同实例」的打散**（单实例或边缘已按前缀粘滞），router 只要把会话
粘到该域名即可保证真实 KV cache 命中。

### 2.5 已知口径影响（评测期间发现，fix_majors 修复中）

`router.lua:604` `usage_from_object(...) or usage_from_object(...)` 把多返回值截断，
**非流式**请求写入 `/_ui/logs`/指标的 `completion_tokens`/`cached_tokens` 恒 0
（`logs_final.json` 中 6 条非流行全 0，46 条流式行正常）。本报告 B 部分 cached 证据取自
流式路径 + 客户端解析的 usage，不受影响；非流式 token 统计待修后重验。

## 3. 结论

1. **A：通过 18/18**（功能矩阵 15 + 实例启动/TLS 验收/控制面轮换）。三真实模型经 router
   的语义质量与直连等价，负样本 503 契约对齐，SSE 帧完整。
2. **B：prefix cache 调度准确性成立**。cache_aware 选工 52/52 无漂移；上游命中
   cached/prompt ≈ 97-99%，首轮 null → 第 2 轮起命中，interleave 打散不掉命中；
   上游侧无实例打散，粘滞到域名即等于粘滞到 KV cache。
3. 限制：单 worker URL 场景下 router 粘滞结论偏弱（平凡成立），多实例场景的命中率对比
   需多 worker 池验证；页粒度 1600 tok 意味着短会话拿不到命中，属上游特性而非 router 缺陷。
4. 非流式 usage 回归（§2.5）修复后，建议对 `/_ui/logs` 的 token 字段做一次补验收。

复现：`/data/tmp/real-eval/` 下 `python3 -u eval_a.py http://127.0.0.1:<port> <out.jsonl> <model>`、
`python3 -u prefix_sessions.py http://127.0.0.1:<port> Q38-Flash-Next <out.jsonl> [--repeat]`。
