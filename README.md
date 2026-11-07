# FeatherNote

A single-owner, self-hosted note service: one Zig process, one SQLite file, server-rendered HTML, and a 3 KiB stylesheet. No JavaScript is required to create, read, edit, search, pin, delete, or restore notes. It is designed to listen on loopback behind a TLS reverse proxy on an inexpensive Linux machine.

**Status:** P0 implementation complete and locally verified. Performance figures below are measured on the build machine identified in `reports/benchmarks.md`; they are not universal claims.

## What works

- Owner bootstrap from a local admin command; no public registration and no default password.
- Login/logout with Argon2id, server-side session digests, `HttpOnly`/`SameSite=Strict` cookies, session expiry, and login rate limiting.
- Create, list, open, edit, save, pin/unpin, soft-delete, and restore plaintext UTF-8 notes.
- Title/body search (FTS5, safely quoted terms) with URL-addressable queries, server-side pagination (50 notes per page), and deterministic ordering: pinned first, then `updated_at DESC, id DESC`.
- Optimistic concurrency: an update carries the version it started from. A stale save returns **409** and shows both the latest stored version and the complete submitted draft, with an explicit "save my draft over the latest" form. Nothing is overwritten silently.
- Post/Redirect/Get after every successful mutation.
- HTML escaping everywhere, including `</textarea>` injection; CSP denies scripts and remote assets.
- CSRF synchronizer tokens on every authenticated mutation, including logout.
- Responsive single-column mobile layout and a two-column desktop editor/list layout.
- Consistent online SQLite backup, integrity check, and documented restore.
- No browser JavaScript, no CDN, no external fonts, no analytics.

## Requirements

- Linux x86_64 (other Zig targets are possible but untested).
- Zig **0.17.1** to build.
- SQLite **3.54.1** is vendored as the official amalgamation; no system SQLite is required.
- For public access: a maintained TLS terminator such as Nginx. FeatherNote never implements TLS.

## Build

```sh
zig build --release=safe
./zig-out/bin/feathernote --help
```

Zig 0.17 uses `--release=safe` rather than `-Doptimize=ReleaseSafe`. A debug build is `zig build`.

## First run

```sh
mkdir -p data
printf '%s\n' 'a long owner password' | ./zig-out/bin/feathernote admin set-password --db data/feathernote.db
./zig-out/bin/feathernote serve --db data/feathernote.db --listen 127.0.0.1:8080 --insecure-cookies
```

Open <http://127.0.0.1:8080/>. `--insecure-cookies` is only for plain-HTTP local testing; the production default uses a `__Host-` cookie and requires HTTPS.

Configuration can also be supplied through environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `FEATHERNOTE_DB` | `data/feathernote.db` | SQLite database path |
| `FEATHERNOTE_LISTEN` | `127.0.0.1:8080` | `host:port`; non-loopback binds are refused unless `--allow-public-bind` |
| `FEATHERNOTE_INSECURE_COOKIES` | `0` | `1` omits `Secure` and uses a non-`__Host-` cookie name (local tests only) |
| `FEATHERNOTE_TRUST_PROXY` | `0` | Trust `X-Real-IP` for login rate limiting; enable only behind the local proxy |
| `FEATHERNOTE_SESSION_DAYS` | `30` | Absolute session lifetime, 1-365 |
| `FEATHERNOTE_ALLOW_PUBLIC_BIND` | `0` | Allow a non-loopback listen address; intended only with an external firewall |

Flags override environment values: `--db`, `--listen`, `--insecure-cookies`, `--trust-proxy`, `--allow-public-bind`.

## HTTPS deployment

1. Build and install the binary, for example to `/usr/local/bin/feathernote`.
2. Create a service account and data directory:
   ```sh
   sudo useradd --system --home /var/lib/feathernote --shell /usr/sbin/nologin feathernote
   sudo install -d -o feathernote -g feathernote -m 700 /var/lib/feathernote
   sudo -u feathernote /usr/local/bin/feathernote admin set-password --db /var/lib/feathernote/feathernote.db
   ```
3. Install `deploy/feathernote.service` as `/etc/systemd/system/feathernote.service`, then:
   ```sh
   sudo systemctl daemon-reload
   sudo systemctl enable --now feathernote
   ```
4. Install an Nginx server block based on `deploy/nginx.conf`, replacing the hostname and certificate paths. Keep `proxy_pass http://127.0.0.1:8080` and `--trust-proxy` in the unit.
5. Confirm:
   ```sh
   curl -fsS http://127.0.0.1:8080/healthz
   curl -fsSI https://notes.example.com/login
   ```
   The public response should include `Strict-Transport-Security`, a restrictive CSP, and `X-Content-Type-Options: nosniff`.

The Zig process binds loopback only. The reverse proxy owns certificates, renewal, TLS policy, and the public request-size ceiling. The app enforces its own 320 KiB request-body limit as well.

## Backup and restore

Use the online backup API, never a plain copy of a live WAL database:

```sh
feathernote admin backup --db /var/lib/feathernote/feathernote.db \
  --out /var/backups/feathernote/daily/feathernote-$(date -u +%Y%m%dT%H%M%SZ).db
```

`scripts/backup.sh` adds daily/weekly retention (7 daily, 4 weekly). The backup command runs `PRAGMA integrity_check` on the destination before reporting success.

Restore deliberately, with the service stopped:

```sh
sudo systemctl stop feathernote
sudo scripts/restore.sh /var/backups/feathernote/daily/feathernote-YYYYmmddTHHMMSSZ.db \
  /var/lib/feathernote/feathernote.db
sudo systemctl start feathernote
```

`scripts/restore.sh` refuses to overwrite an existing database, verifies the backup, copies to a temporary name, syncs, renames, removes stale `-wal`/`-shm` sidecars, and verifies the result. Backups that leave the host must be encrypted with a separately managed key; FeatherNote does not claim end-to-end encryption, because the server reads plaintext.

## Tests

```sh
zig build test          # Zig unit tests: CRUD, search, conflicts, sessions
python3 tests/integration.py   # real server, adversarial HTTP, restart, backup/restore
```

The integration suite drives the compiled server over TCP with no JavaScript and checks login, unauthorized access, all note operations, 409 draft preservation, CSRF, XSS/`</textarea>` escaping, SQL injection in search and login, invalid UTF-8, oversized bodies, disallowed methods, logout revocation, restart persistence, an online backup taken while 40 concurrent saves are in flight, restore into a fresh directory, security headers, and absence of secrets in logs. It executes 62 checks.

## Benchmarks

```sh
python3 scripts/bench.py --requests 200 --counts 100,10000
```

Measured results, commands, machine details, and PASS/FAIL/UNVERIFIED status are in `reports/benchmarks.md` and raw JSON in `reports/benchmarks-raw.json`. Summary on this machine (ReleaseSafe, loopback, 1 KiB notes): idle RSS 6.0-6.6 MiB, idle PSS 4.6-5.1 MiB, peak RSS 23.4 MiB during Argon2id login, warm note GET p95 1.1-3.2 ms, save p95 9.1-10.6 ms, 10k-note FTS search p95 4.2 ms. See the report for exact figures and unverified items.

## Data and behaviour notes

- Timestamps are UTC Unix seconds. Titles are limited to 200 Unicode scalar values / 1 KiB; note bodies to 256 KiB; full form posts to 320 KiB; search queries to 100 bytes.
- Sessions have an absolute 30-day lifetime by default. `last_used_at` is refreshed at most hourly. Logout revokes the server-side session.
- Soft-deleted notes remain in Trash. There is no purge UI in P0; an operator can remove them with SQL after taking a backup.
- One SQLite connection is serialized by a mutex. This keeps memory predictable for one owner; the schema and service API do not assume a connection pool.
- WAL mode with `synchronous=FULL`. Acknowledged writes are committed and synced before the response. WAL is checkpointed on normal shutdown; after a crash SQLite recovers automatically.
- The service has no background worker, polling loop, websocket, or timer. Idle CPU measured at 0.0 s over a 5 s sample.
- There is no graceful-shutdown signal handler. `SIGTERM` terminates the process; committed notes survive, and SQLite recovers the WAL on the next start.

## Security limitations and non-claims

- One owner only; there is no sharing, multi-tenancy, or public registration.
- No password reset flow. Use `feathernote admin set-password` with local access; it revokes all sessions.
- Login POST is not CSRF-protected because there is no cross-account confusion possible on a single-owner instance and the form has no session. Every authenticated mutation, including logout, uses a session-bound CSRF token. This is recorded in `docs/DECISIONS.md`.
- Search uses an external-content FTS5 index. User input is split into whitespace terms, individually quoted with embedded quotes doubled, and joined with `AND`; it is never interpolated into `MATCH` as a query language. The 10k-note gate is measured in the benchmark report.
- Plaintext on the server is accessible to the server process and to anyone who can read the database. Protect file permissions and backups accordingly.
- No third-party error collection or analytics. Application logs contain route paths and errors, not note bodies, passwords, cookies, or query strings.

## Repository layout

```
src/            Zig sources: server/routes, SQLite layer, auth, HTML views, HTTP helpers
assets.zig      build-time embedding of CSS and SQL migration
web/style.css   local stylesheet (3047 bytes)
migrations/     versioned SQL schema
tests/          integration and adversarial HTTP suite
scripts/        backup, restore, seed, benchmark
deploy/         hardened systemd unit and Nginx example
reports/        measured benchmark evidence
docs/           decision log
vendor/sqlite/  pinned SQLite 3.54.1 amalgamation + checksums
```

## License

No license file is included yet. Add one before distributing binaries.
