#!/usr/bin/env python3
"""
dispatch_mqtt.py - Envío de POCSAG via MQTT a MMDVMHost (RemoteControl).
Reemplaza a dispatch_serial.py: en lugar de hablar el protocolo binario
MMDVM por serial, publica el comando "page <cap> <mensaje>" en el topic
MQTT que MMDVMHost escucha (Name=host -> topic "host/command").

Uso: dispatch_mqtt.py <cap_code(s)> <mensaje> [baudios]
  cap_code(s): un cap_code o varios separados por coma (para grupos)
"""
import sys, os, subprocess, time

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


def publish_page(cap, message):
    """Publica un comando 'page' por MQTT usando mosquitto_pub."""
    host, port, topic = _mqtt_cfg()
    cmd = ["mosquitto_pub", "-h", host, "-p", str(port),
           "-t", topic, "-m", "page %s %s" % (str(cap).zfill(7), message)]
    log("MQTT pub: %s" % " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    if r.returncode != 0:
        log("ERROR mosquitto_pub: %s" % (r.stderr or r.stdout).strip()[:200])
        return False
    log("MQTT OK cap=%s msg=%s" % (cap, message))
    return True


def main():
    if len(sys.argv) < 3:
        print("Uso: dispatch_mqtt.py <cap_code(s)> <mensaje> [baudios]")
        sys.exit(1)

    caps_str = str(sys.argv[1])
    cap_list = [c.strip() for c in caps_str.split(",") if c.strip()]
    message = str(sys.argv[2])

    if not cap_list:
        log("ERROR: no hay cap codes validos")
        print("ERROR: cap codes invalidos")
        sys.exit(1)

    log("=== Envio MQTT ===")
    log("caps=%s msg=%r" % (cap_list, message))

    sent = 0
    for cap in cap_list:
        try:
            cap_int = int(cap)
        except ValueError:
            log("ERROR cap invalido: %s" % cap)
            continue
        if publish_page(cap_int, message):
            sent += 1
        # Pausa entre caps para no saturar el modulo
        if len(cap_list) > 1:
            time.sleep(2.0)

    log("Envio completado: %d/%d cap(s)" % (sent, len(cap_list)))
    print("OK: %d/%d cap(s) via MQTT" % (sent, len(cap_list)))
    if sent == 0:
        sys.exit(1)


if __name__ == "__main__":
    main()