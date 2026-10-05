-- registry.caps - upstream capability capture (block J of the original registry.lua).
--
-- Cut verbatim out of registry.lua (refactor 2026-10-05,
-- doc/refactor-arch-2026-10-05.md section 1). This is a self-contained pure domain:
-- zero shdict, zero ngx, zero cosocket, so it is unit-testable by feeding it decoded
-- JSON, and it cannot touch the forwarding plane.
--
-- The three rules the original block header pinned travel with the code, because they
-- are the concrete shape of the never-fake-a-reading discipline:
--   1. Never guess, never fill a default. A field the upstream did not answer stays
--      absent from the table (not null, not an empty array), and the output surface
--      decides between reporting what is known and reporting nothing. An invented
--      context_length gets used by clients as a budget, which is worse than silence.
--   2. A failed capture never touches the forwarding plane. Nothing here touches the
--      health bit or the breaker, and every parse error is swallowed (AGENTS.md hard
--      rule 4: a probe failure on the forwarding path costs accuracy only).
--   3. Provenance stays traceable. Where several places carry the same field the
--      order is capabilities.* then the entry top-level field then max_model_len -
--      how explicitly the engine said it, not which one we prefer.

local M = {}

local cjson = require "cjson.safe"

local json_encode = cjson.encode
local json_decode = cjson.decode

-- The self-calls that read _M.x() in the original file resolve against the
-- registry facade, late-bound below so this module loads before the facade does.
local R

---Non-empty string or nil, so an optional WorkerSpec field is absent rather than
---cjson.null on the record (the capability readers test type() == "string").
local function string_field(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

---Non-negative integer out of a JSON value, tolerating the numeric-string spelling
---some engines use (context_length: "524288"). Anything else -- a table, a bool, a
---negative, a fraction, a word -- is "no reading", i.e. nil.
---@param value any
---@param max_value number|nil @ upper bound; a nonsense magnitude counts as no reading
---@return number|nil
local function caps_int(value, max_value)
    local number = type(value) == "number" and value
        or (type(value) == "string" and tonumber(value))
    if type(number) ~= "number" or number ~= number or number < 0 then
        -- number ~= number is the NaN test: NaN compares >= 0 against every bound and
        -- would land in the record as an un-encodable value.
        return nil
    end
    local integral = math.floor(number + 0.5)
    if integral < 0 then
        return nil
    end
    if max_value and integral > max_value then
        return nil
    end
    return integral
end

---Boolean out of a JSON value, tolerating the "true"/"false" string spelling.
---Anything else (1, "yes", a table) is "no reading" -> nil, never false: false is a
---statement that the capability is absent, and only the engine may make it.
---@param value any
---@return boolean|nil
local function caps_bool(value)
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "string" then
        local lowered = value:lower()
        if lowered == "true" then
            return true
        elseif lowered == "false" then
            return false
        end
    end
    return nil
end

---Array of non-empty strings out of a JSON value: dedup, order preserved, junk items
---dropped. nil when nothing usable came through (a field the engine did not answer).
---@param value any
---@return table|nil
local function caps_str_list(value)
    if type(value) ~= "table" then
        return nil
    end
    local out, seen = {}, {}
    for i = 1, #value do
        local item = value[i]
        if type(item) == "string" then
            local trimmed = item:match("^%s*(.-)%s*$"):lower()
            if trimmed ~= "" and not seen[trimmed] then
                seen[trimmed] = true
                out[#out + 1] = trimmed
            end
        end
    end
    if #out == 0 then
        return nil
    end
    return out
end

---Sequence table? Used to tell an array (reasoning_efforts) from a map (supports),
---because the two merge differently: an array is replaced wholesale, a map is merged
---sub-key by sub-key.
---@param value any
---@return boolean
local function caps_is_seq(value)
    if type(value) ~= "table" then
        return false
    end
    local n = 0
    for k in pairs(value) do
        if type(k) ~= "number" then
            return false
        end
        n = n + 1
    end
    return n == #value
end

-- 来源优先级的取值器：候选按"上游说得有多明确"排序（capabilities.* > 条目顶层 >
-- max_model_len），逐个试，返回**第一个能读成目标类型**的值。
-- 为什么不是"第一个非 nil 就停"：一个类型不对的 readings（context_length 写成数组、
-- 写成 "abc"）在语义上是"这台引擎没说清"，此时继续往下看下一个来源才是对的；当场停住
-- 会让一个坏字段把后面本来可用的读数一起挡掉，等于让上游的笔误变成我们的信息缺失。

---@param max_value number|nil
---@param ... any
---@return number|nil
local function caps_pick_int(max_value, ...)
    for i = 1, select("#", ...) do
        local parsed = caps_int(select(i, ...), max_value)
        if parsed ~= nil then
            return parsed
        end
    end
    return nil
end

---@param ... any
---@return boolean|nil
local function caps_pick_bool(...)
    for i = 1, select("#", ...) do
        local parsed = caps_bool(select(i, ...))
        if parsed ~= nil then
            return parsed
        end
    end
    return nil
end

---@param ... any
---@return table|nil
local function caps_pick_str_list(...)
    for i = 1, select("#", ...) do
        local parsed = caps_str_list(select(i, ...))
        if parsed ~= nil then
            return parsed
        end
    end
    return nil
end

---Reasoning-effort ladder out of whatever spelling the engine used.
---
--- Three shapes seen in the wild, all normalized to {value,label,default}:
---   * opencodex 顶层 reasoning_efforts[] = {value,label,default}  (the rich one)
---   * capabilities.reasoning_effort[] = {["low","high","max"]}    (values only)
---   * nothing at all                                              -> nil
--- An effort entry whose only usable member is its value still counts: the ladder is
--- the client's picker content, and "these are the names" is information the engine
--- really did give. default is false unless the engine said otherwise -- the *string*
--- default (top-level reasoning_effort) is folded in separately, not here.
---@param value any
---@return table|nil
local function caps_efforts(value)
    if type(value) ~= "table" then
        return nil
    end
    local out, seen = {}, {}
    for i = 1, #value do
        local raw = value[i]
        local entry_value, label, default
        -- 档位名只接受字符串：数字 5 转写成 "5"、布尔转写成 "true" 都是替上游编话，
        -- 下游要拿这个名字去比对请求里的 reasoning_effort，编出来的名字谁也匹配不上。
        if type(raw) == "string" then
            entry_value = raw
        elseif type(raw) == "table" then
            entry_value = string_field(raw.value or raw.name or raw.effort)
            label = string_field(raw.label or raw.name_label or raw.title)
            default = caps_bool(raw["default"] or raw.is_default) or false
        end
        if entry_value then
            local key = entry_value:lower()
            if not seen[key] then
                seen[key] = true
                out[#out + 1] = {
                    value = entry_value,
                    label = label,
                    ["default"] = default and true or false,
                }
            end
        end
    end
    if #out == 0 then
        return nil
    end
    return out
end

---@param ... any
---@return table|nil
local function caps_pick_efforts(...)
    for i = 1, select("#", ...) do
        local parsed = caps_efforts(select(i, ...))
        if parsed ~= nil then
            return parsed
        end
    end
    return nil
end

---Normalize one decoded /v1/models entry into the registry's capability shape.
---
---形状（所有字段都可能缺，缺=没这个 key）：
---  context_length            number  上下文总窗口（输入+输出），引擎报的那个数
---  max_output_tokens         number  单次输出预算上限
---  modalities                { input = {..}, output = {..} }  小写字符串数组
---  supports                  { tool_use, streaming, reasoning, vision } 布尔
---  reasoning_efforts         { {value,label,default}, ... } 档位阶梯（客户端 picker）
---  reasoning_effort          string  引擎自己声明的缺省档
---  created                   number  上游答里的 unix 时间（OpenAI Model.created）
---  owned_by                  string  上游答里的 owned_by
---来源优先级（同一字段多处在）：capabilities.* > 条目顶层同名字段 > max_model_len。
---SGLang 只报 max_model_len，它映射成 context_length；opencodex 报整套 capabilities。
---
---刻意**不**从别处推：
---  * 不读条目顶层的 context_window：那是**本网关配置层**的字段名（对外声明的窗口，见
---    AGENTS.md 2026-10-04 裁定块）。把它和引擎读数混成一个字段，就等于重犯"把三个不同
---    的量当成同一个数"的那次事故。
---  * 不从 input_modalities 里有 image 反推 supports.vision=true：那是同一件事的两种说法
---    时才对，而"报了 modalities 没报 supports"也可能只是引擎少写一列。宁可少一个字段。
---@param entry any @ one decoded element of the upstream data[] array
---@return table|nil @ normalized caps, or nil when the entry carried nothing usable
function M.model_caps_from_entry(entry)
    if type(entry) ~= "table" then
        return nil
    end
    local caps = type(entry.capabilities) == "table" and entry.capabilities or nil
    local out = {}

    -- 上限 1e8：真实引擎不会超过这个量级，而"一个明显是别的含义的数被放错了字段"
    -- （比如把字节数、把 token id 写成 context_length）应该读作没有读数。
    out.context_length = caps_pick_int(100000000,
        caps and caps.context_length,
        entry.context_length,
        caps and caps.max_position_embeddings,
        entry.max_model_len,
        entry.max_context_length)
    out.max_output_tokens = caps_pick_int(100000000,
        caps and caps.max_output_tokens,
        entry.max_output_tokens,
        caps and caps.max_tokens,
        entry.max_tokens)

    local input_modalities = caps_pick_str_list(
        caps and caps.input_modalities, entry.input_modalities)
    local output_modalities = caps_pick_str_list(
        caps and caps.output_modalities, entry.output_modalities)
    if input_modalities or output_modalities then
        out.modalities = { input = input_modalities, output = output_modalities }
    end

    local supports
    local function support(target, ...)
        local flag = caps_pick_bool(...)
        if flag ~= nil then
            supports = supports or {}
            supports[target] = flag
        end
    end
    -- entry 在上面已经判过是 table，这里只剩 caps 是否存在。
    support("tool_use", caps and caps.supports_tool_use, entry.supports_tool_use)
    support("streaming", caps and caps.supports_streaming, entry.supports_streaming)
    support("reasoning", caps and caps.supports_reasoning, entry.supports_reasoning)
    support("vision", caps and caps.supports_vision, entry.supports_vision)
    if supports then
        out.supports = supports
    end

    -- 档位信息在上游有两种拼写，含义不同，所以**各留各的**、不互相覆盖：
    --   * out.reasoning_efforts       客户端 picker 的可选项（含 label / default）
    --   * out.reasoning_effort_values 下游**接受**的档位判定面（capabilities.reasoning_effort）
    -- 为什么不做交集：实测用户给的样例里两份就不一致（顶层阶梯 low/medium/high/max，
    -- capabilities 只 low/high/max），取交集会丢掉 medium 连同它身上的 default=true，客户端
    -- 反而没有缺省档可用；取并集又会报出下游可能不接受的名字。分成两个字段就都不用猜——
    -- 两份都是引擎原话，由输出面决定各自画在哪个位置。
    -- 为什么不做"整条取一份"：取带标签的那份会少两档，取值数组那份会丢全部 label 与 default。
    -- 阶梯与缺省档必须自洽：out.reasoning_effort 永远等于阶梯里 default 为真的那一档，
    -- 绝不写阶梯里没有的名字——那等于让 picker 选出一个自己列表里没有的档位。
    local efforts = caps_pick_efforts(entry.reasoning_efforts,
        caps and caps.reasoning_efforts, caps and caps.reasoning_effort)
    local accepted = caps_pick_str_list(caps and caps.reasoning_effort)
    local declared = string_field(entry.reasoning_effort)
    if efforts then
        local chosen
        for i = 1, #efforts do
            if efforts[i]["default"] then
                chosen = efforts[i].value
                break
            end
        end
        if not chosen and declared then
            local lowered = declared:lower()
            for i = 1, #efforts do
                local name = efforts[i].value
                if name:lower() == lowered then
                    efforts[i]["default"] = true
                    chosen = name
                end
            end
        end
        out.reasoning_efforts = efforts
        out.reasoning_effort = chosen
    elseif declared then
        -- 只有缺省档、没有阶梯：仍然报出来（引擎确实说了默认用哪个），但客户端无从枚举。
        out.reasoning_effort = declared
    end
    -- 只有 capabilities 那份判定面、且它与阶梯不完全同形时才单列；两者一致时单列一次就够，
    -- 免得输出面拿到两份语义相同、拼写不同的数据去纠结该信谁。
    if accepted and #accepted > 0 then
        local same_as_ladder = false
        if efforts and #efforts == #accepted then
            same_as_ladder = true
            for i = 1, #accepted do
                if not efforts[i] or efforts[i].value:lower() ~= accepted[i]:lower() then
                    same_as_ladder = false
                    break
                end
            end
        end
        if not same_as_ladder then
            out.reasoning_effort_values = accepted
        end
    end

    out.created = caps_pick_int(4294967295, entry.created)
    out.owned_by = string_field(entry.owned_by)

    if next(out) == nil then
        return nil
    end
    return out
end

---Normalize a whole decoded /v1/models body into { [model_id] = caps }.
---
---接受三种输入：完整的响应体（{data=...}）、裸的 data 数组、以及老引擎的字符串数组。
---没有一条能提取出能力时返回 nil（调用方据此保持"从没采到"，而不是存一张空表）。
---@param listing any
---@return table|nil
function M.model_caps_from_listing(listing)
    local data = listing
    if type(listing) == "table" and type(listing.data) == "table" then
        data = listing.data
    end
    if type(data) ~= "table" then
        return nil
    end
    local out, found = {}, false
    for i = 1, #data do
        local raw = data[i]
        local id, entry
        if type(raw) == "table" then
            entry = raw
            id = string_field(raw.id) or string_field(raw.model)
        elseif type(raw) == "string" then
            -- Bare-string data[] (older engines): the id is all the engine said, so
            -- this model legitimately has no capability fields. norm_models filters the
            -- placeholder and empty names the same way the id list does.
            id = string_field(raw)
        end
        if id and id ~= "unknown" then
            local caps = R.model_caps_from_entry(entry or {})
            -- 名字知道、能力一个字没采到的模型**不进这张表**：覆盖面由 record.models 负责，
            -- 能力表里"有这个 key"就只意味着"引擎真的说过它的能力"。留一个空条目会让它被
            -- 编码成 {}，读起来像"引擎答了这个模型但拒绝描述它"，与"从没答过"无法区分。
            if caps and next(caps) ~= nil then
                out[id] = caps
                found = true
            end
        end
    end
    if not found then
        return nil
    end
    return out
end

---How much information a caps table actually carries (leaf count, arrays included).
---This is the "信息最全的那份" measure used by the fold below.
---@param value any
---@return number
local function caps_weight(value)
    if value == nil or value == cjson.null then
        return 0
    end
    if type(value) ~= "table" then
        return 1
    end
    local total = 0
    for _, item in pairs(value) do
        total = total + caps_weight(item)
    end
    return total
end

---Deep copy of one JSON-shaped table (caps entries are plain maps/arrays/scalars).
---Defined next to caps_weight because both walk the same shape.
---@param value any
---@return any
local function caps_clone(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = caps_clone(item)
    end
    return out
end

---Deterministic rendering of a caps table, used only as a tie-break key.
---@param value any
---@return string
local function caps_signature(value)
    if value == nil then
        return "nil"
    end
    if type(value) ~= "table" then
        local encoded = json_encode(value)
        return encoded or tostring(value)
    end
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    local parts = {}
    for i = 1, #keys do
        local key = keys[i]
        parts[#parts + 1] = key .. "=" .. caps_signature(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

---Fold several workers' claims about *one model* into a single entry.
---
---规则（root 裁定 2026-10-04）：
---  * 逐字段取非 nil 的那份：一台实例没报 max_output_tokens 而另一台报了，合并结果就该有它
---    （互补字段两边都要留住，这是跨实例合并的全部意义）。
---  * 同一字段两份都有且值不同：取**整条信息最全的那份**（leaf 数多者）的值，而不是逐字段
---    投票。原因是一个引擎对自己能力的陈述是**成套**的，把 A 台的 context_length 和 B 台的
---    max_output_tokens 拼在一起，会造出一份谁都没说过的组合，而那种组合同样会被客户端
---    当成事实拿去做预算。
---  * 为什么不用"取最新"：合并发生在每次查询时，"最新"取决于哪台 worker 的记录后写，而写
---    的顺序由巡检与调度时序决定。那会让同一个模型的对外读数是**抖动的**——同一份配置、同
---    一个上游，两次 /v1/models 给出不同的 context_length，客户端就无法据此缓存任何东西，
---    排查时也没人能复现"昨天那个数是多少"。所以定序只看内容本身（leaf 数，再比字典序），
---    与调用顺序、写入顺序一律无关。
---  * 数组字段（reasoning_efforts）整条取，不按下标拼：两份阶梯的下标没有对齐语义。
---  * 映射字段（supports / modalities）逐子键合，冲突时同样按整条 leaf 数定序。
---没有任何一份带信息时返回 nil。
---@param entries table[] @ normalized caps tables from several workers, same model
---@return table|nil
function M.merge_model_caps(entries)
    if type(entries) ~= "table" or #entries == 0 then
        return nil
    end
    -- 每条候选 = 某个字段（或某个子字段）在某个 worker 那一份里的读数，连同**它所属整条**
    -- 的完整度。冲突时比整条完整度、而不是比这两个值本身——值本身没有"谁更详细"可言
    -- （true 和 false 一样重），能决定可信度的是报这个数的那台引擎一共说了多少话。
    --
    -- 形状：node = { scalar = {cand..}, subs = { [sub] = {cand..} } }。用两层表而不是把
    -- 子键拼进字符串键：Lua 的 pattern 在 C 侧以 NUL 结尾，任何含 \0 的分隔符都会让
    -- match 在分隔符处提前结束（写成 key:match("^(.-)\0(.*)$") 时 sub 恒为 nil，
    -- 于是 bucket[nil] 直接抛 "table index is nil"）。
    local nodes = {}
    local field_order, seen_field = {}, {}
    local function node_for(field)
        local node = nodes[field]
        if not node then
            node = { subs = {}, sub_order = {}, seen_sub = {} }
            nodes[field] = node
            if not seen_field[field] then
                seen_field[field] = true
                field_order[#field_order + 1] = field
            end
        end
        return node
    end
    local function offer(field, sub, cand)
        local node = node_for(field)
        if sub == nil then
            local list = node.scalar
            if not list then
                list = {}
                node.scalar = list
            end
            list[#list + 1] = cand
        else
            local list = node.subs[sub]
            if not list then
                list = {}
                node.subs[sub] = list
                node.seen_sub[sub] = true
                node.sub_order[#node.sub_order + 1] = sub
            end
            list[#list + 1] = cand
        end
    end
    for i = 1, #entries do
        local entry = entries[i]
        if type(entry) == "table" and next(entry) ~= nil then
            local entry_weight = caps_weight(entry)
            local entry_sig = caps_signature(entry)
            for field, value in pairs(entry) do
                if type(value) == "table" and not caps_is_seq(value) then
                    for sub, sub_value in pairs(value) do
                        if sub_value ~= nil and sub_value ~= cjson.null then
                            offer(field, tostring(sub), {
                                value = sub_value, weight = entry_weight, sig = entry_sig,
                                vtag = caps_signature(sub_value),
                            })
                        end
                    end
                elseif value ~= nil and value ~= cjson.null then
                    offer(field, nil, {
                        value = value, weight = entry_weight, sig = entry_sig,
                        vtag = caps_signature(value),
                    })
                end
            end
        end
    end
    -- 定序全看成：完整度 > 整条签名 > 值签名。三层都不含时间、不含 worker 顺序，
    -- 所以把 entries 数组倒过来传，赢家一定是同一个（探针第 7 项钉的就是这条）。
    local function winner(list)
        local best
        for i = 1, #list do
            local cand = list[i]
            if not best or cand.weight > best.weight
                or (cand.weight == best.weight
                    and (cand.sig > best.sig
                        or (cand.sig == best.sig and cand.vtag > best.vtag))) then
                best = cand
            end
        end
        return best
    end
    local out = {}
    -- 每个字段先铺子键（映射形状），标量只在没有任何子键时兜底：同一字段既有被当映射报的、
    -- 又有被当标量报的，说明上游把形状写坏了（supports=true 对上 supports={tool_use=true}）。
    -- 这时按内容定胜负——报出了结构的那份更可信——而不是让遍历先后决定，否则又回到
    -- "结果随调用顺序变化"。
    for i = 1, #field_order do
        local field = field_order[i]
        local node = nodes[field]
        local bucket, bucket_any = nil, false
        for j = 1, #node.sub_order do
            local sub = node.sub_order[j]
            local best = winner(node.subs[sub])
            if best then
                if not bucket then
                    bucket = {}
                end
                bucket[sub] = caps_clone(best.value)
                bucket_any = true
            end
        end
        if bucket_any then
            out[field] = bucket
        else
            local best = winner(node.scalar)
            if best then
                out[field] = caps_clone(best.value)
            end
        end
    end
    if next(out) == nil then
        return nil
    end
    return out
end

---Copy a { [model] = caps } map, dropping empty entries so the stored record never
---carries a model that says nothing (an empty entry would encode as `{}` and read as
---"the engine answered this model and refused to describe it" — indistinguishable from
---"no data", which is exactly the state we promised never to fake).
---@param caps any
---@return table|nil
local function clone_model_caps(caps)
    if type(caps) ~= "table" then
        return nil
    end
    local out = {}
    for name, entry in pairs(caps) do
        if type(name) == "string" and name ~= "" and type(entry) == "table"
            and next(entry) ~= nil then
            out[name] = caps_clone(entry)
        end
    end
    if next(out) == nil then
        return nil
    end
    return out
end

---内容比较（而不是引用比较）：patch_record 用它决定"这次要不要重写记录"。
---cjson 对 hash 部分的键序不作保证，所以先按键名排一遍再生成签名。
---@param a any
---@param b any
---@return boolean
local function caps_equal(a, b)
    return caps_signature(a) == caps_signature(b)
end

-- Late-bind the facade: registry.lua pre-registers package.loaded before it
-- requires this module, and a test that swaps the whole module table for a stub
-- through package.loaded is honoured by the same lookup.
R = package.loaded["resty.luarouter.registry"] or require "resty.luarouter.registry"


-- Published for the registry siblings and the facade.
M.caps_equal = caps_equal
M.clone_model_caps = clone_model_caps
M.string_field = string_field

return M
