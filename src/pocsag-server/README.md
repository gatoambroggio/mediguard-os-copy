# pocsag-server

Sistema de **paginación hospitalaria** con codificación **POCSAG** sobre **VoIP (Asterisk)** y transmisión por **VHF/HF**, autónomo sobre **Ubuntu Server 22.04 LTS**.

## Flujo

1. El operador marca el interno de paginación (ej. `2184`).
2. Asterisk contesta: *"Marque su número de código"* → **pip**.
3. Operador marca el código por DTMF.
4. Asterisk: *"Marque su mensaje"* → **pip**.
5. Operador marca el mensaje por DTMF.
6. El AGI resuelve destinatario/grupo en la base de datos, codifica POCSAG, activa PTT, reproduce el audio modulado, desactiva PTT y registra en bitácora.
7. El transmisor VHF/HF irradia hacia los pagers.

## Estructura

```
pocsag-server/
├── install.sh      uninstall.sh   update.sh   Makefile   README.md
├── asterisk/       # dialplan + SIP/AGI config
├── agi/            # AGI Python (Asterisk Gateway Interface)
├── encoder/        # codificador POCSAG + modulador de audio
├── database/       # esquema SQLite + seed + manager
├── services/       # units de systemd
├── scripts/        # PTT, healthcheck, utilidades
├── config/         # configuración global
├── backend/        # API de gestión (Flask)
├── frontend/       # panel web estático
├── docs/           # documentación técnica
└── tests/          # pruebas encoder + db + flujo
```

## Instalación rápida

```bash
sudo bash install.sh
```

Ver `docs/INSTALACION.md` y `docs/SISTEMA_PAGERS_POCSAG.md` para detalles.

## Requisitos

- Ubuntu Server 22.04 LTS
- Asterisk 18+ (instalado por el script)
- Python 3.10
- Salida de audio + interfaz PTT (GPIO / relé USB / SDR)
- Transmisor VHF/HF calibrado (±4.5 kHz) con licencia ENACOM vigente