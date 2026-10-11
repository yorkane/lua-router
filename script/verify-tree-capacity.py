#!/usr/bin/env python3
# verify-tree-capacity.py — 只读验证 SMG_MAX_TREE_SIZE 容量能否同时留住 N 条超长会话。
# 用法: python3 verify-tree-capacity.py <port> [n_sessions] [chars_per_session] [idle_secs]
#   默认 n_sessions=8 chars=600000 idle=260（两轮 SMG_EVICTION_INTERVAL_SECS=120 之上）。
# 全程只读: 只 GET /logs /metrics + 自造推理请求; 不改任何配置/容器。
import json, urllib.request, time, sys

HOST = "127.0.0.1"
MODEL = "swift-1.5-qwen3.8-flash-next-nvfp4"
UNIT = "Keep this long document block warm on the same inference instance so the prefix cache is reused across turns. "

def filler(n):
    return UNIT * (n // len(UNIT) + 1)

def logs(port, limit=1200):
    return json.load(urllib.request.urlopen(
        "http://%s:%s/logs?limit=%d" % (HOST, port, limit), timeout=25)).get("requests", [])

def selected_for(port, mark):
    for r in reversed(logs(port)):
        if mark in str(r.get("prompt_preview")) and r.get("selected"):
            return r.get("selected")
    return None

def gauges(port):
    t = urllib.request.urlopen("http://%s:%s/metrics" % (HOST, port), timeout=10).read().decode("utf-8", "replace")
    out = {}
    for line in t.splitlines():
        for k in ("smg_cache_aware_tree_chars", "smg_cache_aware_tree_nodes", "smg_cache_aware_tenant_count"):
            if line.startswith(k + " "):
                out[k] = line.split()[1]
    return out

def hit(port, prompt):
    body = {"model": MODEL, "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 1, "temperature": 0, "reasoning_effort": "low"}
    t0 = time.time()
    try:
        j = json.loads(urllib.request.urlopen(urllib.request.Request(
            "http://%s:%s/v1/chat/completions" % (HOST, port),
            data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}),
            timeout=600).read().decode())
    except Exception as e:
        return None, repr(e)[:100], round(time.time() - t0, 2)
    t = j.get("timings") or {}
    return t.get("cache_n"), None, round(time.time() - t0, 2)

def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "8801"
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 8
    chars = int(sys.argv[3]) if len(sys.argv) > 3 else 600000
    idle = int(sys.argv[4]) if len(sys.argv) > 4 else 260
    base = "CAP" + hashlib_mark()
    prompts = []
    for i in range(n):
        m = "%s%02d" % (base, i)
        prompts.append((m, m + filler(chars) + "\nAnswer with the single word OK."))
    print("port=%s n=%d chars/session=%d total~=%d idle=%ds" %
          (port, n, chars, n * chars, idle), flush=True)
    warm = {}
    for i, (m, p) in enumerate(prompts):
        hit(port, p)            # cold prefill, seeds affinity
        c, err, el = hit(port, p)  # warm: should hit cache
        sel = selected_for(port, m)
        warm[m] = sel
        print("  warm[%d] sel=%s cache_n=%s el=%.2fs %s" % (i, sel, c, el, err or ""), flush=True)
    print("gauges after warm: %s" % json.dumps(gauges(port)), flush=True)
    print("idle %ds across %d eviction sweeps..." % (idle, idle // 120), flush=True)
    time.sleep(idle)
    switched = 0; cold = 0
    for i, (m, p) in enumerate(prompts):
        c, err, el = hit(port, p)
        sel = selected_for(port, m)
        bad = (sel != warm[m]) or (c == 0)
        if sel != warm[m]: switched += 1
        if c == 0: cold += 1
        print("  check[%d] sel=%s (was %s) cache_n=%s %s%s" %
              (i, sel, warm[m], c, "SWITCHED " if sel != warm[m] else "", "COLD" if c == 0 else ""), flush=True)
    print("gauges after idle: %s" % json.dumps(gauges(port)), flush=True)
    verdict = "CAPACITY-OK (all %d sessions held)" % n if (switched == 0 and cold == 0) \
        else "DEFICIT: switched=%d cold=%d of %d" % (switched, cold, n)
    print("RESULT: %s" % verdict, flush=True)

def hashlib_mark():
    import hashlib
    return hashlib.md5(str(time.time()).encode()).hexdigest()[:10]

if __name__ == "__main__":
    main()
