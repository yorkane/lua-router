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
local K_URL2ID = "url:"  -- url -> id
local K_IDURL  = "u:"    -- id -> url (cheap label lookup for metrics)
local K_JOB = "job:"     -- url -> JobStatus JSON
local K_DISC = "disc:"   -- id -> metadata discovery attempts
local K_DPROBE = "dpr:"  -- id -> /server_info probes spent on DP expansion
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
---the whole gateway process). doc/gap-http-semantics.md §5 spells out the
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
-- deviation from Rust that the contract suite pins (doc/impl-core.md deviation 3).
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
            priority = tonumber(req.priority) or 50,
            cost = tonumber(req.cost) or 1.0,
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
        -- A re-registration is a new engine behind the url: whatever the previous
        -- owner's GPU was doing has no right to describe this one, so both
        -- external channels start empty (the load source refills them on its tick).
        d:delete(K_XLOAD .. id)
        d:delete(K_SLOAD .. id)
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
                                 K_DISC, K_DPROBE, K_HSEL }) do
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
local function patch_record(id, patch)
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
    for key, value in pairs(patch) do
        if key == "labels" then
            record.labels = record.labels or {}
            for name, label in pairs(value) do
                if record.labels[name] ~= label then
                    record.labels[name] = label
                    changed = true
                end
            end
        elseif record[key] ~= value then
            record[key] = value
            changed = true
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

-- ------------------------------------------------------------------ PUT update

-- Fields PUT /workers/{id} may change. Mirrors the Rust update_worker_properties
-- step, which only touches the scheduling knobs (priority/cost/labels) and the
-- per-worker health-check tuning; url/model_id/connection identity is immutable
-- and any other body member is ignored rather than rejected.
local UPDATE_NUMBER_FIELDS = {
    "priority", "cost",
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
    if type(patch.api_key) == "string" then
        changes.api_key = patch.api_key
    end

    local url = d:get(K_IDURL .. id)
    local ok, lerr = with_lock(function()
        if not patch_record(id, changes) then
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
        return nil
    end
    local attempts = d:incr(K_DISC .. record.id, 1, 0) or 1
    if attempts > 20 then
        return nil
    end

    local hb = require "resty.luarouter.hb"
    local timeout_ms = cfg.health_check_timeout_secs * 1000
    local labels = {}
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
        local models_status, models_body = hb.http_get(record.url .. "/v1/models", timeout_ms)
        if models_status == 200 then
            local listing = json_decode(models_body)
            local data = type(listing) == "table" and listing.data or nil
            if type(data) == "table" and type(data[1]) == "table" then
                labels.served_model_name = present(data[1].id)
            end
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
    return patch_record(record.id, { model_id = model_id, labels = merged })
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
