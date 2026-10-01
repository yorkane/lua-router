#!/usr/bin/env luajit
-- service_discovery.lua 纯 Lua 单测（DP 展开决策 + K8s pod 过滤/协调）。
--   运行（与其余 luajit 口径单测一致，cwd = lua-router/）：
--   docker run --rm -v "$PWD/lua-router:/r:ro" -w /r authz:latest \
--     /usr/local/openresty/luajit/bin/luajit test/unit/test_service_discovery.lua
--
-- 只测决策函数（不碰 ngx / shared dict / cosocket）：expand_dp、poll_once、start
-- 需要真实 registry 与 timer，那部分由 test/integration/e2e_discovery_dp.py 覆盖。
local root = os.getenv("LUA_TEST_LIB") or "./lualib"
package.path = root .. "/?.lua;" .. package.path

local sd = require "resty.luarouter.service_discovery"

local passed, failed = 0, 0
local failures = {}

local function check(cond, name, detail)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = name .. (detail and (" -> " .. tostring(detail)) or "")
    end
end

local function eq(actual, expect, name)
    check(actual == expect, name,
        actual ~= expect and ("got " .. tostring(actual) .. " want " .. tostring(expect)) or nil)
end

local function new_case(name)
    io.write("  case: " .. name .. "\n")
end

local function count(tbl)
    local n = 0
    for _ in pairs(tbl or {}) do
        n = n + 1
    end
    return n
end

--------------------------------------------------------------------------
new_case("parse_selector")
--------------------------------------------------------------------------
local sel = sd.parse_selector("app=sglang,tier=pp")
eq(sel.app, "sglang", "parse: first pair")
eq(sel.tier, "pp", "parse: second pair")
eq(count(sd.parse_selector("a=1 b=2")), 2, "parse: space separated")
eq(count(sd.parse_selector(nil)), 0, "parse: nil -> empty")
eq(count(sd.parse_selector("")), 0, "parse: empty -> empty")
eq(count(sd.parse_selector("garbage")), 0, "parse: term without = is dropped")
eq(sd.parse_selector("a=b=c").a, "b=c", "parse: split on first = only")
eq(sd.selector_string(sd.parse_selector("z=9,a=1,m=2")), "a=1,m=2,z=9",
    "selector_string: sorted, stable")
eq(sd.selector_string({}), "", "selector_string: empty")

check(sd.selector_matches({ app = "x" }, { app = "x" }) == true, "matches: subset ok")
check(sd.selector_matches({ app = "x", other = "1" }, { app = "x" }) == true,
    "matches: extra pod labels allowed")
check(sd.selector_matches({ app = "y" }, { app = "x" }) == false, "matches: value differs")
check(sd.selector_matches({ app = "x" }, {}) == false,
    "matches: empty selector claims nothing (Rust parity)")
check(sd.selector_matches(nil, { app = "x" }) == false, "matches: pod without labels")

--------------------------------------------------------------------------
new_case("strip_dp_rank")
--------------------------------------------------------------------------
local b, r
b, r = sd.strip_dp_rank("http://10.66.5.115:20664@3")
eq(b, "http://10.66.5.115:20664", "strip: base url")
eq(r, 3, "strip: rank")
b, r = sd.strip_dp_rank("http://10.0.0.5:30000@0")
eq(b, "http://10.0.0.5:30000", "strip: rank 0")
eq(r, 0, "strip: rank 0 value")
b, r = sd.strip_dp_rank("http://10.0.0.5:30000")
eq(b, "http://10.0.0.5:30000", "strip: plain url unchanged")
eq(r, nil, "strip: plain url has no rank")
-- userinfo must survive: the tail after '@' is not all digits.
b, r = sd.strip_dp_rank("http://user:pw@10.0.0.5:30000")
eq(b, "http://user:pw@10.0.0.5:30000", "strip: userinfo untouched")
eq(r, nil, "strip: userinfo not a rank")
-- Two '@' (userinfo + rank): only the trailing numeric one is stripped.
b, r = sd.strip_dp_rank("http://user:pw@10.0.0.5:30000@2")
eq(b, "http://user:pw@10.0.0.5:30000", "strip: rank after userinfo")
eq(r, 2, "strip: rank after userinfo value")
-- IPv6 literal.
b, r = sd.strip_dp_rank("http://[fe80::1]:30000@1")
eq(b, "http://[fe80::1]:30000", "strip: ipv6 base")
eq(r, 1, "strip: ipv6 rank")
-- Non-numeric tail is left alone (a path segment or a typo).
b, r = sd.strip_dp_rank("http://h:80@abc")
eq(b, "http://h:80@abc", "strip: non-numeric tail untouched")
eq(r, nil, "strip: non-numeric tail no rank")

--------------------------------------------------------------------------
new_case("dp_size_from_server_info")
--------------------------------------------------------------------------
eq(sd.dp_size_from_server_info({ dp_size = 4 }), 4, "dp_size: top level")
eq(sd.dp_size_from_server_info({ dp_size = 1 }), 1, "dp_size: single")
eq(sd.dp_size_from_server_info({ server_args = { dp_size = 8 } }), 8,
    "dp_size: nested under server_args")
eq(sd.dp_size_from_server_info({ dp_size = "3" }), 3, "dp_size: numeric string")
eq(sd.dp_size_from_server_info({}), nil, "dp_size: absent -> nil")
eq(sd.dp_size_from_server_info({ dp_size = 0 }), nil, "dp_size: zero rejected")
eq(sd.dp_size_from_server_info({ dp_size = -1 }), nil, "dp_size: negative rejected")
eq(sd.dp_size_from_server_info({ dp_size = 2.5 }), nil, "dp_size: fractional rejected")
eq(sd.dp_size_from_server_info(nil), nil, "dp_size: nil body -> nil")
eq(sd.dp_size_from_server_info({ dp_size = "x" }), nil, "dp_size: garbage rejected")

--------------------------------------------------------------------------
new_case("expansion_plan")
--------------------------------------------------------------------------
local action, width
action, width = sd.expansion_plan(4, 1)
eq(action, "expand", "plan: dp_size>1 expands")
eq(width, 4, "plan: width follows dp_size")
action, width = sd.expansion_plan(1, 1)
eq(action, "single", "plan: dp_size=1 does not expand")
eq(width, 1, "plan: single width 1")
action, width = sd.expansion_plan(nil, 1)
eq(action, "retry", "plan: missing dp_size retries")
eq(width, nil, "plan: retry has no width")
action, width = sd.expansion_plan(nil, sd.MAX_DP_ATTEMPTS - 1)
eq(action, "retry", "plan: still retrying one probe before the ceiling")
action, width = sd.expansion_plan(nil, sd.MAX_DP_ATTEMPTS)
eq(action, "give_up", "plan: settles after the attempt ceiling")
eq(width, 1, "plan: give_up keeps one entry")

--------------------------------------------------------------------------
new_case("expansion_requests")
--------------------------------------------------------------------------
local base = {
    url = "http://10.0.0.5:30000",
    model_id = "ornith-35b",
    priority = 12,
    cost = 1.5,
    api_key = "sk-secret",
    labels = { gpu = "l40", dp_size = nil },
    health_check_timeout_secs = 5,
    health_check_interval_secs = 4,
    health_success_threshold = 2,
    health_failure_threshold = 3,
}
local reqs = sd.expansion_requests(base, 4)
eq(#reqs, 4, "expand dp_size=4 -> 4 requests")
eq(reqs[1].url, "http://10.0.0.5:30000@0", "rank 0 url")
eq(reqs[4].url, "http://10.0.0.5:30000@3", "rank 3 url")
eq(reqs[1].dp_rank, 0, "rank 0 dp_rank")
eq(reqs[3].dp_rank, 2, "rank 2 dp_rank")
eq(reqs[1].dp_size, 4, "rank dp_size carried")
eq(reqs[2].dp_base_url, "http://10.0.0.5:30000", "rank dp_base_url")
eq(reqs[1].model_id, "ornith-35b", "rank inherits model_id")
eq(reqs[1].priority, 12, "rank inherits priority")
eq(reqs[1].cost, 1.5, "rank inherits cost")
eq(reqs[1].api_key, "sk-secret", "rank inherits api_key")
eq(reqs[1].health_check_interval_secs, 4, "rank inherits health knobs")
eq(reqs[1].labels.gpu, "l40", "rank inherits labels")
eq(reqs[1].labels.dp_rank, "0", "rank label dp_rank (string, label domain)")
eq(reqs[1].labels.dp_size, "4", "rank label dp_size")
eq(reqs[2].dp_aware, true, "rank marked dp_aware")
eq(#sd.expansion_requests({ url = "http://h:1" }, 1), 1, "dp_size=1 -> 1 request")
-- The expansion request must be accepted by the registry's url normaliser, i.e.
-- the rank suffix has to survive gsub of trailing slashes and the scheme check.
check(reqs[1].url:find("@0", 1, true) ~= nil, "rank suffix not trimmed by construction")

--------------------------------------------------------------------------
new_case("inject_dp_rank")
--------------------------------------------------------------------------
-- First-occurrence splice, the same rule router.lua applies to "model".
local out, changed
out, changed = sd.inject_dp_rank('{"model":"m","messages":[]}', { dp_rank = 2 })
eq(changed, true, "inject: reports change")
eq(out, '{"data_parallel_rank":2,"model":"m","messages":[]}',
    "inject: inserted as first top-level member")
out, changed = sd.inject_dp_rank('{"data_parallel_rank":0,"model":"m"}', { dp_rank = 3 })
eq(out, '{"data_parallel_rank":3,"model":"m"}', "inject: existing member rewritten")
eq(changed, true, "inject: rewrite reports change")
out, changed = sd.inject_dp_rank('{"model":"m","data_parallel_rank":0}', { dp_rank = 1 })
eq(out, '{"model":"m","data_parallel_rank":1}',
    "inject: rewrite happens in place, key order preserved")
out, changed = sd.inject_dp_rank('{"model":"m", "data_parallel_rank" : 7 }', { dp_rank = 1 })
eq(out, '{"model":"m", "data_parallel_rank":1 }', "inject: whitespace tolerated")
-- A nested member with the same name must not be touched: rewriting a tool-call
-- argument blob would corrupt the payload.
out, changed = sd.inject_dp_rank(
    '{"tool":{"data_parallel_rank":9},"model":"m"}', { dp_rank = 2 })
eq(out, '{"data_parallel_rank":2,"tool":{"data_parallel_rank":9},"model":"m"}',
    "inject: nested same-name member left alone")
-- String values containing a brace or an escaped quote must not confuse the scan.
out, changed = sd.inject_dp_rank('{"prompt":"a{b}c \\"x \\\"","model":"m"}', { dp_rank = 1 })
eq(out, '{"data_parallel_rank":1,"prompt":"a{b}c \\"x \\\"","model":"m"}',
    "inject: braces and escapes inside strings handled")
out, changed = sd.inject_dp_rank('{}', { dp_rank = 1 })
eq(out, '{"data_parallel_rank":1}', "inject: empty object")
out, changed = sd.inject_dp_rank('{"model":"m"}', { dp_rank = nil })
eq(changed, false, "inject: record without dp_rank untouched")
eq(out, '{"model":"m"}', "inject: payload unchanged without a rank")
out, changed = sd.inject_dp_rank('not json', { dp_rank = 1 })
eq(changed, false, "inject: body without an object brace untouched")
eq(out, 'not json', "inject: non-object body returned as is")
-- rank 0 is injected too (a stale client value must be corrected, not skipped).
out, changed = sd.inject_dp_rank('{"data_parallel_rank":2}', { dp_rank = 0 })
eq(out, '{"data_parallel_rank":0}', "inject: rank 0 overwrites a stale value")

--------------------------------------------------------------------------
-- K8s: pod -> worker
--------------------------------------------------------------------------
local function pod(name, ip, phase, ready, labels, annotations)
    return {
        metadata = { name = name, labels = labels, annotations = annotations },
        status = {
            phase = phase,
            podIP = ip,
            conditions = { { type = "Initialized", status = "True" },
                           { type = "Ready", status = ready and "True" or "False" } },
        },
    }
end

new_case("pod_from_api")
--------------------------------------------------------------------------
local regular_sel = { app = "sglang" }
local opts = { selector = regular_sel, prefill_selector = {}, decode_selector = {},
               pd_mode = false }

local info = sd.pod_from_api(pod("w-0", "10.1.2.3", "Running", true,
    { app = "sglang", gpu = "h100" }), opts)
check(type(info) == "table", "pod: regular running pod accepted")
eq(info.name, "w-0", "pod: name carried")
eq(info.ip, "10.1.2.3", "pod: podIP carried")
eq(info.status, "Running", "pod: phase carried")
eq(info.is_ready, true, "pod: Ready carried")
eq(info.pod_type, "regular", "pod: type regular outside PD mode")
eq(info.labels.gpu, "h100", "pod: labels kept (gpu)")
eq(info.bootstrap_port, nil, "pod: no bootstrap port for a regular pod")

check(sd.pod_from_api(pod("w-1", "10.1.2.4", "Running", false, { app = "sglang" }), opts)
    ~= nil, "pod: not-ready pod still parsed (so it can be deregistered)")
check(sd.pod_is_healthy(sd.pod_from_api(
    pod("w-1", "10.1.2.4", "Running", false, { app = "sglang" }), opts)) == false,
    "pod: Ready=False is unhealthy")
check(sd.pod_is_healthy(sd.pod_from_api(
    pod("w-2", "10.1.2.5", "Pending", true, { app = "sglang" }), opts)) == false,
    "pod: phase Pending is unhealthy")
check(sd.pod_is_healthy(sd.pod_from_api(
    pod("w-3", "10.1.2.6", "Succeeded", true, { app = "sglang" }), opts)) == false,
    "pod: phase Succeeded is unhealthy")
check(sd.pod_is_healthy(info) == true, "pod: Running+Ready is healthy")
check(sd.pod_from_api(pod("w-4", nil, "Running", true, { app = "sglang" }), opts) == nil,
    "pod: no podIP -> not a worker at all")
check(sd.pod_from_api(pod("w-5", "10.1.2.7", "Running", true, { app = "other" }), opts)
    == nil, "pod: selector mismatch -> ignored")
check(sd.pod_from_api(pod("w-6", "10.1.2.8", "Running", true, nil), opts) == nil,
    "pod: no labels -> selector cannot match")
check(sd.pod_from_api({ metadata = { name = "no-status" } }, opts) == nil,
    "pod: missing status section tolerated")
check(sd.pod_from_api(pod("", "10.1.2.9", "Running", true, { app = "sglang" }), opts)
    == nil, "pod: nameless pod ignored")

-- PD classification + bootstrap annotation.
local pd_opts = {
    selector = {},
    prefill_selector = sd.parse_selector("component=prefill"),
    decode_selector = sd.parse_selector("component=decode"),
    pd_mode = true,
}
local pre = sd.pod_from_api(pod("p-0", "10.1.3.1", "Running", true,
    { app = "sglang", component = "prefill" },
    { ["sglang.ai/bootstrap-port"] = "8998" }), pd_opts)
eq(pre.pod_type, "prefill", "pod: prefill selector wins")
eq(pre.bootstrap_port, 8998, "pod: bootstrap port from the sglang annotation")
local dec = sd.pod_from_api(pod("d-0", "10.1.3.2", "Running", true,
    { component = "decode" }, { ["sglang.ai/bootstrap-port"] = "8998" }), pd_opts)
eq(dec.pod_type, "decode", "pod: decode selector")
eq(dec.bootstrap_port, nil, "pod: decode carries no bootstrap port (Rust parity)")
check(sd.pod_from_api(pod("x-0", "10.1.3.3", "Running", true,
    { component = "other" }), pd_opts) == nil, "pod: PD mode claims nothing unmatched")
local bad_port = sd.pod_from_api(pod("p-1", "10.1.3.4", "Running", true,
    { component = "prefill" }, { ["sglang.ai/bootstrap-port"] = "notaport" }), pd_opts)
eq(bad_port.bootstrap_port, nil, "pod: unusable bootstrap annotation dropped")
eq(bad_port.pod_type, "prefill", "pod: bad annotation does not lose the pod")

eq(sd.pod_worker_url({ ip = "10.1.2.3" }, 8000), "http://10.1.2.3:8000",
    "worker_url: http://<podIP>:<port>")

--------------------------------------------------------------------------
new_case("pod_infos / desired_workers")
--------------------------------------------------------------------------
local doc = {
    items = {
        pod("a", "10.0.0.1", "Running", true, { app = "sglang" }),
        pod("b", "10.0.0.2", "Running", false, { app = "sglang" }),
        pod("c", "10.0.0.3", "Running", true, { app = "other" }),
        pod("d", "10.0.0.4", "Pending", true, { app = "sglang" }),
    },
}
local infos = sd.pod_infos(doc, opts)
eq(#infos, 3, "pod_infos: selector-matched pods (a, b, d)")
local wanted = sd.desired_workers(infos, 80, { pd_mode = false, api_key = "sk-router" })
eq(#wanted, 1, "desired_workers: only the healthy pod (a)")
eq(wanted[1].url, "http://10.0.0.1:80", "desired_workers: url uses the configured port")
eq(wanted[1].discovery, "kubernetes", "desired_workers: discovery marker")
eq(wanted[1].api_key, "sk-router", "desired_workers: router api_key forwarded")
eq(wanted[1].labels.app, "sglang", "desired_workers: pod labels kept")
eq(wanted[1].labels.discovered, "kubernetes", "desired_workers: discovered label")
eq(wanted[1].worker_type, nil, "desired_workers: regular pod has no worker_type")
eq(#sd.pod_infos({}, opts), 0, "pod_infos: empty document")
eq(#sd.pod_infos(nil, opts), 0, "pod_infos: undecodable document tolerated")
eq(#sd.pod_infos({ items = "notalist" }, opts), 0, "pod_infos: malformed items tolerated")

local pd_infos = sd.pod_infos({
    items = {
        pod("p", "10.0.1.1", "Running", true, { component = "prefill" },
            { ["sglang.ai/bootstrap-port"] = "9000" }),
        pod("q", "10.0.1.2", "Running", true, { component = "decode" }),
    }
}, pd_opts)
local pd_wanted = sd.desired_workers(pd_infos, 80, { pd_mode = true })
eq(#pd_wanted, 2, "pd: both pods wanted")
eq(pd_wanted[1].worker_type, "prefill", "pd: worker_type prefill")
eq(pd_wanted[1].bootstrap_port, 9000, "pd: bootstrap_port forwarded")
eq(pd_wanted[1].labels.worker_type, "prefill", "pd: labels.worker_type for pd.pool_of")
eq(pd_wanted[2].worker_type, "decode", "pd: worker_type decode")
eq(pd_wanted[2].bootstrap_port, nil, "pd: decode has no bootstrap_port")

--------------------------------------------------------------------------
new_case("plan (reconcile diff)")
--------------------------------------------------------------------------
local d1 = { { url = "http://10.0.0.1:80" }, { url = "http://10.0.0.2:80" } }
local c1 = { { id = "id-2", url = "http://10.0.0.2:80" },
             { id = "id-9", url = "http://10.0.0.9:80" } }
local add, remove = sd.plan(d1, c1)
eq(#add, 1, "plan: one new pod")
eq(add[1].url, "http://10.0.0.1:80", "plan: the new pod is the add")
eq(#remove, 1, "plan: one vanished pod")
eq(remove[1].id, "id-9", "plan: removal carries the registry id")
add, remove = sd.plan(d1, d1)
eq(#add, 0, "plan: unchanged set adds nothing")
eq(#remove, 0, "plan: unchanged set removes nothing")
add, remove = sd.plan({}, c1)
eq(#add, 0, "plan: empty desired adds nothing")
eq(#remove, 2, "plan: empty desired removes everything tracked")
add, remove = sd.plan({}, {})
eq(#add + #remove, 0, "plan: empty vs empty is a no-op")
-- A data-parallel engine discovered as one pod is stored as ranks: the diff must
-- see the ranks as covering the pod, or every poll would tear them down and
-- re-expand them (engine flapping once per interval).
local ranks = { { id = "r0", url = "http://10.0.0.1:80@0", dp_base_url = "http://10.0.0.1:80" },
                { id = "r1", url = "http://10.0.0.1:80@1", dp_base_url = "http://10.0.0.1:80" } }
add, remove = sd.plan({ { url = "http://10.0.0.1:80" } }, ranks)
eq(#add, 0, "plan: ranks cover their pod (no re-add of the base url)")
eq(#remove, 0, "plan: ranks are kept while the pod is listed")
add, remove = sd.plan({}, ranks)
eq(#add, 0, "plan: a vanished DP pod adds nothing")
eq(#remove, 2, "plan: a vanished DP pod takes every rank with it")
-- The base entry (before the sweep expands it) and the ranks must not both be
-- treated as two claims on the same pod.
add, remove = sd.plan({ { url = "http://10.0.0.1:80" } },
    { { id = "base", url = "http://10.0.0.1:80" } })
eq(#add + #remove, 0, "plan: unexpanded base entry is stable")
eq(sd.coverage_key({ url = "http://h@2" }), "http://h@2",
    "coverage_key: a plain url is its own key")

-- A pod that flipped Ready=False leaves the desired set, so it is deregistered.
local d2 = sd.desired_workers(sd.pod_infos(doc, opts), 80, {})
local c2 = { { id = "a", url = "http://10.0.0.1:80" }, { id = "b", url = "http://10.0.0.2:80" } }
add, remove = sd.plan(d2, c2)
eq(#add, 0, "plan: no re-add for a worker that is already there")
eq(#remove, 1, "plan: a pod that went not-ready is deregistered")
eq(remove[1].id, "b", "plan: the not-ready pod is the removal")

--------------------------------------------------------------------------
new_case("pods_url / api_server / auth")
--------------------------------------------------------------------------
eq(sd.url_encode("a=b,c=d"), "a%3Db%2Cc%3Dd", "url_encode: = and , escaped")
eq(sd.pods_url("http://1.2.3.4:8001", nil, "app=x"),
    "http://1.2.3.4:8001/api/v1/pods?labelSelector=app%3Dx", "pods_url: cluster scoped")
eq(sd.pods_url("http://1.2.3.4:8001", "team-a", ""),
    "http://1.2.3.4:8001/api/v1/namespaces/team-a/pods", "pods_url: namespaced, no selector")
eq(sd.pods_url("https://k:6443", "ns", "a=1,b=2"),
    "https://k:6443/api/v1/namespaces/ns/pods?labelSelector=a%3D1%2Cb%3D2",
    "pods_url: https + namespace + selector")

local api, reason
api, reason = sd.api_server({ kube_api_server = "http://127.0.0.1:7777/" })
eq(api, "http://127.0.0.1:7777", "api_server: override wins, trailing slash trimmed")
api, reason = sd.api_server({ kube_api_server = "" })
if api then
    eq(api, "https://" .. api:match("^https://(.+)$"), "api_server: in-cluster form is https")
else
    check(type(reason) == "string", "api_server: no cluster -> reason given", reason)
end
-- The downward API form, when the environment provides it.
if os.setenv then
    os.setenv("KUBERNETES_SERVICE_HOST", "10.96.0.1")
    os.setenv("KUBERNETES_SERVICE_PORT", "443")
    eq(sd.api_server({}), "https://10.96.0.1:443", "api_server: in-cluster env")
    os.setenv("KUBERNETES_SERVICE_HOST", "fe80::1")
    eq(sd.api_server({}), "https://[fe80::1]:443", "api_server: ipv6 host bracketed")
    os.setenv("KUBERNETES_SERVICE_HOST", "")
end
eq(sd.auth_headers({ kube_sa_path = "/nonexistent-sa-dir" }), nil,
    "auth_headers: no token file -> no header")
eq(sd.read_file("/nonexistent-sa-dir/token"), nil, "read_file: missing file -> nil")

-- A projected SA volume is a directory with a token file inside it.
local dir = (os.getenv("LUA_TMPDIR") or "/tmp") .. "/lr-sa-test"
os.execute("mkdir -p " .. dir)
local f = io.open(dir .. "/token", "wb")
f:write("fake-sa-token\n")
f:close()
local headers = sd.auth_headers({ kube_sa_path = dir })
check(type(headers) == "table", "auth_headers: token present -> header")
if type(headers) == "table" then
    eq(headers.Authorization, "Bearer fake-sa-token",
        "auth_headers: bearer, trailing newline trimmed")
end
local raw = sd.read_file(dir .. "/token")
eq(raw, "fake-sa-token", "read_file: content read, whitespace trimmed")
os.remove(dir .. "/token")
os.execute("rmdir " .. dir)

--------------------------------------------------------------------------
new_case("poll_opts (selector assembly)")
--------------------------------------------------------------------------
local o, text = sd.poll_opts({ discovery_selector = "app=sglang",
                               prefill_selector = "", decode_selector = "" })
eq(text, "app=sglang", "poll_opts: regular mode passes the selector to the API")
eq(o.pd_mode, false, "poll_opts: no pd selectors -> regular")
o, text = sd.poll_opts({ discovery_selector = "app=sglang",
                         prefill_selector = "component=prefill",
                         decode_selector = "component=decode", enable_igw = false })
eq(o.pd_mode, true, "poll_opts: pd selectors detected")
eq(text, "", "poll_opts: pd mode filters client-side (no labelSelector)")
eq(count(o.selector), 0, "poll_opts: --selector ignored in PD mode without IGW")
o, text = sd.poll_opts({ discovery_selector = "app=sglang",
                         prefill_selector = "component=prefill",
                         enable_igw = true })
eq(count(o.selector), 1, "poll_opts: IGW mode keeps the regular selector alongside PD")

eq(sd.interval({ discovery_interval_secs = 0 }), 1, "interval: clamped to >= 1s")
eq(sd.interval({ discovery_interval_secs = 60 }), 60, "interval: 60s default kept")
eq(sd.interval({}), 60, "interval: unset -> 60s (Rust check_interval)")
eq(sd.interval({ discovery_interval_secs = 999999 }), 3600, "interval: capped at 1h")


--------------------------------------------------------------------------
new_case("parse_field_selector / field_matches (fieldSelector equality)")
--------------------------------------------------------------------------
local fs = sd.parse_field_selector("metadata.name=sglang-0")
eq(#fs, 1, "field: one term parsed")
eq(fs[1].key, "metadata.name", "field: key")
eq(fs[1].value, "sglang-0", "field: value")
eq(sd.field_selector_text(fs), "metadata.name=sglang-0", "field: canonical text")
eq(#sd.parse_field_selector("metadata.name=a,status.phase=Running"), 2,
    "field: comma separated")
eq(#sd.parse_field_selector("metadata.name=a status.phase=Running"), 2,
    "field: space separated")
eq(count(sd.parse_field_selector(nil)), 0, "field: nil -> empty")
eq(count(sd.parse_field_selector("")), 0, "field: empty -> empty")
eq(sd.field_selector_text(sd.parse_field_selector("status.phase==Running")),
    "status.phase=Running", "field: == normalised onto =")
eq(sd.field_selector_text(sd.parse_field_selector("z=9,a=1")), "a=1,z=9",
    "field: canonical text sorted (stable URL)")
-- The operators this client cannot evaluate are refused, not turned into an
-- equality test against a nonsense value.
eq(sd.field_selector_text(sd.parse_field_selector("app!=sglang")), "app!=sglang",
    "field: != carried verbatim as unsupported")
eq(sd.unsupported_field_term(sd.parse_field_selector("app!=sglang")), "app!=sglang",
    "field: != reported as unsupported")
check(sd.unsupported_field_term(sd.parse_field_selector("metadata.name=ok")) == nil,
    "field: a good term reports nothing unsupported")
eq(sd.unsupported_field_term(sd.parse_field_selector("phase>Running")), "phase>Running",
    "field: > unsupported")
eq(#sd.parse_field_selector("app"), 1, "field: a bare label is kept as one junk term")
eq(sd.unsupported_field_term(sd.parse_field_selector("app")), "app",
    "field: a bare label is unsupported, not an equality test")
eq(#sd.parse_field_selector("metadata.name="), 1, "field: an empty value is kept as junk")
eq(sd.unsupported_field_term(sd.parse_field_selector("metadata.name=")), "metadata.name=",
    "field: an empty value is unsupported rather than 'match the empty name'")
eq(#sd.parse_field_selector("metadata.name=a,app"), 2,
    "field: a junk term survives as unsupported next to a good one")

local pod_ok = {
    metadata = { name = "sglang-0", namespace = "team-a", labels = { app = "sglang" } },
    status = { phase = "Running", podIP = "10.0.0.1",
               conditions = { { type = "Ready", status = "True" } } },
    spec = { nodeName = "node-a" },
}
check(sd.field_matches(pod_ok, {}) == true, "field match: no terms matches everything")
check(sd.field_matches(pod_ok, nil) == true, "field match: nil terms matches everything")
check(sd.field_matches(pod_ok, sd.parse_field_selector("metadata.name=sglang-0")) == true,
    "field match: metadata.name equality")
check(sd.field_matches(pod_ok, sd.parse_field_selector("metadata.name=sglang-1")) == false,
    "field match: metadata.name mismatch")
check(sd.field_matches(pod_ok, sd.parse_field_selector("status.phase=Running")) == true,
    "field match: status.phase equality")
check(sd.field_matches(pod_ok, sd.parse_field_selector("metadata.namespace=team-a,"
    .. "spec.nodeName=node-a")) == true, "field match: multi-term AND")
check(sd.field_matches(pod_ok, sd.parse_field_selector("metadata.namespace=other,"
    .. "spec.nodeName=node-a")) == false, "field match: one mismatch kills the pod")
check(sd.field_matches(pod_ok, sd.parse_field_selector("status.podIP=10.0.0.1")) == true,
    "field match: status.podIP equality")
check(sd.field_matches(pod_ok, sd.parse_field_selector("metadata.uid=abc")) == false,
    "field match: unknown field refuses the pod (never widens the set)")
check(sd.field_matches(nil, sd.parse_field_selector("metadata.name=sglang-0")) == false,
    "field match: a missing object cannot match")

--------------------------------------------------------------------------
new_case("list_url / watch_url (query assembly)")
--------------------------------------------------------------------------
eq(sd.list_url("http://k:8001", nil, "", ""), "http://k:8001/api/v1/pods",
    "list_url: bare list path unchanged")
eq(sd.list_url("http://k:8001", "ns", "app=sglang", ""),
    "http://k:8001/api/v1/namespaces/ns/pods?labelSelector=app%3Dsglang",
    "list_url: label selector unchanged from pods_url")
eq(sd.list_url("http://k:8001", nil, "", "metadata.name=x"),
    "http://k:8001/api/v1/pods?fieldSelector=metadata.name%3Dx",
    "list_url: field selector alone gets the ?")
eq(sd.list_url("http://k:8001", nil, "app=sglang", "metadata.name=x"),
    "http://k:8001/api/v1/pods?labelSelector=app%3Dsglang&fieldSelector=metadata.name%3Dx",
    "list_url: both selectors joined with &")
eq(sd.watch_url("http://k:8001", "ns", "app=sglang", "metadata.name=x", "1002"),
    "http://k:8001/api/v1/namespaces/ns/pods?watch=true&allowWatchBookmarks=true"
    .. "&labelSelector=app%3Dsglang&fieldSelector=metadata.name%3Dx&resourceVersion=1002",
    "watch_url: full parameter order")
eq(sd.watch_url("http://k:8001", nil, "", nil, nil),
    "http://k:8001/api/v1/pods?watch=true&allowWatchBookmarks=true",
    "watch_url: no empty parameters when nothing is configured")
eq(sd.watch_url("http://k:8001", nil, "", nil, "0"),
    "http://k:8001/api/v1/pods?watch=true&allowWatchBookmarks=true&resourceVersion=0",
    "watch_url: resourceVersion 0 is still sent")
eq(sd.watch_url("http://k:8001", nil, "", nil, 42),
    "http://k:8001/api/v1/pods?watch=true&allowWatchBookmarks=true&resourceVersion=42",
    "watch_url: numeric resourceVersion stringified")

--------------------------------------------------------------------------
new_case("pod_from_api with fieldSelector / router exclusion / deletionTimestamp")
--------------------------------------------------------------------------
local base_opts = { selector = sd.parse_selector("app=sglang") }
local pod_del = {
    metadata = { name = "sglang-0", labels = { app = "sglang" },
                 deletionTimestamp = "2026-09-30T00:00:00Z" },
    status = { phase = "Running", podIP = "10.0.0.1",
               conditions = { { type = "Ready", status = "True" } } },
}
eq(sd.pod_from_api(pod_ok, base_opts).deleting, nil,
    "pod: no deletionTimestamp means no deleting mark")
eq(sd.pod_from_api(pod_del, base_opts).deleting, true,
    "pod: deletionTimestamp is carried (poll has no DELETED event)")
eq(sd.pod_from_api(pod_ok, { selector = base_opts.selector,
    field_selector = sd.parse_field_selector("metadata.name=sglang-0") }) ~= nil, true,
    "pod: a matching fieldSelector keeps the pod")
eq(sd.pod_from_api(pod_ok, { selector = base_opts.selector,
    field_selector = sd.parse_field_selector("metadata.name=other") }), nil,
    "pod: a non-matching fieldSelector drops the pod (client-side recheck)")
eq(sd.pod_from_api(pod_ok, { selector = base_opts.selector,
    router_selector = sd.parse_selector("app=sglang") }), nil,
    "pod: a router pod is never a worker candidate")
eq(sd.pod_from_api(pod_ok, { selector = base_opts.selector,
    router_selector = sd.parse_selector("app=lua-router") }).name, "sglang-0",
    "pod: a non-matching router selector leaves the worker path alone")
eq(count(sd.pod_infos({ items = { pod_ok, pod_del } }, { selector = base_opts.selector,
    field_selector = sd.parse_field_selector("metadata.name=sglang-0") })), 2,
    "pod_infos: field selector applies to every item (healthy and deleting alike)")

--------------------------------------------------------------------------
new_case("router_pod_from_api / router_mesh_address")
--------------------------------------------------------------------------
local router_pod = {
    metadata = { name = "lua-router-1", labels = { app = "lua-router" },
                 annotations = { ["sglang.ai/mesh-port"] = "9002" } },
    status = { phase = "Running", podIP = "10.0.1.2",
               conditions = { { type = "Ready", status = "True" } } },
}
local rsel = { router_selector = sd.parse_selector("app=lua-router") }
local rinfo = sd.router_pod_from_api(router_pod, rsel)
eq(rinfo.name, "lua-router-1", "router pod: name")
eq(rinfo.ip, "10.0.1.2", "router pod: podIP")
eq(rinfo.mesh_port, 9002, "router pod: mesh port from the annotation")
eq(sd.router_mesh_address(rinfo, 80), "http://10.0.1.2:9002",
    "router mesh address uses the annotated port")
eq(sd.router_mesh_address({ ip = "10.0.1.9" }, 30000), "http://10.0.1.9:30000",
    "router mesh address falls back to the configured port")
eq(sd.router_mesh_address({ ip = "10.0.1.9" }, nil), "http://10.0.1.9:30000",
    "router mesh address: no fallback at all still yields a dialable url")
eq(sd.router_pod_from_api(router_pod, {}), nil,
    "router pod: no selector configured claims nothing")
eq(sd.router_pod_from_api(router_pod, { router_selector = sd.parse_selector("app=other") }),
    nil, "router pod: labels must match the router selector")
local no_ip = { metadata = { name = "r2", labels = { app = "lua-router" } },
                status = { phase = "Running" } }
eq(sd.router_pod_from_api(no_ip, rsel), nil, "router pod: no podIP, no member")
router_pod.metadata.deletionTimestamp = "2026-09-30T00:00:00Z"
eq(sd.router_pod_from_api(router_pod, rsel).deleting, true,
    "router pod: deletionTimestamp is carried for the retire branch")
router_pod.metadata.deletionTimestamp = nil
local bad_port = { metadata = { name = "r3", labels = { app = "lua-router" },
    annotations = { ["sglang.ai/mesh-port"] = "not-a-port" } },
    status = { phase = "Running", podIP = "10.0.1.3",
               conditions = { { type = "Ready", status = "True" } } } }
eq(sd.router_pod_from_api(bad_port, rsel).mesh_port, nil,
    "router pod: a junk annotation is not a port")
eq(sd.router_mesh_address(sd.router_pod_from_api(bad_port, rsel), 8080),
    "http://10.0.1.3:8080", "router pod: junk annotation falls back to the default port")
local other_ann = { metadata = { name = "r4", labels = { app = "lua-router" },
    annotations = { ["sglang.ai/ha-port"] = "9100" } },
    status = { phase = "Running", podIP = "10.0.1.4",
               conditions = { { type = "Ready", status = "True" } } } }
eq(sd.router_pod_from_api(other_ann, rsel).mesh_port, nil,
    "router pod: the ha-port spelling is not read by default")
eq(sd.router_pod_from_api(other_ann, { router_selector = rsel.router_selector,
    router_mesh_port_annotation = "sglang.ai/ha-port" }).mesh_port, 9100,
    "router pod: SMG_ROUTER_MESH_PORT_ANNOTATION switches the spelling")

--------------------------------------------------------------------------
new_case("apply_watch_event (incremental tracked-set maintenance)")
--------------------------------------------------------------------------
local opts1 = { selector = sd.parse_selector("app=sglang") }
local tracked = {}
check(sd.apply_watch_event(tracked, "ADDED", pod_ok, opts1) == true,
    "watch event: ADDED tracks the pod")
eq(count(tracked), 1, "watch event: one entry after ADDED")
check(sd.apply_watch_event(tracked, "ADDED", pod_ok, opts1) == true,
    "watch event: a repeat ADDED is not an error (idempotent content)")
local pod_notready = { metadata = { name = "sglang-0", labels = { app = "sglang" } },
    status = { phase = "Running", podIP = "10.0.0.1",
               conditions = { { type = "Ready", status = "False" } } } }
check(sd.apply_watch_event(tracked, "MODIFIED", pod_notready, opts1) == true,
    "watch event: MODIFIED replaces the entry")
eq(tracked["sglang-0"].is_ready, false,
    "watch event: an unready pod stays tracked (it exists; the reconcile drops the worker)")
local pod_relabelled = { metadata = { name = "sglang-0", labels = { app = "other" } },
    status = { phase = "Running", podIP = "10.0.0.1",
               conditions = { { type = "Ready", status = "True" } } } }
check(sd.apply_watch_event(tracked, "MODIFIED", pod_relabelled, opts1) == true,
    "watch event: labels stop matching -> the pod is dropped from the set")
eq(count(tracked), 0, "watch event: unclaimed pod removed")
check(sd.apply_watch_event(tracked, "MODIFIED", pod_relabelled, opts1) == false,
    "watch event: dropping an untracked pod changes nothing")
check(sd.apply_watch_event(tracked, "DELETED", pod_ok, opts1) == false,
    "watch event: DELETED for an unknown pod is a no-op")
sd.apply_watch_event(tracked, "ADDED", pod_ok, opts1)
check(sd.apply_watch_event(tracked, "DELETED", pod_ok, opts1) == true,
    "watch event: DELETED removes the pod")
eq(count(tracked), 0, "watch event: set empty after DELETED")
check(sd.apply_watch_event(tracked, "BOOKMARK", { metadata = { name = "x" } }, opts1) == false,
    "watch event: BOOKMARK carries no pod change")
check(sd.apply_watch_event(tracked, "ERROR", nil, opts1) == false,
    "watch event: ERROR carries no pod and changes nothing")
check(sd.apply_watch_event(tracked, "ADDED", { metadata = {} }, opts1) == false,
    "watch event: an object without a name cannot be tracked")
eq(sd.event_resource_version({ metadata = { resourceVersion = "1002" } }), "1002",
    "resource version: string carried")
eq(sd.event_resource_version({ metadata = { resourceVersion = 42 } }), "42",
    "resource version: number stringified (the API server sends strings; a decoder "
    .. "that widens them must still produce a comparable value)")
eq(sd.event_resource_version({ metadata = {} }), nil, "resource version: absent -> nil")
eq(sd.event_resource_version(nil), nil, "resource version: no object -> nil")
eq(count(sd.tracked_infos({ a = { name = "a" }, b = { name = "b" } })), 2,
    "tracked_infos: map becomes a list")
eq(count(sd.tracked_infos(nil)), 0, "tracked_infos: nil -> empty")

--------------------------------------------------------------------------
new_case("stream_opts (poll options plus the field selector)")
--------------------------------------------------------------------------
local so, s_text, f_text = sd.stream_opts({ discovery_selector = "app=sglang",
    field_selector = "metadata.name=sglang-0" })
eq(s_text, "app=sglang", "stream_opts: label selector text unchanged")
eq(f_text, "metadata.name=sglang-0", "stream_opts: field selector text emitted")
eq(#so.field_selector, 1, "stream_opts: field terms parsed for the client-side recheck")
eq(count(so.router_selector), 0, "stream_opts: no router selector by default")
so, s_text, f_text = sd.stream_opts({ discovery_selector = "app=sglang" })
eq(f_text, "", "stream_opts: no field selector -> empty text (no parameter sent)")
so = sd.stream_opts({ discovery_selector = "app=sglang", router_selector = "app=lua-router" })
eq(count(so.router_selector), 1, "stream_opts: router selector parsed")

--------------------------------------------------------------------------
new_case("mesh adopt / retire / suspect (router-pod membership)")
--------------------------------------------------------------------------
-- The mesh module is pure Lua until start() / http_request(), so the membership
-- writes can be checked without a container.
local mesh = require "resty.luarouter.mesh"
local cjson = require "cjson.safe"
local function ha_doc(m)
    local out = m:ha_status(nil)
    -- Outside a request phase the handler returns a table instead of writing the
    -- response itself (mesh.can_write_response), which is what makes it testable.
    if type(out) == "string" then
        return nil
    end
    return cjson.decode(out.body)
end

-- SMG_MESH_PEERS with only this instance in it is the shape init.lua produces for
-- a node that has no static peers: the instance exists, start() refuses, and the
-- first discovered pod has to be what gets the timer going.
local mm = mesh.new({ self_addr = "http://127.0.0.1:9001",
                      peers = { "http://127.0.0.1:9001" },
                      now = (function() local t = 1000
                          return function() t = t + 1 return t end end)() })
eq(count(mm.store.members), 1,
    "mesh: a peers list containing only self leaves exactly one member")
check(mm:start() == false, "mesh: nothing starts before a peer exists")
-- (In a container the refusal is "no mesh peers"; under bare luajit it is the
-- missing ngx.timer, which is checked first. Both mean the same thing here.)
check(mm.started == false, "mesh: the sync timer is not marked running")

local changed, why = mm:adopt_member("lua-router-b", "http://127.0.0.2:9002")
check(changed == true, "mesh: discovering a peer is a change")
check(why == nil, "mesh: a successful adopt reports no reason")
eq(mm.store.members["lua-router-b"].value.status, mesh.STATUS_ALIVE,
    "mesh: a discovered peer is alive")
eq(mm.store.members["lua-router-b"].value.address, "http://127.0.0.2:9002",
    "mesh: the discovered address is stored")
eq(count(mm:peer_bases()), 1, "mesh: the discovered peer becomes a sync target")
eq(mm:peer_bases()[1], "http://127.0.0.2:9002", "mesh: sync targets the discovered address")

local before = mm.store.members["lua-router-b"].version
changed, why = mm:adopt_member("lua-router-b", "http://127.0.0.2:9002")
check(changed == false and why == "unchanged",
    "mesh: re-adopting the same address is not a write (a poll would otherwise bump "
    .. "the version every interval and thrash LWW)")
eq(mm.store.members["lua-router-b"].version, before,
    "mesh: the version is untouched by a no-op adopt")

changed, why = mm:adopt_member("lua-router-self", "http://127.0.0.1:9001")
check(changed == false and why == "self",
    "mesh: this instance's own pod never becomes a peer of itself")
eq(count(mm.store.members), 2, "mesh: no extra member created for self")
eq(mm:adopt_member("lua-router-x", ""), false, "mesh: an address-less pod is not adopted")
-- Self-detection is textual (hostport equality), so "http://localhost:<same port>"
-- is NOT recognised as this node. Documented as a limit rather than asserted as
-- behaviour: SMG_MESH_SELF has to be spelled the way the pod reports its own IP,
-- which it is because both come from status.podIP.
check(mm:adopt_member("lua-router-localhost", "http://localhost:9001") == true,
    "mesh: a different spelling of self is treated as another node (limit)")
eq(mm:adopt_member("", "http://127.0.0.5:9005"), false, "mesh: an unnamed pod is not adopted")

-- A changed address for a known name is a write, and the peer list follows it.
check(mm:adopt_member("lua-router-b", "http://127.0.0.9:9009") == true,
    "mesh: a pod that moved gets a new address")
eq(mm.store.members["lua-router-b"].value.address, "http://127.0.0.9:9009",
    "mesh: the address is replaced rather than duplicated")
eq(mm.store.members["lua-router-b"].value.status, mesh.STATUS_ALIVE,
    "mesh: an address change re-marks the peer alive")
check(mm.store.members["lua-router-b"].version > before,
    "mesh: a real change bumps the version")

check(mm:retire_member("lua-router-b") == true, "mesh: retiring a known member is a change")
eq(mm.store.members["lua-router-b"].value.status, mesh.STATUS_DOWN,
    "mesh: retire marks down (Rust marks Down on deletionTimestamp)")
check(mm:retire_member("lua-router-b") == false, "mesh: retiring an already down member is quiet")
check(mm:retire_member("never-seen") == false, "mesh: retiring an unknown name changes nothing")
-- The record survives: the next sync has to be able to tell the peer it is down.
eq(count(mm.store.members), 3, "mesh: the downed member is kept, not deleted")

check(mm:suspect_member("nope") == false,
    "mesh: suspecting a never-seen pod creates no member (Rust only downgrades existing)")
mm:adopt_member("lua-router-c", "http://127.0.0.3:9003")
check(mm:suspect_member("lua-router-c") == true, "mesh: an alive member can be suspected")
eq(mm.store.members["lua-router-c"].value.status, mesh.STATUS_SUSPECT,
    "mesh: suspect is the status written")
check(mm:suspect_member("lua-router-c") == false, "mesh: an already suspect member is not rewritten")
check(mm:suspect_member("lua-router-b") == false,
    "mesh: down is terminal here (a poll must not resurrect it as suspect)")
-- An unready pod stays tracked by discovery and is retried every pass, so the
-- suspect write has to be the quiet kind: a no-op after the first.
check(mm:adopt_member("lua-router-c", "http://127.0.0.3:9003") == false,
    "mesh: suspect does not block a later adopt from being recognised as unchanged")

local body = ha_doc(mm)
eq(body.node_count, 4,
    "mesh: /ha/status counts self plus every discovered pod (self's localhost alias included)")
local down_seen = 0
for i = 1, #body.nodes do
    if body.nodes[i].status == "down" then down_seen = down_seen + 1 end
end
eq(down_seen, 1, "mesh: /ha/status shows the retired peer as down")
-- Two-node clusters stay "normal": min_cluster_size (3) is never met, so no
-- quorum judgement is made and traffic keeps flowing.
eq(body.partition, "normal",
    "mesh: a small dynamic cluster is never judged partitioned (min_cluster_size default 3)")

--------------------------------------------------------------------------
new_case("reconcile_infos (registry write path, stubbed)")
--------------------------------------------------------------------------
-- The watch loop calls the reconcile with a fresh {} per event, which is what a
-- nil counter increment used to blow up on: the worker was already removed when
-- the error was raised, so the registry and the deregistration metrics disagreed
-- and nothing downstream noticed. Stubbed registry/observability so the arithmetic
-- and the bookkeeping are exercised without ngx or a shared dict.
local removed_ids, added_urls = {}, {}
local counted = {}
local gauged = {}
package.loaded["resty.luarouter.registry"] = {
    discovery_records = function()
        return { { id = "id-old", url = "http://10.0.0.9:30000", discovery = "kubernetes" } }
    end,
    add = function(record)
        added_urls[#added_urls + 1] = record.url
        return { worker_id = "id-new" }, nil
    end,
    remove = function(id)
        removed_ids[#removed_ids + 1] = id
        return { worker_id = id, url = "http://10.0.0.9:30000" }, nil
    end,
}
package.loaded["resty.luarouter.observability"] = {
    counter = function(metric, pairs, delta)
        local out = { metric = metric }
        for i = 1, #(pairs or {}) do
            out[pairs[i][1]] = pairs[i][2]
        end
        counted[#counted + 1] = out
    end,
    gauge = function(metric, pairs, value)
        gauged[#gauged + 1] = { metric = metric, value = value }
    end,
}

local rcfg = { discovery_port = 30000, api_key = nil }
local rinfo = {
    name = "sglang-a", ip = "10.0.0.1", status = "Running", is_ready = true,
    labels = { app = "sglang" },
}
-- The empty-table call is the shape the watch loop uses. Before the fix this
-- raised "attempt to perform arithmetic on field 'removed'".
local rres = sd.reconcile_infos(rcfg, { pd_mode = false }, { rinfo }, {})
eq(type(rres), "table", "reconcile: a fresh {} is returned as the result")
eq(rres.listed, 1, "reconcile: listed counted")
eq(rres.added, 1, "reconcile: the new pod counted as added")
eq(rres.removed, 1, "reconcile: the stale pod counted as removed")
eq(rres.failed, 0, "reconcile: nothing failed")
eq(#added_urls, 1, "reconcile: one worker registered")
eq(added_urls[1], "http://10.0.0.1:30000", "reconcile: registered the pod url")
eq(#removed_ids, 1, "reconcile: one worker deregistered")
eq(removed_ids[1], "id-old", "reconcile: removed the stale registry id")

local dereg = 0
local reg_ok = 0
local gauge_seen = 0
for i = 1, #counted do
    if counted[i].metric == "smg_discovery_deregistrations_total" then
        dereg = dereg + 1
        eq(counted[i].reason, "pod_deleted", "reconcile: deregistration reason")
        eq(counted[i].source, "kubernetes", "reconcile: deregistration source")
    elseif counted[i].metric == "smg_discovery_registrations_total" then
        reg_ok = reg_ok + 1
        eq(counted[i].result, "success", "reconcile: registration counted as success")
    end
end
for i = 1, #gauged do
    if gauged[i].metric == "smg_discovery_workers_discovered" then
        gauge_seen = gauge_seen + 1
        eq(gauged[i].value, 1, "reconcile: the discovered gauge mirrors the pod set")
    end
end
eq(dereg, 1, "reconcile: the removal is exported (the bug left it at zero)")
eq(reg_ok, 1, "reconcile: the registration is exported")
eq(gauge_seen, 1, "reconcile: the gauge is written on every reconcile")

-- A result table that already carries counts (the poll path) is added to, not
-- reset: poll_once accumulates across a pass and reports the total.
local carried = sd.reconcile_infos(rcfg, { pd_mode = false }, { rinfo },
    { listed = 0, added = 4, removed = 2, failed = 1 })
eq(carried.added, 5, "reconcile: an existing result keeps its history (added)")
eq(carried.removed, 3, "reconcile: an existing result keeps its history (removed)")
eq(carried.failed, 1, "reconcile: a carried failure count survives")

-- Restore the real modules for anything loaded later in this process.
package.loaded["resty.luarouter.registry"] = nil
package.loaded["resty.luarouter.observability"] = nil

--------------------------------------------------------------------------
io.write("\n", passed, " passed, ", failed, " failed\n")
if failed > 0 then
    for i = 1, #failures do
        io.write("FAIL " .. failures[i] .. "\n")
    end
    os.exit(1)
end
