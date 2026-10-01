# lua-router MAJOR 缺陷修复记录（M1–M6 + usage 截断回归）

评审来源：review_final。本文记录每条缺陷的根因、修法、diff 摘要与验证证据。
全部改动都在 `lua-router/` 工作树（未 commit），最小 diff，未重构无关代码。

> **状态**：7 项修复全部有效，已进工作树；**尚未 commit**（与 parity-contract 的 router.lua
> 修复同批挂在工作区），发布镜像 `lua-router:latest` 不含这些改动。
> **日期**：修复 2026-09-29 23:40 – 09-30 00:36 UTC，状态复核 2026-09-30（UTC，最后一次 04:5x 刷新）。
> **证据强度**：A（2026-09-30 02:15 UTC 复跑：契约 **322 passed / 0 failed / 3 notes**、
> tree 67 / policies 118 / hash 795 / integration 66 全 0 failed、e2e_stateful 43/0）。
>
> **当前基线已推进到契约 474 / 0 / 3**（核心第二波，router.lua md5 `c0570b84…`；门禁日志
> `/data/tmp/lr-core2/FINAL_GATES.log`）。M1–M6 的 56 条新断言仍在那 474 条里，
> 单测四组数字（67 / 118 / 795 / 66）与 e2e_stateful 43/0 一字未变，
> 也就是**这一波新增的 152 条断言没有把 M1–M6 任何一条顶掉**。
> 本文其余数据（逐条根因、diff 摘要、A/B 对照）仍是那 7 项修复的出处，未因基线推进而失效。
>
> 本文是「M1–M6 已修复」这一说法的出处；原始日志在 `/data/tmp/lr-fix/`。
> 本文也是 feature-gap.md §5.1 那个 bug 的**漏网证据**：M3 / M5 都动过 `set_top_field`
> 相关路径，但配套的 `[json-edit] number member replaced` 断言用的是「插入」形状，没钉住
> 「替换已存在的整数成员」，于是 322 全绿仍然漏掉了 ctx cap 失效这个真缺陷。
> **该缺陷核心第二波已修**（指数组可选化，两条 e2e 红转绿），并且补上了缺的那条形状断言
> （契约 `probes` 的 `set_top_field replaces an existing integer member without duplicating the key`）；
> 教训照旧成立：绿灯的契约套件能漏掉真缺陷，取决于断言用的是哪种形状。

## 汇总

| 缺陷 | 文件 | 状态 | 契约新断言 |
|---|---|---|---|
| M1 直方图双重累计 | observability.lua | 已修 | 1 |
| M2 TLS 上游静默失败 | registry/router/hb/config_store | 已修（真实 https 上游验收 PASS） | 11 |
| M3 /_ui 别名整表重编码 | ui.lua + router.lua | 已修 | 3 |
| M4 熔断计数跨进程竞态 | registry.lua + hb.lua | 已修（4 worker 进程实测） | 6 |
| M5 流式 usage 重复扫描 | router.lua stream_response | 已修（1024×65KB 场景 5.3×） | 1 |
| M6 /_ui API 别名鉴权 | ui.lua + conf/ui.conf | 已修（对齐 Rust ui_api_routes） | 33 |
| 附加：buffered usage 多返回值截断（real_eval 发现） | router.lua usage_from_body | 已修 | 1 |

回归结果（见文末）：契约套件严格模式 **322 passed / 0 failed / 3 notes**（266 基线 + 56 新增）；
单测 tree 67 / policies 118 / hash 795 / integration 66；e2e_stateful **43 checks, 0 failed**；
`openresty -t` 两个 conf 均 OK。

---

## M1 Prometheus 直方图双重累计

根因：`observability.lua observe()`（:169）对覆盖观测值的**所有**桶逐个 +1，
而渲染侧（:798 起）又把 per-bucket 数组做了一次前缀和 —— 一次请求被计入
每一个覆盖它的桶，小 le 桶可以超过 `_count`。

修法：observe() 只写**首个命中桶**（桶升序，第一个 `seconds <= BUCKETS[i]` 即 +1 后
`break`），前缀和保留在渲染侧一处完成。这样 `b[i]` 语义是"该桶单独计数"，
导出时 `le=x` = 前缀和，`le=+Inf` 恰等于 `_count`。

diff 摘要（observability.lua）：
- :169-173 命中首桶后 `break`（原来是继续累加所有覆盖桶）
- :801-805 渲染侧前缀和逻辑不变，注释明确"prefix sum happens here and only here"

验证：
- 契约新增断言 `duration histogram buckets cumulative, monotone, <= _count`
  （suite 内嵌 `histogram_check.py` 校验 /metrics 全文：单调、中间桶 ≤ _count、+Inf == _count）。
- 单请求实测（`/data/tmp/lr-fix/m1_single_request.sh`，脚本保留）：起实例、只发
  1 个 chat 请求，curl /metrics 后该 series 为
  `_count=1  le=0.001=0（请求耗时 2ms）  le=0.005=1  le=+Inf=1`，
  4 条 duration series 全部 0 违反。旧代码此时 le=240 会是 20。

## M2 TLS 上游静默失败

根因（real_eval 实证 + 本仓库确认）：http{} 模块的 tcp cosocket `connect()`
选项表不认 `ssl`，`{ssl=true}` 被静默忽略 → 明文发 443 → 上游回 400
"The plain HTTP request was sent to HTTPS port"；hb.lua 探测同样失败导致
https worker 永远 unhealthy。

修法：registry.lua 新增 `tls_handshake(sock, host, tls)`（:179）：connect 之后显式
`sock:sslhandshake(nil, host, false)`（SNI=host，不验证证书，与既有
`ssl_verify=false` 语义一致），失败返回错误串。三个调用点接入：
- router.lua :708 `send_attempt`（推理转发）
- hb.lua :60 `http_get`（健康探测）
- config_store.lua :915 raw_request 的 cosocket 回退路径；其 lua-resty-http 快路径
  （:892）同时补 `ssl_verify = false`（否则自签证书直接握手失败）

验证：
- 契约新增 tls_upstream 段 11 断言：openssl 自签证书 + `tls_wrap.py` 把 mock 包成
  https；覆盖 https worker 注册→健康探测 healthy→chat 转发（含 model 重写、usage）
  →流式 [DONE]→/_ui/props 代理，外加反向断言"443 端口不发明文响应"（明文 curl 得 000）。
- real_eval 用真实上游 `<real-upstream-host>` 端到端验收 PASS：
  reload 后健康探测 healthy=True，非流式/流式 chat 全通（200、choices/usage 完整、
  SSE 帧、reasoning_content 正常）。

## M3 /_ui/v1/chat/completions 整表重编码（[] → {}）

根因：ui.lua 把 body decode 后，router.lua 的 /_ui 路径 `json_encode(body)` 整表
重编码。lua-cjson 无法区分空数组与空对象，`"tools":[]`、`"stop":[]` 到达 worker
时变成 `{}`，直接改变 llama.cpp 端行为。

修法：保留原始字节 + 定点改写，与 /v1 主路径的 `rewrite_model` 同一套做法：
- ui.lua 新增 `read_raw_body()`（:117），`read_json_body()` 改为返回
  `(value, raw, err)`（:131），新增 `splice_ui_cleanups(raw, body)`（:182）：
  fill_default_model / clean_ui_effort 的决策仍作用于 decoded 表（路由、stream
  检测要用），但落到 payload 时通过 `router.set_top_field` 只改写 `model` /
  `reasoning_effort` 两个顶层键的字节，其余原文透传。
- router.lua 新增 `ui_pipeline(route, body, raw_body)`（:1355）：raw 存在就用 raw，
  `forward()`（:1002）内的 `rewrite_model(raw_body, ...)`（:1063）在原始字节上重写
  model；`do_chat` / `do_completion`（:1399/:1404）透传 raw。
  decode→encode 往返只作为 raw 缺失时的兜底。

验证：
- 契约 ui_fixed 新增 3 断言：POST `/_ui/v1/chat/completions`，body 含
  `"tools":[],"stop":[]`，断言 sink 的 echo_body 里两者 `type == "array"`。
- e2e_stateful 已有 `[payload] empty arrays stay arrays through the raw edits` 与
  `[payload] untouched numbers survive`（n/temperature 不被改写）。

## 附加（real_eval 发现的回归）：buffered usage 多返回值被 `or` 截断

根因：router.lua `usage_from_body` 原实现
`return usage_from_object(decoded.usage) or usage_from_object(decoded.usage_metadata)`
—— Lua 的 `or` 把多返回值函数截断成第一个值，非流式请求 completion_tokens /
cached_tokens 恒 nil → /_ui/logs 与 smg 指标记 0。流式路径（sse_usage）不受影响。

修法：显式接全返回值再判空（:600-613）：
`local p,c,ca = usage_from_object(...); if p or c then return p,c,ca end;
return usage_from_object(decoded.usage_metadata)`，并留注释禁止 `f() or g()` 写法。

验证：契约 observability 段新增 `/_ui/logs buffered usage was parsed`
（存在 stream=false 且 completion_tokens>0 的记录）。

## M4 熔断计数跨进程竞态

根因：`hb.lua record_outcome` 是 `cb_state()` 读 → +1 → `set_cb_counters()` 写的
读-改-写。多个 nginx worker 进程并发 charge 同一 worker 时互相覆盖丢失增量
（四个进程都读到 failures=2，都写 3），熔断打开点被推后；且每个越过阈值的进程
都会各自 flip 一次并各自记 transition/日志。

修法：
- registry.lua 新增 `charge_cb(id, success)`（:614）：被 charge 一侧用
  `shdict:incr(key,1,0)` 原子累加（incr 的返回值即本次 outcome 的序号），对侧清零；
  incr 失败（dict 满等）退化为 set 保底。
- registry.lua 新增 `flip_cb(id, expect, next_state, opened_at_ms)`（:646）：
  在 `with_lock`（registry 全局锁）内重查当前状态是否仍等于调用者看到的 expect，
  只有匹配者执行翻转 —— 恰好一个进程记 transition 与日志；翻回 CLOSED 时清空两计数。
- hb.lua `record_outcome`（:290）改为 charge_cb → 用返回值判阈值 → flip_cb 成功者
  才写 observability。
- 健康计数同样竞态：hb.lua `apply_health_result`（:145）hs:/hf: 改 incr。
- registry.lua 头部 :16-20 的误导注释（原称计数器"无需原子"）改为说明真实约束。

验证：
- 契约新增 cb_race 段 6 断言（4 nginx 进程：由套件 conf sed 派生
  `worker_processes 4` 的 conf）：TH=6、每批 2 并发打 FAIL_MODE=retryable_500
  mock。实测 **after 6 opened**（允差 6/7/8）、打开后请求 503、
  `closed->open transitions == 1`、failure 计数 6（无丢失）。
- 独立 A/B 证据（真实窗口太窄难以复现，人为把读-改-写窗口加宽 50ms 后对比，
  脚本 `/data/tmp/lr-fix/m4v/run_m4.sh` + `/data/tmp/lr-fix/make_wide.py`）：
  旧 get+set 版 threshold=6 却要 **80 个请求**才打开，期间计数呈 2,3,4,5,6
  （每批 16 个并发只留下 1 个增量）；incr 版在**同样的加宽窗口**下第一个并发批次
  （16 请求）内就打开且计数 16 无一丢失。不加宽时旧代码偶尔也能过阈值，说明这是
  概率性丢失而非必然 —— 契约断言因此按"阈值+2 容差"设计。

## M5 流式 usage 提取 O(流长×64KB) 重复扫描

根因：`router.lua stream_response` 的 `note()` 每收到一个 block 就把文本拼进 64KB
尾窗并**整窗**重跑 `sse_usage`（gmatch + 每帧 json_decode），成本随
流长 × 尾窗重复；且 usage 帧跨越两次 read 时前半截被尾窗淘汰就可能彻底错过。

修法（:811-880，保留 64KB 尾窗语义）：增量扫描 ——
- `usage_carry` 只保留未完成尾行，每个字节只被考虑一次；
- 只扫本次新增的完整行，行内先做廉价子串检查（含 `usage` 才逐帧 decode）；
- `usage_found` 后扫描器直接停用（usage 帧在流尾之前的场景省掉全部后续解析）；
- 同一批内 last-wins，与旧全窗扫描语义一致；tail 返回（给截断检测用的 64KB）不变。

验证：
- 契约新增探针断言：`/probe/stream-usage` 用脚本化 cosocket 驱动真实
  `stream_response`——usage 帧被切成 3 段（跨 read、对象内部断开）、中间垫
  70KB×2 把首段顶出 64KB 尾窗、4096 字节分块读，约 35 次扫描；断言
  `ok prompt=11 completion=22 cached=0`。
- 性能对照（`/data/tmp/lr-fix/m5bench4.conf`，512→1024 个 65KB SSE block、usage 在
  最后一 block，os.clock CPU 毫秒，各 3 次）：
  旧实现 1568.5 / 1507.1 / 1503.5 ms，新实现 290.8 / 261.7 / 288.4 ms，
  **约 5.3× 提速**（同一 1024-block ~66MB 假流）。

## M6 /_ui API 别名缺鉴权

根因：Rust `ui_api_routes` 组挂了 `route_layer(auth_middleware)`；ui.conf 的别名
location 全部匿名可达。

修法（严格对齐 Rust，不扩大范围）：
- ui.lua 新增 `_M.api_auth()`（:62）+ 常量时间比较 `constant_eq`：
  SMG_API_KEY 未配置 → 直通；只认 `Authorization: Bearer `（大小写精确，
  x-api-key 不属于该组）；失败回 401 **空 body**（须
  `content_type=nil; content_length=0; send_headers(); exit(401)`，否则 nginx
  会塞 185 字节 HTML 错误页，axum 的 Err(StatusCode) 没有 body）。
- conf/ui.conf：9 个受保护 location 首行接 `ui.api_auth()` ——
  `/_ui/v1/models`、`/_ui/models/{load,unload,sse}`、`/_ui/props`、`/_ui/slots`、
  `/_ui/tools`、`/_ui/v1/streams/lookup`、`/_ui/v1/chat/completions/control`、
  `/_ui/v1/stream`。
- `/_ui/v1/chat/completions`、`/_ui/v1/completions` 走共享 pipeline 的
  `check_data_auth()`（OpenAI JSON 错误体，与 /v1 一致），不叠加 401 空 body 语义。
- 保持无鉴权（对齐 Rust 的 trusted-LAN 设计）：`/_ui/logs*`、`/_ui/stats`、
  `/_ui/config*`、静态 SPA。静态 SPA 与 Rust ServeDir 一致本来就不挂鉴权，
  该差异沿用 Rust，不做额外收紧。

验证：契约新增 ui_auth 段 33 断言，双实例（带/不带 SMG_API_KEY）：无 key 时
9 个端点全 401 且空 body、只认 Bearer 前缀（bearer 小写拒）、错误 key 401、
带 key 200（props/v1/models）、logs/stats/config/静态无 key 直通、
带 key 实例的 /v1 无 key 仍 401。

---

## 套件自身的一处修复

cb_race 段最初用 `start_mock failing-model` 起故障 mock，会把全局 `MOCK_URL`
重置为空，导致后续 igw / discovery 段注册空 url 得 400。已改为独立
`free_port` + 直接起 FAIL_MODE mock，不触碰全局变量。

## 全量回归

| 项 | 命令 | 结果 |
|---|---|---|
| 语法门 | `openresty -t` test/conf/nginx-lua-router.conf 与 conf/lua-router.conf | 两个均 test is successful |
| 单测 tree/policies/hash/integration | resty @ apache/apisix:3.11.0-debian（doc/impl-*.md 命令） | 67 / 118 / 795 / 66，全部 0 failed |
| 契约套件（严格模式） | `bash test/test_lua_router.sh` | **322 passed, 0 failed, 3 notes**（266 基线 + 56 新增） |
| e2e_stateful | `python3 test/integration/e2e_stateful.py`（lua-router:integration 重建后） | **43 checks, 0 failed** |

新增断言 56 条分布：observability 2（直方图 + buffered usage）、ui_fixed 3、
tls_upstream 11、cb_race 6、ui_auth 33、probes 1。
日志：`/data/tmp/lr-fix/full-contract.log`、`/data/tmp/lr-fix/e2e.log`。

perf 压测端口（:43100、mock 43101/43102）未触碰。

## 遗留与说明

- `registry.set_cb_counters` 保留为 public API（metrics/UI 语义需要直接清零的场景），
  但生产路径已无调用方。
- M4 的概率性：真实读-改-写窗口只有微秒级，竞态丢失是概率事件；修复后计数
  由 shdict incr 保证不丢，与窗口宽度无关。
- M2 的证书验证维持 skip verify（内部 worker 自签证书），与 Rust 侧
  `ssl_verify=false` 默认一致；若要严格验证需另开配置项，不在本次范围。
