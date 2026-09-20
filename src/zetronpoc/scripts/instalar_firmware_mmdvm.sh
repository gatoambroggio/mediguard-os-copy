#!/usr/bin/env bash
# ============================================================================
# instalar_firmware_mmdvm.sh — Flashea el firmware custom MMDVM_HS (POCSAG
# 512 baud + 149.255 MHz) en el STM32 del hotspot, probando las dos variantes
# de board por las que varian los clones chinos del Nano hotSPOT.
# ============================================================================
# Por qué dos variantes: el mismo modelo de placa (clon del Nano hotSPOT) sale
# en lotes con pin mapping distinto. La definicion de board que arranca en una
# unidad puede crashear (LED rojo en loop, version vacia) en otra. Este script
# flashea LIBRE_KIT_ADF7021, verifica que el STM32 devuelva su string de version
# y, si no lo hace, flashea NANO_HOTSPOT. Se queda con la que arranca.
#
# Si ninguna variante arranca, flashea el firmware OFICIAL para separar placa
# rota de firmware incompatible, y te dice cual de las dos es.
#
# Uso:  sudo ./instalar_firmware_mmdvm.sh [puerto]
# ============================================================================
set -uo pipefail

APP_DIR="${ZETRONPOC_DIR:-/opt/zetronpoc}"
DB="${APP_DIR}/database/zetronpoc.db"
DETECTOR="${APP_DIR}/scripts/mmdvm_detect_port.py"
REL="https://github.com/gatoambroggio/mediguard-os-copy/releases/download/pocsag512-149mhz-latest"
FLASH_URL="https://raw.githubusercontent.com/gatoambroggio/mediguard-os-copy/main/src/zetronpoc/firmware/mmdvm_hs_512/flash.sh"
OFFICIAL_URL="https://github.com/juribeparada/MMDVM_HS/releases/download/v1.5.2/generic_gpio_fw.bin"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
ok(){   echo -e "  ${G}✓${N} $1"; }
fail(){ echo -e "  ${R}✗${N} $1"; }
warn(){ echo -e "  ${Y}!${N} $1"; }

[ "$(id -u)" -eq 0 ] || { fail "Correr con sudo:  sudo ./instalar_firmware_mmdvm.sh"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FLASH="${WORK}/flash.sh"

dl(){ # dl <url> <dest> — reintenta contra 503/red transitoria
  local i=0
  while :; do
    curl -fsSL --retry 3 --retry-delay 2 "$1" -o "$2" 2>/dev/null && return 0
    i=$((i+1)); [ "$i" -ge 5 ] && return 1
    warn "descarga falló (intento $i/5), reintentando en 3s"
    sleep 3
  done
}

echo -e "${B}${C}╔══════════════════════════════════════════════════════╗${N}"
echo -e "${B}${C}║  Firmware MMDVM_HS · POCSAG 512 baud / 149.255 MHz    ║${N}"
echo -e "${B}${C}╚══════════════════════════════════════════════════════╝${N}"

# ---------------------------------------------------------------------------
echo -e "\n${B}==> 1/6 Dependencias (stm32flash, gpiod)...${N}"
if ! command -v stm32flash >/dev/null 2>&1 || ! command -v gpioset >/dev/null 2>&1; then
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y stm32flash gpiod 2>&1 | tail -3
fi
command -v stm32flash >/dev/null 2>&1 || { fail "stm32flash no se pudo instalar"; exit 1; }
command -v gpioset >/dev/null 2>&1 || { fail "gpiod (gpioset) no se pudo instalar"; exit 1; }
ok "stm32flash y gpioset disponibles"

# ---------------------------------------------------------------------------
echo -e "\n${B}==> 2/6 Detectando el puerto del módulo...${N}"
systemctl stop mmdvmhost 2>/dev/null || true
sleep 1
PORT="${1:-}"
if [ -z "$PORT" ] && [ -x "$DETECTOR" ]; then
  PORT="$(python3 "$DETECTOR" 2>/dev/null || true)"
fi
PORT="${PORT:-/dev/ttyAMA0}"
[ -e "$PORT" ] || { fail "no existe ${PORT} (¿módulo conectado?)"; systemctl start mmdvmhost 2>/dev/null || true; exit 1; }
ok "puerto: ${PORT} (MMDVMHost detenido para liberarlo)"

# ---------------------------------------------------------------------------
echo -e "\n${B}==> 3/6 Descargando flasheador y firmwares...${N}"
dl "$FLASH_URL" "$FLASH" || { fail "no se pudo descargar flash.sh"; systemctl start mmdvmhost 2>/dev/null || true; exit 1; }
chmod +x "$FLASH"

BIN_LIBRE="${WORK}/firmware_pocsag512_149mhz.bin"
BIN_NANO="${WORK}/firmware_pocsag512_149mhz_nano.bin"
BIN_OFFICIAL="${WORK}/generic_gpio_fw.bin"

dl "${REL}/firmware_pocsag512_149mhz.bin"      "$BIN_LIBRE"    || { fail "no se pudo descargar el firmware (LIBRE_KIT)"; systemctl start mmdvmhost 2>/dev/null || true; exit 1; }
dl "${REL}/firmware_pocsag512_149mhz_nano.bin" "$BIN_NANO"     || warn "no se pudo descargar la variante NANO_HOTSPOT (se prueba solo LIBRE_KIT)"
dl "$OFFICIAL_URL"                             "$BIN_OFFICIAL" || warn "no se pudo descargar el firmware oficial (no habrá test de hardware)"

# ---------------------------------------------------------------------------
# valida un binario STM32 antes de flashearlo
verificar_bin(){
  python3 - "$1" <<'PY'
import sys, struct
b = open(sys.argv[1], "rb").read()
if len(b) < 8192:
    print("  \033[0;31m✗\033[0m el binario es demasiado chico"); sys.exit(1)
sp, rv = struct.unpack("<II", b[:8])
if not (0x20000000 <= sp <= 0x20020000):
    print("  \033[0;31m✗\033[0m stack pointer inválido (%#x)" % sp); sys.exit(1)
if not (0x08000000 <= rv < 0x08040000):
    print("  \033[0;31m✗\033[0m vector de reset fuera de flash (%#x)" % rv); sys.exit(1)
print("  \033[0;32m✓\033[0m binario válido: stack=%#x reset=%#x" % (sp, rv))
PY
}

# lee el string de version que devuelve el STM32 (vacio = no arranco)
leer_version(){
  [ -x "$DETECTOR" ] || return 0
  local v=""
  for _ in 1 2 3; do
    v="$(python3 "$DETECTOR" "$1" 115200 --version 2>/dev/null | cut -f2 || true)"
    [ -n "$v" ] && { echo "$v"; return 0; }
    sleep 1
  done
  echo ""
}

# flashea y confirma que el firmware arranca (devuelve el string de version)
flash_y_verificar(){
  local bin="$1" nombre="$2"
  echo -e "\n  ${B}--- ${nombre} ---${N}"
  verificar_bin "$bin" || return 1
  if ! "$FLASH" "$bin" "$PORT"; then
    warn "el flasheo falló"
    echo "    Si fue NACK al ~67% (write protection de fábrica):"
    echo "      sudo stm32flash -k ${PORT}"
    echo "      sudo ./instalar_firmware_mmdvm.sh ${PORT}"
    return 1
  fi
  ok "flash completado, esperando arranque..."
  sleep 3
  local v; v="$(leer_version "$PORT")"
  if [ -n "$v" ] && printf '%s' "$v" | grep -qi 'MMDVM'; then
    ok "la placa arrancó: ${v}"
    return 0
  fi
  fail "la placa no devolvió versión (crash loop con esta variante)"
  return 1
}

# ---------------------------------------------------------------------------
echo -e "\n${B}==> 4/6 Probando variantes de board...${N}"
ELEGIDA=""
if flash_y_verificar "$BIN_LIBRE" "LIBRE_KIT_ADF7021"; then
  ELEGIDA="LIBRE_KIT_ADF7021"
elif [ -f "$BIN_NANO" ] && flash_y_verificar "$BIN_NANO" "NANO_HOTSPOT"; then
  ELEGIDA="NANO_HOTSPOT"
fi

# ---------------------------------------------------------------------------
echo -e "\n${B}==> 5/6 Resultado...${N}"
if [ -z "$ELEGIDA" ]; then
  warn "ninguna variante del firmware custom arrancó."
  echo -e "\n  ${B}Test de hardware con el firmware OFICIAL...${N}"
  if [ -f "$BIN_OFFICIAL" ] && flash_y_verificar "$BIN_OFFICIAL" "OFICIAL v1.5.2 (SIMPLEX)"; then
    fail "CONCLUSIÓN: la PLACA ESTÁ BIEN, el firmware custom no arranca en esta unidad."
    echo "    El hardware responde con firmware oficial pero crashea con el custom."
    echo "    Esta unidad necesita una definición de board distinta a las dos probadas."
    echo "    Pasame el string de versión que devolvió el oficial y lo ajusto."
  else
    fail "CONCLUSIÓN: la placa NO arranca ni con firmware oficial → problema de HARDWARE."
    echo "    Causas típicas en clones chinos (issue #159 de MMDVM_HS):"
    echo "      1. BOOT1 (PB2, pin 20) flotante → soldar PB2 a GND"
    echo "      2. Write protection / RDP de fábrica → sudo stm32flash -u ${PORT}"
    echo "         (borra todo) y volver a correr este script"
    echo "      3. Falla física de la placa"
  fi
  echo -e "\n  ${B}Dejando el firmware oficial puesto para no dejar la placa muda.${N}"
  echo "  Cuando esté resuelto:  sudo ./instalar_firmware_mmdvm.sh"
  systemctl start mmdvmhost 2>/dev/null || true
  exit 1
fi

ok "variante que arranca: ${ELEGIDA}"

# ---------------------------------------------------------------------------
echo -e "\n${B}==> 6/6 Configurando la placa como HOTSPOT...${N}"
python3 - "$DB" "$PORT" <<'PY'
import sqlite3, sys
db, port = sys.argv[1], sys.argv[2]
try:
    c = sqlite3.connect(db)
    for k, v in (("mmdvm_board_type", "hotspot"), ("mmdvm_serial_port", port)):
        c.execute("INSERT OR REPLACE INTO config(clave,valor) VALUES(?,?)", (k, v))
    c.commit(); c.close()
    print("  \033[0;32m✓\033[0m mmdvm_board_type=hotspot, mmdvm_serial_port=%s" % port)
except Exception as e:
    print("  \033[1;33m!\033[0m no se pudo actualizar la BD: %s" % e)
PY

python3 - "$APP_DIR" <<'PY'
import sys, os
app = sys.argv[1]
sys.path.insert(0, app); sys.path.insert(0, os.path.join(app, "database"))
os.environ["ZETRONPOC_DIR"] = app
try:
    from db_manager import generar_mmdvm_ini
    ok, msg = generar_mmdvm_ini()
    print("  %s %s" % ("\033[0;32m✓\033[0m" if ok else "\033[1;33m!\033[0m", msg))
except Exception as e:
    print("  \033[1;33m!\033[0m no se pudo regenerar MMDVM.ini: %s" % e)
PY

systemctl start mmdvmhost 2>/dev/null || true
sleep 4
if systemctl is-active --quiet mmdvmhost; then
  ok "MMDVMHost activo"
else
  warn "MMDVMHost no quedó activo — ver: journalctl -u mmdvmhost -n 40"
fi

echo ""
echo "  Probar la portación en vivo (y mandar un page de prueba):"
echo "    sudo journalctl -u mmdvmhost -f"
echo "  Diagnóstico completo:"
echo "    sudo ${APP_DIR}/scripts/diagnostico_placa.sh"
echo ""