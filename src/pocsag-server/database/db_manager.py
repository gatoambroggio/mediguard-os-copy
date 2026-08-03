#!/usr/bin/env python3
"""database/db_manager.py - Helpers SQLite para el sistema POCSAG."""
import sqlite3
import os
import datetime
from contextlib import contextmanager

DEFAULT_DB = "/opt/pocsag-server/database/pocsag.db"


@contextmanager
def get_conn(db_path=DEFAULT_DB):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db(db_path=DEFAULT_DB):
    schema = os.path.join(os.path.dirname(__file__), "schema.sql")
    seed = os.path.join(os.path.dirname(__file__), "seed.sql")
    with get_conn(db_path) as conn:
        with open(schema) as f:
            conn.executescript(f.read())
        with open(seed) as f:
            conn.executescript(f.read())


def resolver_codigo(codigo, db_path=DEFAULT_DB):
    """Devuelve (cap_code, baudios, tipo) o None si no existe/inactivo."""
    with get_conn(db_path) as conn:
        row = conn.execute(
            "SELECT cap_code, baudios, tipo FROM codigos WHERE codigo=? AND activo=1",
            (codigo,),
        ).fetchone()
        return tuple(row) if row else None


def listar_miembros_grupo(grupo_id, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [r["cap_code"] for r in conn.execute(
            "SELECT cap_code FROM grupo_miembros WHERE grupo_id=?", (grupo_id,)
        )]


def registrar_bitacora(interno, codigo, cap_code, mensaje, baudios, estado, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute(
            """INSERT INTO bitacora
               (fecha_hora,interno_origen,codigo,cap_code,mensaje,baudios,estado)
               VALUES (?,?,?,?,?,?,?)""",
            (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
             interno, codigo, cap_code, mensaje, baudios, estado),
        )


def listar_codigos(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM codigos ORDER BY codigo")]


def bitacora_reciente(limit=20, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute(
            "SELECT * FROM bitacora ORDER BY id DESC LIMIT ?", (limit,)
        )]


if __name__ == "__main__":
    import sys
    cmd = sys.argv[1] if len(sys.argv) > 1 else "init"
    if cmd == "init":
        init_db()
        print("Base de datos inicializada.")
    elif cmd == "codigos":
        for c in listar_codigos():
            print(c)
    elif cmd == "bitacora":
        for b in bitacora_reciente():
            print(b)