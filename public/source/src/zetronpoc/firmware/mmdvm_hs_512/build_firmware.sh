#!/usr/bin/env bash
# Compila el firmware POCSAG_512 (env pocsag512-144) y copia el .bin al fork.
#
# Requisitos: PlatformIO Core  (pip install platformio)  + toolchain ARM
# (PIO baja el toolchain solo la primera vez).
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

cd "$TARGET"

if ! command -v pio >/dev/null 2>&1; then
  echo "ERROR: platformio (pio) no esta instalado. Instala con:  pip install platformio"
  exit 1
fi

echo "[1/2] pio run -e pocsag512-144  (compila firmware 512 baud)"
pio run -e pocsag512-144

BIN="$TARGET/.pio/build/pocsag512-144/firmware.bin"
if [ ! -f "$BIN" ]; then
  echo "ERROR: no se genero $BIN . Revisa el log de pio arriba."
  exit 1
fi

OUT="$HERE/firmware_pocsag512.bin"
cp "$BIN" "$OUT"
echo "[2/2] Listo: $OUT"
echo "Flashealo al STM32 del Jumbospot con:"
echo "    ./flash.sh $OUT"