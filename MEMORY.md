# MYK POS VPS — mémoire du projet

Notes de reprise : ce qui a été analysé et décidé. À tenir à jour à chaque décision.

## Origine

- Copie de `Caisse_MYK_backend` (branche `digui_remote`, commit `37f45d9`, 20/10/2026), avec l'historique.
- Remotes : `origin` = ce dépôt ; `upstream` = `Caisse_MYK_backend`, en lecture seule (push désactivé). Récupérer une correction : `git fetch upstream && git cherry-pick <commit>`.
- `Caisse_MYK_backend` reste la version « tout en local » (ADR-01) et n'est pas modifié par ce projet.

## Objectif

Faire tourner la caisse **en ligne** : backend et base sur un VPS, terminal du restaurant en client. Refonte limitée au **strict nécessaire** pour ce mode.

## Décisions

| Date | Décision |
|---|---|
| 20/10/2026 | Backend + base sur VPS, en Docker, sans Keycloak (connexion par PIN + JWT inchangée) |
| 20/10/2026 | Nouveau dépôt plutôt qu'une branche de `Caisse_MYK_backend` |
| 20/10/2026 | Déployer ce dépôt directement sur le VPS une fois la refonte prête (pas `Caisse_MYK_backend`) |
| 20/10/2026 | FNE : jamais la clé de production sur un environnement de recette ; `FNE_PROVIDER=mock` par défaut |
| 20/10/2026 | Domaine acheté pour la caisse ; sous-domaines prévus : `gestion.` (prod) et `recette.` |
| 20/10/2026 | Impression : le paiement répond tout de suite (`receipt.status = QUEUED`, `drawer_opened = null`) ; le front suit `GET /printing/jobs/{id}`. Pas d'attente de l'agent dans la requête |
| 20/10/2026 | Tiroir : s'ouvre **toujours** avec le ticket, même sorti en retard (retour de l'agent après coupure). Mais l'ouverture manuelle et le test sont refusés (`503`) si aucun agent ne s'est signalé depuis 15 s |
| 20/10/2026 | Une seule file d'impression, jeton de terminal non rattaché à une caisse (un seul poste) ; rattachement à prévoir s'il y a un 2ᵉ poste |
| 21/10/2026 | **Risque accepté** : coupure Internet au restaurant = pas de vente ni d'impression (pas de mode hors ligne) |
| 22/10/2026 | Rendement des fiches (« rapport bœuf ») : `GET /reports/yield` (ADMIN). Portion = moyenne des fiches appliquées aux ventes, prix moyen pondéré par les ventes. M. Yapi envisage un **inventaire hebdomadaire** : l'écart n'apparaît que sur une période qui contient un inventaire (à confirmer : jour de l'inventaire) |
| 22/10/2026 | Restaurant ouvert **du lundi au vendredi** seulement. Rien à changer au backend (journées comptables = jours de session). Inventaire hebdomadaire à dater du **vendredi** (compté le vendredi soir, ou le lundi matin avec `business_date` = vendredi) ; rendement interrogé du lundi au vendredi ; produits abîmés le week-end déclarés en perte le lundi |
| 21/10/2026 | Approvisionnement : rôle `ACHETEUR` (rang 0, sous CAISSIER : `CurrentUser` exige désormais CAISSIER, l'acheteur n'a que `/auth/me`, `/auth/logout`, `/purchases`). Liste = tous les articles actifs (filtre famille) ; montant = dernier prix d'achat, sinon CMP ; circuit SUBMITTED → APPROVED → DISBURSED → RECEIVED, décaissement enregistré sans mouvement de tiroir. Notification = compteur dans l'appli seulement |
| 21/10/2026 | Pagination par curseur (keyset `horodatage, id`, du plus récent au plus ancien) sur les 5 listes qui grossissent : commandes, sessions, mouvements de stock, documents FNE, tickets. 100 par défaut, 500 au plus. Les listes courtes restent entières |
| 21/10/2026 | Renvoi automatique FNE : conteneur `caisse-fne-worker` (même image que l'API, `cli fne-worker`), passage toutes les 30 s, `QUEUED` échus seulement ; jamais les incertains ni les refusés. Pas de renvoi automatique des tickets |
| 20/10/2026 | Agent : interrogation courte toutes les 2 s (`POST /print-agent/poll`), un travail à la fois ; jamais de remise en file automatique d'un travail `PRINTING` (double ticket), rejeu manuel après 2 min |

## Périmètre de la refonte

1. ✅ **Impression dans l'autre sens** (20/10/2026) : `POST /print-agent/poll` et `POST /print-agent/jobs/{id}/result` sur `print_jobs` (migration 0007) ; tiroir manuel et test = travaux `DRAWER` / `TEST`. `PRINT_AGENT_URL` supprimé. Contrat front mis à jour (`docs/ENDPOINTS-TESTABLES.md` §10).
2. ✅ **Jeton propre au terminal** (20/10/2026) : table `print_terminals`, jeton `pt_…` (empreinte SHA-256), `GET/POST /printing/terminals`, `…/revoke` (ADMIN), CLI `create-print-terminal`.
3. ✍️ **Agent d'impression Windows** (20/10/2026) : boucle d'interrogation (`poller.py`, testée en `dummy` contre l'API) ; backend `win32` = ESC/POS brut (`RAW`) par le spouleur, pilote Xprinter conservé (`win32_spool.py`, testé avec un faux pywin32) ; tâche planifiée SYSTEM au démarrage + rappel toutes les 5 min (`windows/install.ps1`). Tickets coupés aux mots sur 32 caractères. **Reste : valider sur le terminal** (nom de l'imprimante, accents CP858 sinon CP850, tiroir, imprimante éteinte → `FAILED` et ticket retiré de la file Windows).
4. **Déploiement de prod** : HTTPS sur le domaine, `deploy/` adapté.
5. **Nettoyage** de ce qui ne sert qu'au mode local (socle `infra_shared`, `scripts/demarrer-caisse.sh`…).

Hors périmètre : mode hors ligne. **Conséquence acceptée le 21/10/2026 : sans Internet au restaurant, pas de vente ni d'impression.**

## Questions ouvertes

- [ ] **Serveur de prod** : le VPS partagé `162.215.172.50` est sous CentOS 7 (sans mises à jour depuis 06/2024), partagé avec ~20 projets, accès `root` commun. Recommandé : VPS dédié Ubuntu 24.04. Décider avant la prod
- [ ] Terminal : caractéristiques (RAM, CPU, disque) ; **Windows 10 sans mises à jour depuis le 14/10/2025** → Windows 11 si compatible, ou ESU
- [ ] Imprimante : **Xprinter 58 mm** (à confirmer : modèle exact, coupe-papier ?), pilote installé sur le Windows de la caisse. Tiroir branché sur l'imprimante (RJ11) ?
- [ ] Nom de domaine exact, et accès DNS pour créer les sous-domaines

## Matériel

- Terminal **Resolv System**, tactile tout-en-un, **Windows 10** (en anglais), wifi, Chrome et Edge installés, imprimante en USB. Aucun logiciel de caisse existant.
- Imprimante **Xprinter 58 mm** (selon le client), pilote du fabricant installé sur le Windows → `PRINTER_WIDTH=32` côté API et agent, agent en `PRINTER_BACKEND=win32`. Ne pas installer libusb/Zadig.

## État du VPS `162.215.172.50` (recette)

Guide : [`deploy/vps/README.md`](deploy/vps/README.md). **Mise à jour : `deploy/vps/redeploy.sh`** depuis le poste de dev (`deploy.sh` : première installation sur un autre serveur). Scripts testés de bout en bout sur une simulation locale le 21/10/2026 (bascule ≈ 3 s).

**Déployé le 21/10/2026** : ce dépôt @ `3170d4d` (Swagger servi par l'API), migration 0007, menu et stock réels, 15 tables, ADMIN créé, terminal d'impression « Comptoir » créé (jeton noté hors dépôt), Nginx sur 8083, pare-feu ouvert. SELinux désactivé. Swagger et connexion par PIN vérifiés.

Comptes CAISSIER et RESPONSABLE créés et remis au dev front (21/10/2026).

**Reste :** cron de sauvegarde (§9 du guide) à vérifier ; front à déployer par le dev front (`docs/GUIDE-FRONT.md` §10, avec son accès SSH existant) ; puis installation et recette de l'agent Windows (§7-8).

**Réseau du bureau (Wi-Fi OSIS GROUP)** : une plage d'adresses Cloudflare (104.16.x–104.23.x : `cdn.jsdelivr.net`, `unpkg.com`, `registry.npmjs.org`, Docker Hub) ne répond pas au-delà de la connexion TCP. Contourné pour Swagger (servi par l'API). Docker Hub et npm injoignables depuis ce réseau : passer par PyPI, `fastly.jsdelivr.net` ou `registry.npmmirror.com`.

**Ports :**

| Port | Usage | |
|---|---|---|
| 8083 | Nginx caisse (front + `/api`) — seul port à ouvrir au pare-feu | libre |
| 8011 | API caisse, `127.0.0.1` uniquement | libre |
| — | Base caisse : **aucun port publié** (API → `caisse-db:5432` sur `caisse_net`) | |
| 8001 / 5433 / 15433 / 5434 / 5444 / 5432 | déjà pris par d'autres projets (`restomyk_web`, `cipres-postgres`, PostgreSQL de l'hôte…) | ne pas toucher |

- Sites Nginx existants liés au restaurant : `mykresto.conf` (mykresto.com → 8001), `resto-myk.conf` (7443 → 18080) — autre équipe, aucun conflit.
- Interdits sur ce VPS : `docker system prune`, `docker volume prune`, `docker compose down -v`, `systemctl restart nginx` (utiliser `reload`).
