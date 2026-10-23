#!/bin/bash
# Installe l'agent en service systemd (04-EXPLOITATION-BACKEND §1.7).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="${SUDO_USER:-$USER}"

cd "$DIR"
[ -f .env ] || { cp .env.example .env; echo "→ .env créé : renseigner PRINTER_VENDOR_ID / PRODUCT_ID (lsusb) puis relancer."; exit 1; }
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q -r requirements.txt

sed -e "s#__USER__#${USER_NAME}#g" -e "s#__DIR__#${DIR}#g" caisse-print-agent.service \
  | sudo tee /etc/systemd/system/caisse-print-agent.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now caisse-print-agent
systemctl --no-pager status caisse-print-agent | head -5
echo "Test : ticket de test depuis la caisse (POST /api/v1/printing/test, ADMIN)"
echo "Journal : journalctl -u caisse-print-agent -n 50 -f"
