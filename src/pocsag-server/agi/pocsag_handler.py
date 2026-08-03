#!/usr/bin/env python3
"""
agi/pocsag_handler.py - AGI de Asterisk para paginación POCSAG.

Uso desde el dialplan:
    AGI(pocsag_handler.py,${CALLERID(num)},${CODE},${MESSAGE})

Lee variables AGI por stdin, resuelve el destino, codifica POCSAG,
activa PTT, reproduce el audio hacia el transmisor y registra en bitácora.
"""
import sys
import os
import subprocess
import traceback

sys.path.insert(0, "/opt/pocsag-server")
from database.db_manager import resolver_codigo, registrar_bitacora  # noqa: E402

CONFIG = "/opt/pocsag-server/config/server.conf"
AUDIO_DIR = "/opt/pocsag-server/audio"
PTT_ON = "/opt/pocsag-server/scripts/ptt_on.sh"
PTT_OFF = "/opt/pocsag-server/scripts/ptt_off.sh"
ENCODER = "/opt/pocsag-server/encoder/pocsag_gen.py"


def agi_get(var):
    """Lee una variable AGI desde stdin (protocolo AGI)."""
    sys.stdout.write(f'GET VARIABLE {var}\n')
    sys.stdout.flush()
    return sys.stdin.readline().strip()


def log(msg):
    with open("/opt/pocsag-server/logs/pocsag.log", "a") as f:
        f.write(f"[AGI] {msg}\n")


def fail():
    sys.stdout.write("SET VARIABLE AGISTATUS FAILURE\n")
    sys.stdout.flush()
    sys.exit(0)


def main():
    try:
        interno = sys.argv[1] if len(sys.argv) > 1 else "unknown"
        codigo = sys.argv[2] if len(sys.argv) > 2 else ""
        mensaje = sys.argv[3] if len(sys.argv) > 3 else ""

        if not codigo or not mensaje:
            log(f"Datos incompletos: interno={interno} codigo={codigo} mensaje={mensaje}")
            fail()

        destino = resolver_codigo(codigo)
        if not destino:
            log(f"Código no encontrado o inactivo: {codigo}")
            fail()

        cap_code, baudios, tipo = destino
        wav = os.path.join(AUDIO_DIR, f"out_{cap_code}.wav")

        # Codificar POCSAG
        rc = subprocess.run(
            [sys.executable, ENCODER, cap_code, mensaje, str(baudios), wav],
            capture_output=True, text=True,
        )
        if rc.returncode != 0:
            log(f"Encoder falló: {rc.stderr}")
            registrar_bitacora(interno, codigo, cap_code, mensaje, baudios, "error",
                               observaciones="encoder")
            fail()

        # Activar PTT + reproducir audio hacia el transmisor
        subprocess.run([PTT_ON], check=True)
        subprocess.run(["aplay", "-q", wav], check=True)
        subprocess.run([PTT_OFF], check=True)

        registrar_bitacora(interno, codigo, cap_code, mensaje, baudios, "enviado")
        sys.stdout.write("SET VARIABLE AGISTATUS SUCCESS\n")
        sys.stdout.flush()
        log(f"Envío OK interno={interno} codigo={codigo} cap={cap_code} msg={mensaje}")

    except Exception as e:
        log(f"Excepción: {e}\n{traceback.format_exc()}")
        fail()


if __name__ == "__main__":
    main()