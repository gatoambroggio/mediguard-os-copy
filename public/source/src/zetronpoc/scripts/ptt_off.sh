#!/usr/bin/env bash
# ptt_off.sh - Desactiva el PTT del radio via GPIO (BCM 17 por defecto)
# --- MODO PRUEBA: todas las lineas funcionales comentadas ---
# --- No toca el GPIO. Permite probar la generacion de WAV sin hardware. ---
# PIN="${POCSAG_GPIO_PIN:-17}"
# CHIP="${POCSAG_GPIO_CHIP:-gpiochip0}"
# gpioset "${CHIP}" "${PIN}=0" 2>/dev/null || true
# echo "ptt off (pin ${PIN})"
