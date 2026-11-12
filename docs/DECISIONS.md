# Engineering decision log

Short records of deviations and tradeoffs made during the P0 build.

## D001 — Zig 0.17.1 uses `--release=safe`, not `-Doptimize`

Zig 0.17.1 changed the build option surface: `-Doptimize` is only exposed when a project does not declare a preferred mode. `build.zig` declares `ReleaseSafe` as preferred, so the release command is `zig build --release=safe`; a bare `zig build` produces a debug binary. All documentation and the Makefile use the new form.

## D002 — SQLite is accessed through `zig translate-c`, not `@cImport`

Zig 0.17.1 removed the `@cImport` builtin. `build.zig` runs `b.addTranslateC` on the vendored `sqlite3.h` and exposes it as the `sqlite3` module. The amalgamation `sqlite3.c` is compiled as a normal C source file with pinned flags. This preserves the C ABI path and keeps the SQLite version exactly 3.54.1.

## D003 — Embedded assets live behind `assets.zig`

`@embedFile` may not escape its package root, and `src/main.zig` is the package root. A tiny root-level `assets.zig` module embeds `web/style.css` and `migrations/0001_init.sql`; `main.zig` and `db.zig` import it. The source tree still keeps assets in the conventional `web/` and `migrations/` directories.

## D004 — One SQLite connection, serialized by a mutex

For a single owner, predictable memory and simple transaction ordering matter more than connection-pool throughput. All DB methods take one mutex. Argon2 verification happens outside the mutex so a login does not block note reads for its full hashing time. If concurrency measurements later show unacceptable queueing, a small bounded pool can be added without changing the SQL semantics.

## D005 — WAL with `synchronous=FULL`, 512 KiB page cache

Durability is a hard gate; speed is not. `synchronous=FULL` means a committed, acknowledged write is synced before the HTTP response. The `-512` cache setting is 512 KiB per connection. WAL is checkpointed on normal close. SQLite's 3.54.1 release is pinned because the 2026 WAL-reset defect requires a corrected release.

## D006 — Argon2id OWASP parameters, peak RSS reported separately

Passwords use Argon2id with `m=19 MiB, t=2, p=1` via Zig's standard library. This deliberately creates a ~19 MiB transient allocation during login; the measured peak RSS (~24 MiB) is therefore reported separately from idle RSS (~6 MiB). Security strength was not reduced to meet the idle-memory target.

## D007 — FTS5 search with an explicitly built query

The first implementation used parameterized `LIKE '%...%' ESCAPE '\'`. At 10,000 notes its p95 crossed the 100 ms gate on one measured run (106.8 ms), so schema v2 adds an external-content FTS5 table (`unicode61 remove_diacritics 2`) with insert/update/delete triggers. User input is never passed to `MATCH` verbatim: whitespace-separated terms are individually double-quoted (with embedded quotes doubled), joined with `AND`, and punctuation-only terms are dropped. This keeps the query a restricted phrase grammar rather than an input language. Lookup remains a join to `notes` filtered by `deleted_at IS NULL`, ordered by pin/updated/id. The 1 KiB-body 10,000-note benchmark now passes the search gate with substantial margin.

## D008 — Absolute sessions, no sliding expiry

Sessions have an absolute 30-day expiry. `last_used_at` is refreshed at most once per hour to limit write amplification. This is simpler to reason about than idle-plus-absolute expiry and still bounds session lifetime. Logout revokes the row; password changes revoke all sessions.

## D009 — Login form has no CSRF token

FeatherNote has exactly one owner and no cross-account login confusion: an attacker who forces a victim through login can only target the same single account and must still know its password. Login is rate-limited and performs a full Argon2 verification. Every authenticated mutation, including logout, uses a session-bound synchronizer CSRF token with constant-time comparison.

## D010 — Session cookie naming depends on transport

Production uses `__Host-feather_session` with `Secure`, `HttpOnly`, `SameSite=Strict`, `Path=/`, and no `Domain`. `__Host-` mandates `Secure`, so local plain-HTTP testing uses `--insecure-cookies`, which switches to `feather_session` and omits `Secure`. The public deployment never uses that flag.

## D011 — Conflict resolution requires an explicit second POST

A stale save returns 409 with the full draft and the latest stored version. The draft can be submitted explicitly against the latest version; this is a new POST with the latest version. There is no automatic merge and no overwrite without the user seeing both. Revisions/diffs are deliberately P1.

## D012 — No graceful-shutdown signal handler in v1

Systemd sends `SIGTERM`; the process exits without running `Db.close`'s checkpoint. This is safe because WAL plus `synchronous=FULL` preserves committed transactions and SQLite recovers on next open. The only cost is leaving WAL frames for the next start. A signal handler and orderly shutdown can be added later without changing durability.

## D013 — TCP loopback only, no Unix-domain socket in v1

The specification permits loopback or a Unix socket. TCP `127.0.0.1` is the tested path and is simple with the Zig HTTP server. Non-loopback binds are refused unless an explicit `--allow-public-bind` flag is supplied, to prevent accidental public exposure.

## D014 — Administrative output goes to stderr

Admin commands print status and errors with `std.debug.print` (stderr). Tests accept combined stdout/stderr. This keeps diagnostics separate from any future machine-readable stdout mode.

## D015 — Themes are server-side owner state, not a cookie or script

The selected theme is a validated id stored on the single owner row and emitted as `data-theme` on `<html>`. One embedded stylesheet carries all twelve palettes. Switching is a CSRF-protected form post. This keeps the choice consistent across devices, includes it in backups, and avoids a theme-flash cookie or any client script. The CSS grew from 3 KiB to about 23 KiB; it is still a single embedded, cacheable request with no per-navigation cost.

## D016 — Markdown was a safe, bounded subset rendered on the server

`src/markdown.zig` rendered headings, emphasis, strikethrough, inline and fenced or indented code, lists, quotes, rules, links, and images. Source text was escaped before output, raw HTML never passed through, and links were limited to http(s), mailto, and same-origin absolute paths. Images were same-origin only, matching the CSP's `img-src 'self'`, so remote images could not be used as tracking pixels. Innermost emphasis and link labels were depth-limited. The read view rendered this HTML; the editor stayed a plain textarea. Tables, footnotes, task lists, and embedded HTML were intentionally unsupported and degraded to text. Superseded by D019.

## D017 — Attachments are SQLite BLOBs, uploaded without JavaScript

Files up to 8 MiB are parsed from `multipart/form-data`, MIME-sniffed from their bytes rather than trusted headers, and stored in an `attachments` table with a SHA-256 ETag. Images are served inline; every other type, including SVG and HTML, is served as a download with `nosniff`. Uploads require CSRF and append a Markdown link to the note. Clipboard paste and drag-and-drop need JavaScript and are deliberately absent; the file picker is the supported path.

## D018 — Plaintext is the product

The server reads note plaintext to render and search it. No end-to-end encryption is claimed. Database and backup file permissions, plus host security, are the protection boundary; backups leaving the host require operator-managed encryption.

## D019 — MD4C for parsing, a Zig allowlist sanitizer for safety

`src/markdown.zig` is now a three-stage pipeline: (1) a footnote preprocessor (`[^label]` definitions/references, skipped inside fenced and inline code), because MD4C has no footnote support; (2) the vendored MD4C 0.5.3 parser (MIT, `vendor/md4c/`, see `VENDOR.md`) via a thin C bridge with the GitHub dialect and XHTML output, which provides full CommonMark plus tables, task lists, strikethrough, and permissive autolinks; (3) an allowlist HTML sanitizer with an explicit tag tokenizer and element stack (no regexes). Every byte of HTML output passes the sanitizer, including MD4C-emitted links and raw HTML from the note: allowlisted tags are kept with allowlisted, validated attributes; disallowed tags are escaped as visible text; comments are dropped; `on*` handlers, `style`, `srcdoc`, and unsafe URLs are stripped or dropped; `href` allows http(s), mailto, same-origin paths, and `#` fragments; `img src` allows same-origin absolute paths only (CSP `img-src 'self'` still prevents tracking pixels). Element depth and total output are capped. On any failure the renderer fails closed and escapes the whole source.

Lexbor was evaluated and not vendored: it is only an HTML5 parser, not a sanitizer, and MD4C output is well-formed XHTML that the Zig tokenizer sanitizes directly, so a second C dependency bought nothing. cmark-gfm was not adopted because MD4C already passes the suites below and FeatherNote needs no AST for reading; a future block editor may revisit that tradeoff. Math, diagrams, alerts/admonitions, wiki links, underline, and LaTeX spans are not enabled and render as text or plain emphasis; header IDs are not generated. Alerts are not supported.

Measured with the upstream `md2html` tool against MD4C 0.5.3 sources on 2026-11-12: CommonMark spec.txt 652/652, tables 12/12, tasklists 5/5, strikethrough 5/5, permissive autolinks 15/15, regressions 65/65. Cost: binary 2,648,856 to 2,813,720 bytes, idle RSS 6,148 to 6,972 KiB at 100 notes, note GET p95 3.2 to 3.9 ms. Sources are pinned in `vendor/md4c/CHECKSUMS.txt`.
