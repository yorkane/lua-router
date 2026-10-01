# watcher 合并：把独立部署的 llm-watcher 搬进 lua-router 进程内

实现文件：[watcher.lua](../lualib/resty/luarouter/watcher.lua)（纯逻辑层 + live 接线层）、
[init.lua](../lualib/resty/luarouter/init.lua)（worker 0 定时器接线）、
[config.lua](../lualib/resty/luarouter/config.lua)（`cfg.watcher` 段）、
[router.lua](../lualib/resty/luarouter/router.lua)（`GET`/`HEAD`/`POST /model-map`）、
[observability.lua](../lualib/resty/luarouter/observability.lua)（`lr_watch_*` 登记点）、
三份 conf（`env` 声明 + `lua_shared_dict lr_watch`）。
单测：[test_watcher.lua](../test/unit/test_watcher.lua)（385 checks）。
e2e：[e2e_watcher.py](../test/integration/e2e_watcher.py)（108 checks）。

语义移植基准：`llm-router/watcher/llm_watcher.py`（1577 行）与同目录 `README.md`
的守卫表。原守护进程通过 HTTP 控制面（`POST`/`DELETE` /workers，202=queued）间接
驱动一个在跑的 router；合并形态跑在 router 进程里，注册就是直接调
`registry.add` / `registry.remove`，ledger 从磁盘上的 `ledger.json` 变成
`lr_watch` 共享字典。

---

## 1. 九条守卫逐条对照

（守卫 1-9 是从 Python 守护进程逐条移植过来的那九条；本仓后补的**第 10 条**（探针确认不可用即按分档
摘除）不在表内，单独写在 §1.1。全仓引用守卫编号时以 1-9 为原编号，不要重排。）

| # | README 守卫 | Python 实现 | Lua 实现 | 测试 |
|---|---|---|---|---|
| 1 | No self-loop | `probe_all` 比对 router.port + `ROUTER_FINGERPRINT_KEYS` | `is_self_url()`（loopback + 自有端口）与 `classify()` 的 `/server_info` 指纹两道；`SMG_PORT`/`SMG_METRICS_PORT` 由 `new_config` 收进 `self_ports`，连候选都不是 | unit `normalize_url/split_http/is_self_url`、`guards 1/2 applied in reconcile`；e2e `[2] the router's own port is never a candidate` |
| 2 | 只认真 OpenAI 端点 | `probe_worker`：`/v1/models` 必须 `data[].id` | `classify()` 同一条：非 2xx/4xx、无 `data[].id`、空 `data[]` 全部拒 | unit `classify`（HTML 404、`{"ok":true}`、空 data 三种形状）；e2e `[2] a non-OpenAI listener never becomes a worker` |
| 3 | 首接触快照 protected | `first reconcile` 把 `GET /workers` 全量写进 `ledger.protected` | `reconcile()` 开头 `ledger.touched()` 未置位且 protected/owned 皆空时快照，`desired = discovered - protected` | unit `guard 3 first-contact protection`、`model map renames reach the pool`；e2e `[2] both pre-configured workers are protected`（停掉的保护 worker 越过 grace 仍在池内、removes 计数不增）与改名领养后 `[2] the untouched protected worker is still protected` |
| 4 | 只删自己 ledger 里的 | 删除循环走 `ledger.owned` | 同上，且 `unregister()` 先 `registry.get(id)` 确认记录仍在 | unit `guards 4/5`、`allow_remove false`；e2e `[2] the ledger counted no removal`（保护 worker 消失也不删）、`[2] the adoption delete is counted`、`[3] the deletion is counted once` |
| 5 | remove-grace 300 s | `missing_since` + `--remove-grace` | 同结构，`SMG_WATCHER_REMOVE_GRACE_SECS` 默认 300 | unit `guards 4/5`；e2e `[3]` 两条（窗口内保留 / 窗口后删除） |
| 6 | Never empties a model | `_is_last_for_model` + `--keep-last-grace` 到期后才删 | `is_last_for_model()`（不健康的同模型兄弟不算覆盖）+ `keep_last_grace_secs`，`0`=永久保护，负值=关掉（`SMG_WATCHER_KEEP_LAST=false`） | unit `is_last_for_model`、`guard 6 keep-last`（含只警告一次、grace 到期、0=永久）；e2e `[4]` 三条 |
| 7 | Releases stuck adds | 202 只代表 queued，AddWorker job 卡在死 URL 上会永久占住该 URL | 合并形态没有 job 队列，`reap_pending()` 保留下来管另一件事：ledger 声称拥有、但池子里没有的 URL（手工 DELETE、或 reload 把 `lr_workers` 清空而 `lr_watch` 还留着），超过 `add_confirm_timeout_secs` 就删掉释放 URL，同一轮即可重新注册 | unit `guard 7 stuck add released` |
| 8 | Survives a router restart | 周期性 `GET /workers` 刷新 worker_id | `reconcile()` 每轮把 `entry.worker_id` 与池内实际 id 对齐；容器重启形态下 `lr_watch` 与 `lr_workers` 一起清空，重新发现即重建（合并语义等价） | unit `guard 7` 里的 id 采用断言；e2e `[5] after a router restart rediscovery re-registers` |
| 9 | Blind by design | 只读 HTTP 端点，不碰 GPU、不起停服务 | 同：只访问 `/v1/models` `/server_info` `/get_server_info` `/props` `/metrics` `/health`，docker 侧只读 `/containers/json`，`/proc` 侧只 `io.open` 读文件，全程无 `io.popen`、无子进程、无 GPU 读取 | 代码审读 + live 层无 `os.execute`/`io.popen` |

`Probes that it really generates`（活动探针，每分钟让每个 worker 生成一个 token）与
`Hands over what it evicts`（驱逐 protected worker 时接管所有权）**不在这九条里**，
前者未移植（见 §4），后者已移植：改名与所有权交接走 `ledger.unprotect` 那条路径，
单测 `model map renames reach the pool` 覆盖。

### 1.1 第 10 条守卫：探针分档摘除（确认不可用的服务不留池；2026-10-01 用户裁定，非 Python 移植）

守卫 2 只管**入口**：一个 URL 注册成功之后，旧实现里每轮探针再读不出 `data[].id`，也只是
不把它写进 `desired`，删除仍旧走守卫 5/6 的宽限。于是池里会留下一行「广告着模型、请求过去
就 5xx」的僵尸，代价分两档：若巡检把 `/health` 打到连续失败，健康位翻假、它退出选路，但仍占着
`GET /workers` 与管理台服务池页一行，也让那个模型继续出现在 `/v1/models` 里；若它注册时带了
`disable_health_check`（引擎没有 `/health`），或 `/health` 照常回 200 而 `/v1/models` 读不出来，
健康位永远为真，请求会**继续被分到它头上**。用户裁定补的就是这一段：**注册要拿到真实模型信息，
被判定不可用的服务就不该继续出现在服务池里**。

关键是把「探针这一轮没给通过」拆成三档（外加「发现源不再报它」这条老路作对照），后果各不相同：
**这套分档话术是全仓唯一口径**，[agent-handover.md](agent-handover.md) §4、`watcher.lua` 的文件头注释
与日志文案必须与之保持一致。

| 情形 | 判据 | 后果 |
|---|---|---|
| **确定性否定** | 该 URL 本轮**仍是发现源候选**、探针确实拨通并拿到了 HTTP 回答，但内容不合要求：`/v1/models` 读不出 `data[].id`、`/server_info` 命中 router 自指纹、或报出的模型数超过 `max_models` | 本轮立即 `release()`，跳过 remove-grace 与 keep-last |
| **传输层未知** | 探针连不上／超时／TLS 失败／接受 TCP 后无应答——拨号本身没给出可归因于对方的回答 | 计入该 owned 条目的连续失败数，达到 `SMG_WATCHER_PROBE_FAILURES`（缺省 2）才摘；未达阈值保留原行，任一轮成功即清零 |
| **不触发摘除** | `no probe transport`（网关自身缺 fetch，属自己故障而非对方证据）；`require_health` 未通过（那是**注册准入**开关，不是摘除理由） | 保留原行，既不摘也不计入连续失败数 |
| 只是看不见 | 发现源本轮不再报它（进程停、容器删、监听关闭），探针根本没跑过 | 原路不变：`missing_since` + 守卫 5 grace + 守卫 6 keep-last |

判据要能落地，`classify()` 的拒绝理由必须先分成可判别的两类，再交给摘除逻辑：现实现的
`no /v1/models answer` 一条同时覆盖了「对方回了 4xx/5xx」与「拨号根本没成功」（`fetch` 返回
的状态是 `nil`），而传输层线索（连接失败、超时、拿不到状态行）在 `hb.http_request` 的第三个
返回值里。分档实现要求：带传输层线索的失败算「传输层未知」，拿到状态行但内容不合要求算
「确定性否定」，`fetch` 缺失（`no probe transport`）单独一档不摘。改这些理由字符串时同步更新
本节与单测用例名，别只改代码。

**为什么确定性否定不给宽限，传输层未知只给两轮滞回。** 宽限存在的理由只有一个：短暂重启不该清空
服务池，而本机服务短暂重启的表现恰恰是「发现源暂时不报它」——进程一停，端口就从 `/proc/net/tcp`
消失，容器一停就不再出现在 `/containers/json`，于是它落进最后一行的 grace 路径。反过来，本轮仍然拨
它、仍然拿到了 HTTP 回答，却读不出一份模型列表，那就不是重启窗口，而是「挂着但不服务」：对它等
300 s（grace）乃至 1800 s（keep-last）没有任何好处，那段时间里每个打到这个模型的请求都在拿 5xx，
而调度器还以为这个模型有实例。传输层未知不当轮定罪，是因为「连不上」同样符合「对端正忙、conntrack
掉了、网关自己的网络抖了一下」这组解释，而一次误判的代价比多留一轮 5xx 更贵：摘了要重新
`registry.add`，健康位与外部负载读数一起清零。所以它攒够 `SMG_WATCHER_PROBE_FAILURES` 次**连续**失败
才动手。守卫 5/6 与本条管的是两件不同的事：**「发现源消失」归守卫 5/6，「对方明确答了但不合要求」
归本条**，同一轮里互不干扰，也不会打架。

三条不变量，保证它没有把前面几条守卫放宽：

- 摘除仍然只作用于自己 ledger 里的 owned 条目（守卫 4 原封不动），且 `is_config_member` 的免疫判定
  排在本条之前：protected 条目与 config_store 声明的 upstream 不由 watcher 删除，探针结论也不例外。
- 恢复走正常路径，没有旁路：下一轮又能读到 `data[].id`，就按新服务的同一套门槛（自端口、exclude、
  `max_models`、router 指纹、add 失败退避）重新注册。`release()` 顺带清掉 backoff 与 pending，所以
  恢复不会被上一轮的失败记账挡住。但「能回来」不等于「立刻接流」：`registry.add` 会把健康位与外部
  负载读数一并重置，重新接流要等 `health_success_threshold` 个巡检周期把健康位翻回来，这期间该 URL
  在 `GET /workers` 与管理台服务池页里以 unhealthy 出现。
- 单轮摘除保险丝：一次 reconcile 内因探针（含滞回达标）被摘的 owned 条目超过 owned 总数的一半时，
  本轮降级为只 warn 不摘，`SMG_WATCHER_PROBE_FUSE=0` 可关闭（回到逐条即时摘除）。动机是网关自身故障
  （配置写坏、到 worker 的网络整片断、docker.sock 读不到导致发现源集体异常）会让全部 owned 条目在同一
  批里集体失败，interval 15 s 下两轮滞回约 30 s 就能清空整个服务池，而清空全池比留几行僵尸严重得多。
  阈值取「超过一半」而不是绝对条数：owned 只剩一两条时任何一次摘除都算超半，这类小池子实际由滞回那一档
  兜住。实现上还有一个下限：本轮被摘数必须 **≥ 2** 才算数。否则单 worker 部署（owned=1、摘 1 条）
  会因为「1 > 0.5」而永远摘不掉确定性否定——那正是这条守卫最该生效的场景。保险丝只降级探针摘除路径，
  守卫 5/6 的 grace 删除不受它影响。

**双 5xx 那条判据刻意放在「传输层未知」，不当轮定罪。** 它只在引擎嗅探不到任何特征
（`engine == "openai"`）时才生效，而 vLLM 与 llama.cpp 的身份标签恰恰来自 `/metrics` 正文里的
`vllm:`／`llamacpp:` 前缀：`/metrics` 一旦 5xx 或返回体读不出，嗅探就退回 `openai`，双 5xx 判据随即
成立。也就是说**一个健康运行的 vLLM／SGLang／llama.cpp，只要 `/metrics` 与 `/health` 同时抖一次**
（重启中的 exporter、被限流的监控端点都可能造成）就会被这条判据说服：引擎身份标签只对「嗅探成功的那一轮」
有效，并不能给双 5xx 判据免疫，所以这条一律归「传输层未知」走滞回，攒够 `SMG_WATCHER_PROBE_FAILURES`
才动手。
确实是「API 网关只代理 /v1」的裸 OpenAI 接口（本仓实测：21.k 的 openresty :9080），用
`SMG_WATCHER_ALLOW_MODELS_ONLY=1` 在**注册准入**上放行。

**例外（操作员开关，与上面的摘除保险丝是两件事）**：`SMG_WATCHER_ALLOW_REMOVE=false` 时本条**不删**（滞回达标那条路径同样不删），
只在第一轮 warn 一次，之后靠 `entry.warned` 静音；服务重新被探到时该标记清掉，所以「恢复后再坏」仍会
再提醒一次。理由是那个开关是「只许加不许删」的明确约定，探针结论再确定也不能替操作员做删除决定，
否则严格探针就成了绕过保险丝的后门。

**代价**：一个反复好坏的服务每轮会产生一次 remove + 一次 add 的 churn（以及 `registry.add` 带来的
policy generation bump），每次 add 之后还要重新攒 `health_success_threshold` 个周期才恢复接流。这是
有意的取舍——抖动比僵尸行便宜，僵尸行的代价是持续的 5xx 与一个假的「该模型仍有实例」视图。

与 activity probe（偏差 5）的关系：两者互补，不重叠。activity probe 抓的是「`/v1/models` 答得很好、
但已经生成不出 token」（llama.cpp 权重没了还在报模型列表），本条抓的是「连模型列表都读不出来」；
activity probe 仍未移植，所以前一种僵尸目前无人管。

---

## 2. env 映射表

守护进程的 `LLM_WATCHER_*`（裸名亦可）→ 合并形态的 `SMG_WATCHER_*`。前缀换了，
语义与默认值不变；`_` 后缀差别（`INTERVAL` → `INTERVAL_SECS`）只为与仓库里既有的
`*_SECS` 命名一致。

| LLM_WATCHER_* | SMG_WATCHER_* | 默认 | 备注 |
|---|---|---|---|
| `TARGETS` | `TARGETS` | 空 | 逗号/空格/分号分隔，可远程 |
| `DOCKER` | `DOCKER` | off | 原默认 on；合并形态三个发现源全部默认关，见 §4 偏差 1 |
| `PROC_SCAN` | `PROC_SCAN` | off | 同上 |
| `CONTAINER_IPS` | `CONTAINER_IPS` | on | 仅在 `DOCKER=1` 时有意义 |
| `DOCKER_SOCKET` | `DOCKER_SOCKET` | `/var/run/docker.sock` | cosocket `unix:` 形式 |
| `INTERVAL` | `INTERVAL_SECS` | 15 | |
| `PROBE_TIMEOUT` | `PROBE_TIMEOUT_SECS` | 3 → **4** | 对齐任务书的缺省值，见 §4 偏差 3 |
| `WORKERS` | —— | 16 | 未移植：`ngx.thread` 池固定 8，见 §4 偏差 4 |
| `MAX_MODELS` | `MAX_MODELS` | 8 | 0 关闭 |
| `REQUIRE_HEALTH` | `REQUIRE_HEALTH` | off | |
| `ALLOW_MODELS_ONLY` | `ALLOW_MODELS_ONLY` | off | `/health`+`/metrics` 双 5xx 判活的放行阀 |
| `ALLOW_REMOVE` | `ALLOW_REMOVE` | on | off 时只警告一次 |
| `REMOVE_GRACE` | `REMOVE_GRACE_SECS` | 300 | |
| `KEEP_LAST` | `KEEP_LAST` | on | false ⇒ `KEEP_LAST_GRACE_SECS=-1`（关闭守卫 6） |
| `KEEP_LAST_GRACE` | `KEEP_LAST_GRACE_SECS` | 1800 | 0=永久保护 |
| `ADD_CONFIRM_TIMEOUT` | `ADD_CONFIRM_TIMEOUT_SECS` | 180 | 守卫 7 |
| `SHORT_MODEL_NAMES` | `SHORT_MODEL_NAMES` | off | `/models/x.gguf` → `x` |
| `MODEL_MAP`（及 `LMR_MODEL_MAP`/`LMR_MODLE_MAP`/`MODEL_ID_MAP`/`MODEL_RENAME`） | `MODEL_MAP`（兼容读 `LMR_MODEL_MAP`） | 空 | `orig:new,...`；运行时改由 `POST /model-map` |
| `EXCLUDE` | `EXCLUDE` | 空 | POSIX regex → Lua pattern，见 §4 偏差 6 |
| `ALLOW_PORT` / `DENY_PORT` | `ALLOW_PORT` / `DENY_PORT` | 空 | `8000-8020,11434` 形态不变 |
| `ROUTER` / `ROUTER_URL` / `ROUTER_API_KEY` | —— | —— | 合并形态没有「对面那个 router」：同进程直连 registry，鉴权层也已随 scope-trim 移除 |
| `WORKER_API_KEY` | —— | —— | 若要给 worker 带 key，用 `POST /workers` 的 `api_key` 字段 |
| `STATE_DIR` | —— | —— | ledger 改住 `lr_watch` |
| `METRICS_PORT` | —— | —— | 指标改由 router 自己的 `/metrics` 暴露 |
| `ACTIVITY_*`（5 个） | —— | —— | 未移植，见 §4 偏差 5 |

新增（无 Python 对应）：`SMG_WATCHER_ENABLED`（总开关，默认 off）、
`SMG_WATCHER_PROBE_FAILURES`（传输层未知的连续失败摘除阈值，缺省 2；1 等价于回到当轮即摘）、
`SMG_WATCHER_PROBE_FUSE`（单轮摘除保险丝开关，缺省 on；`=0` 关闭）。后两个是第 10 条守卫（§1.1）
的分档旋钮，只在探针摘除路径上生效，不影响守卫 5/6 的 grace 删除。

带 watcher 的两份 conf（`conf/lua-router.conf`、`conf/nginx.conf.template`）都补了上述 `env` 声明
（含第 10 条守卫新增的两个探针旋钮）与 `lua_shared_dict lr_watch 64k;`。`env SMG_WATCHER_*` 的条数以
conf 实际内容为准（本文不钉数字），新增旋钮时两份 conf 必须同时补——漏声明的 env 在 openresty 里
读不到值也不报错，只在运行期静默用缺省。

---

## 3. `/model-map` 兼容面

原守护进程把控制面挂在 metrics 端口上（`GET`/`POST :9912/model-map`）。合并形态挂在
router 主端口：

```
curl -s http://127.0.0.1:<SMG_PORT>/model-map                                   # 当前生效表
curl -s -X POST .../model-map -d '{"a.gguf":"a"}'                               # 形态 1
curl -s -X POST .../model-map -d '{"map":{"a.gguf":"a"}}'                       # 形态 2
curl -s -X POST .../model-map -d 'a.gguf:a,b.gguf:b'                            # 形态 3
curl -s -X POST .../model-map -d '{"map":"a.gguf:a,b.gguf:b"}'                  # 形态 4
curl -s -X POST .../model-map -d '{"a.gguf":""}'                                # 删条目
curl -s -X POST .../model-map -d '{"map":""}'                                   # 清掉历史污染的字面 key "map"
```

四种 body 与「POST 合并而非替换」「坏 body 400 并点名被忽略的条目」全部照抄
`parse_model_map_body`；形态 4 曾是历史坑（落进对象分支，把字面 key `map` 当成原始
模型 id，改名静默失效），单测与 e2e 都专门钉了它。

响应同时给两套字段：任务书要求的 `{"renamed":<map>,"status":"queued"}`，以及原版的
`{"model_map":<map>,"note":"owned workers are re-registered on the next pass"}`。
既有消费方 `config_store.lua` 的 `/_ui/config/model-map`（`LMR_WATCHER_URL` 指向
守护进程 metrics 口）因此只要把 URL 指到 router 主口就能继续用；请求侧改名不动，
仍走 `config_store` 的 virtual-models 别名机制。

---

## 4. 与 Python 版的偏差清单

1. **三个发现源默认全关**，只留 `SMG_WATCHER_ENABLED` 一道总闸之外的显式选择。守护
   进程默认 `--proc-scan --docker` 全开（它是个独立进程，扫到就算它的职责）；合并进
   router 之后，同一个进程既服务推理流量又自主决定池成员，默认全开等于让所有现存部署
   在升级瞬间多出一个看不见的写者。默认 off = 升级零行为变化。
2. **注册面从 HTTP 变成函数调用**：不再有 202/queued 的异步语义，`registry.add` 返回
   即生效。守卫 7 因此从「等 AddWorker job」改写为「等池子真的认账」，实现更简单，
   但保留的理由变了。
3. `PROBE_TIMEOUT` 缺省从 3 s 抬到 4 s（任务书指定），与 `SMG_HEALTH_CHECK_TIMEOUT_SECS`
   的 5 s 更接近。
4. **探针并发固定 8 条协程**（`ngx.thread.spawn`），没有 `--workers` 旋钮。守护进程要
   16 线程是因为它在解释器里串行跑 HTTP；cosocket 每次等待都 yield，8 条已经让整轮的
   成本等于最慢的那一个探针。
5. **活动探针（activity probe）未移植**：`/v1/models` 之外的「每分钟生成一个 token」
   判活、strikes 计数、`--activity-*` 五个旋钮都不在合并形态里。它解决的问题真实存在
   （llama.cpp 权重没了还在报模型列表），但代价是持续向每个 worker 注入真实推理，
   在一个和业务同进程的定时器里做这件事需要单独设计（限流、退避、失败不得拖慢
   reconcile）。这里先按 README 的原始九条交付，activity probe 列为后续项。
   `Hands over what it evicts` 因此暂时没有触发方：所有权交接仍由改名路径使用。
6. `--exclude` 从 POSIX regex 变成 Lua pattern（`node-exporter` 这类纯字面量两种
   写法一致；`[0-9]` 要写成 `%d`）。Lua 拒绝的 pattern（例如不配对的方括号）会退化成
   字面子串匹配而不是报错，所以一个坏 pattern 不会让整轮 discovery 失败。
7. **mixed-model 警告未移植**：`model_signature()` 没有对应调用点。Python 版发这条
   警告是因为 Rust 在 single-router 模式下选 worker 时忽略请求里的 model（README 实测
   10/10 命名本地模型的请求被远端接走）；本 Lua router 的 `candidates_for(model)`
   （router.lua:987）按 `record.model_id` 过滤候选，命名未注册的模型直接 404，不存在
   混发路径，因此这条警告无从触发。e2e `[1] chat by the renamed model id routes to
   that worker` 把「按 model 过滤」这件事钉成了断言。
8. **ledger 是 shdict 而不是磁盘 JSON**：容器重启即清零，这与 `lr_workers` 同为共享
   字典的事实一致（重启后池子也是空的，由 `SMG_WORKER_URLS` 与重新发现填回来）。
   `--dry-run` / `--once` 两个运维形态随之消失。
9. **`disable_health_check` 的判据来源相同**（探针拿不到可用 `/health` 就置位），
   但合并形态省掉了守护进程的 `--health-check-*-secs` 四个 per-worker 覆盖旋钮：
   `registry.add` 本来就只读 router 全局的健康参数（Rust 亦如此）。
10. **docker 发现只读 `/containers/json`，不逐个 `inspect`**：该端点的 `Ports` 字段
    已带 `PublicPort`/`PrivatePort` 映射，`NetworkSettings.Networks` 已带容器 IP，
    Python 版也是这么读的（`docker_candidates`）。任务书提到的「inspect 端口映射」因此
    由这一条批量请求覆盖，N 个容器只有 1 次 socket 往返。
11. **watcher 关闭时 `/model-map` 仍可读可写**：map 住在 `lr_watch`，与定时器是否运行
    无关，所以可以先配改名再打开 `SMG_WATCHER_ENABLED`。关掉的状态下改名不会作用到池子
    （没有 reconcile 去回收），这是有意的。
12. 一 URL 一模型、不展开 DP rank 这两条 README 里的 Limitations 原样成立，未在合并时改变。
    第三条（remote target 不可达后被 grace 摘掉）已被 §1.1 的第 10 条守卫改写：TARGETS 是静态清单，
    不可达的 remote target 永远「仍在被发现源报告」，摘除理由因此一律走探针分档而不是 grace——对方答了
    HTTP 却读不出 `data[].id` 属确定性否定，当轮摘；连不上／无应答属传输层未知，攒够
    `SMG_WATCHER_PROBE_FAILURES`（缺省 2）轮连续失败才摘。两条都不等 remove-grace，服务恢复后由下一轮
    正常重新注册回来（接流要再等 `health_success_threshold` 个巡检周期）。grace 路径从此只服务
    「发现源不再报它」这一种情形。
13. **timer 阶段的 cosocket recv 失败会被 nginx 记 [error]，deny 清单是唯一消音手段**。
    探针走 `hb.http_request`，其首行读取是 `sock:receive("*l")`；对端接受 TCP 后不回
    HTTP/1.1 文本（gRPC 的二进制 HTTP/2 帧、rpcbind 直接 RST），这条读就以 ECONNRESET
    结束，而该错误是 nginx **核心**在 `ngx.timer` 上下文里记的，`lua_socket_log_errors
    off` 挡不住（那条只压 lua 层的 cosocket 错误日志）。独立守护进程没有这个问题，因为
    Python 的 `http.client` 把 RST 当成普通异常吞掉——这是合并形态独有的日志噪音，只能
    在拨号之前消除。实测（2026-10-01 本机，间隔 15 s）每轮一条 `recv() failed (104:
    Connection reset by peer), context: ngx.timer`，归因到 `http://127.0.0.1:6334/v1/models`
    （qdrant 的 gRPC 口）：探针日志显示它每轮 `err=no response: connection reset by
    peer`。修法是两件事叠加：(a) `6334` 进 `DEFAULT_DENY_PORTS`（gRPC 永远不可能提供
    `/v1/models`，deny 掉零成本）；(b) 修好 deny 的合并语义（见下）。同时操作员可用
    `SMG_WATCHER_DENY_PORT` 追加本机特有的一次性 RST 口。
    **deny 语义修正**：`collect()` 原先在 `SMG_WATCHER_ALLOW_PORT` 为空时把整个 deny 变量
    赋成 `DEFAULT_DENY_PORTS`，操作员清单被整体丢弃（Python 版是
    `deny = cfg.deny_ports | (set() if cfg.allow_ports else DEFAULT_DENY_PORTS)`，是并集）。
    现在改成 `union_port_sets(cfg.deny_ports, DEFAULT_DENY_PORTS)`，allow 非空时仍只用操作员
    清单；allow-list 那一支仍无条件追加（与 daemon 一致：显式点名要探的口，两份 deny 都不
    拦），这条由单测 case 22b 钉住。守卫语义没有放宽：deny 只影响「拨不拨」，探针判定、
    protected/owned 账本与删除路径一行未动。

---

## 5. 测试

| 门禁 | 口径 | 数量 |
|---|---|---|
| 语法 | luajit `loadfile`（watcher/config/init/router/observability） | 5 份 |
| 语法 | `openresty -t`（conf/lua-router.conf、test/conf/nginx-lua-router.conf、模板渲染） | 3 份 |
| 单测 | `test/unit/test_watcher.lua`（luajit 与 apisix resty 两种口径，注入 fetch/reader/store，无 ngx） | 385 checks |
| e2e | `test/integration/e2e_watcher.py`（真容器 + 真 mock + 真 docker.sock + 容器重启） | 108 checks |

单测覆盖：`parse_model_map` 四分隔符与坏输入、`parse_model_map_body` 四形态 + 坏
body + 删除语义、`merge_map`、url 形态与 IPv6、`model_name`、`parse_ports`、
`gpu_from_name`、`is_excluded`、`classify`（拒连/HTML/无 id/聚合器/路由器指纹/双 5xx
判活/`require_health`/三种引擎嗅探）、`/proc/net/tcp{,6}` 解码（含 v4-mapped 与
v6 loopback）、docker 候选去重、`local_candidates` 与 allow/deny（含 case 22b：
deny 是 default ∪ 操作员、allow 非空时 default 让位、显式 allow  outranks 两份 deny、`union_port_sets` 对 nil 参数与字符串键的健壮性）、ledger 全部键操作、
候选在拨号前就被自端口与 exclude 拦掉、ledger 条目每轮续期、九条守卫各自的时序断言、`new_config` 缺省值与钳制、`collect` 三源合并。
第 10 条守卫（§1.1）另有一组用例：确定性否定当轮即摘（含 ledger 条目一并清掉）、传输层未知第一轮只计数
不摘、连续达到 `SMG_WATCHER_PROBE_FAILURES` 才摘、中途任一轮成功清零重算、`no probe transport` 与
`require_health` 都不摘也不计数、keep-last 不豁免确定性否定、单轮摘除超过 owned 一半时保险丝降级为只
warn、`SMG_WATCHER_PROBE_FUSE=0` 时保险丝不生效、`allow_remove=false` 时只警告一次、恢复时按正常 add
门槛回来、以及「发现源不再报它」仍旧先走 grace 计时（防止把两种情形写混）。
（本节用例清单随实现落地；`check` 数字仍以上方表格与门禁日志为准。）

e2e 按 [1]–[5] 分五组、四个启动器（grace 与 keep-last 共用一个容器对，docker 发现与容器重启同理）：TARGET 注册 + env 改名 + 四形态 API + 改名回收 + 按 public id 真实路由；
proc scan 发现 + 自端口排除 + 非 OpenAI 端口排除 + `SMG_WORKER_URLS` 保护快照（守卫 3
的两面都测：停掉的保护 worker 越过 grace 仍在池内、计数不增，而一次 `POST /model-map`
改名会让它被领养、改挂新 public id、此后才受 remove-grace 约束）；grace 窗口内保留 /
窗口后删除（keep-last 关掉以隔离守卫 5）；keep-last 生效与自身宽限到期；docker unix
socket 发现（容器名标签）+ 容器删除后离池；容器重启后重新发现并恢复流量。

日志：`/data/tmp/lr-gates/gates-rest-174123.log`（e2e 门 108 checks，含探针摘除两场景）、
`/data/tmp/lr-gates/gates-20261001-171333.log`（build/conf/unit/contract/probes 全绿，
contract 650 checks，17:13 一轮）。

### 5.2 recv-RST 噪音的 A/B 证据（偏差 13）

同一台机器、同一份生产 env（`SMG_WATCHER_PROC_SCAN=1`、`SMG_WATCHER_DOCKER=1`、
`SMG_WATCHER_DENY_PORT=111,5432,11022,14389,42209`、四个远程 TARGET、docker.sock 只读挂载）、
同一套缺省节奏（interval 15 s / probe timeout 4 s），差别只有镜像：

| 镜像 | 70 s 内 `recv() failed (104` | 其他 timer 上下文 [error] | `watcher: registered` |
|---|---|---|---|
| `lua-router:pre-deny`（修复前） | 4 | 4 | 1 |
| `lua-router:integration`（修复后） | **0** | **0** | 1 |

两侧都注册了同一个 worker，所以零错误不是空转出来的。原始日志
`/data/tmp/lr-watch/ab2_pre.log`、`ab2_post.log`，脚本 `ab2.sh`。归因证据在
`inst.log`（插桩探针：23 条 `lrwatch-probe http://127.0.0.1:6334/v1/models -> nil
err=no response: connection reset by peer`，且 `:111` 探针行数为 0 —— 111 从未被拨，
前手「111 漏网」的判断不成立，默认清单本来就挡住了它）与 `deny_diff.lua`
（修复前操作员清单被丢弃：11022/14389/42209 仍在候选里；修复后 `denied-but-present: 0`）。

### 5.1 单测/e2e 期间发现并修掉的真问题

| 现象 | 根因 | 影响 |
|---|---|---|
| `watcher.lua` 加载即报 `unexpected symbol near 'until'` | `{ n = n, until = ... }` 用了 Lua 关键字作表键 | 原稿从未过语法门；改键名 `until_ts` |
| 方括号 IPv6 候选端口丢失（`http://[::1]:8000` → `http://[::1]`） | `(%[[^%]]+%])(:?%d*)$` 把冒号吃进端口捕获，`tonumber` 失败返回 nil | 自环守卫与 id 计算都会错；改成括号组外再切端口 |
| `is_self_url("http://[::1]:3000")` 恒 false | `split_http` 返回带方括号的主机名，loopback 表里是 `::1` | v6 loopback 上的自注册无守卫；先剥括号再查表 |
| `/proc/net/tcp6` 的 v6 loopback 与 v4-mapped 地址解析错误 | Python 版直接拿原始 hex 比对 `"0…1"`/`"0…ffff"`，而内核按 4 个小端 32-bit word 存储，真机上这两个常量永不命中 | v6 场景下守卫 1 失效；改成先按 word 内字节反转再判定 |
| owned 条目只在状态变化时回写 | `lr_watch` 条目带 TTL，长期健康的 worker 一小时内不写就过期 | 条目消失后该 URL 脱离删除循环，成为永久僵尸；改成每轮见到就续期 |
