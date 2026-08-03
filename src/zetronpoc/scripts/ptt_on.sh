#!/usr/bin/env bash
# ptt_on.sh - Activa el PTT del radio via GPIO (BCM 17 por defecto)
PIN="${POCSAG_GPIO_PIN:-17}"
CHIP="${POCSAG_GPIO_CHIP:-gpiochip0}"
gpioset "${CHIP}" "${PIN}=1" 2>/dev/null || true
echo "ptt on (pin ${PIN})"