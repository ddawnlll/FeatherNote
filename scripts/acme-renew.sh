#!/bin/sh
# Renew the configured Let's Encrypt certificate and install it into nginx.
# Safe to run before DuckDNS is configured: exits 0.
set -eu

ENV_FILE="${FEATHERNOTE_DUCKDNS_ENV:-$HOME/.config/feathernote/duckdns.env}"
if [ ! -f "$ENV_FILE" ]; then
    exit 0
fi
# shellcheck disable=SC1090
. "$ENV_FILE"
if [ -z "${DUCKDNS_DOMAIN:-}" ]; then
    exit 0
fi

DOMAIN="${DUCKDNS_DOMAIN%.duckdns.org}.duckdns.org"
ACME="$HOME/.local/bin/acme.sh"
ACME_HOME="$HOME/.acme.sh"
NGINX_PREFIX="$HOME/.local/nginx"
ACME_DIR="$ACME_HOME/$DOMAIN"

if [ ! -d "$ACME_DIR" ]; then
    exit 0
fi

"$ACME" --cron --home "$ACME_HOME" --config-home "$ACME_HOME"

if [ -f "$ACME_DIR/fullchain.cer" ] && [ -f "$ACME_DIR/$DOMAIN.key" ]; then
    install -m 0644 "$ACME_DIR/fullchain.cer" "$NGINX_PREFIX/ssl/fullchain.pem"
    install -m 0600 "$ACME_DIR/$DOMAIN.key" "$NGINX_PREFIX/ssl/privkey.pem"
    "$NGINX_PREFIX/usr/sbin/nginx" -t -p "$NGINX_PREFIX" -c etc/nginx/nginx.conf
    systemctl --user reload feathernote-nginx.service 2>/dev/null || \
        "$NGINX_PREFIX/usr/sbin/nginx" -p "$NGINX_PREFIX" -c etc/nginx/nginx.conf -s reload
fi
