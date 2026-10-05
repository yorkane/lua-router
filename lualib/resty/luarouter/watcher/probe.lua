local cjson = require "cjson.safe"

local _M = require "resty.luarouter.watcher"
local json_decode = cjson.decode

-- watcher/probe.lua -- the strict probe and the three-way verdict (doc/
-- gap-watcher-merge.md 1.1, AGENTS.md hard rule 4): a deterministic
-- rejection evicts in the same pass, a transport-level unknown must
-- accumulate SMG_WATCHER_PROBE_FAILURES rounds before eviction, and
-- "no probe transport" / require_health neither evicts nor counts.
-- The reason strings are the document-locked contract with a single owner
-- here; classify() reads the router fingerprint through the facade exactly
-- as the monolith did.

-- ------------------------------------------------------------------ probe

local function as_int(status)
    return tonumber(status) or 0
end

---One probe hop: fetch via the injected getter and decode defensively.
---@param fetch function @ (url) -> status, body, err
---@param url string
---@return number status, table|nil json, string|nil raw
local function get_json(fetch, url)
    local status, body = fetch(url)
    local code = as_int(status)
    if type(body) ~= "string" then
        return code, nil, nil
    end
    local decoded = json_decode(body)
    if type(decoded) ~= "table" then
        return code, nil, body
    end
    return code, decoded, body
end

---Ask a candidate whether it really is an inference worker.
---
---Port of probe_worker. Accept returns {url, models, engine, has_health}; a
---rejection returns nil plus a one-line reason (the reason is logged with a
---per-url rate limit, so a busy host does not fill the error log with the same
---"that is nginx" note every 15 s).
---@param url string
---@param opts table|nil @ {fetch, require_health, max_models, allow_models_only}
---@return table|nil info, string|nil reason
function _M.classify(url, opts)
    opts = opts or {}
    local fetch = opts.fetch
    if type(fetch) ~= "function" then
        return nil, "no probe transport"
    end
    local max_models = tonumber(opts.max_models) or 0

    local status, payload, raw = get_json(fetch, url .. "/v1/models")
    if status < 200 or status >= 400 or raw == nil then
        return nil, "no /v1/models answer"
    end
    local ids = {}
    local data = type(payload) == "table" and payload.data or nil
    if type(data) == "table" then
        for i = 1, #data do
            local item = data[i]
            if type(item) == "table"
                and (type(item.id) == "string" or type(item.id) == "number") then
                ids[#ids + 1] = tostring(item.id)
            end
        end
    end
    if #ids == 0 then
        -- An HTML/JSON service that is not an OpenAI model endpoint: this is the
        -- gate that keeps node_exporter and every 404 page out of the pool.
        return nil, "/v1/models answers without data[].id"
    end

    -- A server advertising dozens of models is an aggregator or another proxy,
    -- not a worker: routing through it adds a hop and can loop back here.
    if max_models > 0 and #ids > max_models then
        return nil, string.format("advertises %d models (> max-models %d), looks like a proxy",
            #ids, max_models)
    end

    -- Self-loop guard, second half: another router also serves /v1/models.
    local info_status, server_info = get_json(fetch, url .. "/server_info")
    if info_status >= 200 and info_status < 400 and type(server_info) == "table" then
        for i = 1, #_M.ROUTER_FINGERPRINT_KEYS do
            if rawget(server_info, _M.ROUTER_FINGERPRINT_KEYS[i]) ~= nil then
                return nil, "it is a router, not a worker"
            end
        end
    end

    local engine = "openai"
    local gsi_status, gsi = get_json(fetch, url .. "/get_server_info")
    local props_status, props = get_json(fetch, url .. "/props")
    local metrics_status, _, metrics_raw = get_json(fetch, url .. "/metrics")
    local metrics_text = metrics_raw or ""
    if gsi_status >= 200 and gsi_status < 400 and type(gsi) == "table"
        and (rawget(gsi, "disaggregation_mode") ~= nil or rawget(gsi, "tp_size") ~= nil
            or rawget(gsi, "model_path") ~= nil) then
        engine = "sglang"
    elseif info_status >= 200 and info_status < 400 and type(server_info) == "table"
        and rawget(server_info, "model_path") ~= nil then
        engine = "sglang"
    elseif string.find(metrics_text, "vllm:", 1, true) then
        engine = "vllm"
    elseif string.find(metrics_text, "llamacpp:", 1, true) then
        engine = "llama.cpp"
    elseif props_status >= 200 and props_status < 400 and type(props) == "table"
        and (rawget(props, "build_commit") ~= nil or rawget(props, "build_number") ~= nil
            or rawget(props, "webui") ~= nil) then
        engine = "llama.cpp"
    end

    local health_status = as_int((fetch(url .. "/health")))
    local has_health = health_status >= 200 and health_status < 400
    if opts.require_health and not has_health then
        return nil, "no usable /health endpoint"
    end

    -- /v1/models alone is not enough: an API gateway that only proxies the /v1
    -- surface answers it happily while /health and /metrics both 5xx (measured on
    -- 21.k's openresty :9080, which registered as a worker and then failed every
    -- AddWorker job). A 404 only means the engine did not implement the endpoint,
    -- so only a 5xx on BOTH counts as the proxy signal.
    if engine == "openai" and health_status >= 500 and metrics_status >= 500
        and not opts.allow_models_only then
        return nil, "/v1/models answers but /health and /metrics both 5xx -- an "
            .. "upstream/gateway, not a worker (or set SMG_WATCHER_ALLOW_MODELS_ONLY=1)"
    end

    return { url = url, models = ids, engine = engine, has_health = has_health }
end

---探针拒绝原因 -> 本轮该怎么处置（"reject" / "count" / nil）。
---
---分档依据只有一条：网关有没有亲眼看见对方给出一个否定的答案。
---  * reject（确定性否定）：对方确实答了 HTTP，只是内容不合要求——有 2xx 却读不出
---    data[].id（node_exporter、Web UI、404 页）、advertises 几十个模型（聚合器/另一层
---    代理，路由过去等于多一跳甚至绕圈）、命中 router 自指纹（对端是 router，接进池会
---    成环）。这种行留在池里只会回 5xx 并广告一个它服务不了的模型，所以当轮摘除，
---    不等 remove_grace、也不受 keep-last 豁免。
---  * count（传输层未知）：连不上、超时、TLS 失败、keepalive 池里被对端半关闭的旧连接、
---    /v1/models 答非 2xx，以及 "/health 与 /metrics 双 5xx" 那条。前面几种在
---    hb.http_request 里都落成 "no /v1/models answer"，网关分不清是引擎在忙大 prefill
---    没在 probe_timeout 内答完，还是它真死了；双 5xx 那条同样不能算否定——vLLM 的身份
---    标签恰恰来自 /metrics 文本，一次 /metrics 抖动 5xx 就让引擎判定退回 openai 进而
---    触发它，它是"证据不完整"。摘除的真实代价：registry.add 把 K_HEALTH 归零并清掉两条
---    外部负载读数，配合 health_success_threshold=2 与巡检间隔折算约 60s 才恢复接流，
---    policy.on_remove 还会顺带摘掉该 URL 在所有 cache_aware 树里的租户、丢掉学到的前缀
---    分布。引擎忙时很容易连续几轮都读不到，一次抖动就换来几十秒 503 空窗，比忍一轮
---    僵尸行贵得多，所以必须先累计到阈值。
---  * nil（完全不判定）："no probe transport" 说的是网关自己的装配（fetch 没注入）或
---    cosocket 被限流，"no usable /health endpoint" 是注册准入开关 require_health 的产物，
---    两者都不描述对方此刻能不能服务。拿它们当摘除理由的话，打开 require_health 的操作员
---    会让所有 /health 404 的引擎陷入摘-加循环，所以这类条目本轮既不置计数也不走宽限。
---@param reason string|nil @ classify() 的第二返回值
---@return string|nil @ "reject" | "count" | nil（nil = 本轮不判定）
function _M.probe_verdict(reason)
    if type(reason) ~= "string" or reason == "" then
        -- 老夹具或以后新增的文案：按最保守的传输层计一次，最终仍会摘，只是要先累计。
        return "count"
    end
    if reason == "no probe transport" or reason == "no usable /health endpoint" then
        return nil
    end
    if reason == "/v1/models answers without data[].id"
        or reason == "it is a router, not a worker"
        or string.find(reason, "advertises ", 1, true) == 1 then
        return "reject"
    end
    -- "no /v1/models answer" 与 "/v1/models answers but /health and /metrics both 5xx ..."
    return "count"
end

return _M
