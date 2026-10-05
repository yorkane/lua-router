-- SQLite snapshot backend (default).
--
-- Shape borrowed from the authz gateway's production SQLite layer
-- (resty/authz/db/driver.lua): FFI against libsqlite3.so.0, open_v2, WAL,
-- busy_timeout, parameterised bind. That driver owns the connection, so this
-- module owns only the one table a config snapshot needs. Deliberately NOT
-- reused from authz/db.lua: its query_cache and bump_authz_revision are wired
-- to the authz_cache shdict and a users/sessions/policies schema that has no
-- bearing on the router's runtime config.
--
-- The driver keeps one connection per worker and returns early if one is
-- already open, so a second opener would silently share the first one's file.
-- Nothing in the router's rendered nginx.conf loads authz, but that invariant
-- belongs to another file, so this module records the path it opened and
-- refuses (degrades) if the connection belongs to somebody else.

local cjson = require "cjson.safe"

local _M = {}
_M.name = "sqlite"

local SNAPSHOT_KEY = "runtime"
local DEFAULT_BUSY_MS = 5000

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

-- One WARN per key for the life of the worker. The failure paths below include
-- the read path (load/revision run on config reads), so an unthrottled warn is a
-- log-flood away from being worse than the silence it replaces -- while a plain
-- "log once ever" is what made the old dispatcher signal useless: it said the
-- true thing exactly once, at boot, and then nothing for the remaining weeks.
-- Deduping per *key* rather than per module keeps the distinct failures
-- distinguishable (a broken table and a broken driver are not the same news),
-- and _M.reset_warn_state() lets a test or an ops reload re-arm them.
local warned = {}

local function warn(key, ...)
    if warned[key] then return end
    warned[key] = true
    if ngx and ngx.log then
        pcall(ngx.log, ngx.WARN, "luarouter store sqlite: ", ...)
    end
end

---Re-arm the per-key WARNs so a backend that broke, was fixed, and broke again
---can say so again.
function _M.reset_warn_state()
    warned = {}
end

-- ------------------------------------------------------------ driver binding

-- Hard failure of the binding (no libsqlite3, no ffi) must degrade to the file
-- backend, not abort startup: a gateway that cannot come up because its config
-- store is unavailable is a worse outcome than a gateway on the old backend.
local driver, driver_err
do
    local ok, mod = pcall(require, "resty.authz.db.driver")
    if ok and type(mod) == "table"
        and type(mod.open) == "function" and type(mod.query) == "function"
        and type(mod.exec) == "function" then
        driver = mod
    else
        driver_err = tostring(mod)
    end
end

_M.driver_error = driver_err

local opened_path
local broken

local function db_path()
    local explicit = env("LMR_CONFIG_STORE_PATH")
    if explicit then return explicit end
    local base = env("LMR_CONFIG_FILE")
    if base then return base .. ".db" end
    return nil
end

local function ensure_open()
    if not driver then return nil, "no sqlite driver: " .. tostring(driver_err) end
    local path = db_path()
    if not path then return nil, "no LMR_CONFIG_STORE_PATH or LMR_CONFIG_FILE" end
    if opened_path == path then return path end
    if driver.is_open and driver.is_open() and opened_path ~= path then
        -- The shared driver keeps one connection per process, so a second path
        -- here would silently read and write somebody else's file. Refusing is
        -- right; saying nothing was not.
        warn("held", "refusing ", path, ": connection already held by ",
            tostring(opened_path))
        return nil, "sqlite connection already held by " .. tostring(opened_path)
    end
    -- driver.open raises on failure.
    local ok, err = pcall(driver.open, path)
    if not ok then
        warn("open", "cannot open ", path, ": ", tostring(err))
        return nil, "open " .. path .. ": " .. tostring(err)
    end
    opened_path = path
    local ddl = [[CREATE TABLE IF NOT EXISTS lr_config_snapshot(
  key TEXT PRIMARY KEY,
  revision INTEGER NOT NULL,
  body TEXT NOT NULL,
  updated_at INTEGER NOT NULL)]]
    local created, derr = driver.exec(ddl)
    if not created then
        opened_path = nil
        warn("ddl", "cannot create lr_config_snapshot: ", tostring(derr))
        return nil, "create table: " .. tostring(derr)
    end
    driver.exec("PRAGMA busy_timeout=" .. DEFAULT_BUSY_MS)
    return path
end

---Tell the dispatcher that the backend it may still be holding is gone.
---
---Without this the dispatcher keeps serving the module it cached, so a backend
---that breaks mid-life is used-but-refused on every save and the operator sees
---neither a WARN (the dispatcher already spent its one) nor a gauge that moved.
---The require is lazy because the dispatcher loads this module itself: a
---top-level require here would be a cycle.
local function report_broken(why)
    local ok, dispatcher = pcall(require, "resty.luarouter.store_dispatcher")
    if ok and type(dispatcher) == "table"
        and type(dispatcher.notify_backend_broken) == "function" then
        pcall(dispatcher.notify_backend_broken, "sqlite", why)
    end
end

--- Mark this backend unusable so the dispatcher can fall back to file.
function _M.disable(why)
    broken = why or "disabled"
    opened_path = nil
    -- The one-way door of this backend: after this, available() refuses for the
    -- rest of the process and the dispatcher falls to file. Silence here is what
    -- let a mid-life breakage look like a gateway that "was always on file", so
    -- this is logged unconditionally rather than through the deduped keys -- and
    -- the keys are re-armed so the other pending failures can say themselves
    -- again, now that there is a fresh cause behind them.
    warned = {}
    if ngx and ngx.log then
        pcall(ngx.log, ngx.WARN,
            "luarouter store sqlite: backend disabled: ", tostring(why))
    end
    report_broken(why)
    return nil, why
end



function _M.broken_reason()
    return broken
end

function _M.available()
    if not driver then
        warn("driver", "no sqlite driver: ", tostring(driver_err))
        return false, "no sqlite driver: " .. tostring(driver_err)
    end
    if broken then
        warn("broken", "backend disabled: ", broken)
        return false, broken
    end
    if not db_path() then
        warn("path", "no store path configured (set LMR_CONFIG_STORE_PATH or LMR_CONFIG_FILE)")
        return false, "no store path configured"
    end
    return true
end

local function now()
    return (ngx and ngx.now) and math.floor(ngx.now()) or os.time()
end

-- ------------------------------------------------------------------- read

--- Revision persisted in the table, or nil when there is nothing readable yet.
function _M.revision()
    local ok, err = _M.available()
    if not ok then return nil, err end
    local path, oerr = ensure_open()
    if not path then return nil, oerr end
    local rows, qerr = driver.query(
        "SELECT revision FROM lr_config_snapshot WHERE key = ?", { SNAPSHOT_KEY })
    if not rows then
        warn("revision-query", "revision read failed: ", tostring(qerr))
        return nil, tostring(qerr)
    end
    if #rows == 0 then return nil end
    return tonumber(rows[1].revision)
end

---@return snapshot|nil, err|nil, revision|nil
function _M.load()
    local ok, err = _M.available()
    if not ok then return nil, err end
    local path, oerr = ensure_open()
    if not path then return nil, oerr end
    local rows, qerr = driver.query(
        "SELECT revision, body FROM lr_config_snapshot WHERE key = ?", { SNAPSHOT_KEY })
    if not rows then
        warn("load-query", "snapshot read failed: ", tostring(qerr))
        return nil, tostring(qerr)
    end
    if #rows == 0 then return nil, "empty store", nil end
    local snap = cjson.decode(rows[1].body)
    if not snap then
        -- Bytes in the authoritative column that the gateway cannot read back.
        -- Not safe to stay silent about: the config layer falls through to the
        -- file on nil, so this is the moment the mirror becomes the truth.
        warn("load-decode", "stored snapshot is not json (revision ",
            tostring(rows[1].revision), "); readers fall back to the file")
        return nil, "stored snapshot is not json", nil
    end
    return snap, nil, tonumber(rows[1].revision)
end

-- ------------------------------------------------------------------ write

--- Whole-snapshot replace with compare-and-set.
---   expect_revision nil -> unconditional (replay / degraded CAS)
---   expect_revision n   -> write only while the stored revision is still n
--- The two statements run back to back on one connection; SQLite's writer lock
--- plus busy_timeout serialises competing workers, and the guarded UPDATE makes
--- a lost race observable instead of silent.
function _M.save(snap, expect_revision)
    local ok, err = _M.available()
    if not ok then return false, err end
    local path, oerr = ensure_open()
    if not path then return false, oerr end
    local text, enc_err = cjson.encode(snap)
    if not text then return false, "encode: " .. tostring(enc_err) end

    local cur_rows, qerr = driver.query(
        "SELECT revision FROM lr_config_snapshot WHERE key = ?", { SNAPSHOT_KEY })
    if not cur_rows then
        warn("save-read", "cannot read the current revision: ", tostring(qerr))
        return false, tostring(qerr)
    end
    local cur = (#cur_rows > 0) and tonumber(cur_rows[1].revision) or nil

    if expect_revision ~= nil and cur ~= nil and cur ~= expect_revision then
        return false, string.format("revision conflict: expected %s, current %s",
            tostring(expect_revision), tostring(cur)), cur
    end
    local next_rev = (cur or 0) + 1

    if cur == nil then
        local ins, ierr = driver.exec(
            "INSERT INTO lr_config_snapshot(key, revision, body, updated_at) VALUES(?,?,?,?)",
            { SNAPSHOT_KEY, next_rev, text, now() })
        if not ins then
            warn("insert", "insert failed: ", tostring(ierr))
            return false, "insert: " .. tostring(ierr)
        end
        return true, nil, next_rev
    end

    local updated, uerr = driver.exec(
        "UPDATE lr_config_snapshot SET revision=?, body=?, updated_at=? WHERE key=? AND revision=?",
        { next_rev, text, now(), SNAPSHOT_KEY, expect_revision or cur })
    if not updated then
        warn("update", "update failed at revision ", tostring(next_rev), ": ",
            tostring(uerr))
        return false, "update: " .. tostring(uerr)
    end
    local after = driver.query(
        "SELECT revision FROM lr_config_snapshot WHERE key = ?", { SNAPSHOT_KEY })
    if after and #after > 0 and tonumber(after[1].revision) == next_rev then
        return true, nil, next_rev
    end
    -- Two different outcomes wear the same "conflict" wording from here and the
    -- distinction is the whole value of this line: either another writer won the
    -- race (harmless, the caller retries) or the UPDATE reported success while
    -- the row does not say what it was just written to say (the commit is a lie).
    -- The second is findable nowhere else, so it is logged as itself.
    if not after or #after == 0 then
        warn("verify-gone", "UPDATE reported success and the snapshot row is gone")
    elseif tonumber(after[1].revision) ~= next_rev then
        warn("verify", "UPDATE reported success at revision ", tostring(next_rev),
            " but the stored revision is ", tostring(tonumber(after[1].revision)))
    end
    return false, string.format("revision conflict: expected %s, current %s",
        tostring(expect_revision or cur), tostring(cur)), cur
end

--- Import a snapshot read from the legacy file backend. Idempotent: a store
--- that already holds a snapshot is left exactly as it is.
function _M.import_snapshot(snap, revision)
    local ok, err = _M.available()
    if not ok then return false, err end
    local cur = _M.revision()
    if cur ~= nil then return false, "store not empty", cur end
    return _M.save(snap, nil)
end

function _M.close()
    if opened_path and driver and driver.close then
        pcall(driver.close)
        opened_path = nil
    end
end

return _M

