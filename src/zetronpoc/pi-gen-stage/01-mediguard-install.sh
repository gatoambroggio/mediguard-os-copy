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
# --update pasa a instalador.sh: no reinstala deps base (ya estan via 00-packages)
# SKIP_ASTERISK_COMPILE=1: NO compilar Asterisk bajo qemu durante el build
# (tardaria 3-4 h). La compilacion nativa (~30 min) corre en el PRIMER arranque
# de la Pi via 02-mediguard-firstboot.sh -> instalar_asterisk.sh. Asi el build
# de la imagen baja de ~4 h a ~30 min.
export SKIP_ASTERISK_COMPILE=1
bash /tmp/instalador_rpi.sh --update
rm -f /tmp/instalador_rpi.sh

echo "[mediguard] instalacion completada dentro del rootfs."