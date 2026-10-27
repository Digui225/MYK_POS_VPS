# Déploiement de production — OsisPos (Caisse MYK)

VPS OVH `148.113.149.10` (Debian 13), **dédié à la caisse** · domaine `gestion.osispos.com`
(DNS chez ResellerClub) · déployé depuis la branche `main` de ce dépôt.

## Sur le serveur

| Élément | Emplacement |
|---|---|
| Code en service / précédent | `/opt/Departement_Bi/OsisPos_Backend/code`, `code.prev` |
| Secrets (root, `chmod 600`) | `/opt/Departement_Bi/OsisPos_Backend/api.env`, `db.env` (modèles : `*.env.example`) |
| Sauvegardes | `/opt/Departement_Bi/OsisPos_Backend/backups` (chaque nuit à 2 h, 14 jours) |
| Front (build du dev front) | `/opt/Departement_Bi/OsisPos_Frontend/dist` |
| Nginx | `/etc/nginx/conf.d/osispos.conf` (IP:8083), `osispos-domain.conf` (domaine), `/etc/nginx/snippets/osispos-locations.conf` |
| Conteneurs | `caisse-api` (127.0.0.1:8011), `caisse-fne-worker`, `caisse-db` (aucun port publié) |

Ports ouverts (ufw) : 22, 80, 443, et 8083 tant que l'agent d'impression n'est pas passé sur
le domaine.

**Jamais** : `docker system prune`, `docker volume prune`, `docker compose down -v` (efface la
base), `systemctl restart nginx` (toujours `nginx -t && systemctl reload nginx`). Toute
modification de `deploy/vps/` se fait **dans le dépôt**, puis est déployée.

## 1. Mettre une version en production

**Automatique** : tout push sur `main` lance `.github/workflows/deploy.yml` : tous les tests,
puis dépôt du code dans `code.new` et `deploy/vps/update.sh`. Secrets GitHub : `VPS_HOST`,
`VPS_USER`, `VPS_SSH_KEY`.

**Depuis un poste** (même résultat, sans GitHub) :

```bash
deploy/vps/deploy.sh            # HEAD ; ou un commit : deploy/vps/deploy.sh 3170d4d
```

`update.sh`, côté serveur :
1. avertit des variables du modèle absentes d'`api.env` (le code prend sa valeur par défaut) ;
2. **sauvegarde la base** (arrêt sans rien toucher si elle échoue) ;
3. construit la nouvelle image pendant que l'API tourne (arrêt sans rien toucher si échec) ;
4. bascule : `code` → `code.prev`, `code.new` → `code` ; les migrations Alembic passent au
   démarrage du conteneur ;
5. contrôle de santé (`/health/ready`, 3 min au plus) ; en échec : **retour automatique** à la
   version précédente (code et image). Une migration n'est jamais annulée : l'ancien code
   tourne alors sur le nouveau schéma, à vérifier ;
6. installe Nginx (HTTPS si le certificat existe), `nginx -t` puis `reload` ; ancienne
   configuration remise si le test échoue ;
7. installe la sauvegarde nocturne (`/etc/cron.d/osispos-backup`).

Coupure pendant la bascule : quelques secondes (redémarrage de l'API et migrations). Déployer
**hors service** (le restaurant est fermé le week-end).

## 2. Domaine et HTTPS (une fois)

1. **DNS** (ResellerClub → `osispos.com` → DNS Management → A Records) : `gestion` →
   `148.113.149.10`, TTL par défaut. Dans « Host Name », taper `gestion` seulement. Vérifier :
   ```bash
   dig @ns1.nudns.com gestion.osispos.com +short   # 148.113.149.10
   dig @1.1.1.1 gestion.osispos.com +short         # idem, après propagation
   ```
2. Un déploiement (§1) : Nginx sert alors `http://gestion.osispos.com`.
3. Certificat, pare-feu 80/443, LLMNR coupé :
   ```bash
   ssh debian@148.113.149.10
   sudo bash /opt/Departement_Bi/OsisPos_Backend/code/deploy/vps/setup-server.sh adresse@mail
   ```
   Renouvellement automatique (`certbot.timer`) ; l'adresse reçoit les avis d'expiration.
4. `api.env` (§4) : `CORS_ORIGINS` et `ALLOWED_HOSTS` avec le domaine.
5. Bascule des postes (§3), puis retrait de l'accès par l'IP : supprimer
   `deploy/vps/nginx/osispos.conf` du dépôt (et `update.sh` de l'installer), déployer, puis
   `sudo rm /etc/nginx/conf.d/osispos.conf && sudo nginx -t && sudo systemctl reload nginx`
   et `sudo ufw delete allow 8083/tcp`.

## 3. Postes du restaurant

- **Navigateur** : `https://gestion.osispos.com` en favori. L'ancienne adresse
  (`http://148.113.149.10:8083`) est un autre site pour le navigateur : connexion à refaire, et
  l'ancienne application installée (PWA) à désinstaller.
- **Agent d'impression** (`C:\CaisseMYK\.env`) : `API_URL=https://gestion.osispos.com`, puis
  redémarrer la tâche planifiée. Contrôle : `GET /api/v1/printing/status` → agent en ligne.
- Nouveau jeton de terminal (perdu, nouveau poste) :
  ```bash
  sudo docker exec -it caisse-api python -m caisse.cli create-print-terminal --name Comptoir-2
  ```

## 4. Réglages (`api.env`)

Modèle commenté : `api.env.example`. **Les noms comptent** : une variable mal nommée est
ignorée sans message (`update.sh` signale celles du modèle qui manquent). Après modification :

```bash
sudo nano /opt/Departement_Bi/OsisPos_Backend/api.env
cd /opt/Departement_Bi/OsisPos_Backend/code/deploy/vps
sudo CAISSE_ROOT=/opt/Departement_Bi/OsisPos_Backend docker compose up -d --force-recreate caisse-api caisse-fne-worker
```

Avant la première vraie vente : `ENABLE_DOCS=false`, `CORS_ORIGINS` / `ALLOWED_HOSTS` sans `*`,
données de test vidées. Le WebSocket : `WS_REQUIRE_AUTH=true` dès que le front ouvre
`/api/v1/ws?token=<access_token>` (sans jeton, il ne reçoit aujourd'hui que le type des
événements, sans montants).

**FNE** : `FNE_PROVIDER=mock` tant que le passage à la vraie API n'est pas décidé. Ce jour-là :
`FNE_PROVIDER=api`, `FNE_API_BASE_URL`, `FNE_API_KEY`, puis une vente de contrôle. Chaque FNE
émise avec la clé de production est une **vraie facture**.

## 5. Données

- `restore_real_data.sql` **efface commandes, paiements et sessions** avant de recharger le
  catalogue réel : réservé à une base de test, il refuse de tourner s'il trouve des paiements
  ou des FNE (sauf confirmation explicite, voir l'en-tête du fichier). Jamais après la
  première vraie vente.
- Console SQL : `sudo docker exec -it caisse-db psql -U caisse -d caisse`.
- Jamais de suppression dans `payments`, `fne_documents`, `stock_movements`, `audit_logs`
  (traces comptables et fiscales) ; jamais de changement de schéma à la main (Alembic).

## 6. Sauvegardes et restauration

```bash
sudo CAISSE_ROOT=/opt/Departement_Bi/OsisPos_Backend bash /opt/Departement_Bi/OsisPos_Backend/code/deploy/vps/backup.sh
sudo tail /opt/Departement_Bi/OsisPos_Backend/backups/backup.log
```

Les dumps restent sur le serveur : **les copier ailleurs** régulièrement (une panne du VPS les
emporterait), par exemple depuis un poste :
`scp debian@148.113.149.10:/opt/Departement_Bi/OsisPos_Backend/backups/caisse-*.dump .`
(lecture réservée à root : copier d'abord dans `/home/debian` avec `sudo cp` et `sudo chown`).

Restauration (API arrêtée, **après** une sauvegarde de l'état actuel) :

```bash
cd /opt/Departement_Bi/OsisPos_Backend/code/deploy/vps
export CAISSE_ROOT=/opt/Departement_Bi/OsisPos_Backend
sudo -E docker compose stop caisse-api caisse-fne-worker
sudo docker exec -i caisse-db pg_restore -U caisse -d caisse --clean --if-exists < /chemin/caisse-AAAAMMJJ-HHMMSS.dump
sudo -E docker compose start caisse-api caisse-fne-worker
```

## 7. Accès SSH

La connexion par mot de passe est active (`/etc/ssh/sshd_config.d/50-cloud-init.conf`). À
couper une fois que **chaque** compte utilisé a sa clé (`~/.ssh/authorized_keys`), dont
`departement_ia_osis` (aucune clé aujourd'hui) :

```bash
sudo sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/50-cloud-init.conf
sudo sshd -t && sudo systemctl reload ssh
```

Garder une session ouverte pendant l'opération et tester une nouvelle connexion avant de la fermer.
