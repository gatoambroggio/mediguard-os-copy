#!/usr/bin/env bash
# ============================================================================
# tests/run_tests.sh - Ejecuta todas las pruebas del sistema POCSAG.
# ============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR/.."

echo "==> Probando codificador..."
python3 tests/test_encoder.py
echo "==> Probando base de datos..."
python3 tests/test_db.py
echo "==> Probando scripts de PTT (sintaxis)..."
bash -n scripts/ptt_on.sh
bash -n scripts/ptt_off.sh
echo "==> Probando healthcheck (sintaxis)..."
bash -n scripts/healthcheck.sh
echo "Todas las pruebas OK."