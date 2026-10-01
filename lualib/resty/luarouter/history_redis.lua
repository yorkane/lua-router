-- Redis backend for resty.luarouter.history.
--
-- Speaks RESP directly over a cosocket with no lua-resty-redis dependency: the
-- whole router runs on stdlib + hand-rolled wire code (see hash.lua for the
-- same choice), so adding a vendored client here would be one more upstream to
-- track for a dozen lines of protocol.
--
-- Shape: this module is a drop-in implementation of the memory store's function
-- set (get_conversation, store_conversation, link_item, ...), so registration is
-- exactly what doc/gap-history.md promises:
--
--     local redis = require "resty.luarouter.history_redis"
--     redis.configure({ host = ..., password = ..., prefix = ... })  -- from init_by_lua env
--     history.register_backend("redis", redis)
--
-- or just redis.install(). history.lua's store() consults BACKENDS before the
-- 501 gate, so backend_supported() and stats() flip to supported the moment this
-- registers, and router.lua call sites do not change.
--
-- Locking: the public API already runs every write through history.with_lock
-- (resty.lock on lr_locks, cross-process inside one nginx). The router is a
-- single instance, so that lock already serialises all writers and a Redis
-- SET NX lock here would be redundant latency on the hot path; the module
-- therefore takes no lock of its own. doc/gap-history-redis.md records the
-- tradeoff and the optional _M.lock() for a future shared-Redis fleet.
--
-- Error mapping (the err tables flow into router.lua's send_error verbatim):
--   * connect/send/receive failure or timeout -> 503 history_unavailable
--   * RESP error replies (WRONGPASS, WRONGTYPE, ...) -> 503 history_unavailable
--   * protocol desync / truncated stream -> 503 history_unavailable
-- The 501 history_backend_unsupported gate lives in history.lua and stays for
-- an unregistered backend; this file never emits 501 itself.

local cjson = require "cjson.safe"
local history = require "resty.luarouter.history"

local _M = { _VERSION = "0.1.0" }

local encode_json = history.encode
local json_decode = cjson.decode

local getenv = os.getenv

local function raw(name, default)
    local value = getenv(name)
    if value == nil or value == "" then
        return default
    end
    return value
end

local function num(name, default)
    local parsed = tonumber(raw(name))
    if parsed == nil then
        return default
    end
    return parsed
end

-- ==================================================================== config

local config

---Parse SMG_HISTORY_REDIS_* once. Kept separate from history.config() so this
---module can be reconfigured (and faked) by tests without disturbing the
---shared limits the memory backend reads.
---@return table
function _M.config()
    if not config then
        config = {
            host = raw("SMG_HISTORY_REDIS_HOST", "127.0.0.1"),
            port = num("SMG_HISTORY_REDIS_PORT", 6379),
            password = raw("SMG_HISTORY_REDIS_PASSWORD", nil),
            db = num("SMG_HISTORY_REDIS_DB", 0),
            prefix = raw("SMG_HISTORY_REDIS_PREFIX", "lrhist:"),
            timeout_ms = num("SMG_HISTORY_REDIS_TIMEOUT_MS", 2500),
            -- Record TTL for this backend. Separate from SMG_HISTORY_TTL_SECS
            -- (which the memory dict consumes) so one env does not silently
            -- drive two stores with different clocks.
            ttl_secs = num("SMG_HISTORY_REDIS_TTL_SECS", 0),
            keepalive_ms = num("SMG_HISTORY_REDIS_KEEPALIVE_MS", 30000),
            keepalive_pool = num("SMG_HISTORY_REDIS_KEEPALIVE_POOL", 8),
        }
        -- URL form wins per-component: redis://[:password@]host[:port][/db].
        local url = raw("SMG_HISTORY_REDIS_URL", nil)
        if url then
            _M.parse_url(url, config)
        end
    end
    return config
end

---Parse one redis://[:password@]host[:port][/db] URL over cfg; each component
---is taken from the URL only when the URL actually carries it. Exposed so the
---unit test can drive it without env (luajit has no os.setenv).
---@param url string
---@param cfg table
---@return table
function _M.parse_url(url, cfg)
    local body = url:gsub("^redis://", ""):gsub("^rediss://", "")
    local auth
    local at = body:find("@", 1, true)
    if at then
        auth = body:sub(1, at - 1)
        body = body:sub(at + 1)
    end
    if auth then
        local colon = auth:find(":", 1, true)
        -- user form (non-default user) is not supported by the plain AUTH
        -- command path; treat everything after ':' as the password.
        cfg.password = colon and auth:sub(colon + 1) or auth
    end
    local hostport = body:gsub("/.*$", "")
    local slash = body:find("/", 1, true)
    if slash then
        local db = tonumber(body:sub(slash + 1))
        if db then
            cfg.db = db
        end
    end
    local colon = hostport:find(":", 1, true)
    if colon then
        cfg.host = hostport:sub(1, colon - 1)
        local port = tonumber(hostport:sub(colon + 1))
        if port then
            cfg.port = port
        end
    else
        cfg.host = hostport
    end
    return cfg
end

function _M.reset_config()
    config = nil
end

---init_by_lua should call this while the real environment is still visible
---(same reason history.configure exists: nginx rebuilds the worker env after
---fork, so os.getenv here can come up empty on request threads).
---@param overrides table|nil
function _M.configure(overrides)
    local base = _M.config()
    if overrides == nil then
        return base
    end
    if type(overrides) ~= "table" then
        return nil, "overrides must be a table"
    end
    for k, v in pairs(overrides) do
        base[k] = v
    end
    return base
end

-- ============================================================ RESP protocol

---Encode one command (array of bulk strings) exactly like every RESP client:
-- *N\r\n followed by $len\r\n<payload>\r\n per argument. Lengths are byte
-- lengths (#arg), so payloads containing \r\n or NUL survive intact.
---@param args string[]
---@return string
function _M.encode_command(args)
    local out = { "*" .. tostring(#args) .. "\r\n" }
    for i = 1, #args do
        local arg = tostring(args[i])
        out[#out + 1] = "$" .. tostring(#arg) .. "\r\n" .. arg .. "\r\n"
    end
    return table.concat(out)
end

---Read one reply from a conn exposing receive("*l") / receive(n).
---@param conn table
---@return string typ @ "ok"|"err"|"int"|"str"|"nil"|"array"
---@return any val @ string|number|table|nil (false for a nil bulk reply)
---@return string|nil err
function _M.read_reply(conn)
    local line = conn:receive("*l")
    if line == nil then
        return nil, nil, "connection closed"
    end
    local tag = string.sub(line, 1, 1)
    local body = string.sub(line, 2)
    if tag == "+" then
        return "ok", body
    elseif tag == "-" then
        return "err", body
    elseif tag == ":" then
        local n = tonumber(body)
        if not n then
            return nil, nil, "bad integer reply: " .. body
        end
        return "int", n
    elseif tag == "$" then
        local n = tonumber(body)
        if not n then
            return nil, nil, "bad bulk length: " .. body
        end
        if n < 0 then
            return "nil", false
        end
        local data = conn:receive(n)
        if data == nil then
            return nil, nil, "truncated bulk reply"
        end
        conn:receive(2) -- trailing CRLF
        return "str", data
    elseif tag == "*" or tag == ">" then
        local n = tonumber(body)
        if not n then
            return nil, nil, "bad array length: " .. body
        end
        if n < 0 then
            return "nil", false
        end
        local items = {}
        for i = 1, n do
            local typ, val, err = _M.read_reply(conn)
            if typ == nil then
                return nil, nil, err
            end
            items[i] = { typ = typ, val = val }
        end
        return "array", items
    end
    return nil, nil, "unknown reply tag: " .. tostring(tag)
end

-- ================================================================ transport

---acquire() must return a conn that is already AUTHed/SELECTed, exposing
---send(str) and receive(spec) with the cosocket surface. release(conn, ok)
---returns it to the pool or tears it down. Tests inject a fake here so the
---whole protocol path (encode -> parse -> reply) runs over real RESP bytes
---without needing a socket.
local transport

local function cosocket_transport()
    return {
        acquire = function()
            local cfg = _M.config()
            local sock = ngx.socket.tcp()
            sock:settimeouts(cfg.timeout_ms, cfg.timeout_ms, cfg.timeout_ms)
            local ok, err = sock:connect(cfg.host, cfg.port)
            if not ok then
                return nil, "connect " .. cfg.host .. ":" .. cfg.port
                    .. " failed: " .. tostring(err)
            end
            if cfg.password then
                local _
                _, err = sock:send(_M.encode_command({ "AUTH", cfg.password }))
                if err then
                    sock:close()
                    return nil, "auth send failed: " .. tostring(err)
                end
                local typ, val = _M.read_reply(sock)
                if typ ~= "ok" then
                    sock:close()
                    return nil, "auth failed: " .. tostring(val or typ)
                end
            end
            if cfg.db and cfg.db > 0 then
                local _
                _, err = sock:send(_M.encode_command({ "SELECT", tostring(cfg.db) }))
                if err then
                    sock:close()
                    return nil, "select send failed: " .. tostring(err)
                end
                local typ = _M.read_reply(sock)
                if typ ~= "ok" then
                    sock:close()
                    return nil, "select db " .. cfg.db .. " failed"
                end
            end
            return sock
        end,
        release = function(conn, reusable)
            if not reusable or not conn.setkeepalive then
                pcall(function() conn:close() end)
                return
            end
            local cfg = _M.config()
            local ok = conn:setkeepalive(cfg.keepalive_ms, cfg.keepalive_pool)
            if not ok then
                pcall(function() conn:close() end)
            end
        end,
    }
end

---Swap the connection layer (tests). Passing nil restores the cosocket default.
---@param t table|nil @ {acquire=function, release=function} or nil
function _M.set_transport(t)
    if t == nil then
        transport = nil
        return
    end
    if type(t.acquire) ~= "function" then
        return nil, "transport needs an acquire function"
    end
    transport = t
    t.reusable = t.reusable ~= false
end

local function active_transport()
    if transport then
        return transport
    end
    if _G.ngx and ngx.socket and ngx.socket.tcp then
        transport = cosocket_transport()
        return transport
    end
    return nil
end

local function unavailable(msg)
    return history.error(503, "history_unavailable", "redis: " .. msg)
end

---Run one batch of commands on one connection (pipelined: one round trip) and
---return the decoded replies. Stale pooled connections are retried once with a
---fresh one; RESP error replies are surfaced as errors without retry, since
---retrying a semantic failure only doubles the latency.
---@param cmds table[] @ array of arg tables
---@return table[]|nil @ replies [{typ, val}]
---@return table|nil err
function _M.exec(cmds)
    local t = active_transport()
    if not t then
        return nil, unavailable("no cosocket and no transport injected "
            .. "(unit-test this module with set_transport, run it under openresty)")
    end
    local last_err
    for attempt = 1, 2 do
        local conn, aerr = t.acquire()
        if not conn then
            last_err = unavailable(aerr)
            break
        end
        local parts = {}
        for i = 1, #cmds do
            parts[i] = _M.encode_command(cmds[i])
        end
        -- cosocket's send returns bytes, err; only err matters here.
        local _, serr = conn:send(table.concat(parts))
        if serr then
            pcall(function() conn:close() end)
            last_err = unavailable("send failed: " .. tostring(serr))
        else
            local replies = {}
            local rerr
            for i = 1, #cmds do
                local typ, val, err = _M.read_reply(conn)
                if typ == nil then
                    rerr = unavailable("reply read failed: " .. tostring(err))
                    break
                end
                replies[i] = { typ = typ, val = val }
            end
            if not rerr then
                -- Even an error reply leaves the stream aligned, so the
                -- connection stays poolable unless the transport opts out.
                t.release(conn, t.reusable ~= false)
                return replies
            end
            pcall(function() conn:close() end)
            last_err = rerr
        end
        -- transport-level breakage above: the loop drops the connection and
        -- retries once with a fresh acquire. Writes can therefore be replayed
        -- after a mid-batch timeout; SET/ZADD NX/ZREM/DEL are all idempotent
        -- under replay, and INCR only drives the monotonic ordering clock.
    end
    return nil, last_err
end

---Convenience: run one command, map the first reply through a check.
---@param args string[]
---@return string|number|table|false|nil @ decoded val (nil on error)
---@return table|nil err
function _M.cmd(args)
    local replies, err = _M.exec({ args })
    if not replies then
        return nil, err
    end
    local r = replies[1]
    if r.typ == "err" then
        return nil, unavailable(tostring(r.val))
    end
    if r.typ == "nil" then
        return false
    end
    return r.val
end

local function first_err_of(replies, upto)
    for i = 1, upto or #replies do
        if replies[i].typ == "err" then
            return unavailable(tostring(replies[i].val))
        end
    end
    return nil
end

-- ================================================================= key layout
--
-- <p>cv:<id>   string   conversation record (JSON)
-- <p>it:<id>   string   conversation item record (JSON)
-- <p>lx:<conv> zset     ordered item index, member = item_id, score = seq
-- <p>rs:<id>   string   stored response record (JSON, raw_json preserved)
-- <p>zconv     zset     LRU clock for conversations (score = last-touch seq)
-- <p>zresp     zset     created_at clock for responses (score = created_at)
-- <p>seq       string   global INCR counter (never expires)
--
-- The reverse index rv: that the memory store needs is free here: ZSCORE gives
-- the cursor lookup directly, so unlink/idempotency checks are one command.

local function pfx()
    return _M.config().prefix
end

local function k_conv(id) return pfx() .. "cv:" .. id end
local function k_item(id) return pfx() .. "it:" .. id end
local function k_links(conv) return pfx() .. "lx:" .. conv end
local function k_resp(id) return pfx() .. "rs:" .. id end
local K_LRU_CONV = "zconv"
local K_LRU_RESP = "zresp"
local K_SEQ = "seq"

local function k_lru_conv() return pfx() .. K_LRU_CONV end
local function k_lru_resp() return pfx() .. K_LRU_RESP end
local function k_seq() return pfx() .. K_SEQ end

---Score string identical to history.score(), so the public list_items cursor
---(which compares score strings for equality) cannot tell the backends apart.
---@param sequence number
---@param item_id string
---@return string
local function score_str(sequence, item_id)
    return string.format("%012d ", math.floor(sequence)) .. item_id
end

local function ttl()
    local t = _M.config().ttl_secs
    if t and t > 0 then
        return t
    end
    return nil
end

local function next_seq()
    local v, err = _M.cmd({ "INCR", k_seq() })
    if not v then
        return nil, err
    end
    return v
end

-- ------------------------------------------------------------ conversations

local function set_with_ttl(key, json)
    local args = { "SET", key, json }
    local t = ttl()
    if t then
        args[#args + 1] = "EX"
        args[#args + 1] = tostring(t)
    end
    local v, err = _M.cmd(args)
    if err then
        return nil, err
    end
    return v
end

function _M.get_conversation(id)
    local rawv, err = _M.cmd({ "GET", k_conv(id) })
    if err then
        return nil, err
    end
    if rawv == false then
        return nil
    end
    local conv = json_decode(rawv)
    if type(conv) ~= "table" then
        return nil
    end
    -- LRU touch, same observable effect as the memory store bumping sq:<id>.
    local seq = next_seq()
    if seq then
        _M.cmd({ "ZADD", k_lru_conv(), tostring(seq), id })
    end
    return conv
end

function _M.store_conversation(conv)
    local encoded = encode_json(conv)
    if not encoded then
        return nil, history.error(500, "history_storage_error",
            "failed to encode conversation")
    end
    local ok, err = set_with_ttl(k_conv(conv.id), encoded)
    if err then
        return nil, err
    end
    local seq = next_seq()
    if seq then
        _M.cmd({ "ZADD", k_lru_conv(), tostring(seq), conv.id })
    end
    return conv
end

---Evict LRU conversations down to ~90% of the cap (same hysteresis as memory).
function _M.enforce_conversation_cap()
    local cap = history.config().max_conversations
    if cap <= 0 then
        return 0
    end
    local count, cerr = _M.cmd({ "ZCARD", k_lru_conv() })
    if not count or type(count) ~= "number" then
        return 0, cerr
    end
    if count < cap then
        return 0
    end
    local target = cap - 1 - math.floor(cap * 0.1)
    if target < 0 then
        target = 0
    end
    local need = count - target
    local victims, verr = _M.cmd({ "ZRANGE", k_lru_conv(), "0", tostring(need - 1) })
    if not victims then
        return 0, verr
    end
    local dropped = 0
    for i = 1, #victims do
        local id = victims[i].val
        if victims[i].typ == "str" and id then
            _M.drop_conversation(id)
            dropped = dropped + 1
        end
    end
    return dropped
end

function _M.drop_conversation(id)
    local members = _M.cmd({ "ZRANGE", k_links(id), "0", "-1" })
    local cmds = {}
    if type(members) == "table" then
        for i = 1, #members do
            local item_id = members[i].val
            if members[i].typ == "str" and item_id then
                -- Reclaim the record with the link, matching the memory store's
                -- documented deviation (shared items die with either conversation).
                cmds[#cmds + 1] = { "DEL", k_item(item_id) }
            end
        end
    end
    cmds[#cmds + 1] = { "DEL", k_conv(id) }
    cmds[#cmds + 1] = { "DEL", k_links(id) }
    cmds[#cmds + 1] = { "ZREM", k_lru_conv(), id }
    local replies, err = _M.exec(cmds)
    if not replies then
        return nil, err
    end
    local eerr = first_err_of(replies)
    if eerr then
        return nil, eerr
    end
    return true
end

-- ------------------------------------------------------------------- items

---Idempotent link: an existing member keeps its position (same observable
---behaviour as the memory store's "already linked" branch). The public API
---holds history.with_lock, so the ZSCORE/ZADD window cannot lose updates.
function _M.link_item(conv_id, item_id, created_at)
    local cur, zerr = _M.cmd({ "ZSCORE", k_links(conv_id), item_id })
    if cur == nil then
        return nil, zerr
    end
    if cur ~= false then
        -- Already a member: keep its position (memory's "already linked"
        -- branch), and hand back the same score string the memory store would.
        return score_str(tonumber(cur) or 0, item_id)
    end
    local seq, serr = next_seq()
    if not seq then
        return nil, serr
    end
    local cmds = { { "ZADD", k_links(conv_id), "NX", tostring(seq), item_id } }
    local t = ttl()
    if t then
        cmds[#cmds + 1] = { "EXPIRE", k_links(conv_id), tostring(t) }
    end
    local replies, err = _M.exec(cmds)
    if not replies then
        return nil, err
    end
    local eerr = first_err_of(replies)
    if eerr then
        return nil, eerr
    end
    -- Cap: drop oldest links (and their records), as the memory store does.
    -- These reads are best-effort: a failure here never loses the link that
    -- was just added, so the public API cannot observe a half-written index.
    local cap = history.config().max_items_per_conversation
    if cap > 0 then
        local count = _M.cmd({ "ZCARD", k_links(conv_id) })
        if type(count) == "number" and count > cap then
            local excess = count - cap
            local victims = _M.cmd({ "ZRANGE", k_links(conv_id), "0", tostring(excess - 1) })
            if type(victims) == "table" and #victims > 0 then
                local drop = {}
                for i = 1, #victims do
                    local victim = victims[i].val
                    if victims[i].typ == "str" and victim then
                        drop[#drop + 1] = { "DEL", k_item(victim) }
                    end
                end
                drop[#drop + 1] = { "ZREMRANGEBYRANK", k_links(conv_id), "0",
                    tostring(excess - 1) }
                _M.exec(drop)
            end
        end
    end
    return score_str(seq, item_id)
end

function _M.get_item(item_id)
    local rawv, err = _M.cmd({ "GET", k_item(item_id) })
    if err then
        return nil, err
    end
    if rawv == false then
        return nil
    end
    return json_decode(rawv)
end

function _M.store_item(item)
    local encoded = encode_json(item)
    if not encoded then
        return nil, history.error(500, "history_storage_error",
            "failed to encode item")
    end
    local _, err = set_with_ttl(k_item(item.id), encoded)
    if err then
        return nil, err
    end
    return item
end

function _M.is_item_linked(conv_id, item_id)
    local cur, err = _M.cmd({ "ZSCORE", k_links(conv_id), item_id })
    if err then
        return false, err
    end
    return type(cur) == "string"
end

function _M.unlink_item(conv_id, item_id)
    local removed, err = _M.cmd({ "ZREM", k_links(conv_id), item_id })
    if err then
        return false, err
    end
    return type(removed) == "number" and removed > 0
end

---Oldest-first entries with memory-identical score strings.
function _M.index(conv_id)
    local items = _M.cmd({ "ZRANGE", k_links(conv_id), "0", "-1", "WITHSCORES" })
    local entries = {}
    if type(items) ~= "table" then
        return entries
    end
    local i = 1
    while i + 1 <= #items do
        local member = items[i]
        local sc = items[i + 1]
        if member.typ == "str" and sc.typ == "str" then
            entries[#entries + 1] = {
                score = score_str(tonumber(sc.val) or 0, member.val),
                item_id = member.val,
            }
        end
        i = i + 2
    end
    return entries
end

function _M.score_of(conv_id, item_id)
    local sc = _M.cmd({ "ZSCORE", k_links(conv_id), item_id })
    if type(sc) ~= "string" then
        return nil
    end
    return score_str(tonumber(sc) or 0, item_id)
end

-- --------------------------------------------------------------- responses

function _M.get_response(id)
    local rawv, err = _M.cmd({ "GET", k_resp(id) })
    if err then
        return nil, err
    end
    if rawv == false then
        return nil
    end
    return json_decode(rawv)
end

function _M.store_response(rec)
    local encoded = encode_json(rec)
    if not encoded then
        return nil, history.error(500, "history_storage_error",
            "failed to encode response")
    end
    local _, err = set_with_ttl(k_resp(rec.id), encoded)
    if err then
        return nil, err
    end
    _M.cmd({ "ZADD", k_lru_resp(), tostring(rec.created_at or 0), rec.id })
    return rec
end

---Returns true when the record existed, matching memory's contract that
---delete_response's boolean drives the public 404 (unlike memory, the clock
---entry is removed in the same pipeline).
function _M.delete_response(id)
    local replies, err = _M.exec({
        { "DEL", k_resp(id) },
        { "ZREM", k_lru_resp(), id },
    })
    if not replies then
        return nil, err
    end
    if replies[1].typ == "err" then
        return nil, unavailable(tostring(replies[1].val))
    end
    return type(replies[1].val) == "number" and replies[1].val > 0
end

function _M.enforce_response_cap()
    local cap = history.config().max_responses
    if cap <= 0 then
        return 0
    end
    local count = _M.cmd({ "ZCARD", k_lru_resp() })
    if type(count) ~= "number" or count < cap then
        return 0
    end
    local target = cap - 1 - math.floor(cap * 0.1)
    if target < 0 then
        target = 0
    end
    local need = count - target
    local victims = _M.cmd({ "ZRANGE", k_lru_resp(), "0", tostring(need - 1) })
    local dropped = 0
    if type(victims) == "table" then
        for i = 1, #victims do
            if victims[i].typ == "str" and victims[i].val then
                _M.delete_response(victims[i].val)
                dropped = dropped + 1
            end
        end
    end
    return dropped
end

-- ------------------------------------------------------------- operations

---Counters for history.stats()'s backend hook.
---@return table
function _M.stats()
    local conv = _M.cmd({ "ZCARD", k_lru_conv() })
    local resp = _M.cmd({ "ZCARD", k_lru_resp() })
    return {
        backend = "redis",
        supported = true,
        conversations = type(conv) == "number" and conv or nil,
        responses = type(resp) == "number" and resp or nil,
    }
end

---Capacity sweeps for the timer hook.
---@return table
function _M.sweep()
    local dc = _M.enforce_conversation_cap() or 0
    local dr = _M.enforce_response_cap() or 0
    return { dropped_conversations = dc, dropped_responses = dr }
end

---Delete every key under the configured prefix, in SCAN pages so a keyspace of
---another tenant on a shared Redis is never blocked by a KEYS scan.
---@return boolean
function _M.flush_all()
    local pattern = pfx() .. "*"
    local cursor = "0"
    repeat
        local reply, err = _M.cmd({ "SCAN", cursor, "MATCH", pattern, "COUNT", "500" })
        if not reply then
            return false, err
        end
        if type(reply) ~= "table" or #reply < 2 then
            return false, unavailable("unexpected SCAN reply")
        end
        cursor = reply[1].val
        local keys = reply[2].typ == "array" and reply[2].val or {}
        if #keys > 0 then
            local del = { "DEL" }
            for i = 1, #keys do
                if keys[i].typ == "str" then
                    del[#del + 1] = keys[i].val
                end
            end
            if #del > 1 then
                local _, derr = _M.cmd(del)
                if derr then
                    return false, derr
                end
            end
        end
    until cursor == "0"
    return true
end

---One-shot liveness probe used by the smoke test and (optionally) an admin
---route; returns true, nil when AUTH/SELECT/PING all pass.
function _M.ping()
    local v, err = _M.cmd({ "PING" })
    if err then
        return nil, err
    end
    return v == "PONG", nil, v
end

---Register this table under the name history.lua's 501 gate reserves for it.
function _M.install()
    return history.register_backend("redis", _M)
end

-- Optional distributed lock (see module header for why the store does not use
-- it): SET key val NX PX + token-compared delete, so a follower of a crashed
-- leader can take over after the lease. Only exercised by its own unit tests.
local lock_seq = 0

---@param name string
---@param ttl_ms number|nil @ lease length, default 10000
---@return table|nil @ {token, key} held, nil when not held or on error
function _M.try_lock(name, ttl_ms)
    lock_seq = lock_seq + 1
    local token = tostring(_G.ngx and ngx.worker and ngx.worker.pid() or 0)
        .. "-" .. tostring(_M.now_ms and _M.now_ms() or os.time() * 1000)
        .. "-" .. tostring(lock_seq)
    local key = pfx() .. "lock:" .. name
    local v, err = _M.cmd({ "SET", key, token, "NX", "PX", tostring(ttl_ms or 10000) })
    if err then
        return nil, err
    end
    if v == "OK" then
        return { key = key, token = token }
    end
    return nil
end

---Release with a Lua compare-and-delete so we never unlock someone else's lease.
---@param held table
---@return boolean|nil, table|nil
function _M.release_lock(held)
    local v, err = _M.cmd({ "EVAL",
        "if redis.call('get',KEYS[1])==ARGV[1] then return redis.call('del',KEYS[1]) "
        .. "else return 0 end",
        "1", held.key, held.token })
    if err then
        return nil, err
    end
    return v == 1 or v == "1" or (type(v) == "number" and v > 0)
end

return _M
