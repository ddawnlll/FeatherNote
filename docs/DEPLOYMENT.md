# FeatherNote deployment on this host

This is the operator guide for the current installation. It runs without root
services because the sandbox blocks writes to `/etc` and `/usr`: everything is
installed under the `quant` account and managed by the **systemd user manager**
with linger enabled. nginx is the public `0.0.0.0` TLS listener.

## Current topology

```text
Internet  :8443 (TLS, Let's Encrypt for dawnll.duckdns.org)
      |
      v
nginx 1.26.3 (user-space prefix /home/quant/local/nginx)
      |  127.0.0.1:8080
      v
FeatherNote (systemd user service) -> SQLite at ~/feathernote-data/feathernote.db
```

- App: `127.0.0.1:8080` only, `--trust-proxy`.
- nginx: `0.0.0.0:8443` and `[::]:8443` (IPv4 and IPv6).
- Public IP: `212.108.82.243` (verify with `curl -s https://api.ipify.org`).
- Public URL: <https://dawnll.duckdns.org:8443/> with a valid Let's Encrypt
  certificate (no browser warning).
- `https://212.108.82.243:8443/` still uses the self-signed default certificate
  and will warn; the domain name is the supported URL.
- Certificate: ECC, issued 2026-11-08, expires 2027-02-06. The acme timer
  renews it on 2027-01-08 and reloads nginx.
- Ports 80 and 443 are **not** bound: `net.ipv4.ip_unprivileged_port_start` is
  1024 and `sudo` requires a password. There is no HTTP-to-HTTPS redirect; use
  the `https://...:8443` URL directly.
- Host firewall: `ufw` is installed but `ENABLED=no`; `firewalld` is absent.
  External TCP probes to 8443 succeed, so inbound is open.

## Installed paths

| Item | Path |
|---|---|
| Source | `/home/quant/FeatherNote` |
| Binary | `/home/quant/.local/bin/feathernote` |
| Database | `/home/quant/feathernote-data/feathernote.db` |
| Initial password | `/home/quant/feathernote-data/INITIAL_PASSWORD.txt` (600) |
| Backups | `/home/quant/feathernote-backups` |
| nginx prefix | `/home/quant/local/nginx` |
| nginx config | `/home/quant/local/nginx/etc/nginx/nginx.conf`, `/home/quant/local/nginx/conf.d/` |
| nginx logs | `/home/quant/local/nginx/logs/error.log` (access log disabled) |
| systemd units | `/home/quant/.config/systemd/user` |
| DuckDNS env | `/home/quant/.config/feathernote/duckdns.env` (600, dawnll.duckdns.org) |
| acme.sh | wrapper `/home/quant/.local/bin/acme.sh` -> `/home/quant/local/opt/acme-sh/acme.sh`, home `/home/quant/.acme.sh` |
| Let's Encrypt cert | `/home/quant/local/nginx/ssl/fullchain.pem`, `privkey.pem` |
| Domain config | `/home/quant/local/nginx/conf.d/duckdns.conf` |

`~/.local` itself is root-owned in this sandbox; only `~/.local/bin` is
writable. That is why the nginx prefix lives under `~/local/nginx`.

## First login

Read the generated owner password once:

```sh
cat /home/quant/feathernote-data/INITIAL_PASSWORD.txt
```

Open <https://dawnll.duckdns.org:8443/> (valid certificate), log in, then change
the password and remove the initial-password file:

```sh
printf '%s\n' 'your new long password' | \
  /home/quant/.local/bin/feathernote admin set-password \
  --db /home/quant/feathernote-data/feathernote.db
shred -u /home/quant/feathernote-data/INITIAL_PASSWORD.txt
```

Changing the password revokes all sessions.

## Services and timers

```sh
systemctl --user status feathernote.service feathernote-nginx.service
systemctl --user list-timers
systemctl --user restart feathernote.service
systemctl --user reload feathernote-nginx.service
journalctl --user -u feathernote.service -n 100 --no-pager
```

| Unit | Behavior |
|---|---|
| `feathernote.service` | Zig app, loopback only, restart on failure |
| `feathernote-nginx.service` | public TLS reverse proxy on 8443, restart on failure |
| `feathernote-backup.timer` | daily consistent SQLite backup at 03:17 UTC |
| `feathernote-duckdns.timer` | refresh the DuckDNS A record every 5 minutes |
| `feathernote-acme.timer` | renew the certificate and reload nginx |

## Boot persistence

All units are `enabled` and linger is set (`Linger=yes`,
`/var/lib/systemd/linger/quant`). In a normal setup that starts the user manager
and these units at boot without a login.

**UNVERIFIED here:** this sandbox's `systemd-logind` reports `State=closing` and
previously failed with status 226/NAMESPACE, and the machine was not rebooted
during installation. After a reboot, if the public URL is down, log in and run:

```sh
systemctl --user start feathernote.service feathernote-nginx.service
```

The user crontab is not writable (`/var/spool/cron` is root-owned), so
`scripts/boot-fallback.sh` cannot be installed as an `@reboot` job here. It
remains the fallback for hosts where cron is writable.

## DuckDNS + Let's Encrypt

Configured for `dawnll.duckdns.org` -> `212.108.82.243`. The token lives in
`/home/quant/.config/feathernote/duckdns.env` (mode 600) and is never logged.
The certificate is served on 8443; DNS-01 needs no inbound port 80.

- Certificate: `/home/quant/local/nginx/ssl/fullchain.pem` and `privkey.pem`,
  ECC, expires 2027-02-06.
- Domain config: `/home/quant/local/nginx/conf.d/duckdns.conf`.
- Renewal: `feathernote-acme.timer` runs the renewal check and reloads nginx.
  Next renewal window is 2027-01-08T06:00:59Z.

Re-run configuration (prompts for the token, or reads one line from stdin):

```sh
/home/quant/.local/bin/feathernote-configure-duckdns dawnll
```

If `acme.sh` is missing or lacks `dnsapi/`, reinstall it with
`scripts/install-acme.sh`; the wrapper must point at the full tree, not the
single-file download.

Manual renewal check:

```sh
/home/quant/.local/bin/feathernote-acme-renew
journalctl --user -u feathernote-acme.service -n 50 --no-pager
```

The A record is refreshed every 5 minutes by `feathernote-duckdns.timer`. Never
disable TLS verification to work around a certificate warning.

## Updating FeatherNote

```sh
cd /home/quant/FeatherNote
git pull --ff-only
zig build --release=safe      # cold build of the SQLite amalgamation can take many minutes
install -m 0755 zig-out/bin/feathernote /home/quant/.local/bin/feathernote
systemctl --user restart feathernote.service
curl -fsS http://127.0.0.1:8080/healthz
```

If unit files changed:

```sh
install -m 0644 deploy/user/systemd/*.service deploy/user/systemd/*.timer \
  /home/quant/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user restart feathernote.service feathernote-nginx.service
```

If nginx config changed:

```sh
install -m 0644 deploy/user/nginx/nginx.conf \
  /home/quant/local/nginx/etc/nginx/nginx.conf
install -m 0644 deploy/user/nginx/conf.d/site.conf \
  /home/quant/local/nginx/conf.d/site.conf
rm -f /home/quant/local/nginx/conf.d/00-http.conf   # no port 80 listener
/home/quant/local/nginx/usr/sbin/nginx -t -p /home/quant/local/nginx -c etc/nginx/nginx.conf
systemctl --user reload feathernote-nginx.service
```

Never delete `/home/quant/feathernote-data` during an update. Take a backup
first if a migration is involved:

```sh
/home/quant/.local/bin/feathernote admin backup \
  --db /home/quant/feathernote-data/feathernote.db \
  --out /home/quant/feathernote-backups/daily/pre-update-$(date -u +%Y%m%dT%H%M%SZ).db
```

## Backup and restore

Backups run daily at 03:17 UTC and are written to
`/home/quant/feathernote-backups/daily`, with a weekly copy on Sundays. Retention
is 7 daily / 4 weekly via `scripts/backup.sh`.

Manual backup:

```sh
/home/quant/.local/bin/feathernote admin backup \
  --db /home/quant/feathernote-data/feathernote.db \
  --out /home/quant/feathernote-backups/daily/manual-$(date -u +%Y%m%dT%H%M%SZ).db
```

Restore with the service stopped:

```sh
systemctl --user stop feathernote.service
/home/quant/FeatherNote/scripts/restore.sh \
  /home/quant/feathernote-backups/daily/feathernote-YYYYmmddTHHMMSSZ.db \
  /home/quant/feathernote-data/feathernote.db.restored
# Move the old DB aside yourself, then place the restored file at the DB path.
systemctl --user start feathernote.service
```

`scripts/restore.sh` refuses to overwrite an existing file and verifies
integrity. Plain copies of a live WAL database are not valid backups; always use
the online backup command/script.

## Public reachability checks

```sh
ss -ltnp | grep -E ':8080|:8443'
curl -sS --resolve dawnll.duckdns.org:8443:127.0.0.1 https://dawnll.duckdns.org:8443/healthz
curl -sS -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' https://dawnll.duckdns.org:8443/login
```

`ssl_verify_result` should be `0`. An external TCP probe (for example
check-host.net) should show 8443 open from outside. If local checks pass but the
public URL does not, the block is outside the app: oVirt/router NAT or a provider
firewall. Nothing in FeatherNote needs to change for that.

## Troubleshooting

- **nginx will not start:** run
  `/home/quant/local/nginx/usr/sbin/nginx -t -p /home/quant/local/nginx -c etc/nginx/nginx.conf`
  and read `~/local/nginx/logs/error.log`.
- **Permission denied binding 80/443:** expected. Bind 8443 as configured, or
  get root and apply `cap_net_bind_service` before changing the port.
- **Login page loads but cookies do not stick:** the public URL must be HTTPS;
  the app uses a `__Host-` Secure cookie. Do not use `--insecure-cookies` here.
- **502 from nginx:** the app is down; check
  `systemctl --user status feathernote.service`.
- **Certificate warning on the domain:** check
  `openssl s_client -connect 127.0.0.1:8443 -servername dawnll.duckdns.org`
  and confirm nginx selected `conf.d/duckdns.conf`. The IP URL intentionally
  still serves the self-signed default certificate.
- **Certificate renewal:** `journalctl --user -u feathernote-acme.service` and
  `/home/quant/.local/bin/feathernote-acme-renew`.
- **DuckDNS A record:** `journalctl --user -u feathernote-duckdns.service`; the
  timer runs every 5 minutes and the token is never logged.

## Security notes

- Do not expose port 8080. Only nginx should be public.
- Use `https://dawnll.duckdns.org:8443/`; the certificate validates, so browser
  traffic is authenticated as well as encrypted.
- Keep `/home/quant/feathernote-data`, `/home/quant/.config/feathernote`, and the
  nginx private key at mode 600 or stricter.
- Do not commit DuckDNS tokens, passwords, session cookies, or note bodies.
- The DuckDNS token grants control of the subdomain's DNS. Rotate it at DuckDNS
  and update `duckdns.env` if it may have been exposed outside this host.
- The app is plaintext on the server; backups leaving the host must be encrypted
  by the operator.
- nginx access logging is disabled to avoid recording search terms. Application
  logs contain route paths/errors, not note content.
