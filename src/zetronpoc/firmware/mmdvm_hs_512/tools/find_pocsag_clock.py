#!/usr/bin/env python3
"""
find_pocsag_clock.py - Localiza el bit-clock de POCSAG en el source del MMDVM_HS.

EL DIAGNOSTICO (probado):
  El baud de TX de POCSAG en el MMDVM_HS lo fija el STM32: la ISR CIO::interrupt()
  drena m_txBuffer al pin TXD del ADF7021 a la sample-rate del timer. El registro
  R3 (ADF7021_REG3_POCSAG) es el clock de RECUPERACION DE RX (CDR_CLK); NO cambia
  el baud de TX. Por eso el flag POCSAG_512 que solo toca R3 no resolvio nada.

  Este script escanea el source clonado y te muestra DONDE y COMO se define ese
  bit-clock, con numeros de linea, para parchearlo a 512 baud sin adivinar.

Uso:
    find_pocsag_clock.py [MMDVM_HS_DIR]   # default: ../MMDVM_HS (relativo a tools/)
"""
import os
import sys
import re


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().splitlines()
    except FileNotFoundError:
        return None


def extract_fn(lines, name):
    """Extrae la funcion miembro `name` (ej 'void CIO::interrupt(') por balance de llaves."""
    start = None
    for i, l in enumerate(lines):
        if name in l:
            # la llave puede estar en la misma linea o en la siguiente
            if "{" in l:
                start = i
                break
            if i + 1 < len(lines) and "{" in lines[i + 1]:
                start = i
                break
    if start is None:
        return None
    j = start
    buf = []
    depth = 0
    seen = False
    while j < len(lines):
        buf.append(lines[j])
        for ch in lines[j]:
            if ch == "{":
                depth += 1
                seen = True
            elif ch == "}":
                depth -= 1
                if seen and depth == 0:
                    return (start, j, buf)
        j += 1
    return (start, j, buf)


def show(title, region):
    print("\n" + "=" * 72)
    print(title)
    print("=" * 72)
    if region is None:
        print("  (no encontrado)")
        return
    s, _, buf = region
    for k, l in enumerate(buf):
        print("%5d: %s" % (s + 1 + k, l))


def grep_pocsag(lines, fname, limit=50):
    hits = [(i + 1, l) for i, l in enumerate(lines) if re.search(r"POCSAG|pocsag", l)]
    if not hits:
        return
    print("\n--- %s: lineas con 'POCSAG' (%d) ---" % (fname, len(hits)))
    for n, l in hits[:limit]:
        print("%5d: %s" % (n, l.rstrip()))
    if len(hits) > limit:
        print("  ... +%d mas" % (len(hits) - limit))


def find_candidates(lines, fname):
    pats = [
        r"POCSAG_\w*SYMBOL\w*",
        r"POCSAG_\w*LENGTH\w*",
        r"POCSAG_\w*BIT\w*",
        r"POCSAG_\w*BAUD\w*",
        r"POCSAG_\w*SAMPLE\w*",
        r"RADIO_SYMBOL_LENGTH",
        r"SAMPLE_RATE",
        r"SAMPLES_PER_BIT",
    ]
    found = []
    for i, l in enumerate(lines):
        for p in pats:
            if re.search(p, l):
                found.append((i + 1, l.rstrip(), p))
                break
    if found:
        print("\n[%s] constantes candidatas a samples-per-bit / baud:" % fname)
        for n, l, sym in found:
            print("%5d: %s   <- %s" % (n, l, sym))


def main():
    default = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "MMDVM_HS"))
    src = sys.argv[1] if len(sys.argv) > 1 else default
    src = os.path.abspath(src)

    print("######## POCSAG BIT-CLOCK REPORT ########")
    print("Source: %s" % src)
    if not os.path.isdir(src):
        print("ERROR: no existe el dir. Corre clone_and_patch.sh primero para clonar MMDVM_HS.")
        sys.exit(1)

    io = read(os.path.join(src, "IO.cpp"))
    ptx = read(os.path.join(src, "POCSAGTX.cpp"))
    pdef = read(os.path.join(src, "POCSAGDefines.h"))
    adf = read(os.path.join(src, "ADF7021.cpp"))

    if io is None:
        print("ERROR: no encontre IO.cpp en %s" % src)
        sys.exit(1)

    show("CIO::interrupt()  <- ISR del timer: drena m_txBuffer a TXD (ACA esta el baud)",
         extract_fn(io, "void CIO::interrupt("))
    show("CIO::startInt()   <- setup del timer (base rate / sample rate del modem)",
         extract_fn(io, "void CIO::startInt("))
    show("CIO::ifConf()     <- config del ADF7021 por modo (buscar分支 STATE_POCSAG)",
         extract_fn(io, "void CIO::ifConf("))
    show("CPOCSAGTX::writeByte() <- como se escriben los bits a io (1 bit por io.write)",
         extract_fn(ptx, "void CPOCSAGTX::writeByte(") if ptx else None)

    print("\n" + "=" * 72)
    print("Constantes candidatas a samples-per-bit / baud divider")
    print("=" * 72)
    for fname, lines in [("IO.cpp", io), ("POCSAGTX.cpp", ptx),
                        ("POCSAGDefines.h", pdef), ("ADF7021.cpp", adf)]:
        if lines:
            find_candidates(lines, fname)

    grep_pocsag(io, "IO.cpp")
    if adf:
        grep_pocsag(adf, "ADF7021.cpp (ifConf STATE_POCSAG)")

    print("\n" + "=" * 72)
    print("PROXIMO PASO")
    print("=" * 72)
    print("1) Busca arriba la linea que fija el samples-per-bit de POCSAG, o el")
    print("   divider del timer para STATE_POCSAG en interrupt()/ifConf().")
    print("2) Anota la BASE RATE del timer (sample rate en startInt).")
    print("3) Pasaeme esos dos datos (linea + base rate) y te doy el patch exacto:")
    print("     new_samples_per_bit = round(base_rate / 512)")
    print("   envuelto en #if defined(POCSAG_512) / #else para fallback a 1200.")
    print("4) NO toques R3 (ADF7021_REG3_POCSAG): es clock de RX, no el baud de TX.")


if __name__ == "__main__":
    main()