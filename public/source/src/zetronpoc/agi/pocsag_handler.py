#!/usr/bin/env python3
"""pocsag_handler.py - AGI que genera el WAV POCSAG y lo transmite por radio.
test_mode=1: solo genera el WAV y lo reproduce por la tarjeta local (sin PTT/GPIO)."""
import sys, os, subprocess, datetime
APP_DIR = os.environ.get("ZETRONPOC_DIR", "/opt/zetronpoc")
sys.path.insert(0, APP_DIR)
sys.path.insert(0, os.path.join(APP_DIR, "database"))
from db_manager import resolver_destino, registrar_bitacora, get_config

ENCODER = os.path.join(APP_DIR, "encoder/pocsag_gen.py")
PTT_ON = os.path.join(APP_DIR, "scripts/ptt_on.sh")
PTT_OFF = os.path.join(APP_DIR, "scripts/ptt_off.sh")
AUDIO_DIR = os.path.join(APP_DIR, "audio")
LOG = os.path.join(APP_DIR, "logs/cola.log")

def log(m):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            f.write(datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S") + " | " + m + "\n")
    except Exception:
        pass

def set_result(ok):
    sys.stdout.write('SET VARIABLE POCSAG_RESULT "%s"\n' % ("ok" if ok else "fail")); sys.stdout.flush()

def fail():
    try: subprocess.run([PTT_OFF], capture_output=True, timeout=5)
    except Exception: pass

def main():
    interno = sys.argv[1] if len(sys.argv) > 1 else ""
    codigo = sys.argv[2] if len(sys.argv) > 2 else ""
    mensaje = sys.argv[3] if len(sys.argv) > 3 else ""
    if not codigo or not mensaje:
        set_result(False); return
    dest = resolver_destino(codigo)
    if not dest:
        registrar_bitacora(interno, codigo, "", mensaje, 1200, "error", "codigo inexistente")
        set_result(False); return
    caps, baudios, tipo = dest
    test_mode = get_config("test_mode", "0") == "1"
    pre = get_config("ptt_preactivo", "0.5")
    os.makedirs(AUDIO_DIR, exist_ok=True)
    wav = os.path.join(AUDIO_DIR, "msg_%d_%d.wav" % (os.getpid(), int(datetime.datetime.now().timestamp())))
    try:
        rc = subprocess.run([sys.executable, ENCODER, caps, mensaje, str(baudios), wav],
                            capture_output=True, text=True, timeout=60)
        log("encoder rc=%d %s" % (rc.returncode, (rc.stderr or rc.stdout or "")[:120]))
        if rc.returncode != 0 or not os.path.exists(wav):
            registrar_bitacora(interno, codigo, caps, mensaje, baudios, "error", (rc.stderr or rc.stdout or "")[:200])
            set_result(False); return
        if not test_mode:
            subprocess.run([PTT_ON], capture_output=True, timeout=5)
            subprocess.run(["sleep", str(pre)], capture_output=True, timeout=5)
        subprocess.run(["aplay", "-q", wav], capture_output=True, timeout=30)
        if not test_mode:
            subprocess.run([PTT_OFF], capture_output=True, timeout=5)
        registrar_bitacora(interno, codigo, caps, mensaje, baudios, "enviado", "")
        set_result(True)
    except Exception as e:
        fail()
        registrar_bitacora(interno, codigo, caps, mensaje, baudios, "error", str(e)[:200])
        set_result(False)
    finally:
        try:
            if os.path.exists(wav): os.remove(wav)
        except Exception: pass

if __name__ == "__main__":
    main()