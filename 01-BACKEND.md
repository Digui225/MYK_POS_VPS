# Backend — FastAPI

> Destinataire : **développeur backend**.
> Prérequis : avoir lu `00-ARCHITECTURE-GLOBALE.md`.
> Installation, démarrage, sauvegardes, dépannage : **`04-EXPLOITATION-BACKEND.md`**.
> Le backend est **propriétaire des règles métier**. Le frontend ne fait que les refléter.
>
> **v1.1** — intègre l'agent d'impression USB (ADR-13), l'ouverture du tiroir à l'encaissement, la FNE par ticket (ADR-15) et la mutualisation PostgreSQL avec le PMS (ADR-14).

---

## 1. Stack

| Rôle | Choix | Version | Remarque |
|---|---|---|---|
| Langage | Python | 3.12 | |
| Framework | FastAPI | ≥ 0.115 | OpenAPI 3.1 natif |
| ASGI | Uvicorn (workers Gunicorn en prod) | | 2 workers suffisent |
| ORM | SQLAlchemy 2.x (style `Mapped[]`) | | Sessions synchrones assumées (voir §7) |
| Migrations | Alembic | | Chaque migration réversible |
| Validation | Pydantic v2 | | `model_config = ConfigDict(from_attributes=True)` |
| Base | PostgreSQL | 16 | Instance **mutualisée avec le PMS**, base `caisse` dédiée (ADR-02, ADR-14) |
| Cache / file | Redis | 7 | Optionnel au MVP (outbox en DB suffit) |
| Auth | `python-jose` + `argon2-cffi` | | JWT + hachage PIN |
| Impression | `python-escpos` / `win32print` | | Dans l'**agent** (sur l'hôte Windows), pas dans l'API — ADR-13 |
| Agent d'impression | FastAPI minimal + `win32print` (Windows Spooler) | | Service Windows (NSSM) ou script démarrage, port 8090, pilote l'imprimante USB et le tiroir |
| Tâches de fond | Worker `asyncio` intégré + APScheduler | | Pas de Celery : 1 machine, 2 devs |
| Tests | pytest, pytest-asyncio, httpx, factory-boy, testcontainers | | |
| Qualité | ruff, mypy (strict sur `domain/` et `services/`), pre-commit | | |
| Packaging | uv (ou poetry) + Docker multi-stage | | |

---

## 2. Principes d'architecture

**Monolithe modulaire en couches**, dépendances strictement descendantes :

```
api/ (routers)        ← HTTP, validation d'entrée, codes de statut, RBAC
   ↓
services/             ← cas d'usage, orchestration, transactions
   ↓
domain/               ← règles métier pures, calculs, machines à états (0 dépendance I/O)
   ↓
repositories/         ← accès données SQLAlchemy
   ↓
models/               ← tables
```

Règles :

- **`domain/` ne connaît ni FastAPI, ni SQLAlchemy.** C'est là que vivent le calcul de totaux, la ventilation TVA, les transitions d'état, la validation des paiements. Testable en millisecondes, sans base.
- Un **router n'appelle jamais un repository** directement.
- Une **transaction = un cas d'usage**. Ouverte et fermée dans le service, jamais dans le router.
- Les **intégrations externes** (imprimante, DGI) sont derrière un `Protocol` dans `domain/ports.py`, implémenté dans `infrastructure/`. Elles sont toujours remplaçables par un mock.
- **Pas d'appel réseau sortant dans le chemin critique d'une vente.** Tout ce qui sort passe par l'outbox.

---

## 3. Arborescence

```
apps/api/
├── alembic/
│   ├── versions/
│   └── env.py
├── src/caisse/
│   ├── main.py                     # création de l'app, middlewares, lifespan
│   ├── config.py                   # Settings (pydantic-settings)
│   ├── database.py                 # engine, SessionLocal, get_db
│   ├── deps.py                     # dépendances communes (current_user, require_role, idempotency)
│   ├── errors.py                   # exceptions métier → problem+json
│   │
│   ├── domain/                     # ❗ zéro I/O
│   │   ├── money.py                # type Money (int XOF), arrondis, ventilation TVA
│   │   ├── order_rules.py          # transitions, totaux, ajout/retrait de ligne
│   │   ├── payment_rules.py        # reste dû, mixte, rendu monnaie
│   │   ├── session_rules.py        # ouverture/clôture, écart de caisse
│   │   ├── stock_rules.py          # mouvements, seuils
│   │   ├── fiscal.py               # construction du payload fiscal
│   │   ├── enums.py                # OrderStatus, PaymentMethod, MovementType…
│   │   └── ports.py                # Printer, FneProvider, Clock, IdGenerator
│   │
│   ├── models/                     # SQLAlchemy
│   │   ├── base.py                 # Base, TimestampMixin, UUID pk
│   │   ├── user.py  catalog.py  table.py  order.py  payment.py
│   │   ├── cash_session.py  stock.py  customer.py  fne.py
│   │   └── audit.py  outbox.py  settings.py
│   │
│   ├── schemas/                    # Pydantic (entrée/sortie API)
│   │   └── auth.py  catalog.py  orders.py  payments.py  sessions.py  reports.py  fne.py
│   │
│   ├── repositories/
│   │   └── base.py  orders.py  catalog.py  sessions.py  stock.py  …
│   │
│   ├── services/
│   │   ├── auth_service.py
│   │   ├── catalog_service.py
│   │   ├── order_service.py
│   │   ├── payment_service.py      # ⚠️ cœur transactionnel
│   │   ├── cash_session_service.py
│   │   ├── stock_service.py
│   │   ├── printing_service.py
│   │   ├── fne_service.py
│   │   ├── reporting_service.py
│   │   └── audit_service.py
│   │
│   ├── infrastructure/
│   │   ├── printing/agent_client.py  templates/ticket.py  null_printer.py
│   │   ├── fne/manual_provider.py  api_provider.py  mock_provider.py
│   │   └── outbox/worker.py  dispatcher.py
│   │
│   ├── api/v1/
│   │   ├── router.py               # agrégation
│   │   ├── auth.py  users.py  catalog.py  tables.py  orders.py
│   │   ├── payments.py  sessions.py  stock.py  reports.py
│   │   ├── customers.py  fne.py  printing.py  settings.py
│   │
│   └── seeds/                      # menu réel du restaurant, tables, utilisateurs de test
│
├── tests/
│   ├── unit/domain/                # rapide, sans base
│   ├── integration/                # avec Postgres (testcontainers)
│   └── e2e/test_service_complet.py # journée type : ouverture → ventes → clôture
├── Dockerfile
└── pyproject.toml

apps/print-agent/                    # ❗ hors conteneur — Service Windows (NSSM) / Script hôte
├── agent/__main__.py                # FastAPI minimal : /status /print /open-drawer /test-print
├── agent/spooler_driver.py          # Pilote Spooler Windows (win32print / ESC/POS raw bytes)
├── requirements.txt                 # fastapi, uvicorn, pydantic, pywin32
└── .env                             # PRINTER_NAME, WIDTH, DRAWER_PULSE_HEX
```

---

## 4. Modèle de données

Conventions : `id` = UUIDv7 (ordonnable, pratique pour les index), timestamps `created_at`/`updated_at` en `timestamptz` UTC, montants en `INTEGER` (XOF), suppression logique interdite sur les entités fiscales.

### 4.1 Identité et caisse

```sql
users(
  id, full_name, pin_hash, role ENUM('CAISSIER','RESPONSABLE','ADMIN'),
  is_active, last_login_at, failed_attempts, locked_until
)

cash_registers(id, name, printer_config JSONB, is_active)

cash_sessions(
  id, cash_register_id, opened_by_user_id, closed_by_user_id,
  business_date DATE,                    -- journée comptable
  status ENUM('OPEN','CLOSING','CLOSED'),
  opening_float_xof INT,
  opened_at, closed_at,
  z_number INT,                          -- séquence par caisse, attribuée à la clôture
  counted_cash_xof INT, expected_cash_xof INT, variance_xof INT,
  closing_breakdown JSONB,               -- comptage par dénomination
  totals_snapshot JSONB                  -- figé à la clôture
)
-- index unique partiel : un seul OPEN par caisse
CREATE UNIQUE INDEX ON cash_sessions(cash_register_id) WHERE status <> 'CLOSED';

cash_movements(id, cash_session_id, type ENUM('IN','OUT'), amount_xof, reason, user_id, created_at)
```

### 4.2 Catalogue

```sql
categories(id, name, kind ENUM('FOOD','DRINK','OTHER'), sort_order, color, is_active,
           fiscal_group)   -- regroupement pour le récap FNE (poissons, viandes, jus…)

products(
  id, category_id, name, short_name,       -- short_name = libellé ticket (≤ 20 car.)
  price_xof INT, vat_rate NUMERIC(4,2) DEFAULT 18.00,
  track_stock BOOL, is_custom BOOL, is_active BOOL,
  sort_order, color, sku
)

product_price_history(id, product_id, old_price_xof, new_price_xof, changed_by, changed_at, reason)
```

> `is_custom = true` → produit créé à la volée pour une commande (CR §3). Non listé dans le menu, conservé pour la traçabilité et l'historique.

### 4.3 Tables et commandes

```sql
restaurant_tables(id, label, zone, seats, sort_order, is_active)

orders(
  id, order_number TEXT,                -- séquence lisible par journée : 2026-09-24-0042
  cash_session_id, table_id NULL,       -- NULL = vente à emporter / comptoir
  status ENUM('OPEN','PARTIALLY_PAID','PAID','CANCELLED','REFUNDED'),
  opened_by_user_id, closed_by_user_id,
  guests_count INT,
  total_ttc_xof INT, total_ht_xof INT, total_vat_xof INT,
  paid_xof INT, due_xof INT,            -- dénormalisés, recalculés dans la transaction
  cancelled_reason, cancelled_by, cancelled_at,
  opened_at, paid_at
)
CREATE UNIQUE INDEX ON orders(table_id) WHERE status IN ('OPEN','PARTIALLY_PAID');

order_items(
  id, order_id, product_id,
  product_name_snapshot, category_snapshot,   -- figés
  unit_price_xof, quantity, vat_rate,
  line_total_xof,
  note,                                        -- « sans piment », « bien cuit »
  added_by_user_id, added_at,
  removed_at, removed_by_user_id, removal_reason   -- retrait tracé, jamais de DELETE
)

payments(
  id, order_id, cash_session_id,
  method ENUM('CASH','MOBILE_MONEY','CARD','BANK_TRANSFER','CREDIT','OTHER'),
  provider,                                -- ORANGE / MTN / MOOV / WAVE …
  amount_xof, tendered_xof, change_xof,
  reference,                               -- n° transaction Mobile Money
  status ENUM('CAPTURED','VOIDED'),
  idempotency_key UNIQUE,
  created_by_user_id, created_at,
  voided_at, voided_by, void_reason
)
```

### 4.4 Stock

```sql
stock_items(id, product_id UNIQUE, quantity NUMERIC(12,3), unit, alert_threshold, updated_at)

stock_movements(
  id, product_id, type ENUM('PURCHASE_IN','SALE_OUT','RETURN_IN','LOSS_OUT','ADJUSTMENT','INVENTORY_COUNT'),
  quantity NUMERIC(12,3),      -- signée
  quantity_after NUMERIC(12,3),
  unit_cost_xof NULL, reference_order_id NULL, reason, user_id, created_at
)
```

### 4.5 Fiscal, impression, technique

```sql
customers(id, company_name, ncc, tax_regime, address, phone, email, created_at)

fne_documents(
  id, type ENUM('FNE','RNE','DAILY_SUMMARY'),
  order_id NULL, cash_session_id NULL, customer_id NULL,
  status ENUM('DRAFT','QUEUED','SUBMITTING','CERTIFIED','FAILED','MANUAL'),
  payload JSONB,                 -- snapshot figé, jamais recalculé
  external_number, qr_payload, certified_at,
  attempts INT, last_error, next_retry_at
)

print_jobs(
  id, type ENUM('RECEIPT','X_REPORT','Z_REPORT','FNE','ORDER_TICKET'),
  order_id NULL, session_id NULL, payload JSONB, rendered TEXT,
  status ENUM('QUEUED','PRINTING','DONE','FAILED'),
  attempts, last_error, is_reprint BOOL, requested_by, created_at
)

outbox_events(id, aggregate_type, aggregate_id, event_type, payload JSONB,
              status, attempts, available_at, created_at, processed_at)

idempotency_records(key PRIMARY KEY, request_path, request_hash, response_status,
                    response_body JSONB, created_at)

audit_logs(id, user_id, acting_as_user_id NULL, action, entity, entity_id,
           before JSONB, after JSONB, reason, ip, device_id, created_at)

settings(key PRIMARY KEY, value JSONB, updated_by, updated_at)
```

`settings` porte : mentions légales du ticket, largeur d'impression, taux de TVA par défaut, arrondi, mode FNE, seuils d'alerte globaux, durée de verrouillage écran.

---

## 5. Modules et cas d'usage

### 5.1 `auth_service`

- `login(pin, device_id)` → vérifie Argon2, incrémente `failed_attempts`, applique la temporisation, émet les JWT, audite.
- `authorize_override(pin, required_role, action)` → élévation ponctuelle (annulation, retrait de ligne). Retourne un jeton d'autorisation à usage unique, valable 60 s, consommé par l'opération concernée.
- Dépendances FastAPI : `current_user`, `require_role(*roles)`, `require_open_session`.

### 5.2 `cash_session_service`

```python
def open_session(user, register_id, opening_float_xof, business_date=None):
    # 0. vérifier le rôle (réservé CAISSIER — séparation stricte des rôles)
    # 1. refuser si une session OPEN existe sur cette caisse
    # 2. business_date par défaut = date du jour ; si une session CLOSED existe déjà
    #    pour cette date sur cette caisse → exiger une confirmation explicite (CR §2.4)
    # 3. créer la session, tracer le fonds de caisse, auditer
```

- `x_report(session)` → agrégats en lecture seule, sans effet de bord (session en cours).
- `close_session(session, counted_breakdown, user)` :
  1. refuser s'il reste des commandes `OPEN`/`PARTIALLY_PAID` → 409 avec la **liste des tables bloquantes** ;
  2. calculer les espèces théoriques = fonds + encaissements espèces + entrées − sorties − remboursements espèces ;
  3. écart = compté − théorique ;
  4. attribuer le `z_number` (séquence par caisse, `SELECT ... FOR UPDATE` sur un compteur) ;
  5. figer `totals_snapshot` ;
  6. créer les `print_jobs` du Z et l'événement `DAILY_SUMMARY` pour la FNE ;
  7. auditer.

### 5.3 `order_service`

- `create_order(session, table_id, guests)` — réservé `CAISSIER`, 409 si la table porte déjà une commande active.
- `add_item(order, product_id, qty, note)` — copie le prix et le libellé, recalcule les totaux.
- `update_item_quantity` / `remove_item(reason, override_token?)` — jamais de `DELETE`. Retrait post-validation soumis à élévation responsable.
- `add_custom_item(name, price, category_id)` — crée un `product(is_custom=True)` puis la ligne (réservé `CAISSIER`).
- `cancel_order(reason, override)` — exige validation responsable/admin (`X-Override-Token`), annule les paiements éventuels (tracés), libère la table.
- `get_table_board()` — vue optimisée pour l'écran principal caisse et la supervision Dashboard : par table, statut, total en cours, durée d'occupation, nombre de couverts. **Un seul appel, requête agrégée** (pas de N+1 : c'est l'écran le plus sollicité du système).

### 5.4 `payment_service` — le cœur transactionnel

```python
def register_payment(order_id, method, amount_xof, tendered_xof, reference,
                     idempotency_key, user) -> PaymentResult:
    with unit_of_work() as uow:                       # SERIALIZABLE
        existing = uow.payments.by_idempotency_key(idempotency_key)
        if existing:
            return PaymentResult.replay(existing)     # ← rejeu, pas de doublon

        order = uow.orders.get_for_update(order_id)   # SELECT ... FOR UPDATE
        rules.assert_payable(order)
        rules.assert_amount_valid(order, method, amount_xof, tendered_xof)

        payment = uow.payments.add(...)
        order.paid_xof += amount_xof
        order.due_xof = order.total_ttc_xof - order.paid_xof

        if order.due_xof == 0:
            order.status = PAID
            order.paid_at = now()
            stock.apply_sale_out(order, uow)          # décrément du stock
            printing.enqueue_receipt(order, uow)      # ticket
            fiscal.certify_on_payment(order, uow)     # FNE : attente bornée (4s) ou repli outbox (ADR-15)
            tables.release(order.table_id, uow)
        else:
            order.status = PARTIALLY_PAID

        audit.log(...)
    return PaymentResult.created(payment, change=rules.change(tendered_xof, amount_xof))
```

Points non négociables :
- **Un seul commit** pour paiement + stock + file d'impression + document fiscal. Pas de vente à moitié enregistrée.
- L'impression est mise en file ; la certification FNE tente une soumission synchrone bornée (≤ 4 s) avant repli automatique en outbox.
- Idempotence garantie par un index unique en base, pas par un `if` applicatif.
- En cas de conflit de sérialisation Postgres (`40001`), **retry automatique** (3 tentatives, jitter).

### 5.5 `stock_service`

- `apply_sale_out(order)` — un mouvement par ligne de produit suivi, `reference_order_id` renseigné.
- `receive_stock(product_id, qty, unit_cost)` — entrée manuelle (responsable).
- `inventory_count(product_id, counted_qty)` — crée un mouvement d'ajustement + conserve l'écart.
- `low_stock_alerts()` — pour le tableau de bord et le rapport Z.
- Stock négatif autorisé, mais renvoie un `warning` dans la réponse (le front affiche un bandeau, ne bloque pas).

### 5.6 `printing_service` et agent d'impression

L'imprimante est en **USB sous Windows** : le processus qui la pilote doit tourner sur la machine hôte où le câble est branché. Il est donc sorti du conteneur Docker et devient un **agent Windows autonome** (ADR-13).

```
API (conteneur Docker)  ──HTTP──▶  print-agent (Service Windows / NSSM, port 8090)  ──win32print──▶  imprimante ──DK──▶ tiroir
```

**Côté API — `printing_service`**

- `enqueue(job_type, payload, open_drawer=False)` → `print_jobs` en `QUEUED`.
- Worker : rendu du gabarit → `POST http://host.docker.internal:8090/print` → `DONE` / `FAILED` (3 tentatives, backoff, puis alerte).
- `reprint(job_id, user)` → **nouveau** job avec `is_reprint=True`, ticket marqué « DUPLICATA », audité, **sans ouverture du tiroir**.
- `printer_status()` → interroge `GET /status` de l'agent, met en cache 5 s, expose à l'UI.
- **Mode dégradé obligatoire** : agent ou imprimante indisponible → la vente aboutit quand même, les tickets restent en file et sont rejoués au retour ; le front propose l'affichage du ticket à l'écran.

**Côté agent — contrat minimal**

| Méthode | Chemin | Rôle |
|---|---|---|
| `GET` | `/status` | `{ "online": true, "paper": "ok", "model": "...", "width": 48 }` |
| `POST` | `/print` | `{ "content": "<texte rendu>", "qr": "<payload ou null>", "open_drawer": true, "cut": true }` |
| `POST` | `/open-drawer` | Impulsion seule (bouton « ouvrir le tiroir » du responsable, tracé) |
| `POST` | `/test-print` | Ticket de test (administration) |

L'agent ne connaît **aucune règle métier** : il reçoit du texte déjà mis en forme, le QR éventuel et deux drapeaux. Toute la logique de gabarit reste côté API, ce qui permet de la tester sans matériel.

**Ouverture du tiroir & Envoi Spooler Windows (`win32print`)**

Exigence client : *au clic sur « Payer », le tiroir s'ouvre et le reçu sort en même temps* — comportement de l'ancienne caisse. Le tiroir est branché sur le port **DK / RJ11 de l'imprimante**, pas sur l'ordinateur : l'ouverture est une commande ESC/POS envoyée **dans le même flux d'octets bruts** que le ticket via l'API d'impression Windows.

```python
# agent/spooler_driver.py (Windows)
import win32print

def print_job_raw(printer_name: str, raw_data: bytes):
    hPrinter = win32print.OpenPrinter(printer_name)
    try:
        hJob = win32print.StartDocPrinter(hPrinter, 1, ("Ticket Caisse", None, "RAW"))
        win32print.StartPagePrinter(hPrinter)
        win32print.WritePrinter(hPrinter, raw_data)
        win32print.EndPagePrinter(hPrinter)
        win32print.EndDocPrinter(hPrinter)
    finally:
        win32print.ClosePrinter(hPrinter)
```

Règles : ouverture uniquement sur un encaissement réel ou sur action explicite d'un responsable (tracée). Jamais sur une ré-impression, jamais sur un rapport X.

**Sécurité** : l'agent écoute sur `127.0.0.1` (ou sur le LAN avec un jeton partagé si l'API déménage sur une autre machine). Il n'est jamais exposé à l'extérieur.

Gabarit de ticket (rendu serveur, paramétrable via `settings`) :

```
        [NOM DU RESTAURANT]
      [Adresse] · [Téléphone]
   NCC: xxxxxxx · RCCM: xxxxxxx
----------------------------------
Ticket   : 2026-09-24-0042
Table    : 12        Couverts: 4
Caissier : Awa
Date     : 24/09/2026 20:14
----------------------------------
2 x Poisson braisé      7 000
1 x Attiéké             1 000
3 x Sucrerie 33cl       1 500
----------------------------------
TOTAL TTC               9 500 F
  dont TVA 18%          1 449 F
----------------------------------
Espèces                 5 000
Mobile Money (Wave)     4 500
Rendu                       0
----------------------------------
FNE n° 2026-CI-00048127
      [QR code sticker DGI]
----------------------------------
      Merci de votre visite
```

Deux variantes du bloc fiscal, selon l'issue de la transmission (§5.7) :

```
# certifié à temps                  # transmission différée
FNE n° 2026-CI-00048127             Facture normalisée en cours
   [QR code sticker DGI]            de transmission
                                    Réf. interne : 2026-09-24-0042
```

Pour une **vente à emporter**, la ligne `Table` est remplacée par `Comptoir : n° 7`.

### 5.7 `fne_service`

```python
class FneProvider(Protocol):
    def submit(self, document: FiscalDocument) -> FneResult: ...
    def status(self, external_id: str) -> FneStatus: ...
```

| Implémentation | Usage |
|---|---|
| `ManualFneProvider` | **MVP** : marque le document `MANUAL`, produit un récapitulatif imprimable + export (CSV/JSON) exploitable dans l'application FNE déjà utilisée par le restaurant |
| `ApiFneProvider` | Phase 2 : appel à la plateforme DGI, authentification par clé, gestion de l'accusé (numéro + QR), conservation de la réponse brute |
| `MockFneProvider` | Tests et développement frontend |

Le choix se fait par configuration (`FNE_PROVIDER=manual|api|mock`), sans changement de code appelant.

**Une FNE par ticket (ADR-15).** Chaque encaissement soldé crée un `fne_document` et déclenche une tentative de certification **bornée dans le temps** :

```python
def certify_on_payment(order, uow) -> FneDocument:
    doc = uow.fne.create(order=order, payload=fiscal.snapshot(order), status=PENDING)
    uow.commit()                       # le document existe avant tout appel réseau

    try:
        result = provider.submit(doc, timeout=settings.FNE_SYNC_TIMEOUT)   # 4 s
        doc.mark_certified(result.number, result.qr_payload)
    except (Timeout, NetworkError):
        doc.mark_queued(next_retry_at=now() + 60)      # rejeu par le worker
    except RejectedByDgi as e:
        doc.mark_failed(e.detail)                       # donnée invalide → correction humaine
    return doc
```

Règles :

- **Le document est créé et commité avant l'appel réseau.** Une panne au milieu de la soumission ne peut pas faire disparaître une obligation fiscale.
- `FNE_SYNC_TIMEOUT` (4 s par défaut) est la seule attente que subit le client. Au-delà, le ticket sort avec la mention de transmission différée et le worker prend le relais (backoff 1 min, 5 min, 15 min, 1 h, plafonné).
- Le `payload` est un **snapshot figé** : une modification ultérieure du catalogue ne peut pas altérer une déclaration déjà émise.
- La certification tardive rend disponible un **duplicata fiscal** imprimable depuis l'historique.
- Un compteur `documents_pending` est exposé en permanence (barre d'état du front, rapport Z, `/health/ready`).

**Récapitulatif journalier** : à la clôture, agrégation des quantités et montants vendus **par `fiscal_group`** (poissons, viandes, jus, eau, plats, autres), généré comme un `fne_document` de type `DAILY_SUMMARY`. Avec la FNE par ticket il n'est plus le vecteur de déclaration, mais il reste produit pour le **contrôle interne et le rapprochement** entre ce qui a été vendu et ce qui a été transmis.

> ⚠️ Le mode dégradé (ticket remis sans sticker, régularisation ensuite) doit être **validé auprès du comptable et de la DGI** avant le lot L6 — voir §8.3 du document d'architecture. Tant que ce n'est pas tranché, `FNE_PROVIDER=manual`.

### 5.8 `reporting_service`

Requêtes agrégées en lecture seule, jamais de calcul en Python sur des listes complètes :
- CA par journée comptable / par session / par caissier,
- ventilation par moyen de paiement, par catégorie, par produit,
- panier moyen, nombre de couverts, taux de rotation des tables,
- indicateurs de contrôle : annulations, retraits de lignes, ré-impressions, écarts de caisse.

Au-delà de 30 jours d'historique, prévoir une vue matérialisée `daily_sales_summary` rafraîchie à la clôture.

---

## 6. Gestion des erreurs

Format unique `application/problem+json` (RFC 9457) — détaillé dans `03-CONTRAT-API.md` :

```json
{
  "type": "https://caisse.local/errors/table-already-occupied",
  "title": "La table porte déjà une commande active",
  "status": 409,
  "code": "TABLE_ALREADY_OCCUPIED",
  "detail": "La table 12 a une commande ouverte depuis 19h42.",
  "meta": { "order_id": "...", "table_label": "12" }
}
```

Hiérarchie : `DomainError` (→ 4xx, `code` métier) / `InfrastructureError` (→ 5xx, message générique + log complet). Un `ExceptionHandler` global fait la traduction. **Aucune stack trace ne sort de l'API.**

Codes métier à couvrir dès le MVP : `SESSION_ALREADY_OPEN`, `NO_OPEN_SESSION`, `SESSION_HAS_OPEN_ORDERS`, `TABLE_ALREADY_OCCUPIED`, `ORDER_NOT_EDITABLE`, `PAYMENT_EXCEEDS_DUE`, `INSUFFICIENT_PRIVILEGE`, `OVERRIDE_REQUIRED`, `PRINTER_UNAVAILABLE`, `STOCK_NEGATIVE_WARNING`, `IDEMPOTENCY_CONFLICT`.

---

## 7. Transactions, concurrence, cohérence

- Isolation par défaut `READ COMMITTED`, **`SERIALIZABLE` sur les opérations financières** (paiement, clôture), avec retry sur `40001`.
- Verrou pessimiste `SELECT ... FOR UPDATE` sur la commande pendant l'encaissement et sur le compteur de séquence Z.
- Les totaux dénormalisés (`total_ttc_xof`, `paid_xof`) sont **toujours recalculés dans la transaction**, jamais incrémentés à l'aveugle depuis une valeur cliente.
- Contraintes en base, pas seulement en Python : index uniques partiels (une session ouverte par caisse, une commande active par table), `CHECK (amount_xof > 0)`, clés étrangères `ON DELETE RESTRICT`.
- Choix synchrone assumé : le volume (quelques centaines de requêtes/heure) ne justifie pas `async` + `asyncpg` ; la simplicité de débogage prime. Les endpoints restent `def` classiques, FastAPI les exécute dans un threadpool.

---

## 8. Configuration

`pydantic-settings`, un seul fichier `.env` par environnement :

```env
APP_ENV=production
DATABASE_URL=postgresql+psycopg://caisse:***@db:5432/caisse
JWT_SECRET=***
ACCESS_TOKEN_TTL_MINUTES=15
REFRESH_TOKEN_TTL_HOURS=12
PIN_MAX_ATTEMPTS=5

PRINT_AGENT_URL=http://host.docker.internal:8090 # nécessite extra_hosts: ["host.docker.internal:host-gateway"] sous Linux
PRINT_AGENT_TOKEN=              # requis seulement si l'agent écoute sur le LAN
PRINTER_WIDTH=48                # 48 caractères (80 mm) · 32 (58 mm) — à confirmer
DRAWER_PULSE=ESC_P_0_25_250     # code d'impulsion du tiroir

FNE_PROVIDER=manual             # manual | api | mock
FNE_SYNC_TIMEOUT_SECONDS=4      # attente maximale imposée au client
FNE_API_BASE_URL=
FNE_API_KEY=

TZ=Africa/Abidjan
BACKUP_DIR=/var/backups/caisse
BACKUP_REMOTE_TARGET=
```

Les paramètres **métier** (mentions du ticket, TVA, seuils, arrondi) ne vont **pas** dans `.env` mais dans la table `settings`, modifiables par l'admin depuis l'UI.

---

## 9. Tests

| Niveau | Cible | Contenu |
|---|---|---|
| Unitaires `domain/` | **≥ 90 %** | Totaux, TVA, arrondi, rendu monnaie, transitions interdites, écart de caisse, règles de stock |
| Intégration | ≥ 70 % | Endpoints avec vraie base (testcontainers), RBAC, idempotence, contraintes uniques, conflits |
| Bout en bout | 1 scénario | « Journée type » : ouverture → 3 tables → modification → paiement mixte → annulation → clôture Z, avec vérification des totaux et des mouvements de stock |

Cas de test explicitement obligatoires :

- Double `POST /payments` avec la même clé d'idempotence → **un seul** paiement, même réponse.
- Deux commandes simultanées sur la même table → une seule réussit (409 pour l'autre).
- Clôture avec une commande ouverte → 409 + liste des tables.
- Paiement supérieur au reste dû en Mobile Money → refus ; en espèces → rendu monnaie correct.
- Imprimante injoignable → la vente aboutit, le job reste `QUEUED`.
- Panne DGI → commande `PAID`, document `QUEUED`, ticket imprimé avec mention de transmission différée, rejeu ultérieur réussi.
- Timeout FNE dépassé → le client n'attend pas plus de `FNE_SYNC_TIMEOUT`.
- Agent d'impression injoignable → vente aboutie, job `QUEUED`, **tiroir non ouvert** → l'UI le signale explicitement.
- Ré-impression → aucun signal d'ouverture du tiroir n'est émis.
- Changement de prix en cours de service → les commandes ouvertes gardent l'ancien prix.

---

## 10. Observabilité

- Logs **structurés JSON** (`structlog`), avec `request_id`, `user_id`, `session_id`, `order_id`.
- Endpoint `/health` (liveness) et `/health/ready` (base + imprimante + file outbox).
- Métriques minimales exposées à l'UI admin : taille des files (impression, FNE), nombre d'échecs, dernier backup réussi, espace disque.
- Alerte simple (journal + bandeau UI) si : imprimante `FAILED` > 3 jobs, outbox FNE en échec > 1 h, sauvegarde manquée.

---

## 11. Déploiement

Le serveur est **l'ordinateur portable de la caisse**, et PostgreSQL est **mutualisé avec le PMS Hôtel Résidence de la Paix** (ADR-14 et §4 du document d'architecture) : une instance, deux bases, deux rôles, aucun accès croisé.

```
infra/docker-compose.yml           # socle commun
  db          postgres:16 · bases  hotel_paix  et  caisse · réseau infra_shared

caisse-backend/docker-compose.yml  # projet caisse
  api         FastAPI · réseau infra_shared · restart: always
  worker      outbox FNE + file d'impression + planificateur
  web         nginx : build React + proxy /api
  backup      pg_dump chiffré horaire + copie hors site quotidienne

print-agent                         # HORS Docker — Service Windows (NSSM) / win32print (port 8090)
```

`hotel-paix-backend/docker-compose.yml` perd son service `db` et rejoint `infra_shared` — `DB_HOST` reste `db`, aucune modification de code Django.

**Procédure complète — installation Windows, Docker Desktop, migrations, création de l'admin, sauvegardes, pgAdmin, dépannage : `04-EXPLOITATION-BACKEND.md`.**

Check-list de mise en production :

- [ ] `restart: always` sur tous les conteneurs + Docker Desktop configuré pour démarrer avec Windows
- [ ] **Options d'alimentation Windows réglées** : veille = jamais, fermeture capot = ne rien faire, suspension sélective USB = désactivée
- [ ] Agent d'impression configuré en Service Windows (via NSSM) avec redémarrage automatique
- [ ] **Test réel** : clic sur « Payer » → tiroir ouvert + ticket sorti, simultanément via Spooler Windows
- [ ] Onduleur sur l'imprimante et le routeur (le portable a sa batterie)
- [ ] Sauvegarde restaurée avec succès sur une machine tierce (test réel, pas théorique)
- [ ] Bases `caisse` et `hotel_paix` cloisonnées : vérifier qu'un rôle ne peut pas se connecter à l'autre base
- [ ] Seeds chargés : menu réel, tables réelles, comptes réels
- [ ] Consigne papier affichée près de la caisse (§9 du runbook)
- [ ] Décision prise sur la colocalisation en production (§4.4 du document d'architecture)

---

## 12. Conventions de code

- `ruff` + `ruff format`, ligne à 100 caractères.
- `mypy --strict` sur `domain/` et `services/`.
- Nommage **en anglais dans le code**, **en français dans l'UI et les libellés métier**. Le glossaire (§5.1 du doc global) donne la correspondance : `cash_session` = session de caisse, etc.
- Un commit = un changement cohérent, message conventionnel (`feat(orders): ...`).
- Toute nouvelle règle métier arrive avec son test unitaire dans la même PR.

---

## 13. Backlog backend par lot

| Lot | Tâches |
|---|---|
| **L0** | Squelette, **socle Docker mutualisé `infra/` + bascule du PMS**, Alembic, CI, `domain/money.py` + tests, endpoints mockés complets, publication de l'OpenAPI |
| **L1** | `users`, PIN/Argon2, JWT, refresh, RBAC, `authorize_override`, `cash_sessions` (ouverture/clôture simple), audit |
| **L2** | Catégories, produits, historique de prix, tables, seeds du menu réel |
| **L3** | Commandes, lignes, produit personnalisé, machine à états, `get_table_board` optimisé, annulation |
| **L4** | Paiements + idempotence + mixte, `printing_service`, **agent d'impression USB + ouverture du tiroir**, gabarit de ticket, mode dégradé |
| **L5** | Rapports X/Z, comptage par dénomination, écart, stock complet, alertes |
| **L6** | **FNE par ticket** : `fne_documents`, certification bornée à l'encaissement, outbox + rejeu, `ManualFneProvider`, `customers`/NCC, récap journalier par groupe fiscal, endpoints de reporting |
| **L7** | Tests e2e, sauvegardes + restauration testée, durcissement, **runbook `04-EXPLOITATION-BACKEND.md` validé sur la machine réelle** |
