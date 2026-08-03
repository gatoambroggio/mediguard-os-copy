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

    # --- Worker: transmitir ---
    test_mode = get_config("test_mode", "1") == "1"
    pre = float(get_config("ptt_preactivo", "0.5"))
    os.makedirs(AUDIO_DIR, exist_ok=True)
    if test_mode:
        for cap in cap_list:
            registrar_bitacora(interno, codigo, cap, mensaje, baudios, "enviado", "modo test")
        log("Envio OK (TEST) codigo=%s caps=%s msg=%s" % (codigo, caps, mensaje))
        return
    wavs = []
    for cap in cap_list:
        wav = os.path.join(AUDIO_DIR, "out_%s.wav" % cap)
        rc = subprocess.run([sys.executable, ENCODER, cap, mensaje, str(baudios), wav],
                            capture_output=True, text=True, timeout=60)
        if rc.returncode != 0 or not os.path.exists(wav):
            log("Encoder fallo para %s: %s" % (cap, (rc.stderr or rc.stdout or "")[:120]))
            registrar_bitacora(interno, codigo, cap, mensaje, baudios, "error", "encoder")
            fail()
        wavs.append(wav)
    obs = []
    try:
        subprocess.run([PTT_ON], capture_output=True, timeout=5)
        time.sleep(pre)
        for wav in wavs:
            r = subprocess.run(["aplay", "-q", wav], capture_output=True, text=True, timeout=30)
            if r.returncode != 0:
                obs.append("aplay: %s" % (r.stderr or "").strip()[:80])
        subprocess.run([PTT_OFF], capture_output=True, timeout=5)
    except Exception as e:
        obs.append("excepcion: %s" % str(e)[:80])
    obs_txt = "; ".join(obs)
    for cap in cap_list:
        registrar_bitacora(interno, codigo, cap, mensaje, baudios, "enviado", obs_txt)
    log("Envio OK codigo=%s caps=%s msg=%s obs=%s" % (codigo, caps, mensaje, obs_txt or "ok"))

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log("Excepcion: %s" % e)
        fail()