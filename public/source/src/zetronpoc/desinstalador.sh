#!/usr/bin/env bash
# ============================================================================
# desinstalador.sh - ZetronPOC v1.0 - Elimina TODO el sistema y sus dependencias
# ============================================================================
# Detiene y borra los servicios, borra /opt/zetronpoc, limpia /etc/asterisk de
# los archivos de ZetronPOC y, opcionalmente, desinstala Asterisk y demas
# paquetes instalados por el instalador.
#
#   curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/src/zetronpoc/desinstalador.sh | sudo bash
#   curl -fsSL .../desinstalador.sh | sudo bash -s -- --purge   # borra tambien asterisk y deps
# ============================================================================
set -uo pipefail

APP_DIR="/opt/zetronpoc"
AST_ETC="/etc/asterisk"
PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; NC="\033[0m"
log(){ echo -e "${G}[OK]${NC}   $*"; }
warn(){ echo -e "${Y}[WARN]${NC} $*"; }
err(){ echo -e "${R}[ERR]${NC}  $*" >&2; }

[[ $EUID -ne 0 ]] && { err "Ejecuta como root o con sudo."; exit 1; }

echo "==> Deteniendo y deshabilitando servicios ZetronPOC..."
systemctl stop zetronpoc-api zetronpoc-cola 2>/dev/null || true
systemctl disable zetronpoc-api zetronpoc-cola 2>/dev/null || true
rm -f /etc/systemd/system/zetronpoc-api.service /etc/systemd/system/zetronpoc-cola.service
systemctl daemon-reload 2>/dev/null || true

echo "==> Quitando cron y logrotate de ZetronPOC..."
rm -f /etc/logrotate.d/zetronpoc /etc/cron.d/zetronpoc-cleanup 2>/dev/null || true

echo "==> Removiendo AGI de Asterisk..."
rm -f /var/lib/asterisk/agi-bin/pocsag_handler.py /var/lib/asterisk/agi-bin/pocsag_check.py 2>/dev/null || true

echo "==> Limpiando configuracion de Asterisk de ZetronPOC..."
if [[ -f "${AST_ETC}/pjsip.conf" ]]; then
  if grep -q "pjsip_zetronpoc.conf" "${AST_ETC}/pjsip.conf"; then
    # Restaurar pjsip.conf a un estado basico sin el include de ZetronPOC
    cat > "${AST_ETC}/pjsip.conf" <<'EOF'
; pjsip.conf - limpio tras desinstalar ZetronPOC
EOF
  fi
fi
rm -f "${AST_ETC}/pjsip_zetronpoc.conf" "${AST_ETC}/pjsip_zetronpoc.conf.bak" 2>/dev/null || true
# Restaurar extensions.conf a uno basico
cat > "${AST_ETC}/extensions.conf" <<'EOF'
[general]
priorityjumping=no

[from-internal]
exten => _X.,1,Hangup()

[default]
exten => s,1,Hangup()
EOF
asterisk -rx "dialplan reload" 2>/dev/null || true
asterisk -rx "pjsip reload" 2>/dev/null || true

echo "==> Borrando directorio de la aplicacion (${APP_DIR})..."
rm -rf "${APP_DIR}"

echo "==> Borrando backups y logs sueltos..."
rm -f /opt/zetronpoc*.log 2>/dev/null || true
rm -rf "${APP_DIR}" 2>/dev/null || true

if [[ $PURGE -eq 1 ]]; then
  echo "==> --purge: desinstalando Asterisk y dependencias..."
  apt-get purge -y asterisk asterisk-config asterisk-modules asterisk-core-sounds-* \
    asterisk-dahdi dahdi-linux libgpiod2 gpiod espeak sox 2>/dev/null || warn "Algunos paquetes no se pudieron purgar"
  apt-get autoremove -y 2>/dev/null || true
  rm -rf /var/lib/asterisk /var/spool/asterisk /var/log/asterisk /etc/asterisk /usr/lib/asterisk 2>/dev/null || true
  log "Asterisk y dependencias eliminados."
else
  warn "Asterisk conservado. Para eliminarlo tambien: vuelva a correr con --purge"
fi

log "ZetronPOC desinstalado por completo."
echo ""
echo "  Si conservo Asterisk y no lo usa para nada mas, puede quitarlo con:"
echo "    curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/src/zetronpoc/desinstalador.sh | sudo bash -s -- --purge"