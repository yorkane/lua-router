-- Worker registry backed by ngx.shared.DICT (lr_workers).
--
-- Mirrors the Rust gateway's core::{WorkerRegistry, JobQueue} contract:
--   * POST /workers reserves an id, queues a background job and answers 202
--   * the id is sha224(url) hex truncated to 32 chars, rendered as a UUID, so
--     the same URL always maps to the same id
--   * re-registering a live URL is not an HTTP error: the job fails with
--     "Worker <url> already exists" and GET /workers/{id} exposes job_status
--   * DELETE releases the url -> id mapping so the URL can be re-added
--
-- Static per-worker fields live in one JSON value under w:<id>; the fields that
-- change on every request (health, circuit breaker, load) are separate numeric
-- keys so they can be touched without decoding the JSON.
--
-- Being numeric is not the same as being race-free: several nginx worker
-- processes charge the same worker concurrently, so every counter that means
-- "consecutive" must be accumulated with shdict:incr() (see charge_cb) and any
-- state flip must be re-checked under the registry lock (see flip_cb). A
-- get()/set() pair there loses updates across processes.

local cjson = require "cjson.safe"
local lock_mod = require "resty.lock"

local _M = { _VERSION = "0.1.0" }

local DICT_NAME = "lr_workers"
local LOCK_DICT = "lr_locks"
local IDS_KEY = "ids"

local json_encode = cjson.encode
local json_decode = cjson.decode

-- key prefixes
local K_WORKER = "w:"    -- static record (JSON)
local K_HEALTH = "hl:"   -- 1 healthy / 0 unhealthy
local K_HFAIL = "hf:"    -- consecutive health-check failures
local K_HSUCC = "hs:"    -- consecutive health-check successes
local K_CBSTATE = "cbs:" -- 0 closed, 1 half_open, 2 open
local K_CBF = "cbf:"     -- consecutive breaker failures
local K_CBS = "cbu:"     -- consecutive breaker successes
local K_CBO = "cbo:"     -- ms timestamp when the breaker opened
local K_LOAD = "lo:"     -- in-flight requests
local K_ACTIVE = "act:"  -- ms timestamp of the last completed request
local K_URL2ID = "url:"  -- url -> id
local K_IDURL  = "u:"    -- id -> url (cheap label lookup for metrics)
local K_JOB = "job:"     -- url -> JobStatus JSON
local K_DISC = "disc:"   -- id -> metadata discovery attempts
local K_DPROBE = "dpr:"  -- id -> /server_info probes spent on DP expansion
local K_MPROBE = "mp:"    -- id -> /v1/models coverage probes spent (failed ones)
local K_MPROBE_OK = "mpok:" -- id -> TTL stamp of the last successful coverage probe
-- Cached "this record may serve the HTTP inference plane" flag (see
-- _M.http_selectable). A derived value, recomputed whenever the static record is
-- written, so the selection path never has to decode the record to ask.
local K_HSEL = "isel:"

-- GPU 负载源（doc/gap-gpu-load.md）的两个外部采样通道，都是 **带 TTL 的数值键**：
-- 值为归一化负载的千分位整数（0..1000 = 0..1），所以过期（读取返回 nil）就等于
-- 「这个 tick 没有样本」，不需要额外的清理定时器，也不会把一台监控挂掉的机器永久
-- 钉在高负载上。两键分列是因为优先级明确（见 _M.load）：
--   xl: 外部负载源（gpu_load.lua 从 /metrics 或远程 Prometheus 抓来的 GPU 压力）
--   sl: 引擎自报负载（/v1/loads 那条通道）。本仓库的 /v1/loads 仍是按需拉取、
--       从不回写 registry（router.lua 的 loads_handler 只读上游），键位留给它，
--       是为了让「谁说了算」这件事在数据模型里就写清楚，而不是靠调用顺序。
local K_XLOAD = "xl:"  -- external GPU sample, milli of a 0..1 load, TTL'd
local K_SLOAD = "sl:"  -- engine self-report, same shape, lower priority
-- Raw measured power (doc/gap-worker-caps.md): the third external channel, and
-- deliberately *not* a load. `xl:` answers "how busy is this card" for the ranking
-- policies; `pw:` answers "how many watts is it drawing" for the per-worker power
-- cap, which is a hard admission gate and not a score. Folding watts into
-- _M.load() would let an idle-but-thirsty co-tenant's GPU make a worker look
-- overloaded to power_of_two, so the two numbers never share a field.
--   value = integer milli-watts (watts x 1000), TTL'd like the load samples: an
--   expired key means "no reading", and _M.capacity_exclusion reads that as
--   *unknown*, which never excludes a worker.
local K_POWER = "pw:"   -- raw power sample, milli-watts, TTL'd
-- Weight of a fully busy worker: how many in-flight requests a 1.0 sample is
-- worth. Published by gpu_load.run_pass on every tick so the selection path never
-- reads the environment; the default keeps cache_aware's balance_abs_threshold (a
-- request-count-shaped knob, Rust default 64) inside its usable range.
local LOAD_SCALE_DEFAULT = 100
local load_scale = LOAD_SCALE_DEFAULT   -- set_load_scale override (tests, an operator knob)
local load_scale_from_cfg = false       -- memo of "the config value was applied"
-- One shared "any sample exists anywhere" flag plus its per-process memo.
--
-- The writer is the load timer, which runs in worker 0 only; the readers are the
-- selection paths of every process, so a per-process boolean could never be set by
-- the process that needs it. The shared key (TTL'd like the samples it covers) is the
-- authority, and the memo is what keeps the shipped shape (SMG_LOAD_SOURCE=none, no
-- samples ever) at one shdict get per process per second instead of one per load()
-- call -- that call runs once per candidate on every request, and per-request shdict
-- traffic is already the dominant CPU cost (doc/parity-cpu-ablation.md).
local K_XANY = "xany"   -- shared "some worker has a fresh sample" flag, TTL'd
local MEMO_SECS = 1
local memo_any = false
local memo_checked_at = -MEMO_SECS

-- Numeric codes follow the Rust metric encoding (gateway/src/core/
-- circuit_breaker.rs STATE_CLOSED=0, STATE_OPEN=1, STATE_HALF_OPEN=2) so
-- smg_worker_cb_state means the same thing on both gateways. Lua-side ordering
-- assumptions must use the constants, never the numbers.
_M.CB_CLOSED = 0
_M.CB_OPEN = 1
_M.CB_HALF_OPEN = 2

local CB_STATE_NAME = { "closed", "open", "half_open" }
_M.CB_STATE_NAME = CB_STATE_NAME

-- ngx.shared.DICT is resolved lazily so the module also loads under `resty -t`.
local dict

local function shdict()
    if dict == nil then
        dict = ngx.shared[DICT_NAME]
    end
    return dict
end

-- ------------------------------------------------- upstream reconcile coupling
--
-- The worker-0 self-healing timer (init.lua) keys off the applied-revision
-- token in lr_workers (UPSTREAMS_REV_KEY there). e2e S3 showed the failure
-- mode: a manual DELETE /workers/<id> of a discovery=config member never
-- reached that token, so the pool drift stayed invisible and the member was
-- never re-added. Any *external* mutation of the pool therefore drops the
-- token here, and the next tick re-runs reconcile.
--
-- Anti-spin: config_store.reconcile_upstreams legitimately calls add/remove
-- while it applies the document; letting those clear the token would make
-- every pass schedule another one forever. The timer wraps its pass in
-- _M.set_reconcile_guard(true), so reconcile-originated add/remove skip the
-- clear (a per-Lua-process flag; the timer is worker 0 only, while
-- control-plane writes that reconcile run in request workers with the guard
-- off, so genuine drift stays visible). init.lua also runs one unconditional
-- sweep every few ticks to bound the narrow window where an external
-- mutation lands inside a guarded reconcile.
local APPLIED_REV_KEY = "upstreams:applied_rev"
local reconcile_guard = false

---Open/close the reconcile-origin filter for the applied-revision invalidation.
---@param on any @ truthy = suppress invalidation in this Lua process
function _M.set_reconcile_guard(on)
    reconcile_guard = on and true or false
end

---Drop the applied-revision token so worker 0's timer sees pool drift.
---Tolerates every non-nginx shape (no ngx, no shdict, fake test dicts): pure
---unit environments must not raise from a pool write.
local function invalidate_applied_rev()
    if reconcile_guard then
        return
    end
    local ok, d = pcall(shdict)
    if ok and d then
        pcall(function() d:delete(APPLIED_REV_KEY) end)
    end
end

local function with_lock(fn)
    local lock, err = lock_mod:new(LOCK_DICT, { timeout = 5, exptime = 10 })
    if not lock then
        return nil, "lock init failed: " .. tostring(err)
    end
    local ok, err = lock:lock("registry")
    if not ok then
        return nil, "lock failed: " .. tostring(err)
    end
    local res, ferr = pcall(fn)
    lock:unlock()
    if not res then
        return nil, "registry operation failed: " .. tostring(ferr)
    end
    return true
end

-- ------------------------------------------------------------------ worker id

local digest_mod

--- sha224(url) hex, first 32 chars, rendered in 8-4-4-4-12 UUID form.
---@param url string
---@return string
function _M.worker_id_for_url(url)
    if not digest_mod then
        digest_mod = require "resty.openssl.digest"
    end
    local d, err = digest_mod.new("sha224")
    if not d then
        error("sha224 unavailable: " .. tostring(err))
    end
    local ok, uerr = d:update(url)
    if not ok then
        error("sha224 update failed: " .. tostring(uerr))
    end
    local raw, ferr = d:final()
    if not raw then
        error("sha224 final failed: " .. tostring(ferr))
    end
    local hex = {}
    for i = 1, #raw do
        hex[#hex + 1] = string.format("%02x", string.byte(raw, i))
    end
    local h = table.concat(hex):sub(1, 32)
    return string.format("%s-%s-%s-%s-%s",
        h:sub(1, 8), h:sub(9, 12), h:sub(13, 16), h:sub(17, 20), h:sub(21, 32))
end

local UUID_RE = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

---@param raw string
---@return string|nil id, string|nil err
function _M.parse_worker_id(raw)
    if type(raw) ~= "string" or raw == "" then
        return nil, "empty worker_id"
    end
    local candidate = string.lower(raw)
    if not ngx.re.match(candidate, UUID_RE, "jo") then
        return nil, string.format("Invalid worker_id '%s' (expected UUID)", raw)
    end
    return candidate
end

-- ------------------------------------------------------------------ url parse

---@param url string
---@return string|nil normalized, string|nil err
function _M.normalize_url(url)
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

_M.strip_rank = strip_rank

---DP rank carried by a url, or nil when it is a plain (non-rank) url.
---
---Also the expansion guard: a url that already ends in a rank is a rank, so it
---must never be expanded again. That matters for a rank deleted and re-added
---through POST /workers, which arrives without the dp_* record fields and would
---otherwise be re-expanded into "<base>@<rank>@0..N".
---@param url string
---@return number|nil rank
function _M.rank_of(url)
    local stripped = strip_rank(url)
    if stripped == url then
        return nil
    end
    return tonumber(url:match("@(%d+)$"))
end

---@param url string @normalized
---@return string host, number port, boolean tls
function _M.split_url(url)
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
function _M.tls_handshake(sock, host, tls)
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
function _M.pool_name(kind, url)
    local host, port, tls = _M.split_url(url)
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
function _M.pool_opts(cfg, kind, url)
    local host, port, tls = _M.split_url(url)
    local keep = cfg.tcp_keepalive_secs or 30
    return {
        pool = _M.pool_name(kind, url),
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
function _M.pool_idle_ms(cfg)
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
function _M.pump_chunked(sock, collect)
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
function _M.response_reusable(headers, complete)
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
function _M.release(sock, cfg, reusable, kind, url)
    if reusable and cfg then
        local pool_size
        if kind and url then
            pool_size = _M.pool_opts(cfg, kind, url).pool_size
        end
        local ok = sock:setkeepalive(_M.pool_idle_ms(cfg), pool_size)
        if ok then
            return true
        end
    end
    sock:close()
    return false
end


-- ------------------------------------------------------------------ policy hint

---Routing hint advertised by a worker of one model (labels.policy), plus how many
---workers the model has.
---
---The Rust gateway reads the hint once, when the worker joins
---(core/steps/worker/shared/update_policies.rs:102 -> policies/registry.rs:66
---on_worker_added), and keeps it for as long as the model has a worker; the entry
---goes away with the last one (registry.rs:111). The worker records are this
---router's durable copy, so the lookup re-reads them: that survives a restart and
---an nginx reload without a second store, and the first hinted worker of a model
---still wins because the id list is registration-ordered.
---@param model_id string|nil
---@return string|nil hint, number worker_count
function _M.policy_hint_for_model(model_id)
    if type(model_id) ~= "string" or model_id == "" then
        return nil, 0
    end
    local records = _M.records()
    local hint, count = nil, 0
    for i = 1, #records do
        local record = records[i]
        if record.model_id == model_id then
            count = count + 1
            if not hint then
                local labels = record.labels
                if type(labels) == "table" then
                    local candidate = labels.policy
                    if type(candidate) == "string" and candidate ~= "" then
                        hint = candidate
                    end
                end
            end
        end
    end
    return hint, count
end

-- ------------------------------------------------------------------ id index

local function read_ids(d)
    local raw = d:get(IDS_KEY)
    if not raw or raw == "" then
        return {}
    end
    local ids = {}
    for id in string.gmatch(raw, "[^,]+") do
        ids[#ids + 1] = id
    end
    return ids
end

local function write_ids(d, ids)
    if #ids == 0 then
        d:delete(IDS_KEY)
        return
    end
    local ok, err = d:set(IDS_KEY, table.concat(ids, ","))
    if not ok then
        error("failed to persist worker id index: " .. tostring(err))
    end
end

-- ------------------------------------------------------------------ CRUD

-- The Rust worker spec models both knobs as enums (core/worker.rs:423-436 and
-- :514-525), with two extra worker-type variants and a tagged non-HTTP
-- connection mode. This gateway serves the regular HTTP plane only (scope-trim.md
-- removed the transport and pool-splitting planes), so the other enum variants
-- answer 400 rather than being silently collapsed to Regular -- the same
-- deviation from Rust that the contract suite pins.
_M.WORKER_TYPES = { regular = true }
_M.CONNECTION_MODES = { http = true }

---Lower-case a knob to its canonical spelling, or nil when unrecognised.
local function keyword(value, allowed)
    if type(value) ~= "string" then
        return nil
    end
    local lowered = string.lower(value)
    if allowed[lowered] then
        return lowered
    end
    return nil
end

---Normalised worker_type for a POST /workers body.
---@param value any
---@return string|nil kind @ nil = regular
---@return string|nil err
function _M.parse_worker_type(value)
    if value == nil or value == cjson.null then
        return nil
    end
    if type(value) ~= "string" then
        return nil, 'worker_type must be a string (only "regular" is supported)'
    end
    if keyword(value, _M.WORKER_TYPES) ~= "regular" then
        return nil, 'unsupported worker_type "' .. value
            .. '" (only "regular" is supported by the Lua router)'
    end
    return nil
end

---Normalised connection mode for a POST /workers body.
---
---The accepted spellings come from the Rust wire spec: a plain string, the serde
---internally-tagged object {"type":"http","port":n}, or a scheme carried by the
---url. Only "http" is served by this gateway, so every other spelling is a 400;
---a non-http(s) *url scheme* is rejected by _M.parse_spec_url instead.
---@param value any @ req.connection_mode
---@return string mode @ always "http"
---@return string|nil err
function _M.parse_connection_mode(value)
    local kind
    if value == nil or value == cjson.null then
        kind = nil
    elseif type(value) == "string" then
        kind = value
    elseif type(value) == "table" then
        -- serde internally-tagged shape: {"type":"http",...}
        kind = value.type or value["mode"]
        if type(kind) ~= "string" then
            return "http", 'connection_mode object must carry a string "type"'
        end
    else
        return "http",
            "connection_mode must be a string or an object with a type key"
    end

    if kind ~= nil and keyword(kind, _M.CONNECTION_MODES) ~= "http" then
        return "http", "unsupported connection_mode \"" .. kind
            .. "\" (only \"http\" is supported by the Lua router)"
    end
    return "http", nil
end

---Store-ready url. This gateway speaks HTTP to its workers, so a scheme other
---than http(s) is not rewritten but rejected: the record url is also the
---health-probe and control-plane target, and a target the router cannot dial
---must never enter the pool.
---@param url string
---@return string|nil normalized, string|nil err
function _M.parse_spec_url(url)
    if type(url) ~= "string" or url == "" then
        return nil, "url is required"
    end
    local scheme = url:match("^(%a[%w+.-]*)://")
    if scheme then
        scheme = string.lower(scheme)
        if scheme ~= "http" and scheme ~= "https" then
            return nil, "unsupported worker url scheme \"" .. scheme
                .. "\" (only http and https are proxied)"
        end
    end
    return _M.normalize_url(url)
end

---Non-empty string or nil, so an optional WorkerSpec field is absent rather than
---cjson.null on the record (the capability readers test type() == "string").
local function string_field(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

--- Normalized list of every model id one worker advertises.
---
--- 为什么要这个字段（root 裁定 2026-10-01，虚拟模型多绑定）：虚拟模型现在能把不同候选绑到
--- 不同模型上，于是网关必须知道"某个实例到底提供哪些模型"。记录里原来只有一个 model_id，
--- 探针在 /v1/models 看到的多模型列表只留了第一条、其余当场丢弃（watcher 那边），配置声明
--- 更是只有一列 model_id。没有这份列表，多绑定的配置就只能靠"名字看起来像"来路由：绑错一个
--- 就整条请求 4xx，而网关明明有能力当场判掉。
---
--- 三个入口都归一到同一形状：请求体里的 models 数组、只写了 model_id 的老形状、以及
--- labels.served_model_name。缺省返回 nil 而不是空表——空表在 patch_record 的合并语义里是
--- "声明了空集合"，与"没说过"必须可区分（见 merge_models）。
--- 顺序保持调用方给定的顺序，去重；非字符串项忽略（上游把 models 写成对象时不该整条注册失败）。
---@param value any @ raw models field from a registration request or a probe meta
---@param fallback string|nil @ model_id / served_model_name to seed from
---@return table|nil @ array of model ids, or nil when nothing was advertised
local function norm_models(value, fallback)
    local out, seen = {}, {}
    local function note(model)
        if type(model) ~= "string" then
            return
        end
        local trimmed = model:match("^%s*(.-)%s*$")
        -- "unknown" is our own placeholder for "not discovered yet" (see _M.add), never
        -- something an engine advertises. Letting it in would make the multi-binding
        -- filter route real traffic to a name no engine will accept.
        if trimmed == "" or trimmed == "unknown" or seen[trimmed] then
            return
        end
        seen[trimmed] = true
        out[#out + 1] = trimmed
    end
    if type(value) == "table" then
        for i = 1, #value do
            note(value[i])
        end
    end
    note(fallback)
    if #out == 0 then
        return nil
    end
    return out
end

--- Fold a new model list into a stored record without inventing coverage.
---
--- 三条规则，都来自"这份列表只能代表它自己的来源"：
---   * 新来的是 nil（对方没说过模型列表）：保持原值。 discovery 那条路径就是典型——它只在
---     model_id 还是 unknown 时才跑，手里根本没有 /v1/models 的完整列表，绝不能拿
---     {model_id} 去覆盖 watcher 探到的全量列表。
---   * 主模型变化（改名、纠正、配置声明了另一个模型）：整表替换。这时旧列表多半来自别的
---     引擎或上一次注册，留着它等于让一个实例继续广告它已经不服务的模型。
---   * 两者都没变：并集。 配置只声明 model_id 的运维补充场景里，探针后到补全列表，而声明值
---     不能被探针悄悄抹掉（否则刚配好的绑定会随下一轮心跳消失）。
---@param opts table|nil @{replace=true: the incoming list is an *observation* (the
---            worker answered /v1/models), so it is authoritative and the stored list
---            is dropped. Default is fold/union, for declarations: an operator naming
---            one model must not delete what the probe already saw.}
---@return table|nil @ the list to store, or nil when the field should stay unset
local function merge_models(record, incoming, opts)
    if incoming == nil then
        return record.models
    end
    if opts and opts.replace then
        return incoming
    end
    local primary = record.model_id
    local current = record.models
    if type(current) ~= "table" or #current == 0 then
        return incoming
    end
    local merged, seen = {}, {}
    local function note(model)
        if type(model) == "string" and model ~= "" and not seen[model] then
            seen[model] = true
            merged[#merged + 1] = model
        end
    end
    note(primary)
    for i = 1, #current do
        note(current[i])
    end
    for i = 1, #incoming do
        note(incoming[i])
    end
    if #merged == 0 then
        return nil
    end
    return merged
end

---Every model a record claims to serve: the advertised list when it has one, plus the
---primary model_id. Shared by the answer below and by any listing that wants the truth
---rather than the single column.
---@param record table|nil
---@return table @ array (possibly empty)
local function models_of(record)
    -- Empty is rendered as [], not {}: consumers index the field as an array
    -- (jq .models[], the pool table), and cjson turns a bare {} table into an object.
    local EMPTY = setmetatable({}, cjson.empty_array_mt)
    if type(record) ~= "table" then
        return EMPTY
    end
    -- Primary first: several readers (props.lua, the UI pool table) take models[1] as
    -- "the" model of a worker, and that position has always been model_id. Keeping the
    -- invariant means widening the field cannot silently re-point those readers at
    -- whatever the probe happened to list first.
    -- Built as one flat candidate list rather than via the fallback argument: that
    -- position takes a *single* string, and passing record.models there would have
    -- norm_models() ignore the array wholesale (its note() skips non-strings), leaving
    -- every multi-advertised name invisible.
    local list = { record.model_id }
    if type(record.models) == "table" then
        for i = 1, #record.models do
            list[#list + 1] = record.models[i]
        end
    end
    return norm_models(list, nil) or EMPTY
end

---Should the coverage probe run for this record?
---
--- 只有一种情况需要再探：记录已经有主模型、可广告列表却还没成型（缺省或只有一条）。这正是
--- watcher / 单模型配置声明 / 手工 POST 三条入口的共同产物。已经有两条以上就没什么可问的——
--- 那个列表是引擎亲口答的，重复探只会白占巡检时间。
---@param record table|nil
---@return boolean
local function needs_models_refresh(record)
    if type(record) ~= "table" then
        return false
    end
    local list = record.models
    if type(list) ~= "table" or #list <= 1 then
        return true
    end
    return false
end
_M.needs_models_refresh = needs_models_refresh


---Queue the registration of a worker (202 semantics live in router.lua).
---@param req table @ decoded POST /workers body
---@param cfg table @ router config providing the health-check defaults
---@return table|nil result @ {id, url, location, status}
---@return string|nil err
---@return string|nil kind @ "validation" for client-side rejections (400)
-- ------------------------------------------------------------------ mesh mirror
--
-- The cluster view (doc/gap-mesh.md 4.2) is a mirror of these records and has to
-- follow every write: the boot seed, a control-plane POST/PUT/DELETE, metadata
-- discovery and a health flip. router.lua used to be the only caller (from inside
-- its own /workers handlers), which left every other write path - above all
-- SMG_WORKER_URLS - invisible to peers, and left a mirrored worker frozen at the
-- record as it stood at registration time (health false, model unknown). Hooking
-- the registry's own write paths means a new one cannot forget it again.
--
-- mesh is required lazily and every step is guarded: the pure-Lua unit tests load
-- this module without ngx, and with the mesh off there is no instance to write to.
---@param id string
local function mesh_mirror(id)
    if not ngx or not ngx.shared then
        return false
    end
    local ok, mesh_mod = pcall(require, "resty.luarouter.mesh")
    if not ok or type(mesh_mod) ~= "table"
        or type(mesh_mod.instance) ~= "function" then
        return false
    end
    local inst = mesh_mod.instance()
    if not inst then
        return false
    end
    return inst:observe_worker(id, _M.get(id), _M.cb_state(id))
end

---Delete-side half: drop the key once the record is gone.
---@param id string
local function mesh_forget(id)
    if not ngx or not ngx.shared then
        return false
    end
    local ok, mesh_mod = pcall(require, "resty.luarouter.mesh")
    if not ok or type(mesh_mod) ~= "table"
        or type(mesh_mod.instance) ~= "function" then
        return false
    end
    local inst = mesh_mod.instance()
    if not inst or type(inst.remove_worker) ~= "function" then
        return false
    end
    return inst:remove_worker(id)
end

function _M.add(req, cfg)
    if type(req) ~= "table" then
        return nil, "invalid worker config", "validation"
    end
    local worker_type, type_err = _M.parse_worker_type(req.worker_type)
    if type_err then
        return nil, type_err, "validation"
    end
    local mode, mode_err = _M.parse_connection_mode(req.connection_mode)
    if mode_err then
        return nil, mode_err, "validation"
    end
    local url, err = _M.parse_spec_url(req.url)
    if not url then
        return nil, err, "validation"
    end

    local id = _M.worker_id_for_url(url)

    local ok, lerr = with_lock(function()
        local d = shdict()
        if d:get(K_URL2ID .. url) then
            -- Idempotent: the URL keeps its id and the duplicate surfaces as a
            -- failed job, matching the Rust create_worker step.
            _M.set_job(url, "add_worker", "failed",
                string.format("Worker %s already exists", url))
            return
        end
        local record = {
            id = id,
            url = url,
            model_id = req.model_id or (type(req.labels) == "table"
                and req.labels.served_model_name) or "unknown",
            -- Every model this endpoint advertises. Read from the request so each
            -- registration entry point (POST /workers, the watcher, the config
            -- declaration layer, the bootstrap seed, DP ranks) gets the same shape
            -- without touching its own call site; a caller that knows only one model
            -- keeps working because model_id seeds the list. "unknown" never enters
            -- it: that is our placeholder for "not discovered yet", not something an
            -- engine advertises, and a record claiming to serve "unknown" would make
            -- the multi-binding filter route real traffic to a bogus name.
            models = norm_models(rawget(req, "models"),
                type(req.model_id) == "string" and req.model_id
                    or (type(req.labels) == "table" and req.labels.served_model_name)),
            priority = tonumber(req.priority) or 50,
            cost = tonumber(req.cost) or 1.0,
            -- Per-worker capacity caps (doc/gap-worker-caps.md): stored only when a
            -- usable limit was declared, so a record built without them keeps its
            -- exact pre-feature shape and the selection path short-circuits on
            -- `cap == nil` before it touches a dict. Every registration entry
            -- point (POST /workers, the watcher, the config declaration layer, the
            -- bootstrap seed, DP ranks) gets them from here rather than its own
            -- call site, which is what keeps the four paths identical.
            max_concurrency = _M.cap_limit(rawget(req, "max_concurrency"), true),
            max_power_w = _M.cap_limit(rawget(req, "max_power_w"), false),
            worker_type = worker_type or "regular",
            connection_mode = mode,
            api_key = req.api_key,
            labels = type(req.labels) == "table" and req.labels or {},
            -- The four model-card capability fields (token-counting path, tool
            -- and reasoning parser names, vocab size) went with the proxy plane
            -- that read them (doc/scope-trim.md). A POST /workers body that
            -- still carries them ignores them: they are not stored and not
            -- echoed.
            disable_health_check = (req.disable_health_check and true)
                or (cfg.disable_health_check and true)
                or false,
            registered_at = ngx.time(),
            -- Provenance and DP identity. Both are copied onto the record
            -- (rather than inferred from labels) because expansion reads them and
            -- they must not be editable through a PUT /workers label patch.
            -- `discovery` is whatever wrote the entry (a watcher's own name);
            -- dp_* describe a rank of a data-parallel engine.
            discovery = string_field(req.discovery),
            dp_rank = tonumber(req.dp_rank),
            dp_size = tonumber(req.dp_size),
            dp_base_url = string_field(req.dp_base_url),
            -- Copied from the router defaults: the Rust gateway ignores the
            -- per-worker health knobs on POST too, because build_health_config
            -- reads app_context.router_config only.
            health_check_timeout_secs = cfg.health_check_timeout_secs,
            health_check_interval_secs = cfg.health_check_interval_secs,
            health_success_threshold = cfg.health_success_threshold,
            health_failure_threshold = cfg.health_failure_threshold,
        }
        local encoded = json_encode(record)
        if not encoded then
            error("failed to encode worker record")
        end
        local stored, serr = d:set(K_WORKER .. id, encoded)
        if not stored then
            error("failed to store worker record: " .. tostring(serr))
        end
        d:set(K_URL2ID .. url, id)
        d:set(K_IDURL .. id, url)
        d:set(K_HSEL .. id, _M.record_http_selectable(record) and 1 or 0)
        -- A fresh worker starts unhealthy until its first health check passes,
        -- unless health checks are disabled for it.
        d:set(K_HEALTH .. id, record.disable_health_check and 1 or 0)
        d:set(K_HFAIL .. id, 0)
        d:set(K_HSUCC .. id, 0)
        d:set(K_CBSTATE .. id, _M.CB_CLOSED)
        d:set(K_CBF .. id, 0)
        d:set(K_CBS .. id, 0)
        d:set(K_LOAD .. id, 0)
        d:set(K_ACTIVE .. id, 0)  -- 从未活跃过，让第一次巡检会探它
        -- A re-registration is a new engine behind the url: whatever the previous
        -- owner's GPU was doing has no right to describe this one, so both
        -- external channels start empty (the load source refills them on its tick).
        d:delete(K_XLOAD .. id)
        d:delete(K_SLOAD .. id)
        d:delete(K_POWER .. id)
        local ids = read_ids(d)
        local seen = false
        for i = 1, #ids do
            if ids[i] == id then
                seen = true
                break
            end
        end
        if not seen then
            ids[#ids + 1] = id
            write_ids(d, ids)
        end
    end)
    if not ok then
        return nil, lerr
    end

    -- Pool drift must reach the self-healing timer (see the reconcile-coupling
    -- block near shdict): drop the applied-revision token unless this add is
    -- part of an ongoing guarded reconcile pass.
    invalidate_applied_rev()

    -- Queued rather than synchronous: the caller answers 202 either way.
    if not shdict():get(K_WORKER .. id) then
        _M.set_job(url, "add_worker", "pending", nil)
    end
    mesh_mirror(id)
    return { id = id, url = url, location = "/workers/" .. id, status = "accepted" }
end

---Remove a worker by id and free its URL so the URL can be re-registered.
---@param worker_id string
---@return table|nil result @ {worker_id, url}
---@return string|nil err
function _M.remove(worker_id)
    local id, perr = _M.parse_worker_id(worker_id)
    if not id then
        return nil, perr
    end
    local d = shdict()
    local raw = d:get(K_WORKER .. id)
    if not raw then
        return nil, "Worker " .. id .. " not found"
    end
    local record = json_decode(raw) or {}
    local url = record.url

    local ok, lerr = with_lock(function()
        local dd = shdict()
        dd:delete(K_WORKER .. id)
        if url then
            dd:delete(K_URL2ID .. url)
            dd:delete(K_JOB .. url)
        end
        dd:delete(K_IDURL .. id)
        for _, prefix in ipairs({ K_HEALTH, K_HFAIL, K_HSUCC, K_CBSTATE,
                                 K_CBF, K_CBS, K_CBO, K_LOAD, K_XLOAD, K_SLOAD,
                                K_POWER,
                                K_DISC, K_DPROBE, K_MPROBE, K_MPROBE_OK, K_HSEL }) do
            dd:delete(prefix .. id)
        end
        local kept = {}
        local ids = read_ids(dd)
        for i = 1, #ids do
            if ids[i] ~= id then
                kept[#kept + 1] = ids[i]
            end
        end
        write_ids(dd, kept)
    end)
    if not ok then
        return nil, lerr
    end
    -- A hand DELETE of a discovery=config member is exactly the drift the
    -- timer must catch: clear the applied-revision token (guarded reconcile's
    -- own removals skip it, so the pass still converges).
    invalidate_applied_rev()
    mesh_forget(id)
    return { worker_id = id, url = url }
end

---Static record plus live mutable fields, in the WorkerInfo wire shape.
---@param worker_id string
---@return table|nil info
function _M.get(worker_id)
    local id, perr = _M.parse_worker_id(worker_id)
    if not id then
        return nil, perr
    end
    local d = shdict()
    local raw = d:get(K_WORKER .. id)
    if not raw then
        return nil
    end
    local record = json_decode(raw)
    if type(record) ~= "table" then
        return nil
    end
    record.id = record.id or id
    return _M.info(record, d)
end

---@param record table @ decoded static record
---@param d ngx.shared.Dict|nil
---@return table
function _M.info(record, d)
    d = d or shdict()
    local id = record.id
    local labels = record.labels or {}
    local metadata = {}
    for k, v in pairs(labels) do
        metadata[k] = tostring(v)
    end
    local job
    if record.url then
        job = _M.get_job(record.url)
    end
    return {
        id = id,
        url = record.url,
        model_id = record.model_id or "unknown",
        -- Advertised coverage, the shape the admin console and the multi-binding
        -- config need: a worker that serves two engines' models shows both, and a
        -- worker that has never been probed shows [] rather than the placeholder
        -- "unknown" that model_id still carries for the pre-feature readers.
        models = models_of(record),
        priority = record.priority or 50,
        cost = record.cost or 1.0,
        worker_type = record.worker_type or "regular",
        is_healthy = (d:get(K_HEALTH .. id) or 0) == 1,
        -- The same number the policies rank on (see _M.load), so /workers and the
        -- admin console show what selection actually saw rather than a different
        -- half of it. With no load source configured this is exactly the in-flight
        -- counter, i.e. the Rust-parity value the contract pins.
        load = _M.load_with(d, id),
        connection_mode = record.connection_mode or "http",
        metadata = metadata,
        disable_health_check = record.disable_health_check or false,
        job_status = job,
        -- Capacity caps and their two live readings (doc/gap-worker-caps.md).
        -- A cap that was never declared is *absent* rather than 0 -- 0 would read
        -- as "a limit of zero slots" to anything that does not know cap_limit's
        -- normalization, and the admin console needs to tell "unlimited" apart from
        -- "configured to 0 and therefore never selectable". inflight_requests is
        -- the pure request count (what the concurrency cap compares against), which
        -- is deliberately not `load` -- that field is the ranking number and mixes
        -- in the GPU sample. power_w stays nil while no fresh watt sample exists,
        -- which is the same "unknown, not zero" the power cap reads.
        max_concurrency = _M.cap_limit(record.max_concurrency),
        max_power_w = _M.cap_limit(record.max_power_w),
        inflight_requests = d:get(K_LOAD .. id) or 0,
        power_w = (function()
            local milli = d:get(K_POWER .. id)
            return milli and (milli / 1000) or nil
        end)(),
        -- Provenance for GET /workers (doc/gap-virtual-models.md 3.1): config
        -- members are the config_store-declared upstreams; everything else
        -- (watcher, SMG_WORKER_URLS bootstrap, POST /workers, mesh mirror)
        -- reports the neutral "dynamic". The raw provenance string is only
        -- surfaced when it is not already the dynamic spelling.
        discovery = (record.discovery ~= nil and record.discovery ~= "")
            and record.discovery or "dynamic",
    }
end

---@return table[] @ WorkerInfo list
function _M.list()
    local d = shdict()
    local out = {}
    local records = _M.records()
    for i = 1, #records do
        out[#out + 1] = _M.info(records[i], d)
    end
    return out
end

---Raw static records (used by the health checker, router and policy timers).
---@return table[]
function _M.records()
    local d = shdict()
    local out = {}
    local ids = read_ids(d)
    for i = 1, #ids do
        local raw = d:get(K_WORKER .. ids[i])
        if raw then
            local record = json_decode(raw)
            if type(record) == "table" then
                record.id = record.id or ids[i]
                out[#out + 1] = record
            end
        end
    end
    return out
end

---@param id string
---@return table|nil
function _M.record(id)
    local d = shdict()
    local raw = d:get(K_WORKER .. id)
    if not raw then
        return nil
    end
    local record = json_decode(raw)
    if type(record) ~= "table" then
        return nil
    end
    record.id = record.id or id
    return record
end

---Does a record belong to the HTTP inference plane?
---
---The router's candidate filter (router.lua `candidates_for`, shared by every
---HTTP route) asks only `registry.is_available(id)`, so the pool rule lives here
---rather than in the router: a record that is not a plain HTTP worker must never
---be handed an OpenAI HTTP request. Only `connection_mode = "http"` **and**
---`worker_type = "regular"` may, which is every record this build can store.
---@param record table|nil
---@return boolean
function _M.record_http_selectable(record)
    if type(record) ~= "table" then
        return false
    end
    local mode = record.connection_mode or "http"
    local worker_type = record.worker_type or "regular"
    return mode == "http" and worker_type == "regular"
end

---Write the derived flag for one record (call while holding the same lock that
---wrote the record, so the pair cannot be observed half-updated).
---@param id string
---@param record table
function _M.set_http_selectable(id, record)
    shdict():set(K_HSEL .. id, _M.record_http_selectable(record) and 1 or 0)
end

---HTTP-plane availability. Missing flag = record written by an older build, so
---fall back to decoding it once and cache the answer.
---@param id string
---@return boolean
function _M.http_selectable(id)
    local d = shdict()
    local flag = d:get(K_HSEL .. id)
    if flag ~= nil then
        return flag == 1
    end
    local raw = d:get(K_WORKER .. id)
    if not raw then
        return false
    end
    local selectable = _M.record_http_selectable(json_decode(raw)) and 1 or 0
    d:set(K_HSEL .. id, selectable)
    return selectable == 1
end

---@return string[] @ distinct model ids with at least one worker
function _M.models()
    local seen, out = {}, {}
    local records = _M.records()
    for i = 1, #records do
        local model = records[i].model_id or "unknown"
        if not seen[model] then
            seen[model] = true
            out[#out + 1] = model
        end
    end
    table.sort(out)
    return out
end

--- Every model id advertised by any worker, primary and multi-advertised alike.
---
--- Kept separate from _M.models() on purpose: that one is the Rust-parity single
--- column the /metrics pool gauge and the legacy /v1/models list are pinned to, so
--- widening it would move a contract assertion. The admin console and the
--- multi-binding config read *this* one, where "this instance also serves model X"
--- has to be visible.
---@return string[] @ sorted distinct model ids
function _M.all_models()
    local seen, out = {}, {}
    local records = _M.records()
    for i = 1, #records do
        local list = models_of(records[i])
        for j = 1, #list do
            local model = list[j]
            if not seen[model] then
                seen[model] = true
                out[#out + 1] = model
            end
        end
    end
    table.sort(out)
    return out
end

--- Advertised model list of one worker, by id. Empty array when nothing learned yet.
---@param id string
---@return table @ array of model ids (fresh table; the caller may keep it)
function _M.worker_models(id)
    if type(id) ~= "string" or id == "" then
        return {}
    end
    return models_of(_M.record(id))
end

--- Advertised list of an already-decoded record, exported so the config layer can
--- build its registered-model table (which wants every advertised name, not one
--- column) without reimplementing the primary-first ordering rule.
---@param record table|nil
---@return table
function _M.record_models(record)
    return models_of(record)
end

--- HTTP-plane workers grouped by url as {url, api_key, models}, the shape props.lua
--- asks for first (it prefers this function whenever the registry exports it, and
--- only falls back to grouping records() by the single model_id column itself).
---
--- 为什么由 registry 提供：那是唯一同时看得见 records 与探针学到的 models 的地方。
--- props.lua 的自带回退只读 model_id 一列，于是多广告的第二个模型在 /_ui/v1/models、
--- /props 的候选匹配和 config 的 models 文档里都看不见——绑定了却看不到，等于需求没做完。
--- 这里补上，props/ui/config 三个消费者不用改就一起看到全量。
---
--- 与 props 的回退分支保持同一套可用性判据（connection_mode=http），并在 registry 本身
--- 不可用时（纯 Lua 单测没有 ngx.shared，records() 会抛）退回 props 原来会用的
--- LMR_TEST_WORKERS 注入，避免导出这个函数反而把单测的注入口关死。
---@return table[]
function _M.http_workers()
    local ok_records, records = pcall(_M.records)
    if not ok_records or type(records) ~= "table" then
        if ngx and ngx.shared then
            return {}
        end
        local injected = rawget(_G, "LMR_TEST_WORKERS")
        if type(injected) == "table" then
            return injected
        end
        return {}
    end
    local by_url, out = {}, {}
    for i = 1, #records do
        local rec = records[i]
        local url = rec.url
        local mode = rec.connection_mode or "http"
        local wtype = rec.worker_type or "regular"
        if url and mode == "http" and wtype == "regular" then
            local w = by_url[url]
            if not w then
                local key = rec.api_key
                if key == false or key == cjson.null then key = nil end
                w = { url = url, api_key = key, models = {}, seen = {} }
                by_url[url] = w
                out[#out + 1] = w
            end
            local list = models_of(rec)
            for j = 1, #list do
                local model = list[j]
                if not w.seen[model] then
                    w.seen[model] = true
                    w.models[#w.models + 1] = model
                end
            end
        end
    end
    for i = 1, #out do
        out[i].seen = nil
    end
    return out
end

---Does one worker advertise model M?
---
---The multi-binding question the router asks per candidate (a virtual model may bind
---different candidates to different models, so "is this instance usable for that
---name" can no longer be a single model_id equality).
---
---Three-way answer, because the pool has a third state and guessing on it would
---cost requests:
---  true   -- the worker advertises M (probe list, or its primary model_id).
---  false  -- the worker advertises a list that does not contain M. That is a real
---            denial: it answered /v1/models and named what it serves, so routing
---            the request there means a 4xx from the engine. How *trustworthy* that
---            denial is depends on who named the list, so the caller that has to make
---            a routing decision should also ask _M.models_are_verified(): an answer
---            from the engine is a fact, a list that only ever came from a
---            registration body or a config row is somebody's note, and dropping an
---            otherwise healthy worker over a hand-filled config row is the mistake
---            this feature exists to avoid.
---  nil    -- we never learned what it serves (no probe list and model_id is still
---            the placeholder). The caller decides whether an unknown engine is
---            usable; a whitelist-style narrowing treats it as usable, because
---            "we have not looked yet" must not become "this worker is broken" --
---            the same rule that keeps a failed probe from ever removing a worker.
---@param id_or_record string|table
---@param model string|nil @ nil/"" = the question is meaningless; answered nil
---@return boolean|nil
function _M.worker_serves_model(id_or_record, model)
    if type(model) ~= "string" or model == "" then
        return nil
    end
    local record
    if type(id_or_record) == "table" then
        record = id_or_record
    elseif type(id_or_record) == "string" and id_or_record ~= "" then
        record = _M.record(id_or_record)
    end
    if type(record) ~= "table" then
        return nil
    end
    -- Exact comparison, deliberately: an engine's model id is an opaque key that it
    -- matches itself, and prefix/fuzzy "looks close enough" guessing is how a request
    -- for qwen3-30b ends up on a qwen3-30b-instruct that 404s it.
    local list = models_of(record)
    if #list == 0 then
        return nil
    end
    for i = 1, #list do
        if list[i] == model then
            return true
        end
    end
    -- Denying a request is the expensive direction, so it needs the engine's own
    -- word. Until a /v1/models answer backs the list, "not in it" is only "nobody
    -- wrote it down", which must stay routable.
    return false
end

---Was a worker's advertised list learned from the engine's own /v1/models answer?
---
---The provenance bit behind worker_serves_model's three-way answer. Exported so
---the router (and the admin console) can tell "the engine says it does not serve M"
---from "nobody ever wrote M into a config row" -- the first is a routable denial,
---the second must never narrow traffic.
---@param id_or_record string|table
---@return boolean
function _M.models_are_verified(id_or_record)
    local record
    if type(id_or_record) == "table" then
        record = id_or_record
    elseif type(id_or_record) == "string" and id_or_record ~= "" then
        record = _M.record(id_or_record)
    end
    return type(record) == "table" and record.models_verified == true
end

---Can this worker be given a request for model M? The routing-shaped form of
---worker_serves_model, and the one the selection path should call.
---
---为什么再来一个：worker_serves_model 是三值答案，"要不要把它从候选里剔掉"这个决定
---得同时看来源（models_are_verified）才判得对。两个调用方各自拼这套逻辑，迟早有人只调
---第一个就把 false 当死刑用——那等于让一条手填的配置声明（或一次没探到的巡检）替一个
---健康的实例宣布不服务某模型，正是"监控故障不许吃掉流量"这条红线在选路上的形态。
---合成一个函数、缺省方向是"仍可路由"，就把这个坑填在写它的人这一侧。
---  false 只在一种情况下返回：引擎亲口答过 /v1/models，而它给的列表里没有 M。
---  其余一律 true，包括"从没探到过"（未知 ≠ 不可用）与"列表只是声明出来的"
---  （那人只写了他想到的名字）。
---@param id_or_record string|table
---@param model string|nil @ nil/"" = 问题不成立，不据此收窄
---@return boolean
function _M.candidate_allows_model(id_or_record, model)
    if type(model) ~= "string" or model == "" then
        return true
    end
    local verdict = _M.worker_serves_model(id_or_record, model)
    if verdict ~= false then
        return true
    end
    -- 用显式分支而不是 "verified and false or true"：Lua 里那个式子恒为 true
    -- （false 会落到 or 的右侧），等于把唯一的排除条件写没了。
    if _M.models_are_verified(id_or_record) then
        return false
    end
    return true
end

-- ------------------------------------------------------------------ live state

---@param id string
---@return boolean
---Worker URL for breaker metric labels (Rust labels those with the URL, not the
---id). Falls back to the id for a record written before the reverse key existed.
---@param id string
---@return string
function _M.url_for(id)
    local d = shdict()
    local url = d:get(K_IDURL .. id)
    if url then
        return url
    end
    local record = json_decode(d:get(K_WORKER .. id) or "")
    if type(record) == "table" and record.url then
        d:set(K_IDURL .. id, record.url)
        return record.url
    end
    return id
end

---@param id string
---@return boolean
function _M.is_healthy(id)
    return (shdict():get(K_HEALTH .. id) or 0) == 1
end

---@param id string
---@param healthy boolean
function _M.set_healthy(id, healthy)
    shdict():set(K_HEALTH .. id, healthy and 1 or 0)
    -- The cluster view advertises worker health (Rust's WorkerState.health), and a
    -- flip is exactly when a peer's view goes stale. Mirroring here rather than in
    -- the health sweep means every writer of health gets it for free, and the
    -- version bump inside observe_worker is what makes the update propagate.
    mesh_mirror(id)
end

---A worker is selectable when healthy and its breaker is not open.
---
--- An open circuit is not permanent: once cb_timeout_duration_secs has elapsed
--- the breaker half-opens so the next request can probe it. The flip happens
--- here because this is the only place every selection path goes through, which
--- is how the Rust gateway behaves too (is_available() calls
--- circuit_breaker().can_execute(), and can_execute() runs the state check).
--- The CAS on the state key makes exactly one concurrent selector perform the
--- transition, mirroring the compare_exchange in core/circuit_breaker.rs.
---Circuit-breaker availability, including the timed open -> half_open flip.
---Every selection path reads it through is_available, so a worker can only ever
---have one recovery clock.
---@param id string
---@return boolean
function _M.breaker_available(id)
    local d = shdict()
    local key = K_CBSTATE .. id
    local state = d:get(key) or _M.CB_CLOSED
    if state ~= _M.CB_OPEN then
        return true
    end

    local conf = require("resty.luarouter").config()
    if conf.disable_circuit_breaker then
        return true
    end

    local elapsed_ms = ngx.now() * 1000 - (d:get(K_CBO .. id) or 0)
    if elapsed_ms < conf.cb_timeout_duration_secs * 1000 then
        return false
    end

    -- This image has no shdict CAS, so the single-writer flip runs under the
    -- same registry lock the add/remove paths use. Whoever takes it performs the
    -- transition; everyone else just observes half_open and stays selectable.
    with_lock(function()
        local dd = shdict()
        if (dd:get(key) or _M.CB_CLOSED) ~= _M.CB_OPEN then
            return
        end
        dd:set(key, _M.CB_HALF_OPEN)
        dd:set(K_CBO .. id, ngx.now() * 1000)
        dd:set(K_CBF .. id, 0)
        dd:set(K_CBS .. id, 0)
        local label = _M.url_for(id)
        local ok_obs, observability = pcall(require, "resty.luarouter.observability")
        if ok_obs then
            observability.record_cb_transition(label, "open", "half_open")
        end
    end)
    return true
end

---Health, pool membership and breaker for the HTTP inference plane.
---@param id string
---@return boolean
function _M.is_available(id)
    if (shdict():get(K_HEALTH .. id) or 0) ~= 1 then
        return false
    end
    -- Pool gate: a non-HTTP record is invisible to the inference plane, and
    -- router.lua's candidate filter runs is_available on every route, so gating
    -- here keeps the HTTP surface byte-identical without touching router.lua.
    if not _M.http_selectable(id) then
        return false
    end
    return _M.breaker_available(id)
end

---Scheduling load for one worker, in in-flight-request units.
--
--This is *the* consumer-facing load field: power_of_two and manual's min_load mode
--read it through registry.load(), and the standalone policies get it through
--router.lua's `record.load` snapshot and _M.info's `load` key. One ranking rule
--here therefore reaches every policy without any policy module knowing that a load
--source exists (doc/gap-gpu-load.md §4).
--
--Priority, highest first:
--  1. the router's own in-flight counter. Nothing else knows what this process
--     handed a worker and has not finished serving, and it is the only signal that
--     reacts within a millisecond of a burst.
--  2. `xl:` the external GPU sample. It outranks the self-report because it is the
--     only reading of the shared hardware: a worker with nothing in flight but a
--     95 %-busy GPU (a queue another router process filled, a sibling rank of the
--     same DP engine, a co-located second engine) must not look idle to
--     power_of_two, and only the metrics/prometheus source can see that.
--  3. `sl:` the engine's own self-report, consulted only when no fresh external
--     sample exists. The metrics source answers every worker it can reach, so in
--     practice one channel wins and the two never fight over a field.
--
--Both external terms are 0..1 fractions, so they are weighted by load_scale (a 1.0
--sample = load_scale in-flight requests) before being added; that weight is what
--keeps SMG_BALANCE_ABS_THRESHOLD meaningful whatever the knob measures. Samples
--expire with their TTL, which degrades to in-flight alone: a monitoring system
--that dies costs accuracy, never capacity, and never a worker.
---@param id string
---@return number @ load in in-flight units
function _M.load(id)
    return _M.load_with(shdict(), id)
end

---The same ranking against an already-resolved dict.
---
---_M.info/_M.list pass their dict in so a /workers sweep reads one dict once
---instead of resolving it per worker, and so a caller holding a dict (a test double,
---a future batch path) can rank without going through the module-level cache.
---@param d table @ an ngx.shared.DICT (or a test double with get)
---@param id string
---@return number
function _M.load_with(d, id)
    local inflight = d:get(K_LOAD .. id) or 0
    if not _M.any_external_samples() then
        return inflight
    end
    local milli = d:get(K_XLOAD .. id)
    if milli == nil then
        milli = d:get(K_SLOAD .. id)
    end
    if milli == nil then
        return inflight
    end
    return inflight + (milli * _M.current_load_scale()) / 1000
end

---The external sample alone, normalized back to 0..1 (nil when there is none).
---Read by gpu_load's own reporting and the unit tests; the inference plane never
---needs it because _M.load already folded it in.
---@param id string
---@return number|nil load @ 0..1
function _M.external_load(id)
    if not _M.any_external_samples() then
        return nil
    end
    local milli = shdict():get(K_XLOAD .. id)
    if milli == nil then
        return nil
    end
    return milli / 1000
end

---Store one external GPU sample for a worker.
--
--Only gpu_load.lua (the metrics and prom sources) and the unit tests call this:
--the load source owns the key and there is no second writer, which is what makes
--the ranking in _M.load decidable rather than first-come-first-served.
---@param id string
---@param load number|nil @ normalized 0..1
---@param ttl_secs number|nil @ staleness window
---@return boolean written
function _M.set_external_load(id, load, ttl_secs)
    local milli = _M.to_milli(load)
    if milli == nil then
        return false
    end
    local seconds = _M.stale_ttl(ttl_secs)
    if not shdict():set(K_XLOAD .. id, milli, seconds) then
        return false
    end
    _M.flag_external_samples(seconds)
    return true
end

---Store one engine self-reported load (`/v1/loads`): the lower-priority channel.
---@param id string
---@param load number|nil @ normalized 0..1
---@param ttl_secs number|nil
---@return boolean written
function _M.set_self_reported_load(id, load, ttl_secs)
    local milli = _M.to_milli(load)
    if milli == nil then
        return false
    end
    local seconds = _M.stale_ttl(ttl_secs)
    if not shdict():set(K_SLOAD .. id, milli, seconds) then
        return false
    end
    _M.flag_external_samples(seconds)
    return true
end

---Drop both external channels for a worker (an operator override, or a test).
---@param id string
function _M.clear_external_load(id)
    local d = shdict()
    d:delete(K_XLOAD .. id)
    d:delete(K_SLOAD .. id)
end

------------------------------------------------------------------ capacity caps
--
-- Per-worker ceilings on the two things that actually run a serving instance out
-- of headroom: requests in flight and watts the GPU is drawing (the latter is the
-- fleet's own reason for the feature -- a card pinned at its power limit decodes
-- noticeably slower than one at half load, and neither the request count nor the
-- utilization gauge shows it). doc/gap-worker-caps.md.

---Normalize one declared cap. Absent, blank, non-numeric, NaN, +/-inf or a value
---<= 0 all mean "no limit" and collapse to nil, so the selection path can test
---`cap ~= nil` without re-reading the environment, and a record that never
---declared a cap stores no key at all. Integers are floored for the concurrency
---cap: a fractional 2.5 slots would read "third request allowed" one way and
---"two slots" the other, and "at most 2" is the safe reading of both.
---@param value any
---@param integer boolean @ true for a request count, false for watts
---@return number|nil limit
function _M.cap_limit(value, integer)
    local number = tonumber(value)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge or number <= 0 then
        return nil
    end
    if integer then
        return math.floor(number)
    end
    return number
end

---The router's own in-flight request count for one worker: the *pure* number,
---without the external GPU term that _M.load() adds. `lo:` is maintained by the
---hold/release pair in router.lua via shdict:incr, so it already spans every
---nginx process, and it is the same raw counter smg_worker_requests_active
---exports. The concurrency cap has to compare request counts, which is why it
---reads this key rather than load() (a mixed load would make a busy-but-not-full
---worker hit a request-count threshold it was never defined against).
---nil-safe: a worker with no key reads 0, exactly as load_with treats it.
---@param id string
---@return number inflight
---Touch the worker's activity clock (call on every completed request).
---The health sweep uses this to skip workers that just saw traffic.
---@param id string
function _M.touch_active(id)
    shdict():set(K_ACTIVE .. id, ngx.now() * 1000)
end

---How long since the worker last saw traffic, in ms. nil = never seen.
---@param id string
---@return number|nil
function _M.last_active_ms(id)
    local ts = shdict():get(K_ACTIVE .. id)
    if not ts or ts == 0 then return nil end
    return ngx.now() * 1000 - ts
end

function _M.inflight_requests(id)
    return shdict():get(K_LOAD .. id) or 0
end

---Hard capacity gate for one candidate worker.
---
---Root ruling 2026-10-01: a worker at its configured in-flight or power ceiling
---must leave the candidate set even when cache_aware's affinity tree would have
---kept it here. So this is an *exclusion*, evaluated where candidates are
---assembled, not another term in the ranking: the policies' own load escape
---(balance_abs/rel thresholds, power_of_two's low-load branch) turns "busier"
---into "less preferred", which under affinity keeps exactly the traffic this
---rule is meant to move. Absent = selectable; a returned table = exclude, with
---{reason="concurrency"|"power"} and the two numbers that decided it so the
---caller can count and log which kind fired.
---
---The two readings are different in kind on purpose:
---  * concurrency is this gateway's own counter, always known;
---  * power is an external sample, and *missing means unknown, not zero*. A
---    monitoring system that dies must cost accuracy, never capacity, so a nil
---    sample never excludes -- the same rule the load samples follow, and the
---    reason the key is TTL'd rather than last-value-wins.
---Both caps default to unlimited, and an uncapped worker costs zero shdict reads.
---@param record table @ static record (needs id; cap fields optional)
---@param d table|nil @ shared dict (resolved when omitted)
---@return table|nil exclusion @ nil = selectable
function _M.capacity_exclusion(record, d)
    if type(record) ~= "table" then
        return nil
    end
    local max_c = _M.cap_limit(record.max_concurrency)
    local max_w = _M.cap_limit(record.max_power_w)
    if max_c == nil and max_w == nil then
        return nil
    end
    d = d or shdict()
    local id = record.id
    if max_c ~= nil then
        local inflight = d:get(K_LOAD .. id) or 0
        if inflight >= max_c then
            return { reason = "concurrency", inflight = inflight,
                max_concurrency = max_c }
        end
    end
    if max_w ~= nil then
        local milli = d:get(K_POWER .. id)
        if milli ~= nil and milli >= max_w * 1000 then
            return { reason = "power", power_w = milli / 1000,
                max_power_w = max_w }
        end
    end
    return nil
end

---Store one raw watt sample for a worker (gpu_load's power pass is the only
---writer; unit tests may call it directly). Watts go in as milli-watts so gauge
---noise below one watt does not widen the key's type, and a negative or unusable
---reading is refused rather than clamped: "0 W" is a claim about the hardware
---that no exporter in this fleet can honestly make, and a stored 0 would read
---"far below any cap" for a worker whose exporter is misbehaving.
---@param id string
---@param watts number|nil
---@param ttl_secs number|nil
---@return boolean written
function _M.set_power_w(id, watts, ttl_secs)
    local number = tonumber(watts)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge or number < 0 then
        return false
    end
    local seconds = _M.stale_ttl(ttl_secs)
    local ok, err = shdict():set(K_POWER .. id,
        math.floor(number * 1000 + 0.5), seconds)
    if not ok then
        -- No-capacity-on-the-dict is the only way this fails and it is worth one
        -- line: the cap silently stops being enforceable for this worker until the
        -- sample TTLs out or the exporter refills it.
        if ngx and ngx.log then
            ngx.log(ngx.WARN, "luarouter: power sample for ", tostring(id),
                " not stored: ", tostring(err))
        end
        return false
    end
    return true
end

---The fresh watt sample for one worker: nil when there is none (an absent sample
---is *unknown*, and never collapses to 0 -- that distinction is what makes the
---power cap safe to leave switched on).
---@param id string
---@return number|nil watts
function _M.power_w(id)
    local milli = shdict():get(K_POWER .. id)
    if milli == nil then
        return nil
    end
    return milli / 1000
end

---Every fresh watt sample, keyed by worker id. The exporter and the UI pool
---table both want the whole table (N single lookups over a shared dict is the
---shape this module has already paid for in _M.records).
---@return table @ worker id -> watts
function _M.power_samples()
    local out = {}
    local d = shdict()
    if type(d.get_keys) ~= "function" then
        return out
    end
    for _, key in ipairs(d:get_keys(0)) do
        if type(key) == "string" and #key > #K_POWER
            and string.sub(key, 1, #K_POWER) == K_POWER then
            local value = d:get(key)
            if value ~= nil then
                out[string.sub(key, #K_POWER + 1)] = value / 1000
            end
        end
    end
    return out
end

---Drop the power sample (an operator override, a re-registration, or a test;
---TTL expiry is the ordinary life cycle).
---@param id string
function _M.clear_power_w(id)
    shdict():delete(K_POWER .. id)
end

---Normalized 0..1 -> milli integer, nil for anything unusable. NaN and the
---infinities answer nil: they compare false against everything, so storing one
---would strand a worker at whatever the previous sample said.
---@param load number|nil
---@return number|nil milli
function _M.to_milli(load)
    local number = tonumber(load)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge then
        return nil
    end
    if number < 0 then
        number = 0
    elseif number > 1 then
        number = 1
    end
    return math.floor(number * 1000 + 0.5)
end

---Staleness window of one sample. The TTL is what makes an expired reading stop
---being a load, so a caller that knows its interval always passes it; the default
---only covers a bare call from a test.
---@param ttl_secs number|nil
---@return number
function _M.stale_ttl(ttl_secs)
    local seconds = tonumber(ttl_secs)
    if seconds == nil or seconds <= 0 or seconds ~= seconds then
        seconds = 45
    end
    return math.min(math.max(seconds, 5), 3600)
end

---Whether any worker currently has an external sample (memoized per process).
---@return boolean
function _M.any_external_samples()
    local now = ngx.now()
    if now - memo_checked_at >= MEMO_SECS then
        memo_checked_at = now
        memo_any = shdict():get(K_XANY) ~= nil
    end
    return memo_any
end

---Publish the shared flag with the TTL of the sample that justified it. The TTL is
---what retires the flag when the source stops: an expired key sends the readers back
---to the in-flight counter without anything having to clean up, and a load source
---that never stores a sample never writes this key at all.
---@param ttl_secs number
---@return boolean written
function _M.flag_external_samples(ttl_secs)
    if not shdict():set(K_XANY, 1, _M.stale_ttl(ttl_secs)) then
        return false
    end
    -- The writer sees its own flag immediately: a policy in this process should not
    -- wait out the memo for the sample it just stored.
    memo_any = true
    memo_checked_at = ngx.now()
    return true
end

---Forget the flag as well as the samples (an operator override / a test).
function _M.clear_external_samples_flag()
    shdict():delete(K_XANY)
    memo_any = false
    memo_checked_at = -MEMO_SECS
end

---Publish the weight of a fully busy worker. gpu_load.run_pass calls this on every
---tick, so an edited SMG_LOAD_SCALE lands on the next pass without a reload.
---@param scale number|nil
---@return number applied
function _M.set_load_scale(scale)
    local number = tonumber(scale)
    if number == nil or number ~= number or number <= 0 then
        return load_scale
    end
    load_scale = number
    load_scale_from_cfg = true   -- an explicit override outranks the config value
    return load_scale
end

---Current weight of a fully busy worker.
---@return number
function _M.load_scale()
    return load_scale
end

---The weight actually in force: an explicit set_load_scale wins, otherwise the
---env-published SMG_LOAD_SCALE from the config snapshot (identical in every process).
---
---The load timer that would otherwise publish this runs in worker 0 only, so a
---Lua-local written from the pass would leave the other processes on the default and
---make power_of_two rank the same pair of workers differently depending on which
---process answered. config.load_scale is read lazily -- one table field on the first
---sampled request -- and only superseded by an explicit set_load_scale.
---@return number
function _M.current_load_scale()
    if not load_scale_from_cfg then
        load_scale_from_cfg = true
        local ok_cfg, outer = pcall(require, "resty.luarouter")
        if ok_cfg and type(outer) == "table" and type(outer.config) == "function" then
            local ok, conf = pcall(outer.config)
            local configured = ok and type(conf) == "table"
                and tonumber(conf.load_scale) or nil
            if configured and configured > 0 then
                load_scale = configured
            end
        end
    end
    return load_scale
end

---@param id string
---@param delta number
---@return number @ load after the change
function _M.change_load(id, delta)
    local d = shdict()
    local value, err = d:incr(K_LOAD .. id, delta, 0)
    if not value then
        d:set(K_LOAD .. id, 0)
        value = 0
    end
    if value < 0 then
        d:set(K_LOAD .. id, 0)
        return 0
    end
    return value
end

---Resilience state, used by hb.lua and the metrics exporter.
---@param id string
---@return table
function _M.cb_state(id)
    local d = shdict()
    local state = d:get(K_CBSTATE .. id) or _M.CB_CLOSED
    return {
        state = state,
        state_name = CB_STATE_NAME[state + 1] or "closed",
        consecutive_failures = d:get(K_CBF .. id) or 0,
        consecutive_successes = d:get(K_CBS .. id) or 0,
        opened_at_ms = d:get(K_CBO .. id) or 0,
        healthy = (d:get(K_HEALTH .. id) or 0) == 1,
        health_failures = d:get(K_HFAIL .. id) or 0,
        health_successes = d:get(K_HSUCC .. id) or 0,
        -- Deliberately the raw in-flight counter, not _M.load(): this table feeds
        -- smg_worker_requests_active, whose Rust counterpart counts running requests
        -- per worker. Folding a GPU sample in here would make the gauge disagree
        -- with the router's own concurrency counters for no scheduling benefit.
        load = d:get(K_LOAD .. id) or 0,
    }
end

---@param id string
function _M.set_cb_state(id, state, opened_at_ms)
    local d = shdict()
    d:set(K_CBSTATE .. id, state)
    if opened_at_ms then
        d:set(K_CBO .. id, opened_at_ms)
    end
end

---Accumulate one breaker outcome atomically.
---
---The counters mean "consecutive", so the other side is zeroed; the charged side
---uses shdict:incr(), which is the only cross-process-safe way to add one. A
---get()+set() pair loses updates when several nginx workers charge the same
---worker in the same window (four processes reading failures=2 all write 3),
---which delays the open transition far past cb_failure_threshold.
---@param id string
---@param success boolean
---@return number failures @ count after the update
---@return number successes @ count after the update
function _M.charge_cb(id, success)
    local d = shdict()
    if success then
        d:set(K_CBF .. id, 0)
        local value, err = d:incr(K_CBS .. id, 1, 0)
        if not value then
            d:set(K_CBS .. id, 1)
            value = 1
        end
        return 0, value
    end
    d:set(K_CBS .. id, 0)
    local value, err = d:incr(K_CBF .. id, 1, 0)
    if not value then
        d:set(K_CBF .. id, 1)
        value = 1
    end
    return value, 0
end

---Breaker state flip, re-checked under the registry lock.
---
---Every process that crosses a threshold calls this; the lock plus the
---expected-state check makes exactly one of them perform the transition, so the
---transition metric and the log line are not counted per process. Closing also
---clears both counters (an open circuit keeps its failure count for the metrics
---page, which is what the Rust gateway shows too).
---@param id string
---@param expect number @ state the caller observed
---@param next_state number
---@param opened_at_ms number|nil @ stamped when the circuit opens
---@return boolean changed @ true when this caller performed the flip
function _M.flip_cb(id, expect, next_state, opened_at_ms)
    local changed = false
    with_lock(function()
        local d = shdict()
        if (d:get(K_CBSTATE .. id) or _M.CB_CLOSED) ~= expect then
            return
        end
        d:set(K_CBSTATE .. id, next_state)
        if opened_at_ms then
            d:set(K_CBO .. id, opened_at_ms)
        end
        if next_state == _M.CB_CLOSED then
            d:set(K_CBF .. id, 0)
            d:set(K_CBS .. id, 0)
        end
        changed = true
    end)
    return changed
end

---@param id string
function _M.set_cb_counters(id, failures, successes)
    local d = shdict()
    d:set(K_CBF .. id, failures)
    d:set(K_CBS .. id, successes)
end

---@param id string
---@param failures number|nil @ nil keeps the stored value
---@param successes number|nil
function _M.set_health_counters(id, failures, successes)
    local d = shdict()
    if failures then
        d:set(K_HFAIL .. id, failures)
    end
    if successes then
        d:set(K_HSUCC .. id, successes)
    end
end

-- ---------------------------------------------------------- metadata discovery

---Merge discovered fields into the stored record.
---@param id string
---@param patch table @ fields to overwrite (model_id, labels)
---@param opts table|nil @{labels_replace=true: the labels map replaces the
---            stored one wholesale instead of merging; config_store's upstream
---            reconcile wants the document to be the single source of truth}
local function patch_record(id, patch, opts)
    local d = shdict()
    local raw = d:get(K_WORKER .. id)
    if not raw then
        return nil
    end
    local record = json_decode(raw)
    if type(record) ~= "table" then
        return nil
    end
    local changed = false
    -- models is applied after every other key, on purpose: merge_models decides
    -- "replace or fold" by comparing the incoming head against the record's *final*
    -- model_id, and pairs() has no order. Left unordered, a config row that renames a
    -- worker A -> C sometimes folds the old list back in ({"C","A","B"}) and sometimes
    -- replaces it, so the same declaration would converge differently per tick.
    local models_patch, models_seen = nil, false
    for key, value in pairs(patch) do
        if key == "models" then
            models_patch, models_seen = value, true
        elseif key == "labels" then
            if opts and opts.labels_replace then
                local next_labels = {}
                for name, label in pairs(value) do
                    next_labels[name] = label
                end
                record.labels = next_labels
                changed = true
            else
                record.labels = record.labels or {}
                for name, label in pairs(value) do
                    if record.labels[name] ~= label then
                        record.labels[name] = label
                        changed = true
                    end
                end
            end
        elseif key == "model_id" and record.model_id ~= value then
            -- 换了主模型就是换了一次"这个实例到底是什么"的陈述：之前那份广告列表是
            -- 围绕旧身份学到的，不能再当作引擎亲口答过的凭证（models_verified 的含义见
            -- worker_serves_model）。清掉标记后，下一轮 /v1/models 观测会重新盖章。
            record.model_id = value
            record.models_verified = false
            changed = true
        elseif record[key] ~= value then
            record[key] = value
            changed = true
        end
    end
    if models_seen then
        -- Wholesale assignment would be wrong here: half the writers only know the
        -- single model they were configured with (a config-declared upstream names one
        -- model_id), while the probe path knows the full advertised list. Each has to
        -- be able to write without erasing what the other learned, so the fold lives in
        -- merge_models and every caller shares it.
        -- Two stances, told apart by the caller: an *observation* (the worker itself
        -- answered /v1/models) is authoritative and replaces the list; a *declaration
        -- or config reconcile* only states what it knows and folds into the stored list,
        -- so naming one model never deletes what a sweep already saw.
        local next_models = merge_models(record, models_patch,
            { replace = (opts and opts.models_replace) and true or false })
        if next_models ~= record.models then
            record.models = next_models
            changed = true
        end
        -- 只有"观测"才给这份列表盖章：opts.models_replace 是调用方在说"这些名字是
        -- 对方 /v1/models 亲口答的"（refresh_models、metadata discovery 两条路径）。
        -- 注册体与 config 声明行只是人在打字，不能凭它们宣称"这个实例就是不服务
        -- 模型 M"，否则一条欠配置的声明会让一个本来能答上请求的实例被选路判掉。
        if opts and opts.models_replace and next_models ~= nil then
            if not record.models_verified then
                record.models_verified = true
                changed = true
            end
        end
    end
    if not changed then
        return record
    end
    local encoded = json_encode(record)
    if encoded then
        d:set(K_WORKER .. id, encoded)
        -- The pool flag is derived from the record, so any write that can reach
        -- worker_type/connection_mode has to recompute it. Kept here rather than
        -- at each call site (discovery and PUT) so a new writer cannot leave it
        -- stale.
        d:set(K_HSEL .. id, _M.record_http_selectable(record) and 1 or 0)
        mesh_mirror(id)
    end
    return record
end

--- Ask one worker what it advertises, as a normalized id list.
---
--- Shared by the metadata-discovery fallback and by the coverage refresh below so
--- both read /v1/models the same way (data[].id, tolerate a bare-string data[]).
---@param url string
---@param timeout_ms number
---@param headers table|nil
---@return table|nil @ array of ids, or nil when the endpoint did not answer
function _M.probe_advertised_models(url, timeout_ms, headers)
    local hb = require "resty.luarouter.hb"
    local status, body = hb.http_get(url .. "/v1/models", timeout_ms, headers)
    if status ~= 200 then
        return nil
    end
    local listing = json_decode(body or "")
    local data = type(listing) == "table" and listing.data or nil
    if type(data) ~= "table" then
        return nil
    end
    local ids = {}
    for j = 1, #data do
        ids[j] = type(data[j]) == "table" and data[j].id or data[j]
    end
    return norm_models(ids, nil)
end

--- How many coverage probes one worker may spend before we believe its list is final.
--- Same order as the metadata-discovery ceiling: a genuinely single-model engine
--- answers with one id every time, so without a ceiling this would be one wasted
--- GET per sweep per worker for the life of the deployment.
local MAX_MPROBE = 20
_M.MAX_MPROBE = MAX_MPROBE

--- Re-ask window for the coverage probe, in seconds. Exported so a test can shorten it.
local MODELS_REFRESH_COOLDOWN_SECS = 300
_M.MODELS_REFRESH_COOLDOWN_SECS = MODELS_REFRESH_COOLDOWN_SECS

--- Learn the advertised model list for one worker, on the health sweep clock.
---
--- Called from discover(), i.e. only for a worker the sweep already reached, so it
--- never blocks a request. An answer from the engine itself *replaces* the stored
--- list (models_replace): it is the only source that states coverage, so a model the
--- engine dropped must be able to leave our claim. Two budgets keep the steady state
--- cheap while keeping that claim honest:
---   * thin list (absent, or the single name a registration left behind) -- ask on
---     every sweep up to MAX_MPROBE times, because filling this in is what makes a
---     per-candidate binding verifiable at all;
---   * complete list -- re-ask once per MODELS_REFRESH_COOLDOWN_SECS window, which is
---     what stops an engine reloaded behind the same endpoint from being advertised
---     forever by a row nobody refreshed.
---@param record table
---@param cfg table
---@param opts table|nil @{force=true: skip both budgets (admin refresh, tests)}
---@return table|nil updated
function _M.refresh_models(record, cfg, opts)
    local d = shdict()
    if not (opts and opts.force) then
        local fresh = d:get(K_MPROBE_OK .. record.id) ~= nil
        if needs_models_refresh(record) then
            -- Thin list: bounded by the attempt ceiling so a silent engine goes
            -- quiet instead of being dialed on every sweep forever.
            if fresh then
                return nil
            end
            local attempts = d:incr(K_MPROBE .. record.id, 1, 0) or 1
            if attempts > MAX_MPROBE then
                return nil
            end
        elseif fresh then
            -- Complete list inside the window: nothing to learn right now.
            return nil
        end
    end
    local timeout_ms = cfg.health_check_timeout_secs * 1000
    local headers = record.api_key and { ["Authorization"] = "Bearer " .. record.api_key }
        or nil
    local list = _M.probe_advertised_models(record.url, timeout_ms, headers)
    if not list then
        -- No answer, or an engine without the endpoint: leave the coverage as it is.
        -- worker_serves_model answers nil for "never learned", which the caller treats
        -- as usable, so a failed probe costs nothing beyond the budgets above.
        return nil
    end
    -- One stamp serves both budgets: a worker that answered gets its next look when
    -- the window lapses, and a thin list that finally answered stops spending attempts.
    d:set(K_MPROBE_OK .. record.id, 1, MODELS_REFRESH_COOLDOWN_SECS)
    return patch_record(record.id, { models = list }, { models_replace = true })
end

-- ------------------------------------------------------------------ PUT update

-- Fields PUT /workers/{id} may change. Mirrors the Rust update_worker_properties
-- step, which only touches the scheduling knobs (priority/cost/labels) and the
-- per-worker health-check tuning; url/model_id/connection identity is immutable
-- and any other body member is ignored rather than rejected.
local UPDATE_NUMBER_FIELDS = {
    "priority", "cost",
    -- Capacity caps ride the same PUT path as the scheduling knobs (root ruling
    -- 2026-10-01), including the config-declaration reconcile's patch. Their
    -- *meaning* is decided by cap_limit at read time, so a PUT of 0 (or a
    -- negative, or a null the caller meant as "clear it") all land on
    -- "unlimited" instead of needing a bespoke validator here; the contract's
    -- non-numeric-400 rule applies unchanged.
    "max_concurrency", "max_power_w",
    "health_check_timeout_secs", "health_check_interval_secs",
    "health_success_threshold", "health_failure_threshold",
}
local UPDATE_BOOL_FIELDS = { "disable_health_check" }

---Apply a partial update to one stored worker record.
---@param worker_id string
---@param patch table @ decoded PUT body
---@return table|nil result @ {worker_id, url}
---@return string|nil err
---@return string|nil kind @ "validation" for client-side rejections (400)
function _M.update(worker_id, patch)
    if type(patch) ~= "table" then
        return nil, "worker update must be a JSON object", "validation"
    end
    local id, perr = _M.parse_worker_id(worker_id)
    if not id then
        return nil, perr, "validation"
    end
    local d = shdict()
    if not d:get(K_WORKER .. id) then
        return nil, "Worker " .. id .. " not found", "not_found"
    end

    local changes = {}
    for i = 1, #UPDATE_NUMBER_FIELDS do
        local field = UPDATE_NUMBER_FIELDS[i]
        local value = patch[field]
        if value ~= nil and value ~= cjson.null then
            local number = tonumber(value)
            if not number then
                return nil, string.format("field '%s' must be a number", field),
                    "validation"
            end
            changes[field] = number
        end
    end
    for i = 1, #UPDATE_BOOL_FIELDS do
        local field = UPDATE_BOOL_FIELDS[i]
        local value = patch[field]
        if value ~= nil and value ~= cjson.null then
            if type(value) ~= "boolean" then
                return nil, string.format("field '%s' must be a boolean", field),
                    "validation"
            end
            changes[field] = value
        end
    end
    if patch.labels ~= nil and patch.labels ~= cjson.null then
        if type(patch.labels) ~= "table" then
            return nil, "field 'labels' must be a JSON object", "validation"
        end
        -- patch_record merges labels (discovery writes the same map), so a PUT
        -- that only names one label keeps the rest.
        changes.labels = patch.labels
    end
    if patch.api_key ~= nil and patch.api_key ~= cjson.null then
        -- Non-string api_key stays ignored (Rust-style: unknown shapes of a
        -- known field are dropped, not rejected; the contract only pins the
        -- null / "" / non-empty tri-state). Empty string clears the key
        -- (doc/gap-virtual-models.md 3.4), stored as false so every
        -- `worker.api_key and ...` reader skips the Authorization header and
        -- patch_record's pairs() can still see the write.
        if type(patch.api_key) == "string" then
            changes.api_key = (patch.api_key ~= "") and patch.api_key or false
        end
    end

    -- Config-declared upstreams are owned by config_store: the reconcile in
    -- gap-virtual-models 3.1 re-applies model_id and *replaces* the label map
    -- from the document. Rust's identity-immutability parity rule stays intact
    -- for every other record (a PUT naming model_id on a dynamic worker keeps
    -- being ignored, the contract pins that).
    local labels_replace
    local current = json_decode(d:get(K_WORKER .. id))
    if type(current) == "table" and current.discovery == "config" then
        if type(patch.model_id) == "string" and patch.model_id ~= "" then
            changes.model_id = patch.model_id
        end
        -- The advertised list is part of what a config row declares (a row may name
        -- several models for one endpoint), so the config layer is allowed to write
        -- it. A dynamic worker keeps the probe's answer as its own -- a PUT naming
        -- models on a watcher-owned row is dropped by the same identity rule that
        -- already ignores model_id there, which keeps a hand-typed override from
        -- outliving the next sweep that knows better.
        -- patch_record folds rather than replaces (see merge_models), so declaring
        -- one model here cannot delete what the probe already learned.
        if patch.models ~= nil and patch.models ~= cjson.null then
            if type(patch.models) ~= "table" then
                return nil, "field 'models' must be a JSON array", "validation"
            end
            changes.models = norm_models(patch.models, patch.model_id)
        elseif changes.model_id then
            changes.models = norm_models(nil, changes.model_id)
        end
        labels_replace = true
    end

    local url = d:get(K_IDURL .. id)
    local ok, lerr = with_lock(function()
        if not patch_record(id, changes, { labels_replace = labels_replace }) then
            error("worker " .. id .. " disappeared while updating")
        end
    end)
    if not ok then
        return nil, lerr
    end
    return { worker_id = id, url = url }
end

---Query the worker for the model it serves, the way the Rust worker workflow's
---discover_metadata step does: /model_info and /server_info give the identity
---labels, /v1/models is the fallback, and model_id falls back through
---served_model_name then model_path.
---
---Returns nil once the worker has a real model id, so the caller can stop asking.
---@param record table
---@param cfg table
---@return table|nil updated @ record after the update
function _M.discover(record, cfg)
    local d = shdict()

    -- DP expansion comes first, because it can replace the record this function
    -- was handed: a data-parallel engine has to become dp_size entries before
    -- per-rank metadata makes any sense. Ranks carry dp_base_url and are never
    -- expanded again; a base that already decided (dp_size set, including the
    -- settled dp_size == 1) is skipped, so this costs one probe per worker.
    --
    -- Only "expanded" short-circuits: when the engine says dp_size <= 1, or when
    -- /server_info has not answered yet, the ordinary metadata path below still
    -- runs against the base worker, which is reachable and useful on its own.
    if cfg and cfg.dp_aware and not record.dp_base_url and not record.dp_size
        and not _M.rank_of(record.url) then
        if _M.expand_dp(record, cfg) == "expanded" then
            return nil
        end
    end

    if record.model_id and record.model_id ~= "unknown" then
        -- A worker that already has a primary model is normally finished with this
        -- path, but its advertised *coverage* may still be a single name: the watcher
        -- registers rows from its own probe and reports only one model, and a record
        -- created from a one-model config row is in the same shape. Without the full
        -- list here, a virtual-model binding naming that row's second model would be
        -- answered `false` ("it advertised a list, and M is not in it") and the request
        -- would be filtered away from an engine that can serve it -- the exact failure
        -- mode the multi-binding feature is supposed to remove. Bounded by the same
        -- attempt ceiling as the unknown-model path so a silent engine costs 20 probes
        -- per worker and then stops; one /v1/models call per sweep for a talking one.
        -- One decision point: refresh_models itself decides whether this worker is
        -- worth asking (thin list on the attempt ceiling, complete list on the
        -- cooldown window), so discover does not pre-empt it with a second rule.
        return _M.refresh_models(record, cfg)
    end
    local attempts = d:incr(K_DISC .. record.id, 1, 0) or 1
    if attempts > 20 then
        return nil
    end

    local hb = require "resty.luarouter.hb"
    local timeout_ms = cfg.health_check_timeout_secs * 1000
    local labels = {}
    -- Declared before the probes so the /v1/models branch (nested two conditionals
    -- deep) can hand its full answer to the write at the bottom without shadowing.
    local discovered_models
    local present = function(value)
        if type(value) == "string" and value ~= "" then
            return value
        end
        if type(value) == "number" then
            return tostring(value)
        end
        return nil
    end

    local info_status, info_body = hb.http_get(record.url .. "/model_info", timeout_ms)
    if info_status == 200 then
        local model_info = json_decode(info_body)
        if type(model_info) == "table" then
            labels.model_path = present(model_info.model_path)
            labels.served_model_name = present(model_info.served_model_name)
        end
    end

    local server_status, server_body = hb.http_get(record.url .. "/server_info", timeout_ms)
    if server_status == 200 then
        local server_info = json_decode(server_body)
        if type(server_info) == "table" then
            labels.model_path = labels.model_path or present(server_info.model_path)
            labels.served_model_name = labels.served_model_name
                or present(server_info.served_model_name)
            labels.tp_size = present(server_info.tp_size)
            labels.dp_size = present(server_info.dp_size)
        end
    end

    if not labels.model_path and not labels.served_model_name then
        -- llama.cpp workers expose neither: ask the OpenAI discovery endpoint.
        discovered_models = _M.probe_advertised_models(record.url, timeout_ms)
        if discovered_models then
            labels.served_model_name = present(discovered_models[1])
        end
    end

    local model_id = labels.served_model_name or labels.model_path
    if not model_id then
        -- Nothing discovered yet; leave it unknown so the next sweep retries.
        return nil
    end

    local merged = {}
    for key, value in pairs(labels) do
        if value then
            merged[key] = value
        end
    end
    -- models rides the same patch: patch_record folds it (merge_models) rather than
    -- overwriting, so a sweep that only ever sees one name cannot shrink a list the
    -- watcher already reported.
    -- The list rides the same patch as an observation: the worker itself named these
    -- models, so it replaces whatever was stored (a stale entry from an engine that
    -- has since been reloaded with a different model set goes away on the next sweep
    -- rather than lingering as a coverage claim).
    return patch_record(record.id, { model_id = model_id, labels = merged,
        models = discovered_models }, { models_replace = true })
end

-- ---------------------------------------------------------- DP-aware ranks

-- The three pure decisions below lived in the Kubernetes poller module and
-- moved here when it was removed (doc/scope-trim.md). The DP expansion is the
-- scheduler's own feature: a data-parallel engine is stored as one registry
-- entry per rank regardless of how the worker was discovered.

-- A worker that never answers /server_info stays a single-entry worker after
-- this many probes. The metadata-discovery attempt ceiling in discover() is the
-- same order (20), so the two bounded retries end together.
local MAX_DP_ATTEMPTS = 20
_M.MAX_DP_ATTEMPTS = MAX_DP_ATTEMPTS

---Read dp_size out of a decoded /server_info body.
---
---Both spellings seen in the wild are accepted: the sglang engine reports
---dp_size at the top level, and some builds nest it under "server_args".
---@param info table|nil
---@return number|nil dp_size
local function dp_size_from_server_info(info)
    if type(info) ~= "table" then
        return nil
    end
    local raw = info.dp_size
    if raw == nil and type(info.server_args) == "table" then
        raw = info.server_args.dp_size
    end
    local n = tonumber(raw)
    if not n or n ~= math.floor(n) or n < 1 then
        return nil
    end
    return n
end

---Decide what one DP probe implies for the registry.
---
---This function only classifies so the decision is unit-testable without a
---shared dict; the caller (expand_dp) owns the writes.
---@param dp_size number|nil @ parsed from /server_info, nil when unavailable
---@param attempts number @ probes already spent on this record
---@return string action @ "expand" | "single" | "retry" | "give_up"
---@return number|nil dp_size @ effective fan-out width for "expand"
local function expansion_plan(dp_size, attempts)
    if not dp_size then
        -- No answer. Retry a bounded number of times (the engine may still be
        -- loading), then settle on the base worker as a single entry.
        if (attempts or 0) >= MAX_DP_ATTEMPTS then
            return "give_up", 1
        end
        return "retry", nil
    end
    if dp_size <= 1 then
        return "single", 1
    end
    return "expand", dp_size
end

---Build the registration requests for ranks 0..dp_size-1 of one base worker.
---
---Everything the scheduler needs to treat a rank like the engine it stands for
---is copied from the base record (model id, priority, cost, api key, health
---tuning, labels); the rank identity goes in dp_rank/dp_size/dp_base_url plus a
---dp_aware marker so a later teardown can find them again.
---@param base table @ stored record for the base url
---@param dp_size number
---@param meta table|nil @ {model_id, labels} learned from the probe body
---@return table[] @ one POST /workers-shaped request per rank
local function expansion_requests(base, dp_size, meta)
    meta = meta or {}
    local out = {}
    for rank = 0, (dp_size or 1) - 1 do
        local labels = {}
        for k, v in pairs(base.labels or {}) do
            labels[k] = v
        end
        for k, v in pairs(meta.labels or {}) do
            labels[k] = v
        end
        labels.dp_rank = tostring(rank)
        labels.dp_size = tostring(dp_size)
        out[#out + 1] = {
            url = base.url .. "@" .. rank,
            -- The probe that revealed the ranks usually carries the model too, so
            -- a rank is routable on the sweep that created it rather than having to
            -- re-discover /model_info four times over.
            model_id = meta.model_id or base.model_id,
            -- Ranks inherit the base engine's advertised coverage: every rank of a
            -- data-parallel engine serves the same model set, and a rank that lost the
            -- list would read as "we never learned what it serves" to the multi-binding
            -- filter (nil) or, worse, be filtered out by a binding naming its second
            -- model. meta.model_id leads so a probe that just corrected the name also
            -- resets the coverage rather than folding a stale second model in.
            -- The base list is inherited wholesale (norm_models puts the head first, so
            -- the name the /server_info probe just reported leads it), which is what a
            -- rank of a data-parallel engine means: every rank serves the same model
            -- set. A rank that lost the list would read as never-learned to the
            -- multi-binding filter, and a binding naming its second model would filter
            -- the rank out of a pool that can actually serve it.
            models = norm_models({ meta.model_id or base.model_id }, base.models),
            priority = base.priority,
            cost = base.cost,
            api_key = base.api_key,
            labels = labels,
            disable_health_check = base.disable_health_check or false,
            health_check_timeout_secs = base.health_check_timeout_secs,
            health_check_interval_secs = base.health_check_interval_secs,
            health_success_threshold = base.health_success_threshold,
            health_failure_threshold = base.health_failure_threshold,
            dp_rank = rank,
            dp_size = dp_size,
            dp_base_url = base.url,
            dp_aware = true,
            -- Inherit the source name so a rank stays attributed to whatever
            -- registered its base (there is no pod reconcile any more; the
            -- field is provenance only).
            discovery = base.discovery,
        }
    end
    return out
end

---Expand one base worker into its data-parallel ranks.
---
---Called from _M.discover() (i.e. from the health sweep of a reachable worker),
---so it never blocks a request. The probe is /server_info with /get_server_info
---as the older spelling; both are the endpoints the Rust gateway reads dp_size
---from. A rank is registered as "<base>@<rank>": a distinct id, distinct health
---counters, distinct load and circuit breaker, and a policy tenant of its own -
---which is the whole point, since the engine schedules each rank independently.
---
---Ranks start unhealthy like any fresh worker and are brought up by the next
---sweep; that sweep is also what learns their metadata. The base entry is then
---removed, so /workers shows exactly the dp_size ranks the Rust gateway would.
---@param record table @ base worker record (no dp_base_url)
---@param cfg table
---@return string action @ "expanded" | "settled" | "retry"
function _M.expand_dp(record, cfg)
    local d = shdict()
    local attempts = d:incr(K_DPROBE .. record.id, 1, 0) or 1

    local hb = require "resty.luarouter.hb"
    local timeout_ms = cfg.health_check_timeout_secs * 1000
    local headers = record.api_key and { ["Authorization"] = "Bearer " .. record.api_key }
        or nil
    local dp_size, info
    for _, endpoint in ipairs({ "/server_info", "/get_server_info" }) do
        local status, body = hb.http_get(record.url .. endpoint, timeout_ms, headers)
        if status == 200 then
            local decoded = json_decode(body)
            dp_size = dp_size_from_server_info(decoded)
            if dp_size then
                info = decoded
                break
            end
        end
    end

    -- The probe that reveals the ranks usually reveals the model as well, so hand
    -- both to the rank records: otherwise every rank has to re-run metadata
    -- discovery, and until it does the engine is unroutable even though the base
    -- worker already knew its model id.
    local meta
    if type(info) == "table" then
        local present = function(value)
            if type(value) == "string" and value ~= "" then
                return value
            end
            if type(value) == "number" then
                return tostring(value)
            end
            return nil
        end
        local labels = {}
        labels.model_path = present(info.model_path)
        labels.served_model_name = present(info.served_model_name)
        labels.tp_size = present(info.tp_size)
        labels.dp_size = present(info.dp_size)
        local model_id = labels.served_model_name or labels.model_path
        if model_id or record.model_id ~= "unknown" then
            meta = { model_id = model_id or record.model_id, labels = labels }
        end
    end

    local action, width = expansion_plan(dp_size, attempts)
    if action == "retry" then
        -- Keep asking (bounded): a loading engine answers /health before it
        -- answers /server_info, and expanding at the wrong width is worse than
        -- waiting. Until then the base worker carries traffic as a single entry.
        return "retry"
    end
    if action == "give_up" then
        ngx.log(ngx.WARN, "luarouter: no usable dp_size from ", record.url,
            " after ", attempts, " probes; keeping it as a single worker")
    end

    if (width or 1) <= 1 then
        -- Settled: record the decision so neither this worker nor the sweep
        -- retries /server_info for DP again.
        patch_record(record.id, { dp_size = 1 })
        return "settled"
    end

    local requests = expansion_requests(record, width, meta)
    local added = 0
    for i = 1, #requests do
        local _, err = _M.add(requests[i], cfg)
        if err then
            -- A rank that already exists means a previous attempt got part-way:
            -- treat it as present and let the sweep finish the job next time.
            ngx.log(ngx.WARN, "luarouter: dp rank ", requests[i].url,
                " not registered: ", err)
        else
            added = added + 1
        end
    end
    if added == 0 then
        return "retry"
    end

    -- The base entry would be a phantom candidate taking selections to a listener
    -- that is one of the ranks, so it goes away once the ranks exist.
    local _, remove_err = _M.remove(record.id)
    if remove_err then
        ngx.log(ngx.ERR, "luarouter: expanded ", record.url, " into ", added,
            " ranks but could not remove the base entry: ", remove_err)
    end

    -- Same signal a control-plane write gives: the worker set changed, so a
    -- stateful policy has to re-seed rather than keep a tree of the old list.
    local ok, policy = pcall(require, "resty.luarouter.policy")
    if ok and policy and policy.bump_generation then
        policy.bump_generation()
    end

    ngx.log(ngx.NOTICE, "luarouter: expanded ", record.url, " into ", added,
        " data-parallel ranks (SMG_DP_AWARE)")
    return "expanded"
end

-- ------------------------------------------------------------------ job queue

---@param url string
---@param job_type string
---@param status string @ pending | processing | completed | failed
---@param message string|nil
function _M.set_job(url, job_type, status, message)
    local job = {
        job_type = job_type,
        worker_url = url,
        status = status,
        message = message or cjson.null,
        timestamp = ngx.time(),
    }
    local encoded = json_encode(job)
    if encoded then
        shdict():set(K_JOB .. url, encoded, 600)
    end
end

---@param url string
---@return table|nil
function _M.get_job(url)
    local raw = shdict():get(K_JOB .. url)
    if not raw then
        return nil
    end
    local job = json_decode(raw)
    if type(job) ~= "table" then
        return nil
    end
    return job
end

---@param url string
function _M.clear_job(url)
    shdict():delete(K_JOB .. url)
end

-- ------------------------------------------------------------------ bootstrap

---Register the SMG_WORKER_URLS seed list (idempotent).
---@param cfg table
---@return number @ registered count
function _M.bootstrap(cfg)
    local count = 0
    local urls = cfg.worker_urls or {}
    for i = 1, #urls do
        local _, err = _M.add({ url = urls[i] }, cfg)
        if err then
            ngx.log(ngx.ERR, "luarouter: seed worker ", urls[i], " failed: ", err)
        else
            count = count + 1
        end
    end
    return count
end

return _M
