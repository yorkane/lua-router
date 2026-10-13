# lua-router 部署手册（全新部署与升级）

> 读者是执行部署的 agent。本文是给「从零部署一个实例」与「滚动升级一个既有实例」用的
> 唯一操作手册，含全部明文凭据。fleet 现状逐实例事实在
> [deploy-state.md](deploy-state.md)，实例角色真值在 AGENTS.md 硬规则 3，
> 管理面鉴权的设计口径在 [gap-admin-auth.md](gap-admin-auth.md)，
> 配置持久化语义在 [gap-config-store.md](gap-config-store.md)。
>
> 用户裁定 2026-10-13：部署文档必须写清认证名和密码。凭据以明文入本档；
> 仓库与部署机同属可信内网域。口令轮换后同步更新本档 §0（见 §0.2 的轮换步骤）。

## 0. 凭据总表

### 0.1 镜像仓库（阿里云 ACR 企业版，推/拉镜像用）

| 项 | 值 |
|---|---|
| Registry | `wasu-wtvdev-registry-test-registry.cn-hangzhou.cr.aliyuncs.com`（下称 `$RG`） |
| 命名空间 | **只有 `pub/` 可用**（`dev/`、顶层、无命名空间一律 denied） |
| 镜像名 | `$RG/pub/lua-router:<tag>` |
| 登录用户名 | `caifangwei@wasutest` |
| 密码 | `cfw.wasu@892` |

登录命令（目标机没有凭据时才需要；235.t 本机 `~/.docker/config.json` 已保存，不要重复 login）：

```bash
echo 'cfw.wasu@892' | docker login -u 'caifangwei@wasutest' --password-stdin \
  wasu-wtvdev-registry-test-registry.cn-hangzhou.cr.aliyuncs.com
```

密码含特殊字符，必须单引号包裹。该账号对列举接口（`/v2/_catalog`、tags list）返回 401，
确认 tag 存在用 `docker manifest inspect $RG/pub/lua-router:<tag>`（退出码 0 = 在）。
推上去的 tag 删不掉，命名前想清楚；`latest` 不许用。
跨 box 分发口径见 docker-acr 技能：小镜像（本镜像约 80MB）走 ACR，超大镜像才走 /nas2/docker。

### 0.2 管理面 Basic Auth（网关自建，用户名恒定）

| 项 | 值 |
|---|---|
| 用户名 | **`lua-router`**（`admin_auth.ADMIN_USER` 常量，不可配） |
| 密码 env | `SMG_ADMIN_AUTH_PASS`（只走 env，不落配置 db / 配置文件） |
| fleet 现值 | 21.k:8800 与 21.k:8802 = **`test123`**（2026-10-12 部署时写入的临时口令，生产应尽快轮换）；235.t:8800、21.k:8801、217.t:8800 = 未配置（整道门关闭，管理面匿名） |

行为要点（全部由 `test/unit/test_admin_auth.lua` 钉死，改动前先读 gap-admin-auth.md）：

- `SMG_ADMIN_AUTH_PASS` **未配置或空串 = 整道门关闭**（缺省逐字节零行为变化）。
  compose 里注释掉该键或写成 `""` 都是关门；纯空白（`" "`）**是**有效口令，不裁空白。
- 来源 loopback（127/8、`::1`）免凭据；但 `X-Real-IP` / `X-Forwarded-For` / `Forwarded`
  **任一头名一出现就收回豁免，值一概不解析**（反代同机时 remote_addr 恒 127.0.0.1，
  按值还原等于给 `-H 'X-Real-IP: 127.0.0.1'` 开门——这是被用户裁定推翻过的 v1 形状）。
- 保护范围：管理台入口 `/` 与 `*.html`、根数据面 `/config*` `/logs*` `/stats` `/slots` `/tools`、
  `/u/config*` 别名族、klib 控制面 `/workers` `/model-map` `/flush_cache`。
  `/health` `/metrics` `/v1/*` `/u/` 对话面与 mesh 互联面**永不**过这道门。
- 用户名错、密码错、非 Basic、缺 `:`，全部同一个 401 + `WWW-Authenticate: Basic realm="lua-router admin"`，
  不区分原因。口令是明文 base64：只在 HTTPS（反代终结 TLS）或可信内网下启用。
- **env 白名单登记纪律**（AGENTS.md 硬规则 11-3）：`conf/nginx.conf.template`、
  `conf/lua-router.conf`、`test/conf/nginx-lua-router.conf` 三份的 `env SMG_ADMIN_AUTH_PASS;`
  必须同步在（现状已齐）。漏登记 = nginx 从 worker 剥掉该变量 = 门静默不生效，
  现象是「compose 里配了口令但怎么都不 401」。
- 浏览器把凭据嵌在页面 URL 里时页面内相对 fetch 会被拒（侧栏显示「网关不可达」）——
  弹框输凭据与 `curl -u` 两条路径正常，这不是网关缺陷。

轮换口令（只动 env，不碰配置 db）：

```bash
sed -i 's#SMG_ADMIN_AUTH_PASS: "旧值"#SMG_ADMIN_AUTH_PASS: "新值"#' docker-compose.yml
docker compose up -d
curl -s -o /dev/null -w '%{http_code}\n' -H 'X-Real-IP: 127.0.0.1' http://127.0.0.1:<port>/config                       # 期望 401
curl -s -o /dev/null -w '%{http_code}\n' -u 'lua-router:新值' -H 'X-Real-IP: 127.0.0.1' http://127.0.0.1:<port>/config  # 期望 200
```

换完同步更新本文 §0.2 的现值列。

### 0.3 基座镜像 authz（构建 lua-router 的前提）

Dockerfile 是 `FROM authz:latest`（OpenResty 1.31.1.1 + PCRE2/JIT + klib.router 基座）。取基座：

```bash
# 首选：ACR 镜像（本机 authz:latest 的 RepoDigests 与它同 digest，2026-10-13 实测）
docker pull $RG/pub/authz:latest
docker tag  $RG/pub/authz:latest authz:latest
# 外网可达的机器可走上游（公开仓库，匿名可拉；CI 只发 GHCR）
docker pull ghcr.io/yorkane/authz:latest && docker tag ghcr.io/yorkane/authz:latest authz:latest
```

`authz:latest` 这个名字必须存在且非空，`docker build` 才走得动（基座不需要登录；ACR 侧 pull 需要 §0.1 的登录）。

### 0.4 入口级 api-key（与被保护面无关的下游准入门）

虚拟模型条目可配 `api_key`（三态：未配=匿名 / 配置=门槛）。配置后该入口只认
`Authorization: Bearer <key>`，缺键与错键同一个 401（`WWW-Authenticate: Bearer realm="lua-router"`）。
它是按入口的下游准入门，密钥值在 `/config` 的 `virtual_models[].api_key`（对外回显脱敏，明文只活在
config_store 内部）。与 §0.2 的管理面口令是两套，互不相干。

## 1. 全新部署

### 1.1 前置

- 机器上有 docker + docker compose；host 网络可用（fleet 全部 host 网络部署）。
- 规划三个端口：推理口 `SMG_PORT`（生产惯例 8800）、metrics 口 `SMG_METRICS_PORT`
  （惯例 = 29000 + 实例偏移：8800→29000、8801→29001、8802→29002；同机多实例互不冲突）。
- 落盘根：**有 /data 的机器用 `/data/app/lua-router-<PORT>/`**（235.t 的 8800 用无后缀的
  `/data/app/lua-router/`，保持历史路径）；**21.k 用 `/data1/app/lua-router-<PORT>/`**
  （21.k 的 /data/app 下没有 lua-router）。
- 生产 8800 的部署与替换需要用户明确要求（AGENTS.md 硬规则 3）；改动先上 21.k:8801/8802 测试实例。

### 1.2 目录与文件

```bash
export PORT=8800 METRICS_PORT=29000               # metrics 惯例 = 29000 + 实例偏移
export ROOT=/data/app/lua-router-$PORT            # 21.k 换 /data1；235 的 8800 用 /data/app/lua-router（无后缀）
sudo mkdir -p $ROOT/config
sudo chown -R $(id -un):$(id -gn) $ROOT           # 容器以 root 运行，落盘文件归 root；宿主目录归操作员便于备份与 git
cat > $ROOT/http-extra.conf <<'EOF'
log_not_found off;
EOF
```

`http-extra.conf` 由 `LR_HTTP_INCLUDE` 注入 http{} 层，唯一作用是压掉 metrics 口上
llm-watcher 类端口扫描器 `GET /v1/models` 落静态兜底产生的 `No such file` 抄送日志；
Lua 侧 error 日志不受影响（内容出处 = 235.t 生产在用的 /data/app/lua-router/http-extra.conf）。
`config/` 目录必须存在：sqlite 后端要往 `<LMR_CONFIG_FILE>.db` 写，bind 挂载的宿主目录不存在时
docker 会自动建（root 属主）；先手建好并把属主理顺，备份/git 都省事。

### 1.3 compose 模板

`$ROOT/docker-compose.yml`（键值取 fleet 生产实测形状；镜像 tag 换当前绿的）：

```yaml
services:
  lua-router:
    image: wasu-wtvdev-registry-test-registry.cn-hangzhou.cr.aliyuncs.com/pub/lua-router:20261012-69b5d53
    container_name: lua-router-$PORT              # 生产 8800 惯例名 lua-router-8800
    network_mode: host
    restart: unless-stopped                       # AGENTS.md：compose + unless-stopped 是部署基线
    environment:
      SMG_HOST: "0.0.0.0"
      SMG_PORT: "$PORT"
      SMG_POLICY: "cache_aware"                   # 8 值见 README〈策略〉；未知值静默归一
      SMG_CACHE_THRESHOLD: "0.2"                  #  fleet 实测值，缺省 0.3 更松
      SMG_BALANCE_ABS_THRESHOLD: "32"
      SMG_BALANCE_REL_THRESHOLD: "1.5"
      SMG_EVICTION_INTERVAL_SECS: "120"
      SMG_MAX_TREE_SIZE: "100000000"              # 1e8：2026-10-11 长会话亲和定尺，不要缩
      SMG_ENABLE_IGW: "true"                      # 按 model 查表路由
      SMG_HEALTH_CHECK_INTERVAL_SECS: "30"
      SMG_HEALTH_CHECK_TIMEOUT_SECS: "5"
      SMG_HEALTH_CHECK_ENDPOINT: "/health"
      SMG_REQUEST_TIMEOUT_SECS: "1800"
      SMG_METRICS_PORT: "29000"
      SMG_PROMETHEUS_HOST: "0.0.0.0"
      SMG_UI_DIR: "/usr/local/share/llama-ui"
      SMG_LOG_LEVEL: "info"
      # —— 管理面 Basic Auth（用户名恒 lua-router；删掉本行 = 整道门关闭）——
      SMG_ADMIN_AUTH_PASS: "改成正式口令"
      # —— 内建 watcher 服务发现（fleet 全部开启）——
      SMG_WATCHER_ENABLED: "1"
      SMG_WATCHER_DOCKER: "1"
      SMG_WATCHER_PROC_SCAN: "1"
      SMG_WATCHER_CONTAINER_IPS: "0"              # docker 分支不过 DENY_PORT，宿主映射口齐的机器关掉无损
      SMG_WATCHER_DENY_PORT: "111,5432"           # 按机器环境填，见 1.4
      # —— 配置持久化（sqlite 权威 + JSON 只读镜像，见 gap-config-store.md）——
      LMR_CONFIG_FILE: "/data/lua-router/runtime.json"
      LR_HTTP_INCLUDE: "/etc/lua-router/http-extra.conf"
      # —— 可选：启动种子 worker（不填则纯 watcher 发现，watcher 30s 内会补齐）——
      # SMG_WORKER_URLS: "http://127.0.0.1:8012,http://127.0.0.1:8021"
      # —— 可选：GPU 利用率通道（要配 max_gpu_util 的机器必须开，正解 = 8802 形状）——
      # SMG_LOAD_SOURCE: "prom"
      # SMG_LOAD_PROM_URL: "http://127.0.0.1:9092"
      # SMG_LOAD_PROM_QUERY: "max by (Hostname,instance,gpu) (DCGM_FI_DEV_GPU_UTIL)"
      # SMG_LOAD_UTIL_QUERY: "max by (Hostname,instance,gpu) (DCGM_FI_DEV_GPU_UTIL)"
      # SMG_LOAD_INTERVAL_SECS: "10"
      # SMG_LOAD_STALE_SECS: "30"
    volumes:
      - "$ROOT/config:/data/lua-router"
      - "/var/run/docker.sock:/var/run/docker.sock:ro"   # watcher 的 docker 发现；只读
      - "$ROOT/http-extra.conf:/etc/lua-router/http-extra.conf:ro"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:$PORT/health"]
      interval: 30s
      timeout: 5s
      start_period: 15s
      retries: 3
```

要点：

- **workers 数不用配**：入口脚本在 `SMG_POLICY=cache_aware`（缺省）时钉 `worker_processes 1`——
  亲和树是 per-process 的；mesh 开启同样钉 1。显式 `NGINX_WORKER_PROCESSES` 永远优先。
- `SMG_LOAD_PROM_QUERY` / `SMG_LOAD_UTIL_QUERY` 必须带 `instance` 与 `gpu` 标签：
  缺 `instance` 则机器名与 `127.0.0.1:8012` 类 worker 地址对不上，unmatched 只涨、读数落不到池上；
  缺 `gpu` 则整机共享一个数，逐卡判定不成立（fleet 三形状与读数的教训见 deploy-state.md §2.2）。
- 裸容器（不给 `LMR_CONFIG_FILE` 也不给 `LMR_CONFIG_STORE_PATH`）入口脚本会注入默认
  `/data/lua-router/runtime.json` 并建父目录；显式 `LMR_CONFIG_STORE_BACKEND=file` = 要无落盘纯内存态，
  此时不注入。上面的模板按 fleet 惯例显式给路径，别依赖注入。

### 1.4 DENY_PORT 按机器环境填

watcher 的 proc 扫描会把本机所有监听端口探测成 worker 候选。deny 名单收「接受连接后立刻 RST」
的基础设施口与不该被代理进池的自身/边缘服务（235.t：`111,5432,11022,14389,42209`；
21.k：外加 `22,80,443,3000,9080,9091,9092,9100,9180,9443,9912,15012,2379,2380`——authz/apisix 边缘
会代理 `/v1/*`，不 deny 会被注册成 worker）。新机器按 `doc/gap-watcher-merge.md` 的端口名单与探针预算逐口核实。

### 1.5 启动与验收

```bash
cd $ROOT
docker compose pull && docker compose up -d

curl -s  http://127.0.0.1:$PORT/health                                  # OK
curl -s  http://127.0.0.1:$PORT/metrics | grep -E '^lr_config_store_backend'
    # 必须 backend="sqlite"} 1 —— 是 file 说明落盘没起来，一切持久化验证作废（硬规则 11「另」条）
curl -s  http://127.0.0.1:$PORT/workers | head -c 400                   # watcher 首轮后有条目
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:$PORT/        # 管理台（loopback 免凭据）200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:$PORT/u/      # 原版 webui 200
curl -s  http://127.0.0.1:$PORT/v1/models | head -c 300                 # 官方四字段齐，owned_by 恒 lua-router
```

四条认证形状探针（配了口令的实例；全绿 = 门生效且豁免面不缩水）：

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:$PORT/config                                            # 200 loopback 豁免
curl -s -o /dev/null -w '%{http_code}\n' -H 'X-Real-IP: 127.0.0.1' http://127.0.0.1:$PORT/config                  # 401 前置否决
curl -s -o /dev/null -w '%{http_code}\n' -u 'lua-router:<口令>' -H 'X-Real-IP: 127.0.0.1' http://127.0.0.1:$PORT/config  # 200
curl -s -o /dev/null -w '%{http_code}\n' -u 'wrong:<口令>' -H 'X-Real-IP: 127.0.0.1' http://127.0.0.1:$PORT/config        # 401
```

**启动后 30–60s 内出现 503 `all circuits open or unhealthy` 是暂态**：健康巡检间隔 30s +
success_threshold=2，第一个巡检周期没走完。上游直连 /health 200、容器日志无 error 时，等一拍再判断，
别把它当部署失败（fleet 两轮实测踩过）。

冒烟推理（挑一个池内真实模型名）：

```bash
curl -s http://127.0.0.1:$PORT/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"<模型>","messages":[{"role":"user","content":"hi"}],"max_tokens":8}' | head -c 300
curl -s http://127.0.0.1:$METRICS_PORT/metrics | grep smg_router_tokens_total | head -5   # 计数增长
docker logs --since 5m lua-router-$PORT 2>&1 | grep -c '\[error\]'                        # 应为 0
```

持久化闭环（新部署做一次即可）：`POST /config/apply` 写一条无害声明（如一个临时虚拟入口），
确认 `config/runtime.json` 镜像更新、`runtime.json.rev` 递增、`docker compose restart` 后回显还在；
验完清回。CAS：带期望 revision 写，冲突回 409 带当前值——409 不是「后端连不上」，两者处置不同。

## 2. 升级（滚动既有实例）

### 2.1 镜像从哪来

```bash
cd /home/aigc/ChatGPT/lua-router
# 前置：HEAD 是门禁全绿锚点、已跟踪文件干净（发版镜像只从干净绿锚点构建）
GATE_TIER=full bash test/final_gates.sh          # 22 门全绿；分组聚合补齐全 22 门等价（testing-workflow.md §5）
script/build-image.sh                            # tag = YYYYMMDD-<短sha>，推 ACR pub/，manifest inspect 自检
```

tag 规范自 2026-10-12 起为 `YYYYMMDD-<短sha>`（不带端口前缀）：**同一构建在 fleet 里用同一个 tag**，
一台构建、多实例复用——别再为某台单独打端口 tag，那是 fleet 漂移的来源（旧形状 `8800-YYYYMMDD-N` 已废弃）。
构建机与目标机不通时走 ACR push/pull（本镜像 ~80MB，不必走 /nas2）。

### 2.2 顺序（硬规则 3）

1. 先滚 **21.k:8802**（测试实例）跑验收矩阵；
2. 用户确认后滚生产：**21.k:8800 → 235.t:8800 → 217.t:8800**（每台都要 2.3 的备份与 2.4 的矩阵）。
   217.t:8800 是裸 docker run（inspect 的 compose 标签为空，已核实），转 compose 时逐条搬 env
   （关键项在 deploy-state.md §1 列了名册），不许丢。

### 2.3 切换前取证（每台必做，2026-10-12 生产形状）

```bash
TS=$(date -u +%Y%m%dT%H%M%SZ); BK=$ROOT/backup-$TS
mkdir -p $BK
cp docker-compose.yml $BK/
cp -a config $BK/config
# db 是权威源：直接 cp 的 .db 不是事务一致的，只能当证据。恢复源走 WAL 安全在线快照
# （导完 integrity_check 必须 ok）：
python3 - "$ROOT/config/runtime.json.db" "$BK/runtime.sqlite-online" <<'PY'
import sqlite3, sys
src = sqlite3.connect(sys.argv[1]); dst = sqlite3.connect(sys.argv[2])
src.backup(dst); dst.close(); src.close()
PY
sqlite3 "$BK/runtime.sqlite-online" 'PRAGMA integrity_check;'
cat $ROOT/config/runtime.json.rev                 # 记 revision（真值在 .rev sidecar，/config 响应里没有）
curl -s http://127.0.0.1:$METRICS_PORT/metrics | grep -E '^lr_config_store_backend'   # sqlite=1
docker images --format '{{.Repository}}:{{.Tag}}' | grep lua-router | head   # 旧 tag 在盘 = 回滚秒级
```

升级窗口内**不做任何配置写操作**（CAS 409 在 reload 期是噪声源）。

### 2.4 换镜像与验收

```bash
sed -i 's#pub/lua-router:[0-9a-zA-Z.-]*#pub/lua-router:<新tag>#' docker-compose.yml
docker compose pull && docker compose up -d --force-recreate
```

验收矩阵（全绿才算完；等一个巡检周期再跑推理项）：

- `/health` OK；`/workers` healthy 数与切换前同量级（**total 含门禁 mock 残留，别当容量**）；
- `runtime.json.rev` 与切换前**相等** = 升级窗口零写入（零漂移）；`lr_config_store_backend{backend="sqlite"} 1`；
- `/config` 回显与切换前逐字段一致（虚拟入口/卡片/策略）；
- 一条真实流式 chat 200 + `smg_router_tokens_total` 增长；`docker logs` grep `\[error\]` = 0；
- 配了口令的实例跑 §1.5 的四条认证探针（200/401/200/401）+ `/u/v1/chat/completions` 与
  `OPTIONS` 预检永不 401；
- 管理台浏览器复核四页渲染（playwright-cli，无头下 `ERR_INVALID_AUTH_CREDENTIALS` = 401 挑战到达，
  属预期）；
- 外部域名形状：APISIX 链路（写 X-Real-IP）→ 配口令实例 401、未配实例 302（authz 登录墙）——
  按 [gap-admin-auth.md](gap-admin-auth.md) 的保护清单与匿名面逐项验收。

### 2.5 回滚

```bash
sed -i 's#pub/lua-router:[0-9a-zA-Z.-]*#pub/lua-router:<旧tag>#' docker-compose.yml
docker compose up -d --force-recreate        # 旧镜像本机在盘，秒级
```

回滚到不含 Basic Auth 的旧版（`fc037af`/`89f0ad0` 及更早）时顺手删掉 `SMG_ADMIN_AUTH_PASS` 行
（留着无害）。配置 db 一般无需回滚——升级不写配置；确要回滚时停容器、用备份的
`runtime.json.db`/`.db-shm`/`.db-wal` 三件套整体覆盖 `config/` 同名文件、再起容器。

## 3. 已知坑（都对应过一次真实事故或实测）

1. **`SMG_ADMIN_AUTH_PASS` 配了不生效**：三份 conf 的 env 白名单被改漏（§0.2 纪律），
   或 compose 写成空串（空串 = 关门是设计，不是 bug）。
2. **去 `/config` 响应里找 revision**：响应头与 JSON 顶层都没有这个字段（五实例实测一致）；
   落点在 config 目录的 sidecar `runtime.json.rev`，内容形如 `N <8位hex>`（2026-10-13 fleet 取证）。
3. **`/workers` 的 total 当池容量**：watcher 的 proc 扫描会把门禁轮 mock（alpha/beta 之类模型名、
   高位随机口）短暂注册进生产池（235.t 实测 total 462 / healthy 9）。处置是生产写面：
   `DELETE /workers/{id}` 逐条清，watcher 只重发现真在监听的；keep-last 宽限也会自收。
4. **给 `max_gpu_util` 却没配负载 env**：235.t/217.t 无 `SMG_LOAD_*`，闸门等于没配
   （`SMG_LOAD_SOURCE` 缺省 = 定时器根本不启动）。要配就按 8802 形状（§1.3 注释块）。
5. **cp 活动 sqlite 当恢复源**：WAL 模式下不一致；用 `sqlite3.Connection.backup()`（§2.3）。
6. **重启后立刻判死**：30–60s 暂态 503 属预期（§1.5）。
7. **热配置等一拍**：apply 之后第一个请求可能还走旧路由，apply 生效是异步的（fleet 实测记录）。
8. **旧 tag 形状并存**：fleet 里 `20261012-69b5d53`（新）与 `8800-20261011-89f0ad0`（旧，217.t）同时存在，
   升级时按 deploy-state.md 现状表逐台核对，别假设所有台用同一 tag。
9. **21.k 落盘根是 `/data1/app`**，235.t 的 8800 是 `/data/app/lua-router`（无端口后缀）——按现状表走，
   不要「顺手统一」。

## 4. 相关文档

- 现状与漂移：[deploy-state.md](deploy-state.md)；操作前重新核对实例
- 口径权威：[gap-admin-auth.md](gap-admin-auth.md)（鉴权）、[gap-config-store.md](gap-config-store.md)（持久化）、
  [gap-worker-caps.md](gap-worker-caps.md)（容量上限）、[gap-virtual-models.md](gap-virtual-models.md)（虚拟入口）
- 发布与门禁：[testing-workflow.md](testing-workflow.md)
- 验收标准：[gap-admin-auth.md](gap-admin-auth.md)、[gap-config-store.md](gap-config-store.md)
