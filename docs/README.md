# Documentation — Caisse MYK Backend

Ce dossier centralise l'ensemble de la documentation technique, des spécifications métier, des contrats d'interface et des procédures d'exploitation du backend de la caisse restaurant **OsisPos**.

---

## 📚 Sommaire des documents

### 1. Spécifications & Architecture
- **[`00-ARCHITECTURE-GLOBALE.md`](./00-ARCHITECTURE-GLOBALE.md)** : Vision d'ensemble du système, modèle de domaine (DDD), règles métier restaurant, gestion de la FNE (§8), infrastructure mutualisée avec le PMS Hôtel (§4) et plan de continuité d'activité (hors ligne d'abord).
- **[`01-BACKEND.md`](./01-BACKEND.md)** : Architecture en couches FastAPI, schéma relationnel PostgreSQL, services applicatifs, gestion des transactions, agent d'impression ESC/POS et adaptateur DGI FNE.
- **[`03-CONTRAT-API.md`](./03-CONTRAT-API.md)** : **Contrat d'API REST v1 gelé** : conventions RFC 7807 (erreurs `problem+json`), en-têtes d'idempotence (`X-Device-Id`, `Idempotency-Key`), endpoints et formats de requêtes/réponses.
- **[`05-PLAN-IMPLEMENTATION.md`](./05-PLAN-IMPLEMENTATION.md)** : Plan de réalisation par lots (L0 à L7), compétences mobilisées, livrables et critères de validation (Definition of Done).
- **[`compte_rendu_reunion_achats_ventes.md`](./compte_rendu_reunion_achats_ventes.md)** : Spécifications fonctionnelles détaillées issues des ateliers métier sur les achats marché, le rendement des protéines et les ventes journalières.
- **`TB ACHAT VENTE v01.xlsx`** : Tableau Excel de référence utilisé par le gérant pour la gestion quotidienne des achats, stocks et ventes.

### 2. Exploitation & Déploiement
- **[`04-EXPLOITATION-BACKEND.md`](./04-EXPLOITATION-BACKEND.md)** : Guide d'installation locale, gestion du conteneur PostgreSQL partagé, application des migrations Alembic, sauvegardes automatisées et dépannage.
- **[`RUNBOOK-EXPLOITATION-WINDOWS.md`](./RUNBOOK-EXPLOITATION-WINDOWS.md)** : Procédure pas à pas d'installation sous Windows (services d'arrière-plan via NSSM, scripts PowerShell de sauvegarde/restauration).
- **[`DEPLOYMENT-VPS.md`](./DEPLOYMENT-VPS.md)** : Procédure de déploiement sur serveur distant / VPS avec reverse proxy Caddy / Nginx.

### 3. FNE & Homologation DGI
- **`homologation/`** : Dossier officiel de certification et d'homologation de la Facture Normalisée Électronique auprès de la DGI (Côte d'Ivoire).
