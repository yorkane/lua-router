# 管理面 Basic Auth（用户裁定 2026-10-12）

## 1. 边界：保护什么、不保护什么

网关有三套互不相同的入口面，本次只给其中一套加门：

| 面 | 路径 | 是否鉴权 | 凭据来源 |
|---|---|---|---|
| admin 管理台 + 配置数据面 | `/`（入口文档）、`*.html`、`/config*`、`/logs*`、`/stats`、`/slots`、`/tools` | **是**（Basic） | 本文件 |
| 配置数据面的 webui 别名 | `/u/config*` 全部 9 条 | **是**（同一道 `guard()`） | 本文件 |
| 控制面 klib 路由 | `/workers`（含 GET 与逐 id 读写）、`/model-map`、`/flush_cache` | **是**（`guard_klib()`，见 §6） | 本文件 |
| 模型访问面 | `/v1/*` 等转发面 | 否 | 调用方自带 api-key，与本层无关 |
| 对话界面 webui | `/u/` 非 config 族（`/u/v1/*` `/u/props` `/u/slots` `/u/logs*` `/u/stats` `/u/tools` `/u/v1/stream`） | 否（用户裁定） | — |
| 健康 / 指标 / 公开面 | `/health` `/readiness` `/liveness` `/metrics` `/v1/models` `/server_info` `/v1/loads` `/ha/*` `/_mesh/internal/*` | 否 | 监控面与集群互联必须匿名 |

> 2026-10-12 收口补记：首版只挂根数据面，留下两个绕过洞——`/u/config*` 是同一批
> handler 的别名族（匿名可写同一份配置），klib 控制面 `/workers` 匿名可改运行态名册。
> 两洞同性质：**门的覆盖面小于它声称的范围 = 门形同虚设**。现在两族都进门，
> §5/§6 写落点。

不走 authz 体系：网关自己校验，单独提供服务。

## 2. 两条豁免与一条前置否决（用户裁定 2026-10-12 追加 §2.1）

判定顺序写在 `admin_auth.required()` 里：先过前置否决，再按两条豁免的原文顺序判。

1. **`SMG_ADMIN_AUTH_PASS` 未配置或为空串** → 整道门关闭。缺省行为逐字节等于加这道门
   之前（AGENTS.md 硬规则 4「新开关缺省零行为变化」）。空串等同未配置：compose 的注释型
   默认值（`FOO: ""`）不该打开一道空密码的门。
   注意纯空白（`" "`）**是**有效口令，不裁空白 —— 操作员填了什么就比什么。
2. **来源是 loopback** → 免凭据。整段 127/8 加 IPv6 的 `::1`。前缀匹配要求带点
   （`127` 不算，`1127.0.0.1` 不算），拿不到地址时按「非 loopback」处理（fail closed）。
   经反代访问时这一条不成立，见 §2.1。

### 2.1 前置否决：代理来源头一旦出现，一律要凭据（用户裁定 2026-10-12）

要修的洞：反代与网关同机时（8802 经 APISIX：8802-248.ai-t.wtvdev.com ->
127.0.0.1:8802），`remote_addr` 恒 127.0.0.1，loopback 豁免被反代无条件触发，
Basic Auth 形同虚设（2026-10-12 生产实测踩实）。

裁定口径（`admin_auth.has_proxy_origin_header()`）：请求里出现 `X-Real-IP` /
`X-Forwarded-For` / `Forwarded` 任一头名，就**不授予 loopback 豁免**，直接走凭据。
**只看头名出现与否，完全不解析值**：

- 值写成 `127.0.0.1`（客户端伪造本机声明）→ 要凭据；
- 值为空串、畸形、多跳 `127.0.0.1, 10.0.0.1`、重复头（ngx 返回 table）、非字符串值 → 要凭据；
- 头表整体取不到 → 要凭据（fail closed，与 `required(nil)` 同向）；
- 头名比对大小写不敏感（真机 `get_headers(0, true)` 返回原始键名）。

为什么不按值还原来源地址（被推翻的 v1 形状，写清楚免得下一个人改回去）：这三条头的
语义是「上一跳替我转发的，值由那一跳说了算」，而本网关的 nginx 层没有 `set_real_ip_from`
受信网段，没有任何东西替我们保证那一跳写了什么。一旦去解析值，就得回答「信哪一条头、
XFF 取哪一段、值畸形算不算、重复头取第一个还是最后一个」，每一个答案都是新的绕过面；
伪造 `X-Real-IP: 127.0.0.1` 在「按值信 loopback」的实现里直接拿到豁免。把三条头当成一个
布尔量之后这些追问整体消失：**出现 = 来源不可直证 = 认证**。单测 §7.1 变异 B 就是把实现
换回「按值还原」，那几条伪造断言当场红。

行为变化如实记录（这是修复的目的，不是副作用）：

- 经反代访问管理台的本机操作员不再匿名，要输凭据；
- 直连 `curl 127.0.0.1` 不带代理头，豁免不变；缺省（不配 `SMG_ADMIN_AUTH_PASS`）仍是
  整道门关闭、逐字节零变化——豁免一的优先级在这条之前，代理头不会替没配口令的实例
  擅自开门（单测各钉一条）；
- `X-Forwarded-Proto`、`X-Real-Ip-Client` 这类相似名不在名单内（单测钉住），只有那三个
  头名算「代理来源声明」。

若要让经反代的本机操作员继续匿名，正确做法不是在网关里解析代理头，而是在反代上做
（APISIX 的 `proxy-rewrite` 剥掉这三个头再转发，或改用受信网段的 realip），把信任决策
留在唯一知道链路的那一层。

两条豁免都不命中才要凭据；前置否决命中时豁免二直接失效。

## 3. 凭据与校验形状

- 用户名恒为 **`lua-router`**，不可配（`admin_auth.ADMIN_USER`）。
- 密码取 env **`SMG_ADMIN_AUTH_PASS`**，只走 env，不落配置文件。
- 已进三份 conf 的 env 白名单（`conf/nginx.conf.template`、`conf/lua-router.conf`、
  `test/conf/nginx-lua-router.conf`）。漏登记的后果是 nginx 从 worker 剥掉这个变量、
  门静默不生效（AGENTS.md 硬规则 11③）。

非 Basic 方案、base64 解不开、缺 `:` 分隔、用户名错、密码错，全部返回同一个 401，
不区分原因 —— 401 回给探测者的信息量必须为零（否则 401 的差别就是一条「用户名对不对」
的旁路）。密码比对走常量时间：先比长度（长度在 401 之外本来就可观测），再逐字节异或累积。

401 必带 `WWW-Authenticate: Basic realm="lua-router admin"` + `Cache-Control: no-store`。
realm 是不带秘密的文案位：口令、内网地址、版本一律不写。

## 4. 传输安全前提

Basic 口令是**明文 base64**，只在 HTTPS 下才安全。走明文 HTTP 时口令在链路上裸奔，
所以本层只在「可信内网」或「前面已有 TLS 终结边缘」的前提下用；要跨不可信网络，要么给
容器开 `TLS_LISTEN_FLAGS`，要么在 authz / APISIX 上终结 TLS 再放行。

loopback 豁免的边界同样要说清：网关跑 host 网络，同机任何进程 `curl 127.0.0.1` 都落在
豁免区。它防得住跨机未授权访问，防不住本机任一进程的越权 —— 这是「网关零鉴权、只信
边缘」既有信任模型的延伸，不是本文件新引入的洞。

## 5. 落点与实现形状

- `lualib/resty/luarouter/admin_auth.lua`：`password` / `is_loopback` / `required` /
  `has_proxy_origin_header`（§2.1 前置否决，只看头名不解析值）/
  `check_header` / `const_eq` / `challenge` / `guard` / `static_challenge_worthy` /
  `guard_static`。
- `conf/ui.conf`：24 条 exact location 各加一行 `access_by_lua_block { ... .guard() }`，
  exact 纪律不破（前缀 location 会 shadow 同名静态文件，文件头写了这条）。清单：
  根数据面 15 条 `/logs` `/logs/stream` `/logs/backends` `/stats` `/config`
  `/config/effort` `/config/ctx` `/config/model` `/config/virtual` `/config/upstreams`
  `/config/policy` `/config/apply` `/config/model-map` `/slots` `/tools`，
  外加 `/u/` 别名族 9 条 `/u/config` `/u/config/effort` `/u/config/ctx`
  `/u/config/model` `/u/config/virtual` `/u/config/upstreams` `/u/config/policy`
  `/u/config/apply` `/u/config/model-map`（同一批 handler，两族必须同权）。
- `location /`（admin 静态）用 `guard_static` 而不是 `guard`：access 阶段跑在
  `try_files` 之前，整块一拦会把 try_files 未命中、本该由 `@lmr_klib` 回答的
  `/v1/*` `/health` `/metrics` 一起锁死。所以只对「打开管理台」这个动作发挑战：
  `/` 与 `*.html`。浏览器拿到 401 挑战后会对同源后续请求带凭据，所以 js/css 这类
  无秘密资源放行不减弱保护。
- 单测 `test/unit/test_admin_auth.lua`（luajit 口径、假 ngx、零端口，已进 gate_unit 名单）。
  反证用六段变异源码：删口令豁免 / 删 loopback 豁免 / 空串当口令 / klib 清单摘掉
  `/workers` / klib 前缀匹配去掉边界 / klib 清单换成数据面前缀，全部必须红。
  另有 conf 接线清单断言（逐行扫 `conf/ui.conf` 的 location 块钉 24 条 guard 挂载、
  对照清单钉 `/u/` 对话面匿名、router.lua 钉 `guard_klib` 在 OPTIONS 短路之后分发之前）
  ——判定函数全对但漏挂一条 location，正是洞 1 的成因，只有清单断言能拦住它。

## 6. klib 控制面：单一挂点 + fail-open 清单

`/workers`（含逐 id 的读写删）、`/model-map`、`/flush_cache` 由 `router.lua` 的 klib
路由表拥有，不是 ui.conf 的 location；它们与推理面 `/v1/chat/completions`、公开面
`/health` `/metrics`、mesh 互联 `/_mesh/internal/*` 共用**同一个 dispatcher**
（`location /` 的 try_files 未命中全落进来），所以挂点只能是 dispatcher 里的路径过滤器：

```lua
-- router.lua handle()，OPTIONS 预检短路之后、instance:handle() 分发之前
admin_auth.guard_klib()
```

三点形状：

1. **单一挂点在 handle**，不是逐 handler 挂：逐条挂要动 15 个注册点，漏一条就是一个
   洞（洞 1 的教训），且逐 handler 挂不到 OPTIONS 短路之后的位置。
2. **必须在 OPTIONS 短路之后**：浏览器 CORS 预检从不带凭据，预检若过门会把跨域管理台
   整体变成 401（preflight_guard 在 rewrite 阶段应答、本门在 content 阶段，顺序天然
   成立；单测与真机各钉一条 OPTIONS 永不 401）。
3. **清单刻意 fail-open**（默认放行，名单内才拦）。判据是后果不对称：数据面/公开面被
   误拦 = 推理流量与监控当场断，属「看不见就炸」；管理面漏拦 = 多一条匿名路。所以新增
   受管路径要在 `KLIB_ADMIN_PREFIXES` 里添一行，清单外的一切照旧。前缀匹配带斜杠边界
   （`/workersfoo` 不拦，变异反证钉住）。

清单内三族：`/workers`（读写全拦——名册是配置面的镜像，GET 也拦，与 ui.conf 侧
`GET /config` 同权）、`/model-map`（watcher 改名表）、`/flush_cache`（向全部 worker
发广播）。**刻意不进清单**的：`/metrics`（Prometheus 抓取必须匿名）、`/v1/loads`
（健康判定链 hb 逐秒读它，拦了会让健康评估吃 401）、`/ha/*` 与 `/_mesh/internal/*`
（集群互联面，节点间 401 会被记成对端故障）、`/wasm*`（501 面）、404 sink。

真机验证（lr-adminauth，host 网络 = 与生产同形态，28 项）：配口令后局域网
`/u/config*`→401、`/workers` GET/POST→401、带凭据→200、loopback 全豁免、
`/u/v1/chat/completions` 与 `/v1/chat/completions` 永不 401、OPTIONS 预检永不 401、
`/` 入口文档→401 带 WWW-Authenticate；不配口令全 200（缺省零行为变化）；
`/u/config` 与 `/config` 回同一份文档（别名族同权的直接证据）。
反证两条：摘掉 ui.conf 的 `/u/config` 门 → 局域网变回 200（红）；摘掉 router.lua 的
`guard_klib` 行 → `/workers` 变回 200（红）。
