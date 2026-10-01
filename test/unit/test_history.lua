#!/usr/bin/env luajit
-- history.lua 单测：conversation / item / response 三层存储的语义与边界。
--   运行（纯 luajit，用内存表替身，不需要 shared dict）：
--   docker run --rm -v "$PWD:/repo:ro" -w /repo authz:latest \
--     /usr/local/openresty/luajit/bin/luajit /repo/test/unit/test_history.lua
--   同一份文件在 apache/apisix:3.11.0-debian 的 resty 里也能跑，两边断言一致。
--
-- 为什么能脱离 nginx 跑：history.lua 只通过 _M.use_dict 拿存储句柄、通过
-- pcall(require, "resty.lock") 拿锁。这里给一张实现了 get/set/add/delete/incr/
-- get_keys 的内存表，锁自动退化为单进程顺序执行；真正的跨进程互斥由接线后的
-- test_lua_router.sh 契约段验证（见 doc/gap-history.md）。
--
-- cjson.safe 把 JSON null 解成 cjson.null（userdata），所以 metadata 的
-- "null 删键" 语义要用 cjson.null 构造，这才是 router 解出来的真实形状。

package.path = (os.getenv("LUA_TEST_LIB") or "./lualib") .. "/?.lua;" .. package.path
package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath

local cjson = require "cjson.safe"
local history = require "resty.luarouter.history"

--------------------------------------------------------------------------
-- 极简断言框架（与 test_tree.lua 一致）
--------------------------------------------------------------------------
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

--------------------------------------------------------------------------
-- ngx.shared.DICT 替身
--------------------------------------------------------------------------
local function new_fake_dict()
    return setmetatable({ store = {}, expire = {}, fail_next = false }, { __index = {
        get = function(self, k) return self.store[k] end,
        set = function(self, k, v, ttl)
            if self.fail_next then return nil, "no memory" end
            self.store[k] = v
            self.expire[k] = (tonumber(ttl) and ttl > 0) and (os.time() + ttl) or 0
            return true
        end,
        add = function(self, k, v, ttl)
            if self.store[k] ~= nil then return false, "exists" end
            return self:set(k, v, ttl)
        end,
        delete = function(self, k)
            self.store[k] = nil
            self.expire[k] = nil
        end,
        incr = function(self, k, delta, init)
            local v = self.store[k]
            if v == nil then
                v = init or 0
            elseif type(v) ~= "number" then
                return nil, "not a number"
            end
            v = v + delta
            self.store[k] = v
            return v
        end,
        get_keys = function(self, n)
            local out = {}
            for k in pairs(self.store) do
                if not n or n == 0 or #out < n then
                    out[#out + 1] = k
                end
            end
            return out
        end,
        flush_all = function(self)
            self.store = {}
            self.expire = {}
        end,
    } })
end

local fake
local cfg

local function reset()
    fake = new_fake_dict()
    history.use_dict(fake)
    cfg = history.config()
    cfg.backend = "memory"
    cfg.max_conversations = 10000
    cfg.max_items_per_conversation = 1000
    cfg.max_responses = 10000
    cfg.max_items_per_request = 1000
    cfg.ttl_secs = 0
    return fake
end

local function err_is(err, status, code)
    return type(err) == "table" and err.status == status
        and (code == nil or err.code == code)
end

---Key count in the fake dict, so "wrote nothing" can be asserted as a delta.
local function leftover()
    local n = 0
    for _ in pairs(fake.store) do n = n + 1 end
    return n
end

---Assert success, and print the error when there is one.
local function ok(res, err, name)
    check(res ~= nil, name,
        err and (tostring(err.status) .. "/" .. tostring(err.code) .. " "
            .. tostring(err.message)) or "nil result")
end

reset()

--------------------------------------------------------------------------
new_case("config：后端取值集合与常量对齐 Rust")
eq(cfg.backend, "memory", "未设置 env 时后端默认 memory")
check(history.contains(history.BACKEND_VALUES, "memory")
    and history.contains(history.BACKEND_VALUES, "none")
    and history.contains(history.BACKEND_VALUES, "oracle")
    and history.contains(history.BACKEND_VALUES, "redis")
    and history.contains(history.BACKEND_VALUES, "postgres"),
    "BACKEND_VALUES 是 CLI value_parser 的五个取值")
eq(#history.BACKEND_VALUES, 5, "取值不多不少")
eq(history.MAX_METADATA_PROPERTIES, 16, "metadata 上限 16")
eq(history.DEFAULT_PAGE_SIZE, 100, "默认分页 100")
eq(history.SUPPORTED_ITEM_TYPES[1], "message", "SUPPORTED_ITEM_TYPES 首项 message")
eq(#history.SUPPORTED_ITEM_TYPES, 19, "19 种 item type 与 handlers.rs 同数")
eq(#history.IMPLEMENTED_ITEM_TYPES, 5, "5 种已实现")
eq(history.IMPLEMENTED_ITEM_TYPES[5], "item_reference", "已实现项含 item_reference")
check(history.ITEM_TYPE_FIELDS.mcp_call[1] == "name", "ITEM_TYPE_FIELDS 对齐 persistence_utils")

--------------------------------------------------------------------------
new_case("memory 后端：create 返回 conversation 对象")
do
    local conv, err = history.create_conversation({ user = "alice", topic = "math" })
    ok(conv, err, "create 带 metadata")
    eq(conv.object, "conversation", "object=conversation")
    check(type(conv.created_at) == "number", "created_at 是 unix 秒")
    check(math.abs(conv.created_at - os.time()) <= 2, "created_at 接近当前时间")
    eq(conv.metadata.user, "alice", "create 回显 metadata")
    local got, gerr = history.get_conversation(conv.id)
    ok(got, gerr, "get 命中")
    eq(got.id, conv.id, "get 返回同一 id")
    eq(got.created_at, conv.created_at, "created_at 不随读改写")
    eq(got.metadata.topic, "math", "get 保留 metadata")
    local bare, berr = history.create_conversation()
    ok(bare, berr, "无 metadata 也能创建")
    eq(bare.metadata, nil, "空 metadata 整体省略（对齐 conversation_to_json）")
    local explicit_empty = history.create_conversation({})
    eq(explicit_empty.metadata, nil, "显式空对象同样省略 metadata 字段")
    local with_id = history.create_conversation({ a = 1 }, { id = "conv_client" })
    ok(with_id, nil, "允许客户端自带 id（NewConversation.id）")
    eq(with_id.id, "conv_client", "自带 id 原样使用")
    local dup = history.create_conversation(nil, { id = "conv_client" })
    check(dup == nil, "重复 id 不会静默覆盖")
end

--------------------------------------------------------------------------
new_case("register_backend：注册表可让未实现名字落地（501 门控让位）")
do
    reset()
    local fake_store = {}
    local stub = {
        get_conversation = function(id) return fake_store[id] end,
        store_conversation = function(conv)
            fake_store[conv.id] = conv
            return conv
        end,
        drop_conversation = function(id) fake_store[id] = nil; return true end,
        enforce_conversation_cap = function() return 0 end,
        get_item = function() return nil end,
        store_item = function(item) return item end,
        link_item = function() return true end,
        is_item_linked = function() return false end,
        unlink_item = function() return true end,
        index = function() return {} end,
        score_of = function() return nil end,
        get_response = function() return nil end,
        store_response = function(rec) return rec end,
        delete_response = function() return false end,
        enforce_response_cap = function() return 0 end,
    }
    local reg, rerr = history.register_backend("redis", stub)
    check(reg == true and rerr == nil, "register_backend 接受自定义实现", rerr)
    local bad, berr = history.register_backend("postgres", "not-a-table")
    check(bad == nil and berr ~= nil, "非表实现被拒而不是崩")
    cfg.backend = "redis"
    local supported, serr = history.backend_supported()
    check(supported == true and serr == nil, "注册后 redis 不再是 501")
    local conv, cerr = history.create_conversation({ x = 1 })
    check(conv ~= nil, "redis 走注册表实现创建成功",
        cerr and tostring(cerr.message))
    if conv then
        eq(conv.metadata.x, 1, "create 结果由 stub 回显")
    end
    check(next(fake_store) ~= nil, "写入落进 stub 而不是 memory dict")
    local got = conv and history.get_conversation(conv.id)
    check(got ~= nil and got.id == conv.id, "读也走注册表")
    local deleted, derr = conv and history.delete_conversation(conv.id)
    check(deleted ~= nil and derr == nil, "delete 也走注册表")
    check(next(fake_store) == nil, "stub 的删除生效")
    history.BACKENDS.redis = nil
    -- backend 仍是 redis，只是注册表里没有了：门控必须重新接管
    local r2, e2 = history.create_conversation()
    check(r2 == nil and e2 and e2.status == 501, "撤销注册后 redis 恢复 501")
    eq(history.stats().supported, false, "stats 也跟着回到 unsupported")
    cfg.backend = "memory"
end

new_case("后端门控：none 走 NoOp，redis/postgres/oracle 明确 501")
for _, name in ipairs({ "redis", "postgres", "oracle" }) do
    cfg.backend = name
    local res, err = history.create_conversation()
    check(res == nil and err_is(err, 501, "history_backend_unsupported"),
        name .. " create 返回 501")
    check(err and err.message:find(name, 1, true) ~= nil, name .. " 的 message 点名该后端")
    check(err and err.message:find("memory or none", 1, true) ~= nil,
        name .. " 的 message 给出可用替代")
    for _, call in ipairs({
        function() return history.get_conversation("conv_x") end,
        function() return history.update_conversation("conv_x", { metadata = {} }) end,
        function() return history.delete_conversation("conv_x") end,
        function() return history.list_items("conv_x") end,
        function() return history.create_items("conv_x", { { role = "user" } }) end,
        function() return history.get_item("conv_x", "msg_x") end,
        function() return history.delete_item("conv_x", "msg_x") end,
        function() return history.create_response({}) end,
        function() return history.get_response("resp_x") end,
        function() return history.cancel_response("resp_x") end,
        function() return history.delete_response("resp_x") end,
        function() return history.list_input_items("resp_x") end,
    }) do
        local r, e = call()
        check(r == nil and e and e.status == 501, name .. " 读路径同样 501")
    end
end
cfg.backend = "none"
do
    local clean = leftover()
    local conv, err = history.create_conversation({ k = "v" })
    ok(conv, err, "none 后端 create 仍返回对象（NoOp 语义）")
    check(conv.id:match("^conv_[0-9a-f]+$") ~= nil, "none 也发真实形状的 id")
    local again, gerr = history.get_conversation(conv.id)
    check(again == nil and err_is(gerr, 404, "not_found"), "none 后端读不到任何东西")
    local listed, lerr = history.list_items(conv.id)
    check(listed == nil and lerr.status == 404, "none 后端 items 列表 404")
    eq(history.stats().conversations, 0, "none 后端 stats 计 0")
    local resp, rerr = history.create_response({ status = "completed", output = {} })
    ok(resp, rerr, "none 后端 create_response 成功")
    local got = history.get_response(type(resp) == "string" and "" or resp.id)
    check(got == nil, "none 后端 response 读不回")
    local del, derr = history.delete_response("resp_whatever")
    ok(del, derr, "none 后端 delete 无条件成功（NoOpResponseStorage）")
    eq(leftover(), clean, "none 后端完全不向 dict 写入")
end
cfg.backend = "memory"

--------------------------------------------------------------------------
new_case("dict 未声明时报 503 并点名 dict，而不是崩在 nil 上")
history.use_dict(nil)
do
    local res, err = history.create_conversation()
    check(res == nil and err_is(err, 503, "history_unavailable"), "缺 shared dict 报 503")
    check(err.message:find(history.DICT, 1, true) ~= nil, "503 message 点名 dict 名")
    check(err.message:find("lua_shared_dict", 1, true) ~= nil, "503 message 给出修复方向")
    local r2, e2 = history.get_conversation("conv_x")
    check(r2 == nil and e2.status == 503, "读路径同样 503")
end
reset()

--------------------------------------------------------------------------
new_case("ID 与时间戳：conv_ / <prefix>_ / ULID 形状")
do
    local id = history.new_conversation_id()
    check(id:match("^conv_[0-9a-f]+$") ~= nil, "conv_<50 hex>", id)
    eq(#("conv_" .. string.rep("0", 50)), 55, "conversation id 长 55")
    local seen = {}
    for i = 1, 200 do
        local n = history.new_conversation_id()
        check(not seen[n], "conversation id 不重复 #" .. i)
        seen[n] = true
    end
    eq(#(history.new_item_id("message"):match("^msg_([0-9a-f]+)$") or ""), 50, "msg_ + 50 hex")
    eq(history.new_item_id("reasoning"):sub(1, 3), "rs_", "reasoning -> rs")
    eq(history.new_item_id("mcp_call"):sub(1, 4), "mcp_", "mcp_call -> mcp")
    eq(history.new_item_id("mcp_list_tools"):sub(1, 5), "mcpl_", "mcp_list_tools -> mcpl")
    eq(history.new_item_id("function_call"):sub(1, 3), "fc_", "function_call -> fc")
    eq(history.new_item_id("web_search_call"):sub(1, 4), "web_", "未知类型取前三字母")
    eq(history.new_item_id(""):sub(1, 4), "itm_", "空类型退化为 itm")
    local rid = history.new_response_id()
    eq(#rid, 26, "response id 是 26 字符 ULID")
    check(rid:match("^[0-9A-HJKMNP-TV-Z]+$") ~= nil, "ULID 用 Crockford base32 字母表", rid)
    local older = history.new_response_id()
    local newer = history.new_response_id()
    check(older ~= newer, "同毫秒内随机位保证不重复")
    eq(older:sub(1, 10), newer:sub(1, 10), "同毫秒共享时间前缀（标准 ULID 语义）")
end

--------------------------------------------------------------------------
new_case("ULID 实现自检：48 位毫秒前缀 + 80 位随机")
do
    -- 时间前缀必须可解码回毫秒，否则 GET 的排序语义无从谈起。
    local alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    local function value_of(ch)
        return (alphabet:find(ch, 1, true) or 1) - 1
    end
    local id = history.new_response_id()
    local ms = 0
    for i = 1, 10 do
        ms = ms * 32 + value_of(id:sub(i, i))
    end
    local now_ms = math.floor(os.time() * 1000)
    check(math.abs(ms - now_ms) < 5000, "标准 ULID 解析器可从前 10 字符读回毫秒", ms)
    check(history.new_response_id():sub(11, 26) ~= history.new_response_id():sub(11, 26),
        "后 16 字符逐次不同")
end

--------------------------------------------------------------------------
new_case("metadata：合并、null 删键、16 键上限")
local conv
do
    conv = history.create_conversation({ user = "alice", topic = "math" }).id
end
do
    local res, err = history.update_conversation(conv, { metadata = { topic = "code", extra = 1 } })
    ok(res, err, "update 合并新键")
    eq(res.metadata.topic, "code", "update 覆盖已有键")
    eq(res.metadata.user, "alice", "update 保留未提及的键")
    eq(res.metadata.extra, 1, "update 追加新键")
end
do
    -- 真·JSON null：router 用 cjson 解 body，null 落成 cjson.null（userdata）
    local body = cjson.decode('{"metadata":{"topic":null,"extra":null,"keep":2}}')
    local res, err = history.update_conversation(conv, body)
    ok(res, err, "null 值删键")
    eq(res.metadata.topic, nil, "null 删掉 topic")
    eq(res.metadata.extra, nil, "null 删掉 extra")
    eq(res.metadata.user, "alice", "null 不误删未提及的键")
    eq(res.metadata.keep, 2, "null 与赋值可同批")
    local res2, err2 = history.update_conversation(conv, cjson.decode('{"metadata":{"keep":null,"user":null}}'))
    ok(res2, err2, "删空最后一个键")
    eq(res2.metadata, nil, "metadata 全空时整体省略")
    local res3 = history.update_conversation(conv, { metadata = {} })
    eq(res3.metadata, nil, "空 patch 不改内容")
end
do
    local big = {}
    for i = 1, 16 do big["k" .. i] = i end
    local res, err = history.create_conversation(big)
    ok(res, err, "恰好 16 键通过")
    eq(res.metadata.k16, 16, "16 键全部回显")
    local body = cjson.decode(cjson.encode(big))
    body.k17 = 17
    local res2, err2 = history.create_conversation(body)
    check(res2 == nil and err_is(err2, 400, "invalid_request_error"), "17 键被拒")
    check(err2.message:find("16", 1, true) ~= nil, "越界 message 报出上限")
    local res3, err3 = history.update_conversation(conv, { metadata = body })
    check(res3 == nil and err3.status == 400, "update 合并结果超限同样被拒")
    check(err3.message:find("16", 1, true) ~= nil, "合并超限的 message 报出上限")
    local res4, err4 = history.update_conversation("conv_missing", { metadata = {} })
    check(res4 == nil and err4.status == 404, "update 不存在先 404")
    local res5, err5 = history.update_conversation(conv, { metadata = { "array", "form" } })
    check(res5 == nil and err5.status == 400, "metadata 传数组被拒")
    local res6, err6 = history.update_conversation(conv, "not-a-table")
    check(res6 == nil and err6.status == 400, "body 非对象报 400")
    local res7, err7 = history.create_conversation({ "arr" })
    check(res7 == nil and err7.status == 400, "create 传数组同样被拒")
end
do
    -- 16 键上限在 patch 上按合并后的总数算，而不是按 patch 条数
    local many = {}
    for i = 1, 15 do many["m" .. i] = i end
    local c2 = history.create_conversation(many).id
    local res, err = history.update_conversation(c2, { metadata = { added = 1 } })
    ok(res, err, "合并后恰好 16 键通过")
    local res2, err2 = history.update_conversation(c2, { metadata = { added = 1, another = 2 } })
    check(res2 == nil and err2.status == 400, "合并后 17 键被拒")
end

--------------------------------------------------------------------------
new_case("delete_conversation：返回 deleted 标记并连带清索引")
do
    local tmp = history.create_conversation()
    local created = history.create_items(tmp.id, {
        { type = "message", role = "user", content = "one" },
        { type = "message", role = "assistant", content = "two" },
    })
    local before = fake.store[history.KEYS.n_conv]
    check(fake.store[history.KEYS.link .. tmp.id] ~= nil, "link 索引已写入")
    check(fake.store[history.KEYS.rev .. tmp.id .. "|" .. created.data[1].id] ~= nil,
        "after 游标的反向索引已写入")
    check(fake.store[history.KEYS.item .. created.data[1].id] ~= nil, "item 记录已写入")
    local res, err = history.delete_conversation(tmp.id)
    ok(res, err, "delete 成功")
    eq(res.object, "conversation.deleted", "object=conversation.deleted")
    check(res.deleted == true, "deleted=true")
    eq(res.id, tmp.id, "回显 id")
    check(fake.store[history.KEYS.conv .. tmp.id] == nil, "conversation 记录已删")
    check(fake.store[history.KEYS.link .. tmp.id] == nil, "link 索引已删")
    check(fake.store[history.KEYS.rev .. tmp.id .. "|" .. created.data[1].id] == nil,
        "反向索引已删")
    check(fake.store[history.KEYS.item .. created.data[1].id] == nil,
        "归属该 conversation 的 item 记录一并回收")
    eq(fake.store[history.KEYS.n_conv], before - 1, "计数随删除回落")
    local res2, err2 = history.delete_conversation(tmp.id)
    check(res2 == nil and err_is(err2, 404, "not_found"), "重复 delete 报 404")
    check(err2.message:find("Conversation not found", 1, true) ~= nil,
        "404 措辞对齐 handlers.rs")
end
do
    for _, bad in ipairs({ "", "has space", "has|pipe", "a,b", string.rep("x", 200), 42 }) do
        local res, err = history.get_conversation(bad)
        check(res == nil and err ~= nil and err.status == 400,
            "非法 conversation_id 被拒: " .. tostring(bad))
    end
    local res, err = history.get_conversation(nil)
    check(res == nil and err.status == 400, "nil id 报 400 而不是崩")
end

--------------------------------------------------------------------------
local conv_id = history.create_conversation({ room = "lab" }).id

new_case("items：批量创建与渲染规则")
local item_ids = {}
do
    local res, err = history.create_items(conv_id, {
        { role = "user", content = "hi" },                    -- 无 type 默认 message
        { type = "message", role = "assistant", content = { { type = "output_text", text = "yo" } } },
        { type = "reasoning" },
        { type = "web_search_call", call_id = "c1" },         -- 已知但未实现 -> warning
    })
    ok(res, err, "批量 create_items")
    eq(res.object, "list", "envelope object=list")
    eq(#res.data, 4, "四条 item 全部返回")
    eq(res.has_more, false, "create 的 has_more 恒 false")
    check(res.warnings and #res.warnings == 1, "未实现类型给一条 warning")
    check(res.warnings[1]:find("web_search_call", 1, true) ~= nil, "warning 点名类型")
    check(res.warnings[1]:find("not yet implemented", 1, true) ~= nil,
        "warning 措辞对齐 handlers.rs")
    eq(res.data[1].type, "message", "无 type 按 message 处理")
    eq(res.data[1].role, "user", "role 透传")
    eq(res.data[1].status, "completed", "status 默认 completed")
    eq(res.data[1].content, "hi", "content 原样存")
    eq(res.data[3].type, "reasoning", "reasoning 类型保持")
    eq(res.data[3].content ~= nil, true, "reasoning 缺 content 时补空数组")
    eq(res.data[4].content.call_id, "c1", "未映射类型整对象入库，字段在 content 下")
    eq(res.data[4].content, res.data[4].content, "未映射类型不透平（对齐 ITEM_TYPE_FIELDS 白名单）")
    eq(res.first_id, res.data[1].id, "first_id 指向首条")
    eq(res.last_id, res.data[4].id, "last_id 指向末条")
    for i = 1, #res.data do
        item_ids[#item_ids + 1] = res.data[i].id
        check(type(res.data[i].created_at) == "number", "列表渲染带 created_at")
    end
    eq(res.data[1].id:sub(1, 4), "msg_", "message 的 id 前缀")
    eq(res.data[3].id:sub(1, 3), "rs_", "reasoning 的 id 前缀")
end
do
    local res, err = history.get_item(conv_id, item_ids[2])
    ok(res, err, "get_item 命中")
    eq(res.id, item_ids[2], "get_item 回显 id")
    eq(res.created_at, nil, "单条渲染不带 created_at（对齐 item_to_json）")
    check(type(res.content) == "table", "get_item 渲染出 content")
    local res2, err2 = history.get_item(conv_id, item_ids[4])
    ok(res2, err2, "未实现类型也能单条取回")
    eq(res2.type, "web_search_call", "类型保持")
    local res3, err3 = history.get_item(conv_id, "msg_" .. string.rep("a", 50))
    check(res3 == nil and err_is(err3, 404, "not_found"), "未 link 的 item 报 404")
    check(err3.message:find("Item not found in this conversation", 1, true) ~= nil,
        "404 措辞对齐 handlers.rs")
    local res4, err4 = history.get_item("conv_missing", item_ids[1])
    check(res4 == nil and err4.status == 404, "conversation 不存在先报 conversation 404")
end
do
    -- function_call 类字段按 ITEM_TYPE_FIELDS 抬平，而不是整包塞在 content 里
    local res = history.create_items(conv_id, {
        { type = "function_call", call_id = "call_9", name = "lookup", arguments = '{"q":"x"}' },
        { type = "function_call_output", call_id = "call_9", output = "42" },
    })
    ok(res, nil, "function_call 与 output 可入库")
    eq(res.data[1].name, "lookup", "function_call 抬平 name")
    eq(res.data[1].arguments, '{"q":"x"}', "function_call 抬平 arguments")
    eq(res.data[2].output, "42", "function_call_output 抬平 output")
    eq(res.data[1].content, nil, "抬平后不再重复出现 content")
    history.delete_item(conv_id, res.data[1].id)
    history.delete_item(conv_id, res.data[2].id)
end

new_case("items：校验与单请求上限")
do
    local res, err = history.create_items(conv_id, { { type = "nonsense_type" } })
    check(res == nil and err_is(err, 400, "invalid_request_error"), "未知 item type 被拒")
    check(err.message:find("Unsupported item type", 1, true) ~= nil, "message 对齐 Rust")
    check(err.message:find("message", 1, true) ~= nil, "message 列出可用类型")
    local res2, err2 = history.create_items(conv_id, { { type = "message" } })
    check(res2 == nil and err2.status == 400, "message 缺 role 被拒")
    check(err2.message:find("role", 1, true) ~= nil, "缺 role 报出字段名")
    local res3, err3 = history.create_items(conv_id, "not-a-list")
    check(res3 == nil and err3.status == 400, "items 非数组报 400")
    local res4, err4 = history.create_items(conv_id, nil)
    check(res4 == nil and err4.status == 400, "items 缺失报 400")
    local res5, err5 = history.create_items("conv_missing", { { role = "user" } })
    check(res5 == nil and err5.status == 404, "conversation 不存在时 404")
    local res6, err6 = history.create_items(conv_id, { { type = "item_reference" } })
    check(res6 == nil and err6.status == 400, "item_reference 缺 id 报 400")
end
do
    local many = {}
    for i = 1, 101 do many[i] = { type = "message", role = "user", content = "x" } end
    cfg.max_items_per_request = 100
    local res, err = history.create_items(conv_id, many)
    check(res == nil and err_is(err, 400, "invalid_request_error"), "单请求 101 条被拒")
    check(err.message:find("100", 1, true) ~= nil, "越界 message 报出上限")
    eq(err.param, "items", "越界带 param=items")
    many[101] = nil
    local res2, err2 = history.create_items(conv_id, many)
    ok(res2, err2, "恰好 100 条通过")
    eq(#res2.data, 100, "100 条全部入库")
    -- 100 条上限可配置回 Rust 的 20
    cfg.max_items_per_request = 20
    local res3, err3 = history.create_items(conv_id, { many[1], many[2] })
    ok(res3, err3, "降到 20 后小批量仍通过")
    local res4, err4 = history.create_items(conv_id, many)
    check(res4 == nil and err4.message:find("20", 1, true) ~= nil,
        "上限可经 SMG_HISTORY_MAX_ITEMS_PER_REQUEST 收紧到 Rust 的 20")
    cfg.max_items_per_request = 1000
    for i = 1, #res2.data do
        history.delete_item(conv_id, res2.data[i].id)
    end
    for i = 1, #res3.data do
        history.delete_item(conv_id, res3.data[i].id)
    end
    eq(#history.list_items(conv_id).data, 4, "清完临时条目")
end

new_case("items：自带 id、重复 link、item_reference 跨会话共享")
do
    local created, err = history.create_items(conv_id, {
        { id = "msg_fixed0001", type = "message", role = "user", content = "fixed id" },
    })
    ok(created, err, "客户端自带 item id")
    eq(created.data[1].id, "msg_fixed0001", "自带 id 原样使用")
    local dup, derr = history.create_items(conv_id, {
        { id = "msg_fixed0001", type = "message", role = "user", content = "again" },
    })
    check(dup == nil and derr and derr.code == "item_already_in_conversation",
        "同 conversation 重复 link 报 item_already_in_conversation")
    local other = history.create_conversation().id
    local link, lerr = history.create_items(other, {
        { type = "item_reference", id = "msg_fixed0001" },
    })
    ok(link, lerr, "item_reference 链接既有 item")
    eq(link.data[1].id, "msg_fixed0001", "reference 返回既有 item")
    eq(link.data[1].content, "fixed id", "reference 返回原 content")
    eq(link.data[1].role, "user", "reference 返回原 role")
    local miss, merr = history.create_items(other, {
        { type = "item_reference", id = "msg_never_exists" },
    })
    check(miss == nil and merr and merr.status == 404, "reference 指向不存在报 404")
    check(merr.message:find("Referenced item", 1, true) ~= nil, "reference 404 措辞对齐 Rust")
    local still = history.get_item(conv_id, "msg_fixed0001")
    ok(still, nil, "被引用的 item 仍留在原 conversation")
    local bad_id, biderr = history.create_items(conv_id, {
        { id = "bad id with spaces", type = "message", role = "user" },
    })
    check(bad_id == nil and biderr.status == 400, "自带非法 id 被拒")
end

new_case("items：分页、order、after 游标")
local page_conv = history.create_conversation().id
do
    for i = 1, 5 do
        history.create_items(page_conv, { { type = "message", role = "user", content = "c" .. i } })
    end
    local all, err = history.list_items(page_conv)
    ok(all, err, "默认分页")
    eq(#all.data, 5, "默认 limit 100 一次给完")
    eq(all.data[1].content, "c5", "默认 order=desc：最新在前")
    eq(all.data[5].content, "c1", "desc 末条最旧")
    check(all.has_more == false, "未填满页 has_more=false")
    local asc, aerr = history.list_items(page_conv, { order = "asc" })
    ok(asc, aerr, "order=asc")
    eq(asc.data[1].content, "c1", "asc 最旧在前")
    eq(asc.data[5].content, "c5", "asc 末条最新")
    local bogus = history.list_items(page_conv, { order = "BOGUS" })
    eq(bogus.data[1].content, "c5", "非 asc 一律按 desc（对齐 Rust 的 match）")
end
do
    local asc = history.list_items(page_conv, { order = "asc" })
    local p2, p2err = history.list_items(page_conv, { order = "asc", after = asc.data[2].id })
    ok(p2, p2err, "asc + after 游标")
    eq(#p2.data, 3, "游标之后三条")
    eq(p2.data[1].content, "c3", "游标 exclusive")
    eq(p2.first_id, p2.data[1].id, "翻页后 first_id 跟着走")
    local d2 = history.list_items(page_conv, { after = asc.data[3].id })
    eq(#d2.data, 2, "desc + after 取更早两条")
    eq(d2.data[1].content, "c2", "desc 游标同样 exclusive")
    local tail = history.list_items(page_conv, { order = "asc", after = asc.data[5].id })
    eq(#tail.data, 0, "asc 游标到尾返回空页")
    eq(tail.has_more, false, "空页 has_more=false")
    eq(tail.first_id, nil, "空页省略 first_id")
    eq(tail.last_id, nil, "空页省略 last_id")
    local unknown = history.list_items(page_conv, { after = "msg_not_linked" })
    eq(#unknown.data, 5, "游标指向未 link 的 item 时退化为无游标（Rust 同样行为）")
    local bad, berr = history.list_items(page_conv, { after = "bad cursor" })
    check(bad == nil and berr.status == 400, "非法游标报 400")
end
do
    local p1 = history.list_items(page_conv, { limit = 2 })
    eq(#p1.data, 2, "limit 生效")
    check(p1.has_more == true, "填满页 has_more=true（Rust 口径：下一页可能仍为空）")
    local p2 = history.list_items(page_conv, { limit = 2, after = p1.last_id })
    eq(#p2.data, 2, "第二页两条")
    local p3 = history.list_items(page_conv, { limit = 2, after = p2.last_id })
    eq(#p3.data, 1, "第三页一条")
    eq(p3.has_more, false, "末页不满 has_more=false")
    local bad, berr = history.list_items(page_conv, { limit = 0 })
    check(bad == nil and berr.status == 400, "limit 0 报 400")
    local bad2, berr2 = history.list_items(page_conv, { limit = -3 })
    check(bad2 == nil and berr2.status == 400, "limit 负数报 400")
    local bad3, berr3 = history.list_items(page_conv, { limit = "abc" })
    check(bad3 == nil and berr3.status == 400, "limit 非数字报 400")
    eq(berr3.param, "limit", "limit 报错带 param")
    local big = history.list_items(page_conv, { limit = 99999 })
    ok(big, nil, "limit 超上限夹到 MAX_PAGE_SIZE 而不是报错")
    local miss, merr = history.list_items("conv_missing")
    check(miss == nil and merr.status == 404, "list 不存在 conversation 报 404")
end
do
    -- 同一秒批量写入时翻页顺序仍要稳定：排序键是入库序号而非秒
    local fast = history.create_conversation().id
    for i = 1, 30 do
        history.create_items(fast, { { type = "message", role = "user", content = "f" .. i } })
    end
    local collected = {}
    local cursor
    for page = 1, 15 do
        local res = history.list_items(fast, { limit = 2, order = "asc", after = cursor })
        for i = 1, #res.data do
            collected[#collected + 1] = res.data[i].content
        end
        cursor = res.last_id
        if not res.has_more then break end
    end
    eq(#collected, 30, "同秒写入逐页翻完 30 条")
    eq(collected[1], "f1", "第一页首条")
    eq(collected[15], "f15", "第 15 页不乱序")
    eq(collected[30], "f30", "末条是最后写入的")
    local seen = {}
    for i = 1, #collected do
        check(not seen[collected[i]], "游标翻页不重复: " .. collected[i])
        seen[collected[i]] = true
    end
end

new_case("items：delete_item 只解链，返回 conversation 对象")
do
    local shared_conv = history.create_conversation().id
    local created = history.create_items(conv_id, {
        { id = "msg_shared", type = "message", role = "user", content = "shared" },
    })
    eq(created.data[1].id, "msg_shared", "创建将被共享的 item")
    history.create_items(shared_conv, { { type = "item_reference", id = "msg_shared" } })
    local res, err = history.delete_item(conv_id, "msg_shared")
    ok(res, err, "delete_item 成功")
    eq(res.object, "conversation", "delete_item 返回 conversation 对象（对齐 Rust）")
    eq(res.id, conv_id, "回显 conversation id")
    local gone, gerr = history.get_item(conv_id, "msg_shared")
    check(gone == nil and gerr.status == 404, "本 conversation 已看不到该 item")
    local kept, kerr = history.get_item(shared_conv, "msg_shared")
    ok(kept, kerr, "delete_item 只解本会话的链")
    eq(kept.id, "msg_shared", "item 记录仍在，另一 conversation 照常读到")
    eq(kept.content, "shared", "记录内容未被动过")
    local again, aerr = history.delete_item(conv_id, "msg_shared")
    ok(again, aerr, "重复 delete 不报错（Rust storage 层无条件成功）")
    local miss, merr = history.delete_item("conv_missing", "msg_shared")
    check(miss == nil and merr.status == 404, "delete_item 对不存在 conversation 报 404")
end

new_case("response：原始字节回显、id 生成、cancel、delete")
local raw = '{"id":"resp_01JTESTAAAA0000000000000","object":"response","status":"completed",'
    .. '"model":"qwen3","output":[{"type":"message","role":"assistant","content":[]}],'
    .. '"usage":{"input_tokens":11,"output_tokens":22,"total_tokens":33},"created_at":1769800000}'
local resp_id
do
    local res, err = history.create_response(raw)
    ok(res, err, "create_response 接受上游原始 JSON 字节")
    check(type(res) == "string", "有原始字节时返回原始字节", type(res))
    resp_id = res:match('"id"%s*:%s*"([^"]+)"')
    eq(resp_id, "resp_01JTESTAAAA0000000000000", "沿用上游 id")
    local got, gerr = history.get_response(resp_id)
    ok(got, gerr, "get_response 命中")
    eq(got, raw, "GET 回显与上游字节完全一致（raw_response 语义）")
    local miss, merr = history.get_response("resp_missing")
    check(miss == nil and merr.status == 404, "不存在的 response 报 404")
    check(merr.message:find("No response found with id", 1, true) ~= nil,
        "404 措辞对齐 openai/router.rs")
    local bad, berr = history.create_response("")
    check(bad == nil and berr.status == 400, "空 payload 报 400")
    local bad2, berr2 = history.create_response("not json")
    check(bad2 == nil and berr2.status == 400, "非 JSON 报 400")
    local bad3, berr3 = history.create_response("[1,2]")
    check(bad3 == nil and berr3.status == 400, "JSON 数组不是 response")
    local bad4, berr4 = history.create_response(42)
    check(bad4 == nil and berr4.status == 400, "数字 payload 报 400")
end
do
    local res, err = history.create_response({
        status = "in_progress", model = "m1", output = {}, input = {},
        usage = { total_tokens = 0 },
    })
    ok(res, err, "create_response 也接受已解码的表")
    eq(#res.id, 26, "自动生成 26 字符 ULID")
    eq(res.status, "in_progress", "status 透传")
    eq(res.model, "m1", "model 透传")
    local text = history.encode(res)
    check(text:find('"output":%[%]') ~= nil, "空 output 编码为 []", text)
    check(text:find('"instructions"', 1, true) == nil, "未设置的字段整体省略")
    check(text:find('"usage"', 1, true) ~= nil, "usage 原样保留")
    local c, cerr = history.cancel_response(res.id)
    ok(c, cerr, "in_progress 可 cancel")
    eq(c.status, "cancelled", "cancel 后状态为 cancelled")
    local c2 = history.cancel_response(res.id)
    eq(c2.status, "cancelled", "重复 cancel 幂等")
    local done = history.create_response({ status = "completed" })
    local c3, c3err = history.cancel_response(done.id)
    check(c3 == nil and c3err.status == 400, "completed 不可 cancel")
    eq(c3err.code, "response_not_cancellable", "cancel 失败带专用 code")
    local c4, c4err = history.cancel_response("resp_missing")
    check(c4 == nil and c4err.status == 404, "cancel 不存在报 404")
end
do
    local res = history.create_response({ status = "completed", model = "m",
        output = { { type = "message", role = "assistant", content = "hi" } } })
    local del, derr = history.delete_response(res.id)
    ok(del, derr, "delete_response 成功")
    eq(del.object, "response.deleted", "delete 标记 object")
    check(del.deleted == true, "deleted=true")
    eq(del.id, res.id, "delete 回显 id")
    local gone, gerr = history.get_response(res.id)
    check(gone == nil and gerr.status == 404, "删除后读不到")
    local again, aerr = history.delete_response(res.id)
    check(again == nil and aerr.status == 404, "重复 delete 报 404")
end
do
    -- 上游只给表时按字段渲染；id 与 payload 不一致时以存储 id 为准（对齐 Rust 强制覆写 id）
    local res = history.create_response({ id = "resp_01JTESTAAAA0000000000000", status = "completed" })
    ok(res, nil, "表形式也能指定 id")
    eq(res.id, "resp_01JTESTAAAA0000000000000", "id 生效")
    local got = history.get_response(res.id)
    eq(got.id, res.id, "GET 的 id 与请求一致")
end

new_case("response：list_input_items 补 id、has_more 恒 false")
do
    local res = history.create_response({
        input = {
            { role = "user", content = "no id here" },
            { type = "message", role = "user", id = "msg_known", content = "kept" },
        },
    })
    local list, err = history.list_input_items(res.id)
    ok(list, err, "list_input_items 命中")
    eq(list.object, "list", "object=list")
    eq(#list.data, 2, "两条 input item")
    check(list.data[1].id:match("^msg_") ~= nil, "缺 id 的 input item 补 msg_ id", list.data[1].id)
    eq(list.data[2].id, "msg_known", "自带 id 不被覆盖")
    eq(list.data[1].content, "no id here", "item 内容原样返回")
    eq(list.has_more, false, "has_more 恒 false（单页给全）")
    eq(list.first_id, list.data[1].id, "first_id")
    eq(list.last_id, list.data[2].id, "last_id")
    local empty = history.create_response({ input = {} })
    local el = history.list_input_items(empty.id)
    eq(#el.data, 0, "空 input 返回空列表")
    check(history.encode(el):find('"data":%[%]') ~= nil, "空 data 编码为 []", history.encode(el))
    local miss, merr = history.list_input_items("resp_missing")
    check(miss == nil and merr.status == 404, "response 不存在报 404")
end

new_case("response：previous_response_id 链与环检测")
do
    local a = history.create_response({ status = "completed" })
    local b = history.create_response({ status = "completed", previous_response_id = a.id })
    local c = history.create_response({ status = "completed", previous_response_id = b.id })
    local chain, cerr = history.get_response_chain(c.id)
    ok(chain, cerr, "取链成功")
    eq(#chain.responses, 3, "链上三个节点")
    eq(chain.responses[1].id, a.id, "最旧优先（chronological）")
    eq(chain.responses[3].id, c.id, "末节点是入参 response")
    local shallow = history.get_response_chain(c.id, 2)
    eq(#shallow.responses, 2, "max_depth 生效")
    eq(#shallow.responses, 2, "max_depth 截断")
    eq(shallow.responses[1].id, b.id, "截断后仍按最旧优先（b -> c）")
    eq(shallow.responses[2].id, c.id, "截断保留离入参最近的一段")
    local single = history.get_response_chain(a.id)
    eq(#single.responses, 1, "无 previous 的链长度为 1")
    local miss = history.get_response_chain("resp_missing")
    eq(#miss.responses, 0, "不存在的链返回空而不是报错")
    -- 手工造环：x -> y -> x
    local x = history.create_response({ status = "completed" })
    local y = history.create_response({ status = "completed", previous_response_id = x.id })
    local rec = history.memory_store.get_response(x.id)
    rec.previous_response_id = y.id
    history.memory_store.store_response(rec)
    local cres, cerr2 = history.get_response_chain(y.id)
    check(cres == nil and cerr2.code == "response_chain_cycle", "检测到 previous_response_id 环")
end

new_case("response 与 conversation 联动：input/output 自动 link")
do
    local conv2 = history.create_conversation().id
    local res = history.create_response({
        conversation = conv2,
        status = "completed",
        model = "m",
        input = { { type = "message", role = "user", content = "ask" } },
        output = {
            { type = "message", role = "assistant", content = { { type = "output_text", text = "ans" } } },
            { type = "function_call", call_id = "call_1", name = "f", arguments = "{}" },
        },
    })
    ok(res, nil, "带 conversation 的 response 入库")
    local list = history.list_items(conv2, { order = "asc" })
    eq(#list.data, 3, "一条 input + 两条 output 都进了 conversation")
    eq(list.data[1].content, "ask", "message 类 input 只存 content")
    eq(list.data[3].name, "f", "function_call 整对象入库并抬平 name")
    eq(list.data[3].call_id, "call_1", "function_call 抬平 call_id")
    local item = history.memory_store.get_item(list.data[3].id)
    eq(item.response_id, res.id, "item 记录带来源 response_id")
    local ghost, gerr = history.create_response({
        conversation = "conv_missing", status = "completed",
        output = { { type = "message", role = "assistant", content = "x" } },
    })
    ok(ghost, gerr, "conversation 不存在时 response 仍入库（Rust 只 warn）")
end

new_case("容量淘汰：conversation 按 LRU、items 按 oldest")
do
    cfg.max_conversations = 4
    local ids = {}
    for i = 1, 4 do ids[i] = history.create_conversation().id end
    -- ids[1] 最后被访问，应活过淘汰；ids[2] 最久未访问，应先出局
    history.get_conversation(ids[4])
    history.get_conversation(ids[3])
    history.get_conversation(ids[1])
    history.get_conversation(ids[2])
    history.get_conversation(ids[1])
    local fresh = history.create_conversation().id
    check(history.get_conversation(ids[1]) ~= nil, "ids[1] 刚被访问，LRU 保留")
    check(history.get_conversation(fresh) ~= nil, "新写入必然保留")
    local alive = 0
    for i = 1, 4 do
        if history.get_conversation(ids[i]) then alive = alive + 1 end
    end
    check(alive <= cfg.max_conversations, "存活数不超过上限", alive)
    check(fake.store[history.KEYS.n_conv] <= cfg.max_conversations,
        "LRU 淘汰与 response 一样保持计数守恒")
    cfg.max_conversations = 10000
end
do
    cfg.max_items_per_conversation = 5
    local tmp = history.create_conversation().id
    for i = 1, 8 do
        history.create_items(tmp, { { type = "message", role = "user", content = "n" .. i } })
    end
    local list = history.list_items(tmp, { order = "asc" })
    eq(#list.data, 5, "超上限按最旧淘汰，保留 5 条")
    eq(list.data[1].content, "n4", "淘汰的是最旧的三条")
    eq(list.data[5].content, "n8", "最新 item 一定保留")
    check(fake.store[history.KEYS.item .. list.data[1].id] ~= nil, "保留项记录仍在")
    cfg.max_items_per_conversation = 1000
end
do
    cfg.max_responses = 3
    local ids = {}
    for i = 1, 5 do ids[i] = history.create_response({ status = "completed" }).id end
    local alive = 0
    for i = 1, 5 do
        if history.get_response(ids[i]) then alive = alive + 1 end
    end
    check(alive <= 3, "response 数不超过上限", alive)
    check(history.get_response(ids[5]) ~= nil, "最新的 response 保留")
    eq(fake.store[history.KEYS.n_resp] <= 3, true, "response 计数守恒")
    cfg.max_responses = 10000
end

new_case("写失败与 encode 失败：返回 500，不污染后续请求")
do
    fake.fail_next = true
    local res, err = history.create_conversation()
    check(res == nil and err_is(err, 500, "history_storage_error"), "dict 写失败返回 500")
    fake.fail_next = true
    local r2, e2 = history.create_response({ status = "completed" })
    check(r2 == nil and e2 and e2.status == 500, "response 写失败返回 500")
    fake.fail_next = false
    ok(history.create_conversation(), nil, "写失败后仍可正常写入")
    -- 自定义编码器把不可编码的字段降级为 null，而不是抛错打断请求
    local cyc, cycerr = history.create_conversation({ fn = function() return 1 end })
    ok(cyc, cycerr, "含 function 值的 metadata 不崩")
    check(history.encode({ meta = cyc.metadata }):find('"fn":null') ~= nil,
        "不可编码字段降级为 null", history.encode({ meta = cyc.metadata }))
end

new_case("并发模拟：交替写入不丢索引、计数守恒、游标同步")
do
    local tmp = history.create_conversation().id
    local a_ids, b_ids = {}, {}
    for i = 1, 20 do
        -- 两个"进程"交替各写 20 条：共享 dict 替身顺序执行，所以这里验证的是
        -- 读-改-写序列本身的可线性（索引 / 反向索引 / 计数三者一致）。
        a_ids[i] = history.create_items(tmp, { { type = "message", role = "user", content = "A" .. i } }).data[1].id
        b_ids[i] = history.create_items(tmp, { { type = "message", role = "user", content = "B" .. i } }).data[1].id
    end
    local list = history.list_items(tmp, { limit = 100 })
    eq(#list.data, 40, "40 次交替写入全部可见")
    local entries = history.memory_store.index(tmp)
    eq(#entries, 40, "link 索引没有丢条目")
    local seen = {}
    for i = 2, #entries do
        check(entries[i].score > entries[i - 1].score, "索引严格有序 #" .. i)
        check(not seen[entries[i].item_id], "索引无重复")
        seen[entries[i].item_id] = true
    end
    local rev_count = 0
    local prefix = history.KEYS.rev .. tmp .. "|"
    for k in pairs(fake.store) do
        if k:sub(1, #prefix) == prefix then rev_count = rev_count + 1 end
    end
    eq(rev_count, 40, "after 游标的反向索引与 link 索引同步")
    for i = 1, 20 do
        history.delete_item(tmp, a_ids[i])
    end
    eq(#history.list_items(tmp).data, 20, "交替删除后只剩一半")
    eq(#history.memory_store.index(tmp), 20, "删除同样保持索引一致")
    for i = 1, 20 do
        local gone, gerr = history.get_item(tmp, a_ids[i])
        check(gone == nil and gerr.status == 404, "被解链的 item 读不回 #" .. i)
    end
    local asc = history.list_items(tmp, { order = "asc", limit = 3 })
    local p2 = history.list_items(tmp, { order = "asc", limit = 3, after = asc.last_id })
    eq(#p2.data, 3, "交替写入后游标翻页仍正确")
    eq(p2.data[1].content, "B4", "顺序按入库次序，解链不影响剩余项排序")
end

new_case("stats / sweep / flush_all 运维面")
do
    reset()
    local c = history.create_conversation().id
    history.create_items(c, { { type = "message", role = "user", content = "z" } })
    history.create_response({ status = "completed" })
    local st = history.stats()
    eq(st.backend, "memory", "stats 报后端")
    check(st.supported == true, "stats 报 supported")
    eq(st.conversations, 1, "stats 计 conversation")
    eq(st.responses, 1, "stats 计 response")
    eq(st.limits.max_conversations, 10000, "stats 带容量参数")
    eq(st.limits.ttl_secs, 0, "stats 带 TTL")
    local sw = history.sweep()
    eq(sw.dropped_conversations, 0, "未超限时 sweep 不删数据")
    eq(sw.dropped_responses, 0, "未超限时 sweep 不删 response")
    cfg.max_conversations = 1
    local n = history.sweep()
    check(n.dropped_conversations >= 0, "超限时 sweep 返回淘汰数")
    cfg.max_conversations = 10000
    check(history.flush_all(), "flush_all 返回 true")
    eq(leftover(), 0, "flush 清掉本模块的全部 key")
    check(history.get_conversation(c) == nil, "flush 后数据清空")
    -- stats() 读计数用的是 incr(k, 0, 0)，会顺带重建计数键，所以放在空判之后
    eq(history.stats().conversations, 0, "flush 后计数归零")
    eq(history.stats().responses, 0, "flush 后 response 计数归零")
    cfg.backend = "redis"
    local r = history.stats()
    check(r.supported == false and r.error.status == 501, "stats 也能报出未实现后端")
    eq(history.sweep().dropped_responses, 0, "未实现后端 sweep 不动数据")
    check(history.flush_all(), "flush_all 与后端无关")
    cfg.backend = "memory"
end

new_case("JSON 编码：数组/对象形状与键序稳定")
do
    eq(history.encode(history.array()), "[]", "空数组保持数组")
    eq(history.encode({ { 1 } }), "[[1]]", "带元素的表是数组")
    eq(history.encode({ b = 1, a = 2 }), '{"a":2,"b":1}', "对象按键序输出（字节稳定）")
    eq(history.encode({}), "{}", "普通空表是对象（不改 cjson 全局设置）")
    eq(history.encode({ x = history.array() }), '{"x":[]}', "嵌套空数组")
    eq(history.encode(0 / 0), "null", "nan 标量编码为 null 而不是抛错")
    eq(history.encode({ 0 / 0 }), "[null]", "nan 在数组里同样降级为 null")
    eq(history.encode({ x = cjson.null }), '{"x":null}', "cjson.null 编码为 null")
    eq(history.encode({ x = history.array({ 1, 2 }) }), '{"x":[1,2]}', "数组元素保序")
    eq(history.encode("plain"), '"plain"', "字符串直接编码")
    check(history._VERSION ~= nil, "模块带版本号")
    -- 空数组不会被静默写成对象：这是 OpenAI 里 content/output 的 schema 形状
    local c = history.create_conversation().id
    local item = history.create_items(c, { { type = "message", role = "user", content = history.array() } })
    check(history.encode(item):find('"content":%[%]') ~= nil,
        "message 的空 content 编码为 []", history.encode(item))
    local got = history.get_item(c, item.data[1].id)
    check(#got.content == 0 and history.encode(got.content) == "[]",
        "空 content 往返后仍是数组", history.encode(got.content))
    local r = history.create_response({ status = "completed", output = {} })
    local back = history.get_response(r.id)
    check(history.encode(back):find('"output":%[%]') ~= nil,
        "空 output 经 shared dict 往返后仍是 []（JSON 不携带数组标记）",
        history.encode(back))
end

new_case("TTL：SMG_HISTORY_TTL_SECS 透传到写入")
do
    reset()
    cfg.ttl_secs = 60
    local c = history.create_conversation().id
    eq(fake.expire[history.KEYS.conv .. c] > 0, true, "conversation 带过期时间")
    cfg.ttl_secs = 0
    local c2 = history.create_conversation().id
    eq(fake.expire[history.KEYS.conv .. c2], 0, "ttl 0 表示不过期")
end

new_case("config：后端名解析与容错（resolve_backend 是 env 解析的纯函数形式）")
do
    eq(history.resolve_backend("none"), "none", "显式 none")
    eq(history.resolve_backend("NONE"), "none", "大小写不敏感")
    eq(history.resolve_backend("  memory  "), "memory", "空白被 trim")
    eq(history.resolve_backend("redis"), "redis", "redis 被识别（后续 501 由门控负责）")
    eq(history.resolve_backend("postgres"), "postgres", "postgres 被识别")
    eq(history.resolve_backend("oracle"), "oracle", "oracle 被识别")
    eq(history.resolve_backend("bogus"), "memory", "未知取值回落 memory（对齐 _ => Memory）")
    eq(history.resolve_backend(""), "memory", "空串回落默认")
    eq(history.resolve_backend(nil), "memory", "未设置默认 memory")
    eq(history.DEFAULT_BACKEND, "memory", "默认值与 Rust 一致")
    eq(history.backend(), "memory", "backend() 反映当前配置")
    history.reset_config()
end

new_case("configure：由 init_by_lua 注入配置，不依赖 worker 环境")
do
    reset()
    local before = history.config().max_responses
    local cfg2, err = history.configure({ max_responses = 123, backend = "NONE" })
    check(cfg2 ~= nil and err == nil, "configure 返回生效的配置", err and err.message)
    eq(cfg2.max_responses, 123, "覆盖项写入")
    eq(cfg2.backend, "none", "backend 经 resolve_backend 归一并立即生效")
    eq(history.config().max_responses, 123, "后续 config() 读到同一份缓存")
    eq(history.backend(), "none", "backend() 跟着切换")
    history.configure({ backend = "bogus" })
    eq(history.backend(), "memory", "非法后端名仍折叠到 memory")
    history.configure({ max_responses = before, backend = "memory" })
    eq(history.config().max_responses, 10000, "复原")
    local bad, baderr = history.configure("nope")
    check(bad == nil and baderr ~= nil, "非表入参返回错误而不是崩")
    history.reset_config()
end

--------------------------------------------------------------------------
io.write("\n")
if failed > 0 then
    io.write("FAILED " .. failed .. " checks:\n")
    for i = 1, #failures do
        io.write("  - " .. failures[i] .. "\n")
    end
    io.write("\n")
end
io.write(passed .. " passed, " .. failed .. " failed\n")
os.exit(failed == 0 and 0 or 1)
