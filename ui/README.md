# llama.cpp webui bundle

来自 llama.cpp 官方发布包 `llama-b11215-ui.tar.gz`，解包后就地打两处补丁：

1. 接口路径：webui 保持官方原版（相对路径 fetch 根路径），**不再做 /_ui/ 前缀改写**。
   2026-10-08 起 router 侧 `/_ui/` 入口全部取消，页面从 `/u/` 挂载、请求根路径接口：
   `/v1/chat/completions`、`/v1/chat/completions/control`、`/v1/stream`、`/v1/streams/lookup`
   与 `/props` 均由 conf/ui.conf 的 exact location 提供；`/tools`、`/models/unload` 等本来就是相对路径。
   （历史上 `watcher/patch_ui.sh` 曾把这些相对路径改写成绝对 /_ui/... 前缀以配合当时的别名路由，
   该做法已随 `/_ui/` 入口一并作废；bundle 里残留的 6 处 `/_ui/` 前缀已改回根路径。）
2. `watcher/patch_ui_effort.sh` —— 让思考强度（thinking effort）选择器在 router 后面真正可用：
   - 取值补齐：官方 default/off/low/medium/high/max 之外补 none / minimal / xhigh / ultra
     （枚举 + 选项数组 + 预算表三处都要改，少一处就会出现"有选项但选了没效果"）。
   - 让选择器改发顶层 `reasoning_effort`：官方实现只把它折算成
     `thinking_budget_tokens` + `chat_template_kwargs.enable_thinking`，而后端（ninfer / vllm / sglang）
     一律以 400 chat_template_option_not_supported 拒绝 chat_template_kwargs，
     于是"选任意一档都会报错"。改后：Default(null) 什么都不发（后端自定），
     off/none 发 `reasoning_effort: "none"`，其余档位原样透传。
   - 给 sw.js 里被改过的 bundle 固定 precache revision（官方是 revision:null，
     等于"URL 就是版本号"，重新部署后 service worker 会继续喂旧 bundle）。
   注意各档是否被接受由后端决定：<gpu-box-217> 的 ninfer 只认 none/minimal/low…max 中模板声明的那些，
   选了不支持的档位会把后端 400 原样显示，不会静默改参数。
3. 选择器的显示开关是 `modelSupportsThinking`：llama-ui 靠 /props 的 `chat_template` 里是否出现
   `enable_thinking` / `reasoning_effort` / `<|im_start|>` 来判断。ninfer 等非 llama.cpp 引擎的
   /props 不回传 chat_template，于是整条选择器被隐藏。这个能力问题改由 router 回答：
   `ui_props_with_thinking()`（watcher/patches/ui/handlers.snippet）在后端没有声明时补一个标记。
   不要用 router mode 绕：llama-ui 只有 /props 返回 `role:"router"` 才进 router mode，
   而那个模式还会去要 /models/sse 与模型加载/卸载接口，router 不提供，结果模型列表显示空。

升级方法：用新版 *-ui.tar.gz 覆盖 ui/ 后，依次重跑：

```bash
bash ../watcher/patch_ui_effort.sh ui
node --check _app/immutable/bundle.*.js   # 校验补丁未破坏语法
```

`patch_ui_effort.sh` 幂等；若上游改了混淆变量名导致 anchor 失配，脚本会 assert 失败（而非静默跳过）。
覆盖后务必核对 `ui/sw.js` 里该 bundle 的 precache revision 等于新的 `md5sum` 值，否则 service worker 继续喂旧 bundle。
