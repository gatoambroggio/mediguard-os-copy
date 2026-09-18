#!/usr/bin/env bash
# Flashea firmware al STM32 del Nano hotSPOT por SERIAL (stm32flash).
#
# Maneja automáticamente la secuencia BOOT0/NRST por GPIO (libgpiod):
#   1. Entra al bootloader  (BOOT0=1 + pulso NRST)
#   2. Flashea con stm32flash a 0x08000000 (0x0)
#   3. Arranca el firmware   (BOOT0=0 + pulso NRST)
#
# Pines GPIO por defecto (Nano hotSPOT / Jumbospot, igual que Makefile MMDVM_HS):
#   BOOT0 = GPIO 20
#   NRST  = GPIO 21
#
# Override con variables de entorno:
#   BOOT0_PIN=23 NRST_PIN=24 ./flash.sh firmware.bin
#   GPIOCHIP=gpiochip4 ./flash.sh firmware.bin   # RPi 5
#
# Requiere:  sudo apt install stm32flash gpiod
set -euo pipefail

BIN="${1:-firmware_pocsag512_149mhz.bin}"
PORT="${2:-/dev/ttyAMA0}"
BOOT0_PIN="${BOOT0_PIN:-20}"
NRST_PIN="${NRST_PIN:-21}"
GPIOCHIP="${GPIOCHIP:-gpiochip0}"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: correr con sudo:  sudo ./flash.sh $BIN"; exit 1; }
[ -f "$BIN" ] || { echo "ERROR: no existe $BIN"; echo "Uso: sudo ./flash.sh <firmware.bin> [serial_port]"; exit 1; }
command -v stm32flash >/dev/null 2>&1 || { echo "ERROR: stm32flash no instalado.  sudo apt install stm32flash"; exit 1; }
command -v gpioset >/dev/null 2>&1 || { echo "ERROR: gpioset no instalado.  sudo apt install gpiod"; exit 1; }

# Mata cualquier gpioset previo que pueda tener BOOT0 trabado
pkill -f "gpioset.*$GPIOCHIP" 2>/dev/null || true
sleep 0.2

echo "=== Flash MMDVM_HS → Nano hotSPOT ==="
echo "  Firmware: $BIN ($(stat -c%s "$BIN") bytes)"
echo "  Puerto:   $PORT"
echo "  BOOT0:    GPIO $BOOT0_PIN"
echo "  NRST:     GPIO $NRST_PIN"
echo ""

# --- Paso 1: entrar al bootloader ---
echo "[1/3] Entrando al bootloader (BOOT0=1 + pulso RESET)..."
gpioset "$GPIOCHIP" "$BOOT0_PIN"=1 &    # mantener BOOT0 alto
HOLD_PID=$!
sleep 0.2
gpioset "$GPIOCHIP" "$NRST_PIN"=0 &     # NRST low → STM32 entra en reset
NRST_PID=$!
sleep 0.2
kill "$NRST_PID" 2>/dev/null || true     # soltar NRST → pull-up la lleva a high → STM32 sale de reset
sleep 0.3                                # esperar a que el STM32 entre al bootloader UART
echo "      OK."

# --- Paso 2: flashear ---
echo "[2/3] Flasheando a 0x08000000..."
if ! stm32flash -b 115200 -v -w "$BIN" -g 0x0 "$PORT"; then
    kill "$HOLD_PID" 2>/dev/null || true
    echo ""
    echo "ERROR: stm32flash fallo."
    echo "  Si NACK al ~67% (write protection activada):"
    echo "    sudo stm32flash -k $PORT"
    echo "    sleep 1 && sudo ./flash.sh $BIN $PORT"
    exit 1
fi
echo "      Flash OK."

# --- Paso 3: arrancar el firmware ---
echo "[3/3] Arrancando firmware (BOOT0=0 + pulso RESET)..."
kill "$HOLD_PID" 2>/dev/null || true     # soltar BOOT0=1
sleep 0.2
gpioset "$GPIOCHIP" "$BOOT0_PIN"=0 &     # BOOT0=0 (asegurar que arranque de flash)
HOLD_PID2=$!
sleep 0.2
gpioset "$GPIOCHIP" "$NRST_PIN"=0 &      # NRST low → reset
NRST_PID2=$!
sleep 0.2
kill "$NRST_PID2" 2>/dev/null || true    # soltar NRST → STM32 sale de reset con BOOT0=0 → arranca firmware
sleep 0.3
kill "$HOLD_PID2" 2>/dev/null || true    # soltar BOOT0=0

echo ""
echo "=== Listo. El STM32 arrancó con el nuevo firmware. ==="
echo "  Verificar: sudo systemctl restart mmdvmhost && journalctl -u mmdvmhost -f | grep -i version"