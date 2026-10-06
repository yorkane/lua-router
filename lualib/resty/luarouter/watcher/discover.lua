local cjson = require "cjson.safe"

local _M = require "resty.luarouter.watcher"
local env_mod = require "resty.luarouter.watcher.env"
local json_decode = cjson.decode
local uri_encode = env_mod.uri_encode
local has_ngx = env_mod.has_ngx
local gpu_from_cmdline = env_mod.gpu_from_cmdline

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
                                -- inode 是 /proc/net/tcp 自带的第 10 列（不是新扫描），
                                -- 只顺手记下，给下面的 socket->pid GPU 标注用。桩数据
                                -- （单测注入的假 /proc）通常没有这一列 -> nil -> 不触发扫描。
                                out[#out + 1] = { host = host, port = port,
                                                  inode = tonumber(fields[10]) }
                            end
                        end
                    end
                end
            end
        end
    end
    return out
end

------------------------------------------------------------------ gpu label
-- doc/caps-redesign-2026-10-06.md §9：给 proc 路径发现的实例补 GPU 归属标注。
--
-- 这段是**纯 label 采集**，不参与任何判定：结果只写进候选自己的 gpu 字段，
-- 后面由 reconcile 现成的 info.gpu / ledger.set_gpu_hint 那条链带给 /workers 与
-- gpu_load 逐卡归属。它不进排除、不进摘除、不进探针、不进宽限，任何一步失败
-- （/proc 不可读、权限不够、格式变、ffi 不在）一律 nil —— 服务发现本身一个字节
-- 都不受影响（watcher 十条守卫与探针分档红线的原样前提）。
--
-- 开销控制（watcher 每 tick 都跑这条路径，不能让它变重）：
--  1. **不需要的 tick 零开销**：只有「至少一个 proc 候选自己不带 gpu，且它的
--     LISTEN socket 拿到了 inode」才开扫（want 集为空 -> 直接 return，一次
--     syscall 都不新增）。
--  2. **先看 cmdline，再决定要不要碰 fd 目录**：绝大多数进程既没有 --device-id
--     也没有 CUDA_VISIBLE_DEVICES，一次 io.open 就被排除，根本不进它的 fd 枚举。
--     于是每 tick 的实际成本约等于「一次 /proc 目录列举 + 每个 pid 一次 cmdline
--     open + 少数几个 GPU 进程的 fd readlink」，而不是「全机所有 fd 全扫」。
--  3. **限量**：单 tick 最多看 PID_LIMIT 个 pid；单个 pid 的 fd 条目超过
--     FD_LIMIT（python 推理服务能开到上千）就放弃该 pid；readlink 总额
--     READLINK_LIMIT，超了带着「认不出」收工。异常膨胀只会让标注变 nil，不会拖长 tick。
--  4. **memo（一次 collect() = 一个 tick）**：同 inode 解析一次就丢出 want 集
--     （全部命中立刻提前结束）、同 pid 的 cmdline 只读一次。跨 tick 不缓存：
--     pid 会被回收复用，把上一轮的卡号留给新进程正是这类标注最容易出错的地方。

local PROC_GPU_PID_LIMIT = 4096        -- 单 tick 最多探测的 pid 数
local PROC_GPU_FD_LIMIT = 2048         -- 单个 pid 最多枚举的 fd 条目数
local PROC_GPU_READLINK_LIMIT = 16384  -- 单 tick readlink 总额
local PROC_GPU_ITER_LIMIT = 16         -- readdir 迭代保险丝倍数
local SOCKET_PREFIX = "socket:["
-- 独立的字面 pattern：SOCKET_PREFIX 的 "[" 在这里必须转义成 %[，所以不复用它。
local SOCKET_INODE = "^socket:%[(%d+)%]$"

local ffi_tried = false
local ffi_backend = nil

---The two /proc primitives that pure io.open cannot do: list a directory and read
---a symlink.  io.popen is deliberately off the table (per-tick background path --
---forking a shell every pass is out of the question, and the watcher's own contract
---is pure file reads), and the image carries no lfs, so libc through LuaJIT's ffi
---is the only available primitive.  Anything missing or shape-incompatible yields
---nil, which the caller degrades to "no gpu label".
---@return table|nil @{ffi=, C=, link_buf=}
local function syscall_backend()
    if ffi_tried then
        return ffi_backend
    end
    ffi_tried = true
    local ok, ffi = pcall(require, "ffi")
    if not ok or type(ffi) ~= "table" or type(ffi.cdef) ~= "function" then
        return nil
    end
    local declared = pcall(function()
        ffi.cdef([=[
typedef struct { unsigned long long d_ino; long long d_off;
                 unsigned short d_reclen; unsigned char d_type;
                 char d_name[256]; } lr_watch_dirent;
typedef struct __dirstream lr_watch_DIR;
lr_watch_DIR *opendir(const char *name);
lr_watch_dirent *readdir(lr_watch_DIR *dirp);
int closedir(lr_watch_DIR *dirp);
long readlink(const char *path, char *buf, unsigned long bufsiz);
]=])
    end)
    if not declared then
        -- 名字与别的模块的 cdef 撞了：这是纯 label，直接放弃，不跟它抢
        return nil
    end
    local built = pcall(function()
        ffi_backend = { ffi = ffi, C = ffi.C, link_buf = ffi.new("char[64]") }
    end)
    if not built then
        ffi_backend = nil
    end
    return ffi_backend
end

---Entry names of a directory.  Returns nil when the directory is unreadable
---(missing, no permission) or when it overflowed the limit and reject_overflow
---asked for that to count as unreadable.
---@param bk table @ syscall_backend()
---@param path string
---@param limit number
---@param reject_overflow boolean
---@return table|nil names, boolean overflow
local function dir_names(bk, path, limit, reject_overflow)
    local dir = bk.C.opendir(path)
    if dir == nil then          -- NULL：不可读/不存在，绝不把空指针交给 readdir
        return nil, false
    end
    local names, iterations, overflow = {}, 0, false
    local hard_cap = limit * PROC_GPU_ITER_LIMIT + 128
    while true do
        iterations = iterations + 1
        if iterations > hard_cap then
            overflow = true
            break
        end
        local ent = bk.C.readdir(dir)
        if ent == nil then      -- NULL：读完或出错，两者都按"到此为止"处理
            break
        end
        -- d_name 紧跟在 19 字节的头后面，整条记录 d_reclen 字节；按 d_reclen 收窄
        -- 读取范围，绝不越过内核交给我们的那块缓冲。
        local reclen = tonumber(ent.d_reclen) or 0
        if reclen < 19 or reclen > 65536 then
            -- 记录长度读不出可信值 = 布局不是我们认的那个：整个目录按"读不了"处理，
            -- 不拿 255 去猜（那会读到缓冲外面去）。降级 = 没有 gpu 标注。
            overflow = true
            break
        end
        local room = reclen - 19
        if room > 255 then room = 255 end
        if room < 1 then room = 1 end
        local chars = {}
        local k = 0
        while k < room do
            local c = ent.d_name[k]
            if c == 0 then break end
            chars[#chars + 1] = string.char(tonumber(c))
            k = k + 1
        end
        local name = table.concat(chars)
        if name ~= "" and name ~= "." and name ~= ".." then
            if #names >= limit then
                overflow = true
                break
            end
            names[#names + 1] = name
        end
    end
    bk.C.closedir(dir)
    if overflow and reject_overflow then
        return nil, true
    end
    return names, overflow
end

---One readlink, into the shared per-tick buffer.  nil on any error.
---@param bk table
---@param path string
---@return string|nil
local function link_target(bk, path)
    local n = bk.C.readlink(path, bk.link_buf, 63)
    if n == nil or n < 0 or n > 63 then
        return nil
    end
    local ok, target = pcall(bk.ffi.string, bk.link_buf, tonumber(n))
    if not ok then
        return nil
    end
    return target
end

---@param target string|nil
---@return number|nil @ the socket inode, nil when this fd is not a socket
local function socket_inode_of(target)
    if type(target) ~= "string" or string.sub(target, 1, #SOCKET_PREFIX) ~= SOCKET_PREFIX then
        return nil
    end
    local digits = string.match(target, SOCKET_INODE)
    return tonumber(digits)
end

local function read_whole(path)
    local handle = io.open(path, "r")
    if not handle then
        return nil
    end
    local body = handle:read("a")
    handle:close()
    return body
end

---Resolve inode -> gpu id for the wanted LISTEN sockets by walking /proc once.
---Every failure mode (no ffi, unreadable /proc, odd layout, budget spent) simply
---leaves the inode out of the result, i.e. "no label".
---@param bk table
---@param want table @ {[inode number]=true}; resolved inodes are removed as we go
---@param root string @ normally "/proc"
---@param counters table|nil @ 可选计数器：**只有探针传**，生产路径恒 nil（不多走一个分支）。
---        pids_seen / cmdline_reads / fd_dirs / fd_entries / fd_skipped / readlinks /
---        readlinks_capped / pids_capped
---@return table @ {[inode number]=gpu id}
local function scan_proc_for_gpu(bk, want, root, counters)
    local found = {}
    local pids = dir_names(bk, root, PROC_GPU_PID_LIMIT, false)
    if not pids then
        return found
    end
    if counters then counters.pids_seen = #pids end
    local pending = 0
    for _ in pairs(want) do
        pending = pending + 1
    end
    local cmdline_memo, readlinks = {}, 0
    for i = 1, #pids do
        if pending == 0 then
            break                       -- 全部命中，提前收工
        end
        if readlinks >= PROC_GPU_READLINK_LIMIT then
            if counters then counters.readlinks_capped = true end
            break                       -- 预算花完：剩下的按"认不出"处理
        end
        if i > PROC_GPU_PID_LIMIT then
            if counters then counters.pids_capped = true end
            break                       -- pid 预算花完：同样只是"认不出"
        end
        local pid = pids[i]
        if tonumber(pid) then
            -- 同一 pid 本 tick 只读一次 cmdline（kernel 线程读到空串，同样进 memo）
            local gpu = cmdline_memo[pid]
            if gpu == nil then
                if counters then
                    counters.cmdline_reads = (counters.cmdline_reads or 0) + 1
                end
                local body = nil
                local ok, value = pcall(read_whole, root .. "/" .. pid .. "/cmdline")
                if ok then body = value end
                local parsed = nil
                if type(body) == "string" then
                    local ok2, gpu_value = pcall(gpu_from_cmdline, body)
                    if ok2 and type(gpu_value) == "string" then
                        parsed = gpu_value
                    end
                end
                gpu = parsed or false
                cmdline_memo[pid] = gpu
            end
            if gpu ~= false then
                local fds = dir_names(bk, root .. "/" .. pid .. "/fd",
                    PROC_GPU_FD_LIMIT, true)
                if counters then
                    counters.fd_dirs = (counters.fd_dirs or 0) + 1
                    if fds then counters.fd_entries = (counters.fd_entries or 0) + #fds
                    else counters.fd_skipped = (counters.fd_skipped or 0) + 1 end
                    counters.fd_dirs_pid = counters.fd_dirs_pid or {}
                    counters.fd_dirs_pid[pid] = (counters.fd_dirs_pid[pid] or 0) + 1
                end
                if fds then
                    for j = 1, #fds do
                        if readlinks >= PROC_GPU_READLINK_LIMIT or pending == 0 then
                            break
                        end
                        if tonumber(fds[j]) then
                            readlinks = readlinks + 1
                            local target = link_target(bk,
                                root .. "/" .. pid .. "/fd/" .. fds[j])
                            local ino = socket_inode_of(target)
                            if ino ~= nil and want[ino] then
                                want[ino] = nil
                                pending = pending - 1
                                found[ino] = gpu
                            end
                        end
                    end
                end
            end
        end
    end
    if counters then counters.readlinks = readlinks end
    return found
end

---Fill gpu labels onto proc-sourced candidates that have none (never overwrites
---a value another source already wrote -- docker 那一路从容器名解析出的卡号优先).
---@param cands table[]
---@param opts table|nil @{proc_root=, gpu_lookup=, counters=}（探针注入假 /proc 与计数器；
---        生产调用方一个都不传，counters 恒 nil）
local function annotate_proc_gpu(cands, opts)
    opts = opts or {}
    local want, need = {}, 0
    for i = 1, #cands do
        local cand = cands[i]
        -- 只给 proc 一路补：docker 一路的卡号（容器名解析）永远优先，这里一个字段都不碰它
        if cand.source == "proc" and (cand.gpu == nil or cand.gpu == false) then
            local ino = tonumber(cand.inode)
            if ino ~= nil and ino > 0 and want[ino] == nil then
                want[ino] = true
                need = need + 1
            end
        end
    end
    if need == 0 then
        return                       -- 没有候选要标注：本 tick 零新增开销
    end
    local root = opts.proc_root or "/proc"
    local lookup = opts.gpu_lookup
    if lookup == nil then
        local bk = syscall_backend()
        if bk == nil then
            return
        end
        lookup = function(w)
            return scan_proc_for_gpu(bk, w, root, opts.counters)
        end
    end
    local ok, got = pcall(lookup, want)
    if not ok or type(got) ~= "table" then
        return                       -- 探针式的意外：放弃标注，不影响发现
    end
    for i = 1, #cands do
        local cand = cands[i]
        if cand.source == "proc" and (cand.gpu == nil or cand.gpu == false) then
            local ino = tonumber(cand.inode)
            local gpu = ino ~= nil and got[ino] or nil
            if type(gpu) == "string" and gpu ~= "" then
                cand.gpu = gpu
            end
        end
    end
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
                    -- inode 随候选带下来，annotate_proc_gpu 拿它去 /proc 找属主进程。
                    -- 桩 reader（单测假 /proc）没有这一列 -> nil -> 扫描整个跳过。
                    inode = item.inode,
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
---@param gpu_opts table|nil @{proc_root=, gpu_lookup=} injected only by the
---        GPU-label probe; the daemon (live.run_pass) never passes it, so the
---        production path always takes the real-/proc branch.
function _M.collect(cfg, reader, gpu_opts)
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
        -- GPU 归属标注（纯 label）：给不带 gpu 的 proc 候选按 LISTEN inode 找属主
        -- 进程、从它的 cmdline 认卡号。认不出/扫不动一律保持 nil，发现逻辑本身不动。
        annotate_proc_gpu(cands, gpu_opts)
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
