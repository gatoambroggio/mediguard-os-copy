#!/usr/bin/env bash
# flash_official.sh — Descarga y flashea el firmware OFICIAL de MMDVM_HS
# (generic_gpio_fw.bin, SIMPLEX standalone) para diagnosticar si la placa
# nueva responde correctamente.
#
# Este firmware NO tiene nuestros patches (POCSAG 512 / 149 MHz). Sirve solo
# para DESCARTAR falla física: si la placa responde con un string de versión
# completo, el hardware está bien y el problema está en nuestro firmware custom.
#
# Uso:  sudo ./flash_official.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/generic_gpio_fw_v1.5.2.bin"
URL="https://github.com/juribeparada/MMDVM_HS/releases/download/v1.5.2/generic_gpio_fw.bin"
FLASH_SH="$HERE/flash.sh"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: correr con sudo:  sudo ./flash_official.sh"; exit 1; }

echo "=== Flash firmware OFICIAL MMDVM_HS v1.5.2 (generic_gpio, SIMPLEX) ==="
echo "  Este firmware NO tiene los patches de POCSAG 512 / 149 MHz."
echo "  Sirve solo para descartar falla física de la placa."
echo ""

# --- Descargar ---
if [ ! -f "$BIN" ]; then
  echo "[1/3] Descargando firmware oficial..."
  for i in 1 2 3; do
    if wget -q -O "$BIN" "$URL"; then
      break
    fi
    echo "  Reintento $i/3..."
    sleep 2
  done
  [ -f "$BIN" ] || { echo "ERROR: no se pudo descargar $URL"; exit 1; }
else
  echo "[1/3] Firmware oficial ya descargado: $BIN"
fi
echo "      Tamaño: $(stat -c%s "$BIN") bytes"
echo ""

# --- Flashear ---
echo "[2/3] Flasheando firmware oficial..."
"$FLASH_SH" "$BIN"
FLASH_RC=$?

if [ $FLASH_RC -ne 0 ]; then
  echo ""
  echo "ERROR: flash falló."
  echo "  Si NACK al ~67% (write protection):"
  echo "    sudo stm32flash -k /dev/ttyAMA0 && sleep 1 && sudo ./flash_official.sh"
  exit $FLASH_RC
fi

# --- Verificar ---
echo ""
echo "[3/3] Verificando respuesta del módulo..."
sleep 2
DETECT="/opt/zetronpoc/scripts/mmdvm_detect_port.py"
if [ -x "$DETECT" ]; then
  RESULT="$(python3 "$DETECT" /dev/ttyAMA0 115200 --version 2>/dev/null || true)"
  echo "  Detección: $RESULT"
  if echo "$RESULT" | grep -q "MMDVM\|Nano_hotSPOT\|ZUMspot"; then
    echo ""
    echo "=== ✅ LA PLACA RESPONDE CORRECTAMENTE ==="
    echo "  El hardware está bien. El problema está en tu firmware custom."
    echo "  El string de versión confirma que el STM32 arranca sin crashear."
    echo ""
    echo "  Próximo paso: recompilar el firmware custom en modo SIMPLEX (sin DUPLEX)"
    echo "  y flashearlo con:  sudo ./flash.sh firmware_pocsag512_149mhz.bin"
  else
    echo ""
    echo "=== ⚠️ EL MÓDULO RESPONDE PERO SIN VERSIÓN VÁLIDA ==="
    echo "  El STM32 sigue crasheando incluso con firmware oficial."
    echo "  Posibles causas:"
    echo "    1. BOOT1 (PB2, pin 20) no está a GND en esta placa china"
    echo "       → requiere solder bridge de PB2 a GND (ver issue #159)"
    echo "    2. Write protection (RDP Level 1) activada de fábrica"
    echo "       → sudo stm32flash -u /dev/ttyAMA0  (borra todo) y re-flashear"
    echo "    3. Falla física de la placa nueva"
  fi
else
  echo "  (script de detección no encontrado en $DETECT)"
  echo "  Verificar manualmente:"
  echo "    sudo systemctl restart mmdvmhost"
  echo "    sudo tail -20 /var/log/mmdvm/mmdvmhost.out.log"
fi