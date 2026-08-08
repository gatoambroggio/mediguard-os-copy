#!/usr/bin/env python3
"""
test_pocsag.py - TEST standalone TODO-EN-UNO.
Genera el bitstream POCSAG completo (preambulo 576 + sync + codewords con BCH)
y lo transmite directo al modem MMDVM por serial. Sin BD, sin imports externos:
corre aislado para diagnosticar en que le estamos errando.

El modem (ADF7021) hace la modulacion 2FSK en hardware; el host solo envia los
codewords como datos (POCSAG_DATA 0x50). El firmware agrega el preambulo al aire
antes del primer batch. Aca generamos el preambulo tambien solo para LOG/inspeccion.

Uso:
  sudo python3 test_pocsag.py <capcode> <mensaje> [baud] [txdelay_ms] [pocsag_level] [freq_hz] [func_mode]
  Ej:  sudo python3 test_pocsag.py 0002198 mensaje 512 500 50 149255000 alphanumeric
"""
import sys, os, struct, time, termios, fcntl

# === MMDVM Protocolo ===
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

# === POCSAG ===
SYNC_CODEWORD = 0x7CD215D8
IDLE_CODEWORD = 0x7A89C197
BCH_GEN = 0x779  # x^10+x^9+x^8+x^6+x^5+x^4+x^3+1
FN_NUMERIC = 0x0
FN_TONE = 0x1
FN_ALPHA = 0x3
NUM_CHARS = "0123456789*U -() "

LOG = "/tmp/test_pocsag.log"


def log(m):
    with open(LOG, "a") as f:
        f.write(time.strftime("%H:%M:%S") + " | " + m + "\n")


# === BCH(31,21) + paridad par ===
def bch_parity(data21):
    d = (data21 & 0x1FFFFF) << 10
    for i in range(20, -1, -1):
        if (d >> (i + 10)) & 1:
            d ^= BCH_GEN << i
    return d & 0x3FF


def make_codeword(flag, data20):
    data21 = ((flag & 1) << 20) | (data20 & 0xFFFFF)
    cw = (data21 & 0x1FFFFF) << 11
    cw |= bch_parity(data21) << 1
    if bin(cw).count("1") & 1:
        cw |= 1
    return cw & 0xFFFFFFFF


def alpha_bits(msg):
    bits = []
    for ch in msg:
        v = ord(ch) & 0x7F
        for i in range(7):
            bits.append((v >> i) & 1)
    return bits


def numeric_bits(msg):
    bits = []
    for ch in msg:
        idx = NUM_CHARS.find(ch)
        if idx < 0:
            idx = 12
        for i in range(3, -1, -1):  # MSB-first por digito BCD
            bits.append((idx >> i) & 1)
    return bits


def bits_to_words(bits, width=20):
    while len(bits) % width:
        bits.append(0)
    words = []
    for i in range(0, len(bits), width):
        chunk = bits[i:i + width]
        # POCSAG: primer bit del stream va en MSB del data field (bit 30 del cw)
        data20 = sum(b << (width - 1 - j) for j, b in enumerate(chunk))
        words.append(data20)
    return words


def build_codewords(cap, func, msg, func_mode):
    if func_mode == "numeric":
        fn = FN_NUMERIC
        mwords = bits_to_words(numeric_bits(msg)) if msg else []
    elif func_mode == "tone":
        fn = FN_TONE
        mwords = []
    else:
        fn = FN_ALPHA
        mwords = bits_to_words(alpha_bits(msg)) if msg else []
    addr_data = ((cap >> 3) << 2) | (fn & 0x3)
    addr_cw = make_codeword(0, addr_data)
    msg_cws = [make_codeword(1, w) for w in mwords]
    start_frame = cap & 0x7
    start_slot = start_frame * 2
    total = start_slot + 1 + len(msg_cws)
    import math
    batches = max(1, math.ceil(total / 16))
    slots = [IDLE_CODEWORD] * (batches * 16)
    pos = start_slot
    slots[pos] = addr_cw
    pos += 1
    for cw in msg_cws:
        slots[pos] = cw
        pos += 1
    out = []
    for b in range(batches):
        out.append(SYNC_CODEWORD)
        out.extend(slots[b * 16:(b + 1) * 16])
    return out


def cw_to_bits(cws):
    bits = []
    for cw in cws:
        for i in range(31, -1, -1):
            bits.append((cw >> i) & 1)
    return bits


# === Serial ===
def open_serial(port, baud):
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NDELAY)
    fcntl.fcntl(fd, fcntl.F_SETFL, 0)
    a = termios.tcgetattr(fd)
    speed_map = {9600: termios.B9600, 19200: termios.B19200, 38400: termios.B38400,
                 57600: termios.B57600, 115200: termios.B115200,
                 230400: termios.B230400, 460800: termios.B460800}
    s = speed_map.get(baud, termios.B115200)
    a[4] = s; a[5] = s
    a[2] = (a[2] & ~termios.CSIZE) | termios.CS8
    a[2] &= ~(termios.PARENB | termios.CSTOPB | termios.CRTSCTS)
    a[2] |= termios.CLOCAL | termios.CREAD
    a[3] = 0; a[0] = 0; a[1] = 0
    a[6][termios.VMIN] = 0; a[6][termios.VTIME] = 30
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def stuff(data):
    out = bytearray()
    for b in data:
        out.append(b)
        if b == FRAME_START:
            out.append(FRAME_START)
    return bytes(out)


def build_frame(cmd, data=b""):
    length = 3 + len(data)
    raw = bytes([FRAME_START, length, cmd]) + bytes(data)
    return bytes([FRAME_START]) + stuff(raw[1:])


def read_frame(fd, timeout=3.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        b = os.read(fd, 1)
        if b and b[0] == FRAME_START:
            break
    else:
        return None
    out = bytearray()
    prev = False
    while time.time() < deadline and len(out) < 255:
        b = os.read(fd, 1)
        if not b:
            continue
        byte = b[0]
        if byte == FRAME_START and not prev:
            prev = True; continue
        if prev:
            if byte == FRAME_START:
                out.append(FRAME_START); prev = False
            else:
                out = bytearray([byte]); prev = False
            continue
        out.append(byte)
        if len(out) >= 1 and out[0] >= 3 and len(out) >= out[0] - 1:
            break
    if not out:
        return None
    return bytes(out[1:out[0] - 1])


def send_frame(fd, cmd, data=b""):
    os.write(fd, build_frame(cmd, data))


def send_and_wait(fd, cmd, data=b"", timeout=3.0):
    send_frame(fd, cmd, data)
    time.sleep(0.15)
    return read_frame(fd, timeout)


def init_modem(fd, txdelay_ms, pocsag_level, freq_hz, tx_invert=1, rx_invert=0, ptt_invert=0):
    # GET_VERSION
    r = send_and_wait(fd, CMD_GET_VERSION, timeout=3.0)
    if not r or len(r) < 2:
        return False, "modem no responde GET_VERSION"
    proto = r[1] if r[0] == CMD_GET_VERSION else 0
    log("GET_VERSION proto=%d %s" % (proto, r[2:].decode("ascii", "replace")))
    if proto != 1:
        return False, "no es MMDVM_HS (proto=%d)" % proto

    # SET_MODE IDLE
    send_and_wait(fd, CMD_SET_MODE, bytes([STATE_IDLE]), 2.0)
    time.sleep(0.2)

    # SET_CONFIG (23 bytes, layout MMDVM_HS)
    # Flag byte: bit0=RXInvert, bit1=TXInvert, bit2=PTTInvert, bit7=simplex
    # Jumbospot/MMDVM_HS necesita TXInvert=1 (ADF7021 polaridad invertida)
    cfg = bytearray(23)
    cfg[0] = 0x80 | (rx_invert & 1) | ((tx_invert & 1) << 1) | ((ptt_invert & 1) << 2)
    cfg[1] = 0x20          # POCSAG enable
    cfg[2] = max(1, min(255, txdelay_ms // 10))
    cfg[3] = STATE_IDLE
    cfg[4] = 50            # rxLevel
    cfg[5] = 0
    cfg[6] = 0
    cfg[7] = 0
    cfg[8] = 128           # OscOffset
    cfg[13] = 128          # txDCOffset
    cfg[14] = 128          # rxDCOffset
    cfg[17] = max(0, min(100, pocsag_level))  # pocsagTXLevel
    log("SET_CONFIG bytes: %s" % " ".join("%02X" % b for b in cfg))
    r = send_and_wait(fd, CMD_SET_CONFIG, bytes(cfg), 3.0)
    if r and r[0] == CMD_ACK:
        log("SET_CONFIG ACK")
    elif r and r[0] == CMD_NAK:
        return False, "SET_CONFIG NAK razon=%d" % (r[2] if len(r) > 2 else -1)
    else:
        return False, "SET_CONFIG sin respuesta"

    # SET_FREQ (14 bytes: reserved + RX + TX + power + POCSAG, little-endian)
    power = 255
    fd2 = (bytes([0x00]) + struct.pack("<I", freq_hz) + struct.pack("<I", freq_hz)
           + bytes([power]) + struct.pack("<I", freq_hz))
    r = send_and_wait(fd, CMD_SET_FREQ, fd2, 3.0)
    if r and r[0] == CMD_ACK:
        log("SET_FREQ ACK %d Hz" % freq_hz)
    elif r and r[0] == CMD_NAK:
        return False, "SET_FREQ NAK razon=%d" % (r[2] if len(r) > 2 else -1)
    else:
        return False, "SET_FREQ sin respuesta"

    # SET_MODE POCSAG
    r = send_and_wait(fd, CMD_SET_MODE, bytes([STATE_POCSAG]), 3.0)
    if r and r[0] == CMD_ACK:
        log("SET_MODE POCSAG ACK")
    else:
        log("WARN SET_MODE POCSAG sin ACK")
    return True, "OK"


def send_pocsag(fd, cap, message, func_mode, baud):
    func = FN_ALPHA if func_mode == "alphanumeric" else (FN_NUMERIC if func_mode == "numeric" else FN_TONE)
    cws = build_codewords(cap, func, message, func_mode)
    log("Codewords: %d  cap=%d  func=%s(%d)" % (len(cws), cap, func_mode, func))
    for i, cw in enumerate(cws):
        log("  cw[%02d]=%08X" % (i, cw))

    # Bitstream completo para inspeccion (preambulo 576 + codewords)
    preamble = [1, 0] * (576 // 2)
    full_bits = preamble + cw_to_bits(cws)
    log("Bitstream total: %d bits (preambulo 576 + %d codewords)" % (len(full_bits), len(cws)))

    frame_tx_sec = 544.0 / max(baud, 1)
    sent = 0
    for i in range(0, len(cws), 17):
        chunk = cws[i:i + 17]
        while len(chunk) < 17:
            chunk.append(IDLE_CODEWORD)
        data = b"".join(struct.pack(">I", cw) for cw in chunk)
        send_frame(fd, CMD_POCSAG_DATA, data)
        log("POCSAG_DATA frame %d (%d cws)" % (sent + 1, len(chunk)))
        time.sleep(frame_tx_sec + 0.05)
        sent += 1
    return sent


def main():
    if len(sys.argv) < 3:
        print("Uso: test_pocsag.py <capcode> <mensaje> [baud] [txdelay_ms] [pocsag_level] [freq_hz] [func_mode] [tx_invert] [rx_invert]")
        sys.exit(1)
    cap = int(str(sys.argv[1]).strip().lstrip("0") or "0")
    message = str(sys.argv[2])
    baud = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else 512
    txdelay_ms = int(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else 500
    pocsag_level = int(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5] else 50
    freq_hz = int(sys.argv[6]) if len(sys.argv) > 6 and sys.argv[6] else 149255000
    func_mode = sys.argv[7] if len(sys.argv) > 7 and sys.argv[7] else "alphanumeric"
    tx_invert = int(sys.argv[8]) if len(sys.argv) > 8 and sys.argv[8] else 1
    rx_invert = int(sys.argv[9]) if len(sys.argv) > 9 and sys.argv[9] else 0
    port = "/dev/ttyUSB1"
    serial_baud = 115200

    log("=== TEST cap=%d msg=%r baud=%d txdelay=%dms level=%d freq=%d mode=%s txinv=%d rxinv=%d ===" %
        (cap, message, baud, txdelay_ms, pocsag_level, freq_hz, func_mode, tx_invert, rx_invert))
    print("cap=%d msg=%r baud=%d txdelay=%dms pocsag_level=%d freq=%dHz mode=%s txinv=%d rxinv=%d" %
          (cap, message, baud, txdelay_ms, pocsag_level, freq_hz, func_mode, tx_invert, rx_invert))

    fd = open_serial(port, serial_baud)
    try:
        ok, msg = init_modem(fd, txdelay_ms, pocsag_level, freq_hz, tx_invert, rx_invert)
        if not ok:
            print("ERROR: %s" % msg)
            sys.exit(1)
        time.sleep(0.5)
        total = send_pocsag(fd, cap, message, func_mode, baud)
        wait_sec = (total * 1120.0 / max(baud, 1)) + 2.0
        log("Esperando %.1fs (%d frames @ %d baud) antes de IDLE..." % (wait_sec, total, baud))
        time.sleep(wait_sec)
        send_and_wait(fd, CMD_SET_MODE, bytes([STATE_IDLE]), 2.0)
        print("OK: %d frame(s) POCSAG enviados. Log: %s" % (total, LOG))
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()