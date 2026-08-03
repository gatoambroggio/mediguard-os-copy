# Sistema de Paginación Hospitalaria con Codificación POCSAG sobre VoIP

**Versión:** 1.0 · **Plataforma:** Ubuntu Server 22.04 LTS · **Actualizado:** 2026-07-31

## 1. Descripción general

Sistema autónomo de paginación hospitalaria que combina una **central VoIP (Asterisk)** con un **codificador POCSAG** y un **transmisor VHF/HF**. Permite que cualquier interno telefónico del hospital dispare un mensaje codificado hacia paginadores individuales o grupales.

### Flujo operativo

1. El operador **descuelga y marca el interno** (ej. `2184`).
2. Asterisk **atiende** y reproduce *"Marque su número de código"* + **pip**.
3. El operador **marca el código** por DTMF.
4. Asterisk reproduce *"Marque su mensaje"* + **pip**.
5. El operador **marca el mensaje** por DTMF.
6. El AGI resuelve el destinatario/grupo en SQLite, **codifica POCSAG**, **activa PTT**, reproduce el audio modulado, **desactiva PTT** y registra en bitácora.
7. El transmisor **irradia** hacia los pagers (persona, grupo o broadcast).

## 2. Arquitectura

```
+----------------+   SIP/RTP   +------------------+  Audio+PTT  +-------------------+
|  Teléfono IP   | <---------> |   Asterisk PBX   | ---------> | Transmisor VHF/HF |
+----------------+             |  (dialplan IVR)  |            +---------+---------+
                               +--------+--------+                      |
                                        | consulta/AGI                     | RF (POCSAG)
                                        v                                  v
                               +------------------+             +-------------------+
                               |  AGI + DB manager |             |  Paginadores      |
                               +--------+---------+             +-------------------+
                                        | persistencia
                                        v
                               +------------------+
                               |  SQLite          |
                               +------------------+
```

### Componentes

| Componente    | Función                                  | Paquete/proyecto          |
|---------------|------------------------------------------|---------------------------|
| SO            | Ubuntu Server 22.04 LTS                  | apt                       |
| PBX VoIP      | Atender llamada, IVR, captura DTMF       | Asterisk 18/20            |
| AGI           | Orquestar código→encoder→TX→bitácora    | Python (agi/pocsag_handler.py) |
| Codificador   | Generar audio POCSAG                     | python `pocsag` (alt: f4exb, rtl-pager) |
| PTT           | Activar TX                               | GPIO (gpiod) / relé USB / SDR |
| Base de datos | Códigos, grupos, bitácora                | SQLite                    |
| API + panel   | Gestión y monitoreo web                  | backend/app.py + frontend/index.html |
| Servicios     | Inicio automático                        | systemd                   |

## 3. Modelo de datos (SQLite)

Ver `database/schema.sql`. Tablas: `codigos`, `grupos`, `grupo_miembros`, `bitacora`.

### Convención de códigos (ejemplo)

| Código | Significado                  | Tipo        |
|--------|------------------------------|-------------|
| 11     | Código Azul (paro cardíaco) | grupo       |
| 12     | Código Rojo (incendio)       | broadcast   |
| 13     | Código Blanco (evacuación)   | broadcast   |
| 21     | Médico de guardia            | individual  |
| 99     | Prueba de sistema            | individual  |

## 4. Dialplan de Asterisk

Ver `asterisk/extensions_pocsag.conf`. Resumen:

```ini
[pocsag-incoming]
exten => 2184,1,NoOp(=== Paginación hospitalaria ===)
 same => n,Answer()
 same => n,Set(TIMEOUT(digit)=5)
 same => n,Set(TIMEOUT(response)=20)
 same => n,Playback(marque-codigo)
 same => n,Playback(beep)
 same => n,Read(CODE,,8,,3,5)
 same => n,GotoIf($["${CODE}" = ""]?fin:error)
 same => n,Playback(marque-mensaje)
 same => n,Playback(beep)
 same => n,Read(MESSAGE,,16,,3,8)
 same => n,AGI(pocsag_handler.py,${CALLERID(num)},${CODE},${MESSAGE})
 same => n,GotoIf($["${AGISTATUS}" = "SUCCESS"]?ok:fail)
 same => n(ok),Playback(confirmado)
 same => n(fin),Hangup()
 same => n(fail),Playback(error-envio)
 same => n,Hangup()
 same => n(error),Playback(codigo-invalido)
 same => n,Hangup()
```

## 5. AGI de orquestación

`agi/pocsag_handler.py` recibe `(interno, codigo, mensaje)`:
1. `db_manager.resolver_codigo(codigo)` → `(cap_code, baudios, tipo)`.
2. Invoca `encoder/pocsag_gen.py` para generar el `.wav` POCSAG.
3. `scripts/ptt_on.sh` → `aplay` → `scripts/ptt_off.sh`.
4. `db_manager.registrar_bitacora(...)` con estado `enviado` o `error`.
5. Setea `AGISTATUS` para el dialplan.

## 6. Codificador POCSAG

`encoder/pocsag_gen.py` soporta tres backends (variable `POCSAG_BACKEND`):
- **python** (default): `pip3 install pocsag`, genera `.wav`.
- **f4exb**: binario compilado de https://github.com/f4exb/pocsag.
- **rtl-pager**: SDR TX directo (HackRF/PlutoSDR), https://github.com/roger-/rtl-pager.

Tasa configurable: 512 (HF), 1200 (VHF urbano), 2400.

## 7. Interfaz con el transmisor (PTT)

`scripts/ptt_on.sh` / `scripts/ptt_off.sh`:
- **GPIO** (default): `gpioset gpiochip4 17=1`. Ajustar chip/pin al hardware.
- **Relé USB**: `/dev/ttyUSB0`.
- **SDR**: `rtl-pager` maneja PTT internamente.

Audio del `.wav` POCSAG → salida de audio del servidor → entrada MIC/AUX del TX. Desviación objetivo ±4.5 kHz (calibrar con instrumentos).

## 8. API + panel web

- `backend/app.py`: HTTP server en `:8080`, sin dependencias extra (stdlib).
  - `GET /api/codigos` → lista de códigos.
  - `GET /api/bitacora` → últimos 50 envíos.
  - `GET /api/health` → estado.
  - `GET /` → sirve `frontend/index.html`.
- `frontend/index.html`: panel estático (códigos + bitácora + estado).

## 9. Pruebas

`tests/run_tests.sh` ejecuta:
- `tests/test_encoder.py` — genera un `.wav` POCSAG y verifica tamaño.
- `tests/test_db.py` — resuelve el código de ejemplo "11".
- Sintaxis bash de scripts de PTT y healthcheck.

## 10. Seguridad y mantenimiento

- Restringir el interno de paginación a extensiones autorizadas (contexto SIP separado).
- Backups diarios de `database/pocsag.db` (cron).
- `logrotate` en `logs/*.log`.
- Auditoría periódica de la bitácora (requisito hospitalario).
- Permisos GPIO: `usermod -aG dialout asterisk`.

## 11. Pendientes que el programador debe resolver contra el hardware real

- Pin/chip GPIO exacto para PTT.
- Nivel de audio y desviación del transmisor (calibración con instrumentos).
- Backend de codificador final (python / f4exb / rtl-pager).
- Frecuencia de TX autorizada por ENACOM.
- Locuciones IVR profesionales (reemplazar las generadas con `espeak`).