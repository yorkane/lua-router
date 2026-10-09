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

---Build the watcher sub-config, or a disabled stub when the module is unusable.
---@param cfg table @ partially built router config (owns the two self ports)
---@return table
local function watcher_snapshot(cfg)
    local ok, watcher = pcall(require, "resty.luarouter.watcher")
    if ok and type(watcher) == "table"
        and type(watcher.new_config) == "function" then
        -- The two self ports go in as numbers: they are the listeners the watcher
        -- must never turn into candidates (guard 1).
        local built_ok, result = pcall(watcher.new_config, os.getenv,
            cfg.port, cfg.metrics_port)
        if built_ok and type(result) == "table" then
            return result
        end
    end
    return { enabled = false, targets = {}, model_map = {}, self_ports = { cfg.port },
             interval_secs = 15, probe_timeout_secs = 4, remove_grace_secs = 300,
             max_models = 8, keep_last_grace_secs = 1800 }
end

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
        -- core/worker_builder.rs (DP 展开设计见 git 历史).
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
        -- 亲和树的**节点数**上限（doc/gap-cpu-idle-burn.md）。max_tree_size 管的是
        -- 「每租户（= 每个 worker URL）的字符数」，同一批 worker 可以合法地各背满它，
        -- 于是总占用 = 树数 × 租户数 × max_tree_size，没有任何一维约束节点个数。
        -- 单 worker 进程里真正把转发核压住的是节点数（每节点一张表 + 一份 prompt 尾巴），
        -- 所以这里补一维。200000 的量级选择：每节点约 200-400 B，最坏约 60 MB/树，
        -- 相对 8801 事故现场的 1.9 GB 是可接受的天花板；<=0 关闭这一维。
        max_tree_nodes = num("SMG_MAX_TREE_NODES", 200000),
        -- 单次淘汰最多弹多少个叶子（增量淘汰的硬上界）。0 = 用 tree.lua 的缺省 2000。
        -- 这条是给「树已经失控」的现场用的：没有预算时那淘汰的一拍本身就能占秒级核时。
        evict_budget = num("SMG_EVICT_BUDGET", 0),

        -- 策略实例（_M.instances 里一条 <policy>:<模型/入口名>）的空闲回收 TTL。
        -- 实例原本只在 for_model 的 has_workers==false 分支删除，而 router/candidates.lua
        -- 的 profile-forced 路径直接 policy_mod.new 建实例，绕过那条回收 —— 于是每
        -- 一个曾经出现过的入口名都留下一条实例，背后还挂着整棵亲和树。20h 的进程里
        -- 这就是「没人记得它为什么还在」的那部分内存。<=0 关闭回收（回到旧行为）。
        policy_instance_ttl_secs = num("SMG_POLICY_INSTANCE_TTL_SECS", 1800),
        
        -- prefix_hash knobs (Rust --prefix-token-count / --prefix-hash-load-factor;
        -- the Lua tree counts characters, documented deviation).
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

        -- ==================== GPU load source ====================
        -- doc/gap-gpu-load.md. Off by default: none means no timer, no fetch and no
        -- registry write, so a box that never opted in runs exactly the pre-feature
        -- code path. metrics scrapes each worker's own /metrics; prom pulls one
        -- PromQL from an existing monitoring Prometheus and maps the vector back to
        -- workers by host.
        load_source = one_of("SMG_LOAD_SOURCE", "none",
                             { "none", "metrics", "prom" }),
        load_interval_secs = num("SMG_LOAD_INTERVAL_SECS", 15),
        load_timeout_secs = num("SMG_LOAD_TIMEOUT_SECS", 4),
        -- Remote source: the Prometheus base (http://prom:9090) and the PromQL
        -- template. {host} / {instance} in the template expand per worker, which is
        -- what makes one query string serve a whole pool.
        load_prom_url = str("SMG_LOAD_PROM_URL", ""),
        load_prom_query = str("SMG_LOAD_PROM_QUERY", ""),
        -- Local source: the gauge names to keep from a worker's /metrics, comma or
        -- space separated. Empty selects the built-in candidates (gpu_load
        -- .DEFAULT_METRIC_KEYS: the nvidia/dcgm utilization gauges plus the two KV
        -- cache usage spellings), and the answer is their maximum.
        load_metrics_keys = list("SMG_LOAD_METRICS_KEYS"),
        load_metrics_path = str("SMG_LOAD_METRICS_PATH", "/metrics"),
        -- How long a sample stays a load: the default is three intervals so one
        -- Prometheus blip does not drop a worker to in-flight-only, and the TTL is
        -- what makes an expired sample stop counting at all.
        load_stale_secs = num("SMG_LOAD_STALE_SECS", 0),
        -- Weight of a fully busy worker in in-flight-request units, i.e. the load
        -- a 100 %-busy GPU contributes to registry.load(). 100 keeps the combined
        -- number in the same order of magnitude as SMG_BALANCE_ABS_THRESHOLD.
        load_scale = num("SMG_LOAD_SCALE", 100),

        -- ==================== GPU utilization channel ====================
        -- doc/caps-redesign-2026-10-06.md §5：gu: 键（逐卡 GPU 利用率 0..1，TTL'd）的唯一
        -- 写者通道，registry 的 max_gpu_util 上限判定读它。与负载那一路共用同一个定时器
        -- 与同一份抓取（metrics 路同一正文多扫一遍；prom 路最多再多一条 PromQL），所以
        -- SMG_LOAD_SOURCE 仍是总开关：它是 none 时这里设了也不会有任何读数（registry 侧
        -- 「读数未知 -> 不排除」，红线 §0 第 2 条）。
        --  * SMG_LOAD_UTIL_ENABLED 缺省 **1**（设计书 §5）。缺省开不改变任何现有部署的选路
        --    行为：判定只发生在记录显式配了 max_gpu_util 的时候，采集本身只是把读数写进
        --    registry；而缺省关的代价是操作员要多记一个开关才知道利用率上限为什么一直
        --    按「未知」放行。显式关：0/false/no/off。
        --  * SMG_LOAD_UTIL_QUERY 空 = 用 gpu_load/parse.lua 的 DEFAULT_UTIL_QUERY
        --    （max by (Hostname,instance,gpu) (DCGM_FI_DEV_GPU_UTIL)——**带 gpu 标签才有
        --    逐卡**，把它聚合掉就是 342.371 的利用率复刻；权威串只有一份，这里不重复字面量
        --    的判读逻辑，空值原样交给 util_config 兜底）。prom 路「这条查询要不要多发」
        --    看的是**操作员有没有显式写过它**（runpass 的 util_enabled 口径），所以空值
        --    在这里保持空串而不是就地填缺省。
        --  * SMG_LOAD_UTIL_KEYS 覆盖 metrics 路的利用率 gauge 名册；空 = 内置名册
        --    （DEFAULT_UTIL_METRIC_KEYS：dcgm_fi_dev_gpu_util 真名 + nvidia/dcgm 两个同量纲
        --    写法，刻意不含 KV-cache 用量名——准入判据只认 GPU 利用率）。
        -- 这三个名字走的是 config.lua 装配（fork 前解析，天然进
        -- /probe/config）；三份 conf 的 env 声明只是为了让 util_config 的 os.getenv 兜底
        -- 分支在「手搓 cfg」的调用面里也能读到，两条路都通。
        load_util_enabled = bool("SMG_LOAD_UTIL_ENABLED", true),
        load_util_query = str("SMG_LOAD_UTIL_QUERY", ""),
        load_util_keys = list("SMG_LOAD_UTIL_KEYS"),

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

    -- ==================== in-process watcher ====================
    -- Discovery + registration (doc/gap-watcher-merge.md). Parsed by the watcher
    -- module itself - one parser owns the SMG_WATCHER_* vocabulary and the guard
    -- defaults - and attached here so /probe/config reports it and init_worker can
    -- hand the same table to watcher.start() without a second read of the
    -- environment. A module load failure degrades to "watcher off" rather than
    -- taking the router down.
    cfg.watcher = watcher_snapshot(cfg)

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
    -- Load-source guard rails: a sub-second interval or a sub-second deadline
    -- would turn the tick into a busy loop against every worker's /metrics, and an
    -- unparsable timeout would hand cosocket a nil deadline. Both clamp rather than
    -- fail the boot, as every other knob here does.
    if cfg.load_interval_secs < 1 then
        cfg.load_interval_secs = 1
    end
    if cfg.load_interval_secs > 3600 then
        cfg.load_interval_secs = 3600
    end
    if cfg.load_timeout_secs < 1 then
        cfg.load_timeout_secs = 1
    end
    if cfg.load_timeout_secs > 60 then
        cfg.load_timeout_secs = 60
    end
    -- A tick whose probes cannot finish inside the interval would stack passes; the
    -- single-flight lock skips them, but clamping the timeout keeps the interval
    -- honest about how long a pass may take.
    if cfg.load_timeout_secs * 2 > cfg.load_interval_secs then
        cfg.load_timeout_secs = math.max(1, math.floor(cfg.load_interval_secs / 2))
    end
    if cfg.load_scale <= 0 then
        cfg.load_scale = 100
    end
    if cfg.load_metrics_path:sub(1, 1) ~= "/" then
        cfg.load_metrics_path = "/" .. cfg.load_metrics_path
    end
   if cfg.max_retries < 0 then
       cfg.max_retries = 0
   end
    -- 亲和树闸门的取值边界。eviction_interval_secs 从来没有 >=1 的钳制（历史上就是个
    -- 雷：设 0 就等于每拍重跑一遍全树淘汰 + 落盘），新加的两维不能踩同一个坑。
    if cfg.eviction_interval_secs < 1 then
        cfg.eviction_interval_secs = 1
    end
    if cfg.max_tree_nodes < 0 then
        cfg.max_tree_nodes = 0
    end
    if cfg.max_tree_nodes > 5000000 then
        cfg.max_tree_nodes = 5000000   -- 设到千万级就等于没设，且单拍成本失控
    end
    if cfg.evict_budget < 0 then
        cfg.evict_budget = 0
    end
    if cfg.evict_budget > 200000 then
        cfg.evict_budget = 200000
    end
    if cfg.policy_instance_ttl_secs < 0 then
        cfg.policy_instance_ttl_secs = 0     -- 0/负数 = 不回收（兼容旧部署）
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
