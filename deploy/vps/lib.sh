# Commun à deploy.sh et redeploy.sh, côté poste de développement (sourcé, pas exécuté).
set -euo pipefail

HOST="${CAISSE_HOST:-root@148.113.149.10}"
REMOTE_ROOT="${CAISSE_ROOT:-/opt/caisse}"
REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
REF=main
YES=0
# une seule connexion SSH pour tout le déploiement : le mot de passe n'est demandé qu'une fois
SSH_OPTS=(-o ServerAliveInterval=30 -o ControlMaster=auto
          -o "ControlPath=${TMPDIR:-/tmp}/caisse-deploy-%C" -o ControlPersist=300)

info() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '    \033[33mATTENTION\033[0m %s\n' "$*"; }
die() { printf '\n\033[31mERREUR : %s\033[0m\n' "$*" >&2; exit 1; }
# shellcheck disable=SC2029  # les commandes distantes sont construites ici, exprès
remote() { ssh "${SSH_OPTS[@]}" "$HOST" "$@"; }
close_ssh() { ssh "${SSH_OPTS[@]}" -O exit "$HOST" 2>/dev/null || true; }

usage() {
    sed -n '2,/^$/s/^# \{0,1\}//p' "$0"
    exit 0
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --host) HOST="$2"; shift 2 ;;
            -y|--yes) YES=1; shift ;;
            -h|--help) usage ;;
            -*) die "option inconnue : $1 (--help)" ;;
            *) REF="$1"; shift ;;
        esac
    done
}

check_repo() {
    cd "$REPO"
    [ -z "$(git status --porcelain)" ] \
        || die "modifications non commitées : seul le contenu commité est déployé. Commiter, puis relancer."
    SHA=$(git rev-parse --verify --quiet "$REF^{commit}") || die "référence inconnue : $REF"
    SHORT=$(git rev-parse --short "$SHA")
    if ! git branch -r --contains "$SHA" 2>/dev/null | grep -q .; then
        warn "$SHORT n'est pas encore poussé sur GitHub (git push)"
    fi
}

confirm() {
    [ "$YES" = 1 ] && return 0
    read -r -p "    Déployer $SHORT sur $HOST ? [o/N] " answer
    [[ "$answer" =~ ^[oOyY]$ ]] || die "annulé"
}

send_code() {
    info "Envoi du code ($SHORT) dans $REMOTE_ROOT/backend.new"
    git -C "$REPO" archive --format=tar "$SHA" | remote "set -e
        rm -rf '$REMOTE_ROOT/backend.new' && mkdir -p '$REMOTE_ROOT/backend.new'
        tar -x -C '$REMOTE_ROOT/backend.new'
        echo '$SHORT' > '$REMOTE_ROOT/backend.new/VERSION'"
}

run_server() {
    local tty=()
    [ "$1" = install ] && tty=(-t)       # create-user demande le PIN au clavier
    ssh "${SSH_OPTS[@]}" "${tty[@]}" "$HOST" \
        "CAISSE_ROOT='$REMOTE_ROOT' bash '$REMOTE_ROOT/backend.new/deploy/vps/server.sh' $1"
}
