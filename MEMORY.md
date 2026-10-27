# OsisPos (Caisse MYK) — mémoire du projet

Notes de reprise : ce qui a été analysé et décidé. À tenir à jour à chaque décision.

## Origine

- **Base de référence depuis le 27/10/2026 : ce code** (branche `aziz` du dev front, monorepo `apps/api`, `apps/print-agent`), celui qui tourne en production et que le front utilise.
- L'ancienne branche `main` de `MYK_POS_VPS` (backend `src/caisse`, migrations 0001-0008) est **gelée** : historique sans ancêtre commun avec celle-ci, contrat d'API différent sur 62 routes. On y reprend des idées, jamais du code tel quel (schémas incompatibles).
- `Caisse_MYK_backend` (remote `upstream`) reste la version « tout en local » (ADR-01).

## Décisions

| Date | Décision |
|---|---|
| 20/10/2026 | Backend + base sur VPS, en Docker, sans Keycloak (connexion par PIN + JWT) |
| 20/10/2026 | FNE : jamais la clé de production hors production ; `FNE_PROVIDER=mock` tant que le passage n'est pas décidé |
| 20/10/2026 | Impression tirée par l'agent du terminal (`POST /print-agent/poll` toutes les 2 s), jeton de terminal ; tiroir avec le ticket |
| 21/10/2026 | **Risque accepté** : coupure Internet au restaurant = pas de vente ni d'impression (pas de mode hors ligne) |
| 22/10/2026 | Restaurant ouvert **du lundi au vendredi**. Inventaire hebdomadaire daté du vendredi |
| 27/10/2026 | **Production : VPS OVH `148.113.149.10`** (Debian 13), dédié à la caisse ; **`caisse.osispos.com`** (DNS ResellerClub). `162.215.172.50` abandonné (à démonter : sauvegarde, `docker compose down` sans `-v`, retrait de `caisse.conf`, port 8083, cron) |
| 27/10/2026 | **Base de code = `aziz`**, pas `main` : le front, la prod et la base (migration `017`) l'utilisent ; aucune vraie vente en base, mais garder `main` coûtait ~3 semaines (front ou contrat à refaire) contre ~1,5-2 |
| 27/10/2026 | Un seul circuit de déploiement : `deploy/vps/update.sh` (sauvegarde, santé, retour arrière), lancé par le workflow GitHub ou `deploy/vps/deploy.sh`. Anciens `redeploy.sh`/`server.sh` de `main` retirés (ils visaient `/opt/caisse`) |
| 27/10/2026 | **Blocage après PIN erronés : 5 PIN faux consécutifs depuis un poste (son IP) bloquent ses connexions 5 min** (`PIN_MAX_FAILED_ATTEMPTS`, `LOCKOUT_DURATION_MINUTES`). Il n'existait pas (ces réglages n'étaient lus nulle part) : connexion par PIN seul, sans identifiant, donc blocage par poste et non par compte. Nginx transmet l'IP vue par lui (`X-Forwarded-For $remote_addr`), sinon un client contournait la limite avec un en-tête inventé |
| 27/10/2026 | WebSocket : `?token=<access_token>` ; sans jeton, toléré (`WS_REQUIRE_AUTH=false`) mais seulement le type des événements. Passer `WS_REQUIRE_AUTH=true` quand le front envoie le jeton |

## Corrections faites le 27/10/2026 (revue de `aziz`)

- WebSocket sans authentification (ventes et montants diffusés à tout Internet) → jeton, données réservées aux clients authentifiés.
- `ORDER_PAID` jamais diffusé : la route d'encaissement est synchrone, `broadcast_sync` ne trouvait pas de boucle → diffusion par la boucle de l'application (test de bout en bout).
- `get_current_user` acceptait le jeton de rafraîchissement (12 h) et le jeton d'override comme jeton d'accès.
- Renvoi FNE de fond de l'API : reprenait aussi les `PENDING` (en cours d'envoi par l'encaissement) → risque de **deux factures DGI** ; et bloquait la boucle d'événements pendant les appels HTTP.
- `restore_real_data.sql` (`TRUNCATE` des ventes) : refuse de tourner s'il y a des paiements ou des FNE, sauf confirmation explicite.
- Déploiement : sauvegarde avant migration, contrôle de santé, retour arrière, plus de `seed --demo` ni d'échec Nginx masqué ; HTTPS ; sauvegarde nocturne (timer systemd) ; `sw.js` jamais en cache.
- `api.env.example` aux noms réellement lus par `core/config.py` (l'ancien, repris de `main`, avait des noms ignorés).
- Ticket : numéro « FNE-<commande> », QR vers une adresse devinée et « Signature DGI : DGI-CI-847291048 » codée en dur s'imprimaient même pour une FNE en file ou refusée → bloc fiscal seulement pour une FNE de vente certifiée, avec le numéro et le lien (`token`) renvoyés par la DGI ; FNE simulée marquée « SANS VALEUR FISCALE ». `FNE_PROVIDER=manual` utilisait le simulateur → aucun envoi.
- `api.env` du serveur corrigé le 27/10/2026 à 16 h 11 (sauvegarde `api.env.bak-20261027-161126`) : 10 noms de l'ancien backend, ignorés, mis en commentaire ; bons noms ajoutés avec les valeurs déjà en vigueur. Puis `LOCKOUT_DURATION_MINUTES=5`.

## Questions ouvertes

- [ ] **Front** : ouvrir le WebSocket avec `?token=<access_token>` (fonction `OB()` du bundle), puis `WS_REQUIRE_AUTH=true`.
- [ ] **Avant la première vraie vente** : vider les données de test (14 commandes au 27/10), `ENABLE_DOCS=false`, comptes réels (PIN), copie des sauvegardes hors du serveur, SSH par clé seulement (README §7).
- [ ] **FNE production** (27/10/2026) : clé reçue ; URL `https://www.services.fne.dgi.gouv.ci/ws` ; établissement `RESTAURANT CHEZ SYLLA PLUS` ; stickers disponibles. Points de vente de l'espace FNE : « point de vente 1 » (Application FNE) et « Service Facturation » (TPE, avec n° de série) : **lequel pour la caisse, ou un nouveau ?** Reste : essais contre l'environnement de test DGI avec ce code (B2C espèces, mobile money, B2B avec NCC, avoir), puis bascule (FNE de test vidées d'abord, vente de contrôle).
- [ ] À examiner : `python-jose` (non maintenu, alertes de sécurité) → `PyJWT` ; `Base.metadata.create_all` au démarrage (contourne Alembic) ; routes `async` qui font des appels base synchrones (bloquent la boucle) ; `/reports/yield` de `main` contre `/reports/protein-yields` d'ici (même besoin ?) ; docs `00`/`01`/`04` décrivent encore l'architecture locale (PMS hôtelier, `infra_shared`).
- [ ] Terminal : **Windows 10 sans mises à jour depuis le 14/10/2025** → Windows 11 si compatible, ou ESU.
- [ ] Imprimante : **Xprinter 58 mm** (modèle exact, coupe-papier ?), tiroir sur l'imprimante (RJ11) ?

## Production (`148.113.149.10`)

**Déployé le 27/10/2026 à 16 h 35 : `prod-aziz` @ `053694a`** par `deploy/vps/deploy.sh` (sauvegarde `caisse-20261027-163508.dump`, ancien code dans `code.prev`). Vérifié : front et API sur `:8083`, `/health/ready` ok avec agent d'impression en ligne, WebSocket sans jeton accepté et jeton invalide refusé, `sw.js` sans cache, `osispos-backup.timer` actif. Reste : `setup-server.sh` (HTTPS) ; DNS `caisse` créé le 27/10, puis la bascule des postes.

Guide : [`deploy/vps/README.md`](deploy/vps/README.md). État relevé le 27/10/2026 (avant ces changements) : code `aziz` @ `737addc` déployé par le workflow GitHub dans `/opt/Departement_Bi/OsisPos_Backend/code` ; `api.env` avec `CORS_ORIGINS=*`, `ALLOWED_HOSTS=*`, `ENABLE_DOCS=true`, `FNE_PROVIDER=mock` ; ufw : 22 et 8083 ; pas de certificat ni de cron de sauvegarde ; SSH par mot de passe actif ; comptes `root`, `debian`, `departement_ia_osis` (sudo, sans clé).

**Réseau du bureau (Wi-Fi OSIS GROUP)** : une plage d'adresses Cloudflare (104.16.x–104.23.x : `cdn.jsdelivr.net`, `unpkg.com`, `registry.npmjs.org`, Docker Hub) ne répond pas au-delà de la connexion TCP. Passer par PyPI, `fastly.jsdelivr.net` ou `registry.npmmirror.com`.

## Matériel

- Terminal **Resolv System**, tactile tout-en-un, **Windows 10** (en anglais), wifi, Chrome et Edge, imprimante en USB.
- Imprimante **Xprinter 58 mm**, pilote du fabricant sur le Windows → 32 caractères, agent en `PRINTER_BACKEND=win32`. Ne pas installer libusb/Zadig.
