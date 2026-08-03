#!/usr/bin/env bash
# ============================================================================
# scripts/healthcheck.sh - Verifica estado de los servicios POCSAG.
# ============================================================================
set -euo pipefail
ok=1
check() {
  if systemctl is-active --quiet "$1"; then
    echo "[OK]   $1 activo"
  else
    echo "[FAIL] $1 inactivo"; ok=0
  fi
}
check asterisk
check pocsag-monitor
check pocsag-api 2>/dev/null || true

command -v aplay   >/dev/null && echo "[OK]   aplay"   || { echo "[FAIL] aplay"; ok=0; }
command -v sqlite3 >/dev/null && echo "[OK]   sqlite3" || { echo "[FAIL] sqlite3"; ok=0; }
command -v python3 >/dev/null && echo "[OK]   python3" || { echo "[FAIL] python3"; ok=0; }
python3 -c "import pocsag" 2>/dev/null && echo "[OK]   python-pocsag" || echo "[WARN] python-pocsag no instalado"

[[ $ok -eq 1 ]] && echo "Sistema POCSAG: SALUDABLE" || echo "Sistema POCSAG: REVISAR"
exit $((1 - ok))