#!/usr/bin/env bash
# Clona el MMDVM_HS oficial (juribeparada) y aplica el parche del flag POCSAG_512.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="https://github.com/juribeparada/MMDVM_HS.git"
TARGET="${1:-$HERE/MMDVM_HS}"

echo "[1/3] Clonando $SRC -> $TARGET"
if [ -d "$TARGET" ]; then
  echo "    ya existe $TARGET, salteando clone (borralo a mano si queres re-clonar)"
else
  git clone "$SRC" "$TARGET"
fi

cd "$TARGET"
echo "[2/3] Aplicando patches/ADF7021.h.patch"
PATCH="$HERE/patches/ADF7021.h.patch"

if git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
  echo "    parche aplicado (git apply)"
elif git apply --3way "$PATCH" 2>/dev/null; then
  echo "    parche aplicado (git apply --3way)"
else
  echo "    WARN: git apply fallo. Aplicando reemplazo por sed (fallback robusto)."
  # Fallback: reemplaza el #define ADF7021_REG3_POCSAG por el bloque condicional.
  # 14.7456 MHz
  python3 - "$PATCH" <<'PY'
import sys, re, io
path = "ADF7021.h"
with open(path, encoding="utf-8", errors="replace") as f:
    s = f.read()

block_147456 = """#if defined(POCSAG_512)
// 512 baud: DEMOD_CLK_DIVIDE=4 (DEMOD_CLK=3.6864MHz), CDR_CLK_DIVIDE=225 -> CDR_CLK=16384=32x512
#define ADF7021_REG3_POCSAG      0x2A4F8513
#else
// 1200 baud (default): DEMOD_CLK_DIVIDE=2 (7.3728MHz), CDR_CLK_DIVIDE=192 -> CDR_CLK=38400=32x1200
#define ADF7021_REG3_POCSAG      0x2A4F0093
#endif"""
block_122880 = """#if defined(POCSAG_512)
// 512 baud: DEMOD_CLK_DIVIDE=3 (DEMOD_CLK=4.096MHz), CDR_CLK_DIVIDE=250 -> CDR_CLK=16384=32x512
#define ADF7021_REG3_POCSAG      0x29EFE8D3
#else
// 1200 baud (default): DEMOD_CLK_DIVIDE=2 (6.144MHz), CDR_CLK_DIVIDE=160 -> CDR_CLK=38400=32x1200
#define ADF7021_REG3_POCSAG      0x29EE8093
#endif"""

# Reemplaza solo la linea plana del macro en cada variante (hex univoco).
before = s
s = s.replace("#define ADF7021_REG3_POCSAG      0x2A4F0093", block_147456, 1)
s = s.replace("#define ADF7021_REG3_POCSAG      0x29EE8093", block_122880, 1)
if s == before:
    print("    ERROR: no se encontro ADF7021_REG3_POCSAG para reemplazar.")
    sys.exit(1)
with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("    parche aplicado por fallback Python.")
PY
fi

echo "[3/3] Buscando el bit-clock real de POCSAG (STM32, NO R3)..."
echo "    R3 (ADF7021_REG3_POCSAG) es clock de RX; NO fija el baud de TX."
echo "    El baud de TX lo fija el STM32 (CIO::interrupt que drena TXD)."
echo
python3 "$HERE/tools/find_pocsag_clock.py" "$TARGET" || {
  echo
  echo "ERROR: no se pudo localizar el bit-clock. Corre el finder a mano:"
  echo "    python3 $HERE/tools/find_pocsag_clock.py $TARGET"
  echo "y pasa el reporte para escribir el patch exacto a 512 baud."
  exit 1
}
echo
echo "El reporte de arriba muestra DONDE esta el samples-per-bit de POCSAG."
echo "Con esa linea + la base rate del timer, se arma el patch a 512 baud"
echo "(round(base_rate/512) muestras/bit) envuelto en #if defined(POCSAG_512)."
echo
echo "Cuando el patch este aplicado, compila con:"
echo "    cd $HERE && ./build_firmware.sh"
echo "    (genera firmware_pocsag512.bin listo para flash.sh)"