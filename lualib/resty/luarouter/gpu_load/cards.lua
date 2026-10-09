local _M = require "resty.luarouter.gpu_load"

-- gpu_load/cards.lua -- worker<->card attribution and the utilization
-- folding pass.  The four-way util rule (source exposes no gpu label ->
-- machine max; worker names its card and the vector has it -> that card;
-- card unknown, or no series for that card -> fall back to the machine max
-- and count the fallback, never silently) and the util_fold identity rules
-- (case-folded machine label vs loopback-instance adoption) are the whole
-- 21.k 342.371 lesson; moved line for line so the rule has one owner.

---Separator for per-card keys: a control byte appears in neither a Prometheus label
---value (exporters escape it) nor a host key, so host..SEP..gpu cannot collide with
---either half, and a key can never be forged from ordinary text.
local CARD_SEP = "\001"
_M.CARD_SEP = CARD_SEP

---@param host string|nil
---@param gpu string|number
---@return string
function _M.card_key(host, gpu)
    return tostring(host or "") .. CARD_SEP .. tostring(gpu)
end

---url -> (host, port) identity key, with the scheme's default port made explicit.
---
---Why the lookup needs a second key beyond the url text: the hint is written under
---the *watcher's* canonical url (watcher.normalize_url lower-cases the host and drops
---a default :80/:443) but read with the *registry's* record.url (registry
---normalize_url only adds a scheme and trims trailing slashes -- it keeps ":80" and
---the original case). The two normalizers disagree, so an exact-string hint table
---misses whenever an operator seeds SMG_WORKER_URLS as
---"http://GPU-Box:8012" and the watcher discovers "http://gpu-box:8012". A miss is
---not harmless: with per-card attribution in force, "no card resolved" means
---"no per-card reading" -- the worker falls back to the whole-machine max and
---the fallback counter says so.  split_host() is the one function both paths
---already agree on semantically
---(assign() matches series to workers through it), so the identity goes through it
---too, and the port is defaulted per scheme so :80 and the bare form meet.
---@param url string|nil
---@return string|nil key @ "host:port", or nil when the url cannot be named
function _M.host_port_key(url)
    if type(url) ~= "string" or url == "" then
        return nil
    end
    local host, port = _M.split_host(url)
    if not host then
        return nil
    end
    if not port then
        port = (string.match(string.lower(url), "^https://") ~= nil) and 443 or 80
    end
    return host .. ":" .. tostring(port)
end

---Compile the watcher's url -> gpu snapshot into a lookup index.
---
---Two levels: the exact url (the common case, and the only one that can distinguish
---two containers that share a host but were registered with different spellings) and
---the host:port identity for the normalizer-mismatch case. An ambiguous bucket is
---**dropped** rather than resolved by whoever wrote last: two candidate urls that
---collapse to the same identity yet name different cards mean the gateway does not
---know which card lives at that address, and guessing there is how a reading
---ends up on the wrong worker. Dropping is also order-independent, which is what
---keeps a pass reproducible across runs (see the determinism probe).
---@param hints table|nil @ url -> gpu id (raw snapshot)
---@return table @ index accepted by worker_card()
function _M.hint_index(hints)
    local exact, buckets, seen = {}, {}, {}
    if type(hints) == "table" then
        for url, gpu in pairs(hints) do
            local card = _M.worker_gpu({ labels = { gpu = gpu } })
            if type(url) == "string" and url ~= "" and card ~= nil then
                exact[url] = card
                local key = _M.host_port_key(url)
                if key then
                    local prior = seen[key]
                    if prior == nil or prior == card then
                        seen[key] = card
                        buckets[key] = card
                    else
                        -- two different cards claim one address: keep neither
                        seen[key] = false
                        buckets[key] = nil
                    end
                end
            end
        end
    end
    return { __card_index = true, exact = exact, buckets = buckets }
end

---The card id to attribute one worker's utilization reading to, or nil for "unknown".
---
---Two sources, checked in this order, and the order matters in production:
---  * the watcher ledger's g|<url> hint, which the watcher writes for **every**
---    candidate it discovers (reconcile), independent of whether that worker is a
---    protected pre-existing row;
---  * registry's labels.gpu, which only carries a value for workers the watcher
---    actually registered.
---The ledger first because 21.k:8801's eight workers are all seeded from
---SMG_WORKER_URLS (bootstrap -> registry.add({url=...}), no labels) and then
---permanently protected by the watcher's guard 3, so their record.labels stays
---empty forever -- registry.add's idempotent branch (registry.lua:1476) answers a
---duplicate url with a failed job and *does not touch the record*, so a later add
---can never back-fill labels either. Reading the ledger is what keeps this whole
---feature inside gpu_load.lua + watcher.lua: no registry change is required, and
---nothing here depends on labels ever arriving.
---@param record table|nil
---@param hints table|nil @ a hint_index() (preferred; compiled once per pass) or a raw
---                        url -> gpu id table (test seams, probes)
---@return string|nil gpu
function _M.worker_card(record, hints)
    if type(record) ~= "table" then
        return nil
    end
    local url = record.url
    if type(url) == "string" and type(hints) == "table" then
        local index = hints.__card_index and hints or _M.hint_index(hints)
        local card = index.exact[url]
        if card == nil then
            -- The hint was written under the watcher's canonical url and we are
            -- reading with the registry's, so a spelling difference (:80, host case)
            -- has to fall through to the host:port identity rather than miss.
            card = index.buckets[_M.host_port_key(url) or ""]
        end
        if card ~= nil then
            return card
        end
    end
    return _M.worker_gpu(record)
end


-------------------------------------------------------------------- util (0..1)

---Per-card utilization fold for one result vector.  Both sources come through
---here: the prom path hands it parsed PromQL rows, the metrics path hands it
---the rows read off one worker exposition.
---
---This is the only folding pass left in the gateway, so it owns the
---machine-identity rules in full.  Each of the three below was paid for once
---in production -- the 21.k 342.371 flat line, and the cross-machine bleed --
---which is why the pass cannot be a plain group-by:
---  * dcgm-exporter 的机器名标签是**大写**的 Hostname，而 host_of() 只读小写键，所以先
---    整体折叠大小写；折叠后 Hostname 在 HOST_LABELS 里排在 instance **之后**，而每条 DCGM
---    series 都带 instance="127.0.0.1:9400"（抓取地址，不是机器），照抄 host_of() 的优先级
---    会把两台机器的 exporter 折到同一个值上——A 机最热的卡把 B 机的 worker 顶过上限，而
---    unmatched 恒为 0、一行日志都不留。
---  * 机器身份优先取机器名标签（Hostname / hostname / nodename / host / node / pod /
---    name）；instance 只在它是**非环回**地址时采纳，或者当同一 instance 下的全部 series
---    只属**一台**机器。后者是本 fleet 的正常形状（八个 worker 都注册成
---    http://127.0.0.1:80xx，与 DCGM 的 127.0.0.1:9400 在 "127.0.0.1" 这把键上相遇）；一旦
---    一个环回 instance 后面出现两个 Hostname，说明这台 Prometheus 抓了多台机器的本机
---    exporter，那个键没有资格代表其中任何一台——不采纳，也不猜。
---  * 折叠口径取**最大**而不是取和/取平均：一台 worker 往往看得见整机所有卡，路由要避免
---    把请求打到已经最热的那张卡上，取和会让「一张满载七张空闲」看起来仍然很闲。利用率
---    更没有「sum 出 800 %」这一档。
---
---What counts as a usable reading is decided by util_fraction(): **0 is a legal
---reading** (an idle card really does report 0 %, and the admission gate has to
---read that as "far below any ceiling", which is exactly what it means);
---negatives, NaN, ±inf and out-of-range values are refused.
---@param rows table[]|nil @ parse_prom_response() rows (labels + value)
---@param expose_cards boolean|nil @ also fold per-card keys
---@return table @ host -> utilization (whole-machine hottest, 0..1)
---@return table @ host..CARD_SEP..gpu -> utilization (empty unless expose_cards)
---@return table|nil @ host -> true for hosts with at least one card series
---@return boolean @ any usable series carried a numeric gpu label
local function util_fold(rows, expose_cards)
    local by_host, cards, card_hosts = {}, {}, {}
    local groups = {}
    local have_cards = false
    if type(rows) ~= "table" then
        return by_host, cards, card_hosts, have_cards
    end
    local function group(gpu)
        local g = groups[gpu]
        if not g then
            g = { host = {}, inst = {}, inst_machines = {} }
            groups[gpu] = g
        end
        return g
    end
    local function remember(target, key, util)
        if target[key] == nil or util > target[key] then
            target[key] = util
        end
    end
    for i = 1, #rows do
        local row = rows[i]
        local util = row and _M.util_fraction(row.value)
        if util and type(row.labels) == "table" then
            local lowered = {}
            for key, value in pairs(row.labels) do
                if type(key) == "string" then
                    lowered[string.lower(key)] = value
                end
            end
            local machine = _M.host_of({
                hostname = lowered.hostname or lowered.nodename or lowered.host,
                node = lowered.node, pod = lowered.pod, name = lowered.name,
            })
            local inst = _M.host_from_label(lowered.instance)
            -- "" = this series does not name a card. Those rows only feed the
            -- whole-machine map, and they are what keeps a machine-level source
            -- (node_exporter, an operator's by(Hostname) query) working.
            local gpu = ""
            if expose_cards then
                local raw = lowered.gpu or lowered.devicename or lowered.gpu_id
                if type(raw) == "string" or type(raw) == "number" then
                    local text = string.match(tostring(raw), "^%s*(.-)%s*$")
                    if text and string.match(text, "^%d+$") then
                        gpu = text
                    end
                end
            end
            if gpu ~= "" then
                have_cards = true
            end
            local g = group(gpu)
            if machine then
                remember(g.host, machine, util)
            end
            if inst then
                remember(g.inst, inst, util)
                local seen = g.inst_machines[inst]
                if not seen then
                    seen = {}
                    g.inst_machines[inst] = seen
                end
                -- A series with no machine label cannot prove whose it is; the
                -- empty-string placeholder marks "attribution uncertain".
                seen[machine or ""] = true
            end
        end
    end
    for gpu, g in pairs(groups) do
        local adopted = {}
        for inst, util in pairs(g.inst) do
            local distinct = 0
            for _ in pairs(g.inst_machines[inst] or {}) do
                distinct = distinct + 1
            end
            local loopback = (inst == "localhost" or inst == "::1"
                or string.sub(inst, 1, 4) == "127.")
            if (not loopback) or distinct <= 1 then
                adopted[inst] = util
            end
        end
        -- Drop machine-name keys fully represented by an adopted instance key: the
        -- instance max already covers that machine's whole series set, so the
        -- machine-name key carries no extra reading and would only inflate
        -- util_unmatched_total (pointing the operator at a label mismatch that does
        -- not exist). A machine-name key kept on its own (by(Hostname)) *is* the
        -- "reachable but unassignable" signal the operator needs, so it stays.
        local kept = {}
        for machine, util in pairs(g.host) do
            if adopted[machine] ~= nil or machine == "" then
                kept[machine] = util
            else
                local redundant
                for inst, inst_util in pairs(adopted) do
                    local seen = g.inst_machines[inst]
                    if seen and seen[machine] and inst_util >= util then
                        redundant = true
                        break
                    end
                end
                if not redundant then
                    kept[machine] = util
                end
            end
        end
        for machine, util in pairs(adopted) do
            remember(kept, machine, util)
        end
        if gpu ~= "" then
            for host, util in pairs(kept) do
                cards[_M.card_key(host, gpu)] = util
                card_hosts[host] = true
            end
        end
        -- Whole-machine max, folded over *every* series of the machine regardless of
        -- card, so the fallback branch of assign_util() cannot drift from the
        -- machine-level reading the other channels already use.
        for host, util in pairs(kept) do
            remember(by_host, host, util)
        end
    end
    return by_host, cards, card_hosts, have_cards
end
_M.util_fold = util_fold

---Map the utilization vector onto workers, preferring each worker's own card.
---
---The four-way attribution rule, and why each branch is what it is
---(doc/caps-redesign-2026-10-06.md §5, deliberate and not an oversight):
---  * 源根本没有逐卡标签（source_has_cards 假）-> 整机最热卡的利用率。这是老
---    数据源（node_exporter、operator 的 by(Hostname) 查询、只报一个整机 gauge 的引擎）
---    唯一可能的口径，逐字节保持改动前的行为，否则一直在用的数据源会在逐卡落地当天变黑。
---    「老源」的判据取自**源**，永远不取自 worker（否则一个没有卡标签的 exporter 会被读成
---    「这个 worker 认不出自己的卡」，几种情形塌成一条无法区分的日志）。
---  * worker 认得出卡 + vector 有该卡 series -> 它自己那张卡的利用率（per_card++）。这是
---    342.371 的修复在利用率侧的对应物：同机八台不再共用一个数。卡号复用现成的
---    worker_card()（watcher 台账 g|<url> 优先、registry labels.gpu 第二来源）与
---    hint_index()/card_key()/parse_labels()，逐卡归属的设施一处不改。
---  * worker 认不出卡 -> **回退整机 max**（fallback++）。
---  * 卡认得出但 vector 没有该卡 series -> **回退整机 max**（fallback++）。
---后两支选择**回退**而不是留空，这是刻意的：留空等于把这台 worker 当永远不忙，
---那才是更危险的一侧。两个方向各自的代价：
---  * 绝对读数（邻居那张卡的负载）冒充本卡读数，会让一张空闲 worker 被摘出
---    候选集——一个监控缺口吃掉容量，正是这条通道最不肯犯的错。
---  * 利用率上限读的是「这张卡忙不忙」。整机 max 在利用率语义下是保守方向：本机只要有任何
---    一张卡忙，就把这台 worker 当忙看待，代价是少用一台机器（吞吐），而不是让满载的卡
---    继续接新请求（排队与延迟）。「不知道哪张卡归它」时，按最热的算比当它永远不忙诚实。
---    而且归属冲突在这里会被识破：源已是逐卡而这块卡认不出来时，写进去的数是**别人那张卡**
---    的利用率，所以它必须被计数、被说出来（fallback++，见 export.lua 那一族），不能像
---    「本机就是整机口径」那样混在同一个数里——fallback 与 per_card 并排读就是覆盖率。
---  * 这条回退**不是静默的**：每一次回退都进 lr_gpu_load_util_fallback_total；处方是
---    把容器登记成带 gpuN 的名字（让 watcher 台账有 g| 键），并确认
---    SMG_LOAD_UTIL_QUERY 没把 gpu 聚合掉。
---claimed[host] 仍取自 host 级可达性而不是「有没有产出数值」，所以 util_unmatched 保持
---「这台机器的 series 匹配不到任何在池 worker」的原义，一次缺失的卡归属不会把它撑成假的
---标签不匹配。source_has_cards 接受布尔（metrics 路：一份正文 = 一台机器）或 host -> true
---集合（prom 路：一轮跨多台机器、甚至跨几种数据源）；集合形态是防「A 机有逐卡 series 就把
---B 机一起拖进逐卡口径」那条——一台机器的监控形状不该关掉另一台机器的通道。
---@param workers table[]|nil
---@param by_host table|nil @ host -> whole-machine utilization (0..1)
---@param cards table|nil @ card_key(host, gpu) -> utilization (0..1)
---@param source_has_cards boolean|table|nil @ boolean, or host -> true
---@param hints table|nil @ hint_index or raw url -> gpu id
---@return table @ worker id -> utilization (0..1)
---@return number @ unmatched host count
---@return number @ per_card @ workers that got their own card's series
---@return number @ fallback @ workers that got the whole-machine max
function _M.assign_util(workers, by_host, cards, source_has_cards, hints)
    local out, unmatched = {}, 0
    local per_card, fallback = 0, 0
    if type(workers) ~= "table" then
        return out, unmatched, per_card, fallback
    end
    local claimed = {}
    for i = 1, #workers do
        local worker = workers[i]
        local host = worker and _M.split_host(worker.url)
        if host and type(by_host) == "table" and by_host[host] ~= nil then
            claimed[host] = true
            local util
            local per_card_flag = source_has_cards
            if type(per_card_flag) == "table" then
                per_card_flag = per_card_flag[host] == true
            end
            if per_card_flag then
                local gpu = _M.worker_card(worker, hints)
                if gpu ~= nil and type(cards) == "table" then
                    util = cards[_M.card_key(host, gpu)]
                end
                if util ~= nil then
                    per_card = per_card + 1
                end
            end
            if util == nil then
                -- 整机 max 回退（代价方向见上方那一支）。源本身没有卡标签时也走
                -- 这里——那本来就是整机口径，如实计入
                -- fallback，让「逐卡覆盖率」这一个读数就说得清整台机器的状况。
                util = by_host[host]
                fallback = fallback + 1
            end
            if util ~= nil and worker.id ~= nil then
                out[worker.id] = util
            end
        end
    end
    if type(by_host) == "table" then
        for host in pairs(by_host) do
            if not claimed[host] then
                unmatched = unmatched + 1
            end
        end
    end
    return out, unmatched, per_card, fallback
end

---Fold a result vector into per-card utilization readings as well as per-host.
---
---Per-card counterpart of host_utils(): the same fold with card keys exposed.
---
---默认查询串（缺省值只有一个权威：parse.lua 的 DEFAULT_UTIL_QUERY，这里抄一份给运维看）：
---    max by (Hostname,instance,gpu) (DCGM_FI_DEV_GPU_UTIL)
---  * gpu 必须留在 by 里：聚合掉它 = 八台 worker 共用一个数（342.371 的利用率复刻），而
---    lr_gpu_load_util_per_card_workers 会诚实地停在 0。
---  * Hostname 留在 by 里：让 util_fold 在「一台 Prometheus 抓了多台机器的本机
---    exporter」时识破归属冲突，宁可整台不采纳，也不把 A 机最热的卡挂到 B 机头上。
---  * instance 留在 by 里：本 fleet 的 worker 全注册成 http://127.0.0.1:80xx，机器名与 IP
---    之间没有可用映射，只有 exporter 的抓取地址能把读数交回本机 worker。
---  * 用 max 而不是 sum/avg：sum 会把同一张卡的多份副本相加（利用率没有「大于 100 %」这一
---    档），avg 会把「一张满载七张空闲」折成很闲——准入门要的是最热那张卡的读数。
---@param rows table[]|nil @ parse_prom_response() rows
---@return table @ host -> utilization (whole-machine hottest, 0..1)
---@return table @ host..CARD_SEP..gpu -> utilization
---@return table @ host -> true (hosts exposing at least one card series)
---@return boolean @ any series carried a numeric gpu label
function _M.host_card_utils(rows)
    return util_fold(rows, true)
end

---Fold a result vector down to one utilization reading per host (hottest wins).
---@param rows table[]|nil @ parse_prom_response() rows
---@return table @ host -> utilization (0..1, only usable readings)
function _M.host_utils(rows)
    return util_fold(rows, false)
end

--- Utilization knobs for this pass, read from the config table with an env fallback.
---
--- How these knobs behave, in three points:
---   * 这两个开关**走 config.lua**（cfg.load_util_enabled / cfg.load_util_query 由
---     SMG_LOAD_UTIL_ENABLED / SMG_LOAD_UTIL_QUERY 在 init_by_lua 里装配），所以它们天然
---     进得了 /probe/config 与管理台可见面（AGENTS.md 重点 3）。下面的 env 分支是给「手搓
---     cfg 表」的调用者（单测、探针）留的注入面，与负载那一路的 env() 同形；生产上请
---     配 config.lua 那一份。三份 conf 也一并声明了 SMG_LOAD_UTIL_*，两条路都通——漏一份
---     env 声明时 os.getenv 那一路会静默失效，而 config 那一路不受影响。
---   * 这三个名字每 tick 现读并不比 init 期读一次更「热」：worker 环境在
---     fork 时固定，全仓没有 setenv/putenv，生效方式是重启容器。别把它承诺成可热改。
---   * 开关缺省 **1**（doc/caps-redesign-2026-10-06.md §5）。利用率缺省开的理由是它的
---     **判定**并不由这个开关决定
---     ——采集只把读数写进 registry 的 gu: 键，只有记录上显式配了 max_gpu_util 才有人读它，
---     所以缺省开不会改变任何现有部署的选路行为（红线「缺省零行为变化」由判定侧的「读数未知
---     -> 不排除」与「没配上限 -> 零 shdict 读」保证）。缺省关的代价则是操作员多记一个开关
---     才知道利用率上限为什么一直按「未知」放行。
---  * SMG_LOAD_UTIL_ENABLED  "1"/"true"/"yes"/"on" 开（缺省开）；其余判关
---  * SMG_LOAD_UTIL_KEYS     覆盖 metrics 路的利用率 gauge 名册（逗号/空格分隔）
---  * SMG_LOAD_UTIL_QUERY    prom 路的第二条 PromQL；留空 = 用缺省查询串
---@param cfg table|nil @ router config; cfg.load_util* wins when present
---@return table @ {on, keys, query}
function _M.util_config(cfg)
    cfg = cfg or {}
    local function env(name)
        if type(os.getenv) ~= "function" then
            return nil
        end
        local value = os.getenv(name)
        if type(value) ~= "string" or value == "" then
            return nil
        end
        return value
    end
    local on = cfg.load_util_enabled
    if on == nil then
        local raw = env("SMG_LOAD_UTIL_ENABLED")
        if type(raw) == "string" then
            local lowered = string.lower(raw)
            on = lowered == "1" or lowered == "true" or lowered == "yes" or lowered == "on"
        else
            -- 缺省开；唯一的显式关法是 0/false/no/off 或任何不被认识的值（判真口径
            -- 与负载那一路一致：不认识 = 关）。
            on = true
        end
    end
    local keys = cfg.load_util_keys
    if keys == nil or (type(keys) == "table" and #keys == 0)
        or (type(keys) == "string" and string.match(keys, "^%s*$")) then
        keys = env("SMG_LOAD_UTIL_KEYS")
    end
    local query = cfg.load_util_query
    if query == nil or (type(query) == "string" and query == "") then
        query = env("SMG_LOAD_UTIL_QUERY")
    end
    -- 「操作员到底有没有写过这条查询」必须能分开：prom 路的整轮 skip 判据（负载
    -- 查询都没配就整轮不跑）不能因为利用率有缺省串而被推翻——否则每个只配负载查询的部署都
    -- 会多打一条没人要求的 POST。反过来，操作员**显式**写了 SMG_LOAD_UTIL_QUERY 就是明确的
    -- 意图信号，那条查询必须能单独把这一路跑起来。
    local explicit_query = type(query) == "string" and query ~= ""
        and string.match(query, "^%s*$") == nil
    if not explicit_query then
        -- 缺省串只有一份权威（parse.lua 的 DEFAULT_UTIL_QUERY）：config.lua 把空值留给这里
        -- 兜一次，两处不再各抄一遍字面量。
        query = _M.DEFAULT_UTIL_QUERY
    end
    return {
        on = not not on,
        keys = keys,
        query = (type(query) == "string" and query ~= "") and query or nil,
        explicit_query = explicit_query and true or false,
    }
end

return _M
