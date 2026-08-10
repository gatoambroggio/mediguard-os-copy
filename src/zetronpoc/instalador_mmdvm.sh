#!/usr/bin/env bash
# ============================================================================
# instalador_mmdvm.sh - Instala MMDVMHost (G4KLX) + mosquitto y deja el
# MMDVM.ini COMPLETO (con [MQTT] y [RemoteControl] habilitados) en la misma
# ruta que usa el panel admin: /opt/zetronpoc/mmdvm/MMDVM.ini
#
# Sin esto, una instalacion fresca de MMDVM deja el modulo sin escuchar MQTT
# ni RemoteControl -> dispatch_mqtt publica al vacio y el pager nunca suena.
# ============================================================================
set -euo pipefail

APP_DIR="/opt/zetronpoc"
MMDVM_DIR="${APP_DIR}/mmdvm"
INI="${MMDVM_DIR}/MMDVM.ini"
BIN="/usr/local/bin/MMDVM-Host"
SVC="/etc/systemd/system/mmdvmhost.service"
CALLSIGN="${MMDVM_CALLSIGN:-LU1ABC}"
PORT="${MMDVM_PORT:-/dev/ttyUSB0}"
BAUD="${MMDVM_BAUD:-115200}"
FREQ="${MMDVM_FREQ:-433800000}"

G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; NC="\033[0m"
log(){ echo -e "${G}[OK]${NC}   $*"; }
warn(){ echo -e "${Y}[WARN]${NC} $*"; }
err(){ echo -e "${R}[ERR]${NC}  $*" >&2; }

[[ $EUID -ne 0 ]] && { err "Ejecuta como root o con sudo."; exit 1; }

echo "==> 1/6 Dependencias (build + mosquitto)..."
apt-get update -y
apt-get install -y git g++ make wget curl mosquitto mosquitto-clients \
  libssl-dev systemd 2>&1 || { err "Fallo instalacion de paquetes."; exit 1; }
systemctl enable --now mosquitto 2>/dev/null || true

echo "==> 2/6 Compilando MMDVMHost (G4KLX)..."
if [[ -x "$BIN" ]]; then
  log "MMDVMHost ya compilado en $BIN (omitir build)."
else
  TMP="$(mktemp -d)"
  git clone --depth 1 https://github.com/g4klx/MMDVMHost.git "$TMP/MMDVMHost" 2>&1 || { err "No se pudo clonar MMDVMHost"; exit 1; }
  ( cd "$TMP/MMDVMHost" && make -j2 2>&1 ) || { err "Fallo la compilacion."; exit 1; }
  install -m 0755 "$TMP/MMDVMHost/MMDVMHost" "$BIN"
  rm -rf "$TMP"
  log "MMDVMHost compilado e instalado en $BIN."
fi

echo "==> 3/6 Escribiendo MMDVM.ini completo en ${INI}..."
mkdir -p "$MMDVM_DIR" /var/log/mmdvm
cat > "$INI" <<EOF
# MMDVM.ini - generado por instalador_mmdvm.sh (ZetronPOC / MediGuard OS)
# El panel admin regenera este archivo desde la BD (db_manager.generar_mmdvm_ini);
# ambas rutas coinciden, por eso "Aplicar a la placa MMDVM" siempre toca el .ini vivo.

[General]
Callsign=${CALLSIGN}
Id=${CALLSIGN// /}000
Timeout=180
Duplex=0
RFModeHang=10
DMR=0
DSTAR=0
YSF=0
P25=0
NXDN=0
POCSAG=1
Display=None

[Modem]
Port=${PORT}
Protocol=uart
UARTPort=${PORT}
UARTSpeed=${BAUD}
RXFrequency=${FREQ}
TXFrequency=${FREQ}
TXInvert=1
RXInvert=0
PTTInvert=1
TXDelay=500
RXOffset=0
TXOffset=0
DMRDelay=0
RXLevel=50
TXLevel=50
RXDCOffset=0
TXDCOffset=0
RFLevel=100
RSSIMappingFile=RSSI.dat
UseCOSAsLockout=0
Trace=0
Debug=0
OscillatorSpeed=14745600

[POCSAG]
Enable=1

[MQTT]
Enable=1
Host=127.0.0.1
Port=1883
Name=host

[RemoteControl]
Enable=1
Port=7642

[DAPNET]
Enable=0
Address=
Passcode=

[Info]
Enabled=0

[Log]
DisplayLevel=1
FileLevel=1
FilePath=/var/log/mmdvm
FileRoot=MMDVM
EOF
# RSSI.dat vacio para evitar el error de startup
[[ -f "$MMDVM_DIR/RSSI.dat" ]] || touch "$MMDVM_DIR/RSSI.dat"
log "MMDVM.ini escrito con [MQTT] y [RemoteControl] habilitados."

echo "==> 4/6 Servicio systemd mmdvmhost..."
cat > "$SVC" <<EOF
[Unit]
Description=MMDVMHost (POCSAG via MQTT/RemoteControl)
After=network.target mosquitto.service
Wants=mosquitto.service

[Service]
Type=simple
ExecStart=${BIN} ${INI}
Restart=always
RestartSec=5
StandardOutput=append:/var/log/mmdvm/mmdvmhost.out.log
StandardError=append:/var/log/mmdvm/mmdvmhost.err.log

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
log "Servicio mmdvmhost creado apuntando a ${INI}."

echo "==> 5/6 Reiniciando servicios..."
systemctl enable mmdvmhost 2>/dev/null || true
systemctl restart mmdvmhost 2>/dev/null && log "mmdvmhost reiniciado" || warn "mmdvmhost no pudo reiniciar"
# Reiniciar cola para que reconecte al broker
systemctl restart zetronpoc-cola 2>/dev/null || true
systemctl restart zetronpoc-api 2>/dev/null || true

echo "==> 6/6 Chequeo..."
sleep 2
if systemctl is-active --quiet mmdvmhost; then
  log "mmdvmhost ACTIVO leyendo ${INI}"
else
  warn "mmdvmhost no activo. Ver: journalctl -u mmdvmhost -n 50"
fi
if systemctl is-active --quiet mosquitto; then
  log "mosquitto ACTIVO (dispatch_mqtt publica a host/command)"
else
  warn "mosquitto no activo. Ver: systemctl status mosquitto"
fi

echo "--------------------------------------------"
log "MMDVM instalado."
echo "  .ini       : ${INI}"
echo "  broker     : 127.0.0.1:1883 (topic host/command <- dispatch)"
echo "  remote ctl : 127.0.0.1:7642"
echo ""
echo "  Proximo paso: desde el panel admin -> Parametros -> MMDVM ->"
echo "  cargar Callsign/Puerto/Frecuencia reales y pulsar 'Aplicar a la placa MMDVM'."
echo ""