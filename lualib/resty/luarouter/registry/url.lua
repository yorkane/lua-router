-- registry.url - url normalisation and dialing helpers.
--
-- Cut verbatim out of registry.lua (refactor 2026-10-05,
-- doc/refactor-arch-2026-10-05.md section 1, block D). Pure string helpers: no shared
-- dict and no cosocket state, so any module can require them safely. The registry
-- facade re-exports the public names (normalize_url / strip_rank / rank_of / split_url /
-- tls_handshake) because router.lua, hb.lua, mesh.lua and watcher.lua borrow them
-- through registry; those call sites are unchanged.

local M = {}

---@param url string
---@return string|nil normalized, string|nil err
function M.normalize_url(url)
    if type(url) ~= "string" or url == "" then
        return nil, "url is required"
    end
    if not ngx.re.match(url, [[^https?://]], "jo") then
        url = "http://" .. url
    end
    -- strip trailing slashes so http://h:p/ and http://h:p are one worker
    url = ngx.re.gsub(url, [[/+$/]], "", "jo")
    if not ngx.re.match(url, [[^https?://[^/]+]], "jo") then
        return nil, "invalid worker url: " .. url
    end
    return url
end

---Strip a DP rank suffix from the *authority* of a url.
---
---The rank is scheduler identity, not transport identity: every rank of a
---data-parallel engine is served by the same listener, so connecting to
---"http://10.0.0.5:30000@2" means connecting to 10.0.0.5:30000 and telling the
---engine which rank to route to inside the request (Rust does the same through
---BasicWorker::normalised_url, gateway/src/core/worker.rs:680, which strips the
---suffix before every outgoing call). Stripping happens here rather than in each
---caller because every cosocket path in the router resolves through this one
---function - the health sweep, the fan-out probes and the forwarding connect.
---
---Only the authority is touched, and only when it ends in "@<digits>": call sites
---concatenate a path onto the worker url before dialing it (record.url ..
---"/health", .. "/metrics", .. "/v1/loads"), so the suffix is rarely at the end of
---the string that arrives here, and a userinfo "user:pw@host" must survive because
---its tail is not digits.
---@param url string
---@return string url
local function strip_rank(url)
    if type(url) ~= "string" then
        return url
    end
    local scheme, rest = url:match("^(%a[%w+.-]*)://(.*)$")
    local prefix = scheme and (scheme .. "://") or ""
    local body = rest or url
    local authority, tail = body:match("^([^/]*)(.*)$")
    local without = authority:match("^(.-)@%d+$")
    return prefix .. (without or authority) .. tail
end

M.strip_rank = strip_rank

---DP rank carried by a url, or nil when it is a plain (non-rank) url.
---
---Also the expansion guard: a url that already ends in a rank is a rank, so it
---must never be expanded again. That matters for a rank deleted and re-added
---through POST /workers, which arrives without the dp_* record fields and would
---otherwise be re-expanded into "<base>@<rank>@0..N".
---@param url string
---@return number|nil rank
function M.rank_of(url)
    local stripped = strip_rank(url)
    if stripped == url then
        return nil
    end
    return tonumber(url:match("@(%d+)$"))
end

---@param url string @normalized
---@return string host, number port, boolean tls
function M.split_url(url)
    url = strip_rank(url)
    local m = ngx.re.match(url, [==[^https?://([^/]+)]==], "jo")
    local tls = ngx.re.match(url, [[^https://]], "jo") and true or false
    local text = m[1]
    local parts = ngx.re.match(text,
        [==[^(\[[0-9a-fA-F:]+\]|[^:\]]+)(?::(\d+))?$]==], "jo")
    if not parts then
        return text, tls and 443 or 80, tls
    end
    return parts[1], tonumber(parts[2]) or (tls and 443 or 80), tls
end

---Upgrade a connected cosocket to TLS.
---
---OpenResty's tcp cosocket in an http{} context ignores the `ssl` option of
---`connect` (it is only honoured by stream and by the explicit handshake), so an
---https worker used to be contacted in cleartext and the upstream answered
---400 "The plain HTTP request was sent to HTTPS port". Every https call path
---therefore has to shake hands explicitly after connecting. SNI carries the
---worker host and the certificate is not verified, which keeps the previous
---`ssl_verify = false` intent (internal workers ship self-signed certs).
---@param sock table @ connected ngx.socket.tcp()
---@param host string
---@param tls boolean|nil
---@return boolean ok, string|nil err
function M.tls_handshake(sock, host, tls)
    if not tls then
        return true
    end
    local ok, err = sock:sslhandshake(nil, host, false)
    if not ok then
        return nil, "TLS handshake failed: " .. tostring(err)
    end
    return true
end

-- ------------------------------------------------------------------ pool

return M
