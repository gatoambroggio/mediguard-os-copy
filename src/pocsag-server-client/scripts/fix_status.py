#!/usr/bin/env python3
"""
fix_status.py - Hotfix para corregir estado_registros_api() en app.py ya desplegado.
El patch_client.py original busca "3000" como token suelto en la salida de
"pjsip show registrations", pero la salida real tiene "reg-3000/sip:3000@IP".
Resultado: el panel siempre muestra "No registrado" (rojo) aun cuando Asterisk
siempre tiene los internos registrados.

Este script reemplaza el parser por uno que busca "reg-3000" o ":3000@" en
cada linea, que es como Asterisk realmente imprime los registros.

Uso:
    sudo python3 fix_status.py
Luego:
    sudo systemctl restart pocsag-api
"""
import re

APP = "/opt/pocsag-server/backend/app.py"

OLD = """        for line in (r.stdout or "").splitlines():
            toks=set(line.split())
            for n in activos:
                if n in toks and "Registered" in line: out[n]="Registered\""""

NEW = """        for line in (r.stdout or "").splitlines():
            if "Registered" not in line: continue
            for n in activos:
                if ("reg-%s"%n) in line or (":%s@"%n) in line: out[n]="Registered\""""

try:
    with open(APP, encoding="utf-8") as f:
        src = f.read()
except FileNotFoundError:
    print("[ERR] %s no existe. Corrio instalador.sh?" % APP)
    raise SystemExit(1)

if NEW.strip() in src:
    print("[OK] Ya tiene el parser corregido. Nada que hacer.")
    raise SystemExit(0)

if OLD not in src:
    # intentar variante con espacios distintos
    pattern = r"toks=set\(line\.split\(\)\)\s*\n\s*for n in activos:\s*\n\s*if n in toks and \"Registered\" in line: out\[n\]=\"Registered\""
    if re.search(pattern, src):
        src2 = re.sub(
            pattern,
            'if "Registered" not in line: continue\n            for n in activos:\n                if ("reg-%s"%n) in line or (":%s@"%n) in line: out[n]="Registered"',
            src,
        )
        with open(APP, "w", encoding="utf-8") as f:
            f.write(src2)
        print("[OK] Parser corregido (via regex). Reinicia pocsag-api.")
        raise SystemExit(0)
    print("[WARN] No se encontro el patron viejo. Quizas ya esta corregido o el formato cambio.")
    raise SystemExit(0)

src2 = src.replace(OLD, NEW, 1)
with open(APP, "w", encoding="utf-8") as f:
    f.write(src2)
print("[OK] Parser de estado de registro corregido en %s" % APP)
print("     Reinicia con:  sudo systemctl restart pocsag-api")