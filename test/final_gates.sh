#!/usr/bin/env bash
# ============================================================================
# lua-router final gate — one serial command for the whole release check
# ============================================================================
#仓库化的最终门禁（取代 /data/tmp/lr-core2/final_gates.sh 那个一次性脚本）。
# 与旧脚本的差异：补齐了 probes.py、e2e_errors.py、e2e_effort.py、
# 未接线模块的单测（mesh / tokenizer_parse）以及新增的两个
# HTTP 面集成测试（test_head_routes.py、test_mesh_http.py），并改成
# 首个失败即退出。
#
# Usage:
#   bash test/final_gates.sh                    # full run, strict
#   SKIP_ENV=mesh_http bash test/final_gates.sh # skip named gates
#   KEEP_GOING=1 bash test/final_gates.sh       # run all, count fails
#   GATE_ONLY=unit bash test/final_gates.sh     # single gate
#   LR_GATE_LOG=/path/log bash ...                         # log location
#
# Gate ids, in run order (SKIP_ENV takes a comma/space separated list of these):
#   build          docker build lua-router:integration (the e2e suites boot it)
#   conf           openresty -t on test/conf/nginx-lua-router.conf + conf/lua-router.conf
#   unit           tree / policies / hash / mesh (authz luajit)
#                  + tree / policies / hash / integration / tokenizer_parse (apisix resty)
#   contract       test_lua_router.sh, strict (first FAIL aborts the suite)
#   probes         integration/probes.py (policy factory, knobs, re_split, json-edit)
#   e2e_stateful   integration/e2e_stateful.py
#   e2e_policies   integration/e2e_policies.py
#   e2e_ui_bridge  integration/e2e_ui_bridge.py
#   e2e_errors     integration/e2e_errors.py
#   e2e_effort     integration/e2e_effort.py
#   e2e_discovery_dp integration/e2e_discovery_dp.py
#   e2e_jwt        integration/e2e_jwt.py (JWT/JWKS control-plane gate)
#   head_routes    integration/test_head_routes.py (HEAD mirror of the GET surface)
#   mesh_http      integration/test_mesh_http.py (mesh enabled over real HTTP)
#   e2e_otel       integration/e2e_otel.py (W3C trace propagation + OTLP/HTTP export)
#   e2e_policy_parity prefix_hash/bucket/power_of_two/random quantitative parity
#   mesh_two       integration/test_mesh_two.py (two real routers: converge,
#                  18 s stability, stop/heal partition window, retire broadcast)
#   e2e_tls_chain  integration/e2e_tls_chain.py (server-side TLS: runtime-built
#                  root/intermediate/leaf PKI, chain completeness as served,
#                  expired / wrong-name / non-CA-issuer / self-signed refusals,
#                  RSA and ECDSA x TLSv1.2/1.3, SNI two names on one port)
#
# What skipping costs (read this before using SKIP_ENV):
#   build          e2e_* and mesh_http then run against a possibly stale image.
#   conf           nothing checks the two shipped configs still parse.
#   unit           the pure-Lua modules (tree/hash/policies/mesh/
#                  tokenizer_parse) have no other gate — router.lua only
#                  exercises them through HTTP, so a regression can hide.
#   contract       the whole 659-check wire contract is unverified.
#   probes         the policy factory / config-knob / raw-JSON-editor probes.
#   e2e_*          that behaviour family over a real container.
#   head_routes    the HEAD mirror (Rust axum answers HEAD on every GET route).
#   mesh_http      mesh enablement over real HTTP: peer apply/sync, worker
#                  mirror, /ha/policies, /_mesh/internal/{state,apply}.
#   e2e_otel       trace-context generation/inheritance, OTLP export, batching,
#                  sampling and the dead-collector path have no other gate.
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
# Concurrency with other container-heavy suites is allowed but roughly doubles
# the wall time.
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

# gate order; keep in sync with the SKIP_ENV table in the header
GATE_ORDER=(build conf unit contract probes e2e_stateful e2e_policies e2e_ui_bridge
            e2e_errors e2e_effort e2e_discovery_dp e2e_jwt head_routes mesh_http
            e2e_otel e2e_policy_parity mesh_two e2e_tls_chain)

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
    return 0
}

# gate NAME [command...] — runs the command, tees into $LOG, and records the
# result. A gate is a shell function name defined below (gate_<name>).
gate() {
    local name=$1; shift
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
        "gate_$name" >>"$LOG" 2>&1
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

summary() {
    printf '\n----------------------------------------\n'
    printf 'final gates: %d passed, %d failed, %d skipped (SKIP_ENV=%s)\n' \
        "$PASSED_GATES" "$FAILED_GATES" "$SKIPPED_GATES" "${raw_skips:-none}"
    [[ ${#FAILURES[@]} -eq 0 ]] || printf 'failed: %s\n' "${FAILURES[*]}"
    [[ ${#SKIP[@]} -eq 0 ]] || printf 'skipped: %s\n' "${!SKIP[*]}"
    printf 'log: %s\n' "$LOG"
    { echo; echo "== summary: $PASSED_GATES passed, $FAILED_GATES failed, $SKIPPED_GATES skipped =="; } >>"$LOG"
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
    for t in test_tree test_policies test_hash test_mesh \
             test_service_discovery test_jwks test_otel; do
        printf '\n-- luajit %s\n' "$t"
        run_unit_luajit "$t" || rc=1
    done
    for t in test_tree test_policies test_hash test_integration test_tokenizer_parse; do
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
gate_e2e_discovery_dp() { run_integration e2e_discovery_dp.py 1500; }
gate_e2e_jwt()       { run_integration e2e_jwt.py 900; }
gate_head_routes()   { run_integration test_head_routes.py 900; }
gate_mesh_http()     { run_integration test_mesh_http.py 900; }
gate_e2e_otel()      { run_integration e2e_otel.py 1500; }
gate_e2e_policy_parity() { run_integration e2e_policy_parity.py 1800; }
gate_mesh_two()        { run_integration test_mesh_two.py 900; }
gate_e2e_tls_chain()   { run_integration e2e_tls_chain.py 1500; }

preflight
{
    echo "lua-router final gates  $STAMP"
    echo "repo=$REPO_ROOT authz=$AUTHZ_IMAGE resty=$RESTY_IMAGE e2e=$E2E_IMAGE"
    echo "KEEP_GOING=$KEEP_GOING GATE_ONLY=${GATE_ONLY:-none} SKIP_ENV=${raw_skips:-none}"
} >>"$LOG"

gate build
gate conf
gate unit
gate contract
gate probes
gate e2e_stateful
gate e2e_policies
gate e2e_ui_bridge
gate e2e_errors
gate e2e_effort
gate e2e_discovery_dp
gate e2e_jwt
gate head_routes
gate mesh_http
gate e2e_otel
gate e2e_policy_parity
gate mesh_two
gate e2e_tls_chain

if [[ "$KEEP_GOING" == "1" && "$FAILED_GATES" != "0" ]]; then
    summary
fi
summary
