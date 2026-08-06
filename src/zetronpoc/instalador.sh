#!/usr/bin/env bash
# ============================================================================
# instalador.sh - ZetronPOC v1.0 (paginacion hospitalaria POCSAG, cliente FreePBX)
# ============================================================================
# Registra internos SIP contra la central FreePBX del hospital y reproduce un
# IVR (igual al 2184) cuando alguien marca esos internos.
#
# Instalacion (una linea):
#   curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/src/zetronpoc/instalador.sh | sudo bash
#
# Actualizar (sin reinstalar Asterisk/deps):
#   curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/src/zetronpoc/instalador.sh | sudo bash -s -- --update
# ============================================================================
set -euo pipefail

REPO="https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main"
SRC="${REPO}/src/zetronpoc"
AST_ETC="/etc/asterisk"
APP_DIR="/opt/zetronpoc"
DB="${APP_DIR}/database/zetronpoc.db"
VERSION="2.0"
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

# ============================ 0. LIMPIAR SISTEMA ANTERIOR ====================
echo "==> 0/10 Limpiando instalacion anterior (pogsac-server / pogsag-server)..."
# Detener y deshabilitar TODOS los servicios viejos (y los propios por si es reintento)
for svc in pogsag-api pogsag-cola pogsag-monitor zetronpoc-api zetronpoc-cola; do
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
  rm -f "/etc/systemd/system/${svc}.service" 2>/dev/null || true
done
systemctl daemon-reload 2>/dev/null || true
# Matar procesos viejos que pudieran tener el puerto 8080 o colas activas
pkill -f "/opt/pogsag-server" 2>/dev/null || true
pkill -f "pogsag_handler" 2>/dev/null || true
pkill -f "cola_worker" 2>/dev/null || true
fuser -k 8080/tcp 2>/dev/null || true
# Borrar directorios de apps viejas
rm -rf /opt/pogsag-server 2>/dev/null || true
# Limpiar configs de Asterisk dejadas por sistemas viejos
for f in pjsip_hospital.conf pjsip_pocsag.conf pjsip_pogsag.conf \
         pjsip_hospital.conf.bak pjsip_pocsag.conf.bak pjsip_pogsag.conf.bak \
         extensions_hospital.conf extensions_pocsag.conf; do
  rm -f "${AST_ETC}/${f}" 2>/dev/null || true
done
# Limpiar AGI scripts viejos copiados a Asterisk
for f in pogsag_handler.py pogsag_check.py cola_worker.py; do
  rm -f "/var/lib/asterisk/agi-bin/${f}" 2>/dev/null || true
done
# Quitar cron y logrotate viejos
rm -f /etc/cron.d/pogsag-cleanup /etc/logrotate.d/pogsag 2>/dev/null || true
# Recargar Asterisk para que solte endpoints/registros viejos
asterisk -rx "pjsip reload" 2>/dev/null || true
asterisk -rx "dialplan reload" 2>/dev/null || true
log "Sistema anterior limpio."

# ============================ 1. DEPENDENCIAS ================================
echo "==> 1/10 Dependencias base..."
if [[ $UPDATE -eq 0 ]]; then
  apt-get update -y
  apt-get install -y sqlite3 python3 python3-pip alsa-utils sox git curl ca-certificates \
    logrotate espeak gpiod libgpiod2 asterisk 2>&1 || { err "Fallo instalacion de paquetes."; exit 1; }
else
  # En --update solo asegurar lo critico que pudo ser purgado (ej: asterisk)
  command -v asterisk >/dev/null 2>&1 || apt-get install -y asterisk 2>&1 || warn "No se pudo reinstalar asterisk"
fi
command -v espeak >/dev/null 2>&1 || apt-get install -y espeak sox 2>&1 || true
pip3 install --break-system-packages openpyxl xlrd 2>&1 || warn "openpyxl/xlrd no instalados (import Excel limitado a CSV)"

AST_USER="asterisk"
mkdir -p /var/lib/asterisk/agi-bin /var/lib/asterisk/sounds
chown -R "${AST_USER}:${AST_USER}" /var/lib/asterisk/agi-bin 2>/dev/null || true

# ============================ 2. ESTRUCTURA =================================
echo "==> 2/10 Estructura de directorios..."
mkdir -p "${APP_DIR}"/{asterisk,agi,encoder,database,services,scripts,config,backend,frontend,audio,logs,bin}
touch "${APP_DIR}/logs/"{api,cola}.log 2>/dev/null || true

# ============================ 3. DESCARGAR ARCHIVOS =========================
echo "==> 3/10 Descargando archivos..."

dl "${SRC}/backend/app.py" "${APP_DIR}/backend/app.py"
chmod +x "${APP_DIR}/backend/app.py"
dl "${SRC}/frontend/admin.html" "${APP_DIR}/frontend/admin.html"
dl "${SRC}/frontend/index.html" "${APP_DIR}/frontend/index.html"

dl "${SRC}/database/db_manager.py" "${APP_DIR}/database/db_manager.py"
chmod +x "${APP_DIR}/database/db_manager.py"
dl "${SRC}/database/schema.sql" "${APP_DIR}/database/schema.sql"
dl "${SRC}/database/seed.sql" "${APP_DIR}/database/seed.sql"

dl "${SRC}/agi/pocsag_handler.py" "${APP_DIR}/agi/pocsag_handler.py"
dl "${SRC}/agi/pocsag_check.py" "${APP_DIR}/agi/pocsag_check.py"
dl "${SRC}/agi/cola_worker.py" "${APP_DIR}/agi/cola_worker.py"
chmod +x "${APP_DIR}/agi/"*.py
cp "${APP_DIR}/agi/pocsag_handler.py" "${APP_DIR}/agi/pocsag_check.py" /var/lib/asterisk/agi-bin/
chmod +x /var/lib/asterisk/agi-bin/*.py
chown -R "${AST_USER}:${AST_USER}" /var/lib/asterisk/agi-bin 2>/dev/null || true

dl "${SRC}/encoder/pocsag_gen.py" "${APP_DIR}/encoder/pocsag_gen.py"
chmod +x "${APP_DIR}/encoder/pocsag_gen.py"

dl "${SRC}/scripts/ptt_on.sh" "${APP_DIR}/scripts/ptt_on.sh"
dl "${SRC}/scripts/ptt_off.sh" "${APP_DIR}/scripts/ptt_off.sh"
chmod +x "${APP_DIR}/scripts/"*.sh

dl "${SRC}/services/zetronpoc-api.service" "/etc/systemd/system/zetronpoc-api.service"
dl "${SRC}/services/zetronpoc-cola.service" "/etc/systemd/system/zetronpoc-cola.service"

# ============================ 4. ASTERISK CONFIG ===========================
echo "==> 4/10 Configurando Asterisk..."
mkdir -p "${AST_ETC}"
# pjsip.conf: self-contained (se regenera desde la BD en el paso 6 / panel admin)
cat > "${AST_ETC}/pjsip.conf" <<'EOF'
; ZetronPOC: pjsip.conf es self-contained (transport + endpoints + registros)
; Se regenera desde el panel admin -> Extensiones -> Aplicar a Asterisk
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
EOF

# extensions.conf: dialplan con IVR en un unico contexto (from-hospital)
dl "${SRC}/asterisk/extensions.conf" "${AST_ETC}/extensions.conf"
dl "${SRC}/asterisk/modules.conf" "${AST_ETC}/modules.conf" 2>/dev/null || true

chown -R "${AST_USER}:${AST_USER}" "${AST_ETC}" 2>/dev/null || true

# ============================ 5. BASE DE DATOS ==============================
echo "==> 5/10 Inicializando base de datos..."
if [[ $UPDATE -eq 0 ]] || [[ ! -f "${DB}" ]]; then
  python3 "${APP_DIR}/database/db_manager.py" init
fi
python3 - <<PYEOF
import sqlite3
c = sqlite3.connect('${DB}')
c.execute("INSERT OR REPLACE INTO config(clave,valor) VALUES('version','${VERSION}')")
c.commit(); c.close()
PYEOF
chmod 640 "${DB}" 2>/dev/null || true
chown "${AST_USER}:${AST_USER}" "${DB}" 2>/dev/null || true

# ============================ 6. GENERAR PJSIP DESDE BD ====================
echo "==> 6/10 Generando pjsip_zetronpoc.conf desde la base de datos..."
python3 - <<'PYEOF'
import sys, os
sys.path.insert(0, "/opt/zetronpoc"); sys.path.insert(0, "/opt/zetronpoc/database")
os.environ["ZETRONPOC_DIR"] = "/opt/zetronpoc"
try:
    from db_manager import generar_pjsip_conf
    ok, msg = generar_pjsip_conf()
    print(f"[{'OK' if ok else 'WARN'}] {msg}")
except Exception as e:
    print(f"[WARN] {e}")
PYEOF
chown "${AST_USER}:${AST_USER}" "${AST_ETC}/pjsip.conf" 2>/dev/null || true

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
cat > /etc/logrotate.d/zetronpoc <<EOF
${APP_DIR}/logs/*.log { daily rotate 14 compress missingok notifempty }
EOF
systemctl daemon-reload
systemctl enable --now asterisk 2>/dev/null || warn "Asterisk no pudo activarse"
asterisk -rx "dialplan reload" 2>/dev/null || warn "No se pudo recargar dialplan"
asterisk -rx "pjsip reload" 2>/dev/null || true
sleep 1
# Verificar que res_pjsip cargo el transporte; si no, forzar recarga del modulo
if ! asterisk -rx "pjsip show transports" 2>/dev/null | grep -q "transport-udp"; then
  warn "pjsip no cargo el transporte. Reintentando..."
  asterisk -rx "module reload res_pjsip.so" 2>/dev/null || true
  asterisk -rx "pjsip reload" 2>/dev/null || true
  sleep 1
fi
asterisk -rx "pjsip show transports" 2>/dev/null | head -6 || true
systemctl enable --now zetronpoc-api 2>/dev/null || warn "API no pudo activarse"
systemctl enable --now zetronpoc-cola 2>/dev/null || true
sleep 2

# ============================ 10. CHEQUEO =================================
echo "==> 10/10 Chequeo final..."
if curl -sf "http://localhost:8080/api/health" >/dev/null 2>&1; then
  log "API responde en http://localhost:8080"
else
  warn "API no responde aun. Verifique: systemctl status zetronpoc-api"
fi
echo "  Dialplan cargado:"
asterisk -rx "dialplan show from-hospital" 2>/dev/null | head -8 || warn "No se pudo mostrar el dialplan"

echo "--------------------------------------------"
log "ZetronPOC v${VERSION} instalado."
echo ""
echo "  Panel publico: http://localhost:8080/"
echo "  Panel admin  : http://localhost:8080/admin  (admin / admin123)"
echo ""
echo "  PROXIMO PASO (todo desde el panel admin):"
echo "    1) Parametros -> IP de la central FreePBX -> Guardar"
echo "    2) Extensiones -> editar cada interno con su clave real"
echo "    3) Extensiones -> Aplicar a Asterisk  (genera pjsip_zetronpoc.conf)"
echo "    4) La columna 'Registro' debe quedar en Registered"
echo "    5) Probar IVR: marcar *99 desde la central (escucha dos beeps)"
echo ""
echo "  Verificar por consola:"
echo "    sudo asterisk -rx 'pjsip show registrations'"
echo "    sudo asterisk -rx 'dialplan show from-hospital'"
echo ""
echo "  Actualizar (sin perder config):"
echo "    curl -fsSL ${SRC}/instalador.sh | sudo bash -s -- --update"
echo ""
echo "  Desinstalar (elimina todo):"
echo "    curl -fsSL ${SRC}/desinstalador.sh | sudo bash"