#!/usr/bin/env bash
# ============================================================================
# instalador_rpi.sh - ZetronPOC para Raspberry Pi (Pi 3/4/5, Pi OS 64-bit)
# ============================================================================
# Bootstrap especifico para Raspberry Pi OS:
#   - apt-get update + dependencias en grupos (asterisk/libgpiod2 por separado
#     para no abortar todo si el mirror no los tiene).
#   - Detecta el gpiochip principal automaticamente (Pi 5 -> gpiochip4,
#     Pi 3/4 -> gpiochip0) y configura el PTT en BCM 17 por defecto.
#   - Luego ejecuta el instalador principal (instalador.sh) y deja el
#     gpio_chip/gpio_pin guardado en la base de datos.
#
# Instalacion (una linea):
#   curl -fsSL https://raw.githubusercontent.com/gatoambroggio/mediguard-os-copy/main/src/zetronpoc/instalador_rpi.sh | sudo bash
#
# Otro pin BCM (ej: 18):
#   curl -fsSL .../instalador_rpi.sh | sudo POCSAG_GPIO_PIN=18 bash
# ============================================================================
set -euo pipefail

REPO="https://raw.githubusercontent.com/gatoambroggio/mediguard-os-copy/main"
SRC="${REPO}/src/zetronpoc"

G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; NC="\033[0m"
log(){ echo -e "${G}[OK]${NC}   $*"; }
warn(){ echo -e "${Y}[WARN]${NC} $*"; }
err(){ echo -e "${R}[ERR]${NC}  $*" >&2; }

[[ $EUID -ne 0 ]] && { err "Ejecuta como root o con sudo."; exit 1; }

dl(){ # dl <url> <dest>
  if ! curl -fsSL "$1" -o "$2"; then err "No se pudo descargar $1"; exit 1; fi
}

echo "==> Raspberry Pi: actualizando lista de paquetes..."
apt-get update -y

echo "==> Raspberry Pi: instalando dependencias base..."
# Base: siempre disponibles en Pi OS 64-bit. Si alguno falla aca si abortamos.
apt-get install -y sqlite3 python3 python3-pip sox git curl ca-certificates \
  logrotate espeak gpiod 2>&1 || { err "Fallo la instalacion de paquetes base."; exit 1; }

# asterisk y libgpiod2 por separado: si el mirror del Pi no los tiene, no abortan.
apt-get install -y asterisk 2>&1 || warn "asterisk no esta en el repo activo. Habilite el repo main de Raspbian: deb http://raspbian.raspberrypi.org/raspbian/ bookworm main"
# libgpiod2: la numeracion del paquete varia entre releases (libgpiod2 / libgpiod3
# / libgpiod-dev). gpiod ya instalo gpioset para el PTT, asi que si ninguno de los
# candidatos existe, se ignora en silencio (no es un WARN accionable).
for _pkg in libgpiod2 libgpiod3 libgpiod-dev; do
  if apt-cache show "$_pkg" >/dev/null 2>&1; then
    apt-get install -y "$_pkg" 2>&1 >/dev/null || true
    break
  fi
done

# ============================ DETECTAR GPIOCHIP =============================
# El gpiochip principal es el que mas lineas expone. Pi 5 -> gpiochip4 (rp1),
# Pi 3/4 -> gpiochip0 (pinctrl-bcm2835).
GPIO_CHIP="gpiochip0"
BEST=0
for c in 0 1 2 3 4 5 6 7; do
  if [[ -e "/dev/gpiochip$c" ]]; then
    N=$(gpioinfo "gpiochip$c" 2>/dev/null | wc -l)
    N=${N:-0}
    if [[ $N -gt $BEST ]]; then BEST=$N; GPIO_CHIP="gpiochip$c"; fi
  fi
done
GPIO_PIN="${POCSAG_GPIO_PIN:-17}"
log "GPIO detectado: ${GPIO_CHIP} (BCM ${GPIO_PIN})"

# ============================ EJECUTAR INSTALADOR PRINCIPAL ==================
echo "==> Ejecutando instalador principal (instalador.sh)..."
TMP="$(mktemp -d)"
dl "${SRC}/instalador.sh" "${TMP}/instalador.sh"
bash "${TMP}/instalador.sh" "$@"

# ============================ GUARDAR GPIO EN LA BD ==========================
python3 - <<PYEOF
import sqlite3
DB='/opt/zetronpoc/database/zetronpoc.db'
try:
    c=sqlite3.connect(DB)
    c.execute("INSERT OR REPLACE INTO config(clave,valor) VALUES('gpio_chip','${GPIO_CHIP}')")
    c.execute("INSERT OR REPLACE INTO config(clave,valor) VALUES('gpio_pin','${GPIO_PIN}')")
    c.commit(); c.close()
    print("[OK] gpio_chip=${GPIO_CHIP} gpio_pin=${GPIO_PIN} guardados en la base")
except Exception as e:
    print("[WARN] no se pudo guardar gpio en la base: %s" % e)
PYEOF

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo ""
log "ZetronPOC instalado en Raspberry Pi (${GPIO_CHIP} BCM ${GPIO_PIN})."
echo "  Panel publico: http://${IP:-localhost}:8080/"
echo "  Panel admin  : http://${IP:-localhost}:8080/admin  (admin / admin123)"