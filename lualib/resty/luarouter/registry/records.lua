-- registry.records - worker records: registration spec parsing, the models helper
-- family, the pool structural writers (add/remove), the read-side views and the
-- single record merge writer (patch_record).
--
-- Cut verbatim out of registry.lua (refactor 2026-10-05,
-- doc/refactor-arch-2026-10-05.md section 1, blocks F/G/H/I/L/M/P).
--
-- Invariants this module owns:
--   * add/remove are the only two entries that change pool membership, and both do
--     their whole-table write inside registry.keys.with_lock;
--   * isel: is a derived bit with exactly one rule, so every write that can reach
--     worker_type/connection_mode recomputes it - add, set_http_selectable and
--     patch_record, never a submodule on the state side;
--   * patch_record is the only merge entry point for w:, it defers models and
--     model_caps until the other keys have landed (pairs() has no order), stamps
--     models_verified only for observations, compares caps by content, and mirrors
--     the record to mesh after a real write;
--   * the mesh mirror hooks and the applied-revision invalidation live in
--     registry.keys, which is where the key layout and the lock are documented.

local M = {}

local cjson = require "cjson.safe"
local keys = require "resty.luarouter.registry.keys"
local caps = require "resty.luarouter.registry.caps"

local json_encode = cjson.encode
local json_decode = cjson.decode

-- Helpers that were plain locals in the original file. They stay
-- module-private bindings (the facade roster is unchanged), reached
-- through registry.caps / registry.keys rather than duplicated.
local string_field = caps.string_field
local clone_model_caps = caps.clone_model_caps
local caps_equal = caps.caps_equal
-- The registry internals this block called directly when they lived in
-- one file: bound as locals so the record and selection paths keep the
-- original call shape (no table lookup added on a per-request path).
local shdict = keys.shdict
local with_lock = keys.with_lock
local read_ids = keys.read_ids
local write_ids = keys.write_ids
local invalidate_applied_rev = keys.invalidate_applied_rev
local mesh_mirror = keys.mesh_mirror
local mesh_forget = keys.mesh_forget

local K_ACTIVE = keys.K_ACTIVE
local K_CBF = keys.K_CBF
local K_CBO = keys.K_CBO
local K_CBS = keys.K_CBS
local K_CBSTATE = keys.K_CBSTATE
local K_DISC = keys.K_DISC
local K_DPROBE = keys.K_DPROBE
local K_GPU_UTIL = keys.K_GPU_UTIL
local K_HEALTH = keys.K_HEALTH
local K_HFAIL = keys.K_HFAIL
local K_HSEL = keys.K_HSEL
local K_HSUCC = keys.K_HSUCC
local K_IDURL = keys.K_IDURL
local K_JOB = keys.K_JOB
local K_LOAD = keys.K_LOAD
local K_MPROBE = keys.K_MPROBE
local K_MPROBE_OK = keys.K_MPROBE_OK
local K_SLOAD = keys.K_SLOAD
local K_TEMP_DISABLE = keys.K_TEMP_DISABLE
local K_URL2ID = keys.K_URL2ID
local K_WORKER = keys.K_WORKER
local K_XLOAD = keys.K_XLOAD

-- The self-calls that read _M.x() in the original file resolve against the
-- registry facade, late-bound below so this module loads before the facade does.
local R

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
function M.policy_hint_for_model(model_id)
    if type(model_id) ~= "string" or model_id == "" then
        return nil, 0
    end
    local records = R.records()
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

-- The Rust worker spec models both knobs as enums (core/worker.rs:423-436 and
-- :514-525), with two extra worker-type variants and a tagged non-HTTP
-- connection mode. This gateway serves the regular HTTP plane only (scope-trim.md
-- removed the transport and pool-splitting planes), so the other enum variants
-- answer 400 rather than being silently collapsed to Regular -- the same
-- deviation from Rust that the contract suite pins.
M.WORKER_TYPES = { regular = true }
M.CONNECTION_MODES = { http = true }

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
function M.parse_worker_type(value)
    if value == nil or value == cjson.null then
        return nil
    end
    if type(value) ~= "string" then
        return nil, 'worker_type must be a string (only "regular" is supported)'
    end
    if keyword(value, R.WORKER_TYPES) ~= "regular" then
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
function M.parse_connection_mode(value)
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

    if kind ~= nil and keyword(kind, R.CONNECTION_MODES) ~= "http" then
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
function M.parse_spec_url(url)
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
    return R.normalize_url(url)
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
M.needs_models_refresh = needs_models_refresh


-- ------------------------------------------------- upstream capability capture
--
-- 对外 /v1/models 要按 OpenAI 生态的丰富形状输出（capabilities.context_length、
-- reasoning_efforts[] 等），而那些数字只存在于上游 /v1/models 的回答里。原来的探针
-- 只取 data[].id，其余字段当场丢弃，于是网关对"这个实例到底能干什么"一无所知，
-- 输出面就只能报 {id, object, owned_by}。这一块负责**先把它留住**：
--   * probe_advertised_entries()  -- 拿上游答的完整 data[] 条目（原样，不归一）
--   * model_caps_from_entries()    -- 纯函数，把条目归一成统一形状（可单测、可注入）
--   * _M.model_caps()              -- 跨 worker 汇总，按"最完整的那份"合并
-- 三条口径写在这里，是因为它们都是"宁缺勿假"的具体形态：
--   1. **绝不猜、绝不填默认值**。上游没给的字段留 nil（整个表里没有这个 key），
--      下游输出面据此决定"报已知"还是"不报"。一个编出来的 context_length 会被
--      客户端当作事实拿去做预算，比不报糟糕得多。
--   2. **采集失败不影响转发**。这里所有函数都不碰健康位、不碰熔断，解析异常一律
--      吞掉（AGENTS.md 硬规则 4：转发路径上的探测失败只损失精度）。
--   3. **来源可追溯**。同一字段多处都有时按 capabilities.* > 顶层同名字段 >
--      max_model_len 取值，顺序就是"上游说得有多明确"，不是"我更喜欢哪个"。

function M.add(req, cfg)
    if type(req) ~= "table" then
        return nil, "invalid worker config", "validation"
    end
    local worker_type, type_err = R.parse_worker_type(req.worker_type)
    if type_err then
        return nil, type_err, "validation"
    end
    local mode, mode_err = R.parse_connection_mode(req.connection_mode)
    if mode_err then
        return nil, mode_err, "validation"
    end
    local url, err = R.parse_spec_url(req.url)
    if not url then
        return nil, err, "validation"
    end

    local id = R.worker_id_for_url(url)

    local ok, lerr = with_lock(function()
        local d = shdict()
        if d:get(K_URL2ID .. url) then
            -- Idempotent: the URL keeps its id and the duplicate surfaces as a
            -- failed job, matching the Rust create_worker step.
            R.set_job(url, "add_worker", "failed",
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
            -- Engine-answered capabilities ride the same record (see the capability
            -- capture block). Stored only when the caller actually has a captured map
            -- -- normally the watcher or a DP rank's inheritance -- so a registration
            -- without it keeps its exact pre-feature record shape.
            model_caps = clone_model_caps(rawget(req, "model_caps")),
            priority = tonumber(req.priority) or 50,
            cost = tonumber(req.cost) or 1.0,
            -- Per-worker capacity ceilings (doc/caps-redesign-2026-10-06.md section 1):
            -- stored only when a usable limit was declared, so a record built without
            -- them keeps its exact pre-feature shape and the verdict short-circuits on
            -- "all three absent" before it touches a dict. Every registration entry
            -- point (POST /workers, the watcher, the config declaration layer, the
            -- bootstrap seed, DP ranks) gets them from here rather than its own
            -- call site, which is what keeps the four paths identical. The scheduler's
            -- busy-side knob is the utilisation percent (`max_gpu_util`, whose
            -- meaningful zero is why it normalizes through util_limit, not cap_limit).
            -- `min_concurrency` is the lower rung of the three-way verdict and is
            -- absent-equivalent-to-1, so it is stored the same way rather than defaulted.
            max_concurrency = R.cap_limit(rawget(req, "max_concurrency"), true),
            min_concurrency = R.cap_limit(rawget(req, "min_concurrency"), true),
            max_gpu_util = R.util_limit(rawget(req, "max_gpu_util")),
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
        d:set(K_HSEL .. id, R.record_http_selectable(record) and 1 or 0)
        -- A fresh worker starts unhealthy until its first health check passes,
        -- unless health checks are disabled for it.
        d:set(K_HEALTH .. id, record.disable_health_check and 1 or 0)
        d:set(K_HFAIL .. id, 0)
        d:set(K_HSUCC .. id, 0)
        d:set(K_CBSTATE .. id, keys.CB_CLOSED)
        d:set(K_CBF .. id, 0)
        d:set(K_CBS .. id, 0)
        d:set(K_LOAD .. id, 0)
        d:set(K_ACTIVE .. id, 0)  -- 从未活跃过，让第一次巡检会探它
        -- A re-registration is a new engine behind the url: whatever the previous
        -- owner's GPU was doing has no right to describe this one, so the external
        -- channels start empty (the load source refills them on its tick).
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

    -- Pool drift must reach the self-healing timer (see the reconcile-coupling
    -- block near shdict): drop the applied-revision token unless this add is
    -- part of an ongoing guarded reconcile pass.
    invalidate_applied_rev()

    -- Queued rather than synchronous: the caller answers 202 either way.
    if not shdict():get(K_WORKER .. id) then
        R.set_job(url, "add_worker", "pending", nil)
    end
    mesh_mirror(id)
    return { id = id, url = url, location = "/workers/" .. id, status = "accepted" }
end

---Remove a worker by id and free its URL so the URL can be re-registered.
---@param worker_id string
---@return table|nil result @ {worker_id, url}
---@return string|nil err
function M.remove(worker_id)
    local id, perr = R.parse_worker_id(worker_id)
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
                                K_TEMP_DISABLE,
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
function M.get(worker_id)
    local id, perr = R.parse_worker_id(worker_id)
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
    return R.info(record, d)
end

---@param record table @ decoded static record
---@param d ngx.shared.Dict|nil
---@return table
function M.info(record, d)
    d = d or shdict()
    local id = record.id
    local labels = record.labels or {}
    local metadata = {}
    for k, v in pairs(labels) do
        metadata[k] = tostring(v)
    end
    local job
    if record.url then
        job = R.get_job(record.url)
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
        load = R.load_with(d, id),
        connection_mode = record.connection_mode or "http",
        metadata = metadata,
        disable_health_check = record.disable_health_check or false,
        job_status = job,
        -- The three ceilings and their live readings (doc/caps-redesign-2026-10-06.md
        -- section 1-2). A ceiling that was never declared is *absent* rather than 0 --
        -- 0 would read as "a limit of zero slots" to anything that does not know
        -- cap_limit's normalization, and the console has to tell "unlimited" apart from
        -- the one rung where 0 *is* a limit (max_gpu_util, folded by util_limit).
        -- inflight_requests is the pure request count (what the concurrency ceiling
        -- compares against), which is deliberately not `load` -- that field is the
        -- ranking number and mixes in the GPU sample. gpu_util stays nil while no
        -- fresh sample exists: "unknown, not zero" is what keeps the utilisation
        -- ceiling safe to leave switched on.
        max_concurrency = R.cap_limit(record.max_concurrency),
        min_concurrency = R.cap_limit(record.min_concurrency),
        max_gpu_util = R.util_limit(record.max_gpu_util),
        -- The verdict itself (doc/caps-redesign-2026-10-06.md section 2): read-only, and
        -- computed here rather than in the browser. The pool table colours with this
        -- value and the router trims its candidate array with the same call, so neither
        -- side can drift into a private definition of "full". Absent when the worker
        -- declares no ceiling at all -- an explicit null would make an uncapped row look
        -- like a state the gateway refused to name.
        load_state = R.capacity_state(record, d),
        inflight_requests = d:get(K_LOAD .. id) or 0,
        -- The live reading the utilisation ceiling compares against, in the 0..1 shape
        -- the exporter publishes it in. Nil = no fresh sample = unknown.
        gpu_util = (function()
            local milli = d:get(K_GPU_UTIL .. id)
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
function M.list()
    local d = shdict()
    local out = {}
    local records = R.records()
    for i = 1, #records do
        out[#out + 1] = R.info(records[i], d)
    end
    return out
end

---Raw static records (used by the health checker, router and policy timers).
---@return table[]
function M.records()
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
function M.record(id)
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
function M.record_http_selectable(record)
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
function M.set_http_selectable(id, record)
    shdict():set(K_HSEL .. id, R.record_http_selectable(record) and 1 or 0)
end

---HTTP-plane availability. Missing flag = record written by an older build, so
---fall back to decoding it once and cache the answer.
---@param id string
---@return boolean
function M.http_selectable(id)
    local d = shdict()
    local flag = d:get(K_HSEL .. id)
    if flag ~= nil then
        return flag == 1
    end
    local raw = d:get(K_WORKER .. id)
    if not raw then
        return false
    end
    local selectable = R.record_http_selectable(json_decode(raw)) and 1 or 0
    d:set(K_HSEL .. id, selectable)
    return selectable == 1
end

---@return string[] @ distinct model ids with at least one worker
function M.models()
    local seen, out = {}, {}
    local records = R.records()
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
function M.all_models()
    local seen, out = {}, {}
    local records = R.records()
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
function M.worker_models(id)
    if type(id) ~= "string" or id == "" then
        return {}
    end
    return models_of(R.record(id))
end

--- Advertised list of an already-decoded record, exported so the config layer can
--- build its registered-model table (which wants every advertised name, not one
--- column) without reimplementing the primary-first ordering rule.
---@param record table|nil
---@return table
function M.record_models(record)
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
function M.http_workers()
    local ok_records, records = pcall(R.records)
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
function M.worker_serves_model(id_or_record, model)
    if type(model) ~= "string" or model == "" then
        return nil
    end
    local record
    if type(id_or_record) == "table" then
        record = id_or_record
    elseif type(id_or_record) == "string" and id_or_record ~= "" then
        record = R.record(id_or_record)
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
function M.models_are_verified(id_or_record)
    local record
    if type(id_or_record) == "table" then
        record = id_or_record
    elseif type(id_or_record) == "string" and id_or_record ~= "" then
        record = R.record(id_or_record)
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
function M.candidate_allows_model(id_or_record, model)
    if type(model) ~= "string" or model == "" then
        return true
    end
    local verdict = R.worker_serves_model(id_or_record, model)
    if verdict ~= false then
        return true
    end
    -- 用显式分支而不是 "verified and false or true"：Lua 里那个式子恒为 true
    -- （false 会落到 or 的右侧），等于把唯一的排除条件写没了。
    if R.models_are_verified(id_or_record) then
        return false
    end
    return true
end

-- ------------------------------------------------------------------ live state

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
    -- model_caps 与 models 同批落地，并共用 models_replace 这个"引擎亲口答过"的印章：
    -- 能力读数与覆盖列表必须来自同一次 /v1/models 观测，否则会出现"列表说没有这个模型、
    -- 能力表还在对外报它"的分裂。见 _M.probe_advertised_entries 的注释。
    local caps_patch, caps_seen = nil, false
    for key, value in pairs(patch) do
        if key == "models" then
            models_patch, models_seen = value, true
        elseif key == "model_caps" then
            caps_patch, caps_seen = value, true
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
    if caps_seen or (opts and opts.models_replace) then
        -- 观测（models_replace）时整表重建：引擎这次没提到的模型、以及提到但没给任何能力
        -- 字段的模型，其条目都要走掉——和 models 的 replace 语义同一个理由，那份列表是
        -- 唯一陈述覆盖面与能力的来源。非观测的补丁（操作员/配置层）只并集，绝不清空：
        -- 人在打字说他知道什么，不等于引擎说别人不知道。
        local next_caps
        if caps_seen and opts and opts.models_replace then
            next_caps = clone_model_caps(caps_patch)
        elseif caps_seen then
            next_caps = clone_model_caps(record.model_caps) or {}
            local incoming = clone_model_caps(caps_patch)
            for name, entry in pairs(incoming or {}) do
                -- 逐模型整条替换：同一模型的旧读数可能来自已经重启过的引擎，
                -- 逐字段并只会让它的新旧两代混在一份里。
                next_caps[name] = entry
            end
            if next_caps ~= nil and next(next_caps) == nil then
                next_caps = nil
            end
        else
            next_caps = clone_model_caps(record.model_caps)
        end
        if next_caps and opts and opts.models_replace then
            -- Prune against the list the engine just gave, so a model it dropped cannot
            -- keep being advertised with capabilities.
            local keep = {}
            if type(record.models) == "table" then
                for i = 1, #record.models do
                    keep[record.models[i]] = true
                end
            end
            if type(record.model_id) == "string" and record.model_id ~= "unknown" then
                keep[record.model_id] = true
            end
            local kept = {}
            local kept_any = false
            for name, entry in pairs(next_caps) do
                if keep[name] then
                    kept[name] = entry
                    kept_any = true
                end
            end
            next_caps = kept_any and kept or nil
        end
        -- 内容比较而不是引用比较：巡检每轮都带同一份读数回来，用 ~={} 会每次都重写记录
        -- （连带 mesh 镜像与 applied-revision 抖动）。
        if not caps_equal(record.model_caps, next_caps) then
            record.model_caps = next_caps
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
        d:set(K_HSEL .. id, R.record_http_selectable(record) and 1 or 0)
        mesh_mirror(id)
    end
    return record
end

-- Late-bind the facade: registry.lua pre-registers package.loaded before it
-- requires this module, and a test that swaps the whole module table for a stub
-- through package.loaded is honoured by the same lookup.
R = package.loaded["resty.luarouter.registry"] or require "resty.luarouter.registry"


-- Published for the registry siblings and the facade.
M.needs_models_refresh = needs_models_refresh
M.norm_models = norm_models
M.patch_record = patch_record

return M
