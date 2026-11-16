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

## D020 — Zero-JS rich editing is server-driven blocks over byte ranges

Issue #3's rich editor is not a browser widget. `src/blocks.zig` splits the
stored Markdown into blocks described by byte ranges `[start, end)` over the
original body, and the separator bytes between blocks (newlines and blank
lines) belong to no block, so editing block *k* splices only its own bytes
and every unedited block keeps its exact original bytes. There is no
reformat pass and no canonical rewrite: the source editor and the block
editor share one stored representation, Markdown remains canonical, and
opening the block editor and changing nothing writes nothing at all.

Editable kinds are paragraph, heading (levels 1-6), unordered/ordered lists,
checklist tasks, quote, fenced code (with language), table, thematic break,
link, and image. Constructs the editor cannot regenerate without loss
(indented code, nested or mixed lists, footnote and link reference
definitions, HTML blocks, multi-paragraph quotes, large tables) are
classified as `raw` and stay editable as verbatim Markdown. That is the
documented source fallback, not a silent degradation: the read renderer
(D019) still renders the full document, and nothing the user wrote is
rewritten by accident.

Operations (all `POST` with CSRF and the optimistic version, 409 on stale
version with the draft preserved): title save, per-block update, insert
before/after, delete behind an explicit confirmation, move up/down,
duplicate, convert between kinds, and table add/delete row/column plus a
per-cell grid (escaped pipes and code spans respected). Limits: 200 blocks
per note and 512 rendered table cells; larger tables fall back to verbatim
Markdown editing. The form parser's field cap rose from 32 to 1024 total
fields for the same reason; total work is still bounded by the encoded
request size cap in the HTTP layer, and duplicate field names stay
rejected. Preview (`POST /notes/preview`, `POST /notes/{id}/preview`)
renders the current draft through the D019 pipeline and writes nothing;
the version is validated so a stale tab cannot preview as if current.

Deliberately not provided: live cursor tracking, drag-and-drop reordering,
inline formatting buttons (form controls only), autosave, and any client
script. Each block save is a full form submission that lands on an anchor
(`#block-N`) so keyboard users keep their place. Verified in Chromium with
JavaScript disabled (38 browser checks, desktop/mobile, light/dark) plus
integration tests for preview, all block operations, table editing, and
stale-version conflict.

Measured 2026-11-12, same bench and machine (`scripts/bench.py` now also
measures the blocks page and preview endpoints): binary 2,813,720 to
2,908,312 bytes (+94,592 B, +3.4%); idle RSS at 100 notes 6,972 to 7,920
KiB; blocks page GET p50/p95 1.99/2.69 ms at 100 notes and 2.04/3.53 ms at
10,000 notes; preview POST p50/p95 2.42/5.45 ms and 2.54/5.60 ms. Zero
bytes of frontend JavaScript are still served by every page.

## D021 — Revisions are full, immutable snapshots written in the same transaction

Every acknowledged semantic change (create, content edit, pin/unpin, trash,
restore, historical restore) appends a `note_revisions` row inside the same
`BEGIN IMMEDIATE` transaction that checks the expected `notes.version` and
updates current state. A stale version returns 409/conflict before any row is
written. A no-op save with the current version returns success without bumping
the version or appending a revision. Full snapshots were chosen over deltas:
one row is enough to recover a note, with no chain to corrupt, and the byte
price is measured before considering dedup in a later change.

Each revision stores title, exact Markdown, pin/trash state, the resulting note
version, UTC time, validated origin (`web`, `mcp`, `import`, `admin`,
`system`), action, a short summary, and a SHA-256 checksum over length-prefixed
title and body. Web and MCP call the same DB writer; web blocks, uploads and
MCP append all therefore share one revision rule.

Migration `0004_revisions` is the history boundary. It creates the revision
tables, soft-deletes attachments instead of deleting their bytes, and seeds
exactly one `baseline` revision per existing note with its current bytes. It
does not pretend those notes had earlier revisions. `revision_assets` records
the live attachment manifest at each revision, so replacing or removing a file
cannot change what an old revision referenced. Normal file URLs still hide
removed attachments; historical downloads require the attachment to be listed
in the requested revision (`/files/{id}/{name}?revision=N`).

History UI is server-rendered: a paginated timeline, escaped revision source,
and a bounded line diff. The diff uses an LCS matrix up to 2,000,000 cells and
falls back to a prefix/suffix block diff above that, preventing a hostile note
from forcing unbounded work. Restore requires CSRF and the current note
version and creates revision N+1; it never rewrites revision N.
Restoring a revision also clears soft-deletion for the files listed in that
revision, because their bytes were retained; the new head therefore has a
working attachment set again. Files added after the restored revision stay
live and are not removed.

## D022 — Conflicts show base, latest and draft, never a silent merge

The edit form still carries the note version it started from. On a 409,
`revisionAtVersion(note_id, submitted_version)` finds the newest content
snapshot at or before that version; pin/trash events can advance the version
without changing text, so version equality alone is not enough. The conflict
page shows the exact base snapshot, a line diff from base to latest, and a line
diff from base to draft, with the draft still editable.

There is no automatic merge, no last-write-wins, and no client JavaScript. The
only overwrite is the explicit "Save draft over latest" button, which submits
the latest version and is checked again by the normal writer. Conflict diffs
are capped at 2,000 rendered lines and use escaped text. This satisfies the
deliberate three-way review requirement without pretending to resolve
overlapping edits automatically.

## D023 — Checkpoint labels annotate revisions without rewriting them

Migration `0005_checkpoints` adds a `label` text column (empty string means no
label) with an 80-character check and a partial index for labelled revisions.
A label is metadata: setting or clearing it does not append a revision, bump
the note version, or change the content checksum. Handlers trim surrounding
spaces, require valid UTF-8, reject control characters and cap the label at 80
bytes; MCP applies the same rule.

History and revision detail show labels, and the detail page has a CSRF-
protected form to set or clear one. Retention (D024) treats every non-empty
label as a hard floor and never deletes it.

## D024 — Retention is an explicit prefix purge with a recorded floor

Migration `0006_retention` adds `note_history_retention`, one row per purged
note holding the first retained revision and cumulative purged count. Revision
numbers above that floor stay contiguous; the doctor compares each chain's
minimum against the floor instead of assuming every note still starts at r1.

`admin purge-history` requires `--keep-last N`, optionally accepts
`--older-than-days`, and is a dry run until `--apply` is passed. Per note it
protects the newest N revisions, every labelled revision, and every revision
newer than the age cutoff. Only the contiguous unlabelled prefix below all
three is deleted. This deliberately avoids punching holes that would break
compare, restore, or the chain invariant.

A stale draft whose base revision was purged still receives 409 and keeps its
draft, but the base-diff section is unavailable; the page says so rather than
inventing a base.

Verification runs inside the same transaction before commit: labelled count is
unchanged, every note still has a head, chain shape matches the floor, floors
point at an existing revision at or below the head, asset manifests resolve,
and `PRAGMA integrity_check` passes. A failure rolls back. There is no timer,
no daemon, and no retention in the web or MCP surface; an operator with database
access performs it. History pages state the floor when it is above r1, and
compare rejects revisions below it.

## D025 — Backups are only successful after the doctor passes

`admin backup` uses SQLite's online backup API, then opens the destination
read-only and runs the same doctor as `admin doctor`. Success is printed only
if every check passes; otherwise the command exits non-zero and says the file
is unsafe. The doctor now recomputes SHA-256 over every attachment blob and
compares it with the stored hash and size, not just the hash's length. This
catches silent byte corruption that `PRAGMA integrity_check` cannot see.

The restore drill in `tests/integration.py` takes an online backup while a
writer is active, runs the doctor on it, copies it to a separate directory,
starts a second server on the copy, logs in and reads the restored note. The
backup command does not truncate, move or overwrite the source database.

## D026 — Session inventory revokes only, never reveals tokens

Sessions remain keyed by the SHA-256 of a 32-byte random cookie token. Settings
lists unexpired, non-revoked rows with issued/last-used/expiry times and an
eight-character fingerprint of the stored hash. Revoke forms carry the full
stored hash in a hidden field; that hash cannot authenticate a request, and the
cookie token is never written into HTML. Every revoke route is POST with CSRF.

The current session is shown as "This browser" with no revoke control; ending
it goes through Log out, which also expires the cookie. Selective revoke updates
one row, revoke-all-others updates every other active row. There is no session
identifier in a URL and no GET mutation, so a prefetched link cannot log a
browser out.

## D027 — Page transitions stay in CSS

Navigation uses cross-document View Transitions: `@view-transition` opts in, the
site header keeps its own name so it does not move, and `main` is named
`page-content` so the old page eases out while the new one eases in. No script
runs and no JavaScript is served.

Browsers without `view-transition-name` get a one-shot page-load fade and rise
through `@supports not`. Browsers with the property get the full old/new
transition. `prefers-reduced-motion: reduce` removes all animation and
transition, including button press feedback. The same rule is asserted by the
HTTP suite so a future stylesheet edit cannot silently drop it.
