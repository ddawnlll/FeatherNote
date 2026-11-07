#!/bin/sh
# Deliberate restore to a fresh directory. The service must be stopped first.
# Usage: scripts/restore.sh BACKUP.db TARGET_DB
set -eu
if [ "$#" -ne 2 ]; then
    echo "usage: $0 BACKUP.db TARGET_DB" >&2
    exit 2
fi
SRC="$1"
TARGET="$2"
BIN="${FEATHERNOTE_BIN:-feathernote}"

if [ ! -f "$SRC" ]; then
    echo "backup not found: $SRC" >&2
    exit 1
fi
if [ -e "$TARGET" ]; then
    echo "refusing to overwrite existing $TARGET; move it aside first" >&2
    exit 1
fi

echo "Verifying backup integrity..."
"$BIN" admin integrity --db "$SRC"

DIR="$(dirname "$TARGET")"
mkdir -p "$DIR"
# Copy to a temporary name, fsync, then rename into place.
TMP="$TARGET.restore-tmp"
cp "$SRC" "$TMP"
chmod 600 "$TMP"
sync
mv "$TMP" "$TARGET"
# Stale WAL/SHM sidecars from an old database must not be reused.
rm -f "$TARGET-wal" "$TARGET-shm"

"$BIN" admin integrity --db "$TARGET"
echo "Restored $TARGET. Start FeatherNote only after the service was stopped."
echo "Remember to verify a note in the browser after startup."
