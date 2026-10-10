#!/usr/bin/env luajit
-- 控制面容量上限的持久化镜像单测（用户裁定 2026-10-09，doc/gap-worker-caps.md §4）。
--
-- 钉的是这条链的四个决定：
--   1. apply_upstream_caps 的 建 / 改 / 清 / 删 四路，且**只动 caps**（身份字段一个
--      都不写进镜像行）；
--   2. 镜像行能扛住 snapshot_of -> cfg_from_document 的磁盘往返（往返会把
--      priority=50 / cost=1.0 / labels={} / disable_health_check=false /
--      api_key_state="keep" 物化到每一行上，「默认值=没说」这条判据就是为它存在的
--      —— 判据若按原始键是否存在来判，镜像行第一次落盘后就再也不认得了）；
--   3. 删 worker 清掉纯镜像行，且**不复活**：reconcile 的 add 分支对 caps-only 行
--      必须沉默（否则重启后凭这条行把删掉的 worker 建成 discovery="config"，
--      既复活又翻归属）；
--   4. protected 行不被翻成 config：镜像 + reconcile 之后该行的 discovery 不变。
--
-- 手法与 test_profiles.lua 同形状：luajit 口径、假 shdict、registry 用
-- package.loaded 注入的内存池桩，零端口，因此可与门禁并发。
--
-- 运行：
--   docker run --rm -v "$PWD":/repo:ro -w /repo +--     --entrypoint /usr/local/openresty/luajit/bin/luajit -e LUA_TEST_LIB=/repo/lualib \
--     authz:latest -e 'package.cpath="/usr/local/openresty/lualib/?.so;"..package.path
--         package.path="/repo/lualib/?.lua;"..package.path
--         dofile("/repo/test/unit/test_caps_persist.lua")'
package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath
package.path = (os.getenv("LUA_TEST_LIB") or "./lualib") .. "/?.lua;" .. package.path

local cjson = require "cjson.safe"
local NULL = cjson.null

local TAG = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
local CONFIG_PATH = "/tmp/lr-caps-persist-" .. TAG .. ".json"
local function unlink(path) os.remove(path) end

--------------------------------------------------------------------------
-- ngx / shdict 替身（config_store 用到的最小面）
--------------------------------------------------------------------------
local function new_shdict()
    local store = {}
    return {
        get = function(_, k) return store[k] end,
        set = function(_, k, v) store[k] = tostring(v); return true end,
        incr = function(_, k, delta, init)
            local cur = tonumber(store[k]) or init or 0
            cur = cur + delta
            store[k] = tostring(cur)
            return cur
        end,
        delete = function(_, k) store[k] = nil end,
        flush_all = function() store = {} end,
    }
end
local shared = { luarouter_config = new_shdict() }

local RE_GSUB = { ["^\\s+"] = "^%s+", ["\\s+$"] = "%s+$" }
local RE_FIND = { ["^\\d+$"] = "^%d+$", ["[,;\\n]+"] = "[,;%c]+" }
local unmapped = {}
local function map_re(list, pattern, where)
    local mapped = list[pattern]
    if not mapped then
        unmapped[#unmapped + 1] = where .. ":" .. tostring(pattern)
        return nil
    end
    return mapped
end

_G.ngx = {
    shared = shared,
    now = function() return os.time() end,
    time = function() return os.time() end,
    log = function() end,
    WARN = 1, ERR = 2, INFO = 3, NOTICE = 4,
    HTTP_OK = 200, HTTP_BAD_REQUEST = 400,
    ctx = {}, header = {}, status = nil,
    re = {
        gsub = function(subject, pattern, _r, _o)
            local mapped = map_re(RE_GSUB, pattern, "gsub")
            if not mapped then return subject end
            return (subject:gsub(mapped, ""))
        end,
        find = function(subject, pattern, _o, ctx)
            local mapped = map_re(RE_FIND, pattern, "find")
            if not mapped then return nil end
            local init = (ctx and ctx.pos) or 1
            local from, to = string.find(subject, mapped, init)
            if not from then return nil end
            if ctx then ctx.pos = to + 1 end
            return from, to
        end,
    },
    req = {
        read_body = function() end,
        get_body_data = function() return nil end,
        get_body_file = function() return nil end,
        get_method = function() return "POST" end,
    },
    socket = { tcp = function() return nil, "closed" end },
    unescape_uri = function(s) return s end,
}
_G.LMR_ENV_CACHE = { LMR_CONFIG_FILE = CONFIG_PATH }

--------------------------------------------------------------------------
-- registry 替身：url -> record 的内存池（protected 行 = discovery 非 config）
--------------------------------------------------------------------------
local pool, pool_order, calls
local function pool_reset()
    pool, pool_order = {}, {}
    calls = { add = 0, update = 0, remove = 0 }
end
pool_reset()

local function pool_put(record)
    pool[record.url] = record
    pool_order[#pool_order + 1] = record.url
end

-- 与真 registry 同口径的两个读时归一器（cap_limit 把 <=0 折成 nil，util_limit
-- 保住 0）。桩必须照抄语义：本文件断言的正是「声明层写进去的数，池侧读成什么」。
local function cap_limit(value, integer)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge or n <= 0 then return nil end
    if integer then return math.floor(n) end
    return n
end
local function util_limit(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge or n < 0 then return nil end
    return math.floor(n)
end

local function make_registry_stub()
    local stub = {}
    function stub.cap_limit(v, i) return cap_limit(v, i) end
    function stub.util_limit(v) return util_limit(v) end
    function stub.records()
        local out = {}
        for _, url in ipairs(pool_order) do
            if pool[url] then out[#out + 1] = pool[url] end
        end
        return out
    end
    function stub.add(req)
        calls.add = calls.add + 1
        if type(req) ~= "table" or type(req.url) ~= "string" or req.url == "" then
            return nil, "url is required", "validation"
        end
        if pool[req.url] then
            return nil, string.format("Worker %s already exists", req.url), "validation"
        end
        pool[req.url] = {
            id = "w-" .. req.url, url = req.url,
            model_id = req.model_id or "unknown",
            priority = tonumber(req.priority) or 50,
            cost = tonumber(req.cost) or 1.0,
            labels = req.labels or {},
            disable_health_check = (req.disable_health_check and true) or false,
            -- 上限按真 records.add 的口径存在记录上（只存可用读数）。
            max_concurrency = cap_limit(rawget(req, "max_concurrency"), true),
            min_concurrency = cap_limit(rawget(req, "min_concurrency"), true),
            max_gpu_util = util_limit(rawget(req, "max_gpu_util")),
            discovery = req.discovery,
        }
        pool_order[#pool_order + 1] = req.url
        return { id = "w-" .. req.url, url = req.url, status = "accepted" }
    end
    function stub.update(id, patch)
        calls.update = calls.update + 1
        local rec
        for _, r in pairs(pool) do if r.id == id then rec = r break end end
        if not rec then return nil, "Worker " .. tostring(id) .. " not found", "not_found" end
        if type(patch) ~= "table" then return nil, "must be an object", "validation" end
        -- registry.update 的那道身份门照抄：非 config 行不认 model_id / models。
        if rec.discovery == "config" then
            if type(patch.model_id) == "string" and patch.model_id ~= "" then
                rec.model_id = patch.model_id
            end
        end
        if patch.priority ~= nil then rec.priority = tonumber(patch.priority) end
        if patch.cost ~= nil then rec.cost = tonumber(patch.cost) end
        for _, field in ipairs({ "max_concurrency", "min_concurrency" }) do
            if patch[field] ~= nil then rec[field] = cap_limit(patch[field], true) end
        end
        if patch.max_gpu_util ~= nil then rec.max_gpu_util = util_limit(patch.max_gpu_util) end
        return { id = rec.id, url = rec.url }
    end
    function stub.remove(id)
        calls.remove = calls.remove + 1
        for _, r in pairs(pool) do
            if r.id == id then
                pool[r.url] = nil
                for i, url in ipairs(pool_order) do
                    if url == r.url then table.remove(pool_order, i) break end
                end
                return { worker_id = id, url = r.url }
            end
        end
        return nil, "Worker " .. tostring(id) .. " not found"
    end
    function stub.worker_id_for_url(url) return "w-" .. tostring(url) end
    function stub.normalize_url(url) return url end
    return stub
end

local store
local function use_registry(mod)
    package.loaded["resty.luarouter.registry"] = mod
    store = require "resty.luarouter.config_store"
    store._reset_pool_module_caches()
end

-- 判据本体：本文件既用它做断言，也借它确认「镜像行的认得」这条判据没被绕开。
-- 先加载 facade：子模块回指 config_store 需要它已预登记，否则直接 require 子模块
-- 会撞上循环加载。位置也必须在第一段之前（luajit 的 local 是位置敏感的）。
require "resty.luarouter.config_store"
local CS_UP = require "resty.luarouter.config_store.upstreams"

--------------------------------------------------------------------------
-- 断言框架
--------------------------------------------------------------------------
local passed, failed = 0, {}
local function check(cond, name, detail)
    if cond then
        passed = passed + 1
    else
        failed[#failed + 1] = name .. (detail and (" -> " .. tostring(detail)) or "")
    end
end
local function eq(actual, expect, name)
    check(actual == expect, name,
        (actual ~= expect) and (tostring(actual) .. " ~= " .. tostring(expect)) or nil)
end

local function reset_state(with_pool)
    _G.ngx = _G.ngx
    shared.luarouter_config:flush_all()
    unlink(CONFIG_PATH)
    _G.LMR_ENV_CACHE = { LMR_CONFIG_FILE = CONFIG_PATH }
    store = require "resty.luarouter.config_store"
    store._reset_pool_module_caches()
    pool_reset()
    if with_pool ~= false then use_registry(make_registry_stub()) end
end

local function row_for(url)
    for _, item in ipairs(store.current().upstreams or {}) do
        if item.url == url then return item end
    end
    return nil
end
local function pool_row(url) return pool[url] end

local A = "http://pool-a.invalid:8080"
local B = "http://pool-b.invalid:9090"

--- 磁盘往返 = 容器重启后唯一能依赖的那一层。write_snapshot 已经把整份快照落进
--- LMR_CONFIG_FILE，所以「清 shdict + 清进程内 memo」之后再读，走的就是
--- 磁盘 -> cfg_from_document 这条通道本身（snapshot_of 的物化因此必然经过）。
local function roundtrip()
    shared.luarouter_config:flush_all()
    store._reset_pool_module_caches()  -- 含 _file_cache，逼下一次 current() 读盘
    local doc = store.current()
    return doc
end

--------------------------------------------------------------------------
-- 1. 建：给一条完全没有声明的 protected 行镜像三档上限
--------------------------------------------------------------------------
reset_state()
use_registry(make_registry_stub())
-- protected 行（bootstrap 播种的形状：discovery 为 nil，不带任何上限）
pool_put({ id = "w-" .. A, url = A, model_id = "alpha", priority = 50, cost = 1.0,
           labels = {}, disable_health_check = false })
eq(store.current().upstreams and #store.current().upstreams or 0, 0,
    "premise: the declaration layer knows nothing yet")

local summary, err = store.apply_upstream_caps(A, { max_concurrency = 2, max_gpu_util = 60 })
eq(err, nil, "(1) mirroring caps onto an unknown url succeeds")
eq(type(summary), "table", "(1) the mutator answers a reconcile summary")
local r1 = row_for(A)
check(r1 ~= nil, "(1) a minimal mirror row was created")
eq(r1 and r1.max_concurrency, 2, "(1) max_concurrency mirrored")
eq(r1 and r1.max_gpu_util, 60, "(1) max_gpu_util mirrored")
check(r1 ~= nil and r1.min_concurrency == nil, "(1) a tier the body did not name stays absent")
-- 只写 caps：身份字段一个都不凭空长出（reconcile 的 else 分支因此只贴 caps）
eq(r1 and r1.model_id, nil, "(1) no model_id is invented")
-- 落盘一次之后 snapshot_of 会把默认值**物化**到每一行上（priority=50 / cost=1.0 /
-- labels={} / disable_health_check=false），所以「镜像行不碰身份」的正确说法不是
-- 「这些键不存在」，而是「这些键只能是默认值」—— 判据 caps_only_row 正是按这个
-- 口径写的，下面四条把两边的约定同时钉住。
eq(r1 and tonumber(r1.priority), 50, "(1) priority holds only the default (no operator claim)")
eq(r1 and tonumber(r1.cost), 1.0, "(1) cost holds only the default")
eq(r1 and (r1.labels == nil or next(r1.labels) == nil), true, "(1) no label is invented")
eq(r1 and (r1.disable_health_check == nil or r1.disable_health_check == false), true,
    "(1) disable_health_check is not turned on")
eq(r1 and r1.api_key, nil, "(1) the mirror carries no secret")
eq(r1 and r1.api_key_stored, nil, "(1) the mirror carries no stored secret")
eq(r1 and CS_UP.caps_only_row(r1), true, "(1) the live row is a pure caps mirror")
-- 投影：protected 行拿到了上限，且归属没被翻
eq(pool_row(A).max_concurrency, 2, "(1) reconcile projected the ceiling onto the pool row")
eq(pool_row(A).max_gpu_util, 60, "(1) reconcile projected the utilisation ceiling")
eq(pool_row(A).discovery, nil, "(1) the protected row was NOT flipped to config")
eq(pool_row(A).model_id, "alpha", "(1) the engine-reported identity survived the projection")

-- 幂等：同一组上限再镜像一次，声明层不 fork 行、池侧一次写都不多（reconcile 两侧
-- 都先过归一器，"声明的 2" 对 "池里的 2" 不是漂移）
local before_updates = calls.update
store.apply_upstream_caps(A, { max_concurrency = 2, max_gpu_util = 60 })
eq(calls.update, before_updates, "(1) re-mirroring the same ceilings writes nothing to the pool")
eq(#store.current().upstreams, 1, "(1) re-mirroring does not fork a second row")

-- 另一种书写法（大小写 / 尾斜杠）落进同一行：不产生第二条镜像
store.apply_upstream_caps("http://POOL-A.invalid:8080/", { max_concurrency = 2 })
eq(#store.current().upstreams, 1, "(1) a differently spelled url is the same mirror row")

--------------------------------------------------------------------------
-- 2. 改 / 清：逐档改写，清除用「该档的 unlimited 拼法」
--------------------------------------------------------------------------
store.apply_upstream_caps(A, { max_concurrency = 5 })
eq(row_for(A).max_concurrency, 5, "(2) a ceiling update overwrites the tier")
eq(row_for(A).max_gpu_util, 60, "(2) the tier that was not named keeps its value")
eq(pool_row(A).max_concurrency, 5, "(2) the updated ceiling reached the pool row")

-- 并发档 <=0 = unlimited = 该档不再声明（键缺席，而不是显式 0）
store.apply_upstream_caps(A, { max_concurrency = 0 })
eq(row_for(A).max_concurrency, nil, "(2) a concurrency clear removes the key (never an explicit 0)")
check(row_for(A).max_gpu_util == 60, "(2) the clear did not touch the utilisation tier")
check(row_for(A) ~= nil, "(2) the row lives on while another tier still says a limit")
-- util 档的 0 是**结论**不是清除：极严档必须保住
store.apply_upstream_caps(A, { max_gpu_util = 0 })
eq(row_for(A).max_gpu_util, 0, "(2) max_gpu_util = 0 is stored as the strictest gate")
eq(pool_row(A).max_gpu_util, 0, "(2) the strict gate reached the pool row")
-- 负数才是 util 的清除
store.apply_upstream_caps(A, { max_gpu_util = -1 })
-- 三档全空（并发已清、min 从未写、util 刚清）→ 镜像行什么也不记得了，按设计整行消失；
eq(row_for(A), nil, "(2) a fully-cleared mirror row is dropped, not left empty")
-- 声明层的清除**只下发不清除**存量（protected 行的 caps-only 投影那条纪律，
-- doc/gap-worker-caps.md §4）：控制面那条 PUT 已经先把池里的读数清成 nil，
-- mutator 自己不碰记录 —— 于是「当场摘」由 registry.update 完成，
-- 「以后不回来」由这一行的消失完成。
check(pool_row(A) ~= nil, "(2) the pool row itself is not touched by the mutator")
-- 重启的形状：url 被重新播种成裸记录 -> reconcile 无行可投影 -> 上限彻底不回来
pool[A] = nil
pool_order = {}
pool_put({ id = "w-" .. A, url = A, model_id = "alpha", priority = 50, cost = 1.0,
           labels = {}, disable_health_check = false })
store.reconcile_upstreams()
eq(pool_row(A).max_concurrency, nil, "(2) a cleared ceiling does not come back after a restart")
eq(pool_row(A).max_gpu_util, nil, "(2) nor does the cleared utilisation ceiling")
eq(pool_row(A).discovery, nil, "(2) and the re-seeded row is still protected")

-- 越界值走同一条校验（upstream_from_entry 的那份），不新造规则
local _, range_err = store.apply_upstream_caps("http://over.invalid:1", { max_concurrency = 99 })
check(range_err ~= nil, "(2) max_concurrency above the ceiling is refused by the shared validator")
local _, min_err = store.apply_upstream_caps("http://over.invalid:1", { min_concurrency = 99 })
check(min_err ~= nil, "(2) an out-of-range min_concurrency is refused too")
eq(row_for("http://over.invalid:1"), nil, "(2) a refused mirror left no row behind")

--------------------------------------------------------------------------
-- 3. 磁盘往返 + 删 worker：镜像行必须还认得、且不复活
--------------------------------------------------------------------------
reset_state()
use_registry(make_registry_stub())
pool_put({ id = "w-" .. A, url = A, model_id = "alpha", priority = 50, cost = 1.0,
           labels = {}, disable_health_check = false })
store.apply_upstream_caps(A, { max_concurrency = 3, max_gpu_util = 45 })
eq(pool_row(A).max_concurrency, 3, "(3) projected before the round-trip")

-- 落盘 -> 读回（重启前把唯一可依赖的那一层先验一遍）
local disk = roundtrip()
eq(type(disk.upstreams), "table", "(3) the mirror row reached the disk layer")
local mirrored
for _, item in ipairs(disk.upstreams) do
    if item.url == A then mirrored = item end
end
check(mirrored ~= nil, "(3) the mirror row survived the round-trip")
-- 判据的主战场：往返会把默认值物化出来，纯镜像的认得与否就看这里
check(mirrored ~= nil and tonumber(mirrored.priority) == 50,
    "(3) premise: the round-trip materialized default-shaped keys",
    cjson.encode(mirrored or {}):sub(1, 200))
check(mirrored ~= nil and mirrored.api_key_state == "keep",
    "(3) premise: the round-trip materialized api_key_state=keep")
check(CS_UP.caps_only_row(mirrored) == true,
    "(3) the post-round-trip row is still recognized as a pure caps mirror")
-- 磁盘那一层不许带出明文密钥（镜像行压根没有密钥，落盘也不许凭空出现）
check(cjson.encode(mirrored):find("sk-", 1, true) == nil
    and mirrored.api_key == nil or mirrored.api_key == NULL,
    "(3) the mirrored row carries no secret on disk", cjson.encode(mirrored):sub(1, 200))
eq(pool_row(A).discovery, nil, "(3) still protected after the round-trip")

-- 删 worker：按 delete_worker_handler 的顺序两步（先摘池记录，再清镜像）
local rm = package.loaded["resty.luarouter.registry"].remove("w-" .. A)
check(rm ~= nil, "(3) the pool row was removed")
local dropped, drop_err = store.drop_upstream_caps(A)
check(dropped == true, "(3) the pure mirror row was removed with the worker", tostring(drop_err))
eq(row_for(A), nil, "(3) no mirror row is left behind")

-- 重启（shdict 全清 = 池被重新播种成裸记录之前）：reconcile 不许把它建成 config
local r_sum = store.reconcile_upstreams()
eq(r_sum.added, 0, "(3) the deleted worker was NOT resurrected by reconcile")
eq(r_sum.removed, 0, "(3) nothing else was reclaimed")
eq(pool[A], nil, "(3) the pool has no row for the deleted worker")

-- 反向：就算镜像行还留着（探针绕过删除钩子那条路），add 分支也不许认领它
reset_state()
use_registry(make_registry_stub())
pool_put({ id = "w-" .. A, url = A, model_id = "alpha", priority = 50, cost = 1.0,
           labels = {}, disable_health_check = false })
store.apply_upstream_caps(A, { max_concurrency = 3 })
local gone = package.loaded["resty.luarouter.registry"].remove("w-" .. A)
check(gone ~= nil, "(3b) premise: the row was reaped (probe-style removal)")
local r2_sum = store.reconcile_upstreams()
eq(r2_sum.added, 0, "(3b) an orphaned mirror row does not resurrect the worker")
eq(pool[A], nil, "(3b) no config row was created for it")
-- 行回来了（compose 重新播种）→ 镜像继续生效，归属仍不归声明层
pool_put({ id = "w-" .. A, url = A, model_id = "alpha", priority = 50, cost = 1.0,
           labels = {}, disable_health_check = false })
store.reconcile_upstreams()
eq(pool_row(A) and pool_row(A).max_concurrency, 3,
    "(3b) the mirror re-arms as soon as the url is seeded again")
eq(pool_row(A).discovery, nil, "(3b) and the row stays protected")

--------------------------------------------------------------------------
-- 4. 带别的声明字段的行：删 worker 不许动它
--------------------------------------------------------------------------
reset_state()
use_registry(make_registry_stub())
store.apply_upstreams({ { url = B, model_id = "mine", max_concurrency = 4 } })
eq(pool_row(B).discovery, "config", "(4) premise: a real declaration owns the row")
package.loaded["resty.luarouter.registry"].remove("w-" .. B)
local dropped4 = store.drop_upstream_caps(B)
eq(dropped4, false, "(4) deleting the worker does not erase an operator's declaration")
check(row_for(B) ~= nil, "(4) the declared row is still there")
eq(row_for(B).model_id, "mine", "(4) with its identity intact")

-- protected 行 + 操作员在声明层写过 model_id：镜像行不算纯镜像，删 worker 保留
reset_state()
use_registry(make_registry_stub())
pool_put({ id = "w-" .. A, url = A, model_id = "alpha", priority = 50, cost = 1.0,
           labels = {}, disable_health_check = false })
store.apply_upstreams({ { url = A, model_id = "declared-name" } })
store.apply_upstream_caps(A, { max_concurrency = 7 })
eq(pool_row(A).discovery, nil, "(4) the row stays protected even with a declaration")
eq(pool_row(A).max_concurrency, 7, "(4) caps still project onto the protected row")
check(CS_UP.caps_only_row(row_for(A)) == false,
    "(4) a row with a declared model_id is not a pure mirror")

--------------------------------------------------------------------------
-- 5. CAS 冲突：持久层拒绝时 mutator 报错而不是假装成功
--------------------------------------------------------------------------
reset_state()
use_registry(make_registry_stub())
local CS_P = require "resty.luarouter.config_store.persistence"
local real_write = CS_P.write_snapshot
CS_P.write_snapshot = function() return false, "config revision conflict: stale", 9 end
local _, conflict_err = store.apply_upstream_caps(A, { max_concurrency = 2 })
CS_P.write_snapshot = real_write
check(type(conflict_err) == "string" and conflict_err:find("revision", 1, true) ~= nil,
    "(5) a refused compare-and-set surfaces as an error carrying the revision",
    tostring(conflict_err))
eq(row_for(A), nil, "(5) the refused mirror left nothing in the live document")
-- 同一入口的删除路径也照口径：拒绝时报错，不静默
store.apply_upstream_caps(A, { max_concurrency = 2 })
CS_P.write_snapshot = function() return false, "config revision conflict: stale", 9 end
local dropped5, err5 = store.drop_upstream_caps(A)
CS_P.write_snapshot = real_write
eq(dropped5, false, "(5) the drop reports the conflict too")
check(type(err5) == "string", "(5) with a message", tostring(err5))

--------------------------------------------------------------------------
-- 6. 缺省零行为变化：没镜像过的行，形状与字段一个都不许多出来
--------------------------------------------------------------------------
reset_state()
use_registry(make_registry_stub())
store.apply_upstreams({ { url = B } })
local plain = row_for(B)
local extra = {}
for _, field in ipairs(CS_UP.CAP_FIELDS) do
    if plain[field] ~= nil then extra[#extra + 1] = field end
end
eq(#extra, 0, "(6) a declaration without caps grows no cap keys", table.concat(extra, ","))
eq(pool_row(B).max_concurrency, nil, "(6) and the pool row stays uncapped")

--------------------------------------------------------------------------
-- 7. 收尾：未映射的 ngx.re 模式必须为空（否则上面的替身在骗人）
--------------------------------------------------------------------------
local seen = {}
for _, entry in ipairs(unmapped) do
    if not seen[entry] then
        seen[entry] = true
        failed[#failed + 1] = "unmapped ngx.re pattern " .. entry
    end
end
unlink(CONFIG_PATH)

print("caps_persist: " .. passed .. " passed, " .. #failed .. " failed")
if #failed > 0 then
    for i = 1, #failed do print("  FAIL " .. failed[i]) end
    os.exit(1)
end
