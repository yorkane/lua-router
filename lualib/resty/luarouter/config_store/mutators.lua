-- resty.luarouter.config_store.mutators
-- P27-P28 apply_* 家族 + P29 的 apply_upstreams + P30 整表写（policy / document）。
--
-- 由 lualib/resty/luarouter/config_store.lua 拆分而来：函数体逐行原样搬家，只调整 require 与
-- 跨模块接线（doc/refactor-arch-2026-10-05.md §1–§2）。原文里经 _M.x() 的自调 → 经 CS_FACADE
-- 表调用（保住单测换桩的可拦截性逐点一致）；原文里的同文件 local 直调 → 直接 require 对端
-- 子模块的共享表调用（不进 facade 导出面，_M 契约因此逐名不变）。
local CS_FACADE = require "resty.luarouter.config_store"
local cjson = require "cjson.safe"
local JSON_NULL = cjson.null
local CS_LEXICON = require "resty.luarouter.config_store.lexicon"
local CS_PROFILES = require "resty.luarouter.config_store.profiles"
local CS_PERSISTENCE = require "resty.luarouter.config_store.persistence"
local CS_UPSTREAMS = require "resty.luarouter.config_store.upstreams"
local CS_SNAPSHOT = require "resty.luarouter.config_store.snapshot"

local _M = {}

--- Persist-then-echo for every mutator below: the durable layers have to answer
--- before a caller can honestly show a document. On a refused compare-and-set the
--- mutator returns (nil, error) like any other validation failure, so no handler ever
--- responds 200 with a document that exists only in this worker's shdict.
local function commit_snapshot(cfg)
    local saved, err, cur = CS_PERSISTENCE.write_snapshot(CS_SNAPSHOT.snapshot_of(cfg))
    if not saved then return nil, CS_PERSISTENCE.store_conflict_message(err, cur) end
    return CS_SNAPSHOT.snapshot_of(CS_FACADE.current()), nil
end

--- Apply an effort edit; returns (snapshot, nil) or (nil, error).
function _M.apply_effort(patch)
    if type(patch) ~= "table" then return nil, "body must be a JSON object" end
    local cfg = CS_FACADE.current()

    local has_default = rawget(patch, "default_effort") ~= nil
    if has_default then
        local raw = patch.default_effort
        if raw == JSON_NULL then
            cfg.default_effort = nil
        elseif type(raw) == "string" then
            local trimmed = CS_LEXICON.trim(raw)
            if trimmed == "" or CS_LEXICON.lower(trimmed) == "null" then
                cfg.default_effort = nil
            else
                local effort = CS_FACADE.normalize_effort(trimmed)
                if effort == false then
                    return nil, string.format("unknown effort: %s (want one of %s)",
                        trimmed, CS_LEXICON.EFFORT_LEVELS_JOIN)
                end
                cfg.default_effort = effort
            end
        else
            return nil, "default_effort must be a string or null"
        end
    end

    if patch.effort_map ~= nil then
        if not CS_LEXICON.is_array(patch.effort_map) then return nil, "effort_map must be an array" end
        local next_map = {}
        for _, entry in ipairs(patch.effort_map) do
            local from = CS_FACADE.normalize_effort(entry.from)
            local to = CS_LEXICON.trim(entry.to)
            if from == false or from == nil then
                return nil, string.format("unknown effort in map: %s", tostring(entry.from or ""))
            end
            if to ~= "" then
                local to_norm = CS_FACADE.normalize_effort(to)
                if to_norm == false then
                    return nil, string.format("unknown effort in map target: %s (want one of %s)",
                        to, CS_LEXICON.EFFORT_LEVELS_JOIN)
                end
                next_map[from] = to_norm
            end
        end
        cfg.effort_map = next_map
    end

    if patch.model_effort ~= nil then
        if not CS_LEXICON.is_array(patch.model_effort) then
            return nil, "model_effort must be an array of {model, effort}"
        end
        local next_map = {}
        for _, entry in ipairs(patch.model_effort) do
            local model = CS_LEXICON.trim(entry.model)
            local raw = entry.effort
            local trimmed = type(raw) == "string" and CS_LEXICON.trim(raw) or ""
            if model ~= "" and trimmed ~= "" and CS_LEXICON.lower(trimmed) ~= "null" then
                local effort = CS_FACADE.normalize_effort(trimmed)
                if effort == false then
                    return nil, string.format("unknown effort for %s: %s (want one of %s)",
                        model, trimmed, CS_LEXICON.EFFORT_LEVELS_JOIN)
                end
                next_map[model] = effort
            end
        end
        cfg.model_effort = next_map
    end

    return commit_snapshot(cfg)
end

--- Apply one context cap; ctx nil/JSON_NULL removes it.
function _M.apply_ctx(model, ctx)
    model = CS_LEXICON.trim(model or "")
    if model == "" then return nil, "model is required" end
    local cfg = CS_FACADE.current()
    if ctx == nil or ctx == JSON_NULL then
        cfg.model_ctx[model] = nil
    else
        local cap = CS_LEXICON.parse_positive_int(ctx)
        if not cap then return nil, "ctx must be greater than zero" end
        cfg.model_ctx[model] = cap
    end
    return commit_snapshot(cfg)
end

--- One model-card patch. remove:true drops the card plus legacy rows.
function _M.apply_model_config(patch)
    if type(patch) ~= "table" then return nil, "body must be a JSON object" end
    local model = CS_LEXICON.trim(patch.model or "")
    if model == "" then return nil, "model is required" end
    local cfg = CS_FACADE.current()
    if patch.remove == true then
        cfg.model_configs[model] = nil
        cfg.model_ctx[model] = nil
        cfg.model_effort[model] = nil
        return commit_snapshot(cfg)
    end
    local card = cfg.model_configs[model] or CS_SNAPSHOT.new_card()
    local ok, err = CS_SNAPSHOT.merge_model_patch(card, patch)
    if not ok then return nil, err end
    if rawget(patch, "default_effort") ~= nil then cfg.model_effort[model] = nil end
    if rawget(patch, "ctx") ~= nil then cfg.model_ctx[model] = nil end
    -- 卡片与平铺行是同一个读数的两种拼法，所以照抄上面 ctx 的口径：写了卡片的
    -- max_output_tokens 就清掉平铺那一行。留着它是个隐形地雷——日后把卡片的读数清成
    -- null 时，对外读数会悄悄改用一条谁都不再看作生效的旧数字（卡片说 8192、平铺说
    -- 4096 的配置根本没法向操作员解释）。
    if rawget(patch, "max_output_tokens") ~= nil then cfg.model_max_output_tokens[model] = nil end
    cfg.model_configs[model] = card
    return commit_snapshot(cfg)
end

--- Whole-list replace for the virtual model table (profiles shape). Kept as the
--- public entry point for the existing callers; it validates through the same
--- profile builder as apply_profiles.
function _M.apply_virtual_models(entries)
    return CS_FACADE.apply_profiles(entries)
end

--- Whole-list replace for the profiles table: entries are the document shape
--- [{model, target?, candidates?, workers?, policy?, effort?}] (legacy
--- {model, target} pairs still validate; target-less entries bind per candidate).
--- Returns (snapshot, nil) or (nil, error).
function _M.apply_profiles(entries)
    if not CS_LEXICON.is_array(entries) then return nil, "virtual_models must be an array" end
    -- The live graph participates in the chain check, so an entry cannot point at an
    -- alias this batch does not declare (root ruling 4).
    local built, berr = CS_PROFILES.build_profiles(entries, CS_FACADE.current().virtual_profiles)
    if not built then return nil, berr end
    local cfg = CS_FACADE.current()
    cfg.virtual_profiles = built
    CS_SNAPSHOT.sync_virtual_view(cfg)
    return commit_snapshot(cfg)
end

-- ------------------------------------------------------- profile readers
--
-- Hot-path shape of the profile accessors: they read the already-memoised
-- current() snapshot (SNAPSHOT_TTL window, no extra shdict round trip) and are
-- pure functions of it, so router.lua may call them per request.

--- Profile for one alias, or nil when the name is not an alias. Returns a fresh
--- table each call so a caller cannot mutate the live snapshot.
function _M.profile_for(model)
    if type(model) ~= "string" or model == "" then return nil end
    local cfg = CS_FACADE.current()
    local profile = cfg.virtual_profiles[model]
    if type(profile) ~= "table" then
        local target = cfg.virtual_models[model]
        if type(target) ~= "string" then return nil end
        return { target = target }
    end
    local out = { target = profile.target }
    -- The entry carries its own client-facing name so the router can key policy state
    -- by it (one entry, one affinity tree) without every call site threading the alias
    -- through a second argument. The store is the only place that knows both.
    out.model = model
    -- explicit_targets rides along deliberately: the *derived* group exists for every
    -- row (a legacy pair has the group of one it always was), and reading it as "this
    -- entry is a group entry" would put the model gate and the single-tree policy key
    -- onto configs that never asked for them. Only a row whose group the operator wrote
    -- gets the new selection semantics; everything else keeps the old path verbatim.
    out.explicit_targets = profile.explicit_targets or nil
    -- The group rides the same fresh-copy rule as workers/candidates: the router reads
    -- it per request and must not be able to write into the live snapshot through it.
    if profile.targets then out.targets = { table.unpack(profile.targets) } end
    out.context_window = profile.context_window
    if profile.workers then out.workers = { table.unpack(profile.workers) } end
    -- Bindings ride the same "fresh copy" rule as workers: the router reads them per
    -- request and must not be able to corrupt the live snapshot through the returned
    -- table. explicit_target is internal bookkeeping and stays inside the store.
    if profile.candidates then out.candidates = CS_PROFILES.copy_bindings(profile.candidates) end
    out.policy = profile.policy
    out.effort = profile.effort
    -- Entry-level declarations ride the hot-path profile copy so the router can hand
    -- them to request_effort_for / entry_declaration without a second store read.
    -- effort_map is copied (not shared) for the same reason as candidates above: a
    -- caller must not be able to write through into the live snapshot.
    out.default_effort = profile.default_effort
    if profile.effort_map then
        local declared_map = {}
        for from, to in pairs(profile.effort_map) do declared_map[from] = to end
        out.effort_map = declared_map
    end
    if profile.modalities then out.modalities = { table.unpack(profile.modalities) } end
    out.supports_tool_use = profile.supports_tool_use
    -- 四条能力位与 tool use 同一条热路径拷贝：/v1/models 的合成侧（router
    -- .resolve_model_caps）每请求读它，"false 与 nil 分家"必须一路到这里都不塌缩。
    out.supports_streaming = profile.supports_streaming
    out.supports_reasoning = profile.supports_reasoning
    out.supports_vision = profile.supports_vision
    out.supports_reasoning_effort = profile.supports_reasoning_effort
    return out
end

--- Profiles as an array ordered by alias, the round-trip form the UI and the
--- apply endpoint accept.
function _M.profiles_list()
    local cfg = CS_FACADE.current()
    local out = {}
    for _, alias in ipairs(CS_LEXICON.sorted_keys(cfg.virtual_profiles)) do
        local profile = cfg.virtual_profiles[alias]
        -- Same rule as snapshot_of: only an operator-declared target is re-emitted, so
        -- the list handed to the UI / apply endpoint round-trips a candidates-only row
        -- without inventing a model name nobody configured.
        local entry = { model = alias }
        if profile.explicit_targets and profile.targets then
            entry.targets = { table.unpack(profile.targets) }
        end
        if profile.candidates then
            if profile.explicit_target then entry.target = profile.target end
            entry.candidates = CS_PROFILES.copy_bindings(profile.candidates)
        elseif not profile.explicit_targets then
            entry.target = profile.target
        end
        if profile.workers then entry.workers = { table.unpack(profile.workers) } end
        entry.policy = profile.policy
        entry.effort = profile.effort
        -- The four entry-level declarations ride the UI round-trip list as well, with
        -- the same tri-state rule as snapshot_of: supports_tool_use=false is an answer
        -- and must survive an apply -> profiles_list -> apply cycle untouched.
        if profile.default_effort then entry.default_effort = profile.default_effort end
        if profile.effort_map then
            entry.effort_map = CS_SNAPSHOT.effort_pairs(profile.effort_map)
        end
        if profile.modalities then entry.modalities = { table.unpack(profile.modalities) } end
        for _, field in ipairs({ "supports_tool_use", "supports_streaming",
                                 "supports_reasoning", "supports_vision",
                                 "supports_reasoning_effort" }) do
            if profile[field] ~= nil then entry[field] = profile[field] end
        end
        if profile.context_window then entry.context_window = profile.context_window end
        out[#out + 1] = entry
    end
    return out
end

--- Per-alias policy override (contract 3.3: profile.policy beats
--- model_policies, hint, global and env). Accepts either an alias or a profile
--- table, so router.lua can pass what it already resolved.
function _M.profile_policy(alias_or_profile)
    local name
    if type(alias_or_profile) == "table" then
        name = alias_or_profile.policy
    elseif type(alias_or_profile) == "string" and alias_or_profile ~= "" then
        local profile = CS_FACADE.current().virtual_profiles[alias_or_profile]
        name = profile and profile.policy
    end
    if type(name) ~= "string" then return nil end
    local normalized = CS_FACADE.normalize_policy(name)
    return normalized or nil
end

--- Per-alias effort override with the precedence of contract 3.3: a forced
--- model_effort row wins, then the profile of the alias, then the profile keyed
--- by the resolved target. nil = "no override", the caller keeps its ladder.
function _M.profile_effort(alias, resolved)
    local cfg = CS_FACADE.current()
    for _, key in ipairs({ alias, resolved }) do
        if type(key) == "string" and key ~= "" then
            local forced = cfg.model_effort[key]
            if type(forced) == "string" and forced ~= "" then return forced end
        end
    end
    for _, key in ipairs({ alias, resolved }) do
        if type(key) == "string" and key ~= "" then
            local profile = cfg.virtual_profiles[key]
            local wanted = profile and profile.effort
            if type(wanted) == "string" and wanted ~= "" then return wanted end
        end
    end
    return nil
end

-- --------------------------------------------------------- upstreams layer
--
-- The declaration half of the pool: document rows keyed by normalized url, with
-- reconcile_upstreams() projecting them into lr_workers. Field defaults mirror
-- registry.add (priority 50, cost 1.0, model_id unknown), and the key follows
-- the tri-state of contract 3.4 (keep / clear / set).

--- Validate + persist + reconcile the declared upstream pool (whole-list
--- replace). Returns (summary, nil) or (nil, error).
function _M.apply_upstreams(entries)
    local rows, err = CS_UPSTREAMS.build_upstreams(entries, CS_UPSTREAMS.previous_upstream_map(CS_FACADE.current()))
    if not rows then return nil, err end
    local cfg = CS_FACADE.current()
    cfg.upstreams = rows
    local saved, serr, scur = CS_PERSISTENCE.write_snapshot(CS_SNAPSHOT.snapshot_of(cfg))
    if not saved then return nil, CS_PERSISTENCE.store_conflict_message(serr, scur) end
    local summary = CS_FACADE.reconcile_upstreams()
    return summary, nil
end

--- Routing-policy patch. Body accepts three independent sections, all optional
--- and applied in one atomic write (validate-then-write, like apply_effort):
---   policy          string|null  global override; null / "" / "auto" clears it
---   model_policies  [{model, policy}]  whole-table replace of the per-model rows
---   model_policy    {model, policy}    upsert or delete one per-model row
--- An unknown policy name is rejected before anything is written, so the caller
--- sees 400 and the running configuration is untouched.
function _M.apply_policy(patch)
    if type(patch) ~= "table" then return nil, "body must be a JSON object" end
    local touched = false

    local next_global
    if rawget(patch, "policy") ~= nil then
        local raw = patch.policy
        if raw == JSON_NULL then
            next_global = nil
        elseif type(raw) == "string" then
            local trimmed = CS_LEXICON.trim(raw)
            if trimmed == "" or CS_LEXICON.lower(trimmed) == "null" then
                next_global = nil
            else
                local name = CS_FACADE.normalize_policy(trimmed)
                if name == false then
                    return nil, string.format("unknown policy: %s (want one of %s)",
                        trimmed, CS_LEXICON.POLICY_NAMES_JOIN)
                end
                next_global = name
            end
        else
            return nil, "policy must be a string or null"
        end
        touched = true
    end

    local next_rows
    if rawget(patch, "model_policies") ~= nil then
        local rows = patch.model_policies
        if rows == JSON_NULL then rows = {} end
        if not CS_LEXICON.is_array(rows) then return nil, "model_policies must be an array" end
        next_rows = {}
        for _, entry in ipairs(rows) do
            if type(entry) ~= "table" then
                return nil, "model_policies entries must be objects"
            end
            local model = CS_LEXICON.trim(type(entry.model) == "string" and entry.model or "")
            if model == "" then
                return nil, "every model_policies entry needs a model"
            end
            local raw = entry.policy
            local trimmed = type(raw) == "string" and CS_LEXICON.trim(raw) or ""
            if raw ~= JSON_NULL and trimmed ~= "" and CS_LEXICON.lower(trimmed) ~= "null" then
                local name = CS_FACADE.normalize_policy(trimmed)
                if name == false then
                    return nil, string.format("unknown policy for %s: %s (want one of %s)",
                        model, trimmed, CS_LEXICON.POLICY_NAMES_JOIN)
                end
                next_rows[model] = name
            end
        end
        touched = true
    elseif rawget(patch, "model_policy") ~= nil then
        local entry = patch.model_policy
        if entry == JSON_NULL or type(entry) ~= "table" then
            return nil, "model_policy must be an object {model, policy}"
        end
        local model = CS_LEXICON.trim(type(entry.model) == "string" and entry.model or "")
        if model == "" then return nil, "model_policy needs a model" end
        local raw = entry.policy
        local trimmed = type(raw) == "string" and CS_LEXICON.trim(raw) or ""
        next_rows = {}
        for target, name in pairs(CS_FACADE.current().model_policies) do
            next_rows[target] = name
        end
        if raw == JSON_NULL or trimmed == "" or CS_LEXICON.lower(trimmed) == "null" then
            next_rows[model] = nil
        else
            local name = CS_FACADE.normalize_policy(trimmed)
            if name == false then
                return nil, string.format("unknown policy for %s: %s (want one of %s)",
                    model, trimmed, CS_LEXICON.POLICY_NAMES_JOIN)
            end
            next_rows[model] = name
        end
        touched = true
    end

    if not touched then
        return nil, "nothing to apply: send policy, model_policies or model_policy"
    end

    -- Every section validated: rebuild the config, mutate only the policy keys,
    -- and write once.
    local cfg = CS_FACADE.current()
    if next_global ~= nil or rawget(patch, "policy") ~= nil then
        cfg.policy = next_global
    end
    if next_rows ~= nil then cfg.model_policies = next_rows end
    return commit_snapshot(cfg)
end

--- Whole-document replace (JSON editor). Validate first: nothing half-applies.
--- Returns (snapshot, nil, reconcile_summary_or_nil); the summary is present
--- only when this call actually reconciled the pool (root ruling 2), so a
--- config-only save keeps the response shape it always had.
function _M.apply_document(doc)
    local previous = CS_UPSTREAMS.previous_upstream_map(CS_FACADE.current())
    local cfg, err = CS_SNAPSHOT.cfg_from_document(doc, previous)
    if not cfg then return nil, err end
    local saved, serr, scur = CS_PERSISTENCE.write_snapshot(CS_SNAPSHOT.snapshot_of(cfg))
    if not saved then return nil, CS_PERSISTENCE.store_conflict_message(serr, scur) end
    local summary
    if type(doc) == "table"
        and (rawget(doc, "upstreams") ~= nil or rawget(doc, "virtual_models") ~= nil) then
        summary = CS_FACADE.reconcile_upstreams()
    end
    return CS_SNAPSHOT.snapshot_of(CS_FACADE.current()), nil, summary
end

-- ------------------------------------------------------------- watcher

return _M
