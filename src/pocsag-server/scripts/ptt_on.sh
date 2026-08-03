#!/usr/bin/env bash
# ============================================================================
# scripts/ptt_on.sh - Activa PTT del transmisor.
# AJUSTAR chip/pin al hardware real. Ver docs/SISTEMA_PAGERS_POCSAG.md sec. 7.
# ============================================================================
set -euo pipefail
CHIP="gpiochip4"
PIN="17"

if [[ -c "/dev/ttyUSB0" ]]; then
  # Modo relé/serial USB
  stty -F /dev/ttyUSB0 9600 2>/dev/null || true
  echo -n 'ON' > /dev/ttyUSB0
elif command -v gpioset >/dev/null; then
  gpioset "${CHIP}" "${PIN}=1"
else
  echo "[ptt_on] Ningún método PTT disponible (gpioset/ttyUSB0). Configurar." >&2
  exit 1
fi