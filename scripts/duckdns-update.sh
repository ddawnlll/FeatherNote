#!/bin/sh
# Refresh the DuckDNS A record from the host's current public address.
# Safe to run when unconfigured: exits 0 so a timer is not noisy.
set -eu

ENV_FILE="${FEATHERNOTE_DUCKDNS_ENV:-$HOME/.config/feathernote/duckdns.env}"
if [ ! -f "$ENV_FILE" ]; then
    exit 0
fi
# shellcheck disable=SC1090
. "$ENV_FILE"
if [ -z "${DUCKDNS_DOMAIN:-}" ] || [ -z "${DUCKDNS_TOKEN:-}" ]; then
    exit 0
fi

DOMAIN="${DUCKDNS_DOMAIN%.duckdns.org}"
case "$DOMAIN" in
    ""|*[!a-zA-Z0-9-]*) echo "duckdns: invalid subdomain" >&2; exit 1 ;;
esac
case "$DUCKDNS_TOKEN" in
    *[!a-zA-Z0-9-]*) echo "duckdns: invalid token format" >&2; exit 1 ;;
esac

RESPONSE="$(curl -fsS --get "https://www.duckdns.org/update" \
    --data-urlencode "domains=$DOMAIN" \
    --data-urlencode "token=$DUCKDNS_TOKEN" \
    --data "ip=")" || {
    echo "duckdns: update request failed" >&2
    exit 1
}
if [ "$RESPONSE" != "OK" ]; then
    echo "duckdns: update rejected: $RESPONSE" >&2
    exit 1
fi
echo "duckdns: $DOMAIN.duckdns.org -> OK"
