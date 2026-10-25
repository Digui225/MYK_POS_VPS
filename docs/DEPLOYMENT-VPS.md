# Guide de Déploiement sur Serveur VPS (Caisse MYK)

Ce document détaille la procédure pas-à-pas pour déployer l'intégralité de la solution (Base de données PostgreSQL, API FastAPI et Frontend React / PWA sous Nginx) sur un serveur VPS distant.

---

## 1. Architecture Déployée sur le VPS

```
                              Navigateurs (PC Caissière, Mobiles, Responsable)
                                                    │
                                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ Serveur VPS (Linux / Docker)                                                │
│                                                                             │
│   ┌───────────────────────────┐         ┌───────────────────────────────┐   │
│   │ caisse-web (Nginx)        │ ──────> │ caisse-api (FastAPI)          │   │
│   │ Port 80 (ou 443 avec SSL) │  /v1/*  │ Port interne 8001             │   │
│   └───────────────────────────┘         └──────────────┬────────────────┘   │
│                                                        │                    │
│                                                        ▼                    │
│                                         ┌───────────────────────────────┐   │
│                                         │ caisse-db (PostgreSQL 16)     │   │
│                                         │ Port 5432 (isolé en local)    │   │
│                                         └───────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                                    ▲
                                                    │ Polling des impressions
                                                    │ (POST /v1/print-agent/poll)
                                                    │
                                   ┌─────────────────────────────────┐
                                   │ PC Windows du Restaurant        │
                                   │ (Imprimante USB + Tiroir-Caisse)│
                                   │ Agent Python en tâche de fond   │
                                   └─────────────────────────────────┘
```

---

## 2. Prérequis sur le VPS

Sur un VPS neuf (ex: Ubuntu 22.04 LTS ou 24.04 LTS) :

```bash
# 1. Mise à jour du système
sudo apt update && sudo apt upgrade -y

# 2. Installer Docker et le plugin Docker Compose
sudo apt install -y ca-certificates curl gnupg git
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 3. Ajouter l'utilisateur courant au groupe docker
sudo usermod -aG docker $USER
newgrp docker
```

---

## 3. Installation et Clonage

Les deux dépôts doivent être clonés côte-à-côte dans un même répertoire (ex: `/opt/caisse/` ou votre dossier personnel) :

```bash
mkdir -p /opt/caisse && cd /opt/caisse

# Cloner le backend et le frontend
git clone -b aziz https://github.com/Abdell87/Caisse_MYK_Back.git Caisse_MYK_backend
git clone -b aziz https://github.com/Abdell87/Caisse_MYK_frontend.git Caisse_MYK_frontend
```

---

## 4. Configuration d'Environnement

Dans le dossier backend :

```bash
cd /opt/caisse/Caisse_MYK_backend

# Copier le fichier d'exemple
cp .env.prod.example .env

# Éditer la configuration
nano .env
```

Points obligatoires à personnaliser dans `.env` :
1. `POSTGRES_SUPERPASSWORD` et `CAISSE_DB_PASSWORD` : définissez des mots de passe robustes.
2. `JWT_SECRET` : générez une chaîne aléatoire d'au moins 64 caractères (ex: via `openssl rand -hex 32`).
3. `ALLOWED_HOSTS` : mettez votre nom de domaine ou l'adresse IP publique de votre VPS (ou `*`).
4. `WEB_PORT` : `80` (ou un autre port si vous utilisez déjà un reverse proxy Nginx / Traefik / Caddy sur le VPS).

---

## 5. Démarrage de la Stack

Lancez la compilation et le démarrage en arrière-plan :

```bash
docker compose -f docker-compose.prod.yml up -d --build
```

Vérifiez que tous les conteneurs sont en cours d'exécution :

```bash
docker compose -f docker-compose.prod.yml ps
```

Vous devez voir 3 conteneurs :
* `caisse-db` (healthy)
* `caisse-api` (running sur 8001)
* `caisse-web` (running sur 80)

Les migrations de base de données (Alembic) s'appliquent automatiquement au démarrage grâce à l'entrypoint.

---

## 6. Initialisation des Données et Utilisateurs

Créez le premier utilisateur administrateur ou chargez les données initiales du restaurant :

```bash
# Charger le catalogue de démonstration et les tables (optionnel) :
docker compose -f docker-compose.prod.yml exec api python -m caisse.cli seed

# OU créer un utilisateur administrateur manuellement :
docker compose -f docker-compose.prod.yml exec api python -m caisse.cli create-user \
  --username admin \
  --role ADMIN \
  --pin 654321 \
  --first-name "Admin" \
  --last-name "MYK"

# Créer un caissier :
docker compose -f docker-compose.prod.yml exec api python -m caisse.cli create-user \
  --username caisse1 \
  --role CAISSIER \
  --pin 123456 \
  --first-name "Awa" \
  --last-name "Traore"
```

---

## 7. Raccordement de l'Imprimante Ticket du Restaurant

Le restaurant n'a pas besoin d'IP fixe ni d'ouverture de port sur sa box :
1. Sur le VPS, générez un jeton de terminal d'impression :
   ```bash
   docker compose -f docker-compose.prod.yml exec api python -m caisse.cli create-print-terminal --name "Caisse Principale"
   ```
   Ce script vous affiche un jeton du type : `pt_xxxxxxxxxxxxxxxxxxxx`.
2. Sur le PC Windows du restaurant, suivez le guide dans `apps/print-agent/README.md` et configurez dans le fichier `.env` :
   ```ini
   API_URL=http://<IP_DU_VPS_OU_DOMAINE>/v1
   TERMINAL_TOKEN=pt_xxxxxxxxxxxxxxxxxxxx
   PRINTER_NAME=Nom_De_Votre_Xprinter
   ```
3. L'agent Windows interrogera le serveur VPS toutes les 2 secondes pour récupérer instantanément les reçus à imprimer et déclencher l'ouverture du tiroir-caisse.

---

## 8. Commandes Utiles d'Exploitation

* **Voir les logs en direct :**
  ```bash
  docker compose -f docker-compose.prod.yml logs -f
  docker compose -f docker-compose.prod.yml logs -f api
  ```
* **Redémarrer les services :**
  ```bash
  docker compose -f docker-compose.prod.yml restart
  ```
* **Mettre à jour avec la dernière version de Git :**
  ```bash
  git pull origin aziz
  cd ../Caisse_MYK_frontend && git pull origin aziz && cd ../Caisse_MYK_backend
  docker compose -f docker-compose.prod.yml up -d --build
  ```
