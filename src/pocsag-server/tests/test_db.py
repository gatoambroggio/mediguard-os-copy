#!/usr/bin/env python3
"""tests/test_db.py - Prueba del manager de base de datos."""
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from database import db_manager


def test_resolver_codigo():
    tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False).name
    db_manager.init_db(tmp)
    # Código de ejemplo "11" debe existir
    res = db_manager.resolver_codigo("11", tmp)
    assert res is not None, "Código 11 no encontrado"
    cap, baud, tipo = res
    assert tipo == "grupo"
    assert baud == 1200
    # Código inexistente
    assert db_manager.resolver_codigo("ZZZ", tmp) is None
    os.unlink(tmp)
    print("[OK] test_resolver_codigo")


if __name__ == "__main__":
    test_resolver_codigo()
    print("test_db OK")