#!/bin/bash
# Configure DuckDNS and a Let's Encrypt certificate using the DuckDNS DNS-01
# challenge. No root and no inbound port 80 are required for issuance.
#
# Usage: scripts/configure-duckdns.sh SUBDOMAIN TOKEN
# Example: scripts/configure-duckdns.sh mynotes 12345678-1234-1234-1234-123456789abc
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 SUBDOMAIN_OR_FULL_DOMAIN DUCKDNS_TOKEN" >&2
    exit 2
fi

RAW_DOMAIN="$1"
TOKEN="$2"
SUBDOMAIN="${RAW_DOMAIN%.duckdns.org}"
DOMAIN="$SUBDOMAIN.duckdns.org"
HOME_DIR="${HOME:-/home/quant}"
NGINX_PREFIX="$HOME_DIR/.local/nginx"
ENV_DIR="$HOME_DIR/.config/feathernote"
ENV_FILE="$ENV_DIR/duckdns.env"
ACME="$HOME_DIR/.local/bin/acme.sh"
ACME_HOME="$HOME_DIR/.acme.sh"

case "$SUBDOMAIN" in
    ""|*[!a-zA-Z0-9-]*) echo "invalid DuckDNS subdomain" >&2; exit 1 ;;
esac
case "$TOKEN" in
    *[!a-zA-Z0-9-]*) echo "invalid DuckDNS token format" >&2; exit 1 ;;
esac

mkdir -p "$ENV_DIR" "$NGINX_PREFIX/ssl" "$NGINX_PREFIX/etc/nginx/conf.d" "$NGINX_PREFIX/logs" "$NGINX_PREFIX/run"
umask 077
cat > "$ENV_FILE" <<EOF
DUCKDNS_DOMAIN=$SUBDOMAIN.duckdns.org
DUCKDNS_TOKEN=$TOKEN
EOF
chmod 600 "$ENV_FILE"

echo "Updating DuckDNS..."
"$HOME_DIR/.local/bin/feathernote-duckdns-update"

if [ ! -x "$ACME" ]; then
    echo "acme.sh is missing; expected $ACME" >&2
    exit 1
fi

echo "Requesting certificate for $DOMAIN via DuckDNS DNS-01..."
export DuckDNS_Token="$TOKEN"
export DuckDNS_Subdomain="$SUBDOMAIN"
"$ACME" --home "$ACME_HOME" --config-home "$ACME_HOME" \
    --issue --dns dns_duckdns -d "$DOMAIN" \
    --server https://acme-v02.api.letsencrypt.org/directory

ACME_DIR="$ACME_HOME/$DOMAIN"
install -m 0644 "$ACME_DIR/fullchain.cer" "$NGINX_PREFIX/ssl/fullchain.pem"
install -m 0600 "$ACME_DIR/$DOMAIN.key" "$NGINX_PREFIX/ssl/privkey.pem"

cat > "$NGINX_PREFIX/etc/nginx/conf.d/duckdns.conf" <<EOF
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $DOMAIN;

    ssl_certificate     $NGINX_PREFIX/ssl/fullchain.pem;
    ssl_certificate_key $NGINX_PREFIX/ssl/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "";
        proxy_read_timeout 30s;
        proxy_send_timeout 30s;
        proxy_buffering on;
    }
}
EOF

"$NGINX_PREFIX/usr/sbin/nginx" -t -p "$NGINX_PREFIX" -c etc/nginx/nginx.conf
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user reload feathernote-nginx.service 2>/dev/null || \
        "$NGINX_PREFIX/usr/sbin/nginx" -p "$NGINX_PREFIX" -c etc/nginx/nginx.conf -s reload
else
    "$NGINX_PREFIX/usr/sbin/nginx" -p "$NGINX_PREFIX" -c etc/nginx/nginx.conf -s reload
fi

echo "Configured https://$DOMAIN/ with a Let's Encrypt certificate."
echo "Ensure inbound TCP 80 and 443 reach this host (or forward them to it)."
