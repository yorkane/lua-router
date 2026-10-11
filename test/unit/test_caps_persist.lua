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
-- 第 8 段（池侧 PUT 越界）跑**真 registry**，需要 keys.shdict 的那两块 dict。
-- shdict 惰性解析后 memo，整份文件共用同一张表，reset 走 flush_all 而不是换表。
shared.lr_workers = new_shdict()
shared.lr_locks = new_shdict()

local RE_GSUB = { ["^\\s+"] = "^%s+", ["\\s+$"] = "%s+$" }
-- registry/url.lua 的 normalize_url 用 "/+$"（gsub 锚点为 /+$/）剥尾斜杠。
local RE_GSUB = { ["^\\s+"] = "^%s+", ["\\s+$"] = "%s+$", ["/+$/"] = "/+$" }
local RE_FIND = { ["^\\d+$"] = "^%d+$", ["[,;\\n]+"] = "[,;%c]+" }
-- registry 的 normalize_url / parse_worker_id 走 ngx.re.match（第 8 段用到）。
-- 与 RE_FIND 同一纪律：没登记的模式记进 unmapped，收尾必须为空，桩不许悄悄骗人。
local RE_MATCH = {
    ["^https?://"] = "^https?://",
    ["^https?://[^/]+"] = "^https?://[^/]+",
    ["^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"] =
        "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$",
}
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
        match = function(subject, pattern, _o, ctx)
            local mapped = RE_MATCH[pattern]
            if not mapped then
                unmapped[#unmapped + 1] = "match:" .. tostring(pattern)
                return nil
            end
            local from, to = string.find(subject, mapped, 1)
            if not from then return nil end
            if ctx then ctx.pos = to + 1 end
            return { [0] = subject:sub(from, to) }
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

-- 真 registry 的两颗外部依赖桩（第 8 段跑真 facade 用）：resty.lock 经
-- resty.core 要 authz 基座的 ngx.config，真 sha224 经 resty.openssl 拉
-- ngx/base64 撞同一堵墙。锁的互斥与哈希的真值都不是本文件钉的东西（id 只
-- 用来取回自己写的记录），preload 桩让 registry 域在纯 Lua 口径下可加载。
package.preload["resty.lock"] = function()
    return { new = function()
        return { lock = function() return true end, unlock = function() return true end }
    end }
end
package.preload["resty.openssl.digest"] = function()
    local md = {}
    function md.new()
        local acc = ""
        local obj = {}
        function obj:update(s) acc = acc .. tostring(s); return true end
        function obj:final()
            local hex = {}
            for i = 1, 28 do
                local b = (string.byte(acc, (i % #acc) + 1) * (i * 37 + 11)) % 256
                hex[#hex + 1] = string.format("%02x", b)
            end
            return table.concat(hex)
        end
        return obj
    end
    return md
end

-- 判据本体 = **真** registry/loads 的 cap_range_refusal / cap_range_wording
-- （config_store/upstreams.lua 的 cap_rule 注释点名的就是这个预加载形状：
-- resty.lock/digest 走 preload 桩，真模块在纯 Lua 口径下可加载）。
-- 桩位走 package.loaded：6b 的声明层门与第 8 段的池侧门因此共用同一份判据，
-- 本文件不复制任何规则 —— 复制一份范围表就是任务书禁止的「另造规则」。
-- facade 预登记后 require 它，keys/loads 的 R 晚绑定与生产同一条路径。
local ok_registry, registry_real = pcall(require, "resty.luarouter.registry")
local REG_LOADS
if ok_registry then
    REG_LOADS = package.loaded["resty.luarouter.registry.loads"]
end

-- 兜底桩（只在真模块加载不了的环境生效）：按 registry/loads 的派生形状接 ——
-- 先过本文件既有的 cap_limit / util_limit 归一器，再对档取范围。6b 的断言在
-- 这份兜底判据上同样成立（判别性反证 B 就是把它换成恒 nil 来验 6b 咬的是判据）。
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

-- 判据本体（桩位）。真 registry/loads 可用时就用**真**的那份（上面预加载的
-- REG_LOADS）；加载不了的环境才用这份兜底，且按 registry/loads 的派生形状接：
-- 先过上面这两个归一器，再对档取范围，与真模块同一结构。
--
-- 为什么桩必须带 cap_range_refusal：config_store/upstreams.lua 的 cap_rule()
-- 取的是 package.loaded 上的**子模块** resty.luarouter.registry.loads（刻意不
-- 走 facade，因为 facade 在纯 Lua 单测里被换成内存池桩）。子模块缺席时
-- cap_rule() 返回 nil，cap_tiers_said 的 "rule and rule.cap_range_refusal(...)"
-- 静默跳过校验，越界值于是走进快照，这就是本次 6b 红 8 条的成因。缺它不是
-- 「少测一点」，是声明层的门在单测口径下根本不存在，别当兼容删掉。
local MIN_CONCURRENCY_LIMIT, MAX_CONCURRENCY_LIMIT, MAX_GPU_UTIL_LIMIT = 31, 32, 100
local function fallback_wording(field)
    if field == "max_gpu_util" then
        return string.format("must be a whole percentage between 0 and %d", MAX_GPU_UTIL_LIMIT)
    end
    if field == "min_concurrency" then
        return string.format("must be an integer between 1 and %d", MIN_CONCURRENCY_LIMIT)
    end
    return string.format("must be at most %d", MAX_CONCURRENCY_LIMIT)
end
local function fallback_refusal(field, value)
    if field == "max_gpu_util" then
        local number = tonumber(value)
        if number == nil or number ~= number
            or number == math.huge or number == -math.huge then
            return nil   -- not a reading: util_limit folds it to unlimited
        end
        if number < 0 then
            return nil   -- this tier's clearing spelling
        end
        if number > MAX_GPU_UTIL_LIMIT or math.floor(number) ~= number then
            return fallback_wording(field)
        end
        return nil
    end
    if field ~= "min_concurrency" and field ~= "max_concurrency" then
        return nil   -- not a ceiling: callers may hand the whole field list in
    end
    local cap = cap_limit(value, true)
    if cap == nil then
        return nil   -- <=0 / NaN / inf / non-numeric = the rung is cleared
    end
    if field == "min_concurrency" then
        if cap ~= tonumber(value) or cap < 1 or cap > MIN_CONCURRENCY_LIMIT then
            return fallback_wording(field)
        end
        return nil
    end
    if cap > MAX_CONCURRENCY_LIMIT then
        return fallback_wording(field)
    end
    return nil
end
local RULEBOOK = REG_LOADS
if type(RULEBOOK) ~= "table" or type(RULEBOOK.cap_range_refusal) ~= "function"
    or type(RULEBOOK.cap_range_wording) ~= "function" then
    RULEBOOK = {
        cap_limit = cap_limit, util_limit = util_limit,
        cap_range_refusal = fallback_refusal, cap_range_wording = fallback_wording,
    }
end
-- 判别性反证 B 的注入口（一次性、显式开）：LR_CAP_RULE_VOID=1 把桩位判据换成
-- 「恒说无话」的形状。6b 与第 8 段必须因此变红 —— 绿了就说明这些断言其实不
-- 经过判据（比如门在别处、或断言测的是复制的规则）。生产路径不读本开关。
if os.getenv("LR_CAP_RULE_VOID") == "1" then
    RULEBOOK = {
        cap_limit = cap_limit, util_limit = util_limit,
        cap_range_refusal = function() return nil end,
        cap_range_wording = function(field) return fallback_wording(field) end,
    }
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
    -- 桩的**子模块**桩位：facade 被换成内存池桩后，upstreams.lua 的 cap_rule()
    -- 仍按名字取 resty.luarouter.registry.loads（真实路径与桩路径同一个键）。
    -- 这里必须一并登记判据，否则 cap_rule() 在换桩之后 require 不到判据 →
    -- 声明层的门静默消失（本次 6b 红 8 条的成因）。登记发生在
    -- _reset_pool_module_caches 之前：reset 会连带清掉 upstreams 里
    -- cap_rulebook 的 memo，下一句 cap_tiers_said 重新解析到这份判据。
    package.loaded["resty.luarouter.registry.loads"] = RULEBOOK
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
-- 6b. 已存在的镜像行 + 越界 caps（21.k:8802 实测：整份持久配置静默失效）
--
-- 复现的形状：该 url 已有一条镜像行（min=2/max=10），操作员在服务池弹窗里 PUT
-- /workers/{id} {"max_concurrency":77} —— 池侧 registry 没有 32 的上限（那是运行态
-- 读数，原样接受），于是镜像把 77 写进快照；cfg_from_document 校验的是**整份**文档，
-- 一个越界档就让它把 model_configs / virtual_models / policy 一起退回 env 缺省，
-- 每请求刷 "persisted config invalid ... falling back to env defaults"，而且
-- POST /config/upstreams {"entries":[]} 清不掉（current() 已经在读 env 那份）。
-- 判别性：旧实现在「快照里没有越界值」「整份文档仍可读」两条同时红。
--------------------------------------------------------------------------
reset_state()
use_registry(make_registry_stub())
pool_put({ id = "w-" .. A, url = A, model_id = "alpha", priority = 50, cost = 1.0,
           labels = {}, disable_health_check = false })
-- 一份"整份配置"：模型卡片 + 虚拟入口 + 全局策略。越界镜像的爆炸半径就是这三样。
store.apply_model_config({ model = "alpha", ctx = 8192 })
store.apply_profiles({ { model = "entry-a", target = "alpha" } })
store.apply_policy({ policy = "round_robin" })

--- 盘上字节 = 容器重启后唯一会被读回的那一层，直接按文本查越界值。
local function disk_text()
    local f = io.open(CONFIG_PATH, "r")
    if not f then return "" end
    local out = f:read("*a")
    f:close()
    return out
end
-- nil 安全取值：越界镜像在旧实现下的形状是"盘上出现 77 + current() 整体退回 env 缺省"
-- （负证跑过：旧 mutators 会在这里取到 nil 而崩在半路）。崩了看不出是谁的错，所以这几处
-- 走 nil 安全的读法，让那个形状如实报成 FAIL 清单。
local function row_field(url, field)
    local item = row_for(url)
    return item and item[field]
end

local seeded, seed_err = store.apply_upstream_caps(A, {
    min_concurrency = 2, max_concurrency = 10, max_gpu_util = 60,
})
eq(seed_err, nil, "(6b) premise: the in-range mirror row was accepted", tostring(seed_err))
eq(type(seeded), "table", "(6b) premise: the mirror answered a reconcile summary")
check(type(store.current().policy) == "string", "(6b) premise: the document carries a policy")

-- 1) 越界档写进已存在行：拒（与新建分支同形状的错误），且**整批不落盘**
local poison, poison_err = store.apply_upstream_caps(A, { max_concurrency = 77 })
eq(poison, nil, "(6b) an out-of-range ceiling onto an existing row is refused")
check(type(poison_err) == "string"
    and poison_err:find("max_concurrency must be at most 32", 1, true) ~= nil,
    "(6b) the refusal carries the shared validator wording", tostring(poison_err))
check(disk_text():find('"max_concurrency":77') == nil,
    "(6b) the poisoned value never reached the snapshot",
    disk_text():match('"max_concurrency":[0-9]+') or "no ceiling on disk")
eq(row_field(A, "max_concurrency"), 10, "(6b) the row keeps the ceiling it had")
eq(row_field(A, "min_concurrency"), 2, "(6b) the tier the batch did not name is untouched")
eq(row_field(A, "max_gpu_util"), 60, "(6b) nor is any other tier")

-- 2) 主判别条：毒行不落盘之后，current() 仍读得到整份文档（不触发 env 兜底）
local doc = roundtrip()
eq(doc.policy, "round_robin", "(6b) the refused mirror did not take the global policy with it")
check(next(doc.model_configs) ~= nil, "(6b) the model card is still readable")
check(next(doc.virtual_profiles) ~= nil, "(6b) the virtual entry is still readable")
check(disk_text():find("round_robin", 1, true) ~= nil,
    "(6b) the policy is still on disk, not merely in this process")

-- 3) 同一批混合合法档 + 越界档：整批拒绝，合法的也不许悄悄落盘
local mixed, mixed_err = store.apply_upstream_caps(A, {
    max_concurrency = 8, max_gpu_util = 101,
})
eq(mixed, nil, "(6b) a batch with one out-of-range tier is refused as a whole")
check(type(mixed_err) == "string"
    and mixed_err:find("max_gpu_util must be a whole percentage", 1, true) ~= nil,
    "(6b) naming the tier that broke the batch", tostring(mixed_err))
eq(row_field(A, "max_concurrency"), 10,
    "(6b) the legal tier of a refused batch did not land either")
check(disk_text():find('"max_concurrency":8') == nil,
    "(6b) ... nor on disk", disk_text():match('"max_concurrency":[0-9]+') or "none")
eq(row_field(A, "max_gpu_util"), 60, "(6b) the utilisation ceiling is untouched by the refused batch")

-- 4) 正向：范围内值照常镜像（32 是文档能承载的上界）
local raised, raised_err = store.apply_upstream_caps(A, { max_concurrency = 32 })
eq(raised_err, nil, "(6b) an in-range ceiling onto an existing row still mirrors",
    tostring(raised_err))
eq(type(raised), "table", "(6b) the accepted mirror answers a reconcile summary")
eq(row_field(A, "max_concurrency"), 32, "(6b) the ceiling was written")
check(disk_text():find('"max_concurrency":32') ~= nil, "(6b) and it reached the snapshot")
eq(pool_row(A).max_concurrency, 32, "(6b) reconcile projected it onto the pool row")
local doc2 = roundtrip()
eq(doc2.policy, "round_robin", "(6b) the accepted mirror kept the rest of the document intact")

-- 5) 第二个同形状毒口：**只点名一档**的写与行内未点名的另一档组成 min>=max
--    （旧实现同样绕过校验 → 整份文档失效），必须一起挡住。
reset_state()
use_registry(make_registry_stub())
pool_put({ id = "w-" .. A, url = A, model_id = "alpha", priority = 50, cost = 1.0,
           labels = {}, disable_health_check = false })
store.apply_policy({ policy = "round_robin" })
store.apply_upstream_caps(A, { min_concurrency = 6, max_concurrency = 10 })
local inverted, invert_err = store.apply_upstream_caps(A, { max_concurrency = 4 })
eq(inverted, nil, "(6b) a partial write that inverts the row's floor/ceiling is refused")
check(type(invert_err) == "string" and invert_err:find("must be less than max_concurrency", 1, true) ~= nil,
    "(6b) with the cross-tier wording", tostring(invert_err))
eq(row_field(A, "max_concurrency"), 10, "(6b) the ceiling the refused batch wanted is not on the row")
eq(row_field(A, "min_concurrency"), 6, "(6b) and the floor it never mentioned is untouched")
eq(roundtrip().policy, "round_robin", "(6b) the document still reads back whole")

-- 6) 反向护栏：这批**点名清除**的档按清除算，不许拿行内旧值来判冲突
--    （min=0 + max=6 是合法的"摘掉绿档、留红档"，不是 min>=max）
local cleared, clear_err = store.apply_upstream_caps(A, { min_concurrency = 0, max_concurrency = 6 })
eq(clear_err, nil, "(6b) a batch that clears one tier is judged on what the row will say",
    tostring(clear_err))
eq(row_field(A, "min_concurrency"), nil, "(6b) the cleared floor is absent, not an explicit 0")
eq(row_field(A, "max_concurrency"), 6, "(6b) the ceiling named by the same batch landed")

-- 7) 上界成对出现仍受跨档规则管（31/31 拒，31/32 收）
local pair, pair_err = store.apply_upstream_caps(A, { min_concurrency = 31, max_concurrency = 31 })
eq(pair, nil, "(6b) min == max is refused on the mirror path too")
check(type(pair_err) == "string", "(6b) with an error", tostring(pair_err))
local pair2, pair2_err = store.apply_upstream_caps(A, { min_concurrency = 31, max_concurrency = 32 })
eq(pair2_err, nil, "(6b) the highest legal pair mirrors", tostring(pair2_err))
eq(row_field(A, "min_concurrency"), 31, "(6b) floor 31")
eq(row_field(A, "max_concurrency"), 32, "(6b) ceiling 32")

--------------------------------------------------------------------------
-- 8. 池侧 PUT /workers/{id} 的越界拒绝（doc/cap-put-ceiling-task.md）
--
-- 6b 钉的是声明层（cap_tiers_said），这一段钉**门本身**：PUT 的执行方是
-- registry.update（registry/discovery.lua 的 UPDATE_NUMBER_FIELDS 循环）。
-- 21.k:8802 实测的缺口就在这儿：池侧只 tonumber，于是越界的 77 走进活记录与
-- /workers 回显、死在进快照的路上，每条请求刷一句
-- "the ceiling is live now but will not survive a restart"。声明层与池侧现在
-- 调同一份判据（registry/loads.cap_range_refusal），两侧必须答得一模一样。
--
-- 这一段跑**真 registry**，不跑内存池桩：要钉的是 discovery.lua 里那处
-- cap_range_refusal 调用，桩照抄判据的话判别性反证（回退产品代码）就不会红。
-- 真 facade 在段首交还 package.loaded，段尾换回桩。外部依赖只剩两颗 preload
-- 桩（resty.lock 的互斥、sha224 的真值都不是本段钉的东西）。
--------------------------------------------------------------------------
check(ok_registry and registry_real ~= nil,
    "(8) premise: the real registry domain loads in the pure-Lua caliber")
if registry_real ~= nil then
    reset_state(false)          -- 不换桩：真 facade 留在 package.loaded 上
    shared.lr_workers:flush_all()
    local registry = registry_real
    local added, add_err = registry.add({
        url = A, model_id = "alpha",
        max_concurrency = 8, min_concurrency = 2, max_gpu_util = 60,
    }, {})
    eq(add_err, nil, "(8) premise: the real registry accepted an in-range record",
        tostring(add_err))
    eq(type(added), "table", "(8) premise: add answered the accepted result")
    local POOL_ID = type(added) == "table" and added.id
    local function rec_field(field)
        local rec = registry.record(POOL_ID)
        return rec and rec[field]
    end
    eq(rec_field("max_concurrency"), 8, "(8) premise: the record carries the seeded ceiling")

    -- 1) 越界并发档：当场拒，kind 是 validation（control.lua 按这个 kind 映射 400）
    local refused, refuse_err, refuse_kind = registry.update(POOL_ID,
        { max_concurrency = 77 })
    eq(refused, nil, "(8) PUT max_concurrency=77 is refused at the pool doorway")
    check(type(refuse_err) == "string"
        and refuse_err:find("'max_concurrency' must be at most 32", 1, true) ~= nil,
        "(8) with the shared rulebook's wording", tostring(refuse_err))
    eq(refuse_kind, "validation",
        "(8) as a validation refusal: the kind control.lua maps onto 400")
    eq(rec_field("max_concurrency"), 8,
        "(8) the record keeps the ceiling it had: the value never entered it")

    -- 2) 另两档同口径（声明层怎么答，门就怎么答）
    local u101, e101, k101 = registry.update(POOL_ID, { max_gpu_util = 101 })
    eq(u101, nil, "(8) PUT max_gpu_util=101 is refused too")
    check(type(e101) == "string"
        and e101:find("'max_gpu_util' must be a whole percentage between 0 and 100", 1, true) ~= nil,
        "(8) naming the utilisation tier's range", tostring(e101))
    eq(k101, "validation", "(8) same kind")
    local umin, emin, kmin = registry.update(POOL_ID, { min_concurrency = 33 })
    eq(umin, nil, "(8) PUT min_concurrency=33 is refused (the floor tops out one below the ceiling)")
    check(type(emin) == "string"
        and emin:find("'min_concurrency' must be an integer between 1 and 31", 1, true) ~= nil,
        "(8) naming the floor's range", tostring(emin))
    eq(kmin, "validation", "(8) same kind")
    -- 分数绿档是笔误（cap_limit 会 floor，读数面看不出被抹掉的那一位）
    local uhalf, ehalf = registry.update(POOL_ID, { min_concurrency = 1.5 })
    eq(uhalf, nil, "(8) a fractional min_concurrency is refused as a typo")
    check(type(ehalf) == "string", "(8) with an error", tostring(ehalf))
    eq(rec_field("min_concurrency"), 2, "(8) the floor on the record is untouched by all of it")
    eq(rec_field("max_gpu_util"), 60, "(8) so is the utilisation ceiling")

    -- 3) 一批里有一档越界：整批拒，合法的同伴档位也不许悄悄落盘
    local mixed, mixed_err, mixed_kind = registry.update(POOL_ID,
        { max_concurrency = 8, max_gpu_util = 101 })
    eq(mixed, nil, "(8) a batch with one out-of-range tier is refused as a whole")
    eq(mixed_kind, "validation", "(8) with the validation kind")
    check(type(mixed_err) == "string"
        and mixed_err:find("max_gpu_util", 1, true) ~= nil,
        "(8) and names the tier that broke the batch", tostring(mixed_err))
    eq(rec_field("max_concurrency"), 8, "(8) the refused batch wrote nothing")

    -- 4) 正向：三档的合法边界走同一条 202 路径（门不许比文档还窄）
    local ok_all, ok_err = registry.update(POOL_ID,
        { min_concurrency = 31, max_concurrency = 32, max_gpu_util = 100 })
    eq(ok_err, nil, "(8) the legal boundary 31/32/100 is accepted", tostring(ok_err))
    eq(type(ok_all), "table", "(8) the accepted update answers {worker_id,url}")
    eq(rec_field("min_concurrency"), 31, "(8) floor applied")
    eq(rec_field("max_concurrency"), 32, "(8) ceiling applied")
    eq(rec_field("max_gpu_util"), 100, "(8) utilisation applied")
    -- 分数红档照旧合法：cap_limit 的 floor 语义（创建路径一直说 2.5 是个合法的 2）
    local ok_frac, frac_err = registry.update(POOL_ID, { max_concurrency = 2.5 })
    eq(frac_err, nil, "(8) a fractional max_concurrency stays legal on the pool side",
        tostring(frac_err))
    eq(rec_field("max_concurrency"), 2.5, "(8) stored raw, read floored")
    eq(registry.cap_limit(rec_field("max_concurrency"), true), 2,
        "(8) and the reader floors it to 2, as it always did")

    -- 5) 非 cap 字段不受影响：整张数字字段表都过门，陌生名字答案是「无话」
    local knobs, knobs_err = registry.update(POOL_ID,
        { priority = 999, cost = 1.5, health_check_timeout_secs = 9999 })
    eq(knobs_err, nil, "(8) priority / cost / the health knobs are not range-gated",
        tostring(knobs_err))
    eq(rec_field("priority"), 999, "(8) priority applied as written")
    eq(rec_field("cost"), 1.5, "(8) cost applied as written")
    eq(rec_field("health_check_timeout_secs"), 9999, "(8) and the health knob too")

    -- 6) 清除哨兵保持既有语义（自愈的 clear 写入依赖这条 202 路径）
    local cleared, clear_err = registry.update(POOL_ID, { max_concurrency = 0 })
    eq(clear_err, nil, "(8) PUT 0 clears a concurrency rung (202 path intact)",
        tostring(clear_err))
    eq(rec_field("max_concurrency"), 0, "(8) stored as the sentinel the readers fold")
    eq(registry.cap_limit(rec_field("max_concurrency")), nil,
        "(8) and cap_limit reads it back as unlimited")
    local util_clear, util_err = registry.update(POOL_ID, { max_gpu_util = -1 })
    eq(util_err, nil, "(8) PUT -1 clears the utilisation rung (its zero is a gate, not an absence)",
        tostring(util_err))
    eq(rec_field("max_gpu_util"), -1, "(8) stored as the negative sentinel")
    eq(registry.util_limit(rec_field("max_gpu_util")), nil,
        "(8) and util_limit reads it back as unlimited")
    local util_zero, util_zero_err = registry.update(POOL_ID, { max_gpu_util = 0 })
    eq(util_zero_err, nil, "(8) util 0 is the strictest legal rung, not a refusal",
        tostring(util_zero_err))
    eq(rec_field("max_gpu_util"), 0, "(8) and it is stored as 0")

    -- 7) 全池扫尾：任何一条记录都不带越界读数（回显里不许出现 77 这件事的池侧形式）
    local leaked = nil
    for _, record in ipairs(registry.records()) do
        local cap = registry.cap_limit(record.max_concurrency)
        local floor = registry.cap_limit(record.min_concurrency)
        local util = registry.util_limit(record.max_gpu_util)
        if (cap ~= nil and cap > 32) or (floor ~= nil and (floor < 1 or floor > 31))
            or (util ~= nil and (util < 0 or util > 100)) then
            leaked = record.id
        end
    end
    eq(leaked, nil, "(8) no record in the pool carries an out-of-range reading")

    -- 段尾：把桩交还 package.loaded，后面的收尾与所有前段保持池桩口径
    use_registry(make_registry_stub())
    shared.lr_workers:flush_all()
end

--------------------------------------------------------------------------
-- 9. 收尾：未映射的 ngx.re 模式必须为空（否则上面的替身在骗人）
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
