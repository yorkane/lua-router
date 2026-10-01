# 补齐两项：DP rank 请求体注入 + 控制面 JWT/JWKS

对应任务：`doc/gap-discovery-dp.md` §1.5 的注入缺口，以及控制面认证里 Rust smg-auth 有、
Lua 侧一直没有的 JWT 分支。两条线共用一次提交，因为它们都只碰 `router.lua`。

## 1. DP rank 注入（`data_parallel_rank`）

### 1.1 接线位置

`router.lua` 的 `forward()` 里，紧跟 model 改写：

```lua
local payload = rewrite_model(raw_body, worker.model_id)
if cfg().dp_aware and discovery() then
    payload = (discovery().inject_dp_rank(payload, worker))
end
```

写入顺序与 Rust 无关（Rust 在 model 序列化之后 insert，Lua 也是在 model 之后），重要的是
两步都走**原位字节改写**而不是 decode/encode：客户端的空白、键序、数字精度都得原样带过去。

`discovery()` 是本文件新增的惰性 require 访问器，形状照抄 `registry.lua` 的 `sd()`：
`pcall(require, ...)` + 进程表缓存，加载失败记 false 而不是每请求再试一次。这样
init_by_lua 语法门不受影响，`service_discovery.lua` 万一坏掉也只是不注入，转发路径照常。

### 1.2 语义

- 两道条件都要满足才注入：`SMG_DP_AWARE` 打开，**且** worker 记录带 `dp_rank`。Rust 那边
  注入的开关就是 `self.dp_aware`（router.rs:579），只看记录字段会更宽 —— 手工
  `POST /workers` 塞一个 `dp_rank` 进来，在不认 DP 的部署上也会开始改请求体。对齐之后
  这类记录只在 `SMG_DP_AWARE=1` 时生效，与 Rust 的 `extract_dp_rank(worker_url)` 同侧。
- 非 DP 部署（开关关，或记录无 rank）请求体**逐字节不变**。
- 顶层成员已存在则原位覆盖（客户端自己塞的 `data_parallel_rank` 会被 router 的选择替换掉，
  不会留下两个同名键）；不存在则插在最前面。嵌套对象里的同名键、字符串里的花括号都不受影响
  —— 这套规则是 `inject_dp_rank` 原有的单测覆盖范围，本次只是把它接上。
- 注入的是整数（`"data_parallel_rank":2`），不是字符串。

### 1.3 验证

`e2e_discovery_dp.py` 里原来的 `[dp4] body injection still absent` 翻成正向，并补了三条：

| 断言 | 做法 |
|---|---|
| 每个 rank 收到自己的编号 | round_robin 连发 8 次，收集 echo_body 的值，断言集合 == {0,1,2,3} |
| 注入是整数 | `isinstance(v, int)` |
| model 改写与注入共存 | 同一个 echo_body 里两个字段都对 |
| 客户端预置值被覆盖而非重复 | 请求带 `data_parallel_rank:99`，回来的值 ∈0..3 |
| 非 DP 不注入 | dp_size=1 组的 echo_body 里不含该字段 |

集合断言而不是逐次序列断言，是因为候选顺序来自 registry 的字典遍历，不保证等于 rank 顺序；
不变的是「每个 rank 的请求带自己的号」。DP mock 只有一个监听口，四个 rank 共用，rank 只能
从 router 注入了什么看出来 —— 这也正是这个字段存在的意义。

## 2. 控制面 JWT/JWKS

新文件 `lualib/resty/luarouter/jwks.lua`（705 行），`router.lua` 里 `check_control_auth()`
前置一个 JWT 闸门。

### 2.1 环境变量（三处 conf 各加 7 行 `env`）

| 变量 | 默认 | 作用 |
|---|---|---|
| `SMG_JWT_ISSUER` | 无 | 配了就校验 `iss` |
| `SMG_JWT_AUDIENCE` | 无 | 配了就校验 `aud` |
| `SMG_JWT_JWKS_URI` | 无 | **唯一开关**：没配则 JWT 闸门整体关闭 |
| `SMG_JWT_ROLE_CLAIM` | `roles` | 角色 claim 名 |
| `SMG_JWT_ROLE_MAPPING` | 无 | `guest:user,ops:admin`（也接受 `=` 与 `;`） |
| `SMG_JWT_LEEWAY_SECS` | 30 | exp/nbf 时钟余量 |
| `SMG_JWT_JWKS_CACHE_SECS` | 300 | 缓存 TTL |

nginx 会重建 worker 环境，未声明 `env` 的变量在 worker 里 `os.getenv` 一律 nil，而三个 conf 的
`init_by_lua_block` 只 require `resty.luarouter`、不加载 router.lua，所以没有任何属于本任务
所有权的文件能在 master 阶段抓快照。结论只能是加 `env` 声明，和既有
`env SMG_CONTROL_PLANE_API_KEYS;` 同一规则、同三处同加。

只把 `SMG_JWT_JWKS_URI` 当开关是有意的：只配 issuer/audience 而没有端点，等于声明了一套谁也
没法执行的校验，那种情况下静默放行比报错更危险。

### 2.2 闸门语义

```
Bearer token 进来
  ├─ 没配 JWKS URI  ────────────────────────────┐
  ├─ 不是三段 JWS（=API key 走错门）  ───────────┤→ 记 WARN(auth_method 不变)，沿用既有多 key 逻辑
  ├─ JWKS 拉不下来（端点挂了/非 loopback http）──┘
  ├─ 三段 JWS 且验签/claim 失败 ── 401 invalid JWT: <原因> + WWW-Authenticate，不回退
  └─ 验签通过 ── 角色映射 admin ──┬─ admin → 200
                                 └─ user  → 403 Admin role required
```

「不回退」这条与 Rust middleware 一致：一个真 JWS 验不过却放行给共享 API key，等于把
fail-fast 变成 fail-open。回退只发生在 JWT **平面本身不可用**的时候（没配、拉不到、给进来的
根本不是 JWS），这正是任务里「JWT 不可用时再按现有多 key 逻辑」的含义。e2e 的
`[fb] a forged/expired JWT is not rescued by a valid admin key` 与
`[fb] with the JWKS endpoint dead, the admin API key still works` 分别钉住两侧。

只有 `Authorization: Bearer` 会被当成 JWT。`x-api-key` 头仍然只走 key 逻辑（Rust 也只读
Bearer），所以把 JWT 塞进 `x-api-key` 是 401 而不是被当 key 匹配。

### 2.3 算法与密钥

白名单 RS256/384/512、ES256/384（与 smg-auth 的 `JWT_ALGS` 同），HS* 与 OKP/EdDSA 直接拒绝。
**token 的 alg 必须等于 kid 所指 JWK 自己的 alg**（JWK 有 `alg` 用它，否则 RSA→RS256、
EC P-256→ES256、P-384→ES384），这是算法混淆的防线：拿 EC 公钥去按 RSA 验、或者反过来，都会
被这条挡掉。

验签走镜像自带的 `resty.openssl.pkey`：

```lua
local pk = pkey.new(cjson.encode(jwk), { format = "JWK", type = "pu" })
pk:verify(sig_raw, signing_input, "sha256")                          -- RSA
pk:verify(sig_raw, signing_input, "sha256", nil, { ecdsa_use_raw = true })  -- EC
```

三个坑值得记下来，都踩过：
1. `format = "JWK"` 必须显式给。不指定时 resty.openssl 先按 PEM/DER 猜，key 对象看着建成功了，
   到 `verify` 才报 `expect a string at #1`。
6. JWS 的 ECDSA 签名是定宽 `r‖s`（各 32B/48B），不是 DER，所以要 `ecdsa_use_raw`；宽度不对先
   在 Lua 侧拒掉，不进 OpenSSL。
3. JWKS 里 RSA 的 `n` 必须带前导零字节补到 256B，否则 JWK 构造失败。

镜像里另有 `resty.jwt`（xmath/cjwt fork），但它不认 kid 也没有 JWKS 管理，且 alg 覆盖与
smg-auth 不一致，所以只用 openssl 原语自己搭，纯决策函数保持能在 luajit 下裸跑。

### 2.4 抓取与缓存

- 抓取复用 `hb.http_get`（K8s discovery 的 poll 同一个函数、同一个连接池 kind="hb"），
  超时 5s，非 2xx 视为不可用，body 上限 1MiB（Rust 的 `MAX_JWKS_BYTES`）。
- 缓存在**进程表**，TTL = `SMG_JWT_JWKS_CACHE_SECS`；`resty.lock("lr_locks")` 做跨 worker 单飞。
- kid 未命中 → 强制刷新一次（对齐 Rust 的 rotate 重试），强制刷新有 5s 冷却，避免随便一个
  陌生 kid 就打爆 IdP。
- `resty.lock:new()` 传的是**字典名**字符串，不是 `ngx.shared.lr_locks` 对象 —— 传对象会得到
  `dictionary not found`，这个错误会让闸门误判成「JWKS 不可用」从而整体退化成 API key 模式，
  属于必须写下来的静默失败。

`_M.status()` 返回配置与缓存年龄（含 `last_fetch`、`last_forced_refresh`），不含任何 token。

### 2.5 与 smg-auth 的差异（全部是刻意的）

| 维度 | Rust smg-auth | 本实现 | 原因 |
|---|---|---|---|
| `nbf` | `validate_nbf=false`，未来的 nbf 被接受 | **校验** | 更安全的超集 |
| SSRF 私网拦截 | 拒绝私有 IP | 只拒绝非 loopback 的明文 http；https 一律放行 | 内网 IdP 本来就部署在私网，照抄等于不能用的功能；e2e 用 127.0.0.1 |
| JTI 重放缓存 | 默认无 | 无 | 与上游一致 |
| 密钥缓存 | 进程内 `RwLock` 一份 | 每 worker 一份 | nginx worker 不共享 Lua 表；与 cache_aware 亲和树（impl-policies.md 偏差 1）同理 |
| 三段 JWS 验签失败 | 401，不回退 | 401，不回退 | 与任务文字「别让无效 JWT 阻断有效 API key」的冲突在此：采用 Rust 语义，把「不可用」解释为平面故障，见 §2.2 |
| 单飞锁 | 无（进程内 RwLock 天然串行） | `resty.lock` over `lr_locks` | 多 worker 下避免同时打 IdP |
| iss/aud 为数组 | aud 需是期望集合的子集 | 命中期望值即通过 | 与 Rust 的实际判定等价（期望值是单值配置） |
| 401 响应体 | `Invalid JWT: <err>` | `{"error":{"message":"invalid JWT: <err>","code":"unauthorized"}}` | 沿用本项目既有的 error_body 形状 |

### 2.6 审计

沿用 `cp_audit()`，只把硬编码的 `auth_method` 改成读 principal 自带的值：
JWT 主体是 `jwt`，key 仍是 `api_key`，无凭证仍是 `none`。JWT 主体的 principal 形如
`jwt:<sub>`（sub 缺失时依次退到 email / preferred_username / unknown），与 Rust 的
`Display for AuthMethod` 一致。deny 行带 `reason=admin_role_required`（角色不足）或
`reason=invalid_jwt`（验签失败）。**token 本身绝不入日志**，只记录失败原因。

## 3. 测试

- `test/unit/test_jwks.lua`（新，120 checks）：base64url 解码用 Python base64 生成的
  18 条真向量（1..256B，含 JWT claims 的真实长度段）、token 拆分、alg 白名单与混淆守卫、
  ECDSA 定宽预检、iss/aud 字符串与数组、exp/nbf 与 leeway、角色提取与映射的四种缺省、
  jwks_uri 白名单、JWKS 文档解析边界、以及闸门关闭时的回退返回值。已注册进 final_gates
  的 `unit` 门（luajit 口径）。
  注：验签本身需要 `resty.openssl`（即 ngx 运行时），所以不在单测里，由 e2e 覆盖。
- `e2e_discovery_dp.py`：72 checks / 0 fail。顺带修掉一个既有 flake：`[k8soff]` 用
  「API server 收到的请求数」证明 discovery 没被调用，但这个数把所有请求都算进去了，
  而 fake API server 绑 0.0.0.0，上一组 router 终止过程中的健康探测 `/v1/models` 会打到
  被回收的端口上，于是偶发 1 次误计。改成只统计 `/api/v1` 前缀的 discovery_calls。
- `e2e_jwt.py`（新）：48 checks / 0 fail，5 个容器分组
  （allow / deny / fallback / cache / audit）。JWKS 端点是文件内的 stdlib HTTP server，
  自己计数，缓存行为只能靠请求次数从外面观测；RSA-2048 与 EC P-256 密钥、以及手搓的
  compact JWS 都由 `cryptography` 现场生成（环境里没有 pyjwt，手搓也顺带证明本模块说的是
  标准 JWS 而不是某个库的方言）。覆盖：RS256/ES256 admin 放行、aud 数组、过期（含超 leeway）、
  错 iss、错 aud、缺 iss/aud、未来 nbf、user 角色 403、未映射角色默认 user、无角色默认 user、
  篡改签名、HS256、两种算法混淆、缺 kid、非 JWS、两侧回退规则、一次抓取多次命中、
  轮换后自动生效、陌生 kid 不放大请求、审计 auth_method=jwt 与 token 不落日志。
- 契约套件新增 `jwt_gate` 段（11 checks，769 → **780**）：它管两件只有契约跑能钉住的事
  —— `SMG_JWT_*` 是否真的到了 worker（`openresty -t` 只查语法，漏一行 `env` 会让整个闸门
  静默失效），以及 JWT 平面不可用时既有多 key 契约是否原样保留；顺带钉住「header 段不是
  JSON 的三段 token 属于确定性失败、不回退」这条与 Rust 一致的判定。
- final_gates：13 门 → **14 门**（新增 `e2e_jwt`，注册在 `e2e_discovery_dp` 之后；`unit`
  门的 luajit 列表加 `test_jwks`）。

## 4. 已知限制

1. `doc/gap-discovery-dp.md` §1.5「尚未注入」一节已被本文件取代（该文件不在本次所有权内，
   未改动），其结论「rank 只是调度身份」不再成立。
2. `SMG_JWT_*` 必须走 conf 的 `env` 声明；`/_ui` 上的 config 面板改不了这些值（它们不在
   config_store 的 ENV_NAMES 里），改完要重启容器。
3. JWKS 缓存不跨 worker：强制刷新后，其他 worker 最长仍会拿旧 keys 到各自 TTL 到期。轮换窗口
   内表现为「同一个 token 时而 200 时而 401」，最坏 `SMG_JWT_JWKS_CACHE_SECS` 秒。生产上把该值
   调小，或者靠 kid 变化触发（本模块会在 miss 时强刷）。
4. 不做 JTI 重放保护：一个有效 token 在过期前可以无限次重放（Rust 默认同样如此）。
5. `--jwt-role-mapping` 在 Rust 是 CLI 的 Append 列表，这里压成一个 env 串；角色 claim 缺失时
   会依次试 `role`/`roles`/`groups`/`group`（同 Rust），全都缺失则默认 user。
6. 单飞锁依赖 `lr_locks`；缺失时退化为每 worker 各抓一次（不影响正确性，只影响 IdP 请求量）。
7. gRPC 面与 PD 分离路径不注入 rank（Rust 的 pd_router 会在 prefill/decode 两份 body 里各写
   一次，Lua 侧的 PD 转发在 `pd.lua`/`grpc_proxy.lua`，不在本次接线范围）。
