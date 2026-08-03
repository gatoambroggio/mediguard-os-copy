#!/usr/bin/env bash
# ============================================================================
# pullupdate.sh  -  Actualiza el sistema POCSAG desde GitHub con un comando
# ============================================================================
# Flujo:
#   1. git pull   -> baja los ultimos cambios del repositorio
#   2. instalador.sh --update -> aplica los cambios (sin reinstalar dependencias,
#      preservando la base de datos, logs, audio y configs)
#
# Uso (en el servidor, dentro del clon del repositorio):
#   bash pullupdate.sh
#
# Requisitos:
#   - El repo ya clonado en el servidor y con acceso SSH a GitHub configurado.
#   - El usuario debe poder ejecutar sudo (para instalador.sh --update).
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

echo "==> 1/2 Bajando cambios de GitHub (git pull)..."
git pull --ff-only

echo "==> 2/2 Aplicando actualizacion (instalador.sh --update)..."
sudo bash instalador.sh --update

echo ""
echo "[OK] Sistema POCSAG actualizado desde GitHub."
echo "     Panel publico: http://localhost:8080/"
echo "     Panel admin  : http://localhost:8080/admin"