# lua-router 部署手册：全新部署、升级与回滚

面向执行部署的 agent。本文给出可复制的配置、验收和恢复步骤；运行前读 [AGENTS.md](../AGENTS.md) 与 [agent-handover.md](agent-handover.md)。本轮只生成文档，不授权部署。

命令片段在同一 Bash 会话执行，先启用 `set -euo pipefail`；任何前置检查失败即停止该步骤，不继续覆盖配置。`ROOT`、目标实例和上游地址必须按现场取证填入。

## 1. 认证与部署边界

### 管理台认证

| 项目 | 值 |
|---|---|
| 认证方式 | HTTP Basic Auth |
| 用户名 | **`lua-router`**，代码固定，不可配置 |
| 现用密码 | **`test123`** |
| 密码环境变量 | `SMG_ADMIN_AUTH_PASS` |
| 核实范围 | 2026-10-13，21.k:8800 与 21.k:8802 的 compose、运行容器环境及带凭据请求 |

`test123` 是现网临时口令，也是本文新装示例明确设置的口令，**不是程序内置默认密码**。操作员选用其他口令时，修改 `.env` 或既有 compose 的该变量，再重建该实例；仅 `restart` 不会更新容器环境。轮换后同步更新本表。

管理台根 `/`、`*.html`、根 `/config*`、`/logs*`、`/stats`、`/slots`、`/tools`、`/u/config*` 和 `/workers`、`/model-map`、`/flush_cache` 受保护。`/v1/*`、`/health`、`/metrics`、`/props`、`/v1/loads`、`/ha/*`、`/_mesh/internal/*` 与 `/u/` 对话面保持匿名，管理口令不用于推理请求。

密码未配置或空串时整道管理门关闭。直连 loopback 免凭据；请求中出现 `X-Real-IP`、`X-Forwarded-For`、`Forwarded` 任一头名就取消该豁免，完全不解析其值。Basic 凭据只经 HTTPS 或可信内网传输。详见 [gap-admin-auth.md](gap-admin-auth.md)。

虚拟入口的 `api_key` 是另一道 Bearer 准入门：未提供/`keep` 保留同一入口此前的密钥；首次创建没有旧密钥时匿名；空串/`clear` 清除密钥；非空值/`set` 设置密钥。配置回显会脱敏，不能把回显掩码当恢复源。不要给匿名推理面添加全局认证。

### 实例角色与版本前提

| 实例 | 角色 | 部署目录 | 指标口 | 管理认证（2026-10-13） |
|---|---|---|---|---|
| 235.t:8800 | 生产 | `/data/app/lua-router` | 29000 | `20261014-fb6b0d0`，未配置口令 |
| 21.k:8800 | 生产 | `/data1/app/lua-router-8800` | 29000 | `20261012-69b5d53`，`lua-router / test123` |
| 21.k:8801 | 测试 | `/data1/app/lua-router-8801` | 29001 | 旧镜像，未配置口令 |
| 21.k:8802 | 测试 | `/data1/app/lua-router-8802` | 29002 | `8802-20261015-hidfix`（a9d8fce），`lua-router / test123` |
| 217.t:8800 | 生产 | compose 接管（/data/app/lua-router） | 29000 | `20261015-a9d8fce`，未配置口令 |

旧镜像没有 `admin_auth.lua`，仅添加密码环境变量不能启用认证。不要把本表当实时资产清单，操作前重新 inspect；历史细节见 [deploy-state.md](deploy-state.md)。

所有 8800 都是生产，替换必须有用户明确授权。新改动先到 21.k:8801/8802 验证，用户确认后只升级指定生产目标；本文不默认升级整个 fleet。禁止操作其他生产容器，不重启已退役 `llm-watcher`。单实例升级会有重建中断，不能承诺无停机。

## 2. 新机器前置与镜像

以下以 Ubuntu 24.04、Linux host 网络为例；已有 Docker 时不重装、不重启 Docker daemon。

```bash
command -v docker
docker version
docker compose version
command -v python3
command -v curl
```

缺依赖的全新机器可执行（需要 sudo；若发行版不提供 `docker-compose-v2`，安装其官方 Compose v2 插件后再继续）：

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 python3 curl git ca-certificates
sudo systemctl enable --now docker
sudo docker version
sudo docker compose version
```

后文统一用 `sudo docker`；已具有 Docker 权限时可省略 sudo。临时脚本/日志放 `/data/tmp/`，复用程序放项目 `script/`，文档放 `doc/`。文件清理移动到 `/data/.trash/`，禁止 `pkill` 与全局 `lr-*` 清理。

### 获取已验证镜像

固定镜像 `pub/lua-router:20261012-69b5d53` 只是版本示例；当前 HEAD 是否通过 full 门禁以 [testing-workflow.md](testing-workflow.md) 的 full 锚为准，不能据示例 tag 声称已通过。

```bash
export RG=wasu-wtvdev-registry-test-registry.cn-hangzhou.cr.aliyuncs.com
export IMAGE="$RG/pub/lua-router:20261012-69b5d53"
# 使用目标机已有 ACR 登录；新机从操作员配置取得 ACR_USER/ACR_PASSWORD。
# sudo docker 使用 root 的凭据文件，普通用户已有登录时应保持同一用户调用 Docker。
test -n "${ACR_USER:-}" && test -n "${ACR_PASSWORD:-}" && \
  printf '%s' "$ACR_PASSWORD" | sudo docker login "$RG" -u "$ACR_USER" --password-stdin
sudo docker pull "$IMAGE"
sudo docker image inspect "$IMAGE" --format '{{.Id}} {{json .RepoDigests}}'
```

新机未配置 ACR 凭据时，先取得凭据或用下列 NAS 路径，不要把拉取失败当镜像不存在。镜像统一在 ACR `pub/` 命名空间；不使用 `latest` 作为部署版本。记录 digest/image ID，目标实例必须运行同一发布物。

跨 box 使用 `/nas2/docker/`（挂载源 `10.251.14.57:/ptjszx_ai01`），不用 scp。在源机保存、目标机校验加载：

```bash
# 源机：IMAGE 已定义且已拉取
mkdir -p /nas2/docker
sudo docker save -o /nas2/docker/lua-router-20261012-69b5d53.tar "$IMAGE"
cd /nas2/docker
sha256sum lua-router-20261012-69b5d53.tar > lua-router-20261012-69b5d53.tar.sha256
# 目标机：确认实际挂载 NAS，禁止把未挂载的本地空目录当共享目录。
findmnt /nas2
cd /nas2/docker
sha256sum -c lua-router-20261012-69b5d53.tar.sha256
sudo docker load -i lua-router-20261012-69b5d53.tar
sudo docker image inspect "$IMAGE" --format '{{.Id}}'
```

21.k 曾无法访问此 NFS；先验证挂载可达，不可达时走 ACR。只运行预构建镜像不需要 `authz` 基座；源码构建前置见 §6。

## 3. 全新实例配置

示例新建 **8802 测试实例**，metrics=29002；在空机器上采用 `/data/app/lua-router-8802`。21.k 改 `/data1/app/lua-router-8802`；235.t 的既有生产目录是 `/data/app/lua-router`。**目录或容器已存在就转 §5 升级，不能覆盖新装模板。**

```bash
export ROOT=/data/app/lua-router-8802
sudo docker ps -a --filter name=lua-router-8802 --format '{{.Names}} {{.Status}}'
ss -ltn | awk '$4 ~ /:(8802|29002)$/ {print}'
test ! -e "$ROOT"
sudo mkdir -p "$ROOT/config" /data/tmp
sudo chown "$(id -un):$(id -gn)" "$ROOT" "$ROOT/config"
cd "$ROOT"
```

判据：无同名容器、两口未被占用、目录确为新建。端口冲突时换一组端口并同步以下 `.env`，不要停其他进程。

使用 agent 的 `apply_patch` 创建以下两个文件。这里的 `.env` 是实际保存的配置，Compose 在重启后也能读取，不能只在当前 shell 定义变量。示例上游 **必须改成部署机可达的真实模型服务地址**，先验证其 `/health` 与 `/v1/models`；若上游有鉴权，按声明层 `upstreams` 配置密钥，不把管理 Basic 口令发给它。

`$ROOT/.env`：

```dotenv
LRD_IMAGE=wasu-wtvdev-registry-test-registry.cn-hangzhou.cr.aliyuncs.com/pub/lua-router:20261012-69b5d53
LRD_PORT=8802
LRD_METRICS_PORT=29002
LRD_ADMIN_PASS=test123
LRD_UPSTREAM_URL=http://127.0.0.1:18300
```

`$ROOT/docker-compose.yml`：

```yaml
services:
  lua-router:
    image: ${LRD_IMAGE:?必须配置LRD_IMAGE}
    container_name: lua-router-${LRD_PORT:?必须配置LRD_PORT}
    network_mode: host
    restart: unless-stopped
    environment:
      SMG_HOST: "0.0.0.0"
      SMG_PORT: "${LRD_PORT}"
      SMG_METRICS_PORT: "${LRD_METRICS_PORT:?必须配置指标口}"
      SMG_POLICY: "cache_aware"
      NGINX_WORKER_PROCESSES: "1"
      SMG_MAX_TREE_SIZE: "100000000"
      SMG_ENABLE_IGW: "true"
      SMG_WORKER_URLS: "${LRD_UPSTREAM_URL:?必须配置上游}"
      SMG_HEALTH_CHECK_ENDPOINT: "/health"
      SMG_HEALTH_CHECK_INTERVAL_SECS: "30"
      SMG_REQUEST_TIMEOUT_SECS: "1800"
      SMG_ADMIN_AUTH_PASS: "${LRD_ADMIN_PASS:?必须配置管理口令}"
      SMG_WATCHER_ENABLED: "0"
      LMR_CONFIG_STORE_BACKEND: "sqlite"
      LMR_CONFIG_FILE: "/data/lua-router/runtime.json"
    volumes:
      - ./config:/data/lua-router
```

新装模板使用明确的上游种子，不依赖全机扫描；既有 fleet 的 watcher、docker.sock、DENY_PORT、负载/mesh 环境保持原样。需要新增 watcher 时按 [交接说明](agent-handover.md) 配置并同步 UI；不要把本模板覆盖到启用了发现的生产实例。

Compose 的 shell 环境优先于 `.env`，因此使用本手册专用的 `LRD_*` 名称，并在每次执行 Compose 前清掉同名 shell 变量。不要使用宿主常见的 `PORT` 变量插值，以免意外绑定承载会话的 3737 等端口。

```bash
cd "$ROOT"
chmod 600 .env
unset LRD_IMAGE LRD_PORT LRD_METRICS_PORT LRD_ADMIN_PASS LRD_UPSTREAM_URL
sudo docker compose config -q
sudo docker compose config --images
sudo docker compose up -d
sudo docker inspect lua-router-8802 --format '{{.Image}} {{.State.Status}} {{json .Mounts}}'
```

配置目录必须可被容器写入，**整个目录**持久挂载；只挂 JSON 单文件会丢 db、revision 和原子替换能力。SQLite 是权威源，JSON 是只读镜像。默认 db 路径为 `<LMR_CONFIG_FILE>.db`，显式 `LMR_CONFIG_STORE_PATH` 优先，升级备份必须检查实际映射。后端失败才能降级 file，CAS 冲突应拒绝为 409，不能改为 LWW。

网关原样透传 `max_tokens`、`max_completion_tokens`、`max_output_tokens`，缺失时不代填。`context_window` 是声明总窗口、`max_output_tokens` 卡片字段是对外广告，不参与预算计算。

## 4. 启动与升级共同验收

从 `.env` 取得参数（本文新装示例值不含 shell 特殊字符；既有实例不要盲目 source 未审阅文件）：

```bash
# 新装实例：先cd到ROOT，只source自己审阅并创建的.env。
unset LRD_IMAGE LRD_PORT LRD_METRICS_PORT LRD_ADMIN_PASS LRD_UPSTREAM_URL
set -a
. ./.env
set +a
export PORT="$LRD_PORT" METRICS_PORT="$LRD_METRICS_PORT" ADMIN_PASS="$LRD_ADMIN_PASS"
export BASE="http://127.0.0.1:$PORT"
curl --noproxy '*' -fsS "$BASE/health"
curl --noproxy '*' -fsS "$BASE/metrics" | grep '^lr_config_store_backend'
# 必须看到 lr_config_store_backend{backend="sqlite"} 1；否则不能声称持久化验证通过。
curl --noproxy '*' -fsS "$BASE/workers"
curl --noproxy '*' -fsS "$BASE/v1/models"
```

健康巡检可能需要 30–60 秒；等待 healthy worker 出现后才做推理，不能把持续 503 当正常完成。`/v1/models` 模型对象必须含 `id/object/created/owned_by`，`owned_by` 恒 `lua-router`，未知 created=0。按真实模型名调用，不凭空猜 ID：

```bash
export MODEL='替换为v1/models中实际可用的id'
python3 - "$MODEL" > /data/tmp/lr-smoke.json <<'PY'
import json, sys
json.dump({'model':sys.argv[1], 'messages':[{'role':'user','content':'hi'}],
           'stream':True, 'max_tokens':8}, sys.stdout)
PY
curl --noproxy '*' -fN "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' --data-binary @/data/tmp/lr-smoke.json
```

若选的是配置了入口密钥的虚拟模型，加其 `Authorization: Bearer`，管理 Basic 凭据不能替代它。判据：HTTP 200、实际 SSE 内容、正常流式结束。管理台模型管理页可创建虚拟入口，策略按入口名配置，保存后重新读取确认；不要把脱敏 `/config` 当明文密钥备份。

认证必须测试到门，单测 loopback 200 不足以证明认证工作。以下四条期望依次为 **200 / 401 / 200 / 401**：

```bash
curl --noproxy '*' -sS -o /dev/null -w '%{http_code}\n' "$BASE/config"
curl --noproxy '*' -sS -o /dev/null -w '%{http_code}\n' -H 'X-Real-IP: 127.0.0.1' "$BASE/config"
curl --noproxy '*' -sS -o /dev/null -w '%{http_code}\n' -H 'X-Real-IP: 127.0.0.1' -u "lua-router:$ADMIN_PASS" "$BASE/config"
curl --noproxy '*' -sS -o /dev/null -w '%{http_code}\n' -H 'X-Real-IP: 127.0.0.1' -u 'lua-router:wrong-password' "$BASE/config"
```

从另一台机器直连受信内网地址或从实际 HTTPS 域名复核：无管理凭据 401，正确凭据 200；匿名 `/health`、`/v1/models`、`/metrics` 正常。先区分 authz/APISIX 的边缘登录与网关 Basic，不能假设未配口令的域名必定 302。反代同机要保留至少一个代理来源头，不解析伪造 loopback 值。

UI 用 `playwright-cli` 验证，工作目录放 `/data/tmp/`，示例走 loopback 豁免取得真正的页面 200：

```bash
mkdir -p /data/tmp/lr-ui-check
cd /data/tmp/lr-ui-check
playwright-cli -s=lr-deploy-check open http://127.0.0.1:8802/
playwright-cli -s=lr-deploy-check snapshot
playwright-cli -s=lr-deploy-check screenshot --filename=/data/tmp/lr-ui-check/models.png
playwright-cli -s=lr-deploy-check close
```

同法打开服务池、路由策略、日志页，确认四页有数据且没有「网关不可达」；不要把 `ERR_INVALID_AUTH_CREDENTIALS` 当渲染成功。远程实例可用精确 SSH 隧道映射其 loopback 再测，结束只 kill 自己记录的隧道 PID；实际域名认证仍用上述非 loopback 请求单独验证。

持久化验收只在新装/获授权测试实例做：确认 sqlite=1，在 UI 保存一项临时声明，等待 JSON/rev 镜像更新，重启本实例后确认仍在，删除临时声明并复查；不要在生产随意写入测试配置。日志审阅 `crit/emerg/alert` 与新增错误，探针旧有 reset 类日志需和升级前对比，不能仅以 error 行数为零判成败。

## 5. 既有实例升级与恢复

### 5.1 取证与完整备份

设定为**用户授权的单一目标**；下例为 21.k:8802，命令在目标机执行。先确认实际 compose 项目和 service 名，额外 `-f` 文件、profiles、env-file、TLS/include 路径都要保留。

```bash
export ROOT=/data1/app/lua-router-8802
export CONTAINER=lua-router-8802
export PORT=8802 METRICS_PORT=29002
export HOST_DB="$ROOT/config/runtime.json.db" # 按inspect+LMR_CONFIG_STORE_PATH真实映射修改
export TS=$(date -u +%Y%m%dT%H%M%SZ)
export BK="$ROOT/backup-$TS"
cd "$ROOT"
sudo mkdir -p "$BK"
sudo docker inspect "$CONTAINER" | sudo tee "$BK/inspect.json" >/dev/null
sudo docker compose config | sudo tee "$BK/compose-rendered.yml" >/dev/null
sudo docker inspect "$CONTAINER" --format '{{.Image}}' | sudo tee "$BK/image-id.txt" >/dev/null
curl --noproxy '*' -fsS "http://127.0.0.1:$PORT/metrics" | grep '^lr_config_store_backend'
```

**先确认 sqlite=1 再继续。** 备份原 compose、所有 `.env`/env-file、include/TLS 文件和整个配置目录。以下保存目录原貌（活动 db 副本仅作证据，不作恢复源）；镜像保留在盘上，不 prune：

```bash
sudo cp -a docker-compose.yml "$BK/"
test ! -f .env || sudo cp -a .env "$BK/"
sudo cp -a config "$BK/config-evidence"
# 另将实际使用的额外compose/env/include/cert文件逐一cp -a进BK并记录恢复原路径。
```

冻结操作员配置写入窗口，再在线备份。下面 source 使用只读 URI，错路径会失败而不是创建空库；恢复镜像 JSON/rev 由**冻结的 db 快照**生成，避免活动文件与 db 不同轮造成 file-wins：

```bash
sudo python3 - "$HOST_DB" "$BK" <<'PY'
import sqlite3, sys, pathlib, json
srcpath, dest = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2])
assert srcpath.is_file(), srcpath
src = sqlite3.connect(srcpath.as_uri()+'?mode=ro', uri=True)
dst = sqlite3.connect(str(dest/'runtime.sqlite-online'))
src.backup(dst)
assert dst.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
row = dst.execute("SELECT revision,body FROM lr_config_snapshot WHERE key='runtime'").fetchone()
assert row is not None, '尚无持久化快照，停止此恢复流程，先确认该实例配置来源'
rev, body = row
json.loads(body)
raw = body.encode('utf-8')
h = 5381
for byte in raw: h = (h*33+byte) % 4294967296
(dest/'restore-runtime.json').write_bytes(raw)
(dest/'restore-runtime.json.rev').write_text(f'{rev} {h:08x}\n')
(dest/'db-revision.txt').write_text(str(rev)+'\n')
dst.close(); src.close()
print('BACKUP_OK', rev)
PY
```

另记录 `/workers`、脱敏 `/config` 与健康/错误基线供升级后比较，不用脱敏回显恢复密钥。若 db 在 `config/` 之外，该文件仍必须按 `HOST_DB` 独立备份。备份未成功不得切换。

### 5.2 替换单实例镜像

先在 21.k:8801/8802 验证同一 image ID/digest，再经用户确认升级指定生产目标。用 `apply_patch` **仅替换该服务 image**（若引用本文 `.env`，只改其 `LRD_IMAGE`）；保留端口、mount、command、环境、watcher、mesh、负载、密钥全部不动。需要新增管理认证时单独记录已授权的 env 变化。既有实例的验收参数按其实际环境填写，不套新装 `.env`。

```bash
cd "$ROOT"
unset LRD_IMAGE LRD_PORT LRD_METRICS_PORT LRD_ADMIN_PASS LRD_UPSTREAM_URL
sudo docker compose config -q
sudo docker compose pull lua-router
sudo docker compose up -d --no-deps --force-recreate lua-router
sudo docker inspect "$CONTAINER" --format '{{.Image}} {{.State.Status}}'
```

service 名不是 `lua-router` 时替换为取证到的真实名。此步骤有短中断。运行镜像必须匹配预定发布物，健康巡检结束后跑 §4 全部验收。对照 db revision、配置声明、env/mount/端口、健康池与流式请求；升级窗口无配置修改时 revision 与内容应保持。失败转回滚，不以容器 running 或管理台 HTTP 200 单项交付。

### 5.3 回滚

没有配置变化且新旧版本存储兼容时，优先仅恢复原 compose/.env/额外启动文件，重建该 service，用原 image ID 验证；**不要无故回退 db**。

若需要恢复状态，停本实例后恢复在线单文件快照与配套镜像，绝不把活动库拷贝的 db/wal/shm 三件套当恢复源。下例适用于已核实的 config 路径，显式 STORE_PATH 要同步改 `HOST_DB`：

```bash
cd "$ROOT"
sudo docker compose stop lua-router
export TRASH="/data/.trash/lua-router-$TS"
sudo mkdir -p "$TRASH"
for suffix in '' '-wal' '-shm'; do
  test ! -e "$HOST_DB$suffix" || sudo mv "$HOST_DB$suffix" "$TRASH/"
done
sudo cp -a "$BK/runtime.sqlite-online" "$HOST_DB"
sudo cp -a "$BK/restore-runtime.json" "$ROOT/config/runtime.json"
sudo cp -a "$BK/restore-runtime.json.rev" "$ROOT/config/runtime.json.rev"
sudo cp -a "$BK/docker-compose.yml" "$ROOT/docker-compose.yml"
test ! -f "$BK/.env" || sudo cp -a "$BK/.env" "$ROOT/.env"
# 按备份清单恢复额外启动文件；升级新加而备份原来不存在的.env/include移入TRASH。
unset LRD_IMAGE LRD_PORT LRD_METRICS_PORT LRD_ADMIN_PASS LRD_UPSTREAM_URL
sudo docker compose config -q
sudo docker compose up -d --no-deps --force-recreate lua-router
```

复查 sqlite=1、db revision、声明与密钥状态、旧镜像 ID、健康池和流式请求。恢复镜像 JSON 与 sidecar 摘要必须配套，否则外部编辑检测会再次采纳文件。旧版不支持管理认证时明确报告认证能力回退。

### 5.4 217.t 裸容器迁移

没有 compose 时不能直接套 §5.2。先保存 `docker inspect`、原 image ID、全部 Env、Mounts、HostConfig、Entrypoint/Cmd、restart policy、端口和配置备份；按它们生成等价 compose，并用逐字段对照确认无丢项。尤其不要用新装模板代替其 `SMG_WORKER_URLS`、watcher、DENY_PORT 与 `http-extra.conf`。

仅获授权的维护窗口：停止旧 `lua-router-8800`，`docker rename` 为带时间戳的回滚名并保留，然后启动同名 compose 实例。失败时停止新实例，将其精确 rename 为失败留档名，旧容器 rename 回原名并 start；有数据变化则先按 §5.3 恢复配套状态。禁止删除旧容器、全局清理、借机改其他服务。原容器与新容器不能同时绑定 8800。

## 6. 源码构建与发布

仅运行固定镜像可跳过本节。Dockerfile 位于仓库根，`FROM authz:latest`；构建机必须先从可信 ACR/NAS 取得已知基座并 tag 为本地 `authz:latest`，记录其 image ID/digest。不要临时拉一个未知 `latest` 后宣称与已验基座相同。

读 [testing-workflow.md](testing-workflow.md)；门禁使用冻结源码/镜像 manifest、run 命名空间和机器端口台账，独立 run 可并发。先检查已有测试与端口，清理仅限自己名册，所有临时文件 `/data/tmp/`。

```bash
cd /home/aigc/ChatGPT/lua-router
git status --short
ps -ef | grep '[f]inal_gates.sh'
mkdir -p /data/tmp/lr-gates
export MANIFEST=/data/tmp/lr-gates/deploy-manifest.json
bash test/final_gates.sh prepare --manifest-out "$MANIFEST"
GATE_TIER=full bash test/final_gates.sh run --manifest "$MANIFEST"
```

全 22 门 pass、无 skip/missing/invalid，`full_anchor_eligible=True` 才是发版锚点；分组聚合也必须同 fingerprint 与 image IDs 补齐全部门。quick/定向绿不算 full。长任务用记录 PID 的 setsid/nohup 脚本，日志 `/data/tmp/`，不能全局 kill。

`script/build-image.sh` 从当前仓库树构建并推 ACR，检查 tracked dirty，**不会自行检查 full 结果或锁定基座**。执行前确认当前构建输入与绿 manifest 同 fingerprint、基座 ID 相同，未跟踪源码也必须核实；HEAD 记录对应锚点，不得把别的树的绿日志套上来。固定 tag 为 `YYYYMMDD-短sha`，发布后记录 manifest、源码身份、实际 image ID/digest。同一构建复用于各目标，不为每台重打不同 tag。

```bash
# 仅在需要发布且上述前置已确认时运行；会向ACR写入镜像。
script/build-image.sh
```

本次文档修改只需 `python3 script/check_docs_index.py` 与 `git diff --check`，不需要跑门禁，不改历史测试计数。部署完成的交付应包含：实例地址、版本/digest、认证用户名与口令、sqlite 生效证据、流式推理/UI验收、配置保存结果、备份路径与回滚依据。
