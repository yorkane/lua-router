-- Concurrency limiter for the inference plane (SMG_MAX_CONCURRENT_REQUESTS).
--
-- Mirrors the Rust middleware stack:
--   * middleware.rs:498 concurrency_limit_middleware is attached to
--     protected_routes only (server.rs:1314), i.e. the seven inference routes.
--     Public, admin, worker, mesh and /_ui traffic is never limited here.
--   * app_context.rs:376 builds the guard only when max_concurrent_requests > 0;
--     any other value (the -1 default included) means "no limiter at all", so
--     acquire() becomes a no-op rather than a counter pass-through.
--   * core/token_bucket.rs: capacity is the concurrency limit and the refill rate
--     is SMG_RATE_LIMIT_TOKENS_PER_SECOND, which falls back to the capacity when
--     unset (0). With that fallback the bucket behaves like a plain semaphore once
--     the pool is saturated, because refilling at capacity only ever returns the
--     tokens that were handed back.
--
-- State lives in a shared dict so every nginx worker process sees the same
-- budget: with N processes the limit is global, exactly as it is in the single
-- Rust process. The dict is also the only place where the queue depth can be
-- counted, since waiters live in different processes.
--
-- Rejected requests answer 429 with an empty body, like Rust
-- (StatusCode::TOO_MANY_REQUESTS.into_response() carries no JSON). A waiter that
-- runs out of queue time answers 429 as well; Rust answers 408 there, which is
-- documented deviation.
--
-- Token return: release() is idempotent per request (the guard flag lives in
-- ngx.ctx), is called by router.finish_request on the normal path, and by
-- init.lua's on_log hook, which also runs when the client goes away mid-stream
-- and the handler never reaches finish_request. Streaming therefore holds its
-- token for the whole response, matching the Rust TokenGuardBody that returns
-- only once the body has been consumed.

local observability = require "resty.luarouter.observability"

local _M = { _VERSION = "0.1.0" }

local DICT_NAME = "lr_limit"
local K_TOKENS = "tokens"
local K_STAMP = "stamp"
local K_ACTIVE = "active"
local K_QUEUED = "queued"
local POLL_S = 0.01

local config

local function cfg()
    if not config then
        config = require("resty.luarouter").config()
    end
    return config
end

local function dict()
    return ngx.shared[DICT_NAME]
end

---True when the limiter is configured and switched on.
---@return boolean
function _M.enabled()
    return (cfg().max_concurrent_requests or -1) > 0
end

---Refill the bucket from elapsed time and clamp it to capacity.
---@param d ngx.shared.Dict
---@param capacity number
---@param rate number
---@param now number
---@return number tokens
local function refill(d, capacity, rate, now)
    local last = d:get(K_STAMP)
    local tokens = tonumber(d:get(K_TOKENS)) or capacity
    if not last then
        -- First use after boot or after an explicit reset.
        return tokens
    end
    local elapsed = now - last
    if elapsed <= 0 then
        return tokens
    end
    if rate > 0 then
        tokens = math.min(capacity, tokens + elapsed * rate)
    else
        -- No refill configured: hold the full capacity so a pure semaphore never
        -- loses the tokens it returns. release() is what actually unlocks.
        tokens = capacity
    end
    return tokens
end

---Try to reserve one concurrency slot, waiting in the queue when configured.
---@return boolean ok @ false means the caller must answer 429
function _M.acquire()
    if not _M.enabled() then
        return true
    end
    local conf = cfg()
    local capacity = conf.max_concurrent_requests
    local rate = conf.rate_limit_tokens_per_second
    if not rate or rate <= 0 then
        rate = capacity
    end
    local d = dict()
    if not d then
        -- No dictionary in this nginx config: fail open rather than refuse
        -- traffic because of a missing declaration.
        return true
    end

    local deadline = ngx.now() + (conf.queue_timeout_secs or 0)
    local queued = false

    while true do
        local tokens = refill(d, capacity, rate, ngx.now())
        if tokens >= 1 then
            d:set(K_TOKENS, tokens - 1, 3600)
            d:set(K_STAMP, ngx.now(), 3600)
            d:incr(K_ACTIVE, 1, 0)
            ngx.ctx.lr_limit_token = true
            if queued then
                d:incr(K_QUEUED, -1, 0)
                ngx.ctx.lr_limit_queued = nil
            end
            observability.record_http_rate_limit("allowed")
            return true
        end

        local queue_size = conf.queue_size or 0
        if queue_size <= 0 then
            observability.record_http_rate_limit("rejected")
            return false
        end
        if not queued then
            local depth = d:incr(K_QUEUED, 1, 0)
            if depth > queue_size then
                d:incr(K_QUEUED, -1, 0)
                observability.record_http_rate_limit("rejected")
                return false
            end
            queued = true
            ngx.ctx.lr_limit_queued = true
        end
        if ngx.now() >= deadline then
            d:incr(K_QUEUED, -1, 0)
            ngx.ctx.lr_limit_queued = nil
            -- Rust answers 408 here; the task contract wants 429 for every
            -- limiter rejection (documented deviation).
            observability.record_http_rate_limit("rejected")
            return false
        end
        -- Yield so the request holding the token can finish. ngx.sleep returns no
        -- values at all when it succeeds, so the call must be wrapped: judging the
        -- result directly reads a healthy sleep as an abort and rejects instantly.
        local ok, err = pcall(ngx.sleep, POLL_S)
        if not ok then
            -- Request terminated under us (client gone): hand the queue slot back
            -- instead of leaking depth. Nobody sees a response, so the decision is
            -- not counted as a rejection.
            d:incr(K_QUEUED, -1, 0)
            ngx.ctx.lr_limit_queued = nil
            observability.log_debug("limiter queue sleep aborted: " .. tostring(err))
            return false
        end
    end
end

---Hand back the slot reserved by acquire(). Safe to call more than once.
---@return boolean released
function _M.release()
    if not ngx.ctx.lr_limit_token then
        return false
    end
    ngx.ctx.lr_limit_token = nil
    local d = dict()
    if d then
        local active = d:incr(K_ACTIVE, -1, 0)
        if active and active < 0 then
            d:set(K_ACTIVE, 0)
        end
        if _M.enabled() then
            -- One slot freed: credit it back so a waiter can take it without
            -- waiting for the refill clock.
            local capacity = cfg().max_concurrent_requests
            d:set(K_STAMP, ngx.now(), 3600)
            local tokens = tonumber(d:get(K_TOKENS)) or 0
            d:set(K_TOKENS, math.min(capacity, tokens + 1), 3600)
        end
    end
    return true
end

---Live gauges, used by the contract suite to prove the budget is shared and
---returned rather than counted per process.
---@return table
function _M.stats()
    local d = dict()
    if not d then
        return { enabled = false, active = 0, queued = 0, tokens = 0 }
    end
    return {
        enabled = _M.enabled(),
        active = tonumber(d:get(K_ACTIVE)) or 0,
        queued = tonumber(d:get(K_QUEUED)) or 0,
        tokens = tonumber(d:get(K_TOKENS)) or 0,
    }
end

_M.POLL_S = POLL_S

return _M
