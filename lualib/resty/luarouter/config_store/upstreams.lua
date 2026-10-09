-- resty.luarouter.config_store.upstreams
-- P11 声明层校验与脱敏 + P29 drift / patch / reconcile（声明层 → lr_workers 的投影）。
--
-- 由 lualib/resty/luarouter/config_store.lua 拆分而来：函数体逐行原样搬家，只调整 require 与
-- 跨模块接线（doc/refactor-arch-2026-10-05.md §1–§2）。原文里经 _M.x() 的自调 → 经 CS_FACADE
-- 表调用（保住单测换桩的可拦截性逐点一致）；原文里的同文件 local 直调 → 直接 require 对端
-- 子模块的共享表调用（不进 facade 导出面，_M 契约因此逐名不变）。
local CS_FACADE = require "resty.luarouter.config_store"
local cjson = require "cjson.safe"
local EMPTY_ARRAY_MT = cjson.empty_array_mt
local JSON_NULL = cjson.null
local CS_LEXICON = require "resty.luarouter.config_store.lexicon"
local CS_PROFILES = require "resty.luarouter.config_store.profiles"
local CS_PERSISTENCE = require "resty.luarouter.config_store.persistence"

local _M = {}

local UPSTREAMS_LIMIT = 256

-- Ranges from doc/caps-redesign-2026-10-06.md §1, kept as named constants because three
-- separate code paths (parse, the console's own copy of the rule, and the error text) have
-- to agree on them: min 1..31 leaves room below a max of 32 so the strict-less-than rule
-- always has a legal spelling, and util 0..100 is a whole percentage.
local MIN_CONCURRENCY_LIMIT = 31
local MAX_CONCURRENCY_LIMIT = 32
local MAX_GPU_UTIL_LIMIT = 100

-- Per-instance capacity gates (doc/caps-redesign-2026-10-06.md §1). The three fields share
-- one field list so parse / defaults / drift / patch / create cannot drift apart, and one
-- normalizer dispatch so a field's "unlimited" spelling is decided in exactly one place:
-- the two concurrency tiers go through declared_cap (registry.cap_limit), the utilisation
-- tier through declared_util (0 is a legal, strict reading there, which cap_limit would
-- erase).
local CAP_FIELDS = { "min_concurrency", "max_concurrency", "max_gpu_util" }

local function cap_normalize(field, value)
    if field == "max_gpu_util" then return CS_PROFILES.declared_util(value) end
    return CS_PROFILES.declared_cap(value, true)
end

--- The one value the *pool side* reads back as "no limit" for this field. The concurrency
--- tiers keep the historical explicit 0 (cap_limit folds <= 0 to nil, and an uncapped
--- record costs no dict read). The utilisation tier cannot use 0 -- that is its strictest
--- legal value -- so it clears with an explicit -1, which declared_util / the registry's
--- util reader fold to nil. Same "explicit sentinel, only sent when the stored row really
--- holds a limit" rule as before; only the sentinel spelling is per-tier.
local function cap_clear_value(field)
    if field == "max_gpu_util" then return -1 end
    return 0
end

--- Mask one upstreams row for a response body (contract 3.4): api_key is
--- present but always null, has_api_key says whether a secret is held, and the
--- persistence fields (api_key_state / api_key_stored) never leave the store.
local function sanitize_upstream_row(row)
    local out = {}
    for key, value in pairs(row) do
        if key ~= "api_key" and key ~= "api_key_state" and key ~= "api_key_stored" then
            out[key] = value
        end
    end
    out.api_key = JSON_NULL
    out.has_api_key = (row.api_key_state == "set") == true
    return out
end

local function sanitize_upstream_rows(rows)
    local out = {}
    for _, row in ipairs(rows or {}) do out[#out + 1] = sanitize_upstream_row(row) end
    if #out == 0 then return setmetatable({}, EMPTY_ARRAY_MT) end
    return out
end

--- Validate + normalize one upstreams entry. Returns (entry, nil) or (nil, err).
--- The entry keeps the three-state api_key (absent / JSON_NULL = keep, "" =
--- clear, non-empty = set) plus api_key_stored for persistence.
local function upstream_from_entry(entry, index)
    local who = "upstreams[" .. tostring(index) .. "]"
    if type(entry) ~= "table" then
        return nil, who .. " must be an object"
    end
    local url = type(entry.url) == "string" and CS_LEXICON.trim(entry.url) or ""
    if url == "" then
        return nil, "every upstreams entry needs a url"
    end
    local canonical = CS_PROFILES.norm_pool_url(url)
    if not canonical then
        return nil, string.format("invalid upstream url %s (want http(s)://host[:port])", url)
    end
    local out = { url = canonical }

    if rawget(entry, "model_id") ~= nil and entry.model_id ~= JSON_NULL then
        if type(entry.model_id) ~= "string" then
            return nil, string.format("upstream %s model_id must be a string", canonical)
        end
        local model_id = CS_LEXICON.trim(entry.model_id)
        if model_id ~= "" then out.model_id = model_id end
    end

    -- Advertised coverage of this endpoint. An operator can name more than the one
    -- model the engine happens to report first (a merged endpoint serves two, or the
    -- engine's /v1/models answer is not the name the virtual model binds to), which is
    -- what makes a per-candidate binding verifiable before traffic arrives. Absent =
    -- "the probe decides", so this never overwrites what a sweep learned.
    if rawget(entry, "models") ~= nil and entry.models ~= JSON_NULL then
        if not CS_LEXICON.is_array(entry.models) then
            return nil, string.format("upstream %s models must be an array of strings", canonical)
        end
        local list, seen = {}, {}
        for _, item in ipairs(entry.models) do
            if type(item) ~= "string" then
                return nil, string.format("upstream %s models must be an array of strings", canonical)
            end
            local name = CS_LEXICON.trim(item)
            if name ~= "" and not seen[name] then
                seen[name] = true
                list[#list + 1] = name
            end
        end
        if #list > 0 then out.models = list end
    end

    -- Key tri-state (contract 3.4): absent / null = keep, "" = clear, non-empty
    -- = set. The persisted form additionally carries api_key_state plus
    -- api_key_stored, so a document rewrite that only knows the masked display
    -- shape (api_key: null) cannot lose the secret.
    local state, stored = "keep", nil
    local declared = rawget(entry, "api_key_state")
    if declared ~= nil and declared ~= JSON_NULL then
        if declared ~= "keep" and declared ~= "set" and declared ~= "clear" then
            return nil, string.format("upstream %s api_key_state must be keep, set or clear", canonical)
        end
        state = declared
    end
    -- The operative secret: api_key carries what the UI typed, api_key_stored
    -- what the persisted snapshot carries. A display null on either field is
    -- "not said" rather than "said empty", so the masked document shape
    -- round-trips through the JSON editor without touching the key.
    local explicit, explicit_field
    for _, field in ipairs({ "api_key", "api_key_stored" }) do
        local value = rawget(entry, field)
        if value ~= nil and value ~= JSON_NULL then
            explicit, explicit_field = value, field
            break
        end
    end
    if explicit ~= nil then
        if type(explicit) ~= "string" then
            return nil, string.format("upstream %s %s must be a string or null", canonical, explicit_field)
        end
        if explicit == "" then
            state, stored = "clear", nil
        else
            state, stored = "set", explicit
        end
    elseif state == "set" then
        CS_LEXICON.ngx_log_warn("luarouter upstream ", canonical,
            " api_key_state set without api_key_stored; treating as keep")
        state = "keep"
    end
    out.api_key_state = state
    out.api_key_stored = stored

    for _, field in ipairs({ "priority", "cost" }) do
        local value = rawget(entry, field)
        if value ~= nil and value ~= JSON_NULL then
            local number = tonumber(value)
            if not number then
                return nil, string.format("upstream %s %s must be a number", canonical, field)
            end
            out[field] = number
        end
    end

    if rawget(entry, "labels") ~= nil and entry.labels ~= JSON_NULL then
        if type(entry.labels) ~= "table" then
            return nil, string.format("upstream %s labels must be an object of string values", canonical)
        end
        local labels = {}
        for k, v in pairs(entry.labels) do
            if type(k) ~= "string" or type(v) ~= "string" then
                return nil, string.format("upstream %s labels must be an object of string values", canonical)
            end
            labels[k] = v
        end
        if next(labels) then out.labels = labels end
    end

    local dhc = rawget(entry, "disable_health_check")
    if dhc ~= nil and dhc ~= JSON_NULL then
        if type(dhc) ~= "boolean" then
            return nil, string.format("upstream %s disable_health_check must be a boolean", canonical)
        end
        out.disable_health_check = dhc
    end

    -- Per-worker capacity gates (doc/caps-redesign-2026-10-06.md §1, which supersedes
    -- doc/gap-worker-caps.md): the pool side accepts them on POST/PUT /workers, so a
    -- declaration that cannot carry them is a field the console can set and the document
    -- cannot keep. Absent / null / "means unlimited" all store as *absent* (never an
    -- explicit null) exactly like the other optional fields, so a row that never mentions
    -- caps keeps its pre-feature byte-identical shape.
    --
    -- How hard each tier pushes back on a value it cannot use is decided per tier, and the
    -- asymmetry is deliberate:
    --   * max_concurrency keeps today's normalization verbatim. The console has always sent
    --     an explicit 0 for "unlimited" and 2.5 for "at most 2", and five readers (add /
    --     update / info / capacity_exclusion / declared_cap) share that one folding, so the
    --     declaration layer must not unilaterally turn a legacy spelling into a 400
    --     (doc/gap-worker-caps.md §8 item 3). Anything cap_limit reads as unlimited is
    --     stored as *absent*, and a whole number above 32 is the only refusal.
    --   * min_concurrency is new, so it has no legacy spelling to honour: a value that is
    --     not a whole 1..31 is a typo, and a floor the gateway quietly dropped is a gate
    --     the operator believes is closed -- 400.
    --   * max_gpu_util follows the design's split: a negative or non-numeric reading is
    --     "not said" (nil, same unlimited the reader would fold it to), while a number that
    --     cannot be a whole percentage -- 101, 55.5 -- is refused. Zero passes through: it
    --     is the strictest legal gate, not an absence.
    local caps_said = {}
    for _, field in ipairs(CAP_FIELDS) do
        local value = rawget(entry, field)
        if value ~= nil and value ~= JSON_NULL then
            if field == "max_gpu_util" then
                local number = tonumber(value)
                if number ~= nil and number == number
                    and number ~= math.huge and number ~= -math.huge then
                    if number < 0 then
                        -- "said nothing": the reader folds it to unlimited either way.
                        number = nil
                    elseif number > MAX_GPU_UTIL_LIMIT or math.floor(number) ~= number then
                        return nil, string.format(
                            "upstream %s max_gpu_util must be a whole percentage between 0 and %d",
                            canonical, MAX_GPU_UTIL_LIMIT)
                    end
                else
                    number = nil
                end
                if number ~= nil then
                    -- The registry reader stays the authority for the *stored* value (same
                    -- posture as the concurrency tier): the range checks above decide what
                    -- counts as said-vs-400, declared_util decides the canonical number
                    -- that lands in the row.
                    local cap = CS_PROFILES.declared_util(number)
                    if cap ~= nil then
                        out[field] = cap
                        caps_said[field] = cap
                    end
                end
            elseif field == "max_concurrency" then
                local cap = CS_PROFILES.declared_cap(value, true)
                if cap ~= nil then
                    if cap > MAX_CONCURRENCY_LIMIT then
                        return nil, string.format(
                            "upstream %s max_concurrency must be at most %d",
                            canonical, MAX_CONCURRENCY_LIMIT)
                    end
                    out[field] = cap
                    caps_said[field] = cap
                end
            else
                local cap = cap_normalize(field, value)
                -- Integrality is tested on the raw reading, not on the normalized one:
                -- cap_limit *floors* a fractional value (that is what makes 2.5 a legal
                -- max_concurrency), so by the time this branch sees it a typo like 1.5 has
                -- already become a plausible 1. A floor is not a number the operator has to
                -- be protected from rounding -- it is the green threshold, so a fractional
                -- reading is a typo and says nothing about what was meant.
                local number = tonumber(value)
                if cap == nil or number == nil or cap ~= number
                    or cap < 1 or cap > MIN_CONCURRENCY_LIMIT then
                    return nil, string.format(
                        "upstream %s min_concurrency must be an integer between 1 and %d",
                        canonical, MIN_CONCURRENCY_LIMIT)
                end
                out[field] = cap
                caps_said[field] = cap
            end
        end
    end
    -- Both concurrency tiers declared: the green floor has to sit strictly below the red
    -- ceiling, otherwise "idle" and "full" overlap (or invert) and every state judgment in
    -- the pool becomes arbitrary. max_concurrency unlimited (nil) has no ceiling to violate.
    if caps_said.min_concurrency ~= nil and caps_said.max_concurrency ~= nil
        and caps_said.min_concurrency >= caps_said.max_concurrency then
        return nil, string.format(
            "upstream %s min_concurrency (%d) must be less than max_concurrency (%d)",
            canonical, caps_said.min_concurrency, caps_said.max_concurrency)
    end
    return out, nil
end

--- Whole-section validation for upstreams: array, cap, url dedup. `previous`
--- (optional, url -> {api_key_state, api_key_stored}) is the declaration layer
--- being replaced: a row that says nothing about the key inherits the stored
--- secret rather than dropping it, which is what makes a masked document
--- round-trip (GET /_ui/config -> JSON editor -> apply) key-preserving. An
--- explicit "" still clears, and a url that changed identity inherits nothing.
local function build_upstreams(rows, previous)
    if rows == nil or rows == JSON_NULL then rows = {} end
    if not CS_LEXICON.is_array(rows) then return nil, "upstreams must be an array" end
    if #rows > UPSTREAMS_LIMIT then
        return nil, string.format("upstreams exceeds the %d entry limit", UPSTREAMS_LIMIT)
    end
    local out, seen = {}, {}
    for i, entry in ipairs(rows) do
        local item, err = upstream_from_entry(entry, i)
        if not item then return nil, err end
        if seen[item.url] then
            return nil, string.format("duplicate upstream url after normalization: %s", item.url)
        end
        seen[item.url] = true
        if item.api_key_state == "keep" and not item.api_key_stored and previous then
            local before = previous[item.url]
            if before and before.api_key_state == "set" and before.api_key_stored then
                item.api_key_state = "set"
                item.api_key_stored = before.api_key_stored
            end
        end
        out[#out + 1] = item
    end
    return out, nil
end

--- The live declaration layer in the shape build_upstreams wants for inheritance.
local function previous_upstream_map(cfg)
    local by_url = {}
    for _, item in ipairs((cfg and cfg.upstreams) or {}) do
        if type(item) == "table" and type(item.url) == "string" then
            by_url[item.url] = item
        end
    end
    return by_url
end

-- ------------------------------------------------------------- config shape
-- Internal (map) form; the disk / dict form is the array snapshot below.

local function upstream_defaults(item)
    return {
        model_id = (type(item.model_id) == "string" and item.model_id ~= "") and item.model_id or "unknown",
        priority = tonumber(item.priority) or 50,
        cost = tonumber(item.cost) or 1.0,
        labels = item.labels or {},
        disable_health_check = (item.disable_health_check and true) or false,
        -- Caps are projected through the same normalizer here (rather than read raw)
        -- so drift and patch see *one* value for "unlimited": nil. The record side is
        -- normalized the same way before comparison, which is what stops a row that
        -- declares no cap from reporting drift against a worker that has none either
        -- (a permanent drift would make the 30s self-heal rewrite the same worker
        -- forever, the failure mode models_covered() exists to avoid).
        min_concurrency = cap_normalize("min_concurrency", item.min_concurrency),
        max_concurrency = cap_normalize("max_concurrency", item.max_concurrency),
        max_gpu_util = cap_normalize("max_gpu_util", item.max_gpu_util),
    }
end

--- Does the stored advertised list already carry everything the row declares?
---
--- Subset rather than equality, because the registry *folds* a declaration into what
--- the probe learned (registry.merge_models): a worker that advertises two models and
--- is declared with one is converged, and comparing the raw declaration against the
--- merged list would report drift forever -- the 30s self-heal would rewrite the same
--- worker on every tick and never settle.
local function models_covered(want, have)
    if want == nil then return true end
    have = have or {}
    for i = 1, #want do
        local found = false
        for j = 1, #have do
            if have[j] == want[i] then
                found = true
                break
            end
        end
        if not found then return false end
    end
    return true
end

local function same_labels(a, b)
    a = a or {}
    b = b or {}
    for k, v in pairs(a) do
        if b[k] ~= v then return false end
    end
    for k, v in pairs(b) do
        if a[k] == nil or a[k] ~= v then return false end
    end
    return true
end

--- True when applying `item` to `record` would change the stored worker. Root
--- ruling 1: an unchanged declaration must not count as an update, and a keep
--- (null/absent) api_key is never a change.
local function upstream_drifts(item, record)
    local want = upstream_defaults(item)
    if (record.model_id or "unknown") ~= want.model_id then return true end
    if (tonumber(record.priority) or 50) ~= want.priority then return true end
    if (tonumber(record.cost) or 1.0) ~= want.cost then return true end
    if ((record.disable_health_check and true) or false) ~= want.disable_health_check then
        return true
    end
    -- Caps on both sides go through the same normalizer before they are compared:
    -- a PUT of 0 or a negative is stored verbatim by registry.update, but cap_limit
    -- reads all of those as "unlimited", and an absent field is also "unlimited".
    -- Comparing raw would report a drift that the pool can never satisfy (the two
    -- stored shapes both normalize to nil), i.e. the endless self-heal loop again.
    for _, field in ipairs(CAP_FIELDS) do
        local have = cap_normalize(field, record[field])
        if have ~= want[field] then return true end
    end
    if not same_labels(want.labels, record.labels) then return true end
    -- Drift is judged against the *merged* list the registry would end up with, not
    -- against the declaration: the registry folds a declared single model into what
    -- the probe already learned (registry.merge_models), so comparing the raw
    -- declaration against the stored list would report a permanent drift and the
    -- 30s self-heal would rewrite the same worker forever.
    if not models_covered(item.models, record.models) then return true end
    local stored = record.api_key
    if stored == false or stored == cjson.null then stored = nil end
    if item.api_key_state == "set" then
        return stored ~= item.api_key_stored
    elseif item.api_key_state == "clear" then
        return stored ~= nil and stored ~= ""
    end
    return false
end

--- What registry.update should receive for one drifted config worker. Only the
--- tri-state key is sent when it says so; keep never touches the stored secret.
---
--- `record` (the live pool row, optional) decides only the cap *clears*: registry.update
--- ignores an absent or null number field, so "the declaration stopped naming a cap"
--- cannot be sent as a deletion -- the pool only reads back "unlimited" from an explicit
--- sentinel its own reader folds to nil: 0 for the concurrency tiers (cap_limit folds
--- <= 0), and -1 for the utilisation tier, which cannot use 0 because that is its
--- strictest gate (see cap_clear_value). Each sentinel is sent only when the stored row
--- really holds a limit; sending them unconditionally would materialize keys on every
--- config worker the operator never capped, which is the byte-shape change this layer
--- promises to avoid.
local function upstream_patch(item, record)
    local want = upstream_defaults(item)
    local patch = {
        model_id = want.model_id,
        priority = want.priority,
        cost = want.cost,
        labels = want.labels,
        disable_health_check = want.disable_health_check,
    }
    for _, field in ipairs(CAP_FIELDS) do
        if want[field] ~= nil then
            patch[field] = want[field]
        elseif record and cap_normalize(field, record[field]) ~= nil then
            patch[field] = cap_clear_value(field)
        end
    end
    -- Carried only when the row says something: registry.patch_record folds it into
    -- the stored list rather than replacing it, so a declaration that names one model
    -- cannot erase the rest of what the probe learned.
    if item.models then patch.models = item.models end
    if item.api_key_state == "set" then
        patch.api_key = item.api_key_stored
    elseif item.api_key_state == "clear" then
        patch.api_key = ""
    end
    return patch
end

--- Caps-only patch for a row the declaration layer does NOT own (protected:
--- watcher / SMG_WORKER_URLS bootstrap / manual POST /workers). Returns nil when
--- the row has nothing to say.
---
--- 为什么这一份要单独写、而不是复用 upstream_patch：上游那份会把 model_id / priority /
--- cost / labels / disable_health_check 一起下发，而 registry.update 对 protected 行恰恰
--- 拒绝其中判身份的那几个（registry.lua:3159 那道 current.discovery == "config" 的门：
--- 非 config 行的 model_id / models 会被丢掉）。丢掉是对的（那是「手填配置不能冒充引擎
--- 读数」的守卫），但正因为它会丢，拿 upstream_drifts 去判 protected 行会永远报漂移 ——
--- 声明写的 model_id 与探针学到的那个不同、而 update 又永远改不动它，于是 init.lua 的
--- 30s 自愈计时器每轮都重写同一个 worker、每轮都不收敛（正是 models_covered 存在理由所
--- 针对的那类死循环）。所以判漂移与下补丁都必须只看 caps。
---
--- 只「下发」不「清除」，同样是刻意的：声明层没写 caps 时这里答 nil（= 沉默），而不像
--- upstream_patch 那样补一个 0 去抹掉存量上限。protected 行的上限可能来自操作员手工
--- PUT /workers，那是声明层从未主张过所有权的读数；「我这行没写」应当读成「我对这行
--- 无话可说」，而不是「我命令它回到无上限」。不对称的代价如实登记在此：从声明里删掉一个
--- caps 不会立刻摘掉 dynamic 行上的存量上限，它会在下一次容器重启（记录重新播种）时自然
--- 消失；要当场摘，用 PUT /workers 显式写 0。
---@param item table @ declared row
---@param record table @ live pool row
---@return table|nil patch @ nil = nothing to project
local function upstream_caps_only_patch(item, record)
    local patch
    for _, field in ipairs(CAP_FIELDS) do
        local want = cap_normalize(field, item[field])
        if want ~= nil then
            local have = record and cap_normalize(field, record[field]) or nil
            if have ~= want then
                patch = patch or {}
                patch[field] = want
            end
        end
    end
    return patch
end
--- 红线口径（doc/gap-worker-caps.md 第 312 行第 4 项）。原话「手填配置不能凭它判死一个健康
--- 实例」被落地成了「protected 行整行不许声明层碰」，这个表述会误导下一个人继续绕开 caps
--- （本函数存在的全部理由就是那次误解）。红线保护的对象是身份与健康判定：discovery、
--- is_healthy、探活结论、判死逻辑，以及 model_id / models 这两份引擎读数 —— 声明层一个字都
--- 改不动，执行由 registry.update 里那道 current.discovery == "config" 的门负责（本函数
--- 刻意不往补丁里放这些键，即便放了也会被那扇门丢掉，两道保险）。红线不覆盖调度旋钮：
--- caps 从不判死，只在超限时把请求迁走（registry.capacity_exclusion 是排除而不是否决，
--- 读数未知时连排除都不做），因此下发它们不触碰原话担心的那件事。

--- Idempotent projection of the declared upstreams into the worker pool
--- (contract 3.1 / 3.2). Rows the declaration layer owns (discovery == "config")
--- are projected whole; a protected row (watcher / bootstrap / manual) gets only
--- the scheduling knobs it still needs to survive a restart -- see
--- upstream_caps_only_patch for what that excludes and why. Only config rows are
--- ever reclaimed. Returns a summary {added=,updated=,removed=,skipped=} (arrays
--- also carry the affected urls). Without a usable registry module (unit caliber,
--- stripped build) every counter is 0 and nothing counts as an error.
function _M.reconcile_upstreams()
    local summary = { added = 0, updated = 0, removed = 0, skipped = 0 }
    local reg = CS_LEXICON.store_registry()
    if not reg or type(reg.records) ~= "function"
        or type(reg.add) ~= "function" or type(reg.update) ~= "function"
        or type(reg.remove) ~= "function" then
        return summary
    end
    local declared = CS_FACADE.current().upstreams or {}

    local all_records = {}
    local by_endpoint = {}
    local ok_records, records_or_err = pcall(reg.records)
    if ok_records and type(records_or_err) == "table" then
        for _, record in ipairs(records_or_err) do
            if type(record) == "table" and type(record.url) == "string" then
                all_records[#all_records + 1] = record
                local key = CS_PROFILES.norm_pool_url(record.url) or record.url
                local slot = by_endpoint[key]
                if not slot then
                    slot = {}
                    by_endpoint[key] = slot
                end
                if record.discovery == "config" or not slot.chosen then
                    slot.chosen = record
                end
            end
        end
    end

    local owned = {}
    for _, item in ipairs(declared) do
        local key = CS_PROFILES.norm_pool_url(item.url) or item.url
        owned[key] = true
        local slot = by_endpoint[key]
        local record = slot and slot.chosen
        if not record then
            local res, aerr, kind = reg.add({
                url = item.url,
                -- Same pass-through as the patch path: registry.add seeds the record's
                -- advertised list from `models`, falling back to model_id, so a worker
                -- created by the declaration layer starts out carrying everything the
                -- operator said about it instead of waiting for a sweep.
                models = item.models,
                model_id = (type(item.model_id) == "string" and item.model_id ~= "") and item.model_id or "unknown",
                api_key = (item.api_key_state == "set") and item.api_key_stored or nil,
                priority = tonumber(item.priority) or 50,
                cost = tonumber(item.cost) or 1.0,
                labels = item.labels or {},
                disable_health_check = (item.disable_health_check and true) or false,
                -- Caps ride the create path too, so a worker the declaration layer
                -- creates is born gated instead of waiting for the next drift tick: the
                -- self-heal gap between add and the following reconcile would otherwise
                -- let one uncapped request through a worker the operator had already
                -- fenced. registry.add normalizes them with the same readers (cap_limit
                -- for the two concurrency tiers, the utilisation reader for the third).
                min_concurrency = cap_normalize("min_concurrency", item.min_concurrency),
                max_concurrency = cap_normalize("max_concurrency", item.max_concurrency),
                max_gpu_util = cap_normalize("max_gpu_util", item.max_gpu_util),
                discovery = "config",
            }, CS_LEXICON.store_config() or {})
            if res then
                summary.added = summary.added + 1
            else
                -- Duplicate url (a race with discovery) still means the pool has
                -- the endpoint; anything else is a real validation failure.
                if kind == "validation" and type(aerr) == "string"
                    and aerr:find("already exists", 1, true) == nil then
                    CS_LEXICON.ngx_log_warn("luarouter upstream add failed for ", item.url, ": ", aerr)
                end
                summary.skipped = summary.skipped + 1
            end
        elseif record.discovery == "config" then
            if upstream_drifts(item, record) then
                local upd_id = record.id
                if type(upd_id) ~= "string" then
                    local ok_id, derived = pcall(reg.worker_id_for_url, item.url)
                    upd_id = ok_id and derived or nil
                end
                local res, uerr = reg.update(upd_id, upstream_patch(item, record))
                if res then
                    summary.updated = summary.updated + 1
                else
                    CS_LEXICON.ngx_log_warn("luarouter upstream update failed for ", item.url, ": ", uerr or "?")
                    summary.skipped = summary.skipped + 1
                end
            end
        else
            -- Held by the watcher / bootstrap / an operator: the row is left as it
            -- is, with one narrow exception. The pool record only lives in the
            -- lr_workers shdict (there is no on-disk path for it), so a container
            -- restart re-seeds it bare from SMG_WORKER_URLS and any cap the operator
            -- set through PUT /workers evaporates. The declaration layer is the only
            -- thing that survives a restart, so the caps have to ride it, otherwise
            -- there is no spelling at all that outlives a restart: the create path is
            -- closed by registry.add refusing an existing url and the update path was
            -- closed by this very branch.
            --
            -- Caps only (see upstream_caps_only_patch): identity and health verdicts
            -- stay untouched, and a row that declares no cap is left exactly as it
            -- was, which is what keeps the pre-feature behaviour byte-identical for
            -- every pool row that never opted in.
            local caps_patch = upstream_caps_only_patch(item, record)
            if caps_patch then
                local upd_id = record.id
                if type(upd_id) ~= "string" then
                    local ok_id, derived = pcall(reg.worker_id_for_url, item.url)
                    upd_id = ok_id and derived or nil
                end
                local res, uerr = reg.update(upd_id, caps_patch)
                if res then
                    summary.updated = summary.updated + 1
                else
                    CS_LEXICON.ngx_log_warn("luarouter upstream caps update failed for ",
                        item.url, ": ", uerr or "?")
                    summary.skipped = summary.skipped + 1
                end
            else
                summary.skipped = summary.skipped + 1
            end
        end
    end

    for _, record in ipairs(all_records) do
        local key = CS_PROFILES.norm_pool_url(record.url) or record.url
        if record.discovery == "config" and not owned[key] then
            local res, rerr = reg.remove(record.id)
            if res then
                summary.removed = summary.removed + 1
            else
                CS_LEXICON.ngx_log_warn("luarouter upstream remove failed for ",
                    tostring(record.url), ": ", rerr or "?")
            end
        end
    end

    local shared = CS_PERSISTENCE.dict()
    if shared then
        local token = CS_FACADE.policy_revision() or tostring((ngx and ngx.now and ngx.now()) or os.time())
        local ok_set, serr = shared:set(CS_PERSISTENCE.UPS_REV_KEY, token)
        if not ok_set then
            CS_LEXICON.ngx_log_warn("luarouter upstreams revision write failed: ", serr or "?")
        end
    end
    return summary
end

-- ------------------------------------------------- 跨子模块直调的原文 local
-- 这些函数在原文里是同文件 local 直调、从未挂在 _M 上；拆开后由调用方直接 require 本表
-- 调用（不经 facade，所以既不是新增导出、也不给单测多开一个可替换点）。
-- 容量门字段名册：本波新增的共享件（doc/caps-redesign-2026-10-06.md §1）。snapshot.lua
-- 的落盘段与 reconcile 的三条写路径都从这同一份名单取值，字段不在两个文件里各写一遍。
-- 不是导出面契约的一部分（老 _M 契约逐名不变），只是跨子模块共用。
_M.CAP_FIELDS = CAP_FIELDS
_M.build_upstreams = build_upstreams
_M.previous_upstream_map = previous_upstream_map
_M.sanitize_upstream_rows = sanitize_upstream_rows
_M.upstream_from_entry = upstream_from_entry

return _M
