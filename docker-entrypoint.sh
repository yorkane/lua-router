#!/bin/sh
# lua-router entrypoint
#   1. resolve the listen address / worker count / log level from the env
#   2. envsubst nginx.conf.template -> nginx.conf
#   3. exec openresty
#
# Every behavioural knob (policy, health check, circuit breaker, retries, request
# log capacity) is read from the environment by resty.luarouter.config, so this
# script only has to render what nginx itself needs at parse time.

set -e

LISTEN_HOST="${SMG_HOST:-0.0.0.0}"
LISTEN_PORT="${SMG_PORT:-30000}"
# Default one process per core. cache_aware keeps its affinity tree in per-process
# Lua memory, so an unset count drops to 1 to avoid N partial trees
# (doc/impl-policies.md deviation 1); an explicit NGINX_WORKER_PROCESSES always wins.
WORKER_PROCESSES="${NGINX_WORKER_PROCESSES:-auto}"
# SMG_POLICY itself defaults to cache_aware (resty.luarouter.config), so the
# single-process rule has to apply when the variable is unset as well: an
# operator who never names a policy still gets cache_aware behaviour.
if [ -z "${NGINX_WORKER_PROCESSES:-}" ] && [ "${SMG_POLICY:-cache_aware}" = "cache_aware" ]; then
    WORKER_PROCESSES="1"
fi
# The mesh cluster view lives in process memory (doc/gap-mesh.md 4.4), so only
# worker 0 syncs and the others would answer /ha/* from a stale table - and each
# process would multiply the global rate-limit counters. Pin the count the same
# way cache_aware does; an explicit NGINX_WORKER_PROCESSES still wins.
case "${SMG_ENABLE_MESH:-}" in
    1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn])
        if [ -z "${NGINX_WORKER_PROCESSES:-}" ]; then
            WORKER_PROCESSES="1"
        fi
        ;;
esac
WORKER_CONNECTIONS="${NGINX_WORKER_CONNECTIONS:-4096}"
MAX_PAYLOAD_SIZE="${SMG_MAX_PAYLOAD_SIZE:-512m}"
LOG_LEVEL="${SMG_LOG_LEVEL:-${LR_LOG_LEVEL:-warn}}"
# config.lua spells the Rust CLI levels, so accept trace as well.
[ "$LOG_LEVEL" = "trace" ] && LOG_LEVEL="debug"
# The UI bundle directory is named LMR_UI_DIR by the UI agent's config store and
# SMG_UI_DIR by the Rust CLI. Mapping the Rust name onto the Lua one here (before
# init_by_lua snapshots the environment) makes both work without touching ui.conf.
if [ -n "${SMG_UI_DIR:-}" ] && [ -z "${LMR_UI_DIR:-}" ]; then
    LMR_UI_DIR="$SMG_UI_DIR"
    export LMR_UI_DIR
fi
# Container logs go to the foreground stderr so `docker logs` sees Lua errors.
# The authz image symlinks logs/error.log to /dev/stderr, but the template
# renders this variable, so it must never be empty: with an empty path nginx
# falls back to a file literally named after the level.
ERROR_LOG_PATH="${LR_ERROR_LOG_PATH:-/dev/stderr}"

OPENRESTY_PREFIX="${OPENRESTY_PREFIX:-/usr/local/openresty/nginx}"
NGINX_CONF_DIR="$OPENRESTY_PREFIX/conf"
TEMPLATE_DIR="${OPENRESTY_TEMPLATE_DIR:-$NGINX_CONF_DIR}"
TEMPLATE_FILE="$TEMPLATE_DIR/nginx.conf.template"

# A size, not a count: normalise bare numbers to <n>m the way nginx expects.
case "$MAX_PAYLOAD_SIZE" in
    *[!0-9]*) : ;;                       # already has a k/m/g suffix
    *) MAX_PAYLOAD_SIZE="${MAX_PAYLOAD_SIZE}m" ;;
esac

case "$LISTEN_PORT" in
    ""|*[!0-9]*) echo "error: SMG_PORT must be numeric" >&2; exit 1 ;;
esac
if [ "$LISTEN_PORT" -lt 1 ] || [ "$LISTEN_PORT" -gt 65535 ]; then
    echo "error: SMG_PORT must be 1-65535" >&2
    exit 1
fi
case "$LOG_LEVEL" in
    debug|info|notice|warn|error|crit|alert|emerg) : ;;
    *) echo "error: SMG_LOG_LEVEL must be debug|info|notice|warn|error|crit|alert|emerg" >&2
       exit 1 ;;
esac
case "$WORKER_PROCESSES" in
    auto|*[!0-9]*) : ;;
    *) if [ "$WORKER_PROCESSES" -lt 1 ] || [ "$WORKER_PROCESSES" -gt 256 ]; then
         echo "error: NGINX_WORKER_PROCESSES must be auto or 1-256" >&2
         exit 1
       fi ;;
esac

# IPv6 literals need brackets in the listen directive.
case "$LISTEN_HOST" in
    *:*) LISTEN_ADDR="[$LISTEN_HOST]:$LISTEN_PORT" ;;
    *)   LISTEN_ADDR="$LISTEN_HOST:$LISTEN_PORT" ;;
esac

DNS_RESOLVER="${AUTHZ_DNS_RESOLVER:-$(awk '/^nameserver[[:space:]]+/ { print $2; exit }' /etc/resolv.conf)}"
DNS_RESOLVER="${DNS_RESOLVER:-1.1.1.1}"

# Modules live in the image at site/lualib; the bundled UI is served by the UI
# agent's own static file under that prefix, so no extra lua path is required.
LUA_PACKAGE_PATH="/usr/local/openresty/site/lualib/?.lua;/usr/local/openresty/site/lualib/?/init.lua;/usr/local/openresty/lualib/?.lua;/usr/local/openresty/lualib/?/init.lua;;"

# Second listener for Prometheus scrapes, so a dashboard can point at a dedicated
# port. The Rust gateway binds this by default (--prometheus-port 29000,
# gateway/src/main.rs:274) and only shares /metrics on the main port otherwise;
# SMG_METRICS_PORT=0 turns the listener off, which is what the e2e suites need
# because the test host already has a gateway on 29000.
METRICS_PORT="${SMG_METRICS_PORT:-${LR_METRICS_PORT:-29000}}"
METRICS_HOST="${SMG_PROMETHEUS_HOST:-$LISTEN_HOST}"
case "$METRICS_PORT" in
    ""|*[!0-9]*) echo "error: SMG_METRICS_PORT must be numeric" >&2; exit 1 ;;
esac
if [ "$METRICS_PORT" -gt 65535 ]; then
    echo "error: SMG_METRICS_PORT must be 0-65535" >&2; exit 1
fi
case "$METRICS_HOST" in
    *:*) METRICS_ADDR="[$METRICS_HOST]:$METRICS_PORT" ;;
    *)   METRICS_ADDR="$METRICS_HOST:$METRICS_PORT" ;;
esac
if [ "$METRICS_PORT" -gt 0 ] && [ "$METRICS_PORT" != "$LISTEN_PORT" ]; then
    METRICS_EXTRA="server {
        listen ${METRICS_ADDR};
        server_name _;
        location = /metrics {
            content_by_lua_block {
                require(\"resty.luarouter.router\").metrics_handler()
            }
        }
        location = /health {
            return 200 \"OK\";
        }
        # Anything else gets a clean 404. Without this the request falls
        # through to the default static root and nginx logs an [error]
        # for every probe that hits the metrics port with a non-metrics
        # path (e.g. the llm-watcher port scanner trying GET /v1/models
        # on every local listener). The Rust prometheus listener also
        # answers non-metrics paths with a plain 404; this matches it and
        # keeps the error log clean.
        location / {
            return 404;
        }
    }"
else
    METRICS_EXTRA=""
fi

# Server-side TLS (doc/gap-auth-tls.md). SMG_TLS_CERT_PATH + SMG_TLS_KEY_PATH
# turn the *main* listener into a TLS listener, which is what the Rust gateway
# does with rustls: the encrypted socket replaces the plain bind on the same
# host:port instead of opening a second port, so a client that speaks plain http
# to that port gets a handshake error rather than a router response. The separate
# metrics listener and the gRPC listener stay plain (Rust shares their TLS
# configuration with the main bind, so the difference is only cosmetic here).
TLS_LISTEN_FLAGS=""
TLS_SERVER_EXTRA=""
TLS_STATE="off"
if [ -n "${SMG_TLS_CERT_PATH:-}" ] || [ -n "${SMG_TLS_KEY_PATH:-}" ]; then
    if [ -z "${SMG_TLS_CERT_PATH:-}" ] || [ -z "${SMG_TLS_KEY_PATH:-}" ]; then
        echo "error: SMG_TLS_CERT_PATH and SMG_TLS_KEY_PATH must be set together" >&2
        exit 1
    fi
    if [ ! -s "$SMG_TLS_CERT_PATH" ] || [ ! -s "$SMG_TLS_KEY_PATH" ]; then
        echo "error: TLS certificate or key missing (check SMG_TLS_CERT_PATH/SMG_TLS_KEY_PATH)" >&2
        exit 1
    fi
    TLS_LISTEN_FLAGS=" ssl"
    TLS_SERVER_EXTRA="        ssl_certificate ${SMG_TLS_CERT_PATH};
        ssl_certificate_key ${SMG_TLS_KEY_PATH};
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers on;
        ssl_session_cache shared:LR_TLS:10m;
        ssl_session_timeout 10m;"
    TLS_STATE="on (TLSv1.2/1.3)"
fi

HTTP_EXTRA=""
if [ -n "${LR_HTTP_INCLUDE:-}" ] && [ -f "${LR_HTTP_INCLUDE}" ]; then
    HTTP_EXTRA="include ${LR_HTTP_INCLUDE};"
fi

TEMPLATE_VARIABLES='${WORKER_PROCESSES} ${WORKER_CONNECTIONS} ${NOFILE_LIMIT} ${LISTEN_ADDR} ${LUA_PACKAGE_PATH} ${DNS_RESOLVER} ${MAX_PAYLOAD_SIZE} ${ERROR_LOG_PATH} ${LOG_LEVEL} ${SERVER_EXTRA} ${HTTP_EXTRA} ${METRICS_EXTRA} ${GRPC_EXTRA} ${TLS_LISTEN_FLAGS} ${TLS_SERVER_EXTRA}'

# render <template> <output> [variables] - envsubst is given an explicit whitelist,
# so a fragment with its own knobs passes its own list (the gRPC server template
# would otherwise ship a literal ${GRPC_LISTEN_ADDR} into the listen directive).
render() {
    input_file="$1"
    output_file="$2"
    variables=${3:-$TEMPLATE_VARIABLES}
    temporary_file="${output_file}.tmp.$$"
    envsubst "$variables" < "$input_file" > "$temporary_file"
    mv "$temporary_file" "$output_file"
}

# ---------------------------------------------------------------- gRPC plane
# SMG_GRPC_PORT (Rust: --grpc-port style opt-in) renders a second listener that
# proxies gRPC to the registered grpc workers. 0 (the default) keeps the plane
# entirely absent: nothing is rendered, nothing is included, and the registry
# refuses grpc/prefill/decode registrations with a 400 (registry.grpc_enabled),
# so an off deployment behaves exactly as it did before this feature.
GRPC_PORT="${SMG_GRPC_PORT:-0}"
case "$GRPC_PORT" in
    ""|*[!0-9]*) echo "error: SMG_GRPC_PORT must be numeric" >&2; exit 1 ;;
esac
if [ "$GRPC_PORT" -gt 65535 ]; then
    echo "error: SMG_GRPC_PORT must be 0-65535" >&2; exit 1
fi
GRPC_HOST="${SMG_GRPC_HOST:-$LISTEN_HOST}"
GRPC_POLICY="${SMG_GRPC_POLICY:-round_robin}"
GRPC_MAX_BODY_SIZE="$MAX_PAYLOAD_SIZE"
GRPC_READ_TIMEOUT="${SMG_GRPC_READ_TIMEOUT_SECS:-1800}s"
case "$GRPC_POLICY" in
    round_robin|sticky|power_of_two) : ;;
    *) echo "error: SMG_GRPC_POLICY must be round_robin|sticky|power_of_two" >&2
       exit 1 ;;
esac
GRPC_SERVER_TEMPLATE="$TEMPLATE_DIR/grpc-server.conf.template"
GRPC_READINESS_FRAGMENT="$TEMPLATE_DIR/grpc-readiness.conf"
GRPC_EXTRA=""
if [ "$GRPC_PORT" -gt 0 ]; then
    if [ "$GRPC_PORT" = "$LISTEN_PORT" ] || [ "$GRPC_PORT" = "$METRICS_PORT" ]; then
        echo "error: SMG_GRPC_PORT must differ from SMG_PORT and SMG_METRICS_PORT" >&2
        exit 1
    fi
    if [ ! -s "$GRPC_SERVER_TEMPLATE" ]; then
        echo "error: missing gRPC server template: $GRPC_SERVER_TEMPLATE" >&2
        exit 1
    fi
    case "$LISTEN_HOST" in
        *:*) GRPC_LISTEN_ADDR="[$GRPC_HOST]:$GRPC_PORT" ;;
        *)   GRPC_LISTEN_ADDR="$GRPC_HOST:$GRPC_PORT" ;;
    esac
    export GRPC_LISTEN_ADDR GRPC_READ_TIMEOUT GRPC_MAX_BODY_SIZE GRPC_POLICY
    render "$GRPC_SERVER_TEMPLATE" "$NGINX_CONF_DIR/grpc-server.conf" \
        '$GRPC_LISTEN_ADDR $GRPC_READ_TIMEOUT $GRPC_MAX_BODY_SIZE $GRPC_POLICY'
    # Declared here rather than in the fragment: log_format only parses in http{},
    # where this variable lands. The per-call line names the selected worker, the
    # pool it came from and the peer, which is the evidence that the dynamic
    # selection actually moved (a static proxy log cannot show it).
    GRPC_EXTRA="log_format lr_grpc '\$remote_addr \"\$request\" worker=[\$lr_grpc_worker] pool=[\$lr_grpc_pool] peer=[\$upstream_addr] grpc_status=[\$upstream_http_grpc_status] upstream_status=[\$upstream_status] status=\$status rt=\$request_time';
include ${NGINX_CONF_DIR}/grpc-server.conf;"
    # The plane being on is what makes the registry accept the grpc/prefill/decode
    # enum variants, so the exported value is the one knob both halves read.
    SMG_GRPC=1
    export SMG_GRPC
fi

# The UI agent ships conf/ui.conf (all /_ui/* locations: API aliases plus the
# static SPA). It is included when present so the router still boots without it;
# LR_UI_CONF overrides the path, LR_UI_CONF=off disables the include.
SERVER_EXTRA=""
UI_CONF="${LR_UI_CONF:-$NGINX_CONF_DIR/lua-router/ui.conf}"
if [ "$UI_CONF" = "off" ]; then
    UI_CONF=""
fi
if [ -n "$UI_CONF" ] && [ -f "$UI_CONF" ]; then
    SERVER_EXTRA="include ${UI_CONF};"
fi
if [ -n "${LR_SERVER_INCLUDE:-}" ] && [ -f "${LR_SERVER_INCLUDE}" ]; then
    SERVER_EXTRA="${SERVER_EXTRA}
include ${LR_SERVER_INCLUDE};"
fi
# With the gRPC plane on, /readiness also has to judge the PD pools (Rust requires
# one healthy worker per pool in PrefillDecode mode). The fragment overrides the
# route with an exact location, which outranks the klib.router catch-all, so the
# router module itself stays untouched.
if [ "$GRPC_PORT" -gt 0 ] && [ -s "$GRPC_READINESS_FRAGMENT" ]; then
    SERVER_EXTRA="${SERVER_EXTRA}
include ${GRPC_READINESS_FRAGMENT};"
fi

case "$WORKER_CONNECTIONS" in
    ""|*[!0-9]*) echo "error: NGINX_WORKER_CONNECTIONS must be numeric" >&2; exit 1 ;;
esac

# nginx warns when worker_connections exceeds the fd limit; raise the soft limit
# to cover it (the container's hard limit is far higher) and tell nginx the same
# number through worker_rlimit_nofile.
NOFILE_LIMIT=$((WORKER_CONNECTIONS * 2))
ulimit -n "$NOFILE_LIMIT" 2>/dev/null || true
mkdir -p "$(dirname "$ERROR_LOG_PATH")" "$OPENRESTY_PREFIX/logs"

if [ ! -s "$TEMPLATE_FILE" ]; then
    echo "error: missing runtime template: $TEMPLATE_FILE" >&2
    exit 1
fi

export WORKER_PROCESSES WORKER_CONNECTIONS NOFILE_LIMIT LISTEN_ADDR LUA_PACKAGE_PATH \
       DNS_RESOLVER MAX_PAYLOAD_SIZE ERROR_LOG_PATH LOG_LEVEL \
       SERVER_EXTRA HTTP_EXTRA METRICS_EXTRA GRPC_EXTRA \
       TLS_LISTEN_FLAGS TLS_SERVER_EXTRA

render "$TEMPLATE_FILE" "$NGINX_CONF_DIR/nginx.conf"

# Fail fast on a bad render rather than crash-looping after the health probe.
OPENRESTY_BIN="${OPENRESTY_BIN:-$OPENRESTY_PREFIX/bin/openresty}"
[ -x "$OPENRESTY_BIN" ] || OPENRESTY_BIN="$(command -v openresty)"
"$OPENRESTY_BIN" -t -p "$OPENRESTY_PREFIX" >/dev/null 2>&1 || {
    echo "error: rendered nginx.conf failed validation; writing it to stderr" >&2
    cat "$NGINX_CONF_DIR/nginx.conf" >&2
    exit 1
}

# The banner has to spell the same default resty.luarouter.config applies,
# otherwise a container with no SMG_POLICY claims round_robin while running cache_aware.
if [ -n "$METRICS_EXTRA" ]; then
    METRICS_STATE="on ${METRICS_ADDR}"
else
    METRICS_STATE="off"
fi
if [ "$GRPC_PORT" -gt 0 ]; then
    GRPC_STATE="on ${GRPC_LISTEN_ADDR} (policy: ${GRPC_POLICY})"
else
    GRPC_STATE="off"
fi
echo "==> lua-router listening on ${LISTEN_ADDR} (workers: ${WORKER_PROCESSES}, policy: ${SMG_POLICY:-cache_aware}, metrics: ${METRICS_STATE}, grpc: ${GRPC_STATE}, tls: ${TLS_STATE})"

exec "$@"
