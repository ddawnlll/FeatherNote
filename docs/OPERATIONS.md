# Operating FeatherNote

FeatherNote is one binary and one SQLite database. These are the routines that
keep it durable: configuration, backup, verification, restore, and explicit
history retention.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `FEATHERNOTE_DB` | `data/feathernote.db` | database path |
| `FEATHERNOTE_LISTEN` | `127.0.0.1:8080` | `host:port` |
| `FEATHERNOTE_INSECURE_COOKIES` | `0` | local HTTP only |
| `FEATHERNOTE_TRUST_PROXY` | `0` | trust `X-Real-IP` from the local proxy |
| `FEATHERNOTE_SESSION_DAYS` | `30` | absolute session lifetime, 1 to 365 |
| `FEATHERNOTE_ALLOW_PUBLIC_BIND` | `0` | allow a non-loopback bind |

Flags override environment values. Run `feathernote --help` for the full list.

## Backup

Use the online backup command. Do not copy a live WAL database with `cp`.

```sh
feathernote admin backup --db /var/lib/feathernote/feathernote.db \
  --out /var/backups/feathernote/daily/pre-update.db
```

The command runs `PRAGMA integrity_check`, then the full read-only doctor on the
destination. That includes revision checksums and a SHA-256 recomputation of
every attachment blob. A backup that fails any check returns non-zero and is
reported as unsafe to rely on. Notes, files, revisions, sessions, and the theme
travel together in the one database file.

[`scripts/backup.sh`](../scripts/backup.sh) adds 7 daily and 4 weekly retention.
It calls the same command and fails loudly if verification fails.

## Verify

```sh
feathernote admin doctor --db /var/backups/feathernote/daily/latest.db
```

The doctor is read-only. It checks:

- SQLite integrity and foreign keys;
- FTS row parity with notes;
- revision chain shape and retention floors;
- revision content checksums;
- current-note and head-revision agreement;
- attachment ownership, size, and recomputed SHA-256;
- checkpoint label bounds and asset-manifest resolution.

It exits non-zero on any failure and never writes to the database.

## Restore

```sh
systemctl stop feathernote
mv /var/lib/feathernote/feathernote.db /var/lib/feathernote/feathernote.db.old
scripts/restore.sh /var/backups/feathernote/daily/pre-update.db \
  /var/lib/feathernote/feathernote.db
systemctl start feathernote
curl -fsS http://127.0.0.1:8080/healthz
```

The restore script refuses to overwrite an existing database, verifies the
backup with the doctor, copies to a temporary name, fsyncs, and renames it into
place. It does not stop or start the service, so do that around the restore.
Run a restore drill into a scratch directory at least once a quarter.

## Upgrade

```sh
feathernote admin backup --db /var/lib/feathernote/feathernote.db \
  --out /var/backups/feathernote/daily/pre-update-$(date -u +%Y%m%dT%H%M%SZ).db

install -m 0755 feathernote /usr/local/bin/feathernote
systemctl restart feathernote
curl -fsS http://127.0.0.1:8080/healthz
```

Schema migrations run automatically and transactionally when the new binary
opens the database. Verify with the doctor and confirm the note count after the
restart. Keep the pre-update backup until the new version has served real
traffic.

## Explicit history retention

History is append-only by default. No timer prunes it. An operator can remove
only the oldest unlabelled revisions with a dry run first:

```sh
feathernote admin purge-history --db /var/lib/feathernote/feathernote.db \
  --keep-last 50 --older-than-days 365
```

`--keep-last` is required. The command always keeps:

- the newest N revisions per note;
- every revision carrying a checkpoint label;
- every revision newer than `--older-than-days`, when set.

It removes only a contiguous unlabelled prefix below those protections, records
the first retained revision as a per-note floor, verifies labelled rows, heads,
chain shape, asset manifests, and `integrity_check`, then rolls back. Add
`--apply` to commit only after verification passes.

The History page reports any floor above r1. If a stale draft was based on a
revision that has since been purged, its 409 page still preserves the draft and
shows the latest note, but cannot show the missing base diff.

## Encryption boundary

Backups that leave the host should be encrypted with a key you manage
separately. FeatherNote does not claim end-to-end encryption, because the server
reads plaintext to render and search notes.
