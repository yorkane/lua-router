-- Prefill/Decode (PD) disaggregation layer for the Lua router.
--
-- Parity target: gateway/src/routers/http/pd_router.rs plus
-- src/core/{worker.rs,worker_registry.rs} and src/policies/registry.rs:
--   * a worker is Regular, Prefill { bootstrap_port } or Decode
--     (core/worker.rs WorkerType); worker_registry.rs keeps one list per type
--     (get_prefill_workers / get_decode_workers)
--   * PD selection picks *two* workers, one per pool, each through its own
--     policy instance (policies/registry.rs set_prefill_policy /
--     set_decode_policy, pd_router.rs select_pd_pair)
--   * the prefill worker's bootstrap address is injected into the *shared*
--     request body -- bootstrap_host / bootstrap_port / bootstrap_room, arrays
--     when the request is a batch (pd_router.rs inject_bootstrap_into_value)
--   * the decode copy additionally carries disagg_prefill_dp_rank when the
--     prefill worker is DP-aware (inject_prefill_dp_rank_for_decode)
--   * /readiness in PD mode requires one healthy worker in *each* pool
--     (server.rs readiness: has_prefill && has_decode)
--   * a failed prefill dooms the paired decode request, so the prefill outcome
--     decides the breaker charge and decode is not charged for it
--     (execute_dual_dispatch_internal)
--
-- Pool state deliberately reuses registry's existing per-worker keys (health,
-- circuit breaker, load) rather than inventing a parallel store: a prefill
-- worker and a regular worker are indistinguishable to the checker, only the
-- *candidate filter* changes. See doc/gap-grpc-pd.md for the wiring plan.
--
-- Everything here is pure Lua over tables, so test/unit/test_pd.lua can drive
-- it without a shared dict.

local _M = { _VERSION = "0.1.0" }

_M.POOL_REGULAR = "regular"
_M.POOL_PREFILL = "prefill"
_M.POOL_DECODE = "decode"

local POOLS = { [_M.POOL_REGULAR] = true, [_M.POOL_PREFILL] = true,
                [_M.POOL_DECODE] = true }

-- Body keys copied from pd_router.rs BOOTSTRAP_*_KEY / DISAGG_PREFILL_DP_RANK_KEY.
_M.BOOTSTRAP_HOST_KEY = "bootstrap_host"
_M.BOOTSTRAP_PORT_KEY = "bootstrap_port"
_M.BOOTSTRAP_ROOM_KEY = "bootstrap_room"
_M.DISAGG_PREFILL_DP_RANK_KEY = "disagg_prefill_dp_rank"

-- Selection failure codes, mirroring the strings pd_router.rs puts in the
-- "server_selection_failed" error body ("<pool> worker not found").
_M.ERR_NO_PREFILL = "no_healthy_prefill_workers"
_M.ERR_NO_DECODE = "no_healthy_decode_workers"
_M.ERR_NO_WORKERS = "no_pd_workers"
_M.ERR_NOT_PD_MODE = "pd_mode_disabled"

----------------------------------------------------------------------
-- worker type / pool classification
----------------------------------------------------------------------

---Pool tag of one worker record. Priority matches the Rust worker, where the
---type is explicit metadata; `pool` is the label llm-watcher already writes for
---the Lua policies (policies/utils.lua worker_pool reads it first).
---@param w table|nil
---@return string pool
function _M.pool_of(w)
    if type(w) ~= "table" then
        return _M.POOL_REGULAR
    end
    local v = w.pool
    if type(v) ~= "string" or not POOLS[v] then
        v = w.worker_type
    end
    if type(v) ~= "string" or not POOLS[v] then
        v = _M.POOL_REGULAR
    end
    local labels = w.labels
    if type(labels) == "table" then
        local tag = labels.worker_type or labels.pool
        if type(tag) == "string" and POOLS[tag] then
            v = tag
        end
    end
    return v
end

---Bootstrap port of a prefill worker. Rust caches it in WorkerType::Prefill and
---in metadata.bootstrap_port; llm-watcher / POST /workers may instead carry it
---as a label. nil means the decode side must discover it.
---@param w table|nil
---@return number|nil port
function _M.bootstrap_port_of(w)
    if type(w) ~= "table" then
        return nil
    end
    local p = w.bootstrap_port
    if type(p) ~= "number" then
        local labels = w.labels
        p = type(labels) == "table" and tonumber(labels.bootstrap_port) or nil
    end
    if type(p) ~= "number" then
        return nil
    end
    p = math.floor(p)
    if p < 1 or p > 65535 then
        return nil
    end
    return p
end

---DP rank carried by the url suffix (`http://10.66.5.115:20664@3`), the same
---convention Rust parse_bootstrap_host_from_url strips before resolving the
---bootstrap host. Workers without the suffix are not DP-aware.
---@param url string|nil
---@return string base_url, number|nil rank
function _M.split_dp_rank(url)
    if type(url) ~= "string" then
        return url, nil
    end
    local base, rank = url:match("^(.-)@(%d+)$")
    if not base then
        return url, nil
    end
    return base, tonumber(rank)
end

---Host part of a worker url, without scheme, port or DP-rank suffix. Matches
---Rust parse_bootstrap_host_from_url, which parses the URL after stripping
---`@rank` and keeps only the host (never the port: bootstrap is a separate
---server on the prefill node).
---@param url string|nil
---@return string host
function _M.bootstrap_host_of(url)
    if type(url) ~= "string" or url == "" then
        return "localhost"
    end
    local base = _M.split_dp_rank(url)
    -- Drop the scheme, then read either a bracketed IPv6 literal or the run of
    -- characters before the port colon. Url::host in Rust returns the bare
    -- address without brackets, so neither form keeps them here.
    local authority = base:match("^[^:/?#]+://(.+)$") or base
    local host = authority:match("^%[([^]%]]+)%]") or authority:match("^([^:/?#%[]+)")
    if not host or host == "" then
        return "localhost"
    end
    return host
end

----------------------------------------------------------------------
-- pools
----------------------------------------------------------------------

---Split records into the three pools.
---@param records table[]
---@param is_available fun(w: table): boolean|nil @ health+breaker filter; nil = trust w.healthy
---@return table pools @ {regular=..., prefill=..., decode=...}
function _M.pools(records, is_available)
    local out = { regular = {}, prefill = {}, decode = {} }
    if type(records) ~= "table" then
        return out
    end
    for i = 1, #records do
        local w = records[i]
        if type(w) == "table" then
            local available
            if is_available then
                available = is_available(w) and true or false
            else
                available = (w.healthy == nil) and true or (w.healthy and true or false)
            end
            if available then
                local pool = _M.pool_of(w)
                out[pool][#out[pool] + 1] = w
            end
        end
    end
    return out
end

---Pool census over *all* records, healthy or not: what /readiness and the UI
---need to explain why PD routing is unusable.
---@param records table[]
---@return table counts @ {regular=n, prefill=n, decode=n, healthy_prefill=n, healthy_decode=n}
function _M.counts(records, is_available)
    local pools = _M.pools(records, is_available)
    local counts = {
        regular = #pools.regular,
        prefill = #pools.prefill,
        decode = #pools.decode,
    }
    local total = { regular = 0, prefill = 0, decode = 0 }
    if type(records) == "table" then
        for i = 1, #records do
            total[_M.pool_of(records[i])] = total[_M.pool_of(records[i])] + 1
        end
    end
    counts.total = total
    return counts
end

----------------------------------------------------------------------
-- pair selection
----------------------------------------------------------------------

---Is PD mode usable, i.e. does every pool have at least one candidate?
---Rust expresses this through RoutingMode::PrefillDecode (a startup flag); the
---Lua router has no such flag, so mode is inferred from the registered pool
---membership and reported by /readiness (server.rs requires both pools).
---@param pools_or_records table @ pools() result or raw records
---@param is_available fun(w: table): boolean|nil
---@return boolean pd_mode, string|nil err
function _M.pd_mode(pools_or_records, is_available)
    local pools = pools_or_records.prefill and pools_or_records
        or _M.pools(pools_or_records, is_available)
    if #pools.prefill > 0 and #pools.decode > 0 then
        return true
    end
    if #pools.prefill == 0 and #pools.decode == 0 then
        if #pools.regular > 0 then
            -- Only regular workers: nothing to disaggregate, use the plain path.
            return false, _M.ERR_NOT_PD_MODE
        end
        return false, _M.ERR_NO_WORKERS
    end
    return false, (#pools.prefill == 0) and _M.ERR_NO_PREFILL or _M.ERR_NO_DECODE
end

---Select the prefill/decode pair for one request.
---
---`select` is called once per pool with a pool-scoped candidate list, which is
---how the Rust policy_registry keeps a prefill policy and a decode policy: pass
---the same policy instance twice (its affinity trees are keyed by
---(pool, model), so the two calls cannot cross-contaminate) or two instances.
---@param records table[] @ registry.records()
---@param opts table @ {select=fn(candidates, pool)->worker|nil, is_available=fn, model=string|nil}
---@return table|nil pair @ {prefill=worker, decode=worker, bootstrap_room=number, prefill_url, decode_url}
---@return string|nil err
function _M.select_pair(records, opts)
    opts = opts or {}
    if type(opts.select) ~= "function" then
        return nil, "select function required"
    end
    local is_available = opts.is_available
    if not is_available then
        is_available = function(w)
            return (w.healthy == nil) and true or (w.healthy and true or false)
        end
    end

    local pools = _M.pools(records, is_available)
    local pd, mode_err = _M.pd_mode(pools, is_available)
    if not pd then
        return nil, mode_err
    end

    local prefill = opts.select(pools.prefill, _M.POOL_PREFILL)
    if not prefill then
        return nil, _M.ERR_NO_PREFILL
    end
    local decode = opts.select(pools.decode, _M.POOL_DECODE)
    if not decode then
        return nil, _M.ERR_NO_DECODE
    end

    local room = _M.room_id(opts.rng)
    local base, rank = _M.split_dp_rank(prefill.url)
    return {
        prefill = prefill,
        decode = decode,
        prefill_url = base,
        prefill_dp_rank = rank,
        decode_url = decode.url,
        bootstrap_host = _M.bootstrap_host_of(prefill.url),
        bootstrap_port = _M.bootstrap_port_of(prefill),
        bootstrap_room = room,
        pools = pools,
    }
end

----------------------------------------------------------------------
-- bootstrap room id
----------------------------------------------------------------------

---Room id in [0, 2^63-1], the range Python's random.randint(0, 2**63-1) gives
---(pd_types.rs generate_room_id). The room only has to be unique per in-flight
---request and JSON-serialisable as an integer, so 53 bits of double precision is
---enough to avoid the fixed-point truncation that math.random() % 2^63 would hit.
---@param rng fun(): number|nil @ [0,1) source, injectable for tests
---@return number room
function _M.room_id(rng)
    rng = rng or math.random
    local high = math.floor(rng() * 2097152)        -- 21 bits
    local low = math.floor(rng() * 2097152)         -- 21 bits
    local tail = math.floor(rng() * 1024)           -- 10 bits  => 52 bits
    local room = ((high * 2097152) + low) * 1024 + tail
    return room
end

---Room id for the gRPC path: [0, 2^31-1].
---
---The two Rust PD implementations do not use the same range. The HTTP path
---serialises JSON and calls pd_types.rs generate_room_id, which reaches for
---2^63-1; the gRPC path fills the proto int32 field DisaggregatedParams
---.bootstrap_room and draws from 0..i32::MAX (grpc/common/stages/helpers.rs
---inject_bootstrap_metadata). A room beyond 2^31-1 would not encode.
---@param rng fun(): number|nil @ [0,1) source, injectable for tests
---@return number room
function _M.room_id_i32(rng)
    rng = rng or math.random
    return math.floor(rng() * 2147483647)
end

---Default bootstrap port for a prefill worker that never declared one.
---The HTTP path injects JSON null and lets the engine pick; the gRPC path
---substitutes 8998 (helpers.rs `bootstrap_port().unwrap_or(8998)`), which is
---sglang's --disaggregation-bootstrap-port default.
_M.DEFAULT_BOOTSTRAP_PORT = 8998

----------------------------------------------------------------------
-- request-body rewriting
----------------------------------------------------------------------

---Inject the bootstrap triple into a decoded request body, in place, matching
---inject_bootstrap_into_value. `batch_size` switches every field to a repeated
---array (SGLang's batch contract), and one room per batch item is *distinct*,
---like the Rust loop.
---@param body table @ decoded JSON object
---@param pair table @ select_pair() result
---@param batch_size number|nil
---@return table body, string|nil err
function _M.inject_bootstrap(body, pair, batch_size)
    if type(body) ~= "table" then
        return nil, "request must be a JSON object"
    end
    if type(pair) ~= "table" then
        return nil, "pd pair required"
    end
    local host = pair.bootstrap_host or _M.bootstrap_host_of(pair.prefill_url)
    local port = pair.bootstrap_port

    if type(batch_size) == "number" and batch_size > 0 then
        local hosts, ports, rooms = {}, {}, {}
        for i = 1, batch_size do
            hosts[i] = host
            ports[i] = port
            rooms[i] = pair.bootstrap_room + i - 1
        end
        body[_M.BOOTSTRAP_HOST_KEY] = hosts
        body[_M.BOOTSTRAP_PORT_KEY] = ports
        body[_M.BOOTSTRAP_ROOM_KEY] = rooms
        return body
    end

    body[_M.BOOTSTRAP_HOST_KEY] = host
    body[_M.BOOTSTRAP_PORT_KEY] = port
    body[_M.BOOTSTRAP_ROOM_KEY] = pair.bootstrap_room
    return body
end

---Add disagg_prefill_dp_rank to the *decode* copy when the prefill worker is
---DP-aware (url carried @rank). Returns the body unchanged otherwise, which is
---the Rust behaviour (inject_prefill_dp_rank_for_decode early-returns).
---@param body table
---@param pair table
---@return table body, string|nil err
function _M.inject_dp_rank_for_decode(body, pair)
    if type(body) ~= "table" then
        return nil, "request must be a JSON object"
    end
    local rank = pair and pair.prefill_dp_rank
    if type(rank) ~= "number" then
        return body
    end
    body[_M.DISAGG_PREFILL_DP_RANK_KEY] = rank
    return body
end

----------------------------------------------------------------------
-- dispatch and outcome
----------------------------------------------------------------------

---Whether a paired dispatch should charge the prefill breaker.
---
---execute_dual_dispatch_internal: any non-2xx/transport error on prefill
---cancels the decode request on purpose (decode would otherwise sit in
---WaitingForInput until the 300 s disaggregation timeout), and decode is
---deliberately *not* charged, because a prefill storm would otherwise open
---healthy decode breakers. 4xx counts as a client fault, so it is not charged
---either -- the same rule registry.charge_cb applies to plain routes.
---@param prefill_status number|nil @ nil = transport error
---@return boolean charge_prefill, boolean charge_decode, string error_type
function _M.outcome(prefill_status)
    if not prefill_status then
        return true, false, "transport"
    end
    if prefill_status >= 200 and prefill_status < 300 then
        return false, false, "ok"
    end
    if prefill_status >= 400 and prefill_status < 500 then
        return false, false, "client"
    end
    return true, false, "upstream"
end

---What /readiness must answer in PD mode.
---
---Rust: PrefillDecode mode is ready only when at least one healthy worker exists
---in *each* pool; IGW mode only needs one healthy worker of any type.
---@param records table[]
---@param opts table|nil @ {is_available=fn, enable_igw=bool}
---@return boolean ready, table report @ {status, healthy_workers, total_workers, reason}
function _M.readiness(records, opts)
    opts = opts or {}
    local available = opts.is_available or function(w)
        return (w.healthy == nil) and true or (w.healthy and true or false)
    end
    local pools = _M.pools(records, available)
    local total = type(records) == "table" and #records or 0
    local healthy = #pools.regular + #pools.prefill + #pools.decode

    if opts.enable_igw then
        if healthy > 0 then
            return true, { status = "ready", healthy_workers = healthy, total_workers = total }
        end
        return false, { status = "not ready", reason = "insufficient healthy workers",
                        healthy_workers = 0, total_workers = total }
    end

    -- PD mode is judged on the *registered* census, not the healthy one: Rust
    -- reads router_config.mode, which a health flip cannot change. A fleet that
    -- has ever registered a prefill or decode worker is a PD fleet.
    local registered_pd = false
    if type(records) == "table" then
        for i = 1, #records do
            local pool = _M.pool_of(records[i])
            if pool ~= _M.POOL_REGULAR then
                registered_pd = true
                break
            end
        end
    end
    if not registered_pd then
        if healthy > 0 then
            return true, { status = "ready", healthy_workers = healthy, total_workers = total }
        end
        return false, { status = "not ready", reason = "insufficient healthy workers",
                        healthy_workers = 0, total_workers = total }
    end

    if #pools.prefill > 0 and #pools.decode > 0 then
        return true, { status = "ready", healthy_workers = healthy, total_workers = total,
                       prefill_workers = #pools.prefill, decode_workers = #pools.decode }
    end
    local err = (#pools.prefill == 0) and _M.ERR_NO_PREFILL or _M.ERR_NO_DECODE
    return false, { status = "not ready", reason = err,
                    healthy_workers = healthy, total_workers = total,
                    prefill_workers = #pools.prefill, decode_workers = #pools.decode }
end

return _M
