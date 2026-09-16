#!/usr/bin/env bash
# Compila el firmware MMDVM_HS con los patches POCSAG 512 baud + 149.255 MHz.
#
# Build STANDALONE (sin bootloader USB-DFU) -> se flashea a 0x08000000 con
# stm32flash por serial (/dev/ttyAMA0). La tabla de vectores queda en 0x0.
#
# Los defines POCSAG_512 y POCSAG_149MHZ van directo en Config.h (no hace
# falta pasarlos por linea de comando al make).
#
# Requiere:
#   - gcc-arm-none-eabi libstdc++-arm-none-eabi-newlib libnewlib-arm-none-eabi
#   - El submodulo STM32F10X_Lib (clone_and_patch.sh lo inicializa)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$HERE/MMDVM_HS}"

if [ ! -d "$TARGET" ]; then
  echo "ERROR: no existe $TARGET. Corre ./clone_and_patch.sh primero."
  exit 1
fi

if [ ! -d "$TARGET/STM32F10X_Lib" ]; then
  echo "ERROR: falta STM32F10X_Lib. Corre en $TARGET:"
  echo "    git submodule init && git submodule update"
  exit 1
fi

cd "$TARGET"

if ! command -v arm-none-eabi-gcc >/dev/null 2>&1; then
  echo "ERROR: arm-none-eabi-gcc no instalado."
  echo "  Ubuntu/Debian: sudo apt install gcc-arm-none-eabi libstdc++-arm-none-eabi-newlib libnewlib-arm-none-eabi"
  exit 1
fi

echo "[1/3] make clean..."
make clean

echo "[2/3] make OSC=14745600  (standalone, TCXO 14.7456 MHz, vector table en 0x0)..."
make OSC=14745600

# mmdvm_f1.bin = standalone (sin bootloader), flashable a 0x08000000 con stm32flash
BIN="$TARGET/bin/mmdvm_f1.bin"
if [ ! -f "$BIN" ]; then
  echo "ERROR: no se genero $BIN"
  echo "  Revisa el log de make arriba."
  exit 1
fi

OUT="$HERE/firmware_pocsag512_149mhz.bin"
cp "$BIN" "$OUT"
echo "[3/3] Listo: $OUT ($(stat -c%s "$OUT") bytes)"
echo
echo "Flashealo al STM32 del Jumbospot con:"
echo "    sudo stm32flash -b 115200 -v -w $OUT -g 0x0 -R /dev/ttyAMA0"
echo
echo "Si la placa tiene write protection (NACK al ~67%):"
echo "    sudo stm32flash -k /dev/ttyAMA0  &&  power-cycle  &&  re-flashear"