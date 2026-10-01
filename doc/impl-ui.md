# lua-router /_ui 实现说明（UI 静态资源 + API 别名）

对应 Rust 参照实现：`gateway/src/server.rs`（`ui_api_routes` / `ui_logs_routes` /
`ui_config_routes` / `ServeDir` 挂载）、`gateway/src/runtime_config.rs`。
本侧文件：

| 文件 | 内容 |
|---|---|
| `conf/ui.conf` | 全部 `/_ui/*` location（API 别名 + 静态 SPA），被 server 的 server{} include |
| `lualib/resty/luarouter/ui.lua` | 别名 handler：chat/completion、models、load/unload/sse、slots/tools/lookup、control/stream、config/logs 转发 |
| `lualib/resty/luarouter/props.lua` | `/_ui/props` 合成（worker /props 代理 + 改写链 + 兜底文档） |
| `lualib/resty/luarouter/config_store.lua` | RuntimeConfig：八档 effort 校验、model_ctx、virtual 别名、`LMR_CONFIG_FILE` 原子落盘、`/_ui/config*` 全家、watcher model-map 代理 |

> **状态**：仍有效；§1「部署接线（core agent 需要做的）」与 §3 的 pipeline 查找链已完成。
> **日期**：写作 2026-09-29，状态复核 2026-09-30（UTC）。
> **证据强度**：A（契约 `ui_fixed` 51 项 + `ui_auth` 33 项本轮复跑全绿）。
>
> 事实校正：
> - `router.do_chat` / `do_completion` **已实现**（router.lua:1399 / :1404 → `ui_pipeline`），
>   `POST /_ui/v1/chat/completions` 实测 **200**；body 走原始字节 + `splice_ui_cleanups` 定点改写，
>   `"tools":[]` / `"stop":[]` 到 worker 仍是数组（fix-majors M3）。
> - §2 表里所有 `/_ui/*` 别名现在还有一层鉴权：9 个受保护 location 先过 `ui.api_auth()`
>   （`SMG_API_KEY` 未配置时直通；只认 `Authorization: Bearer`；失败回 401 **空 body**），
>   chat / completions 两条走共享 pipeline 的 `check_data_auth()`。由 `ui_auth` 段 33 断言覆盖（M6）。
> - §1 记录的 `config_store.re_split` 崩溃 bug **已修**（现用 `ngx.re.find` 取位置），
>   由 probes 轮次的 `[re_split]` 断言覆盖。
> - §6 的 observability 桥四个 handler 已全部落地，不再是「core 侧待实现/在建」。

## 1. 部署接线（core agent 需要做的）

```nginx
# server{} 内（所有 API location 都是精确 `=`，与路由无关，可放任何 include 点；
# 静态 `^~ /_ui/` 放最后即可，精确匹配天然优先）
include /usr/local/openresty/nginx/conf/lua-router/ui.conf;
```

`init_by_lua_block` 必须调用一次环境快照（nginx 会剥离 worker 里未声明的
env，Lua 请求阶段 `os.getenv` 一律返回 nil，这是实测行为）：

```lua
init_by_lua_block {
    require("resty.luarouter.config_store").capture_env()
    -- ...core 自己的 init
}
```

需要的 shared dict（缺 `luarouter_config` 时 config_store 自动退化为
「每次现读 LMR_CONFIG_FILE（0.5s TTL 缓存）」，功能不挂，但跨 worker 一致性
变差，建议声明）：

```nginx
lua_shared_dict luarouter_config 1m;   # 跨 worker 配置广播（本模块用）
```

静态目录：`LMR_UI_DIR`（默认 `/usr/local/share/llama-ui`）。Dockerfile 里
`COPY ui/ /usr/local/share/llama-ui`（与 Rust 镜像一致）由 core 负责。
ui.conf 的静态段用 `set_by_lua_block` 解析目录 + `alias $var`，实时 gzip，
不启用 brotli_static/gzip_static（bundle 无 .br/.gz 兄弟文件）。

## 2. 固定行为清单（全部已实测）

| 路径 | 方法 | 响应 |
|---|---|---|
| `/_ui/v1/chat/completions` | POST（否则 405） | 走共享 pipeline（见 §3），body 先 fill_default_model + clean_ui_effort；坏 JSON → 400 `{"error":{"message":"invalid chat request: ..."}}` |
| `/_ui/v1/completions` | POST | 同上，错误文案 `invalid completion request: ...` |
| `/_ui/v1/models` | GET | `{object:"list",data:[{id,object:"model",created:0,owned_by,status:{value:"loaded"}}]}`，含 virtual 别名（`owned_by:"llm-router->target"`），按 id 排序 |
| `/_ui/models/load` | POST | 200 `{"success":true}` |
| `/_ui/models/unload` | POST | 400 `{"error":{"message":"模型由 router 后的实例常驻提供，聊天界面不能卸载；要摘除请在 watcher / 服务侧操作"}}` |
| `/_ui/models/sse` | GET | `text/event-stream`，只发 `: ping` 注释帧，30s 间隔（实测 30.0s 节拍），永不结束 |
| `/_ui/props` | GET | props.lua 合成，见 §4 |
| `/_ui/slots` `/_ui/tools` `/_ui/v1/streams/lookup` | any | 200 `[]`（cjson empty_array） |
| `/_ui/v1/stream` `/_ui/v1/chat/completions/control` | any | 501 `{"error":"llama.cpp server stream/control not available through the router"}` |
| `/_ui/config` | GET=读 / POST=effort | 见 §5 |
| `/_ui/config/{effort,ctx,model,virtual,apply,model-map}` | POST | 见 §5 |
| `/_ui/logs` `/_ui/logs/stream` `/_ui/logs/backends` `/_ui/stats` | GET | observability 桥（见 §6） |
| `/_ui` | GET | 301 → `/_ui/` |
| `/_ui/...` 其它 | GET | 静态文件（`LMR_UI_DIR` alias） |

方法门控对齐 axum：错方法 405 + `Allow` 头（Rust 在 route 层拒绝，不 handler 里判断）。

**与任务书的一个有意偏差**：任务书要求 logs/stats/config 用 `location ^~
/_ui/logs*` 前缀。前缀会吞掉静态页 `/_ui/config.html`、`/_ui/logs.html`、
`/_ui/metrics.html`（Rust 里这些页面靠 exact-route 优先级才能打开）。因此
全部 endpoint 用精确 `=` location，行为一致且静态页可达。若后续新增
`/_ui/config/<新子路径>`，需显式加 location。

## 3. 给 core 的 pipeline 契约（chat/completion 代理）

`ui.lua` **不复制任何代理逻辑**。它解析顺序：

1. `require("resty.luarouter.api")` → `api.chat(body_table)` / `api.completion(body_table)`
2. `require("resty.luarouter.router")` → `router.do_chat(body_table)` / `router.do_completion(body_table)`
3. 全局 `LMR_TEST_PIPELINE`（单测注入）

契约会话（core 侧二选一实现即可，推荐 api 名）：

```lua
--- 入参：已由 UI 层清洗过的 JSON body（table）。
--- 必填语义：body.model 保证非空（除非注册表为空）；reasoning_effort 为
--- 空串/null 时已被删除。effort/ctx 策略、虚拟别名解析（resolve_model）
--- 归 pipeline 内部做（与 Rust route_chat 前 apply_effort_policy/ctx cap 一致）。
--- 责任：自行写响应状态行 + header + body（含 SSE 透传），返回后 ui.lua 直接
--- 交还（通常内部以 ngx.exit/ngx.eof 收尾）。错误响应格式
--- {"error":{"message":...}} 由 pipeline 统一。
function api.chat(body) end
function api.completion(body) end
```

三者都缺位时 ui.lua 以 503 `invalid chat request: router pipeline not available`
诚实报错（不静默 200）。

## 4. props 契约与 registry 读侧约定

`props.http_workers()` 返回 `[{url, api_key|nil, models={id...}}]`。解析顺序：

1. `registry.http_workers()`（若 core 想直接提供）
2. `registry.records()`（现有 registry.lua 已提供）→ 按 `url` 聚合、
   `connection_mode=="http"` 过滤、`model_id` 去重（record.api_key 透传）
3. 全局 `LMR_TEST_WORKERS`（单测）

props 改写链（顺序与 Rust 一致）：`chat_template` 未宣称 thinking 则注入探针
→ `modalities`（config 卡覆盖优先，否则默认 vision:true）→ `role:"router"`
（`LMR_UI_ROUTER_MODE` 默认开，false/0/off 关）→ `n_ctx`/`n_ctx_train` 用
ctx cap 覆写（cap 键用 UI 请求的原名/别名，同 Rust cap_model）。
全部 worker 3s cosocket 超时；全失败 → 合成
`{model_path=解析后的 wanted 或首模型或 "unknown", model_alias:null,
webui_version:"llm-router"}` 再过改写链。

## 5. config_store 行为对齐要点

- 存储层级：`ngx.shared.luarouter_config`（JSON 快照）→ `LMR_CONFIG_FILE`
  （原子 tmp+rename，父目录自动 mkdir）→ env 基线（`LMR_*` 全套，解析规则同
  Rust，含 `LMR_MODEL_EFFORT_MAP=model:from>to`、`LMR_MODEL_MODALITIES=model:cap+cap`）。
  写路径同时刷新 dict + 文件，多 worker 立即可见（实测 2 worker 一致）。
- 校验/报错文案逐字对齐 Rust：八档 `none..ultra`；`unknown effort: X (want one
  of ...)`、`model_ctx for X must be greater than zero`、`virtual model X must
  differ from its target` 等；JSON `null`＝清除、缺字段＝不动（apply_document
  除外：整档替换，缺段清空）。cjson 无法区分 `{}` 与 `[]`，空表按数组处理、
  纯 hash 表按非数组拒绝（`is_array`）。
- 成功响应＝改后完整文档（`document()`：快照 + `env_defaults` + `watcher`
  `{url,reachable,model_map}` + `persist.file`）；`config/model`、`config/get`、
  `config/apply` 额外带 `models` 派生段（registered/sources/ctx/default_effort/
  effort_map/modalities/target）。
- `config/model-map` 代理 watcher `{LMR_WATCHER_URL}/model-map`（GET 3s 拉表，
  POST 5s 转发，对齐 Rust reqwest 超时）；未配置 →
  503 `{"ok":false,"error":"watcher not configured (set LMR_WATCHER_URL)"}`，
  watcher 失败 → 502 `{"ok":false,"error":"watcher said <status>: <detail>"}`；
  成功时把 watcher 原文档加 `ok:true` 返回（对齐 Rust；apply 路径的
  `watcher_model_map` 则保留 watcher 原文不加 ok，同 Rust）。
- `apply` 的可选 `model_map` 段：object 或 `orig:new` 字符串，失败降级为
  `warning` 字段（不回滚已应用的文档主体，同 Rust）。

## 6. observability 桥（core 侧待实现/在建）

ui.conf 已转发，桥在 `ui.lua`：`require("resty.luarouter.observability")` 存在
且函数在 ⇒ 直接调用；否则 503 `{"error":"request log not enabled"}`（与 Rust
`request_log_disabled()` 同形）。接口契约：

```lua
function observability.handle_logs() end         -- GET /_ui/logs?cursor=&limit=
function observability.handle_logs_stream() end  -- SSE 广播 + 15s keep-alive ping
function observability.handle_stats() end        -- GET /_ui/stats
function observability.handle_backends() end     -- GET /_ui/logs/backends -> {backends:[{url,model,gpu}]}
```

（注意 handler 名即 require 后的模块函数名；ui.lua 分别经
`_M.logs/logs_stream/logs_backends/stats` 转接，SSE 的 15s ping 属 observability
内部实现。）

## 7. 测试与验证记录

`openresty -t`（目标镜像 authz:latest = openresty/1.31.1.1）：core 的
`test/conf/nginx-lua-router.conf` 尚未落库时，用等价最小 conf 以
`include /repo/conf/ui.conf;`（绝对路径）验证通过（syntax ok /
test successful，见本轮交付说明）。

行为回归（本机 authz:latest 起真实 nginx + mock_llm_worker + fake watcher，
46 项断言全绿）：props 代理与兜底合成、别名解析、ctx cap 注入、thinking
探针、modalities 覆盖、load/unload/slots/tools/lookup/control/stream 固定
响应、chat 填充模型/清洗 effort/坏 body 400、config 全家校验与响应形状、
model-map 代理成功/503、apply 整档替换与 warning、持久化 reload、坏文件回退
env、多 worker 一致、SSE 30s ping 实测、错方法 405、静态 alias+实时 gzip。

已知差异（对齐度评估后保留）：worker /props 返回 2xx 但 body 非 JSON 时，
Rust 原样透传文本，本实现视作失败继续下一候选（cjson 不允许直接吐脏文本进
JSON 通道，且该分支在真实部署中不可达）。
