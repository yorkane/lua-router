-- resty.luarouter.config_store.httpc
-- P31 零依赖 cosocket HTTP 客户端 raw_request（唯一生产读者是 props.lua 的 /props 代理）。
--
-- 由 lualib/resty/luarouter/config_store.lua 拆分而来：函数体逐行原样搬家，只调整 require 与
-- 跨模块接线（doc/refactor-arch-2026-10-05.md §1–§2）。原文里经 _M.x() 的自调 → 经 CS_FACADE
-- 表调用（保住单测换桩的可拦截性逐点一致）；原文里的同文件 local 直调 → 直接 require 对端
-- 子模块的共享表调用（不进 facade 导出面，_M 契约因此逐名不变）。
local CS_FACADE = require "resty.luarouter.config_store"
local CS_LEXICON = require "resty.luarouter.config_store.lexicon"

local _M = {}

--- Minimal HTTP/1.1 client on ngx.socket.tcp. Returns status, headers(table,
--- lowercase), body — or nil, err. Supports Content-Length and chunked.
function _M.raw_request(method, url, body, headers, timeout_ms)
    local ok, http_mod = pcall(require, "resty.http")
    if ok and http_mod and http_mod.new then
        if body == false then body = nil end  -- lua-resty-http would stringify it
        local client = http_mod.new()
        client:set_timeout(timeout_ms or 5000)
        local pool_cfg = CS_LEXICON.store_config()
        local res, err = client:request_uri(url, {
            method = method,
            body = body,
            headers = headers,
            -- lua-resty-http has its own pool, keyed by host:port and scheme, and
            -- it only reuses when the caller opts in. The old `keepalive = false`
            -- meant one fresh TCP+TLS handshake per /props probe; the timeouts are
            -- the router's pool knobs so both client paths
            -- agree on how long an idle socket may live.
            keepalive = true,
            keepalive_timeout = pool_cfg and (pool_cfg.pool_idle_timeout_secs * 1000) or 50000,
            keepalive_pool = pool_cfg and pool_cfg.pool_max_idle_per_host or 500,
            -- Same posture as the cosocket path below: internal workers and the
            -- watcher present self-signed certs, and lua-resty-http verifies by
            -- default, which would fail every https request outright.
            ssl_verify = false,
        })
        if not res then return nil, err or "http request failed" end
        local h = {}
        for k, v in pairs(res.headers or {}) do
            h[tostring(k):lower()] = type(v) == "table" and table.concat(v, ",") or tostring(v)
        end
        return res.status, h, res.body or ""
    end
    -- Fallback: raw cosocket (lua-resty-http missing on the box).
    local host, port, path = url:match("^https?://([^:/]+):?(%d*)(/?.*)$")
    if not host then return nil, "bad url: " .. tostring(url) end
    local tls = url:find("^https") ~= nil
    port = (port ~= "" and tonumber(port)) or (tls and 443 or 80)
    if path == "" then path = "/" end
    local sock = ngx.socket.tcp()
    sock:settimeouts(timeout_ms or 5000, timeout_ms or 5000, timeout_ms or 5000)
    local pool_cfg = CS_LEXICON.store_config()
    local pool_opts
    if pool_cfg then
        local registry_mod = CS_LEXICON.store_registry()
        if registry_mod and registry_mod.pool_opts then
            pool_opts = registry_mod.pool_opts(pool_cfg, "store", url)
        end
    end
    local ok_conn, conn_err = sock:connect(host, port, pool_opts)
    if not ok_conn then sock:close(); return nil, conn_err or "connect failed" end
    if tls then
        -- cosocket connect() has no TLS in http{} context, so an https url has
        -- to be upgraded here or the request is sent in cleartext. SNI carries
        -- the host; the cert is not verified (self-signed internal workers).
        local ok_tls, tls_err = sock:sslhandshake(nil, host, false)
        if not ok_tls then
            sock:close()
            return nil, "TLS handshake failed: " .. tostring(tls_err)
        end
    end
    -- No `Connection: close`: the socket is pooled below, and asking the peer to
    -- close it while setkeepalive() keeps it warm is how a reused socket ends up
    -- reset by the server.
    local req = { method .. " " .. path .. " HTTP/1.1\r\n",
                  "Host: " .. host .. ":" .. port .. "\r\n" }
    local has_body = body ~= nil and body ~= false
    for k, v in pairs(headers or {}) do
        req[#req + 1] = tostring(k) .. ": " .. tostring(v) .. "\r\n"
    end
    if has_body then
        req[#req + 1] = "Content-Length: " .. #body .. "\r\n"
    end
    req[#req + 1] = "\r\n"
    local ok_send, send_err = sock:send(table.concat(req))
    if not ok_send then sock:close(); return nil, send_err or "send failed" end
    if has_body then
        local ok_write, write_err = sock:send(body)
        if not ok_write then sock:close(); return nil, write_err or "write failed" end
    end
    local head = sock:receive("*l")
    if not head then sock:close(); return nil, "no response head" end
    local status = tonumber((head:match("^(%S+) (%d+)"))) or 0
    local hdrs = {}
    while true do
        local line = sock:receive("*l")
        if line == nil or line == "" then break end
        local k, v = line:match("^([^:]+):%s*(.*)$")
        if k then hdrs[CS_LEXICON.lower(k)] = v end
    end
    local out
    local complete = true
    if hdrs["transfer-encoding"] and hdrs["transfer-encoding"]:lower():find("chunked") then
        local registry_mod = CS_LEXICON.store_registry()
        if registry_mod and registry_mod.pump_chunked then
            out, complete = registry_mod.pump_chunked(sock, true)
        else
            out = {}
            while true do
                local size_line = sock:receive("*l")
                if not size_line then complete = false break end
                local size = tonumber(size_line:gsub("%s+$", ""), 16)
                if not size or size == 0 then break end
                local chunk = sock:receive(size)
                if not chunk then complete = false break end
                out[#out + 1] = chunk
                sock:receive(2)  -- trailing CRLF
            end
            out = table.concat(out)
        end
    else
        local len = tonumber(hdrs["content-length"] or "")
        if len then
            local parts = {}
            local remaining = len
            while remaining > 0 do
                local block = sock:receive(math.min(65536, remaining))
                if not block then complete = false break end
                parts[#parts + 1] = block
                remaining = remaining - #block
            end
            out = table.concat(parts)
        else
            -- Unframed answer: reading it to the end consumed the connection.
            out = sock:receive("*a") or ""
            complete = false
        end
    end
    if pool_cfg and complete then
        local registry_mod = CS_LEXICON.store_registry()
        if registry_mod and registry_mod.release then
            registry_mod.release(sock, pool_cfg, registry_mod.response_reusable(
                hdrs, true), "store", url)
        else
            sock:close()
        end
    else
        sock:close()
    end
    return status, hdrs, out
end

return _M
