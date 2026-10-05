-- mesh.wire —— 协议编解码：纯 Lua base64/hex（不依赖 ngx.encode_base64）+
-- 快照信封的 JSON+base64 往返。
local _M = require "resty.luarouter.mesh"

local cjson = require "cjson.safe"

local json_encode = cjson.encode
local json_decode = cjson.decode

-- ------------------------------------------------------------------ base64

-- 纯 Lua 实现：ngx.encode_base64 在 resty/luajit 单测里不存在，而树快照这个
-- blob 必须能在两层都一样地编解码，所以不依赖 ngx。
local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_REVERSE = {}
for i = 1, 64 do
    B64_REVERSE[string.sub(B64_ALPHABET, i, i)] = i - 1
end
B64_REVERSE["="] = 0

---base64（纯 Lua，3 字节一组做整数运算，不依赖 ngx.encode_base64）。
function _M.b64_encode(text)
    if text == nil then
        return nil
    end
    local out = {}
    local n = #text
    local pos = 1
    while pos + 2 <= n do
        local b1, b2, b3 = string.byte(text, pos, pos + 2)
        local chunk = b1 * 65536 + b2 * 256 + b3
        out[#out + 1] = string.char(
            B64_ALPHABET:byte(math.floor(chunk / 262144) + 1),
            B64_ALPHABET:byte(math.floor(chunk / 4096) % 64 + 1),
            B64_ALPHABET:byte(math.floor(chunk / 64) % 64 + 1),
            B64_ALPHABET:byte(chunk % 64 + 1))
        pos = pos + 3
    end
    local rest = n - pos + 1
    if rest == 1 then
        local b1 = string.byte(text, pos)
        out[#out + 1] = string.char(
            B64_ALPHABET:byte(math.floor(b1 / 4) + 1),
            B64_ALPHABET:byte((b1 % 4) * 16 + 1),
            string.byte("="), string.byte("="))
    elseif rest == 2 then
        -- 16 位不够切出第三个 6 位组，直接按位移取，别拿合并后的整除值。
        local b1, b2 = string.byte(text, pos, pos + 1)
        out[#out + 1] = string.char(
            B64_ALPHABET:byte(math.floor(b1 / 4) + 1),
            B64_ALPHABET:byte((b1 % 4) * 16 + math.floor(b2 / 16) + 1),
            B64_ALPHABET:byte((b2 % 16) * 4 + 1),
            string.byte("="))
    end
    return table.concat(out)
end

function _M.b64_decode(text)
    if text == nil then
        return nil
    end
    local clean = string.gsub(text, "%s", "")
    if #clean % 4 ~= 0 then
        return nil, "invalid base64 length"
    end
    local out = {}
    for pos = 1, #clean, 4 do
        local c1 = string.sub(clean, pos, pos)
        local c2 = string.sub(clean, pos + 1, pos + 1)
        local c3 = string.sub(clean, pos + 2, pos + 2)
        local c4 = string.sub(clean, pos + 3, pos + 3)
        local v1, v2 = B64_REVERSE[c1], B64_REVERSE[c2]
        if not v1 or not v2 then
            return nil, "invalid base64 character"
        end
        out[#out + 1] = string.char(v1 * 4 + math.floor(v2 / 16))
        if c3 ~= "=" then
            local v3 = B64_REVERSE[c3]
            if not v3 then
                return nil, "invalid base64 character"
            end
            out[#out + 1] = string.char((v2 % 16) * 16 + math.floor(v3 / 4))
            if c4 ~= "=" then
                local v4 = B64_REVERSE[c4]
                if not v4 then
                    return nil, "invalid base64 character"
                end
                out[#out + 1] = string.char((v3 % 4) * 64 + v4)
            end
        elseif c4 ~= "=" then
            return nil, "invalid base64 padding"
        end
    end
    return table.concat(out)
end

---与 Rust handlers.rs 的 hex 编码约定一致（/ha/config/{key} 的 value 字段）。
function _M.hex_encode(text)
    if text == nil then
        return nil
    end
    return (string.gsub(text, ".", function(c)
        return string.format("%02x", string.byte(c))
    end))
end

function _M.hex_decode(hex)
    if type(hex) ~= "string" then
        return nil, "hex value must be a string"
    end
    if #hex % 2 ~= 0 then
        return nil, "Hex string must have even length"
    end
    local out = {}
    for pos = 1, #hex, 2 do
        local byte_hex = string.sub(hex, pos, pos + 1)
        local value = tonumber(byte_hex, 16)
        if not value then
            return nil, "Invalid hex encoding"
        end
        out[#out + 1] = string.char(value)
    end
    return table.concat(out)
end


-- ------------------------------------------------------------------ wire 编解码

---JSON + base64：base64 让树快照这类二进制 blob 在 JSON 里安全往返。
function _M.encode(snap)
    local text = json_encode(snap)
    if not text then
        return nil, "snapshot not encodable"
    end
    return _M.b64_encode(text)
end

function _M.decode(text)
    local json_text, err = _M.b64_decode(text)
    if not json_text then
        return nil, err or "invalid base64"
    end
    local snap = json_decode(json_text)
    if type(snap) ~= "table" then
        return nil, "snapshot JSON unreadable"
    end
    return snap
end


return { priv = {} }
