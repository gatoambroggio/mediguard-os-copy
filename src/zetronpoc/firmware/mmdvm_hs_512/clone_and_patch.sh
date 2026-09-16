#!/usr/bin/env bash
# Clona el MMDVM_HS oficial (juribeparada), aplica los 3 patches:
#   1) Config.h  -> NANO_HOTSPOT board (BI7JTA), UART host, SIMPLEX, TCXO 14.7456
#   2) IO.h      -> VHF1_MAX extendido a 150 MHz (para 149.255 MHz)
#   3) ADF7021.h -> REG3 POCSAG a 512 baud (CLK output del ADF7021 = baud de TX)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="https://github.com/juribeparada/MMDVM_HS.git"
TARGET="${1:-$HERE/MMDVM_HS}"

echo "[1/4] Clonando $SRC -> $TARGET"
if [ -d "$TARGET" ]; then
  echo "    ya existe $TARGET, salteando clone (borralo a mano si queres re-clonar)"
else
  git clone "$SRC" "$TARGET"
fi

cd "$TARGET"

echo "[2/4] Inicializando submodulos (STM32F10X_Lib)..."
git submodule init
git submodule update

echo "[3/4] Aplicando patches..."

# --- Patch 1: Config.h (reemplazo completo por NANO_HOTSPOT) ---
cp "$HERE/patches/Config.h" Config.h
echo "    Config.h: NANO_HOTSPOT board config aplicado"

# --- Patch 2: IO.h (VHF1_MAX 148 -> 150 MHz para 149.255 MHz) ---
IO_PATCH="$HERE/patches/IO.h.patch"
if git apply --check "$IO_PATCH" 2>/dev/null; then
  git apply "$IO_PATCH"
  echo "    IO.h: VHF1_MAX extendido a 150 MHz (git apply)"
else
  # Fallback: sed directo
  python3 - "$HERE/patches/IO.h.patch" <<'PY'
import sys
with open("IO.h", encoding="utf-8", errors="replace") as f:
    s = f.read()
old = """// HS frequency ranges
#define VHF1_MIN  144000000
#define VHF1_MAX  148000000"""
new = """// HS frequency ranges
#if defined(POCSAG_149MHZ)
// Extended VHF1 for 149.255 MHz POCSAG (hospital paging)
#define VHF1_MIN  144000000
#define VHF1_MAX  150000000
#else
#define VHF1_MIN  144000000
#define VHF1_MAX  148000000
#endif"""
if old not in s:
    print("    ERROR: no se encontro el bloque VHF1_MIN/VHF1_MAX en IO.h")
    sys.exit(1)
s = s.replace(old, new, 1)
with open("IO.h", "w", encoding="utf-8") as f:
    f.write(s)
print("    IO.h: VHF1_MAX extendido a 150 MHz (fallback Python)")
PY
fi

# --- Patch 3: ADF7021.h (REG3 POCSAG 512 baud) ---
ADF_PATCH="$HERE/patches/ADF7021.h.patch"
if git apply --check "$ADF_PATCH" 2>/dev/null; then
  git apply "$ADF_PATCH"
  echo "    ADF7021.h: REG3 POCSAG 512 baud aplicado (git apply)"
elif git apply --3way "$ADF_PATCH" 2>/dev/null; then
  echo "    ADF7021.h: REG3 POCSAG 512 baud aplicado (git apply --3way)"
else
  echo "    WARN: git apply fallo para ADF7021.h. Aplicando fallback Python..."
  python3 - <<'PY'
import sys
path = "ADF7021.h"
with open(path, encoding="utf-8", errors="replace") as f:
    s = f.read()
block_147456 = """#if defined(POCSAG_512)
// 512 baud: DEMOD_CLK_DIVIDE=4, CDR_CLK_DIVIDE=225 -> CDR_CLK=16384=32x512
#define ADF7021_REG3_POCSAG      0x2A4F8513
#else
// 1200 baud (default): DEMOD_CLK_DIVIDE=2, CDR_CLK_DIVIDE=192 -> CDR_CLK=38400=32x1200
#define ADF7021_REG3_POCSAG      0x2A4F0093
#endif"""
block_122880 = """#if defined(POCSAG_512)
// 512 baud: DEMOD_CLK_DIVIDE=3, CDR_CLK_DIVIDE=250 -> CDR_CLK=16384=32x512
#define ADF7021_REG3_POCSAG      0x29EFE8D3
#else
// 1200 baud (default): DEMOD_CLK_DIVIDE=2, CDR_CLK_DIVIDE=160 -> CDR_CLK=38400=32x1200
#define ADF7021_REG3_POCSAG      0x29EE8093
#endif"""
before = s
s = s.replace("#define ADF7021_REG3_POCSAG      0x2A4F0093", block_147456, 1)
s = s.replace("#define ADF7021_REG3_POCSAG      0x29EE8093", block_122880, 1)
if s == before:
    print("    ERROR: no se encontro ADF7021_REG3_POCSAG para reemplazar.")
    sys.exit(1)
with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("    ADF7021.h: REG3 POCSAG 512 baud aplicado (fallback Python)")
PY
fi

echo "[4/4] Verificando patches aplicados..."
python3 "$HERE/tools/verify_patches.py" "$TARGET" || {
  echo "ERROR: verificacion de patches fallo. Revisa el output arriba."
  exit 1
}

echo
echo "=== Patches aplicados correctamente ==="
echo "  - Config.h:  NANO_HOTSPOT, DUPLEX, STM32_USART1_HOST, TCXO 14.7456 MHz (match oficial)"
echo "  - IO.h:      VHF1_MAX = 150 MHz (soporta 149.255 MHz)"
echo "  - ADF7021.h: REG3 POCSAG = 512 baud (CLK output del ADF7021)"
echo
echo "Compila con:"
echo "    cd $HERE && ./build_firmware.sh"
echo "    (genera firmware_pocsag512_149mhz.bin listo para flash.sh)"