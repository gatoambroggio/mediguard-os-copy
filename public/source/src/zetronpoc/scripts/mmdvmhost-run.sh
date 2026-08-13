#!/usr/bin/env bash
# mmdvmhost-run.sh - wrapper de arranque de MMDVMHost (MediGuard / ZetronPOC).
# ----------------------------------------------------------------------------
# 1) Resuelve el puerto real del modulo MMDVM sondando GET_VERSION en
#    ttyUSB0/ttyAMA0/ttyS0 (via mmdvm_detect_port.py). Si el puerto del .ini no
#    responde, busca el que si y reescribe Port/UARTPort del .ini. Sin esto,
#    forzar /dev/ttyS0 (mini-UART) deja a MMDVMHost hablando al vacio y la LED
#    roja del modulo titilando para siempre (nunca hace handshake).
# 2) Espera a que ese puerto exista antes de lanzar MMDVM-Host (asi el servicio
#    queda "active" aunque el modulo no este conectado al arrancar, y arranca
#    solo al conectarlo).
#
# Uso: mmdvmhost-run.sh [/path/to/MMDVM.ini]
set -u
INI="${1:-/opt/zetronpoc/mmdvm/MMDVM.ini}"
BIN="/usr/local/bin/MMDVM-Host"
PROBE="/opt/zetronpoc/scripts/mmdvm_detect_port.py"
APP_DIR="/opt/zetronpoc"
DB="${APP_DIR}/database/zetronpoc.db"

if [[ ! -x "$BIN" ]]; then
  echo "[mmdvm-run] falta el binario $BIN (todavia compilando?). Reintentando en 10s..." >&2
  sleep 10; exit 1
fi

port_from_ini() {
  awk -F= '/^\[Modem\]/{f=1;next} /^\[/{f=0} f&&tolower($1)~/^[[:space:]]*port[[:space:]]*$/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$INI" 2>/dev/null
}
uart_from_ini() {
  awk -F= '/^\[Modem\]/{f=1;next} /^\[/{f=0} f&&tolower($1)~/^[[:space:]]*uartport[[:space:]]*$/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$INI" 2>/dev/null
}
baud_from_ini() {
  awk -F= '/^\[Modem\]/{f=1;next} /^\[/{f=0} f&&tolower($1)~/^[[:space:]]*uartspeed[[:space:]]*$/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$INI" 2>/dev/null
}

set_ini_port() { # set_ini_port <port>  -> reescribe Port y UARTPort del .ini
  local p="$1"
  [[ ! -f "$INI" ]] && return
  python3 - "$INI" "$p" <<'PYEOF'
import sys, re
path, port = sys.argv[1], sys.argv[2]
try:
    txt = open(path).read()
except Exception:
    sys.exit(1)
def repl(section, key, val, s):
    # reemplaza key= dentro de [section]; si no existe, lo agrega tras la seccion
    pat = re.compile(r'(\['+section+r'\][^\[]*?'+key+r'\s*=\s*)([^\r\n]*)', re.I|re.S)
    if pat.search(s):
        return pat.sub(lambda m: m.group(1)+val, s, count=1)
    return s
txt = repl("Modem", "Port", port, txt)
txt = repl("Modem", "UARTPort", port, txt)
open(path, "w").write(txt)
PYEOF
}

save_db_port() { # save_db_port <port>
  local p="$1"
  [[ ! -f "$DB" ]] && return
  python3 - "$DB" "$p" <<'PYEOF'
import sqlite3, sys
db, port = sys.argv[1], sys.argv[2]
try:
    c = sqlite3.connect(db)
    c.execute("INSERT OR REPLACE INTO config(clave,valor) VALUES('mmdvm_serial_port',?)", (port,))
    c.commit(); c.close()
except Exception:
    pass
PYEOF
}

resolve_port() {
  local ini_port ini_baud detected
  ini_port="$(port_from_ini)"; ini_port="${ini_port:-$(uart_from_ini)}"
  ini_baud="$(baud_from_ini)"; ini_baud="${ini_baud:-115200}"
  if [[ -x "$PROBE" ]]; then
    # probar primero el puerto del .ini
    if [[ -n "$ini_port" ]]; then
      detected="$(python3 "$PROBE" "$ini_port" "$ini_baud" 2>/dev/null || true)"
    fi
    # si no responde, barrer todos los candidatos
    if [[ -z "$detected" ]]; then
      detected="$(python3 "$PROBE" "" "$ini_baud" 2>/dev/null || true)"
    fi
    if [[ -n "$detected" ]]; then
      if [[ "$detected" != "$ini_port" ]]; then
        echo "[mmdvm-run] puerto detectado: ${detected} (el .ini tenia ${ini_port:-<vacio>}); corrigiendo .ini + BD..."
        set_ini_port "$detected"
        save_db_port "$detected"
      else
        echo "[mmdvm-run] puerto confirmado: ${detected}"
      fi
      PORT="$detected"
      return
    fi
    echo "[mmdvm-run] ningun puerto respondio al handshake. Usando ${ini_port:-/dev/ttyUSB0} (a la espera del modulo)..."
  else
    echo "[mmdvm-run] ${PROBE} no encontrado; usando puerto del .ini."
  fi
  PORT="${ini_port:-/dev/ttyUSB0}"
}

RESOLVE_PORT="${MMDVM_AUTODETECT:-1}"
if [[ "$RESOLVE_PORT" == "1" ]]; then
  resolve_port
else
  PORT="$(port_from_ini)"; PORT="${PORT:-$(uart_from_ini)}"; PORT="${PORT:-/dev/ttyUSB0}"
fi

echo "[mmdvm-run] esperando modulo MMDVM en ${PORT} ..."
QUICK_FAILS=0
while true; do
  while [[ ! -e "$PORT" ]]; do sleep 2; done
  echo "[mmdvm-run] ${PORT} disponible -> lanzando MMDVMHost (${INI})"
  start_ts="$(date +%s)"
  "$BIN" "$INI" 2>&1 | sed 's/^/[mmdvm] /' || true
  elapsed=$(( $(date +%s) - start_ts ))
  echo "[mmdvm-run] MMDVMHost salio tras ${elapsed}s (modulo desconectado o error). Reintentando en 3s..."
  # si sale muy rapido 3 veces seguidas, el puerto probablemente dejo de
  # responder -> volver a sondear antes de reintentar.
  if (( elapsed < 10 )); then
    QUICK_FAILS=$((QUICK_FAILS+1))
  else
    QUICK_FAILS=0
  fi
  if (( QUICK_FAILS >= 3 )) && [[ "$RESOLVE_PORT" == "1" && -x "$PROBE" ]]; then
    echo "[mmdvm-run] 3 caidas rapidas -> re-sondeando puerto..."
    resolve_port
    QUICK_FAILS=0
  fi
  sleep 3
done