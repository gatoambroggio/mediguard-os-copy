#!/usr/bin/env bash
# ============================================================================
# pack.sh - Empaqueta el proyecto pocsag-server en un .zip entregable.
# Uso:  bash pack.sh [nombre_salida.zip]
#       (desde dentro del directorio pocsag-server o su padre)
# ============================================================================
set -euo pipefail

OUT="${1:-pocsag-server.zip}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Si el script vive dentro de src/pocsag-server, empaquetar esa carpeta
if [[ "$(basename "$DIR")" == "pocsag-server" ]]; then
  SRC="$DIR"
  PARENT="$(cd "$DIR/.." && pwd)"
  cd "$PARENT"
else
  SRC="$DIR/pocsag-server"
  [[ -d "$SRC" ]] || { echo "No se encontró el directorio pocsag-server en $DIR"; exit 1; }
  cd "$DIR"
fi

# Limpiar basura antes de empaquetar
find "$SRC" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find "$SRC" -name '*.pyc' -delete 2>/dev/null || true
find "$SRC" -name '*.db' -delete 2>/dev/null || true
find "$SRC" -name '*.wav' -path '*/audio/*' -delete 2>/dev/null || true
rm -f "$SRC/logs/"*.log 2>/dev/null || true

# Necesitamos zip
if ! command -v zip >/dev/null; then
  echo "Instalando zip..."
  if command -v apt-get >/dev/null; then sudo apt-get install -y zip
  elif command -v yum >/dev/null; then sudo yum install -y zip
  elif command -v apk >/dev/null; then sudo apk add zip
  else echo "Instalá 'zip' manualmente."; exit 1; fi
fi

OUT_PATH="$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")"
zip -r "$OUT_PATH" "$(basename "$SRC")" \
  -x '*/__pycache__/*' '*/logs/*.log' '*/database/*.db' >/dev/null

echo "--------------------------------------------"
echo "Archivo creado: $OUT_PATH"
echo "Tamaño: $(du -h "$OUT_PATH" | cut -f1)"
echo "Contenido: $(unzip -l "$OUT_PATH" | tail -1)"