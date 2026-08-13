#!/usr/bin/env bash
# mmdvmhost-run.sh - wrapper de arranque de MMDVMHost (MediGuard / ZetronPOC).
# ----------------------------------------------------------------------------
# Espera a que el puerto serie del modulo MMDVM exista antes de lanzar
# MMDVM-Host. Sin esto, si el modulo no esta conectado al arrancar, MMDVMHost
# sale de inmediato ("cannot open the modem port") y con Restart=always queda
# en loop "activating" para siempre (eso es lo que el panel muestra como
# "svc activating"). Con este wrapper, ExecStart se mantiene "active" (bloqueado
# esperando el dispositivo) y en cuanto conectas el MMDVM (USB-TTL o UART de la
# Pi) arranca solo, sin manipular nada a mano.
#
# Uso: mmdvmhost-run.sh [/path/to/MMDVM.ini]
set -u
INI="${1:-/opt/zetronpoc/mmdvm/MMDVM.ini}"
BIN="/usr/local/bin/MMDVM-Host"
if [[ ! -x "$BIN" ]]; then
  echo "[mmdvm-run] falta el binario $BIN (todavia compilando?). Reintentando en 10s..." >&2
  sleep 10
  exit 1
fi

# Lee el puerto serie configurado en [Modem] del .ini (Port, fallback UARTPort).
port_from_ini() {
  awk -F= '/^\[Modem\]/{f=1;next} /^\[/{f=0} f&&tolower($1)~/^[[:space:]]*port[[:space:]]*$/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$INI" 2>/dev/null
}
PORT="$(port_from_ini)"
if [[ -z "$PORT" ]]; then
  PORT="$(awk -F= '/^\[Modem\]/{f=1;next} /^\[/{f=0} f&&tolower($1)~/^[[:space:]]*uartport[[:space:]]*$/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$INI" 2>/dev/null)"
fi
[[ -z "$PORT" ]] && PORT="/dev/ttyUSB0"

echo "[mmdvm-run] esperando modulo MMDVM en ${PORT} ..."
while true; do
  # Esperar (bloqueante) a que el puerto del modulo exista.
  while [[ ! -e "$PORT" ]]; do sleep 2; done
  echo "[mmdvm-run] ${PORT} disponible -> lanzando MMDVMHost (${INI})"
  "$BIN" "$INI" 2>&1 | sed 's/^/[mmdvm] /' || true
  echo "[mmdvm-run] MMDVMHost salio (modulo desconectado o error de config). Reintentando en 3s..."
  sleep 3
done