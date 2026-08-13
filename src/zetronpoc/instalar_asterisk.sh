#!/usr/bin/env bash
# ============================================================================
# instalar_asterisk.sh - Compila e instala Asterisk 22 LTS desde fuente.
# ----------------------------------------------------------------------------
# Asterisk fue ELIMINADO de los repos Debian bookworm/trixie y de Raspbian.
# La unica ruta es compilar desde fuente. Este script es autocontenido y
# robusto: instala TODAS las deps de build, compila con pjproject+bundled
# (garantiza chan_pjsip), hace fallback a -j1 si -jN OOM/racea, y verifica
# que chan_pjsip.so quede instalado.
#
# Uso:
#   curl -fsSL https://raw.githubusercontent.com/gatoambroggio/mediguard-os-copy/main/src/zetronpoc/instalar_asterisk.sh | sudo bash
#
# Tiempo: Pi 4/5 ~20-30 min, Pi 3 ~45-60 min. Lento pero deterministico.
# ============================================================================
set -euo pipefail

G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; NC="\033[0m"
log(){ echo -e "${G}[OK]${NC}   $*"; }
warn(){ echo -e "${Y}[WARN]${NC} $*"; }
err(){ echo -e "${R}[ERR]${NC}  $*" >&2; }

[[ $EUID -ne 0 ]] && { err "Ejecuta como root o con sudo."; exit 1; }

# Salir si ya esta instalado Y tiene chan_pjsip
if [[ -x /usr/sbin/asterisk ]] && [[ -f /usr/lib/asterisk/modules/chan_pjsip.so ]]; then
  log "Asterisk ya instalado con chan_pjsip.so. Nada que hacer."
  asterisk -V 2>/dev/null || true
  exit 0
fi

# ====================== RUTA RAPIDA: .deb PRECOMPILADO (SEGUNDOS) ======================
# Si alguien corrio empaquetar_asterisk.sh una vez, existe un .deb arm64 en el
# release publico del repo. Lo bajamos y lo instalamos con dpkg en SEGUNDOS,
# sin compilar. Solo si falla (no hay .deb, red, o lib mismatch) caemos a la
# compilacion desde fuente (lento). Esto hace que la 2da instalacion en adelante
# sea instantanea, incluyendo imagenes nuevas y Pis nuevas.
DEB_URL="https://github.com/gatoambroggio/mediguard-os-copy/releases/download/asterisk-prebuilt/asterisk-22-arm64.deb"
DEB_TMP="/tmp/asterisk-22-arm64.deb"
if curl -fsSL "$DEB_URL" -o "$DEB_TMP" 2>/dev/null && [[ -s "$DEB_TMP" ]]; then
  log "Bajando .deb precompilado (instalacion en segundos, sin compilar)..."
  # apt install ./deb resuelve e instala las deps de runtime automaticamente.
  if apt-get install -y "$DEB_TMP" 2>&1 | tail -8; then
    ldconfig
    if [[ -x /usr/sbin/asterisk ]] && [[ -f /usr/lib/asterisk/modules/chan_pjsip.so ]]; then
      log "Asterisk instalado desde .deb precompilado en segundos."
      asterisk -V 2>/dev/null || true
      # Asegurar el servicio systemd (el .deb no lo crea)
      if ! systemctl list-unit-files 2>/dev/null | grep -q "^asterisk.service"; then
        cat > /etc/systemd/system/asterisk.service <<'UNIT'
[Unit]
Description=Asterisk PBX
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/sbin/asterisk -f
ExecStop=/usr/sbin/asterisk -rx "core stop now"
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload 2>/dev/null || true
      fi
      systemctl enable asterisk 2>/dev/null || true
      rm -f "$DEB_TMP"
      exit 0
    else
      warn ".deb instalado pero falta chan_pjsip.so o binario. Cayendo a compilacion..."
    fi
  else
    warn "apt-get install ./deb fallo (libs incompatibles?). Cayendo a compilacion..."
  fi
  rm -f "$DEB_TMP"
else
  warn "No hay .deb precompilado en el release (todavia). Se compilara desde fuente."
  warn "Para que la proxima vez sea instantanea, corregui empaquetar_asterisk.sh una vez."
fi

# ====================== RUTA RAPIDA 2: .deb DE UBUNTU NOBLE arm64 (SEGUNDOS) ======================
# Debian Trixie elimino Asterisk de sus repos, pero Ubuntu Noble (24.04) sigue
# publicando un Asterisk 20.6 LTS arm64 precompilado con chan_pjsip en
# ports.ubuntu.com (universe). El unico conflicto es que esos .deb dependen de
# libssl3t64 (el rename "t64" de Ubuntu), que en Debian Trixie se llama libssl3:
# el .so.3 real es el mismo (OpenSSL 3.x), asi que el binario linkea y corre, solo
# la METADATA del paquete no coincide. --force-depends saltea el chequeo de dpkg
# y apt-mark hold inmuniza a Asterisk contra futuros apt-get. El resto de las
# deps de runtime (libjansson4, libsqlite3-0, libxml2, liburiparser1, libpopt0,
# libxslt1.1, libedit2, libcap2, libuuid1, libsrtp2-1) tienen nombres identicos
# en Trixie y se instalan antes del dpkg -i. Resultado: Asterisk con PJSIP en
# SEGUNDOS, sin compilar, en cualquier Pi arm64. Si la red o un ABI mismatch
# rompen esta ruta, la verificacion final falla y cae a la compilacion lenta.
discover_deb_url() { # <pkgname> -> imprime ruta relativa (pool/...) o return 1
  local pkg="$1" pgz="/tmp/noble-arm64-Packages.gz"
  [[ -f "$pgz" ]] || curl -fsSL "http://ports.ubuntu.com/ubuntu-ports/dists/noble/universe/binary-arm64/Packages.gz" -o "$pgz" 2>/dev/null || return 1
  zcat "$pgz" 2>/dev/null | grep -A20 "^Package: ${pkg}\$" | grep '^Filename:' | head -1 | awk '{print $2}'
}
install_ubuntu_debs() {
  local TMPD="/tmp/ast-ubuntu-debs" BASE="http://ports.ubuntu.com/ubuntu-ports"
  local cfg deb mod
  cfg="$(discover_deb_url asterisk-config)"  || { warn "No encontre asterisk-config en Noble arm64."; return 1; }
  deb="$(discover_deb_url asterisk)"          || { warn "No encontre asterisk en Noble arm64.";        return 1; }
  mod="$(discover_deb_url asterisk-modules)"  || { warn "No encontre asterisk-modules en Noble arm64."; return 1; }
  # 1) Pre-instalar libs de runtime con nombres identicos en Trixie (antes del
  #    dpkg -i, para que apt no vea a Asterisk como paquete roto). Una por una
  #    con || true: si un nombre cambio de version en Trixie (ej. libspandsp3 ->
  #    libspandsp4), no aborta las demas.
  log "Instalando libs de runtime (nombres identicos en Trixie)..."
  for lib in libjansson4 liburiparser1 libpopt0 libxslt1.1 libedit2 libcap2 \
             libuuid1 libsqlite3-0 libxml2 libsrtp2-1 libspandsp3 libbluetooth3 \
             libical3a libneon27 libogg0 libvorbis0a libasound2 libgmime-3.0-0; do
    apt-get install -y "$lib" 2>/dev/null || true
  done
  # 2) Bajar los 3 .deb de Ubuntu Noble arm64.
  rm -rf "$TMPD"; mkdir -p "$TMPD"
  log "Bajando 3 .deb de Ubuntu Noble arm64 (Asterisk 20.6 LTS, con chan_pjsip)..."
  curl -fsSL "${BASE}/${cfg}" -o "$TMPD/asterisk-config.deb"  || return 1
  curl -fsSL "${BASE}/${deb}" -o "$TMPD/asterisk.deb"          || return 1
  curl -fsSL "${BASE}/${mod}" -o "$TMPD/asterisk-modules.deb"  || return 1
  # 3) Instalar con --force-depends (saltea el rename libssl3t64) y --force-confnew.
  log "Instalando con dpkg --force-depends (saltea rename libssl3t64 -> libssl3)..."
  dpkg --force-depends --force-confnew -i "$TMPD/asterisk-config.deb" "$TMPD/asterisk.deb" "$TMPD/asterisk-modules.deb" 2>&1 | tail -6
  ldconfig
  # 4) Inmunizar a Asterisk contra futuros apt-get que lo vean "roto" por libssl3t64.
  apt-mark hold asterisk asterisk-config asterisk-modules 2>/dev/null || true
  rm -rf "$TMPD"
  # 5) Verificacion final: binario + chan_pjsip.so presentes.
  [[ -x /usr/sbin/asterisk ]] && [[ -f /usr/lib/asterisk/modules/chan_pjsip.so ]]
}
if install_ubuntu_debs; then
  log "Asterisk instalado desde .deb de Ubuntu Noble arm64 (instantaneo, sin compilar)."
  asterisk -V 2>/dev/null || true
  # Asegurar el servicio systemd (los .deb de Ubuntu pueden traer el suyo o no).
  if ! systemctl list-unit-files 2>/dev/null | grep -q "^asterisk.service"; then
    cat > /etc/systemd/system/asterisk.service <<'UNIT'
[Unit]
Description=Asterisk PBX
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/sbin/asterisk -f
ExecStop=/usr/sbin/asterisk -rx "core stop now"
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload 2>/dev/null || true
  fi
  systemctl enable asterisk 2>/dev/null || true
  exit 0
else
  warn "Ruta .deb de Ubuntu fallo (red o ABI incompatible). Cayendo a compilacion desde fuente..."
fi

echo "==> 1/7 Actualizando indices e instalando dependencias de build..."
apt-get update -y || true
# Todas las deps necesarias para compilar Asterisk 22 con PJSIP en Debian arm64.
# Si una falta, el configure o el make revienta despues de 20 min -> las ponemos
# todas de una y no abortamos el script si una menor no existe.
apt-get install -y \
  build-essential wget tar pkg-config \
  libsqlite3-dev libedit-dev libxml2-dev libcurl4-openssl-dev \
  uuid-dev libssl-dev libjansson-dev \
  libsrtp2-dev libspandsp-dev libgmime-3.0-dev \
  libncurses-dev libbluetooth-dev libical-dev libneon27-dev \
  libogg-dev libvorbis-dev libasound2-dev 2>/dev/null || true
# libtonezone-dev / DAHDI no existen en Pi OS -> no son fatales (POCSAG no usa DAHDI)

echo "==> 2/7 Descargando Asterisk 22 LTS..."
AB="/tmp/asterisk-build"
rm -rf "$AB"; mkdir -p "$AB"; cd "$AB"
wget -q "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-22-current.tar.gz" -O ast.tar.gz \
  || { err "No se pudo descargar el tarball de Asterisk (sin red?)."; exit 1; }
tar xzf ast.tar.gz
cd asterisk-22*/
log "Fuente: $(pwd | sed 's:.*/::')"

echo "==> 3/7 Configurando (pjproject + jansson bundled -> garantiza chan_pjsip)..."
# --disable-xmldoc: evita fracasos de build por XML faltante en ARM y acelera.
# --with-pjproject-bundled: compila pjproject dentro del tree -> chan_pjsip SIEMPRE presente.
./configure --with-pjproject-bundled --with-jansson-bundled --disable-xmldoc \
  || { err "configure fallo. Faltan deps. Ver /tmp/asterisk-build/asterisk-22*/config.log"; exit 1; }
log "configure OK."

echo "==> 4/7 Compilando (esto tarda, paciencia)..."
JOBS="$(nproc 2>/dev/null || echo 2)"
# make paralelo es mas rapido pero en Pi 3 puede OOM o racear en apps/.
# Si falla con -jN, reintentar serial (-j1) que es determinista.
if ! make -j"$JOBS" 2>&1 | tail -15; then
  warn "make -j$JOBS fallo (OOM o race). Reintentando serial (-j1)..."
  if ! make -j1 2>&1 | tail -15; then
    err "make fallo incluso con -j1. Ver el log de errores arriba."; exit 1
  fi
fi
log "Compilacion OK."

echo "==> 5/7 Instalando binarios + config base..."
make install 2>&1 | tail -3
make config 2>&1 >/dev/null || true
make samples 2>&1 >/dev/null || true   # genera /etc/asterisk/*.conf base
ldconfig
log "Instalado en /usr/sbin/asterisk."

echo "==> 6/7 Verificando chan_pjsip.so..."
if [[ -f /usr/lib/asterisk/modules/chan_pjsip.so ]]; then
  log "chan_pjsip.so presente -> ZetronPOC puede registrar internos via PJSIP."
else
  err "chan_pjsip.so NO esta. El pjproject-bundled fallo silenciosamente."
  err "Re-ejecuta este script; si persiste, verifica que make no tiro errores arriba."
  exit 1
fi

echo "==> 7/7 Servicio systemd..."
if ! systemctl list-unit-files 2>/dev/null | grep -q "^asterisk.service"; then
  cat > /etc/systemd/system/asterisk.service <<'UNIT'
[Unit]
Description=Asterisk PBX
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/sbin/asterisk -f
ExecStop=/usr/sbin/asterisk -rx "core stop now"
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload 2>/dev/null || true
  log "asterisk.service creado."
fi
systemctl enable asterisk 2>/dev/null || true

echo ""
log "============================================="
log "Asterisk instalado desde fuente:"
asterisk -V 2>/dev/null || true
log "Modulos: $(ls /usr/lib/asterisk/modules/ | wc -l) archivos"
log "chan_pjsip: $([ -f /usr/lib/asterisk/modules/chan_pjsip.so ] && echo OK || echo FALTA)"
log "============================================="
echo "  Ahora corre el instalador de ZetronPOC:"
echo "    curl -fsSL https://raw.githubusercontent.com/gatoambroggio/mediguard-os-copy/main/src/zetronpoc/instalador.sh | sudo bash -s -- --update"