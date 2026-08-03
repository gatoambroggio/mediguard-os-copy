#!/usr/bin/env bash
# ============================================================================
# update.sh - Actualiza el sistema POCSAG desde el directorio fuente actual.
# Uso: sudo bash update.sh
# Preserva la base de datos y la configuración personalizada (ptt, pjsip).
# ============================================================================
set -euo pipefail

APP_DIR="/opt/pocsag-server"
AST_USER="asterisk"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ $EUID -ne 0 ]] && { echo "Ejecutá como root o con sudo."; exit 1; }

if [[ ! -d "${APP_DIR}" ]]; then
  echo "El sistema no está instalado en ${APP_DIR}. Ejecutá install.sh primero."
  exit 1
fi

echo "==> Respaldando base de datos y config personalizada..."
BACKUP="/tmp/pocsag-update-backup.$(date +%s)"
mkdir -p "${BACKUP}"
cp "${APP_DIR}/database/pocsag.db" "${BACKUP}/" 2>/dev/null || true
cp "${APP_DIR}/scripts/ptt_on.sh" "${BACKUP}/" 2>/dev/null || true
cp "${APP_DIR}/scripts/ptt_off.sh" "${BACKUP}/" 2>/dev/null || true
cp "${APP_DIR}/asterisk/pjsip_pocsag.conf" "${BACKUP}/" 2>/dev/null || true

echo "==> Actualizando archivos desde ${SRC_DIR}..."
cp -r "${SRC_DIR}"/* "${APP_DIR}/" 2>/dev/null || true

echo "==> Restaurando DB y config personalizada..."
cp "${BACKUP}/pocsag.db" "${APP_DIR}/database/" 2>/dev/null || true
cp "${BACKUP}/ptt_on.sh"  "${APP_DIR}/scripts/" 2>/dev/null || true
cp "${BACKUP}/ptt_off.sh" "${APP_DIR}/scripts/" 2>/dev/null || true
cp "${BACKUP}/pjsip_pocsag.conf" "${APP_DIR}/asterisk/" 2>/dev/null || true

chmod +x "${APP_DIR}"/scripts/*.sh "${APP_DIR}"/encoder/*.sh "${APP_DIR}"/agi/*.py 2>/dev/null || true
chown -R "${AST_USER}:${AST_USER}" "${APP_DIR}"

echo "==> Reinstalando AGI y config de Asterisk..."
cp "${APP_DIR}/agi/pocsag_handler.py" /var/lib/asterisk/agi-bin/ 2>/dev/null || true
cp "${APP_DIR}/asterisk/extensions_pocsag.conf" /etc/asterisk/ 2>/dev/null || true
cp "${APP_DIR}/services/"*.service /etc/systemd/system/ 2>/dev/null || true
systemctl daemon-reload
asterisk -rx "dialplan reload" 2>/dev/null || true
asterisk -rx "pjsip reload" 2>/dev/null || true
systemctl restart pocsag-monitor pocsag-api 2>/dev/null || true

rm -rf "${BACKUP}"
echo "==> Actualización completa. Backup temporal descartado."