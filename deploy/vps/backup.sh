#!/bin/bash
# Dump de la base caisse (et d'elle seule) dans $CAISSE_ROOT/backups, conservé 14 jours.
# Planifié par update.sh dans /etc/cron.d/osispos-backup (chaque nuit à 2 h) ; lancé aussi avant
# chaque mise à jour. Copier régulièrement ce dossier HORS du serveur (README §6).
set -euo pipefail
DEST="${BACKUP_DEST:-${CAISSE_ROOT:-/opt/Departement_Bi/OsisPos_Backend}/backups}"
KEEP_DAYS="${KEEP_DAYS:-14}"

mkdir -p "$DEST"
FILE="$DEST/caisse-$(date +%Y%m%d-%H%M%S).dump"
docker exec caisse-db pg_dump -U caisse -Fc caisse > "$FILE"
find "$DEST" -name 'caisse-*.dump' -mtime +"$KEEP_DAYS" -delete
echo "$(date '+%F %T') sauvegarde : $FILE ($(du -h "$FILE" | cut -f1))"
