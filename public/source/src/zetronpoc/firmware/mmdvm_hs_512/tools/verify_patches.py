#!/usr/bin/env python3
"""
verify_patches.py - Verifica que los 3 patches quedaron aplicados correctamente
en el source del MMDVM_HS clonado.

Uso:
    verify_patches.py [MMDVM_HS_DIR]   # default: ../MMDVM_HS (relativo a tools/)
"""
import os
import sys


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except FileNotFoundError:
        return None


def check(label, condition, detail=""):
    status = "OK" if condition else "FAIL"
    print("  [%s] %s%s" % (status, label, (" - " + detail) if detail else ""))
    return condition


def main():
    default = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "MMDVM_HS"))
    src = sys.argv[1] if len(sys.argv) > 1 else default
    src = os.path.abspath(src)

    print("Verificando patches en: %s" % src)
    print()

    all_ok = True

    # --- Config.h ---
    config = read(os.path.join(src, "Config.h"))
    if config is None:
        check("Config.h existe", False)
        return 1
    all_ok &= check("Config.h: NANO_HOTSPOT definido", "#define NANO_HOTSPOT" in config)
    all_ok &= check("Config.h: LIBRE_KIT_ADF7021 NO definido",
                    "#define LIBRE_KIT_ADF7021" not in config or
                    "// #define LIBRE_KIT_ADF7021" in config)
    all_ok &= check("Config.h: STM32_USART1_HOST definido", "#define STM32_USART1_HOST" in config)
    all_ok &= check("Config.h: STM32_USB_HOST NO definido",
                    "#define STM32_USB_HOST" not in config or
                    "// #define STM32_USB_HOST" in config)
    all_ok &= check("Config.h: ADF7021_14_7456 definido", "#define ADF7021_14_7456" in config)
    all_ok &= check("Config.h: DUPLEX definido", "#define DUPLEX" in config)

    # --- IO.h ---
    io = read(os.path.join(src, "IO.h"))
    if io is None:
        check("IO.h existe", False)
        return 1
    all_ok &= check("IO.h: VHF1_MAX extendido a 150 MHz",
                    "150000000" in io and "#if defined(POCSAG_149MHZ)" in io)

    # --- ADF7021.h ---
    adf = read(os.path.join(src, "ADF7021.h"))
    if adf is None:
        check("ADF7021.h existe", False)
        return 1
    all_ok &= check("ADF7021.h: REG3 POCSAG 512 baud (0x2A4F8513)",
                    "0x2A4F8513" in adf and "#if defined(POCSAG_512)" in adf)
    all_ok &= check("ADF7021.h: fallback 1200 baud preservado (0x2A4F0093)",
                    "0x2A4F0093" in adf)

    # --- STM32F10X_Lib submodule ---
    lib_path = os.path.join(src, "STM32F10X_Lib")
    all_ok &= check("STM32F10X_Lib submodule presente", os.path.isdir(lib_path))

    print()
    if all_ok:
        print("=== Todos los patches verificados correctamente ===")
        return 0
    else:
        print("=== ALGUNOS PATCHES NO ESTAN APLICADOS ===")
        print("    Revisa el output arriba y vuelve a correr clone_and_patch.sh")
        return 1


if __name__ == "__main__":
    sys.exit(main())