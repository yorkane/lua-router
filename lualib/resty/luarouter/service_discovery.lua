-- DP-aware worker expansion and Kubernetes pod service discovery.
--
-- Two independent features share this module because both answer the same
-- question - "what should the registry actually contain?" - one rank or pod at a
-- time, and both run from worker 0's timers rather than from the request path.
--
-- A. DP-aware (SMG_DP_AWARE). A worker whose /server_info reports dp_size > 1
--    is a data-parallel engine: one HTTP front, dp_size independent scheduler
--    ranks behind it. The Rust gateway models that as dp_size registry entries
--    whose url is "<base>@<rank>" (DPAwareWorkerBuilder,
--    gateway/src/core/worker_builder.rs:316), each with its own health counters,
--    load and circuit breaker. This module reproduces that expansion:
--
--      * triggered from registry.discover() (the metadata hook the health sweep
--        already calls), never from router.lua, so the forwarding path is untouched;
--      * one entry per rank at "<base>@<rank>", so a policy that keys on url
--        (cache_aware, manual, ring) naturally treats ranks as separate tenants,
--        exactly as the Rust gateway does;
--      * the rank suffix is stripped again by registry.split_url(), which every
--        cosocket connect goes through, so "<base>@0" remains dialable;
--      * /server_info failing (engine still booting, endpoint absent, 5xx) does
--        NOT expand: the base worker is kept as a single entry. The Rust gateway
--        fails the create_worker step instead; a router that drops a reachable
--        worker because one metadata call failed is worse than one that keeps it.
--
--- B. Kubernetes discovery (SMG_SERVICE_DISCOVERY). Two transports share one
--    reconcile: the poll loop (the default, one GET /api/v1[/namespaces/<ns>]/pods
--    with a labelSelector per SMG_SERVICE_DISCOVERY_CHECK_INTERVAL_SECS) and, when
--    SMG_SERVICE_DISCOVERY_WATCH is on, a kube watch stream like the Rust
--    gateway's (gateway/src/service_discovery.rs) - a long-lived chunked response
--    whose ADDED/MODIFIED/DELETED events update the tracked pod set in place,
--    resuming from the last resourceVersion and relisting after a 410. The poll
--    stays the default because it is the accepted contract (doc/gap-discovery-watch.md),
--    and it stays the fallback: a watch that cannot be held degrades to listing.
--    SMG_KUBE_FIELD_SELECTOR adds equality fieldSelector terms to both paths.
--
--    C. Router-pod discovery (SMG_ROUTER_SELECTOR). Pods matching it are not
--    workers: they become mesh peers (see mesh.adopt_member), which is what
--    replaces a hand-written SMG_MESH_PEERS list. The pod -> worker rules (Running + Ready + podIP, http://<podIP>:<port>, prefill
--    / decode classification, the sglang.ai/bootstrap-port annotation) follow
--    PodInfo::from_pod / PodInfo::is_healthy so both gateways pick the same pods.
--
-- Everything that decides *what* to register is a pure function in this file
-- (parse_selector, pod_from_api, desired_workers, plan, expansion_plan,
-- inject_dp_rank) so it is unit-testable under luajit without ngx; only
-- poll_once() and start() touch ngx / cosockets.

local cjson = require "cjson.safe"

local _M = { _VERSION = "0.1.0" }

local json_decode = cjson.decode

_M.SOURCE = "kubernetes"
_M.BOOTSTRAP_PORT_ANNOTATION = "sglang.ai/bootstrap-port"
-- Default annotation for a router pod's mesh port, and the fallback when the
-- config knob is empty. Rust disagrees with itself here (config/types.rs:380 vs
-- main.rs:947); types.rs is used, see config.lua and doc/gap-discovery-watch.md.
_M.ROUTER_MESH_PORT_ANNOTATION = "sglang.ai/mesh-port"

-- A worker that never answers /server_info stays a single-entry worker after
-- this many probes. The metadata-discovery attempt ceiling in registry.discover
-- is the same order (20), so the two bounded retries end together.
local MAX_DP_ATTEMPTS = 20
_M.MAX_DP_ATTEMPTS = MAX_DP_ATTEMPTS

-- ------------------------------------------------------------------ selectors

---Parse a Kubernetes label selector ("a=b,c=d"; commas or spaces).
---@param text string|nil
---@return table map @ label name -> required value (empty table when unset)
function _M.parse_selector(text)
    local out = {}
    if type(text) ~= "string" then
        return out
    end
    for term in string.gmatch(text, "[^,%s]+") do
        -- Split on the FIRST '=' only: a value may legitimately contain one.
        local name, value = term:match("^([^=]+)=(.*)$")
        if name and value ~= "" then
            out[name] = value
        end
    end
    return out
end

---Canonical selector text for a labelSelector query parameter. Sorted so the
---generated URL is stable across polls (a log-grep or a fixture has to match).
---@param map table
---@return string @ "a=b,c=d", empty string for an empty selector
function _M.selector_string(map)
    local parts = {}
    for name, value in pairs(map or {}) do
        parts[#parts + 1] = name .. "=" .. tostring(value)
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

---True when every selector pair appears in the pod labels with that value.
---An empty selector matches nothing (Rust matches_selector returns false for the
---empty map, which is what keeps "no prefill_selector" from claiming every pod).
---@param labels table|nil
---@param selector table
---@return boolean
function _M.selector_matches(labels, selector)
    if type(labels) ~= "table" then
        return false
    end
    local pairs_count = 0
    for name, value in pairs(selector or {}) do
        if labels[name] ~= value then
            return false
        end
        pairs_count = pairs_count + 1
    end
    return pairs_count > 0
end

---------------------------------------------------------------------------
-- A. DP-aware expansion
---------------------------------------------------------------------------

---Split a DP-aware worker url into base url and rank.
---
---A rank suffix is only recognised when it is a trailing "@" followed by digits
---and nothing else, which mirrors BasicWorker::normalised_url in
---gateway/src/core/worker.rs:680 (rfind('@') plus a numeric tail). A userinfo
---"user:pass@host" url therefore keeps its authority untouched because the tail
---after '@' is not all digits.
---@param url string
---@return string url, number|nil rank
function _M.strip_dp_rank(url)
    if type(url) ~= "string" then
        return url, nil
    end
    local at = url:find("@[^@]*$")
    if not at then
        return url, nil
    end
    local tail = url:sub(at + 1)
    if tail == "" or not tail:match("^%d+$") then
        return url, nil
    end
    return url:sub(1, at - 1), tonumber(tail)
end

---Read dp_size out of a decoded /server_info body.
---
---Both spellings seen in the wild are accepted: the sglang engine reports
---dp_size at the top level, and some builds nest it under "server_args".
---@param info table|nil
---@return number|nil dp_size
function _M.dp_size_from_server_info(info)
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
---The caller (registry) owns the writes; this function only classifies so the
---decision is unit-testable without a shared dict.
---@param dp_size number|nil @ parsed from /server_info, nil when unavailable
---@param attempts number @ probes already spent on this record
---@return string action @ "expand" | "single" | "retry" | "give_up"
---@return number|nil dp_size @ effective fan-out width for "expand"
function _M.expansion_plan(dp_size, attempts)
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
---is copied from the base record (model id, priority, cost, api key, connection
---identity, health tuning, labels); the rank identity goes in dp_rank/dp_size/
---dp_base_url plus a dp_aware marker so a later teardown can find them again.
---@param base table @ stored record for the base url
---@param dp_size number
---@param meta table|nil @ {model_id, labels} learned from the probe body
---@return table[] @ one POST /workers-shaped request per rank
function _M.expansion_requests(base, dp_size, meta)
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
            -- Inherit the source: a DP engine found through Kubernetes stays a
            -- Kubernetes worker per rank, so the pod reconcile keeps owning them
            -- (and a manual worker stays manual).
            discovery = base.discovery,
        }
    end
    return out
end

---Find the byte range of a top-level member in a JSON object.
---
---Depth-aware on purpose: a naive search for the key name also hits a *nested*
---member with the same name (a tool call's arguments blob can carry one), and
---rewriting that would corrupt the payload. Splices therefore have to know the
---brace depth, which costs one forward scan with an escape-aware string state
---machine - the same cost class as the router's "model" rewrite.
---@param raw string
---@param field string
---@param start number @ 1-based byte offset of the object's opening brace
---@return number|nil member_from, number|nil member_to, number|nil insert_at
---@return   @ member range spans "field": value; insert_at is the offset just
---@return   @ after the opening brace (where a new first member goes)
local function find_top_member(raw, field, start)
    local needle = '"' .. field .. '"'
    local depth = 0
    local i = start
    local n = #raw
    while i <= n do
        local c = raw:sub(i, i)
        if c == '"' then
            -- Skip the whole string literal, honouring backslash escapes.
            local j = i + 1
            while j <= n do
                local d = raw:sub(j, j)
                if d == "\\" then
                    j = j + 2
                elseif d == '"' then
                    break
                else
                    j = j + 1
                end
            end
            if depth == 1 and j - i + 1 == #needle and raw:sub(i, j) == needle then
                -- Confirm it is a key: the next non-space character is ':'.
                local k = j + 1
                while k <= n and raw:sub(k, k):match("^[%s]$") do
                    k = k + 1
                end
                if raw:sub(k, k) == ":" then
                    local v = k + 1
                    while v <= n and raw:sub(v, v):match("^[%s]$") do
                        v = v + 1
                    end
                    -- Value span: stop at the first top-level ',' or the '}'
                    -- that closes the object, skipping over nested containers
                    -- and string literals.
                    local scan = v
                    local inner = 0
                    while scan <= n do
                        local e = raw:sub(scan, scan)
                        if e == '"' then
                            scan = scan + 1
                            while scan <= n do
                                local q = raw:sub(scan, scan)
                                if q == "\\" then
                                    scan = scan + 2
                                elseif q == '"' then
                                    break
                                else
                                    scan = scan + 1
                                end
                            end
                        elseif e == "{" or e == "[" then
                            inner = inner + 1
                        elseif e == "}" or e == "]" then
                            if inner == 0 then
                                break
                            end
                            inner = inner - 1
                        elseif (e == "," or e == "}") and inner == 0 then
                            break
                        end
                        scan = scan + 1
                    end
                    local member_to = scan - 1
                    while member_to >= v and raw:sub(member_to, member_to):match("^[%s]$") do
                        member_to = member_to - 1
                    end
                    return i, member_to, start + 1
                end
            end
            i = j + 1
        elseif c == "{" or c == "[" then
            depth = depth + 1
            i = i + 1
        elseif c == "}" or c == "]" then
            depth = depth - 1
            if depth == 0 then
                return nil, nil, start + 1
            end
            i = i + 1
        else
            i = i + 1
        end
    end
    return nil, nil, start + 1
end

---Offset of the object's first `{`, or nil when the payload is not an object.
---@param raw string
---@return number|nil
local function object_start(raw)
    return raw:find("{", 1, true)
end

---Inject "data_parallel_rank" into a raw JSON payload.
---
---Splices the top-level member in place (rewrite when present, prepend when
---absent) rather than decoding and re-encoding: the forwarding path must not
---reorder or reformat the client's body, which is the same rule router.lua's
---set_top_field follows for "model" and "reasoning_effort".
---
---Integration note: router.lua is owned by another agent, so nothing calls this
---from the forwarding path yet. It is exported and unit-tested so the one-line
---hook can be added there independently; doc/gap-discovery-dp.md records the
---exact call site.
---@param raw string @ request body
---@param record table @ selected worker record (rank read from dp_rank)
---@return string raw, boolean changed
function _M.inject_dp_rank(raw, record)
    if type(raw) ~= "string" or raw == "" or type(record) ~= "table" then
        return raw, false
    end
    local rank = tonumber(record.dp_rank)
    if not rank then
        return raw, false
    end
    local start = object_start(raw)
    if not start then
        return raw, false
    end
    local member_from, member_to, insert_at = find_top_member(raw, "data_parallel_rank", start)
    if member_from then
        return raw:sub(1, member_from - 1) .. '"data_parallel_rank":' .. rank
            .. raw:sub(member_to + 1), true
    end
    -- Absent: prepend as the first member. An empty object needs no comma.
    local rest = raw:sub(insert_at)
    if rest:match("^%s*}") then
        return raw:sub(1, insert_at - 1) .. '"data_parallel_rank":' .. rank .. "}", true
    end
    return raw:sub(1, insert_at - 1) .. '"data_parallel_rank":' .. rank .. "," .. rest, true
end

---------------------------------------------------------------------------
-- B. Kubernetes discovery
---------------------------------------------------------------------------

local function label_strings(labels)
    local out = {}
    if type(labels) == "table" then
        for k, v in pairs(labels) do
            out[tostring(k)] = tostring(v)
        end
    end
    return out
end

---Extract the fields the discovery loop needs from one /api/v1/pods item.
---Returns nil for a pod that cannot be turned into a worker at all (no name, no
---podIP, or claimed by none of the selectors), which is a different thing from an
---unhealthy pod: the latter has to survive as a PodInfo so the reconcile can
---*deregister* it.
---@param pod table @ decoded items[] element
---@param opts table @ {selector, prefill_selector, decode_selector, pd_mode}
---@return table|nil pod_info
function _M.pod_from_api(pod, opts)
    if type(pod) ~= "table" then
        return nil
    end
    opts = opts or {}
    -- fieldSelector is re-checked locally for the same reason labelSelector is:
    -- a fake API server, or a cluster whose field support differs, must not be
    -- able to widen the set the operator asked for.
    if not _M.field_matches(pod, opts.field_selector) then
        return nil
    end
    local meta = type(pod.metadata) == "table" and pod.metadata or {}
    local name = type(meta.name) == "string" and meta.name or nil
    if not name or name == "" then
        return nil
    end
    local status = type(pod.status) == "table" and pod.status or {}
    local pod_ip = type(status.podIP) == "string" and status.podIP or nil
    if not pod_ip or pod_ip == "" then
        return nil
    end
    local phase = type(status.phase) == "string" and status.phase or ""

    -- conditions[] is where the readiness gate lives; a pod whose Ready flips to
    -- False has to unregister, so read it even when the phase is something else.
    local is_ready = false
    local conditions = type(status.conditions) == "table" and status.conditions or {}
    for i = 1, #conditions do
        local cond = conditions[i]
        if type(cond) == "table" and cond.type == "Ready" and cond.status == "True" then
            is_ready = true
        end
    end

    local labels = label_strings(meta.labels)

    -- A pod that carries the router selector is a gateway, not an engine. Rust
    -- flags it (PodInfo::is_router) and drops it before registration; the same
    -- rule here is what keeps --router-selector from load-balancing inference
    -- onto the routers themselves.
    if opts.router_selector and next(opts.router_selector) ~= nil
        and _M.selector_matches(labels, opts.router_selector) then
        return nil
    end

    -- Classification mirrors PodInfo::from_pod: prefill wins over decode, and a
    -- selector-less PD mode claims nothing.
    local pod_type
    if opts.pd_mode then
        if _M.selector_matches(labels, opts.prefill_selector) then
            pod_type = "prefill"
        elseif _M.selector_matches(labels, opts.decode_selector) then
            pod_type = "decode"
        elseif _M.selector_matches(labels, opts.selector) then
            pod_type = "regular"
        end
    elseif _M.selector_matches(labels, opts.selector) then
        pod_type = "regular"
    end
    if not pod_type then
        return nil
    end

    local bootstrap_port
    if pod_type == "prefill" then
        local annotations = type(meta.annotations) == "table" and meta.annotations or {}
        local port = tonumber(annotations[_M.BOOTSTRAP_PORT_ANNOTATION])
        if port and port == math.floor(port) and port >= 1 and port <= 65535 then
            bootstrap_port = port
        end
    end

    return {
        name = name,
        ip = pod_ip,
        status = phase,
        is_ready = is_ready,
        pod_type = pod_type,
        bootstrap_port = bootstrap_port,
        labels = labels,
        -- deletionTimestamp is how Kubernetes says "this one is on its way out";
        -- the watch's DELETED event usually arrives first, but a poll only ever
        -- sees the object, so carry the mark either way.
        deleting = (type(meta.deletionTimestamp) == "string"
            and meta.deletionTimestamp ~= "") and true or nil,
    }
end

---Rust parity: PodInfo::is_healthy is Ready && phase == Running.
---@param pod_info table
---@return boolean
function _M.pod_is_healthy(pod_info)
    return (pod_info.is_ready and true or false) and pod_info.status == "Running"
end

---http://<podIP>:<port> (PodInfo::worker_url).
---@param pod_info table
---@param port number
---@return string
function _M.pod_worker_url(pod_info, port)
    return string.format("http://%s:%d", pod_info.ip, port)
end

---Decode a pods list response into the PodInfo set that the current selectors
---claim. Unhealthy pods are kept so the reconcile can notice they disappeared.
---@param doc table|nil @ decoded /api/v1/pods body
---@param opts table @ same shape as pod_from_api opts
---@return table[] infos
function _M.pod_infos(doc, opts)
    local out = {}
    if type(doc) ~= "table" then
        return out
    end
    local items = type(doc.items) == "table" and doc.items or {}
    for i = 1, #items do
        local info = _M.pod_from_api(items[i], opts)
        if info then
            out[#out + 1] = info
        end
    end
    return out
end

---Translate the discovered pods into POST /workers-shaped registrations.
---@param infos table[]
---@param port number
---@param opts table @ {pd_mode, api_key}
---@return table[] requests
function _M.desired_workers(infos, port, opts)
    opts = opts or {}
    local out = {}
    for i = 1, #infos do
        local info = infos[i]
        if _M.pod_is_healthy(info) then
            local labels = {}
            for k, v in pairs(info.labels or {}) do
                labels[k] = v
            end
            labels.discovered = "kubernetes"
            local req = {
                url = _M.pod_worker_url(info, port),
                labels = labels,
                api_key = opts.api_key,
                discovery = _M.SOURCE,
                pod_name = info.name,
            }
            if opts.pd_mode and info.pod_type ~= "regular" then
                req.worker_type = info.pod_type
                if info.pod_type == "prefill" and info.bootstrap_port then
                    req.bootstrap_port = info.bootstrap_port
                    labels.bootstrap_port = tostring(info.bootstrap_port)
                end
                -- pd.pool_of also reads labels.worker_type, so the pool identity
                -- survives on the record even where worker_type itself is gated
                -- (registry.parse_worker_type rejects prefill/decode unless the
                -- gRPC plane is enabled - see the limit note in the doc).
                labels.worker_type = info.pod_type
            end
            out[#out + 1] = req
        end
    end
    return out
end

---The url a registry entry answers for: its DP base when it is a rank.
---
---Discovery speaks in pod urls, while a data-parallel engine is stored as
---"<pod url>@<rank>" entries (and the base entry only exists between registration
---and the first sweep). Comparing the two forms literally would make every poll
---"discover" the pod again, delete the ranks it already has, and re-expand them -
---the engine would flap once per interval, losing rank health state each time.
---Keying on the base url makes the diff stable in both directions: a rank counts
---as its pod, and a pod that disappears takes all of its ranks with it.
---@param record table
---@return string key
local function coverage_key(record)
    return record.dp_base_url or record.url
end

_M.coverage_key = coverage_key

---Diff the desired worker set against what discovery registered before.
---@param desired table[] @ requests from desired_workers
---@param current table[] @ records with discovery == "kubernetes"
---@return table[] to_add, table[] to_remove
function _M.plan(desired, current)
    desired = desired or {}
    current = current or {}
    local wanted = {}
    for i = 1, #desired do
        wanted[desired[i].url] = desired[i]
    end
    local seen = {}
    for i = 1, #current do
        seen[coverage_key(current[i])] = true
    end
    local to_add = {}
    for i = 1, #desired do
        if not seen[desired[i].url] then
            to_add[#to_add + 1] = desired[i]
        end
    end
    local to_remove = {}
    for i = 1, #current do
        if not wanted[coverage_key(current[i])] then
            to_remove[#to_remove + 1] = current[i]
        end
    end
    return to_add, to_remove
end

---Percent-encode the handful of characters a labelSelector can carry.
---@param text string
---@return string
function _M.url_encode(text)
    return (tostring(text):gsub("[^%w%-_%.~]", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

---List path for one poll: namespace-scoped when configured (cheaper, and the RBAC
---role usually only covers it), cluster-scoped otherwise.
---@param api string @ base url, no trailing slash
---@param namespace string|nil
---@param selector string @ canonical selector text (may be "")
---@return string url
function _M.pods_url(api, namespace, selector)
    local base = tostring(api or "")
    if namespace and namespace ~= "" then
        base = base .. "/api/v1/namespaces/" .. namespace .. "/pods"
    else
        base = base .. "/api/v1/pods"
    end
    if selector and selector ~= "" then
        base = base .. "?labelSelector=" .. _M.url_encode(selector)
    end
    return base
end

-- ------------------------------------------------------------------ fieldSelector
--
-- Kubernetes' field selectors are a small fixed vocabulary, not the label
-- language: only equality on a handful of fields is supported by the API server,
-- and each field has its own allowed operators. This client honours the equality
-- spellings ("k=v" and "k==v") and refuses anything else, in both directions:
-- an unsupported term is never sent to the API server, and a pod carrying a
-- term the client cannot evaluate matches nothing. Guessing at a selector is
-- how a gateway ends up routing to pods the operator explicitly excluded.

---Parse a fieldSelector into terms.
---@param text string|nil
---@return table[] @ array of {key, value} or {unsupported = raw term}
function _M.parse_field_selector(text)
    local out = {}
    if type(text) ~= "string" then
        return out
    end
    for term in string.gmatch(text, "[^,%s]+") do
        -- Only the two equality spellings are recognised, and the key may not
        -- contain an operator character: that is what turns "app!=sglang",
        -- "phase>Running" and a bare "app" into unsupported terms rather than
        -- equality tests against a nonsense value ("!sglang" would otherwise look
        -- like a value no pod has, which happens to match nothing but for the
        -- wrong reason and is invisible at startup).
        local key, value = term:match("^([^=!<>]+)==(.+)$")
        if not key then
            key, value = term:match("^([^=!<>]+)=(.+)$")
        end
        if key and key ~= "" and value and value ~= "" then
            out[#out + 1] = {
                key = key, value = value,
                -- Canonical text normalises "==" onto "=", so the same selector
                -- produces the same URL however the operator was spelled.
                raw = key .. "=" .. value,
            }
        else
            out[#out + 1] = { unsupported = term }
        end
    end
    return out
end

---Canonical fieldSelector text. Unsupported terms are carried verbatim so the
---refusal is visible in the request path (and in a fake server's log) rather
---than silently dropped.
---@param specs table[]
---@return string
function _M.field_selector_text(specs)
    local parts = {}
    for i = 1, #(specs or {}) do
        parts[#parts + 1] = specs[i].raw or specs[i].unsupported
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

---True when the raw pod object satisfies every term. Supported fields follow
---the API server's selectable fields for pods; anything else refuses the pod.
---@param pod table|nil @ decoded items[] element (raw API shape)
---@param specs table[]
---@return boolean
function _M.field_matches(pod, specs)
    if type(specs) ~= "table" or #specs == 0 then
        return true
    end
    if type(pod) ~= "table" then
        return false
    end
    local meta = type(pod.metadata) == "table" and pod.metadata or {}
    local status = type(pod.status) == "table" and pod.status or {}
    local spec = type(pod.spec) == "table" and pod.spec or {}
    for i = 1, #specs do
        local term = specs[i]
        if term.unsupported then
            return false
        end
        local actual
        if term.key == "metadata.name" then
            actual = meta.name
        elseif term.key == "metadata.namespace" then
            actual = meta.namespace
        elseif term.key == "status.phase" then
            actual = status.phase
        elseif term.key == "status.podIP" then
            actual = status.podIP
        elseif term.key == "spec.nodeName" then
            actual = spec.nodeName
        else
            -- Unknown field: the API server would reject it, and a client that
            -- ignored it would widen the set. Refuse instead.
            return false
        end
        if tostring(actual or "") ~= term.value then
            return false
        end
    end
    return true
end

---True when a term cannot be honoured. Used to say so once at startup rather
---than let the loop quietly register nothing.
---@param specs table[]
---@return string|nil @ the first unsupported term
function _M.unsupported_field_term(specs)
    for i = 1, #(specs or {}) do
        if specs[i].unsupported then
            return specs[i].unsupported
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- B.2 Kubernetes watch stream
---------------------------------------------------------------------------

---List URL for one pass: the pods path plus labelSelector and fieldSelector.
---pods_url owns the path and the labelSelector so its existing behaviour (and
---its unit tests) stay untouched; this only adds the field selector on top.
---@param api string
---@param namespace string|nil
---@param selector string @ canonical selector text (may be "")
---@param field_text string|nil @ canonical fieldSelector text (may be "")
---@return string url
function _M.list_url(api, namespace, selector, field_text)
    local url = _M.pods_url(api, namespace, selector)
    if field_text and field_text ~= "" then
        url = url .. (string.find(url, "?", 1, true) and "&" or "?")
            .. "fieldSelector=" .. _M.url_encode(field_text)
    end
    return url
end

---Watch URL. The parameter order is fixed so a fake API server, a log grep and
---a reconnect all see the same string for the same state.
---
---allowWatchBookmarks is on because a bookmark is what keeps the resourceVersion
---fresh across a quiet cluster: without it a stream that sees no event for an
---hour can only resume from a version the API server has since compacted away.
---
---The resourceVersion is sent whenever it is known, including "0": that asks for
---"the current live set" on the first connect and is what the reconnect path
---carries after an event advanced it.
---@param api string
---@param namespace string|nil
---@param selector string
---@param field_text string|nil
---@param rv string|nil
---@return string url
function _M.watch_url(api, namespace, selector, field_text, rv)
    local parts = { "watch=true", "allowWatchBookmarks=true" }
    if selector and selector ~= "" then
        parts[#parts + 1] = "labelSelector=" .. _M.url_encode(selector)
    end
    if field_text and field_text ~= "" then
        parts[#parts + 1] = "fieldSelector=" .. _M.url_encode(field_text)
    end
    if rv ~= nil then
        parts[#parts + 1] = "resourceVersion=" .. _M.url_encode(tostring(rv))
    end
    return _M.pods_url(api, namespace, "") .. "?" .. table.concat(parts, "&")
end

---Fold one watch event into the tracked pod set.
---
---A nil pod_info means "this pod is no longer ours" - the labels stopped
---matching, it became a router pod, or it lost its podIP - which has to remove
---the entry as surely as a DELETED does. Unhealthy pods keep their entry (they
---still exist), and the reconcile drops the worker without dropping the pod.
---@param tracked table @ name -> pod_info, mutated in place
---@param evt_type string @ ADDED | MODIFIED | DELETED | BOOKMARK | ERROR
---@param pod table|nil @ event.object
---@param opts table @ pod_from_api options
---@return boolean tracked_changed
function _M.apply_watch_event(tracked, evt_type, pod, opts)
    local meta = type(pod) == "table" and type(pod.metadata) == "table"
        and pod.metadata or nil
    local name = meta and type(meta.name) == "string" and meta.name or nil
    if not name or name == "" then
        return false
    end
    if evt_type == "DELETED" then
        if tracked[name] == nil then
            return false
        end
        tracked[name] = nil
        return true
    end
    if evt_type ~= "ADDED" and evt_type ~= "MODIFIED" then
        return false
    end
    local info = _M.pod_from_api(pod, opts)
    if not info then
        if tracked[name] == nil then
            return false
        end
        tracked[name] = nil
        return true
    end
    tracked[info.name] = info
    return true
end

---ResourceVersion carried by an event object (nil when it has none).
---@param pod table|nil
---@return string|nil
function _M.event_resource_version(pod)
    if type(pod) ~= "table" or type(pod.metadata) ~= "table" then
        return nil
    end
    local rv = pod.metadata.resourceVersion
    if rv == nil then
        return nil
    end
    return tostring(rv)
end

---Turn the tracked map into the list shape the reconcile takes.
---@param tracked table
---@return table[]
function _M.tracked_infos(tracked)
    local out = {}
    for _, info in pairs(tracked or {}) do
        out[#out + 1] = info
    end
    return out
end

-- ------------------------------------------------------------------ watch metrics
--
-- Rust declares four smg_discovery_* families and none of them covers the
-- stream itself (its watch loop has no counters), so the three below are this
-- gateway's own addition: without them a resync storm is invisible until the
-- worker churn shows up in the registry.

local function count_watch_event(type_name)
    local ok, observability = pcall(require, "resty.luarouter.observability")
    if ok and type(observability) == "table" and observability.counter then
        observability.counter("smg_discovery_watch_events_total",
            { { "source", _M.SOURCE }, { "type", type_name } })
    end
end

local function count_watch_reconnect()
    local ok, observability = pcall(require, "resty.luarouter.observability")
    if ok and type(observability) == "table" and observability.counter then
        observability.counter("smg_discovery_watch_reconnects_total",
            { { "source", _M.SOURCE } })
    end
end

local function count_watch_error(kind)
    local ok, observability = pcall(require, "resty.luarouter.observability")
    if ok and type(observability) == "table" and observability.counter then
        observability.counter("smg_discovery_watch_errors_total",
            { { "source", _M.SOURCE }, { "kind", kind } })
    end
end

-- ------------------------------------------------------------------ stream reader
--
-- The watch response is a chunked stream that never ends, so hb.http_get cannot
-- be used on it: it reads the body to completion and pools the socket. Both
-- would be wrong here - there is no completion, and a socket parked mid-stream
-- must never be handed to another caller. So the stream gets its own cosocket,
-- always closed on the way out, and its own per-chunk reader.

---Read the HTTP framing of a watch response.
---@param sock table
---@return table|nil headers, string|nil err @ lowercase header table
local function read_response_headers(sock)
    local status_line, read_err = sock:receive("*l")
    if not status_line then
        return nil, "no response: " .. tostring(read_err)
    end
    local status = tonumber(string.match(status_line, "^HTTP/%d%.%d%s+(%d%d%d)"))
    if not status then
        return nil, "malformed status line: " .. tostring(status_line)
    end
    local headers = { [":status"] = status }
    repeat
        local line = sock:receive("*l")
        if line and line ~= "" then
            local name, value = string.match(line, "^([%w%-]+):%s*(.*)$")
            if name then
                headers[string.lower(name)] = value
            end
        end
    until line == nil or line == ""
    return headers
end

_M.read_response_headers = read_response_headers

---Open a watch stream.
---
---Returns a table describing the outcome rather than raising: the caller has to
---tell a 410 (drop the resourceVersion and relist) apart from a transport error
---(back off and retry from where it was), and both are ordinary events in a
---cluster where etcd compaction happens on its own schedule.
---@param cfg table
---@param url string @ full watch url
---@param read_ms number @ per-read timeout: silence this long ends the stream
---@return table result @ {kind="stream"|"gone"|"status"|"transport", sock?, code?, err?}
function _M.open_watch(cfg, url, read_ms)
    local registry = require "resty.luarouter.registry"
    local host, port, tls = registry.split_url(url)
    local request_path = string.match(url, "^[^:]+://[^/]+(/.*)$") or "/"
    local sock = ngx.socket.tcp()
    local connect_opts = registry.pool_opts(cfg, "hb", url)
    -- Never pooled: pool_opts carries the name for the keepalive path, and a
    -- held-open stream has no message boundary to be returned at.
    connect_opts.pool = nil
    connect_opts.pool_size = nil
    local connect_ms = math.max(1, tonumber(cfg.connect_timeout_secs) or 10) * 1000
    if sock.settimeouts then
        sock:settimeouts(connect_ms, connect_ms, read_ms)
    else
        sock:settimeout(connect_ms)
    end
    local ok, err = sock:connect(host, port, connect_opts)
    if not ok then
        sock:close()
        return { kind = "transport", err = "connect failed: " .. tostring(err) }
    end
    local tls_ok, tls_err = registry.tls_handshake(sock, host, tls)
    if not tls_ok then
        sock:close()
        return { kind = "transport", err = tls_err }
    end
    local headers = _M.auth_headers(cfg) or {}
    local request = "GET " .. request_path .. " HTTP/1.1\r\n"
        .. "Host: " .. host .. ":" .. port .. "\r\n"
        .. "User-Agent: lua-router/discovery\r\n"
        .. "Accept: application/json\r\n"
        -- The stream is ours alone and always closed on the way out, so tell the
        -- peer not to keep it half-referenced after we drop it.
        .. "Connection: close\r\n"
    for name, value in pairs(headers) do
        request = request .. name .. ": " .. value .. "\r\n"
    end
    request = request .. "\r\n"
    local sent, serr = sock:send(request)
    if not sent then
        sock:close()
        return { kind = "transport", err = "send failed: " .. tostring(serr) }
    end
    local response, h_err = read_response_headers(sock)
    if not response then
        sock:close()
        return { kind = "transport", err = h_err }
    end
    local status = response[":status"]
    if status == 410 then
        sock:close()
        return { kind = "gone", code = status }
    end
    if status ~= 200 then
        sock:close()
        return { kind = "status", code = status }
    end
    return {
        kind = "stream",
        sock = sock,
        chunked = type(response["transfer-encoding"]) == "string"
            and not not string.find(response["transfer-encoding"], "chunk", 1, true),
    }
end

---Consume a watch stream, calling on_event for every complete JSON object.
---
---Chunk boundaries carry no meaning: the API server may pack several events into
---one chunk or split one event across several, so lines are reassembled in a
---buffer and only decoded once their newline has arrived.
---@param sock table
---@param chunked boolean
---@param on_event fun(event: table): string|nil @ returns "stop" to end the stream
---@return string reason, string|nil detail @ "eof"|"timeout"|"closed"|"error"|"stop"
function _M.consume_watch(sock, chunked, on_event)
    local pending = ""

    local function feed_line(line)
        if line == "" then
            return nil
        end
        local event = json_decode(line)
        if type(event) ~= "table" then
            return nil
        end
        return on_event(event)
    end

    ---Drain every complete line out of the accumulate buffer.
    local function drain()
        while true do
            local find_start, find_stop = string.find(pending, "[\r\n]", 1)
            if not find_start then
                return nil
            end
            local line = string.sub(pending, 1, find_start - 1)
            -- One contiguous run of CR/LF is one terminator.
            local after = find_stop + 1
            while string.sub(pending, after, after) == "\r"
                or string.sub(pending, after, after) == "\n" do
                after = after + 1
            end
            pending = string.sub(pending, after)
            local stopped = feed_line(line)
            if stopped then
                return stopped
            end
        end
    end

    while true do
        if chunked then
            local size_line, err = sock:receive("*l")
            if not size_line then
                return (err == "timeout") and "timeout" or "closed", err
            end
            local size = tonumber(string.match(size_line, "^%x+") or "", 16)
            if not size then
                return "error", "malformed chunk size: " .. tostring(size_line)
            end
            if size == 0 then
                -- The server closed the stream normally (a 0-size chunk is the
                -- only way a chunked watch body can end).
                return "eof"
            end
            local data, derr = sock:receive(size)
            if not data then
                return (derr == "timeout") and "timeout" or "closed", derr
            end
            -- The CRLF that follows every chunk. Ignore failures: a stream that
            -- dies between the payload and its terminator is caught by the next
            -- size-line read, which is where the error actually surfaces.
            local crlf = sock:receive(2)
            if not crlf then
                return "closed", "chunk terminator missing"
            end
            pending = pending .. data
            local stopped = drain()
            if stopped then
                return stopped
            end
        else
            -- Plain (unchunked) framing: an event-per-line stream. The API
            -- server does not do this for watch, but a proxy in front of it can,
            -- and reading line by line costs nothing extra to support.
            local line, lerr = sock:receive("*l")
            if not line then
                return (lerr == "timeout") and "timeout" or "closed", lerr
            end
            local stopped = feed_line(line)
            if stopped then
                return stopped
            end
        end
    end
end

---Resolve the API server endpoint: an explicit override wins (and may be http,
---which is how the fake API server in the e2e suite is reached), otherwise the
---in-cluster service environment is used over https.
---@param cfg table
---@return string|nil api, string|nil reason
function _M.api_server(cfg)
    if cfg and cfg.kube_api_server and cfg.kube_api_server ~= "" then
        return (string.gsub(cfg.kube_api_server, "/+$", ""))
    end
    local host = os.getenv("KUBERNETES_SERVICE_HOST")
    local port = os.getenv("KUBERNETES_SERVICE_PORT") or "443"
    if not host or host == "" then
        return nil, "KUBERNETES_SERVICE_HOST is unset and SMG_KUBE_API_SERVER is empty"
    end
    -- An IPv6 service host arrives bare from the downward API and has to be
    -- bracketed to be dialable.
    if host:find(":", 1, true) then
        host = "[" .. host .. "]"
    end
    return "https://" .. host .. ":" .. port
end

---Read one service-account file. Returns nil when absent, which is how the
---"not running in a cluster" case stays silent on every poll.
---@param path string
---@return string|nil text
local function read_file(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local text = f:read("*a")
    f:close()
    if type(text) ~= "string" or text == "" then
        return nil
    end
    -- Trailing newline from the projected volume would otherwise be sent in the
    -- Authorization header and rejected as a malformed token.
    return (string.gsub(text, "%s+$", ""))
end

_M.read_file = read_file

---Headers for one list call: bearer token when the SA token exists.
---@param cfg table
---@return table|nil headers
function _M.auth_headers(cfg)
    local token = read_file(((cfg or {}).kube_sa_path or "") .. "/token")
    if not token then
        return nil
    end
    return { ["Authorization"] = "Bearer " .. token }
end

-- ------------------------------------------------------------------ log + metrics

local timer_running = false
local last_note = nil

-- One log line per distinct problem rather than one per poll: a cluster-less
-- deployment or a revoked token otherwise produces a log every interval forever.
local function note(warn, message)
    if last_note == message then
        return
    end
    last_note = message
    if not ngx or not ngx.log then
        return
    end
    ngx.log(warn and ngx.WARN or ngx.NOTICE, "luarouter: ", message)
end

local function count_reg(result)
    local ok, observability = pcall(require, "resty.luarouter.observability")
    if ok and type(observability) == "table" and observability.counter then
        observability.counter("smg_discovery_registrations_total",
            { { "source", _M.SOURCE }, { "result", result } })
    end
end

local function count_dereg(reason)
    local ok, observability = pcall(require, "resty.luarouter.observability")
    if ok and type(observability) == "table" and observability.counter then
        observability.counter("smg_discovery_deregistrations_total",
            { { "source", _M.SOURCE }, { "reason", reason } })
    end
end

local function set_gauge(metric, value)
    local ok, observability = pcall(require, "resty.luarouter.observability")
    if ok and type(observability) == "table" and observability.gauge then
        observability.gauge(metric, { { "source", _M.SOURCE } }, value)
    end
end

---One sync sample. Rust declares smg_discovery_sync_duration_seconds but never
---reaches a call site for it (its watch loop has no equivalent timer), so this
---is the gateway that actually populates the family: the wall time of one
---list-and-reconcile pass, recorded only when a list was really attempted.
local function observe_sync(started)
    if not started or not ngx or not ngx.now then
        return
    end
    local ok, observability = pcall(require, "resty.luarouter.observability")
    if ok and type(observability) == "table" and observability.observe then
        observability.observe("smg_discovery_sync_duration_seconds",
            { { "source", _M.SOURCE } }, ngx.now() - started)
    end
end

---Registration result label, restricted to the Rust value domain
---(success | failed | duplicate, metrics.rs:424-426). The Lua reconcile has no
---"already tracked" branch -- plan() diffs by url, so a pod it already owns is
---never re-added -- and a rejected add whose job says "already exists" is
---Rust's duplicate case rather than a failure.
local function registration_result(err)
    if not err then
        return "success"
    end
    if string.find(err, "already exists", 1, true) then
        return "duplicate"
    end
    return "failed"
end

-- ------------------------------------------------------------------ poll loop

---Build the request options for one poll (selectors, PD mode, IGW rule).
---@param cfg table
---@return table opts, string selector_text
function _M.poll_opts(cfg)
    local selector = _M.parse_selector(cfg.discovery_selector)
    local prefill = _M.parse_selector(cfg.prefill_selector)
    local decode = _M.parse_selector(cfg.decode_selector)
    local pd_mode = next(prefill) ~= nil or next(decode) ~= nil
    if pd_mode then
        -- Rust's warn_if_misconfigured: --selector is ignored in PD mode unless
        -- IGW mode is on, and SMG_ENABLE_IGW is what this gateway has for that.
        selector = (cfg.enable_igw and true) and selector or {}
    end
    -- Two selector sets cannot be combined into one labelSelector, so PD mode
    -- lists everything and filters client-side (Rust runs two watch streams; one
    -- list covers both here). Otherwise ask the API server to filter, and still
    -- re-check the labels in pod_from_api so a fake API server or a cluster with
    -- different labelSelector semantics cannot silently widen the set.
    local selector_text = pd_mode and "" or _M.selector_string(selector)
    return {
        selector = selector,
        prefill_selector = prefill,
        decode_selector = decode,
        pd_mode = pd_mode,
    }, selector_text
end

---Body of one poll, split out so poll_once can time every exit path. The
---forward declaration keeps poll_once above the implementation, which is the
---order the reader wants: what a poll does, then how the pass is timed.
local sync

---One discovery sync: list pods, reconcile the registry, and record the
---duration of the pass.
---@param cfg table
---@return table result @ {listed, added, removed, failed, error}
function _M.poll_once(cfg)
    local result = { listed = 0, added = 0, removed = 0, failed = 0, error = nil }

    local api, reason = _M.api_server(cfg)
    if not api then
        -- Nothing was listed, so there is no duration to record: a poll that
        -- never called the API server is not a sample of the list latency.
        result.error = "disabled: " .. reason
        note(true, "service discovery disabled: " .. reason)
        return result
    end

    local started = ngx and ngx.now and ngx.now() or nil
    local synced = sync(cfg, api, result)
    observe_sync(started)
    return synced
end

---@param cfg table
---@param api string
---@param result table @ mutated in place
---@return table result
sync = function(cfg, api, result)
    local opts, selector_text, field_text = _M.stream_opts(cfg)
    local url = _M.list_url(api, cfg.discovery_namespace, selector_text, field_text)
    local timeout_ms = math.max(1, tonumber(cfg.health_check_timeout_secs) or 5) * 1000
    local hb = require "resty.luarouter.hb"
    local status, body, err = hb.http_get(url, timeout_ms, _M.auth_headers(cfg))

    if status == 401 or status == 403 then
        -- AuthN/AuthZ failure says nothing about the pods: keep the last known
        -- set rather than tearing every worker down because a token expired
        -- between two polls.
        result.error = "unauthorized (" .. tostring(status) .. ")"
        result.failed = 1
        count_reg("failed")
        note(true, "service discovery cannot list pods: HTTP " .. tostring(status)
            .. " for " .. url .. " (keeping the current workers;"
            .. " check the RBAC list permission on pods)")
        return result
    end
    if status ~= 200 then
        result.error = "list failed: " .. (err or ("status " .. tostring(status)))
        result.failed = 1
        count_reg("failed")
        note(true, "service discovery list failed for " .. url .. ": "
            .. (err or ("status " .. tostring(status))))
        return result
    end
    last_note = nil

    local infos = _M.pod_infos(json_decode(body), opts)
    return _M.reconcile_infos(cfg, opts, infos, result)
end

local function interval(cfg)
    local seconds = tonumber(cfg and cfg.discovery_interval_secs) or 60
    if seconds < 1 then
        seconds = 1
    end
    return math.min(seconds, 3600)
end

_M.interval = interval

---------------------------------------------------------------------------
-- Shared reconcile
---------------------------------------------------------------------------

---Reconcile one pod set into the registry.
---
---Split out of sync() so the watch loop and the poll loop apply exactly the same
---registration rules: the accepted poll contract and the new stream must never
---disagree about what a pod becomes.
---@param cfg table
---@param opts table @ pod_from_api options (pd_mode read from it)
---@param infos table[] @ pod_info list for this pass
---@param result table @ mutated in place: {listed, added, removed, failed}
---@return table result
function _M.reconcile_infos(cfg, opts, infos, result)
    local registry = require "resty.luarouter.registry"
    result = result or {}
    -- Every counter is defaulted, not just listed: the watch loop calls this with
    -- a fresh {} per event, and incrementing a nil field there raised inside the
    -- reconcile - after the worker was already removed. The removal stuck, the
    -- deregistration counter and the discovered gauge did not, so the metrics
    -- quietly disagreed with the registry.
    result.listed = result.listed or 0
    result.added = result.added or 0
    result.removed = result.removed or 0
    result.failed = result.failed or 0
    result.listed = #infos
    local desired = _M.desired_workers(infos, cfg.discovery_port,
        { pd_mode = opts.pd_mode, api_key = cfg.api_key })
    local current = registry.discovery_records(_M.SOURCE)

    local to_add, to_remove = _M.plan(desired, current)
    for i = 1, #to_add do
        local _, add_err = registry.add(to_add[i], cfg)
        local outcome = registration_result(add_err)
        count_reg(outcome)
        if outcome == "failed" then
            result.failed = result.failed + 1
            note(true, "service discovery could not register " .. to_add[i].url
                .. ": " .. add_err)
        elseif outcome == "success" then
            result.added = result.added + 1
        end
    end
    for i = 1, #to_remove do
        local _, remove_err = registry.remove(to_remove[i].id)
        if not remove_err then
            result.removed = result.removed + 1
            count_dereg("pod_deleted")
        end
    end

    -- Gauge mirrors the Rust set_discovery_workers_discovered(source, tracked):
    -- pods known to discovery, healthy or not.
    set_gauge("smg_discovery_workers_discovered", result.listed)
    return result
end

---Request options for one list/watch pass, including the field selector.
---poll_opts() keeps its own shape (its unit tests and the poll contract pin it);
---this only layers the fieldSelector terms on top.
---@param cfg table
---@return table opts, string selector_text, string field_text
function _M.stream_opts(cfg)
    local opts, selector_text = _M.poll_opts(cfg)
    opts.field_selector = _M.parse_field_selector(cfg.field_selector)
    opts.router_selector = _M.parse_selector(cfg.router_selector)
    return opts, selector_text, _M.field_selector_text(opts.field_selector)
end

---------------------------------------------------------------------------
-- B.2 the watch loop
---------------------------------------------------------------------------

-- Worker-0-only state, owned by the timer coroutine. Nothing else reads it, so a
-- plain module table is enough: the registry is where the two loops meet, and
-- that is already shared memory.
local watch = {
    running = false,
    rv = nil,
    tracked = {},
    backoff = 1,
    streams = 0,
}

_M.watch_state = watch

---Exponential backoff ceiling for a broken stream, in the Rust shape
---(service_discovery.rs:1s, doubling, capped at 300s).
local WATCH_MAX_BACKOFF = 300
_M.WATCH_MAX_BACKOFF = WATCH_MAX_BACKOFF

local function watch_read_ms(cfg)
    local idle = tonumber(cfg and cfg.discovery_watch_idle_secs)
    if not idle or idle < 1 then
        idle = math.max(1, interval(cfg)) * 2
    end
    return math.max(1000, math.floor(idle * 1000))
end

local last_watch_note = nil

---Deduplicated warning for the watch path. note() is shared with the poll loop,
---and two loops that remember problems separately must not overwrite each
---other's idea of what has already been said.
local function watch_note(message)
    if last_watch_note == message then
        return
    end
    last_watch_note = message
    note(true, message)
end

---One watch stream, plus whatever relist had to precede it.
---
---Returns the delay before the next call rather than looping inside one timer
---coroutine: nginx has to be able to stop this work at shutdown, and a coroutine
---parked in a cosocket read for an hour is not stoppable (premature is only
---delivered to the scheduled call, never to a loop already running).
---@param cfg table
---@param api string
---@return number @ seconds until the next attempt
local function watch_pass(cfg, api)
    local opts, selector_text, field_text = _M.stream_opts(cfg)

    -- No resourceVersion means the tracked map is not trustworthy: bootstrap, or
    -- the recovery from a 410. A list is the only way to learn the full set.
    if not watch.rv then
        local hb = require "resty.luarouter.hb"
        local url = _M.list_url(api, cfg.discovery_namespace, selector_text, field_text)
        local timeout_ms = math.max(1, tonumber(cfg.health_check_timeout_secs) or 5) * 1000
        local status, body, err = hb.http_get(url, timeout_ms, _M.auth_headers(cfg))
        if status == 401 or status == 403 then
            watch_note("service discovery cannot list pods: HTTP "
                .. tostring(status) .. " for " .. url .. " (keeping the current workers;"
                .. " check the RBAC list permission on pods)")
            count_reg("failed")
            return interval(cfg)
        end
        if status ~= 200 then
            count_reg("failed")
            watch_note("service discovery list failed for " .. url .. ": "
                .. (err or ("status " .. tostring(status))))
            return interval(cfg)
        end
        last_note = nil
        local doc = json_decode(body)
        watch.tracked = {}
        local infos = _M.pod_infos(doc, opts)
        for i = 1, #infos do
            watch.tracked[infos[i].name] = infos[i]
        end
        local doc_rv = doc and type(doc.metadata) == "table"
            and doc.metadata.resourceVersion or nil
        -- Without a version there is nothing to resume from, so the next pass
        -- lists again rather than opening a stream from "now" and silently
        -- missing whatever the list and the stream agreed on in between.
        watch.rv = doc_rv ~= nil and tostring(doc_rv) or nil
        _M.reconcile_infos(cfg, opts, _M.tracked_infos(watch.tracked), {})
        watch.backoff = 1
        if not watch.rv then
            note(true, "kubernetes list response carried no metadata.resourceVersion;"
                .. " falling back to a list every " .. interval(cfg) .. "s")
            return interval(cfg)
        end
    end

    local url = _M.watch_url(api, cfg.discovery_namespace, selector_text,
        field_text, watch.rv)
    local opened = _M.open_watch(cfg, url, watch_read_ms(cfg))
    if opened.kind == "gone" then
        -- 410 is the API server saying "that version is compacted away": the only
        -- correct move is a fresh list, which is also the only way to learn a new
        -- version. Counting it as an error keeps a chatty compaction visible.
        count_watch_error("gone")
        watch.rv = nil
        watch.tracked = {}
        watch.backoff = 1
        return 1
    end
    if opened.kind ~= "stream" then
        if opened.kind == "status" then
            count_watch_error("status")
            watch_note("watch on " .. url .. " answered HTTP "
                .. tostring(opened.code) .. " (retrying with backoff)")
        else
            count_watch_error("transport")
            watch_note("watch on " .. url .. " failed: "
                .. tostring(opened.err))
        end
        local delay = watch.backoff
        watch.backoff = math.min(delay * 2, WATCH_MAX_BACKOFF)
        return delay
    end

    watch.streams = watch.streams + 1
    if watch.streams > 1 then
        count_watch_reconnect()
    end

    local dirty = false
    local stats = { added = 0, modified = 0, deleted = 0, bookmark = 0 }
    local function on_event(event)
        local typ = string.upper(tostring(event.type or ""))
        local object = event.object
        local rv = _M.event_resource_version(object)
        if typ == "BOOKMARK" then
            -- A bookmark carries a version and no pod: it is how the resume point
            -- stays fresh through a quiet period.
            if rv then
                watch.rv = rv
            end
            stats.bookmark = stats.bookmark + 1
            count_watch_event("bookmark")
            return nil
        end
        if typ == "ERROR" then
            -- The in-body ERROR frame is how a mid-stream 410 arrives (the status
            -- line was already a 200), so it has the same meaning as the response.
            local reason = object and type(object.reason) == "string"
                and object.reason or ""
            count_watch_error("stream")
            if string.find(string.lower(reason), "expired", 1, true)
                or (object and tostring(object.code) == "410") then
                watch.rv = nil
                watch.tracked = {}
                watch.backoff = 1
                return "stop"
            end
            return "stop"
        end
        if typ ~= "ADDED" and typ ~= "MODIFIED" and typ ~= "DELETED" then
            return nil
        end
        if _M.apply_watch_event(watch.tracked, typ, object, opts) then
            dirty = true
        end
        if rv then
            watch.rv = rv
        end
        if typ == "ADDED" then
            stats.added = stats.added + 1
            count_watch_event("added")
        elseif typ == "MODIFIED" then
            stats.modified = stats.modified + 1
            count_watch_event("modified")
        else
            stats.deleted = stats.deleted + 1
            count_watch_event("deleted")
        end
        -- Reconcile per event rather than per stream: Rust registers a worker the
        -- moment its pod appears, and a watch that only applied its deltas when
        -- the connection dropped would be slower than the poll it replaced.
        if dirty then
            dirty = false
            _M.reconcile_infos(cfg, opts, _M.tracked_infos(watch.tracked), {})
        end
        return nil
    end

    local reason, detail = _M.consume_watch(opened.sock, opened.chunked, on_event)
    if opened.sock then
        opened.sock:close()
    end
    if dirty then
        _M.reconcile_infos(cfg, opts, _M.tracked_infos(watch.tracked), {})
        dirty = false
    end
    if reason == "stop" then
        -- Either an ERROR frame (handled above) or the caller asked out; retry
        -- promptly so a resume from a live version is not delayed by an interval.
        return 1
    end
    if reason == "error" then
        count_watch_error("transport")
        watch_note("watch stream framing error from " .. url .. ": "
            .. tostring(detail))
        local delay = watch.backoff
        watch.backoff = math.min(delay * 2, WATCH_MAX_BACKOFF)
        return delay
    end
    -- eof (server closed), timeout (idle window with no event) and closed (peer
    -- gone) are all normal stream ends: the resume point is real, so reconnect
    -- from it after the configured interval, exactly like Rust's outer loop.
    watch.backoff = 1
    if stats.added + stats.modified + stats.deleted + stats.bookmark > 0 or reason ~= "timeout" then
        note(false, "kubernetes watch stream ended (" .. reason .. "); resuming from "
            .. tostring(watch.rv))
    end
    return interval(cfg)
end

local function watch_tick(premature)
    if premature then
        watch.running = false
        return
    end
    local conf
    local ok, lr = pcall(require, "resty.luarouter")
    if ok and lr and lr.config then
        conf = lr.config()
    end
    local delay = interval(conf)
    if conf then
        local api, reason = _M.api_server(conf)
        if not api then
            note(true, "kubernetes watch disabled: " .. reason)
            delay = interval(conf)
        else
            local pass_ok, pass_err = pcall(watch_pass, conf, api)
            if not pass_ok then
                note(true, "kubernetes watch error: " .. tostring(pass_err))
            else
                delay = pass_err
            end
        end
    end
    if type(delay) ~= "number" or delay < 1 then
        delay = 1
    end
    local again, terr = ngx.timer.at(delay, watch_tick)
    if not again then
        watch.running = false
        note(true, "kubernetes watch timer not rescheduled: " .. tostring(terr))
    end
end

---Start the watch loop (worker 0). Exposed for wiring and tests; start() calls it
---when SMG_SERVICE_DISCOVERY_WATCH is on.
---@param cfg table
---@return boolean|nil started, string|nil err
function _M.start_watch(cfg)
    if watch.running then
        return true
    end
    if not ngx or not ngx.timer then
        return false, "no ngx.timer"
    end
    watch.running = true
    local ok, err = ngx.timer.at(0, watch_tick)
    if not ok then
        watch.running = false
        return false, tostring(err)
    end
    return true
end

---------------------------------------------------------------------------
-- B. router-pod discovery (mesh peers from the pod API)
---------------------------------------------------------------------------

---Read the mesh port off a router pod.
---@param meta table
---@param annotation string|nil
---@return number|nil port
local function mesh_port_from_meta(meta, annotation)
    local annotations = type(meta.annotations) == "table" and meta.annotations or {}
    local name = (annotation and annotation ~= "") and annotation
        or _M.ROUTER_MESH_PORT_ANNOTATION
    local port = tonumber(annotations[name])
    if port and port == math.floor(port) and port >= 1 and port <= 65535 then
        return port
    end
    return nil
end

_M.mesh_port_from_meta = mesh_port_from_meta

---Router-pod view of one pod: enough to place it in the mesh membership.
---
---Deliberately separate from pod_from_api: a router pod is not a candidate
---worker, and pretending otherwise is how a fleet ends up load-balancing
---requests onto the gateways themselves.
---@param pod table
---@param opts table @ {router_selector, router_mesh_port_annotation}
---@return table|nil @ {name, ip, status, is_ready, deleting, mesh_port}
function _M.router_pod_from_api(pod, opts)
    if type(pod) ~= "table" then
        return nil
    end
    opts = opts or {}
    local selector = opts.router_selector
    if type(selector) ~= "table" or next(selector) == nil then
        return nil
    end
    local meta = type(pod.metadata) == "table" and pod.metadata or {}
    local name = type(meta.name) == "string" and meta.name or nil
    if not name or name == "" then
        return nil
    end
    if not _M.selector_matches(label_strings(meta.labels), selector) then
        return nil
    end
    local status = type(pod.status) == "table" and pod.status or {}
    local pod_ip = type(status.podIP) == "string" and status.podIP or nil
    if not pod_ip or pod_ip == "" then
        return nil
    end
    local is_ready = false
    local conditions = type(status.conditions) == "table" and status.conditions or {}
    for i = 1, #conditions do
        local cond = conditions[i]
        if type(cond) == "table" and cond.type == "Ready" and cond.status == "True" then
            is_ready = true
        end
    end
    return {
        name = name,
        ip = pod_ip,
        status = type(status.phase) == "string" and status.phase or "",
        is_ready = is_ready,
        deleting = type(meta.deletionTimestamp) == "string"
            and meta.deletionTimestamp ~= "",
        mesh_port = mesh_port_from_meta(meta, opts.router_mesh_port_annotation),
    }
end

---Mesh address for a router pod: http://<podIP>:<annotation port or fallback>.
---@param info table
---@param fallback_port number|nil
---@return string
function _M.router_mesh_address(info, fallback_port)
    return string.format("http://%s:%d", info.ip,
        tonumber(info.mesh_port) or tonumber(fallback_port) or 30000)
end

---Reconcile router pods into the mesh membership.
---
---The three branches are Rust's start_router_discovery (service_discovery.rs:622)
---step by step: a pod being deleted marks the node Down, a healthy pod inserts it
---Alive, anything else marks it Suspect - and only when it was already known, so
---a never-seen unhealthy pod does not create a member. Plus one thing the Rust
---loop cannot do without a watch: a pod that simply vanishes from the list is
---retired too, because the poll has no DELETED event to learn from.
---@param cfg table
---@param mesh table @ mesh instance
---@param infos table[] @ router_pod_from_api results for this pass
---@param tracked table @ name -> address, mutated in place
---@return table @ {adopted, suspected, retired, skipped_self}
function _M.reconcile_router_members(mesh, infos, tracked, fallback_port)
    local out = { adopted = 0, suspected = 0, retired = 0, skipped_self = 0 }
    local seen = {}
    for i = 1, #(infos or {}) do
        local info = infos[i]
        seen[info.name] = true
        if info.deleting then
            -- The address is passed alongside the name: sync can rewrite the
            -- member key to the peer's self-reported identity, and a lookup that
            -- only knows the pod name would then never find the entry to mark down.
            local known = tracked[info.name]
                or _M.router_mesh_address(info, fallback_port)
            if mesh:retire_member(info.name, known) then
                out.retired = out.retired + 1
            end
            tracked[info.name] = nil
        elseif _M.pod_is_healthy(info) then
            local address = _M.router_mesh_address(info, fallback_port)
            local adopted, reason = mesh:adopt_member(info.name, address)
            if adopted then
                out.adopted = out.adopted + 1
                tracked[info.name] = address
            elseif reason == "self" then
                -- This instance is in the pod list, as it should be. It must not
                -- become its own peer, and it must not be tracked either: the
                -- "gone from the list" sweep below retires whatever it is holding,
                -- and retiring our own entry would take this node out of its own
                -- cluster view. The count is exported so the operator can tell
                -- "found myself" from "found nobody".
                out.skipped_self = out.skipped_self + 1
            else
                -- Same address, already alive: nothing to write and nothing new to
                -- track (the name is already in tracked from the pass that adopted
                -- it). Keeping tracked[] small is what makes the retire sweep cheap.
                tracked[info.name] = tracked[info.name] or address
            end
        else
            if mesh:suspect_member(info.name, tracked[info.name]) then
                out.suspected = out.suspected + 1
            end
            -- The name stays tracked: an unready router pod is suspected, not
            -- retired, and the next pass has to be able to promote it back.
        end
    end
    -- A name we adopted earlier that is no longer in the list: the pod is gone and
    -- no DELETED event will tell us (Rust's watch does, the poll has to infer it).
    for name, address in pairs(tracked) do
        if not seen[name] then
            if mesh:retire_member(name, address) then
                out.retired = out.retired + 1
            end
            tracked[name] = nil
        end
    end
    return out
end

local router_tracked = {}
local router_running = false
local router_warned = false
_M.router_tracked = router_tracked

---One router-pod pass: list the pods, reconcile the mesh membership.
---@param cfg table
---@param api string
---@param mesh table|nil @ mesh instance; nil means mesh is off
---@param result table|nil @ mutated counters
---@return table result
function _M.router_discover_once(cfg, api, mesh, result)
    result = result or { listed = 0, adopted = 0, suspected = 0, retired = 0,
                         skipped_self = 0, error = nil }
    if not mesh then
        if not router_warned then
            router_warned = true
            note(true, "router selector configured but mesh is not enabled"
                .. " (SMG_ENABLE_MESH/SMG_MESH_PEERS); skipping router discovery")
        end
        result.error = "mesh not enabled"
        return result
    end
    local selector = _M.parse_selector(cfg.router_selector)
    if next(selector) == nil then
        result.error = "no router selector"
        return result
    end
    local url = _M.pods_url(api, cfg.discovery_namespace,
        _M.selector_string(selector))
    local hb = require "resty.luarouter.hb"
    local timeout_ms = math.max(1, tonumber(cfg.health_check_timeout_secs) or 5) * 1000
    local status, body, err = hb.http_get(url, timeout_ms, _M.auth_headers(cfg))
    if status ~= 200 then
        result.error = "router list failed: "
            .. (err or ("status " .. tostring(status)))
        note(true, "router pod discovery could not list " .. url .. ": "
            .. (err or ("status " .. tostring(status))))
        return result
    end
    last_note = nil
    local doc = json_decode(body)
    local opts = {
        router_selector = selector,
        router_mesh_port_annotation = cfg.router_mesh_port_annotation,
    }
    local infos = {}
    local items = type(doc) == "table" and type(doc.items) == "table" and doc.items or {}
    for i = 1, #items do
        local info = _M.router_pod_from_api(items[i], opts)
        if info then
            infos[#infos + 1] = info
        end
    end
    result.listed = #infos
    local counts = _M.reconcile_router_members(mesh, infos, router_tracked,
        cfg.discovery_port)
    for key, value in pairs(counts) do
        result[key] = (result[key] or 0) + value
    end
    return result
end

local function router_tick(premature)
    if premature then
        router_running = false
        return
    end
    local conf
    local ok, lr = pcall(require, "resty.luarouter")
    if ok and lr and lr.config then
        conf = lr.config()
    end
    if conf and conf.router_selector and conf.router_selector ~= "" then
        local ok_mesh, mesh = pcall(require, "resty.luarouter.mesh")
        local inst = ok_mesh and mesh and mesh.instance() or nil
        local api = _M.api_server(conf)
        if api then
            local pass_ok, pass_err = pcall(_M.router_discover_once, conf, api, inst)
            if not pass_ok then
                note(true, "router pod discovery error: " .. tostring(pass_err))
            end
        end
    end
    local again, terr = ngx.timer.at(interval(conf), router_tick)
    if not again then
        router_running = false
        note(true, "router pod discovery timer not rescheduled: " .. tostring(terr))
    end
end

---Start router-pod discovery (worker 0). Runs on the poll interval: the Rust side
---watches this one too, but the pod set here is a handful of routers, so polling
---buys nothing that a second long-lived stream would (see the doc's limits).
---@param cfg table
---@return boolean|nil started, string|nil err
function _M.start_router_discovery(cfg)
    if router_running then
        return true
    end
    if not cfg or not cfg.router_selector or cfg.router_selector == "" then
        return false, "no router selector configured"
    end
    if not ngx or not ngx.timer then
        return false, "no ngx.timer"
    end
    router_running = true
    local ok, err = ngx.timer.at(0, router_tick)
    if not ok then
        router_running = false
        return false, tostring(err)
    end
    return true
end

local function tick(premature)
    if premature then
        timer_running = false
        return
    end
    local conf
    local ok, lr = pcall(require, "resty.luarouter")
    if ok and lr and lr.config then
        conf = lr.config()
    end
    if conf then
        local synced, err = pcall(_M.poll_once, conf)
        if not synced then
            note(true, "service discovery poll error: " .. tostring(err))
        end
    end
    local again, terr = ngx.timer.at(interval(conf), tick)
    if not again then
        timer_running = false
        note(true, "service discovery timer not rescheduled: " .. tostring(terr))
    end
end

---Start the poll loop (worker 0 only; called after hb.start()).
---@param cfg table
---@return boolean|nil started, string|nil err
function _M.start(cfg)
    if timer_running then
        return true
    end
    if not cfg or not cfg.service_discovery then
        return false, "service discovery disabled"
    end
    local api, reason = _M.api_server(cfg)
    if not api then
        -- Loud once, then quiet: the operator asked for discovery and did not get
        -- it, which must not be confused with "not configured".
        note(true, "SMG_SERVICE_DISCOVERY is on but discovery is disabled: " .. reason
            .. " (set SMG_KUBE_API_SERVER or run inside a cluster)")
        return false, reason
    end
    if not read_file((cfg.kube_sa_path or "") .. "/token") then
        note(true, "no service account token at " .. tostring(cfg.kube_sa_path)
            .. "/token; querying " .. api .. " unauthenticated")
    end
    local watching = (cfg.discovery_watch and true) or false
    local field_terms = _M.parse_field_selector(cfg.field_selector)
    local unsupported = _M.unsupported_field_term(field_terms)
    if unsupported then
        -- Say it out loud: the term matches nothing, so discovery will claim no
        -- pods at all, and "the API server rejected it" is not visible from here.
        note(true, "unsupported fieldSelector term \"" .. unsupported .. "\"; it matches"
            .. " nothing, so no pod will be discovered (equality on metadata.name,"
            .. " metadata.namespace, status.phase, status.podIP, spec.nodeName only)")
    end
    note(false, "starting kubernetes service discovery | api " .. api
        .. " | namespace " .. tostring(cfg.discovery_namespace or "<all>")
        .. " | port " .. tostring(cfg.discovery_port)
        .. " | interval " .. interval(cfg) .. "s (" .. (watching and "watch" or "poll, not watch")
        .. ")"
        .. (cfg.field_selector and cfg.field_selector ~= ""
                and " | fieldSelector " .. cfg.field_selector or "")
        .. (cfg.router_selector and cfg.router_selector ~= ""
                and " | router selector " .. cfg.router_selector or ""))
    timer_running = true
    local ok, err
    if watching then
        ok, err = _M.start_watch(cfg)
    else
        ok, err = ngx.timer.at(0, tick)
    end
    if not ok then
        timer_running = false
        note(true, "failed to start service discovery timer: " .. tostring(err))
        return false, tostring(err)
    end
    if cfg.router_selector and cfg.router_selector ~= "" then
        local started, rerr = _M.start_router_discovery(cfg)
        if not started then
            note(true, "router pod discovery not started: " .. tostring(rerr))
        end
    end
    return true
end

return _M
