#!/usr/bin/env resty
-- tokenizer.lua / parse.lua 单测：管理 API 状态机、输入校验、路由候选选择、
-- 代理请求构造。纯 Lua（resty CLI 里跑），不需要 shared dict 与 nginx。
--
--   docker run --rm -v "$PWD/..":/repo:ro -w /repo \
--     --entrypoint /usr/bin/resty apache/apisix:3.11.0-debian \
--     -e 'package.path="./lualib/?.lua;"..package.path
--         dofile("./test/unit/test_tokenizer_parse.lua")'
--
-- 替身三层：
--   1. ngx.shared.lr_workers —— 一张闭包表（tokenizer 的 job store 真跑）
--   2. package.loaded["resty.luarouter.registry"] —— mock worker 表 +
--      is_available 开关（候选选择/排序逻辑本身仍走被测代码）
--   3. 模块的 write_raw / raw_body / request 三个 seam —— 捕获响应、喂入请求、
--      记录并回放上游应答
-- 每个 case 前 reset() 重装替身，用例之间不共享状态。

package.path = (os.getenv("LUA_TEST_LIB") or "./lualib") .. "/?.lua;" .. package.path

local cjson = require "cjson.safe"

local tokenizer = require "resty.luarouter.tokenizer"
local parse = require "resty.luarouter.parse"

local passed, failed = 0, 0
local failures = {}

local function check(cond, name, detail)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = name .. (detail and (" -> " .. tostring(detail)) or "")
    end
end

local function eq(actual, expect, name)
    check(actual == expect, name,
        actual ~= expect and (tostring(actual) .. " ~= " .. tostring(expect)) or nil)
end

local function new_case(name)
    io.write("  case: " .. name .. "\n")
end

--- UUID v4 shape check in plain Lua (Lua patterns have no {n} repetition).
local HEX = "0123456789abcdef"
local function is_hex(text)
    for i = 1, #text do
        if not HEX:find(text:sub(i, i), 1, true) then
            return false
        end
    end
    return #text > 0
end
local function is_uuid4(id)
    if type(id) ~= "string" or #id ~= 36 then
        return false
    end
    local groups = {}
    for part in id:gmatch("[^-]+") do
        groups[#groups + 1] = part
    end
    local widths = { 8, 4, 4, 4, 12 }
    if #groups ~= 5 or id:find("-", 1, true) == nil
        or select(2, id:gsub("-", "")) ~= 4 then
        return false
    end
    for i = 1, 5 do
        if #groups[i] ~= widths[i] or not is_hex(groups[i]) then
            return false
        end
    end
    if groups[3]:sub(1, 1) ~= "4" then
        return false
    end
    return groups[4]:sub(1, 1):find("[89ab]", 1) ~= nil
end

--------------------------------------------------------------------------
-- 替身 1：shared dict（只实现 tokenizer 用到的 get/set/delete/incr）
--------------------------------------------------------------------------
local store
local dict_missing = false

local function fake_dict()
    return {
        get = function(_, key) return store[key] end,
        set = function(_, key, value) store[key] = value; return true end,
        delete = function(_, key) store[key] = nil; return true end,
        incr = function(_, key, delta, init)
            store[key] = (store[key] or init or 0) + delta
            return store[key]
        end,
    }
end

_G.ngx.shared = _G.ngx.shared or {}
setmetatable(_G.ngx.shared, { __index = function(_, key)
    if key ~= "lr_workers" or dict_missing then return nil end
    return fake_dict()
end })

--------------------------------------------------------------------------
-- 替身 2：worker 注册表
--------------------------------------------------------------------------
local workers = {}
local unavailable = {}

local function worker(url, opts)
    opts = opts or {}
    local record = {
        id = opts.id or url,
        url = url,
        model_id = opts.model_id or "m1",
        labels = opts.labels or {},
    }
    if opts.tokenizer_path then record.tokenizer_path = opts.tokenizer_path end
    if opts.tool_parser then record.tool_parser = opts.tool_parser end
    if opts.reasoning_parser then record.reasoning_parser = opts.reasoning_parser end
    if opts.api_key then record.api_key = opts.api_key end
    if opts.vocab_size then record.vocab_size = opts.vocab_size end
    workers[#workers + 1] = record
    return record
end

package.loaded["resty.luarouter.registry"] = {
    records = function() return workers end,
    is_available = function(id) return unavailable[id] ~= true end,
}

--------------------------------------------------------------------------
-- 替身 3：请求正文 / 响应写出 / 上游应答
--------------------------------------------------------------------------
local request_body = ""
local request_headers = {}
local responses = {}
local calls = {}
---回放队列：每次 _M.request 弹出一条（{status, headers, body} 或 {err=...}）
local replies = {}

local function reset()
    store = {}
    dict_missing = false
    workers = {}
    unavailable = {}
    responses = {}
    calls = {}
    replies = {}
    request_body = ""
    request_headers = { ["content-type"] = "application/json" }
    _G.ngx.req = {
        get_headers = function() return request_headers end,
    }
    local function instrument(mod)
        mod.raw_body = function() return request_body end
        mod.forward_headers = mod.forward_headers or nil
        mod.write_raw = function(status, body, content_type, headers)
            responses[#responses + 1] = {
                status = status, body = body, content_type = content_type,
                headers = headers or {},
            }
            return ""
        end
        mod.request = function(method, url, body, headers, timeout_ms)
            calls[#calls + 1] = {
                method = method, url = url, body = body, headers = headers,
                timeout_ms = timeout_ms,
            }
            local reply = table.remove(replies, 1)
            if not reply then
                return nil, nil, nil, "test: no reply queued"
            end
            if reply.err then
                return nil, nil, nil, reply.err
            end
            return reply.status, reply.headers or { ["content-type"] = "application/json" },
                reply.body or ""
        end
    end
    instrument(tokenizer)
    instrument(parse)
end

---最后一条写出的响应
local function response(index)
    return responses[index or #responses]
end

local function decoded(index)
    local r = response(index)
    if not r or not r.body then return nil end
    return cjson.decode(r.body)
end

local function ok200(body)
    replies = { { status = 200, body = body } }
end

--------------------------------------------------------------------------
new_case("前置：模块加载、seam 就位")
eq(type(tokenizer.handle_tokenize), "function", "tokenizer handlers exported")
eq(type(parse.handle_function_call), "function", "parse handlers exported")
reset()
eq(response(), nil, "reset clears captures")

--------------------------------------------------------------------------
-- tokenizer：/v1/tokenize 校验
--------------------------------------------------------------------------
new_case("tokenize: 非 JSON 对象 → 400 invalid_json")
reset()
request_body = "not json"
tokenizer.handle_tokenize({}, {}, {})
eq(response().status, 400, "tokenize bad json status")
eq(decoded().error.code, "invalid_json", "tokenize bad json code")
eq(response().headers["X-SMG-Error-Code"], "invalid_json", "tokenize error code header")
eq(#calls, 0, "tokenize bad json does not proxy")

new_case("tokenize: prompt 缺失/类型错误 → 400")
reset()
request_body = '{"model":"m1"}'
tokenizer.handle_tokenize({}, {}, {})
eq(response().status, 400, "tokenize missing prompt status")
eq(decoded().error.code, "invalid_request", "tokenize missing prompt code")
reset()
request_body = '{"prompt":42}'
tokenizer.handle_tokenize({}, {}, {})
eq(response().status, 400, "tokenize numeric prompt → 400")
reset()
request_body = '{"prompt":["a",3]}'
tokenizer.handle_tokenize({}, {}, {})
eq(response().status, 400, "tokenize array with non-string → 400")
reset()
request_body = '{"prompt":"hi","model":{"a":1}}'
tokenizer.handle_tokenize({}, {}, {})
eq(response().status, 400, "tokenize non-string model → 400")

new_case("detokenize: tokens 形状校验")
local bad_inputs = {
    { '{"model":"m1"}', "detokenize missing tokens → 400" },
    { '{"tokens":"1,2,3"}', "detokenize string tokens → 400" },
    { '{"tokens":[1,"x"]}', "detokenize non-numeric member → 400" },
    { '{"tokens":[-1]}', "detokenize negative token → 400" },
    { '{"tokens":[1.5]}', "detokenize fractional token → 400" },
    { '{"tokens":[4294967296]}', "detokenize token above u32 → 400" },
    { '{"tokens":[[1,2],3]}', "detokenize mixed shapes → 400" },
    { '{"tokens":[[1,"2"]]}' , "detokenize nested non-numeric → 400" },
    { '{"tokens":[1,2],"skip_special_tokens":"yes"}', "detokenize non-bool flag → 400" },
}
for i = 1, #bad_inputs do
    reset()
    request_body = bad_inputs[i][1]
    tokenizer.handle_detokenize({}, {}, {})
    eq(response().status, 400, bad_inputs[i][2])
    eq(decoded().error.code, "invalid_request", bad_inputs[i][2] .. " code")
end

new_case("valid_tokens: 单序列/批/空数组接受")
eq(tokenizer.valid_tokens({ 1, 2, 3 }), true, "single sequence accepted")
eq(tokenizer.valid_tokens({ { 1, 2 }, { 3 } }), true, "batch accepted")
eq(tokenizer.valid_tokens({}), true, "empty array accepted (Rust accepts it too)")
local _, verr = tokenizer.valid_tokens("nope")
check(type(verr) == "string" and #verr > 0, "valid_tokens reports a message", verr)

--------------------------------------------------------------------------
-- tokenizer：无 tokenizer 后端 → 501
--------------------------------------------------------------------------
new_case("tokenize: 没有声称支持 tokenizer 的 worker → 501")
reset()
request_body = '{"model":"m1","prompt":"hi"}'
tokenizer.handle_tokenize({}, {}, {})
eq(response().status, 501, "tokenize 501 without backend")
eq(decoded().error.message, "tokenizer backend unavailable", "tokenize 501 message")
eq(decoded().error.code, "tokenizer_unavailable", "tokenize 501 code")
eq(response().headers["X-SMG-Error-Code"], "tokenizer_unavailable", "501 error-code header")
reset()
worker("http://plain")            -- 注册了但没有任何 tokenizer 声明
request_body = '{"model":"m1","prompt":"hi"}'
tokenizer.handle_tokenize({}, {}, {})
eq(response().status, 501, "plain worker is not a tokenizer backend")
reset()
request_body = '{"model":"m1","tokens":[1,2]}'
tokenizer.handle_detokenize({}, {}, {})
eq(response().status, 501, "detokenize 501 without backend")

--------------------------------------------------------------------------
-- tokenizer：候选选择
--------------------------------------------------------------------------
new_case("tokenizer_claim: 记录字段、标签、限定式声明")
eq(tokenizer.tokenizer_claim({ labels = {} }), nil, "no claim → nil")
eq(tokenizer.tokenizer_claim({ tokenizer_path = "qwen-tok" }), "qwen-tok", "record field wins")
eq(tokenizer.tokenizer_claim({ labels = { tokenizer_path = "/models/tok" } }),
    "/models/tok", "discovered label")
eq(tokenizer.tokenizer_claim({ labels = { tokenizer = "true" } }), "*",
    "unqualified label → *")
eq(tokenizer.tokenizer_claim({ labels = { tokenizer_id = "glm" } }), "glm", "tokenizer_id label")
eq(tokenizer.vocab_size_for({ labels = { vocab_size = "151643" } }), 151643,
    "vocab size from labels")
eq(tokenizer.vocab_size_for({ labels = {} }), nil, "no vocab advertised → nil")

new_case("tokenizer_candidates: 打分与精确名优先")
worker("http://tok-exact", { labels = { tokenizer = "qwen2.5" } })
worker("http://tok-any", { labels = { tokenizer = "true" } })
worker("http://tok-other", { labels = { tokenizer = "llama3" } })
worker("http://plain")
local ranked = tokenizer.tokenizer_candidates("qwen2.5")
eq(#ranked, 3, "only claiming workers are candidates")
eq(ranked[1].record.url, "http://tok-exact", "exact-name claim ranks first")
eq(ranked[1].score, 2, "exact-name score 2")
for i = 1, #ranked do
    check(ranked[i].record.url ~= "http://plain", "plain worker never in the list",
        ranked[i].record.url)
end
local picked = tokenizer.pick_tokenizer_worker("qwen2.5")
eq(picked.url, "http://tok-exact", "pick prefers the exact claim")
local unqualified = tokenizer.pick_tokenizer_worker(nil)
check(unqualified ~= nil and unqualified.url ~= "http://plain",
    "pick without a model still returns a claimant", unqualified and unqualified.url)
local misses = tokenizer.tokenizer_candidates("no-such-tokenizer")
for i = 1, #misses do
    eq(misses[i].score == 2, false, "no exact match → nothing scores 2")
end

new_case("tokenizer_candidates: 熔断/不健康的 worker 被排除")
reset()
worker("http://tok-down", { labels = { tokenizer = "qwen2.5" } })
unavailable["http://tok-down"] = true
eq(tokenizer.pick_tokenizer_worker("qwen2.5"), nil, "unavailable claimant is skipped")

new_case("bound_backends: 管理 job 的 source 指向 worker URL 即完成绑定")
reset()
local bound_url = "http://10.0.0.5:8000"
worker(bound_url, { model_id = "unknown" })
store["tok:ids"] = "job-1"
store["tok:job:job-1"] = cjson.encode({
    id = "job-1", name = "deepseek-v3", source = bound_url,
    status = "pending", created_at = 0, updated_at = 0,
})
local bounds = tokenizer.bound_backends(tokenizer.worker_records(), tokenizer.list_jobs())
eq(bounds[bound_url] and bounds[bound_url][1].name, "deepseek-v3", "job binds a name to the url")
local cand = tokenizer.tokenizer_candidates("deepseek-v3")
eq(cand[1].record.url, bound_url, "bound worker is a candidate")
eq(cand[1].score, 2, "bound name scores as an exact match")
eq(tokenizer.pick_tokenizer_worker("deepseek-v3").url, bound_url, "pick uses the binding")

--------------------------------------------------------------------------
-- tokenizer：代理请求构造
--------------------------------------------------------------------------
new_case("tokenize: 代理到 worker 同路径，字节原样转发")
reset()
worker("http://tok-a", { labels = { tokenizer = "qwen2.5" }, api_key = "sekret" })
request_body = '{"model":"qwen2.5","prompt":["a","b"]}'
request_headers = {
    ["content-type"] = "application/json",
    ["x-request-id"] = "req-7",
    ["authorization"] = "Bearer caller",
    ["cookie"] = "session=1",
    ["content-length"] = "40",
}
ok200('{"tokens":[[1,2],[3]],"count":[2,1],"char_count":[1,1]}')
tokenizer.handle_tokenize({}, {}, {})
eq(#calls, 1, "tokenize proxies once")
eq(calls[1].method, "POST", "proxy method")
eq(calls[1].url, "http://tok-a/v1/tokenize", "proxy path mirrors the request path")
eq(calls[1].body, request_body, "proxy forwards the original bytes")
eq(calls[1].headers["x-request-id"], "req-7", "x-request-id forwarded")
eq(calls[1].headers["authorization"], "Bearer caller", "caller authorization wins")
eq(calls[1].headers["cookie"], nil, "cookie not forwarded")
eq(calls[1].headers["content-length"], nil, "content-length not copied from the client")
eq(calls[1].headers["accept-encoding"], "identity", "identity requested upstream")
check(type(calls[1].timeout_ms) == "number" and calls[1].timeout_ms > 0,
    "proxy carries a timeout", calls[1].timeout_ms)
eq(response().status, 200, "proxied 200 passed through")
eq(cjson.decode(response().body).count[1], 2, "proxied body passed through verbatim")

new_case("tokenize: worker 无 api_key 时用记录里的 key 补 authorization")
reset()
worker("http://tok-b", { labels = { tokenizer = "llama3" }, api_key = "wk-key" })
request_body = '{"model":"llama3","prompt":"hi"}'
request_headers = { ["content-type"] = "application/json" }
ok200('{"tokens":[1],"count":1,"char_count":2}')
tokenizer.handle_tokenize({}, {}, {})
eq(calls[1].headers["authorization"], "Bearer wk-key", "worker key injected")

new_case("detokenize: 代理 + 上游非 2xx 透传状态")
reset()
worker("http://tok-c", { labels = { tokenizer = "glm" } })
request_body = '{"model":"glm","tokens":[[1,2],[3]]}'
replies = { { status = 400, body = '{"error":{"message":"bad token"}}' } }
tokenizer.handle_detokenize({}, {}, {})
eq(calls[1].url, "http://tok-c/v1/detokenize", "detokenize proxies its own path")
eq(response().status, 400, "upstream 400 forwarded")
eq(cjson.decode(response().body).error.message, "bad token", "upstream message preserved")
eq(response().headers["X-SMG-Error-Code"], "backend_error", "backend_error code stamped")

new_case("proxy: 上游连接失败 → 502 tokenizer_backend_error")
reset()
worker("http://tok-d", { labels = { tokenizer = "deepseek" } })
request_body = '{"model":"deepseek","prompt":"hi"}'
replies = { { err = "connect failed: timeout" } }
tokenizer.handle_tokenize({}, {}, {})
eq(response().status, 502, "connect failure is 502")
eq(decoded().error.code, "tokenizer_backend_error", "backend error code")
check(response().body:find("connect failed", 1, true) ~= nil, "backend error carries cause")

new_case("proxy: tokenizer 名字不匹配时选到 exact 而非任意声明")
reset()
worker("http://tok-any", { labels = { tokenizer = "true" } })
worker("http://tok-glm", { labels = { tokenizer = "glm4" } })
request_body = '{"model":"glm4","prompt":"hi"}'
ok200('{"tokens":[1],"count":1,"char_count":2}')
tokenizer.handle_tokenize({}, {}, {})
eq(calls[1].url, "http://tok-glm/v1/tokenize", "exact-name backend chosen")

--------------------------------------------------------------------------
-- tokenizer：管理 API（状态机）
--------------------------------------------------------------------------
new_case("POST /v1/tokenizers: 校验与 202 形状")
reset()
request_body = '{"name":"qwen2.5","source":"/models/qwen2.5"}'
tokenizer.handle_add_tokenizer({}, {}, {})
eq(response().status, 202, "add returns 202")
local added = decoded()
eq(added.status, "pending", "job starts pending")
eq(type(added.id) == "string" and #added.id == 36, true, "id is a 36-char uuid")
check(is_uuid4(added.id), "id is a v4 uuid", added.id)
check(added.message:find("Loading from: /models/qwen2.5", 1, true) ~= nil,
    "202 message names the source", added.message)
eq(added.vocab_size, nil, "vocab_size omitted before completion")

reset()
request_body = '{"source":"/models/x"}'
tokenizer.handle_add_tokenizer({}, {}, {})
eq(response().status, 400, "add without name → 400")
reset()
request_body = '{"name":"x"}'
tokenizer.handle_add_tokenizer({}, {}, {})
eq(response().status, 400, "add without source → 400")
reset()
request_body = 'not json'
tokenizer.handle_add_tokenizer({}, {}, {})
eq(response().status, 400, "add with bad json → 400")
eq(decoded().error.code, "invalid_json", "add bad json code")
reset()
request_body = '{"name":"x","source":"/p","chat_template_path":7}'
tokenizer.handle_add_tokenizer({}, {}, {})
eq(response().status, 400, "non-string chat_template_path → 400")

new_case("POST /v1/tokenizers: 重名 409，形状照 Rust")
reset()
request_body = '{"name":"dup","source":"/models/a"}'
tokenizer.handle_add_tokenizer({}, {}, {})
local first = decoded()
eq(first.status, "pending", "first add pending")
request_body = '{"name":"dup","source":"/models/b"}'
tokenizer.handle_add_tokenizer({}, {}, {})
eq(response().status, 409, "duplicate name → 409")
local conflict = decoded()
eq(conflict.status, "failed", "Rust marks the 409 body failed")
eq(conflict.id, first.id, "409 carries the existing id")
check(conflict.message:find("already exists", 1, true) ~= nil,
    "409 message says already exists", conflict.message)

new_case("POST /v1/tokenizers: shared dict 不可用 → 503 failed")
reset()
dict_missing = true
request_body = '{"name":"d1","source":"/models/a"}'
tokenizer.handle_add_tokenizer({}, {}, {})
eq(response().status, 503, "no dict → 503")
eq(decoded().status, "failed", "no dict → status failed")
eq(decoded().message, "Job queue not available", "no dict message matches Rust")
dict_missing = false

new_case("GET /v1/tokenizers: 只列 completed，?all=1 附状态")
reset()
request_body = '{"name":"ready","source":"http://10.0.0.9:8000"}'
tokenizer.handle_add_tokenizer({}, {}, {})
worker("http://10.0.0.9:8000", { model_id = "unknown",
    labels = { tokenizer = "ready", vocab_size = "151643" } })
tokenizer.handle_list_tokenizers({}, {}, {})
eq(response().status, 200, "list is 200")
local list = decoded().tokenizers
eq(#list, 1, "one loaded tokenizer listed")
eq(list[1].name, "ready", "listing carries the name")
eq(list[1].vocab_size, 151643, "vocab_size from the backend label")
check(list[1].id ~= nil and list[1].source == "http://10.0.0.9:8000",
    "listing carries id and source", cjson.encode(list[1]))
check(list[1].status == nil, "Rust's TokenizerInfo has no status field", cjson.encode(list[1]))

new_case("GET /v1/tokenizers: 空表序列化为 [] 而不是 {}")
reset()
tokenizer.handle_list_tokenizers({}, { uri_args = {} }, {})
eq(response().body:gsub("%s", ""), '{"tokenizers":[]}', "empty listing is a JSON array")

new_case("GET /v1/tokenizers?all=1: 未认领的 job 带状态出现")
reset()
request_body = '{"name":"orphan","source":"/models/orphan"}'
tokenizer.handle_add_tokenizer({}, {}, {})
tokenizer.handle_list_tokenizers({}, { uri_args = { all = "1" } }, {})
local all = decoded().tokenizers
eq(#all, 1, "all=1 lists the pending job")
eq(all[1].status, "pending", "pending job surfaced")
reset()
tokenizer.handle_list_tokenizers({}, { uri_args = {} }, {})
eq(#decoded().tokenizers, 0, "default listing hides non-completed jobs")

new_case("状态机: pending → processing → completed（后端中途声明）")
reset()
local now = ngx.now()
store["tok:ids"] = "job-p"
store["tok:job:job-p"] = cjson.encode({
    id = "job-p", name = "late-tok", source = "/models/late", status = "pending",
    message = "submitted", created_at = now - 30, updated_at = now - 30,
})
local job = tokenizer.get_job("job-p")
eq(job.status, "pending", "starts pending")
eq(tokenizer.advance(job, now), true, "advance past the grace window")
eq(job.status, "processing", "pending → processing after grace")
worker("http://late", { labels = { tokenizer = "late-tok", vocab_size = "100" } })
eq(tokenizer.advance(job, now), true, "claim completes the job")
eq(job.status, "completed", "processing → completed on claim")
eq(job.vocab_size, 100, "vocab_size recorded from the claim")
eq(tokenizer.advance(job, now + 10000), false, "completed is terminal")

new_case("状态机: 无人认领 → failed（stale），且限定式声明不算完成")
reset()
local now = ngx.now()
store["tok:ids"] = "job-s"
store["tok:job:job-s"] = cjson.encode({
    id = "job-s", name = "nobody", source = "/models/nobody", status = "pending",
    created_at = now - 400, updated_at = now - 400,
})
worker("http://unqualified", { labels = { tokenizer = "true" } })
local stale = tokenizer.get_job("job-s")
eq(tokenizer.advance(stale, now), true, "stale pending advances")
eq(stale.status, "failed", "no claim within stale_secs → failed")
check(stale.message:find("does not load tokenizers", 1, true) ~= nil,
    "failure message states the proxy strategy", stale.message)
local fresh = tokenizer.get_job("job-s")
eq(fresh.status, "failed", "failure persisted to the store")

new_case("状态机: 未 finished 的 job 可被同名重注册顶掉")
reset()
request_body = '{"name":"retry-me","source":"/models/a"}'
tokenizer.handle_add_tokenizer({}, {}, {})
local first_id = decoded().id
store["tok:job:" .. first_id] = cjson.encode({
    id = first_id, name = "retry-me", source = "/models/a", status = "failed",
    message = "stale", created_at = 0, updated_at = 0,
})
request_body = '{"name":"retry-me","source":"/models/b"}'
tokenizer.handle_add_tokenizer({}, {}, {})
eq(response().status, 202, "failed name can be re-added")
check(decoded().id ~= first_id, "re-add mints a new id", decoded().id)
eq(#tokenizer.list_jobs(), 1, "the failed job was dropped")

new_case("GET /v1/tokenizers/{id}: 按 id 与按 name，未完成时附状态")
reset()
request_body = '{"name":"by-name","source":"/models/n"}'
tokenizer.handle_add_tokenizer({}, {}, {})
local by_id = decoded().id
tokenizer.handle_get_tokenizer({ tokenizer_id = by_id }, {}, {})
eq(response().status, 200, "get by id → 200")
eq(decoded().name, "by-name", "get by id returns the record")
eq(decoded().status, "pending", "unfinished get exposes status (deviation)")
tokenizer.handle_get_tokenizer({ tokenizer_id = "by-name" }, {}, {})
eq(response().status, 200, "get by name → 200 (Rust falls back to name)")
tokenizer.handle_get_tokenizer({ tokenizer_id = "nope" }, {}, {})
eq(response().status, 404, "get unknown → 404")
eq(decoded().error.code, "tokenizer_not_found", "get 404 code matches Rust")
tokenizer.handle_get_tokenizer({}, {}, {})
eq(response().status, 400, "get without id → 400")

new_case("GET /v1/tokenizers/{id}/status: completed 说 ready，未知 404")
reset()
worker("http://ready-box", { labels = { tokenizer = "ready-tok", vocab_size = "32000" } })
request_body = '{"name":"ready-tok","source":"http://ready-box"}'
tokenizer.handle_add_tokenizer({}, {}, {})
local ready_id = decoded().id
tokenizer.handle_tokenizer_status({ tokenizer_id = "ready-tok" }, {}, {})
eq(response().status, 200, "status of a claimed tokenizer → 200")
local status_body = decoded()
eq(status_body.status, "completed", "status is completed")
check(status_body.message:find("is loaded and ready", 1, true) ~= nil,
    "completed message matches Rust", status_body.message)
eq(status_body.vocab_size, 32000, "status exposes vocab size")
tokenizer.handle_tokenizer_status({ tokenizer_id = "ghost" }, {}, {})
eq(response().status, 404, "unknown status → 404")
eq(decoded().error.code, "not_found", "404 code matches Rust's not_found")
check(decoded().error.message:find("no pending job", 1, true) ~= nil,
    "404 message matches Rust", decoded().error.message)

new_case("DELETE /v1/tokenizers/{id}: 成功与 404")
reset()
request_body = '{"name":"gone","source":"/models/g"}'
tokenizer.handle_add_tokenizer({}, {}, {})
local gone_id = decoded().id
tokenizer.handle_delete_tokenizer({ tokenizer_id = gone_id }, {}, {})
eq(response().status, 200, "delete → 200")
eq(decoded().success, true, "delete success true")
check(decoded().message:find("removed successfully", 1, true) ~= nil,
    "delete message matches Rust", decoded().message)
eq(tokenizer.get_job(gone_id), nil, "job record removed")
eq(tokenizer.get_job_by_name("gone"), nil, "name index removed")
tokenizer.handle_delete_tokenizer({ tokenizer_id = gone_id }, {}, {})
eq(response().status, 404, "second delete → 404")
eq(decoded().success, false, "404 body says success false")
request_body = '{"name":"gone","source":"/models/g2"}'
tokenizer.handle_add_tokenizer({}, {}, {})
eq(response().status, 202, "name free after delete")

new_case("GET 列表与状态: settled 后再应答（read-driven 生命周期）")
reset()
request_body = '{"name":"lazy","source":"/models/l"}'
tokenizer.handle_add_tokenizer({}, {}, {})
local lazy_id = decoded().id
store["tok:job:" .. lazy_id] = cjson.encode({
    id = lazy_id, name = "lazy", source = "/models/l", status = "pending",
    message = "x", created_at = ngx.now() - 400, updated_at = ngx.now() - 400,
})
tokenizer.handle_list_tokenizers({}, { uri_args = { all = "1" } }, {})
local settled = decoded().tokenizers[1]
eq(settled.status, "failed", "listing settles the job before answering")
local persisted = tokenizer.get_job(lazy_id)
eq(persisted.status, "failed", "settled state written back")

new_case("generate_id: v4 形状且互不相同")
local seen = {}
for i = 1, 50 do
    local id = tokenizer.generate_id()
    check(is_uuid4(id), "generated id is a v4 uuid", id)
    check(not seen[id], "generated ids are unique", id)
    seen[id] = true
end

new_case("param_text: 反转义并容忍表形态参数")
eq(tokenizer.param_text({ tokenizer_id = "a%2Fb" }, "tokenizer_id"), "a/b", "unescaped")
eq(tokenizer.param_text({ tokenizer_id = { "x" } }, "tokenizer_id"), "x", "table form")
eq(tokenizer.param_text({}, "tokenizer_id"), nil, "missing → nil")

--------------------------------------------------------------------------
-- parse：候选选择
--------------------------------------------------------------------------
new_case("parser_claim: 记录字段优先，标签兜底，true 视为未限定")
eq(parse.parser_claim({ labels = {} }, "tool_parser"), nil, "no claim → nil")
eq(parse.parser_claim({ tool_parser = "qwen" }, "tool_parser"), "qwen", "record field")
eq(parse.parser_claim({ labels = { tool_parser = "glm47_moe" } }, "tool_parser"),
    "glm47_moe", "label")
eq(parse.parser_claim({ labels = { reasoning_parser = "true" } }, "reasoning_parser"),
    "*", "unqualified label")
eq(parse.parser_claim({ labels = { reasoning_parser = 1 } }, "reasoning_parser"),
    "*", "numeric 1 label")

new_case("parser_candidates: 打分与排序")
worker("http://p-exact", { labels = { tool_parser = "qwen" } })
worker("http://p-any", { labels = { tool_parser = "true" } })
worker("http://p-other", { labels = { tool_parser = "mistral" } })
worker("http://p-plain")
local pranked = parse.parser_candidates("tool_parser", "qwen", nil)
eq(#pranked, 3, "only parser claimants")
eq(pranked[1].record.url, "http://p-exact", "exact parser name first")
eq(pranked[1].score, 4, "exact parser name scores highest")
eq(pranked[2].score, 1, "unqualified claim scores +1")
eq(pranked[3].score, 0, "different parser name scores 0")
eq(parse.pick_parser_worker("tool_parser", "qwen", nil).url, "http://p-exact",
    "pick uses the exact claim")
local star = parse.pick_parser_worker("tool_parser", "nonexistent", nil)
check(star ~= nil and star.url == "http://p-any",
    "unqualified claim can serve an unknown parser name", star and star.url)

new_case("parser_candidates: model 匹配提升一级")
reset()
worker("http://p-other", { labels = { tool_parser = "mistral" }, model_id = "glm-5" })
worker("http://p-any", { labels = { tool_parser = "true" }, model_id = "other" })
worker("http://p-star-matching", { labels = { tool_parser = "true" }, model_id = "glm-5" })
local by_model = parse.parser_candidates("tool_parser", "nonexistent", "glm-5")
eq(by_model[1].record.url, "http://p-star-matching",
    "model-matching unqualified claim ranks first")
eq(by_model[2].record.url, "http://p-other", "model-matching named claim next")
eq(by_model[3].record.url, "http://p-any", "wrong-model unqualified claim last")
eq(parse.pick_parser_worker("tool_parser", "nonexistent", "glm-5").url,
    "http://p-star-matching", "pick honours the model tiebreak")

new_case("pick_parser_worker: 有标签但名字不匹配 → unknown_parser")
reset()
worker("http://only-mistral", { labels = { tool_parser = "mistral" } })
worker("http://other-mistral", { labels = { tool_parser = "mistral" }, model_id = "m2" })
local rec, picked = parse.pick_parser_worker("tool_parser", "qwen", nil)
eq(rec, nil, "no worker claims the requested parser")
eq(picked.unknown_parser, true, "unknown_parser flagged")
local rec2, picked2 = parse.pick_parser_worker("tool_parser", "qwen", "m1")
eq(rec2, nil, "still unknown with a model in play")
eq(#picked2.candidates, 2, "candidates reported for the message")

--------------------------------------------------------------------------
-- parse：handler 行为
--------------------------------------------------------------------------
new_case("parse/function_call: 校验")
reset()
request_body = "nope"
parse.handle_function_call({}, {}, {})
eq(response().status, 400, "non-JSON body → 400")
eq(decoded().error.code, "invalid_json", "non-JSON uses router error_body")
reset()
request_body = '{"tool_call_parser":"json","tools":[]}'
parse.handle_function_call({}, {}, {})
eq(response().status, 400, "missing text → 400")
eq(decoded().error.code, "invalid_request", "missing text code")
eq(#calls, 0, "validation failure never proxies")
reset()
request_body = '{"text":"hi","tools":[]}'
parse.handle_function_call({}, {}, {})
eq(response().status, 400, "missing tool_call_parser → 400")
reset()
worker("http://json-parser", { labels = { tool_parser = "json" } })
request_body = '{"text":"","tool_call_parser":"json","tools":[]}'
ok200('{"remaining_text":"","tool_calls":[],"success":true}')
parse.handle_function_call({}, {}, {})
eq(response().status, 200, "empty text is valid (Rust accepts it too)")
eq(#calls, 1, "empty text still proxied")

new_case("parse/function_call: 没有任何 tool parser → 503 + success:false")
reset()
request_body = '{"text":"hi","tool_call_parser":"json","tools":[]}'
parse.handle_function_call({}, {}, {})
eq(response().status, 503, "no parser → 503")
eq(decoded().success, false, "parse error shape keeps success false")
eq(decoded().error, "Tool parser factory not initialized", "503 message matches Rust")

new_case("parse/function_call: 未知 parser 名 → 400 + 候选清单")
reset()
worker("http://mistral-only", { labels = { tool_parser = "mistral" } })
request_body = '{"text":"hi","tool_call_parser":"nope","tools":[]}'
parse.handle_function_call({}, {}, {})
eq(response().status, 400, "unknown parser → 400")
eq(decoded().success, false, "400 shape keeps success false")
check(decoded().error:find("Unknown tool parser: nope", 1, true) ~= nil,
    "400 names the requested parser", decoded().error)
check(decoded().error:find("mistral", 1, true) ~= nil,
    "400 lists what workers advertise", decoded().error)

new_case("parse/function_call: 代理构造")
reset()
worker("http://p1", { labels = { tool_parser = "json" }, api_key = "k1" })
request_body = '{"text":"t","tool_call_parser":"json","tools":[]}'
request_headers = { ["content-type"] = "application/json", ["x-request-id"] = "req-1" }
ok200('{"remaining_text":"t","tool_calls":[],"success":true}')
parse.handle_function_call({}, {}, {})
eq(#calls, 1, "one upstream call")
eq(calls[1].method .. " " .. calls[1].url, "POST http://p1/parse/function_call", "proxied path")
eq(calls[1].body, request_body, "original bytes forwarded (tools:[] preserved)")
eq(calls[1].headers["authorization"], "Bearer k1", "worker api key injected")
eq(calls[1].headers["x-request-id"], "req-1", "request id forwarded")
eq(cjson.decode(response().body).success, true, "worker answer passed through")

new_case("parse/reasoning: 走 reasoning_parser 标签")
reset()
worker("http://r1", { labels = { reasoning_parser = "qwen3" } })
request_body = '{"text":"a","reasoning_parser":"qwen3"}'
ok200('{"normal_text":"a","reasoning_text":"","success":true}')
parse.handle_reasoning({}, {}, {})
eq(calls[1].url, "http://r1/parse/reasoning", "reasoning path proxied")
eq(response().status, 200, "reasoning 200")
reset()
request_body = '{"text":"a","reasoning_parser":"qwen3"}'
parse.handle_reasoning({}, {}, {})
eq(response().status, 503, "no reasoning parser → 503")
eq(decoded().error, "Reasoning parser factory not initialized", "reasoning 503 message")

new_case("parse: 上游非 2xx 且已符合 parse 形状时原样转发")
reset()
worker("http://p2", { labels = { tool_parser = "json" } })
request_body = '{"text":"t","tool_call_parser":"json","tools":[]}'
replies = { { status = 400, body = '{"error":"Failed to parse function calls","success":false}' } }
parse.handle_function_call({}, {}, {})
eq(response().status, 400, "worker 400 forwarded")
eq(decoded().error, "Failed to parse function calls", "worker message kept verbatim")
eq(decoded().success, false, "success false kept")

new_case("parse: 上游返回非 parse 形状时包装成 parse 错误")
reset()
worker("http://p3", { labels = { tool_parser = "json" } })
request_body = '{"text":"t","tool_call_parser":"json","tools":[]}'
replies = { { status = 404, body = "no route", headers = { ["content-type"] = "text/plain" } } }
parse.handle_function_call({}, {}, {})
eq(response().status, 404, "worker 404 status forwarded")
eq(decoded().success, false, "wrapped into the parse error shape")
check(decoded().error:find("no route", 1, true) ~= nil, "wrapped body included", decoded().error)

new_case("parse: 上游连不上 → 503 而不是 502")
reset()
worker("http://p4", { labels = { tool_parser = "json" } })
request_body = '{"text":"t","tool_call_parser":"json","tools":[]}'
replies = { { err = "connection refused" } }
parse.handle_function_call({}, {}, {})
eq(response().status, 503, "unreachable parser backend → 503")
eq(decoded().success, false, "503 uses the parse error shape")
check(decoded().error:find("connection refused", 1, true) ~= nil, "cause reported")

new_case("parse: 熔断/不健康的解析后端被跳过")
reset()
worker("http://p-down", { labels = { tool_parser = "json" } })
worker("http://p-up", { labels = { tool_parser = "json" } })
unavailable["http://p-down"] = true
request_body = '{"text":"t","tool_call_parser":"json","tools":[]}'
ok200('{"remaining_text":"","tool_calls":[],"success":true}')
parse.handle_function_call({}, {}, {})
eq(calls[1].url, "http://p-up/parse/function_call", "healthy backend used")


--------------------------------------------------------------------------
-- auth 接线：authorize seam（Rust: tokenize=数据面 key，tokenizers*/parse=控制面 key）
--------------------------------------------------------------------------
new_case("authorize: 注入的 auth_checks 决定是否放行")
reset()
tokenizer.auth_checks = { data = function() return false end, control = function() return true end }
request_body = '{"prompt":"hi"}'
local out = tokenizer.handle_tokenize({}, {}, {})
eq(out, "", "denied data handler returns '' (error already sent by the checker)")
eq(#calls, 0, "denied request never proxies")
eq(#responses, 0, "module itself writes nothing when denied")
reset()
tokenizer.auth_checks = { data = function() return true end }
worker("http://tok-auth", { labels = { tokenizer = "glm" } })
request_body = '{"model":"glm","prompt":"hi"}'
ok200('{"tokens":[1],"count":1,"char_count":2}')
tokenizer.handle_tokenize({}, {}, {})
eq(#calls, 1, "allowed request proxies")
reset()
parse.auth_checks = { control = function() return false end }
request_body = '{"text":"t","tool_call_parser":"json","tools":[]}'
eq(parse.handle_function_call({}, {}, {}), "", "parse denied returns ''")
eq(#calls, 0, "parse denied never proxies")
reset()
tokenizer.auth_checks = { control = function() return true end }
request_body = '{"name":"authed","source":"/models/a"}'
tokenizer.handle_add_tokenizer({}, {}, {})
eq(response().status, 202, "control-allowed add works")
reset()
tokenizer.auth_checks = nil
parse.auth_checks = nil

--------------------------------------------------------------------------
io.write(string.format("\ntokenizer+parse: %d passed, %d failed\n", passed, failed))
if failed > 0 then
    for i = 1, #failures do
        io.write("FAIL " .. failures[i] .. "\n")
    end
    os.exit(1)
end
os.exit(0)
