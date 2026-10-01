# gap-history-redis：history 模块的 Redis 后端

实现文件：`lualib/resty/luarouter/history_redis.lua`（新增）；
`lualib/resty/luarouter/history.lua` 只做两处挂点：
`stats/sweep/flush_all` 在配置到已注册后端时转发给后端实现，以及把
store 函数返回的第二值（错误表）向上传播（memory store 从不返回第二值，
所以既有行为逐字不变）。router.lua / conf / init.lua 均未改。

## 协议与连接

纯 Lua 手写 RESP2（无 lua-resty-redis 依赖，与 hash.lua 的 stdlib-only 选择一致）：

- 命令编码 `*N\r\n$len\r\n<arg>\r\n…`，长度按字节算，参数含 `\r\n`/NUL 都安全。
- 解码覆盖 `+ - : $ *`（以及 RESP3 的 `>` push 头，按数组读）；截断、坏长度、
  未知 tag 一律报错误而不是崩。
- 连接走 `ngx.socket.tcp`，`settimeouts(timeout_ms)`，成功后 `setkeepalive` 入池
  （每 worker keepalive_pool 个、空闲 keepalive_ms）；AUTH 和 SELECT 在 acquire
  握手期完成，池中连接永远已鉴权。批量命令一次 `send` 管道化、顺序读回，
  一个往返完成多键操作（如 drop_conversation 的 DEL 批）。
- 传输层断掉（send 失败/应答读断）时换新连接重试一次；本后端所有写
  （SET、ZADD NX、ZREM、DEL）重放幂等，INCR 只驱动排序时钟。
- 错误映射：连接失败、超时、服务器错误回复（WRONGPASS/WRONGTYPE/…）、
  协议错位统一 `503 history_unavailable`，message 带 `redis:` 前缀和服务器原文。
  501 `history_backend_unsupported` 仍由 history.lua 的门控产生：注册前 redis
  名字照样 501，注册即翻转，摘掉又回到 501。

## 数据结构

前缀 `SMG_HISTORY_REDIS_PREFIX`（默认 `lrhist:`）；公共 Redis 上多实例共享时按前缀隔离。

| 键 | 类型 | 内容 |
| --- | --- | --- |
| `<p>cv:<id>` | string | conversation 记录 JSON |
| `<p>it:<id>` | string | item 记录 JSON（与 memory 的 `it:` 同形状，含 raw_json） |
| `<p>lx:<conv>` | zset | 会话条目索引，member=item_id，score=全局 seq |
| `<p>rs:<id>` | string | response 记录 JSON（raw_json 字段保字节回放） |
| `<p>zconv` | zset | conversation 的 LRU 时钟（score=最近访问 seq），替代 memory 的 get_keys 扫描 |
| `<p>zresp` | zset | response 的 created_at 时钟，供 max_responses 淘汰 |
| `<p>seq` | string | 全局 INCR 计数器，驱动索引 score 与 LRU |

- memory 的反向索引 `rv:` 在这里是免费的：ZSCORE 直接给出游标，after 分页、
  is_item_linked、unlink 都是一条命令。
- 索引 score 输出为 `history.score()` 同串的零填充形式（`%012d ` + item_id），
  `list_items` 的游标等值比较不区分后端。
- `SMG_HISTORY_REDIS_TTL_SECS>0` 时对记录键写 `EX`、对 zset 补 `EXPIRE`
  （Lua 5.1 无负数取模问题，代码里没有该写法）；时钟 zset 与 seq 永不过期，
  记录过期后 zset 里的幽灵 member 由读路径的 nil 跳过兜底（list_items 本来就跳过
  取不到的 item）。

## 与 memory 后端的语义差异（都是有意为之）

1. 上限淘汰走 zset 有序集（ZRANGE 头部即最旧），不再有 memory 的 get_keys 全扫。
2. 计数（stats 的 conversations/responses）是 ZCARD 实时值，不是 memory 的增量计数器，
   不会漂移。
3. `delete_response` 与 memory 一样返回存在性布尔驱动公共层 404（history.lua 里
   `backend() == "memory"` 的判断放宽成 `~= "none"`，noop 的无条件成功不变）。
4. 幂等 link：已存在的 member 用 ZADD NX 保留原位置，与 memory 的
   "already linked" 分支一致；同一 conversation 并发 create_items 由公共层的
   history.with_lock（resty.lock + lr_locks）串行化。
5. 锁的选择不重复造轮子：写路径沿用 history.with_lock，模块不再自加 SET NX 锁；
   `try_lock/release_lock`（SET NX PX + EVAL compare-and-delete）作为独立小工具提供，
   单测覆盖，供未来多 router 实例共享一套 Redis 时按 key 前缀细粒度锁用。取舍
   记录在模块头注释：单实例下 with_lock 已覆盖，Redis 锁只会给热路径加往返。
6. 与 memory 相同的已知偏差保留：conversation 删除时连带删掉链接的 item 记录
   （共享 item 会被第二个会话看不到）；这是 memory.rs 就有的行为。

## 配置

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `SMG_HISTORY_BACKEND` | `memory` | 设为 `redis` 启用本后端 |
| `SMG_HISTORY_REDIS_URL` | 无 | `redis://[:pw@]host[:port][/db]`，逐分量覆盖下面的单项变量 |
| `SMG_HISTORY_REDIS_HOST` / `_PORT` | `127.0.0.1` / `6379` | |
| `SMG_HISTORY_REDIS_PASSWORD` | 无 | 非空则握手期 AUTH |
| `SMG_HISTORY_REDIS_DB` | `0` | db>0 则握手期 SELECT |
| `SMG_HISTORY_REDIS_PREFIX` | `lrhist:` | 所有键的前缀 |
| `SMG_HISTORY_REDIS_TIMEOUT_MS` | `2500` | connect/send/receive 三向超时 |
| `SMG_HISTORY_REDIS_TTL_SECS` | `0` | 本后端记录 TTL；与 memory 的 `SMG_HISTORY_TTL_SECS` 分开，避免一个 env 驱动两种时钟 |
| `SMG_HISTORY_REDIS_KEEPALIVE_MS` / `_POOL` | `30000` / `8` | 池参数（每 worker） |

## 接线步骤（init 侧）

> 本节是当初设计的接线草图，已在 2026-09-30 执行，实际实现见文末「接线状态」。
> 差异只有一处：不在 init 里逐字段 `configure`，改成在 init 里预热 `config()`（理由见那里）。

本后端已实现，接线只需两处，
都在 `init.lua` 的 `init_by_lua`（SMG_HISTORY_* 解析处旁）：

```lua
local ok_hr, history_redis = pcall(require, "resty.luarouter.history_redis")
if ok_hr then
    history_redis.configure({
        host = os.getenv("SMG_HISTORY_REDIS_HOST"),
        port = tonumber(os.getenv("SMG_HISTORY_REDIS_PORT")),
        password = os.getenv("SMG_HISTORY_REDIS_PASSWORD"),
        db = tonumber(os.getenv("SMG_HISTORY_REDIS_DB")),
        prefix = os.getenv("SMG_HISTORY_REDIS_PREFIX"),
        ttl_secs = tonumber(os.getenv("SMG_HISTORY_REDIS_TTL_SECS")),
        timeout_ms = tonumber(os.getenv("SMG_HISTORY_REDIS_TIMEOUT_MS")),
    })
    -- URL 形态优先，configure 之后再 parse 一次覆盖：
    local url = os.getenv("SMG_HISTORY_REDIS_URL")
    if url and url ~= "" then
        history_redis.parse_url(url, history_redis.config())
    end
    history_redis.install()   -- = history.register_backend("redis", ...)
end
```

要点：
- `install()` 之后 `SMG_HISTORY_BACKEND=redis` 才不再是 501；注册表在门控之前查，
  router.lua 调用点零改动。
- configure 必须在 `init_by_lua`（fork 前）做，理由与 history.configure 相同：
  worker 里 os.getenv 已被 nginx 重建。URL 用 parse_url 逐分量覆盖，兼容
  "裸 map / 带 scheme / 缺端口缺 db" 各形态。
- 容量上限（max_conversations 等）继续由 history.configure 提供，两个后端共享
  同一套旋钮；本模块只读不复制。
- 冒烟钩子：`/_ui` 若要显示 redis 健康，直接调 `history_redis.ping()`。

## 测试证据

`test/unit/test_history_redis.lua`，12 个 case：RESP 编解码逐字节断言、
全部回复类型与畸形输入、URL 解析（含 rediss/user:pw、缺分量保留原值）、
注册翻转 501、conversation CRUD（含 metadata null 删键）、items 分页
after/order/上限淘汰/幂等 link/score 串同形、response raw 字节回放与
cancel/delete/chain/input_items、stats/sweep/flush_all 挂点、AUTH 失败与
服务器 ERR 与断连三种 503、SET NX 锁所有权、真实 Redis 冒烟。

fake server 注入在 transport 层（模块唯一连接抽象），send/receive 之间跑的仍是
真实 RESP 字节，因为 authz 镜像的 luajit 没有 lua-socket，真 loopback 监听要线程。

跑法与结果（2026-09-30）：

```bash
# 纯逻辑 + fake（luajit，无网络）：99 passed, 0 failed, 1 skipped
docker run --rm -v "$PWD:/repo:ro" -w /repo \
  --entrypoint /usr/local/openresty/luajit/bin/luajit authz:latest \
  test/unit/test_history_redis.lua

# 真实公共 Redis 冒烟（cosocket 只在 resty 有；authz 的 resty 缺 perl）：
# 101 passed, 0 failed, 0 skipped
docker run --rm --network host -v "$PWD:/repo:ro" -w /repo \
  --entrypoint /usr/local/openresty/bin/resty apache/apisix:3.11.0-debian \
  test/unit/test_history_redis.lua
```

冒烟目标 <shared-redis:6379>（密码 env 注入），全部键带 `lua_router_test:` 前缀，
结束时 `flush_all` + `KEYS lua_router_test:*` 断言为 0 条，验证已清理。网络不可达
时该段 SKIP 并打印原因，不算失败。

回归：`test_history.lua` 731 passed, 0 failed（memory 后端行为不受挂点改动影响）。

## 接线状态（2026-09-30 已执行）

`init.lua` 的 `init_by_lua` 里新增 `wire_history_redis()`，紧跟
`history.configure` 之后、fork 之前调用；worker 侧新增 `start_history_redis_probe()`，
挂在 `start_history_sweep()` 旁。router.lua / conf / registry 未改。

判定链（`history.backend() == "redis"` 才进入）：

1. `SMG_HISTORY_REDIS_URL` 与 `SMG_HISTORY_REDIS_HOST` 都没设 → WARN
   `SMG_HISTORY_BACKEND=redis but neither ... is set; history falls back to the
   memory backend`，`history.configure{backend="memory"}`，正常启动。
2. 模块 require 失败、`config()` 抛错、`install()` 失败 → 同样 WARN + 回落 memory。
3. 目标配置齐全 → `history_redis.config()` 预热 env 快照（含 URL 逐分量覆盖，
   口令不写日志），`install()` 注册，NOTICE 打印
   `history backend redis wired to host:port db N prefix P`。此后 redis 不再 501。

上面草图里的逐字段 `configure{host=..., port=...}` 再补一次 `parse_url` 也能
工作（`configure` 内部先调 `config()`，缓存同样在 fork 前建好）。直接预热
`config()` 只是少一层重复：URL 的逐分量覆盖 `config()` 已经做了，init 也不用
再维护一份字段白名单（`_KEEPALIVE_MS` / `_KEEPALIVE_POOL` 这类草图没列出的
名字照样生效）。容量上限继续由 `history.configure` 单点提供，两个后端共享
同一套旋钮。

**缺 host/url 时选择回落 memory，不是拒绝启动也不是 503**，理由记在这里：
Rust 侧 `RedisConfig::validate`（data-connector `config.rs`）对空 url 直接
`ConfigError::ValidationFailed`，`main.rs` 在 bind 之前就退出——即“拒绝启动”。
Lua router 不在 init 阶段 `error()`：那会让整个数据面（推理路由）为一个可选的会话
存储配置错误而起不来，而且 router 本身不依赖 history。选它已有的语义先例是
`main.rs` 的 `_ => Memory`（未知后端名回落 memory），`history.lua` 的
`resolve_backend` 已经照抄。配置齐但 Redis 连不上是另一回事：照常注册，
每个请求 503 `history_unavailable`（message 带 `redis:` 前缀），推理面不受影响。

**健康探针**：`init_by_lua` 没有 cosocket，PING 只能在 worker 阶段发，所以
`worker_init` 用 `ngx.timer.at(0, ping)` 做一次性探针，失败只写 WARN
`luarouter: history redis ping failed: ...`，不改变启动结果。
`_M.history_redis_ping()` 暴露给未来的 /_ui 只读端点（当前未挂路由：
conf 属于其他 agent 的所有权，且 `/_ui/history` 的 `stats()` 已经会报
`backend: "redis"`）。sweep / flush / stats 三个挂点走 `history.lua`
已有的 `BACKENDS[]` 转发，`start_history_sweep()` 原样复用，无需新代码。

## 测试证据（接线）

`test/integration/e2e_history_redis.py`（新增，独立运行，不进 final_gates）：
用 `_lib.py` 的容器 helper 起真 router，另用一个最小 RESP2 客户端从 Redis 侧
核对键，共 44 项断言，三段场景：

| 场景 | env | 断言要点 |
| --- | --- | --- |
| A redis 生效 | `SMG_HISTORY_BACKEND=redis` + `SMG_HISTORY_REDIS_URL`（第二个实例改用 `_HOST/_PORT/_PASSWORD`） | 会话 CRUD、items 分页（asc/limit/after 不重复）、response 字节回放 + input_items、`/_ui/history` 报 redis 且计数来自 ZCARD、`max_conversations=2` 只留最新两个、**两个 router 实例共享同一份会话**（memory 做不到的那件事）、drop 回收 `cv:/lx:/it:`、worker 的 sweep 定时器对 redis 跑满全程无 backend 报错 |
| B 缺目标 | 只给 `SMG_HISTORY_BACKEND=redis` | 正常启动、WARN 命中、`/_ui/history` 报 memory、CRUD 正常、Redis 里没有任何记录键（`seq` 时钟按名字排除） |
| C 目标不可达 | `_HOST=127.0.0.1` + 已释放端口 | 正常启动、探针 WARN、读写 503 `history_unavailable`（message 含 `redis:`）、推理仍 200、`/_ui/history` 仍 200 且报 redis |

Redis 不可达（连不上或 AUTH 被拒）时整段打印 SKIP 并 exit 0。收尾 `SCAN` 断言
`lua_router_test:` 前缀为 0 条；场景 B 用名字过滤掉 A 留下的 `seq` 排序时钟
（永不过期），只要求没有任何记录键。

跑法与结果（2026-09-30）：

```bash
# 真公共 Redis：44 passed, 0 failed
python3 test/integration/e2e_history_redis.py
# 网络不可达：SKIP 并 exit 0
LUA_TEST_REDIS_HOST=127.0.0.1 LUA_TEST_REDIS_PORT=6399 \
  python3 test/integration/e2e_history_redis.py

# 回归
openresty -t                     # test/conf + conf/lua-router.conf 两份都 successful
test_history.lua                 # 731 passed, 0 failed（挂点未影响 memory）
test_history_redis.lua luajit    # 101 passed, 0 failed, 1 skipped（真实段无 cosocket）
test_history_redis.lua resty     # 110 passed, 0 failed, 0 skipped（公共 Redis 可达）
TEST_ONLY=history_crud           # 86 contract checks passed
```

## 尚未处理的两处相邻文档

- `doc/gap-history.md` 原先写「`redis` / `postgres` / `oracle` 是**已知但未实现**：任何读写都返回 501」，
  现在这句话已就地更正为分档：**redis 已实现**（本文），`postgres` / `oracle` 是
  **TODO / Deferred**（用户指示 2026-09-30，除非明确指定否则不实现，见
  [todo-deferred.md](todo-deferred.md) §3）。
  也就是说这两个后端不会在下一波补上，引用时不要写成「在接」。
- `/_ui/history` 之外没有新增 redis 健康端点（conf 与 router.lua 属其他 agent）。
  要挂的话调用 `require("resty.luarouter").history_redis_ping()` 即可，
  它只在后端为 redis 时发 PING。

## 接入 final_gates 的方式（已落地，2026-09-30）

本套 e2e 刻意不进 `test_lua_router.sh`（那份契约跑真实容器，加一段 redis 依赖会把
无网络的机器变成 FAIL）。`test/final_gates.sh` 里的门禁形态是：

```bash
GATE_ORDER=(... e2e_grpc e2e_history_redis e2e_otel ...)   # 18 门
gate_e2e_history_redis() { LR_REDIS_REQUIRED=1 run_integration e2e_history_redis.py 900; }
```

`e2e_history_redis` 也在 preflight 的 `$E2E_IMAGE` 检查列表里。**关键取舍**：门禁内带
`LR_REDIS_REQUIRED=1`（脚本也认 `--require-redis`），Redis 不可达就 FAIL + exit 1；不带该
变量的手动跑仍是 SKIP + exit 0。若按原样让门禁里也 SKIP，绿跑会把「没测到」记成 PASS，
所以宁可让门禁与公共 Redis `<shared-redis:6379>` 的可达性耦合，换掉这个假绿。
没有 Redis 的机器要跑门禁就显式 `SKIP_ENV=e2e_history_redis`（日志记 skipped）。
