# Contrat d'API v1

> **Document co-signé par les deux développeurs.**
> C'est la seule interface entre le backend et le frontend. Tout changement cassant se décide à deux et s'accompagne d'une mise à jour de ce fichier **avant** l'implémentation.
> Source de vérité exécutable : `http://<serveur>:8001/openapi.json` (généré par FastAPI).
>
> **v1.1** — la réponse d'encaissement porte désormais l'état de la **facture normalisée par ticket** et de l'**ouverture du tiroir**.

---

## 1. Conventions générales

| Sujet | Règle |
|---|---|
| Base | `/api/v1` — la version change uniquement en cas de rupture |
| Format | JSON, `snake_case`, UTF-8 |
| Dates | ISO 8601 UTC avec `Z` : `2026-09-24T20:14:03Z`. La **journée comptable** est une date nue : `business_date: "2026-09-24"` |
| Montants | **Entiers XOF**, suffixe `_xof` obligatoire : `total_ttc_xof: 9500`. Jamais de chaîne. *Exception documentée (D3)* : les prix unitaires de valorisation de stock (`avg_cost_xof`, `unit_cost_xof`, `unit_price_xof`) tolèrent un flottant à 2 décimales max pour les sous-unités (grammes, cl) ; tout total reste un entier strict. |
| Quantités | Entier pour les lignes de commande, décimal (3 chiffres) pour le stock |
| Identifiants | UUID en chaîne |
| Énumérations | MAJUSCULES_SNAKE : `PARTIALLY_PAID`, `MOBILE_MONEY` |
| Booléens | Préfixe `is_` / `has_` / `can_` |
| Tri / pagination | `?limit=50&cursor=...` (curseur opaque). Réponse : `{ "items": [...], "next_cursor": "..." }` |
| Champs nuls | Présents avec `null`, jamais absents |
| Langue | **Le backend ne renvoie pas de texte destiné à l'affichage final.** Il renvoie un `code` ; le front produit le message français |

### En-têtes

| En-tête | Sens | Usage |
|---|---|---|
| `Authorization: Bearer <jwt>` | → | Toutes les routes sauf `/auth/login` et `/health` |
| `Idempotency-Key: <uuid>` | → | **Obligatoire** sur toute mutation financière |
| `X-Device-Id: <uuid>` | → | Identifie le poste, tracé dans l'audit |
| `X-Override-Token: <token>` | → | Autorisation responsable ponctuelle |
| `X-Request-Id` | ↔ | Corrélation des logs |

---

## 2. Erreurs

Format unique `application/problem+json` :

```json
{
  "type": "https://caisse.local/errors/payment-exceeds-due",
  "title": "Montant supérieur au reste dû",
  "status": 422,
  "code": "PAYMENT_EXCEEDS_DUE",
  "detail": "Reste dû : 4 500 XOF, montant proposé : 6 000 XOF.",
  "meta": { "due_xof": 4500, "amount_xof": 6000 },
  "request_id": "01J..."
}
```

`code` est **stable et contractuel** : c'est sur lui que le front branche ses messages et ses comportements. `title` et `detail` servent aux logs et au débogage.

### Catalogue des codes (MVP)

| Code | HTTP | Comportement attendu côté front |
|---|---|---|
| `INVALID_CREDENTIALS` | 401 | Message + compteur d'essais |
| `ACCOUNT_LOCKED` | 423 | Afficher la durée de blocage (`meta.locked_until`) |
| `TOKEN_EXPIRED` | 401 | Rafraîchir une fois, sinon retour à `/login` |
| `INSUFFICIENT_PRIVILEGE` | 403 | Masquer/désactiver l'action |
| `OVERRIDE_REQUIRED` | 403 | Ouvrir `OverridePinDialog`, rejouer avec `X-Override-Token` |
| `NO_OPEN_SESSION` | 409 | Rediriger vers `/session/open` |
| `SESSION_ALREADY_OPEN` | 409 | Proposer de reprendre la session (`meta.session_id`) |
| `SESSION_HAS_OPEN_ORDERS` | 409 | Lister `meta.open_orders[]` avec accès direct |
| `BUSINESS_DATE_MISMATCH` | 409 | Demander confirmation explicite de la journée comptable |
| `TABLE_ALREADY_OCCUPIED` | 409 | Proposer d'ouvrir `meta.order_id` |
| `ORDER_NOT_EDITABLE` | 409 | Rafraîchir la commande, expliquer l'état |
| `PAYMENT_EXCEEDS_DUE` | 422 | Ajuster le montant au reste dû |
| `MARKET_BUDGET_EXCEEDED` | 422 | Budget marché journalier dépassé : validation bloquée côté front |
| `IDEMPOTENCY_CONFLICT` | 409 | Même clé, corps différent → bug client à corriger |
| `PRINTER_UNAVAILABLE` | 503 | Bandeau, **ne bloque pas la vente** |
| `PRINT_AGENT_UNAVAILABLE` | 503 | Idem, et signaler que **le tiroir ne s'est pas ouvert** |
| `FNE_REJECTED` | 200 | Dans `warnings[]` : facture rejetée par la DGI, prévenir le responsable |
| `STOCK_NEGATIVE_WARNING` | 200 | Avertissement dans `warnings[]`, pas une erreur |
| `VALIDATION_ERROR` | 422 | `meta.fields[]` → erreurs de formulaire |

---

## 3. Idempotence

Sur toute mutation financière ou irréversible : encaissements (`POST /orders/{id}/payments`), avoirs/remboursements (`POST /orders/{id}/refunds`), annulations (`POST /orders/{id}/cancel`), modifications de lignes (`POST /orders/{id}/items`), sessions de caisse (`POST /cash-sessions`, `POST /cash-sessions/{id}/close`), mouvements de stock (`POST /stock/receipts`, `POST /stock/losses`, `POST /stock/counts`), approvisionnement (`POST /purchases`), et émissions FNE (`POST /orders/{id}/fne`, `POST /fne/generate`) :

1. Le **front** génère un UUID **avant** l'appel et le conserve tant qu'aucune réponse définitive n'est reçue.
2. Le **backend** stocke la clé (index unique) avec le hachage du corps et la réponse produite.
3. Rejeu avec la même clé et le même corps → **la réponse d'origine**, statut `200` (au lieu de `201`) + en-tête `Idempotent-Replay: true`.
4. Même clé, corps différent → `409 IDEMPOTENCY_CONFLICT`.

---

## 4. Endpoints

Légende des rôles : `C` Caissier (Vente/Caisse) · `R` Responsable (Supervision/Dashboard/Stocks) · `A` Admin (Système/Utilisateurs) · `E` Acheteur/Économe (Approvisionnement).

### 4.1 Authentification

| Méthode | Chemin | Rôle | Description |
|---|---|---|---|
| POST | `/auth/login` | — | PIN + `device_id` → jetons |
| POST | `/auth/refresh` | — | Renouvellement |
| POST | `/auth/logout` | C / R / A | Révocation du refresh |
| GET | `/auth/me` | C / R / A | Utilisateur courant, rôle, session ouverte |
| POST | `/auth/override` | C | PIN responsable → `X-Override-Token` (60 s, usage unique) |

```http
POST /api/v1/auth/login
{ "pin": "482913", "device_id": "3f2a..." }

200
{
  "access_token": "eyJ...", "refresh_token": "eyJ...", "token_type": "bearer",
  "expires_in": 900,
  "user": { "id": "...", "full_name": "Awa Koné", "role": "CAISSIER" },
  "open_session": { "id": "...", "business_date": "2026-09-24", "cash_register_id": "..." }
}
```

### 4.2 Sessions de caisse

| Méthode | Chemin | Rôle | Description |
|---|---|---|---|
| GET | `/cash-sessions/current` | C | Session ouverte sur la caisse du poste |
| POST | `/cash-sessions` | C | Ouverture (idempotent — réservé caissier) |
| GET | `/cash-sessions/{id}/x-report` | C | Rapport X (sa session en cours) |
| POST | `/cash-sessions/{id}/close` | C | Clôture + Z avec comptage (idempotent) |
| GET | `/cash-sessions/{id}/z-report` | R / A | Rapport Z figé de clôture |
| GET | `/cash-sessions` | R / A | Historique des sessions de caisse |
| POST | `/cash-sessions/{id}/movements` | C | Entrée / sortie de tiroir (fond, appoint) |

```http
POST /api/v1/cash-sessions
Idempotency-Key: 7c1e...
{ "cash_register_id": "...", "opening_float_xof": 20000, "business_date": "2026-09-24" }
```

```http
POST /api/v1/cash-sessions/{id}/close
Idempotency-Key: 9a2f...
{
  "counted_breakdown": { "10000": 12, "5000": 8, "2000": 5, "1000": 14, "500": 20, "100": 35 },
  "notes": "RAS"
}

200
{
  "z_number": 128,
  "business_date": "2026-09-24",
  "expected_cash_xof": 196500, "counted_cash_xof": 196000, "variance_xof": -500,
  "totals": {
    "gross_ttc_xof": 412000, "vat_xof": 62847, "orders_count": 58,
    "by_payment_method": [
      { "method": "CASH", "amount_xof": 176500, "count": 41 },
      { "method": "MOBILE_MONEY", "amount_xof": 235500, "count": 17 }
    ],
    "by_fiscal_group": [
      { "group": "POISSONS", "quantity": 62, "amount_xof": 217000 },
      { "group": "JUS",      "quantity": 48, "amount_xof": 48000 },
      { "group": "EAU",      "quantity": 71, "amount_xof": 35500 }
    ],
    "controls": { "cancelled_orders": 1, "removed_items": 3, "reprints": 2 }
  },
  "print_job_id": "..."
}
```

### 4.3 Catalogue

| Méthode | Chemin | Rôle | Description |
|---|---|---|---|
| GET | `/categories` | C / R / A | Liste des catégories |
| POST / PATCH / DELETE | `/categories` | R / A | Gestion des catégories |
| GET | `/products?category_id=&search=&is_active=` | C / R / A | Menu pour caisse ou gestion |
| POST | `/products` | R / A | Création de plat/boisson permanent |
| PATCH | `/products/{id}` | R / A | Modification fiche produit |
| PATCH | `/products/{id}/price` | R / A | Changement de prix (historisé, motif requis) |
| POST | `/products/custom` | C | Produit à la volée pour commande en cours |

```http
GET /api/v1/products?category_id=...
200
{
  "items": [{
    "id": "...", "name": "Poisson braisé", "short_name": "Poisson braisé",
    "category_id": "...", "price_xof": 3500, "vat_rate": 18.0,
    "track_stock": false, "stock_quantity": null,
    "is_active": true, "is_custom": false, "color": "#B45309", "sort_order": 1
  }]
}
```

### 4.4 Tables

| Méthode | Chemin | Rôle | Description |
|---|---|---|---|
| GET | `/tables` | C / R / A | Configuration et plan |
| GET | `/tables/board` | C / R / A | **Écran d'accueil caisse & plan de salle Dashboard** |
| POST / PATCH | `/tables` | A | Configuration initiale des tables |

```http
GET /api/v1/tables/board
200
{
  "business_date": "2026-09-24",
  "summary": { "revenue_today_xof": 186500, "orders_count": 24, "open_orders": 3 },
  "tables": [
    { "id": "...", "label": "1", "zone": "Salle", "seats": 4, "status": "FREE",
      "order": null, "active_orders_count": 0, "active_orders": [] },
    { "id": "...", "label": "12", "zone": "Salle", "seats": 4, "status": "OCCUPIED",
      "current_order_id": "...", "current_total_ttc_xof": 12400,
      "active_orders_count": 2,
      "active_orders": [
        { "order_id": "...", "order_number": "...", "note_label": "Note 1", "total_ttc_xof": 7500, "guests_count": 2 },
        { "order_id": "...", "order_number": "...", "note_label": "Note 2", "total_ttc_xof": 4900, "guests_count": 2 }
      ],
      "order": { "id": "...", "total_ttc_xof": 12400, "paid_xof": 0,
                 "guests_count": 4, "opened_at": "2026-09-24T19:42:00Z",
                 "status": "OPEN" } }
  ]
}
```

### 4.5 Commandes

| Méthode | Chemin | Rôle | Description |
|---|---|---|---|
| POST | `/orders` | C | Créer (table, à emporter, ou nouvelle note sur table via `allow_multiple: true`, `note_label`) |
| GET | `/orders/{id}` | C / R / A | Détail complet (inclut `note_label`) |
| GET | `/orders?status=&business_date=&date_from=&date_to=&order_type=&search=` | C / R / A | Historique des commandes du restaurant (filtrable par date, type, statut ou recherche de plat) |
| POST | `/orders/{id}/items` | C | Ajouter une ligne |
| PATCH | `/orders/{id}/items/{item_id}` | C | Quantité, note |
| DELETE | `/orders/{id}/items/{item_id}` | C + override (R/A) | Retirer (motif obligatoire) |
| POST | `/orders/{id}/cancel` | C + override (R/A) | Annuler (motif obligatoire) |
| POST | `/orders/{id}/reprint` | C / R / A | Ré-impression (tracée) |

```http
POST /api/v1/orders/{id}/items
{ "product_id": "...", "quantity": 2, "note": "bien cuit" }

201
{
  "order": {
    "id": "...", "status": "OPEN", "table_id": "...", "guests_count": 4,
    "total_ttc_xof": 9500, "total_ht_xof": 8051, "total_vat_xof": 1449,
    "paid_xof": 0, "due_xof": 9500,
    "items": [
      { "id": "...", "product_id": "...", "name": "Poisson braisé",
        "unit_price_xof": 3500, "quantity": 2, "line_total_xof": 7000,
        "note": "bien cuit", "added_at": "2026-09-24T19:45:11Z" }
    ]
  },
  "warnings": []
}
```

> **Toutes** les mutations de commande renvoient **l'objet commande complet et recalculé**. Le front n'a jamais à additionner quoi que ce soit ni à enchaîner un second appel.

### 4.6 Paiements

| Méthode | Chemin | Rôle | Description |
|---|---|---|---|
| POST | `/orders/{id}/payments` | C | Encaissement (idempotent — caissier uniquement) |
| DELETE | `/orders/{id}/payments/{payment_id}` | R / A | Annulation d'un paiement (tracée) |
| POST | `/orders/{id}/refunds` | R / A | Remboursement / Avoir (idempotent) |
| GET | `/payment-methods` | C / R / A | Moyens de paiement actifs |

```http
POST /api/v1/orders/{id}/payments
Idempotency-Key: 4d9b...
{ "method": "CASH", "amount_xof": 5000, "tendered_xof": 5000 }

201
{
  "payment": { "id": "...", "method": "CASH", "amount_xof": 5000, "change_xof": 0 },
  "order": { "id": "...", "status": "PARTIALLY_PAID",
             "total_ttc_xof": 9500, "paid_xof": 5000, "due_xof": 4500 },
  "receipt": null
}
```

Second règlement soldant l'addition :

```http
POST /api/v1/orders/{id}/payments
Idempotency-Key: 8e0c...
{ "method": "MOBILE_MONEY", "provider": "WAVE", "amount_xof": 4500, "reference": "TX8812" }

201
{
  "payment": { "id": "...", "method": "MOBILE_MONEY", "amount_xof": 4500, "change_xof": 0 },
  "order": { "id": "...", "status": "PAID", "paid_xof": 9500, "due_xof": 0,
             "paid_at": "2026-09-24T20:14:03Z" },
  "receipt": {
    "print_job_id": "...", "status": "QUEUED", "drawer_opened": true
  },
  "fiscal_document": {
    "id": "...", "type": "FNE", "status": "CERTIFIED",
    "external_number": "2026-CI-00048127",
    "qr_payload": "https://fne.dgi.gouv.ci/v/...",
    "certified_at": "2026-09-24T20:14:06Z"
  },
  "warnings": [
    { "code": "STOCK_NEGATIVE_WARNING", "detail": "Sucrerie 33cl : stock -2",
      "meta": { "product_id": "..." } }
  ]
}
```

**Variante — transmission différée** (hors ligne ou délai de 4 s dépassé) : le statut HTTP reste `201`, la vente est faite, seul le bloc fiscal change.

```json
{
  "fiscal_document": {
    "id": "...", "type": "FNE", "status": "QUEUED",
    "external_number": null, "qr_payload": null,
    "internal_reference": "2026-09-24-0042",
    "next_retry_at": "2026-09-24T20:15:06Z"
  }
}
```

Statuts possibles de `fiscal_document.status` : `PENDING`, `SUBMITTING`, `CERTIFIED`, `QUEUED`, `FAILED`, `MANUAL`.
`receipt.drawer_opened` vaut `false` si l'agent d'impression n'a pas répondu — le front doit le signaler explicitement à la caissière.

### 4.7 Stock

| Méthode | Chemin | Rôle | Description |
|---|---|---|---|
| GET | `/stock?low_only=` | C / R / A | Consultation stock et alertes |
| POST | `/stock/{product_id}/receive` | R / A | Entrée manuelle de stock |
| POST | `/stock/{product_id}/adjust` | R / A | Ajustement / perte (motif obligatoire) |
| POST | `/stock/inventory` | R / A | Comptage d'inventaire groupé |
| GET | `/stock/{product_id}/movements` | R / A | Historique des mouvements de stock |

### 4.8 Clients entreprise et documents fiscaux

| Méthode | Chemin | Rôle | Description |
|---|---|---|---|
| GET | `/customers?search=&ncc=` | C / R / A | Recherche fiche client / NCC |
| POST | `/customers` | C / R / A | Création fiche client |
| POST | `/orders/{id}/fne` | C | Émission facture normalisée entreprise |
| POST | `/fne/generate` | C / R / A | Émission FNE directe (alias rétrocompatible, idempotent) |
| GET | `/fne/documents?status=&business_date=` | R / A | Suivi des documents fiscaux |
| POST | `/fne/documents/{id}/retry` | R / A | Rejeu manuel d'un document en échec |
| GET | `/fne/documents/{id}/duplicate` | C / R / A | Duplicata fiscal |
| GET | `/fne/pending-count` | C / R / A | Compteur pour la barre d'état |
| GET | `/fne/daily-summary?business_date=` | R / A | Récapitulatif journalier par groupe fiscal |
| GET | `/fne/daily-summary/{id}/export?format=csv\|json` | R / A | Export CSV/JSON pour application FNE |

```http
GET /api/v1/fne/daily-summary/summary_uuid/export?format=csv
200 Content-Type: text/csv
business_date,fiscal_group,quantity,gross_ht_xof,vat_xof,total_ttc_xof
2026-09-24,POISSONS,62,183898,33102,217000
2026-09-24,JUS,48,40678,7322,48000
2026-09-24,EAU,71,30085,5415,35500
```

### 4.9 Approvisionnement & Achats marché

| Méthode | Chemin | Rôle | Description |
|---|---|---|---|
| GET | `/purchases/market/budget-status?total_budget_xof=` | E / R / A | Statut de la jauge budgétaire marché (masque les montants pour l'économe) |
| GET | `/purchases/articles` | E / R / A | Liste des articles éligibles à l'achat |
| POST | `/purchases` | E / R / A | Créer une demande d'achat marché (idempotent, vérification de budget) |
| GET | `/purchases/mine` | E | Mes demandes d'achat |
| GET | `/purchases/mine/{id}` | E | Détail de ma demande |
| POST | `/purchases/mine/{id}/cancel` | E | Retirer ma demande en attente |
| GET | `/purchases` | R / A | Suivi de l'ensemble des demandes d'achat |
| GET | `/purchases/{id}` | R / A | Détail d'une demande d'achat |
| POST | `/purchases/{id}/approve` | R / A | Valider une demande d'achat |
| POST | `/purchases/{id}/reject` | R / A | Refuser une demande d'achat |
| POST | `/purchases/{id}/disburse` | R / A | Décaisser les fonds pour l'achat |
| POST | `/purchases/{id}/receive` | R / A | Réceptionner les achats et intégrer au stock |
| PUT | `/production/market-purchases/{id}` | R / A | Ajuster les articles, quantités ou l'enveloppe condiments d'un bon d'achat en attente (DRAFT) |
| GET | `/production/market-purchases/{id}/protein-analysis` | R / A | Comparatif des 9 protéines du bon vs ventes réelles et stock de la semaine |
| POST | `/production/market-purchases/{id}/complete` | R / A | **Modifié D9** — Valider le bon : `DRAFT` → `VALIDATED`, argent remis (`deduct_from_cash_session`), **le stock ne bouge plus** |
| POST | `/production/market-purchases/{id}/cancel` | E / R / A | **Ajout D10** — Annuler un bon pas encore validé (`DRAFT` → `CANCELLED`), corps `{"reason"}` obligatoire (voir ci-dessous) |
| POST | `/production/market-purchases/{id}/receive` | R / A | **Ajout D9** — Réceptionner (`VALIDATED` → `COMPLETED`) ou corriger les quantités reçues d'un bon `COMPLETED` (voir ci-dessous) |
| POST | `/production/opening-stock-corrections` | R / A | **Ajout D9** — Corriger le stock de départ d'un article à une journée (voir ci-dessous) |
| POST | `/production/daily-preparations` | C / R / A | Saisir la sortie cuisine d'une protéine pour une journée (`prepared_quantity: 0` l'efface). Réponse : `status` (`VALIDATED` si la quantité confirme l'estimation ou s'il n'y en a pas, `ADJUSTED` sinon) et `estimated_quantity` |
| POST | `/production/daily-preparations/validate-day` | C / R / A | **Ajout D6** — corps `{"business_date"}` : valider d'un coup les sorties `ESTIMATED` du jour. Réponse : `{business_date, validated_count, preparations[]}` |
| GET | `/production/weekly-matrix?date_from=&date_to=` | R / A | Matrice de contrôle hebdomadaire des 9 protéines (règle universelle du stock, ci-dessous) |

#### Réception des bons d'achat marché (D9, 05/11/2026)

Cycle du bon : `DRAFT` (prévu) → `VALIDATED` (validé, argent remis) → `COMPLETED` (réceptionné). Seule la réception fait entrer le stock, avec les **quantités réellement reçues** ; la quantité prévue peut différer de ce qui revient du marché.

`POST /production/market-purchases/{id}/receive`, corps `{"lines": [{"item_id", "received_quantity"}], "reason"?}` :
- bon `VALIDATED` : une ligne absente vaut la quantité prévue, `0` si l'article n'a pas été trouvé. Entrées `PURCHASE_IN` au prix unitaire du bon, **datées du bon** ; le kit condiments éventuel entre aussi en stock. Refusé (422) sur un bon `DRAFT` ou annulé ;
- bon `COMPLETED` : correction (motif `reason` obligatoire, 422 sinon). Pour chaque ligne modifiée, l'écart (reçu corrigé − reçu enregistré) est un `PURCHASE_IN` **signé** (négatif pour un retrait, sans changer le coût moyen), daté du bon, motif « Correction réception bon du JJ/MM/AAAA : ancien → nouveau — motif ». Aucun mouvement existant n'est modifié ;
- les quantités sont des valeurs cibles : rejouer la même demande ne change rien (pas d'en-tête d'idempotence requis).

`POST /production/opening-stock-corrections`, corps `{"article_id", "business_date", "quantity", "reason"}` : le stock de départ de l'article à `business_date` devient `quantity`. L'écart est un mouvement `OPENING` daté de cette journée (compté dans l'ouverture de la matrice) ; les journées suivantes, stock actuel compris, sont décalées d'autant. Réponse `OpeningStockCorrectionOut {article_id, article_name, unit, business_date, previous_quantity, quantity, delta_quantity, current_stock_quantity}`. Valeur cible : rejouer ne change rien.

Champs ajoutés (rétrocompatibles) : `MarketPurchaseItemOut.received_quantity` (null tant que non réceptionné), `MarketPurchaseListOut.received_at` et `received_by_user_name`. Les bons validés avant D9 (`COMPLETED`) ont `received_quantity` = quantité prévue (migration `028`).

#### Annulation des bons d'achat marché (D10, 05/11/2026)

`POST /production/market-purchases/{id}/cancel`, corps `{"reason"}` (3 à 200 caractères, 422 sinon) :
- seul un bon `DRAFT` (pas encore validé : ni argent remis, ni stock entré) s'annule. Un bon `VALIDATED` ou `COMPLETED` renvoie 409 `PURCHASE_NOT_CANCELLABLE` ; un bon réceptionné se corrige par ses quantités reçues (`/receive`) ;
- le bon n'est **jamais supprimé** : il passe à `CANCELLED` et reste listé par `GET /production/market-purchases` (historique). Il ne peut plus être modifié, validé ni réceptionné ;
- droits : responsable et admin pour tout bon ; l'économe seulement pour les bons qu'il a préparés (403 `INSUFFICIENT_PRIVILEGE` sinon) ; le caissier ne peut pas annuler ;
- rejouer l'annulation d'un bon déjà annulé renvoie le bon inchangé (pas d'en-tête d'idempotence requis). Action tracée dans le journal d'audit (`market_purchase.cancel`).

Champs ajoutés (rétrocompatibles) : `MarketPurchaseListOut.cancelled_at`, `cancelled_by_user_name`, `cancel_reason` (null si le bon n'est pas annulé). Migration `029`.

#### Règle universelle du stock protéines (D6, 04/11/2026)

Une seule source : le journal `stock_movements`. Pour chaque protéine et chaque journée de caisse :

> **Restant = Ouverture + Achats − Ventes − Pertes ± Écart d'inventaire ± Corrections**

| Colonne | Mouvements |
|---|---|
| Achats | `PURCHASE_IN`, tous circuits (bon marché, demande d'achat, entrée manuelle) |
| Ventes | `SALE_OUT` liés à une commande, moins les `RETURN_IN` |
| Pertes | `LOSS_OUT` |
| Écart d'inventaire | `INVENTORY_COUNT` (compté − théorique). Un `OPENING` (premier comptage) compte dans l'ouverture |
| Corrections | `ADJUSTMENT` et `SALE_OUT` sans commande (rattrapages des migrations 024/025) |

Le restant de fin de période (`closing_stock_qty`) est, par construction, le stock à cette date ; il est égal à `current_stock_qty` quand la période se termine aujourd'hui. Le stock baisse **à la vente** ; un plat sans fiche protéine (« Hors Menu ») déstocke la protéine citée dans son libellé, à sa portion standard. La **sortie cuisine n'est qu'un contrôle** (sorti contre vendu) : elle ne modifie jamais le stock. À la clôture de caisse elle est pré-remplie comme estimation (`ESTIMATED`), que la cuisine valide (`VALIDATED`) ou ajuste (`ADJUSTED`) ; une estimation ne remplace jamais une sortie validée ou ajustée.

Champs ajoutés (rétrocompatibles) :
- `WeeklyDayData` : `opening_quantity`, `purchased_quantity`, `stock_sold_quantity`, `loss_quantity`, `inventory_variance_quantity`, `correction_quantity`, `closing_quantity`, `preparation_status`, `estimated_quantity`, `preparation_gap_quantity` (sorti cuisine − besoin des plats encaissés, portion × plats, déstockés ou non ; 0 les jours sans sortie saisie), `non_destocked_dishes` (plats encaissés sans sortie de stock). `remaining_quantity` reste le disponible du jour (ouverture + achats du jour).
- `WeeklyProductRow` : `total_stock_sold_qty`, `total_loss_qty`, `total_inventory_variance_qty`, `total_correction_qty`, `closing_stock_qty`, `current_stock_qty`, `total_non_destocked_dishes`. `weekly_purchased_qty`/`weekly_purchased_cost_xof` comptent désormais toutes les entrées d'achat de la période ; `quantity_variance` = somme des `preparation_gap_quantity` (seuls les jours avec sortie saisie) ; `actual_gross_margin_xof` = vente réelle − coût de la matière consommée au CMP (ventes + pertes + manquant net d'inventaire et de corrections), et non plus − achats de la période ; `dishes_variance` = plats vendus − plats possibles (positif : plus vendu que le stock disponible, anomalie). Rapport `/reports/protein-yields` : `consumed_quantity` compense inventaires et corrections avant de retenir un manquant.
- `DailyPreparationOut` : `status`, `estimated_quantity`.
- `StockReportArticle` (`/reports/stock`) : `correction_quantity`. `count_adjustment_quantity` ne compte plus que les inventaires ; `sold_quantity` exclut les sorties sans commande.


### 4.10 Impression

| Méthode | Chemin | Rôle | Description |
|---|---|---|---|
| GET | `/printing/status` | C / R / A | État de l'agent, de l'imprimante et de la file |
| POST | `/printing/open-drawer` | R / A | Ouverture manuelle du tiroir (tracée, superviseur) |
| GET | `/printing/jobs?status=` | C / R / A | File d'impression |
| POST | `/printing/jobs/{id}/retry` | C / R / A | Rejeu d'un ticket en file |
| POST | `/printing/test` | A | Ticket de test (configuration) |

```http
GET /api/v1/printing/status
200
{
  "agent_online": true, "printer_online": true, "paper": "ok",
  "width": 48, "queued_jobs": 0, "failed_jobs": 0,
  "last_success_at": "2026-09-24T20:14:05Z"
}
```

### 4.11 Rapports & Tableau de bord

| Méthode | Chemin | Rôle | Description |
|---|---|---|---|
| GET | `/reports/dashboard?business_date=` | R / A | **Tableau de bord de supervision en direct** |
| GET | `/reports/overview?business_date=` | R / A | **Synthèse d'exploitation complète de la journée** |
| GET | `/reports/sales?date_from=&date_to=` | R / A | **Statistiques détaillées et suivi journalier des ventes et marges (`by_day`: achats, coûts matières fiches, marge brute, espèces et écarts)** |
| GET | `/reports/sales/export?date_from=&date_to=` | R / A | **Export CSV Excel du suivi journalier des ventes et marges (séparateur `;`, UTF-8 BOM)** |
| GET | `/reports/protein-yields?date_from=&date_to=` | R / A | **Contrôle des rendements viandes & poissons (croisement sorties stock, fiches techniques, plats vendus et écarts de portions)** |
| GET | `/reports/protein-yields/export?date_from=&date_to=` | R / A | **Export CSV Excel du contrôle des rendements viandes & poissons** |
| GET | `/reports/stock?date_from=&date_to=` | R / A | **Rapport de stock, consommations et valorisation au CMP** |
| GET | `/reports/audit?from=&to=&action=` | A | Journal d'audit de sécurité |

### 4.12 Finance & Décaissements

| Méthode | Chemin | Rôle | Description |
|---|---|---|---|
| POST | `/finance/expenses` | C / R / A | **Enregistrer une dépense d'exploitation / décaissement** (avec déduction tiroir-caisse optionnelle) |
| GET | `/finance/expenses?date_from=&date_to=&category=` | C / R / A | **Lister les dépenses de la période** avec totaux |
| POST | `/finance/bank-deposits` | R / A | **Enregistrer un bordereau de versement bancaire** (rapprochement) |
| GET | `/finance/bank-deposits?date_from=&date_to=` | C / R / A | **Lister les versements bancaires** de la période |
| POST | `/finance/cash-regularizations` | R / A | **Régulariser un écart de caisse après la clôture** : `business_date`, `amount_xof` signé (positif = argent retrouvé, négatif = manque constaté après coup, jamais nul), `reason` obligatoire, `cash_session_id` facultatif s'il n'y a qu'une session ce jour-là. La session doit être **clôturée** ; le Z n'est **pas modifié** (la régularisation est tracée à côté et journalisée). `Idempotency-Key` obligatoire |
| GET | `/finance/cash-regularizations?date_from=&date_to=` | R / A | **Lister les régularisations d'écart** de la période avec total |

**Saisies libres (hors menu) dans `/reports/sales` (04/11/2026).** Chaque saisie libre est une ligne de `by_product` à son libellé, avec `product_id` = `hors-menu:<libellé>` et `is_off_menu: true` (auparavant toutes les saisies libres étaient regroupées sous un seul libellé). `totals.uncosted_revenue_xof` ne compte plus que les produits **du catalogue** sans fiche technique.

**Total versé (ajout du 04/11/2026, rétrocompatible).** Dans `/reports/sales`, `counted_cash_xof` garde son sens historique (espèces comptées, **fond de caisse inclus**). Nouveaux champs de `by_day` : `opening_float_xof`, `non_cash_payments_xof`, `cash_regularization_xof`, `adjusted_cash_variance_xof` (écart du Z + régularisations), `has_closed_session`, et **`remitted_xof` = espèces comptées − fond de caisse + paiements hors espèces + régularisations**, sur les sessions clôturées. Sans écart, le total versé est égal au chiffre d'affaires. `totals` reçoit `remitted_xof` et `cash_regularization_xof` ; chaque élément de `cash_sessions` reçoit `opening_float_xof`, `closed_by` et `regularization_xof`.

### 4.13 Administration

| Méthode | Chemin | Rôle | Description |
|---|---|---|---|
| GET / POST / PATCH | `/users` | A | Gestion des comptes utilisateurs |
| POST | `/users/{id}/pin` | A | Réinitialisation de code PIN |
| GET / PUT | `/settings` | A | Paramètres généraux (ticket, TVA, FNE) |
| GET / POST / PATCH | `/cash-registers` | A | Paramétrage des postes de caisse |

### 4.14 Santé

| Méthode | Chemin | Rôle | Description |
|---|---|---|---|
| GET | `/health` | — | Vivant (utilisé par le bandeau de connexion) |
| GET | `/health/ready` | — | Base, imprimante, files d'attente |

---

## 5. Temps réel (phase 2)

Non implémenté au MVP (un seul poste → le `refetchInterval` de 5 s suffit).
Quand plusieurs postes existeront : `WS /api/v1/ws` avec des événements `table.updated`, `order.updated`, `printer.status`, `session.closed`. Le contrat des charges utiles reprendra exactement les objets ci-dessus, pour que le front puisse se contenter de remplacer une entrée de cache.

---

## 6. Règles de versionnement

| Type de changement | Conséquence |
|---|---|
| Ajout d'un champ optionnel en réponse | Non cassant — autorisé à tout moment |
| Ajout d'un endpoint | Non cassant |
| Ajout d'une valeur d'énumération | **Cassant en pratique** → le front doit toujours prévoir un cas par défaut ; prévenir malgré tout |
| Renommage / suppression d'un champ | Cassant → `/api/v2` ou période de double publication |
| Changement de sémantique d'un `code` d'erreur | Cassant → interdit, créer un nouveau code |

---

## 7. Check-list avant de geler le contrat (fin S1)

- [ ] Tous les endpoints du MVP existent dans FastAPI, même en réponse mockée
- [ ] `/openapi.json` publié et types TS générés sans erreur
- [ ] Handlers MSW alignés sur les mêmes fixtures que les seeds backend
- [ ] Les deux développeurs ont relu et validé le catalogue de codes d'erreur
- [ ] Le parcours « commande → paiement mixte → ticket » est simulable de bout en bout en mode mock
