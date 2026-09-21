#!/usr/bin/env bash
# Flashea firmware al STM32 del hotspot por SERIAL (stm32flash).
#
# Maneja automáticamente la secuencia BOOT0/NRST por GPIO (libgpiod):
#   1. Entra al bootloader  (BOOT0=1 + pulso NRST)
#   2. Flashea con stm32flash a 0x08000000 (0x0)
#   3. Arranca el firmware   (BOOT0=0 + pulso NRST)
#
# COMPATIBILIDAD gpiod: la sintaxis cambió entre v1 y v2.
#   gpiod v1:  gpioset gpiochip0 20=1
#   gpiod v2:  gpioset -c gpiochip0 20=1     <-- Debian 13 / Raspberry Pi OS nuevos
# Con v2, pasar el chip como argumento posicional da
#   "gpioset: invalid line value: 'gpiochip0'"
# y el STM32 nunca entra al bootloader -> "Failed to init device, timeout".
# Este script detecta la version y arma la invocacion correcta.
#
# El chip GPIO tambien se autodetecta (en RPi 5 el header es gpiochip4, no 0).
#
# Override con variables de entorno:
#   BOOT0_PIN=23 NRST_PIN=24 ./flash.sh firmware.bin
#   GPIOCHIP=gpiochip4 ./flash.sh firmware.bin
#
# Requiere:  sudo apt install stm32flash gpiod
set -uo pipefail

BIN="${1:-firmware_pocsag512_149mhz.bin}"
PORT="${2:-/dev/ttyAMA0}"
BOOT0_PIN="${BOOT0_PIN:-20}"
NRST_PIN="${NRST_PIN:-21}"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: correr con sudo:  sudo ./flash.sh $BIN"; exit 1; }
[ -f "$BIN" ] || { echo "ERROR: no existe $BIN"; echo "Uso: sudo ./flash.sh <firmware.bin> [serial_port]"; exit 1; }
command -v stm32flash >/dev/null 2>&1 || { echo "ERROR: stm32flash no instalado.  sudo apt install stm32flash"; exit 1; }
command -v gpioset >/dev/null 2>&1 || { echo "ERROR: gpioset no instalado.  sudo apt install gpiod"; exit 1; }

# --- Chip GPIO: el header de 40 pines (pinctrl de Broadcom). En RPi 5 es otro indice ---
if [ -z "${GPIOCHIP:-}" ]; then
  GPIOCHIP="$(gpiodetect 2>/dev/null | awk '/pinctrl|bcm/ {print $1; exit}')"
  GPIOCHIP="${GPIOCHIP:-gpiochip0}"
fi
if [ ! -e "/dev/${GPIOCHIP}" ]; then
  echo "ERROR: no existe /dev/${GPIOCHIP}."
  echo "  Chips disponibles:"
  gpiodetect 2>/dev/null | sed 's/^/    /' || echo "    (gpiodetect no disponible)"
  echo "  Forzá el chip correcto:  GPIOCHIP=gpiochip4 sudo ./flash.sh $BIN $PORT"
  exit 1
fi

# --- Sintaxis de gpioset segun version de gpiod ---
GPIOD_MAJ="$(gpioset --version 2>/dev/null | sed -n 's/.*[^0-9]v\([0-9]\{1,\}\).*/\1/p' | head -1)"
if [ -n "$GPIOD_MAJ" ] && [ "$GPIOD_MAJ" -ge 2 ]; then
  CHIP_ARGS=(-c "$GPIOCHIP")
elif [ -z "$GPIOD_MAJ" ] && gpioset --help 2>&1 | grep -q -- '--chip'; then
  CHIP_ARGS=(-c "$GPIOCHIP")
else
  CHIP_ARGS=("$GPIOCHIP")
fi

# Mata cualquier gpioset previo que pueda tener BOOT0 trabado
pkill -f "gpioset" 2>/dev/null || true
sleep 0.2

# hold <pin> <valor> -> deja la linea fija y devuelve el PID de gpioset
hold(){
  gpioset "${CHIP_ARGS[@]}" "$1"="$2" &
  echo $!
}

# Verifica que gpioset realmente pueda manejar la linea (falla rapido y claro).
# Sin opciones extra: la sintaxis de --toggle cambia entre versiones de gpiod.
gpioset "${CHIP_ARGS[@]}" "$BOOT0_PIN"=0 >/dev/null 2>&1 &
PROBE_PID=$!
sleep 0.3
if ! kill -0 "$PROBE_PID" 2>/dev/null; then
  wait "$PROBE_PID" 2>/dev/null; PROBE_RC=$?
  if [ "${PROBE_RC:-0}" -ne 0 ]; then
    echo "ERROR: gpioset no pudo manejar GPIO ${BOOT0_PIN} en ${GPIOCHIP}."
    echo "  Probá:  gpioset ${CHIP_ARGS[*]} ${BOOT0_PIN}=1"
    echo "  Si el chip es otro:  GPIOCHIP=gpiochip4 sudo ./flash.sh $BIN $PORT"
    exit 1
  fi
else
  kill "$PROBE_PID" 2>/dev/null || true
fi

echo "=== Flash MMDVM_HS → hotspot ==="
echo "  Firmware: $BIN ($(stat -c%s "$BIN") bytes)"
echo "  Puerto:   $PORT"
echo "  Chip:     $GPIOCHIP (gpiod v${GPIOD_MAJ:-?})"
echo "  BOOT0:    GPIO $BOOT0_PIN"
echo "  NRST:     GPIO $NRST_PIN"
echo ""

entrar_bootloader(){
  local hold_pid nrst_pid
  hold_pid="$(hold "$BOOT0_PIN" 1)"   # mantener BOOT0 alto
  sleep 0.2
  nrst_pid="$(hold "$NRST_PIN" 0)"    # NRST low → STM32 en reset
  sleep 0.2
  kill "$nrst_pid" 2>/dev/null || true # soltar NRST → pull-up → sale de reset
  sleep 0.3                            # esperar a que entre al bootloader UART
  echo "$hold_pid"
}

# --- Paso 1 + 2: bootloader y flash (con un reintento por timing) ---
HOLD_PID="$(entrar_bootloader)"
echo "[1/3] Bootloader listo (BOOT0=1)."
echo "[2/3] Flasheando a 0x08000000..."
if ! stm32flash -b 115200 -v -w "$BIN" -g 0x0 "$PORT"; then
  echo "      Reintentando la entrada al bootloader..."
  kill "$HOLD_PID" 2>/dev/null || true
  sleep 0.5
  HOLD_PID="$(entrar_bootloader)"
  if ! stm32flash -b 115200 -v -w "$BIN" -g 0x0 "$PORT"; then
    kill "$HOLD_PID" 2>/dev/null || true
    echo ""
    echo "ERROR: stm32flash no pudo inicializar el dispositivo."
    echo "  El STM32 no entró al bootloader. Verificá:"
    echo "    - Que BOOT0 esté realmente cableado a GPIO ${BOOT0_PIN} en esta placa"
    echo "      (si no lo está, puenteá BOOT0 a 3V3 a mano y reintentá)"
    echo "    - Que el chip GPIO sea el correcto:  gpiodetect"
    echo "    - Que el puerto serie sea el correcto y no esté ocupado:"
    echo "        sudo systemctl stop mmdvmhost"
    echo "  Si el error es NACK al ~67% (write protection activada):"
    echo "    sudo stm32flash -k $PORT"
    echo "    sleep 1 && sudo ./flash.sh $BIN $PORT"
    exit 1
  fi
fi
echo "      Flash OK."

# --- Paso 3: arrancar el firmware ---
echo "[3/3] Arrancando firmware (BOOT0=0 + pulso RESET)..."
kill "$HOLD_PID" 2>/dev/null || true     # soltar BOOT0=1
sleep 0.2
HOLD_PID2="$(hold "$BOOT0_PIN" 0)"       # BOOT0=0 (arranca de flash)
sleep 0.2
NRST_PID2="$(hold "$NRST_PIN" 0)"        # NRST low → reset
sleep 0.2
kill "$NRST_PID2" 2>/dev/null || true    # soltar NRST → arranca firmware
sleep 0.3
kill "$HOLD_PID2" 2>/dev/null || true    # soltar BOOT0=0

echo ""
echo "=== Listo. El STM32 arrancó con el nuevo firmware. ==="
echo "  Verificar: sudo systemctl restart mmdvmhost && journalctl -u mmdvmhost -f | grep -i version"