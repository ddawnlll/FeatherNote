#!/bin/sh
# Boot fallback for environments where systemd-logind cannot start the user
# manager. Prefer systemd user services; only start unmanaged processes if the
# user manager is unavailable.
set -u

HOME=/home/quant
export HOME
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
LOG="$HOME/.local/state/feathernote-boot.log"
mkdir -p "$HOME/.local/state"

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"
}

# Wait up to ~60 s for outbound networking.
i=0
while [ "$i" -lt 30 ]; do
    if curl -fsS --max-time 2 https://api.ipify.org >/dev/null 2>&1; then
        break
    fi
    sleep 2
    i=$((i + 1))
done

if timeout 10 systemctl --user is-system-running >/dev/null 2>&1; then
    timeout 20 systemctl --user start \
        feathernote.service feathernote-nginx.service \
        feathernote-backup.timer \
        >>"$LOG" 2>&1 || true
    if timeout 5 systemctl --user is-active --quiet feathernote.service && \
       timeout 5 systemctl --user is-active --quiet feathernote-nginx.service; then
        log "systemd user services active"
        exit 0
    fi
fi

log "systemd user manager unavailable; starting fallback processes"

if ! pgrep -f "$HOME/.local/bin/feathernote serve" >/dev/null 2>&1; then
    nohup sh -c "while true; do $HOME/.local/bin/feathernote serve --db $HOME/feathernote-data/feathernote.db --listen 127.0.0.1:8080 --trust-proxy; sleep 2; done" \
        >>"$LOG" 2>&1 &
    log "started fallback feathernote supervisor"
fi

if ! pgrep -f "$HOME/local/nginx/usr/sbin/nginx -p" >/dev/null 2>&1; then
    "$HOME/local/nginx/usr/sbin/nginx" -p "$HOME/local/nginx" -c etc/nginx/nginx.conf >>"$LOG" 2>&1 || true
    log "started fallback nginx"
fi
