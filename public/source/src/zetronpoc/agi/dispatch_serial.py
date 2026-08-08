#!/usr/bin/env python3
"""
dispatch_serial.py - Envío directo POCSAG al módem MMDVM por puerto serie.
Bypassa MMDVMHost y RemoteControl. Implementa el protocolo binario MMDVM v2
directamente sobre /dev/ttyUSB0 usando termios (sin dependencias externas).

Protocolo MMDVM v2:
  Frame: [0xE0] [Length] [Command] [Data...]
  Length incluye el byte 0xE0 y todos los bytes siguientes (sin stuffing).
  Byte stuffing: 0xE0 en datos → 0xE0 0xE0 en el wire.
  POCSAG_DATA (0x50): 68 bytes = 17 codewords uint32 big-endian
    (1 sync word + 16 codewords address/message/idle)

Uso: dispatch_serial.py <cap_code(s)> <mensaje> [baudios]
  cap_code(s): un cap_code o varios separados por coma (para grupos)
"""
import sys, os, struct, time, termios, fcntl

APP_DIR = os.environ.get("ZETRONPOC_DIR", "/opt/zetronpoc")
sys.path.insert(0, APP_DIR)
sys.path.insert(0, os.path.join(APP_DIR, "database"))
sys.path.insert(0, os.path.join(APP_DIR, "encoder"))

from db_manager import get_config
from pocsag_gen import build_codewords

# === MMDVM Protocol Constants ===
FRAME_START = 0xE0
CMD_GET_VERSION = 0x00
CMD_GET_STATUS = 0x01
CMD_SET_CONFIG = 0x02
CMD_SET_MODE = 0x03
CMD_SET_FREQ = 0x04
CMD_POCSAG_DATA = 0x50
CMD_ACK = 0x70
CMD_NAK = 0x7F

STATE_IDLE = 0
STATE_POCSAG = 6

POCSAG_SYNC_WORD = 0x7CD215D8
POCSAG_IDLE_WORD = 0x7A89C197
POCSAG_FRAME_WORDS = 17  # 1 sync + 16 data

LOG = os.path.join(APP_DIR, "logs", "dispatch_serial.log")


def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S") + " | " + msg + "\n")
    except Exception:
        pass


def open_serial(port, baud):
    """Abre puerto serie con termios (8N1, raw, sin dependencias)."""
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NDELAY)
    fcntl.fcntl(fd, fcntl.F_SETFL, 0)

    attrs = termios.tcgetattr(fd)
    speed_map = {
        9600: termios.B9600, 19200: termios.B19200, 38400: termios.B38400,
        57600: termios.B57600, 115200: termios.B115200,
        230400: termios.B230400, 460800: termios.B460800,
    }
    speed = speed_map.get(baud, termios.B115200)
    attrs[4] = speed
    attrs[5] = speed
    attrs[2] = (attrs[2] & ~termios.CSIZE) | termios.CS8
    attrs[2] &= ~termios.PARENB
    attrs[2] &= ~termios.CSTOPB
    attrs[2] &= ~termios.CRTSCTS
    attrs[2] |= termios.CLOCAL | termios.CREAD
    attrs[3] = 0
    attrs[0] = 0
    attrs[1] = 0
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 30  # 3s timeout
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def stuff(data):
    """Byte stuffing MMDVM: 0xE0 → 0xE0 0xE0."""
    out = bytearray()
    for b in data:
        out.append(b)
        if b == FRAME_START:
            out.append(FRAME_START)
    return bytes(out)


def build_frame(command, data=b""):
    """Construye frame MMDVM con byte stuffing."""
    length = 3 + len(data)
    raw = bytes([FRAME_START, length, command]) + bytes(data)
    return bytes([FRAME_START]) + stuff(raw[1:])


def read_frame(fd, timeout_sec=3.0):
    """Lee un frame del módem con destuffing. Retorna [cmd, data...] o None."""
    deadline = time.time() + timeout_sec

    # Buscar frame start
    while time.time() < deadline:
        b = os.read(fd, 1)
        if not b:
            continue
        if b[0] == FRAME_START:
            break
    else:
        return None

    # Leer resto con destuffing
    out = bytearray()
    prev_e0 = False
    while time.time() < deadline and len(out) < 255:
        b = os.read(fd, 1)
        if not b:
            continue
        byte = b[0]
        if byte == FRAME_START and not prev_e0:
            prev_e0 = True
            continue
        if prev_e0:
            if byte == FRAME_START:
                out.append(FRAME_START)
                prev_e0 = False
            else:
                # Nuevo frame start
                out = bytearray()
                out.append(byte)
                prev_e0 = False
            continue
        out.append(byte)
        if len(out) >= 1:
            length = out[0]
            if length >= 3 and len(out) >= length - 1:
                break

    if not out:
        return None
    length = out[0]
    payload = out[1:length - 1]
    return bytes(payload)


def send_frame(fd, command, data=b""):
    os.write(fd, build_frame(command, data))


def send_and_wait(fd, command, data=b"", timeout=3.0):
    send_frame(fd, command, data)
    time.sleep(0.15)
    return read_frame(fd, timeout)


def safe_int(val, default=50):
    """Convierte a int de forma segura, devolviendo default si está vacío o es inválido."""
    try:
        if val is None or str(val).strip() == "":
            return default
        return int(val)
    except (ValueError, TypeError):
        return default


def init_modem(fd, cfg):
    """Secuencia completa de inicialización del módem MMDVM."""
    # 1. GET_VERSION — detectar version de protocolo (1=MMDVM_HS/Jumbospot, 2=G4KLX)
    log("GET_VERSION...")
    resp = send_and_wait(fd, CMD_GET_VERSION, timeout=3.0)
    if not resp or len(resp) < 2:
        log("ERROR: módem no responde a GET_VERSION")
        return False, "modem no responde (GET_VERSION)"
    proto = 0
    if resp[0] == CMD_GET_VERSION:
        proto = resp[1] if len(resp) > 1 else 0
        ver = resp[2:].decode("ascii", errors="replace") if len(resp) > 2 else ""
        log("GET_VERSION OK: proto=%d %s" % (proto, ver))
    else:
        log("GET_VERSION resp cmd=0x%02X" % resp[0])

    # 1b. SET_MODE IDLE — forzar estado IDLE antes de reconfigurar
    log("SET_MODE IDLE (preconfig)...")
    send_and_wait(fd, CMD_SET_MODE, bytes([STATE_IDLE]), timeout=2.0)
    time.sleep(0.2)

    # 2. SET_CONFIG — layout DISTINTO segun firmware
    #    proto=1 (MMDVM_HS / Jumbospot): 23 bytes min
    #      data[0]=flags, data[1]=modos(POCSAG=0x20), data[2]=txDelay,
    #      data[3]=modemState, data[6]=colorCode(0-15), data[17]=pocsagTXLevel
    #    proto=2 (G4KLX MMDVM): 37 bytes min
    #      data[0]=flags, data[1]=modos1, data[2]=modos2(POCSAG=0x01),
    #      data[3]=txDelay, data[4]=modemState, data[5]=rxLevel, data[6]=txLevel
    log("SET_CONFIG (proto=%d)..." % proto)
    flags = 0x00
    if cfg.get("mmdvm_rx_invert", "0") == "1": flags |= 0x01
    if cfg.get("mmdvm_tx_invert", "0") == "1": flags |= 0x02
    if cfg.get("mmdvm_ptt_invert", "0") == "1": flags |= 0x04
    if cfg.get("mmdvm_duplex", "0") == "0": flags |= 0x80

    if proto == 1:
        # MMDVM_HS (Jumbospot) — layout exacto de MMDVMHost setConfig1 (23 bytes).
        #   data[0]=flags, data[1]=CAP1 (POCSAG=0x20), data[2]=txDelay/10,
        #   data[3]=MODE_IDLE, data[4]=rxLevel, data[5]=cwIdTXLevel,
        #   data[6]=dmrColorCode(0-15), data[7]=dmrDelay, data[8]=OscOffset(128),
        #   data[9]=dstarTXLevel, data[10]=dmrTXLevel, data[11]=ysfTXLevel,
        #   data[12]=p25TXLevel, data[13]=txDCOffset+128, data[14]=rxDCOffset+128,
        #   data[15]=nxdnTXLevel, data[16]=ysfTXHang, data[17]=pocsagTXLevel.
        config_data = bytearray(23)
        config_data[0] = flags
        config_data[1] = 0x20          # POCSAG enable (bit 5 de CAP1)
        config_data[2] = 50             # txDelay/10 = 500ms (igual que .ini [Modem] TXDelay=500, valor efectivo que hacia sonar el beeper)
        config_data[3] = STATE_IDLE    # modemState
        config_data[4] = 50            # rxLevel
        config_data[5] = 0             # cwIdTXLevel
        config_data[6] = 0             # dmrColorCode (sin DMR)
        config_data[7] = 0             # dmrDelay
        config_data[8] = 128           # OscOffset (debe ser 128, no 0)
        config_data[9] = 0             # dstarTXLevel
        config_data[10] = 0            # dmrTXLevel
        config_data[11] = 0            # ysfTXLevel
        config_data[12] = 0            # p25TXLevel
        config_data[13] = 128          # txDCOffset + 128
        config_data[14] = 128          # rxDCOffset + 128
        config_data[15] = 0            # nxdnTXLevel
        config_data[16] = 0            # ysfTXHang
        config_data[17] = 50           # pocsagTXLevel -> +-4.5kHz (stock). 80 daba +-7.2kHz (sobredesviacion): el pager 512 no decodifica.
        # data[18..22]: niveles RX restantes en 0
    else:
        # G4KLX MMDVM v2 — 37 bytes, POCSAG=data[2] bit 0
        config_data = bytearray(37)
        config_data[0] = flags
        config_data[1] = 0x00
        config_data[2] = 0x01          # POCSAG enable (bit 0)
        config_data[3] = 50            # txDelay (max 50)
        config_data[4] = STATE_IDLE    # modemState
        config_data[5] = 50            # rxLevel
        config_data[6] = 50            # txLevel
        for i in range(7, 37):
            config_data[i] = 50

    log("SET_CONFIG bytes: %s" % " ".join("%02X" % b for b in config_data))
    resp = send_and_wait(fd, CMD_SET_CONFIG, bytes(config_data), timeout=3.0)
    if resp and resp[0] == CMD_ACK:
        log("SET_CONFIG OK (ACK)")
    elif resp and resp[0] == CMD_NAK:
        reason = resp[2] if len(resp) > 2 else "?"
        log("ERROR: SET_CONFIG NAK razon=%d" % reason)
        return False, "SET_CONFIG rechazado (NAK razon=%d)" % reason
    else:
        log("WARN: SET_CONFIG sin respuesta")

    # 3. SET_FREQ
    log("SET_FREQ...")
    # FRECUENCIA HARDCODEADA — 149.255 MHz (VHF) segun hardware del usuario.
    # Frame SET_FREQ EXACTO (segun MMDVMHost setFrequency, proto 1):
    #   data[0]    = 0x00 (byte reserved)
    #   data[1..4] = RX frequency  (LITTLE-ENDIAN, Hz)
    #   data[5..8] = TX frequency  (LITTLE-ENDIAN, Hz)
    #   data[9]    = RF power      (0-255, = rfLevel*2.55)
    #   data[10..13]= POCSAG freq  (LITTLE-ENDIAN, Hz)
    #   Total = 14 bytes.
    # CRITICO: endianness LITTLE y byte reserved 0x00. Con big-endian o sin el
    # byte reserved, el firmware parsea frecuencias basura -> NAK razon 4 -> sin RF.
    # (Confirmado en g4klx/MMDVM-Host Modem.cpp setFrequency().)
    freq_hz = 149255000
    power = 255  # 100% RF level
    freq_data = (bytes([0x00])
                 + struct.pack("<I", freq_hz)
                 + struct.pack("<I", freq_hz)
                 + bytes([power])
                 + struct.pack("<I", freq_hz))

    resp = send_and_wait(fd, CMD_SET_FREQ, freq_data, timeout=3.0)
    if resp and resp[0] == CMD_ACK:
        log("SET_FREQ OK (ACK) %d Hz power=%d" % (freq_hz, power))
    elif resp and resp[0] == CMD_NAK:
        reason = resp[2] if len(resp) > 2 else -1
        log("ERROR: SET_FREQ NAK razon=%d" % reason)
        hint = ""
        if reason == 4:
            hint = " — freq fuera de rango: el firmware MMDVM_HS solo acepta 144-148 / 219-225 / 420-475 / 842-950 MHz salvo DISABLE_FREQ_CHECK. 149.255 MHz queda fuera de 144-148."
        return False, "SET_FREQ rechazado (NAK razon=%d)%s" % (reason, hint)
    else:
        log("WARN: SET_FREQ sin respuesta")

    # 4. SET_MODE POCSAG
    log("SET_MODE POCSAG...")
    resp = send_and_wait(fd, CMD_SET_MODE, bytes([STATE_POCSAG]), timeout=3.0)
    if resp and resp[0] == CMD_ACK:
        log("SET_MODE OK (ACK)")
    else:
        log("WARN: SET_MODE sin ACK")

    return True, "inicializacion OK"


def send_pocsag(fd, cap_code, message, func_mode="alphanumeric", baud=1200):
    """Genera codewords POCSAG y los envía como frames MMDVM al módem."""
    func = 0x3 if func_mode == "alphanumeric" else (0x0 if func_mode == "numeric" else 0x1)
    cws = build_codewords(cap_code, func, message, func_mode)
    log("Codewords: %d para cap=%d func=%s" % (len(cws), cap_code, func_mode))

    # Paceo entre frames segun baud: un frame POCSAG = 544 bits. A baudios bajos
    # (512) el firmware demora ~1.06s/frame en vaciar el buffer de 1000 bytes del
    # STM32; si el host envia cada 0.15s, el buffer se llena y se pierden frames
    # -> el pager recibe un fragmento ("suena y se corta"). Se espera lo que tarda
    # un frame en salir del aire antes de mandar el siguiente.
    frame_tx_sec = 544.0 / max(baud, 1)
    frames_sent = 0
    for i in range(0, len(cws), POCSAG_FRAME_WORDS):
        chunk = cws[i:i + POCSAG_FRAME_WORDS]
        while len(chunk) < POCSAG_FRAME_WORDS:
            chunk.append(POCSAG_IDLE_WORD)
        data = b"".join(struct.pack(">I", cw) for cw in chunk)
        log("Frame POCSAG %d (%d cws)" % (frames_sent + 1, len(chunk)))
        send_frame(fd, CMD_POCSAG_DATA, data)
        time.sleep(frame_tx_sec + 0.05)
        frames_sent += 1
    return frames_sent


def main():
    if len(sys.argv) < 3:
        print("Uso: dispatch_serial.py <cap_code(s)> <mensaje> [baudios]")
        sys.exit(1)

    caps_str = str(sys.argv[1])
    cap_list = [int(c.strip()) for c in caps_str.split(",") if c.strip()]
    message = str(sys.argv[2])
    baud = safe_int(sys.argv[3], safe_int(get_config("mmdvm_pocsag_baud", "1200"), 1200))
    func_mode = get_config("function_mode", "alphanumeric") or "alphanumeric"

    # PUERTO HARDCODEADO — ignorar la base de datos para evitar errores de config.
    port = "/dev/ttyUSB1"
    serial_baud = 115200

    log("=== Envio directo serial ===")
    log("Port=%s baud=%d caps=%s msg=%r" % (port, serial_baud, cap_list, message))

    if not cap_list:
        log("ERROR: no hay cap codes validos")
        print("ERROR: cap codes invalidos")
        sys.exit(1)

    try:
        fd = open_serial(port, serial_baud)
    except Exception as e:
        log("ERROR abriendo %s: %s" % (port, e))
        print("ERROR: %s" % e)
        sys.exit(1)

    try:
        cfg = {}
        for k in ["mmdvm_tx_invert", "mmdvm_rx_invert", "mmdvm_ptt_invert",
                   "mmdvm_duplex", "mmdvm_enable_pocsag", "mmdvm_ptt_delay",
                   "mmdvm_rx_level", "mmdvm_tx_level", "mmdvm_frequency"]:
            cfg[k] = get_config(k)

        ok, msg = init_modem(fd, cfg)
        if not ok:
            print("ERROR: %s" % msg)
            sys.exit(1)

        time.sleep(0.5)

        total = 0
        for cap in cap_list:
            total += send_pocsag(fd, cap, message, func_mode, baud)

        # Esperar a que el firmware termine de transmitir TODOS los frames
        # antes de liberar PTT. Un frame POCSAG ~= 1120 bits (576 preamble +
        # 544 datos). A 1200 baud son ~0.9s/frame; a 512 baud ~2.2s/frame. Si se
        # manda SET_MODE IDLE antes de tiempo, el firmware aborta la TX y el
        # pager recibe solo un fragmento ("suena y se corta"). Por eso el wait
        # se calcula segun baud y nro de frames, no fijo.
        wait_sec = (total * 1120.0 / max(baud, 1)) + 2.0
        log("Esperando %.1fs (%d frame(s) @ %d baud) antes de liberar PTT..." % (wait_sec, total, baud))
        time.sleep(wait_sec)
        log("SET_MODE IDLE (post-envio, liberar PTT)...")
        send_and_wait(fd, CMD_SET_MODE, bytes([STATE_IDLE]), timeout=2.0)

        log("Envio completado: %d frame(s) a %d cap(s)" % (total, len(cap_list)))
        print("OK: %d frame(s) POCSAG a %d destinatario(s)" % (total, len(cap_list)))

    finally:
        os.close(fd)


if __name__ == "__main__":
    main()