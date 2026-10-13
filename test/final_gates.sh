#!/usr/bin/env bash
# ============================================================================
# lua-router final gate - single entry point for the release check
# ============================================================================
# This file is two things:
#   1. the 22 gate BODIES (gate_build .. gate_e2e_tls_chain below), unchanged;
#   2. the CLI compat layer that forwards scheduling to test/gates/runner.py.
#
# Scheduling, locking, run identity, source freezing and result recording moved
# into the python package under test/gates/ (see the module docstrings):
#   catalog.py     the 22 gates: group (base/config/routing/observability/
#                  discovery/mesh/tls), tier, locks, dependencies, timeouts
#   locks.py       writer-preferring observation RW lock + build prepare lock
#   context.py     frozen source snapshot, fingerprints, image cache, run dirs
#   bodies.py      how a body is launched (re-entry into this script)
#   results.py     atomic per-gate JSON records + same-version aggregation
#   scheduler.py   dependency-aware pool; no phase barrier
#
# Usage (the historical surface is unchanged):
#   bash test/final_gates.sh                     # quick tier, default pool
#   GATE_TIER=full bash test/final_gates.sh      # all 22 gates
#   GATE_JOBS=1 bash test/final_gates.sh         # explicit serial, GATE_ORDER
#   GATE_JOBS=6 GATE_TIER=full bash ...          # pool width 6
#   GATE_GROUP=routing,mesh GATE_TIER=full ...   # group selection
#   GATE_DRY_RUN=1 GATE_TIER=full bash ...       # print the plan, run nothing
#   SKIP_ENV=mesh_http GATE_TIER=full bash ...   # skip named gates (recorded)
#   GATE_ONLY=unit bash test/final_gates.sh      # single gate (any tier)
#   KEEP_GOING=1 bash test/final_gates.sh        # accepted; now the behaviour
#   LR_GATE_LOG=/path/log bash ...               # merged log location
#   bash test/final_gates.sh prepare             # freeze + build, print manifest
#   bash test/final_gates.sh plan                # selection/group/lock plan
#
# Keep-going is unconditional now: the pool has no first failure to stop at, and
# every gate is recorded, so the report always states exactly what is red.
#
# Concurrency model (supersedes the old three-wave table):
#   GATE_JOBS is a pool width, default min(8, nproc). Gate membership is no
#   longer a hand-kept list: each gate declares LOCKS and DEPENDENCIES in
#   catalog.py and the scheduler honours them. conf/unit/contract/probes never
#   wait for build; the image-booting suites wait for the build GATE.
#   e2e_watcher takes NO lock at all: its docker.sock port-table snapshot used to
#   be the one thing that needed an exclusive machine window, and the snapshot now
#   ships test/integration/docker_test_proxy.py, which filters socket events to
#   this run's fixture containers while preserving the raw port fields, so the
#   suite no longer sees foreign publishes. Every HTTP gate shares the observation
#   window. mesh_two and
#   e2e_tls_chain joined the pool after an audit showed their serial reasons
#   were wall-clock fidelity, not machine-wide state: the Lua mesh is a static
#   peer list (no gossip discovery, so no foreign router can join a roster), and
#   the 31337 'listener' is an openresty -t config render that never binds. The
#   per-gate durations in the result JSON are how you check that claim here.
#
# There is deliberately no global 'one gate run at a time' flock any more. Runs
# are independent by construction: unique LR_RUN_ID, per-run log/tmp/result dirs,
# per-gate LR_GATE_TAG namespaces, and one machine-wide port ledger
# (/data/tmp/lr-gates/ports.reserved, flock'd, reclaimed by pid liveness). Two
# runs may overlap; the ledger is what makes that safe for loopback ports.
#
# Gate ids, in run order (SKIP_ENV takes a comma/space separated list of these):
#   build          docker build lua-router:integration (the e2e suites boot it)
#   conf           openresty -t on test/conf/nginx-lua-router.conf + conf/lua-router.conf
#   unit           tree / policies / hash / mesh (authz luajit)
#                  + tree / policies / hash / integration (apisix resty)
#   contract       test_lua_router.sh, strict (first FAIL aborts the suite)
#   probes         integration/probes.py (policy factory, knobs, re_split, json-edit)
#   e2e_stateful   integration/e2e_stateful.py
#   e2e_policies   integration/e2e_policies.py
#   e2e_ui_bridge  integration/e2e_ui_bridge.py
#   e2e_errors     integration/e2e_errors.py
#   e2e_effort     integration/e2e_effort.py
#   head_routes    integration/test_head_routes.py (HEAD mirror of the GET surface)
#   mesh_http      integration/test_mesh_http.py (mesh enabled over real HTTP)
#   e2e_policy_parity prefix_hash/bucket/power_of_two/random quantitative parity
#   e2e_token_accounting integration/e2e_token_accounting.py (usage injection+strip,
#                  token counters, 400-fallback sticky)
#   e2e_gpu_load   integration/e2e_gpu_load.py (metrics/prom load sources -> registry)
#   e2e_routing_dyn integration/e2e_routing_dyn.py (runtime policy switch, no restart)
#   e2e_watcher    integration/e2e_watcher.py (in-process watcher: targets/proc/docker
#                  discovery, 9 guards, model-map, restart rediscovery)
#   e2e_profiles   integration/e2e_profiles.py (virtual model profiles: alias worker
#                  whitelist, per-alias policy/effort, upstreams CRUD with remote
#                  api_key injection + masking (key tri-state, normalized-url
#                  dedup 400), LMR_UPSTREAMS_FILE boot seed, watcher immunity,
#                  LMR_CONFIG_FILE revival across a restart, the 30 s self-heal
#                  timer re-adding a hand-deleted config member, apply-document
#                  with all-or-nothing reject)
#   e2e_caps       integration/e2e_caps.py (the two worker-level capabilities:
#                  S1 a virtual alias bound to two instances of two *different*
#                  models under IGW=1 and IGW=0 (forwarded model == the bound
#                  name), plus candidates-intersect-legacy-workers (an added
#                  `workers` list can only narrow the bindings, never widen them:
#                  a whitelist that matches nothing must empty the candidate set to
#                  503 without leaking to a bound instance);
#                  S2 per-worker max_concurrency really excludes the saturated
#                  instance from the candidate array; S3 max_gpu_util excludes on the
#                  gpu_load per-card utilisation reading while a *missing* reading
#                  stays unknown = never excluded; the /metrics lr_gpu_load_util*
#                  family; S4 cache_aware affinity cannot carry a capped instance;
#                  S5 pool-full 503 keeps code no_available_workers with the cap
#                  count in the message; S7 a renamed config row stops routing the
#                  old name under IGW; S5c default-off pool behaviour unchanged)
#   e2e_models_advertisement integration/e2e_models_advertisement.py (/v1/models 的对外
#                  形状过一遍真 HTTP：S1 官方 required 四字段逐行齐（改动前真实模型那一支
#                  漏 created）；S2 采集链路把引擎自报的 capabilities/reasoning_efforts
#                  如实带出来，同一场景用两个不同的 context_length 跑两遍证明这个数不是
#                  网关造的；S3 缺数据=删键，不出现 null / [] / {}；S4 操作员 config 卡片
#                  压过引擎广告（引擎那个数整份响应里不许出现）；S5 全表 owned_by 恒
#                  lua-router（2026-10-11 裁定，不带目标名/整组名单）与组内聚合能力；
#                  S6 组内**有一台没给长度读数**时入口行必须删键
#                  （都有读数时照报最窄的对照断言与之成对，防修过头）。跑盘上 lualib，
#                  判别性通道 LR_LEGACY_LUALIB=<旧树>)
#   mesh_two       integration/test_mesh_two.py (two real routers: converge,
#                  18 s stability, stop/heal partition window, retire broadcast)
#   e2e_tls_chain  integration/e2e_tls_chain.py (server-side TLS: runtime-built
#                  root/intermediate/leaf PKI, chain completeness as served,
#                  expired / wrong-name / non-CA-issuer / self-signed refusals,
#                  RSA and ECDSA x TLSv1.2/1.3, SNI two names on one port)
#
# Tiers (GATE_TIER=quick|full, default quick):
#   quick = build conf unit contract probes — the fast-verifiable core
#           (~3 min). Enough for ordinary edits.
#   full  = all 22 gates (~12-17 min serial). Required for release builds,
#           README/handover count updates and production image replacement;
#           a quick-tier green log never counts as a full-green anchor.
#
# What skipping costs (read this before using SKIP_ENV):
#   build          e2e_* and mesh_http then run against a possibly stale image.
#   conf           nothing checks the two shipped configs still parse.
#   unit           the pure-Lua modules (tree/hash/policies/mesh) have no
#                  other gate — router.lua only
#                  exercises them through HTTP, so a regression can hide.
#   contract       the whole 650-check wire contract is unverified.
#   probes         the policy factory / config-knob / raw-JSON-editor probes.
#   e2e_*          that behaviour family over a real container.
#   e2e_watcher    the merged watcher (was a separate llm-watcher container):
#                  without it nothing proves discovery/guards/ledger work.
#   e2e_profiles   the virtual-model layer (doc/gap-virtual-models.md): the alias
#                  worker whitelist, per-alias policy/effort override, the upstreams
#                  declaration layer (remote api_key injection, the null-keeps/
#                  empty-clears write semantics, key never echoed), watcher immunity
#                  for discovery=config, and persistence through LMR_CONFIG_FILE
#                  (the only layer that survives a restart for config workers), the
#                  LMR_UPSTREAMS_FILE env layer, and the 30 s self-heal timer.
#   head_routes    the HEAD mirror (Rust axum answers HEAD on every GET route).
#   mesh_http      mesh enablement over real HTTP: peer apply/sync, worker
#                  mirror, /ha/policies, /_mesh/internal/{state,apply}.
#   mesh_two       two-real-router mesh convergence/hold/partition/heal/retire has no
#                  other gate: a fake peer cannot reproduce the seed-vs-self address spelling that
#                  produced the phantom member, so a roster regression would ship unnoticed.
#   e2e_tls_chain  server-side TLS has no other gate: whether the listener really
#                  ships an intermediate (a leaf-only cert passes `openresty -t`
#                  and fails every real client), whether the four broken-PKI shapes
#                  are refused for the right reason without taking the router down,
#                  RSA/ECDSA x TLSv1.2/1.3 suites, and SNI certificate selection.
# Skipping is only legitimate when the gate is known-blocked by an unrelated
# change; the run log records every skip so a green run cannot silently shrink.
#
# Requirements: docker (+ authz:latest and apache/apisix:3.11.0-debian; the gate
# image is built by the build GATE from the frozen snapshot and tagged
# lua-router:gate-<fingerprint>, never a shared mutable tag), curl, jq, python3.
# test/local.env is still sourced for local overrides (none are required by the
# shipped gates).
#
# Overlapping runs are allowed: there is no global run lock, and two runs are
# independent because each has its own run id, snapshot, log/result/tmp dirs and
# per-gate namespaces, sharing only the machine-wide port ledger. Sharing the
# box is still not free -- every container suite wants docker and CPU, so a very
# large GATE_JOBS buys nothing past saturation, and the observation lock makes
# e2e_watcher's machine scan wait for the pool rather than race it.
#
# Prepared artifacts (all under /data/tmp/lr-gates/):
#   snapshots/<fingerprint>/   frozen tree the gates actually mount
#   images/<fingerprint>.json  fingerprint -> immutable image id
#   runs/<run-id>/             logs/, results/<gate>.json, manifest.json,
#                              report.json, gates.log (the merged log)
#   ports.reserved             the shared loopback ledger (see _lib.py,
#                              port_allocator.py: same rows, same flock rules)
# Modes:
#   plan                        print the selection/group/lock/deps plan
#   prepare                     freeze + build now, write a manifest to reuse
#   run (default)               freeze, schedule, record, aggregate
#   --aggregate --manifest M --results "dirA dirB" [--gates "..."]
#                               decide several runs at once: same-version rules
#                               apply, so an aggregate is only as trustworthy as
#                               the manifests you pass it

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# optional untracked local overrides (see test/local.env.example)
[ -f "$SCRIPT_DIR/local.env" ] && . "$SCRIPT_DIR/local.env"
LUA_ROUTER=$(cd "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$LUA_ROUTER   # standalone repo: repo root == this dir
AUTHZ_IMAGE=${OPENRESTY_TEST_IMAGE:-authz:latest}
RESTY_IMAGE=${LR_RESTY_IMAGE:-apache/apisix:3.11.0-debian}
E2E_IMAGE=${LR_IMAGE:-lua-router:integration}

case "${1:-}" in
    --help|-h)
        sed -n "1,100p" "${BASH_SOURCE[0]}"
        exit 0 ;;
    --gate-body)
        ;;                                   # handled after the gate bodies load
    plan|prepare|run|aggregate)
        exec python3 "$SCRIPT_DIR/gates/runner.py" "$1" "${@:2}" ;;
    --plan|--prepare|--run|--aggregate)
        # flag form: the flag is the mode, the rest belongs to the runner, so
        # --aggregate --manifest M --results "dir1 dir2" reaches argparse intact
        mode="${1#--}"; shift
        exec python3 "$SCRIPT_DIR/gates/runner.py" "$mode" "$@" ;;
esac

# ------------------------------------------------------------------ gate bodies
# The 22 bodies below are the historical release checks, unchanged: they are what
# a green anchor certifies. The runner launches each through --gate-body, with
# this script resolved from inside the frozen snapshot, so REPO_ROOT points at
# the snapshot and every -v "$REPO_ROOT:/repo" mount, every python3
# test/integration/*.py and every luajit unit run reads frozen bytes - not the
# live worktree a parallel agent may be editing underneath.

# Group selection over the shared unit gate: LR_GATE_UI_ONLY=1 (set by the
# runner when the selection is exactly group=ui) narrows gate_unit to the node
# UI badge test and turns gate_contract into a recorded skip. A group filter has
# to be real: 'ui' must not silently run the whole luajit/resty/contract tree.
unit_subset() {
    local all=(test_tree test_tree_bounds test_state_bounds test_observability test_policies test_hash test_mesh test_watcher test_gpu_load test_routing_dyn test_profiles test_caps_persist test_caps_routing test_models_shape test_models_advertise test_effort_layers test_admin_auth)
    if [[ "${LR_GATE_UI_ONLY:-0}" == "1" ]]; then
        printf '%s\n' test_ui_merge.mjs
    else
        printf '%s\n' "${all[@]}"
    fi
}
ui_only_skip() {
    if [[ "${LR_GATE_UI_ONLY:-0}" == "1" ]]; then
        printf 'UI-only selection: %s not part of the ui group; recorded as a skip by the runner\n' "$1"
        exit 5
    fi
}
gate_build() {
    # The base comes from the FROZEN MANIFEST, never from the Dockerfile's
    # mutable FROM tag: a plain 'docker build -f Dockerfile' resolves
    # authz:latest at build time, so a base retagged between freeze and build
    # builds on the new image while the run's manifest reports the old one --
    # the build gate would certify an identity the registry disproves, and the
    # on_build backfill now refuses exactly that (it checks the registry's base
    # evidence, not a self-declared field).
    # The context module owns the CLI: 'build --manifest PATH' runs
    # build_for_manifest -- registry-first under the cache-key lock, FROM pinned
    # to a private tag bound to the manifest's build_base_id -- prints the
    # identity json and exits 0. LR_GATE_MANIFEST is the manifest the
    # RunContext wrote atomically at run start (ctx.manifest_path).
    # No LR_GATE_MANIFEST = a standalone direct run: nothing froze this tree, so
    # there is no pinned base to honour and the historical plain build stands.
    if [[ -n "${LR_GATE_MANIFEST:-}" && -f "${LR_GATE_MANIFEST}" ]]; then
        ( cd "$REPO_ROOT" && python3 test/gates/context.py build --manifest "$LR_GATE_MANIFEST" )
        return $?
    fi
    ( cd "$REPO_ROOT" && docker build -t "$E2E_IMAGE" -f Dockerfile . )
}

run_conf_gate() {
    local conf=$1
    ( cd "$REPO_ROOT" && docker run --rm -v "$REPO_ROOT:/repo:ro" --entrypoint openresty \
        "$AUTHZ_IMAGE" -t -p /usr/local/openresty/nginx/ -c "/repo/$conf" )
}

gate_conf() {
    run_conf_gate test/conf/nginx-lua-router.conf || return 1
    run_conf_gate conf/lua-router.conf || return 1
}

# luajit口径 (authz image): pure-Lua modules, run as a script so package.path
# comes from the file itself (LUA_TEST_LIB pins the lualib root).
run_unit_luajit() {
    local t=$1
    ( cd "$REPO_ROOT" && timeout 300 docker run --rm -v "$REPO_ROOT:/repo:ro" \
        -w /repo --entrypoint /usr/local/openresty/luajit/bin/luajit \
        -e LUA_TEST_LIB=/repo/lualib "$AUTHZ_IMAGE" \
        "/repo/test/unit/$t.lua" )
}

# resty口径 (apisix image): needs ngx, so the file is dofile'd from -e.
run_unit_resty() {
    local t=$1
    ( cd "$REPO_ROOT" && timeout 300 docker run --rm -v "$REPO_ROOT:/repo:ro" \
        -w /repo --entrypoint /usr/bin/resty "$RESTY_IMAGE" \
        -e "package.path='/repo/lualib/?.lua;'..package.path
            dofile('/repo/test/unit/$t.lua')" )
}

# node口径 (host node, no container): 只跑 ui/admin 的纯函数单测 —— 无端口、无 shdict、
# 不碰任何容器名册，与其余 unit 同档串行也不会踩到别的门。宿主没有 node 时如实打一行
# NOT RUN 并返回 0：本仓门禁此前对宿主 node 零依赖，不该由一枚徽章测试把它升级成硬
# 依赖；但「没跑」必须看得见，不许被读成绿。
run_unit_node() {
    local t=$1
    if ! command -v node >/dev/null 2>&1; then
        printf '!! host node missing: %s NOT RUN (recorded, not a green)\n' "$t" >&2
        return 0
    fi
    ( cd "$REPO_ROOT" && timeout 120 node "test/unit/$t" )
}

gate_unit() {
    # UI-only selection (LR_GATE_UI_ONLY=1, set by the runner when the selection
    # is exactly group=ui): run the node UI badge test and nothing else. The
    # luajit/resty lists and the contract gate belong to other groups, and a
    # group filter has to be real - the ui group must not quietly run the tree.
    local rc=0 t
    if [[ "${LR_GATE_UI_ONLY:-0}" == "1" ]]; then
        printf '\n-- node test_ui_merge (ui-only subset)\n'
        run_unit_node test_ui_merge.mjs || rc=1
        return "$rc"
    fi
    # test_caps_routing：并发/利用率上限与 candidates 交集的纯 luajit 单测（无端口，
    # 与其余 luajit 组同档）；它钉的判定在 router.lua/registry.lua 里，HTTP 面只有
    # e2e_caps 一份门禁，二者缺一就会漏掉"上限写成排序项"这类回归。
    # test_models_shape：/v1/models 对外形状的纯 luajit 单测（切真源码配桩，无端口）。
    # 它钉输出层的纪律，e2e_models_advertisement 钉采集链路过真 HTTP；两者覆盖面不同
    # （单测能造"上游只说了一半""脏读数""组内口径不一致"这些真 HTTP 里造不出来的形状，
    # e2e 才能证明探针真的调了归一化层）。
    # test_models_advertise：/v1/models「只广告虚拟入口」开关判定层的纯 luajit 单测
    # （无端口，与其余 luajit 组同档）。e2e_models_advertisement 只能从 HTTP 外面看「广告了
    # 哪几行」，证不了开关内部三条纪律：truthy 是「认识才算开」（写错的字符串要退回缺省全量
    # 广告，而不是把硬规则 9 第三条的老契约整页翻掉）、磁盘读数与 env 读数是优先级而不是 OR
    # （nil 与 false 必须分家，否则 env 层永远读不到）、only_data 拿不到入口时返回 nil（退回
    # 全量）而不是空表（交空列表）。后两条在 HTTP 面上长得一模一样，只有把源码切出来才分得开；
    # 返回形状写反 = 静默清空整个广告面。
    # test_effort_layers：effort 三层继承（模型卡片 -> 虚拟条目 -> 全局）语义与接线的纯
    # luajit 单测（切 router.lua 真实现配桩、config_store 用盘上真模块，无端口）。这条链的
    # 错误形状是静默的——操作员在全局页填的映射被一张只管 ctx 的卡片悄悄屏蔽，转发体只是少改
    # 一个键，没有任何日志会喊，所以 e2e_effort 那份过真 HTTP 的门禁也不足以替代它（它钉的是
    # 「逐 from 问三层、第一个给值的层赢」这条查表口径本身，以及条目层读数确实被喂进了转发链）。
    # 两份的判别性通道（LR_MODELS_TEST_LEGACY_SRC / LR_EFFORT_LEGACY_LUALIB）刻意不在门禁里
    # 设：那是手工核实「断言真会红」的反证手段，需要外挂改动前的旧源码树，门禁只跑 HEAD。
    # test_tree_bounds / test_state_bounds / test_observability：单 worker 空载烧核与进程内
    # 累积状态的三条闸门（doc/gap-cpu-idle-burn.md）。它们钉的都是「以前只会涨、现在必须
    # 能降」的形状 —— 亲和树的节点上界与增量预算、_M.instances 的空闲回收、lr_stats 的
    # model 标签基数与导出扫描上限 —— 回归时不会有任何 HTTP 面症状，只有这些断言会红。
    # test_tree_bounds 单列而不并进 test_tree：后者是对齐 Rust 的语义基线，新增维度是
    # Lua 侧的超集，分文件才看得清哪条断言属于哪一边。
    # test_caps_persist：控制面（PUT/POST /workers）设的三档上限经声明层镜像持久化
    # 的判定层单测（用户裁定 2026-10-09，doc/gap-worker-caps.md §4）。它钉的四件事在
    # HTTP 面上都看不到症状 —— 镜像行的 建/改/清/删、「默认值=没说」这条能扛住
    # snapshot 往返的认得判据、孤儿镜像不被 reconcile 建成 config 行、删 worker 连带
    # 清除。e2e_caps S9 钉的是端到端那一半（真 docker restart 后上限真的挡流量）。
    for t in test_tree test_tree_bounds test_state_bounds test_observability test_policies test_hash test_mesh test_watcher test_gpu_load test_routing_dyn test_profiles test_caps_persist test_caps_routing test_models_shape test_models_advertise test_effort_layers test_admin_auth; do
        printf '\n-- luajit %s\n' "$t"
        run_unit_luajit "$t" || rc=1
    done
    for t in test_tree test_policies test_hash test_integration; do
        printf '\n-- resty %s\n' "$t"
        run_unit_resty "$t" || rc=1
    done
    # test_ui_merge：服务池页 mergeRows 的徽章归属判定（node、无端口、无容器）。合并逻辑
    # 此前只有开发期自查脚本覆盖（doc/gap-pool-merge.md §6 第 3 条）；徽章判错的形状是安静的
    # —— 把已经生效的上限读成失效配置，HTTP 面没有任何症状，只能钉纯函数。
    printf '\n-- node test_ui_merge\n'
    run_unit_node test_ui_merge.mjs || rc=1
    # test_gate_runner.py: the release runner's own self-test, against a fake
    # gate backend (no docker, no HTTP, no ports), so it can join the unit gate
    # without changing what any other unit run observes. It pins the scheduling
    # contract this script now depends on: selection and group filters, the
    # dependency edges that replace the old wave barrier, the observation lock
    # (shared for HTTP gates, exclusive for the watcher), per-run namespaces,
    # and the result rules - a missing record is a crash, a red body is never
    # rescued by its marker, a foreign fingerprint/image id is refused, and a
    # targeted run may not claim a full anchor.
    printf '\n-- python3 test_gate_runner.py (gate runner self-test)\n'
    ( cd "$REPO_ROOT" && timeout 300 python3 test/test_gate_runner.py ) || rc=1
    # The two runner-module self-tests that live in their own files, for the two
    # modules the scheduler cannot certify alone: results.py (coverage/scope rules
    # - a UI-node pass is not full unit coverage, a subset selection can never be
    # a full anchor, duplicate full-scope passes dedup but a fail is never
    # overwritten by a later pass) and context.py (the snapshot publish race, the
    # (fingerprint, authz base id) image-cache key, manifest validation). They are
    # pure python - fake docker, no ports, no HTTP - so they run in-process like
    # test_gate_runner.py.
    #
    # Missing file is a RED unit gate, not a skip: these files are part of the
    # harness tree, and a gate that quietly passes when its self-test vanished
    # would certify a runner nobody tested. The unit gate must not be the place
    # where an absent harness test reads as green.
    for t in test_gate_results test_gate_context; do
        if [[ ! -f "$REPO_ROOT/test/$t.py" ]]; then
            printf '!! test/%s.py missing: unit gate is RED, not skipped\n' "$t" >&2
            rc=1
            continue
        fi
        printf '\n-- python3 %s.py (runner module self-test)\n' "$t"
        ( cd "$REPO_ROOT" && timeout 300 python3 "test/$t.py" ) || rc=1
    done
    return "$rc"
}

gate_contract() {
    # Under UI-only group selection the wire contract is outside the selected subset.
    # rc=5 is a recorded SKIP, not a green contract result.
    if [[ "${LR_GATE_UI_ONLY:-0}" == "1" ]]; then
        printf 'ui-only selection: contract belongs to base, not ui\n'
        exit 5
    fi
    ( cd "$REPO_ROOT" && timeout 2400 bash test/test_lua_router.sh )
}

run_integration() {
    local f=$1 timeout_s=${2:-2400}
    ( cd "$REPO_ROOT" && timeout "$timeout_s" python3 "test/integration/$f" )
}

gate_probes()        { run_integration probes.py; }
gate_e2e_stateful()  { run_integration e2e_stateful.py; }
gate_e2e_policies()  { run_integration e2e_policies.py; }
gate_e2e_ui_bridge() { run_integration e2e_ui_bridge.py; }
gate_e2e_errors()    { run_integration e2e_errors.py; }
gate_e2e_effort()    { run_integration e2e_effort.py; }
gate_head_routes()   { run_integration test_head_routes.py 900; }
gate_mesh_http()     { run_integration test_mesh_http.py 900; }
gate_e2e_policy_parity() { run_integration e2e_policy_parity.py 1800; }
gate_e2e_watcher()    { run_integration e2e_watcher.py 900; }
gate_e2e_profiles()   { run_integration e2e_profiles.py 1500; }
# 与 e2e_profiles 相邻：同样依赖 virtual_models/profiles 形状（candidates 绑定/交集
# 走的是同一套 config_store 校验与 candidates_for 过滤）。
gate_e2e_caps()       { run_integration e2e_caps.py 900; }
gate_e2e_models_advertisement() { run_integration e2e_models_advertisement.py 900; }
gate_e2e_token_accounting() { run_integration e2e_token_accounting.py 900; }
gate_e2e_gpu_load()    { run_integration e2e_gpu_load.py 900; }
gate_e2e_routing_dyn() { run_integration e2e_routing_dyn.py 900; }
gate_mesh_two()        { run_integration test_mesh_two.py 900; }
gate_e2e_tls_chain()   { run_integration e2e_tls_chain.py 1500; }

# ------------------------------------------------------------------ body mode
# --gate-body NAME: the runner's per-gate re-entry point. Runs exactly one gate
# body, writing to stdout/stderr for the runner to capture, and publishes the
# result marker. Exit 0 WITHOUT the marker is recorded as crash: a body killed
# by a signal, or one whose tail was bypassed, must not be able to read green.
if [[ "${1:-}" == "--gate-body" ]]; then
    gate_name=${2:-}
    gate_fn="gate_${gate_name}"
    if ! declare -F "$gate_fn" >/dev/null; then
        printf 'gate body: unknown gate %s\n' "$gate_name" >&2
        exit 2
    fi
    "$gate_fn"
    gate_rc=$?
    if [[ "$gate_rc" == "0" && -n "${LR_GATE_RESULT:-}" ]]; then
        : >"$LR_GATE_RESULT"
    fi
    exit "$gate_rc"
fi

exec python3 "$SCRIPT_DIR/gates/runner.py" run "$@"
