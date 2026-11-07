# FeatherNote deployment on this host

This is the operator guide for the current installation. It runs without root
services because the sandbox blocks writes to `/etc` and `/usr`; everything is
installed under the `quant` account and managed by the **systemd user manager**
with linger enabled. nginx is the public `0.0.0.0` listener.

## Current topology

```text
Internet :80/:443
      |
      v
nginx 1.26.3 (user-space prefix, cap_net_bind_service)
      |  127.0.0.1:8080
      v
FeatherNote (systemd user service) -> SQLite at ~/feathernote-data/feathernote.db
```

- App: `127.0.0.1:8080` only, `--trust-proxy`.
- nginx: `0.0.0.0:80` and `0.0.0.0:443` (IPv4 and IPv6).
- Public IP: `212.108.82.243` (verify with `curl -s https://api.ipify.org`).
- TLS today: self-signed default certificate. A browser will warn until DuckDNS
  and Let's Encrypt are configured.
- HTTP redirects to HTTPS on port 80.

## Installed paths

| Item | Path |
|---|---|
| Source | `/home/quant/FeatherNote` |
| Binary | `/home/quant/.local/bin/feathernote` |
| Database | `/home/quant/feathernote-data/feathernote.db` |
| Initial password | `/home/quant/feathernote-data/INITIAL_PASSWORD.txt` (600) |
| Backups | `/home/quant/feathernote-backups` |
| nginx prefix | `/home/quant/.local/nginx` |
| nginx config | `/home/quant/.local/nginx/etc/nginx/nginx.conf` |
| nginx logs | `/home/quant/.local/nginx/logs/error.log` (access log disabled) |
| systemd units | `/home/quant/.config/systemd/user` |
| DuckDNS env | `/home/quant/.config/feathernote/duckdns.env` (600, currently absent) |
| acme.sh | `/home/quant/.local/bin/acme.sh`, home `/home/quant/.acme.sh` |

## First login

Read the generated owner password once:

```sh
cat /home/quant/feathernote-data/INITIAL_PASSWORD.txt
```

Open `https://212.108.82.243/` (certificate warning until DuckDNS TLS is set),
log in, then change the password and remove the initial-password file:

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
```

| Unit | Behavior |
|---|---|
| `feathernote.service` | Zig app, loopback only, restart on failure |
| `feathernote-nginx.service` | public TLS reverse proxy, restart on failure |
| `feathernote-duckdns.timer` | refresh DuckDNS every 5 min; no-op until configured |
| `feathernote-backup.timer` | daily consistent SQLite backup at 03:17 UTC |
| `feathernote-acme.timer` | weekly certificate renewal check |

Linger is enabled via `/var/lib/systemd/linger/quant`, and all units are enabled.
On a normal system this starts them at boot without an interactive login.
**However, this sandbox's `systemd-logind` currently fails with status
226/NAMESPACE**, so automatic start after a reboot is UNVERIFIED here. If the
services are not running after a reboot, log in and run:

```sh
systemctl --user start feathernote.service feathernote-nginx.service \
  feathernote-duckdns.timer feathernote-backup.timer feathernote-acme.timer
```

`scripts/boot-fallback.sh` (installed at `~/.local/bin/feathernote-boot`) is a
fallback for hosts where the user manager cannot start; it prefers systemd and
only starts unmanaged processes if necessary. Install it in a user crontab
(`@reboot /home/quant/.local/bin/feathernote-boot`) on a host where `crontab`
is writable. Writing `/var/spool/cron` is blocked in this sandbox, so that cron
entry is not installed here.

## DuckDNS + Let's Encrypt

Create a DuckDNS subdomain at <https://www.duckdns.org/>, then run once with its
token:

```sh
/home/quant/.local/bin/feathernote-configure-duckdns SUBDOMAIN TOKEN
```

Example: `... feathernote-example 12345678-1234-1234-1234-123456789abc`.

The script:

1. Writes `~/.config/feathernote/duckdns.env` with mode 600.
2. Updates the DuckDNS A record to the current public IP.
3. Uses `acme.sh` with the DuckDNS DNS-01 challenge to issue a Let's Encrypt
   certificate for `SUBDOMAIN.duckdns.org`.
4. Installs `fullchain.pem`/`privkey.pem` under `~/.local/nginx/ssl`.
5. Writes `conf.d/duckdns.conf`, tests nginx, and reloads it.
6. The weekly acme timer renews and reloads nginx.

No inbound port 80 is needed for DNS-01 issuance, but public clients need
inbound **443**. Keep **80** open as well for the HTTP-to-HTTPS redirect.

Verify after configuration:

```sh
curl -I https://SUBDOMAIN.duckdns.org/
curl -fsS https://SUBDOMAIN.duckdns.org/healthz
```

If the DNS record does not resolve to `212.108.82.243`, check the DuckDNS env
file and run `feathernote-duckdns-update` manually. If issuance fails, inspect
the acme.sh output; do not disable TLS verification.

## Updating FeatherNote

```sh
cd /home/quant/FeatherNote
git pull --ff-only
zig build --release=safe
install -m 0755 zig-out/bin/feathernote /home/quant/.local/bin/feathernote
systemctl --user restart feathernote.service
curl -fsS http://127.0.0.1:8080/healthz
```

If unit or nginx files changed:

```sh
install -m 0644 deploy/user/systemd/*.service deploy/user/systemd/*.timer \
  /home/quant/.config/systemd/user/
systemctl --user daemon-reload

install -m 0644 deploy/user/nginx/nginx.conf \
  /home/quant/.local/nginx/etc/nginx/nginx.conf
install -m 0644 deploy/user/nginx/conf.d/00-http.conf \
  deploy/user/nginx/conf.d/site.conf \
  /home/quant/.local/nginx/etc/nginx/conf.d/
/home/quant/.local/nginx/usr/sbin/nginx -t -p /home/quant/.local/nginx -c etc/nginx/nginx.conf
systemctl --user reload feathernote-nginx.service
```

If the nginx binary itself is replaced, reapply the bind capability:

```sh
sudo setcap cap_net_bind_service=+ep /home/quant/.local/nginx/usr/sbin/nginx
```

Before a schema migration, take a backup:

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
ss -ltnp | grep -E ':80 |:443 |:8080 '
curl -ksS https://127.0.0.1/healthz
curl -ksS -o /dev/null -w '%{http_code}\n' https://212.108.82.243/login
```

If local checks pass but the public URL does not, the block is outside the app:
oVirt/router NAT, provider firewall, or a missing inbound rule for TCP 80/443.
Nothing in FeatherNote needs to change for that.

## Troubleshooting

- **nginx will not start:** run
  `/home/quant/.local/nginx/usr/sbin/nginx -t -p /home/quant/.local/nginx -c etc/nginx/nginx.conf`
  and read `~/.local/nginx/logs/error.log`.
- **Permission denied binding 80/443:** reapply `setcap` to the nginx binary.
- **Login page loads but cookies do not stick:** the public URL must be HTTPS;
  the app uses a `__Host-` Secure cookie. Do not use `--insecure-cookies` here.
- **502 from nginx:** the app is down; check
  `systemctl --user status feathernote.service`.
- **DuckDNS timer fails:** inspect
  `journalctl --user -u feathernote-duckdns.service`. The token is never logged.
- **Certificate renewal:** `journalctl --user -u feathernote-acme.service`.

## Security notes

- Do not expose port 8080. Only nginx should be public.
- Keep `/home/quant/feathernote-data`, `/home/quant/.config/feathernote`, and the
  nginx private key at mode 600 or stricter.
- Do not commit DuckDNS tokens, passwords, session cookies, or note bodies.
- The app is plaintext on the server; backups leaving the host must be encrypted
  by the operator.
- nginx access logging is disabled to avoid recording search terms. Application
  logs contain route paths/errors, not note content.
