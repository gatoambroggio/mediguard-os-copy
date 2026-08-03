#!/usr/bin/env bash
set -euo pipefail
AUDIO_DIR="/opt/pocsag-server/audio"
DIAS="${1:-7}"
[[ -d "$AUDIO_DIR" ]] || exit 0
find "$AUDIO_DIR" -name 'out_*.wav' -type f -mtime +"${DIAS}" -delete 2>/dev/null || true