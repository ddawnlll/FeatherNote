#!/bin/sh
# Consistent local backup using SQLite's online backup API.
# Usage: scripts/backup.sh [DB] [BACKUP_DIR]
# Defaults: /var/lib/feathernote/feathernote.db and /var/backups/feathernote
set -eu
DB="${1:-/var/lib/feathernote/feathernote.db}"
DIR="${2:-/var/backups/feathernote}"
BIN="${FEATHERNOTE_BIN:-feathernote}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$DIR/daily" "$DIR/weekly"
OUT="$DIR/daily/feathernote-$STAMP.db"
"$BIN" admin backup --db "$DB" --out "$OUT"
chmod 600 "$OUT"

# Weekly copy on Sundays (UTC).
if [ "$(date -u +%u)" = "7" ]; then
    cp -p "$OUT" "$DIR/weekly/feathernote-$STAMP.db"
fi

# Retention: daily 7, weekly 4.
find "$DIR/daily" -type f -name 'feathernote-*.db' -mtime +7 -delete
find "$DIR/weekly" -type f -name 'feathernote-*.db' -mtime +28 -delete
echo "backup: $OUT"
