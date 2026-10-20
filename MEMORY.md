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

## Périmètre de la refonte

1. **Impression dans l'autre sens** : l'agent du terminal vient chercher les tickets sur le VPS (routes « tickets en attente » / « ticket imprimé » sur `print_jobs`) ; le tiroir passe par la même file. Aujourd'hui, c'est le backend qui appelle l'agent (`PRINT_AGENT_URL`), impossible depuis le VPS.
2. **Jeton propre au terminal** pour l'agent, révocable, distinct des PIN.
3. **Agent d'impression Windows** : boucle d'interrogation, impression ESC/POS brute, service Windows. L'agent actuel (`print-agent/`) est pour Linux (systemd, udev).
4. **Déploiement de prod** : HTTPS sur le domaine, `deploy/` adapté.
5. **Nettoyage** de ce qui ne sert qu'au mode local (socle `infra_shared`, `scripts/demarrer-caisse.sh`…).

Hors périmètre : mode hors ligne. **Conséquence assumée à confirmer : sans Internet au restaurant, pas de vente ni d'impression.**

## Questions ouvertes

- [ ] Confirmer par écrit l'acceptation du risque « coupure Internet = caisse arrêtée »
- [ ] **Serveur de prod** : le VPS partagé `162.215.172.50` est sous CentOS 7 (sans mises à jour depuis 06/2024), partagé avec ~20 projets, accès `root` commun. Recommandé : VPS dédié Ubuntu 24.04. Décider avant la prod
- [ ] Terminal : caractéristiques (RAM, CPU, disque) ; **Windows 10 sans mises à jour depuis le 14/10/2025** → Windows 11 si compatible, ou ESU
- [ ] Imprimante : marque et modèle ; tiroir branché sur l'imprimante (RJ11) ?
- [ ] Nom de domaine exact, et accès DNS pour créer les sous-domaines

## Matériel

- Terminal **Resolv System**, tactile tout-en-un, **Windows 10** (en anglais), wifi, Chrome et Edge installés, imprimante en USB. Aucun logiciel de caisse existant.

## État du VPS `162.215.172.50` (recette)

Guide de référence : `projet_caisse_MYK/05-DEPLOIEMENT-VPS.md` (procédure à reprendre pour ce dépôt).

**Fait :**
- Étape 1 (inventaire) ✅ — Compose v2.27.1, SELinux **désactivé** (sauter §7.1), 298 Go libres, aucun conteneur/réseau/volume `caisse`.
- Étape 2 ✅ — `/opt/caisse/{backend,front-dist,backups}` créés ; `/opt/caisse/backend` contient **`Caisse_MYK_backend` @ `9e9ec8b`**.

**À la reprise (« étape 3 un jour prochain ») :**
1. Remplacer `/opt/caisse/backend` par **ce dépôt** : `ssh root@… "rm -rf /opt/caisse/backend && mkdir -p /opt/caisse/backend"` puis `git archive main | ssh root@… "tar -x -C /opt/caisse/backend"`.
2. Étape 3 : secrets (`db.env`, `api.env` depuis les modèles). Rien n'a encore été créé ; ensuite ne plus régénérer `db.env` après le premier démarrage de la base.
3. Travailler dans `tmux` et avec `ssh -o ServerAliveInterval=30` (coupures SSH constatées).

**Ports :**

| Port | Usage | |
|---|---|---|
| 8083 | Nginx caisse (front + `/api`) — seul port à ouvrir au pare-feu | libre |
| 8011 | API caisse, `127.0.0.1` uniquement | libre |
| — | Base caisse : **aucun port publié** (API → `caisse-db:5432` sur `caisse_net`) | |
| 8001 / 5433 / 15433 / 5434 / 5444 / 5432 | déjà pris par d'autres projets (`restomyk_web`, `cipres-postgres`, PostgreSQL de l'hôte…) | ne pas toucher |

- Sites Nginx existants liés au restaurant : `mykresto.conf` (mykresto.com → 8001), `resto-myk.conf` (7443 → 18080) — autre équipe, aucun conflit.
- Interdits sur ce VPS : `docker system prune`, `docker volume prune`, `docker compose down -v`, `systemctl restart nginx` (utiliser `reload`).
