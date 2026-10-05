-- mesh.handlers —— 对外契约面：/_mesh/internal/* 四个内部端点 + 13 条 /ha/*
-- handler + handler 小工具。响应体逐字段对齐 Rust handlers.rs；未启用时的 503
-- 固定体被契约测试逐字节锁定（见 mesh.lua 头注与 doc/gap-mesh.md）。
--
-- handler_response 是跨子模块把手（mesh/sync.lua 的 dispatch/disabled_response
-- 也要用小响应），经 return { priv = ... } 交出。
local _M = require "resty.luarouter.mesh"

local cjson = require "cjson.safe"

local has_ngx = (type(ngx) == "table")

local json_encode = cjson.encode
local json_decode = cjson.decode

local alive = require "resty.luarouter.mesh.crdt".priv.alive

-- ------------------------------------------------------------------ 内部端点协议
--
-- 全部走 /_mesh/internal/ 前缀，Content-Type: application/x-mesh-b64（正文是
-- 一段 base64(JSON)）。
--   POST /_mesh/internal/sync   请求体 = 本节点快照(b64)，响应体 = 对端快照(b64)
--   POST /_mesh/internal/apply  请求体 = 对端快照(b64)，响应 = {applied}
--   GET  /_mesh/internal/ping   响应 = {node,status,version,draining}
--   GET  /_mesh/internal/state  调试：本节点快照(b64)
-- 一轮 tick 对每个 peer 发一次 sync：请求带自己的快照（推送本地写入），响应带
-- 对方的快照（拉取远端写入），一次往返完成双向收敛。
--
-- handler 返回约定与 router.lua 一致：返回字符串表示响应已自行写完；在没有 ngx
-- 的单测环境里返回 {status=,body=} 表，两条路径共用同一段逻辑。

---当前是否处在可以写响应的阶段。ngx.status 在 init_worker / init 阶段是禁用
-- 的（读它就抛 "API disabled in the current context"），所以判定相位而不是探测
-- 字段：定时器里的广播路径也会经由 handler，必须能安全退回返回表的形式。
local RESPONSE_PHASES = {
    content = true, header_filter = true, body_filter = true, rewrite = true,
}

local function can_write_response()
    if not has_ngx then
        return false
    end
    local ok, phase = pcall(ngx.get_phase)
    return ok and RESPONSE_PHASES[phase] == true
end

---统一的小响应。
local function handler_response(status, payload, content_type)
    local body = ""
    if payload ~= nil then
        if type(payload) == "string" then
            body = payload
        else
            body = json_encode(payload) or "{}"
        end
    end
    if can_write_response() then
        ngx.status = status
        ngx.header["Content-Type"] = content_type or "application/json"
        if body ~= "" then
            ngx.print(body)
        end
        return ""
    end
    return { status = status, body = body, content_type = content_type or "application/json" }
end

local function read_body(req)
    if req and type(req.body) == "string" then
        return req.body
    end
    if req and type(req.get_body) == "function" then
        return req.get_body() or ""
    end
    if can_write_response() then
        ngx.req.read_body()
        return ngx.req.get_body_data() or ""
    end
    return ""
end

_M.read_body = read_body

---GET /_mesh/internal/ping —— 活着就行，回答自己的成员条目。
function _M:handle_ping(req)
    local entry = self.store.members[self.self_name]
    return handler_response(200, {
        protocol = _M.PROTOCOL,
        node = self.self_name,
        addr = self.self_addr or "",
        status = (entry and entry.value.status) or _M.STATUS_ALIVE,
        version = (entry and entry.version) or 1,
        draining = self.draining and true or false,
    })
end

---POST /_mesh/internal/sync —— 合并对端快照，再把自己的快照发回去。
function _M:handle_sync(req)
    local body = read_body(req)
    if body ~= "" then
        local snap, err = _M.decode(body)
        if not snap then
            return handler_response(400, { error = "bad mesh envelope: " .. tostring(err) })
        end
        local _, apply_err = self:apply_snapshot(snap)
        if apply_err then
            return handler_response(400, { error = apply_err })
        end
    end
    local text = _M.encode(self:snapshot())
    if not text then
        return handler_response(500, { error = "snapshot encode failed" })
    end
    return handler_response(200, text, "application/x-mesh-b64")
end

---POST /_mesh/internal/apply —— 只推不拉。
function _M:handle_apply(req)
    local snap, err = _M.decode(read_body(req))
    if not snap then
        return handler_response(400, { error = "bad mesh envelope: " .. tostring(err) })
    end
    local applied, apply_err = self:apply_snapshot(snap)
    if apply_err then
        return handler_response(400, { error = apply_err })
    end
    return handler_response(200, { applied = applied, node = self.self_name })
end

---GET /_mesh/internal/state —— 调试：本节点全量快照。
function _M:handle_state(req)
    local text = _M.encode(self:snapshot())
    if not text then
        return handler_response(500, { error = "snapshot encode failed" })
    end
    return handler_response(200, text, "application/x-mesh-b64")
end

-- ------------------------------------------------------------------ handler 小工具

---cjson 无法区分空表与空对象，空数组必须显式带元表（与 router.lua 的做法一致）。
local function empty_array()
    return setmetatable({}, cjson.empty_array_mt or {})
end
---读 JSON 请求体。req 为接线层传入的请求对象（可为 nil，则走 ngx）。
local function json_body(req)
    local text
    if req and type(req.body) == "string" then
        text = req.body
    else
        text = read_body(req)
    end
    if not text or text == "" then
        return nil, "empty body"
    end
    local value = json_decode(text)
    if type(value) ~= "table" then
        return nil, "invalid JSON body"
    end
    return value
end

---同步失败计数导出为数组（/ha/stats 用）。
local function sync_fail_list(mesh)
    local out = {}
    for name, fails in pairs(mesh.sync_fail) do
        out[#out + 1] = { node = name, consecutive_failures = fails }
    end
    table.sort(out, function(a, b) return a.node < b.node end)
    if #out == 0 then
        return empty_array()
    end
    return out
end

---rate store 的条目不是 LWW 记录，单独计数。
local function rate_key_count(store)
    local n = 0
    for _ in pairs(store) do
        n = n + 1
    end
    return n
end

-- ------------------------------------------------------------------ /ha/* handlers
--
-- 路由表逐条对齐 gateway/src/server.rs:1393-1404，响应体逐字段对齐
-- gateway/src/routers/mesh/handlers.rs。差别只有三处，都写进 doc/gap-mesh.md：
--   * stores 的三个 count 字段 Rust 硬编码 0（源码里就是 TODO），这里给真实值；
--   * /ha/health 在有 peer 不可达或没有 quorum 时 status=degraded（Rust 恒 healthy）；
--   * /ha/shutdown 只把本节点标成 draining 并向对等端广播，不退出进程。

local function not_found(message)
    return handler_response(404, { error = message })
end

---GET /ha/status
function _M:ha_status(req)
    local nodes = {}
    for name, entry in pairs(self.store.members) do
        local member = entry.value
        nodes[#nodes + 1] = {
            name = name,
            address = member.address or "",
            status = member.status or _M.STATUS_INIT,
            version = entry.version or member.version or 0,
        }
    end
    table.sort(nodes, function(a, b) return a.name < b.name end)
    local state, detail = self:partition_state()
    return handler_response(200, {
        node_name = self.self_name,
        node_count = #nodes,
        nodes = #nodes > 0 and nodes or empty_array(),
        partition = state,
        reachable = detail.reachable,
        unreachable = detail.unreachable,
        draining = self.draining and true or false,
        stores = {
            membership_count = #nodes,
            worker_count = _M.count_live(self.store.workers),
            policy_count = _M.count_live(self.store.policies),
            app_count = _M.count_live(self.store.apps),
        },
    })
end

---GET /ha/health
function _M:ha_health(req)
    local state, detail = self:partition_state()
    local healthy = (state == "normal") and not self.draining
    return handler_response(200, {
        status = healthy and "healthy" or "degraded",
        node_name = self.self_name,
        cluster_size = _M.count_live(self.store.members),
        partition = state,
        unreachable = detail.unreachable,
        should_serve = self:should_serve() and true or false,
        draining = self.draining and true or false,
        stores_healthy = healthy and true or false,
    })
end

local function worker_view(entry)
    local value = entry.value
    return {
        worker_id = value.worker_id,
        model_id = value.model_id,
        url = value.url,
        health = value.health and true or false,
        load = value.load or 0,
        version = entry.version or value.version or 0,
        origin = entry.node,
    }
end

---GET /ha/workers
function _M:ha_workers(req)
    local out = {}
    local live = _M.all(self.store.workers)
    for i = 1, #live do
        out[i] = worker_view(live[i].entry)
    end
    return handler_response(200, #out > 0 and out or empty_array())
end

---GET /ha/workers/{worker_id}
function _M:ha_worker(req, worker_id)
    local entry = type(worker_id) == "string" and self.store.workers[worker_id] or nil
    if not entry or not alive(entry.value) then
        return not_found("Worker not found")
    end
    return handler_response(200, worker_view(entry))
end

local function policy_view(entry)
    local value = entry.value
    return {
        model_id = value.model_id,
        policy_type = value.policy_type,
        config = value.config,
        version = entry.version or value.version or 0,
        origin = entry.node,
    }
end

---GET /ha/policies
function _M:ha_policies(req)
    local out = {}
    local live = _M.all(self.store.policies)
    for i = 1, #live do
        out[i] = policy_view(live[i].entry)
    end
    return handler_response(200, #out > 0 and out or empty_array())
end

---GET /ha/policies/{model_id}
function _M:ha_policy(req, model_id)
    if type(model_id) ~= "string" or model_id == "" then
        return not_found("Policy not found")
    end
    local entry = self.store.policies["policy:" .. model_id]
    if not entry or not alive(entry.value) then
        return not_found("Policy not found")
    end
    return handler_response(200, policy_view(entry))
end

---GET /ha/config/{key} —— 值按 Rust 约定 hex 编码。
function _M:ha_config_get(req, key)
    local record = type(key) == "string" and self:get_app(key) or nil
    if not record then
        return not_found("Config not found")
    end
    return handler_response(200, {
        key = key, value = _M.hex_encode(record.value or ""), format = "hex",
    })
end

---POST /ha/config —— body {key, value(hex)}，对齐 update_app_config。
function _M:ha_config_put(req)
    local body, err = json_body(req)
    if not body then
        return handler_response(400, { error = err or "invalid JSON body" })
    end
    if type(body.key) ~= "string" or body.key == "" then
        return handler_response(400, { error = "key is required" })
    end
    local value, verr = _M.hex_decode(body.value or "")
    if not value then
        return handler_response(400, { error = verr })
    end
    self:put_app(body.key, value)
    return handler_response(200, { status = "updated", key = body.key })
end

---POST /ha/rate-limit —— body {limit_per_second}。
function _M:ha_rate_limit_set(req)
    local body, err = json_body(req)
    if not body then
        return handler_response(400, { error = err or "invalid JSON body" })
    end
    local limit = tonumber(body.limit_per_second)
    if not limit or limit < 0 then
        return handler_response(400, { error = "limit_per_second must be a non-negative number" })
    end
    limit = math.floor(limit + 0.5)
    self:set_rate_limit_config(limit)
    self:broadcast_now()
    return handler_response(200, { status = "updated", limit_per_second = limit })
end

---GET /ha/rate-limit
function _M:ha_rate_limit_get(req)
    local config = self:get_rate_limit_config()
    if not config then
        return not_found("Global rate limit not configured")
    end
    return handler_response(200, { limit_per_second = config.limit_per_second or 0 })
end

---GET /ha/rate-limit/stats
function _M:ha_rate_limit_stats(req)
    local config = self:get_rate_limit_config() or { limit_per_second = 0 }
    local limit = config.limit_per_second or 0
    local count = self:rate_value(_M.GLOBAL_RATE_LIMIT_COUNTER_KEY) or 0
    local remaining = -1
    if limit > 0 then
        remaining = math.max(0, limit - count)
    end
    return handler_response(200, {
        limit_per_second = limit,
        current_count = count,
        remaining = remaining,
        window_s = self.config.rate_window_s or 1,
        owner = self:rate_owner(_M.GLOBAL_RATE_LIMIT_COUNTER_KEY),
    })
end

---POST /ha/shutdown —— 标记 draining 并广播；不退出进程（进程生命周期归 supervisor）。
function _M:ha_shutdown(req)
    if not self.draining then
        self.draining = true
        local entry = self.store.members[self.self_name]
        self:put_member({
            name = self.self_name,
            address = (entry and entry.value.address) or self.self_addr or "",
            status = _M.STATUS_LEAVING,
            version = (entry and entry.version or 0) + 1,
        }, self.self_name)
    end
    local sent = self:broadcast_now()
    return handler_response(202, {
        status = "shutdown initiated", node = self.self_name, peers_notified = sent,
    })
end

---GET /ha/stats（本模块补充的观测端点，Rust 无对应路由）。
function _M:ha_stats(req)
    local state, detail = self:partition_state()
    return handler_response(200, {
        node = self.self_name,
        draining = self.draining and true or false,
        partition = state,
        members = _M.count_live(self.store.members),
        alive = detail.alive,
        reachable = detail.reachable,
        unreachable = detail.unreachable,
        unreachable_names = detail.unreachable_names,
        sync_fail = sync_fail_list(self),
        stores = {
            workers = _M.count_live(self.store.workers),
            policies = _M.count_live(self.store.policies),
            apps = _M.count_live(self.store.apps),
            trees = _M.count_live(self.store.trees),
            manual = _M.count_live(self.store.manual),
            rate_keys = rate_key_count(self.store.rate),
        },
        stats = self.stats,
        local_version = self.local_version,
    })
end


return { priv = { handler_response = handler_response } }
