#!/usr/bin/env bash
# ============================================================================
# diagnostico_placa.sh — Diagnóstico del MMDVM / Jumbospot (MediGuard OS)
# ============================================================================
# Prueba la placa de punta a punta SIN dependencias extra: el acceso serie va
# por termios (igual que mmdvm_detect_port.py), así no hace falta python3-serial.
#
# Verifica:
#   1. Servicio MMDVMHost (estado + últimas líneas del log)
#   2. Puertos serie presentes y puerto detectado por handshake
#   3. Versión de firmware completa y tipo de placa (hotspot / repetidora)
#   4. Test de frecuencia (solo hotspot): ACK o NAK con su motivo
#   5. Paridad del MMDVM.ini (incluye [MQTT] Port y [Remote Control] Port)
#
# Protocolo MMDVM: frame = 0xE0 <len> <cmd> <data...> <crc_hi> <crc_lo>,
# donde <len> cuenta cmd + data + los 2 bytes de CRC.
#
# Uso:  sudo ./diagnostico_placa.sh [puerto]
# ============================================================================
set -uo pipefail

APP_DIR="${ZETRONPOC_DIR:-/opt/zetronpoc}"
INI="${APP_DIR}/mmdvm/MMDVM.ini"
DETECTOR="${APP_DIR}/scripts/mmdvm_detect_port.py"
FREQ_HZ=149255000

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
ok(){   echo -e "  ${G}✓${N} $1"; }
fail(){ echo -e "  ${R}✗${N} $1"; }
warn(){ echo -e "  ${Y}!${N} $1"; }
hdr(){  echo -e "\n${C}${B}━━━ $1 ━━━${N}"; }

echo -e "${B}${C}╔══════════════════════════════════════════════╗${N}"
echo -e "${B}${C}║  Diagnóstico MMDVM / Jumbospot — MediGuard   ║${N}"
echo -e "${B}${C}╚══════════════════════════════════════════════╝${N}"

if [ "$(id -u)" -ne 0 ]; then
  fail "Necesita root: sudo ./diagnostico_placa.sh"
  exit 1
fi

# ini_get <seccion> <clave> -> valor de la clave dentro de esa seccion del .ini
ini_get(){
  awk -v sec="$1" -v key="$2" '
    /^\[/ { f = (tolower($0) == "[" tolower(sec) "]") ? 1 : 0; next }
    f && $0 ~ "=" {
      k = tolower($1); gsub(/[[:space:]]/, "", k)
      if (k == tolower(key)) { v = $2; gsub(/[[:space:]]/, "", v); print v; exit }
    }
  ' "$INI" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 1. Servicio MMDVMHost
# ---------------------------------------------------------------------------
hdr "1. Servicio MMDVMHost"

if systemctl is-active --quiet mmdvmhost 2>/dev/null; then
  ok "MMDVMHost está corriendo"
else
  fail "MMDVMHost NO está corriendo"
  systemctl start mmdvmhost 2>/dev/null || warn "No se pudo iniciar automáticamente"
fi

echo -e "\n  ${B}Últimas 15 líneas del log:${N}"
journalctl -u mmdvmhost -n 15 --no-pager 2>/dev/null | sed 's/^/    /' || warn "No hay logs en journalctl"

# ---------------------------------------------------------------------------
# 2. Puerto serie
# ---------------------------------------------------------------------------
hdr "2. Puerto serial del módulo MMDVM"

if [ ! -f "$INI" ]; then
  INI_ALT="$(find "$APP_DIR" /etc -name "MMDVM.ini" 2>/dev/null | head -1)"
  [ -n "$INI_ALT" ] && INI="$INI_ALT"
fi
[ -f "$INI" ] && echo -e "  .ini en uso: ${B}${INI}${N}" || warn "No se encontró MMDVM.ini"

INI_PORT="$(ini_get Modem UARTPort)"; INI_PORT="${INI_PORT:-$(ini_get Modem Port)}"
INI_BAUD="$(ini_get Modem UARTSpeed)"; INI_BAUD="${INI_BAUD:-115200}"
echo -e "  Puerto en .ini: ${B}${INI_PORT:-no definido}${N}   UART speed: ${B}${INI_BAUD}${N}"

echo -e "\n  ${B}Dispositivos seriales disponibles:${N}"
ls -la /dev/ttyAMA* /dev/ttyUSB* /dev/ttyS* /dev/serial/by-id/* 2>/dev/null | sed 's/^/    /' || warn "Ninguno"

PORT="${1:-}"
if [ -z "$PORT" ]; then
  echo -e "\n  ${B}Detección automática por handshake:${N}"
  if [ -x "$DETECTOR" ]; then
    PORT="$(python3 "$DETECTOR" 2>/dev/null || true)"
  fi
  if [ -z "$PORT" ] && [ -n "$INI_PORT" ] && [ -e "$INI_PORT" ]; then
    PORT="$INI_PORT"; warn "sin handshake; usando el puerto del .ini (${PORT})"
  fi
  if [ -z "$PORT" ]; then
    for p in /dev/ttyAMA0 /dev/ttyUSB0 /dev/ttyS0; do
      [ -e "$p" ] && PORT="$p" && break
    done
  fi
fi

if [ -n "$PORT" ] && [ -e "$PORT" ]; then
  ok "Usando puerto: ${PORT}"
else
  fail "No hay ningún puerto serie utilizable (¿módulo conectado?)"
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Firmware y tipo de placa  ·  4. Test de frecuencia
# ---------------------------------------------------------------------------
KIND_FILE="$(mktemp)"
trap 'rm -f "$KIND_FILE"' EXIT

python3 - "$PORT" "$INI_BAUD" "$KIND_FILE" "$FREQ_HZ" <<'PYEOF'
import os, sys, time, termios, fcntl, struct

PORT      = sys.argv[1]
BAUD      = int(sys.argv[2]) if sys.argv[2].isdigit() else 115200
KIND_FILE = sys.argv[3]
FREQ_HZ   = int(sys.argv[4])

FRAME_START     = 0xE0
CMD_GET_VERSION = 0x00
CMD_SET_FREQ    = 0x02
CMD_ACK         = 0x00
CMD_NAK         = 0x04

BAUD_CONST = {9600: termios.B9600, 19200: termios.B19200, 38400: termios.B38400,
              57600: termios.B57600, 115200: termios.B115200,
              230400: termios.B230400, 460800: termios.B460800}


def crc16(data):
    """CRC-CCITT (XModem): poly 0x1021, init 0xFFFF. Es el CRC de los frames MMDVM."""
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def build(cmd, data=b""):
    """Frame MMDVM: 0xE0 <len> <cmd> <data...> <crc_hi> <crc_lo>."""
    body = bytes([cmd]) + data
    frame = bytes([FRAME_START, len(body) + 2]) + body
    c = crc16(frame)
    return frame + bytes([(c >> 8) & 0xFF, c & 0xFF])


def open_port(port, baud, timeout=1.5):
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NDELAY)
    fcntl.fcntl(fd, fcntl.F_SETFL, 0)
    a = termios.tcgetattr(fd)
    sp = BAUD_CONST.get(baud, termios.B115200)
    a[4] = sp; a[5] = sp
    a[2] = (a[2] & ~termios.CSIZE) | termios.CS8
    a[2] &= ~(termios.PARENB | termios.CSTOPB | termios.CRTSCTS)
    a[2] |= termios.CLOCAL | termios.CREAD
    a[3] = 0; a[0] = 0; a[1] = 0
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = max(1, int(timeout * 10))
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def read_frame(fd, timeout=2.0):
    """Lee un frame MMDVM completo respetando el campo <len> (no corta la version)."""
    deadline = time.time() + timeout
    buf = b""
    while time.time() < deadline:
        try:
            r = os.read(fd, 256)
        except OSError:
            break
        if r:
            buf += r
            i = buf.find(bytes([FRAME_START]))
            if i >= 0 and len(buf) >= i + 2:
                total = 2 + buf[i + 1]
                if len(buf) >= i + total:
                    return buf[i:i + total]
        time.sleep(0.05)
    return None


# ---- abrir el puerto probando el baud del .ini y los dos tipicos ----
bauds = [BAUD] + [b for b in (115200, 460800) if b != BAUD]
opened = None
for b in bauds:
    try:
        fd = open_port(PORT, b)
    except OSError as e:
        print("  \033[0;31m✗\033[0m No se pudo abrir %s: %s" % (PORT, e))
        print("    Verifique que el servicio MMDVMHost esté detenido:")
        print("    sudo systemctl stop mmdvmhost")
        sys.exit(1)
    os.write(fd, build(CMD_GET_VERSION))
    time.sleep(0.3)
    fr = read_frame(fd, 2.0)
    if fr:
        opened = (b, fd, fr)
        break
    os.close(fd)

print("\n\033[0;36m\033[1m━━━ 3. Firmware y tipo de placa ━━━\033[0m")
if not opened:
    print("  \033[0;31m✗\033[0m El módulo no respondió al GET_VERSION en %s"
          % ", ".join(str(x) for x in bauds))
    print("    Posibles causas: firmware no flasheado (placa en bootloader),")
    print("    puerto equivocado, o baud rate distinto al esperado.")
    open(KIND_FILE, "w").write("desconocido")
    sys.exit(0)

baud, fd, fr = opened
print("  Baud de handshake: %d" % baud)
if baud != BAUD:
    print("  \033[1;33m!\033[0m El .ini dice %d pero la placa responde a %d — corregir UARTSpeed"
          % (BAUD, baud))

payload = fr[2:2 + fr[1]]
version = payload[2:-2].decode("ascii", "ignore").strip() if len(payload) >= 4 else ""
proto = payload[1] if len(payload) >= 2 else None
kind = "repeater" if proto == 2 else ("hotspot" if proto == 1 else "desconocido")
open(KIND_FILE, "w").write(kind)

print("  Versión de firmware: \033[1m%s\033[0m" % (version or "(sin descripción)"))
if kind == "repeater":
    print("  \033[0;32m✓\033[0m Tipo de placa: REPETIDORA (radio externo, firmware G4KLX)")
elif kind == "hotspot":
    print("  \033[0;32m✓\033[0m Tipo de placa: HOTSPOT (ADF7021, RF propia)")
else:
    print("  \033[1;33m!\033[0m Tipo de placa: no se pudo clasificar (proto=%s)" % proto)

if kind == "hotspot" and "512" not in version:
    print("  \033[1;33m!\033[0m El string no menciona 512: probablemente sea el firmware")
    print("    stock (no el custom de 512 baud). Si los pagers no decodifican,")
    print("    hay que flashear firmware_pocsag512_149mhz.bin.")

# ---- 4. Test de frecuencia ----
print("\n\033[0;36m\033[1m━━━ 4. Test de frecuencia %d Hz (%.3f MHz) ━━━\033[0m"
      % (FREQ_HZ, FREQ_HZ / 1e6))

if kind == "repeater":
    print("  \033[1;33m!\033[0m Omitido: es una REPETIDORA. El RF lo fija el RADIO externo,")
    print("    no la frecuencia del .ini. Verifique cable PTT/COS/audio, el radio")
    print("    programado a la frecuencia de paginación, y UARTSpeed=460800.")
else:
    # SET_FREQUENCY: cmd 0x02 + frecuencia LE(4) + dirección(1) + offset LE(4)
    req = build(CMD_SET_FREQ, struct.pack("<I", FREQ_HZ) + bytes([0]) + struct.pack("<i", 0))
    termios.tcflush(fd, termios.TCIOFLUSH)
    os.write(fd, req)
    time.sleep(0.4)
    fr2 = read_frame(fd, 2.0)
    if not fr2:
        print("  \033[0;31m✗\033[0m Sin respuesta al SET_FREQ.")
        print("    El firmware puede haber crasheado o estar en bootloader.")
    else:
        p2 = fr2[2:2 + fr2[1]]
        cmd = p2[0] if p2 else None
        if cmd == CMD_ACK:
            print("  \033[0;32m✓✓✓ ACK — la placa ACEPTÓ %.3f MHz\033[0m" % (FREQ_HZ / 1e6))
            print("    El rango VHF del firmware admite esta frecuencia.")
        elif cmd == CMD_NAK:
            reason = p2[1] if len(p2) > 1 else "?"
            print("  \033[0;31m✗ NAK reason %s — la placa RECHAZÓ %.3f MHz\033[0m"
                  % (reason, FREQ_HZ / 1e6))
            if reason == 4:
                print("    Reason 4 = frecuencia fuera del rango del firmware.")
                print("    El firmware flasheado no tiene el patch VHF hasta 150 MHz.")
            print("    Solución: flashear el firmware custom de 512 baud / 149 MHz:")
            print("      sudo ./flash.sh firmware_pocsag512_149mhz.bin")
        else:
            print("  \033[0;31m✗\033[0m Respuesta inesperada (cmd=0x%02X)" % (cmd or 0))
            print("    Frame: %s" % fr2.hex())

os.close(fd)
PYEOF

KIND="$(cat "$KIND_FILE" 2>/dev/null || echo desconocido)"

# ---------------------------------------------------------------------------
# 5. Paridad del MMDVM.ini
# ---------------------------------------------------------------------------
hdr "5. Paridad del MMDVM.ini"

if [ -f "$INI" ]; then
  INI_PORT2="$(ini_get Modem UARTPort)"; INI_PORT2="${INI_PORT2:-$(ini_get Modem Port)}"
  INI_SPEED="$(ini_get Modem UARTSpeed)"
  INI_DUPLEX="$(ini_get General Duplex)"
  INI_FREQ="$(ini_get Modem TXFrequency)"
  INI_POCSAG="$(ini_get General POCSAG)"
  INI_MQTT_PORT="$(ini_get MQTT Port)"
  INI_MQTT_EN="$(ini_get MQTT Enable)"
  INI_RC_PORT="$(ini_get "Remote Control" Port)"
  INI_RC_EN="$(ini_get "Remote Control" Enable)"

  echo -e "  ${B}[Modem]${N}         Port/UARTPort=${INI_PORT2:-?}  UARTSpeed=${INI_SPEED:-?}"
  echo -e "  ${B}[General]${N}       Duplex=${INI_DUPLEX:-?}  POCSAG=${INI_POCSAG:-?}"
  echo -e "  ${B}[Modem]${N}         TXFrequency=${INI_FREQ:-?}"
  echo -e "  ${B}[MQTT]${N}          Enable=${INI_MQTT_EN:-?}  Port=${INI_MQTT_PORT:-?}"
  echo -e "  ${B}[Remote Control]${N} Enable=${INI_RC_EN:-?}  Port=${INI_RC_PORT:-?}"

  echo ""
  [ "$(ini_get Modem Port)" = "$INI_PORT2" ] || warn "Port y UARTPort del .ini NO coinciden — el wrapper puede abrir el puerto equivocado"
  [ "$INI_POCSAG" = "1" ] || warn "POCSAG no está en 1 en [General] — la placa no paginará"
  [ "$INI_MQTT_EN" = "1" ] || warn "[MQTT] Enable no está en 1 — MMDVMHost no recibirá los pages"
  [ "$INI_MQTT_PORT" = "1883" ] || warn "[MQTT] Port=${INI_MQTT_PORT:-?} (esperado 1883) — puerto pisado"
  [ "$INI_RC_EN" = "1" ] || warn "[Remote Control] Enable no está en 1 — los pages por comando remoto no se procesan"
  [ "$INI_RC_PORT" = "7642" ] || warn "[Remote Control] Port=${INI_RC_PORT:-?} (esperado 7642) — puerto pisado"
  if [ "$KIND" = "hotspot" ] && [ "$INI_DUPLEX" = "1" ]; then
    warn "Duplex=1 con placa HOTSPOT — el duplex cuelga el STM32 en placas ADF7021 simples; debe ser 0"
  fi
  if [ "$KIND" = "repeater" ] && [ "$INI_DUPLEX" = "0" ]; then
    warn "Duplex=0 con placa REPETIDORA — el firmware G4KLX espera Duplex=1"
  fi
  if [ -n "$INI_FREQ" ] && [ "$INI_FREQ" != "$FREQ_HZ" ]; then
    warn "TXFrequency=${INI_FREQ} (esperado ${FREQ_HZ}) — el instalador pudo pisar la frecuencia de la BD"
  fi
  ok "Paridad revisada (los avisos de arriba son los desvíos)"
else
  fail "No se encontró MMDVM.ini en ${APP_DIR}"
fi

# ---------------------------------------------------------------------------
# 6. Resumen y próximos pasos
# ---------------------------------------------------------------------------
hdr "6. Resumen y próximos pasos"

echo ""
echo -e "  ${B}Ver la portación en vivo (y mandar un page de prueba):${N}"
echo -e "    ${C}sudo journalctl -u mmdvmhost -f${N}"
echo ""
if [ "$KIND" = "repeater" ]; then
  echo -e "  ${B}Placa REPETIDORA:${N} el test de frecuencia no aplica (el RF lo fija el radio)."
  echo -e "    Verifique PTT/COS/audio y UARTSpeed acorde al firmware (460800 en V3F4)."
elif [ "$KIND" = "hotspot" ]; then
  echo -e "  ${B}Placa HOTSPOT:${N} si el paso 4 dio NAK reason 4, reflashar el firmware custom:"
  echo -e "    ${C}sudo ./flash.sh firmware_pocsag512_149mhz.bin${N}"
fi
echo -e "  ${B}Si el paso 4 dio ACK pero el pager no suena:${N} el problema está en la"
echo -e "    portación POCSAG (velocidad de 512 baud en el firmware) o en el .ini."
echo ""