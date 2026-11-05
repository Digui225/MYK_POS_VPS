# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Les instructions principales du projet (arborescence, commandes, invariants, conventions) sont dans AGENTS.md :

@AGENTS.md

Le journal des décisions et l'état de la production sont dans `MEMORY.md` (à lire avant tout changement d'architecture, à mettre à jour après chaque décision).

## Compléments et corrections à AGENTS.md

### Tests : PostgreSQL, pas SQLite
`tests/conftest.py` se connecte à **PostgreSQL** (`postgresql+psycopg://caisse_user:caisse_pass@127.0.0.1:5441/caisse_test`, surchargeable par `DATABASE_URL`). Avant de lancer les tests, démarrer la base avec `cd infra && docker compose up -d` et s'assurer que la base `caisse_test` existe.
- Chaque test recrée le schéma par `Base.metadata.create_all` puis `drop_all` (les migrations Alembic ne sont **pas** jouées en test) et insère des données fixes : utilisateurs `usr-caissier-01` (PIN `123456`), `usr-resp-01` (`654321`), `usr-admin-01` (`999999`), caisse `reg-01`, tables `tbl-01`/`tbl-02`.
- Fixtures automatiques : l'impression ESC/POS matérielle est neutralisée, le limiteur de débit et le blocage PIN sont remis à zéro.
- `APP_ENV=test` et `FNE_PROVIDER=mock` sont forcés ; en test le worker outbox ne démarre pas.
- Un seul test : `.venv/bin/pytest tests/integration/test_orders.py::nom_du_test -q` (ou `-k motif`).

### Migrations
Les migrations vont aujourd'hui jusqu'à `028_…` (la prochaine est `029_…`). Les migrations 019 à 025 sont des **corrections de données** de production (renommages, stock, achats) ; depuis la décision D6 (`MEMORY.md`), on ne corrige plus le stock par migration mais par inventaire. La 026 ajoute l'état des sorties cuisine, la 027 la table des régularisations d'écart de caisse, la 028 la réception des bons d'achat marché (quantités reçues, D9). Comme le schéma de test vient des modèles ORM, un modèle et sa migration doivent rester cohérents.

### Démarrage de l'application (`caisse/main.py`)
- Hors test, le lifespan exécute `Base.metadata.create_all` (contourne Alembic, point ouvert dans `MEMORY.md`) puis lance la boucle du worker outbox (`infrastructure/outbox/worker.py`, `ENABLE_OUTBOX_WORKER`, `OUTBOX_WORKER_INTERVAL_SECONDS`), qui renvoie les FNE différées.
- Middlewares : en-têtes de sécurité, limite de taille de requête, identifiant de requête, `TrustedHostMiddleware` (`ALLOWED_HOSTS`). Swagger servi en local depuis `static/swagger-ui`, désactivable (`ENABLE_DOCS`).
- Routes de santé : `/health` et `/health/ready` (base + agent d'impression en ligne).

### Idempotence
`caisse.core.idempotency` fournit `IdempotencyKey` (en-tête `Idempotency-Key` obligatoire, erreur `IDEMPOTENCY_KEY_REQUIRED`) et `OptionalIdempotencyKey`. La réponse est rejouée à partir d'un hash du corps ; même clé + corps différent → `IdempotencyConflictError`.

### Impression
L'agent (`apps/print-agent/`) tourne sur le poste Windows du restaurant et **tire** les travaux de l'API (mode PULL, jeton de terminal) ; l'API ne pousse jamais vers l'imprimante. Le tiroir-caisse s'ouvre avec le ticket.

### Déploiement : `main` = production, `aziz` = tests
`.github/workflows/deploy.yml` : un push sur **`aziz`** lance seulement les vérifications (Ruff, mypy, pytest), **sans déploiement**. Un push sur **`main`** (ou `prod-aziz`) est **déployé en production** (`148.113.149.10`) si les tests passent (CI avec service PostgreSQL 16). On travaille et on commite sur `aziz` ; la mise en production se fait en fusionnant `aziz` dans `main`, **uniquement avec l'accord explicite de l'utilisateur**. Seules les branches `main` et `aziz` existent. Côté serveur, le seul circuit est `deploy/vps/update.sh` (sauvegarde, migration, contrôle de santé, retour arrière), également appelé par `deploy/vps/deploy.sh`.

Scripts destructeurs à ne pas lancer sans accord : `deploy/vps/restore_real_data.sql` (`TRUNCATE` des ventes) et `scripts/reset_production_data.sql`.
