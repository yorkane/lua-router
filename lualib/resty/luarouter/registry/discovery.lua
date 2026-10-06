-- registry.discovery - probes, coverage learning, PUT update, metadata discovery,
-- DP expansion, the job queue and the SMG_WORKER_URLS seed (blocks Q/R/S/T/U/V).
--
-- Cut verbatim out of registry.lua (refactor 2026-10-05,
-- doc/refactor-arch-2026-10-05.md section 1).
--
-- Everything that dials an engine lives here and everything it touches is
-- accuracy-only: a probe failure costs precision, never a worker (AGENTS.md hard
-- rule 4). The record writers are borrowed from registry.records - patch_record,
-- add and remove - and stay behind registry.keys.with_lock.

local M = {}

local cjson = require "cjson.safe"
local keys = require "resty.luarouter.registry.keys"
local recs = require "resty.luarouter.registry.records"

local json_encode = cjson.encode
local json_decode = cjson.decode
-- Same reason as in registry/records: these were direct calls inside
-- the original file, so they stay direct calls here.
local shdict = keys.shdict
local with_lock = keys.with_lock
local patch_record = recs.patch_record
local norm_models = recs.norm_models
local needs_models_refresh = recs.needs_models_refresh

local K_DISC = keys.K_DISC
local K_DPROBE = keys.K_DPROBE
local K_IDURL = keys.K_IDURL
local K_JOB = keys.K_JOB
local K_MPROBE = keys.K_MPROBE
local K_MPROBE_OK = keys.K_MPROBE_OK
local K_WORKER = keys.K_WORKER
local shdict = keys.shdict
local with_lock = keys.with_lock

-- The self-calls that read _M.x() in the original file resolve against the
-- registry facade, late-bound below so this module loads before the facade does.
local R

--- Turn one upstream data[] array into the normalized id list.
---
--- Split out of _M.probe_advertised_models so the capability capture below can derive
--- both readings from **one** GET: the coverage list and the data[] entries then cannot
--- disagree about what the engine advertises (a list of three models with capabilities
--- for one would otherwise be a legitimate-looking state with nobody to blame).
--- Behaviour is byte-for-byte what the probe always did: data[].id, tolerate a
--- bare-string data[], nil when there is no usable entry.
---@param data any @ the decoded data[] array
---@return table|nil @ array of ids
local function ids_from_entries(data)
    if type(data) ~= "table" then
        return nil
    end
    local ids = {}
    for j = 1, #data do
        ids[j] = type(data[j]) == "table" and data[j].id or data[j]
    end
    return norm_models(ids, nil)
end

--- Ask one worker what it advertises, as a normalized id list.
---
--- Shared by the metadata-discovery fallback and by the coverage refresh below so
--- both read /v1/models the same way (data[].id, tolerate a bare-string data[]).
---@param url string
---@param timeout_ms number
---@param headers table|nil
---@return table|nil @ array of ids, or nil when the endpoint did not answer
function M.probe_advertised_models(url, timeout_ms, headers)
    local entries = R.probe_advertised_entries(url, timeout_ms, headers)
    if not entries then
        return nil
    end
    return ids_from_entries(entries)
end

--- Ask one worker what it advertises and keep the **whole** data[] answer.
---
--- 与 _M.probe_advertised_models 的分工：那一个只给归一化后的 id 列表，形状被契约与
--- 若干调用方钉住（探针/巡检/watcher 都吃它），所以它一个字都不能改；这一个是**能力
--- 采集**的入口，把上游原文交给 _M.model_caps_from_listing。两条路径共用一次 GET 的
--- 读法（同 url、同 timeout、同 header），因此"探到了哪些模型"与"它们各自能干什么"永远
--- 来自同一份回答，不会出现"列表说有三条、能力说只有一条"的分裂。
---
--- 返回上游 data[] 的原文数组（不归一、不猜），容忍老引擎的裸字符串数组——那种情况下
--- 调用方拿到的是名字数组，能力字段自然是 nil。非 200、非 JSON、没有可用数组都返回 nil，
--- 调用方据此保持"从没采到"；本函数绝不抛。
---@param url string
---@param timeout_ms number
---@param headers table|nil
---@return table|nil @ decoded data[] entries array, or nil
function M.probe_advertised_entries(url, timeout_ms, headers)
    local hb = require "resty.luarouter.hb"
    local status, body = hb.http_get(url .. "/v1/models", timeout_ms, headers)
    if status ~= 200 then
        return nil
    end
    local listing = json_decode(body or "")
    local data = type(listing) == "table" and listing.data or nil
    if type(data) ~= "table" or #data == 0 then
        -- 与老探针同一个判据：没有可用数组就等于对方没答，两条读数的 nil 语义保持一致。
        return nil
    end
    return data
end

--- The capability entries one worker's engine itself answered, plus the coverage
--- provenance bit that decides whether that answer is trustworthy.
---
--- 单独导出这一条是为了让"引擎亲口答过"这件事只有一种判定方式：能力读数只能来自
--- `/v1/models` 的**观测**（models_verified），不能来自配置声明。否则操作员在配置里写
--- 的一个名字会被当成引擎的能力陈述往外报，而那正是 context_window 事故的形状。
--- 调用方（router 的输出合成）应先用 _M.models_are_verified 判一次，再取条目。
---@param id_or_record string|table
---@return table|nil @ { [model_name] = caps } or nil when nothing captured
function M.record_model_caps(id_or_record)
    local record
    if type(id_or_record) == "table" then
        record = id_or_record
    elseif type(id_or_record) == "string" and id_or_record ~= "" then
        record = R.record(id_or_record)
    end
    if type(record) ~= "table" or not R.models_are_verified(record) then
        return nil
    end
    local caps = record.model_caps
    if type(caps) ~= "table" or next(caps) == nil then
        return nil
    end
    return caps
end

--- Cross-worker view of what the fleet's engines advertised about their models.
---
--- 输出面（router.lua 合成 /v1/models）按模型名查这一张表：同一个模型可能被多台实例
--- 广告（一个虚拟入口后面挂多个上游、或两台机器跑同一个模型），它们的读数互补时合并，
--- 冲突时取信息最全的那份——规则的完整论证在 _M.merge_model_caps 的注释里，一句话版是
--- 「取最新会让对外读数随调度抖动，所以定序只看内容，不看时序」。
---
--- 没有任何数据时返回**空表而不是 nil**：调用方是输出合成路径，那里为每个模型判一次
--- nil 与判一次 next() 等价，但少一种错误可能。表是新构造的，调用方可以随意改。
---
--- 只统计引擎亲口答过的记录（record_model_caps 的判定），配置声明的名字不贡献读数。
--- @return table<string, table> @ { [model_name] = normalized caps }
function M.model_caps()
    local out = {}
    local ok_records, records = pcall(R.records)
    if not ok_records or type(records) ~= "table" then
        return out
    end
    local grouped, order = {}, {}
    for i = 1, #records do
        local caps = R.record_model_caps(records[i])
        if caps then
            for name, entry in pairs(caps) do
                if type(name) == "string" and name ~= ""
                    and type(entry) == "table" and next(entry) ~= nil then
                    local bucket = grouped[name]
                    if not bucket then
                        bucket = {}
                        grouped[name] = bucket
                        order[#order + 1] = name
                    end
                    bucket[#bucket + 1] = entry
                end
            end
        end
    end
    for i = 1, #order do
        local name = order[i]
        local merged = R.merge_model_caps(grouped[name])
        if merged then
            out[name] = merged
        end
    end
    return out
end

--- How many coverage probes one worker may spend before we believe its list is final.
--- Same order as the metadata-discovery ceiling: a genuinely single-model engine
--- answers with one id every time, so without a ceiling this would be one wasted
--- GET per sweep per worker for the life of the deployment.
local MAX_MPROBE = 20
M.MAX_MPROBE = MAX_MPROBE

--- Re-ask window for the coverage probe, in seconds. Exported so a test can shorten it.
local MODELS_REFRESH_COOLDOWN_SECS = 300
M.MODELS_REFRESH_COOLDOWN_SECS = MODELS_REFRESH_COOLDOWN_SECS

--- Learn the advertised model list for one worker, on the health sweep clock.
---
--- Called from discover(), i.e. only for a worker the sweep already reached, so it
--- never blocks a request. An answer from the engine itself *replaces* the stored
--- list (models_replace): it is the only source that states coverage, so a model the
--- engine dropped must be able to leave our claim. Two budgets keep the steady state
--- cheap while keeping that claim honest:
---   * thin list (absent, or the single name a registration left behind) -- ask on
---     every sweep up to MAX_MPROBE times, because filling this in is what makes a
---     per-candidate binding verifiable at all;
---   * complete list -- re-ask once per MODELS_REFRESH_COOLDOWN_SECS window, which is
---     what stops an engine reloaded behind the same endpoint from being advertised
---     forever by a row nobody refreshed.
---@param record table
---@param cfg table
---@param opts table|nil @{force=true: skip both budgets (admin refresh, tests)}
---@return table|nil updated
function M.refresh_models(record, cfg, opts)
    local d = shdict()
    if not (opts and opts.force) then
        local fresh = d:get(K_MPROBE_OK .. record.id) ~= nil
        if needs_models_refresh(record) then
            -- Thin list: bounded by the attempt ceiling so a silent engine goes
            -- quiet instead of being dialed on every sweep forever.
            if fresh then
                return nil
            end
            local attempts = d:incr(K_MPROBE .. record.id, 1, 0) or 1
            if attempts > MAX_MPROBE then
                return nil
            end
        elseif fresh then
            -- Complete list inside the window: nothing to learn right now.
            return nil
        end
    end
    local timeout_ms = cfg.health_check_timeout_secs * 1000
    local headers = record.api_key and { ["Authorization"] = "Bearer " .. record.api_key }
        or nil
    -- One GET, two readings: the coverage list and the capability map come from the
    -- same upstream answer, so they can never describe two different answers.
    local entries = R.probe_advertised_entries(record.url, timeout_ms, headers)
    local list = ids_from_entries(entries)
    if not list then
        -- No answer, or an engine without the endpoint: leave the coverage as it is.
        -- worker_serves_model answers nil for "never learned", which the caller treats
        -- as usable, so a failed probe costs nothing beyond the budgets above.
        -- Same for capabilities: nothing captured, nothing rewritten, health untouched.
        return nil
    end
    local caps = R.model_caps_from_listing(entries)
    -- One stamp serves both budgets: a worker that answered gets its next look when
    -- the window lapses, and a thin list that finally answered stops spending attempts.
    d:set(K_MPROBE_OK .. record.id, 1, MODELS_REFRESH_COOLDOWN_SECS)
    return patch_record(record.id, { models = list, model_caps = caps },
        { models_replace = true })
end

-- ------------------------------------------------------------------ PUT update

-- Fields PUT /workers/{id} may change. Mirrors the Rust update_worker_properties
-- step, which only touches the scheduling knobs (priority/cost/labels) and the
-- per-worker health-check tuning; url/model_id/connection identity is immutable
-- and any other body member is ignored rather than rejected.
local UPDATE_NUMBER_FIELDS = {
    "priority", "cost",
    -- Capacity ceilings ride the same PUT path as the scheduling knobs (root ruling
    -- 2026-10-01, reshaped by 2026-10-06's three-way verdict), including the
    -- config-declaration reconcile's patch. Their *meaning* is decided by the
    -- normalizer at read time - cap_limit for the two request-count rungs (<=0 folds
    -- to "unlimited", so a PUT of 0 is the ordinary way to clear one) and util_limit
    -- for the percent (its zero is the strictest rung, so a ceiling is cleared with a
    -- negative number or by the declaration dropping the key, never with 0). That is
    -- why no bespoke validator lives here; the contract's non-numeric-400 rule applies
    -- unchanged. max_power_w left the list with the watt gate: a PUT naming it is now
    -- ignored like any unknown field, and `pw:` itself stays collected as an
    -- observation.
    "max_concurrency", "min_concurrency", "max_gpu_util",
    "health_check_timeout_secs", "health_check_interval_secs",
    "health_success_threshold", "health_failure_threshold",
}
local UPDATE_BOOL_FIELDS = { "disable_health_check" }

---Apply a partial update to one stored worker record.
---@param worker_id string
---@param patch table @ decoded PUT body
---@return table|nil result @ {worker_id, url}
---@return string|nil err
---@return string|nil kind @ "validation" for client-side rejections (400)
function M.update(worker_id, patch)
    if type(patch) ~= "table" then
        return nil, "worker update must be a JSON object", "validation"
    end
    local id, perr = R.parse_worker_id(worker_id)
    if not id then
        return nil, perr, "validation"
    end
    local d = shdict()
    if not d:get(K_WORKER .. id) then
        return nil, "Worker " .. id .. " not found", "not_found"
    end

    local changes = {}
    for i = 1, #UPDATE_NUMBER_FIELDS do
        local field = UPDATE_NUMBER_FIELDS[i]
        local value = patch[field]
        if value ~= nil and value ~= cjson.null then
            local number = tonumber(value)
            if not number then
                return nil, string.format("field '%s' must be a number", field),
                    "validation"
            end
            changes[field] = number
        end
    end
    for i = 1, #UPDATE_BOOL_FIELDS do
        local field = UPDATE_BOOL_FIELDS[i]
        local value = patch[field]
        if value ~= nil and value ~= cjson.null then
            if type(value) ~= "boolean" then
                return nil, string.format("field '%s' must be a boolean", field),
                    "validation"
            end
            changes[field] = value
        end
    end
    if patch.labels ~= nil and patch.labels ~= cjson.null then
        if type(patch.labels) ~= "table" then
            return nil, "field 'labels' must be a JSON object", "validation"
        end
        -- patch_record merges labels (discovery writes the same map), so a PUT
        -- that only names one label keeps the rest.
        changes.labels = patch.labels
    end
    if patch.api_key ~= nil and patch.api_key ~= cjson.null then
        -- Non-string api_key stays ignored (Rust-style: unknown shapes of a
        -- known field are dropped, not rejected; the contract only pins the
        -- null / "" / non-empty tri-state). Empty string clears the key
        -- (doc/gap-virtual-models.md 3.4), stored as false so every
        -- `worker.api_key and ...` reader skips the Authorization header and
        -- patch_record's pairs() can still see the write.
        if type(patch.api_key) == "string" then
            changes.api_key = (patch.api_key ~= "") and patch.api_key or false
        end
    end

    -- Config-declared upstreams are owned by config_store: the reconcile in
    -- gap-virtual-models 3.1 re-applies model_id and *replaces* the label map
    -- from the document. Rust's identity-immutability parity rule stays intact
    -- for every other record (a PUT naming model_id on a dynamic worker keeps
    -- being ignored, the contract pins that).
    local labels_replace
    local current = json_decode(d:get(K_WORKER .. id))
    if type(current) == "table" and current.discovery == "config" then
        if type(patch.model_id) == "string" and patch.model_id ~= "" then
            changes.model_id = patch.model_id
        end
        -- The advertised list is part of what a config row declares (a row may name
        -- several models for one endpoint), so the config layer is allowed to write
        -- it. A dynamic worker keeps the probe's answer as its own -- a PUT naming
        -- models on a watcher-owned row is dropped by the same identity rule that
        -- already ignores model_id there, which keeps a hand-typed override from
        -- outliving the next sweep that knows better.
        -- patch_record folds rather than replaces (see merge_models), so declaring
        -- one model here cannot delete what the probe already learned.
        if patch.models ~= nil and patch.models ~= cjson.null then
            if type(patch.models) ~= "table" then
                return nil, "field 'models' must be a JSON array", "validation"
            end
            changes.models = norm_models(patch.models, patch.model_id)
        elseif changes.model_id then
            changes.models = norm_models(nil, changes.model_id)
        end
        labels_replace = true
    end

    local url = d:get(K_IDURL .. id)
    local ok, lerr = with_lock(function()
        if not patch_record(id, changes, { labels_replace = labels_replace }) then
            error("worker " .. id .. " disappeared while updating")
        end
    end)
    if not ok then
        return nil, lerr
    end
    return { worker_id = id, url = url }
end

---Query the worker for the model it serves, the way the Rust worker workflow's
---discover_metadata step does: /model_info and /server_info give the identity
---labels, /v1/models is the fallback, and model_id falls back through
---served_model_name then model_path.
---
---Returns nil once the worker has a real model id, so the caller can stop asking.
---@param record table
---@param cfg table
---@return table|nil updated @ record after the update
function M.discover(record, cfg)
    local d = shdict()

    -- DP expansion comes first, because it can replace the record this function
    -- was handed: a data-parallel engine has to become dp_size entries before
    -- per-rank metadata makes any sense. Ranks carry dp_base_url and are never
    -- expanded again; a base that already decided (dp_size set, including the
    -- settled dp_size == 1) is skipped, so this costs one probe per worker.
    --
    -- Only "expanded" short-circuits: when the engine says dp_size <= 1, or when
    -- /server_info has not answered yet, the ordinary metadata path below still
    -- runs against the base worker, which is reachable and useful on its own.
    if cfg and cfg.dp_aware and not record.dp_base_url and not record.dp_size
        and not R.rank_of(record.url) then
        if R.expand_dp(record, cfg) == "expanded" then
            return nil
        end
    end

    if record.model_id and record.model_id ~= "unknown" then
        -- A worker that already has a primary model is normally finished with this
        -- path, but its advertised *coverage* may still be a single name: the watcher
        -- registers rows from its own probe and reports only one model, and a record
        -- created from a one-model config row is in the same shape. Without the full
        -- list here, a virtual-model binding naming that row's second model would be
        -- answered `false` ("it advertised a list, and M is not in it") and the request
        -- would be filtered away from an engine that can serve it -- the exact failure
        -- mode the multi-binding feature is supposed to remove. Bounded by the same
        -- attempt ceiling as the unknown-model path so a silent engine costs 20 probes
        -- per worker and then stops; one /v1/models call per sweep for a talking one.
        -- One decision point: refresh_models itself decides whether this worker is
        -- worth asking (thin list on the attempt ceiling, complete list on the
        -- cooldown window), so discover does not pre-empt it with a second rule.
        return R.refresh_models(record, cfg)
    end
    local attempts = d:incr(K_DISC .. record.id, 1, 0) or 1
    if attempts > 20 then
        return nil
    end

    local hb = require "resty.luarouter.hb"
    local timeout_ms = cfg.health_check_timeout_secs * 1000
    local labels = {}
    -- Declared before the probes so the /v1/models branch (nested two conditionals
    -- deep) can hand its full answer to the write at the bottom without shadowing.
    local discovered_models
    local discovered_entries
    local present = function(value)
        if type(value) == "string" and value ~= "" then
            return value
        end
        if type(value) == "number" then
            return tostring(value)
        end
        return nil
    end

    local info_status, info_body = hb.http_get(record.url .. "/model_info", timeout_ms)
    if info_status == 200 then
        local model_info = json_decode(info_body)
        if type(model_info) == "table" then
            labels.model_path = present(model_info.model_path)
            labels.served_model_name = present(model_info.served_model_name)
        end
    end

    local server_status, server_body = hb.http_get(record.url .. "/server_info", timeout_ms)
    if server_status == 200 then
        local server_info = json_decode(server_body)
        if type(server_info) == "table" then
            labels.model_path = labels.model_path or present(server_info.model_path)
            labels.served_model_name = labels.served_model_name
                or present(server_info.served_model_name)
            labels.tp_size = present(server_info.tp_size)
            labels.dp_size = present(server_info.dp_size)
        end
    end

    if not labels.model_path and not labels.served_model_name then
        -- llama.cpp workers expose neither: ask the OpenAI discovery endpoint.
        -- 同 refresh_models 的"一次 GET、两份读数"：这条路径是 llama.cpp 那类引擎唯一会
        -- 看到 /v1/models 的地方，能力条目不在这儿交下去，它们就永远没有描述。
        discovered_entries = R.probe_advertised_entries(record.url, timeout_ms)
        discovered_models = ids_from_entries(discovered_entries)
        if discovered_models then
            labels.served_model_name = present(discovered_models[1])
        end
    end

    local model_id = labels.served_model_name or labels.model_path
    if not model_id then
        -- Nothing discovered yet; leave it unknown so the next sweep retries.
        return nil
    end

    local merged = {}
    for key, value in pairs(labels) do
        if value then
            merged[key] = value
        end
    end
    -- models rides the same patch: patch_record folds it (merge_models) rather than
    -- overwriting, so a sweep that only ever sees one name cannot shrink a list the
    -- watcher already reported.
    -- The list rides the same patch as an observation: the worker itself named these
    -- models, so it replaces whatever was stored (a stale entry from an engine that
    -- has since been reloaded with a different model set goes away on the next sweep
    -- rather than lingering as a coverage claim).
    return patch_record(record.id, { model_id = model_id, labels = merged,
        models = discovered_models,
        model_caps = R.model_caps_from_listing(discovered_entries) },
        { models_replace = true })
end

-- ---------------------------------------------------------- DP-aware ranks

-- The three pure decisions below lived in the Kubernetes poller module and
-- moved here when it was removed (doc/scope-trim.md). The DP expansion is the
-- scheduler's own feature: a data-parallel engine is stored as one registry
-- entry per rank regardless of how the worker was discovered.

-- A worker that never answers /server_info stays a single-entry worker after
-- this many probes. The metadata-discovery attempt ceiling in discover() is the
-- same order (20), so the two bounded retries end together.
local MAX_DP_ATTEMPTS = 20
M.MAX_DP_ATTEMPTS = MAX_DP_ATTEMPTS

---Read dp_size out of a decoded /server_info body.
---
---Both spellings seen in the wild are accepted: the sglang engine reports
---dp_size at the top level, and some builds nest it under "server_args".
---@param info table|nil
---@return number|nil dp_size
local function dp_size_from_server_info(info)
    if type(info) ~= "table" then
        return nil
    end
    local raw = info.dp_size
    if raw == nil and type(info.server_args) == "table" then
        raw = info.server_args.dp_size
    end
    local n = tonumber(raw)
    if not n or n ~= math.floor(n) or n < 1 then
        return nil
    end
    return n
end

---Decide what one DP probe implies for the registry.
---
---This function only classifies so the decision is unit-testable without a
---shared dict; the caller (expand_dp) owns the writes.
---@param dp_size number|nil @ parsed from /server_info, nil when unavailable
---@param attempts number @ probes already spent on this record
---@return string action @ "expand" | "single" | "retry" | "give_up"
---@return number|nil dp_size @ effective fan-out width for "expand"
local function expansion_plan(dp_size, attempts)
    if not dp_size then
        -- No answer. Retry a bounded number of times (the engine may still be
        -- loading), then settle on the base worker as a single entry.
        if (attempts or 0) >= MAX_DP_ATTEMPTS then
            return "give_up", 1
        end
        return "retry", nil
    end
    if dp_size <= 1 then
        return "single", 1
    end
    return "expand", dp_size
end

---Build the registration requests for ranks 0..dp_size-1 of one base worker.
---
---Everything the scheduler needs to treat a rank like the engine it stands for
---is copied from the base record (model id, priority, cost, api key, health
---tuning, labels); the rank identity goes in dp_rank/dp_size/dp_base_url plus a
---dp_aware marker so a later teardown can find them again.
---@param base table @ stored record for the base url
---@param dp_size number
---@param meta table|nil @ {model_id, labels} learned from the probe body
---@return table[] @ one POST /workers-shaped request per rank
local function expansion_requests(base, dp_size, meta)
    meta = meta or {}
    local out = {}
    for rank = 0, (dp_size or 1) - 1 do
        local labels = {}
        for k, v in pairs(base.labels or {}) do
            labels[k] = v
        end
        for k, v in pairs(meta.labels or {}) do
            labels[k] = v
        end
        labels.dp_rank = tostring(rank)
        labels.dp_size = tostring(dp_size)
        out[#out + 1] = {
            url = base.url .. "@" .. rank,
            -- The probe that revealed the ranks usually carries the model too, so
            -- a rank is routable on the sweep that created it rather than having to
            -- re-discover /model_info four times over.
            model_id = meta.model_id or base.model_id,
            -- Ranks inherit the base engine's advertised coverage: every rank of a
            -- data-parallel engine serves the same model set, and a rank that lost the
            -- list would read as "we never learned what it serves" to the multi-binding
            -- filter (nil) or, worse, be filtered out by a binding naming its second
            -- model. meta.model_id leads so a probe that just corrected the name also
            -- resets the coverage rather than folding a stale second model in.
            -- The base list is inherited wholesale (norm_models puts the head first, so
            -- the name the /server_info probe just reported leads it), which is what a
            -- rank of a data-parallel engine means: every rank serves the same model
            -- set. A rank that lost the list would read as never-learned to the
            -- multi-binding filter, and a binding naming its second model would filter
            -- the rank out of a pool that can actually serve it.
            models = norm_models({ meta.model_id or base.model_id }, base.models),
            -- 能力读数刻意**不**跟着继承：rank 是新建记录、models_verified 尚未盖章，
            -- 而能力只认证引擎亲口答过（见 _M.record_model_caps）。盖章前继承一份读数是
            -- 纯死重——巡检第一轮就会自己探到，届时 replace 会整表重建它。
            priority = base.priority,
            cost = base.cost,
            api_key = base.api_key,
            labels = labels,
            disable_health_check = base.disable_health_check or false,
            health_check_timeout_secs = base.health_check_timeout_secs,
            health_check_interval_secs = base.health_check_interval_secs,
            health_success_threshold = base.health_success_threshold,
            health_failure_threshold = base.health_failure_threshold,
            dp_rank = rank,
            dp_size = dp_size,
            dp_base_url = base.url,
            dp_aware = true,
            -- Inherit the source name so a rank stays attributed to whatever
            -- registered its base (there is no pod reconcile any more; the
            -- field is provenance only).
            discovery = base.discovery,
        }
    end
    return out
end

---Expand one base worker into its data-parallel ranks.
---
---Called from _M.discover() (i.e. from the health sweep of a reachable worker),
---so it never blocks a request. The probe is /server_info with /get_server_info
---as the older spelling; both are the endpoints the Rust gateway reads dp_size
---from. A rank is registered as "<base>@<rank>": a distinct id, distinct health
---counters, distinct load and circuit breaker, and a policy tenant of its own -
---which is the whole point, since the engine schedules each rank independently.
---
---Ranks start unhealthy like any fresh worker and are brought up by the next
---sweep; that sweep is also what learns their metadata. The base entry is then
---removed, so /workers shows exactly the dp_size ranks the Rust gateway would.
---@param record table @ base worker record (no dp_base_url)
---@param cfg table
---@return string action @ "expanded" | "settled" | "retry"
function M.expand_dp(record, cfg)
    local d = shdict()
    local attempts = d:incr(K_DPROBE .. record.id, 1, 0) or 1

    local hb = require "resty.luarouter.hb"
    local timeout_ms = cfg.health_check_timeout_secs * 1000
    local headers = record.api_key and { ["Authorization"] = "Bearer " .. record.api_key }
        or nil
    local dp_size, info
    for _, endpoint in ipairs({ "/server_info", "/get_server_info" }) do
        local status, body = hb.http_get(record.url .. endpoint, timeout_ms, headers)
        if status == 200 then
            local decoded = json_decode(body)
            dp_size = dp_size_from_server_info(decoded)
            if dp_size then
                info = decoded
                break
            end
        end
    end

    -- The probe that reveals the ranks usually reveals the model as well, so hand
    -- both to the rank records: otherwise every rank has to re-run metadata
    -- discovery, and until it does the engine is unroutable even though the base
    -- worker already knew its model id.
    local meta
    if type(info) == "table" then
        local present = function(value)
            if type(value) == "string" and value ~= "" then
                return value
            end
            if type(value) == "number" then
                return tostring(value)
            end
            return nil
        end
        local labels = {}
        labels.model_path = present(info.model_path)
        labels.served_model_name = present(info.served_model_name)
        labels.tp_size = present(info.tp_size)
        labels.dp_size = present(info.dp_size)
        local model_id = labels.served_model_name or labels.model_path
        if model_id or record.model_id ~= "unknown" then
            meta = { model_id = model_id or record.model_id, labels = labels }
        end
    end

    local action, width = expansion_plan(dp_size, attempts)
    if action == "retry" then
        -- Keep asking (bounded): a loading engine answers /health before it
        -- answers /server_info, and expanding at the wrong width is worse than
        -- waiting. Until then the base worker carries traffic as a single entry.
        return "retry"
    end
    if action == "give_up" then
        ngx.log(ngx.WARN, "luarouter: no usable dp_size from ", record.url,
            " after ", attempts, " probes; keeping it as a single worker")
    end

    if (width or 1) <= 1 then
        -- Settled: record the decision so neither this worker nor the sweep
        -- retries /server_info for DP again.
        patch_record(record.id, { dp_size = 1 })
        return "settled"
    end

    local requests = expansion_requests(record, width, meta)
    local added = 0
    for i = 1, #requests do
        local _, err = R.add(requests[i], cfg)
        if err then
            -- A rank that already exists means a previous attempt got part-way:
            -- treat it as present and let the sweep finish the job next time.
            ngx.log(ngx.WARN, "luarouter: dp rank ", requests[i].url,
                " not registered: ", err)
        else
            added = added + 1
        end
    end
    if added == 0 then
        return "retry"
    end

    -- The base entry would be a phantom candidate taking selections to a listener
    -- that is one of the ranks, so it goes away once the ranks exist.
    local _, remove_err = R.remove(record.id)
    if remove_err then
        ngx.log(ngx.ERR, "luarouter: expanded ", record.url, " into ", added,
            " ranks but could not remove the base entry: ", remove_err)
    end

    -- Same signal a control-plane write gives: the worker set changed, so a
    -- stateful policy has to re-seed rather than keep a tree of the old list.
    local ok, policy = pcall(require, "resty.luarouter.policy")
    if ok and policy and policy.bump_generation then
        policy.bump_generation()
    end

    ngx.log(ngx.NOTICE, "luarouter: expanded ", record.url, " into ", added,
        " data-parallel ranks (SMG_DP_AWARE)")
    return "expanded"
end

-- ------------------------------------------------------------------ job queue

---@param url string
---@param job_type string
---@param status string @ pending | processing | completed | failed
---@param message string|nil
function M.set_job(url, job_type, status, message)
    local job = {
        job_type = job_type,
        worker_url = url,
        status = status,
        message = message or cjson.null,
        timestamp = ngx.time(),
    }
    local encoded = json_encode(job)
    if encoded then
        shdict():set(K_JOB .. url, encoded, 600)
    end
end

---@param url string
---@return table|nil
function M.get_job(url)
    local raw = shdict():get(K_JOB .. url)
    if not raw then
        return nil
    end
    local job = json_decode(raw)
    if type(job) ~= "table" then
        return nil
    end
    return job
end

---@param url string
function M.clear_job(url)
    shdict():delete(K_JOB .. url)
end

-- ------------------------------------------------------------------ bootstrap

---Register the SMG_WORKER_URLS seed list (idempotent).
---@param cfg table
---@return number @ registered count
function M.bootstrap(cfg)
    local count = 0
    local urls = cfg.worker_urls or {}
    for i = 1, #urls do
        local _, err = R.add({ url = urls[i] }, cfg)
        if err then
            ngx.log(ngx.ERR, "luarouter: seed worker ", urls[i], " failed: ", err)
        else
            count = count + 1
        end
    end
    return count
end

-- Late-bind the facade: registry.lua pre-registers package.loaded before it
-- requires this module, and a test that swaps the whole module table for a stub
-- through package.loaded is honoured by the same lookup.
R = package.loaded["resty.luarouter.registry"] or require "resty.luarouter.registry"

return M
