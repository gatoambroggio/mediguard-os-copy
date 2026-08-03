#!/usr/bin/env bash
# ============================================================================
# uninstall.sh - Desinstala el sistema POCSAG conservando la base de datos.
# Uso: sudo bash uninstall.sh [--purge]   (--purge borra también la DB)
# ============================================================================
set -euo pipefail

APP_DIR="/opt/pocsag-server"
PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

[[ $EUID -ne 0 ]] && { echo "Ejecutá como root o con sudo."; exit 1; }

echo "==> Deteniendo servicios..."
systemctl disable --now pocsag-monitor pocsag-api 2>/dev/null || true
systemctl stop asterisk 2>/dev/null || true

echo "==> Quitando units de systemd..."
rm -f /etc/systemd/system/pocsag-monitor.service
rm -f /etc/systemd/system/pocsag-api.service
systemctl daemon-reload

echo "==> Quitando config de Asterisk..."
rm -f /etc/asterisk/extensions_pocsag.conf
rm -f /etc/asterisk/pjsip_pocsag.conf
rm -f /etc/asterisk/modules.conf.bak 2>/dev/null || true
# (no tocamos extensions.conf/pjsip.conf para no romper la PBX)
rm -f /var/lib/asterisk/agi-bin/pocsag_handler.py

echo "==> Quitando logrotate..."
rm -f /etc/logrotate.d/pocsag

if [[ $PURGE -eq 1 ]]; then
  echo "==> PURGE: borrando ${APP_DIR} completamente (incluye DB y logs)..."
  rm -rf "${APP_DIR}"
  rm -f /var/log/pocsag-install.log
else
  if [[ -d "${APP_DIR}/database" ]]; then
    echo "==> Respaldando base de datos a /tmp/pocsag-backup.db..."
    cp "${APP_DIR}/database/pocsag.db" /tmp/pocsag-backup.db 2>/dev/null || true
  fi
  echo "==> (DB preservada en /tmp si existía). Borrando resto de ${APP_DIR}..."
  rm -rf "${APP_DIR}"
fi

echo "==> Desinstalación completa."
echo "    Asterisk y dependencias NO se quitan (usar apt-get remove si lo deseás)."