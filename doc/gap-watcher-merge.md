# watcher 合并：把独立部署的 llm-watcher 搬进 lua-router 进程内

实现文件：[watcher.lua](../lualib/resty/luarouter/watcher.lua)（纯逻辑层 + live 接线层）、
[init.lua](../lualib/resty/luarouter/init.lua)（worker 0 定时器接线）、
[config.lua](../lualib/resty/luarouter/config.lua)（`cfg.watcher` 段）、
[router.lua](../lualib/resty/luarouter/router.lua)（`GET`/`HEAD`/`POST /model-map`）、
[observability.lua](../lualib/resty/luarouter/observability.lua)（`lr_watch_*` 登记点）、
三份 conf（`env` 声明 + `lua_shared_dict lr_watch`）。
单测：[test_watcher.lua](../test/unit/test_watcher.lua)（253 checks）。
e2e：[e2e_watcher.py](../test/integration/e2e_watcher.py)（56 checks）。

语义移植基准：`llm-router/watcher/llm_watcher.py`（1577 行）与同目录 `README.md`
的守卫表。原守护进程通过 HTTP 控制面（`POST`/`DELETE` /workers，202=queued）间接
驱动一个在跑的 router；合并形态跑在 router 进程里，注册就是直接调
`registry.add` / `registry.remove`，ledger 从磁盘上的 `ledger.json` 变成
`lr_watch` 共享字典。

---

## 1. 九条守卫逐条对照

| # | README 守卫 | Python 实现 | Lua 实现 | 测试 |
|---|---|---|---|---|
| 1 | No self-loop | `probe_all` 比对 router.port + `ROUTER_FINGERPRINT_KEYS` | `is_self_url()`（loopback + 自有端口）与 `classify()` 的 `/server_info` 指纹两道；`SMG_PORT`/`SMG_METRICS_PORT` 由 `new_config` 收进 `self_ports`，连候选都不是 | unit `normalize_url/split_http/is_self_url`、`guards 1/2 applied in reconcile`；e2e `[2] the router's own port is never a candidate` |
| 2 | 只认真 OpenAI 端点 | `probe_worker`：`/v1/models` 必须 `data[].id` | `classify()` 同一条：非 2xx/4xx、无 `data[].id`、空 `data[]` 全部拒 | unit `classify`（HTML 404、`{"ok":true}`、空 data 三种形状）；e2e `[2] a non-OpenAI listener never becomes a worker` |
| 3 | 首接触快照 protected | `first reconcile` 把 `GET /workers` 全量写进 `ledger.protected` | `reconcile()` 开头 `ledger.touched()` 未置位且 protected/owned 皆空时快照，`desired = discovered - protected` | unit `guard 3 first-contact protection`；e2e `[2] the seed worker is snapshotted as protected` + 消失后不被删 |
| 4 | 只删自己 ledger 里的 | 删除循环走 `ledger.owned` | 同上，且 `unregister()` 先 `registry.get(id)` 确认记录仍在 | unit `guards 4/5`、`allow_remove false`；e2e `[3] the deletion is counted once` |
| 5 | remove-grace 300 s | `missing_since` + `--remove-grace` | 同结构，`SMG_WATCHER_REMOVE_GRACE_SECS` 默认 300 | unit `guards 4/5`；e2e `[3]` 两条（窗口内保留 / 窗口后删除） |
| 6 | Never empties a model | `_is_last_for_model` + `--keep-last-grace` 到期后才删 | `is_last_for_model()`（不健康的同模型兄弟不算覆盖）+ `keep_last_grace_secs`，`0`=永久保护，负值=关掉（`SMG_WATCHER_KEEP_LAST=false`） | unit `is_last_for_model`、`guard 6 keep-last`（含只警告一次、grace 到期、0=永久）；e2e `[4]` 三条 |
| 7 | Releases stuck adds | 202 只代表 queued，AddWorker job 卡在死 URL 上会永久占住该 URL | 合并形态没有 job 队列，`reap_pending()` 保留下来管另一件事：ledger 声称拥有、但池子里没有的 URL（手工 DELETE、或 reload 把 `lr_workers` 清空而 `lr_watch` 还留着），超过 `add_confirm_timeout_secs` 就删掉释放 URL，同一轮即可重新注册 | unit `guard 7 stuck add released` |
| 8 | Survives a router restart | 周期性 `GET /workers` 刷新 worker_id | `reconcile()` 每轮把 `entry.worker_id` 与池内实际 id 对齐；容器重启形态下 `lr_watch` 与 `lr_workers` 一起清空，重新发现即重建（合并语义等价） | unit `guard 7` 里的 id 采用断言；e2e `[5] after a router restart rediscovery re-registers` |
| 9 | Blind by design | 只读 HTTP 端点，不碰 GPU、不起停服务 | 同：只访问 `/v1/models` `/server_info` `/get_server_info` `/props` `/metrics` `/health`，docker 侧只读 `/containers/json`，`/proc` 侧只 `io.open` 读文件，全程无 `io.popen`、无子进程、无 GPU 读取 | 代码审读 + live 层无 `os.execute`/`io.popen` |

`Probes that it really generates`（活动探针，每分钟让每个 worker 生成一个 token）与
`Hands over what it evicts`（驱逐 protected worker 时接管所有权）**不在这九条里**，
前者未移植（见 §4），后者已移植：改名与所有权交接走 `ledger.unprotect` 那条路径，
单测 `model map renames reach the pool` 覆盖。

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

新增（无 Python 对应）：`SMG_WATCHER_ENABLED`（总开关，默认 off）。

三份 conf 都补了这 20 个 `env` 声明与 `lua_shared_dict lr_watch 64k;`。

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
12. 一 URL 一模型、不展开 DP rank、remote target 也会因不可达被 grace 摘掉——这三条
    README 里的 Limitations 原样成立，未在合并时改变。

---

## 5. 测试

| 门禁 | 口径 | 数量 |
|---|---|---|
| 语法 | luajit `loadfile`（watcher/config/init/router/observability） | 5 份 |
| 语法 | `openresty -t`（conf/lua-router.conf、test/conf/nginx-lua-router.conf、模板渲染） | 3 份 |
| 单测 | `test/unit/test_watcher.lua`（luajit 与 apisix resty 两种口径，注入 fetch/reader/store，无 ngx） | 253 checks |
| e2e | `test/integration/e2e_watcher.py`（真容器 + 真 mock + 真 docker.sock + 容器重启） | 56 checks |

单测覆盖：`parse_model_map` 四分隔符与坏输入、`parse_model_map_body` 四形态 + 坏
body + 删除语义、`merge_map`、url 形态与 IPv6、`model_name`、`parse_ports`、
`gpu_from_name`、`is_excluded`、`classify`（拒连/HTML/无 id/聚合器/路由器指纹/双 5xx
判活/`require_health`/三种引擎嗅探）、`/proc/net/tcp{,6}` 解码（含 v4-mapped 与
v6 loopback）、docker 候选去重、`local_candidates` 与 allow/deny、ledger 全部键操作、
候选在拨号前就被自端口与 exclude 拦掉、ledger 条目每轮续期、九条守卫各自的时序断言、`new_config` 缺省值与钳制、`collect` 三源合并。

e2e 六个场景：TARGET 注册 + env 改名 + 四形态 API + 改名回收 + 按 public id 真实路由；
proc scan 发现 + 自端口排除 + 非 OpenAI 端口排除 + `SMG_WORKER_URLS` 保护快照（消失后
仍不删）；grace 窗口内保留 / 窗口后删除（keep-last 关掉以隔离守卫 5）；keep-last 生效
与自身宽限到期；docker unix socket 发现（容器名标签）+ 容器删除后离池；容器重启后重新
发现并恢复流量。

日志：`/data/tmp/lr-watch/e2e_watcher.log`、`/data/tmp/lr-watch/unit.log`。

### 5.1 单测/e2e 期间发现并修掉的真问题

| 现象 | 根因 | 影响 |
|---|---|---|
| `watcher.lua` 加载即报 `unexpected symbol near 'until'` | `{ n = n, until = ... }` 用了 Lua 关键字作表键 | 原稿从未过语法门；改键名 `until_ts` |
| 方括号 IPv6 候选端口丢失（`http://[::1]:8000` → `http://[::1]`） | `(%[[^%]]+%])(:?%d*)$` 把冒号吃进端口捕获，`tonumber` 失败返回 nil | 自环守卫与 id 计算都会错；改成括号组外再切端口 |
| `is_self_url("http://[::1]:3000")` 恒 false | `split_http` 返回带方括号的主机名，loopback 表里是 `::1` | v6 loopback 上的自注册无守卫；先剥括号再查表 |
| `/proc/net/tcp6` 的 v6 loopback 与 v4-mapped 地址解析错误 | Python 版直接拿原始 hex 比对 `"0…1"`/`"0…ffff"`，而内核按 4 个小端 32-bit word 存储，真机上这两个常量永不命中 | v6 场景下守卫 1 失效；改成先按 word 内字节反转再判定 |
| owned 条目只在状态变化时回写 | `lr_watch` 条目带 TTL，长期健康的 worker 一小时内不写就过期 | 条目消失后该 URL 脱离删除循环，成为永久僵尸；改成每轮见到就续期 |

