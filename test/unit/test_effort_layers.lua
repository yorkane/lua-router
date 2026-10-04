#!/usr/bin/env luajit
-- effort 三层继承（模型卡片 -> 虚拟条目 -> 全局）的**判别**单测：纯 luajit，不绑端口、
-- 不起容器，因此可与 host 网络的门禁并发（AGENTS.md 硬规则 1）。
--
-- 为什么需要这一份：1e57618 换掉了 config_store.request_effort_for 的查表口径（「有卡片就
-- 整层走卡片，卡片没这条映射直接透传」→ **逐 from 问三层**，第一个给了值的层赢），
-- 030dab5 才把条目层接进转发链（apply_effort_policy 里把 profile_entry_fallback 作第三参
-- 传给 request_effort_for）。两个提交各自只留了 /data/tmp 下的一次性探针，仓里没有任何
-- 东西钉住这组语义；而这条链的错误形状恰好是**静默**的——操作员在全局页填的映射被一张
-- 只管 ctx 的卡片悄悄屏蔽，转发体只是少改一个键，没有任何日志会喊。
--
-- 手法沿用 test_caps_routing / test_models_shape：按锚点把 router.lua 的**真实现**切出来
-- 配桩加载（set_top_field 那一族 + profile_effort_value / profile_entry_fallback +
-- apply_effort_policy），config_store 用盘上的**真模块**。语义（store 的三层查表）与接线
-- （router 把条目层读数喂给 store）因此都跑在盘上那两份代码上。
--
-- 判别性纪律（两条腿，同一组断言、三份 lualib）：
--   LR_EFFORT_LEGACY_LUALIB=<1e57618 之前的整棵 lualib>
--       → G2 / G3 / G6 / G7 / G10 必须红：这四组就是本次要修的行为，
--         外加 G1b / G3b 两条「条目层压过全局」的成对判据。
--   LR_EFFORT_LEGACY_LUALIB=<新 config_store + 030dab5 之前的 router>
--       → 只剩条目层不参与（G2 / G6 / G8 那几条红）：证明红是**接线**造成的，
--         不是断言只测了 config_store 那半边。
--   标注「守卫」的条目（G1 / G4 / G5 / G7b / G9 / G11）在两份旧实现上都该绿——它们钉的是
--   「缺省零行为变化」与既有优先级没被推翻，绿在旧版正是应有的样子。
--
-- 运行：
--   docker run --rm -v "$PWD":/repo:ro -w /repo -e LUA_TEST_LIB=/repo/lualib \
--     --entrypoint /usr/local/openresty/luajit/bin/luajit authz:latest \
--     test/unit/test_effort_layers.lua
-- 旧实现对照（判别性通道，见上面的两条腿）：再加
--     -v <旧树目录>:/legacy:ro -e LR_EFFORT_LEGACY_LUALIB=/legacy/lualib

local lib = os.getenv("LUA_TEST_LIB") or "./lualib"
local legacy_lib = os.getenv("LR_EFFORT_LEGACY_LUALIB")
local LEGACY = type(legacy_lib) == "string" and legacy_lib ~= ""
if LEGACY then lib = legacy_lib end

package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath
package.path = lib .. "/?.lua;" .. package.path

local cjson = require "cjson.safe"
local NULL = cjson.null

--------------------------------------------------------------------------
-- 1. 切 router.lua 的真实现（三块；锚点用导出语句/注释边界，不用相邻函数名）
--------------------------------------------------------------------------
local fh = io.open(lib .. "/resty/luarouter/router.lua")
local src = fh and fh:read("*a")
if type(src) ~= "string" then
    print("FAIL: cannot read router.lua from " .. lib)
    os.exit(1)
end

local function between(a_marker, b_marker)
    local a = src:find(a_marker, 1, true)
    local b = src:find(b_marker, a or 1, true)
    if not a or not b then return nil end
    return src:sub(a, b - 1)
end

-- 顶层精确改写那一族（field_pattern / skip_string / value_end / top_member_span / set_top_field）。
local blk_edits = between("local function field_pattern(field)", "_M.set_top_field = set_top_field")
-- 条目层装配（profile_effort_value 恒 nil 的 legacy 缝 + 新实现才有的 profile_entry_fallback）。
local blk_profile = between("---Effective per-profile effort.",
                            "-- ------------------------------------------------------------------ raw JSON edits")
-- 转发链上的 effort 决策（本次接线的落点）。
local blk_apply = between("apply_effort_policy = function(",
                          "---The output budget the gateway forwards")
if type(blk_edits) ~= "string" or type(blk_profile) ~= "string" or type(blk_apply) ~= "string" then
    print("FAIL: source blocks not extracted (" .. tostring(blk_edits ~= nil) .. ","
        .. tostring(blk_profile ~= nil) .. "," .. tostring(blk_apply ~= nil) .. ")")
    os.exit(1)
end

-- 两个 profile helper 在原文件里是「前向声明 + 后置赋值」的局部。chunk 里同样先声明再赋值：
-- 旧实现不给 profile_entry_fallback 赋值，它保持 nil，而旧版的 apply_effort_policy 本来也
-- 不调用它——那正是「接线前」的形状（不是本探针伪造的）。
local chunk_src = "local profile_effort_value, profile_entry_fallback\n"
    .. blk_edits .. "\n" .. blk_profile .. "\n" .. blk_apply .. "\n"
    .. "return { apply_effort_policy = apply_effort_policy,\n"
    .. "  profile_entry_fallback = profile_entry_fallback, set_top_field = set_top_field }"

--------------------------------------------------------------------------
-- 2. ngx 替身：只实现 config_store / router 真正调到的那几个 PCRE 模式，
--    逐个显式映射；未映射的记下来在末尾断言（否则替身在骗人）。
--------------------------------------------------------------------------
-- 键必须是普通字符串（Lua 里长字符串不能当表键，`[[...]] = v` 是语法错误），
-- 值是被替换成的 Lua 模式。
local RE_GSUB = {
    ["^\\s+"] = "^%s+",
    ["\\s+$"] = "%s+$",
    ["^\\s*\\{"] = "^%s*{",
    ["^\\s*\\}\\s*$"] = "^%s*}%s*$",
}
local RE_FIND = {
    ["^\\d+$"] = "^%d+$",
    ["[,;\\n]+"] = "[,;%c]+",
    ["+, ]+"] = "[+, ]+",
    -- set_top_field 的「键原本不存在 → 插成第一个成员」路径问的也是 ngx.re.find。
    -- 漏了它，"补一个缺省档"的用例会静默变成"什么都没改"，那种断言等于没断。
    ["^\\s*\\{"] = "^%s*{",
    ["^\\s*\\}\\s*$"] = "^%s*}%s*$",
}
local unmapped_re = {}

--- field_pattern 产出的 `"name"\s*:` 存在性门（router 的 top_member_span 用它）。
--- 只认这一族形状，别的一律记成未映射。
local function field_gate_to_lua(pattern)
    local name = pattern:match('^"([%w_]+)"')
    if not name then return nil end
    -- 只认 router 自己拼出来的那一种形状，别的一律当未映射。
    if pattern ~= '"' .. name .. '"\\s*:' then return nil end
    return '"' .. name .. '"%s*:'
end

local function new_shdict()
    local data = {}
    return {
        get = function(_, k) return data[k] end,
        set = function(_, k, v) data[k] = tostring(v); return true end,
        incr = function(_, k, delta, init)
            local cur = (tonumber(data[k]) or init or 0) + delta
            data[k] = tostring(cur)
            return cur
        end,
        delete = function(_, k) data[k] = nil end,
        flush_all = function() data = {} end,
    }
end

local shared = { luarouter_config = new_shdict() }

_G.ngx = {
    shared = shared,
    now = function() return os.time() end,
    time = function() return os.time() end,
    log = function() end,
    WARN = 1, ERR = 2, INFO = 3, NOTICE = 4,
    ctx = {},
    header = {},
    status = nil,
    say = nil,
    exit = nil,
    re = {
        gsub = function(subject, pattern, repl, _opts)
            local mapped = RE_GSUB[pattern]
            if not mapped then
                unmapped_re[#unmapped_re + 1] = "gsub " .. tostring(pattern)
                return subject
            end
            local out = subject:gsub(mapped, repl or "")
            if out == subject then return subject end
            return out
        end,
        find = function(subject, pattern, _opts, ctx)
            local mapped = RE_FIND[pattern] or field_gate_to_lua(pattern)
            if not mapped then
                unmapped_re[#unmapped_re + 1] = "find " .. tostring(pattern)
                return nil
            end
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

--------------------------------------------------------------------------
-- 3. config_store（盘上真模块）+ 每条用例一份干净状态
--------------------------------------------------------------------------
local TAG = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
local CONFIG_PATH = "/tmp/lr-effort-" .. TAG .. "-config.json"
local function unlink(path) os.remove(path) end

local store = require "resty.luarouter.config_store"

--- 装配三层配置。全局层与卡片层用 env（与配置页同源：LMR_EFFORT_MAP /
--- LMR_DEFAULT_EFFORT / LMR_MODEL_EFFORT_MAP / LMR_MODEL_CTX / LMR_MODEL_EFFORT），
--- 条目层只能走 config_store 的写入 API（env 里没有条目的 effort 声明位）。
---@param env_map table @ 追加进 LMR_ENV_CACHE 的键
---@param entries table|nil @ apply_virtual_models 的 entries（条目层）
---@param cards table|nil @ {model = patch} 走 apply_model_config（卡片 default_effort 没有 env 层）
local function setup(env_map, entries, cards)
    shared.luarouter_config:flush_all()
    unlink(CONFIG_PATH)
    _G.ngx.ctx = {}
    store._reset_pool_module_caches()
    local cache = { LMR_CONFIG_FILE = CONFIG_PATH }
    for k, v in pairs(env_map or {}) do cache[k] = v end
    _G.LMR_ENV_CACHE = cache
    for model, card in pairs(cards or {}) do
        local body = { model = model }
        for k, v in pairs(card) do body[k] = v end
        local _, err = store.apply_model_config(body)
        if err then error("apply_model_config(" .. model .. "): " .. tostring(err)) end
    end
    if entries then
        local _, err = store.apply_virtual_models(entries)
        if err then error("apply_virtual_models: " .. tostring(err)) end
    end
end

--------------------------------------------------------------------------
-- 4. router 侧的 chunk（配桩：store() 返回盘上那份 config_store）
--------------------------------------------------------------------------
local sandbox = {
    ngx = _G.ngx,
    cjson = cjson,
    json_encode = cjson.encode,
    store = function() return store end,
}
setmetatable(sandbox, { __index = _G })
local compiled = load(chunk_src, "effort_layers", "t", sandbox)
if not compiled then
    print("FAIL: extracted source did not compile")
    os.exit(1)
end
local R = compiled()

--- 一条转发体：顶层 reasoning_effort 可给可不给。**嵌套**同名成员、把档位名写进 stop
--- 数组、以及 "tools": [] 都刻意留在原位，用来盯「只改该改的那个字节」。
local function raw_body(opts)
    opts = opts or {}
    local head = '{"model":"' .. (opts.requested_name or "eff-alias")
        .. '","messages":[{"role":"user","content":{"reasoning_effort":"nested-keep"}}]'
        .. ',"tools":[]'
    local tail = ',"stop":["reasoning_effort"],"temperature":0.5}'
    if opts.effort == nil then
        return head .. tail
    end
    return head .. ',"reasoning_effort":' .. cjson.encode(opts.effort) .. tail
end

--- 走一遍转发链：返回（转发体字节, 解码后的转发体, requested, effective）。
local function forward(raw, model, alias, profile)
    local body = cjson.decode(raw)
    local out, requested, effective = R.apply_effort_policy(raw, body, model, profile, alias)
    return out, cjson.decode(out), requested, effective
end

--------------------------------------------------------------------------
-- 断言框架
--------------------------------------------------------------------------
local checks, fails = 0, 0
local function check(name, cond, detail)
    checks = checks + 1
    if not cond then
        fails = fails + 1
        print("FAIL " .. name .. (detail ~= nil and ("   | " .. tostring(detail)) or ""))
    end
end
--- 判转发体里的 reasoning_effort。want = nil 判的是**键缺席**（而不是等于某个值）。
local function eq_effort(out_raw, out, want, name)
    local got = rawget(out or {}, "reasoning_effort")
    if want == nil then
        check(name, got == nil, "reasoning_effort 在场 = " .. tostring(got) .. " / " .. tostring(out_raw))
    else
        check(name, got == want,
            "got " .. tostring(got) .. " want " .. tostring(want) .. " / " .. tostring(out_raw))
    end
end

local MODEL = "effmod"
local ALIAS = "eff-alias"
--- 字节纪律：顶层那一个键之外，一个字节都不许多改（硬规则 4 的转发纪律）。
local function intact(out_raw)
    return out_raw:find('"reasoning_effort":"nested-keep"', 1, true) ~= nil
        and out_raw:find('"tools":[]', 1, true) ~= nil
        and out_raw:find('"stop":["reasoning_effort"]', 1, true) ~= nil
end

print("=== 模式: " .. (LEGACY and "LEGACY（" .. lib .. "）" or "HEAD（盘上实现）") .. " ===")

--------------------------------------------------------------------------
-- G1 三层齐全、同一个 from：卡片赢。【守卫】落点引擎自己说的话压过入口与全局；
--    旧实现同样走卡片这一支，所以它在旧版也绿 —— 它守的是新实现内部的优先级。
--------------------------------------------------------------------------
setup({
    LMR_EFFORT_MAP = "high:high",
    LMR_MODEL_EFFORT_MAP = MODEL .. ":high>low",
}, {
    { model = ALIAS, target = MODEL, effort_map = { { from = "high", to = "medium" } } },
})
do
    local raw = raw_body({ effort = "high" })
    local out_raw, out, requested, effective = forward(raw, MODEL, ALIAS, nil)
    eq_effort(out_raw, out, "low", "G1 三层都写了 high：卡片赢（既不是条目的 medium 也不是全局的 high）")
    check("G1 只改写顶层那一个键（嵌套同名字节 / stop 数组 / tools 空数组原位不动）",
        intact(out_raw), out_raw)
    check("G1 日志口径：requested 是客户端原话 high，effective 是转发值 low",
        requested == "high" and effective == "low",
        tostring(requested) .. " / " .. tostring(effective))
end

--------------------------------------------------------------------------
-- G1b 卡片存在但没写 low 这条 from：条目压过全局。
--    【判据·config_store 腿】旧实现「有卡片就整层走卡片」→ 透传 low。
--------------------------------------------------------------------------
setup({
    LMR_EFFORT_MAP = "low:max",
    LMR_MODEL_EFFORT_MAP = MODEL .. ":high>low",
}, {
    { model = ALIAS, target = MODEL, effort_map = { { from = "low", to = "minimal" } } },
})
do
    local raw = raw_body({ effort = "low" })
    local out_raw, out = forward(raw, MODEL, ALIAS, nil)
    eq_effort(out_raw, out, "minimal",
        "G1b 卡片只管 high：请求点名 low 时必须继续问条目→全局，条目的 low>minimal 赢（旧实现在这里透传 low）")
end

--------------------------------------------------------------------------
-- G2【判据·两条腿都红 / 本次要修的第一个 bug】卡片存在但**没有这条 from** → 落到上层。
--    旧实现：卡片分支里 `card.effort_map[level]` 查不到就 `return level` 透传，条目与全局
--    的 high>medium 永远问不到；未接线的 router 同样不把条目层交给 store。
--------------------------------------------------------------------------
setup({
    LMR_MODEL_EFFORT_MAP = MODEL .. ":medium>low",
}, {
    { model = ALIAS, target = MODEL, effort_map = { { from = "high", to = "medium" } } },
})
do
    local raw = raw_body({ effort = "high" })
    local out_raw, out = forward(raw, MODEL, ALIAS, nil)
    eq_effort(out_raw, out, "medium",
        "G2 卡片只声明了 medium>low，请求点名 high：必须落到条目层的 high>medium")
    check("G2 转发体仍是顶层精确改写的字节（嵌套同名 / stop / tools 原位）", intact(out_raw), out_raw)
end
-- 成对的反向断言：同一份配置里卡片自己声明过的那条 from 仍然卡片赢，排除「整层跳过卡片」这种修过头。
do
    local raw = raw_body({ effort = "medium" })
    local out_raw, out = forward(raw, MODEL, ALIAS, nil)
    eq_effort(out_raw, out, "low", "G2 卡片声明过的 from 不受影响（没有被整层跳过）")
end

--------------------------------------------------------------------------
-- G3【判据·config_store 腿】卡片与条目都没有这条 from → 落到全局。
--    操作员在全局页填的 high>minimal 此前对任何配了卡片的模型永远不生效。
--------------------------------------------------------------------------
setup({
    LMR_EFFORT_MAP = "high:minimal",
    LMR_MODEL_EFFORT_MAP = MODEL .. ":medium>low",
}, {
    { model = ALIAS, target = MODEL, effort_map = { { from = "low", to = "xhigh" } } },
})
do
    local raw = raw_body({ effort = "high" })
    local out_raw, out = forward(raw, MODEL, ALIAS, nil)
    eq_effort(out_raw, out, "minimal",
        "G3 卡片与条目都没写 high：全局的 high>minimal 必须生效（旧实现在这里透传 high）")
end
-- G3b【判据·两条腿都红】条目层写过的 from 压过全局（顺序仍是卡片→条目→全局）。
do
    local raw = raw_body({ effort = "low" })
    local out_raw, out = forward(raw, MODEL, ALIAS, nil)
    eq_effort(out_raw, out, "xhigh",
        "G3b 条目写过的 low>xhigh 压过全局（卡片没这条 from 时按 条目→全局 问下去）")
end

--------------------------------------------------------------------------
-- G4【守卫】三层全空且请求没点名 → 网关一个字节都不改，转发体**不带** reasoning_effort 键。
--    断言判的是「键缺席」而不是「等于某个值」，再加一条逐字节相同：任何替客户端造档位的
--    实现（包括日后有人把缺省档硬编成 none）都会红。
--------------------------------------------------------------------------
setup({ LMR_MODEL_CTX = MODEL .. ":8192", LMR_MODEL_TOOL_USE = MODEL .. "=false" }, nil)
do
    local raw = raw_body()
    local out_raw, out = forward(raw, MODEL, ALIAS, nil)
    eq_effort(out_raw, out, nil, "G4 三层全空 + 没点名：转发体里没有 reasoning_effort 这个键")
    -- 出现次数与请求原文相同 = 顶层没多出一个键（嵌套的成员名与 stop 数组的元素名各一次）。
    -- 只判"值不等于某个数"会被 null / 空串冒充骗过，所以这里数键名。
    local function count(subject, needle)
        local n, pos = 0, 1
        while true do
            local at = subject:find(needle, pos, true)
            if not at then return n end
            n = n + 1
            pos = at + #needle
        end
    end
    check("G4 顶层没多出键名：出现次数与请求原文相同（嵌套与 stop 各留一次）",
        count(out_raw, '"reasoning_effort"') == count(raw, '"reasoning_effort"')
        and count(out_raw, "null") == 0, out_raw)
    check("G4 转发体逐字节等于原请求", out_raw == raw, out_raw)
end

--------------------------------------------------------------------------
-- G5【守卫 / 接线纪律】条目层完全没声明时，转发字节必须与「没有条目层这一说」时逐字相同
--    （AGENTS.md「新开关缺省零行为变化」；030dab5 提交信息里那条「9 条字节相同」的仓内版本）。
--    期望写成**死的字节串**：一条恒真的「和上次一样」在这里不算断言。
--------------------------------------------------------------------------
setup({
    LMR_DEFAULT_EFFORT = "medium",
    LMR_EFFORT_MAP = "high:low",
}, {
    -- 条目只声明 target，一个 effort 位都没有。
    { model = ALIAS, target = MODEL },
})
do
    -- 钉死字节：点名过的档位**原位替换**，没点名的补成第一个顶层成员（set_top_field 的两条
    -- 支路）。写成死的字符串而不是从实现推出来，否则实现写错时断言跟着一起错。
    local PREF = '{"model":"eff-alias","messages":[{"role":"user","content":'
        .. '{"reasoning_effort":"nested-keep"}}],"tools":[],'
    local SUF = '"stop":["reasoning_effort"],"temperature":0.5}'
    local cases = {
        { effort = "high", want = PREF .. '"reasoning_effort":"low",' .. SUF },
        { effort = "low", want = PREF .. '"reasoning_effort":"low",' .. SUF },
        { effort = "medium", want = PREF .. '"reasoning_effort":"medium",' .. SUF },
        { effort = "ultra", want = PREF .. '"reasoning_effort":"ultra",' .. SUF },
        { effort = nil, want = '{"reasoning_effort":"medium",' .. PREF:sub(2) .. SUF },
    }
    for i = 1, #cases do
        local raw = raw_body({ effort = cases[i].effort })
        local out_raw = forward(raw, MODEL, ALIAS, nil)
        check("G5 条目层未声明：转发字节逐字相同（case " .. i .. "）",
            out_raw == cases[i].want, "got " .. out_raw .. "\n      want " .. cases[i].want)
    end
end

--------------------------------------------------------------------------
-- G6【判据·两条腿都红 / 本次要修的第二个 bug】卡片存在但没声明缺省档 → 必须让位条目层。
--    旧实现卡片分支查不到 default_effort 就 `return cfg.default_effort`，条目整个被跳过。
--------------------------------------------------------------------------
setup({
    LMR_DEFAULT_EFFORT = "low",
    LMR_MODEL_EFFORT_MAP = MODEL .. ":high>minimal",
}, {
    { model = ALIAS, target = MODEL, default_effort = "xhigh" },
})
do
    local raw = raw_body()
    local out_raw, out = forward(raw, MODEL, ALIAS, nil)
    eq_effort(out_raw, out, "xhigh",
        "G6 卡片存在却没声明缺省档：条目的 default_effort 必须压过全局的 low（旧实现在这里给 low）")
end
-- 卡片自己声明了缺省档 → 仍然卡片赢（条目让位）。
setup({
    LMR_DEFAULT_EFFORT = "low",
}, {
    { model = ALIAS, target = MODEL, default_effort = "xhigh" },
}, {
    [MODEL] = { default_effort = "none" },
})
do
    local raw = raw_body()
    local out_raw, out = forward(raw, MODEL, ALIAS, nil)
    eq_effort(out_raw, out, "none", "G6 卡片声明了缺省档时卡片优先（条目让位）")
end

--------------------------------------------------------------------------
-- G7【判据·config_store 腿】卡片在场时，未知档位仍算「点了名但没人规定改写」→ 原样透传。
--    旧实现有卡片时把未命中的档位拉去填 cfg.default_effort：卡片在场与否改变了语义。
--------------------------------------------------------------------------
setup({
    LMR_DEFAULT_EFFORT = "medium",
    LMR_MODEL_EFFORT_MAP = MODEL .. ":medium>low",
}, nil)
do
    local raw = raw_body({ effort = "turbo" })
    local out_raw, out = forward(raw, MODEL, ALIAS, nil)
    eq_effort(out_raw, out, "turbo",
        "G7 有卡片 + 请求点名未知档位：原样透传 turbo，不拿缺省档覆盖客户端亲口写的值（旧实现在这里给 medium）")
end
do
    -- 「客户端没说话」的三种写法走缺省档那一支。【守卫】
    for _, spelled in ipairs({ "", "null", "default" }) do
        local raw = raw_body({ effort = spelled })
        local out_raw, out = forward(raw, MODEL, ALIAS, nil)
        eq_effort(out_raw, out, "medium", "G7 客户端写 '" .. spelled .. "' 算没说话 → 用缺省档 medium")
    end
end

--------------------------------------------------------------------------
-- G8【判据·接线腿】请求直接点名真实模型（没有入口别名）时条目层不参与，
--    卡片与全局两层照旧；别名命中时条目层参与。同一份配置两个方向都判，
--    缺任何一层接线都会红。
--------------------------------------------------------------------------
setup({
    LMR_MODEL_EFFORT_MAP = MODEL .. ":minimal>low",
}, {
    { model = ALIAS, target = MODEL, effort_map = { { from = "high", to = "max" } } },
})
do
    local raw_direct = raw_body({ effort = "high", requested_name = MODEL })
    local out_raw, out = forward(raw_direct, MODEL, MODEL, nil)
    eq_effort(out_raw, out, "high",
        "G8 直接请求真实模型名（别名不在场）：条目层的 high>max 不得漏进来")
    local raw_alias = raw_body({ effort = "high" })
    local out_raw2, out2 = forward(raw_alias, MODEL, ALIAS, nil)
    eq_effort(out_raw2, out2, "max", "G8 走入口名：条目层参与改写")
    local out_raw3, out3 = forward(raw_body({ effort = "minimal" }), MODEL, ALIAS, nil)
    eq_effort(out_raw3, out3, "low", "G8 卡片声明过的 from 仍压过条目（同一份配置）")
end

--------------------------------------------------------------------------
-- G9【守卫】model_effort 强制层（LMR_MODEL_EFFORT）位置不变，仍在三层之上。
--------------------------------------------------------------------------
setup({
    LMR_MODEL_EFFORT = MODEL .. ":max",
    LMR_MODEL_EFFORT_MAP = MODEL .. ":high>low",
}, {
    { model = ALIAS, target = MODEL, effort_map = { { from = "high", to = "medium" } } },
})
do
    local raw = raw_body({ effort = "high" })
    local out_raw, out = forward(raw, MODEL, ALIAS, nil)
    eq_effort(out_raw, out, "max", "G9 强制行压过卡片/条目/全局三层")
end

--------------------------------------------------------------------------
-- G10【判据·接线腿】条目层的装配形状：只把档位两个字段交给 store，能力位不得漏进转发链。
--    未接线的 router 没有 profile_entry_fallback，第二条判据即红。
--------------------------------------------------------------------------
do
    setup({ LMR_MODEL_CTX = MODEL .. ":8192" }, { { model = ALIAS, target = MODEL } })
    check("G10 条目没声明任何 effort 位 → 装配交 nil（不是空表）",
        R.profile_entry_fallback == nil
        or R.profile_entry_fallback(nil, ALIAS, MODEL) == nil,
        cjson.encode((R.profile_entry_fallback or function() return "MISSING" end)(nil, ALIAS, MODEL) or NULL))
    setup({ LMR_MODEL_CTX = MODEL .. ":8192" }, {
        { model = ALIAS, target = MODEL, effort_map = { { from = "high", to = "low" } } },
    })
    local got = R.profile_entry_fallback and R.profile_entry_fallback(nil, ALIAS, MODEL) or nil
    check("G10 条目声明了 effort_map → 装配出那一层的读数（store 的第三参形状）",
        type(got) == "table" and type(got.effort_map) == "table" and got.effort_map.high == "low",
        cjson.encode(got or NULL))
    setup({}, {
        { model = ALIAS, target = MODEL, modalities = { "image" }, supports_tool_use = false },
    })
    local only_caps = R.profile_entry_fallback and R.profile_entry_fallback(nil, ALIAS, MODEL) or nil
    check("G10 条目只声明能力位（无 effort）→ 装配仍是 nil",
        only_caps == nil, cjson.encode(only_caps or NULL))
end

--------------------------------------------------------------------------
-- G11【守卫】未知档位（客户端写了引擎没规定的档位）在任何层在场时都规范化透传，
--    既不猜也不清空；这条同时盯住「三层查表不许把未知档位吞掉」。
--------------------------------------------------------------------------
setup({
    LMR_EFFORT_MAP = "high:minimal",
}, {
    { model = ALIAS, target = MODEL, default_effort = "low" },
})
do
    local raw = raw_body({ effort = " DeepThink " })
    local out_raw, out = forward(raw, MODEL, ALIAS, nil)
    eq_effort(out_raw, out, "deepthink",
        "G11 未知档位算「点了名没人改写」：规范化（trim）后透传，不被缺省档顶掉")
    check("G11 未知档位的改写也只动顶层一个键", intact(out_raw), out_raw)
end

--------------------------------------------------------------------------
-- 收尾：未映射的 ngx.re 模式必须为空，否则上面的替身在骗人。
--------------------------------------------------------------------------
local seen = {}
for _, entry in ipairs(unmapped_re) do
    if not seen[entry] then
        seen[entry] = true
        checks = checks + 1
        fails = fails + 1
        print("FAIL unmapped ngx.re pattern " .. entry)
    end
end

unlink(CONFIG_PATH)
print(string.format("%s%d checks, %d failed", LEGACY and "LEGACY " or "", checks, fails))
os.exit(fails == 0 and 0 or 1)
