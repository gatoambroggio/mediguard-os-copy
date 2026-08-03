#!/usr/bin/env bash
# ============================================================================
# install.sh - Sistema de Paginación Hospitalaria POCSAG sobre VoIP
# Objetivo: Ubuntu Server 22.04 LTS
# Uso:     sudo bash install.sh
# ============================================================================
set -euo pipefail

# ----------------------------- Variables -------------------------------------
APP_DIR="/opt/pocsag-server"
AST_USER="asterisk"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/pocsag-install.log"

# Colores
GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; NC="\033[0m"
log()  { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*" >&2; }

# ----------------------------- Prechecks -------------------------------------
if [[ $EUID -ne 0 ]]; then
  err "Ejecutá como root o con sudo."
  exit 1
fi

if ! grep -q 'Ubuntu 22.04' /etc/os-release 2>/dev/null; then
  warn "No se detectó Ubuntu 22.04. Continuando bajo tu responsabilidad."
fi

echo "==> Instalando sistema POCSAG en ${APP_DIR}"
mkdir -p "${LOG_FILE%/*}" || true
exec > >(tee -a "${LOG_FILE}") 2>&1

export DEBIAN_FRONTEND=noninteractive

# ----------------------------- 1. Paquetes -----------------------------------
echo "==> 1/8 Instalando dependencias del sistema..."
apt-get update -y
apt-get install -y \
  asterisk \
  asterisk-config \
  asterisk-doc \
  sqlite3 \
  python3 \
  python3-pip \
  alsa-utils \
  sox \
  git \
  libgpiod2 \
  gpiod \
  curl \
  ca-certificates \
  logrotate

# Codificador POCSAG (Opción C: Python)
echo "==> 1b Instalando codificador POCSAG (python)..."
pip3 install --break-system-packages pocsag || warn "No se pudo instalar paquete pocsag (revisar manualmente)"

# ----------------------------- 2. Estructura ---------------------------------
echo "==> 2/8 Creando estructura de directorios..."
mkdir -p "${APP_DIR}"/{etc/asterisk,etc/pocsag,etc/systemd,bin,audio,db,logs,docs}
cp -r "${SCRIPT_DIR}/docs"/* "${APP_DIR}/docs/" 2>/dev/null || true
cp -r "${SCRIPT_DIR}/etc"/* "${APP_DIR}/etc/" 2>/dev/null || true
cp -r "${SCRIPT_DIR}/bin"/* "${APP_DIR}/bin/" 2>/dev/null || true
cp -r "${SCRIPT_DIR}/audio"/* "${APP_DIR}/audio/" 2>/dev/null || true

chmod +x "${APP_DIR}/bin"/*.sh "${APP_DIR}/bin"/*.agi 2>/dev/null || true

# ----------------------------- 3. Base de datos ------------------------------
echo "==> 3/8 Inicializando base de datos SQLite..."
DB="${APP_DIR}/db/pocsag.db"
sqlite3 "${DB}" <<'SQL'
CREATE TABLE IF NOT EXISTS codigos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo TEXT UNIQUE NOT NULL,
  tipo TEXT NOT NULL,
  cap_code TEXT,
  baudios INTEGER DEFAULT 1200,
  descripcion TEXT,
  activo INTEGER DEFAULT 1
);
CREATE TABLE IF NOT EXISTS grupos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  nombre TEXT UNIQUE NOT NULL,
  cap_code TEXT,
  baudios INTEGER DEFAULT 1200
);
CREATE TABLE IF NOT EXISTS grupo_miembros (
  grupo_id INTEGER REFERENCES grupos(id),
  cap_code TEXT NOT NULL,
  PRIMARY KEY (grupo_id, cap_code)
);
CREATE TABLE IF NOT EXISTS bitacora (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fecha_hora DATETIME DEFAULT CURRENT_TIMESTAMP,
  interno_origen TEXT,
  codigo TEXT,
  cap_code TEXT,
  mensaje TEXT,
  baudios INTEGER,
  estado TEXT,
  observaciones TEXT
);
-- Códigos de ejemplo
INSERT OR IGNORE INTO codigos (codigo,tipo,cap_code,baudios,descripcion) VALUES
 ('11','grupo','100001',1200,'Código Azul (paro cardíaco)'),
 ('12','broadcast','200001',1200,'Código Rojo (incendio)'),
 ('13','broadcast','200002',1200,'Código Blanco (evacuación)'),
 ('21','individual','300021',1200,'Médico de guardia'),
 ('99','individual','300099',512,'Prueba de sistema');
SQL
chown -R asterisk:asterisk "${APP_DIR}"
chmod 640 "${DB}"

# ----------------------------- 4. Dialplan Asterisk --------------------------
echo "==> 4/8 Configurando dialplan de Asterisk..."
DIALPLAN="${APP_DIR}/etc/asterisk/extensions_pocsag.conf"
if [[ ! -f "${DIALPLAN}" ]]; then
cat > "${DIALPLAN}" <<'DIAL'
[pocsag-incoming]
exten => 2184,1,NoOp(Paginación hospitalaria)
 same => n,Answer()
 same => n,Set(TIMEOUT(digit)=5)
 same => n,Set(TIMEOUT(response)=20)
 same => n,Playback(marque-codigo)
 same => n,Playback(beep)
 same => n,Read(CODE,,8,,3,5)
 same => n,GotoIf($["${CODE}" = ""]?fin:error)
 same => n,Playback(marque-mensaje)
 same => n,Playback(beep)
 same => n,Read(MESSAGE,,16,,3,8)
 same => n,AGI(agi_pocsag.agi,${CALLERID(num)},${CODE},${MESSAGE})
 same => n,Playback(confirmado)
 same => n(fin),Hangup()
 same => n(error),Playback(codigo-invalido)
 same => n,Hangup()
DIAL
fi

# Incluir el dialplan y el contexto en la config de Asterisk
AST_ETC="/etc/asterisk"
mkdir -p "${AST_ETC}"
cp "${DIALPLAN}" "${AST_ETC}/extensions_pocsag.conf"
grep -q 'extensions_pocsag.conf' "${AST_ETC}/extensions.conf" 2>/dev/null \
  || echo '#include extensions_pocsag.conf' >> "${AST_ETC}/extensions.conf"

# ----------------------------- 5. AGI ----------------------------------------
echo "==> 5/8 Instalando AGI y scripts..."
AGI_SRC="${APP_DIR}/bin/agi_pocsag.agi"
if [[ ! -f "${AGI_SRC}" ]]; then
cat > "${AGI_SRC}" <<'AGI'
#!/usr/bin/env bash
set -euo pipefail
INTERNO="$1"; CODIGO="$2"; MENSAJE="$3"
BASE=/opt/pocsag-server
DB="$BASE/db/pocsag.db"
ROW=$(sqlite3 "$DB" "SELECT cap_code, baudios, tipo FROM codigos WHERE codigo='$CODIGO' AND activo=1")
[ -z "$ROW" ] && { echo "ESTADO=error" >&2; exit 1; }
CAPCODE=$(echo "$ROW" | cut -d'|' -f1)
BAUD=$(echo "$ROW" | cut -d'|' -f2)
WAV="$BASE/audio/out_${CAPCODE}.wav"
"$BASE/bin/pocsag_encode.sh" "$CAPCODE" "$MENSAJE" "$BAUD" "$WAV"
"$BASE/bin/ptt_on.sh"
aplay -q "$WAV"
"$BASE/bin/ptt_off.sh"
sqlite3 "$DB" "INSERT INTO bitacora (interno_origen,codigo,cap_code,mensaje,baudios,estado)
               VALUES ('$INTERNO','$CODIGO','$CAPCODE','$MENSAJE','$BAUD','enviado');"
AGI
chmod +x "${AGI_SRC}"
fi
cp "${AGI_SRC}" /var/lib/asterisk/agi-bin/ 2>/dev/null || {
  mkdir -p /var/lib/asterisk/agi-bin && cp "${AGI_SRC}" /var/lib/asterisk/agi-bin/
}
chown -R asterisk:asterisk /var/lib/asterisk/agi-bin

# Scripts de soporte
[[ -f "${APP_DIR}/bin/pocsag_encode.sh" ]] || cat > "${APP_DIR}/bin/pocsag_encode.sh" <<'ENC'
#!/usr/bin/env bash
# args: capcode mensaje baudios salida.wav
python3 -c "
from pocsag import encode
import sys
encode(sys.argv[4], [(int(sys.argv[1]), 'N', sys.argv[2])], baud=int(sys.argv[3]))
" "$@"
ENC
chmod +x "${APP_DIR}/bin/pocsag_encode.sh"

[[ -f "${APP_DIR}/bin/ptt_on.sh" ]] || cat > "${APP_DIR}/bin/ptt_on.sh" <<'PTT'
#!/usr/bin/env bash
# Ajustar chip/pin al hardware real. Ver docs/SISTEMA_PAGERS_POCSAG.md sección 7.
gpioset gpiochip4 17=1 2>/dev/null || echo "PTT ON (stub - configurar)" 
PTT
[[ -f "${APP_DIR}/bin/ptt_off.sh" ]] || cat > "${APP_DIR}/bin/ptt_off.sh" <<'PTT'
#!/usr/bin/env bash
gpioset gpiochip4 17=0 2>/dev/null || echo "PTT OFF (stub - configurar)"
PTT
chmod +x "${APP_DIR}/bin/ptt_on.sh" "${APP_DIR}/bin/ptt_off.sh"

# ----------------------------- 6. Locuciones IVR -----------------------------
echo "==> 6/8 Generando locuciones IVR (TTS de prueba)..."
gen_tts() { # nombre texto
  local out="${APP_DIR}/audio/$1.gsm"
  [[ -f "$out" ]] && return
  espeak -s 160 "$2" -w "${out%.gsm}.wav" 2>/dev/null \
    && sox "${out%.gsm}.wav" -r 8000 -c 1 "$out" 2>/dev/null \
    || warn "No se pudo generar $1 (instalar espeak o grabar manualmente)"
  rm -f "${out%.gsm}.wav"
}
apt-get install -y espeak 2>/dev/null || true
gen_tts marque-codigo "Marque su número de código"
gen_tts marque-mensaje "Marque su mensaje"
gen_tts confirmado "Mensaje enviado"
gen_tts codigo-invalido "Código inválido"
# beep
[[ -f "${APP_DIR}/audio/beep.gsm" ]] || sox -n -r 8000 -c 1 "${APP_DIR}/audio/beep.gsm" synth 0.2 sine 1000 2>/dev/null \
  || warn "beep.gsm no generado"
cp "${APP_DIR}"/audio/*.gsm /var/lib/asterisk/sounds/ 2>/dev/null || true
chown -R asterisk:asterisk /var/lib/asterisk/sounds/ 2>/dev/null || true

# ----------------------------- 7. systemd ------------------------------------
echo "==> 7/8 Configurando servicios systemd..."
SVC="${APP_DIR}/etc/systemd/pocsag-monitor.service"
[[ -f "$SVC" ]] || cat > "$SVC" <<'SVCU'
[Unit]
Description=Monitor del sistema de paginación POCSAG
After=asterisk.service network.target

[Service]
Type=simple
ExecStart=/bin/bash -lc 'while true; do systemctl is-active --quiet asterisk || systemctl restart asterisk; sleep 30; done'
Restart=always

[Install]
WantedBy=multi-user.target
SVCU
cp "$SVC" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now asterisk pocsag-monitor 2>/dev/null || warn "Asterisk/monitor no pudo activarse (revisar dependencias)"
asterisk -rx "dialplan reload" 2>/dev/null || warn "No se pudo recargar dialplan"

# ----------------------------- 8. Chequeo final ------------------------------
echo "==> 8/8 Chequeo final..."
ok=1
command -v asterisk   >/dev/null || { err "Asterisk no disponible"; ok=0; }
command -v sqlite3    >/dev/null || { err "sqlite3 no disponible"; ok=0; }
command -v python3    >/dev/null || { err "python3 no disponible"; ok=0; }
command -v aplay      >/dev/null || { err "alsa-utils no disponible"; ok=0; }
python3 -c "import pocsag" 2>/dev/null || warn "Paquete python pocsag no importable (ver instalacion)"
[[ -f "${DB}" ]] || { err "Base de datos no creada"; ok=0; }

echo "--------------------------------------------"
if [[ $ok -eq 1 ]]; then
  log "Instalación completada en ${APP_DIR}"
else
  warn "Instalación parcial. Revisar mensajes [ERR] arriba."
fi
cat <<'EOF'

PROXIMOS PASOS:
  1. Editar bin/ptt_on.sh y bin/ptt_off.sh con el pin GPIO real de tu hardware.
  2. Calibrar nivel de audio y desviación del transmisor (±4.5 kHz POCSAG).
  3. Configurar un interno SIP (o trunk) que use el contexto [pocsag-incoming].
  4. Marcar 2184 y probar el flujo de paginación.
  5. Revisar bitácora: sqlite3 /opt/pocsag-server/db/pocsag.db "SELECT * FROM bitacora ORDER BY id DESC LIMIT 5;"

Ver documentación completa: /opt/pocsag-server/docs/SISTEMA_PAGERS_POCSAG.md
EOF