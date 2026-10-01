# lua-router tokenizer / parse 缺口实现说明（agent: gap_tokenizer）

新增文件（**未改动任何既有文件**）：

| 文件 | 内容 |
|---|---|
| `lualib/resty/luarouter/tokenizer.lua` | `/v1/tokenize`、`/v1/detokenize`、`/v1/tokenizers` 管理面 handler + shared-dict job store |
| `lualib/resty/luarouter/parse.lua` | `/parse/function_call`、`/parse/reasoning` handler + 解析器能力路由 |
| `test/unit/test_tokenizer_parse.lua` | 316 条纯 Lua 断言（状态机 / 校验 / 候选选择 / 代理构造 / auth seam） |
| `doc/gap-tokenizer-parse.md` | 本文档 |

Rust 参照实现（写代码时逐项对照，未修改）：

- `gateway/src/server.rs:1312-1364` 路由表与两套 auth（`protected_routes` =
  数据面 key，`admin_routes` = 控制面 key）
- `gateway/src/routers/tokenize/handlers.rs` 全部管理面状态码
- `~/.cargo/.../openai-protocol-1.0.0/src/tokenize.rs` / `parser.rs` /
  `worker_spec.rs` 请求与响应 schema
- `gateway/src/routers/parse/handlers.rs` + `gateway/tests/api/parser_endpoints_test.rs`
  parse 面的成功/错误形状
- 生产 Rust 实例 `<dev-box>:8800`：写作时做过只读 GET/POST 采样（见 §5）

## 1. 策略：代理，不自研 BPE

Lua 侧**没有**任何分词实现，也不会去做。`/v1/tokenize` 与 `/v1/detokenize`
把调用方的原始字节转发给「声称支持 tokenizer」的 worker 的同名路径，并把 worker
的回答**逐字节**透传（状态码 + body + content-type）。管理面
（`/v1/tokenizers*`）是本路由自己的 shared-dict job store，用来记录「哪个
tokenizer 名字被谁认领了」，它不加载任何词表。

worker 是否算 tokenizer 后端，按下列面取值（第一个命中为准）：

| 面 | 来源 | 说明 |
|---|---|---|
| `record.tokenizer_path` | `POST /workers` 请求体字段 | 即 Rust `WorkerSpec.tokenizer_path`，本路由原样存进记录 |
| `labels.tokenizer_path` | registry 的 `discover()` 写入 | Rust `discover_metadata` 从 `/model_info` 取 `tokenizer_path` 落到同名 label |
| `labels.tokenizer` / `labels.tokenizer_id` | 运维在 `POST /workers` 的 `labels` 里手填 | 值 `true`/`yes`/`1` 视为「有 tokenizer 但未具名」，仍可作兜底候选 |
| 管理 job 的 `source` 指向某 worker URL | `POST /v1/tokenizers {"name":"qwen2.5","source":"http://10.0.0.5:8000"}` | 不动 labels 也能把名字绑到后端，见 §2.2 |

候选打分：具名且与请求 `model` 同名 = 2 分，其余声称支持的 = 1 分；只在最高分档
内随机（与 `SMG_POLICY=random` 的行为一致）。没有任何候选 → **501
`tokenizer backend unavailable`**。

## 2. 接口表

### 2.1 分词面（数据面 api key，`check_data_auth`）

| 方法 路径 | 校验 | 无后端 | 上游失败 |
|---|---|---|---|
| `POST /v1/tokenize` | `model` 可为 string（缺省 `unknown`）；`prompt` 必填，string 或 string 数组 | `501 tokenizer_unavailable` | `502 tokenizer_backend_error` |
| `POST /v1/detokenize` | `tokens` 必填，u32 数组或 u32 数组的数组（不可混用）；`skip_special_tokens` 可选 bool，缺省 `true` 由 worker 决定 | 同上 | 同上 |

转发体是**调用方原始字节**，不做 re-encode：cjson 分不清 `[]` 与 `{}`，重编码会
把 `"tools":[]` 变成 `"tools":{}`。转发的请求头沿用 router.lua 的白名单
（`authorization`、`x-request-id*`、`x-correlation-id`、`traceparent`、`tracestate`、
`x-smg-routing-key`），外加 `content-type`/`accept`/`accept-encoding: identity`，
worker 记录里有 `api_key` 且调用方没带 `authorization` 时补上 Bearer。

### 2.2 管理面（控制面 api key，`check_control_auth`）

job 状态机四态 `pending / processing / failed / completed`，存在
`lr_workers` 共享字典的 `tok:job:<id>` / `tok:name:<name>` / `tok:ids` 键下（这些前缀
与 registry 自己用的 `w: hl: hf: hs: cbs: cbf: cbu: cbo: lo: url: u: job: disc: ids`
都不冲突，所以**不需要新增 `lua_shared_dict`**）。生命周期是读驱动的：任何一次
`GET`/`POST`/`DELETE` 先 `settle_all()` 再应答，`pending` 超过 5s 无认领转
`processing`，超过 120s 无认领转 `failed`，任一可用 worker 具名认领即转 `completed`
并带上该 worker 声称的 `vocab_size`。`failed` 的名字可以被同名重注册顶掉（旧 job 被
丢弃），`completed` 是终态。

| 方法 路径 | 成功 | 失败 |
|---|---|---|
| `POST /v1/tokenizers` | `202 {id,status:"pending",message}`（`vocab_size` 缺省不出现，同 Rust 的 `skip_serializing_if`） | 重名 `409 {id,status:"failed",message:"Tokenizer 'x' already exists"}`；缺 `name`/`source` 或非 JSON `400`；shared dict 不可用 `503 {id:"",status:"failed",message:"Job queue not available"}` |
| `GET /v1/tokenizers` | `200 {tokenizers:[{id,name,source,vocab_size}]}`，只列 `completed`；空列表序列化成 `[]` | — |
| `GET /v1/tokenizers?all=1` | 同上，另把未 `completed` 的 job 附 `status`/`message`/`updated_at` 列出（Rust 无此查询参数，是本实现的增量） | — |
| `GET /v1/tokenizers/{id}` | `200 {id,name,source,vocab_size}`；先按 id、再按 name（同 Rust） | 未知 `404 tokenizer_not_found`，body 为 `error_body` 形状 |
| `GET /v1/tokenizers/{id}/status` | `200 {id,status,message,vocab_size}`；`completed` 时 message 为 `Tokenizer 'x' is loaded and ready` | 未知 `404 not_found`，message `... not found and no pending job` |
| `DELETE /v1/tokenizers/{id}` | `200 {success:true,message:"Tokenizer 'x' removed successfully"}`，先 id 后 name | 未知 `404 {success:false,message:"Tokenizer 'x' not found"}` |

`id` 是 UUIDv4 形状（`generate_id()`）。Rust 用 `Uuid::now_v7()`，两者都只被当作
不透明 id 使用；这里不需要 v7 的时间有序性，且 Lua 侧没有 uuid crate，用 `bit` 手搓
v4 变体位是最省事的等价面。

### 2.3 parse 面（控制面 api key）

| 方法 路径 | 请求体 | 成功透传 | 错误 |
|---|---|---|---|
| `POST /parse/function_call` | `text`(string) + `tool_call_parser`(string) + `tools`(array) | `{remaining_text,tool_calls,success:true}` | 见下 |
| `POST /parse/reasoning` | `text`(string) + `reasoning_parser`(string) | `{normal_text,reasoning_text,success:true}` | 见下 |

worker 的解析器能力取自 `record.tool_parser` / `record.reasoning_parser`
（即 `WorkerSpec` 同名字段）或 `labels.tool_parser` / `labels.reasoning_parser`；
`true`/`yes`/`1` 同样是「有解析器但未具名」。打分：具名且与请求同名 `+4`、
`model_id` 与请求 model 相同 `+2`、未具名 `+1`，档位差远大于附加分，所以「名字不匹配
但 model 命中」不会盖过「名字精确命中」。**注意请求字段名与能力字段名不同**：Rust 的
请求体是 `tool_call_parser`（`openai-protocol/src/parser.rs`），worker 侧能力字段是
`tool_parser`（`worker_spec.rs`），本实现照抄这个区别。

错误分支：

| 情况 | 状态 | body |
|---|---|---|
| body 不是 JSON 对象 | `400` | `error_body` 形状（`invalid_json`）+ `X-SMG-Error-Code` |
| `text` 缺失/非 string，或 parser 字段缺失/空 | `400` | `error_body` 形状（`invalid_request`） |
|  fleet 里没有任何该面解析器 | `503` | `{"error":"Tool parser factory not initialized","success":false}`（与 Rust 逐字一致，reasoning 为 `Reasoning parser factory not initialized`） |
| 有解析器但没人认领请求的名字 | `400` | `{"error":"Unknown tool parser: <名> (workers advertise: <清单>)","success":false}` |
| 上游解析后端连不上 | `503` | `{"error":"parser backend <url> failed: <原因>","success":false}` |
| 上游返回非 2xx | 透传该状态 | 已是 parse 形状则逐字节透传，否则包成 parse 错误 |
| 上游 200 | `200` | 逐字节透传 |

**parse 的错误 body 是 Rust 的形状 `{"error":<字符串>,"success":false}`，不是
router.lua 的 `{"error":{type,code,message}}`** —— 那是
`routers/parse/handlers.rs::error_response` 的既有决定，客户端已经按它写，本实现
照抄而没有「顺手修正」；只有本路由自己读 body 才能发现的校验失败（非 JSON 对象、缺
必填字段）用 router 的 `error_body`，因为那种情况 Rust 是 axum `Json` extractor
答的 `422`，两边本来就不同形。

## 3. Rust 是本地解析，Lua 是代理等价面：差异清单

Rust 的 `/parse/*` **不转发任何东西**：`AppContext` 里持有
`tool_parser_factory` / `reasoning_parser_factory`（`tool-parser` /
`reasoning-parser` crate 的池化解析器），在网关进程内把文本切开。Lua 侧没有这两个
crate，所以选择代理给「注册时声明了同名解析器」的 worker。二者对外是同一个接口，
但有这些可观测差异：

1. **谁来判定名字合法性**。Rust 查自己的 registry，未知名一律 `400 Unknown tool
   parser: x`（`parser_endpoints_test.rs::test_parse_function_call_invalid_parser`
   证实）。Lua 查 worker 声明：没有任何 worker 带该面解析器 → `503 factory not
   initialized`；有但名字都对不上 → `400 Unknown ...`；有 worker 声明了**未具名**
   解析器 → 照样转发，由 worker 自己决定 400 还是 200。也就是说 Lua 的 `400`/`503`
   区分依据是「舰队里有没有」，不是「内置表里有没有」。
2. **空串 parser 名**。Rust 的 `Unknown` 判定发生在查表时，`""` 也是 `400`；Lua 把
   缺失或空串视为调用方错误，`400 invalid_request`（`error_body` 形状，不带
   `success:false`）。
3. **缺失字段**。Rust 走 axum extractor → `422`（`test_parse_function_call_missing_fields`
   断言 `UNPROCESSABLE_ENTITY`）；Lua → `400`，与它其余的 body 校验保持一致。
4. **谁做解析**。代理路径会把 `text` 送到后端再跑一遍解析，所以延迟等于后端
   往返；Rust 是进程内解析。功能等价、成本不等价，`/parse/*` 不适合高频调用。
5. **后端不支持该端点**。llama.cpp / 多数引擎根本没有 `/parse/*`，代理会拿到
   `404`，本实现把状态透传（body 非 parse 形状时包成
   `{"error":"parser backend said 404: ...","success":false}`）。要真正用上
   `/parse/*`，必须把解析器名字写在注册信息里（见 §5）。
6. **`tools` 数组的语义**。Rust 把 `tools` 交给内置解析器做校验；代理路径原样转给
   worker，是否使用由 worker 决定。因为字节原样透传，`"tools":[]` 不会被改写成 `{}`。

## 4. 已知限制

| # | 限制 | 影响 |
|---|---|---|
| L1 | 不实现 BPE/SentencePiece，`/v1/tokenize` 只代理 | 舰队里没有支持 `/v1/tokenize` 的后端（llama.cpp 就没有）时，这条链只能得到 `501`；Rust 同环境下是 `400 No tokenizers available. Use POST /v1/tokenizers to add one.`（实测见 §5），**状态码与措辞都不同**，依赖该 400 文案的客户端要适配 |
| L2 | `POST /v1/tokenizers` 只建 job，不加载词表 | 没有任何 worker 具名认领时，job 只会走 `pending → processing → failed`；`completed` 完全由后端声明驱动 |
| L3 | `vocab_size` 只在后端 label 主动上报时出现 | Rust 从真词表取；这里 label 缺失就省略该字段（不编造数字），`GET /v1/tokenizers` 的条目因此可能没有 `vocab_size` |
| L4 | job 存储在 `lr_workers`（2m），且带 24h TTL | 只够几百个 tokenizer 名字；字典被 LRU 淘汰后 job 记录消失，`GET /v1/tokenizers/{id}` 变 404。Rust 的 job queue 在内存里同样不是持久化的，但 worker 记录会恢复 |
| L5 | 生命周期是读驱动的 | 没有任何请求打到管理面时，`pending` 不会自己变 `processing`/`failed`。好处是不占定时器；代价是外部轮询者看到的推进时刻取决于它自己的轮询 |
| L6 | `tokenizer_candidates()` 每请求做一次 O(jobs × workers) 扫描 | worker 与 job 数量都小，可接受；不做缓存以保持与 worker 上下线一致 |
| L7 | `GET /v1/tokenizers/{id}` 对未 `completed` 的 job 返 `200`（额外带 `status`/`message`） | Rust 该端点只查已加载表，只有 job 没词表时返 `404`（`/status` 才会回 `200 pending`）。这里选择 200 是为了让只轮询 `/{id}` 的客户端也能看到推进；要严格对齐 Rust，把 `handle_get_tokenizer` 里 `job.status ~= "completed"` 的分支改成 404 |
| L8 | `/parse/*` 的 503 用 `Tool parser factory not initialized` 措辞 | 与 Rust 逐字一致，但它在这里的含义是「舰队里没有解析器」，运维读日志时别当成路由自身没初始化 |
| L9 | 未做 tokenizer 名字与 `model_id` 的强绑定 | `model` 只是候选排序信号；IGW 关闭时任何具名后端都可能被选中，与 router.lua `candidates_for()` 的现有语义一致 |
| L10 | 超时是模块常量（默认 15s，`_M.configure{proxy_timeout_ms=...}` 可改），不读 `SMG_REQUEST_TIMEOUT_SECS` | 分词请求本就该快；不读 env 是因为 `conf/*.conf` 里没有对应的 `env` 声明，加开关要动别人的文件（见 §6 D5） |
| L11 | 没有 SSE/流式，管理面也不写 metrics 计数器 | `observability.counter` 没接入这两个模块，`/metrics` 里看不到 tokenizer 代理的调用量 |

## 5. 与生产 Rust 实例的实测对照（`<dev-box>:8800`，只读采样）

| 请求 | Rust 8800 实测 | Lua 本模块 |
|---|---|---|
| `POST /v1/tokenize {"model":"qwen","prompt":"hi"}` | `400 {"error":{"message":"No tokenizers available. Use POST /v1/tokenizers to add one.","type":"tokenizer_not_found"}}` | `501` + `X-SMG-Error-Code: tokenizer_unavailable`，message 固定 `tokenizer backend unavailable` |
| `POST /v1/detokenize {"tokens":[1,2]}` | 同上 `400` | `501` |
| `GET /v1/tokenizers` | `200 {"tokenizers":[]}` | `200 {"tokenizers":[]}`（无 completed job 时） |
| `GET /v1/tokenizers/xyz` | `404 {"error":{"message":"Tokenizer 'xyz' not found","type":"tokenizer_not_found"}}` | 同状态同 message，但 body 是 `{"error":{"type","code","message"}}` |
| `GET /v1/tokenizers/xyz/status` | `404 ... "not found and no pending job"`，`type:"not_found"` | 同 message，`code:"not_found"` |
| `POST /parse/reasoning` 未知 parser | `400 {"error":"Unknown reasoning parser: nope","success":false}` | `400 {"error":"Unknown reasoning parser: nope (workers advertise: ...)","success":false}` |
| `POST /parse/function_call`（有内置 json 解析器） | `200`，进程内解析 | 需后端声明 `tool_parser`，否则 `503 Tool parser factory not initialized` |

Lua 的 `501` 而不是 Rust 的 `400`：按任务要求「没有可用 tokenizer 时返回 501 明确
`tokenizer backend unavailable`」。语义上也更诚实——Rust 那台是「本进程没加载词表」，
Lua 是「舰队里没有能分词的后端」，后者对客户端是可重试的部署问题而不是请求错误。

## 6. router.lua 接线建议（本 agent 未执行）

现状：`router.lua:1865-1873` 把 `v1/tokenize`、`v1/detokenize`、`v1/tokenizers`
（GET/POST）注册到 `not_implemented_handler`，`/parse/*` 与
`/v1/tokenizers/{id}`、`/v1/tokenizers/{id}/status` 根本没注册，落到 404 sink。
接线由 router.lua 的所有者完成，建议如下。

**D1 用 `exact_json` 包装，而不是直接登记函数。** 本模块自己写响应并返回 `''`，
与 `not_implemented_handler` 的约定相同。若希望统一走 `exact_json`，把
`_M.write_raw` 换掉即可（模块内只有一个写出点），但当前形态已经保证
`Content-Length` 精确、不被 nginx 改成分块。

**D2 建议的替换（`lualib/resty/luarouter/router.lua` 的 `build()` 内）**：

```lua
local tokenizer_mod = require "resty.luarouter.tokenizer"
local parse_mod = require "resty.luarouter.parse"

-- 替掉这两行 not_implemented_handler
app:post("v1/tokenize", tokenizer_mod.handle_tokenize)
app:post("v1/detokenize", tokenizer_mod.handle_detokenize)

-- 替掉这两行，并补上 Rust 有而本路由缺的三条管理路由
app:get("v1/tokenizers", tokenizer_mod.handle_list_tokenizers)
app:post("v1/tokenizers", tokenizer_mod.handle_add_tokenizer)
app:get("v1/tokenizers/:tokenizer_id", tokenizer_mod.handle_get_tokenizer)
app:delete("v1/tokenizers/:tokenizer_id", tokenizer_mod.handle_delete_tokenizer)
app:get("v1/tokenizers/:tokenizer_id/status", tokenizer_mod.handle_tokenizer_status)

-- Rust 的 admin_routes 里，本路由此前完全缺失
app:post("parse/function_call", parse_mod.handle_function_call)
app:post("parse/reasoning", parse_mod.handle_reasoning)
```

同名的 `app:head(...)` 注册按 router.lua 现有惯例补（axum 的 `get()` 顺带应答
HEAD）。klib.router 的分段匹配对 `/v1/tokenizers/{id}` 与
`/v1/tokenizers/{id}/status` 是两条不同长度的规则，不会互相遮蔽。

**D3 auth 已经就位，无需接线改动。** 两个模块都调 `_M.authorize("data"|"control")`，
它优先读注入的 `_M.auth_checks`，其次读 `package.loaded["resty.luarouter.router"]`
（`router.lua` 自己在 chunk 执行期 `require` 它，此时表尚未填好，所以不能靠
`require` 的返回值），最后才 lazy `require`。若 router.lua 想显式注入，`build()` 里：

```lua
tokenizer_mod.auth_checks = { data = check_data_auth, control = check_control_auth }
parse_mod.auth_checks = { data = check_data_auth, control = check_control_auth }
```

不注入也能工作（`package.loaded` 路径命中），但依赖加载顺序，正式接线时建议显式注入。

**D4 需要顺带更新的既有事实（属 router.lua / 测试所有者的改动，本 agent 未动）**：

- `test/test_lua_router.sh:865` 断言 `POST /v1/tokenize` → `501`。接线后无 worker
  的场景仍返 `501`，但该段的 `{"text":"x"}` body 会先撞 `prompt` 校验变 `400`，
  断言要改成 `400`，或补一个带 `prompt` 的用例；同时建议新增 501/503/409 三条
  契约断言。
- `test/conf/nginx-lua-router.conf` 的 `/klib/load` 模块清单应加
  `resty.luarouter.tokenizer`、`resty.luarouter.parse`。
- `doc/impl-core.md` §2.8 的「不实现 tokenizers」表述已过期。
- Rust 的 `/parse/*` 在 `admin_routes`，与 `/workers` 同一套 key；`/v1/tokenize`
  在 `protected_routes`。若 router.lua 决定两者统一用数据面 key，是有意偏离，需在
  `doc/parity-contract.md` 记一条。

**D5 需要新开关时才动 conf。** 两个模块的参数（`proxy_timeout_ms`、
`pending_grace_secs`、`stale_secs`）走 `_M.configure{}` 而不是 `os.getenv`，因为
`conf/nginx.conf.template` 与 `conf/lua-router.conf` 没有声明对应 `env`，nginx fork
后 `os.getenv` 读不到。若要让运维用环境变量控制，请由 conf 所有者加
`env LMR_TOKENIZER_PROXY_TIMEOUT_MS;` 之类声明，再在 init 钩子里调用
`configure()`。

**D6 观测指标。** 若要在 `/metrics` 看到这两个面，接线时给 handler 前后加
`observability.record_router_request("tokenizer", ...)`；模块内故意没引
observability，以免与 router.lua 形成加载环。

## 7. 验证

```bash
cd /path/to/lua-router

# 单测（316 passed, 0 failed；连跑 5 次稳定）
docker run --rm -v "$PWD":/repo:ro -w /repo \
  --entrypoint /usr/bin/resty apache/apisix:3.11.0-debian \
  -e 'package.path="./lualib/?.lua;"..package.path
      dofile("./test/unit/test_tokenizer_parse.lua")'

# 语法 gate（两个 conf 都含 include 链，确认新模块没被漏掉）
docker run --rm -v "$PWD":/repo:ro --entrypoint openresty authz:latest \
  -t -p /usr/local/openresty/nginx/ -c /repo/conf/lua-router.conf
```

另跑过一次真机 smoke（`authz:latest` + 一个真 mock worker，
`/data/tmp/lr-gap/{nginx-smoke.conf,mock_tok_worker.py}`，容器已销毁），实测：无
worker 时 `501`/`503`；带 `tokenizer=qwen2.5` label 的 worker 时 `/v1/tokenize`、
`/v1/detokenize`、`/parse/function_call`、`/parse/reasoning` 四条代理链路返回
worker 原始 JSON；`POST/GET/DELETE /v1/tokenizers` 的 202/409/404/202-again 与
`?all=1` 的 `pending → processing` 推进；设了 `SMG_API_KEY`/
`SMG_CONTROL_PLANE_API_KEY` 后数据面/控制面各自 401 与放行。既有的
`test/test_lua_router.sh` 全量与另外 4 套单测（hash 795、tree 67、policies 118、
integration 66）在本次改动后复跑结果见 §8。

## 8. 本次运行结果

| 项目 | 结果 |
|---|---|
| `test/unit/test_tokenizer_parse.lua` | **316 passed, 0 failed**（连跑 5 次稳定，随机档位不影响断言） |
| `test/test_lua_router.sh` 全量契约 | **All 322 lua-router contract checks passed (3 documented notes)**，本次改动未触碰 router.lua，`/v1/tokenize` 仍由 `not_implemented_handler` 应答 501 |
| 既有单测复跑 | hash 795 / tree 67 / policies 118 / integration 66，全 0 failed |
| conf 语法 gate | `conf/lua-router.conf` 与 `test/conf/nginx-lua-router.conf` 均 `test is successful` |
| 真机 smoke（authz:latest + 真 mock worker） | tokenize/detokenize/parse×2 代理透传、501/503/409/404/202、`?all=1` 状态推进、双 key 401/放行 全部符合预期；容器与临时 conf 已清理（留在 `/data/tmp/lr-gap/`） |

**接线状态**：截至本轮，`router.lua` 仍把 `/v1/tokenize`、`/v1/detokenize`、
`/v1/tokenizers` 指向 `not_implemented_handler`，`/parse/*` 未注册。router.lua 由
其他 agent 并行持有，本 agent 按所有权边界没有改动它，所以 §6 的 D2 属于**待接线**
状态：接线前这两个模块不会被路由触达，接线后 §6 D4 列的契约断言需要同步更新。
