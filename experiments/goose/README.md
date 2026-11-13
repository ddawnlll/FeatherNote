# FeatherNote Goose backend experiment (not production)

**Status:** Stage 0 committed, compiler validation pending. Nothing under this directory is wired into the production service. This is an intentionally isolated research branch.

## Why this exists

FeatherNote is already a tiny, server-rendered, no-JavaScript Zig application. Rewriting it in Goose must demonstrate better *application-level* speed, memory, build time, or maintainability without changing security or data guarantees. A synthetic Goose-vs-C++ language microbenchmark is NOT proof.

Pinned source snapshots at experiment start:

- FeatherNote master: `8961d45e98984121d8c617d310374e502cdaf049`
- Goose master: `d5ae5bbda990923fa4129f969c7f853c20d4d1e6`
- Baseline evidence: `../../reports/benchmarks.md` (2026-11-07)
- Zig baseline uses SQLite 3.54.1, WAL and `synchronous=FULL` with one serialized connection.

## Stage 0: exact HTML-escaping spike

`escape_html.goose` implements `src/http_util.zig::escapeHtml` for stdin->stdout, preserving all bytes other than the five escaped ASCII characters. This is **not** a Markdown renderer, HTTP server, or working FeatherNote port.

On a development machine with Goose compiler installed:

```bash
goose version
goose check experiments/goose/escape_html.goose
python3 experiments/goose/test_escape.py
```

The test harness calls `goose build` to create an optimized native executable and runs deterministic byte-for-byte comparison against the Zig escape rules. It includes Unicode, hostile HTML, long strings and randomized byte fixtures. Record the exact compiler/runtime versions and any failures.

**Verification status:** not compiled in the author's environment: Goose is not installed here and external network access is unavailable. A source file on GitHub is not a passed test. Do not merge into production until tests actually pass.

## Why Goose cannot simply replace main.zig today

- Goose has no fully-fledged network server in its built-in `os` module. A production server needs a reviewed C/POSIX HTTP bridge or separate ingress and request protocol.
- SQLite must use the real SQLite C library, via a narrow C FFI shim, with parameter binding, error handling, migrations, full durability, and online backup. No hand-built or in-memory substitute.
- The authentication path uses Argon2id and cryptographically random sessions; memory reduction must never weaken password hashing.
- Goose's stack-lifetime discipline needs deliberate ownership across requests. Its TinyCC `goose run` is useful for fast experimentation, but **not** for runtime-performance comparisons; use `goose build` with an optimizing native C compiler.
- The existing server's live HTTP protocol, file handling, streaming/keepalive behavior, concurrency, MCP stdio interface and request limits all need behavioral equivalence, not just a home page.

## Experiment stages (advance on evidence only)

| Stage | Implement | Acceptance evidence |
|---|---|---|
| 0 | Pure-Goose HTML escape | Exact differential output vs Zig reference, 0 failures |
| 1 | Markdown inline + block renderer | Full existing Markdown test corpus + XSS/URL policy parity; fuzz malformed and UTF-8 |
| 2 | SQLite thin C boundary | Open existing DB; migrations, FTS5, CRUD, backup, optimistic 409 writes; same durability |
| 3 | HTTP transport | Real loopback server, timeouts/limits, headers/cookies/CSRF, keep-alive, concurrency |
| 4 | Authentication and file support | Argon2id correctness, session revocation, attachment content-sniffing, 8 MiB cap |
| 5 | MCP and complete application | All existing integration/adversarial tests pass without modifying them |
| 6 | Comparable A/B performance and maintainability | Go/no-go matrix below |

## Fair benchmark protocol

Run three candidates on the **same host**, same data, flags and workload:

1. `Zig-baseline` — pinned master, ReleaseSafe, stripped, existing SQLite amalgamation.
2. `Zig-optimized` — profile-guided internal changes but no semantic weakening; ReleaseSafe as default. Record `ReleaseFast` separately as an exploration, not a drop-in equivalent.
3. `Goose-AOT` — Goose compiled via native optimized C backend, same SQLite build and schema, same durability and auth parameters.

Use a fresh clone or separate worktree for each. No concurrent candidate runs; randomize run order across repetitions. Before each trial, restore byte-identical DB snapshots. Report at least 5 repeats and confidence intervals, not just the fastest run.

Cases: 100 / 10,000 / 100,000 notes; 1 KiB / 256 KiB text; 1/2/8/32 clients; 1/10/100% writes; both fresh TCP and keepalive. Warm and cold runs separated. Also track clean/incremental build time, build disk footprint, binary bytes, idle/peak RSS/PSS, CPU cycles, `perf stat`, and per-endpoint p50/p95/p99, errors and completed requests/s. Compare both loopback and deployed-proxy HTTPS separately. Simulate slow clients and malformed requests.

Retain `journal_mode=WAL`, `synchronous=FULL`, correct FTS5 query semantics, Argon2id memory cost, CSRF, session cookies, content security headers, and backup safety. A faster but less safe system is a failed candidate.

### Existing baseline (single-run report; not yet comparative)

| Metric (10k notes) | Zig baseline |
|---|---:|
| Idle RSS | 6.61 MiB |
| Peak process RSS (login included) | 23.4 MiB |
| GET note p95 | 1.09 ms |
| Save POST p95 | 10.58 ms |
| Search p95 | 4.23 ms |
| Binary | 2,406,040 bytes |

Recorded on Xeon E5-2680 v2 VM with Python client establishing a new TCP connection per request. The 8-client GET p95 increases to 15.45 ms; the shared SQLite connection and network/client overhead both require profiling.

### Go/no-go

Keep Goose as a supported alternative **only if** all behavior and adversarial tests pass, *and* it demonstrates a reproducible significant full-app win (for example >=20% p95 or peak memory under realistic load) without a harmful regression elsewhere, or substantial measured compile-time/developer-iteration benefit. Otherwise keep production Zig and retain Goose as a research spike.

### Prioritized Zig optimization hypotheses

1. Profile SQLite lock wait, prepare/finalize churn, query plans, row materialization, FTS5, and response-rendering separately. Use `perf`, SQLite `EXPLAIN QUERY PLAN`, and built-in request timing **off** in final measurement.
2. Compare fresh TCP with persistent keepalive: existing benchmark opens a new connection for *every* call; the client and network may dominate low-millisecond readings.
3. Explore cached prepared statements and a bounded read connection pool (only if contention and locking evidence justify it). Preserve schema and snapshot semantics.
4. Investigate streaming/reusing response buffers and bounded per-request scratch memory; profile before introducing caches.
5. Keep `synchronous=FULL`; tune batching only for explicitly grouped write operations with equivalent durability.

**Never optimize by dropping security checks, reducing Argon2id strength, disabling fsync, omitting FTS updates, or treating different features as equivalent.**
