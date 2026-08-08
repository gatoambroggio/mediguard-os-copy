#!/usr/bin/env python3
"""pocsag_handler.py - AGI POCSAG (ZetronPOC v2.0).
Sin POCSAG_WORKER (lo llama el IVR): encola el mensaje y retorna rapido.
Con POCSAG_WORKER=1 (lo llama el worker de cola): transmite por la placa MMDVM
via RemoteCommand (TCP), sin audio/WAV/GPIO. test_mode=1: solo registra en
bitacora como enviado."""
import sys, os, subprocess, datetime, time
APP_DIR = os.environ.get("ZETRONPOC_DIR", "/opt/zetronpoc")
sys.path.insert(0, APP_DIR)
sys.path.insert(0, os.path.join(APP_DIR, "database"))
from db_manager import (resolver_destino, registrar_bitacora, encolar_mensaje, get_config,
                        actualizar_bitacora_envio, marcar_bitacora_error)

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
    qid_raw = sys.argv[4] if len(sys.argv) > 4 else ""
    try:
        qid = int(qid_raw) if qid_raw else None
    except ValueError:
        qid = None
    worker = os.environ.get("POCSAG_WORKER") == "1"
    if not codigo or not mensaje:
        log("Falta codigo o mensaje (worker=%s)" % worker)
        if worker: sys.exit(1)
        set_result(False); return
    dest = resolver_destino(codigo)
    if not dest:
        if worker and qid:
            marcar_bitacora_error(qid, "codigo inexistente")
        else:
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

    # --- Worker: transmitir SOLO por MMDVM (RemoteCommand, sin audio/PTT) ---
    test_mode = get_config("test_mode", "1") == "1"
    if test_mode:
        for cap in cap_list:
            if qid:
                actualizar_bitacora_envio(qid, cap, "enviado", "modo test")
            else:
                registrar_bitacora(interno, codigo, cap, mensaje, baudios, "enviado", "modo test")
        log("Envio OK (TEST) codigo=%s caps=%s msg=%s" % (codigo, caps, mensaje))
        return
    port = (get_config("mmdvm_remote_port", "7642") or "7642").strip() or "7642"
    rc_bin = get_config("mmdvm_remote_cmd", "/usr/local/bin/RemoteCommand")
    obs = []
    for cap in cap_list:
        try:
            r = subprocess.run([rc_bin, port, "page", cap, mensaje],
                               capture_output=True, text=True, timeout=15)
            if r.returncode == 0:
                if qid:
                    actualizar_bitacora_envio(qid, cap, "enviado", "")
                else:
                    registrar_bitacora(interno, codigo, cap, mensaje, baudios, "enviado", "")
            else:
                err = "RemoteCommand: %s" % (r.stderr or r.stdout or "").strip()[:80]
                if qid:
                    actualizar_bitacora_envio(qid, cap, "error", err)
                else:
                    registrar_bitacora(interno, codigo, cap, mensaje, baudios, "error", err)
                obs.append("%s: %s" % (cap, err))
        except FileNotFoundError:
            err = "RemoteCommand no instalado"
            if qid:
                actualizar_bitacora_envio(qid, cap, "error", err)
            else:
                registrar_bitacora(interno, codigo, cap, mensaje, baudios, "error", err)
            obs.append("%s: %s" % (cap, err))
        except Exception as e:
            err = "excepcion: %s" % str(e)[:80]
            if qid:
                actualizar_bitacora_envio(qid, cap, "error", err)
            else:
                registrar_bitacora(interno, codigo, cap, mensaje, baudios, "error", err)
            obs.append("%s: %s" % (cap, err))
    obs_txt = "; ".join(obs)
    log("Envio MMDVM codigo=%s caps=%s port=%s msg=%s obs=%s" % (codigo, caps, port, mensaje, obs_txt or "ok"))

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log("Excepcion: %s" % e)
        fail()