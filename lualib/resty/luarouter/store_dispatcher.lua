-- Snapshot store dispatcher: picks the persistent backend, owns the fallback
-- ladder, and keeps the "new switch, no default behaviour change" promise.
--
-- Backend is chosen once per process from LMR_CONFIG_STORE_BACKEND:
--   sqlite    (default) single-instance deployment
--   postgres            multi-instance deployment (shared database)
--   file                explicit rollback to the pre-database behaviour
--
-- Degradation is the whole point of this module. Any backend that cannot be
-- opened -- no driver in the image, host unreachable, file missing, table
-- absent -- makes this module warn once and hand the caller the file backend,
-- because the router must still boot on env defaults. Nothing here raises.

local file_backend = require "resty.luarouter.store_file"

local _M = {}

local BACKENDS = { sqlite = true, postgres = true, file = true }
local DEFAULT_BACKEND = "sqlite"

local active       -- { backend = module, degraded = bool }
local warned = {}

local function trim(value)
    if type(value) ~= "string" then return nil end
    local out = value:gsub("^%s+", ""):gsub("%s+$", "")
    if out == "" then return nil end
    return out
end

local function env(name)
    local cache = _G.LMR_ENV_CACHE
    local v = cache and cache[name] or nil
    if v == nil then v = os.getenv(name) end
    return trim(v)
end

local function warn_once(key, ...)
    if warned[key] then return end
    warned[key] = true
    if ngx and ngx.log then pcall(ngx.log, ngx.WARN, ...) end
end

function _M.requested_backend()
    local want = env("LMR_CONFIG_STORE_BACKEND") or DEFAULT_BACKEND
    if not BACKENDS[want] then
        warn_once("backend-name", "luarouter store: unknown LMR_CONFIG_STORE_BACKEND ",
            want, ", using ", DEFAULT_BACKEND)
        return DEFAULT_BACKEND
    end
    return want
end

--- Start in replay mode: writes that the caller performs during process
--- bootstrap must never be rejected for a revision conflict, otherwise a
--- temporarily unreachable backend would turn into a failed startup.
function _M.begin_replay() _M.replaying = true end
function _M.end_replay() _M.replaying = false end
function _M.replaying_active() return _M.replaying == true end

-- The real require is deferred so a missing optional driver costs nothing for
-- deployments that never select that backend.
local function load_backend(name)
    if name == "file" then return file_backend end
    local modname = "resty.luarouter.store_" .. name
    local ok, mod = pcall(require, modname)
    if not ok or type(mod) ~= "table" then
        return nil, "require " .. modname .. " failed: " .. tostring(mod)
    end
    local can, why = mod.available()
    if not can then return nil, why or "backend unavailable" end
    return mod
end

--- Resolve (and cache) the active backend. Always returns a usable module: on
--- any failure that is the file backend, with a WARN.
function _M.backend()
    if active then return active.backend end
    local want = _M.requested_backend()
    if want ~= "file" then
        local mod, err = load_backend(want)
        if mod then
            -- Probe it once: a backend that answers available() but cannot hand
            -- back a revision is unreachable in practice, and discovering that
            -- here (rather than on the first save) is what keeps startup green.
            local rev, perr = mod.revision()
            if rev == nil and perr then
                warn_once(want .. "-probe", "luarouter store: backend ", want,
                    " unusable (", perr, "), falling back to file")
            else
                active = { backend = mod, name = want }
                return mod
            end
        else
            warn_once(want .. "-load", "luarouter store: backend ", want,
                " unavailable (", err, "), falling back to file")
        end
    end
    active = { backend = file_backend, name = "file" }
    return file_backend
end

--- Test/ops hook: forget the cached choice so the next call re-resolves.
function _M.reset() active = nil warned = {} end

function _M.active_name()
    local mod = _M.backend()
    return mod.name
end

function _M.load()
    return _M.backend().load()
end

function _M.revision()
    return _M.backend().revision()
end

--- expect_revision nil means "the caller does not know / replay": never reject.
function _M.save(snap, expect_revision)
    local mod = _M.backend()
    local expect = _M.replaying and nil or expect_revision
    local ok, err, cur = mod.save(snap, expect)
    if not ok and err and err:find("revision conflict") and _M.replaying then
        -- Belt and braces: a backend that rejects during replay must not be able
        -- to break startup, so drop the expectation and write unconditionally.
        return mod.save(snap, nil)
    end
    return ok, err, cur
end

--- Import the legacy JSON snapshot into a fresh backend, then keep a backup.
--- Returns (imported, err). A non-empty backend is left untouched (idempotent).
function _M.migrate_from_file(mod)
    mod = mod or _M.backend()
    if mod.name == "file" then return false, "file backend needs no migration" end
    if not file_backend.available() then return false, "no legacy file to migrate" end
    local cur = mod.revision()
    if cur ~= nil then return false, "backend already populated" end
    local snap, err = file_backend.load()
    if not snap then return false, "read legacy file: " .. tostring(err) end
    local text = require("cjson.safe").encode(snap)
    if not text then return false, "legacy snapshot not encodable" end
    local base = env("LMR_CONFIG_FILE")
    if base then
        local stamp = ((ngx and ngx.now) and math.floor(ngx.now()) or os.time())
        local backup = base .. ".pre-" .. mod.name .. "." .. stamp .. ".json"
        local f = io.open(backup, "w")
        if f then f:write(text); f:close() else backup = nil end
        _M.last_backup = backup
    end
    local ok, serr, rev = mod.save(snap, nil)
    if not ok then return false, "import: " .. tostring(serr) end
    return true, nil, rev
end

return _M

