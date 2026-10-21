# Déploiement de recette sur le VPS partagé — MYK_POS_VPS

VPS `162.215.172.50` (CentOS 7, partagé avec ~20 projets) · branche `main` de ce dépôt ·
**environnement de RECETTE** : données fictives, HTTP sans chiffrement, FNE simulée.

Ce guide remplace, pour ce dépôt, `projet_caisse_MYK/05-DEPLOIEMENT-VPS.md` (écrit pour
`Caisse_MYK_backend`). Il reprend là où le déploiement s'est arrêté : **étapes 1 et 2 de ce
guide-là déjà faites** (inventaire, dossiers `/opt/caisse/{backend,front-dist,backups}`).

## Ce qui change par rapport au guide 05

| | Guide 05 (`Caisse_MYK_backend`) | Ici |
|---|---|---|
| Code déployé | dossier `caisse-backend`, branche `digui_remote` | `MYK_POS_VPS`, branche `main` |
| Impression | aucune sur le VPS (`PRINT_AGENT_URL` injoignable) | l'agent du terminal du restaurant vient chercher les tickets sur `http://162.215.172.50:8083` |
| Nouveauté | — | création du **terminal d'impression** (jeton de l'agent) et installation de l'agent sur le Windows de la caisse |
| Largeur des tickets | 48 (80 mm) | `PRINTER_WIDTH=32` (Xprinter 58 mm) |
| SELinux | §7.1 à faire si `Enforcing` | **désactivé** sur ce VPS : rien à faire |

## Règles du VPS (inchangées)

- **Jamais** : `docker system prune`, `docker volume prune`, `docker compose down -v`,
  `systemctl restart nginx` (toujours `nginx -t && systemctl reload nginx`).
- Ne toucher à aucun autre projet. Ports caisse : **8083** (Nginx, seul port public) et
  **8011** (API, `127.0.0.1` seulement) ; la base n'a aucun port sur l'hôte.
- Travailler dans `tmux` et se connecter avec `ssh -o ServerAliveInterval=30 root@162.215.172.50`
  (coupures SSH constatées).
- Une modification de `deploy/vps/` se fait **dans le dépôt**, est commitée, puis redéployée.

---

## 1. Remplacer le code

`/opt/caisse/backend` contient encore `Caisse_MYK_backend` @ `9e9ec8b` (jamais démarré) : on le
remplace par ce dépôt. Seul le contenu commité part (`git archive`), sans `.env` ni `.git`.

```bash
# Sur ta machine
cd ~/Projets_thio_isaac/MYK_POS_VPS
git status                                   # rien en attente sur main

ssh root@162.215.172.50 "rm -rf /opt/caisse/backend && mkdir -p /opt/caisse/backend"
git archive --format=tar main | ssh root@162.215.172.50 "tar -x -C /opt/caisse/backend"
git rev-parse --short main | ssh root@162.215.172.50 "cat > /opt/caisse/backend/VERSION"
```

## 2. Secrets : `db.env` et `api.env`

À faire **une seule fois** : `db.env` n'est lu par PostgreSQL qu'au premier démarrage de la base.

```bash
# Sur le VPS
cd /opt/caisse
ls db.env api.env 2>/dev/null && echo "STOP : déjà créés, ne pas régénérer"

DB_PWD=$(openssl rand -hex 24)
JWT=$(openssl rand -base64 48 | tr -d '\n/+=')
sed "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${DB_PWD}|" \
  backend/deploy/vps/db.env.example > db.env
sed -e "s|<mot-de-passe>|${DB_PWD}|" -e "s|^JWT_SECRET=.*|JWT_SECRET=${JWT}|" \
  backend/deploy/vps/api.env.example > api.env
chmod 600 db.env api.env
unset DB_PWD JWT

grep -qE '<mot-de-passe>|^JWT_SECRET=$|^POSTGRES_PASSWORD=$' db.env api.env \
  && echo "ERREUR : secret manquant" || echo "OK : secrets renseignés"
grep -E '^(PRINTER_WIDTH|FNE_PROVIDER)=' api.env     # PRINTER_WIDTH=32, FNE_PROVIDER=mock

cd /opt/caisse/backend/deploy/vps && docker compose config --quiet && echo "Syntaxe OK"
```

`FNE_PROVIDER=mock` : **jamais la clé FNE de production** dans ce fichier (chaque FNE de test
deviendrait une vraie facture).

## 3. Build et démarrage

```bash
cd /opt/caisse/backend/deploy/vps
docker compose build caisse-api
docker compose up -d
docker compose ps                         # caisse-db et caisse-api : healthy (≈ 30 s)
docker compose logs --tail 50 caisse-api
```

## 4. Base, données et terminal d'impression

```bash
cd /opt/caisse/backend/deploy/vps
docker compose exec caisse-api alembic upgrade head
docker compose exec caisse-api alembic current          # 0007 (head)

docker compose exec caisse-api python -m caisse.cli bootstrap
docker compose exec caisse-api python -m caisse.cli create-user      # premier ADMIN (PIN 6 chiffres)

docker compose exec caisse-api python -m caisse.cli import-catalog
docker compose exec caisse-api python -m caisse.cli import-stock --stock-initial
docker compose exec caisse-api python -m caisse.cli create-tables --count 15

# Jeton de l'agent d'impression du restaurant : affiché UNE SEULE FOIS, à noter tout de suite
docker compose exec caisse-api python -m caisse.cli create-print-terminal --name Comptoir
```

Ne pas mélanger `seed --demo` avec le menu réel. Pour les tests, un utilisateur par rôle
(`CAISSIER`, `RESPONSABLE`, `ADMIN`) avec `create-user`.

Jeton perdu : le révoquer (`POST /api/v1/printing/terminals/{id}/revoke`, ADMIN) et en créer un
autre sous un nouveau nom (`--name Comptoir-2`).

## 5. Nginx et pare-feu

```bash
cp /opt/caisse/backend/deploy/vps/caisse.conf /etc/nginx/conf.d/caisse.conf
[ -f /opt/caisse/front-dist/index.html ] || echo '<!doctype html><meta charset="utf-8"><title>Caisse MYK</title><p>Front caisse : en attente. API : <a href="/docs">/docs</a></p>' \
  > /opt/caisse/front-dist/index.html
nginx -t && systemctl reload nginx

firewall-cmd --permanent --add-port=8083/tcp && firewall-cmd --reload
firewall-cmd --list-ports                 # 8083 présent ; 8011 ABSENT
```

`nginx -t` en échec : **ne pas recharger**, corriger ou retirer `/etc/nginx/conf.d/caisse.conf`.

## 6. Vérification

```bash
# Sur le VPS
curl -s http://127.0.0.1:8011/health/ready     # "database":"ok" ; agent_online:false tant que l'agent n'est pas installé
docker ps --format 'table {{.Names}}\t{{.Status}}'   # les autres projets toujours Up

# Depuis ta machine
curl -s http://162.215.172.50:8083/api/v1/health                               # {"status":"ok"}
curl -s --max-time 5 http://162.215.172.50:8011/health || echo "OK : 8011 fermé depuis l'extérieur"
```

Swagger : `http://162.215.172.50:8083/docs`, **Authorize** avec le `access_token` de
`POST /api/v1/auth/login` `{"pin": "…", "device_id": "poste-test"}`.

## 7. Agent d'impression sur le terminal Windows

Procédure détaillée : [`print-agent/README.md`](../../print-agent/README.md), section Windows.

```bash
# Sur ta machine : le dossier de l'agent, à copier sur le terminal (clé USB, partage…)
cd ~/Projets_thio_isaac/MYK_POS_VPS
git archive --format=zip -o ~/print-agent.zip main print-agent
```

Sur le terminal : Python 3.12 **pour tous les utilisateurs**, dézipper dans `C:\CaisseMYK\`, puis
dans PowerShell administrateur `windows\install.ps1` (deux passages). Dans `.env` :

```
API_URL=http://162.215.172.50:8083
TERMINAL_TOKEN=pt_…              # celui du §4
PRINTER_NAME=…                   # nom affiché par le premier passage d'install.ps1
```

## 8. Recette du circuit d'impression

À cocher avec quelqu'un devant la caisse :

- [ ] `GET /api/v1/printing/status` : `agent_online: true`, `width: 32`
- [ ] `POST /api/v1/printing/test` (ADMIN) : ticket sorti, **accents lisibles** (sinon
      `PRINTER_CODEPAGE=CP850` dans le `.env` du terminal, puis redémarrer la tâche)
- [ ] `POST /api/v1/printing/open-drawer` (RESPONSABLE) : le tiroir s'ouvre
- [ ] Vente complète (ouverture de session, commande, paiement : `docs/CIRCUIT-TEST-SWAGGER.md`) :
      ticket et tiroir sous ~2 s, `GET /api/v1/printing/jobs/{print_job_id}` → `DONE`
- [ ] Imprimante éteinte puis vente : le travail finit `FAILED` **et ne sort pas** au rallumage ;
      `POST /api/v1/printing/jobs/{id}/retry` le réimprime une fois
- [ ] Wifi du terminal coupé 1 min puis rétabli : les tickets en attente sortent
- [ ] Redémarrage de Windows : l'agent repart seul (`agent_online: true` sans ouvrir de session)
- [ ] Agent tué dans le Gestionnaire des tâches : il repart dans les 5 min

Noter les résultats dans `MEMORY.md`.

## 9. Sauvegardes

```bash
( crontab -l 2>/dev/null; echo "0 2 * * * bash /opt/caisse/backend/deploy/vps/backup.sh >> /opt/caisse/backups/backup.log 2>&1" ) | crontab -
bash /opt/caisse/backend/deploy/vps/backup.sh && ls -lh /opt/caisse/backups
```

Restauration et commandes du quotidien : guide 05, §10 et §12 (identiques).

## 10. Mise à jour

```bash
# Sur ta machine
cd ~/Projets_thio_isaac/MYK_POS_VPS && git status
ssh root@162.215.172.50 "rm -rf /opt/caisse/backend && mkdir -p /opt/caisse/backend"
git archive --format=tar main | ssh root@162.215.172.50 "tar -x -C /opt/caisse/backend"
git rev-parse --short main | ssh root@162.215.172.50 "cat > /opt/caisse/backend/VERSION"

# Sur le VPS
bash /opt/caisse/backend/deploy/vps/backup.sh
cd /opt/caisse/backend/deploy/vps
docker compose build caisse-api && docker compose up -d caisse-api
docker compose exec caisse-api alembic upgrade head
diff <(grep -oE '^[A-Z_]+=' api.env.example | sort) <(grep -oE '^[A-Z_]+=' /opt/caisse/api.env | sort)
```

Nouvelle variable dans `api.env.example` : la reporter dans `/opt/caisse/api.env`, puis
`docker compose up -d caisse-api`. `caisse.conf` modifié : le recopier, `nginx -t`, `reload`.

## 11. Dépannage de l'impression

Le reste (secrets, CORS, 502, SELinux…) : guide 05, §13.

| Symptôme | Cause probable | Solution |
|---|---|---|
| `agent_online: false` | Agent arrêté, mauvais `API_URL`, terminal sans Internet | `logs\agent.log` sur le terminal ; depuis le terminal, ouvrir `http://162.215.172.50:8083/api/v1/health` dans Chrome |
| Journal de l'agent : « jeton de terminal refusé » | Jeton mal copié ou révoqué | Recréer un terminal (§4), mettre à jour `.env`, redémarrer la tâche |
| Tickets restés `QUEUED`, agent en ligne | L'agent rapporte l'imprimante hors ligne (`printer_online: false`) | Windows : décocher « Utiliser l'imprimante hors connexion », papier, capot |
| Tickets `FAILED` « toujours dans la file Windows » | Imprimante éteinte, câble USB, mauvais `PRINTER_NAME` | Vérifier dans Paramètres > Imprimantes, puis rejouer depuis la caisse |
| Accents faux | Page de code | `PRINTER_CODEPAGE=CP850` |
| Lignes coupées en deux | Largeur différente entre API et imprimante | `PRINTER_WIDTH=32` dans `/opt/caisse/api.env` **et** dans le `.env` du terminal |
| `503 PRINT_AGENT_UNAVAILABLE` sur le tiroir ou le test | Aucun agent depuis 15 s | Normal tant que l'agent n'est pas en ligne |

## 12. Accès du dev front

Le dev front dépose son build dans `/opt/caisse/front-dist` avec un compte qui ne peut écrire
que là (procédure côté front : [`docs/GUIDE-FRONT.md`](../../docs/GUIDE-FRONT.md) §10). Il envoie
sa **clé publique** SSH ; on ne lui donne jamais le mot de passe `root`.

```bash
# Sur le VPS
id caisse-front 2>/dev/null || useradd -m caisse-front
mkdir -p /home/caisse-front/.ssh
nano /home/caisse-front/.ssh/authorized_keys          # coller sa clé publique (une ligne ssh-ed25519 …)
chown -R caisse-front: /home/caisse-front/.ssh
chmod 700 /home/caisse-front/.ssh && chmod 600 /home/caisse-front/.ssh/authorized_keys

chown -R caisse-front: /opt/caisse/front-dist
chmod 755 /opt/caisse
ls -l /opt/caisse/db.env /opt/caisse/api.env          # -rw------- root : illisibles pour lui
```

Test depuis sa machine : `ssh caisse-front@162.215.172.50 "ls /opt/caisse/front-dist"`.

À lui transmettre :
- `docs/GUIDE-FRONT.md` (branchement, déploiement §10, nouveautés) et
  `docs/ENDPOINTS-TESTABLES.md` (détail des routes), ou un accès en lecture au dépôt ;
- un PIN par rôle (`CAISSIER`, `RESPONSABLE`, `ADMIN`), **par un canal privé** ;
- pas le jeton du terminal d'impression : il ne sert qu'à l'agent.
