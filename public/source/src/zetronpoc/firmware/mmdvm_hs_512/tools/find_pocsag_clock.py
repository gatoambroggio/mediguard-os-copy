#!/usr/bin/env python3
"""
find_pocsag_clock.py - Reporte de diagnóstico del bit-clock de POCSAG en MMDVM_HS.

HALLAZGO CLAVE (verificado en el source):
  El interrupt() del MMDVM_HS es disparado por el CLK output del ADF7021
  (NO por un timer del STM32). El CLK output se configura con REG3
  (ADF7021_REG3_POCSAG). Por lo tanto:

    - Cambiar REG3 (ADF7021.h) → cambia el baud de TX (y RX)
    - NO hace falta parchear el timer del STM32
    - El patch existente de ADF7021.h (R3 512 baud) ES el fix correcto

  El README anterior que decía "R3 es RX-only" estaba equivocado: el ISR
  CIO::interrupt() drena m_txBuffer a TXD en cada flanco de bajada del CLK
  del ADF7021, y lee RXD en cada flanco de subida. El CLK frecuencia =
  baud rate (no 32x ni 20x).

Uso:
    find_pocsag_clock.py [MMDVM_HS_DIR]   # default: ../MMDVM_HS
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
    start = None
    for i, l in enumerate(lines):
        if name in l:
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


def main():
    default = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "MMDVM_HS"))
    src = sys.argv[1] if len(sys.argv) > 1 else default
    src = os.path.abspath(src)

    print("######## POCSAG BIT-CLOCK REPORT ########")
    print("Source: %s" % src)
    if not os.path.isdir(src):
        print("ERROR: no existe el dir. Corre clone_and_patch.sh primero.")
        sys.exit(1)

    adf = read(os.path.join(src, "ADF7021.cpp"))
    io = read(os.path.join(src, "IO.cpp"))
    ioh = read(os.path.join(src, "IO.h"))

    if adf is None:
        print("ERROR: no encontre ADF7021.cpp en %s" % src)
        sys.exit(1)

    show("CIO::interrupt()  <- ISR disparada por CLK del ADF7021 (ACA esta el baud)",
         extract_fn(adf, "void CIO::interrupt("))
    show("CIO::ifConf()     <- config del ADF7021 por modo (branch STATE_POCSAG)",
         extract_fn(adf, "void CIO::ifConf("))

    print("\n" + "=" * 72)
    print("CONCLUSION")
    print("=" * 72)
    print("El interrupt() es disparado por CLK_pin() del ADF7021.")
    print("El CLK output se configura con REG3 (ADF7021_REG3_POCSAG).")
    print("Cambiar REG3 en ADFVM.h = cambiar el baud de TX (y RX).")
    print("NO hace falta parchear el timer del STM32.")
    print()
    print("Patch aplicado (ver patches/ADF7021.h.patch):")
    print("  #if defined(POCSAG_512)")
    print("  #define ADF7021_REG3_POCSAG  0x2A4F8513  // 512 baud")
    print("  #else")
    print("  #define ADF7021_REG3_POCSAG  0x2A4F0093  // 1200 baud (default)")
    print("  #endif")


if __name__ == "__main__":
    main()