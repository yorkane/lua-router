local cjson = require "cjson.safe"

local _M = require "resty.luarouter.watcher"
local M = {}   -- cross-module helper surface (not part of _M)
local json_encode = cjson.encode
local json_decode = cjson.decode

-- watcher/ledger.lua -- the lr_watch closure: protected / owned / pending
-- back-off / g| gpu hints / map.  Moved verbatim; the key-layout comment
-- and the one-pass-one-read discipline (gpu_hints takes get_keys once)
-- travel with it.  lr_watch stays the watcher s only shdict.

-- ------------------------------------------------------------------ ledger

local GPU_HINT_PREFIX = "g|"

---The ledger is the memory of what this watcher owns and what it must never
---touch. The daemon keeps it in a JSON file; here it lives in lr_watch so every
---nginx process (and a reload) sees one copy. A container restart clears it,
---which is coherent: lr_workers is a shared dict too, so a restart clears the
---pool as well and SMG_WORKER_URLS re-seeds it.
---
---Key layout (all in lr_watch):
---   p|<url>   protected marker
---   o|<url>   owned entry   {model_id, worker_id, engine, source, label, added_at,
---                            missing_since, probe_fails}
---   q|<url>   pending add   {queued_at, worker_id}
---   f|<url>   add back-off  {n, until}
---   map       the whole rename map as one JSON object
---   g|<url>   卡号提示：这个 url 背后的容器是哪张卡（gpu_load 的逐卡功率用它接地址）
---@param d table ngx.shared.Dict (or a test double with get/set/delete/get_keys)
local function new_ledger(d)
    local self = { dict = d }

    local function url_key(prefix, url)
        return prefix .. url
    end

    function self.protected_urls()
        local out = {}
        for _, key in ipairs(d:get_keys(0)) do
            if string.sub(key, 1, 2) == "p|" then
                out[string.sub(key, 3)] = true
            end
        end
        return out
    end

    function self.is_protected(url)
        return d:get(url_key("p|", url)) ~= nil
    end

    function self.protect(url)
        d:set(url_key("p|", url), 1)
    end

    function self.unprotect(url)
        d:delete(url_key("p|", url))
    end

    local function decode(raw)
        if type(raw) ~= "string" then
            return nil
        end
        local value = json_decode(raw)
        if type(value) ~= "table" then
            return nil
        end
        return value
    end

    function self.owned_urls()
        local out = {}
        for _, key in ipairs(d:get_keys(0)) do
            if string.sub(key, 1, 2) == "o|" then
                local entry = decode(d:get(key))
                if entry then
                    out[string.sub(key, 3)] = entry
                end
            end
        end
        return out
    end

    function self.get_owned(url)
        return decode(d:get(url_key("o|", url)))
    end

    ---`ttl` keeps a live entry alive across a reload; it is rewritten on every
    ---pass that still sees the worker, so it only matters as a leak guard.
    function self.set_owned(url, entry, ttl)
        local encoded = json_encode(entry)
        if not encoded then
            return false
        end
        return d:set(url_key("o|", url), encoded, ttl or 0) and true or false
    end

    function self.drop_owned(url)
        d:delete(url_key("o|", url))
    end

    function self.get_pending(url)
        return decode(d:get(url_key("q|", url)))
    end

    ---记下「这个 url 背后的容器是哪张卡」（g| 键）。
    ---
    ---为什么放在台账里而不是只靠 make_register 写 labels.gpu：registry.add 遇到已存在的
    ---url 走幂等分支（registry.lua:1476 起）——它回一条 failed job 然后直接 return，**不碰
    ---记录**，所以「让 watcher 再 add 一次把 labels 补上」这条链在盘上不成立。21.k 生产
    ---正是这种形状：八个 worker 由 SMG_WORKER_URLS 播种（bootstrap → registry.add({url=…})，
    ---不带 labels），watcher 首轮又把池里已有的行整排 protect 掉（guard 3），register 对
    ---它们永远不会被调用，于是 labels 恒为 null、逐卡功率永远接不上。
    ---卡号是 watcher 从容器名解析出来的知识，就存在 watcher 自己的 lr_watch 里；gpu_load
    ---在写某个 worker 的功率读数时读一次，接不上就回落整机 max。全程不需要 registry.lua 配合。
    ---@param url string
    ---@param gpu string|nil @ nil / "" = 这一轮不再认得它（容器改名），删键
    ---@return boolean stored
    function self.set_gpu_hint(url, gpu)
        local key = GPU_HINT_PREFIX .. tostring(url or "")
        if url == nil or url == "" then
            return false
        end
        local wanted = (type(gpu) == "string" and gpu ~= "") and gpu or nil
        if wanted == nil then
            if d:get(key) ~= nil then
                d:delete(key)
            end
            return false
        end
        if d:get(key) == wanted then
            return true
        end
        return d:set(key, wanted, 0) and true or false
    end

    ---台账里现存的卡号提示，一次读全（功率 pass 每 tick 读一次，不在 worker 循环里摸 shdict）。
    ---@return table @ url -> gpu id
    function self.gpu_hints()
        local out = {}
        for _, key in ipairs(d:get_keys(0)) do
            if string.sub(key, 1, 2) == GPU_HINT_PREFIX then
                local value = d:get(key)
                if type(value) == "string" and value ~= "" then
                    out[string.sub(key, 3)] = value
                end
            end
        end
        return out
    end

    function self.pending_urls()
        local out = {}
        for _, key in ipairs(d:get_keys(0)) do
            if string.sub(key, 1, 2) == "q|" then
                local value = decode(d:get(key))
                if value then
                    out[string.sub(key, 3)] = value
                end
            end
        end
        return out
    end

    function self.set_pending(url, value, ttl)
        local encoded = json_encode(value)
        if encoded then
            d:set(url_key("q|", url), encoded, ttl or 0)
        end
    end

    function self.drop_pending(url)
        d:delete(url_key("q|", url))
    end

    function self.get_backoff(url)
        return decode(d:get(url_key("f|", url)))
    end

    ---Exponential back-off after a rejected add, capped at 15 minutes like the
    ---daemon (30 s * 2^n, max 900 s).
    ---The field is named until_ts: `until` is a Lua keyword and cannot be a key.
    function self.set_backoff(url, n, now)
        local until_ts = now + math.min(900, 30 * (2 ^ n))
        d:set(url_key("f|", url), json_encode({ n = n, until_ts = until_ts }),
            until_ts - now + 60)
        return until_ts
    end

    function self.drop_backoff(url)
        d:delete(url_key("f|", url))
    end

    ---First-contact marker: the ledger has been seeded once. Separate from the
    ---protected set because an empty pool is a legitimate first contact too.
    function self.touched()
        return d:get("touched") ~= nil
    end

    function self.mark_touched()
        d:set("touched", 1)
    end

    function self.map()
        local value = decode(d:get("map"))
        if value then
            return value
        end
        return {}
    end

    function self.set_map(mapping)
        local encoded = json_encode(mapping or {})
        if encoded then
            d:set("map", encoded)
        end
    end

    return self
end

_M.new_ledger = new_ledger

-- live.lua gpu_hint_snapshot pcalls the factory directly; the monolith
-- read the same file-local, so this stays a direct call.
M.new_ledger = new_ledger

return M
