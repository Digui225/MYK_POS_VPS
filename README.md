# caisse-backend — API FastAPI

Documentation de référence : `../projet_caisse_MYK/` (01-BACKEND, 03-CONTRAT-API, 04-EXPLOITATION).

## Démarrage

Prérequis : le socle `../infra` tourne (PostgreSQL partagé, réseau `infra_shared`).

```bash
cp .env.example .env && nano .env        # DATABASE_URL (mot de passe caisse du socle), JWT_SECRET
docker compose up -d --build
docker compose exec api alembic upgrade head
docker compose exec api python -m caisse.cli bootstrap        # caisse n° 1 + paramètres
docker compose exec api python -m caisse.cli create-user      # premier ADMIN (PIN 6 chiffres)
docker compose exec api python -m caisse.cli seed --demo      # dév. uniquement : menu + 15 tables
# ou le menu réel et son stock (CSV tirés des Excel, src/caisse/seeds/data/) :
docker compose exec api python -m caisse.cli import-catalog
docker compose exec api python -m caisse.cli import-stock --stock-initial
docker compose exec api python -m caisse.cli create-tables --count 15
curl -s localhost:8001/health/ready
```

OpenAPI : http://localhost:8001/docs · http://localhost:8001/openapi.json

Front : [`docs/GUIDE-FRONT.md`](docs/GUIDE-FRONT.md) (branchement, conventions, routes par écran) ; détail des routes : [`docs/ENDPOINTS-TESTABLES.md`](docs/ENDPOINTS-TESTABLES.md).

Après un redémarrage, ou en cas de doute : `./scripts/demarrer-caisse.sh` vérifie Docker, le réseau,
la base, l'API, les migrations et la santé, démarre ce qui manque et explique chaque résultat
(`--check` pour vérifier sans rien démarrer).

Recette sur le VPS partagé (base PostgreSQL propre, sans le socle `infra/`) : fichiers dans
[`deploy/vps/`](deploy/vps/), procédure dans `../projet_caisse_MYK/05-DEPLOIEMENT-VPS.md`.

Développement (rechargement à chaud) :
`docker compose -f docker-compose.yml -f docker-compose.dev.yml up --build`

## Tests et qualité

```bash
docker build --target dev -t caisse-api:dev .
docker network create caisse_test
docker run -d --rm --name caisse-test-db --network caisse_test \
  -e POSTGRES_USER=caisse -e POSTGRES_PASSWORD=caisse -e POSTGRES_DB=caisse postgres:16-alpine
docker run --rm --network caisse_test -v $PWD:/app \
  -e TEST_DATABASE_URL=postgresql+psycopg://caisse:caisse@caisse-test-db:5432/caisse \
  caisse-api:dev sh -c "pytest && ruff check src tests && mypy src"
docker rm -f caisse-test-db && docker network rm caisse_test
```

Sans `TEST_DATABASE_URL`, les tests démarrent eux-mêmes un PostgreSQL via testcontainers
(nécessite l'accès au démon Docker).
Les tests d'intégration rejouent `alembic downgrade base` puis `upgrade head` :
toute migration doit rester réversible.

## Arborescence

```
src/caisse/
  domain/          règles pures, zéro I/O (money, enums, ids, ports)
  models/          SQLAlchemy — schéma complet de 01-BACKEND §4
  repositories/    accès données
  services/        cas d'usage + transactions (auth, users, audit)
  api/             routers FastAPI (/health, /api/v1/…)
  infrastructure/  client FNE (API DGI, simulateur)
  seeds/ cli.py    amorçage et dépannage
alembic/           migrations
print-agent/       agent du terminal : vient chercher les tickets sur l'API (imprimante USB + tiroir)
```

## État d'avancement

| Lot | Fait | Reste |
|---|---|---|
| L0 | Squelette, schéma + migration, problem+json, `domain/money`, OpenAPI | Endpoints mockés du reste du contrat, CI |
| L1 | PIN Argon2, JWT + refresh (rotation), RBAC, override 60 s usage unique, blocage progressif par poste, users, audit, sessions de caisse (ouverture/clôture, X/Z, mouvements, idempotence générique) | — |
| L2 | Catalogue (catégories, produits, prix historisé avec motif), tables (CRUD, partage de table : plusieurs commandes par table), seeds, import CSV | — |
| L3 | `GET /tables/board` (requête agrégée), commandes (table / à emporter), lignes (ajout, modification, retrait avec motif), annulation sous override, article libre, `POST /orders/{id}/reprint` | — |
| L4 | Paiements (idempotents, partiels/mixtes, rendu monnaie, annulation tracée sous override), `GET /payment-methods` ; agent d'impression (USB + tiroir, mode dummy) ; ticket imprimé et tiroir ouvert à l'encaissement et à la clôture (Z), `/printing/*` (état, file, rejeu, ouverture manuelle, test) | Remboursement d'une commande soldée (reporté) |
| L6 | FNE à la demande (B2C/B2B, idempotente, résultats incertains, renvoi manuel, avoirs), clients entreprise, récapitulatif fiscal | Worker de renvoi automatique, export du récapitulatif figé au Z |
| L5 (stock) | Articles de stock distincts des produits, fiches techniques, entrées (CMP), pertes, inventaires (stock de départ `OPENING`), sortie automatique à l'encaissement et remise en stock à l'annulation d'un paiement, tableaux ventes et stock (ADMIN), import du menu et du stock tirés des Excel (`import-catalog`, `import-stock`) | Écrans front, rapport `dashboard`, alertes de stock dans le Z |
| Admin | `/settings`, `/cash-registers`, tableau de bord du jour, duplicata du Z, export CSV des FNE ; limite de débit par IP, en-têtes de sécurité, Swagger coupé en production (repris de la branche `aziz`, sous les routes du contrat) | — |
| En ligne | Impression tirée par l'agent du terminal (file `print_jobs`, jeton de terminal révocable, tiroir et test en file) | Agent Windows, HTTPS et déploiement de prod, nettoyage du mode local |
| Reste | — | Rapport `audit`, worker (renvoi auto FNE), temps réel (WebSocket), backup |
