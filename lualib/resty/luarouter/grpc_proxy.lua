-- gRPC forwarding layer for the Lua router.
--
-- What the prototype on this box proved about authz:latest (OpenResty 1.31.1.1,
-- nginx 1.31.1) -- see doc/gap-grpc-pd.md for the raw transcript:
--   * ngx_http_grpc_module is compiled in (the binary carries the
--     ngx_http_grpc_module / grpc_pass / grpc_read_timeout symbols; nginx builds
--     it by default and the image does not pass --without-http_grpc_module)
--   * grpc_pass must live in location{}; in server{} nginx says
--     '"grpc_pass" directive is not allowed here'
--   * grpc_pass forwards the raw :path, so a location prefix reaches the
--     backend. Unlike proxy_pass there is no URI normalisation, so a PD/regular
--     gRPC worker needs `rewrite ^/prefix(/.*)$ $1 break;` or an exact-match
--     location, otherwise the backend answers UNIMPLEMENTED "Method not found!"
--   * the backend address can be a variable (grpc_pass grpc://$lr_grpc_peer) or
--     an upstream{} block driven by balancer_by_lua; both work and the balancer
--     runs once per gRPC call, so per-request worker selection survives
--   * unary, server-streaming (incremental, not buffered) and bidi streaming all
--     pass through; grpc-status / grpc-message and *custom* trailing metadata
--     reach the client (nginx adds its own server/date headers to the trailer set)
--   * the client's grpc-timeout header is forwarded and honoured end to end
--   * grpcs:// works with grpc_ssl_verify off
--   * the module does NOT multiplex onto one upstream connection: 100 concurrent
--     calls hold 100 established TCP connections to one worker, so upstream
--     keepalive buys nothing for gRPC
--
-- The Lua surface therefore has three parts:
--   1. pure helpers (framing, timeout encoding, deadline resolution, status and
--      header policy) that unit tests can drive without nginx
--   2. access_by_lua: pick the worker, publish the peer + headers into nginx
--      variables so grpc_pass can act on them
--   3. balancer_by_lua: hand that peer to nginx, and report failures the way the
--      HTTP path reports them
--
-- gRPC-over-HTTP/2 in OpenResty keeps one nginx request per gRPC call, which is
-- fine for LLM serving (one call per completion) but means a client that
-- multiplexes 200 calls onto one connection gets 200 upstream connections here.

local _M = { _VERSION = "0.1.0" }

-- nginx variables the template must `set` in server{} for the gRPC locations.
_M.VAR_PEER = "lr_grpc_peer"
_M.VAR_HOST = "lr_grpc_host"
_M.VAR_PORT = "lr_grpc_port"
_M.VAR_SCHEME = "lr_grpc_scheme"
_M.VAR_TIMEOUT = "lr_grpc_timeout"
_M.VAR_WORKER = "lr_grpc_worker"

local TLS_SCHEMES = { grpcs = true, https = true }

----------------------------------------------------------------------
-- worker url -> nginx upstream peer
----------------------------------------------------------------------

---Split a worker url into host/port/tls for grpc_pass. Accepts grpc:// and
---grpcs:// (the Rust gateway's scheme vocabulary, config/validation.rs allows
---http://, https:// and grpc://) as well as plain http(s) urls, because sglang
---workers are usually registered with an http url and reached on a separate gRPC
---port.
---@param url string @ e.g. grpc://10.0.0.1:20000, grpcs://h:443, http://h:30001@2
---@return string|nil host, number|nil port, boolean tls, string|nil err
function _M.parse_worker(url)
    if type(url) ~= "string" or url == "" then
        return nil, nil, false, "url is required"
    end
    -- Drop the DP-rank suffix (http://host:port@3), which is metadata, not part
    -- of the address. Same rule as registry.split_url / Rust
    -- parse_bootstrap_host_from_url.
    local base = url:gsub("@(%d+)$", "")
    local scheme, rest = base:match("^(%a[%w+.-]*)://(.+)$")
    if not scheme then
        scheme, rest = "http", base
    end
    scheme = scheme:lower()
    if scheme == "grpc" or scheme == "http" then
        -- plain
    elseif scheme == "grpcs" or scheme == "https" then
        -- tls
    else
        return nil, nil, false, "unsupported worker scheme: " .. scheme
    end
    local tls = (scheme == "grpcs" or scheme == "https")

    -- strip path/query; grpc_pass takes only host:port
    rest = rest:gsub("/.*$", ""):gsub("%?.*$", ""):gsub("#.*$", "")

    local host, port
    if rest:match("^%[") then
        -- bracketed IPv6: [::1]:20000
        host, port = rest:match("^%[([0-9a-fA-F:.]-)%]:(%d+)$")
        if not host then
            host = rest:match("^%[([0-9a-fA-F:.]-)%]$")
        end
    else
        host, port = rest:match("^([^:]+):(%d+)$")
        if not host then
            host = rest:match("^([^:]-):?$")
        end
    end
    if not host or host == "" then
        return nil, nil, tls, "invalid worker url: " .. url
    end
    local number = tonumber(port)
    if not number then
        number = tls and 443 or (scheme == "grpc" or scheme == "grpcs") and 50051 or 80
    end
    if number < 1 or number > 65535 then
        return nil, nil, tls, "port out of range: " .. url
    end
    return host, number, tls
end

---Render the peer string grpc_pass expects (bracketed IPv6, host:port).
---@param host string
---@param port number
---@return string peer
function _M.format_peer(host, port)
    if host:find(":") then
        return "[" .. host .. "]:" .. port
    end
    return host .. ":" .. port
end

----------------------------------------------------------------------
-- deadline (grpc-timeout) handling
----------------------------------------------------------------------

-- grpc-timeout wire format: at most 8 ASCII digits plus one unit character,
-- where n=nanoseconds, u=microseconds, m=milliseconds, S=seconds, M=minutes and
-- H=hours. nginx forwards the header untouched, so the router only has to encode
-- it and, when both an incoming deadline and a local cap exist, keep the tighter
-- one (a deadline can only be tightened downstream).
--
-- Everything is computed in whole nanoseconds: the units are all decimal
-- multiples of each other, so integer divisibility picks the coarsest exact unit
-- without any float comparison, and 1 ms encodes as "1m" rather than "1000u".
_M.UNIT_NS = { H = 3600e9, M = 60e9, S = 1e9, m = 1e6, u = 1e3, n = 1 }
local UNIT_ORDER = { "H", "M", "S", "m", "u", "n" }
local MAX_DIGITS = 99999999
local NS_EXACT_LIMIT = 2 ^ 53

---Seconds encoded by a grpc-timeout value.
---@param value string|nil @ e.g. "5S", "100m", "7n"
---@return number|nil secs, string|nil err
function _M.parse_grpc_timeout(value)
    if value == nil or value == "" then
        return nil
    end
    if type(value) ~= "string" then
        return nil, "grpc-timeout must be a string"
    end
    -- Reject anything off-spec rather than forwarding a header the backend would
    -- answer with an INTERNAL error.
    local digits, unit = value:match("^(%d+)([HMSmun])$")
    if not digits or #digits > 8 then
        return nil, "invalid grpc-timeout: " .. value
    end
    return tonumber(digits) * _M.UNIT_NS[unit] / 1e9
end

---Nanoseconds encoded by a grpc-timeout value, nil when out of range.
---@param value string|nil
---@return number|nil ns, string|nil err
function _M.parse_grpc_timeout_ns(value)
    if value == nil or value == "" then
        return nil
    end
    if type(value) ~= "string" then
        return nil, "grpc-timeout must be a string"
    end
    local digits, unit = value:match("^(%d+)([HMSmun])$")
    if not digits or #digits > 8 then
        return nil, "invalid grpc-timeout: " .. value
    end
    return tonumber(digits) * _M.UNIT_NS[unit]
end

---grpc-timeout value for a number of seconds.
---@param secs number
---@return string|nil value
function _M.format_grpc_timeout(secs)
    if type(secs) ~= "number" or secs <= 0 or secs ~= secs or secs == math.huge then
        return nil
    end
    if secs * 1e9 > NS_EXACT_LIMIT then
        -- Past ~104 days whole nanoseconds stop being exact; hours are the
        -- coarsest unit and 8 digits of hours reach 114 years.
        local hours = math.floor(secs / 3600 + 0.5)
        if hours < 1 then
            hours = 1
        elseif hours > MAX_DIGITS then
            hours = MAX_DIGITS
        end
        return hours .. "H"
    end
    local ns = math.floor(secs * 1e9 + 0.5)
    if ns < 1 then
        ns = 1
    end
    for i = 1, #UNIT_ORDER do
        local unit = UNIT_ORDER[i]
        local divisor = _M.UNIT_NS[unit]
        local value = ns / divisor
        if value >= 1 and value <= MAX_DIGITS and math.floor(value) == value then
            return math.floor(value) .. unit
        end
    end
    -- No unit divides it exactly and fits 8 digits: round up in nanoseconds so
    -- the deadline is never silently extended.
    if ns > MAX_DIGITS then
        return MAX_DIGITS .. "n"
    end
    return ns .. "n"
end

---Nanoseconds -> grpc-timeout value (exact, no rounding to do).
---@param ns number
---@return string|nil value
function _M.format_grpc_timeout_ns(ns)
    if type(ns) ~= "number" or ns < 1 then
        return nil
    end
    return _M.format_grpc_timeout(ns / 1e9)
end

---Resolve the deadline for one call: the client's grpc-timeout wins when it is
---shorter than the router's request_timeout_secs, because gRPC semantics say a
---deadline propagates and can only be tightened downstream.
---@param incoming string|nil @ client grpc-timeout header
---@param cap_secs number|nil @ router request_timeout_secs
---@return string|nil value @ header to send upstream, nil = send none
function _M.resolve_timeout(incoming, cap_secs)
    local incoming_ns, err = _M.parse_grpc_timeout_ns(incoming)
    if err then
        -- A malformed client deadline is not ours to fix; pass it through
        -- untouched so the backend produces the error the client expects.
        return incoming
    end
    local cap_ns
    if type(cap_secs) == "number" and cap_secs > 0 and cap_secs == cap_secs then
        cap_ns = math.floor(cap_secs * 1e9 + 0.5)
    end
    local chosen
    if incoming_ns and cap_ns then
        chosen = math.min(incoming_ns, cap_ns)
    else
        chosen = incoming_ns or cap_ns
    end
    if not chosen then
        return nil
    end
    return _M.format_grpc_timeout_ns(chosen)
end

----------------------------------------------------------------------
-- request framing (for the cosocket fallback path, not for grpc_pass)
----------------------------------------------------------------------

---Length-prefixed gRPC message: 1 compression flag byte + 4-byte big-endian
---length + payload. Needed by any cosocket/HTTP2-less client and by tests that
---assert what nginx would have forwarded.
---@param payload string
---@param compressed boolean|nil
---@return string frame
function _M.encapsulate(payload, compressed)
    local bytes = payload or ""
    local flag = compressed and 1 or 0
    local n = #bytes
    return string.char(flag,
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256) .. bytes
end

---Inverse of encapsulate over a complete buffer.
---@param frame string
---@return string|nil payload, number|nil consumed, string|nil err
function _M.decapsulate(frame)
    if type(frame) ~= "string" or #frame < 5 then
        return nil, nil, "frame too short"
    end
    local b1, b2, b3, b4 = frame:byte(2, 5)
    local n = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
    if #frame < 5 + n then
        return nil, nil, "incomplete message"
    end
    return frame:sub(6, 5 + n), 5 + n
end

----------------------------------------------------------------------
-- minimal protobuf wire codec (PD native body injection)
----------------------------------------------------------------------

-- The byte-forwarding proxy never needed to understand a gRPC message until PD
-- bootstrap had to be written into sglang's proto instead of riding along as
-- metadata. Only the pieces of the wire format that job requires are here:
-- varint, length-delimited, fixed32/64 (skipped, never interpreted) and nested
-- messages, with every field -- known or unknown -- kept as its *verbatim*
-- encoded bytes so a rewrite cannot lose data the router does not understand.
--
-- Field numbers and types come from the vendored schema the Rust gateway
-- compiles (crates.io smg-grpc-client-1.0.0/proto/sglang_scheduler.proto, which
-- is what gateway/target/debug/build/*/out/sglang.grpc.scheduler.rs encodes):
--
--   message GenerateRequest {           -- /sglang.grpc.scheduler.SglangScheduler/Generate
--     ...                                 request_id = 1 (string)
--     DisaggregatedParams disaggregated_params = 10;   -- length-delimited
--   }
--   message DisaggregatedParams {
--     string bootstrap_host = 1;
--     int32  bootstrap_port = 2;
--     int32  bootstrap_room = 3;
--   }
--
-- helpers.rs inject_bootstrap_metadata writes exactly those three fields; the
-- 101/102/103 tags below are *ours*, documented in doc/gap-grpc-proto.md: the
-- vendored proto has no place for the decode peer because Rust does not need one
-- (it dual-dispatches to both workers instead of relaying through prefill), and
-- one nginx request has exactly one grpc_pass upstream. A proto3 parser that
-- does not know them skips them as unknown fields, which is harmless.
_M.WIRE_VARINT  = 0
_M.WIRE_FIXED64 = 1
_M.WIRE_LEN     = 2
_M.WIRE_GROUP_S = 3   -- deprecated groups: rejected, which routes the call to
_M.WIRE_GROUP_E = 4   -- the metadata fallback rather than risk corrupting a body
_M.WIRE_FIXED32 = 5

_M.DISAGG_MSG_FIELD = 10      -- GenerateRequest.disaggregated_params
_M.DISAGG_FIELD = {
    bootstrap_host  = 1,      -- string
    bootstrap_port  = 2,      -- int32
    bootstrap_room  = 3,      -- int32
    decode_host     = 101,    -- string, router extension (no native field exists)
    decode_port     = 102,    -- int32,  router extension
    prefill_dp_rank = 103,    -- int32,  router extension
}
---A GenerateRequest is the only PD carrier in the schema; Chat/Embed requests
---are built from it upstream, and every sglang PD method ends in /Generate.
_M.GENERATE_METHOD = "Generate"

---Cap on how much of an upstream body the rewriter will materialise in a Lua
---string. read_body() above this size spills to a temp file and copying it into
---the worker would cost more than the feature is worth, so the call keeps the
---metadata carrier instead.
_M.PD_MAX_BODY_BYTES = 8 * 1024 * 1024

---Wire encoding of a non-negative integer.
---@param n number
---@return string|nil bytes
local function encode_varint(n)
    if type(n) ~= "number" or n < 0 or n ~= n or n >= 2 ^ 63 then
        return nil
    end
    local out = {}
    local value = math.floor(n)
    repeat
        local byte = value % 128
        value = math.floor(value / 128)
        if value > 0 then
            byte = byte + 128
        end
        out[#out + 1] = byte
    until value == 0
    return string.char(table.unpack(out))
end

---Wire encoding of an int32, including the 10-byte sign-extended form prost and
---protoc use for negative int32/int64 values.
---@param n number
---@return string|nil bytes
local function encode_int32(n)
    if type(n) ~= "number" or n ~= n or n < -2147483648 or n > 2147483647 then
        return nil
    end
    if n >= 0 then
        return encode_varint(n)
    end
    -- -2^31 <= n < 0: the encoded value is n mod 2^64, i.e. the low 32 bits
    -- followed by five all-ones groups and the final bit 63.
    local out = {}
    local low = n % 4294967296
    for _ = 1, 4 do
        out[#out + 1] = (low % 128) + 128
        low = math.floor(low / 128)
    end
    out[#out + 1] = (low % 128) + 112 + 128   -- bits 28..31 plus the ones at 32..34
    for _ = 1, 4 do
        out[#out + 1] = 255
    end
    out[#out + 1] = 1
    return string.char(table.unpack(out))
end

_M.encode_varint = encode_varint
_M.encode_int32 = encode_int32

---Read a varint. Values are only decoded where a caller needs the number, so
---anything past 2^53 is refused rather than silently rounded.
---@param s string
---@param i number @ 1-based position
---@return number|nil value, number|nil next_i, string|nil err
function _M.decode_varint(s, i)
    local value = 0
    local shift = 1
    local pos = i or 1
    for byte_index = 1, 10 do
        local byte = s:byte(pos)
        if not byte then
            return nil, nil, "truncated varint"
        end
        value = value + (byte % 128) * shift
        if value >= 2 ^ 53 then
            return nil, nil, "varint beyond exact range"
        end
        pos = pos + 1
        if byte < 128 then
            return value, pos
        end
        shift = shift * 128
    end
    return nil, nil, "varint overlong"
end

---Skip a varint without interpreting it (used for unknown fields).
---@param s string
---@param i number
---@return number|nil next_i, string|nil err
function _M.skip_varint(s, i)
    local pos = i or 1
    for _ = 1, 10 do
        local byte = s:byte(pos)
        if not byte then
            return nil, "truncated varint"
        end
        pos = pos + 1
        if byte < 128 then
            return pos
        end
    end
    return nil, "varint overlong"
end

---Split one protobuf message into its fields, keeping each field's encoded bytes
---untouched. Groups and malformed tags are errors: the caller then leaves the
---body alone, which is always safer than guessing.
---@param s string
---@return table|nil fields @ array of {field=n, wire=w, raw=string, payload=string|nil}
---@return string|nil err
function _M.parse_message(s)
    if type(s) ~= "string" then
        return nil, "message required"
    end
    local fields = {}
    local pos, len = 1, #s
    while pos <= len do
        local tag, next_pos, err = _M.decode_varint(s, pos)
        if not tag then
            return nil, err
        end
        local field = math.floor(tag / 8)
        local wire = tag % 8
        if field < 1 then
            return nil, "field number 0"
        end
        if wire == _M.WIRE_VARINT then
            local stop
            stop, err = _M.skip_varint(s, next_pos)
            if not stop then
                return nil, err
            end
            fields[#fields + 1] = {
                field = field, wire = wire, raw = s:sub(pos, stop - 1),
                payload = s:sub(next_pos, stop - 1),
            }
            pos = stop
        elseif wire == _M.WIRE_LEN then
            local size
            size, next_pos, err = _M.decode_varint(s, next_pos)
            if not size then
                return nil, err
            end
            if size > 2 ^ 31 or next_pos + size - 1 > len then
                return nil, "length-delimited field truncated"
            end
            local stop = next_pos + size
            fields[#fields + 1] = {
                field = field, wire = wire, raw = s:sub(pos, stop - 1),
                payload = s:sub(next_pos, stop - 1),
            }
            pos = stop
        elseif wire == _M.WIRE_FIXED64 then
            -- The tag is variable-length, so the payload starts at next_pos, not
            -- at pos: raw spans tag plus the eight payload bytes.
            if next_pos + 8 > len + 1 then
                return nil, "truncated fixed64"
            end
            fields[#fields + 1] = {
                field = field, wire = wire, raw = s:sub(pos, next_pos + 7),
                payload = s:sub(next_pos, next_pos + 7),
            }
            pos = next_pos + 8
        elseif wire == _M.WIRE_FIXED32 then
            if next_pos + 4 > len + 1 then
                return nil, "truncated fixed32"
            end
            fields[#fields + 1] = {
                field = field, wire = wire, raw = s:sub(pos, next_pos + 3),
                payload = s:sub(next_pos, next_pos + 3),
            }
            pos = next_pos + 4
        else
            return nil, "unsupported wire type " .. wire .. " (groups are not rewritten)"
        end
    end
    return fields
end

---Concatenate parsed fields back into a message.
---@param fields table[]
---@return string
function _M.serialize_fields(fields)
    local out = {}
    for i = 1, #fields do
        out[i] = fields[i].raw
    end
    return table.concat(out)
end

---One length-delimited field, tag and all.
---@param field number
---@param payload string
---@return string
function _M.encode_len_field(field, payload)
    local tag = encode_varint(field * 8 + _M.WIRE_LEN)
    return tag .. encode_varint(#payload) .. payload
end

---One varint field, tag and all.
---@param field number
---@param value number @ int32 range
---@return string|nil
function _M.encode_int_field(field, value)
    local tag = encode_varint(field * 8 + _M.WIRE_VARINT)
    local encoded = encode_int32(value)
    if not tag or not encoded then
        return nil
    end
    return tag .. encoded
end

---Drop every existing occurrence of `field` and append `raw`. Field order is
---unspecified in the wire format, so an in-place rewrite is as valid as an
---append; keeping the position of a field that was already there is what makes
---the diff observable in the e2e checks.
---@param fields table[]
---@param field number
---@param raw string
---@return table[] fields
function _M.replace_field(fields, field, raw)
    local out = {}
    local n = 0
    for i = 1, #fields do
        if fields[i].field ~= field then
            n = n + 1
            out[n] = fields[i]
        end
    end
    out[n + 1] = { field = field, raw = raw }
    return out
end

---Find the first occurrence of a field.
---@param fields table[]
---@param field number
---@return table|nil field
function _M.find_field(fields, field)
    for i = 1, #fields do
        if fields[i].field == field then
            return fields[i]
        end
    end
    return nil
end

---Set DisaggregatedParams (field 10) on a GenerateRequest message, in place,
---preserving every other field byte for byte -- including fields the router does
---not know. See the block comment above for the schema this encodes.
---@param message string @ GenerateRequest bytes (no gRPC frame header)
---@param params table @ {bootstrap_host, bootstrap_port, bootstrap_room, decode_host?, decode_port?, prefill_dp_rank?}
---@return string|nil rewritten, table|nil report @ {replaced=..., set={field=true}}
---@return string|nil err
function _M.inject_disaggregated_params(message, params)
    if type(message) ~= "string" then
        return nil, nil, "message required"
    end
    if type(params) ~= "table" then
        return nil, nil, "params required"
    end
    local outer, err = _M.parse_message(message)
    if not outer then
        return nil, nil, err
    end

    local existing = _M.find_field(outer, _M.DISAGG_MSG_FIELD)
    local inner = {}
    if existing then
        if existing.wire ~= _M.WIRE_LEN then
            return nil, nil, "disaggregated_params is not a message on the wire"
        end
        inner, err = _M.parse_message(existing.payload or "")
        if not inner then
            return nil, nil, err
        end
    end

    local report = { replaced = existing ~= nil, set = {} }
    local function set_string(field, value)
        if type(value) ~= "string" or value == "" then
            return nil, "field " .. field .. " needs a non-empty string"
        end
        inner = _M.replace_field(inner, field, _M.encode_len_field(field, value))
        report.set[field] = "string"
        return true
    end
    local function set_int(field, value)
        local number = tonumber(value)
        if not number then
            return nil, "field " .. field .. " needs a number"
        end
        local encoded = _M.encode_int_field(field, number)
        if not encoded then
            return nil, "field " .. field .. " out of int32 range"
        end
        inner = _M.replace_field(inner, field, encoded)
        report.set[field] = "int32"
        return true
    end

    local ok, field_err = set_string(_M.DISAGG_FIELD.bootstrap_host, params.bootstrap_host)
    if not ok then
        return nil, nil, field_err
    end
    ok, field_err = set_int(_M.DISAGG_FIELD.bootstrap_port, params.bootstrap_port)
    if not ok then
        return nil, nil, field_err
    end
    ok, field_err = set_int(_M.DISAGG_FIELD.bootstrap_room, params.bootstrap_room)
    if not ok then
        return nil, nil, field_err
    end
    if params.decode_host then
        ok, field_err = set_string(_M.DISAGG_FIELD.decode_host, params.decode_host)
        if not ok then
            return nil, nil, field_err
        end
    end
    if params.decode_port then
        ok, field_err = set_int(_M.DISAGG_FIELD.decode_port, params.decode_port)
        if not ok then
            return nil, nil, field_err
        end
    end
    if params.prefill_dp_rank then
        ok, field_err = set_int(_M.DISAGG_FIELD.prefill_dp_rank, params.prefill_dp_rank)
        if not ok then
            return nil, nil, field_err
        end
    end

    outer = _M.replace_field(outer, _M.DISAGG_MSG_FIELD,
        _M.encode_len_field(_M.DISAGG_MSG_FIELD, _M.serialize_fields(inner)))
    return _M.serialize_fields(outer), report
end

---Is `path` an sglang gRPC method whose request message can carry
---DisaggregatedParams? grpc_pass forwards :path untouched, so this is the client's
---own method name (e.g. /sglang.grpc.scheduler.SglangScheduler/Generate).
---@param path string|nil
---@return boolean
function _M.is_generate_path(path)
    if type(path) ~= "string" then
        return false
    end
    return path:match("/([^/]+)$") == _M.GENERATE_METHOD
end

---Rewrite a whole gRPC request buffer that holds exactly one uncompressed
---GenerateRequest. Anything else (streaming, compressed, ≠1 frame, unparsable) is
---an error, and the caller keeps the metadata carrier.
---@param body string @ bytes as nginx read them, frame headers included
---@param params table
---@return string|nil rewritten, table|nil report
---@return string|nil err
function _M.rewrite_generate_body(body, params)
    if type(body) ~= "string" or body == "" then
        return nil, nil, "empty body"
    end
    local payload, consumed, err = _M.decapsulate(body)
    if not payload then
        return nil, nil, err or "unframeable body"
    end
    if consumed ~= #body then
        return nil, nil, "body is not a single message (" .. tostring(consumed) .. "/" .. #body .. ")"
    end
    if body:byte(1) ~= 0 then
        return nil, nil, "compressed message is not rewritten"
    end
    local message, report = _M.inject_disaggregated_params(payload, params)
    if not message then
        return nil, nil, report or "inject failed"
    end
    return _M.encapsulate(message), report
end

---Should PD write its native body fields? See _M.pd_carrier.
---@return string carrier @ "body" | "metadata" | "none"
function _M.pd_carrier()
    local raw = os.getenv("LR_GRPC_PD_METADATA")
    if raw == nil then
        -- Native proto body injection is the default: it is what the Rust
        -- gateway writes and what stock sglang reads.
        return "body"
    end
    local lowered = string.lower(raw)
    if lowered == "on" or lowered == "1" or lowered == "true" or lowered == "yes"
        or lowered == "metadata" then
        return "metadata"
    end
    if lowered == "off" or lowered == "0" or lowered == "false" or lowered == "no"
        or lowered == "none" then
        return "none"
    end
    return "body"
end

----------------------------------------------------------------------
-- header policy
----------------------------------------------------------------------

-- Headers the router itself owns on the gRPC path. content-type must stay
-- application/grpc, te is what makes the backend emit trailers at all, and
-- grpc-timeout is regenerated per request. Everything else follows the HTTP
-- path's allow-list so a tenant's authorization header still arrives.
_M.GRPC_REQUIRED_HEADERS = {
    ["content-type"] = "application/grpc",
    ["te"] = "trailers",
}

---Headers that must never be copied onto a gRPC upstream request: the pseudo
---headers nginx synthesises, plus the hop-by-hop set the HTTP path already drops.
local GRPC_DROP_HEADERS = {
    [":method"] = true, [":path"] = true, [":scheme"] = true, [":authority"] = true,
    host = true, connection = true, ["keep-alive"] = true,
    ["proxy-authenticate"] = true, ["proxy-authorization"] = true,
    ["transfer-encoding"] = true, upgrade = true, ["content-length"] = true,
}
_M.GRPC_DROP_HEADERS = GRPC_DROP_HEADERS

---Build the upstream header table for one gRPC call.
---
---`forward` decides which client headers survive and defaults to the HTTP path's
---should_forward_request_header (authorization, x-request-id*, traceparent,
---tracestate, x-smg-routing-key), so both transports expose the same tenancy and
---tracing surface. grpc_pass cannot take a per-request header map from Lua
---directly: the values land in nginx variables and the location's grpc_set_header
---lines name them, which is why this returns a table rather than touching ngx.
---@param headers table @ client request headers (lower-cased keys)
---@param opts table|nil @ {forward=fn(name)->bool, timeout=string|nil, worker_api_key=string|nil, extra=table}
---@return table out
function _M.build_metadata(headers, opts)
    opts = opts or {}
    local forward = opts.forward
    if type(forward) ~= "function" then
        -- Same rule as router.lua should_forward_request_header, inlined so this
        -- module loads without dragging the router in.
        local ALLOW = {
            authorization = true, ["x-request-id"] = true,
            ["x-correlation-id"] = true, traceparent = true, tracestate = true,
            ["x-smg-routing-key"] = true,
        }
        forward = function(name)
            local lower = string.lower(name)
            if ALLOW[lower] then
                return true
            end
            return lower:sub(1, #("x-request-id-")) == "x-request-id-"
        end
    end

    local out = {}
    if type(headers) == "table" then
        for name, value in pairs(headers) do
            local lower = string.lower(name)
            if not GRPC_DROP_HEADERS[lower] and type(value) == "string"
                and forward(lower) then
                out[lower] = value
            end
        end
    end
    for name, value in pairs(_M.GRPC_REQUIRED_HEADERS) do
        out[name] = value
    end
    if opts.timeout then
        out["grpc-timeout"] = opts.timeout
    end
    if opts.worker_api_key and not out["authorization"] then
        out["authorization"] = "Bearer " .. opts.worker_api_key
    end
    if type(opts.extra) == "table" then
        for name, value in pairs(opts.extra) do
            out[string.lower(name)] = value
        end
    end
    return out
end

----------------------------------------------------------------------
-- status mapping
----------------------------------------------------------------------

-- gRPC status -> HTTP status, the mapping the Rust gateway's gRPC routers rely on
-- when they turn a transport failure into an axum response. Kept as a table so
-- the breaker can classify a gRPC failure with the same is_retryable_status rule
-- it applies to HTTP codes.
_M.GRPC_TO_HTTP = {
    [0] = 200,  [1] = 499,  [2] = 400,  [3] = 400,  [4] = 504,  [5] = 404,
    [6] = 409,  [7] = 403,  [8] = 422,  [9] = 400,  [10] = 409, [11] = 400,
    [12] = 501, [13] = 500, [14] = 503, [15] = 500, [16] = 500,
}
_M.GRPC_NAME = {
    "OK", "CANCELLED", "UNKNOWN", "INVALID_ARGUMENT", "DEADLINE_EXCEEDED",
    "NOT_FOUND", "ALREADY_EXISTS", "PERMISSION_DENIED", "RESOURCE_EXHAUSTED",
    "FAILED_PRECONDITION", "ABORTED", "OUT_OF_RANGE", "UNIMPLEMENTED",
    "INTERNAL", "UNAVAILABLE", "DATA_LOSS", "UNAUTHENTICATED",
}

---@param code number|nil @ grpc-status
---@return number http
function _M.http_status_for_grpc(code)
    if type(code) ~= "number" then
        return 502
    end
    return _M.GRPC_TO_HTTP[code] or 500
end

---@param status number @ HTTP status
---@return number|nil grpc_code
function _M.grpc_status_for_http(status)
    if status == 200 then return 0 end
    if status == 400 then return 3 end
    if status == 401 then return 16 end
    if status == 403 then return 7 end
    if status == 404 then return 12 end
    if status == 409 then return 6 end
    if status == 422 then return 9 end
    if status == 429 then return 8 end
    if status == 499 then return 1 end
    if status == 501 then return 12 end
    if status == 503 then return 14 end
    if status == 504 then return 4 end
    return 13
end

----------------------------------------------------------------------
-- request classification
----------------------------------------------------------------------

---Is this request a gRPC call (rather than an OpenAI HTTP call)?
---@param content_type string|nil
---@return boolean
function _M.is_grpc_content_type(content_type)
    if type(content_type) ~= "string" then
        return false
    end
    return content_type:lower():find("^application/grpc") ~= nil
end

---Worker's gRPC target.
---
---Three spellings are in the wild and all three mean the same thing here, in this
---precedence order:
---  1. the record's own `grpc_port`/`grpc_tls`, which registry.add derives from
---     `connection_mode = {type="grpc", port=n}` or a grpc(s):// url;
---  2. `labels.grpc_port` (the sglang convention: register the http url, expose
---     gRPC on SGLANG_GRPC_PORT);
---  3. the url itself, which is the whole answer for a bare grpc:// record.
---@param worker table
---@return string|nil host, number|nil port, boolean tls, string|nil err
function _M.target_for(worker)
    if type(worker) ~= "table" then
        return nil, nil, false, "worker required"
    end
    local labels = worker.labels or {}
    local host, port, tls, err = _M.parse_worker(worker.url)
    if not host then
        return nil, nil, false, err
    end
    local override = tonumber(worker.grpc_port) or tonumber(labels.grpc_port)
    if override and override >= 1 and override <= 65535 then
        port = override
    end
    if labels.grpc_tls ~= nil then
        tls = (labels.grpc_tls == true or labels.grpc_tls == "true" or labels.grpc_tls == 1)
    end
    if worker.grpc_tls ~= nil then
        tls = worker.grpc_tls and true or false
    end
    if worker.connection_mode == "grpcs" then
        tls = true
    end
    return host, port, tls
end

----------------------------------------------------------------------
-- address form
----------------------------------------------------------------------

---Is the host already an IP literal?
---
---This decides which of the two working upstream forms a worker can use.
---balancer_by_lua's set_current_peer takes (host, port) but rejects a name with
---"no host allowed" (verified on this box against a `grpc://localhost:19600`
---worker), whereas `grpc_pass grpc://$var` resolves names through the http{}
---resolver, at a measured p50 of 0.9 ms versus 0.8 ms for a literal -- the
---resolver cache makes the difference invisible. So the production path should be
---the variable upstream, and the balancer path is only for IP-addressed fleets.
---@param host string|nil
---@return boolean
function _M.ip_literal(host)
    if type(host) ~= "string" or host == "" then
        return false
    end
    if host:find(":") then
        -- IPv6 literal (a colon never appears in a hostname): only hex digits,
        -- colons and the embedded-IPv4 dots, and at least one colon-delimited
        -- group. Covers ::1, 2001:db8::1 and ::ffff:10.0.0.1.
        if host:match("[^0-9a-fA-F:.]") then
            return false
        end
        return host:match("^[0-9a-fA-F:]*%:[0-9a-fA-F:%.]*$") ~= nil
    end
    local a, b, c, d, rest = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)(.*)$")
    if not a then
        return false
    end
    if rest ~= "" then
        return false
    end
    local n = 0
    for _, part in ipairs({ a, b, c, d }) do
        local value = tonumber(part)
        if value == nil or value > 255 or #part > 4 or part:match("^0%d") then
            return false
        end
        n = n + 1
    end
    return n == 4
end

----------------------------------------------------------------------
-- phase handlers
----------------------------------------------------------------------

---Decide everything the gRPC locations need for one call. Pure: no ngx state, so
---it is unit-testable, and setup() is only the publishing layer over it.
---@param worker table @ registry record
---@param opts table|nil @ {timeout_secs=number, headers=table, api_key=string}
---@return table|nil plan @ {host, port, tls, scheme, peer, timeout, worker_id}
---@return string|nil err
function _M.plan(worker, opts)
    opts = opts or {}
    local host, port, tls, err = _M.target_for(worker)
    if not host then
        return nil, err
    end
    local timeout = _M.resolve_timeout(
        opts.headers and opts.headers["grpc-timeout"],
        opts.timeout_secs)
    return {
        host = host,
        port = port,
        tls = tls,
        scheme = tls and "grpcs" or "grpc",
        peer = _M.format_peer(host, port),
        -- nil means "no deadline": the header is dropped rather than sent empty,
        -- because an empty grpc-timeout is a protocol error the backend rejects.
        timeout = timeout,
        worker_id = worker.id and tostring(worker.id) or nil,
    }
end

---Publish a selected worker into the nginx variables the gRPC location reads.
---Call from access_by_lua after the policy has picked a worker.
---
---Variables that the deployment did not `set` are skipped rather than fatal:
---writing an undeclared ngx.var raises (resty/core/var.lua errors on __newindex),
---so each publish is guarded and the misses are collected. A location that only
---uses the variable-form grpc_pass can declare just lr_grpc_peer and ignore the
---host/port pair the balancer form needs.
---@param worker table @ registry record
---@param opts table|nil @ {timeout_secs=number, headers=table, api_key=string}
---@return table|nil plan, string|nil err
function _M.setup(worker, opts)
    local plan, err = _M.plan(worker, opts)
    if not plan then
        return nil, err
    end
    local missing = {}
    local function publish(name, value)
        local ok = pcall(function()
            ngx.var[name] = value
        end)
        if not ok then
            missing[#missing + 1] = name
        end
    end
    publish(_M.VAR_HOST, plan.host)
    publish(_M.VAR_PORT, tostring(plan.port))
    publish(_M.VAR_PEER, plan.peer)
    publish(_M.VAR_SCHEME, plan.scheme)
    publish(_M.VAR_TIMEOUT, plan.timeout or "")
    if plan.worker_id then
        publish(_M.VAR_WORKER, plan.worker_id)
    end
    if #missing > 0 and ngx.log then
        ngx.log(ngx.INFO, "lr-grpc: undeclared variable(s) skipped: ",
            table.concat(missing, ","))
    end
    return plan
end

---balancer_by_lua handler: send this call to the peer chosen in access_by_lua.
---@return boolean ok, string|nil err
function _M.balancer()
    local balancer = require "ngx.balancer"
    local host = ngx.var[_M.VAR_HOST]
    local port = tonumber(ngx.var[_M.VAR_PORT])
    if not host or not port then
        return nil, "no gRPC peer selected"
    end
    local ok, err = balancer.set_current_peer(host, port)
    if not ok then
        return nil, err
    end
    return true
end

---gRPC-style error trailer body for a failure that never reached a backend, so a
---grpc client sees a real status instead of nginx's HTML 502.
---@param code number @ grpc-status
---@param message string
---@return string body
function _M.trailer_frame(code, message)
    return "grpc-status:" .. code .. "\r\n"
        .. "grpc-message:" .. (message or "") .. "\r\n"
end

----------------------------------------------------------------------
-- worker selection for the gRPC plane
--
-- The HTTP plane runs the full policy stack (policy.lua plus the standalone
-- modules) over candidates_for(model). The gRPC plane deliberately does not:
-- those policies key their affinity state on the *worker url* of the HTTP face,
-- and handing them grpc records would seed the cache-aware trees with addresses
-- no HTTP request will ever name. What the gRPC plane needs is a pool-scoped
-- pick plus the two strategies that actually matter for serving -- round-robin
-- spread and routing-key stickiness -- so they are implemented here against the
-- same availability rule the registry uses (registry.pd_available).
----------------------------------------------------------------------

---Process-local selection state, keyed "<pool>:<model>". Kept per policy family
---and not in lr_policy: the gRPC plane is one listener, and a cursor that only
---has to spread across N processes can stay local (Rust keeps its round-robin
---cursor in the policy instance too).
local pick_state = {}

local function state_for(key)
    local s = pick_state[key]
    if not s then
        s = {}
        pick_state[key] = s
    end
    return s
end

---Round robin over candidates with a per-process cursor.
---@param candidates table[]
---@param key string @ cursor namespace (pool + model)
---@param counter fun(key: string, step: number, init: number): number|nil|false
---@return table|nil worker
local function pick_round_robin(candidates, key, counter)
    if #candidates == 0 then
        return nil
    end
    local index
    if counter then
        local value = counter(key, 1, 0)
        if value then
            index = value % #candidates
        end
    end
    if not index then
        local state = state_for("rr:" .. key)
        state.cursor = (state.cursor or 0) + 1
        index = state.cursor % #candidates
    end
    return candidates[index + 1]
end

---Sticky pick: consistent-hash the routing key onto the candidate ring, falling
---back to round-robin when the request carries no key. Mirrors the Rust
---consistent_hashing policy's contract (key -> ring, unhealthy skipped, walk
---clockwise) on top of the shared blake3 ring in hash.lua.
---@param candidates table[]
---@param key string @ routing key
---@param ring_key string @ cache namespace
---@return table|nil worker
local function pick_sticky(candidates, key, ring_key)
    if #candidates == 0 then
        return nil
    end
    local hash = require "resty.luarouter.hash"
    local urls = {}
    for i = 1, #candidates do
        urls[i] = candidates[i].id or candidates[i].url
    end
    local ring = hash.ring_cached(state_for("ring:" .. ring_key), urls)
    local index = hash.lookup(ring, key, function(w)
        return candidates[w] ~= nil
    end)
    if not index then
        return nil
    end
    return candidates[index]
end

---Pick one worker out of a candidate list.
---
---`policy` names the strategy: "round_robin" (default), "sticky" (routing key ->
---consistent hash), "power_of_two" (less loaded of two random candidates, the
---one policy that reads live load and therefore works unchanged on grpc records)
---and "pd_pair" is not a strategy but a mode handled by pd.select_pair. Unknown
---names fall back to round-robin rather than failing the call, which matches how
---config.lua treats an unknown SMG_POLICY.
---@param candidates table[] @ already filtered by availability
---@param opts table|nil @ {policy=string, routing_key=string, model=string, pool=string, rng=fun, counter=fun}
---@return table|nil worker, string policy
function _M.pick(candidates, opts)
    opts = opts or {}
    local policy = opts.policy or "round_robin"
    local key = (opts.pool or "regular") .. ":" .. (opts.model or "default")

    if policy == "sticky" then
        local routing_key = opts.routing_key
        if type(routing_key) == "string" and routing_key ~= "" then
            local worker = pick_sticky(candidates, routing_key, key)
            if worker then
                return worker, policy
            end
        end
        -- No key (or an empty pool): a sticky pick has nothing to hold onto, so
        -- spread rather than pinning everything to candidate 1.
        return pick_round_robin(candidates, key, opts.counter), policy
    end

    if policy == "power_of_two" and #candidates > 1 then
        local rng = opts.rng or math.random
        local first = math.floor(rng() * #candidates) + 1
        local second = (first - 1 + math.floor(rng() * (#candidates - 1))) % #candidates + 1
        local registry = require "resty.luarouter.registry"
        local load_first = registry.load(candidates[first].id)
        local load_second = registry.load(candidates[second].id)
        if load_second < load_first then
            return candidates[second], policy
        end
        return candidates[first], policy
    end

    return pick_round_robin(candidates, key, opts.counter), "round_robin"
end

---Publish the PD pair onto the wire: the bootstrap triple the prefill worker
---must hand to sglang, plus the decode peer the relay needs.
---
---Two carriers exist and LR_GRPC_PD_METADATA picks between them:
---  * "body" (default) writes sglang's native proto fields -- GenerateRequest
---    field 10, DisaggregatedParams{bootstrap_host=1, bootstrap_port=2,
---    bootstrap_room=3} -- which is byte-for-byte what helpers.rs
---    inject_bootstrap_metadata sets, so an unmodified sglang worker reads it.
---    The decode peer rides as extension fields 101/102/103 because the vendored
---    schema has no native place for it (see the codec block above and
---    doc/gap-grpc-proto.md).
---  * "metadata" keeps the pre-proto-codec behaviour: the same values as
---    x-lr-* headers, which a worker only reads if it was taught to.
---    "none" publishes nothing at all.
---Body mode degrades to metadata on any call whose body cannot be rewritten
---safely (not a Generate method, streaming, compressed, unparsable, over the
---size cap, or a router build without the body in memory), and the reason is
---logged, because a silently missing bootstrap triple stalls the request 300 s
---inside sglang's disaggregation timeout.
---@param pair table @ pd.select_pair() result
---@return string carrier @ "body" | "metadata" | "none"
local function pd_publish(pair)
    local pd = require "resty.luarouter.pd"
    local carrier = _M.pd_carrier()
    local decode_host, decode_port = _M.target_for(pair.decode)

    local function publish_metadata(reason)
        ngx.req.set_header("x-lr-decode-worker", tostring(pair.decode.id))
        if decode_host then
            ngx.req.set_header("x-lr-decode-peer",
                _M.format_peer(decode_host, decode_port or 0))
        end
        ngx.req.set_header("x-lr-bootstrap-host", pair.bootstrap_host)
        -- Rust's gRPC path substitutes sglang's default port when the worker
        -- never declared one (helpers.rs unwrap_or(8998)).
        ngx.req.set_header("x-lr-bootstrap-port",
            tostring(pair.bootstrap_port or pd.DEFAULT_BOOTSTRAP_PORT))
        ngx.req.set_header("x-lr-bootstrap-room", tostring(pair.bootstrap_room))
        if pair.prefill_dp_rank then
            ngx.req.set_header("x-lr-prefill-dp-rank",
                tostring(pair.prefill_dp_rank))
        end
        if reason then
            ngx.log(ngx.INFO, "lr-grpc: PD body injection unavailable (", reason,
                "), using metadata carrier")
        end
        return "metadata"
    end

    if carrier ~= "body" then
        if carrier == "none" then
            return "none"
        end
        return publish_metadata(nil)
    end

    -- Body carrier. Everything here is guarded: a Lua error would 500 a call
    -- that metadata serves fine.
    local ok, result, reason = pcall(function()
        local path = ngx.var.uri
        if not _M.is_generate_path(path) then
            return nil, "not a Generate method: " .. tostring(path)
        end
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if not body then
            local file = ngx.req.get_body_file()
            if not file then
                return nil, "no request body"
            end
            -- Past client_body_buffer_size nginx spills to a temp file. Reading
            -- it would cost the whole payload in Lua memory, so anything over the
            -- cap is left for the metadata carrier.
            local size = tonumber(ngx.var.request_length) or 0
            if size > _M.PD_MAX_BODY_BYTES then
                return nil, "body over " .. _M.PD_MAX_BODY_BYTES .. " bytes"
            end
            local handle = io.open(file, "rb")
            if not handle then
                return nil, "body file unreadable"
            end
            body = handle:read(_M.PD_MAX_BODY_BYTES + 1)
            handle:close()
            if not body or #body > _M.PD_MAX_BODY_BYTES then
                return nil, "body over " .. _M.PD_MAX_BODY_BYTES .. " bytes"
            end
        end
        local rewritten, report, err = _M.rewrite_generate_body(body, {
            bootstrap_host = pair.bootstrap_host,
            bootstrap_port = pair.bootstrap_port or pd.DEFAULT_BOOTSTRAP_PORT,
            bootstrap_room = pair.bootstrap_room,
            decode_host = decode_host,
            decode_port = decode_port,
            prefill_dp_rank = pair.prefill_dp_rank,
        })
        if not rewritten then
            return nil, err or "rewrite failed"
        end
        ngx.req.set_body_data(rewritten)
        return report
    end)

    if not ok then
        return publish_metadata("error: " .. tostring(result))
    end
    if not result then
        return publish_metadata(reason or result)
    end
    return "body"
end

---Which gRPC pool family a fleet belongs to.
---@param records table[] @ registry.grpc_records()
---@return table pools @ {regular=..., prefill=..., decode=...}
function _M.pools(records)
    local pd = require "resty.luarouter.pd"
    local out = { regular = {}, prefill = {}, decode = {} }
    for i = 1, #(records or {}) do
        out[pd.pool_of(records[i])][#out[pd.pool_of(records[i])] + 1] = records[i]
    end
    return out
end

---Resolve the model a gRPC call is for.
---
---sglang's gRPC surface carries the model in metadata (`x-smg-model` in this
---gateway's vocabulary) rather than in a JSON body, which the byte-forwarding
---proxy never decodes. Order: metadata, then the routing-plane default (the first
---registered model, same rule router.lua uses when a body omits "model").
---@param headers table @ client headers (lower-cased keys)
---@param records table[]|nil
---@return string|nil model
function _M.model_of(headers, records)
    local raw = type(headers) == "table" and headers["x-smg-model"] or nil
    if type(raw) == "string" and raw ~= "" then
        return raw
    end
    if type(records) == "table" then
        for i = 1, #records do
            local model = records[i].model_id
            if type(model) == "string" and model ~= "" and model ~= "unknown" then
                return model
            end
        end
    end
    return nil
end

---Filter a candidate list by model with the IGW rules the HTTP plane uses
---(router.lua's candidates_for: with IGW off every worker is a candidate whatever
---model it serves, and an undiscovered worker stays visible as "unknown").
---@param candidates table[]
---@param model string|nil
---@param enable_igw boolean|nil
---@return table[]
function _M.filter_model(candidates, model, enable_igw)
    if not enable_igw or type(model) ~= "string" or model == "" then
        return candidates
    end
    local out = {}
    for i = 1, #candidates do
        local record = candidates[i]
        if record.model_id == model or record.model_id == "unknown"
            or record.model_id == nil then
            out[#out + 1] = record
        end
    end
    return out
end

---Candidates whose model_id is exactly `model` (nil/"" matches nothing).
---@param candidates table[]
---@param model string|nil
---@return table[]
function _M.exact_model(candidates, model)
    local out = {}
    if type(model) ~= "string" or model == "" then
        return out
    end
    for i = 1, #candidates do
        if candidates[i].model_id == model then
            out[#out + 1] = candidates[i]
        end
    end
    return out
end

---Decide between the plain gRPC path and the PD path for one call.
---
---Rust picks one mode for the whole router (--pd-disaggregation). Here the mode is
---inferred from the pool census of the *model-scoped* candidates, with two rules
---that make a mixed fleet usable: a call that names a model served by PD workers
---takes the PD path, and a call that names nothing prefers the regular pool when
---one exists (an unlabelled plain-gRPC fleet must not be dragged into PD just
---because somebody also registered a prefill worker).
---@param pools table @ _M.pools() over the scoped records
---@param model string|nil
---@param records table[] @ the scoped records (for the exact-match test)
---@return boolean pd_mode
function _M.pd_preferred(pools, model, records)
    if #pools.prefill == 0 and #pools.decode == 0 then
        return false
    end
    if #pools.regular == 0 then
        return true
    end
    if type(model) ~= "string" or model == "" then
        return false
    end
    local exact = _M.exact_model(records, model)
    if #exact == 0 then
        return false
    end
    local pd = require "resty.luarouter.pd"
    for i = 1, #exact do
        if pd.pool_of(exact[i]) ~= pd.POOL_REGULAR then
            return true
        end
    end
    return false
end

---Restrict a list to one *explicitly named* model plus undiscovered workers.
---Unlike filter_model this is not gated on IGW: the gRPC plane has no body to read
---a model from, so metadata that does name one must be honoured, and a fleet that
---mixes plain and PD workers would otherwise send every call through whichever pool
---happens to be registered. Undiscovered workers (model_id nil/"unknown", which is
---how every record looks before its first probe) stay candidates so a booting fleet
---is still reachable; a name that matches nothing yields an empty list, and the
---caller turns that into UNAVAILABLE rather than quietly serving a *different*
---model's worker - which is what an "otherwise no filter" fallback would do.
---@param candidates table[]
---@param model string|nil
---@return table[]
function _M.scope_named_model(candidates, model)
    if type(model) ~= "string" or model == "" then
        return candidates
    end
    local out = {}
    for i = 1, #candidates do
        local record = candidates[i]
        local id = record.model_id
        if id == nil or id == "unknown" or id == model then
            out[#out + 1] = record
        end
    end
    return out
end

----------------------------------------------------------------------
-- PD pair selection over the gRPC pool
----------------------------------------------------------------------

---Select a prefill/decode pair from the gRPC records.
---
---Two policy instances are used - one per pool - because that is what Rust's
---PolicyRegistry does (set_prefill_policy / set_decode_policy), and it is what
---keeps the round-robin cursors from consuming each other's slots.
---@param records table[] @ registry.grpc_records()
---@param opts table|nil @ {policy, routing_key, model, enable_igw, rng, counter}
---@return table|nil pair, string|nil err
function _M.select_pair(records, opts)
    opts = opts or {}
    local pd = require "resty.luarouter.pd"
    local pools = _M.pools(records)
    local model = opts.model or _M.model_of(opts.headers, records)
    pools.prefill = _M.filter_model(pools.prefill, model, opts.enable_igw)
    pools.decode = _M.filter_model(pools.decode, model, opts.enable_igw)
    local pair, err = pd.select_pair(records, {
        select = function(candidates, pool)
            return _M.pick(candidates, {
                policy = opts.policy,
                routing_key = opts.routing_key,
                model = model,
                pool = pool,
                rng = opts.rng,
                counter = opts.counter,
            })
        end,
        is_available = function() return true end,
        rng = opts.rng,
    })
    if not pair then
        return nil, err
    end
    -- The room is an int32 on this plane -- both carriers need it to fit
    -- 0..2^31-1, the native DisaggregatedParams.bootstrap_room field and the
    -- x-lr-bootstrap-room metadata alike. pd.select_pair draws the JSON/HTTP
    -- range (2^63-1), which would not encode; the gRPC path re-draws with the
    -- int32 helper, exactly as helpers.rs does (random_range(0..i32::MAX)).
    pair.bootstrap_room = pd.room_id_i32(opts.rng)
    return pair
end

----------------------------------------------------------------------
-- access_by_lua entry point for the rendered gRPC listener
----------------------------------------------------------------------

---How long one gRPC call may run. The config default is shared with the HTTP
---plane (request_timeout_secs) so a client that sets no grpc-timeout still gets
---a bounded call.
local function timeout_secs()
    local ok, lr = pcall(require, "resty.luarouter")
    if ok and lr and lr.config then
        local good, conf = pcall(lr.config)
        if good and conf and conf.request_timeout_secs then
            return conf.request_timeout_secs
        end
    end
    return 1800
end

local function enable_igw()
    local ok, lr = pcall(require, "resty.luarouter")
    if ok and lr and lr.config then
        local good, conf = pcall(lr.config)
        if good and conf then
            return conf.enable_igw and true or false
        end
    end
    return false
end

---Write a gRPC status straight back to the client, without an upstream call.
---
---This is the spec's *Trailers-only* response, and the content-length: 0 is what
---makes it work: nginx ends the stream with a DATA frame whenever a body byte is
---written (even a zero-length Length-Prefixed-Message one), and grpcio reads a
---DATA-with-END_STREAM without a trailer as
---  UNKNOWN: Stream removed (Data frame with END_STREAM flag received)
---instead of the intended code. Measured side by side on this box: header-only
---without content-length -> UNKNOWN, with content-length: 0 ->
---  UNAVAILABLE('no_healthy_grpc_workers')
---which is also why ngx.header.footer (measured) cannot be used here: the trailer
---only reaches the client when the *upstream* produced it, never for a
---Lua-generated body.
---@param code number @ grpc-status
---@param message string
local function answer_status(code, message)
    ngx.status = 200
    ngx.header["content-type"] = "application/grpc"
    ngx.header["grpc-status"] = code
    ngx.header["grpc-message"] = message or ""
    ngx.header["content-length"] = "0"
    return ngx.exit(200)
end

---Select the worker for this gRPC call and publish it for grpc_pass.
---
---Call from `access_by_lua_block` in the gRPC location. Returns the plan on
---success; on failure it has already answered the client (a gRPC status, never an
---HTML 502) and the caller must simply return.
---@param opts table|nil @ {policy=string, timeout_secs=number}
---@return table|nil plan @ {worker=..., pair=table|nil, pool=string}
---@return string|nil err
function _M.route(opts)
    opts = opts or {}
    local registry = require "resty.luarouter.registry"
    local headers = ngx.req.get_headers()
    local records = registry.grpc_records()
    if #records == 0 then
        answer_status(14, "no_healthy_grpc_workers")
        return nil, "no grpc workers"
    end

    local model = _M.model_of(headers, records)
    local routing_key = headers["x-smg-routing-key"]
    if type(routing_key) ~= "string" or routing_key == "" then
        routing_key = nil
    end
    local policy = opts.policy or "round_robin"
    local shared = {
        policy = policy,
        routing_key = routing_key,
        model = model,
        enable_igw = enable_igw(),
        headers = headers,
        -- One shared-dict counter across the nginx processes, so round-robin
        -- stays even when a deployment runs more than one worker process.
        counter = function(key, step, init)
            local d = ngx.shared.lr_policy
            if not d then
                return nil
            end
            return d:incr("grpc:" .. key, step, init)
        end,
    }

    local pd = require "resty.luarouter.pd"
    -- Model first, pools second: a fleet can serve a PD-disaggregated model and a
    -- plain one at the same time, and only the calls whose model resolves to a
    -- prefill/decode worker may take the PD path. (Rust picks one mode for the
    -- whole router with --pd-disaggregation; inferring per model is the closest
    -- the header-only proxy can get without a per-model routing table.)
    local scoped = shared.enable_igw
        and _M.filter_model(records, model, true)
        -- IGW off: the HTTP plane ignores the model entirely, but here a model
        -- named in metadata still has to steer, otherwise a mixed fleet (a plain
        -- grpc pool plus one PD model) sends every call down the PD path.
        or _M.scope_named_model(records, model)
    -- Candidate set, most specific first: workers that serve exactly the named
    -- model; if none do, the loose set (named-or-never-discovered) so a worker
    -- whose model was not discovered yet stays usable rather than invisible.
    local exact = _M.exact_model(scoped, model)
    local picked = #exact > 0 and exact or scoped
    local pools = _M.pools(picked)
    local is_pd = _M.pd_preferred(pools, model, picked)
    local worker, pair, pool, err

    if is_pd then
        local selected, pair_err = _M.select_pair(picked, shared)
        pair = selected
        if not pair then
            err = pair_err
            -- grpc-status 14 UNAVAILABLE is what a missing pool means: the
            -- selection is a server-side condition the client can retry.
            answer_status(14, err or "pd selection failed")
            return nil, err
        end
        worker = pair.prefill
        pool = pd.POOL_PREFILL
        -- Native proto body injection, with the metadata carrier behind
        -- LR_GRPC_PD_METADATA=on (doc/gap-grpc-proto.md). One nginx request has
        -- exactly one grpc_pass upstream, so the call always goes to prefill and
        -- the decode half travels inside the message the engine already parses.
        local carrier = pd_publish(pair)
        if ngx and ngx.ctx then
            ngx.ctx.lr_grpc_pd_carrier = carrier
        end
    else
        worker = _M.pick(pools.regular, shared)
        pool = pd.POOL_REGULAR
        if not worker then
            answer_status(14, "no_healthy_grpc_workers")
            return nil, "no healthy grpc workers"
        end
    end

    local plan, serr = _M.setup(worker, {
        timeout_secs = opts.timeout_secs or timeout_secs(),
        headers = headers,
    })
    if not plan then
        answer_status(13, "grpc target unresolved: " .. tostring(serr))
        return nil, serr
    end

    -- Load accounting and the breaker share the HTTP plane's keys, so a gRPC
    -- failure opens the same circuit an HTTP failure would (and the /workers
    -- load column means the same thing on both planes).
    registry.change_load(worker.id, 1)
    ngx.ctx.lr_grpc = {
        worker_id = worker.id,
        worker_url = worker.url,
        pool = pool,
        held = true,
        decode_id = pair and pair.decode and pair.decode.id or nil,
    }
    local ok_obs, observability = pcall(require, "resty.luarouter.observability")
    if ok_obs then
        observability.counter("smg_worker_selection_total", {
            { "worker_type", pool }, { "connection_mode", "grpc" },
            { "model", model or "unknown" }, { "policy", policy },
        })
    end

    local ok_var = pcall(function() ngx.var.lr_grpc_pool = pool end)
    if not ok_var and ngx.log then
        ngx.log(ngx.INFO, "lr-grpc: undeclared variable skipped: lr_grpc_pool")
    end
    return { worker = worker, pair = pair, pool = pool, plan = plan }
end

---Decide whether one finished gRPC call counts as a worker failure.
---
---The response carries the verdict in its trailer, and nginx only surfaces the
---upstream's own status line: a grpc backend that answers NOT_FOUND still returns
---HTTP 200 with grpc-status: 5 in the trailer, which is a *client* fault and must
---not charge the breaker. A transport-level failure (no upstream answer at all,
---or a 5xx from nginx's own grpc module) is the failure the breaker exists for.
---@param http_status number|nil @ ngx.status
---@param upstream_status string|nil @ $upstream_status ("", "502", a retry chain)
---@param grpc_status number|nil @ grpc-status from the trailer, when visible
---@param client_abort boolean|nil @ $request == '' / 499 semantics
---@return boolean success, string error_type
function _M.outcome(http_status, upstream_status, grpc_status, client_abort)
    if client_abort then
        return true, "client_abort"
    end
    if type(grpc_status) == "number" then
        if grpc_status == 0 then
            return true, "ok"
        end
        -- Codes that describe the *caller's* request, not the worker's health:
        -- INVALID_ARGUMENT/CANCELLED/ALREADY_EXISTS/PERMISSION_DENIED/... follow
        -- the same 4xx-is-not-a-failure rule registry.charge_cb applies to HTTP.
        if grpc_status == 1 or grpc_status == 2 or grpc_status == 3
            or grpc_status == 5 or grpc_status == 6 or grpc_status == 7
            or grpc_status == 9 or grpc_status == 10 or grpc_status == 11
            or grpc_status == 12 or grpc_status == 16 then
            return true, "client"
        end
        return false, "upstream"
    end
    if type(upstream_status) ~= "string" or upstream_status == "" then
        -- grpc_pass never reached a backend: connect refused, DNS failure, read
        -- timeout. That is the transport error the breaker charges.
        return false, "transport"
    end
    local status = tonumber(upstream_status:match("(%d+)$")) or http_status or 0
    if status >= 200 and status < 400 then
        return true, "ok"
    end
    if status >= 400 and status < 500 then
        return true, "client"
    end
    return false, "upstream"
end

---log_by_lua handler for the gRPC location: release load and charge the breaker.
---
---The HTTP plane does this in router.lua after it has read the response; here the
---proxy module owns the response stream, so the only hook left is the log phase.
---That is also where nginx exposes $upstream_status and the grpc trailer, which is
---exactly the information the verdict needs.
function _M.on_log()
    local state = ngx.ctx.lr_grpc
    if not state or not state.worker_id then
        return
    end
    local ok, registry = pcall(require, "resty.luarouter.registry")
    if not ok then
        return
    end
    if state.held then
        registry.change_load(state.worker_id, -1)
        state.held = nil
    end

    local upstream_status
    pcall(function() upstream_status = ngx.var.upstream_status end)
    local grpc_status
    pcall(function()
        local raw = ngx.var.upstream_http_grpc_status
        if raw and raw ~= "" then
            grpc_status = tonumber(raw)
        end
    end)
    local abort = false
    pcall(function()
        abort = (tonumber(ngx.var.status) or 0) == 499
    end)

    local success, error_type = _M.outcome(tonumber(ngx.status), upstream_status,
        grpc_status, abort)
    local ok_hb, hb = pcall(require, "resty.luarouter.hb")
    if ok_hb and hb.record_outcome then
        hb.record_outcome(state.worker_id, success)
    end
    if not success then
        local ok_obs, observability = pcall(require, "resty.luarouter.observability")
        if ok_obs then
            observability.record_worker_error(state.worker_url, error_type)
        end
    end
    -- The decode half of a PD pair is deliberately not charged: a prefill failure
    -- cancels the paired decode request on purpose (pd.outcome, Rust
    -- execute_dual_dispatch_internal), so charging it would open healthy decode
    -- breakers during a prefill storm.
    return success, error_type
end

_M.ANSWER_STATUS = answer_status
_M.TLS_SCHEMES = TLS_SCHEMES
return _M
