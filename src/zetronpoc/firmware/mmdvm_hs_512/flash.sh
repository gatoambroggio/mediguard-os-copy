#!/usr/bin/env bash
# Flashea el firmware.bin al STM32 del Jumbospot por USB-DFU.
# Previo: pones el Jumbospot en modo DFU (BOOT0=1) y lo conectas por USB.
# Requiere dfu-util:  sudo apt install dfu-util
set -euo pipefail

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
  echo "Uso: flash.sh <firmware.bin>"
  echo "  ej: flash.sh .pio/build/pocsag512-144/firmware.bin"
  exit 1
fi

if ! command -v dfu-util >/dev/null 2>&1; then
  echo "ERROR: dfu-util no instalado.  sudo apt install dfu-util"
  exit 2
fi

echo "Buscando STM32 en modo DFU..."
if ! lsusb | grep -qi "STM.*DFU"; then
  echo "WARN: no veo 'STM Device in DFU Mode' en lsusb."
  echo "      Pone el Jumbospot en DFU (puente BOOT0=1) y reconecta USB."
  echo "      Continuo igual por si el ID no matchea..."
fi

echo "Flasheando $BIN a 0x08008000..."
sudo dfu-util -a 0 -s 0x08008000:leave -D "$BIN"

echo "OK. Sacá BOOT0, desconectá/reconectá USB -> arranca con el nuevo fw."