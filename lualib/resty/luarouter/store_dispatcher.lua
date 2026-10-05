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

-- Observability hooks are deliberately indirect. The store layer has to be able
-- to degrade even when the metrics module itself is out of reach -- a luajit unit
-- run has no ngx and therefore no lr_stats to write into -- and a counter that
-- can throw would convert an invisible failure into a failed startup. So every
-- call below is pcall'd and every failure ignored: these numbers are the reason
-- a degradation became alertable at all, not a dependency of the write path.
local obs_mod

local function obs()
    if obs_mod == false then return nil end
    if obs_mod then return obs_mod end
    local ok, mod = pcall(require, "resty.luarouter.observability")
    if not ok or type(mod) ~= "table" then
        obs_mod = false
        return nil
    end
    obs_mod = mod
    return mod
end

---Say which backend this process writes to. observability caches the published
---name, so calling this from the hot resolution path costs one string compare
---until the answer actually changes; no shared-dict write, no store read.
local function publish_backend(name)
    local m = obs()
    if m and m.publish_config_backend then pcall(m.publish_config_backend, name) end
end

---One resolution ended on a weaker backend than the operator asked for. The
---`reason` values are a fixed enum owned by observability (driver_missing,
---probe_failed, unavailable, runtime_error, unknown_name); nothing derived from
---an error string is ever sent as a label, because those carry paths and hosts.
local function note_degradation(reason)
    local m = obs()
    if m and m.note_config_degradation then pcall(m.note_config_degradation, reason) end
end

---One save attempt, classified where it happened. See _M.note_config_save.
local function note_save(result)
    local m = obs()
    if m and m.note_config_save then pcall(m.note_config_save, result) end
end

---Classify a load_backend refusal into the degradation enum. The wording is
---matched against the fixed strings the backends themselves produce, so the
---label set stays closed: the raw text goes to the WARN, and the label is only
---ever one of the enum names. "driver_missing" covers both flavours of "what
---this needs is not here" -- no pgmoon in the image, no host configured --
---because the operator action is the same (fix the image or the knob), while
---"unavailable" means it is configured and refusing.
local MISSING_WORDS = { "driver", "require", "not configured", "no store path" }

local broke_after_selection = {}

local function classify_unavailable(why)
    local text = tostring(why or ""):lower()
    for i = 1, #MISSING_WORDS do
        if text:find(MISSING_WORDS[i], 1, false) then return "driver_missing" end
    end
    return "unavailable"
end

---Classify a failed save into the saves_total enum. The CAS refusal is matched
---on the backends' own fixed wording (both `store_sqlite` and `store_postgres`
---say "revision conflict" for a lost race); anything else that stopped a write
---is reported as unavailable, which is the honest label for "the store could not
---be reached" without letting a driver's error text into a label.
local function classify_save_failure(err)
    local text = tostring(err or "")
    if text:find("revision conflict", 1, false) then
        return "conflict"
    end
    return "unavailable"
end

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
        -- Counted, not just warned: a typo in the knob is indistinguishable from
        -- the requested backend at the traffic level, and this is the only place
        -- that knows the operator asked for something else.
        note_degradation("unknown_name")
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
                note_degradation("probe_failed")
            else
                active = { backend = mod, name = want }
                publish_backend(want)
                return mod
            end
        else
            warn_once(want .. "-load", "luarouter store: backend ", want,
                " unavailable (", err, "), falling back to file")
            -- A backend that broke after selection re-resolves into this branch;
            -- its degradation was already decided by notify_backend_broken, so the
            -- marker is spent here to keep the event at one increment with the
            -- honest reason, instead of a second one labelled "unavailable".
            if broke_after_selection[want] then
                broke_after_selection[want] = nil
                note_degradation("runtime_error")
            else
                note_degradation(classify_unavailable(err))
            end
        end
    end
    active = { backend = file_backend, name = "file" }
    -- Published on every path that lands here, including want == "file": a
    -- process that asked for file is on file, and the gauge says so. The real
    -- signal is the *pair* -- backend="sqlite" requested, backend="file" 1 --
    -- which is why this never needs a second series to be honest.
    publish_backend("file")
    return file_backend
end

--- Called by a backend that broke after it was already selected (see
--- store_sqlite.disable). The cached module is dropped so the next call
--- re-resolves -- which is what moves the gauge, since a backend that broke
--- mid-life is otherwise used-and-refused on every save with neither a WARN (the
--- dispatcher spent its one at selection time) nor a series that changed.
---
--- Counted per call rather than once: unlike the boot-time fallback, this is not
--- a single decision the process makes and then lives with. If the answer keeps
--- coming back broken, the rate is the news.
function _M.notify_backend_broken(name, why)
    if active and active.name == name then
        active = nil
    end
    warned[name .. "-load"] = nil
    warned[name .. "-probe"] = nil
    broke_after_selection[name] = true
    if ngx and ngx.log then
        pcall(ngx.log, ngx.WARN, "luarouter store: backend ", tostring(name),
            " broke after selection (", tostring(why), "), re-resolving")
    end
end

--- Test/ops hook: forget the cached choice so the next call re-resolves.
function _M.reset()
    active = nil
    warned = {}
end

function _M.active_name()
    local mod = _M.backend()
    return mod.name
end

function _M.active_backend_name()
    return active and active.name or nil
end

function _M.load()
    return _M.backend().load()
end

function _M.revision()
    return _M.backend().revision()
end

--- expect_revision nil means "the caller does not know / replay": never reject.
---
--- Every outcome of one save call is counted exactly where it happened, and the
--- replay path deliberately yields two increments: a CAS refused during replay
--- is counted as the conflict it was, then the forced unconditional write that
--- follows is counted by its own result. Neither number lies on its own -- the
--- pair says "the operator's compare-and-set was refused, and the value was
--- persisted anyway", which is the one shape a caller that only reports its final
--- return can never express, and precisely the failure that left the reviewer
--- with nothing to grep.
function _M.save(snap, expect_revision)
    local mod = _M.backend()
    local expect = _M.replaying and nil or expect_revision
    local ok, err, cur = mod.save(snap, expect)
    if ok then
        note_save("ok")
        return ok, err, cur
    end
    note_save(classify_save_failure(err))
    if err and err:find("revision conflict") and _M.replaying then
        -- Belt and braces: a backend that rejects during replay must not be able
        -- to break startup, so drop the expectation and write unconditionally.
        local fok, ferr, fcur = mod.save(snap, nil)
        note_save(fok and "ok" or classify_save_failure(ferr))
        return fok, ferr, fcur
    end
    return ok, err, cur
end

---Mirror the authoritative write into the human-readable file, with the failure
---counted.
---
---This is the seam the config-store layer is meant to call for its post-commit
---mirror; it currently requires store_file directly, and routing that one call
---here is the owner's decision (config_store.lua is outside this change). The
---mirror is for humans and for the rollback path, so a failure there stays a
---warning rather than a failed save -- but it must not also stay invisible: a db
---that committed while its mirror did not leaves a stale file that the
---external-edit path can later adopt back over the newer db value, which is the
---one shape where "the save returned ok" is a lie. Counted here so the
---accounting sits with the store layer that owns these numbers.
---@return boolean ok, string|nil err
function _M.mirror_to_file(snap, rev)
    if not env("LMR_CONFIG_FILE") then
        -- Nothing to mirror to: without a configured file there is no stale
        -- second source of truth either, so this is not a mirror_failed.
        return true
    end
    local ok, fmod = pcall(require, "resty.luarouter.store_file")
    if not ok or type(fmod) ~= "table" or type(fmod.mirror) ~= "function" then
        note_save("mirror_failed")
        return false, "file backend unavailable"
    end
    local mok, merr = fmod.mirror(snap, rev)
    if not mok then note_save("mirror_failed") end
    return mok, merr
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

