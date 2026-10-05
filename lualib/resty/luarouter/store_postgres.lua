-- PostgreSQL snapshot backend, for the multi-instance case.
--
-- One row holds the whole snapshot; revision is a column, so compare-and-set
-- is a guarded UPDATE rather than a rename race. Everything about this backend
-- is meant to be pure configuration: connection parameters arrive through
-- LMR_CONFIG_STORE_* and nothing here hardcodes a host.
--
-- pgmoon is NOT vendored into this repo and the base image does not ship it
-- (the image carries mysql/redis/memcached cosocket drivers only). Requiring it
-- is therefore done lazily and a missing driver is a *degrade*, not a startup
-- error: the dispatcher falls back to the file backend and logs a WARN. 21.k
-- has no reachable database at all today, so "postgres configured but
-- unreachable" is the normal state on that box, not an exceptional one.

local cjson = require "cjson.safe"

local _M = {}
_M.name = "postgres"

local SNAPSHOT_KEY = "runtime"
local TABLE_NAME = "lr_config_snapshot"

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

-- ------------------------------------------------------------------ config

local function settings()
    local host = env("LMR_CONFIG_STORE_PG_HOST") or env("LMR_CONFIG_STORE_HOST")
    if not host then return nil, "no LMR_CONFIG_STORE_PG_HOST" end
    return {
        host = host,
        port = tonumber(env("LMR_CONFIG_STORE_PG_PORT") or env("LMR_CONFIG_STORE_PORT")) or 5432,
        database = env("LMR_CONFIG_STORE_PG_DATABASE") or env("LMR_CONFIG_STORE_DATABASE") or "lua_router",
        user = env("LMR_CONFIG_STORE_PG_USER") or env("LMR_CONFIG_STORE_USER") or "lua_router",
        password = env("LMR_CONFIG_STORE_PG_PASSWORD") or env("LMR_CONFIG_STORE_PASSWORD") or "",
        timeout = (tonumber(env("LMR_CONFIG_STORE_TIMEOUT_MS")) or 2000) * 1000,
    }
end

-- --------------------------------------------------------------- connection

local pgmoon, pgmoon_err
local conn, conn_sig

local function signature(cfg)
    return table.concat({ cfg.host, cfg.port, cfg.database, cfg.user }, "|")
end

local function ensure_conn()
    if not pgmoon then
        local ok, mod = pcall(require, "pgmoon")
        if not ok or type(mod) ~= "table" or type(mod.new) ~= "function" then
            pgmoon_err = tostring(mod)
            return nil, "no pgmoon driver: " .. pgmoon_err
        end
        pgmoon = mod
    end
    local cfg, cerr = settings()
    if not cfg then return nil, cerr end
    local sig = signature(cfg)
    if conn and conn_sig == sig then return conn end
    if conn and conn_sig ~= sig then
        pcall(function() conn:close() end)
        conn = nil
    end
    local ok, client = pcall(pgmoon.new, {
        host = cfg.host, port = tostring(cfg.port), database = cfg.database,
        user = cfg.user, password = cfg.password, timeout = cfg.timeout,
    })
    if not ok or not client then return nil, "pgmoon.new failed: " .. tostring(client) end
    local okc, err = client:connect()
    if not okc then
        pcall(function() client:close() end)
        return nil, "connect " .. cfg.host .. ":" .. cfg.port .. ": " .. tostring(err)
    end
    conn, conn_sig = client, sig
    local created = client:query(
        "CREATE TABLE IF NOT EXISTS " .. TABLE_NAME .. "(" ..
        "key text PRIMARY KEY, revision bigint NOT NULL, body text NOT NULL, updated_at bigint NOT NULL)")
    local is_err = type(created) == "table" and created.affected_rows == nil
        and created.error ~= nil
    if not created or is_err then
        return nil, "create table: " .. tostring(type(created) == "table" and created.error or created)
    end
    return client
end

--- Normalise a pgmoon result: queries report errors inline rather than raising.
local function rows_of(res)
    if type(res) ~= "table" then return nil, "bad response" end
    if res.error then return nil, tostring(res.error) end
    return res
end

function _M.available()
    if not env("LMR_CONFIG_STORE_PG_HOST") and not env("LMR_CONFIG_STORE_HOST") then
        return false, "postgres backend not configured"
    end
    return true
end

local function now()
    return (ngx and ngx.now) and math.floor(ngx.now()) or os.time()
end

function _M.revision()
    local client, cerr = ensure_conn()
    if not client then return nil, cerr end
    local res, rerr = rows_of(client:query(
        "SELECT revision FROM " .. TABLE_NAME .. " WHERE key = $1", { SNAPSHOT_KEY }))
    if not res then return nil, rerr end
    if #res == 0 then return nil end
    return tonumber(res[1].revision)
end

function _M.load()
    local client, cerr = ensure_conn()
    if not client then return nil, cerr end
    local res, rerr = rows_of(client:query(
        "SELECT revision, body FROM " .. TABLE_NAME .. " WHERE key = $1", { SNAPSHOT_KEY }))
    if not res then return nil, rerr end
    if #res == 0 then return nil, "empty store", nil end
    local snap = cjson.decode(res[1].body)
    if not snap then return nil, "stored snapshot is not json", nil end
    return snap, nil, tonumber(res[1].revision)
end

function _M.save(snap, expect_revision)
    local client, cerr = ensure_conn()
    if not client then return false, cerr end
    local text, enc_err = cjson.encode(snap)
    if not text then return false, "encode: " .. tostring(enc_err) end

    local cur_res, qerr = rows_of(client:query(
        "SELECT revision FROM " .. TABLE_NAME .. " WHERE key = $1", { SNAPSHOT_KEY }))
    if not cur_res then return false, qerr end
    local cur = (#cur_res > 0) and tonumber(cur_res[1].revision) or nil

    if expect_revision ~= nil and cur ~= nil and cur ~= expect_revision then
        return false, string.format("revision conflict: expected %s, current %s",
            tostring(expect_revision), tostring(cur)), cur
    end
    local next_rev = (cur or 0) + 1

    if cur == nil then
        local ins = client:query(
            "INSERT INTO " .. TABLE_NAME .. "(key, revision, body, updated_at) VALUES($1,$2,$3,$4)",
            { SNAPSHOT_KEY, next_rev, text, now() })
        local _, ierr = rows_of(ins)
        if ierr then return false, "insert: " .. ierr end
        return true, nil, next_rev
    end

    local upd = client:query(
        "UPDATE " .. TABLE_NAME .. " SET revision = $1, body = $2, updated_at = $3" ..
        " WHERE key = $4 AND revision = $5",
        { next_rev, text, now(), SNAPSHOT_KEY, expect_revision or cur })
    local urow, uerr = rows_of(upd)
    if uerr then return false, "update: " .. uerr end
    local affected = tonumber((urow[1] or {}).affected_rows or urow.affected_rows or 0) or 0
    if affected > 0 then return true, nil, next_rev end
    return false, string.format("revision conflict: expected %s, current %s",
        tostring(expect_revision or cur), tostring(cur)), cur
end

function _M.import_snapshot(snap, revision)
    local cur = _M.revision()
    if cur ~= nil then return false, "store not empty", cur end
    return _M.save(snap, nil)
end

function _M.close()
    if conn then pcall(function() conn:close() end); conn, conn_sig = nil, nil end
end

return _M

