#!/usr/bin/env python3
# 单路 vs 双路聚合：受控负载对照基准（swift-1.5，21.k:8034/8035 + 网关 8801）。
#
# 三方对照，隔离「双路聚合收益」与「网关转发/调度损耗」两个因素：
#   single    : 所有并发请求全打一台引擎（8034）——基线，1 台 max-concurrency 上限。
#   rr2       : 第 i 个请求轮流打 8034/8035——「理想双路」，无网关开销，验证聚合上限≈2×。
#   gateway   : 所有请求打网关 8801（真名 swift-1.5…），由 cache_aware 调度到两台——真实路径。
#
# 负载：
#   decode        短随机前缀 + 长 max_tokens → 纯解码扩展性（双路收益应≈2×）。
#   prefill       每请求不同长前缀 + 短生成 → 纯 prefill 算力扩展性（两台无共享 KV，看是否打折）。
#   sharedprefill 所有请求共享一个长前缀 + 短生成 → 多用户同 RAG 文档；双路时同一前缀两台各缓存一份。
#
# 全程只读，不改任何配置。聚合口径：
#   per-request tok/s = completion_tokens / 单请求墙钟（每批取中位）。
#   aggregate tok/s   = 批次内 Σcompletion_tokens / 批次墙钟。
#   ttft_ms           = 首个 content/reasoning delta 相对请求发出的时间（每批取中位）。
# 用法（在 21.k 上）：python3 bench-swift-single-vs-dual.py [--modes single,rr2,gateway]
#     [--workloads decode,prefill,sharedprefill] [--conc 1,2,4,8] [--reps 2]
import argparse, json, time, urllib.request, uuid, threading, statistics

HOST = "127.0.0.1"
ENGINE_A = ("http://%s:8034/v1/chat/completions" % HOST)
ENGINE_B = ("http://%s:8035/v1/chat/completions" % HOST)
GATEWAY  = ("http://%s:8801/v1/chat/completions" % HOST)
MODEL = "swift-1.5-qwen3.8-flash-next-nvfp4"
WORD = "The quarterly infrastructure report for the Q38 fleet covers serving capacity. "

def make_prompt(kind, shared_prefix):
    if kind == "decode":
        return uuid.uuid4().hex[:16] + " In one flowing paragraph explain cache locality. "
    if kind == "prefill":
        body = WORD * 3000                       # ~15-20k tokens, unique per request via uuid head
        return uuid.uuid4().hex + " " + body + " Summarize in one word."
    if kind == "sharedprefill":
        return shared_prefix + uuid.uuid4().hex[:8] + " Answer with the single word OK."
    raise ValueError(kind)

def one(url, prompt, maxtok, out, idx):
    body = {"model": MODEL, "messages": [{"role": "user", "content": prompt}],
            "max_tokens": maxtok, "temperature": 0, "reasoning_effort": "low",
            "stream": True, "stream_options": {"include_usage": True}}
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time(); ttft = None; usage = {}
    try:
        r = urllib.request.urlopen(req, timeout=600)
        for line in r:
            s = line.decode("utf-8", "replace").strip()
            if not s.startswith("data:"):
                continue
            s = s[5:]
            if s == "[DONE]":
                break
            try:
                j = json.loads(s)
            except Exception:
                continue
            if ttft is None:
                ch = (j.get("choices") or [{}])[0]
                d = ch.get("delta") or {}
                if d.get("content") or d.get("reasoning_content"):
                    ttft = time.time() - t0
            if j.get("usage"):
                usage = j["usage"]
    except Exception as e:
        out[idx] = {"err": repr(e)[:120]}; return
    el = time.time() - t0
    comp = usage.get("completion_tokens") or usage.get("output_tokens") or 0
    out[idx] = {"el": el, "ttft": ttft, "comp": comp,
               "tps": (comp / el if comp and el > 0 else 0)}

def run_batch(urls_for, prompts, maxtok, conc):
    out = [None] * conc
    th = []
    wall0 = time.time()
    for i in range(conc):
        t = threading.Thread(target=one, args=(urls_for(i), prompts[i], maxtok, out, i))
        th.append(t); t.start()
    for t in th:
        t.join()
    wall = time.time() - wall0
    ok = [r for r in out if r and "tps" in r]
    if not ok:
        return {"conc": conc, "n_ok": 0, "err": (out[0] or {}).get("err")}
    tps = sorted(r["tps"] for r in ok)
    ttfts = sorted(r["ttft"] for r in ok if r["ttft"] is not None)
    tot_comp = sum(r["comp"] for r in ok)
    return {"conc": conc, "n_ok": len(ok),
            "req_tps_p50": round(statistics.median(tps), 1),
            "req_tps_p10": round(tps[max(0, int(len(tps)*0.1))], 1),
            "agg_tps": round(tot_comp / wall, 1),
            "ttft_ms_p50": round(statistics.median(ttfts)*1000, 0) if ttfts else None,
            "tot_comp": tot_comp}

def urls_for(mode, i):
    if mode == "single":  return ENGINE_A
    if mode == "rr2":     return ENGINE_A if i % 2 == 0 else ENGINE_B
    if mode == "gateway": return GATEWAY
    raise ValueError(mode)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--modes", default="single,rr2,gateway")
    ap.add_argument("--workloads", default="decode,prefill,sharedprefill")
    ap.add_argument("--conc", default="1,2,4,8")
    ap.add_argument("--reps", type=int, default=2)
    a = ap.parse_args()
    concs = [int(x) for x in a.conc.split(",")]
    # max_tokens per workload: decode long, prefill/shared short
    mt = {"decode": 512, "prefill": 48, "sharedprefill": 48}
    shared_prefix = WORD * 3500                    # the shared RAG-style doc
    print("model=%s  engines=%s/%s  gateway=8801  conc=%s reps=%d"
          % (MODEL, "8034", "8035", concs, a.reps), flush=True)
    print("%-14s %-8s %4s %10s %10s %10s %10s" %
          ("workload", "mode", "conc", "req_tps50", "req_tps10", "agg_tps", "ttft_ms"), flush=True)
    print("-"*76, flush=True)
    for wl in a.workloads.split(","):
        for mode in a.modes.split(","):
            rows = []
            for conc in concs:
                prompts = [make_prompt(wl, shared_prefix) for _ in range(max(concs))]
                best = None
                for _ in range(a.reps):
                    r = run_batch(lambda i, m=mode: urls_for(m, i), prompts, mt[wl], conc)
                    if r.get("n_ok") and (best is None or r["agg_tps"] > best["agg_tps"]):
                        best = r
                if best is None:
                    print("%-14s %-8s %4d  ALL-ERR" % (wl, mode, conc), flush=True); continue
                rows.append((conc, best))
                print("%-14s %-8s %4d %10s %10s %10s %10s" %
                      (wl, mode, conc, best["req_tps_p50"], best["req_tps_p10"],
                       best["agg_tps"], best["ttft_ms_p50"]), flush=True)
            # scaling note
            if len(rows) >= 2:
                a1 = rows[0][1]["agg_tps"]; aN = rows[-1][1]["agg_tps"]
                print("%-14s %-8s  scaling %d->%d conc: agg %s -> %s (%.2fx)" %
                      (wl, mode, rows[0][0], rows[-1][0], a1, aN, (aN/a1 if a1 else 0)), flush=True)
            print("", flush=True)

if __name__ == "__main__":
    main()
