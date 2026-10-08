#!/usr/bin/env python3
"""Probe-level checks: policy factory, re_split, raw JSON editor, snapshot write-back."""
import json, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (free_port, http, check, start_mock, mock_lines, start_router,
                  logs, stop_router, wait_ready, register, chat, cleanup,
                  probe_container, RESULTS, RUN, REPO)

start_probe = probe_container


# ---- 1. policy factory: every SMG_POLICY value must resolve to its own instance
names = ["random", "round_robin", "cache_aware", "power_of_two", "prefix_hash",
         "manual", "bucket", "consistent_hashing"]
for want in names:
    name = "lr-pf-%s-%s" % (want[:12], RUN)
    try:
        port = start_probe({"SMG_POLICY": want, "SMG_DISABLE_HEALTH_CHECK": "1"}, name)
    except Exception as e:
        check("[factory] %s boots" % want, False, e)
        continue
    st, body, _ = http("GET", "http://127.0.0.1:%d/probe/policy" % port)
    doc = json.loads(body) if st == 200 else {}
    standalone = want in ("cache_aware", "prefix_hash", "bucket", "consistent_hashing")
    check("[factory] SMG_POLICY=%s -> name=%s standalone=%s" % (want, want, standalone),
          st == 200 and doc.get("name") == want and doc.get("standalone") == standalone,
          "%s %s" % (st, body[:250]))
    stop_router(name)

# unknown policy still collapses
name = "lr-pf-bogus-" + RUN
port = start_probe({"SMG_POLICY": "definitely_not_a_policy"}, name)
st, body, _ = http("GET", "http://127.0.0.1:%d/probe/policy" % port)
# The default policy is cache_aware (config.lua one_of("SMG_POLICY",
# "cache_aware", POLICIES), Rust --policy default_value_t = CacheAware), so an
# unknown name collapses to the tree policy - not round_robin. The assertion used
# to pin the pre-default-fallback value and has been red ever since.
check("[factory] unknown policy falls back to the default cache_aware",
      json.loads(body).get("name") == "cache_aware", body[:200])
stop_router(name)

# ---- 1b. policy knobs parsed from the SMG_* names the Rust CLI uses
name = "lr-knobs-" + RUN
port = start_probe({"SMG_POLICY": "cache_aware", "SMG_CACHE_THRESHOLD": "0.75",
                    "SMG_BALANCE_ABS_THRESHOLD": "16", "SMG_BALANCE_REL_THRESHOLD": "1.2",
                    "SMG_MAX_TREE_SIZE": "5000", "SMG_PREFIX_TOKEN_COUNT": "64",
                    "SMG_PREFIX_HASH_LOAD_FACTOR": "1.5",
                    "SMG_BUCKET_ADJUST_INTERVAL_SECS": "7",
                    "LR_SNAPSHOT_MAX_BYTES": "4096",
                    "SMG_EVICTION_INTERVAL_SECS": "5"}, name)
st, body, _ = http("GET", "http://127.0.0.1:%d/probe/config" % port)
cfg = json.loads(body) if st == 200 else {}
check("[knobs] cache_threshold / balance thresholds",
      cfg.get("cache_threshold") == 0.75 and cfg.get("balance_abs_threshold") == 16
      and cfg.get("balance_rel_threshold") == 1.2 and cfg.get("max_tree_size") == 5000,
      json.dumps({k: cfg.get(k) for k in ("cache_threshold", "balance_abs_threshold",
                                          "balance_rel_threshold", "max_tree_size")}))
check("[knobs] prefix_hash + bucket + snapshot",
      cfg.get("prefix_token_count") == 64 and cfg.get("prefix_hash_load_factor") == 1.5
      and cfg.get("bucket_adjust_interval_secs") == 7 and cfg.get("snapshot_max_bytes") == 4096
      and cfg.get("eviction_interval_secs") == 5,
      json.dumps({k: cfg.get(k) for k in ("prefix_token_count", "prefix_hash_load_factor",
                                          "bucket_adjust_interval_secs", "snapshot_max_bytes")}))
# defaults are the Rust CLI defaults
stop_router(name)
name = "lr-knobd-" + RUN
port = start_probe({}, name)
st, body, _ = http("GET", "http://127.0.0.1:%d/probe/config" % port)
cfg = json.loads(body) if st == 200 else {}
check("[knobs] Rust CLI defaults (0.3 / 64 / 1.5 / 67108864)",
      cfg.get("cache_threshold") == 0.3 and cfg.get("balance_abs_threshold") == 64
      and cfg.get("balance_rel_threshold") == 1.5 and cfg.get("max_tree_size") == 67108864,
      json.dumps({k: cfg.get(k) for k in ("cache_threshold", "balance_abs_threshold",
                                          "balance_rel_threshold", "max_tree_size")}))
stop_router(name)

# ---- 2. re_split: multi-value LMR_*_MAP must parse (previously a 500 crash)
name = "lr-resplit-" + RUN
port = start_probe({"LMR_EFFORT_MAP": "low:medium,high:xhigh;minimal:low",
                    "LMR_MODEL_CTX": "alpha:128,beta:256",
                    "LMR_MODEL_EFFORT_MAP": "alpha:low>medium,beta:high>xhigh",
                    "LMR_MODEL_MODALITIES": "alpha:text+image,beta:text+video",
                    # 卡片档位勾选的 env 层（用户诉求 2026-10-08）。它跟着这一批一起设而不是
                    # 另起一份容器：这条断言真正钉的是**名册登记**（config_store.ENV_NAMES 里
                    # 那行），而名册只在 init_by_lua 的 capture_env 那一刻起作用 —— worker 里
                    # os.getenv 读不到未登记的名字。删掉那一行，这里读到的就是「没有这张卡」，
                    # 与「env 语法写错」两种失败在别处都无法区分（硬规则 11③）。
                    "LMR_MODEL_EFFORT_LEVELS": "alpha:low+medium+high,beta:max",
                    "LMR_VIRTUAL_MODELS": "alias-a:alpha,alias-b:beta",
                    "LMR_DEFAULT_EFFORT": "medium"}, name)
st, body, _ = http("GET", "http://127.0.0.1:%d/_ui/config" % port)
doc = json.loads(body) if st == 200 else {}
cfg = doc.get("config", doc) if isinstance(doc, dict) else {}


def pairs(section):
    return {(e.get("from") or e.get("model")): (e.get("to") or e.get("ctx") or e.get("target") or e.get("effort"))
            for e in (cfg.get(section) or [])}


em = pairs("effort_map")
check("[re_split] LMR_EFFORT_MAP 3 pairs parsed", st == 200
      and em == {"low": "medium", "high": "xhigh", "minimal": "low"}, "%s %s" % (st, body[:400]))
mc = pairs("model_ctx")
check("[re_split] LMR_MODEL_CTX 2 pairs parsed", mc == {"alpha": 128, "beta": 256},
      json.dumps(mc))
vm = pairs("virtual_models")
check("[re_split] LMR_VIRTUAL_MODELS 2 pairs parsed", vm == {"alias-a": "alpha", "alias-b": "beta"},
      json.dumps(vm))
mcards = {e.get("model"): e for e in (cfg.get("model_configs") or [])}
check("[re_split] LMR_MODEL_EFFORT_MAP per-model maps",
      mcards.get("alpha", {}).get("effort_map") == [{"from": "low", "to": "medium"}]
      and mcards.get("beta", {}).get("effort_map") == [{"from": "high", "to": "xhigh"}],
      json.dumps(mcards)[:400])
check("[re_split] LMR_MODEL_MODALITIES caps split",
      mcards.get("alpha", {}).get("modalities") == ["text", "image"]
      and mcards.get("beta", {}).get("modalities") == ["text", "video"],
      json.dumps({k: v.get("modalities") for k, v in mcards.items()})[:200])
def ladder_names(card_row):
    rows = (card_row or {}).get("reasoning_efforts")
    if not isinstance(rows, list):
        return None
    return [r.get("value") if isinstance(r, dict) else r for r in rows]


check("[env] LMR_MODEL_EFFORT_LEVELS reaches the worker (ENV_NAMES roster)",
      ladder_names(mcards.get("alpha")) == ["low", "medium", "high"]
      and ladder_names(mcards.get("beta")) == ["max"],
      json.dumps({k: ladder_names(v) for k, v in mcards.items()})[:240])
st, body, _ = http("GET", "http://127.0.0.1:%d/probe/env" % port)
check("[env] init snapshot present (capture_env ran)", '"cached_before": true' in body or
      json.loads(body).get("cached_before") is True, body[:200])
stop_router(name)

# ---- 3. raw JSON editor keeps the rest of the document intact
name = "lr-json-" + RUN
port = start_probe({}, name)
st, body, _ = http("GET", "http://127.0.0.1:%d/probe/json-edit" % port)
doc = json.loads(body) if st == 200 else {}
check("[json-edit] all edits decode", st == 200 and all(doc.get("decodes", {}).values())
      and len(doc.get("decodes", {})) >= 6, "%s %s" % (st, json.dumps(doc)[:400]))
check("[json-edit] string member replaced",
      '"reasoning_effort":"high"' in doc.get("set_string", "").replace(" ", ""),
      doc.get("set_string", ""))
check("[json-edit] number member replaced",
      '"max_tokens":128' in doc.get("set_number", "").replace(" ", ""), doc.get("set_number", ""))
check("[json-edit] removal leaves valid JSON",
      "reasoning_effort" not in doc.get("remove", "") and '{"' in doc.get("remove", ""),
      doc.get("remove", ""))
check("[json-edit] sole-member removal", doc.get("remove_only", "").strip() in ("{}", "{ }"),
      repr(doc.get("remove_only", "")))
check("[json-edit] empty object insert", doc.get("empty_object", "").replace(" ", "") == '{"model":"m"}',
      doc.get("empty_object", ""))
check("[json-edit] nested members untouched",
      doc.get("keep_nested") is True and doc.get("keep_tools") is True, json.dumps(doc)[:300])
stop_router(name)

failed = [r for r in RESULTS if not r[0]]
print("\n=== %d probe checks, %d failed ===" % (len(RESULTS), len(failed)))
for _, n, d in failed:
    print("FAILED: %s | %s" % (n, str(d)[:400]))
cleanup()
sys.exit(1 if failed else 0)
