#!/bin/bash
# stage2-mediguard/02-mediguard-firstboot.sh
# Se ejecuta dentro del rootfs durante el build. Instala un servicio oneshot
# que corre en el PRIMER arranque real de la Pi para:
#   1) Detectar el gpiochip real (en el build, sobre PC x86, no hay /dev/gpiochip*).
#   2) Expandir el rootfs al tamanho real de la microSD.
#   3) Meter al usuario admin en grupos utiles (dialout/gpio/audio) para debug.
# El servicio se auto-deshabilita tras correr una vez (ConditionPathExists).
set -e

# ---- script que corre en el primer boot ----
cat > /usr/local/bin/mediguard-firstboot.sh <<'FB'
#!/bin/bash
# MediGuard first-boot setup.
GPIO_CHIP="gpiochip0"
BEST=0
for c in 0 1 2 3 4 5 6 7; do
  if [[ -e "/dev/gpiochip$c" ]]; then
    N=$(gpioinfo "gpiochip$c" 2>/dev/null | wc -l)
    N=${N:-0}
    if [[ $N -gt $BEST ]]; then BEST=$N; GPIO_CHIP="gpiochip$c"; fi
  fi
done
GPIO_PIN="17"
python3 - <<PYEOF
import sqlite3
DB='/opt/zetronpoc/database/zetronpoc.db'
try:
    c=sqlite3.connect(DB)
    c.execute("INSERT OR REPLACE INTO config(clave,valor) VALUES('gpio_chip',?)",('${GPIO_CHIP}',))
    c.execute("INSERT OR REPLACE INTO config(clave,valor) VALUES('gpio_pin',?)",('${GPIO_PIN}',))
    c.commit(); c.close()
    print("[mediguard-firstboot] gpio_chip=%s gpio_pin=%s" % ('${GPIO_CHIP}','${GPIO_PIN}'))
except Exception as e:
    print("[mediguard-firstboot] WARN: %s" % e)
PYEOF
# Expandir rootfs al tamanho real de la microSD (idempotente)
command -v raspi-config >/dev/null 2>&1 && raspi-config --expand-rootfs 2>/dev/null || true
# Marcar done para que el servicio no vuelva a correr
touch /var/lib/mediguard-firstboot.done
FB
chmod +x /usr/local/bin/mediguard-firstboot.sh

# ---- unidad systemd oneshot ----
cat > /etc/systemd/system/mediguard-firstboot.service <<'UNIT'
[Unit]
Description=MediGuard first-boot setup (gpiochip detection + rootfs expand)
After=local-fs.target
ConditionPathExists=!/var/lib/mediguard-firstboot.done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mediguard-firstboot.sh
RemainAfterExit=yes
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
UNIT

# enable crea el symlink -> arranca en el primer boot
systemctl enable mediguard-firstboot.service 2>/dev/null || true

# grupos utiles para el usuario admin (debug serial / GPIO por SSH)
usermod -aG dialout,gpio,audio,plugdev admin 2>/dev/null || true
echo "[mediguard] firstboot service + grupos de usuario configurados."