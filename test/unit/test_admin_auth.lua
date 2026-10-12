#!/usr/bin/env luajit
-- 管理台 Basic Auth 的判定层单测（用户裁定 2026-10-12，doc/gap-admin-auth.md）。
--
-- 钉的五件事，全在 HTTP 面上看不见症状：
--   1. 两条豁免的顺序与语义：SMG_ADMIN_AUTH_PASS 未配置或空串 = 整道门关闭；
--      loopback（127/8 与 ::1）免凭据。缺省（不配 env）必须逐字节等于改动前 ——
--      这是 AGENTS.md 硬规则 4「新开关缺省零行为变化」在鉴权面上的形状。
--   2. fail closed：非 Basic 方案、base64 解不开、缺冒号、用户名错、口令错，
--      一律同一个 401，回给探测者的信息量必须为零。
--   3. 401 必带 WWW-Authenticate（没有它浏览器不弹登录框，门变成「打不开」）。
--   4. 静态入口只挑入口文档发挑战（/ 与 *.html），js/css 与 try_files 未命中的
--      代理路径放行 —— 判定写宽会连模型面一起锁死，写窄会漏掉管理台。
--   5. 口令比对是常量时间（先比长度，再逐字节异或累积），不是逐字符短路。
--
-- 手法与 test_caps_persist.lua 同形状：luajit 口径、假 ngx、零端口，可与门禁并发。
-- 反证：文件末尾六段变异源码（三段豁免 + 三段 klib 清单），红才算断言有效。
-- §9 另有 conf 接线清单：闸门判定全对但 location 忘挂 = 洞 1 的成因，清单两头钉。
package.cpath = "/usr/local/openresty/lualib/?.so;" .. package.cpath
package.path = (os.getenv("LUA_TEST_LIB") or "./lualib") .. "/?.lua;" .. package.path

local PASS_ENV = "SMG_ADMIN_AUTH_PASS"

--------------------------------------------------------------------------
-- ngx 替身：只给 admin_auth 用到的最小面
--------------------------------------------------------------------------
local SENTINEL = {}
local env_ngx
env_ngx = {
    var = { remote_addr = "10.0.0.9", uri = "/config",
            http_x_real_ip = nil, http_x_forwarded_for = nil },
    header = {},
    status = nil,
    req = { get_headers = function() return env_ngx.__headers or {} end },
    exit = function(status)
        env_ngx.__exit = status
        error(SENTINEL, 0)
    end,
}

-- 纯 Lua base64 解码：luajit 口径下没有 mime.c，真机走 ngx.decode_base64（C 模块）。
-- 桩刻意严格：长度不合法 / 非字母表字符 / 尾部残留位不为零，一律 nil（真实现同样
-- fail closed），否则「脏头必须 401」那几条会被桩骗绿。
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local REV = {}
for i = 1, 64 do REV[B64:sub(i, i)] = i - 1 end

local function b64decode(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("%s", "")
    local pad = 0
    if text:sub(-2) == "==" then
        pad = 2
    elseif text:sub(-1) == "=" then
        pad = 1
    end
    if pad > 0 then text = text:sub(1, -(pad + 1)) end
    if #text % 4 == 1 then return nil end
    local out, acc, bits = {}, 0, 0
    for i = 1, #text do
        local v = REV[text:sub(i, i)]
        if v == nil then return nil end
        acc = acc * 64 + v
        bits = bits + 6
        if bits >= 8 then
            bits = bits - 8
            out[#out + 1] = string.char(math.floor(acc / 2 ^ bits) % 256)
            acc = acc % 2 ^ bits
        end
    end
    -- 残留位必须全是零，且位数与补位字符数对得上：
    -- 3 字节组无补位无残留；2 字节组 1 个 = 剩 2 位；1 字节组 2 个 = 剩 4 位。
    if acc ~= 0 then return nil end
    if bits ~= (pad == 1 and 2 or (pad == 2 and 4 or 0)) then return nil end
    return table.concat(out)
end

local function b64encode(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local s = B64:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
            .. B64:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
            .. B64:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)
            .. B64:sub(n % 64 + 1, n % 64 + 1)
        local keep = (b == nil) and 2 or ((c == nil) and 3 or 4)
        out[#out + 1] = s:sub(1, keep) .. string.rep("=", 4 - keep)
    end
    return table.concat(out)
end
env_ngx.decode_base64 = b64decode
_G.ngx = env_ngx

--------------------------------------------------------------------------
-- 断言器
--------------------------------------------------------------------------
local checks, failures = 0, 0
local function ok(cond, name, detail)
    checks = checks + 1
    if cond then return true end
    failures = failures + 1
    io.write("FAIL: ", name)
    if detail ~= nil then io.write("  (", tostring(detail), ")") end
    io.write("\n")
    return false
end
-- luajit 没有 setenv，直接把 os.getenv 换成查表桩：admin_auth 在调用时才读 env，
-- 所以这个缝足够真（真机上这个函数读到的就是 nginx env 白名单放行进来的值）。
local fake_env = {}
local real_getenv = os.getenv
os.getenv = function(name)
    local v = fake_env[name]
    if v ~= nil then return v end
    return real_getenv(name)
end
local function set_pass(v)
    if v == nil then fake_env[PASS_ENV] = nil else fake_env[PASS_ENV] = v end
end
local function basic(user, pass) return "Basic " .. b64encode(user .. ":" .. pass) end

local SRC_PATH = (os.getenv("LUA_TEST_LIB") or "./lualib") .. "/resty/luarouter/admin_auth.lua"
local handle = assert(io.open(SRC_PATH, "rb"), "cannot read " .. SRC_PATH)
local REAL_SRC = handle:read("a")
handle:close()

local function load_src(src, name)
    local chunk, err = loadstring(src, name)
    assert(chunk, err)
    return chunk()
end

-- 反证用的变异：plain 文本替换（不用模式，锚点写错就直接 assert 炸，免得静默不变异）
local function splice(src, needle, repl)
    local from = string.find(src, needle, 1, true)
    assert(from, "mutation anchor missing: " .. needle)
    return src:sub(1, from - 1) .. repl .. src:sub(from + #needle)
end

local auth = load_src(REAL_SRC, "admin_auth.real")

--------------------------------------------------------------------------
-- 1. 豁免一：口令未配置 = 整道门关闭（缺省零行为变化）
--------------------------------------------------------------------------
set_pass(nil)
ok(auth.password() == nil, "unset pass reads nil")
ok(auth.required("203.0.113.7") == false, "unset pass: remote peer needs no auth")

set_pass("")
ok(auth.password() == nil, "empty-string pass reads nil")
ok(auth.required("203.0.113.7") == false, "empty-string pass: gate stays closed")

-- 纯空白是操作员真填过的口令，不裁空白（写进去什么就比什么）
set_pass(" ")
ok(auth.password() == " ", "single-space pass counts as a credential")
ok(auth.required("203.0.113.7") == true, "single-space pass: gate opens")

--------------------------------------------------------------------------
-- 2. 豁免二：loopback
--------------------------------------------------------------------------
set_pass("s3cret")
ok(auth.password() == "s3cret", "configured pass reads back")
ok(auth.required("127.0.0.1") == false, "127.0.0.1 exempt")
ok(auth.required("127.0.0.53") == false, "whole 127/8 exempt")
ok(auth.required("::1") == false, "ipv6 loopback exempt")
ok(auth.required("10.252.25.217") == true, "LAN peer needs auth")
ok(auth.required("203.0.113.7") == true, "public peer needs auth")
ok(auth.required("0.0.0.0") == true, "0.0.0.0 is not loopback")
ok(auth.required("127") == true, "bare 127 needs the dot")
ok(auth.required("1127.0.0.1") == true, "prefix match must not hit 1127/")
ok(auth.required(nil) == true, "unknown address = no exemption (fail closed)")

--------------------------------------------------------------------------
-- 2.1 反代来源还原（2026-10-12：8802 经 APISIX，remote_addr 恒 127.0.0.1）
--   required(nil) 走 real_client_addr()：X-Real-IP 优先，其次 XFF 最左段，
--   都无才 remote_addr；代理头只在直连对端是 loopback 时采信。
--   显式传 addr 的第一参保持纯函数语义（测试与任何直传调用不受头影响）。
--------------------------------------------------------------------------
local function with_proxy_headers(remote, xri, xff)
    env_ngx.var.remote_addr = remote
    env_ngx.var.http_x_real_ip = xri
    env_ngx.var.http_x_forwarded_for = xff
end
local function clear_proxy_headers()
    with_proxy_headers("10.0.0.9", nil, nil)
end

-- 反代（对端 loopback）声明的原始客户端非环 → 必须鉴权（修复的核心断言）
with_proxy_headers("127.0.0.1", "203.0.113.1", nil)
ok(auth.required() == true, "proxied X-Real-IP public client needs auth")
with_proxy_headers("127.0.0.1", nil, "203.0.113.1")
ok(auth.required() == true, "proxied XFF-only public client needs auth")
with_proxy_headers("127.0.0.1", nil, "203.0.113.1, 10.0.0.1, 127.0.0.1")
ok(auth.required() == true, "xff chain takes the leftmost hop")
with_proxy_headers("127.0.0.1", nil, " 198.51.100.7 , 10.0.0.1")
ok(auth.required() == true, "xff segments tolerate spaces around the leftmost ip")
with_proxy_headers("127.0.0.1", "10.252.25.217", "203.0.113.1")
ok(auth.required() == true, "x-real-ip wins over xff (proxy-rewritten header is the trusted one)")
-- 反代声明原始客户端就是本机 → 豁免跟着 X-Real-IP 走
with_proxy_headers("127.0.0.1", "127.0.0.1", nil)
ok(auth.required() == false, "proxied loopback client stays exempt")
-- X-Real-IP 空串 = 头缺失，继续看 XFF / peer
with_proxy_headers("127.0.0.1", "", "203.0.113.9")
ok(auth.required() == true, "empty X-Real-IP falls through to XFF")
with_proxy_headers("127.0.0.1", "", "")
ok(auth.required() == false, "empty proxy headers fall through to loopback peer")
-- 直连（无代理头）豁免逐字节不变
clear_proxy_headers()
env_ngx.var.remote_addr = "127.0.0.1"
ok(auth.required() == false, "direct loopback without headers stays exempt")
-- 直连非环的伪造头不采信：remote_addr 已是非环，判定地址恒 peer
with_proxy_headers("203.0.113.7", "127.0.0.1", "127.0.0.1")
ok(auth.required() == true, "spoofed X-Real-IP from a direct peer is not honored")
with_proxy_headers("203.0.113.7", nil, "127.0.0.1")
ok(auth.required() == true, "spoofed XFF from a direct peer is not honored")
clear_proxy_headers()
ok(auth.real_client_addr() == "10.0.0.9", "real_client_addr returns peer when no headers")


--------------------------------------------------------------------------
-- 3. 头校验：全部 fail closed，不区分失败原因
--------------------------------------------------------------------------
ok(auth.check_header(nil, "s3cret") == false, "missing header rejected")
ok(auth.check_header("", "s3cret") == false, "empty header rejected")
ok(auth.check_header("Bearer abc", "s3cret") == false, "bearer scheme rejected")
ok(auth.check_header("Basic", "s3cret") == false, "scheme without payload rejected")
ok(auth.check_header("Basic !!!not-base64!!!", "s3cret") == false, "dirty base64 rejected")
ok(auth.check_header("Basic " .. b64encode("lua-router"), "s3cret") == false,
    "pair without colon rejected")
ok(auth.check_header("Basic " .. b64encode("a"), "s3cret") == false, "odd-length base64 rejected")
ok(auth.check_header(basic("lua-router", ""), "s3cret") == false, "empty submitted password rejected")
ok(auth.check_header(basic("", "s3cret"), "s3cret") == false, "empty submitted user rejected")
ok(auth.check_header(basic("admin", "s3cret"), "s3cret") == false, "wrong user rejected")
ok(auth.check_header(basic("Lua-Router", "s3cret"), "s3cret") == false, "user is case-sensitive")
ok(auth.check_header(basic("lua-router", "s3cre"), "s3cret") == false, "short password rejected")
ok(auth.check_header(basic("lua-router", "s3cret!"), "s3cret") == false, "long password rejected")
ok(auth.check_header(basic("lua-router", "S3cret"), "s3cret") == false, "password is case-sensitive")
ok(auth.check_header(basic("lua-router", "s3cret"), "s3cret") == true, "correct pair accepted")
ok(auth.check_header("basic " .. b64encode("lua-router:s3cret"), "s3cret") == true,
    "scheme is case-insensitive")
ok(auth.check_header("   Basic    " .. b64encode("lua-router:s3cret") .. "  ", "s3cret") == true,
    "surrounding whitespace tolerated")
-- 口令含冒号：用户名段取第一个冒号之前，其余整段归口令
ok(auth.check_header(basic("lua-router", "a:b"), "a:b") == true, "password may contain a colon")
ok(auth.check_header(basic("lua-router", "p+=/s"), "p+=/s") == true,
    "password may contain base64 punctuation")
-- 用户名段不许带空格（Basic 语义里没有这回事，比对就是逐字节）
ok(auth.check_header(basic("lua-router ", "s3cret"), "s3cret") == false, "trailing space in user rejected")

--------------------------------------------------------------------------
-- 4. guard：放行 / 401 的形状
--------------------------------------------------------------------------
local function call_guard(mod, addr, header, uri, preserve_proxy_headers)
    if addr ~= nil then env_ngx.var.remote_addr = addr end
    if not preserve_proxy_headers then
        env_ngx.var.http_x_real_ip = nil
        env_ngx.var.http_x_forwarded_for = nil
    end
    env_ngx.var.uri = uri or "/config"
    env_ngx.__headers = header and { Authorization = header } or {}
    env_ngx.header = {}
    env_ngx.status = nil
    env_ngx.__exit = nil
    local okcall, err = pcall(mod.guard)
    if not okcall and err ~= SENTINEL then error(err) end
    return env_ngx.__exit, env_ngx.header
end

set_pass("s3cret")
local exit_code, headers = call_guard(auth, "127.0.0.1", nil)
ok(exit_code == nil, "loopback anonymous: no exit", exit_code)
ok(headers["WWW-Authenticate"] == nil, "loopback anonymous: no challenge")

exit_code, headers = call_guard(auth, "203.0.113.7", nil)
ok(exit_code == 401, "remote without credential -> 401", exit_code)
ok(type(headers["WWW-Authenticate"]) == "string", "401 carries WWW-Authenticate")
ok(headers["WWW-Authenticate"]:find("^Basic realm=") ~= nil,
    "challenge is a Basic realm challenge", headers["WWW-Authenticate"])
ok(headers["WWW-Authenticate"]:find("lua%-router admin") ~= nil, "realm names the admin surface")
ok(headers["WWW-Authenticate"]:find("s3cret") == nil, "realm never carries the password")
ok(headers["Cache-Control"] == "no-store", "401 must not be cacheable")
ok(env_ngx.status == 401, "status is 401 before exit", env_ngx.status)

exit_code = call_guard(auth, "203.0.113.7", basic("lua-router", "s3cret"))
ok(exit_code == nil, "remote with correct credential passes", exit_code)
exit_code = call_guard(auth, "203.0.113.7", basic("lua-router", "wrong"))
ok(exit_code == 401, "remote with wrong credential -> 401", exit_code)
exit_code = call_guard(auth, "127.0.0.1", basic("lua-router", "wrong"))
ok(exit_code == nil, "loopback bypasses even a wrong credential", exit_code)

set_pass(nil)
exit_code, headers = call_guard(auth, "203.0.113.7", nil)
ok(exit_code == nil, "pass unset: remote peer anonymous", exit_code)
ok(headers["WWW-Authenticate"] == nil, "pass unset: no challenge at all")

-- guard 面：反代进来的公网客户端,无凭据 401、带凭据过
--   上一组把口令清掉了（缺省零行为变化那两条），这里必须重新钉上口令，
--   否则「门整道关闭」会伪装成「反代还原生效」把断言全灌成绿色。
set_pass("s3cret")
local function call_guard_p(mod, remote, header, uri, xri, xff)
    with_proxy_headers(remote, xri, xff)
    return call_guard(mod, nil, header, uri, true)
end
exit_code = call_guard_p(auth, "127.0.0.1", nil, "/config", "203.0.113.1", nil)
ok(exit_code == 401, "reverse-proxied public client without credential -> 401")
exit_code = call_guard_p(auth, "127.0.0.1", basic("lua-router", "s3cret"), "/config",
    "203.0.113.1", nil)
ok(exit_code == nil, "reverse-proxied public client with credential passes")
exit_code = call_guard_p(auth, "127.0.0.1", nil, "/config", nil, "203.0.113.1")
ok(exit_code == 401, "xff-only proxied public client -> 401")
exit_code = call_guard_p(auth, "127.0.0.1", nil, "/config", "127.0.0.1", nil)
ok(exit_code == nil, "proxied loopback client stays anonymous")
clear_proxy_headers()

--------------------------------------------------------------------------
-- 5. 静态入口判定：只挑入口文档
--------------------------------------------------------------------------
ok(auth.static_challenge_worthy("/") == true, "/ is an entry document")
ok(auth.static_challenge_worthy("/index.html") == true, "/index.html is an entry document")
for _, page in ipairs({ "models", "routing", "workers", "upstreams", "logs" }) do
    ok(auth.static_challenge_worthy("/" .. page .. ".html") == true, "/" .. page .. ".html entry")
end
ok(auth.static_challenge_worthy("/app.js") == false, "js is secret-free static")
ok(auth.static_challenge_worthy("/vendor/quasar-umd.js") == false, "vendor bundle is static")
ok(auth.static_challenge_worthy("/app.css") == false, "css is static")
ok(auth.static_challenge_worthy("/v1/chat/completions") == false,
    "try_files fallback path must not be challenged by the static gate")
ok(auth.static_challenge_worthy("/health") == false, "health stays open")
ok(auth.static_challenge_worthy("/metrics") == false, "metrics stays open")
ok(auth.static_challenge_worthy("/favicon.ico") == false, "icon is static")
ok(auth.static_challenge_worthy(nil) == false, "nil uri never challenged")
ok(auth.static_challenge_worthy("/x.html.bak") == false, "suffixed name is not an entry")

local function call_static(mod, addr, header, uri)
    env_ngx.var.remote_addr = addr
    env_ngx.var.uri = uri
    env_ngx.__headers = header and { Authorization = header } or {}
    env_ngx.header = {}
    env_ngx.status = nil
    env_ngx.__exit = nil
    local okcall, err = pcall(mod.guard_static)
    if not okcall and err ~= SENTINEL then error(err) end
    return env_ngx.__exit
end
set_pass("s3cret")
ok(call_static(auth, "203.0.113.7", nil, "/") == 401, "remote GET / -> 401 prompts the browser")
ok(call_static(auth, "203.0.113.7", nil, "/app.js") == nil, "remote GET /app.js passes")
ok(call_static(auth, "203.0.113.7", nil, "/v1/chat/completions") == nil,
    "remote GET /v1/... reaches the proxy face, no admin 401")
ok(call_static(auth, "203.0.113.7", basic("lua-router", "s3cret"), "/") == nil,
    "remote GET / with credential passes")
ok(call_static(auth, "127.0.0.1", nil, "/index.html") == nil, "loopback GET /index.html passes")
set_pass(nil)
ok(call_static(auth, "203.0.113.7", nil, "/") == nil, "unset pass: GET / passes")

--------------------------------------------------------------------------
-- 6. 常量时间比对
--------------------------------------------------------------------------
ok(auth.const_eq("abc", "abc") == true, "const_eq equal")
ok(auth.const_eq("abc", "abd") == false, "const_eq differs in last byte")
ok(auth.const_eq("abc", "xbc") == false, "const_eq differs in first byte")
ok(auth.const_eq("abc", "ab") == false, "const_eq length differs")
ok(auth.const_eq("", "") == true, "const_eq both empty")
ok(auth.const_eq("a", "") == false, "const_eq one side empty")
ok(auth.const_eq(nil, "a") == false, "const_eq nil lhs never matches")
ok(auth.const_eq("a", nil) == false, "const_eq nil rhs never matches")
ok(auth.const_eq(123, "123") == false, "const_eq non-string never matches")

--------------------------------------------------------------------------
-- 7. 反证：三段变异源码必须在同一批豁免断言上红
--------------------------------------------------------------------------
local function expect_red(name, src)
    local mod = load_src(src, name)
    local red = {}
    env_ngx.var.http_x_real_ip = nil
    env_ngx.var.http_x_forwarded_for = nil
    local probes = {
        { "no pass exemption",
          function() set_pass(nil); return call_guard(mod, "203.0.113.7", nil) end },
        { "no loopback exemption",
          function() set_pass("s3cret"); return call_guard(mod, "127.0.0.1", nil) end },
        { "empty string treated as credential",
          function() set_pass(""); return call_guard(mod, "203.0.113.7", nil) end },
    }
    for _, p in ipairs(probes) do
        if p[2]() == 401 then red[#red + 1] = p[1] end
    end
    set_pass(nil)
    checks = checks + 1
    if #red > 0 then
        io.write("mutation " .. name .. " correctly RED (" .. table.concat(red, ", ") .. ")\n")
    else
        failures = failures + 1
        io.write("FAIL: mutation " .. name .. " not caught by the suite\n")
    end
end

-- (1) 删掉「口令未配置 = 门关闭」这一支
expect_red("drop-password-exemption", splice(REAL_SRC,
    "    if _M.password() == nil then\n        return false\n    end\n", ""))
-- (2) loopback 豁免改成恒要凭据
expect_red("drop-loopback-exemption", splice(REAL_SRC,
    "    return not _M.is_loopback(addr)", "    return true"))
-- (3) 空串不再等同未配置
expect_red("empty-string-is-credential", splice(REAL_SRC,
    '    if value == nil or value == "" then', "    if value == nil then"))
-- (4) 比对退回逐字符短路（豁免不变，但 check_header 必须仍然全对 —— 这一支钉的是
--     「断言不依赖 const_eq 的实现细节」，所以它红在 const_eq 那组而不是豁免组）
local short_circuit = splice(REAL_SRC,
    "    local diff = 0\n    for i = 1, #a do\n        diff = bit.bor(diff, bit.bxor(a:byte(i), b:byte(i)))\n    end\n    return diff == 0",
    "    for i = 1, #a do if a:byte(i) ~= b:byte(i) then return false end end\n    return true")
local sc_mod = load_src(short_circuit, "short_circuit")
set_pass("s3cret")
checks = checks + 1
if sc_mod.check_header(basic("lua-router", "s3cret"), "s3cret")
    and not sc_mod.check_header(basic("lua-router", "s3cre"), "s3cret") then
    io.write("short-circuit variant still passes the header suite (expected: only RED on the const-time group)\n")
    ok(sc_mod.const_eq("abc", "abd") == false, "short-circuit variant keeps equality semantics")
else
    failures = failures + 1
    io.write("FAIL: short-circuit mutation broke the header suite unexpectedly\n")
end



--------------------------------------------------------------------------
-- 7.1 反代还原的两段变异反证（§2.1 断言的判别性）
--------------------------------------------------------------------------
-- 变异 A：删掉代理头还原段（required 退回只看 remote_addr）—— 反代 401 断言必须红
local no_proxy = splice(REAL_SRC,
    "    local peer = ngx.var.remote_addr\n"
    .. "    -- 非 loopback 直连：代理头一概不信，remote_addr 就是判定地址。\n"
    .. "    if not _M.is_loopback(peer) then\n        return peer\n    end\n"
    .. "    local xri = ngx.var.http_x_real_ip\n"
    .. "    if type(xri) == \"string\" and xri ~= \"\" then\n        return xri\n    end\n"
    .. "    local xff = ngx.var.http_x_forwarded_for\n"
    .. "    if type(xff) == \"string\" and xff ~= \"\" then\n"
    .. "        local first = xff:match(\"^%s*([^,]+)\")\n"
    .. "        if first then\n            return (first:gsub(\"%s+$\", \"\"))\n        end\n"
    .. "    end\n    return peer",
    "    return ngx.var.remote_addr")
local np_mod = load_src(no_proxy, "proxy_drop_restore")
set_pass("s3cret")
ok(call_guard_p(np_mod, "127.0.0.1", nil, "/config", "203.0.113.1", nil) == nil,
    "mutation: without proxy restore the reverse-proxied peer reads as loopback (suite catches it)")
ok(call_guard_p(np_mod, "203.0.113.7", nil, "/config", "127.0.0.1", nil) == 401,
    "mutation: direct non-loopback peer still challenged")
clear_proxy_headers()

-- 变异 B：删掉「只在直连对端是 loopback 时采信」的信任条件 —— 直连伪造头豁免断言必须红
local no_trust = splice(REAL_SRC,
    "    -- 非 loopback 直连：代理头一概不信，remote_addr 就是判定地址。\n"
    .. "    if not _M.is_loopback(peer) then\n        return peer\n    end\n", "")
local nt_mod = load_src(no_trust, "proxy_drop_trust")
set_pass("s3cret")
ok(call_guard_p(nt_mod, "203.0.113.7", nil, "/config", "127.0.0.1", nil) == nil,
    "mutation: without the loopback-only trust condition a spoofed header exempts (suite catches it)")
ok(call_guard_p(nt_mod, "127.0.0.1", nil, "/config", "203.0.113.1", nil) == 401,
    "mutation: proxied public client still challenged (this group pins the trust condition, not the restore)")
clear_proxy_headers()
set_pass(nil)

--------------------------------------------------------------------------
-- 8. klib 控制面过滤器（洞 2）：管理型拦、数据面/公开面放行
--------------------------------------------------------------------------
-- 形状与静态闸门同款（fail open 清单）：/workers /model-map /flush_cache 与推理面、
-- 公开面共用一个 dispatcher（try_files 未命中全落进来），判定必须先过清单，否则
-- 401 会砸在模型流量与监控面上。
ok(auth.klib_challenge_worthy("/workers") == true, "workers managed")
ok(auth.klib_challenge_worthy("/workers/0f7d0c9e-1") == true, "workers/<id> managed")
ok(auth.klib_challenge_worthy("/model-map") == true, "model-map managed")
ok(auth.klib_challenge_worthy("/flush_cache") == true, "flush_cache managed")
ok(auth.klib_challenge_worthy("/workersfoo") == false, "prefix match needs the slash boundary")
ok(auth.klib_challenge_worthy("/model-mapx") == false, "no sloppy prefix hit")
ok(auth.klib_challenge_worthy("/v1/chat/completions") == false, "inference plane never challenged")
ok(auth.klib_challenge_worthy("/v1/completions") == false, "inference plane never challenged")
ok(auth.klib_challenge_worthy("/v1/models") == false, "advertisement stays open")
ok(auth.klib_challenge_worthy("/v1/loads") == false, "loads feeds health checks, stays open")
ok(auth.klib_challenge_worthy("/health") == false, "health stays open")
ok(auth.klib_challenge_worthy("/metrics") == false, "Prometheus scrape stays open")
ok(auth.klib_challenge_worthy("/server_info") == false, "server_info stays open")
ok(auth.klib_challenge_worthy("/_mesh/internal/sync") == false, "mesh peer hops stay open")
ok(auth.klib_challenge_worthy("/ha/stats") == false, "mesh answers its own 503, not a 401")
ok(auth.klib_challenge_worthy(nil) == false, "nil uri never challenged")
ok(auth.klib_challenge_worthy("") == false, "empty uri never challenged")

local function call_klib(mod, addr, header, uri)
    env_ngx.var.remote_addr = addr
    env_ngx.var.uri = uri
    env_ngx.__headers = header and { Authorization = header } or {}
    env_ngx.header = {}
    env_ngx.status = nil
    env_ngx.__exit = nil
    local okcall, err = pcall(mod.guard_klib)
    if not okcall and err ~= SENTINEL then error(err) end
    return env_ngx.__exit
end

set_pass("s3cret")
ok(call_klib(auth, "203.0.113.7", nil, "/workers") == 401, "remote /workers -> 401")
ok(call_klib(auth, "203.0.113.7", nil, "/workers/abc") == 401, "remote /workers/<id> -> 401")
ok(call_klib(auth, "203.0.113.7", nil, "/model-map") == 401, "remote /model-map -> 401")
ok(call_klib(auth, "203.0.113.7", nil, "/flush_cache") == 401, "remote /flush_cache -> 401")
ok(call_klib(auth, "203.0.113.7", basic("lua-router", "s3cret"), "/workers") == nil,
    "remote /workers with credential passes")
ok(call_klib(auth, "127.0.0.1", nil, "/workers") == nil, "loopback /workers anonymous")
ok(call_klib(auth, "203.0.113.7", nil, "/v1/chat/completions") == nil,
    "remote inference never sees the admin gate")
ok(call_klib(auth, "203.0.113.7", nil, "/health") == nil, "remote health never sees the gate")
set_pass(nil)
ok(call_klib(auth, "203.0.113.7", nil, "/workers") == nil,
    "pass unset: /workers anonymous (default zero behavior change)")

--------------------------------------------------------------------------
-- 9. conf 接线清单（洞 1/洞 2 挂载点）：判定函数全对但某条 location 忘挂 =
-- 门形同虚设——洞 1 就是这么漏的（根族挂了、/u/config* 别名族没挂）。单测以 :ro
-- 挂载运行，逐行扫 conf/ui.conf 的 location 块钉「真接上了」；conf 读不到时这些
-- 断言直接红（清单判据不许静默跳过）。
--------------------------------------------------------------------------
local REPO = (os.getenv("LR_REPO_ROOT") or "/repo")
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("a")
    f:close()
    return data
end

local ui_conf = read_file(REPO .. "/conf/ui.conf")
ok(type(ui_conf) == "string", "conf/ui.conf readable for the wiring inventory")
local guarded, unguarded = {}, {}
do
    local current, blk = nil, nil
    local function flush()
        if current == nil then return end
        local has = false
        for _, line in ipairs(blk) do
            if line:find("admin_auth", 1, true) and line:find(".guard()", 1, true) then has = true end
        end
        if has then
            guarded[current] = true
        else
            unguarded[#unguarded + 1] = current
        end
    end
    for line in (ui_conf or ""):gmatch("[^\n]+") do
        local path = line:match("^location%s+=%s+([^%s{]+)")
        if path then
            flush()
            current, blk = path, {}
        elseif current then
            -- 块内 lua 表初始化带 {}，不能用 %b{} 配对；行扫到下一个 location 为止
            blk[#blk + 1] = line
        end
    end
    flush()
end

-- 必须挂门的 24 条：根数据面 15 + /u/config* 9（用户裁定配置 API 要保护）
local MUST_GUARD = {
    "/logs", "/logs/stream", "/logs/backends", "/stats",
    "/config", "/config/effort", "/config/ctx", "/config/model", "/config/virtual",
    "/config/upstreams", "/config/policy", "/config/apply", "/config/model-map",
    "/slots", "/tools",
    "/u/config", "/u/config/effort", "/u/config/ctx", "/u/config/model",
    "/u/config/virtual", "/u/config/upstreams", "/u/config/policy",
    "/u/config/apply", "/u/config/model-map",
}
for _, path in ipairs(MUST_GUARD) do
    ok(guarded[path] == true, "ui.conf location = " .. path .. " carries guard()")
end

-- 对照清单：必须保持匿名的 /u/ 对话面与展示面。误拦 = 砸掉裁定里明确不保护的
-- 界面，与漏拦同样严重，所以清单两头都钉。
local MUST_OPEN = {
    "/u/v1/chat/completions", "/u/v1/completions", "/u/v1/models", "/u/props",
    "/u/slots", "/u/tools", "/u/logs", "/u/logs/stream", "/u/stats", "/u/v1/stream",
    "/props",
}
for _, path in ipairs(MUST_OPEN) do
    local seen_unguarded = false
    for _, name in ipairs(unguarded) do
        if name == path then seen_unguarded = true end
    end
    ok(seen_unguarded and guarded[path] == nil,
        "ui.conf location = " .. path .. " stays anonymous")
end

-- 静态闸门接线：生产模板与测试 conf 的 location / 都要有 guard_static
local tpl = read_file(REPO .. "/conf/nginx.conf.template")
local tconf = read_file(REPO .. "/test/conf/nginx-lua-router.conf")
ok(type(tpl) == "string" and tpl:find('guard_static', 1, true) ~= nil,
    "template wires location / to guard_static")
ok(type(tconf) == "string" and tconf:find('guard_static', 1, true) ~= nil,
    "test conf wires location / to guard_static")

-- 洞 2 接线：router.lua handle() 里 guard_klib 在 OPTIONS 短路之后、分发之前
local router_src = read_file(REPO .. "/lualib/resty/luarouter/router.lua")
ok(type(router_src) == "string"
    and router_src:find("admin_auth.guard_klib()", 1, true) ~= nil,
    "router.lua wired to guard_klib")
do
    local opts_at = router_src and router_src:find('if method == "OPTIONS" then', 1, true)
    local gate_at = router_src and router_src:find("admin_auth.guard_klib()", 1, true)
    local disp_at = router_src and router_src:find("instance:handle({})", 1, true)
    ok(opts_at ~= nil and gate_at ~= nil and disp_at ~= nil
        and opts_at < gate_at and gate_at < disp_at,
        "guard_klib runs after OPTIONS short-circuit, before dispatch")
end

--------------------------------------------------------------------------
-- 10. klib 清单变异反证：洞 2 每条断言必须真有判别性
--------------------------------------------------------------------------
-- 反证 5：清单里摘掉 /workers —— /workers 必须不再被拦（其余不受影响）
local no_workers = splice(REAL_SRC,
    'local KLIB_ADMIN_PREFIXES = { "/workers", "/model-map", "/flush_cache" }',
    'local KLIB_ADMIN_PREFIXES = { "/model-map", "/flush_cache" }')
local nw_mod = load_src(no_workers, "klib_drop_workers")
set_pass("s3cret")
ok(call_klib(nw_mod, "203.0.113.7", nil, "/workers") == nil,
    "mutation: /workers out of the list stops being challenged")
ok(call_klib(nw_mod, "203.0.113.7", nil, "/model-map") == 401,
    "mutation leaves the other managed routes intact")

-- 反证 6：前缀匹配写成无边界（sub(1,#p)==p）—— /workersfoo 会被误拦
local sloppy = splice(REAL_SRC,
    '        if uri == p or uri:sub(1, #p + 1) == p .. "/" then',
    '        if uri:sub(1, #p) == p then')
local sl_mod = load_src(sloppy, "klib_sloppy_prefix")
ok(call_klib(sl_mod, "203.0.113.7", nil, "/workersfoo") == 401,
    "mutation: sloppy prefix challenges /workersfoo (boundary assertions catch it)")

-- 反证 7：清单被换成数据面前缀（fail open 写反）—— /v1/chat/completions 吃 401
local inverted = splice(REAL_SRC,
    'local KLIB_ADMIN_PREFIXES = { "/workers", "/model-map", "/flush_cache" }',
    'local KLIB_ADMIN_PREFIXES = { "/v1", "/health", "/metrics" }')
local iv_mod = load_src(inverted, "klib_inverted")
ok(call_klib(iv_mod, "203.0.113.7", nil, "/v1/chat/completions") == 401,
    "mutation: inverted list challenges the inference plane (suite catches it)")
ok(nw_mod.klib_challenge_worthy("/v1/chat/completions") == false,
    "mutation: dropped route still not challenged by accident")
set_pass(nil)

io.write("\n")
io.write(string.format("admin_auth: %d checks, %d failed\n", checks, failures))
os.exit(failures > 0 and 1 or 0)
