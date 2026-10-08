-- resty.luarouter.config_store.env
-- P5 env 名册（ENV_NAMES）与 capture_env / env，加 P13 的 LMR_UPSTREAMS_FILE 种子层
-- （含 0.5s TTL 缓存）。_G.LMR_ENV_CACHE 是四个后端共读的隐式契约，语义原样。
--
-- 由 lualib/resty/luarouter/config_store.lua 拆分而来：函数体逐行原样搬家，只调整 require 与
-- 跨模块接线（doc/refactor-arch-2026-10-05.md §1–§2）。原文里经 _M.x() 的自调 → 经 CS_FACADE
-- 表调用（保住单测换桩的可拦截性逐点一致）；原文里的同文件 local 直调 → 直接 require 对端
-- 子模块的共享表调用（不进 facade 导出面，_M 契约因此逐名不变）。
local CS_FACADE = require "resty.luarouter.config_store"
local cjson = require "cjson.safe"
local CS_LEXICON = require "resty.luarouter.config_store.lexicon"

local _M = {}

--- LMR_* names the module reads. Declared here so capture_env() can snapshot
--- them once in the master process (nginx strips undeclared variables from
--- worker environments, so os.getenv returns nil inside request phases).
_M.ENV_NAMES = {
    "SMG_POLICY",
    "LMR_DEFAULT_EFFORT", "LMR_EFFORT_MAP", "LMR_MODEL_CTX", "LMR_MODEL_EFFORT",
    "LMR_MODEL_EFFORT_MAP", "LMR_MODEL_MODALITIES", "LMR_VIRTUAL_MODELS",
    -- 卡片级档位勾选（用户诉求 2026-10-08）。漏登记的名字会被 nginx 从 worker 环境里剥掉、
    -- capture_env 也只按名册抓，现象是「配了但静默走未配置」（硬规则 11③）。
    "LMR_MODEL_EFFORT_LEVELS",
    -- 声明进 ENV_NAMES 是硬要求：nginx 会把未声明的变量从 worker 环境里剥掉，
    -- 漏了这一行则 LMR_MODEL_CONTEXT_LIMIT 只在 master 里可见，worker 读到 nil。
    "LMR_MODEL_CONTEXT_LIMIT",
    -- /v1/models「只广告虚拟入口」开关（030dab5 落的路由侧读的就是这个键的 env 层）。
    -- 它当时绕开 config_store 直读磁盘原文，正是为了躲「没进 ENV_NAMES 的键在 worker 里
    -- 恒为 nil」这一层；名册补齐之后 config_store 与 router 读到的是同一份读数。
    -- 另注：本仓三份 conf 里没有任何 env LMR_* 白名单（只放行 LR_* / SMG_*），LMR_* 一律
    -- 靠 capture_env 在 init_by_lua（fork 之前）抓进 _G.LMR_ENV_CACHE，所以这里加名就是
    -- 全部要做的事，不需要也不应该去 conf 里再加一行 env 指令。
    "LMR_MODELS_VIRTUAL_ONLY",
    "LMR_CONFIG_FILE", "LMR_CONFIG_STORE_BACKEND", "LMR_CONFIG_STORE_PATH",
    -- Both spellings are live: store_postgres reads the PG_-prefixed name first and
    -- falls back to the short one. Registering only one half leaves whichever the
    -- operator did not type invisible to the worker (nginx drops env that is not
    -- in this list, and capture_env only caches what is in it).
    "LMR_CONFIG_STORE_PG_HOST", "LMR_CONFIG_STORE_HOST",
    "LMR_CONFIG_STORE_PG_PORT", "LMR_CONFIG_STORE_PORT",
    "LMR_CONFIG_STORE_PG_DATABASE", "LMR_CONFIG_STORE_DATABASE",
    "LMR_CONFIG_STORE_PG_USER", "LMR_CONFIG_STORE_USER",
    "LMR_CONFIG_STORE_PG_PASSWORD", "LMR_CONFIG_STORE_PASSWORD",
    "LMR_CONFIG_STORE_TIMEOUT_MS",
    "LMR_UI_DIR", "LMR_UI_ROUTER_MODE",
    "LMR_LOGS_BUFFER", "LMR_UPSTREAMS_FILE",
}

--- Call from init_by_lua_block: caches the environment in a plain global that
--- every worker inherits by fork. Idempotent; safe to call again later.
function _M.capture_env()
    if _G.LMR_ENV_CACHE then return _G.LMR_ENV_CACHE end
    local cache = {}
    for _, name in ipairs(CS_FACADE.ENV_NAMES) do
        local v = os.getenv(name)
        if v ~= nil then cache[name] = v end
    end
    _G.LMR_ENV_CACHE = cache
    return cache
end

--- Trimmed non-empty environment value, or nil. Reads the init-time cache
--- first, then os.getenv (covers unit tests run outside nginx).
local function env(name)
    local cache = _G.LMR_ENV_CACHE
    local v = cache and cache[name] or nil
    if v == nil then v = os.getenv(name) end
    if v == nil then return nil end
    v = CS_LEXICON.trim(v)
    if v == "" then return nil end
    return v
end

_M.env = env

--- env-layer upstream seed: LMR_UPSTREAMS_FILE points at a JSON file holding
--- either the array form or {upstreams:[...]} (the same shapes the document
--- accepts). Missing/unreadable/invalid means "no seed" — the env layer must
--- never take the gateway down over a bootstrap file.
local env_upstreams_cache = { path = nil, at = 0, rows = nil }

--- Forget the cached seed file (unit hook + operator reload path).
function _M.reset_env_upstreams_cache()
    env_upstreams_cache.path = nil
    env_upstreams_cache.at = 0
    env_upstreams_cache.rows = nil
end

function _M.env_upstreams()
    local path = env("LMR_UPSTREAMS_FILE")
    if not path then return {} end
    local now = (ngx and ngx.now) and ngx.now() or os.time()
    if env_upstreams_cache.path == path and env_upstreams_cache.rows
        and (now - env_upstreams_cache.at) < CS_LEXICON.SNAPSHOT_TTL then
        return env_upstreams_cache.rows
    end
    env_upstreams_cache.path = path
    env_upstreams_cache.at = now
    env_upstreams_cache.rows = {}
    local f = io.open(path, "r")
    if not f then return env_upstreams_cache.rows end
    local text = f:read("*a")
    f:close()
    local decoded = cjson.decode(text or "")
    if decoded == nil then return env_upstreams_cache.rows end
    local rows = decoded
    if type(decoded) == "table" and not CS_LEXICON.is_array(decoded) and decoded.upstreams ~= nil then
        rows = decoded.upstreams
    end
    if CS_LEXICON.is_array(rows) then env_upstreams_cache.rows = rows end
    return env_upstreams_cache.rows
end

-- ------------------------------------------------- 跨子模块直调的原文 local
-- 这些函数在原文里是同文件 local 直调、从未挂在 _M 上；拆开后由调用方直接 require 本表
-- 调用（不经 facade，所以既不是新增导出、也不给单测多开一个可替换点）。
_M.env = env

return _M
