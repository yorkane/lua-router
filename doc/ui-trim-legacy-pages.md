# 移除根目录三个工具页（logs / metrics / config）

用户裁定 2026-10-03：`/_ui/logs.html`、`/_ui/metrics.html`、`/_ui/config.html`
与 `/_ui/admin/` 功能重叠，删除其前端代码与入口配置。本文记录**删除前的差异对拍**
（哪些能力是旧页独有、迁移到哪里）与**保留/删除的后端面**，作为后续「为什么这行
代码还在」的凭据。

## 1. 三个页面各是什么

| 文件 | 行数 | 定位 | 数据源 |
|---|---|---|---|
| `ui/logs.html` | 616 | 请求日志流（自包含单文件，无构建） | `GET ./logs?cursor=`（1s 增量轮询）+ `GET ./logs/stream`（SSE 低延迟）+ `GET ./stats` + `GET ./logs/backends`（worker→GPU） |
| `ui/metrics.html` | 373 | 运行指标聚合看板 | `GET ./stats`（2s）+ `GET ./logs?cursor=0&limit=2000`（10s 全量，页内聚合）+ `GET ./logs/backends` |
| `ui/config.html` | 1982 | 网关配置页：表单视图 + **整文档 JSON 源码编辑** | `GET ./config` 与 `POST ./config/{effort,ctx,model,virtual,upstreams,model-map,apply}`、`GET ./v1/models` |
| `ui/lmr-tabs.js` | 47 | 三页共享的标签条（Logs/Config/Metrics + 返回聊天） | — |
| `ui/logs-inject.js` | 105 | 向原版 webui 左导航注入 Logs + Admin 两个按钮 | — |

三者都是「离线单文件」路线（内联 CSS/JS、无 CDN、无构建、无 service worker），
早于 `ui/admin/`（Quasar UMD 管理台）出现，因此与后者大面积重叠。

## 2. 与 /_ui/admin/ 的重叠与差异对拍

### 2.1 logs.html ↔ admin/logs.html（日志监控页）

重叠：同一环形缓冲数据源（`/_ui/logs`）、状态码/模型/文本筛选、详情展开、
统计摘要卡（inflight / 窗口请求错误 / tok/s / 缓冲容量 / 运行时长）。
admin 版还多出 SSE 开关、GPU 与 route_type 列、tokens/cached/reasoning 明细。

旧页独有 → 处置：
- **1s 增量轮询 + SSE 双通道**：admin 版已是「SSE 追加 + 2s 轮询兜底 + 5s 统计轮询」，
  等价能力已覆盖，旧页的 cursor 补拉逻辑不再需要。
- **「复制请求 ID」「按会话筛选」按钮**：admin 版详情行已显示 session 与请求上下文，
  会话筛选退化为文本筛选输入（`filters.text` 覆盖该字段），可接受。
- **空态里的 curl 示例命令**：文档化能力，删（本文档与 doc/agent-handover.md 承担）。

### 2.2 metrics.html ↔ admin/logs.html（统计摘要）

重叠：实时块（并发、输入/输出 tok/s、窗口请求/错误、平均 TTFT、运行时长、缓冲容量）
——admin/logs.html 顶部四张 stat 卡完全覆盖。

旧页独有 → 已移植进 `ui/admin/logs.html` 的「聚合」折叠区：
1. 按模型聚合：请求数/错误数/成功率/平均耗时/平均 TTFT/P95 耗时/平均 tok/s/
   输入 tokens/输出 tokens/缓存命中。
2. 按后端聚合：worker（`:端口 + gpuN`，GPU 取自 `/_ui/logs/backends`）/请求数/错误数/
   平均耗时/该后端服务过的模型列表。
3. 推理强度分布：生效 effort 档位 / 请求数 / 被改写次数（requested≠effective）/ 改写示例，
   档位序 none→…→ultra，(默认) 置尾。

三张表都基于页面**已加载**的记录在浏览器端聚合，不新增 fetch；Prometheus 原始计数器
仍只看 `/metrics`（旧页本来也不跨端口 fetch，浏览器 CORS 挡）。

### 2.3 config.html ↔ admin/{models,workers,routing}.html

重叠（表单面，admin 全覆盖且更强）：全局 default_effort 与强度映射、每模型卡
（ctx / 默认档位 / 模型级映射 / 能力启用）、虚拟模型入口（targets / workers 白名单 /
context_window / candidates 逐候选绑定）、服务接入池 upstreams（含 max_concurrency /
max_power_w / api_key 三态）、模型名映射（转发 watcher）。路由策略已由
admin/routing.html 承担（`/_ui/config/policy`）。

旧页独有 → 已移植进 `ui/admin/models.html` 的「配置 JSON」对话框：
- **整份配置的 JSON 源码编辑 + `POST /_ui/config/apply` 整体替换**（缺省字段=清空）。
  这条是 AGENTS.md 第 4 点「JSON 格式的 API 修改与保存」的权威面：表单画不出的字段
  （未识别键、candidates 的特殊形状）必须有一条不丢字段的编辑通路。
- 无损读写：只过滤顶层段键（default_effort / effort_map / model_ctx / model_effort /
  model_configs / virtual_models / upstreams / model_map），行内字段一律原样往返。
- `upstreams.api_key` 三态语义（null/缺省=不动、`""`=清除、填值=设置）与
  `model_map` 转发 watcher 落地，写进对话框说明文案。
- 环境默认值（只读）：`GET /_ui/config` 响应顶层的 `env_defaults` 段仍在，
  admin 侧可通过 JSON 对话框的「重新载入」前先别删键的方式查看；该段由后端保留，
  前端不再单独渲染（旧页的 `<details>` 只读块随之删除）。

注意：`workers.html` 的 JSON 对话框只管 `upstreams` 一段（走 `/_ui/config/upstreams`
整表替换），与新的整文档 JSON 面互补，不重复。

移植时相对旧页面的两处有意偏离（root 裁定 2026-10-03）：
1. 旧页只发 8 段，而 `cfg_from_document` 还读 `policy` / `model_policies`（以及后端以后
   新增的任意顶层段）——整表替换下「文本里没有」= 清空，照抄会把路由策略页刚写的策略抹平。
   新实现把所有非派生、非可编辑的顶层段从当前 document 原样补回，这个面不编辑它们也绝不丢它们。
2. `model_map` 在 JSON 文本里缺席时按「不转发、watcher 账本不动」处理，与
   `handle_config_apply` 自己的口径一致（`model_map ~= nil and ~= JSON_NULL` 才转发）；
   绝不自作主张发 `{}`，那会被 watcher 当成清空账本。旧页面是整段发出，风险更高。
另外 `openConfigJson` 打开对话框时静默重取一次 document 作基线（只换 `doc.value`，
不走 `hydrate`，避免冲掉表单里未保存的编辑），缩表（虚拟入口/实例/改名条数减少或全清空）
必须二次确认，且只点名真的缩了的那一段。

## 3. 入口配置变更

- `ui/index.html`：注入脚本改名为 `admin-inject.js`（原 `logs-inject.js`）。
- `ui/logs-inject.js` → `ui/admin-inject.js`：ENTRIES 去掉 Logs 项，只留 Admin
  （新标签打开 `admin/index.html`）；幂等标记 `__lmrLogsInject` → `__lmrAdminInject`。
  **MutationObserver 防抖 + 判重注入模式原样保留**（AGENTS.md 记录过：Svelte 持有
  导航容器 children 引用，折叠侧栏会清掉注入节点，别破坏）。
- `ui/lmr-tabs.js` 删除：它只服务于三个被删页面。
- `ui/sw.js` 与 `ui/build.json` 无需改动——三个页面与注入脚本从来不在 workbox
  precache 列表里（当初就是为此才做自包含单文件）。

## 4. 后端：删什么、留什么

**全部保留**。这三个页面对应的后端 API 同时是 `/_ui/admin/` 的数据面，删任何一个
都会打断管理台：

| location（conf/ui.conf） | 现在的使用方 |
|---|---|
| `/_ui/logs`、`/_ui/logs/stream`、`/_ui/logs/backends`、`/_ui/stats` | `admin/logs.html`（含新聚合区） |
| `/_ui/config`（GET/HEAD） | `admin/models.html`、`admin/workers.html` |
| `/_ui/config/{effort,ctx,model,virtual}` | `admin/models.html` |
| `/_ui/config/upstreams` | `admin/workers.html`（含其 JSON 对话框） |
| `/_ui/config/model-map` | `admin/models.html` |
| `/_ui/config/policy` | `admin/routing.html` |
| `/_ui/config/apply` | `admin/models.html` 的新「配置 JSON」对话框 |
| `/_ui/config/ctx` | `admin/models.html`（ctx 批量保存） |

真正删除的「后端代码」只有页面自身，Lua 侧仅调整注释指向：
`conf/ui.conf` 头部与 config 段的注释不再声称「exact location 是为了让
config.html / logs.html 可达」（该约束随页面消失，但 exact `=` 仍然必须保留——
它同时保护 `/_ui/` 静态前缀不吃掉 `/metrics`、`/stats` 这些控制面路径）；
`observability.lua` 的 wire-contract 注释指向 `ui/admin/logs.html`。

## 5. 测试变更

- `test/test_lua_router.sh` ui_fixed 段：删除 `GET /_ui/logs.html` 的 200 断言，
  改为断言三个旧页面已消失（`/_ui/logs.html`、`/_ui/metrics.html`、
  `/_ui/config.html` 一律 404），并保留 `/_ui/admin/` 200 的锚点断言。
- 其余 API 断言（`/_ui/config`、`/_ui/stats`、`/_ui/logs`、HEAD 镜像、CORS）不动。
- `test/integration/e2e_ui_bridge.py` 不引用这三个页面，无需改动。

删除把 ui_fixed 段换成 4 条 404 断言后契约计数 650 → **653**（ui_fixed 57 → 60），
已同锚更新 README 的门禁表与 23 段构成。

本次移除的全量门禁锚点：`/data/tmp/lr-gates/gates-20261003-034756.log`
（`GATE_TIER=full`，21 passed / 0 failed / 0 skipped）。
