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
# || true: si un repo de fabrica viene sin firmar (NO_PUBKEY en raspbian), no
# aborta todo el script bajo set -e. Los apt-get install posteriores usan los
# repos firmados (deb.debian.org), que igual quedaron actualizados.
apt-get update -y || true

echo "==> Raspberry Pi: reparando dependencias rotas (si las hay)..."
# Un run viejo pudo instalar las variantes -gnome de NetworkManager
# (network-manager-*-gnome -> libnma0 -> libgtk-3-0t64). En un Pi OS con
# bookworm+rpi mezclado con trixie, libgtk-3-0t64 choca por archivos con
# libgtk-3-0 (rpi) y dpkg no lo instala -> apt queda roto y aborta TODO
# ("Unmet dependencies"). apt-get -f install no lo resuelve (intenta instalar
# libgtk-3-0t64 y pega de frente con el conflicto). La salida es SACAR a la
# fuerza los -gnome + libnma0 (applets de escritorio, inutiles en headless);
# la VPN cliente sigue andando con network-manager-openvpn/pptp (sin -gnome).
# Despues apt-get -f install limpia el resto del estado.
dpkg --remove --force-all \
  network-manager-openvpn-gnome network-manager-pptp-gnome \
  network-manager-l2tp-gnome libnma0 2>/dev/null || true
apt-get -f install -y 2>&1 || warn "apt-get -f install no pudo resolver todo (continuando)."

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
  # Borrar los .list temporales al salir (exito o fallo). Sin esto, si el build
  # aborta o apt falla, los sources [trusted=yes] quedan en el rootfs y el
  # siguiente apt-get del build revienta con
  # "Conflicting values set for option Trusted ... trixie" (trusted si vs no).
  # local ZT_LISTS se limpia en el return de esta funcion.
  local ZT_LISTS="/etc/apt/sources.list.d/debian-zetronpoc.list /etc/apt/sources.list.d/raspios-zetronpoc.list"
  zt_clean_lists(){ rm -f $ZT_LISTS 2>/dev/null || true; }
  if command -v asterisk >/dev/null 2>&1 || [[ -x /usr/sbin/asterisk ]]; then
    # Si ya hay Asterisk pero le falta chan_pjsip.so (compilacion vieja sin
    # --with-pjproject-bundled), forzamos recompilar para que ZetronPOC pueda
    # registrar los internos via PJSIP.
    if [[ -f /usr/lib/asterisk/modules/chan_pjsip.so ]]; then
      log "asterisk ya instalado con PJSIP."; zt_clean_lists; return 0
    fi
    warn "asterisk existe pero sin chan_pjsip.so -> recompilando con pjproject bundled..."
  fi
  # Trixie: el keyring viejo no firma el repo nuevo -> apt falla con "Missing key
  # A0DA38D0D76E8B5D638872819165938D90FDDD2E". Refrescar keyrings ANTES de cualquier
  # intento de apt-get install asterisk, asi el repo por defecto de Pi OS ya lo trae.
  apt-get install -y raspbian-archive-keyring debian-archive-keyring >/dev/null 2>&1 || true
  apt-get update -y >/dev/null 2>&1 || true
  if apt-get install -y asterisk >/dev/null 2>&1; then
    log "asterisk instalado via apt."; zt_clean_lists; return 0
  fi
  # Plan A: repo Debian main (tiene asterisk precompilado para arm64 y NO
  # necesita la key de Rasprian, que es la que falla con NO_PUBKEY ...90FDDD2E).
  # [trusted=yes] salta la verificacion de firma -> apt-get update no aborta.
  warn "asterisk no esta en el repo activo. Probando repo Debian main (trusted=yes)..."
  . /etc/os-release 2>/dev/null || true
  local CODENAME="${VERSION_CODENAME:-bookworm}"
  echo "deb [trusted=yes] http://deb.debian.org/debian ${CODENAME} main contrib" > /etc/apt/sources.list.d/debian-zetronpoc.list
  apt-get update -y >/dev/null 2>&1 || true
  if apt-cache show asterisk >/dev/null 2>&1 && apt-get install -y asterisk >/dev/null 2>&1; then
    log "asterisk instalado via apt (Debian main)."; zt_clean_lists; return 0
  fi
  # Plan B: Raspbian main con trusted=yes (salta la firma que rompe en Trixie).
  echo "deb [trusted=yes] http://raspbian.raspberrypi.org/raspbian/ ${CODENAME} main" > /etc/apt/sources.list.d/raspios-zetronpoc.list
  apt-get update -y >/dev/null 2>&1 || true
  if apt-cache show asterisk >/dev/null 2>&1 && apt-get install -y asterisk >/dev/null 2>&1; then
    log "asterisk instalado via apt (Raspbian main)."; zt_clean_lists; return 0
  fi
  warn "apt no pudo instalar asterisk."
  zt_clean_lists
  # SKIP_ASTERISK_COMPILE=1: NO compilar Asterisk desde fuente aca. Lo usa el
  # build de la imagen (pi-gen bajo qemu) donde compilar tarda 3-4 h. En su lugar
  # la compilacion nativa (~30 min) se difiere al primer arranque de la Pi
  # (02-mediguard-firstboot.sh -> instalar_asterisk.sh). Fuera del build (Pi
  # real) SKIP_ASTERISK_COMPILE no esta seteado y compila aca normalmente.
  if [[ "${SKIP_ASTERISK_COMPILE:-0}" == "1" ]]; then
    warn "SKIP_ASTERISK_COMPILE=1: Asterisk se compilara en el primer arranque de la Pi (nativo, ~30 min, no bajo qemu)."
    return 0
  fi
  warn "Compilando Asterisk 22 LTS desde fuente (instalador robusto)..."
  # Delega en instalar_asterisk.sh: instala TODAS las deps de build, compila con
  # pjproject-bundled (garantiza chan_pjsip), fallback -j1 si -jN OOM/racea, y
  # verifica chan_pjsip.so. Mas robusto que embeberlo aca.
  local IA="$(mktemp -d)/instalar_asterisk.sh"
  if ! curl -fsSL "${SRC}/instalar_asterisk.sh" -o "$IA"; then
    err "No se pudo descargar instalar_asterisk.sh (sin red?)."; return 1
  fi
  if bash "$IA"; then
    log "Asterisk compilado e instalado desde fuente."; return 0
  fi
  return 1
}
ensure_asterisk || warn "No se pudo instalar asterisk por ningun metodo. El IVR/SIP no funcionara hasta resolverlo."
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

# ============================ MMDVM + UART (auto, sin tocar a mano) =========
echo "==> Liberando UART + instalando MMDVMHost..."
if [[ -f /boot/cmdline.txt ]]; then
  sed -i -E 's/ ?console=(serial0|ttyAMA0|ttyS0),[0-9]+//g' /boot/cmdline.txt
fi
if [[ -f /boot/config.txt ]]; then
  grep -q '^enable_uart=1'  /boot/config.txt || echo 'enable_uart=1'  >> /boot/config.txt
  grep -q '^dtoverlay=disable-bt' /boot/config.txt || echo 'dtoverlay=disable-bt' >> /boot/config.txt
fi
systemctl disable serial-getty@ttyAMA0.service serial-getty@ttyS0.service 2>/dev/null || true
systemctl disable bthelper@hciuart.service hciuart.service 2>/dev/null || true
if [[ "${SKIP_MMDVM_INSTALL:-0}" == "1" ]]; then
  warn "SKIP_MMDVM_INSTALL=1: MMDVMHost se instala en el primer arranque de la Pi (nativo, ~5-10 min, no bajo qemu)."
elif ! command -v MMDVM-Host >/dev/null 2>&1 && [[ ! -x /usr/local/bin/MMDVM-Host ]]; then
  MMDVM_TMP="$(mktemp -d)/instalador_mmdvm.sh"
  if curl -fsSL "${SRC}/instalador_mmdvm.sh" -o "$MMDVM_TMP"; then
    bash "$MMDVM_TMP" || warn "instalador_mmdvm.sh fallo (ver journalctl -u mmdvmhost)"
    rm -f "$MMDVM_TMP"
  else
    warn "No se pudo descargar instalador_mmdvm.sh (sin red?). MMDVM no instalado."
  fi
else
  log "MMDVMHost ya instalado."
  systemctl enable --now mmdvmhost 2>/dev/null || true
fi

# ============================ VERIFICAR Y LEVANTAR CADENA TX ==================
# Sin esta cadena arriba, el panel y el IVR encolan pero el pager nunca suena:
#   panel/IVR -> cola_envios -> worker -> dispatch_mqtt -> mosquitto -> MMDVMHost -> RF
# Si falta cualquier eslabon (mosquitto, MMDVMHost, worker, API), nada llega al aire.
# Forzamos los 4 servicios activos y regeneramos el .ini desde la BD del panel.
echo "==> Verificando cadena de transmision (mosquitto + MMDVMHost + cola + API)..."
systemctl enable --now mosquitto 2>/dev/null || true
python3 - <<'PYEOF' 2>/dev/null || warn "No se pudo regenerar MMDVM.ini desde la BD"
import sys, os
sys.path.insert(0, "/opt/zetronpoc"); sys.path.insert(0, "/opt/zetronpoc/database")
os.environ["ZETRONPOC_DIR"] = "/opt/zetronpoc"
try:
    from db_manager import generar_mmdvm_ini
    ok, msg = generar_mmdvm_ini()
    print("[OK] MMDVM.ini" if ok else "[WARN] %s" % msg)
except Exception as e:
    print("[WARN] %s" % e)
PYEOF
if command -v MMDVM-Host >/dev/null 2>&1 || [[ -x /usr/local/bin/MMDVM-Host ]]; then
  systemctl enable mmdvmhost 2>/dev/null || true
  systemctl restart mmdvmhost 2>/dev/null || true
else
  warn "MMDVMHost NO instalado -> los pages no salen al aire. Conecte el modulo y vuelva a ejecutar este instalador."
fi
systemctl enable --now zetronpoc-cola zetronpoc-api 2>/dev/null || true
systemctl restart zetronpoc-cola zetronpoc-api 2>/dev/null || true
sleep 2
echo "  Estado de la cadena:"
for s in mosquitto mmdvmhost zetronpoc-cola zetronpoc-api; do
  st="$(systemctl is-active "$s" 2>/dev/null || echo no)"
  printf "    %-16s %s\n" "$s" "$st"
done

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo ""
log "ZetronPOC instalado en Raspberry Pi (${GPIO_CHIP} BCM ${GPIO_PIN})."
echo "  Panel publico: http://${IP:-localhost}:8080/"
echo "  Panel admin  : http://${IP:-localhost}:8080/admin  (admin / admin123)"
echo ""
echo "  Para que un codigo llegue al pager los 4 servicios deben decir 'active'."
echo "  Si mmdvmhost dice 'activating' o 'inactive': el modulo MMDVM no esta conectado"
echo "  (conectelo por USB-TTL y espere; el wrapper lo levanta solo al detectarlo)."