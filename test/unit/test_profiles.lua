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
-- 11. 热路径 readers：profile_for / profile_policy / profile_effort
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
eq(store.profile_policy("vm-a"), "prefix_hash", "profile_policy reads the alias override")
eq(store.profile_policy("vm-b"), nil, "profile_policy is nil when unset")
eq(store.profile_policy(store.profile_for("vm-a")), "prefix_hash", "profile_policy accepts a profile table")
eq(store.profile_policy({ policy = "bogus" }), nil, "profile_policy drops an unknown stored name")
eq(store.profile_policy({ policy = 12 }), nil, "profile_policy drops a non-string stored name")

-- 返回的是副本：调用方改不坏活动快照
local p1 = store.profile_for("vm-a")
p1.workers = { "tampered" }
p1.target = "tampered"
local p2 = store.profile_for("vm-a")
eq(p2.target, "target-model", "the live snapshot is immune to caller writes")
eq(store.profiles_list()[1].target, "target-model", "profiles_list is immune too")

-- effort 优先级（契约 3.3）：强制 model_effort > alias profile > resolved profile
eq(store.profile_effort("vm-a", "target-model"), "low", "the alias profile effort applies")
store.apply_effort({ model_effort = { { model = "vm-a", effort = "ultra" } } })
eq(store.profile_effort("vm-a", "target-model"), "ultra", "a forced model_effort on the alias wins")
store.apply_effort({ model_effort = {} })
eq(store.profile_effort("vm-a", "target-model"), "low", "clearing the forced row restores the profile")

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
eq(store.profile_effort("vm-c", "target-model"), "minimal", "the profile effort reader still works")
reset_env()

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
