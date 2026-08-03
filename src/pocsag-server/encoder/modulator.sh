#!/usr/bin/env bash
# ============================================================================
# encoder/modulator.sh - Genera audio POCSAG y maneja PTT para transmisión.
# Uso: modulator.sh <cap_code> <mensaje> <baudios> <salida.wav>
# ============================================================================
set -euo pipefail
CAP="${1:?falta cap_code}"
MSG="${2:?falta mensaje}"
BAUD="${3:?falta baudios}"
OUT="${4:?falta salida wav}"
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "${BASE}/encoder/pocsag_gen.py" "$CAP" "$MSG" "$BAUD" "$OUT"
echo "Audio POCSAG generado: $OUT"