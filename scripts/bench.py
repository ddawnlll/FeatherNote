#!/usr/bin/env python3
"""Reproducible loopback benchmark for FeatherNote.

Measures real request latency, response sizes and /proc RSS/PSS. This is not a
synthetic microbenchmark: it drives the compiled server over TCP exactly as a
browser would, using one persistent session and plain HTTP.

Usage:
  python3 scripts/bench.py --binary zig-out/bin/feathernote --requests 200
"""
import argparse
import http.client
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASSWORD = "benchmark owner password 123"


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def wait_healthy(port, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
            c.request("GET", "/healthz")
            r = c.getresponse()
            ok = r.status == 200 and r.read() == b"ok\n"
            c.close()
            if ok:
                return True
        except OSError:
            time.sleep(0.02)
    return False


class Client:
    def __init__(self, port):
        self.port = port
        self.cookies = {}

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=60)
        hdrs = dict(headers or {})
        if body is not None:
            hdrs.setdefault("Content-Type", "application/x-www-form-urlencoded")
        if self.cookies:
            hdrs["Cookie"] = "; ".join(f"{k}={v}" for k, v in self.cookies.items())
        conn.request(method, path, body=body, headers=hdrs)
        r = conn.getresponse()
        data = r.read()
        hs = {k.lower(): v for k, v in r.getheaders()}
        for k, v in r.getheaders():
            if k.lower() == "set-cookie":
                first = v.split(";", 1)[0]
                if "=" in first:
                    name, val = first.split("=", 1)
                    if "max-age=0" in v.lower() or not val:
                        self.cookies.pop(name, None)
                    else:
                        self.cookies[name] = val
        conn.close()
        return r.status, hs, data

    def post_form(self, path, fields):
        return self.request("POST", path, urllib.parse.urlencode(fields))


def csrf_of(html):
    m = re.search(rb'name="csrf" value="([0-9a-f]{64})"', html)
    return m.group(1).decode() if m else None


def version_of(html):
    m = re.search(rb'name="version" value="(\d+)"', html)
    return int(m.group(1)) if m else None


def percentile(values, p):
    if not values:
        return None
    ordered = sorted(values)
    idx = min(len(ordered) - 1, max(0, int(round((p / 100.0) * (len(ordered) - 1)))))
    return ordered[idx]


def proc_status(pid):
    out = {}
    for line in open(f"/proc/{pid}/status"):
        if ":" in line:
            k, v = line.split(":", 1)
            out[k.strip()] = v.strip()
    return out


def rss_kib(pid):
    return int(proc_status(pid).get("VmRSS", "0 KiB").split()[0])


def hwm_kib(pid):
    return int(proc_status(pid).get("VmHWM", "0 KiB").split()[0])


def pss_kib(pid):
    try:
        for line in open(f"/proc/{pid}/smaps_rollup"):
            if line.startswith("Pss:"):
                return int(line.split()[1])
    except OSError:
        return None
    return None


def cpu_ticks(pid):
    fields = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
    return int(fields[11]) + int(fields[12])


def start(binary, db, port, log):
    f = open(log, "ab")
    p = subprocess.Popen(
        [binary, "serve", "--db", db, "--listen", f"127.0.0.1:{port}", "--insecure-cookies"],
        cwd=ROOT, stdout=f, stderr=subprocess.STDOUT,
    )
    if not wait_healthy(port):
        p.kill()
        raise RuntimeError("server failed to start")
    return p


def stop(p):
    p.terminate()
    try:
        p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait(timeout=5)


def measure(fn, n, warmup=10):
    for _ in range(warmup):
        fn()
    samples = []
    for _ in range(n):
        t0 = time.perf_counter()
        fn()
        samples.append((time.perf_counter() - t0) * 1000.0)
    return samples


def concurrent_measure(fn, n, concurrency):
    threads = []
    results = [[] for _ in range(concurrency)]
    per = max(1, n // concurrency)

    def worker(i):
        for _ in range(per):
            t0 = time.perf_counter()
            fn()
            results[i].append((time.perf_counter() - t0) * 1000.0)

    for i in range(concurrency):
        t = threading.Thread(target=worker, args=(i,))
        threads.append(t)
        t.start()
    for t in threads:
        t.join()
    return [x for group in results for x in group]


def summarize(samples):
    return {
        "n": len(samples),
        "p50_ms": round(percentile(samples, 50), 3),
        "p95_ms": round(percentile(samples, 95), 3),
        "p99_ms": round(percentile(samples, 99), 3),
        "max_ms": round(max(samples), 3),
    }


def run_scenario(binary, count, body_size, requests, concurrency, outdir):
    work = os.path.join(outdir, f"seed-{count}")
    os.makedirs(work, exist_ok=True)
    db_path = os.path.join(work, "feather.db")
    log_path = os.path.join(work, "server.log")
    branch = subprocess.run([binary, "admin", "integrity", "--db", db_path],
                            cwd=ROOT, capture_output=True)
    # integrity on a new DB creates the schema; a fresh DB reports ok.
    if branch.returncode != 0:
        raise RuntimeError(branch.stderr.decode())
    subprocess.run([binary, "admin", "set-password", "--db", db_path],
                   input=(PASSWORD + "\n").encode(), check=True, cwd=ROOT,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "seed.py"),
                    "--db", db_path, "--count", str(count), "--body-size", str(body_size), "--clear"],
                   check=True, stdout=subprocess.DEVNULL)

    port = free_port()
    proc = start(binary, db_path, port, log_path)
    result = {"notes": count, "body_size": body_size, "pid": proc.pid}
    try:
        client = Client(port)
        t0 = time.perf_counter()
        status, headers, _ = client.post_form("/login", {"password": PASSWORD})
        login_ms = (time.perf_counter() - t0) * 1000.0
        assert status == 303, status
        result["login_ms"] = round(login_ms, 3)
        result["hwm_after_login_kib"] = hwm_kib(proc.pid)

        _, _, body = client.request("GET", "/notes")
        note_url = "/notes/1"
        _, _, edit = client.request("GET", note_url)
        csrf = csrf_of(edit)
        version = version_of(edit)
        assert csrf and version, "could not read note form"

        # Save path uses increasing versions so every request commits.
        save_state = {"version": version}

        def do_save():
            payload = urllib.parse.urlencode({
                "csrf": csrf, "title": "Benchmark note", "body": "save payload " + "y" * 1024,
                "version": save_state["version"],
            })
            status, _, _ = client.request("POST", note_url, payload)
            assert status == 303, status
            save_state["version"] += 1

        get_samples = measure(lambda: client.request("GET", note_url), requests)
        list_samples = measure(lambda: client.request("GET", "/notes"), requests)
        search_url = "/notes?q=" + urllib.parse.quote("needle-42")
        search_samples = measure(lambda: client.request("GET", search_url), requests)
        save_samples = measure(do_save, max(20, requests // 2), warmup=3)
        result["hwm_after_saves_kib"] = hwm_kib(proc.pid)

        result["get_note"] = summarize(get_samples)
        result["list"] = summarize(list_samples)
        result["search"] = summarize(search_samples)
        result["save"] = summarize(save_samples)

        conc = {}
        for n in concurrency:
            def fn():
                status, _, _ = client.request("GET", note_url)
                assert status == 200
            conc[str(n)] = summarize(concurrent_measure(fn, requests, n))
        result["get_note_concurrency"] = conc

        idle_rss = rss_kib(proc.pid)
        idle_pss = pss_kib(proc.pid)
        time.sleep(2)
        idle_rss2 = rss_kib(proc.pid)
        idle_pss2 = pss_kib(proc.pid)
        tick0 = cpu_ticks(proc.pid)
        time.sleep(5)
        tick1 = cpu_ticks(proc.pid)
        hertz = os.sysconf("SC_CLK_TCK")
        result["idle_rss_kib"] = idle_rss2
        result["idle_pss_kib"] = idle_pss2
        result["rss_after_requests_kib"] = idle_rss
        result["pss_after_requests_kib"] = idle_pss
        result["idle_cpu_seconds_per_5s"] = round((tick1 - tick0) / hertz, 4)
        result["hwm_kib"] = hwm_kib(proc.pid)

        _, headers, css_body = client.request("GET", "/style.css")
        result["css_bytes"] = len(css_body)
        _, headers, list_body = client.request("GET", "/notes")
        result["list_html_bytes_50"] = len(list_body)
        result["binary_bytes"] = os.path.getsize(binary)

        # Max-size note body peak.
        big = "z" * (256 * 1024)
        new_status, new_headers, _ = client.post_form("/notes", {"csrf": csrf, "title": "Big", "body": big})
        assert new_status == 303
        result["hwm_after_256k_note_kib"] = hwm_kib(proc.pid)
        t0 = time.perf_counter()
        status, _, _ = client.post_form("/notes", {"csrf": csrf, "title": "Big2", "body": big})
        result["big_note_post_ms"] = round((time.perf_counter() - t0) * 1000.0, 3)
        assert status == 303

        # cgroup 128 MiB test if the current shell can create one.
        result["cgroup_128m"] = try_cgroup(binary, db_path, port)

    finally:
        stop(proc)
    return result


def try_cgroup(binary, db_path, port):
    _ = (binary, db_path, port)
    base = "/sys/fs/cgroup"
    if not os.access(base, os.W_OK):
        return "UNVERIFIED (cgroup v2 root is not writable by this user)"
    try:
        return "UNVERIFIED (cgroup root writable, but this harness does not re-exec into a scope)"
    except OSError as exc:
        return f"UNVERIFIED ({exc.__class__.__name__}: {exc})"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=os.path.join(ROOT, "zig-out", "bin", "feathernote"))
    ap.add_argument("--requests", type=int, default=200)
    ap.add_argument("--counts", default="100,10000")
    ap.add_argument("--body-size", type=int, default=1024)
    ap.add_argument("--concurrency", default="1,2,8")
    ap.add_argument("--out", default=os.path.join(ROOT, "reports", "benchmarks-raw.json"))
    args = ap.parse_args()
    binary = os.path.abspath(args.binary)
    counts = [int(x) for x in args.counts.split(",")]
    conc = [int(x) for x in args.concurrency.split(",")]
    outdir = tempfile.mkdtemp(prefix="feathernote-bench-", dir=os.path.join(ROOT, ".jcode-test") if os.path.isdir(os.path.join(ROOT, ".jcode-test")) else None)

    results = []
    for count in counts:
        print(f"running scenario notes={count} ...", flush=True)
        r = run_scenario(binary, count, args.body_size, args.requests, conc, outdir)
        results.append(r)
        print(json.dumps(r, indent=2), flush=True)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    payload = {
        "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "machine": {
            "cpu": open("/proc/cpuinfo").read().split("model name", 1)[-1].splitlines()[0].split(":", 1)[-1].strip(),
            "kernel": os.uname().release,
            "python": sys.version.split()[0],
        },
        "results": results,
    }
    with open(args.out, "w") as f:
        json.dump(payload, f, indent=2)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
