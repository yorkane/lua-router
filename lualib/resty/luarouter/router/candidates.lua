-- 策略选路与候选装配（自 router.lua 逐字搬来，只调整了 require 接线）。
--
-- P2 policy_for + P11 candidates_for 三道门（健康→白名单/绑定→模型许可→容量
-- 硬排除→组门→绿灯优先裁剪）+ card_key 族。选路热路径：函数体逐行原样，门序不许动
-- （AGENTS.md 硬规则；doc/gap-worker-caps.md、doc/gap-virtual-models.md §1–§4）。
-- test/unit/test_caps_routing 与 test_profiles 11b 按字符串锚点切本文件源码配桩
-- 加载——锚点区间内的代码逐字不许动。
local registry = require "resty.luarouter.registry"
local observability = require "resty.luarouter.observability"
local policy_mod = require "resty.luarouter.policy"

local host = require "resty.luarouter.router.host"
local profiles = require "resty.luarouter.router.profiles"

local _M = {}
package.loaded["resty.luarouter.router.candidates"] = _M

local cfg = host.cfg
-- 拆分接线：这四个读数在原文件里是同文件局部（P8 的前向声明 + 节末赋值），拆开后
-- 由 profiles 子模块导出，这里绑成同形局部，调用点一个字节不改。
local profile_policy_name = profiles.profile_policy_name
local profile_model_group = profiles.profile_model_group
local profile_worker_list = profiles.profile_worker_list
local is_array_table = profiles.is_array_table
local default_policy

--- 「隐藏」门（用户裁定 2026-10-08）的本趟读数：一次取好，整趟候选装配共用。
---
--- 返回 **nil** = 这一趟没有任何隐藏声明，调用方因此**一个字都不必做**（隐藏名册连构造
--- 都不发生）。这就是「没声明 hidden 的部署逐字节不变」那条硬约束在热路径上的形状：
--- config_store 侧的整表判据（any_hidden）替全场答一次「没人说过隐藏」，这里据此跳过。
--- 返回表 = 有两种读法：`blocked` 是「客户端所名的这个入口/模型整个被藏起来」——
--- 候选一律不给（调用方落回既有的「无候选」503 路径）；`member(name)` 问的是「这一组里
--- 的这个**实际模型**还被服务吗」，组门与绑定按它逐个成员收窄。
---
--- 两个读法都走 config_store 的**同一份判定**（readers.lua 的 model_is_hidden：卡片
--- hidden=true 或入口 hidden=true），本函数一个判据都不复刻。store 缺席、reader 缺席
--- （半程发布的旧 build）、pcall 出错，一律答 nil = 没有这道门 —— 一个读不出来的隐藏
--- 声明绝不该把一台在服务的实例从池里抹掉（AGENTS.md 硬规则 4 的同一姿态）。
---
--- 落点在**切片区间之外**是有意的：本文件的函数体被 test_caps_routing 与 test_profiles 11b
--- 按字符串锚点切出去配桩加载，切片环境里没有 config_store。于是切片里 `hidden_pass`
--- 是一个 nil 全局，调用点的 `hidden_pass ~= nil and ...` 直接短路成「没有这道门」，
--- 那两份单测继续跑在改动前的行为上；真模块口径（本目录的 require）才有这道门。
---@param model string|nil @ route_inference 传下来的解析结果（组入口下 = 代表值/组头）
---@param profile table|nil @ 入口 profile（组路径的策略桶名 = profile.model）
---@param is_group boolean|nil @ 这一趟是**组**选路（profile_model_group 非空）
---@return table|nil
local function hidden_pass(model, profile, is_group)
    local ok_store, store_mod = pcall(require, "resty.luarouter.config_store")
    if not ok_store or type(store_mod) ~= "table" then return nil end
    local any_reader = store_mod.any_hidden
    local asked_reader = store_mod.model_is_hidden
    if type(any_reader) ~= "function" or type(asked_reader) ~= "function" then return nil end
    local ok_any, flagged = pcall(any_reader)
    if not ok_any or flagged ~= true then return nil end
    -- 到这里才有人真的说过隐藏（没说过时上面已经 return nil，一次表都不构造）。此后每问
    -- 一句走的都是 config_store 那份带 revision/TTL 记忆的名册（一次哈希查表 + 一次
    -- revision 令牌读，与本文件既有热路径上的 shdict 读数同档），而且整趟只建这一份闭包。
    -- 组入口每趟的问句数量 = 组内成员数 + 每台候选的绑定判定，量级仍是"几个名字"。
    local function asked(name)
        if type(name) ~= "string" or name == "" then return false end
        local ok_ask, verdict = pcall(asked_reader, name)
        return ok_ask and verdict == true
    end
    -- 「整个入口/模型被藏」只在两个名字上判：**入口自己的名字**（一个入口一棵亲和树、
    -- 对外那一行也叫这个名字，操作员勾的就是它），以及**非组路径下客户端所名的落点名**
    -- （裸模型、legacy 单目标入口、手写脏行 —— 那条路上 model 就是要服务的真实模型）。
    --
    -- 组路径刻意**不**问 model：那是 profile 的代表值（组头），不是客户端报的名字，
    -- 拿它当整组判据会让「勾掉组里一台」变成「整组一个候选都不给」。组里的成员由
    -- member 逐个收窄（下面的组门），这正是「藏一台、其余照常服务」的形状。
    if asked(type(profile) == "table" and profile.model)
        or (not is_group and asked(model)) then
        return { blocked = true }
    end
    return { member = asked }
end
-- Policy selection, per model.
--
-- The Rust gateway owns one PolicyRegistry that keys policies by model
-- (policies/registry.rs): the hint a worker advertises in labels.policy fixes the
-- policy of its model when that model gets its first worker, later workers of the
-- same model do not change it, and a model without a hint uses the configured
-- default. policy_mod.for_model holds the instances; policy.default stays the
-- global one so init_worker's eviction sweep and mesh mirror have an anchor.
-- Called from policy_for, which sits a thousand lines above their definitions: without
-- this forward declaration the reference compiles to a global read and the select path
-- dies on a nil call at the first group request.
local group_key_name, group_policy_hint
local function policy_for(model, profile)
    local conf = cfg()
    if not default_policy then
        default_policy = policy_mod.new(conf)
        default_policy.generation = policy_mod.generation()
        policy_mod.default = default_policy
    end
    -- Idempotent: init_worker already starts the sweep in every process, so this
    -- only matters when the policy is built outside that phase (unit probes).
    policy_mod.start_eviction()
    if type(model) ~= "string" or model == "" then
        return default_policy
    end
    -- Profile layer (gap-virtual-models 3.3): an explicit profile.policy sits
    -- above the whole for_model chain (model_policies > global > hint > env).
    -- Reuse the shared instance cache so affinity state survives (same key
    -- shape policy_mod.for_model uses); an unknown name collapses inside
    -- policy.new exactly like every other operator-set policy name.
    local forced = profile_policy_name(profile)
    if forced then
        local inst = policy_mod.instances[forced .. ":" .. model]
        if not inst then
            inst = policy_mod.new(conf, { model = model, name = forced })
            inst.generation = policy_mod.generation()
            if ngx and ngx.shared then
                inst:restore_snapshot()
            end
        end
        return inst
    end
    -- Group mode: the service entry, not any one of its models, owns the policy state
    -- (one entry = one instance = one affinity tree). Two things have to be arranged for
    -- that key to behave like a real model's:
    --   * the hint has to come from the *group's* workers, since no worker advertises the
    --     entry's name and policy_hint_for_model(entry) would always answer nil;
    --   * has_workers is computed against the group rather than the entry name, so the
    --     "last worker gone, forget the instance" rule still fires when the pool really
    --     empties (a truthful signal) and does not fire merely because the entry name
    --     never appears in a record (which would hand every entry the shared global
    --     instance and silently pool two entries' affinity together).
    local group = profile_model_group(profile)
    if group then
        local hint, live = group_policy_hint(group)
        -- 第四个参数必须是布尔：policy.for_model 判定的是 has_workers == false，
        -- 直接把 group_policy_hint 的**计数**递过去，数字永远不等于 false，「最后一个 worker
        -- 走了就丢掉该实例」这条规则对组入口就永久失效——池子清空后入口仍抱着旧的策略实例
        -- 与旧的亲和树，等 worker 带不同 labels.policy 回来时，新 hint 被旧实例盖住。
        -- 组清空 → false（真的回收），组内有活 → true（不误收，因为入口名本身不在任何
        -- record 里，按名字问会永远得到 0 而被误判成空池）。
        return policy_mod.for_model(conf, group_key_name(profile, model), hint, live > 0)
    end
    local hint, count = registry.policy_hint_for_model(model)
    if not hint then
        -- No advertised hint: Rust's get_policy_or_default. The global instance is
        -- keyed "default", so a model without a hint shares its affinity state with
        -- the fallback path exactly as the pre-per-model router did.
        return default_policy
    end
    return policy_mod.for_model(conf, model, hint, count > 0)
end

_M.policy_for = policy_for
-- ------------------------------------------------------------------ selection

---Match one record against a profile's candidate whitelist, and say *which* row
---matched.
---
---The body is the one the legacy `workers` whitelist used, moved here unchanged:
---the new `candidates` bindings are the same matching rule with a model name hung
---off the winning row, and if the two spellings ever matched differently, the same
---intent written two ways would route two ways. That is why this is a helper and
---not a second copy of the loop.
---@param record table
---@param allow string[]
---@return boolean hit, number|nil index @ 1-based position inside allow
local function record_in_allow_list(record, allow)
    local rec_url
    if registry.normalize_url then
        local ok, normalized = pcall(registry.normalize_url, record.url)
        if ok and type(normalized) == "string" then
            rec_url = normalized
        end
    end
    for j = 1, #allow do
        local want = allow[j]
        local hit = want == record.id
        if not hit and rec_url ~= nil then
            local ok, normalized = pcall(registry.normalize_url, want)
            if ok and type(normalized) == "string" then
                hit = normalized == rec_url
            end
        end
        if hit then
            return true, j
        end
    end
    return false, nil
end

---Per-candidate model bindings of a profile, flattened to two parallel arrays
---(`allow[i]` matches the pool, `models[i]` is the name to forward there).
---nil = the profile declares none, which is every pre-feature config: the alias
---points at one target and the whole pool shares it.
---
---形状守卫与 profile_worker_list 同一套：store 在写入时已经校验过，这里只防一张手改过的
---磁盘文档把选路热路径带崩。任一条缺 worker 或 worker 不是字符串就整体当作"没有绑定"，
---回退到旧语义——半套绑定比没有绑定更危险，因为漏掉的那条会静默继承别的候选的模型名。
---@param profile table|nil
---@return string[]|nil allow, string[]|nil models
local function profile_bindings(profile)
    if type(profile) ~= "table" then
        return nil
    end
    local raw = profile.candidates
    if not is_array_table(raw) or #raw == 0 then
        return nil
    end
    local allow, models = {}, {}
    for i = 1, #raw do
        local item = raw[i]
        if type(item) ~= "table" then
            return nil
        end
        local worker = item.worker
        if type(worker) ~= "string" or worker == "" then
            return nil
        end
        local model = item.model
        allow[#allow + 1] = worker
        models[#models + 1] = (type(model) == "string" and model ~= "") and model or nil
    end
    if #allow == 0 then
        return nil
    end
    return allow, models
end

_M.profile_bindings = profile_bindings

---The upstream model name whose config cards (effort, ctx cap) and policy hint apply.
---
---One function because three readers have to agree: the effort ladder, the context
---card and the policy decision each key off a model name, and under per-candidate
---bindings that name is only known once a worker is chosen. If they disagreed, one
---request would get instance A's effort, instance B's ctx card and C's
---routing tree -- three layers describing three different engines, which is exactly
---what the override feature exists to prevent.
---
---Priority, and why the chosen instance's name comes first: an operator who bound two
---instances to two models means two engines, and each engine's own effort/ctx card is
---the only one that describes what it can actually do. The alias-level settings stay
---as the fallback below, so anything configured there still applies whenever the
---per-instance name is not a configured key.
---  1. the binding of the selected candidate (explicit, or carried by the record);
---  2. the profile's declared target, for a bindings profile read *before* selection;
---  3. the resolved alias -- which is the requested name itself when the model is not
---     an alias, i.e. exactly what the pre-feature code passed, so an unbound config
---     cannot move.
---@param profile table|nil
---@param resolved string|nil @ alias target, or the requested name when not an alias
---@param worker table|nil @ selected worker record (nil before selection)
---@param bound string|nil @ binding carried by the selected candidate
---@return string|nil card_key
local function card_key_for(profile, resolved, worker, bound)
    local named = function(value)
        if type(value) == "string" and value ~= "" then
            return value
        end
        return nil
    end
    return named(bound)
        or named(type(worker) == "table" and worker.lr_bound_model or nil)
        or (type(profile) == "table" and profile.candidates ~= nil
            and named(profile.target) or nil)
        or resolved
end

_M.card_key_for = card_key_for

---The single upstream model name an explicitly bound alias stands for, or nil.
---
---nil whenever the answer is not single: an unbound profile (every pre-feature
---config), or bindings that name more than one model, in which case the request's
---destination really is undecided until the policy has spoken.
---
---Derived from the *declared* bindings and never from the surviving candidates, for
---two reasons. Stability: a policy instance is keyed by model, so an answer that
---flickered with the pool would move an alias's affinity tree between keys every time a
---worker came or went, which is a worse cache_aware than a dumb one. Agreement: the
---same function is called before the pick (to decide whether the routing text is worth
---extracting) and at the pick itself, and the two must not disagree.
---@param profile table|nil
---@return string|nil
local function profile_policy_model(profile)
    if type(profile) ~= "table" then
        return nil
    end
    -- A group entry has no single model to name (that is the whole point), and its
    -- policy instance is keyed by the entry itself inside policy_for, so reporting a
    -- model here would be both wrong and misleading to the caller.
    if profile.explicit_targets == true then
        return nil
    end
    if profile.candidates == nil then
        return nil
    end
    local allow, models = profile_bindings(profile)
    if not allow then
        return nil
    end
    local named = models[1]
    if type(named) ~= "string" or named == "" then
        return nil
    end
    for i = 2, #models do
        if models[i] ~= named then
            return nil
        end
    end
    return named
end

_M.profile_policy_model = profile_policy_model
---Model gate for one candidate: may this instance be handed a request for `want`?
---
---The IGW-shaped question is "may a request that *names* M be given to this row", and
---the answer is the pre-feature equality widened in exactly one direction: a second
---name the engine itself advertised also routes (that is what lets an instance serving
---two names be addressed by either, with no binding needed). Every other combination
---is refused, and the two refusals are load-bearing:
---  * an unverified list (a config row, a hand-written POST /workers) is a note, not a
---    fact, so it must not *widen* the narrowing switch;
---  * the "unknown" placeholder cannot ride the three-way question -- no engine ever
---    advertises it, so a probed row would be denied by definition (right, but by luck)
---    while a never-discovered row is the one thing IGW-without-a-client-model is defined
---    to match, since route_inference falls back to "unknown" precisely to make the
---    lookup get_by_model("unknown"). Hence the literal comparison on the primary model.
---@param record table
---@param want string|nil
---@return boolean
local function candidate_may_serve(record, want)
    if type(want) ~= "string" or want == "" then
        -- IGW narrows a *name*; a client that named nothing gives the gate nothing to
        -- ask, and it abstains exactly as the pre-feature `not model` branch did.
        return true
    end
    local primary = record.model_id
    if primary == want then
        return true
    end
    if primary == "unknown" then
        -- Never discovered: the pre-feature clause, kept verbatim. A row whose model is
        -- still the placeholder answers to every name, because "we have not looked yet"
        -- must never cost capacity -- and it is also the *only* row a request that named
        -- nothing resolves to, since route_inference turns an omitted model into
        -- get_by_model("unknown") while IGW is on.
        return true
    end
    -- Widening beyond the primary model needs the engine itself to have named it.
    -- `candidate_allows_model` answers "still routable" for an unverified list, which is
    -- the right answer when the alternative is killing a healthy worker over a config
    -- typo, but IGW is the narrowing switch: a name that was only ever typed into a
    -- config row must not *widen* it. Concretely, renaming a config-declared upstream
    -- clears models_verified in patch_record (registry.lua) and refresh_models then
    -- sits behind its 300 s `mp:` cooldown, so a fold-leftover of the previous name
    -- would keep routing a dead id for five minutes. Two pinned contracts say so:
    -- test_lua_router.sh "IGW: unknown model is 503" and e2e_profiles "[S2] the old
    -- model_id stopped routing under igw".
    if registry.models_are_verified(record)
        and registry.worker_serves_model(record, want) == true then
        return true
    end
    return false
end
---What name the policy state of one selection pass is bucketed under.
---
---The entry's own client-facing name when this is a group pass (the callers hand the
---requested name in), otherwise the resolved model id as before. Falls back to the
---representative target when no client name is available (a direct callers such as the
---/_ui chat path), so the bucket is still one stable string per entry.
---@param profile table|nil
---@param model string|nil
---@return string
group_key_name = function(profile, model)
    -- The entry name first: it is one stable string per service entry, whereas the
    -- resolved id is the group's *head*, which two entries could share by accident (and
    -- then they would silently pool their affinity state).
    if type(profile) == "table" and type(profile.model) == "string" and profile.model ~= "" then
        return profile.model
    end
    if type(model) == "string" and model ~= "" then
        return model
    end
    if type(profile) == "table" and type(profile.target) == "string" and profile.target ~= "" then
        return profile.target
    end
    return "unknown"
end

---The labels.policy hint and live-worker count of a whole mapped group.
---
---Mirrors registry.policy_hint_for_model's rule ("the first worker of the model fixes
---the policy"): the first *available* record that serves any model of the group wins, in
---registry order, so the hint is stable while its workers are. Counting live members here
---rather than passing a constant true keeps policy.for_model's eviction rule meaningful
---for an entry name that no record carries.
---@param group string[]
---@return string|nil hint, number count
group_policy_hint = function(group)
    local records = registry.records()
    local hint, count = nil, 0
    for i = 1, #records do
        local record = records[i]
        local serves = false
        for j = 1, #group do
            if registry.candidate_allows_model(record, group[j]) then
                serves = true
                break
            end
        end
        if serves then
            count = count + 1
            if hint == nil then
                local labels = record.labels
                if type(labels) == "table"
                    and type(labels.policy) == "string" and labels.policy ~= "" then
                    hint = labels.policy
                end
            end
        end
    end
    return hint, count
end

_M.group_policy_hint = group_policy_hint

---Healthy, breaker-not-open workers that may take this request.
---
---One pass, three gates, ordered cheap-first:
---  1. registry.is_available  -- health + pool membership + circuit breaker;
---  2. the profile's whitelist (the legacy `workers` list, or the new
---     `candidates` bindings, which are the same match with a model attached);
---  3. the model permission, then the capacity caps.
---
---Why the model question goes to candidate_may_serve instead of a bare
---`record.model_id == model`: with per-candidate bindings one alias spans several
---model names, so "does *this* instance serve *that* name" has to be asked of the
---advertised list, not of the one primary column. The gate still sits behind
---`enable_igw` for the unbound shapes (that is the pre-feature meaning of the switch)
---and widens the old equality in one direction only -- see candidate_may_serve for
---why a name nobody but the engine itself wrote down must not widen it. An explicit
---binding is operator intent and therefore applies whether or not IGW is on.
---
---Why the caps exclude here rather than rank: cache_aware's affinity hit reads its
---tenant out of the tree by URL and never looks at load
---(policies/cache_aware.lua), so an over-ceiling-but-sticky worker keeps exactly the
---traffic this rule exists to move. Excluding it from the array handed to
---`policy:select` is the one place where the two cannot disagree, and the tree's own
---dirty-tenant cleanup plus the next rebalance relocate the affinity onto a
---surviving candidate without any help from here.
---@param model string|nil
---@param profile table|nil @ virtual-model profile (whitelist / bindings, gap-virtual-models 3.3)
---@param counted boolean|nil @ true = the selection pass, and the only caller allowed to
---            count exclusions and green-light yields. log_inference_request runs this
---            same filter again after the response to list what was selectable; letting it
---            count would bill every exclusion twice per request and make the counter
---            unreadable, so counting is opt-in rather than a side effect of asking the
---            question.
---@return table[] candidates, table|nil why
local function candidates_for(model, profile, counted)
    local records = registry.records()
    local out = {}
    -- Green-light preference (doc/caps-redesign-2026-10-06.md section 3) works on two
    -- side arrays indexed 1..live alongside out[i]: the capacity state a survivor was
    -- priced with, and the model name it was bound to. Parallel arrays rather than one
    -- table per candidate, because this loop is the selection hot path and the
    -- pre-feature shape allocated nothing per candidate beyond the decoded record.
    local states = {}
    local bindings = {}
    local live = 0
    local igw = cfg().enable_igw
    local bound_allow, bound_models = profile_bindings(profile)
    local legacy_allow = profile_worker_list(profile)
    local allow = bound_allow or legacy_allow
    -- Group mode (root ruling 2026-10-02): the entry stands for a set of real models,
    -- and which one a candidate serves is a question for *that engine*, not a name the
    -- operator wrote. Computed once per pass -- the group is a few strings and this loop
    -- is the hot path, so the per-record membership test below stays a table lookup.
    local group = profile_model_group(profile)
    local in_group
    if group then
        in_group = {}
        for i = 1, #group do in_group[group[i]] = true end
    end
    -- 「隐藏」门（用户裁定 2026-10-08）：整趟只问 config_store 一次，判据只有一份（文件头的
    -- hidden_pass）。按代价从低到高排三件事：先问「有没有人说过隐藏」—— 没说过就是 hid=nil，
    -- 下面每一支都短路，选路路径与改动前逐字节相同、连一次 shdict 读都不多；再说「这个入口
    -- 被整个藏起来」—— 这一趟**不给任何候选**，调用方落回既有的「无候选」503 路径（forward
    -- 按 #candidates==0 出文案：一条被操作员抹掉的名字与「池里没有这个模型」对外同形，正是
    -- 「不再被服务」的语义。刻意不复用 refused 那条组专属文案 —— 「没有这个服务」与「有这个
    -- 服务但引擎都不接」是两句不同的话，操作员据此该查的东西也相反）；最后是按成员收窄。
    --
    -- 排在 group 之后是必需的：组与否决定了「客户端所名的那个算不算一个模型」这一判
    -- （见 hidden_pass 的 is_group），两处必须用同一个 group 读数，不能各问一次。
    --
    -- hidden_pass 在**切片口径**下是 nil 全局（test_caps_routing / test_profiles 11b 把
    -- candidates_for 连这一带切出去配桩加载，那个沙箱没有 config_store），于是 hid 恒 nil、
    -- hidden_name 恒 false，那两份单测继续跑在改动前的行为上；锚点区间里因此对切片环境
    -- 零新增要求（只有一个 nil 全局 + 一个本函数内的 local 闭包）。
    local hid = hidden_pass ~= nil and hidden_pass(model, profile, group ~= nil) or nil
    if hid ~= nil and hid.blocked then
        -- 空数组就是答案：调用方（forward）按 #candidates==0 落**既有的「无候选」503 路径**
        -- （用户裁定要的那句「按现有无候选路径 503」），文案一字不改。三个计数全给 0 是
        -- 如实报数：这一趟一次引擎谓词都没问（没 refused）、没问容量（没 capped）、没让位
        -- （没 idle）；刻意不带 group 旗标 —— 那条专属文案要求 refused>0，这里给 0 就永远
        -- 不触发它，也就不会替操作员编一句「引擎回绝了你的 targets」（真相是操作员自己藏的）。
        return {}, { capped = 0, refused = 0, idle = 0 }
    end
    ---@param name any @ 实际模型名（组内成员 / 绑定名 / record.model_id）
    ---@return boolean
    local function hidden_name(name)
        if hid == nil then return false end
        if type(name) ~= "string" or name == "" then return false end
        return hid.member(name) == true
    end
    -- Registry-side cap predicate (doc/gap-worker-caps.md). Read-only from here:
    -- the two numbers it compares are this gateway's own in-flight counter and
    -- gpu_load's watt samples, both maintained elsewhere. Absent (a stripped unit
    -- probe, an older build) means no gate at all, which is the fail-open direction
    -- the rule itself demands -- a missing reading must never cost capacity.
    local cap_check = registry.capacity_exclusion
    -- The traffic-light half of the *same* verdict, taken once per pass the same way as
    -- cap_check and with the same fail-open shape: nil -- not the counted pass, a
    -- stripped unit probe, an older build without capacity_state -- means no narrowing,
    -- i.e. today's behaviour. The request-log re-read deliberately runs unpriced: it
    -- exists to list *what was selectable*, and a busy candidate was selectable, so
    -- narrowing there would shrink the log row's candidate list for a distinction the
    -- row does not report -- and would pay one lo:/gu: read per candidate for a verdict
    -- it has no use for.
    -- Why a second predicate rather than reusing cap_check's verdict: capacity_exclusion
    -- answers "is this worker out of the pool", so it returns numbers only for the "full"
    -- case -- idle and busy both come back nil, which carries no state at all. The
    -- registry owns the comparison (registry/loads.lua bars a caller from deriving the
    -- light from lo:/gu: at home), so the router asks instead of recomputing. The cost is
    -- bounded on purpose:
    --   * a candidate the hard gate already removed is never asked -- it leaves the pass
    --     before this call -- so the extra predicate runs on survivors only;
    --   * a candidate that declares no ceiling costs *zero* shdict reads: the registry
    --     short-circuits on "all three caps nil" before it touches the dict, the same
    --     guard the hard gate has. An unconfigured pool therefore pays one Lua call per
    --     candidate and not one extra shdict round-trip;
    --   * only a candidate that really declares min/max/util pays that single lo: get
    --     (plus gu: once max_gpu_util is set) -- and the operator configured the ceiling
    --     precisely so the gateway would read that key. The dict handle is a memoized
    --     upvalue in registry.keys.shdict, so omitting the `d` argument costs no lookup
    --     per candidate either.
    local price = counted and registry.capacity_state or nil
    local capped = 0
    local refused = 0
    for i = 1, #records do
        local record = records[i]
        local keep = registry.is_available(record.id)
        local binding
        if keep and allow then
            local hit, index = record_in_allow_list(record, allow)
            keep = hit
            if hit and bound_models then
                binding = bound_models[index]
            end
            -- Two lists at once take the *intersection*. The bindings say which name
            -- a candidate is addressed by; the legacy whitelist says whether that
            -- instance may be touched at all. Letting the bindings shadow it would
            -- mean an operator who added `workers` next to the new `candidates` field
            -- silently *lost* a restriction they had just written down -- a new field
            -- must never widen what an old one already limited.
            if keep and bound_allow ~= nil and legacy_allow ~= nil then
                keep = record_in_allow_list(record, legacy_allow)
            end
        end
        -- Model permission, and it is asked only of an *unbound* candidate under IGW.
        -- A binding is the operator naming the pair himself, so the engine's advertised
        -- list must not veto it: the whole point of a binding is to address an instance
        -- under a name its own /v1/models need not carry (a second serving name, a
        -- renamed checkpoint, a proxy that maps names). Refusing there would make
        -- cross-binding unconfigurable, which is the feature being asked for. The IGW
        -- narrowing, by contrast, is a guess about a client-supplied name, and a guess
        -- the engine has explicitly contradicted is worth 4xx-ing locally.
        -- 组模式下这道门整个让位给下面的组门。客户端报的是入口名，而入口名不会
        -- 出现在任何引擎的 /v1/models 里（引擎背书的是它所映射的实际模型名），照入口名
        -- 去问引擎等于「凡是被引擎亲口答过的实例一律否掉」——enable_igw 一开就会
        -- 把整组健康实例筛空，只剩从没被探过的那一行。组门问的才是正确的问题：这个候选
        -- 能否提供组里的任一名（candidate_allows_model，未探过=可路由）。模型收窄没有被
        -- 取消，只是换了问法：从「你叫这个名字吗」改成「这一组里有没有你能服务的」。
        if keep and binding == nil and igw and not group then
            if not candidate_may_serve(record, model) then
                keep = false
                refused = refused + 1
            end
        end
        -- Hard capacity gate (requirement B): exclusion, not a ranking term, so the
        -- policy below cannot see a worker that is at its ceiling.
        if keep and cap_check then
            local ok, verdict = pcall(cap_check, record)
            if ok and type(verdict) == "table" then
                keep = false
                capped = capped + 1
                if counted then
                    observability.counter("smg_worker_capacity_excluded_total", {
                        { "reason", verdict.reason or "cap" } })
                    observability.log_debug("capacity cap excluded ", record.url,
                        ": ", verdict.reason, " (",
                        tostring(verdict.inflight or verdict.gpu_util), " >= ",
                        tostring(verdict.max_concurrency or verdict.max_gpu_util), ")")
                end
            end
        end
        -- Group gate: ask the engine, never guess. A candidate stays if any model of
        -- the group is one it will take; the *first* such name becomes the forwarding
        -- binding. candidate_allows_model is deliberately the registry's fail-open
        -- predicate -- false only when the engine answered /v1/models itself and its
        -- list lacks the name -- so a worker nobody ever probed is not excluded for the
        -- crime of being un-inspected (design red line: a probe failure may not cost
        -- capacity).
        if keep and group then
            local serve, serving = nil, 0
            for i = 1, #group do
                -- 被藏起来的组名**整个从这一趟的组里消失**：既不能成为 serve 候选，
                -- 也不能被选作转发绑定名。刻意做在 candidate_allows_model **之前** ——
                -- 后者是引擎的 fail-open 谓词（没探过的实例一律算可路由），把操作员的话
                -- 排在它前面，「藏起来的模型即使从没被探过也不冒出来」才是结构性的。
                if not hidden_name(group[i]) and registry.candidate_allows_model(record, group[i]) then
                    serving = serving + 1
                    if serve == nil then
                        serve = group[i]
                    end
                end
            end
            if serving == 0 then
                keep = false
                refused = refused + 1
            else
                -- An explicit binding is operator intent and outranks the engine's
                -- answer, but only for a name inside the group (the store refuses the
                -- others at write time, this guards a hand-edited document).
                -- 隐藏压过操作员绑定：绑到一个被藏起来的模型 = 这个绑定这一趟不作数，
                -- 退回引擎愿意服务的另一个组名（一个都不剩时上面的 serving==0 已经排掉）。
                if binding ~= nil and (not in_group[binding] or hidden_name(binding)) then
                    binding = serve
                elseif binding == nil then
                    -- Prefer the name the worker leads with: two candidates that both
                    -- serve the whole group then disagree less often about which one is
                    -- "their" model, and a worker serving the group through its primary
                    -- name forwards the same id it advertises today.
                    local primary = record.model_id
                    if primary ~= nil and in_group[primary] and primary ~= "unknown"
                        and not hidden_name(primary) then
                        binding = primary
                    else
                        binding = serve
                    end
                end
            end
        end
        -- 非组路径的「隐藏」门（组路径上面已按成员与绑定收窄，这里管 legacy 单目标、
        -- 无入口的裸模型、以及手写脏行）：这台实例对外所服务的名字被藏起来，就不进候选。
        -- 绑定优先看绑定名（转发时真正发出去的那个名字），没有绑定看 record.model_id；
        -- "unknown" 占位永不判隐藏 —— 它不是任何模型的名字，把它否掉就是让「还没被探到」
        -- 这台实例替一个它并不持有的名字受罚（与旁边的模型许可门同一理由，且 IGW 下
        -- get_by_model("unknown") 那条老契约要靠它活着）。
        -- 计进 refused 而不是 capped：它是「这个名字不给服务」，不是「容量到顶」，
        -- 于是 429 的判据（forward 只看 why.capped）不会被它污染。
        if keep and hid ~= nil then
            local served = binding
            if served == nil then served = record.model_id end
            if served ~= nil and served ~= "unknown" and hidden_name(served) then
                keep = false
                refused = refused + 1
            end
        end
        if keep then
            -- Survived every gate, the hard capacity one included: park it and price its
            -- traffic light, but do not stamp or measure it yet. The narrowing below can
            -- still step this candidate aside, and registry.load() (two or three shdict
            -- reads of its own) must not be billed for a worker that never reaches a policy.
            live = live + 1
            out[live] = record
            bindings[live] = binding
            if price then
                local ok, state = pcall(price, record)
                -- A predicate that throws reads as "state unknown", never as "exclude":
                -- the same posture as the cap gate's pcall above, for the same reason
                -- (AGENTS.md hard rule 4 -- a broken reading costs accuracy, not capacity).
                states[live] = (ok and state) or nil
            end
        end
    end
    -- Green-light preference (root ruling 2026-10-06, doc/caps-redesign-2026-10-06.md
    -- section 3): when somebody in the surviving set sits below its lower concurrency
    -- rung, the yellows step aside for it. A *narrowing*, not an exclusion -- the
    -- stepped-aside candidates are healthy and under their ceiling, they are merely less
    -- available than the greens, and the policy keeps all of its freedom inside the
    -- subset it is handed (policies/ still knows nothing about any of this).
    -- Three rules shape it, each because the loose reading of a one-line-sounding feature
    -- breaks something specific:
    --   * it sits after the group gate and after bindings resolved, so a group entry is
    --     priced as one pool (one tree, one subset) and an operator's per-candidate
    --     binding is never undone by a traffic light;
    --   * only a known "busy" yields. nil means the candidate declares no ceiling (or
    --     could not be asked), and dropping it would let an uncapped worker starve
    --     because a capped peer happens to be green -- red line 2 says a reading that
    --     cannot be had must not cost capacity, and e2e_caps S2 would die on the spot,
    --     since there the uncapped Y has to take all 6 concurrent requests while the
    --     capped X stays excluded;
    --   * when nothing is idle -- every survivor busy, every survivor unknown, or nobody
    --     left at all -- the array passes through untouched, so a yellow keeps taking
    --     traffic up to its own ceiling instead of being pushed off a green that already
    --     holds its minimum (user rule 3).
    -- yielded rides why.idle for observability and never why.capped: the 429 downstream
    -- means "every worker is at a hard ceiling", and billing a yield as a cap would let a
    -- pool that is merely *preferencing* greens answer with a capacity-exhausted diagnostic.
    local yielded = 0
    -- Records the narrowing stepped aside, kept only so forward() can still honour an
    -- explicit `x-smg-target-worker` pin: the pin is not a policy decision, and silently
    -- rerouting a request that names its instance would turn a debug/affinity tool into
    -- a coin flip whenever some *other* worker happens to be green. nil unless a yield
    -- actually happened, so the shape costs nothing on an uncapped pool. The hard
    -- capacity gate has no such escape -- "an explicit pin cannot resurrect a capped
    -- worker" is pinned by e2e_caps S3, and `full` candidates never reach this array.
    local stepped_aside
    if price and live > 1 then
        local idle = 0
        for i = 1, live do
            local state = states[i]
            if state == "idle" then
                idle = idle + 1
            elseif state == "busy" then
                yielded = yielded + 1
            end
        end
        if idle > 0 and yielded > 0 then
            local kept = 0
            for i = 1, live do
                if states[i] ~= "busy" then
                    kept = kept + 1
                    out[kept] = out[i]
                    bindings[kept] = bindings[i]
                else
                    -- Stamp what the pin path reads (the forwarded model name comes from
                    -- lr_bound_model; `healthy` keeps the record honest about having
                    -- passed the health gate) but *not* record.load: only the policies
                    -- read that, and a pinned request never reaches one, so the
                    -- stepped-aside workers keep costing the two shdict reads their
                    -- capacity verdict needed and nothing more.
                    local stepped = out[i]
                    stepped.healthy = true
                    stepped.lr_bound_model = bindings[i]
                    stepped_aside = stepped_aside or {}
                    stepped_aside[#stepped_aside + 1] = stepped
                end
            end
            for i = kept + 1, live do
                out[i] = nil
                bindings[i] = nil
            end
            live = kept
            if counted then
                -- One sample per counted pass, the same discipline as the hard gate's
                -- counter below: the request-log re-read bills nothing.
                observability.counter("smg_worker_capacity_preferred_idle_total", {})
            end
        else
            yielded = 0
        end
    end
    for i = 1, live do
        local record = out[i]
        -- The standalone policies read load and health off the worker itself
        -- (Rust reads them through Worker::load()/is_healthy()), so hand them a
        -- snapshot alongside the static record. records() decodes fresh tables,
        -- so neither this field nor the binding can leak back into the dict.
        record.load = registry.load(record.id)
        record.healthy = true
        record.lr_bound_model = bindings[i]
        -- One entry, one affinity tree. The standalone policies bucket their state
        -- by (pool, model) read off the *worker* (policies/cache_aware.lua
        -- make_tree_key, prefix_hash/consistent_hashing ring keys, bucket keys), so
        -- a group spanning two models would split into two trees whose tenant sets
        -- never see each other -- affinity and load-escape would then hold *inside*
        -- each model and fail across the group, which is exactly the thing this
        -- feature is for. Stamping the entry name into the field they read makes the
        -- whole group one pool. Forwarding is unaffected: it reads lr_bound_model,
        -- which is always set for a group candidate (never the entry name), so no
        -- request can be sent upstream under a name no engine knows.
        if group then
            record.model_id = group_key_name(profile, model)
        end
    end
    -- Second return value: how many candidates the capacity gate removed, so the 503
    -- can tell "nothing healthy" apart from "healthy, but every one of them is at its
    -- cap", and how many the engine's own model answer refused. A second return is free
    -- for callers that ignore it (Lua truncates the tuple), which is why this is not
    -- module state that a retry or the request-log re-read would have to race with.
    -- group 旗标只服务 503 文案：组入口被引擎「答过、且都不服务这一组」时，沿用
    -- 「全部熔断或不健康」是假的（它们健康，只是没有组里的名字）。legacy 路径不带
    -- 这个旗标，所以旧文案一个字都不会变。
    -- idle 恒为「被绿灯挤下去的黄灯数」（0 = 这一趟没有发生让位），与 capped/refused 同为
    -- 常驻数字键：它不参与任何应答文案（429 的判据仍只看 capped），只是让「让位发生过没
    -- 有、让了几台」在 /metrics 之外还能按请求查。group 旗标保持缺席式缺省——那一个才真的
    -- 只服务 503 文案。
    return out, { capped = capped, refused = refused, idle = yielded,
                  stepped_aside = stepped_aside,
                  group = group ~= nil and true or nil }
end

local function compact_url(url)
    return ngx.re.gsub(url, [[^https?://]], "", "jo")
end

_M.candidates_for = candidates_for
_M.compact_url = compact_url
-- 跨模块接线（拆分新增；文末，不进任何单测锚点区间）。原处已有的就近导出
-- （policy_for / profile_bindings / card_key_for / profile_policy_model /
-- group_policy_hint / candidates_for / compact_url）留在上面原样，赋的是本模块 _M。
_M.record_in_allow_list = record_in_allow_list
_M.candidate_may_serve = candidate_may_serve
_M.group_key_name = group_key_name
return _M
