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

# ============================ ASEGURAR ASTERISK =============================
# 1) si ya esta instalado (paquete o binario), listo.
# 2) apt-get install asterisk.
# 3) si falla, asegurar el repo main de Raspbian + apt-get update + reintentar.
# 4) si tampoco, compilar Asterisk 20 LTS desde fuente (lento, pero garantizado).
ensure_asterisk() {
  if command -v asterisk >/dev/null 2>&1 || [[ -x /usr/sbin/asterisk ]]; then
    log "asterisk ya instalado."; return 0
  fi
  if apt-get install -y asterisk 2>&1 >/dev/null; then
    log "asterisk instalado via apt."; return 0
  fi
  warn "asterisk no esta en el repo activo. Intentando habilitar el repo main de Raspbian..."
  . /etc/os-release 2>/dev/null || true
  local CODENAME="${VERSION_CODENAME:-bookworm}"
  local SRCFILE="/etc/apt/sources.list.d/raspios-zetronpoc.list"
  if ! grep -rq "raspbian.raspberrypi.org" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    echo "deb http://raspbian.raspberrypi.org/raspbian/ ${CODENAME} main" > "$SRCFILE"
  fi
  apt-get update -y 2>&1 >/dev/null || true
  if apt-get install -y asterisk 2>&1 >/dev/null; then
    log "asterisk instalado via apt (tras habilitar Raspbian main)."; return 0
  fi
  warn "apt no pudo instalar asterisk. Compilando Asterisk 20 LTS desde fuente (puede tardar 30-60 min)..."
  apt-get install -y build-essential libsqlite3-dev libedit-dev libxml2-dev \
    uuid-dev libssl-dev wget tar pkg-config 2>&1 >/dev/null || true
  local AB="/tmp/asterisk-build"
  rm -rf "$AB"; mkdir -p "$AB"; cd "$AB"
  wget -q "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-20-current.tar.gz" -O ast.tar.gz \
    || { err "No se pudo descargar el tarball de Asterisk."; return 1; }
  tar xzf ast.tar.gz
  cd asterisk-20*/
  ./configure --with-jansson-bundled 2>&1 | tail -3
  if ! make -j"$(nproc)" 2>&1 | tail -3; then
    err "La compilacion de Asterisk fallo."; return 1
  fi
  make install 2>&1 | tail -3
  make config 2>&1 >/dev/null || true
  ldconfig
  # systemd unit si make config no creo uno usable
  if ! systemctl list-unit-files 2>/dev/null | grep -q "^asterisk.service"; then
    cat > /etc/systemd/system/asterisk.service <<'UNIT'
[Unit]
Description=Asterisk PBX
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/sbin/asterisk -f
ExecStop=/usr/sbin/asterisk -rx "core stop now"
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload 2>/dev/null || true
  fi
  log "Asterisk compilado e instalado desde fuente."; return 0
}
ensure_asterisk || warn "No se pudo instalar asterisk por ningun metodo (apt, repo, ni fuente). El IVR/SIP no funcionara."
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