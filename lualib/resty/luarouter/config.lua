-- Environment parsing and defaults for the Lua router.
--
-- Names mirror the Rust gateway's clap flags (SMG_ prefix) so an operator can
-- read one vocabulary in both implementations; the LMR_ prefix keeps the
-- observability knobs the repo added on top. Defaults are the Rust defaults.
-- Booleans accept 1/true/yes/on; lists accept comma or space separated values.

local _M = { _VERSION = "0.1.0" }

local getenv = os.getenv

local function raw(name, default)
    local value = getenv(name)
    if value == nil then
        return default
    end
    -- Treat an empty string as "not set" so docker-compose commented defaults
    -- (FOO: "") do not turn numeric knobs into parse errors.
    if value == "" then
        return default
    end
    return value
end

_M.raw = raw

local function str(name, default)
    return raw(name, default)
end

local function num(name, default)
    local value = raw(name)
    if value == nil then
        return default
    end
    local parsed = tonumber(value)
    if parsed == nil then
        return default
    end
    return parsed
end

local function bool(name, default)
    local value = raw(name)
    if value == nil then
        return default
    end
    value = string.lower(value)
    if value == "1" or value == "true" or value == "yes" or value == "on" then
        return true
    end
    if value == "0" or value == "false" or value == "no" or value == "off" then
        return false
    end
    return default
end

-- Split on comma or whitespace, dropping empty fields.
local function list(name)
    local value = raw(name, "")
    local out = {}
    for item in string.gmatch(value, "[^,%s]+") do
        out[#out + 1] = item
    end
    return out
end

-- Trim and lowercase a policy-ish token, with a fallback when unknown.
local function one_of(name, default, allowed)
    local value = raw(name, default)
    value = string.lower(string.gsub(value, "^%s*(.-)%s*$", "%1"))
    for i = 1, #allowed do
        if allowed[i] == value then
            return value
        end
    end
    return default
end

_M.bool = bool
_M.num = num
_M.list = list

-- Comma/space separated number list (Prometheus buckets). Empty -> {}.
local function num_list(name)
    local out = {}
    for _, item in ipairs(list(name)) do
        local parsed = tonumber(item)
        if parsed then
            out[#out + 1] = parsed
        end
    end
    table.sort(out)
    return out
end

-- SMG_LOG_LEVEL (Rust: debug|info|warn|error|trace) with LR_LOG_LEVEL as the
-- older spelling. nginx levels (notice/crit/alert/emerg) stay accepted so an
-- operator can quiet the error log without changing the Lua gate.
local LOG_LEVELS = { debug = true, info = true, warn = true, error = true,
                     notice = true, crit = true, alert = true, emerg = true }

local function log_level_from_env()
    for _, name in ipairs({ "SMG_LOG_LEVEL", "LR_LOG_LEVEL" }) do
        local value = raw(name)
        if value then
            value = string.lower(string.gsub(value, "^%s*(.-)%s*$", "%1"))
            if value == "trace" then
                return "debug"
            end
            if LOG_LEVELS[value] then
                return value
            end
        end
    end
    return "info"
end

-- The full policy set of the Rust gateway (policies/factory.rs plus the CLI
-- value_parser), plus bucket, which the CLI only accepts through a config file.
-- Unknown names still collapse to the default rather than failing to boot.
local POLICIES = { "random", "round_robin", "cache_aware", "power_of_two",
                   "prefix_hash", "manual", "bucket", "consistent_hashing" }

function _M.load()
    local cfg = {
        -- ==================== server ====================
        host = str("SMG_HOST", "0.0.0.0"),
        port = num("SMG_PORT", 30000),
        -- worker_processes is decided at render time by docker-entrypoint.sh
        -- (auto, or 1 for cache_aware); nginx.conf.template owns that rule, so
        -- this stays the informational value /probe/config reports.
        worker_processes = num("NGINX_WORKER_PROCESSES", 2),
        -- The gateway's own API keys (SMG_API_KEY / SMG_CONTROL_PLANE_API_KEY /
        -- the JWT plane) were removed with the auth layer (doc/scope-trim.md):
        -- every endpoint is open and the trust boundary is the edge. A worker's
        -- api_key field stays -- that is the credential this router presents to
        -- an upstream, not a gate in front of itself.

        -- ==================== workers ====================
        worker_urls = list("SMG_WORKER_URLS"),
        enable_igw = bool("SMG_ENABLE_IGW", false),
        -- SMG_DP_AWARE (Rust --dp-aware). When on, a worker whose /server_info
        -- reports dp_size > 1 is expanded into one registry entry per rank, each
        -- with its own health counters, exactly like DPAwareWorkerBuilder in
        -- core/worker_builder.rs. See doc/gap-discovery-dp.md.
        dp_aware = bool("SMG_DP_AWARE", false),

        -- ==================== policy ====================
        -- Rust default is cache_aware (--policy default_value_t = PolicyConfig::
        -- CacheAware), so an unset SMG_POLICY selects the tree policy here and
        -- docker-entrypoint.sh drops worker_processes to 1 for it. Unknown names
        -- still collapse to the default.
        policy = one_of("SMG_POLICY", "cache_aware", POLICIES),
        eviction_interval_secs = num("SMG_EVICTION_INTERVAL_SECS", 120),
        max_idle_secs = num("SMG_MAX_IDLE_SECS", 14400),
        assignment_mode = one_of("SMG_ASSIGNMENT_MODE", "random",
                                 { "random", "min_load", "min_group" }),

        -- cache_aware knobs: defaults are the Rust CLI defaults (main.rs
        -- --cache-threshold / --balance-*-threshold / --max-tree-size), not the
        -- policy struct defaults, because the container is launched from a CLI.
        cache_threshold = num("SMG_CACHE_THRESHOLD", 0.3),
        balance_abs_threshold = num("SMG_BALANCE_ABS_THRESHOLD", 64),
        balance_rel_threshold = num("SMG_BALANCE_REL_THRESHOLD", 1.5),
        max_tree_size = num("SMG_MAX_TREE_SIZE", 67108864),

        -- prefix_hash knobs (Rust --prefix-token-count / --prefix-hash-load-factor;
        -- the Lua tree counts characters, see doc/impl-hash.md deviation 6).
        prefix_token_count = num("SMG_PREFIX_TOKEN_COUNT", 256),
        prefix_hash_load_factor = num("SMG_PREFIX_HASH_LOAD_FACTOR", 1.25),

        -- bucket knob (Rust PolicyConfig::Bucket default in validation tests).
        bucket_adjust_interval_secs = num("SMG_BUCKET_ADJUST_INTERVAL_SECS", 5),

        -- Ceiling for one cache_aware tree snapshot written into lr_policy; a
        -- snapshot larger than this is skipped (encode_snapshot returns nil).
        snapshot_max_bytes = num("LR_SNAPSHOT_MAX_BYTES", 3 * 1024 * 1024),

        -- ==================== circuit breaker ====================
        cb_failure_threshold = num("SMG_CB_FAILURE_THRESHOLD", 10),
        cb_success_threshold = num("SMG_CB_SUCCESS_THRESHOLD", 3),
        cb_timeout_duration_secs = num("SMG_CB_TIMEOUT_DURATION_SECS", 60),
        cb_window_duration_secs = num("SMG_CB_WINDOW_DURATION_SECS", 120),
        disable_circuit_breaker = bool("SMG_DISABLE_CIRCUIT_BREAKER", false),

        -- ==================== health checks ====================
        health_failure_threshold = num("SMG_HEALTH_FAILURE_THRESHOLD", 3),
        health_success_threshold = num("SMG_HEALTH_SUCCESS_THRESHOLD", 2),
        health_check_timeout_secs = num("SMG_HEALTH_CHECK_TIMEOUT_SECS", 5),
        health_check_interval_secs = num("SMG_HEALTH_CHECK_INTERVAL_SECS", 60),
        health_check_endpoint = str("SMG_HEALTH_CHECK_ENDPOINT", "/health"),
        disable_health_check = bool("SMG_DISABLE_HEALTH_CHECK", false),

        -- ==================== retries ====================
        max_retries = num("SMG_RETRY_MAX_RETRIES", 5),
        initial_backoff_ms = num("SMG_RETRY_INITIAL_BACKOFF_MS", 50),
        max_backoff_ms = num("SMG_RETRY_MAX_BACKOFF_MS", 30000),
        backoff_multiplier = num("SMG_RETRY_BACKOFF_MULTIPLIER", 1.5),
        jitter_factor = num("SMG_RETRY_JITTER_FACTOR", 0.2),
        disable_retries = bool("SMG_DISABLE_RETRIES", false),

        -- ==================== request handling ====================
        request_timeout_secs = num("SMG_REQUEST_TIMEOUT_SECS", 1800),
        -- Outbound connection pool (Rust RouterConfig, config/types.rs:9-13 and
        -- the --connect-timeout / --pool-idle-timeout / --pool-max-idle-per-host
        -- --tcp-keepalive CLI defaults). The Rust gateway hands these to
        -- reqwest; here they drive the cosocket pool (see registry.pool_opts).
        connect_timeout_secs = num("SMG_CONNECT_TIMEOUT_SECS", 10),
        pool_idle_timeout_secs = num("SMG_POOL_IDLE_TIMEOUT_SECS", 50),
        pool_max_idle_per_host = num("SMG_POOL_MAX_IDLE_PER_HOST", 500),
        tcp_keepalive_secs = num("SMG_TCP_KEEPALIVE_SECS", 30),
        max_payload_size = num("SMG_MAX_PAYLOAD_SIZE", 536870912),
        request_id_headers = list("SMG_REQUEST_ID_HEADERS"),

        -- ==================== data-parallel ranks ===========================
        -- The Kubernetes pod poller and the router-pod selector that fed mesh
        -- members went out with it (doc/scope-trim.md). SMG_DP_AWARE stays above:
        -- rank expansion is registry-side and needs no cluster API.

        -- ==================== metrics / observability ====================
        -- Rust name is --prometheus-port (default 29000); LR_METRICS_PORT stays
        -- as the older alias. The listener itself is rendered by the entrypoint,
        -- which reads the same names.
        metrics_port = num("SMG_METRICS_PORT", num("LR_METRICS_PORT", 29000)),
        metrics_host = str("SMG_PROMETHEUS_HOST", "0.0.0.0"),
        -- SMG_PROMETHEUS_DURATION_BUCKETS: comma/space separated seconds. Empty
        -- means the default ladder in observability.lua.
        duration_buckets = num_list("SMG_PROMETHEUS_DURATION_BUCKETS"),

        -- ==================== CORS ====================
        -- Empty = the Rust default (allow every origin, methods and headers).
        -- A list restricts the echoed origin and the allowed methods/headers.
        cors_allowed_origins = list("SMG_CORS_ALLOWED_ORIGINS"),

        -- ==================== concurrency limit ====================
        -- Rust: max_concurrent_requests <= 0 disables the limiter entirely.
        max_concurrent_requests = num("SMG_MAX_CONCURRENT_REQUESTS", -1),
        queue_size = num("SMG_QUEUE_SIZE", 100),
        queue_timeout_secs = num("SMG_QUEUE_TIMEOUT_SECS", 60),
        -- 0/absent means "same as the concurrency ceiling" (Rust unwrap_or(n)).
        rate_limit_tokens_per_second = num("SMG_RATE_LIMIT_TOKENS_PER_SECOND", 0),
        request_log_capacity = num("LMR_REQUEST_LOG_CAPACITY", 1000),
        price_in_per_mtok = num("LMR_PRICE_IN_PER_MTOK"),
        price_out_per_mtok = num("LMR_PRICE_OUT_PER_MTOK"),
        stats_window_s = num("LR_STATS_WINDOW_S", 10),

        -- ==================== misc ====================
        version = str("LR_VERSION", "0.1.0-lua"),
        -- SMG_LOG_LEVEL is the Rust name and wins; LR_LOG_LEVEL (the value nginx
        -- itself is configured with) is still honoured, and "trace" collapses to
        -- "debug" because nginx has no trace level.
        log_level = log_level_from_env(),
        started_at_ms = math.floor(ngx.now() * 1000),
    }
    return cfg
end

-- init_by_lua runs before the error-log level is applied, so keep the message
-- plain and let the caller decide whether it is fatal.
function _M.validate(cfg)
    if cfg.health_check_endpoint:sub(1, 1) ~= "/" then
        cfg.health_check_endpoint = "/" .. cfg.health_check_endpoint
    end
    if cfg.health_check_interval_secs < 1 then
        cfg.health_check_interval_secs = 1
    end
    if cfg.max_retries < 0 then
        cfg.max_retries = 0
    end
    -- Pool knobs: Rust validation.rs rejects connect_timeout_secs == 0 and
    -- tcp_keepalive_secs == 0 outright (config/validation.rs:316-327). A Lua
    -- router that refuses to start over a typo would be worse than one that
    -- clamps, so 0 falls back to the Rust default instead of failing.
    if cfg.connect_timeout_secs < 1 then
        cfg.connect_timeout_secs = 10
    end
    if cfg.tcp_keepalive_secs < 1 then
        cfg.tcp_keepalive_secs = 30
    end
    if cfg.pool_idle_timeout_secs < 1 then
        cfg.pool_idle_timeout_secs = 50
    end
    if cfg.pool_max_idle_per_host < 1 then
        cfg.pool_max_idle_per_host = 500
    end
    -- Zero disables the request log entirely, as in the Rust gateway: the store
    -- is never installed there, so /_ui/logs* and /_ui/stats answer 503. Only a
    -- negative value is nonsense.
    if cfg.request_log_capacity < 0 then
        cfg.request_log_capacity = 0
    end
    -- Concurrency guard rails (Rust validation.rs rejects queue_size > 0 with
    -- queue_timeout_secs == 0; here the timeout is clamped instead of failing).
    if cfg.queue_size < 0 then
        cfg.queue_size = 0
    end
    if cfg.max_concurrent_requests > 0 and cfg.queue_size > 0
        and cfg.queue_timeout_secs < 1 then
        cfg.queue_timeout_secs = 1
    end
    return cfg
end

return _M
