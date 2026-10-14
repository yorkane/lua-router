#!/usr/bin/env python3
"""SSE 断连清理探针（21.k CPU 事故的第一验收步骤）。

判据（doc/incident-21k-cpu-20261014.md：断连的 SSE 协程不退出 → 输出链不回收）：
nginx 的 access 行在 log 阶段写，请求结束才有。所以「客户端 RST/FIN 之后该请求
的 access 收尾行出现」= 协程真的退出了；收尾行数远低于断连数 = 泄漏。
CPU / RSS / 健康延迟作为佐证一起采，不单凭 CPU 定性。

用法（本地跑，脚本经 ssh stdin 在远端执行，全程只读，不 scp）：
  python3 script/verify-sse-cleanup.py --ssh 21.254.220.248 \
    --report /data/tmp/lr-sse-fix-1014/remote-probe/report.json
可选：--port 8802 --container lua-router-8802 --model swift-1.5-plefp8
      --seconds 60 --clients 13 --sudo

安全边界：远端只读 docker/cgroup/proc 与本机 HTTP；SSE 断连用 RST 与 FIN 各半；
推理请求只在显式 --flood N 时发（max_tokens=16，模型由 --model 指定）。日志流
通过 loopback 的既有免凭据路径访问，不携带代理来源头；401 时探针报 GATE。
响应帧只记类型与字节数，不落正文。
"""
import argparse
import concurrent.futures
import datetime
from http.client import HTTPConnection
import json
import os
import re
import socket
import struct
import subprocess
import sys
import time
import uuid

ACCESS_RE = re.compile(r'^(\S+) (\S+) (\S+) \[([^\]]+)\] "(\S+) ([^"]*?) HTTP/[0-9.]+" (\d{3}) (\S+)')


def sh(args, sudo=False, timeout=20):
    argv = (["sudo"] if sudo else []) + [str(a) for a in args]
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout).stdout


def http(host, port, path, method="GET", obj=None, timeout=10):
    conn = HTTPConnection(host, port, timeout=timeout)
    h = {"Host": "127.0.0.1"}
    body = None if obj is None else json.dumps(obj).encode()
    if body is not None:
        h["Content-Type"] = "application/json"
    try:
        conn.request(method, path, body=body, headers=h)
        res = conn.getresponse()
        return res.status, res.read()
    finally:
        conn.close()


def metrics(host, port):
    out = {"error": None}
    try:
        status, data = http(host, port, "/metrics", timeout=8)
        if status != 200:
            out["error"] = "http %d" % status
            return out
        text = data.decode("utf-8", "replace")
    except Exception as exc:  # noqa: BLE001 - saturation of the single worker shows up here
        out["error"] = repr(exc)[:180]
        return out
    for line in text.splitlines():
        if line.startswith("smg_http_inflight_requests "):
            out["inflight"] = float(line.split()[-1])
        elif line.startswith("smg_http_inflight_request_age_slots_active "):
            out["age_slots"] = float(line.split()[-1])
    return out


def cgroup_cpu_usec(container, sudo):
    cid = sh(["docker", "inspect", "-f", "{{.Id}}", container], sudo).strip()
    for path in ("/sys/fs/cgroup/system.slice/docker-%s.scope/cpu.stat" % cid,
                 "/sys/fs/cgroup/docker/%s/cpu.stat" % cid):
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    if line.startswith("usage_usec"):
                        return int(line.split()[1])
        except OSError:
            pass
    raise RuntimeError("cgroup v2 cpu.stat not readable for %s" % container)


def worker_rss_kb(container, sudo):
    rows = sh(["docker", "top", container, "-eo", "pid,args"], sudo).splitlines()
    values = []
    for row in rows:
        if "worker process" not in row:
            continue
        pid = row.split()[0]
        try:
            with open("/proc/%s/status" % pid, encoding="utf-8") as fh:
                for line in fh:
                    if line.startswith("VmRSS:"):
                        values.append(int(line.split()[1]))
        except OSError:
            pass
    return sum(values) if values else None


def health(host, port):
    t0 = time.monotonic()
    try:
        status, _ = http(host, port, "/health", timeout=8)
        return {"status": status, "latency_ms": round((time.monotonic() - t0) * 1000, 1)}
    except Exception as exc:  # noqa: BLE001
        return {"status": None, "latency_ms": round((time.monotonic() - t0) * 1000, 1),
                "error": repr(exc)[:120]}


def frame_kind(buf):
    """SSE 帧只按类型归类，绝不返回正文（可能含 prompt 预览）。"""
    s = buf.lstrip()
    if s.startswith(b"data:"):
        return "data"
    if s.startswith(b":"):
        return "ping"
    return "other"


def open_stream(host, port, path, wait_first):
    """建立 SSE 连接。收到响应头即算成功（/logs/stream 空闲时正文要等 15s ping，
    初装的 ngx.flush 只出头部框架）。返回 (socket, 状态行, 首帧类型, 首帧字节数)，
    首帧超时未到则类型为 None —— 流是活的，只是没有正文可发。"""
    s = socket.create_connection((host, port), timeout=8)
    try:
        s.sendall(("GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                   "Accept: text/event-stream\r\n\r\n" % path).encode())
        s.settimeout(wait_first)
        buf = b""
        head = None
        deadline = _deadline(wait_first)
        while time.monotonic() < deadline:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
            if b"\r\n\r\n" in buf:
                head, _, buf = buf.partition(b"\r\n\r\n")
                break
        if head is None:
            raise RuntimeError("no SSE response headers within %ds" % wait_first)
        status_line = head.split(b"\r\n", 1)[0].decode("latin1", "replace")
        if " 200 " not in status_line:
            raise RuntimeError("SSE status not 200: " + status_line)
        while b"\n\n" not in buf and time.monotonic() < deadline:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        if b"\n\n" in buf:
            first, _, _ = buf.partition(b"\n\n")
            return s, status_line, frame_kind(first), len(first)
        return s, status_line, None, 0
    except Exception:
        try:
            s.close()
        except OSError:
            pass
        raise


def _deadline(secs):
    return time.monotonic() + secs


def rst_close(s):
    s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    s.close()


def fin_close(s):
    try:
        s.shutdown(socket.SHUT_WR)
    except OSError:
        pass
    s.close()


def access_rows(container, sudo, since_s, path, not_before=None, marker=None):
    """docker logs 里的 access 收尾行（nginx access.log -> /dev/stdout）。
    行内容含 IP/UA/正文引用，绝不回传原文；解析时间为 epoch 用于窗口过滤。"""
    out = sh(["docker", "logs", "--since", "%ds" % since_s, container], sudo, timeout=40)
    rows = []
    for line in out.splitlines():
        m = ACCESS_RE.match(line)
        request_target = m.group(6) if m else ""
        if m and request_target.split("?", 1)[0] == path and (marker is None or ("sse_probe=" + marker + "-") in request_target):
            try:
                ts = datetime.datetime.strptime(m.group(4), "%d/%b/%Y:%H:%M:%S %z").timestamp()
            except ValueError:
                ts = None
            if not_before is not None and ts is not None and ts < not_before:
                continue
            rows.append({"ts": ts, "method": m.group(5),
                         "status": int(m.group(7)), "bytes": m.group(8)})
    return rows


def run_probe(a):
    host, port = "127.0.0.1", a.port
    mark = "SSEFIX" + uuid.uuid4().hex[:8]
    rep = {"target": {"host": host, "port": port, "container": a.container,
                      "image": sh(["docker", "inspect", "-f", "{{.Config.Image}}",
                                   a.container], a.sudo).strip()},
           "args": {k: getattr(a, k) for k in
                    ("seconds", "clients", "model", "flood", "endpoint", "sudo")},
           "mark": mark, "checks": {}, "endpoints": {}, "samples": []}

    # 1) 端点可达性：/logs/stream 在管理口令已配且来源非 loopback 时 401（探针不猜凭据）。
    probes = []
    for path in a.endpoint:
        try:
            s, status_line, kind, nbytes = open_stream(host, port, path, a.first_frame_timeout)
            rep["endpoints"][path] = {"status_line": status_line,
                                      "first_frame_kind": kind,
                                      "first_frame_bytes": nbytes}
            probes.append((path, s))
        except Exception as exc:  # noqa: BLE001
            rep["endpoints"][path] = {"error": repr(exc)[:160]}
    rep["checks"]["gate"] = ("OPEN" if probes else
                             "BLOCKED(401: /logs/stream 需要管理口令；带 --admin-basic 或 loopback 免凭据)")
    if not probes:
        rep["verdict"] = "GATE"
        return rep
    open_paths = [p for p, _ in probes]
    abort_path = open_paths[0]
    rep["checks"]["abort_endpoint"] = abort_path

    # 2) 基线（CPU 速率 + 健康 + RSS + metrics）。
    cpu0 = cgroup_cpu_usec(a.container, a.sudo)
    t0 = time.time()
    time.sleep(a.baseline_secs)
    cpu1 = cgroup_cpu_usec(a.container, a.sudo)
    rep["baseline"] = {"cpu_cores": round((cpu1 - cpu0) / ((time.time() - t0) * 1e6), 4),
                       "health": health(host, port),
                       "worker_rss_kb": worker_rss_kb(a.container, a.sudo),
                       "metrics": metrics(host, port)}

    # 3) 断连队列：先留一条健康流（对照组，要求端点支持正文帧），其余 RST/FIN 各半。
    healthy = None
    healthy_path = "/logs/stream" if "/logs/stream" in open_paths else open_paths[0]
    for path, s in probes:
        if path == healthy_path and healthy is None:
            healthy = s
            continue
        rst_close(s)
    n = max(2, a.clients)
    t_abort = time.time()
    def abort(i):
        try:
            s, _, _, _ = open_stream(host, port, abort_path + "?sse_probe=" + mark + "-" + str(i), a.first_frame_timeout)
        except Exception:  # noqa: BLE001 - 单条建流失败记数不中断
            return False
        (rst_close if i % 2 == 0 else fin_close)(s)
        return True
    ok = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(n, 16)) as pool:
        for r in pool.map(lambda i: (i, abort(i)), range(n)):
            ok += 1 if r[1] else 0
    rep["checks"]["aborts"] = {"clients": ok, "requested": n,
                               "rst": (n + 1) // 2, "fin": n // 2,
                               "endpoint": abort_path}
    n = max(1, ok)

    # 4) 断连后日志泵（可选）：只给 max_tokens=16 的小请求，制造合法日志事件。
    if a.flood:
        sent = {"ok": 0, "err": 0}
        body = {"model": a.model, "max_tokens": 16, "temperature": 0,
                "messages": [{"role": "user", "content": mark + " ping"}]}
        for _ in range(a.flood):
            try:
                st, _ = http(host, port, "/v1/chat/completions", "POST", body, timeout=90)
                sent["ok" if 200 <= st < 300 else "err"] += 1
            except Exception:  # noqa: BLE001
                sent["err"] += 1
            time.sleep(0.5)
        rep["checks"]["flood"] = sent
        rep["checks"]["flood_model"] = a.model

    # 5) 观察窗：CPU 逐窗速率、健康延迟、RSS、metrics；健康流计数。
    hs = {"events": 0, "pings": 0, "bytes": 0, "closed_early": False, "read_error": None}
    end = time.monotonic() + a.seconds
    prev_cpu, prev_t = cgroup_cpu_usec(a.container, a.sudo), time.time()
    while time.monotonic() < end:
        time.sleep(min(5, max(0.2, end - time.monotonic())))
        now = time.time()
        cpu = cgroup_cpu_usec(a.container, a.sudo)
        window_cores = (cpu - prev_cpu) / max(1e-6, (now - prev_t) * 1e6)
        prev_cpu, prev_t = cpu, now
        if healthy is not None:
            try:
                healthy.settimeout(0.05)
                chunk = healthy.recv(8192)
                if chunk:
                    hs["bytes"] += len(chunk)
                    hs["events"] += chunk.count(b"data:")
                    hs["pings"] += chunk.count(b": ping")
                else:
                    hs["closed_early"] = True
            except socket.timeout:
                pass
            except OSError as exc:  # noqa: BLE001
                hs["read_error"] = repr(exc)[:120]
        rep["samples"].append({"t": round(now - t0, 1),
                               "cpu_cores": round(window_cores, 4),
                               "health": health(host, port),
                               "worker_rss_kb": worker_rss_kb(a.container, a.sudo),
                               "metrics": metrics(host, port)})
    if healthy is not None:
        fin_close(healthy)
    rep["healthy_stream"] = hs

    # 6) 收尾行核对：断连后窗口内该端点的 access 行数。
    # nginx 在 log 阶段写 access 行：handler 正常收尾是 200，nginx 自己因客户端
    # 断连终止请求是 499；断连的 SSE 协程若泄漏，请求永不进 log 阶段 → 没有行。
    # 所以「有行（200 或 499）」= 请求结束 = 清理干净。
    rows = access_rows(a.container, a.sudo, int(a.seconds + a.baseline_secs + a.first_frame_timeout + 15),
                       abort_path, not_before=t_abort - 1, marker=mark)
    closed = sum(1 for r in rows if r["status"] in (200, 499))
    rep["access_rows"] = {"count": len(rows), "ended": closed,
                          "statuses": sorted({r["status"] for r in rows})}
    last = rep["samples"][-1] if rep["samples"] else {}
    rep["after"] = {"cpu_cores": last.get("cpu_cores"), "health": last.get("health"),
                    "worker_rss_kb": last.get("worker_rss_kb"), "metrics": last.get("metrics")}

    def delta(key):
        b = rep["baseline"].get("metrics", {}).get(key)
        x = (last.get("metrics") or {}).get(key)
        return None if b is None or x is None else x - b
    infl_growth = delta("inflight")
    cores_first = rep["baseline"]["cpu_cores"]
    cores_last = last.get("cpu_cores") or 0
    rss0 = rep["baseline"].get("worker_rss_kb")
    rss1 = (last.get("worker_rss_kb"))
    rep["checks"].update({
        "closed_ratio": round(closed / n, 3),
        "inflight_growth": infl_growth,
        "cpu_cores_baseline": cores_first,
        "cpu_cores_after": cores_last,
        "rss_growth_kb": None if rss0 is None or rss1 is None else rss1 - rss0,
        "healthy_stream_alive": not hs["closed_early"],
        "healthy_stream_pings": hs["pings"],
    })
    # 判定：收尾行齐（>=80%）→ 协程退出；健康流活着且没堆积 → 干净。
    leak = closed < ok or ok != a.clients
    rep["checks"]["leak"] = bool(leak)
    cpu_worse = (cores_last > max(0.2, cores_first * 2) and cores_last > 0.3)
    rep["checks"]["cpu_worse_after_aborts"] = bool(cpu_worse)
    healthy_ok = not hs["closed_early"] and hs["read_error"] is None and (a.seconds < 16 or hs["pings"] > 0)
    endpoints_ok = len(open_paths) == len(a.endpoint)
    health_ok = all(s["health"].get("status") == 200 and s["health"].get("latency_ms", 9999) < 1000 for s in rep["samples"])
    flood_ok = not a.flood or rep["checks"].get("flood", {}).get("ok") == a.flood
    rep["checks"]["functional_pass"] = healthy_ok and endpoints_ok and health_ok and flood_ok
    rep["verdict"] = "LEAK" if leak else ("WARN-CPU" if cpu_worse else ("CLEAN" if rep["checks"]["functional_pass"] else "FAIL"))
    rep["limitations"] = [
        "access 收尾行按时间窗归属，同窗内的他人流量会计入（8802 是测试实例，噪声小）。",
        "klib 之外的 UI 路由不走 inflight 计数，inflight 增长只作旁证，主判据是收尾行。",
        "--seconds < 16 时健康流的 15s ping 观测不到，healthy_stream_pings=0 不算异常。"]
    return rep


def main():
    p = argparse.ArgumentParser(description="SSE 断连清理探针（只读；见文件头）")
    p.add_argument("--ssh", help="ssh 目标：把本文件原样管道过去，在远端对 127.0.0.1 执行")
    p.add_argument("--port", type=int, default=8802)
    p.add_argument("--container", default="lua-router-8802")
    p.add_argument("--endpoint", action="append",
                   help="SSE 端点，可重复；缺省 /logs/stream，建议加 /u/models/sse")
    p.add_argument("--clients", type=int, default=13, help="断连客户端数（缺省对齐取证 N=13）")
    p.add_argument("--seconds", type=int, default=60, help="断连后观察窗（秒）")
    p.add_argument("--baseline-secs", type=int, default=10)
    p.add_argument("--first-frame-timeout", type=int, default=31,
                   help="首帧上限秒数；要盖过 /logs/stream 的 15s ping 节拍")
    p.add_argument("--flood", type=int, default=0,
                   help="断连后发的 max_tokens=16 小请求条数（0=不发）")
    p.add_argument("--model", default="swift-1.5-plefp8",
                   help="--flood 使用的真实模型名；运行前确认该实例支持此 ID")
    p.add_argument("--sudo", action="store_true", help="docker/cgroup 读取需要 root 时加")
    p.add_argument("--report", help="JSON 报告落盘路径")
    a = p.parse_args()
    if not a.endpoint:
        a.endpoint = ["/logs/stream", "/u/models/sse"]
    if a.ssh:
        argv = ["python3", "-", "--port", str(a.port), "--container", a.container,
                "--clients", str(a.clients), "--seconds", str(a.seconds),
                "--baseline-secs", str(a.baseline_secs),
                "--first-frame-timeout", str(a.first_frame_timeout),
                "--flood", str(a.flood), "--model", a.model]
        for ep in a.endpoint:
            argv += ["--endpoint", ep]
        if a.sudo:
            argv.append("--sudo")
        # 远端把完整 JSON 报告写到同名路径（两台机器都有 /data/tmp），取回本地。
        remote_report = a.report if a.report and a.report.startswith("/data/tmp/") else None
        if remote_report:
            argv += ["--report", remote_report]
        proc = subprocess.run(["ssh", "-o", "BatchMode=yes", a.ssh] + argv,
                              input=open(__file__, encoding="utf-8").read(),
                              capture_output=True, text=True,
                              timeout=a.baseline_secs + a.seconds + 420)
        if proc.stderr.strip():
            sys.stderr.write(proc.stderr[-3000:] + "\n")
        payload, rc = proc.stdout, proc.returncode
        if remote_report:
            try:
                got = subprocess.run(["ssh", "-o", "BatchMode=yes", a.ssh,
                                      "cat", remote_report],
                                     capture_output=True, text=True, timeout=30)
                if got.returncode == 0 and got.stdout.strip().startswith("{"):
                    payload = got.stdout
            except Exception:  # noqa: BLE001 - 取回失败就退回紧凑行
                pass
    else:
        try:
            rep = run_probe(a)
            payload = json.dumps(rep, ensure_ascii=False, indent=2)
            rc = {"CLEAN": 0, "WARN-CPU": 1, "LEAK": 1, "FAIL": 1, "GATE": 3}[rep["verdict"]]
        except Exception as exc:  # noqa: BLE001
            payload = json.dumps({"verdict": "ERROR", "error": repr(exc)[:400]})
            rc = 2
    if a.report:
        os.makedirs(os.path.dirname(os.path.abspath(a.report)), exist_ok=True)
        with open(a.report, "w", encoding="utf-8") as fh:
            fh.write(payload + "\n")
    try:
        j = json.loads(payload)
        chk = j.get("checks", {})
        print(json.dumps({"verdict": j.get("verdict"),
                          "closed_ratio": chk.get("closed_ratio"),
                          "aborts": chk.get("aborts"),
                          "inflight_growth": chk.get("inflight_growth"),
                          "cpu": [chk.get("cpu_cores_baseline"), chk.get("cpu_cores_after")],
                          "rss_growth_kb": chk.get("rss_growth_kb"),
                          "healthy": {"alive": chk.get("healthy_stream_alive"),
                                      "pings": chk.get("healthy_stream_pings")},
                          "gate": chk.get("gate"), "error": j.get("error")},
                         ensure_ascii=False))
    except json.JSONDecodeError:
        sys.stdout.write(payload[-3000:])
    return rc


if __name__ == "__main__":
    sys.exit(main())
