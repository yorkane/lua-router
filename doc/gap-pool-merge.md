# 服务池页（运行态与声明态统一视图）

日期：2026-10-02。决策人：用户「服务池 和 远程服务 功能重叠，合并成一个」。

## 1. 为什么合并

原来两个页面看的是**同一批服务**的两种状态：
- **服务池**（`workers.html`）：运行态，来自 `GET /workers`，即池里此刻真实存在的条目。
- **远程服务**（`upstreams.html`）：声明态，来自 `/_ui/config` 的 `upstreams` 段，即希望长期存在的池成员。

分开时会出现两个编辑面看同一份声明、且各自的「事实来源」互相打架（见 §4）。合并后**一个地址一行**，
归属用徽章讲清楚。

## 2. 合并后的结构

两个数据源各自独立轮询（池 3s、声明层 20s），由纯函数 `mergeRows(workerRows, declRows)`
按**规范化 URL**（折叠尾斜杠 + 大小写）做**全外合并**。每行携带三个来源：
`decl`（原始声明条目，写回时 clone 保真）、`pool_*` 与 `decl_*` 两份上限值。

三种归属：

| 归属 | 判定 | 显示 | 编辑入口 |
|---|---|---|---|
| `declared` | 有声明 **且**（未入池 或 池行 `discovery === 'config'`） | 声明值 | 「编辑声明条目」→ `POST /_ui/config/upstreams` |
| `runtime` | `discovery` 不是 config（watcher / 手工 / bootstrap） | 池值 | 「编辑运行属性」→ `PUT /workers/{id}` |
| `shadowed` | `cap_owner !== 'declared'` 但仍有声明 | 池值 + 按字段类别分档的归属徽章（见下） | 同 runtime |

`shadowed` 不是一枚红色到底：这一行要按**字段类别**分两半读，因为后端对这两半的口径不同。三档上限
（`CAP_FIELDS` = `min_concurrency` / `max_concurrency` / `max_gpu_util`，
`config_store/upstreams.lua`）对 protected 行是**可投影**的：`reconcile_upstreams` 的 protected 分支用
`upstream_caps_only_patch` 把声明里写了的那几档行级写回池记录（自愈计时器 30 秒一轮，
见 `init.lua` 的 `RECONCILE_INTERVAL_SECS`），因此活得过容器重建；执行面读的
正是池记录上这几个字段（`registry/loads.lua` 的 `capacity_verdict` 判定、
`router/candidates.lua` 的 `candidates_for` 硬排除），写进去即生效。身份与调度意图字段仍然惰性：
`model_id` / `models` / `labels` 会被 `registry.update` 里那道 `current.discovery == "config"` 的门
（`registry/discovery.lua`）丢掉，`priority` / `cost` 根本不进 caps-only 补丁，密钥存在位则单独
标成灰徽章 `key_inert`：同地址被他人持有时，声明对它们是「说了不算」。

徽章跟着上限的实际状态分三档（文案以 `ui/admin/i18n.js` 的这三个键为准）：

| 上限状态 | 徽章 |
|---|---|
| 池记录归一后与声明一致 | 青色「上限按声明 · 投影生效」（i18n `capProjected`） |
| 还有差（等自愈写回） | 琥珀「等自愈 · 上限未跟上」（`capProjectedDrift`） |
| 声明对三档一个都没写 | 红色「声明管不到这行」（`capShadowed`）——这句话只关于身份与模型 |

「watcher 抢先 → 声明惰性」只对第二类字段是稳态、不是竞态；三档上限那一半已于 2026-10-04（提交
`3728821`）改成自愈按声明写回，口径见 [gap-worker-caps.md](gap-worker-caps.md) §11 第 4 项。protected 行的
判漂移与下补丁都只看 caps，是为了让永远改不动的身份字段不把自愈拖进死循环，理由写在
`config_store/upstreams.lua` 的 `upstream_caps_only_patch` 注释里。显示层曾与此相反——徽章自
2026-10-02（`80eaf3f`）起把整个 protected 行判红、tooltip 连带宣布声明里的上限也没生效，操作员因此把
配好且已生效的并发/利用率读成失效配置，现按上面这张表分档修正。

添加对话框有双模式（持久化进声明 / 仅注册进池）；后端无 `upstreams` 段时默认档落到 runtime
并把声明档置灰。

## 3. JSON 往返与整表替换

- 保存唯一出口 `saveDecls` 先**重取整表**（`loadDeclsQuiet`）再改，只替换目标条目。
  首次拉取失败时 `decls` 会停在空数组，此时保存 = 用单条覆盖整表，其余声明连 config 池行
  一起被 reclaim —— 这是本轮修掉的一个真 blocker（B1）：刷新失败或后端不支持时**一律拒绝保存**。
- 定位条目用**打开时的快照键**（`declSelfKey`），不是输入框里的新地址。用新地址定位会让
  「改 URL」变成「新增一条 + 旧条目成幽灵继续被自愈投影进池」，且表单未画的字段全丢（B2）。
- JSON 面板缩表 / 清空前弹确认（等长与扩表不打扰）——注释声称「UI 自带确认」但第一版没做（B3）。
- `api_key` 三态：缺席=保持、`""`=清除、填值=设置；回显恒走存在位，两个密码输入框，
  手写存在位直接报错而非静默删。

`POST /_ui/config/apply` 是**整表替换**语义：只发一段会把其它段清空。合并页的所有写路径
都基于刚拉取的整表，页面顶部横幅与 JSON 面板文案都明说了这点。

## 4. 上限的事实来源

`max_concurrency` **以声明层为准**。原因：`upstream_drifts` 把
`max_*` 连同 priority / cost / labels / disable_health_check 一并比较，所以运行态
`PUT /workers/{id}` 改的值会在 30 秒自愈里被声明值写回——**只锁上限字段是不够的**，
改 priority 照样被抹。

因此 `cap_owner === 'declared'` 的行，**运行态编辑入口整体隐藏**（不止上限），提交路径还有第二道
防御拒绝。UI 用归属徽章 + tooltip 明示（判定按「字段类别」分档，见 §2）：
- 「等自愈 · 与声明不一致」= 声明层拥有这一行（`discovery === 'config'`）而池值与声明有差，等自愈收敛；
- 「上限按声明 · 投影生效」/「等自愈 · 上限未跟上」= 来源不是 config，但声明对三档上限有主张：自愈按 caps-only 投影把它
  写进池记录，执行面按池记录上那个数选路，所以只差未收敛时是「等一下」而不是「不生效」；
- 「声明管不到这行」= 来源不是 config **且**声明对三档上限一个都没写；惰性的只有身份与模型那类字段；
- 运行态对话框顶部 warning 说明「在这里改会在 30 秒内被自愈按声明值覆盖」。

后端根治（尚未做）：把 `upstream_patch` 的「声明缺席 → 显式下发 0 撤上限」改成「缺席=不碰」，
让撤除改由 UI 的显式「不限」勾选发 `null` 表达。**这要后端与 UI 两处一起改**——
缺席=保持原值虽然更干净，但会让「清空输入框」不再等于撤除。

## 5. 引用清理

- 导航顺序：**模型管理 → 服务池 → 路由策略 → 日志**（`ui/admin/app.js` 的 `pages`）。
- `upstreams.html` **文件保留但缩成 24 行重定向占位**（meta refresh + `location.replace`）：
  直接删会让老链接 404；保留 655 行旧页面则会造成「同一份声明层两个编辑面持续分叉」。
- 旧锚点 `#upstreams.html` 经 `legacyPages` 落到合并页而不是 404 回首页。

## 6. 已知限制

1. 上限互踩在**声明层**与**运行态**之间仍然存在（§4 后半），只是被 UI 变成「可见且不可触达」。
2. 声明改名时若新地址已被第三方持有，会被拒并提示——不会静默产生幽灵条目。
3. `mergeRows` 的归属判定已有 quick 档 node 单测覆盖（`test/unit/test_ui_merge.mjs`，从盘上
   html 抽真函数执行，判别性通道 `LR_UI_HTML` 可指向旧源码核实断言真会红）；`saveDecls` 的
   整表语义仍只有开发期自查脚本覆盖，仍值得补进 quick 档。

