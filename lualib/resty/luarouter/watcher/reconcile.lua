local _M = require "resty.luarouter.watcher"
local env_mod = require "resty.luarouter.watcher.env"
local cjson = require "cjson.safe"

-- cjson 的 JSON null 哨兵抓成 file-local：「这条池行对卡号有没有已经说过话」那一判
-- （row_gpu）每 tick 每候选都要跑一次，热路径不查表。
local cjson_null = cjson.null

-- watcher/reconcile.lua -- the guards single decision point.  The whole
-- reconcile() function lives here *undivided*: the comment above it in the
-- original (watcher.lua 1394-1399) is exactly why -- "why did that
-- worker leave" must have one answer site.  The probe-verdict
-- pre-pass (decide the whole pass before the first delete), the fuse
-- denominator (the owned total read before deletions shrink it) and the
-- hysteresis counters interlock; splitting this further would break the
-- auditability doc/gap-watcher-merge.md 1.1 pins.  Do not decompose this
-- file.

-- ------------------------------------------------------------------ reconcile
--
-- What the daemon does here and the Lua version does not: a *mixed-model warning*.
-- The daemon logged one because the Rust gateway ignores the requested model when it
-- picks a worker in single-router mode (README measured 10/10 requests naming the
-- local model served by a remote one), so a heterogeneous pool silently mis-routes.
-- This router cannot mis-route that way - candidates_for(model) filters by
-- record.model_id (router.lua:987), and a request naming an unregistered model gets a
-- 404 rather than a random worker - so the warning has nothing to warn about and was
-- deliberately not ported. doc/gap-watcher-merge.md lists it as the one README
-- behaviour with no Lua counterpart.

local function warn(log, message)
    if type(log) == "function" then
        log("warn", message)
    end
end

local function notice(log, message)
    if type(log) == "function" then
        log("notice", message)
    end
end

---warn/notice 的 DEBUG 档兄弟。GPU 归属标注的「没写成」走这一档：registry 那侧底下是
---resty.lock + JSON 编解码，一处持续失败会以每 tick 每 worker 一条的频率刷进 error.log，
---而那条路径的失败上限本来就只是"没标上"。报警信号是 pass 计数（stats），日志只是查因线索。
local function note_debug(log, message)
    if type(log) == "function" then
        log("debug", message)
    end
end

--- 「禁用」判定的取用接缝（用户裁定 2026-10-09：watcher 的注册与摘除从 hidden 改读
--- disabled；另两处联动：/v1/models 广告读两条、路由候选只读 disabled）。**判定本身只有
--- 一份**，住在 config_store（readers.lua 的 model_is_disabled：卡片 disabled=true 或
--- 虚拟入口 disabled=true 即算禁用），本函数只负责「取不取得到」。
---
--- hidden **不再**进来（2026-10-09 收窄）：操作员勾了「隐藏」的模型继续被注册、被保留、
--- 被发现 —— 隐藏只关广告面，watcher 把它摘掉会让「不对外广告但继续服务」变成「停止服务」，
--- 那是 disabled 那句话。
---
--- 返回 nil = 「无从知道」= 没有任何名字被禁用，调用方据此整条禁用逻辑短路成今天的
--- 逐字节行为。三种情形都落到 nil：config_store 缺席（未装配的 build / 裸 luajit 探针 ——
--- test_watcher 那份单测就是这么跑的）、reader 缺席（半程发布的旧 build）、整表判据
--- 答「没人说过禁用」（生产上绝大多数 tick 走这一条，一次哈希读，不构造名册）。
---
--- 刻意**不是** `() -> boolean`：先取一次闭包、再在循环里问，比每个候选都 require + pcall
--- 便宜，而且把「取不到」与「取到了但没人禁用」在形状上分开（nil vs 函数），日志和
--- 探针都分辨得出「配置没生效」与「配置说不用摘」。
---
--- pcall 包住 require 而不是裸调：config_store 加载期会 require 一串重模块，一处抛错
--- 不该让整轮 reconcile 少跑一步（AGENTS.md 硬规则 4 的同一姿态 —— 读数拿不到只是
--- 没精度，绝不摘 worker）。
---@return fun(name: string): boolean|nil|nil
function _M.disabled_reader()
    local ok_store, store_mod = pcall(require, "resty.luarouter.config_store")
    if not ok_store or type(store_mod) ~= "table" then return nil end
    if type(store_mod.any_disabled) ~= "function"
        or type(store_mod.model_is_disabled) ~= "function" then
        return nil
    end
    local ok_any, flagged = pcall(store_mod.any_disabled)
    if not ok_any or flagged ~= true then return nil end
    return function(name)
        if type(name) ~= "string" or name == "" then return false end
        local ok_ask, verdict = pcall(store_mod.model_is_disabled, name)
        if not ok_ask then return false end
        return verdict == true
    end
end

---Is `url` the only remaining worker of `model_id`? (_is_last_for_model)
---An unhealthy sibling does not count as coverage.
---@param model_id string
---@param url string
---@param actual table @ url -> {model_id=, is_healthy=}
---@return boolean
function _M.is_last_for_model(model_id, url, actual)
    if not model_id or model_id == "" then
        return true
    end
    for other_url, item in pairs(actual or {}) do
        if other_url ~= url and tostring(item.model_id or "") == model_id then
            if item.is_healthy ~= false then
                return false
            end
        end
    end
    return true
end

---Confirm the adds we queued and release the stuck ones (guard 7).
---
---The daemon had to wait for the router's async AddWorker job: a 202 only meant
---"queued", and a job parked on a dead URL squatted the URL forever (every retry
---said "already exists"), so it deleted the worker to free it. Registration here
---is a direct registry.add, so a worker is live the moment we return; what is
---still worth reaping is a ledger entry whose URL has left the pool behind our
---back (a hand DELETE, or an add that never landed), which would otherwise keep
---the URL claimed and the model advertised as if it had a worker.
---@param state table @ {cfg, ledger, now, actual}
---@return table @ live pending urls (still waiting, excluded from this pass)
function _M.reap_pending(state)
    local ledger, now, actual = state.ledger, state.now, state.actual
    local live = {}
    for url, pending in pairs(ledger.pending_urls()) do
        if actual[url] then
            -- Confirmed: the pool carries it, so the ledger takes the live id.
            ledger.drop_pending(url)
            ledger.drop_backoff(url)
            local entry = ledger.get_owned(url)
            if entry then
                entry.worker_id = tostring(actual[url].id or entry.worker_id or "")
                entry.missing_since = nil
                ledger.set_owned(url, entry, state.entry_ttl)
            end
        else
            local age = now - tonumber(pending.queued_at or now)
            if age <= state.cfg.add_confirm_timeout_secs then
                live[url] = true
            else
                notice(state.log, string.format(
                    "watcher: add for %s never reached the pool after %.0fs; releasing the URL",
                    url, age))
                -- The id the add returned may still be in the pool under a
                -- different URL spelling (a DP expansion replaces the base
                -- entry): registry.remove answers "not found" for anything gone,
                -- so trying is safe and releases the URL either way.
                if pending.worker_id then
                    state.unregister(tostring(pending.worker_id))
                end
                ledger.drop_pending(url)
                ledger.drop_owned(url)
                state.stats.adds_stuck_released = state.stats.adds_stuck_released + 1
            end
        end
    end
    return live
end

---Is this URL's pool row a config_store-declared upstream? Config members are
---immune to every watcher mutation: no ledger reclaim, no keep-last clearing,
---no model-map rename, no removal (doc/gap-virtual-models.md 3.2). The live
---pool row is the authority, so a URL whose row vanished is *not* immune (the
---removal loops need to clean the ledger entry the old way).
---@param state table
---@param url string
---@return boolean
function _M.is_config_member(state, url)
    local live = state.actual[url]
    return type(live) == "table" and live.discovery == "config"
end

---One-line DEBUG summary for a skipped config member, through the testable
---state.log sink so the pure layer stays ngx-free.
---@param state table
---@param url string
---@param action string
local function note_config_skip(state, url, action)
    if state.log then
        state.log("debug", string.format(
            "watcher: skipping config-declared upstream %s (%s; config_store owns it)",
            url, action))
    end
end

_M.note_config_skip = note_config_skip

------------------------------------------------------------------ gpu 归属补给
--
-- 这一节是**纯 label 补给**：把发现层从容器名解析出来的卡号（discover 的
-- _M.gpu_from_name → 候选的 gpu 字段）落到**已经在池里**的那条 worker 记录的
-- labels.gpu 上。它存在的理由是 21.k 的实际形状：八个 sglang 实例由 compose 的
-- SMG_WORKER_URLS 播种进池（registry.discovery.bootstrap → registry.add({url=…})，
-- 一个 labels 都不带），容器名却把卡号写在脸上（qwen38-27b-dflash-tgt-gpu0 …
-- pennyroyal-orca-gpu7）。播种的下一拍守卫 3 就把池里已有的行整排 protect 掉
-- （日志：watcher: protecting 8 pre-existing worker(s)），于是
--   * register 对它们永远不会被调用 —— make_register 里 `if entry.gpu then
--     labels.gpu = entry.gpu` 那一段是 watcher 唯一一处写 labels.gpu 的地方，
--     对 protected 行一次都没执行过；
--   * registry.add 的幂等分支对重复 URL 只回一条 failed job 就 return，**不碰记录**
--     （registry/records.lua 的 add），所以「再 add 一次把 labels 带上」这条路在盘上
--     不成立；
--   * reconcile 对 protected 行只做 model-map rename（本文件 protected_seen 那一圈），
--     从不认领发现层的元数据。
-- 三条链合起来的结果就是 labels 恒空：/_ui 的卡号徽章不亮，gpu_load 的逐卡 util 归属
-- 也只有 ledger 的 g|<url> 提示可依（逐卡归属先读台账提示、再读记录 labels.gpu）。
--
-- 为什么补 label 不违反守卫 3（「不改操作员/环境已经声明过的东西」）：守卫 3 保护的是
-- **路由身份与调度判定** —— URL、model_id、健康位、熔断、优先级、权重、DP 展开、并发与
-- 利用率上限；改这些会改变「谁被选中、选中之后被怎么对待」，而这些正是操作员或环境写进
-- SMG_WORKER_URLS / PUT /workers / 声明层的读数。labels.gpu 不在其中：本函数一次只写
-- labels 里的 gpu 这一个键（registry.update 的 labels 支是**合并**语义，见
-- registry/discovery.lua 的 changes.labels 注释），写下去的读数来自**对方容器的名字**，
-- 是网关自己看见的事实，不是对操作员陈述的覆盖。三条护栏把这条论证钉在代码里：
--   * **已有值绝不覆盖**：行里已经带 labels.gpu（哪怕是操作员手写的 "all" 这类非数字
--     形状）就跳过 —— 操作员声明优先；非数字值也不去动它，逐卡匹配那条既有降级路径
--     （解析不出卡就不归属、不封顶）原样保留；
--   * **config 行整体不碰**：_M.is_config_member 那一判排在写之前。声明层行的 labels
--     归 config_store 所有，而 registry.update 对 config 行会把整个 labels 表**替换**成
--     文档里那一份（labels_replace），从 watcher 发一次「只带 gpu」的补丁等于让一次
--     监控补齐去清空操作员声明的 label 集 —— 那是越权，直接不写；
--   * **失败只是没标上**：写不进去不影响发现、探针、摘除、宽限 —— 本函数的返回值不喂给
--     上面任何判定，也不读它们的结论，计数只进 stats。
--
-- 写入走 registry 侧既有的 labels 写入接口（live.lua 的 make_patch_labels →
-- registry.update 的 labels 支 → registry/records.lua 的 patch_record），不另开写路径，
-- 于是合并语义、锁、mesh 镜像、derived 标记的重算都是现成的那一份。

---池行现在带的是哪张卡：`labels.gpu` 的**原始**值，未经数字收窄。
---
---故意不做 gpu_load.parse.worker_gpu 那样的「只认纯数字」收窄：这一判的职责是「这条记录
---对卡号有没有已经说过话」，任何非空值都算说过（操作员写的 "all" 也是一句陈述，不许被
---监控层覆盖）。cjson 的 null 哨兵算「没说过」——历史上有的写路径会把缺失落成 JSON null。
---@param record table|nil @ 池行（actual_pool 的形状，带 labels）
---@return string|nil @ 有值时返回它的字符串形态，否则 nil
local function row_gpu(record)
    if type(record) ~= "table" then
        return nil
    end
    local labels = record.labels
    if type(labels) ~= "table" then
        return nil
    end
    local value = labels.gpu
    if value == nil or value == false or value == cjson_null then
        return nil
    end
    local text = tostring(value)
    if text == "" then
        return nil
    end
    return text
end

_M.row_gpu = row_gpu

---发现层给的卡号能不能落到 labels 上：只收纯数字串。
---
---discover 的 gpu_from_name 本来就只产数字串，这一判是挡住注入形状（未来的新来源、或
---夹具里的假候选）把 "nvidia0" / UUID 之类写进 labels.gpu —— 那种值 gpu_load 的逐卡匹配
---永远对不上，等于用一条永远用不上的读数占住「已声明」的位置、把能用的那条挡在门外。
---@param gpu any
---@return string|nil
local function usable_gpu(gpu)
    if type(gpu) ~= "string" then
        return nil
    end
    if string.match(gpu, "^%d+$") then
        return gpu
    end
    return nil
end

---把本轮候选带来的卡号补给**已在池中**的记录（owned 与 protected 一视同仁）。
---
---只在「本轮该 URL 探到了（进了 sources）且候选认得它的卡、而池行自己还不带卡」时发一次
---patch；patch 成功后池行已经带 gpu，下一 tick 第一条判据就不成立，于是稳态每 tick 的成本
---是每个候选几次表查找，不发任何写。刻意**不**在探针失败的候选上补卡：那一行本轮对
---/v1/models 什么都没说出口，把 label 补给一条正在被摘除链处理的行，只会让「这条记录说的
---是谁」在宽限期里多一份说不清的读数（ledger 的 g| 提示同口径 —— 它也只在探到之后写）。
---
---@param state table @ reconcile 的 state（读 actual / candidates / patch_gpu_label / log / stats）
---@param sources table @ url -> true：本轮探到的候选集合（discovered 的 URL 集）
---@return number patched @ 本轮真正写成的条数
function _M.annotate_gpu_labels(state, sources)
    local patch = state.patch_gpu_label
    if type(patch) ~= "function" then
        -- 纯层夹具（test/unit/test_watcher.lua 的 harness）不注入这条接缝：没有写入
        -- 后端就等于这件事没人做，静默返回，不动任何既有断言。生产由 live.run_pass 注入。
        return 0
    end
    if type(state.actual) ~= "table" then
        return 0
    end
    local stats = state.stats
    local patched = 0
    for i = 1, #(state.candidates or {}) do
        local cand = state.candidates[i]
        local url = type(cand) == "table" and cand.url or nil
        if url and sources[url] then
            local gpu = usable_gpu(cand.gpu)
            local row = state.actual[url]
            -- 顺序即代价：先看候选有没有话说（绝大多数没有），再看池行缺不缺，
            -- 最后才可能摸一次 registry。
            if gpu and row and row_gpu(row) == nil
                and not _M.is_config_member(state, url) then
                -- 逐条 pcall：一条记录写入抛出来（registry 底下是 lock + 编解码 + shdict）
                -- 只让**这一条**没标上，本轮其余候选与后续守卫照跑。外层 reconcile 那里
                -- 还有一层 pcall 兜底，两道都不许把异常递给调用方。
                local okp, ok, err = pcall(patch, url, tostring(row.id or ""), gpu)
                if not okp then
                    ok, err = false, tostring(ok)
                end
                if ok then
                    patched = patched + 1
                    -- 把这一轮的结论就地写回这一行的视图：同一次 pass 里同一条记录不可能
                    -- 被发第二次 patch（重复 URL 的候选也走这条 memo），生产的 actual 是本轮
                    -- 现读的快照，改写它不影响任何外部状态。
                    row.labels = type(row.labels) == "table" and row.labels or {}
                    row.labels.gpu = gpu
                    note_debug(state.log, string.format(
                        "watcher: labelled %s with gpu %s (from container name)", url, gpu))
                else
                    stats.gpu_label_fails = (stats.gpu_label_fails or 0) + 1
                    note_debug(state.log, string.format(
                        "watcher: gpu label for %s not written: %s",
                        url, tostring(err or "patch refused")))
                end
            end
        end
    end
    if patched > 0 then
        stats.gpu_labels_patched = (stats.gpu_labels_patched or 0) + patched
    end
    return patched
end


---One reconcile pass. Everything outside this function is plumbing, which makes
---the guards above auditable in one place and testable with fakes -- including the
---probe-verdict pre-pass below, which deliberately stays inside this function so
---"why did that worker leave" has exactly one answer site.
---
---@param state table @ {cfg, ledger, actual, candidates, probe, register,
---                       unregister, now, stats, log}
---@return table @ the (mutated) stats
function _M.reconcile(state)
    local cfg, ledger, now = state.cfg, state.ledger, state.now
    local stats = state.stats
    stats.reconciles = stats.reconciles + 1

    -- Guard 3: on first contact every worker already in the pool was configured
    -- by someone else (SMG_WORKER_URLS or a human), so protect it permanently.
    if not ledger.touched() then
        local protected = ledger.protected_urls()
        local owned = ledger.owned_urls()
        if next(protected) == nil and next(owned) == nil then
            for url in pairs(state.actual) do
                ledger.protect(url)
            end
            ledger.mark_touched()
            if next(state.actual) ~= nil then
                notice(state.log, string.format("watcher: protecting %d pre-existing worker(s)",
                    (function()
                        local n = 0
                        for _ in pairs(state.actual) do n = n + 1 end
                        return n
                    end)()))
            end
        end
    end

    -- Discovery + strict probe.
    local discovered = {}
    -- A URL we looked at and could not confirm is not "absent from discovery": the
    -- strict probe wants a real /v1/models answer with data[].id, and without that
    -- the service cannot answer a request. What we must NOT do is treat every
    -- rejection as the same evidence, so the set carries classify()'s reason and the
    -- verdict derived from it (see probe_verdict): a deterministic "this is not a
    -- worker" answer evicts in the same pass, a transport-level unknown accumulates
    -- entry.probe_fails and only evicts once it repeats.
    local probe_failed = {}
    -- Reasons that say more about the gateway than about the service (no transport,
    -- require_health admission): this pass says nothing about the URL, so the entry
    -- keeps its missing_since clock and its counter untouched.
    local probe_ignore = {}
    for i = 1, #state.candidates do
        local cand = state.candidates[i]
        if cand and cand.url and not _M.is_self_url(cand.url, cfg.self_ports)
            and not _M.is_excluded(cand.url, cfg.exclude_patterns) then
            local info, reason = state.probe(cand.url)
            if info then
                info.label = cand.label or info.engine
                info.source = cand.source
                info.gpu = cand.gpu
                -- 卡号进台账：g| 键与 register/protect 无关，所以保护行（bootstrap 播种的
                -- SMG_WORKER_URLS 那八个）也拿得到。认不出卡时同样调用一次 —— 传 nil 是
                -- 删键，免得上一轮容器改名后留下过期卡号，把好端端的读数接到别的卡上。
                if ledger.set_gpu_hint then
                    ledger.set_gpu_hint(cand.url, cand.gpu)
                end
                discovered[#discovered + 1] = info
            else
                local verdict = _M.probe_verdict(reason)
                if verdict then
                    probe_failed[cand.url] = { reason = reason, verdict = verdict }
                else
                    probe_ignore[cand.url] = true
                end
            end
        end
    end
    stats.discovered = #discovered

    -- GPU 归属补给（纯 label；为什么这事不违反守卫 3，见本文件「gpu 归属补给」一节的论证）：
    -- 本轮探到的候选里，凡是「候选认得卡号、池行自己还不带卡」的，补一次 labels.gpu。
    -- 位置排在守卫 3 的快照**之后**：首接触那一拍先把池里已有的行整排 protect 掉，而那八条
    -- 正是等着被补标注的对象；也排在 adds / renames / removals 之前 —— 补给与它们互不通信，
    -- 既不读它们的结论，也不把任何结论喂给它们（摘除判定看到的状态与本轮有无 patch 无关）。
    -- sources 只收本轮探到的 URL：探针没答上的那批留给 g| 台账提示（同口径），不写记录。
    local probed_urls = {}
    for i = 1, #discovered do
        probed_urls[discovered[i].url] = true
    end
    -- 整段套 pcall：这是「补给」不是「判定」，一条 label 写不写得成都不能让本轮的守卫
    -- 少跑一步（registry 底下是 lock + 编解码，任何一处抛出来都只是没标上，
    -- 下一 tick 自然重试）。
    local annotated, ann_err = pcall(_M.annotate_gpu_labels, state, probed_urls)
    if not annotated then
        note_debug(state.log, string.format(
            "watcher: gpu label pass skipped: %s", tostring(ann_err)))
    end

    -- desired = discovered - protected (guard 3 again, from the other side).
    local desired, protected_seen = {}, {}
    -- 「禁用」（用户裁定 2026-10-09）在 watcher 侧的联动（另两处：/v1/models 广告读两条、
    -- 路由候选只读 disabled），判据只有一份：config_store 的 model_is_disabled（卡片或入口
    -- 任一说了 disabled=true）。hidden **不**在这里问：被藏起来的模型继续注册、继续保留、
    -- 继续被发现 —— 隐藏只是不对外广告，服务照旧。
    --
    -- 位置刻意排在守卫 3 的 protected/desired 分流**之后**、Adds / renames / Removals
    -- **之前**，一次过滤改动三支：被禁用的 URL 不进 desired（于是 Adds 的注册侧跳过是
    -- **结构性**的 —— 循环根本到不了它，Renames 也无从谈起），已注册的行由 Removals
    -- 那一圈的专属分支摘掉。protected_seen 一并过滤是刻意的：被禁用的行如果继续被当
    -- protected 喂给 rename 那一圈，会把一台操作员刚宣布不服务的实例又 adopt 一遍。
    --
    -- 摘除走 _M.release 这**同一个**出口（见下面「禁用即摘」那一支）：台账清理、
    -- drop_pending / drop_backoff、removes 计数、pass 日志全是现成的那一份，不新增
    -- 摘除判据；allow_remove 那一道保险照旧在前。刻意**不**借 undiscovered 那一支的
    -- remove-grace 时钟与 keep-last 保险 —— 前者会让「勾了禁用」要等几分钟才在 /workers
    -- 上见效（操作员会以为没生效），后者会让「这个模型只剩这一台」把操作员的明确意图
    -- 顶回去。两者的理由都写在下面那一支里。
    --
    -- 读数拿不到就**不禁用**（store 缺席 / reader 缺席 / pcall 出错 → nil = 没有任何名字
    -- 被禁用），与硬规则 4 同一姿态：一次读不出的配置声明绝不该摘掉一台在服务的实例。
    -- 每 tick 只问一次整表判据；没人说过禁用时下面三个函数各自短路成今天的逐字节行为。
    local disabled_asked = _M.disabled_reader()
    --- 按**注册用的那个名字**问（= 操作员在 /_ui 与 /v1/models 上看到的名字）。
    --- 卡片的键是那个名字而不是引擎自报的原文，所以问之前必须过一遍与 Adds 循环
    --- 逐字相同的解析（_M.model_name(..., state.model_map, cfg.short_model_names)）：
    --- 拿原文去问会让「配了 model_map / short_model_names 的部署」上禁用静默不生效
    --- —— 操作员勾了禁用、名字却对不上，与他自己那句话相反。两处同源因此不可漂移。
    local function disabled_name(name)
        if disabled_asked == nil then return false end
        if type(name) ~= "string" or name == "" then return false end
        local model = _M.model_name(name, state.model_map, cfg.short_model_names)
        return type(model) == "string" and model ~= "" and disabled_asked(model) == true
    end
    --- 本轮探到的候选：它对外服务的第一个名字（= 注册名）被禁用了吗。
    local function url_disabled(info)
        return disabled_name(info and info.models and info.models[1])
    end
    --- 台账里已注册的行：entry.model_id **就是**当初注册用的那个名字，直接问，
    --- 绝不再跑一遍 _M.model_name —— 对已解析的名字二次解析会在「map 的键里恰好
    --- 有某个解析结果」时二次改写（链式别名），把摘除判定挂在一个不相干的名字上。
    local function owned_disabled(entry)
        if disabled_asked == nil then return false end
        local model = entry and entry.model_id
        return type(model) == "string" and model ~= "" and disabled_asked(model) == true
    end
    for i = 1, #discovered do
        local info = discovered[i]
        if url_disabled(info) then
            -- 被禁用的 URL 既不进 desired 也不进 protected_seen：它这一轮等同于不存在。
            -- 已经在池里的行交给 Removals 的禁用分支摘（不在池里的自然什么都不做）。
            -- 注册侧跳过因此是**结构性**的：desired 里没有它，Adds 的循环根本到不了它。
        elseif ledger.is_protected(info.url) then
            protected_seen[info.url] = info
        else
            desired[info.url] = info
        end
    end

    local pending_live = _M.reap_pending(state)

    ---A URL with a queued add is claimed, whatever its stage in this pass.
    local function pending_now(url)
        return pending_live[url] or ledger.get_pending(url) ~= nil
    end

    -- Adds.
    for _, url in ipairs(env_mod.sorted_keys(desired)) do
        if not state.actual[url] and not pending_live[url] then
            local entry = desired[url]
            local model_id = _M.model_name(entry.models[1], state.model_map, cfg.short_model_names)
            local fail_until = ledger.get_backoff(url)
            if fail_until and now < tonumber(fail_until.until_ts or 0) then
                -- in back-off after a rejected add
            else
                local worker_id, err = state.register(url, model_id, entry)
                if not worker_id then
                    stats.add_fails = stats.add_fails + 1
                    local n = ((ledger.get_backoff(url) or {}).n or 0) + 1
                    ledger.set_backoff(url, n, now)
                    warn(state.log, string.format("watcher: add %s failed: %s",
                        url, tostring(err)))
                else
                    stats.adds = stats.adds + 1
                    ledger.drop_backoff(url)
                    ledger.set_pending(url, { queued_at = now, worker_id = worker_id },
                        cfg.add_confirm_timeout_secs + cfg.interval_secs)
                    ledger.set_owned(url, {
                        model_id = model_id,
                        worker_id = worker_id,
                        engine = entry.engine,
                        source = entry.source,
                        label = entry.label,
                        added_at = now,
                    }, state.entry_ttl)
                    notice(state.log, string.format("watcher: registered %s as model %q (engine %s)",
                        url, model_id, entry.engine))
                end
            end
        end
    end

    -- Renames: a map (or short-model-names) change has to reach the pool, which
    -- means recycling the entry so the next pass re-adds it under the new id.
    -- Owned workers go through their ledger entry; protected ones have no entry,
    -- and dropping their protection is what hands ownership over (same trick as
    -- the daemon's eviction hand-off).
    for _, url in ipairs(env_mod.sorted_keys(desired)) do
        if not pending_now(url) and state.actual[url] then
            local info = desired[url]
            local want = _M.model_name(info.models[1], state.model_map, cfg.short_model_names)
            local have = tostring(state.actual[url].model_id or "")
            local entry = ledger.get_owned(url)
            if entry and entry.model_id ~= want and have ~= want then
                if _M.is_config_member(state, url) then
                    note_config_skip(state, url, "rename")
                else
                    notice(state.log, string.format("watcher: rename %s (registered %q, want %q)",
                        url, have, want))
                    _M.release(state, url, entry, 0, "rename")
                end
            end
        end
    end
    for _, url in ipairs(env_mod.sorted_keys(protected_seen)) do
        if not pending_now(url) and state.actual[url] then
            local info = protected_seen[url]
            local want = _M.model_name(info.models[1], state.model_map, cfg.short_model_names)
            local have = tostring(state.actual[url].model_id or "")
            if have ~= "" and have ~= want and _M.is_config_member(state, url) then
                note_config_skip(state, url, "model-map rename")
            elseif have ~= "" and have ~= want then
                notice(state.log, string.format(
                    "watcher: rename of protected %s (registered %q, want %q); adopting it",
                    url, have, want))
                ledger.unprotect(url)
                if state.unregister(tostring(state.actual[url].id or "")) then
                    stats.removes = stats.removes + 1
                else
                    ledger.protect(url)   -- keep the promise if the delete failed
                end
            end
        end
    end

    -- Removals: only from our own ledger (guard 4).
    --
    -- Probe verdicts are decided for the whole pass *before* the first delete. Two
    -- reasons: the fuse compares "how many rows the probes want gone" against the
    -- owned total, and that denominator cannot be read after deletions started
    -- shrinking it; and the hysteresis arithmetic belongs in one place so the loop
    -- below stays the audit of the eight guards rather than a second decision tree.
    -- probe_verdict_of maps url -> {verdict="release"|"bump", reason=, fails=};
    -- anything absent from it is not a probe eviction candidate this pass.
    local owned = ledger.owned_urls()
    -- math.floor so a fractional env value cannot silently shorten the wait, and
    -- 0/negative collapses to 1: that is the operator's explicit "evict at once".
    local fail_threshold = math.floor(tonumber(cfg.probe_failures) or 2)
    if fail_threshold < 1 then
        fail_threshold = 1
    end
    local probe_verdict_of, probe_evicting = {}, 0
    -- 2026-10-09 用户裁定：物理摘除只留两个信号——服务下线(undiscovered,走下面
    -- 宽限分支)与 /v1/models 无法访问(count 档「no /v1/models answer」,含连不上/
    -- 超时,保持累计摘除)。探针「能应答却判它不是合格 worker」的 reject 三档
    -- (无 data[].id / router 自指纹 / 超 max_models)属「其他情况」,改走临时禁用
    -- 保行:registry 行不动、只打 td: 键让候选装配排除它,探针恢复轮 clear 即回归。
    -- 不进 probe_evicting 计数(它永远不删,喂进保险丝分母就是虚报战果)。
    -- SMG_WATCHER_PROBE_TEMP_DISABLE=0 退回旧行为(这三档当轮删行)。
    local function temp_disable_reason(reason)
        if reason == "/v1/models answers without data[].id"
            or reason == "it is a router, not a worker" then
            return true
        end
        if type(reason) == "string"
            and string.find(reason, "advertises ", 1, true) == 1 then
            return true
        end
        return false
    end
    local temp_disable_on = cfg.probe_temp_disable ~= false
    for _, url in ipairs(env_mod.sorted_keys(owned)) do
        local entry = owned[url]
        local failed = entry and not desired[url] and state.actual[url]
            and probe_failed[url]
        -- Config members belong to config_store and a URL absent from probe_failed
        -- was never dialled this pass (the undiscovered grace owns it); both stay out
        -- of the tally, so a verdict can neither feed the fuse that would spare it nor
        -- get blamed for the delete that could not remove it.
        if failed and not _M.is_config_member(state, url) then
            if failed.verdict == "reject" then
                if temp_disable_on and temp_disable_reason(failed.reason) then
                    probe_verdict_of[url] = { verdict = "temp_disable",
                        reason = failed.reason }
                else
                    probe_verdict_of[url] = { verdict = "release", reason = failed.reason }
                    probe_evicting = probe_evicting + 1
                end
            else
                local fails = (tonumber(entry.probe_fails) or 0) + 1
                if fails >= fail_threshold then
                    probe_verdict_of[url] = {
                        verdict = "release", reason = failed.reason, fails = fails }
                    probe_evicting = probe_evicting + 1
                else
                    probe_verdict_of[url] = {
                        verdict = "bump", reason = failed.reason, fails = fails }
                end
            end
        end
    end

    -- Single-pass fuse (guard 10). A gateway-wide failure -- cosocket exhaustion,
    -- DNS, a kernel or timer problem that starves every probe of its budget -- makes
    -- every service on the box look dead at once, and the strict probe would
    -- obediently empty the pool in one interval. Losing more than half of owned
    -- workers to a probe verdict in a single pass is far more likely to be the
    -- gateway than the fleet, so the pass degrades to warn-only and waits for a
    -- second opinion; the counters keep climbing, so a real fleet-wide outage still
    -- evicts as soon as the premise (a transient gateway fault) stops holding.
    --
    -- The >= 2 floor is what keeps a one-worker deployment honest: a single row that
    -- fails a *deterministic* probe really is a zombie, and sparing it would mean the
    -- strict probe could never evict anything on a one-worker box.
    local owned_total = 0
    for _, entry in pairs(owned) do
        if entry then
            owned_total = owned_total + 1
        end
    end
    -- allow_remove=false means nothing was ever going to be deleted, so claiming the
    -- fuse "kept" them would describe a rescue that never happened.
    local fuse_on = cfg.allow_remove and cfg.probe_fuse ~= false
        and probe_evicting >= 2 and probe_evicting * 2 > owned_total
    if fuse_on then
        stats.probe_fuse_skips = (stats.probe_fuse_skips or 0) + probe_evicting
        warn(state.log, string.format(
            "watcher: probe fuse kept %d/%d owned workers this pass (the probes condemned more than half the pool; suspect a gateway-wide probe failure, SMG_WATCHER_PROBE_FUSE=0 disables the fuse)",
            probe_evicting, owned_total))
    end

    ---Carry out this pass's probe decision for one owned entry.
    ---@param url string
    ---@param entry table
    local function probe_evict(url, entry)
        local decided = probe_verdict_of[url]
            or { verdict = "release", reason = (probe_failed[url] or {}).reason }
        -- A transport-level unknown is one observation per pass whether or not this
        -- pass acts on it: the counter is what the hysteresis decides with, and the
        -- metrics series is what tells an operator "the probes are unhappy" before any
        -- worker is gone. It is written back in the keep-it branches too, so a pass
        -- spared by the fuse still climbs toward the threshold and the survivors
        -- evict the moment the fuse's premise (a transient gateway fault) lapses --
        -- without the run ever having to restart from zero.
        if decided.fails then
            stats.probe_failures = (stats.probe_failures or 0) + 1
            entry.probe_fails = decided.fails
        end
        if decided.verdict == "temp_disable" then
            -- 保行、打位、每轮 warn（靠 entry.warned 静音,与 keep-it 分支同形）。
            -- 不受 fuse 与 allow_remove 约束:这条分支从不删行,保险丝与「只许加
            -- 不许删」约定管的都是删除,与临时禁用正交。
            -- 走 state.temp_disable 接缝（live.lua 注入的闭包）,reconcile 不碰 registry。
            if type(state.temp_disable) == "function" then
                local worker_id = tostring(entry.worker_id or "")
                if worker_id ~= "" then
                    local ttl = (tonumber(cfg.interval_secs) or 15) * 3
                    state.temp_disable(worker_id, decided.reason, ttl)
                end
            end
            if not entry.warned then
                warn(state.log, string.format(
                    "watcher: %s fails the strict /v1/models probe (%s); temporarily disabled, keeping the row",
                    url, tostring(decided.reason or "unknown")))
                entry.warned = true
            end
            entry.temp_disabled = true
            ledger.set_owned(url, entry, state.entry_ttl)
        elseif decided.verdict == "bump" then
            ledger.set_owned(url, entry, state.entry_ttl)
            -- Unlike the other keep-it branches this one may log every round: the
            -- wait is bounded by the threshold, and an engine that starts timing out
            -- should leave a trace the moment it starts, one pass before it costs the
            -- pool a worker.
            warn(state.log, string.format(
                "watcher: %s failed the strict /v1/models probe (%d/%d): %s; keeping it",
                url, tonumber(decided.fails) or 0, fail_threshold,
                tostring(decided.reason or "unknown")))
        elseif fuse_on then
            -- The pass-level warn already named the count; per-entry silence rides on
            -- entry.warned, the same mute every other keep-it branch uses, and it is
            -- cleared as soon as the service answers a probe again.
            if not entry.warned then
                warn(state.log, string.format(
                    "watcher: %s fails the strict /v1/models probe but the pass fuse is on; keeping it",
                    url))
                entry.warned = true
                ledger.set_owned(url, entry, state.entry_ttl)
            end
        else
            stats.probe_removes = (stats.probe_removes or 0) + 1
            -- The classify() reason travels verbatim into the log line, because "the
            -- probe said no" is only actionable when an operator can tell *which* no
            -- it said: the strict probe's "it answered the wrong thing" versus the
            -- undiscovered branch's "it stopped answering at all".
            _M.release(state, url, entry, 0,
                "probe failed (no /v1/models): " .. tostring(decided.reason or "unknown"))
        end
    end

    for _, url in ipairs(env_mod.sorted_keys(owned)) do
        local entry = ledger.get_owned(url)
        if entry then
            if desired[url] then
                -- The entry is rewritten on every pass that still sees the worker,
                -- which is what renews its lr_watch ttl. Skipping the write in the
                -- steady state would let a long-lived worker's entry age out (the
                -- ledger lives in a shared dict with a TTL as a leak guard), and an
                -- owned URL with no entry is invisible to the removal loop below:
                -- the worker would keep its pool row after the service died for
                -- good, which is precisely the zombie the daemon exists to prevent.
                entry.missing_since = nil
                entry.warned = nil
                -- The hysteresis clock resets at the same place as the warn mute: a
                -- service that answers the probe again is no longer in a failure run,
                -- so "up-down-up-down" cannot accumulate toward a threshold it would
                -- never reach if each flap started from zero.
                entry.probe_fails = nil
                ledger.set_owned(url, entry, state.entry_ttl)
                -- 探针恢复轮：清掉临时禁用位,该 worker 立刻回到候选池（TTL 键本就
                -- 会自愈,显式清一次让回归即时、不靠过期兜底）。pcall 兜住桩环境里
                -- registry 被换掉缺这个方法的极端情况,失败=键靠 TTL 掉,不影响判定。
                if entry.temp_disabled then
                    entry.temp_disabled = nil
                    if type(state.clear_temp_disable) == "function" then
                        state.clear_temp_disable(tostring(entry.worker_id or ""))
                    end
                    ledger.set_owned(url, entry, state.entry_ttl)
                end
                -- Guard 8: a router restart/reload re-creates workers with fresh
                -- ids, so keep the recorded id in step with the pool.
                local live = state.actual[url]
                if live and live.id and tostring(live.id) ~= tostring(entry.worker_id) then
                    entry.worker_id = tostring(live.id)
                    ledger.set_owned(url, entry, state.entry_ttl)
                end
            elseif not state.actual[url] then
                -- Gone from the pool and from discovery: forget it, nothing to delete.
                ledger.drop_owned(url)
                ledger.drop_pending(url)
            elseif _M.is_config_member(state, url) then
                -- The row outlived the ledger's knowledge because someone
                -- re-declared the URL as a config upstream: neither the
                -- missing_since clock nor the delete may run against it. The
                -- ledger forgets its claim so the member is config-owned, end
                -- of story (watcher stop-owning, not watcher-delete).
                note_config_skip(state, url, "reclaim")
                ledger.drop_owned(url)
                ledger.drop_pending(url)
                ledger.drop_backoff(url)
            elseif owned_disabled(entry) then
                -- 「禁用即摘」（用户裁定 2026-10-09 的 watcher 侧最小路径）：操作员勾了禁用，
                -- 这条已注册的行就退出池子。走 _M.release 这**同一个**摘除出口（台账清理、
                -- drop_pending / drop_backoff、removes 计数、pass 日志全复用），理由与
                -- 「为什么 whole reconcile 不拆」那条纪律同一条 —— 「为什么那台 worker 走了」
                -- 必须只有一个答点；新增一条并行摘除路径等于给出第二个答案。
                --
                -- 排在 is_config_member **之后**：声明层行归 config_store 所有，watcher 从不删它
                -- （上面那一支的 stop-owning 口径），操作员禁用一台 config 实例时由声明层与
                -- 候选门负责；这里只管 watcher 自己认领的行。protected 行同样不进这里（守卫 3
                -- 永不删），两者都由候选门保证「不被服务」。
                --
                -- 也受 allow_remove 约束：SMG_WATCHER_ALLOW_REMOVE=0 是操作员「只许加不许删」的
                -- 明确约定，配置动作不该绕过它（这与 strict probe 那次踩过的同一个坑对齐）。
                -- 不删也不影响「不再被服务」—— 候选门按 disabled 排除它是独立的一道，摘除只是
                -- 把池子打扫干净。warn 一次靠 entry.warned 静音，与 undiscovered 分支同形。
                --
                -- 隐藏（hidden）不走这一支：被藏的行留在池里继续服务（2026-10-09 收窄），
                -- 它只是不出现在 /v1/models 的对外广告里。
                if not cfg.allow_remove then
                    if not entry.warned then
                        warn(state.log, string.format(
                            "watcher: model %q of %s is disabled but removal is disabled; keeping it (it stays out of every candidate pool)",
                            tostring(entry.model_id), url))
                        entry.warned = true
                        ledger.set_owned(url, entry, state.entry_ttl)
                    end
                else
                    -- keep-last 这一判刻意**不**套用（与 undiscovered 分支相反）：那一判存在的
                    -- 理由是「别让一次重启/掉线把某个模型的服务清空」，它防的是**意外**；
                    -- 禁用是操作员的明确意图，用「它是这个模型最后一台」去否决它，等于让
                    -- 网关替操作员决定「这句话我不照做」。摘完之后该入口按既有的无候选路径答
                    -- 503，正是「不再被服务」的对外形状。
                    _M.release(state, url, entry, 0,
                        string.format("model %q disabled by operator config",
                            tostring(entry.model_id)))
                end
            elseif probe_ignore[url] then
                -- 本轮对这条 URL 什么都没说出口：探针压根没拨通（no probe transport，
                -- 网关侧的装配或 cosocket 限流），或它给的理由是注册准入开关
                -- require_health 的产物（/health 404 的引擎有一大半）。这类结论既不能
                -- 计入滞回也不能走 missing_since 宽限——否则打开 SMG_WATCHER_REQUIRE_HEALTH
                -- 的操作员会让每个不实现 /health 的引擎陷入摘-加循环，网关自己的 socket
                -- 抖动也会被记成"这个 worker 死了"。条目原样留着，等下一轮的真结论。
            elseif probe_failed[url] then
                -- Confirmed unavailable, not merely undiscovered: the strict probe
                -- reached the service and could not read a usable model list from it.
                -- Such a row answers 5xx while advertising a model it cannot serve, so
                -- it does not get the undiscovered grace or the keep-last exemption --
                -- how soon it leaves is decided by probe_evict above, which is where
                -- the reject/count split, the hysteresis threshold and the fuse all
                -- live. Recovery stays the normal path: the first round that reads a
                -- real /v1/models re-adds it through the same add gates.
                --
                -- 摘除开关仍然排在探针结论前面：SMG_WATCHER_ALLOW_REMOVE=0 是操作员
                -- "只许加不许删"的明确约定，探针结论再确定也不能替他们做删除的决定，
                -- 否则严格探针就成了绕过这道保险的后门（首次实现就是直接 release，
                -- 于是关掉摘除的服务仍然被删）。这里沿用下方 undiscovered 分支的
                -- 形态：保留 pool 行、只警告一次，靠 entry.warned 静音后续轮次，
                -- 避免每个 interval 刷一条同样的 warn。warned 会在服务重新被探到
                -- 时（desired 分支）清掉，所以"恢复后再坏"仍会再提醒一次。
                if not cfg.allow_remove then
                    if not entry.warned then
                        warn(state.log, string.format(
                            "watcher: %s fails the strict /v1/models probe but removal is disabled; keeping it",
                            url))
                        entry.warned = true
                        ledger.set_owned(url, entry, state.entry_ttl)
                    end
                else
                    probe_evict(url, entry)
                end
            else
                local first_missing = tonumber(entry.missing_since)
                if not first_missing then
                    entry.missing_since = now
                    ledger.set_owned(url, entry, state.entry_ttl)
                    first_missing = now
                end
                local age = now - first_missing
                if not cfg.allow_remove then
                    if age >= cfg.remove_grace_secs and not entry.warned then
                        warn(state.log, string.format(
                            "watcher: %s has been undiscovered for %.0fs but removal is disabled",
                            url, age))
                        entry.warned = true
                        ledger.set_owned(url, entry, state.entry_ttl)
                    end
                elseif age < cfg.remove_grace_secs then
                    -- Guard 5: a short restart is the health sweep's job, not ours.
                elseif cfg.keep_last_grace_secs >= 0
                    and _M.is_last_for_model(tostring(entry.model_id or ""), url, state.actual) then
                    -- Guard 6: never empty a model, but do not keep a permanently
                    -- stopped service serving 5xx either.
                    if not (cfg.keep_last_grace_secs > 0 and age >= cfg.keep_last_grace_secs) then
                        if not entry.warned then
                            warn(state.log, string.format(
                                "watcher: %s gone %.0fs but it is the last worker of model %q; keeping it",
                                url, age, tostring(entry.model_id)))
                            entry.warned = true
                            ledger.set_owned(url, entry, state.entry_ttl)
                        end
                    else
                        notice(state.log, string.format(
                            "watcher: %s gone %.0fs and it is the last worker of model %q (>= keep-last grace %.0fs); removing it",
                            url, age, tostring(entry.model_id), cfg.keep_last_grace_secs))
                        _M.release(state, url, entry, age, "keep-last expired")
                    end
                else
                    _M.release(state, url, entry, age, "undiscovered")
                end
            end
        end
    end

    return stats
end

---Delete one ledger-owned worker and forget the entry (the daemon's _remove).
---@param state table
---@param url string
---@param entry table
---@param age number
---@param reason string
---@return boolean ok
function _M.release(state, url, entry, age, reason)
    local worker_id = tostring(entry.worker_id or "")
    if worker_id == "" then
        warn(state.log, string.format("watcher: %s has no recorded worker id; cannot delete", url))
        return false
    end
    if not state.unregister(worker_id) then
        warn(state.log, string.format("watcher: remove %s failed", url))
        return false
    end
    state.stats.removes = state.stats.removes + 1
    state.ledger.drop_owned(url)
    state.ledger.drop_pending(url)
    state.ledger.drop_backoff(url)
    notice(state.log, string.format("watcher: removed %s (%s, gone %.0fs)", url, reason, age or 0))
    return true
end

return _M
