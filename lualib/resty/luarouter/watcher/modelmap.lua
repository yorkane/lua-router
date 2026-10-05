local cjson = require "cjson.safe"

local _M = require "resty.luarouter.watcher"
local env_mod = require "resty.luarouter.watcher.env"
local live_mod = require "resty.luarouter.watcher.live"
local json_encode = cjson.encode
local json_decode = cjson.decode
local trim = env_mod.trim
local is_blank = env_mod.is_blank
local lower = env_mod.lower
local has_ngx = env_mod.has_ngx

-- watcher/modelmap.lua -- the rename map: model_name resolution, the four
-- accepted POST /model-map bodies (including the cjson empty-table trap
-- and the literal "map" key escape hatch), merge semantics
-- and the request-phase effective_map / apply_model_map API.  Moved
-- verbatim.

-- ------------------------------------------------------------------ model map

---Public model id for one advertised id (llm_watcher.py _model_name): the
---optional short-name transform, then the map (keyed on either spelling).
---@param raw string
---@param map table|nil @ original -> public
---@param short boolean|nil @ basename without the weights suffix
---@return string
function _M.model_name(raw, map, short)
    local name = tostring(raw or "")
    if short then
        name = trim((name:gsub("/+$", "")))
        name = (name:gsub("^.*[/\\]", ""))
        local low = lower(name)
        for _, suffix in ipairs({ ".gguf", ".safetensors", ".bin", ".pt", ".ckpt" }) do
            if string.sub(low, -#suffix) == suffix then
                name = string.sub(name, 1, #name - #suffix)
                break
            end
        end
        if trim(name) == "" then
            name = tostring(raw)
        end
    end
    if type(map) == "table" then
        local by_raw = map[raw]
        if type(by_raw) == "string" and by_raw ~= "" then
            return by_raw
        end
        local by_short = map[name]
        if type(by_short) == "string" and by_short ~= "" then
            return by_short
        end
    end
    return name
end

---`orig1:new1,orig2:new2` -> {orig = new} (llm_watcher.py parse_model_map).
---A blank value drops nothing here; deletion is a POST /model-map concern.
---@param spec string|nil
---@return table map, string[] ignored
function _M.parse_model_map(spec)
    local out, ignored = {}, {}
    if type(spec) ~= "string" then
        return out, ignored
    end
    for part in string.gmatch(spec, "[^,;\n]+") do
        part = trim(part)
        if part ~= "" then
            local orig, sep, new = string.match(part, "^([^:]*)(:)(.*)$")
            if not sep or trim(orig or "") == "" or trim(new or "") == "" then
                ignored[#ignored + 1] = part
            else
                out[trim(orig)] = trim(new)
            end
        end
    end
    return out, ignored
end

---Merge renames (llm_watcher.py set_model_map): an empty new id deletes.
---@param current table
---@param incoming table
---@return table merged, number deleted
function _M.merge_map(current, incoming)
    local merged = {}
    for key, value in pairs(current or {}) do
        merged[key] = value
    end
    local deleted = 0
    for key, value in pairs(incoming or {}) do
        local orig = trim(key)
        if orig ~= "" then
            local new = trim(value)
            if new == nil or new == cjson.null or new == "" then
                if merged[orig] ~= nil then
                    deleted = deleted + 1
                end
                merged[orig] = nil
            else
                merged[orig] = new
            end
        end
    end
    return merged, deleted
end

---Value coercion for a decoded JSON rename object: null is the empty string
---(that is how `{"a.gguf":""}` deletes), everything else is its text.
local function map_value(value)
    if is_blank(value) then
        return ""
    end
    return tostring(value)
end

---Decode a pairs text ("a:b,c:d", any of comma / ";" / newline).
---@return table|nil mapping, string[]|nil bad
local function pairs_to_map(text)
    local mapping, bad = {}, {}
    for chunk in string.gmatch(text, "[^,;\n]+") do
        local part = trim(chunk)
        if part ~= "" then
            local orig, sep, new = string.match(part, "^([^:]*)(:)(.*)$")
            if not sep or trim(orig or "") == "" then
                bad[#bad + 1] = part
            else
                mapping[trim(orig)] = trim(new)
            end
        end
    end
    if #bad > 0 then
        return nil, bad
    end
    return mapping
end

---Turn a POST /model-map body into ({original = new}, error).
---
---Port of parse_model_map_body, four accepted shapes and all: the plain object
---{"orig":"new"}, the same wrapped as {"map":{...}}, a bare pairs string
---"a:b,c:d", and the pairs string wrapped as {"map":"a:b,c:d"}. That last form
---used to fall into the object branch, which made the literal key "map" the
---original id so the rename silently never happened (hit on 217.t). An empty
---wrapper is deliberately NOT unwrapped, so {"map":""} stays a plain-object
---delete: that is the documented way to clear a poisoned entry whose key reads
---"map" (the cjson trap here is that `{}` decodes to an empty table with no
---object/array marker, so an empty table is taken for the object form exactly
---like Python takes an empty dict).
---@param raw string|nil
---@return table|nil mapping, table|nil err
function _M.parse_model_map_body(raw)
    local text = trim(raw or "")
    if text == "" then
        return nil, { error = 'empty body; send {"original":"new"} or '
            .. "original:new (an empty new id deletes the entry)" }
    end
    if string.sub(text, 1, 1) == "{" then
        local obj = json_decode(text)
        if type(obj) ~= "table" then
            return nil, { error = "invalid JSON" }
        end
        if rawget(obj, "map") ~= nil or next(obj) == nil then
            -- `{"map": ...}`: unwrap the two wrapped spellings.
            local wrapped = rawget(obj, "map")
            if type(wrapped) == "table" then
                local out = {}
                for key, value in pairs(wrapped) do
                    if type(key) == "string" then
                        out[key] = map_value(value)
                    end
                end
                return out
            elseif type(wrapped) == "string" and trim(wrapped) ~= "" then
                text = wrapped
            else
                -- {"map":null}, {"map":""} and {"map":{}} stay in the object
                -- branch: the literal "map" key is then deleted (or untouched).
                local out = {}
                for key, value in pairs(obj) do
                    if type(key) == "string" then
                        out[key] = map_value(value)
                    end
                end
                return out
            end
        else
            local out = {}
            for key, value in pairs(obj) do
                if type(key) == "string" then
                    out[key] = map_value(value)
                end
            end
            return out
        end
    end
    local mapping, bad = pairs_to_map(text)
    if not mapping then
        return nil, { error = "want original:new per entry", ignored = bad }
    end
    return mapping
end

-- ------------------------------------------------------------- model-map API

---Effective rename map: the env/flag map with the ledger map on top (the daemon
---merges the same way at start, so an API edit wins over a stale compose value).
---@param cfg table|nil
---@return table
function _M.effective_map(cfg)
    cfg = cfg or live_mod.captured()
    local merged = {}
    local env_map = (cfg and cfg.model_map)
        or _M.parse_model_map(
            os.getenv("SMG_WATCHER_MODEL_MAP") or os.getenv("LMR_MODEL_MAP") or "")
    for key, value in pairs(env_map) do
        merged[key] = value
    end
    local d = live_mod.dict()
    if d then
        for key, value in pairs(_M.new_ledger(d).map()) do
            merged[key] = value
        end
    end
    return merged
end

---Merge a POST /model-map body into the ledger map.
---@param raw string|nil @ raw request body (all four shapes accepted)
---@return table|nil merged @ effective map after the merge
---@return table|nil err @ {error=, ignored=} for a bad body, or
---        {error=, kind="config"} when the ledger dict is missing (a 5xx condition)
function _M.apply_model_map(raw)
    local mapping, err = _M.parse_model_map_body(raw)
    if err then
        return nil, err
    end
    local d = live_mod.dict()
    if not d then
        return nil, { error = "lua_shared_dict " .. DICT_NAME .. " is not declared",
                      kind = "config" }
    end
    local ledger = _M.new_ledger(d)
    local merged, _ = _M.merge_map(_M.effective_map(), mapping)
    ledger.set_map(merged)
    if has_ngx then
        ngx.log(ngx.NOTICE, "luarouter: watcher model map updated -> ",
            json_encode(merged) or "{}")
    end
    return merged
end

return _M
