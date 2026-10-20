# Circuit de test de la caisse — pas à pas dans Swagger

Une journée de caisse complète, de l'ouverture à la clôture, en ~65 appels. Chaque étape donne **ce qu'il faut envoyer** et **ce qu'on doit obtenir**. Si le résultat diffère, s'arrêter et noter l'étape.

Durée : 55 min environ. Détail de chaque route : [`ENDPOINTS-TESTABLES.md`](ENDPOINTS-TESTABLES.md).

---

## Avant de commencer

**Prérequis** (déjà en place sur la base de dev au 02/10/2026) : API démarrée, `caisse.cli bootstrap` et `caisse.cli seed --demo` passés (13 produits, 15 tables), un compte ADMIN dont vous connaissez le PIN, **aucune session de caisse ouverte**.

**Swagger** : http://localhost:8001/docs

**Utiliser une route** : la déplier → **Try it out** → remplir → **Execute** → lire `Code` et `Response body` juste en dessous.

**S'authentifier** : après chaque connexion, copier l'`access_token` de la réponse → bouton **Authorize** (cadenas, en haut) → **Logout** s'il y a déjà un jeton → coller le jeton **sans** le mot `Bearer` → **Authorize** → **Close**.

**Le jeton dure 15 min.** Si une réponse renvoie `401 TOKEN_EXPIRED`, refaire `POST /auth/login` et recoller le jeton.

**`Idempotency-Key`** : un champ texte libre à remplir sur certaines routes. Utiliser la valeur indiquée dans l'étape : changer de valeur = nouvelle opération ; réutiliser la même = rejeu (voir étapes 10 et 25).

**`X-Device-Id`** : facultatif ; mettre `poste-1` partout où le champ apparaît.

**Bloc-notes** : garder un fichier texte ouvert pour y coller les identifiants au fur et à mesure :

```
CAISSE      = 01a0d401-3fc5-710d-9436-4b9a236ca97b   (Caisse 1 de la base de dev ; sinon `GET /cash-registers`)
SESSION     =
TABLE_1     =
POISSON     =   (Poisson braisé, 3 500)
ATTIEKE     =   (Attiéké, 1 000)
SUCRERIE    =   (Sucrerie 33cl, 500)
POULET      =   (Poulet braisé, 4 000)
BISSAP      =   (Jus de bissap, 1 000)
O1, O2, O3  =   (commandes)
```

> Si l'id de la caisse ne correspond pas (autre base), le récupérer avec :
> `docker exec infra-db sh -c 'psql -U "$POSTGRES_USER" -d caisse -tAc "select id from cash_registers"'`

---

## A. Comptes et droits

| # | Route | Envoyer | Attendu |
|---|---|---|---|
| 1 | `POST /auth/login` | `{"pin": "<PIN ADMIN>", "device_id": "poste-1"}` | `200`, `user.role: "ADMIN"`, `open_session: null`. **Authorize** avec ce jeton. |
| 2 | `POST /users` | `{"full_name": "Caissier Test", "role": "CAISSIER", "pin": "131313"}` | `201`. (`409 PIN_ALREADY_USED` → choisir un autre PIN et le reporter dans la suite.) |
| 3 | `POST /users` | `{"full_name": "Resp Test", "role": "RESPONSABLE", "pin": "242424"}` | `201` |
| 4 | `POST /auth/login` | `{"pin": "131313", "device_id": "poste-1"}` | `200`, `role: "CAISSIER"`. **Authorize** avec ce jeton : **toute la suite se fait en caissier.** |
| 5 | `GET /users` | — | `403 INSUFFICIENT_PRIVILEGE` : un caissier ne gère pas les comptes. |

## B. Ouverture de caisse

| # | Route | Envoyer | Attendu |
|---|---|---|---|
| 6 | `GET /cash-sessions/current` | — | `409 NO_OPEN_SESSION` |
| 7 | `POST /orders` | `{"table_id": null}` | `409 NO_OPEN_SESSION` : pas de vente sans caisse ouverte. |
| 8 | `POST /cash-sessions` | `Idempotency-Key: ouverture-1` ; `{"cash_register_id": "<CAISSE>", "opening_float_xof": 20000}` | `201`, `status: "OPEN"`, `business_date` du jour. Noter `id` → **SESSION**. |
| 9 | `GET /cash-sessions/current` | — | `200`, la même session. |
| 10 | `POST /cash-sessions` | **Même** clé `ouverture-1`, **même** corps | `200` (et non `201`), en-tête `idempotent-replay: true` dans *Response headers*, **même `id`** : rien n'a été ouvert une seconde fois. |
| 11 | `POST /cash-sessions` | Même clé `ouverture-1`, `opening_float_xof: 30000` | `409 IDEMPOTENCY_CONFLICT` : même clé, corps différent. |
| 12 | `POST /cash-sessions/{SESSION}/movements` | `{"type": "OUT", "amount_xof": 2000, "reason": "achat glace"}` | `201` |
| 13 | `GET /cash-sessions/{SESSION}/x-report` | — | `expected_cash_xof: 18000` (20 000 − 2 000), totaux à 0. |

## C. Salle et prise de commande

| # | Route | Envoyer | Attendu |
|---|---|---|---|
| 14 | `GET /tables/board` | — | 15 tables `FREE`, `business_date` renseignée. Noter l'`id` de la table « 1 » → **TABLE_1**. |
| 15 | `GET /products` | `search` = `poisson`, puis `atti`, `sucrerie`, `poulet`, `bissap` | Noter les 5 `id` dans le bloc-notes. Tous à `vat_rate: 0.0` (régime TEE). |
| 16 | `POST /orders` | `{"table_id": "<TABLE_1>", "guests_count": 3}` | `201`, `status: "OPEN"`, `counter_number: null`, `items: []`, `payments: []`. Noter `order.id` → **O1**. |
| 17 | `POST /orders/{O1}/items` | `{"product_id": "<POISSON>", "quantity": 2, "note": "bien cuit"}` | `total_ttc_xof: 7000`, `total_vat_xof: 0` |
| 18 | `POST /orders/{O1}/items` | `{"product_id": "<ATTIEKE>", "quantity": 2}` | `total_ttc_xof: 9000`. Noter l'`id` de cette ligne (dans `items`). |
| 19 | `POST /orders/{O1}/items` | `{"product_id": "<SUCRERIE>", "quantity": 3}` | `total_ttc_xof: 10500`. Noter l'`id` de cette ligne. |
| 20 | `POST /orders` | `{"table_id": "<TABLE_1>"}` | `409 TABLE_ALREADY_OCCUPIED`, `meta.order_id` = **O1** |
| 21 | `PATCH /orders/{O1}/items/{ligne sucrerie}` | `{"quantity": 2}` | `total_ttc_xof: 10000` |
| 22 | `DELETE /orders/{O1}/items/{ligne attiéké}` | `reason` vide | Swagger refuse d'envoyer (champ requis en rouge) : le motif est obligatoire. L'API renverrait `422 VALIDATION_ERROR`. |
| 23 | `DELETE /orders/{O1}/items/{ligne attiéké}` | `reason` = `erreur de saisie` | `total_ttc_xof: 8000`, plus que 2 lignes. |
| 24 | `GET /tables/board` | — | Table 1 `OCCUPIED`, total 8 000 ; `summary.open_orders: 1`. |

## D. Encaissement partiel puis mixte (O1 : 8 000)

| # | Route | Envoyer | Attendu |
|---|---|---|---|
| 25 | `GET /payment-methods` | — | 5 moyens : `CASH` (`gives_change: true`), `MOBILE_MONEY` (4 opérateurs), `CARD`, `BANK_TRANSFER`, `CREDIT`. |
| 26 | `POST /orders/{O1}/payments` | `Idempotency-Key: paiement-1` ; `{"method": "CASH", "amount_xof": 5000, "tendered_xof": 10000}` | `201` ; `payment.change_xof: 5000` (monnaie à rendre) ; `order.status: "PARTIALLY_PAID"`, `paid_xof: 5000`, `due_xof: 3000` ; `receipt: null`, `fiscal_document: null`. |
| 27 | `POST /orders/{O1}/payments` | **Même** clé `paiement-1`, **même** corps | `200`, `idempotent-replay: true`, **même `payment.id`**. |
| 28 | `GET /orders/{O1}` | — | **Un seul** paiement dans `payments` : le rejeu n'a rien encaissé. |
| 29 | `POST /orders/{O1}/payments` | `paiement-2` ; `{"method": "CARD", "amount_xof": 4000}` | `422 PAYMENT_EXCEEDS_DUE`, `meta: {"due_xof": 3000, "amount_xof": 4000}` |
| 30 | `POST /orders/{O1}/payments` | `paiement-3` ; `{"method": "MOBILE_MONEY", "amount_xof": 3000}` | `422 VALIDATION_ERROR` : opérateur manquant. |
| 31 | `POST /orders/{O1}/payments` | `paiement-4` ; `{"method": "CARD", "amount_xof": 1000, "tendered_xof": 2000}` | `422 VALIDATION_ERROR` : somme remise réservée aux espèces. |
| 32 | `DELETE /orders/{O1}/items/{ligne poisson}` | `reason` = `test` | `409 ORDER_NOT_EDITABLE`, `meta.reason: "total_below_paid"` : le total (1 000) passerait sous les 5 000 déjà encaissés. |
| 33 | `POST /orders/{O1}/payments` | `paiement-5` ; `{"method": "MOBILE_MONEY", "provider": "WAVE", "amount_xof": 3000, "reference": "TX8812"}` | `201` ; `order.status: "PAID"`, `due_xof: 0`, `paid_at` renseigné, 2 paiements. **`receipt`** cette fois rempli : `{print_job_id, status: "QUEUED", drawer_opened: null}` (ticket mis en file ; l'agent du terminal l'imprime et ouvre le tiroir, sans jamais bloquer la vente). Noter `receipt.print_job_id` → **JOB_O1**. |
| 34 | `POST /orders/{O1}/items` | `{"product_id": "<SUCRERIE>"}` | `409 ORDER_NOT_EDITABLE` : commande soldée, figée. |
| 35 | `GET /tables/board` | — | Table 1 de nouveau `FREE` ; `summary.revenue_today_xof: 8000`, `orders_count: 1`, `open_orders: 0`. |

## E. Corriger un paiement saisi par erreur (vente à emporter)

Cas : le client a payé en espèces, la caissière a cliqué sur « Carte ».

| # | Route | Envoyer | Attendu |
|---|---|---|---|
| 36 | `POST /orders` | `{"table_id": null}` | `201`, `counter_number: 1` (« Comptoir n° 1 »). Noter → **O2**. |
| 37 | `POST /orders/{O2}/items` | `{"product_id": "<POULET>"}` | `total_ttc_xof: 4000` |
| 38 | `POST /orders/{O2}/payments` | `paiement-6` ; `{"method": "CARD", "amount_xof": 4000}` | `201`, `PAID`. Noter `payment.id` → **P_CARTE**. |
| 39 | `DELETE /orders/{O2}/payments/{P_CARTE}` | `reason` = `erreur de moyen`, sans `X-Override-Token` | `403 OVERRIDE_REQUIRED` : un caissier ne peut pas annuler seul. |
| 40 | `POST /auth/override` | `{"pin": "242424", "action": "payment.void"}` | `200`, `override_token`, `granted_by: Resp Test`. **Copier le jeton : il expire en 60 s.** |
| 41 | `DELETE /orders/{O2}/payments/{P_CARTE}` | `reason` = `erreur de moyen` ; `X-Override-Token` = le jeton | `200` ; `order.status: "OPEN"`, `paid_xof: 0`, `due_xof: 4000` ; le paiement est toujours là avec `status: "VOIDED"` et `void_reason`. (`403` avec `reason: "expired"` → refaire l'étape 40, plus vite.) |
| 42 | `DELETE /orders/{O2}/payments/{P_CARTE}` | Même chose, sans jeton | `409 PAYMENT_NOT_VOIDABLE`, `meta.reason: "already_voided"` |
| 43 | `POST /orders/{O2}/payments` | `paiement-7` ; `{"method": "CASH", "amount_xof": 4000, "tendered_xof": 5000}` | `201`, `PAID`, `change_xof: 1000` ; `payments` : la carte `VOIDED` puis les espèces `CAPTURED`. `receipt` rempli (voir étape 33). |

## F. FNE (mode manuel)

Avec `FNE_PROVIDER=manual` (réglage actuel du `.env`), aucun appel à la DGI : le document est marqué « à saisir dans l'application FNE ».

| # | Route | Envoyer | Attendu |
|---|---|---|---|
| 44 | `POST /orders/{O1}/fne` | `{}` | `201`, `document.status: "MANUAL"`, `type: "FNE"`, `template: "B2C"`. Noter `document.id`. |
| 45 | `POST /orders/{O1}/fne` | `{}` | `200` (et non `201`), **même `document.id`** : un double clic ne crée jamais deux FNE. |
| 46 | `GET /orders/{O1}/fne` | — | Le même document. |

## G. Commande entamée puis annulée, et clôture bloquée

| # | Route | Envoyer | Attendu |
|---|---|---|---|
| 47 | `POST /orders` | `{"table_id": null}` | `counter_number: 2`. Noter → **O3**. |
| 48 | `POST /orders/{O3}/items` | `{"product_id": "<BISSAP>"}` | `total_ttc_xof: 1000` |
| 49 | `POST /orders/{O3}/payments` | `paiement-8` ; `{"method": "CASH", "amount_xof": 500}` | `PARTIALLY_PAID`, `due_xof: 500`. Noter `payment.id` → **P_O3**. |
| 50 | `POST /orders/{O3}/fne` | `{}` | `409 FNE_ORDER_NOT_PAID` |
| 51 | `POST /cash-sessions/{SESSION}/close` | `cloture-0` ; `{"counted_breakdown": {"10000": 1}}` | `409 SESSION_HAS_OPEN_ORDERS`, `meta.open_orders` contient **O3**. |
| 52 | `POST /orders/{O3}/cancel` | `{"reason": "client parti"}` | `409 ORDER_NOT_EDITABLE`, `meta.reason: "has_payments"` : annuler d'abord le paiement. |
| 53 | `POST /auth/override` puis `DELETE /orders/{O3}/payments/{P_O3}` | `{"pin": "242424", "action": "payment.void"}` ; puis `reason` = `client parti` + jeton | `200`, `status: "OPEN"`, `paid_xof: 0` |
| 54 | `POST /auth/override` puis `POST /orders/{O3}/cancel` | `{"pin": "242424", "action": "order.cancel"}` ; puis `{"reason": "client parti"}` + jeton | `200`, `status: "CANCELLED"`. (Un jeton `payment.void` ne marche pas ici : il est lié à son action.) |

## H. Clôture de la journée

| # | Route | Envoyer | Attendu |
|---|---|---|---|
| 55 | `GET /cash-sessions/{SESSION}/x-report` | — | Voir le tableau ci-dessous. |
| 56 | `POST /cash-sessions/{SESSION}/close` | `cloture-1` ; `{"counted_breakdown": {"10000": 2, "5000": 1, "2000": 1}, "notes": "RAS"}` | `201`, `z_number: 1`, `counted_cash_xof: 27000`, `expected_cash_xof: 27000`, **`variance_xof: 0`**. `print_job_id` rempli (ticket Z mis en file, pas de tiroir). Noter → **JOB_Z**. |
| 57 | `GET /cash-sessions/{SESSION}/z-report` | — | Les mêmes chiffres, figés. **Même `print_job_id`** que l'étape 56 : le Z ne s'imprime qu'une fois. |
| 58 | `POST /orders` | `{"table_id": null}` | `409 NO_OPEN_SESSION` |
| 59 | `DELETE /orders/{O1}/payments/{un paiement de O1}` | `reason` = `test` | `409 PAYMENT_NOT_VOIDABLE`, `meta.reason: "session_closed"` : après le Z, plus rien ne bouge. |

**Rapport X attendu à l'étape 55 :**

| Champ | Valeur | Pourquoi |
|---|---|---|
| `expected_cash_xof` | **27 000** | 20 000 de fond − 2 000 de sortie + 5 000 (O1) + 4 000 (O2). La somme remise et les paiements annulés ne comptent pas. |
| `totals.gross_ttc_xof` | 12 000 | O1 (8 000) + O2 (4 000) ; O3 est annulée |
| `totals.vat_xof` | 0 | Régime TEE |
| `totals.orders_count` | 2 | Commandes soldées |
| `totals.by_payment_method` | `CASH` 9 000 (2), `MOBILE_MONEY` 3 000 (1) | La carte d'O2 et les espèces d'O3 ont été annulées |
| `totals.controls` | `cancelled_orders: 1`, `removed_items: 1`, `reprints: 0` | O3 ; l'attiéké retiré à l'étape 23 |

Pour tester un **écart de caisse**, compter 26 500 à l'étape 56 (`{"10000": 2, "5000": 1, "1000": 1, "500": 1}`) : `variance_xof: -500`. On ne peut clôturer qu'une fois : choisir l'un ou l'autre.

## I. Impression

Fonctionne après la clôture : les routes ne dépendent pas d'une session ouverte.

| # | Route | Envoyer | Attendu |
|---|---|---|---|
| 60 | `GET /printing/status` | — | `200`, `queued_jobs` et `failed_jobs` reflètent la file ; `agent_online`/`printer_online` selon l'agent qui interroge l'API (`false` sans agent lancé — normal, voir `print-agent/README.md` pour le mode factice et le jeton de terminal). |
| 61 | `GET /printing/jobs` | — | Au moins 3 travaux `RECEIPT` (**JOB_O1** et celui d'O2) et 1 `Z_REPORT` (**JOB_Z**), avec leur `status`. |
| 62 | `POST /orders/{O1}/reprint` | — | `200`, commande renvoyée. Un nouveau travail `RECEIPT` apparaît dans `GET /printing/jobs`, `is_reprint: true`, **n'ouvre pas le tiroir**. Compté dans `controls.reprints` (relire le rapport Z de l'étape 57 : `controls.reprints` passe à 1 si on le relit après coup — en fait figé à la clôture, donc visible seulement sur une future clôture). |
| 63 | `POST /orders/{O3}/reprint` | — | `409 NO_RECEIPT_TO_REPRINT` : O3 a été annulée sans jamais être soldée, donc jamais imprimée. |
| 64 | `POST /printing/jobs/{JOB_O1}/retry` | — | `409 PRINT_JOB_NOT_RETRYABLE` : **JOB_O1** est `DONE` si l'agent l'a imprimé, ou encore `QUEUED` sans agent (il attend déjà en file). Seul un travail `FAILED` se rejoue (imprimante en panne pendant l'impression). |
| 65 | `POST /printing/open-drawer` | En caissier (jeton de l'étape 4 toujours actif) | `403 INSUFFICIENT_PRIVILEGE` : réservé au RESPONSABLE. Se reconnecter avec le PIN `242424`, puis réessayer → `202`, travail `DRAWER` en file (ou `503 PRINT_AGENT_UNAVAILABLE` si aucun agent ne s'est signalé depuis 15 s). |

---

## Vérifier la trace d'audit

```bash
docker exec infra-db sh -c 'psql -U "$POSTGRES_USER" -d caisse -c \
  "select created_at, action, entity, reason from audit_logs order by created_at desc limit 30"'
```

On doit y voir notamment `payment.create`, `payment.void` (avec le motif), `order.item_remove`, `order.cancel`, `auth.override_granted`, `fne.issue`, `cash_session.close`, `order.reprint`, `print_job.print` (résultat rendu par l'agent), `printing.open_drawer_manual`.

## Rejouer le circuit

Les PIN 131313 et 242424 sont maintenant pris : le relancer avec d'autres PIN (ou sauter les étapes 2-3 et se connecter directement avec ceux-là). La session du jour étant clôturée, l'étape 8 renverra `409 BUSINESS_DATE_MISMATCH` : rejouer avec `"confirm_business_date": true` dans le corps (et une nouvelle clé).
