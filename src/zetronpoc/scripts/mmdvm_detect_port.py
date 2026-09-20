#!/usr/bin/env python3
"""mmdvm_detect_port.py - Detecta el puerto serie real del modulo MMDVM.

Envia un frame GET_VERSION (0xE0 0x03 0x00) del protocolo MMDVM v2 a cada
candidato y devuelve el primero que responde con un frame 0xE0. Sin esto el
instalador forzaba /dev/ttyS0 (mini-UART de la Pi) que NO es donde esta la
placa MMDVM-HS (esa vive en /dev/ttyAMA0 con dtoverlay=disable-bt, o en
/dev/ttyUSB0 si se conecta por USB-TTL) -> MMDVMHost abre el puerto equivocado,
nunca hace handshake y la LED roja del modulo queda titilando.

Uso:
  mmdvm_detect_port.py [puerto_sugerido] [baud] [--version] [--board] [--single]
  - imprime el puerto que responde y sale 0
  - --version: imprime "puerto<TAB>version_firmware"
  - --board:   imprime "puerto<TAB>hotspot|repeater<TAB>proto<TAB>version"
               (se clasifica por el string: MMDVM_HS = hotspot ADF7021,
                MMDVM = G4KLX, modem de radio externo / repetidora)
  - si ninguno responde, sale 1 (sin imprimir nada)

Deteccion preferida: USB-TTL (ttyUSB/ttyACM) > ttyAMA0 (HAT) > ttyS0 (mini-UART).
"""
import os, sys, time, termios, fcntl, glob

FRAME_START = 0xE0
CMD_GET_VERSION = 0x00


def _parse_version(frame):
    """Extrae la descripcion del firmware de la respuesta GET_VERSION.
    Frame MMDVM: 0xE0 <len> <cmd> <ver> <desc...> <crc> <crc>.
    desc = payload[2:-2] (salta cmd 0x00 y ver, descarta 2 bytes de CRC)."""
    try:
        plen = frame[1]
        payload = frame[2:2 + plen]
        if len(payload) < 4:
            return None
        desc = payload[2:-2]
        s = desc.decode("ascii", "ignore").strip()
        return s or None
    except Exception:
        return None


def _parse_proto(frame):
    """Byte de version de protocolo de GET_VERSION:
    1 = MMDVM_HS (hotspot ADF7021), 2 = G4KLX MMDVM (repetidora de radio externo).
    Frame MMDVM: 0xE0 <len> <cmd> <protover> <desc...> <crc> <crc>."""
    try:
        plen = frame[1]
        payload = frame[2:2 + plen]
        return payload[1] if len(payload) >= 2 else None
    except Exception:
        return None


def probe(port, baud=115200, timeout=1.6):
    """(ok, version_str, proto) — ok True si `port` responde a GET_VERSION con un
    frame MMDVM valido; version_str es la descripcion de firmware del modulo
    (o None); proto es el byte de version de protocolo (1/2, o None)."""
    try:
        fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NDELAY)
    except OSError:
        return (False, None, None)
    try:
        fcntl.fcntl(fd, fcntl.F_SETFL, 0)
        a = termios.tcgetattr(fd)
        sp = {9600: termios.B9600, 19200: termios.B19200, 38400: termios.B38400,
              57600: termios.B57600, 115200: termios.B115200,
              230400: termios.B230400, 460800: termios.B460800}.get(baud, termios.B115200)
        a[4] = sp; a[5] = sp
        a[2] = (a[2] & ~termios.CSIZE) | termios.CS8
        a[2] &= ~(termios.PARENB | termios.CSTOPB | termios.CRTSCTS)
        a[2] |= termios.CLOCAL | termios.CREAD
        a[3] = 0; a[0] = 0; a[1] = 0
        a[6][termios.VMIN] = 0
        a[6][termios.VTIME] = max(1, int(timeout * 10))
        termios.tcsetattr(fd, termios.TCSANOW, a)
        termios.tcflush(fd, termios.TCIOFLUSH)
        os.write(fd, bytes([FRAME_START, 3, CMD_GET_VERSION]))
        time.sleep(0.35)
        deadline = time.time() + timeout
        first = b""
        while time.time() < deadline:
            try:
                r = os.read(fd, 64)
            except OSError:
                break
            if r:
                first += r
                break
            time.sleep(0.05)
        termios.tcflush(fd, termios.TCIOFLUSH)
        # un MMDVM valido responde con un frame que arranca en 0xE0
        if first and first[0] == FRAME_START and len(first) >= 3:
            return (True, _parse_version(first), _parse_proto(first))
        return (False, None, None)
    except Exception:
        return (False, None, None)
    finally:
        try:
            os.close(fd)
        except Exception:
            pass


def candidates():
    out = []
    out += sorted(glob.glob("/dev/ttyUSB*"))
    out += sorted(glob.glob("/dev/ttyACM*"))
    if os.path.exists("/dev/ttyAMA0"):
        out.append("/dev/ttyAMA0")
    if os.path.exists("/dev/ttyS0"):
        out.append("/dev/ttyS0")
    # desduplicar preservando orden
    seen = set(); res = []
    for p in out:
        if p not in seen:
            seen.add(p); res.append(p)
    return res


def _board_kind(version):
    """Clasifica la placa por el STRING de version de GET_VERSION.

    El byte de protocolo NO sirve para distinguirlas: MMDVM_HS (hotspot con
    ADF7021) y MMDVM (G4KLX, modem que maneja un radio externo) responden los
    dos con 1. Lo que las diferencia es el string: MMDVM_HS lo lleva siempre en
    el nombre ("MMDVM_HS-v1.6.0 20210919 14.7456MHz"), el G4KLX no
    ("MMDVM 20180327")."""
    v = (version or "").strip().upper()
    if not v:
        return "desconocido"
    if v.startswith("MMDVM_HS") or v.startswith("MMDVM-HS"):
        return "hotspot"
    if v.startswith("MMDVM"):
        return "repeater"
    return "desconocido"


def _emit(port, ver, proto, want_version, want_board):
    if want_board:
        print("%s\t%s\t%s\t%s" % (port, _board_kind(ver),
                                  proto if proto is not None else "?", ver or ""))
    elif want_version and ver:
        print("%s\t%s" % (port, ver))
    else:
        print(port)


def main():
    baud = 115200
    want_version = False
    want_board = False
    single = False
    pos = []
    for a in sys.argv[1:]:
        if a == "--version":
            want_version = True
        elif a == "--board":
            want_board = True
        elif a == "--single":
            single = True
        elif not a.startswith("--"):
            pos.append(a)
    if len(pos) >= 2:
        try:
            baud = int(pos[1])
        except ValueError:
            pass
    suggested = pos[0] if pos else ""
    # 1) si pasan un puerto sugerido, probarlo primero
    if suggested:
        ok, ver, proto = probe(suggested, baud)
        if ok:
            _emit(suggested, ver, proto, want_version, want_board); return 0
        if single:
            # --single: NO barrer otros candidatos (acota el tiempo del polling)
            return 1
    # 2) barrer candidatos por prioridad
    for p in candidates():
        ok, ver, proto = probe(p, baud)
        if ok:
            _emit(p, ver, proto, want_version, want_board); return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())