# FeatherNote v2 progress ledger

Updated 2026-11-16. Source of truth for workstream acceptance is still issues
[#6–#14](https://github.com/ddawnlll/FeatherNote/issues) and the roadmap in
[`V2_ROADMAP.md`](V2_ROADMAP.md). A merged PR is not acceptance evidence by
itself; checks below name the test that proves the claim.

## Integrated

| Work | Evidence |
|---|---|
| Renderer PR #4 (F13, F14) | Merged to `master`; `zig build test`, 178 HTTP checks, 55 MCP checks; vendored MD4C checksums verified; XSS fixtures escaped. |
| Zero-JS block editor PR #5 (F15–F18) | Merged after retargeting to `master`; preview/draft/conflict tests green. |
| Roadmap PR #15 | Merged; 80 feature IDs and release gates are now on `master`. |
| Revision engine foundation (F01, F02 read model, F04, F05, F07, F09, F11 source, F12 default) | `migrations/0004_revisions.sql`, one transactional writer for Web and MCP, migration baseline test, no-op/conflict tests. |
| History timeline, compare and restore UI (F02, F03, F05) | `GET /notes/{id}/history`, `GET /notes/{id}/history/{rev}`, `GET /notes/{id}/compare`, `POST /notes/{id}/restore/{rev}`; escaped server-rendered diff; CSRF and version tests. |
| Historical asset integrity, baseline (F08, part of #10) | Attachments soft-delete; `revision_assets` manifest; historical file access requires a revision that referenced it. |
| MCP revisions (F66 partial, F69 writer) | `list_revisions`, `get_revision`, `compare_revisions`, `restore_revision`; read-only mode hides the write tool. |
| Three-way conflicts (F10) | 409 page shows the exact base revision, base→latest diff and base→draft diff with the draft preserved; no automatic merge. |
| Historical export (F11) | Exact Markdown download plus JSON title/checksum/asset manifest per revision; safe attachment filename; GET-only. |
| Named checkpoints (F06) | 80-character labels on any revision; CSRF web form and MCP `set_revision_label`; labels excluded from checksums and protected by the retention purge. |
| Verified backups and read-only doctor (F59, F62) | `admin doctor` checks integrity, FKs, FTS parity, revision chains/checksums, head agreement, asset manifests, attachment ownership/size, a recomputed SHA-256 of every blob, labels and retention floors. `admin backup` runs the doctor on the destination and fails on any mismatch; the integration drill copies the backup, starts a server on it and reads the restored notes. |
| Focus reading and print output (F52, F55) | `GET /notes/{id}/focus` renders semantic prose without site chrome in the same CSP; `@media print` hides controls and prints external link targets; integration checks assert no scripts and the print rules. |
| Explicit retention and verified purge (F12) | `admin purge-history --keep-last N [--older-than-days D] [--apply]`; dry-run by default; keeps newest N, all labels and young revisions; records per-note floors; verifies labels, heads, chains, assets and integrity before commit; history reports the floor. |
| Per-session inventory and revocation (F64) | Settings lists active sessions with times and fingerprints; CSRF-protected selective revoke and revoke-all-other routes reject the current session; revoked browsers redirect to login; unit and HTTP tests. |

## Measured evidence (this iteration)

- `zig build test`: pass (including revision lifecycle, no-op, conflict,
  restore, attachment manifest, v3→v4 baseline migration, bounded diff).
- `python3 tests/integration.py`: 210 passed, 0 failed.
- `python3 tests/mcp_test.py`: 55 passed, 0 failed.
- Retention: dry run reports the plan without committing; apply matches the
  plan; labelled checkpoint blocks a later `--keep-last 1`; doctor passes with
  a non-1 floor; purged revision returns 404 while the head still serves.
- Zero client JavaScript: history and diff pages are server-rendered forms and
  escaped HTML; integration checks assert no `<script>` in revision/compare
  responses.

## Open / next unblocked

1. **Attachment removal is not itself a revision event yet.** The note bytes
   are unchanged when a file is removed, so no note revision is appended; the
   previous revision's manifest and bytes remain valid. A dedicated asset event
   ledger belongs with the media workstream (#10, F46/F63).
2. **F73/F76/F77 performance and migration gates.** Measure history/diff p95,
   database growth for 100k revisions, and disk-full/WAL fault injection before
   claiming the roadmap's proposed targets.
3. **#7 remaining:** callouts, math, highlighting, diagrams, templates.
4. **#8–#14 remaining:** folders/tags/links, search filters, media library,
   mobile/print/a11y audit, verified backups/doctor/import/export, MCP change
   cursor and collections, migration/fault gates.

## Blockers

No implementation blocker. The specified model route
`opencode-go/deepseek-v4.1-flash` is present in `jcode model list` and the
provider API key is configured; this session's own runtime model cannot be
changed mid-session, so worker routing remains governed by the host's JCode
configuration.
