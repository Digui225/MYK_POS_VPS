# AGENTS.md — Caisse MYK Backend

Backend de caisse enregistreuse (POS) de restaurant, déployé sur **VPS OVH dédié** (`148.113.149.10`, Debian 13) sur `https://caisse.osispos.com`.
Dépôt jumeau : `../Caisse_MYK_frontend` (application React / PWA connectée à cette API).
La documentation, les commentaires, les messages d'erreur et les textes d'interface sont en **français**.

## Documents de référence (à lire avant tout changement important)
- `MEMORY.md` : **mémoire des décisions d'architecture** (notamment décisions D1 à D5 du 01/11/2026).
- `docs/00-ARCHITECTURE-GLOBALE.md` : modèle de domaine, règles métier, ADR v1.2, FNE, flux de production.
- `docs/01-BACKEND.md` : couches, architecture, services, transactions, impression pull, FNE.
- `docs/03-CONTRAT-API.md` : **contrat d'API v1 gelé** (erreurs RFC 7807, idempotence, endpoints).
- `deploy/vps/README.md` et `docs/DEPLOYMENT-VPS.md` : exploitation VPS, sauvegardes systemd, Nginx, SSL Let's Encrypt.
- `docs/04-EXPLOITATION-BACKEND.md` : exploitation générale et environnement local.

## Arborescence
```
apps/api/                 service FastAPI (Python ≥ 3.12, paquet `caisse`)
  src/caisse/
    main.py               création de l'app, lifespan (outbox + ws), gestionnaires d'exceptions, routeurs
    core/                 socle transverse : config, database, security, deps, errors, pagination, idempotency, sequences
    cli/                  CLI modulaire d'administration (commandes users, db, catalog, fne, workers)
    api/v1/               routeurs HTTP : auth, catalog, orders, payments, fne, stock, purchases, production, finance, tables, users, ws, print_agent
    schemas/              modèles Pydantic v2 de requête et de réponse
    services/             cas d'usage et transactions (*_service.py)
    domain/               règles métier pures (money, fiscal, fne avec FneProvider Protocol, *_rules.py)
    repositories/         accès aux données SQLAlchemy
    models/               modèles ORM SQLAlchemy
    infrastructure/       adaptateurs : fne/ (mock, http_client), websocket/, printing/, outbox/
    seeds/                données initiales et importation catalogue
  alembic/versions/       migrations 001…018 (numérotées, séquentielles)
  tests/{unit,integration,e2e}
apps/print-agent/         agent d'impression USB ESC/POS Windows en mode PULL (tâche planifiée/service)
deploy/vps/               scripts de déploiement et configuration Docker Compose / Nginx de production
```

## Commandes (à lancer depuis `apps/api/`)
```bash
.venv/bin/pytest                          # tous les tests (SQLite en mémoire, voir tests/conftest.py)
.venv/bin/pytest tests/unit -q            # tests unitaires du domaine pur
.venv/bin/pytest tests/integration -q     # tests d'intégration des routes et services
.venv/bin/ruff check src tests            # linter Ruff (longueur de ligne 100)
.venv/bin/mypy src                        # vérification des types (mode strict)
.venv/bin/uvicorn caisse.main:app --reload --port 8001
.venv/bin/alembic upgrade head            # appliquer les migrations
.venv/bin/alembic revision -m "019_..."   # nouvelle migration, préfixe séquentiel NNN_ obligatoire
.venv/bin/python -m caisse.cli --help     # administration : create-user, reset-pin, seed, etc.
```
La configuration vient de `apps/api/.env` (modèle : `deploy/vps/api.env.example` ou `apps/api/.env.example`, chargé par `caisse.core.config`).
Documentation OpenAPI : `/docs` et `/openapi.json` sur le port 8001.

## Invariants non négociables
1. **Les montants sont des entiers en XOF** pour tous les totaux, paiements et soldes.
   *Exception documentée (D3)* : les coûts unitaires d'achat et le coût moyen pondéré (`avg_cost_xof`) tolèrent 2 décimales pour les fiches techniques portant sur des sous-unités (grammes, centilitres).
2. **Rien ne se modifie ni ne s'efface après encaissement.** Les corrections passent par des opérations inverses tracées (remboursements, annulations, avoirs).
3. **Une FNE (facture normalisée) par ticket.** Attente bornée à 4 s, puis repli automatique sur une transmission différée via l'outbox DGI.
4. **Le contrat d'API v1 est gelé.** Toute modification d'une route ou d'un schéma doit rester rétrocompatible et être reportée dans `docs/03-CONTRAT-API.md`. Régénérer `openapi.json` pour que le frontend mette à jour ses types (`npm run api:types`).
5. Les endpoints de mutation respectent les **clés d'idempotence** (`caisse.core.idempotency`) et reçoivent l'en-tête `X-Device-Id`.
6. **Sécurité des jetons** : authentification par PIN (argon2) et paire JWT access/refresh. Les jetons restent en mémoire côté frontend (D2).
7. `fne-probe` appelle la vraie API de la DGI et **consomme un sticker** réel. Ne jamais le lancer sans l'accord explicite de l'utilisateur.

## Conventions
- Couches strictes : routeur HTTP → service applicatif → (règles pures `domain/` + repositories SQLAlchemy). Aucun SQL direct dans les routeurs.
- Erreurs métier : lever des sous-classes de `CaisseException` (`caisse.core.errors`).
- Rôles : `ECONOME`, `CAISSIER`, `RESPONSABLE`, `ADMIN` (définis dans `caisse.domain.enums`).
- Tout changement de schéma demande une nouvelle migration séquentielle Alembic. Ne jamais modifier une migration déjà déployée en production.
- Fuseau horaire : `Africa/Abidjan`.
