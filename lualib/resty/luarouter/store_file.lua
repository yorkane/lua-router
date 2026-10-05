-- Persistent snapshot backend on top of LMR_CONFIG_FILE.
--
-- This is the rollback path: it must reproduce the pre-database behaviour
-- byte for byte, so the config JSON it writes carries exactly the keys it
-- carried before the store layer existed. The CAS revision therefore does NOT
-- live inside that JSON - it lives in a sidecar next to it. Losing the sidecar
-- costs CAS (the next write is unconditional, like today), never correctness
-- of the config itself.

local cjson = require "cjson.safe"

local _M = {}
_M.name = "file"

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

local function path()
    return env("LMR_CONFIG_FILE")
end

local function rev_path(base)
    return base .. ".rev"
end

-- Forward declaration: atomic() is defined further down, and a plain reference
-- from here would compile to a global read and blow up with "attempt to call a
-- nil value" at the first save.
local atomic

--- djb2 mod 2^32, pure Lua 5.1 (no bitwise ops, and the unit suite has no ngx).
--- h*33 stays under 2^53 so the modulo is exact in a double. This is a change
--- detector, not a security primitive: it only has to answer "are the bytes on
--- disk still the ones we wrote?".
local function digest(text)
    local h = 5381
    for i = 1, #text do
        h = (h * 33 + text:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

_M.digest = digest

--- sidecar 读成 (rev, digest)。digest 缺省是 nil —— 老 sidecar 只写了数字，
--- 那样就退化成「只有 revision」的老行为，不是错误。
local function read_sidecar(base)
    local f = io.open(rev_path(base), "r")
    if not f then return nil, nil end
    local raw = f:read("*a")
    f:close()
    local number, dg = string.match(trim(raw or "") or "", "^(%-?%d+)%s*(%x*)")
    if not number then return nil, nil end
    number = tonumber(number)
    if not number then return nil, nil end
    return math.floor(number), (dg ~= "" and dg or nil)
end

local function write_sidecar(base, rev, dg)
    return atomic(rev_path(base), dg and (tostring(rev) .. " " .. dg) or tostring(rev))
end

--- The bytes currently on disk for the config file, or nil when unreadable.
local function config_text(base)
    local f = io.open(base, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

--- True when the snapshot file was replaced by somebody other than us: the
--- sidecar records the digest of the bytes we wrote, so an operator (or a test
--- harness) dropping in a different runtime.json leaves the digest stale while
--- the revision counter alone would still look "in sync". The store layer uses
--- this to tell "the operator edited the file" from "we are merely behind".
function _M.edited_externally()
    local base = path()
    if not base then return false end
    local _, recorded = read_sidecar(base)
    if recorded == nil then return false end
    local text = config_text(base)
    if text == nil then return false end
    return digest(text) ~= recorded
end

local function now()
    return (ngx and ngx.now) and math.floor(ngx.now()) or os.time()
end

local function write_text(target, text)
    local f, err = io.open(target, "w")
    if not f then return nil, err end
    f:write(text)
    f:close()
    return true
end

--- tmp + rename, the same shape _M.persist uses. Returns (ok, err).
function atomic(target, text)
    local dir = target:match("^(.*)/[^/]+$")
    local leaf = target:match("([^/]+)$") or "config.json"
    local tmp = target:gsub("[^/]+$", "") .. "." .. leaf .. ".tmp"
    local ok, err = write_text(tmp, text)
    if not ok and dir and dir ~= "" then
        os.execute(string.format("mkdir -p '%s' 2>/dev/null", dir))
        ok, err = write_text(tmp, text)
    end
    if not ok then
        os.remove(tmp)
        return nil, "write tmp: " .. tostring(err)
    end
    local renamed, rerr = os.rename(tmp, target)
    if not renamed then
        os.remove(tmp)
        return nil, "rename: " .. tostring(rerr)
    end
    return true
end

--- The revision currently persisted, or nil when there is no usable sidecar
--- (= no CAS information, exactly the pre-store state).
function _M.revision()
    local base = path()
    if not base then return nil end
    local number = read_sidecar(base)
    if number == nil then return nil end
    return number
end

function _M.load()
    local base = path()
    if not base then return nil, "no LMR_CONFIG_FILE" end
    local f = io.open(base, "r")
    if not f then return nil, "no snapshot file" end
    local raw = f:read("*a")
    f:close()
    local snap = cjson.decode(raw or "")
    if not snap then return nil, "invalid snapshot json" end
    return snap, nil, _M.revision()
end

--- Save the whole snapshot.
---   expect_revision nil  -> unconditional write (replay / no CAS info)
---   expect_revision n    -> compare-and-set; a mismatch returns (false, err, cur)
--- The config JSON bytes never depend on expect_revision.
function _M.save(snap, expect_revision)
    local base = path()
    if not base then return false, "no LMR_CONFIG_FILE" end
    local cur = _M.revision()
    local prev_digest = read_sidecar(base)
    if expect_revision ~= nil and cur ~= nil and cur ~= expect_revision then
        return false, string.format("revision conflict: expected %s, current %s",
            tostring(expect_revision), tostring(cur)), cur
    end
    local text, enc_err = cjson.encode(snap)
    if not text then return false, "encode: " .. tostring(enc_err) end
    -- Write the revision FIRST: a crash between the two renames leaves the
    -- config at the old revision and the sidecar one ahead, which the next
    -- CAS reports as a conflict (safe direction: operator retries).
    local next_rev = (cur or 0) + 1
    local dg = digest(text)
    local ok, err = write_sidecar(base, next_rev, dg)
    if not ok then return false, "write revision: " .. tostring(err) end
    ok, err = atomic(base, text)
    if not ok then
        -- Restore the sidecar (revision AND its digest) so a failed save leaves
        -- no trace: not a bumped revision, and not a digest that would make the
        -- next load think the operator had edited the file.
        if cur ~= nil then write_sidecar(base, cur, prev_digest) end
        return false, "write snapshot: " .. tostring(err)
    end
    return true, nil, next_rev
end

--- True when this backend can carry a snapshot at all.
function _M.available()
    return path() ~= nil
end

--- Write the snapshot as a *mirror* of another backend instead of as an
--- independent copy. The revision sidecar is pinned to `rev` verbatim rather
--- than bumped, so the mirror and the authoritative store stay on one counter
--- and `edited_externally()` still answers honestly afterwards. Used by
--- config_store after it has already committed to the database.
function _M.mirror(snap, rev)
    local base = path()
    if not base then return false, "no LMR_CONFIG_FILE" end
    local text, enc_err = cjson.encode(snap)
    if not text then return false, "encode: " .. tostring(enc_err) end
    local ok, err = write_sidecar(base, rev or 0, digest(text))
    if not ok then return false, "write revision: " .. tostring(err) end
    ok, err = atomic(base, text)
    if not ok then return false, "write snapshot: " .. tostring(err) end
    return true, nil, rev
end

function _M.close() end

return _M
