#!/usr/bin/env luajit
-- jwks.lua pure-Lua unit tests (JWT decision functions, no ngx / no cosocket).
--   docker run --rm -v "$PWD/lua-router:/r:ro" -w /r authz:latest \
--     /usr/local/openresty/luajit/bin/luajit test/unit/test_jwks.lua
--
-- Verifying an actual signature needs resty.openssl, i.e. the ngx runtime, and is
-- covered end to end by test/integration/e2e_jwt.py. What is tested here is every
-- decision the module makes before and after that call, which is where the
-- security-relevant logic lives: the base64url decoder, the alg whitelist and the
-- confusion guard, claim comparison, role mapping, and the url allowlist.

local root = os.getenv("LUA_TEST_LIB") or "./lualib"
package.path = root .. "/?.lua;" .. package.path

local jwt = require "resty.luarouter.jwks"

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
        actual ~= expect and ("got " .. tostring(actual) .. " want " .. tostring(expect)) or nil)
end

-- base64url --------------------------------------------------------------
-- The decoder is hand-written, so it is checked against known vectors and against
-- the lengths a JWT actually carries (a claims segment is 100+ characters, and a
-- streaming decoder that accumulates bits in a double corrupts the tail there).
eq(jwt.b64url_decode("aGVsbG8"), "hello", "b64 basic")
eq(jwt.b64url_decode("YWJjZA=="), "abcd", "b64 double pad")
eq(jwt.b64url_decode("YWJjZA"), "abcd", "b64 no pad")
eq(jwt.b64url_decode("YWI"), "ab", "b64 two bytes")
eq(jwt.b64url_decode("YQ"), "a", "b64 single byte")
eq(jwt.b64url_decode("_-A"), string.char(255, 224), "b64 url alphabet")
check(jwt.b64url_decode("!!") == nil, "b64 rejects foreign alphabet")
check(jwt.b64url_decode("") == nil, "b64 rejects empty")
check(jwt.b64url_decode("A") == nil, "b64 rejects a lone character")
-- Vectors from Python's base64 (the authoritative alphabet), covering the lengths a
-- JWT segment really has. A hand-written streaming decoder that keeps accumulating
-- bits in a double goes past 2^53 and corrupts the tail on the long ones; decoding
-- four characters at a time cannot.
local vectors = {
    ["Bw"] = "\007",
    ["Bw4"] = "\007\014",
    ["Bw4V"] = "\007\014\021",
    ["Bw4VHA"] = "\007\014\021\028",
    ["Bw4VHCM"] = "\007\014\021\028\035",
    ["Bw4VHCMq"] = "\007\014\021\028\035\042",
    ["Bw4VHCMqMTg_Rk1UW2JpcA"] = "\007\014\021\028\035\042\049\056\063\070\077\084\091\098\105\112",
    ["Bw4VHCMqMTg_Rk1UW2JpcHd-hYyTmqGor7a9xMvS2eDn7vX8AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2k"] = "\007\014\021\028\035\042\049\056\063\070\077\084\091\098\105\112\119\126\133\140\147\154\161\168\175\182\189\196\203\210\217\224\231\238\245\252\003\010\017\024\031\038\045\052\059\066\073\080\087\094\101\108\115\122\129\136\143\150\157\164",
    ["Bw4VHCMqMTg_Rk1UW2JpcHd-hYyTmqGor7a9xMvS2eDn7vX8AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kqw"] = "\007\014\021\028\035\042\049\056\063\070\077\084\091\098\105\112\119\126\133\140\147\154\161\168\175\182\189\196\203\210\217\224\231\238\245\252\003\010\017\024\031\038\045\052\059\066\073\080\087\094\101\108\115\122\129\136\143\150\157\164\171",
    ["Bw4VHCMqMTg_Rk1UW2JpcHd-hYyTmqGor7a9xMvS2eDn7vX8AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5"] = "\007\014\021\028\035\042\049\056\063\070\077\084\091\098\105\112\119\126\133\140\147\154\161\168\175\182\189\196\203\210\217\224\231\238\245\252\003\010\017\024\031\038\045\052\059\066\073\080\087\094\101\108\115\122\129\136\143\150\157\164\171\178\185",
    ["Bw4VHCMqMTg_Rk1UW2JpcHd-hYyTmqGor7a9xMvS2eDn7vX8AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wA"] = "\007\014\021\028\035\042\049\056\063\070\077\084\091\098\105\112\119\126\133\140\147\154\161\168\175\182\189\196\203\210\217\224\231\238\245\252\003\010\017\024\031\038\045\052\059\066\073\080\087\094\101\108\115\122\129\136\143\150\157\164\171\178\185\192",
    ["Bw4VHCMqMTg_Rk1UW2JpcHd-hYyTmqGor7a9xMvS2eDn7vX8AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMc"] = "\007\014\021\028\035\042\049\056\063\070\077\084\091\098\105\112\119\126\133\140\147\154\161\168\175\182\189\196\203\210\217\224\231\238\245\252\003\010\017\024\031\038\045\052\059\066\073\080\087\094\101\108\115\122\129\136\143\150\157\164\171\178\185\192\199",
    ["Bw4VHCMqMTg_Rk1UW2JpcHd-hYyTmqGor7a9xMvS2eDn7vX8AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dzj6vH4_wYNFBsiKTA3PkVMU1phaG92fYSLkpmgp661vA"] = "\007\014\021\028\035\042\049\056\063\070\077\084\091\098\105\112\119\126\133\140\147\154\161\168\175\182\189\196\203\210\217\224\231\238\245\252\003\010\017\024\031\038\045\052\059\066\073\080\087\094\101\108\115\122\129\136\143\150\157\164\171\178\185\192\199\206\213\220\227\234\241\248\255\006\013\020\027\034\041\048\055\062\069\076\083\090\097\104\111\118\125\132\139\146\153\160\167\174\181\188",
    ["Bw4VHCMqMTg_Rk1UW2JpcHd-hYyTmqGor7a9xMvS2eDn7vX8AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dzj6vH4_wYNFBsiKTA3PkVMU1phaG92fYSLkpmgp661vMPK0djf5u30-wIJEBceJSwzOkFIT1ZdZGtyeYA"] = "\007\014\021\028\035\042\049\056\063\070\077\084\091\098\105\112\119\126\133\140\147\154\161\168\175\182\189\196\203\210\217\224\231\238\245\252\003\010\017\024\031\038\045\052\059\066\073\080\087\094\101\108\115\122\129\136\143\150\157\164\171\178\185\192\199\206\213\220\227\234\241\248\255\006\013\020\027\034\041\048\055\062\069\076\083\090\097\104\111\118\125\132\139\146\153\160\167\174\181\188\195\202\209\216\223\230\237\244\251\002\009\016\023\030\037\044\051\058\065\072\079\086\093\100\107\114\121\128",
    ["Bw4VHCMqMTg_Rk1UW2JpcHd-hYyTmqGor7a9xMvS2eDn7vX8AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dzj6vH4_wYNFBsiKTA3PkVMU1phaG92fYSLkpmgp661vMPK0djf5u30-wIJEBceJSwzOkFIT1ZdZGtyeYCH"] = "\007\014\021\028\035\042\049\056\063\070\077\084\091\098\105\112\119\126\133\140\147\154\161\168\175\182\189\196\203\210\217\224\231\238\245\252\003\010\017\024\031\038\045\052\059\066\073\080\087\094\101\108\115\122\129\136\143\150\157\164\171\178\185\192\199\206\213\220\227\234\241\248\255\006\013\020\027\034\041\048\055\062\069\076\083\090\097\104\111\118\125\132\139\146\153\160\167\174\181\188\195\202\209\216\223\230\237\244\251\002\009\016\023\030\037\044\051\058\065\072\079\086\093\100\107\114\121\128\135",
    ["Bw4VHCMqMTg_Rk1UW2JpcHd-hYyTmqGor7a9xMvS2eDn7vX8AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dzj6vH4_wYNFBsiKTA3PkVMU1phaG92fYSLkpmgp661vMPK0djf5u30-wIJEBceJSwzOkFIT1ZdZGtyeYCHjpWco6qxuL_GzdTb4unw9_4FDBMaISgvNj1ES1JZYGdudXyDipGYn6attLvCydDX3uXs8_oBCA8WHSQrMjlAR05VXGNqcXg"] = "\007\014\021\028\035\042\049\056\063\070\077\084\091\098\105\112\119\126\133\140\147\154\161\168\175\182\189\196\203\210\217\224\231\238\245\252\003\010\017\024\031\038\045\052\059\066\073\080\087\094\101\108\115\122\129\136\143\150\157\164\171\178\185\192\199\206\213\220\227\234\241\248\255\006\013\020\027\034\041\048\055\062\069\076\083\090\097\104\111\118\125\132\139\146\153\160\167\174\181\188\195\202\209\216\223\230\237\244\251\002\009\016\023\030\037\044\051\058\065\072\079\086\093\100\107\114\121\128\135\142\149\156\163\170\177\184\191\198\205\212\219\226\233\240\247\254\005\012\019\026\033\040\047\054\061\068\075\082\089\096\103\110\117\124\131\138\145\152\159\166\173\180\187\194\201\208\215\222\229\236\243\250\001\008\015\022\029\036\043\050\057\064\071\078\085\092\099\106\113\120",
    ["Bw4VHCMqMTg_Rk1UW2JpcHd-hYyTmqGor7a9xMvS2eDn7vX8AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dzj6vH4_wYNFBsiKTA3PkVMU1phaG92fYSLkpmgp661vMPK0djf5u30-wIJEBceJSwzOkFIT1ZdZGtyeYCHjpWco6qxuL_GzdTb4unw9_4FDBMaISgvNj1ES1JZYGdudXyDipGYn6attLvCydDX3uXs8_oBCA8WHSQrMjlAR05VXGNqcXh_ho2Um6KpsLe-xczT2uHo7_b9BAsSGSAnLjU8Q0pRWF9mbXR7gomQl56lrLO6wcjP1t3k6_L5"] = "\007\014\021\028\035\042\049\056\063\070\077\084\091\098\105\112\119\126\133\140\147\154\161\168\175\182\189\196\203\210\217\224\231\238\245\252\003\010\017\024\031\038\045\052\059\066\073\080\087\094\101\108\115\122\129\136\143\150\157\164\171\178\185\192\199\206\213\220\227\234\241\248\255\006\013\020\027\034\041\048\055\062\069\076\083\090\097\104\111\118\125\132\139\146\153\160\167\174\181\188\195\202\209\216\223\230\237\244\251\002\009\016\023\030\037\044\051\058\065\072\079\086\093\100\107\114\121\128\135\142\149\156\163\170\177\184\191\198\205\212\219\226\233\240\247\254\005\012\019\026\033\040\047\054\061\068\075\082\089\096\103\110\117\124\131\138\145\152\159\166\173\180\187\194\201\208\215\222\229\236\243\250\001\008\015\022\029\036\043\050\057\064\071\078\085\092\099\106\113\120\127\134\141\148\155\162\169\176\183\190\197\204\211\218\225\232\239\246\253\004\011\018\025\032\039\046\053\060\067\074\081\088\095\102\109\116\123\130\137\144\151\158\165\172\179\186\193\200\207\214\221\228\235\242\249",
    ["Bw4VHCMqMTg_Rk1UW2JpcHd-hYyTmqGor7a9xMvS2eDn7vX8AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dzj6vH4_wYNFBsiKTA3PkVMU1phaG92fYSLkpmgp661vMPK0djf5u30-wIJEBceJSwzOkFIT1ZdZGtyeYCHjpWco6qxuL_GzdTb4unw9_4FDBMaISgvNj1ES1JZYGdudXyDipGYn6attLvCydDX3uXs8_oBCA8WHSQrMjlAR05VXGNqcXh_ho2Um6KpsLe-xczT2uHo7_b9BAsSGSAnLjU8Q0pRWF9mbXR7gomQl56lrLO6wcjP1t3k6_L5AA"] = "\007\014\021\028\035\042\049\056\063\070\077\084\091\098\105\112\119\126\133\140\147\154\161\168\175\182\189\196\203\210\217\224\231\238\245\252\003\010\017\024\031\038\045\052\059\066\073\080\087\094\101\108\115\122\129\136\143\150\157\164\171\178\185\192\199\206\213\220\227\234\241\248\255\006\013\020\027\034\041\048\055\062\069\076\083\090\097\104\111\118\125\132\139\146\153\160\167\174\181\188\195\202\209\216\223\230\237\244\251\002\009\016\023\030\037\044\051\058\065\072\079\086\093\100\107\114\121\128\135\142\149\156\163\170\177\184\191\198\205\212\219\226\233\240\247\254\005\012\019\026\033\040\047\054\061\068\075\082\089\096\103\110\117\124\131\138\145\152\159\166\173\180\187\194\201\208\215\222\229\236\243\250\001\008\015\022\029\036\043\050\057\064\071\078\085\092\099\106\113\120\127\134\141\148\155\162\169\176\183\190\197\204\211\218\225\232\239\246\253\004\011\018\025\032\039\046\053\060\067\074\081\088\095\102\109\116\123\130\137\144\151\158\165\172\179\186\193\200\207\214\221\228\235\242\249\000",
}
local vector_count = 0
for enc_text, want in pairs(vectors) do
    vector_count = vector_count + 1
    eq(jwt.b64url_decode(enc_text), want, "b64 decodes a " .. #want .. "-byte vector exactly")
end
check(vector_count == 18, "the vector table is intact", vector_count)

local seg_obj = jwt.decode_segment("eyJpc3MiOiJodHRwczovL2lkcC5pbnRlcm5hbC5leGFtcGxlIiwiYXVkIjoic21nLWNvbnRyb2wtcGxhbmUiLCJzdWIiOiJzcmUtMSIsImlhdCI6MTcwMDAwMDAwMCwiZXhwIjoxODAwMDAwMDAwLCJyb2xlcyI6WyJvcHMiXX0")
check(type(seg_obj) == "table" and seg_obj.iss == "https://idp.internal.example"
    and seg_obj.exp == 1800000000 and seg_obj.roles[1] == "ops",
    "decode_segment parses a realistic claims segment")

-- token splitting -------------------------------------------------------
local si, h, c, s = jwt.split_token("aaa.bbb.ccc")
eq(si, "aaa.bbb", "split returns the signing input")
eq(h, "aaa", "split header")
eq(c, "bbb", "split claims")
eq(s, "ccc", "split signature")
check(jwt.split_token("aaa.bbb") == nil, "split rejects a two-part token")
check(jwt.split_token("aaa.bbb.ccc.ddd") == nil, "split rejects a four-part token")
check(jwt.split_token("") == nil, "split rejects empty")
check(jwt.split_token(nil) == nil, "split rejects nil")

-- jwk_alg / confusion guard --------------------------------------------
eq(jwt.jwk_alg({ kty = "RSA" }), "RS256", "RSA defaults to RS256")
eq(jwt.jwk_alg({ kty = "EC", crv = "P-256" }), "ES256", "P-256 defaults to ES256")
eq(jwt.jwk_alg({ kty = "EC", crv = "P-384" }), "ES384", "P-384 defaults to ES384")
eq(jwt.jwk_alg({ kty = "EC", crv = "P-521" }), nil, "P-521 unsupported")
eq(jwt.jwk_alg({ kty = "OKP" }), nil, "OKP/EdDSA unsupported")
eq(jwt.jwk_alg({ kty = "oct" }), nil, "oct unsupported")
eq(jwt.jwk_alg({ kty = "RSA", alg = "RS512" }), "RS512", "explicit alg honoured")
eq(jwt.jwk_alg({ kty = "RSA", alg = "HS256" }), nil, "explicit HS256 on an RSA key refused")
eq(jwt.jwk_alg({ kty = "RSA", alg = "none" }), nil, "alg none refused")

-- signature shape pre-checks (no key needed) -----------------------------
local ok_es, err_es = jwt.verify_signature({ kty = "EC" }, "ES256", "x.y", jwt.b64url_decode and "AAAA" or "AAAA")
check(not ok_es and err_es:find("r%|%|s") ~= nil, "a wrong-width ECDSA signature is refused", err_es)
local ok_alg = jwt.verify_signature({ kty = "RSA" }, "HS256", "x.y", "AAA")
check(not ok_alg, "HS256 never reaches a key lookup")

-- claim comparison ------------------------------------------------------
check(jwt.claim_matches("a", "a"), "iss string equal")
check(not jwt.claim_matches("a", "b"), "iss string differs")
check(jwt.claim_matches({ "a", "b" }, "a"), "aud array containing ours matches")
check(not jwt.claim_matches({ "a", "b" }, "c"), "aud array without ours does not match")
check(jwt.claim_matches(nil, "a") == false, "missing claim does not match")
check(jwt.claim_matches("a", nil), "unset expectation matches anything")

-- exp / nbf / iss / aud -------------------------------------------------
local now = 1700000000
local function claims_extra(t)
    local base = { iss = "i", aud = "a", exp = now + 60 }
    for k, v in pairs(t) do base[k] = v end
    return base
end
local opts = { issuer = "i", audience = "a", leeway_secs = 30, now = now }
check(jwt.check_claims(claims_extra({}), opts), "a fresh token passes")
check(jwt.check_claims(claims_extra({ exp = now - 20 }), opts), "exp inside leeway still passes")
eq(select(2, jwt.check_claims(claims_extra({ exp = now - 20 }), opts)), nil, "exp inside leeway reports no error")
check(not jwt.check_claims(claims_extra({ exp = now - 31 }), opts), "exp past leeway refused")
check(not jwt.check_claims({ iss = "i", aud = "a" }, opts), "exp missing refused (Rust requires exp)")
check(not jwt.check_claims(claims_extra({ nbf = now + 31 }), opts), "nbf in the future refused")
check(jwt.check_claims(claims_extra({ nbf = now - 5 }), opts), "past nbf passes")
check(not jwt.check_claims(claims_extra({ iss = "other" }), opts), "wrong iss refused")
check(not jwt.check_claims(claims_extra({ aud = "other" }), opts), "wrong aud refused")
check(jwt.check_claims(claims_extra({ aud = { "a", "b" } }), opts), "aud array accepted")
check(not jwt.check_claims({ iss = "i", aud = "a" }, opts), "no exp at all refused")
eq(select(2, jwt.check_claims(claims_extra({}), { now = now })), nil, "unset iss/aud expectations pass")
local ok_n, why_n = jwt.check_claims({ exp = "abc" }, { now = now })
check(not ok_n and why_n ~= nil, "a non-numeric exp refused", why_n)

-- role extraction and mapping ------------------------------------------
local m = jwt.parse_role_mapping("guest:user,ops:admin")
eq(m.ops, "admin", "mapping admin")
eq(m.guest, "user", "mapping user")
check(next(jwt.parse_role_mapping("ops:admin;guest:user")) ~= nil, "semicolon separated list parses")
eq(jwt.parse_role_mapping("ops=admin")["ops"], "admin", "equals spelling parses")
eq(jwt.parse_role_mapping("ops:ADMIN")["ops"], "admin", "target is case-insensitive")
check(next(jwt.parse_role_mapping("ops:root")) == nil, "a non admin/user target is dropped")
check(next(jwt.parse_role_mapping("no separator")) == nil, "a pair without a separator is dropped")
check(next(jwt.parse_role_mapping(nil)) == nil, "nil mapping is empty")

eq(#jwt.extract_roles({ roles = { "a", "b" } }, "roles"), 2, "array role claim")
eq(#jwt.extract_roles({ roles = "admin" }, "roles"), 1, "string role claim")
eq(jwt.extract_roles({ role = "admin" }, "roles")[1], "admin", "falls back to 'role'")
eq(jwt.extract_roles({ groups = { "ops" } }, "roles")[1], "ops", "falls back to 'groups'")
eq(#jwt.extract_roles({}, "roles"), 0, "no role claim yields no roles")
eq(#jwt.extract_roles({ roles = { 1, "ops" } }, "roles"), 1, "non-string array entries ignored")

eq(jwt.resolve_role({ "ops" }, m, true), "admin", "mapped admin")
eq(jwt.resolve_role({ "guest" }, m, true), "user", "mapped user")
eq(jwt.resolve_role({ "nobody" }, m, true), "user", "unmapped identity defaults to user")
eq(jwt.resolve_role({}, m, true), "user", "no identity defaults to user")
eq(jwt.resolve_role({ "ADMIN" }, {}, false), "admin", "no mapping: admin spelled admin")
eq(jwt.resolve_role({ "ops" }, {}, false), "user", "no mapping: unknown identity is user")

eq(jwt.subject({ sub = "s" }), "s", "subject from sub")
eq(jwt.subject({ email = "e" }), "e", "subject falls back to email")
eq(jwt.subject({ preferred_username = "p" }), "p", "subject falls back to preferred_username")
eq(jwt.subject({}), "unknown", "subject default")

-- jwks_uri allowlist ----------------------------------------------------
check(jwt.allowed_url("https://idp.example/keys"), "https allowed anywhere")
check(jwt.allowed_url("http://127.0.0.1:9/keys"), "loopback http allowed")
check(jwt.allowed_url("http://127.0.0.2:9/keys"), "any 127/8 allowed")
check(jwt.allowed_url("http://localhost:9/keys"), "localhost allowed")
check(jwt.allowed_url("http://[::1]:9/keys"), "bracketed IPv6 loopback allowed")
check(not jwt.allowed_url("http://10.0.0.1/keys"), "private http refused")
check(not jwt.allowed_url("http://idp.internal/keys"), "named host over http refused")
check(not jwt.allowed_url("ftp://h/keys"), "non-http scheme refused")
check(not jwt.allowed_url("idp.example/keys"), "scheme-less url refused")
check(not jwt.allowed_url(nil), "nil url refused")
check(not jwt.allowed_url(""), "empty url refused")

-- parsed JWKS document --------------------------------------------------
local keys, perr = jwt.parse_jwks('{"keys":[{"kid":"a","kty":"RSA"}]}')
check(keys and #keys == 1, "a normal JWKS parses", perr)
check(jwt.parse_jwks('{"keys":{}}') ~= nil, "a non-array keys object decodes to a set")
check(jwt.find_jwk(jwt.parse_jwks('{"keys":{}}'), "a") == nil, "and matches no kid")
check(jwt.parse_jwks("{}") == nil, "document without keys refused")
check(jwt.parse_jwks("not json") == nil, "non-JSON refused")
check(jwt.parse_jwks("") == nil, "empty body refused")
check(jwt.parse_jwks(string.rep("x", jwt.MAX_JWKS_BYTES + 1)) == nil, "oversized body refused")
eq(jwt.find_jwk({ { kid = "a" }, { kid = "b" } }, "b").kid, "b", "find_jwk locates a kid")
check(jwt.find_jwk({ { kid = "a" } }, "c") == nil, "find_jwk misses cleanly")
check(jwt.find_jwk(nil, "a") == nil, "find_jwk tolerates a missing list")

-- config / gate presence -------------------------------------------------
jwt.reset_config()
check(not jwt.enabled(), "JWT gate off with no jwks_uri")
local cfg = jwt.config()
eq(cfg.role_claim, "roles", "role claim default")
eq(cfg.leeway_secs, 30, "leeway default")
eq(cfg.cache_secs, 300, "cache default")
eq(cfg.mapping_configured, false, "no mapping configured by default")
local st = jwt.status()
eq(st.enabled, false, "status says disabled")
eq(st.cached_keys, 0, "status starts with no keys")

local principal, aerr, unavailable = jwt.authenticate("aaa.bbb.ccc")
check(principal == nil and aerr == "jwt_not_configured" and unavailable == true,
    "gate off => not configured and caller falls back")

print(("%d passed, %d failed"):format(passed, failed))
for i = 1, #failures do
    print("FAIL " .. failures[i])
end
os.exit(failed == 0 and 0 or 1)
