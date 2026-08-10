#!/usr/bin/env bash
# build_firmware.sh - Compila el firmware MMDVM_HS con POCSAG a 512 baud
# (variante TCXO 14.7456 MHz, Jumbospot/ZumSpot) y deja el .bin listo para
# flashear con flash.sh.
#
# El baud de TX en MMDVM_HS lo fija el registro R3 del ADF7021
# (ADF7021_REG3_POCSAG), NO un symbol-length en POCSAGTX.cpp. El flag
# -DPOCSAG_512 activa el R3 de 512 (0x2A4F8513) que ya esta en el fork.
#
# Uso:
#   ./build_firmware.sh            # compila pocsag512-144
#   ./build_firmware.sh <env>      # compila otro env de platformio.ini
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENV="${1:-pocsag512-144}"
CLONE="${HERE}/MMDVM_HS"
OUT_BIN="${HERE}/firmware_pocsag512_${ENV}.bin"

# ----------------------------------------------------------------------------
echo "[1/4] Verificando PlatformIO..."
if ! command -v pio >/dev/null 2>&1; then
  echo "    PlatformIO no encontrado. Instalando con pip3..."
  if ! command -v pip3 >/dev/null 2>&1; then
    echo "ERROR: pip3 no instalado.  sudo apt install python3-pip"
    exit 2
  fi
  pip3 install --user platformio
  export PATH="$HOME/.local/bin:$PATH"
  if ! command -v pio >/dev/null 2>&1; then
    echo "ERROR: pio sigue sin estar en PATH. Agregá ~/.local/bin al PATH y reejecutá."
    exit 3
  fi
fi
echo "    pio: $(pio --version)"

# ----------------------------------------------------------------------------
echo "[2/4] Clonando MMDVM_HS + aplicando patch R3 (512 baud)..."
bash "${HERE}/clone_and_patch.sh" "$CLONE"

# ----------------------------------------------------------------------------
echo "[3/4] Compilando env '${ENV}' (con -DPOCSAG_512)..."
cd "$CLONE"

# Copiar nuestro platformio.ini de ejemplo si el upstream no tiene el env.
if ! pio project config --json-output 2>/dev/null | grep -q "\"${ENV}\""; then
  echo "    El env '${ENV}' no existe en el platformio.ini upstream."
  echo "    Fusionando nuestro platformio.ini de ejemplo..."
  # Nuestro platformio.ini define el env pocsag512-144; lo dejamos como base.
  cp -f "${HERE}/platformio.ini" "${CLONE}/platformio.ini"
fi

pio run -e "$ENV"

BIN_SRC="${CLONE}/.pio/build/${ENV}/firmware.bin"
if [ ! -f "$BIN_SRC" ]; then
  echo "ERROR: no se genero ${BIN_SRC}. Revisá el log de PlatformIO arriba."
  exit 4
fi

# ----------------------------------------------------------------------------
echo "[4/4] Copiando .bin -> ${OUT_BIN}"
cp -f "$BIN_SRC" "$OUT_BIN"
echo
echo "============================================================"
echo "  OK. Firmware 512 baud compilado:"
echo "    ${OUT_BIN}"
echo
echo "  Verificá el baud con verify_baud.sh despues de flashear."
echo "  Flasheá con:"
echo "    ./flash.sh ${OUT_BIN}"
echo "============================================================"