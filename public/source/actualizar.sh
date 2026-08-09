#!/bin/bash
# actualizar.sh - Actualiza ZetronPOC desde GitHub y reinicia servicios.
# Uso:  cd /ubntpagingsystem && bash actualizar.sh
#   (o desde donde tengas el repo clonado)
set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

echo "=== 1/4 Git pull ==="
git pull origin main || { echo "ERROR: git pull fallo. Probá: git stash && git pull origin main"; exit 1; }

echo "=== 2/4 Copiando archivos a /opt/zetronpoc ==="
sudo cp -v src/zetronpoc/agi/pocsag_handler.py    /opt/zetronpoc/agi/
sudo cp -v src/zetronpoc/agi/dispatch_mqtt.py    /opt/zetronpoc/agi/
sudo cp -v src/zetronpoc/agi/cola_worker.py      /opt/zetronpoc/agi/
sudo cp -v src/zetronpoc/database/db_manager.py  /opt/zetronpoc/database/
sudo cp -v src/zetronpoc/database/schema.sql      /opt/zetronpoc/database/
sudo cp -v src/zetronpoc/frontend/index.html      /opt/zetronpoc/frontend/
# Sincronizar tambin el handler del AGI bin (lo usa el IVR de Asterisk)
sudo cp -v /opt/zetronpoc/agi/pocsag_handler.py /var/lib/asterisk/agi-bin/pocsag_handler.py
sudo cp -v /opt/zetronpoc/agi/dispatch_mqtt.py /var/lib/asterisk/agi-bin/dispatch_mqtt.py
sudo chmod +x /opt/zetronpoc/agi/*.py /var/lib/asterisk/agi-bin/*.py

echo "=== 3/4 Reiniciando servicios ==="
sudo systemctl restart zetronpoc-api zetronpoc-cola

echo "=== 4/4 Estado ==="
sleep 2
sudo systemctl --no-pager --lines=5 status zetronpoc-api zetronpoc-cola 2>/dev/null || true
echo ""
echo "=== Listo. La base se auto-migra al arrancar (agrega cola_id si falta). ==="
echo "=== Log del worker: tail -30 /opt/zetronpoc/logs/cola.log ==="
