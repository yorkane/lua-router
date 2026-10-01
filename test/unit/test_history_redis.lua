#!/usr/bin/env luajit
-- history_redis.lua tests: RESP encode/decode, an in-memory fake server that
-- runs the full backend semantics, the history.lua public API end to end over
-- the redis backend, and (optionally) a real public-Redis smoke pass.
--
-- Two ways to run:
--   # pure logic + fake server (no network, no nginx):
--   docker run --rm -v "$PWD:/repo:ro" -w /repo authz:latest \
--     /usr/local/openresty/luajit/bin/luajit test/unit/test_history_redis.lua
--   # plus the real public Redis smoke (cosocket only exists under resty;
--   # the authz image's resty cannot start because perl is missing, so use
--   # the apisix image with host networking):
--   docker run --rm --network host -v "$PWD:/repo:ro" -w /repo \
--     --entrypoint /usr/local/openresty/bin/resty apache/apisix:3.11.0-debian \
--     test/unit/test_history_redis.lua
--   LUA_TEST_REDIS_HOST/PORT/PASSWORD steer the smoke target (default
--   set via LUA_TEST_REDIS_HOST/PASSWORD). If unset/unreachable the section SKIPs.
--   reason instead of failing.
--
-- Why the fake injects at the transport layer rather than the socket layer:
-- the authz luajit has no lua-socket, so a real loopback listener would need
-- threads. transport is this module's only connection abstraction
-- (acquire/release); swapping it still runs real RESP bytes through send and
-- read_reply, so the encode/parse/pipeline path is exercised.

package.path = (os.getenv("LUA_TEST_LIB") or "./lualib") .. "/?.lua;" .. package.path
package.cpath = "/usr/local/openresty/lualib/?.so:" .. package.cpath

local cjson = require "cjson.safe"

local history = require "resty.luarouter.history"
local redis = require "resty.luarouter.history_redis"

local CR = string.char(13)
local LF = string.char(10)
local CRLF = CR .. LF

local passed, failed, skipped = 0, 0, 0
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
    io.write("  case: " .. name .. "" .. LF)
end

--------------------------------------------------------------------------
-- fake RESP server. Implements only what this backend sends, and simulates
-- server-side behaviour (NX, score formatting, error replies) rather than
-- mirroring history_redis's own logic.
--------------------------------------------------------------------------
local function fmt_score(v)
    if v == math.floor(v) then
        return string.format("%d", v)
    end
    return string.format("%.17g", v)
end

local function new_fake_server(opts)
    opts = opts or {}
    local srv = { kv = {}, zsets = {}, expire = {}, commands = 0, fail_cmd = nil,
        auth_required = opts.auth_required, conns = 0, released = 0 }
    local function bulk(s)
        return "$" .. #s .. CRLF .. s .. CRLF
    end
    local function reply_str(s) return "+" .. s .. CRLF end
    local function reply_int(n) return ":" .. tostring(n) .. CRLF end
    local function reply_nil() return "$-1" .. CRLF end

    local function zset(key, create)
        local z = srv.zsets[key]
        if not z and create then
            z = {}
            srv.zsets[key] = z
        end
        return z
    end
    local function zmembers(key)
        local z = zset(key, false)
        local out = {}
        if not z then return out end
        local ids = {}
        for m in pairs(z) do ids[#ids + 1] = m end
        table.sort(ids, function(a, b)
            if z[a] == z[b] then return a < b end
            return z[a] < z[b]
        end)
        for i = 1, #ids do out[i] = { id = ids[i], score = z[ids[i]] } end
        return out
    end

    local function run(cmd)
        local name = string.upper(tostring(cmd[1] or ""))
        srv.commands = srv.commands + 1
        if srv.auth_required and name ~= "AUTH" then
            return srv:error_reply("NOAUTH Authentication required.")
        end
        if srv.fail_cmd == name then
            return srv:error_reply("ERR simulated failure for " .. name)
        end
        if name == "PING" then
            return reply_str("PONG")
        elseif name == "AUTH" then
            if cmd[2] == srv.auth_required then
                srv.auth_required = nil
                return reply_str("OK")
            end
            return srv:error_reply("WRONGPASS invalid username-password pair")
        elseif name == "SELECT" then
            srv.selected_db = tonumber(cmd[2]) or 0
            return reply_str("OK")
        elseif name == "SET" then
            local key, val = cmd[2], cmd[3]
            local nx
            local i = 4
            while i <= #cmd do
                local opt = string.upper(tostring(cmd[i]))
                if opt == "NX" then
                    nx = true
                    i = i + 1
                elseif opt == "PX" then
                    srv.expire[key] = os.time() + math.ceil(tonumber(cmd[i + 1]) / 1000)
                    i = i + 2
                elseif opt == "EX" then
                    srv.expire[key] = os.time() + tonumber(cmd[i + 1])
                    i = i + 2
                else
                    i = i + 1
                end
            end
            if nx and srv.kv[key] ~= nil then
                return reply_nil()
            end
            srv.kv[key] = val
            return reply_str("OK")
        elseif name == "GET" then
            local v = srv.kv[cmd[2]]
            if v == nil then return reply_nil() end
            return bulk(v)
        elseif name == "DEL" then
            local n = 0
            for i = 2, #cmd do
                if srv.kv[cmd[i]] ~= nil then n = n + 1 srv.kv[cmd[i]] = nil end
                if srv.zsets[cmd[i]] ~= nil then n = n + 1 srv.zsets[cmd[i]] = nil end
                srv.expire[cmd[i]] = nil
            end
            return reply_int(n)
        elseif name == "INCR" then
            local v = (tonumber(srv.kv[cmd[2]]) or 0) + 1
            srv.kv[cmd[2]] = tostring(v)
            return reply_int(v)
        elseif name == "EXPIRE" then
            local exists = srv.kv[cmd[2]] ~= nil or srv.zsets[cmd[2]] ~= nil
            if exists then srv.expire[cmd[2]] = os.time() + (tonumber(cmd[3]) or 0) end
            return reply_int(exists and 1 or 0)
        elseif name == "ZADD" then
            local key = cmd[2]
            local i = 3
            local nx
            while cmd[i] ~= nil and tonumber(cmd[i]) == nil do
                if string.upper(tostring(cmd[i])) == "NX" then nx = true end
                i = i + 1
            end
            local z = zset(key, true)
            local added = 0
            while i + 1 <= #cmd do
                local sc = tonumber(cmd[i])
                local member = cmd[i + 1]
                if sc == nil then
                    return srv:error_reply("ERR value is not a valid float")
                end
                if not nx or z[member] == nil then
                    if z[member] == nil then added = added + 1 end
                    z[member] = sc
                end
                i = i + 2
            end
            return reply_int(added)
        elseif name == "ZSCORE" then
            local z = zset(cmd[2], false)
            local sc = z and z[cmd[3]]
            if sc == nil then return reply_nil() end
            return bulk(fmt_score(sc))
        elseif name == "ZCARD" then
            local z = zset(cmd[2], false)
            local n = 0
            if z then for _ in pairs(z) do n = n + 1 end end
            return reply_int(n)
        elseif name == "ZREM" then
            local z = zset(cmd[2], false)
            local n = 0
            if z then
                for i = 3, #cmd do
                    if z[cmd[i]] ~= nil then z[cmd[i]] = nil n = n + 1 end
                end
            end
            return reply_int(n)
        elseif name == "ZRANGE" then
            local all = zmembers(cmd[2])
            local n = #all
            local lo = tonumber(cmd[3]) or 0
            local hi = tonumber(cmd[4]) or -1
            local withscores = false
            for i = 5, #cmd do
                if string.upper(tostring(cmd[i])) == "WITHSCORES" then withscores = true end
            end
            if lo < 0 then lo = math.max(n + lo + 1, 1) else lo = lo + 1 end
            if hi < 0 then hi = n + hi + 1 else hi = hi + 1 end
            local items = {}
            for i = lo, math.min(hi, n) do
                items[#items + 1] = bulk(all[i].id)
                if withscores then items[#items + 1] = bulk(fmt_score(all[i].score)) end
            end
            return "*" .. #items .. CRLF .. table.concat(items)
        elseif name == "ZREMRANGEBYRANK" then
            local all = zmembers(cmd[2])
            local n = #all
            local lo = tonumber(cmd[3]) or 0
            local hi = tonumber(cmd[4]) or -1
            if lo < 0 then lo = math.max(n + lo + 1, 1) else lo = lo + 1 end
            if hi < 0 then hi = n + hi + 1 else hi = hi + 1 end
            local z = zset(cmd[2], false)
            local removed = 0
            if z then
                for i = lo, math.min(hi, n) do
                    if all[i] and z[all[i].id] ~= nil then
                        z[all[i].id] = nil
                        removed = removed + 1
                    end
                end
            end
            return reply_int(removed)
        elseif name == "SCAN" then
            -- One page, cursor 0: enough for flush_all's loop and prefix delete.
            local pattern = tostring(cmd[4] or "*")
            local anchor = string.sub(pattern, 1, #pattern - 1)
            local keys = {}
            for k in pairs(srv.kv) do
                if string.sub(k, 1, #anchor) == anchor then keys[#keys + 1] = k end
            end
            for k in pairs(srv.zsets) do
                if string.sub(k, 1, #anchor) == anchor then keys[#keys + 1] = k end
            end
            table.sort(keys)
            local items = {}
            for i = 1, #keys do items[i] = bulk(keys[i]) end
            return "*2" .. CRLF .. bulk("0") .. "*" .. #keys .. CRLF .. table.concat(items)
        elseif name == "EVAL" then
            -- compare-and-delete, shape-matched to release_lock's script.
            if string.find(tostring(cmd[2]), "redis.call", 1, true)
                and srv.kv[cmd[4]] == cmd[5] then
                srv.kv[cmd[4]] = nil
                return reply_int(1)
            end
            return reply_int(0)
        end
        return srv:error_reply("ERR unknown command '" .. name .. "'")
    end

    function srv:error_reply(msg) return "-" .. msg .. CRLF end
    srv.run = run
    srv.bulk = bulk
    srv.transport = function(self, broken)
        return {
            acquire = function()
                srv.conns = srv.conns + 1
                local input = ""
                local out = ""
                local dead = broken
                local handshake_ok = true
                local conn
                conn = {
                    send = function(_, data)
                        if dead or not handshake_ok then return nil, "broken pipe" end
                        input = input .. data
                        out = ""
                        local pos = 1
                        while true do
                            local at = string.find(input, CRLF, pos, true)
                            if not at then break end
                            if string.sub(input, pos, pos) == "*" then
                                local n = tonumber(string.sub(input, pos + 1, at - 1))
                                local cur = at + 2
                                local args = {}
                                for _ = 1, n do
                                    local la = string.find(input, CRLF, cur, true)
                                    if not la then return #data end
                                    local hdr = string.sub(input, cur, la - 1)
                                    if string.sub(hdr, 1, 1) ~= "$" then return #data end
                                    local len = tonumber(string.sub(hdr, 2))
                                    if not len then return #data end
                                    args[#args + 1] = string.sub(input, la + 2, la + 1 + len)
                                    cur = la + len + 4
                                end
                                out = out .. run(args)
                                pos = cur
                            else
                                pos = at + 2
                            end
                        end
                        input = string.sub(input, pos)
                        return #data
                    end,
                    receive = function(_, spec)
                        if dead then return nil, "closed" end
                        if spec == "*l" then
                            local at = string.find(out, CRLF, 1, true)
                            if not at then return nil, "timeout" end
                            local line = string.sub(out, 1, at - 1)
                            out = string.sub(out, at + 2)
                            return line
                        end
                        local n = tonumber(spec)
                        if #out < n then return nil, "timeout" end
                        local data = string.sub(out, 1, n)
                        out = string.sub(out, n + 1)
                        return data
                    end,
                    close = function() dead = true end,
                }
                -- mirror the cosocket handshake: AUTH only when configured, and
                -- the connection is unusable when the server rejects it.
                local cfg = redis.config()
                if srv.auth_required and cfg.password then
                    local r = run({ "AUTH", cfg.password })
                    if string.sub(r, 1, 1) == "-" then
                        handshake_ok = false
                        return nil, "auth failed: WRONGPASS (fake)"
                    end
                    srv.auth_required = nil
                elseif srv.auth_required then
                    return nil, "auth failed: NOAUTH and no password configured (fake)"
                end
                return conn
            end,
            release = function(conn, reusable)
                srv.released = srv.released + (reusable and 1 or 0)
            end,
        }
    end
    return srv
end

--------------------------------------------------------------------------
new_case("RESP encode: bulk array framing, byte-exact")
do
    local enc = redis.encode_command({ "SET", "a", "b" })
    eq(enc, "*3" .. CRLF .. "$3" .. CRLF .. "SET" .. CRLF .. "$1" .. CRLF
        .. "a" .. CRLF .. "$1" .. CRLF .. "b" .. CRLF, "SET a b 逐字节")
    local weird = redis.encode_command({ "GET", "x" .. CRLF .. "y" })
    check(weird:find("$4" .. CRLF, 1, true) ~= nil, "含 CRLF 的参数按字节长度框定")
    local num_arg = redis.encode_command({ "EXPIRE", "k", 300 })
    check(num_arg:find("$3" .. CRLF .. "300", 1, true) ~= nil, "数字参数 tostring 后框定")
end

new_case("RESP decode: 全部回复类型 + 错误映射")
local function conn_from(text)
    return {
        receive = function(_, spec)
            if spec == "*l" then
                local at = string.find(text, CRLF, 1, true)
                if not at then return nil, "eof" end
                local line = string.sub(text, 1, at - 1)
                text = string.sub(text, at + 2)
                return line
            end
            local n = tonumber(spec)
            if #text < n then return nil, "eof" end
            local data = string.sub(text, 1, n)
            text = string.sub(text, n + 1)
            return data
        end,
    }
end
do
    local typ, val = redis.read_reply(conn_from("+OK" .. CRLF))
    eq(typ, "ok", "simple string"); eq(val, "OK", "simple 内容")
    typ, val = redis.read_reply(conn_from("-WRONGPASS nope" .. CRLF))
    eq(typ, "err", "error reply"); eq(val, "WRONGPASS nope", "error 文本")
    typ, val = redis.read_reply(conn_from(":42" .. CRLF))
    eq(typ, "int", "integer"); eq(val, 42, "integer 值")
    typ, val = redis.read_reply(conn_from("$-1" .. CRLF))
    eq(typ, "nil", "nil bulk"); eq(val, false, "nil bulk 值是 false")
    typ, val = redis.read_reply(conn_from("$5" .. CRLF .. "hello" .. CRLF))
    eq(typ, "str", "bulk"); eq(val, "hello", "bulk 值")
    typ, val = redis.read_reply(conn_from("*0" .. CRLF))
    eq(typ, "array", "空数组"); eq(#val, 0, "空数组长度 0")
    typ, val = redis.read_reply(conn_from("*2" .. CRLF .. "$2" .. CRLF .. "ab" .. CRLF .. ":7" .. CRLF))
    eq(typ, "array", "嵌套数组"); eq(val[1].val, "ab", "数组元素 1"); eq(val[2].val, 7, "数组元素 2")
    typ, val = redis.read_reply(conn_from(">3" .. CRLF .. "+A" .. CRLF .. "+B" .. CRLF .. "+C" .. CRLF))
    eq(typ, "array", "RESP3 push 头按数组读")
    local t2, v2, e2 = redis.read_reply(conn_from("!bad" .. CRLF))
    eq(t2, nil, "未知 tag 报错"); check(e2 ~= nil, "未知 tag 带 err")
    t2, v2, e2 = redis.read_reply(conn_from("$5" .. CRLF .. "ab" .. CRLF))
    eq(t2, nil, "截断 bulk 报错")
end

--------------------------------------------------------------------------
local function use_fake(srv, overrides)
    redis.set_transport(srv:transport())
    local cfg = {
        host = "fake", port = 1, password = nil, db = 0,
        prefix = "lua_router_test:", timeout_ms = 100,
        ttl_secs = 0, keepalive_ms = 1000, keepalive_pool = 4,
    }
    for k, v in pairs(overrides or {}) do cfg[k] = v end
    redis.configure(cfg)
end

local function reset_history()
    history.reset_config()
    local cfg = history.config()
    cfg.backend = "redis"
    cfg.max_conversations = 10000
    cfg.max_items_per_conversation = 1000
    cfg.max_responses = 10000
    cfg.max_items_per_request = 1000
    cfg.ttl_secs = 0
    history.use_dict(nil)
end

local srv

new_case("configure/SMG_HISTORY_REDIS_URL 解析")
do
    -- luajit has no os.setenv, so drive parse_url directly with a fresh cfg
    -- (same code path config() takes when SMG_HISTORY_REDIS_URL is set).
    local cfg = { host = "127.0.0.1", port = 6379, db = 0 }
    redis.parse_url("redis://:secret@10.0.0.1:6380/3", cfg)
    eq(cfg.host, "10.0.0.1", "URL 覆盖 HOST")
    eq(cfg.port, 6380, "URL 端口")
    eq(cfg.password, "secret", "URL 密码")
    eq(cfg.db, 3, "URL db")
    local cfg2 = { host = "x", port = 1, db = 9 }
    redis.parse_url("redis://plain-host", cfg2)
    eq(cfg2.host, "plain-host", "无端口无密码")
    eq(cfg2.port, 1, "URL 缺端口保留原值")
    eq(cfg2.db, 9, "URL 缺 path 保留原 db")
    local cfg3 = { host = "x", port = 1, db = 0 }
    redis.parse_url("rediss://user:s3cr3t@tls-host:6390", cfg3)
    eq(cfg3.password, "s3cr3t", "带用户名时取冒号后为密码")
    eq(cfg3.host, "tls-host", "rediss:// 前缀剥离")
    eq(cfg3.port, 6390, "rediss 端口")
end

new_case("注册即解除 501：install + backend_supported")
do
    reset_history()
    local ok, err = history.backend_supported()
    eq(ok, false, "注册前 redis 是 501")
    eq(err and err.status, 501, "501 状态码")
    redis.install()
    ok, err = history.backend_supported()
    eq(ok, true, "注册后转为支持")
    eq(err, nil, "注册后无错误")
end

new_case("conversation CRUD 走 fake server")
do
    srv = new_fake_server()
    use_fake(srv)
    reset_history()
    redis.install()
    local conv, err = history.create_conversation({ user = "alice" })
    check(conv ~= nil, "create_conversation 成功", err and err.message)

    check(type(conv) == "table" and conv.id ~= nil, "返回 conversation 对象")
    local got, gerr = history.get_conversation(conv.id)
    check(got ~= nil, "get_conversation 命中", gerr and gerr.message)
    eq(got and got.metadata and got.metadata.user, "alice", "metadata 存活")
    local upd, uerr = history.update_conversation(conv.id, { metadata = { user = cjson.null, extra = "1" } })
    check(upd ~= nil, "metadata patch 成功", uerr and uerr.message)
    eq(upd and (upd.metadata == nil or upd.metadata.user == nil), true, "null 值删键")
    eq(upd and upd.metadata and upd.metadata.extra, "1", "新键写入")
    local del, derr = history.delete_conversation(conv.id)
    check(del ~= nil and del.deleted == true, "delete 返回 deleted 标记", derr and derr.message)
    local gone = history.get_conversation(conv.id)
    check(gone == nil, "删除后读不到")
    local g2, e2 = history.get_conversation(conv.id)
    check(g2 == nil and e2 and e2.status == 404, "二次删除 404", e2 and e2.status)
end

new_case("items：创建 / 分页 after order / 幂等 link / 上限")
do
    srv = new_fake_server()
    use_fake(srv)
    reset_history()
    redis.install()
    local conv = history.create_conversation()
    local made = {}
    for i = 1, 5 do
        local env, err = history.create_items(conv.id, {
            { type = "message", role = "user", content = "m" .. i },
        })
        check(env ~= nil, "create item " .. i, err and err.message)
        made[i] = env and env.data[1]
    end
    local page = history.list_items(conv.id, { limit = 2 })
    eq(page and #page.data, 2, "limit 生效")
    eq(page and page.has_more, true, "满页 has_more")
    eq(page and page.data[1].id, made[5].id, "默认 desc：data[1] 是最新一条")
    local asc = history.list_items(conv.id, { limit = 10, order = "asc" })
    eq(asc and asc.data[1].id, made[1].id, "asc 从最旧开始")
    eq(asc and asc.data[5].id, made[5].id, "asc 到最新结束")
    local after = history.list_items(conv.id, { limit = 10, order = "asc", after = made[3].id })
    eq(after and #after.data, 2, "after 游标跳过前三条")
    eq(after and after.data[1].id, made[4].id, "游标位置正确")
    -- 幂等：同一 item 再次 link 不改变顺序、不报错。
    local dup = history.create_items(conv.id, {
        { id = made[2].id, type = "item_reference" },
    })
    check(dup ~= nil, "item_reference 重复 link 不报错", dup and dup.message)
    local idx = redis.index(conv.id)
    eq(#idx, 5, "重复 link 不加条目")
    eq(idx[2].item_id, made[2].id, "位置保持")
    -- score 串与 memory 完全同形（12 位零填充 + 空格 + id），游标比较不区分后端。
    check(string.match(idx[1].score, "^%d%d%d%d%d%d%d%d%d%d%d%d ") ~= nil, "score 串形状与 memory 一致")
    -- items 上限：淘汰最旧。
    history.config().max_items_per_conversation = 3
    history.create_items(conv.id, { { type = "message", role = "user", content = "overflow" } })
    local now = history.list_items(conv.id, { limit = 10, order = "asc" })
    eq(now and #now.data, 3, "上限裁剪到 3")
    -- 6 links -> cap 3 keeps the newest three: m4, m5, overflow.
    eq(now and now.data[1].id, made[4].id, "最旧三条被淘汰，asc 首条是 m4")
    eq(now and now.data[3].content and "x" or nil, "x")
    local got1 = history.get_item(conv.id, made[1].id)
    check(got1 == nil, "被淘汰项不再可读")
    -- 单个 DELETE 路径。
    local dd = history.delete_item(conv.id, made[5].id)
    check(dd ~= nil, "delete_item 返回 conversation", dd and dd.message)
    check(redis.score_of(conv.id, made[5].id) == nil, "unlink 后游标消失")
end

new_case("response：存储 / raw 回放 / cancel / delete / input_items / chain")
do
    srv = new_fake_server()
    use_fake(srv)
    reset_history()
    redis.install()
    local conv = history.create_conversation()
    local raw = cjson.encode({
        id = "resp_test1", status = "in_progress", model = "m1",
        conversation = conv.id,
        output = { { type = "message", role = "assistant", content = "hi" } },
        input = { { type = "function_call", name = "f", call_id = "c1" } },
    })
    local stored, serr = history.create_response(raw)
    check(stored ~= nil, "create_response 成功", serr and serr.message)
    local got, gerr = history.get_response("resp_test1")
    check(got ~= nil, "get_response 命中", gerr and gerr.message)
    eq(type(got) == "string" and got or nil, raw, "raw_json 字节级回放")
    local cancelled = history.cancel_response("resp_test1")
    check(cancelled ~= nil, "cancel in_progress 成功")
    check(history.delete_response("resp_test1") ~= nil, "delete_response 成功")
    local g2, e2 = history.get_response("resp_test1")
    check(g2 == nil and e2 and e2.status == 404, "删除后 404")
    local g3, e3 = history.delete_response("resp_missing")
    check(g3 == nil and e3 and e3.status == 404, "redis 后端删除不存在回 404（memory 契约）")
    -- input_items + chain
    local r2 = history.create_response(cjson.encode({
        id = "resp_a", previous_response_id = "resp_b",
        input = { { role = "user", content = "x" } },
    }))
    check(r2 ~= nil, "存 resp_a")
    history.create_response(cjson.encode({ id = "resp_b" }))
    local chain = history.get_response_chain("resp_a")
    eq(chain and #chain.responses, 2, "chain 深度 2")
    eq(chain and chain.responses[1].id or (chain and type(chain.responses[1]) == "string" and cjson.decode(chain.responses[1]).id),
        "resp_b", "chain 最旧在前")
    local li = history.list_input_items("resp_a")
    eq(li and #li.data, 1, "input_items 返回原条目")
    check(li and li.data[1].id ~= nil, "无 id 的 input 条目补生成 id")
end

new_case("stats / sweep / flush_all 的后端挂点")
do
    srv = new_fake_server()
    use_fake(srv)
    reset_history()
    redis.install()
    history.create_conversation()
    history.create_conversation({ k = "v" })
    local st = history.stats()
    eq(st.backend, "redis", "stats 报告 redis")
    eq(st.conversations, 2, "conversation 计数来自 ZCARD")
    local sw = history.sweep()
    check(sw.dropped_conversations == 0, "未超上限 sweep 不淘汰")
    local ok = history.flush_all()
    eq(ok, true, "flush_all 成功")
    local st2 = history.stats()
    eq(st2.conversations, 0, "flush 后计数归零")
    check(next(srv.kv) == nil and next(srv.zsets) == nil, "fake 键空间被清空")
end

new_case("错误映射：AUTH 失败 -> 503，服务器错误回复 -> 503")
do
    srv = new_fake_server({ auth_required = "right" })
    use_fake(srv, { password = "wrong" })
    reset_history()
    redis.install()
    local v, err = history.get_conversation("cv_missing")
    check(v == nil and err ~= nil, "坏密码下读取失败")
    eq(err and err.status, 503, "AUTH 失败映射 503")
    check(err and err.code == "history_unavailable", "错误码 history_unavailable")
    check(err and err.message and err.message:find("auth") ~= nil, "错误信息带 auth", err and err.message)
    srv = new_fake_server()
    use_fake(srv)
    srv.fail_cmd = "GET"
    reset_history()
    redis.install()
    local _, err2 = history.get_conversation("cv_x")
    eq(err2 and err2.status, 503, "服务器 ERR 回复映射 503")
    srv.fail_cmd = "ZSCORE"
    local c9 = history.create_conversation()
    check(c9 ~= nil, "create 在 ZSCORE 故障下不受影响", "create 不读 zset")
    local gi, gierr = history.get_item(c9.id, "msg_0123456789abcdef0123456789abcdef0123456789abcdef0123")
    check(gi == nil and gierr and gierr.status == 503, "is_item_linked 传输故障 -> 503 而不是 404")
    srv.fail_cmd = nil
    check(err2 and err2.message and err2.message:find("simulated") ~= nil, "保留服务器消息")
end

new_case("transport 丢失：acquire 失败映射 503 而不是崩")
do
    srv = new_fake_server()
    use_fake(srv)
    local broken = srv:transport(true)
    redis.set_transport(broken)
    reset_history()
    redis.install()
    local _, err = history.get_conversation("cv_x")
    eq(err and err.status, 503, "connect 失败 -> 503")
    local _, err2 = history.create_conversation()
    eq(err2 and err2.status, 503, "写路径同样 -> 503")
    redis.set_transport(nil)
end

new_case("SET NX 锁：try/release 与所有权")
do
    srv = new_fake_server()
    use_fake(srv)
    local held = redis.try_lock("smoke")
    check(held ~= nil, "首次 try_lock 获得锁")
    local again = redis.try_lock("smoke")
    check(again == nil, "锁被占用时第二次 try_lock 失败")
    local rel = redis.release_lock(held)
    eq(rel, true, "持有者释放成功")
    local third = redis.try_lock("smoke")
    check(third ~= nil, "释放后可再获取")
    local wrong = redis.release_lock({ key = third.key, token = "not-mine" })
    eq(wrong, false, "非持有者释放无效")
    redis.release_lock(third)
end

--------------------------------------------------------------------------
-- 真实公共 Redis 冒烟：只在 resty（有 cosocket）下执行。luajit 下 SKIP。
--------------------------------------------------------------------------
new_case("真实 Redis 冒烟（LUA_TEST_REDIS_HOST，key 前缀 lua_router_test:）")
if not (_G.ngx and ngx.socket) then
    io.write("    SKIP: 无 cosocket（luajit 环境）；用 apisix 镜像的 resty + --network host 跑此段\n")
    skipped = skipped + 1
else
    local host = os.getenv("LUA_TEST_REDIS_HOST")
    local port = tonumber(os.getenv("LUA_TEST_REDIS_PORT") or "6379")
    local password = os.getenv("LUA_TEST_REDIS_PASSWORD")
    redis.set_transport(nil)
    redis.configure({ host = host, port = port, password = password, db = 0,
        prefix = "lua_router_test:", timeout_ms = 3000 })
    reset_history()
    redis.install()
    local ok, err = redis.ping()
    if not ok then
        io.write("    SKIP: Redis 不可达: " .. tostring(err and err.message) .. "\n")
        skipped = skipped + 1
    else
        local conv, cerr = history.create_conversation({ probe = "redis-smoke" })
        check(conv ~= nil, "真实 create_conversation", cerr and cerr.message)
        local items, ierr2 = history.create_items(conv.id, {
            { type = "message", role = "user", content = "ping from test" },
            { type = "message", role = "assistant", content = "pong" },
        })
        check(items ~= nil and #items.data == 2, "真实 create_items", ierr2 and ierr2.message)
        local page = history.list_items(conv.id, { limit = 1, order = "asc" })
        eq(page and #page.data, 1, "真实分页 limit")
        eq(page and page.has_more, true, "真实 has_more")
        local raw = cjson.encode({ id = conv.id:sub(4) .. "-resp", status = "completed" })
        local rid = cjson.decode(raw).id
        local stored = history.create_response(raw)
        check(stored ~= nil, "真实 create_response")
        local back = history.get_response(rid)
        eq(type(back) == "string" and back or nil, raw, "真实 raw 字节回放")
        local st = history.stats()
        check((st.conversations or 0) >= 1, "真实 stats 计数")
        history.delete_response(rid)
        history.delete_conversation(conv.id)
        local cleaned = redis.flush_all()
        eq(cleaned, true, "flush_all 清理测试 key")
        local leftovers = redis.cmd({ "KEYS", "lua_router_test:*" })
        eq(type(leftovers) == "table" and #leftovers or -1, 0, "lua_router_test: 前缀已清空")
    end
end

--------------------------------------------------------------------------
io.write("" .. LF)
if failed > 0 then
    io.write("FAILED " .. failed .. " checks:" .. LF)
    for i = 1, #failures do
        io.write("  - " .. failures[i] .. LF)
    end
    io.write("" .. LF)
end
io.write(passed .. " passed, " .. failed .. " failed, " .. skipped .. " skipped" .. LF)
os.exit(failed == 0 and 0 or 1)
