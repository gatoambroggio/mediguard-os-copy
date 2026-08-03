# Instalación del sistema POCSAG en Ubuntu Server 22.04

## Requisitos previos

- Ubuntu Server 22.04 LTS actualizado (`sudo apt update && sudo apt upgrade -y`).
- Usuario con privilegios `sudo`.
- Acceso a internet (para instalar paquetes).
- Salida de audio funcional (`aplay -l` debe listar un dispositivo).
- Interfaz de PTT (GPIO, relé USB o SDR) según el hardware del transmisor.
- Transmisor VHF/HF calibrado con licencia ENACOM vigente (responsabilidad del hospital).

## Instalación

```bash
cd pocsag-server
sudo bash install.sh
```

El instalador:
1. Verifica Ubuntu 22.04.
2. Instala Asterisk, SQLite, Python 3, ALSA, sox, espeak, gpiod.
3. Copia el sistema a `/opt/pocsag-server`.
4. Inicializa la base de datos SQLite con esquema y códigos de ejemplo.
5. Despliega el dialplan de Asterisk y el endpoint SIP del interno `2184`.
6. Instala el AGI en `/var/lib/asterisk/agi-bin`.
7. Genera locuciones IVR de prueba con `espeak` (reemplazar por grabaciones profesionales).
8. Instala los servicios `systemd` (`pocsag-monitor`, `pocsag-api`).
9. Configura `logrotate` y recarga Asterisk.

## Configuración post-instalación

### 1. PTT (hardware)
Editá `scripts/ptt_on.sh` y `scripts/ptt_off.sh` con el chip y pin GPIO reales de tu placa.

### 2. Interno SIP
Editá `asterisk/pjsip_pocsag.conf` (copiado a `/etc/asterisk/`) y cambiá el `password` del interno `2184`. Registrá un teléfono SIP con ese usuario/contraseña.

### 3. Calibración de RF
- Nivel de audio hacia el transmisor (entrada MIC/AUX).
- Desviación objetivo: ±4.5 kHz para POCSAG.
- Usar deviaciónmetro/frecuencímetro. Responsabilidad del técnico de radio.

### 4. Prueba del flujo
```bash
# Desde el teléfono SIP registrado, marcar:
2184
# Escuchar: "Marque su número de código" + pip
# Marcar: 11  (Código Azul)
# Escuchar: "Marque su mensaje" + pip
# Marcar: 99
# Escuchar: "Mensaje enviado"
```

### 5. Verificación
```bash
make status                              # healthcheck
sqlite3 database/pocsag.db "SELECT * FROM bitacora ORDER BY id DESC LIMIT 5;"
```

## Panel web

La API de gestión escucha en `http://127.0.0.1:8080`. Abrí en un navegador el `index.html` servido por la misma API:
```
http://<servidor>:8080/
```

## Desinstalación

```bash
sudo bash uninstall.sh            # conserva DB (backup en /tmp)
sudo bash uninstall.sh --purge    # borra todo
```

## Actualización

```bash
sudo bash update.sh               # preserva DB y config personalizada
```

## Pruebas

```bash
make test   # o: bash tests/run_tests.sh
```

## Servicios systemd

| Servicio          | Función                                  |
|-------------------|------------------------------------------|
| `asterisk`        | PBX VoIP                                 |
| `pocsag-monitor`  | Vigila Asterisk + healthcheck cada 30s   |
| `pocsag-api`      | API + panel web en :8080                 |

```bash
systemctl status pocsag-monitor
journalctl -u pocsag-api -f
```

## Troubleshooting

- **No hay audio POCSAG:** verificar `python3 -c "import pocsag"` y `aplay -l`.
- **PTT no activa:** revisar permisos GPIO (`usermod -aG dialout asterisk`) y chip/pin.
- **Asterisk no recarga:** `asterisk -rvvv` para ver errores de dialplan.
- **DTMF no detectado:** usar codec G.711 (ulaw/alaw), no comprimidos.

## Nota regulatoria

La transmisión por radio está sujeta a la normativa local (ENACOM en Argentina). El hospital debe contar con la habilitación de frecuencia y potencia. Este software no reemplaza la certificación del enlace de radio.