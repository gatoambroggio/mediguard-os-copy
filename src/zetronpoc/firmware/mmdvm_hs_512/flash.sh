#!/usr/bin/env bash
# Flashea el firmware.bin al STM32 del Jumbospot por SERIAL (stm32flash).
#
# El firmware es STANDALONE (sin bootloader) -> se graba a 0x08000000 (0x0).
# No requiere BOOT0 jumper ni modo DFU — flashea directo por UART.
#
# Requiere stm32flash:  sudo apt install stm32flash
set -euo pipefail

BIN="${1:-firmware_pocsag512_149mhz.bin}"
PORT="${2:-/dev/ttyAMA0}"

if [ ! -f "$BIN" ]; then
  echo "Uso: flash.sh <firmware.bin> [serial_port]"
  echo "  ej: flash.sh firmware_pocsag512_149mhz.bin /dev/ttyAMA0"
  exit 1
fi

if ! command -v stm32flash >/dev/null 2>&1; then
  echo "ERROR: stm32flash no instalado.  sudo apt install stm32flash"
  exit 2
fi

echo "Flasheando $BIN a 0x08000000 via $PORT..."
sudo stm32flash -b 115200 -v -w "$BIN" -g 0x0 -R "$PORT"

echo "OK. El STM32 reseteo y arranco con el nuevo firmware."