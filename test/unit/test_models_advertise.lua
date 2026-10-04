#!/usr/bin/env luajit
-- /v1/models 广告面开关 models_advertise 的**判定层**单测：纯 luajit，不绑端口、不起
-- 容器，因此可与 host 网络的门禁并发（AGENTS.md 硬规则 1）。
--
-- 为什么在 e2e_models_advertisement 之外还要这一份：e2e 只能从 HTTP 外面看「广告了哪几
-- 行」，它证不了开关内部的三条判定纪律，而那三条正是最容易被"顺手简化"写坏的地方：
--   1. truthy 是「认识才算开」而不是「非假即真」——一个写错的字符串必须退回缺省全量广告，
--      而不是把硬规则 9 第三条的老契约整页翻掉；
--   2. 磁盘读数与 env 读数是**优先级**而不是 OR：磁盘说 false 必须压过 env 说 true；
--      而 nil（没说）与 false（说了要关）必须分家，否则 env 层永远读不到；
--   3. only_data 拿不到入口时返回 **nil**（= 调用方退回全量）而不是空表（= 交空列表）。
--      这两件事在 HTTP 面上长得一模一样（都是 data[] 有没有内容），只有把源码切出来才
--      分得开。返回形状写反 = 静默清空整个服务，是这份单测存在的首要理由。
--
-- 手法沿用 test/unit/test_models_shape.lua 与 test_caps_routing.lua：按锚点把 router.lua
-- 的**真实现**切出来配桩加载，断言跑在盘上那份代码上。
--
-- 判别性纪律：LR_MODELS_TEST_LEGACY_SRC 指向 030dab5 之前的 router.lua 时，同一组断言跑在
--   旧实现上，除标注「回归守卫」的以外全部必须红（旧实现连 models_advertise 这块都没有，
--   切片直接失败 → 整份非零退出）。反向变异验证（三条判定各造一个写错的路由树，口径见
--   doc 与本次回报）：truthy 改成「非假即真」→ G1 红；两层读数改成 OR → G2 的优先级条红；
--   only_data 的 nil 改成空表 → G3 红。
--
-- 运行：
--   docker run --rm -v "$PWD":/repo:ro -w /repo -e LUA_TEST_LIB=/repo/lualib \
--     --entrypoint /usr/local/openresty/luajit/bin/luajit authz:latest \
--     test/unit/test_models_advertise.lua
local lib = os.getenv("LUA_TEST_LIB") or "./lualib"
local legacy_src_path = os.getenv("LR_MODELS_TEST_LEGACY_SRC")

local fh = io.open(lib .. "/resty/luarouter/router.lua")
local src = fh and fh:read("*a")
if type(src) ~= "string" then
    print("FAIL: cannot read router.lua from " .. lib)
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

-- 切出整块开关：从表的声明到 inject_virtual_models 之前（后者是广告面的老逻辑，由
-- test_models_shape.lua 钉，不属于本文件）。
local a = src:find("local models_advertise = {", 1, true)
local b = src:find("local function inject_virtual_models", 1, true)
local blk = (a and b and b > a) and src:sub(a, b - 1) or nil
if type(blk) ~= "string" then
    -- 判别性的锚点：旧实现没有这一节，切片必然失败。这里如实报错退出而不是"跳过"，
    -- 否则旧实现下会伪装成一份全绿的报告。
    print("FAIL: cannot slice the models_advertise region out of router.lua"
        .. (legacy_src_path and (" (legacy tree: " .. legacy_src_path .. ")") or ""))
    os.exit(1)
end

package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath
package.path = lib .. "/?.lua;" .. package.path
local cjson = require "cjson.safe"

-- ------------------------------------------------------------------ 桩
-- advertise_virtual_entry 属于**另一条**纪律（入口行的形状），由 test_models_shape.lua
-- 与 e2e_models_advertisement 钉。这里桩成"required 四字段 + 由 alias/tail 派生的 owned_by"
-- 这一最小形状，让 only_data 的判定不被行内容干扰；正因为字段是从入参派生的，"每入口一
-- 行""去重保留第一条""tail 原样透传""单/多目标的 owned_by 口径"在这份桩上仍然可观测。
local entry_calls = 0
local function stub_advertise(store_mod, cfg, caps_by_model, alias, tail)
    entry_calls = entry_calls + 1
    return { id = alias, object = "model", created = 0,
             owned_by = (#tail == 1) and ("llm-router->" .. tail[1]) or "llm-router",
             _tail = tail, _store = store_mod, _cfg = cfg, _caps = caps_by_model }
end

local clock = { now = 1000 }
local logged = {}
local env_table = {
    advertise_virtual_entry = stub_advertise,
    json_decode = function(text) return cjson.decode(text) end,
    cjson = cjson,
    type = type, pcall = pcall, pairs = pairs, ipairs = ipairs, next = next,
    tostring = tostring, tonumber = tonumber, rawget = rawget, select = select,
    string = string, table = table, math = math, os = os, io = io, require = require,
    setmetatable = setmetatable,
    -- 纯 luajit 下 ngx 这个全局压根不存在，所以这里的 WARN 用常量而不是 ngx.WARN
    -- （openresty 的 NGX_LOG_WARN 就是 4）；日志捕获做成表，用例只判「有没有写过」。
    ngx = {
        WARN = 4,
        now = function() return clock.now end,
        log = function(_, ...) logged[#logged + 1] = { ... } end,
    },
}
local factory = assert(load(blk
    .. "\nreturn models_advertise", "models-advertise", "t", env_table))
local MA = factory()
if type(MA) ~= "table" then
    print("FAIL: the sliced block did not yield models_advertise")
    os.exit(1)
end

local fails, checks = 0, 0
local function check(name, cond, extra)
    checks = checks + 1
    if cond then
        print("  ok   " .. name)
    else
        fails = fails + 1
        print("  FAIL " .. name .. (extra and (" -> " .. tostring(extra)) or ""))
    end
end

-- 一个可控的 config_store 替身：env 层与磁盘层都由测试说了算。
local fake_env, disk_path = {}, nil
local function store_stub()
    return {
        env = function(name) return fake_env[name] end,
        virtual_models_list = function() return store_stub.rows or {} end,
    }
end
local function reset_state()
    fake_env, disk_path, logged, entry_calls = {}, nil, {}, 0
    clock.now = 1000
    -- 缓存字段是表状态：不清的话上一条用例的读数会污染下一条（这正是 ttl 的意义，
    -- 所以 G4 单独测它，其余用例每组先把它复位）。
    MA.at, MA.on = 0, false
end
local TMPD = "/tmp/lr-models-adv-" .. tostring(os.time())
local function write_disk(text)
    local path = TMPD .. "-cfg.json"
    local f = io.open(path, "wb")
    if f then f:write(text); f:close() end
    disk_path = path
end
local function store_with_disk()
    local store = store_stub()
    store.env = function(name)
        if name == "LMR_CONFIG_FILE" then return disk_path end
        return fake_env[name]
    end
    return store
end

print("=== G1 truthy：认识才算开，不认识一律关 ===")
-- 判别性：把 truthy 写成 return v ~= "false" 的「非假即真」，下面每一条垃圾值都会红。
-- 真值判定会先 trim 再 lower（实现里的 match("^%s*(.-)%s*$"):lower()），所以带空白或
-- 大小写混排的同名档位**都**算开：这两条钉的就是"操作员手抖多打个空格"不会被静默吞掉。
local ON = { true, "true", "TRUE", "  true  ", "1", "1 ", " yes ", "yes", "YES", "on",
             "On", "\ton" }
for i = 1, #ON do
    check("G1 truthy 认识 " .. tostring(ON[i]), MA.truthy(ON[i]) == true, tostring(ON[i]))
end
local OFF = { false, "false", "FALSE", "0", "off", "no", "", "   ", "not-a-bool",
              "ture", "0 ", nil, 0, 1, {}, {} }
for i = 1, #OFF do
    check("G1 truthy 不认识 " .. tostring(OFF[i]), MA.truthy(OFF[i]) == false,
          tostring(OFF[i]))
end
check("G1 truthy 的返回一定是布尔而不是 nil/假值",
      (function()
          for i = 1, #ON do if MA.truthy(ON[i]) ~= true then return false end end
          for i = 1, #OFF do if MA.truthy(OFF[i]) ~= false then return false end
          end
          return true
      end)(), "非布尔返回")

print("=== G2 磁盘层：nil（没说）与 false（说了要关）分家 ===")
reset_state()
-- 没有 LMR_CONFIG_FILE = 「他没说」，必须是 nil 而不是 false，否则 env 层永远读不到。
check("G2 没有配置文件时磁盘答 nil（不是 false）",
      MA.from_disk(store_stub()) == nil, tostring(MA.from_disk(store_stub())))
reset_state(); write_disk("")
check("G2 空文件答 nil（读不出东西 ≠ 说了要关）", MA.from_disk(store_with_disk()) == nil)
reset_state(); write_disk("this is not json")
check("G2 坏 JSON 答 nil（磁盘层的垃圾不该翻掉老契约）",
      MA.from_disk(store_with_disk()) == nil)
reset_state(); write_disk('{"models_virtual_only": null}')
check("G2 键写成 null 答 nil（JSON null 与 Lua nil 分家）",
      MA.from_disk(store_with_disk()) == nil)
reset_state(); write_disk('{"upstreams": []}')
check("G2 键缺失答 nil", MA.from_disk(store_with_disk()) == nil)
reset_state(); write_disk('{"models_virtual_only": false}')
check("G2 键写 false 答 false（这是结论，不是沉默）",
      MA.from_disk(store_with_disk()) == false)
reset_state(); write_disk('{"models_virtual_only": true}')
check("G2 键写 true 答 true", MA.from_disk(store_with_disk()) == true)
reset_state(); write_disk('{"models_virtual_only": "yes"}')
check("G2 键写 \"yes\" 答 true（与 env 层同一族真值判定）",
      MA.from_disk(store_with_disk()) == true)
reset_state(); write_disk('{"models_virtual_only": "off"}')
check("G2 键写 \"off\" 答 false", MA.from_disk(store_with_disk()) == false)

print("=== G3 两层优先级：磁盘压过 env，而不是 OR ===")
-- 判别性：把 enabled 写成 from_disk() or from_env() 那种 OR，下面第一条立刻红。
reset_state(); write_disk('{"models_virtual_only": false}')
fake_env[MA.env_key] = "true"
check("G3 磁盘 false + env true -> 关（磁盘说『要全量』压过 env）",
      MA.enabled(store_with_disk()) == false)
reset_state(); write_disk('{"models_virtual_only": true}')
fake_env[MA.env_key] = "false"
check("G3 磁盘 true + env false -> 开（同一条纪律的反向）",
      MA.enabled(store_with_disk()) == true)
reset_state()
fake_env[MA.env_key] = "true"
check("G3 磁盘没说 + env true -> 开（沉默让给下一层）",
      MA.enabled(store_with_disk()) == true)
reset_state(); write_disk('{"models_virtual_only": null}')
fake_env[MA.env_key] = "true"
check("G3 磁盘写 null（没说）+ env true -> 开", MA.enabled(store_with_disk()) == true)
reset_state(); write_disk('{"models_virtual_only": true}')
check("G3 只磁盘 true、env 缺席 -> 开", MA.enabled(store_with_disk()) == true)
reset_state(); fake_env["LMR_MODELS_VIRTUAL_ONLY"] = "1"
check("G3 只 env 层认 1 这一档", MA.enabled(store_stub()) == true)
reset_state()
check("G3 两层都没说过 -> 关（= 改动前的缺省行为）", MA.enabled(store_with_disk()) == false)
check("G3 store 整个缺席时 env 兜底仍走 os.getenv 而不崩",
      (function()
          local ok = pcall(MA.enabled, nil)
          return ok
      end)(), "enabled(nil) 抛错")

print("=== G4 缓存：只在有毫秒时钟时启用，TTL 后必须换新值 ===")
-- 这条钉的是「改了配置文件却看不出变化」这个反直觉形状：缓存窗口内复用读数是有意的
-- （与 config_store 的 SNAPSHOT_TTL 同档），窗口外必须重读磁盘。
reset_state(); write_disk('{"models_virtual_only": false}')
local store = store_with_disk()
check("G4 第一次读取得关", MA.enabled(store) == false)
write_disk('{"models_virtual_only": true}')
check("G4 TTL 内仍是缓存的关（缓存确实在生效）", MA.enabled(store) == false)
clock.now = clock.now + (MA.ttl_s or 0.5) + 1
check("G4 越过 TTL 后读到新的开", MA.enabled(store) == true)
check("G4 ttl_s 与 config_store 同档（0.5 s 量级，别写成永久缓存）",
      type(MA.ttl_s) == "number" and MA.ttl_s > 0 and MA.ttl_s <= 5, tostring(MA.ttl_s))
-- 没有毫秒时钟时不许缓存：那是「操作员改了配置却看不到」的 bug 形状。
do
    local saved = env_table.ngx.now
    env_table.ngx = { WARN = 4, log = function() end }
    local no_clock = assert(load(blk .. "\nreturn models_advertise", "adv-no-clock", "t",
        env_table))()
    no_clock.at, no_clock.on = 0, false
    local st = store_with_disk()
    local first = no_clock.enabled(st)
    write_disk('{"models_virtual_only": ' .. (first and "false" or "true") .. '}')
    check("G4 无 ngx.now 时不缓存：改了磁盘立刻可见", no_clock.enabled(st) ~= first,
          "first=" .. tostring(first))
    env_table.ngx.now = saved
end

print("=== G5 only_data：拿不到入口答 nil，不是空表 ===")
-- 判别性的首要一条：nil = 调用方退回全量广告；{} = 对外交出空 data[]（等于让客户端以为
-- 服务消失了）。把这条写成 return {} 是本节最危险的写错，HTTP 面上与「全量」几乎无差。
local store_rows = {}
local function store_with_rows(rows)
    local s = store_stub()
    s.virtual_models_list = function() return rows end
    return s
end
reset_state()
check("G5 store 缺席 -> nil", MA.only_data(nil, {}, {}) == nil)
reset_state()
local no_reader = store_stub()
no_reader.virtual_models_list = nil
check("G5 store 没有 virtual_models_list -> nil", MA.only_data(no_reader, {}, {}) == nil)
reset_state()
check("G5 一条入口都没有 -> nil（而不是 {}）",
      MA.only_data(store_with_rows({}), {}, {}) == nil)
do
    local boom = store_stub()
    boom.virtual_models_list = function() error("reader blew up") end
    check("G5 reader 抛错 -> nil（pcall 兜住，不能把 /v1/models 一起拖崩）",
          MA.only_data(boom, {}, {}) == nil)
    local junk = store_stub()
    junk.virtual_models_list = function() return "not a table" end
    check("G5 reader 返回非表 -> nil", MA.only_data(junk, {}, {}) == nil)
end
reset_state()
local rows = { { "vm-b", "beta" }, { "vm-a", "alpha", "beta" } }
local data = MA.only_data(store_with_rows(rows), { k = 1 }, { caps = 2 })
check("G5 每个入口一行，条数等于入口数", type(data) == "table" and #data == 2,
      type(data) == "table" and tostring(#data) or "nil")
check("G5 按 id 排序（对外字节稳定，客户端可对比）",
      data ~= nil and data[1].id == "vm-a" and data[2].id == "vm-b",
      data and (tostring(data[1].id) .. "," .. tostring(data[2].id)) or "nil")
check("G5 装配入口行时把 store/快照/能力表原样往下传（不自己造数据源）",
      data ~= nil and data[1]._cfg ~= nil and data[1]._caps ~= nil and data[1]._store ~= nil)
check("G5 组内目标按 tail 透传（多目标入口不许退化成单目标）",
      data ~= nil and data[1]._tail ~= nil and #data[1]._tail == 2
      and data[1]._tail[1] == "alpha" and data[1]._tail[2] == "beta",
      data and data[1]._tail and table.concat(data[1]._tail, ",") or "nil")
check("G5 单目标入口的 owned_by 老口径不受开关影响",
      data ~= nil and data[2].owned_by == "llm-router->beta",
      data and tostring(data[2].owned_by) or "nil")
check("G5 多目标入口 owned_by == llm-router",
      data ~= nil and data[1].owned_by == "llm-router",
      data and tostring(data[1].owned_by) or "nil")
reset_state()
local dup = { { "vm-dup", "one" }, { "vm-dup", "two" }, { "vm-keep", "three" } }
local d2 = MA.only_data(store_with_rows(dup), {}, {})
check("G5 重复别名去重（同一 id 出两行会打断按 id 建索引的客户端）",
      d2 ~= nil and #d2 == 2, d2 and tostring(#d2) or "nil")
check("G5 去重保留列表里第一条（store 侧按别名排序，哪条在前是确定的）",
      d2 ~= nil and d2[1]._tail[1] == "one", d2 and d2[1]._tail[1] or "nil")
reset_state()
local junk_rows = { "not-a-row", { nil }, { "" }, { 7 }, {} }
check("G5 全是无效行 -> nil（不是空表，调用方仍退回全量）",
      MA.only_data(store_with_rows(junk_rows), {}, {}) == nil)
reset_state()
-- 名字遮蔽：关掉真实那一半之后遮蔽规则已无对手，所以配几条入口就出几条。
local shadow = { { "shared-name", "alpha" } }
local d3 = MA.only_data(store_with_rows(shadow), {}, {})
check("G5 入口名与真实模型同名时照样广告（遮蔽判定已随真实那一半一起失效）",
      d3 ~= nil and #d3 == 1 and d3[1].id == "shared-name",
      d3 and tostring(#d3) or "nil")
reset_state()
-- 回归守卫（两版都该绿）：only_data 不许读 env/磁盘以外的东西，也不许留跨请求状态。
local before = entry_calls
MA.only_data(store_with_rows({ { "x", "alpha" } }), {}, {})
check("G5 only_data 每次都重新装配（不吃跨请求缓存）", entry_calls > before,
      before .. " -> " .. entry_calls)

print("=== G6 常量与契约：开关只有一处读者 ===")
reset_state()
check("G6 磁盘键名钉住 models_virtual_only", MA.doc_key == "models_virtual_only",
      tostring(MA.doc_key))
check("G6 env 键名钉住 LMR_MODELS_VIRTUAL_ONLY", MA.env_key == "LMR_MODELS_VIRTUAL_ONLY",
      tostring(MA.env_key))
check("G6 表里没有第四个可写状态位（跨请求状态只走 shdict 的纪律：这里只允许 at/on 缓存）",
      (function()
          local extra = {}
          for k in pairs(MA) do
              if k ~= "truthy" and k ~= "nullish" and k ~= "from_env" and k ~= "from_disk"
                  and k ~= "enabled" and k ~= "only_data" and k ~= "env_key"
                  and k ~= "doc_key" and k ~= "ttl_s" and k ~= "on" and k ~= "at" then
                  extra[#extra + 1] = tostring(k)
              end
          end
          return #extra == 0, table.concat(extra, ",")
      end)())

print(("\n%s %d checks, %d failed"):format(fails == 0 and "PASS:" or "FAIL:", checks, fails))
if fails > 0 then os.exit(1) end
os.exit(0)
