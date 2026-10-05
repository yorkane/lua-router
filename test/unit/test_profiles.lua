#!/usr/bin/env luajit
-- 虚拟 model profile + upstreams 配置层单测（doc/gap-virtual-models.md 第 5 节）。
--
-- 覆盖 config_store 的两条新链路：
--   1. virtual_profiles：校验（自指 / 链式 / workers / policy / effort）、旧
--      {model,target} 形状兼容、env 种子、快照与磁盘往返、热路径 readers；
--   2. upstreams：URL 规范化与去重、api_key 三态（keep/clear/set）与脱敏往返、
--      reconcile 幂等计数（added/updated/removed/skipped，由 registry stub 驱动）。
--
-- 与 test_routing_dyn.lua 同形状：luajit 口径（authz:latest）跑纯 Lua 逻辑，ngx
-- 用最小替身（re.find/gsub 只映射 config_store 用到的锚定模式，shared dict 是一张
-- 表），config_store 用真模块。registry 用 package.loaded 注入的内存池 stub，切换
-- stub / 不可用两种形态后调 _reset_pool_module_caches() 清掉惰性缓存。
--
-- 运行：
--   docker run --rm -v "$PWD:/repo:ro" -w /repo \
--     --entrypoint /usr/local/openresty/luajit/bin/luajit authz:latest \
--     -e 'package.path="/repo/lualib/?.lua;"..package.path
--         dofile("/repo/test/unit/test_profiles.lua")'
--
-- 真容器里的 HTTP 面（POST /_ui/config/upstreams 之后 /workers 出现 config 成员）
-- 由 test_lua_router.sh 的 profiles_upstreams 段与 e2e_profiles 负责。

package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath
package.path = (os.getenv("LUA_TEST_LIB") or "./lualib") .. "/?.lua;" .. package.path

local cjson = require "cjson.safe"
local NULL = cjson.null

--------------------------------------------------------------------------
-- 临时文件（容器内 /tmp 可写；仓库挂载是只读的）
--------------------------------------------------------------------------
local TAG = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
local TMP = "/tmp/lr-profiles-" .. TAG
local CONFIG_PATH = TMP .. "-config.json"
local SEED_PATH = TMP .. "-upstreams.json"
local function write_file(path, text)
    local f = io.open(path, "w")
    if not f then error("cannot write " .. path) end
    f:write(text)
    f:close()
end
local function unlink(path) os.remove(path) end

--------------------------------------------------------------------------
-- ngx 替身
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
        _dump = store,
    }
end

local shared = { luarouter_config = new_shdict() }

-- config_store 只用得到这几个 PCRE 模式，逐个显式映射。未映射的记下来在末尾断言，
-- 免得哪天 config_store 新增了 ngx.re 用法而这里静默退化。键写成普通字符串，
-- 长字符串不能当表键（[[...]] = v 是语法错误）。
local RE_GSUB = {
    ["^\\s+"] = "^%s+",
    ["\\s+$"] = "%s+$",
}
local RE_FIND = {
    ["^\\d+$"] = "^%d+$",
    ["[,;\\n]+"] = "[,;%c]+",
    ["+, ]+"] = "[+, ]+",
}
local unmapped_re = {}
local function map_re(list, pattern, where)
    local mapped = list[pattern]
    if not mapped then
        unmapped_re[#unmapped_re + 1] = where .. ":" .. tostring(pattern)
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
    ctx = {},
    header = {},
    status = nil,
    say = nil,
    exit = nil,
    re = {
        gsub = function(subject, pattern, _repl, _opts)
            local mapped = map_re(RE_GSUB, pattern, "gsub")
            if not mapped then return subject end
            return (subject:gsub(mapped, ""))
        end,
        find = function(subject, pattern, _opts, ctx)
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
}

-- capture_env 快照的替身（config_store 的 env() 先读这张表）
_G.LMR_ENV_CACHE = { LMR_CONFIG_FILE = CONFIG_PATH }

--------------------------------------------------------------------------
-- registry 替身：一张 url -> record 的内存池
--------------------------------------------------------------------------
local pool, pool_order, calls
local function pool_reset()
    pool, pool_order = {}, {}
    calls = { add = 0, update = 0, remove = 0 }
end
pool_reset()

local inject_add_fail, inject_update_fail, inject_remove_fail = nil, nil, nil
local function record_of(url) return pool[url] end
local function pool_add_manual(record)
    pool[record.url] = record
    pool_order[#pool_order + 1] = record.url
end

local function make_registry_stub()
    local stub = {}
    function stub.records()
        local out = {}
        for _, url in ipairs(pool_order) do
            if pool[url] then out[#out + 1] = pool[url] end
        end
        return out
    end
    function stub.add(req, _cfg)
        calls.add = calls.add + 1
        if inject_add_fail then return nil, inject_add_fail, "validation" end
        if type(req) ~= "table" then return nil, "invalid worker config", "validation" end
        local url = req.url
        if type(url) ~= "string" or url == "" then return nil, "url is required", "validation" end
        if pool[url] then
            return nil, string.format("Worker %s already exists", url), "validation"
        end
        pool[url] = {
            id = "w-" .. url, url = url,
            model_id = req.model_id or "unknown",
            priority = tonumber(req.priority) or 50,
            cost = tonumber(req.cost) or 1.0,
            labels = req.labels or {},
            disable_health_check = (req.disable_health_check and true) or false,
            api_key = req.api_key,
            discovery = req.discovery,
        }
        pool_order[#pool_order + 1] = url
        return { id = "w-" .. url, url = url, status = "accepted" }
    end
    function stub.update(id, patch)
        calls.update = calls.update + 1
        if inject_update_fail then return nil, inject_update_fail, "validation" end
        local rec
        for _, r in pairs(pool) do if r.id == id then rec = r break end end
        if not rec then return nil, "Worker " .. tostring(id) .. " not found", "not_found" end
        if type(patch) ~= "table" then
            return nil, "worker update must be a JSON object", "validation"
        end
        if type(patch.model_id) == "string" and patch.model_id ~= "" then
            rec.model_id = patch.model_id
        end
        if patch.priority ~= nil then rec.priority = tonumber(patch.priority) end
        if patch.cost ~= nil then rec.cost = tonumber(patch.cost) end
        if patch.disable_health_check ~= nil then
            rec.disable_health_check = (patch.disable_health_check and true) or false
        end
        if patch.labels ~= nil then rec.labels = patch.labels end
        if patch.api_key ~= nil then
            rec.api_key = (patch.api_key ~= "") and patch.api_key or false
        end
        return { id = rec.id, url = rec.url }
    end
    function stub.remove(id)
        calls.remove = calls.remove + 1
        if inject_remove_fail then return nil, inject_remove_fail end
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

local function use_registry(mod)
    package.loaded["resty.luarouter.registry"] = mod
    local config_store = require "resty.luarouter.config_store"
    config_store._reset_pool_module_caches()
end

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
local function ok(cond, name, detail) check(cond and true or false, name, detail) end

local store = require "resty.luarouter.config_store"

-- 段前清一次：shdict（config 快照 + revision）、文件/env 种子缓存、registry 惰性
-- 缓存全部归零，段与段之间不互相污染。
local function reset_state(with_pool)
    shared.luarouter_config:flush_all()
    unlink(CONFIG_PATH)
    store._reset_pool_module_caches()
    pool_reset()
    inject_add_fail, inject_update_fail, inject_remove_fail = nil, nil, nil
    if with_pool ~= false then use_registry(make_registry_stub()) end
end
local function reset_env()
    _G.LMR_ENV_CACHE = { LMR_CONFIG_FILE = CONFIG_PATH }
    reset_state(true)
end

local function find_row(rows, model)
    for _, row in ipairs(rows or {}) do
        if row.model == model then return row end
    end
    return nil
end

--------------------------------------------------------------------------
-- 1. URL 规范化（与 registry.normalize_url 同语义，config_store 本地实现）
--------------------------------------------------------------------------
reset_env()
local norm_cases = {
    { "HTTP://Host.Example.COM:8080", "http://host.example.com:8080" },
    { "http://h.example:30000/", "http://h.example:30000" },
    { "http://h.example:30000///", "http://h.example:30000" },
    { "  https://H.example:443  ", "https://h.example:443" },
    { "http://127.0.0.1:18080", "http://127.0.0.1:18080" },
    { "http://[::1]:9999", "http://[::1]:9999" },
}
for _, pair in ipairs(norm_cases) do
    local _, err = store.apply_upstreams({ { url = pair[1] } })
    eq(err, nil, "normalize accepts " .. pair[1])
    local row = store.current().upstreams[1]
    ok(row ~= nil, "normalize stored one row for " .. pair[1])
    if row then eq(row.url, pair[2], "normalized to " .. pair[2]) end
end

local bad_urls = {
    "", "   ", "ftp://pool.invalid:21", "pool.invalid:8080",
    "http://pool.invalid/path/segment", "http://user:pw@pool.invalid:80",
    "http://pool.invalid:0", "http://pool.invalid:99999",
    "http://pool.invalid:abc", "http://", "http:///x", "not a url at all",
}
for _, bad in ipairs(bad_urls) do
    local before = #store.current().upstreams
    local _, err = store.apply_upstreams({ { url = bad } })
    check(type(err) == "string", "reject url [" .. bad .. "]", err)
    eq(#store.current().upstreams, before, "rejected url did not mutate the pool")
end

local _, dup_err = store.apply_upstreams({
    { url = "http://dup.invalid:8080" },
    { url = "http://dup.invalid:8080/" },
    { url = "HTTP://DUP.invalid:8080" },
})
check(type(dup_err) == "string" and dup_err:find("duplicate upstream url", 1, true) ~= nil,
    "three spellings of one url are a duplicate", dup_err)

--------------------------------------------------------------------------
-- 2. upstreams 字段校验（256 上限 / 数字 / labels map / 数组形状）
--------------------------------------------------------------------------
reset_env()
local big = {}
for i = 1, 257 do big[i] = { url = string.format("http://cap-%d.invalid:80", i) } end
local _, cap_err = store.apply_upstreams(big)
check(type(cap_err) == "string" and cap_err:find("256", 1, true) ~= nil,
    "257 entries hit the cap", cap_err)
local exactly = {}
for i = 1, 256 do exactly[i] = { url = string.format("http://cap-%d.invalid:80", i) } end
local cap_summary, cap_err2 = store.apply_upstreams(exactly)
eq(cap_err2, nil, "exactly 256 entries are accepted")
ok(cap_summary ~= nil and cap_summary.added == 256, "256-entry reconcile adds 256",
    cap_summary and cap_summary.added)

reset_env()
local field_cases = {
    { { priority = "abc" }, "priority" },
    { { priority = {} }, "priority" },
    { { cost = "cheap" }, "cost" },
    { { model_id = 42 }, "model_id" },
    { { labels = { a = 1 } }, "labels" },
    { { labels = { "a" } }, "labels" },
    { { labels = "gpu=1" }, "labels" },
    { { disable_health_check = "yes" }, "disable_health_check" },
    { { api_key = 12 }, "api_key" },
    { { api_key_state = "maybe" }, "api_key_state" },
}
for _, case in ipairs(field_cases) do
    local entry = { url = "http://fields.invalid:8080" }
    for k, v in pairs(case[1]) do entry[k] = v end
    local _, ferr = store.apply_upstreams({ entry })
    check(type(ferr) == "string" and ferr:find(case[2], 1, true) ~= nil,
        "field rejection names " .. case[2], ferr)
end
local _, notarray = store.apply_upstreams("nope")
check(type(notarray) == "string", "a non-array upstreams list is rejected", notarray)
local _, nomanaged = store.apply_upstreams({ { model_id = "m" } })
check(type(nomanaged) == "string" and nomanaged:find("url", 1, true) ~= nil,
    "an entry without a url is rejected", nomanaged)
local _, notobj = store.apply_upstreams({ "just-a-string" })
check(type(notobj) == "string", "a non-object entry is rejected", notobj)

reset_env()
local _, ok_err = store.apply_upstreams({ {
    url = "http://typed.invalid:8080", model_id = "  deep  ", priority = "70",
    cost = "2.5", labels = { gpu = "l40", tag = "" }, disable_health_check = true,
} })
eq(ok_err, nil, "typed-valid upstream accepted")
local trow = store.current().upstreams[1]
ok(trow ~= nil, "typed-valid row stored")
if trow then
    eq(trow.model_id, "deep", "model_id trimmed")
    eq(trow.priority, 70, "numeric string priority accepted")
    eq(trow.cost, 2.5, "numeric string cost accepted")
    eq(trow.disable_health_check, true, "disable_health_check stored")
    eq(trow.labels.gpu, "l40", "label stored")
end

--------------------------------------------------------------------------
-- 3. api_key 三态（契约 3.4）：set / keep / clear + 脱敏往返
--------------------------------------------------------------------------
reset_env()
local SECRET = "sk-profile-unit-secret"
local _, kerr = store.apply_upstreams({ { url = "http://key.invalid:8080", api_key = SECRET } })
eq(kerr, nil, "upstream with api_key accepted")
local krow = store.current().upstreams[1]
eq(krow.api_key_state, "set", "state is set")
eq(krow.api_key_stored, SECRET, "secret stored internally")

-- document() 永不回显密钥：api_key 恒 null、has_api_key 布尔、持久化字段不外泄
local doc = store.document()
local drow = doc.upstreams[1]
ok(drow ~= nil, "document carries the upstream")
eq(drow.api_key, NULL, "document api_key is JSON null")
eq(drow.has_api_key, true, "document exposes has_api_key true")
eq(rawget(drow, "api_key_state"), nil, "document hides api_key_state")
eq(rawget(drow, "api_key_stored"), nil, "document hides api_key_stored")
local encoded_doc = cjson.encode(doc)
check(encoded_doc:find(SECRET, 1, true) == nil, "the secret never reaches the document")
check(encoded_doc:find("api_key_stored", 1, true) == nil, "no persistence field in the JSON either")

-- 前端把脱敏文档原样提交回来（api_key: null）：密钥必须留着
local mask_roundtrip = {}
for _, row in ipairs(doc.upstreams) do
    mask_roundtrip[#mask_roundtrip + 1] = {
        url = row.url,
        model_id = (row.model_id ~= NULL) and row.model_id or nil,
        api_key = row.api_key,
        priority = row.priority,
        cost = row.cost,
        labels = row.labels,
        disable_health_check = row.disable_health_check,
    }
end
local _, merr = store.apply_upstreams(mask_roundtrip)
eq(merr, nil, "masked document round-trip accepted")
local after = store.current().upstreams[1]
eq(after.api_key_state, "set", "keep inherits the stored secret")
eq(after.api_key_stored, SECRET, "the secret survived the round-trip")

-- 字段完全不提同样是 keep
local _, kerr2 = store.apply_upstreams({ { url = "http://key.invalid:8080" } })
eq(kerr2, nil, "entry omitting api_key accepted")
eq(store.current().upstreams[1].api_key_stored, SECRET, "absent api_key keeps the secret")
eq(store.current().upstreams[1].api_key_state, "set", "inherited state is set")

-- 显式空串 = 清除
local _, kerr3 = store.apply_upstreams({ { url = "http://key.invalid:8080", api_key = "" } })
eq(kerr3, nil, "empty api_key accepted (clear)")
eq(store.current().upstreams[1].api_key_state, "clear", "explicit empty clears the key")
eq(store.current().upstreams[1].api_key_stored, nil, "the cleared key is gone")
eq(store.document().upstreams[1].has_api_key, false, "has_api_key flips to false")

-- 换个 url 就是新身份：keep 不从别的条目继承密钥
local _, kerr4 = store.apply_upstreams({ { url = "http://other.invalid:8080" } })
eq(kerr4, nil, "new url accepted")
eq(store.current().upstreams[1].api_key_state, "keep", "a fresh url keeps nothing")
eq(store.current().upstreams[1].api_key_stored, nil, "no inherited secret for a new url")

-- api_key_state=set 却没带密钥：降级 keep 而不是报错（日志一句）
local _, kerr5 = store.apply_upstreams({ { url = "http://odd.invalid", api_key_state = "set" } })
eq(kerr5, nil, "state set without a secret is tolerated")
eq(store.current().upstreams[1].api_key_state, "keep", "state set without a secret degrades to keep")

--------------------------------------------------------------------------
-- 4. reconcile 幂等计数（契约 3.1 / 3.2）
--------------------------------------------------------------------------
reset_env()
local A, B = "http://pool-a.invalid:8080", "http://pool-b.invalid:9090"
local s1 = store.apply_upstreams({
    { url = A, model_id = "test-model" },
    { url = B, model_id = "sink-model", priority = 70, cost = 2.5 },
})
eq(type(s1.added), "number", "summary counts are numbers")
eq(s1.added, 2, "a cold pool adds two")
eq(s1.updated, 0, "nothing to update on a cold pool")
eq(s1.removed, 0, "nothing removed on a cold pool")
eq(s1.skipped, 0, "nothing skipped on a cold pool")
eq(record_of(A).discovery, "config", "discovery is written as config")
eq(record_of(A).model_id, "test-model", "model_id lands on the record")
eq(record_of(B).priority, 70, "priority lands on the record")
eq(record_of(B).cost, 2.5, "cost lands on the record")
eq(record_of(A).api_key, nil, "an unkeyed member carries no key")

-- 完全相同的声明再跑一遍：四个计数全 0，且不产生 update 调用（root ruling 1）
local s2 = store.apply_upstreams({
    { url = A, model_id = "test-model" },
    { url = B, model_id = "sink-model", priority = 70, cost = 2.5 },
})
eq(s2.added, 0, "idempotent: no adds")
eq(s2.updated, 0, "idempotent: no updates")
eq(s2.removed, 0, "idempotent: no removes")
eq(s2.skipped, 0, "idempotent: no skips")
eq(calls.update, 0, "idempotent: registry.update never called for an unchanged row")

-- api_key 的 keep 永远不算变化（契约 3.4 + root ruling 1）
local s3 = store.apply_upstreams({
    { url = A, model_id = "test-model", api_key = NULL },
    { url = B, model_id = "sink-model", priority = 70, cost = 2.5 },
})
eq(s3.updated, 0, "a null api_key resubmit is not an update")

-- 只有真正变了才算 updated
local s4 = store.apply_upstreams({
    { url = A, model_id = "test-model" },
    { url = B, model_id = "changed-model", priority = 70, cost = 2.5 },
})
eq(s4.updated, 1, "a model_id change is exactly one update")
eq(record_of(B).model_id, "changed-model", "the new model_id reaches the record")
local s4b = store.apply_upstreams({
    { url = A, model_id = "test-model" },
    { url = B, model_id = "changed-model", priority = 80, cost = 2.5 },
})
eq(s4b.updated, 1, "a priority change is exactly one update")
local s4c = store.apply_upstreams({
    { url = A, model_id = "test-model" },
    { url = B, model_id = "changed-model", priority = 80, cost = 2.5, labels = { gpu = "l40" } },
})
eq(s4c.updated, 1, "a label change is exactly one update")
eq(record_of(B).labels.gpu, "l40", "labels reach the record")
local s4d = store.apply_upstreams({
    { url = A, model_id = "test-model" },
    { url = B, model_id = "changed-model", priority = 80, cost = 2.5, labels = { gpu = "l40" } },
})
eq(s4d.updated, 0, "the same labels are not an update")

-- set / clear 的密钥变化算 updated，keep 不算
local s4e = store.apply_upstreams({
    { url = A, model_id = "test-model", api_key = "sk-new" },
    { url = B, model_id = "changed-model", priority = 80, cost = 2.5, labels = { gpu = "l40" } },
})
eq(s4e.updated, 1, "setting a key on a keyless member is an update")
eq(record_of(A).api_key, "sk-new", "the key reaches the record")
local s4f = store.apply_upstreams({
    { url = A, model_id = "test-model", api_key = "sk-new" },
    { url = B, model_id = "changed-model", priority = 80, cost = 2.5, labels = { gpu = "l40" } },
})
eq(s4f.updated, 0, "re-declaring the same key is not an update")
local s4g = store.apply_upstreams({
    { url = A, model_id = "test-model", api_key = "" },
    { url = B, model_id = "changed-model", priority = 80, cost = 2.5, labels = { gpu = "l40" } },
})
eq(s4g.updated, 1, "clearing a key is an update")
eq(record_of(A).api_key, false, "the cleared key becomes false on the record")

-- 声明里消失的 config 成员被回收
local s5 = store.apply_upstreams({ { url = A, model_id = "test-model" } })
eq(s5.removed, 1, "a dropped declaration removes exactly one member")
eq(record_of(B), nil, "the dropped member left the pool")
ok(record_of(A) ~= nil, "the kept member stays")

-- 被 watcher / 手工持有的同 url：声明不动它，计入 skipped
pool_add_manual({
    id = "w-held", url = "http://held.invalid:8080", model_id = "watched",
    priority = 50, cost = 1.0, labels = {}, disable_health_check = false,
    api_key = "watcher-key", discovery = "watcher",
})
local s6 = store.apply_upstreams({
    { url = A, model_id = "test-model" },
    { url = "http://held.invalid:8080", model_id = "declared", priority = 99 },
})
eq(s6.skipped, 1, "a non-config owner holds the url: skipped")
eq(s6.updated, 0, "the held record is not patched")
eq(record_of("http://held.invalid:8080").model_id, "watched", "the watcher model_id survives")
eq(record_of("http://held.invalid:8080").priority, 50, "the watcher priority survives")
eq(record_of("http://held.invalid:8080").api_key, "watcher-key", "the watcher key survives")
-- 声明里撤掉它也不得回收别人的成员
local s7 = store.apply_upstreams({ { url = A, model_id = "test-model" } })
eq(s7.removed, 0, "a withdrawn declaration never removes a watcher member")
ok(record_of("http://held.invalid:8080") ~= nil, "the watcher member survives the teardown")
-- discovery 缺失（bootstrap / 手工 POST）同样受保护
pool_add_manual({
    id = "w-manual", url = "http://manual.invalid:8080", model_id = "manual",
    priority = 50, cost = 1.0, labels = {}, disable_health_check = false,
})
local s7b = store.apply_upstreams({
    { url = A, model_id = "test-model" },
    { url = "http://manual.invalid:8080", model_id = "declared" },
})
eq(s7b.skipped, 1, "a manual owner (no discovery) is skipped too")
eq(record_of("http://manual.invalid:8080").model_id, "manual", "the manual row keeps its identity")

-- add / update / remove 失败都进 skipped 或告警，不冒泡成错误
reset_env()
store.apply_upstreams({ { url = A } })
inject_add_fail = "pool exhausted"
local s8 = store.apply_upstreams({ { url = A }, { url = "http://new.invalid:1" } })
eq(s8.added, 0, "a failed add is not counted as added")
eq(s8.skipped, 1, "a failed add counts as skipped")
eq(s8.updated, 0, "a failed add leaves updates at zero")
inject_add_fail = nil
inject_update_fail = "boom"
local s9 = store.apply_upstreams({ { url = A, priority = 33 }, { url = "http://new.invalid:1" } })
eq(s9.updated, 0, "a failed update is not counted as updated")
check(s9.skipped >= 1, "a failed update counts as skipped", s9.skipped)
inject_update_fail = nil
inject_remove_fail = "busy"
local s9r = store.apply_upstreams({})
eq(s9r.removed, 0, "a failed remove is not counted as removed")
inject_remove_fail = nil

-- registry 模块不可用（纯单测环境）：全 0 摘要，且不算错误
reset_state(false)
use_registry({})
local s9b = store.apply_upstreams({ { url = "http://nosvc.invalid:1" } })
eq(type(s9b), "table", "apply_upstreams still answers a summary without a registry")
eq(s9b.added, 0, "no registry: added stays 0")
eq(s9b.updated, 0, "no registry: updated stays 0")
eq(s9b.removed, 0, "no registry: removed stays 0")
eq(s9b.skipped, 0, "no registry: skipped stays 0")
local direct = store.reconcile_upstreams()
eq(type(direct), "table", "reconcile_upstreams answers a table without a registry")
use_registry(make_registry_stub())

-- 池里的同一监听器可能有别的写法（watcher 报的 host 大小写、尾斜杠）：按
-- 规范化后的 endpoint 认领，既不再加一个重复成员，也不误判成"别人持有"
pool_add_manual({
    id = "w-cased", url = "http://Cased.Invalid:8080/", model_id = "watched",
    priority = 50, cost = 1.0, labels = {}, disable_health_check = false,
    discovery = "watcher",
})
local adds_before = calls.add
local s8c = store.apply_upstreams({
    { url = "http://cased.invalid:8080", model_id = "declared" },
})
eq(s8c.added, 0, "a differently spelled pool row is not a new member")
eq(s8c.skipped, 1, "the foreign owner of the same endpoint still wins")
eq(calls.add, adds_before, "registry.add was never called for the duplicate spelling")

-- 同一 endpoint 上先有 config 行、后出现外来行：声明仍然认领自己的那一行
reset_env()
store.apply_upstreams({ { url = "http://both.invalid:8080", model_id = "mine" } })
eq(record_of("http://both.invalid:8080").discovery, "config", "the config row exists")
pool_add_manual({
    id = "w-stray", url = "http://BOTH.invalid:8080", model_id = "stray",
    priority = 50, cost = 1.0, labels = {}, disable_health_check = false,
    discovery = "watcher",
})
local s8d = store.apply_upstreams({ { url = "http://both.invalid:8080", model_id = "mine" } })
eq(s8d.updated, 0, "an unchanged declaration on its own row updates nothing")
eq(s8d.added, 0, "the stray row does not push the declaration into a new add")
local s8e = store.apply_upstreams({ { url = "http://both.invalid:8080", model_id = "mine-renamed" } })
eq(s8e.updated, 1, "the config row is the one that gets patched, not the stray")
eq(record_of("http://both.invalid:8080").model_id, "mine-renamed", "the config row carries the change")
eq(record_of("http://BOTH.invalid:8080").model_id, "stray", "the foreign row is untouched")

-- 声明消失后外来行仍在：config 成员仍被精确回收（按 endpoint 比对）
local s8f = store.apply_upstreams({})
eq(s8f.removed, 1, "only the config member is reclaimed")
eq(record_of("http://both.invalid:8080"), nil, "the config row is gone")
ok(record_of("http://BOTH.invalid:8080") ~= nil, "the foreign row survives the reclaim")

-- 直接调 reconcile_upstreams 也幂等（init.lua 的 30s 自愈计时器口径）
reset_env()
store.apply_upstreams({ { url = A }, { url = B } })
local r1 = store.reconcile_upstreams()
eq(r1.added, 0, "timer reconcile after the write adds nothing")
eq(r1.updated, 0, "timer reconcile after the write updates nothing")
eq(r1.removed, 0, "timer reconcile after the write removes nothing")
local r2 = store.reconcile_upstreams()
eq(cjson.encode({ r2.added, r2.updated, r2.removed, r2.skipped }), "[0,0,0,0]",
    "a second timer pass is still all zero")
-- 池被外力清空后计时器补投：声明还在，成员复活
for _, url in ipairs({ A, B }) do pool[url] = nil end
pool_order = {}
local r3 = store.reconcile_upstreams()
eq(r3.added, 2, "the self-heal pass re-adds the wiped pool")
eq(#store.reconcile_upstreams() and "ok" or "?", "ok", "reconcile is callable twice in a row")

-- reconcile 完成后写入跨进程 token（契约 3.1 自愈判据）
ok(store.upstreams_revision() ~= nil, "reconcile records the upstreams revision")
eq(store.upstreams_reconcile_due(), false, "not due right after a reconcile")
shared.luarouter_config:incr("policy_revision", 1, 0)
eq(store.upstreams_reconcile_due(), true, "a newer config revision says reconcile is due")
store.reconcile_upstreams()
eq(store.upstreams_reconcile_due(), false, "the token catches up after the heal pass")

--------------------------------------------------------------------------
-- 5. virtual_profiles 校验（契约 3.1 / 3.3）
--------------------------------------------------------------------------
reset_env()
local p_ok, p_err = store.apply_profiles({
    { model = "vm-full", target = "test-model",
      workers = { A, A .. "/", "HTTP://POOL-A.INVALID:8080" },
      policy = "round_robin", effort = "high" },
})
eq(p_err, nil, "a full profile is accepted")
local snap_row = p_ok and p_ok.virtual_models[1]
ok(snap_row ~= nil, "apply_profiles returns the snapshot")
eq(snap_row and snap_row.model, "vm-full", "snapshot keeps the alias")
eq(snap_row and snap_row.target, "test-model", "snapshot keeps the target")
eq(snap_row and #snap_row.workers, 1, "worker candidates dedupe after normalization")
eq(snap_row and snap_row.workers[1], A, "the candidate is the normalized url")
eq(snap_row and snap_row.policy, "round_robin", "snapshot keeps the policy")
eq(snap_row and snap_row.effort, "high", "snapshot keeps the effort")
local prof = store.profile_for("vm-full")
ok(prof ~= nil, "profile_for answers for an alias")
eq(prof and prof.target, "test-model", "profile_for carries the target")
eq(prof and #prof.workers, 1, "profile_for carries the candidate list")
eq(prof and prof.policy, "round_robin", "profile_for carries the policy")
eq(prof and prof.effort, "high", "profile_for carries the effort")
eq(store.resolve_model("vm-full"), "test-model", "resolve_model still maps the alias")

-- 可选字段缺省时整体省略（旧快照形状不变）
reset_env()
store.apply_profiles({ { model = "vm-old", target = "test-model" } })
local old_row = store.profiles_list()[1]
ok(old_row ~= nil, "profiles_list returns the alias row")
eq(old_row and rawget(old_row, "workers"), nil, "no workers key when unset")
eq(old_row and rawget(old_row, "policy"), nil, "no policy key when unset")
eq(old_row and rawget(old_row, "effort"), nil, "no effort key when unset")
local snap_vm = store.snapshot_of(store.current()).virtual_models[1]
eq(rawget(snap_vm, "workers"), nil, "the snapshot row has no workers key when unset")
eq(rawget(snap_vm, "policy"), nil, "the snapshot row has no policy key when unset")
eq(rawget(snap_vm, "effort"), nil, "the snapshot row has no effort key when unset")
check(cjson.encode(snap_vm):find('"policy"', 1, true) == nil,
    "the encoded row carries no null policy placeholder")

-- 空集合渲染成 []（root 补充 2）
reset_env()
local empty_snap = cjson.encode(store.document())
check(empty_snap:find('"upstreams":%[%]', 1) ~= nil, "an empty upstreams array renders as []")
check(empty_snap:find('"virtual_models":%[%]', 1) ~= nil, "an empty virtual_models array renders as []")

-- 自指 / 空 target / 空 alias / 非对象 / 非数组
local bad_profiles = {
    { { { model = "vm-same", target = "vm-same" } }, "must differ from its target" },
    { { { model = "vm-empty", target = "" } }, "model and target" },
    { { { model = "", target = "test-model" } }, "model and target" },
    { { { model = "vm-null", target = NULL } }, "model and target" },
    { { "string-entry" }, "objects" },
    { { { model = 42, target = "test-model" } }, "model and target" },
    { "not-an-array", nil },
}
for _, case in ipairs(bad_profiles) do
    local _, err = store.apply_profiles(case[1])
    check(type(err) == "string", "rejected profile shape", err)
    if case[2] then
        check(type(err) == "string" and err:find(case[2], 1, true) ~= nil,
            "rejection wording mentions " .. case[2], err)
    end
end

-- workers 形状
local w_cases = {
    { "http://pool.invalid", "array of strings" },
    { { "ok", 123 }, "normalized urls or worker ids" },
    { { "not a url at all" }, "normalized urls or worker ids" },
}
for _, case in ipairs(w_cases) do
    local _, err = store.apply_profiles({ { model = "vm-w", target = "test-model", workers = case[1] } })
    check(type(err) == "string" and err:find(case[2], 1, true) ~= nil,
        "workers rejection wording " .. case[2], err)
end
for _, empty in ipairs({ {}, cjson.decode("[]") }) do
    reset_env()
    local _, err = store.apply_profiles({ { model = "vm-w", target = "test-model", workers = empty } })
    eq(err, nil, "an empty workers list is legal (field omitted)")
    eq(rawget(store.profiles_list()[1], "workers"), nil, "empty workers list stores nothing")
end
-- worker id 与 url 两种命中都收（root ruling 5）
reset_env()
local UUID = "0f8fad5b-d9cb-469f-a165-70867728950e"
local _, wid_err = store.apply_profiles({ { model = "vm-id", target = "test-model", workers = { UUID, A } } })
eq(wid_err, nil, "a worker id candidate is accepted")
local wid_row = store.profiles_list()[1]
eq(wid_row and #wid_row.workers, 2, "both candidate kinds are stored")
eq(wid_row and wid_row.workers[1], UUID, "worker ids are stored lowercase")
--------------------------------------------------------------------------
-- 5b. virtual_models 新形状：候选各带模型（candidates 绑定层）
--
-- 需求：一个别名可以把不同上游实例绑到不同模型（不必同构），target 因此变成可选。
-- 这里逐条钉住 build_candidate_bindings / profile_from_entry /
-- assert_bindings_no_alias / snapshot_of / profiles_list / profile_for /
-- cfg_from_document 的契约，尤其是「旧 {model,target} 形状逐字段不变」与
-- 「candidates-only 不许长出没人声明的 target」两条红线。
--------------------------------------------------------------------------
-- luajit 的 main chunk 只容得下 200 个局部变量，本段整体收进一个函数里跑。
local function verify_candidate_bindings()
    local UUID_UP = "0F8FAD5B-D9CB-469F-A165-70867728950F"
    local UUID_LOW = "0f8fad5b-d9cb-469f-a165-70867728950f"
    local function cnd(worker, model) return { worker = worker, model = model } end

    -- (1) 候选各带模型：两条候选、两个不同 model，声明顺序与形状都保留
    reset_env()
    local mb_snap, mb_err = store.apply_profiles({
        { model = "vm-multi", candidates = { cnd(A, "qwen3-30b"), cnd(B, "deepseek-v3") } },
    })
    eq(mb_err, nil, "1) per-candidate models are accepted")
    local mb_row = store.profiles_list()[1]
    ok(mb_row ~= nil, "1) the multi-binding row is listed")
    eq(mb_row and mb_row.model, "vm-multi", "1) the alias is kept")
    local mb_c = mb_row and mb_row.candidates
    ok(type(mb_c) == "table", "1) the row carries candidates")
    eq(mb_c and #mb_c, 2, "1) both bindings are stored")
    eq(mb_c and mb_c[1].worker, A, "1) binding 1 keeps its worker")
    eq(mb_c and mb_c[1].model, "qwen3-30b", "1) binding 1 keeps its model (declaration order)")
    eq(mb_c and mb_c[2].worker, B, "1) binding 2 keeps its worker")
    eq(mb_c and mb_c[2].model, "deepseek-v3", "1) binding 2 keeps its model")
    check(mb_c ~= nil and mb_c[1].model ~= mb_c[2].model, "1) the two bindings use different models")
    check(mb_c ~= nil and rawget(mb_c[1], "url") == nil, "1) a binding is {worker,model} with no url key")
    local function binding_key_count(row)
        local n = 0
        for _ in pairs(row) do n = n + 1 end
        return n
    end
    eq(mb_c and binding_key_count(mb_c[1]), 2, "1) a binding carries exactly the worker and model keys")
    eq(mb_c and mb_c[1].worker ~= nil and mb_c[1].model ~= nil, true, "1) both binding fields are filled")
    eq(store.profile_for("vm-multi") and store.profile_for("vm-multi").target, "qwen3-30b",
        "1) the representative target is the first explicit model")
    eq(store.current().virtual_profiles["vm-multi"] and store.current().virtual_profiles["vm-multi"].target,
        "qwen3-30b", "1) the stored profile keeps the derived representative")
    eq(store.resolve_model("vm-multi"), "qwen3-30b", "1) resolve_model maps to the representative")
    eq(mb_row and rawget(mb_row, "target"), nil, "1) an undeclared target stays absent from the row")
    local mb_prof = store.profile_for("vm-multi")
    eq(mb_prof and #mb_prof.candidates, 2, "1) profile_for carries the bindings")
    eq(mb_prof and mb_prof.candidates[2].model, "deepseek-v3", "1) profile_for keeps the binding models")
    eq(mb_prof and rawget(mb_prof, "explicit_target"), nil, "1) profile_for hides explicit_target")
    local mb_snap_row = mb_snap and mb_snap.virtual_models[1]
    eq(mb_snap_row and #mb_snap_row.candidates, 2, "1) the returned snapshot carries the bindings")
    eq(mb_snap_row and mb_snap_row.candidates[1].model, "qwen3-30b", "1) the snapshot keeps binding models")

    -- (2) target 可缺省：不写 target 也能 apply
    reset_env()
    local co_snap, co_err = store.apply_profiles({
        { model = "vm-conly", candidates = { cnd(A, "model-a"), cnd(B, "model-b") } },
    })
    eq(co_err, nil, "2) a candidates-only profile applies without a target")
    local co_row = store.profiles_list()[1]
    ok(co_row ~= nil, "2) the candidates-only row is listed")
    eq(co_row and #co_row.candidates, 2, "2) both bindings survived")
    eq(co_row and rawget(co_row, "target"), nil, "2) no target key when none was declared")
    eq(co_snap and rawget(co_snap.virtual_models[1], "target"), nil, "2) the returned snapshot has no target key")
    eq(store.profile_for("vm-conly") and store.profile_for("vm-conly").target, "model-a",
        "2) the representative target is still readable by pre-feature readers")

    -- (3) candidates[].model 缺省继承 target
    reset_env()
    local _, ih_err = store.apply_profiles({
        { model = "vm-inherit", target = "test-model", candidates = { { worker = A }, { worker = B } } },
    })
    eq(ih_err, nil, "3) bindings without a model are accepted when a target exists")
    local ih_row = store.profiles_list()[1]
    eq(ih_row and #ih_row.candidates, 2, "3) both inherit-bindings are stored")
    eq(ih_row and ih_row.candidates[1].model, "test-model", "3) binding 1 inherits the target")
    eq(ih_row and ih_row.candidates[2].model, "test-model", "3) binding 2 inherits the target")
    eq(ih_row and ih_row.target, "test-model", "3) the declared target survives")
    local ih_prof = store.profile_for("vm-inherit")
    eq(ih_prof and ih_prof.candidates[2].model, "test-model", "3) profile_for hands out the inherited model")
    reset_env()
    local _, in_err = store.apply_profiles({
        { model = "vm-nullmodel", target = "test-model",
          candidates = { { worker = A, model = NULL }, { worker = B, model = "" } } },
    })
    eq(in_err, nil, "3) a null or empty model reads as unset")
    local in_row = store.profiles_list()[1]
    eq(in_row and in_row.candidates[1].model, "test-model", "3) an explicit null inherits the target")
    eq(in_row and in_row.candidates[2].model, "test-model", "3) an empty model inherits the target")

    -- (4) 无 target 且候选无 model -> 报错（no target to inherit）
    reset_env()
    local _, nt_err = store.apply_profiles({ { model = "vm-nt", candidates = { { worker = A } } } })
    check(type(nt_err) == "string" and nt_err:find("no target to inherit", 1, true) ~= nil,
        "4) a target-less binding without a model is refused", nt_err)
    check(type(nt_err) == "string" and nt_err:find("vm-nt", 1, true) ~= nil,
        "4) the rejection names the alias", nt_err)
    check(type(nt_err) == "string" and nt_err:find(A, 1, true) ~= nil,
        "4) the rejection names the offending worker", nt_err)
    eq(#store.profiles_list(), 0, "4) the refused batch wrote nothing")
    reset_env()
    local _, nt2_err = store.apply_profiles({
        { model = "vm-nt2", candidates = { cnd(A, "model-a"), { worker = B } } },
    })
    check(type(nt2_err) == "string" and nt2_err:find("no target to inherit", 1, true) ~= nil,
        "4) one model-less binding among explicit ones is refused", nt2_err)
    eq(#store.profiles_list(), 0, "4) the partially bad batch wrote nothing")
    local _, nt3_err = store.apply_profiles({
        { model = "vm-nt2", target = "model-a", candidates = { cnd(A, "model-a"), { worker = B } } },
    })
    eq(nt3_err, nil, "4) the same row is accepted once a target exists to inherit")

    -- (5) 同一 worker 绑两个模型报错；同一条绑定重复提交静默去重
    reset_env()
    local _, two_err = store.apply_profiles({
        { model = "vm-two", candidates = { cnd(A, "model-a"), cnd(A, "model-b") } },
    })
    check(type(two_err) == "string" and two_err:find("two models", 1, true) ~= nil,
        "5) one worker bound to two models is refused", two_err)
    check(type(two_err) == "string" and two_err:find("vm-two", 1, true) ~= nil,
        "5) the two-model rejection names the alias", two_err)
    check(type(two_err) == "string" and two_err:find(A, 1, true) ~= nil,
        "5) the two-model rejection names the worker", two_err)
    eq(#store.profiles_list(), 0, "5) the refused two-model batch wrote nothing")
    reset_env()
    local _, dd_err = store.apply_profiles({
        { model = "vm-dd", candidates = { cnd(A, "model-a"), cnd(A, "model-a"), cnd(A, "model-a") } },
    })
    eq(dd_err, nil, "5) the identical binding repeated is accepted")
    local dd_row = store.profiles_list()[1]
    eq(dd_row and #dd_row.candidates, 1, "5) the duplicate binding silently dedupes to one row")
    eq(dd_row and dd_row.candidates[1].model, "model-a", "5) the deduped binding keeps its model")
    eq(dd_row and dd_row.candidates[1].worker, A, "5) the deduped binding keeps its worker")
    reset_env()
    local _, dd2_err = store.apply_profiles({
        { model = "vm-dd2", target = "test-model", candidates = { { worker = A }, { worker = A } } },
    })
    eq(dd2_err, nil, "5) two model-less bindings for one worker dedupe")
    local dd2_row = store.profiles_list()[1]
    eq(dd2_row and #dd2_row.candidates, 1, "5) the inherit-duplicates collapse to one binding")
    eq(dd2_row and dd2_row.candidates[1].model, "test-model", "5) the collapsed binding inherits the target")
    reset_env()
    local _, dd3_err = store.apply_profiles({
        { model = "vm-dd3", candidates = { cnd(A, "model-a"), { url = A, model = "model-a" } } },
    })
    eq(dd3_err, nil, "5) worker= and url= spellings of one binding dedupe together")
    eq(store.profiles_list()[1] and #store.profiles_list()[1].candidates, 1,
        "5) the mixed spelling batch stores one binding")

    -- (6) 绑定指向别的别名 -> 拒绝（沿用 target 那一族文案）
    reset_env()
    local _, sib_err = store.apply_profiles({ { model = "vm-sib", target = "test-model" } })
    eq(sib_err, nil, "6) the sibling alias is created first")
    local _, b1_err = store.apply_profiles({
        { model = "vm-b1", target = "real-model", candidates = { cnd(A, "real-2"), cnd(B, "vm-sib") } },
    })
    check(type(b1_err) == "string" and b1_err:find("must not be another virtual model", 1, true) ~= nil,
        "6) a binding that names an existing alias is refused", b1_err)
    check(type(b1_err) == "string" and b1_err:find("vm-b1", 1, true) ~= nil,
        "6) the binding chain rejection names the writer", b1_err)
    eq(#store.profiles_list(), 1, "6) the refused batch left the table untouched")
    eq(store.profiles_list()[1] and store.profiles_list()[1].model, "vm-sib",
        "6) the surviving row is the old alias")
    reset_env()
    local _, b2_err = store.apply_profiles({
        { model = "vm-m1", target = "real-1", candidates = { cnd(A, "real-2"), cnd(B, "vm-m2") } },
        { model = "vm-m2", target = "real-3", candidates = { cnd(A, "real-4") } },
    })
    check(type(b2_err) == "string" and b2_err:find("must not be another virtual model", 1, true) ~= nil,
        "6) same-batch bindings to a sibling alias are refused", b2_err)
    eq(#store.profiles_list(), 0, "6) the refused same-batch wrote nothing")
    reset_env()
    local _, b2b_err = store.apply_profiles({
        { model = "vm-cx", target = "real-1", candidates = { cnd(A, "vm-cy") } },
        { model = "vm-cy", target = "real-2", candidates = { cnd(B, "vm-cx") } },
    })
    check(type(b2b_err) == "string" and b2b_err:find("must not be another virtual model", 1, true) ~= nil,
        "6) two bindings in one batch that point at each other are refused", b2b_err)
    eq(#store.profiles_list(), 0, "6) the mutually-pointing batch wrote nothing")
    reset_env()
    local _, b3_err = store.apply_profiles({
        { model = "vm-self", target = "real-1", candidates = { cnd(A, "real-2"), cnd(B, "vm-self") } },
    })
    check(type(b3_err) == "string" and b3_err:find("must differ from its target", 1, true) ~= nil,
        "6) a binding that names its own alias uses the self-reference wording", b3_err)
    reset_env()
    local _, b4_err = store.apply_profiles({ { model = "vm-named", candidates = { cnd(A, "vm-named") } } })
    check(type(b4_err) == "string" and b4_err:find("must differ from its target", 1, true) ~= nil,
        "6) a candidates-only row named after itself is refused", b4_err)
    reset_env()
    local _, anc_err = store.apply_profiles({ { model = "vm-anchor", target = "test-model" } })
    eq(anc_err, nil, "6) the anchor alias for the legacy wording is created")
    local _, t6_err = store.apply_profiles({ { model = "vm-child", target = "vm-anchor" } })
    check(type(t6_err) == "string" and t6_err:find("must not be another virtual model", 1, true) ~= nil,
        "6) the legacy target->alias wording is unchanged", t6_err)
    check(type(t6_err) == "string" and t6_err:find("vm-child", 1, true) ~= nil,
        "6) the legacy rejection still names the writer", t6_err)
    -- document 层（cfg_from_document）同样挡住互指
    local _, d6_err = store.cfg_from_document({
        virtual_models = {
            { model = "vm-d1", target = "real-1", candidates = { cnd(A, "vm-d2") } },
            { model = "vm-d2", target = "real-2", candidates = { cnd(B, "ok-model") } },
        },
    })
    check(type(d6_err) == "string" and d6_err:find("must not be another virtual model", 1, true) ~= nil,
        "6) cfg_from_document refuses cross-alias bindings in the batch", d6_err)

    -- (7) 向后兼容：旧 {model,target} 形状四条链路逐字段不变
    reset_env()
    local lg_snap, lg_err = store.apply_profiles({
        { model = "vm-legacy", target = "test-model", workers = { A }, policy = "round_robin", effort = "high" },
    })
    eq(lg_err, nil, "7) the legacy {model,target} shape still applies")
    local lg_row = store.profiles_list()[1]
    ok(lg_row ~= nil, "7) the legacy row is listed")
    eq(lg_row and lg_row.model, "vm-legacy", "7) the legacy alias is kept")
    eq(lg_row and lg_row.target, "test-model", "7) the legacy target is always written back")
    eq(lg_row and rawget(lg_row, "candidates"), nil, "7) the legacy row grows no candidates key")
    eq(lg_row and lg_row.policy, "round_robin", "7) the legacy policy is kept")
    eq(lg_row and lg_row.effort, "high", "7) the legacy effort is kept")
    eq(lg_row and #lg_row.workers, 1, "7) the legacy workers list is kept")
    check(lg_row ~= nil and cjson.encode(lg_row):find("candidates", 1, true) == nil,
        "7) the encoded legacy row never mentions candidates")
    local lg_snap_row = lg_snap and lg_snap.virtual_models[1]
    eq(lg_snap_row and rawget(lg_snap_row, "candidates"), nil, "7) apply_profiles' snapshot has no candidates key")
    eq(lg_snap_row and lg_snap_row.target, "test-model", "7) apply_profiles' snapshot keeps the target")
    local lg_of = store.snapshot_of(store.current()).virtual_models[1]
    eq(lg_of and rawget(lg_of, "candidates"), nil, "7) snapshot_of hands out no candidates key")
    eq(lg_of and lg_of.target, "test-model", "7) snapshot_of writes the target")
    check(lg_of ~= nil and cjson.encode(lg_of):find("candidates", 1, true) == nil,
        "7) the snapshot text has no candidates field")
    local lg_doc = store.document().virtual_models[1]
    eq(lg_doc and rawget(lg_doc, "candidates"), nil, "7) document() has no candidates key")
    eq(lg_doc and lg_doc.target, "test-model", "7) document() writes the target back")
    check(cjson.encode(store.document().virtual_models):find("candidates", 1, true) == nil,
        "7) the document text never mentions candidates")
    local lg_prof = store.profile_for("vm-legacy")
    eq(lg_prof and rawget(lg_prof, "candidates"), nil, "7) profile_for hands out no candidates key")
    eq(lg_prof and lg_prof.target, "test-model", "7) profile_for keeps the legacy target")
    eq(lg_prof and rawget(lg_prof, "explicit_target"), nil, "7) profile_for leaks no bookkeeping")
    local lg_cfg, lg_cfg_err = store.cfg_from_document({ virtual_models = { { model = "vm-l2", target = "t2" } } })
    eq(lg_cfg_err, nil, "7) cfg_from_document accepts the legacy shape")
    eq(lg_cfg and lg_cfg.virtual_models["vm-l2"], "t2", "7) the alias -> target map is unchanged")
    eq(lg_cfg and lg_cfg.virtual_profiles["vm-l2"].target, "t2", "7) the profile view is unchanged")
    eq(lg_cfg and rawget(lg_cfg.virtual_profiles["vm-l2"], "candidates"), nil,
        "7) cfg_from_document invents no candidates")
    check(lg_cfg ~= nil
        and cjson.encode(store.snapshot_of(lg_cfg).virtual_models[1]):find("candidates", 1, true) == nil,
        "7) the rebuilt legacy snapshot stays candidates-free")
    -- 纯 target 行经过 document 两轮往返也必须逐字节稳定（没有 candidates 干扰）
    local lg_t1 = cjson.encode(store.document())
    local _, lg_a1 = store.apply_document(cjson.decode(lg_t1))
    eq(lg_a1, nil, "7) the legacy document re-saves cleanly")
    eq(cjson.encode(store.document()), lg_t1, "7) the legacy round trip is byte-identical")

    -- (8) candidates-only 不长出幻影 target：document 往返逐字节稳定
    reset_env()
    store.apply_profiles({ { model = "vm-rt", candidates = { cnd(A, "r-one"), cnd(B, "r-two") } } })
    local rt_text1 = cjson.encode(store.document())
    local rt_row1 = cjson.decode(rt_text1).virtual_models[1]
    eq(rt_row1 and rawget(rt_row1, "target"), nil, "8) round 1 writes no target for a candidates-only row")
    check(rt_row1 ~= nil and cjson.encode(rt_row1):find('"target"', 1, true) == nil,
        "8) the encoded candidates-only row has no target field")
    local _, rt_e2 = store.apply_document(cjson.decode(rt_text1))
    eq(rt_e2, nil, "8) the JSON editor can save the candidates-only document")
    local rt_text2 = cjson.encode(store.document())
    local _, rt_e3 = store.apply_document(cjson.decode(rt_text2))
    eq(rt_e3, nil, "8) saving it a second time stays clean")
    local rt_text3 = cjson.encode(store.document())
    eq(rt_text2, rt_text3, "8) two round trips produce byte-identical JSON")
    eq(rt_text1, rt_text2, "8) the first save is already a fixed point")
    local rt_row3 = cjson.decode(rt_text3).virtual_models[1]
    eq(rt_row3 and rawget(rt_row3, "target"), nil, "8) no phantom target after two round trips")
    eq(rt_row3 and #rt_row3.candidates, 2, "8) both bindings survive the round trips")
    eq(rt_row3 and rt_row3.candidates[2].model, "r-two", "8) the binding models survive the round trips")
    eq(store.profiles_list()[1] and rawget(store.profiles_list()[1], "target"), nil,
        "8) profiles_list stays target-free after the round trips")
    check(rt_text3:find("explicit_target", 1, true) == nil,
        "8) the internal bookkeeping field never reaches the document")
    check(rt_text3:find("phantom", 1, true) == nil, "8) no invented model name appears in the text")
    reset_env()
    store.apply_profiles({
        { model = "vm-mix8", target = "rep-model", candidates = { cnd(A, "m-one"), cnd(B, "m-two") } },
    })
    local mx_text1 = cjson.encode(store.document())
    check(mx_text1:find('"target":"rep-model"', 1, true) ~= nil,
        "8) a declared target is written back for a candidates row", mx_text1)
    local _, mx_e2 = store.apply_document(cjson.decode(mx_text1))
    eq(mx_e2, nil, "8) the declared-target row re-saves cleanly")
    local _, mx_e3 = store.apply_document(cjson.decode(cjson.encode(store.document())))
    eq(mx_e3, nil, "8) and a third save stays clean")
    local mx_row3 = cjson.decode(cjson.encode(store.document())).virtual_models[1]
    eq(mx_row3 and mx_row3.target, "rep-model", "8) the declared target survives two round trips")
    eq(mx_row3 and #mx_row3.candidates, 2, "8) bindings survive alongside a declared target")
    eq(mx_row3 and mx_row3.candidates[1].model, "m-one", "8) the binding models survive with a declared target")

    -- (9) worker 字段规范化：三种拼写归一、uuid 收小写、url 与 worker 同义
    reset_env()
    local _, nz_err = store.apply_profiles({
        { model = "vm-nz", target = "test-model", candidates = {
            { worker = "HTTP://POOL-A.INVALID:8080", model = "m-nz" },
            { worker = "http://pool-a.invalid:8080/", model = "m-nz" },
            { worker = "http://pool-a.invalid:8080", model = "m-nz" },
        } },
    })
    eq(nz_err, nil, "9) three spellings of one worker are not a conflict")
    local nz_row = store.profiles_list()[1]
    eq(nz_row and #nz_row.candidates, 1, "9) the three spellings dedupe to one binding")
    eq(nz_row and nz_row.candidates[1].worker, A, "9) the worker is stored in normalized form")
    reset_env()
    local _, us_err = store.apply_profiles({
        { model = "vm-url", candidates = {
            { url = "HTTP://POOL-A.INVALID:8080/", model = "m-u" }, { url = B, model = "m-v" },
        } },
    })
    eq(us_err, nil, "9) url= is accepted as a synonym for worker=")
    local us_row = store.profiles_list()[1]
    eq(us_row and #us_row.candidates, 2, "9) both url-shape bindings are stored")
    eq(us_row and us_row.candidates[1].worker, A, "9) the synonym is stored under worker and normalized")
    eq(us_row and us_row.candidates[2].worker, B, "9) the second synonym is normalized too")
    eq(us_row and us_row.candidates[1].model, "m-u", "9) the synonym binding keeps its model")
    check(us_row ~= nil and rawget(us_row.candidates[1], "url") == nil, "9) no url key survives the store")
    reset_env()
    local _, pw_err = store.apply_profiles({
        { model = "vm-pw", target = "test-model", candidates = { { worker = A, url = B, model = "m-p" } } },
    })
    eq(pw_err, nil, "9) a row naming both worker and url is accepted")
    eq(store.profiles_list()[1] and store.profiles_list()[1].candidates[1].worker, A,
        "9) worker= wins over the url= synonym")
    reset_env()
    local _, uid_err = store.apply_profiles({
        { model = "vm-uid", candidates = { { worker = UUID_UP, model = "m-id" } } },
    })
    eq(uid_err, nil, "9) a uuid-form worker id is accepted as a binding")
    local uid_row = store.profiles_list()[1]
    eq(uid_row and uid_row.candidates[1].worker, UUID_LOW, "9) the id binding is stored lowercase")
    eq(uid_row and uid_row.candidates[1].model, "m-id", "9) the id binding keeps its model")
    reset_env()
    local _, mx9_err = store.apply_profiles({
        { model = "vm-mix9", target = "test-model", candidates = {
            { worker = "  " .. A .. "  ", model = "m1" }, { worker = UUID_UP, model = "m2" },
        } },
    })
    eq(mx9_err, nil, "9) a padded url and an id coexist in one list")
    local mx9_row = store.profiles_list()[1]
    eq(mx9_row and mx9_row.candidates[1].worker, A, "9) the padded url is trimmed and normalized")
    eq(mx9_row and mx9_row.candidates[2].worker, UUID_LOW, "9) the id is trimmed and lowercased")

    -- (10) candidates 与 workers 两层独立；非法形状各自文案；空数组按未设置处理
    reset_env()
    local _, cw_err = store.apply_profiles({
        { model = "vm-both", target = "test-model", workers = { A, B },
          candidates = { cnd(A, "m-x"), cnd(B, "m-y") } },
    })
    eq(cw_err, nil, "10) workers and candidates are accepted together")
    local cw_row = store.profiles_list()[1]
    eq(cw_row and #cw_row.workers, 2, "10) the workers whitelist is kept")
    eq(cw_row and cw_row.workers[2], B, "10) workers stay normalized urls")
    eq(cw_row and #cw_row.candidates, 2, "10) the binding layer is kept as well")
    eq(cw_row and cw_row.candidates[1].model, "m-x", "10) bindings keep their own models")
    eq(cw_row and cw_row.target, "test-model", "10) the declared target is kept")
    local cw_snap = cjson.encode(store.snapshot_of(store.current()).virtual_models[1])
    check(cw_snap:find('"workers"', 1, true) ~= nil and cw_snap:find('"candidates"', 1, true) ~= nil,
        "10) the snapshot encodes both layers", cw_snap)
    local bad_cands = {
        { "not-an-array", "candidates must be an array of objects" },
        { { "plain-string" }, "must be objects with a worker" },
        { { 42 }, "must be objects with a worker" },
        { { { foo = 1 } }, "must name a normalized url or worker id" },
        { { { model = "m" } }, "must name a normalized url or worker id" },
        { { { worker = "not a url at all", model = "m" } }, "must name a normalized url or worker id" },
        { { { worker = 12345, model = "m" } }, "must name a normalized url or worker id" },
        { { { worker = A, model = 42 } }, "model must be a string or null" },
        { { { worker = A, model = true } }, "model must be a string or null" },
        { { foo = 1 }, "candidates must be an array of objects" },
        { { { worker = NULL, model = "m" } }, "must name a normalized url or worker id" },
    }
    for _, case in ipairs(bad_cands) do
        reset_env()
        local _, cerr = store.apply_profiles({
            { model = "vm-bc", target = "test-model", candidates = case[1] },
        })
        check(type(cerr) == "string" and cerr:find(case[2], 1, true) ~= nil,
            "10) candidates rejection wording: " .. case[2], cerr)
        check(type(cerr) == "string" and cerr:find("vm-bc", 1, true) ~= nil,
            "10) the rejection names the alias: " .. case[2], cerr)
        eq(#store.profiles_list(), 0, "10) the rejected batch wrote nothing: " .. case[2])
    end
    for _, empty in ipairs({ {}, cjson.decode("[]") }) do
        reset_env()
        local _, eerr = store.apply_profiles({
            { model = "vm-ce", target = "test-model", candidates = empty },
        })
        eq(eerr, nil, "10) an empty candidates list is legal (field omitted)")
        local ce_row = store.profiles_list()[1]
        ok(ce_row ~= nil, "10) the empty-candidates row is stored")
        eq(ce_row and rawget(ce_row, "candidates"), nil, "10) an empty candidates list stores nothing")
        eq(ce_row and ce_row.target, "test-model", "10) the row keeps its other fields")
    end
    reset_env()
    local _, ne_err = store.apply_profiles({ { model = "vm-ne", candidates = {} } })
    check(type(ne_err) == "string" and (ne_err:find("need both model and target", 1, true) ~= nil
        or ne_err:find("needs a target model", 1, true) ~= nil),
        "10) an empty candidates list with no target is the neither-half error", ne_err)
    reset_env()
    local _, nd_err = store.apply_profiles({ { model = "vm-nd" } })
    check(type(nd_err) == "string" and (nd_err:find("need both model and target", 1, true) ~= nil
        or nd_err:find("needs a target model", 1, true) ~= nil),
        "10) a row with neither half keeps the old wording", nd_err)
    local _, doc_nd_err = store.cfg_from_document({ virtual_models = { { model = "vm-dn" } } })
    check(type(doc_nd_err) == "string" and doc_nd_err:find("needs a target model", 1, true) ~= nil,
        "10) cfg_from_document words the neither-half row as documented", doc_nd_err)
    local _, doc_ok_err = store.cfg_from_document({
        virtual_models = { { model = "vm-dok", candidates = { cnd(A, "doc-model") } } },
    })
    eq(doc_ok_err, nil, "10) cfg_from_document accepts a target-less candidates row")

    -- (11) profile_for 返回拷贝：调用方改不坏存储
    reset_env()
    store.apply_profiles({
        { model = "vm-copy", target = "rep-model", candidates = { cnd(A, "m-one"), cnd(B, "m-two") },
          workers = { A }, policy = "bucket", effort = "low" },
    })
    local cp1 = store.profile_for("vm-copy")
    ok(cp1 ~= nil, "11) profile_for returns a table for the alias")
    eq(rawget(cp1, "explicit_target"), nil, "11) the returned profile has no explicit_target key")
    eq(cp1 and cp1.candidates[1].model, "m-one", "11) the copy carries the binding model")
    cp1.candidates[1].model = "tampered"
    cp1.candidates[1].worker = "tampered"
    cp1.candidates[2] = { worker = A, model = "phantom" }
    cp1.target = "tampered"
    local cp2 = store.profile_for("vm-copy")
    eq(cp2 and cp2.candidates[1].model, "m-one", "11) the stored binding is immune to caller writes")
    eq(cp2 and cp2.candidates[1].worker, A, "11) the stored worker is immune too")
    eq(cp2 and #cp2.candidates, 2, "11) an appended binding does not leak into the store")
    eq(cp2 and cp2.target, "rep-model", "11) the stored target is immune to caller writes")
    eq(store.profiles_list()[1] and store.profiles_list()[1].candidates[1].model, "m-one",
        "11) profiles_list reads untampered bindings")
    eq(store.current().virtual_profiles["vm-copy"].candidates[1].model, "m-one",
        "11) current() keeps the untampered binding")
    check(cp2 ~= nil and cp1 ~= nil and cp2.candidates[1] ~= cp1.candidates[1],
        "11) two calls hand out different binding tables")
    local cp3 = store.profile_for("vm-copy")
    eq(cp3 and #cp3.workers, 1, "11) the copied worker list is independent too")
    eq(cp3 and cp3.policy, "bucket", "11) the copy carries the policy")
    eq(cp3 and cp3.effort, "low", "11) the copy carries the effort")

    -- (12) env 种子层：旧 LMR_VIRTUAL_MODELS 形状仍只是 {target} 的 profile
    reset_env()
    _G.LMR_ENV_CACHE.LMR_VIRTUAL_MODELS = "env-old:real-old"
    local ev_doc = store.env_defaults()
    local ev_rows = {}
    for _, row in ipairs(ev_doc.virtual_models) do ev_rows[row.model] = row end
    ok(ev_rows["env-old"] ~= nil, "12) the legacy env pair still seeds a row")
    eq(ev_rows["env-old"] and ev_rows["env-old"].target, "real-old", "12) the env row keeps its target")
    eq(ev_rows["env-old"] and rawget(ev_rows["env-old"], "candidates"), nil,
        "12) the env row grows no candidates key")
    check(ev_rows["env-old"] ~= nil
        and cjson.encode(ev_rows["env-old"]):find("candidates", 1, true) == nil,
        "12) the encoded env row never mentions candidates")
    local ev_prof = store.profile_for("env-old")
    eq(ev_prof and ev_prof.target, "real-old", "12) profile_for serves the env alias")
    eq(ev_prof and rawget(ev_prof, "candidates"), nil, "12) the env profile carries no candidates key")
    eq(ev_prof and rawget(ev_prof, "explicit_target"), nil, "12) no internal bookkeeping leaks for the env row")
    eq(store.profiles_list()[1] and rawget(store.profiles_list()[1], "candidates"), nil,
        "12) profiles_list keeps the env row target-only")
    eq(store.resolve_model("env-old"), "real-old", "12) resolve_model still maps the env alias")
    reset_env()
end
verify_candidate_bindings()

--------------------------------------------------------------------------
-- 6. policy / effort 词表：合法名收下，空/auto/null 省略，垃圾名与非字符串 400
--------------------------------------------------------------------------
reset_env()
local _, pad_err = store.apply_profiles({ { model = "vm-pol", target = "test-model", policy = " cache_aware " } })
eq(pad_err, nil, "a padded policy is accepted")
eq(store.profiles_list()[1].policy, "cache_aware", "policy trimmed and lowercased")
for _, word in ipairs({ "", "  ", "auto", "null", "default" }) do
    reset_env()
    local _, werr = store.apply_profiles({ { model = "vm-word", target = "test-model", policy = word } })
    eq(werr, nil, "policy [" .. word .. "] is treated as unset")
    eq(rawget(store.profiles_list()[1], "policy"), nil, "policy [" .. word .. "] omitted from the row")
end
-- effort 的"未设置"词表沿用模块既有口径（"" / null / default）；"auto" 只有
-- policy 侧认（normalize_policy 特判），effort 侧仍是未知档位 = 400。
for _, word in ipairs({ "", "null", "default" }) do
    reset_env()
    local _, werr = store.apply_profiles({ { model = "vm-word", target = "test-model", effort = word } })
    eq(werr, nil, "effort [" .. word .. "] is treated as unset")
    eq(rawget(store.profiles_list()[1], "effort"), nil, "effort [" .. word .. "] omitted from the row")
end
local _, auto_effort_err = store.apply_profiles({ { model = "vm-word", target = "test-model", effort = "auto" } })
check(type(auto_effort_err) == "string"
    and auto_effort_err:find("unknown effort for virtual model vm-word", 1, true) ~= nil,
    "effort auto stays an unknown level (the word belongs to policy only)", auto_effort_err)
for _, level in ipairs(store.effort_levels()) do
    reset_env()
    local _, lerr = store.apply_profiles({ { model = "vm-lv", target = "test-model", effort = level } })
    eq(lerr, nil, "the eight effort levels are all accepted")
    eq(store.profiles_list()[1].effort, level, "effort round-trips: " .. level)
end
local bad_field_cases = {
    { { policy = "roundabout" }, "unknown policy" },
    { { policy = 42 }, "policy must be a string" },
    { { policy = true }, "policy must be a string" },
    { { effort = "mega" }, "unknown effort" },
    { { effort = true }, "effort must be a string" },
}
for _, case in ipairs(bad_field_cases) do
    local entry = { model = "vm-bad", target = "test-model" }
    for k, v in pairs(case[1]) do entry[k] = v end
    local _, err = store.apply_profiles({ entry })
    check(type(err) == "string" and err:find(case[2], 1, true) ~= nil,
        "reject " .. case[2], err)
    check(type(err) == "string" and err:find("vm-bad", 1, true) ~= nil,
        "the rejection names the alias: " .. case[2], err)
end

--------------------------------------------------------------------------
-- 7. 成环判定：批内 + 跨批（root ruling 4）
--------------------------------------------------------------------------
reset_env()
local _, chain1 = store.apply_profiles({
    { model = "vm-p1", target = "vm-p2" },
    { model = "vm-p2", target = "test-model" },
})
check(type(chain1) == "string" and chain1:find("must not be another virtual model", 1, true) ~= nil,
    "an alias targeting a sibling alias in the same batch is refused", chain1)
check(type(chain1) == "string" and (chain1:find("vm-p1", 1, true) ~= nil or chain1:find("vm-p2", 1, true) ~= nil),
    "the chain error names one of the two aliases", chain1)
eq(#store.profiles_list(), 0, "the refused batch wrote nothing")

reset_env()
local _, seed_err = store.apply_profiles({ { model = "vm-p2", target = "test-model" } })
eq(seed_err, nil, "the first-batch alias lands")
local _, chain2 = store.apply_profiles({ { model = "vm-p1", target = "vm-p2" } })
check(type(chain2) == "string" and chain2:find("must not be another virtual model", 1, true) ~= nil,
    "targeting an alias created by an earlier batch is refused", chain2)
eq(#store.profiles_list(), 1, "the rejected replace left the table untouched")
eq(store.profiles_list()[1].model, "vm-p2", "the surviving row is the old one")
local _, chain3 = store.apply_profiles({
    { model = "vm-p2", target = "test-model" },
    { model = "vm-p1", target = "another-model" },
})
eq(chain3, nil, "aliasing real models is fine")
eq(#store.profiles_list(), 2, "both rows landed")
-- 别名之间互指（互相引用）也被同一规则挡住
local _, chain4 = store.apply_profiles({
    { model = "vm-x", target = "vm-y" },
    { model = "vm-y", target = "vm-x" },
})
check(type(chain4) == "string", "mutual aliases are refused", chain4)

--------------------------------------------------------------------------
-- 8. 向后兼容：旧 config.json 与旧 LMR_VIRTUAL_MODELS
--------------------------------------------------------------------------
reset_env()
local legacy_doc = {
    virtual_models = { { model = "vm-a", target = "test-model" } },
    default_effort = "medium",
    model_ctx = { { model = "test-model", ctx = 8192 } },
}
local legacy_cfg, legacy_err = store.cfg_from_document(cjson.decode(cjson.encode(legacy_doc)))
eq(legacy_err, nil, "a legacy {model,target} document loads")
eq(legacy_cfg and legacy_cfg.virtual_models["vm-a"], "test-model", "the alias->target map still works")
eq(legacy_cfg and legacy_cfg.virtual_profiles["vm-a"].target, "test-model", "the profile view is derived")
eq(legacy_cfg and rawget(legacy_cfg.virtual_profiles["vm-a"], "workers"), nil, "no workers invented")
eq(legacy_cfg and legacy_cfg.default_effort, "medium", "the untouched sections still parse")
eq(legacy_cfg and legacy_cfg.model_ctx["test-model"], 8192, "model_ctx still parses")

-- 完全没有 upstreams 键的历史快照：渲染 []，不引入密钥字段
reset_env()
local historical = cjson.decode(cjson.encode({
    default_effort = NULL, effort_map = {}, model_ctx = {}, model_effort = {},
    model_configs = {}, virtual_models = { { model = "old", target = "test-model" } },
}))
local hist_cfg, hist_err = store.cfg_from_document(historical)
eq(hist_err, nil, "a pre-upstreams snapshot loads")
eq(hist_cfg and #hist_cfg.upstreams, 0, "a snapshot without upstreams has none")
local hist_text = cjson.encode(store.snapshot_of(hist_cfg))
check(hist_text:find('"upstreams":%[%]', 1) ~= nil, "the legacy snapshot renders upstreams as []")

-- env 层：LMR_VIRTUAL_MODELS 的 alias=target 对 == 新形状（可选字段省略）
reset_env()
_G.LMR_ENV_CACHE.LMR_VIRTUAL_MODELS = "fast:qwen3-30b, code:test-model"
local env_cfg = store.env_defaults()
local env_virtual = {}
for _, row in ipairs(env_cfg.virtual_models) do env_virtual[row.model] = row end
eq(env_virtual["fast"] and env_virtual["fast"].target, "qwen3-30b", "the env alias resolves to its target")
eq(env_virtual["fast"] and rawget(env_virtual["fast"], "policy"), nil, "the env alias carries no policy")
eq(store.resolve_model("fast"), "qwen3-30b", "resolve_model still maps the env alias")
local pairs_list = store.virtual_models_list()
eq(#pairs_list, 2, "virtual_models_list keeps its pair shape")
eq(pairs_list[1] and pairs_list[1][1], "code", "the pair list is sorted by alias")
eq(pairs_list[1] and #pairs_list[1], 2, "each pair is {alias, target}")
reset_env()

--------------------------------------------------------------------------
-- 9. LMR_UPSTREAMS_FILE 作为 env 层种子
--------------------------------------------------------------------------
reset_env()
write_file(SEED_PATH, cjson.encode({ { url = "http://seed-a.invalid:8080", model_id = "seed-model" } }))
_G.LMR_ENV_CACHE.LMR_UPSTREAMS_FILE = SEED_PATH
reset_state(true)
local seeded = store.current().upstreams
eq(#seeded, 1, "the env seed file contributes one upstream")
eq(seeded[1] and seeded[1].url, "http://seed-a.invalid:8080", "the seeded url is normalized")
eq(seeded[1] and seeded[1].model_id, "seed-model", "the seeded model_id survives")
local seed_summary = store.reconcile_upstreams()
eq(seed_summary.added, 1, "the seed reconciles into the pool")

write_file(SEED_PATH, cjson.encode({ upstreams = { { url = "http://seed-b.invalid:8080" } } }))
reset_state(true)
eq(store.current().upstreams[1].url, "http://seed-b.invalid:8080", "the wrapped {upstreams:[...]} shape works")

-- 缺文件 / 坏 JSON / 标量 = 无种子，绝不报错
unlink(SEED_PATH)
reset_state(true)
eq(#store.current().upstreams, 0, "a missing seed file means no upstreams")
write_file(SEED_PATH, "{not json")
reset_state(true)
eq(#store.current().upstreams, 0, "a broken seed file means no upstreams")
write_file(SEED_PATH, cjson.encode("a string"))
reset_state(true)
eq(#store.current().upstreams, 0, "a scalar seed file means no upstreams")
write_file(SEED_PATH, cjson.encode({ { url = "ftp://nope.invalid" }, { url = "http://mixed.invalid" } }))
reset_state(true)
eq(#store.current().upstreams, 1, "one bad seed row does not sink the good ones")
unlink(SEED_PATH)
reset_env()

--------------------------------------------------------------------------
-- 10. 快照 / 磁盘往返：脱敏 document -> apply_document -> 声明层等价
--------------------------------------------------------------------------
reset_env()
store.apply_profiles({
    { model = "vm-full", target = "test-model", workers = { A }, policy = "bucket", effort = "medium" },
    { model = "vm-plain", target = "other-model" },
})
store.apply_upstreams({
    { url = A, model_id = "test-model", api_key = SECRET, priority = 70, cost = 2.5,
      labels = { gpu = "l40" }, disable_health_check = true },
    { url = B, model_id = "sink-model" },
})
local round_doc = store.document()
local round_virtual = cjson.decode(cjson.encode(round_doc.virtual_models))
local round_ups = {}
for _, row in ipairs(round_doc.upstreams) do
    round_ups[#round_ups + 1] = {
        url = row.url,
        model_id = (row.model_id ~= NULL) and row.model_id or nil,
        api_key = row.api_key,
        priority = row.priority, cost = row.cost, labels = row.labels,
        disable_health_check = row.disable_health_check,
    }
end
local rebuilt, rebuilt_err = store.cfg_from_document({
    default_effort = round_doc.default_effort,
    effort_map = round_doc.effort_map,
    model_ctx = round_doc.model_ctx,
    model_effort = round_doc.model_effort,
    model_configs = round_doc.model_configs,
    virtual_models = round_virtual,
    policy = round_doc.policy,
    model_policies = round_doc.model_policies,
    upstreams = round_ups,
}, (function()
    -- previous 的入参形状是 url -> 行（previous_upstream_map 的产物），不是数组
    local by_url = {}
    for _, row in ipairs(store.current().upstreams) do by_url[row.url] = row end
    return by_url
end)())
eq(rebuilt_err, nil, "the masked document rebuilds cleanly")
eq(rebuilt and rebuilt.virtual_profiles["vm-full"].policy, "bucket", "policy survives the round-trip")
eq(rebuilt and rebuilt.virtual_profiles["vm-full"].effort, "medium", "effort survives the round-trip")
eq(rebuilt and #rebuilt.virtual_profiles["vm-full"].workers, 1, "workers survive the round-trip")
eq(rebuilt and rawget(rebuilt.virtual_profiles["vm-plain"], "workers"), nil, "an unset field stays unset")
eq(rebuilt and #rebuilt.upstreams, 2, "both upstreams survive the round-trip")
eq(rebuilt and rebuilt.upstreams[1].api_key_stored, SECRET, "the key survives via the declaration layer")
eq(rebuilt and rebuilt.upstreams[2].api_key_state, "keep", "an ownerless row stays keep")

-- 落盘再读回：与内存视图一致（写盘走 LMR_CONFIG_FILE）
local f = io.open(CONFIG_PATH, "r")
ok(f ~= nil, "the snapshot is persisted to LMR_CONFIG_FILE")
if f then
    local text = f:read("*a")
    f:close()
    check(text:find(SECRET, 1, true) ~= nil, "the disk copy carries the stored key once")
    check(text:find('"discovery"', 1, true) == nil, "the config snapshot never writes pool fields")
    local disk_snap = cjson.decode(text)
    eq(disk_snap.upstreams[1].api_key, NULL, "the on-disk api_key field is masked")
    eq(disk_snap.upstreams[1].api_key_stored, SECRET, "the on-disk persistence field holds the key")
    eq(disk_snap.virtual_models[1].policy, "bucket", "the profile is persisted")
    eq(disk_snap.virtual_models[2].model, "vm-plain", "the second profile is persisted")
end
shared.luarouter_config:flush_all()
store._reset_pool_module_caches()
local from_disk = store.current()
eq(from_disk.upstreams[1].api_key_stored, SECRET, "reloaded from disk with the key intact")
eq(from_disk.virtual_profiles["vm-full"].policy, "bucket", "reloaded from disk with the profile intact")
eq(from_disk.virtual_models["vm-plain"], "other-model", "the alias map reloaded too")
-- 坏文件不炸：写坏后 current() 退回 env 层
write_file(CONFIG_PATH, "{definitely not json")
store._reset_pool_module_caches()
local after_bad = store.current()
eq(#after_bad.upstreams, 0, "a corrupt snapshot falls back to the env layer")
unlink(CONFIG_PATH)
reset_env()

--------------------------------------------------------------------------
-- 11. 保留 readers（**不再驱动转发**）：profile_for / profile_policy / profile_effort
--
-- root ruling 2026-10-02 把 per-alias 的 policy / effort 从热路径上摘掉了：虚拟模型是
-- 对下游的服务主入口、一对多映射一组实际模型，而 policy/effort 描述的是**某一个引擎**，
-- 挂在入口名上对组里任何一个模型都不诚实。字段的现在的地位是：
--   * 仍被接受、仍落盘、仍从磁盘读回（本节钉住"没被人删的东西不会凭空消失"）；
--   * 这两个 store reader 仍原样答题（保留 API，不是热路径入口）；
--   * 转发路径**一个字都不读**它们 —— 那是下面 11b 节的事，断言打在 router.lua 的
--     真源码上。
-- 所以本节刻意**不再**用 "applies" / "wins" / "restores the profile" 这类词：那是在
-- 说这些字段驱动了行为，而它们不驱动。改名之前已核实全仓除本文件外无调用者
-- （rg profile_policy|profile_effort 只命中 config_store 的两处定义；router 用的是
--  profile_policy_name / profile_effort_value 这两个自己的 seam）。
--------------------------------------------------------------------------
reset_env()
eq(store.profile_for("nope"), nil, "profile_for is nil for a real model")
eq(store.profile_for(nil), nil, "profile_for tolerates nil")
eq(store.profile_for(""), nil, "profile_for tolerates the empty string")
eq(store.profile_for(42), nil, "profile_for tolerates a number")
eq(store.profile_policy("nope"), nil, "profile_policy is nil for an unknown name")
eq(store.profile_policy(nil), nil, "profile_policy tolerates nil")
eq(store.profile_policy(""), nil, "profile_policy tolerates the empty string")
eq(store.profile_policy(7), nil, "profile_policy tolerates a number")
eq(store.profile_effort("nope", "other"), nil, "profile_effort is nil without an override")
eq(store.profile_effort(nil, nil), nil, "profile_effort tolerates nils")

store.apply_profiles({
    { model = "vm-a", target = "target-model", policy = "prefix_hash", effort = "low" },
    { model = "vm-b", target = "shared-target" },
})
eq(store.profile_policy("vm-a"), "prefix_hash",
    "the retained policy reader answers for the alias (round-trip only, see 11b)")
eq(store.profile_policy("vm-b"), nil, "the retained policy reader is nil when unset")
eq(store.profile_policy(store.profile_for("vm-a")), "prefix_hash",
    "the retained policy reader accepts a profile table")
eq(store.profile_policy({ policy = "bogus" }), nil,
    "the retained policy reader drops an unknown stored name")
eq(store.profile_policy({ policy = 12 }), nil,
    "the retained policy reader drops a non-string stored name")

-- 返回的是副本：调用方改不坏活动快照
local p1 = store.profile_for("vm-a")
p1.workers = { "tampered" }
p1.target = "tampered"
local p2 = store.profile_for("vm-a")
eq(p2.target, "target-model", "the live snapshot is immune to caller writes")
eq(store.profiles_list()[1].target, "target-model", "profiles_list is immune too")

-- 保留 reader 内部的优先级（契约 3.3 的形状）：强制 model_effort > alias profile >
-- resolved profile。这条链路现在是**孤立**的：热路径的 effort 走落点模型自己的卡
-- （11b(d) 用真源码钉住），所以这里钉的是"若将来恢复一个 per-entry 旋钮，它接哪"。
eq(store.profile_effort("vm-a", "target-model"), "low",
    "the retained effort reader answers the alias profile value")
store.apply_effort({ model_effort = { { model = "vm-a", effort = "ultra" } } })
eq(store.profile_effort("vm-a", "target-model"), "ultra",
    "a forced model_effort row outranks the alias value inside the reader")
store.apply_effort({ model_effort = {} })
eq(store.profile_effort("vm-a", "target-model"), "low",
    "clearing the forced row returns the reader to the stored alias value")

store.apply_profiles({
    { model = "vm-a", target = "target-model", policy = "prefix_hash", effort = "low" },
    { model = "vm-b", target = "shared-target" },
})
eq(store.profile_effort("vm-b", "shared-target"), nil, "no override anywhere is nil")
store.apply_effort({ model_effort = { { model = "shared-target", effort = "max" } } })
eq(store.profile_effort("vm-b", "shared-target"), "max", "the resolved target's forced effort applies")
store.apply_effort({ model_effort = {} })
-- alias 与 resolved 双键，先命中先用
store.apply_profiles({
    { model = "vm-a", target = "target-model", policy = "prefix_hash", effort = "low" },
    { model = "vm-c", target = "target-model", effort = "minimal" },
})
store.apply_effort({ model_effort = { { model = "vm-c", effort = "high" } } })
eq(store.profile_effort("vm-c", "target-model"), "high", "the alias forced row beats the profile")
store.apply_effort({ model_effort = { { model = "target-model", effort = "none" },
                                       { model = "vm-c", effort = "high" } } })
eq(store.profile_effort("vm-c", "target-model"), "high", "the alias key is checked first")
store.apply_effort({ model_effort = {} })

-- readers 只读 current() 快照：连读同值，且不因上一批写入而漂移
eq(store.profile_policy("vm-a"), "prefix_hash", "the policy reader repeats")
eq(store.profile_policy("vm-a"), "prefix_hash", "and is stable across calls")
eq(store.profile_effort("vm-c", "target-model"), "minimal",
    "the retained effort reader still answers from the stored field")
reset_env()


--------------------------------------------------------------------------
-- 11b. 热路径 seams：per-alias policy / effort 已停用（root ruling 2026-10-02）
--
-- 上一节钉的是**磁盘与 reader 层**：字段还在、还往返、两个保留 reader 仍答题。
-- 这一节钉的是**转发层**：router 一个字都不读那两个字段。手法同
-- test/unit/test_caps_routing.lua —— 按导出语句把 router.lua 的**真实现**切出来配桩
-- 加载，所以断言跑在盘上那份代码上：把 profile_policy_name 改回 return profile.policy
-- 就会让这里变红（变异验证见 /data/tmp/lr-vm/mutate_seams.py 的输出）。
--
-- 为什么不能只断言 seam 返回 nil：它现在就是一行 return nil，照抄一份断言等于自我
-- 实现。真正有判别力的是 policy_for 的**分支形状** —— 停用之前 profile.policy 会让它
-- 走 forced 分支（第二次 policy_mod.new 带上 name）而根本不问 for_model；停用之后它
-- 必须问 for_model。stub 分别记下"建过哪些实例"和"问过哪些 key"，两件事实同时钉住。
--------------------------------------------------------------------------
local function verify_hot_path_seams()
    local lib = os.getenv("LUA_TEST_LIB") or "./lualib"
    -- 2026-10-05 拆分（doc/refactor-arch-2026-10-05.md §1）：热路径的七块真实现分别
    -- 住在 router/profiles.lua 与 router/candidates.lua，锚点字符串一个都不动，只换
    -- 源码文件；子模块不在时逐块回退整只 router.lua（旧树对照走的正是这条）。
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
    local src_profiles = read_src("profiles.lua")
    local src_candidates = read_src("candidates.lua")
    if type(src_profiles) ~= "string" or type(src_candidates) ~= "string" then
        failed[#failed + 1] = "cannot read router sources for the hot-path slice"
        return
    end
    local function slice(from_pat, to_pat, name)
        -- 家族归位：策略桶名 / 组 hint / card_key / policy_for 在 candidates，
        -- profile 停用缝与 is_array_table 一族在 profiles；两处锚点文本各自唯一，
        -- 切片仍逐字命中真实现。
        local src = (name == "card_key_for" or name == "key_name" or name == "hint"
            or name == "policy_for") and src_candidates or src_profiles
        local blk = src:match("(" .. from_pat .. ".-)" .. to_pat)
        if type(blk) ~= "string" then
            failed[#failed + 1] = "router source slice missing: " .. name
            return "local _missing_" .. name .. " = nil"
        end
        return blk
    end

    local asked, built
    local policy_stub = {
        instances = {},
        new = function(_conf, opts)
            built[#built + 1] = (type(opts) == "table" and opts.name) or "-"
            return { policy_name = function() return "stub" end,
                     restore_snapshot = function() end }
        end,
        generation = function() return 1 end,
        start_eviction = function() end,
        for_model = function(_conf, key, hint, has_workers)
            asked[#asked + 1] = { key = key, hint = hint, hw = has_workers }
            return { policy_name = function() return "stub" end,
                     restore_snapshot = function() end }
        end,
    }
    local hint_by_model = {}
    local records_fn
    local reg_stub = {
        records = function() return records_fn() end,
        policy_hint_for_model = function(m) return hint_by_model[m], 1 end,
        candidate_allows_model = function() return true end,
    }
    records_fn = function() return {} end
    -- is_array_table 不写替身。它是 profile_model_group 判"这是不是一组模型"的依据，
    -- 用替身等于把判定换成我自己的理解 —— 替身写 n>0、真实现写 n==#v，稀疏表在两者下
    -- 结果不同，而这种差异正是守卫要挡的东西。区间 [is_array_table, _M.profile_worker_list)
    -- 恰好只含 is_array_table / profile_model_group / profile_worker_list 三个函数，
    -- 整块切真实现（锚点用导出语句：在两函数间插新函数不会把块切坏）。
    local chunk_src = table.concat({
        "local _M = {}",
        "local _unused_is_array_table, registry, policy_mod, cfg = ...",
        "local profile_policy_name, profile_effort_value, profile_model_group",
        "local group_key_name, group_policy_hint, default_policy",
        slice("local function card_key_for", "_M%.card_key_for", "card_key_for"),
        slice("profile_policy_name = function", "_M%.profile_policy_name", "policy_name"),
        slice("profile_effort_value = function", "local function field_pattern", "effort_value"),
        slice("local function is_array_table", "_M%.profile_worker_list", "is_array_and_group"),
        slice("group_key_name = function", "%-%-%-The labels%.policy hint", "key_name"),
        slice("group_policy_hint = function", "_M%.group_policy_hint", "hint"),
        slice("local function policy_for", "_M%.policy_for", "policy_for"),
        "return { card_key_for = card_key_for," ..
        " profile_policy_name = profile_policy_name," ..
        " profile_effort_value = profile_effort_value," ..
        " profile_model_group = profile_model_group," ..
        " group_key_name = group_key_name, group_policy_hint = group_policy_hint," ..
        " policy_for = policy_for }",
    }, "\n")
    local compiled, load_err = load(chunk_src, "profiles_hot_seams", "t", _G)
    if not compiled then
        failed[#failed + 1] = "hot-path slice did not compile: " .. tostring(load_err)
        return
    end
    local HN = compiled(nil, reg_stub, policy_stub,
        function() return { policy = "round_robin" } end)
    if type(HN) ~= "table" then
        failed[#failed + 1] = "hot-path slice returned no table"
        return
    end
    -- 把切出来的真实现交给组语义一节复用（同一次切片，两处断言）。
    local seams = HN

    -- (a) 同一个 profile 上，保留 reader 答题、热路径 seam 答 nil：两行**同时**绿才叫
    --     "字段还在但不再驱动转发"，一起坏掉只会证明模块没加载。
    reset_env()
    store.apply_profiles({
        { model = "vm-dead", target = "target-model", policy = "prefix_hash", effort = "ultra" },
    })
    local dead = store.profile_for("vm-dead")
    ok(dead ~= nil, "11b(a) the row with retired fields stored")
    eq(dead and dead.policy, "prefix_hash", "11b(a) the field is really there to be ignored")
    eq(store.profile_policy("vm-dead"), "prefix_hash",
        "11b(a) the retained store reader still answers for it")
    eq(store.profile_effort("vm-dead", "target-model"), "ultra",
        "11b(a) and so does the retained effort reader")
    eq(HN.profile_policy_name(dead), nil, "11b(a) the router seam ignores the stored policy")
    eq(HN.profile_effort_value(dead, "vm-dead", "target-model"), nil,
        "11b(a) the router seam ignores the stored effort")
    -- 组入口（1 对多的主用法）同样接不回来：这里是将来最容易被"顺手恢复"的地方。
    store.apply_profiles({
        { model = "vm-dead", targets = { "target-model", "other-model" },
          policy = "prefix_hash", effort = "ultra" },
    })
    local gdead = store.profile_for("vm-dead")
    ok(HN.profile_model_group(gdead) ~= nil, "11b(a) the same row really is a group entry")
    eq(gdead and gdead.policy, "prefix_hash", "11b(a) a group row keeps its stored policy field")
    eq(HN.profile_policy_name(gdead), nil, "11b(a) a group entry cannot re-enable the alias policy")
    eq(HN.profile_effort_value(gdead, "vm-dead", "target-model"), nil,
        "11b(a) a group entry cannot re-enable the alias effort")

    -- (b) policy_for 的分支形状：legacy 行带 policy 字段也必须走 for_model。
    reset_env()
    -- 必须让模型**有** hint，否则 policy_for 按既有语义直接返回共享的 default 实例、
    -- 根本不问 for_model，那条分支就什么都没测到（第一版如此，被自己的断言照了出来）。
    hint_by_model = { ["target-model"] = "cache_aware" }
    store.apply_profiles({ { model = "vm-seam", target = "target-model", policy = "bucket" } })
    local seam = store.profile_for("vm-seam")
    asked, built = {}, {}
    local inst = HN.policy_for("target-model", seam)
    ok(inst ~= nil, "11b(b) policy_for still answers")
    eq(#built, 1, "11b(b) only the global default instance was built")
    eq(built[1], "-", "11b(b) that build carried no alias-level policy name")
    -- asked[1] 要先判空再取字段：若哪天 alias 的 policy 被重新接回热路径，policy_for 会
    -- 走 forced 分支**根本不调** for_model，那时 asked 是空的 —— 直接索引会让整个文件
    -- 崩在这里（崩溃也红，但没有 FAIL 行，变异验证就没法说"是哪条断言抓到的"）。
    eq(asked[1] and asked[1].key, "target-model",
        "11b(b) the retired field does not short-circuit the for_model chain")
    eq(asked[1] and asked[1].hint, "cache_aware",
        "11b(b) it reaches for_model with the per-model hint, not an alias-level name")

    -- (c) 组模式一棵亲和树：key 是**入口名**。两个入口映射同一组模型时必须各自一棵树 ——
    --     这是 1 对多最常见的形状，也最容易因"key 退化成组头/落点名"而静默串台。
    reset_env()
    store.apply_profiles({
        { model = "svc-one", targets = { "grp-a", "grp-b" } },
        { model = "svc-two", targets = { "grp-a", "grp-b" } },
    })
    local one = store.profile_for("svc-one")
    local two = store.profile_for("svc-two")
    ok(HN.profile_model_group(one) ~= nil, "11b(c) entry one is in group mode")
    asked, built = {}, {}
    HN.policy_for("grp-a", one)
    HN.policy_for("grp-b", one)
    HN.policy_for("grp-a", two)
    eq(#asked, 3, "11b(c) three passes each asked for an instance")
    eq(asked[1] and asked[1].key, "svc-one", "11b(c) the group keys by the entry name")
    eq(asked[2] and asked[2].key, "svc-one",
        "11b(c) the landing model does not move the tree within an entry")
    eq(asked[3] and asked[3].key, "svc-two",
        "11b(c) a second entry over the SAME group gets its own tree")
    ok(asked[1] ~= nil and asked[3] ~= nil and asked[1].key ~= asked[3].key,
        "11b(c) two entries never share an affinity tree")
    eq(asked[1] and type(asked[1].hw), "boolean",
        "11b(c) has_workers is a boolean (for_model compares == false)")
    -- hint 取自**整组**第一个活着的 record：入口名不出现在任何 record 里，按名字问恒 nil。
    records_fn = function()
        return { { id = "w1", url = A, model_id = "grp-a", labels = { policy = "cache_aware" } } }
    end
    asked = {}
    HN.policy_for("grp-a", store.profile_for("svc-one"))
    eq(asked[1] and asked[1].hint, "cache_aware", "11b(c) the hint comes from the group's workers")
    eq(asked[1] and asked[1].hw, true, "11b(c) a group with a live worker reports true")
    records_fn = function() return {} end
    asked = {}
    HN.policy_for("grp-a", store.profile_for("svc-one"))
    eq(asked[1] and asked[1].hw, false,
        "11b(c) an emptied group reports false so the eviction rule can fire")

    -- (d) effort / ctx 卡的**查找键跟着落点模型走**（裁定"effort 属于模型卡"的落点）。
    --     绑定的模型名优先于 profile.target 与 resolved，所以给入口写 effort 既不生效、
    --     也不会盖住落点模型自己的卡。断言打在真 card_key_for 上。
    local bound_prof = { model = "svc-k", target = "grp-head",
        candidates = { { worker = A, model = "m-one" }, { worker = B, model = "m-two" } } }
    eq(HN.card_key_for(bound_prof, "svc-k", nil, "m-two"), "m-two",
        "11b(d) the selected binding names the card")
    eq(HN.card_key_for(bound_prof, "svc-k", { lr_bound_model = "m-one" }, nil), "m-one",
        "11b(d) a binding carried by the record names the card")
    eq(HN.card_key_for(bound_prof, "svc-k", nil, nil), "grp-head",
        "11b(d) before selection a bindings row falls back to the declared target")
    eq(HN.card_key_for({ model = "svc-p", target = "real" }, "real", nil, nil), "real",
        "11b(d) an unbound row keeps the pre-feature key (zero behaviour change)")
    reset_env()
    return seams
end

--------------------------------------------------------------------------
-- 11c. 虚拟模型 = 服务主入口（1 对多）的契约（root ruling 2026-10-02）
--
-- 语义反转后一个条目说的是"这个入口对外提供**哪一组**实际模型"，选路在组内做；条目上
-- 唯一允许的覆盖是 context_window（2026-10-04 裁定后它是**对外声明的上下文总窗口**，
-- 不再参与任何 max_tokens 计算；热路径的钳制已整体删除，见 router.lua 的
-- apply_ctx_cap 恒等空壳）。本组钉的是 config_store 仍保留 ctx_cap /
-- virtual_ctx_cap 两个读数（UI 与 doc 按名字引用），不是热路径拿它改写请求体。
-- 本节按六组钉住：
--   (1) 新形状解析：targets 多值 + context_window；target 单值是"长度为 1 的组"，
--       只在读侧归一，磁盘上不许凭空长出 targets；
--   (2) 向后兼容：纯 {model,target}、candidates-only、LMR_VIRTUAL_MODELS env 种子三条
--       旧路径的 profile_model_group 一律 nil（组门不触发 = 既有部署逐字节不变）；
--   (3) 校验拒绝：空/非数组/非字符串/空白成员、非正整数 context_window、组内出现另一个
--       入口名、绑定名不在组内、同一实例绑两个不同模型；
--   (4) 快照往返：apply -> list -> apply -> document -> cfg_from_document 两轮不丢字段
--       也不长幻影字段（explicit_targets / explicit_target 决定回写与否）；
--   (5) 派生组优先级：显式 targets > target 与各候选绑定名的并集（target 恒首位）> nil，
--       以及"候选缺省 model 只能继承操作员写过的名字"这条顺序无关性；
--   (6) virtual_models 降级为**派生只读视图**：virtual_profiles 是唯一事实来源。
--
-- 判组开关（explicit_targets）与转发名的推导都在 router.lua 里，所以 (2)(5) 的断言复用
-- 11b 那一次真源码切片：桩化的判定函数永远不会红，真实现才会。
--------------------------------------------------------------------------
local function verify_group_semantics(HN)
    local function rg(t, k)
        if type(t) ~= "table" then return nil end
        return rawget(t, k)
    end
    local function row_of(rows, m)
        for _, row in ipairs(rows or {}) do
            if row.model == m then return row end
        end
        return nil
    end
    local function cnd(worker, model) return { worker = worker, model = model } end

    ---------------------------------------------------------------- (1) 新形状解析
    reset_env()
    local _, s1 = store.apply_profiles({
        { model = "svc-main", targets = { "glm-4", "qwen3-30b" }, context_window = 32768 },
    })
    eq(s1, nil, "(1) an explicit group is accepted")
    local p1 = store.profile_for("svc-main")
    ok(p1 ~= nil, "(1) profile_for answers for the entry")
    eq(p1 and p1.model, "svc-main", "(1) the profile carries its own entry name")
    eq(rg(p1, "explicit_targets"), true, "(1) explicit_targets records that the operator wrote it")
    eq(rg(p1, "targets") and #p1.targets, 2, "(1) the group has both models")
    eq(p1 and p1.targets[1], "glm-4", "(1) the declared order is kept")
    eq(p1 and p1.target, "glm-4", "(1) the representative is the group head")
    eq(p1 and p1.context_window, 32768, "(1) the only allowed per-entry override stored")
    eq(store.virtual_targets("svc-main") and #store.virtual_targets("svc-main"), 2,
        "(1) virtual_targets reports the group")
    store.apply_model_config({ model = "glm-4", ctx = 131072 })
    store.apply_model_config({ model = "qwen3-30b", ctx = 8192 })
    -- 统一钳制：clamp 是**入口**的属性而不是"策略挑了哪台"的函数。不写 override 时取整组
    -- 最小卡（更宽会让最窄的引擎拒收，而且值会随落点抖动）；写下的那个直接赢、忽略所有卡。
    eq(store.virtual_ctx_cap(p1), 32768,
        "(1) an explicit context_window wins outright over every card")
    store.apply_profiles({ { model = "svc-main", targets = { "glm-4", "qwen3-30b" } } })
    eq(store.virtual_ctx_cap(store.profile_for("svc-main")), 8192,
        "(1) without an override the clamp is the group minimum (uniform, never per-pick)")
    -- 组缩到一个名字时 clamp 交还给**落点模型自己的卡**：组里只有一个引擎，卡本身就是
    -- 统一答案，入口层再插一层反而会让"删掉第二个模型"这种普通修改悄悄改掉钳制值。
    store.apply_profiles({ { model = "svc-main", targets = { "glm-4" } } })
    eq(store.virtual_ctx_cap(store.profile_for("svc-main")), nil,
        "(1) a group of one defers to the landing model's own card")
    eq(store.ctx_cap("glm-4"), 131072, "(1) and that card still answers its own name")
    eq(store.virtual_ctx_cap({ model = "svc-x", explicit_targets = true,
        targets = { "glm-4", "qwen3-30b" }, context_window = 4096 }), 4096,
        "(1) an explicit context_window wins outright over every card")

    -- target 单值 = 长度为 1 的组：读侧归一，写侧**绝不**回写。
    reset_env()
    local _, s1b = store.apply_profiles({ { model = "svc-one", target = "solo-model" } })
    eq(s1b, nil, "(1) a lone target still parses (it is the group of one it always was)")
    local p1b = store.profile_for("svc-one")
    eq(p1b and #p1b.targets, 1, "(1) the reader normalizes a lone target into a group of one")
    eq(p1b and p1b.targets[1], "solo-model", "(1) the derived group carries the target")
    eq(rg(p1b, "explicit_targets"), nil, "(1) a derived group is NOT group mode")
    local r1b = store.profiles_list()[1]
    eq(rg(r1b or {}, "targets"), nil, "(1) the emitted row grows no targets key nobody wrote")
    check(cjson.encode(r1b):find('"targets"', 1, true) == nil,
        "(1) the encoded legacy row never mentions targets")

    ---------------------------------------------------------------- (2) 向后兼容旗标
    -- 这三行是整个改动的安全旗标：旧形状一旦被误判成组模式，policy 树的 key 与引擎模型门
    -- 会同时挪位，等于给没提过要求的既有部署改了行为（设计红线）。
    reset_env()
    store.apply_profiles({ { model = "vm-legacy", target = "real-legacy" } })
    eq(HN.profile_model_group(store.profile_for("vm-legacy")), nil,
        "(2) a pure {model,target} row never enters group mode")
    reset_env()
    store.apply_profiles({
        { model = "vm-bound", target = "real-legacy",
          candidates = { cnd(A, "real-legacy"), cnd(B, "other-real") } },
    })
    eq(HN.profile_model_group(store.profile_for("vm-bound")), nil,
        "(2) a candidates-only row never enters group mode (last round's shape still routes)")
    reset_env()
    _G.LMR_ENV_CACHE.LMR_VIRTUAL_MODELS = "env-a:real-a,env-b:real-b"
    reset_state(true)
    eq(store.resolve_model("env-a"), "real-a", "(2) the env seed still maps the alias")
    local envp = store.profile_for("env-a")
    eq(envp and envp.target, "real-a", "(2) the env profile keeps its target")
    eq(rg(envp, "explicit_targets"), nil, "(2) an env pair is not group mode")
    eq(HN.profile_model_group(envp), nil, "(2) the env seed never enters group mode")
    eq(store.virtual_ctx_cap(envp), nil, "(2) the env entry takes no clamp")
    local erow = row_of(store.env_defaults().virtual_models, "env-a")
    eq(rg(erow or {}, "targets"), nil, "(2) the env snapshot grows no targets key")
    reset_env()

    ---------------------------------------------------------------- (3) 校验拒绝
    -- 每条都要求 err 是 string（拒绝），且措辞落在被钉住的家族里；拒绝后不得留半行配置。
    local rejects = {
        { { model = "vc-1", targets = "not-an-array" }, "must be an array of strings" },
        { { model = "vc-2", targets = cjson.decode("[123]") }, "must be strings" },
        { { model = "vc-3", targets = { "ok", 42 } }, "must be strings" },
        { { model = "vc-4", targets = { "ok", "  " } }, "must not be blank" },
        { { model = "vc-5", targets = { "ok" }, context_window = 0 }, "positive integer" },
        { { model = "vc-6", targets = { "ok" }, context_window = -8 }, "positive integer" },
        { { model = "vc-7", targets = { "ok" }, context_window = 1.5 }, "positive integer" },
        { { model = "vc-8", targets = { "ok" }, context_window = "many" }, "positive integer" },
        { { model = "vc-9", targets = { "ok" }, context_window = false }, "positive integer" },
    }
    for _, case in ipairs(rejects) do
        reset_env()
        local _, err = store.apply_profiles({ case[1] })
        check(type(err) == "string", "(3) rejected " .. case[1].model, err)
        check(type(err) == "string" and err:find(case[2], 1, true) ~= nil,
            "(3) wording mentions " .. case[2] .. " for " .. case[1].model, err)
        eq(#store.profiles_list(), 0, "(3) the rejected batch wrote nothing (" .. case[1].model .. ")")
    end
    -- 链守卫：组里任何一名都不得是另一个入口（防虚拟名链式转发）。
    reset_env()
    local _, chain1 = store.apply_profiles({
        { model = "vc-base", target = "real-base" },
        { model = "vc-top", targets = { "vc-base", "real-base" } },
    })
    check(type(chain1) == "string"
        and chain1:find("another virtual model", 1, true) ~= nil,
        "(3) a group member naming another entry is rejected", chain1)
    reset_env()
    local _, chain2 = store.apply_profiles({ { model = "vc-self", targets = { "vc-self", "x" } } })
    check(type(chain2) == "string", "(3) a group that names itself is rejected", chain2)
    -- 跨批（引用**存量**入口）也要挡住：只查本批的话，分两次保存就能拼出一条虚拟名链，
    -- 转发体里就会出现一个上游根本不认识的模型名。
    reset_env()
    store.apply_profiles({ { model = "vc-live", target = "real-live" } })
    local _, chain3 = store.apply_profiles({ { model = "vc-top2", targets = { "vc-live", "real-live" } } })
    check(type(chain3) == "string" and chain3:find("another virtual model", 1, true) ~= nil,
        "(3) a group member naming a live entry from an earlier batch is rejected", chain3)
    eq(#store.profiles_list(), 1, "(3) the rejected cross-batch row left nothing behind")
    -- 空数组：按"未声明"处理而不是"声明了零个模型"。当后者会得到一个永远 503 的入口，
    -- 当前者继续走 target 路径 —— 一个可用的入口胜过一份看起来合法的坏配置。
    reset_env()
    local _, ea_err = store.apply_profiles({ { model = "vc-empty", targets = {} } })
    check(type(ea_err) == "string" and ea_err:find("needs a target model", 1, true) ~= nil,
        "(3) an empty targets array with nothing else is refused", ea_err)
    reset_env()
    local _, eb_err = store.apply_profiles({ { model = "vc-empty2", targets = {}, target = "real-x" } })
    eq(eb_err, nil, "(3) an empty targets array alongside a target degrades to the target path")
    local ep = store.profile_for("vc-empty2")
    eq(rg(ep, "explicit_targets"), nil, "(3) and the empty array does not claim group mode")
    eq(HN.profile_model_group(ep), nil, "(3) so the hot path still sees no group")
    -- 内部标记还得能在**磁盘形状**上被看到：空数组若被当成"写过 targets"，发射器会因
    -- explicit_targets 为真而**不写** target、只写一个空数组 —— 那行下次读回就没有落点了。
    -- （这条断言是变异 empty-array-is-a-group 第一次存活时补的：当时只断言了行为、
    --  没断言形状，那个缺陷在公开 API 上确实无从观测。）
    local erow = store.profiles_list()[1]
    eq(rg(erow or {}, "targets"), nil, "(3) the empty array is not emitted as a written group")
    eq(erow and erow.target, "real-x", "(3) and the row keeps the target it will read back as")
    local _, ereapply = store.apply_profiles({ erow })
    eq(ereapply, nil, "(3) the emitted row re-applies cleanly (no self-poisoned round-trip)")

    -- 手改磁盘的文档必须**降级**而不是打挂热路径：写侧校验只在 apply 时起作用，磁盘上
    -- 一份坏形状不能让选路崩。profile_model_group 返回 nil 的含义就是"这不是组条目"，
    -- 请求于是照旧路径转发 —— 半份声明好过一个 500。
    -- 这组也是真 is_array_table 唯一能被观测的地方：替身写成 n>0 时，稀疏表
    -- targets[1]="a", targets[3]="b" 在替身下是数组、在真实现下不是（n==#v 不成立）。
    local dirty_cases = {
        { model = "d1", explicit_targets = true, targets = "not-an-array" },
        { model = "d2", explicit_targets = true, targets = {} },
        { model = "d3", explicit_targets = true, targets = { "a", 42 } },
        { model = "d4", explicit_targets = true, targets = { "a", "" } },
        { model = "d5", explicit_targets = true, targets = { [1] = "a", [3] = "b" } },
        { model = "d6", explicit_targets = true, targets = { a = "x" } },
        { model = "d7", explicit_targets = true },
        { model = "d8" },
        { model = "d9", targets = { "ok1", "ok2" }, explicit_targets = true },
    }
    for _, dirty in ipairs(dirty_cases) do
        local name = dirty.model
        if name == "d9" then
            ok(HN.profile_model_group(dirty) ~= nil,
                "(3) a well-formed hand-edited row still selects as a group: " .. name)
            eq(#HN.profile_model_group(dirty), 2, "(3) and hands both names to selection: " .. name)
        else
            eq(HN.profile_model_group(dirty), nil,
                "(3) a hand-edited row degrades to not-a-group instead of crashing: " .. name)
        end
    end
    -- 同一份脏行的重复名要在**选路层**再去重（写侧去重管不到手改的磁盘）：两个同名模型
    -- 会造出两个候选、两遍亲和记账。
    eq(#HN.profile_model_group({ model = "d10", explicit_targets = true,
        targets = { "dup", "dup", "keep" } }), 2,
        "(3) selection-level dedup still applies to a hand-edited row")

    -- 入口名与模型卡重名：裁定"只能配 context_window 以便对下游保持统一"的**唯一**绕过
    -- 途径，就是有人给入口那个名字写了张卡 —— ctx_cap 按落点名查卡的话，同一个请求落在
    -- A 与落在 B 会拿到两个 max_tokens，正是裁定要消除的抖动。所以入口名必须对卡片查找
    -- **隐身**。两种写入顺序都要测：只查一张表的守卫会漏掉另一种。
    reset_env()
    store.apply_profiles({ { model = "svc-clash", targets = { "cl-a", "cl-b" } } })
    store.apply_model_config({ model = "svc-clash", ctx = 4096 })
    ok(store.current().virtual_profiles["svc-clash"] ~= nil,
        "(1) precondition: the clashing name really is an entry")
    eq(store.ctx_cap("svc-clash"), nil,
        "(1) entry written first: the entry name never answers a card lookup")
    eq(store.virtual_ctx_cap(store.profile_for("svc-clash")), nil,
        "(1) a card under the entry name cannot become the entry clamp")
    reset_env()
    store.apply_model_config({ model = "svc-later", ctx = 2048 })
    eq(store.ctx_cap("svc-later"), 2048, "(1) precondition: a plain name does answer")
    store.apply_profiles({ { model = "svc-later", targets = { "la", "lb" } } })
    eq(store.ctx_cap("svc-later"), nil,
        "(1) card written first: once the name is an entry it stops answering")
    reset_env()
    store.apply_profiles({ { model = "svc-keep", target = "real-k" } })
    store.apply_model_config({ model = "real-k", ctx = 9216 })
    eq(store.ctx_cap("real-k"), 9216,
        "(1) a real model name still answers its own card (the guard is entry-name only)")
    eq(store.virtual_ctx_cap(store.profile_for("svc-keep")), nil,
        "(1) a legacy single-target entry leaves clamping to the per-pick card")
    -- 绑定名必须在组内：写错一个字母会把流量钉到一个必然 404 的实例上，必须当场报错。
    reset_env()
    local _, bind_out = store.apply_profiles({
        { model = "vc-bo", targets = { "in-a", "in-b" },
          candidates = { cnd(A, "typo-model") } },
    })
    check(type(bind_out) == "string" and bind_out:find("not one of its targets", 1, true) ~= nil,
        "(3) a binding outside the group is rejected by name", bind_out)
    -- 同一实例绑两个不同模型 = 必须报错（"最后一条说了算"会悄悄改变路由）；
    -- 同一条重复提交则静默去重。
    reset_env()
    local _, dup_two = store.apply_profiles({
        { model = "vc-dup", targets = { "p", "q" },
          candidates = { cnd(A, "p"), cnd(A, "q") } },
    })
    check(type(dup_two) == "string" and dup_two:find("two models", 1, true) ~= nil,
        "(3) one worker bound to two models is refused", dup_two)
    reset_env()
    local _, dup_same = store.apply_profiles({
        { model = "vc-dup2", targets = { "p" },
          candidates = { cnd(A, "p"), cnd(A, "p") } },
    })
    eq(dup_same, nil, "(3) an identical repeated binding dedupes instead of refusing")
    eq(store.profile_for("vc-dup2") and #store.profile_for("vc-dup2").candidates, 1,
        "(3) the duplicate collapsed to one binding")

    ---------------------------------------------------------------- (4) 快照往返两轮
    reset_env()
    store.apply_model_config({ model = "mm-a", ctx = 131072 })
    store.apply_profiles({
        { model = "svc-rt", targets = { "mm-a", "mm-b" }, context_window = 20000,
          candidates = { cnd(A, "mm-a"), cnd(B, "mm-b") } },
        { model = "svc-rt-legacy", target = "mm-a" },
    })
    local emitted = store.profiles_list()
    local rt = row_of(emitted, "svc-rt")
    ok(rt ~= nil, "(4) the group row is emitted")
    eq(type(rt.targets) == "table" and #rt.targets, 2, "(4) targets round-trip through the list")
    eq(rt and rt.context_window, 20000, "(4) context_window round-trips")
    eq(rt and rt.candidates and #rt.candidates, 2, "(4) candidates round-trip")
    eq(rt and rawget(rt, "target"), nil, "(4) a written-targets row emits no derived target")
    local _, rt2_err = store.apply_profiles(emitted)
    eq(rt2_err, nil, "(4) re-applying the emitted list is accepted")
    local after2 = store.profile_for("svc-rt")
    eq(after2 and #after2.targets, 2, "(4) still 1-to-N after the second write")
    eq(after2 and after2.context_window, 20000, "(4) the override survives the second write")
    eq(rg(after2, "explicit_targets"), true, "(4) group mode survives the second write")
    local doc = store.document()
    local drow = row_of(doc.virtual_models, "svc-rt")
    ok(drow ~= nil, "(4) document() carries the row")
    eq(type(drow.targets) == "table" and #drow.targets, 2, "(4) the authoritative JSON view keeps the group")
    eq(drow and drow.context_window, 20000, "(4) and the override")
    local dleg = row_of(doc.virtual_models, "svc-rt-legacy")
    eq(rg(dleg or {}, "targets"), nil, "(4) the legacy row's JSON view grows no phantom group")
    eq(dleg and dleg.target, "mm-a", "(4) the legacy row keeps its written target")
    -- 已停用的 per-alias 字段必须**留在**权威 JSON 视图里：操作员没删过的东西不能在
    -- 一次查看/保存后凭空消失（那是"配了却丢"，比不显示更糟）。它同时是"字段还在但
    -- 不再驱动转发"这半句话的另一只脚 —— 只断言 reader 答题而视图不保留，就等于字段
    -- 实际上已经丢了。
    store.apply_profiles({ { model = "svc-rt-legacy", target = "mm-a",
        policy = "prefix_hash", effort = "low" } })
    local dret = row_of(store.document().virtual_models, "svc-rt-legacy")
    eq(dret and dret.policy, "prefix_hash",
        "(4) the authoritative JSON view keeps a retired policy field")
    eq(dret and dret.effort, "low", "(4) and the retired effort field")
    eq(store.profile_policy("svc-rt-legacy"), "prefix_hash",
        "(4) the retained reader still answers for it after a document round-trip")
    eq(HN.profile_policy_name(store.profile_for("svc-rt-legacy")), nil,
        "(4) while the hot path still ignores the same stored value")
    local rebuilt, rb_err = store.cfg_from_document({ virtual_models = doc.virtual_models })
    eq(rb_err, nil, "(4) the document re-reads cleanly")
    local rp = rebuilt and rebuilt.virtual_profiles and rebuilt.virtual_profiles["svc-rt"]
    eq(rp and #rp.targets, 2, "(4) the re-read row is still a group")
    eq(rg(rp, "explicit_targets"), true, "(4) the re-read row keeps group mode")
    eq(rebuilt and rebuilt.virtual_models["svc-rt"], "mm-a",
        "(4) the derived alias view matches the group head")
    -- 删掉 targets 是"退回 legacy"，不是留一份幻影组。
    reset_env()
    store.apply_profiles({ { model = "svc-dl", targets = { "d1", "d2" }, context_window = 1024 } })
    local _, dl_err = store.apply_profiles({ { model = "svc-dl", target = "d-only" } })
    eq(dl_err, nil, "(4) rewriting without targets is accepted")
    local p10 = store.profile_for("svc-dl")
    eq(p10 and p10.target, "d-only", "(4) the new target is explicit")
    eq(rg(p10, "explicit_targets"), nil, "(4) group mode is gone once targets are not written")
    eq(rg(p10, "context_window"), nil, "(4) a deleted context_window does not resurrect")
    eq(store.current().virtual_models["svc-dl"], "d-only",
        "(4) the derived view follows the rewrite (no stale representative)")

    ---------------------------------------------------------------- (5) 派生组优先级
    -- 显式 targets 决定组的**内容与顺序**，候选声明顺序改不了它。为什么这样测而不是
    -- "绑一个组外模型看它会不会被并进来"：组外绑定在 (3) 就被硬拒了，根本走不到派生组，
    -- 所以"显式组不被加宽"在公开 API 上是**不可观测**的（第一版正是这样，被变异验证照成
    -- 只有 (3) 变红）。真正能被观测、也真正会坏的是"显式顺序被候选顺序覆盖"。
    reset_env()
    store.apply_profiles({
        { model = "svc-prio", targets = { "t2", "t1" }, target = "stale-name",
          candidates = { cnd(A, "t1"), cnd(B, "t2") } },
    })
    local prio = store.profile_for("svc-prio")
    eq(prio and type(prio.targets) == "table" and #prio.targets, 2,
        "(5) a written targets array is not widened by the union path")
    eq(prio and prio.targets[1], "t2", "(5) the written order leads, not the candidate order")
    eq(prio and prio.targets[2], "t1", "(5) and both written names survive in written order")
    eq(prio and prio.target, "stale-name",
        "(5) the stale written target stays on the row untouched (disk bytes are the operator's)")
    eq(store.current().virtual_models["svc-prio"], "t2",
        "(5) but the derived view self-heals to the group head instead of chasing it")
    eq(store.resolve_model("svc-prio"), "t2", "(5) so resolve_model never forwards the stale name")
    eq(store.profiles_list()[1].targets[1], "t2", "(5) the emitted row keeps the written order")
    local names = {}
    for _, n in ipairs((prio and prio.targets) or {}) do names[n] = true end
    eq(names["stale-name"], nil, "(5) a target outside the written group never joins the group")
    -- 没写 targets 时：并集 = target + 各候选绑定名，target 恒首位（凡"必须挑一个代表名"
    -- 的旧读者读到的还是组头，与上一轮逐字节一致）。
    reset_env()
    store.apply_profiles({
        { model = "svc-union", target = "t0",
          candidates = { cnd(A, "c1"), cnd(B, "c2"), cnd("http://c:8000", "c1") } },
    })
    local uni = store.profile_for("svc-union")
    eq(uni and #uni.targets, 3, "(5) the derived union is target + distinct binding names")
    eq(uni and uni.targets[1], "t0", "(5) the written target leads the union")
    eq(rg(uni, "explicit_targets"), nil, "(5) a derived union never claims group mode")
    eq(HN.profile_model_group(uni), nil, "(5) and the hot path agrees it is not a group")
    -- 候选缺省 model 的继承源只能是"操作员亲口写过的名字"，不能是兄弟候选的名字：
    -- 否则同一份配置换个顺序就得到不同落点。两种顺序都要测。
    reset_env()
    local _, inh_err = store.apply_profiles({
        { model = "svc-inh", candidates = { cnd(A, "sib"), cnd(B) } },
    })
    check(type(inh_err) == "string" and inh_err:find("needs a model", 1, true) ~= nil,
        "(5) a model-less binding does not inherit a sibling's model", inh_err)
    reset_env()
    local _, inh_err2 = store.apply_profiles({
        { model = "svc-inh", candidates = { cnd(B), cnd(A, "sib") } },
    })
    check(type(inh_err2) == "string" and inh_err2:find("needs a model", 1, true) ~= nil,
        "(5) the same refusal regardless of candidate order", inh_err2)
    reset_env()
    store.apply_profiles({ { model = "svc-head", targets = { "h1", "h2" },
        candidates = { cnd(A), cnd(B, "h2") } } })
    local headp = store.profile_for("svc-head")
    eq(headp and headp.candidates and headp.candidates[1].model, "h1",
        "(5) a model-less binding inherits the group head the operator wrote")
    reset_env()
    store.apply_profiles({ { model = "svc-wt", target = "written",
        candidates = { cnd(A), cnd(B, "second") } } })
    local wtp = store.profile_for("svc-wt")
    eq(wtp and wtp.candidates and wtp.candidates[1].model, "written",
        "(5) with no written targets it inherits the written target instead")

    ---------------------------------------------------------------- (6) 派生只读视图
    -- virtual_models 不再是第二份可写状态：它必须永远由 virtual_profiles 派生，否则
    -- resolve_model / /v1/models / 模型文档三处会各自读到不同的一张（幻影别名）。
    reset_env()
    store.apply_profiles({ { model = "svc-view", targets = { "v1", "v2" } } })
    eq(store.current().virtual_models["svc-view"], "v1",
        "(6) the derived view carries the group head, not a second stored value")
    local vlist = store.virtual_models_list()
    local vrow
    for _, row in ipairs(vlist) do
        if row[1] == "svc-view" then vrow = row end
    end
    ok(vrow ~= nil, "(6) the entry is listed for the /v1/models advertiser")
    eq(vrow and #vrow, 3, "(6) the row is alias + the whole group (variadic, not a pair)")
    eq(vrow and vrow[2], "v1", "(6) the advertised group starts at the head")
    store.apply_profiles({})
    eq(#store.profiles_list(), 0, "(6) the profile table cleared")
    eq(store.current().virtual_models["svc-view"], nil,
        "(6) the derived view clears with it (no phantom alias survives)")
    eq(store.resolve_model("svc-view"), "svc-view",
        "(6) resolve_model stops mapping a removed entry")
    eq(store.virtual_targets("svc-view"), nil,
        "(6) virtual_targets reports no entry rather than an empty group")
    reset_env()
end

local vm_seams = verify_hot_path_seams()
verify_group_semantics(vm_seams)

--------------------------------------------------------------------------
-- 12. 端点语义：ui 桥 -> handle_config_virtual / handle_config_upstreams /
--      handle_config_apply（400 带 error 文本、200 带顶层 reconcile 键）
--------------------------------------------------------------------------
local captured, captured_body
_G.ngx.say = function(text) captured[#captured + 1] = text end
_G.ngx.exit = function(status) return status end
_G.ngx.req.get_body_data = function() return captured_body end
local function request_body(value)
    if value == nil then captured_body = nil
    elseif type(value) == "string" then captured_body = value
    else captured_body = cjson.encode(value) end
end
local ui = require "resty.luarouter.ui"
local function call_handler(fn)
    captured = {}
    _G.ngx.status = nil
    fn()
    return _G.ngx.status, cjson.decode(captured[1] or "")
end

-- ---- /config/virtual --------------------------------------------------
reset_env()
request_body({ entries = { { model = "vm-h", target = "test-model", workers = { A },
                             policy = "power_of_two", effort = "minimal" } } })
local status, payload = call_handler(ui.config_virtual)
eq(status, 200, "POST /config/virtual answers 200")
local h_row = find_row(payload and payload.virtual_models, "vm-h")
ok(h_row ~= nil, "the response echoes the profile")
eq(h_row and h_row.policy, "power_of_two", "the echoed profile carries the policy")
eq(h_row and h_row.effort, "minimal", "the echoed profile carries the effort")
ok(h_row and h_row.workers and h_row.workers[1] == A, "the echoed profile carries the workers",
    h_row and h_row.workers and tostring(h_row.workers[1]))

request_body({ entries = { { model = "vm-old-shape", target = "test-model" } } })
status, payload = call_handler(ui.config_virtual)
eq(status, 200, "an old-shape {model,target} entry still answers 200")
local o_row = find_row(payload and payload.virtual_models, "vm-old-shape")
eq(o_row and o_row.target, "test-model", "the old shape keeps model and target")
eq(o_row and rawget(o_row, "policy"), nil, "the old shape echoes no policy field")

-- entries 缺失 = 全清（root ruling 3，与既有 handle_config_virtual 一致）
request_body({})
status, payload = call_handler(ui.config_virtual)
eq(status, 200, "POST /config/virtual without entries answers 200")
eq(type(payload.virtual_models) == "table" and #payload.virtual_models, 0,
    "missing entries cleared the table")

request_body({ entries = { { model = "vm-same", target = "vm-same" } } })
status, payload = call_handler(ui.config_virtual)
eq(status, 400, "a self-alias through the endpoint is 400")
check(type(payload) == "table" and type(payload.error) == "string" and payload.error ~= "",
    "the 400 body explains itself", payload and payload.error)
eq(#store.profiles_list(), 0, "the 400 wrote nothing")
request_body(nil)
eq(call_handler(ui.config_virtual), 400, "an empty body is a 400")
request_body("{not json")
eq(call_handler(ui.config_virtual), 400, "broken JSON is a 400")
request_body("42")
eq(call_handler(ui.config_virtual), 400, "a scalar body is a 400, never a 500")
request_body(cjson.decode("null"))
eq(call_handler(ui.config_virtual), 400, "a JSON null body is a 400, never a 500")

-- ---- /config/upstreams ------------------------------------------------
reset_env()
request_body({ entries = { { url = A, model_id = "test-model", api_key = SECRET },
                           { url = B, model_id = "sink-model" } } })
status, payload = call_handler(ui.config_upstreams)
eq(status, 200, "POST /config/upstreams answers 200")
local summary = payload and payload.reconcile
ok(type(summary) == "table", "the response carries a top-level reconcile bag")
eq(summary and summary.added, 2, "the summary counts the two adds")
eq(summary and summary.updated, 0, "the summary counts no updates")
eq(summary and summary.removed, 0, "the summary counts no removals")
eq(summary and summary.skipped, 0, "the summary counts no skips")
local up_row = payload.upstreams[1]
eq(up_row.api_key, NULL, "the endpoint response masks the key")
eq(up_row.has_api_key, true, "the endpoint response exposes has_api_key")
eq(rawget(up_row, "api_key_stored"), nil, "the endpoint response hides the stored key")
eq(up_row.priority, 50, "the response shows the stored priority default")
eq(up_row.cost, 1.0, "the response shows the stored cost default")
eq(type(up_row.labels) == "table", true, "the response always carries a labels map")
check(cjson.encode(payload):find(SECRET, 1, true) == nil, "no secret on the wire")

request_body({ entries = { { url = A, model_id = "test-model", api_key = SECRET },
                           { url = B, model_id = "sink-model" } } })
status, payload = call_handler(ui.config_upstreams)
eq(status, 200, "a resubmit answers 200")
eq(cjson.encode({ payload.reconcile.added, payload.reconcile.updated,
                  payload.reconcile.removed, payload.reconcile.skipped }), "[0,0,0,0]",
    "the resubmit reconciles nothing")

-- null 密钥重提交：200 而非 500，且不新增成员（契约 3.4 的 UI 侧口径）
request_body({ entries = { { url = A, model_id = "test-model", api_key = NULL },
                           { url = B, model_id = "sink-model" } } })
status, payload = call_handler(ui.config_upstreams)
eq(status, 200, "a null api_key resubmit answers 200, never 500")
eq(payload.reconcile.added, 0, "the null resubmit adds nobody")
local upd_after_null = payload.reconcile.updated
check(upd_after_null == 0 or upd_after_null == 1,
    "the null resubmit counts as updated=0 or 1", upd_after_null)
eq(payload.upstreams[1].api_key, NULL, "the response still hides the key")

request_body({ entries = { { url = "ftp://bad.invalid" } } })
status, payload = call_handler(ui.config_upstreams)
eq(status, 400, "a non-http scheme through the endpoint is 400")
check(type(payload.error) == "string" and payload.error:find("url", 1, true) ~= nil,
    "the 400 explains the url problem", payload and payload.error)
eq(#store.document().upstreams, 2, "the rejected batch left the pool alone")
request_body("42")
eq(call_handler(ui.config_upstreams), 400, "a scalar body is a 400, never a 500")
request_body(nil)
eq(call_handler(ui.config_upstreams), 400, "an empty body is a 400")
request_body({ entries = {} })
status, payload = call_handler(ui.config_upstreams)
eq(status, 200, "an explicit empty replace is accepted")
eq(payload.reconcile.removed, 2, "the empty replace reclaims exactly the config members")
request_body({})
status = call_handler(ui.config_upstreams)
eq(status, 200, "missing entries is an empty replace")
eq(#store.document().upstreams, 0, "the declaration layer is empty")

-- ---- /config/apply ----------------------------------------------------
reset_env()
request_body({
    virtual_models = { { model = "ap-a", target = "test-model", policy = "bucket",
                         effort = "medium", workers = cjson.decode("[]") } },
    upstreams = { { url = A, model_id = "test-model" } },
})
status, payload = call_handler(ui.config_apply)
eq(status, 200, "POST /config/apply with both new sections answers 200")
local ap_row = find_row(payload and payload.virtual_models, "ap-a")
eq(ap_row and ap_row.policy, "bucket", "apply echoes the profile")
eq(ap_row and ap_row.effort, "medium", "apply echoes the effort")
ok(type(payload.reconcile) == "table", "apply reports the reconcile it performed")
eq(payload.reconcile.added, 1, "apply counts the new pool member")
eq(record_of(A) and record_of(A).discovery, "config", "apply really projected into the pool")

request_body({ default_effort = "high" })
status, payload = call_handler(ui.config_apply)
eq(status, 200, "a config-only apply answers 200")
eq(rawget(payload, "reconcile"), nil, "an apply that reconciled nothing omits the key")
eq(payload.default_effort, "high", "the config-only save took effect")

request_body({ upstreams = { { url = A }, { url = A .. "/" } } })
status, payload = call_handler(ui.config_apply)
eq(status, 400, "a duplicate url inside apply is refused")
check(type(payload.error) == "string", "the apply 400 explains itself", payload and payload.error)
eq(store.document().default_effort, "high", "the refused apply left the document alone")

request_body({ virtual_models = { { model = "ap-chain", target = "ap-a" } } })
status = call_handler(ui.config_apply)
eq(status, 200, "an alias to a real model through apply is accepted")
request_body({ virtual_models = { { model = "ap-chain", target = "ap-a" },
                                  { model = "ap-a", target = "test-model" } } })
status, payload = call_handler(ui.config_apply)
eq(status, 400, "a chained alias inside apply is refused")
eq(find_row(payload and payload.virtual_models, "ap-chain"), nil,
    "the refused batch left the profile table alone")

-- 标量 / null body 绝不能变成一次成功的整文档清空。先写一份"有东西可清"的文档
-- （apply 是整文档替换，上一步只带 virtual_models 的提交本就会清掉别的段）
request_body({ default_effort = "high",
               upstreams = { { url = A, model_id = "test-model" } } })
status = call_handler(ui.config_apply)
eq(status, 200, "a full document saved before the refusal checks")
eq(store.document().default_effort, "high", "the document holds something worth keeping")
request_body("42")
status, payload = call_handler(ui.config_apply)
eq(status, 400, "a scalar body to apply is a 400")
eq(type(payload.error) == "string", true, "the 400 explains itself")
request_body(cjson.decode("null"))
eq(call_handler(ui.config_apply), 400, "a JSON null body to apply is a 400")
request_body(nil)
eq(call_handler(ui.config_apply), 400, "an empty body to apply is a 400")
eq(store.document().default_effort, "high", "none of the refused bodies wiped the document")

-- ---- GET /_ui/config 的键集合是旧断言的超集 -------------------------------
reset_env()
status, payload = call_handler(ui.config_get)
eq(status, 200, "GET /_ui/config answers 200")
for _, key in ipairs({ "default_effort", "effort_map", "model_ctx", "model_effort",
                       "model_configs", "virtual_models", "policy", "model_policies",
                       "env_defaults", "watcher", "persist", "models", "upstreams" }) do
    ok(rawget(payload, key) ~= nil, "GET /_ui/config still carries " .. key)
end
eq(type(payload.upstreams) == "table" and #payload.upstreams, 0,
    "an untouched upstreams section is an empty array")
check(captured[1]:find('"upstreams":%[%]') ~= nil,
    "GET renders an untouched upstreams section as []")
eq(type(payload.virtual_models) == "table" and #payload.virtual_models, 0,
    "an untouched virtual_models section is an empty array")
eq(payload.watcher.url, NULL, "the watcher section keeps its shape")

--------------------------------------------------------------------------
-- 13. 收尾：未映射的 ngx.re 模式必须为空（否则上面的替身在骗人）
--------------------------------------------------------------------------
local seen_pattern = {}
for _, entry in ipairs(unmapped_re) do
    if not seen_pattern[entry] then
        seen_pattern[entry] = true
        failed[#failed + 1] = "unmapped ngx.re pattern " .. entry
    end
end

for _, path in ipairs({ CONFIG_PATH, SEED_PATH }) do unlink(path) end
_G.ngx.say = nil
_G.ngx.exit = nil
print("profiles: " .. passed .. " passed, " .. #failed .. " failed")
if #failed > 0 then
    for i = 1, #failed do print("  FAIL " .. failed[i]) end
    os.exit(1)
end
