# Caisse MYK — Backend (API & Print Agent)

Backend de caisse enregistreuse et facturation normalisée (POS) pour restaurant, conçu pour fonctionner **en local sur le poste de caisse** avec une architecture résiliente aux coupures réseau (**offline-first**).

- **Dépôt jumeau (Frontend PWA React)** : `../Caisse_MYK_frontend`
- **Port API par défaut** : `http://localhost:8001` (Documentation interactive Swagger : `/docs` et `/openapi.json`)
- **Port Agent d'impression** : `http://localhost:8090`

---

## 🏛️ Structure du Monorepo

```text
Caisse_MYK_backend/
├── apps/
│   ├── api/                  # Service principal FastAPI (Python ≥ 3.12, paquet caisse)
│   │   ├── src/caisse/       # Code source de l'application (couches API, domain, services...)
│   │   ├── alembic/          # Migrations de schéma de base de données
│   │   ├── tests/            # Tests unitaires, d'intégration et E2E (165 tests)
│   │   └── pyproject.toml    # Dépendances et configuration des outils (Ruff, Mypy)
│   └── print-agent/          # Service Python dédié à l'impression ESC/POS & tiroir USB (hors Docker)
├── infra/                    # Socle Docker Compose (PostgreSQL commun avec le PMS, bases séparées)
├── scripts/                  # Scripts d'automatisation PowerShell (NSSM, sauvegarde, restauration)
├── docs/                     # Spécifications métier, architecture et guides d'exploitation
└── README.md                 # Ce guide de démarrage
```

---

## ⚡ Invariants & Règles d'Or

1. **Montants en entiers XOF** : Aucun float ni décimal pour les montants financiers (base de données, schémas Pydantic, domaine). L'unité minimale est le franc CFA (XOF).
2. **Immuabilité après encaissement** : Rien ne se modifie ni ne se supprime après paiement. Les corrections se font uniquement par opérations inverses tracées (remboursements, avoirs).
3. **Facture Normalisée Électronique (FNE)** : Une FNE par ticket. Appel DGI borné à 4 secondes, puis repli automatique en tâche de fond via la table d'Outbox.
4. **Contrat d'API v1 gelé** : Tout endpoint doit respecter strictement le format documenté dans [`docs/03-CONTRAT-API.md`](./docs/03-CONTRAT-API.md).
5. **Architecture en couches stricte** :
   `Routeur HTTP → Service Applicatif → (Règles Domaine pures + Repository SQLAlchemy)`
   *Aucune logique métier ne doit résider dans les routeurs FastAPI.*

---

## 🚀 Démarrage Rapide (Quick Start)

### 1. Prérequis
- Python ≥ 3.12 (avec `uv` ou `venv`)
- Docker & Docker Compose (pour PostgreSQL)

### 2. Démarrer la base de données
Depuis le dossier racine :
```bash
cd infra
docker compose up -d
```
*La base de données PostgreSQL de caisse est accessible sur `localhost:5441` (base `caisse_db`, utilisateur `caisse_user`).*

### 3. Installer l'environnement API
```bash
cd ../apps/api

# Création du venv et installation (avec uv ou pip)
uv sync --dev
# ou : python3.12 -m venv .venv && source .venv/bin/activate && pip install -e ".[dev]"
```

### 4. Appliquer les migrations & charger les données de démo
```bash
# Appliquer les migrations Alembic
.venv/bin/alembic upgrade head

# Initialiser le catalogue et les utilisateurs de démo
.venv/bin/python -m caisse.cli seed
```

### 5. Lancer le serveur de développement
```bash
.venv/bin/uvicorn caisse.main:app --reload --port 8001
```

Accédez à :
- **Swagger UI** : [http://localhost:8001/docs](http://localhost:8001/docs)
- **OpenAPI Schema** : [http://localhost:8001/openapi.json](http://localhost:8001/openapi.json)
- **Health Check** : [http://localhost:8001/health](http://localhost:8001/health)

---

## 🧪 Lancer les Tests

Les tests s'exécutent sur une base SQLite isolée en mémoire :

```bash
cd apps/api

# Lancer la totalité de la suite de tests (165 tests)
.venv/bin/pytest

# Lancer uniquement les règles métier pures (domaine)
.venv/bin/pytest tests/unit/domain -q

# Lancer les tests d'intégration API
.venv/bin/pytest tests/integration -q
```

---

## 👤 Comptes de Test par Défaut

| Rôle | Nom | Code PIN |
|---|---|---|
| **Caissier** | Caissier 1 | `123456` |
| **Responsable** | Responsable Salle | `654321` |
| **Économe** | Économe Marché | `112233` |
| **Admin** | Administrateur Système | `999999` |

---

## 🛠️ Commandes CLI d'Administration

Le module CLI [`caisse.cli`](./apps/api/src/caisse/cli.py) fournit des commandes utilitaires pour l'administration :

```bash
cd apps/api

# Créer un utilisateur
.venv/bin/python -m caisse.cli create-user --name "Kouamé" --role CAISSIER --pin 123456

# Réinitialiser un code PIN
.venv/bin/python -m caisse.cli reset-pin --user-id "<UUID>" --new-pin 654321

# Modifier le taux de TVA (ex: 18%)
.venv/bin/python -m caisse.cli set-vat-rate 18

# Réinitialiser les transactions de test (conserve catalogue et utilisateurs)
.venv/bin/python -m caisse.cli reset-transactions
```

---

## 📖 Documentation Détaillée

Consultez le dossier [`docs/`](./docs/README.md) pour les spécifications exhaustives :
- [`00-ARCHITECTURE-GLOBALE.md`](./docs/00-ARCHITECTURE-GLOBALE.md) : Modèle DDD, règles métier et FNE
- [`01-BACKEND.md`](./docs/01-BACKEND.md) : Architecture technique détaillée du backend
- [`03-CONTRAT-API.md`](./docs/03-CONTRAT-API.md) : Spécification du contrat d'API REST v1
- [`04-EXPLOITATION-BACKEND.md`](./docs/04-EXPLOITATION-BACKEND.md) : Sauvegardes, migrations et exploitation
- [`RUNBOOK-EXPLOITATION-WINDOWS.md`](./docs/RUNBOOK-EXPLOITATION-WINDOWS.md) : Déploiement Windows (NSSM)
