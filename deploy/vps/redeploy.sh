#!/usr/bin/env bash
# Mise à jour de la caisse déjà installée : nouvelle image construite pendant que l'ancienne
# tourne, sauvegarde, migrations, bascule, contrôle de santé, Nginx si caisse.conf a changé.
# S'arrête sans rien modifier si api.env n'a pas une variable ajoutée au modèle.
#
#   deploy/vps/redeploy.sh [--host root@IP] [--yes] [commit|branche]
#
# Par défaut : branche main. Retour arrière : redeploy.sh <commit précédent>.
source "$(dirname "$0")/lib.sh"
parse_args "$@"
trap close_ssh EXIT

check_repo
DEPLOYED=$(remote "cat '$REMOTE_ROOT/backend/VERSION' 2>/dev/null" || true)
[ -n "$DEPLOYED" ] || die "aucune version installée sur $HOST : utiliser deploy/vps/deploy.sh"

info "Mise à jour de $HOST : $DEPLOYED → $SHORT"
if ! git cat-file -e "$DEPLOYED^{commit}" 2>/dev/null; then
    warn "version installée $DEPLOYED inconnue de ce dépôt local (git fetch ?)"
elif [ "$(git rev-parse "$DEPLOYED")" = "$SHA" ]; then
    echo "    Même version : reconstruction et redémarrage seulement."
elif git merge-base --is-ancestor "$DEPLOYED" "$SHA"; then
    git log --oneline "$DEPLOYED..$SHA" | sed 's/^/    + /'
else
    warn "RETOUR ARRIÈRE : ces commits seront retirés"
    git log --oneline "$SHA..$DEPLOYED" | sed 's/^/    - /'
fi
if git cat-file -e "$DEPLOYED^{commit}" 2>/dev/null; then
    changed=$(git diff --name-only "$DEPLOYED" "$SHA" -- deploy/vps/api.env.example \
        deploy/vps/caisse.conf deploy/vps/docker-compose.yml alembic/versions)
    if [ -n "$changed" ]; then
        echo "    Fichiers sensibles modifiés :"
        sed 's/^/      /' <<< "$changed"
    fi
fi
confirm
send_code
run_server update
