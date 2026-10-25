# Compte rendu de réunion — Gestion des achats, de la production et des ventes

## 1. Objectif de la réunion

La réunion avait pour objectif de définir le fonctionnement d'une application permettant de suivre les achats, les quantités produites, les ventes et les écarts constatés dans l'activité de restauration.

L'objectif principal est de disposer d'une comptabilité analytique détaillée pour connaître, par produit, les quantités achetées, le nombre de plats pouvant être préparés, les quantités vendues et les écarts éventuels.

## 2. Organisation générale de l'application

L'application devra s'appuyer sur plusieurs parties complémentaires :

- Un tableau des achats et de la production.
- Un tableau des ventes.
- Un suivi spécifique des produits d'accompagnement.
- Un tableau de bord général.

## 3. Tableau des achats et de la production

Ce tableau permettra d'enregistrer les achats de matières premières et de calculer automatiquement le nombre de plats réalisables à partir des quantités achetées.

### Informations à enregistrer

- Date de l'achat ou de la production.
- Produit concerné : poulet, poisson, mouton, etc.
- Quantité achetée, en pièces ou en kilogrammes.
- Prix d'achat unitaire.
- Montant total de l'achat.
- Rendement du produit, c'est-à-dire le nombre de plats obtenus par unité.
- Nombre total de plats prévus, calculé automatiquement.

### Exemple de calcul

Supposons qu'un poulet permette de préparer quatre plats.

| Information | Valeur |
|---|---:|
| Produit | Poulet |
| Quantité achetée | 10 poulets |
| Prix d'achat unitaire | 4 000 FCFA |
| Montant total de l'achat | 40 000 FCFA |
| Rendement par poulet | 4 plats |
| Nombre total de plats prévus | 40 plats |

**Formules :**

- Montant total de l'achat = Quantité achetée × Prix d'achat unitaire.
- Nombre de plats prévus = Quantité achetée × Rendement du produit.

Les rendements devront être configurables selon le produit. Par exemple, un poulet entier peut correspondre à quatre plats, tandis qu'un kilogramme de viande peut produire un nombre de plats défini dans les paramètres.

## 4. Tableau des ventes

Le tableau des ventes permettra de suivre quotidiennement les résultats réels.

### Informations à enregistrer

- Date de vente.
- Produit concerné.
- Nombre de plats prévus.
- Nombre de plats réellement vendus.
- Prix de vente unitaire d'un plat.
- Montant total des ventes.
- Écart entre le nombre de plats prévus et le nombre de plats vendus.
- Valeur financière associée à l'écart, si elle peut être déterminée.

### Exemple

| Information | Valeur |
|---|---:|
| Nombre de plats prévus | 12 |
| Nombre de plats vendus | 10 |
| Écart | -2 plats |
| Prix de vente unitaire | 3 000 FCFA |
| Valeur absolue de l'écart au prix de vente | 6 000 FCFA |

Dans cet exemple, deux plats de moins que prévu ont été vendus.

**Formules :**

- Montant des ventes = Nombre de plats vendus × Prix de vente unitaire.
- Écart en plats = Nombre de plats vendus − Nombre de plats prévus.

Un écart négatif indique que le nombre de plats vendus est inférieur au nombre prévu. Un écart positif indique que les ventes dépassent la prévision initiale.

> **Attention :** un écart entre les plats prévus et les plats vendus ne constitue pas nécessairement une perte financière. Il faut aussi tenir compte des invendus, des plats conservés, des pertes et des autres mouvements de stock.

## 5. Calcul des écarts et de la rentabilité

Le système devra rapprocher les dépenses d'achat et les recettes issues des ventes.

Les indicateurs à suivre comprennent :

- Le montant total des achats.
- Le chiffre d'affaires réalisé.
- Les quantités achetées et vendues.
- Les quantités prévues et réellement vendues.
- Les écarts constatés.
- Le coût des matières premières consommées.
- La marge, lorsque les données nécessaires sont disponibles.

La quantité achetée au cours d'une journée ne correspond pas nécessairement à la quantité consommée pendant cette même journée. Le calcul de la rentabilité devra donc tenir compte des stocks restants et des consommations réelles.

## 6. Fonctionnement automatique attendu

### Champs calculés automatiquement

- Montant total des achats.
- Nombre de plats réalisables à partir des quantités achetées.
- Nombre total de plats prévus.
- Montant des ventes.
- Écarts entre les prévisions et les résultats réels.
- Totaux journaliers et hebdomadaires.

### Champs modifiables par l'utilisateur

- Quantités achetées.
- Prix d'achat.
- Rendements et paramètres des produits, selon les droits attribués.
- Quantités prévues, lorsque cela est nécessaire.
- Quantités réellement vendues.
- Autres informations variables liées à la production.

Les données calculées devront se mettre à jour lorsque les données sources sont modifiées. Les champs calculés automatiquement devraient être protégés contre la modification manuelle directe.

## 7. Gestion des produits d'accompagnement

Les produits qui accompagnent les plats principaux pourront être suivis dans une partie distincte, adaptée à leur mode de consommation.

Les produits évoqués pendant la réunion comprennent notamment :

- Le riz.
- L'huile.
- L'eau.
- La banane et d'autres accompagnements.

Pour ces produits, le système devra permettre de suivre :

- Les quantités achetées.
- Les quantités utilisées sur une période donnée.
- Le nombre de portions ou de plats que ces quantités permettent de préparer, lorsque cela est mesurable.
- Le coût associé à leur consommation.

Cette séparation doit permettre d'obtenir une vision plus complète des coûts de production.

## 8. Tableau de bord général

Les tableaux des achats et des ventes devront alimenter un tableau de bord central.

| Indicateur | Description |
|---|---|
| Total des achats | Montant cumulé des dépenses d'achat |
| Chiffre d'affaires | Montant total des ventes réalisées |
| Quantités achetées | Quantités de produits acquis |
| Plats prévus | Nombre de plats théoriquement réalisables |
| Plats vendus | Nombre de plats réellement vendus |
| Écarts constatés | Différence entre les prévisions et les résultats |
| Coût de production | Coût des matières premières consommées |
| Marge | Différence entre les recettes et les coûts retenus pour son calcul |
| Résultat hebdomadaire | Synthèse des données de la semaine |

Les indicateurs devront pouvoir être consultés par jour et sur une période donnée, notamment à la fin de la semaine.

## 9. Bilan hebdomadaire

Le système devra faciliter la préparation du bilan de fin de semaine en regroupant automatiquement les données enregistrées au quotidien.

Le responsable devra pouvoir consulter :

- Le total des achats effectués.
- Le chiffre d'affaires réalisé.
- Les quantités de plats prévues et vendues.
- Les écarts journaliers et hebdomadaires.
- Les produits présentant des anomalies.
- Les coûts associés aux produits consommés.
- Les marges calculées à partir des données disponibles.

L'objectif est de réduire les calculs manuels et de repérer plus rapidement les problèmes.

## 10. Principales orientations retenues

1. **Séparer les achats et les ventes** dans deux tableaux distincts.
2. **Automatiser les calculs** des montants, des rendements, des plats prévus et des écarts.
3. **Configurer le rendement de chaque produit** pour convertir les quantités achetées en nombre de plats.
4. **Suivre les ventes quotidiennement** et comparer les prévisions aux résultats réels.
5. **Prévoir un suivi adapté des produits d'accompagnement**, comme le riz et l'huile.
6. **Centraliser les indicateurs dans un tableau de bord**.
7. **Faciliter le bilan hebdomadaire** grâce aux données déjà enregistrées.

## 11. Points à clarifier avant le développement

Certains éléments doivent encore être précisés pour garantir la fiabilité des calculs.

| Point à clarifier | Question |
|---|---|
| Rendement des produits | Combien de plats chaque produit permet-il de préparer ? |
| Prix de vente | Le prix d'un plat est-il fixe ou peut-il varier ? |
| Gestion des invendus | Comment traiter les plats préparés mais non vendus ? |
| Gestion des pertes | Comment enregistrer les produits abîmés, perdus ou jetés ? |
| Stock restant | Comment gérer les produits achetés mais non consommés ? |
| Calcul de la marge | Quels coûts faut-il intégrer au calcul ? |
| Quantités réellement utilisées | Comment distinguer les quantités achetées des quantités consommées ? |
| Produits d'accompagnement | Comment calculer leur coût par plat ou par période ? |

Ces précisions sont nécessaires, car le montant des achats d'une journée ne correspond pas forcément au coût des produits consommés ce jour-là. De même, un écart entre le nombre de plats prévus et vendus ne suffit pas à établir une perte financière réelle.

## 12. Conclusion

La réunion a permis de définir les grandes orientations d'une application de suivi des achats, de la production et des ventes.

Le besoin principal est de disposer d'un système capable de calculer automatiquement les données essentielles, de suivre les quantités de produits, de comparer les prévisions aux résultats réels et de faire ressortir les écarts.

L'application devra s'appuyer sur deux tableaux principaux — les achats et les ventes — complétés par un suivi spécifique des produits d'accompagnement et un tableau de bord général.

Le résultat attendu est une comptabilité analytique plus détaillée et plus fiable, permettant au responsable de comprendre les coûts, de suivre les performances de chaque produit et d'obtenir un bilan quotidien et hebdomadaire de l'activité.

L'automatisation de ces opérations doit réduire le travail manuel, faciliter les contrôles et améliorer la visibilité sur la rentabilité de l'activité.
