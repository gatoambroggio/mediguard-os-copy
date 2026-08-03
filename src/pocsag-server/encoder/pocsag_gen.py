#!/usr/bin/env python3
# Codificador POCSAG 512 baud - Banda base limpia (Discriminador) compatible con multimon-ng.
# Genera WAV mono 16-bit a 22050 Hz (obligatorio para multimon-ng en modo nativo).
#
# Algoritmo BCH(31,21) estandar de POCSAG, polaridad de discriminador:
#   Bit 0 -> amplitud maxima positiva
#   Bit 1 -> amplitud maxima negativa
#
# Uso: pocsag_gen.py <capcode> <mensaje> <baudios> <out.wav>
# Nota: el sistema solo encodea a 512 baud; el argumento <baudios> se ignora.
import sys
import wave
import struct

BAUDIOS = 512
FRECUENCIA_MUESTREO = 22050  # Obligatorio para multimon-ng en modo nativo
AMPLITUD = 16384  # Amplitud media para evitar saturacion de clipping


def calcular_bch_pocsag(datos_21bit):
    """Calcula el codigo de control de errores BCH(31,21) estandar de POCSAG."""
    polinomio_generador = 0x769
    registro = datos_21bit << 10
    for i in range(20, -1, -1):
        if (registro >> (i + 10)) & 1:
            registro ^= (polinomio_generador << i)
    return registro & 0x3FF


def crear_bitstream_pocsag(capcode, mensaje):
    bitstream = []

    # 1. Preambulo estandar: 576 bits alternados (1, 0, 1, 0...)
    for _ in range(288):
        bitstream.extend([1, 0])

    def agregar_palabra(w):
        for idx in range(31, -1, -1):
            bitstream.append((w >> idx) & 1)

    palabra_sync = 0x7CD215D8
    palabra_idle = 0x7A89C197

    # 2. Codificacion del Capcode (Direccion)
    frame_destino = capcode & 7
    bits_direccion = capcode >> 3
    tipo_funcion = 3  # Codigo de funcion 3 (Mensaje Alfanumerico)

    datos_direccion = (bits_direccion << 2) | tipo_funcion
    bch_addr = calcular_bch_pocsag(datos_direccion)
    cw_direccion = (datos_direccion << 11) | (bch_addr << 1)
    if bin(cw_direccion).count('1') % 2 != 0:
        cw_direccion |= 1  # Bit de paridad par

    # 3. Codificacion del Mensaje (ASCII 7 bits - LSB primero)
    bits_mensaje = []
    for caracter in mensaje:
        c_val = ord(caracter)
        for j in range(7):
            bits_mensaje.append((c_val >> j) & 1)

    # Relleno del mensaje para completar bloques exactos de 20 bits
    residuo = len(bits_mensaje) % 20
    if residuo != 0:
        bits_mensaje.extend([0] * (20 - residuo))

    codewords_mensaje = []
    for i in range(0, len(bits_mensaje), 20):
        bloque = bits_mensaje[i:i + 20]

        # En POCSAG los bits dentro del codeword de texto se ordenan (MSB del bloque primero)
        valor_bloque = 0
        for bit in bloque:
            valor_bloque = (valor_bloque << 1) | bit

        datos_msg = (1 << 20) | valor_bloque  # Bit 31 en 1 indica que es palabra de mensaje
        bch_msg = calcular_bch_pocsag(datos_msg)
        cw_msg = (datos_msg << 11) | (bch_msg << 1)
        if bin(cw_msg).count('1') % 2 != 0:
            cw_msg |= 1
        codewords_mensaje.append(cw_msg)

    # 4. Construccion del Lote (Batch) en base al frame de destino
    agregar_palabra(palabra_sync)

    indice_mensaje = 0
    # Creamos un lote completo de 8 frames (16 palabras en total)
    for f in range(8):
        if f == frame_destino:
            agregar_palabra(cw_direccion)
            if indice_mensaje < len(codewords_mensaje):
                agregar_palabra(codewords_mensaje[indice_mensaje])
                indice_mensaje += 1
            else:
                agregar_palabra(palabra_idle)
        else:
            # Si hay mas palabras de mensaje, continuan en los siguientes frames
            if indice_mensaje < len(codewords_mensaje) and f > frame_destino:
                agregar_palabra(codewords_mensaje[indice_mensaje])
                indice_mensaje += 1
                if indice_mensaje < len(codewords_mensaje):
                    agregar_palabra(codewords_mensaje[indice_mensaje])
                    indice_mensaje += 1
                else:
                    agregar_palabra(palabra_idle)
            else:
                agregar_palabra(palabra_idle)
                agregar_palabra(palabra_idle)

    return bitstream


def modular_banda_base(bits):
    """Modulacion de banda base limpia (discriminador) sin numpy/scipy.

    Bit 0 -> amplitud maxima positiva
    Bit 1 -> amplitud maxima negativa
    """
    muestras_por_bit = FRECUENCIA_MUESTREO / BAUDIOS
    total_muestras = int(len(bits) * muestras_por_bit)

    muestras = bytearray()
    for n in range(total_muestras):
        # indice del bit correspondiente a esta muestra
        idx = int(n * BAUDIOS / FRECUENCIA_MUESTREO)
        if idx >= len(bits):
            idx = len(bits) - 1
        valor = AMPLITUD if bits[idx] == 0 else -AMPLITUD
        muestras += struct.pack('<h', valor)
    return bytes(muestras), total_muestras


def main():
    if len(sys.argv) != 5:
        print("Uso: pocsag_gen.py <capcode> <mensaje> <baudios> <out.wav>", file=sys.stderr)
        return 1

    capcode = int(sys.argv[1])
    mensaje = sys.argv[2]
    out_path = sys.argv[4]

    # El sistema solo encodea a POCSAG 512 baud; se ignora el argumento de baudios.
    bitstream = crear_bitstream_pocsag(capcode, mensaje)
    audio, total = modular_banda_base(bitstream)

    with wave.open(out_path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(FRECUENCIA_MUESTREO)
        w.writeframes(audio)

    print(f"OK: {out_path} ({BAUDIOS} bps, {FRECUENCIA_MUESTREO} Hz, {len(bitstream)} bits, {total} muestras)")
    return 0


if __name__ == "__main__":
    sys.exit(main())