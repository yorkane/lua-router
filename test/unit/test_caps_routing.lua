#!/usr/bin/env luajit
-- 每服务并发/利用率硬上限（doc/caps-redesign-2026-10-06.md）+ 虚拟模型多绑定（需求 A）
-- 的选路单测。
-- 纯 luajit：不绑端口、不起容器，因此可与 host 网络门禁并发。
--
-- 手法沿用 test/unit/test_integration.lua 第 5 节：router.lua 依赖 klib 与 cosocket，
-- 在 resty CLI 里 require 不起来，所以按函数名把**真实源码**切出来配桩加载，断言跑的
-- 就是盘上那份实现。模型许可的两个 accessor 用桩复刻 registry 的三值语义（真实现由
-- e2e_caps 的 S1 在真容器里钉），这里钉的是 router.candidate_may_serve 怎么**用**它们
-- —— 那正是本次选路接入新增的判定式。
--
-- 2026-10-06 容量语义重设计：capacity_exclusion 只对 "full" 返回
-- {reason="concurrency_max"|"gpu_util"}（"concurrency"/"power" 两个旧字符串退役），
-- candidates_for 在组门与绑定之后追加**绿灯优先**裁剪（被让位的黄灯记 why.idle，不计入
-- why.capped）。本文件对 registry 谓词一直是**桩**（旧版假绿的根源：桩自己实现判定、
-- 与生产脱节）。桩保留——它钉的是 candidates_for 怎么**使用**谓词；判定本体从此由 G9
-- 直接跑 registry/loads.lua 的**真源码**（假 shdict、零端口），不再有零覆盖的真空。
--
-- 组：
--   G1 IGW 模型门四条款（含两条"未盖章声明行不得放宽收窄"的负向断言）
--   G2 candidates 多绑定：同模型/跨模型/IGW 两侧/半套配置降级
--   G3 candidates 与旧 workers 同时存在 -> 交集
--   G4 硬上限边界（桩）：达到即排除、util 读数未知不排除、并发档 <=0 不限、
--      util 档 0 是合法极严档（与并发档相反）
--   G5 上限排除发生在策略之前（cache_aware 亲和的前提）
--   G6 卡片/策略键优先级（card_key_for / profile_policy_model）
--   G7 counted 双计守卫（log_inference_request 会二次调用同一函数）
--   G8 缺省零行为变化：老配置与改动前一致、两个谓词各自缺席 fail-open
--   G9 真判定（**不打桩**）：registry/loads.lua 的 capacity_state / capacity_exclusion /
--      cap_limit / util_limit / set_gpu_util 切真源码配假 shdict 直测（idle/busy/full
--      边界、util 0 极严档、gu 缺席不排除、reason 字符串、无门零次 dict 读、TTL 回未知）
--   G10 绿灯优先：全 idle / 混合 / 全 busy / 全 full 四种下的返回数组与 why 计数
--
-- 运行：
--   docker run --rm -v "$PWD":/repo:ro -w /repo -e LUA_TEST_LIB=/repo/lualib \
--     --entrypoint /usr/local/openresty/luajit/bin/luajit authz:latest \
--     test/unit/test_caps_routing.lua
local lib = os.getenv("LUA_TEST_LIB") or "./lualib"
-- 2026-10-05 拆分（doc/refactor-arch-2026-10-05.md §1）：实现搬进了
-- lualib/resty/luarouter/router/ 子模块，逐字搬家、锚点字符串一个都不动；
-- 搬家的只是**源码文件路径**。旧实现对照通道（LR_*_LEGACY 指向改动前的
-- lualib 树）没有子模块文件，读不到就回退读整只 router.lua。
local function read_src(rel)
    local f = io.open(lib .. "/resty/luarouter/router/" .. rel)
    if f then
        local s = f:read("*a")
        f:close()
        if type(s) == "string" and s ~= "" then return s end
    end
    local g = io.open(lib .. "/resty/luarouter/router.lua")
    local s = g and g:read("*a")
    if g then g:close() end
    return s
end
-- G9 要跑 registry 的真判定，同一手法读 registry/loads.lua（对照树里判定住在整只
-- registry.lua，没有子模块文件时回退读它）。
local function read_registry_src(rel)
    local f = io.open(lib .. "/resty/luarouter/registry/" .. rel)
    if f then
        local s = f:read("*a")
        f:close()
        if type(s) == "string" and s ~= "" then return s end
    end
    local g = io.open(lib .. "/resty/luarouter/registry.lua")
    local s = g and g:read("*a")
    if g then g:close() end
    return s
end
local src_profiles = read_src("profiles.lua")
local src_candidates = read_src("candidates.lua")
local src_loads = read_registry_src("loads.lua")
if type(src_profiles) ~= "string" or type(src_candidates) ~= "string" then
    print("FAIL: cannot read router sources from " .. lib)
    os.exit(1)
end
if type(src_loads) ~= "string" then
    print("FAIL: cannot read the registry source from " .. lib)
    os.exit(1)
end

-- 两块真源码。锚点用导出语句而不是相邻函数名：以后在两块之间插入新函数不会把切块切坏，
-- 只会让断言照样跑在真实现上。
-- is_array_table 一族在 router/profiles.lua，候选装配一族在 router/candidates.lua。
local b1 = src_profiles:match("(local function is_array_table.-)_M%.profile_worker_list")
local b2 = src_candidates:match("(local function record_in_allow_list.-)_M%.compact_url")
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
-- 三态判定桩（doc/caps-redesign-2026-10-06.md §2 的口径）。桩存在的意义只剩一件事：
-- 钉 candidates_for 怎么**使用**谓词（排除位置、计数、pcall、绿灯裁剪的数组与 why
-- 形状）。判定本体的真覆盖在 G9 —— 那里 require 的是盘上的 registry，不经过这份桩。
-- 口径与 registry/loads.lua 的 capacity_verdict 一致：full = inflight >= max_concurrency
-- 或新鲜 util 读数 >= max_gpu_util；idle = 非 full 且 inflight < min_concurrency（缺席
-- 读 1）；其余 busy；三档全缺席 = 无门。并发档按 cap_limit 形状（<=0/非数 = 不限、向下
-- 取整），util 档按 util_limit 形状（**0 是合法的极严档**，只有负数/非数才是不限）。
-- lo: 缺失当 0（本网关的计数器，恒已知），util 缺失当**未知**（永不因它排除）。
local function stub_verdict(rec)
    local c = caps[rec.id]
    local mc = tonumber(rec.max_concurrency)
    if mc == nil or mc ~= mc or mc <= 0 then mc = nil else mc = math.floor(mc) end
    local mn = tonumber(rec.min_concurrency)
    if mn == nil or mn ~= mn or mn <= 0 then mn = nil else mn = math.floor(mn) end
    local mu = tonumber(rec.max_gpu_util)
    if mu == nil or mu ~= mu or mu < 0 then mu = nil else mu = math.floor(mu) end
    if mc == nil and mn == nil and mu == nil then return nil end
    local inflight = (c and c.inflight) or 0
    if mc ~= nil and inflight >= mc then
        return "full", { reason = "concurrency_max", inflight = inflight,
            max_concurrency = mc }
    end
    if mu ~= nil and c ~= nil and c.util ~= nil then
        local milli = math.floor(c.util * 1000 + 0.5)
        if milli >= mu * 10 then
            return "full", { reason = "gpu_util", gpu_util = milli / 1000,
                max_gpu_util = mu }
        end
    end
    if inflight < (mn or 1) then return "idle" end
    return "busy"
end
registry.capacity_exclusion = function(rec)
    local state, verdict = stub_verdict(rec)
    if state ~= "full" then return nil end
    return verdict
end
registry.capacity_state = function(rec)
    local state = stub_verdict(rec)
    return state
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
local function check(cond, name, detail)
    n = n + 1
    if not cond then
        bad = bad + 1
        print("FAIL " .. name .. ": " .. tostring(detail))
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
local function yielded_count()
    return counters["smg_worker_capacity_preferred_idle_total:?"] or 0
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
-- 判定本体（真实现）由 G9 直测；这一组钉 candidates_for 怎么**使用**谓词：排除发生在
-- 策略之前、计数按 reason 分档、缺席读数不排除、util 档 0 是合法极严档（与并发档 <=0
-- 的方向相反——那是 cap_limit 与 util_limit 唯一的分岔，两侧都必须照真口径钉住）。
reset(false)
A.max_concurrency, caps.wa = 3, { inflight = 3 }
eq(#M.candidates_for("z", nil, true), 2, "G4 at the concurrency cap = excluded")
eq(counted("concurrency_max"), 1, "G4 the counted pass bills the exclusion by reason")
reset(false)
A.max_concurrency, caps.wa = 3, { inflight = 2 }
eq(#M.candidates_for("z", nil), 3, "G4 one below the cap stays selectable")
reset(false)
B.max_gpu_util, caps.wb = 60, { util = 0.65 }
eq(#M.candidates_for("z", nil, true), 2, "G4 at the GPU-util cap = excluded")
eq(counted("gpu_util"), 1, "G4 util exclusions bill separately from concurrency")
reset(false)
B.max_gpu_util, caps.wb = 60, {}
eq(#M.candidates_for("z", nil), 3, "G4 a missing util reading never excludes")
reset(false)
B.max_gpu_util, caps.wb = 60, { util = 0.599 }
eq(#M.candidates_for("z", nil, true), 3, "G4 just under the util cap stays selectable")
eq(counted("gpu_util"), 0, "G4 and it bills nothing")
reset(false)
B.max_gpu_util, caps.wb = 0, { util = 0.0 }
eq(#M.candidates_for("z", nil, true), 2, "G4 max_gpu_util=0 is the strictest legal gate")
eq(counted("gpu_util"), 1, "G4 and it bills as gpu_util, not under a cap fallback")
reset(false)
B.max_gpu_util, caps.wb = 0, {}
eq(#M.candidates_for("z", nil), 3, "G4 even the 0 gate stays silent without a reading")
reset(false)
A.max_concurrency, caps.wa = 0, { inflight = 99 }
B.max_gpu_util, caps.wb = -5, { util = 0.99 }
eq(#M.candidates_for("z", nil), 3,
   "G4 a concurrency cap <= 0 and a negative util cap are both unlimited")
reset(false)
A.max_concurrency, A.min_concurrency, caps.wa = "abc", "abc", { inflight = 9 }
eq(#M.candidates_for("z", nil), 3, "G4 a non-numeric cap is unlimited, not a wall")
reset(false)
A.max_concurrency, B.max_concurrency = 5, 5
caps.wa, caps.wb = { inflight = 5 }, { inflight = 5 }
local list4, why4 = M.candidates_for("z", nil)
eq(#list4, 1, "G4 only the uncapped worker survives")
eq(why4 and why4.capped, 2,
   "G4 the capped count rides the second return for the 429 wording")
eq(why4 and why4.idle, 0, "G4 nothing yielded here, so why.idle reads 0")
-- 只声明下限**不是**排除，也不计费：它是绿灯优先的阈值，谁都不许因为它少一台。
reset(false)
A.min_concurrency, caps.wa = 4, { inflight = 0 }
eq(#M.candidates_for("z", nil, true), 3, "G4 a lower rung alone excludes nothing")
eq(counted("concurrency_max") + counted("gpu_util"), 0,
   "G4 and the lower rung bills no capacity exclusion")

------------------------------- G5 the caps bite before the policy is asked
reset(false)
A.max_concurrency, caps.wa = 1, { inflight = 1 }
eq(urls(M.candidates_for("vm", bound)), B.url,
   "G5 a capped candidate leaves a bound profile too (affinity cannot keep it)")
reset(false)
A.max_concurrency, caps.wa = 1, { inflight = 1 }
B.max_concurrency, caps.wb = 1, { inflight = 1 }
local empty5, empty_why = M.candidates_for("vm", bound, true)
eq(#empty5, 0, "G5 every candidate over cap = an empty array for policy:select")
eq(empty_why and empty_why.capped, 2,
   "G5 the second return carries the cap count for the 429 branch")
-- 硬排除与绿灯让位是两条分开的通道：被硬排除的记录**不会**进 stepped_aside
-- （那是让位旁路，e2e_caps S3 从 pin 一侧钉「上限台连显式 pin 都带不走」）。
-- 形状：A 硬满（capped）、U 全绿（0 < min 4）、B 黄（inflight == min 3）
-- → 裁剪只让 B 让位，A 根本不在存活集里。
reset(false)
A.max_concurrency, caps.wa = 1, { inflight = 1 }
U.min_concurrency, caps.wu = 4, { inflight = 0 }
B.min_concurrency, caps.wb = 3, { inflight = 3 }
local kept5, kept_why = M.candidates_for("z", nil, true)
eq(#kept5, 1, "G5 a hard-capped worker is not rescued by the stepping-aside list")
eq(urls(kept5), U.url, "G5 the surviving candidate is the green worker")
local aside_ids = {}
for i = 1, #(kept_why and kept_why.stepped_aside or {}) do
    aside_ids[kept_why.stepped_aside[i].id] = true
end
eq(aside_ids.wa and 1 or 0, 0, "G5 the capped worker never reaches stepped_aside")
eq(aside_ids.wb and 1 or 0, 1, "G5 the yielded yellow is kept reachable for pins")
eq(kept_why and kept_why.capped, 1, "G5 the capped count says the one hard exclusion")
eq(kept_why and kept_why.idle, 1, "G5 the yielded count says the one yellow")

------------------------------------------------------- G7 counting is opt-in
reset(false)
A.max_concurrency, caps.wa = 3, { inflight = 3 }
eq(#M.candidates_for("z", nil), 2, "G7 the uncounted pass filters identically")
eq(counted("concurrency_max"), 0, "G7 the request-log re-read bills nothing")
eq(#M.candidates_for("z", nil, false), 2, "G7 counted=false also filters")
eq(counted("concurrency_max"), 0, "G7 and still bills nothing")
eq(#M.candidates_for("z", nil, true), 2, "G7 only the selection pass bills")
eq(counted("concurrency_max"), 1, "G7 one sample per counted pass")

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
eq(yielded_count(), 0, "G8 a cap-free pool bills no green-light yield either")
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
-- 2026-10-06 之后有两个谓词可缺：硬门（capacity_exclusion）与红绿灯（capacity_state），
-- 各自 fail-open、互不牵连。
local saved_exclusion = registry.capacity_exclusion
local saved_state = registry.capacity_state
registry.capacity_exclusion = nil
registry.capacity_state = nil
reset(false)
A.max_concurrency, caps.wa = 1, { inflight = 9 }
eq(#M.candidates_for("z", nil), 3, "G8 a missing cap predicate fails open, never closed")
eq(#M.candidates_for("z", nil, true), 3,
   "G8 and the counted pass through a missing predicate bills nothing")
eq(counted("concurrency_max") + counted("gpu_util") + yielded_count(), 0,
   "G8 no predicate, no meter of any kind")
-- 只有红绿灯缺席（老构建没有 capacity_state）：硬门照旧、裁剪整个不跑 —— 交给策略的
-- 数组就是改动前的形状；被硬门摘掉的那台也不会出现在让位旁路里。
registry.capacity_exclusion = saved_exclusion
B.max_gpu_util, caps.wb = 10, { util = 0.9 }
A.min_concurrency, caps.wa = 4, { inflight = 0 }
local half, half_why = M.candidates_for("z", nil, true)
eq(#half, 2, "G8 without capacity_state the hard gate still fires and nothing narrows")
eq(counted("gpu_util"), 1, "G8 the hard gate bills as before when only the light is gone")
eq(half_why and half_why.idle, 0, "G8 an unpriced pass cannot bill yields")
eq(#(half_why and half_why.stepped_aside or {}), 0,
   "G8 no traffic light means no stepped-aside list either")
eq(#M.candidates_for("z", nil), 2,
   "G8 the uncounted pass filters identically without the traffic light")
registry.capacity_state = saved_state
registry.capacity_exclusion = saved_exclusion

---------------------------------------------------------------------------
-- G9 真判定（**不打桩**）：把 registry/loads.lua 的 cap_limit/util_limit、
-- capacity_verdict/capacity_state/capacity_exclusion、set_gpu_util/gpu_util/
-- clear_gpu_util/stale_ttl 按锚点切出**真源码**，配假 shdict 直接跑。这份文件
-- 过去对判定本体只有桩（桩与生产脱节 = G4 假绿），真谓词的覆盖只有过真容器的
-- e2e_caps，而「gu 缺席」「util=0 极严档」「双上限的 reason 优先」「无门零次 dict
-- 读」这些形状在真容器里恰恰造不出来。左端锚点是函数头（导出语句），右端是顶格
-- 的 end（函数体内所有 if/for 的 end 都有缩进）：两族之间插入新函数不会把切块切坏。
---------------------------------------------------------------------------
local NL = string.char(10)
local function grab(head)
    return src_loads:match("(" .. head .. ".-" .. NL .. "end" .. NL .. ")")
end
local blocks = {
    grab("function M%.cap_limit"),
    grab("function M%.util_limit"),
    grab("local function capacity_verdict"),
    grab("function M%.capacity_state"),
    grab("function M%.capacity_exclusion"),
    grab("function M%.set_gpu_util"),
    grab("function M%.gpu_util"),
    grab("function M%.clear_gpu_util"),
    grab("function M%.stale_ttl"),
}
for i = 1, #blocks do
    if type(blocks[i]) ~= "string" then
        print("FAIL: registry block " .. i .. " not extracted from " .. lib)
        os.exit(1)
    end
end

-- 假 shdict：形状同 keys.shdict 的真 dict（get 按名读回、set 带 TTL），外加一个
-- 「这一趟查了几次字典」的计数器 —— 「三档全缺席 = 零次读」是生产护栏（candidates
-- 热路径），没有计数器就没有任何断言会因为它被破坏而红。TTL 用真 os.time。
local dict_store, dict_gets
local function dict_reset()
    dict_store, dict_gets = {}, 0
end
local function fake_get(_, key)
    dict_gets = dict_gets + 1
    local hit = dict_store[key]
    if not hit then return nil end
    if hit.expire and hit.expire <= os.time() then return nil end
    return hit.value
end
local function fake_set(_, key, value, ttl)
    dict_store[key] = {
        value = tostring(value),
        expire = (tonumber(ttl) and tonumber(ttl) > 0)
            and (os.time() + tonumber(ttl)) or nil,
    }
    return true
end
local function fake_delete(_, key)
    dict_store[key] = nil
    return true
end
dict_reset()
local REG_TABLE = {}
local real_env = {
    K_LOAD = "lo:", K_GPU_UTIL = "gu:", K_ACTIVE = "act:",
    shdict = function()
        return { get = fake_get, set = fake_set, delete = fake_delete }
    end,
    M = REG_TABLE,
    R = nil,   -- late-bound below: the extracted code reads R.cap_limit / R.stale_ttl
    ngx = { log = function() end, WARN = 4, shared = {},
            now = function() return os.time() end },
}
setmetatable(real_env, { __index = _G })
local real_chunk = load(table.concat(blocks, NL) .. NL .. "return M",
    "caps_registry_real", "t", real_env)
if not real_chunk then
    print("FAIL: extracted registry source did not compile")
    os.exit(1)
end
local REG = real_chunk()
-- R 与真 facade 同一个 late-bind 口径（loads.lua 文件尾）：切出来的判定读
-- R.cap_limit / R.util_limit / R.stale_ttl，全部指向这份真实现自己。
real_env.R = REG

-- lo: 用手拼整数串（真写者是 change_load 的 incr），gu: 走 set_gpu_util 的真拼写
-- （0..1 折成毫、带 TTL）。桩里「手拼一个数字当读数」省掉的格式知识，正是过去
-- 没有覆盖的部分。
local function put_inflight(id, value)
    dict_store["lo:" .. id] = { value = tostring(value) }
end

-- 无门：三档全缺席 = nil，且一次字典读都不发（未配置部署的热路径成本护栏）。
dict_reset()
eq(REG.capacity_state({ id = "g9" }), nil, "G9 real: no ceiling declared = no gate at all")
eq(REG.capacity_exclusion({ id = "g9" }), nil, "G9 real: no gate excludes nothing")
eq(dict_gets, 0, "G9 real: an ungated record costs zero shdict reads")
eq(REG.capacity_state(nil), nil, "G9 real: a non-table record reads as no gate")
-- 并发三态边界：min 的 idle 档、含相等的 full、busy 可选。
dict_reset(); put_inflight("g9", 2)
eq(REG.capacity_state({ id = "g9", min_concurrency = 2, max_concurrency = 3 }), "busy",
   "G9 real: at the lower rung but one below the ceiling is busy, not full")
eq(REG.capacity_exclusion({ id = "g9", min_concurrency = 2, max_concurrency = 3 }), nil,
   "G9 real: busy stays selectable — the gate answers nil")
put_inflight("g9", 3)
eq(REG.capacity_state({ id = "g9", max_concurrency = 3 }), "full",
   "G9 real: the comparison is inclusive (inflight >= ceiling)")
local verdict = REG.capacity_exclusion({ id = "g9", max_concurrency = 3 })
eq(type(verdict) == "table" and verdict.reason or "?", "concurrency_max",
   "G9 real: the concurrency verdict names its reason")
eq(verdict and verdict.inflight, 3, "G9 real: the verdict carries its reading")
eq(verdict and verdict.max_concurrency, 3, "G9 real: and the ceiling that decided it")
dict_reset(); put_inflight("g9", 0)
eq(REG.capacity_state({ id = "g9", max_concurrency = 3 }), "idle",
   "G9 real: zero in-flight under any ceiling reads idle (absent min is 1)")
eq(REG.capacity_state({ id = "g9", min_concurrency = 4, max_concurrency = 9 }), "idle",
   "G9 real: below the declared lower rung reads idle")
eq(REG.capacity_exclusion({ id = "g9", min_concurrency = 4, max_concurrency = 9 }), nil,
   "G9 real: the lower rung never excludes — idle is not a verdict")
-- 利用率通道：>= 含相等判、缺席 = 未知、0 是合法极严档。
dict_reset()
check(REG.set_gpu_util("g9", 0.6, 30) == true,
   "G9 real: set_gpu_util stores an honest 60 % reading")
local u60 = REG.capacity_exclusion({ id = "g9", max_gpu_util = 60 })
eq(u60 and u60.reason or "?", "gpu_util",
   "G9 real: a fresh reading at the ceiling is full with reason gpu_util")
eq(u60 and u60.max_gpu_util, 60,
   "G9 real: and the verdict carries the declared percent")
eq(REG.capacity_state({ id = "g9", max_gpu_util = 60 }), "full",
   "G9 real: the state says the same thing the gate acts on")
dict_reset()
REG.set_gpu_util("g9", 0.599, 30)
eq(REG.capacity_state({ id = "g9", max_gpu_util = 60 }), "idle",
   "G9 real: just below the ceiling remains selectable")
eq(REG.capacity_exclusion({ id = "g9", max_gpu_util = 60 }), nil,
   "G9 real: below the ceiling the gate answers nil")
dict_reset()
eq(REG.capacity_state({ id = "g9", max_gpu_util = 0 }), "idle",
   "G9 real: gu absent is unknown, never zero — the 0 gate stays silent")
eq(REG.capacity_exclusion({ id = "g9", max_gpu_util = 0 }), nil,
   "G9 real: an unknown reading cannot exclude anyone")
REG.set_gpu_util("g9", 0.0, 30)
eq(REG.capacity_state({ id = "g9", max_gpu_util = 0 }), "full",
   "G9 real: max_gpu_util = 0 is the strictest legal rung (any fresh reading is full)")
local util0 = REG.capacity_exclusion({ id = "g9", max_gpu_util = 0 })
eq(util0 and util0.gpu_util, 0,
   "G9 real: the util verdict carries the fraction the gate read")
-- 双上限同触：并发先判（读序即口径，doc/caps-redesign-2026-10-06.md §2 的形状）。
dict_reset(); put_inflight("g9", 5); REG.set_gpu_util("g9", 0.99, 30)
local both = REG.capacity_exclusion({ id = "g9", max_concurrency = 5, max_gpu_util = 50 })
eq(both and both.reason or "?", "concurrency_max",
   "G9 real: with both ceilings hit the concurrency gate answers first")
-- 旧 reason 字符串退役：两个方向的判定都翻不出 "concurrency" / "power"。
dict_reset(); put_inflight("g9", 1)
local rc = REG.capacity_exclusion({ id = "g9", max_concurrency = 1 })
eq(rc and rc.reason or "?", "concurrency_max", "G9 real: no retired 'concurrency' spelling")
dict_reset(); REG.set_gpu_util("g9", 1.0, 30)
local ru = REG.capacity_exclusion({ id = "g9", max_gpu_util = 0 })
eq(ru and ru.reason or "?", "gpu_util", "G9 real: no retired 'power' spelling")
-- util_limit 归一：0 存活（cap_limit 会折掉的正是这一档），负/非数 = 没说，小数向下取整。
eq(REG.util_limit(0), 0, "G9 real: util_limit keeps the meaningful zero")
eq(REG.util_limit(-1), nil, "G9 real: a negative util ceiling is 'not said'")
eq(REG.util_limit("abc"), nil, "G9 real: non-numeric is 'not said'")
eq(REG.util_limit("40"), 40, "G9 real: a numeric string is adopted")
eq(REG.util_limit(55.9), 55, "G9 real: the percent floors to an integer")
eq(REG.util_limit(0 / 0), nil, "G9 real: NaN is 'not said'")
eq(REG.util_limit(math.huge), nil, "G9 real: inf is 'not said'")
-- cap_limit 的并发档也从没在真实现上钉过（0/负 = 不限、2.5 向下取整）。
eq(REG.cap_limit(0, true), nil, "G9 real: a 0 concurrency ceiling folds to unlimited")
eq(REG.cap_limit(2.5, true), 2, "G9 real: a fractional ceiling floors down")
eq(REG.cap_limit(-5, true), nil, "G9 real: negative is unlimited")
-- set_gpu_util 的入库口径：准入读数是硬件陈述，坏读数拒收而不是夹到 0。
dict_reset()
eq(REG.set_gpu_util("g9b", -0.1), false, "G9 real: a negative fraction is refused")
eq(REG.set_gpu_util("g9b", 0 / 0), false, "G9 real: NaN is refused, not clamped")
eq(REG.set_gpu_util("g9b", nil), false, "G9 real: nothing to store")
eq(dict_store["gu:g9b"], nil, "G9 real: refused samples leave no key behind")
eq(REG.set_gpu_util("g9b", 1.5), true, "G9 real: above-range clamps to 1.0")
eq(REG.gpu_util("g9b"), 1, "G9 real: the clamp lands on exactly one")
eq(REG.set_gpu_util("g9b", 0), true, "G9 real: 0 % is an honest reading and is stored")
eq(REG.gpu_util("g9b"), 0, "G9 real: a stored zero reads as zero, not as unknown")
REG.clear_gpu_util("g9b")
eq(REG.gpu_util("g9b"), nil, "G9 real: clear takes the sample back to unknown")
-- TTL：过期 = 没有样本 = 未知（「监控挂了只花精度不花容量」的机制本体）。
dict_reset()
check(REG.set_gpu_util("g9t", 0.9, -10) == true,
   "G9 real: stale_ttl floors even a negative window into a stored sample")
dict_store["gu:g9t"].expire = os.time() - 1
eq(REG.gpu_util("g9t"), nil, "G9 real: an expired sample is unknown again")
eq(REG.capacity_state({ id = "g9t", max_gpu_util = 10 }), "idle",
   "G9 real: an expired util sample cannot keep a worker full")
-- 红绿灯与硬门共用同一次判定：/workers 的颜色与选路不可能各说各话。
dict_reset(); put_inflight("g9s", 9)
local only_state = { REG.capacity_state({ id = "g9s", max_concurrency = 5 }) }
eq(#only_state, 1, "G9 real: capacity_state answers exactly the one value")
eq(only_state[1], "full", "G9 real: and it is the same verdict the gate used")
eq(REG.capacity_exclusion({ id = "g9s", max_concurrency = 5 }).reason,
   "concurrency_max", "G9 real: /workers colour and the gate cannot disagree")

---------------------------------------------------------------------------
-- G10 绿灯优先（doc/caps-redesign-2026-10-06.md §3）：candidates_for 在组门与
-- 绑定**之后**的数组裁剪。四种整池形状（全 idle / 混合 / 全 busy / 全 full）各自
-- 的返回数组与 why 计数。钉五条口径：有 idle 只交 idle 子集；让位数进 why.idle、
-- **不计入** why.capped；一次 counted pass 计一次 preferred-idle；全 busy 不动数组；
-- 无门（状态 nil）的候选绝不因为别人是绿的而被让出（红线 2 的镜像形状）。
---------------------------------------------------------------------------
reset(false)
A.min_concurrency, caps.wa = 4, { inflight = 0 }
B.min_concurrency, caps.wb = 4, { inflight = 1 }
U.min_concurrency, caps.wu = 4, { inflight = 2 }
local allidle, why_ai = M.candidates_for("z", nil, true)
eq(#allidle, 3, "G10 all-idle hands the policy the whole pool")
eq(why_ai and why_ai.idle, 0, "G10 all-idle bills no yield (nobody gave way)")
eq(yielded_count(), 0, "G10 and the preferred-idle counter stays untouched")
reset(false)
-- 混合：1 绿 2 黄 -> 只交绿的那台。
A.min_concurrency, A.max_concurrency, caps.wa = 4, 9, { inflight = 0 }
B.min_concurrency, B.max_concurrency, caps.wb = 4, 9, { inflight = 4 }
U.min_concurrency, U.max_concurrency, caps.wu = 4, 9, { inflight = 5 }
local mixed, why_mx = M.candidates_for("z", nil, true)
eq(urls(mixed), A.url, "G10 mixed hands the policy only the idle subset")
eq(why_mx and why_mx.idle, 2, "G10 the two yielded yellows ride why.idle")
eq(why_mx and why_mx.capped, 0, "G10 yielding is not capping: why.capped stays 0")
eq(yielded_count(), 1, "G10 one counted pass bills one preferred-idle sample")
-- 复跑（reqlog 的第二次调用）**不裁剪也不计费**：日志行要列出所有"可选"候选，
-- 而黄灯是可选的 —— 裁剪只属于 counted 的选路趟（G8 同一形状，从让位侧再钉一遍）。
eq(#M.candidates_for("z", nil), 3, "G10 the uncounted pass stays unpriced: no narrowing")
eq(yielded_count(), 1, "G10 and it bills no second preferred-idle sample")
reset(false)
-- 混合 + 一台无门：nil 状态**不是**黄灯，无门的 U 不许被挤掉。
A.min_concurrency, A.max_concurrency, caps.wa = 4, 9, { inflight = 0 }
B.min_concurrency, B.max_concurrency, caps.wb = 4, 9, { inflight = 4 }
U.max_gpu_util, caps.wu = nil, { inflight = 7 }
local mixedu, why_mu = M.candidates_for("z", nil, true)
eq(urls(mixedu), A.url .. "," .. U.url,
   "G10 an ungated worker is never stepped aside for a green peer")
eq(why_mu and why_mu.idle, 1, "G10 only the one real yellow yielded")
reset(false)
-- 全 busy：最闲的也已到下限，黄灯继续接到触达上限 —— 数组不许被裁。
A.min_concurrency, A.max_concurrency, caps.wa = 3, 9, { inflight = 3 }
B.min_concurrency, B.max_concurrency, caps.wb = 3, 9, { inflight = 4 }
U.min_concurrency, U.max_concurrency, caps.wu = 3, 9, { inflight = 5 }
local allbusy, why_bz = M.candidates_for("z", nil, true)
eq(#allbusy, 3, "G10 all-busy passes the whole array through untouched")
eq(why_bz and why_bz.idle, 0, "G10 a pool with no green bills no yield")
eq(yielded_count(), 0, "G10 and no preferred-idle sample either")
reset(false)
-- 全 full：硬门先清空数组；capped=3、idle=0（到顶不是让位），429 分支的输入形状。
A.max_concurrency, caps.wa = 2, { inflight = 2 }
B.max_concurrency, caps.wb = 1, { inflight = 1 }
U.max_gpu_util, caps.wu = 50, { util = 0.95 }
local allfull, why_ff = M.candidates_for("z", nil, true)
eq(#allfull, 0, "G10 all-full empties the array for policy:select")
eq(why_ff and why_ff.capped, 3, "G10 every one of them counted as capped")
eq(why_ff and why_ff.idle, 0, "G10 full is never a yield: why.idle stays 0")
eq(counted("concurrency_max"), 2, "G10 the concurrency reason bills its two")
eq(counted("gpu_util"), 1, "G10 the util reason bills its one")
eq(yielded_count(), 0, "G10 an all-full pass bills no preferred-idle sample")

print(string.format("=== %d checks, %d failed ===", n, bad))
os.exit(bad == 0 and 0 or 1)
