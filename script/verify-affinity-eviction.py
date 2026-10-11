#!/usr/bin/env python3
# verify-affinity-eviction.py
# 只读复现：长上下文会话在 cache_aware 亲和树被 LRU 淘汰后是否被甩到另一台引擎。
# 用法（在 21.k 上跑）：python3 verify-affinity-eviction.py [port_a port_b]
#   默认 port_a=8801(生产同款 SMG_MAX_TREE_SIZE=50000) port_b=8802(缺省 64M，对照组)。
#   两个实例必须挂同一对后端引擎（8034/8035）。
# 全程只读：只做 GET /logs /workers /metrics + 自造推理请求，不改任何配置或容器状态。
import json, urllib.request, time, hashlib, sys, statistics

HOST = "127.0.0.1"
MODEL = "swift-1.5-qwen3.8-flash-next-nvfp4"
SWIFT_PORTS = ("8034", "8035")
IDLE_SECS = 260          # > 两轮 SMG_EVICTION_INTERVAL_SECS(120)
N_PER_PHASE = 3
MIN_CHARS = 80000        # 单条路由文本就 > 生产每租户字符上限(50000)


def filler_chars(n):
    # ~ "Keep this document warm on the same instance so the prefix cache is reused. "
    unit = "Keep this document block warm on the same inference instance so the prefix cache is reused. "
    return unit * (n // len(unit) + 1)


def get(url, timeout=25):
    return json.load(urllib.request.urlopen(url, timeout=timeout))


def gauges(port):
    txt = urllib.request.urlopen("http://%s:%s/metrics" % (HOST, port), timeout=10).read().decode("utf-8", "replace")
    out = {}
    for line in txt.splitlines():
        for key in ("smg_cache_aware_tree_chars", "smg_cache_aware_tree_nodes", "smg_cache_aware_tenant_count"):
            if line.startswith(key + " "):
                out[key] = line.split()[1]
    return out


def hit(port, prompt, label):
    body = {"model": MODEL, "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 1, "temperature": 0, "reasoning_effort": "low"}
    url = "http://%s:%s/v1/chat/completions" % (HOST, port)
    t0 = time.time()
    try:
        j = json.loads(urllib.request.urlopen(
            urllib.request.Request(url, data=json.dumps(body).encode(),
                                   headers={"Content-Type": "application/json"}),
            timeout=600).read().decode())
    except Exception as e:
        print("  %-3s %s ERR %s" % (port, label, repr(e)[:120]), flush=True)
        return None, None
    t = j.get("timings") or {}
    el = time.time() - t0
    print("  %-4s %-3s el=%6.2fs prompt_n=%-6s cache_n=%-6s" %
          (port, label, el, t.get("prompt_n"), t.get("cache_n")), flush=True)
    return t.get("prompt_n"), t.get("cache_n")


def selected_for_mark(port, mark, limit=400):
    try:
        d = get("http://%s:%s/logs?limit=%d" % (HOST, port, limit))
    except Exception:
        return []
    rows = [r for r in d.get("requests", []) if mark in str(r.get("prompt_preview"))]
    return [r.get("selected") for r in rows]


def run_phase(port, prompt, mark):
    print("==== %s phase-A: %d hits back-to-back ====" % (port, N_PER_PHASE), flush=True)
    for i in range(N_PER_PHASE):
        hit(port, prompt, "A%d" % i)
        time.sleep(1)
    print("==== %s idle %ds (>=2 eviction sweeps) ====" % (port, IDLE_SECS), flush=True)
    time.sleep(IDLE_SECS)
    print("==== %s phase-B: %d hits after sweeps (gauges=%s) ====" %
          (port, N_PER_PHASE, json.dumps(gauges(port))), flush=True)
    cold = 0
    for i in range(N_PER_PHASE):
        _, cache_n = hit(port, prompt, "B%d" % i)
        if cache_n == 0:
            cold += 1
        time.sleep(1)
    sel = selected_for_mark(port, mark)
    verdict = "AFFINITY-BROKEN (cold re-prefill after eviction)" if cold else "affinity held"
    print("  %s phase-B selected=%s  cold(B*)=%d/%d -> %s" %
          (port, sel, cold, N_PER_PHASE, verdict), flush=True)
    return sel, cold


def main():
    a = sys.argv[1] if len(sys.argv) > 1 else "8801"
    b = sys.argv[2] if len(sys.argv) > 2 else "8802"
    # shared long prefix; unique mark so /logs rows are attributable to this run
    mark = "AFFEV" + hashlib.md5(str(time.time()).encode()).hexdigest()[:12]
    prompt = mark + filler_chars(MIN_CHARS) + "\nAnswer with the single word OK."
    print("mark=%s chars=%d  (SMG_MAX_TREE_SIZE on A is typically 50000, on B the code default)"
          % (mark, len(prompt)), flush=True)
    res = {}
    # run A then B; note warm-prefix cross-talk is expected and itself informative
    for port in (a, b):
        m = mark + port
        p = m + filler_chars(MIN_CHARS) + "\nAnswer with the single word OK."
        res[port] = run_phase(port, p, m)
    print("\n================ summary ================", flush=True)
    for port, (sel, cold) in res.items():
        print("port %s: phase-B cold=%d, selected=%s" % (port, cold, sel))
    print("\nInterpretation: the instance whose phase-B goes cold / flips engine is the one"
          " whose affinity leaves are being LRU-evicted (too-small SMG_MAX_TREE_SIZE)."
          " Raising it (or dropping the env to the code default) is the fix.", flush=True)


if __name__ == "__main__":
    main()
