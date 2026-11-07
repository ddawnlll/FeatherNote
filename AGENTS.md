# AGENTS.md

Guidance for coding/deployment agents working in this repository. Keep this file
high-level: commands, deployment seams and durable conventions. Product details
belong in `README.md`, tradeoffs in `docs/DECISIONS.md`, and procedures in
`docs/DEPLOYMENT.md`.

## What this is

FeatherNote: a single-owner, server-rendered notes service built with Zig 0.17.1,
SQLite 3.54.1 (vendored amalgamation), and zero mandatory JavaScript. The Zig
process binds loopback; nginx is the public TLS listener.

## Build and test

```sh
zig build --release=safe      # stripped release binary: zig-out/bin/feathernote
zig build                     # debug build
zig build test                # Zig unit tests
python3 tests/integration.py  # real HTTP acceptance/security tests (67 checks)
python3 scripts/bench.py --requests 200 --counts 100,10000
```

Zig 0.17 uses `--release=safe`, not `-Doptimize=ReleaseSafe`. The build uses a
`translate-c` module for SQLite because `@cImport` no longer exists in 0.17.

Do not weaken security to improve a benchmark. Search is FTS5; WAL uses
`synchronous=FULL`.

## Production layout on this host

Because this sandbox blocks writes to `/etc` and `/usr`, the service is installed
entirely in user space and runs under the **systemd user manager** with linger
enabled. Do not try to `apt install` system-wide or write `/etc/systemd/system`.

| Thing | Path |
|---|---|
| Source checkout | `/home/quant/FeatherNote` |
| Installed binary | `/home/quant/.local/bin/feathernote` |
| Database | `/home/quant/feathernote-data/feathernote.db` |
| Initial owner password | `/home/quant/feathernote-data/INITIAL_PASSWORD.txt` (mode 600) |
| Backups | `/home/quant/feathernote-backups/{daily,weekly}` |
| nginx prefix | `/home/quant/.local/nginx` |
| nginx binary | `/home/quant/.local/nginx/usr/sbin/nginx` (has `cap_net_bind_service`) |
| nginx config | `/home/quant/.local/nginx/etc/nginx/nginx.conf` and `conf.d/` |
| Self-signed default cert | `/home/quant/.local/nginx/ssl/selfsigned.{crt,key}` |
| Let's Encrypt cert | `/home/quant/.local/nginx/ssl/fullchain.pem`, `privkey.pem` |
| User units | `/home/quant/.config/systemd/user/` |
| DuckDNS config | `/home/quant/.config/feathernote/duckdns.env` (mode 600) |
| acme.sh | `/home/quant/.local/bin/acme.sh`, home `/home/quant/.acme.sh` |

Ports: nginx on `0.0.0.0:80` and `0.0.0.0:443`; FeatherNote on
`127.0.0.1:8080`. Never expose 8080 publicly.

## Services

```sh
systemctl --user status feathernote.service feathernote-nginx.service
systemctl --user list-timers
systemctl --user restart feathernote.service
systemctl --user reload feathernote-nginx.service
journalctl --user -u feathernote.service -n 100 --no-pager
```

Units: `feathernote.service`, `feathernote-nginx.service`,
`feathernote-duckdns.{service,timer}`, `feathernote-backup.{service,timer}`,
`feathernote-acme.{service,timer}`.

The nginx binary needs `cap_net_bind_service=+ep` to bind 80/443 as user
`quant`. Re-apply after replacing that nginx binary:

```sh
sudo setcap cap_net_bind_service=+ep /home/quant/.local/nginx/usr/sbin/nginx
```

Boot persistence: linger marker `/var/lib/systemd/linger/quant` and enabled user
units are in place, but `systemd-logind` in this sandbox fails with
226/NAMESPACE. Post-reboot auto-start is therefore UNVERIFIED; after a reboot,
log in and run `systemctl --user start feathernote.service feathernote-nginx.service`.
`scripts/boot-fallback.sh` is an optional crontab fallback.

## Update procedure (the important part)

```sh
cd /home/quant/FeatherNote
git pull --ff-only
zig build --release=safe
install -m 0755 zig-out/bin/feathernote /home/quant/.local/bin/feathernote
install -m 0644 deploy/user/systemd/*.service deploy/user/systemd/*.timer \
  /home/quant/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user restart feathernote.service
systemctl --user reload feathernote-nginx.service
systemctl --user --no-pager status feathernote.service feathernote-nginx.service
curl -fsS http://127.0.0.1:8080/healthz
```

If nginx config under `deploy/user/nginx/` changed, also copy it into
`/home/quant/.local/nginx/etc/nginx/` and run `nginx -t` before reloading.

Never delete `/home/quant/feathernote-data` during an update. Take a backup
first if a migration is involved:

```sh
/home/quant/.local/bin/feathernote admin backup \
  --db /home/quant/feathernote-data/feathernote.db \
  --out /home/quant/feathernote-backups/daily/pre-update-$(date -u +%Y%m%dT%H%M%SZ).db
```

## DuckDNS and TLS

DuckDNS credentials are not in git. Configure once:

```sh
/home/quant/.local/bin/feathernote-configure-duckdns SUBDOMAIN DUCKDNS_TOKEN
```

This writes the env file, updates DuckDNS, issues a Let's Encrypt certificate via
the DuckDNS DNS-01 challenge, writes `conf.d/duckdns.conf`, and reloads nginx.
The timer refreshes the A record every 5 minutes. Until configured, nginx serves
a self-signed certificate, which browsers will warn about.

Never log or commit `DUCKDNS_TOKEN`, the owner password, session tokens, or note
bodies.

## Product invariants

- P0 only: single owner, plaintext notes, no registration, no sharing, no JS
  requirement, no websocket/worker/SPA.
- All mutations are POST with CSRF; GET never mutates.
- Optimistic version checks must preserve a conflicting draft and return 409.
- SQL is parameterized; FTS5 input is quoted into a restricted phrase grammar.
- HTML output is escaped, including `</textarea>`.
- App stays on loopback; nginx owns public TLS.
- Performance claims must come from `reports/benchmarks.md` measurements, not
  guesses. Mark anything unmeasured UNVERIFIED.

## Git

The working repository is `/home/quant/FeatherNote`. A local bare remote is at
`/home/quant/FeatherNote.git` (`origin`). Commit small, coherent changes.
Before committing run `zig build test` and `python3 tests/integration.py`.
