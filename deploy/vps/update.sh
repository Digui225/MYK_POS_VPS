#!/usr/bin/env bash
# Côté serveur, en root : met en service le code déposé dans $CAISSE_ROOT/code.new, par le
# workflow GitHub (.github/workflows/deploy.yml) ou par deploy/vps/deploy.sh depuis un poste.
#   sudo bash /opt/Departement_Bi/OsisPos_Backend/code.new/deploy/vps/update.sh
#
# Sauvegarde de la base, construction de la nouvelle image pendant que l'API tourne, bascule
# (les migrations Alembic passent au démarrage du conteneur), contrôle de santé, retour à la
# version précédente en cas d'échec, puis Nginx et sauvegarde nocturne.
# Une migration n'est jamais annulée : après un retour arrière, l'ancien code tourne sur le
# nouveau schéma (le message le signale). Guide : deploy/vps/README.md
set -euo pipefail
export LC_ALL=C

ROOT="${CAISSE_ROOT:-/opt/Departement_Bi/OsisPos_Backend}"
export CAISSE_ROOT="$ROOT"                    # lu par docker-compose.yml (env_file)
NEW="$ROOT/code.new"
CUR="$ROOT/code"
PREV="$ROOT/code.prev"
DOMAIN=gestion.osispos.com
NGINX_SNIPPET=/etc/nginx/snippets/osispos-locations.conf
NGINX_CONF_DIR=/etc/nginx/conf.d

info() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok() { printf '    \033[32mOK\033[0m %s\n' "$*"; }
warn() { printf '    \033[33mATTENTION\033[0m %s\n' "$*"; }
die() { printf '\n\033[31mERREUR : %s\033[0m\n' "$*" >&2; exit 1; }

dc() { local dir="$1"; shift; docker compose -f "$dir/deploy/vps/docker-compose.yml" "$@"; }
container_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
version_of() { cat "$1/VERSION" 2>/dev/null || echo '?'; }

[ "$(id -u)" = 0 ] || die "à lancer en root (sudo)"
[ -d "$NEW" ] || die "$NEW absent : déposer le code d'abord (workflow GitHub ou deploy/vps/deploy.sh)"
for f in db.env api.env; do
    [ -f "$ROOT/$f" ] || die "$ROOT/$f absent (modèle : deploy/vps/$f.example)"
done

exec 9>"$ROOT/.deploy.lock"
flock -n 9 || die "un autre déploiement est en cours sur ce serveur"

info "Mise à jour : $(version_of "$CUR") → $(version_of "$NEW")"

# Variables du modèle absentes de api.env : le code prend alors sa valeur par défaut, sans message
missing=$(comm -23 <(grep -oE '^[A-Z_]+=' "$NEW/deploy/vps/api.env.example" | sort -u) \
                   <(grep -oE '^[A-Z_]+=' "$ROOT/api.env" | sort -u) | tr -d '=' | tr '\n' ' ')
[ -z "$missing" ] || warn "absentes de $ROOT/api.env (valeur par défaut du code) : $missing"

info "Sauvegarde de la base"
if container_running caisse-db; then
    CAISSE_ROOT="$ROOT" bash "$NEW/deploy/vps/backup.sh" || die "sauvegarde impossible : rien n'a été modifié"
else
    warn "caisse-db ne tourne pas : pas de sauvegarde (première installation ?)"
fi

info "Construction de l'image (l'API actuelle continue de tourner)"
docker image inspect caisse-api:latest >/dev/null 2>&1 && docker tag caisse-api:latest caisse-api:previous
dc "$NEW" build caisse-api || die "construction en échec : rien n'a été modifié"

info "Bascule"
rm -rf "$PREV"
[ -d "$CUR" ] && mv "$CUR" "$PREV"
mv "$NEW" "$CUR"
dc "$CUR" up -d

info "Contrôle de santé (migrations comprises)"
healthy=0
for _ in $(seq 1 60); do
    if [ "$(docker inspect -f '{{.State.Health.Status}}' caisse-api 2>/dev/null)" = healthy ] \
        && curl -fsS --max-time 5 http://127.0.0.1:8011/health/ready | grep -q '"status":"ok"'; then
        healthy=1; break
    fi
    sleep 3
done
if [ "$healthy" != 1 ]; then
    docker logs --tail 40 caisse-api 2>&1 | sed 's/^/    | /'
    if [ -d "$PREV" ] && docker image inspect caisse-api:previous >/dev/null 2>&1; then
        warn "retour à $(version_of "$PREV")"
        rm -rf "$ROOT/code.failed" && mv "$CUR" "$ROOT/code.failed" && mv "$PREV" "$CUR"
        docker tag caisse-api:previous caisse-api:latest
        dc "$CUR" up -d
        die "nouvelle version en échec (code dans $ROOT/code.failed). Si elle contenait une migration, l'ancien code tourne sur le nouveau schéma : vérifier l'appli"
    fi
    die "l'API n'est pas en bonne santé et aucune version précédente n'est disponible"
fi
ok "API en bonne santé : $(version_of "$CUR")"

info "Nginx"
mkdir -p /var/www/certbot "$ROOT/nginx.prev" /etc/nginx/snippets
cp -a "$NGINX_SNIPPET" "$NGINX_CONF_DIR"/osispos*.conf "$ROOT/nginx.prev/" 2>/dev/null || true
src="$CUR/deploy/vps/nginx"
cp "$src/osispos-locations.conf" "$NGINX_SNIPPET"
cp "$src/osispos.conf" "$NGINX_CONF_DIR/osispos.conf"
if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    cp "$src/osispos-domain-https.conf" "$NGINX_CONF_DIR/osispos-domain.conf"
    ok "https://$DOMAIN"
else
    cp "$src/osispos-domain-http.conf" "$NGINX_CONF_DIR/osispos-domain.conf"
    warn "pas encore de certificat : http://$DOMAIN seulement (deploy/vps/setup-server.sh)"
fi
rm -f "$NGINX_CONF_DIR/caisse.conf"           # ancien nom, remplacé par osispos.conf
if nginx_test=$(nginx -t 2>&1); then
    systemctl reload nginx                     # jamais restart : pas de coupure des connexions
    ok "configuration rechargée"
else
    echo "$nginx_test" | sed 's/^/    | /'
    rm -f "$NGINX_CONF_DIR"/osispos*.conf
    cp -a "$ROOT/nginx.prev/"osispos*.conf "$NGINX_CONF_DIR/" 2>/dev/null || true
    cp -a "$ROOT/nginx.prev/osispos-locations.conf" "$NGINX_SNIPPET" 2>/dev/null || true
    die "nginx -t en échec : ancienne configuration remise (l'API, elle, est à jour)"
fi

info "Sauvegarde nocturne"
cat > /etc/cron.d/osispos-backup <<EOF
# OsisPos : dump de la base chaque nuit (deploy/vps/backup.sh), géré par update.sh
0 2 * * * root CAISSE_ROOT=$ROOT bash $CUR/deploy/vps/backup.sh >> $ROOT/backups/backup.log 2>&1
EOF
ok "/etc/cron.d/osispos-backup (2 h, conservation 14 jours)"

info "Terminé : $(version_of "$CUR") en service (précédente : $(version_of "$PREV"), dans code.prev)"
