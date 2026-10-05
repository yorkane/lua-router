-- 纯字符串/表工具面（自 router.lua 逐字搬来，只调整了 require 接线）。
--
-- P1 DP rank 注入 + P6 路由文本抽取 + P9 raw JSON 顶层精确改写族 + P12 usage 族
-- + P13 SSE 工具 + P14 session 指纹 + P15 sse_usage。
-- 字节透传红线（AGENTS.md 硬规则 4）：只做顶层精确改写，绝不整表重编码。
-- test/unit 的多份单测按字符串锚点切本文件的源码配桩加载，锚点区间内的代码
-- 逐字不许动（改名、重排、顺手清理都会把切片切坏）。
local cjson = require "cjson.safe"

local _M = {}
package.loaded["resty.luarouter.router.jsonutil"] = _M

local json_encode = cjson.encode
local json_decode = cjson.decode
-- ---------------------------------------------------------------- DP rank

---Find the byte range of a top-level member in a JSON object.
---
---Depth-aware on purpose: a naive search for the key name also hits a *nested*
---member with the same name (a tool call's arguments blob can carry one), and
---rewriting that would corrupt the payload. Splices therefore have to know the
---brace depth, which costs one forward scan with an escape-aware string state
---machine - the same cost class as the router's "model" rewrite.
---
---(This pair of helpers lived in the Kubernetes poller module and moved here
---with the DP rank injection when it was removed, doc/scope-trim.md.)
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
---rewrite_model follows for "model".
---@param raw string @ request body
---@param record table @ selected worker record (rank read from dp_rank)
---@return string raw, boolean changed
local function inject_dp_rank(raw, record)
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
-- ------------------------------------------------------------------ text extract

---Flatten a content value: strings pass through, arrays keep {type:"text"} parts.
local function content_to_text(content)
    if type(content) == "string" then
        return content
    end
    if type(content) ~= "table" then
        return nil
    end
    if content.type == "text" and type(content.text) == "string" then
        return content.text
    end
    local parts = {}
    for i = 1, #content do
        local segment = content[i]
        if type(segment) == "table" and segment.type == "text"
            and type(segment.text) == "string" and segment.text ~= "" then
            parts[#parts + 1] = segment.text
        end
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, " ")
end

-- Mirrors extract_text_for_routing in openai-protocol/src/chat.rs: walk messages
-- in order, take content for system/user/tool/developer, content plus
-- reasoning_content for assistant, content for function, joined by single spaces.
local function chat_text(body)
    local messages = body.messages
    if type(messages) ~= "table" then
        return ""
    end
    local parts = {}
    for i = 1, #messages do
        local message = messages[i]
        if type(message) == "table" then
            local role = message.role
            local text = content_to_text(message.content)
            if text and text ~= "" and (role == "assistant" or role == "system"
                or role == "user" or role == "tool" or role == "developer"
                or role == "function") then
                parts[#parts + 1] = text
            end
            if role == "assistant" then
                local reasoning = message.reasoning_content
                if type(reasoning) == "string" and reasoning ~= "" then
                    parts[#parts + 1] = reasoning
                end
            end
        end
    end
    return table.concat(parts, " ")
end

local function array_text(value)
    if type(value) == "string" then
        return value
    end
    if type(value) ~= "table" then
        return ""
    end
    local parts = {}
    for i = 1, #value do
        if type(value[i]) == "string" and value[i] ~= "" then
            parts[#parts + 1] = value[i]
        end
    end
    return table.concat(parts, " ")
end

-- One extractor per endpoint, matching that protocol's extract_text_for_routing.
local text_extractors = {
    ["/v1/chat/completions"] = chat_text,
    ["/generate"] = function(body) return array_text(body.text) end,
    ["/v1/completions"] = function(body) return array_text(body.prompt) end,
    ["/v1/embeddings"] = function(body) return array_text(body.input) end,
    ["/v1/classify"] = function(body) return array_text(body.input) end,
    ["/v1/rerank"] = function(body)
        return type(body.query) == "string" and body.query or ""
    end,
    ["/v1/responses"] = function(body)
        local input = body.input
        if type(input) == "string" then
            return input
        end
        if type(input) == "table" then
            return chat_text({ messages = input })
        end
        return ""
    end,
}
_M.text_extractors = text_extractors
-- ------------------------------------------------------------------ raw JSON edits
--
-- The forwarded payload is edited in place rather than re-encoded from the
-- decoded table: cjson cannot tell an empty array from an empty object, so
-- re-encoding would turn "tools": [] into "tools": {}. Only the top-level
-- object is touched, and every edit is anchored on the key name so a nested
-- field with the same name stays alone.

---Presence pattern for one field name: the key followed by its colon. It says
---nothing about the value shape, which is deliberate -- the exact member is found
---by top_member_span below, and this pattern only decides whether that walk can
---possibly find anything. Anchoring on the key name (rather than a position) is
---what keeps a nested member that shares the name from being edited.
local function field_pattern(field)
    return '"' .. field .. '"\\s*:'
end

local QUOTE, BACKSLASH, COLON, COMMA = 34, 92, 58, 44
local OPEN_BRACE, CLOSE_BRACE = 123, 125
local OPEN_BRACKET, CLOSE_BRACKET = 91, 93

---Index just past the closing quote of the string that starts at `i`. Escapes are
---honoured, so `\"` never ends the string.
---@return number
local function skip_string(raw, i, n)
    local j = i + 1
    while j <= n do
        local b = raw:byte(j)
        if b == BACKSLASH then
            j = j + 2
        elseif b == QUOTE then
            return j + 1
        else
            j = j + 1
        end
    end
    return n + 1
end

---Last byte of the JSON value that starts at `v`, or nil when it never closes.
---Only the matching bracket type is counted: in valid JSON the other kind only
---ever appears inside a string, and strings are skipped whole.
---@return number|nil
local function value_end(raw, v, n)
    local b = raw:byte(v)
    if b == nil then
        return nil
    elseif b == QUOTE then
        return skip_string(raw, v, n) - 1
    elseif b == OPEN_BRACE or b == OPEN_BRACKET then
        local opener, closer = b, (b == OPEN_BRACE) and CLOSE_BRACE or CLOSE_BRACKET
        local depth = 0
        local j = v
        while j <= n do
            local d = raw:byte(j)
            if d == QUOTE then
                j = skip_string(raw, j, n) - 1
            elseif d == opener then
                depth = depth + 1
            elseif d == closer then
                depth = depth - 1
                if depth == 0 then
                    return j
                end
            end
            j = j + 1
        end
        return nil
    end
    -- number / true / false / null: the value runs to the next delimiter
    local j = v
    while j < n do
        local d = raw:byte(j + 1)
        if d == COMMA or d == CLOSE_BRACE or d == CLOSE_BRACKET
            or d == 32 or d == 9 or d == 10 or d == 13 then
            break
        end
        j = j + 1
    end
    return j
end

---Byte span of the first **top-level** member named `field`: value start, value
---end and the opening quote of the key, or nil when the document has no such
---member.
---
---A PCRE search returns the first match anywhere in the document, and an OpenAI
---response nests members that share names with the ones /v1/responses has to
---patch ("model" inside a usage or tool object, "instructions" inside an output
---item, "conversation" inside user metadata). Rust edits a decoded Map and so can
---only ever touch the top level; a pattern-based edit would corrupt the nested
---member instead. This walk counts depth, skips strings with their escapes, and
---only reads a key at depth 1 -- the scan stops at the first top-level hit, and a
---nested member with the same name never registers. A depth-1 value string can
---look like a key to the walk, but valid JSON never puts a colon after one, so it
---cannot be mistaken for a member name.
---
---The cheap PCRE presence gate in front keeps the common paths (key absent, so
---the caller appends) allocation-free and only pays for the walk when the name
---really appears in the document.
---@param raw string
---@param field string
---@return number|nil value_from, number|nil value_to, number|nil member_from
local function top_member_span(raw, field)
    if not ngx.re.find(raw, field_pattern(field), "jo") then
        return nil
    end
    local n = #raw
    local open = raw:find("{", 1, true)
    if not open then
        return nil
    end
    local depth = 0
    local i = open
    local key, key_from = nil, nil
    while i <= n do
        local b = raw:byte(i)
        if b == QUOTE then
            local after = skip_string(raw, i, n)
            if depth == 1 and key == nil then
                key = raw:sub(i + 1, after - 2)
                key_from = i
            end
            i = after
        elseif b == OPEN_BRACE or b == OPEN_BRACKET then
            depth = depth + 1
            i = i + 1
        elseif b == CLOSE_BRACE or b == CLOSE_BRACKET then
            depth = depth - 1
            if depth <= 0 then
                break
            end
            i = i + 1
        elseif b == COMMA and depth == 1 then
            key, key_from = nil, nil
            i = i + 1
        elseif b == COLON and depth == 1 and key ~= nil then
            if key == field then
                local v = i + 1
                while v <= n do
                    local w = raw:byte(v)
                    if w ~= 32 and w ~= 9 and w ~= 10 and w ~= 13 then
                        break
                    end
                    v = v + 1
                end
                local last = value_end(raw, v, n)
                if not last then
                    return nil
                end
                return v, last, key_from
            end
            key, key_from = nil, nil
            i = i + 1
        else
            i = i + 1
        end
    end
    return nil
end

---Set, add or remove the first top-level JSON member named `field`. Spliced by
---hand instead of through gsub: a replacement string would have to re-escape the
---JSON we just encoded, and gsub would also rewrite nested members that happen
---to share the name.
---@param raw string
---@param field string
---@param value string|number|nil @ nil removes the member
---@return string raw
local function set_top_field(raw, field, value)
    if type(raw) ~= "string" or raw == "" then
        return raw
    end
    local value_from, value_to, member_from = top_member_span(raw, field)

    if value == nil then
        if not value_from then
            return raw
        end
        -- Eat the comma on whichever side of the member exists, preferring the
        -- preceding one so a middle or last member never leaves a dangling comma.
        if raw:sub(member_from - 1, member_from - 1) == "," then
            return raw:sub(1, member_from - 2) .. raw:sub(value_to + 1)
        end
        local after = value_to + 1
        while after <= #raw and raw:sub(after, after):match("^%s$") do
            after = after + 1
        end
        if raw:sub(after, after) == "," then
            return raw:sub(1, member_from - 1) .. raw:sub(after + 1)
        end
        return raw:sub(1, member_from - 1) .. raw:sub(value_to + 1)
    end

    local encoded_value = json_encode(value)
    if not encoded_value then
        return raw
    end
    if value_from then
        -- The span covers the value only, so the key is already in place and a
        -- member that exists can never be left behind as a duplicate.
        return raw:sub(1, value_from - 1) .. encoded_value .. raw:sub(value_to + 1)
    end
    encoded_value = '"' .. field .. '":' .. encoded_value

    -- Absent: insert as the first member of the top-level object.
    local brace_from, brace_to = ngx.re.find(raw, [[^\s*\{]], "jo")
    if not brace_from then
        return raw
    end
    local tail = raw:sub(brace_to + 1)
    local rest = ngx.re.gsub(tail, [[^\s*\}\s*$]], "", "jo")
    if rest == "" then
        return raw:sub(1, brace_to) .. encoded_value .. "}"
    end
    return raw:sub(1, brace_to) .. encoded_value .. "," .. tail
end

_M.set_top_field = set_top_field

---Set `member` inside the top-level object member `field`, creating the object
---when the document has no such member. Byte-preserving like set_top_field: the
---rest of the document is never re-encoded.
---
---This is the edit the token-accounting injection needs and set_top_field alone
---cannot do: the OpenAI body carries a *nested* object whose inside has to change
---("stream_options": {"include_usage": true}), and a client that already sent a
---stream_options object must keep its other members. Handled shapes:
---  * `member` already truthy   -> no change (nothing to inject)
---  * `field` absent            -> insert "<field>":{"<member>":value} first member
---  * `field` is an object      -> splice the member into that object; the nested
---                                 edit reuses set_top_field on the object
---                                 substring, whose depth walk restarts at that
---                                 substring's own first brace
---  * `member` explicitly false or null -> rewritten to `value`
---  * `field` present but not an object -> no change: replacing a value the client
---                                 chose for that name is not ours to make
---@param raw string
---@param field string @ top-level member name
---@param member string @ member to set inside that object
---@param value any @ JSON scalar
---@return string raw, boolean changed
local function merge_top_object(raw, field, member, value)
    if type(raw) ~= "string" or raw == "" then
        return raw, false
    end
    local object_from, object_to = top_member_span(raw, field)
    if not object_from then
        local inserted = set_top_field(raw, field, { [member] = value })
        return inserted, inserted ~= raw
    end
    local object_text = raw:sub(object_from, object_to)
    if object_text == "null" then
        -- An explicit null says "no options" rather than "options I chose", so it
        -- is safe to fill in: the same replace-by-value path set_top_field uses
        -- for a member that exists.
        local filled = set_top_field(raw, field, { [member] = value })
        return filled, filled ~= raw
    end
    if object_text:sub(1, 1) ~= "{" then
        return raw, false
    end
    local member_from, member_to = top_member_span(object_text, member)
    if member_from then
        local current = json_decode(object_text:sub(member_from, member_to))
        if current ~= nil and current ~= cjson.null and current ~= false then
            return raw, false
        end
    end
    local merged_object = set_top_field(object_text, member, value)
    if merged_object == object_text then
        return raw, false
    end
    return raw:sub(1, object_from - 1) .. merged_object .. raw:sub(object_to + 1), true
end

_M.merge_top_object = merge_top_object

---Decode the first top-level member named `field` without re-encoding the
---surrounding document. Returns (value, present); a JSON null comes back as
---cjson.null rather than Lua nil so "absent" and "explicit null" stay distinct.
local function top_field_value(raw, field)
    local from, to = top_member_span(raw, field)
    if not from then
        return nil, false
    end
    local value = json_decode(raw:sub(from, to))
    if value == nil then
        return nil, false
    end
    return value, true
end

---Rust's is_missing_or_empty (responses/utils.rs:12-18): missing, JSON null or an
---empty string. An object or array -- including `{}` and `[]` -- is present.
---@param raw string
---@param field string
---@return boolean
local function missing_or_empty(raw, field)
    local value, present = top_field_value(raw, field)
    if not present then
        return true
    end
    if value == cjson.null then
        return true
    end
    return value == ""
end

---responses/utils.rs::patch_response_with_request_metadata, expressed as
---byte-preserving top-level edits. With the response store removed this is the
---client-facing half only: /v1/responses answers the upstream bytes with the
---request's own metadata echoed back, which is the Rust wire shape.
---@param raw string @ upstream response bytes
---@param body table @ decoded request
---@return string raw
local function patch_response_metadata(raw, body)
    if type(raw) ~= "string" or raw == "" or type(body) ~= "table" then
        return raw
    end

    if type(body.previous_response_id) == "string"
        and missing_or_empty(raw, "previous_response_id") then
        raw = set_top_field(raw, "previous_response_id", body.previous_response_id)
    end
    if type(body.instructions) == "string"
        and missing_or_empty(raw, "instructions") then
        raw = set_top_field(raw, "instructions", body.instructions)
    end
    if type(body.metadata) == "table"
        and missing_or_empty(raw, "metadata") then
        raw = set_top_field(raw, "metadata", body.metadata)
    end
    -- Unconditional, and a request without the field lands false: ResponsesRequest
    -- ::store is Option<bool> and Rust writes unwrap_or(false).
    raw = set_top_field(raw, "store", body.store == true)
    if missing_or_empty(raw, "model") then
        -- ResponsesRequest.model is a String whose serde default is "unknown"
        -- (openai-protocol common.rs::default_model), so a request that omitted
        -- it still lands a concrete model on the response. Rust reads the
        -- client's own field here, not the worker's resolved id.
        raw = set_top_field(raw, "model",
            type(body.model) == "string" and body.model or "unknown")
    end

    -- Rust inserts the user only when safety_identifier is present and null, and
    -- only for a user that deserialized into Some(String): a JSON null decodes to
    -- cjson.null here, which is not a string.
    local safety, safety_present = top_field_value(raw, "safety_identifier")
    if safety_present and safety == cjson.null and type(body.user) == "string" then
        raw = set_top_field(raw, "safety_identifier", body.user)
    end
    -- The conversation link is not echoed: it only ever meant "this stored
    -- response belongs to that conversation", and the store is gone.
    return raw
end

_M.patch_response_metadata = patch_response_metadata

-- Only the top-level "model" field is rewritten, which is the first occurrence
-- in any OpenAI-style payload. Anchoring on the key name (not a positional
-- regex) keeps a nested "model" further down the document untouched.
local MODEL_FIELD_RE = [==["model"\s*:\s*"(?:[^"\\]|\\.)*"]==]

---Point the payload at the selected worker's real model id, the way the Rust
---router overwrites payload["model"] before sending. The first occurrence only.
---@param raw string
---@param target string
---@return string
local function rewrite_model(raw, target)
    if type(target) ~= "string" or target == "" or target == "unknown" then
        return raw
    end
    local encoded_target = json_encode(target)
    if not encoded_target then
        return raw
    end
    local from, to = ngx.re.find(raw, MODEL_FIELD_RE, "jo")
    if not from then
        return raw
    end
    return raw:sub(1, from - 1) .. '"model":' .. encoded_target .. raw:sub(to + 1)
end

_M.rewrite_model = rewrite_model
-- ------------------------------------------------------------------ usage

local function usage_from_object(usage)
    if type(usage) ~= "table" then
        return nil
    end
    local prompt = tonumber(usage.prompt_tokens or usage.input_tokens)
    local completion = tonumber(usage.completion_tokens or usage.output_tokens)
    if not prompt and not completion then
        return nil
    end
    -- The two spellings of the details objects are the two wire families:
    -- chat/completions uses prompt_tokens_details/completion_tokens_details, and
    -- /v1/responses (usage nested under response) uses input_tokens_details/
    -- output_tokens_details. The counts inside keep the same names in both, and
    -- the pair mirrors the prompt_tokens/input_tokens alias above, so a reader
    -- that already understands why the totals have two spellings needs nothing
    -- new here.
    local details = (type(usage.prompt_tokens_details) == "table"
        and usage.prompt_tokens_details)
        or (type(usage.input_tokens_details) == "table"
            and usage.input_tokens_details) or nil
    local cached = tonumber(details and details.cached_tokens or usage.cached_tokens) or 0
    -- Reasoning tokens come from completion_tokens_details, with a bare
    -- usage.reasoning_tokens as the fallback: exactly the two shapes Rust reads
    -- (observability/request_log.rs:304-309 and :918-922). SGLang and the
    -- thinking-capable engines use either, and the UI shows the field either way.
    local out_details = (type(usage.completion_tokens_details) == "table"
        and usage.completion_tokens_details)
        or (type(usage.output_tokens_details) == "table"
            and usage.output_tokens_details) or nil
    local reasoning = tonumber(out_details and out_details.reasoning_tokens
        or usage.reasoning_tokens) or 0
    return prompt or 0, completion or 0, cached, reasoning
end

---Token counts from a buffered JSON body.
---
---Never write `return f() or g()` here: `or` truncates the multi-valued return
---to its first value, so completion_tokens and cached_tokens silently become
---nil and every buffered request logs 0 completion tokens.
local function usage_from_body(body)
    if type(body) ~= "string" or body == "" then
        return nil
    end
    local decoded = json_decode(body)
    if type(decoded) ~= "table" then
        return nil
    end
    local prompt, completion, cached, reasoning = usage_from_object(decoded.usage)
    if prompt or completion then
        return prompt, completion, cached, reasoning
    end
    return usage_from_object(decoded.usage_metadata)
end

---Read the usage of one decoded SSE data payload, covering the two shapes a
---backend puts on the wire:
---  * chat/completions and completions: `usage` is a top-level member of the chunk
---  * responses: the completed event carries it under `response`, and the chunk
---    itself has no usage member
---Returns nil when the payload carries neither, so callers can keep scanning.
---@param decoded table @ one decoded data: payload
---@return number|nil prompt, number|nil completion, number|nil cached, number|nil reasoning
local function usage_from_chunk(decoded)
    local prompt, completion, cached, reasoning = usage_from_object(decoded.usage)
    if prompt or completion then
        return prompt, completion, cached, reasoning
    end
    local response = decoded.response
    if type(response) == "table" then
        return usage_from_object(response.usage)
    end
    return nil
end

---Byte-based fallback, used only when the worker sent no usage object.
local function estimate_tokens(text)
    if not text or text == "" then
        return 0
    end
    return math.floor(#text / 4 + 0.5)
end

_M.usage_from_body = usage_from_body
_M.estimate_tokens = estimate_tokens

---Decide whether one complete SSE event is ours to remove from the client
---stream: a usage frame we asked the backend for on the client's behalf and that
---carries nothing the client would otherwise have seen.
---
---The rule is deliberately narrow; every visible byte of the event must be the
---accounting payload:
---  * exactly one `data:` line. A multi-line event can also carry the [DONE]
---    terminator, and dropping that would leave the client waiting for a stream
---    end that never arrives.
---  * no `event:` / `id:` / `retry:` fields. A /v1/responses frame is never just
---    usage (its completed event is protocol the client parses), and an
---    id-carrying frame would change the resumability the client observed.
---  * the payload decodes to an object whose usage (top-level `usage`, or the
---    `response.usage` of a responses-frame) is readable. Note that a
---    /v1/responses completed event also carries an `event:` line, which the
---    second rule already exempts from dropping.
---  * `choices` is absent or empty, and every element carries no content: an
---    empty or absent `delta`, no `text`, and a null or absent `finish_reason`.
---    The last condition protects a llama.cpp style backend, which puts usage on
---    the same chunk that closes the turn: dropping that would eat the
---    finish_reason the client needs to end the message, so the frame stays (the
---    client sees one usage object it did not ask for; the alternative, editing
---    the frame's bytes, is the payload-mutating behaviour this gateway avoids).
---Anything else -- heartbeats (": ping"), content deltas, the [DONE] sentinel --
---passes through untouched.
---@param text string @ one complete event, the separator line included
---@return boolean
local function sse_event_droppable(text)
    if type(text) ~= "string" or text == "" then
        return false
    end
    if string.find(text, "usage", 1, true) == nil then
        return false
    end
    local data_lines = 0
    local payload
    for line in string.gmatch(text, "[^\r\n]+") do
        if line:sub(1, 1) == ":" then
            -- comment / heartbeat line: carries no data, does not disqualify
        elseif line:sub(1, 5) == "data:" then
            data_lines = data_lines + 1
            local value = line:sub(6)
            if value:sub(1, 1) == " " then
                value = value:sub(2)
            end
            payload = value
        else
            -- event:, id:, retry: or any field we do not own: keep the event.
            return false
        end
    end
    if data_lines ~= 1 or payload == nil or payload == "" or payload == "[DONE]" then
        return false
    end
    local decoded = json_decode(payload)
    if type(decoded) ~= "table" then
        return false
    end
    local prompt, completion = usage_from_chunk(decoded)
    if not prompt and not completion then
        return false
    end
    local choices = decoded.choices
    if type(choices) == "table" then
        for i = 1, #choices do
            local choice = choices[i]
            if type(choice) ~= "table" then
                return false
            end
            if choice.finish_reason ~= nil and choice.finish_reason ~= cjson.null then
                return false
            end
            local delta = choice.delta
            if delta ~= nil and type(delta) ~= "table" then
                return false
            end
            if type(delta) == "table" and next(delta) ~= nil then
                return false
            end
            if choice.text ~= nil and choice.text ~= cjson.null and choice.text ~= "" then
                return false
            end
        end
    end
    return true
end

_M.sse_event_droppable = sse_event_droppable

---Split buffered SSE bytes into the complete events they carry plus the bytes
---still waiting for their terminating blank line.
---
---The boundary follows WHATWG eventsource: every line terminator (CR LF, LF, CR)
---closes a line and an empty line closes the event. Three literal searches cover
---the shapes a real backend produces -- "\n\n" (2), "\r\n\r\n" (4) and
---"\n\r\n" (3, the mixed spelling from a server that writes LF after its headers
---and CRLF inside the body). The earliest index wins; two candidates can never
---tie at one index because their second bytes differ, and "\r\n\r\n" always beats
---the "\n\r\n" that starts one byte later.
---
---Event text keeps its terminating separator: the pump forwards event.text
---verbatim, so the client reassembles the upstream's exact bytes, separator
---spelling included.
---
---Deliberately no ngx.re here: the unit-test sandbox drives this function
---directly with nothing but the Lua string library in scope.
---
---A stream the upstream stopped mid-frame never loses bytes: whatever lacks a
---terminating blank line comes back as `rest`, and the pump forwards that
---verbatim when the upstream ends. Swallowing a partial tail would truncate the
---client's body, a worse contract than leaking one un-dropped frame.
---@param buf string
---@return table events @ array of { text = string, droppable = boolean }
---@return string rest
local function sse_split(buf)
    local events = {}
    local pos = 1
    while true do
        local at, width
        local hit = string.find(buf, "\n\n", pos, true)
        if hit then
            at, width = hit, 2
        end
        hit = string.find(buf, "\r\n\r\n", pos, true)
        if hit and (not at or hit < at) then
            at, width = hit, 4
        end
        hit = string.find(buf, "\n\r\n", pos, true)
        if hit and (not at or hit < at) then
            at, width = hit, 3
        end
        if not at then
            break
        end
        local text = buf:sub(pos, at + width - 1)
        events[#events + 1] = {
            text = text,
            droppable = sse_event_droppable(text),
        }
        pos = at + width
    end
    return events, buf:sub(pos)
end

_M.sse_split = sse_split

-- ------------------------------------------------------------------ session

local session_digest

--- sha256 hex of a string, lowercase, one byte at a time.
---
---Same byte-wise hex loop the worker-id helper uses, and deliberately the same
---shape as Rust's hex_lower (request_log.rs:141-149): the fingerprint lands in the
---request log and in the UI's session filter, so it has to be comparable with what
---the Rust gateway wrote for the same conversation.
---@param text string
---@return string|nil hex
local function sha256_hex(text)
    if not session_digest then
        local ok, mod = pcall(require, "resty.openssl.digest")
        if not ok then
            return nil
        end
        session_digest = mod
    end
    local d, err = session_digest.new("sha256")
    if not d then
        return nil
    end
    local ok, uerr = d:update(text)
    if not ok then
        return nil
    end
    local raw, ferr = d:final()
    if not raw then
        return nil
    end
    local hex = {}
    for i = 1, #raw do
        hex[#hex + 1] = string.format("%02x", string.byte(raw, i))
    end
    return table.concat(hex)
end

--- Stable conversation key: an explicit OpenAI-ish conversation/user field when
--- present, otherwise a hash of the leading messages so a multi-turn chat
--- collapses onto one row group in the UI's session filter.
---
--- Byte-for-byte the Rust rule (observability/request_log.rs:151-200): the first
--- non-empty string among prompt_cache_key / user / conversation / session_id is
--- hashed on its own, and failing that a two-message-or-longer conversation is
--- hashed as role + NUL + first-message content, where a multimodal content array
--- contributes the concatenation of its text parts. nil means "no key", which is
--- what a single-turn request without an explicit id gets in either gateway.
---@param body table @ decoded request body
---@return string|nil hex
local function router_session_key(body)
    if type(body) ~= "table" then
        return nil
    end
    local keys = { "prompt_cache_key", "user", "conversation", "session_id" }
    for i = 1, #keys do
        local value = body[keys[i]]
        if type(value) == "string" and value ~= "" then
            return sha256_hex(value)
        end
    end

    local messages = body.messages
    if type(messages) ~= "table" or #messages < 2 then
        return nil
    end
    local first = messages[1]
    if type(first) ~= "table" then
        return nil
    end
    local content = first.content
    local text
    if type(content) == "string" then
        text = content
    elseif type(content) == "table" then
        -- Array of typed parts (the OpenAI multimodal shape): only text parts
        -- identify the conversation, and Rust joins them with no separator.
        local parts = {}
        for i = 1, #content do
            local part = content[i]
            if type(part) == "table" and type(part.text) == "string" then
                parts[#parts + 1] = part.text
            end
        end
        text = table.concat(parts)
    else
        return nil
    end
    if text == "" then
        return nil
    end
    local role = type(first.role) == "string" and first.role or ""
    return sha256_hex(role .. "\0" .. text)
end

_M.router_session_key = router_session_key
_M.sha256_hex = sha256_hex

---Usage carried by the final SSE data event; the payload may straddle reads, so
---the caller hands over a sliding tail window.
local function sse_usage(tail)
    local found
    for data in string.gmatch(tail, "data:%s*(.-)\r?\n") do
        if data ~= "" and data ~= "[DONE]" then
            local decoded = json_decode(data)
            if type(decoded) == "table" then
                local prompt, completion, cached, reasoning =
                    usage_from_object(decoded.usage)
                if prompt then
                    found = { prompt, completion, cached, reasoning }
                end
            end
        end
    end
    if found then
        return found[1], found[2], found[3], found[4]
    end
    return nil
end
-- 跨模块接线（拆分新增；文末，不进任何单测锚点区间）。本节原有的就近导出
-- （set_top_field / merge_top_object / patch_response_metadata / rewrite_model /
-- text_extractors / usage_from_body / estimate_tokens / sse_event_droppable /
-- sse_split / router_session_key / sha256_hex）留在各自原处，赋的是本模块 _M。
_M.inject_dp_rank = inject_dp_rank
_M.usage_from_object = usage_from_object
_M.usage_from_chunk = usage_from_chunk
_M.sse_usage = sse_usage
return _M
