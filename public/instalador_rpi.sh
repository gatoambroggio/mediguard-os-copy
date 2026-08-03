#!/usr/bin/env bash
# ============================================================================
# instalador_rpi.sh  -  Sistema POCSAG para Raspberry Pi (Pi 3/4/5, Pi OS 64-bit)
# ============================================================================
# Wrapper que detecta el gpiochip del Pi y ejecuta el instalador principal.
# El instalador principal es el mismo de Ubuntu (funciona en Debian/Pi OS).
#
# Uso:
#   curl -fsSL <url>/instalador_rpi.sh | sudo bash
#   (o despues de bajarlo)  sudo bash instalador_rpi.sh
#
# Cambiar pin GPIO de PTT (por defecto 17 / BCM 17):
#   sudo POCSAG_GPIO_PIN=18 bash instalador_rpi.sh
# En Pi 5 puede hacer falta:
#   sudo POCSAG_GPIO_CHIP=gpiochip4 bash instalador_rpi.sh
# ============================================================================
set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Ejecuta como root o con sudo."; exit 1; }

# Deteccion del gpiochip (Pi 3/4 = gpiochip0, Pi 5 = gpiochip4)
CHIP="${POCSAG_GPIO_CHIP:-gpiochip0}"
if [[ -z "${POCSAG_GPIO_CHIP:-}" ]]; then
  if command -v gpioinfo >/dev/null 2>&1; then
    DET="$(gpioinfo 2>/dev/null | awk 'NR==2{print $1; exit}')"
    [[ -n "$DET" ]] && CHIP="$DET"
  fi
fi
PIN="${POCSAG_GPIO_PIN:-17}"

echo "==> Raspberry Pi detectada. GPIO PTT: chip=${CHIP} pin=${PIN}"
echo "==> (Para cambiar: POCSAG_GPIO_CHIP=... POCSAG_GPIO_PIN=... bash instalador_rpi.sh)"

echo "==> Descargando instalador POCSAG..."
TMP="$(mktemp -d)"
if ! curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/instalador.sh -o "$TMP/instalador.sh"; then
  echo "[ERR] No se pudo descargar instalador.sh. Verifica conexion a internet." >&2
  exit 1
fi

export POCSAG_GPIO_CHIP="$CHIP"
export POCSAG_GPIO_PIN="$PIN"

echo "==> Ejecutando instalador (podes pasar --update o --reset)..."
bash "$TMP/instalador.sh" "$@"

echo ""
echo "[OK] Sistema POCSAG instalado en la Raspberry Pi."
echo "     Panel publico: http://localhost:8080/"
echo "     Panel admin  : http://localhost:8080/admin"
echo "     GPIO PTT      : chip=${CHIP} pin=${PIN}"
echo "     (Si el PTT no conmuta, ajusta POCSAG_GPIO_CHIP en scripts/ptt_*.sh)"