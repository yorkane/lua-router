-- resty.luarouter.httpc - the gateway shared cosocket pool and HTTP primitives.
--
-- Raised verbatim out of the registry E block (registry.lua:328-482) per
-- doc/refactor-arch-2026-10-05.md section 1. These helpers were never
-- registry-specific: router.lua, config_store.lua, hb.lua, mesh.lua, watcher.lua and
-- gpu_load.lua all borrow them, and they did so through the registry module table,
-- which made the worker registry the de-facto transport library of the gateway.
--
-- The move is structural only:
--   * every pool parameter keeps its original value (pool_size default 500,
--     so_keepalive idle/interval = cfg.tcp_keepalive_secs or 30 with count 3,
--     setkeepalive idle TTL = (cfg.pool_idle_timeout_secs or 50) * 1000, pool name
--     lr:<kind>:<s|c>:<host>:<port>);
--   * no call site changed: router/config_store/hb/mesh/watcher/gpu_load keep
--     reaching these functions through the registry facade, which re-exports them
--     under their original names (pool_name, pool_opts, pool_idle_ms, pump_chunked,
--     response_reusable, release);
--   * split_url comes from registry.url rather than back through the facade, so this
--     module has no dependency on the worker registry at all.

local M = {}

local url_mod = require "resty.luarouter.registry.url"

---Cosocket pool name for one outbound target.
---
---OpenResty pools sockets by the `pool` string plus the connect address, so the
---name only has to keep the parts nginx cannot see apart: the caller class (a
---health probe must not hand a socket to the inference path and vice versa) and
---the TLS state, because a pooled cleartext socket reused for an https worker (or
---the other way round) is a protocol error rather than a slow start. host:port is
---carried for readability: nginx still keys the pool by it internally, and a
---shared name across hosts would be correct but impossible to reason about from
---`nginx -V` output or a stack trace.
---@param kind string @ "forward" | "stream" | "hb" | "mesh" | "store" | "probe"
---@param url string @ normalized worker/peer url
---@return string
function M.pool_name(kind, url)
    local host, port, tls = url_mod.split_url(url)
    return "lr:" .. kind .. ":" .. (tls and "s" or "c") .. ":" .. host .. ":" .. port
end

---Connect options for one outbound call: a named pool plus TCP keepalive.
---
---`pool_size` is cosocket's *per nginx process* idle ceiling for this pool name,
---which is the closest thing to reqwest's pool_max_idle_per_host (one number for
---the whole gateway process). the cosocket pool notes (git history) spell out the
---difference. `so_keepalive` maps reqwest's single tcp_keepalive interval onto
---the three Linux knobs: idle, interval and probe count.
---@param cfg table @ router config
---@param kind string
---@param url string
---@return table opts @ ready for sock:connect(host, port, opts)
function M.pool_opts(cfg, kind, url)
    local host, port, tls = url_mod.split_url(url)
    local keep = cfg.tcp_keepalive_secs or 30
    return {
        pool = M.pool_name(kind, url),
        pool_size = cfg.pool_max_idle_per_host or 500,
        so_keepalive = {
            idle = keep,
            interval = keep,
            count = 3,
            always_send = true,
        },
    }
end

---Idle TTL in milliseconds for setkeepalive() on a pooled socket.
---@param cfg table
---@return number
function M.pool_idle_ms(cfg)
    return (cfg.pool_idle_timeout_secs or 50) * 1000
end

---Read a chunked body to the end, including the terminating chunk and the
---trailer block.
---
---The pool only works if the socket is left at a message boundary: setkeepalive()
---answers "unread data in buffer" for anything else, and every helper that used to
---stop after the "0" size line silently lost its keepalive that way (the CRLF
---before the trailer and the trailer's own CRLF were never consumed). Reading the
---trailer is also required for correctness, because a trailer field is legal HTTP
---and a leftover would be parsed as the next response's status line on a reused
---connection.
---@param sock table @ connected cosocket
---@param collect boolean|nil @ false drops the payload (drain path)
---@return string body, boolean complete @ false when the stream broke off early
function M.pump_chunked(sock, collect)
    local buffer = {}
    local complete = false
    while true do
        local size_line = sock:receive("*l")
        if not size_line then
            break
        end
        local size = tonumber(string.match(size_line, "^%x+") or "", 16)
        if not size then
            break
        end
        if size == 0 then
            complete = true
            break
        end
        local chunk = sock:receive(size)
        if not chunk then
            break
        end
        if collect ~= false then
            buffer[#buffer + 1] = chunk
        end
        local crlf = sock:receive(2)
        if not crlf or crlf == "" then
            break
        end
    end
    if complete then
        -- Trailer headers, if any, run until the blank line that closes them.
        while true do
            local line = sock:receive("*l")
            if line == nil or line == "" then
                break
            end
        end
    end
    return table.concat(buffer), complete
end

---Whether a response may leave its connection in the pool.
---
---Two conditions, both borrowed from what reqwest does with a pooled client: the
---message body has to be consumed to its declared end, and the peer must not have
---asked to be disconnected. A `Connection: close` response that got pooled is a
---socket the server has already forgotten, and the next request on it fails with
---"connection reset by peer" one layer down where it is invisible to the retry loop.
---@param headers table @ lowercase response header table
---@param complete boolean @ the body reached its framing boundary
---@return boolean
function M.response_reusable(headers, complete)
    if not complete then
        return false
    end
    local connection = headers and headers["connection"]
    if type(connection) == "string"
        and ngx.re.find(connection, [[\bclose\b]], "ijo") then
        return false
    end
    return true
end

---Return a fully-consumed socket to its pool, or close it.
---
---The Rust pool hands a connection back only after the response was consumed in
---full; anything else (a broken stream, a body we deliberately dropped) is closed.
---Failure to keep alive is treated the same way - cosocket then already discarded
---the fd, so a second close is harmless.
---@param sock table
---@param cfg table|nil @ router config; nil closes
---@param reusable boolean @ the caller's verdict on the stream state
---@param kind string|nil @ pool class, for the pool_size argument
---@param url string|nil @ target url, for the pool_size argument
---@return boolean kept
function M.release(sock, cfg, reusable, kind, url)
    if reusable and cfg then
        local pool_size
        if kind and url then
            pool_size = M.pool_opts(cfg, kind, url).pool_size
        end
        local ok = sock:setkeepalive(M.pool_idle_ms(cfg), pool_size)
        if ok then
            return true
        end
    end
    sock:close()
    return false
end


-- ------------------------------------------------------------------ policy hint

return M
