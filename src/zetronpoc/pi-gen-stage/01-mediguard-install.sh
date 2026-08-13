#!/bin/bash
# stage2-mediguard/01-mediguard-install.sh
# Se ejecuta DENTRO del rootfs arm64 durante el build de pi-gen (en chroot).
# Corre instalador_rpi.sh que deja ZetronPOC + Asterisk configurados y los
# servicios habilitados. 00-packages ya preinstalo las deps pesadas, asi que
# esto es mayormente configuracion + descarga de codigo desde GitHub.
#
# Nota: systemctl start/restart son no-ops en el chroot (no corre systemd durante
# el build), pero `systemctl enable` crea los symlinks -> los servicios arrancan
# en el primer boot real de la Pi.
set -e

export POCSAG_GPIO_PIN="${POCSAG_GPIO_PIN:-17}"
export ZETRONPOC_DIR="/opt/zetronpoc"

echo "[mediguard] descargando instalador_rpi.sh..."
curl -fsSL https://raw.githubusercontent.com/gatoambroggio/mediguard-os-copy/main/src/zetronpoc/instalador_rpi.sh \
  -o /tmp/instalador_rpi.sh
chmod +x /tmp/instalador_rpi.sh

echo "[mediguard] ejecutando instalador (gpio default BCM ${POCSAG_GPIO_PIN})..."
# --update: no reinstala deps base (ya estan via 00-packages).
# SKIP_ASTERISK_COMPILE=1 + SKIP_MMDVM_INSTALL=1: NO compilar ni Asterisk ni
# MMDVMHost bajo qemu (lento + fragil). Ambos se instalan nativamente en el
# PRIMER arranque de la Pi via 02-mediguard-firstboot.sh (~5-10 min). Asi el
# build baja a ~30 min y no aborta por una compilacion ARM emulada que falle.
export SKIP_ASTERISK_COMPILE=1
export SKIP_MMDVM_INSTALL=1
# CRITICO: si el instalador falla por cualquier motivo (red, apt, python, etc.)
# NO abortamos el build -> no habria .img y el usuario se queda sin nada. Se
# marca un flag y 02-mediguard-firstboot.sh corre el instalador COMPLETO en el
# primer arranque real. Resultado: la imagen SIEMPRE se genera y en la Pi todo
# se instala solo.
mkdir -p /etc/mediguard
if bash /tmp/instalador_rpi.sh --update; then
  echo "[mediguard] instalacion en rootfs OK."
else
  echo "[mediguard] WARN: instalador fallo en el build -> se completa en el primer boot."
  touch /etc/mediguard/need-full-install
fi
rm -f /tmp/instalador_rpi.sh

echo "[mediguard] instalacion completada dentro del rootfs."