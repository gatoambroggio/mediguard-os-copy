#!/usr/bin/env python3
"""cola_worker.py - Worker de cola de envios ZetronPOC.
Procesa mensajes pendientes llamando a pocsag_handler.py con POCSAG_WORKER=1."""
import sys, os, time
APP_DIR = os.environ.get("ZETRONPOC_DIR", "/opt/zetronpoc")
sys.path.insert(0, APP_DIR)
sys.path.insert(0, os.path.join(APP_DIR, "database"))
from db_manager import procesar_siguiente_cola, get_conn, DEFAULT_DB, init_db

LOG = os.path.join(APP_DIR, "logs/cola.log")

def clog(m):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S") + " " + m + "\n")
    except Exception:
        pass

def recuperar_enviando():
    with get_conn(DEFAULT_DB) as conn:
        conn.execute("UPDATE cola_envios SET estado='pendiente' WHERE estado='enviando'")

def main():
    try:
        init_db()
        clog("[START] Base de datos verificada/migrada")
    except Exception as e:
        clog("[WARN] init_db: %s" % e)
    recuperar_enviando()
    clog("[START] Worker de cola ZetronPOC iniciado")
    while True:
        try:
            result = procesar_siguiente_cola()
            if result is None:
                time.sleep(2)
            else:
                clog("[OK] Procesado item id=%s" % result); time.sleep(0.5)
        except Exception as e:
            clog("[ERROR] %s" % e); time.sleep(5)

if __name__ == "__main__":
    main()