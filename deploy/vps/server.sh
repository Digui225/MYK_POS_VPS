#!/usr/bin/env bash
# Côté serveur : lancé par deploy.sh (install) et redeploy.sh (update) depuis le poste de
# développement, sur le code qu'ils viennent de déposer dans $ROOT/backend.new.
#   bash /opt/caisse/backend.new/deploy/vps/server.sh install|update
# Guide : deploy/vps/README.md. Ne touche qu'aux conteneurs, au réseau et au volume « caisse »,
# et à /etc/nginx/conf.d/caisse.conf ; jamais de prune ni de « down -v ».
set -euo pipefail
export LC_ALL=C                                # tri identique pour sort et comm, quelle que soit la langue

ROOT="${CAISSE_ROOT:-/opt/caisse}"
export CAISSE_ROOT="$ROOT"                     # lu par docker-compose.yml (env_file)
NEW="$ROOT/backend.new"
CUR="$ROOT/backend"
PREV="$ROOT/backend.prev"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/conf.d/caisse.conf}"
TABLES="${CAISSE_TABLES:-15}"
TERMINAL_NAME="${CAISSE_TERMINAL_NAME:-Comptoir}"

info() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok() { printf '    \033[32mOK\033[0m %s\n' "$*"; }
warn() { printf '    \033[33mATTENTION\033[0m %s\n' "$*"; }
die() { printf '\n\033[31mERREUR : %s\033[0m\n' "$*" >&2; exit 1; }

dc() { local dir="$1"; shift; docker compose -f "$dir/deploy/vps/docker-compose.yml" "$@"; }
sql() { docker exec caisse-db psql -U caisse -d caisse -tAc "$1"; }
container_exists() { docker container inspect "$1" >/dev/null 2>&1; }
port_in_use() { ss -tln | awk '{print $4}' | grep -qE "[:.]$1\$"; }

lock() {
    mkdir -p "$ROOT"
    exec 9>"$ROOT/.deploy.lock"
    flock -n 9 || die "un autre déploiement est en cours sur ce serveur"
}

wait_healthy() {
    local status
    for _ in $(seq 1 60); do
        status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
            caisse-api 2>/dev/null || echo absent)
        [ "$status" = healthy ] && return 0
        sleep 2
    done
    return 1
}

check_ready() {
    local body
    body=$(curl -s --max-time 5 http://127.0.0.1:8011/health/ready) || die "l'API ne répond pas sur 127.0.0.1:8011"
    echo "    $body"
    [[ "$body" == *'"database":"ok"'* ]] || die "l'API répond, mais pas la base"
}

swap_code() {
    [ -d "$NEW" ] || die "$NEW absent : lancer deploy.sh ou redeploy.sh depuis le poste de développement"
    rm -rf "$PREV"
    local previous=""
    if [ -d "$CUR" ]; then
        mv "$CUR" "$PREV"
        previous=" (précédent : $(cat "$PREV/VERSION" 2>/dev/null || echo '?'), dans backend.prev)"
    fi
    mv "$NEW" "$CUR"
    ok "code en place : $(cat "$CUR/VERSION" 2>/dev/null || echo '?')$previous"
}

sync_nginx() {
    local src="$CUR/deploy/vps/caisse.conf"
    if [ "${SKIP_NGINX:-0}" = 1 ] || ! command -v nginx >/dev/null; then
        warn "Nginx absent ou ignoré : $NGINX_CONF non installé"
        return 0
    fi
    if [ -f "$NGINX_CONF" ] && cmp -s "$src" "$NGINX_CONF"; then
        ok "configuration Nginx inchangée"
        return 0
    fi
    local had_old=0
    if [ -f "$NGINX_CONF" ]; then cp "$NGINX_CONF" "$ROOT/caisse.conf.prev"; had_old=1; fi
    cp "$src" "$NGINX_CONF"
    if nginx -t; then
        systemctl reload nginx           # jamais restart : les autres sites ne sont pas coupés
        ok "configuration Nginx mise à jour et rechargée (ancienne : $ROOT/caisse.conf.prev)"
    else
        if [ "$had_old" = 1 ]; then cp "$ROOT/caisse.conf.prev" "$NGINX_CONF"; else rm -f "$NGINX_CONF"; fi
        die "nginx -t a échoué : ancienne configuration remise, Nginx NON rechargé"
    fi
}

summary() {
    info "Terminé"
    echo "    Version     : $(cat "$CUR/VERSION")"
    echo "    Migration   : $(dc "$CUR" exec -T caisse-api alembic current 2>/dev/null | tail -1)"
    echo "    Conteneurs  : $(docker ps --filter label=com.docker.compose.project=caisse --format '{{.Names}} {{.Status}}' | paste -sd ',' -)"
}

# --- Première installation ---------------------------------------------------------------

install() {
    lock
    info "Vérifications"
    if container_exists caisse-db; then
        die "la caisse est déjà installée (conteneur caisse-db) : utiliser redeploy.sh"
    fi
    docker compose version >/dev/null 2>&1 || die "Docker Compose v2 requis (docker compose version)"
    if port_in_use 8011; then die "le port 8011 est déjà pris sur ce serveur"; fi
    if port_in_use 8083 && ! [ -f "$NGINX_CONF" ]; then die "le port 8083 est déjà pris sur ce serveur"; fi
    if [ ! -f "$ROOT/db.env" ] && docker volume inspect caisse_pgdata >/dev/null 2>&1; then
        die "volume caisse_pgdata existant sans $ROOT/db.env : son mot de passe est inconnu, ne rien régénérer"
    fi
    ok "Docker Compose v2, ports 8011 et 8083 libres"

    info "Dossiers et code"
    mkdir -p "$ROOT/front-dist" "$ROOT/backups"
    swap_code

    info "Secrets (db.env, api.env)"
    if [ -f "$ROOT/db.env" ] && [ -f "$ROOT/api.env" ]; then
        ok "déjà présents : conservés"
    else
        if [ -f "$ROOT/db.env" ] || [ -f "$ROOT/api.env" ]; then
            die "un seul des deux fichiers existe : les compléter à la main (guide §2)"
        fi
        local db_pwd jwt
        db_pwd=$(openssl rand -hex 24)
        jwt=$(openssl rand -base64 48 | tr -d '\n/+=')
        (umask 077
         sed "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${db_pwd}|" \
             "$CUR/deploy/vps/db.env.example" > "$ROOT/db.env"
         sed -e "s|<mot-de-passe>|${db_pwd}|" -e "s|^JWT_SECRET=.*|JWT_SECRET=${jwt}|" \
             "$CUR/deploy/vps/api.env.example" > "$ROOT/api.env")
        unset db_pwd jwt
        ok "générés (chmod 600) ; $(grep '^FNE_PROVIDER=' "$ROOT/api.env")"
    fi

    info "Construction et démarrage"
    dc "$CUR" build caisse-api
    dc "$CUR" up -d
    wait_healthy || { dc "$CUR" logs --tail 50 caisse-api; die "caisse-api n'est pas healthy"; }
    ok "caisse-db et caisse-api démarrés"

    info "Base de données"
    dc "$CUR" exec -T caisse-api alembic upgrade head
    dc "$CUR" exec -T caisse-api python -m caisse.cli bootstrap
    if [ "$(sql 'select count(*) from products')" = 0 ]; then
        dc "$CUR" exec -T caisse-api python -m caisse.cli import-catalog
        dc "$CUR" exec -T caisse-api python -m caisse.cli import-stock --stock-initial
    else
        ok "menu déjà chargé"
    fi
    if [ "$(sql 'select count(*) from restaurant_tables')" = 0 ]; then
        dc "$CUR" exec -T caisse-api python -m caisse.cli create-tables --count "$TABLES"
    fi

    info "Premier ADMIN"
    if [ "$(sql 'select count(*) from users')" != 0 ]; then
        ok "des utilisateurs existent déjà"
    elif [ -t 0 ]; then
        echo "    Nom, rôle ADMIN, puis PIN à 6 chiffres (saisi deux fois, sans affichage) :"
        dc "$CUR" exec caisse-api python -m caisse.cli create-user
    else
        warn "pas de terminal interactif : créer l'ADMIN ensuite (guide §4, create-user)"
    fi

    info "Terminal d'impression « $TERMINAL_NAME »"
    if [ "$(sql 'select count(*) from print_terminals where revoked_at is null')" != 0 ]; then
        ok "un terminal actif existe déjà (son jeton n'est plus affichable)"
    else
        echo "    ┌─ JETON DE L'AGENT : à copier MAINTENANT (gestionnaire de mots de passe) ─┐"
        dc "$CUR" exec -T caisse-api python -m caisse.cli create-print-terminal --name "$TERMINAL_NAME"
        echo "    └──────────────────────────────────────────────────────────────────────────┘"
    fi

    info "Nginx, SELinux, pare-feu, sauvegardes"
    [ -f "$ROOT/front-dist/index.html" ] || echo '<!doctype html><meta charset="utf-8"><title>Caisse MYK</title><p>Front caisse : en attente. API : <a href="/docs">/docs</a></p>' \
        > "$ROOT/front-dist/index.html"
    if command -v getenforce >/dev/null && [ "$(getenforce)" = Enforcing ]; then
        setsebool -P httpd_can_network_connect 1
        semanage port -a -t http_port_t -p tcp 8083 2>/dev/null || semanage port -m -t http_port_t -p tcp 8083
        semanage fcontext -a -t httpd_sys_content_t "$ROOT/front-dist(/.*)?" 2>/dev/null || true
        restorecon -R "$ROOT/front-dist"
        ok "SELinux : relais, port 8083 et front-dist autorisés"
    fi
    sync_nginx
    if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        if firewall-cmd --list-ports | grep -qw 8083/tcp; then
            ok "pare-feu : 8083 déjà ouvert"
        else
            firewall-cmd --permanent --add-port=8083/tcp >/dev/null && firewall-cmd --reload >/dev/null
            ok "pare-feu : 8083 ouvert (8011 reste fermé)"
        fi
    else
        warn "firewalld absent ou arrêté : ouvrir 8083 à la main si besoin"
    fi
    if [ "${SKIP_CRON:-0}" = 1 ]; then
        warn "sauvegarde quotidienne non programmée (SKIP_CRON=1)"
    elif crontab -l 2>/dev/null | grep -q 'deploy/vps/backup.sh'; then
        ok "sauvegarde quotidienne déjà programmée"
    else
        (crontab -l 2>/dev/null; echo "0 2 * * * bash $CUR/deploy/vps/backup.sh >> $ROOT/backups/backup.log 2>&1") | crontab -
        ok "sauvegarde quotidienne programmée (2 h)"
    fi

    check_ready
    summary
}

# --- Mise à jour -------------------------------------------------------------------------

update() {
    lock
    info "Vérifications"
    [ -d "$NEW" ] || die "$NEW absent : lancer redeploy.sh depuis le poste de développement"
    if [ ! -f "$ROOT/api.env" ] || [ ! -f "$ROOT/db.env" ]; then
        die "secrets absents : première installation avec deploy.sh"
    fi
    container_exists caisse-db || die "caisse-db absent : première installation avec deploy.sh"

    local example="$NEW/deploy/vps/api.env.example" missing extra
    missing=$(comm -23 <(grep -oE '^[A-Z_]+=' "$example" | sort -u) <(grep -oE '^[A-Z_]+=' "$ROOT/api.env" | sort -u))
    if [ -n "$missing" ]; then
        echo "    Variables du modèle absentes de $ROOT/api.env (avec leur commentaire) :"
        for var in $missing; do      # la variable, précédée de son bloc de commentaires
            awk -v v="$var" '/^#/ {c = c $0 "\n"; next} index($0, v) == 1 {printf "%s%s\n\n", c, $0} {c = ""}' \
                "$example" | sed 's/^/      /'
        done
        die "les ajouter (nano $ROOT/api.env) puis relancer redeploy.sh. Rien n'a été modifié."
    fi
    extra=$(comm -13 <(grep -oE '^[A-Z_]+=' "$example" | sort -u) <(grep -oE '^[A-Z_]+=' "$ROOT/api.env" | sort -u))
    [ -z "$extra" ] || warn "variables plus utilisées dans api.env (sans effet) : $(echo "$extra" | tr -d '=' | paste -sd ' ' -)"
    ok "api.env complet"

    info "Construction de la nouvelle image (l'API actuelle continue de tourner)"
    if docker image inspect caisse-api:latest >/dev/null 2>&1; then
        docker tag caisse-api:latest caisse-api:previous
    fi
    restore_image() {
        if docker image inspect caisse-api:previous >/dev/null 2>&1; then
            docker tag caisse-api:previous caisse-api:latest
        fi
    }
    dc "$NEW" build caisse-api || { restore_image; die "construction échouée. Rien n'a été modifié."; }

    info "Sauvegarde de la base"
    BACKUP_DEST="$ROOT/backups" bash "$NEW/deploy/vps/backup.sh"

    info "Migrations"
    if ! dc "$NEW" run --rm --no-deps -T caisse-api alembic upgrade head; then
        restore_image
        die "migration échouée : l'API actuelle tourne toujours sur l'ancien code. Si la base est plus
récente que ce code (retour arrière), il faut d'abord « alembic downgrade » (guide §10)."
    fi

    info "Bascule"
    swap_code
    dc "$CUR" up -d
    if ! wait_healthy; then
        dc "$CUR" logs --tail 50 caisse-api
        die "caisse-api n'est pas healthy après la mise à jour. Revenir en arrière :
    deploy/vps/redeploy.sh $(cat "$PREV/VERSION" 2>/dev/null || echo '<commit précédent>')"
    fi
    ok "caisse-api healthy"

    info "Nginx"
    sync_nginx

    check_ready
    summary
}

case "${1:-}" in
    install) install ;;
    update) update ;;
    *) die "usage : server.sh install|update" ;;
esac
