#!/usr/bin/env bash
# ============================================================================
# instalador.sh - ZetronPOC v1.0 (paginacion hospitalaria POCSAG, cliente FreePBX)
# ============================================================================
# Registra internos SIP contra la central FreePBX del hospital y reproduce un
# IVR (igual al 2184) cuando alguien marca esos internos.
#
# Instalacion (una linea):
#   curl -fsSL https://raw.githubusercontent.com/gatoambroggio/mediguard-os-copy/main/src/zetronpoc/instalador.sh | sudo bash
#
# Actualizar (sin reinstalar Asterisk/deps):
#   curl -fsSL https://raw.githubusercontent.com/gatoambroggio/mediguard-os-copy/main/src/zetronpoc/instalador.sh | sudo bash -s -- --update
# ============================================================================
set -euo pipefail

REPO="https://raw.githubusercontent.com/gatoambroggio/mediguard-os-copy/main"
SRC="${REPO}/src/zetronpoc"
AST_ETC="/etc/asterisk"
APP_DIR="/opt/zetronpoc"
DB="${APP_DIR}/database/zetronpoc.db"
VERSION="2.0"
UPDATE=0
NO_ASTERISK=0
for arg in "$@"; do
  [[ "$arg" == "--update" ]] && UPDATE=1
  [[ "$arg" == "--no-asterisk" ]] && NO_ASTERISK=1
done
# --no-asterisk (opt-in, por defecto OFF): saltea apt-get install asterisk y las
# recargas de Asterisk. SIRVE SOLO si vas a compilar Asterisk aparte con
# instalar_asterisk.sh y despues reejecutar el instalador sin el flag para que
# genere la config de telefonia. La telefonia (IVR/internos SIP) es la parte
# principal de ZetronPOC: NO lo uses salteando telefonia a menos que sepas por que.

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
# Reparar estado apt roto de runs anteriores. Un run viejo pudo instalar las
# variantes -gnome de NetworkManager (network-manager-*-gnome -> libnma0 ->
# libgtk-3-0t64). En Pi OS con bookworm+rpi mezclado con trixie, libgtk-3-0t64
# choca por archivos con libgtk-3-0 (rpi) y dpkg no lo instala -> apt queda
# roto y aborta TODO. apt-get -f install NO lo resuelve (intenta instalar
# libgtk-3-0t64 y pega con el conflicto). Hay que SACAR a la fuerza los -gnome
# + libnma0 (applets de escritorio, inutiles en headless); la VPN cliente
# sigue con network-manager-openvpn/pptp (sin -gnome). Despues -f install limpia.
dpkg --remove --force-all \
  network-manager-openvpn-gnome network-manager-pptp-gnome \
  network-manager-l2tp-gnome libnma0 2>/dev/null || true
apt-get -f install -y 2>&1 || warn "apt-get -f install no pudo resolver todo (continuando)."
if [[ $UPDATE -eq 0 ]]; then
  apt-get update -y
  apt-get install -y sqlite3 python3 python3-pip alsa-utils sox git curl ca-certificates \
    logrotate espeak gpiod 2>&1 || { err "Fallo instalacion de paquetes base."; exit 1; }
  # asterisk y libgpiod2 por separado: en algunos repos (Raspberry Pi OS) pueden
  # no estar en el mirror activo. Si fallan, no abortan todo el instalador.
  # --no-asterisk: saltear (Asterisk fue eliminado de Debian, compilar tarda mucho).
  if [[ $NO_ASTERISK -eq 0 ]]; then
    apt-get install -y asterisk 2>&1 || warn "asterisk no encontrado en el repo. Compilarlo con instalar_asterisk.sh despues."
    apt-get install -y libgpiod2 2>&1 || warn "libgpiod2 no encontrado (gpiod ya instala gpioset; el PTT igual funciona)"
  else
    log "--no-asterisk: salteando apt-get install asterisk (modo emergencia)."
  fi
else
  # En --update solo asegurar lo critico que pudo ser purgado (ej: asterisk)
  if [[ $NO_ASTERISK -eq 0 ]]; then
    command -v asterisk >/dev/null 2>&1 || apt-get install -y asterisk 2>&1 || warn "No se pudo reinstalar asterisk"
  fi
fi
command -v espeak >/dev/null 2>&1 || apt-get install -y espeak sox 2>&1 || true
pip3 install --break-system-packages openpyxl xlrd 2>&1 || warn "openpyxl/xlrd no instalados (import Excel limitado a CSV)"

# VPN: NetworkManager (cliente OpenVPN/L2TP/PPTP) + servidores OpenVPN/PPTP/L2TP
echo "==> 1b/10 Dependencias VPN (NetworkManager + openvpn/pptpd/strongswan/xl2tpd)..."
# Sin las variantes -gnome: solo agregan applets GTK (libnma0 -> libgtk-3-0t64)
# y en un server headless no se usan; ademas libgtk-3-0t64 rompe apt en Pi OS Trixie.
apt-get install -y network-manager network-manager-openvpn \
  network-manager-pptp \
  openvpn pptpd strongswan xl2tpd wireguard wireguard-tools 2>&1 || warn "Algunos paquetes VPN no pudieron instalarse (verifique repos universe habilitado)"
# network-manager-l2tp suele estar en PPA, no en repos base de Ubuntu; intentar igual
apt-get install -y network-manager-l2tp 2>&1 || warn "network-manager-l2tp no esta en el repo base (si usa L2TP cliente, instalelo via PPA: add-apt-repository ppa:nm-l2tp/network-manager-l2tp)"
systemctl enable --now NetworkManager 2>/dev/null || true
echo "  Estado NetworkManager:"; systemctl is-active NetworkManager 2>/dev/null || true
# strongswan y xl2tpd auto-arrancan al instalarse (apt los habilita por defecto).
# Solo deben iniciar cuando el admin configura el servidor L2TP entrante desde
# el panel. Los deshabilitamos aqui para que no queden "active" sin razon.
systemctl disable --now strongswan-starter 2>/dev/null || true
systemctl disable --now strongswan 2>/dev/null || true
systemctl disable --now xl2tpd 2>/dev/null || true

# Si las placas estan unmanaged, NetworkManager no puede enrutar la VPN
# ("could not find source connection"). Migrar netplan al renderer NetworkManager
# para que NM gestione la red base. Hace backup de los .yaml originales.
if nmcli device status 2>/dev/null | grep -qi unmanaged; then
  echo "==> 1c/10 Migrando red a NetworkManager (placas unmanaged)..."
  NP_DIR="/etc/netplan"
  if ls "${NP_DIR}"/*.yaml >/dev/null 2>&1; then
    for f in "${NP_DIR}"/*.yaml; do [[ -f "$f.zetronpoc.bak" ]] || cp -a "$f" "$f.zetronpoc.bak"; done
    if grep -rqE "renderer:\s*(networkd|NetworkManager)" "${NP_DIR}"/*.yaml; then
      sed -i -E 's/renderer:[[:space:]]*networkd/renderer: NetworkManager/g' "${NP_DIR}"/*.yaml
    else
      cat > "${NP_DIR}/99-zetronpoc-nm.yaml" <<'EOF'
network:
  version: 2
  renderer: NetworkManager
EOF
    fi
    netplan apply 2>/dev/null || warn "netplan apply fallo (verifique configuracion de red)"
    sleep 4
    echo "  Estado de placas tras migrar:"; nmcli device status 2>/dev/null || true
  else
    warn "No se encontro netplan en ${NP_DIR}; NetworkManager queda sin gestionar la red base (VPN cliente no conectara). Migre la red a NM a mano."
  fi
fi

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
dl "${SRC}/backend/vpn.py" "${APP_DIR}/backend/vpn.py"
chmod +x "${APP_DIR}/backend/vpn.py"
dl "${SRC}/frontend/admin.html" "${APP_DIR}/frontend/admin.html"
dl "${SRC}/frontend/public.html" "${APP_DIR}/frontend/public.html"

dl "${SRC}/database/db_manager.py" "${APP_DIR}/database/db_manager.py"
chmod +x "${APP_DIR}/database/db_manager.py"
dl "${SRC}/database/schema.sql" "${APP_DIR}/database/schema.sql"
dl "${SRC}/database/seed.sql" "${APP_DIR}/database/seed.sql"

dl "${SRC}/agi/pocsag_handler.py" "${APP_DIR}/agi/pocsag_handler.py"
dl "${SRC}/agi/pocsag_check.py" "${APP_DIR}/agi/pocsag_check.py"
dl "${SRC}/agi/cola_worker.py" "${APP_DIR}/agi/cola_worker.py"
dl "${SRC}/agi/dispatch_mqtt.py" "${APP_DIR}/agi/dispatch_mqtt.py"
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
if [[ $NO_ASTERISK -eq 1 ]]; then
  echo "==> 4/10 Asterisk: OMITIDO (--no-asterisk). Paging por panel web + MMDVM."
else
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
fi

# ============================ 5. BASE DE DATOS ==============================
echo "==> 5/10 Inicializando base de datos..."
if [[ $UPDATE -eq 0 ]] || [[ ! -f "${DB}" ]]; then
  python3 "${APP_DIR}/database/db_manager.py" init || warn "db init fallo (se reintentara en firstboot si hace falta)"
fi
python3 - <<PYEOF
import sqlite3
try:
    c = sqlite3.connect('${DB}')
    c.execute("INSERT OR REPLACE INTO config(clave,valor) VALUES('version','${VERSION}')")
    c.commit(); c.close()
except Exception as e:
    print("[WARN] no se pudo setear version: %s" % e)
PYEOF
chmod 640 "${DB}" 2>/dev/null || true
chown "${AST_USER}:${AST_USER}" "${DB}" 2>/dev/null || true

# Seed demo data so Dashboard/Historial/Logs/Auditoria show content on a fresh install
python3 - <<'PYEOF'
import sqlite3, datetime
DB='/opt/zetronpoc/database/zetronpoc.db'
try:
    c=sqlite3.connect(DB)
    n=c.execute("SELECT COUNT(*) FROM bitacora").fetchone()[0]
    if n==0:
        now=datetime.datetime.now()
        for i in range(6):
            ts=(now-datetime.timedelta(days=i, hours=i)).strftime("%Y-%m-%d %H:%M:%S")
            est='enviado' if i%3==0 else ('encolado' if i%3==1 else 'error')
            c.execute("INSERT INTO bitacora (fecha_hora,interno_origen,codigo,cap_code,mensaje,baudios,estado,observaciones,cola_id) VALUES (?,?,?,?,?,?,?,?,?)",
                (ts,'200'+str(i%3),'TEST0'+str(i+1),'1234567','Mensaje de prueba '+str(i+1),512,est,'',None))
        c.commit(); print("[seed] 6 mensajes demo en bitacora")
    nl=c.execute("SELECT COUNT(*) FROM logs").fetchone()[0]
    if nl==0:
        now=datetime.datetime.now()
        for i in range(8):
            ts=(now-datetime.timedelta(hours=i)).strftime("%Y-%m-%d %H:%M:%S")
            nivel=['info','info','warn','error'][i%4]
            orig=['api','cola','mmdvm','pbx'][i%4]
            c.execute("INSERT INTO logs (fecha_hora,nivel,origen,mensaje) VALUES (?,?,?,?)",
                (ts,nivel,orig,'Evento de demostracion #%d'%i))
        c.commit(); print("[seed] 8 logs demo")
    na=c.execute("SELECT COUNT(*) FROM auditoria").fetchone()[0]
    if na==0:
        now=datetime.datetime.now()
        for i in range(4):
            ts=(now-datetime.timedelta(hours=i)).strftime("%Y-%m-%d %H:%M:%S")
            c.execute("INSERT INTO auditoria (fecha_hora,usuario,accion,entidad,entidad_id,detalle,ip) VALUES (?,?,?,?,?,?,?)",
                (ts,'admin',['login','guardar','aplicar','enviar'][i%4],['auth','config','mmdvm','mensaje'][i%4],'','demo','127.0.0.1'))
        c.commit(); print("[seed] 4 auditoria demo")
    c.close()
except Exception as e:
    print("[seed] WARN: %s" % e)
PYEOF

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
if [[ $NO_ASTERISK -eq 1 ]]; then
  echo "==> 7/10 Locuciones IVR: OMITIDAS (--no-asterisk)."
elif [[ $UPDATE -eq 0 ]]; then
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
systemctl daemon-reload 2>/dev/null || true
if [[ $NO_ASTERISK -eq 1 ]]; then
  log "--no-asterisk: salteando enable/reload de Asterisk."
else
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
fi
systemctl enable zetronpoc-api 2>/dev/null || true
systemctl enable zetronpoc-cola 2>/dev/null || true
# Forzar reinicio SIEMPRE para cargar codigo nuevo (enable --now no reinicia un servicio ya activo)
systemctl restart zetronpoc-api 2>/dev/null || warn "No se pudo reiniciar zetronpoc-api"
systemctl restart zetronpoc-cola 2>/dev/null || true
# Regenerar MMDVM.ini desde la BD y reiniciar mmdvmhost si esta instalado
# (instalacion y --update): sin esto, los cambios del panel nunca llegan al aire.
if command -v MMDVM-Host >/dev/null 2>&1 || [[ -x /usr/local/bin/MMDVM-Host ]] || systemctl is-active --quiet mmdvmhost 2>/dev/null; then
  echo "==> Regenerando MMDVM.ini y reiniciando mmdvmhost..."
  python3 - <<'PYEOF' 2>/dev/null || warn "No se pudo regenerar MMDVM.ini"
import sys, os
sys.path.insert(0, "/opt/zetronpoc"); sys.path.insert(0, "/opt/zetronpoc/database")
os.environ["ZETRONPOC_DIR"] = "/opt/zetronpoc"
try:
    from db_manager import generar_mmdvm_ini
    ok, msg = generar_mmdvm_ini()
    print("[OK] MMDVM.ini" if ok else "[WARN] %s" % msg)
except Exception as e:
    print("[WARN] %s" % e)
PYEOF
  # Refrescar el mmdvmhost.service desde el repo para evitar un service stale
  # (un service viejo sin [RemoteControl] hace que MQTT conecte pero los pages
  #  no se procesen -> el bug del "OK 1/1 pero no suena el pager").
  if curl -fsSL "${SRC}/services/mmdvmhost.service" -o /etc/systemd/system/mmdvmhost.service 2>/dev/null; then
    systemctl daemon-reload 2>/dev/null || true
  fi
  systemctl restart mmdvmhost 2>/dev/null && log "mmdvmhost reiniciado (service + .ini refrescados)" || warn "mmdvmhost no reinicio (¿instalado?)"
fi
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