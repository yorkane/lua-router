# gap-history：history / conversations / responses 持久化模块

实现文件：`lualib/resty/luarouter/history.lua`（本阶段只新增文件，`router.lua` 未改，
所以路由仍然对这些 endpoint 回 501，接线见最后一节）。

对齐的 Rust 参照（写作时逐一读过源码）：

| 参照 | 取用内容 |
| --- | --- |
| `data-connector-1.0.0/src/core.rs` | 对象模型、id 格式、`ListParams`、`make_item_id` 前缀表 |
| `data-connector-1.0.0/src/memory.rs` | memory 后端语义（link 索引、`(ts,id)` 排序、游标反向索引） |
| `data-connector-1.0.0/src/noop.rs` | `--history-backend none` 的确切行为 |
| `gateway/src/main.rs:482` | `--history-backend` 取值集合与默认值 |
| `gateway/src/routers/conversations/handlers.rs` | 校验规则、metadata patch、list envelope |
| `gateway/src/routers/persistence_utils.rs` | item ↔ JSON 渲染、`ITEM_TYPE_FIELDS` 抬平表 |
| `gateway/src/routers/openai/router.rs:1026` | response 的 `not_found` 措辞、`list_input_items` 补 id |

## 后端抽象

`SMG_HISTORY_BACKEND=memory|none|redis`（`postgres` / `oracle` 见下），默认 `memory`，与 Rust CLI 的
`value_parser = ["memory","none","oracle","postgres","redis"]` 同名同默认值。
未知取值折叠成 `memory`，对齐 `main.rs` 的 `_ => HistoryBackend::Memory`
（`_M.resolve_backend` 是这段解析的纯函数形式，单测直接测它）。

`postgres` / `oracle` **已知但不实现**：档位是 **TODO / Deferred**（用户指示 2026-09-30，
除非明确指定否则不实现，见 [todo-deferred.md](todo-deferred.md) §3，
不是「下一波补上」）。任何读写都返回

```
HTTP 501, code=history_backend_unsupported
message="history backend 'postgres' is not implemented in the Lua router; use memory or none"
```

不是落到 memory 假装成功。将来接真后端用 `_M.register_backend(name, impl)` 注册一张
与 `_M.memory_store` 同名函数的表即可，调用点不用改：注册表在 501 门控**之前**查，
所以 `register_backend("redis", ...)` 一装上去，`backend_supported()` 与 `stats()` 会
同时转为可用；从 registry 里摘掉名字则恢复 501。传入非 table 实现返回错误而不是崩。

**`redis` 已经不再是占位**：`history_redis.lua` 提供纯 Lua RESP2 实现，由 `init.lua` 的
`wire_history_redis()` 在 fork 前 `install()` 注册，实现与三场景验证见
[gap-history-redis.md](gap-history-redis.md)；
缺目标（`SMG_HISTORY_REDIS_URL` / `_HOST` 都没给）时回落 memory 并打 WARN，目标不可达时逐请求
503 `history_unavailable`。所以本文件其余段落里凡是把 redis 说成占位的措辞，都以这句为准。

env 只在配置被读取的那一刻有效，而本模块的 `_M.config()` 是懒解析：nginx 会重建 worker 环境，
`SMG_HISTORY_*` 若没在 conf 里用 `env` 声明，请求线程里 `os.getenv` 已经取不到了。所以接线时
应在 `init_by_lua`（fork 之前、还能看到真实环境的那一段）调一次

```lua
require("resty.luarouter.history").configure({
    backend = os.getenv("SMG_HISTORY_BACKEND"),
    max_conversations = tonumber(os.getenv("SMG_HISTORY_MAX_CONVERSATIONS")),
})
```

`configure` 会把 backend 名再过一遍 `resolve_backend`，所以传 `nil` 或非法值都会安全落到
`memory`。不调用它则退化成首次请求时读环境，此时需要 conf 里显式 `env SMG_HISTORY_BACKEND;`。

`_M.config()` 一次性解析的完整旋钮：

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `SMG_HISTORY_BACKEND` | `memory` | 后端选择 |
| `SMG_HISTORY_MAX_CONVERSATIONS` | 10000 | conversation 条数上限，超出按 LRU 淘汰 |
| `SMG_HISTORY_MAX_ITEMS_PER_CONVERSATION` | 1000 | 单会话条目上限，超出淘汰最旧 |
| `SMG_HISTORY_MAX_RESPONSES` | 10000 | response 条数上限，超出淘汰最旧 |
| `SMG_HISTORY_MAX_ITEMS_PER_REQUEST` | 100 | 单次 `create_items` 条数上限（见「与 Rust 差异」3） |
| `SMG_HISTORY_TTL_SECS` | 0 | 写入 dict 的 TTL，0 表示不过期 |

## nginx conf 需要声明的 shared dict

模块不会自己声明，缺声明时所有读写返回 503 `history_unavailable`（message 点名所需
dict），而不是崩在 nil 上。需要加两行（`lr_locks` 本仓库已有）：

```nginx
lua_shared_dict lr_history  10m;   # 新增：history 记录 + 索引
lua_shared_dict lr_locks      1m;   # 已存在：resty.lock 的宿主
```

`10m` 是按 `max_conversations=10000 × max_items=1000` 的保守下限给的：一条记录 JSON
约 200–400B，索引是每条目 ~70B 的紧凑文本。真实容量到顶时 `lr_history` 会先触发
nginx 的 LRU 驱逐，届时应把 `SMG_HISTORY_MAX_*` 调小或把 dict 调大，二者必须一致，
否则 dict 的静默驱逐会让 `n:conv` 计数与实际条数漂移（模块自己按计数淘汰，不感知
nginx 的驱逐）。

## 对象模型

```
conversation { id, object="conversation", created_at, metadata }
item         { id, type, role?, content, status?, response_id?, created_at? }
response     { id, object, created_at, status, model?, usage?, output, input_items, ... }
```

`created_at` 一律是整数 unix 秒（Rust 侧 `.timestamp()` 也是整数）。metadata 为空对象时
整体省略该字段，对齐 `conversation_to_json`。

key 布局（`_M.KEYS` 暴露，便于运维与单测直接检视）：

| 前缀 | 内容 |
| --- | --- |
| `cv:<conv_id>` | conversation 记录（JSON） |
| `it:<item_id>` | item 记录（JSON），全局一份，可被多会话引用 |
| `lx:<conv_id>` | 该会话的有序条目索引（`score\2item_id` 以 `\1` 连接的紧凑文本） |
| `rv:<conv_id>|<item_id>` | item_id → score，`after` 游标的 O(1) 查表 |
| `rs:<resp_id>` | response 记录（JSON，含上游原始字节） |
| `sq:<conv_id>` / `seq` | LRU 时钟（每次访问 `incr`） |
| `n:conv` / `n:resp` | 计数，供容量淘汰与 `stats()` |

单会话列表只走 `lx:` 索引，不扫全 dict，所以 `list_items` 与该会话条目数成正比、
与 dict 总量无关。

## 接口清单

错误统一是 `nil, {status, code, message, param}`，正是 `router.lua` 的 `send_error`
吃的形状；成功是 `value, nil`。本模块不碰 `ngx.req` / `ngx.say`，所以可脱离 nginx 单测。

| 函数 | 对应 endpoint | 关键语义 |
| --- | --- | --- |
| `create_conversation(metadata, opts?)` | `POST /v1/conversations` | `opts.id` 可带客户端 id；metadata ≤16 键 |
| `get_conversation(id)` | `GET /v1/conversations/{id}` | 不存在 404 `Conversation not found` |
| `update_conversation(id, body)` | `POST /v1/conversations/{id}` | metadata patch，`null` 删键，合并后 ≤16 键 |
| `delete_conversation(id)` | `DELETE /v1/conversations/{id}` | 返回 `conversation.deleted`；连带清索引 |
| `list_items(id, {limit,order,after})` | `GET .../items` | `limit` 默认 100、上限 1000；`order` 非 `asc` 皆按 desc |
| `create_items(id, items)` | `POST .../items` | 单请求上限；返回 list envelope + `warnings` |
| `get_item(id, item_id)` | `GET .../items/{item_id}` | 未 link → 404 `Item not found in this conversation` |
| `delete_item(id, item_id)` | `DELETE .../items/{item_id}` | 只解链；返回 **conversation 对象**（对齐 Rust） |
| `create_response(payload)` | `POST /v1/responses` 之后回写 | payload 可为上游原始 JSON 字节 |
| `get_response(id)` | `GET /v1/responses/{id}` | 有原始字节时逐字节回显 |
| `cancel_response(id)` | `POST /v1/responses/{id}/cancel` | `completed` → 400；重复 cancel 幂等 |
| `delete_response(id)` | `DELETE /v1/responses/{id}` | 返回 `response.deleted`；重复 → 404 |
| `list_input_items(id)` | `GET /v1/responses/{id}/input_items` | 缺 id 的 item 补 `msg_` id；`has_more` 恒 false |
| `get_response_chain(id, max_depth?)` | 内部（`previous_response_id`） | 最旧优先；检环 |
| `stats()` / `sweep()` / `flush_all()` | `/_ui` 与定时器 | 计数、手动淘汰、清空 |
| `configure(overrides)` / `resolve_backend(v)` | `init_by_lua` | 注入配置、解析后端名 |

## 实现要点

- **ID**：`conv_<50 hex>`、`<type 前缀>_<50 hex>`（前缀表 `msg/rs/mcp/mcpl/fc`，未知取前三
  字母）、26 字符 ULID。ULID 按标准布局编码：前 10 字符是 48 位毫秒（左侧补零到 50 位），
  后 16 字符是 80 位随机，所以标准解析器能读回时间戳；同毫秒内靠随机位区分，不保证单调。
  随机源优先 `resty.openssl.rand`，缺失时退 `math.random`（首次调用播种一次），再退时间+pid，
  保证取随机数失败不会打断请求。
- **时间戳**：`_M.now()` 走 `ngx.now()`，非 nginx 环境退 `os.time()`。
- **原子写**：`with_lock` 用 `resty.lock`（`lr_locks`，timeout 5s / exptime 10s）。可重入标记
  放在 `ngx.ctx`，因此是**每请求**的。锁不可用时退化为顺序写而不报错，保证单测可跑。
- **容量淘汰**：conversation 用 LRU（`sq:` 访问时钟，create 时超阈值才扫一次，一次淘汰到约
  90% 做迟滞）；单会话 items 与 responses 用 oldest。淘汰策略明确记录在代码注释与本节。
- **JSON**：`_M.encode` 自己递归，空表按 `array()` 标记决定 `[]` 还是 `{}`，键排序输出所以
  字节稳定；不可编码值降级为 `null` 而不是抛错。**不改 cjson 的全局 array 设置**，避免影响
  `router.lua` 自己的空对象输出。

## 与 Rust 的差异

1. **重启即丢**（memory 后端）。memory 后端没有落盘，`nginx -s reload` 因为 dict 保留而数据仍在，但
   `docker restart` / 换容器会清空。Rust 的 memory 后端同样不持久，差别在于 Rust 还有
   redis/postgres/oracle 可换；这里 redis 已实现（见「后端抽象」一节与 gap-history-redis.md），
   postgres / oracle 是 **TODO / Deferred**（用户指示 2026-09-30，除非明确指定否则不实现，见
   [todo-deferred.md](todo-deferred.md) §3），
   要跨实例共享会话就用 redis。
2. **容量有上限且会淘汰**。Rust memory 后端是无界 `HashMap`；这里受 `lua_shared_dict` 大小
   与 `SMG_HISTORY_MAX_*` 双重约束，超额静默淘汰最旧/最久未用。长会话必须自己翻页。
3. **单请求 items 上限 100，Rust 是 20**。`handlers.rs` 硬编码 20。这里默认放宽到 100 并
   做成 env 开关：要严格对齐就 `SMG_HISTORY_MAX_ITEMS_PER_REQUEST=20`。
4. **排序键是入库序号，不是秒**（代码标了 DEVIATION）。`memory.rs` 按
   `(added_at.timestamp(), item_id)` 排，所以同一秒内写入的条目返回顺序是随机的。这里用单调
   序号，保证文档承诺的创建顺序与 `after` 游标稳定；`created_at` 字段仍是秒。
5. **`has_more` 沿用 Rust 的宽松口径**：页被填满就报 `true`，所以最后一页可能 `has_more=true`
   而下一页为空。照抄是为了不改客户端翻页逻辑。
6. **`delete_conversation` 连带删掉该会话独占的 item 记录**（代码标了 DEVIATION）。Rust 只删
   link、item 记录留在全局表里；这里不删就会在 dict 里堆不可达记录，与有界存储的初衷冲突。
   代价：被第二个会话引用的 item 会一并消失（本模块不做引用计数）。
7. **`cancel_response` 不代理上游**。Rust 的 http router 把 cancel 转给上游，openai router
   走 trait 默认值直接 501。本模块没有上游句柄，只改本地记录状态，所以
   `queued/in_progress → cancelled`，`completed → 400 response_not_cancellable`。接线时若需要
   真取消，应由 `router.lua` 先转发上游再回写状态。
8. **id 字符集受校验**。`_M.parse_id` 只接受 `[%w_%-%.%:]+` 且 ≤128 字节（索引把 id 存在分隔
   文本里，控制字符会破坏它）；Rust 不校验，任意字符串都能进。
9. **`usage` 只透传不重算**，且 `previous_response_id` 链多了环检测（Rust 靠 `max_depth=100`
   截断，这里遇到环直接 400 `response_chain_cycle`）。
10. **metadata 的 JSON null 依赖 cjson**。`cjson.safe` 把 `null` 解成 `cjson.null`
    （userdata），`apply_metadata_patch` 同时认这个常量和 Lua 的 `nil`。

## router.lua 接线建议

`router.lua` 现在有 5 个 endpoint 挂的是 `not_implemented_handler`（1867-1871 行附近）。接成：

| endpoint | 函数 | 取参 |
| --- | --- | --- |
| `POST v1/conversations` | `create_conversation(body.metadata, {id=body.id})` | body |
| `GET v1/conversations/:conversation_id` | `get_conversation(params.conversation_id)` | path |
| `POST v1/conversations/:conversation_id` | `update_conversation(cid, body)` | path+body |
| `DELETE v1/conversations/:conversation_id` | `delete_conversation(cid)` | path |
| `GET v1/conversations/:conversation_id/items` | `list_items(cid, {limit=params.limit, order=params.order, after=params.after})` | path+query |
| `POST v1/conversations/:conversation_id/items` | `create_items(cid, body.items)` | path+body |
| `GET v1/conversations/:conversation_id/items/:item_id` | `get_item(cid, item_id)` | path |
| `DELETE v1/conversations/:conversation_id/items/:item_id` | `delete_item(cid, item_id)` | path |
| `GET v1/responses/:response_id` | `get_response(response_id)` | path |
| `POST v1/responses/:response_id/cancel` | `cancel_response(response_id)` | path |
| `DELETE v1/responses/:response_id` | `delete_response(response_id)` | path |
| `GET v1/responses/:response_id/input_items` | `list_input_items(response_id)` | path |

统一样板（每个 handler 三行）：

```lua
local value, err = history.get_conversation(params.conversation_id)
if err then return send_error(err.status, err.code, err.message) end
return set_content_length(json_encode_or_pass(value))
```

注意四点：

- `get_response` 可能返回**字符串**（上游原始字节），要走 `Content-Type: application/json`
  直接发，不要再 encode 一遍。
- 404 的 `code` 目前统一是 `not_found`。Rust 的 conversations handler 回的是纯文本
  `{"error":"Conversation not found"}`，openai response handler 回
  `{"error":{...,"code":"not_found"}}`。要严格对齐 conversations 的 body 形状，接线时在
  `router.lua` 侧按 endpoint 分派，而不是改这个模块的错误表。
- `create_response` 应在 `router.lua` 拿到上游响应体之后调用，把**原始字节**传进来，这样
  后续 GET 能逐字节回显；同时它会自动把 input/output item 挂进 `body.conversation`（会话不
  存在时只挂 response、不报错，对齐 Rust 的 warn 分支）。
- `stats()` 可以并进 `/_ui`，`sweep()` 适合挂进 `init.lua` 已有的 worker-0 定时器（和 policy
  淘汰同一个 timer）。

## 验证

```bash
# 纯 luajit，不需要 nginx（用内存表替身）
docker run --rm -v "$PWD:/repo:ro" -w /repo authz:latest \
  /usr/local/openresty/luajit/bin/luajit /repo/test/unit/test_history.lua
# 731 passed, 0 failed

# 同一份用例在 apisix 镜像的 resty 里跑（有真实 ngx.* 全局）
docker run --rm -v "$PWD/lua-router:/r:ro" -w /r --entrypoint /usr/bin/resty \
  apache/apisix:3.11.0-debian -e 'package.path="/r/lualib/?.lua;"..package.path
    dofile("/r/test/unit/test_history.lua")'
# 731 passed, 0 failed
```

真实 `ngx.shared.DICT` + 真实 `resty.lock` 的一次性验证（临时 conf 在 `/data/tmp/gaphist/`，
未落进仓库）：12/12 功能断言通过，包括原始字节存取、游标翻页、stats 与 flush。并发面用
同一套代码、只差一把锁对照测量（每组都先在单请求里预建 conversation，排除脚手架自身竞态）：

| 场景 | 结果 |
| --- | --- |
| 不加锁，2 worker × 10 并发 × 40 次 link | 期望 +400，索引实际 +231，**丢 169 条（42%）**；item 记录本身 440 条一条不丢 |
| 加锁，同样的 2 worker × 10 并发 × 40 | 索引 +400，**零丢失**，list 与索引长度始终相等 |
| 2 worker × 8 并发，在临界区内计并发度 | peak=1，overlaps=0，fails=0 |
| 顺序单线程 10 × 40 | +400，与加锁并发结果一致 |

丢的是索引而不是记录，这正说明问题所在：`store_item` 是单键 `set`，天然安全；`link_item`
是 `get` 索引 → 追加 → 排序 → `set` 的读改写，多个 worker 各自基于旧快照回写，后写的把先写
的覆盖掉。所以这把锁是承重的，不是装饰。

修锁过程中先踩了两个坑，都有上面的数字支撑：`with_lock` 的可重入标记原本是**进程内全局变量**，
于是同 worker 的第二个请求以为自己已持锁而跳过加锁；`resty.lock` 的构造又写成了
`lock_mod.new(...)`（漏了 self），`lr_locks` 查不到而报 `dictionary not found`，锁被静默跳过。
标记改放 `ngx.ctx`（每请求）、构造改成 `lock_mod:new(...)`（与 `registry.lua` 一致）后才是上表
的 peak=1。

接线后的多请求 HTTP 契约应进 `test_lua_router.sh`，本阶段的并发证据只到上面这些探针为止。
