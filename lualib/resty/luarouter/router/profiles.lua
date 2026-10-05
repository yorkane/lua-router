-- 虚拟模型 profile 读层（自 router.lua 逐字搬来，只调整了 require 接线）。
--
-- config_store 之上的 pcall + 类型守卫缝（doc/gap-virtual-models.md §3.3）。两条
-- 恒 nil 停用缝（profile_policy_name / profile_effort_value，用户裁定 2026-10-02）
-- 是刻意保留的兼容行为，**不是死代码清理对象**（AGENTS.md）。
-- test/unit/test_caps_routing / test_profiles 11b / test_effort_layers 按字符串
-- 锚点切本文件源码配桩——锚点区间内的代码逐字不许动。
local host = require "resty.luarouter.router.host"

local _M = {}
package.loaded["resty.luarouter.router.profiles"] = _M

local store = host.store
-- Virtual-model profile hooks (doc/gap-virtual-models.md 3.3). The helpers
-- call store(), so they are defined next to it further below; the names are
-- forward declared here because policy_for already consults them.
local profile_for_alias, profile_worker_list, profile_policy_name, profile_effort_value,
    profile_model_group, profile_entry_fallback
-- ------------------------------------------------------------- profile reads
--
-- doc/gap-virtual-models.md 3.3. Every config_store entry point here goes
-- through pcall + type checks: while the store has no profiles feature (a
-- mid-rollout build, a stripped unit probe, or worker A's file still landing),
-- each helper answers nil/"" and the call sites keep their pre-feature
-- behaviour byte-for-byte. Profile reads ride the store's own snapshot cache
-- (SNAPSHOT_TTL), so a request adds no shared-dict round trip.

---Profile for one *client-facing* alias (profile_for keys off the requested
---name, not the resolved target). Shape: {target, workers, policy, effort}.
---@param model string|nil
---@return table|nil
profile_for_alias = function(model)
    if type(model) ~= "string" or model == "" then
        return nil
    end
    local store_mod = store()
    if not store_mod or type(store_mod.profile_for) ~= "function" then
        return nil
    end
    local ok, profile = pcall(store_mod.profile_for, model)
    if ok and type(profile) == "table" then
        return profile
    end
    return nil
end

_M.profile_for_alias = profile_for_alias

local function is_array_table(v)
    if type(v) ~= "table" then
        return false
    end
    local n = 0
    for k in pairs(v) do
        -- LuaJIT-safe integer test (math.tointeger is 5.3+): the key must be a
        -- positive whole number.
        if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
            return false
        end
        n = n + 1
    end
    return n == #v
end

---The mapped model group of a profile (1 对多), or nil.
---
---Root ruling 2026-10-02 turns the virtual model into the *service entry point*: one
---public name covers a group of real models and the policy picks among them. The store
---normalizes every spelling (explicit targets, a lone legacy target, or the distinct
---models of the per-candidate bindings) into this one array, so the router has exactly
---one question to ask: which names does this entry stand for.
---
---Guards mirror profile_worker_list/profile_bindings: the store validated on write, so
---this only keeps a hand-edited on-disk document from taking down the hot path. A row
---whose shape is wrong yields nil, which means "not a group entry" and the request
---routes on the pre-feature path rather than on half a declaration.
---@param profile table|nil
---@return string[]|nil group
profile_model_group = function(profile)
    if type(profile) ~= "table" then
        return nil
    end
    -- Only a group the operator *wrote* selects like a group. The store derives a
    -- one-element group for every legacy row (a lone target always had one), and reading
    -- that as "group mode" would move the policy tree key and the engine model gate onto
    -- configs that never asked for them -- a byte-for-byte behaviour change for existing
    -- deployments, which the design red line forbids.
    if profile.explicit_targets ~= true then
        return nil
    end
    local raw = profile.targets
    if not is_array_table(raw) or #raw == 0 then
        return nil
    end
    local out, seen = {}, {}
    for i = 1, #raw do
        local model = raw[i]
        if type(model) ~= "string" or model == "" then
            return nil
        end
        if not seen[model] then
            seen[model] = true
            out[#out + 1] = model
        end
    end
    if #out == 0 then
        return nil
    end
    return out
end

_M.profile_model_group = profile_model_group

---Non-empty candidate whitelist of a profile, or nil (= full pool). The store
---validates the shape on write; the guards here only protect the hot path from
---a hand-edited document.
---@param profile table|nil
---@return string[]|nil
profile_worker_list = function(profile)
    if type(profile) ~= "table" then
        return nil
    end
    local workers = profile.workers
    if not is_array_table(workers) or #workers == 0 then
        return nil
    end
    for i = 1, #workers do
        if type(workers[i]) ~= "string" or workers[i] == "" then
            return nil
        end
    end
    return workers
end

_M.profile_worker_list = profile_worker_list

-- The eight accepted spellings, mirrored locally so a store without the
-- validator (unit probes) still recognises them; when the store is present
-- its normalize_policy is the single source of truth (same POLICY_SET the
-- config page writes through).
local FALLBACK_POLICY_SET = {
    random = true, round_robin = true, cache_aware = true, power_of_two = true,
    prefix_hash = true, manual = true, bucket = true, consistent_hashing = true,
}
local FALLBACK_EFFORT_SET = {
    none = true, minimal = true, low = true, medium = true, high = true,
    xhigh = true, max = true, ultra = true,
}

local function plain_trim(value)
    return string.gsub(value, "^%s*(.-)%s*$", "%1")
end

local function normalize_policy_name(value)
    if type(value) ~= "string" then
        return nil
    end
    local lowered = string.lower(plain_trim(value))
    if lowered == "" then
        return nil
    end
    local store_mod = store()
    if store_mod and type(store_mod.normalize_policy) == "function" then
        local ok, named = pcall(store_mod.normalize_policy, lowered)
        if ok and type(named) == "string" and named ~= "" then
            return named
        end
        if ok and named == false then
            return nil
        end
    end
    if FALLBACK_POLICY_SET[lowered] then
        return lowered
    end
    return nil
end

---Effective per-profile policy name. Always nil since root ruling 2026-10-02 (see the
---body): the routing page owns policy, so policy_for must not be handed an alias-level
---override. The function stays because policy_for calls it on every request and unit
---tests pin that the alias layer cannot come back through it.
---@param profile table|nil
---@return nil
profile_policy_name = function(profile)
    if type(profile) ~= "table" then
        return nil
    end
    -- Same ruling as profile_effort_value: scheduling policy is configured per model or
    -- globally on the routing page (model_policies / policy), never on the service
    -- entry. Ignoring both the field and the store reader is what makes the whole
    -- mapped group route under *one* policy instance -- the prerequisite for affinity
    -- and load-escape to hold across the group instead of inside each model.
    return nil
end

_M.profile_policy_name = profile_policy_name

local function normalize_effort_name(value)
    if type(value) ~= "string" then
        return nil
    end
    local lowered = string.lower(plain_trim(value))
    if lowered == "" then
        return nil
    end
    local store_mod = store()
    if store_mod and type(store_mod.normalize_effort) == "function" then
        local ok, named = pcall(store_mod.normalize_effort, lowered)
        if ok and type(named) == "string" and named ~= "" then
            return named
        end
        if ok and named == false then
            return nil
        end
    end
    if FALLBACK_EFFORT_SET[lowered] then
        return lowered
    end
    return nil
end

---Effective per-profile effort. Always nil since root ruling 2026-10-02; kept as a
---named seam because apply_effort_policy already threads the alias/resolved keys and a
---future ruling that restores a *different* per-entry knob lands here rather than in
---the ladder.
---@param profile table|nil
---@param alias string|nil @ client-facing name (unused since the ruling)
---@param resolved string|nil @ upstream id the alias maps to (unused since the ruling)
---@return nil
profile_effort_value = function(profile, alias, resolved)
    if type(profile) ~= "table" then
        return nil
    end
    -- Root ruling 2026-10-02 (虚拟模型语义反转): the effort ladder describes an
    -- *engine*, and a virtual entry now spans several engines, so one per-entry effort
    -- cannot be honest about any of them. It belongs on the model card, keyed by the
    -- real model a request lands on (apply_effort_policy already looks it up there).
    -- The stored field is still accepted and round-tripped so an old document keeps
    -- validating -- and warns at parse time -- but nothing on this path consults it,
    -- because a row nobody deleted must not keep enforcing a rule the design retired.
    -- Both layers go: the profile field *and* the store reader below, which would
    -- otherwise resolve the same alias from the live snapshot.
    return nil
end

--- 虚拟模型条目那一层的档位声明，装配成 request_effort_for 的 entry_fallback。
---
--- 三层继承（用户裁定 2026-10-04：模型卡片 -> 虚拟条目 -> 全局）的中间一层在 router
--- 侧的装配点。读数只从 config_store.entry_declaration 取：它返回新表（改不坏存储），
--- 且刻意把 false / nil 分家，这里要的正是那份三态。
---
--- 只取档位两个字段（default_effort / effort_map）。条目的 supports_tool_use 与
--- modalities 是对外形状的聚合口径，不是转发体的改写位，不能从这里漏进转发链。
---
--- 没有任何条目声明时返回 nil，request_effort_for 于是只查卡片与全局两层，
--- 与改动前逐字节一致（缺省零行为变化）。
---@param profile table|nil
---@param alias string|nil
---@param model string|nil
---@return table|nil entry_fallback
profile_entry_fallback = function(profile, alias, model)
    local store_mod = store()
    if not store_mod or type(store_mod.entry_declaration) ~= "function" then
        return nil
    end
    -- 先按客户端给的名字查（条目的主键），查不到再按解析后的落点名：与
    -- profile_effort_value 一样的两次机会，legacy 别名（条目名不等于落点名）不漏。
    local names = {}
    if type(alias) == "string" and alias ~= "" then names[1] = alias end
    if type(model) == "string" and model ~= "" then names[#names + 1] = model end
    for i = 1, #names do
        local ok, declared = pcall(store_mod.entry_declaration, names[i])
        if ok and type(declared) == "table" then
            local out
            if type(declared.default_effort) == "string" and declared.default_effort ~= "" then
                out = out or {}
                out.default_effort = declared.default_effort
            end
            if type(declared.effort_map) == "table" and next(declared.effort_map) ~= nil then
                out = out or {}
                local map = {}
                for from, to in pairs(declared.effort_map) do map[from] = to end
                out.effort_map = map
            end
            if out then return out end
        end
    end
    return nil
end
-- ------------------------------------------------------------------ raw JSON edits

-- 跨模块接线（拆分新增；上方 banner 行是 test_effort_layers 的 blk_profile 结束
-- 锚点：锚点字符串与原文逐字节一致，只是源码文件从 router.lua 换成了本文件；
-- 它下面没有任何会被切进锚点的代码）。
-- is_array_table / profile_effort_value / profile_entry_fallback 在原文件里是
-- forward() 与 apply_effort_policy 同文件可见的局部，拆开后按名导出。
-- 「先声明、后赋值」的缝（原文件 policy_for 上方的前向声明注释与声明行）随本节
-- 闭合在本文件；那里的 policy_for 现居 router/candidates.lua。
-- 下一节 local function field_pattern 现居 router/jsonutil.lua（这一行刻意保留
-- 字面 "local function field_pattern"：test_profiles 11b 用它做 effort_value
-- 切片的结束锚点，锚点字符串不动、只是源码文件换了）。
_M.is_array_table = is_array_table
_M.profile_effort_value = profile_effort_value
_M.profile_entry_fallback = profile_entry_fallback
return _M
