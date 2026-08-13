#!/usr/bin/env python3
"""mmdvm_detect_port.py - Detecta el puerto serie real del modulo MMDVM.

Envia un frame GET_VERSION (0xE0 0x03 0x00) del protocolo MMDVM v2 a cada
candidato y devuelve el primero que responde con un frame 0xE0. Sin esto el
instalador forzaba /dev/ttyS0 (mini-UART de la Pi) que NO es donde esta la
placa MMDVM-HS (esa vive en /dev/ttyAMA0 con dtoverlay=disable-bt, o en
/dev/ttyUSB0 si se conecta por USB-TTL) -> MMDVMHost abre el puerto equivocado,
nunca hace handshake y la LED roja del modulo queda titilando.

Uso:
  mmdvm_detect_port.py [puerto_sugerido] [baud]
  - imprime el puerto que responde y sale 0
  - si ninguno responde, sale 1 (sin imprimir nada)

Deteccion preferida: USB-TTL (ttyUSB/ttyACM) > ttyAMA0 (HAT) > ttyS0 (mini-UART).
"""
import os, sys, time, termios, fcntl, glob

FRAME_START = 0xE0
CMD_GET_VERSION = 0x00


def probe(port, baud=115200, timeout=1.6):
    """True si `port` responde a GET_VERSION con un frame MMDVM valido."""
    try:
        fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NDELAY)
    except OSError:
        return False
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
        return bool(first and first[0] == FRAME_START and len(first) >= 3)
    except Exception:
        return False
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


def main():
    baud = 115200
    if len(sys.argv) > 2:
        try:
            baud = int(sys.argv[2])
        except ValueError:
            pass
    # 1) si pasan un puerto sugerido, probarlo primero
    if len(sys.argv) > 1 and sys.argv[1]:
        if probe(sys.argv[1], baud):
            print(sys.argv[1]); return 0
    # 2) barrer candidatos por prioridad
    for p in candidates():
        if probe(p, baud):
            print(p); return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())