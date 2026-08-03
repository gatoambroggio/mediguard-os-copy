# Sistema de Paginación Hospitalaria con Codificación POCSAG sobre VoIP

**Versión:** 1.0
**Plataforma objetivo:** Ubuntu Server 22.04 LTS (x86_64 o ARM64)
**Última actualización:** 2026-07-31

---

## 1. Descripción general

Sistema autónomo de paginación hospitalaria que combina una **central VoIP (Asterisk)** con un **codificador POCSAG** y un **transmisor VHF/HF**. Permite que cualquier interno telefónico del hospital dispare un mensaje codificado hacia paginadores (pagers) individuales o grupales.

### Flujo operativo

1. El operador **descuelga y marca un interno** (ej. `2184`) que corresponde a la central de paginación.
2. Asterisk **atiende la llamada** y reproduce una locución: *"Marque su número de código"* seguida de un **tono (pip)**.
3. El operador **marca el código** por tonos DTMF.
4. Asterisk reproduce *"Marque su mensaje"* seguido de un **tono (pip)**.
5. El operador **marca el mensaje** por DTMF.
6. El sistema **codifica el código + mensaje en POCSAG** (función/alias + texto numérico/alfanumérico).
7. El frame POCSAG se envía como **audio modulado** hacia el transmisor (VHF o HF), activando PTT.
8. El transmisor **irradia la señal** hacia los pagers destino (persona, grupo o broadcast).

---

## 2. Arquitectura

```
+----------------+      SIP/RTP      +------------------+      Audio + PTT      +-------------------+
|  Teléfono IP   | <--------------> |   Asterisk PBX   | -------------------> | Transmisor VHF/HF |
|  (interno)     |                  |  (dialplan IVR)  |                     | (o SDR TX)         |
+----------------+                  +--------+--------+                     +---------+---------+
                                             |                                       |
                                             |  consulta / comandos                  | RF (POCSAG)
                                             v                                       v
                                    +------------------+                     +-------------------+
                                    |  Codificador      |                    |  Paginadores      |
                                    |  POCSAG (CLI)     |                    |  (pagers)         |
                                    +--------+---------+                    +-------------------+
                                             |
                                             | persistencia
                                             v
                                    +------------------+
                                    |  Base de datos    |
                                    |  (SQLite)         |
                                    +------------------+
```

### Componentes de software

| Componente        | Función                                         | Paquete / proyecto sugerido        |
|-------------------|-------------------------------------------------|------------------------------------|
| Sistema base      | SO                                              | Ubuntu Server 22.04 LTS            |
| PBX VoIP          | Atender llamada, IVR, captura DTMF              | Asterisk 18 o 20 (apt)             |
| Codificador       | Generar audio POCSAG desde código + mensaje     | `pocsag` (GitHub: f4exb/pocsag) o `rtl-pager` |
| Interfaz TX       | PTT + audio al transmisor                       | GPIO (wiringPi/libgpiod) o serial  |
| Base de datos     | Códigos, destinatarios, grupos, bitácora        | SQLite (apt)                       |
| Orquestación      | Unir dialplan → codificador → transmisor         | Bash + AGI (Asterisk Gateway Intf.)|
| Servicios         | Inicio automático, monitoreo                     | systemd                            |

### Componentes de hardware (mínimo)

- Servidor con tarjeta de sonido USB o GPIO (Raspberry Pi 4/5 también válido).
- Transmisor VHF/HF con entrada de audio + control de PTT (HT o placa dedicada).
- Paginadores compatibles con POCSAG (Motorola, etc.).
- *Opcional:* SDR transmisor (HackRF, PlutoSDR) en lugar de transmisor convencional.

---

## 3. Flujo detallado de la llamada (dialplan)

1. **Llamada entrante al interno de paginación** (configurable; aquí `2184`).
2. Asterisk conteste: `Playback("marque-codigo")` → `Playback("beep")`.
3. `Read(CODE, "beep", 8, ..., 5000)` — captura DTMF del código (timeout 5s).
4. `Playback("marque-mensaje")` → `Playback("beep")`.
5. `Read(MESSAGE, "beep", 16, ..., 8000)` — captura DTMF del mensaje.
6. Validación contra la base de datos (¿el código existe? ¿a qué grupo/persona apunta?).
7. Llamada al AGI `agi_pocsag.agi` que:
   - Recupera el destinatario/grupo desde SQLite.
   - Invoca el codificador POCSAG generando el archivo de audio `.wav` (1200 o 512 bps).
   - Activa PTT del transmisor.
   - Reproduce el `.wav` hacia la salida de audio conectada al TX.
   - Desactiva PTT.
   - Registra el envío en la bitácora.
8. Reproduce confirmación y cuelga.

### Tasa de baudios POCSAG

- **512 bps** — mayor alcance, recomendado para HF.
- **1200 bps** — más rápido, estándar para VHF urbano.
- Configurable por canal/destinatario en la base de datos.

---

## 4. Modelo de datos (SQLite)

```sql
-- Códigos de paginación mapeados a destinatarios o grupos
CREATE TABLE codigos (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo        TEXT UNIQUE NOT NULL,         -- ej. "11", "2184"
  tipo          TEXT NOT NULL,                 -- 'individual' | 'grupo' | 'broadcast'
  cap_code      TEXT,                          -- POCSAG capcode/ric del pager o del grupo
  baudios       INTEGER DEFAULT 1200,          -- 512 | 1200 | 2400
  descripcion   TEXT,
  activo        INTEGER DEFAULT 1
);

-- Grupos de pagers (un grupo puede reenviar a varios capcodes)
CREATE TABLE grupos (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  nombre      TEXT UNIQUE NOT NULL,
  cap_code    TEXT,                            -- capcode grupal POCSAG
  baudios     INTEGER DEFAULT 1200
);

CREATE TABLE grupo_miembros (
  grupo_id    INTEGER REFERENCES grupos(id),
  cap_code   TEXT NOT NULL,
  PRIMARY KEY (grupo_id, cap_code)
);

-- Bitácora de envíos (auditoría hospitalaria)
CREATE TABLE bitacora (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  fecha_hora    DATETIME DEFAULT CURRENT_TIMESTAMP,
  interno_origen TEXT,
  codigo        TEXT,
  cap_code      TEXT,
  mensaje       TEXT,
  baudios       INTEGER,
  estado        TEXT,                          -- 'enviado' | 'error'
  observaciones TEXT
);
```

### Convención de códigos (ejemplo, editable)

| Código | Significado                         | Tipo        |
|--------|------------------------------------|-------------|
| 11     | Código Azul (paro cardíaco)        | grupo       |
| 12     | Código Rojo (incendio)             | broadcast   |
| 13     | Código Blanco (evacuación)        | broadcast   |
| 21     | Médico de guardia                  | individual  |
| 99     | Prueba de sistema                  | individual  |

---

## 5. Estructura de archivos del proyecto

```
/opt/pocsag-server/
├── install.sh
├── README.md
├── docs/
│   └── SISTEMA_PAGERS_POCSAG.md
├── etc/
│   ├── asterisk/
│   │   ├── extensions_pocsag.conf        # dialplan IVR + AGI
│   │   └── pjsip_pocsag.conf             # trunk/SIP opcional
│   ├── pocsag/
│   │   ├── config.json                   # parámetros del codificador
│   │   └── ptt_gpio.conf                  # pin GPIO / comando PTT
│   └── systemd/
│       └── pocsag-monitor.service        # monitoreo/healthcheck
├── bin/
│   ├── agi_pocsag.agi                    # AGI Asterisk (orchestration)
│   ├── pocsag_encode.sh                  # wrapper del codificador
│   ├── ptt_on.sh                         # activa PTT
│   ├── ptt_off.sh                        # desactiva PTT
│   └── db_utils.sh                       # helpers SQLite
├── audio/
│   ├── marque-codigo.gsm                 # locución IVR
│   ├── marque-mensaje.gsm
│   └── beep.gsm
├── db/
│   └── pocsag.db                         # SQLite (se crea en install)
└── logs/
    └── pocsag.log
```

---

## 6. Codificador POCSAG

Opciones recomendadas (elegir una):

### Opción A — `pocsag` (línea de comandos, C++)
- Repo: https://github.com/f4exb/pocsag
- Genera archivo de audio `.wav` con la trama POCSAG.
- Uso: `pocsag --capcode <RIC> --baud <512|1200> --message "<texto>" --out out.wav`

### Opción B — `rtl-pager` (con SDR transmisor)
- Repo: https://github.com/roger-/rtl-pager
- Transmite directamente vía HackRF/PlutoSDR sin transmisor convencional.

### Opción C — Implementación propia
- Script Python con la librería `pocsag` (PyPI) para generar `.wav`:
  ```python
  from pocsag import encode
  encode('out.wav', [(capcode, 'N', mensaje)], baud=1200)
  ```
- Recomendado para control total y fácil integración con el AGI.

El `install.sh` instala la **Opción C** por defecto (Python `pocsag`) por su simplicidad, y deja documentadas A y B.

---

## 7. Interfaz con el transmisor (PTT)

### Modo GPIO (Raspberry Pi / pin header del servidor)
- `ptt_on.sh`: `gpioset gpiochip4 17=1` (ajustar chip/pin al hardware).
- `ptt_off.sh`: `gpioset gpiochip4 17=0`.

### Modo serie / relé USB
- `ptt_on.sh`: `stty -F /dev/ttyUSB0 9600 && echo -n 'ON' > /dev/ttyUSB0`
- Controlador externo activa el PTT del radio.

### Modo SDR (sin transmisor convencional)
- `rtl-pager` maneja TX + PTT internamente.

El audio del `.wav` POCSAG se reproduce por la **salida de audio** del servidor conectada a la entrada MIC/AUX del transmisor. Nivel de audio y desviación deben calibrarse con un frecuencímetro/deviaciónmetro (típ. ±4.5 kHz para POCSAG).

---

## 8. Dialplan de Asterisk (ejemplo)

`etc/asterisk/extensions_pocsag.conf`:

```ini
[pocsag-incoming]
exten => 2184,1,NoOp(Paginación hospitalaria)
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
 same => n,AGI(agi_pocsag.agi,${CALLERID(num)},${CODE},${MESSAGE})
 same => n,Playback(confirmado)
 same => n(fin),Hangup()
 same => n(error),Playback(codigo-invalido)
 same => n,Hangup()
```

Incluirlo en `/etc/asterisk/extensions.conf` con `#include extensions_pocsag.conf` o vía `modules`.

---

## 9. AGI de orquestación (esqueleto)

`bin/agi_pocsag.agi` (Bash, recibe `interno codigo mensaje`):

```bash
#!/usr/bin/env bash
set -euo pipefail
INTERNO="$1"; CODIGO="$2"; MENSAJE="$3"
BASE=/opt/pocsag-server
DB="$BASE/db/pocsag.db"

# 1. Resolver destinatario/grupo desde la BD
ROW=$(sqlite3 "$DB" "SELECT cap_code, baudios, tipo FROM codigos WHERE codigo='$CODIGO' AND activo=1")
[ -z "$ROW" ] && { echo "ESTADO=error" >&2; exit 1; }
CAPCODE=$(echo "$ROW" | cut -d'|' -f1)
BAUD=$(echo "$ROW" | cut -d'|' -f2)

# 2. Codificar POCSAG -> wav
WAV="$BASE/audio/out_${CAPCODE}.wav"
"$BASE/bin/pocsag_encode.sh" "$CAPCODE" "$MENSAJE" "$BAUD" "$WAV"

# 3. Activar PTT y transmitir
"$BASE/bin/ptt_on.sh"
aplay -q "$WAV"
"$BASE/bin/ptt_off.sh"

# 4. Bitácora
sqlite3 "$DB" "INSERT INTO bitacora (interno_origen,codigo,cap_code,mensaje,baudios,estado)
               VALUES ('$INTERNO','$CODIGO','$CAPCODE','$MENSAJE','$BAUD','enviado');"
```

`bin/pocsag_encode.sh` (wrapper Python):

```bash
#!/usr/bin/env bash
# args: capcode mensaje baudios salida.wav
python3 -c "
from pocsag import encode
import sys
encode(sys.argv[4], [(int(sys.argv[1]), 'N', sys.argv[2])], baud=int(sys.argv[3]))
" "$@"
```

---

## 10. Requisitos previos

- Ubuntu Server 22.04 LTS actualizado.
- Usuario con `sudo`.
- Acceso a internet para instalar paquetes.
- **Salida de audio** funcional (`aplay -l` debe listar un dispositivo).
- **Control de PTT** funcional (GPIO, relé USB o SDR) según el modo elegido.
- Teléfono SIP o softphone para probar el interno `2184`.
- Transmisor VHF/HF calibrado + antena + licencia de radio válido (responsabilidad del hospital).

### Supuestos de licencia / regulación

La operación de transmisores de radio está sujeta a la normativa local (ENACOM en Argentina). Es responsabilidad del hospital contar con la **habilitación de frecuencia y potencia** correspondientes. Este sistema no reemplaza la certificación reglamentaria del enlace de radio.

---

## 11. Instalación

```bash
sudo bash install.sh
```

El script:
1. Verifica Ubuntu 22.04.
2. Instala dependencias (Asterisk, SQLite, Python, ALSA, etc.).
3. Copia archivos a `/opt/pocsag-server`.
4. Crea la base de datos SQLite con esquema y códigos de ejemplo.
5. Configura el dialplan de Asterisk y recarga.
6. Instala los servicios `systemd`.
7. Genera locuciones IVR si no existen.
8. Deja un chequeo final (`make check` equivalente).

Ver sección 12 del `install.sh` para pruebas.

---

## 12. Pruebas

1. **Audio del codificador:**
   `bash bin/pocsag_encode.sh 123456 99 1200 /tmp/test.wav && aplay /tmp/test.wav`
2. **PTT:**
   `bash bin/ptt_on.sh && sleep 1 && bash bin/ptt_off.sh`
3. **Llamada IVR:**
   Marcar `2184` desde un SIP y recorrer el flujo de códigos.
4. **Bitácora:**
   `sqlite3 db/pocsag.db "SELECT * FROM bitacora ORDER BY id DESC LIMIT 5;"`

---

## 13. Seguridad y mantenimiento

- Restringir el interno de paginación a extensiones autorizadas (contexto SIP separado).
- Backups diarios de `db/pocsag.db` (cron).
- Monitoreo de salud del servicio con `systemctl status pocsag-monitor`.
- Rotación de logs con `logrotate`.
- Auditoría periódica de la bitácora (requisito hospitalario).

---

## 14. Entregables al programador

1. Este documento (`docs/SISTEMA_PAGERS_POCSAG.md`).
2. `install.sh` reproducible y idempotente.
3. Esquema de base de datos (`db/`).
4. Dialplan de Asterisk (`etc/asterisk/`).
5. AGI + scripts (`bin/`).
6. Locuciones IVR (`audio/`) — a grabar con locución hospitalaria.
7. Configuración PTT (`etc/pocsag/ptt_gpio.conf`) — a adaptar al hardware real.

---

## 15. Pendientes que el programador debe resolver según el hardware

- Pin GPIO / chip exacto para PTT (varía por placa).
- Nivel de audio y desviación del transmisor (calibración con instrumentos).
- Elección final del codificador (A, B o C) según disponibilidad y complejidad.
- Frecuencia de TX autorizada por ENACOM.
- Si se usa SDR TX en lugar de transmisor convencional, ajustar `bin/pocsag_encode.sh` y eliminar scripts de PTT.