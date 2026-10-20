# Agent d'impression du terminal

Pilote l'imprimante ESC/POS USB et le tiroir (branché sur le port DK/RJ11 de l'imprimante).
Il ne connaît aucune règle métier : il reçoit des textes déjà mis en page.

La caisse est en ligne et ne peut pas joindre le restaurant : **c'est l'agent qui vient
chercher les travaux**, avec le jeton de son terminal (distinct des PIN, révocable).

| Appel de l'agent | Rôle |
|---|---|
| `POST /api/v1/print-agent/poll` `{ "printer": { "online", "paper", "model", "width" } }` | Se signaler (toutes les ~2 s) et prendre le plus ancien travail en file : `{ "job": null }` ou `{ "job": { "id", "type", "content", "open_drawer", "cut" } }` |
| `POST /api/v1/print-agent/jobs/{id}/result` `{ "printed", "error" }` | Rendre le résultat (`DONE` / `FAILED` côté caisse) |

Imprimante rapportée hors ligne : la caisse ne confie rien, les tickets attendent en file et
sortent au retour de l'imprimante (le tiroir s'ouvre alors avec eux).

## Jeton du terminal

Créé une fois, affiché une seule fois :

```bash
# sur le serveur
docker compose exec caisse-api python -m caisse.cli create-print-terminal --name Comptoir
# ou depuis l'administration : POST /api/v1/printing/terminals {"name": "Comptoir"} (ADMIN)
```

Perdu ou compromis : `POST /api/v1/printing/terminals/{id}/revoke`, puis en créer un nouveau.

## Sans imprimante (développement)

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
cp .env.example .env && sed -i 's/^PRINTER_BACKEND=.*/PRINTER_BACKEND=dummy/' .env
nano .env                           # API_URL=http://localhost:8001, TERMINAL_TOKEN=pt_…
.venv/bin/python -m agent           # les tickets s'affichent dans le terminal
```

## Sur le poste Windows du restaurant (Xprinter 58 mm)

L'agent passe par le **pilote Xprinter déjà installé** : il remet au spouleur Windows les octets
ESC/POS bruts (`RAW`), sans rendu par le pilote. Ne pas installer libusb ni Zadig, qui priveraient
Windows de l'imprimante. Un ticket que Windows n'arrive pas à transmettre (imprimante éteinte,
plus de papier) est retiré de la file Windows et signalé `FAILED` à la caisse : le rejouer depuis
la caisse ne donnera jamais deux tickets.

1. Installer Python 3.12 depuis python.org, **pour tous les utilisateurs** (case « Install for all
   users » de l'installation personnalisée).
2. Copier ce dossier `print-agent` dans `C:\CaisseMYK\print-agent`.
3. PowerShell **en administrateur** :
   ```powershell
   cd C:\CaisseMYK\print-agent
   powershell -ExecutionPolicy Bypass -File windows\install.ps1   # crée .env, liste les imprimantes
   notepad .env                                                   # API_URL, TERMINAL_TOKEN, PRINTER_NAME
   powershell -ExecutionPolicy Bypass -File windows\install.ps1   # installe et démarre l'agent
   ```
4. Depuis la caisse : `GET /api/v1/printing/status` → `agent_online: true`, puis ticket de test
   (`POST /api/v1/printing/test`) : accents lisibles (sinon `PRINTER_CODEPAGE=CP850`), lignes de
   32 caractères sans retour à la ligne parasite. Puis `POST /api/v1/printing/open-drawer`.

L'agent tourne en tâche planifiée `CaisseMYK-AgentImpression` (compte SYSTEM, au démarrage de
Windows, relancée toutes les 5 min si elle s'est arrêtée), sans session ouverte.

| Action | Commande (PowerShell administrateur) |
|---|---|
| Journal | `Get-Content C:\CaisseMYK\print-agent\logs\agent.log -Wait -Tail 50` |
| Redémarrer (après modification de `.env`) | `Stop-ScheduledTask CaisseMYK-AgentImpression; Start-ScheduledTask CaisseMYK-AgentImpression` |
| Désinstaller | `powershell -ExecutionPolicy Bypass -File windows\install.ps1 -Uninstall` |

L'API doit rendre les tickets sur la même largeur : `PRINTER_WIDTH=32` dans son `api.env`.

## Sur un poste Linux

```bash
lsusb                               # repérer « ID vvvv:pppp »
cp .env.example .env && nano .env   # API_URL, TERMINAL_TOKEN, PRINTER_VENDOR_ID / PRODUCT_ID
sudo cp 99-escpos.rules /etc/udev/rules.d/   # après y avoir mis les mêmes identifiants
sudo udevadm control --reload-rules && sudo udevadm trigger
sudo usermod -aG lp $USER           # puis se déconnecter / reconnecter
./install.sh                        # venv + service systemd caisse-print-agent
```

Vérifier : `GET /api/v1/printing/status` doit répondre `agent_online: true`, puis ticket de
test (`POST /api/v1/printing/test`, ADMIN) et ouverture du tiroir
(`POST /api/v1/printing/open-drawer`, RESPONSABLE).

Journal : `journalctl -u caisse-print-agent -n 100 -f`

