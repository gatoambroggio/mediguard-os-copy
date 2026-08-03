#!/usr/bin/env python3
"""tests/test_encoder.py - Prueba básica del codificador POCSAG."""
import os
import sys
import subprocess
import tempfile

ENCODER = os.path.join(os.path.dirname(__file__), "..", "encoder", "pocsag_gen.py")


def test_genera_wav():
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        out = f.name
    rc = subprocess.run(
        [sys.executable, ENCODER, "123456", "99", "1200", out],
        capture_output=True, text=True,
    )
    assert rc.returncode == 0, f"Encoder falló: {rc.stderr}"
    assert os.path.exists(out) and os.path.getsize(out) > 0, "Wav vacío o inexistente"
    os.unlink(out)
    print("[OK] test_genera_wav")


if __name__ == "__main__":
    test_genera_wav()
    print("test_encoder OK")