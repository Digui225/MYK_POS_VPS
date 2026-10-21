# Plan d'implémentation — FNE (Facture Normalisée Électronique, DGI Côte d'Ivoire)

Référence : *Procédure d'interfaçage des entreprises par API*, DGI, mai 2025.
Document vivant : on coche, on corrige et on note les découvertes au fil de l'intégration.

## 0. Rappel de l'API

| | |
|---|---|
| URL test | `http://54.247.95.108/ws` (URL de prod transmise par la DGI après validation) |
| Auth | `Authorization: Bearer <API KEY>` (onglet « Paramétrage » de l'espace FNE) |
| Vente | `POST {url}/external/invoices/sign` — `invoiceType: "sale"` |
| Avoir | `POST {url}/external/invoices/{invoice.id}/refund` — `items: [{id, quantity}]` |
| Réponse | `reference` (n° FNE), `token` (URL de vérification → QR), `balance_funds` (solde en XOF ; la procédure disait `balance_sticker`), `warning`, `invoice` (avec `id` et `items[].id`) |
| Erreurs | 400 requête invalide (détail par champ dans `errors`), 401 clé invalide, 500 erreur serveur (**peut laisser une facture créée**) |
| Établissement | `RESTAURANT CHEZ SYLLA PLUS` |

## 1. Décisions de conception

| # | Décision | Statut |
|---|---|---|
| D1 | **Quand émettre** : **à la demande** via `POST /orders/{id}/fne`, sur une commande soldée. Pas de certification automatique à l'encaissement : `fiscal_document` vaut `null` dans la réponse de paiement (écart avec l'exemple v1.1 du contrat §4.6, à signaler au front) | **décidé** 01/10 |
| D2 | **Prix HT** : `amount` = prix unitaire HT calculé depuis le TTC. On envoie un HT décimal (4 décimales) si l'API l'accepte, sinon arrondi entier ; l'écart TTC caisse ↔ TTC FNE est stocké et surveillé | à valider en sonde (phase 1) |
| D3 | **Codes TVA** : 18 → `TVA`, 9 → `TVAB`, 0 → `TVAD`. Un seul code par article (exigé par l'API). **Régime TEE confirmé (01/10)** : taux par défaut 0 % (`vat.default_rate`), tous les articles partent en `TVAD` ; `cli set-vat-rate 0 --all-products` pour une base existante | **décidé** 01/10 |
| D9 | `clientSellerName` = nom du caissier connecté (rempli sur les vraies FNE du restaurant) ; `measurementUnit` = `U` ; `reference` = code produit | proposé |
| D10 | **Impression** : la FNE est remise en **A4** (pratique du restaurant). Pas de FNE sur le ticket 80 mm : la caisse expose le lien de vérification FNE (`token`) que le front ouvre pour impression A4 ; le ticket de caisse peut mentionner le n° FNE. À vérifier en test : la page de vérification s'imprime-t-elle en A4 complet ? Imprimante A4 au poste de caisse ? | **décidé** 01/10 (A4) |
| D11 | Point de vente et établissement = **paramètres** (`fne.point_of_sale`) : `CAISSE-1` en test, « Service Facturation » en production | proposé |
| D4 | **Moyen de paiement** : CASH→`cash`, CARD→`card`, MOBILE_MONEY→`mobile-money`, BANK_TRANSFER→`transfer`, CREDIT→`deferred`, OTHER à paramétrer. Paiement mixte : moyen du plus gros montant | proposé |
| D5 | **Pas d'idempotence côté FNE** : un délai dépassé = résultat **incertain**, jamais renvoyé automatiquement. Seules les erreurs certaines (connexion refusée, 401, 502/503) repartent en file ; **un 500 est incertain** (constaté : facture créée non signée). Pour ne pas ajouter de valeur d'énumération (cassant en pratique, contrat §6), l'incertain reste en `SUBMITTING` avec un champ ajouté `is_uncertain: true` | proposé |
| D6 | **Une seule FNE de vente active par commande** (index unique partiel), donc pas de double certification par double clic | proposé |
| D7 | `DAILY_SUMMARY` n'a pas d'équivalent dans l'API. Avec D1, il couvre les tickets sans FNE (`/fne/daily-summary`, contrat §4.8) | proposé |
| D8 | Client de passage (B2C) : nom / téléphone / e-mail par défaut paramétrables (`fne.walk_in_client`) — l'API les exige même en B2C | à valider en sonde |

## 2. Cycle de vie d'un document FNE

```
PENDING ──(soumission)──► SUBMITTING ──200──► CERTIFIED
                             │
                             ├─ connexion refusée / 502 / 503 / 401 ─► QUEUED ──(worker, backoff)──► SUBMITTING
                             ├─ 400 (données invalides) ─────► FAILED   (correction puis nouvel essai manuel)
                             └─ délai dépassé / 500 / 504 ────► SUBMITTING + is_uncertain (vérification dans
                                                                         l'espace FNE : « certifiée » avec n° saisi,
                                                                         ou « non certifiée » → renvoi)
MANUAL : document traité hors API.
```

## 3. Phases

### Phase 1 — Sonde sur l'environnement de test
- [x] Clé API de test vérifiée (01/10) : acceptée, la plateforme répond depuis le poste local
- [x] Commande `python -m caisse.cli fne-probe` : facture B2C (TVA 18 % + TVAD) puis avoir d'une unité (`--refund`) ; requêtes et réponses écrites dans `fne-probe/<horodatage>/` (hors git)
- [ ] Lancer la sonde et ramener les traces dans `tests/fixtures/fne/`
- [ ] Questions à trancher : HT décimal accepté (D2) ? valeurs client acceptées en B2C (D8) ? arrondi du TTC FNE ? format de `token` ?
- Lancement (`.env` avec `FNE_API_BASE_URL=http://54.247.95.108/ws` et `FNE_API_KEY`, puis `docker compose up -d` pour recharger) :
  ```bash
  docker compose exec api python -m caisse.cli fne-probe \
    --point-of-sale "<point de vente FNE>" \
    --client-phone 07XXXXXXXX --client-email contact@exemple.ci --refund --yes
  # établissement par défaut : RESTAURANT CHEZ SYLLA PLUS ; variante : --ht-decimals 0
  ```

### Phase 2 — Domaine pur (sans I/O)
- [x] `domain/fne.py` : construction de la requête depuis une commande figée (lignes, TVA, moyen de paiement, template B2C/B2B/B2G/B2F, client), calcul HT, avoir
- [x] Tests unitaires (`tests/unit/domain/test_fne.py`)

### Phase 3 — Client HTTP (`infrastructure/fne/`)
- [x] Port `FneProvider` : `sign(payload)` et `refund(invoice_id, payload)` ; `FneResult` (`invoice_id`, `items`, montants, `balance_funds_xof`, `low_balance_warning`)
- [x] `HttpFneProvider` (httpx) avec classification des erreurs : `FneRejectedError` (4xx), `FneAuthError` (401), `FneUnavailableError` (connexion impossible, 502/503), `FneUncertainError` (délai dépassé après envoi, 500, 504, réponse illisible)
- [x] `MockFneProvider` (dév. et tests) et sélection selon `FNE_PROVIDER`
- [x] Tests du client avec `httpx.MockTransport` (`tests/unit/infrastructure/test_fne_client.py`) ; à compléter avec les traces réelles de la sonde

### Phase 4 — Schéma (migration `0002`, réversible)
- [x] `fne_documents` : `template`, `fne_invoice_id`, `parent_document_id` (avoir → vente), `items_map` (ligne caisse → id article FNE), `fne_amount_ttc_xof`, `balance_funds_xof`, `low_balance_warning`, `is_uncertain`, `created_by_user_id`
- [x] Enum `FneDocumentType.REFUND` (⚠ nouvelle valeur : prévenir le front, contrat §6)
- [x] Index unique partiel : une FNE de vente par commande (D6) ; NCC client unique
- [x] Paramètres métier : `fne.point_of_sale`, `fne.establishment`, `fne.walk_in_client` (valeur par défaut si la clé manque en base) ; `fne.sticker_alert_threshold` supprimé le 06/10/2026

### Phase 5 — Service (`services/fne_service.py`)
- [x] `issue_for_order` : commande soldée, une FNE par commande (rappel = même document, sans appel), FNE refusée reconstruite
- [x] `_submit` : `SUBMITTING` commité **avant** l'appel, appel synchrone (`FNE_SYNC_TIMEOUT_SECONDS`), transitions de la §2, audit `fne.submit`
- [x] `refund` : avoir total ou partiel à partir de `items_map`, quantités déjà reprises déduites
- [x] `retry`, `resolve` (certifiée avec n° relevé, ou non certifiée → renvoi) ; mode `manual` → `MANUAL`
- [x] Alerte solde bas : avertissement `FNE_STICKER_LOW` quand la DGI renvoie `warning: true` (`meta.balance_funds_xof`)
- [ ] Alerte stickers dans `/health` et le journal (avec le worker)

### Phase 6 — API (contrat §4.8 + ajouts non cassants)
- [x] `GET /customers?search=&ncc=` · `POST /customers` (NCC : 7 chiffres + 1 lettre, normalisé)
- [x] `POST /orders/{id}/fne` (C) · `GET /orders/{id}/fne` (C, ajout)
- [x] `GET /fne/documents` (R) · `POST /fne/documents/{id}/retry` (R) · `POST …/resolve` (R, ajout) · `POST …/refund` (R, ajout)
- [x] `GET /fne/documents/{id}/duplicate` (C) · `GET /fne/pending-count` (C) · `GET /fne/daily-summary` (R, calculé à la volée)
- [ ] `GET /fne/daily-summary/{id}/export` : nécessite le récapitulatif figé à la clôture (avec le Z)
- [x] Codes d'erreur : `CUSTOMER_NCC_EXISTS`, `FNE_ORDER_NOT_PAID`, `FNE_NOT_CONFIGURED`, `FNE_DOCUMENT_STATE`, `FNE_REFUND_EXCEEDS`, `FNE_*` de traduction (422) ; avertissements `FNE_REJECTED`, `FNE_UNCERTAIN`, `FNE_QUEUED`, `FNE_STICKER_LOW` → à valider avec le front
- [x] 11 tests d'intégration (`tests/integration/test_fne.py`) contre `MockFneProvider`

### Phase 7 — Worker de renvoi
- [x] `python -m caisse.cli fne-worker` (service `caisse-fne-worker` dans `deploy/vps/docker-compose.yml`, 21/10/2026) : traite les `QUEUED` échus un par un (`SKIP LOCKED`), paliers `RETRY_DELAYS` 1 min → 5 min → 15 min → 1 h (plafond), ne touche jamais aux documents incertains (`is_uncertain`) ni refusés ; termine l'envoi en cours avant de s'arrêter (SIGTERM)

### Phase 8 — Branchements (dépendent de L4)
- [ ] Encaissement : `payment_method` déduit des paiements réels (testé aujourd'hui avec des paiements insérés en base)
- [ ] Remboursement → avoir FNE
- [ ] FNE remise en A4 via le lien de vérification (`token`) renvoyé par l'API (D10) ; n° FNE optionnel sur le ticket de caisse

### Phase 9 — Validation DGI et production
- [ ] Jeu de spécimens : B2C espèces, B2C mobile money, B2B avec NCC, multi-taux, avoir partiel
- [ ] Envoi à support.fne@dgi.gouv.ci (factures FNE + factures correspondantes de la caisse)
- [ ] Après validation : URL et clé de prod, surveillance des journaux

## 4. Journal des découvertes

| Date | Constat | Conséquence |
|---|---|---|
| 01/10/2026 | Contrat d'API : routes FNE au §4.8, statuts au §4.6 (`PENDING`, `SUBMITTING`, `CERTIFIED`, `QUEUED`, `FAILED`, `MANUAL`) | D5 sans nouvelle valeur d'énumération ; phase 6 alignée |
| 01/10/2026 | Clé de test valide : corps vide → 400 avec détail par champ ; clé bidon → 401 `"error": "unauthorized"` (la procédure indiquait `unauthorized_exception`) | Ne pas se fier au libellé `error`, seulement au statut HTTP |
| 01/10/2026 | Champs exigés : `invoiceType`, `paymentMethod`, `template`, `clientCompanyName`, `clientPhone` (**chaîne**, la procédure dit `int`), `clientEmail`, `pointOfSale`, `establishment`, `items` ; `isRne` non exigé | `clientPhone` envoyé en chaîne |
| 01/10/2026 | `items` : « exactly one tax » parmi `TVA`, `TVAB`, `TVAC`, `TVAD`, **`TVAE`** (absent de la procédure) | Un code par article ; demander à la DGI ce que couvre `TVAE` |
| 01/10/2026 | `pointOfSale` inconnu → 400 `"Point of sale is invalid"`. Il faut créer un point de vente dans l'espace FNE (outil « Application FNE », l'autre choix étant « TPE ») ; `CAISSE-1` créé | `fne.point_of_sale = "CAISSE-1"` |
| 01/10/2026 | Avec `CAISSE-1` : validation passée puis 500 `invoice_signing_error`, identique avec un HT à 4 décimales ou entier | Cause côté compte FNE (stickers, établissement incomplet ou point de vente non actif) ; un 500 de signature doit être vérifié dans l'espace FNE avant d'être considéré « sans danger » |
| 01/10/2026 | Les deux 500 ont laissé **deux factures « Vente » sans numéro** dans « Reçus et factures émis » ; solde de stickers à 0 FCFA | 500 reclassé incertain ; demander des stickers de test à la DGI. Montants FNE : 6 932 HT + 1 068 TVA = 8 000 TTC, identiques à la caisse avec un HT à 4 décimales comme entier (D2 rassurante) |
| 01/10/2026 | Essai B2B avec un NCC absurde (`0000000X`) : pas de 400 sur `clientNcc`, même 500 de signature qu'en B2C | La FNE ne vérifie pas le NCC à la validation → contrôle de format côté caisse ; le blocage de signature ne dépend pas du modèle |
| 01/10/2026 | Ébauche PDF téléchargée depuis l'espace FNE (essai de 12:12) : pas de n° ni de QR ; émetteur repris de l'espace FNE (NCC 1304777N, RCCM, adresse, PDV) ; P.U HT affiché arrondi (2 966), totaux exacts (6 932 + 1 068 = 8 000) ; **régime d'imposition TEE** | D3 : taux de TVA de la caisse à faire confirmer ; format NCC 7 chiffres + lettre confirmé ; la caisse n'envoie pas les données de l'émetteur |
| 01/10/2026 | Vraie FNE de production (photo) : n° `1304777N26000000023` = NCC + année + n° d'ordre sur 9 chiffres ; tous les articles en `TVAD (0)`, TVA 0 ; client B2B CGECI `9506466A` affiché avec son régime (« RS employeur ») retrouvé par la FNE ; vendeur, unité `U` et références renseignés ; PDV de prod « Service Facturation » ; coordonnées du restaurant différentes du test ; format A4 | TEE confirmé en pratique (D3) ; la FNE connaît les NCC ; D9, D10, D11 ; la caisse continuera la série déjà entamée via l'application FNE (éviter la double facturation d'une même vente) |
| 01/10/2026 | Régime **TEE confirmé** | Caisse à 0 % par défaut (`vat.default_rate`), `TVAD` sur la FNE ; HT = TTC, plus aucun arrondi de TVA |
| 05/10/2026 | Panne de signature côté DGI alors que le solde avait été rechargé la veille (factures du dev front numérotées le 04/10) : `ReadTimeout` après 15 s, puis `504 Connection Timed Out` de la passerelle après 30 s ; factures créées **sans numéro** dans l'espace FNE | Classement « incertain » confirmé à l'usage ; incident signalé à la DGI ; aucun document en base caisse (essais via `fne-probe`) |
| 06/10/2026 | Service rétabli : B2B certifiée en ~1 s (`1304777N26000000005`), TTC 8 000 / 8 000, TVA 1 068. La réponse ne contient plus `balance_sticker` mais **`balance_funds: 20400`** (solde prépayé en XOF) | `FNE_STICKER_LOW` restait muet (seuil comparé à un champ absent) : alerte basée sur `warning` de la DGI, solde stocké en XOF (migration 0004). Coût d'une facture inconnu : à demander à la DGI pour afficher un nombre de factures restantes |
