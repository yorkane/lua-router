#!/usr/bin/env luajit
-- /v1/models 对外形状的**合规 + 填充**单测：纯 luajit，不绑端口、不起容器，
-- 因此可与 host 网络的门禁并发（AGENTS.md 硬规则 1）。
--
-- 为什么需要这一份：registry/router 那两个提交把 /v1/models 从三字段扩成了完整形状，
-- 但 HTTP 面（test_lua_router.sh 的 public 段）只断言过 .object 与 .data[].id，
-- 新增字段一条都没钉。这里钉的是**输出层的纪律**；采集链路过一次真 HTTP 之后是否
-- 还成立，由 test/integration/e2e_models_advertisement.py 钉。
--
-- 手法沿用 test/unit/test_caps_routing.lua：按锚点把 router.lua 的**真实现**切出来配桩
-- 加载，断言跑在盘上那份代码上；能力归一化用 registry 的**真**函数（probe_seam.lua 同
-- 手法），这样"上游原文 -> 对外读数"整条链没有一处是手写替身。
--
-- 判别性纪律：LR_MODELS_TEST_LEGACY_SRC 指向改动前的 router.lua 时，同一组断言跑在旧
--   实现上，除"入口 owned_by 老口径"与"503 分支"这两组回归守卫以外全部必须红。
--   一条断言在 legacy 下也绿，说明它没测到东西。
--
-- 运行：
--   docker run --rm -v "$PWD":/repo:ro -w /repo -e LUA_TEST_LIB=/repo/lualib \
--     --entrypoint /usr/local/openresty/luajit/bin/luajit authz:latest \
--     test/unit/test_models_shape.lua
local lib = os.getenv("LUA_TEST_LIB") or "./lualib"
local legacy_src_path = os.getenv("LR_MODELS_TEST_LEGACY_SRC")

-- 2026-10-05 拆分（doc/refactor-arch-2026-10-05.md §1）：/v1/models 合成层逐字搬进
-- lualib/resty/luarouter/router/models_api.lua，锚点字符串一个都不动，只换源码文件。
-- 旧实现对照（LR_MODELS_TEST_LEGACY_SRC 指向改动前的 router.lua）与旧树对照走末尾的
-- router.lua 回退。
local function read_src()
    local f = io.open(lib .. "/resty/luarouter/router/models_api.lua")
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
local src = read_src()
if type(src) ~= "string" then
    print("FAIL: cannot read router sources from " .. lib)
    os.exit(1)
end
if legacy_src_path then
    local lf = io.open(legacy_src_path)
    local old = lf and lf:read("*a")
    if type(old) ~= "string" then
        print("FAIL: cannot read the legacy router.lua from " .. legacy_src_path)
        os.exit(1)
    end
    src = old
end

--- 切出模型列表那一段。两个文件锚点不同（改动前没有 MODEL_CREATED_UNKNOWN 那一块），
--- 所以起始锚点先试新的、退到旧的，结束锚点两边共用。
local function slice(text, from_marker, to_marker)
    local a = text:find(from_marker, 1, true)
    local b = text:find(to_marker, a or 1, true)
    if not a or not b then return nil end
    return text:sub(a, b - 1)
end
local blk = slice(src, "local MODEL_CREATED_UNKNOWN = 0", "---The Rust gateway answers")
    or slice(src, "local function inject_virtual_models", "---The Rust gateway answers")
if type(blk) ~= "string" then
    print("FAIL: cannot slice the models region out of router.lua")
    os.exit(1)
end
if not slice(blk, "local function models_handler()", "return {") then
    print("FAIL: models_handler missing from the slice")
    os.exit(1)
end

-- registry 的真归一化层（与 test_watcher.lua 同手法：摘掉 _G.ngx 再 require，并把
-- resty.lock 桩掉——它经 resty.core 需要 ngx，而本探针不碰锁）。
_G.ngx = nil
package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath
package.path = lib .. "/?.lua;" .. package.path
package.preload["resty.lock"] = function()
    return { new = function()
        return { lock = function() return nil, "stubbed" end,
                 unlock = function() return true end }
    end }
end
local ok_registry, registry_real = pcall(require, "resty.luarouter.registry")

-- ------------------------------------------------------------------ 装配
local models_list, caps_table, store_tbl
local registry_stub = {
    models = function() return models_list end,
    model_caps = function() return caps_table end,
    model_caps_from_listing = ok_registry and registry_real.model_caps_from_listing
        or function() return nil end,
}
local captured
local M
do
    local env = {
        registry = registry_stub,
        store = function() return store_tbl end,
        text_response = function(status, text)
            captured = { status = status, text = text }
            return ""
        end,
        tostring = tostring, type = type, tonumber = tonumber, next = next,
        pairs = pairs, ipairs = ipairs, table = table, string = string,
        math = math, select = select, pcall = pcall, rawget = rawget,
        setmetatable = setmetatable, os = os, require = require,
    }
    local factory = assert(load(blk
        .. "\nreturn { models_handler = models_handler,"
        .. " inject_virtual_models = inject_virtual_models }",
        "models-region", "t", env))
    M = factory()
end

--- 把上游 data[] 原文交给**真**归一化层，再喂给输出层。
local function advertise_listing(listing)
    caps_table = registry_stub.model_caps_from_listing(listing)
    return caps_table
end

-- ------------------------------------------------------------------ 断言
local fails = 0
local checks = 0
local function check(name, cond, extra)
    checks = checks + 1
    if cond then
        print("  ok   " .. name)
    else
        fails = fails + 1
        print("  FAIL " .. name .. (extra and (" -> " .. tostring(extra)) or ""))
    end
end

-- 自己编码而不是用 cjson：空表在 cjson 下会变 [] 或 {}，而"缺字段就删键"这条纪律要测
-- 的正是**输出层有没有把键留下**，编码器的兜底会把判定糊掉。
local function encode(v, indent)
    indent = indent or 0
    local pad, pad0 = string.rep("  ", indent + 1), string.rep("  ", indent)
    if type(v) == "table" then
        local n = #v
        if n > 0 then
            local parts = {}
            for i = 1, n do parts[i] = pad .. encode(v[i], indent + 1) end
            return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad0 .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        if #keys == 0 then return "{}" end
        local out = {}
        for _, k in ipairs(keys) do
            out[#out + 1] = pad .. '"' .. k .. '": ' .. encode(v[k], indent + 1)
        end
        return "{\n" .. table.concat(out, ",\n") .. "\n" .. pad0 .. "}"
    elseif type(v) == "string" then
        return '"' .. v .. '"'
    elseif type(v) == "boolean" then
        return v and "true" or "false"
    elseif v == nil then
        return "null"
    end
    return tostring(v)
end

local function find(rep, id)
    for i = 1, #rep.data do
        if rep.data[i].id == id then return rep.data[i] end
    end
    return nil
end

--- 官方 ModelObject：OpenAI 的 Model 响应体只有这四个字段，且四个都是 required。
local REQUIRED = { "id", "object", "created", "owned_by" }
local function missing_required(entry)
    local out = {}
    if type(entry) ~= "table" then return { "<entry gone>" } end
    for i = 1, #REQUIRED do
        if rawget(entry, REQUIRED[i]) == nil then out[#out + 1] = REQUIRED[i] end
    end
    return out
end
local function key_names(entry)
    local out = {}
    for k in pairs(entry) do
        if rawget(entry, k) ~= nil then out[#out + 1] = tostring(k) end
    end
    table.sort(out)
    return out
end
local function join(list) return table.concat(list or {}, ",") end

--- 取「可能整块不存在」的读数字段：旧实现下 capabilities / reasoning_efforts 是 nil，
--- 直接点下去会让整个探针崩在中途（崩掉 = 后面的组一个都没跑，判别性表就废了）。
--- 一律经这两个访问器，让"填不出来"表现为该条 FAIL 而不是脚本 error。
local function block(entry, key)
    if type(entry) ~= "table" then return nil end
    local value = rawget(entry, key)
    if type(value) ~= "table" then return nil end
    return value
end
local function read(entry, key, sub)
    local parent = entry
    if sub then
        parent = block(entry, key)
        if parent == nil then return nil end
        return rawget(parent, sub)
    end
    if parent == nil then return nil end
    return rawget(parent, key)
end

--- 操作员什么都没声明的最小 config 快照。
local function bare_store()
    return {
        virtual_models_list = function() return {} end,
        current = function()
            return { model_configs = {}, model_context_limit = {}, model_effort = {} }
        end,
        ctx_cap = function() return nil end,
        modalities_for = function() return nil end,
        profile_for = function() return nil end,
    }
end

-- 用户给的那份上游原文（opencodex 拼写）。两份档位**刻意不一致**：picker 给
-- low/medium/high/max，判定面只 low/high/max。这是判别"网关把阶梯虚构进判定面"这种
-- 写错的唯一输入，所以原样保留、不许"顺手统一"。
local UPSTREAM_K3 = {
    id = "kimi-code/k3", object = "model", created = 1700000000, owned_by = "vendor",
    supports_reasoning_effort = true, reasoning_effort = "medium",
    reasoning_efforts = {
        { value = "low", label = "Low Effort" },
        { value = "medium", label = "medium Effort", ["default"] = true },
        { value = "high", label = "High Effort" },
        { value = "max", label = "Max Effort" },
    },
    capabilities = {
        context_length = 1000000, max_output_tokens = 128000,
        output_modalities = { "text" }, input_modalities = { "text", "image" },
        supports_tool_use = true, supports_streaming = true,
        supports_reasoning = true, supports_vision = true,
        reasoning_effort = { "low", "high", "max" },
    },
}

local function listing_of(...)
    local data = {}
    for i = 1, select("#", ...) do data[i] = select(i, ...) end
    return { object = "list", data = data }
end

local function copy_table(source)
    local out = {}
    for k, v in pairs(source) do out[k] = v end
    return out
end

local function rung_default_marked(entry)
    local ladder = entry and entry.reasoning_efforts
    if type(ladder) ~= "table" then return 0, nil end
    local n, value = 0, nil
    for i = 1, #ladder do
        if ladder[i]["default"] == true then
            n = n + 1
            value = ladder[i].value
        end
    end
    return n, value
end

-- ===================================================================== 用例
print("=== G1 required 四字段：任何一行都不许缺 ===")
-- legacy 红：改动前真实模型那一支整个漏了 created（本次修的真 bug）。
local cases = {
    { name = "裸真实模型（无任何数据源）", models = { "bare" }, caps = nil,
      probe = "bare" },
    { name = "带能力读数的真实模型", models = { "kimi-code/k3" },
      listing = listing_of(UPSTREAM_K3), probe = "kimi-code/k3" },
    { name = "单目标入口", models = { "test-model" }, caps = {},
      alias = { { "alias-a", "test-model" } }, probe = "alias-a" },
    { name = "多目标入口", models = { "a1", "a2" }, caps = {},
      alias = { { "grp", "a1", "a2" } }, probe = "grp" },
}
for i = 1, #cases do
    local c = cases[i]
    models_list = c.models
    caps_table = c.caps
    store_tbl = bare_store()
    if c.listing then advertise_listing(c.listing) end
    if c.alias then
        local alias = c.alias
        store_tbl.virtual_models_list = function() return alias end
    end
    local rep = M.models_handler()
    local entry = find(rep, c.probe)
    local missing = missing_required(entry)
    check("G1 " .. c.name .. " 四字段齐", #missing == 0,
          "missing: " .. join(missing) .. " in " .. encode(entry or {}))
    if entry then
        check("G1 " .. c.name .. " object=model", entry.object == "model")
        check("G1 " .. c.name .. " created 是非负整数",
              type(entry.created) == "number" and entry.created >= 0
              and entry.created == math.floor(entry.created), tostring(entry.created))
    end
    -- 整表判定：只查第一条会被"第一条恰好对"骗过去。
    local bad = 0
    for k = 1, #rep.data do
        if #missing_required(rep.data[k]) > 0 then bad = bad + 1 end
    end
    check("G1 " .. c.name .. " 全表逐行都齐（不只第一条）",
          bad == 0 and #rep.data >= #c.models, bad .. " bad of " .. #rep.data)
end

print("=== G2 省略而不是 null/空表 ===")
-- legacy 部分红：老实现也只有三键，所以"没有 null"这一半在旧实现下也绿（那是回归
-- 守卫），而"恰好只有 required 四个键"这一半在旧实现下红（旧实现连 created 都没有）。
models_list = { "quiet" }
caps_table = nil
store_tbl = bare_store()
local rep_q = M.models_handler()
local raw_q = encode(rep_q)
check("G2 无数据源时整个 body 搜不到 null", raw_q:find("null", 1, true) == nil, raw_q)
check("G2 无数据源时不出现空数组/空对象",
      raw_q:find("%[%s*%]") == nil and raw_q:find("%{%s*%}") == nil, raw_q)
check("G2 无数据源时该模型只有 required 四个键",
      #key_names(rep_q.data[1]) == 4, join(key_names(rep_q.data[1])))
check("G2 无数据源时不出现 capabilities",
      rawget(rep_q.data[1], "capabilities") == nil)
check("G2 无数据源时不出现三个 effort 键",
      rawget(rep_q.data[1], "reasoning_efforts") == nil
      and rawget(rep_q.data[1], "reasoning_effort") == nil
      and rawget(rep_q.data[1], "supports_reasoning_effort") == nil)

-- 上游只说了一半：说出来的照报，没说的删键（不是 null、不是 []）。
models_list = { "half" }
advertise_listing(listing_of({ id = "half", object = "model",
    capabilities = { context_length = 262144 } }))
store_tbl = bare_store()
local rep_h = M.models_handler()
local e_h = rep_h.data[1]
check("G2 半个读数：说出来的 context_length 照报",
      read(e_h, "capabilities", "context_length") == 262144,
      encode(block(e_h, "capabilities") or {}))
check("G2 半个读数：没说的一律删键（无 null / 无 [] / 无 {}）",
      encode(rep_h):find("null", 1, true) == nil
      and read(e_h, "capabilities", "max_output_tokens") == nil
      and read(e_h, "capabilities", "input_modalities") == nil
      and read(e_h, "capabilities", "supports_tool_use") == nil
      and read(e_h, "capabilities", "reasoning_effort") == nil
      and rawget(e_h, "reasoning_efforts") == nil,
      encode(block(e_h, "capabilities") or {}))

print("=== G3 虚拟入口的 owned_by 老口径（有客户端在读，钉死） ===")
-- legacy 绿：这两条钉的是改动前已有的行为，属回归守卫（刻意如此）。
models_list = { "test-model" }
caps_table = {}
store_tbl = bare_store()
store_tbl.virtual_models_list = function() return { { "alias-a", "test-model" } } end
local rep_s = M.models_handler()
local e_s = find(rep_s, "alias-a")
check("G3 单目标 owned_by == llm-router-><目标模型名>",
      e_s and e_s.owned_by == "llm-router->test-model",
      e_s and tostring(e_s.owned_by) or "<entry gone>")
check("G3 单目标不带 owned_by_models", e_s and rawget(e_s, "owned_by_models") == nil)
check("G3 单目标 created == 0", e_s and e_s.created == 0,
      e_s and tostring(e_s.created))
check("G3 真实模型 owned_by 仍是 local",
      find(rep_s, "test-model").owned_by == "local")

models_list = { "Q38-Flash-Next", "kimi-code/k3" }
store_tbl.virtual_models_list = function()
    return { { "grp", "Q38-Flash-Next", "kimi-code/k3" } }
end
local rep_g = M.models_handler()
local e_g = find(rep_g, "grp")
check("G3 多目标 owned_by == llm-router", e_g and e_g.owned_by == "llm-router",
      e_g and tostring(e_g.owned_by) or "<entry gone>")
check("G3 多目标 owned_by_models 是目标列表",
      e_g and type(e_g.owned_by_models) == "table"
      and join(e_g.owned_by_models) == "Q38-Flash-Next,kimi-code/k3",
      e_g and join(e_g.owned_by_models))
check("G3 多目标 created == 0（组的 created 不继承成员）",
      e_g and e_g.created == 0, e_g and tostring(e_g.created))
-- id 的取值集合与排序也在这条链上：registry 的 worker 判定与客户端选模型全按 id 建。
check("G3 id 集合不被入口行污染且按 id 有序",
      join({ find(rep_g, "Q38-Flash-Next").id, find(rep_g, "grp").id,
             find(rep_g, "kimi-code/k3").id })
      == "Q38-Flash-Next,grp,kimi-code/k3")

print("=== G4 扩展字段被真正填上（判别性主战场） ===")
-- legacy 红：老实现只输出 {id,object,owned_by}，以下每一条都填不出来。
models_list = { "kimi-code/k3" }
advertise_listing(listing_of(UPSTREAM_K3))
store_tbl = bare_store()
local rep_r = M.models_handler()
local e_r = rep_r.data[1]
local cap_r = e_r.capabilities or {}
check("G4 capabilities.context_length 如实透出",
      cap_r.context_length == 1000000, tostring(cap_r.context_length))
check("G4 capabilities.max_output_tokens 如实透出",
      cap_r.max_output_tokens == 128000, tostring(cap_r.max_output_tokens))
check("G4 input_modalities 如实透出（顺序保留）",
      join(cap_r.input_modalities) == "text,image", join(cap_r.input_modalities))
check("G4 output_modalities 如实透出",
      join(cap_r.output_modalities) == "text", join(cap_r.output_modalities))
check("G4 四个 supports_* 都是 true",
      cap_r.supports_tool_use == true and cap_r.supports_streaming == true
      and cap_r.supports_reasoning == true and cap_r.supports_vision == true,
      encode(cap_r))
check("G4 顶层 supports_reasoning_effort", e_r.supports_reasoning_effort == true)
check("G4 picker 阶梯 = 引擎给的 4 档（含 label）",
      type(e_r.reasoning_efforts) == "table" and #e_r.reasoning_efforts == 4
      and e_r.reasoning_efforts[1].value == "low"
      and e_r.reasoning_efforts[1].label == "Low Effort"
      and e_r.reasoning_efforts[3].label == "High Effort",
      encode(e_r.reasoning_efforts or {}))
do
    local n, value = rung_default_marked(e_r)
    check("G4 阶梯里恰好一个 default:true 且落在 medium",
          n == 1 and value == "medium", n .. " -> " .. tostring(value))
    check("G4 顶层 reasoning_effort 与阶梯的 default 自洽",
          e_r.reasoning_effort == "medium", tostring(e_r.reasoning_effort))
end
-- 判定面不许被阶梯虚构：这是本形状里最容易写错的一条（上游自己就给的不一致）。
check("G4 判定面 = 引擎亲口说的 3 档，不掺阶梯里的 medium",
      join(cap_r.reasoning_effort) == "low,high,max", join(cap_r.reasoning_effort))
check("G4 created 用上游读数而不是 0", e_r.created == 1700000000,
      tostring(e_r.created))
check("G4 真实模型的 owned_by 仍是 local（引擎自报不上外）",
      e_r.owned_by == "local", tostring(e_r.owned_by))
-- 判别性的另一半：改一个上游读数，对外读数必须跟着变（否则上面几条全是恒真）。
local mutated = copy_table(UPSTREAM_K3)
mutated.capabilities = copy_table(UPSTREAM_K3.capabilities)
mutated.capabilities.context_length = 262144
models_list = { "kimi-code/k3" }
advertise_listing(listing_of(mutated))
local rep_m = M.models_handler()
check("G4 判别性：上游 context_length 改了，对外读数跟着变",
      read(rep_m.data[1], "capabilities", "context_length") == 262144,
      tostring(read(rep_m.data[1], "capabilities", "context_length")))
mutated.capabilities.max_output_tokens = 65536
advertise_listing(listing_of(mutated))
rep_m = M.models_handler()
check("G4 判别性：上游 max_output_tokens 改了，对外读数跟着变",
      read(rep_m.data[1], "capabilities", "max_output_tokens") == 65536,
      tostring(read(rep_m.data[1], "capabilities", "max_output_tokens")))
-- 采集链路的源头判据：真归一化层对这份原文确实给出了完整读数，上面的数不是输出层自造的。
do
    local caps = advertise_listing(listing_of(UPSTREAM_K3))
    local one = caps and caps["kimi-code/k3"] or nil
    check("G4 源头：归一化层从上游原文读出 context_length/max_output_tokens",
          one ~= nil and one.context_length == 1000000
          and one.max_output_tokens == 128000, encode(one or {}))
    check("G4 源头：判定面与阶梯分开留两份（不互相覆盖）",
          one ~= nil and type(one.reasoning_effort_values) == "table"
          and join(one.reasoning_effort_values) == "low,high,max"
          and type(one.reasoning_efforts) == "table"
          and #one.reasoning_efforts == 4,
          one and (join(one.reasoning_effort_values) .. "/"
                   .. tostring(one.reasoning_efforts and #one.reasoning_efforts)) or "<gone>")
end

print("=== G5 优先级：操作员 config 声明压过引擎自报 ===")
-- legacy 红：老实现读不到任何声明。
models_list = { "kimi-code/k3" }
advertise_listing(listing_of(UPSTREAM_K3))
store_tbl = bare_store()
store_tbl.current = function()
    return {
        model_configs = { ["kimi-code/k3"] = {
            ctx = 524288, context_limit = 300000, default_effort = "high",
            modalities = { "text", "image", "video" },
        } },
        model_context_limit = {}, model_effort = {},
    }
end
store_tbl.ctx_cap = function(model)
    if model == "kimi-code/k3" then return 524288 end
    return nil
end
store_tbl.modalities_for = function(model)
    if model == "kimi-code/k3" then return { "text", "image", "video" } end
    return nil
end
local rep_p = M.models_handler()
local e_p = rep_p.data[1]
check("G5 卡片 ctx 声明压过引擎 context_length",
      read(e_p, "capabilities", "context_length") == 524288,
      tostring(read(e_p, "capabilities", "context_length")))
check("G5 引擎报的那个值不再出现在输出里",
      encode(rep_p):find("1000000", 1, true) == nil, encode(e_p.capabilities or {}))
check("G5 卡片模态压过引擎模态",
      join(read(e_p, "capabilities", "input_modalities")) == "text,image,video",
      join(read(e_p, "capabilities", "input_modalities")))
check("G5 卡片 default_effort 决定对外缺省档",
      e_p.reasoning_effort == "high", tostring(e_p.reasoning_effort))
do
    local n, value = rung_default_marked(e_p)
    check("G5 default:true 只落在 high 那一档",
          n == 1 and value == "high", n .. " -> " .. tostring(value))
end
check("G5 操作员没声明的维度仍取引擎读数（每个维度独立取源）",
      read(e_p, "capabilities", "max_output_tokens") == 128000,
      tostring(read(e_p, "capabilities", "max_output_tokens")))
-- 卡片只写 context_limit（没有 ctx）：走 declared_context_limit 那一支。
store_tbl.ctx_cap = function() return nil end
local rep_p2 = M.models_handler()
check("G5 只有卡片 context_limit 时它也压过引擎",
      read(rep_p2.data[1], "capabilities", "context_length") == 300000,
      tostring(read(rep_p2.data[1], "capabilities", "context_length")))
-- 平铺层 model_context_limit（完全没有卡片）。
store_tbl = bare_store()
store_tbl.current = function()
    return { model_configs = {}, model_context_limit = { ["kimi-code/k3"] = 131072 },
             model_effort = {} }
end
rep_p2 = M.models_handler()
check("G5 平铺层 model_context_limit 也压过引擎",
      read(rep_p2.data[1], "capabilities", "context_length") == 131072,
      tostring(read(rep_p2.data[1], "capabilities", "context_length")))

print("=== G6 虚拟入口的能力来自组内聚合，只在口径一致时才声明 ===")
-- legacy 红：老实现的入口行只有四个键，任何 capabilities 都填不出来。
local UP_A = copy_table(UPSTREAM_K3)
UP_A.id = "a1"
local UP_B = copy_table(UPSTREAM_K3)
UP_B.id = "a2"
models_list = { "a1", "a2" }
advertise_listing(listing_of(UP_A, UP_B))
store_tbl = bare_store()
store_tbl.virtual_models_list = function() return { { "grp", "a1", "a2" } } end
local rep_v = M.models_handler()
local e_v = find(rep_v, "grp")
check("G6 组行也带齐 required 四字段",
      #missing_required(e_v) == 0, join(missing_required(e_v)))
check("G6 组内读数一致时 capabilities 照报",
      e_v.capabilities and e_v.capabilities.context_length == 1000000,
      encode(e_v.capabilities or {}))
check("G6 组行不继承成员的 created", e_v.created == 0, tostring(e_v.created))
check("G6 组行档位表与成员一致（且只有一个 default）",
      type(e_v.reasoning_efforts) == "table" and #e_v.reasoning_efforts == 4
      and (rung_default_marked(e_v)) == 1, encode(e_v.reasoning_efforts or {}))
-- 组内不一致：数值取最窄，picker 删键（不把两台并起来造出会被拒的选项）。
local NARROW_A = copy_table(UP_A)
NARROW_A.capabilities = copy_table(UP_A.capabilities)
NARROW_A.capabilities.context_length = 524288
local NARROW_B = copy_table(UP_B)
NARROW_B.capabilities = copy_table(UP_B.capabilities)
NARROW_B.capabilities.context_length = 262144
NARROW_B.reasoning_efforts = { { value = "low", label = "Low Effort" } }
models_list = { "a1", "a2" }
advertise_listing(listing_of(NARROW_A, NARROW_B))
store_tbl = bare_store()
store_tbl.virtual_models_list = function() return { { "grp", "a1", "a2" } } end
local rep_n = M.models_handler()
local e_n = find(rep_n, "grp")
check("G6 组内 context 不一致时取最窄",
      e_n.capabilities and e_n.capabilities.context_length == 262144,
      tostring(e_n.capabilities and e_n.capabilities.context_length))
check("G6 组内档位序列不一致 -> picker 整个删键",
      rawget(e_n, "reasoning_efforts") == nil, encode(e_n.reasoning_efforts or {}))
check("G6 删键的输出里没有 null", encode(rep_n):find("null", 1, true) == nil)
-- 入口自己声明 context_window 时压过组内最小值（那是对外声明的总窗口）。
store_tbl.profile_for = function(name)
    if name == "grp" then return { model = "grp", context_window = 200000 } end
    return nil
end
local rep_cw = M.models_handler()
check("G6 入口声明的 context_window 优先于组内最窄",
      read(find(rep_cw, "grp"), "capabilities", "context_length") == 200000,
      tostring(read(find(rep_cw, "grp"), "capabilities", "context_length")))

print("=== G6b 组内**缺读数**的成员必须让整键消失（2026-10-04 线上缺陷） ===")
-- 症状（生产 235.t:8800）：入口 Qn 的组里是 Q38-Flash-Next + kimi-code/k3，kimi 报
-- context_length 1000000，Q38 那一半当时**一个长度读数都没有**，于是对外广告出了
-- 1000000 —— 比部分成员能承受的更大。客户端照这个值塞 token，请求被策略派到 Q38 那
-- 一半就炸。旧实现的 narrowest_number 只比"给出读数的成员"，把未知读成了默许。
-- 判别性纪律：这一组必须与"都有读数时照报最窄"**成对**出现——只有删键类断言的那一组
-- 在旧实现（旧实现整行没有 capabilities）下会误绿，成对的照报断言把它抬红。
local GA = copy_table(UPSTREAM_K3)
GA.id = "b1"
GA.capabilities = copy_table(UPSTREAM_K3.capabilities)
GA.capabilities.context_length = 524288
GA.capabilities.max_output_tokens = 65536
local GB = copy_table(UPSTREAM_K3)
GB.id = "b2"
GB.capabilities = copy_table(UPSTREAM_K3.capabilities)
GB.capabilities.context_length = 1000000
GB.capabilities.max_output_tokens = nil
models_list = { "b1", "b2" }
advertise_listing(listing_of(GA, GB))
store_tbl = bare_store()
store_tbl.virtual_models_list = function() return { { "grpb", "b1", "b2" } } end
local rep_half = M.models_handler()
local e_half = find(rep_half, "grpb")
-- 两台都开了口：数值照旧取最窄（这条红 = 修复过头，把能报的也抹了）。
check("G6b 组内两台都有长度读数(524288/1000000) -> 报最窄 524288（不许修过头）",
      read(e_half, "capabilities", "context_length") == 524288,
      tostring(read(e_half, "capabilities", "context_length")))
-- 只有一台给了输出预算：那一键必须整体消失，而不是拿已知那份对外担保。
check("G6b 组内一台没报 max_output_tokens -> 整个键删除（不是抄另一台）",
      rawget(block(e_half, "capabilities") or {}, "max_output_tokens") == nil,
      encode(block(e_half, "capabilities") or {}))
check("G6b 键缺失的输出里没有 null / 空表冒充",
      encode(rep_half):find("null", 1, true) == nil, encode(rep_half))

-- 线上那份形状：一台有长度读数，另一台整行里没有任何长度读数（刻意保留档位读数，
-- 这样测的是"这台没给窗口读数"，而不是"这台整行都没登记"）。
local HA = copy_table(UPSTREAM_K3)
HA.id = "c1"
HA.capabilities = copy_table(UPSTREAM_K3.capabilities)
HA.capabilities.context_length = 1000000
HA.capabilities.max_output_tokens = 128000
local HB = copy_table(UPSTREAM_K3)
HB.id = "c2"
HB.capabilities = {}
models_list = { "c1", "c2" }
advertise_listing(listing_of(HA, HB))
store_tbl = bare_store()
store_tbl.virtual_models_list = function() return { { "grpc", "c1", "c2" } } end
local rep_unknown = M.models_handler()
local e_unknown = find(rep_unknown, "grpc")
check("G6b 线上形状：一台有读数一台没有 -> context_length 必须不存在【判别本缺陷】",
      rawget(block(e_unknown, "capabilities") or {}, "context_length") == nil,
      encode(block(e_unknown, "capabilities") or {}))
check("G6b 线上形状：max_output_tokens 同样必须不存在（同一条纪律）",
      rawget(block(e_unknown, "capabilities") or {}, "max_output_tokens") == nil,
      encode(block(e_unknown, "capabilities") or {}))
check("G6b 删键不许顺带掉官方四字段（required 恒齐）",
      #missing_required(e_unknown) == 0, join(missing_required(e_unknown)))
check("G6b 删键不影响成员自己那行（c1 仍如实报自己的 1000000）",
      read(find(rep_unknown, "c1"), "capabilities", "context_length") == 1000000,
      encode(find(rep_unknown, "c1") or {}))
-- 例外路径：入口自己声明的 context_window 是操作员说的话，组内不齐也必须照报，
-- 且只救 length —— 没有任何声明可依据的 max_output_tokens 仍然走删键。
store_tbl.profile_for = function(name)
    if name == "grpc" then return { model = name, context_window = 65535 } end
    return nil
end
local rep_decl = M.models_handler()
local e_decl = find(rep_decl, "grpc")
check("G6b 入口声明 context_window=65535 且组内不齐 -> 仍报 65535（例外不许被改坏）",
      read(e_decl, "capabilities", "context_length") == 65535,
      tostring(read(e_decl, "capabilities", "context_length")))
check("G6b 例外只覆盖 length；max_output_tokens 无声明可依 -> 仍删键",
      rawget(block(e_decl, "capabilities") or {}, "max_output_tokens") == nil,
      encode(block(e_decl, "capabilities") or {}))
-- 单成员入口（入口**就是**那台引擎）：没有"组内不齐"要仲裁，读数照报。
models_list = { "solo" }
advertise_listing(listing_of({
    id = "solo", object = "model",
    capabilities = { context_length = 262144, max_output_tokens = 32768 },
}))
store_tbl = bare_store()
store_tbl.virtual_models_list = function() return { { "solo-entry", "solo" } } end
local rep_solo = M.models_handler()
check("G6b 单成员入口有读数 -> 两条数值照报（没有组内仲裁可言）",
      read(find(rep_solo, "solo-entry"), "capabilities", "context_length") == 262144
      and read(find(rep_solo, "solo-entry"), "capabilities", "max_output_tokens") == 32768,
      encode(find(rep_solo, "solo-entry") or {}))

print("=== G7 上游原文的脏形状不许把对外读数变成假话 ===")
-- legacy 部分红（旧实现没有任何 capabilities，"删键"类断言会误绿）：这里额外钉
-- "四字段仍齐"，让旧实现下至少这条红，避免整组退化成恒真。
local function bare_entry(id, extra)
    local one = { id = id, object = "model" }
    for k, v in pairs(extra or {}) do one[k] = v end
    return one
end
models_list = { "dirt" }
advertise_listing(listing_of(bare_entry("dirt", {
    capabilities = { context_length = "not-a-number", max_output_tokens = -5,
                     input_modalities = { "", 7, true }, supports_vision = "yes",
                     reasoning_effort = { 1, 2 } },
    reasoning_efforts = { { label = "no value" }, "low", "low" },
})))
store_tbl = bare_store()
local rep_d = M.models_handler()
local e_d = rep_d.data[1]
local cap_d = e_d.capabilities
check("G7 脏形状下 required 四字段仍然齐",
      #missing_required(e_d) == 0, join(missing_required(e_d)))
check("G7 非法数值一律删键而不是 0",
      cap_d == nil or (rawget(cap_d, "context_length") == nil
                       and rawget(cap_d, "max_output_tokens") == nil),
      encode(cap_d or {}))
check("G7 非字符串模态被洗掉，空集合删键（不报 []）",
      cap_d == nil or rawget(cap_d, "input_modalities") == nil, encode(cap_d or {}))
check("G7 非布尔 supports_vision 读作没说（删键，不写 false）",
      cap_d == nil or rawget(cap_d, "supports_vision") == nil, encode(cap_d or {}))
-- 引擎给的判定面（capabilities.reasoning_effort = {1,2}）被洗空后**退到阶梯序列**，
-- 而不是把脏数字抬出去，也不是删键——阶梯是引擎另一句原话，判定面退到它是实现里
-- 写明的口径（resolve_model_caps 的 `or ladder_values(ladder)`）。
check("G7 判定面的数字档位被洗掉后退到阶梯序列（不抬数字、不误删键）",
      cap_d ~= nil and join(cap_d.reasoning_effort) == "low",
      encode(cap_d or {}))
check("G7 档位只留字符串且去重（1 条 low）",
      type(e_d.reasoning_efforts) == "table" and #e_d.reasoning_efforts == 1
      and e_d.reasoning_efforts[1].value == "low", encode(e_d.reasoning_efforts or {}))
check("G7 脏输入的输出里没有 null", encode(rep_d):find("null", 1, true) == nil,
      encode(rep_d))

print("=== G8 没有 worker 时的 503 纯文本分支不变 ===")
-- legacy 绿：钉的是改动前就有的行为，属回归守卫（客户端的缓存/重试判定依赖它）。
models_list = {}
caps_table = nil
captured = nil
store_tbl = bare_store()
local rep_empty = M.models_handler()
check("G8 无 worker 返回空串（响应已手写）", rep_empty == "", tostring(rep_empty))
check("G8 状态码仍是 503 且文案原样",
      captured ~= nil and captured.status == 503
      and captured.text == "No models available", encode(captured or {}))

print("=== G9 同一份数据两次调用的字节完全相同 ===")
-- 判别性：created 若取 ngx.time() 则这一条必红（客户端缓存与前后对比依赖它）。
models_list = { "kimi-code/k3" }
advertise_listing(listing_of(UPSTREAM_K3))
store_tbl = bare_store()
local first = encode(M.models_handler())
local second = encode(M.models_handler())
check("G9 两次输出逐字节相同", first == second, first .. "\n---\n" .. second)

print("=== G10 同名遮蔽（用户裁定 2026-10-07 方案 A）：入口赢，真实那一行不再单独出现 ===")
-- 判别性：733b386 之前 inject_virtual_models 的裁判方向是「真实 worker 保住名字、入口行被
-- 丢弃」(if not seen[alias])。把 LR_MODELS_TEST_LEGACY_SRC 指向改动前的 models_api.lua 时，
-- 本组**每一条**都必须红：同名时入口行缺席 → find 返回 nil，条数/owned_by/created 全对不上。
local function count_id(rep, id)
    local n = 0
    for i = 1, #rep.data do
        if rep.data[i].id == id then n = n + 1 end
    end
    return n
end
local function ids_of(rep)
    local out = {}
    for i = 1, #rep.data do out[i] = tostring(rep.data[i].id) end
    return table.concat(out, ",")
end

-- (a) 单成员同名入口：入口 X 的组里只有被它遮蔽的那个真实模型 X。
local SHADOW_SOLO = copy_table(UPSTREAM_K3)
SHADOW_SOLO.id = "shadow-solo"
SHADOW_SOLO.capabilities = copy_table(UPSTREAM_K3.capabilities)
SHADOW_SOLO.capabilities.context_length = 262144
SHADOW_SOLO.capabilities.max_output_tokens = 32768
SHADOW_SOLO.reasoning_efforts = nil
SHADOW_SOLO.supports_reasoning_effort = nil
SHADOW_SOLO.reasoning_effort = nil
local PLAIN_B = copy_table(UPSTREAM_K3)
PLAIN_B.id = "plain-b"
PLAIN_B.capabilities = copy_table(UPSTREAM_K3.capabilities)
PLAIN_B.capabilities.context_length = 131072
PLAIN_B.capabilities.max_output_tokens = 16384
PLAIN_B.reasoning_efforts = nil
PLAIN_B.supports_reasoning_effort = nil
PLAIN_B.reasoning_effort = nil
models_list = { "shadow-solo", "plain-b" }
advertise_listing(listing_of(SHADOW_SOLO, PLAIN_B))
store_tbl = bare_store()
store_tbl.virtual_models_list = function() return { { "shadow-solo", "shadow-solo" } } end
local rep_shadow = M.models_handler()
local e_shadow = find(rep_shadow, "shadow-solo")
check("G10 T9 同名入口在列表里恰好一行（真实那一行被摘掉）",
      count_id(rep_shadow, "shadow-solo") == 1, ids_of(rep_shadow))
check("G10 T9 全表条数 = 未被遮蔽的真实模型 + 入口（不多不少、不重复 id）",
      #rep_shadow.data == 2, ids_of(rep_shadow))
check("G10 T9 id 集合按升序且无重复", ids_of(rep_shadow) == "plain-b,shadow-solo",
      ids_of(rep_shadow))
check("G10 T9 那一行是入口行：单成员 owned_by == llm-router-><绑定名>",
      e_shadow ~= nil and e_shadow.owned_by == "llm-router->shadow-solo",
      e_shadow and tostring(e_shadow.owned_by) or "<entry gone>")
check("G10 T9 入口行不带 owned_by_models（单成员的老口径不因遮蔽改变）",
      e_shadow ~= nil and rawget(e_shadow, "owned_by_models") == nil)
check("G10 T9 入口行 created 恒 0（不继承被遮蔽引擎的读数）",
      e_shadow ~= nil and e_shadow.created == 0,
      e_shadow and tostring(e_shadow.created) or "<entry gone>")
check("G10 T9 遮蔽后 required 四字段仍然齐",
      #missing_required(e_shadow) == 0, join(missing_required(e_shadow)))
check("G10 T9 未同名的真实行不受影响（那一行还在、owned_by 仍 local）",
      count_id(rep_shadow, "plain-b") == 1
      and find(rep_shadow, "plain-b").owned_by == "local", ids_of(rep_shadow))
-- 判别性的另一半：入口行说的是被遮蔽那台引擎的读数。若实现把入口行做成「谁都不继承」的
-- 空行（顺手改遮蔽方向时最容易犯），下面这条立刻红。
check("G10 T9 入口行的数值读数来自被遮蔽的那台引擎",
      read(e_shadow, "capabilities", "context_length") == 262144
      and read(e_shadow, "capabilities", "max_output_tokens") == 32768,
      encode(block(e_shadow, "capabilities") or {}))
check("G10 T9 遮蔽后两次调用逐字节相同（摘除是纯查表，没把顺序依赖带进输出）",
      encode(rep_shadow) == encode(M.models_handler()), ids_of(rep_shadow))

-- (b) T10：入口声明的 context_window 在遮蔽后仍然压过引擎自报。
store_tbl.profile_for = function(name)
    if name == "shadow-solo" then return { model = name, context_window = 65535 } end
    return nil
end
local rep_cw = M.models_handler()
check("G10 T10 入口声明 context_window=65535 压过引擎自报的 262144",
      read(find(rep_cw, "shadow-solo"), "capabilities", "context_length") == 65535,
      tostring(read(find(rep_cw, "shadow-solo"), "capabilities", "context_length")))
check("G10 T10 例外只覆盖 length：max_output_tokens 仍取引擎读数",
      read(find(rep_cw, "shadow-solo"), "capabilities", "max_output_tokens") == 32768,
      encode(block(find(rep_cw, "shadow-solo"), "capabilities") or {}))
store_tbl.profile_for = function() return nil end
local rep_cw_off = M.models_handler()
check("G10 T10 判别性：撤掉入口声明后同一格回到引擎自报的 262144",
      read(find(rep_cw_off, "shadow-solo"), "capabilities", "context_length") == 262144,
      tostring(read(find(rep_cw_off, "shadow-solo"), "capabilities", "context_length")))

-- (c) 多成员同名入口：owned_by 走「入口拥有整组」那一支，被遮蔽的名字仍在组里如实挂着。
models_list = { "grp-x", "member-b" }
advertise_listing(listing_of({ id = "grp-x", object = "model",
    capabilities = { context_length = 262144 } }))
store_tbl = bare_store()
store_tbl.virtual_models_list = function()
    return { { "grp-x", "grp-x", "member-b" } }
end
local rep_grp = M.models_handler()
local e_grp = find(rep_grp, "grp-x")
check("G10 T9 多成员同名入口也只出一行", count_id(rep_grp, "grp-x") == 1, ids_of(rep_grp))
check("G10 T9 多成员入口 owned_by == llm-router（入口口径，不是 local）",
      e_grp ~= nil and e_grp.owned_by == "llm-router",
      e_grp and tostring(e_grp.owned_by) or "<entry gone>")
check("G10 T9 owned_by_models 如实挂着整组（含被遮蔽的那个名字）",
      e_grp ~= nil and type(e_grp.owned_by_models) == "table"
      and join(e_grp.owned_by_models) == "grp-x,member-b",
      e_grp and join(e_grp.owned_by_models or {}))
check("G10 T9 多成员同名入口 created 恒 0",
      e_grp ~= nil and e_grp.created == 0, e_grp and tostring(e_grp.created))
check("G10 T9 未同名的成员行照旧单独广告（遮蔽只吃 id 相等的那一行）",
      count_id(rep_grp, "member-b") == 1
      and find(rep_grp, "member-b").owned_by == "local", ids_of(rep_grp))

-- (d) 判据精确到入口名：组内成员名与某真实模型同名时**不许**误伤那一行。
-- 判别性：若有人把摘除判据从「入口名」放宽成「名册里出现过的任何名字」，
-- m-a / m-b 两行会被一起摘掉 → 这一条红。
models_list = { "m-a", "m-b" }
caps_table = {}
store_tbl = bare_store()
store_tbl.virtual_models_list = function() return { { "ent", "m-a", "m-b" } } end
local rep_member = M.models_handler()
check("G10 组员名与真实模型同名不误伤：三行都在（ent,m-a,m-b）",
      ids_of(rep_member) == "ent,m-a,m-b", ids_of(rep_member))
check("G10 组员那两行的 owned_by 仍是 local",
      find(rep_member, "m-a").owned_by == "local"
      and find(rep_member, "m-b").owned_by == "local")

-- (e) 同名 + 重复别名：真实行只摘一次，入口行按名册顺序保留第一条。
models_list = { "dup-name" }
caps_table = {}
store_tbl = bare_store()
store_tbl.virtual_models_list = function()
    return { { "dup-name", "one" }, { "dup-name", "two" } }
end
local rep_dup = M.models_handler()
check("G10 同名重复别名不重复 id，且保留名册里第一条",
      count_id(rep_dup, "dup-name") == 1
      and find(rep_dup, "dup-name").owned_by == "llm-router->one",
      ids_of(rep_dup) .. " / " .. tostring(find(rep_dup, "dup-name").owned_by))
caps_table = nil
store_tbl = bare_store()

do
print("=== G11 卡片档位勾选：操作员勾选接管对外阶梯，判定面只跟引擎说过的（用户诉求 2026-10-08）===")
-- legacy 红：老实现没有 card.reasoning_efforts 这一族，勾选表要么整个不被读（picker 仍是引擎
-- 那 4 档）、要么判定面被勾选表顶掉。两条判别各自把一组断言染红。
local function rung_values(ladder)
    if type(ladder) ~= "table" then return nil end
    local out = {}
    for i = 1, #ladder do out[i] = ladder[i].value end
    return table.concat(out, ",")
end
local function rung_labels(ladder)
    if type(ladder) ~= "table" then return nil end
    local out = {}
    for i = 1, #ladder do out[i] = ladder[i].label or "-" end
    return table.concat(out, ",")
end
local function card_store(ladder)
    local s = bare_store()
    s.current = function()
        return {
            model_configs = { ["kimi-code/k3"] = { reasoning_efforts = ladder } },
            model_context_limit = {}, model_effort = {},
        }
    end
    return s
end
-- 引擎那份（UPSTREAM_K3）：阶梯 low/medium/high/max（medium 带 default + 4 个 label），
-- 判定面只 low/high/max。勾选表故意做三件事：删掉 medium、加进引擎从没报过的 xhigh、
-- 把预选挪到 high。
models_list = { "kimi-code/k3" }
advertise_listing(listing_of(UPSTREAM_K3))
local TICKED = {
    { value = "low", ["default"] = false },
    { value = "high", ["default"] = true },
    { value = "max", ["default"] = false },
    { value = "xhigh", ["default"] = false },
}
store_tbl = card_store(TICKED)
local rep_t = M.models_handler()
local e_t = rep_t.data[1]
check("G11 required 四字段仍齐（多出来的只是扩展位）",
      #missing_required(e_t) == 0, encode(missing_required(e_t)))
check("G11 picker = 勾选的那 4 档（顺序 = 勾选顺序，medium 被取消后消失）",
      rung_values(e_t.reasoning_efforts) == "low,high,max,xhigh",
      tostring(rung_values(e_t.reasoning_efforts)))
check("G11 勾选档位的 label 从引擎那份继承（一次勾选不毁掉别的字段）",
      rung_labels(e_t.reasoning_efforts) == "Low Effort,High Effort,Max Effort,-",
      tostring(rung_labels(e_t.reasoning_efforts)))
do
    local n, value = rung_default_marked(e_t)
    check("G11 预选落在操作员标的 high 上（恰好一枚 default）",
          n == 1 and value == "high", n .. " -> " .. tostring(value))
    check("G11 顶层 reasoning_effort 与预选自洽", e_t.reasoning_effort == "high",
          tostring(e_t.reasoning_effort))
end
-- 判定面：引擎说过 low/high/max，勾选把 medium 取消（本来就不在判定面里）、加的 xhigh
-- 引擎从没说过 —— 所以判定面必须仍是 low,high,max 三个，**不许**冒出 xhigh。
check("G11 判定面 = 引擎说过 ∩ 勾选（xhigh 只进 picker、不进判定面）",
      join(read(e_t, "capabilities", "reasoning_effort")) == "low,high,max",
      join(read(e_t, "capabilities", "reasoning_effort")))
-- 取消到判定面之外：勾掉 max（引擎判定面里的那一档）→ 判定面剩 low,high。
store_tbl = card_store({
    { value = "low", ["default"] = false },
    { value = "high", ["default"] = true },
    { value = "xhigh", ["default"] = false },
})
local rep_cut = M.models_handler()
check("G11 勾掉引擎判定面里的一档，判定面同步收窄",
      join(read(rep_cut.data[1], "capabilities", "reasoning_effort")) == "low,high",
      join(read(rep_cut.data[1], "capabilities", "reasoning_effort")))
-- 只勾引擎从没报过的档位（引擎连判定面都没给）：判定面这时退到勾选序列 —— 与原来
-- 「退到阶梯序列」同一支路，只是序列换成了操作员那份。
local UP_BARE = {
    id = "kimi-code/k3", object = "model", created = 1700000000, owned_by = "vendor",
    capabilities = { context_length = 1000000 },
}
advertise_listing(listing_of(UP_BARE))
store_tbl = card_store({
    { value = "minimal", ["default"] = true },
    { value = "ultra", ["default"] = false },
})
local rep_blind = M.models_handler()
local e_blind = rep_blind.data[1]
check("G11 引擎什么都没报时，勾选表就是 picker 的唯一来源",
      rung_values(e_blind.reasoning_efforts) == "minimal,ultra",
      tostring(rung_values(e_blind.reasoning_efforts)))
check("G11 无引擎 label 可用时不编一个（整列都该没有 label）",
      rung_labels(e_blind.reasoning_efforts) == "-,-",
      tostring(rung_labels(e_blind.reasoning_efforts)))
check("G11 勾选撑起 supports_reasoning_effort（原来两侧都沉默时该键是省略的）",
      e_blind.supports_reasoning_effort == true, tostring(e_blind.supports_reasoning_effort))
check("G11 引擎无判定面时判定面退到勾选序列（不虚构、也不误删）",
      join(read(e_blind, "capabilities", "reasoning_effort")) == "minimal,ultra",
      join(read(e_blind, "capabilities", "reasoning_effort")))
-- 清除回自动：键不在（null 语义） → 整条阶梯退回引擎原话，与 G4 逐字节一致。
advertise_listing(listing_of(UPSTREAM_K3))
store_tbl = card_store(nil)
local rep_auto = M.models_handler()
local e_auto = rep_auto.data[1]
check("G11 卡片没勾 = 跟随引擎：阶梯回到那 4 档（判别性：读不到勾选表也读不到声明）",
      rung_values(e_auto.reasoning_efforts) == "low,medium,high,max",
      tostring(rung_values(e_auto.reasoning_efforts)))
check("G11 卡片没勾时判定面也不被收窄",
      join(read(e_auto, "capabilities", "reasoning_effort")) == "low,high,max",
      join(read(e_auto, "capabilities", "reasoning_effort")))
do
    local n = rung_default_marked(e_auto)
    check("G11 引擎的预选（medium）在自动态下不被勾选手势影响", n == 1, n)
end
-- 勾选表与专职字段打架：default_effort 卡片位压过勾选表上的 default 标记（同一条陈述里
-- 专职字段赢，与 model_scoped_effort 的既有优先级一致）。
store_tbl = card_store(TICKED)
store_tbl.current = function()
    return {
        model_configs = { ["kimi-code/k3"] = {
            reasoning_efforts = TICKED, default_effort = "max",
        } },
        model_context_limit = {}, model_effort = {},
    }
end
local rep_forced = M.models_handler()
do
    local n, value = rung_default_marked(rep_forced.data[1])
    check("G11 卡片 default_effort 压过勾选表上的预选标记",
          n == 1 and value == "max", n .. " -> " .. tostring(value))
end
-- 组内一台勾过一台没勾：入口行的阶梯按组内一致口径判 —— 不一致删键（宁可不报）。
local UP_G1 = copy_table(UPSTREAM_K3); UP_G1.id = "g1"
local UP_G2 = copy_table(UPSTREAM_K3); UP_G2.id = "g2"
models_list = { "g1", "g2" }
advertise_listing(listing_of(UP_G1, UP_G2))
store_tbl = bare_store()
store_tbl.virtual_models_list = function() return { { "grp-l", "g1", "g2" } } end
store_tbl.current = function()
    return {
        model_configs = { g1 = { reasoning_efforts = {
            { value = "low", ["default"] = true },
            { value = "high", ["default"] = false },
        } } },
        model_context_limit = {}, model_effort = {},
    }
end
local rep_grp = M.models_handler()
local e_grp_row = find(rep_grp, "grp-l")
check("G11 组内只有一台勾过 -> 入口行的 picker 删键（成员间口径不齐）",
      rawget(e_grp_row, "reasoning_efforts") == nil,
      encode(e_grp_row.reasoning_efforts or {}))
check("G11 删键不牵连真实模型那一行（g1 自己仍如实报勾选结果）",
      rung_values(find(rep_grp, "g1").reasoning_efforts) == "low,high",
      tostring(rung_values(find(rep_grp, "g1").reasoning_efforts)))
-- 两台勾同一份：入口行恢复，且恰好一个预选。
store_tbl.current = function()
    local cards = {}
    for _, id in ipairs({ "g1", "g2" }) do
        cards[id] = { reasoning_efforts = {
            { value = "low", ["default"] = false },
            { value = "high", ["default"] = true },
        } }
    end
    return { model_configs = cards, model_context_limit = {}, model_effort = {} }
end
local rep_grp2 = M.models_handler()
local e_grp2 = find(rep_grp2, "grp-l")
check("G11 组内勾选一致 -> 入口行的 picker 用勾选表",
      rung_values(e_grp2.reasoning_efforts) == "low,high",
      tostring(rung_values(e_grp2.reasoning_efforts)))
do
    local n, value = rung_default_marked(e_grp2)
    check("G11 入口行的预选唯一且落在勾选标的 high",
          n == 1 and value == "high", n .. " -> " .. tostring(value))
end
check("G11 判定面按组内交集（勾掉的那档从整组判定面消失）",
      join(read(e_grp2, "capabilities", "reasoning_effort")) == "low,high",
      join(read(e_grp2, "capabilities", "reasoning_effort")))
caps_table = nil
store_tbl = bare_store()

end
print(string.format("\n%d checks, %d failed", checks, fails))
os.exit(fails == 0 and 0 or 1)
