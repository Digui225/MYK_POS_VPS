#!/bin/bash
# Dump de la base caisse (et d'elle seule) dans /opt/caisse/backups, conservé 14 jours.
# Cron : 0 2 * * * bash /opt/caisse/backend/deploy/vps/backup.sh >> /opt/caisse/backups/backup.log 2>&1
set -euo pipefail
DEST="${BACKUP_DEST:-${CAISSE_ROOT:-/opt/caisse}/backups}"
KEEP_DAYS="${KEEP_DAYS:-14}"

mkdir -p "$DEST"
FILE="$DEST/caisse-$(date +%Y%m%d-%H%M).dump"
docker exec caisse-db pg_dump -U caisse -Fc caisse > "$FILE"
find "$DEST" -name 'caisse-*.dump' -mtime +"$KEEP_DAYS" -delete
echo "$(date '+%F %T') sauvegarde : $FILE ($(du -h "$FILE" | cut -f1))"
