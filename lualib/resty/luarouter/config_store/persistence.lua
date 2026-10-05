-- resty.luarouter.config_store.persistence
-- P17-P21：dict / store 惰性解析 + 三层读写 + CAS 冲突 + persist + migrate_once；外加
-- 四枚 shdict 键上的 token 读点（policy_revision / upstreams_revision /
-- upstreams_reconcile_due 都只读 shdict，按同域纪律留在这里）。
-- 硬边界：全模块只有本文件碰 shdict / 后端 / 文件 IO。
--
-- 由 lualib/resty/luarouter/config_store.lua 拆分而来：函数体逐行原样搬家，只调整 require 与
-- 跨模块接线（doc/refactor-arch-2026-10-05.md §1–§2）。原文里经 _M.x() 的自调 → 经 CS_FACADE
-- 表调用（保住单测换桩的可拦截性逐点一致）；原文里的同文件 local 直调 → 直接 require 对端
-- 子模块的共享表调用（不进 facade 导出面，_M 契约因此逐名不变）。
local CS_FACADE = require "resty.luarouter.config_store"
local cjson = require "cjson.safe"
local CS_LEXICON = require "resty.luarouter.config_store.lexicon"
local CS_ENV = require "resty.luarouter.config_store.env"

local _M = {}

local DICT_NAME = "luarouter_config"

local DICT_KEY = "runtime_config"

-- Cheap cross-worker invalidation token for the policy readers (policy.lua calls
-- this on the hot path; it is a plain shdict get with no JSON decode).
local REV_KEY = "policy_revision"

-- The revision the durable layer answered with when it accepted the snapshot now
-- sitting in DICT_KEY. It rides the dict for one reason: _store_rev is per-process,
-- so a worker whose read was served from the dict never learned that somebody else
-- bumped the counter, and its next compare-and-set went out with a base from process
-- start (see write_snapshot / refresh_store_rev).
local STORE_REV_KEY = "store_revision"

-- Cross-process token for the upstreams reconcile self-heal (contract 3.1):
-- written after every successful reconcile, read by init.lua's 30s timer. Same
-- unprefixed style as DICT_KEY / REV_KEY.
local UPS_REV_KEY = "upstreams_rev"

-- All three backends spell a lost compare-and-set with this marker; the write path
-- uses it to tell "the store refused my CAS" (a conflict the operator must see and
-- retry) from "the store is unreachable" (degrade to the file, keep serving).
local CONFLICT_MARK = "revision conflict"

local function is_conflict_error(err)
    return type(err) == "string" and err:find(CONFLICT_MARK, 1, true) ~= nil
end

local function dict()
    -- Unit runs outside nginx (luajit caliber) may not carry ngx at all; nil
    -- then means the file layer alone works, which is the documented degraded
    -- mode for a missing lua_shared_dict as well.
    if not ngx or not ngx.shared then return nil end
    return ngx.shared[DICT_NAME]
end

-- Persistent store layer (sqlite / postgres / file), resolved lazily and only
-- inside a real nginx worker. The unit suite has neither ngx.config nor
-- ngx.worker, so gating on those keeps every no-port test on exactly the file
-- path it has always used: the store is invisible there.
local _store_mod

local function store()
    if _store_mod ~= nil then return _store_mod end
    if not (ngx and ngx.config and ngx.worker) then
        -- Deliberately NOT cached: config_store is first loaded in init_by_lua,
        -- where ngx.worker does not exist yet. Caching this miss would make the
        -- store unreachable for the rest of the process and silently send every
        -- write down the legacy file path -- which keeps working, right up until
        -- you go looking for the database.
        return nil
    end
    -- init_by_lua needs its own guard, and the shape of the one above is why it was
    -- easy to miss: in that phase ngx.worker is a perfectly good table and
    -- ngx.worker.id() answers 0, so "is this a worker?" is not a question the
    -- module presence can answer. It is the *phase* that decides. Opening the store
    -- in the master hands every worker the same sqlite3* handle by fork inheritance,
    -- and store_sqlite's "the connection belongs to somebody else" guard cannot see
    -- it, because opened_path was inherited along with the handle. Measured on NW=8
    -- with a fresh database: 6 of 8 workers came up "database is locked" and degraded
    -- to the file for the rest of the process, so half of one container wrote sqlite
    -- and half wrote the file. init is also the phase where a write is impossible by
    -- definition -- the answer here is nil, so init only ever capture_env()s.
    if ngx.get_phase then
        local ok_phase, phase = pcall(ngx.get_phase)
        if ok_phase and phase == "init" then return nil end
    end
    if ngx.process_type then
        local ok_type, kind = pcall(ngx.process_type)
        if ok_type and kind == "no" then return nil end
    end
    local ok, mod = pcall(require, "resty.luarouter.store_dispatcher")
    if not ok or type(mod) ~= "table" or type(mod.load) ~= "function" then
        return nil
    end
    _store_mod = mod
    return mod
end

_M.store = store

--- Repoint this process's CAS base at the revision the durable layer answered with
--- for the snapshot that is currently in view.
---
--- This exists because _store_rev is per-process: a worker whose read was served
--- from the shdict never reached the store branch below, so it went on signing every
--- compare-and-set with the base it happened to hold when the process started -- and
--- in a two-writer race that is exactly the stale value that makes the CAS meaningless.
--- The shdict now carries the committed revision next to the snapshot (STORE_REV_KEY),
--- which a reader can pick up for the price of one shared-dict get. Only when that
--- companion token is absent -- an entry written before the key existed, or by a
--- worker whose store was unreachable -- does it fall back to asking the backend, and
--- that question is throttled to one per SNAPSHOT_TTL window per worker so the read
--- path never turns into a per-request database hit.
---
--- The base is deliberately *not* re-read at write time. A compare-and-set only means
--- something when its expected value is the one the caller actually built its change
--- on; refreshing it inside the write would quietly convert "lost the race, retry" into
--- "overwrite whatever the other writer committed".
local function refresh_store_rev(shared)
    if shared then
        local cached = shared:get(STORE_REV_KEY)
        local number = (type(cached) == "number") and cached or tonumber(cached)
        if number ~= nil then
            CS_FACADE._store_rev = number
            return number
        end
    end
    local now = (ngx and ngx.now) and ngx.now() or os.time()
    if CS_FACADE._store_rev_at and (now - CS_FACADE._store_rev_at) < CS_LEXICON.SNAPSHOT_TTL then
        return CS_FACADE._store_rev
    end
    CS_FACADE._store_rev_at = now
    local d = store()
    if d then
        local ok, current = pcall(d.revision)
        if ok then CS_FACADE._store_rev = current end
    end
    return CS_FACADE._store_rev
end

_M.refresh_store_rev = refresh_store_rev

-- Would a snapshot sitting in LMR_CONFIG_FILE be somebody's own edit rather
-- than our own (now stale) mirror? Two signals, because the revision counter
-- alone cannot tell them apart: a harness or operator replacing runtime.json
-- leaves the sidecar's digest pointing at bytes that are no longer there, and a
-- file written by another instance lands with a higher counter. When neither
-- holds the store is the answer, so a section deleted through the gateway must
-- NOT come back from the mirror.
local function file_was_edited_outside(db_rev)
    local ok, fmod = pcall(require, "resty.luarouter.store_file")
    if not ok or type(fmod) ~= "table" then return false end
    if type(fmod.edited_externally) == "function" and fmod.edited_externally() then
        return true, "LMR_CONFIG_FILE replaced outside the gateway"
    end
    local f_rev = nil
    if type(fmod.revision) == "function" then f_rev = fmod.revision() end
    if type(f_rev) == "number" and type(db_rev) == "number" and f_rev > db_rev then
        return true, "LMR_CONFIG_FILE revision ahead of the store"
    end
    return false
end

--- Layered read of the current snapshot (array form). Returns table or nil.
local function read_snapshot()
    local shared = dict()
    if shared then
        local raw = shared:get(DICT_KEY)
        if raw then
            local snap = cjson.decode(raw)
            if snap and not CS_LEXICON.snapshot_is_empty(snap) then
                refresh_store_rev(shared)
                return snap
            end
        end
    end

    -- The store sits between the in-process shdict and the legacy file: it is
    -- the durable, shareable source of truth. Whatever it cannot answer falls
    -- through to the file below, so a dead database degrades the store instead
    -- of taking the router down with it.
    local d = store()
    if d then
        local ok, snap, rev = pcall(d.load)
        -- An empty snapshot is the store saying "nothing here", not "the config is
        -- empty". A {} can be in there because an earlier build imported one (see
        -- migrate_once / legacy_snapshot_is_empty), and current() merges whole layers
        -- rather than fields, so letting it answer would silence the env layer for
        -- the life of the deployment -- including after the operator deletes the
        -- file, which used to be the documented way back to env defaults.
        if ok and snap and not CS_LEXICON.snapshot_is_empty(snap) then
            local edited, why = file_was_edited_outside(rev)
            if edited then
                -- Read the FILE, not the store: the whole point of noticing an
                -- external edit is to honour it, and re-adopting what the store
                -- already had would detect the edit and then ignore it.
                local adopted = nil
                local fok, fmod = pcall(require, "resty.luarouter.store_file")
                if fok and type(fmod) == "table" and type(fmod.load) == "function" then
                    local lok, fsnap = pcall(fmod.load)
                    if lok then adopted = fsnap end
                end
                if type(adopted) == "table" then snap = adopted end
                local saved, serr = d.save(snap, nil)
                if not saved then
                    if ngx and ngx.log then
                        pcall(ngx.log, ngx.WARN,
                            "luarouter config: adopting ", tostring(why),
                            " failed (", tostring(serr), "); the store keeps serving")
                    end
                elseif ngx and ngx.log then
                    pcall(ngx.log, ngx.NOTICE, "luarouter config: adopted ", why)
                    -- Re-write the mirror so the digest the sidecar recorded
                    -- matches the bytes again. Without this the file stays
                    -- permanently "externally edited" and every single read
                    -- re-adopts, re-saving the store on the request path.
                    if fok and type(fmod) == "table" and type(fmod.mirror) == "function" then
                        local aok, arv = pcall(d.revision)
                        if aok then fmod.mirror(snap, arv) end
                    end
                end
            end
            local rok, cur = pcall(d.revision)
            CS_FACADE._store_rev = (rok and cur) or nil
            return snap
        end
        if not ok and ngx and ngx.log then
            pcall(ngx.log, ngx.WARN, "luarouter config: store load failed (", tostring(snap), ")")
        end
    end
    local path = CS_ENV.env("LMR_CONFIG_FILE")
    if path then
        local now = (ngx and ngx.now) and ngx.now() or os.time()
        CS_FACADE._file_cache_at = CS_FACADE._file_cache_at or 0
        -- nil means "not looked yet"; false is the memoised "looked, no answer" (the
        -- file is missing, unreadable, or empty). Both answers and both non-answers
        -- are held for one TTL window, so a deployment with no LMR_CONFIG_FILE costs
        -- exactly the same one stat per window it did before this branch existed.
        if CS_FACADE._file_cache ~= nil and (now - CS_FACADE._file_cache_at) < CS_LEXICON.SNAPSHOT_TTL then
            return CS_FACADE._file_cache or nil
        end
        CS_FACADE._file_cache_at = now
        local f = io.open(path, "r")
        if f then
            local text = f:read("*a")
            f:close()
            local snap = cjson.decode(text or "")
            -- Same rule as the store branch above: an empty file has not answered, and
            -- handing {} to current() would take the whole env layer down with it.
            if CS_LEXICON.snapshot_is_hollow(snap) then
                CS_FACADE._file_cache = false
            else
                CS_FACADE._file_cache = snap
                return snap
            end
        else
            CS_FACADE._file_cache = false
        end
    end
    return nil
end

--- Write the snapshot into every available layer (dict first, then disk).
---
--- Returns (true) when the durable layer accepted the write (or there is no durable
--- layer to disagree), and (false, err, current_revision) when the store *refused* it
--- for a revision conflict. The distinction is the whole point: a refused
--- compare-and-set used to fall through into the plain file write below, so the
--- losing value landed on disk -- and then got adopted into the database on the next
--- cold start, which is the reverse of what CAS is for. The refused value now goes
--- nowhere at all, and the caller answers the operator with an error carrying the
--- current revision instead of a 200 holding a document the database has never seen.
---
--- A store that is merely unreachable is still the documented degraded path: it warns
--- and persists to the file, because "the database is down" must not take the config
--- plane down with it. Only a refusal -- the store answered and disagreed -- is
--- propagated.
local function write_snapshot(snap)
    local shared = dict()

    -- Durable first, then the in-process and human-readable layers. The store commits
    -- before anything publishes this snapshot, because a refused compare-and-set now
    -- aborts the write: had the dict been filled first, every worker and every reader
    -- would have served -- and the UI confirmed to the operator -- a value the
    -- database turned down, which is the half of the bug that made two sources of
    -- truth contradict each other.
    local d = store()
    local committed_rev = CS_FACADE._store_rev
    if d then
        -- The base comes from the read path; the store layer answers nil during a
        -- bootstrap replay (store_dispatcher.replaying), so a migration write can
        -- never be refused here.
        local ok, err, cur = d.save(snap, CS_FACADE._store_rev)
        if ok then
            committed_rev = cur
            CS_FACADE._store_rev = cur
        else
            if ngx and ngx.log then
                pcall(ngx.log, ngx.WARN, "luarouter config: store save failed: ", tostring(err))
            end
            if is_conflict_error(err) then
                -- The base really was stale. Adopt the revision the store just gave so
                -- the next attempt is signed correctly, drop this worker's file memo,
                -- and hand the caller an error carrying that revision -- "retry" has to
                -- be one action, not a guess. A replay (bootstrap / migration) is
                -- exempt: those are unconditional writes that must never fail startup.
                if cur ~= nil then CS_FACADE._store_rev = cur end
                CS_FACADE._file_cache = nil
                -- The shared snapshot is now provably behind the durable layer -- the
                -- store just said its own revision is not the one this copy was written
                -- with. Leaving it in place would be worse than merely untidy: every
                -- read short-circuits on the dict and re-pins the CAS base from the
                -- companion token, so the conflict would never clear and the gateway
                -- would reject every later save for the life of the process. Dropping
                -- both keys sends the next reader to the store, which is the only party
                -- that can say what the current document is.
                if shared then
                    shared:delete(DICT_KEY)
                    shared:delete(STORE_REV_KEY)
                end
                CS_FACADE._policy_view_dirty = true
                return false, err, cur
            end
            -- Unreachable rather than refusing: keep serving off the file, which is
            -- the documented degradation (a dead database must not take the router
            -- down), and forget a base we can no longer trust.
            committed_rev = nil
        end
    end

    if shared then
        local ok, err = shared:set(DICT_KEY, cjson.encode(snap))
        if not ok then
            ngx.log(ngx.WARN, "luarouter config dict write failed: ", err or "?")
        end
        if d and committed_rev ~= nil then
            -- The companion token: whatever reads this snapshot also learns the
            -- revision it was committed with, which is what keeps a second worker's
            -- CAS base honest (refresh_store_rev).
            local set_ok, set_err = shared:set(STORE_REV_KEY, tostring(committed_rev))
            if not set_ok then
                ngx.log(ngx.WARN, "luarouter config store revision write failed: ",
                    set_err or "?")
            end
        end
    end
    local path = CS_ENV.env("LMR_CONFIG_FILE")
    if path then
        -- No store at all (unit runs, degraded boot) is the legacy path: the file is
        -- then the only durable layer and keeps writing without a sidecar bump. A
        -- store that answered with a revision, on the other hand, owns the counter,
        -- so the file goes down the mirror path and stays digest-consistent with it.
        if d and committed_rev ~= nil then
            local fok, ferr = pcall(require, "resty.luarouter.store_file")
            local mok, merr
            if fok and type(ferr) == "table" and type(ferr.mirror) == "function" then
                mok, merr = ferr.mirror(snap, committed_rev)
            else
                mok, merr = CS_FACADE.persist(path, snap)
            end
            if not mok and ngx and ngx.log then
                pcall(ngx.log, ngx.WARN, "luarouter config mirror to ", path, " failed: ", tostring(merr))
            end
        else
            local ok, err = CS_FACADE.persist(path, snap)
            if not ok and ngx and ngx.log then
                pcall(ngx.log, ngx.WARN, "luarouter config persist to ", path, " failed: ", tostring(err))
            end
        end
    end
    CS_FACADE._file_cache = nil  -- force a re-read on next miss
    -- Invalidate the policy memo here and bump the revision last, so a reader
    -- that sees the new token also sees the new snapshot in the layers above.
    -- The dirty flag covers the writing worker (its own memo would otherwise
    -- serve the old policy for up to SNAPSHOT_TTL); incr is the atomic
    -- cross-process form - a per-process counter would let a second writer
    -- re-use the old token and leave the first writer's workers cached.
    CS_FACADE._policy_view_dirty = true
    if shared then
        local value, err = shared:incr(REV_KEY, 1, 0)
        if not value then
            ngx.log(ngx.WARN, "luarouter config revision bump failed: ", err or "?")
        end
    end
    return true
end

--- One refusal, worded for the operator. The backends already name the revision they
--- expected and the one they hold ("revision conflict: expected 3, current 4"); this
--- repeats the live number and the action, so a 409 is actionable from the message
--- alone instead of requiring a second GET to find out what to sign with.
---
--- CONFLICT_TAG is the stable marker the handlers match on to answer 409 rather than
--- 400. It is matched with plain substring finds and never derived from a backend's
--- own text, so a driver that rewords its error cannot silently turn a conflict into
--- a "your body was invalid" 400.
local CONFLICT_TAG = "config revision conflict:"

local function store_conflict_message(err, cur)
    return string.format("%s %s (current revision %s: re-read the document and retry)",
        CONFLICT_TAG,
        tostring(err or CONFLICT_MARK),
        cur == nil and "unknown" or tostring(cur))
end

--- True when a mutator's error came from the durable layer refusing a compare-and-set
--- (as opposed to a body that never should have been accepted).
function _M.is_store_conflict(err)
    return type(err) == "string" and err:find(CONFLICT_TAG, 1, true) ~= nil
end

--- Atomic write (tmp + rename), same as the Rust persist(). A missing parent
--- directory is created (mkdir -p) and the write retried once.
local function write_text(path, text)
    local f, err = io.open(path, "w")
    if not f then return nil, err end
    f:write(text)
    f:close()
    return true
end

function _M.persist(path, snap)
    local text, enc_err = cjson.encode(snap)
    if not text then return nil, "encode: " .. tostring(enc_err) end
    local dir = path:match("^(.*)/[^/]+$")
    local tmp = (path:gsub("[^/]+$", "")) .. "." .. (path:match("([^/]+)$") or "config.json") .. ".tmp"
    local ok, err = write_text(tmp, text)
    if not ok and dir and dir ~= "" then
        local executed = os.execute(string.format("mkdir -p '%s' 2>/dev/null", dir))
            or (io.popen(string.format("mkdir -p '%s' 2>/dev/null", dir)) ~= nil)
        if not executed then return nil, "create dir: " .. dir end
        ok, err = write_text(tmp, text)
    end
    if not ok then return nil, "write tmp: " .. tostring(err) end
    local renamed, rerr = os.rename(tmp, path)
    if not renamed then
        os.remove(tmp)
        return nil, "rename: " .. tostring(rerr)
    end
    return true
end

--- Current config as internal map form: env baseline overlaid with the
--- persisted/shared snapshot (same precedence as Rust: file wins when present
--- and valid; invalid file falls back to env).
-- One import of the legacy JSON snapshot into a fresh store, per process.
-- `migrate_from_file` is itself idempotent (a non-empty store is left alone),
-- so the guard here is about not re-stat-ing the file on every request.
--
-- Replay exemption matters here: a migration is a bootstrap write, and a
-- briefly unreachable store must degrade to the file, never fail startup.
local _migrated = false

function _M.migrate_once()
    if _migrated then return end
    local d = store()
    -- The flag is set only once a store is actually in hand. Setting it up front looks
    -- harmless but is not: config_store is first loaded in init_by_lua, where store()
    -- now answers nil on purpose (the store must not be opened before the fork). A
    -- migration attempt made there would mark the master as migrated and every worker
    -- would inherit that by fork, so the legacy file would never be imported for the
    -- life of the deployment -- the file keeps serving, and nobody goes looking for
    -- the database until long after it matters. Retrying is cheap: store() short
    -- circuits on the phase check before it does anything else.
    if not d then return end
    _migrated = true
    -- Importing {} is how a deployment loses its env layer forever. The dispatcher
    -- only asks "is the table still empty?" (mod.revision() ~= nil) and then copies
    -- whatever the file says, so on the common first-deployment shape -- the database
    -- opens fine, the JSON file is {} -- a vacuous document becomes the stored truth.
    -- current() then answers from that one layer and never consults env again, and the
    -- usual escape hatch stops working too: deleting runtime.json and its .rev leaves
    -- the {} in the database answering every read. Skipping the import is safe in both
    -- directions, because a file with nothing in it has nothing to migrate.
    local fok, fmod = pcall(require, "resty.luarouter.store_file")
    if fok and type(fmod) == "table" and type(fmod.load) == "function" then
        local lok, legacy = pcall(fmod.load)
        if lok and CS_LEXICON.snapshot_is_hollow(legacy) then
            if ngx and ngx.log then
                pcall(ngx.log, ngx.NOTICE,
                    "luarouter config: LMR_CONFIG_FILE carries no snapshot; the store ",
                    "stays empty and the env layer keeps answering")
            end
            return
        end
    end
    if type(d.begin_replay) == "function" then d.begin_replay() end
    local ok, imported, err = pcall(d.migrate_from_file)
    if type(d.end_replay) == "function" then d.end_replay() end
    if not ok then
        if ngx and ngx.log then
            pcall(ngx.log, ngx.WARN, "luarouter config: store migration errored (", tostring(imported), ")")
        end
        return
    end
    if imported and ngx and ngx.log then
        pcall(ngx.log, ngx.NOTICE, "luarouter config: imported LMR_CONFIG_FILE into the store",
            d.last_backup and (" (backup " .. d.last_backup .. ")") or "")
    end
end

--- Cross-process invalidation token, or nil when no shared dict can carry one
--- (then policy_state falls back to the plain TTL window).
function _M.policy_revision()
    local shared = dict()
    if not shared then return nil end
    local value = shared:get(REV_KEY)
    if value == nil then return "unset" end
    return tostring(value)
end

--- Token the 30s self-heal timer compares against the config revision
--- (init.lua). nil when no shared dict can carry it.
function _M.upstreams_revision()
    local shared = dict()
    if not shared then return nil end
    local value = shared:get(UPS_REV_KEY)
    if value == nil then return nil end
    return tostring(value)
end

--- True when the two-layer revision says a reconcile is overdue (a restart,
--- another worker's write, or a pool edit that dropped config rows).
function _M.upstreams_reconcile_due()
    local shared = dict()
    if not shared then return false end
    local applied = shared:get(UPS_REV_KEY)
    if applied == nil then return true end
    return tostring(applied) ~= tostring(CS_FACADE.policy_revision())
end

-- ------------------------------------------------- 跨子模块直调的原文 local
-- 这些函数在原文里是同文件 local 直调、从未挂在 _M 上；拆开后由调用方直接 require 本表
-- 调用（不经 facade，所以既不是新增导出、也不给单测多开一个可替换点）。
_M.UPS_REV_KEY = UPS_REV_KEY
_M.dict = dict
_M.read_snapshot = read_snapshot
_M.store_conflict_message = store_conflict_message
_M.write_snapshot = write_snapshot

return _M
