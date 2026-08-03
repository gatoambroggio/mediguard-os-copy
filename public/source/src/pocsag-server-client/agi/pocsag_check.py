#!/usr/bin/env python3
"""AGI check - valida si un codigo existe en la BD antes de pedir mensaje."""
import sys
sys.path.insert(0, "/opt/pocsag-server")
from database.db_manager import resolver_destino, get_config

def main():
    codigo = sys.argv[1] if len(sys.argv)>1 else ""
    dest = resolver_destino(codigo)
    if not dest:
        sys.stdout.write("SET VARIABLE POCSAG_VALID 0\n"); sys.stdout.flush(); return
    caps, baud, tipo = dest
    timeout = get_config("mensaje_timeout", "5")
    sys.stdout.write("SET VARIABLE POCSAG_VALID 1\n")
    sys.stdout.write(f"SET VARIABLE POCSAG_CAPS {caps}\n")
    sys.stdout.write(f"SET VARIABLE POCSAG_BAUD {baud}\n")
    sys.stdout.write(f"SET VARIABLE POCSAG_TIPO {tipo}\n")
    sys.stdout.write(f"SET VARIABLE POCSAG_MSJ_TIMEOUT {timeout}\n")
    sys.stdout.flush()

if __name__ == "__main__": main()