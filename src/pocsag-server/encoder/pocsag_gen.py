#!/usr/bin/env python3
# Codificador POCSAG con Filtro Gaussiano para Radios VHF/UHF
# Genera WAV mono 16-bit compatible con entradas de audio comerciales (Mic o Data).
# Basado en el algoritmo de faithanalog/pocsag-encoder.
import sys, wave, struct, math

SYNC = 0x7CD215D8
IDLE = 0x7A89C197
FRAME_SIZE = 2
BATCH_SIZE = 16
PREAMBLE_LENGTH = 576
FLAG_MESSAGE = 0x100000
FUNCTION_ALPHANUMERIC = 0x3
CRC_BITS = 10
CRC_GENERATOR = 0b11101101001
TEXT_BITS_PER_WORD = 20
TEXT_BITS_PER_CHAR = 7

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
    for _ in range(PREAMBLE_LENGTH // 32):
        out.append(0xAAAAAAAA)
    start = len(out)
    out.append(SYNC)
    offset = address_offset(address)
    for _ in range(offset):
        out.append(IDLE)
    addr_data = ((address >> 3) << 2) | FUNCTION_ALPHANUMERIC
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
    with wave.open(out_path, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sample_rate)
        w.writeframes(data)
    print(f"OK: {out_path} ({baud} bps, {sample_rate} Hz, {len(codewords)} cw)")
    return 0

if __name__ == "__main__":
    sys.exit(main())