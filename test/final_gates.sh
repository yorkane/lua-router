#!/usr/bin/env bash
# ============================================================================
# lua-router final gate — one serial command for the whole release check
# ============================================================================
#仓库化的最终门禁（取代 /data/tmp/lr-core2/final_gates.sh 那个一次性脚本）。
# 与旧脚本的差异：补齐了 probes.py、e2e_errors.py、e2e_effort.py、
# 未接线模块的单测（mesh）以及新增的两个
# HTTP 面集成测试（test_head_routes.py、test_mesh_http.py），并改成
# 首个失败即退出。
#
# Usage:
#   bash test/final_gates.sh                    # quick tier (default, ~3 min)
#   GATE_TIER=full bash test/final_gates.sh     # all 21 gates (release/count/
#                                               # pre-production changes)
#   SKIP_ENV=mesh_http GATE_TIER=full bash ...  # skip named gates (recorded)
#   GATE_ONLY=unit bash test/final_gates.sh     # single gate (any tier)
#   KEEP_GOING=1 bash test/final_gates.sh       # run all selected, count fails
#   LR_GATE_LOG=/path/log bash ...              # log location
#   GATE_JOBS=4 bash test/final_gates.sh        # run the safe gates in parallel
#   GATE_DRY_RUN=1 GATE_TIER=full bash ...      # print the plan, run nothing
#
# Concurrency (GATE_JOBS, default 1 = the historical serial run):
#   GATE_JOBS>1 only parallelises gates that passed the machine-state audit in the
#   PHASE comments below. Membership is not a knob: GATE_JOBS=8 cannot promote a
#   gate that reads machine-wide state into the pool.
#   A parallel run implies keep-going: every selected gate runs, the exit code is
#   1 if any one of them is red, and each red gate prints its own 25 tail lines.
#   Two gate RUNS at once are refused by an flock, so a parallel run can never
#   overlap another run whether that one is parallel or serial.
#
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
#                  压过引擎广告（引擎那个数整份响应里不许出现）；S5 虚拟入口的 owned_by
#                  老口径与组内聚合能力；S6 组内**有一台没给长度读数**时入口行必须删键
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
#   full  = all 21 gates (~12-17 min serial). Required for release builds,
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
# Requirements: docker (+ authz:latest, apache/apisix:3.11.0-debian, and the
# built lua-router:integration), curl, jq and python3. test/local.env is still
# sourced for local overrides (none are required by the shipped gates).
# Only ever run one copy at a time: a second invocation exits 3 while the first
# holds /data/tmp/lr-gates/.gates.lock. GATE_JOBS parallelises gates INSIDE one
# run; it is not a licence to start two runs, and it does not make the suites
# cheaper to share the box with -- each container suite still wants docker and
# CPU, so a very large GATE_JOBS buys nothing past the point of saturation.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# optional untracked local overrides (see test/local.env.example)
[ -f "$SCRIPT_DIR/local.env" ] && . "$SCRIPT_DIR/local.env"
LUA_ROUTER=$(cd "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$LUA_ROUTER   # standalone repo: repo root == this dir
AUTHZ_IMAGE=${OPENRESTY_TEST_IMAGE:-authz:latest}
RESTY_IMAGE=${LR_RESTY_IMAGE:-apache/apisix:3.11.0-debian}
E2E_IMAGE=${LR_IMAGE:-lua-router:integration}
STAMP=$(date -u +%Y%m%d-%H%M%S)
LOG_DIR=${LR_GATE_LOG_DIR:-/data/tmp/lr-gates}
LOG=${LR_GATE_LOG:-$LOG_DIR/gates-$STAMP.log}
KEEP_GOING=${KEEP_GOING:-0}
GATE_ONLY=${GATE_ONLY:-}
mkdir -p "$LOG_DIR"
# LR_GATE_LOG may name a path outside LOG_DIR (the original script derived the
# default log from LR_GATE_LOG_DIR, so the two could disagree). Create the
# directory of the file actually used, or every gate dies on the redirect.
mkdir -p "$(dirname "$LOG")"

# ------------------------------------------------------------------ concurrency
# GATE_JOBS>1 turns the serial run into a worker pool over PARALLEL_GATES, with
# WAVE_PRE before it and WAVE_TAIL strictly after it. Only the pool is concurrent;
# the split is what keeps the machine-wide readers (the docker.sock port snapshot,
# the mesh roster, a fixed listener) from observing another gate containers.
GATE_JOBS=${GATE_JOBS:-1}
GATE_DRY_RUN=${GATE_DRY_RUN:-0}
if ! [[ "$GATE_JOBS" =~ ^[0-9]+$ ]] || [[ "$GATE_JOBS" -lt 1 ]]; then
    printf "GATE_JOBS must be a positive integer (got: %s)\n" "$GATE_JOBS" >&2
    exit 2
fi

# The run is split into three phases; only phases 1 and 2 are pools, and
# membership is decided by what a gate reads from the machine, never by how
# long it takes.
#
# PHASE 1 (pool) -- these four may share the pool because between them only
# contract ever binds a host port:
#   build            writes lua-router:integration; the other three read only
#                    the two pre-existing images (authz:latest, apisix), so no
#                    tag is produced and consumed inside the same phase. It
#                    sits here, not in phase 2, because every e2e suite boots
#                    the image it writes.
#   conf             docker run --rm, no --network host, no published port.
#   unit             luajit/resty --rm runs, no network at all.
#   contract         carries the caveat that shapes phase 1: it publishes host
#                    ports picked by its OWN free_port() (test_lua_router.sh:194,
#                    a plain bind(0)) which does not consult the shared reserve
#                    file. It is safe only beside gates that bind no host port,
#                    and these three do. Put any phase-2 gate next to it and the
#                    suite dies on "container failed to start" for a reason that
#                    has nothing to do with the code under test.
#
# PHASE 2 (pool) -- every gate here takes its host port from
# _lib.free_port(), which reserves numbers across processes through a shared
# file, and pins SMG_METRICS_PORT=0 so the 29000 scrape listener never competes.
#
# PHASE 3 (serial, one at a time) -- each of these reads state that belongs to
# the whole machine, so they may not even overlap each other:
#   e2e_watcher      snapshots "docker ps --format {{.Ports}}" to build its
#                    SMG_WATCHER_EXCLUDE list (e2e_watcher.py:501 and :732) and
#                    mounts /var/run/docker.sock. A container another gate
#                    starts after that snapshot is an unaccounted published port,
#                    so its "exactly one worker" assertions fail for an unrelated
#                    reason.
#   mesh_two         asserts the mesh roster across an 18 s stability window and
#                    a stop/heal partition window (test_mesh_two.py:132-137);
#                    roster timing only means anything with no other router
#                    answering on the box LAN address.
#   e2e_tls_chain    names one fixed listener (31337, e2e_tls_chain.py:942) and
#                    checks SNI selection on it, so nothing else may be binding
#                    near that range while it runs.
WAVE_PRE=(build conf unit contract)
WAVE_TAIL=(e2e_watcher mesh_two e2e_tls_chain)

# Parallel-safe pool (phase 2).
# Every gate below takes its host port from _lib.free_port(), which now reserves
# numbers across processes through the shared $RESULT_DIR/ports.reserved file, and
# pins SMG_METRICS_PORT=0 so the 29000 scrape listener never competes. The mock
# workers bind ports the same way, and their logs live under $TMP keyed by port.
PARALLEL_GATES=(probes e2e_stateful e2e_policies e2e_ui_bridge
                e2e_errors e2e_effort head_routes mesh_http e2e_policy_parity
                e2e_token_accounting e2e_gpu_load e2e_routing_dyn e2e_profiles
                e2e_caps e2e_models_advertisement)

# Fail closed, and only sound because it runs after GATE_ORDER is defined (see
# the call site below): an
# unclassified gate is a hard error rather than a silent fall-through to serial.
check_gate_classification() {
    local _g _h _seen
    for _g in "${GATE_ORDER[@]}"; do
        _seen=0
        for _h in "${WAVE_PRE[@]}" "${PARALLEL_GATES[@]}" "${WAVE_TAIL[@]}"; do
            [[ "$_h" == "$_g" ]] && _seen=1
        done
        if [[ "$_seen" != "1" ]]; then
            printf "gate %s is not classified as parallel or exclusive\n" "$_g" >&2
            exit 2
        fi
    done
}

parallel_active() {
    if [[ "$GATE_JOBS" -gt 1 && -z "$GATE_ONLY" ]]; then return 0; fi
    return 1
}

# A pool has no "first failure" to stop at, so the parallel run always keeps
# going and lets summary decide the exit code. Set here, before the log header,
# so the recorded KEEP_GOING line matches what actually happened.
if parallel_active; then KEEP_GOING=1; fi

# One gate run at a time: an flock held for the life of the process, so a second
# run (parallel or serial) is refused instead of overlapping the first.
# The lock path is FIXED, deliberately not $LOG_DIR: LR_GATE_LOG_DIR lets a caller
# move the log anywhere, and if the lock moved with it, two runs pointed at
# different log dirs would each find their own lock free and both start -- the
# exact overlap this exists to prevent. A dry run takes no lock: it prints the
# plan and touches nothing.
if [[ "$GATE_DRY_RUN" != "1" ]]; then
    mkdir -p /data/tmp/lr-gates
    exec 9>/data/tmp/lr-gates/.gates.lock
    if ! flock -n 9; then
        printf "another final_gates run holds the gates lock; refusing to start a\n" >&2
        printf "second one (hard rule: only one gate run at a time)\n" >&2
        exit 3
    fi
fi

# gate order; keep in sync with the SKIP_ENV table in the header
GATE_ORDER=(build conf unit contract probes e2e_stateful e2e_policies e2e_ui_bridge
            e2e_errors e2e_effort head_routes mesh_http
            e2e_policy_parity e2e_watcher e2e_token_accounting e2e_gpu_load
            e2e_routing_dyn e2e_profiles e2e_caps e2e_models_advertisement
            mesh_two e2e_tls_chain)

# quick tier: only the gates that verify in seconds-to-minutes without the
# slow e2e container suites. The default for ordinary changes.
QUICK_GATES=(build conf unit contract probes)
GATE_TIER=${GATE_TIER:-quick}
case "$GATE_TIER" in
    quick|full) ;;
    *) printf 'GATE_TIER must be quick or full (got: %s)\n' "$GATE_TIER" >&2; exit 2 ;;
esac

in_tier() {
    local g=$1 want
    [[ "$GATE_TIER" == "full" ]] && return 0
    for want in "${QUICK_GATES[@]}"; do [[ "$want" == "$g" ]] && return 0; done
    return 1
}

# Runs here rather than where the wave tables are declared: it walks GATE_ORDER,
# which is defined above this point and not below it. An unclassified gate is a
# hard error, so adding a gate without classifying it cannot silently serialise.
check_gate_classification

declare -A SKIP=()
raw_skips=${SKIP_ENV:-}
for want in ${raw_skips//,/ }; do
    SKIP["$want"]=1
done
matched=0
for want in "${!SKIP[@]}"; do
    matched=0
    for g in "${GATE_ORDER[@]}"; do [[ "$g" == "$want" ]] && matched=1; done
    [[ "$matched" == "1" ]] || { echo "SKIP_ENV: unknown gate '$want' (known: ${GATE_ORDER[*]})" >&2; exit 2; }
done

PASSED_GATES=0
FAILED_GATES=0
SKIPPED_GATES=0
FAILURES=()

is_selected() {
    local g=$1
    [[ -n "$GATE_ONLY" && "$GATE_ONLY" != "$g" ]] && return 1
    [[ -n "${SKIP[$g]:-}" ]] && return 1
    in_tier "$g" || return 1
    return 0
}

# gate NAME [command...] — runs the command, tees into $LOG, and records the
# result. A gate is a shell function name defined below (gate_<name>).
gate() {
    local name=$1; shift
    if [[ -z "$GATE_ONLY" ]] && ! in_tier "$name"; then
        # not in this tier and not singled out: simply not part of this run.
        # Deliberately NOT recorded as a skip — a quick log must not read as
        # a shrunk full log.
        return 0
    fi
    if [[ -n "${SKIP[$name]:-}" ]]; then
        SKIPPED_GATES=$((SKIPPED_GATES + 1))
        printf '\n== gate: %-14s SKIPPED (SKIP_ENV) ==\n' "$name"
        printf '   see the header comment for what this skip leaves unverified\n'
        { echo; echo "== gate: $name SKIPPED by SKIP_ENV =="; } >>"$LOG"
        return 0
    fi
    if [[ -n "$GATE_ONLY" && "$GATE_ONLY" != "$name" ]]; then
        return 0
    fi
    printf '\n== gate: %-14s ' "$name"
    { echo; echo "===== gate: $name  $(date -u +%H:%M:%S) ====="; } >>"$LOG"
    local started=$SECONDS rc=0
    if [[ $# -gt 0 ]]; then
        "$@" >>"$LOG" 2>&1
        rc=$?
    else
        run_gate_body "$name" "$LOG"
        rc=$?
    fi
    local took=$((SECONDS - started))
    if [[ "$rc" == "0" ]]; then
        PASSED_GATES=$((PASSED_GATES + 1))
        printf 'PASS  (%3ss)\n' "$took"
    else
        FAILED_GATES=$((FAILED_GATES + 1))
        FAILURES+=("$name (rc=$rc, ${took}s)")
        printf 'FAIL  (%3ss, rc=%s)\n' "$took" "$rc"
        printf '   last lines of %s:\n' "$LOG"
        tail -n 25 "$LOG" | sed 's/^/   | /'
    fi
    if [[ "$rc" != "0" && "$KEEP_GOING" != "1" && -z "$GATE_ONLY" ]]; then
        printf '\nstopping at the first failing gate (%s)\n' "$name"
        printf 'full log: %s\n' "$LOG"
        exit 1
    fi
    return 0
}

# run_gate_body NAME LOGFILE NAMESPACE — the single place a gate body is
# executed. NAMESPACE=1 (parallel only) also hands the suite a gate-scoped tag,
# which _lib.py folds into every container name, every mock log path and every
# per-run temp file, plus the one reserve file the pool shares so two suites
# cannot be handed the same loopback port. With NAMESPACE=0 nothing is exported,
# so the default serial run is the historical byte-for-byte behaviour.
run_gate_body() {
    local name=$1 logfile=$2 namespace=${3:-0}
    if [[ "$namespace" == "1" ]]; then
        export LR_GATE_TAG="$name"
        # One reserve file for the whole pool: a per-gate file would let two
        # suites be handed the same port, which is the race this closes.
        export LR_PORT_RESERVE="$RESULT_DIR/ports.reserved"
    fi
    # 9>&- drops the run-wide lock before the gate body runs. It is inherited by
    # every child otherwise, so one gate that leaks a stray background process --
    # an orphaned mock worker, say -- would keep the lock alive after this script
    # exits and block every later run. The parent still holds it, so the run
    # remains exclusive; only the descendants stop advertising that they hold it.
    "gate_$name" >>"$logfile" 2>&1 9>&-
}

# Parallel bookkeeping. Jobs report through $RESULT_DIR/<gate>.rc (rc, seconds,
# start stamp) and never touch the shared counters, which stay parent-only.
declare -A JOB_PID=()

start_gate_job() {
    local name=$1
    local plog="$PER_GATE_DIR/$name.log"
    : >"$plog"
    rm -f "$RESULT_DIR/$name.rc"
    # 9>&- so a gate that leaks a stray background process cannot keep the
    # run-wide flock alive after this script exits and wedge every later run.
    (
        local started=$SECONDS rc
        run_gate_body "$name" "$plog" 1
        rc=$?
        # write-then-rename so the parent never reads a half-written result
        printf "%s %s %s\n" "$rc" "$((SECONDS - started))" "$(date -u +%H:%M:%S)" \
            >"$RESULT_DIR/$name.rc.part"
        mv -f "$RESULT_DIR/$name.rc.part" "$RESULT_DIR/$name.rc"
    ) 9>&- &
    JOB_PID["$name"]=$!
}

# collect_finished — print + count every job that reported, in completion order
# so a red gate shows its own context the moment it lands.
collect_finished() {
    local name rc took
    for name in "${!JOB_PID[@]}"; do
        [[ -f "$RESULT_DIR/$name.rc" ]] || continue
        read -r rc took <<<"$(cut -d" " -f1,2 "$RESULT_DIR/$name.rc")" || continue
        [[ -n "$rc" && -n "$took" ]] || continue
        unset "JOB_PID[$name]"
        if [[ "$rc" == "0" ]]; then
            PASSED_GATES=$((PASSED_GATES + 1))
            printf '\n== gate: %-14s PASS  (%3ss)\n' "$name" "$took"
        else
            FAILED_GATES=$((FAILED_GATES + 1))
            FAILURES+=("$name (rc=$rc, ${took}s)")
            printf '\n== gate: %-14s FAIL  (%3ss, rc=%s)\n' "$name" "$took" "$rc"
        fi
        if [[ "$rc" != "0" ]]; then
            printf '   last lines of %s:\n' "$PER_GATE_DIR/$name.log"
            tail -n 25 "$PER_GATE_DIR/$name.log" | sed 's/^/   | /'
        fi
    done
}

# run_wave — the pool over the gates named in the arguments; blocks are
# appended to $LOG in GATE_ORDER afterwards, so the log keeps the serial shape
# (one ===== gate: NAME HH:MM:SS ===== block per gate, in run order).
run_wave() {
    local -a queue=("$@")
    local -a requested=("$@")
    local name; local -a finished=()
    while [[ ${#queue[@]} -gt 0 || ${#JOB_PID[@]} -gt 0 ]]; do
        while [[ ${#JOB_PID[@]} -lt "$GATE_JOBS" && ${#queue[@]} -gt 0 ]]; do
            name=${queue[0]}
            queue=("${queue[@]:1}")
            if [[ -n "${SKIP[$name]:-}" ]]; then
                SKIPPED_GATES=$((SKIPPED_GATES + 1))
                printf '\n== gate: %-14s SKIPPED (SKIP_ENV) ==\n' "$name"
                printf '   see the header comment for what this skip leaves unverified\n'
                finished+=("$name")
                continue
            fi
            if ! is_selected "$name"; then
                continue
            fi
            start_gate_job "$name"
        done
        [[ ${#JOB_PID[@]} -gt 0 ]] || break
        collect_finished
        [[ ${#JOB_PID[@]} -gt 0 ]] && sleep 0.5
    done
    collect_finished
    for name in "${finished[@]}"; do
        { echo; echo "===== gate: $name  SKIPPED by SKIP_ENV ====="; } >>"$LOG"
    done
    # Only the gates this wave actually ran, in GATE_ORDER. A second wave must
    # not re-append the first wave blocks, which is why the queue itself (not the
    # whole result dir) decides what to merge.
    for name in "${GATE_ORDER[@]}"; do
        # merge only this wave gates, and only those that really ran
        local hit=0
        for _r in "${requested[@]}"; do [[ "$_r" == "$name" ]] && hit=1; done
        [[ "$hit" == "1" ]] || continue
        [[ -f "$RESULT_DIR/$name.rc" ]] || continue
        { echo; echo "===== gate: $name  parallel ====="; cat "$PER_GATE_DIR/$name.log"; } >>"$LOG"
    done
}

summary() {
    printf '\n----------------------------------------\n'
    printf 'final gates [tier=%s]: %d passed, %d failed, %d skipped (SKIP_ENV=%s)\n' \
        "$GATE_TIER" "$PASSED_GATES" "$FAILED_GATES" "$SKIPPED_GATES" "${raw_skips:-none}"
    [[ ${#FAILURES[@]} -eq 0 ]] || printf 'failed: %s\n' "${FAILURES[*]}"
    [[ ${#SKIP[@]} -eq 0 ]] || printf 'skipped: %s\n' "${!SKIP[*]}"
    printf 'log: %s\n' "$LOG"
    { echo; echo "== summary: $PASSED_GATES passed, $FAILED_GATES failed, $SKIPPED_GATES skipped (tier=$GATE_TIER) =="; } >>"$LOG"
    [[ "$FAILED_GATES" == "0" ]] || exit 1
    return 0
}

# ------------------------------------------------------------------ preflight
preflight() {
    local missing=()
    command -v docker >/dev/null || missing+=(docker)
    command -v curl  >/dev/null || missing+=(curl)
    command -v jq    >/dev/null || missing+=(jq)
    command -v python3 >/dev/null || missing+=(python3)
    if [[ ${#missing[@]} -gt 0 ]]; then
        printf 'missing tools: %s\n' "${missing[*]}" >&2
        exit 2
    fi
    docker image inspect "$AUTHZ_IMAGE" >/dev/null 2>&1 || {
        printf 'image %s is not present (needed by conf/unit/contract)\n' "$AUTHZ_IMAGE" >&2
        exit 2; }
    # Only check an image when a gate that needs it is actually selected, so
    # SKIP_ENV=unit works on a box without the apisix image.
    if is_selected unit; then
        docker image inspect "$RESTY_IMAGE" >/dev/null 2>&1 || {
            printf 'image %s is not present (needed by the resty-based unit runs)\n' \
                "$RESTY_IMAGE" >&2
            exit 2; }
    fi
    if is_selected e2e_stateful || is_selected head_routes || is_selected mesh_http ||
       is_selected e2e_tls_chain; then
        docker image inspect "$E2E_IMAGE" >/dev/null 2>&1 || {
            printf 'image %s is not present (the e2e suites boot it; drop SKIP_ENV=build)\n' \
                "$E2E_IMAGE" >&2
            exit 2; }
    fi
}

# ------------------------------------------------------------------ gates
gate_build() {
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

gate_unit() {
    local rc=0 t
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
    for t in test_tree test_tree_bounds test_state_bounds test_observability test_policies test_hash test_mesh test_watcher test_gpu_load test_routing_dyn test_profiles test_caps_persist test_caps_routing test_models_shape test_models_advertise test_effort_layers; do
        printf '\n-- luajit %s\n' "$t"
        run_unit_luajit "$t" || rc=1
    done
    for t in test_tree test_policies test_hash test_integration; do
        printf '\n-- resty %s\n' "$t"
        run_unit_resty "$t" || rc=1
    done
    return "$rc"
}

gate_contract() {
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

preflight
{
    echo "lua-router final gates  $STAMP"
    echo "repo=$REPO_ROOT authz=$AUTHZ_IMAGE resty=$RESTY_IMAGE e2e=$E2E_IMAGE"
    echo "KEEP_GOING=$KEEP_GOING GATE_ONLY=${GATE_ONLY:-none} SKIP_ENV=${raw_skips:-none}"
} >>"$LOG"


run_all_gates() {
    if ! parallel_active; then
        # Default: the historical serial run, one shared $LOG, first failure stops.
        gate build; gate conf; gate unit; gate contract; gate probes
        gate e2e_stateful; gate e2e_policies; gate e2e_ui_bridge; gate e2e_errors
        gate e2e_effort; gate head_routes; gate mesh_http; gate e2e_policy_parity
        gate e2e_watcher; gate e2e_profiles; gate e2e_caps
        gate e2e_models_advertisement; gate e2e_token_accounting; gate e2e_gpu_load
        gate e2e_routing_dyn; gate mesh_two; gate e2e_tls_chain
        return 0
    fi
    PER_GATE_DIR="$LOG_DIR/per-gate-$STAMP"
    RESULT_DIR="$LOG_DIR/results-$STAMP"
    rm -rf "$PER_GATE_DIR" "$RESULT_DIR"
    mkdir -p "$PER_GATE_DIR" "$RESULT_DIR"
    export LR_PORT_RESERVE="$RESULT_DIR/ports.reserved"
    : >"$LR_PORT_RESERVE"
    # Phase 1: the portless four. build writes the image every e2e suite boots,
    # and contract is the only member that publishes a host port (an unreserved
    # bind(0) of its own), which is safe only because the other three bind none.
    run_wave "${WAVE_PRE[@]}"
    # If build is red, the 15 suites that boot its image would all fail for the
    # same unrelated reason, so stop there. A red contract does not stop the run:
    # it is independent of the container suites, and seeing all of them in one
    # pass is the point of running them together.
    if [[ -f "$RESULT_DIR/build.rc" && "$(cut -d" " -f1 "$RESULT_DIR/build.rc")" != "0" ]]; then
        printf "\nstopping: the build gate is red, the e2e pool cannot be trusted\n"
        summary
    fi
    printf "\n== phase 2 (pool, %s at a time, %s gates eligible)\n" \
        "$GATE_JOBS" "${#PARALLEL_GATES[@]}"
    run_wave "${PARALLEL_GATES[@]}"
    # Phase 3 uses gate(), never the pool: these read machine-wide state, so
    # they must not even overlap each other. gate() appends to $LOG directly,
    # which is why no merge step is needed for them.
    for _name in "${WAVE_TAIL[@]}"; do
        gate "$_name"
    done
    printf "\nper-gate logs: %s\n" "$PER_GATE_DIR"
}

if [[ "$GATE_DRY_RUN" == "1" ]]; then
    printf "lua-router final gates — plan only (nothing executed)\n"
    printf "tier=%s  GATE_JOBS=%s  selected tier gates:\n" "$GATE_TIER" "$GATE_JOBS"
    for g in "${GATE_ORDER[@]}"; do
        if is_selected "$g"; then tag="run"; else tag="off"; fi
        # Which pool the gate belongs to, so the plan reads like the scheduler.
        mode=serial-only
        for _p in "${WAVE_PRE[@]}"; do [[ "$_p" == "$g" ]] && mode=pool-1; done
        for _p in "${PARALLEL_GATES[@]}"; do [[ "$_p" == "$g" ]] && mode=pool-2; done
        for _p in "${WAVE_TAIL[@]}"; do [[ "$_p" == "$g" ]] && mode=serial-only; done
        if [[ -n "${SKIP[$g]:-}" ]]; then tag="skip"; fi
        printf "  %-24s %-6s %s\n" "$g" "$tag" "$mode"
    done
    printf "\nphase 1 (pool, %s at a time): %s\n" "$GATE_JOBS" "${WAVE_PRE[*]}"
    printf "phase 2 (pool, %s at a time): %s\n" "$GATE_JOBS" "${PARALLEL_GATES[*]}"
    printf "phase 3 (serial, one at a time): %s\n" "${WAVE_TAIL[*]}"
    exit 0
fi

run_all_gates

if [[ "$KEEP_GOING" == "1" && "$FAILED_GATES" != "0" ]]; then
    summary
fi
summary
