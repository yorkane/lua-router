-- History store: conversations, conversation items and responses.
--
-- Storage layer only. Nothing in here reads ngx.req or writes an HTTP response,
-- so router.lua can wire the endpoints later without this module changing; every
-- function returns
--     value, nil    on success
--     nil, err      on failure, with err = {status, code, message, param}
-- which is exactly the shape router.lua's send_error() consumes (see the
-- endpoint -> function table in doc/gap-history.md).
--
-- Parity references, read at authoring time:
--   * data-connector-1.0.0/src/core.rs      object model, id formats, ListParams
--   * data-connector-1.0.0/src/memory.rs    the memory backend semantics we copy
--   * data-connector-1.0.0/src/noop.rs      what --history-backend none means
--   * gateway/src/main.rs:482               --history-backend value set + default
--   * gateway/src/routers/conversations/handlers.rs   validation + list envelope
--   * gateway/src/routers/persistence_utils.rs        item <-> JSON rendering
--
-- Deliberate deviations are documented in doc/gap-history.md and marked
-- "DEVIATION" where they appear in the code.

local cjson = require "cjson.safe"

local _M = { _VERSION = "0.1.0" }

local json_encode = cjson.encode
local json_decode = cjson.decode

-- ==================================================================== config

-- Shared dict that backs the memory store. Not declared by this module: the
-- nginx conf has to say `lua_shared_dict lr_history 10m;` (see the module docs)
-- and a missing declaration surfaces as 503 history_unavailable rather than as
-- a nil-index error on the first request.
_M.DICT = "lr_history"
_M.LOCK_DICT = "lr_locks"
_M.LOCK_KEY = "history"

local getenv = os.getenv

local function raw(name, default)
    local value = getenv(name)
    if value == nil or value == "" then
        return default
    end
    return value
end

local function num(name, default)
    local value = raw(name)
    local parsed = tonumber(value)
    if parsed == nil then
        return default
    end
    return parsed
end

-- Same collapse-to-default rule as config.lua's one_of, so an unknown
-- --history-backend value boots as `memory` exactly like main.rs's `_ => Memory`.
local function one_of_value(value, default, allowed)
    if value == nil then
        return default
    end
    value = string.lower(string.gsub(value, "^%s*(.-)%s*$", "%1"))
    for i = 1, #allowed do
        if allowed[i] == value then
            return value
        end
    end
    return default
end

local function one_of(name, default, allowed)
    return one_of_value(raw(name), default, allowed)
end

-- Value set and default of the Rust CLI flag.
_M.BACKEND_VALUES = { "memory", "none", "redis", "postgres", "oracle" }
_M.DEFAULT_BACKEND = "memory"

---Resolve one --history-backend value the way main.rs does: trim, lowercase, and
---collapse anything unknown to memory.
---@param value string|nil
---@return string
function _M.resolve_backend(value)
    return one_of_value(value, _M.DEFAULT_BACKEND, _M.BACKEND_VALUES)
end
-- Backends the Rust gateway can reach but this Lua router cannot yet.
_M.UNSUPPORTED_BACKENDS = { redis = true, postgres = true, oracle = true }

-- OpenAI Conversations API limits. MAX_METADATA_PROPERTIES and the item-type
-- tables are the Rust handler's constants verbatim.
_M.MAX_METADATA_PROPERTIES = 16
-- DEVIATION: handlers.rs hardcodes MAX_ITEMS_PER_REQUEST = 20. The 100 default
-- here follows the list/page limit instead, and is an env knob so the operator
-- can dial it back to Rust's 20 for a strict parity run.
_M.MAX_ITEMS_PER_REQUEST_DEFAULT = 100
_M.DEFAULT_PAGE_SIZE = 100
_M.MAX_PAGE_SIZE = 1000

local config

---Parse (once) the SMG_HISTORY_* knobs. Independent of config.lua so this
---module can be loaded by a unit test that never touches the router config.
---@return table
function _M.config()
    if not config then
        config = {
            backend = one_of("SMG_HISTORY_BACKEND", "memory", _M.BACKEND_VALUES),
            max_conversations = num("SMG_HISTORY_MAX_CONVERSATIONS", 10000),
            max_items_per_conversation = num("SMG_HISTORY_MAX_ITEMS_PER_CONVERSATION", 1000),
            max_responses = num("SMG_HISTORY_MAX_RESPONSES", 10000),
            max_items_per_request = num("SMG_HISTORY_MAX_ITEMS_PER_REQUEST",
                                        _M.MAX_ITEMS_PER_REQUEST_DEFAULT),
            ttl_secs = num("SMG_HISTORY_TTL_SECS", 0),
        }
        if config.max_items_per_request < 1 then
            config.max_items_per_request = 1
        end
        if config.ttl_secs < 0 then
            config.ttl_secs = 0
        end
    end
    return config
end

---Drop the cached config. Tests use it to re-read the environment.
function _M.reset_config()
    config = nil
end

---Set the config from init_by_lua, where the real environment is still visible.
---
--- nginx rebuilds the worker environment from scratch, so an SMG_HISTORY_* name is
--- gone by the time a request handler reaches os.getenv unless the conf declares it
--- with an `env` directive. config.lua gets away with it because init_by_lua parses
--- it before the fork; this module parses lazily, so router.lua should call
--- configure() in the same phase instead of relying on the environment.
---@param overrides table @ keys from _M.config(); nil leaves the env fallback
function _M.configure(overrides)
    if type(overrides) ~= "table" then
        return nil, "overrides must be a table"
    end
    local base = _M.config()
    for k, v in pairs(overrides) do
        base[k] = v
    end
    if type(base.backend) == "string" then
        base.backend = _M.resolve_backend(base.backend)
    end
    return base
end

---@return string @ configured backend name
function _M.backend()
    return _M.config().backend
end

---Whether the configured backend can serve requests. A name in the registry counts
---as supported, so an operator who registers redis/postgres/oracle later flips this
---without touching the gate.
---@return boolean, table|nil @ supported, err (501 for an unregistered built-in)
function _M.backend_supported()
    local name = _M.backend()
    if _M.BACKENDS[name] then
        return true
    end
    if _M.UNSUPPORTED_BACKENDS[name] then
        return false, _M.error(501, "history_backend_unsupported",
            "history backend '" .. name
            .. "' is not implemented in the Lua router; use memory or none")
    end
    return true
end

-- ============================================================ pluggable backends

-- Registry for future backends. An implementation is a table exposing the same
-- function names as the memory store below (store_conversation, get_conversation,
-- ...). Registering one is the only way to add redis/postgres/oracle later: no
-- call site in router.lua changes.
--
--     history.register_backend("redis", require "resty.luarouter.history_redis")
_M.BACKENDS = {}

---@param name string
---@param impl table
function _M.register_backend(name, impl)
    if type(impl) ~= "table" then
        return nil, "backend implementation must be a table"
    end
    _M.BACKENDS[string.lower(name)] = impl
    return true
end

-- ================================================================== primitives

---Errors are plain tables so the module never depends on ngx.
---@param status number
---@param code string
---@param message string
---@param param string|nil
---@return table
function _M.error(status, code, message, param)
    return { status = status, code = code, message = message, param = param }
end

local function not_found(msg)
    return _M.error(404, "not_found", msg)
end

local function bad_request(msg, param)
    return _M.error(400, "invalid_request_error", msg, param)
end

local function internal_error(msg)
    return _M.error(500, "history_storage_error", msg)
end

-- cjson encodes an empty Lua table as an object, which is wrong for the OpenAI
-- fields that are schema-level arrays (message content, response input/output).
-- Two rules close that gap without touching cjson's global state (which would
-- change what router.lua emits for its own empty objects):
--   * a table wrapped by _M.array() is always written as an array;
--   * any table with #t > 0 is written as an array (cjson's own rule).
-- Byte-exact pass-through payloads (raw response bytes from an upstream) never
-- go through the encoder at all, so they keep whatever the upstream sent.
local ARRAY_MT = { __lr_array = true }

---Mark a table as a JSON array, so an empty one still encodes as [].
---@param t table|nil
---@return table
function _M.array(t)
    return setmetatable(t or {}, ARRAY_MT)
end

local function is_array(v)
    return type(v) == "table" and (getmetatable(v) == ARRAY_MT or #v > 0)
end

---Coerce a decoded value into something that encodes as a JSON array. Used for
---the response fields that are arrays by schema (input, output).
---
---cjson decodes both `[]` and `{}` into an empty Lua table, so an incoming
---`output: []` would otherwise be written back as an object.
local function as_array(v)
    if v == nil then
        return _M.array()
    end
    if is_array(v) then
        return v
    end
    if type(v) == "table" and next(v) == nil then
        return _M.array(v)
    end
    return _M.array({ v })
end

---Normalise an item's content without changing its kind.
---
---OpenAI lets message content be either a plain string or an array of content
---parts, and Rust stores whatever arrived (`item_val.get("content").cloned()`),
---so only the two ambiguous cases get fixed here: a missing content becomes [],
---and a decoded empty table becomes [] rather than {}.
local function content_value(v)
    if v == nil then
        return _M.array()
    end
    if type(v) == "table" and not is_array(v) and next(v) == nil then
        return _M.array(v)
    end
    return v
end

local function encode_value(v, out)
    local t = type(v)
    if v == nil then
        out[#out + 1] = "null"
    elseif t == "boolean" then
        out[#out + 1] = tostring(v)
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            out[#out + 1] = "null"
        else
            out[#out + 1] = json_encode(v)
        end
    elseif t == "string" then
        out[#out + 1] = json_encode(v)
    elseif is_array(v) then
        out[#out + 1] = "["
        for i = 1, #v do
            if i > 1 then
                out[#out + 1] = ","
            end
            encode_value(v[i], out)
        end
        out[#out + 1] = "]"
    elseif t == "table" then
        local keys = {}
        for k in pairs(v) do
            if type(k) == "string" then
                keys[#keys + 1] = k
            end
        end
        table.sort(keys)
        out[#out + 1] = "{"
        for i = 1, #keys do
            if i > 1 then
                out[#out + 1] = ","
            end
            out[#out + 1] = json_encode(keys[i])
            out[#out + 1] = ":"
            encode_value(v[keys[i]], out)
        end
        out[#out + 1] = "}"
    else
        out[#out + 1] = "null"
    end
end

---Encode a value to JSON with the array rule above. Keys are sorted, so output
---is byte-stable, which the unit tests and the on-disk index rely on.
---@param v any
---@return string|nil
function _M.encode(v)
    local out = {}
    local ok, err = pcall(encode_value, v, out)
    if not ok then
        return nil, tostring(err)
    end
    return table.concat(out)
end

local function decode(text)
    if text == nil or text == "" then
        return nil
    end
    return json_decode(text)
end

-- ------------------------------------------------------------------ id / time

local ENCODING = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

local function bit_at(text, index)
    local byte = string.byte(text, math.floor((index - 1) / 8) + 1)
    if not byte then
        return 0
    end
    return math.floor(byte / 2 ^ (7 - ((index - 1) % 8))) % 2
end

---Encode a value below 2^(5*n_out) as exactly n_out Crockford base32 characters.
---This is the half of the ULID that a standard parser reads back as the timestamp.
local function base32_number(value, n_out)
    local out = {}
    for c = 1, n_out do
        local power = 5 * (n_out - c)
        local digit = math.floor(value / 2 ^ power) % 32
        out[#out + 1] = string.sub(ENCODING, digit + 1, digit + 1)
    end
    return table.concat(out)
end

---Crockford base32, left-aligned, zero padded to n_out characters.
local function base32(text, n_out)
    local bits = #text * 8
    local out = {}
    for c = 0, n_out - 1 do
        local value = 0
        for b = 0, 4 do
            local index = c * 5 + b + 1
            value = value * 2 + (index <= bits and bit_at(text, index) or 0)
        end
        out[#out + 1] = string.sub(ENCODING, value + 1, value + 1)
    end
    return table.concat(out)
end

local rand_mod

---n random bytes as a hex string.
local function random_hex(n_bytes)
    local text, err = _M.random_bytes(n_bytes)
    if not text then
        return nil, err
    end
    local out = {}
    for i = 1, #text do
        out[#out + 1] = string.format("%02x", string.byte(text, i))
    end
    return table.concat(out)
end

---Random bytes, preferring the same CSPRNG the registry already leans on.
---Falls back to math.random (seeded once per process here, so an unseeded test
---run stays reproducible) and finally to a time+pid mix, so id generation never
---hard-fails a request because OpenSSL is missing.
---@param n_bytes number
---@return string|nil, string|nil
function _M.random_bytes(n_bytes)
    if not rand_mod then
        local ok, mod = pcall(require, "resty.openssl.rand")
        if ok and type(mod) == "table" and mod.bytes then
            rand_mod = mod
        else
            rand_mod = false
        end
    end
    if rand_mod then
        local bytes, err = rand_mod.bytes(n_bytes)
        if bytes then
            return bytes
        end
        return nil, "rand: " .. tostring(err)
    end
    local seeded = _M._seeded
    if not seeded then
        _M._seeded = true
        local clock
        if _G.ngx and _G.ngx.now then
            clock = _G.ngx.now() * 1000
        else
            clock = os.time() * 1000
        end
        local pid = _G.ngx and _G.ngx.worker and _G.ngx.worker.pid and _G.ngx.worker.pid() or 0
        math.randomseed(math.floor(clock) + pid)
    end
    local out = {}
    for i = 1, n_bytes do
        out[#out + 1] = string.char(math.random(0, 255))
    end
    return table.concat(out)
end

---conv_<50 hex>, the shape of data_connector's ConversationId::new().
---@return string
function _M.new_conversation_id()
    local hex = random_hex(25)
    if not hex then
        -- Last-ditch uniqueness: a monotonic-ish mix is better than nothing.
        hex = string.format("%08x%08x%08x%08x", os.time(), math.random(0, 0x7fffffff),
            math.random(0, 0x7fffffff), math.random(0, 0x7fffffff)):sub(1, 50)
    end
    return "conv_" .. hex:sub(1, 50)
end

-- make_item_id's prefix table, copied from data-connector/src/core.rs.
local ITEM_ID_PREFIX = {
    message = "msg",
    reasoning = "rs",
    mcp_call = "mcp",
    mcp_list_tools = "mcpl",
    function_call = "fc",
}

---<type prefix>_<50 hex>, matching data_connector's make_item_id().
---@param item_type string
---@return string
function _M.new_item_id(item_type)
    local prefix = ITEM_ID_PREFIX[item_type]
    if not prefix then
        prefix = tostring(item_type or ""):sub(1, 3)
        if prefix == "" then
            prefix = "itm"
        end
    end
    local hex = random_hex(25)
    if not hex then
        hex = string.format("%08x%08x%08x%08x", os.time(), math.random(0, 0x7fffffff),
            math.random(0, 0x7fffffff), math.random(0, 0x7fffffff)):sub(1, 50)
    end
    return prefix .. "_" .. hex:sub(1, 50)
end

---26-character ULID, the shape of data_connector's ResponseId::new(). Lexicously
---sortable because the 48-bit millisecond timestamp comes first.
---@return string
function _M.new_response_id()
    local clock
    if _G.ngx and _G.ngx.now then
        clock = _G.ngx.now()
    else
        clock = os.time()
    end
    local rand, err = _M.random_bytes(10)
    if not rand then
        return nil, err
    end
    return base32_number(math.floor(clock * 1000), 10) .. base32(rand, 16)
end

---Unix seconds, as `created_at` is an integer everywhere in the Rust API.
---@return number
function _M.now()
    if _G.ngx and _G.ngx.now then
        return math.floor(_G.ngx.now())
    end
    return os.time()
end

-- ------------------------------------------------------------------ locking

---Run fn() under a cross-process lock.
---
---Every write here touches more than one dict key (record + index + counter), so
---a get/set pair loses updates across nginx worker processes, exactly as the
---registry found. A live probe with two workers and eight concurrent writers lost
---78 of 240 item links without this lock, so it is load-bearing, not decorative.
---
---The reentrancy flag lives in ngx.ctx, so it is per request: a process-global
---flag made every *other* request in the same worker believe it already held the
---lock and skip it, which is how the overlap above went unnoticed at first.
---resty.lock is optional: with it absent (plain luajit tests, or a dict that was
---never declared) the module degrades to unlocked writes rather than erroring.
---@param fn fun():any
---@return any, table|string|nil
function _M.with_lock(fn)
    local ctx = _G.ngx and _G.ngx.ctx
    if ctx and ctx.lr_history_held then
        -- reentrant within one request; resty.lock is not reentrant
        return fn()
    end
    local ok, lock_mod = pcall(require, "resty.lock")
    if not ok or type(lock_mod) ~= "table" or not lock_mod.new or not _G.ngx
        or not _G.ngx.shared or not _G.ngx.shared[_M.LOCK_DICT] then
        if ctx then
            ctx.lr_history_held = true
        end
        local called, res, err = pcall(fn)
        if ctx then
            ctx.lr_history_held = nil
        end
        if not called then
            return nil, internal_error("history operation failed: " .. tostring(res))
        end
        return res, err
    end
    -- resty.lock's new is a method: the dict name has to follow self, so call it
    -- with the colon form exactly as registry.lua does.
    local lock, lerr = lock_mod:new(_M.LOCK_DICT, { timeout = 5, exptime = 10 })
    if not lock then
        return nil, internal_error("history lock init failed: " .. tostring(lerr))
    end
    local got, gerr = lock:lock(_M.LOCK_KEY)
    if not got then
        return nil, internal_error("history lock failed: " .. tostring(gerr))
    end
    if ctx then
        ctx.lr_history_held = true
    end
    local called, res, err = pcall(fn)
    if ctx then
        ctx.lr_history_held = nil
    end
    lock:unlock()
    if not called then
        return nil, internal_error("history operation failed: " .. tostring(res))
    end
    if err then
        return nil, err
    end
    return res
end

-- ------------------------------------------------------------------ dict access

local dict

---Inject the store handle. Unit tests pass an in-memory table with the same
---get/set/add/delete/incr/get_keys surface as ngx.shared.DICT.
---@param d ngx.shared.DICT|table|nil
function _M.use_dict(d)
    dict = d
end

---@return ngx.shared.DICT|table|nil
function _M.dict()
    if dict == nil then
        if _G.ngx and _G.ngx.shared then
            dict = _G.ngx.shared[_M.DICT] or false
        else
            dict = false
        end
    end
    if dict == false then
        return nil
    end
    return dict
end

---Guard every write path: configured backend usable, store present.
---@return table|nil @ the store implementation
---@return table|nil err
local function store()
    local name = _M.backend()
    -- A registered implementation wins before the 501 gate, which is what makes
    -- register_backend("redis", ...) the extension path the module docs promise.
    local custom = _M.BACKENDS[name]
    if custom then
        return custom
    end
    local ok, err = _M.backend_supported()
    if not ok then
        return nil, err
    end
    if name == "none" then
        return _M.noop_store
    end
    if not _M.dict() then
        return nil, _M.error(503, "history_unavailable",
            "history backend 'memory' needs a lua_shared_dict " .. _M.DICT
            .. " declaration in the nginx config")
    end
    return _M.memory_store
end

-- =================================================================== item types

-- handlers.rs SUPPORTED_ITEM_TYPES / IMPLEMENTED_ITEM_TYPES, verbatim.
_M.SUPPORTED_ITEM_TYPES = {
    "message", "reasoning", "mcp_list_tools", "mcp_call", "item_reference",
    "function_call", "function_call_output", "file_search_call", "computer_call",
    "computer_call_output", "web_search_call", "image_generation_call",
    "code_interpreter_call", "local_shell_call", "local_shell_call_output",
    "mcp_approval_request", "mcp_approval_response", "custom_tool_call",
    "custom_tool_call_output",
}

_M.IMPLEMENTED_ITEM_TYPES = {
    "message", "reasoning", "mcp_list_tools", "mcp_call", "item_reference",
}

-- persistence_utils.rs ITEM_TYPE_FIELDS: for these types the stored content is
-- the whole item and the listed fields are hoisted back out on render.
_M.ITEM_TYPE_FIELDS = {
    mcp_call = { "name", "arguments", "output", "server_label",
                 "approval_request_id", "error" },
    mcp_list_tools = { "tools", "server_label" },
    function_call = { "call_id", "name", "arguments", "output" },
    function_call_output = { "call_id", "output" },
}

local function contains(list, value)
    for i = 1, #list do
        if list[i] == value then
            return true
        end
    end
    return false
end

_M.contains = contains

-- Only characters an id actually ever carries (msg_ / resp_ / item_ prefixes plus
-- hex or ULID bodies). DEVIATION: Rust accepts any string; the link index stores
-- ids inside a delimited text key, so a control character would corrupt it.
local ID_RE = "^[%w_%-%.%:]+$"

---@param raw_id any
---@param what string @ "item_id" | "conversation_id" | "response_id"
---@return string|nil, table|nil err
function _M.parse_id(raw_id, what)
    if type(raw_id) ~= "string" or raw_id == "" then
        return nil, bad_request(what .. " is required")
    end
    if #raw_id > 128 or not string.match(raw_id, ID_RE) then
        return nil, bad_request(string.format("Invalid %s '%s'", what, raw_id))
    end
    return raw_id
end

-- ============================================================ record rendering

---Conversation wire object. An empty metadata map is dropped, as Rust's
---conversation_to_json does.
---@param conv table
---@return table
function _M.conversation_to_json(conv)
    local obj = {
        id = conv.id,
        object = "conversation",
        created_at = conv.created_at,
    }
    if type(conv.metadata) == "table" and next(conv.metadata) ~= nil then
        obj.metadata = conv.metadata
    end
    return obj
end

---Item wire object, following persistence_utils.rs item_to_json: id and type
---first, role and status only when set, then either the hoisted fields of a
---tool-call type or content as-is.
---@param item table
---@param with_created_at boolean|nil @ list_items adds it, get_item does not
---@return table
function _M.item_to_json(item, with_created_at)
    local obj = { id = item.id, ["type"] = item.item_type }
    if item.role then
        obj.role = item.role
    end
    local fields = _M.ITEM_TYPE_FIELDS[item.item_type]
    if fields and type(item.content) == "table" then
        for i = 1, #fields do
            local field = fields[i]
            if item.content[field] ~= nil then
                obj[field] = item.content[field]
            end
        end
    else
        obj.content = content_value(item.content)
    end
    if item.status then
        obj.status = item.status
    end
    if item.response_id then
        obj.response_id = item.response_id
    end
    if with_created_at then
        obj.created_at = item.created_at
    end
    return obj
end

---Validate one incoming item. Returns the storable record, or an error table.
---Mirrors handlers.rs parse_item_from_value: unknown types are rejected, known
---but unimplemented types are accepted with a warning, and a message needs a role.
---@param value table @ decoded item
---@return table|nil record, string|nil warning, table|nil err
function _M.parse_item(value)
    if type(value) ~= "table" then
        return nil, nil, bad_request("item must be an object")
    end
    local item_type = value.type or value.item_type or "message"
    if type(item_type) ~= "string" then
        return nil, nil, bad_request("item type must be a string")
    end
    if not contains(_M.SUPPORTED_ITEM_TYPES, item_type) then
        return nil, nil, bad_request(string.format(
            "Unsupported item type '%s'. Supported types: %s",
            item_type, table.concat(_M.SUPPORTED_ITEM_TYPES, ", ")))
    end
    local warning
    if not contains(_M.IMPLEMENTED_ITEM_TYPES, item_type) then
        warning = string.format(
            "Item type '%s' is accepted but not yet implemented. "
            .. "The item will be stored but may not function as expected.",
            item_type)
    end
    local role = value.role
    if type(role) ~= "string" then
        role = nil
    end
    if item_type == "message" and role == nil then
        return nil, nil, bad_request("Message items require 'role' field")
    end
    local status = value.status
    if type(status) ~= "string" then
        status = "completed"
    end
    -- Message and reasoning keep their content field; every other type stores the
    -- whole item as content so the tool fields survive a round trip.
    local content
    if item_type == "message" or item_type == "reasoning" then
        content = content_value(value.content)
    else
        content = value
    end
    local record = {
        item_type = item_type,
        role = role,
        content = content,
        status = status,
        response_id = type(value.response_id) == "string" and value.response_id or nil,
    }
    if value.id ~= nil then
        local id, err = _M.parse_id(value.id, "item_id")
        if not id then
            return nil, nil, err
        end
        record.id = id
    end
    return record, warning
end

---Metadata patch semantics from handlers.rs apply_metadata_patches: a null value
---deletes the key, and the cap is checked on the merged result.
---@param current table|nil
---@param patch table|nil
---@return table|nil merged (nil means "no metadata")
---@return table|nil err
function _M.apply_metadata_patch(current, patch)
    if patch == nil then
        return current
    end
    if type(patch) ~= "table" then
        return nil, bad_request("metadata must be an object")
    end
    local result = {}
    local count = 0
    if type(current) == "table" then
        for k, v in pairs(current) do
            result[k] = v
            count = count + 1
        end
    end
    local has_array = false
    for k, v in pairs(patch) do
        if type(k) ~= "string" then
            has_array = true
        elseif v == cjson.null or v == nil then
            if result[k] ~= nil then
                result[k] = nil
                count = count - 1
            end
        else
            if result[k] == nil then
                count = count + 1
            end
            result[k] = v
        end
    end
    -- A JSON array in metadata means the caller sent [] where an object belongs.
    if has_array or #patch > 0 then
        return nil, bad_request("metadata must be an object")
    end
    if count > _M.MAX_METADATA_PROPERTIES then
        return nil, bad_request(string.format(
            "metadata cannot have more than %d properties",
            _M.MAX_METADATA_PROPERTIES))
    end
    if count == 0 then
        return nil
    end
    return result
end

---Validate metadata on create (no merge, so the cap is checked on the payload).
---@param value any
---@return table|nil, table|nil err
function _M.validate_metadata(value)
    if value == nil then
        return nil
    end
    if type(value) ~= "table" or #value > 0 then
        return nil, bad_request("metadata must be an object")
    end
    local count = 0
    for k in pairs(value) do
        if type(k) ~= "string" then
            return nil, bad_request("metadata must be an object")
        end
        count = count + 1
    end
    if count > _M.MAX_METADATA_PROPERTIES then
        return nil, bad_request(string.format(
            "metadata cannot have more than %d properties",
            _M.MAX_METADATA_PROPERTIES))
    end
    if count == 0 then
        return nil
    end
    return value
end

-- =================================================================== key layout

local K_CONV = "cv:"    -- conversation record (JSON)
local K_ITEM = "it:"    -- conversation item (JSON)
local K_LINK = "lx:"    -- per-conversation ordered item index (text)
local K_REV  = "rv:"    -- item_id -> index score, for the after cursor
local K_RESP = "rs:"    -- stored response (JSON)
local K_SEQ  = "sq:"    -- last-access sequence, for the LRU sweep
local G_SEQ  = "seq"    -- monotonic access counter
local N_CONV = "n:conv" -- conversation count
local N_RESP = "n:resp" -- response count

-- Index key. DEVIATION: memory.rs sorts by (added_at.timestamp(), item_id), so
-- every item added inside one second comes back in random id order. A monotonic
-- sequence keeps the documented creation order and makes the after cursor stable
-- for a fast batch; created_at still reports the second, as the wire field does.
-- Zero-padded so lexicographic order equals numeric order, item_id as tiebreak.
local function score(sequence, item_id)
    return string.format("%012d ", sequence) .. item_id
end

local ENTRY_SEP = "\1"
local FIELD_SEP = "\2"

local function parse_index(text)
    local entries = {}
    if not text or text == "" then
        return entries
    end
    for entry in string.gmatch(text, "[^" .. ENTRY_SEP .. "]+") do
        local at = string.find(entry, FIELD_SEP, 1, true)
        if at then
            entries[#entries + 1] = {
                score = string.sub(entry, 1, at - 1),
                item_id = string.sub(entry, at + 1),
            }
        end
    end
    return entries
end

local function render_index(entries)
    local parts = {}
    for i = 1, #entries do
        parts[i] = entries[i].score .. FIELD_SEP .. entries[i].item_id
    end
    return table.concat(parts, ENTRY_SEP)
end

---------------------------------------------------------------------------
-- The memory store. ngx.shared.DICT holds one JSON value per record plus a
-- compact text index per conversation, so listing never scans the whole dict.
---------------------------------------------------------------------------
_M.memory_store = {}

local function d()
    return _M.dict()
end

---Monotonic per-dict access counter; also the LRU clock.
local function next_seq()
    local seq, err = d():incr(G_SEQ, 1, 0)
    if not seq then
        -- incr on a fresh key can fail under `resty -t`; fall back to wall clock.
        return _M.now(), err
    end
    return seq
end

local function touch(key)
    local seq = next_seq()
    d():set(K_SEQ .. key, seq)
    return seq
end

local function ttl()
    return _M.config().ttl_secs
end

-- --------------------------------------------------------------- conversations

function _M.memory_store.get_conversation(id)
    local raw = d():get(K_CONV .. id)
    if not raw then
        return nil
    end
    local conv = decode(raw)
    if not conv then
        return nil
    end
    touch(id)
    return conv
end

function _M.memory_store.store_conversation(conv)
    local encoded = _M.encode(conv)
    if not encoded then
        return nil, internal_error("failed to encode conversation")
    end
    local existed = d():get(K_CONV .. conv.id) ~= nil
    local ok, err = d():set(K_CONV .. conv.id, encoded, ttl())
    if not ok then
        return nil, internal_error("failed to store conversation: " .. tostring(err))
    end
    if not existed then
        d():incr(N_CONV, 1, 0)
    end
    touch(conv.id)
    return conv
end

---Evict least-recently-touched conversations to make room for one more. Called
---only from create, so the expensive get_keys scan is rare.
function _M.memory_store.enforce_conversation_cap()
    local cap = _M.config().max_conversations
    if cap <= 0 then
        return 0
    end
    local count = d():incr(N_CONV, 0, 0)
    if not count or count < cap then
        return 0
    end
    local victims = {}
    for _, key in ipairs(d():get_keys(0)) do
        if string.sub(key, 1, #K_CONV) == K_CONV then
            local id = string.sub(key, #K_CONV + 1)
            victims[#victims + 1] = { id = id, seq = d():get(K_SEQ .. id) or 0 }
        end
    end
    table.sort(victims, function(a, b)
        if a.seq == b.seq then
            return a.id < b.id
        end
        return a.seq < b.seq
    end)
    -- Hysteresis: evict down to ~90% so one create does not pay for the scan on
    -- every subsequent request.
    local target = cap - 1 - math.floor(cap * 0.1)
    if target < 0 then
        target = 0
    end
    local dropped = 0
    local i = 1
    while count > target and i <= #victims do
        local id = victims[i].id
        _M.memory_store.drop_conversation(id)
        dropped = dropped + 1
        count = count - 1
        i = i + 1
    end
    return dropped
end

---Remove every key owned by a conversation. Skips the count bookkeeping so the
---caller controls when the gauge moves.
function _M.memory_store.drop_conversation(id)
    local d0 = d()
    local text = d0:get(K_LINK .. id)
    if text then
        local entries = parse_index(text)
        for i = 1, #entries do
            d0:delete(K_REV .. id .. "|" .. entries[i].item_id)
            -- Reclaim the record as well: it is unreachable once the link is gone.
            -- DEVIATION: an item referenced by a second conversation disappears
            -- from that one too, because nothing here counts links per item.
            d0:delete(K_ITEM .. entries[i].item_id)
        end
        d0:delete(K_LINK .. id)
    end
    d0:delete(K_CONV .. id)
    d0:delete(K_SEQ .. id)
    d0:incr(N_CONV, -1, 0)
    return true
end

-- ---------------------------------------------------------------- items

---Append one entry to a conversation index and persist it. Caller holds the lock.
function _M.memory_store.link_item(conv_id, item_id, created_at)
    local d0 = d()
    local entry_score = score(next_seq(), item_id)
    local text = d0:get(K_LINK .. conv_id)
    local entries = parse_index(text)
    for i = 1, #entries do
        if entries[i].item_id == item_id then
            -- Already linked: memory.rs overwrites the (ts, id) key, so keep the
            -- first position and just refresh the reverse index.
            d0:set(K_REV .. conv_id .. "|" .. item_id, entries[i].score)
            return entries[i].score
        end
    end
    entries[#entries + 1] = { score = entry_score, item_id = item_id }
    table.sort(entries, function(a, b) return a.score < b.score end)
    local cap = _M.config().max_items_per_conversation
    while cap > 0 and #entries > cap do
        local victim = table.remove(entries, 1)
        d0:delete(K_REV .. conv_id .. "|" .. victim.item_id)
        d0:delete(K_ITEM .. victim.item_id)
    end
    local rendered = render_index(entries)
    local ok, err = d0:set(K_LINK .. conv_id, rendered, ttl())
    if not ok then
        return nil, internal_error("failed to store item index: " .. tostring(err))
    end
    d0:set(K_REV .. conv_id .. "|" .. item_id, entry_score)
    return entry_score
end

function _M.memory_store.get_item(item_id)
    local raw = d():get(K_ITEM .. item_id)
    if not raw then
        return nil
    end
    return decode(raw)
end

function _M.memory_store.store_item(item)
    local encoded = _M.encode(item)
    if not encoded then
        return nil, internal_error("failed to encode item")
    end
    local ok, err = d():set(K_ITEM .. item.id, encoded, ttl())
    if not ok then
        return nil, internal_error("failed to store item: " .. tostring(err))
    end
    return item
end

function _M.memory_store.is_item_linked(conv_id, item_id)
    return d():get(K_REV .. conv_id .. "|" .. item_id) ~= nil
end

---Unlink only, which is what the Rust delete_item does: the item record itself
---stays and can still be referenced by another conversation.
function _M.memory_store.unlink_item(conv_id, item_id)
    local d0 = d()
    local entry_score = d0:get(K_REV .. conv_id .. "|" .. item_id)
    if not entry_score then
        return false
    end
    d0:delete(K_REV .. conv_id .. "|" .. item_id)
    local text = d0:get(K_LINK .. conv_id)
    local entries = parse_index(text)
    local kept = {}
    for i = 1, #entries do
        if entries[i].item_id ~= item_id then
            kept[#kept + 1] = entries[i]
        end
    end
    if #kept == 0 then
        d0:delete(K_LINK .. conv_id)
    else
        d0:set(K_LINK .. conv_id, render_index(kept), ttl())
    end
    return true
end

---Sorted entries for a conversation, oldest first.
function _M.memory_store.index(conv_id)
    return parse_index(d():get(K_LINK .. conv_id))
end

function _M.memory_store.score_of(conv_id, item_id)
    return d():get(K_REV .. conv_id .. "|" .. item_id)
end

-- --------------------------------------------------------------- responses

function _M.memory_store.get_response(id)
    local raw = d():get(K_RESP .. id)
    if not raw then
        return nil
    end
    return decode(raw)
end

function _M.memory_store.store_response(rec)
    local encoded = _M.encode(rec)
    if not encoded then
        return nil, internal_error("failed to encode response")
    end
    local d0 = d()
    local existed = d0:get(K_RESP .. rec.id) ~= nil
    local ok, err = d0:set(K_RESP .. rec.id, encoded, ttl())
    if not ok then
        return nil, internal_error("failed to store response: " .. tostring(err))
    end
    if not existed then
        d0:incr(N_RESP, 1, 0)
    end
    return rec
end

function _M.memory_store.delete_response(id)
    local d0 = d()
    if not d0:get(K_RESP .. id) then
        return false
    end
    d0:delete(K_RESP .. id)
    d0:incr(N_RESP, -1, 0)
    return true
end

function _M.memory_store.enforce_response_cap()
    local cap = _M.config().max_responses
    if cap <= 0 then
        return 0
    end
    local count = d():incr(N_RESP, 0, 0)
    if not count or count < cap then
        return 0
    end
    local victims = {}
    for _, key in ipairs(d():get_keys(0)) do
        if string.sub(key, 1, #K_RESP) == K_RESP then
            local id = string.sub(key, #K_RESP + 1)
            local rec = decode(d():get(key))
            victims[#victims + 1] = {
                id = id,
                created_at = type(rec) == "table" and rec.created_at or 0,
            }
        end
    end
    table.sort(victims, function(a, b)
        if a.created_at == b.created_at then
            return a.id < b.id
        end
        return a.created_at < b.created_at
    end)
    local target = cap - 1 - math.floor(cap * 0.1)
    if target < 0 then
        target = 0
    end
    local dropped = 0
    local i = 1
    while count > target and i <= #victims do
        _M.memory_store.delete_response(victims[i].id)
        dropped = dropped + 1
        count = count - 1
        i = i + 1
    end
    return dropped
end

---------------------------------------------------------------------------
-- The `none` backend: data_connector's NoOp storages, i.e. ids are handed back
-- and every read comes up empty. Nothing is written anywhere.
---------------------------------------------------------------------------
_M.noop_store = {}

function _M.noop_store.get_conversation(_id)
    return nil
end

function _M.noop_store.store_conversation(conv)
    return conv
end

function _M.noop_store.drop_conversation(_id)
    return true
end

function _M.noop_store.enforce_conversation_cap()
    return 0
end

function _M.noop_store.get_item(_item_id)
    return nil
end

function _M.noop_store.store_item(item)
    return item
end

function _M.noop_store.link_item(_conv_id, _item_id, _created_at)
    return true
end

function _M.noop_store.is_item_linked(_conv_id, _item_id)
    return false
end

function _M.noop_store.unlink_item(_conv_id, _item_id)
    return true
end

function _M.noop_store.index(_conv_id)
    return {}
end

function _M.noop_store.score_of(_conv_id, _item_id)
    return nil
end

function _M.noop_store.get_response(_id)
    return nil
end

function _M.noop_store.store_response(rec)
    return rec
end

function _M.noop_store.delete_response(_id)
    return false
end

function _M.noop_store.enforce_response_cap()
    return 0
end


-- ================================================================== public API

---POST /v1/conversations.
---@param metadata table|nil
---@param opts table|nil @ {id = string} client-provided id, as NewConversation allows
---@return table|nil conversation, table|nil err
function _M.create_conversation(metadata, opts)
    local s, err = store()
    if not s then
        return nil, err
    end
    local meta, merr = _M.validate_metadata(metadata)
    if merr then
        return nil, merr
    end
    local id
    if opts and opts.id ~= nil then
        id, err = _M.parse_id(opts.id, "conversation_id")
        if not id then
            return nil, err
        end
    else
        id = _M.new_conversation_id()
    end
    local conv, lerr = _M.with_lock(function()
        local existing, gerr = s.get_conversation(id)
        if gerr then
            return nil, gerr
        end
        if existing then
            -- create_conversation mints a fresh id in Rust, so a collision is a
            -- server-side problem, not a 409.
            return nil, internal_error("conversation " .. id .. " already exists")
        end
        s.enforce_conversation_cap()
        local record = { id = id, created_at = _M.now(), metadata = meta }
        local stored, serr = s.store_conversation(record)
        if not stored then
            return nil, serr
        end
        return stored
    end)
    if not conv then
        return nil, lerr
    end
    return _M.conversation_to_json(conv)
end

---GET /v1/conversations/{id}
---@param conversation_id string
---@return table|nil, table|nil
function _M.get_conversation(conversation_id)
    local s, err = store()
    if not s then
        return nil, err
    end
    local id, ierr = _M.parse_id(conversation_id, "conversation_id")
    if not id then
        return nil, ierr
    end
    local conv, gerr = s.get_conversation(id)
    if gerr then
        -- A registered backend (redis) reports transport failures as the second
        -- return value; the memory store never sets it, so the map below holds
        -- for both. Without this a dead Redis would surface as 404 on every GET.
        return nil, gerr
    end
    if not conv then
        return nil, not_found("Conversation not found")
    end
    return _M.conversation_to_json(conv)
end

---POST /v1/conversations/{id} - metadata patch, null deletes a key.
---@param conversation_id string
---@param body table @ {metadata = table}
---@return table|nil, table|nil
function _M.update_conversation(conversation_id, body)
    local s, err = store()
    if not s then
        return nil, err
    end
    local id, ierr = _M.parse_id(conversation_id, "conversation_id")
    if not id then
        return nil, ierr
    end
    if type(body) ~= "table" then
        return nil, bad_request("body must be an object")
    end
    return _M.with_lock(function()
        local conv, gerr = s.get_conversation(id)
        if gerr then
            return nil, gerr
        end
        if not conv then
            return nil, not_found("Conversation not found")
        end
        local merged, merr = _M.apply_metadata_patch(conv.metadata, body.metadata)
        if merr then
            return nil, merr
        end
        conv.metadata = merged
        local stored, serr = s.store_conversation(conv)
        if not stored then
            return nil, serr
        end
        return _M.conversation_to_json(stored)
    end)
end

---DELETE /v1/conversations/{id}. Drops the links too; orphaned item records stay
---in the dict until the capacity sweep reclaims them, which is what a shared item
---store has to do (an item can be linked to several conversations).
---@param conversation_id string
---@return table|nil, table|nil
function _M.delete_conversation(conversation_id)
    local s, err = store()
    if not s then
        return nil, err
    end
    local id, ierr = _M.parse_id(conversation_id, "conversation_id")
    if not id then
        return nil, ierr
    end
    return _M.with_lock(function()
        local conv, gerr = s.get_conversation(id)
        if gerr then
            return nil, gerr
        end
        if not conv then
            return nil, not_found("Conversation not found")
        end
        s.drop_conversation(id)
        return { id = id, object = "conversation.deleted", deleted = true }
    end)
end

---GET /v1/conversations/{id}/items
---@param conversation_id string
---@param params table|nil @ {limit=number, order="asc"|"desc", after=item_id}
---@return table|nil list envelope, table|nil err
function _M.list_items(conversation_id, params)
    local s, err = store()
    if not s then
        return nil, err
    end
    local id, ierr = _M.parse_id(conversation_id, "conversation_id")
    if not id then
        return nil, ierr
    end
    local conv_ok, gerr = s.get_conversation(id)
    if gerr then
        return nil, gerr
    end
    if not conv_ok then
        return nil, not_found("Conversation not found")
    end
    params = params or {}
    local limit = params.limit
    if limit == nil then
        limit = _M.DEFAULT_PAGE_SIZE
    else
        limit = tonumber(limit)
        if not limit or limit < 1 then
            return nil, bad_request("limit must be a positive integer", "limit")
        end
        if limit > _M.MAX_PAGE_SIZE then
            limit = _M.MAX_PAGE_SIZE
        end
    end
    -- Rust maps only the literal "asc" to ascending; anything else is descending.
    local asc = params.order == "asc"
    local entries = s.index(id)
    local from, to, step
    if asc then
        from, to, step = 1, #entries, 1
    else
        from, to, step = #entries, 1, -1
    end
    if params.after then
        local cursor, cerr = _M.parse_id(params.after, "item_id")
        if not cursor then
            return nil, cerr
        end
        local cursor_score = s.score_of(id, cursor)
        if cursor_score then
            for i = from, to, step do
                if entries[i].score == cursor_score then
                    from = i + step
                    break
                end
            end
        end
    end
    local data = {}
    local i = from
    while i >= 1 and i <= #entries and #data < limit do
        local item = s.get_item(entries[i].item_id)
        if item then
            data[#data + 1] = _M.item_to_json(item, true)
        end
        i = i + step
    end
    return {
        object = "list",
        data = as_array(data),
        first_id = #data > 0 and data[1].id or nil,
        last_id = #data > 0 and data[#data].id or nil,
        -- Rust reports "did the page fill up" rather than "is there more", so a
        -- full last page answers has_more=true with an empty next page.
        has_more = #data == limit,
    }
end

---POST /v1/conversations/{id}/items
---@param conversation_id string
---@param items table[] @ decoded items array
---@return table|nil list envelope (plus warnings when some types are not implemented), table|nil err
function _M.create_items(conversation_id, items)
    local s, err = store()
    if not s then
        return nil, err
    end
    local id, ierr = _M.parse_id(conversation_id, "conversation_id")
    if not id then
        return nil, ierr
    end
    if type(items) ~= "table" then
        return nil, bad_request("Missing or invalid 'items' field", "items")
    end
    if #items > _M.config().max_items_per_request then
        return nil, bad_request(string.format(
            "Cannot add more than %d items at one time",
            _M.config().max_items_per_request), "items")
    end
    return _M.with_lock(function()
        local live, gerr = s.get_conversation(id)
        if gerr then
            return nil, gerr
        end
        if not live then
            return nil, not_found("Conversation not found")
        end
        local created = _M.array({})
        local warnings = {}
        local added_at = _M.now()
        for n = 1, #items do
            local value = items[n]
            local item_type = type(value) == "table" and (value.type or value.item_type) or nil
            if item_type == "item_reference" then
                -- Link an existing item rather than creating one.
                local ref, rerr = _M.parse_id(value.id, "item_id")
                if not ref then
                    return nil, rerr
                end
                local existing, ierr = s.get_item(ref)
                if ierr then
                    return nil, ierr
                end
                if not existing then
                    return nil, not_found("Referenced item '" .. ref .. "' not found")
                end
                s.link_item(id, ref, added_at)
                created[#created + 1] = _M.item_to_json(existing, true)
            else
                local record, warning, perr = _M.parse_item(value)
                if perr then
                    return nil, perr
                end
                local item_id = record.id or _M.new_item_id(record.item_type)
                if record.id and s.is_item_linked(id, record.id) then
                    return nil, _M.error(400, "item_already_in_conversation",
                        "Item already in conversation", "items")
                end
                record.id = item_id
                record.created_at = added_at
                local stored, serr = s.store_item(record)
                if not stored then
                    return nil, serr
                end
                s.link_item(id, item_id, added_at)
                if warning then
                    warnings[#warnings + 1] = warning
                end
                created[#created + 1] = _M.item_to_json(stored, true)
            end
        end
        local envelope = {
            object = "list",
            data = created,
            first_id = #created > 0 and created[1].id or nil,
            last_id = #created > 0 and created[#created].id or nil,
            has_more = false,
        }
        if #warnings > 0 then
            envelope.warnings = warnings
        end
        return envelope
    end)
end

---GET /v1/conversations/{id}/items/{item_id}
---@param conversation_id string
---@param item_id string
---@return table|nil, table|nil
function _M.get_item(conversation_id, item_id)
    local s, err = store()
    if not s then
        return nil, err
    end
    local id, ierr = _M.parse_id(conversation_id, "conversation_id")
    if not id then
        return nil, ierr
    end
    local target, terr = _M.parse_id(item_id, "item_id")
    if not target then
        return nil, terr
    end
    local live, gerr = s.get_conversation(id)
    if gerr then
        return nil, gerr
    end
    if not live then
        return nil, not_found("Conversation not found")
    end
    local linked, lerr = s.is_item_linked(id, target)
    if lerr then
        return nil, lerr
    end
    if not linked then
        return nil, not_found("Item not found in this conversation")
    end
    local item, ierr = s.get_item(target)
    if ierr then
        return nil, ierr
    end
    if not item then
        return nil, not_found("Item not found")
    end
    return _M.item_to_json(item)
end

---DELETE /v1/conversations/{id}/items/{item_id}. Rust answers with the
---conversation object, not a deleted marker, so this does too.
---@param conversation_id string
---@param item_id string
---@return table|nil, table|nil
function _M.delete_item(conversation_id, item_id)
    local s, err = store()
    if not s then
        return nil, err
    end
    local id, ierr = _M.parse_id(conversation_id, "conversation_id")
    if not id then
        return nil, ierr
    end
    local target, terr = _M.parse_id(item_id, "item_id")
    if not target then
        return nil, terr
    end
    return _M.with_lock(function()
        local conv, gerr = s.get_conversation(id)
        if gerr then
            return nil, gerr
        end
        if not conv then
            return nil, not_found("Conversation not found")
        end
        local _, uerr = s.unlink_item(id, target)
        if uerr then
            return nil, uerr
        end
        return _M.conversation_to_json(conv)
    end)
end

-- --------------------------------------------------------------- responses API

---Build the stored record from an upstream response payload.
---
---`payload` may be the raw JSON bytes the upstream sent (preferred: they are
---stored verbatim and handed back untouched on GET, so arrays and field order
---survive) or an already-decoded table.
---@param payload string|table
---@return table|nil record, table|nil err
function _M.build_response_record(payload)
    local body, raw_json
    if type(payload) == "string" then
        if payload == "" then
            return nil, bad_request("response payload is empty")
        end
        body = decode(payload)
        if type(body) ~= "table" or is_array(body) then
            return nil, bad_request("response payload is not a JSON object")
        end
        raw_json = payload
    elseif type(payload) == "table" then
        body = payload
        raw_json = nil
    else
        return nil, bad_request("response payload must be a JSON object")
    end
    local id = body.id
    if id ~= nil then
        local parsed, err = _M.parse_id(id, "response_id")
        if not parsed then
            return nil, err
        end
        id = parsed
    else
        id = _M.new_response_id()
        if not id then
            return nil, internal_error("id generation failed")
        end
    end
    local usage
    if type(body.usage) == "table" then
        usage = body.usage
    end
    local output = as_array(body.output)
    local input = as_array(body.input)
    local metadata
    if type(body.metadata) == "table" then
        metadata = body.metadata
    end
    return {
        id = id,
        object = "response",
        status = type(body.status) == "string" and body.status or "completed",
        model = type(body.model) == "string" and body.model or nil,
        usage = usage,
        output = output,
        input_items = input,
        instructions = type(body.instructions) == "string" and body.instructions or nil,
        conversation_id = type(body.conversation) == "string" and body.conversation
            or (type(body.conversation_id) == "string" and body.conversation_id or nil),
        previous_response_id = type(body.previous_response_id) == "string"
            and body.previous_response_id or nil,
        safety_identifier = type(body.safety_identifier) == "string"
            and body.safety_identifier or nil,
        created_at = tonumber(body.created_at) or _M.now(),
        metadata = metadata,
        raw_json = raw_json,
    }
end

---Render a stored record for GET /v1/responses/{id}. The Rust gateway hands back
---stored.raw_response with the id forced to the requested one; here the raw bytes
---are returned whenever they already carry that id, which keeps them byte-exact.
---@param rec table
---@return table|string
function _M.response_to_json(rec)
    if rec.raw_json then
        local body = decode(rec.raw_json)
        if type(body) == "table" and body.id == rec.id then
            return rec.raw_json
        end
    end
    local obj = {
        id = rec.id,
        object = "response",
        created_at = rec.created_at,
        status = rec.status or "completed",
    }
    if rec.model then
        obj.model = rec.model
    end
    if rec.usage then
        obj.usage = rec.usage
    end
    obj.output = as_array(rec.output)
    if rec.instructions then
        obj.instructions = rec.instructions
    end
    if rec.conversation_id then
        obj.conversation = rec.conversation_id
    end
    if rec.previous_response_id then
        obj.previous_response_id = rec.previous_response_id
    end
    if type(rec.metadata) == "table" and next(rec.metadata) ~= nil then
        obj.metadata = rec.metadata
    end
    return obj
end

---Record an upstream response. When the request named a conversation that exists,
---the input and output items are linked into it, as persist_conversation_items
---does; a missing conversation is logged as a warning by the caller and skipped.
---@param payload string|table @ upstream JSON bytes (preferred) or decoded table
---@return table|nil, table|nil
function _M.create_response(payload)
    local s, err = store()
    if not s then
        return nil, err
    end
    local rec, rerr = _M.build_response_record(payload)
    if not rec then
        return nil, rerr
    end
    return _M.with_lock(function()
        s.enforce_response_cap()
        local stored, serr = s.store_response(rec)
        if not stored then
            return nil, serr
        end
        if rec.conversation_id and s.get_conversation(rec.conversation_id) then
            local added_at = rec.created_at
            for i = 1, #(rec.input_items or {}) do
                _M.link_output_item(s, rec.conversation_id, rec.input_items[i],
                    rec.id, added_at, true)
            end
            for i = 1, #(rec.output or {}) do
                _M.link_output_item(s, rec.conversation_id, rec.output[i],
                    rec.id, added_at, false)
            end
        end
        return _M.response_to_json(stored)
    end)
end

---Store and link one response item. Input items keep their whole JSON as content
---for function_call / function_call_output and their content field otherwise;
---output items are stored whole unless they are messages. Same split as
---persistence_utils.rs item_to_new_conversation_item.
---@param s table
---@param conv_id string
---@param value table
---@param response_id string
---@param added_at number
---@param is_input boolean
---@return string|nil item_id
function _M.link_output_item(s, conv_id, value, response_id, added_at, is_input)
    if type(value) ~= "table" then
        return nil
    end
    local item_type = value.type or "message"
    local store_whole
    if is_input then
        store_whole = item_type == "function_call" or item_type == "function_call_output"
    else
        store_whole = item_type ~= "message"
    end
    local content
    if store_whole then
        content = value
    else
        content = content_value(value.content)
    end
    local item_id = value.id
    if item_id ~= nil then
        local parsed = _M.parse_id(item_id, "item_id")
        if not parsed then
            return nil
        end
        item_id = parsed
    else
        item_id = _M.new_item_id(item_type)
    end
    local record = {
        id = item_id,
        item_type = item_type,
        role = type(value.role) == "string" and value.role or nil,
        content = content,
        status = type(value.status) == "string" and value.status or "completed",
        response_id = response_id,
        created_at = added_at,
    }
    if not s.get_item(item_id) then
        s.store_item(record)
    end
    s.link_item(conv_id, item_id, added_at)
    return item_id
end

---GET /v1/responses/{id}
---@param response_id string
---@return table|string|nil, table|nil
function _M.get_response(response_id)
    local s, err = store()
    if not s then
        return nil, err
    end
    local id, ierr = _M.parse_id(response_id, "response_id")
    if not id then
        return nil, ierr
    end
    local rec, gerr = s.get_response(id)
    if gerr then
        return nil, gerr
    end
    if not rec then
        return nil, not_found("No response found with id '" .. id .. "'")
    end
    return _M.response_to_json(rec)
end

---POST /v1/responses/{id}/cancel.
---
---The Rust gateway either proxies cancel to the upstream (http router) or, for a
---profile with no upstream cancel, answers 501 from the trait default. This store
---has no upstream, so it only moves the local record: completed and already
---cancelled responses are rejected the way OpenAI does.
---@param response_id string
---@return table|nil, table|nil
function _M.cancel_response(response_id)
    local s, err = store()
    if not s then
        return nil, err
    end
    local id, ierr = _M.parse_id(response_id, "response_id")
    if not id then
        return nil, ierr
    end
    return _M.with_lock(function()
        local rec, gerr = s.get_response(id)
        if gerr then
            return nil, gerr
        end
        if not rec then
            return nil, not_found("No response found with id '" .. id .. "'")
        end
        if rec.status == "completed" then
            return nil, _M.error(400, "response_not_cancellable",
                "Only a background response that is queued or in progress can be cancelled")
        end
        if rec.status ~= "cancelled" then
            rec.status = "cancelled"
            local stored, serr = s.store_response(rec)
            if not stored then
                return nil, serr
            end
            rec = stored
        end
        return _M.response_to_json(rec)
    end)
end

---DELETE /v1/responses/{id}
---@param response_id string
---@return table|nil, table|nil
function _M.delete_response(response_id)
    local s, err = store()
    if not s then
        return nil, err
    end
    local id, ierr = _M.parse_id(response_id, "response_id")
    if not id then
        return nil, ierr
    end
    return _M.with_lock(function()
        local existed, derr = s.delete_response(id)
        if derr then
            return nil, derr
        end
        -- The memory store reports whether the record was there. The noop store
        -- answers like data_connector's NoOpResponseStorage, i.e. unconditional
        -- success, so `none` never has anything to delete and never 404s.
        if not existed and _M.backend() ~= "none" then
            return nil, not_found("No response found with id '" .. id .. "'")
        end
        return { id = id, object = "response.deleted", deleted = true }
    end)
end

---GET /v1/responses/{id}/input_items
---
---Items without an id get a generated msg_ id, which is what the Rust handler
---does so the list is cursor-addressable. has_more is always false because the
---whole array is returned in one page.
---@param response_id string
---@return table|nil, table|nil
function _M.list_input_items(response_id)
    local s, err = store()
    if not s then
        return nil, err
    end
    local id, ierr = _M.parse_id(response_id, "response_id")
    if not id then
        return nil, ierr
    end
    local rec, gerr = s.get_response(id)
    if gerr then
        return nil, gerr
    end
    if not rec then
        return nil, not_found("No response found with id '" .. id .. "'")
    end
    local items = rec.input_items or {}
    local data = {}
    for i = 1, #items do
        local item = items[i]
        if type(item) == "table" and item.id == nil then
            local copy = { id = _M.new_item_id(item.type or "message") }
            for k, v in pairs(item) do
                copy[k] = v
            end
            item = copy
        end
        data[#data + 1] = item
    end
    return {
        object = "list",
        data = as_array(data),
        first_id = #data > 0 and data[1].id or nil,
        last_id = #data > 0 and data[#data].id or nil,
        has_more = false,
    }
end

---Walk previous_response_id backwards, oldest first, as get_response_chain does.
---@param response_id string
---@param max_depth number|nil @ default 100, the Rust default
---@return table|nil @ {responses = [...], latest_id = string|nil}
---@return table|nil err
function _M.get_response_chain(response_id, max_depth)
    local s, err = store()
    if not s then
        return nil, err
    end
    local id, ierr = _M.parse_id(response_id, "response_id")
    if not id then
        return nil, ierr
    end
    max_depth = tonumber(max_depth) or 100
    local ids = {}
    local seen = {}
    local current = id
    while current and #ids < max_depth do
        if seen[current] then
            return nil, _M.error(400, "response_chain_cycle",
                "previous_response_id chain loops at '" .. current .. "'")
        end
        seen[current] = true
        local rec, gerr = s.get_response(current)
        if gerr then
            return nil, gerr
        end
        if not rec then
            break
        end
        ids[#ids + 1] = rec
        current = rec.previous_response_id
    end
    local out = _M.array()
    for i = #ids, 1, -1 do
        out[#out + 1] = _M.response_to_json(ids[i])
    end
    return { responses = out, latest_id = #ids > 0 and ids[1].id or nil }
end

-- ================================================================== operations

---Contents of the store plus the counters, for /_ui and the tests.
---@return table
function _M.stats()
    local out = { backend = _M.backend(), supported = true }
    local ok, err = _M.backend_supported()
    if not ok then
        out.supported = false
        out.error = err
        return out
    end
    -- A registered backend (redis) owns its own counters; the memory dict
    -- numbers below only describe the memory store.
    local custom = _M.BACKENDS[_M.backend()]
    if custom and type(custom.stats) == "function" then
        return custom.stats()
    end
    if _M.backend() ~= "memory" or not _M.dict() then
        out.conversations = _M.backend() == "none" and 0 or nil
        out.responses = out.conversations
        return out
    end
    local d0 = _M.dict()
    out.conversations = d0:incr(N_CONV, 0, 0) or 0
    out.responses = d0:incr(N_RESP, 0, 0) or 0
    out.limits = {
        max_conversations = _M.config().max_conversations,
        max_items_per_conversation = _M.config().max_items_per_conversation,
        max_responses = _M.config().max_responses,
        max_items_per_request = _M.config().max_items_per_request,
        ttl_secs = _M.config().ttl_secs,
    }
    return out
end

---Run the capacity sweeps by hand. Cheap enough for a timer; the router can call
---it from the same place it runs the policy eviction sweep.
---@return table @ {dropped_conversations, dropped_responses}
function _M.sweep()
    local out = { dropped_conversations = 0, dropped_responses = 0 }
    local ok = _M.backend_supported()
    local custom = _M.BACKENDS[_M.backend()]
    if custom and type(custom.sweep) == "function" then
        local res, serr = custom.sweep()
        if not res then
            out.error = serr
            return out
        end
        return res
    end
    if not ok or _M.backend() ~= "memory" or not _M.dict() then
        return out
    end
    out.dropped_conversations = _M.memory_store.enforce_conversation_cap()
    out.dropped_responses = _M.memory_store.enforce_response_cap()
    return out
end

---Wipe the history store. Only touches this module's own keys.
---@return boolean
function _M.flush_all()
    local custom = _M.BACKENDS[_M.backend()]
    if custom and type(custom.flush_all) == "function" then
        return custom.flush_all()
    end
    local d0 = _M.dict()
    if not d0 then
        return false
    end
    for _, key in ipairs(d0:get_keys(0)) do
        if string.sub(key, 1, #K_CONV) == K_CONV
            or string.sub(key, 1, #K_ITEM) == K_ITEM
            or string.sub(key, 1, #K_LINK) == K_LINK
            or string.sub(key, 1, #K_REV) == K_REV
            or string.sub(key, 1, #K_RESP) == K_RESP
            or string.sub(key, 1, #K_SEQ) == K_SEQ
            or key == G_SEQ or key == N_CONV or key == N_RESP then
            d0:delete(key)
        end
    end
    return true
end

-- Exposed for the tests and the sweep, which need to name the keys.
_M.KEYS = {
    conv = K_CONV, item = K_ITEM, link = K_LINK, rev = K_REV, resp = K_RESP,
    seq = K_SEQ, global_seq = G_SEQ, n_conv = N_CONV, n_resp = N_RESP,
}
_M.score = score

return _M
