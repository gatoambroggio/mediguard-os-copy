#!/usr/bin/env python3
"""
dispatch_mqtt.py - Envío de POCSAG via MQTT a MMDVMHost (RemoteControl).
Reemplaza a dispatch_serial.py: en lugar de hablar el protocolo binario
MMDVM por serial, publica el comando "page <cap> <mensaje>" en el topic
MQTT que MMDVMHost escucha (Name=host -> topic "host/command").

Uso: dispatch_mqtt.py [--bcd] <cap_code(s)> <mensaje> [baudios]
  --bcd       : modo numerico (page_bcd) en vez de alfanumerico (page)
  cap_code(s) : un cap_code o varios separados por coma (para grupos)
"""
import sys, os, subprocess, time, socket

APP_DIR = os.environ.get("ZETRONPOC_DIR", "/opt/zetronpoc")
sys.path.insert(0, APP_DIR)
sys.path.insert(0, os.path.join(APP_DIR, "database"))
from db_manager import get_config

LOG = os.path.join(APP_DIR, "logs", "dispatch_mqtt.log")

# Config MQTT — leido de la BD (debe coincidir con [MQTT] de MMDVM.ini)
def _mqtt_cfg():
    host = get_config("mmdvm_mqtt_host", "127.0.0.1")
    port = int(get_config("mmdvm_mqtt_port", "1883") or "1883")
    name = get_config("mmdvm_mqtt_name", "host")
    return host, port, "%s/command" % name


def log(m):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S") + " | " + m + "\n")
    except Exception:
        pass


def _remote_cfg():
    host = "127.0.0.1"
    port = int(get_config("mmdvm_remote_port", "7642") or "7642")
    return host, port

def publish_page(cap, message, bcd=False):
    """Envia 'page <cap> <msg>' al socket RemoteControl TCP de MMDVMHost
    (mas confiable que MQTT: no depende de mosquitto ni de [MQTT] Enable).
    Cae a MQTT si el socket no responde. Siempre usa 'page' (alfanumerico):
    page_bcd no prende el PTT en versiones legacy de MMDVMHost."""
    cmd_word = "page"
    payload = "%s %s %s\n" % (cmd_word, str(cap).zfill(7), message)
    rc_host, rc_port = _remote_cfg()
    # --- intento 1: TCP RemoteControl (nativo de MMDVMHost) ---
    try:
        s = socket.create_connection((rc_host, rc_port), timeout=3)
        s.sendall(payload.encode("utf-8", "replace"))
        s.settimeout(0.5)
        resp = b""
        end = time.time() + 2.0
        while time.time() < end:
            try:
                d = s.recv(4096)
                if not d:
                    break
                resp += d
            except socket.timeout:
                if resp:
                    break
        s.close()
        rtxt = resp.decode("utf-8", "replace").strip()
        log("RemoteControl TCP %s:%s -> %r | resp=%r" % (rc_host, rc_port, payload.strip(), rtxt[:200]))
        low = rtxt.lower()
        if "ko" in low or "invalid" in low or "nak" in low:
            log("RemoteControl RECHAZO: %s" % rtxt[:200])
            return False
        return True
    except Exception as e:
        log("RemoteControl TCP no disponible (%s); cae a MQTT" % str(e)[:120])
    # --- intento 2: MQTT (fallback) ---
    host, port, topic = _mqtt_cfg()
    mqtt_payload = "%s %s %s" % (cmd_word, str(cap).zfill(7), message)
    cmd = ["mosquitto_pub", "-h", host, "-p", str(port), "-t", topic, "-m", mqtt_payload]
    log("MQTT pub (fallback): %s" % " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    if r.returncode != 0:
        log("ERROR mosquitto_pub: %s" % (r.stderr or r.stdout).strip()[:200])
        return False
    log("MQTT OK cap=%s msg=%s" % (cap, message))
    return True


def main():
    raw = list(sys.argv[1:])
    bcd = "--bcd" in raw
    args = [a for a in raw if a != "--bcd"]
    if len(args) < 2:
        print("Uso: dispatch_mqtt.py [--bcd] <cap_code(s)> <mensaje> [baudios]")
        print("  --bcd : pagina en modo numerico (page_bcd) en vez de alfanumerico (page)")
        sys.exit(1)

    caps_str = str(args[0])
    cap_list = [c.strip() for c in caps_str.split(",") if c.strip()]
    message = str(args[1])

    if not cap_list:
        log("ERROR: no hay cap codes validos")
        print("ERROR: cap codes invalidos")
        sys.exit(1)

    # BCD solo acepta digitos. Si el mensaje trae otra cosa (texto libre),
    # page_bcd seria invalido y MMDVMHost lo descarta sin transmitir pero
    # mosquitto_pub devuelve 0 -> la bitacora quedaria "enviado" sin salir al aire.
    # En ese caso caemos a modo alfanumerico (page) y lo dejamos asentado en el log.
    if bcd and not message.isdigit():
        log("WARN: --bcd solicitado pero mensaje no numerico (%r) -> cae a page (alfanumerico)" % message)
        bcd = False

    log("=== Envio MQTT ===")
    log("caps=%s msg=%r bcd=%s" % (cap_list, message, bcd))

    sent = 0
    for cap in cap_list:
        try:
            cap_int = int(cap)
        except ValueError:
            log("ERROR cap invalido: %s" % cap)
            continue
        if publish_page(cap_int, message, bcd=bcd):
            sent += 1
        # Pausa entre caps para no saturar el modulo
        if len(cap_list) > 1:
            time.sleep(2.0)

    log("Envio completado: %d/%d cap(s)" % (sent, len(cap_list)))
    print("OK: %d/%d cap(s) via MMDVM (RemoteControl TCP)" % (sent, len(cap_list)))
    if sent == 0:
        sys.exit(1)


if __name__ == "__main__":
    main()