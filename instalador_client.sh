#!/usr/bin/env bash
# ============================================================================
# instalador_client.sh - Pogsac v1.0 (paginacion hospitalaria POCSAG, modo cliente)
# ============================================================================
# Registra internos (2000-2010) contra la central VoIP del hospital (FreePBX).
# TOTALMENTE SELF-CONTAINED: no depende de instalador.sh ni de pjsip_pocsag.conf.
# Toda la configuracion se maneja desde la base de datos via panel admin.
#
# Instalacion (una linea):
#   curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/instalador_client.sh | sudo bash
#
# Actualizar (sin reinstalar Asterisk/deps):
#   curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/instalador_client.sh | sudo bash -s -- --update
# ============================================================================
set -euo pipefail

REPO="https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main"
SRC="${REPO}/src/pocsag-server-client"
AST_ETC="/etc/asterisk"
APP_DIR="/opt/pocsag-server"
DB="${APP_DIR}/database/pocsag.db"
VERSION="1.02"
UPDATE=0
[[ "${1:-}" == "--update" ]] && UPDATE=1

G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; NC="\033[0m"
log(){ echo -e "${G}[OK]${NC}   $*"; }
warn(){ echo -e "${Y}[WARN]${NC} $*"; }
err(){ echo -e "${R}[ERR]${NC}  $*" >&2; }

[[ $EUID -ne 0 ]] && { err "Ejecuta como root o con sudo."; exit 1; }

dl(){ # dl <url> <dest>
  if ! curl -fsSL "$1" -o "$2"; then err "No se pudo descargar $1"; exit 1; fi
}

export TZ="America/Argentina/Cordoba"
timedatectl set-timezone "America/Argentina/Cordoba" 2>/dev/null || true

# ============================ 1. DEPENDENCIAS ================================
if [[ $UPDATE -eq 0 ]]; then
  echo "==> 1/10 Dependencias base..."
  apt-get update -y
  apt-get install -y sqlite3 python3 python3-pip alsa-utils sox git \
    libgpiod2 gpiod curl ca-certificates logrotate espeak zip \
    python3-dev build-essential wget asterisk 2>&1 || { err "Fallo instalacion de paquetes."; exit 1; }
  pip3 install --break-system-packages openpyxl xlrd 2>&1 || warn "openpyxl/xlrd no instalados"
else
  echo "==> 1/10 Dependencias (omitidas en --update)"
fi

AST_USER="asterisk"
mkdir -p /var/lib/asterisk/agi-bin /var/lib/asterisk/sounds
chown -R "${AST_USER}:${AST_USER}" /var/lib/asterisk/agi-bin 2>/dev/null || true

# ============================ 2. ESTRUCTURA =================================
echo "==> 2/10 Estructura de directorios..."
mkdir -p "${APP_DIR}"/{asterisk,agi,encoder,database,services,scripts,config,backend,frontend,docs,tests,audio,logs,bin}
touch "${APP_DIR}/logs/"{pocsag,cola,backup,health,scheduler,smtp}.log 2>/dev/null || true

# ============================ 3. DESCARGAR ARCHIVOS =========================
echo "==> 3/10 Descargando archivos del sistema cliente..."

# Backend
dl "${SRC}/backend/app.py" "${APP_DIR}/backend/app.py"
chmod +x "${APP_DIR}/backend/app.py"

# Frontend
dl "${SRC}/frontend/admin.html" "${APP_DIR}/frontend/admin.html"
dl "${SRC}/frontend/index.html" "${APP_DIR}/frontend/index.html"

# Database
dl "${SRC}/database/db_manager.py" "${APP_DIR}/database/db_manager.py"
chmod +x "${APP_DIR}/database/db_manager.py"
dl "${SRC}/database/schema.sql" "${APP_DIR}/database/schema.sql"
dl "${SRC}/database/seed.sql" "${APP_DIR}/database/seed.sql"

# AGI
dl "${SRC}/agi/pocsag_handler.py" "${APP_DIR}/agi/pocsag_handler.py"
dl "${SRC}/agi/pocsag_check.py" "${APP_DIR}/agi/pocsag_check.py"
dl "${SRC}/agi/cola_worker.py" "${APP_DIR}/agi/cola_worker.py"
chmod +x "${APP_DIR}/agi/"*.py
cp "${APP_DIR}/agi/pocsag_handler.py" "${APP_DIR}/agi/pocsag_check.py" /var/lib/asterisk/agi-bin/
chmod +x /var/lib/asterisk/agi-bin/*.py
chown -R "${AST_USER}:${AST_USER}" /var/lib/asterisk/agi-bin 2>/dev/null || true

# Encoder
dl "${SRC}/encoder/pocsag_gen.py" "${APP_DIR}/encoder/pocsag_gen.py"
chmod +x "${APP_DIR}/encoder/pocsag_gen.py"

# Scripts
dl "${SRC}/scripts/ptt_on.sh" "${APP_DIR}/scripts/ptt_on.sh"
dl "${SRC}/scripts/ptt_off.sh" "${APP_DIR}/scripts/ptt_off.sh"
dl "${SRC}/scripts/healthcheck.sh" "${APP_DIR}/scripts/healthcheck.sh"
dl "${SRC}/scripts/limpiar_audio.sh" "${APP_DIR}/scripts/limpiar_audio.sh"
chmod +x "${APP_DIR}/scripts/"*.sh

# Services
dl "${SRC}/services/pocsag-api.service" "/etc/systemd/system/pocsag-api.service"
dl "${SRC}/services/pocsag-cola.service" "/etc/systemd/system/pocsag-cola.service"
dl "${SRC}/services/pocsag-monitor.service" "/etc/systemd/system/pocsag-monitor.service"

# Asterisk configs
dl "${SRC}/asterisk/extensions_hospital.conf" "${AST_ETC}/extensions_hospital.conf"
dl "${SRC}/asterisk/modules.conf" "${AST_ETC}/modules.conf" 2>/dev/null || true

# ============================ 4. PJSIP.CONF CLEAN ==========================
echo "==> 4/10 Configurando pjsip.conf (self-contained)..."
# Renombrar pjsip_pocsag.conf viejo para evitar conflictos de transporte duplicado
if [[ -f "${AST_ETC}/pjsip_pocsag.conf" ]] && ! grep -q "pjsip_pocsag" "${AST_ETC}/pjsip.conf" 2>/dev/null; then
  mv "${AST_ETC}/pjsip_pocsag.conf" "${AST_ETC}/pjsip_pocsag.conf.bak" 2>/dev/null || true
  echo "  [FIX] pjsip_pocsag.conf renombrado a .bak (evita transporte duplicado)"
fi
# pjsip.conf: SOLO incluye pjsip_hospital.conf (que tiene su propio transporte)
# Esto elimina la dependencia de pjsip_pocsag.conf y evita transportes duplicados
cat > "${AST_ETC}/pjsip.conf" <<'EOF'
; pjsip_hospital.conf es SELF-CONTAINED: incluye [transport-udp] + endpoints + registros
; Todo se genera desde el panel admin (base de datos) -> Aplicar a Asterisk
#include pjsip_hospital.conf
EOF

# pjsip_hospital.conf: solo descargar template si no existe (en --update se regenera desde BD)
if [[ $UPDATE -eq 0 ]] || [[ ! -f "${AST_ETC}/pjsip_hospital.conf" ]]; then
  dl "${SRC}/asterisk/pjsip_hospital.conf" "${AST_ETC}/pjsip_hospital.conf"
fi

# extensions.conf: incluye extensions_hospital.conf
cat > "${AST_ETC}/extensions.conf" <<'EOF'
[general]
priorityjumping=no

; IVR autocontenido del cliente (contexto pocsag-incoming + pocsag-ivr)
#include extensions_hospital.conf
EOF

chown -R "${AST_USER}:${AST_USER}" "${AST_ETC}" 2>/dev/null || true

# ============================ 5. BASE DE DATOS ==============================
echo "==> 5/10 Inicializando base de datos..."
if [[ $UPDATE -eq 0 ]] || [[ ! -f "${DB}" ]]; then
  python3 "${APP_DIR}/database/db_manager.py" init
fi
# Forzar modo cliente y version (NO pisar hospital_pbx_ip si ya tiene un valor real)
python3 - <<PYEOF
import sqlite3
c = sqlite3.connect('${DB}')
c.execute("INSERT OR REPLACE INTO config(clave,valor) VALUES('pocsag_mode','client')")
# Limpiar valor IP_HOSPITAL corrupto dejado por instalador viejo
row = c.execute("SELECT valor FROM config WHERE clave='hospital_pbx_ip'").fetchone()
if row and row[0] == 'IP_HOSPITAL':
    c.execute("UPDATE config SET valor='' WHERE clave='hospital_pbx_ip'")
    print("[FIX]  hospital_pbx_ip era 'IP_HOSPITAL' (placeholder). Limpiado.")
# Asegurar config por defecto (INSERT OR IGNORE no pisa valores existentes)
for k,v in [('hospital_pbx_ip','192.168.2.97'),('hospital_pbx_port','5060'),('transport_bind','0.0.0.0:5060'),('transport_protocol','udp'),
            ('codecs','ulaw,alaw'),('retry_interval','60'),('expiration','3600'),
            ('warmup_512_ms','750'),('warmup_1200_ms','1500'),('warmup_2400_ms','1500'),('preamble_bits','576'),
            ('fsk_deviation_khz','4.5'),('fsk_deviation_baseband_hz','450'),('fsk_levels','2'),('function_mode','alphanumeric'),('baudios_default','1200')]:
    c.execute("INSERT OR IGNORE INTO config(clave,valor) VALUES(?,?)", (k,v))
c.execute("INSERT OR REPLACE INTO config(clave,valor) VALUES('version','${VERSION}')")
# Asegurar que existen los internos 2000-2010 (no pisar claves existentes)
for n in ('2000','2001','2002','2003','2004','2005','2006','2007','2008','2009','2010'):
    c.execute("INSERT OR IGNORE INTO extensiones (numero,password,contexto,descripcion,activo) VALUES (?,?,?,?,1)",
              (n, 'CAMBIAR_PASSWORD_' + n, 'pocsag-incoming', 'Interno hospital ' + n))
c.commit(); c.close()
PYEOF
chmod 640 "${DB}" 2>/dev/null || true
chown "${AST_USER}:${AST_USER}" "${DB}" 2>/dev/null || true

# ============================ 6. GENERAR PJSIP DESDE BD ====================
echo "==> 6/10 Generando pjsip_hospital.conf desde la base de datos..."
python3 - <<'PYEOF'
import sys, os
sys.path.insert(0, "/opt/pocsag-server")
sys.path.insert(0, "/opt/pocsag-server/database")
os.chdir("/opt/pocsag-server")
try:
    from db_manager import generar_pjsip_hospital_conf
    ok, msg = generar_pjsip_hospital_conf()
    if ok:
        print(f"[OK]   {msg}")
    else:
        print(f"[WARN] {msg}")
        print("       Configure la IP y claves desde el panel admin -> Aplicar a Asterisk")
except Exception as e:
    print(f"[WARN] No se pudo generar pjsip_hospital.conf: {e}")
PYEOF
chown "${AST_USER}:${AST_USER}" "${AST_ETC}/pjsip_hospital.conf" 2>/dev/null || true

# ============================ 7. LOCUCIONES IVR ============================
if [[ $UPDATE -eq 0 ]]; then
  echo "==> 7/10 Generando locuciones del IVR..."
  gen(){ local out="${APP_DIR}/audio/$1.gsm"; [[ -f "$out" ]] && return
    espeak -v es -s 160 "$2" -w "${out%.gsm}.wav" 2>/dev/null && sox "${out%.gsm}.wav" -r 8000 -c 1 "$out" 2>/dev/null || warn "No se pudo generar $1"
    rm -f "${out%.gsm}.wav"; }
  gen despues-del-tono-marque-codigo "Despues del tono marque el numero de codigo"
  gen despues-de-la-senal-su-mensaje "Despues de la senal marque su mensaje"
  gen codigo-inexistente "Codigo inexistente"
  gen marque-otro-codigo "Por favor marque otro codigo"
  gen mensaje-vacio "Mensaje vacio"
  gen confirmado "Mensaje enviado"
  gen error-envio "Error de envio"
  sox -n -r 8000 -c 1 "${APP_DIR}/audio/beep.gsm" synth 0.2 sine 1000 2>/dev/null || warn "beep no generado"
  cp "${APP_DIR}"/audio/*.gsm /var/lib/asterisk/sounds/ 2>/dev/null || true
  chown -R "${AST_USER}:${AST_USER}" /var/lib/asterisk/sounds 2>/dev/null || true
else
  echo "==> 7/10 Locuciones IVR (omitidas en --update)"
fi

# ============================ 8. PERMISOS ==================================
echo "==> 8/10 Ajustando permisos..."
chown -R "${AST_USER}:${AST_USER}" "${APP_DIR}" 2>/dev/null || true
chown -R "${AST_USER}:${AST_USER}" "${AST_ETC}" 2>/dev/null || true

# ============================ 9. SERVICIOS + CRON ==========================
echo "==> 9/10 Activando servicios..."
cat > /etc/logrotate.d/pocsag <<EOF
${APP_DIR}/logs/*.log { daily rotate 14 compress missingok notifempty }
EOF
cat > /etc/cron.d/pocsag-cleanup <<'EOF'
0 3 * * * root /opt/pocsag-server/scripts/limpiar_audio.sh 7 >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/pocsag-cleanup
systemctl daemon-reload
systemctl enable --now asterisk 2>/dev/null || warn "Asterisk no pudo activarse"
asterisk -rx "dialplan reload" 2>/dev/null || warn "No se pudo recargar dialplan"
asterisk -rx "pjsip reload" 2>/dev/null || true
systemctl restart pocsag-api 2>/dev/null || warn "API no pudo reiniciarse"
systemctl enable pocsag-api 2>/dev/null || true
systemctl restart pocsag-cola 2>/dev/null || true
systemctl enable pocsag-cola 2>/dev/null || true
systemctl restart pocsag-monitor 2>/dev/null || true
systemctl enable pocsag-monitor 2>/dev/null || true
sleep 2

# ============================ 10. CHEQUEO =================================
echo "==> 10/10 Chequeo final..."
if curl -sf "http://localhost:8080/api/health" >/dev/null 2>&1; then
  log "API responde en http://localhost:8080"
else
  warn "API no responde aun. Verifique: systemctl status pocsag-api"
fi

echo "--------------------------------------------"
log "Pogsac v${VERSION} instalado (paginacion hospitalaria, modo cliente)."
echo ""
echo "  Panel publico: http://localhost:8080/"
echo "  Panel admin  : http://localhost:8080/admin  (admin / admin123)"
echo ""
echo "  PROXIMO PASO (todo desde el panel admin):"
echo "    1) Parametros -> IP central del hospital (default 192.168.2.97) -> Guardar"
echo "    2) Extensiones -> editar cada interno (2000-2010) con su clave real"
echo "    3) Extensiones -> Aplicar a Asterisk  (regenera pjsip_hospital.conf)"
echo "    4) La columna 'Registro' muestra Registered / No registrado en vivo"
echo ""
echo "  Verificar por consola:"
echo "    sudo asterisk -rx 'pjsip show registrations'"
echo "    sudo asterisk -rx 'dialplan show pocsag-incoming'"
echo "    cat /etc/asterisk/pjsip_hospital.conf"
echo ""
echo "  Actualizar (sin perder config):"
echo "    curl -fsSL ${REPO}/instalador_client.sh | sudo bash -s -- --update"