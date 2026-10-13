# 服务端 TLS：渲染形状、链与 SNI 的实测口径（e2e_tls_chain）

被测对象 = `docker-entrypoint.sh` 渲染出的 TLS 主监听。门禁文件
`test/integration/e2e_tls_chain.py`（`GATE_ONLY=e2e_tls_chain` 可单跑，期望 checks 数打印在收尾行）。
门禁不改实现：两个真实缺口只记录不修（§5、§6）。

## 1. 开关与渲染形状

`SMG_TLS_CERT_PATH` + `SMG_TLS_KEY_PATH` 成对出现且两个文件都非空，否则入口 `exit 1`
（"must be set together" / "certificate or key missing"）。渲染结果：主监听就地加密
（`listen <addr> ssl`），即 TLS **替换**明文监听，不在旁边开第二个端口；渲染进主 `server{}` 的是

```
ssl_certificate     <SMG_TLS_CERT_PATH>;
ssl_certificate_key <SMG_TLS_KEY_PATH>;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_session_cache shared:LR_TLS:10m;
ssl_session_timeout 10m;
```

启动横幅报 `tls: on (TLSv1.2/1.3)`。**独立 metrics 监听保持明文**（TLS scrape 自行加反代）。
TLSv1.1 拿不到任何响应；明文 http 打到 TLS 端口不被服务。ALPN 未协商（`ssl_alpn`/`http2`
都没渲染，尽管镜像编译了 `--with-http_v2_module`）。

入口只渲染**一对**证书。多证书用既有 `LR_HTTP_INCLUDE` 片段注入额外 `server{}`（不动核心）。
镜像里的 OpenResty 1.31.1.1（nginx 核心 1.31.1 ≥ 1.25.10）支持一个 `server{}` 写多对
`ssl_certificate`/`ssl_certificate_key`，但那是**按客户端 signature_algorithms 选证**、不是按
hostname 选证；按名字选证要多个 `server{}`。`ssl_certificate2` 指令不存在（`openresty -t`
直接 unknown directive）。该形态入口脚本渲染不出，属片段层能力，未进断言。

## 2. 链与握手实测

PKI 由门禁现场生成（根 RSA-3072 → 中间 ECDSA P-384（CA:TRUE pathlen:0）→ 各 leaf，SAN 同时带
DNS 与 IP；过期件走 `openssl ca` 的 `default_startdate/default_enddate`），落
`/data/tmp/lr/tls-chain-<pid5>/`，只读挂进容器。客户端信任库分两份：只给根（证明中间证书是
服务器发的）、根+中间（负例用，把「链不完整」从变量里剔除）。链完整性先离线自证：leaf 单独 +
根必须验不过，leaf+中间+根必须验得过。「服务器发全链」的证据 = 深度 2 **且**只信根 ok 同时成立。

四类负例（同一实例、同一信任库，只有被测那一项不同；每个负例都用匹配自身 SAN 的主机名访问，
所以拒绝不可能是主机名失败伪装）：curl rc 一律 60，`-k` 一律 200，容器全程存活无崩溃行。

| 类别 | curl / python 报的原因 | `s_client` verify code |
|---|---|---|
| 过期 leaf | `certificate has expired` | 10 |
| 非信任链（rogue 根签） | `unable to get local issuer certificate` | 21 |
| 签发者 CA:FALSE | `invalid ca certificate` | 32（keyUsage 不含签发位） |
| 自签无 CA | `self-signed certificate` | 18 |
| 主机名/SAN 不匹配 | `no alternative certificate subject name matches target host name` | 链单独 0；`-verify_hostname` 后 62 |

四类都额外验「被拒的 leaf 确实完整发出（指纹匹配）」——失败发生在客户端，服务器没有半途断流。
主机名类是唯一「证书本身没问题」的，必须 `-verify_hostname/-verify_return_error` 才看得见拒绝。
有 SAN 时 CN 被忽略；无 SAN 时 OpenSSL 3 回落 CN 接受（浏览器与 Go 会拒，属**客户端相关**行为，
门禁记 NOTE 不记失败）。

密钥类型 × 协议（python `ssl` 与 openssl CLI 双向一致）：TLSv1.3 恒 `TLS_AES_256_GCM_SHA384`
（套件名不体现签名算法），TLSv1.2 下 RSA leaf → `ECDHE-RSA-AES256-GCM-SHA384`、
ECDSA leaf → `ECDHE-ECDSA-AES256-GCM-SHA384`。**密钥类型的断言必须打在 TLSv1.2 上**。

SNI（`LR_HTTP_INCLUDE` 注入第二个 `server{}`，两域名两对证书，同端口）：SNI 匹配 → 对应 leaf
（指纹判定）；未匹配 SNI 与无 SNI → 默认 server 的证书；两个名字背后是同一个 router 进程状态
（用别名注册的 worker 在主名的 `/workers` 可见）；TLSv1.2 下两名的套件族各自跟着自己的密钥类型。

## 3. mTLS 的实际形态

服务器不发客户端 CA 名单（`s_client` 输出 `No client certificate CA names sent`），带客户端证书
握手仍然 200（证书被忽略）。**当前只有服务端单向 TLS**；门禁只把「没有 mTLS」钉成断言，不实现。

## 4. 门禁覆盖面形状

一轮起 11 个 TLS 实例（RSA leaf / ECDSA leaf / SNI 双证书 / 四类负例 / wronghost / cnbutsan /
nosan / pairing）加 3 次一次性 `openresty -t`，全部由门禁自己收尾。PKI 现场生成、只读挂进容器，
绿的一侧连目录一起删。断言组：离线 PKI 自证、渲染断言（`listen ... ssl` + fullchain 路径 +
横幅）、链深度与指纹、四类负例各自的客户端判词、RSA/ECDSA × TLSv1.2/1.3 套件族、SNI 选证、
入口渲染失败两例、pairing 形态、收尾稳定性（全部实例仍在跑、全程无 `[emerg]`/signal/lua aborted）。

## 5. 缺口一：证书与私钥不配对，入口抓不住（记录，未修）

A 的证书配 B 的私钥：`openresty -t` **通过**（nginx 加载时不做配对校验）→ 容器正常启动、端口
正常监听 → **每次握手都死**（客户端 TLS alert 40 handshake failure）→ 默认 `warn` 级别看不到原因，
`SMG_LOG_LEVEL=info` 才有 `SSL_do_handshake() failed ... no suitable signature algorithm`。
不崩溃（无 `[emerg]`、无 signal、worker 不退）：fail-closed，不是 fail-fast。

入口现有检查只有「两个变量都给 + 两个文件非空」，抓不到这件事。补它需要 openssl 能力，而
`authz:latest` / `lua-router:integration` 镜像里**没有 openssl**（实测 command not found），
可选路线：Lua 侧 `resty.openssl`、镜像内 vendored 静态 openssl、或健康检查带一次真实握手。
三条都是核心改动。门禁的 `[pairing]` 段把当前形态钉住：将来入口加了预检，这几项会立刻变红提醒更新本文。

## 6. 缺口二：入口不检查链是否完整（记录，未修）

`ssl_certificate` 指向只含 leaf 的文件时，`-t` 同样通过、同样监听、同样横幅 `tls: on`，
但只有信任库里恰好有中间证书的客户端能连上。入口对「证书形状」毫无判断（拿 CA 证书当服务器
证书照样渲染）。门禁量化了这条风险（只信根必须验得过 + leaf 单独离线必须验不过），要主动拒绝
仍需 §5 的 openssl 能力。

## 7. 未覆盖 / 限制

- TLS 参数不可调：`ssl_protocols`、`ssl_prefer_server_ciphers`、session cache 全硬编码在
  `docker-entrypoint.sh`，没有 `SMG_TLS_*` 旋钮，因此没有「改配置生效」的断言；
- OCSP stapling、`ssl_trusted_certificate`、client CA bundle、证书热更新（`nginx -s reload`
  换证）均未覆盖；metrics 监听明文面本门禁不测；
- `config_store` 的 lua-resty-http 快路径固定 `ssl_verify = false`（`config_store/httpc.lua`，
  自签上游握手需要）；
- §5/§6 是记录性缺口：断言的是「当前 fail-closed」，不是「被正确拦住」；
- 门禁跑法：`--network host` + 随机端口，与其他容器化套件并发跑时墙钟时间翻倍；绿的一侧连
  PKI 目录一起删，失败时保留 `/data/tmp/lr/tls-chain-<pid5>/` 供验尸；容器名
  `lr-tlsc-<tag>-<pid5>`，只按名字 `docker rm -f`。

## 8. 写这类测试要知道的 openssl 事实（避免口述返工）

- `-nameopt` 取值是 `UTF8`；写成 `UTF-8` 会让 `openssl x509` 打 usage 并非 0 退出。脚本若只取
  stdout 且不断言，指纹变空串，「SNI 选对证书」这类断言会空对空通过。本门禁的 `fingerprint()`
  取不到就直接抛异常，不返回 `""`。
- `openssl x509 -checkhost` **匹配与不匹配都返回 0**，结论只在文本里；判 rc 一律「全通过」。
- `openssl verify` 的失败详情走 **stderr**，`x509 -text` 走 stdout：负向离线断言统一读 out+err。
- `openssl req` 没有 `-extfile`，自签要逐行 `-addext`；`x509 -req -days` 推不到过去，
  过期件必须走 `openssl ca` 的日期对。
- nginx 只认 `TLSv1.2`，写 `TLS1.2` 直接 `-t` 失败。
