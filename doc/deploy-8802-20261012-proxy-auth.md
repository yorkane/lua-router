# 21.k:8802 部署验证报告——代理来源前置否决（2026-10-12）

锚点与发布物：
- 代码：`69b5d53`（fix(auth): 代理来源头前置否决按「出现即认证」实现），已推送 origin/main。
- 全量门禁：`GATE_TIER=full GATE_JOBS=6` **22 passed / 0 failed / 0 skipped**（SKIP_ENV=none），
  日志 `/data/tmp/gate_full_proxyv2.log`，归档 `/data/tmp/lr-gates/gates-20261012-160634.log`，
  per-gate 目录 `/data/tmp/lr-gates/per-gate-20261012-160634`。单测 admin_auth 191 checks / 0 failed。
- 镜像：`wasu-wtvdev-registry-test-registry.cn-hangzhou.cr.aliyuncs.com/pub/lua-router:20261012-69b5d53`
  （digest sha256:f952ee507dd9…，manifest inspect 通过；构建脚本 `script/build-image.sh`，随 146828b 入库）。
- 部署：21.k `/data1/app/lua-router-8802/docker-compose.yml` 镜像行 `20261012-b5130da -> 20261012-69b5d53`，
  `docker compose pull && up -d`；容器 `lua-router-8802` Up，inspect 镜像与新 tag 一致。
  生产（21.k:8800 / 8801 / 本机 8800）未做任何改动。

真机验证矩阵（部署后，全部实测）：

| 项 | 期望 | 实测 |
|---|---|---|
| 域名 `https://8802-248.ai-t.wtvdev.com/config` 无凭据 | 401 | 401 |
| 域名 `/config` 带 `lua-router:test123` | 200 | 200 |
| 域名 `/config` 错误口令 | 401 | 401 |
| 域名伪造 `X-Real-IP: 127.0.0.1` 无凭据（v1 绕过面） | 401 | 401 |
| 域名伪造 `X-Forwarded-For: 127.0.0.1` 无凭据 | 401 | 401 |
| 域名 `X-Forwarded-Proto: https` 无凭据 | 401（该头不在名单，401 来自无凭据本身） | 401 |
| 域名 `/u/` 对话面 无凭据 | 200（不在覆盖清单） | 200 |
| 域名 `/v1/models` 无凭据 | 200 | 200 |
| 21.k 直连 `127.0.0.1:8802/config` 无代理头无凭据 | 200（loopback 豁免不变） | 200 |
| 21.k 直连 loopback 自带伪造 `X-Real-IP: 127.0.0.1` | 401（修复目的达成） | 401 |
| 21.k 直连 loopback 带凭据 | 200 | 200 |
| 8801（未配 `SMG_ADMIN_AUTH_PASS`）带伪造来源头无凭据 | 200（缺省零行为变化，代理头不擅自开门） | 200 |
| 8802 数据面 `POST /v1/chat/completions` | 200 | 200（swift-1.5-plefp8 正常回包，usage 完整） |
| `/health` | 200 | 200 |

浏览器验证（playwright-cli，无头 Chromium）：
- 带凭据打开域名：管理台正常渲染（模型管理 / 服务池 / 路由策略 / 日志监控四页齐全），
  截图 `/data/tmp/lr8802_admin.png`。
- 无凭据打开域名：`ERR_INVALID_AUTH_CREDENTIALS`（401 挑战到达浏览器；无头环境无法弹框输凭据）。
- 已知现象（非网关缺陷）：凭据内嵌在页面 URL 时，页面内相对 `fetch("/config")` 被浏览器拒绝
  （"Request cannot be constructed from a URL that includes credentials"），侧栏显示「网关不可达」；
  curl `-u` 与浏览器弹框输凭据两个正常路径均 200。

结论：v2「出现即认证」在 8802 测试环境达成修复目标——反代同机时 loopback 豁免不再被无条件触发，
伪造 loopback 来源头拿不到豁免；豁免面（直连 loopback、未配口令实例、数据面、匿名只读面）逐项确认未缩水。
