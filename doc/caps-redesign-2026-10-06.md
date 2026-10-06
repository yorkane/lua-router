# 容量语义重设计 + 日志页改造（2026-10-06 执行契约）

> 用户裁定来源：本轮对话三条需求（并发上下限三态 / 功率改利用率 / 日志页合并与列序）。
> 事实基础：/data/tmp/lr-map-caps-2026.md、lr-map-gpuload-2026.md、lr-map-ui2-2026.md。
> 本设计**覆盖** doc/gap-worker-caps.md（2026-10-01）与 AGENTS.md §4 的旧容量口径，其余硬规则照旧。

## 0. 三条不可违反的红线（延续）

1. **上限是选路信号，不是健康信号**：不摘 worker、不改 is_healthy、不进熔断。颜色只是 UI 徽章 +
   /workers 的一个只读字段。
2. **读数未知 → 不排除**：gu: 缺席（监控挂了）绝不能变成容量排除，代价只能是精度。
3. **缺省零行为变化**：三个新字段全部缺席时，行为与今天逐字节一致（max_concurrency 缺席=不限；
   min 缺席=1；util 缺席=不限）。

## 1. 字段（声明层 upstreams per-instance）

| 字段 | 含义 | 缺省 | 校验 | 备注 |
|---|---|---|---|---|
| min_concurrency | 并发调度下限，低于它=绿 | 1（字段缺席等价 1） | 整数 1..31，且必须 < max_concurrency | 缺席时 UI 预填 1 |
| max_concurrency | 并发调度上限，硬排除 | 缺席=不限（回退今天语义） | 整数 1..32 | 缺席时 UI 预填 8 |
| max_gpu_util | GPU 利用率上限（0..100 整数） | 缺席=不限 | 整数 0..100；0 合法（极严档），负数/非数=nil | 缺席=不限 |

- max_power_w **退役**（读侧删、配置面删、UI 删）。功率采集链 pw: 与 lr_gpu_load_power_* 指标
  **保留**（纯观测，仍有读者），只是不再参与容量判定。理由：删采集要动六族指标 + e2e 断言，
  收益不抵风险；用户要换的是「上限这个判定指标」。
- 旧配置里写了 max_power_w 的：解析时 warn 一次并丢弃该键，**不迁移**（新字段无等价值，猜一个
  功率→利用率换算等于替操作员做决定）。/_ui/config GET 如实不返回它。

## 2. 三态与判定（registry 侧，UI 只显示不算）

新增 registry.capacity_state(record, d) → "idle" | "busy" | "full" | nil：

- 读数：lo:<id>（本网关在飞，整数，无 TTL）、gu:<id>（逐卡 GPU 利用率 0..1，TTL'd）
- **full（红）**：inflight >= max_concurrency，或 gu: 存在且 util >= max_gpu_util
- **idle（绿）**：inflight < min_concurrency（且非 full）
- **busy（黄）**：其余
- 三 cap 全缺席时返回 nil（无门 = 今天行为）
- capacity_exclusion 改为只对 **full** 返回 {reason="concurrency_max"|"gpu_util", ...}；
  既有 reason="concurrency"/"power" 字符串退役。

/workers 每条记录新增只读字段 load_state（idle/busy/full，nil=无门），UI 据此上色——
**禁止前端自己重算**（现状 capExceeded 是纯前端判定且零测试覆盖，是缺陷不是先例）。

## 3. 选路：绿灯优先（router/candidates.lua 门序追加）

现门序不变：健康→白名单/绑定→IGW 模型门→**容量硬排除(full)**→组门→落地。
在**落地段之前**追加一道子集裁剪（此时组门与绑定都已生效，组模式整组一起算）：

    if 有 idle 候选：只保留 idle 子集（黄灯让位），记 why.idle = 被让位数
    else：保留全部（说明池里最闲的也已到下限，此时黄灯可继续接直到触达上限）

- 落在 candidates_for 内，policies/ 仍是零改动。
- why 新增 idle 计数（可观测：让位了多少次）。
- 绿灯优先**不排除**任何 worker，只是缩小交给策略的数组；策略在该子集内照旧选路。

## 4. 兜底应答（router/forward.lua，覆盖旧 503 口径）

- why.capped > 0 and #candidates == 0（全池到顶）→ **429**，
  body: {error:{code:"no_available_workers", message:"No available workers (N at their concurrency or GPU-util limit)"}}。
  code 沿用（契约改动面最小），状态码 429，文案说清是容量到顶。
- 熔断/不健康/组不服务（why.refused 或无 capped）→ **保持 503** 与原文案。
- 契约与 e2e_caps 对应断言同步改（见 §6），用户裁定日期写进注释。

## 5. GPU 利用率读数（gpu_load 侧）

- 新键 gu:<worker_id>：0..1 纯利用率，带 TTL；**不复用 xl:**（那个被 load_scale 混成
  「在飞请求单位」，是打分不是准入）。
- 逐卡归属优先：复用 cards.lua 现成的 card_key/hint_index/worker_card/parse_labels，
  新增 assign_util（结构与 assign_power 平行：四路口径、归属冲突识破、逐卡命中计数）。
  没有卡归属时回退 host 级，并在 lr_gpu_load_util_fallback_total 计数（不做静默降级）。
- env：SMG_LOAD_UTIL_QUERY（默认 max by (Hostname,instance,gpu) (DCGM_FI_DEV_GPU_UTIL)，
  **带 gpu 标签才有逐卡**）、SMG_LOAD_UTIL_ENABLED（缺省 1）、沿用 SMG_LOAD_INTERVAL_SECS/
  SMG_LOAD_STALE_SECS。
- 内置 metric 名册补 dcgm_fi_dev_gpu_util（今天写的是 dcgm_gpu_utilization，与 DCGM 真名对不上）。
- 三份 conf 的 os.getenv 名单三处同步（conf/lua-router.conf、conf/nginx.conf.template、
  test/conf/nginx-lua-router.conf），漏一份即静默失效。

## 6. 指标、门禁、文档

- smg_worker_capacity_excluded_total{reason}：concurrency→concurrency_max，power→gpu_util；
  新增 smg_worker_capacity_preferred_idle_total（绿灯优先让位次数）。
- e2e_caps 改造点（/data/tmp/lr-map-caps-2026.md §6.4 有完整 11 条）：S2 并发改三态、
  S3 功率改 util、S5 全场到顶 503→429 且文案精确匹配、S3b 逐卡守卫改 util 口径。
- test_caps_routing G4/G5/G8 补三态与绿灯优先；**注意它用桩替换 capacity_exclusion**
  (:108)，要新增一组不打桩的真实现断言。
- contract：igw 段 503 断言保留（熔断路径），新增 429 全场到顶断言。
- 文档：doc/gap-worker-caps.md 重写、gap-gpu-load.md 补 gu 通道、README 端点与字段表更新、
  agent-handover §4 容量段改写、deploy-fleet 示例串改新字段。

## 7. UI 契约

### 7.1 服务池（workers.html + i18n.js）
- 表格 capacity 列：并发（min–max 区间显示）与 GPU 利用率上限两段；load_state 决定颜色
  （idle 绿 / busy 黄 / full 红 + 满员图标）。
- 实例名后加 **GPU 徽章**：数据源 /workers 的 metadata.gpu（labels 已由 registry 转出，
  logs.html:606-616 已有 gpuIndex 先例），零新增请求。**不改 model_id**（会动策略 key 与
  /v1/models 广告，风险不成比例）。无 gpu label 时不显示徽章。
- 三个对话框（add/decl/edit）容量区：并发下限（默认 1，必填，1..31）、并发上限（必填，1..32，
  必须 > 下限）、GPU 利用率上限（0..100，可空=不限）。校验用 q-rules，缺省值预填。
- 并排两列（.form-grid-2），省垂直空间；declared 行的编辑入口仍整体隐藏。

### 7.2 日志页（logs.html + app.css）
- 顶部：inflight / 窗口请求·错误 / 缓冲 三卡合并为一条**紧凑统计条**；腾出的整块给
  **输入 tok/s / 输出 tok/s（60s 均值）** 大字卡（口径沿用现有 summarizeWindow，60s 窗口）。
- 列序：时间 → **状态** → …… → **CACHE** → **模型** → ……（状态进第二列，模型移到 CACHE 之后）。
- 抖动修复（根因是每 2s autoRefresh 制造 loading 占位 + catch 清空 rows）：
  L1 :loading="loading && rows.length === 0"；L2 非首屏失败不清空 rows；L3 cursor 无变化
  跳过整段替换；L5 声明 autoTimer（现为隐式全局）并在 SSE 连上后把轮询降档/停掉。

## 8. 波次与所有权

| 波 | worker | 名下文件 |
|---|---|---|
| A | w_caps_registry | registry/keys.lua registry/loads.lua registry/records.lua registry/discovery.lua |
| A | w_caps_store | config_store/upstreams.lua config_store/profiles.lua config_store/snapshot.lua |
| A | w_util_gpu | gpu_load/* config.lua conf 三处 SMG_LOAD env 段 |
| B | w_caps_router | router/candidates.lua router/forward.lua |
| B | w_workers_ui | ui/admin/workers.html ui/admin/i18n.js |
| B | w_logs_ui | ui/admin/logs.html ui/admin/app.css |
| C | w_caps_tests | test/integration/e2e_caps.py test/unit/test_caps_routing.lua test/unit/test_gpu_load.lua test/test_lua_router.sh |
| D | t_8802b | 21.k:8802 部署与真机验证（禁止碰 8801） |
| E | w_docs2 | gap-worker-caps.md gap-gpu-load.md README.md doc/agent-handover.md doc/deploy-fleet.md 本设计书 §9 |

跨文件契约（并行前置）：capacity_state 签名、load_state 字段名、gu: 键名与 0..1 口径、
why.idle 计数、429 兜底文案 —— 全部按本文件 §1-§5 钉死，worker 不得自行改名。

## 9. GPU 标注采集（补充裁定，root 实测发现）

**实测**：8802 的 /workers 每条记录 metadata 里**没有 gpu 字段**——watcher 现在的
`gpu_from_name` 只匹配名字里的 `gpu(\d+)`（如 `q38fn-gpu0`），而 21.k 的容器名/进程名里没有这种
标记，所以 21.k 上 8 个实例全部拿不到 GPU 标注。UI 徽章的数据源因此是空的。

**21.k 上 GPU 归属确实存在**：`ps aux` 里 sglang 进程带 `--device-id` 与 `CUDA_VISIBLE_DEVICES=`。

**改造**（watcher 侧，纯采集，不碰发现与探针逻辑）：
1. `watcher/env.lua` 新增 `gpu_from_cmdline(cmdline)`：解析 `--device-id N`，其次
   `CUDA_VISIBLE_DEVICES=N`（取第一个数字，支持 `0,1` 形式），都无则 nil。
2. `watcher/discover.lua` 的 `listening_sockets` 已在读 /proc/net/tcp——补一条 **socket→pid 解析**：
   记下每条 LISTEN socket 的 inode，扫 `/proc/<pid>/fd/*` 找 `socket:[inode]` 命中者，
   读该 pid 的 `/proc/<pid>/cmdline`（NUL 分隔）交给 gpu_from_cmdline。
3. 候选对象带 `gpu = <解析结果>`；**只在原 gpu 为空时填充**，绝不覆盖已有值。
4. 任何一步失败（/proc 读不到、权限、格式变）一律降级为 nil——它只是 label，
   不进任何排除/摘除/探针逻辑，绝不影响服务发现本身（watcher 十条守卫与探针分档红线原样）。
5. 有 GPU 标注后：UI 实例名后显示 GPU 徽章（数据源 metadata.gpu），
   且 gpu_load 的逐卡 util 归属（§5）也能用上这个标注来确认 worker↔卡映射。

**归属说明**：UI 显示仍是徽章，**不改 model_id**（会动策略 key 与 /v1/models 广告，风险不成比例）。
