-- mesh.sync —— 需要 cosocket 的一层（http_request + sync_with/sync_tick/
-- broadcast_now/start/stop）、对外路由表 ROUTES 与 dispatch/route_matches/
-- disabled_response、SMG_MESH_* 环境变量装配，以及进程内单例。
local _M = require "resty.luarouter.mesh"

local has_ngx = (type(ngx) == "table")

local handler_response = require "resty.luarouter.mesh.handlers".priv.handler_response

-- ------------------------------------------------------------------ cosocket 层
--
-- 下面三个函数需要 cosocket（ngx.socket.tcp）与 ngx.timer，因此只能跑在
-- OpenResty 里；单测通过注入 mesh.http 覆盖同样的代码路径。

---路由器配置（连接池参数）。纯 Lua 单测里没有完整的 router 装配，所以取不到就
--退化成"不入池"，语义与旧实现一致。
local cached_mesh_config
local function mesh_config()
    if cached_mesh_config ~= nil then
        return cached_mesh_config or nil
    end
    local ok, luarouter = pcall(require, "resty.luarouter")
    if ok and type(luarouter) == "table"
        and type(luarouter.config) == "function" then
        local good, conf = pcall(luarouter.config)
        if good and type(conf) == "table" then
            cached_mesh_config = conf
            return conf
        end
    end
    cached_mesh_config = false
    return nil
end

---内部端点的共享 token（接线层在 init_by_lua 里写入控制面 key）。
--router.lua 用同一把 key 守 /_mesh/internal/*，所以出站同步必须带上它，否则每个
--对端都回 401、成员表永远停在 init（历史实测，git 历史可查）。单测的 http 替身
--不走这里，因此设不设都不影响既有断言。
_M.auth_token = nil

---POST/GET 一个 mesh 内部端点。返回 status, body, err。
---@return number|nil status, string|nil body, string|nil err
function _M.http_request(method, url, body, content_type, timeout_ms)
    local registry_ok, registry = pcall(require, "resty.luarouter.registry")
    if not registry_ok then
        return nil, nil, "registry unavailable: " .. tostring(registry)
    end
    local host, port, tls = registry.split_url(url)
    if not host then
        return nil, nil, "bad peer url: " .. tostring(url)
    end
    local path = string.match(url, "^[%w]+://[^/]+(/.*)$") or "/"
    local timeout = timeout_ms or 2000
    local sock = ngx.socket.tcp()
    sock:settimeouts(timeout, timeout, timeout)
    -- resty.luarouter.config() is the cached router config; pcall because the pure
    -- Lua unit tests load this module without the rest of the router wired up.
    local conf = mesh_config()
    local pool_opts
    if conf then
        pool_opts = registry.pool_opts(conf, "mesh", url)
    end
    local ok, err = sock:connect(host, port, pool_opts)
    if not ok then
        return nil, nil, "connect failed: " .. tostring(err)
    end
    local tls_ok, terr = registry.tls_handshake(sock, host, tls)
    if not tls_ok then
        sock:close()
        return nil, nil, terr
    end
    -- Pooled like every other outbound call, so a sync round per peer per interval
    -- stops paying for a fresh handshake each time. No `Connection: close`: that
    -- header asks the peer to drop the connection setkeepalive() is about to reuse.
    local request = method .. " " .. path .. " HTTP/1.1\r\n"
        .. "Host: " .. host .. ":" .. port .. "\r\n"
        .. "User-Agent: lua-router/mesh\r\n"
        .. "Accept: application/json, application/x-mesh-b64\r\n"
    if _M.auth_token then
        request = request .. "Authorization: Bearer " .. _M.auth_token .. "\r\n"
    end
    if body then
        request = request .. "Content-Type: "
            .. (content_type or "application/x-mesh-b64") .. "\r\n"
            .. "Content-Length: " .. #body .. "\r\n"
    end
    request = request .. "\r\n"
    local bytes, werr = sock:send(request)
    if not bytes then
        sock:close()
        return nil, nil, "send failed: " .. tostring(werr)
    end
    if body then
        local _, berr = sock:send(body)
        if berr then
            sock:close()
            return nil, nil, "send body failed: " .. tostring(berr)
        end
    end
    local head = sock:receive("*l")
    if not head then
        sock:close()
        return nil, nil, "no response head"
    end
    local status = tonumber(string.match(head, "^HTTP/%d%.%d%s+(%d%d%d)"))
    if not status then
        sock:close()
        return nil, nil, "malformed status line: " .. head
    end
    local content_length, chunked, connection = nil, false, nil
    repeat
        local line = sock:receive("*l")
        if line and line ~= "" then
            local name, value = string.match(line, "^([%w%-]+):%s*(.*)$")
            if name then
                local lower = string.lower(name)
                if lower == "content-length" then
                    content_length = tonumber(value)
                elseif lower == "transfer-encoding"
                    and string.lower(value):find("chunked") then
                    chunked = true
                elseif lower == "connection" then
                    connection = value
                end
            end
        end
    until line == nil or line == ""
    local out
    local complete = true
    if chunked then
        out, complete = registry.pump_chunked(sock, true)
    elseif content_length then
        local remaining = content_length
        local parts = {}
        while remaining > 0 do
            local block = sock:receive(math.min(65536, remaining))
            if not block then
                complete = false
                break
            end
            parts[#parts + 1] = block
            remaining = remaining - #block
        end
        out = table.concat(parts)
    else
        -- No framing at all: read to end of stream, which ends the connection.
        out = sock:receive("*a") or ""
        complete = false
    end
    if conf and complete then
        registry.release(sock, conf,
            registry.response_reusable({ connection = connection }, true),
            "mesh", url)
    else
        sock:close()
    end
    return status, out
end

---拉一次对端状态：POST /_mesh/internal/sync，body 是自己的快照。
---返回 applied, err。成功/失败都会更新成员表与 unreachable 计数。
function _M:sync_with(base)
    local name = self:resolve_peer_name(base)
    -- 记下这个地址属于哪个键：身份迁移、以及下一轮的 candidate 排序都靠它。
    self:note_address_key(name, base)
    local send = self.http or _M.http_request
    local snap = self:snapshot()
    local text = _M.encode(snap)
    if not text then
        self:mark_sync_failure(name)
        return 0, "snapshot encode failed"
    end

    -- 候选地址：先试已知写法（验证过的优先），再试调用方给的那个写法。
    local targets = self:peer_candidates(name)
    local has_base = false
    for i = 1, #targets do
        if targets[i] == base then
            has_base = true
        end
    end
    if not has_base and base and base ~= "" then
        targets[#targets + 1] = base
    end
    local status, body
    for _, target in ipairs(targets) do
        status, body = send("POST", target .. "/_mesh/internal/sync", text,
            "application/x-mesh-b64", self.config.rpc_timeout_ms)
        if status then
            -- 对方答了（哪怕 4xx/5xx）就不再换写法：鉴权与状态都是节点级的，
            -- 换地址重问只会把一轮同步的开销乘以写法数。只有连不上（拨号层
            -- 失败）才说明「这个写法是错的」，继续试下一个。
            if status >= 200 and status < 300 then
                -- 记住哪种写法能连通（对端自报的地址未必从本机可达）
                self.used_addr[name] = target
            end
            break
        end
    end

    if not status then
        self.stats.sync_failures = self.stats.sync_failures + 1
        self:mark_sync_failure(name)
        return 0, tostring(body)
    end
    if status < 200 or status >= 300 then
        self.stats.sync_failures = self.stats.sync_failures + 1
        self:mark_sync_failure(name)
        return 0, "peer said " .. status
    end
    local remote, err = _M.decode(body or "")
    if not remote then
        self.stats.sync_failures = self.stats.sync_failures + 1
        self:mark_sync_failure(name)
        return 0, "unreadable peer snapshot: " .. tostring(err)
    end
    local applied, apply_err = self:apply_snapshot(remote)
    if apply_err then
        self.stats.sync_failures = self.stats.sync_failures + 1
        self:mark_sync_failure(name)
        return 0, apply_err
    end
    -- 拨号地址与对端自报名认成同一个节点，这一步把种子键（幻影）合并掉。
    local unified = self:unify_identity(base, remote.node) or name
    -- apply_snapshot 已经把对端自报名记成可达；这里补上「对端没自报名」的情况，
    -- 并且不能再拿旧的名字去记账（那个键可能刚被 migrate 掉）。
    self:mark_sync_success(remote.node or unified)
    self.stats.sync_rounds = self.stats.sync_rounds + 1
    return applied
end

---一轮全对等同步。返回同步过的 peer 数。
function _M:sync_tick()
    local peers = self:peer_bases()
    for i = 1, #peers do
        local ok, err = pcall(self.sync_with, self, peers[i])
        if not ok and has_ngx then
            ngx.log(ngx.ERR, "luarouter: mesh sync with ", peers[i], " failed: ",
                tostring(err))
        end
    end
    self:roll_windows()
    return #peers
end

---立即广播一轮（/ha/shutdown 与 /ha/rate-limit 写后调用）。在无 cosocket 的
--环境里返回 0，这样 handler 在单测里也可调用。
function _M:broadcast_now()
    if not self.http and not has_ngx then
        return 0
    end
    local sent = self:sync_tick()
    self.stats.broadcasts = self.stats.broadcasts + 1
    return sent
end

---周期同步定时器。只在 worker 0 跑：状态表是进程内的，多 worker 各自同步会把
--对等端的负载乘以 worker 数，而收敛结果一样（LWW 幂等）。代价是非 0 号 worker
--的状态落后一个 interval，接线层若要严格一致应把 mesh 与 policy 一样限制
--worker_processes=1（见 doc/gap-mesh.md §4）。
function _M:start()
    if self.started then
        return true
    end
    if not has_ngx or type(ngx.timer) ~= "table" then
        return false, "no ngx.timer (mesh sync needs OpenResty)"
    end
    if #self:peer_bases() == 0 then
        return false, "no mesh peers"
    end
    self.started = true
    local function tick(premature)
        if premature or not self.started then
            return
        end
        local ok, err = pcall(self.sync_tick, self)
        if not ok and has_ngx then
            ngx.log(ngx.ERR, "luarouter: mesh sync tick failed: ", tostring(err))
        end
        local again, aerr = ngx.timer.at(self.config.interval_s, tick)
        if not again then
            self.started = false
            ngx.log(ngx.ERR, "luarouter: mesh sync timer stopped: ", tostring(aerr))
        end
    end
    -- init_by_lua 里 ngx.timer 表存在但 ngx.timer.at 会直接报 "no request"，
    -- 所以用 pcall 兜住：定时器只能在 init_worker 及之后的相位里排。
    local ok, scheduled, serr = pcall(ngx.timer.at, self.config.interval_s, tick)
    if not ok or not scheduled then
        self.started = false
        return false, tostring(scheduled or serr)
    end
    return true
end

function _M:stop()
    self.started = false
end

-- ------------------------------------------------------------------ 路由表与分发
--
-- 一张表说明所有对外端点，接线层可以整块交给 klib.router 注册（见
-- doc/gap-mesh.md §4），也可以按名字单独调 handler。
--   path    相对 /ha 或 /_mesh/internal 的路径（klib.router 的 pattern 形状）
--   method  大小写敏感的 HTTP method（klib.router 逐字匹配）
--   handler _M 上的方法名
--   args    从路由捕获参数里取的位置（worker_id / model_id / key）
_M.ROUTES = {
    { method = "GET",  path = "ha/status",                handler = "ha_status" },
    { method = "GET",  path = "ha/health",                handler = "ha_health" },
    { method = "GET",  path = "ha/workers",               handler = "ha_workers" },
    { method = "GET",  path = "ha/workers/:worker_id",    handler = "ha_worker", args = { "worker_id" } },
    { method = "GET",  path = "ha/policies",              handler = "ha_policies" },
    { method = "GET",  path = "ha/policies/:model_id",    handler = "ha_policy", args = { "model_id" } },
    { method = "GET",  path = "ha/config/:key",           handler = "ha_config_get", args = { "key" } },
    { method = "POST", path = "ha/config",                handler = "ha_config_put" },
    { method = "GET",  path = "ha/rate-limit",            handler = "ha_rate_limit_get" },
    { method = "POST", path = "ha/rate-limit",            handler = "ha_rate_limit_set" },
    { method = "GET",  path = "ha/rate-limit/stats",      handler = "ha_rate_limit_stats" },
    { method = "POST", path = "ha/shutdown",              handler = "ha_shutdown" },
    { method = "GET",  path = "ha/stats",                 handler = "ha_stats" },
    { method = "GET",  path = "_mesh/internal/ping",      handler = "handle_ping" },
    { method = "POST", path = "_mesh/internal/sync",      handler = "handle_sync" },
    { method = "POST", path = "_mesh/internal/apply",     handler = "handle_apply" },
    { method = "GET",  path = "_mesh/internal/state",     handler = "handle_state" },
}

---未启用 mesh 时的固定响应。接线层在拿不到 mesh 实例时用它回答 /ha/*，响应与
---router.lua 现在的 mesh_disabled_handler 逐字节一致（契约测试锁定了这个 body）。
function _M.disabled_response()
    return handler_response(503, '{"error":"mesh not enabled"}', "application/json")
end

---按路径分发（对齐 Rust /ha/* 与内部端点）。mesh 未启用一律 503 固定体。
---@param mesh table|nil @ 关闭时传 nil
---@param method string
---@param path string  @ 以 / 开头的请求路径
---@param params table|nil @ klib.router 的捕获参数
---@param req table|nil @ 请求对象（{body=} 或带 get_body 的对象）
function _M.dispatch(mesh, method, path, params, req)
    if not mesh then
        return _M.disabled_response()
    end
    local trimmed = path
    if trimmed:sub(1, 1) == "/" then
        trimmed = trimmed:sub(2)
    end
    for i = 1, #_M.ROUTES do
        local route = _M.ROUTES[i]
        if route.method == method and _M.route_matches(route.path, trimmed) then
            local fn = mesh[route.handler]
            if type(fn) ~= "function" then
                return handler_response(500, { error = "mesh handler missing: " .. route.handler })
            end
            if route.args then
                local args = {}
                for j = 1, #route.args do
                    args[j] = params and params[route.args[j]]
                end
                return fn(mesh, req, args[1], args[2])
            end
            return fn(mesh, req)
        end
    end
    if path:sub(1, 4) == "/ha/" or path == "/ha" then
        -- Rust 的 404 兜底：/ha 前缀下的未知路径同样回 mesh not enabled；这里
        -- mesh 已启用，用同样的固定体表示「这条路由本实现不提供」。
        return handler_response(404, { error = "unknown ha route: " .. method .. " " .. path })
    end
    return nil
end

---把 "ha/workers/:worker_id" 与请求路径做段级比较（':' 段通配一段）。
function _M.route_matches(pattern, path)
    local p, q = 1, 1
    while true do
        local p_seg = string.match(pattern, "^:([^/]+)", p)
        local q_seg_end = string.find(path, "/", q, true) or (#path + 1)
        if p_seg then
            if q >= #path + 1 then
                return false
            end
            p = p + #p_seg + 1
            q = q_seg_end + 1
        else
            local lit_end = string.find(pattern, "/", p, true) or (#pattern + 1)
            local literal = string.sub(pattern, p, lit_end - 1)
            if string.sub(path, q, q_seg_end - 1) ~= literal then
                return false
            end
            if lit_end > #pattern and q_seg_end > #path then
                return true
            end
            if lit_end > #pattern or q_seg_end > #path then
                return false
            end
            p = lit_end + 1
            q = q_seg_end + 1
        end
    end
end


-- ------------------------------------------------------------------ 环境变量装配

---从环境变量装配 mesh（SMG_MESH_PEERS / SMG_MESH_SELF 是任务书指定的两个名字，
--其余 SMG_MESH_* 是可选覆盖）。peers 为空时返回 nil —— 与 Rust 不带
-- --enable-mesh 时的行为一致，/ha/* 全部 503。
function _M.from_env(getenv, opts)
    local raw = getenv or (type(os) == "table" and os.getenv) or function() return nil end
    local take = function(name)
        local value = raw(name)
        if value == nil or value == "" then
            return nil
        end
        return value
    end
    local peers_text = take("SMG_MESH_PEERS")
    if not peers_text then
        return nil, "SMG_MESH_PEERS not set"
    end
    local peers = _M.parse_peers(peers_text)
    local self_addr = take("SMG_MESH_SELF") or take("SMG_MESH_SELF_ADDR")
    -- 本实例可以不在 peers 里（Rust 的 init_peer 允许只写对等端）；不在则补进去
    -- 也不算错，成员表最终靠同步收敛。
    local opts_tbl = {
        peers = peers,
        self_addr = self_addr,
        self_name = take("SMG_MESH_SELF_NAME")
            or (self_addr and _M.hostport_from_url(self_addr)),
        interval_s = tonumber(take("SMG_MESH_SYNC_INTERVAL_SECS")) or 2,
        unreachable_s = tonumber(take("SMG_MESH_UNREACHABLE_TIMEOUT_SECS")) or 30,
        suspect_threshold = tonumber(take("SMG_MESH_SUSPECT_THRESHOLD")) or 2,
        quorum = tonumber(take("SMG_MESH_QUORUM")),
        min_cluster_size = tonumber(take("SMG_MESH_MIN_CLUSTER_SIZE")) or 3,
        rate_window_s = tonumber(take("SMG_MESH_RATE_WINDOW_SECS")) or 1,
        rpc_timeout_ms = tonumber(take("SMG_MESH_RPC_TIMEOUT_MS")) or 2000,
        snapshot_max_bytes = tonumber(take("SMG_MESH_SNAPSHOT_MAX_BYTES"))
            or (3 * 1024 * 1024),
    }
    if opts then
        for k, v in pairs(opts) do
            opts_tbl[k] = v
        end
    end
    return _M.new(opts_tbl)
end


-- ------------------------------------------------------------------ 模块级单例
--
-- 与 policy.default / hb 的配置读取一样，mesh 实例是进程内的：router 的接线
-- 代码通过 _M.instance() 拿到它做本地写入，init_worker 负责构造与启动定时器。

local instance

---构造并保存进程内的 mesh 实例（已存在则返回原实例）。
function _M.init(getenv, opts)
    if instance then
        return instance
    end
    local mesh, err = _M.from_env(getenv, opts)
    if not mesh then
        return nil, err
    end
    instance = mesh
    return instance
end

---@return table|nil mesh
function _M.instance()
    return instance
end

---测试与热重载用：替换（传 nil 即清空）进程内实例。
function _M.set_instance(mesh)
    instance = mesh
    return instance
end

return { priv = {} }
