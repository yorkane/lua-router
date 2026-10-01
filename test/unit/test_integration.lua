#!/usr/bin/env resty
-- 集成接线单测：policy 工厂分发、cache_aware 树快照、原始 JSON 字段编辑。
--   运行（真实 ngx 环境，stub 掉 shared-dict 依赖）：
--   docker run --rm -v "$PWD:/repo:ro" -w /repo \
--     --entrypoint /usr/bin/resty apache/apisix:3.11.0-debian \
--     -e 'package.path="/repo/lualib/?.lua;"..package.path
--         dofile("/repo/test/unit/test_integration.lua")'
--
-- 为什么能这么跑：policy.lua 只通过 observability.counter/gauge 与
-- registry.load/records 触碰外部世界，router.lua 的 set_top_field 是纯字符串函数。
-- 两个模块都在 require 之前塞进 package.loaded 的替身即可隔离测试，
-- 不需要 shared dict（dict() 只在被 stub 的方法路径上才会调用）。

package.path = (os.getenv("LUA_TEST_LIB") or "./lualib") .. "/?.lua;" .. package.path

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

--------------------------------------------------------------------------
-- stubs（必须在 require "resty.luarouter.policy" 之前装好）
--------------------------------------------------------------------------
local observed = { counters = {}, gauges = {} }
package.loaded["resty.luarouter.observability"] = {
    counter = function(name, pairs_spec, delta)
        observed.counters[name] = (observed.counters[name] or 0) + (delta or 1)
    end,
    gauge = function(name, pairs_spec, value)
        observed.gauges[name] = value
    end,
    record_worker_selection = function(url, model, policy)
        observed.last_selection = { url = url, model = model, policy = policy }
    end,
}

local stub_workers = {}
package.loaded["resty.luarouter.registry"] = {
    load = function(id) return 0 end,
    change_load = function() return 0 end,
    records = function() return stub_workers end,
}

-- 共享字典替身：policy.lua 的 dict() 走 ngx.shared，直接给它一张表
local fake_store = {}
_G.ngx.shared = _G.ngx.shared or {}
setmetatable(_G.ngx.shared, { __index = function(_, key)
    if key ~= "lr_policy" then return nil end
    return {
        get = function(_, k) return fake_store[k] end,
        set = function(_, k, v) fake_store[k] = v; return true end,
        incr = function(_, k, d, init)
            fake_store[k] = (fake_store[k] or init or 0) + d; return fake_store[k]
        end,
        delete = function(_, k) fake_store[k] = nil end,
        get_keys = function() local out = {}; for k in pairs(fake_store) do out[#out+1]=k end; return out end,
    }
end })

local policy_mod = require "resty.luarouter.policy"

local function make_workers(n)
    local out = {}
    for i = 1, n do
        out[i] = { id = "w" .. i, url = "http://w" .. i, load = 0, healthy = true,
                   model_id = "m1" }
    end
    stub_workers = out
    return out
end

local base_cfg = {
    policy = "round_robin",
    eviction_interval_secs = 120, max_idle_secs = 14400, assignment_mode = "random",
    cache_threshold = 0.3, balance_abs_threshold = 64, balance_rel_threshold = 1.5,
    max_tree_size = 67108864, prefix_token_count = 256, prefix_hash_load_factor = 1.25,
    bucket_adjust_interval_secs = 5, snapshot_max_bytes = 3 * 1024 * 1024,
}

--------------------------------------------------------------------------
-- 1. 工厂分发：8 个策略名各自命中实现
--------------------------------------------------------------------------
local standalone_expected = {
    cache_aware = true, bucket = true, consistent_hashing = true, prefix_hash = true,
}
for _, name in ipairs({ "random", "round_robin", "cache_aware", "power_of_two",
                        "prefix_hash", "manual", "bucket", "consistent_hashing" }) do
    local cfg = {}
    for k, v in pairs(base_cfg) do cfg[k] = v end
    cfg.policy = name
    local inst = policy_mod.new(cfg)
    eq(inst:name_instance():match("^[^:]+"), name, "factory keeps name " .. name)
    eq(inst.impl ~= nil, standalone_expected[name] == true,
        "factory wires module for " .. name)
end

-- 未知策略名回落 round_robin，且不加载任何模块
local cfg_unknown = {}
for k, v in pairs(base_cfg) do cfg_unknown[k] = v end
cfg_unknown.policy = "not_a_policy"
local inst_unknown = policy_mod.new(cfg_unknown)
eq(inst_unknown.name, "round_robin", "unknown policy collapses to round_robin")
eq(inst_unknown.impl, nil, "unknown policy loads no module")

--------------------------------------------------------------------------
-- 2. select() 统一返回 entry（而非下标），并记 selection metric
--------------------------------------------------------------------------
local workers = make_workers(3)
local text = "the quick brown fox jumps over the lazy dog"

local function select_one(name, request_text)
    local cfg = {}
    for k, v in pairs(base_cfg) do cfg[k] = v end
    cfg.policy = name
    local inst = policy_mod.new(cfg)
    return inst:select({ candidates = workers, request_text = request_text,
                         headers = {}, model = "m1" })
end

for _, name in ipairs({ "random", "round_robin", "power_of_two", "manual",
                        "cache_aware", "bucket", "consistent_hashing", "prefix_hash" }) do
    local chosen = select_one(name, text)
    check(type(chosen) == "table" and chosen.url ~= nil,
        "select returns entry for " .. name, type(chosen))
    eq(observed.last_selection.policy, name, "selection metric names " .. name)
end

-- cache_aware 粘滞（同文本 10 次同一 worker）
local first = select_one("cache_aware", text)
local stuck = true
for _ = 1, 9 do
    if select_one("cache_aware", text).url ~= first.url then stuck = false end
end
-- 每次 select_one 都新建实例，粘滞必须在同一实例上测
local cfg_ca = {}
for k, v in pairs(base_cfg) do cfg_ca[k] = v end
cfg_ca.policy = "cache_aware"
local inst_ca = policy_mod.new(cfg_ca)
local ca_first = inst_ca:select({ candidates = workers, request_text = text, model = "m1" })
stuck = true
for _ = 1, 9 do
    local again = inst_ca:select({ candidates = workers, request_text = text, model = "m1" })
    if again.url ~= ca_first.url then stuck = false end
end
check(stuck, "cache_aware sticks to one worker for one prefix")

-- consistent_hashing 用 routing-key 粘滞
local cfg_ch = {}
for k, v in pairs(base_cfg) do cfg_ch[k] = v end
cfg_ch.policy = "consistent_hashing"
local inst_ch = policy_mod.new(cfg_ch)
local ch_first = inst_ch:select({ candidates = workers, model = "m1",
                                  headers = { ["x-smg-routing-key"] = "session-42" } })
local ch_stuck = true
for _ = 1, 9 do
    local again = inst_ch:select({ candidates = workers, model = "m1",
                                   headers = { ["x-smg-routing-key"] = "session-42" } })
    if again.url ~= ch_first.url then ch_stuck = false end
end
check(ch_stuck, "consistent_hashing sticks per routing key")
check(observed.counters["smg_consistent_hashing_policy_branch_total"] ~= nil,
    "hashing branch counter recorded")

-- needs_request_text
for _, name in ipairs({ "cache_aware", "bucket", "prefix_hash" }) do
    local cfg = {}
    for k, v in pairs(base_cfg) do cfg[k] = v end
    cfg.policy = name
    eq(policy_mod.new(cfg):needs_request_text(), true, name .. " needs request text")
end
for _, name in ipairs({ "random", "round_robin", "power_of_two", "manual",
                        "consistent_hashing" }) do
    local cfg = {}
    for k, v in pairs(base_cfg) do cfg[k] = v end
    cfg.policy = name
    eq(policy_mod.new(cfg):needs_request_text(), false, name .. " ignores request text")
end

--------------------------------------------------------------------------
-- 3. cache_aware 快照：写回 lr_policy、max_bytes 跳过、恢复回同进程树
--------------------------------------------------------------------------
local snap_workers = make_workers(2)
cfg_ca.snapshot_max_bytes = 3 * 1024 * 1024
local writer = policy_mod.new(cfg_ca)
writer:prepare()
writer:select({ candidates = snap_workers, request_text = "snapshot unit prefix", model = "m1" })
local key = writer:snapshot_key()
check(key:find("^snapshot:cache_aware:default:") ~= nil, "snapshot key shape", key)
eq(writer:save_snapshot(), true, "save_snapshot writes")
check(type(fake_store[key]) == "string" and #fake_store[key] > 0,
    "lr_policy holds JSON text")
local cjson = require "cjson.safe"
local parsed = cjson.decode(fake_store[key])
check(type(parsed) == "table" and parsed.policy == "cache_aware"
    and type(parsed.trees) == "table", "snapshot shape is the tree dump")

-- max_bytes 超限：跳过写盘，不报错，也不覆盖旧值
local stale = fake_store[key]
cfg_ca.snapshot_max_bytes = 16
local tight = policy_mod.new(cfg_ca)
tight:prepare()
tight:select({ candidates = snap_workers, request_text = "a much longer snapshot payload",
               model = "m1" })
eq(tight:save_snapshot(), false, "oversized snapshot is skipped")
-- the previously stored dump survives untouched (same key: same policy + model)
eq(fake_store[tight:snapshot_key()], stale, "skip leaves the previous dump alone")

-- 恢复：新实例 decode_snapshot 之后粘滞同一个 worker（模拟 reload）
cfg_ca.snapshot_max_bytes = 3 * 1024 * 1024
local reader = policy_mod.new(cfg_ca)
reader:restore_snapshot()
check(reader.seeded == false, "restore does not imply seeding")
reader:prepare()
local restored_first = reader:select({ candidates = snap_workers,
                                       request_text = "snapshot unit prefix", model = "m1" })
local restored_stuck = true
for _ = 1, 5 do
    local again = reader:select({ candidates = snap_workers,
                                  request_text = "snapshot unit prefix", model = "m1" })
    if again.url ~= restored_first.url then restored_stuck = false end
end
check(restored_stuck, "restored tree keeps affinity")

--------------------------------------------------------------------------
-- 4. worker 增删通知
--------------------------------------------------------------------------
local notify = policy_mod.new(cfg_ca)
notify:prepare()
notify:on_add({ url = "http://w9", model_id = "m1" })
notify:on_remove({ url = "http://w9" })
check(true, "on_add/on_remove survive on a standalone policy")

--------------------------------------------------------------------------
-- 5. router.set_top_field（纯字符串路径，不碰 ngx.req）
--    router.lua 依赖 klib 与 cosocket，无法在 resty CLI 里 require；
--    把函数体所在的片段单独 load 进沙箱不现实，这里用等价的独立编译：
--    直接读文件里 set_top_field 的实现并在最小环境执行。
--------------------------------------------------------------------------
local function load_set_top_field()
    local src = io.open((os.getenv("LUA_TEST_LIB") or "./lualib")
        .. "/resty/luarouter/router.lua"):read("*a")
    local body = src:match("(local function field_pattern.-)\n_M%.set_top_field")
    check(type(body) == "string", "set_top_field source extracted")
    local sandbox = {
        ngx = ngx,
        json_encode = require("cjson.safe").encode,
    }
    -- keep the standard library reachable (the chunk has no other _ENV)
    setmetatable(sandbox, { __index = _G })
    local chunk = load(body .. "\nreturn set_top_field", "set_top_field", "t", sandbox)
    return chunk and chunk() or nil
end

local set_top_field = load_set_top_field()
if set_top_field then
    local raw = '{"model":"m","tools":[{"type":"function"}],"nested":{"model":"keep"},'
        .. '"reasoning_effort":"low","max_tokens":99999}'
    local replaced = set_top_field(raw, "reasoning_effort", "high")
    check(replaced:find('"reasoning_effort":"high"', 1, true) ~= nil, "string member replaced")
    check(replaced:find('"reasoning_effort":"low"', 1, true) == nil, "old value gone")
    local capped = set_top_field(raw, "max_tokens", 128)
    check(capped:find('"max_tokens":128', 1, true) ~= nil, "number member replaced")
    local added = set_top_field(raw, "user", "u1")
    check(added:find('"user":"u1",', 1, true) ~= nil, "absent member inserted first")
    check(added:find('"nested":{"model":"keep"}', 1, true) ~= nil, "nested member untouched")
    check(added:find('"tools":[{"type":"function"}]', 1, true) ~= nil, "empty-ish array kept")
    local removed = set_top_field(raw, "reasoning_effort", nil)
    local decoded = cjson.decode(removed)
    check(decoded ~= nil and decoded.reasoning_effort == nil and decoded.model == "m"
        and decoded.max_tokens == 99999, "removal keeps the document valid", removed)
    local sole = set_top_field('{"reasoning_effort":"low"}', "reasoning_effort", nil)
    check(cjson.decode(sole) ~= nil and next(cjson.decode(sole) or {}) == nil
        or sole:gsub("%s", "") == "{}", "sole member removal yields empty object", sole)
    local empty = set_top_field("{}", "model", "m")
    check(empty:gsub("%s", "") == '{"model":"m"}', "insert into empty object", empty)
    -- removal when the member is last (no trailing comma on its right)
    local last = set_top_field('{"a":1,"reasoning_effort":"low"}', "reasoning_effort", nil)
    check(cjson.decode(last) ~= nil and cjson.decode(last).a == 1
        and #cjson.decode(last) >= 0, "last member removal valid", last)
    -- removal when the member is first
    local head = set_top_field('{"reasoning_effort":"low","a":1}', "reasoning_effort", nil)
    check(cjson.decode(head) ~= nil and cjson.decode(head).a == 1, "first member removal valid",
        head)
else
    check(false, "set_top_field loaded")
end

local function new_case(name)
    io.write("  case: " .. name .. "\n")
end

--------------------------------------------------------------------------
-- 6. token 核算：stream_options 注入 / SSE 帧切分 / usage 帧剥除判定
--    （doc/gap-token-accounting.md）
--
--    与第 5 节同一手法：router.lua 依赖 klib 与 cosocket，无法在 resty CLI 里
--    require，所以把这段纯字符串逻辑单独 load 进沙箱。被 load 的片段与线上代码
--    逐字相同（从文件里按函数名切出来），所以这里断言的是真实现，不是复刻。
--------------------------------------------------------------------------
local function load_accounting_sandbox()
    local src = io.open((os.getenv("LUA_TEST_LIB") or "./lualib")
        .. "/resty/luarouter/router.lua"):read("*a")
    local blocks = {
        src:match("(local function field_pattern.-)\n_M%.set_top_field"),
        src:match("(local function merge_top_object.-)\n_M%.merge_top_object"),
        src:match("(local function usage_from_object.-\nend\n)"),
        src:match("(local function usage_from_chunk.-\nend\n)"),
        src:match("(local function sse_event_droppable.-)\n_M%.sse_event_droppable"),
        src:match("(local function sse_split.-)\n_M%.sse_split"),
        src:match("(local function client_wants_usage.-)\n_M%.client_wants_usage"),
        src:match("(local function names_stream_options.-)\n_M%.names_stream_options"),
    }
    for i = 1, #blocks do
        if type(blocks[i]) ~= "string" then
            return nil, "block " .. i .. " not extracted"
        end
    end
    local cjson_safe = require("cjson.safe")
    local sandbox = {
        ngx = ngx,
        json_encode = cjson_safe.encode,
        json_decode = cjson_safe.decode,
        cjson = cjson_safe,
    }
    setmetatable(sandbox, { __index = _G })
    local chunk = load("local _M = {}\n"
        .. blocks[1] .. "\n" .. blocks[2] .. "\n" .. blocks[3] .. "\n"
        .. blocks[4] .. "\n" .. blocks[5] .. "\n" .. blocks[6] .. "\n"
        .. blocks[7] .. "\n" .. blocks[8] .. "\n"
        .. "return { set_top_field = set_top_field,"
        .. " merge_top_object = merge_top_object,"
        .. " usage_from_chunk = usage_from_chunk,"
        .. " sse_event_droppable = sse_event_droppable,"
        .. " sse_split = sse_split,"
        .. " client_wants_usage = client_wants_usage,"
        .. " names_stream_options = names_stream_options }",
        "token accounting", "t", sandbox)
    if not chunk then
        return nil, "chunk did not compile"
    end
    return chunk()
end

local acc = load_accounting_sandbox()
if not acc then
    check(false, "token-accounting sandbox loaded", tostring(acc))
else
    new_case("stream_options injection")

    -- 6.1 注入：客户端没写 stream_options 时补一个对象，其余字节逐字保留
    local plain = '{"model":"m","stream":true,"messages":[{"role":"user","content":"hi"}]}'
    local injected, changed = acc.merge_top_object(plain, "stream_options", "include_usage", true)
    eq(changed, true, "absent stream_options is created")
    eq(injected, '{"stream_options":{"include_usage":true},' .. plain:sub(2),
        "injection prepends the member and keeps every other byte")
    check(cjson.decode(injected).stream == true
        and cjson.decode(injected).messages[1].content == "hi",
        "injected body still decodes to the same request")

    -- 6.2 已有 stream_options 对象：合并而不是覆盖（客户端的 verbose 必须活着）
    local partial = '{"model":"m","stream":true,"stream_options":{"verbose":true}}'
    local merged = acc.merge_top_object(partial, "stream_options", "include_usage", true)
    eq(merged, '{"model":"m","stream":true,"stream_options":{"include_usage":true,"verbose":true}}',
        "existing stream_options is merged, not replaced")

    -- 6.3 客户端自己就要了 usage：一个字都不改（该帧是客户端的，不能剥）
    local _, already_changed = acc.merge_top_object(
        '{"stream_options":{"include_usage":true}}', "stream_options", "include_usage", true)
    eq(already_changed, false, "include_usage already true -> no change")

    -- 6.4 显式 false / null：客户端的 false 会被网关改写（并剥掉后果），必须报 changed
    local _, flipped = acc.merge_top_object(
        '{"stream_options":{"include_usage":false}}', "stream_options", "include_usage", true)
    eq(flipped, true, "explicit false is flipped to true")
    local null_filled = acc.merge_top_object(
        '{"stream_options":null,"model":"m"}', "stream_options", "include_usage", true)
    check(null_filled:find('"stream_options":{"include_usage":true}', 1, true) ~= nil,
        "explicit null is filled in", null_filled)

    -- 6.5 客户端把这个名字用成了别的类型：不动它（覆盖客户端选定的值不是我们的权利）
    local _, hostile_changed = acc.merge_top_object(
        '{"stream_options":"yes"}', "stream_options", "include_usage", true)
    eq(hostile_changed, false, "non-object stream_options is left alone")
    local _, array_changed = acc.merge_top_object(
        '{"stream_options":[]}', "stream_options", "include_usage", true)
    eq(array_changed, false, "array stream_options is left alone")

    -- 6.6 嵌套同名字段不受影响（top_member_span 的深度意义所在）
    local nested = '{"a":{"stream_options":{"x":1}},"model":"m"}'
    local nested_out = acc.merge_top_object(nested, "stream_options", "include_usage", true)
    check(nested_out:find('"a":{"stream_options":{"x":1}}', 1, true) ~= nil,
        "nested stream_options untouched", nested_out)
    check(nested_out:find('"stream_options":{"include_usage":true}', 1, true) ~= nil,
        "top-level stream_options added beside the nested one", nested_out)

    -- 6.7 空对象 / 带空白的写法
    eq(acc.merge_top_object("{}", "stream_options", "include_usage", true),
        '{"stream_options":{"include_usage":true}}', "injection into an empty object")
    local spaced = '{ "stream_options" : { "verbose" : true } , "model":"m" }'
    check(acc.merge_top_object(spaced, "stream_options", "include_usage", true)
              :find('"include_usage":true', 1, true) ~= nil,
        "whitespace around the member is handled")

    -- 6.8 客户端原意判定：只有真值 include_usage 算「客户端要这帧」
    eq(acc.client_wants_usage({ stream_options = { include_usage = true } }), true,
        "client asked for usage")
    eq(acc.client_wants_usage({ stream_options = { include_usage = false } }), false,
        "client asked against usage")
    eq(acc.client_wants_usage({ stream_options = {} }), false, "empty stream_options is not a request")
    eq(acc.client_wants_usage({}), false, "no stream_options at all")
    eq(acc.client_wants_usage({ stream_options = cjson.null }), false,
        "null stream_options is not a request")

    new_case("SSE frame splitting")

    -- 6.9 LF 分隔：两个完整事件，无残留
    local events, rest = acc.sse_split('data: {"a":1}\n\ndata: [DONE]\n\n')
    eq(#events, 2, "two LF-separated events")
    eq(rest, "", "nothing left over")
    eq(events[1].text, 'data: {"a":1}\n\n', "event text keeps its separator bytes")
    eq(events[2].text, "data: [DONE]\n\n", "second event verbatim")

    -- 6.10 CRLF 分隔（/v1/responses 的上游就这么写）
    local crlf_events, crlf_rest = acc.sse_split(
        'data: {"a":1}\r\ndata: [DONE]\r\n\r\ndata: partial')
    eq(#crlf_events, 1, "one CRLF-terminated event")
    eq(crlf_rest, "data: partial", "an unterminated tail stays in the carry")

    -- 6.11 混排 \n\r\n（先 \n 后 \r\n 的上游）
    local mixed, mixed_rest = acc.sse_split('data: {"a":1}\n\r\ndata: [DONE]\n\r\n')
    eq(#mixed, 2, "mixed line endings still split into two events")
    eq(mixed_rest, "", "mixed form leaves nothing behind")

    -- 6.12 分块喂入：帧跨读必须最终切出同一帧，且不丢字节（泵按块调用）
    local p1 = 'data: {"id":"c","choices":[{"finish_reason":"stop"}],"usa'
    local p2 = 'ge":{"prompt_'
    local p3 = 'tokens":11,"completion_tokens":22,"total_tokens":33}}\n\n'
    local e1, c1 = acc.sse_split(p1)
    local e2, c2 = acc.sse_split(c1 .. p2)
    local e3, c3 = acc.sse_split(c2 .. p3)
    eq(#e1, 0, "a frame with no separator is not an event yet")
    eq(#e2, 0, "still incomplete after the second read")
    eq(#e3, 1, "the frame closes once its blank line arrives")
    eq(c3, "", "no residue after the completed frame")
    eq(e3[1].text, p1 .. p2 .. p3, "reassembled frame is byte-exact")

    -- 6.13 逐块拼接后必须等于原始流（剥帧只删整帧，绝不吞字节）
    local whole = 'data: {"a":1}\n\ndata: {"b":2}\n\n'
    local rebuilt = {}
    local carry = ""
    for i = 1, #whole do
        local evs, next_carry = acc.sse_split(carry .. whole:sub(i, i))
        for j = 1, #evs do rebuilt[#rebuilt + 1] = evs[j].text end
        carry = next_carry
    end
    eq(table.concat(rebuilt) .. carry, whole, "byte-at-a-time feeding loses nothing")

    new_case("usage frame drop decision")

    -- 6.14 纯 usage 帧（choices 为空）：可剥
    local usage_frame = 'data: {"id":"c","object":"chat.completion.chunk","choices":[],'
        .. '"usage":{"prompt_tokens":11,"completion_tokens":22,"total_tokens":33}}\n\n'
    eq(acc.sse_event_droppable(usage_frame), true, "usage-only frame is droppable")

    -- 6.15 choices 缺省也可剥（字段缺省不等于携带内容）
    eq(acc.sse_event_droppable('data: {"usage":{"prompt_tokens":1}}\n\n'), true,
        "frame with no choices member is droppable")

    -- 6.16 delta 带 role 的 usage 帧（vLLM 形态）也可剥：role 之外没有内容
    eq(acc.sse_event_droppable(
        'data: {"choices":[{"index":0,"delta":{},"finish_reason":null}],'
        .. '"usage":{"prompt_tokens":1,"completion_tokens":5}}\n\n'), true,
        "empty delta plus null finish_reason stays droppable")

    -- 6.17 llama.cpp 形态：usage 与 finish_reason 同帧 —— 不许剥
    eq(acc.sse_event_droppable(
        'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],'
        .. '"usage":{"prompt_tokens":1}}\n\n'), false,
        "a frame that closes the turn is never dropped")

    -- 6.18 usage 与内容同帧 —— 不许剥
    eq(acc.sse_event_droppable(
        'data: {"choices":[{"index":0,"delta":{"content":"x"}},'
        .. '{"index":1,"delta":{},"finish_reason":null}],"usage":{"prompt_tokens":1}}\n\n'),
        false, "a frame carrying content is never dropped")

    -- 6.19 三种必须原样透传的帧
    eq(acc.sse_event_droppable("data: [DONE]\n\n"), false, "[DONE] survives")
    eq(acc.sse_event_droppable(": ping\n\n"), false, "heartbeat comment survives")
    eq(acc.sse_event_droppable('data: {"choices":[{"delta":{"content":"a"}}]}\n\n'), false,
        "content delta survives")
    eq(acc.sse_event_droppable("data: not-json\n\n"), false, "undecodable payload survives")
    eq(acc.sse_event_droppable('data: {"choices":[]}\n\n'), false,
        "usage-less empty frame survives (nothing to account for)")

    -- 6.20 带 event: / id: 的帧一律不剥（/v1/responses 的协议帧、可续传游标）
    eq(acc.sse_event_droppable('event: response.completed\n'
        .. 'data: {"response":{"usage":{"input_tokens":3,"output_tokens":4}}}\n\n'), false,
        "responses completed event is protocol, not ours to drop")
    eq(acc.sse_event_droppable('id: 7\ndata: {"usage":{"prompt_tokens":1}}\n\n'), false,
        "an id-carrying frame keeps its id by staying whole")

    -- 6.21 多行 data 事件不剥（可能同时装着 [DONE]，剥掉客户端就等不到结束）
    eq(acc.sse_event_droppable(
        'data: {"usage":{"prompt_tokens":1}}\ndata: [DONE]\n\n'), false,
        "a multi-line event is kept whole")

    -- 6.22 /v1/responses 的 usage 藏在 response 下面：读得到（且因 event: 行不会被剥）
    local p_, c_, a_, r_ = acc.usage_from_chunk(
        cjson.decode('{"response":{"usage":{"input_tokens":3,"output_tokens":4,'
            .. '"input_tokens_details":{"cached_tokens":2},'
            .. '"output_tokens_details":{"reasoning_tokens":1}}}}'))
    eq(p_, 3, "responses usage reads input_tokens")
    eq(c_, 4, "responses usage reads output_tokens")
    eq(a_, 2, "responses usage reads cached detail")
    eq(r_, 1, "responses usage reads reasoning detail")
    local tp, tc = acc.usage_from_chunk(
        cjson.decode('{"choices":[{"delta":{"content":"x"}}],"usage":'
            .. '{"prompt_tokens":1,"completion_tokens":5}}'))
    eq(tp, 1, "chat usage reads the top-level member")
    eq(tc, 5, "chat completion count survives")
    check(acc.usage_from_chunk(cjson.decode('{"choices":[{"delta":{"content":"x"}}]}')) == nil,
        "a content chunk reports no usage")

    -- 6.23 空 usage / 非表 usage 都不算数
    check(acc.usage_from_chunk(cjson.decode('{"usage":{}}')) == nil, "empty usage object is not usage")
    check(acc.usage_from_chunk(cjson.decode('{"usage":"x"}')) == nil, "string usage is not usage")

    new_case("400 fallback attribution")

    -- 6.24 只有后端点名这个字段才 sticky 关闭注入：否则一个坏请求就能让健康的
    -- worker 失去一天的精确核算
    eq(acc.names_stream_options('{"error":{"message":"Unexpected value '
        .. 'stream_options with input"}}'), true, "backend names stream_options")
    eq(acc.names_stream_options("data: {'error': 'include_usage is not supported'}\n\n"), true,
        "backend names include_usage")
    eq(acc.names_stream_options('{"error":"messages must be a list"}'), false,
        "an unrelated 400 does not mark the worker")
    eq(acc.names_stream_options(""), false, "empty body marks nobody")
    eq(acc.names_stream_options(nil), false, "nil body marks nobody")
end

--------------------------------------------------------------------------
--------------------------------------------------------------------------
ngx.say("integration: " .. passed .. " passed, " .. failed .. " failed")
if failed > 0 then
    for i = 1, #failures do ngx.say("  FAIL " .. failures[i]) end
    os.exit(1)
end
