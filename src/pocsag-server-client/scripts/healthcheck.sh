#!/usr/bin/env bash
set -euo pipefail
ok=1
check(){ if systemctl is-active --quiet "$1"; then echo "[OK]   $1"; else echo "[FAIL] $1"; ok=0; fi; }
if asterisk -rx "core show uptime" >/dev/null 2>&1; then echo "[OK]   asterisk"; else echo "[FAIL] asterisk"; ok=0; fi
check pocsag-api 2>/dev/null||true
command -v aplay>/dev/null&&echo "[OK]   aplay"||{ echo "[FAIL] aplay"; ok=0; }
command -v sqlite3>/dev/null&&echo "[OK]   sqlite3"||{ echo "[FAIL] sqlite3"; ok=0; }
command -v python3>/dev/null&&echo "[OK]   python3"||{ echo "[FAIL] python3"; ok=0; }
python3 /opt/pocsag-server/encoder/pocsag_gen.py 123 test 1200 /tmp/_pocsag_test.wav 2>/dev/null && rm -f /tmp/_pocsag_test.wav && echo "[OK]   encoder POCSAG" || echo "[WARN] encoder POCSAG"
[[ $ok -eq 1 ]]&&echo "Sistema POCSAG: SALUDABLE"||echo "Sistema POCSAG: REVISAR"
exit $((1-ok))