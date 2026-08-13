#!/usr/bin/env bash
# ============================================================================
# empaquetar_asterisk.sh - Compila Asterisk 22 UNA VEZ y lo empaqueta como .deb
# ----------------------------------------------------------------------------
# Corre UNA SOLA VEZ en la Pi 3 (o 4/5). Compila Asterisk 22 con chan_pjsip,
# empaqueta TODO lo instalado en un .deb arm64 portable y lo sube como release
# asset a GitHub. A partir de ahi, instalar_asterisk.sh baja ese .deb y lo
# instala en SEGUNDOS con dpkg -i (sin volver a compilar nunca mas).
#
# Requisito: un GitHub Personal Access Token (classic, scope `repo`) exportado
# como GH_TOKEN antes de ejecutar. Se usa SOLO aca para subir el .deb al
# release; los instaladores lo bajan de un release publico (no necesitan token).
#   https://github.com/settings/tokens/new?scopes=repo  -> copiar el token
#   export GH_TOKEN=ghp_xxxxx
#
# Uso (en la Pi, una sola vez en la vida):
#   export GH_TOKEN=ghp_xxx
#   curl -fsSL https://raw.githubusercontent.com/gatoambroggio/mediguard-os-copy/main/src/zetronpoc/empaquetar_asterisk.sh | sudo bash
#
# Tiempo: Pi 3 ~50-60 min (UNA vez). Despues: 0 minutos para siempre.
# ============================================================================
set -euo pipefail

OWNER="gatoambroggio"
REPO="mediguard-os-copy"
TAG="asterisk-prebuilt"
ASSET="asterisk-22-arm64.deb"

G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; NC="\033[0m"
log(){ echo -e "${G}[OK]${NC}   $*"; }
warn(){ echo -e "${Y}[WARN]${NC} $*"; }
err(){ echo -e "${R}[ERR]${NC}  $*" >&2; }

[[ $EUID -ne 0 ]] && { err "Ejecuta como root o con sudo."; exit 1; }
[[ -z "${GH_TOKEN:-}" ]] && { err "Falta GH_TOKEN. Genera un PAT en https://github.com/settings/tokens/new?scopes=repo y: export GH_TOKEN=ghp_xxx"; exit 1; }

# Si ya existe un .deb armado antes, no recompilar: solo re-subir.
DEB="/tmp/asterisk-build/${ASSET}"
if [[ -f "$DEB" ]]; then
  warn "Ya existe $DEB. Salteando compilacion, solo re-subiendo al release."
else
  # ====================== 1. DEPENDENCIAS DE BUILD ======================
  echo "==> 1/6 Dependencias de build..."
  apt-get update -y || true
  apt-get install -y \
    build-essential wget tar pkg-config dpkg-dev \
    libsqlite3-dev libedit-dev libxml2-dev libcurl4-openssl-dev \
    uuid-dev libssl-dev libjansson-dev \
    libsrtp2-dev libspandsp-dev libgmime-3.0-dev \
    libncurses-dev libbluetooth-dev libical-dev libneon27-dev \
    libogg-dev libvorbis-dev libasound2-dev 2>/dev/null || true

  # ====================== 2. DESCARGAR FUENTE ======================
  echo "==> 2/6 Descargando Asterisk 22 LTS..."
  AB="/tmp/asterisk-build"
  mkdir -p "$AB"; cd "$AB"
  wget -q "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-22-current.tar.gz" -O ast.tar.gz \
    || { err "No se pudo descargar Asterisk."; exit 1; }
  tar xzf ast.tar.gz
  cd asterisk-22*/

  # ====================== 3. CONFIGURE + COMPILE ======================
  echo "==> 3/6 configure (pjproject + jansson bundled)..."
  ./configure --with-pjproject-bundled --with-jansson-bundled --disable-xmldoc \
    || { err "configure fallo. Ver config.log."; exit 1; }

  echo "==> 4/6 Compilando (Pi 3 ~50-60 min, paciencia - es LA UNICA vez)..."
  # Pi 3: 1GB RAM. -jN muere por OOM. Forzar -j2 (seguro) y caer a -j1 si revienta.
  if ! make -j2 2>&1 | tail -20; then
    warn "make -j2 fallo (OOM). Reintentando serial (-j1)..."
    make -j1 2>&1 | tail -20 || { err "make fallo."; exit 1; }
  fi
  log "Compilacion OK."

  # ====================== 5. INSTALAR EN STAGING + EMPAQUETAR .deb ======================
  echo "==> 5/6 Empaquetando en .deb arm64..."
  ROOT="/tmp/ast-deb-root"
  rm -rf "$ROOT"; mkdir -p "$ROOT"
  # DESTDIR instala TODO bajo $ROOT sin tocar el sistema real.
  make install DESTDIR="$ROOT" 2>&1 | tail -3
  make samples DESTDIR="$ROOT" 2>&1 >/dev/null || true

  # Verificar chan_pjsip en el staging
  if [[ ! -f "$ROOT/usr/lib/asterisk/modules/chan_pjsip.so" ]]; then
    err "chan_pjsip.so no quedo en el staging. Algo fallo en el bundled pjproject."
    exit 1
  fi

  # Directorio DEBIAN/control con dependencias de runtime (libs presentes en Bookworm)
  mkdir -p "$ROOT/DEBIAN"
  cat > "$ROOT/DEBIAN/control" <<CTRL
Package: asterisk-zetronpoc
Version: 22.0
Architecture: arm64
Maintainer: MediGuard OS
Section: comm
Priority: optional
Depends: libsqlite3-0, libssl3, libjansson4, libsrtp2-1, libspandsp2, libncurses6, libxml2, libcurl4, uuid-runtime, libedit2, libgmime-3.0-0, libbluetooth3, libical3a, libneon27, libogg0, libvorbis0a, libasound2
Description: Asterisk 22 LTS precompilado para MediGuard OS (arm64, con chan_pjsip)
 Compilado una sola vez para no recompilar en cada instalacion. Incluye
 chan_pjsip.so (pjproject bundled). Solo para Raspberry Pi OS Bookworm arm64.
CTRL
  # postinst: ldconfig para registrar las libs nuevas
  cat > "$ROOT/DEBIAN/postinst" <<'POST'
#!/bin/sh
ldconfig
exit 0
POST
  chmod 755 "$ROOT/DEBIAN/postinst"

  mkdir -p /tmp/asterisk-build
  dpkg-deb --build --root-owner-group "$ROOT" "$DEB" \
    || { err "dpkg-deb fallo."; exit 1; }
  log ".deb creado: $(du -h "$DEB" | cut -f1)"
fi

# ====================== 6. SUBIR COMO RELEASE ASSET ======================
echo "==> 6/6 Subiendo $ASSET al release $TAG de GitHub..."
GH_API="https://api.github.com"
AUTH="Authorization: Bearer ${GH_TOKEN}"

# Crear o actualizar el release (sin body, solo contenedor para el asset)
rel=$(curl -fsSL -H "$AUTH" "${GH_API}/repos/${OWNER}/${REPO}/releases/tags/${TAG}" 2>/dev/null || true)
rel_id=$(echo "$rel" | grep -m1 '"id"' | grep -oE '[0-9]+' || true)
if [[ -z "$rel_id" ]]; then
  resp=$(curl -fsSL -X POST -H "$AUTH" -H "Content-Type: application/json" \
    -d "{\"tag_name\":\"${TAG}\",\"name\":\"Asterisk 22 precompilado (arm64)\",\"body\":\".deb arm64 de Asterisk 22 con chan_pjsip. Instalacion en segundos via instalar_asterisk.sh.\"}" \
    "${GH_API}/repos/${OWNER}/${REPO}/releases") || { err "No se pudo crear el release."; exit 1; }
  rel_id=$(echo "$resp" | grep -m1 '"id"' | grep -oE '[0-9]+')
fi

# Borrar asset anterior con el mismo nombre (si existe) para reemplazar
existing=$(curl -fsSL -H "$AUTH" "${GH_API}/repos/${OWNER}/${REPO}/releases/${rel_id}/assets" 2>/dev/null | grep -m1 "\"name\": \"${ASSET}\"" -B3 | grep -m1 '"id"' | grep -oE '[0-9]+' || true)
if [[ -n "$existing" ]]; then
  curl -fsSL -X DELETE -H "$AUTH" "${GH_API}/repos/${OWNER}/${REPO}/releases/assets/${existing}" >/dev/null 2>&1 || true
fi

# Subir el asset (upload via API de assets)
up_url=$(curl -fsSL -H "$AUTH" "${GH_API}/repos/${OWNER}/${REPO}/releases/${rel_id}" | grep -m1 '"upload_url"' | sed -E 's/.*"upload_url": *"([^"?]+)\{[^}]*\}".*/\1/')
curl -fsSL -X POST -H "$AUTH" -H "Content-Type: application/octet-stream" \
  --data-binary "@${DEB}" "${up_url}?name=${ASSET}" >/dev/null \
  || { err "Fallo la subida del .deb."; exit 1; }

log "============================================="
log "Listo. .deb subido al release publico:"
log "  https://github.com/${OWNER}/${REPO}/releases/tag/${TAG}"
log "============================================="
echo " A partir de ahora, instalar_asterisk.sh baja ese .deb y lo instala en"
echo " SEGUNDOS con dpkg -i. Ninguna Pi vuelve a compilar."
echo " Descarga directa (publica, sin token):"
echo "   https://github.com/${OWNER}/${REPO}/releases/download/${TAG}/${ASSET}"