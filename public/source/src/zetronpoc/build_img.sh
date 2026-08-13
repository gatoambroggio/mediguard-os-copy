#!/usr/bin/env bash
# ============================================================================
# build_img.sh - Construye mediguardos-rpi.img (Pi OS Lite 64-bit + ZetronPOC)
# ============================================================================
# Corre en una PC Linux x86 (Debian/Ubuntu). Usa pi-gen (builder oficial de
# Raspberry Pi) para armar una imagen .img flasheable con TODO ya instalado:
# Asterisk + PJSIP, ZetronPOC (API + cola + panel), NetworkManager/VPN,
# mosquitto, servicios habilitados y SSH headless (admin / admin123).
#
# Uso:
#   sudo bash build_img.sh                # construye la imagen
#   sudo bash build_img.sh --skip-build   # solo configura pi-gen, no construye
#
# Requisitos: ~6 GB libres, Docker (recomendado) o debootstrap + qemu-user-binfmt.
# Tiempo estimado: ~30-45 min (Asterisk NO se compila aca; se difiere al primer
# arranque de la Pi, nativo ~30 min). Antes compilar bajo qemu tardaba 3-4 h.
# Salida: ./mediguardos-rpi.img (flashear con BalenaEtcher / Raspberry Pi Imager)
#
# Nota: ni MMDVMHost ni Asterisk se compilan durante el build (compilar bajo
#       qemu tardaba 3-4 h). Ambos se instalan nativamente en el PRIMER arranque
#       de la Pi: Asterisk desde .deb (instantáneo) y MMDVMHost compilado desde
#       fuente (~5-10 min). El UART de la Pi se libera (consola serie + BT fuera)
#       en ese mismo primer boot, asi el modulo MMDVM anda sin tocar nada a mano.
#       zetronpoc-api / zetronpoc-cola / mosquitto sí quedan habilitados y arrancan solos.
# ============================================================================
set -euo pipefail

REPO="https://raw.githubusercontent.com/gatoambroggio/mediguard-os-copy/main/src/zetronpoc"
PIGEN_URL="https://github.com/RPi-Distro/pi-gen.git"
PIGEN_BRANCH="arm64"   # 64-bit: el README de pi-gen indica usar el branch arm64
IMG_NAME="mediguardos-rpi"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/pi-gen-work"
PIGEN="$WORK/pi-gen"
STAGE="stage2-mediguard"
SKIP_BUILD=0
[[ "${1:-}" == "--skip-build" ]] && SKIP_BUILD=1

G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; NC="\033[0m"
log(){ echo -e "${G}[OK]${NC}  $*"; }
warn(){ echo -e "${Y}[WARN]${NC} $*"; }
err(){ echo -e "${R}[ERR]${NC} $*" >&2; }

[[ $EUID -ne 0 ]] && { err "Ejecuta como root o con sudo."; exit 1; }

echo "==================================================="
echo " build_img.sh - MediGuard OS para Raspberry Pi (64b)"
echo "==================================================="
echo " Salida esperada : $HERE/$IMG_NAME.img"
echo " Tiempo estimado : ~30-45 min (Asterisk se compila en el 1er boot, no aca)"
echo " RAM host        : 2+ GB libres (sin compilacion ARM emulada)"
echo " Disco necesario : ~6 GB libres en $HERE"
echo ""

# -------------------- 1. DEPENDENCIAS DEL HOST --------------------
echo "==> 1/6 Dependencias del host..."
USE_DOCKER=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  USE_DOCKER=1
  log "Docker disponible -> build via Docker (mas limpio y rapido)."
else
  warn "Docker no detectado -> build nativo (instalando deps del host)..."
  apt-get update -y || { err "apt-get update fallo. Revisa tus repositorios."; exit 1; }

  # Instalar cada paquete critico POR SEPARADO: apt aborta TODA la
  # transaccion si un nombre del lote no tiene candidato (ej: qemu-user-static
  # es paquete virtual en Ubuntu 25.10 "resolute" -> no hay candidato -> se
  # lleva puesto a debootstrap aunque este si exista). Separandolos, un paquete
  # que no exista no impide instalar el resto.

  # debootstrap + binfmt-support: criticos, no silenciados (si fallan, aborta).
  apt-get install -y debootstrap binfmt-support \
    || { err "No se pudo instalar debootstrap/binfmt-support. Revisa apt arriba."; exit 1; }

  # qemu para el chroot arm64: en distros viejas el paquete real es
  # qemu-user-static; en Ubuntu 25.10+ es virtual y hay que pedir el proveedor
  # qemu-user-binfmt. Probar primero el real y caer al proveedor si falla.
  if ! apt-get install -y qemu-user-static 2>/dev/null; then
    warn "qemu-user-static no disponible (probablemente virtual en esta distro)."
    warn "Instalando proveedor qemu-user-binfmt en su lugar..."
    apt-get install -y qemu-user-binfmt \
      || { err "No se pudo instalar ni qemu-user-static ni qemu-user-binfmt."; exit 1; }
  fi

  # resto de deps del builder (algunas pueden faltar segun distro, no son fatales)
  apt-get install -y coreutils quilt parted zerofree zip dosfstools e2fsprogs \
    libarchive-tools libcap2-bin grep rsync xz-utils file git curl bc gpg pigz \
    xxd arch-test bmap-tools kmod 2>&1 || warn "Algunas deps secundarias no instalaron (build puede igual funcionar)."

  # Registrar binfmt para que qemu ejecute binarios arm64 dentro del chroot
  update-binfmts --enable qemu-aarch64 2>/dev/null \
    || warn "update-binfmts fallo (quizas necesites reiniciar o cargar el modulo binfmt_misc)."

  command -v debootstrap >/dev/null 2>&1 \
    || { err "debootstrap sigue ausente tras apt-get install. Instalalo manualmente y reejecuta."; exit 1; }
  log "Deps nativas listas."
fi

# -------------------- 2. CLONAR pi-gen (branch arm64) --------------------
echo "==> 2/6 Clonando pi-gen (branch $PIGEN_BRANCH = 64-bit)..."
if [[ -d "$PIGEN/.git" ]]; then
  warn "pi-gen ya existe en $PIGEN. Reutilizando. (borra la carpeta para forzar reclone)"
else
  git clone --depth 1 -b "$PIGEN_BRANCH" "$PIGEN_URL" "$PIGEN"
  log "pi-gen clonado (branch $PIGEN_BRANCH)."
fi

# Limpiar el rootfs stale de runs anteriores. pi-gen guarda el rootfs armado en
# work/<IMG>/stage*/rootfs y lo REUTILIZA al re-correr (no lo borra solo). Si un
# build fallo a mitad (ej: instalador_rpi aborto y dejo .list temporales en el
# rootfs), el proximo run arranca con esa basura y apt revienta con
# "Conflicting values set for option Trusted". Borrar solo work/ deja el clone
# intacto (rapido) y fuerza un rootfs limpio desde stage0.
rm -rf "$PIGEN/work"
log "work/ stale limpiado (rootfs fresco desde stage0)."

# -------------------- 3. CONFIG pi-gen --------------------
echo "==> 3/6 Escribiendo config pi-gen..."
cat > "$PIGEN/config" <<EOF
IMG_NAME="$IMG_NAME"
DEPLOY_COMPRESSION=none
TARGET_HOSTNAME=mediguard
LOCALE_DEFAULT="es_AR.UTF-8"
KEYBOARD_KEYMAP="us"
KEYBOARD_LAYOUT="English (US)"
TIMEZONE_DEFAULT="America/Argentina/Cordoba"
FIRST_USER_NAME="admin"
FIRST_USER_PASS="admin123"
DISABLE_FIRST_BOOT_USER_RENAME=1
PASSWORDLESS_SUDO=1
ENABLE_SSH=1
ENABLE_CLOUD_INIT=0
STAGE_LIST="stage0 stage1 $STAGE"
EOF
log "config: hostname=mediguard, admin/admin123, SSH on, sudo sin clave."
# -------------------- 4. INYECTAR stage2-mediguard --------------------
# pi-gen SOLO ejecuta subdirectorios numerados dentro de un stage; los archivos
# sueltos en la raiz del stage se ignoran (por eso el build "terminaba" en 1 min
# sin instalar nada). Cada archivo baja a un .tmp, se valida (tamaño + no-HTML)
# y despues se mueve a su slot canonico dentro del subdirectorio numerado:
#   00-install-packages/00-packages        -> apt preinstall (lista, uno por linea)
#   01-mediguard-install/00-run-chroot.sh   -> corre instalador_rpi.sh --update DENTRO del chroot (arm64)
#   02-mediguard-firstboot/00-run-chroot.sh -> instala servicio oneshot primer boot DENTRO del chroot
# Ademas se deja un archivo EXPORT_IMAGE vacio en la raiz del stage: sin el,
# pi-gen arma el rootfs pero NUNCA exporta el .img a deploy/.
echo "==> 4/6 Inyectando stage $STAGE..."
# Borrar la definicion del stage de corridas anteriores: si reutilizamos pi-gen
# (no lo re-clonamos), los 00-run.sh stale pre-fix quedarian junto a los
# 00-run-chroot.sh nuevos y pi-gen los ejecutaria en el HOST (x86) en lugar del
# chroot. rm -rf garantiza que solo queden los slots actuales (00-run-chroot.sh).
rm -rf "$PIGEN/$STAGE"
mkdir -p "$PIGEN/$STAGE"
touch "$PIGEN/$STAGE/EXPORT_IMAGE"

# pi-gen exige un prerun.sh en la RAIZ de cada stage (excepto stage0, que hace
# debootstrap). Los stages estandar (stage1/stage2) traen uno que llama a
# `copy_previous` para copiar el rootfs del stage anterior al actual. Sin este
# archivo, el rootfs de stage2-mediguard queda vacio y el chroot revienta con
# "realpath: .../proc: No such file or directory" / "Unable to chroot/chdir".
# El guard revisa ademas si el dir esta vacio (re-run tras un build fallido que
# dejo un rootfs vacio): copy_previous hace mkdir -p + rsync encima, asi que
# llamarlo con dir existente-vacio es seguro.
cat > "$PIGEN/$STAGE/prerun.sh" <<'PRERUN'
#!/bin/bash -e
if [ ! -d "${ROOTFS_DIR}" ] || [ -z "$(ls -A "${ROOTFS_DIR}" 2>/dev/null)" ]; then
	copy_previous
fi
PRERUN
chmod +x "$PIGEN/$STAGE/prerun.sh"

# mapa: <archivo en repo> -> <subdirectorio numerado>/<slot pi-gen>
declare -a STAGE_FILES=(
  "00-packages|00-install-packages/00-packages"
  "01-mediguard-install.sh|01-mediguard-install/00-run-chroot.sh"
  "02-mediguard-firstboot.sh|02-mediguard-firstboot/00-run-chroot.sh"
)
for entry in "${STAGE_FILES[@]}"; do
  src="${entry%%|*}"
  slot="${entry##*|}"
  tmp="$PIGEN/$STAGE/${src}.tmp"
  curl -fsSL "$REPO/pi-gen-stage/$src" -o "$tmp" || { err "No se pudo bajar pi-gen-stage/$src (HTTP/red)."; exit 1; }
  sz=$(wc -c < "$tmp" 2>/dev/null || echo 0)
  first_byte=$(head -c 1 "$tmp" 2>/dev/null || true)
  if [[ $sz -lt 50 ]] || [[ "$first_byte" == "<" ]]; then
    err "pi-gen-stage/$src vino vacio o como HTML (size=$sz). Abortando antes de pi-gen."
    exit 1
  fi
  mkdir -p "$PIGEN/$STAGE/$(dirname "$slot")"
  mv -f "$tmp" "$PIGEN/$STAGE/$slot"
  [[ "$src" == *.sh ]] && chmod +x "$PIGEN/$STAGE/$slot"
done
log "Stage inyectado (3 subdirectorios numerados + prerun.sh + EXPORT_IMAGE)."

# -------------------- 5. BUILD --------------------
echo "==> 5/6 Construyendo imagen (paciencia)..."
# Normalizar locale para el chroot: el SSH desde Mac exporta LC_CTYPE=UTF-8,
# que el rootfs arm64 aun no tiene generado -> perl/apt tiran warnings "Setting
# locale failed" (cosmetico, pero ruidoso y a veces confunde a apt). Forzamos C.
export LC_ALL=C LANG=C
START=$(date +%s)
if [[ $SKIP_BUILD -eq 1 ]]; then
  warn "--skip-build: config y stage listos, NO se construyo. Quita el flag y reejecuta."
else
  cd "$PIGEN"
  if [[ $USE_DOCKER -eq 1 ]]; then
    ./build-docker.sh
  else
    ./build.sh
  fi
  cd "$HERE"
fi
END=$(date +%s)
log "Build tardo ~$(( (END-START)/60 )) min. (Asterisk queda para el 1er boot de la Pi)"

# -------------------- 6. COPIAR .img --------------------
echo "==> 6/6 Copiando .img final..."
SRC="$PIGEN/deploy/$IMG_NAME.img"
DST="$HERE/$IMG_NAME.img"
if [[ -f "$SRC" ]]; then
  cp -v "$SRC" "$DST"
  SZ=$(du -h "$DST" | cut -f1)
  echo ""
  log "============================================="
  log "Imagen lista: $DST  ($SZ)"
  log "============================================="
  echo "  Flashea con BalenaEtcher o Raspberry Pi Imager."
  echo "  Primer arranque (headless, SSH activo):"
  echo "    ssh admin@<IP-DE-LA-PI>   (clave: admin123)"
  echo "  Panel publico: http://<IP-DE-LA-PI>:8080/"
  echo "  Panel admin  : http://<IP-DE-LA-PI>:8080/admin  (admin/admin123)"
  echo "  Primer arranque (auto, sin tocar nada):"
  echo "    - Asterisk se instala solo desde .deb (instantaneo)."
  echo "    - MMDVMHost se compila e instala solo (~5-10 min) y el servicio arranca."
  echo "    - El UART de la Pi se libera (consola serie + BT fuera) -> modulo MMDVM listo."
  echo "  Sigue el avance con: ssh admin@<IP> 'journalctl -u mediguard-firstboot -f'"
  echo "  Siguiente paso desde el panel admin:"
  echo "    1) Parametros -> IP central hospital -> Guardar"
  echo "    2) Extensiones -> claves SIP -> Aplicar a Asterisk"
  echo "    3) Parametros -> MMDVM -> cargar Callsign/Puerto/Frecuencia reales -> Aplicar"
  echo ""
else
  err "No se encontro $SRC. Revisa el log de pi-gen arriba (etapa 5)."
  err "Tip: si fallo por arquitectura, confirma que pi-gen este en el branch arm64."
  exit 1
fi