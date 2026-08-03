#!/usr/bin/env python3
"""
pocsag_gen.py - ZetronPOC v2.0 - Encoder POCSAG (Zetron 640 compatible)
Codewords POCSAG con BCH(31,21) + paridad par. FSK con filtrado Gaussiano.
Todos los parametros se leen de la BD (configurable desde el panel admin).

Uso: pocsag_gen.py <cap_code> <mensaje> [baudios] [wav_out]
"""
import sys, os, math, struct, wave

APP_DIR = os.environ.get("ZETRONPOC_DIR", "/opt/zetronpoc")
sys.path.insert(0, APP_DIR)
sys.path.insert(0, os.path.join(APP_DIR, "database"))
try:
    from db_manager import get_config
except Exception:
    def get_config(k, d=""): return d

# === Constantes POCSAG ===
SYNC_CODEWORD = 0x7CD215D8
IDLE_CODEWORD = 0x7A89C197
BCH_GEN = 0x779  # x^10+x^9+x^8+x^6+x^5+x^4+x^3+1

FUNCTION_NUMERIC = 0x0
FUNCTION_TONE = 0x1
FUNCTION_ALPHANUMERIC = 0x3
NUM_CHARS = "0123456789*U -() "

# === BCH(31,21) ===
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

# === Codificacion de mensajes ===
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
        for i in range(4):
            bits.append((idx >> i) & 1)
    return bits

def bits_to_words(bits, width=20):
    while len(bits) % width:
        bits.append(0)
    words = []
    for i in range(0, len(bits), width):
        chunk = bits[i:i + width]
        data20 = sum(b << j for j, b in enumerate(chunk))
        words.append(data20)
    return words

def build_codewords(cap, func, msg, func_mode):
    # Funcion
    if func_mode == "numeric":
        fn = FUNCTION_NUMERIC
        mwords = bits_to_words(numeric_bits(msg)) if msg else []
    elif func_mode == "tone":
        fn = FUNCTION_TONE
        mwords = []
    else:
        fn = FUNCTION_ALPHANUMERIC
        mwords = bits_to_words(alpha_bits(msg)) if msg else []

    # Address word
    addr_data = ((cap >> 3) << 2) | (fn & 0x3)
    addr_cw = make_codeword(0, addr_data)
    msg_cws = [make_codeword(1, w) for w in mwords]

    start_frame = cap & 0x7
    start_slot = start_frame * 2
    total = start_slot + 1 + len(msg_cws)
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

def codewords_to_bits(cws):
    bits = []
    for cw in cws:
        for i in range(31, -1, -1):
            bits.append((cw >> i) & 1)
    return bits

# === FSK ===
def gaussian_kernel(bt, baud, sr, span=4):
    sps = sr / baud
    n = max(1, int(span * sps))
    alpha = math.sqrt(math.log(2) / 2) * bt * baud
    h = []
    for i in range(-n // 2, n // 2 + 1):
        t = i / sr
        h.append(math.exp(-2 * (math.pi * alpha * t) ** 2))
    s = sum(h) or 1
    return [x / s for x in h]

def convolve(sig, h):
    n = len(h) // 2
    out = [0.0] * len(sig)
    for i in range(len(sig)):
        acc = 0.0
        for j in range(len(h)):
            k = i - n + j
            if 0 <= k < len(sig):
                acc += sig[k] * h[j]
        out[i] = acc
    return out

def bits_to_fsk(bits, baud, dev_hz, sr, bt, invert):
    sps = sr / baud
    n = int(len(bits) * sps) + 1
    nrz = []
    cur = 0
    for i in range(n):
        bi = int(i / sps)
        b = bits[bi] if bi < len(bits) else bits[-1]
        v = 1.0 if b == 1 else -1.0
        if invert:
            v = -v
        nrz.append(v)
    if bt and float(bt) > 0:
        nrz = convolve(nrz, gaussian_kernel(float(bt), baud, sr))
    # FM
    phase = 0.0
    out = [0.0] * len(nrz)
    for i in range(len(nrz)):
        freq = dev_hz * nrz[i]
        phase += 2 * math.pi * freq / sr
        out[i] = math.sin(phase)
    return out

def normalize(samples, peak=0.95):
    m = max(abs(s) for s in samples) or 1.0
    return [s / m * peak for s in samples]

def warmup_tone(ms, sr, gain):
    n = int(sr * ms / 1000)
    return [math.sin(2 * math.pi * 350 * i / sr) * gain for i in range(n)]

def write_wav(path, samples, sr):
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(b"".join(struct.pack("<h", int(s * 32767)) for s in samples))

def main():
    if len(sys.argv) < 3:
        print("Uso: pocsag_gen.py <cap_code> <mensaje> [baudios] [wav_out]", file=sys.stderr)
        sys.exit(1)
    cap = int(str(sys.argv[1]).split(",")[0])
    mensaje = str(sys.argv[2])
    baud = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else int(get_config("baudios_default", "1200"))
    wav_out = sys.argv[4] if len(sys.argv) > 4 else "/tmp/zetronpoc_out.wav"

    func_mode = get_config("function_mode", "alphanumeric")
    dev_hz = int(get_config("fsk_deviation_baseband_hz", "450"))
    sr = int(get_config("sample_rate", "22050"))
    gain = int(get_config("audio_gain", "80")) / 100.0
    invert = get_config("invert_audio", "0") == "1"
    bt = get_config("gaussian_bt", "0.5")
    preamble_bits = int(get_config("preamble_bits", "576"))
    warm_ms = int(get_config("warmup_%d_ms" % baud, "1500"))

    bits = [1, 0] * (preamble_bits // 2)
    bits += codewords_to_bits(build_codewords(cap, 0, mensaje, func_mode))

    samples = bits_to_fsk(bits, baud, dev_hz, sr, bt, invert)
    samples = warmup_tone(warm_ms, sr, gain) + samples
    samples = [s * gain for s in normalize(samples)]
    write_wav(wav_out, samples, sr)
    print("OK %s (%d samples, %d baud, modo %s, dev %dHz, sr %d)" % (wav_out, len(samples), baud, func_mode, dev_hz, sr))

if __name__ == "__main__":
    main()