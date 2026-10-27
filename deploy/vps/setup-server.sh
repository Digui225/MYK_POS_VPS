#!/usr/bin/env bash
# Côté serveur, en root, UNE fois (relançable sans risque) : HTTPS pour caisse.osispos.com,
# pare-feu 80/443, LLMNR coupé. Prérequis : l'enregistrement DNS A caisse → IP du serveur, et
# un premier passage de update.sh (qui sert le défi Let's Encrypt en HTTP).
#   sudo bash /opt/Departement_Bi/OsisPos_Backend/code/deploy/vps/setup-server.sh adresse@mail
# L'adresse reçoit les avis d'expiration de Let's Encrypt (renouvellement automatique sinon).
set -euo pipefail

ROOT="${CAISSE_ROOT:-/opt/Departement_Bi/OsisPos_Backend}"
DOMAIN=caisse.osispos.com
EMAIL="${1:-}"

info() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok() { printf '    \033[32mOK\033[0m %s\n' "$*"; }
die() { printf '\n\033[31mERREUR : %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "à lancer en root (sudo)"
[ -n "$EMAIL" ] || die "usage : setup-server.sh adresse@mail"
[ -f /etc/nginx/conf.d/osispos-domain.conf ] || die "lancer d'abord une mise à jour (update.sh) : Nginx ne sert pas encore $DOMAIN"

info "DNS"
server_ip=$(curl -4 -fsS --max-time 5 https://ifconfig.me)
dns_ip=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 {print $1}')
[ "$dns_ip" = "$server_ip" ] || die "$DOMAIN pointe vers « ${dns_ip:-rien} », pas vers ce serveur ($server_ip) : enregistrement A à créer ou propagation à attendre"
ok "$DOMAIN → $server_ip"

info "Pare-feu"
ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null
ok "80 et 443 ouverts ($(ufw status | grep -c ALLOW) règles)"

info "Certificat Let's Encrypt"
command -v certbot >/dev/null || { apt-get update -q && apt-get install -y -q certbot; }
mkdir -p /var/www/certbot
certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" \
    --email "$EMAIL" --agree-tos --non-interactive --keep-until-expiring
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
nginx -t && systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
systemctl is-active --quiet certbot.timer && ok "renouvellement automatique : certbot.timer actif"

info "Nginx en HTTPS"
cp /etc/nginx/conf.d/osispos-domain.conf "$ROOT/osispos-domain.conf.http"
cp "$ROOT/code/deploy/vps/nginx/osispos-domain-https.conf" /etc/nginx/conf.d/osispos-domain.conf
if nginx -t; then
    systemctl reload nginx
    ok "https://$DOMAIN"
else
    cp "$ROOT/osispos-domain.conf.http" /etc/nginx/conf.d/osispos-domain.conf
    die "nginx -t en échec : configuration HTTP remise"
fi

info "LLMNR (port 5355 ouvert pour rien sur un serveur)"
mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nLLMNR=no\n' > /etc/systemd/resolved.conf.d/no-llmnr.conf
systemctl restart systemd-resolved
ok "coupé"

info "Terminé. Vérifier depuis un poste : curl -I https://$DOMAIN"
