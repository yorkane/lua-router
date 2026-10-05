-- 进程级惰性访问器（自 router.lua 逐字搬来，函数体原样）。
--
-- 拆分落位（回报同步）：cfg()/limit()/store() 这三个「懒取一次、进程级缓存」的
-- 访问器原本是全体函数共享的上文；拆成多个子模块后需要一个公共落点。设计书 §1
-- 未给它们点名文件，这里收进内部模块 router/host.lua —— 不进 _M 导出契约
-- （facade 不 re-export），只被子模块 require。缓存语义与原文件一致：同一进程
-- 同一份 config / limiter 模块 / config_store 表。
-- 锚点单测（test_caps_routing / test_profiles 11b / test_effort_layers）把 cfg/
-- store 当**沙箱注入名**使用——它们只切函数体、桩由 environment 表给，不经本模块。
local _M = {}
package.loaded["resty.luarouter.router.host"] = _M
-- Declared here so the handlers below can reach it; the limiter itself is at
-- resty/luarouter/limit.lua.
local limit_mod
---Accessor so the limiter module is required once per process.
local config
local function cfg()
    if not config then
        config = require("resty.luarouter").config()
    end
    return config
end

local function limit()
    if not limit_mod then
        limit_mod = require "resty.luarouter.limit"
    end
    return limit_mod
end
-- ------------------------------------------------------------------ body rewrite

-- Lazily loaded: the runtime-config module owns virtual aliases, the effort
-- ladder and the per-model context cap. Wrapped so a router
-- without it (unit probes) still forwards.
local function store()
    local ok, mod = pcall(require, "resty.luarouter.config_store")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end
_M.cfg = cfg
_M.limit = limit
_M.store = store
return _M
