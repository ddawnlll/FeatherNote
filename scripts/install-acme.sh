#!/bin/sh
# Install a user-space acme.sh with its DNS API hooks.
#
# The single-file download lacks dnsapi/, which breaks DNS-01 providers such as
# DuckDNS. This installs the full tree and a wrapper at ~/.local/bin/acme.sh.
set -eu

DEST="${1:-$HOME/local/opt/acme-sh}"
BIN="$HOME/.local/bin/acme.sh"

mkdir -p "$(dirname "$DEST")" "$HOME/.local/bin"
if [ ! -d "$DEST/.git" ]; then
    git clone --depth 1 https://github.com/acmesh-official/acme.sh.git "$DEST"
fi

cat >"$BIN" <<EOF
#!/bin/sh
# Wrapper so acme.sh finds its bundled dnsapi/ hooks.
exec "$DEST/acme.sh" "\$@"
EOF
chmod 0755 "$BIN"
"$BIN" --version
