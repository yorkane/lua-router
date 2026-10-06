local _M = require "resty.luarouter.gpu_load"

-- gpu_load/cards.lua -- worker<->card attribution and the two folding
-- passes.  The four-way power rule (source exposes no gpu label ->
-- machine max; worker names its card and the vector has it -> that card;
-- card unknown, or no series for that card -> write nothing, never the
-- neighbour-side watts) and the power_fold identity rules (case-folded
-- machine label vs loopback-instance adoption) are the whole 21.k
-- 342.371 lesson; moved line for line so the rule has one owner.

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
---not harmless any more: with per-card attribution in force, "no card resolved" means
---"no watt written", so a pure spelling difference would switch a worker's power cap
---off. split_host() is the one function both paths already agree on semantically
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
---know which card lives at that address, and guessing there is how a watt reading
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

---The card id to attribute one worker's power reading to, or nil for "unknown".
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

---Map the power vector onto workers, preferring each worker's **own card**.
---
---The four-way rule, and why each branch is what it is:
---  * source exposes no gpu label at all (`source_has_cards` false) -> whole-machine
---    max for every worker. This is the legacy shape (node_exporter, or an operator's
---    `by (Hostname)` query, or the metrics path against an engine that reports one
---    machine-level gauge) and it must stay byte-for-byte today's behaviour, or a
---    data source that has always worked would go dark the day per-card attribution
---    ships. The test for "legacy source" is the **source**, never the worker: if it
---    were decided per worker, a cardless exporter would read as "this worker cannot
---    name its card" and all three failure modes below would collapse into one
---    indistinguishable log line.
---  * worker names a card and the vector has it -> that card's watts. This is the
---    342.371 fix: eight workers on one machine stop sharing one number.
---  * worker names **no** card -> write nothing. Not the machine max. Once the
---    source has proved it is per-card, the machine max is somebody *else's* card,
---    and spending it here would exclude an idle worker because its neighbour runs
---    hot -- a monitoring gap eating capacity, the same failure mode that makes this
---    channel refuse to write 0 or repeat a stale sample. The consequence is stated
---    plainly for whoever configures this: a worker whose card cannot be resolved is
---    not power-capped at all, exactly as if the exporter were down. Register the
---    container with a gpu<N> name (or the equivalent label) to bring it under the
---    cap; watch lr_gpu_load_power_per_card_workers to see how many are covered.
---  * worker names a card and the vector does **not** have it -> write nothing, same
---    reasoning (exporter dropped the card, the card passed through to another
---    container, a stale hint after a rename).
---  Both "write nothing" branches land on registry.power_w() == nil once the old pw:
---  sample TTLs out, and registry.capacity_exclusion reads nil as unknown -> keep.
---  用户裁定 2026-10-04 的降级纪律即此三条：解析不出 gpu / 没有该卡 series / series
---  缺失 -> 不写键，回落「未知 -> 不排除」，绝不摘 worker。
---  * worker names a card and the vector does **not** have it -> write nothing.
---    Deliberately *not* a fallback to the machine max: we know which card this is,
---    the source simply has no series for it (exporter dropped the card, a card
---    passed through to another container, a stale hint after a rename). Reporting
---    another card's watts as this card's reading would exclude an idle worker
---    because its neighbour is hot -- a monitoring gap eating capacity, which is the
---    exact failure this channel is built to avoid. Nothing written -> pw: TTLs ->
---    registry.power_w() == nil -> router's "unknown -> do not exclude".
---`claimed[host]` is set from host-level reachability, not from whether a watt value
---was produced, so power_unmatched keeps its current meaning ("this host's series
---matched no pooled worker") and a missing card cannot inflate it into a bogus label
---mismatch.
---`source_has_cards` accepts a boolean (the metrics path: one /metrics body, so the
---whole question is about that one machine) or a host -> true set (the prom path,
---where one pass can span several machines and even several *kinds* of source). The
---set form is what power_fold already answers as `card_hosts`: if box A reports DCGM
---per-card series and box B only has node_exporter, B's workers must keep the
---whole-machine reading (their source really is not per-card) instead of being
---starved by a global flag A happens to have set.
---@param workers table[]|nil
---@param by_host table|nil @ host -> whole-machine watts
---@param cards table|nil @ card_key(host, gpu) -> watts
---@param source_has_cards boolean|table|nil @ boolean, or host -> true
---@param hints table|nil @ hint_index or raw url -> gpu id
---@return table @ worker id -> watts
---@return number @ unmatched host count
function _M.assign_power(workers, by_host, cards, source_has_cards, hints)
    local out, unmatched = {}, 0
    if type(workers) ~= "table" then
        return out, unmatched
    end
    local claimed = {}
    for i = 1, #workers do
        local worker = workers[i]
        local host = worker and _M.split_host(worker.url)
        if host and type(by_host) == "table" and by_host[host] ~= nil then
            claimed[host] = true
            local watts
            local per_card = source_has_cards
            if type(per_card) == "table" then
                per_card = per_card[host] == true
            end
            if per_card then
                local gpu = _M.worker_card(worker, hints)
                -- 认不出卡 或 该卡无 series -> 什么都不写（不是整机 max）。见上方
                -- 四路口径：源已经是逐卡的了，整机 max 就是**别人那张卡**的瓦特，
                -- 用它顶替会让一张空闲 worker 因为邻居发热而被排除。
                if gpu ~= nil and type(cards) == "table" then
                    watts = cards[_M.card_key(host, gpu)]
                end
            else
                watts = by_host[host]
            end
            if watts ~= nil and worker.id ~= nil then
                out[worker.id] = watts
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
    return out, unmatched
end

---The watt identity rules, shared by both sources (prom rows and one /metrics body).
---
---Why this shape and not a plain group-by: the machine identity of a DCGM series is
---ambiguous by construction, and each of the two wrong answers has been paid for.
---  * dcgm-exporter's machine label is the **capitalised** Hostname, and host_of()
---    only reads lower-case keys, so labels are case-folded first. After folding,
---    Hostname sorts *behind* instance in HOST_LABELS, and every DCGM series carries
---    instance="127.0.0.1:9400" — the scrape address, not the machine. Copying
---    host_of()'s precedence would fold two machines' exporters onto that one value,
---    so A's hottest card pushes B's workers over their cap while unmatched stays 0
---    and no line is logged (cross-machine watt bleed).
---  * Aggregating by (Hostname) alone leaves only the machine name, while 21.k's
---    eight workers are all registered as http://127.0.0.1:80xx, so nothing matches.
---So both keys are registered at once:
---  * a machine-name label (Hostname / hostname / nodename / host / node / pod /
---    name) -> key = machine name;
---  * instance -> key = its host part, adopted only when it is a non-loopback address
---    (a real machine address), or when every series sharing that loopback instance
---    belongs to **one** machine. The latter is this fleet's normal shape (eight
---    workers on 127.0.0.1:80xx meeting DCGM's 127.0.0.1:9400 on the key
---    "127.0.0.1"); once two Hostnames appear behind one loopback instance, that
---    Prometheus scrapes several machines' local exporters and the loopback key has
---    no right to represent any of them -> nothing is adopted, and nothing is guessed.
---Only the power channel uses this; the load channel keeps host_of()'s semantics
---(changing it would move existing e2e assertions).
---@param rows table[]|nil @ parse_prom_response() rows (labels + value)
---@param expose_cards boolean|nil @ also fold per-card keys
---@return table @ host -> watts (whole-machine hottest, only usable readings)
---@return table @ host..CARD_SEP..gpu -> watts (empty unless expose_cards)
---@return table|nil @ host -> true for hosts with at least one card series
---@return boolean @ any usable series carried a numeric gpu label
function _M.power_fold(rows, expose_cards)
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
    local function remember(target, key, watts)
        if target[key] == nil or watts > target[key] then
            target[key] = watts
        end
    end
    for i = 1, #rows do
        local row = rows[i]
        local watts = row and _M.power_watt(row.value)
        if watts and type(row.labels) == "table" then
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
            -- (node_exporter, an operator's by(Hostname) query) working exactly as
            -- it does today.
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
                remember(g.host, machine, watts)
            end
            if inst then
                remember(g.inst, inst, watts)
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
        for inst, watts in pairs(g.inst) do
            local distinct = 0
            for _ in pairs(g.inst_machines[inst] or {}) do
                distinct = distinct + 1
            end
            local loopback = (inst == "localhost" or inst == "::1"
                or string.sub(inst, 1, 4) == "127.")
            if (not loopback) or distinct <= 1 then
                adopted[inst] = watts
            end
        end
        -- Drop machine-name keys fully represented by an adopted instance key: the
        -- instance max already covers that machine's whole series set, so the
        -- machine-name key carries no extra reading and would only inflate
        -- power_unmatched_total (pointing the operator at a label mismatch that does
        -- not exist). A machine-name key kept on its own (by(Hostname)) *is* the
        -- "reachable but unassignable" signal the operator needs, so it stays.
        local kept = {}
        for machine, watts in pairs(g.host) do
            if adopted[machine] ~= nil or machine == "" then
                kept[machine] = watts
            else
                local redundant
                for inst, inst_watts in pairs(adopted) do
                    local seen = g.inst_machines[inst]
                    if seen and seen[machine] and inst_watts >= watts then
                        redundant = true
                        break
                    end
                end
                if not redundant then
                    kept[machine] = watts
                end
            end
        end
        for machine, watts in pairs(adopted) do
            remember(kept, machine, watts)
        end
        if gpu ~= "" then
            for host, watts in pairs(kept) do
                cards[_M.card_key(host, gpu)] = watts
                card_hosts[host] = true
            end
        end
        -- Whole-machine max: this is today's number, folded over *every* series of
        -- the machine regardless of card, so the fallback cannot drift from the
        -- behaviour that shipped before per-card attribution existed.
        for host, watts in pairs(kept) do
            remember(by_host, host, watts)
        end
    end
    return by_host, cards, card_hosts, have_cards
end

---Fold a result vector down to one **watt** reading per host (hottest card wins).
---
---host_values() 的功率版：唯一的区别是不走 normalize()。那是本模块最容易写错的
---一行——照抄 host_values() 会把 96 W 折成 1.0（96/100 夹到上限），于是功率通道
---输出的「1」既不是瓦特也不是负载，上限判定拿它去比 max_power_w 就永远不成立。
---多卡取最大而非取和/取平均：一台 worker 往往看得见整机所有卡，路由要避免把请求
---打到已经最热的那张卡上，取和会让「一张满载七张空闲」看起来仍然很闲。
---
---机器身份的判定规则（含环回 instance 的归属检查）整体在 _M.power_fold() 上说明；
---本函数保持改动前的对外契约（host -> 整机最热瓦特），逐卡展开请用
---_M.host_card_powers()。
---@param rows table[]|nil @ parse_prom_response() rows
---@return table @ host -> watts (only usable readings)
function _M.host_powers(rows)
    local by_host = _M.power_fold(rows, false)
    return by_host
end

---Fold a result vector into **per-card** watt readings as well as per-host.
---
---21.k 生产实况（2026-10-04）：8 个 worker 的 power_w 全是同一个 342.371，因为 compose
---里那条 SMG_LOAD_POWER_QUERY 写的是 max by (Hostname,instance) (DCGM_FI_DEV_POWER_USAGE)
---——Prometheus 侧就已经把 8 张卡折成 1 条 series，逐卡标签根本没能到达网关。逐卡读数
---在 exporter 上一直齐全（/data/tmp/dcgm-metrics-9400.txt：
---DCGM_FI_DEV_POWER_USAGE{gpu="0",...,Hostname="gpu-pro6000-1"} 96.161 … gpu="7" 309.834），
---所以这一路按 gpu 标签建 host+gpu 键，配 registry 记录的 labels.gpu（watcher 从容器名
---解析）把瓦数交回**它自己那张卡**。
---
---默认查询串（部署侧改 compose 的 SMG_LOAD_POWER_QUERY，本仓不改部署）：
---    max by (Hostname, instance, gpu) (DCGM_FI_DEV_POWER_USAGE)
---  * gpu 必须留在 by 里：把它聚合掉 = 回到 342.371 那个故障。
---  * Hostname 也留在 by 里：让 power_fold 能在「一台 Prometheus 抓了多台机器的本机
---    exporter」时识破归属冲突（环回 instance 键只在同批 series 只属一台机器时才采纳），
---    宁可整台不采纳也不会把 A 机最热的卡挂到 B 机头上。
---  * instance 留在 by 里：worker 全注册成 http://127.0.0.1:80xx，机器名与 IP 之间没有
---    可用映射，只有 exporter 的抓取地址能把读数交回本机 worker。
---  * 用 max 而不是 sum：sum 会把同一张卡的多次抓取/多标签副本相加；本模块的口径是
---    「取最热」，不是「取总和」。
---@param rows table[]|nil @ parse_prom_response() rows
---@return table @ host -> watts (whole-machine hottest)
---@return table @ host..CARD_SEP..gpu -> watts
---@return table @ host -> true (hosts exposing at least one card series)
---@return boolean @ any series carried a numeric gpu label
function _M.host_card_powers(rows)
    return _M.power_fold(rows, true)
end

--- Power knobs for this pass, read straight from the environment.
---
--- 为什么读 env 而不是 cfg：resty.luarouter.config 不在本轮改动范围内（它把每个开关都
--- 过一遍 clamp 与缺省归一化），所以这三个名字由本模块自己 os.getenv。三点后果如实写
--- 在这里，别让下一个读者误以为它们已经和其余 SMG_LOAD_* 同等待遇：
---   * nginx 按 `env` 白名单重建 worker 环境，漏声明就静默失效（本仓库踩过的坑），
---     所以三份 conf 都要声明：conf/lua-router.conf、conf/nginx.conf.template，以及集成
---     测试用的 test/conf/nginx-lua-router.conf（_lib.py 的 CONF_TEST 用的正是它，漏了它
---     e2e 里设 SMG_LOAD_POWER=1 会形同虚设）。
---   * worker 环境在 fork 时就固定，全仓没有任何 setenv/putenv，所以这里每 tick 现读并不
---     比 init 期读一次更“热”——真正的生效方式是重启容器 / 重下 compose。别把这三个开关
---     承诺成可热改的能力。
---   * 它们因此也进不了 config_store 的 JSON 文档与 /_ui/config，UI 上看不见也改不了。
---     并进 config.lua 的解析（从而被 JSON 保存链路与管理台覆盖，符合 AGENTS.md「新配置面
---     必须落到可视化」）是紧随其后的收尾项，需要 config 侧的文件所有权。
--- cfg.load_power* 优先于 env：给测试注入用，也是将来接进 config.lua 的天然入口。
---  * SMG_LOAD_POWER       metrics 路是否顺带扫功率（"1"/"true"/"yes"）
---  * SMG_LOAD_POWER_KEYS  覆盖功率 gauge 名单（逗号/空格分隔）
---  * SMG_LOAD_POWER_QUERY prom 路的第二条 PromQL；留空 = 不采功率
---@param cfg table|nil @ router config; cfg.load_power* wins when present
---@return table @ {on, keys, query}
function _M.power_config(cfg)
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
    local on = cfg.load_power
    if on == nil then
        local raw = env("SMG_LOAD_POWER")
        if type(raw) == "string" then
            local lowered = string.lower(raw)
            on = lowered == "1" or lowered == "true" or lowered == "yes" or lowered == "on"
        else
            on = false
        end
    end
    local keys = cfg.load_power_keys
    if keys == nil or (type(keys) == "table" and #keys == 0)
        or (type(keys) == "string" and string.match(keys, "^%s*$")) then
        keys = env("SMG_LOAD_POWER_KEYS")
    end
    local query = cfg.load_power_query
    if query == nil or (type(query) == "string" and query == "") then
        query = env("SMG_LOAD_POWER_QUERY")
    end
    return {
        on = not not on,
        keys = keys,
        query = (type(query) == "string" and query ~= "") and query or nil,
    }
end


-------------------------------------------------------------------- util (0..1)

---Per-card utilization fold: the utilization counterpart of power_fold().
---
---为什么是「抄结构」而不是「抽公共体」：本轮授权明确写着功率通道（assign_power /
---power_fold / host_powers / host_card_powers）**原样保留不动**——它仍是纯观测，容量判定
---不再读它（用户裁定 2026-10-06：功率退役为观测字段，利用率接手上限判定）。把两路的机器
---身份规则抽成一个共享 fold 是更好的长期形状，但那要改功率那一路的实现，风险与本轮的
---「功率零改动」纪律不成比例，所以这里逐条复刻同三条规则，并在两份注释之间互相指认，等
---功率真正退役那一轮再合并（口径见 doc/caps-redesign-2026-10-06.md §1）。
---
---三条身份规则与功率那一路完全同源（它们已被 21.k 的 342.371 与跨机 bleed 两笔学费钉死）：
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
---唯一与功率不同的是「什么样的读数算可用」：功率用 power_watt()（<= 0 拒收，本 fleet 的卡
---空载也有 80-90 W，0 只可能是 exporter 撒谎）；利用率用 util_fraction()，**0 是合法读数**
---（DCGM 空载就报 0 %，准入门要把它读成「远低于任何上限」，那正是它该读成的样子），拒负数 /
---NaN / ±inf / 超界。
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
---功率通道的孪生体：四路口径逐行参照 assign_power（:188），差别只有一支，而那一支是刻意
---的（doc/caps-redesign-2026-10-06.md §5 钉死，不是笔误）：
---  * 源根本没有逐卡标签（source_has_cards 假）-> 整机最热卡的利用率。与功率同：这是老
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
---功率在那后两支什么都不写（宁可「未知 -> 不排除」，绝不拿邻居那张卡的瓦特冒充）；利用率
---回退而不是留空，因为两个量的代价方向不同：
---  * 功率上限读的是绝对瓦特。整机 max 会把邻居的热度算到一个空闲 worker 头上而把它摘出
---    候选集——一个监控缺口吃掉容量，正是这条通道最不肯犯的错。
---  * 利用率上限读的是「这张卡忙不忙」。整机 max 在利用率语义下是保守方向：本机只要有任何
---    一张卡忙，就把这台 worker 当忙看待，代价是少用一台机器（吞吐），而不是让满载的卡
---    继续接新请求（排队与延迟）。「不知道哪张卡归它」时，按最热的算比当它永远不忙诚实。
---    而且归属冲突在这里会被识破：源已是逐卡而这块卡认不出来时，写进去的数是**别人那张卡**
---    的利用率，所以它必须被计数、被说出来（fallback++，见 export.lua 那一族），不能像
---    「本机就是整机口径」那样混在同一个数里——fallback 与 per_card 并排读就是覆盖率。
---  * 这条回退**不是静默的**：每一次回退都进 lr_gpu_load_util_fallback_total；处方与功率侧
---    同一套——把容器登记成带 gpuN 的名字（让 watcher 台账有 g| 键），并确认
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
                -- 整机 max 回退：功率侧在同样位置选择什么都不写（代价方向不同，见上方
                -- 那一支）。源本身没有卡标签时也走这里——那本来就是整机口径，如实计入
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
---host_card_powers() 的利用率版（身份规则见 util_fold 上方）。
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
--- 与 power_config() 的三点差别如实写在这里，别让下一个读者以为两路完全同等待遇：
---   * 这两个开关**走 config.lua**（cfg.load_util_enabled / cfg.load_util_query 由
---     SMG_LOAD_UTIL_ENABLED / SMG_LOAD_UTIL_QUERY 在 init_by_lua 里装配），所以它们天然
---     进得了 /probe/config 与管理台可见面（AGENTS.md 重点 3）。下面的 env 分支是给「手搓
---     cfg 表」的调用者（单测、探针）留的注入面，与 power_config 的 env() 同形；生产上请
---     配 config.lua 那一份。三份 conf 也一并声明了 SMG_LOAD_UTIL_*，两条路都通——漏一份
---     env 声明时 os.getenv 那一路会静默失效，而 config 那一路不受影响。
---   * 与功率那三个名字一样，这里每 tick 现读并不比 init 期读一次更「热」：worker 环境在
---     fork 时固定，全仓没有 setenv/putenv，生效方式是重启容器。别把它承诺成可热改。
---   * 开关缺省 **1**（doc/caps-redesign-2026-10-06.md §5）。功率缺省关是因为它会多打一条
---     查询并喂一个可能没人用的准入门；利用率缺省开的理由是它的**判定**并不由这个开关决定
---     ——采集只把读数写进 registry 的 gu: 键，只有记录上显式配了 max_gpu_util 才有人读它，
---     所以缺省开不会改变任何现有部署的选路行为（红线「缺省零行为变化」由判定侧的「读数未知
---     -> 不排除」与「没配上限 -> 零 shdict 读」保证）。缺省关的代价则是操作员多记一个开关
---     才知道利用率上限为什么一直按「未知」放行。
---  * SMG_LOAD_UTIL_ENABLED  "1"/"true"/"yes"/"on" 开（缺省开）；其余判关
---  * SMG_LOAD_UTIL_KEYS     覆盖 metrics 路的利用率 gauge 名册（逗号/空格分隔）
---  * SMG_LOAD_UTIL_QUERY    prom 路的第三条 PromQL；留空 = 用缺省查询串
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
            -- 缺省开；唯一的显式关法是 0/false/no/off 或任何不被认识的值（与 power_config
            -- 的判真口径一致：不认识 = 关）。
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
    -- 「操作员到底有没有写过这条查询」必须能分开：prom 路的整轮 skip 判据（负载与功率两条
    -- 查询都没配就整轮不跑）不能因为利用率有缺省串而被推翻——否则每个只配负载查询的部署都
    -- 会多打一条没人要求的 POST。反过来，操作员**显式**写了 SMG_LOAD_UTIL_QUERY 就是明确的
    -- 意图信号，那条查询必须能单独把这一路跑起来（与功率那一路的待遇一致）。
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
