#!/usr/bin/env python3
"""
dispatch_mqtt.py - Envío de POCSAG via MQTT a MMDVMHost (RemoteControl).
Reemplaza a dispatch_serial.py: en lugar de hablar el protocolo binario
MMDVM por serial, publica el comando "page <cap> <mensaje>" en el topic
MQTT que MMDVMHost escucha (Name=host -> topic "host/command").

Uso: dispatch_mqtt.py [--bcd] <cap_code(s)> <mensaje> [baudios]
  --bcd       : modo numerico (page_bcd, func 0) para pagers numericos (ej NP88)
  cap_code(s) : un cap_code o varios separados por coma (para grupos)
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


def _to_ascii(s):
    """Normaliza a ASCII 7-bit imprimible (POCSAG alphanumeric): quita acentos,
    descarta bytes no-ASCII y reemplaza saltos de linea/tabulaciones por espacios.
    packASCII de MMDVMHost empaqueta char por char; un acento UTF-8 ('á' = 0xC3 0xA1)
    o un \n pasan como bytes de control y el pager muestra basura."""
    import unicodedata
    try:
        out = unicodedata.normalize("NFKD", str(s)).encode("ascii", "ignore").decode("ascii")
    except Exception:
        out = str(s)
    out = "".join(c if c.isprintable() else " " for c in out)
    return " ".join(out.split())


def publish_page(cap, message, bcd=False):
    """Publica el comando POCSAG por MQTT a host/command.
    bcd=False (alfanumerico) -> 'page <ric> <msg ASCII>'     (func ALPHANUMERIC=3, packASCII)
    bcd=True  (numerico)     -> 'page_bcd <ric> <digits>'    (func NUMERIC=0, packNumeric/BCD)
    MMDVMHost master soporta page y page_bcd (RemoteControl.cpp: PAGE y PAGE_BCD;
    POCSAGControl.cpp: sendPage usa FUNCTIONAL_ALPHANUMERIC, sendPageBCD usa FUNCTIONAL_NUMERIC).
    CRITICO: un pager NUMERICO (ej NP88) solo decodifica function 0 (NUMERIC); si se le
    manda 'page' (function 3 / alfanumerico) llega basura o no decodifica. Por eso los
    pagers con funcion='numeric' DEBEN ir por page_bcd. Requisito: el MMDVMHost instalado
    debe ser master (instalador_mmdvm.sh compila desde master); versiones viejas sin
    PAGE_BCD responden 'Invalid remote command' y no hacen PTT. El ric se zfill(7)."""
    host, port, topic = _mqtt_cfg()
    ric = str(cap).zfill(7)
    if bcd:
        # packNumeric soporta 0-9, espacio, '-', '(', ')', 'U'. Filtramos a digitos
        # (lo que un pager numerico muestra). Sin digitos -> page para que al menos
        # salga al aire (PTT) y el diagnostico muestre comando valido.
        digits = "".join(c for c in str(message) if c.isdigit())
        if digits:
            payload = "page_bcd %s %s" % (ric, digits)
        else:
            payload = "page %s %s" % (ric, _to_ascii(message).strip() or "TEST")
    else:
        msg = _to_ascii(message).strip() or "TEST"
        payload = "page %s %s" % (ric, msg)
    cmd = ["mosquitto_pub", "-h", host, "-p", str(port), "-t", topic, "-m", payload]
    log("MQTT pub: %s" % " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    if r.returncode != 0:
        err = (r.stderr or r.stdout or "unknown").strip()[:200]
        log("ERROR mosquitto_pub: %s" % err)
        sys.stderr.write("mosquitto_pub FALLO (host=%s port=%s topic=%s): %s\n" % (host, port, topic, err))
        return False
    log("MQTT OK: %s" % payload)
    return True


def main():
    raw = list(sys.argv[1:])
    bcd = "--bcd" in raw
    args = [a for a in raw if a != "--bcd"]
    if len(args) < 2:
        print("Uso: dispatch_mqtt.py [--bcd] <cap_code(s)> <mensaje> [baudios]")
        print("  --bcd : pagina numerico (page_bcd, func 0) para pagers como NP88")
        sys.exit(1)

    caps_str = str(args[0])
    cap_list = [c.strip() for c in caps_str.split(",") if c.strip()]
    message = str(args[1])

    if not cap_list:
        log("ERROR: no hay cap codes validos")
        print("ERROR: cap codes invalidos")
        sys.exit(1)

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
    if sent == 0:
        print("ERROR: 0/%d cap(s) via MQTT (mosquitto_pub fallo - ver dispatch_mqtt.log)" % len(cap_list))
        sys.exit(1)
    print("OK: %d/%d cap(s) via MQTT" % (sent, len(cap_list)))


if __name__ == "__main__":
    main()