#!/usr/bin/env bash
# ============================================================================
# install.sh - Instalador del sistema POCSAG para Ubuntu Server 22.04
# Uso: sudo bash install.sh
# ============================================================================
set -euo pipefail

APP_DIR="/opt/pocsag-server"
AST_USER="asterisk"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/pocsag-install.log"

GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; NC="\033[0m"
log()  { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*" >&2; }

# ----------------------------- Prechecks -------------------------------------
[[ $EUID -ne 0 ]] && { err "Ejecutá como root o con sudo."; exit 1; }

if ! grep -q 'Ubuntu 22.04' /etc/os-release 2>/dev/null; then
  warn "No se detectó Ubuntu 22.04. Continuando bajo tu responsabilidad."
fi

echo "==> Instalando sistema POCSAG en ${APP_DIR}"
mkdir -p "${LOG_FILE%/*}"
exec > >(tee -a "${LOG_FILE}") 2>&1
export DEBIAN_FRONTEND=noninteractive

# ----------------------------- 1. Paquetes ----------------------------------
echo "==> 1/9 Instalando dependencias del sistema..."
apt-get update -y
apt-get install -y \
  asterisk \
  sqlite3 \
  python3 \
  python3-pip \
  alsa-utils \
  sox \
  git \
  libgpiod2 gpiod \
  curl ca-certificates \
  logrotate espeak

echo "==> 1b Instalando codificador POCSAG (python)..."
pip3 install --break-system-packages pocsag 2>/dev/null || warn "No se pudo instalar python-pocsag (verificar manualmente)"

# ----------------------------- 2. Estructura --------------------------------
echo "==> 2/9 Copiando estructura de archivos..."
mkdir -p "${APP_DIR}"/{asterisk,agi,encoder,database,services,scripts,config,backend,frontend,docs,tests,audio,logs}
cp -r "${SRC_DIR}"/* "${APP_DIR}/" 2>/dev/null || true
chmod +x "${APP_DIR}"/scripts/*.sh "${APP_DIR}"/encoder/*.sh "${APP_DIR}"/agi/*.py "${APP_DIR}"/backend/*.py "${APP_DIR}"/tests/run_tests.sh 2>/dev/null || true

# ----------------------------- 3. Base de datos ----------------------------
echo "==> 3/9 Inicializando base de datos SQLite..."
python3 "${APP_DIR}/database/db_manager.py" init
chown -R "${AST_USER}:${AST_USER}" "${APP_DIR}"
chmod 640 "${APP_DIR}/database/pocsag.db" 2>/dev/null || true

# ----------------------------- 4. Asterisk ----------------------------------
echo "==> 4/9 Configurando Asterisk..."
AST_ETC="/etc/asterisk"
cp "${APP_DIR}/asterisk/extensions_pocsag.conf" "${AST_ETC}/" 2>/dev/null || true
cp "${APP_DIR}/asterisk/pjsip_pocsag.conf" "${AST_ETC}/" 2>/dev/null || true
cp "${APP_DIR}/asterisk/modules.conf" "${AST_ETC}/" 2>/dev/null || true
grep -q 'extensions_pocsag.conf' "${AST_ETC}/extensions.conf" 2>/dev/null \
  || echo '#include extensions_pocsag.conf' >> "${AST_ETC}/extensions.conf"
grep -q 'pjsip_pocsag.conf' "${AST_ETC}/pjsip.conf" 2>/dev/null \
  || echo '#include pjsip_pocsag.conf' >> "${AST_ETC}/pjsip.conf"

# ----------------------------- 5. AGI ---------------------------------------
echo "==> 5/9 Instalando AGI..."
mkdir -p /var/lib/asterisk/agi-bin
cp "${APP_DIR}/agi/pocsag_handler.py" /var/lib/asterisk/agi-bin/
chmod +x /var/lib/asterisk/agi-bin/pocsag_handler.py
chown -R "${AST_USER}:${AST_USER}" /var/lib/asterisk/agi-bin

# ----------------------------- 6. Locuciones IVR ----------------------------
echo "==> 6/9 Generando locuciones IVR (TTS de prueba)..."
gen_tts() {
  local out="${APP_DIR}/audio/$1.gsm"
  [[ -f "$out" ]] && return
  espeak -s 160 "$2" -w "${out%.gsm}.wav" 2>/dev/null \
    && sox "${out%.gsm}.wav" -r 8000 -c 1 "$out" 2>/dev/null \
    || warn "No se pudo generar $1 (grabar manualmente)"
  rm -f "${out%.gsm}.wav"
}
gen_tts marque-codigo "Marque su numero de codigo"
gen_tts marque-mensaje "Marque su mensaje"
gen_tts confirmado "Mensaje enviado"
gen_tts error-envio "Error de envio"
gen_tts codigo-invalido "Codigo invalido"
gen_tts mensaje-invalido "Mensaje invalido"
sox -n -r 8000 -c 1 "${APP_DIR}/audio/beep.gsm" synth 0.2 sine 1000 2>/dev/null \
  || warn "beep.gsm no generado"
cp "${APP_DIR}"/audio/*.gsm /var/lib/asterisk/sounds/ 2>/dev/null || true
chown -R "${AST_USER}:${AST_USER}" /var/lib/asterisk/sounds/ 2>/dev/null || true

# ----------------------------- 7. systemd -----------------------------------
echo "==> 7/9 Instalando servicios systemd..."
cp "${APP_DIR}/services/"*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now asterisk 2>/dev/null || warn "Asterisk no pudo activarse"
systemctl enable --now pocsag-monitor 2>/dev/null || true
systemctl enable --now pocsag-api 2>/dev/null || warn "API no pudo activarse (ver deps)"

# ----------------------------- 8. logrotate ---------------------------------
echo "==> 8/9 Configurando rotación de logs..."
cat > /etc/logrotate.d/pocsag <<EOF
${APP_DIR}/logs/*.log {
  daily
  rotate 14
  compress
  missingok
  notifempty
}
EOF

# ----------------------------- 9. Recarga + chequeo -------------------------
echo "==> 9/9 Recargando Asterisk y chequeo final..."
asterisk -rx "dialplan reload" 2>/dev/null || warn "No se pudo recargar dialplan"
asterisk -rx "pjsip reload" 2>/dev/null || true
bash "${APP_DIR}/scripts/healthcheck.sh" || warn "Healthcheck reportó problemas"

echo "--------------------------------------------"
log "Instalación completada en ${APP_DIR}"
cat <<'EOF'

PROXIMOS PASOS:
  1. Editar scripts/ptt_on.sh y ptt_off.sh con el pin GPIO real del hardware.
  2. Ajustar asterisk/pjsip_pocsag.conf con el password del interno 2184.
  3. Calibrar nivel de audio y desviación del transmisor (±4.5 kHz POCSAG).
  4. Registrar un SIP usando el contexto [pocsag-incoming] y marcar 2184.
  5. Revisar bitácora: sqlite3 /opt/pocsag-server/database/pocsag.db \
     "SELECT * FROM bitacora ORDER BY id DESC LIMIT 5;"

Docs: /opt/pocsag-server/docs/INSTALACION.md
EOF