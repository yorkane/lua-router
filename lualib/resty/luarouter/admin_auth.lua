-- Admin 面 Basic Auth（用户裁定 2026-10-12）。
--
-- 只保护管理台与它的配置数据面；模型访问面（/v1/*）由调用方自带的 api-key 保护，
-- /u/ 对话界面按裁定完全不保护。不走 authz 体系，网关自己校验。
--
-- 两条豁免（任一命中即完全匿名放行，不校验任何凭据）：
--   1. env SMG_ADMIN_AUTH_PASS 未配置或为空串 —— 缺省行为逐字节等于加这道门之前
--      （AGENTS.md 硬规则 4「新开关缺省零行为变化」）；
--   2. 请求来源是 loopback（127.0.0.0/8 或 ::1）—— 操作员在本机 curl 不需要凭据。
-- 除这两条以外，全部要凭据：用户名恒为 "lua-router"（不可配），密码取 env。
--
-- 传输安全前提：Basic 口令是明文 base64，只在 HTTPS 下才是安全的。本服务若走明文
-- HTTP，口令在链路上裸奔，只应在可信内网这样用；要跨不可信网络就必须在前面挂 TLS
-- 终结的边缘（authz / APISIX），或给容器开 TLS_LISTEN_FLAGS。
local bit_ok, bit = pcall(require, "bit")

local _M = { _VERSION = "0.1.0" }

_M.ADMIN_USER = "lua-router"
_M.PASS_ENV = "SMG_ADMIN_AUTH_PASS"
-- realm 是给浏览器弹框看的文案，不放任何敏感信息（口令、内网地址、版本号都不写）。
_M.REALM = 'Basic realm="lua-router admin", charset="UTF-8"'

---读管理口令。空串按「未配置」处理（docker-compose 注释型默认值 FOO: "" 不应把
---这道门打开成一个谁都进不去的空密码）。
---@return string|nil
function _M.password()
    local value = os.getenv(_M.PASS_ENV)
    if value == nil or value == "" then
        return nil
    end
    return value
end

---是否 loopback 来源。整段 127/8 都算（本机任何回环地址等价），IPv6 只认 ::1。
---直连场景下 remote_addr 就是真实对端；本网关没有 real_ip 递归还原，所以经代理时
---拿到的是代理地址 —— 那属于「非 loopback」，会要凭据，方向是安全侧。
---@param addr string|nil
---@return boolean
function _M.is_loopback(addr)
    if type(addr) ~= "string" then
        return false
    end
    if addr == "::1" then
        return true
    end
    return addr:sub(1, 4) == "127."
end

---这个请求是否需要 Basic Auth。判定顺序即两条豁免的原文顺序。
---@param addr string|nil @来源地址；nil 时取当前请求的 remote_addr
---@return boolean
function _M.required(addr)
    if _M.password() == nil then
        return false
    end
    if addr == nil then
        addr = ngx.var.remote_addr
    end
    return not _M.is_loopback(addr)
end

---常量时间比对。先比长度（长度本来就在 401 之外可观测，泄露无意义），再逐字节异或
---累积，避免逐字符短路带来的口令前缀时序侧信道。基座没有 bit 库时退回 ==（本仓镜像
---内置 LuaJIT 的 bit，这条分支只是给纯 Lua 环境留的兜底，注释写清楚，不假装恒定）。
---@param a string
---@param b string
---@return boolean
local function const_eq(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then
        return false
    end
    if #a ~= #b then
        return false
    end
    if not bit_ok then
        return a == b
    end
    local diff = 0
    for i = 1, #a do
        diff = bit.bor(diff, bit.bxor(a:byte(i), b:byte(i)))
    end
    return diff == 0
end
_M.const_eq = const_eq

---校验一个 Authorization 头的值。用户名或密码任一不符都返回 false；非 Basic 方案、
---base64 解不开、缺冒号分隔，同样 false（全部走同一个 401，不区分失败原因，免得给
---探测者回「用户名对不对」这类线索）。
---@param value string|nil @Authorization 头的原值
---@param pass string|nil @期望口令（调用方传 _M.password() 的读数）
---@return boolean
function _M.check_header(value, pass)
    if type(value) ~= "string" or type(pass) ~= "string" then
        return false
    end
    local scheme, payload = value:match("^%s*(%a+)%s+(.-)%s*$")
    if scheme == nil or scheme:lower() ~= "basic" then
        return false
    end
    -- 解不开就 fail closed：纯 Lua 环境没有 ngx.decode_base64 时也不放行。
    if ngx == nil or type(ngx.decode_base64) ~= "function" then
        return false
    end
    local pair = ngx.decode_base64(payload)
    if type(pair) ~= "string" then
        return false
    end
    -- 口令允许含冒号：用户名段取第一个冒号之前，其余整段是口令。
    local user, pwd = pair:match("^([^:]*):(.*)$")
    if user == nil then
        return false
    end
    if not const_eq(user, _M.ADMIN_USER) then
        return false
    end
    return const_eq(pwd, pass)
end

---发 401 挑战。带 WWW-Authenticate，浏览器就会弹登录框；no-store 免得 401 被缓存住
---活过改口令。
function _M.challenge()
    ngx.header["WWW-Authenticate"] = _M.REALM
    ngx.header["Cache-Control"] = "no-store"
    ngx.status = 401
    return ngx.exit(401)
end

---鉴权闸门本体：接在受保护 location 的 access 阶段（handler 之前，401 不会走到任何
---业务逻辑，也就不会泄露 handler 的行为）。
function _M.guard()
    if not _M.required(ngx.var.remote_addr) then
        return
    end
    local pass = _M.password()
    if _M.check_header(ngx.req.get_headers()["Authorization"], pass) then
        return
    end
    return _M.challenge()
end

---管理台静态入口文档的判定：只对这些路径发挑战。
---为什么不是整棵 location / 都查：try_files 未命中会内部跳 @lmr_klib 走 klib 路由表，
---而 access 阶段跑在 try_files 之前 —— 整块一拦，/v1/chat/completions、/health、
---/metrics 这些本该由 api-key 或匿名面回答的路径会先吃 401，把模型面一起锁在门外。
---入口文档（/ 与 *.html）才是「打开管理台」这个动作，浏览器对同源后续请求会带上已
---缓存的凭据，所以 js/css 这些无秘密的静态资源放行不影响保护效果。
---@param uri string
---@return boolean
function _M.static_challenge_worthy(uri)
    if uri == "/" or uri == "" then
        return true
    end
    return type(uri) == "string" and uri:match("%.html$") ~= nil
end

---静态入口的鉴权闸门（nginx.conf.template / test conf 的 location / 用）。
function _M.guard_static()
    if not _M.static_challenge_worthy(ngx.var.uri) then
        return
    end
    return _M.guard()
end

---klib 控制面（@lmr_klib → router.handle）的闸门。这一族的形状与 ui.conf 的
---exact location 不同：/workers、/model-map、/v1/loads、/flush_cache 这些管理型
---路由和 /v1/chat/completions、/health、/metrics 这些必须匿名的路由共用一个
---dispatcher（try_files 未命中全部落进来），所以闸门只能是「按路径的过滤器」，
---在 router.handle 的 OPTIONS 预检短路之后、路由分发之前调用一次。
---
---清单刻意 **fail open**（默认放行，名单内才拦）：数据面 /v1/*、公开面
---/health /readiness /metrics /server_info、mesh 内部 /_mesh/internal/* 一旦被
---误拦，坏掉的是推理流量与监控这类「看不见就炸」的东西；漏拦的代价只是 admin
---面多一条匿名路。两类后果不对称，所以宁可漏拦不误拦。加受管路径 = 在下面的
---管理型清单里添一行；单测 test_admin_auth.lua 的清单断言与真机 e2e 钉住每条。
---
---/metrics 与 /v1/loads 的归类理由：Prometheus 抓取面必须匿名（监控面约定）；
---loads 是数据面候选装配的引擎读数聚合，/health_generate 与 hb 都在读它，拦了
---会让健康判定链吃 401。管理型 = 会改状态（workers CRUD、flush_cache 广播、
---model-map 合并）或回显名册/配置镜像（GET /workers）。
local KLIB_ADMIN_PREFIXES = { "/workers", "/model-map", "/flush_cache" }

---@param uri string|nil
---@return boolean
function _M.klib_challenge_worthy(uri)
    if type(uri) ~= "string" then
        return false
    end
    for i = 1, #KLIB_ADMIN_PREFIXES do
        local p = KLIB_ADMIN_PREFIXES[i]
        if uri == p or uri:sub(1, #p + 1) == p .. "/" then
            return true
        end
    end
    return false
end

---控制面闸门本体（router.handle 调用；OPTIONS 预检已在调用方短路，浏览器
---preFlight 从不带 Basic 凭据，若在预检后校验会把 CORS 预检全部变成 401）。
function _M.guard_klib()
    if not _M.klib_challenge_worthy(ngx.var.uri) then
        return
    end
    return _M.guard()
end

return _M
