#!/usr/bin/env bash
# ============================================================================
# instalar_firmware_mmdvm.sh — Flashea el firmware custom MMDVM_HS en el STM32
# del hotspot (POCSAG 512 baud + 149.255 MHz), en una sola corrida.
# ============================================================================
# Por qué: el firmware stock de fábrica pagina a 1200 baud y su rango VHF llega
# a 148 MHz, así que en 149.255 MHz no genera RF. Este script baja el binario
# standalone del release, lo verifica, lo flashea por serial (BOOT0/NRST por
# GPIO), deja la placa como HOTSPOT en la BD y reinicia MMDVMHost.
#
# Uso:  sudo ./instalar_firmware_mmdvm.sh [puerto]
# ============================================================================
set -uo pipefail

APP_DIR="${ZETRONPOC_DIR:-/opt/zetronpoc}"
DB="${APP_DIR}/database/zetronpoc.db"
DETECTOR="${APP_DIR}/scripts/mmdvm_detect_port.py"
BIN_URL="https://github.com/gatoambroggio/mediguard-os-copy/releases/download/pocsag512-149mhz-latest/firmware_pocsag512_149mhz.bin"
FLASH_URL="https://raw.githubusercontent.com/gatoambroggio/mediguard-os-copy/main/src/zetronpoc/firmware/mmdvm_hs_512/flash.sh"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
ok(){   echo -e "  ${G}✓${N} $1"; }
fail(){ echo -e "  ${R}✗${N} $1"; }
warn(){ echo -e "  ${Y}!${N} $1"; }

[ "$(id -u)" -eq 0 ] || { fail "Correr con sudo:  sudo ./instalar_firmware_mmdvm.sh"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BIN="${WORK}/firmware_pocsag512_149mhz.bin"
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

echo -e "${B}${C}╔══════════════════════════════════════════════════╗${N}"
echo -e "${B}${C}║  Firmware MMDVM_HS · POCSAG 512 baud / 149.255   ║${N}"
echo -e "${B}${C}╚══════════════════════════════════════════════════╝${N}"

# ---------------------------------------------------------------------------
echo -e "\n${B}==> 1/7 Dependencias (stm32flash, gpiod)...${N}"
if ! command -v stm32flash >/dev/null 2>&1 || ! command -v gpioset >/dev/null 2>&1; then
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y stm32flash gpiod 2>&1 | tail -3
fi
command -v stm32flash >/dev/null 2>&1 || { fail "stm32flash no se pudo instalar"; exit 1; }
command -v gpioset >/dev/null 2>&1 || { fail "gpiod (gpioset) no se pudo instalar"; exit 1; }
ok "stm32flash y gpioset disponibles"

# ---------------------------------------------------------------------------
echo -e "\n${B}==> 2/7 Detectando el puerto del módulo...${N}"
PORT="${1:-}"
if [ -z "$PORT" ] && [ -x "$DETECTOR" ]; then
  PORT="$(python3 "$DETECTOR" 2>/dev/null || true)"
fi
PORT="${PORT:-/dev/ttyAMA0}"
[ -e "$PORT" ] || { fail "no existe ${PORT} (¿módulo conectado?)"; exit 1; }
ok "puerto: ${PORT}"

# ---------------------------------------------------------------------------
echo -e "\n${B}==> 3/7 Firmware actual en la placa...${N}"
CUR=""
if [ -x "$DETECTOR" ]; then
  CUR="$(python3 "$DETECTOR" "$PORT" 115200 --version 2>/dev/null | cut -f2 || true)"
fi
if [ -n "$CUR" ]; then
  echo "  ${CUR}"
  case "$CUR" in
    *512*) ok "ya parece el firmware custom" ;;
    *)     warn "es firmware stock (1200 baud / VHF hasta 148 MHz) — hay que flashear" ;;
  esac
else
  warn "el módulo no respondió al handshake (igual se intenta flashear)"
fi

# ---------------------------------------------------------------------------
echo -e "\n${B}==> 4/7 Descargando firmware y flasheador...${N}"
dl "$BIN_URL" "$BIN" || { fail "no se pudo descargar el firmware"; exit 1; }
dl "$FLASH_URL" "$FLASH" || { fail "no se pudo descargar flash.sh"; exit 1; }
chmod +x "$FLASH"
ok "firmware descargado ($(stat -c%s "$BIN") bytes)"

python3 - "$BIN" <<'PY'
import sys, struct
b = open(sys.argv[1], "rb").read()
if len(b) < 8192:
    print("  \033[0;31m✗\033[0m el binario es demasiado chico"); sys.exit(1)
sp, rv = struct.unpack("<II", b[:8])
if not (0x20000000 <= sp <= 0x20020000):
    print("  \033[0;31m✗\033[0m stack pointer inválido (%#x)" % sp); sys.exit(1)
if not (0x08000000 <= rv < 0x08040000):
    print("  \033[0;31m✗\033[0m vector de reset fuera de flash (%#x)" % rv); sys.exit(1)
if b"14.7456" not in b:
    print("  \033[1;33m!\033[0m no se encontró el TCXO 14.7456 en el binario")
print("  \033[0;32m✓\033[0m binario válido: stack=%#x reset=%#x" % (sp, rv))
PY
[ $? -eq 0 ] || { fail "el binario no pasó la verificación"; exit 1; }

# ---------------------------------------------------------------------------
echo -e "\n${B}==> 5/7 Flasheando (se detiene MMDVMHost)...${N}"
systemctl stop mmdvmhost 2>/dev/null || true
sleep 1
if ! "$FLASH" "$BIN" "$PORT"; then
  fail "el flasheo falló"
  echo "  Si fue NACK al ~67% (write protection de fábrica):"
  echo "    sudo stm32flash -k ${PORT}"
  echo "    sudo ./instalar_firmware_mmdvm.sh ${PORT}"
  systemctl start mmdvmhost 2>/dev/null || true
  exit 1
fi
ok "flash completado"

# ---------------------------------------------------------------------------
echo -e "\n${B}==> 6/7 Configurando la placa como HOTSPOT...${N}"
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

# ---------------------------------------------------------------------------
echo -e "\n${B}==> 7/7 Reiniciando y verificando...${N}"
systemctl start mmdvmhost 2>/dev/null || true
sleep 4
if systemctl is-active --quiet mmdvmhost; then
  ok "MMDVMHost activo"
else
  warn "MMDVMHost no quedó activo — ver: journalctl -u mmdvmhost -n 40"
fi

sleep 2
NEW=""
if [ -x "$DETECTOR" ]; then
  NEW="$(python3 "$DETECTOR" "$PORT" 115200 --version 2>/dev/null | cut -f2 || true)"
fi
echo ""
if [ -n "$NEW" ]; then
  ok "firmware en la placa ahora: ${NEW}"
  case "$NEW" in
    *512*) ok "quedó el firmware custom de 512 baud" ;;
    *)     warn "el string no menciona 512 — revisar el build" ;;
  esac
else
  warn "el módulo no respondió tras el flash (posible crash loop)"
  echo "    Si la LED roja titila rápido, esta placa puede necesitar otra"
  echo "    definición de board (NANO_HOTSPOT en vez de LIBRE_KIT_ADF7021)."
  echo "    El módulo se puede recuperar reflasheando el firmware stock."
fi

echo ""
echo "  Probar la portación en vivo (y mandar un page de prueba):"
echo "    sudo journalctl -u mmdvmhost -f"
echo "  Diagnóstico completo:"
echo "    sudo ${APP_DIR}/scripts/diagnostico_placa.sh"
echo ""