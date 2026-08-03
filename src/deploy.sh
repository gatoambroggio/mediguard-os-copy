#!/usr/bin/env bash
# ============================================================================
# deploy.sh  -  Despliegue rapido del sistema POCSAG al servidor
# ============================================================================
# Sube instalador.sh al servidor y aplica SOLO los cambios (modo --update):
#   - NO reinstala dependencias (apt/pip), ni Asterisk, ni FreePBX.
#   - Regenera los archivos del sistema (backend, frontend, AGI, encoder).
#   - PRESERVA la base de datos (pocsag.db), logs, audio y configuraciones.
#   - Recarga Asterisk (dialplan + pjsip) y reinicia pocsag-api.
#
# Uso (desde la carpeta del ZIP, donde esta instalador.sh):
#   bash src/deploy.sh                              # usa el servidor default
#   POCSAG_SERVIDOR=admin@10.0.0.5 bash src/deploy.sh
#   bash src/deploy.sh admin@10.0.0.5               # servidor como argumento
#   bash src/deploy.sh --no-restart                 # aplicar sin reiniciar
#   bash src/deploy.sh admin@10.0.0.5 --no-restart
#
# Requisitos en tu PC: openssh-client (ssh, scp).
# El usuario del servidor debe poder ejecutar sudo sin pedir clave (o tener
# acceso root). Ver DEPLOY.md para configurar la clave SSH.
# ============================================================================
set -euo pipefail

# ---- CONFIGURACION (edita esta linea o usa POCSAG_SERVIDOR) -----------------
SERVIDOR="${POCSAG_SERVIDOR:-usuario@192.168.1.10}"
RESTART=1

for arg in "$@"; do
  case "$arg" in
    *@*) SERVIDOR="$arg" ;;            # parece usuario@host
    --no-restart) RESTART=0 ;;
  esac
done

# ---- Localizar instalador.sh (junto al script o en la raiz del ZIP) ---------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLER=""
for cand in "$SCRIPT_DIR/instalador.sh" "$SCRIPT_DIR/../instalador.sh" "$PWD/instalador.sh"; do
  [[ -f "$cand" ]] && INSTALLER="$cand" && break
done
[[ -z "$INSTALLER" ]] && { echo "[ERR] No encuentro instalador.sh junto a deploy.sh ni en el directorio actual."; exit 1; }

echo "==> Servidor destino : $SERVIDOR"
echo "==> instalador.sh    : $INSTALLER"
echo "==> Reiniciar servicios: $([ $RESTART -eq 1 ] && echo 'si' || echo 'no')"
echo ""

echo "==> Subiendo instalador.sh al servidor..."
scp -q "$INSTALLER" "$SERVIDOR:/tmp/instalador_pocsag.sh"

echo "==> Aplicando actualizacion (modo --update) en el servidor..."
if [[ $RESTART -eq 1 ]]; then
  ssh -t "$SERVIDOR" "sudo bash /tmp/instalador_pocsag.sh --update"
else
  ssh -t "$SERVIDOR" "sudo bash /tmp/instalador_pocsag.sh --update && echo '(--no-restart: servicios NO reiniciados; ejecuta: sudo systemctl restart pocsag-api)'"
fi

echo ""
echo "[OK] Despliegue completo."
echo "     Panel publico: http://<servidor>:8080/"
echo "     Panel admin  : http://<servidor>:8080/admin"
echo "     Ver logs API : ssh $SERVIDOR 'sudo journalctl -u pocsag-api -n 50'"