#!/usr/bin/env bash
# ============================================================================
# instalador_freepbx.sh - ZetronPOC v2.0 sobre FreePBX 17
# ============================================================================
# Instala FreePBX 17 completo (Asterisk 21 + PJSIP + GUI) y luego despliega
# el panel ZetronPOC, el encoder POCSAG y el worker de cola encima.
#
# REQUISITO: SO base AlmaLinux 9 / Rocky 9 / CentOS Stream 9 (minimal).
#            FreePBX oficial NO soporta Ubuntu. Si estas en Ubuntu, primero
#            reinstala el servidor desde la ISO de AlmaLinux 9 minimal.
#
# Instalacion (una linea, como root):
#   curl -fsSL https://raw.githubusercontent.com/gatoambroggio/mediguard-os-copy/main/src/zetronpoc/instalador_freepbx.sh | bash
# ============================================================================
set -euo pipefail

REPO="https://raw.githubusercontent.com/gatoambroggio/mediguard-os-copy/main"
SRC="${REPO}/src/zetronpoc"
APP_DIR="/opt/zetronpoc"
DB="${APP_DIR}/database/zetronpoc.db"
VERSION="2.0-freepbx"

G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; B="\033[1;34m"; NC="\033[0m"
log(){ echo -e "${G}[OK]${NC}   $*"; }
warn(){ echo -e "${Y}[WARN]${NC} $*"; }
err(){ echo -e "${R}[ERR]${NC}  $*" >&2; }
step(){ echo -e "\n${B}==> $*${NC}"; }

[[ $EUID -ne 0 ]] && { err "Ejecuta como root."; exit 1; }

UPDATE_ZP=0
[[ "${1:-}" == "--update-zetronpoc" ]] && UPDATE_ZP=1

# dl <url> <dest> — descarga y valida que no venga HTML
dl(){
  local url="$1" dest="$2"
  if ! curl -fsSL "$url" -o "$dest"; then
    err "No se pudo descargar $url"; exit 1
  fi
  local first
  first="$(head -c 200 "$dest" | tr -d '\0')"
  if printf '%s' "$first" | grep -qiE '^(\s*<(!doctype|html)|<head)'; then
    err "El archivo bajado de $url vino como HTML. Abortando."; rm -f "$dest"; exit 1
  fi
}

# ============================ 0. CHEQUEO DE SO ==============================
step "0/9 Chequeo de sistema operativo"
if [[ $UPDATE_ZP -eq 1 ]]; then
  # Saltearse FreePBX (paso 1-2) y solo actualizar componentes ZetronPOC
  log "Modo --update-zetronpoc: solo se actualizan los componentes ZetronPOC."
  step "3/9 (update) Estructura ZetronPOC"
  mkdir -p "${APP_DIR}"/{asterisk,agi,encoder,database,services,scripts,config,backend,frontend,audio,logs,bin}
  touch "${APP_DIR}/logs/"{api,cola}.log 2>/dev/null || true
  step "4/9 (update) Descargando archivos ZetronPOC"
  dl "${SRC}/backend/app.py" "${APP_DIR}/backend/app.py"; chmod +x "${APP_DIR}/backend/app.py"
  dl "${SRC}/frontend/admin.html" "${APP_DIR}/frontend/admin.html"
  dl "${SRC}/frontend/index.html" "${APP_DIR}/frontend/index.html"
  dl "${SRC}/database/db_manager.py" "${APP_DIR}/database/db_manager.py"; chmod +x "${APP_DIR}/database/db_manager.py"
  dl "${SRC}/database/schema.sql" "${APP_DIR}/database/schema.sql"
  dl "${SRC}/database/seed.sql" "${APP_DIR}/database/seed.sql"
  dl "${SRC}/agi/pocsag_handler.py" "${APP_DIR}/agi/pocsag_handler.py"
  dl "${SRC}/agi/pocsag_check.py" "${APP_DIR}/agi/pocsag_check.py"
  dl "${SRC}/agi/cola_worker.py" "${APP_DIR}/agi/cola_worker.py"
  chmod +x "${APP_DIR}/agi/"*.py
  cp "${APP_DIR}/agi/pocsag_handler.py" "${APP_DIR}/agi/pocsag_check.py" /var/lib/asterisk/agi-bin/ 2>/dev/null || true
  chmod +x /var/lib/asterisk/agi-bin/*.py 2>/dev/null || true
  dl "${SRC}/encoder/pocsag_gen.py" "${APP_DIR}/encoder/pocsag_gen.py"; chmod +x "${APP_DIR}/encoder/pocsag_gen.py"
  dl "${SRC}/scripts/ptt_on.sh" "${APP_DIR}/scripts/ptt_on.sh"
  dl "${SRC}/scripts/ptt_off.sh" "${APP_DIR}/scripts/ptt_off.sh"
  chmod +x "${APP_DIR}/scripts/"*.sh
  chown -R asterisk:asterisk "${APP_DIR}" 2>/dev/null || true
  systemctl restart zetronpoc-api zetronpoc-cola 2>/dev/null || true
  asterisk -rx "dialplan reload" 2>/dev/null || true
  log "ZetronPOC actualizado (FreePBX intacto)."
  exit 0
fi
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VER="${VERSION_ID:-}"
else
  OS_ID=""; OS_VER=""
fi
SUPPORTED=0
case "$OS_ID" in
  almalinux|rocky|centos)
    [[ "$OS_VER" == 9* ]] && SUPPORTED=1
    ;;
esac
if [[ $SUPPORTED -eq 0 ]]; then
  err "FreePBX 17 requiere AlmaLinux 9 / Rocky 9 / CentOS Stream 9."
  err "Detectado: ${PRETTY_NAME:-$OS_ID $OS_VER}"
  err ""
  err "Pasos:"
  err "  1) Descarga AlmaLinux 9 minimal: https://almalinux.org/get-almalinux/"
  err "  2) Instala el SO (minimal, sin GUI)"
  err "  3) Volve a ejecutar este instalador en el nuevo servidor."
  exit 1
fi
log "SO soportado: ${PRETTY_NAME:-$OS_ID $OS_VER}"

export TZ="America/Argentina/Cordoba"
timedatectl set-timezone "America/Argentina/Cordoba" 2>/dev/null || true

# ============================ 1. DEPENDENCIAS BASE ==========================
step "1/9 Dependencias base del sistema"
dnf update -y
dnf install -y epel-release
dnf install -y wget curl git tar sqlite python3 python3-pip sox espeak \
  libgpiod libgpiod-devel gpiod httpd mariadb-server logrotate policycoreutils-python-utils 2>&1 || {
    err "Fallo la instalacion de paquetes base."; exit 1; }
pip3 install --break-system-packages openpyxl xlrd 2>&1 || warn "openpyxl/xlrd no instalados"
systemctl enable --now mariadb
log "Dependencias base listas."

# ============================ 2. FREEPBX 17 =================================
step "2/9 Instalando FreePBX 17 (Asterisk 21 + PJSIP + GUI)"
# SELinux a permissive (FreePBX lo necesita)
if command -v setenforce >/dev/null 2>&1; then
  setenforce 0 2>/dev/null || true
  sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
fi

FPBX_DIR="/usr/src/freepbx"
mkdir -p "$FPBX_DIR"
cd "$FPBX_DIR"

INSTALLER="install-17"
if [[ ! -x "$INSTALLER" ]]; then
  log "Descargando instalador oficial de FreePBX 17..."
  curl -fsSL "https://github.com/FreePBX/framework/releases/download/17.0.0/install-17" -o "$INSTALLER" || {
    err "No se pudo descargar el instalador de FreePBX 17. Verifica conectividad a GitHub."; exit 1; }
  chmod +x "$INSTALLER"
fi

log "Ejecutando instalador de FreePBX 17 (tarda 30-60 min, compila Asterisk)..."
# El instalador oficial instala Asterisk 21 con PJSIP completo + FreePBX + Apache.
if ! ./"$INSTALLER" --dbhost=127.0.0.1 --dbuser=root --dbpass= 2>&1; then
  # Reintento sin flags (algunas builds de install-17 no aceptan esos flags)
  warn "Instalador con flags fallo, reintentando en modo automatico..."
  ./"$INSTALLER" 2>&1 || { err "El instalador de FreePBX fallo. Revisa /usr/src/freepbx para logs."; exit 1; }
fi
log "FreePBX 17 instalado."

# Reiniciar Asterisk y verificar PJSIP + transporte UDP
systemctl enable --now asterisk 2>/dev/null || true
sleep 3
if ! asterisk -rx "module show" 2>/dev/null | grep -q "res_pjsip.so"; then
  warn "res_pjsip.so no cargo. Verifica: asterisk -rx 'module show'"
fi
if asterisk -rx "module show" 2>/dev/null | grep -q "res_pjsip_transport_udp.so"; then
  log "res_pjsip_transport_udp.so presente y cargado."
else
  warn "res_pjsip_transport_udp.so no aparece. FreePBX deberia traerlo; revisa /usr/lib64/asterisk/modules/"
fi

# ============================ 3. ESTRUCTURA ZETRONPOC ======================
step "3/9 Estructura ZetronPOC"
mkdir -p "${APP_DIR}"/{asterisk,agi,encoder,database,services,scripts,config,backend,frontend,audio,logs,bin}
touch "${APP_DIR}/logs/"{api,cola}.log 2>/dev/null || true

# ============================ 4. DESCARGAR ARCHIVOS =========================
step "4/9 Descargando archivos ZetronPOC"
dl "${SRC}/backend/app.py" "${APP_DIR}/backend/app.py"; chmod +x "${APP_DIR}/backend/app.py"
dl "${SRC}/frontend/admin.html" "${APP_DIR}/frontend/admin.html"
dl "${SRC}/frontend/index.html" "${APP_DIR}/frontend/index.html"
dl "${SRC}/database/db_manager.py" "${APP_DIR}/database/db_manager.py"; chmod +x "${APP_DIR}/database/db_manager.py"
dl "${SRC}/database/schema.sql" "${APP_DIR}/database/schema.sql"
dl "${SRC}/database/seed.sql" "${APP_DIR}/database/seed.sql"
dl "${SRC}/agi/pocsag_handler.py" "${APP_DIR}/agi/pocsag_handler.py"
dl "${SRC}/agi/pocsag_check.py" "${APP_DIR}/agi/pocsag_check.py"
dl "${SRC}/agi/cola_worker.py" "${APP_DIR}/agi/cola_worker.py"
chmod +x "${APP_DIR}/agi/"*.py
# AGI bin para FreePBX (mismo path que Asterisk puro)
AST_USER="asterisk"
mkdir -p /var/lib/asterisk/agi-bin /var/lib/asterisk/sounds
cp "${APP_DIR}/agi/pocsag_handler.py" "${APP_DIR}/agi/pocsag_check.py" /var/lib/asterisk/agi-bin/
chmod +x /var/lib/asterisk/agi-bin/*.py
chown -R "${AST_USER}:${AST_USER}" /var/lib/asterisk/agi-bin 2>/dev/null || true
dl "${SRC}/encoder/pocsag_gen.py" "${APP_DIR}/encoder/pocsag_gen.py"; chmod +x "${APP_DIR}/encoder/pocsag_gen.py"
dl "${SRC}/scripts/ptt_on.sh" "${APP_DIR}/scripts/ptt_on.sh"
dl "${SRC}/scripts/ptt_off.sh" "${APP_DIR}/scripts/ptt_off.sh"
chmod +x "${APP_DIR}/scripts/"*.sh
dl "${SRC}/services/zetronpoc-api.service" "/etc/systemd/system/zetronpoc-api.service"
dl "${SRC}/services/zetronpoc-cola.service" "/etc/systemd/system/zetronpoc-cola.service"
log "Archivos descargados."

# ============================ 5. BASE DE DATOS ZETRONPOC ====================
step "5/9 Base de datos ZetronPOC (SQLite)"
python3 "${APP_DIR}/database/db_manager.py" init
python3 - <<PYEOF
import sqlite3
c = sqlite3.connect('${DB}')
c.execute("INSERT OR REPLACE INTO config(clave,valor) VALUES('version','${VERSION}')")
c.commit(); c.close()
PYEOF
chmod 640 "${DB}" 2>/dev/null || true
chown "${AST_USER}:${AST_USER}" "${DB}" 2>/dev/null || true

# ============================ 6. DIALPLAN FreePBX (custom) =================
step "6/9 Dialplan IVR en FreePBX (extensions_custom.conf)"
# FreePBX gestiona extensions.conf; usamos extensions_custom.conf que FreePBX incluye
# y no sobreescribe al aplicar cambios desde la GUI.
dl "${SRC}/asterisk/extensions.conf" "${APP_DIR}/asterisk/extensions_zetronpoc.conf"
# Armamos extensions_custom.conf solo con el contexto from-hospital
if [[ -f /etc/asterisk/extensions_custom.conf ]]; then
  cp /etc/asterisk/extensions_custom.conf /etc/asterisk/extensions_custom.conf.bak.$(date +%s) 2>/dev/null || true
fi
# Extraer solo el contexto from-hospital y colocarlo en custom (sin duplicar)
python3 - <<'PYEOF'
import re
src = open('/opt/zetronpoc/asterisk/extensions_zetronpoc.conf').read()
m = re.search(r'(\[from-hospital\].*?)(?=\n\[|\Z)', src, re.S)
ctx = m.group(1).strip() if m else ''
path = '/etc/asterisk/extensions_custom.conf'
existing = open(path).read() if __import__('os').path.exists(path) else ''
existing = re.sub(r'\[from-hospital\].*?(?=\n\[|\Z)', '', existing, flags=re.S)
out = existing.rstrip() + '\n\n' + ctx + '\n'
open(path, 'w').write(out)
PYEOF
# Asegurar include en extensions_additional o via FreePBX (lo incluye por defecto)
chown "${AST_USER}:${AST_USER}" /etc/asterisk/extensions_custom.conf 2>/dev/null || true
asterisk -rx "dialplan reload" 2>/dev/null || warn "dialplan reload fallo (¿Asterisk corriendo?)"

# ============================ 7. LOCUCIONES IVR ===========================
step "7/9 Locuciones IVR"
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

# ============================ 8. SERVICIOS + PERMISOS ======================
step "8/9 Permisos y servicios"
chown -R "${AST_USER}:${AST_USER}" "${APP_DIR}" 2>/dev/null || true
cat > /etc/logrotate.d/zetronpoc <<EOF
${APP_DIR}/logs/*.log { daily rotate 14 compress missingok notifempty }
EOF
systemctl daemon-reload
systemctl enable --now zetronpoc-api 2>/dev/null || warn "API no pudo activarse"
systemctl enable --now zetronpoc-cola 2>/dev/null || warn "Worker de cola no pudo activarse"
systemctl restart zetronpoc-cola 2>/dev/null || true
sleep 2
# Apache ya corre en 80 (FreePBX). El panel ZetronPOC en 8080 no choca.
systemctl enable --now httpd 2>/dev/null || true

# ============================ 9. CHEQUEO FINAL ============================
step "9/9 Chequeo final"
if curl -sf "http://localhost:8080/api/health" >/dev/null 2>&1; then
  log "Panel ZetronPOC responde en http://localhost:8080/"
else
  warn "Panel no responde aun. Verifica: systemctl status zetronpoc-api"
fi
if systemctl is-active --quiet zetronpoc-cola; then
  log "Worker de cola activo"
else
  warn "Worker de cola NO activo. Verifica: journalctl -u zetronpoc-cola -n 30"
fi
echo "  Dialplan from-hospital:"
asterisk -rx "dialplan show from-hospital" 2>/dev/null | head -8 || warn "No se pudo mostrar el dialplan"
echo ""
echo "--------------------------------------------"
log "ZetronPOC v${VERSION} instalado sobre FreePBX 17."
echo ""
echo "  FreePBX GUI  : http://$(hostname -I 2>/dev/null | awk '{print $1}')/admin"
echo "  Panel ZetronPOC (publico): http://localhost:8080/"
echo "  Panel ZetronPOC (admin)  : http://localhost:8080/admin  (admin / admin123)"
echo ""
echo "  PROXIMOS PASOS:"
echo "    1) Abrir FreePBX GUI -> Settings -> Advanced Settings -> confirmar."
echo "    2) FreePBX -> Connectivity -> Extensions: crear/verificar los internos 2000-2010"
echo "       (ZetronPOC ya no sobreescribe pjsip.conf; las extensiones viven en FreePBX)."
echo "    3) Para probar el IVR: crear un Misc Application o Custom Extension en FreePBX"
echo "       que apunte al contexto [from-hospital] (ej: *99 -> from-hospital,s,1)."
echo "    4) Marcar *99 desde la central (escucha dos beeps)."
echo ""
echo "  Verificar por consola:"
echo "    sudo asterisk -rx 'pjsip show transports'    (debe mostrar transport-udp)"
echo "    sudo asterisk -rx 'dialplan show from-hospital'"
echo "    sudo systemctl status zetronpoc-cola"
echo ""
echo "  Actualizar (solo ZetronPOC, sin tocar FreePBX):"
echo "    curl -fsSL ${SRC}/instalador_freepbx.sh | bash -s -- --update-zetronpoc"
echo ""