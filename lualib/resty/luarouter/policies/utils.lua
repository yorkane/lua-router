-- 路由策略共享 helper：UTF-8 字符计数/切片、路由文本抽取、并列随机 tie-break、worker 视图访问器。
--
-- 设计约束：纯 Lua（LuaJIT 5.1），核心逻辑不依赖 ngx，可用 resty / luajit 直接跑单测。
-- 只有 now_ms() 会尝试惰性使用 ngx.now()，失败时退回 os.time()。
-- 对齐 gateway/src/policies/{tree,cache_aware,bucket}.rs 与 openai-protocol 的
-- ChatCompletionRequest::extract_text_for_routing / CompletionRequest::extract_text_for_routing。

local ok_cjson, cjson = pcall(require, "cjson")
local cjson_null = ok_cjson and cjson.null or nil

local INF_BOUND = 2 ^ 53 - 1          -- LuaJIT 没有 math.maxinteger，用可精确表示的最大整数代替 usize::MAX

local _M = {}

_M.INF_BOUND = INF_BOUND
_M.UNKNOWN_MODEL_ID = "unknown"

--------------------------------------------------------------------------
-- UTF-8：按码点（char）计数与切片
--------------------------------------------------------------------------
-- Lua 5.1 没有 utf8 库；#s 是字节数。Rust 侧全部按 char 计数，这里必须对齐，
-- 否则中文 prompt 的 match_rate 与分桶位置都会偏大。

--- 返回 s 的 UTF-8 字符数（非法字节按 1 字符前进，保证不死循环）
function _M.utf8_len(s)
    if s == nil or s == "" then
        return 0
    end
    local n = 0
    local i = 1
    local len = #s
    while i <= len do
        local b = string.byte(s, i)
        if b < 128 then
            i = i + 1
        elseif b < 194 then
            i = i + 1                        -- 落单的 continuation 字节，容错前进
        elseif b < 224 then
            i = i + 2
        elseif b < 240 then
            i = i + 3
        else
            i = i + 4
        end
        n = n + 1
    end
    return n
end

--- 返回第 n 个字符之后的字节位置（1-based）；n<=0 → 1，n>=字符数 → #s+1
local function byte_pos_after(s, n)
    if n <= 0 then
        return 1
    end
    local i = 1
    local len = #s
    local seen = 0
    while i <= len do
        local b = string.byte(s, i)
        local w
        if b < 128 then
            w = 1
        elseif b < 194 then
            w = 1
        elseif b < 224 then
            w = 2
        elseif b < 240 then
            w = 3
        else
            w = 4
        end
        seen = seen + 1
        i = i + w
        if seen == n then
            if i > len + 1 then
                return len + 1
            end
            return i
        end
    end
    return len + 1
end
_M.byte_pos_after = byte_pos_after

--- 前 n 个字符（字节前缀）
function _M.utf8_head(s, n)
    if s == nil or s == "" or n <= 0 then
        return ""
    end
    if n >= _M.utf8_len(s) then
        return s
    end
    return string.sub(s, 1, byte_pos_after(s, n) - 1)
end

--- 跳过 n 个字符后的剩余部分
function _M.utf8_tail(s, n)
    if s == nil or s == "" then
        return ""
    end
    if n <= 0 then
        return s
    end
    return string.sub(s, byte_pos_after(s, n))
end

--- 第一个字符（可能多字节）；空串返回 nil
function _M.utf8_first(s)
    if s == nil or s == "" then
        return nil
    end
    return string.sub(s, 1, byte_pos_after(s, 1) - 1)
end

--- 两个字符串从头开始的公共前缀字符数（对齐 Rust shared_prefix_count）
function _M.utf8_shared_prefix_count(a, b)
    if a == nil or b == nil or a == "" or b == "" then
        return 0
    end
    local la, lb = #a, #b
    local i, n = 1, 0
    while i <= la and i <= lb do
        local ba = string.byte(a, i)
        local bb = string.byte(b, i)
        if ba ~= bb then
            break
        end
        local w
        if ba < 128 then
            w = 1
        elseif ba < 194 then
            w = 1
        elseif ba < 224 then
            w = 2
        elseif ba < 240 then
            w = 3
        else
            w = 4
        end
        -- 首字节相同不代表整字符相同（多字节序列必须整段比较）
        if string.sub(a, i, i + w - 1) ~= string.sub(b, i, i + w - 1) then
            break
        end
        n = n + 1
        i = i + w
    end
    return n
end

--------------------------------------------------------------------------
-- 路由文本抽取
--------------------------------------------------------------------------

local function is_null(v)
    return v == nil or v == cjson_null
end

--- content 可能是字符串，也可能是 [{type="text", text=...}, ...]。
--- 把其中的非空 text 片段追加进 parts（保序），返回是否有追加。
local function append_content(content, parts)
    if is_null(content) then
        return false
    end
    local tv = type(content)
    if tv == "string" then
        if content ~= "" then
            parts[#parts + 1] = content
            return true
        end
        return false
    end
    if tv == "table" then
        if rawget(content, "text") ~= nil and (content.type == nil or content.type == "text") then
            -- 单个 text part 直接写成 {text = "..."}
            return append_content(content.text, parts)
        end
        local appended = false
        for i = 1, #content do
            local part = content[i]
            if type(part) == "table" and (part.type == nil or part.type == "text") and not is_null(part) then
                local text = part.text
                if is_null(text) and type(text) ~= "string" then
                    text = part.content               -- 容错：个别实现把正文放在 content 字段
                end
                if type(text) == "string" and text ~= "" then
                    parts[#parts + 1] = text
                    appended = true
                end
            end
        end
        return appended
    end
    return false
end

local function join_parts(parts)
    if #parts == 0 then
        return ""
    end
    return table.concat(parts, " ")
end

--- chat completions 请求体（cjson 解码后的 table）→ 路由文本。
--- 与 Rust 一致：所有消息的非空文本片段按顺序用单个空格连接；
--- assistant 额外拼上 reasoning_content，function 角色只取 content。
--- 没有任何文本时返回 nil（对齐 build_chat_request_text 的 None 语义）。
function _M.extract_chat_text(body)
    if type(body) ~= "table" then
        return nil
    end
    local messages = body.messages
    if type(messages) ~= "table" then
        return nil
    end

    local parts = {}
    for i = 1, #messages do
        local msg = messages[i]
        if type(msg) == "table" then
            local role = msg.role
            if role == "system" or role == "user" or role == "tool" or role == "developer" then
                append_content(msg.content, parts)
            elseif role == "assistant" then
                append_content(msg.content, parts)
                local reasoning = msg.reasoning_content
                if type(reasoning) == "string" and reasoning ~= "" then
                    parts[#parts + 1] = reasoning
                end
            elseif role == "function" then
                if type(msg.content) == "string" and msg.content ~= "" then
                    parts[#parts + 1] = msg.content
                else
                    append_content(msg.content, parts)
                end
            end
        end
    end

    local text = join_parts(parts)
    if text == "" then
        return nil
    end
    return text
end

--- completions 请求体：prompt 为字符串直接用，数组按单空格 join。
function _M.extract_completion_text(body)
    if type(body) ~= "table" then
        return nil
    end
    local prompt = body.prompt
    if is_null(prompt) then
        return nil
    end
    local text
    if type(prompt) == "string" then
        text = prompt
    elseif type(prompt) == "table" then
        local out = {}
        for i = 1, #prompt do
            local item = prompt[i]
            if type(item) == "string" then
                out[i] = item
            elseif type(item) == "number" then
                out[i] = tostring(item)
            elseif type(item) == "table" then
                local buf = {}
                append_content(item, buf)
                out[i] = buf[1] or ""
            else
                out[i] = ""
            end
        end
        text = table.concat(out, " ")
    elseif type(prompt) == "number" then
        text = tostring(prompt)
    else
        return nil
    end

    if text == "" then
        return nil
    end
    return text
end

--- 统一入口：chat（有 messages）走消息拼接，completions（有 prompt）走数组 join，
--- 其它形态退化为 /generate 的纯文本 input / prompt 字段。空 → nil。
function _M.extract_text_for_routing(body)
    if type(body) ~= "table" then
        if type(body) == "string" and body ~= "" then
            return body
        end
        return nil
    end
    if type(body.messages) == "table" then
        local text = _M.extract_chat_text(body)
        if text then
            return text
        end
    end
    if body.prompt ~= nil and not is_null(body.prompt) then
        local text = _M.extract_completion_text(body)
        if text then
            return text
        end
    end
    if type(body.input) == "string" and body.input ~= "" then
        return body.input
    end
    if type(body.text) == "string" and body.text ~= "" then
        return body.text
    end
    return nil
end

--------------------------------------------------------------------------
-- worker 视图访问器（兼容 framework 传对象表或方法对象两种形态）
--------------------------------------------------------------------------

local function call_or_field(w, method_name, field_name, default)
    local f = w[method_name]
    if type(f) == "function" then
        return f(w)
    end
    local v = w[field_name]
    if v == nil or v == cjson_null then
        return default
    end
    return v
end

function _M.worker_url(w)
    return call_or_field(w, "url", "url", "")
end

--- 数值负载；缺失按 0（对齐 Rust worker.load() 的原子计数默认 0）
function _M.worker_load(w)
    local v = call_or_field(w, "load", "load", 0)
    if type(v) ~= "number" then
        return 0
    end
    return v
end

function _M.worker_healthy(w)
    local v = call_or_field(w, "is_healthy", "healthy", true)
    if type(v) == "number" then
        return v ~= 0
    end
    return v and true or false
end

--- 熔断器是否放行（framework 没有该字段时视为放行）
function _M.worker_can_execute(w)
    local cb = w.circuit_breaker
    if type(cb) == "table" then
        local f = cb.can_execute
        if type(f) == "function" then
            return f(cb) and true or false
        end
        if cb.can_execute ~= nil then
            return cb.can_execute and true or false
        end
    end
    return true
end

function _M.worker_model_id(w)
    local v = call_or_field(w, "model_id", "model_id", nil)
    if type(v) == "string" and v ~= "" then
        return v
    end
    -- 框架的 worker 形状是 {url, api_key, models = {ids}}（见 luarouter/props.lua）
    local models = w.models
    if type(models) == "table" then
        local first = models[1]
        if type(first) == "string" and first ~= "" then
            return first
        end
        if type(first) == "table" and type(first.id) == "string" and first.id ~= "" then
            return first.id
        end
    end
    return _M.UNKNOWN_MODEL_ID
end

--- 连接池标签：regular / prefill / decode（对齐 Rust pool_tag）
function _M.worker_pool(w)
    local v = call_or_field(w, "pool", "pool", nil)
    if type(v) ~= "string" or v == "" then
        v = call_or_field(w, "worker_type", "worker_type", "regular")
        if type(v) ~= "string" or v == "" then
            v = "regular"
        end
    end
    if v ~= "regular" and v ~= "prefill" and v ~= "decode" then
        v = "regular"
    end
    return v
end

--- 健康过滤后的原始下标列表（1-based），对齐 get_healthy_worker_indices
function _M.healthy_indices(workers)
    local out = {}
    for i = 1, #workers do
        local w = workers[i]
        if _M.worker_healthy(w) and _M.worker_can_execute(w) then
            out[#out + 1] = i
        end
    end
    return out
end

--------------------------------------------------------------------------
-- 随机与并列 tie-break
--------------------------------------------------------------------------

--- rng(n) → 1..n；便于单测注入确定性随机源
function _M.default_rng(n)
    if n <= 1 then
        return 1
    end
    return math.random(n)
end

--- 从 1-based 候选表里等概率取一个元素（并列随机）
function _M.choose(list, rng)
    if type(list) ~= "table" or #list == 0 then
        return nil
    end
    if #list == 1 then
        return list[1]
    end
    local pick = (rng or _M.default_rng)(#list)
    if type(pick) ~= "number" or pick < 1 or pick > #list then
        pick = 1
    end
    return list[math.floor(pick)]
end

--- 在 indices 里挑 load 最小的下标，并列随机（对齐 Rust 的 filter(==min).choose(rng)）
function _M.min_load_index(indices, load_of, rng)
    local min_load
    local ties = {}
    for i = 1, #indices do
        local idx = indices[i]
        local load = load_of(idx)
        if min_load == nil or load < min_load then
            min_load = load
            ties = { idx }
        elseif load == min_load then
            ties[#ties + 1] = idx
        end
    end
    if #ties == 0 then
        return nil
    end
    return _M.choose(ties, rng)
end

--- min / max（单次遍历，对齐 Rust fold 写法）
function _M.min_max(values)
    local min, max
    for i = 1, #values do
        local v = values[i]
        if min == nil or v < min then
            min = v
        end
        if max == nil or v > max then
            max = v
        end
    end
    return min, max
end

function _M.normalize_model_key(model_id)
    if type(model_id) ~= "string" or model_id == "" then
        return _M.UNKNOWN_MODEL_ID
    end
    return model_id
end

--- 毫秒时间戳（单调性要求不高，滑动窗口只用相对差值）。
--- 优先 ngx.now()（0.001s 精度）；纯 luajit 下退回 os.time()。
--- 注意：resty / ngx.timer 里 ngx 是全局变量而不是可 require 的模块，所以两处都查。
local ngx_now
local G_ngx = (type(ngx) == "table") and ngx or nil   -- luacheck: ignore
if G_ngx == nil then
    local ok_ngx, ngx_mod = pcall(require, "ngx")
    if ok_ngx and type(ngx_mod) == "table" then
        G_ngx = ngx_mod
    end
end
if G_ngx and type(G_ngx.now) == "function" then
    ngx_now = G_ngx.now
end

function _M.now_ms()
    if ngx_now then
        return ngx_now() * 1000
    end
    return os.time() * 1000
end

_M.cjson = ok_cjson and cjson or nil

return _M
