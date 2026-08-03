#!/usr/bin/env python3
"""Worker de cola - procesa mensajes pendientes."""
import sys, os, time
sys.path.insert(0, "/opt/pocsag-server")
from database.db_manager import procesar_siguiente_cola, get_conn, DEFAULT_DB

def recuperar_enviando():
    with get_conn(DEFAULT_DB) as conn:
        conn.execute("UPDATE cola_envios SET estado='pendiente' WHERE estado='enviando'")

def clog(m):
    with open("/opt/pocsag-server/logs/cola.log","a") as f: f.write(time.strftime("%Y-%m-%d %H:%M:%S")+" "+m+"\n")

def main():
    recuperar_enviando()
    os.makedirs("/opt/pocsag-server/logs", exist_ok=True)
    clog("[START] Worker de cola iniciado")
    while True:
        try:
            result = procesar_siguiente_cola()
            if result is None:
                time.sleep(2)
            else:
                clog(f"[OK] Procesado item id={result}"); time.sleep(0.5)
        except Exception as e:
            clog(f"[ERROR] {e}"); time.sleep(5)

if __name__ == "__main__": main()