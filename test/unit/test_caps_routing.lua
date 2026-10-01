#!/usr/bin/env luajit
-- 每服务并发/功率硬上限（需求 B）+ 虚拟模型多绑定（需求 A）的选路单测。
-- 纯 luajit：不绑端口、不起容器，因此可与 host 网络门禁并发。
--
-- 手法沿用 test/unit/test_integration.lua 第 5 节：router.lua 依赖 klib 与 cosocket，
-- 在 resty CLI 里 require 不起来，所以按函数名把**真实源码**切出来配桩加载，断言跑的
-- 就是盘上那份实现。模型许可的两个 accessor 用桩复刻 registry 的三值语义（真实现由
-- e2e_caps 的 S1 在真容器里钉），这里钉的是 router.candidate_may_serve 怎么**用**它们
-- —— 那正是本次选路接入新增的判定式。
--
-- 组：
--   G1 IGW 模型门四条款（含两条"未盖章声明行不得放宽收窄"的负向断言）
--   G2 candidates 多绑定：同模型/跨模型/IGW 两侧/半套配置降级
--   G3 candidates 与旧 workers 同时存在 -> 交集
--   G4 硬上限边界：达到即排除、读数未知不排除、<=0 与非数字不限
--   G5 上限排除发生在策略之前（cache_aware 亲和的前提）
--   G6 卡片/策略键优先级（card_key_for / profile_policy_model）
--   G7 counted 双计守卫（log_inference_request 会二次调用同一函数）
--   G8 缺省零行为变化：老配置与改动前一致
--
-- 运行：
--   docker run --rm -v "$PWD":/repo:ro -w /repo -e LUA_TEST_LIB=/repo/lualib \
--     --entrypoint /usr/local/openresty/luajit/bin/luajit authz:latest \
--     test/unit/test_caps_routing.lua
local lib = os.getenv("LUA_TEST_LIB") or "./lualib"
local fh = io.open(lib .. "/resty/luarouter/router.lua")
local src = fh and fh:read("*a")
if type(src) ~= "string" then
    print("FAIL: cannot read router.lua from " .. lib)
    os.exit(1)
end

-- 两块真源码。锚点用导出语句而不是相邻函数名：以后在两块之间插入新函数不会把切块切坏，
-- 只会让断言照样跑在真实现上。
local b1 = src:match("(local function is_array_table.-)_M%.profile_worker_list")
local b2 = src:match("(local function record_in_allow_list.-)_M%.compact_url")
if type(b1) ~= "string" or type(b2) ~= "string" then
    print("FAIL: source blocks not extracted (" .. tostring(b1 ~= nil) .. ","
        .. tostring(b2 ~= nil) .. ")")
    os.exit(1)
end

local pool, avail, caps, igw_on, counters
local registry = {}
-- 桩的形状必须是**普通函数**而不是方法：调用点写成 registry.is_available(id)，桩若声明
-- 成 function(_, id) 就会把 id 读进 "_"、把 nil 当成第二个参数，断言全绿但什么也没验。
registry.records = function() return pool end
registry.is_available = function(id) return avail[id] ~= false end
registry.normalize_url = function(u) return (u:gsub("/+$", "")) end
registry.load = function(id)
    local c = caps[id]
    return (c and c.inflight) or 0
end
-- 三值语义与 registry.lua 一致：只有引擎亲口答过（models_verified）且列表里没有 M 才是
-- false，"从没获知"是 nil。placeholder 永不进列表，也和 norm_models 同一口径。
local function list_of(rec)
    local out = {}
    local function note(name)
        if type(name) == "string" and name ~= "" and name ~= "unknown" then
            for i = 1, #out do
                if out[i] == name then return end
            end
            out[#out + 1] = name
        end
    end
    note(rec.model_id)
    for i = 1, #(rec.models or {}) do note(rec.models[i]) end
    return out
end
registry.models_are_verified = function(rec)
    return type(rec) == "table" and rec.models_verified == true
end
registry.worker_serves_model = function(rec, want)
    if type(want) ~= "string" or want == "" then return nil end
    local list = list_of(rec)
    for i = 1, #list do
        if list[i] == want then return true end
    end
    if #list > 0 then
        return false
    end
    return nil
end
registry.candidate_allows_model = function(rec, want)
    if type(want) ~= "string" or want == "" then return true end
    local verdict = registry.worker_serves_model(rec, want)
    if verdict ~= false then return true end
    if registry.models_are_verified(rec) then return false end
    return true
end
registry.capacity_exclusion = function(rec)
    local c = caps[rec.id]
    if not c then return nil end
    local mc = tonumber(rec.max_concurrency)
    if c.inflight and mc and mc > 0 and c.inflight >= mc then
        return { reason = "concurrency", inflight = c.inflight, max_concurrency = mc }
    end
    local mw = tonumber(rec.max_power_w)
    if c.watts and mw and mw > 0 and c.watts >= mw then
        return { reason = "power", power_w = c.watts, max_power_w = mw }
    end
    return nil
end

local sandbox = {
    registry = registry,
    cfg = function() return { enable_igw = igw_on and true or false } end,
    observability = {
        counter = function(name, pairs_spec)
            local reason = pairs_spec and pairs_spec[1] and pairs_spec[1][2] or "?"
            local key = name .. ":" .. reason
            counters[key] = (counters[key] or 0) + 1
        end,
        log_debug = function() end,
    },
    ngx = { log = function() end, INFO = 1, shared = {},
            re = { gsub = function(s) return s end, find = function() return nil end } },
    cjson = require("cjson.safe"),
}
setmetatable(sandbox, { __index = _G })
local chunk = load("local _M = {}\n" .. b1 .. "\n" .. b2 .. "\n"
    .. "return { candidates_for = candidates_for, profile_bindings = profile_bindings,"
    .. " card_key_for = card_key_for, profile_policy_model = profile_policy_model,"
    .. " profile_worker_list = profile_worker_list, candidate_may_serve = candidate_may_serve,"
    .. " record_in_allow_list = record_in_allow_list }", "caps_routing", "t", sandbox)
if not chunk then
    print("FAIL: extracted source did not compile")
    os.exit(1)
end
local M = chunk()

local n, bad = 0, 0
local function eq(actual, want, name)
    n = n + 1
    if actual ~= want then
        bad = bad + 1
        print("FAIL " .. name .. ": got " .. tostring(actual) .. " want " .. tostring(want))
    end
end
local function urls(list)
    local out = {}
    for i = 1, #list do out[#out + 1] = list[i].url end
    table.sort(out)
    return table.concat(out, ",")
end

local A, B, U
local function reset(igw)
    A = { id = "wa", url = "http://a:1", model_id = "alpha", models = { "alpha" },
          models_verified = true }
    B = { id = "wb", url = "http://b:1", model_id = "beta", models = { "beta" },
          models_verified = true }
    U = { id = "wu", url = "http://u:1", model_id = "unknown" }
    pool, avail, caps, counters = { A, B, U }, {}, {}, {}
    for i = 1, #pool do avail[pool[i].id] = true end
    igw_on = igw and true or false
end
local function counted(reason)
    return counters["smg_worker_capacity_excluded_total:" .. reason] or 0
end

-- -------------------------------------------------------- G1 the IGW model gate
reset(false)
eq(#M.candidates_for("anything", nil), 3, "G1 igw-off ignores the model entirely")
reset(true)
eq(urls(M.candidates_for("alpha", nil)), A.url .. "," .. U.url,
   "G1 igw-on narrows by the primary model and keeps the never-discovered row")
reset(true)
eq(#M.candidates_for("unknown", nil), 1,
   "G1 a request naming 'unknown' only matches the placeholder row")
reset(true)
eq(#M.candidates_for("gamma", nil), 1,
   "G1 an engine-verified denial filters the row; the unknown row stays routable")
reset(true)
eq(#M.candidates_for(nil, nil), 3,
   "G1 no name asked = the gate abstains, as the pre-feature not-model branch did")
reset(true)
eq(#M.candidates_for("", nil), 3, "G1 an empty name is not a name")
-- 负向断言 1：未盖章的声明行不得对任意模型名放行。直接调 candidate_allows_model 的旧写法
-- 在这里会恒 true —— 那正是这次接入要堵掉的假绿。
reset(true)
B.models_verified = false
B.models = { "beta", "legacy-name" }
eq(#M.candidates_for("legacy-name", nil), 1,
   "G1 a declared-but-unverified list must not WIDEN igw")
eq(#M.candidates_for("beta", nil), 2,
   "G1 the primary of an unverified row still routes; the bit only gates widening")
-- 负向断言 2：钉住 e2e_profiles "[S2] the old model_id stopped routing under igw" 的成因
-- —— config 行改名时 patch_record 清掉 models_verified，而列表里还 fold 着旧名。
reset(true)
B.model_id, B.models, B.models_verified = "dup-renamed", { "dup-renamed", "dup-m" }, false
eq(#M.candidates_for("dup-m", nil), 1,
   "G1 a renamed config row stops answering its old id while unverified")
B.models_verified = true
eq(#M.candidates_for("dup-m", nil), 2,
   "G1 once the engine re-advertises that name it routes again")
reset(true)
A.models = { "alpha", "alpha-alt" }
eq(urls(M.candidates_for("alpha-alt", nil)), A.url .. "," .. U.url,
   "G1 a second engine-advertised name routes with no binding")

-- ------------------------------------------------------------ G2 multi-bindings
local bound = { target = "alpha", candidates = {
    { worker = "http://a:1", model = "alpha" },
    { worker = "http://b:1", model = "beta" } } }
reset(false)
local got = M.candidates_for("vm", bound)
eq(#got, 2, "G2 bindings keep both instances (the old equality dropped B)")
local byid = { [got[1].id] = got[1], [got[2].id] = got[2] }
eq(byid.wa.lr_bound_model, "alpha", "G2 A carries its own bound name")
eq(byid.wb.lr_bound_model, "beta", "G2 B carries a different bound name")
reset(true)
eq(#M.candidates_for("vm", bound), 2, "G2 a binding outranks igw equality")
reset(true)
eq(#M.candidates_for("vm", { candidates = { { worker = "http://b:1", model = "alpha" } } }), 1,
   "G2 cross-binding under igw: the binding replaces the client name")
reset(true)
eq(#M.candidates_for("vm", { candidates = { { worker = "http://a:1", model = "gamma" } } }), 1,
   "G2 a bound name the engine denies stays selectable under igw")
reset(false)
eq(#M.candidates_for("vm", { candidates = { { worker = "http://zz:9", model = "alpha" } } }), 0,
   "G2 an unmatchable binding empties the set (the caller answers 503)")
eq(M.profile_bindings({ candidates = { { model = "orphan" } } }), nil,
   "G2 a row without worker = no bindings at all, never half a set")
eq(M.profile_bindings({ candidates = { { worker = "", model = "x" } } }), nil,
   "G2 an empty worker string also degrades the whole set")
eq(M.profile_bindings({ candidates = "x" }), nil, "G2 non-array candidates = no bindings")
eq(M.profile_bindings({}), nil, "G2 no profile = no bindings")
reset(true)
-- A matches its primary and U is the never-discovered placeholder: exactly the
-- unbound IGW result for this pool, which is what "degrade, do not widen" means.
eq(urls(M.candidates_for("alpha", { candidates = { { model = "orphan" } } })),
   A.url .. "," .. U.url,
   "G2 a broken bindings block falls back to the unbound igw narrowing")

-- ------------------------------------------------------ G3 bindings + workers
reset(false)
eq(urls(M.candidates_for("vm", { candidates = bound.candidates,
    workers = { "http://b:1" } })), B.url,
   "G3 a legacy whitelist next to bindings still restricts (intersection)")
eq(#M.candidates_for("vm", { candidates = bound.candidates,
    workers = { "http://zz:9" } }), 0,
   "G3 a whitelist that matches nothing wins over the bindings")
eq(#M.candidates_for("vm", { candidates = bound.candidates,
    workers = { "http://a:1", "http://b:1" } }), 2,
   "G3 two lists that agree keep both bindings")

-- --------------------------------------------------------------- G4 hard caps
reset(false)
A.max_concurrency, caps.wa = 3, { inflight = 3 }
eq(#M.candidates_for("z", nil, true), 2, "G4 at the concurrency cap = excluded")
eq(counted("concurrency"), 1, "G4 the counted pass bills the exclusion by reason")
reset(false)
A.max_concurrency, caps.wa = 3, { inflight = 2 }
eq(#M.candidates_for("z", nil), 3, "G4 one below the cap stays selectable")
reset(false)
B.max_power_w, caps.wb = 200, { watts = 260 }
eq(#M.candidates_for("z", nil, true), 2, "G4 at the power cap = excluded")
eq(counted("power"), 1, "G4 power exclusions bill separately")
reset(false)
B.max_power_w, caps.wb = 200, {}
eq(#M.candidates_for("z", nil), 3, "G4 a missing watt reading never excludes")
reset(false)
B.max_power_w, caps.wb = 200, { watts = 199.9 }
eq(#M.candidates_for("z", nil), 3, "G4 just under the watt cap stays selectable")
reset(false)
A.max_concurrency, caps.wa = 0, { inflight = 99 }
B.max_power_w, caps.wb = -5, { watts = 400 }
eq(#M.candidates_for("z", nil), 3, "G4 a cap <= 0 means unlimited in both directions")
reset(false)
A.max_concurrency, caps.wa = "abc", { inflight = 9 }
eq(#M.candidates_for("z", nil), 3, "G4 a non-numeric cap is unlimited, not a wall")
reset(false)
A.max_concurrency, B.max_concurrency = 5, 5
caps.wa, caps.wb = { inflight = 5 }, { inflight = 5 }
local list, why = M.candidates_for("z", nil)
eq(#list, 1, "G4 only the uncapped worker survives")
eq(why and why.capped, 2, "G4 the capped count rides the second return for the 503 wording")

-- ------------------------------- G5 the caps bite before the policy is asked
reset(false)
A.max_concurrency, caps.wa = 1, { inflight = 1 }
eq(urls(M.candidates_for("vm", bound)), B.url,
   "G5 a capped candidate leaves a bound profile too (affinity cannot keep it)")
reset(false)
A.max_concurrency, caps.wa = 1, { inflight = 1 }
B.max_concurrency, caps.wb = 1, { inflight = 1 }
eq(#M.candidates_for("vm", bound), 0,
   "G5 every candidate over cap = an empty array for policy:select")

-- ------------------------------------------------------- G7 counting is opt-in
reset(false)
A.max_concurrency, caps.wa = 3, { inflight = 3 }
eq(#M.candidates_for("z", nil), 2, "G7 the uncounted pass filters identically")
eq(counted("concurrency"), 0, "G7 the request-log re-read bills nothing")
eq(#M.candidates_for("z", nil, false), 2, "G7 counted=false also filters")
eq(counted("concurrency"), 0, "G7 and still bills nothing")
eq(#M.candidates_for("z", nil, true), 2, "G7 only the selection pass bills")
eq(counted("concurrency"), 1, "G7 one sample per counted pass")

-- ------------------------------------------------ G6 card / policy model keys
local p_plain = { target = "alpha" }
eq(M.card_key_for(p_plain, "alpha", A, nil), "alpha",
   "G6 unbound = exactly the old resolved id")
eq(M.card_key_for(p_plain, "alpha", A, "beta"), "beta",
   "G6 an explicit binding outranks everything")
eq(M.card_key_for({ candidates = { { worker = "x", model = "beta" } }, target = "beta" },
                  "alias", A, nil), "beta",
   "G6 before the pick a bindings profile uses its declared representative")
eq(M.card_key_for({ candidates = { { worker = "x" } }, target = "t1" }, nil, A, nil), "t1",
   "G6 candidates-only without a binding falls to target, not to the alias")
eq(M.card_key_for(p_plain, nil, { model_id = "m" }, nil), nil,
   "G6 no card is invented from a worker model_id when nothing is configured")
eq(M.card_key_for(nil, nil, A, nil), nil, "G6 nothing configured = nil")
local rec_bound = { id = "x", model_id = "irrelevant", lr_bound_model = "gamma" }
eq(M.card_key_for(nil, nil, rec_bound, nil), "gamma",
   "G6 a record's own binding wins even with no profile")
eq(M.profile_policy_model(p_plain), nil, "G6 an unbound profile keeps the old policy key")
eq(M.profile_policy_model(bound), nil, "G6 two different bindings keep the alias key")
eq(M.profile_policy_model({ candidates = { { worker = "http://a:1", model = "alpha" },
                                            { worker = "http://b:1", model = "alpha" } } }),
   "alpha", "G6 bindings that agree on one model make it the policy key")
eq(M.profile_policy_model({ candidates = { { worker = "http://a:1" } } }), nil,
   "G6 a binding with no model of its own is not a policy key")

-- ------------------------------------------------------ G8 default no-op
reset(false)
eq(urls(M.candidates_for("z", nil)), "http://a:1,http://b:1,http://u:1",
   "G8 an unconfigured deployment routes the whole pool")
local p_workers = { target = "alpha", workers = { "http://a:1/" } }
reset(true)
eq(urls(M.candidates_for("alpha", p_workers)), A.url,
   "G8 the legacy whitelist pins one instance (trailing slash normalises)")
reset(true)
eq(#M.candidates_for("beta", p_workers), 0,
   "G8 legacy whitelist plus a wrong model is empty")
eq(M.profile_worker_list({ workers = { "x" } })[1], "x", "G8 the worker list is read")
eq(M.profile_worker_list({ workers = {} }), nil, "G8 an empty list = the full pool")
eq(M.profile_worker_list(nil), nil, "G8 no profile = the full pool")
reset(false)
avail.wb = false
eq(#M.candidates_for("beta", nil), 2, "G8 an unavailable worker leaves the set")
-- registry 没有上限判据（被裁掉的单测探针 / 老构建）时必须完全放行，而不是全排除。
local saved = registry.capacity_exclusion
registry.capacity_exclusion = nil
reset(false)
A.max_concurrency, caps.wa = 1, { inflight = 9 }
eq(#M.candidates_for("z", nil), 3, "G8 a missing cap predicate fails open, never closed")
registry.capacity_exclusion = saved

print(string.format("=== %d checks, %d failed ===", n, bad))
os.exit(bad == 0 and 0 or 1)
