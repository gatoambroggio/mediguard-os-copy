#!/usr/bin/env bash
# ============================================================================
# test_pocsag_e2e.sh — Manda un page y dice EXACTAMENTE en qué eslabón se corta.
# ============================================================================
# La cadena de un page es:
#   dispatch_mqtt.py → mosquitto_pub → BROKER → MMDVMHost → serial → módem → RF
#
# Este test no adivina: captura en simultáneo
#   - lo que sale y entra por MQTT (mosquitto_sub -t '#')
#   - lo que MMDVMHost escribe en su log (journalctl)
# mientras manda un page real, y después te dice cuál de los dos nunca se enteró.
#
# Uso:  sudo ./test_pocsag_e2e.sh [capcode] [mensaje] [segundos]
#   Ej: sudo ./test_pocsag_e2e.sh 0002198 "PRUEBA 123" 15
# ============================================================================
set -uo pipefail

APP_DIR="${ZETRONPOC_DIR:-/opt/zetronpoc}"
DETECTOR="${APP_DIR}/scripts/mmdvm_detect_port.py"
DISPATCH="${APP_DIR}/agi/dispatch_mqtt.py"
INI="${APP_DIR}/mmdvm/MMDVM.ini"

CAP="${1:-0002198}"
MSG="${2:-PRUEBA 123}"
ESPERA="${3:-15}"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
ok(){   echo -e "  ${G}✓${N} $1"; }
fail(){ echo -e "  ${R}✗${N} $1"; }
warn(){ echo -e "  ${Y}!${N} $1"; }
hdr(){  echo -e "\n${C}${B}━━━ $1 ━━━${N}"; }

[ "$(id -u)" -eq 0 ] || { fail "Correr con sudo"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
MQTT_LOG="${TMP}/mqtt.log"; JRNL_LOG="${TMP}/mmdvm.log"

echo -e "${B}${C}╔══════════════════════════════════════════════════════╗${N}"
echo -e "${B}${C}║  Test POCSAG punta a punta — ¿dónde se corta?         ║${N}"
echo -e "${B}${C}╚══════════════════════════════════════════════════════╝${N}"

# ---------------------------------------------------------------------------
hdr "1/5 Firmware que tiene la placa HOY"
systemctl stop mmdvmhost 2>/dev/null || true
sleep 1
PORT="$(python3 "$DETECTOR" 2>/dev/null || true)"
PORT="${PORT:-/dev/ttyAMA0}"
VER=""
if [ -x "$DETECTOR" ]; then
  VER="$(python3 "$DETECTOR" "$PORT" 115200 --version 2>/dev/null | cut -f2 || true)"
fi
systemctl start mmdvmhost 2>/dev/null || true
sleep 3

echo -e "  Puerto: ${B}${PORT}${N}"
if [ -n "$VER" ]; then
  echo -e "  Versión: ${B}${VER}${N}"
  if printf '%s' "$VER" | grep -qi '512'; then
    ok "el string menciona 512 → el firmware custom PARE CE estar puesto"
  else
    warn "el string NO menciona 512 → es firmware stock (1200 baud), no el custom"
    echo "    Sin el custom, los pagers de 512 baud no van a decodificar aunque"
    echo "    la frecuencia sea válida y el PTT se mueva."
  fi
else
  fail "la placa no respondió (sin servicio o sin firmware arrancado)"
fi

# ---------------------------------------------------------------------------
hdr "2/5 Configuración actual"
if [ -f "$INI" ]; then
  ini_get(){
    awk -v sec="$1" -v key="$2" '
      BEGIN { tgt=tolower(sec); gsub(/[[:space:]]/,"",tgt); tgt="["tgt"]" }
      /^[[:space:]]*\[/ { s=$0; gsub(/[[:space:]]/,"",s); f=(tolower(s)==tgt)?1:0; next }
      f && $0 !~ /^[[:space:]]*[;#]/ && index($0,"=") {
        split($0,kv,"="); k=tolower(kv[1]); gsub(/[[:space:]]/,"",k)
        if (k==tolower(key)) { v=substr($0,index($0,"=")+1); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; exit }
      }' "$INI" 2>/dev/null
  }
  echo -e "  [General]        Duplex=${B}$(ini_get General Duplex)${N}  POCSAG=${B}$(ini_get General POCSAG)${N}"
  echo -e "  [Modem]          UARTSpeed=${B}$(ini_get Modem UARTSpeed)${N}  TXFreq=${B}$(ini_get Modem TXFrequency)${N}"
  echo -e "  [POCSAG]         Enable=${B}$(ini_get POCSAG Enable)${N}"
  echo -e "  [MQTT]           Enable=${B}$(ini_get MQTT Enable)${N}  Name=${B}$(ini_get MQTT Name)${N}  Port=${B}$(ini_get MQTT Port)${N}"
  echo -e "  [Remote Control] Enable=${B}$(ini_get 'Remote Control' Enable)${N}  Port=${B}$(ini_get 'Remote Control' Port)${N}"
else
  fail "no se encontró $INI"
fi

# ---------------------------------------------------------------------------
hdr "3/5 Capturando MQTT y log de MMDVMHost mientras se manda el page"
if command -v mosquitto_sub >/dev/null 2>&1; then
  timeout $((ESPERA + 5)) mosquitto_sub -h 127.0.0.1 -p 1883 -t '#' -v >"$MQTT_LOG" 2>&1 &
  MSUB=$!
  ok "escuchando todo el tráfico MQTT"
else
  MSUB=""
  warn "mosquitto_sub no instalado (sudo apt install mosquitto-clients) — se omite esta parte"
fi
timeout $((ESPERA + 5)) journalctl -u mmdvmhost -f -n 0 --no-pager >"$JRNL_LOG" 2>&1 &
JRN=$!
sleep 2

# ---------------------------------------------------------------------------
hdr "4/5 Mandando el page"
if [ ! -f "$DISPATCH" ]; then
  fail "no existe $DISPATCH"
else
  echo -e "  $ ${B}python3 $DISPATCH $CAP \"$MSG\"${N}"
  python3 "$DISPATCH" "$CAP" "$MSG" || warn "dispatch_mqtt.py devolvió error"
fi
echo -e "  Esperando ${ESPERA}s a que MMDVMHost procese..."
sleep "$ESPERA"

[ -n "$MSUB" ] && kill "$MSUB" 2>/dev/null || true
kill "$JRN" 2>/dev/null || true
sleep 0.5

# ---------------------------------------------------------------------------
hdr "5/5 Qué pasó realmente"

echo -e "\n  ${B}Tráfico MQTT observado:${N}"
if [ -s "$MQTT_LOG" ]; then
  sed 's/^/    /' "$MQTT_LOG" | head -25
  if grep -qiE '(^|[[:space:]])[^[:space:]]*command[[:space:]].*page' "$MQTT_LOG"; then
    ok "el page SÍ salió publicado al broker"
  fi
else
  warn "no se capturó nada (o mosquitto_sub no está instalado)"
fi

echo -e "\n  ${B}Log de MMDVMHost durante el test:${N}"
if [ -s "$JRNL_LOG" ]; then
  sed 's/^/    /' "$JRNL_LOG" | tail -40
else
  warn "(vacío) — MMDVMHost no escribió NI UNA línea en esos ${ESPERA}s"
fi

# --- Veredicto ---
hdr "VEREDICTO"
PUBLICADO=0; RECIBIDO=0
grep -qiE 'page' "$MQTT_LOG" 2>/dev/null && PUBLICADO=1
if [ -s "$JRNL_LOG" ]; then
  grep -qiE 'pocsag|transmitted|command|nak|page' "$JRNL_LOG" && RECIBIDO=1
fi

if [ "$PUBLICADO" = "1" ] && [ "$RECIBIDO" = "0" ]; then
  fail "EL PAGE SE PUBLICA AL VACÍO."
  echo "    Salió al broker MQTT, pero MMDVMHost no reaccionó: no está suscrito"
  echo "    a ese topic. La cadena se corta acá, antes de tocar el módem."
  echo "    → Hay que hacer que MMDVMHost reciba el comando (topic/suscripción)."
elif [ "$PUBLICADO" = "1" ] && [ "$RECIBIDO" = "1" ]; then
  if grep -qi 'transmitted' "$JRNL_LOG"; then
    ok "MMDVMHost TRANSMITIÓ el POCSAG (llegó al módem)."
    echo "    El corte está DESPUÉS del host: firmware/baud/frecuencia/pager."
  elif grep -qi 'nak' "$JRNL_LOG"; then
    fail "el módem respondió NAK — rechazó la config o la frecuencia."
  else
    warn "MMDVMHost reaccionó pero no llegó a 'Transmitted POCSAG'."
    echo "    Mirá las líneas de arriba: ahí está el motivo exacto."
  fi
else
  warn "no se pudo determinar con certeza."
  echo "    Pegame la salida completa de este test y lo interpreto."
fi

echo ""
echo "  Para ver el log en vivo mientras mandás pages desde el panel:"
echo "    sudo journalctl -u mmdvmhost -f"
echo ""