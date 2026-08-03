#!/usr/bin/env bash
# ============================================================================
# scripts/ptt_off.sh - Desactiva PTT del transmisor.
# ============================================================================
set -euo pipefail
CHIP="gpiochip4"
PIN="17"

if [[ -c "/dev/ttyUSB0" ]]; then
  stty -F /dev/ttyUSB0 9600 2>/dev/null || true
  echo -n 'OFF' > /dev/ttyUSB0
elif command -v gpioset >/dev/null; then
  gpioset "${CHIP}" "${PIN}=0"
else
  echo "[ptt_off] Ningún método PTT disponible (gpioset/ttyUSB0). Configurar." >&2
  exit 1
fi