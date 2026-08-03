# Pogsac

Sistema de paginacion hospitalaria POCSAG (modo cliente) - STANDALONE.

## Arquitectura (v1.0)

- **Totalmente self-contained**: no depende de `instalador.sh` ni de `pjsip_pocsag.conf`.
- **Todo en la base de datos**: IP del hospital, transporte, codecs, claves, etc.
- **PJSIP self-contained**: `pjsip_hospital.conf` incluye su propio `[transport-udp]`.
- **pjsip.conf** solo incluye `pjsip_hospital.conf` (sin transportes duplicados).

## Instalacion (una linea)

```bash
curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/instalador_client.sh | sudo bash
```

## Actualizar (sin perder configuracion)

```bash
curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/instalador_client.sh | sudo bash -s -- --update
```

El `--update` NO pisara la IP del hospital ni las claves ya configuradas.
Regenera `pjsip_hospital.conf` desde la base de datos automaticamente.

## Como funciona

1. Los internos 2000-2010 se registran contra la central VoIP del hospital (FreePBX, PJSIP registration).
2. Desde cualquier telefono de la central, al marcar 2000-2010 o 177, la central enruta la llamada al Asterisk.
3. El Asterisk contesta con el IVR: codigo -> mensaje -> envio POCSAG.

## Configuracion post-install (todo desde el panel admin)

`http://servidor:8080/admin` (admin / admin123):

1. **Parametros** -> IP central del hospital (default 192.168.2.97) -> Guardar
2. **Extensiones** -> editar cada interno (2000-2010) con su clave real
3. **Extensiones** -> Aplicar a Asterisk (regenera `pjsip_hospital.conf`)
4. La columna "Registro" muestra Registered / No registrado en vivo (auto-refresh 5s)

## Parametros gestionados desde la base de datos

| Clave BD | Descripcion | Default |
|----------|-------------|---------|
| `hospital_pbx_ip` | IP de la central del hospital (FreePBX) | `192.168.2.97` |
| `transport_bind` | Bind del transporte UDP | `0.0.0.0:5060` |
| `transport_protocol` | Protocolo transporte | `udp` |
| `codecs` | Codecs permitidos | `ulaw,alaw` |
| `retry_interval` | Intervalo reintento registro | `60` |
| `expiration` | Expiracion registro | `3600` |
| `test_mode` | Modo prueba (sin radio) | `1` |

## Verificacion por consola

```bash
sudo asterisk -rx 'pjsip show registrations'
sudo asterisk -rx 'dialplan show pocsag-incoming'
cat /etc/asterisk/pjsip_hospital.conf
```

## Archivos clave

| Archivo | Funcion |
|---------|---------|
| `instalador_client.sh` | Instalador standalone (raiz del repo) |
| `backend/app.py` | API REST + panel web |
| `database/db_manager.py` | BD + `generar_pjsip_hospital_conf()` |
| `database/schema.sql` | Esquema BD (todas las tablas) |
| `database/seed.sql` | Datos iniciales (2000-2010, pagers, config) |
| `frontend/admin.html` | Panel admin con gestion completa |
| `frontend/index.html` | Pagina publica de envio |
| `asterisk/pjsip_hospital.conf` | Template inicial (se regenera desde BD) |
| `asterisk/extensions_hospital.conf` | IVR autocontenido |
| `agi/pocsag_handler.py` | AGI: procesa llamadas IVR |
| `encoder/pocsag_gen.py` | Codificador POCSAG |

## Version

1.0 (Pogsac - FreePBX 192.168.2.97, internos 2000-2010)