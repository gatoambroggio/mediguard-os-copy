# Despliegue rapido del sistema POCSAG

Esta guia explica como actualizar el sistema en el servidor **sin reinstalar
todo**. El metodo profesional usa `deploy.sh` + el modo `--update` del
`instalador.sh`: sube solo los cambios y preserva la base de datos, logs y
configuraciones.

---

## 1. Por que no reinstalar todo

La primera vez ejecutaste `sudo bash instalador.sh`. Eso instala apt, pip,
Asterisk, FreePBX, genera los servicios, la base de datos, las locuciones,
etc. Repetir eso para cambiar una etiqueta del panel web es innecesario y
lento.

El **modo `--update`** saltea las partes costosas (dependencias, Asterisk,
FreePBX, locuciones) y solo regenera los archivos del sistema (backend, paneles
web, scripts AGI, encoder), recarga Asterisk y reinicia la API.

### Que preserva vs que regenera

| Se PRESERVA (no se toca)      | Se REGENERA (se sobrescribe)            |
| ----------------------------- | --------------------------------------- |
| `database/pocsag.db` (datos)  | `backend/app.py`                        |
| `logs/*.log`                  | `database/db_manager.py`               |
| `audio/*.gsm` (locuciones)    | `frontend/index.html` y `admin.html`    |
| `config/server.conf`          | `agi/pocsag_handler.py`, `pocsag_check.py` |
| `/etc/asterisk/*.conf`        | `encoder/pocsag_gen.py`                 |
| Servicios systemd (ya activos)| `scripts/*.sh`, `asterisk/*.conf` local |

> La base de datos es segura: el `init` usa `CREATE TABLE IF NOT EXISTS` y
> `INSERT OR IGNORE`, asi que nunca borra pagers, grupos, extensiones ni
> historial existentes.

---

## 2. Requisitos (una sola vez)

1. **Acceso SSH** desde tu PC al servidor. Probalo:
   ```bash
   ssh usuario@192.168.1.10
   ```
   Si pide clave cada vez, genera una clave y copiala:
   ```bash
   ssh-keygen -t ed25519            # en tu PC (Enter a todo)
   ssh-copy-id usuario@192.168.1.10
   ```
2. **sudo sin clave** para el usuario (recomendado) o que el usuario sea root.
   Para permitir sudo sin clave al usuario:
   ```bash
   echo "usuario ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/usuario
   ```

---

## 3. Configuracion

Edita `src/deploy.sh` y pone la direccion de tu servidor en la linea:

```bash
SERVIDOR="${POCSAG_SERVIDOR:-usuario@192.168.1.10}"
```

O pasala como variable de entorno o argumento al ejecutar (ver punto 4).

---

## 4. Uso

Desde la carpeta del ZIP (donde esta `instalador.sh`):

```bash
# Usando el servidor default configurado en deploy.sh
bash src/deploy.sh

# Pasando el servidor como argumento
bash src/deploy.sh admin@10.0.0.5

# Pasando el servidor por variable de entorno
POCSAG_SERVIDOR=admin@10.0.0.5 bash src/deploy.sh

# Aplicar cambios SIN reiniciar servicios (para no cortar llamadas activas)
bash src/deploy.sh --no-restart
```

Despues de `--no-restart`, reinicia a mano cuando quieras:
```bash
ssh admin@10.0.0.5 'sudo systemctl restart pocsag-api'
```

---

## 5. Como funciona por dentro (paso a paso)

1. `deploy.sh` localiza `instalador.sh` (junto al script o en la raiz del ZIP).
2. Lo sube al servidor con `scp` a `/tmp/instalador_pocsag.sh`.
3. Ejecuta por SSH: `sudo bash /tmp/instalador_pocsag.sh --update`.
4. El instalador detecta `--update` y:
   - Saltea **secciones 1, 2, 3** (dependencias, Asterisk, FreePBX) y la
     **seccion 8** (locuciones IVR).
   - Ejecuta **secciones 4-7**: crea la estructura, regenera todos los
     archivos, inicializa la base (sin perder datos) e integra dialplan + AGI.
   - Ejecuta **seccion 9**: recarga `dialplan` y `pjsip` de Asterisk, reinicia
     `pocsag-api`.
   - Ejecuta **seccion 10**: healthcheck final.

Todo esto tarda segundos, no minutos.

---

## 6. Alternativa: rsync directo (avanzado)

Si queres sincronizar una carpeta local con el servidor sin pasar por el
instalador, podes usar `rsync`. Esto transfiere **solo los bytes que cambiaron**
de cada archivo (no reenvia archivos completos).

```bash
# Sincroniza el backend y los paneles web, excluyendo datos sensibles
rsync -avz --delete \
  --exclude 'database/' \
  --exclude 'logs/' \
  --exclude 'audio/' \
  --exclude '*.db' \
  ./src/pocsag-server/ \
  usuario@192.168.1.10:/opt/pocsag-server/

# Luego reinicia la API y recarga Asterisk
ssh usuario@192.168.1.10 'sudo systemctl restart pocsag-api && sudo asterisk -rx "dialplan reload"'
```

### Que hace cada flag de rsync

| Flag | Significado |
| ---- | ----------- |
| `-a` | **archive**: preserva permisos, fechas, symlinks y recursa directorios. Es un conjunto de flags (`-rlptgoD`). |
| `-v` | **verbose**: muestra los archivos que se transfieren. |
| `-z` | **compress**: comprime los datos durante la transferencia (util en redes lentas). |
| `--delete` | borra en el destino los archivos que ya no existen en el origen (cuidado: confirma antes). |
| `--exclude` | ignora patrones (aca protegemos la base, los logs y el audio). |
| `-n` | **dry-run** (no lo usamos arriba, pero probalo antes): simula sin escribir nada. `rsync -avzn ...` |

> **Precaucion con `--delete`**: si en el servidor tenes archivos que no estan
> en tu carpeta local, se borraran. Para una prueba segura, agregale `-n`
> (dry-run) y revisa que haria antes de ejecutarlo en serio.

**Para cambios puntuales de un solo archivo** (sin rsync):
```bash
scp src/pocsag-server/backend/app.py usuario@192.168.1.10:/opt/pocsag-server/backend/
ssh usuario@192.168.1.10 'sudo systemctl restart pocsag-api'
```

---

## 7. Tabla resumen: que cambia y que comando usar

| Que cambiaste                     | Comando para aplicar                          |
| --------------------------------- | --------------------------------------------- |
| Panel web (`index.html`/`admin.html`) | `bash src/deploy.sh` (solo reinicia pocsag-api) |
| Backend (`app.py`, `db_manager.py`)   | `bash src/deploy.sh`                          |
| AGI o encoder                        | `bash src/deploy.sh` (recarga tambien Asterisk) |
| Esquema de base de datos              | Manual: ver seccion 8                         |
| Config de Asterisk (`*.conf`)          | `bash src/deploy.sh`                          |

---

## 8. Cambios de esquema de base de datos

El modo `--update` NO modifica tablas existentes (es seguro: no rompe datos).
Si el cambio requiere una **tabla nueva** o un **campo nuevo**, aplicalo a mano:

```bash
ssh usuario@192.168.1.10 'sudo sqlite3 /opt/pocsag-server/database/pocsag.db'
```

Y ejecuta el `ALTER TABLE` o `CREATE TABLE` correspondiente. Ejemplo:
```sql
ALTER TABLE pagers ADD COLUMN prioridad INTEGER DEFAULT 0;
```

---

## 9. Solucion de problemas

**`Permission denied (publickey)`** al hacer ssh/scp:
- Falta `ssh-copy-id usuario@servidor` (ver punto 2).

**`sudo: se requiere una contraseña`** en el servidor:
- El usuario no tiene sudo sin clave. Configuralo (ver punto 2) o ejecuta
  `deploy.sh` logueado como root: cambia `SERVIDOR` a `root@servidor`.

**El panel no refleja los cambios**:
- El navegador cachea el HTML. Hace `Ctrl+Shift+R` (recarga forzada).
- Confirma que el deploy termino con `[OK] Despliegue completo`.

**La API no responde despues de actualizar**:
- Verifica el servicio: `ssh usuario@servidor 'sudo systemctl status pocsag-api'`
- Ver logs: `ssh usuario@servidor 'sudo journalctl -u pocsag-api -n 50'`

**Asterisk no recargo el dialplan**:
- A mano: `ssh usuario@servidor 'sudo asterisk -rx "dialplan reload"'`

---

## 10. Rollback (volver atras)

Si un deploy rompe algo, los archivos anteriores se sobrescribieron. Para
recuperar, re-ejecuta un `instalador.sh` anterior (si lo guardaste) o
restaura desde un backup de `/opt/pocsag-server` (recomendado antes de
cambios grandes):

```bash
# Backup previo (en el servidor)
sudo tar czf /tmp/pocsag-backup-$(date +%F).tar.gz /opt/pocsag-server
```

La base de datos (`pocsag.db`) nunca se toca en `--update`, asi que tus datos
siempre estan a salvo.