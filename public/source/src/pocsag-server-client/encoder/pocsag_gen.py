#!/usr/bin/env python3
# Codificador POCSAG con Filtro Gaussiano para Radios VHF/UHF
# Dual Rate (Zetron Model 640) - parametros leidos desde la base de datos:
#   512 baud: WarmUp configurable + preambulo configurable @ 512 Hz
#  1200 baud: WarmUp configurable + preambulo configurable @ 1200 Hz
# Si la BD no esta disponible, usa defaults del Zetron 640.
import sys, wave, struct, math

SYNC = 0x7CD215D8
IDLE = 0x7A89C197
FRAME_SIZE = 2
BATCH_SIZE = 16
FLAG_MESSAGE = 0x100000
FUNCTION_ALPHANUMERIC = 0x3
FUNCTION_NUMERIC = 0x0
FUNCTION_TONE = 0x1
FUNCTION_BITS = {'alphanumeric': 0x3, 'numeric': 0x0, 'tone': 0x1}
CRC_BITS = 10
CRC_GENERATOR = 0b11101101001
TEXT_BITS_PER_WORD = 20
TEXT_BITS_PER_CHAR = 7

# Defaults del Zetron Model 640 (se usan si la BD no responde)
# POCSAG estandar: preambulo >= 576 bits, 2-FSK, desviacion 4.5 kHz (450 Hz baseband)
DEFAULT_WARMUP_MS = {512: 750, 1200: 1500, 2400: 1500}
DEFAULT_PREAMBLE_BITS = 576
DEFAULT_FSK_DEVIATION_KHZ = 4.5
DEFAULT_FSK_DEVIATION_BASEBAND_HZ = 450
DEFAULT_FSK_LEVELS = 2
DEFAULT_FUNCTION_MODE = "alphanumeric"

def get_encoder_config():
    """Lee la configuracion Dual Rate desde la base de datos.
    Devuelve dict con warmup_ms (por baud), preamble_bits y parametros FSK."""
    cfg = {
        'warmup_512': DEFAULT_WARMUP_MS[512],
        'warmup_1200': DEFAULT_WARMUP_MS[1200],
        'warmup_2400': DEFAULT_WARMUP_MS[2400],
        'preamble_bits': DEFAULT_PREAMBLE_BITS,
        'fsk_deviation_khz': DEFAULT_FSK_DEVIATION_KHZ,
        'fsk_deviation_baseband_hz': DEFAULT_FSK_DEVIATION_BASEBAND_HZ,
        'fsk_levels': DEFAULT_FSK_LEVELS,
        'function_mode': DEFAULT_FUNCTION_MODE,
    }
    try:
        sys.path.insert(0, "/opt/pocsag-server")
        sys.path.insert(0, "/opt/pocsag-server/database")
        from db_manager import get_config
        for k, dkey in [('warmup_512_ms', 'warmup_512'), ('warmup_1200_ms', 'warmup_1200'),
                        ('warmup_2400_ms', 'warmup_2400'), ('preamble_bits', 'preamble_bits'),
                        ('fsk_levels', 'fsk_levels')]:
            val = get_config(k, "")
            if val:
                try: cfg[dkey] = int(val)
                except (ValueError, TypeError): pass
        for k, dkey in [('fsk_deviation_khz', 'fsk_deviation_khz'),
                        ('fsk_deviation_baseband_hz', 'fsk_deviation_baseband_hz'),
                        ('function_mode', 'function_mode')]:
            val = get_config(k, "")
            if val:
                if dkey in ('fsk_deviation_khz', 'fsk_deviation_baseband_hz'):
                    try: cfg[dkey] = float(val)
                    except (ValueError, TypeError): pass
                else:
                    cfg[dkey] = val
    except Exception:
        pass
    return cfg

ENC_CFG = None

def get_preamble_bits():
    global ENC_CFG
    if ENC_CFG is None: ENC_CFG = get_encoder_config()
    return ENC_CFG.get('preamble_bits', DEFAULT_PREAMBLE_BITS)

def get_function_bits():
    """Devuelve los bits de funcion POCSAG segun el modo configurado en la BD."""
    global ENC_CFG
    if ENC_CFG is None: ENC_CFG = get_encoder_config()
    mode = (ENC_CFG.get('function_mode', DEFAULT_FUNCTION_MODE) or 'alphanumeric').lower()
    return FUNCTION_BITS.get(mode, FUNCTION_ALPHANUMERIC)

def crc(input_msg):
    denominator = CRC_GENERATOR << 20
    msg = input_msg << CRC_BITS
    for column in range(0, 21):
        if (msg >> (30 - column)) & 1:
            msg ^= denominator
        denominator >>= 1
    return msg & 0x3FF

def parity(x):
    p = 0
    for _ in range(32):
        p ^= (x & 1); x >>= 1
    return p

def encode_codeword(msg, is_message=False):
    base = (0x100000 | (msg & 0xFFFFF)) if is_message else (msg & 0xFFFFF)
    full = (base << CRC_BITS) | crc(base)
    return (full << 1) | parity(full)

def address_offset(address):
    return (address & 0x7) * FRAME_SIZE

def encode_transmission(address, message):
    out = []
    # Preambulo: N bits de 1s y 0s alternados (patron 0xAAAAAAAA = 32 bits c/u)
    preamble_bits = get_preamble_bits()
    preamble_words = max(1, (preamble_bits + 31) // 32)
    for _ in range(preamble_words):
        out.append(0xAAAAAAAA)
    start = len(out)
    out.append(SYNC)
    offset = address_offset(address)
    for _ in range(offset):
        out.append(IDLE)
    addr_data = ((address >> 3) << 2) | get_function_bits()
    out.append(encode_codeword(addr_data, is_message=False))
    cur = 0; nbits = 0; pos = offset + 1
    for c in message:
        for i in range(TEXT_BITS_PER_CHAR):
            cur = (cur << 1) | ((ord(c) >> i) & 1)
            nbits += 1
            if nbits == TEXT_BITS_PER_WORD:
                out.append(encode_codeword(cur, is_message=True))
                cur = 0; nbits = 0; pos += 1
                if pos == BATCH_SIZE:
                    out.append(SYNC); pos = 0
    if nbits > 0:
        cur <<= (TEXT_BITS_PER_WORD - nbits)
        out.append(encode_codeword(cur, is_message=True))
        pos += 1
        if pos == BATCH_SIZE:
            out.append(SYNC); pos = 0
    out.append(IDLE)
    written = len(out) - start
    pad = (BATCH_SIZE + 1) - (written % (BATCH_SIZE + 1))
    for _ in range(pad):
        out.append(IDLE)
    return out

def modulate_gaussian(codewords, baud, sample_rate):
    spb = sample_rate // baud
    raw_bits = []
    for w in codewords:
        for b in range(31, -1, -1):
            raw_bits.append(1 if (w >> b) & 1 else 0)
    total_samples = len(raw_bits) * spb
    samples = [0.0] * total_samples
    for i, bit in enumerate(raw_bits):
        val = -1.0 if bit == 1 else 1.0
        for s in range(spb):
            samples[i * spb + s] = val
    bt = 0.5
    alpha = math.sqrt(2 * math.log(2)) / (bt / baud)
    filter_size = spb * 2 + 1
    mid = filter_size // 2
    kernel = []
    for i in range(filter_size):
        t = (i - mid) / sample_rate
        h = (alpha / math.sqrt(math.pi)) * math.exp(- (alpha * t) ** 2)
        kernel.append(h)
    ksum = sum(kernel)
    kernel = [x / ksum for x in kernel]
    filtered = [0.0] * total_samples
    for i in range(total_samples):
        val = 0.0
        for k in range(filter_size):
            idx = i - (k - mid)
            if 0 <= idx < total_samples:
                val += samples[idx] * kernel[k]
        filtered[i] = val
    out = []
    for s in filtered:
        amp = max(-32768, min(32767, int(s * 24000)))
        out.append(struct.pack('<h', amp))
    return b''.join(out)

def generate_warmup(baud, sample_rate):
    """Genera silencio (amplitud 0) durante el WarmUp configurado en la BD."""
    global ENC_CFG
    if ENC_CFG is None: ENC_CFG = get_encoder_config()
    key = f'warmup_{baud}'
    warmup_ms = ENC_CFG.get(key, DEFAULT_WARMUP_MS.get(baud, 750))
    warmup_samples = int(sample_rate * warmup_ms / 1000)
    return b'\x00\x00' * warmup_samples, warmup_ms

def main():
    if len(sys.argv) != 5:
        print("Uso: pocsag_gen.py <cap> <msg> <baud> <out.wav>", file=sys.stderr)
        return 1
    cap, msg, baud, out_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    if baud not in (512, 1200, 2400):
        baud = 1200
    sample_rate = 38400
    if sample_rate % baud != 0:
        sample_rate = baud * 32
    codewords = encode_transmission(int(cap), msg)
    data = modulate_gaussian(codewords, baud, sample_rate)
    warmup, warmup_ms = generate_warmup(baud, sample_rate)
    preamble_bits = get_preamble_bits()
    with wave.open(out_path, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sample_rate)
        w.writeframes(warmup + data)
    fsk_khz = ENC_CFG.get('fsk_deviation_khz', DEFAULT_FSK_DEVIATION_KHZ)
    fsk_bb = ENC_CFG.get('fsk_deviation_baseband_hz', DEFAULT_FSK_DEVIATION_BASEBAND_HZ)
    fsk_lvl = ENC_CFG.get('fsk_levels', DEFAULT_FSK_LEVELS)
    fmode = ENC_CFG.get('function_mode', DEFAULT_FUNCTION_MODE)
    print(f"OK: {out_path} ({baud} bps, {sample_rate} Hz, warmup={warmup_ms}ms, preamble={preamble_bits}bits, "
          f"FSK {fsk_lvl}-nivel desv={fsk_khz}kHz/{fsk_bb}Hzbb, modo={fmode}, {len(codewords)} cw)")
    return 0

if __name__ == "__main__":
    sys.exit(main())