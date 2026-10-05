-- cosocket 转发泵（自 router.lua 逐字搬来，只调整了 require 接线）。
--
-- P16：connect / read head / send_attempt / discard / read body。裸 HTTP/1.1 手读
-- 状态行与头；连接池与 TLS 复用 registry 的既有借用点。
local registry = require "resty.luarouter.registry"

local host = require "resty.luarouter.router.host"

local _M = {}
package.loaded["resty.luarouter.router.pump"] = _M

local cfg = host.cfg
-- ------------------------------------------------------------------ cosocket

---Split the worker URL, dropping the brackets an IPv6 literal carries so the
---cosocket resolver can use the address.
local function connect_target(url)
    local host, port, tls = registry.split_url(url)
    if host:sub(1, 1) == "[" and host:sub(-1) == "]" then
        host = host:sub(2, -2)
    end
    return host, port, tls
end

_M.connect_target = connect_target

local function read_response_head(sock)
    local line, err = sock:receive("*l")
    if not line then
        return nil, nil, "no status line: " .. tostring(err)
    end
    local status = tonumber(string.match(line, "^HTTP/%d%.%d%s+(%d%d%d)"))
    if not status then
        return nil, nil, "malformed status line: " .. line
    end
    local headers = {}
    while true do
        local header = sock:receive("*l")
        if header == nil then
            return nil, nil, "connection closed while reading headers"
        end
        if header == "" then
            break
        end
        local name, value = string.match(header, "^([%w%-]+):%s?(.*)$")
        if name then
            local lower = string.lower(name)
            if headers[lower] then
                headers[lower] = headers[lower] .. ", " .. value
            else
                headers[lower] = value
            end
        end
    end
    return status, headers
end

---Send one attempt and read only the response head; the caller reads the body.
---
---The connect goes through a named cosocket pool (registry.pool_opts), which is the
---Lua equivalent of the reqwest client the Rust gateway builds once from
---pool_idle_timeout_secs / pool_max_idle_per_host / tcp_keepalive_secs. The class
---comes from `kind`: streaming, health probes and mesh traffic must not inherit each
---other's sockets, and an https target gets its own pool because replaying a pooled
---cleartext socket against a TLS worker is a protocol error rather than a slow start.
---@param worker table
---@param kind string|nil @ pool class: "forward" (default) or "stream"
---@return table|nil response @ {status, headers, sock, kind}
local function send_attempt(worker, method, path, payload, headers, kind)
    local host, port, tls = connect_target(worker.url)
    local conf = cfg()
    local timeout_ms = conf.request_timeout_secs * 1000
    local connect_ms = math.min(conf.connect_timeout_secs * 1000, timeout_ms)
    kind = kind or "forward"
    local sock = ngx.socket.tcp()
    sock:settimeouts(connect_ms, timeout_ms, timeout_ms)
    local ok, cerr = sock:connect(host, port,
        registry.pool_opts(conf, kind, worker.url))
    if not ok then
        sock:close()
        return nil, "connect failed: " .. tostring(cerr)
    end
    -- The ssl option on connect is ignored in http{} context: an https worker
    -- has to be upgraded explicitly or the request goes out in cleartext.
    local tls_ok, terr = registry.tls_handshake(sock, host, tls)
    if not tls_ok then
        sock:close()
        return nil, terr
    end

    local authority = host
    if port ~= (tls and 443 or 80) then
        authority = host .. ":" .. port
    end
    local head = method .. " " .. path .. " HTTP/1.1\r\n"
        .. "Host: " .. authority .. "\r\n"
    for name, value in pairs(headers) do
        head = head .. name .. ": " .. value .. "\r\n"
    end
    head = head .. "\r\n"

    local bytes, serr = sock:send(head)
    if not bytes then
        sock:close()
        return nil, "send headers failed: " .. tostring(serr)
    end
    if payload and payload ~= "" then
        local sent, berr = sock:send(payload)
        if not sent then
            sock:close()
            return nil, "send body failed: " .. tostring(berr)
        end
    end
    local status, response_headers, herr = read_response_head(sock)
    if not status then
        sock:close()
        return nil, herr
    end
    return { status = status, headers = response_headers, sock = sock,
        kind = kind }
end

local function is_chunked(headers)
    local value = headers["transfer-encoding"]
    return value ~= nil and string.find(string.lower(value), "chunked") ~= nil
end

---Drain the body of an attempt we are throwing away.
---
---Always closes rather than pooling: this is the retry path, and the upstream either
---answered a status we will not serve or the attempt is being abandoned. Rust's
---retry loop drops the whole response object there too, so the connection is not
---returned to the pool either way.
local function discard_body(sock, headers)
    if is_chunked(headers) then
        while true do
            local size_line = sock:receive("*l")
            if not size_line then break end
            local size = tonumber(size_line, 16)
            if not size or size == 0 then break end
            if not sock:receive(size) then break end
            sock:receive(2)
        end
    else
        local length = tonumber(headers["content-length"])
        if length and length > 0 then
            sock:receive(length)
        end
    end
    sock:close()
end

---Read a complete non-streaming body.
---
---Returns the bytes and whether the message reached its declared end. The second
---value is the pool's gate: a body that broke off midway leaves unread bytes behind,
---and setkeepalive() then either fails with "unread data in buffer" or hands the next
---request a connection that starts mid-message.
---@return string body, boolean complete
local function read_response_body(sock, headers)
    if is_chunked(headers) then
        -- pump_chunked also consumes the last chunk's CRLF and the trailer block,
        -- which is what makes the socket reusable afterwards.
        return registry.pump_chunked(sock, true)
    end
    local buffer = {}
    local complete = true
    local length = tonumber(headers["content-length"])
    if length and length > 0 then
        local remaining = length
        while remaining > 0 do
            local block = sock:receive(math.min(65536, remaining))
            if not block then
                complete = false
                break
            end
            buffer[#buffer + 1] = block
            remaining = remaining - #block
        end
    end
    return table.concat(buffer), complete
end
-- 跨模块接线（拆分新增；文末；connect_target 的就近导出在原处节内）。
_M.is_chunked = is_chunked
_M.read_response_head = read_response_head
_M.send_attempt = send_attempt
_M.discard_body = discard_body
_M.read_response_body = read_response_body
return _M
