# Backend caisse MYK — guide pour le front

État au 21/10/2026, dépôt `MYK_POS_VPS` (branche `main`), déployé en recette sur **http://162.215.172.50:8083**. Ce guide dit **comment brancher le front sur le backend et le déployer**. Le détail de chaque route (corps, réponses, codes d'erreur) est dans [`ENDPOINTS-TESTABLES.md`](ENDPOINTS-TESTABLES.md), et Swagger (http://162.215.172.50:8083/docs) reste la référence exacte des schémas.

> **Nouveau (20/10/2026) : la caisse est en ligne.** Backend et base tournent sur un serveur ; le terminal du restaurant n'a que le navigateur (le front) et un petit agent qui imprime les tickets. Ce qui change pour le front : l'impression ne répond plus en direct (§5.3, §6) et le build est déployé sur le serveur (§10).

## 1. Un seul backend

Le projet a **un seul backend** : celui de ce dépôt (`MYK_POS_VPS`, issu de la branche `digui_remote` de `Caisse_MYK_backend`). La branche `aziz` contenait un second backend (`apps/api`). Toutes ses fonctions ont été reprises ici, testées et documentées, mais **sous les routes du contrat** (`03-CONTRAT-API.md`). Cette branche sert désormais de référence et ne doit plus évoluer.

Règles de travail :

1. **Le front n'appelle que ce backend.** Les routes et les formats sont ceux de ce guide et d'`ENDPOINTS-TESTABLES.md`.
2. **Il manque une route, ou un format ne convient pas ?** Ouvre une demande (issue GitHub ou message) avec l'écran concerné et la donnée attendue. On convient du nom et du format **avant** de coder ; c'est côté backend qu'on l'ajoute.
3. **En attendant une route**, simule-la côté front (fixtures MSW, prévues dans `02-FRONTEND.md`) plutôt que de la coder dans un backend parallèle.
4. **`main` est protégée** : on n'y entre que par pull request relue.

La section [4](#4-passer-de-la-branche-aziz-à-ce-backend) liste, route par route, ce qui change par rapport au backend de la branche `aziz`.

## 2. Démarrer

### 2.1 Sur la recette (recommandé)

Rien à installer côté backend : il tourne déjà.

| | |
|---|---|
| Appli (front déployé) | http://162.215.172.50:8083 |
| Base de l'API **dans le code du front** | `/api/v1`, **chemin relatif** : le front et l'API sont servis par la même adresse, donc pas de CORS |
| Swagger | http://162.215.172.50:8083/docs |
| Santé (bandeau de connexion) | `GET /api/v1/health` |
| Comptes de test | un PIN par rôle (`CAISSIER`, `RESPONSABLE`, `ADMIN`), transmis en privé |

En développement local (`npm run dev`), viser la recette par un proxy, sans changer le code :

```js
// vite.config.js
server: { proxy: { '/api': 'http://162.215.172.50:8083' } }
```

(Appeler `http://162.215.172.50:8083/api/v1` en URL complète depuis `http://localhost:5173` marche aussi : cette origine est autorisée.)

La recette est un environnement de test : HTTP sans chiffrement, données fictives effacées sans préavis, FNE simulée. Aucune vraie donnée client.

### 2.2 Backend en local (facultatif)

```bash
cp .env.example .env            # renseigner DATABASE_URL et JWT_SECRET ; APP_ENV=development en dev
docker compose up -d --build
docker compose exec api alembic upgrade head                  # migrations jusqu'à 0007
docker compose exec api python -m caisse.cli bootstrap        # caisse « Caisse 1 » + paramètres
docker compose exec api python -m caisse.cli create-user      # un ADMIN (PIN 6 chiffres)
docker compose exec api python -m caisse.cli import-catalog   # menu réel (40 produits)
docker compose exec api python -m caisse.cli import-stock --stock-initial   # 115 articles, 35 fiches
docker compose exec api python -m caisse.cli create-tables --count 10
curl -s localhost:8001/health/ready
```

- API : `http://localhost:8001/api/v1`. Swagger : `http://localhost:8001/docs`, **coupé quand `APP_ENV=production`** (sauf `ENABLE_DOCS=true`).
- Pour les tests, crée un utilisateur par rôle (`POST /users` en ADMIN) : `CAISSIER`, `RESPONSABLE` (le gestionnaire), `ADMIN` (M. Yapi).
- Le menu de démonstration (`seed --demo`) est une autre option ; ne pas le mélanger avec le menu réel.
- CORS : en développement, `CORS_ORIGINS=*` ou la liste des origines du front dans le `.env`.
- Ce `docker-compose.yml` attend le socle PostgreSQL partagé (`../infra`, réseau `infra_shared`). Sans lui, utiliser la recette (§2.1).
- Tickets : sans agent d'impression lancé, ils restent `QUEUED` (normal). Pour les voir sortir : agent en mode factice, [`print-agent/README.md`](../print-agent/README.md).

## 3. Conventions

| Sujet | Règle |
|---|---|
| Préfixe | `/api/v1` pour tout, sauf `/health` et `/health/ready` |
| Authentification | `Authorization: Bearer <access_token>` ; jeton d'accès de 15 min, jeton de renouvellement de 12 h |
| Poste | `X-Device-Id: <identifiant du poste>` sur toutes les requêtes (blocage des PIN, audit). `device_id` aussi dans le corps de `POST /auth/login` |
| Rôles | `CAISSIER < RESPONSABLE < ADMIN` : un rôle a les droits des rôles inférieurs. Rôle insuffisant : `403 INSUFFICIENT_PRIVILEGE` |
| Identifiants | UUID (chaînes) |
| Montants | **Entiers en XOF** (`price_xof`, `total_ttc_xof`…). Seuls les taux de TVA et les quantités de stock sont décimaux |
| Dates | ISO 8601 en UTC (Abidjan est à UTC). `business_date` = journée comptable de la session de caisse |
| Listes | Toujours enveloppées : `{ "items": [...], "next_cursor": null }`. **Paginées** pour `GET /orders`, `/cash-sessions`, `/stock/movements`, `/fne/documents`, `/printing/jobs` : 100 par défaut (`limit` ≤ 500) ; si `next_cursor` n'est pas `null`, rappeler avec `cursor=<next_cursor>` et les mêmes filtres (`ENDPOINTS-TESTABLES` §0) |
| Erreurs | `application/problem+json` : `{type, title, status, code, detail, meta, request_id}`. **Se fier à `code`**, jamais au texte |
| Avertissements | Une réponse `200`/`201` peut porter `warnings: [{code, detail, meta}]` (non bloquant : afficher un bandeau) |
| Idempotence | En-tête `Idempotency-Key` (une clé neuve par action, générée par le front) **obligatoire** sur : `POST /cash-sessions`, `POST /cash-sessions/{id}/close`, `POST /orders/{id}/payments`, `POST /stock/receipts`, `POST /stock/losses`, `POST /stock/counts`. Sans la clé : `422 VALIDATION_ERROR`. Rejouer la même clé renvoie la réponse d'origine en `200` avec `Idempotent-Replay: true` ; même clé, corps différent : `409 IDEMPOTENCY_CONFLICT` |
| Mise à jour partielle | `PATCH` (et `PUT /settings`) ne change que les champs envoyés ; `null` efface un champ facultatif |
| Suppression | Toujours **logique** (`is_active: false`) : l'historique reste lisible |

### Connexion et jetons

```http
POST /api/v1/auth/login
{ "pin": "482913", "device_id": "poste-1" }
→ 200 { "access_token": "…", "refresh_token": "…", "token_type": "bearer", "expires_in": 900,
        "user": { "id": "…", "full_name": "Awa Koné", "role": "CAISSIER" },
        "open_session": { "id": "…", "business_date": "2026-10-19", "cash_register_id": "…" } }
```

- `POST /auth/refresh {"refresh_token": "…"}` renvoie **une nouvelle paire** de jetons. L'ancien jeton de renouvellement est révoqué (rotation) : **stocker le nouveau**, sinon le renouvellement suivant échoue en `401`.
- PIN faux : `401 INVALID_CREDENTIALS` (`meta.remaining_attempts`), puis `423 ACCOUNT_LOCKED` (poste bloqué, `meta.locked_until`).
- Au-delà de 10 tentatives par minute depuis la même adresse IP : `429 RATE_LIMIT_EXCEEDED`, avec l'en-tête `Retry-After`.

### Autorisation d'un responsable (override)

Annuler une commande ou un paiement demande un RESPONSABLE. Un caissier passe par une autorisation ponctuelle :

```http
POST /api/v1/auth/override            (avec le jeton du caissier)
{ "pin": "<PIN du responsable>", "action": "order.cancel", "required_role": "RESPONSABLE" }
→ 200 { "override_token": "…", "expires_in": 60, "granted_by": { … } }
```

On renvoie ensuite l'action avec l'en-tête `X-Override-Token`. Le jeton est valable 60 s et à **usage unique**, lié à l'action et au caissier. Actions concernées : `order.cancel`, `payment.void`. Un RESPONSABLE connecté n'en a pas besoin.

## 4. Passer de la branche `aziz` à ce backend

### Routes qui changent

| Branche `aziz` | Ici | À savoir |
|---|---|---|
| `GET /catalog/categories` | `GET /categories` | `?is_active=false` pour les désactivées |
| `POST /catalog/categories` | `POST /categories` | + `PATCH`/`DELETE /categories/{id}` |
| `GET /catalog/products` | `GET /products` | `?category_id=&search=&is_active=` ; + `GET /products/{id}` |
| `POST /catalog/products` | `POST /products` | `track_stock` ne se saisit plus : il vient de la fiche technique |
| `PATCH /catalog/products/{id}/price` `{new_price_xof, reason}` | `PATCH /products/{id}/price` `{price_xof, reason}` | + `GET /products/{id}/price-history` |
| `GET /stock` | `GET /stock/articles` | Le stock porte sur des **articles** (bœuf en kg, bouteilles…), plus sur les produits : voir §6 |
| `POST /stock/movements` | `POST /stock/receipts` (entrée) ou `POST /stock/losses` (perte) | Plusieurs articles par saisie, `Idempotency-Key` |
| `POST /stock/inventory` | `POST /stock/counts` | Idem |
| `GET /settings/registers` | `GET /cash-registers` | `open_session` à la place de `has_active_session` |
| `POST /settings/registers` | `POST /cash-registers` | |
| `PATCH /settings/registers/{id}` | `PATCH /cash-registers/{id}` | |
| `DELETE /settings/registers/{id}` | `PATCH /cash-registers/{id}` `{"is_active": false}` | |
| `GET`/`PUT /settings` | Mêmes routes | Mêmes noms pour l'établissement ; pas de `print_width` (dans le `.env`) ; + moyens de paiement, coupures, FNE. `PUT` : seuls les champs envoyés changent |
| `POST /cash-sessions/{id}/print-z`, `POST /printing/z-report/{id}` | `POST /cash-sessions/{id}/z-report/reprint` | Le Z s'imprime **déjà automatiquement** à la clôture ; cette route sert au duplicata |
| `POST /printing/reprint/{order_id}` | `POST /orders/{id}/reprint` | |
| `POST /printing/test-ticket` | `POST /printing/test` | ADMIN |
| `GET /fne/export` | `GET /fne/documents/export` | CSV `;` UTF-8 avec BOM ; `?status=&date_from=&date_to=` |
| `POST /fne/generate` | `POST /orders/{id}/fne` | `{ "template": "B2C" \| "B2B" \| "B2G" \| "B2F", "customer_id": … }` |
| `GET /orders/{id}/payments` | `GET /orders/{id}` | Les paiements sont dans `order.payments` (annulés compris) |
| `GET /reports/dashboard?date=` | `GET /reports/dashboard?business_date=` | Noms de champs différents : voir §5.4 |
| WebSocket `/ws` | — | Pas de temps réel pour l'instant (phase 2) : rafraîchir `GET /tables/board` toutes les 5 à 10 s sur l'écran d'accueil |

`POST/PATCH/DELETE /tables` et `GET /customers/{id}` existent ici avec **les mêmes chemins**.

### Formats qui changent sur les routes communes

- **Listes** : `{items, next_cursor}` au lieu d'un tableau nu.
- **`POST /auth/refresh`** : renvoie aussi un nouveau `refresh_token` (rotation, voir §3).
- **`POST /auth/override`** : `{pin, action, required_role}` au lieu de `{manager_pin, reason, target_action}` ; le motif se donne sur l'action elle-même (`reason`).
- **`Idempotency-Key` absente** : `422 VALIDATION_ERROR` au lieu de `400 IDEMPOTENCY_KEY_REQUIRED`.
- **`GET /tables/board`** : `{business_date, summary, tables[]}`. Chaque table a `status` (`FREE`/`OCCUPIED`), `orders[]` (les commandes actives), `order` (la plus ancienne) et `total_ttc_xof`. Ce format remplace `is_occupied`, `active_orders[]`, `open_orders_count` et `total_in_progress_xof`.
- **Partage de table** : mêmes champs que chez toi, `note_label` et `allow_multiple` sur `POST /orders` (voir §5.2).

## 5. Écran par écran

### 5.1 Ouverture de la caisse

| Étape | Route |
|---|---|
| Connexion | `POST /auth/login` ; `open_session` dit si une caisse est déjà ouverte |
| Choisir la caisse | `GET /cash-registers` → `id` (et `open_session` de chaque caisse) |
| Ouvrir | `POST /cash-sessions` `{cash_register_id, opening_float_xof}` + `Idempotency-Key`. Caisse inconnue ou hors service : `404` |
| Session en cours | `GET /cash-sessions/current` |
| Paramètres utiles | `GET /settings` : `screen_lock_timeout_seconds`, `payment_methods`… |

### 5.2 Plan de salle et prise de commande

| Étape | Route |
|---|---|
| Plan de salle | `GET /tables/board` |
| Menu | `GET /categories`, `GET /products` (`stock_quantity` = portions encore vendables, `null` sans fiche technique) |
| Nouvelle commande | `POST /orders` `{table_id, guests_count}` ; à emporter : `table_id: null` → `counter_number` |
| Lignes | `POST /orders/{id}/items` `{product_id, quantity, note}`, `PATCH …/items/{item_id}`, `DELETE …/items/{item_id}?reason=…` |
| Article libre | `POST /products/custom` puis `POST /orders/{id}/items` |
| Annuler | `POST /orders/{id}/cancel` `{reason}` (RESPONSABLE ou `X-Override-Token`) |

**Partage de table.** Sur une table occupée, `POST /orders` répond `409 TABLE_ALREADY_OCCUPIED` (`meta.order_id` : la commande à ouvrir). Pour servir un autre groupe à la même table, renvoyer avec `"allow_multiple": true` ou une `"note_label": "Groupe Koné"`. Chaque commande d'une table a une étiquette (« Note 1 », « Note 2 »… premier numéro libre) ; étiquette déjà prise : `409 ORDER_LABEL_TAKEN`.

### 5.3 Encaissement

| Étape | Route |
|---|---|
| Moyens proposés | `GET /payment-methods` (opérateurs Mobile Money : `WAVE`, `ORANGE`, `MTN`, `MOOV`) |
| Encaisser | `POST /orders/{id}/payments` `{method, amount_xof, tendered_xof?, provider?, reference?}` + `Idempotency-Key`. Partiel ou mixte : appeler plusieurs fois |
| Ticket | Mis en file automatiquement quand la commande passe `PAID` : `receipt.status = "QUEUED"`, `receipt.drawer_opened = null`. L'agent du terminal l'imprime et ouvre le tiroir sous ~2 s ; suivre `GET /printing/jobs/{receipt.print_job_id}` (`DONE`, `FAILED`) pour avertir la caissière |
| Stock | Le paiement qui solde la commande **déstocke** les articles des fiches techniques. `warnings[]` contient `STOCK_NEGATIVE_WARNING` si un article passe sous zéro (bandeau, jamais bloquant) |
| Annuler un paiement | `DELETE /orders/{id}/payments/{payment_id}?reason=…` (RESPONSABLE ou override `payment.void`). Le stock revient |
| Ré-imprimer | `POST /orders/{id}/reprint` |
| FNE | `POST /orders/{id}/fne`, client entreprise : `GET/POST /customers`, `GET /customers/{id}` |

### 5.4 Clôture et tableau de bord du jour (RESPONSABLE)

| Étape | Route |
|---|---|
| Rapport X | `GET /cash-sessions/{id}/x-report` |
| Clôture (Z) | `POST /cash-sessions/{id}/close` `{counted_breakdown: {"10000": 3, "5000": 2}, notes}` + `Idempotency-Key`. Refusée si des commandes sont ouvertes (`409 SESSION_HAS_OPEN_ORDERS`). Le Z s'imprime |
| Duplicata du Z | `POST /cash-sessions/{id}/z-report/reprint` |
| Tableau du jour | `GET /reports/dashboard?business_date=` |

Correspondance des champs du tableau du jour (`aziz` → ici) : `total_sales_ttc_xof` → `revenue_xof` ; `settled_orders` → `orders_paid` ; `open_orders` → `orders_open` ; `average_basket_xof` → `average_ticket_xof` ; `dine_in_orders_count` / `takeaway_orders_count` → `dine_in_orders` / `takeaway_orders` ; `active_tables_count` / `total_tables_count` → `tables_occupied` / `tables_total` ; `payments_by_method` → `payments` (par moyen **et opérateur**) ; `top_products` (mêmes infos : `name`, `quantity`, `revenue_xof`) ; `hourly_sales` → `hourly` ; `sales_by_cashier` → `by_cashier` ; `closing_status` → `sessions[]` ; `low_stock_items_count` → `low_stock_articles` ; `fne_certified_count` / `fne_pending_count` → `fne.certified` / `fne.pending`. Nouveau : `orders_cancelled`, `guests_count`.

### 5.5 Gestion du stock (RESPONSABLE, le gestionnaire)

| Écran | Route |
|---|---|
| Articles | `GET /stock/articles?category=&search=&low_only=`, `POST /stock/articles`, `PATCH /stock/articles/{id}` |
| Entrée (achat) | `POST /stock/receipts` `{supplier, lines: [{article_id, quantity, total_cost_xof}]}` (ou `unit_cost_xof`) |
| Perte | `POST /stock/losses` `{reason, lines: [{article_id, quantity}]}` |
| Inventaire | `POST /stock/counts` `{lines: [{article_id, counted_quantity}]}` |
| Journal | `GET /stock/movements?article_id=&type=&date_from=&date_to=` |
| Fiche technique d'un plat | `GET`/`PUT /products/{id}/components` `{components: [{article_id, quantity}]}` |

### 5.6 Tableaux de M. Yapi (ADMIN)

| Tableau | Route |
|---|---|
| Ventes sur une période | `GET /reports/sales?date_from=&date_to=` : CA, coût matière, marges par jour, plat, catégorie, moyen de paiement, écarts de caisse |
| Stock sur une période | `GET /reports/stock?date_from=&date_to=` : début et fin de période, entrées, ventes, pertes, écart d'inventaire, alertes |

### 5.7 Administration

| Écran | Route | Rôle |
|---|---|---|
| Catalogue | `POST /categories`, `PATCH/DELETE /categories/{id}`, `POST /products`, `PATCH /products/{id}`, `PATCH /products/{id}/price` | RESPONSABLE |
| Salle | `POST /tables`, `PATCH/DELETE /tables/{id}` | ADMIN |
| Caisses | `POST /cash-registers`, `PATCH /cash-registers/{id}` | ADMIN |
| Paramètres | `PUT /settings` | ADMIN |
| Utilisateurs | `GET/POST /users`, `PATCH /users/{id}`, `POST /users/{id}/pin` | ADMIN |
| Impression | `GET /printing/status`, `GET /printing/jobs`, `GET /printing/jobs/{id}`, `POST /printing/jobs/{id}/retry`, `POST /printing/open-drawer` (RESPONSABLE, `202`), `POST /printing/test` (ADMIN, `202`) | — |
| Terminaux d'impression | `GET/POST /printing/terminals`, `POST /printing/terminals/{id}/revoke` (jeton de l'agent, affiché une fois) | ADMIN |
| FNE | `GET /fne/documents`, `…/retry`, `…/resolve`, `…/refund`, `GET /fne/documents/export`, `GET /fne/daily-summary` | RESPONSABLE |

## 6. Nouveautés depuis le 06/10/2026

| Sujet | En bref | Détail |
|---|---|---|
| **Impression tirée par le terminal (20/10)** | La caisse est en ligne : l'agent du terminal vient chercher les tickets. Le paiement répond `receipt.status = "QUEUED"` et `drawer_opened = null` ; suivre `GET /printing/jobs/{id}`. Tiroir manuel et ticket de test : `202` | `ENDPOINTS-TESTABLES` §10 |
| **Stock par articles et fiches techniques** | Le gestionnaire saisit entrées, pertes et inventaires ; **les plats vendus déstockent automatiquement** les articles de leur fiche (0,2 kg de bœuf par plat, 1 bouteille par boisson…). Les légumes, condiments et le gaz se suivent par inventaire. `GET /products` : `stock_quantity` = portions encore vendables | `ENDPOINTS-TESTABLES` §11 |
| **Tableaux de M. Yapi** | Ventes (marges par plat) et stock (écart entre stock théorique et compté) sur une période | §12 |
| **Tableau de bord du jour** | Pour le responsable : la journée en un appel | §12 |
| **Menu réel** | Menu, 115 articles et 35 fiches tirés des Excel du restaurant (`import-catalog`, `import-stock`) | §11 |
| **Gestion du catalogue** | Catégories et produits, prix historisé avec motif ; une commande en cours garde ses prix | §4 |
| **Tables et partage de table** | Gestion de la salle ; plusieurs commandes par table | §5, §7 |
| **Paramètres et caisses** | `/settings`, `/cash-registers` | §13 |
| **Duplicata du Z, export FNE** | `POST /cash-sessions/{id}/z-report/reprint`, `GET /fne/documents/export` | §6, §9 |
| **Ticket** | L'opérateur Mobile Money (« Wave », « Orange Money »…) et le NCC/RCCM apparaissent | §8 |
| **Sécurité** | `429` au-delà de 10 connexions/min par IP, `413` au-delà de 2 Mo, en-têtes de sécurité, Swagger coupé en production | §0, §2 |
| **Annulation de paiement** | N'est plus refusée quand la table a été rouverte (`table_reoccupied` supprimé) | §8 |

Nouveaux codes d'erreur : `STOCK_ARTICLE_NAME_EXISTS`, `CATEGORY_NAME_EXISTS`, `CATEGORY_NOT_EMPTY`, `PRODUCT_NAME_EXISTS`, `PRODUCT_SKU_EXISTS`, `ORDER_LABEL_TAKEN`, `TABLE_LABEL_EXISTS`, `TABLE_HAS_ACTIVE_ORDERS`, `CASH_REGISTER_NAME_EXISTS`, `CASH_REGISTER_HAS_OPEN_SESSION`, `RATE_LIMIT_EXCEEDED` (429), `PAYLOAD_TOO_LARGE` (413). Nouvel avertissement : `STOCK_NEGATIVE_WARNING`. Le catalogue complet des codes est dans `ENDPOINTS-TESTABLES` §0.

## 7. Toutes les routes

« connecté » = n'importe quel utilisateur avec un jeton valide ; un rôle cité inclut les rôles au-dessus.

| Domaine | Méthode | Route | Accès | Description |
|---|---|---|---|---|
| Authentification | `POST` | `/auth/login` | public | Connexion par PIN |
| Authentification | `POST` | `/auth/refresh` | public | Renouveler les jetons |
| Authentification | `POST` | `/auth/logout` | connecté | Déconnexion |
| Authentification | `GET` | `/auth/me` | connecté | Utilisateur connecté |
| Authentification | `POST` | `/auth/override` | connecté | Autorisation ponctuelle d'un responsable |
| Utilisateurs | `GET` | `/users` | ADMIN | Lister les utilisateurs |
| Utilisateurs | `POST` | `/users` | ADMIN | Créer un utilisateur |
| Utilisateurs | `PATCH` | `/users/{user_id}` | ADMIN | Modifier un utilisateur |
| Utilisateurs | `POST` | `/users/{user_id}/pin` | ADMIN | Réinitialiser le PIN d'un utilisateur |
| Catalogue | `GET` | `/categories` | connecté | Lister les catégories |
| Catalogue | `POST` | `/categories` | RESPONSABLE | Créer une catégorie |
| Catalogue | `PATCH` | `/categories/{category_id}` | RESPONSABLE | Modifier une catégorie |
| Catalogue | `DELETE` | `/categories/{category_id}` | RESPONSABLE | Désactiver une catégorie |
| Catalogue | `GET` | `/products` | connecté | Lister les produits |
| Catalogue | `GET` | `/products/{product_id}` | connecté | Détail d'un produit |
| Catalogue | `POST` | `/products` | RESPONSABLE | Créer un produit |
| Catalogue | `PATCH` | `/products/{product_id}` | RESPONSABLE | Modifier un produit |
| Catalogue | `PATCH` | `/products/{product_id}/price` | RESPONSABLE | Changer le prix |
| Catalogue | `GET` | `/products/{product_id}/price-history` | RESPONSABLE | Historique des prix |
| Catalogue | `POST` | `/products/custom` | connecté | Créer un article libre |
| Tables | `GET` | `/tables` | connecté | Lister les tables |
| Tables | `GET` | `/tables/board` | connecté | Plan de salle (écran d'accueil) |
| Tables | `POST` | `/tables` | ADMIN | Créer une table |
| Tables | `PATCH` | `/tables/{table_id}` | ADMIN | Modifier une table |
| Tables | `DELETE` | `/tables/{table_id}` | ADMIN | Désactiver une table |
| Sessions de caisse | `GET` | `/cash-sessions/current` | connecté | Session ouverte sur ce poste |
| Sessions de caisse | `POST` | `/cash-sessions` | connecté | Ouvrir une session de caisse |
| Sessions de caisse | `GET` | `/cash-sessions/{session_id}/x-report` | connecté | Rapport X (lecture seule) |
| Sessions de caisse | `POST` | `/cash-sessions/{session_id}/close` | connecté | Clôturer la session (Z) |
| Sessions de caisse | `GET` | `/cash-sessions/{session_id}/z-report` | connecté | Rapport Z figé |
| Sessions de caisse | `POST` | `/cash-sessions/{session_id}/z-report/reprint` | connecté | Ré-imprimer le ticket Z |
| Sessions de caisse | `GET` | `/cash-sessions` | RESPONSABLE | Historique des sessions |
| Sessions de caisse | `POST` | `/cash-sessions/{session_id}/movements` | connecté | Entrée ou sortie de tiroir |
| Commandes | `POST` | `/orders` | connecté | Créer une commande |
| Commandes | `GET` | `/orders` | connecté | Lister les commandes |
| Commandes | `GET` | `/orders/{order_id}` | connecté | Détail d'une commande |
| Commandes | `POST` | `/orders/{order_id}/items` | connecté | Ajouter une ligne |
| Commandes | `PATCH` | `/orders/{order_id}/items/{item_id}` | connecté | Modifier une ligne |
| Commandes | `DELETE` | `/orders/{order_id}/items/{item_id}` | connecté | Retirer une ligne |
| Commandes | `POST` | `/orders/{order_id}/cancel` | connecté | Annuler une commande |
| Commandes | `POST` | `/orders/{order_id}/reprint` | connecté | Ré-imprimer le ticket |
| Paiements | `GET` | `/payment-methods` | connecté | Moyens de paiement |
| Paiements | `POST` | `/orders/{order_id}/payments` | connecté | Encaisser un paiement |
| Paiements | `DELETE` | `/orders/{order_id}/payments/{payment_id}` | connecté | Annuler un paiement |
| Stock | `GET` | `/stock/articles` | RESPONSABLE | Lister les articles |
| Stock | `POST` | `/stock/articles` | RESPONSABLE | Créer un article |
| Stock | `GET` | `/stock/articles/{article_id}` | RESPONSABLE | Détail d'un article |
| Stock | `PATCH` | `/stock/articles/{article_id}` | RESPONSABLE | Modifier un article |
| Stock | `POST` | `/stock/receipts` | RESPONSABLE | Entrée de stock (achat) |
| Stock | `POST` | `/stock/losses` | RESPONSABLE | Déclarer une perte |
| Stock | `POST` | `/stock/counts` | RESPONSABLE | Saisir un inventaire |
| Stock | `GET` | `/stock/movements` | RESPONSABLE | Journal des mouvements |
| Stock | `GET` | `/products/{product_id}/components` | RESPONSABLE | Fiche technique d'un plat |
| Stock | `PUT` | `/products/{product_id}/components` | RESPONSABLE | Remplacer la fiche technique d'un plat |
| Tableaux de bord | `GET` | `/reports/dashboard` | RESPONSABLE | Tableau de bord du jour |
| Tableaux de bord | `GET` | `/reports/sales` | ADMIN | Tableau des ventes |
| Tableaux de bord | `GET` | `/reports/stock` | ADMIN | Tableau du stock |
| Paramètres et caisses | `GET` | `/settings` | connecté | Paramètres de l'établissement |
| Paramètres et caisses | `PUT` | `/settings` | ADMIN | Modifier les paramètres |
| Paramètres et caisses | `GET` | `/cash-registers` | connecté | Lister les caisses |
| Paramètres et caisses | `POST` | `/cash-registers` | ADMIN | Créer une caisse |
| Paramètres et caisses | `PATCH` | `/cash-registers/{register_id}` | ADMIN | Modifier une caisse |
| Clients entreprise | `GET` | `/customers` | connecté | Rechercher un client entreprise |
| Clients entreprise | `GET` | `/customers/{customer_id}` | connecté | Détail d'un client |
| Clients entreprise | `POST` | `/customers` | connecté | Créer un client entreprise |
| FNE | `POST` | `/orders/{order_id}/fne` | connecté | Émettre la FNE d'une commande soldée |
| FNE | `GET` | `/orders/{order_id}/fne` | connecté | FNE d'une commande |
| FNE | `GET` | `/fne/documents` | RESPONSABLE | Documents FNE (suivi) |
| FNE | `GET` | `/fne/documents/export` | RESPONSABLE | Exporter les documents FNE (CSV) |
| FNE | `POST` | `/fne/documents/{document_id}/retry` | RESPONSABLE | Renvoyer un document FNE |
| FNE | `POST` | `/fne/documents/{document_id}/resolve` | RESPONSABLE | Trancher un document FNE incertain |
| FNE | `POST` | `/fne/documents/{document_id}/refund` | RESPONSABLE | Émettre un avoir FNE |
| FNE | `GET` | `/fne/documents/{document_id}/duplicate` | connecté | Duplicata d'une FNE certifiée |
| FNE | `GET` | `/fne/pending-count` | connecté | Compteur de la barre d'état |
| FNE | `GET` | `/fne/daily-summary` | RESPONSABLE | Récapitulatif fiscal d'une journée |
| Impression | `GET` | `/printing/status` | connecté | État de l'impression |
| Impression | `POST` | `/printing/open-drawer` | RESPONSABLE | Ouverture manuelle du tiroir |
| Impression | `GET` | `/printing/jobs` | connecté | File d'impression |
| Impression | `POST` | `/printing/jobs/{job_id}/retry` | connecté | Rejeu d'un travail d'impression |
| Impression | `POST` | `/printing/test` | ADMIN | Ticket de test |

`GET /health` et `GET /health/ready` (public) : l'API répond ; la base, l'imprimante et les files sont joignables.

## 8. Parcours de test rapide

Avec un jeton par rôle (CAISSIER, RESPONSABLE, ADMIN) et `X-Device-Id: poste-1` :

1. **Caisse** (CAISSIER) : `GET /cash-registers` → `POST /cash-sessions` `{"cash_register_id": "<id>", "opening_float_xof": 20000}` + `Idempotency-Key`.
2. **Commande** : `GET /tables/board` → `POST /orders` `{"table_id": "<table>"}` → `POST /orders/{id}/items` `{"product_id": "<Plat bœuf>", "quantity": 2}`.
3. **Partage** : `POST /orders` sur la même table → `409` ; avec `"allow_multiple": true` → « Note 2 » ; `GET /tables/board` montre les deux commandes.
4. **Encaissement** : `POST /orders/{id}/payments` `{"method": "MOBILE_MONEY", "provider": "WAVE", "amount_xof": 6000}` (2 « Plat bœuf » à 3 000) + `Idempotency-Key` → `PAID`, ticket « Wave ».
5. **Stock** (RESPONSABLE) : `GET /stock/articles?search=bœuf` → 0,4 kg de moins. Annuler le paiement (`DELETE /orders/{id}/payments/{payment_id}?reason=test`) → le bœuf revient.
6. **Saisies** (RESPONSABLE) : `POST /stock/receipts`, `POST /stock/counts`, `POST /stock/losses` (chacune avec sa clé).
7. **Catalogue** (RESPONSABLE) : `PATCH /products/{id}/price` `{"price_xof": 3500, "reason": "test"}` → `GET /products/{id}/price-history`.
8. **Tableaux** : `GET /reports/dashboard` (RESPONSABLE) ; `GET /reports/sales` et `GET /reports/stock` (ADMIN).
9. **Clôture** (CAISSIER) : solder ou annuler les commandes ouvertes → `POST /cash-sessions/{id}/close` `{"counted_breakdown": {"10000": 2}}` + `Idempotency-Key` → `POST /cash-sessions/{id}/z-report/reprint`.

Le parcours détaillé, avec les réponses attendues, est dans [`CIRCUIT-TEST-SWAGGER.md`](CIRCUIT-TEST-SWAGGER.md) et dans `ENDPOINTS-TESTABLES` §14 (en curl).

## 9. Ce qui n'existe pas encore

| Sujet | Où en est-on |
|---|---|
| Temps réel (WebSocket) | Phase 2 du contrat. En attendant, rafraîchir `GET /tables/board` |
| Rejeu automatique d'un ticket | Volontairement absent (risque de double ticket) : les tickets attendent en file le retour de l'agent ; un échec (`FAILED`) se rejoue à la main, `POST /printing/jobs/{id}/retry`. La FNE, elle, repart seule (`QUEUED`) |
| Remboursement d'une commande soldée | `POST /orders/{id}/refunds`, reporté (rare au restaurant) |
| Journal d'audit | `GET /reports/audit`, à venir |
| Agent d'impression pour Windows | Écrit (spouleur Windows, Xprinter 58 mm) ; reste à le valider sur le terminal du restaurant. Tickets sur 32 caractères |

## 10. Déployer le front sur la recette

Le build est servi par Nginx depuis `/opt/caisse/front-dist/` sur le serveur ; `/api/` et `/docs` sont relayés vers le backend.

**Accès** : ton compte SSH sur le serveur (`<compte>` ci-dessous), avec le droit d'écrire dans `/opt/caisse/front-dist`. **N'écrire que dans ce dossier** : le serveur héberge d'autres projets, et `rsync --delete` vers un mauvais chemin les effacerait.

```bash
# 1. Build avec l'API en relatif (exemple Vite) — .env.production : VITE_API_BASE_URL=/api/v1
npm run build                                          # → dist/

# 2. Remplacer le contenu de front-dist (--delete retire les anciens fichiers)
rsync -avz --delete dist/ <compte>@162.215.172.50:/opt/caisse/front-dist/

# 3. Rien à redémarrer : les nouveaux fichiers sont servis immédiatement
```

Sans `rsync` : `ssh <compte>@162.215.172.50 "rm -rf /opt/caisse/front-dist/*"` puis `scp -r dist/* <compte>@162.215.172.50:/opt/caisse/front-dist/`.

Ce que le serveur attend du build :

| Règle | Pourquoi |
|---|---|
| `index.html` à la racine de `dist/` | Toute route inconnue (`/caisse`, `/admin/…`) renvoie `index.html` : le routage côté client fonctionne, rechargement compris |
| Fichiers du build dans `assets/`, avec une empreinte dans le nom (`index-a1b2c3.js`, défaut de Vite) | `assets/` est mis en cache un an ; `index.html` jamais : un nouveau build est pris dès le rechargement |
| **Aucune ressource chargée depuis un CDN** (Google Fonts, `cdn.jsdelivr.net`, `unpkg.com`, icônes…) : tout dans le build (`npm install` + import) | Certains réseaux d'Abidjan n'atteignent pas ces CDN : constaté le 20/10/2026 sur Swagger (page blanche). La caisse doit s'afficher même ainsi |
| Pas d'URL absolue de l'API dans le build | Le même build doit marcher sur la recette puis en production (`https://gestion.…`) |

