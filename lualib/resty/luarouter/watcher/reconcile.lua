local _M = require "resty.luarouter.watcher"
local env_mod = require "resty.luarouter.watcher.env"

-- watcher/reconcile.lua -- the guards single decision point.  The whole
-- reconcile() function lives here *undivided*: the comment above it in the
-- original (watcher.lua 1394-1399) is exactly why -- "why did that
-- worker leave" must have one answer site.  The probe-verdict
-- pre-pass (decide the whole pass before the first delete), the fuse
-- denominator (the owned total read before deletions shrink it) and the
-- hysteresis counters interlock; splitting this further would break the
-- auditability doc/gap-watcher-merge.md 1.1 pins.  Do not decompose this
-- file.

-- ------------------------------------------------------------------ reconcile
--
-- What the daemon does here and the Lua version does not: a *mixed-model warning*.
-- The daemon logged one because the Rust gateway ignores the requested model when it
-- picks a worker in single-router mode (README measured 10/10 requests naming the
-- local model served by a remote one), so a heterogeneous pool silently mis-routes.
-- This router cannot mis-route that way - candidates_for(model) filters by
-- record.model_id (router.lua:987), and a request naming an unregistered model gets a
-- 404 rather than a random worker - so the warning has nothing to warn about and was
-- deliberately not ported. doc/gap-watcher-merge.md lists it as the one README
-- behaviour with no Lua counterpart.

local function warn(log, message)
    if type(log) == "function" then
        log("warn", message)
    end
end

local function notice(log, message)
    if type(log) == "function" then
        log("notice", message)
    end
end

---Is `url` the only remaining worker of `model_id`? (_is_last_for_model)
---An unhealthy sibling does not count as coverage.
---@param model_id string
---@param url string
---@param actual table @ url -> {model_id=, is_healthy=}
---@return boolean
function _M.is_last_for_model(model_id, url, actual)
    if not model_id or model_id == "" then
        return true
    end
    for other_url, item in pairs(actual or {}) do
        if other_url ~= url and tostring(item.model_id or "") == model_id then
            if item.is_healthy ~= false then
                return false
            end
        end
    end
    return true
end

---Confirm the adds we queued and release the stuck ones (guard 7).
---
---The daemon had to wait for the router's async AddWorker job: a 202 only meant
---"queued", and a job parked on a dead URL squatted the URL forever (every retry
---said "already exists"), so it deleted the worker to free it. Registration here
---is a direct registry.add, so a worker is live the moment we return; what is
---still worth reaping is a ledger entry whose URL has left the pool behind our
---back (a hand DELETE, or an add that never landed), which would otherwise keep
---the URL claimed and the model advertised as if it had a worker.
---@param state table @ {cfg, ledger, now, actual}
---@return table @ live pending urls (still waiting, excluded from this pass)
function _M.reap_pending(state)
    local ledger, now, actual = state.ledger, state.now, state.actual
    local live = {}
    for url, pending in pairs(ledger.pending_urls()) do
        if actual[url] then
            -- Confirmed: the pool carries it, so the ledger takes the live id.
            ledger.drop_pending(url)
            ledger.drop_backoff(url)
            local entry = ledger.get_owned(url)
            if entry then
                entry.worker_id = tostring(actual[url].id or entry.worker_id or "")
                entry.missing_since = nil
                ledger.set_owned(url, entry, state.entry_ttl)
            end
        else
            local age = now - tonumber(pending.queued_at or now)
            if age <= state.cfg.add_confirm_timeout_secs then
                live[url] = true
            else
                notice(state.log, string.format(
                    "watcher: add for %s never reached the pool after %.0fs; releasing the URL",
                    url, age))
                -- The id the add returned may still be in the pool under a
                -- different URL spelling (a DP expansion replaces the base
                -- entry): registry.remove answers "not found" for anything gone,
                -- so trying is safe and releases the URL either way.
                if pending.worker_id then
                    state.unregister(tostring(pending.worker_id))
                end
                ledger.drop_pending(url)
                ledger.drop_owned(url)
                state.stats.adds_stuck_released = state.stats.adds_stuck_released + 1
            end
        end
    end
    return live
end

---Is this URL's pool row a config_store-declared upstream? Config members are
---immune to every watcher mutation: no ledger reclaim, no keep-last clearing,
---no model-map rename, no removal (doc/gap-virtual-models.md 3.2). The live
---pool row is the authority, so a URL whose row vanished is *not* immune (the
---removal loops need to clean the ledger entry the old way).
---@param state table
---@param url string
---@return boolean
function _M.is_config_member(state, url)
    local live = state.actual[url]
    return type(live) == "table" and live.discovery == "config"
end

---One-line DEBUG summary for a skipped config member, through the testable
---state.log sink so the pure layer stays ngx-free.
---@param state table
---@param url string
---@param action string
local function note_config_skip(state, url, action)
    if state.log then
        state.log("debug", string.format(
            "watcher: skipping config-declared upstream %s (%s; config_store owns it)",
            url, action))
    end
end

_M.note_config_skip = note_config_skip

---One reconcile pass. Everything outside this function is plumbing, which makes
---the guards above auditable in one place and testable with fakes -- including the
---probe-verdict pre-pass below, which deliberately stays inside this function so
---"why did that worker leave" has exactly one answer site.
---
---@param state table @ {cfg, ledger, actual, candidates, probe, register,
---                       unregister, now, stats, log}
---@return table @ the (mutated) stats
function _M.reconcile(state)
    local cfg, ledger, now = state.cfg, state.ledger, state.now
    local stats = state.stats
    stats.reconciles = stats.reconciles + 1

    -- Guard 3: on first contact every worker already in the pool was configured
    -- by someone else (SMG_WORKER_URLS or a human), so protect it permanently.
    if not ledger.touched() then
        local protected = ledger.protected_urls()
        local owned = ledger.owned_urls()
        if next(protected) == nil and next(owned) == nil then
            for url in pairs(state.actual) do
                ledger.protect(url)
            end
            ledger.mark_touched()
            if next(state.actual) ~= nil then
                notice(state.log, string.format("watcher: protecting %d pre-existing worker(s)",
                    (function()
                        local n = 0
                        for _ in pairs(state.actual) do n = n + 1 end
                        return n
                    end)()))
            end
        end
    end

    -- Discovery + strict probe.
    local discovered = {}
    -- A URL we looked at and could not confirm is not "absent from discovery": the
    -- strict probe wants a real /v1/models answer with data[].id, and without that
    -- the service cannot answer a request. What we must NOT do is treat every
    -- rejection as the same evidence, so the set carries classify()'s reason and the
    -- verdict derived from it (see probe_verdict): a deterministic "this is not a
    -- worker" answer evicts in the same pass, a transport-level unknown accumulates
    -- entry.probe_fails and only evicts once it repeats.
    local probe_failed = {}
    -- Reasons that say more about the gateway than about the service (no transport,
    -- require_health admission): this pass says nothing about the URL, so the entry
    -- keeps its missing_since clock and its counter untouched.
    local probe_ignore = {}
    for i = 1, #state.candidates do
        local cand = state.candidates[i]
        if cand and cand.url and not _M.is_self_url(cand.url, cfg.self_ports)
            and not _M.is_excluded(cand.url, cfg.exclude_patterns) then
            local info, reason = state.probe(cand.url)
            if info then
                info.label = cand.label or info.engine
                info.source = cand.source
                info.gpu = cand.gpu
                -- 卡号进台账：g| 键与 register/protect 无关，所以保护行（bootstrap 播种的
                -- SMG_WORKER_URLS 那八个）也拿得到。认不出卡时同样调用一次 —— 传 nil 是
                -- 删键，免得上一轮容器改名后留下过期卡号，把好端端的读数接到别的卡上。
                if ledger.set_gpu_hint then
                    ledger.set_gpu_hint(cand.url, cand.gpu)
                end
                discovered[#discovered + 1] = info
            else
                local verdict = _M.probe_verdict(reason)
                if verdict then
                    probe_failed[cand.url] = { reason = reason, verdict = verdict }
                else
                    probe_ignore[cand.url] = true
                end
            end
        end
    end
    stats.discovered = #discovered

    -- desired = discovered - protected (guard 3 again, from the other side).
    local desired, protected_seen = {}, {}
    for i = 1, #discovered do
        local info = discovered[i]
        if ledger.is_protected(info.url) then
            protected_seen[info.url] = info
        else
            desired[info.url] = info
        end
    end

    local pending_live = _M.reap_pending(state)

    ---A URL with a queued add is claimed, whatever its stage in this pass.
    local function pending_now(url)
        return pending_live[url] or ledger.get_pending(url) ~= nil
    end

    -- Adds.
    for _, url in ipairs(env_mod.sorted_keys(desired)) do
        if not state.actual[url] and not pending_live[url] then
            local entry = desired[url]
            local model_id = _M.model_name(entry.models[1], state.model_map, cfg.short_model_names)
            local fail_until = ledger.get_backoff(url)
            if fail_until and now < tonumber(fail_until.until_ts or 0) then
                -- in back-off after a rejected add
            else
                local worker_id, err = state.register(url, model_id, entry)
                if not worker_id then
                    stats.add_fails = stats.add_fails + 1
                    local n = ((ledger.get_backoff(url) or {}).n or 0) + 1
                    ledger.set_backoff(url, n, now)
                    warn(state.log, string.format("watcher: add %s failed: %s",
                        url, tostring(err)))
                else
                    stats.adds = stats.adds + 1
                    ledger.drop_backoff(url)
                    ledger.set_pending(url, { queued_at = now, worker_id = worker_id },
                        cfg.add_confirm_timeout_secs + cfg.interval_secs)
                    ledger.set_owned(url, {
                        model_id = model_id,
                        worker_id = worker_id,
                        engine = entry.engine,
                        source = entry.source,
                        label = entry.label,
                        added_at = now,
                    }, state.entry_ttl)
                    notice(state.log, string.format("watcher: registered %s as model %q (engine %s)",
                        url, model_id, entry.engine))
                end
            end
        end
    end

    -- Renames: a map (or short-model-names) change has to reach the pool, which
    -- means recycling the entry so the next pass re-adds it under the new id.
    -- Owned workers go through their ledger entry; protected ones have no entry,
    -- and dropping their protection is what hands ownership over (same trick as
    -- the daemon's eviction hand-off).
    for _, url in ipairs(env_mod.sorted_keys(desired)) do
        if not pending_now(url) and state.actual[url] then
            local info = desired[url]
            local want = _M.model_name(info.models[1], state.model_map, cfg.short_model_names)
            local have = tostring(state.actual[url].model_id or "")
            local entry = ledger.get_owned(url)
            if entry and entry.model_id ~= want and have ~= want then
                if _M.is_config_member(state, url) then
                    note_config_skip(state, url, "rename")
                else
                    notice(state.log, string.format("watcher: rename %s (registered %q, want %q)",
                        url, have, want))
                    _M.release(state, url, entry, 0, "rename")
                end
            end
        end
    end
    for _, url in ipairs(env_mod.sorted_keys(protected_seen)) do
        if not pending_now(url) and state.actual[url] then
            local info = protected_seen[url]
            local want = _M.model_name(info.models[1], state.model_map, cfg.short_model_names)
            local have = tostring(state.actual[url].model_id or "")
            if have ~= "" and have ~= want and _M.is_config_member(state, url) then
                note_config_skip(state, url, "model-map rename")
            elseif have ~= "" and have ~= want then
                notice(state.log, string.format(
                    "watcher: rename of protected %s (registered %q, want %q); adopting it",
                    url, have, want))
                ledger.unprotect(url)
                if state.unregister(tostring(state.actual[url].id or "")) then
                    stats.removes = stats.removes + 1
                else
                    ledger.protect(url)   -- keep the promise if the delete failed
                end
            end
        end
    end

    -- Removals: only from our own ledger (guard 4).
    --
    -- Probe verdicts are decided for the whole pass *before* the first delete. Two
    -- reasons: the fuse compares "how many rows the probes want gone" against the
    -- owned total, and that denominator cannot be read after deletions started
    -- shrinking it; and the hysteresis arithmetic belongs in one place so the loop
    -- below stays the audit of the eight guards rather than a second decision tree.
    -- probe_verdict_of maps url -> {verdict="release"|"bump", reason=, fails=};
    -- anything absent from it is not a probe eviction candidate this pass.
    local owned = ledger.owned_urls()
    -- math.floor so a fractional env value cannot silently shorten the wait, and
    -- 0/negative collapses to 1: that is the operator's explicit "evict at once".
    local fail_threshold = math.floor(tonumber(cfg.probe_failures) or 2)
    if fail_threshold < 1 then
        fail_threshold = 1
    end
    local probe_verdict_of, probe_evicting = {}, 0
    for _, url in ipairs(env_mod.sorted_keys(owned)) do
        local entry = owned[url]
        local failed = entry and not desired[url] and state.actual[url]
            and probe_failed[url]
        -- Config members belong to config_store and a URL absent from probe_failed
        -- was never dialled this pass (the undiscovered grace owns it); both stay out
        -- of the tally, so a verdict can neither feed the fuse that would spare it nor
        -- get blamed for the delete that could not remove it.
        if failed and not _M.is_config_member(state, url) then
            if failed.verdict == "reject" then
                probe_verdict_of[url] = { verdict = "release", reason = failed.reason }
                probe_evicting = probe_evicting + 1
            else
                local fails = (tonumber(entry.probe_fails) or 0) + 1
                if fails >= fail_threshold then
                    probe_verdict_of[url] = {
                        verdict = "release", reason = failed.reason, fails = fails }
                    probe_evicting = probe_evicting + 1
                else
                    probe_verdict_of[url] = {
                        verdict = "bump", reason = failed.reason, fails = fails }
                end
            end
        end
    end

    -- Single-pass fuse (guard 10). A gateway-wide failure -- cosocket exhaustion,
    -- DNS, a kernel or timer problem that starves every probe of its budget -- makes
    -- every service on the box look dead at once, and the strict probe would
    -- obediently empty the pool in one interval. Losing more than half of owned
    -- workers to a probe verdict in a single pass is far more likely to be the
    -- gateway than the fleet, so the pass degrades to warn-only and waits for a
    -- second opinion; the counters keep climbing, so a real fleet-wide outage still
    -- evicts as soon as the premise (a transient gateway fault) stops holding.
    --
    -- The >= 2 floor is what keeps a one-worker deployment honest: a single row that
    -- fails a *deterministic* probe really is a zombie, and sparing it would mean the
    -- strict probe could never evict anything on a one-worker box.
    local owned_total = 0
    for _, entry in pairs(owned) do
        if entry then
            owned_total = owned_total + 1
        end
    end
    -- allow_remove=false means nothing was ever going to be deleted, so claiming the
    -- fuse "kept" them would describe a rescue that never happened.
    local fuse_on = cfg.allow_remove and cfg.probe_fuse ~= false
        and probe_evicting >= 2 and probe_evicting * 2 > owned_total
    if fuse_on then
        stats.probe_fuse_skips = (stats.probe_fuse_skips or 0) + probe_evicting
        warn(state.log, string.format(
            "watcher: probe fuse kept %d/%d owned workers this pass (the probes condemned more than half the pool; suspect a gateway-wide probe failure, SMG_WATCHER_PROBE_FUSE=0 disables the fuse)",
            probe_evicting, owned_total))
    end

    ---Carry out this pass's probe decision for one owned entry.
    ---@param url string
    ---@param entry table
    local function probe_evict(url, entry)
        local decided = probe_verdict_of[url]
            or { verdict = "release", reason = (probe_failed[url] or {}).reason }
        -- A transport-level unknown is one observation per pass whether or not this
        -- pass acts on it: the counter is what the hysteresis decides with, and the
        -- metrics series is what tells an operator "the probes are unhappy" before any
        -- worker is gone. It is written back in the keep-it branches too, so a pass
        -- spared by the fuse still climbs toward the threshold and the survivors
        -- evict the moment the fuse's premise (a transient gateway fault) lapses --
        -- without the run ever having to restart from zero.
        if decided.fails then
            stats.probe_failures = (stats.probe_failures or 0) + 1
            entry.probe_fails = decided.fails
        end
        if decided.verdict == "bump" then
            ledger.set_owned(url, entry, state.entry_ttl)
            -- Unlike the other keep-it branches this one may log every round: the
            -- wait is bounded by the threshold, and an engine that starts timing out
            -- should leave a trace the moment it starts, one pass before it costs the
            -- pool a worker.
            warn(state.log, string.format(
                "watcher: %s failed the strict /v1/models probe (%d/%d): %s; keeping it",
                url, tonumber(decided.fails) or 0, fail_threshold,
                tostring(decided.reason or "unknown")))
        elseif fuse_on then
            -- The pass-level warn already named the count; per-entry silence rides on
            -- entry.warned, the same mute every other keep-it branch uses, and it is
            -- cleared as soon as the service answers a probe again.
            if not entry.warned then
                warn(state.log, string.format(
                    "watcher: %s fails the strict /v1/models probe but the pass fuse is on; keeping it",
                    url))
                entry.warned = true
                ledger.set_owned(url, entry, state.entry_ttl)
            end
        else
            stats.probe_removes = (stats.probe_removes or 0) + 1
            -- The classify() reason travels verbatim into the log line, because "the
            -- probe said no" is only actionable when an operator can tell *which* no
            -- it said: the strict probe's "it answered the wrong thing" versus the
            -- undiscovered branch's "it stopped answering at all".
            _M.release(state, url, entry, 0,
                "probe failed (no /v1/models): " .. tostring(decided.reason or "unknown"))
        end
    end

    for _, url in ipairs(env_mod.sorted_keys(owned)) do
        local entry = ledger.get_owned(url)
        if entry then
            if desired[url] then
                -- The entry is rewritten on every pass that still sees the worker,
                -- which is what renews its lr_watch ttl. Skipping the write in the
                -- steady state would let a long-lived worker's entry age out (the
                -- ledger lives in a shared dict with a TTL as a leak guard), and an
                -- owned URL with no entry is invisible to the removal loop below:
                -- the worker would keep its pool row after the service died for
                -- good, which is precisely the zombie the daemon exists to prevent.
                entry.missing_since = nil
                entry.warned = nil
                -- The hysteresis clock resets at the same place as the warn mute: a
                -- service that answers the probe again is no longer in a failure run,
                -- so "up-down-up-down" cannot accumulate toward a threshold it would
                -- never reach if each flap started from zero.
                entry.probe_fails = nil
                ledger.set_owned(url, entry, state.entry_ttl)
                -- Guard 8: a router restart/reload re-creates workers with fresh
                -- ids, so keep the recorded id in step with the pool.
                local live = state.actual[url]
                if live and live.id and tostring(live.id) ~= tostring(entry.worker_id) then
                    entry.worker_id = tostring(live.id)
                    ledger.set_owned(url, entry, state.entry_ttl)
                end
            elseif not state.actual[url] then
                -- Gone from the pool and from discovery: forget it, nothing to delete.
                ledger.drop_owned(url)
                ledger.drop_pending(url)
            elseif _M.is_config_member(state, url) then
                -- The row outlived the ledger's knowledge because someone
                -- re-declared the URL as a config upstream: neither the
                -- missing_since clock nor the delete may run against it. The
                -- ledger forgets its claim so the member is config-owned, end
                -- of story (watcher stop-owning, not watcher-delete).
                note_config_skip(state, url, "reclaim")
                ledger.drop_owned(url)
                ledger.drop_pending(url)
                ledger.drop_backoff(url)
            elseif probe_ignore[url] then
                -- 本轮对这条 URL 什么都没说出口：探针压根没拨通（no probe transport，
                -- 网关侧的装配或 cosocket 限流），或它给的理由是注册准入开关
                -- require_health 的产物（/health 404 的引擎有一大半）。这类结论既不能
                -- 计入滞回也不能走 missing_since 宽限——否则打开 SMG_WATCHER_REQUIRE_HEALTH
                -- 的操作员会让每个不实现 /health 的引擎陷入摘-加循环，网关自己的 socket
                -- 抖动也会被记成"这个 worker 死了"。条目原样留着，等下一轮的真结论。
            elseif probe_failed[url] then
                -- Confirmed unavailable, not merely undiscovered: the strict probe
                -- reached the service and could not read a usable model list from it.
                -- Such a row answers 5xx while advertising a model it cannot serve, so
                -- it does not get the undiscovered grace or the keep-last exemption --
                -- how soon it leaves is decided by probe_evict above, which is where
                -- the reject/count split, the hysteresis threshold and the fuse all
                -- live. Recovery stays the normal path: the first round that reads a
                -- real /v1/models re-adds it through the same add gates.
                --
                -- 摘除开关仍然排在探针结论前面：SMG_WATCHER_ALLOW_REMOVE=0 是操作员
                -- "只许加不许删"的明确约定，探针结论再确定也不能替他们做删除的决定，
                -- 否则严格探针就成了绕过这道保险的后门（首次实现就是直接 release，
                -- 于是关掉摘除的服务仍然被删）。这里沿用下方 undiscovered 分支的
                -- 形态：保留 pool 行、只警告一次，靠 entry.warned 静音后续轮次，
                -- 避免每个 interval 刷一条同样的 warn。warned 会在服务重新被探到
                -- 时（desired 分支）清掉，所以"恢复后再坏"仍会再提醒一次。
                if not cfg.allow_remove then
                    if not entry.warned then
                        warn(state.log, string.format(
                            "watcher: %s fails the strict /v1/models probe but removal is disabled; keeping it",
                            url))
                        entry.warned = true
                        ledger.set_owned(url, entry, state.entry_ttl)
                    end
                else
                    probe_evict(url, entry)
                end
            else
                local first_missing = tonumber(entry.missing_since)
                if not first_missing then
                    entry.missing_since = now
                    ledger.set_owned(url, entry, state.entry_ttl)
                    first_missing = now
                end
                local age = now - first_missing
                if not cfg.allow_remove then
                    if age >= cfg.remove_grace_secs and not entry.warned then
                        warn(state.log, string.format(
                            "watcher: %s has been undiscovered for %.0fs but removal is disabled",
                            url, age))
                        entry.warned = true
                        ledger.set_owned(url, entry, state.entry_ttl)
                    end
                elseif age < cfg.remove_grace_secs then
                    -- Guard 5: a short restart is the health sweep's job, not ours.
                elseif cfg.keep_last_grace_secs >= 0
                    and _M.is_last_for_model(tostring(entry.model_id or ""), url, state.actual) then
                    -- Guard 6: never empty a model, but do not keep a permanently
                    -- stopped service serving 5xx either.
                    if not (cfg.keep_last_grace_secs > 0 and age >= cfg.keep_last_grace_secs) then
                        if not entry.warned then
                            warn(state.log, string.format(
                                "watcher: %s gone %.0fs but it is the last worker of model %q; keeping it",
                                url, age, tostring(entry.model_id)))
                            entry.warned = true
                            ledger.set_owned(url, entry, state.entry_ttl)
                        end
                    else
                        notice(state.log, string.format(
                            "watcher: %s gone %.0fs and it is the last worker of model %q (>= keep-last grace %.0fs); removing it",
                            url, age, tostring(entry.model_id), cfg.keep_last_grace_secs))
                        _M.release(state, url, entry, age, "keep-last expired")
                    end
                else
                    _M.release(state, url, entry, age, "undiscovered")
                end
            end
        end
    end

    return stats
end

---Delete one ledger-owned worker and forget the entry (the daemon's _remove).
---@param state table
---@param url string
---@param entry table
---@param age number
---@param reason string
---@return boolean ok
function _M.release(state, url, entry, age, reason)
    local worker_id = tostring(entry.worker_id or "")
    if worker_id == "" then
        warn(state.log, string.format("watcher: %s has no recorded worker id; cannot delete", url))
        return false
    end
    if not state.unregister(worker_id) then
        warn(state.log, string.format("watcher: remove %s failed", url))
        return false
    end
    state.stats.removes = state.stats.removes + 1
    state.ledger.drop_owned(url)
    state.ledger.drop_pending(url)
    state.ledger.drop_backoff(url)
    notice(state.log, string.format("watcher: removed %s (%s, gone %.0fs)", url, reason, age or 0))
    return true
end

return _M
