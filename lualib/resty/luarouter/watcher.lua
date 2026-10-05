-- In-process worker watcher: discovery + registration (doc/gap-watcher-merge.md).
--
-- Semantic port of the standalone llm-watcher daemon
-- (llm-router/watcher/llm_watcher.py, 1577 lines plus its README). The Python
-- daemon reconciled a running router through its HTTP control plane
-- (POST/DELETE /workers, 202 = queued); this module runs inside the router, so
-- registration is a direct registry.add / registry.remove call and the ledger
-- lives in a shared dict instead of a JSON file on disk.
--
-- The nine guards the Python version documents, and where each one lives here:
--   1. never add the router itself    -> classify() router fingerprint + is_self_url()
--      (own SMG_PORT / SMG_METRICS_PORT are never even candidates)
--   2. only real OpenAI endpoints     -> classify(): /v1/models must answer
--      data[].id, which is what keeps node_exporter and HTML 404 pages out
--   3. protect the pre-existing pool  -> first-contact snapshot into `protected`,
--      never deleted (they were written by SMG_WORKER_URLS or by a human)
--   4. only delete what it owns       -> removals iterate the ledger's owned set,
--      and unregister() re-checks that the id still maps to that URL
--   5. remove grace                   -> missing_since + remove_grace_secs
--   6. never empty a model            -> is_last_for_model() + keep_last_grace_secs
--   7. release stuck adds             -> reap_pending()
--   8. survive a router restart       -> refresh_ids() re-reads the worker ids
--   9. blind by design                -> no GPU reads, no service control, only
--      /v1/models, /server_info, /get_server_info, /props, /metrics and /health
--  10. probe eviction is graded       -> probe_verdict() splits the classify()
--      rejections: a deterministic "this is not a worker" answer evicts in the
--      same pass, a transport-level unknown must repeat SMG_WATCHER_PROBE_FAILURES
--      rounds (default 2) before eviction, and reasons that say more about the
--      gateway than about the service never count at all; a per-pass fuse
--      (SMG_WATCHER_PROBE_FUSE) keeps one bad interval from emptying the pool.
--
-- Two layers, so the semantics are testable without nginx (same split as
-- mesh.lua): the pure functions below take an injected `fetch`/`getenv`/store,
-- and the live wiring at the bottom resolves ngx, hb, registry and docker.

-- 2026-10-05 (doc/refactor-arch-2026-10-05.md, worker w_bg): the implementation moved
-- verbatim into lualib/resty/luarouter/watcher/ -- env / ledger / probe / discover /
-- reconcile / live / modelmap.  What is left here is the file-header contract, the two
-- constants and this _M facade.  Each submodule registers its own "function _M.x"
-- against this pre-loaded table at load time (design doc section 2), so the _M name
-- set, the signatures and the call semantics (including what a unit-test stub can
-- intercept) are identical to the monolith, name by name.  reconcile() moved whole:
-- its body was deliberately not decomposed.
local _M = { _VERSION = "0.1.0" }
package.loaded["resty.luarouter.watcher"] = _M


---Provenance written into every worker this watcher registers (metadata of the
---same name on GET /workers, so an operator can tell managed rows from hand-made
---ones, exactly like the daemon's llm-watcher label).
_M.MANAGED_BY = "router-watch"

---Keys whose presence in a /server_info body means "this is another router"
---(llm_watcher.py ROUTER_FINGERPRINT_KEYS).
_M.ROUTER_FINGERPRINT_KEYS = { "router_manager", "workers_count", "routers_count" }

require "resty.luarouter.watcher.env"
require "resty.luarouter.watcher.ledger"
require "resty.luarouter.watcher.probe"
require "resty.luarouter.watcher.discover"
require "resty.luarouter.watcher.reconcile"
require "resty.luarouter.watcher.live"
require "resty.luarouter.watcher.modelmap"

return _M
