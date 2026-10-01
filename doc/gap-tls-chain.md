# lua-router 服务端 TLS 证书链 / SNI / 负例门禁（e2e_tls_chain）

日期：2026-09-30（UTC）。被测对象 = `lua-router:integration`（OpenResty 1.31.1.1，
链接独立编译的 OpenSSL 3）由 `docker-entrypoint.sh` 渲染出的 TLS 主监听。
门禁文件：`test/integration/e2e_tls_chain.py`（944 行，**112 checks / 0 failed / 2 notes**）。
本轮**未改任何核心实现**（`conf/`、`docker-entrypoint.sh`、`router.lua` 逐字节不变），
发现的两个真实缺口只记录不修，见 §5、§6。

## 0. 这一门禁补的是哪一段空白

契约 `tls_server` 段（contract gate 内，19 checks）只证明「渲染出了 ssl 指令 + 用一张
自签证书能 200」。它无法回答这些在生产上真正咬人的问题：

- 服务器**是否真的把中间证书发出去**了。只配 leaf 也能通过 `openresty -t`、也照样
  监听端口，但除了「本机恰好存了中间证书」的客户端，全部握手失败 —— 这是
  证书链事故的第一个形态；
- 四种坏证书（过期 / 名字不匹配 / 签发者不是 CA / 自签）客户端**报的原因是不是它自己的原因**，
  以及被拒绝时 router 会不会连带崩溃；
- 换 ECDSA 证书后 TLSv1.2 的套件族有没有跟着换；
- 一个端口上两张证书怎么发（SNI）。

## 1. 运行时 PKI 结构

证书全部由门禁在 `/data/tmp/lr/tls-chain-<pid5>/` 现场用 openssl 生成，不落仓库；
该目录以**只读**方式挂进容器成为 `/gen`，容器内只能用绝对路径读，读不到宿主机别处。

```
Root CA            RSA-3072, sha256SelfSigned, CA:TRUE keyCertSign
└── Intermediate   ECDSA P-384, 由 Root 以 sha384 签发
        CA:TRUE pathlen:0（跨签名算法：RSA 根 + EC 中间）
    ├── router-rsa   RSA-2048  SAN: DNS:router.test,DNS:www.router.test,IP:127.0.0.1
    ├── router-ec    ECDSA P-256 SAN: DNS:ec.router.test,DNS:www.router.test,IP:127.0.0.1
    ├── alt-ec       ECDSA P-256 SAN: DNS:alt.router.test          （SNI 第二张）
    ├── wronghost    RSA-2048  SAN: DNS:notrouter.test,IP:10.99.99.99
    ├── cnbutsan     RSA-2048  CN=router.test 但 SAN 只有 other.test
    ├── nosan        RSA-2048  -clrext 生成，完全没有 SAN，只剩 subject CN
    └── expired      RSA-2048  SAN: DNS:expired.router.test,IP:127.0.0.1
                       有效期 2020-01-01 ~ 2021-01-01，由 `openssl ca` Micro-CA
                       （default_startdate/default_enddate + 独立 index/serial）签发
Rogue Root CA (ECDSA P-256) └── Rogue Intermediate (RSA) ── rogue  leaf   （非信任链）
Fake Issuer  自签，CA:FALSE + keyUsage=digitalSignature ── fake   leaf   （签发者不是 CA）
selfsign     RSA-2048 自签叶子，无 CA                                 （无 CA 签发）
```

客户端信任库两份，故意分开：

- `ca-root-only.crt` —— **只给根**。用它验过就说明中间证书是服务器自己发出来的；
- `ca-root-plus-inter.crt` —— 根 + 中间，用于负例（把「链不完整」从变量里剔除，
  失败只剩被测的那一个原因）。

链完整性在上线前先用离线断言钉死（§2 计数里前 13 项）：leaf 单独 + 根 **必须**验不过
（`unable to get local issuer certificate`），leaf + 中间 + 根 **必须**验得过，
过期件离线也**必须**报 expired。也就是说「服务器发全链」这一条不是被信仰出来的，
是先证明 leaf 单独确实不行。

每个负例都通过**匹配自身 SAN 的主机名**访问（`expired.router.test` 等），
因此一次拒绝不可能是主机名失败伪装出来的。

## 2. 覆盖面与计数（112 checks）

| 段 | 内容 | checks |
|---|---|---:|
| `pki` | 离线自证：根/中间/leaf 三种组合的 openssl verify 结论、SAN 同时含 DNS 与 IP、RSA 根 + EC 中间、CA:FALSE 签发者离线即拒、rogue 链在自己的根下成立、自签被真根拒、wronghost/cnbutsan/nosan 三个 fixture 的形状 | 13 |
| `rsa` | 横幅 `tls: on (TLSv1.2/1.3)`、渲染断言（`listen 0.0.0.0:<port> ssl;` + fullchain 路径）、只信根 200、信根+中间 200、链深度=2、发出的 leaf 指纹=预期、IP SAN 与第二个 DNS SAN 各 200、默认 TLSv1.3、强制 TLSv1.2、`POST /workers` 202、worker 健康、chat 200、SSE `data: [DONE]`、TLSv1.1 拿不到响应、明文 http 打到 TLS 端口不服务 | 20 |
| `ec` | 只信根 verify ok、指纹=P-256 leaf、链深度=2、TLSv1.3、TLSv1.2、**套件族=ECDHE-ECDSA**、worker 健康、chat 200、IP SAN、无 mTLS（不发 client-CA 名单）、带客户端证书也照样 200 | 11 |
| `sni` | 同一端口：SNI=router.test→RSA leaf、SNI=alt.router.test→EC leaf、alt 证书同一根下 verify ok、未匹配 SNI→默认证书、**无 SNI→默认证书**、两个名字都服务 router API、注册状态共享（alt 名注册→主名可见）、同端口 TLSv1.2 下 alt 走 ECDSA 套件而主名走 RSA 套件 | 9 |
| `expired` / `rogue-ca` / `nonca` / `selfsigned` | 每类 10 项：curl 拒绝 + curl 文案、python 验证器拒绝 + 文案、s_client verify code 非 0 + 文案、**被拒的 leaf 确实完整发出（指纹匹配）**、`-k` 仍 200、容器仍活、无崩溃日志 | 40 |
| `mismatch` | 有效链 + 错主机名：curl 拒（`no alternative certificate subject name`）、python 报 Hostname mismatch、链单独 verify=0（证明失败只来自名字）、`-verify_hostname` 报 code 62、同证书的正确名字 200 | 5 |
| `cnbutsan` | 有 SAN 时 CN 被忽略（CN-only 命中被拒）、SAN 名 200 | 2 |
| `nosan` | 无 SAN 时 OpenSSL 回落 CN 接受、既不匹配 SAN 也不匹配 CN 被拒 | 2 |
| `pairing` | 证书与私钥不配对的真实行为（见 §5） | 5 |
| `render` | 只给 cert 不给 key → 入口 `exit 1` "must be set together"；key 文件不存在 → `exit 1` "certificate or key missing"；把 CA 证书当服务器证书仍能渲染（`-t` 通过） | 3 |
| `stability` | 收尾时全部 TLS 实例仍在跑、全程无 `[emerg]`/signal 11/6/lua aborted/core dumped | 2 |
| 合计 | | **112** |

一轮共起 **11 个 TLS 实例**（rsa / ec / sni / 四类负例 / wronghost / cnbutsan / nosan / pairing）
加 3 次一次性 `openresty -t`，全部由门禁自己 `docker rm -f` 收尾。

## 3. 关键实测结论

### 3.1 链完整性（服务器侧发全链才成立）

`ssl_certificate` 指向 `leaf+intermediate` 拼接文件；客户端只存根：

```
depth chain seen: 0 s: CN = router.test, O = LtTlsChain Test
                  1 s: CN = LtTlsChain Test Intermediate CA, O = LtTlsChain Test
Verify return code: 0 (ok)
```

深度 2 + 只信根 ok 两件事同时成立，才是「链是服务器发的」的证据。对照组：leaf 单独
喂 `openssl verify -CAfile root` 直接 `error 20 ... unable to get local issuer certificate`。

### 3.2 四类握手负例（各自的客户端判词）

同一实例、同一信任库，只有被测那一项不同。curl rc 一律 60（无响应），`-k` 一律 200：

| 类别 | curl / python 报的原因 | `openssl s_client` verify code | 说明 |
|---|---|---|---|
| 过期 leaf | `certificate has expired` | **10** (certificate has expired) | 由 Micro-CA 显式签发到过去的时间窗 |
| 非 CA 签发的链（rogue） | `unable to get local issuer certificate` | **21** (unable to verify the first certificate) | 信任库不含 rogue 根，属信任问题而非形状问题（离线对照：rogue 链在自己的根下 verify 通过） |
| 签发者 CA:FALSE | `invalid ca certificate` | **32** (key usage does not include certificate signing) | 签发者在信任库里，但 keyUsage 不允许签发 |
| 自签无 CA | `self-signed certificate` | **18** (self-signed certificate) | 真根不含它 |
| 主机名/SAN 不匹配 | `no alternative certificate subject name matches target host name` | 链单独 **0 (ok)**；加 `-verify_hostname` 后 **62** (hostname mismatch) | 唯一「证书本身没问题」的一类，所以必须用 `-verify_hostname/-verify_return_error` 才看得见拒绝 |

四类负例都验证了「被拒的 leaf 仍然被完整发出」——即拒绝发生在客户端，服务器没有半途断流。
每类之后 `-k` 拿 200、容器存活、无崩溃行。

### 3.3 密钥类型 × 协议矩阵

真实协商结果（python `ssl` 与 openssl CLI 双向一致）：

| leaf | 协议 | 协商套件 | 只信根 verify | 链深度 |
|---|---|---|---|---|
| RSA-2048 | TLSv1.3（默认） | `TLS_AES_256_GCM_SHA384` | 0 | 2 |
| RSA-2048 | TLSv1.2 | `ECDHE-RSA-AES256-GCM-SHA384` | 0 | 2 |
| ECDSA P-256 | TLSv1.3（默认） | `TLS_AES_256_GCM_SHA384` | 0 | 2 |
| ECDSA P-256 | TLSv1.2 | `ECDHE-ECDSA-AES256-GCM-SHA384` | 0 | 2 |

TLSv1.3 的套件名不体现签名算法（密钥类型只反映在证书上），所以**密钥类型的断言必须打在
TLSv1.2 上**，这一点在测试里通过 `maximum_version=TLSv1_2` 固定。
TLSv1.1（`--tls-max 1.1`）拿不到任何响应；明文 http 打到 TLS 端口也不会被服务 ——
与 Rust rustls 的「替换明文监听」语义一致。

### 3.4 SNI 与多证书能力（本仓库镜像的实测边界）

镜像里的 OpenResty 1.31.1.1（nginx 核心 1.31.1，晚于 1.25.10）**支持一个 `server{}` 里写多对
`ssl_certificate`/`ssl_certificate_key`**（nginx ≥ 1.25.10 的能力，证书按客户端
signature_algorithms 能力挑选），但**没有 `ssl_certificate2` 指令**：
`openresty -t` 对 `ssl_certificate2` 直接 `unknown directive`。

双 hostname 双证书用第二个 `server{}` 实现，通过既有的 `LR_HTTP_INCLUDE`
片段注入，不动核心：

```
servername=router.test       -> RSA leaf   verify=0(ok)   TLSv1.2 时 ECDHE-RSA-AES256-GCM-SHA384
servername=alt.router.test   -> EC  leaf   verify=0(ok)   TLSv1.2 时 ECDHE-ECDSA-AES256-GCM-SHA384
servername=www.router.test   -> RSA leaf（未匹配 → 第一个 server，即 default）
servername=<无 SNI>          -> RSA leaf（同上）
```

两个名字背后是同一个 router 进程状态（用 alt 名注册的 worker 在主名的 `/workers` 里可见）。

顺带用一次性配置实测了「一个 server 两对证书」的行为：同一 `a.test` 名下，客户端只发
ECDSA sigalgs → 发 EC leaf，客户端锁定 `ECDHE-RSA` 套件 → 发 RSA leaf。也就是这一形态
提供的是**按算法选证**，不是按 hostname 选证；要按名字选证仍需多个 `server{}`。
（该行为未纳入断言，因为入口脚本渲染不出这种配置，属于片段级能力。）

## 4. mTLS / 数据面 TLS 的实际形态

服务器不发客户端 CA 名单（`s_client` 输出 `No client certificate CA names sent`），
带客户端证书握手仍然 200（证书被忽略）。即**当前实现只有服务端单向 TLS，没有 mTLS**，
本轮只把「没有 mTLS」这件事钉成断言，不实现它。

主监听转 TLS 后，metrics 监听仍是明文（`http://…/metrics` 200），而主端口的 `/metrics`
可以走 TLS 访问；ALPN 未协商（`ssl_alpn`/`http2` 都没渲染，尽管镜像编译了
`--with-http_v2_module`）。gRPC 监听已随平面删除（scope-trim）。

## 5. 缺口一：证书与私钥不配对，入口脚本抓不住（记录，未修）

把 A 的证书配 B 的私钥：

1. `openresty -t` **通过**（nginx 只在加载时做最小检查，不验配对）；
2. 容器正常启动、端口正常监听；
3. **每一次握手都死**：客户端拿到 TLS alert 40 `handshake failure`；
4. 服务器侧默认 `warn` 级别**看不到原因**，把 `SMG_LOG_LEVEL` 调到 `info` 才有
   `SSL_do_handshake() failed ... no suitable signature algorithm`；
5. 不会崩溃（无 `[emerg]`、无 signal、worker 不退），属于 fail-closed 而非 fail-fast。

`docker-entrypoint.sh` 现在只做「两个变量都给 + 两个文件都非空」两条检查，抓不到这件事。
补它需要 `openssl` 二进制，而 **`authz:latest` / `lua-router:integration` 镜像里
没有 openssl**（已实测 `command not found`），因此可选路线是 Lua 侧
`resty.openssl`、或镜像内 vendored 一个静态 openssl、或在 Rust gateway 的健康检查里
带一次真实握手。三条都是核心改动，本轮按「不改核心实现」的边界只落断言 + 文档。
测试里用 `[pairing]` 5 项把这个形态钉住：将来入口脚本加了预检，这几项会立刻变红提醒更新文档。

## 6. 缺口二：入口脚本不检查链是否完整（记录，未修）

`ssl_certificate` 指向只含 leaf 的文件时，`-t` 同样通过、同样监听、同样横幅 `tls: on`，
但只有信任库里恰好有中间证书的客户端能连上（渲染门禁第 3 项也说明入口对
「证书形状」毫无判断：拿 CA 证书当服务器证书照样渲染）。
测试通过「只信根必须验得过」+「leaf 单独离线必须验不过」两头把这条风险量化了，
但要让入口脚本主动拒绝「leaf 无中间」仍需 §5 里同样的 openssl 能力。

## 7. 写这个测试时踩到的 openssl 事实（避免下一个人口述返工）

- `-nameopt` 的取值是 **`UTF8`**；写成 `UTF-8` 会让 `openssl x509` 打印 usage 并以
  非 0 退出。若脚本此时只取 stdout 且不做断言，指纹会变成空串，
  于是「SNI 选对了证书」这类断言会**空对空地通过**。本测试里 `fingerprint()` 现在
  取不到指纹就直接抛异常，不再返回 `""`。
- `openssl x509 -checkhost` **匹配与不匹配都返回 0**，结论只在文本里
  （`does match certificate` / `does NOT match certificate`）。判 rc 一律得到「全通过」。
- `openssl verify` 的失败详情走 **stderr**，`openssl x509 -text` 走 stdout；
  所有负向离线断言统一读 `out + err`。
- `openssl req` 没有 `-extfile`，自签要逐行 `-addext`；`x509 -req -days` 无法把有效期
  推到过去，过期件必须走 `openssl ca` 的 `default_startdate/default_enddate`。
- nginx 只认 `TLSv1.2`，写 `TLS1.2` 直接 `-t` 失败。
- 无 SAN 的 leaf 会被 OpenSSL 3（curl / python / s_client）按 CN 接受，
  而浏览器与 Go 会拒 —— 这是**客户端相关**行为，测试把它记成 NOTE 而不是失败。

## 8. 门禁注册与跑法

`test/final_gates.sh` 里注册位置 = `e2e_policy_parity` 之后（本轮之后别的 agent 又插了一个
`mesh_two`，两者都是「追加在链尾」，互不影响）：

- `GATE_ORDER` 末尾追加 `e2e_tls_chain`；
- 头部 gate 清单与「What skipping costs」两处说明各加一条
  （跳过的代价：链是否真的发出、四类坏 PKI 是否被正确原因拒绝、RSA/ECDSA×协议套件族、
  SNI 选证，全都没有别的 gate）；
- `gate_e2e_tls_chain() { run_integration e2e_tls_chain.py 1500; }`。

单独验证注册（不是全量）：

```
GATE_ONLY=e2e_tls_chain LR_GATE_LOG=/data/tmp/lr-gates/gate-tls-chain2.log \
  bash test/final_gates.sh
→ == gate: e2e_tls_chain  PASS  (16s)
→ final gates: 1 passed, 0 failed, 0 skipped
→ 门禁日志：=== 112 checks, 0 failed, 2 notes ===
```

独立串行跑（同一提交，两轮一致）：

```
cd /path/to/lua-router && LR_TEST_TMP=/data/tmp/lr \
  timeout 1500 python3 test/integration/e2e_tls_chain.py
→ 112 checks, 0 failed, 2 notes（17s，容器 11 起 11 落）

绿的一侧会连自己的 PKI 目录一起删掉（`shutil.rmtree(D)`），失败时才保留
`/data/tmp/lr/tls-chain-<pid5>/` 供事后验尸；容器名统一 `lr-tlsc-<tag>-<pid5>`，
只按名字 `docker rm -f`，不用 pkill。
```

依赖：docker + `lua-router:integration`、宿主机 openssl 3.x、curl、python3。
不需要网络、不需要 Redis、不需要 grpcio。PKI 目录用完由 `cleanup()` 删除。

## 9. 未覆盖 / 已知限制

- **mTLS 不实现也不测双向**，只钉住「当前不发 client CA 名单、客户端证书被忽略」；
- TLS 参数不可调：`ssl_protocols`、`ssl_prefer_server_ciphers`、session cache 全在
  `docker-entrypoint.sh` 里硬编码，没有 `SMG_TLS_*` 旋钮，因此没有「改配置生效」的断言；
  ALPN/h2 未协商（镜像有 http_v2 模块但未渲染）；
- OCSP stapling、`ssl_trusted_certificate`、client CA bundle、证书热更新（`nginx -s reload`
  换证）均未覆盖；
- metrics 监听仍是明文，本门禁不测；
- `config_store` 的 lua-resty-http 快路径必须 `ssl_verify=false`（自签上游握手需要；real-eval 记的三处显式握手不含这条快路径）。
- 证书/私钥**配对**与**链完整性**的入口预检是 §5/§6 的记录性缺口，测试断言的是
  「当前会 fail-closed 而不是 fail-fast」，不是「被正确拦住」；
- 一个 `server{}` 两对证书的「按签名算法选证」只在片段层实测过并写入 §3.4，
  未进断言（入口脚本渲染不出该形态）；
- 测试用 `--network host` + 随机端口，与其他容器化套件并发跑时墙钟时间翻倍
  （`final_gates.sh` 头部已有同样的告诫）。
