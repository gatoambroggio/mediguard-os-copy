#!/usr/bin/env bash
# Compila el firmware MMDVM_HS con los patches POCSAG 512 baud + 149.255 MHz.
#
# Build STANDALONE (make hs, sin bootloader USB-DFU) -> se flashea a 0x08000000
# con stm32flash por serial (/dev/ttyAMA0). La tabla de vectores queda en 0x0.
# make hs = build generico para STM32F1 hotspot (el board se selecciona via
# Config.h, no via el target del make). Genera mmdvm_f1.bin flasheable a 0x0.
#
# Uso:
#   ./build_firmware.sh                          -> LIBRE_KIT_ADF7021 (default)
#   ./build_firmware.sh MMDVM_HS nanohotspot     -> NANO_HOTSPOT
#
# Los clones chinos del Nano hotSPOT vienen en lotes con pin mapping distinto:
# la misma placa fisica puede necesitar LIBRE_KIT_ADF7021 o NANO_HOTSPOT. Por eso
# se compilan las dos variantes y el instalador las prueba en orden.
#
# Requiere:
#   - gcc-arm-none-eabi libstdc++-arm-none-eabi-newlib libnewlib-arm-none-eabi
#   - El submodulo STM32F10X_Lib (clone_and_patch.sh lo inicializa)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$HERE/MMDVM_HS}"
BOARD="${2:-librekit}"

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

# --- Seleccion de board: reescribe la linea de board en Config.h ---
case "$BOARD" in
  nanohotspot|nano|NANO_HOTSPOT)
    BOARD="nanohotspot"
    python3 - Config.h <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "#define NANO_HOTSPOT" in s and "// #define NANO_HOTSPOT" not in s:
    print("    Config.h: NANO_HOTSPOT ya seleccionado")
else:
    s = s.replace("#define LIBRE_KIT_ADF7021", "// #define LIBRE_KIT_ADF7021", 1)
    s = s.replace("// #define NANO_HOTSPOT", "#define NANO_HOTSPOT", 1)
    open(p, "w", encoding="utf-8").write(s)
    print("    Config.h: board = NANO_HOTSPOT")
PY
    ;;
  *)
    BOARD="librekit"
    python3 - Config.h <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "#define LIBRE_KIT_ADF7021" in s and "// #define LIBRE_KIT_ADF7021" not in s:
    print("    Config.h: LIBRE_KIT_ADF7021 ya seleccionado")
else:
    s = s.replace("#define NANO_HOTSPOT", "// #define NANO_HOTSPOT", 1)
    s = s.replace("// #define LIBRE_KIT_ADF7021", "#define LIBRE_KIT_ADF7021", 1)
    open(p, "w", encoding="utf-8").write(s)
    print("    Config.h: board = LIBRE_KIT_ADF7021")
PY
    ;;
esac

# El ADF7021 debe quedar siempre habilitado en las dos variantes
grep -q '^#define ENABLE_ADF7021' Config.h || {
  echo "ERROR: falta #define ENABLE_ADF7021 en Config.h"
  exit 1
}

echo "[1/3] make clean..."
make clean

echo "[2/3] make hs OSC=14745600  (standalone, TCXO 14.7456 MHz)..."
make hs OSC=14745600

# mmdvm_f1.bin = standalone (sin bootloader), vector table en 0x08000000.
# Flashear a 0x08000000 (0x0) con stm32flash.
BIN="$TARGET/bin/mmdvm_f1.bin"
if [ ! -f "$BIN" ]; then
  echo "ERROR: no se genero $BIN"
  echo "  Revisa el log de make arriba."
  exit 1
fi

if [ "$BOARD" = "nanohotspot" ]; then
  OUT="$HERE/firmware_pocsag512_149mhz_nano.bin"
else
  OUT="$HERE/firmware_pocsag512_149mhz.bin"
fi
cp "$BIN" "$OUT"
echo "[3/3] Listo: $OUT ($(stat -c%s "$OUT") bytes)  [board=$BOARD]"
echo
echo "Flashealo al STM32 del hotspot con:"
echo "    sudo ./flash.sh $OUT"
echo
echo "Si la placa tiene write protection (NACK al ~67%):"
echo "    sudo stm32flash -k /dev/ttyAMA0  &&  power-cycle  &&  re-flashear"