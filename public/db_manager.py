#!/usr/bin/env python3
import sqlite3, os
from contextlib import contextmanager
DEFAULT_DB = "/opt/pocsag-server/database/pocsag.db"

@contextmanager
def get_conn(db_path=DEFAULT_DB):
    conn = sqlite3.connect(db_path); conn.row_factory = sqlite3.Row
    try: yield conn; conn.commit()
    finally: conn.close()

def init_db(db_path=DEFAULT_DB):
    base = os.path.dirname(__file__)
    with get_conn(db_path) as conn:
        with open(os.path.join(base,"schema.sql")) as f: conn.executescript(f.read())
        with open(os.path.join(base,"seed.sql")) as f: conn.executescript(f.read())

def resolver_codigo(codigo, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        row = conn.execute("SELECT cap_code, baudios, tipo FROM codigos WHERE codigo=? AND activo=1",(codigo,)).fetchone()
        return tuple(row) if row else None

def registrar_bitacora(interno, codigo, cap_code, mensaje, baudios, estado, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("INSERT INTO bitacora (interno_origen,codigo,cap_code,mensaje,baudios,estado) VALUES (?,?,?,?,?,?)",
                     (interno,codigo,cap_code,mensaje,baudios,estado))

def listar_codigos(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM codigos ORDER BY codigo")]

def bitacora_reciente(limit=20, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM bitacora ORDER BY id DESC LIMIT ?",(limit,))]

def crear_codigo(codigo, tipo, cap_code, baudios, descripcion, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("INSERT OR IGNORE INTO codigos (codigo,tipo,cap_code,baudios,descripcion) VALUES (?,?,?,?,?)",
                     (codigo,tipo,cap_code,baudios,descripcion))

def actualizar_codigo(codigo, tipo, cap_code, baudios, descripcion, activo, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE codigos SET tipo=?,cap_code=?,baudios=?,descripcion=?,activo=? WHERE codigo=?",
                     (tipo,cap_code,baudios,descripcion,activo,codigo))

def borrar_codigo(codigo, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM codigos WHERE codigo=?",(codigo,))

def enviar_mensaje(codigo, mensaje, origen="web", db_path=DEFAULT_DB):
    import subprocess, sys
    destino = resolver_codigo(codigo, db_path)
    if not destino: return {"status":"error","detalle":"código no encontrado"}
    cap_code, baudios, tipo = destino
    handler = "/var/lib/asterisk/agi-bin/pocsag_handler.py"
    if not os.path.exists(handler): handler = "/opt/pocsag-server/agi/pocsag_handler.py"
    rc = subprocess.run([sys.executable, handler, origen, codigo, mensaje], capture_output=True, text=True)
    if rc.returncode == 0: return {"status":"enviado","cap_code":cap_code,"baudios":baudios}
    return {"status":"error","detalle":rc.stderr.strip() or "falló el envío"}

if __name__ == "__main__":
    import sys
    if len(sys.argv)>1 and sys.argv[1]=="init": init_db(); print("Base de datos inicializada.")
