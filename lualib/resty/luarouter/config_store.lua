-- RuntimeConfig for the lua-router: the /_ui/config* document, its validation,
-- and the atomic disk persistence behind LMR_CONFIG_FILE.
--
-- Mirrors gateway/src/runtime_config.rs: same sections (default_effort,
-- effort_map, model_ctx, model_effort, model_configs, virtual_models), the same
-- eight effort levels, the same validation messages, and the same snapshot
-- (array) shape on disk so a config.json written by the Rust gateway loads
-- here unchanged.
--
-- nginx runs several worker processes, so a process-global table (the Rust
-- model) is not enough. Storage order is:
--   1. ngx.shared.luarouter_config   (declared by core server.conf, if present)
--   2. LMR_CONFIG_FILE               (atomic rewrite, read back with a short TTL)
--   3. env defaults                  (LMR_* baseline)
-- Writes update all available layers so every worker sees the change.
--
-- Outbound control-plane HTTP (the /props probe) also lives here, as a
-- dependency-free cosocket client: _M.raw_request. The model-map proxy that used
-- to ride on it is gone with the watcher merge (doc/gap-watcher-merge.md):
-- /_ui/config/model-map calls resty.luarouter.watcher in process, so there is no
-- external watcher URL left to point at.
-- props.lua reuses it rather than requiring lua-resty-http, which the image is
-- not guaranteed to ship.

--
-- 2026-10-05 拆分（doc/refactor-arch-2026-10-05.md §1）：本文件是 facade，实现住在
-- resty.luarouter.config_store.{lexicon,env,profiles,persistence,upstreams,snapshot,
-- readers,mutators,httpc,handlers}。函数体逐字搬家；这里只做 require 与 68 个导出的逐一
-- re-export（_M 导出名集合、函数签名、返回值形状逐名保留，含按名字被 UI / 文档 / 单测
-- 钉着的刻意空壳）。shdict / 后端 / 文件 IO 一律只在 persistence 里。

local _M = {}
package.loaded["resty.luarouter.config_store"] = _M  -- 预登记：子模块加载期可回指同一张表

local CS_LEXICON = require "resty.luarouter.config_store.lexicon"
local CS_ENV = require "resty.luarouter.config_store.env"
local CS_PROFILES = require "resty.luarouter.config_store.profiles"
local CS_PERSISTENCE = require "resty.luarouter.config_store.persistence"
local CS_UPSTREAMS = require "resty.luarouter.config_store.upstreams"
local CS_SNAPSHOT = require "resty.luarouter.config_store.snapshot"
local CS_READERS = require "resty.luarouter.config_store.readers"
local CS_MUTATORS = require "resty.luarouter.config_store.mutators"
local CS_HTTPC = require "resty.luarouter.config_store.httpc"
local CS_HANDLERS = require "resty.luarouter.config_store.handlers"

-- lexicon
_M._reset_pool_module_caches = CS_LEXICON._reset_pool_module_caches
_M.effort_levels = CS_LEXICON.effort_levels
_M.normalize_effort = CS_LEXICON.normalize_effort
_M.normalize_policy = CS_LEXICON.normalize_policy
_M.policy_names = CS_LEXICON.policy_names

-- env
_M.ENV_NAMES = CS_ENV.ENV_NAMES
_M.capture_env = CS_ENV.capture_env
_M.env = CS_ENV.env
_M.env_upstreams = CS_ENV.env_upstreams
_M.reset_env_upstreams_cache = CS_ENV.reset_env_upstreams_cache

-- persistence
_M.is_store_conflict = CS_PERSISTENCE.is_store_conflict
_M.migrate_once = CS_PERSISTENCE.migrate_once
_M.persist = CS_PERSISTENCE.persist
_M.policy_revision = CS_PERSISTENCE.policy_revision
_M.refresh_store_rev = CS_PERSISTENCE.refresh_store_rev
_M.store = CS_PERSISTENCE.store
_M.upstreams_reconcile_due = CS_PERSISTENCE.upstreams_reconcile_due
_M.upstreams_revision = CS_PERSISTENCE.upstreams_revision

-- upstreams
_M.reconcile_upstreams = CS_UPSTREAMS.reconcile_upstreams

-- snapshot
_M.cfg_from_document = CS_SNAPSHOT.cfg_from_document
_M.snapshot_of = CS_SNAPSHOT.snapshot_of

-- readers
_M.card_supports_tool_use = CS_READERS.card_supports_tool_use
_M.card_effort_ladder = CS_READERS.card_effort_ladder
_M.ctx_cap = CS_READERS.ctx_cap
_M.current = CS_READERS.current
_M.entry_declaration = CS_READERS.entry_declaration
_M.env_defaults = CS_READERS.env_defaults
_M.env_policy = CS_READERS.env_policy
_M.modalities_for = CS_READERS.modalities_for
_M.model_policies_list = CS_READERS.model_policies_list
_M.models_virtual_only = CS_READERS.models_virtual_only
_M.policy_document = CS_READERS.policy_document
_M.policy_global_override = CS_READERS.policy_global_override
_M.policy_override_active = CS_READERS.policy_override_active
_M.policy_override_for = CS_READERS.policy_override_for
_M.request_effort_for = CS_READERS.request_effort_for
_M.resolve_model = CS_READERS.resolve_model
_M.resolve_policy = CS_READERS.resolve_policy
_M.virtual_ctx_cap = CS_READERS.virtual_ctx_cap
_M.virtual_models_list = CS_READERS.virtual_models_list
_M.virtual_targets = CS_READERS.virtual_targets

-- mutators
_M.apply_ctx = CS_MUTATORS.apply_ctx
_M.apply_document = CS_MUTATORS.apply_document
_M.apply_effort = CS_MUTATORS.apply_effort
_M.apply_model_config = CS_MUTATORS.apply_model_config
_M.apply_policy = CS_MUTATORS.apply_policy
_M.apply_profiles = CS_MUTATORS.apply_profiles
_M.apply_upstreams = CS_MUTATORS.apply_upstreams
_M.apply_virtual_models = CS_MUTATORS.apply_virtual_models
_M.profile_effort = CS_MUTATORS.profile_effort
_M.profile_for = CS_MUTATORS.profile_for
_M.profile_policy = CS_MUTATORS.profile_policy
_M.profiles_list = CS_MUTATORS.profiles_list

-- httpc
_M.raw_request = CS_HTTPC.raw_request

-- handlers
_M.document = CS_HANDLERS.document
_M.handle_config_apply = CS_HANDLERS.handle_config_apply
_M.handle_config_ctx = CS_HANDLERS.handle_config_ctx
_M.handle_config_effort = CS_HANDLERS.handle_config_effort
_M.handle_config_get = CS_HANDLERS.handle_config_get
_M.handle_config_model = CS_HANDLERS.handle_config_model
_M.handle_config_model_map = CS_HANDLERS.handle_config_model_map
_M.handle_config_policy = CS_HANDLERS.handle_config_policy
_M.handle_config_policy_get = CS_HANDLERS.handle_config_policy_get
_M.handle_config_upstreams = CS_HANDLERS.handle_config_upstreams
_M.handle_config_virtual = CS_HANDLERS.handle_config_virtual
_M.models_document = CS_HANDLERS.models_document
_M.read_json_body = CS_HANDLERS.read_json_body
_M.respond_apply_error = CS_HANDLERS.respond_apply_error
_M.respond_json = CS_HANDLERS.respond_json

return _M
