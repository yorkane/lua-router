# 21.k:8800 生产升级——代理来源前置否决（2026-10-12，用户授权推生产）

镜像：`pub/lua-router:20261012-b5130da` → `pub/lua-router:20261012-69b5d53`
（同一 digest 先在 8802 测试实例验证；full 门禁 22/0/0，日志 /data/tmp/lr-gates/gates-20261012-160634.log）。
旧镜像 tag `8800-20261011-89f0ad0` 保留在 ACR 与 21.k 本机，回滚一条 sed 即可。

## 变更内容

- compose：镜像行替换 + **新增 `SMG_ADMIN_AUTH_PASS`**（值不落文档；本轮为临时测试口令，操作员后续在 compose 里换成正式口令并 `docker compose up -d`）。
- 其余 env 逐字未动：`SMG_MAX_TREE_SIZE: 1e8`、watcher DENY_PORT、prom 载荷通道、LR_HTTP_INCLUDE 全部保留。
- 部署位置：21.k host 网络，`/data1/app/lua-router-8800/docker-compose.yml`，容器 `lua-router-8800`。

## 备份（切换前）

- 目录 `/data1/app/lua-router-8800/backup-20261012T163349Z/`：compose + config 全量（runtime.json md5 c0db6a3a…，rev `44 10504bd6`）。
- SQLite 在线一致性快照 `runtime.sqlite-online`（Python sqlite3 Connection.backup() 从 WAL 活动库导出，integrity ok，lr_config_snapshot 1 行）。
- 切换后 rev 仍是 `44 10504bd6`（配置零漂移）；`lr_config_store_backend{backend="sqlite"} == 1`（验证的是 db 权威路径，不是文件降级）。

## 真机验收矩阵（全部实测）

| 项 | 期望 | 实测 |
|---|---|---|
| APISIX 域名 `https://8800-248.ai-t.wtvdev.com/config` 无凭据 | 401 | 401 |
| 同域伪造 `X-Real-IP: 127.0.0.1` 无凭据（v1 绕过面） | 401 | 401 |
| 同域伪造 `X-Forwarded-For: 127.0.0.1` 无凭据 | 401 | 401 |
| 同域 `X-Forwarded-Proto: https` 单头 | 不属名单，401 来自无凭据 | 401 |
| 同域带凭据 /config、/workers | 200 | 200 / 200 |
| 同域错误口令 | 401 | 401 |
| 同域 `OPTIONS /config` 预检 | 200（不过门） | 200 |
| 公网边缘 `https://8800-248.ws.gatepro.cn:99`（操作员实际入口）anon /config | 401 | 401 |
| 同边缘带凭据 /config、/workers；badpw；伪造 XRI | 200/200/401/401 | 200/200/401/401 |
| 21.k 直连 loopback 无代理头 /config | 200（豁免不变） | 200 |
| 直连 loopback 自带伪造 `X-Real-IP: 127.0.0.1` | 401（修复目的达成） | 401 |
| 直连 loopback 仅 `X-Forwarded-Proto` | 200（名单外不误触） | 200 |
| `/health` `/v1/models` `/u/` `/props` 匿名 | 200（数据面/匿名面不缩水） | 200 |
| `POST /v1/chat/completions` swift-1.5-plefp8 | 200 | 200 |
| /v1/models 形状 | 官方四字段齐、owned_by 恒 lua-router、入口 created=0 | n=4 全符合 |
| worker 恢复 | 8/8 healthy | 8 healthy / total 8 |
| 日志 | 无 [crit/emerg/alert]；error 仅探针 keepalive reset（升级前同形） | 达标 |

## 回滚（已写入本节即回滚手册）

```bash
cd /data1/app/lua-router-8800
sed -i 's#pub/lua-router:20261012-69b5d53#pub/lua-router:8800-20261011-89f0ad0#' docker-compose.yml
# 同时删掉 SMG_ADMIN_AUTH_PASS 行（旧镜像无此功能，留着无害但按原样回滚）：
sed -i '/SMG_ADMIN_AUTH_PASS/d' docker-compose.yml
docker compose up -d
docker inspect lua-router-8800 --format '{{.Config.Image}}'   # 确认
```

配置 db 无需回滚：升级窗口内无任何配置写操作（rev 前后一致 44 10504bd6）；万一需要，用备份目录里的
`runtime.sqlite-online`（integrity ok）覆盖 `config/runtime.json.db*` 三件套后重建容器。

## 说明

- 8800 与 8802 的差异（310+ worker 发现、DENY_PORT、cache_aware 定尺、无测试桩）逐项未动；
- 生产域名链路实测：APISIX 在来源侧写 `X-Real-IP`/`X-Forwarded-For`（8800 经 `8800-248.ai-t.wtvdev.com`
  与公网 `ws.gatepro.cn:99` 两入口取证），即旧版 loopback 豁免在生产反代下确实被无条件触发——
  这就是本次前置否决在生产要堵的洞，验收矩阵第 2/3 行即核心证据；
- 直连 217.t→21.k:8800 的 LAN 匿名 /config 未测（防火墙面未探测）；数据面 LAN 转发正常。
