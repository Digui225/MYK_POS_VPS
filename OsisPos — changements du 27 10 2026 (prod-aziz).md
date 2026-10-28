# OsisPos — changements du 27/10/2026 (prod-aziz)

Oct 28, 2026 · @isaacTech

La production tourne depuis le 27/10 sur la branche **`prod-aziz`** : ta branche `aziz` (jusqu'au commit `b3300b4` « ticket », 15 h 56) plus les corrections ci-dessous, à l'adresse **https://caisse.osispos.com** (HTTPS, certificat Let's Encrypt).

Pour toi, quatre points : fusionner `prod-aziz` dans `aziz` avant ton prochain déploiement (avance rapide, sans conflit), ouvrir le WebSocket avec `?token=`, utiliser la nouvelle adresse, et gérer le code d'erreur `PIN_LOCKOUT`. Le reste de l'API est inchangé : mêmes routes, mêmes formats, la migration reste `017`.

Version en service : `25f0695` · branche sur GitHub : `Digui225/MYK_POS_VPS`, `prod-aziz` · 191 tests verts (171 avant).

## À faire de ton côté

- [ ] **Fusionner `prod-aziz` dans `aziz` avant tout nouveau déploiement.** C'est une avance rapide (`prod-aziz` = `aziz` + 10 commits), sans conflit tant que tu n'as rien ajouté depuis `b3300b4` :

  ```bash
  git switch aziz && git pull
  git merge --ff-only origin/prod-aziz
  git push
  ```

  Si tu as des commits en plus, fais un `git merge origin/prod-aziz` normal ; les fichiers modifiés sont listés plus bas. **Sans cette fusion, ton prochain déploiement remet l'ancien code et l'ancien workflow**, et efface les corrections.
- [ ] **WebSocket : ouvrir `/api/v1/ws?token=<access_token>`** (dans le bundle, c'est la fonction qui construit l'URL `${proto}//${host}/api/v1/ws`). Un navigateur ne peut pas envoyer d'en-tête `Authorization` à l'ouverture d'un WebSocket, d'où le paramètre. À la reconnexion, prendre le jeton d'accès courant (il expire en 15 min). Quand c'est livré, on passe `WS_REQUIRE_AUTH=true` sur le serveur.
- [ ] **Afficher l'erreur `PIN_LOCKOUT`** sur l'écran de connexion (détail plus bas) : « Trop de codes PIN erronés depuis ce poste, réessayez dans N secondes », avec `meta.retry_after`.
- [ ] **Adresse de l'appli : `https://caisse.osispos.com`.** Ton build n'a rien à changer (l'API est appelée en chemin relatif `/api/v1`, le WebSocket choisit déjà `wss:` en HTTPS). Le dossier du build ne change pas : `/opt/Departement_Bi/OsisPos_Frontend/dist`.
- [ ] **Corriger ton document `DEPLOIEMENT-TECHNO-PORTS.md`** : le serveur est dédié à la caisse (aucun PMS hôtelier), le pare-feu est `ufw`, l'agent Windows n'a ni NSSM ni port 8090, il n'y a pas de mode hors ligne. Un bandeau dans le dépôt le signale déjà ; la référence est `deploy/vps/README.md`.

## Ce qui change pour le front

Cinq comportements changent ; les routes, les schémas et la base sont identiques.

| Sujet | Avant | Maintenant | Ce que le front doit faire |
| --- | --- | --- | --- |
| WebSocket `/api/v1/ws` | Accepté sans jeton, chaque client reçoit tout le détail (montants, n° de commande, table) | `?token=<access_token>` valide → détail complet. Sans jeton → accepté tant que `WS_REQUIRE_AUTH=false`, mais `data` arrive **vide** (`{"type":"ORDER_PAID","data":{}}`). Jeton invalide, expiré, de rafraîchissement ou d'override → refus (403 à l'ouverture) | Ajouter `?token=`. Ton code actuel n'utilise que `type` pour invalider les requêtes : il marche déjà tel quel |
| `ORDER_PAID` / `ORDER_PARTIALLY_PAID` | **Jamais diffusés** (l'encaissement est une route synchrone, voir plus bas) | Diffusés à chaque encaissement | Rien : le tableau de bord admin se rafraîchit enfin après un paiement |
| Jeton dans `Authorization: Bearer` | Jeton d'accès, de rafraîchissement ou d'override acceptés | **Jeton d'accès seul** ; les autres → 401 `INVALID_TOKEN` | Rien si le front envoie bien l'`access_token` (c'est le cas) |
| `POST /api/v1/auth/login` | Aucun blocage ; 10 essais/min/IP | 5 PIN faux de suite depuis un poste → **429 `PIN_LOCKOUT`** pendant 5 min, `meta.retry_after` en secondes. Un PIN juste remet le compteur à zéro. La limite 10/min (`RATE_LIMIT_EXCEEDED`) reste | Afficher le message et le délai |
| Ticket de caisse (bloc FNE) | Numéro `FNE-<n° commande>`, QR vers une adresse devinée et « Signature DGI : DGI-CI-847291048 », même pour une FNE en file ou refusée | Bloc fiscal **seulement si la FNE de vente est certifiée** : numéro et QR (`token`) renvoyés par la DGI. Simulateur (`FNE_PROVIDER=mock`) → « SIMULATION FNE – SANS VALEUR FISCALE » | Si un écran affiche un numéro FNE, le prendre dans le document FNE (`external_number`, `qr_url`) et seulement pour `status = CERTIFIED` |

Le blocage porte sur le **poste** (son adresse IP) et non sur un compte, puisque la connexion se fait par PIN seul. Tous les postes du restaurant sortent par la même IP : cinq fautes de frappe d'affilée bloquent la salle 5 minutes.

## Corrections dans le backend

Huit défauts corrigés, chacun couvert par un test ; tous les tests passent (191, contre 171 avant).

| Problème trouvé | Conséquence | Correction | Fichiers |
| --- | --- | --- | --- |
| WebSocket sans authentification | Ventes, montants et tables diffusés à n'importe qui sur Internet | Jeton `?token=` ; détail réservé aux clients authentifiés ; `WS_REQUIRE_AUTH` pour refuser les anonymes | `api/v1/ws.py`, `infrastructure/websocket/manager.py`, `core/config.py` |
| `broadcast_sync` appelé depuis une route synchrone (encaissement) | `asyncio.get_running_loop()` échoue dans le thread du pool : `ORDER_PAID` n'était **jamais** envoyé | La diffusion passe par la boucle de l'application (`run_coroutine_threadsafe`) | `infrastructure/websocket/manager.py` |
| `get_current_user` ne vérifiait pas le type de jeton | Un jeton de rafraîchissement (12 h) ou d'override ouvrait toute l'API | `type == "access"` exigé | `core/deps.py` |
| Aucun blocage après des PIN erronés | `PIN_MAX_FAILED_ATTEMPTS` et `LOCKOUT_DURATION_MINUTES` n'étaient lus nulle part | Blocage du poste 5 min après 5 échecs | `core/security_rate_limit.py`, `api/v1/auth.py` |
| Nginx transmettait l'IP annoncée par le client (`$proxy_add_x_forwarded_for`) | Limite de 10 essais/min contournée en changeant l'en-tête `X-Forwarded-For` à chaque requête | `X-Forwarded-For $remote_addr` | `deploy/vps/nginx/osispos-locations.conf` |
| Le renvoi FNE en tâche de fond de l'API reprenait aussi les FNE `PENDING` | Une FNE en cours d'envoi par l'encaissement pouvait partir deux fois : **deux factures DGI** pour une vente | `QUEUED` seulement, comme le worker FNE (qui verrouille) ; et exécuté hors de la boucle d'événements (les appels HTTP bloquaient toute l'API) | `infrastructure/outbox/dispatcher.py`, `worker.py` |
| Bloc FNE du ticket construit sans la DGI | Ticket paraissant certifié alors qu'il ne l'est pas (numéro, QR, signature inventés) | `fne_service.receipt_fne_info` : FNE de vente certifiée seulement ; duplicata = FNE de vente de la commande (plus un avoir) ; suppression de `fne_verification_base_url` | `services/fne_service.py`, `payment_service.py`, `printing_service.py`, `domain/payment_rules.py` |
| `FNE_PROVIDER=manual` utilisait le simulateur | Des FNE « certifiées » par le simulateur en mode manuel | `manual` → aucun envoi, document `MANUAL` | `core/deps.py` |

Nouveaux tests : `tests/integration/test_websocket_events.py` (un encaissement réel doit atteindre le WebSocket), `test_login_lockout.py`, `test_receipt_fne.py` ; tests mis à jour : `unit/test_websocket.py`, `unit/infrastructure/test_outbox.py`, `unit/test_security_phase2.py`. Tous les chemins ci-dessus sont sous `apps/api/src/caisse/` sauf indication.

Tu peux rejouer toute la suite localement avec un PostgreSQL jetable (`DATABASE_URL` vers une base de test, puis `pytest -q` depuis `apps/api`).

## Déploiement et serveur

Un seul circuit de mise en production désormais : `deploy/vps/update.sh` sur le serveur, lancé soit par ton workflow GitHub (push sur `main`), soit depuis un poste par `deploy/vps/deploy.sh`. Le guide de référence est `deploy/vps/README.md`.

Ce que fait `update.sh`, dans l'ordre :

1. Signale les variables du modèle absentes d'`api.env` (le code prendrait sa valeur par défaut sans rien dire).
2. **Sauvegarde la base** ; si elle échoue, s'arrête sans rien toucher.
3. Construit la nouvelle image pendant que l'API tourne ; si elle échoue, s'arrête sans rien toucher.
4. Bascule `code` → `code.prev`, `code.new` → `code`, puis `docker compose up -d` (les migrations passent au démarrage du conteneur, comme avant).
5. Contrôle de santé (`/health/ready`, 3 min au plus). En échec : **retour automatique** à la version précédente (code et image `caisse-api:previous`).
6. Installe la config Nginx, `nginx -t` puis `reload` ; en échec, remet l'ancienne config.
7. Installe la sauvegarde nocturne (timer systemd `osispos-backup.timer`, 2 h, 14 jours de conservation).

Changements par rapport à ta version :

| Élément | Avant | Maintenant |
| --- | --- | --- |
| Workflow `.github/workflows/deploy.yml` | Tests unitaires seuls ; copie directe dans `code` ; `seed --demo` à chaque déploiement ; `nginx -t … \|\| true` masquait les échecs | Tous les tests (unitaires, intégration, e2e) ; code déposé dans `code.new` puis `update.sh` ; plus de `seed --demo` ; un seul déploiement à la fois (`concurrency`). Mêmes secrets : `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY` |
| Scripts `deploy/vps/` | `deploy.sh`, `redeploy.sh`, `server.sh`, `lib.sh` repris de l'ancien backend, prévus pour `/opt/caisse` (inutilisables ici) | `update.sh` (serveur), `deploy.sh` (poste), `setup-server.sh` (HTTPS, une fois), `backup.sh` |
| Nginx | Un fichier `caisse.conf` copié en `osispos.conf` | Dossier `deploy/vps/nginx/` : `osispos-locations.conf` (commun), `osispos.conf` (IP:8083), `osispos-domain-https.conf` (domaine ; variante -http avant le certificat). `sw.js`, `registerSW.js` et le manifeste ne sont plus mis en cache ; le jeton WebSocket est hors du journal d'accès |
| `api.env` | 10 variables aux noms de l'ancien backend, ignorées sans message | Noms lus par `core/config.py` (modèle : `deploy/vps/api.env.example`). Corrigé sur le serveur, ancienne version sauvegardée |
| `restore_real_data.sql` | `TRUNCATE` des commandes, paiements et sessions sans condition | Refuse de tourner s'il y a des paiements ou des FNE, sauf confirmation explicite (voir l'en-tête du fichier) |

Le serveur : VPS OVH `148.113.149.10`, Debian 13, dédié à la caisse. Pare-feu `ufw` : 22, 80, 443, et 8083 tant que les postes ne sont pas passés sur le domaine. Code dans `/opt/Departement_Bi/OsisPos_Backend/code`, secrets dans `api.env` et `db.env` du même dossier, sauvegardes dans `backups/`. Le certificat Let's Encrypt de `caisse.osispos.com` court jusqu'au 25/01/2027 et se renouvelle seul.

## Ce qui reste

| Sujet | Qui | État |
| --- | --- | --- |
| Fusion de `prod-aziz` dans `aziz`, WebSocket `?token=`, message `PIN_LOCKOUT` | Toi | À faire (section « À faire de ton côté ») |
| `WS_REQUIRE_AUTH=true` sur le serveur | Nous | Dès que le front envoie le jeton |
| Bascule des postes : Chrome sur `https://caisse.osispos.com` (se reconnecter, désinstaller l'appli installée depuis `:8083`), agent d'impression `API_URL=https://caisse.osispos.com` | Restaurant, avec nous | À faire ; ensuite fermeture du port 8083 |
| `CORS_ORIGINS` et `ALLOWED_HOSTS` restreints au domaine, `ENABLE_DOCS=false` | Nous | Avant la première vraie vente. Si tu as encore besoin de Swagger, dis-le avant |
| Données de test à vider (14 commandes, 2 FNE simulées) | Nous | Avant la première vraie vente |
| FNE de production : URL `https://www.services.fne.dgi.gouv.ci/ws`, établissement `RESTAURANT CHEZ SYLLA PLUS` | Nous | Reste : le point de vente dédié à la caisse dans l'espace FNE, puis 4 essais contre l'environnement de test DGI (B2C espèces, mobile money, B2B avec NCC, avoir) avant la bascule |
| Docs `00`, `01`, `04` | À voir | Décrivent encore l'architecture locale (PMS hôtelier, `infra_shared`) |

Question pour toi : `python-jose` n'est plus maintenu et a des alertes de sécurité ; vois-tu un obstacle à passer sur `PyJWT` ?
