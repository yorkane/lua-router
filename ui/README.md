# llama.cpp webui bundle

来自 llama.cpp 官方发布包 `llama-b11215-ui.tar.gz`，解包后就地打两处补丁：

1. `watcher/patch_ui.sh` —— 把相对 API 路径（./v1/... ./props）改写成绝对 /_ui/... 前缀，
   让静态 ServeDir 下的页面能命中 router 的 /_ui 别名路由。
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
bash ../watcher/patch_ui.sh ui
bash ../watcher/patch_ui_effort.sh ui
node --check _app/immutable/bundle.*.js   # 校验补丁未破坏语法
```

两个脚本都幂等；若上游改了混淆变量名导致 anchor 失配，脚本会 assert 失败（而非静默跳过）。
