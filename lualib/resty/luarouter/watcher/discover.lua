local cjson = require "cjson.safe"

local _M = require "resty.luarouter.watcher"
local env_mod = require "resty.luarouter.watcher.env"
local json_decode = cjson.decode
local uri_encode = env_mod.uri_encode
local has_ngx = env_mod.has_ngx

-- watcher/discover.lua -- the three discovery sources (docker published
-- ports beat container IPs, /proc listening sockets, the allow-list), the
-- candidate merge that carries gpu/label across sources, and the docker
-- unix-socket transport.  Moved verbatim (pure 786-1057 + live 1944-2113).

-- ------------------------------------------------------------------ discovery

---Listening TCP sockets as {host, port} from /proc/net/tcp{,6}.
---
---Pure Lua (io.open, no io.popen): this is what catches host-network containers
---(their ports are published by the kernel, not by docker-proxy) and bare native
---processes such as a llama.cpp server. 0A is the TCP_LISTEN state.
---@param reader function|nil @ (path) -> lines (injectable for tests)
---@return table[] @ { {host=, port=}, ... } unique
function _M.listening_sockets(reader)
    reader = reader or function(path)
        local handle = io.open(path, "r")
        if not handle then
            return nil
        end
        local text = handle:read("*a")
        handle:close()
        return text
    end
    local out, seen = {}, {}
    for _, spec in ipairs({ { "/proc/net/tcp", false }, { "/proc/net/tcp6", true } }) do
        local text = reader(spec[1])
        if type(text) == "string" then
            local is_v6 = spec[2]
            local first = true
            for line in string.gmatch(text, "[^\n]+") do
                if first then
                    first = false   -- the header line
                else
                    local fields = {}
                    for field in string.gmatch(line, "%S+") do
                        fields[#fields + 1] = field
                    end
                    if #fields >= 4 and fields[4] == "0A" then
                    local hex_ip, hex_port = string.match(fields[2], "^([^:]+):(%x+)$")
                    local port = tonumber(hex_port, 16)
                    if hex_ip and port then
                        local host
                        -- The kernel prints the hex in lower case; normalising keeps
                        -- the v4-mapped test below from depending on it.
                        hex_ip = string.lower(hex_ip)
                        if not is_v6 then
                            local parts = {}
                            for i = 1, 4 do
                                parts[i] = tonumber(string.sub(hex_ip, (i - 1) * 2 + 1, i * 2), 16)
                            end
                            -- little-endian hex -> dotted quad
                            host = table.concat({ parts[4], parts[3], parts[2], parts[1] }, ".")
                        else
                            -- /proc stores an IPv6 address as four little-endian
                            -- 32-bit words, so the bytes have to be reversed inside
                            -- each word before the address can be read. The daemon
                            -- compares the *raw* hex against "0..01" and
                            -- "0..ffff.." instead, which real /proc output never
                            -- spells that way, so a ::1 or a v4-mapped listener is
                            -- mis-decoded there and the self-loop guard then misses
                            -- it. Swapping first makes both cases come out right.
                            local bytes = {}
                            for word = 1, 4 do
                                local group = string.sub(hex_ip, (word - 1) * 8 + 1, word * 8)
                                if #group ~= 8 then
                                    bytes = nil
                                    break
                                end
                                for b = 4, 1, -1 do
                                    bytes[#bytes + 1] = string.sub(group, (b - 1) * 2 + 1, b * 2)
                                end
                            end
                            local wire = bytes and table.concat(bytes) or nil
                            if not wire or #wire ~= 32 then
                                -- malformed line: skip it rather than guess
                            elseif wire == string.rep("0", 32) then
                                host = "::"
                            elseif wire == string.rep("0", 31) .. "1" then
                                host = "::1"
                            elseif string.sub(wire, 1, 24) == string.rep("0", 20) .. "ffff" then
                                -- v4-mapped: ten zero bytes, two 0xff bytes, then the
                                -- address itself (which is big-endian once swapped).
                                local parts = {}
                                for i = 1, 4 do
                                    parts[i] = tonumber(string.sub(wire, 24 + (i - 1) * 2 + 1,
                                        24 + i * 2), 16)
                                end
                                host = table.concat(parts, ".")
                            else
                                local groups = {}
                                for g = 1, 8 do
                                    local text = string.sub(wire, (g - 1) * 4 + 1, g * 4)
                                        :gsub("^0+", "")
                                    groups[g] = (text == "") and "0" or text
                                end
                                host = table.concat(groups, ":")
                            end
                        end
                            local key = host .. "|" .. port
                            if not seen[key] then
                                seen[key] = true
                                out[#out + 1] = { host = host, port = port }
                            end
                        end
                    end
                end
            end
        end
    end
    return out
end

---Candidates from a /containers/json document (the caller does the socket read).
---
---Published ports win over container-internal IPs: one instance must map to
---exactly one worker URL, two URLs for the same instance would split the prefix
---cache. Also returns {published_port = container_name} so a proc-scan candidate
---can be labelled with the container that owns it.
---@param containers table|nil
---@param include_container_ips boolean|nil
---@return table[] candidates, table port_names
function _M.docker_candidates_from(containers, include_container_ips)
    local cands, port_names = {}, {}
    if type(containers) ~= "table" then
        return cands, port_names
    end
    for _, ctr in ipairs(containers) do
        local names = type(ctr.Names) == "table" and ctr.Names or {}
        local name = string.gsub(names[1] or ctr.Id or "container", "^/", "")
        local host_net = type(ctr.HostConfig) == "table"
            and ctr.HostConfig.NetworkMode == "host"
        local published, mapped_private = {}, {}
        local ports = type(ctr.Ports) == "table" and ctr.Ports or {}
        for i = 1, #ports do
            local binding = ports[i]
            local public = tonumber(binding.PublicPort)
            if public then
                published[public] = true
                local private = tonumber(binding.PrivatePort)
                if private then mapped_private[private] = true end
                port_names[public] = name
                cands[#cands + 1] = {
                    url = _M.normalize_url("http://127.0.0.1:" .. public),
                    source = "docker", label = name,
                    instance_key = ctr.Id, gpu = _M.gpu_from_name(name),
                }
            end
        end
        -- Host-network containers share the host stack: /proc/net/tcp already
        -- covers their ports, and their "container IP" is a host address, so the
        -- container-IP half is skipped there (and when the operator opted out).
        local networks = (type(ctr.NetworkSettings) == "table"
            and type(ctr.NetworkSettings.Networks) == "table")
            and ctr.NetworkSettings.Networks or {}
        if not host_net and include_container_ips ~= false then
            for _, net in pairs(networks) do
                local ip = type(net) == "table" and net.IPAddress or nil
                if type(ip) == "string" and ip ~= "" then
                    local net_ports = type(net.Ports) == "table" and net.Ports or {}
                    for key in pairs(net_ports) do
                        local cport = tonumber(string.match(tostring(key), "^(%d+)"))
                        if cport and not published[cport] and not mapped_private[cport] then
                            cands[#cands + 1] = {
                                url = _M.normalize_url("http://" .. ip .. ":" .. cport),
                                source = "docker-net", label = name, instance_key = ctr.Id,
                                -- 卡是**容器**的属性，不是「这个地址被哪种方式发现」的属性，
                                -- 所以容器 IP 这一路照抄发布端口那一路的解析。这里以前不填
                                -- gpu，是 bridge 网络里的 worker 丢掉自己逐卡读数的第一道断点：
                                -- 同一个容器同时贡献 docker 与 docker-net 两条候选，而
                                -- unique_candidates 的旧写法按 source 择优后整条替换，输的那条
                                -- 会把 gpu 一起带走。
                                gpu = _M.gpu_from_name(name),
                            }
                        end
                    end
                end
            end
        end
    end
    return cands, port_names
end

---Listening sockets -> candidates (local_candidates). A wildcard bind is probed
---through loopback, which is the only address guaranteed to answer.
---@param sockets table[] @ {host=, port=}
---@param deny table|nil @ set of ports
---@param allow table|nil @ when non-empty, probe ONLY these ports
---@return table[]
function _M.local_candidates(sockets, deny, allow)
    local cands = {}
    for i = 1, #sockets do
        local item = sockets[i]
        local port = tonumber(item.port)
        if port then
            local wanted = (allow == nil or next(allow) == nil) or allow[port] == true
            if wanted and not (deny and deny[port]) then
                local host = item.host
                local target
                if host == "0.0.0.0" or host == "::" then
                    target = "127.0.0.1"
                elseif string.find(host, ":", 1, true) then
                    target = "[" .. host .. "]"
                else
                    target = host
                end
                cands[#cands + 1] = {
                    url = _M.normalize_url("http://" .. target .. ":" .. port),
                    source = "proc",
                }
            end
        end
    end
    return cands
end

---Candidate priority so one URL keeps its most specific source (docker beats
---proc beats the allow-list).
local SOURCE_ORDER = { docker = 1, cli = 2, ["docker-net"] = 3, proc = 4,
                       ["allow-list"] = 5 }

---把 src 的卡号/容器名补进 dst（只在 dst 自己缺失时，已有值绝不被覆盖）。
---就地改写：候选表每轮都由 docker_candidates_from / local_candidates 现造，改写它不
---影响任何调用方持有的数据，重复调用同样幂等。
---@param dst table
---@param src table
---@return table dst
local function carry_identity(dst, src)
    if (dst.gpu == nil or dst.gpu == false)
        and src.gpu ~= nil and src.gpu ~= false then
        dst.gpu = src.gpu
    end
    if (dst.label == nil or dst.label == false)
        and src.label ~= nil and src.label ~= false then
        dst.label = src.label
    end
    return dst
end

---Merge candidate lists into unique URLs with their owning label (collect()).
---
---择优仍按 source（docker 胜过 proc 胜过 allow-list），但 gpu / label 改成「取第一个
---非 nil 的」而不是跟着胜者整条替换。理由：这两个字段描述的是**端口背后的那个容器**，
---不是「这个 url 由哪一路扫到」。21.k 的形状正是 bridge 容器 + 发布端口——同一个容器
---同时贡献 docker（127.0.0.1:public）与 docker-net（172.x:container）两条候选，旧写法
---择优后把败者整条丢弃，于是存活那条不带 gpu，make_register 的 labels.gpu 恒 nil，
---逐卡功率就永远接不上。字段只在胜者自己缺失时才补，绝不会覆盖一条本来就写了卡号的候选。
---@param lists table[]
---@return table[]
function _M.unique_candidates(lists)
    local by_url = {}
    for i = 1, #lists do
        for _, cand in ipairs(lists[i] or {}) do
            if cand.url then
                local existing = by_url[cand.url]
                if not existing then
                    by_url[cand.url] = cand
                elseif (SOURCE_ORDER[cand.source] or 9)
                    < (SOURCE_ORDER[existing.source] or 9) then
                    by_url[cand.url] = carry_identity(cand, existing)
                else
                    carry_identity(existing, cand)
                end
            end
        end
    end
    local out = {}
    for url in pairs(by_url) do
        out[#out + 1] = by_url[url]
    end
    table.sort(out, function(a, b)
        local oa, ob = SOURCE_ORDER[a.source] or 9, SOURCE_ORDER[b.source] or 9
        if oa ~= ob then return oa < ob end
        return a.url < b.url
    end)
    return out
end

-- ------------------------------------------------------------ docker discovery

---One HTTP GET over a unix socket.
---
---Verified against this box's daemon (OpenResty 1.31): the table form of connect
---(`{path = ...}`) is NOT supported in this build and raises "string expected, got
---table", so the "unix:<path>" string form is the one to use. The reply is chunked, and
---the request carries Connection: close so a daemon that ignores framing still ends the
---read. `path` must already be percent-encoded.
---@param socket_path string
---@param path string
---@param timeout_ms number
---@return number|nil status, string|nil body, string|nil err
function _M.unix_get(socket_path, path, timeout_ms)
    if not has_ngx then
        return nil, nil, "no ngx"
    end
    local sock = ngx.socket.tcp()
    sock:settimeout(timeout_ms or 2000)
    local ok, err = sock:connect("unix:" .. socket_path)
    if not ok then
        return nil, nil, "connect failed: " .. tostring(err)
    end
    local request = "GET " .. path .. " HTTP/1.1\r\n"
        .. "Host: localhost\r\nAccept: */*\r\nConnection: close\r\n\r\n"
    local sent, werr = sock:send(request)
    if not sent then
        sock:close()
        return nil, nil, "send failed: " .. tostring(werr)
    end
    local status_line = sock:receive("*l")
    if not status_line then
        sock:close()
        return nil, nil, "no response line"
    end
    local status = tonumber(string.match(status_line, "^HTTP/%d%.%d%s+(%d%d%d)"))
    local content_length, chunked = nil, false
    while true do
        local line = sock:receive("*l")
        if line == nil or line == "" then
            break
        end
        local name, value = string.match(line, "^([%w%-]+):%s*(.*)$")
        if name then
            local lowered = string.lower(name)
            if lowered == "content-length" then
                content_length = tonumber(value)
            elseif lowered == "transfer-encoding"
                and string.lower(value or ""):find("chunked") then
                chunked = true
            end
        end
    end
    local body = ""
    if chunked then
        local registry_mod = require "resty.luarouter.registry"
        body = registry_mod.pump_chunked(sock, true)
    elseif content_length and content_length > 0 then
        local remaining = content_length
        while remaining > 0 do
            local block = sock:receive(math.min(65536, remaining))
            if not block then
                break
            end
            body = body .. block
            remaining = remaining - #block
        end
    else
        body = sock:receive("*a") or ""
    end
    sock:close()
    return status or 0, body
end

---Running containers as a decoded array, or nil.
---@param cfg table
---@return table|nil
local function docker_containers(cfg)
    local path = "/containers/json?filters="
        .. uri_encode('{"status":["running"]}')
    local status, body, err = _M.unix_get(cfg.docker_socket, path,
        math.max(1000, (cfg.probe_timeout_secs or 4) * 1000))
    if not status or status < 200 or status >= 300 then
        if err then
            ngx.log(ngx.INFO, "luarouter: watcher docker scan skipped: ", err)
        end
        return nil
    end
    local decoded = json_decode(body or "")
    if type(decoded) ~= "table" then
        return nil
    end
    return decoded
end

-- -------------------------------------------------------------- candidate scan

---Build the candidate list from the enabled sources (the daemon's collect()).
---@param cfg table
---@param reader function|nil @ injectable /proc reader for tests
---@return table[]
function _M.collect(cfg, reader)
    local lists = {}
    local targets = {}
    for i = 1, #(cfg.targets or {}) do
        local url = _M.normalize_url(cfg.targets[i])
        if url then
            targets[#targets + 1] = { url = url, source = "cli", label = "static" }
        else
            ngx.log(ngx.WARN, "luarouter: watcher ignoring bad target ",
                tostring(cfg.targets[i]))
        end
    end
    lists[#lists + 1] = targets

    local port_names = {}
    if cfg.scan_docker then
        local containers = docker_containers(cfg)
        local cands, names = _M.docker_candidates_from(containers,
            cfg.scan_container_ips)
        for port, name in pairs(names) do
            port_names[port] = name
        end
        lists[#lists + 1] = cands
    end

    if cfg.scan_proc then
        -- Same rule as the daemon (llm_watcher.py:769): the operator's deny list and
        -- the default list are a *union*, and the default only applies while the scan
        -- has not been narrowed with SMG_WATCHER_ALLOW_PORT (an explicit allow list is
        -- "probe exactly these", so trimming it further by default is pointless).
        -- An earlier shape of this branch assigned one list or the other, so with no
        -- allow list SMG_WATCHER_DENY_PORT was dropped wholesale and every port the
        -- operator named (11022/14389/42209 on this box) kept being probed.
        local narrowed = next(cfg.allow_ports) ~= nil
        local deny
        if narrowed then
            deny = cfg.deny_ports
        else
            deny = _M.union_port_sets(cfg.deny_ports, _M.DEFAULT_DENY_PORTS)
        end
        local sockets = _M.listening_sockets(reader)
        local cands = _M.local_candidates(sockets, deny, cfg.allow_ports)
        for i = 1, #cands do
            local _, _, port = _M.split_http(cands[i].url)
            if port and port_names[port] and not cands[i].label then
                cands[i].label = port_names[port]
            end
        end
        lists[#lists + 1] = cands
    end

    local allowed = {}
    if next(cfg.allow_ports) ~= nil then
        local ports = {}
        for port in pairs(cfg.allow_ports) do
            ports[#ports + 1] = port
        end
        table.sort(ports)
        for i = 1, #ports do
            allowed[#allowed + 1] = {
                url = _M.normalize_url("http://127.0.0.1:" .. ports[i]),
                source = "allow-list",
            }
        end
    end
    lists[#lists + 1] = allowed

    return _M.unique_candidates(lists)
end

return _M
