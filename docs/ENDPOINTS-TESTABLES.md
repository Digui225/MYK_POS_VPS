# Endpoints testables — état au 20/10/2026

Ce document décrit les **routes réellement implémentées** dans `caisse-backend`, telles que le code les expose aujourd'hui. Le contrat cible complet est dans [`03-CONTRAT-API.md`](../../projet_caisse_MYK/03-CONTRAT-API.md). Toute route du contrat absente d'ici renvoie `404 NOT_FOUND`.

**Pour le front** : commencer par [`GUIDE-FRONT.md`](GUIDE-FRONT.md) (règles de travail, conventions, correspondance avec la branche `aziz`, routes par écran).

## Nouveautés du 20/10/2026 — impression tirée par le terminal (caisse en ligne)

L'API tourne désormais sur un serveur distant, qui ne peut pas joindre l'imprimante du restaurant. **C'est l'agent du terminal qui vient chercher les tickets** : l'API les met en file, l'agent les prend toutes les ~2 s, imprime, puis rend le résultat.

| Sujet | Ce qui change pour le front | Où |
|---|---|---|
| **Ticket à l'encaissement** | `receipt.status` vaut toujours `QUEUED` et `receipt.drawer_opened` toujours `null` : la réponse n'attend plus l'imprimante. Pour afficher « ticket imprimé » ou une alerte, suivre `GET /printing/jobs/{print_job_id}` (`DONE`, `FAILED`). Le tiroir s'ouvre quand l'agent imprime le ticket, en général sous 2 s. | [§8](#8-paiements), [§10](#10-impression) |
| **Nouvelle route** | `GET /printing/jobs/{id}` : suivi d'un travail. | [§10](#10-impression) |
| **Tiroir et ticket de test** | `POST /printing/open-drawer` et `POST /printing/test` répondent `202` avec le travail mis en file (au lieu de `200 {drawer_opened}` / `{printed}`). `503 PRINT_AGENT_UNAVAILABLE` si aucun agent ne s'est signalé depuis 15 s. | [§10](#10-impression) |
| **Rejeu** | `POST /printing/jobs/{id}/retry` remet le travail en file (`QUEUED`) au lieu d'imprimer sur-le-champ. Accepté pour `FAILED`, et pour `PRINTING` resté sans résultat plus de 2 min. | [§10](#10-impression) |
| **État de l'agent** | `agent_online` : un agent s'est signalé depuis moins de 15 s. Nouveau champ `agent_last_seen_at`. | [§10](#10-impression) |
| **Terminaux (ADMIN)** | `GET/POST /printing/terminals`, `POST /printing/terminals/{id}/revoke` : jeton de l'agent, distinct des PIN, affiché une seule fois. | [§10](#10-impression) |
| **Nouveaux codes d'erreur** | `PRINT_TERMINAL_NAME_EXISTS`, `TERMINAL_TOKEN_INVALID`, `PRINT_JOB_NOT_CLAIMED` (ces deux derniers ne concernent que l'agent). | [§0 Erreurs](#format-des-erreurs-applicationproblemjson) |

## Nouveautés du 16/10/2026 — reprise de la branche `aziz`

Les fonctions développées sur la branche `aziz` sont reprises ici **sous les routes de ce document** (contrat `03-CONTRAT-API.md`). Le front s'aligne sur ces routes, pas sur celles de la branche `aziz`.

| Sujet | Ce qui change pour le front | Où |
|---|---|---|
| **Gestion du catalogue** | `POST /categories`, `PATCH/DELETE /categories/{id}`, `POST /products`, `GET/PATCH /products/{id}`, `PATCH /products/{id}/price` (motif obligatoire, historisé), `GET /products/{id}/price-history`. Rôle RESPONSABLE. **Chez aziz** : `/catalog/categories`, `/catalog/products`, `/catalog/products/{id}/price` avec `new_price_xof` → ici `/categories`, `/products`, `/products/{id}/price` avec `price_xof`. `GET /categories` accepte `is_active`. | [§4](#4-catalogue) |
| **Tables** | `POST /tables`, `PATCH/DELETE /tables/{id}` (ADMIN, suppression logique), `GET /tables?is_active=`. **Chez aziz** : `DELETE` renvoie un message → ici la table. | [§5](#5-tables) |
| **Paramètres et caisses** | `GET/PUT /settings` (lecture : connecté ; modification : ADMIN, seuls les champs envoyés changent) ; `GET/POST /cash-registers`, `PATCH /cash-registers/{id}`. **Chez aziz** : `/settings/registers` et un `DELETE` → ici `/cash-registers` et `PATCH {"is_active": false}`. Champs de `/settings` : mêmes noms que chez aziz pour l'établissement (`restaurant_name`, `ncc`, `rccm`, `address`, `phone`, `receipt_footer`, `default_vat_rate`, `screen_lock_timeout_seconds`), plus les moyens de paiement, les coupures et la FNE ; pas de `print_width` (réglé dans le `.env` de l'API). Ouvrir une session sur une caisse inconnue ou hors service renvoie `404` (avant : erreur 500). | [§13](#13-paramètres-et-caisses) |
| **Tableau de bord du jour** | `GET /reports/dashboard?business_date=` (RESPONSABLE) : CA, commandes soldées / ouvertes / annulées, panier moyen, couverts, à table / à emporter, tables occupées, encaissements par moyen **et opérateur**, 10 meilleures ventes, ventes par heure et par caissier, sessions, articles en alerte, FNE. **Chez aziz** : paramètre `date` et noms différents (`total_sales_ttc_xof`, `settled_orders`, `payments_by_method`, `hourly_sales`, `sales_by_cashier`…) → voir §12. | [§12](#12-tableaux-de-bord) |
| **Sécurité** | `429 RATE_LIMIT_EXCEEDED` (avec `Retry-After`) au-delà de 10 connexions ou autorisations par minute et par adresse IP (30 renouvellements) ; `413 PAYLOAD_TOO_LARGE` au-delà de 2 Mo ; en-têtes `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy` sur toutes les réponses ; **Swagger et `/openapi.json` coupés quand `APP_ENV=production`** (sauf `ENABLE_DOCS=true`) ; `ALLOWED_HOSTS` facultatif. Repris de la branche aziz, réglables dans le `.env`. | [§0 Erreurs](#format-des-erreurs-applicationproblemjson) |
| **Ticket** | Le paiement Mobile Money affiche l'opérateur (« Wave », « Orange Money », « MTN MoMo », « Moov Money ») ; l'en-tête affiche le NCC et le RCCM s'ils sont renseignés (`PUT /settings`). | [§8](#8-paiements) |
| **Duplicata du Z, export FNE, client** | `POST /cash-sessions/{id}/z-report/reprint` (**chez aziz** : `POST /cash-sessions/{id}/print-z` ou `/printing/z-report/{id}`) ; `GET /fne/documents/export` en CSV (**chez aziz** : `/fne/export`) ; `GET /customers/{id}`. `POST /fne/generate` (ancien alias chez aziz) n'est pas repris : utiliser `POST /orders/{id}/fne`. | [§6](#6-sessions-de-caisse), [§9](#9-clients-entreprise-et-fne) |
| **Partage de table** | `POST /orders` accepte `note_label` et `allow_multiple` (mêmes noms que chez aziz) ; `order.note_label` dans toutes les réponses de commande ; `GET /tables/board` ajoute `orders[]` et `total_ttc_xof` par table (**chez aziz** : `active_orders[]`, `is_occupied`) et garde `order` (la plus ancienne). Nouveau code `ORDER_LABEL_TAKEN`. Une table rouverte n'empêche plus d'annuler un paiement (`table_reoccupied` supprimé). | [§5](#5-tables), [§7](#7-commandes) |

## Nouveautés du 16/10/2026 — stock et tableaux de bord

| Sujet | Ce qui change pour le front | Où |
|---|---|---|
| **Stock (gestionnaire)** | `/stock/*` : articles de stock, entrées (achats), pertes, inventaires, journal des mouvements ; fiches techniques par produit (`GET/PUT /products/{id}/components`). Rôle RESPONSABLE. Saisies idempotentes (`Idempotency-Key`). | [§11](#11-stock) |
| **Sortie automatique** | Encaisser une commande (`PAID`) déstocke les articles des fiches techniques ; annuler un paiement qui la fait sortir de `PAID` les remet en stock. Seul changement de la réponse de paiement : `warnings[]` peut contenir `STOCK_NEGATIVE_WARNING` (non bloquant). | [§11](#11-stock) |
| **`GET /products`** (sens changé) | `track_stock` : le produit a une fiche technique ; `stock_quantity` : **portions encore vendables** (ex. 8 kg de mouton à 0,27 kg → 29), plus une quantité d'article. Mêmes noms de champs. | [§4](#4-catalogue) |
| **Tableaux de bord (M. Yapi)** | `GET /reports/sales` (chiffre d'affaires, coût matière, marges par jour, produit, catégorie, moyen de paiement, écarts de caisse) et `GET /reports/stock` (stock de début et de fin, entrées, ventes, pertes, écarts d'inventaire, alertes). Rôle ADMIN. | [§12](#12-tableaux-de-bord) |
| **Menu réel** | `import-catalog` et `import-stock` chargent le menu, les 115 articles et les 35 fiches tirés des Excel. | [§11](#charger-les-articles-et-les-fiches-du-restaurant) |
| **Nouveau code d'erreur** | `STOCK_ARTICLE_NAME_EXISTS` ; avertissement `STOCK_NEGATIVE_WARNING` (déjà au contrat) dans `warnings[]` des saisies de stock **et du paiement qui solde une commande**. | [§0 Erreurs](#format-des-erreurs-applicationproblemjson) |

## Nouveautés du 06/10/2026 — impression (ticket, tiroir)

| Sujet | Ce qui change pour le front | Où |
|---|---|---|
| **Ticket imprimé à l'encaissement** | `receipt` n'est plus toujours `null` : dès que la commande passe `PAID`, `POST /orders/{id}/payments` renvoie `receipt: {print_job_id, status, drawer_opened}`. Le tiroir s'ouvre à ce moment-là. | [§8](#8-paiements) |
| **Ticket Z imprimé à la clôture** | `print_job_id` de `POST /cash-sessions/{id}/close` et `GET /cash-sessions/{id}/z-report` n'est plus toujours `null`. N'ouvre pas le tiroir. | [§6](#6-sessions-de-caisse) |
| **Ré-impression** | `POST /orders/{id}/reprint` : réimprime le dernier ticket **tel que remis au client** (jamais ré-rendu depuis l'état courant). N'ouvre pas le tiroir, compté dans `controls.reprints` (X/Z). | [§7](#7-commandes) |
| **Nouvelle section** | `/printing/*` : état de l'agent et de la file, ouverture manuelle du tiroir, rejeu d'un travail en échec, ticket de test. | [§10](#10-impression) |
| **L'imprimante reste informative** | Une panne d'impression (agent ou imprimante hors ligne) **ne bloque jamais** une vente ni une clôture : `receipt.status` passe à `FAILED`/`QUEUED`, `drawer_opened: false`, et c'est tout — `201`/`201` comme si tout allait bien. Seules les actions directes (`/printing/open-drawer`, `/printing/test`) renvoient une erreur `503`. | [§10](#10-impression) |
| **Toujours pas là** | Impression des tickets cuisine/serveur (hors MVP), impression A4 de la FNE (gérée par le front via `qr_payload`, inchangé). | — |
| **FNE : alerte de solde** (changement de `meta`) | `FNE_STICKER_LOW` garde son code, mais se déclenche sur l'alerte renvoyée par la DGI et porte désormais `meta.balance_funds_xof` (solde prépayé en XOF, peut être `null`) au lieu de `meta.balance_sticker`. La DGI ne compte plus en stickers. | [§9](#9-clients-entreprise-et-fne) |

## Nouveautés du 02/10/2026 — encaissement (front)

| Sujet | Ce qui change pour le front | Où |
|---|---|---|
| **Encaissement disponible** | `POST /orders/{id}/payments` (idempotent, partiel ou mixte, rendu monnaie), `GET /payment-methods`, `DELETE /orders/{id}/payments/{payment_id}` (annulation d'un paiement saisi par erreur). Plus besoin de solder les commandes en base pour tester la FNE. | [§8](#8-paiements) |
| **Nouveau champ** | `order.payments[]` dans toutes les réponses de commande (paiements annulés compris, `status: VOIDED`). | [§7](#7-commandes), [§8](#8-paiements) |
| **Réponse de paiement** | `receipt` et `fiscal_document` valent **toujours `null`** : pas encore d'impression, et la FNE reste à la demande. | [§8](#8-paiements) |
| **Nouveaux codes d'erreur** | `PAYMENT_EXCEEDS_DUE` (déjà au contrat), `PAYMENT_METHOD_DISABLED`, `PAYMENT_NOT_VOIDABLE` ; `ORDER_NOT_EDITABLE` avec `meta.reason = "nothing_due"`. | [§0 Erreurs](#format-des-erreurs-applicationproblemjson) |
| **Nouvel avertissement** | `FNE_ALREADY_ISSUED` à l'annulation d'un paiement d'une commande qui a déjà une FNE. | [§8](#8-paiements) |
| **Écran d'avoir FNE** | Non prioritaire (rare au restaurant). | [§9](#9-clients-entreprise-et-fne) |
| **Pas encore là** | Remboursement d'une commande soldée (`POST /orders/{id}/refunds`) ; ticket de caisse et tiroir (`/printing/*`) : fait depuis le 06/10/2026, voir [§10](#10-impression). | [§15](#15-pas-encore-testable) |

## Nouveautés du 01/10/2026 — FNE et TVA

| Sujet | Ce qui change pour le front | Où |
|---|---|---|
| **TVA à 0 %** | Le restaurant est au **régime TEE** (confirmé) : tous les produits sont à `vat_rate: 0.0`, donc `total_ht_xof` = `total_ttc_xof` et `total_vat_xof` = 0 partout (commandes, X, Z). Prévoir de masquer la ligne « TVA » ou d'afficher la mention du régime (à valider avec le comptable). | [§0 Montants](#montants) |
| **FNE à la demande** | La FNE n'est **plus émise à l'encaissement** : écart avec le contrat v1.1 §4.6, où la réponse de paiement porte un `fiscal_document`. Dans la réponse de paiement, ce champ vaut toujours `null`. La FNE s'émet par un bouton dédié : `POST /orders/{id}/fne`. | [§9](#9-clients-entreprise-et-fne) |
| **Clients entreprise** | `GET/POST /customers` : recherche par NCC, création avec contrôle du format (7 chiffres + 1 lettre). | [§9](#9-clients-entreprise-et-fne) |
| **Nouvelle valeur d'énumération** | `FneDocument.type` : `FNE` **ou `REFUND`** (avoir). Contrat §6 : prévoir un cas par défaut. | [§9](#9-clients-entreprise-et-fne) |
| **Nouveau champ** | `is_uncertain` sur un document FNE : issue inconnue, action du responsable requise. Le statut reste `SUBMITTING` (aucune valeur de statut ajoutée). | [§9](#9-clients-entreprise-et-fne) |
| **Nouveaux codes d'erreur** | `CUSTOMER_NCC_EXISTS`, `FNE_ORDER_NOT_PAID`, `FNE_NOT_CONFIGURED`, `FNE_DOCUMENT_STATE`, `FNE_REFUND_EXCEEDS`, et les `422 FNE_*` de traduction. | [§0 Erreurs](#format-des-erreurs-applicationproblemjson) |
| **Nouveaux avertissements** | Dans `warnings[]` (HTTP 200/201) : `FNE_REJECTED` (déjà au contrat), `FNE_UNCERTAIN`, `FNE_QUEUED`, `FNE_STICKER_LOW`. | [§9](#9-clients-entreprise-et-fne) |
| **Routes ajoutées hors contrat** (non cassantes) | `GET /orders/{id}/fne`, `POST /fne/documents/{id}/resolve`, `POST /fne/documents/{id}/refund`. | [§9](#9-clients-entreprise-et-fne) |
| **Impression de la FNE** | En **A4**, pas sur le ticket 80 mm : ouvrir `qr_payload` (page de vérification de la DGI) et l'imprimer depuis le navigateur. | [§9](#9-clients-entreprise-et-fne) |

## Sommaire

| § | Section | Routes | En bref |
|---|---|---|---|
| 0 | [Conventions communes](#0-conventions-communes) | — | Adresses, en-têtes, rôles, format des erreurs et catalogue des codes |
| 1 | [Santé](#1-santé) | `GET /health`, `GET /health/ready` | L'API répond, la base et l'imprimante sont joignables |
| 2 | [Authentification](#2-authentification) | `POST /auth/login`, `POST /auth/refresh`, `POST /auth/logout`, `GET /auth/me`, `POST /auth/override` | Connexion par PIN, jetons, blocage par poste, autorisation ponctuelle d'un responsable |
| 3 | [Utilisateurs](#3-utilisateurs) | `GET /users`, `POST /users`, `PATCH /users/{id}`, `POST /users/{id}/pin` | Gestion des comptes (ADMIN) |
| 4 | [Catalogue](#4-catalogue) | `GET/POST /categories`, `PATCH/DELETE /categories/{id}`, `GET/POST /products`, `GET/PATCH /products/{id}`, `PATCH /products/{id}/price`, `GET /products/{id}/price-history`, `POST /products/custom` | Menu, gestion du catalogue (RESPONSABLE), prix historisé, article libre |
| 5 | [Tables](#5-tables) | `GET/POST /tables`, `PATCH/DELETE /tables/{id}`, `GET /tables/board` | Salle (configuration ADMIN), plan de salle avec tables partagées |
| 6 | [Sessions de caisse](#6-sessions-de-caisse) | `GET /cash-sessions/current`, `POST /cash-sessions`, `GET …/{id}/x-report`, `POST …/{id}/close`, `GET …/{id}/z-report`, `POST …/{id}/z-report/reprint`, `GET /cash-sessions`, `POST …/{id}/movements` | Ouverture, mouvements de tiroir, rapports X et Z, clôture, duplicata du Z |
| 7 | [Commandes](#7-commandes) | `POST /orders`, `GET /orders`, `GET /orders/{id}`, `POST …/{id}/items`, `PATCH …/items/{item_id}`, `DELETE …/items/{item_id}`, `POST …/{id}/cancel` | Prise de commande, lignes (ajout, quantité, retrait), annulation sous autorisation |
| 8 | [Paiements](#8-paiements) | `GET /payment-methods`, `POST /orders/{id}/payments`, `DELETE /orders/{id}/payments/{payment_id}` | Encaissement partiel ou mixte, rendu monnaie, annulation d'un paiement |
| 9 | [Clients entreprise et FNE](#9-clients-entreprise-et-fne) | `GET/POST /customers`, `GET /customers/{id}`, `POST/GET /orders/{id}/fne`, `GET /fne/documents`, `GET /fne/documents/export`, `POST …/{id}/retry`, `POST …/{id}/resolve`, `POST …/{id}/refund`, `GET …/{id}/duplicate`, `GET /fne/pending-count`, `GET /fne/daily-summary` | Facture normalisée DGI à la demande, avoirs, suivi |
| 10 | [Impression](#10-impression) | `GET /printing/status`, `POST /printing/open-drawer`, `GET /printing/jobs`, `POST …/{id}/retry`, `POST /printing/test` | État de l'agent et de la file, actions directes |
| 11 | [Stock](#11-stock) | `GET/POST /stock/articles`, `GET/PATCH /stock/articles/{id}`, `POST /stock/receipts`, `POST /stock/losses`, `POST /stock/counts`, `GET /stock/movements`, `GET/PUT /products/{id}/components` | Articles, entrées, pertes, inventaires, fiches techniques (RESPONSABLE) |
| 12 | [Tableaux de bord](#12-tableaux-de-bord) | `GET /reports/dashboard`, `GET /reports/sales`, `GET /reports/stock` | Journée en cours (RESPONSABLE) ; ventes et stock sur une période (ADMIN) |
| 13 | [Paramètres et caisses](#13-paramètres-et-caisses) | `GET/PUT /settings`, `GET/POST /cash-registers`, `PATCH /cash-registers/{id}` | Établissement, ticket, TVA, moyens de paiement, FNE ; caisses (ADMIN) |
| 14 | [Scénario de test complet](#14-scénario-de-test-complet-curl--jq) | — | Tout le parcours en curl, de la connexion à la clôture |
| 15 | [Pas encore testable](#15-pas-encore-testable) | — | Routes du contrat pas encore implémentées |

**Par où commencer :**

1. Préparer la base avec `docker compose exec api python -m caisse.cli …` : `bootstrap` (caisse n° 1), `create-user` (un ADMIN), `seed --demo` (menu + 15 tables).
2. Ouvrir Swagger (http://localhost:8001/docs), se connecter avec `POST /auth/login`, coller l'`access_token` dans **Authorize**.
   Pour le menu réel du restaurant avec son stock : `import-catalog` puis `import-stock --stock-initial` (§11).
3. Suivre le parcours d'une journée : ouvrir la caisse (§6) → prendre des commandes (§7) → encaisser (§8) → clôturer (§6). Le [§14](#14-scénario-de-test-complet-curl--jq) fait la même chose en curl.

---

## 0. Conventions communes

### Adresses

| | |
|---|---|
| API (Docker) | `http://localhost:8001` |
| Préfixe métier | `/api/v1` |
| Swagger | http://localhost:8001/docs (bouton **Authorize** → coller l'`access_token`) |
| OpenAPI brut | http://localhost:8001/openapi.json |

### En-têtes

| En-tête | Sens | Rôle |
|---|---|---|
| `Authorization: Bearer <access_token>` | requête | Obligatoire sur toutes les routes marquées « connecté » ou « ADMIN » |
| `X-Device-Id` | requête | Facultatif. Identifie le poste pour la temporisation des PIN (`/auth/override`) et pour l'audit. Sans lui, le poste est compté comme `unknown`. |
| `X-Request-Id` | requête / réponse | Facultatif en entrée. Toujours renvoyé en sortie, généré s'il est absent. Il apparaît dans les logs et dans les erreurs. |
| `X-Override-Token` | requête | Jeton obtenu par `POST /auth/override`. Permet à un CAISSIER d'annuler une commande (action `order.cancel`). Inutile pour un RESPONSABLE ou un ADMIN. |
| `Idempotency-Key` | requête | **Obligatoire** sur `POST /cash-sessions` et `POST /cash-sessions/{id}/close`. Rejouer la même clé avec le même corps renvoie la réponse d'origine en `200`, avec l'en-tête `Idempotent-Replay: true` en retour. |

### Rôles

Hiérarchie : `CAISSIER < RESPONSABLE < ADMIN`. Un rôle hérite des droits des rôles inférieurs.

| Mention dans ce document | Signification |
|---|---|
| **public** | Aucun jeton |
| **connecté** | N'importe quel utilisateur actif avec un `access_token` valide |
| **RESPONSABLE** | Rôle RESPONSABLE ou ADMIN, sinon `403 INSUFFICIENT_PRIVILEGE` |
| **ADMIN** | Rôle ADMIN obligatoire, sinon `403 INSUFFICIENT_PRIVILEGE` |

### Durées de vie (valeurs du `.env`)

| Élément | Durée |
|---|---|
| `access_token` | 15 min (`ACCESS_TOKEN_TTL_MINUTES`) |
| `refresh_token` | 12 h (`REFRESH_TOKEN_TTL_HOURS`) |
| Jeton d'override | 60 s, usage unique |

### Listes

Les listes renvoient `{"items": [...], "next_cursor": null}`. Il n'y a **pas encore de pagination** : `next_cursor` est toujours `null` et tout est renvoyé en une fois.

### Montants

Tous les montants sont des **entiers en XOF** (`price_xof`, `total_ttc_xof`…). Seuls `vat_rate` et `stock_quantity` sont des nombres décimaux.

**TVA :** le restaurant est au **régime TEE** (confirmé le 01/10/2026) : les produits sont à **0 %**, donc `total_ht_xof` = `total_ttc_xof` et `total_vat_xof` = 0. Le taux par défaut est le paramètre `vat.default_rate` ; `python -m caisse.cli set-vat-rate 0 --all-products` l'applique à une base existante.

### Format des erreurs (`application/problem+json`)

```json
{
  "type": "https://caisse.local/errors/invalid-credentials",
  "title": "Code PIN invalide",
  "status": 401,
  "code": "INVALID_CREDENTIALS",
  "detail": "Code PIN invalide",
  "meta": { "remaining_attempts": 3 },
  "request_id": "9f1c…"
}
```

Le front doit se fier à **`code`**, qui est stable. `title` et `detail` sont des textes lisibles qui peuvent changer.

| Code | HTTP | Quand |
|---|---|---|
| `VALIDATION_ERROR` | 422 | Corps ou paramètre mal formé. `meta.fields` liste les champs en cause. |
| `TOKEN_EXPIRED` | 401 | Jeton absent, expiré, invalide, du mauvais type, ou utilisateur désactivé |
| `INVALID_CREDENTIALS` | 401 | PIN inconnu |
| `ACCOUNT_LOCKED` | 423 | Poste temporairement bloqué après trop de PIN faux |
| `INSUFFICIENT_PRIVILEGE` | 403 | Rôle trop faible pour la route |
| `OVERRIDE_REQUIRED` | 403 | Le PIN saisi pour un override n'a pas le rôle requis |
| `NOT_FOUND` | 404 | Ressource ou route inexistante |
| `PIN_ALREADY_USED` | 409 | PIN déjà attribué à un autre utilisateur actif |
| `NO_OPEN_SESSION` | 409 | Aucune session de caisse ouverte, ou mouvement demandé sur une session déjà clôturée |
| `SESSION_ALREADY_OPEN` | 409 | Une session est déjà ouverte sur cette caisse |
| `SESSION_ALREADY_CLOSED` | 409 | La session visée est déjà clôturée |
| `SESSION_NOT_CLOSED` | 409 | Rapport Z demandé avant la clôture |
| `SESSION_HAS_OPEN_ORDERS` | 409 | Clôture refusée : des commandes ne sont pas soldées (`meta.open_orders[]`) |
| `BUSINESS_DATE_MISMATCH` | 409 | Une session clôturée existe déjà pour cette journée comptable ; rejouer avec `confirm_business_date: true` |
| `IDEMPOTENCY_CONFLICT` | 409 | Même `Idempotency-Key`, corps différent |
| `TABLE_ALREADY_OCCUPIED` | 409 | La table porte déjà une commande active (`meta.order_id` : la plus ancienne, à ouvrir) ; renvoyer avec `allow_multiple: true` pour partager la table |
| `ORDER_NOT_EDITABLE` | 409 | Commande soldée ou annulée (`meta.status`), modification qui ferait passer le total sous le montant déjà encaissé, ou paiement sans reste dû (`meta.reason = "nothing_due"`) |
| `PAYMENT_EXCEEDS_DUE` | 422 | Montant supérieur au reste dû (`meta.due_xof`, `meta.amount_xof`) |
| `PAYMENT_METHOD_DISABLED` | 422 | Moyen de paiement non proposé par la caisse (`payments.methods`) |
| `PAYMENT_NOT_VOIDABLE` | 409 | Paiement impossible à annuler (`meta.reason`) |
| `CUSTOMER_NCC_EXISTS` | 409 | NCC déjà enregistré (`meta.customer_id` : client à réutiliser) |
| `FNE_ORDER_NOT_PAID` | 409 | FNE demandée sur une commande non soldée |
| `FNE_NOT_CONFIGURED` | 409 | Paramètres `fne.point_of_sale` / `fne.establishment` vides (`meta.missing_settings`) |
| `FNE_DOCUMENT_STATE` | 409 | Action interdite dans l'état du document FNE (`meta.reason`) |
| `FNE_CUSTOMER_REQUIRED`, `FNE_NCC_REQUIRED`, `FNE_NO_PAYMENT`, `FNE_VAT_RATE_UNMAPPED`, `FNE_PAYMENT_METHOD_UNMAPPED`, `FNE_FIELD_REQUIRED` | 422 | Commande impossible à traduire en FNE (client, NCC, paiement, taux de TVA, client de passage non paramétré) |
| `FNE_REFUND_EXCEEDS` | 422 | Avoir supérieur à la quantité certifiée restante (`meta.available`) |
| `NO_RECEIPT_TO_REPRINT` | 409 | `POST /orders/{id}/reprint` sur une commande sans ticket déjà imprimé |
| `CATEGORY_NAME_EXISTS` | 409 | Catégorie déjà existante sous ce nom, sans la casse (`meta.category_id`) |
| `CATEGORY_NOT_EMPTY` | 409 | Désactivation d'une catégorie qui a des produits actifs (`meta.active_products`) |
| `ORDER_LABEL_TAKEN` | 409 | Étiquette déjà portée par une commande active de la table (`meta.order_id`) |
| `CASH_REGISTER_NAME_EXISTS` | 409 | Caisse déjà existante sous ce nom (`meta.cash_register_id`) |
| `CASH_REGISTER_HAS_OPEN_SESSION` | 409 | Désactivation d'une caisse dont une session est ouverte (`meta.session_id`) |
| `TABLE_LABEL_EXISTS` | 409 | Table déjà existante sous ce libellé (`meta.table_id`) |
| `TABLE_HAS_ACTIVE_ORDERS` | 409 | Désactivation d'une table qui porte des commandes en cours (`meta.order_ids`) |
| `PRODUCT_NAME_EXISTS` | 409 | Produit du menu déjà existant sous ce nom (`meta.product_id`) |
| `PRODUCT_SKU_EXISTS` | 409 | Code article (`sku`) déjà utilisé |
| `STOCK_ARTICLE_NAME_EXISTS` | 409 | Article de stock déjà existant sous ce nom, sans tenir compte de la casse (`meta.article_id`) |
| `PRINT_JOB_NOT_RETRYABLE` | 409 | `POST /printing/jobs/{id}/retry` sur un travail déjà `DONE`, déjà en file (`QUEUED`) ou pris à l'instant par l'agent |
| `PRINTER_UNAVAILABLE` | 503 | Action directe (`/printing/open-drawer`, `/printing/test`) : l'agent se signale, mais rapporte l'imprimante hors ligne. **Jamais** renvoyé par `/orders/{id}/payments` ou `/cash-sessions/{id}/close` : voir [§10](#10-impression). |
| `PRINT_AGENT_UNAVAILABLE` | 503 | Action directe : aucun agent ne s'est signalé depuis 15 s. Mêmes réserves que ci-dessus. |
| `PRINT_TERMINAL_NAME_EXISTS` | 409 | `POST /printing/terminals` : un terminal porte déjà ce nom |
| `TERMINAL_TOKEN_INVALID` | 401 | Routes de l'agent (`/print-agent/*`) : jeton absent, inconnu ou révoqué |
| `PRINT_JOB_NOT_CLAIMED` | 409 | Agent : résultat d'un travail qu'il n'a pas (ou plus) en main |
| `RATE_LIMIT_EXCEEDED` | 429 | Trop de requêtes depuis la même adresse IP sur `/auth/login`, `/auth/override` (10 par minute) ou `/auth/refresh` (30 par minute). En-tête `Retry-After` et `meta.retry_after` (secondes) |
| `PAYLOAD_TOO_LARGE` | 413 | Corps de requête de plus de 2 Mo (`meta.max_bytes`) |
| `INTERNAL_ERROR` | 500 | Erreur imprévue. La trace est dans les logs, jamais dans la réponse. |

---

## 1. Santé

### `GET /health` — le processus répond

**Accès** : public · **Aussi servie sous** `/api/v1/health`

Réponse `200` :

```json
{ "status": "ok" }
```

Utilisée par le healthcheck Docker et par le bandeau de connexion du front.

### `GET /health/ready` — l'API est prête à vendre

**Accès** : public · **Aussi servie sous** `/api/v1/health/ready`

Réponse `200` :

```json
{
  "status": "ok",
  "database": "ok",
  "queues": { "print_queued": 0, "print_failed": 0, "fne_pending": 0 },
  "printer": { "agent_online": false, "printer_online": false, "paper": null }
}
```

| Cas | Réponse |
|---|---|
| Base injoignable | `503` avec `"status": "unavailable"`, `"database": "unreachable"` et sans `queues` |
| Agent d'impression arrêté | **Toujours `200`.** L'imprimante n'est qu'informative : `agent_online: false` quand aucun agent ne s'est signalé depuis 15 s. |

À tester :
- lancer l'agent en mode factice (`print-agent/README.md`) et vérifier que `agent_online` passe à `true` ;
- arrêter `infra-db` et vérifier la réponse `503`.

```bash
curl -s localhost:8001/health/ready | jq
```

---

## 2. Authentification

Préfixe : `/api/v1/auth`.

### `POST /auth/login` — connexion par PIN

**Accès** : public

Corps :

| Champ | Type | Contraintes |
|---|---|---|
| `pin` | chaîne | 4 à 8 chiffres (`^\d{4,8}$`). En pratique, les PIN créés font 6 chiffres. |
| `device_id` | chaîne | 1 à 64 caractères. Identifie le poste pour la temporisation. |

```json
{ "pin": "482913", "device_id": "poste-1" }
```

Réponse `200` :

```json
{
  "access_token": "eyJhbGciOi…",
  "refresh_token": "eyJhbGciOi…",
  "token_type": "bearer",
  "expires_in": 900,
  "user": { "id": "2b7c…", "full_name": "Isaac", "role": "ADMIN" },
  "open_session": null
}
```

`open_session` vaut `{id, business_date, cash_register_id}` si une session de caisse est ouverte (voir [§6](#6-sessions-de-caisse)), `null` sinon.

Erreurs :

| Code | Cas | `meta` |
|---|---|---|
| `422 VALIDATION_ERROR` | PIN non numérique ou hors 4–8 chiffres, `device_id` absent. **Ne compte pas comme un essai.** | `fields` |
| `401 INVALID_CREDENTIALS` | PIN inconnu, ou PIN d'un utilisateur désactivé | `remaining_attempts` |
| `423 ACCOUNT_LOCKED` | Le poste (`device_id`) est bloqué | `locked_until` (ISO 8601, UTC) |

**Blocage progressif, par poste et non par utilisateur :**

| Échec n° | Effet |
|---|---|
| 1 à 4 | `401`, avec `remaining_attempts` de 4 à 1 |
| 5 | `423`, poste bloqué 30 s |
| 6 (après déblocage) | `423`, bloqué 60 s |
| 7, 8… | La durée double à chaque fois, **jusqu'à 15 min au plus** |
| Connexion réussie | Le compteur du poste revient à 0 |

Pendant le blocage, toute tentative renvoie `423` **sans être comptée**, même avec le bon PIN.

**Limite par adresse IP**, en plus : 10 tentatives par minute sur `/auth/login` (et `/auth/override`), réussies ou non, quel que soit le poste annoncé ; au-delà, `429 RATE_LIMIT_EXCEEDED` avec l'en-tête `Retry-After`. Réglable dans le `.env` (`LOGIN_RATE_LIMIT_PER_MINUTE`, `REFRESH_RATE_LIMIT_PER_MINUTE` pour `/auth/refresh`, 30 par défaut).

À tester :
- bon PIN → `200` ;
- 5 PIN faux sur `poste-test` → `423` au 5ᵉ essai ;
- pendant le blocage, se connecter avec le bon PIN sur `poste-1` → `200` (le blocage est limité au poste) ;
- PIN `"12ab"` → `422`, et le compteur ne bouge pas.

```bash
curl -s -X POST localhost:8001/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"pin":"482913","device_id":"poste-1"}' | jq
```

Traces dans `audit_logs` : `auth.login` en cas de succès, `auth.login_failed` en cas d'échec.

### `POST /auth/refresh` — renouveler les jetons

**Accès** : public (le `refresh_token` suffit)

Corps :

```json
{ "refresh_token": "eyJhbGciOi…" }
```

Réponse `200` : même format que `/auth/login`, avec une **nouvelle paire** de jetons.

**Rotation** : le `refresh_token` envoyé est révoqué à l'instant où le nouveau est émis.

| Code | Cas |
|---|---|
| `401 TOKEN_EXPIRED` | Jeton expiré ou falsifié, déjà utilisé une fois, révoqué par `/logout`, utilisateur désactivé entre-temps, ou `access_token` envoyé à la place (`detail: "Type de jeton inattendu"`) |

À tester :
- rafraîchir → `200` ;
- **rejouer le même** `refresh_token` → `401` ;
- envoyer l'`access_token` dans `refresh_token` → `401`.

### `POST /auth/logout` — déconnexion

**Accès** : connecté

Corps :

```json
{ "refresh_token": "eyJhbGciOi…" }
```

Réponse : `204`, sans corps.

- Révoque le `refresh_token` s'il appartient bien à l'utilisateur connecté.
- Renvoie `204` même si le `refresh_token` est déjà invalide : la déconnexion ne doit jamais échouer côté caisse.
- **L'`access_token` reste utilisable jusqu'à son expiration (15 min au plus).** Il n'est pas stocké côté serveur, c'est le front qui doit l'oublier.

À tester : après `/logout`, un `/auth/refresh` avec ce même jeton renvoie `401`.

Trace dans `audit_logs` : `auth.logout`.

### `GET /auth/me` — utilisateur courant

**Accès** : connecté

Réponse `200` :

```json
{
  "user": { "id": "2b7c…", "full_name": "Isaac", "role": "ADMIN" },
  "open_session": null
}
```

`open_session` reflète la session de caisse ouverte, comme sur `/auth/login` (voir [§6](#6-sessions-de-caisse)).

| Code | Cas |
|---|---|
| `401 TOKEN_EXPIRED` | Pas d'en-tête `Authorization` (`detail: "Authentification requise"`), jeton expiré ou utilisateur désactivé |

```bash
curl -s localhost:8001/api/v1/auth/me -H "Authorization: Bearer $TOKEN" | jq
```

### `POST /auth/override` — autorisation ponctuelle d'un responsable

**Accès** : connecté. C'est l'utilisateur **demandeur** qui est connecté, par exemple le caissier.

Un responsable tape son PIN sur le poste du caissier. L'API renvoie un jeton valable 60 s, utilisable une seule fois, lié à une action précise et au demandeur.

En-tête conseillé : `X-Device-Id`. Les PIN faux saisis ici comptent dans le blocage de ce poste.

Corps :

| Champ | Type | Contraintes |
|---|---|---|
| `pin` | chaîne | PIN du responsable, 4 à 8 chiffres |
| `action` | chaîne | 1 à 64 caractères, par ex. `order.cancel` |
| `required_role` | `RESPONSABLE` \| `ADMIN` \| `CAISSIER` | Facultatif, `RESPONSABLE` par défaut |

```json
{ "pin": "654321", "action": "order.cancel", "required_role": "RESPONSABLE" }
```

Réponse `200` :

```json
{
  "override_token": "eyJhbGciOi…",
  "expires_in": 60,
  "granted_by": { "id": "8e1a…", "full_name": "Responsable", "role": "RESPONSABLE" }
}
```

| Code | Cas | `meta` |
|---|---|---|
| `401 INVALID_CREDENTIALS` | PIN inconnu | `remaining_attempts` |
| `423 ACCOUNT_LOCKED` | Poste bloqué | `locked_until` |
| `403 OVERRIDE_REQUIRED` | PIN valide mais rôle insuffisant, par ex. un PIN de caissier | `required_role` |
| `401 TOKEN_EXPIRED` | Demandeur non connecté |  |

Le jeton se consomme dans l'en-tête `X-Override-Token` de `POST /orders/{id}/cancel` (action `order.cancel`), voir [§7](#7-commandes). Il est refusé (`403 OVERRIDE_REQUIRED`, `meta.reason`) s'il est expiré, déjà utilisé, demandé pour une autre action ou par un autre utilisateur.

> Rien n'empêche un responsable de s'autoriser lui-même : avec le seul compte ADMIN, on peut donc tester le cas nominal.

Trace dans `audit_logs` : `auth.override_granted`, avec le demandeur et le responsable.

---

## 3. Utilisateurs

Préfixe : `/api/v1/users` · **Accès : ADMIN pour toutes les routes**, sinon `403 INSUFFICIENT_PRIVILEGE` avec `meta.required_role = "ADMIN"`.

Objet renvoyé (`UserDetail`) :

```json
{
  "id": "2b7c…",
  "full_name": "Awa Koné",
  "role": "CAISSIER",
  "is_active": true,
  "last_login_at": "2026-09-27T09:12:44.120Z",
  "created_at": "2026-09-24T15:21:03.004Z"
}
```

Le PIN et son haché ne sont jamais renvoyés.

### `GET /users` — liste

Réponse `200` : `{"items": [UserDetail…], "next_cursor": null}`, **utilisateurs désactivés compris**, triés par nom.

### `POST /users` — créer un utilisateur

Corps :

| Champ | Type | Contraintes |
|---|---|---|
| `full_name` | chaîne | 1 à 120 caractères. Les espaces en début et en fin sont retirés. |
| `role` | `CAISSIER` \| `RESPONSABLE` \| `ADMIN` | |
| `pin` | chaîne | **Exactement 6 chiffres** (`PIN_LENGTH`) |

```json
{ "full_name": "Awa Koné", "role": "CAISSIER", "pin": "111111" }
```

Réponse `201` : `UserDetail`.

| Code | Cas |
|---|---|
| `422 VALIDATION_ERROR` | PIN non numérique ou hors 4–8 chiffres (contrôle du schéma), **ou** PIN de 4, 5, 7 ou 8 chiffres (règle métier : `meta.fields[0].type = "pin_format"`) |
| `409 PIN_ALREADY_USED` | Un autre utilisateur **actif** a déjà ce PIN. Le PIN sert d'identifiant à la connexion, il doit donc être unique. |

Trace dans `audit_logs` : `user.create`.

### `PATCH /users/{user_id}` — modifier

Mise à jour partielle : seuls les champs envoyés changent.

| Champ | Type |
|---|---|
| `full_name` | chaîne, 1 à 120 caractères |
| `role` | `CAISSIER` \| `RESPONSABLE` \| `ADMIN` |
| `is_active` | booléen |

```json
{ "is_active": false }
```

Réponse `200` : `UserDetail`.

| Code | Cas |
|---|---|
| `404 NOT_FOUND` | Identifiant inconnu (`meta.user_id`) |
| `422 VALIDATION_ERROR` | `user_id` n'est pas un UUID |

Effets à vérifier :
- **Désactivation** : l'utilisateur ne peut plus se connecter, et **ses jetons déjà émis cessent de fonctionner immédiatement** (`401` sur `/auth/me` et sur `/auth/refresh`).
- **Changement de rôle** : il s'applique dès la requête suivante, sans reconnexion. Le rôle est relu en base à chaque appel.

> **Comportement actuel :** rien n'empêche un ADMIN de se désactiver lui-même ou de retirer le dernier ADMIN. En cas de besoin, on s'en sort avec `python -m caisse.cli create-user`.

Trace dans `audit_logs` : `user.update`, avec l'état avant et après.

### `POST /users/{user_id}/pin` — réinitialiser le PIN

Corps :

```json
{ "pin": "222222" }
```

Réponse : `204`, sans corps.

| Code | Cas |
|---|---|
| `422 VALIDATION_ERROR` | PIN pas exactement 6 chiffres |
| `404 NOT_FOUND` | Utilisateur inconnu |
| `409 PIN_ALREADY_USED` | PIN déjà pris par un autre utilisateur actif. Remettre son propre PIN actuel est accepté. |

À tester : l'ancien PIN renvoie `401` à la connexion, le nouveau renvoie `200`.

Trace dans `audit_logs` : `user.pin_reset`.

---

## 4. Catalogue

Préfixe : `/api/v1`. **Accès** : lecture et article libre pour tout utilisateur connecté ; création, modification et prix réservés au **RESPONSABLE**.

Les lignes de commande **figent** nom, catégorie, prix et TVA au moment de l'ajout : modifier le catalogue ne change jamais une commande déjà saisie.

### `GET /categories`

Paramètre facultatif `is_active` : `true` par défaut (actives), `false` (désactivées). Réponse `200` triée par `sort_order` puis par nom.

```json
{
  "items": [
    {
      "id": "c1d2…",
      "name": "Poissons",
      "kind": "FOOD",
      "sort_order": 0,
      "color": "#B45309",
      "is_active": true,
      "fiscal_group": "POISSONS"
    }
  ],
  "next_cursor": null
}
```

`kind` vaut `FOOD`, `DRINK` ou `OTHER`. `fiscal_group` sert au récapitulatif FNE journalier (L6).

Jeu de démo : Poissons, Viandes, Accompagnements, Jus, Sucreries, Eau.

### `GET /products`

Paramètres de requête, tous facultatifs :

| Paramètre | Type | Effet |
|---|---|---|
| `category_id` | UUID | Filtre sur une catégorie |
| `search` | chaîne | Recherche dans `name`, sans tenir compte de la casse, n'importe où dans le nom |
| `is_active` | booléen | `true` par défaut. `false` renvoie les produits désactivés. |

Réponse `200` : triée par `sort_order` puis par nom.

```json
{
  "items": [
    {
      "id": "a9f0…",
      "name": "Jus de bissap",
      "short_name": "Bissap",
      "category_id": "c1d2…",
      "price_xof": 1000,
      "vat_rate": 0.0,
      "track_stock": true,
      "stock_quantity": 48.0,
      "is_active": true,
      "is_custom": false,
      "color": null,
      "sort_order": 0
    },
    {
      "id": "b7e3…",
      "name": "Poulet braisé",
      "short_name": "Poulet braisé",
      "category_id": "d4e5…",
      "price_xof": 4000,
      "vat_rate": 0.0,
      "track_stock": false,
      "stock_quantity": null,
      "is_active": true,
      "is_custom": false,
      "color": null,
      "sort_order": 3
    }
  ],
  "next_cursor": null
}
```

- `track_stock: true` : le produit a une **fiche technique** (§11), sa vente déstocke. `stock_quantity` donne alors le **nombre de portions encore vendables** avec le stock actuel (minimum sur les articles de la fiche, jamais négatif) ; `null` sans fiche. Rempli par la même requête, sans appel supplémentaire.
- Les **produits personnalisés** (`is_custom: true`, créés à la volée pendant une commande) **n'apparaissent jamais** dans cette liste.
- Il n'existe **aucun moyen d'obtenir les produits actifs et inactifs en un seul appel** : `is_active` vaut `true` ou `false`, jamais « tous ».

| Code | Cas |
|---|---|
| `422 VALIDATION_ERROR` | `category_id` n'est pas un UUID, ou `is_active` n'est pas un booléen |

```bash
curl -s "localhost:8001/api/v1/products?search=jus" -H "Authorization: Bearer $TOKEN" \
  | jq '.items[] | {name, price_xof, stock_quantity}'
```

### `POST /products/custom` — article libre

Produit créé à la volée pendant une commande (plat du jour, poisson au poids…). Il a `is_custom: true`, n'apparaît **jamais** dans `GET /products`, et s'ajoute ensuite à la commande avec `POST /orders/{id}/items`.

Corps :

| Champ | Type | Contraintes |
|---|---|---|
| `name` | chaîne | 1 à 120 caractères. Le libellé ticket (`short_name`) en reprend les 20 premiers. |
| `price_xof` | entier | ≥ 0, prix TTC |
| `category_id` | UUID | Catégorie active ; elle fixe le groupe fiscal de la ligne |
| `vat_rate` | décimal | Facultatif ; défaut : paramètre `vat.default_rate` (`0.00`, régime TEE) |

```json
{ "name": "Poisson capitaine 1 kg", "price_xof": 9000, "category_id": "c1d2…" }
```

Réponse `201` : le produit, au format de `GET /products` (`stock_quantity: null`, `track_stock: false`).

| Code | Cas |
|---|---|
| `404 NOT_FOUND` | Catégorie inconnue ou désactivée |
| `422 VALIDATION_ERROR` | Nom vide, prix négatif |

Trace dans `audit_logs` : `product.create_custom`.

### `GET /products/{id}` — détail

Même format que `GET /products`, articles libres compris. `404 NOT_FOUND` si inconnu.

### `POST /categories` — créer une catégorie

**Accès** : RESPONSABLE.

```json
{ "name": "Poissons", "kind": "FOOD", "fiscal_group": "POISSONS", "color": "#B45309" }
```

| Champ | Contraintes |
|---|---|
| `name` | 1 à 60 caractères, **unique sans tenir compte de la casse** |
| `kind` | `FOOD`, `DRINK` ou `OTHER` |
| `fiscal_group` | Facultatif, `AUTRES` par défaut, mis en majuscules (POISSONS, VIANDES, JUS, EAU, PLATS, AUTRES…) |
| `color` | Facultatif, `#RRGGBB` |
| `sort_order` | Facultatif ; défaut : après la dernière catégorie |

Réponse `201` : la catégorie. Erreurs : `409 CATEGORY_NAME_EXISTS` (`meta.category_id`), `422 VALIDATION_ERROR`.

### `PATCH /categories/{id}` et `DELETE /categories/{id}` — modifier, désactiver

`PATCH` ne change que les champs envoyés (`name`, `kind`, `fiscal_group`, `color` — `null` l'efface —, `sort_order`, `is_active`). `DELETE` est une **suppression logique** (`is_active: false`), comme `PATCH {"is_active": false}` ; `PATCH {"is_active": true}` réactive.

Une catégorie qui contient encore des **produits actifs** ne peut pas être désactivée : `409 CATEGORY_NOT_EMPTY` (`meta.active_products`). Retirer d'abord ses produits du menu. Réponse `200` : la catégorie. Autres erreurs : `404 NOT_FOUND`, `409 CATEGORY_NAME_EXISTS`.

### `POST /products` — créer un produit

**Accès** : RESPONSABLE.

```json
{ "category_id": "c1d2…", "name": "Plat poulet", "short_name": "Plat poulet", "price_xof": 3000 }
```

| Champ | Contraintes |
|---|---|
| `category_id` | Catégorie **active** |
| `name` | 1 à 120 caractères, unique dans le menu (sans la casse ; les articles libres ne comptent pas) |
| `short_name` | Facultatif, 20 caractères au plus ; défaut : les 20 premiers caractères du nom |
| `price_xof` | Entier ≥ 0, TTC |
| `vat_rate` | Facultatif ; défaut : `vat.default_rate` (0 % en régime TEE) |
| `color`, `sort_order`, `sku` | Facultatifs ; `sort_order` par défaut en fin de catégorie ; `sku` unique |

Réponse `201` : le produit, au format de `GET /products`. Pour qu'il déstocke, lui donner une fiche technique (§11). Erreurs : `404 NOT_FOUND` (catégorie inconnue ou désactivée), `409 PRODUCT_NAME_EXISTS` (`meta.product_id`), `409 PRODUCT_SKU_EXISTS`, `422 VALIDATION_ERROR`.

### `PATCH /products/{id}` — modifier un produit

Seuls les champs envoyés changent : `category_id`, `name`, `short_name`, `vat_rate`, `color`, `sort_order`, `sku` (`null` l'efface), `is_active` (`false` : retiré du menu). **Le prix ne se change pas ici** : un `price_xof` envoyé est ignoré. Réponse `200` : le produit. Erreurs : celles de `POST /products`.

### `PATCH /products/{id}/price` — changer le prix

**Accès** : RESPONSABLE.

```json
{ "price_xof": 3500, "reason": "Hausse du prix du poulet" }
```

`reason` obligatoire. Le changement est historisé et tracé (`product.price_change`). Il vaut pour les lignes ajoutées **ensuite** : une commande en cours garde ses prix. Un prix identique ne change rien. Réponse `200` : le produit.

### `GET /products/{id}/price-history` — historique des prix

**Accès** : RESPONSABLE. Du plus récent au plus ancien :

```json
{ "items": [ { "old_price_xof": 3000, "new_price_xof": 3500, "reason": "Hausse du prix du poulet",
               "changed_by": "…", "changed_at": "2026-10-16T10:00:00Z" } ], "next_cursor": null }
```

Trace dans `audit_logs` : `category.create`, `category.update`, `product.create`, `product.update`, `product.price_change`.

---

## 5. Tables

Préfixe : `/api/v1/tables` · **Accès** : lecture pour tout utilisateur connecté ; création, modification et désactivation réservées à l'**ADMIN**.

### `GET /tables` — configuration de la salle

Paramètre facultatif `is_active` : `true` par défaut (en service), `false` (désactivées). Réponse `200` triée par `sort_order` puis par libellé.

```json
{
  "items": [
    { "id": "5e6f…", "label": "1", "zone": "Salle", "seats": 4, "sort_order": 0, "is_active": true }
  ],
  "next_cursor": null
}
```

Jeu de démo : 15 tables.

### `GET /tables/board` — écran d'accueil de la caisse

Un seul appel fournit l'état de la salle et le résumé de la journée. Le back-end n'exécute qu'une requête pour les tables et une pour le résumé, jamais une par table.

Réponse `200` :

```json
{
  "business_date": null,
  "summary": { "revenue_today_xof": 0, "orders_count": 0, "open_orders": 0 },
  "tables": [
    {
      "id": "5e6f…",
      "label": "1",
      "zone": "Salle",
      "seats": 4,
      "status": "FREE",
      "order": null,
      "orders": [],
      "total_ttc_xof": 0
    }
  ]
}
```

Quand une table a une ou plusieurs commandes actives (`OPEN` ou `PARTIALLY_PAID`) :

```json
{
  "status": "OCCUPIED",
  "order": { "id": "0a1b…", "order_number": "2026-09-27-0007", "note_label": "Note 1",
             "total_ttc_xof": 9000, "paid_xof": 0, "guests_count": 3,
             "opened_at": "2026-09-27T12:04:10Z", "status": "OPEN" },
  "orders": [
    { "id": "0a1b…", "note_label": "Note 1", "total_ttc_xof": 9000, "…": "…" },
    { "id": "7c8d…", "note_label": "Groupe Koné", "total_ttc_xof": 4500, "…": "…" }
  ],
  "total_ttc_xof": 13500
}
```

**Partage de table** : `orders` liste toutes les commandes actives de la table, de la plus ancienne à la plus récente ; `order` reste la plus ancienne (compatibilité avec un écran qui n'en affiche qu'une) ; `total_ttc_xof` est le total de la table. Voir `POST /orders` (§7) pour ouvrir une commande de plus sur une table occupée.

| Champ | Contenu |
|---|---|
| `business_date` | Journée comptable de la session de caisse ouverte, `null` sinon |
| `summary.revenue_today_xof` | Total des commandes **payées** de la journée |
| `summary.orders_count` | Nombre de commandes payées de la journée |
| `summary.open_orders` | Nombre de commandes encore ouvertes |

À tester : ouvrir une session ([§6](#6-sessions-de-caisse)) → `business_date` se remplit ; créer une commande sur une table ([§7](#7-commandes)) → la table passe en `OCCUPIED` avec son total, et `summary.open_orders` augmente ; l'encaisser ([§8](#8-paiements)) ou l'annuler → la table redevient `FREE` ; une fois soldée, la commande compte dans `revenue_today_xof` et `orders_count`.

### `POST /tables` — créer une table

**Accès** : ADMIN.

```json
{ "label": "12", "zone": "Terrasse", "seats": 4 }
```

`label` : 1 à 20 caractères, **unique sans la casse** ; `zone` : `Salle` par défaut ; `seats` : 1 à 50, 4 par défaut ; `sort_order` : facultatif, en dernier par défaut. Réponse `201` : la table. Erreurs : `409 TABLE_LABEL_EXISTS` (`meta.table_id`), `422 VALIDATION_ERROR`.

### `PATCH /tables/{id}` et `DELETE /tables/{id}` — modifier, désactiver

**Accès** : ADMIN. `PATCH` ne change que les champs envoyés (`label`, `zone`, `seats`, `sort_order`, `is_active`). `DELETE` est une **suppression logique** (`is_active: false`) ; `PATCH {"is_active": true}` remet la table en service. Une table qui porte des commandes en cours ne peut pas être désactivée : `409 TABLE_HAS_ACTIVE_ORDERS` (`meta.order_ids`). Réponse `200` : la table. Autres erreurs : `404 NOT_FOUND`, `409 TABLE_LABEL_EXISTS`.

Trace dans `audit_logs` : `table.create`, `table.update`.

---

## 6. Sessions de caisse

Préfixe : `/api/v1/cash-sessions` · **Accès : connecté**, sauf `GET /cash-sessions` (historique) réservé au **RESPONSABLE**.

MVP mono-poste : il n'y a qu'une caisse (`cash_register_id` unique, créée par `python -m caisse.cli bootstrap`) et jamais plus d'une session non clôturée à la fois, tous postes confondus.

Objet renvoyé (`CashSessionOut`) :

```json
{
  "id": "f1a2…",
  "cash_register_id": "b3c4…",
  "status": "OPEN",
  "business_date": "2026-09-30",
  "opening_float_xof": 20000,
  "opened_at": "2026-09-30T08:00:00Z",
  "closed_at": null,
  "z_number": null,
  "counted_cash_xof": null,
  "expected_cash_xof": null,
  "variance_xof": null,
  "notes": null
}
```

### `GET /cash-sessions/current` — session ouverte sur ce poste

Réponse `200` : `CashSessionOut`.

| Code | Cas |
|---|---|
| `409 NO_OPEN_SESSION` | Aucune session ouverte actuellement |

### `POST /cash-sessions` — ouvrir une session

**Idempotent** : en-tête `Idempotency-Key` obligatoire.

Corps :

| Champ | Type | Contraintes |
|---|---|---|
| `cash_register_id` | UUID | Caisse à ouvrir |
| `opening_float_xof` | entier | ≥ 0, fonds de caisse initial |
| `business_date` | date | Facultatif, défaut : date du jour (UTC) |
| `confirm_business_date` | booléen | Facultatif, défaut `false` — voir `BUSINESS_DATE_MISMATCH` |

```json
{ "cash_register_id": "b3c4…", "opening_float_xof": 20000 }
```

Réponse `201` : `CashSessionOut`. Rejeu de la même clé avec le même corps → `200` + en-tête `Idempotent-Replay: true` + le même corps.

| Code | Cas | `meta` |
|---|---|---|
| `404 NOT_FOUND` | Caisse inconnue ou hors service ; la liste des caisses : `GET /cash-registers` (§13) | `cash_register_id` |
| `409 SESSION_ALREADY_OPEN` | Une session est déjà ouverte sur cette caisse | |
| `409 BUSINESS_DATE_MISMATCH` | Une session déjà clôturée existe pour cette caisse et cette `business_date` | `business_date`, `existing_session_id` — rejouer avec `confirm_business_date: true` |
| `409 IDEMPOTENCY_CONFLICT` | Même `Idempotency-Key`, corps différent | `key` |

À tester :
- ouverture → `201` ; rejeu même clé/même corps → `200` + `Idempotent-Replay: true` ; même clé, corps différent → `409 IDEMPOTENCY_CONFLICT` ;
- deuxième ouverture (clé différente) sur la même caisse → `409 SESSION_ALREADY_OPEN`.

Trace dans `audit_logs` : `cash_session.open`.

### `GET /cash-sessions/{id}/x-report` — rapport X (lecture seule)

Réponse `200` (`XReportOut`) : agrégats de la session **en cours**, recalculés à chaque appel, sans aucun effet de bord.

```json
{
  "session_id": "f1a2…",
  "business_date": "2026-09-30",
  "expected_cash_xof": 23000,
  "totals": {
    "gross_ttc_xof": 0, "vat_xof": 0, "orders_count": 0,
    "by_payment_method": [], "by_fiscal_group": [],
    "controls": { "cancelled_orders": 0, "removed_items": 0, "reprints": 0 }
  }
}
```

Seules les commandes **soldées** (`PAID`) comptent dans le chiffre d'affaires et la ventilation par groupe fiscal ; `controls` compte les commandes annulées et les lignes retirées.

> `by_payment_method` additionne les paiements enregistrés ([§8](#8-paiements)), y compris ceux d'une commande pas encore soldée ; les paiements annulés (`VOIDED`) n'y figurent pas. Dans `expected_cash_xof`, les espèces comptent pour `amount_xof` (ce qui reste dans le tiroir), pas pour la somme remise.

| Code | Cas |
|---|---|
| `404 NOT_FOUND` | Session inconnue |

### `POST /cash-sessions/{id}/close` — clôturer la session (Z)

**Idempotent** : en-tête `Idempotency-Key` obligatoire.

Corps :

| Champ | Type | Contraintes |
|---|---|---|
| `counted_breakdown` | objet | Comptage par dénomination, ex. `{"10000": 2, "1000": 3}` |
| `notes` | chaîne \| `null` | Facultatif, ≤ 500 caractères |

```json
{ "counted_breakdown": { "10000": 2, "1000": 3 }, "notes": "RAS" }
```

Réponse `201` (`ZReportOut`) :

```json
{
  "z_number": 1,
  "business_date": "2026-09-30",
  "expected_cash_xof": 23000,
  "counted_cash_xof": 23000,
  "variance_xof": 0,
  "totals": { "...": "identique à x-report, figé" },
  "print_job_id": "9e2f…"
}
```

`expected_cash_xof = opening_float_xof + encaissements espèces + entrées − sorties de tiroir`. `print_job_id` est le ticket Z imprimé **une seule fois**, à la clôture ([§10](#10-impression)) ; `GET /cash-sessions/{id}/z-report` renvoie toujours le même id. N'ouvre pas le tiroir.

| Code | Cas | `meta` |
|---|---|---|
| `404 NOT_FOUND` | Session inconnue | |
| `409 SESSION_ALREADY_CLOSED` | Déjà clôturée (hors rejeu idempotent) | |
| `409 SESSION_HAS_OPEN_ORDERS` | Des commandes ne sont pas soldées | `open_orders[]` |
| `409 IDEMPOTENCY_CONFLICT` | Même `Idempotency-Key`, corps différent | `key` |

À tester :
- clôture avec un comptage exact → `variance_xof: 0`, `z_number` commence à `1` et s'incrémente à chaque clôture sur la même caisse ;
- comptage différent du théorique → `variance_xof` non nul, signé (compté − théorique) ;
- rejeu de la même clé → `200` + `Idempotent-Replay: true`.

Trace dans `audit_logs` : `cash_session.close`.

### `GET /cash-sessions/{id}/z-report` — rapport Z figé

Réponse `200` : `ZReportOut`, identique à la réponse de clôture, relue depuis `totals_snapshot` (aucun recalcul).

| Code | Cas |
|---|---|
| `404 NOT_FOUND` | Session inconnue |
| `409 SESSION_NOT_CLOSED` | La session n'est pas encore clôturée |

### `POST /cash-sessions/{id}/z-report/reprint` — ré-imprimer le ticket Z

**Accès** : connecté. Duplicata du ticket Z **tel qu'imprimé à la clôture** (jamais recalculé), marqué `is_reprint: true`. Il n'ouvre pas le tiroir et est compté dans les ré-impressions. Réponse `200` : le travail d'impression (format de `GET /printing/jobs`, §10), mis en file (`QUEUED`) : l'agent du terminal le prend.

| Code | Cas |
|---|---|
| `404 NOT_FOUND` | Session inconnue |
| `409 SESSION_NOT_CLOSED` | Session pas encore clôturée |
| `409 NO_RECEIPT_TO_REPRINT` | Session clôturée sans ticket Z enregistré |

### `GET /cash-sessions` — historique

**Accès : RESPONSABLE**, sinon `403 INSUFFICIENT_PRIVILEGE`.

Réponse `200` : `{"items": [CashSessionOut…], "next_cursor": null}`, sessions **clôturées** uniquement, les plus récentes en premier.

### `POST /cash-sessions/{id}/movements` — entrée ou sortie de tiroir

Pas d'`Idempotency-Key` (absent du contrat pour cette route).

Corps :

| Champ | Type | Contraintes |
|---|---|---|
| `type` | `IN` \| `OUT` | Entrée ou sortie |
| `amount_xof` | entier | > 0 |
| `reason` | chaîne | 1 à 255 caractères, obligatoire |

```json
{ "type": "OUT", "amount_xof": 2000, "reason": "achat glace" }
```

Réponse `201` (`MovementResult`) :

```json
{
  "movement": { "id": "…", "type": "OUT", "amount_xof": 2000, "reason": "achat glace", "created_at": "…" },
  "session": { "...": "CashSessionOut à jour" }
}
```

| Code | Cas |
|---|---|
| `404 NOT_FOUND` | Session inconnue |
| `409 NO_OPEN_SESSION` | La session n'est plus `OPEN` (déjà clôturée) |

Trace dans `audit_logs` : `cash_session.movement`.

```bash
curl -s -X POST $API/cash-sessions -H "$AUTH" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $(uuidgen)" -d '{"cash_register_id":"'"$REGISTER_ID"'","opening_float_xof":20000}' | jq
```

---

## 7. Commandes

Préfixe : `/api/v1/orders` · **Accès : connecté**. Seule l'annulation d'une commande demande un responsable (ou un caissier avec un `X-Override-Token`).

Une commande est toujours rattachée à la **session de caisse ouverte** et à sa journée comptable. Les montants sont **toujours recalculés par le backend** : le front n'additionne jamais rien.

**Toutes les mutations** (création, ajout, modification, retrait, annulation) renvoient la commande complète (`OrderResult`) :

```json
{
  "order": {
    "id": "0a1b…",
    "order_number": "2026-09-30-0001",
    "status": "OPEN",
    "business_date": "2026-09-30",
    "table_id": "5e6f…",
    "counter_number": null,
    "guests_count": 4,
    "note_label": "Note 1",
    "total_ttc_xof": 9500,
    "total_ht_xof": 9500,
    "total_vat_xof": 0,
    "paid_xof": 0,
    "due_xof": 9500,
    "opened_at": "2026-09-30T12:04:10Z",
    "paid_at": null,
    "cancelled_at": null,
    "cancelled_reason": null,
    "items": [
      {
        "id": "7c8d…",
        "product_id": "a9f0…",
        "name": "Poisson braisé",
        "unit_price_xof": 3500,
        "quantity": 2,
        "line_total_xof": 7000,
        "note": "bien cuit",
        "added_at": "2026-09-30T12:05:02Z"
      }
    ],
    "payments": []
  },
  "warnings": []
}
```

| Règle | Détail |
|---|---|
| Numérotation | `order_number` = `<journée>-<n° sur 4 chiffres>`, séquence par journée comptable |
| Vente à emporter | `table_id: null` → `counter_number` attribué (« Comptoir n° X »), séquence par journée |
| Table partagée | Une commande `OPEN` / `PARTIALLY_PAID` par table, sauf partage demandé explicitement (`allow_multiple` ou `note_label`) : chaque commande d'une table a alors son étiquette |
| Prix figé | Libellé, prix, TVA et groupe fiscal sont **copiés sur la ligne** à l'ajout : un changement de prix du menu ne touche pas les commandes en cours |
| TVA | Calculée depuis le TTC, par taux : `ht = arrondi(ttc / (1 + taux))`, `tva = ttc − ht` |
| Lignes modifiables | Uniquement en `OPEN` / `PARTIALLY_PAID`. Une fois soldée ou annulée, la commande est figée (`409 ORDER_NOT_EDITABLE`) |
| Lignes retirées | Jamais supprimées : marquées retirées (qui, quand, motif), absentes de `items` et des totaux, comptées dans le rapport X/Z |

### `POST /orders` — créer une commande

Corps :

| Champ | Type | Contraintes |
|---|---|---|
| `table_id` | UUID \| `null` | Table active ; `null` ou absent pour une vente à emporter |
| `guests_count` | entier \| `null` | Facultatif, 1 à 99 |
| `note_label` | chaîne \| `null` | Facultatif, 1 à 50 caractères : étiquette de la commande sur la table (« Groupe Koné »). Défaut sur une table : « Note 1 », « Note 2 »… (premier numéro libre) |
| `allow_multiple` | booléen | `false` par défaut. Table occupée : `true` ouvre une commande de plus |

```json
{ "table_id": "5e6f…", "guests_count": 4 }
```

Réponse `201` : `OrderResult`, sans lignes. `order.note_label` donne l'étiquette retenue.

**Partage de table.** Une table occupée **refuse** une nouvelle commande (`409 TABLE_ALREADY_OCCUPIED`) : c'est le cas courant, le front ouvre alors la commande existante (`meta.order_id`). Pour servir un autre groupe à la même table, renvoyer la requête avec `allow_multiple: true` ou une `note_label`. Deux postes qui ouvrent la même table en même temps sont départagés par un verrou : le second reçoit le `409`.

| Code | Cas | `meta` |
|---|---|---|
| `409 NO_OPEN_SESSION` | Aucune session de caisse ouverte | |
| `404 NOT_FOUND` | Table inconnue ou désactivée | `table_id` |
| `409 TABLE_ALREADY_OCCUPIED` | La table a déjà une commande active, sans `allow_multiple` ni `note_label` | `order_id` : la plus ancienne commande active ; `active_orders` : leur nombre |
| `409 ORDER_LABEL_TAKEN` | Une commande active de la table porte déjà cette étiquette (sans la casse) | `order_id`, `note_label` |

Trace dans `audit_logs` : `order.create`.

### `GET /orders` — lister les commandes d'une journée

Paramètres de requête, facultatifs :

| Paramètre | Effet |
|---|---|
| `business_date` | Journée comptable. Défaut : celle de la session ouverte, sinon le jour (UTC) |
| `status` | `OPEN`, `PARTIALLY_PAID`, `PAID`, `CANCELLED`, `REFUNDED` |

Réponse `200` : `{"items": [...], "next_cursor": null}`, les plus récentes en premier. Chaque élément a les mêmes champs que `order` ci-dessus **sans `items`** (détail : `GET /orders/{id}`).

Utile pour retrouver les ventes à emporter en cours, qui n'apparaissent pas sur le plan de salle : `GET /orders?status=OPEN`.

| Code | Cas |
|---|---|
| `403 INSUFFICIENT_PRIVILEGE` | Un CAISSIER demande une autre journée que celle de la session ouverte (historique réservé au RESPONSABLE) |

### `GET /orders/{id}` — détail

Réponse `200` : l'objet `order` complet, avec ses lignes actives et ses paiements (§8). Erreur : `404 NOT_FOUND`.

### `POST /orders/{id}/items` — ajouter une ligne

Corps :

| Champ | Type | Contraintes |
|---|---|---|
| `product_id` | UUID | Produit actif du menu, ou article libre |
| `quantity` | entier | 1 à 999, `1` par défaut |
| `note` | chaîne \| `null` | Facultatif, ≤ 255 caractères (« bien cuit », « sans piment ») |

```json
{ "product_id": "a9f0…", "quantity": 2, "note": "bien cuit" }
```

Réponse `201` : `OrderResult`. Ajouter deux fois le même produit crée **deux lignes** (les notes peuvent différer).

| Code | Cas |
|---|---|
| `404 NOT_FOUND` | Commande ou produit inconnu |
| `409 ORDER_NOT_EDITABLE` | Commande soldée ou annulée |
| `422 VALIDATION_ERROR` | Produit désactivé (`meta.fields[0].type = "product_inactive"`), quantité hors bornes |

### `PATCH /orders/{id}/items/{item_id}` — modifier une ligne

Mise à jour partielle : un champ absent reste inchangé, `"note": null` efface la note.

| Champ | Type |
|---|---|
| `quantity` | entier, 1 à 999 |
| `note` | chaîne \| `null`, ≤ 255 caractères |

```json
{ "quantity": 3 }
```

Réponse `200` : `OrderResult`.

| Code | Cas |
|---|---|
| `404 NOT_FOUND` | Commande inconnue, ou ligne inconnue / déjà retirée |
| `409 ORDER_NOT_EDITABLE` | Commande soldée ou annulée |

Trace dans `audit_logs` : `order.item_update`, avec quantité et note avant/après.

#### Baisser une quantité ou retirer une ligne : quelle différence ?

Exemple : une ligne « 3 × Poisson braisé = 10 500 ».

| | Baisse de quantité (`PATCH`, 3 → 1) | Retrait de ligne (`DELETE`) |
|---|---|---|
| La ligne | Reste sur la commande, à 1 | Disparaît de la commande |
| Total de la commande | − 7 000 | − 10 500 |
| Autorisation d'un responsable | Non | Non |
| Motif | Non demandé | **Obligatoire** |
| Trace | `audit_logs` (`order.item_update`, avant/après) | `audit_logs` (`order.item_remove`) + ligne conservée en base, marquée retirée |
| Compté dans le rapport X/Z (`controls.removed_items`) | **Non** | **Oui** |
| Limite | Minimum 1 : pour aller à 0, il faut retirer la ligne | — |

En résumé : la baisse corrige une quantité, le retrait annule un article. Les deux sont libres pour la caissière ; seul le retrait demande un motif et apparaît dans les contrôles du rapport Z.

### `DELETE /orders/{id}/items/{item_id}?reason=…` — retirer une ligne

**Accès : connecté**, sans autorisation de responsable (décision client du 30/09/2026). Le motif passe en **paramètre de requête** `reason` (1 à 255 caractères, obligatoire).

Réponse `200` : `OrderResult`, la ligne n'est plus dans `items` et les totaux sont recalculés.

| Code | Cas |
|---|---|
| `404 NOT_FOUND` | Commande inconnue, ou ligne inconnue / déjà retirée |
| `409 ORDER_NOT_EDITABLE` | Commande soldée ou annulée |
| `422 VALIDATION_ERROR` | `reason` absent ou vide |

À tester : caissier sans `reason` → `422` ; avec `reason` → `200` et `controls.removed_items` augmente dans le rapport X ; retirer la même ligne une 2ᵉ fois → `404`.

Trace dans `audit_logs` : `order.item_remove`, avec le produit, la quantité, le montant et le motif.

### `POST /orders/{id}/cancel` — annuler une commande

Corps :

```json
{ "reason": "client parti" }
```

| Utilisateur | Condition |
|---|---|
| RESPONSABLE, ADMIN | Direct |
| CAISSIER | En-tête `X-Override-Token` obtenu par `POST /auth/override` avec `"action": "order.cancel"` |

Réponse `200` : `OrderResult` avec `status: "CANCELLED"`, `cancelled_at` et `cancelled_reason` remplis, `due_xof: 0`. **La table est libérée** et la commande est figée.

| Code | Cas | `meta` |
|---|---|---|
| `403 OVERRIDE_REQUIRED` | Caissier sans jeton valide | `action`, `reason` |
| `404 NOT_FOUND` | Commande inconnue | |
| `409 ORDER_NOT_EDITABLE` | Déjà soldée ou annulée (`status`), ou paiements déjà enregistrés (`reason: "has_payments"` : les annuler d'abord, §8) | |

À tester : caissier sans jeton → `403` ; avec le jeton du responsable → `200` ; **rejouer le même jeton** sur une autre commande → `403` ; responsable sans jeton → `200`.

Trace dans `audit_logs` : `order.cancel`, avec le caissier (`user_id`) **et** le responsable qui a autorisé (`acting_as_user_id`).

> **Clôture de caisse :** une commande `OPEN` ou `PARTIALLY_PAID` bloque la clôture (`409 SESSION_HAS_OPEN_ORDERS`) : l'encaisser (§8) ou l'annuler avant de clôturer.

### `POST /orders/{id}/reprint` — ré-imprimer le ticket

**Accès** : connecté.

Réimprime le **dernier ticket tel que remis au client** : le contenu déjà stocké, jamais re-rendu depuis l'état courant de la commande (un retrait ou un avoir ultérieur ne doit pas changer rétroactivement une ré-impression). N'ouvre pas le tiroir. Compté dans `controls.reprints` (X/Z, §6).

Réponse `200` : `OrderResult` (pas de corps à envoyer).

| Code | Cas |
|---|---|
| `404 NOT_FOUND` | Commande inconnue |
| `409 NO_RECEIPT_TO_REPRINT` | Aucun ticket encore imprimé pour cette commande (ex. commande pas encore soldée) |

Trace dans `audit_logs` : `order.reprint`, puis `print_job.print` quand l'agent rend le résultat.

---

## 8. Paiements

**Accès : connecté** pour encaisser ; l'annulation d'un paiement demande un responsable (ou un caissier avec un `X-Override-Token`).

Une addition se règle en **un ou plusieurs paiements** (paiement partiel ou mixte : espèces + Mobile Money…). Chaque paiement réduit le reste dû ; quand il tombe à 0, la commande passe `PAID` et **la table est libérée**. Le backend recalcule toujours `paid_xof` et `due_xof` à partir des paiements enregistrés.

### Parcours d'écran conseillé

1. Bouton « Encaisser » sur une commande `OPEN` / `PARTIALLY_PAID` qui a un reste dû (`due_xof > 0`).
2. Boutons de moyens de paiement : `GET /payment-methods` (au chargement de l'application, la liste change rarement).
3. Montant proposé par défaut : `due_xof`. La caissière peut le baisser (paiement partiel), jamais le dépasser.
4. **Espèces** (`gives_change: true`) : saisir la somme remise (`tendered_xof`) ; afficher en grand la **monnaie à rendre** (`payment.change_xof`).
5. **Mobile Money** : choisir l'opérateur (`providers`) et, si possible, saisir le n° de transaction (`reference`).
6. Générer l'`Idempotency-Key` **avant** l'appel et la réutiliser telle quelle en cas de nouvel essai (coupure réseau, double clic) : la caisse n'enregistre jamais deux fois le même paiement.
7. Réponse : `order.status = "PAID"` → écran « Commande soldée » avec le bouton « Émettre la FNE » (§9). `PARTIALLY_PAID` → rester sur l'encaissement avec le nouveau reste dû.

> **Ticket et tiroir :** `receipt` vaut `null` tant que la commande n'est pas soldée (paiement partiel). Dès que `due_xof` tombe à 0, `receipt: {print_job_id, status, drawer_opened}` est rempli : le ticket part en file (`QUEUED`) et le tiroir s'ouvre quand l'agent du terminal l'imprime, en général sous 2 s (§10). La réponse n'attend jamais l'imprimante : `drawer_opened` vaut toujours `null`, suivre `GET /printing/jobs/{print_job_id}`. **FNE :** `fiscal_document` vaut toujours `null` : elle s'émet à la demande (§9).

### `GET /payment-methods` — moyens de paiement

Réponse `200`, dans l'ordre d'affichage (paramètre `payments.methods`) :

```json
[
  { "method": "CASH", "label": "Espèces", "gives_change": true, "providers": [] },
  { "method": "MOBILE_MONEY", "label": "Mobile Money", "gives_change": false,
    "providers": ["ORANGE", "MTN", "MOOV", "WAVE"] },
  { "method": "CARD", "label": "Carte bancaire", "gives_change": false, "providers": [] },
  { "method": "BANK_TRANSFER", "label": "Virement", "gives_change": false, "providers": [] },
  { "method": "CREDIT", "label": "Paiement différé", "gives_change": false, "providers": [] }
]
```

`OTHER` existe mais n'est pas proposé par défaut : il n'a pas de code FNE.

### `POST /orders/{id}/payments` — encaisser

En-tête **obligatoire** : `Idempotency-Key: <uuid>`.

| Champ | Type | Contraintes |
|---|---|---|
| `method` | texte | Un des `method` de `GET /payment-methods` |
| `amount_xof` | entier | > 0 et ≤ `due_xof` : la part imputée à l'addition |
| `tendered_xof` | entier \| `null` | **Espèces uniquement**, ≥ `amount_xof` : somme remise par le client |
| `provider` | texte \| `null` | **Obligatoire en Mobile Money** (`ORANGE`, `MTN`, `MOOV`, `WAVE`), interdit sinon |
| `reference` | texte \| `null` | N° de transaction, 64 caractères au plus |

```json
{ "method": "CASH", "amount_xof": 5000, "tendered_xof": 10000 }
```

Réponse `201` :

```json
{
  "payment": {
    "id": "3c4d…", "method": "CASH", "provider": null,
    "amount_xof": 5000, "tendered_xof": 10000, "change_xof": 5000, "reference": null,
    "status": "CAPTURED", "created_at": "2026-10-02T13:10:00Z",
    "voided_at": null, "void_reason": null
  },
  "order": { "…": "…", "status": "PARTIALLY_PAID", "total_ttc_xof": 9000,
             "paid_xof": 5000, "due_xof": 4000, "payments": [ { "…": "…" } ] },
  "receipt": null,
  "fiscal_document": null,
  "warnings": []
}
```

Second paiement qui solde l'addition :

```json
{ "method": "MOBILE_MONEY", "provider": "WAVE", "amount_xof": 4000, "reference": "TX8812" }
```

→ `order.status: "PAID"`, `due_xof: 0`, `paid_at` renseigné, et cette fois :

```json
{
  "receipt": { "print_job_id": "9e2f…", "status": "QUEUED", "drawer_opened": null },
  "fiscal_document": null
}
```

Agent ou imprimante hors ligne : la vente reste `201` et le ticket attend en file ; il sortira (tiroir compris) au retour de l'agent. Pour avertir la caissière, interroger `GET /printing/jobs/{print_job_id}` quelques secondes : toujours `QUEUED`, ou `FAILED` (§10).

Ce paiement qui solde la commande déstocke aussi les articles des fiches techniques (§11). Si un article passe sous zéro, la vente reste `201` et `warnings` le signale (bandeau, jamais bloquant) :

```json
"warnings": [ { "code": "STOCK_NEGATIVE_WARNING", "detail": "Mouton : stock -0.27",
                "meta": { "article_id": "…", "quantity": -0.27 } } ]
```

**Rejeu** de la même clé avec le même corps → `200`, en-tête `Idempotent-Replay: true`, **réponse d'origine à l'identique** (même si la commande a changé depuis), aucun nouveau paiement.

| Code | Cas | `meta` |
|---|---|---|
| `404 NOT_FOUND` | Commande inconnue | |
| `409 ORDER_NOT_EDITABLE` | Commande soldée ou annulée (`status`), ou rien à payer (`reason: "nothing_due"`) | |
| `422 PAYMENT_EXCEEDS_DUE` | Montant supérieur au reste dû | `due_xof`, `amount_xof` |
| `422 PAYMENT_METHOD_DISABLED` | Moyen absent de `payments.methods` | `method` |
| `422 VALIDATION_ERROR` | `tendered_xof` hors espèces ou inférieur au montant, `provider` manquant ou en trop, montant ≤ 0 | `fields` |
| `409 NO_OPEN_SESSION` | Aucune session de caisse ouverte | |
| `409 IDEMPOTENCY_CONFLICT` | Même clé, corps différent | `key` |

Trace dans `audit_logs` : `payment.create`.

### `DELETE /orders/{id}/payments/{payment_id}?reason=…` — annuler un paiement

Sert à **corriger une erreur de saisie** (mauvais moyen, mauvais montant) : on annule puis on ré-encaisse correctement. Le paiement n'est jamais supprimé : il reste dans `order.payments` avec `status: "VOIDED"`, `voided_at` et `void_reason`, et sort des totaux (X, Z, reste dû).

| Utilisateur | Condition |
|---|---|
| RESPONSABLE, ADMIN | Direct |
| CAISSIER | En-tête `X-Override-Token` obtenu par `POST /auth/override` avec `"action": "payment.void"` |

`reason` (paramètre de requête) est obligatoire. Réponse `200` : `OrderResult`, la commande redevient `PARTIALLY_PAID` (il reste des paiements) ou `OPEN`.

Warning `FNE_ALREADY_ISSUED` (`meta.document_id`, `meta.status`) si la commande a déjà une FNE : rien n'est fait automatiquement. S'il s'agit seulement de corriger le moyen de paiement, l'ignorer ; si la vente est réellement annulée, prévenir le responsable qu'un avoir est à émettre (§9).

| Code | Cas | `meta` |
|---|---|---|
| `403 OVERRIDE_REQUIRED` | Caissier sans jeton valide | `action`, `reason` |
| `404 NOT_FOUND` | Commande ou paiement inconnu | |
| `409 PAYMENT_NOT_VOIDABLE` | `reason` : `already_voided` ; `session_closed` (encaissé dans une session clôturée : le Z est figé). Depuis le partage de table, une table rouverte entre-temps n'empêche plus l'annulation (`table_reoccupied` n'existe plus) : la commande redevient active à côté des autres | `payment_id`, `reason` |

Trace dans `audit_logs` : `payment.void`, avec le caissier (`user_id`) et le responsable qui a autorisé (`acting_as_user_id`).

> **Annuler une commande déjà entamée :** annuler d'abord ses paiements, puis `POST /orders/{id}/cancel`. Le remboursement d'une commande soldée (`POST /orders/{id}/refunds`) n'est pas prévu pour l'instant.

---

## 9. Clients entreprise et FNE

La **FNE** (facture normalisée électronique) est certifiée par la plateforme de la DGI. Elle est émise **à la demande**, sur une commande soldée, jamais automatiquement à l'encaissement. Plan et décisions : [`PLAN-FNE.md`](PLAN-FNE.md).

### Préparer le test

1. **Choisir le fournisseur FNE** dans `.env`, puis recréer le conteneur (`docker compose … up -d --force-recreate api`) :

   | `FNE_PROVIDER` | Effet |
   |---|---|
   | `manual` (défaut) | Aucun appel : le document passe en `MANUAL`, à saisir dans l'application FNE |
   | `mock` | FNE simulée, réponses au format réel, sans réseau : **pour tester l'API** |
   | `api` | Plateforme DGI (`FNE_API_BASE_URL`, `FNE_API_KEY`) |

2. **Renseigner les paramètres FNE** (pas encore de route `/settings`) :

   ```bash
   docker exec -i infra-db sh -c 'psql -U "$POSTGRES_USER" -d caisse' <<'SQL'
   INSERT INTO settings (key, value) VALUES
     ('fne.point_of_sale', '"CAISSE-1"'),
     ('fne.establishment', '"RESTAURANT CHEZ SYLLA PLUS"'),
     ('fne.walk_in_client', '{"company_name":"CLIENT DIVERS","phone":"0748735573","email":"restaurantmykpro@gmail.com"}')
   ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
   SQL
   ```

3. **Solder une commande** par l'encaissement ([§8](#8-paiements)), par exemple en un seul paiement en espèces de `due_xof`.

### Statuts d'un document FNE

| `status` | `is_uncertain` | Sens | Action |
|---|---|---|---|
| `CERTIFIED` | false | Certifiée : `external_number` et `qr_payload` (lien de vérification DGI = page A4 imprimable) | — |
| `QUEUED` | false | FNE injoignable ou clé refusée : rien n'a été certifié | `retry` (renvoi automatique : à venir) |
| `FAILED` | false | Refusée par la DGI (données) | Corriger (client, paramètres) puis `retry` ou réémettre |
| `SUBMITTING` | **true** | Issue inconnue (délai dépassé, erreur 500) : la facture a **peut-être** été créée | Vérifier dans l'espace FNE, puis `resolve` |
| `MANUAL` | false | Mode manuel | Saisie dans l'application FNE |

Un document incertain n'est **jamais** renvoyé sans vérification : l'API FNE n'a aucune protection contre les doublons.

### Parcours d'écran conseillé

1. **Commande soldée** → bouton « Émettre la FNE » (le backend refuse avant : `409 FNE_ORDER_NOT_PAID`). Si `GET /orders/{id}/fne` renvoie déjà un document, afficher son état au lieu du bouton.
2. Choix **Particulier** (`B2C`, rien d'autre à saisir) ou **Entreprise** (`B2B`). `B2G` (administration) et `B2F` (client étranger) existent aussi.
3. **Entreprise** : saisie du NCC → `GET /customers?ncc=…` :
   - trouvé → afficher la raison sociale pour **confirmation**, puis émettre avec son `customer_id` ;
   - absent → formulaire (raison sociale, téléphone, e-mail) → `POST /customers` → émettre. Sur `409 CUSTOMER_NCC_EXISTS`, réutiliser `meta.customer_id`.
4. `POST /orders/{id}/fne` (jusqu'à 4 s d'attente : afficher un indicateur). Lire `document.status` et `warnings` :

   | Résultat | Affichage conseillé |
   |---|---|
   | `CERTIFIED` | n° FNE + bouton « Imprimer (A4) » qui ouvre `qr_payload` dans un nouvel onglet |
   | `QUEUED` | « FNE en attente de transmission » ; un responsable pourra la renvoyer |
   | `FAILED` (`FNE_REJECTED`) | « FNE refusée par la DGI », prévenir le responsable |
   | `SUBMITTING` + `is_uncertain` (`FNE_UNCERTAIN`) | « Résultat inconnu : **ne pas réessayer**, un responsable doit vérifier dans l'espace FNE » |
   | `MANUAL` | « À saisir dans l'application FNE » |
   | warning `FNE_STICKER_LOW` | bandeau « solde FNE bas, à recharger » (`meta.balance_funds_xof`, en XOF, peut être `null`) |

5. **Barre d'état** : `GET /fne/pending-count` au même rythme que les autres rafraîchissements ; un badge si `pending > 0`, mis en avant si `uncertain > 0`.
6. **Écran responsable** : `GET /fne/documents?status=…` avec les actions `retry` (QUEUED, FAILED) et `resolve` (incertains). L'action `refund` (avoir) est **secondaire** : voir plus bas.

Ne jamais rejouer automatiquement `POST /orders/{id}/fne` côté front : un rappel est sans danger (même document renvoyé), mais il ne relance pas une FNE incertaine.

### Objet `document` (FNE)

```json
{
  "id": "0192f3a1-…",
  "type": "FNE",
  "status": "CERTIFIED",
  "is_uncertain": false,
  "template": "B2B",
  "order_id": "0192f39e-…",
  "internal_reference": "2026-10-01-0042",
  "customer_id": "0192f3a0-…",
  "parent_document_id": null,
  "external_number": "1304777N26000000023",
  "qr_payload": "http://54.247.95.108/fr/verification/019465c1-3f61-766c-9652-706e32dfb436",
  "fne_amount_ttc_xof": 24000,
  "certified_at": "2026-10-01T15:00:36Z",
  "attempts": 1,
  "last_error": null,
  "next_retry_at": null,
  "created_at": "2026-10-01T15:00:35Z"
}
```

| Champ | Sens |
|---|---|
| `type` | `FNE` (vente) ou `REFUND` (avoir, avec `parent_document_id`) |
| `status` | `PENDING`, `SUBMITTING`, `CERTIFIED`, `QUEUED`, `FAILED`, `MANUAL` |
| `is_uncertain` | `true` : issue inconnue, voir `resolve` |
| `template` | `B2C`, `B2B`, `B2G`, `B2F` |
| `internal_reference` | N° de la commande |
| `external_number` | N° FNE de la DGI (`null` tant que non certifiée) |
| `qr_payload` | Lien de vérification DGI : contenu du QR et page A4 imprimable |
| `fne_amount_ttc_xof` | Total TTC calculé par la DGI (doit égaler celui de la commande) |
| `last_error` | Diagnostic technique, **à ne pas afficher tel quel** |
| `next_retry_at` | Renvoi prévu (`QUEUED`) |

Exemple de réponse avec avertissement (FNE injoignable) :

```json
{
  "document": { "id": "…", "type": "FNE", "status": "QUEUED", "is_uncertain": false,
                "external_number": null, "qr_payload": null, "attempts": 1,
                "next_retry_at": "2026-10-01T15:01:35Z", "…": "…" },
  "warnings": [
    { "code": "FNE_QUEUED", "detail": "FneUnavailableError: …",
      "meta": { "next_retry_at": "2026-10-01T15:01:35Z" } }
  ]
}
```

### `GET /customers?search=&ncc=` — rechercher un client entreprise

Rôle : CAISSIER. `search` cherche dans la raison sociale et le NCC ; `ncc` filtre sur le début du NCC (espaces et minuscules acceptés). 50 résultats au plus, triés par raison sociale.

```json
{
  "items": [
    { "id": "0192f3a0-…", "company_name": "CGECI", "ncc": "9506466A", "tax_regime": null,
      "address": null, "phone": "0709080765", "email": "contact@cgeci.ci" }
  ],
  "next_cursor": null
}
```

### `GET /customers/{id}` — détail d'un client

**Accès** : connecté. Réponse `200` : le client (format de `GET /customers`). `404 NOT_FOUND` si inconnu.

### `POST /customers` — créer un client entreprise

```json
{ "company_name": "CGECI", "ncc": "9506466A", "phone": "0709080765", "email": "contact@cgeci.ci" }
```

Le NCC doit comporter **7 chiffres et 1 lettre** (espaces et minuscules acceptés : `"9506 466a"` devient `"9506466A"`). La FNE ne vérifie pas le NCC à la saisie : ce contrôle est le seul filet. Réponse `201` : le client.

| Code | Cas |
|---|---|
| `409 CUSTOMER_NCC_EXISTS` | NCC déjà enregistré ; `meta.customer_id` donne le client existant |
| `422 VALIDATION_ERROR` | Format du NCC (`meta.fields[0].loc = ["body","ncc"]`) |

### `POST /orders/{id}/fne` — émettre la FNE d'une commande

Rôle : CAISSIER.

```json
{ "template": "B2B", "customer_id": "…", "payment_method": null }
```

| Champ | Défaut | Sens |
|---|---|---|
| `template` | `B2C` | `B2C` particulier · `B2B` entreprise (NCC obligatoire) · `B2G` administration · `B2F` international |
| `customer_id` | null | Obligatoire sauf en `B2C` |
| `payment_method` | null | Sinon : moyen du plus gros montant encaissé (la FNE n'en accepte qu'un) |

Réponse `201` : `{ "document": {…}, "warnings": [] }`. L'issue se lit dans `document.status` et `warnings` (`FNE_REJECTED`, `FNE_UNCERTAIN`, `FNE_QUEUED`, `FNE_STICKER_LOW`) : un refus de la DGI n'est **pas** une erreur HTTP.

**Une seule FNE par commande** : si elle existe déjà (et n'a pas été refusée), elle est renvoyée telle quelle en `200`, sans nouvel appel à la DGI. Une FNE refusée est reconstruite et renvoyée.

| Code | Cas |
|---|---|
| `404 NOT_FOUND` | Commande ou client inconnu |
| `409 FNE_ORDER_NOT_PAID` | Commande non soldée |
| `409 FNE_NOT_CONFIGURED` | Point de vente ou établissement non paramétré |
| `422 FNE_CUSTOMER_REQUIRED` | `B2B`, `B2G` ou `B2F` sans `customer_id` |
| `422 FNE_NCC_REQUIRED` | `B2B` avec un client sans NCC |
| `422 FNE_FIELD_REQUIRED` | Client de passage sans téléphone ou e-mail (`fne.walk_in_client`) |
| `422 FNE_NO_PAYMENT`, `FNE_VAT_RATE_UNMAPPED`, `FNE_PAYMENT_METHOD_UNMAPPED` | Paiement absent, taux de TVA ou moyen de paiement sans code FNE |

À tester (`FNE_PROVIDER=mock`) : émettre en B2C → `201 CERTIFIED` ; **rappeler** → `200`, même `id` ; B2B sans client → `422` ; commande non soldée → `409`.

### `GET /orders/{id}/fne` — FNE d'une commande

Rôle : CAISSIER. `404 NOT_FOUND` si aucune FNE n'a été émise.

### `GET /fne/documents?status=&business_date=` — suivi

Rôle : RESPONSABLE. 200 documents au plus, les plus récents en premier.

### `POST /fne/documents/{id}/retry` — renvoyer

Rôle : RESPONSABLE. Pour un document `QUEUED`, `FAILED` (reconstruit avec le client et les paramètres actuels) ou `PENDING`. Réponse `200` : `{ document, warnings }`.

`409 FNE_DOCUMENT_STATE` : `meta.reason = "uncertain"` (passer par `resolve`) ou `"not_retryable"` (certifié, manuel ou en cours).

### `POST /fne/documents/{id}/resolve` — trancher un cas incertain

Rôle : RESPONSABLE. Après vérification dans l'espace FNE, rubrique « Reçus et factures émis » :

```json
{ "is_certified": true, "external_number": "1304777N26000000023" }
```

- facture **numérotée** dans l'espace FNE → `is_certified: true` avec le n° relevé ; le document passe `CERTIFIED`. Il n'a alors pas les identifiants FNE nécessaires à un avoir par API ;
- facture **absente ou sans numéro** → `{ "is_certified": false }` ; le document est renvoyé.

`409 FNE_DOCUMENT_STATE` (`meta.reason = "not_uncertain"`) ; `422 VALIDATION_ERROR` si le n° manque.

### `POST /fne/documents/{id}/refund` — avoir

Rôle : RESPONSABLE. Avoir total ou partiel sur une FNE de vente certifiée par l'API .

> **Écran non prioritaire.** Au restaurant, l'avoir est rare : il sert uniquement à corriger une FNE certifiée par erreur (mauvais client ou NCC, mauvaise commande, plat contesté après certification), car une FNE certifiée ne se supprime ni ne se modifie. Un simple bouton « Émettre un avoir » dans le détail d'une FNE certifiée, côté responsable, suffit ; il peut arriver après le reste du parcours FNE.

Corps :

```json
{ "items": [{ "order_item_id": "…", "quantity": 1 }] }
```

Réponse `201` : le document d'avoir (`type: "REFUND"`, `parent_document_id`), mêmes statuts que l'émission. Les quantités déjà reprises sont déduites.

| Code | Cas |
|---|---|
| `404 NOT_FOUND` | Document ou ligne absente de la FNE |
| `409 FNE_DOCUMENT_STATE` | `meta.reason = "not_refundable"` : non certifiée, manuelle, ou certifiée hors API |
| `422 FNE_REFUND_EXCEEDS` | Quantité supérieure au reste (`meta.available`) |

### `GET /fne/documents/{id}/duplicate` — duplicata

Rôle : CAISSIER. Le document certifié ; `qr_payload` ouvre la page A4 de la DGI à imprimer. `409 FNE_DOCUMENT_STATE` (`not_certified`) sinon.

### `GET /fne/documents/export?status=&date_from=&date_to=` — export CSV

**Accès** : RESPONSABLE. Fichier CSV pour Excel (séparateur `;`, UTF-8 avec BOM, `Content-Disposition: attachment; filename="fne-<date>.csv"`), un document par ligne, du plus ancien au plus récent. Les filtres sont facultatifs ; `date_from`/`date_to` portent sur la journée comptable de la commande.

Colonnes : `cree_le`, `journee`, `commande`, `type` (`FNE`/`REFUND`), `statut`, `incertain` (`oui`/`non`), `numero_fne`, `client`, `ncc`, `montant_ttc_xof`, `certifie_le`, `derniere_erreur`.

### `GET /fne/pending-count` — compteur de la barre d'état

Rôle : CAISSIER. `{ "pending": 2, "uncertain": 1, "failed": 0 }` : documents en attente d'une action (`PENDING`, `QUEUED`, `SUBMITTING`, `FAILED`), dont incertains et refusés.

### `GET /fne/daily-summary?business_date=` — récapitulatif de la journée

Rôle : RESPONSABLE. Commandes soldées, part couverte par une FNE certifiée, documents en attente, ventes par groupe fiscal. Journée par défaut : celle de la session ouverte.

```json
{
  "business_date": "2026-10-01",
  "paid_orders": 58, "gross_ttc_xof": 412000,
  "certified_orders": 6, "certified_ttc_xof": 96000,
  "pending_documents": 1,
  "by_fiscal_group": [
    { "group": "POISSONS", "quantity": 62, "amount_xof": 217000 },
    { "group": "JUS", "quantity": 48, "amount_xof": 48000 }
  ]
}
```

Trace dans `audit_logs` : `customer.create`, `fne.issue`, `fne.submit` (à chaque appel à la DGI), `fne.retry`, `fne.resolve`, `fne.refund`.

---

## 10. Impression

Préfixe : `/api/v1/printing`. L'API est en ligne et ne peut pas joindre le restaurant : **l'agent du terminal** (`print-agent/`) vient chercher les travaux toutes les ~2 s avec le jeton de son terminal, imprime, puis rend le résultat. Le voir en marche : [`print-agent/README.md`](../print-agent/README.md) (mode factice sans imprimante branchée).

Cycle d'un travail : `QUEUED` (en file) → `PRINTING` (pris par l'agent) → `DONE` ou `FAILED`. L'imprimante est **toujours informative** : les tickets déclenchés par une vente ou une clôture (§6, §7, §8) partent `QUEUED` et ne font jamais échouer la requête. Agent arrêté ou imprimante rapportée hors ligne : les travaux attendent en file et sortent à son retour, tiroir compris. Seules les actions directes ci-dessous renvoient une erreur.

### `GET /printing/status` — état de l'impression

**Accès** : connecté.

```json
{
  "agent_online": true, "printer_online": true, "paper": "ok", "width": 48,
  "agent_last_seen_at": "2026-10-20T12:04:09Z",
  "queued_jobs": 0, "failed_jobs": 0, "last_success_at": "2026-10-20T12:04:10Z"
}
```

`agent_online` : un agent s'est signalé depuis moins de 15 s. `printer_online`, `paper`, `width` : l'état que l'agent rapporte. Mêmes informations que `printer` et `queues` de `GET /health/ready` (§1).

### `POST /printing/open-drawer` — ouverture manuelle du tiroir

**Accès** : RESPONSABLE. Hors vente (ex. correction de caisse), tracée dans `audit_logs` (`printing.open_drawer_manual`).

Réponse `202` : le travail mis en file (`"type": "DRAWER"`, `"status": "QUEUED"`). Le tiroir s'ouvre quand l'agent le prend, en général sous 2 s.

| Code | Cas |
|---|---|
| `503 PRINT_AGENT_UNAVAILABLE` | Aucun agent ne s'est signalé depuis 15 s : refusé plutôt qu'un tiroir qui s'ouvrirait plus tard |
| `503 PRINTER_UNAVAILABLE` | L'agent rapporte l'imprimante hors ligne |

### `GET /printing/jobs?status=` — file d'impression

**Accès** : connecté. `status` facultatif : `QUEUED`, `PRINTING`, `DONE`, `FAILED`.

```json
{
  "items": [
    { "id": "9e2f…", "type": "RECEIPT", "order_id": "0a1b…", "session_id": null,
      "status": "FAILED", "open_drawer": true, "attempts": 1, "last_error": "...",
      "is_reprint": false, "created_at": "2026-10-20T12:04:10Z" }
  ],
  "next_cursor": null
}
```

`type` : `RECEIPT`, `Z_REPORT`, `DRAWER` (ouverture manuelle), `TEST`.

### `GET /printing/jobs/{id}` — suivi d'un travail

**Accès** : connecté. Même format qu'un élément de `GET /printing/jobs`. Sert à suivre le ticket d'un paiement (`receipt.print_job_id`) ou d'une clôture (`print_job_id`). `404 NOT_FOUND` si inconnu.

### `POST /printing/jobs/{id}/retry` — rejeu d'un travail

**Accès** : connecté. Remet le travail en file : réponse `200` avec `"status": "QUEUED"`, l'agent le reprend à sa prochaine interrogation. Accepté pour un travail `FAILED`, ou `PRINTING` depuis plus de 2 min (agent arrêté en pleine impression ; jamais remis en file automatiquement, pour ne pas imprimer deux fois).

| Code | Cas |
|---|---|
| `404 NOT_FOUND` | Travail inconnu |
| `409 PRINT_JOB_NOT_RETRYABLE` | Déjà `DONE`, déjà `QUEUED`, ou pris par l'agent il y a moins de 2 min |

### `POST /printing/test` — ticket de test

**Accès** : ADMIN. Réponse `202` : le travail mis en file (`"type": "TEST"`). Mêmes erreurs `503` que l'ouverture du tiroir.

### Terminaux d'impression (ADMIN)

Chaque poste qui imprime a un terminal et un jeton (`pt_…`), distinct des PIN et révocable. Seule son empreinte est stockée.

| Route | Rôle |
|---|---|
| `GET /printing/terminals` | Liste : `id`, `name`, `revoked_at`, `last_seen_at`, `printer_status`, `created_at` |
| `POST /printing/terminals` `{"name": "Comptoir"}` | `201` : `{ "terminal": {…}, "token": "pt_…" }`. **Le jeton n'est montré qu'ici** ; `409 PRINT_TERMINAL_NAME_EXISTS` |
| `POST /printing/terminals/{id}/revoke` | L'agent est refusé dès sa prochaine interrogation. Sans effet si déjà révoqué |

Sur le serveur, sans passer par le front : `python -m caisse.cli create-print-terminal --name Comptoir`.

### Routes de l'agent (`/api/v1/print-agent`)

Réservées à l'agent du terminal (`Authorization: Bearer pt_…`), pas au front. `401 TERMINAL_TOKEN_INVALID` sans jeton valide.

| Route | Rôle |
|---|---|
| `POST /print-agent/poll` `{"printer": {"online", "paper", "model", "width"}}` | Se signale et prend le plus ancien travail en file : `{"job": null}` ou `{"job": {"id", "type", "content", "open_drawer", "cut", "is_reprint"}}`. Rien n'est confié si l'imprimante est rapportée hors ligne |
| `POST /print-agent/jobs/{id}/result` `{"printed", "error"}` | `204`. Même résultat renvoyé deux fois : sans effet ; `409 PRINT_JOB_NOT_CLAIMED` sinon |

Trace dans `audit_logs` : `print_job.print` (résultat rendu par l'agent), `print_job.retry`, `order.reprint`, `cash_session.reprint_z`, `printing.open_drawer_manual`, `printing.test`, `print_terminal.create`, `print_terminal.revoke`.

---

## 11. Stock

Préfixe : `/api/v1`. **Accès** : RESPONSABLE (le gestionnaire) pour toutes les routes de cette section ; un CAISSIER reçoit `403 INSUFFICIENT_PRIVILEGE`.

### Principe

| Notion | Ce qu'il faut savoir |
|---|---|
| **Article de stock** | Ce qu'on achète et qu'on compte (bœuf en kg, poulet à la pièce, Celeste 0,5 L à la bouteille, oignon, gaz…). Distinct du **produit** vendu en caisse. |
| **Fiche technique** | Ce qu'un produit consomme par portion : « Plat mouton » → 0,27 kg de mouton ; « Eau Celeste 0,5 L » → 1 bouteille. |
| **`out_mode`** | `RECIPE` : l'article sort **automatiquement** quand un plat qui le contient est encaissé (protéines, boissons). `INVENTORY` : pas de fiche, sa consommation se déduit des inventaires (légumes, condiments, gaz, emballages). |
| **Sortie automatique** | Quand une commande passe `PAID` (§8), chaque ligne déstocke les articles de sa fiche, dans la même transaction ; la réponse de paiement porte alors `STOCK_NEGATIVE_WARNING` dans `warnings[]` pour chaque article passé sous zéro. Si un paiement annulé la fait repasser `PARTIALLY_PAID`/`OPEN`, le stock revient (`RETURN_IN`). Un nouvel encaissement ressort le stock une seule fois. |
| **Stock négatif** | Permis : une vente n'est jamais bloquée. Il se voit dans `is_low` et dans le tableau de stock (§12). |
| **Coût moyen pondéré** (`avg_cost_xof`) | Recalculé à chaque entrée avec le prix payé. Les sorties, pertes et écarts sont valorisés à ce coût. |
| **Journée** (`business_date`) | Celle de la session de caisse ouverte, sinon aujourd'hui ; une saisie peut la préciser (achat de la veille, par exemple). |

Types de mouvement (`type`) :

| Type | Origine | `quantity` |
|---|---|---|
| `OPENING` | Premier comptage d'un article sans mouvement : **stock de départ**, jamais compté comme un écart | + |
| `PURCHASE_IN` | Entrée (achat), `POST /stock/receipts` | + |
| `SALE_OUT` | Encaissement d'un plat à fiche | − |
| `RETURN_IN` | Paiement annulé : remise en stock de la vente | + |
| `LOSS_OUT` | Perte déclarée, `POST /stock/losses` | − |
| `INVENTORY_COUNT` | Inventaire, `POST /stock/counts` : l'**écart** entre le compté et le théorique | ± |

### Charger les articles et les fiches du restaurant

Les CSV tirés des classeurs Excel (`src/caisse/seeds/data/`) se chargent en ligne de commande. Le menu d'abord, car les fiches techniques visent les produits par leur nom :

```bash
docker compose exec api python -m caisse.cli import-catalog                 # 40 plats et boissons
docker compose exec api python -m caisse.cli import-stock --stock-initial   # 115 articles, 35 fiches
```

`--stock-initial` saisit un stock de départ (`OPENING`) avec la colonne `stock_excel_13_10` (23 articles : protéines et boissons). **Sans** cette option, les articles partent de 0 : saisir alors un inventaire de départ avec `POST /stock/counts`. Les deux commandes ne recréent jamais ce qui existe déjà.

### Objet `article`

```json
{
  "id": "0c4e…", "name": "Bœuf", "category": "PROTEINE", "unit": "kg", "out_mode": "RECIPE",
  "quantity": 9.4, "avg_cost_xof": 4000.0, "value_xof": 37600,
  "alert_threshold": 3.0, "is_low": false, "is_active": true,
  "note": "fournisseur M. Yapi (4 000 F/kg)", "updated_at": "2026-10-16T12:04:10Z"
}
```

- `category` : `PROTEINE`, `BOISSON`, `EPICERIE`, `EMBALLAGE`, `ENTRETIEN`, `ENERGIE`.
- `value_xof` = `quantity` × `avg_cost_xof`, arrondi ; 0 si la quantité est négative.
- `is_low` : stock négatif, ou au plus égal à `alert_threshold`.

### `GET /stock/articles` — liste

Paramètres facultatifs : `category`, `search` (nom, contient), `is_active` (`true` par défaut, `false` : désactivés), `low_only` (`true` : seulement les articles en alerte). Réponse `200` : `{ "items": [article…], "next_cursor": null }`, par famille puis par nom.

### `POST /stock/articles` — créer

```json
{ "name": "Bœuf", "category": "PROTEINE", "unit": "kg", "out_mode": "RECIPE",
  "avg_cost_xof": 4000, "alert_threshold": 3, "note": null }
```

Réponse `201` : l'article, **à quantité 0**. `avg_cost_xof` (facultatif, 0 par défaut) est le coût de départ, remplacé par le prix de la première entrée si le stock est encore à 0.

| Code | Cas |
|---|---|
| `409 STOCK_ARTICLE_NAME_EXISTS` | Nom déjà pris, sans tenir compte de la casse (`meta.article_id`) |
| `422 VALIDATION_ERROR` | Champ manquant ou invalide |

### `GET /stock/articles/{id}` et `PATCH /stock/articles/{id}` — détail, modifier

`PATCH` ne change que les champs envoyés : `name`, `category`, `unit`, `out_mode`, `alert_threshold` (`null` retire l'alerte), `is_active`, `note`. **La quantité et le coût moyen ne se modifient jamais ici** : passer par une entrée, une perte ou un inventaire. Erreurs : `404 NOT_FOUND`, `409 STOCK_ARTICLE_NAME_EXISTS`.

### Saisies : entrées, pertes, inventaire

Les trois routes suivantes ont le même fonctionnement :

- **`Idempotency-Key` obligatoire.** Un rejeu renvoie la réponse d'origine en `200` avec `Idempotent-Replay: true`, sans second mouvement ; même clé avec un corps différent : `409 IDEMPOTENCY_CONFLICT`.
- `business_date` facultatif (voir le principe).
- Plusieurs articles par saisie, **chacun une seule fois** (sinon `422 VALIDATION_ERROR`).
- Article inconnu : `404 NOT_FOUND`, `meta.article_ids`. Rien n'est enregistré.
- Réponse `201` :

```json
{
  "movements": [
    { "id": "…", "article_id": "0c4e…", "article_name": "Bœuf", "type": "PURCHASE_IN",
      "quantity": 10.0, "quantity_after": 10.0, "unit_cost_xof": 4000.0, "value_xof": 40000,
      "business_date": "2026-10-16", "reference_order_id": null, "supplier": "M. Yapi",
      "reason": null, "user_id": "…", "created_at": "2026-10-16T12:04:10Z" }
  ],
  "articles": [ /* les articles touchés, après l'opération */ ],
  "warnings": [ { "code": "STOCK_NEGATIVE_WARNING", "detail": "Bœuf : stock -0.5", "meta": { "article_id": "…", "quantity": -0.5 } } ]
}
```

`STOCK_NEGATIVE_WARNING` signale un article passé sous zéro ; rien n'est bloqué.

#### `POST /stock/receipts` — entrée (achat)

```json
{
  "supplier": "M. Yapi",
  "lines": [
    { "article_id": "…bœuf", "quantity": 10, "total_cost_xof": 40000 },
    { "article_id": "…bissap", "quantity": 24, "unit_cost_xof": 250 }
  ]
}
```

Chaque ligne donne **soit** le montant payé (`total_cost_xof`), **soit** le prix d'une unité (`unit_cost_xof`), jamais les deux ni aucun (`422`). Le coût moyen est recalculé : 10 kg à 4 000 puis 5 kg à 4 600 donnent 15 kg à 4 200.

#### `POST /stock/losses` — perte

```json
{ "reason": "avarié", "lines": [ { "article_id": "…", "quantity": 1.5 } ] }
```

`reason` obligatoire (avarié, cassé, repas du personnel…). Valorisée au coût moyen.

#### `POST /stock/counts` — inventaire

```json
{ "reason": "pesée du lundi", "lines": [ { "article_id": "…", "counted_quantity": 8.5 } ] }
```

Le stock de chaque article **devient** la quantité comptée, et le mouvement porte l'écart. Exemple : stock théorique de 9 kg après les ventes, 8,5 kg comptés → `INVENTORY_COUNT` de −0,5 kg (2 000 F manquants). Pour un article `INVENTORY` (oignon, gaz), cet écart est sa consommation depuis le dernier comptage. Un écart nul est enregistré aussi : il date le dernier inventaire. Le **premier** comptage d'un article sans aucun mouvement est un `OPENING` (stock de départ).

### `GET /stock/movements` — journal

Paramètres facultatifs : `article_id`, `type`, `date_from`, `date_to` (journées incluses), `limit` (100 par défaut, 500 au plus). Réponse `200` : `{ "items": [mouvement…] }`, du plus récent au plus ancien. `reference_order_id` renvoie à la commande pour une vente ou une remise en stock.

### `GET /products/{id}/components` — fiche technique d'un plat

```json
{
  "product_id": "…", "product_name": "Plat bœuf", "price_xof": 3000,
  "components": [
    { "article_id": "…", "article_name": "Bœuf", "unit": "kg", "quantity": 0.2,
      "unit_cost_xof": 4000.0, "cost_xof": 800.0 }
  ],
  "cost_xof": 800.0, "margin_xof": 2200.0
}
```

Coût matière au coût moyen **actuel**. Erreurs : `404 NOT_FOUND`.

### `PUT /products/{id}/components` — remplacer la fiche

```json
{ "components": [ { "article_id": "…", "quantity": 0.2 } ] }
```

La fiche envoyée **remplace** l'ancienne ; `components: []` : le plat ne déstocke plus. Elle vaut pour les encaissements suivants ; les ventes passées gardent leurs mouvements. Réponse `200` : la fiche, au format du `GET`. Erreurs : `404 NOT_FOUND` (produit ou article inconnu), `422 VALIDATION_ERROR` (article présent deux fois, quantité ≤ 0).

Côté caisse, `GET /products` (§4) indique maintenant `track_stock: true` pour un produit qui a une fiche, et `stock_quantity` donne le **nombre de portions** encore vendables.

Trace dans `audit_logs` : `stock.article_create`, `stock.article_update`, `stock.receive`, `stock.loss`, `stock.count`, `stock.components_set`, `stock.import` (ligne de commande).

---

## 12. Tableaux de bord

Préfixe : `/api/v1/reports`. Lecture seule. **Accès** : tableau du jour pour le RESPONSABLE, tableaux de ventes et de stock pour l'ADMIN (M. Yapi).

### `GET /reports/dashboard?business_date=` — tableau de bord du jour

**Accès** : RESPONSABLE. `business_date` facultatif : par défaut, la journée en cours (session ouverte, sinon aujourd'hui).

```json
{
  "business_date": "2026-10-16",
  "revenue_xof": 9000, "orders_paid": 2, "orders_open": 1, "orders_cancelled": 1,
  "average_ticket_xof": 4500, "guests_count": 2, "dine_in_orders": 1, "takeaway_orders": 1,
  "tables_occupied": 1, "tables_total": 15,
  "payments": [ { "method": "MOBILE_MONEY", "provider": "WAVE", "count": 1, "amount_xof": 7000 },
                { "method": "CASH", "provider": null, "count": 1, "amount_xof": 2000 } ],
  "top_products": [ { "product_id": "…", "name": "Poisson braisé", "quantity": 2, "revenue_xof": 7000 } ],
  "hourly": [ { "hour": 12, "orders_count": 2, "revenue_xof": 9000 } ],
  "by_cashier": [ { "user_id": "…", "full_name": "Awa Koné", "orders_count": 2, "revenue_xof": 9000 } ],
  "sessions": [ { "id": "…", "cash_register": "Caisse 1", "status": "OPEN", "opened_by": "Awa Koné",
                  "opened_at": "2026-10-16T07:58:00Z", "closed_at": null, "z_number": null,
                  "variance_xof": null } ],
  "low_stock_articles": 3,
  "fne": { "certified": 0, "pending": 0 }
}
```

- Chiffre d'affaires, panier moyen, couverts, à table / à emporter, moyens de paiement, meilleures ventes, heures et caissiers : sur les commandes **soldées** de la journée.
- `hourly` : heure d'encaissement (Abidjan est à UTC), seulement les heures avec des ventes. `by_cashier` : la personne qui a **soldé** la commande.
- `tables_occupied` et `low_stock_articles` décrivent l'état **actuel**, quelle que soit la journée demandée.
- `403 INSUFFICIENT_PRIVILEGE` si l'utilisateur n'est pas RESPONSABLE.

### Tableaux de ventes et de stock

**Accès** : ADMIN (M. Yapi). Paramètres des deux routes : `date_from` et `date_to` (journées comptables incluses). Sans `date_to` : la journée en cours (session ouverte, sinon aujourd'hui) ; sans `date_from` : égale à `date_to`. Période de 366 jours au plus.

| Code | Cas |
|---|---|
| `403 INSUFFICIENT_PRIVILEGE` | Pas ADMIN |
| `422 VALIDATION_ERROR` | `date_from` après `date_to`, ou période trop longue |

### `GET /reports/sales` — tableau des ventes

Commandes **soldées** (`PAID`) dont la journée est dans la période.

```json
{
  "date_from": "2026-10-12", "date_to": "2026-10-16",
  "totals": {
    "revenue_xof": 845000, "orders_count": 214, "average_ticket_xof": 3949,
    "recipe_cost_xof": 352000, "recipe_margin_xof": 493000, "uncosted_revenue_xof": 21000,
    "inventory_consumption_xof": 118000, "stock_variance_xof": 6000, "gross_margin_xof": 369000
  },
  "by_day": [ { "business_date": "2026-10-12", "orders_count": 41, "revenue_xof": 172000,
                "recipe_cost_xof": 70100, "recipe_margin_xof": 101900 } ],
  "by_product": [ { "product_id": "…", "name": "Plat poulet", "category": "Viandes",
                    "quantity": 58, "revenue_xof": 174000, "has_recipe": true,
                    "recipe_cost_xof": 43500, "recipe_margin_xof": 130500 } ],
  "by_category": [ { "category": "Viandes", "quantity": 120, "revenue_xof": 381000,
                     "recipe_cost_xof": 150000, "recipe_margin_xof": 231000 } ],
  "by_payment_method": [ { "method": "CASH", "count": 180, "amount_xof": 700000 } ],
  "cash_sessions": [ { "id": "…", "business_date": "2026-10-12", "status": "CLOSED",
                       "z_number": 12, "expected_cash_xof": 160000,
                       "counted_cash_xof": 159500, "variance_xof": -500 } ]
}
```

| Champ | Calcul |
|---|---|
| `recipe_cost_xof` | Coût matière des fiches techniques, au coût moyen du **moment de la vente** |
| `uncosted_revenue_xof` | Chiffre d'affaires des produits **sans fiche** (accompagnements, thé…) : leur coût n'est pas dans `recipe_cost_xof` |
| `inventory_consumption_xof` | Ce que les inventaires et les pertes de la période font sortir pour les articles `INVENTORY` (légumes, gaz…) |
| `stock_variance_xof` | Manquants (inventaire) et pertes sur les articles `RECIPE` : ce qui a disparu sans être vendu. Négatif si l'inventaire trouve plus que prévu |
| `gross_margin_xof` | `revenue − recipe_cost − inventory_consumption − stock_variance`. Juste seulement avec des inventaires réguliers |

`by_product` et `by_category` sont triés par chiffre d'affaires décroissant ; les libellés sont ceux du moment de la vente.

### `GET /reports/stock` — tableau du stock

```json
{
  "date_from": "2026-10-12", "date_to": "2026-10-16",
  "totals": { "stock_value_xof": 1250000, "purchases_xof": 410000, "sales_cost_xof": 352000,
              "inventory_consumption_xof": 118000, "stock_variance_xof": 6000, "low_count": 3 },
  "articles": [
    { "article_id": "…", "name": "Bœuf", "category": "PROTEINE", "unit": "kg",
      "out_mode": "RECIPE", "opening_quantity": 0.0, "purchased_quantity": 10.0,
      "purchases_xof": 40000, "sold_quantity": 1.0, "loss_quantity": 0.0,
      "count_adjustment_quantity": -0.25, "closing_quantity": 8.75,
      "consumption_quantity": 1.25, "consumption_xof": 5000,
      "quantity": 8.75, "avg_cost_xof": 4000.0, "value_xof": 35000,
      "alert_threshold": 3.0, "is_low": false, "last_count_date": "2026-10-16" }
  ]
}
```

| Champ | Lecture |
|---|---|
| `opening_quantity` / `closing_quantity` | Stock au début et à la fin de la période (un stock de départ `OPENING` saisi pendant la période compte dans le début) |
| `sold_quantity` | Sorties par les ventes, nettes des remises en stock |
| `count_adjustment_quantity` | Écart d'inventaire : pour un article `RECIPE`, **stock compté − stock théorique** (le « rapport bœuf » de l'Excel) ; pour un article `INVENTORY`, sa consommation (signe −) |
| `consumption_quantity` | `opening + purchased − closing` : tout ce qui est sorti, quelle qu'en soit la raison |
| `quantity`, `avg_cost_xof`, `value_xof`, `is_low` | État **actuel**, quelle que soit la période |
| `last_count_date` | Dernier inventaire jusqu'à `date_to` (`null` : jamais compté) |

Tous les articles actifs apparaissent, plus les articles désactivés qui ont bougé dans la période ; par famille puis par nom.

---

## 13. Paramètres et caisses

Préfixe : `/api/v1`. **Accès** : lecture pour tout utilisateur connecté, modification réservée à l'**ADMIN**.

### `GET /settings` — paramètres de l'établissement

```json
{
  "restaurant_name": "RESTAURANT CHEZ SYLLA PLUS", "address": "Abidjan, Cocody",
  "phone": "0700000000", "ncc": "9506466A", "rccm": "",
  "receipt_footer": "Merci de votre visite", "default_vat_rate": 0.0,
  "cash_rounding_xof": 5, "cash_denominations_xof": [10000, 5000, 2000, 1000, 500],
  "payment_methods": ["CASH", "MOBILE_MONEY", "CARD", "BANK_TRANSFER", "CREDIT"],
  "screen_lock_timeout_seconds": 120,
  "fne_point_of_sale": "CAISSE-1", "fne_establishment": "RESTAURANT CHEZ SYLLA PLUS",
  "fne_walk_in_client": { "company_name": "CLIENT DIVERS", "phone": "0700000000", "email": "a@b.ci" }
}
```

| Champ | Usage |
|---|---|
| `restaurant_name`, `address`, `phone`, `ncc`, `rccm` | En-tête du ticket |
| `receipt_footer` | Pied du ticket |
| `default_vat_rate` | TVA des **nouveaux** produits (0 : régime TEE) |
| `cash_rounding_xof`, `cash_denominations_xof` | Arrondi des espèces, coupures du comptage de clôture |
| `payment_methods` | Moyens proposés à la caisse, dans l'ordre (`GET /payment-methods` les suit) |
| `screen_lock_timeout_seconds` | Verrouillage de l'écran du front ; 0 : jamais |
| `fne_*` | Paramétrage FNE (point de vente et établissement tels que dans l'espace FNE, client de passage des FNE B2C) |

### `PUT /settings` — modifier

**Accès** : ADMIN. **Seuls les champs envoyés changent** ; réponse `200` : tous les paramètres.

```json
{ "restaurant_name": "RESTAURANT CHEZ SYLLA PLUS", "ncc": "95 06466a" }
```

- `ncc` : 7 chiffres + 1 lettre (espaces et minuscules acceptés, normalisés) ou vide.
- `cash_denominations_xof` : positives, distinctes, remises dans l'ordre décroissant.
- `payment_methods` : au moins un, sans doublon. `OTHER` n'a pas de code FNE : une FNE payée ainsi est refusée.
- `default_vat_rate` ne change pas les produits existants (pour tous : `python -m caisse.cli set-vat-rate <taux> --all-products`).

Erreurs : `403 INSUFFICIENT_PRIVILEGE`, `422 VALIDATION_ERROR`. Trace dans `audit_logs` : `settings.update`, avec l'avant/après des champs modifiés.

### `GET /cash-registers` — caisses

**Accès** : connecté. Paramètre `is_active` (`true` par défaut, `false` : hors service).

```json
{ "items": [ { "id": "b3c4…", "name": "Caisse 1", "is_active": true,
               "open_session": { "id": "…", "business_date": "2026-10-16", "opened_by": "Awa Koné",
                                 "opened_at": "2026-10-16T07:58:00Z" } } ],
  "next_cursor": null }
```

L'`id` sert à ouvrir une session (`POST /cash-sessions`, §6) ; `open_session` vaut `null` si la caisse est fermée.

### `POST /cash-registers` et `PATCH /cash-registers/{id}` — créer, modifier

**Accès** : ADMIN. Corps : `{ "name": "Caisse Bar" }` ; `PATCH` accepte `name` et `is_active`. Mettre `is_active: false` retire la caisse du service (suppression logique). C'est refusé tant qu'une session y est ouverte. Une caisse hors service ne peut plus ouvrir de session.

| Code | Cas |
|---|---|
| `404 NOT_FOUND` | Caisse inconnue |
| `409 CASH_REGISTER_NAME_EXISTS` | Nom déjà pris, sans la casse (`meta.cash_register_id`) |
| `409 CASH_REGISTER_HAS_OPEN_SESSION` | Désactivation avec une session ouverte (`meta.session_id`) |

Trace dans `audit_logs` : `cash_register.create`, `cash_register.update`.

---

## 14. Scénario de test complet (curl + jq)

À lancer dans un terminal. Remplacer `ADMIN_PIN` par le PIN de l'administrateur créé avec `caisse.cli create-user`.

```bash
API=localhost:8001/api/v1
ADMIN_PIN=000000                                   # ← à remplacer

# 1. Santé
curl -s localhost:8001/health/ready | jq

# 2. Connexion admin
LOGIN=$(curl -s -X POST $API/auth/login -H 'Content-Type: application/json' \
  -d "{\"pin\":\"$ADMIN_PIN\",\"device_id\":\"poste-1\"}")
TOKEN=$(echo "$LOGIN" | jq -r .access_token)
REFRESH=$(echo "$LOGIN" | jq -r .refresh_token)
AUTH="Authorization: Bearer $TOKEN"
curl -s $API/auth/me -H "$AUTH" | jq

# 3. Rotation du refresh : le 2e appel doit renvoyer 401
curl -s -X POST $API/auth/refresh -H 'Content-Type: application/json' \
  -d "{\"refresh_token\":\"$REFRESH\"}" | jq '.user'
curl -s -X POST $API/auth/refresh -H 'Content-Type: application/json' \
  -d "{\"refresh_token\":\"$REFRESH\"}" | jq '{status, code}'

# 4. Créer un caissier et un responsable
CAISSIER_ID=$(curl -s -X POST $API/users -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"full_name":"Caissier Test","role":"CAISSIER","pin":"111111"}' | jq -r .id)
curl -s -X POST $API/users -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"full_name":"Resp Test","role":"RESPONSABLE","pin":"222222"}' | jq
# PIN déjà pris → 409 PIN_ALREADY_USED
curl -s -X POST $API/users -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"full_name":"Doublon","role":"CAISSIER","pin":"111111"}' | jq '{status, code}'

# 5. Droits : le caissier n'a pas accès à /users → 403
CT=$(curl -s -X POST $API/auth/login -H 'Content-Type: application/json' \
  -d '{"pin":"111111","device_id":"poste-1"}' | jq -r .access_token)
curl -s $API/users -H "Authorization: Bearer $CT" | jq '{status, code, meta}'

# 6. Override demandé par le caissier
#    PIN du responsable → 200 ; PIN du caissier → 403 OVERRIDE_REQUIRED
curl -s -X POST $API/auth/override -H "Authorization: Bearer $CT" -H 'X-Device-Id: poste-1' \
  -H 'Content-Type: application/json' -d '{"pin":"222222","action":"order.cancel"}' | jq
curl -s -X POST $API/auth/override -H "Authorization: Bearer $CT" -H 'X-Device-Id: poste-1' \
  -H 'Content-Type: application/json' -d '{"pin":"111111","action":"order.cancel"}' \
  | jq '{status, code}'

# 7. Catalogue et salle (avec le jeton du caissier)
curl -s $API/categories -H "Authorization: Bearer $CT" | jq '.items[] | {name, kind}'
curl -s "$API/products?search=jus" -H "Authorization: Bearer $CT" \
  | jq '.items[] | {name, price_xof, stock_quantity}'
curl -s $API/tables/board -H "Authorization: Bearer $CT" | jq '{business_date, summary, n: (.tables | length)}'

# 8. Session de caisse (avec le jeton du caissier)
#    bootstrap crée « Caisse 1 » : la première caisse en service
REGISTER_ID=$(curl -s $API/cash-registers -H "Authorization: Bearer $CT" | jq -r '.items[0].id')
KEY=$(cat /proc/sys/kernel/random/uuid)
curl -s -X POST $API/cash-sessions -H "Authorization: Bearer $CT" -H "Idempotency-Key: $KEY" \
  -H 'Content-Type: application/json' -d "{\"cash_register_id\":\"$REGISTER_ID\",\"opening_float_xof\":20000}" \
  | tee /tmp/session.json | jq
SESSION_ID=$(jq -r .id /tmp/session.json)
curl -s $API/tables/board -H "Authorization: Bearer $CT" | jq '.business_date'   # non nul désormais

# rejeu de la même clé → 200 + Idempotent-Replay: true, corps identique
curl -si -X POST $API/cash-sessions -H "Authorization: Bearer $CT" -H "Idempotency-Key: $KEY" \
  -H 'Content-Type: application/json' -d "{\"cash_register_id\":\"$REGISTER_ID\",\"opening_float_xof\":20000}" \
  | grep -i -E '^HTTP|Idempotent-Replay'

# mouvement de tiroir puis rapport X
curl -s -X POST $API/cash-sessions/$SESSION_ID/movements -H "Authorization: Bearer $CT" \
  -H 'Content-Type: application/json' -d '{"type":"OUT","amount_xof":2000,"reason":"achat glace"}' | jq
curl -s $API/cash-sessions/$SESSION_ID/x-report -H "Authorization: Bearer $CT" | jq '.expected_cash_xof'
# → 18000 (20000 - 2000)

# 9. Commandes (menu et tables de démo : caisse.cli seed --demo)
TABLE_1=$(curl -s $API/tables -H "Authorization: Bearer $CT" | jq -r '.items[0].id')
POISSON=$(curl -s "$API/products?search=poisson" -H "Authorization: Bearer $CT" | jq -r '.items[0].id')
ATTIEKE=$(curl -s "$API/products?search=atti" -H "Authorization: Bearer $CT" | jq -r '.items[0].id')
ORDER_ID=$(curl -s -X POST $API/orders -H "Authorization: Bearer $CT" -H 'Content-Type: application/json' \
  -d "{\"table_id\":\"$TABLE_1\",\"guests_count\":4}" | jq -r .order.id)
curl -s -X POST $API/orders/$ORDER_ID/items -H "Authorization: Bearer $CT" -H 'Content-Type: application/json' \
  -d "{\"product_id\":\"$POISSON\",\"quantity\":2,\"note\":\"bien cuit\"}" | jq '.order | {total_ttc_xof, total_ht_xof, total_vat_xof}'
ITEM_ID=$(curl -s -X POST $API/orders/$ORDER_ID/items -H "Authorization: Bearer $CT" -H 'Content-Type: application/json' \
  -d "{\"product_id\":\"$ATTIEKE\"}" | jq -r '.order.items[-1].id')
# table occupée : 2e commande refusée, plan de salle à jour
curl -s -X POST $API/orders -H "Authorization: Bearer $CT" -H 'Content-Type: application/json' \
  -d "{\"table_id\":\"$TABLE_1\"}" | jq '{status, code, meta}'
curl -s $API/tables/board -H "Authorization: Bearer $CT" | jq '.tables[0] | {label, status, order}'

# retrait d'une ligne par le caissier, motif obligatoire (sans motif → 422)
curl -s -X DELETE "$API/orders/$ORDER_ID/items/$ITEM_ID" -H "Authorization: Bearer $CT" | jq '{status, code}'
curl -s -X DELETE "$API/orders/$ORDER_ID/items/$ITEM_ID?reason=erreur%20de%20saisie" \
  -H "Authorization: Bearer $CT" | jq '.order | {total_ttc_xof, n: (.items | length)}'

# vente à emporter : Comptoir n° 1
curl -s -X POST $API/orders -H "Authorization: Bearer $CT" -H 'Content-Type: application/json' \
  -d '{"table_id":null}' | jq '.order | {order_number, counter_number}'

# 10. Encaissement de la table 1 (reste dû : 7 000) : espèces avec rendu, puis Wave
curl -s $API/payment-methods -H "Authorization: Bearer $CT" | jq -c '.[] | {method, providers}'
PAY_KEY=$(cat /proc/sys/kernel/random/uuid)
curl -s -X POST $API/orders/$ORDER_ID/payments -H "Authorization: Bearer $CT" -H "Idempotency-Key: $PAY_KEY" \
  -H 'Content-Type: application/json' -d '{"method":"CASH","amount_xof":5000,"tendered_xof":10000}' \
  | jq '{change: .payment.change_xof, status: .order.status, due: .order.due_xof}'
# → change 5000, PARTIALLY_PAID, due 2000
# rejeu de la même clé → 200 + Idempotent-Replay: true, aucun second paiement
curl -si -X POST $API/orders/$ORDER_ID/payments -H "Authorization: Bearer $CT" -H "Idempotency-Key: $PAY_KEY" \
  -H 'Content-Type: application/json' -d '{"method":"CASH","amount_xof":5000,"tendered_xof":10000}' \
  | grep -i -E '^HTTP|Idempotent-Replay'
# plus que le reste dû → 422 PAYMENT_EXCEEDS_DUE
curl -s -X POST $API/orders/$ORDER_ID/payments -H "Authorization: Bearer $CT" \
  -H "Idempotency-Key: $(cat /proc/sys/kernel/random/uuid)" -H 'Content-Type: application/json' \
  -d '{"method":"CARD","amount_xof":3000}' | jq '{status, code, meta}'
curl -s -X POST $API/orders/$ORDER_ID/payments -H "Authorization: Bearer $CT" \
  -H "Idempotency-Key: $(cat /proc/sys/kernel/random/uuid)" -H 'Content-Type: application/json' \
  -d '{"method":"MOBILE_MONEY","provider":"WAVE","amount_xof":2000,"reference":"TX8812"}' \
  | jq '.order | {status, paid_xof, due_xof, paid_at}'
# → PAID ; la table 1 est libérée
curl -s $API/tables/board -H "Authorization: Bearer $CT" | jq '{summary, table1: (.tables[0] | {label, status})}'

# la vente à emporter vide est annulée par le responsable
RT=$(curl -s -X POST $API/auth/login -H 'Content-Type: application/json' \
  -d '{"pin":"222222","device_id":"poste-1"}' | jq -r .access_token)
for ID in $(curl -s "$API/orders?status=OPEN" -H "Authorization: Bearer $CT" | jq -r '.items[].id'); do
  curl -s -X POST $API/orders/$ID/cancel -H "Authorization: Bearer $RT" -H 'Content-Type: application/json' \
    -d '{"reason":"test"}' | jq -c '.order | {order_number, status}'
done
curl -s $API/cash-sessions/$SESSION_ID/x-report -H "Authorization: Bearer $CT" \
  | jq '{expected_cash_xof, by_method: .totals.by_payment_method, controls: .totals.controls}'
# → expected_cash_xof 23000 (20000 − 2000 + 5000), CASH 5000 + MOBILE_MONEY 2000,
#   cancelled_orders: 1, removed_items: 1

# clôture : Z n°1, écart nul si le comptage correspond
curl -s -X POST $API/cash-sessions/$SESSION_ID/close -H "Authorization: Bearer $CT" \
  -H "Idempotency-Key: $(cat /proc/sys/kernel/random/uuid)" -H 'Content-Type: application/json' \
  -d '{"counted_breakdown":{"10000":2,"2000":1,"1000":1},"notes":"RAS"}' | jq

# 11. Désactiver le caissier : son jeton est aussitôt refusé (401)
curl -s -X PATCH $API/users/$CAISSIER_ID -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"is_active":false}' | jq '{full_name, is_active}'
curl -s $API/auth/me -H "Authorization: Bearer $CT" | jq '{status, code}'

# 12. Blocage progressif sur un poste dédié : 4 × 401 puis 423
for i in 1 2 3 4 5; do
  curl -s -X POST $API/auth/login -H 'Content-Type: application/json' \
    -d '{"pin":"999999","device_id":"poste-test"}' | jq -c '{status, code, meta}'
done
```

Pour vérifier l'audit après le scénario :

```bash
docker exec infra-db sh -c 'psql -U "$POSTGRES_USER" -d caisse -c \
  "select created_at, action, entity from audit_logs order by created_at desc limit 20"'
```

> Le scénario laisse deux utilisateurs de test en base, dont un désactivé, plus une session de caisse clôturée, une commande soldée et une annulée. Comme les PIN doivent être uniques et qu'il ne peut y avoir qu'une session ouverte à la fois, relancer le scénario tel quel renverra `409` à l'étape 4 pour « Resp Test » (la session, elle, sera déjà clôturée et ne bloque rien). Changer les PIN avant de le relancer.

---

## 15. Pas encore testable

| Lot | Routes du contrat absentes |
|---|---|
| L4 | `POST /orders/{id}/refunds` (remboursement d'une commande soldée, reporté : rare au restaurant) |
| L6 | `GET /fne/daily-summary/{id}/export` (export du récapitulatif figé à la clôture), worker de renvoi automatique (le renvoi FNE/impression reste manuel pour l'instant) |
| L5–L6 | `GET /reports/audit` (les tableaux du jour, des ventes et du stock sont là : §12) |
