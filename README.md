# Dossier d'architecture — Application de caisse restaurant

Version **1.1** — intègre les réponses client du 24/09/2026 et la mutualisation d'infrastructure avec le PMS Hôtel Résidence de la Paix.

| Fichier | Destinataire | Contenu |
|---|---|---|
| [`00-ARCHITECTURE-GLOBALE.md`](./00-ARCHITECTURE-GLOBALE.md) | **Les deux + le client** | Contexte, réponses client, ADR, **mutualisation avec le PMS (§4)**, modèle de domaine, règles métier, **FNE par ticket (§8)**, sécurité, organisation, MVP et planning, risques, questions restantes |
| [`01-BACKEND.md`](./01-BACKEND.md) | Dev backend | Stack, couches, schéma de base, services, transactions, **agent d'impression USB + tiroir**, adaptateur FNE, tests, déploiement mutualisé |
| [`02-FRONTEND.md`](./02-FRONTEND.md) | Dev frontend | Stack, direction visuelle, écrans et maquettes, **clavier d'abord**, état, mode dégradé, performance, tests |
| [`03-CONTRAT-API.md`](./03-CONTRAT-API.md) | **Co-signé** | Conventions, erreurs, idempotence, tous les endpoints v1 avec exemples |
| [`04-EXPLOITATION-BACKEND.md`](./04-EXPLOITATION-BACKEND.md) | Dev backend + exploitant | **Installation, socle Docker partagé, migrations, création d'admin, sauvegarde/restauration, pgAdmin, redémarrage, dépannage, consigne caissière** |
| [`05-PLAN-IMPLEMENTATION.md`](./05-PLAN-IMPLEMENTATION.md) | **Dev backend + Lead** | **Plan d'implémentation phase par phase (Lots L0 à L7), compétences/skills mobilisés, DoD et livrables** |

## Les décisions à retenir

1. **Tout tourne en local**, sur l'ordinateur portable de la caisse → une coupure Internet n'arrête jamais la vente.
2. **L'impression passe par un agent hors Docker** : l'imprimante est en USB, le tiroir s'ouvre avec le ticket au clic sur « Payer ».
3. **Une facture normalisée par ticket**, avec attente bornée à 4 secondes puis repli sur une transmission différée.
4. **Montants en entiers XOF** partout, du schéma de base à l'affichage.
5. **Rien ne se modifie ni ne s'efface après encaissement** — seulement des opérations inverses tracées.
6. **Une instance PostgreSQL partagée avec le PMS, deux bases séparées.** Jamais de schéma commun, jamais de requête croisée.
7. **Le contrat OpenAPI est gelé en semaine 1** — c'est ce qui permet aux deux développeurs d'avancer en parallèle.
8. **Le poste est clavier + souris** jusqu'à l'arrivée de l'écran tactile : les raccourcis sont livrés avec chaque écran.

## Bloquants à lever

| # | Question | Bloque | Pour quand |
|---|---|---|---|
| 1 | Mode dégradé FNE autorisé ? Délai de transmission ? Identifiants API DGI disponibles ? | Lot L6 | Avant S6 |
| 2 | Modèle, **largeur** (58/80 mm) et port tiroir (DK/RJ11) de l'imprimante | Lot L4 | Avant S4 — **commander maintenant** |
| 3 | Le restaurant est-il celui de l'Hôtel Résidence de la Paix ? | Lot L7 (colocalisation en production) | Avant S8 |
| 4 | Mentions légales du ticket, taux de TVA, arrondi du rendu | Lot L4 | Avant S4 |

## Prochaines étapes

1. Poser les 4 bloquants ci-dessus, dans cet ordre de priorité.
2. Commander l'imprimante à reçu, le tiroir-caisse et un onduleur pour l'imprimante.
3. Monter le socle Docker partagé (`04-EXPLOITATION-BACKEND.md` §1) et basculer le PMS dessus.
4. Geler le contrat d'API en fin de semaine 1.
