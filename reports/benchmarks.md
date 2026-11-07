# FeatherNote benchmark report

**Date:** 2026-11-07 (UTC)
**Build:** `zig build --release=safe` (ReleaseSafe, stripped)
**Binary:** 2,406,040 bytes
**SQLite:** 3.54.1 amalgamation compiled from `vendor/sqlite/sqlite3.c`
**Zig:** 0.17.1
**Status:** P0 application targets measured and passing. Proxy, live HTTPS, and one-hour idle CPU remain UNVERIFIED below. Screenshots were later captured for documentation, but there is no pixel-diff regression harness.

## Environment

| Item | Value |
|---|---|
| CPU | Intel(R) Xeon(R) CPU E5-2680 v2 @ 2.80GHz (virtualized oVirt VM) |
| Kernel | 6.12.115+deb13.1-amd64 |
| OS | Debian 13 (trixie) |
| Storage | VM virtual disk; commands below are loopback only |
| Python client | 3.13.5, `http.client`, one TCP connection per request |
| Load | single-user, warm server, no reverse proxy |

Because the client opens a new TCP connection per request, the latency numbers include connection setup. A browser would reuse a connection, so these are conservative.

## Commands

```sh
zig build --release=safe
python3 scripts/bench.py --requests 200 --counts 100,10000 --concurrency 1,2,8
```

Raw evidence: `reports/benchmarks-raw.json`.

The benchmark:
1. Creates a fresh database, sets an Argon2id owner password, and seeds 1 KiB notes.
2. Starts the real server on a loopback port.
3. Logs in once, measures login latency and `VmHWM` immediately afterward.
4. Warms 10 requests, then measures 200 requests for note GET, list, search, and 100 for save.
5. Measures GET with 1, 2, and 8 concurrent client threads.
6. Reads `/proc/<pid>/status` and `/proc/<pid>/smaps_rollup` for RSS, PSS, and HWM.
7. Reads `/proc/<pid>/stat` across a 5-second idle window.
8. Posts a 256 KiB note once and records HWM again.
9. Measures CSS bytes, 50-row list HTML bytes, and binary size.

## Targets vs measured results

All latencies are milliseconds, loopback, 1 KiB note bodies.

| Metric | Target | 100 notes | 10,000 notes | Verdict |
|---|---:|---:|---:|---|
| Idle RSS | <= 12 MiB | 6.00 MiB (6148 KiB) | 6.61 MiB (6772 KiB) | **PASS** |
| Idle PSS | reported | 4.64 MiB (4751 KiB) | 5.11 MiB (5237 KiB) | **PASS** |
| Peak RSS (Argon2id login included) | separately recorded | 23.1 MiB (23688 KiB) | 23.4 MiB (23968 KiB) | **PASS, separate from idle** |
| Peak RSS after 256 KiB note | separately recorded | 23.1 MiB | 23.4 MiB | **PASS** |
| CSS | single embedded, cached stylesheet | 23,085 B (12 themes) | 23,085 B | **PASS, revised scope** |
| Mandatory JavaScript | 0 B | 0 B | 0 B | **PASS** |
| List HTML at 50 rows, excluding note content | <= 15 KiB | 8,914 B | 9,143 B | **PASS** |
| Warm GET note p95 | <= 15 ms | 3.20 ms | 1.09 ms | **PASS** |
| Save POST p95 | <= 50 ms | 9.14 ms | 10.58 ms | **PASS** |
| 10k search p95 | <= 100 ms | 4.73 ms (100 notes) | 4.23 ms | **PASS** |
| Login (Argon2id, password hash + session + redirect) | recorded | 133.7 ms | 57.8 ms | **PASS, recorded** |
| 256 KiB note POST (single sample) | recorded | 30.0 ms | 28.0 ms | **PASS** |
| Idle CPU | near zero | 0.0 s / 5 s | 0.0 s / 5 s | **PASS for 5 s; 1-hour UNVERIFIED** |
| 128 MiB cgroup, 10k notes | run under 128 MiB | — | see below | **PASS** |

The original 3 KiB CSS budget covered the single-theme P0 UI. The product
later added twelve themes at the owner's request, so the stylesheet is now
23,085 B. It remains one embedded, cacheable response rather than twelve
downloads, and no per-page CSS cost was added.

### Detailed percentiles

**100 notes**

| Path | p50 | p95 | p99 | max |
|---|---:|---:|---:|---:|
| GET note | 2.15 | 3.20 | 3.79 | 4.16 |
| List | 2.37 | 2.97 | 3.23 | 4.33 |
| Search | 3.53 | 4.73 | 5.58 | 7.11 |
| Save | 4.40 | 9.14 | 9.76 | 13.11 |

**10,000 notes**

| Path | p50 | p95 | p99 | max |
|---|---:|---:|---:|---:|
| GET note | 0.79 | 1.09 | 1.44 | 1.95 |
| List | 1.50 | 5.10 | 6.28 | 6.41 |
| Search | 3.20 | 4.23 | 4.78 | 4.85 |
| Save | 7.58 | 10.58 | 12.76 | 26.23 |

**Concurrent GET note**

| Concurrency | 100 notes p95 | 10,000 notes p95 |
|---:|---:|---:|
| 1 | 0.91 | 2.15 |
| 2 | 1.35 | 3.69 |
| 8 | 13.67 | 15.45 |

The 8-client case is bounded by Python thread scheduling and per-request TCP setup; the single SQLite connection serializes. It remains far below interactive thresholds.

## Search history and why FTS5 was added

The first implementation used parameterized `LIKE '%term%'`. On one 10,000-note run its p95 was **106.8 ms**, above the 100 ms gate. Per the monograph, schema v2 adds an external-content FTS5 index with `unicode61 remove_diacritics 2` and insert/update/delete triggers. User query terms are individually quoted and joined with `AND`, never passed as raw `MATCH` syntax. The final scenario measured **4.23 ms p95**. The LIKE implementation is gone; FTS5 is the production search path.

## 128 MiB cgroup test

The benchmark script could not create a cgroup because `/sys/fs/cgroup` is root-owned and this environment has no sudo. A systemd user scope was available, so the test was run manually:

```sh
systemd-run --user --scope -p MemoryMax=128M --unit=feathernote-cgtest \
  ./zig-out/bin/feathernote serve --db <10k-note-db> \
  --listen 127.0.0.1:18090 --insecure-cookies
```

Then, through a real HTTP session:

- login with Argon2id: 303;
- list 10,000 notes: 200;
- search `needle-42`: 200, correct result;
- create one 256 KiB note: 303;
- 30 additional 10k searches: all 200.

Observed cgroup counters:

```
memory.max      = 134217728   (128 MiB)
memory.peak     = 21508096    (20.51 MiB)
memory.current  = 2048000     (1.95 MiB)
VmHWM           = 23964 kB    (23.4 MiB)
VmRSS           = 5684 kB     (5.55 MiB)
```

**Verdict: PASS.** The application completed all operations while constrained to 128 MiB with a peak cgroup charge of about 20 MiB.

## Resource notes

- Idle RSS grows slightly from 100 to 10,000 notes (6.00 → 6.61 MiB) because SQLite pages and the FTS index are touched during the scenario. It remains far below the 12 MiB target.
- Peak RSS is dominated by the deliberate Argon2id 19 MiB memory cost. Idle and login peaks are separate gates, as required.
- The 10,000-note database was 14.1 MB on disk with 1 KiB bodies and the FTS index.
- No background timer, polling loop, websocket, or worker exists; the 5-second idle CPU delta was exactly 0 ticks.

## Unverified items

| Item | Status | Reason |
|---|---|---|
| 1-hour idle CPU | **UNVERIFIED** | Only a 5-second sample was run; the process has no timer/loop, so the sample is 0 ticks, but a full hour was not observed. |
| App + reverse-proxy idle RSS | **UNVERIFIED** | Nginx is not installed in this environment. The app alone is measured; no proxy number is fabricated. |
| Live HTTPS deployment | **UNVERIFIED** | No public host, domain, certificate, or sudo access was available. Nginx/systemd samples are provided but not executed here. |
| Browser screenshots at phone/desktop widths | **VERIFIED, capture only** | Playwright captures at 1280 px and 390 px are in `docs/screenshots/` and are reproducible with `scripts/capture-screenshots.js`. No pixel-diff baseline exists. |
| 256 KiB note p95 | single sample only | The benchmark records one large-note POST, not a 200-sample distribution. |

## Reproduction caveats

- VM CPU performance varies with host contention. Exact milliseconds will differ; the methodology and thresholds are the reproducible part.
- The benchmark uses 1 KiB bodies. 256 KiB bodies are tested separately as a boundary, not in the percentile tables.
- `synchronous=FULL` is intentionally enabled. A lower durability setting would produce faster saves and is not used.
- All figures are real measurements from `reports/benchmarks-raw.json`; no target is marked PASS without an observed result.
