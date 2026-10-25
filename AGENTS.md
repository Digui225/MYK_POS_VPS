# AGENTS.md — Caisse MYK Backend

Backend de caisse enregistreuse (POS) de restaurant, qui tourne **en local sur le portable de la caisse** (hors ligne d'abord).
Dépôt jumeau : `../Caisse_MYK_frontend` (application React qui appelle cette API).
La documentation, les commentaires, les messages d'erreur et les textes d'interface sont en **français**. On garde ça.

## Documents de référence (à lire avant tout changement important)
- `docs/00-ARCHITECTURE-GLOBALE.md` : modèle de domaine, règles métier, ADR, FNE (§8), infrastructure partagée avec le PMS (§4)
- `docs/01-BACKEND.md` : couches, schéma, services, transactions, agent d'impression, adaptateur FNE
- `docs/03-CONTRAT-API.md` : **contrat d'API v1 gelé** (erreurs, idempotence, endpoints)
- `docs/04-EXPLOITATION-BACKEND.md` et `docs/RUNBOOK-EXPLOITATION-WINDOWS.md` : exploitation, sauvegardes, migrations
- `docs/05-PLAN-IMPLEMENTATION.md` : lots de livraison L0 à L7 et Definition of Done

## Arborescence
```
apps/api/                 service FastAPI (Python ≥ 3.12, paquet `caisse`)
  src/caisse/
    main.py               création de l'app, gestionnaires d'exceptions, montage des routeurs
    core/                 socle transverse : config, database, security, deps, errors, pagination
    cli/                  CLI modulaire d'administration (commandes users, db, catalog, fne, workers)
    api/v1/               routeurs HTTP (router.py les regroupe)
    schemas/              modèles Pydantic v2 de requête et de réponse
    services/             cas d'usage et transactions (*_service.py)
    domain/               règles métier pures (money, fiscal, fne, *_rules.py, ports.py)
    repositories/         accès aux données SQLAlchemy
    models/               modèles ORM SQLAlchemy
    infrastructure/       adaptateurs : fne/ (fournisseurs manual|mock|api), printing/, outbox/
    seeds/                données de démo et catalogue initial
  alembic/versions/       migrations 001…007 (numérotées, séquentielles)
  tests/{unit,integration,e2e}
apps/print-agent/         agent imprimante USB ESC/POS et tiroir-caisse, tourne HORS de Docker (port 8090)
infra/                    socle Docker partagé (PostgreSQL commun avec le PMS, bases séparées)
scripts/                  PowerShell Windows : services NSSM, sauvegarde et restauration
```
Le `.venv` à la racine est un lien symbolique vers `apps/api/.venv`.

## Commandes (à lancer depuis `apps/api/`)
```bash
.venv/bin/pytest                          # tous les tests (SQLite en mémoire, voir tests/conftest.py)
.venv/bin/pytest tests/unit -q            # tests du domaine pur uniquement
.venv/bin/uvicorn caisse.main:app --reload --port 8001
.venv/bin/alembic upgrade head            # appliquer les migrations
.venv/bin/alembic revision -m "008_..."   # nouvelle migration, garder le préfixe NNN_
.venv/bin/python -m caisse.cli --help     # create-user, reset-pin, seed, import-catalog,
                                          # create-tables, set-vat-rate, fne-probe
```
La configuration vient de `apps/api/.env` (modèle : `.env.example`, chargé par `caisse/config.py`).
Documentation de l'API : `/docs` et `/openapi.json` sur le port 8001.

## Invariants non négociables
1. **Les montants sont des entiers en XOF** partout (base, schémas, domaine). Jamais de float ni de décimal pour un montant.
2. **Rien ne se modifie ni ne s'efface après encaissement.** Les corrections passent par des opérations inverses tracées
   (remboursements, annulations, avoirs).
3. **Une FNE (facture normalisée) par ticket.** Attente de 4 s au plus, puis repli sur une transmission différée via l'outbox.
4. **La base est partagée avec le PMS au niveau de l'instance uniquement.** Jamais de schéma commun, jamais de requête
   entre bases.
5. **Le contrat d'API v1 est gelé.** Toute modification d'une route ou d'un schéma doit rester rétrocompatible et être
   reportée dans `03-CONTRAT-API.md`. Régénérer ensuite `openapi.json` pour que le frontend lance `npm run api:types`.
6. Les endpoints qui modifient des données respectent les **clés d'idempotence** (`models/idempotency.py`) et reçoivent
   l'en-tête `X-Device-Id`.
7. `fne-probe` appelle la vraie API de la DGI et **consomme un sticker** à chaque appel. Ne jamais le lancer sans
   l'accord explicite de l'utilisateur.

## Conventions
- Couches : routeur → service → (règles du domaine + repository). La logique métier va dans `domain/` ou `services/`,
  jamais dans les routeurs.
- Erreurs métier : lever des sous-classes de `CaisseException` (`errors.py`). Les gestionnaires de `main.py` les
  convertissent au format d'erreur du contrat.
- Rôles : `CAISSIER`, `RESPONSABLE`, `ADMIN`. L'authentification se fait par PIN (argon2) et une paire de JWT
  access/refresh. Les dépendances sont dans `deps.py`.
- Tout changement de schéma demande une nouvelle migration Alembic. Ne pas modifier une migration déjà appliquée.
- Longueur de ligne Ruff : 100. mypy est en mode strict (`pyproject.toml`). Ruff et mypy ne sont pas encore installés
  dans le `.venv`.
- Les tests neutralisent l'impression matérielle (`PrintingService._send_raw_esc_pos`). Utilisateurs de test :
  caissier PIN `123456`, responsable `654321`.
- Fuseau horaire : `Africa/Abidjan`.
