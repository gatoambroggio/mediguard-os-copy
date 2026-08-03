#!/usr/bin/env python3
"""AGI handler - procesa llamadas del IVR y encola mensajes POCSAG."""
import sys, os, subprocess, traceback, time
sys.path.insert(0, "/opt/pocsag-server")
from database.db_manager import resolver_destino, registrar_bitacora, encolar_mensaje, get_config

AUDIO_DIR = "/opt/pocsag-server/audio"
PTT_ON = "/opt/pocsag-server/scripts/ptt_on.sh"
PTT_OFF = "/opt/pocsag-server/scripts/ptt_off.sh"
ENCODER = "/opt/pocsag-server/encoder/pocsag_gen.py"

def log(msg):
    os.makedirs("/opt/pocsag-server/logs",exist_ok=True)
    with open("/opt/pocsag-server/logs/pocsag.log","a") as f: f.write(f"[AGI] {msg}\n")

def fail():
    subprocess.run([PTT_OFF], check=False)
    sys.stdout.write("SET VARIABLE AGISTATUS FAILURE\n"); sys.stdout.flush(); sys.exit(1)

def main():
    try:
        interno = sys.argv[1] if len(sys.argv)>1 else "unknown"
        codigo = sys.argv[2] if len(sys.argv)>2 else ""
        mensaje = sys.argv[3] if len(sys.argv)>3 else ""
        if not codigo: fail()
        dest = resolver_destino(codigo)
        if not dest: log(f"Codigo no encontrado: {codigo}"); fail()
        caps, baudios, tipo = dest
        if os.environ.get("POCSAG_WORKER") != "1":
            qid = encolar_mensaje(codigo, caps, mensaje, baudios, interno)
            sys.stdout.write("SET VARIABLE AGISTATUS SUCCESS\n"); sys.stdout.flush()
            log(f"Mensaje encolado (IVR) id={qid} interno={interno} codigo={codigo} msg={mensaje}")
            return
        cap_list = [c.strip() for c in caps.split(",") if c.strip()]
        test_mode = get_config("test_mode","1") == "1"
        ptt_preactivo = float(get_config("ptt_preactivo","0.5"))
        os.makedirs(AUDIO_DIR, exist_ok=True)
        if test_mode:
            for cap in cap_list:
                registrar_bitacora(interno, codigo, cap, mensaje, baudios, "enviado", "modo test")
            sys.stdout.write("SET VARIABLE AGISTATUS SUCCESS\n"); sys.stdout.flush()
            log(f"Envio OK (TEST) interno={interno} codigo={codigo} caps={caps} msg={mensaje}")
            return
        wavs = []
        for cap in cap_list:
            wav = os.path.join(AUDIO_DIR, f"out_{cap}.wav")
            rc = subprocess.run([sys.executable, ENCODER, cap, mensaje, str(baudios), wav], capture_output=True, text=True)
            if rc.returncode != 0:
                log(f"Encoder fallo para {cap}: {rc.stderr}")
                registrar_bitacora(interno, codigo, cap, mensaje, baudios, "error", "encoder")
                fail()
            wavs.append(wav)
        subprocess.run([PTT_ON], check=True)
        time.sleep(ptt_preactivo)
        for wav in wavs:
            subprocess.run(["aplay","-q",wav], check=True)
        subprocess.run([PTT_OFF], check=True)
        for cap in cap_list:
            registrar_bitacora(interno, codigo, cap, mensaje, baudios, "enviado")
        sys.stdout.write("SET VARIABLE AGISTATUS SUCCESS\n"); sys.stdout.flush()
        log(f"Envio OK interno={interno} codigo={codigo} caps={caps} tipo={tipo} msg={mensaje}")
    except Exception as e:
        log(f"Excepcion: {e}\n{traceback.format_exc()}"); fail()

if __name__ == "__main__": main()