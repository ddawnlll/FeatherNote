# FeatherNote v2 — The Living Notebook

> **Epic / master plan (documentation only).** Status: proposal; this branch adds no application code. Individual implementation PRs, reviewed evidence and release gates are required. Do not squash the roadmap into a premature "v2 shipped" claim.

**As of 2026-11-16.** Repo: [ddawnlll/FeatherNote](https://github.com/ddawnlll/FeatherNote). Base branch: `master`. Target editions: `v2.0` foundation, `v2.1` discovery/UX/agents, `v2.2` optional native research extensions.

## Product thesis / non-negotiable principles
FeatherNote stays a **self-hosted, single-owner, Markdown-canonical notebook**: fast, offline-first *in the sense of self-hosted/local storage, not an unimplemented offline browser PWA*, understandable and recoverable. It is not a hosted collaborative SaaS. Key invariants:

1. **Zero frontend JavaScript**, no script elements, CDN or remote runtime. All interactions are native HTML forms, links or server-rendered pages. Never promise cursor-aware WYSIWYG, instant preview, browser clipboard integration or seamless autosave under this constraint.
2. **One Zig executable + one SQLite database** as the baseline backup unit; native vendored parser libraries permitted if pinned and verified. Existing README v1 performance figures are measurements of v1 only.
3. **Durable acknowledged writes.** WAL, `synchronous=FULL`, SQLite transaction/optimistic locking; no silent overwrites. Every committed semantic edit is represented consistently in current state, immutable revision history, derived FTS/link indexes and audit events.
4. **Private, one owner.** CSRF, current strict CSP, loopback bind behind TLS proxy, secure cookie, Argon2id, local MCP stdio read-only default; notes/attachments remain plaintext on the host.
5. **Source Markdown never silently reformatted.** Edit-mode no-op is byte-identical, unknown syntax round-trips, old notes import unchanged.
6. **No regression-by-documentation.** Features are considered delivered only after code review, reproducible tests and benchmark evidence, with known limitations noted.

## Existing work / merge dependencies
- [Issue #2](https://github.com/ddawnlll/FeatherNote/issues/2), [PR #4](https://github.com/ddawnlll/FeatherNote/pull/4): full GFM/CommonMark renderer and safe HTML. **Open, unmerged** at epic drafting; must review sanitizer/fixtures before merge.
- [Issue #3](https://github.com/ddawnlll/FeatherNote/issues/3), [PR #5](https://github.com/ddawnlll/FeatherNote/pull/5): zero-JS block editor; **stacked on #4**, merge only after #4 and integration tests.
- [PR #1](https://github.com/ddawnlll/FeatherNote/pull/1): draft Goose backend research, **not production-ready** and **not on the v2 release path**.
- The nine linked v2 workstream issues [#6–#14](https://github.com/ddawnlll/FeatherNote/issues) own feature acceptance, implementation PRs and evidence. This epic PR is the index, dependency/rollout contract and reviewable roadmap, not an umbrella code merge.

## Workstream register

| # | Issue | Area | Items | Priority / release |
|---|---|---|---|---|
| 01 | [#6](https://github.com/ddawnlll/FeatherNote/issues/6) | Revision Engine, diff, restore | F01–F12 | v2.0 P0 |
| 02 | [#7](https://github.com/ddawnlll/FeatherNote/issues/7) | Markdown renderer, editor and extensions | F13–F23 | v2.0 P0 + v2.2 P2 |
| 03 | [#8](https://github.com/ddawnlll/FeatherNote/issues/8) | Folders/tags/wiki/backlinks/graph | F24–F34 | v2.0–v2.2 |
| 04 | [#9](https://github.com/ddawnlll/FeatherNote/issues/9) | Search/history/smart filters | F35–F42 | v2.1–v2.2 |
| 05 | [#10](https://github.com/ddawnlll/FeatherNote/issues/10) | Files/media/dedup/versions | F43–F50 | v2.0–v2.2 |
| 06 | [#11](https://github.com/ddawnlll/FeatherNote/issues/11) | Mobile/editorial UX/accessibility | F51–F57 | v2.1; v2.0 basics |
| 07 | [#12](https://github.com/ddawnlll/FeatherNote/issues/12) | Backup/security/import/export | F58–F65 | v2.0–v2.1 |
| 08 | [#13](https://github.com/ddawnlll/FeatherNote/issues/13) | MCP agent capabilities | F66–F72 | v2.0–v2.2 |
| 09 | [#14](https://github.com/ddawnlll/FeatherNote/issues/14) | Performance/migration/correctness | F73–F80 | v2.0 P0 |

**Feature count:** 80. Numbering is stable and maps 1:1 to the original feature list. Checkboxes are acceptance trackers, not implementation claims.

## Complete 80-feature inventory

### Revision Engine & Recovery — [#6](https://github.com/ddawnlll/FeatherNote/issues/6)

**Delivery:** v2.0 P0

- [ ] **F01** Immutable revision per acknowledged meaningful edit — exact Markdown, title, metadata and validated origin, transactional
- [ ] **F02** Chronological, paginated revision timeline with per-note monotonically increasing revision IDs
- [ ] **F03** Escaped accessible line-level unified and side-by-side diffs; Unicode, long lines and safe links
- [ ] **F04** Compare any two historical revisions without mutation
- [ ] **F05** Restore an old revision as a NEW revision using expected current version and explicit confirmation
- [x] **F06** Optional named checkpoints protected from unintended pruning
- [ ] **F07** Provenance metadata for Web/MCP/import/admin without exposing content in operational logs
- [ ] **F08** Immutable historical asset references and safe reachability/garbage collection
- [ ] **F09** Deletion, trash, archive and recovery actions recorded as versioned events
- [ ] **F10** Explicit base/latest/draft three-way conflict resolution; never silently overwrite
- [ ] **F11** Download precise historical Markdown bytes and associated asset manifest
- [x] **F12** History retained by default; explicit retention policy, protected checkpoints and purge verification

### Markdown & Rich Editor — [#7](https://github.com/ddawnlll/FeatherNote/issues/7)

**Delivery:** v2.0 P0 core / v2.2 P2 extras

- [ ] **F13** Complete tested CommonMark/GFM reader including tables, footnotes and task lists (PR #4)
- [ ] **F14** Allowlisted sanitized HTML; CSP, XSS controls, no browser script or remote resources (PR #4)
- [ ] **F15** Lossless form-driven server-rendered block editor, with per-block type operations (PR #5)
- [ ] **F16** Canonical raw Markdown editor and byte-for-byte no-op round trips (PR #5)
- [ ] **F17** Unsaved POST draft preview without committing data (PR #5)
- [ ] **F18** Accessible table cell/row/column editor, bounded forms (PR #5)
- [ ] **F19** Safe static callout/admonition syntax with documented fallback
- [ ] **F20** Native server-side math rendering feasibility and guarded static output; no JS
- [ ] **F21** Bounded server-side syntax highlighting, escaped source and all-theme readability
- [ ] **F22** Optional safe static diagrams generated without arbitrary code/shell execution
- [ ] **F23** Server-side Markdown templates for journals, meetings, research and projects

### Knowledge Organization — [#8](https://github.com/ddawnlll/FeatherNote/issues/8)

**Delivery:** v2.0 P0 / v2.1 P1 / v2.2 P2

- [ ] **F24** Nested folders with cycle-safe move/delete and non-destructive note handling
- [ ] **F25** Per-note tags with normalization, rename/merge and indexed filtering
- [ ] **F26** Wikilinks with stable destination IDs, title/alias resolution and code-fence exclusions
- [ ] **F27** Transactionally rebuilt incoming backlinks after all Web/MCP/import updates
- [ ] **F28** Server-rendered accessible folder tree and mobile navigation
- [ ] **F29** Separate favorites, pinned, archived and trashed semantics and filters
- [ ] **F30** Deterministic timezone-aware daily notes; idempotent date-keyed creation
- [ ] **F31** Aggregate GFM checkbox tasks linking back to canonical source notes
- [ ] **F32** Bounded static SVG knowledge graph and equivalent accessible relationship list
- [ ] **F33** Restricted frontmatter parser/metadata with lossless canonical Markdown
- [ ] **F34** Aliases and explicit collision/disambiguation policy

### Search & Discovery — [#9](https://github.com/ddawnlll/FeatherNote/issues/9)

**Delivery:** v2.1 P1 / v2.2 P2

- [ ] **F35** Unified titles, bodies, tags and attachment filename search with safe ranking
- [ ] **F36** Whitelist date, folder, tag, type, archive and provenance filters in parameterized SQL
- [ ] **F37** Opt-in local per-owner search history with delete control and log privacy
- [ ] **F38** Safe highlighted search excerpts with Unicode-aware boundaries and XSS resistance
- [ ] **F39** Optional historical revision search with distinct current-versus-past result labels
- [ ] **F40** Saved search expressions and smart collections, not executable raw SQL
- [ ] **F41** Diagnostic report for broken wikilinks and internal attachment references
- [ ] **F42** Transparent rule-based related-note suggestions based on links/tags

### Media & Attachments — [#10](https://github.com/ddawnlll/FeatherNote/issues/10)

**Delivery:** v2.0 P0 asset integrity / v2.1 P1 / v2.2 P2

- [ ] **F43** Native no-JS multi-file upload with explicit per-file and batch failure semantics
- [ ] **F44** Browsable/searchable attachment library by filename, MIME, size and linked note
- [ ] **F45** Content-addressed immutable blob dedup with hash and length verification
- [ ] **F46** Logical file replacement/deletion history independent of historical asset bytes
- [ ] **F47** Safe bounded previews for images, PDFs and escaped text, not executing SVG/HTML
- [ ] **F48** Server-side thumbnail generation with decode/image-dimension and memory caps
- [ ] **F49** Alt-text and caption metadata retained across note versions
- [ ] **F50** Configurable finite upload quotas, streaming transfer and full portable export

### Mobile UI & Accessibility — [#11](https://github.com/ddawnlll/FeatherNote/issues/11)

**Delivery:** v2.1 P1; essential surfaces v2.0

- [ ] **F51** 320px-to-desktop responsive index, reader, editor, history, diff, search and files
- [x] **F52** Distraction-free Focus Reading Mode with semantic accessible prose
- [ ] **F53** Compact desktop sidebar and native mobile navigation without JavaScript
- [x] **F54** Subtle progressive CSS page transitions; reduced-motion respected everywhere
- [x] **F55** Print-friendly stylesheet and browser-native PDF output
- [ ] **F56** Turkish/English strings and explicit timezone/date/number formatting
- [ ] **F57** Keyboard/screen-reader and WCAG-oriented audit across all 12 themes

### Backup, Security & Portability — [#12](https://github.com/ddawnlll/FeatherNote/issues/12)

**Delivery:** v2.0 P0 / v2.1 P1

- [ ] **F58** Configurable systemd scheduled online SQLite backups and retention
- [x] **F59** Verified backups and isolated restore drill including revision/blob hash checks
- [ ] **F60** Versioned portable export of all notes, histories, metadata and attachments
- [ ] **F61** Staged dry-run import from Markdown and Obsidian-like folders with link remapping
- [x] **F62** Read-only database doctor: integrity, FK, schema, FTS, revisions, blob reachability
- [ ] **F63** Redaction-safe provenance/audit event ledger for Web, MCP, import and admin mutations
- [x] **F64** Per-session inventory and CSRF-protected selective/all revocation
- [ ] **F65** Optional operator-held-key encrypted offsite backups; no false E2EE claim

### MCP v2 & Agent Workflows — [#13](https://github.com/ddawnlll/FeatherNote/issues/13)

**Delivery:** v2.0 foundation / v2.1 P1 / v2.2 P2

- [ ] **F66** List/get/compare/restore historical revisions via MCP, gated by write privilege
- [ ] **F67** Read-only-default scoped capability permissions for note/media/metadata writes
- [ ] **F68** Version- and hash-checked atomic source append/patch with exact offsets
- [ ] **F69** Uniform optimistic conflict result for Web and MCP; never bypass revision writer
- [ ] **F70** Bounded bulk operations, explicit atomicity and replay-safe idempotency keys
- [ ] **F71** Monotonic persisted change cursor with pagination and expiry semantics
- [ ] **F72** Folder, tag, backlink, safe import/export and collection tools over local stdio

### Performance, Migrations & Reliability — [#14](https://github.com/ddawnlll/FeatherNote/issues/14)

**Delivery:** v2.0 P0 cross-cutting

- [ ] **F73** Bounded paging/streaming for history, diff, rendering and attachments; low RSS
- [ ] **F74** Checked content hashes, dedup and empirically compared snapshot/delta storage
- [ ] **F75** Crash-safe SQLite transaction boundaries and Web/MCP concurrency verification
- [ ] **F76** Index/query optimization for 10k+ notes and 100k+ historical revisions
- [ ] **F77** Safe forward schema migrations with rollback, old-database fixtures and backup
- [ ] **F78** Disk capacity/WAL/full-storage protections and no acknowledgement of failed commits
- [ ] **F79** Fault injection for crashes, malformed Markdown/HTML, unsafe files and conflicts
- [ ] **F80** Single Zig binary with vendored native components, 0 client JS, measured budgets

## Architectural decision proposal — Revision Engine v2.0

### Conceptual durable transaction
```text
HTTP POST or MCP mutation
    ├── Validate CSRF/auth (web) or explicit write capability (MCP)
    ├── Validate expected note version, bounded payload and Markdown bytes
    └── SQLite BEGIN IMMEDIATE
          ├── Recheck current version against expected version
          ├── Insert immutable revision + snapshot/provenance + asset references
          ├── Update notes.current_title/body/version/metadata
          ├── Update FTS, links/tasks and audit/change events consistently
          └── COMMIT (WAL + synchronous=FULL)
    → Only after commit return success; otherwise 409/error, no partial ack
```
Suggested schema names are **illustrative**: `note_revisions` (note_id, revision_no, title, body, source, summary, created_at, checksum, ...); `revision_blobs` (rev_id, blob_id); `blobs` (sha256/size/bytes); `audit_events` (seq, origin, type, note_id, revision_no, timestamp); indexes by note/revision and sequence. Decide actual schema after review of current `notes`, `attachments` and existing MCP DB calls. Exact-current-state `notes` stays performant for FTS. No page GET creates a revision.

**Migration:** the first v2 migration must import existing current notes (including Trash) into a single **baseline revision** without inventing a pre-v2 history. Existing attachment URLs/IDs must keep working; a media rewrite must not cascade-delete historical bytes. Back up before migration and test restart/interruption. A restoration of old revision N creates revision N+1 *relative to the current head*, never rewrites the old row.

**Storage tradeoff:** begin with full snapshots (simple restore/fewer corruption modes), benchmark repeated 1KB/100KB/1MB edits for disk/write/read overhead, only introduce optional dedup/delta if measured and proven equivalent with power-loss and corruption tests. Dedup is naturally attractive for attachment blobs; history remains append-only logically.

## Dependency / critical path

1. Capture `master` benchmarks and old-DB fixtures, review migration/recovery plan (#14, #12).
2. Audit/merge renderer [#4](https://github.com/ddawnlll/FeatherNote/pull/4), then stacked block editor [#5](https://github.com/ddawnlll/FeatherNote/pull/5), preserving 0-JS and Markdown.
3. Implement revision writer and migration (#6) alongside history-safe attachment references (#10) and backup doctor/checker (#12); integrate Web and MCP on one common writer (#13).
4. Add v2.0 organization minimum (#8), revision timeline/diff/restore UI with accessible mobile/print behavior (#11), and upgrade/restore acceptance.
5. Ship v2.0 **only after** P0 gates; work on v2.1 search/media/navigation/agent ergonomics in independent PRs; keep complex native math/diagrams/graph/delta optimizations behind v2.2 feasibility reviews.

## Release gate matrix

| Gate | Evidence required to mark PASS |
|---|---|
| Data integrity | Every acknowledged edit reconstructable; after SIGKILL/restart/restore current hash and revision chain match; DB `integrity_check` and `foreign_key_check` pass |
| Concurrency | Stale tab or MCP saves return conflict; draft preserved; explicit restore never overwrites unrelated edit |
| History/media | Restore arbitrary revision and attachment; current + historical blobs survive deletion/rename; no orphan loss |
| Migration | Fresh DB + pre-v2 DB both migrate, backup before upgrade, failed migration rollback/retry, no fabricated earlier revisions |
| Security | No script served, CSP unweakened, XSS/scheme tests against historical renders/diffs, CSRF on all form mutations, MCP read-only |
| Usability | JS off, 320px to desktop, keyboard and accessible timeline/diff/restore; all twelve themes |
| Tests | `zig build test`, `zig build --release=safe`, `python3 tests/integration.py`, `python3 tests/mcp_test.py`, targeted browser/fault cases |
| Performance | Capture before/after on same Debian host; warm GET p95 <=10ms, save p95 <=25ms, current 10k FTS p95 <=20ms are *proposed targets*, not current measured v2 results; record idle/peak RSS and binary bytes |
| Operations | Recover from disk full/failures; verified online backup and restore drill; export complete Markdown/revisions/attachments |

**Definition of done for this epic *planning PR***: nine workstream issues exist and are linked; 80 feature IDs documented; sequence, dependencies, non-goals and acceptance gates agreed. Merging the plan does **not** close workstream issues and does **not** constitute the v2 software release.

## Explicit exclusions pending a separate decision
No multi-user/team/sharing system, no remote unauthenticated MCP endpoint, no JS SPA or falsely claimed WYSIWYG, no arbitrary HTML/JS/SVG execution, no unreviewed Goose backend rewrite, no promise of off-host E2EE. Browser-offline PWA/sync and collaborative live editing would require a separate technical and product RFC.
