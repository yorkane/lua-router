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

return _M
