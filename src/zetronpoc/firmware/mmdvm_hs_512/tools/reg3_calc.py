#!/usr/bin/env python3
"""
reg3_calc.py - Recalcula R3 (Clock Register) del ADF7021 para otro baud POCSAG.

Datasheet ADF7021, Register 3 (Transmit/Receive Clock Register):
    DEMOD_CLK = XTAL / DEMOD_CLK_DIVIDE      (R3 bits DB9:DB6,  4 bits, 1..15)
    CDR_CLK   = DEMOD_CLK / CDR_CLK_DIVIDE    (R3 bits DB17:DB10, 8 bits, 1..255)
    CDR_CLK debe ser ~32 x baud  (dentro de 2%)

Restricciones:
    2 MHz <= DEMOD_CLK <= XTAL
    1 <= DEMOD_CLK_DIVIDE <= 15 ; 1 <= CDR_CLK_DIVIDE <= 255
    producto DEMOD_CLK_DIVIDE x CDR_CLK_DIVIDE = XTAL / (32 x baud)

Mantiene todos los demas campos de R3 intactos (AGC, sequencer, BB offset,
address) y reemplaza solo los dos dividers. Por eso funciona para cualquier
variante de TCXO: le pasas el R3 de 1200 que ya tenes en tu ADF7021.h.

Uso:
    reg3_calc.py <r3_baseline_hex> <xtal_hz> <target_baud>

Ejemplos:
    reg3_calc.py 0x2A4F0093 14745600 512   # ZumSpot/Jumbospot 14.7456 MHz
    reg3_calc.py 0x29EE8093 12288000 512   # 12.2880 MHz
"""
import sys

DEMOD_MASK  = 0xF    # 4 bits
DEMOD_SHIFT = 6      # DB9:DB6
CDR_MASK    = 0xFF   # 8 bits
CDR_SHIFT   = 10     # DB17:DB10

def extract(r3):
    demod = (r3 >> DEMOD_SHIFT) & DEMOD_MASK
    cdr   = (r3 >> CDR_SHIFT)   & CDR_MASK
    return demod, cdr

def replace(r3, demod, cdr):
    r3 &= ~(DEMOD_MASK << DEMOD_SHIFT)
    r3 &= ~(CDR_MASK   << CDR_SHIFT)
    r3 |= (demod & DEMOD_MASK) << DEMOD_SHIFT
    r3 |= (cdr   & CDR_MASK)   << CDR_SHIFT
    return r3 & 0xFFFFFFFF

def find_dividers(xtal, baud):
    """Busca (DEMOD_CLK_DIVIDE, CDR_CLK_DIVIDE) enteros que cumplan las
    restricciones y minimicen el error vs 32x baud; empata por DEMOD_CLK mas alto."""
    target = xtal / (32.0 * baud)            # producto DEMOD x CDR
    best = None
    for demod in range(1, 16):
        demod_clk = xtal / demod
        if demod_clk < 2_000_000:            # DEMOD_CLK >= 2 MHz
            continue
        cdr = target / demod
        cdr_i = round(cdr)
        if cdr_i < 1 or cdr_i > 255:
            continue
        cdr_clk = demod_clk / cdr_i
        err = abs(cdr_clk - 32 * baud) / (32 * baud)
        score = (err, -demod_clk)
        if best is None or score < best[0]:
            best = (score, demod, cdr_i, err)
    return best

def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)
    r3   = int(sys.argv[1], 0)
    xtal = int(sys.argv[2])
    baud = int(sys.argv[3])

    demod0, cdr0 = extract(r3)
    demod_clk0 = xtal / demod0
    cdr_clk0   = demod_clk0 / cdr0
    baud0      = cdr_clk0 / 32.0

    print("Baseline R3 = 0x%08X" % r3)
    print("  DEMOD_CLK_DIVIDE = %d  -> DEMOD_CLK = %d Hz" % (demod0, round(demod_clk0)))
    print("  CDR_CLK_DIVIDE   = %d  -> CDR_CLK   = %d Hz" % (cdr0, round(cdr_clk0)))
    print("  baud inferido    = %.1f  (esperado 1200)" % baud0)

    res = find_dividers(xtal, baud)
    if res is None:
        print("\nNo se encontro combinacion valida para %d baud con XTAL %d Hz" % (baud, xtal))
        print("(CDR_CLK_DIVIDE se pasa de 255 o DEMOD_CLK < 2 MHz). Proba otro XTAL.")
        sys.exit(2)

    _, demod, cdr, err = res
    r3_new   = replace(r3, demod, cdr)
    demod_clk = xtal / demod
    cdr_clk   = demod_clk / cdr

    print("\nTarget %d baud:" % baud)
    print("  DEMOD_CLK_DIVIDE = %d  -> DEMOD_CLK = %d Hz" % (demod, round(demod_clk)))
    print("  CDR_CLK_DIVIDE   = %d  -> CDR_CLK   = %d Hz  (32x%d=%d)" % (cdr, round(cdr_clk), baud, 32 * baud))
    print("  error vs 32x baud = %.4f%%" % (err * 100))
    print("\n  NUEVO R3 = 0x%08X" % r3_new)
    print("  (reemplaza #define ADF7021_REG3_POCSAG en ADF7021.h)")

if __name__ == "__main__":
    main()