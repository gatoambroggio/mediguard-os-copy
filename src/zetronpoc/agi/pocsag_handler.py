#!/usr/bin/env python3
"""pocsag_handler.py - AGI POCSAG (ZetronPOC v2.0).
Sin POCSAG_WORKER (lo llama el IVR): encola el mensaje y retorna rapido.
Con POCSAG_WORKER=1 (lo llama el worker de cola): genera el WAV y transmite.
test_mode=1: solo registra en bitacora como enviado (sin PTT/GPIO), igual que
el proyecto de referencia pocsag-server-client."""
import sys, os, subprocess, datetime, time
APP_DIR = os.environ.get("ZETRONPOC_DIR", "/opt/zetronpoc")
sys.path.insert(0, APP_DIR)
sys.path.insert(0, os.path.join(APP_DIR, "database"))
from db_manager import resolver_destino, registrar_bitacora, encolar_mensaje, get_config

ENCODER = os.path.join(APP_DIR, "encoder/pocsag_gen.py")
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
    set_result(False); sys.exit(1)

def main():
    interno = sys.argv[1] if len(sys.argv) > 1 else ""
    codigo = sys.argv[2] if len(sys.argv) > 2 else ""
    mensaje = sys.argv[3] if len(sys.argv) > 3 else ""
    worker = os.environ.get("POCSAG_WORKER") == "1"
    if not codigo or not mensaje:
        log("Falta codigo o mensaje (worker=%s)" % worker)
        if worker: sys.exit(1)
        set_result(False); return
    dest = resolver_destino(codigo)
    if not dest:
        registrar_bitacora(interno, codigo, "", mensaje, 1200, "error", "codigo inexistente")
        log("Codigo no encontrado: %s" % codigo)
        if worker: sys.exit(1)
        set_result(False); return
    caps, baudios, tipo = dest
    cap_list = [c.strip() for c in str(caps).split(",") if c.strip()]

    # --- IVR: solo encolar, el worker se encarga de transmitir ---
    if not worker:
        qid = encolar_mensaje(codigo, caps, mensaje, baudios, interno)
        set_result(True)
        log("Mensaje encolado (IVR) id=%s interno=%s codigo=%s msg=%s" % (qid, interno, codigo, mensaje))
        return

    # --- Worker: generar WAV POCSAG 512 baud (sin transmisor DAPT-X Xtra) ---
    os.makedirs(AUDIO_DIR, exist_ok=True)
    for cap in cap_list:
        wav = os.path.join(AUDIO_DIR, "out_%s.wav" % cap)
        rc = subprocess.run([sys.executable, ENCODER, cap, mensaje, str(baudios), wav],
                            capture_output=True, text=True, timeout=60)
        if rc.returncode != 0 or not os.path.exists(wav):
            log("Encoder fallo para %s: %s" % (cap, (rc.stderr or rc.stdout or "")[:120]))
            registrar_bitacora(interno, codigo, cap, mensaje, baudios, "error", "encoder")
            fail()
    for cap in cap_list:
        registrar_bitacora(interno, codigo, cap, mensaje, baudios, "enviado", "wav generado (sin transmisor)")
    log("Envio OK codigo=%s caps=%s msg=%s (wav generado)" % (codigo, caps, mensaje))

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log("Excepcion: %s" % e)
        fail()