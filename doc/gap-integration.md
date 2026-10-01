# gap-integration：history / tokenizer+parse / mesh 接线报告

把三个已完成模块（resty.luarouter.{history,tokenizer,parse,mesh}）接入真实 HTTP
路由。范围只含 HTTP 面，不含 gRPC / PD 分离（另线进行）。基线：接线前契约
474 passed / 3 notes / EXIT=0；接线后 **659 passed / 3 notes / EXIT=0**
（对账：474 − 24 条过期 501 断言 + 86 history_crud + 80 tokenizer_plane
+ 41 mesh enabled 新增 + 2 tokenize 400 断言净增 = 659）。

改动文件：`lualib/resty/luarouter/router.lua`、`init.lua`、`registry.lua`
（最小改）、`mesh.lua`（一处最小 bug 修，见 §5.1）、三个 conf、
`docker-entrypoint.sh`、`test/test_lua_router.sh`、自有 `test/mock_llm_worker.py`
未改路由（用套件内 tok_worker 替身代替）。history.lua / tokenizer.lua /
parse.lua 零改动。

## 1. history 接线

### 1.1 配置与生命周期

- 三个 conf 均加 `lua_shared_dict lr_history 10m`；锁复用现有 `lr_locks`
  （history.lua 的 `with_lock` 走 resty.lock，独立 dict 无必要）。
- `init.lua init()`：解析 `SMG_HISTORY_BACKEND` /
  `SMG_HISTORY_MAX_{CONVERSATIONS,ITEMS_PER_CONVERSATION,RESPONSES,ITEMS_PER_REQUEST}` /
  `SMG_HISTORY_TTL_SECS` 并 `history.configure`（未知 backend 名坍缩为 memory，
  与 Rust clap 行为一致）。
- `worker_init()`：`start_history_sweep()` —— 每 `eviction_interval_secs`
  （默认 120s）跑一次 `history.sweep`，负责 TTL 与索引漂移后的封顶
  （shared dict 里 cap 只能靠走索引的人执行）。

### 1.2 路由表 → 模块函数（全部 `check_data_auth`，Rust protected_routes 同组）

| 端点 | history.lua 函数 | 应答形 |
|---|---|---|
| POST /v1/conversations | create_conversation | 200，Rust 用 OK 非 201 |
| GET/POST/DELETE /v1/conversations/{id} | get/update/delete_conversation | conversations 面 `{"error":"<msg>"}` + X-SMG-Error-Code |
| GET/POST /v1/conversations/{id}/items | list/create_items | envelope {data,first_id,last_id,has_more,object:"list"}；create 按提交序列出 |
| GET/DELETE /v1/conversations/{id}/items/{iid} | get/unlink_item | 未知 item GET 404；DELETE 幂等 200 回 conversation（Rust 同样不看 unlink 结果）|
| GET/DELETE /v1/responses/{id}、POST …/cancel、GET …/input_items | get/delete/cancel/list_input_items | responses 面 openai 错误形 `{"error":{type,code,param,message}}` + X-SMG-Error-Code |
| GET /_ui/history | history.stats() | 开放（与 /_ui/logs、/_ui/stats 同组）|

- 404 兜底同时把 `/ha/*` 与 `/_mesh/internal/*` 前缀引到 mesh 门（修正了原先
  `string.find(..., "^/_mesh/internal/", 1, true)` 把 `^` 当普通字符的失效判定，
  改为 `uri:sub(1,n)` 前缀切片）。
- `/_ui/history` 在 nginx 配置里必须有 **exact location**：ui.conf 的
  `^~ /_ui/` 静态前缀优先于 `location /`，否则被 SPA alias 吃掉回 nginx 404。
  `conf/nginx.conf.template`（${SERVER_EXTRA} 前）与
  `test/conf/nginx-lua-router.conf`（include ui.conf 前）各补一条；
  `conf/lua-router.conf` 是裸 conf（不含 ui.conf）不需要。

### 1.3 POST /v1/responses 的持久化语义（读了 Rust gateway 源码确认，非猜测）

- Rust：openai 非流式路径 `persist_conversation_items` 无条件调用
  （gateway/src/routers/openai/responses/non_streaming.rs:149，不看 `store`
  字段；`store` 只是被回写进响应体）；gRPC Regular/PD 路径走
  `persist_response_if_needed`（store 默认为 true 时才存），普通 worker 转发
  不写，GET/cancel/delete/input_items 落 trait 默认 501 纯文本
  （<dev-box>:8800 采样证实）。
- lua-router：`route_inference` 在 `route == "/v1/responses"` 且非流式 2xx 时调
  `persist_response`：`normalize_response_input` 把 string input 归一成
  `input_text` message item，`set_top_field` 注入 conversation_id/input 后
  `history.create_response`（在原字节上改写头部，不 re-encode，GET 回显原始
  worker 字节）。SSE 流式不存。这是 **OpenAI-mode 超集**：本路由的
  /v1/responses 本来就是 OpenAI-mode，所以无条件存。
- 绑定了已存在 conversation 时，input+output item 镜像进会话 items
  （带 response_id），与 Rust create_response 的 link 语义一致；conversation
  不存在则只存 response，不隐式建会话。

### 1.4 backend=none（Rust NoOp 对齐）

`SMG_HISTORY_BACKEND=none`：POST /v1/conversations 合成 200 对象、其余读写
（含 item 面与 response 管理面）一律 404（`ensure_conversation_exists` 先行），
推理面照常 200 且不落库，`/_ui/history` 报 `backend:"none"`。契约逐条断言。

## 2. tokenizer / parse 接线

### 2.1 端点与 auth 分组（Rust server.rs:1279-1364）

- 数据面 key（`check_data_auth`）：`POST /v1/tokenize`、`POST /v1/detokenize`。
- 控制面 key（`check_control_auth`，回退数据面 key）：`GET/POST
  /v1/tokenizers[/{id}[/status]]`、`POST /parse/function_call`、
  `POST /parse/reasoning`（含 HEAD 别名）。
- auth 缝经 `tokenizer_mod.auth_checks` / `parse_mod.auth_checks` 显式注入
  （不依赖 package.loaded 顺序）。`/klib/load` 清单加
  `resty.luarouter.{history,tokenizer,parse,mesh}`。

### 2.2 行为（模块语义，契约全部断言）

- 校验先行：tokenize 缺 `prompt` → 400 `prompt is required…`；detokenize 缺
  `tokens` → 400；parse 缺 text/parser 名 → 400；坏 JSON → 400
  `invalid_json`。全部发生在选后端之前。
- 无声明后端：tokenize/detokenize → 501 `tokenizer_unavailable`（Rust 的 400
  "no tokenizer loaded" 措辞差异见 §5.2）；parse → 503
  `{"error":"Tool parser factory not initialized","success":false}`；声明了
  别的 parser 名时 → 400 `Unknown tool parser: nope (workers advertise: hermes)`。
- 选后端：registry record 的 `tokenizer_path`/`tool_parser`/`reasoning_parser`
  字段（POST /workers 顶层）或 `labels.*`；rank = 精确名 > 任意声明。代理
  **字节透传**（含后端自己的 500 体），仅连接失败才回 502/503。
- 管理 job：POST /v1/tokenizers → 202 pending；重名 → 409
  `{id,status:"failed",message:"Tokenizer '<n>' already exists"}`；缺
  name/source → 400。`GET /v1/tokenizers` 只列 completed，`?all=1` 带上
  pending（Rust 超集）；completed 的唯一途径是有存活 worker 广告同名能力
  （Lua 不加载 tokenizer，job 是记账不是加载）。未知 id：GET 404
  `tokenizer_not_found`、/status 404 `not_found`、DELETE 404
  `success:false`；DELETE 已知 → 200 `success:true`。
- registry.lua 最小改：record 带上 WorkerSpec 同名字段
  `tokenizer_path/tool_parser/reasoning_parser/vocab_size`（string_field 保证
  缺省是 absent 而非 cjson.null），供模块读取。

## 3. mesh 接线

### 3.1 disabled（默认，SMG_ENABLE_MESH 未设）

`/ha/*` 与 `/_mesh/internal/*` 一律 503 `{"error":"mesh not enabled"}`（含深
路径 404 兜底路径），与接线前逐字节一致；无 key 时 `/_mesh/internal/*` 额外
有 loopback 门：非 127.0.0.1 请求 → 403 `forbidden`（防匿名注入伪造集群状态，
doc/gap-mesh.md §6.1；契约断言 403）。

### 3.2 enabled（SMG_ENABLE_MESH=1|true|yes|on）

- init 捕获 `SMG_MESH_PEERS/SELF/SELF_NAME/SYNC_INTERVAL_SECS/…`（见 init.lua
  的 mesh_state），worker0 `inst:start()` 定时 sync；无 peers 时打 WARN 且
  `/ha/*` 保持 503（实例级降级而非崩溃）。
- `worker_processes` 钉 1：docker-entrypoint.sh 在 mesh 真值且未显式
  `NGINX_WORKER_PROCESSES` 时覆盖 —— mesh 状态在进程内存，多 worker 会分裂
  （Rust 单进程天然无此问题，这是本实现的环境差异，见 §5.5）。
- `/ha/status|health|workers[/id]|policies|config|rate-limit[/stats]|stats|shutdown`
  全部委托 `mesh.dispatch`；`/_mesh/internal/{ping,sync,apply,state}` 同理。
- 鉴权门 `mesh_control_auth`：配了 key → /ha/* 与 /_mesh/internal/* 都要控制面
  key（回退数据面 key，Rust auth_middleware 语义），实测无 token 一律 401
  `invalid control plane key`；没配 key → /ha/* 开放、内部端点仅 loopback。
  出站同步带 `Bearer <key>`（fake peer 的 bad_auth 计数验证 =0）。
- 本地状态镜像进 mesh store：policy 变更 + 路由树（mirror_mesh_state：
  observe_policy/observe_tree，manual 覆盖不镜像），worker
  create/update/delete → observe/forget worker。

### 3.3 契约（enabled 两节点最小用例 = 单实例 + fake peer mock）

`start_mesh_peer`（说 mesh 线格式的 Python 替身，记录 sync/apply/seen/bad_auth）
+ 带 SMG_API_KEY 的实例：401 门、200 全 /ha 面、config/rate-limit 读写、
deep path enabled 404（`unknown ha route`，与 disabled 503 不同，见 §5.4）、
sync 坏 envelope 400、shutdown 202 → self `leaving` + peer 收到
`lr-contract:leaving` 广播、收敛断言 `node_count==2`（见 §5.3 幻影键）。

## 4. 测试证据（全部 2026-09-30 本机复跑）

| 门 | 结果 | 日志 |
|---|---|---|
| openresty -t（test conf + conf/lua-router.conf） | 双 conf syntax OK（含 gate 段在套件内复跑） | contract_strict.log §gate |
| 单测 tree/policies/hash（apisix resty） | 67 / 118 / 795，0 failed | /data/tmp/gapint/unit_test_*.log |
| 单测 history / mesh（authz luajit） | 731 / 361，0 failed | 同上 |
| 单测 tokenizer_parse（apisix resty） | 316，0 failed | unit_test_tokenizer_parse.log |
| 契约严格全量（22 段） | **659 passed / 3 notes / EXIT=0**（KEEP_GOING 分诊同为 659/0） | /data/tmp/gapint/contract_strict.log |
| e2e_stateful / policies / ui_bridge | **43 / 65 / 19，0 failed**（lua-router:integration 重新 build 后） | /data/tmp/gapint/e2e_*_v2.log |

## 5. 与 Rust 的差异（有意为之，全部写进契约注释）

1. **mesh.lua 最小 bug 修（唯一一次模块改动）**：`mark_sync_success` 会把已是
   `leaving` 的对端翻回 `alive`，违反"leaving 不可逆"语义；改为对端 leaving
   时直接返回。test_mesh 361 复跑通过。
2. **tokenizer 无后端的措辞**：Rust 回 400（tokenizer 服务不存在）；本实现回
   501 `tokenizer_unavailable`——语义上"能力存在但暂无后端"更贴近 501，且与
   wasm 的 not_implemented 区分开。已按 501 断言。
3. **/ha/status 幻影键**：seed peer 以 hostport 记账，对端自报名不同则短暂出现
   第 3 个 `init` 成员，收敛后合并。契约用 mesh_wait_peer 轮询
   `node_count==2` 而非直接断 3。若日后要求即时准确，应在 mesh.lua 合并
   member_key_for_address 的时机上做真修（越出本次最小修授权）。
4. **/ha 深路径**：disabled 503 `{"error":"mesh not enabled"}`（保持旧契约）；
   enabled 404 `{"error":"unknown ha route: <METHOD> <path>"}`（dispatch 的
   兜底措辞）。Rust 两种情况都是 axum fallback 404 空体。
5. **环境变量命名**：Rust 是 `--enable-mesh` / `--mesh-peer-urls` CLI；本实现
   `SMG_ENABLE_MESH` / `SMG_MESH_PEERS` / `SMG_MESH_SELF[_NAME]` 等
   （容器化网关无 CLI 面，风格与既有 SMG_* 一致）。
6. **`/_mesh/internal/*` 端口归并**：Rust 放独立 mesh 端口（39527），内部端点
   无 HTTP 鉴权、靠网络隔离；本实现放业务端口，用控制面 key + 无 key 时仅
   loopback 的更严门补偿（收紧方向，契约断言 401/403）。
7. **MAX_ITEMS_PER_REQUEST**：Rust 硬编码 20，history.lua 默认 100
   （`SMG_HISTORY_MAX_ITEMS_PER_REQUEST` 可配）。
8. **response 存储范围**：本实现"非流式 2xx 无条件存"，是 Rust OpenAI-mode
   行为的超集（Rust 的 Regular/PD 不存路径在 lua-router 不存在）。
9. **`/_ui/history` 需要 exact location**：nginx 前缀匹配语义（`^~`）与 Rust
   nest 路由顺序不同导致的路由优先级补偿，实现细节而非协议差异。

## 6. 遗留与后续

- `POST /v1/responses` 的流式（SSE）响应仍不入库。Rust openai 流式在
  `store=true || conversation 已设` 时用 StreamingResponseAccumulator 聚合后
  入库（streaming.rs:554-566）；本实现缺 SSE 聚合器，先按不存处理，宁缺毋错。
- mesh 两真节点（双容器互 seed）未进契约（fake peer 已覆盖收敛/鉴权/广播
  三要素）；留给人工验证或后续 e2e。
- router.lua 的 404 兜底 `sub()` 修 + mesh.lua leaving 修都属"发现 bug 最小
  修"，其余未动。
