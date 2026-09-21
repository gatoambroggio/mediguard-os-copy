#!/usr/bin/env bash
# ============================================================================
# instalar_firmware_mmdvm.sh — Flashea el firmware custom MMDVM_HS (POCSAG
# 512 baud + 149.255 MHz) en el STM32 del hotspot.
# ============================================================================
# AUTOCONTENIDO: el flasheo (secuencia BOOT0/NRST por GPIO + stm32flash) vive
# ACÁ ADENTRO. No descarga un flash.sh aparte: un solo archivo que actualizar,
# y así no se puede quedar con una copia vieja cacheada.
#
# gpiod v1 vs v2: la sintaxis de gpioset cambió.
#   v1:  gpioset gpiochip0 20=1
#   v2:  gpioset -c gpiochip0 20=1    <-- Debian 13 / Raspberry Pi OS nuevos
# Con v2, pasar el chip posicional da "invalid line value: 'gpiochip0'", el
# STM32 nunca entra al bootloader y stm32flash falla con "Failed to init
# device, timeout". Acá se detecta la versión y se arma la invocación correcta.
# El chip GPIO también se autodetecta (en RPi 5 el header es gpiochip4, no 0).
#
# Prueba dos variantes de board (los clones chinos del Nano hotSPOT salen en
# lotes con pin mapping distinto) y se queda con la que arranca. Si ninguna
# arranca, flashea el firmware OFICIAL para separar placa rota de firmware.
#
# Uso:  sudo ./instalar_firmware_mmdvm.sh [puerto]
# ============================================================================
set -uo pipefail

APP_DIR="${ZETRONPOC_DIR:-/opt/zetronpoc}"
DB="${APP_DIR}/database/zetronpoc.db"
DETECTOR="${APP_DIR}/scripts/mmdvm_detect_port.py"
REL="https://github.com/gatoambroggio/mediguard-os-copy/releases/download/pocsag512-149mhz-latest"
OFFICIAL_URL="https://github.com/juribeparada/MMDVM_HS/releases/download/v1.5.2/generic_gpio_fw.bin"

BOOT0_PIN="${BOOT0_PIN:-20}"
NRST_PIN="${NRST_PIN:-21}"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
ok(){   echo -e "  ${G}✓${N} $1"; }
fail(){ echo -e "  ${R}✗${N} $1"; }
warn(){ echo -e "  ${Y}!${N} $1"; }

[ "$(id -u)" -eq 0 ] || { fail "Correr con sudo:  sudo ./instalar_firmware_mmdvm.sh"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

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
echo -e "\n${B}==> 1/5 Dependencias (stm32flash, gpiod)...${N}"
if ! command -v stm32flash >/dev/null 2>&1 || ! command -v gpioset >/dev/null 2>&1; then
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y stm32flash gpiod 2>&1 | tail -3
fi
command -v stm32flash >/dev/null 2>&1 || { fail "stm32flash no se pudo instalar"; exit 1; }
command -v gpioset >/dev/null 2>&1 || { fail "gpiod (gpioset) no se pudo instalar"; exit 1; }
ok "stm32flash y gpioset disponibles"

# ---------------------------------------------------------------------------
# Chip GPIO: el header de 40 pines es el pinctrl de Broadcom (en RPi 5 es otro índice)
if [ -z "${GPIOCHIP:-}" ]; then
  GPIOCHIP="$(gpiodetect 2>/dev/null | awk '/pinctrl|bcm/ {print $1; exit}')"
  GPIOCHIP="${GPIOCHIP:-gpiochip0}"
fi
if [ ! -e "/dev/${GPIOCHIP}" ]; then
  fail "no existe /dev/${GPIOCHIP}"
  gpiodetect 2>/dev/null | sed 's/^/    /' || true
  exit 1
fi

# Sintaxis de gpioset según versión de gpiod
GPIOD_MAJ="$(gpioset --version 2>/dev/null | sed -n 's/.*[^0-9]v\([0-9]\{1,\}\).*/\1/p' | head -1)"
if [ -n "$GPIOD_MAJ" ] && [ "$GPIOD_MAJ" -ge 2 ]; then
  CHIP_ARGS=(-c "$GPIOCHIP")
elif [ -z "$GPIOD_MAJ" ] && gpioset --help 2>&1 | grep -q -- '--chip'; then
  CHIP_ARGS=(-c "$GPIOCHIP")
else
  CHIP_ARGS=("$GPIOCHIP")
fi

pkill -f gpioset 2>/dev/null || true
sleep 0.2

hold(){ # hold <pin> <valor> -> deja la línea fija y devuelve el PID
  gpioset "${CHIP_ARGS[@]}" "$1"="$2" &
  echo $!
}

# Pre-flight: ¿gpioset puede realmente manejar la línea? (falla rápido y claro)
gpioset "${CHIP_ARGS[@]}" "$BOOT0_PIN"=0 >/dev/null 2>&1 &
PROBE_PID=$!
sleep 0.3
if ! kill -0 "$PROBE_PID" 2>/dev/null; then
  wait "$PROBE_PID" 2>/dev/null; PROBE_RC=$?
  if [ "${PROBE_RC:-0}" -ne 0 ]; then
    fail "gpioset no pudo manejar GPIO ${BOOT0_PIN} en ${GPIOCHIP}"
    echo "    Probá a mano:  gpioset ${CHIP_ARGS[*]} ${BOOT0_PIN}=1"
    exit 1
  fi
else
  kill "$PROBE_PID" 2>/dev/null || true
fi
ok "GPIO ok: ${GPIOCHIP} (gpiod v${GPIOD_MAJ:-?}) · BOOT0=GPIO${BOOT0_PIN} · NRST=GPIO${NRST_PIN}"

# ---------------------------------------------------------------------------
echo -e "\n${B}==> 2/5 Detectando el puerto del módulo...${N}"
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
echo -e "\n${B}==> 3/5 Descargando firmwares...${N}"
BIN_LIBRE="${WORK}/firmware_pocsag512_149mhz.bin"
BIN_NANO="${WORK}/firmware_pocsag512_149mhz_nano.bin"
BIN_OFFICIAL="${WORK}/generic_gpio_fw.bin"

dl "${REL}/firmware_pocsag512_149mhz.bin"      "$BIN_LIBRE"    || { fail "no se pudo descargar el firmware (LIBRE_KIT)"; systemctl start mmdvmhost 2>/dev/null || true; exit 1; }
dl "${REL}/firmware_pocsag512_149mhz_nano.bin" "$BIN_NANO"     || warn "sin variante NANO_HOTSPOT en el release (se prueba solo LIBRE_KIT)"
dl "$OFFICIAL_URL"                             "$BIN_OFFICIAL" || warn "sin firmware oficial (no habrá test de hardware)"

# ---------------------------------------------------------------------------
# --- Flasheo: secuencia BOOT0/NRST + stm32flash (todo acá, sin scripts extra) ---
entrar_bootloader(){ # deja BOOT0=1 y pulsa NRST; imprime el PID que sostiene BOOT0
  local p n
  p="$(hold "$BOOT0_PIN" 1)"; sleep 0.2
  n="$(hold "$NRST_PIN" 0)";  sleep 0.2
  kill "$n" 2>/dev/null || true   # soltar NRST → pull-up → sale de reset
  sleep 0.3                        # entrar al bootloader UART
  echo "$p"
}

arrancar_firmware(){ # BOOT0=0 + pulso NRST → corre el firmware nuevo
  local p n
  p="$(hold "$BOOT0_PIN" 0)"; sleep 0.2
  n="$(hold "$NRST_PIN" 0)";  sleep 0.2
  kill "$n" 2>/dev/null || true
  sleep 0.3
  kill "$p" 2>/dev/null || true
}

flashear(){ # flashear <bin> — con un reintento por timing del bootloader
  local bin="$1" p log="${WORK}/stm32flash.log"
  for intento in 1 2; do
    p="$(entrar_bootloader)"
    if stm32flash -b 115200 -w "$bin" -g 0x0 "$PORT" >"$log" 2>&1; then
      kill "$p" 2>/dev/null || true
      arrancar_firmware
      return 0
    fi
    kill "$p" 2>/dev/null || true
    if [ "$intento" = 1 ]; then
      echo "      stm32flash no inicializó; reintentando la entrada al bootloader..."
      sleep 0.5
    fi
  done
  echo "      --- salida de stm32flash ---"
  sed 's/^/      /' "$log"
  if grep -qi 'NACK' "$log"; then
    echo "      NACK en el flasheo = write protection de fábrica:"
    echo "        sudo stm32flash -k $PORT"
  else
    echo "      El STM32 no entró al bootloader. Verificá:"
    echo "        - BOOT0 cableado a GPIO ${BOOT0_PIN} en esta placa. Si no lo está,"
    echo "          puenteá BOOT0 a 3V3 a mano, corré este script y soltá el puente"
    echo "          cuando diga 'Flasheando'."
    echo "        - Que ${PORT} no esté ocupado:  sudo systemctl stop mmdvmhost"
  fi
  return 1
}

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

# lee el string de versión que devuelve el STM32 (vacío = no arrancó)
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

flash_y_verificar(){
  local bin="$1" nombre="$2"
  echo -e "\n  ${B}--- ${nombre} ---${N}"
  verificar_bin "$bin" || return 1
  if ! flashear "$bin"; then
    warn "el flasheo falló"
    return 1
  fi
  ok "flash OK, esperando arranque..."
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
echo -e "\n${B}==> 4/5 Probando variantes de board...${N}"
ELEGIDA=""
if flash_y_verificar "$BIN_LIBRE" "LIBRE_KIT_ADF7021"; then
  ELEGIDA="LIBRE_KIT_ADF7021"
elif [ -f "$BIN_NANO" ] && flash_y_verificar "$BIN_NANO" "NANO_HOTSPOT"; then
  ELEGIDA="NANO_HOTSPOT"
fi

if [ -z "$ELEGIDA" ]; then
  warn "ninguna variante del firmware custom arrancó."
  echo -e "\n  ${B}Test de hardware con el firmware OFICIAL...${N}"
  if [ -f "$BIN_OFFICIAL" ] && flash_y_verificar "$BIN_OFFICIAL" "OFICIAL v1.5.2 (SIMPLEX)"; then
    fail "CONCLUSIÓN: la PLACA ESTÁ BIEN; el firmware custom no arranca en esta unidad."
    echo "    Necesita otra definición de board. Pasame el string de versión del oficial."
  else
    fail "CONCLUSIÓN: la placa no arranca ni con firmware oficial."
    echo "    Si el error fue de flasheo (no de arranque), el problema es el bootloader:"
    echo "      - BOOT0 no está cableado al GPIO ${BOOT0_PIN} → puenteá a 3V3 a mano"
    echo "      - Write protection → sudo stm32flash -k $PORT"
    echo "    Si el flasheo fue OK y no arrancó, es hardware (BOOT1 flotante o placa fallada)."
  fi
  systemctl start mmdvmhost 2>/dev/null || true
  exit 1
fi

ok "variante que arranca: ${ELEGIDA}"

# ---------------------------------------------------------------------------
echo -e "\n${B}==> 5/5 Configurando la placa como HOTSPOT...${N}"
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