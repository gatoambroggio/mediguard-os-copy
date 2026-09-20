#!/usr/bin/env bash
# ============================================================================
# diagnostico_placa.sh — Diagnóstico completo del MMDVM / Jumbospot
# ============================================================================
# Verifica:
#   1. Servicio MMDVMHost (corriendo, logs)
#   2. Puerto serial del módulo (detección automática)
#   3. Versión del firmware del MMDVM (¿es el nuestro?)
#   4. Si la placa acepta 149.255 MHz (ACK o NAK reason 4)
#   5. Configuración de MMDVM.ini (freq, puerto, POCSAG)
#   6. Test de TX POCSAG en vivo (¿prende PTT?)
#
# Uso:  sudo ./diagnostico_placa.sh
# ============================================================================
set -uo pipefail

# Colores
R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
C='\033[0;36m'
B='\033[1m'
N='\033[0m'

ok()   { echo -e "  ${G}✓${N} $1"; }
fail() { echo -e "  ${R}✗${N} $1"; }
warn() { echo -e "  ${Y}!${N} $1"; }
hdr()  { echo -e "\n${C}${B}━━━ $1 ━━━${N}"; }

echo -e "${B}${C}╔══════════════════════════════════════════════╗${N}"
echo -e "${B}${C}║  Diagnóstico MMDVM / Jumbospot — MediGuard   ║${N}"
echo -e "${B}${C}╚══════════════════════════════════════════════╝${N}"

if [ "$(id -u)" -ne 0 ]; then
  fail "Necesita root: sudo ./diagnostico_placa.sh"
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Servicio MMDVMHost
# ---------------------------------------------------------------------------
hdr "1. Servicio MMDVMHost"

if systemctl is-active --quiet mmdvmhost 2>/dev/null; then
  ok "MMDVMHost está corriendo"
else
  fail "MMDVMHost NO está corriendo"
  echo -e "    ${Y}Iniciando...${N}"
  systemctl start mmdvmhost 2>/dev/null || warn "No se pudo iniciar automáticamente"
fi

echo -e "\n  ${B}Últimas 15 líneas del log:${N}"
journalctl -u mmdvmhost -n 15 --no-pager 2>/dev/null | sed 's/^/    /' || warn "No hay logs"

# ---------------------------------------------------------------------------
# 2. Puerto serial
# ---------------------------------------------------------------------------
hdr "2. Puerto serial del módulo MMDVM"

INI="/opt/zetronpoc/MMDVM.ini"
if [ ! -f "$INI" ]; then
  INI=$(find /opt/zetronpoc /etc /home -name "MMDVM.ini" 2>/dev/null | head -1)
fi

CONFIG_PORT=""
if [ -n "$INI" ] && [ -f "$INI" ]; then
  CONFIG_PORT=$(grep -i "Port=" "$INI" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' ')
fi
echo -e "  Puerto configurado en MMDVM.ini: ${B}${CONFIG_PORT:-no encontrado}${N}"

echo -e "\n  ${B}Dispositivos seriales disponibles:${N}"
ls -la /dev/ttyAMA* /dev/ttyUSB* /dev/ttyS* /dev/serial/by-id/* 2>/dev/null | sed 's/^/    /' || warn "Ninguno"

echo -e "\n  ${B}Detección automática del MMDVM:${N}"
if [ -f "/opt/zetronpoc/scripts/mmdvm_detect_port.py" ]; then
  DETECTED=$(python3 /opt/zetronpoc/scripts/mmdvm_detect_port.py 2>/dev/null || echo "")
  if [ -n "$DETECTED" ]; then
    ok "Módulo detectado en: $DETECTED"
  else
    fail "No se detectó ningún módulo MMDVM respondiendo"
  fi
else
  warn "mmdvm_detect_port.py no encontrado, probando puertos manualmente..."
  for port in /dev/ttyAMA0 /dev/ttyUSB0 /dev/ttyS0 /dev/ttyUSB1; do
    if [ -e "$port" ]; then
      echo -e "    Probando ${port}..."
      python3 -c "
import serial, time, sys
try:
    s = serial.Serial('$port', 115200, timeout=1)
    s.write(bytes([0x01, 0x00, 0x01]))
    time.sleep(0.3)
    r = s.read(64)
    s.close()
    if r:
        print('    RESPONDE: ' + r.hex())
        sys.exit(0)
except:
    pass
sys.exit(1)
" 2>/dev/null && ok "$port responde" || warn "$port no responde"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 3. Versión del firmware
# ---------------------------------------------------------------------------
hdr "3. Versión del firmware MMDVM"

# Determinar el puerto a usar
PORT="${DETECTED:-${CONFIG_PORT:-/dev/ttyAMA0}}"
if [ ! -e "$PORT" ]; then
  for p in /dev/ttyAMA0 /dev/ttyUSB0 /dev/ttyS0; do
    [ -e "$p" ] && PORT="$p" && break
  done
fi

echo -e "  Usando puerto: ${B}${PORT}${N}"

python3 << PYEOF
import serial, time, sys

PORT = "$PORT"

try:
    s = serial.Serial(PORT, 115200, timeout=2)
except Exception as e:
    print("  ✗ No se pudo abrir %s: %s" % (PORT, e))
    sys.exit(1)

# GET_VERSION: 0x01, len=0x00, cmd=0x01
s.write(bytes([0x01, 0x00, 0x01]))
time.sleep(0.5)
resp = s.read(256)

if not resp:
    print("  ✗ El MMDVM no respondió al GET_VERSION")
    print("    Posibles causas:")
    print("    - Firmware no flasheado correctamente (placa en bootloader)")
    print("    - Puerto serial incorrecto")
    print("    - Baud rate incorrecto")
    s.close()
    sys.exit(1)

print("  Respuesta raw: %s" % resp.hex())

# Parse: 0x01 = GET_VERSION response, then len, then protocol_ver, then string
if resp[0] == 0x01:
    # Buscar el string de versión (ASCII printable)
    text = ""
    for b in resp[3:]:
        if 32 <= b < 127:
            text += chr(b)
        elif text:
            break
    print("  ✓ Versión del firmware: %s" % text)

    # Verificar flags importantes
    if "MMDVM_HS" in text or "MMDVM" in text:
        if "14.7456" in text or "14745600" in text:
            print("  ✓ TCXO 14.7456 MHz detectado en string de versión")
        elif "12.288" in text:
            print("  ⚠ TCXO 12.288 MHz detectado — el firmware usa el TCXO equivocado")
        else:
            print("  ! No se detectó TCXO en el string de versión")
    else:
        print("  ⚠ String de versión no reconocido como MMDVM_HS")
else:
    print("  ✗ Respuesta inesperada (byte 0: 0x%02X)" % resp[0])

s.close()
PYEOF

# Clasificar el tipo de placa segun el byte de protocolo de GET_VERSION:
#   1 = MMDVM_HS    -> hotspot con chip ADF7021 (RF propia)
#   2 = G4KLX MMDVM -> repetidora: modem que modula un radio externo
if [ -f "/opt/zetronpoc/scripts/mmdvm_detect_port.py" ]; then
  BOARD_INFO=$(python3 /opt/zetronpoc/scripts/mmdvm_detect_port.py "$PORT" 115200 --board 2>/dev/null || echo "")
  if [ -n "$BOARD_INFO" ]; then
    KIND=$(echo "$BOARD_INFO" | cut -f2)
    case "$KIND" in
      repeater)
        ok "Tipo de placa: REPETIDORA (radio externo, firmware G4KLX)"
        echo -e "    El RF lo genera el RADIO conectado; la frecuencia del .ini NO aplica."
        echo -e "    Config: Protocol=uart, UARTSpeed=460800 (firmware V3F4) o 115200 (viejo)."
        ;;
      hotspot)
        ok "Tipo de placa: HOTSPOT (ADF7021, RF propia)"
        ;;
      *)
        warn "Tipo de placa: no se pudo clasificar (proto=${KIND:-?})"
        ;;
    esac
  else
    warn "No se pudo leer el tipo de placa (modulo sin responder)"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Test de frecuencia 149.255 MHz
# ---------------------------------------------------------------------------
hdr "4. Test de frecuencia 149.255 MHz"

python3 << PYEOF
import serial, time, struct, sys

PORT = "$PORT"

try:
    s = serial.Serial(PORT, 115200, timeout=2)
except Exception as e:
    print("  ✗ No se pudo abrir %s: %s" % (PORT, e))
    sys.exit(1)

# Limpiar buffer
s.reset_input_buffer()
time.sleep(0.1)

# SET_FREQUENCY command
# Format: 0x02, len(8), freq(4 bytes LE), direction(1), offset(4 bytes LE, signed)
freq = 149255000
freq_bytes = struct.pack('<I', freq)
direction = 0  # 0 = simplex
offset = struct.pack('<i', 0)

cmd = bytes([0x02, 0x08]) + freq_bytes + bytes([direction]) + offset
print("  Enviando SET_FREQ: %s MHz" % (freq / 1e6))
print("  Comando: %s" % cmd.hex())

s.write(cmd)
time.sleep(0.5)
resp = s.read(64)

if not resp:
    print("  ✗ Sin respuesta al SET_FREQ")
    print("    El firmware puede haber crasheado o estar en bootloader")
    s.close()
    sys.exit(1)

print("  Respuesta: %s" % resp.hex())

if resp[0] == 0x00:
    print("  ✓✓✓ ACK — La placa ACEPTÓ 149.255 MHz! ✓✓✓")
    print("    El patch de VHF1_MAX (150 MHz) funciona correctamente.")
    print("    El problema de TX está en otro lado (ver pasos 5 y 6).")
elif resp[0] == 0xFF:
    reason = resp[1] if len(resp) > 1 else "?"
    print("  ✗✗✗ NAK reason %s — La placa RECHAZÓ 149.255 MHz ✗✗✗" % reason)
    if reason == 4:
        print("    Reason 4 = frecuencia fuera de rango válido")
        print("    El patch de VHF1_MAX NO está aplicado en el firmware flasheado.")
        print("    Solución: re-flashear el firmware_pocsag512_149mhz.bin más reciente")
        print("    (el que se compiló con 'make hs', no 'make bl')")
        print()
        print("    Verificar el binario descargado:")
        print("      ls -la firmware_pocsag512_149mhz.bin")
        print("      # debe ser ~52KB (make hs standalone)")
        print("      # si es ~68KB, es el binario viejo de 'make bl'")
    else:
        print("    Reason %s — revisar documentación MMDVM" % reason)
else:
    print("  ✗ Respuesta inesperada: 0x%02X" % resp[0])

s.close()
PYEOF

# ---------------------------------------------------------------------------
# 5. Configuración MMDVM.ini
# ---------------------------------------------------------------------------
hdr "5. Configuración MMDVM.ini"

if [ -n "$INI" ] && [ -f "$INI" ]; then
  echo -e "  Archivo: ${B}${INI}${N}\n"

  echo -e "  ${B}[General]${N}"
  grep -iE "^(Callsign|Id|Timeout|Duplex|RFLevel|TXLevel|RXLevel)" "$INI" 2>/dev/null | sed 's/^/    /' || warn "Sección [General] no encontrada"

  echo -e "\n  ${B}[MMDVM]${N}"
  grep -iE "^(Port|TXInvert|RXInvert|PTT|DStar|DMR|YSF|P25|NXDN|M17|POCSAG|FM)" "$INI" 2>/dev/null | sed 's/^/    /' || warn "Sección [MMDVM] no encontrada"

  echo -e "\n  ${B}[POCSAG]${N}"
  grep -A20 "\[POCSAG\]" "$INI" 2>/dev/null | sed 's/^/    /' || warn "Sección [POCSAG] no encontrada"

  echo -e "\n  ${B}[Info]${N}"
  grep -iE "^(Frequency|Latitude|Longitude)" "$INI" 2>/dev/null | sed 's/^/    /' || warn "Sección [Info] no encontrada"

  # Verificar frecuencia
  FREQ_INI=$(grep -i "Frequency=" "$INI" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' ')
  if [ -n "$FREQ_INI" ]; then
    echo ""
    if echo "$FREQ_INI" | grep -qi "149"; then
      ok "Frecuencia en .ini: $FREQ_INI MHz"
    else
      warn "Frecuencia en .ini: $FREQ_INI MHz — ¿debería ser 149.255?"
      echo -e "    Para cambiarla desde el panel admin o:"
      echo -e "    sudo sqlite3 /opt/zetronpoc/database/zetronpoc.db \\"
      echo -e "      \"UPDATE config SET value='149.255000' WHERE key='frequency'\""
      echo -e "    sudo systemctl restart mmdvmhost"
    fi
  fi
else
  fail "No se encontró MMDVM.ini"
fi

# ---------------------------------------------------------------------------
# 6. Resumen y próximos pasos
# ---------------------------------------------------------------------------
hdr "6. Resumen y diagnóstico"

echo ""
echo -e "  ${B}Para ver logs en vivo mientras envías un page:${N}"
echo -e "    ${C}sudo journalctl -u mmdvmhost -f${N}"
echo ""
echo -e "  ${B}Si la placa respondió NAK reason 4 en el paso 4:${N}"
echo -e "    El firmware flasheado no tiene el patch de 149.255 MHz."
echo -e "    Re-descargar y re-flashear:"
echo -e "    ${C}wget https://github.com/gatoambroggio/mediguard-os-copy/releases/download/pocsag512-149mhz-latest/firmware_pocsag512_149mhz.bin${N}"
echo -e "    ${C}sudo ./flash.sh firmware_pocsag512_149mhz.bin${N}"
echo ""
echo -e "  ${B}Si la placa respondió ACK en el paso 4 pero no hay TX:${N}"
echo -e "    El problema está en MMDVMHost o la configuración POCSAG."
echo -e "    Verificar que POCSAG=1 en MMDVM.ini y que el page se está enviando"
echo -e "    por el canal correcto (API → MMDVMHost)."
echo -e "    ${C}sudo journalctl -u mmdvmhost -f${N}  # y enviar un page de prueba"
echo ""
echo -e "  ${B}Si la placa es una REPETIDORA (radio externo):${N}"
echo -e "    El test de frecuencia del paso 4 no aplica: el RF lo fija el radio."
echo -e "    Verificá: cable PTT/COS/audio conectado, radio programado a la"
echo -e "    frecuencia de paginación, y UARTSpeed del .ini acorde al firmware."
echo -e "    Test en vivo: desde el panel admin (Diagnóstico → Test page)."
echo ""