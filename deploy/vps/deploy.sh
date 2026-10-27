#!/usr/bin/env bash
# Première installation de la caisse sur un serveur : code, secrets, conteneurs, base, menu,
# premier ADMIN, terminal d'impression, Nginx, pare-feu, sauvegarde quotidienne.
#
#   deploy/vps/deploy.sh [--host root@IP] [--yes] [commit|branche]
#
# Par défaut : branche main, VPS de recette root@148.113.149.10. Refuse si la caisse est déjà
# installée (utiliser redeploy.sh). Relançable après un échec : ce qui est fait est conservé.
source "$(dirname "$0")/lib.sh"
parse_args "$@"
trap close_ssh EXIT

check_repo
info "Première installation de $SHORT sur $HOST"
if remote "docker container inspect caisse-db >/dev/null 2>&1"; then
    die "la caisse est déjà installée sur $HOST : utiliser deploy/vps/redeploy.sh"
fi
echo "    Le jeton du terminal d'impression sera affiché UNE fois : prévoir de quoi le noter."
confirm
send_code
run_server install
