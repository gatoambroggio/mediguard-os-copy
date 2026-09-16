#!/usr/bin/env bash
# Compila el firmware MMDVM_HS con los patches POCSAG 512 baud + 149.255 MHz.
#
# Usa el Makefile oficial (NO PlatformIO). Requiere:
#   - gcc-arm-none-eabi gdb-arm-none-eabi libstdc++-arm-none-eabi-newlib libnewlib-arm-none-eabi
#   - El submodulo STM32F10X_Lib (clone_and_patch.sh lo inicializa)
#
# Uso:
#     ./build_firmware.sh [MMDVM_HS_DIR]     # default: ./MMDVM_HS
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

# Verificar toolchain ARM
if ! command -v arm-none-eabi-gcc >/dev/null 2>&1; then
  echo "ERROR: arm-none-eabi-gcc no instalado."
  echo "  Ubuntu/Debian: sudo apt install gcc-arm-none-eabi libstdc++-arm-none-eabi-newlib libnewlib-arm-none-eabi"
  exit 1
fi

echo "[1/3] make clean..."
make clean

echo "[2/3] make bl  (compila firmware MMDVM_HS con bootloader STM32F1)..."
# 'bl' = con bootloader USB-DFU (para flash con dfu-util a 0x08008000)
make bl

BIN="$TARGET/bin/mmdvm_f1bl.bin"
if [ ! -f "$BIN" ]; then
  echo "ERROR: no se genero $BIN"
  echo "  Busca tambien: $TARGET/bin/mmdvm_f1.bin (sin bootloader)"
  echo "  Revisa el log de make arriba."
  exit 1
fi

OUT="$HERE/firmware_pocsag512_149mhz.bin"
cp "$BIN" "$OUT"
echo "[3/3] Listo: $OUT"
echo
echo "Flashealo al STM32 del Jumbospot con:"
echo "    ./flash.sh $OUT"
echo
echo "O si flasheas por serial (stm32flash):"
echo "    cd $TARGET && sudo make nano-hotspot"