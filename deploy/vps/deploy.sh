#!/usr/bin/env bash
# Depuis un poste de développement : déploie une version COMMITÉE sur le VPS, sans passer par
# GitHub Actions (même mise en place côté serveur : deploy/vps/update.sh).
#   deploy/vps/deploy.sh [référence]        # défaut : HEAD
#   OSISPOS_HOST=debian@148.113.149.10 deploy/vps/deploy.sh
# Une seule connexion SSH (mot de passe ou phrase de clé demandé une fois).
set -euo pipefail

HOST="${OSISPOS_HOST:-debian@148.113.149.10}"
ROOT="${CAISSE_ROOT:-/opt/Departement_Bi/OsisPos_Backend}"
REF="${1:-HEAD}"
SSH_OPTS=(-o ServerAliveInterval=30 -o ControlMaster=auto
          -o "ControlPath=${TMPDIR:-/tmp}/osispos-deploy-%C" -o ControlPersist=300)
die() { printf '\n\033[31mERREUR : %s\033[0m\n' "$*" >&2; exit 1; }

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
[ -z "$(git status --porcelain)" ] || die "modifications non commitées : seul le contenu commité est déployé"
SHA=$(git rev-parse --verify --quiet "$REF^{commit}") || die "référence inconnue : $REF"
SHORT=$(git rev-parse --short "$SHA")

git log -1 --format='    %h %s (%an, %ad)' --date=short "$SHA"
read -r -p "    Déployer $SHORT en PRODUCTION sur $HOST ? [o/N] " answer
[[ "$answer" =~ ^[oOyY]$ ]] || die "annulé"

trap 'ssh "${SSH_OPTS[@]}" -O exit "$HOST" 2>/dev/null || true' EXIT
git archive --format=tar "$SHA" | ssh "${SSH_OPTS[@]}" "$HOST" "set -e
    sudo rm -rf '$ROOT/code.new' && sudo mkdir -p '$ROOT/code.new'
    sudo tar -x -C '$ROOT/code.new'
    echo '$SHORT' | sudo tee '$ROOT/code.new/VERSION' >/dev/null"
ssh "${SSH_OPTS[@]}" -t "$HOST" "sudo bash '$ROOT/code.new/deploy/vps/update.sh'"
