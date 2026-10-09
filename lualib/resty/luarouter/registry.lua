-- Worker registry backed by ngx.shared.DICT (lr_workers).
--
-- Mirrors the Rust gateway's core::{WorkerRegistry, JobQueue} contract:
--   * POST /workers reserves an id, queues a background job and answers 202
--   * the id is sha224(url) hex truncated to 32 chars, rendered as a UUID, so
--     the same URL always maps to the same id
--   * re-registering a live URL is not an HTTP error: the job fails with
--     "Worker <url> already exists" and GET /workers/{id} exposes job_status
--   * DELETE releases the url -> id mapping so the URL can be re-added
--
-- Static per-worker fields live in one JSON value under w:<id>; the fields that
-- change on every request (health, circuit breaker, load) are separate numeric
-- keys so they can be touched without decoding the JSON.
--
-- Being numeric is not the same as being race-free: several nginx worker
-- processes charge the same worker concurrently, so every counter that means
-- "consecutive" must be accumulated with shdict:incr() (see charge_cb) and any
-- state flip must be re-checked under the registry lock (see flip_cb). A
-- get()/set() pair there loses updates across processes.
--
-- This file is the facade. The implementation lives in the registry/ directory
-- (keys: key layout, shdict, lock, worker ids, ids roster, mesh hooks - url: url
-- parse and dialing helpers - caps: upstream capability capture - records: spec
-- parsing, the structural writers, the read-side views and patch_record - health:
-- health bit and circuit breaker - loads: load folding and the capacity gates -
-- discovery: probes, coverage learning, PUT update, DP expansion, the job queue
-- and the bootstrap seed) and in resty.luarouter.httpc (the cosocket pool and
-- HTTP primitives that the whole gateway borrows). Every public name below keeps
-- its original spelling and signature: the _M roster is the contract that
-- router/hb/mesh/watcher/config_store/gpu_load/props/observability/policy and the
-- test doubles are written against, so it is re-exported in full, including the
-- exports that currently have no caller (README and doc/gap-worker-caps.md
-- section 8 register several of them as intentionally kept).

local _M = { _VERSION = "0.1.0" }

-- Pre-register the facade table so the submodules below can late-bind the
-- original _M.x() self-calls against this very table (facade pattern,
-- doc/refactor-arch-2026-10-05.md section 2). A unit test that swaps the whole
-- module for a stub through package.loaded therefore still sees exactly one
-- module table, which is what test_profiles / test_integration /
-- test_routing_dyn pin.
package.loaded["resty.luarouter.registry"] = _M

local keys = require "resty.luarouter.registry.keys"
local url = require "resty.luarouter.registry.url"
local caps = require "resty.luarouter.registry.caps"
local records = require "resty.luarouter.registry.records"
local health = require "resty.luarouter.registry.health"
local loads = require "resty.luarouter.registry.loads"
local discovery = require "resty.luarouter.registry.discovery"
-- The public transport module (raised out of the old registry E block). Required
-- here so the re-exports below stay plain table assignments: no lazy lookup and
-- no per-request require on the forwarding path.
local httpc = require "resty.luarouter.httpc"

-- registry/keys.lua
_M.CB_CLOSED = keys.CB_CLOSED
_M.CB_OPEN = keys.CB_OPEN
_M.CB_HALF_OPEN = keys.CB_HALF_OPEN
_M.CB_STATE_NAME = keys.CB_STATE_NAME
_M.set_reconcile_guard = keys.set_reconcile_guard
_M.worker_id_for_url = keys.worker_id_for_url
_M.parse_worker_id = keys.parse_worker_id

-- registry/url.lua
_M.normalize_url = url.normalize_url
_M.strip_rank = url.strip_rank
_M.rank_of = url.rank_of
_M.split_url = url.split_url
_M.tls_handshake = url.tls_handshake

-- resty.luarouter.httpc
_M.pool_name = httpc.pool_name
_M.pool_opts = httpc.pool_opts
_M.pool_idle_ms = httpc.pool_idle_ms
_M.pump_chunked = httpc.pump_chunked
_M.response_reusable = httpc.response_reusable
_M.release = httpc.release

-- registry/caps.lua
_M.model_caps_from_entry = caps.model_caps_from_entry
_M.model_caps_from_listing = caps.model_caps_from_listing
_M.merge_model_caps = caps.merge_model_caps

-- registry/records.lua
_M.policy_hint_for_model = records.policy_hint_for_model
_M.WORKER_TYPES = records.WORKER_TYPES
_M.CONNECTION_MODES = records.CONNECTION_MODES
_M.parse_worker_type = records.parse_worker_type
_M.parse_connection_mode = records.parse_connection_mode
_M.parse_spec_url = records.parse_spec_url
_M.needs_models_refresh = records.needs_models_refresh
_M.add = records.add
_M.remove = records.remove
_M.get = records.get
_M.info = records.info
_M.list = records.list
_M.records = records.records
_M.record = records.record
_M.record_http_selectable = records.record_http_selectable
_M.set_http_selectable = records.set_http_selectable
_M.http_selectable = records.http_selectable
_M.models = records.models
_M.all_models = records.all_models
_M.worker_models = records.worker_models
_M.record_models = records.record_models
_M.http_workers = records.http_workers
_M.worker_serves_model = records.worker_serves_model
_M.models_are_verified = records.models_are_verified
_M.candidate_allows_model = records.candidate_allows_model

-- registry/health.lua
_M.url_for = health.url_for
_M.is_healthy = health.is_healthy
_M.set_healthy = health.set_healthy
_M.breaker_available = health.breaker_available
_M.is_available = health.is_available
_M.cb_state = health.cb_state
_M.set_cb_state = health.set_cb_state
_M.charge_cb = health.charge_cb
_M.flip_cb = health.flip_cb
_M.set_cb_counters = health.set_cb_counters
_M.set_health_counters = health.set_health_counters

-- registry/loads.lua
_M.load = loads.load
_M.load_with = loads.load_with
_M.external_load = loads.external_load
_M.set_external_load = loads.set_external_load
_M.set_self_reported_load = loads.set_self_reported_load
_M.clear_external_load = loads.clear_external_load
_M.set_temp_disable = loads.set_temp_disable
_M.clear_temp_disable = loads.clear_temp_disable
_M.is_temp_disabled = loads.is_temp_disabled
_M.cap_limit = loads.cap_limit
_M.util_limit = loads.util_limit
_M.touch_active = loads.touch_active
_M.last_active_ms = loads.last_active_ms
_M.inflight_requests = loads.inflight_requests
_M.capacity_state = loads.capacity_state
_M.capacity_exclusion = loads.capacity_exclusion
_M.set_power_w = loads.set_power_w
_M.power_w = loads.power_w
_M.power_samples = loads.power_samples
_M.clear_power_w = loads.clear_power_w
_M.set_gpu_util = loads.set_gpu_util
_M.gpu_util = loads.gpu_util
_M.clear_gpu_util = loads.clear_gpu_util
_M.to_milli = loads.to_milli
_M.stale_ttl = loads.stale_ttl
_M.any_external_samples = loads.any_external_samples
_M.flag_external_samples = loads.flag_external_samples
_M.clear_external_samples_flag = loads.clear_external_samples_flag
_M.set_load_scale = loads.set_load_scale
_M.load_scale = loads.load_scale
_M.current_load_scale = loads.current_load_scale
_M.change_load = loads.change_load

-- registry/discovery.lua
_M.probe_advertised_models = discovery.probe_advertised_models
_M.probe_advertised_entries = discovery.probe_advertised_entries
_M.record_model_caps = discovery.record_model_caps
_M.model_caps = discovery.model_caps
_M.MAX_MPROBE = discovery.MAX_MPROBE
_M.MODELS_REFRESH_COOLDOWN_SECS = discovery.MODELS_REFRESH_COOLDOWN_SECS
_M.refresh_models = discovery.refresh_models
_M.update = discovery.update
_M.discover = discovery.discover
_M.MAX_DP_ATTEMPTS = discovery.MAX_DP_ATTEMPTS
_M.expand_dp = discovery.expand_dp
_M.set_job = discovery.set_job
_M.get_job = discovery.get_job
_M.clear_job = discovery.clear_job
_M.bootstrap = discovery.bootstrap

return _M
