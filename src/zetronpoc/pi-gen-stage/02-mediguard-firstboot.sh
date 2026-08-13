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
# ---- Instalar Asterisk (ruta .deb instantanea; compila solo si falla) ----
# instalar_asterisk.sh prueba primero el .deb del release propio, despues los
# .deb precompilados de Ubuntu Noble arm64 (segundos, con chan_pjsip), y solo si
# ambos fallan cae a compilacion desde fuente (~30-60 min). En el primer arranque
# de la Pi normalmente resuelve en segundos via .deb.
if [[ ! -x /usr/sbin/asterisk ]] || [[ ! -f /usr/lib/asterisk/modules/chan_pjsip.so ]]; then
  echo "[mediguard-firstboot] Instalando Asterisk (ruta .deb instantanea; cae a compilacion solo si falla)..."
  if curl -fsSL https://raw.githubusercontent.com/gatoambroggio/mediguard-os-copy/main/src/zetronpoc/instalar_asterisk.sh -o /tmp/instalar_asterisk.sh; then
    bash /tmp/instalar_asterisk.sh || echo "[mediguard-firstboot] WARN: instalar_asterisk.sh fallo (ver /tmp/asterisk-build)"
    rm -f /tmp/instalar_asterisk.sh
  else
    echo "[mediguard-firstboot] WARN: no se pudo descargar instalar_asterisk.sh (sin red?). Telefonia no disponible."
  fi
fi

# ---- Generar locuciones IVR (espeak) si faltan ----
# El build corrio instalador.sh en --update, que saltea las locuciones (paso 7).
# Se generan aca, nativo, en el primer arranque.
if [[ -x /usr/sbin/asterisk ]] && ! ls /var/lib/asterisk/sounds/despues-del-tono-marque-codigo.gsm >/dev/null 2>&1; then
  echo "[mediguard-firstboot] Generando locuciones IVR..."
  AD=/opt/zetronpoc/audio
  gen(){ local out="$AD/$1.gsm"; [[ -f "$out" ]] && return
    espeak -v es -s 160 "$2" -w "${out%.gsm}.wav" 2>/dev/null && sox "${out%.gsm}.wav" -r 8000 -c 1 "$out" 2>/dev/null
    rm -f "${out%.gsm}.wav"; }
  gen despues-del-tono-marque-codigo "Despues del tono marque el numero de codigo"
  gen despues-de-la-senal-su-mensaje "Despues de la senal marque su mensaje"
  gen codigo-inexistente "Codigo inexistente"
  gen marque-otro-codigo "Por favor marque otro codigo"
  gen mensaje-vacio "Mensaje vacio"
  gen confirmado "Mensaje enviado"
  gen error-envio "Error de envio"
  sox -n -r 8000 -c 1 "$AD/beep.gsm" synth 0.2 sine 1000 2>/dev/null || true
  cp "$AD"/*.gsm /var/lib/asterisk/sounds/ 2>/dev/null || true
  chown -R asterisk:asterisk /var/lib/asterisk/sounds 2>/dev/null || true
fi

# ---- Activar Asterisk + cablear telefonia (pjsip/dialplan ya generados en el build) ----
if [[ -x /usr/sbin/asterisk ]]; then
  echo "[mediguard-firstboot] Activando Asterisk + recargando dialplan/pjsip..."
  systemctl enable --now asterisk 2>/dev/null || true
  sleep 2
  asterisk -rx "dialplan reload" 2>/dev/null || true
  asterisk -rx "pjsip reload" 2>/dev/null || true
  # Reiniciar API/cola para que reconecten con Asterisk ya arriba
  systemctl restart zetronpoc-api 2>/dev/null || true
  systemctl restart zetronpoc-cola 2>/dev/null || true
  echo "[mediguard-firstboot] Telefonia lista: internos SIP + IVR activos."
else
  echo "[mediguard-firstboot] WARN: Asterisk no compilo. IVR/SIP no disponible (paging por panel web SI funciona)."
fi

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