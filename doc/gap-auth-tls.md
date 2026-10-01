# lua-router 控制面多 key/角色/审计 与 服务端 TLS

日期：2026-09-30（UTC）。对端 = `gateway/` 工作树 + `smg-auth` 1.0.0（`~/.cargo/registry/src/*/smg-auth-1.0.0`）。
证据：契约套件 `auth_rbac`（33 项）+ `tls_server`（19 项），见 §5。

## 1. 控制面多 key（SMG_CONTROL_PLANE_API_KEYS）

格式 `id:name:role:key`，条目之间用逗号或分号分隔；每条只在前三个冒号处切分
（对齐 `gateway/src/main.rs:670` 的 `splitn(4, ':')`），所以 **key 本身可以含冒号**。
role 大小写不敏感，只接受 `admin|user`；`name` 可以含空格。非法条目跳过并写一条
`ngx.log(WARN)`，不会让整个实例起不来（Rust 是 `eprintln!` + 丢弃该条，语义一致）。

闸门逻辑在 `lualib/resty/luarouter/router.lua`：

- `parse_control_plane_keys(raw)` 纯函数，导出为 `_M.parse_control_plane_keys` 供单测探针；
- `control_plane_keys()` 每进程解析一次并缓存（worker env 在运行期不会变）；
- `check_control_auth()` 列出所有条目做**常数时间比较**（复用 `constant_eq`），
  命中后不早退，遍历完全部条目 —— 命中与未命中的耗时一致；
- 命中写入 `ngx.ctx.lr_cp_principal = {id, name, role}`，`_M.control_principal()` 可读；
- `role=admin` 放行；`role=user` 认证通过但对控制面回 **403**
  `Admin role required for control plane access`；
- token 缺失/错误回 **401**，并在响应头加 `WWW-Authenticate: Bearer realm="control-plane"`。

**优先级**：一旦 `SMG_CONTROL_PLANE_API_KEYS` 有合法条目，控制面**只**认这些 key，
单 key（`SMG_CONTROL_PLANE_API_KEY`，回退 `SMG_API_KEY`）不再授予控制面权限 —— 这是 Rust
control-plane middleware 顶替 simple authenticator 的行为。列表缺失/全非法时，
`check_control_auth` 走原实现，逐字节不变（旧断言 `invalid control plane key` 仍绿）。

覆盖面 = 所有调用 `check_control_auth` 的端点：`/workers` 全套 CRUD、`POST /flush_cache`、
`GET /v1/loads`、tokenizer/parse 管理面，以及 `mesh_control_auth` 的 fallback，
因此 `/_mesh/internal/*` 与 `/ha` 写面同样受角色门约束。`mesh_control_auth` 的
「无任何 key 则开放」前置条件加了一条 `#control_plane_keys() == 0`，避免多 key 已配置时
mesh 面被误判成开放面。

**数据面不受影响**：`check_data_auth` 仍只看 `SMG_API_KEY`。admin 控制 key 拿去打
`/v1/chat/completions` 会回 401（契约断言）。控制面接受 `x-api-key` 头（本仓库既有形态）。

## 2. 审计日志

`outcome=allow|deny principal=<id> name=<name> auth_method=api_key|none role=<role>
method=<METHOD> path=<uri> [worker_id=<id>] [reason=<code>] [request_id=<id>]`，
写在 `ngx.INFO`，**永不打印 key 值**（契约断言三个 key 字符串都不出现在 `docker logs`）。
`worker_id` 从 `/workers/<id>` 路径提取；未认证的 deny 记 `principal=unauthenticated
auth_method=none`。`SMG_DISABLE_AUDIT_LOGGING=1|true|yes|on` 关闭整条链路。

审计只覆盖控制面决策，与 Rust 的 `smg::audit` 目标范围一致（推理面不落这条）。

## 3. 服务端 TLS

`SMG_TLS_CERT_PATH` + `SMG_TLS_KEY_PATH` 同时给出且文件非空时，入口脚本把主监听渲染成

```
listen 0.0.0.0:30000 ssl;
server_name _;
ssl_certificate ...; ssl_certificate_key ...;
ssl_protocols TLSv1.2 TLSv1.3; ssl_prefer_server_ciphers on;
ssl_session_cache shared:LR_TLS:10m; ssl_session_timeout 10m;
```

即 **TLS socket 替换同端口的明文监听**（Rust `server.rs:1841-1856` 用 rustls 就是这个语义），
因此没有引入 `SMG_TLS_PORT`。只给一半或文件缺失 → 入口脚本 `exit 1`（快速失败，
不进 crash loop）；渲染结果由已有的 `openresty -t` gate 兜底。两个占位符
`${TLS_LISTEN_FLAGS}` / `${TLS_SERVER_EXTRA}` 已加入 `TEMPLATE_VARIABLES` 白名单，
banner 末尾多出 `tls: on (TLSv1.2/1.3)` / `tls: off`。

未配置任何 TLS 变量时渲染与改动前等价（`listen 0.0.0.0:30000;`，无 ssl 指令），
明文路径不回归。**独立 metrics 监听与 gRPC 监听保持明文**（见 §4）。

## 4. 与 Rust 的差异（诚实清单）

| 项 | Rust | lua-router | 影响 |
| --- | --- | --- | --- |
| 401/403 body | axum 纯文本 | 本仓库统一 JSON + `X-SMG-Error-Code` | 只读 message 的客户端无差别；逐字节比 body 的会差 |
| 403 文案 | `Admin role required for control plane access` | 同 | 无 |
| `WWW-Authenticate` | `Bearer realm="control-plane"` | 同 | 无 |
| key 存储 | 载入时 SHA-256，比对哈希 | 明文 env + 常数时间逐字节比对 | 本机 Lua 无稳定常数时间哈希比较；比较侧等价，内存中明文残留是差异 |
| JWT 面 | `--jwt-issuer/--jwt-audience/--jwt-role-mapping` 可替代 key 面 | **未实现**，只支持 api_key | 用 JWT 的控制面无法迁移 |
| `/ha` 读面 | mesh/HA 路由挂在 plain `auth_middleware`（数据 key），非控制 key | 沿用本仓库 `mesh_control_auth`：无 key 时开放，有 key 时要求控制 key | 已经在契约里固化的既有偏差，本次只加了「多 key 已配置时不开放」的护栏 |
| metrics/gRPC 监听 | 与主监听共用 TLS 配置 | 保持明文 | 需要 scrape over TLS 的部署得自己加反代 |
| TLS 曲线/套件 | rustls 默认 | nginx 默认 + `ssl_prefer_server_ciphers on`，协议下限 1.2 | rustls 默认也只 ≥1.2；套件清单不同 |
| TLS SNI/多证书、mTLS | rustls 可配 | 未实现（单证书对） | 客户端证书校验类需求不支持 |

## 5. 契约与自证

`test/test_lua_router.sh` 新增两节（不新增 gate 文件，沿用 contract gate）：

- `auth_rbac`（33 checks）：admin 200、user 403 + 文案 + `X-SMG-Error-Code`、错误/匿名 401 +
  `WWW-Authenticate`、单数据 key 失权、admin key 不能打数据面、`x-api-key` 双平面、
  `/_mesh/internal` 角色门、审计 allow/deny/worker_id/无 key 泄露、`SMG_DISABLE_AUDIT_LOGGING`、
  非法条目跳过 + role 大小写、key 含冒号、无列表时单 key 行为不变。
- `tls_server`（19 checks）：渲染断言（`listen ... ssl;`、证书/密钥/协议）、
  `curl --cacert` 下 `/health` 200、注册 worker 202、chat 200、SSE `data: [DONE]`、
  `openssl s_client -tls1_2` 验证通过、TLSv1.1 拿不到响应、明文 http 打到 TLS 端口不服务、
  不设 TLS 变量时明文监听逐条不变、只给一半变量与文件缺失各回一条入口错误。

测试证书不落仓库，由 `openssl req -x509` 每次生成（含 `subjectAltName=IP:127.0.0.1,DNS:localhost`），
与 `tls_upstream` 一节的做法一致。

nginx 会按 `env` 白名单重建 worker 环境，请求期 `os.getenv` 的开关必须先声明，
所以 `conf/nginx.conf.template`、`conf/lua-router.conf`、`test/conf/nginx-lua-router.conf`
都放行了 `SMG_CONTROL_PLANE_API_KEYS` 与 `SMG_DISABLE_AUDIT_LOGGING`。

## 6. 未做的事

JWT 控制面、mTLS、metrics/gRPC over TLS、key 哈希存储、以及把审计接到推理面 ——
都需要单独决策，不属于本次范围。
