#!/usr/bin/env bash
# ============================================================================
# instalador.sh  -  Sistema de Paginacion Hospitalaria POCSAG sobre VoIP
# ============================================================================
# Objetivo: PBX Asterisk + sistema POCSAG integrado, en Ubuntu 22.04.
# Uso:    sudo bash instalador.sh
# Quita:  sudo /opt/pocsag-server/bin/uninstall.sh  (o --purge)
# ============================================================================
set -euo pipefail

APP_DIR="/opt/pocsag-server"
AST_USER="asterisk"
LOG_FILE="/var/log/pocsag-install.log"
UPDATE=0
RESET=0
VERSION="1.03"
[[ "${1:-}" == "--update" ]] && UPDATE=1
[[ "${1:-}" == "--reset" ]] && RESET=1

G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; NC="\033[0m"
log()  { echo -e "${G}[OK]${NC}   $*"; }
warn() { echo -e "${Y}[WARN]${NC} $*"; }
err()  { echo -e "${R}[ERR]${NC}  $*" >&2; }

# ============================ PRECHEQUEOS ====================================
[[ $EUID -ne 0 ]] && { err "Ejecuta como root o con sudo."; exit 1; }
grep -q 'Ubuntu 22.04' /etc/os-release 2>/dev/null || warn "No se detecto Ubuntu 22.04. Continuando bajo tu responsabilidad."

mkdir -p "${LOG_FILE%/*}"
exec > >(tee -a "${LOG_FILE}") 2>&1
export DEBIAN_FRONTEND=noninteractive

if [[ $RESET -eq 1 ]]; then
  echo "==> REINSTALACION COMPLETA (modo --reset) en ${APP_DIR}"
  echo "    Se hace backup de la base de datos y se reinstala desde cero."
  systemctl stop pocsag-api pocsag-monitor 2>/dev/null || true
  if [[ -f "${APP_DIR}/database/pocsag.db" ]]; then
    BK="/tmp/pocsag-backup-$(date +%Y%m%d%H%M%S).db"
    cp "${APP_DIR}/database/pocsag.db" "$BK"
    log "Backup de la base guardado en ${BK}"
  else
    warn "No habia base de datos previa. Se creara una nueva vacia."
  fi
  rm -rf "${APP_DIR}"
elif [[ $UPDATE -eq 1 ]]; then
  echo "==> ACTUALIZACION RAPIDA (modo --update) en ${APP_DIR}"
else
  echo "==> Instalando sistema POCSAG + Asterisk en ${APP_DIR}"
fi

# ============================ 1. DEPENDENCIAS ================================
if [[ $UPDATE -eq 0 ]]; then
  echo "==> 1/10 Dependencias base..."
  apt-get update -y
  apt-get install -y sqlite3 python3 python3-pip alsa-utils sox git \
    libgpiod2 gpiod curl ca-certificates logrotate espeak zip \
    python3-dev build-essential libffi-dev wget
  pip3 install --break-system-packages openpyxl xlrd 2>&1 || python3 -m pip install --break-system-packages openpyxl xlrd 2>&1 || warn "openpyxl/xlrd no instalados (importacion Excel solo admitira CSV)"
else
  echo "==> 1/10 Dependencias base (omitidas en --update)"
fi

# ============================ 2. ASTERISK (motor) ============================
echo "==> 2/10 Motor Asterisk..."
if [[ $UPDATE -eq 0 ]]; then
  if ! command -v asterisk >/dev/null 2>&1; then
    apt-get install -y asterisk || { err "No se pudo instalar Asterisk."; exit 1; }
  fi
fi
AST_ETC="/etc/asterisk"
mkdir -p /var/lib/asterisk/agi-bin /var/lib/asterisk/sounds
chown -R "${AST_USER}:${AST_USER}" /var/lib/asterisk/agi-bin 2>/dev/null || true

# ============================ 3. (solo Asterisk nativo) ====================
echo "==> 3/10 (omitido - solo Asterisk nativo)"

# ============================ 4. ESTRUCTURA =================================
echo "==> 4/10 Estructura..."
mkdir -p "${APP_DIR}"/{asterisk,agi,encoder,database,services,scripts,config,backend,frontend,docs,tests,audio,logs,bin}
touch "${APP_DIR}/logs/"{pocsag,cola,backup,health,scheduler,smtp}.log 2>/dev/null || true
export TZ="America/Argentina/Cordoba"; timedatectl set-timezone "America/Argentina/Cordoba" 2>/dev/null || ln -sf /usr/share/zoneinfo/America/Argentina/Cordoba /etc/localtime 2>/dev/null || true
echo "America/Argentina/Cordoba" > /etc/timezone 2>/dev/null || true
echo "==> Zona horaria: $(date '+%Z %H:%M:%S')"

# ============================ 5. ARCHIVOS ==================================
mkx() { chmod +x "$1"; }

# --- config/server.conf ---
cat > "${APP_DIR}/config/server.conf" <<'EOF'
[general]
app_dir       = /opt/pocsag-server
db_path       = /opt/pocsag-server/database/pocsag.db
log_file      = /opt/pocsag-server/logs/pocsag.log
audio_dir     = /opt/pocsag-server/audio

[asterisk]
agi_bin       = /var/lib/asterisk/agi-bin
sounds_dir    = /var/lib/asterisk/sounds
intern        = 2184
incoming_ctx  = pocsag-incoming

[radio]
ptt_mode      = gpio
gpio_chip     = gpiochip4
gpio_pin      = 17
default_baud  = 1200
deviation_khz = 4.5
audio_device  = plughw:0,0

[encoder]
backend       = python
sample_rate   = 38400

[backend_api]
host          = 0.0.0.0
port          = 8080
EOF

# --- database/schema.sql ---
cat > "${APP_DIR}/database/schema.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS pagers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo TEXT UNIQUE NOT NULL,
  cap_code TEXT NOT NULL,
  nombre TEXT,
  apellido TEXT,
  area TEXT,
  baudios INTEGER DEFAULT 1200,
  tipo TEXT DEFAULT 'individual',
  descripcion TEXT,
  activo INTEGER DEFAULT 1
);
CREATE TABLE IF NOT EXISTS grupos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo TEXT UNIQUE NOT NULL,
  nombre TEXT,
  baudios INTEGER DEFAULT 1200,
  activo INTEGER DEFAULT 1
);
CREATE TABLE IF NOT EXISTS grupo_miembros (
  grupo_id INTEGER REFERENCES grupos(id) ON DELETE CASCADE,
  cap_code TEXT NOT NULL,
  orden INTEGER DEFAULT 0,
  PRIMARY KEY (grupo_id, cap_code)
);
CREATE TABLE IF NOT EXISTS config (
  clave TEXT PRIMARY KEY,
  valor TEXT
);
CREATE TABLE IF NOT EXISTS extensiones (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  numero TEXT UNIQUE NOT NULL,
  password TEXT,
  contexto TEXT DEFAULT 'pocsag-incoming',
  descripcion TEXT,
  activo INTEGER DEFAULT 1
);
CREATE TABLE IF NOT EXISTS bitacora (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fecha_hora DATETIME DEFAULT (datetime('now','localtime')),
  interno_origen TEXT,
  codigo TEXT,
  cap_code TEXT,
  mensaje TEXT,
  baudios INTEGER,
  estado TEXT,
  observaciones TEXT
);
CREATE INDEX IF NOT EXISTS idx_bitacora_fecha ON bitacora(fecha_hora);
CREATE INDEX IF NOT EXISTS idx_bitacora_codigo ON bitacora(codigo);
CREATE INDEX IF NOT EXISTS idx_bitacora_cap ON bitacora(cap_code);
CREATE INDEX IF NOT EXISTS idx_bitacora_estado ON bitacora(estado);
CREATE INDEX IF NOT EXISTS idx_bitacora_interno ON bitacora(interno_origen);
CREATE INDEX IF NOT EXISTS idx_pagers_codigo ON pagers(codigo);
CREATE INDEX IF NOT EXISTS idx_pagers_cap ON pagers(cap_code);
CREATE INDEX IF NOT EXISTS idx_pagers_nombre ON pagers(nombre);
CREATE INDEX IF NOT EXISTS idx_pagers_apellido ON pagers(apellido);
CREATE INDEX IF NOT EXISTS idx_pagers_area ON pagers(area);
CREATE INDEX IF NOT EXISTS idx_grupos_codigo ON grupos(codigo);
CREATE INDEX IF NOT EXISTS idx_extensiones_numero ON extensiones(numero);
CREATE TABLE IF NOT EXISTS cola_envios (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fecha_encola DATETIME DEFAULT (datetime('now','localtime')),
  fecha_procesado DATETIME,
  codigo TEXT NOT NULL,
  cap_code TEXT,
  mensaje TEXT,
  baudios INTEGER,
  origen TEXT DEFAULT 'web',
  estado TEXT DEFAULT 'pendiente',
  intentos INTEGER DEFAULT 0,
  observaciones TEXT,
  proximo_intento DATETIME
);
CREATE INDEX IF NOT EXISTS idx_cola_estado ON cola_envios(estado);
CREATE INDEX IF NOT EXISTS idx_cola_fecha ON cola_envios(fecha_encola);
CREATE TABLE IF NOT EXISTS plantillas (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  nombre TEXT NOT NULL,
  mensaje TEXT NOT NULL,
  categoria TEXT DEFAULT 'general',
  activo INTEGER DEFAULT 1,
  orden INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS envios_programados (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo TEXT NOT NULL,
  mensaje TEXT NOT NULL,
  origen TEXT DEFAULT 'web',
  tipo TEXT DEFAULT 'unico',
  fecha_programada DATETIME,
  recurrencia_dia INTEGER DEFAULT 0,
  recurrencia_hora TEXT DEFAULT '08:00',
  proxima_ejecucion DATETIME,
  activo INTEGER DEFAULT 1,
  ultima_ejecucion DATETIME
);
CREATE INDEX IF NOT EXISTS idx_prog_prox ON envios_programados(proxima_ejecucion);
CREATE INDEX IF NOT EXISTS idx_prog_act ON envios_programados(activo);
CREATE TABLE IF NOT EXISTS auditoria (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fecha_hora DATETIME DEFAULT (datetime('now','localtime')),
  usuario TEXT,
  accion TEXT,
  entidad TEXT,
  entidad_id TEXT,
  detalle TEXT,
  ip TEXT
);
CREATE INDEX IF NOT EXISTS idx_aud_fecha ON auditoria(fecha_hora);
CREATE INDEX IF NOT EXISTS idx_aud_entidad ON auditoria(entidad);
EOF

# --- database/seed.sql ---
cat > "${APP_DIR}/database/seed.sql" <<'EOF'
INSERT OR IGNORE INTO config (clave, valor) VALUES
 ('mensaje_timeout','5'),
 ('ptt_preactivo','0.5'),
 ('digit_timeout','5'),
 ('response_timeout','20'),
 ('max_grupo_capcodes','20'),
 ('test_mode','1'),
 ('admin_user','admin'),
 ('admin_pass','admin123'),
 ('smtp_host',''),
 ('smtp_port','587'),
 ('smtp_user',''),
 ('smtp_pass',''),
 ('smtp_from',''),
 ('smtp_secure','tls'),
 ('backup_email',''), ('backup_schedules','[]');

INSERT OR IGNORE INTO pagers (codigo,cap_code,nombre,apellido,area,baudios,descripcion) VALUES
 ('10','00002020','Juan','Perez','Guardia Medica',1200,'Medico de guardia'),
 ('11','00002021','Maria','Gomez','Enfermeria',1200,'Enfermera de guardia'),
 ('12','00002022','Carlos','Ruiz','Trauma',1200,'Traumatologo'),
 ('99','00000099','Sistema','Test','Sistemas',512,'Prueba de sistema');

INSERT OR IGNORE INTO grupos (codigo,nombre,baudios) VALUES
 ('20','Codigo Azul - Guardia Medica',1200),
 ('21','Emergencias Generales',1200);

INSERT OR IGNORE INTO grupo_miembros (grupo_id,cap_code,orden) VALUES
 (1,'00002020',1), (1,'00002021',2),
 (2,'00002020',1), (2,'00002021',2), (2,'00002022',3);

INSERT OR IGNORE INTO extensiones (numero,password,contexto,descripcion) VALUES
 ('101','CAMBIAR_PASSWORD_101','pocsag-incoming','Prueba Zoiper'),
 ('2184','CAMBIAR_PASSWORD_2184','pocsag-incoming','Linea entrante POCSAG 1'),
 ('2185','CAMBIAR_PASSWORD_2185','pocsag-incoming','Linea entrante POCSAG 2'),
 ('2186','CAMBIAR_PASSWORD_2186','pocsag-incoming','Linea entrante POCSAG 3'),
 ('2187','CAMBIAR_PASSWORD_2187','pocsag-incoming','Linea entrante POCSAG 4');

INSERT OR IGNORE INTO plantillas (nombre,mensaje,categoria,orden) VALUES
 ('Codigo Azul','CODIGO AZUL - Emergencia medica - Concurrir de inmediato','emergencia',1),
 ('Codigo Rojo','CODIGO ROJO - Emergencia - Concurrir de inmediato','emergencia',2),
 ('Guardia Medica','Llamado a Guardia Medica - Concurrir','general',3),
 ('Reunion','Convocatoria a reunion - Sala de reuniones','general',4);
EOF

# --- database/db_manager.py ---
cat > "${APP_DIR}/database/db_manager.py" <<'EOF'
#!/usr/bin/env python3
import sqlite3, os, secrets, time, datetime
from contextlib import contextmanager
DEFAULT_DB = "/opt/pocsag-server/database/pocsag.db"
_TOKENS = {}  # token -> epoch de expiracion

@contextmanager
def get_conn(db_path=DEFAULT_DB):
    conn = sqlite3.connect(db_path); conn.row_factory = sqlite3.Row
    try: yield conn; conn.commit()
    finally: conn.close()

def init_db(db_path=DEFAULT_DB):
    base = os.path.dirname(__file__)
    with get_conn(db_path) as conn:
        with open(os.path.join(base,"schema.sql"),encoding="utf-8") as f: conn.executescript(f.read())
        with open(os.path.join(base,"seed.sql"),encoding="utf-8") as f: conn.executescript(f.read())
        try: conn.execute("ALTER TABLE cola_envios ADD COLUMN proximo_intento DATETIME")
        except Exception: pass

def get_config(clave, default="", db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        row = conn.execute("SELECT valor FROM config WHERE clave=?",(clave,)).fetchone()
        return row["valor"] if row else default

def set_config(clave, valor, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("INSERT INTO config(clave,valor) VALUES(?,?) "
                     "ON CONFLICT(clave) DO UPDATE SET valor=excluded.valor",(clave,valor))

def all_config(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return {r["clave"]:r["valor"] for r in conn.execute("SELECT * FROM config")}

def resolver_destino(codigo, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        row = conn.execute("SELECT cap_code,baudios,tipo FROM pagers WHERE codigo=? AND activo=1",(codigo,)).fetchone()
        if row:
            return (row["cap_code"], row["baudios"], row["tipo"] or "individual")
        grow = conn.execute("SELECT id,baudios FROM grupos WHERE codigo=? AND activo=1",(codigo,)).fetchone()
        if grow:
            members = conn.execute("SELECT cap_code FROM grupo_miembros WHERE grupo_id=? ORDER BY orden",(grow["id"],)).fetchall()
            caps = ",".join(m["cap_code"] for m in members)
            return (caps, grow["baudios"], "grupo")
        return None

def registrar_bitacora(interno, codigo, cap_code, mensaje, baudios, estado, obs="", db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("INSERT INTO bitacora (fecha_hora,interno_origen,codigo,cap_code,mensaje,baudios,estado,observaciones) VALUES (?,?,?,?,?,?,?,?)",
                     (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),interno,codigo,cap_code,mensaje,baudios,estado,obs))

def listar_pagers(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM pagers ORDER BY codigo")]

def crear_pager(data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("INSERT INTO pagers (codigo,cap_code,nombre,apellido,area,baudios,descripcion,activo) VALUES (?,?,?,?,?,?,?,1)",
                     (data["codigo"],data["cap_code"],data.get("nombre"),data.get("apellido"),
                      data.get("area"),data.get("baudios",1200),data.get("descripcion")))
        return conn.execute("SELECT * FROM pagers WHERE codigo=?",(data["codigo"],)).fetchone()["id"]

def actualizar_pager(pid, data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE pagers SET codigo=?,cap_code=?,nombre=?,apellido=?,area=?,baudios=?,descripcion=?,activo=? WHERE id=?",
                     (data["codigo"],data["cap_code"],data.get("nombre"),data.get("apellido"),
                      data.get("area"),data.get("baudios",1200),data.get("descripcion"),
                      int(data.get("activo",1)),pid))

def toggle_pager(pid, activo, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE pagers SET activo=? WHERE id=?",(int(activo),pid))

def buscar_pagers(q, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        if not q:
            return [dict(r) for r in conn.execute("SELECT * FROM pagers ORDER BY codigo")]
        like=f"%{q}%"
        return [dict(r) for r in conn.execute(
            "SELECT * FROM pagers WHERE codigo LIKE ? OR cap_code LIKE ? OR nombre LIKE ? OR apellido LIKE ? OR area LIKE ? ORDER BY codigo",
            (like,like,like,like,like))]

def buscar_grupos(q, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        rows = conn.execute("SELECT * FROM grupos ORDER BY codigo").fetchall() if not q else \
               conn.execute("SELECT * FROM grupos WHERE codigo LIKE ? OR nombre LIKE ? ORDER BY codigo",
                            (f"%{q}%",f"%{q}%")).fetchall()
        out=[]
        for g in rows:
            miembros=[m["cap_code"] for m in conn.execute("SELECT cap_code FROM grupo_miembros WHERE grupo_id=? ORDER BY orden",(g["id"],)).fetchall()]
            out.append({**dict(g),"miembros":miembros})
        return out

def importar_pagers(rows, db_path=DEFAULT_DB):
    n=0; errores=0
    with get_conn(db_path) as conn:
        for r in rows:
            try: baud=int(r.get("baudios") or 1200)
            except (ValueError,TypeError): baud=1200
            try:
                conn.execute("INSERT INTO pagers (codigo,cap_code,nombre,apellido,area,baudios,descripcion,activo) VALUES (?,?,?,?,?,?,?,1) "
                    "ON CONFLICT(codigo) DO UPDATE SET cap_code=excluded.cap_code,nombre=excluded.nombre,"
                    "apellido=excluded.apellido,area=excluded.area,baudios=excluded.baudios,descripcion=excluded.descripcion",
                    (r["codigo"],r["cap_code"],r.get("nombre",""),r.get("apellido",""),r.get("area",""),baud,r.get("descripcion","")))
                n+=1
            except Exception: errores+=1
    return {"importados":n,"errores":errores}

def importar_grupos(rows, db_path=DEFAULT_DB):
    n=0; errores=0
    with get_conn(db_path) as conn:
        for r in rows:
            try: baud=int(r.get("baudios") or 1200)
            except (ValueError,TypeError): baud=1200
            caps=[c.strip() for c in str(r.get("cap_codes","")).split(",") if c.strip()][:20]
            codigo=r.get("codigo","")
            if not codigo or not caps: continue
            try:
                conn.execute("INSERT INTO grupos (codigo,nombre,baudios,activo) VALUES (?,?,?,1) "
                    "ON CONFLICT(codigo) DO UPDATE SET nombre=excluded.nombre,baudios=excluded.baudios",
                    (codigo,r.get("nombre",""),baud))
                gid=conn.execute("SELECT id FROM grupos WHERE codigo=?",(codigo,)).fetchone()["id"]
                conn.execute("DELETE FROM grupo_miembros WHERE grupo_id=?",(gid,))
                for i,c in enumerate(caps):
                    conn.execute("INSERT OR IGNORE INTO grupo_miembros (grupo_id,cap_code,orden) VALUES (?,?,?)",(gid,c,i))
                n+=1
            except Exception: errores+=1
    return {"importados":n,"errores":errores}

def listar_extensiones(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM extensiones ORDER BY numero")]

def crear_extension(data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        cur=conn.execute("INSERT INTO extensiones (numero,password,contexto,descripcion,activo) VALUES (?,?,?,?,1)",
            (data["numero"],data.get("password",""),data.get("contexto","pocsag-incoming") or "pocsag-incoming",data.get("descripcion","")))
        return cur.lastrowid

def actualizar_extension(eid, data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE extensiones SET numero=?,password=?,contexto=?,descripcion=?,activo=? WHERE id=?",
            (data["numero"],data.get("password",""),data.get("contexto","pocsag-incoming") or "pocsag-incoming",
             data.get("descripcion",""),int(data.get("activo",1)),eid))

def borrar_extension(eid, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM extensiones WHERE id=?",(eid,))

def generar_pjsip_conf(db_path=DEFAULT_DB):
    exts=listar_extensiones(db_path)
    lines=["[transport-udp]","type=transport","protocol=udp","bind=0.0.0.0:5060",""]
    for e in exts:
        if not e["activo"]: continue
        num=e["numero"]; ctx=e["contexto"] or "pocsag-incoming"
        lines+=[f"[{num}]","type=endpoint",f"context={ctx}","disallow=all","allow=ulaw,alaw",
                "transport=transport-udp",f"auth={num}-auth",f"aors={num}-aor","",
                f"[{num}-auth]","type=auth","auth_type=userpass",f"username={num}",f"password={e['password'] or ''}","",
                f"[{num}-aor]","type=aor","max_contacts=1",""]
    conf="/etc/asterisk/pocsag.conf"
    try:
        with open(conf,"w") as f: f.write("\n".join(lines)+"\n")
        return True
    except PermissionError:
        return False

def generar_dialplan_conf(db_path=DEFAULT_DB):
    exts=listar_extensiones(db_path)
    activos=[e["numero"] for e in exts if e["activo"]]
    nums=activos if activos else ["2184"]
    header="[pocsag-incoming]\n"
    body=""
    for num in nums:
        body+=(
f"""exten => {num},1,NoOp(=== Paginacion hospitalaria POCSAG ===)
 same => n,Answer()
 same => n,Set(TIMEOUT(digit)=5)
 same => n,Set(TIMEOUT(response)=30)
 same => n(loop),Playback(despues-del-tono-marque-codigo)
 same => n,Playback(beep)
 same => n,Read(CODE,,8,,3,5)
 same => n,GotoIf($["${{CODE}}" = ""]?fin)
 same => n,AGI(/var/lib/asterisk/agi-bin/pocsag_check.py,${{CODE}})
 same => n,GotoIf($["${{POCSAG_VALID}}" = "1"]?pedir_mensaje:codigo_invalido)
 same => n(codigo_invalido),Playback(codigo-inexistente)
 same => n,Playback(marque-otro-codigo)
 same => n,Wait(0.5)
 same => n,Goto(loop)
 same => n(pedir_mensaje),Playback(despues-de-la-senal-su-mensaje)
 same => n,Playback(beep)
 same => n,Read(MESSAGE,,16,,3,${{POCSAG_MSJ_TIMEOUT}})
 same => n,GotoIf($["${{MESSAGE}}" = ""]?mensaje_vacio:enviar)
 same => n(enviar),AGI(/var/lib/asterisk/agi-bin/pocsag_handler.py,${{CALLERID(num)}},${{CODE}},${{MESSAGE}})
 same => n,GotoIf($["${{AGISTATUS}}" = "SUCCESS"]?ok:fail)
 same => n(ok),Playback(confirmado)
 same => n,Hangup()
 same => n(fail),Playback(error-envio)
 same => n,Hangup()
 same => n(mensaje_vacio),Playback(mensaje-vacio)
 same => n,Goto(pedir_mensaje)
 same => n(fin),Playback(mensaje-vacio)
 same => n,Hangup()
""")
    conf="/etc/asterisk/extensions_pocsag.conf"
    try:
        with open(conf,"w") as f: f.write(header+body+"\n")
        return True
    except PermissionError:
        return False

def login_validar(user, passw, db_path=DEFAULT_DB):
    au=get_config("admin_user","admin"); ap=get_config("admin_pass","admin123")
    if user==au and passw==ap:
        tok=secrets.token_hex(16); _TOKENS[tok]=time.time()+86400; return tok
    return None

def verificar_token(tok):
    exp=_TOKENS.get(tok)
    if not exp: return False
    if time.time()>exp: _TOKENS.pop(tok,None); return False
    return True

def cerrar_sesion(tok):
    _TOKENS.pop(tok,None)

def historial(filtros, limit=50, offset=0, db_path=DEFAULT_DB):
    def val(v): return v[0] if isinstance(v,list) else v
    where=[]; args=[]
    if filtros.get("fecha_desde"):
        where.append("fecha_hora >= ?"); args.append(val(filtros["fecha_desde"]))
    if filtros.get("fecha_hasta"):
        where.append("fecha_hora <= ?"); args.append(val(filtros["fecha_hasta"]))
    for k,col in (("codigo","codigo"),("cap_code","cap_code"),("estado","estado"),("interno","interno_origen")):
        v=filtros.get(k); v=val(v) if v else ""
        if v: where.append(f"{col} LIKE ?"); args.append(f"%{v}%")
    wsql=(" WHERE "+" AND ".join(where)) if where else ""
    with get_conn(db_path) as conn:
        total=conn.execute("SELECT COUNT(*) AS c FROM bitacora"+wsql,args).fetchone()["c"]
        rows=[dict(r) for r in conn.execute("SELECT * FROM bitacora"+wsql+" ORDER BY id DESC LIMIT ? OFFSET ?",args+[limit,offset])]
    return {"rows":rows,"total":total,"limit":limit,"offset":offset}

def borrar_pager(pid, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM pagers WHERE id=?",(pid,))

def listar_grupos(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        rows = conn.execute("SELECT * FROM grupos ORDER BY codigo").fetchall()
        out=[]
        for g in rows:
            miembros=[m["cap_code"] for m in conn.execute("SELECT cap_code FROM grupo_miembros WHERE grupo_id=? ORDER BY orden",(g["id"],)).fetchall()]
            out.append({**dict(g),"miembros":miembros})
        return out

def crear_grupo(data, db_path=DEFAULT_DB):
    caps = data.get("miembros",[])[:20]
    with get_conn(db_path) as conn:
        cur=conn.execute("INSERT INTO grupos (codigo,nombre,baudios,activo) VALUES (?,?,?,1)",
                     (data["codigo"],data.get("nombre"),data.get("baudios",1200)))
        gid=cur.lastrowid
        for i,c in enumerate(caps):
            conn.execute("INSERT OR IGNORE INTO grupo_miembros (grupo_id,cap_code,orden) VALUES (?,?,?)",(gid,c,i))
        return gid

def actualizar_grupo(gid, data, db_path=DEFAULT_DB):
    caps = data.get("miembros",[])[:20]
    with get_conn(db_path) as conn:
        conn.execute("UPDATE grupos SET codigo=?,nombre=?,baudios=? WHERE id=?",
                     (data["codigo"],data.get("nombre"),data.get("baudios",1200),gid))
        conn.execute("DELETE FROM grupo_miembros WHERE grupo_id=?",(gid,))
        for i,c in enumerate(caps):
            conn.execute("INSERT OR IGNORE INTO grupo_miembros (grupo_id,cap_code,orden) VALUES (?,?,?)",(gid,c,i))

def borrar_grupo(gid, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM grupos WHERE id=?",(gid,))

def bitacora_reciente(limit=50, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM bitacora ORDER BY id DESC LIMIT ?",(limit,))]

def bitacora_filtrada(filtros, db_path=DEFAULT_DB):
    def val(v): return v[0] if isinstance(v,list) else v
    where=[]; args=[]
    if filtros.get("fecha_desde"):
        where.append("fecha_hora >= ?"); args.append(val(filtros["fecha_desde"]))
    if filtros.get("fecha_hasta"):
        where.append("fecha_hora <= ?"); args.append(val(filtros["fecha_hasta"]))
    for k,col in (("codigo","codigo"),("cap_code","cap_code"),("estado","estado"),("interno","interno_origen")):
        v=filtros.get(k)
        v=val(v) if v else ""
        if v: where.append(f"{col} LIKE ?"); args.append(f"%{v}%")
    sql="SELECT * FROM bitacora"
    if where: sql+=" WHERE "+" AND ".join(where)
    sql+=" ORDER BY id DESC LIMIT 5000"
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute(sql,args)]

def encolar_mensaje(codigo, caps, mensaje, baudios, origen, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        cur=conn.execute("INSERT INTO cola_envios (codigo,cap_code,mensaje,baudios,origen,estado) VALUES (?,?,?,?,?,?)",
                         (codigo,caps,mensaje,baudios,origen,"pendiente"))
        return cur.lastrowid

def enviar_mensaje(codigo, mensaje, origen="web", db_path=DEFAULT_DB):
    if not codigo or not mensaje: return {"status":"error","detalle":"falta codigo o mensaje"}
    dest = resolver_destino(codigo, db_path)
    if not dest: return {"status":"error","detalle":"codigo inactivo o inexistente"}
    caps, baudios, tipo = dest
    qid = encolar_mensaje(codigo, caps, mensaje, baudios, origen, db_path)
    return {"status":"encolado","detalle":f"mensaje encolado (id={qid})","id":qid}

def listar_cola(estado=None, limit=200, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        if estado:
            rows=conn.execute("SELECT * FROM cola_envios WHERE estado=? ORDER BY id DESC LIMIT ?",(estado,limit))
        else:
            rows=conn.execute("SELECT * FROM cola_envios ORDER BY id DESC LIMIT ?",(limit,))
        return [dict(r) for r in rows]

def estado_cola(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        counts={}
        for r in conn.execute("SELECT estado, COUNT(*) as c FROM cola_envios GROUP BY estado"):
            counts[r["estado"]]=r["c"]
        return counts

def reintentar_cola(cid, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE cola_envios SET estado='pendiente', intentos=0, observaciones='', proximo_intento=NULL WHERE id=? AND estado IN ('error','fallido')",(cid,))

def limpiar_cola(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM cola_envios WHERE estado='enviado'")

def procesar_siguiente_cola(db_path=DEFAULT_DB):
    import subprocess, sys
    handler="/var/lib/asterisk/agi-bin/pocsag_handler.py"
    if not os.path.exists(handler): handler="/opt/pocsag-server/agi/pocsag_handler.py"
    with get_conn(db_path) as conn:
        row=conn.execute("SELECT * FROM cola_envios WHERE estado='pendiente' AND (proximo_intento IS NULL OR proximo_intento <= datetime('now','localtime')) ORDER BY id ASC LIMIT 1").fetchone()
        if not row: return None
        conn.execute("UPDATE cola_envios SET estado='enviando', intentos=intentos+1 WHERE id=?",(row["id"],))
        conn.commit()
    item=dict(row)
    try:
        env={**os.environ,"POCSAG_WORKER":"1"}
        rc=subprocess.run([sys.executable,handler,item["origen"] or "cola",item["codigo"],item["mensaje"]],
                          capture_output=True,text=True,timeout=120,env=env)
        ok = rc.returncode==0
        obs = "" if ok else (rc.stderr or rc.stdout or "fallo").strip()[:200]
    except Exception as e:
        ok=False; obs=str(e)[:200]
    with get_conn(db_path) as conn:
        if ok:
            conn.execute("UPDATE cola_envios SET estado='enviado', fecha_procesado=datetime('now','localtime'), observaciones='', proximo_intento=NULL WHERE id=?",(item["id"],))
        else:
            intentos=item["intentos"]+1
            if intentos < 3:
                conn.execute("UPDATE cola_envios SET estado='pendiente', fecha_procesado=datetime('now','localtime'), observaciones=?, proximo_intento=datetime('now','localtime','+10 seconds') WHERE id=?",(obs,item["id"]))
            else:
                conn.execute("UPDATE cola_envios SET estado='fallido', fecha_procesado=datetime('now','localtime'), observaciones=?, proximo_intento=NULL WHERE id=?",(obs,item["id"]))
    if not ok:
        intentos=item["intentos"]+1
        if intentos >= 3:
            try: notificar_error("Envio fallido POCSAG", f"Cola id={item['id']} codigo={item['codigo']} fallo tras 3 intentos: {obs}")
            except Exception: pass
    return item["id"]

def backup_db(db_path=DEFAULT_DB):
    import shutil, time
    backup_dir=os.path.join(os.path.dirname(db_path),"backups")
    os.makedirs(backup_dir, exist_ok=True)
    ts=time.strftime("%Y%m%d_%H%M%S")
    bf=os.path.join(backup_dir, f"pocsag_backup_{ts}.db")
    shutil.copy2(db_path, bf)
    return bf

def restore_db(file_data, db_path=DEFAULT_DB):
    import shutil
    bk=db_path+".pre_restore"
    if os.path.exists(db_path): shutil.copy2(db_path, bk)
    with open(db_path,"wb") as f: f.write(file_data)
    return bk

def enviar_email(to, subject, body, attachment_path=None, db_path=DEFAULT_DB):
    import smtplib, traceback, time
    from email.mime.multipart import MIMEMultipart
    from email.mime.text import MIMEText
    from email.mime.base import MIMEBase
    from email import encoders
    SMTP_LOG="/opt/pocsag-server/logs/smtp.log"
    try: os.makedirs(os.path.dirname(SMTP_LOG),exist_ok=True)
    except: pass
    def lg(m):
        try:
            with open(SMTP_LOG,"a") as f: f.write(time.strftime("%Y-%m-%d %H:%M:%S")+" | "+m+"\n")
        except: pass
    host=get_config("smtp_host","",db_path)
    if not host: lg("ERROR no hay smtp_host configurado -> "+str(to)); return {"error":"SMTP no configurado"}
    port=int(get_config("smtp_port","587",db_path))
    user=get_config("smtp_user","",db_path)
    pwd=get_config("smtp_pass","",db_path)
    frm=get_config("smtp_from",user,db_path) or user
    secure=get_config("smtp_secure","tls",db_path)
    lg("INICIO to="+str(to)+" subject="+str(subject)[:50]+" host="+str(host)+":"+str(port)+" secure="+str(secure)+" user="+str(user))
    msg=MIMEMultipart(); msg["From"]=frm; msg["To"]=to; msg["Subject"]=subject
    msg.attach(MIMEText(body,"plain","utf-8"))
    if attachment_path and os.path.exists(attachment_path):
        with open(attachment_path,"rb") as f:
            part=MIMEBase("application","octet-stream"); part.set_payload(f.read()); encoders.encode_base64(part)
            part.add_header("Content-Disposition",f'attachment; filename="{os.path.basename(attachment_path)}"')
            msg.attach(part)
    try:
        if secure=="ssl" or port==465: server=smtplib.SMTP_SSL(host,port,timeout=30); lg("conectado SMTP_SSL OK (port=%s)"%port)
        else:
            server=smtplib.SMTP(host,port,timeout=30); lg("conectado SMTP OK")
            server.ehlo(); lg("ehlo OK")
            if secure=="tls":
                server.starttls(); lg("starttls OK"); server.ehlo()
        if user:
            server.login(user,pwd); lg("login OK")
        else:
            lg("login omitido (sin usuario)")
        server.sendmail(frm,[to],msg.as_string()); lg("sendmail OK")
        server.quit()
        lg("OK enviado a "+str(to))
        return {"ok":True}
    except smtplib.SMTPAuthenticationError as e:
        lg("ERROR auth: "+str(e))
        return {"error":f"Auth fallida - si usas Gmail crea una App Password: {e}"}
    except Exception as e:
        lg("ERROR: "+str(e)+" | "+traceback.format_exc().replace(chr(10)," / "))
        return {"error":str(e)}

def listar_plantillas(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM plantillas ORDER BY orden,categoria,nombre")]

def crear_plantilla(data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        cur=conn.execute("INSERT INTO plantillas (nombre,mensaje,categoria,orden,activo) VALUES (?,?,?,?,1)",
            (data["nombre"],data["mensaje"],data.get("categoria","general"),data.get("orden",0)))
        return cur.lastrowid

def actualizar_plantilla(pid, data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE plantillas SET nombre=?,mensaje=?,categoria=?,orden=?,activo=? WHERE id=?",
            (data["nombre"],data["mensaje"],data.get("categoria","general"),data.get("orden",0),int(data.get("activo",1)),pid))

def borrar_plantilla(pid, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM plantillas WHERE id=?",(pid,))

def listar_programados(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM envios_programados ORDER BY proxima_ejecucion")]

def crear_programado(data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        cur=conn.execute("INSERT INTO envios_programados (codigo,mensaje,origen,tipo,fecha_programada,recurrencia_dia,recurrencia_hora,proxima_ejecucion,activo) VALUES (?,?,?,?,?,?,?,?,1)",
            (data["codigo"],data["mensaje"],data.get("origen","web"),data.get("tipo","unico"),
             data.get("fecha_programada"),int(data.get("recurrencia_dia",0)),data.get("recurrencia_hora","08:00"),
             data.get("fecha_programada") or data.get("proxima_ejecucion")))
        return cur.lastrowid

def actualizar_programado(pid, data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE envios_programados SET codigo=?,mensaje=?,tipo=?,fecha_programada=?,recurrencia_dia=?,recurrencia_hora=?,proxima_ejecucion=?,activo=? WHERE id=?",
            (data["codigo"],data["mensaje"],data.get("tipo","unico"),data.get("fecha_programada"),
             int(data.get("recurrencia_dia",0)),data.get("recurrencia_hora","08:00"),
             data.get("fecha_programada") or data.get("proxima_ejecucion"),int(data.get("activo",1)),pid))

def borrar_programado(pid, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM envios_programados WHERE id=?",(pid,))

def procesar_programados(db_path=DEFAULT_DB):
    import datetime
    now=datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with get_conn(db_path) as conn:
        rows=conn.execute("SELECT * FROM envios_programados WHERE activo=1 AND proxima_ejecucion<=? ORDER BY proxima_ejecucion",(now,)).fetchall()
    procesados=[]
    for r in rows:
        r=dict(r)
        qid=encolar_mensaje(r["codigo"],None,r["mensaje"],1200,r["origen"] or "programado",db_path)
        # resolver caps reales
        dest=resolver_destino(r["codigo"],db_path)
        if dest:
            with get_conn(db_path) as conn:
                conn.execute("UPDATE cola_envios SET cap_code=? WHERE id=?",(dest[0],qid))
        proxima=None
        if r["tipo"]=="diario":
            proxima=(datetime.datetime.now()+datetime.timedelta(days=1)).strftime(f"%Y-%m-%d {r['recurrencia_hora'] or '08:00'}:00")
        elif r["tipo"]=="semanal":
            proxima=(datetime.datetime.now()+datetime.timedelta(weeks=1)).strftime(f"%Y-%m-%d {r['recurrencia_hora'] or '08:00'}:00")
        elif r["tipo"]=="mensual":
            import calendar
            d=datetime.datetime.now()
            nm=d.month+1 if d.month<12 else 1
            ny=d.year if d.month<12 else d.year+1
            _,last=calendar.monthrange(ny,nm)
            dia=min(r["recurrencia_dia"] or 1,last)
            proxima=f"{ny}-{nm:02d}-{dia:02d} {r['recurrencia_hora'] or '08:00'}:00"
        else:
            proxima=None
        with get_conn(db_path) as conn:
            if proxima:
                conn.execute("UPDATE envios_programados SET ultima_ejecucion=?,proxima_ejecucion=? WHERE id=?",(now,proxima,r["id"]))
            else:
                conn.execute("UPDATE envios_programados SET ultima_ejecucion=?,activo=0 WHERE id=?",(now,r["id"]))
        procesados.append(r["id"])
    return procesados

def registrar_auditoria(usuario, accion, entidad, entidad_id, detalle, ip="", db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("INSERT INTO auditoria (usuario,accion,entidad,entidad_id,detalle,ip) VALUES (?,?,?,?,?,?)",
            (usuario or "sistema",accion,entidad,str(entidad_id or ""),detalle or "",ip or ""))

def listar_auditoria(limit=200, offset=0, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        rows=[dict(r) for r in conn.execute("SELECT * FROM auditoria ORDER BY id DESC LIMIT ? OFFSET ?",(limit,offset))]
        total=conn.execute("SELECT COUNT(*) AS c FROM auditoria").fetchone()["c"]
    return {"rows":rows,"total":total}

def estadisticas(db_path=DEFAULT_DB):
    import datetime
    with get_conn(db_path) as conn:
        hoy=datetime.date.today().isoformat()
        hace30=(datetime.date.today()-datetime.timedelta(days=30)).isoformat()
        por_dia=[dict(r) for r in conn.execute(
            "SELECT date(fecha_hora) AS dia, COUNT(*) AS total, SUM(CASE WHEN estado='enviado' THEN 1 ELSE 0 END) AS ok, SUM(CASE WHEN estado='error' THEN 1 ELSE 0 END) AS err FROM bitacora WHERE fecha_hora>=? GROUP BY date(fecha_hora) ORDER BY dia",(hace30,))]
        por_hora=[dict(r) for r in conn.execute(
            "SELECT strftime('%H',fecha_hora) AS hora, COUNT(*) AS total FROM bitacora WHERE date(fecha_hora)=? GROUP BY strftime('%H',fecha_hora) ORDER BY hora",(hoy,))]
        top_pagers=[dict(r) for r in conn.execute(
            "SELECT codigo, COUNT(*) AS total FROM bitacora WHERE fecha_hora>=? GROUP BY codigo ORDER BY total DESC LIMIT 10",(hace30,))]
        total_env=conn.execute("SELECT COUNT(*) AS c FROM bitacora").fetchone()["c"]
        total_ok=conn.execute("SELECT COUNT(*) AS c FROM bitacora WHERE estado='enviado'").fetchone()["c"]
        total_err=conn.execute("SELECT COUNT(*) AS c FROM bitacora WHERE estado='error'").fetchone()["c"]
        cola=estado_cola(db_path)
    return {"por_dia":por_dia,"por_hora":por_hora,"top_pagers":top_pagers,
            "total_enviados":total_env,"total_ok":total_ok,"total_err":total_err,"cola":cola}

def leer_logs(tipo, limit=200, db_path=DEFAULT_DB):
    paths={"asterisk":"/var/log/asterisk/messages","api":"/opt/pocsag-server/logs/pocsag.log",
           "cola":"/opt/pocsag-server/logs/cola.log","backup":"/opt/pocsag-server/logs/backup.log",
           "health":"/opt/pocsag-server/logs/health.log","install":"/var/log/pocsag-install.log","scheduler":"/opt/pocsag-server/logs/scheduler.log"}
    path=paths.get(tipo)
    if not path or not os.path.exists(path): return {"lineas":[],"path":path or "desconocido"}
    try:
        with open(path,"r",errors="replace") as f:
            lineas=f.readlines()[-limit:]
        return {"lineas":[l.rstrip() for l in lineas],"path":path}
    except Exception as e:
        return {"lineas":[],"path":path,"error":str(e)}

def notificar_error(asunto, cuerpo, db_path=DEFAULT_DB):
    email=get_config("backup_email","",db_path)
    if not email: return {"error":"no hay email configurado"}
    return enviar_email(email,asunto,cuerpo,db_path=db_path)

if __name__ == "__main__":
    import sys
    if len(sys.argv)>1 and sys.argv[1]=="init": init_db(); print("Base de datos inicializada.")
    if len(sys.argv)>2 and sys.argv[2]=="seed": print("seed ok")
EOF
mkx "${APP_DIR}/database/db_manager.py"

# --- asterisk dialplan (comun) ---
cat > "${APP_DIR}/asterisk/pocsag_ivr.conf" <<'EOF'
[pocsag-incoming]
exten => 2184,1,NoOp(=== Paginacion hospitalaria POCSAG ===)
 same => n,Answer()
 same => n,Set(TIMEOUT(digit)=5)
 same => n,Set(TIMEOUT(response)=30)
 same => n(loop),Playback(despues-del-tono-marque-codigo)
 same => n,Playback(beep)
 same => n,Read(CODE,,8,,3,5)
 same => n,GotoIf($["${CODE}" = ""]?fin)
 same => n,AGI(/var/lib/asterisk/agi-bin/pocsag_check.py,${CODE})
 same => n,GotoIf($["${POCSAG_VALID}" = "1"]?pedir_mensaje:codigo_invalido)
 same => n(codigo_invalido),Playback(codigo-inexistente)
 same => n,Playback(marque-otro-codigo)
 same => n,Wait(0.5)
 same => n,Goto(loop)
 same => n(pedir_mensaje),Playback(despues-de-la-senal-su-mensaje)
 same => n,Playback(beep)
 same => n,Read(MESSAGE,,16,,3,${POCSAG_MSJ_TIMEOUT})
 same => n,GotoIf($["${MESSAGE}" = ""]?mensaje_vacio:enviar)
 same => n(enviar),AGI(/var/lib/asterisk/agi-bin/pocsag_handler.py,${CALLERID(num)},${CODE},${MESSAGE})
 same => n,GotoIf($["${AGISTATUS}" = "SUCCESS"]?ok:fail)
 same => n(ok),Playback(confirmado)
 same => n,Hangup()
 same => n(fail),Playback(error-envio)
 same => n,Hangup()
 same => n(mensaje_vacio),Playback(mensaje-vacio)
 same => n,Goto(pedir_mensaje)
 same => n(fin),Playback(mensaje-vacio)
 same => n,Hangup()
EOF

# --- pjsip endpoint 101 (solo modo nativo, para Zoiper) ---
cat > "${APP_DIR}/asterisk/pjsip_pocsag.conf" <<'EOF'
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060

[101]
type=endpoint
context=pocsag-incoming
disallow=all
allow=ulaw,alaw
transport=transport-udp
auth=101-auth
aors=101-aor

[101-auth]
type=auth
auth_type=userpass
username=101
password=CAMBIAR_PASSWORD_101

[101-aor]
type=aor
max_contacts=1

[pocsag-endpoint]
type=endpoint
context=pocsag-incoming
disallow=all
allow=ulaw,alaw
transport=transport-udp
auth=pocsag-auth
aors=pocsag-aor

[pocsag-auth]
type=auth
auth_type=userpass
username=2184
password=CAMBIAR_PASSWORD_2184

[pocsag-aor]
type=aor
max_contacts=1
EOF

# --- agi/pocsag_check.py ---
cat > "${APP_DIR}/agi/pocsag_check.py" <<'EOF'
#!/usr/bin/env python3
import sys
sys.path.insert(0, "/opt/pocsag-server")
from database.db_manager import resolver_destino, get_config

def main():
    codigo = sys.argv[1] if len(sys.argv)>1 else ""
    dest = resolver_destino(codigo)
    if not dest:
        sys.stdout.write("SET VARIABLE POCSAG_VALID 0\n"); sys.stdout.flush(); return
    caps, baud, tipo = dest
    timeout = get_config("mensaje_timeout", "5")
    sys.stdout.write("SET VARIABLE POCSAG_VALID 1\n")
    sys.stdout.write(f"SET VARIABLE POCSAG_CAPS {caps}\n")
    sys.stdout.write(f"SET VARIABLE POCSAG_BAUD {baud}\n")
    sys.stdout.write(f"SET VARIABLE POCSAG_TIPO {tipo}\n")
    sys.stdout.write(f"SET VARIABLE POCSAG_MSJ_TIMEOUT {timeout}\n")
    sys.stdout.flush()

if __name__ == "__main__": main()
EOF
mkx "${APP_DIR}/agi/pocsag_check.py"

# --- agi/pocsag_handler.py ---
cat > "${APP_DIR}/agi/pocsag_handler.py" <<'EOF'
#!/usr/bin/env python3
import sys, os, subprocess, traceback, time
sys.path.insert(0, "/opt/pocsag-server")
from database.db_manager import resolver_destino, registrar_bitacora, encolar_mensaje, get_config

AUDIO_DIR = "/opt/pocsag-server/audio"
PTT_ON = "/opt/pocsag-server/scripts/ptt_on.sh"
PTT_OFF = "/opt/pocsag-server/scripts/ptt_off.sh"
ENCODER = "/opt/pocsag-server/encoder/pocsag_gen.py"

def log(msg):
    os.makedirs("/opt/pocsag-server/logs",exist_ok=True)
    with open("/opt/pocsag-server/logs/pocsag.log","a") as f: f.write(f"[AGI] {msg}\n")

def fail():
    subprocess.run([PTT_OFF], check=False)
    sys.stdout.write("SET VARIABLE AGISTATUS FAILURE\n"); sys.stdout.flush(); sys.exit(1)

def main():
    try:
        interno = sys.argv[1] if len(sys.argv)>1 else "unknown"
        codigo = sys.argv[2] if len(sys.argv)>2 else ""
        mensaje = sys.argv[3] if len(sys.argv)>3 else ""
        if not codigo: fail()
        dest = resolver_destino(codigo)
        if not dest: log(f"Codigo no encontrado: {codigo}"); fail()
        caps, baudios, tipo = dest
        # Si viene del IVR (telefono), encolar y salir. El worker procesa la transmision.
        if os.environ.get("POCSAG_WORKER") != "1":
            qid = encolar_mensaje(codigo, caps, mensaje, baudios, interno)
            sys.stdout.write("SET VARIABLE AGISTATUS SUCCESS\n"); sys.stdout.flush()
            log(f"Mensaje encolado (IVR) id={qid} interno={interno} codigo={codigo} msg={mensaje}")
            return
        cap_list = [c.strip() for c in caps.split(",") if c.strip()]
        test_mode = get_config("test_mode","1") == "1"
        ptt_preactivo = float(get_config("ptt_preactivo","0.5"))
        os.makedirs(AUDIO_DIR, exist_ok=True)
        if test_mode:
            for cap in cap_list:
                registrar_bitacora(interno, codigo, cap, mensaje, baudios, "enviado", "modo test")
            sys.stdout.write("SET VARIABLE AGISTATUS SUCCESS\n"); sys.stdout.flush()
            log(f"Envio OK (TEST) interno={interno} codigo={codigo} caps={caps} msg={mensaje}")
            return
        wavs = []
        for cap in cap_list:
            wav = os.path.join(AUDIO_DIR, f"out_{cap}.wav")
            rc = subprocess.run([sys.executable, ENCODER, cap, mensaje, str(baudios), wav], capture_output=True, text=True)
            if rc.returncode != 0:
                log(f"Encoder fallo para {cap}: {rc.stderr}")
                registrar_bitacora(interno, codigo, cap, mensaje, baudios, "error", "encoder")
                fail()
            wavs.append(wav)
        subprocess.run([PTT_ON], check=True)
        time.sleep(ptt_preactivo)
        for wav in wavs:
            subprocess.run(["aplay","-q",wav], check=True)
        subprocess.run([PTT_OFF], check=True)
        for cap in cap_list:
            registrar_bitacora(interno, codigo, cap, mensaje, baudios, "enviado")
        sys.stdout.write("SET VARIABLE AGISTATUS SUCCESS\n"); sys.stdout.flush()
        log(f"Envio OK interno={interno} codigo={codigo} caps={caps} tipo={tipo} msg={mensaje}")
    except Exception as e:
        log(f"Excepcion: {e}\n{traceback.format_exc()}"); fail()

if __name__ == "__main__": main()
EOF
mkx "${APP_DIR}/agi/pocsag_handler.py"

# --- agi/cola_worker.py ---
cat > "${APP_DIR}/agi/cola_worker.py" <<'EOF'
#!/usr/bin/env python3
import sys, os, time
sys.path.insert(0, "/opt/pocsag-server")
from database.db_manager import procesar_siguiente_cola, get_conn, DEFAULT_DB

def recuperar_enviando():
    with get_conn(DEFAULT_DB) as conn:
        conn.execute("UPDATE cola_envios SET estado='pendiente' WHERE estado='enviando'")

def clog(m):
    with open("/opt/pocsag-server/logs/cola.log","a") as f: f.write(time.strftime("%Y-%m-%d %H:%M:%S")+" "+m+"\n")
def main():
    recuperar_enviando()
    os.makedirs("/opt/pocsag-server/logs", exist_ok=True)
    clog("[START] Worker de cola iniciado")
    while True:
        try:
            result = procesar_siguiente_cola()
            if result is None:
                time.sleep(2)
            else:
                clog(f"[OK] Procesado item id={result}"); time.sleep(0.5)
        except Exception as e:
            clog(f"[ERROR] {e}"); time.sleep(5)

if __name__ == "__main__": main()
EOF
mkx "${APP_DIR}/agi/cola_worker.py"

# --- agi/scheduler_worker.py ---
cat > "${APP_DIR}/agi/scheduler_worker.py" <<'EOF'
#!/usr/bin/env python3
import sys, os, time
sys.path.insert(0, "/opt/pocsag-server")
from database.db_manager import procesar_programados

def main():
    os.makedirs("/opt/pocsag-server/logs", exist_ok=True)
    with open("/opt/pocsag-server/logs/scheduler.log","a") as f: f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [START] Scheduler iniciado\n")
    while True:
        try:
            procesados = procesar_programados()
            if procesados:
                with open("/opt/pocsag-server/logs/scheduler.log","a") as f:
                    f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] procesados: {procesados}\n")
            time.sleep(30)
        except Exception as e:
            with open("/opt/pocsag-server/logs/scheduler.log","a") as f:
                f.write(f"[ERROR] {e}\n")
            time.sleep(60)

if __name__ == "__main__": main()
EOF
mkx "${APP_DIR}/agi/scheduler_worker.py"

# --- encoder/pocsag_gen.py ---
cat > "${APP_DIR}/encoder/pocsag_gen.py" <<'EOF'
#!/usr/bin/env python3
# Codificador POCSAG con Filtro Gaussiano para Radios VHF/UHF
# Genera WAV mono 16-bit compatible con entradas de audio comerciales (Mic o Data).
# Basado en el algoritmo de faithanalog/pocsag-encoder.
import sys, wave, struct, math

SYNC = 0x7CD215D8
IDLE = 0x7A89C197
FRAME_SIZE = 2
BATCH_SIZE = 16
PREAMBLE_LENGTH = 576
FLAG_MESSAGE = 0x100000
FUNCTION_ALPHANUMERIC = 0x3
CRC_BITS = 10
CRC_GENERATOR = 0b11101101001
TEXT_BITS_PER_WORD = 20
TEXT_BITS_PER_CHAR = 7

def crc(input_msg):
    denominator = CRC_GENERATOR << 20
    msg = input_msg << CRC_BITS
    for column in range(0, 21):
        if (msg >> (30 - column)) & 1:
            msg ^= denominator
        denominator >>= 1
    return msg & 0x3FF

def parity(x):
    p = 0
    for _ in range(32):
        p ^= (x & 1); x >>= 1
    return p

def encode_codeword(msg, is_message=False):
    base = (0x100000 | (msg & 0xFFFFF)) if is_message else (msg & 0xFFFFF)
    full = (base << CRC_BITS) | crc(base)
    return (full << 1) | parity(full)

def address_offset(address):
    return (address & 0x7) * FRAME_SIZE

def encode_transmission(address, message):
    out = []
    for _ in range(PREAMBLE_LENGTH // 32):
        out.append(0xAAAAAAAA)
    start = len(out)
    out.append(SYNC)
    offset = address_offset(address)
    for _ in range(offset):
        out.append(IDLE)
    addr_data = ((address >> 3) << 2) | FUNCTION_ALPHANUMERIC
    out.append(encode_codeword(addr_data, is_message=False))
    cur = 0; nbits = 0; pos = offset + 1
    for c in message:
        for i in range(TEXT_BITS_PER_CHAR):
            cur = (cur << 1) | ((ord(c) >> i) & 1)
            nbits += 1
            if nbits == TEXT_BITS_PER_WORD:
                out.append(encode_codeword(cur, is_message=True))
                cur = 0; nbits = 0; pos += 1
                if pos == BATCH_SIZE:
                    out.append(SYNC); pos = 0
    if nbits > 0:
        cur <<= (TEXT_BITS_PER_WORD - nbits)
        out.append(encode_codeword(cur, is_message=True))
        pos += 1
        if pos == BATCH_SIZE:
            out.append(SYNC); pos = 0
    out.append(IDLE)
    written = len(out) - start
    pad = (BATCH_SIZE + 1) - (written % (BATCH_SIZE + 1))
    for _ in range(pad):
        out.append(IDLE)
    return out

def modulate_gaussian(codewords, baud, sample_rate):
    spb = sample_rate // baud
    raw_bits = []
    for w in codewords:
        for b in range(31, -1, -1):
            raw_bits.append(1 if (w >> b) & 1 else 0)
    total_samples = len(raw_bits) * spb
    samples = [0.0] * total_samples
    for i, bit in enumerate(raw_bits):
        val = -1.0 if bit == 1 else 1.0
        for s in range(spb):
            samples[i * spb + s] = val
    bt = 0.5
    alpha = math.sqrt(2 * math.log(2)) / (bt / baud)
    filter_size = spb * 2 + 1
    mid = filter_size // 2
    kernel = []
    for i in range(filter_size):
        t = (i - mid) / sample_rate
        h = (alpha / math.sqrt(math.pi)) * math.exp(- (alpha * t) ** 2)
        kernel.append(h)
    ksum = sum(kernel)
    kernel = [x / ksum for x in kernel]
    filtered = [0.0] * total_samples
    for i in range(total_samples):
        val = 0.0
        for k in range(filter_size):
            idx = i - (k - mid)
            if 0 <= idx < total_samples:
                val += samples[idx] * kernel[k]
        filtered[i] = val
    out = []
    for s in filtered:
        amp = max(-32768, min(32767, int(s * 24000)))
        out.append(struct.pack('<h', amp))
    return b''.join(out)

def main():
    if len(sys.argv) != 5:
        print("Uso: pocsag_gen.py <cap> <msg> <baud> <out.wav>", file=sys.stderr)
        return 1
    cap, msg, baud, out_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    if baud not in (512, 1200, 2400):
        baud = 1200
    sample_rate = 38400
    if sample_rate % baud != 0:
        sample_rate = baud * 32
    codewords = encode_transmission(int(cap), msg)
    data = modulate_gaussian(codewords, baud, sample_rate)
    with wave.open(out_path, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sample_rate)
        w.writeframes(data)
    print(f"OK: {out_path} ({baud} bps, {sample_rate} Hz, {len(codewords)} cw)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
EOF
mkx "${APP_DIR}/encoder/pocsag_gen.py"

# --- scripts/ptt_on.sh ---
cat > "${APP_DIR}/scripts/ptt_on.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CHIP="gpiochip4"; PIN="17"
if [[ -c /dev/ttyUSB0 ]]; then stty -F /dev/ttyUSB0 9600 2>/dev/null||true; echo -n 'ON' >/dev/ttyUSB0
elif command -v gpioset >/dev/null; then gpioset "${CHIP}" "${PIN}=1"
else echo "[ptt_on] Configurar GPIO o ttyUSB0" >&2; exit 1; fi
EOF
mkx "${APP_DIR}/scripts/ptt_on.sh"

# --- scripts/ptt_off.sh ---
cat > "${APP_DIR}/scripts/ptt_off.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CHIP="gpiochip4"; PIN="17"
if [[ -c /dev/ttyUSB0 ]]; then stty -F /dev/ttyUSB0 9600 2>/dev/null||true; echo -n 'OFF' >/dev/ttyUSB0
elif command -v gpioset >/dev/null; then gpioset "${CHIP}" "${PIN}=0"
else echo "[ptt_off] Configurar GPIO o ttyUSB0" >&2; exit 1; fi
EOF
mkx "${APP_DIR}/scripts/ptt_off.sh"
if [[ -n "${POCSAG_GPIO_CHIP:-}" ]]; then sed -i "s/CHIP=\"gpiochip4\"/CHIP=\"${POCSAG_GPIO_CHIP}\"/" "${APP_DIR}/scripts/ptt_on.sh" "${APP_DIR}/scripts/ptt_off.sh"; fi
if [[ -n "${POCSAG_GPIO_PIN:-}" ]]; then sed -i "s/PIN=\"17\"/PIN=\"${POCSAG_GPIO_PIN}\"/" "${APP_DIR}/scripts/ptt_on.sh" "${APP_DIR}/scripts/ptt_off.sh"; fi

# --- scripts/healthcheck.sh ---
cat > "${APP_DIR}/scripts/healthcheck.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ok=1
check(){ if systemctl is-active --quiet "$1"; then echo "[OK]   $1"; else echo "[FAIL] $1"; ok=0; fi; }
echo "[OK]   Asterisk nativo"
if asterisk -rx "core show uptime" >/dev/null 2>&1; then echo "[OK]   asterisk"; else echo "[FAIL] asterisk"; ok=0; fi
check pocsag-api 2>/dev/null||true
command -v aplay>/dev/null&&echo "[OK]   aplay"||{ echo "[FAIL] aplay"; ok=0; }
command -v sqlite3>/dev/null&&echo "[OK]   sqlite3"||{ echo "[FAIL] sqlite3"; ok=0; }
command -v python3>/dev/null&&echo "[OK]   python3"||{ echo "[FAIL] python3"; ok=0; }
python3 /opt/pocsag-server/encoder/pocsag_gen.py 123 test 1200 /tmp/_pocsag_test.wav 2>/dev/null && rm -f /tmp/_pocsag_test.wav && echo "[OK]   encoder POCSAG" || echo "[WARN] encoder POCSAG"
[[ $ok -eq 1 ]]&&echo "Sistema POCSAG: SALUDABLE"||echo "Sistema POCSAG: REVISAR"
if [[ $ok -eq 0 ]]; then
  python3 -c "
import sys; sys.path.insert(0,'/opt/pocsag-server')
from database.db_manager import notificar_error
notificar_error('Alerta POCSAG: sistema caido','Healthcheck detecto fallos. Revisar servicios y transmisor.')
" 2>/dev/null||true
fi
exit $((1-ok))
EOF
mkx "${APP_DIR}/scripts/healthcheck.sh"

# --- scripts/limpiar_audio.sh ---
cat > "${APP_DIR}/scripts/limpiar_audio.sh" <<'EOF'
#!/usr/bin/env bash
# Elimina los WAV generados por el sistema (out_*.wav) con mas de N dias.
# NO toca las locuciones .gsm del IVR ni la base de datos.
set -euo pipefail
AUDIO_DIR="/opt/pocsag-server/audio"
DIAS="${1:-7}"
[[ -d "$AUDIO_DIR" ]] || exit 0
find "$AUDIO_DIR" -name 'out_*.wav' -type f -mtime +"${DIAS}" -delete 2>/dev/null || true
EOF
mkx "${APP_DIR}/scripts/limpiar_audio.sh"

# --- scripts/backup_auto.sh ---
cat > "${APP_DIR}/scripts/backup_auto.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PYEOF'
import sys,json,datetime,os,shutil,time
sys.path.insert(0,'/opt/pocsag-server')
from database.db_manager import get_config,set_config,enviar_email
DB="/opt/pocsag-server/database/pocsag.db";BD="/opt/pocsag-server/database/backups";LG="/opt/pocsag-server/logs/backup.log"
os.makedirs(BD,exist_ok=True)
def log(m): open(LG,"a").write(time.strftime("%Y-%m-%d %H:%M:%S")+" "+m+"\n")
try: schs=json.loads(get_config("backup_schedules","[]"))
except: schs=[]
n=datetime.datetime.now();t=n.strftime("%Y-%m-%d");u=get_config("backup_ultima","")[:10];m=None
for s in schs:
    f=s.get("f","none");h=s.get("h","03:00");d=int(s.get("d","1") or 1);p=n.hour>int(h[:2]) or (n.hour==int(h[:2]) and n.minute>=int(h[3:5]))
    if f!="none" and t!=u and p and (f=="diario" or (f=="semanal" and n.weekday()==d) or (f=="mensual" and n.day==d)): m=s; break
if not m: sys.exit(0)
set_config("backup_ultima",n.strftime("%Y-%m-%d %H:%M:%S"))
bf=os.path.join(BD,"pocsag_backup_"+time.strftime("%Y%m%d_%H%M%S")+".db");shutil.copy2(DB,bf);log("Backup ejecutado: "+os.path.basename(bf));now=time.time()
[os.remove(os.path.join(BD,fn)) for fn in os.listdir(BD) if fn.startswith("pocsag_backup_") and os.path.isfile(os.path.join(BD,fn)) and now-os.path.getmtime(os.path.join(BD,fn))>604800]
if m.get("e")=="1" and get_config("backup_email",""): r=enviar_email(get_config("backup_email",""),"Backup automatico POCSAG","Backup de base de datos adjunto.",bf); "error" in r and log("[EMAIL ERROR] "+str(r))
PYEOF
EOF
mkx "${APP_DIR}/scripts/backup_auto.sh"

# --- services/pocsag-api.service ---
cat > "${APP_DIR}/services/pocsag-api.service" <<'EOF'
[Unit]
Description=API y panel web del sistema POCSAG
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/pocsag-server/backend
ExecStart=/usr/bin/python3 /opt/pocsag-server/backend/app.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
Environment=TZ=America/Argentina/Cordoba

[Install]
WantedBy=multi-user.target
EOF

# --- services/pocsag-monitor.service ---
cat > "${APP_DIR}/services/pocsag-monitor.service" <<'EOF'
[Unit]
Description=Monitor del sistema POCSAG
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -lc 'while true; do if ! asterisk -rx "core show uptime" >/dev/null 2>&1; then systemctl restart asterisk; fi; /opt/pocsag-server/scripts/healthcheck.sh >> /opt/pocsag-server/logs/health.log 2>&1; sleep 30; done'
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# --- services/pocsag-cola.service ---
cat > "${APP_DIR}/services/pocsag-cola.service" <<'EOF'
[Unit]
Description=Worker de cola de envios POCSAG
After=network.target pocsag-api.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/pocsag-server/agi/cola_worker.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
Environment=TZ=America/Argentina/Cordoba

[Install]
WantedBy=multi-user.target
EOF

# --- services/pocsag-scheduler.service ---
cat > "${APP_DIR}/services/pocsag-scheduler.service" <<'EOF'
[Unit]
Description=Programador de envios POCSAG
After=network.target pocsag-api.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/pocsag-server/agi/scheduler_worker.py
Restart=always
RestartSec=10
Environment=PYTHONUNBUFFERED=1
Environment=TZ=America/Argentina/Cordoba

[Install]
WantedBy=multi-user.target
EOF

# --- backend/app.py ---
cat > "${APP_DIR}/backend/app.py" <<'EOF'
#!/usr/bin/env python3
import os, sys, json, csv, io, subprocess, tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote
sys.path.insert(0, "/opt/pocsag-server")
from database.db_manager import (listar_pagers, buscar_pagers, crear_pager, actualizar_pager, borrar_pager,
    toggle_pager, importar_pagers, importar_grupos,
    listar_grupos, buscar_grupos, crear_grupo, actualizar_grupo, borrar_grupo,
    listar_extensiones, crear_extension, actualizar_extension, borrar_extension, generar_pjsip_conf, generar_dialplan_conf,
    all_config, set_config, historial, enviar_mensaje, login_validar, verificar_token, cerrar_sesion,
    listar_cola, estado_cola, reintentar_cola, limpiar_cola, procesar_siguiente_cola,
    backup_db, restore_db, enviar_email,
    listar_plantillas, crear_plantilla, actualizar_plantilla, borrar_plantilla,
    listar_programados, crear_programado, actualizar_programado, borrar_programado,
    registrar_auditoria, listar_auditoria, estadisticas, leer_logs, notificar_error)

HOST=os.environ.get("POCSAG_API_HOST","0.0.0.0")
PORT=int(os.environ.get("POCSAG_API_PORT","8080"))
FRONT="/opt/pocsag-server/frontend"

def jr(h,d,c=200):
    b=json.dumps(d,ensure_ascii=False).encode()
    h.send_response(c); h.send_header("Content-Type","application/json; charset=utf-8")
    h.send_header("Access-Control-Allow-Origin","*")
    h.send_header("Content-Length",str(len(b))); h.end_headers(); h.wfile.write(b)

def read_body(h):
    ln=int(h.headers.get("Content-Length",0)); return json.loads(h.rfile.read(ln) or b"{}")

def run_cmd(args, timeout=15):
    try:
        r=subprocess.run(args,capture_output=True,text=True,timeout=timeout)
        return (r.stdout or "")+(r.stderr or "")
    except Exception as e:
        return f"Error: {e}"

def ast_run(cmd): return run_cmd(["asterisk","-rx",cmd])

SAFE_CMDS={"status":"core show status","version":"core show version","peers":"pjsip show endpoints",
           "channels":"core show channels","uptime":"core show uptime","dialplan":"dialplan show"}

def rows_from_sheet(body, filename):
    name=(filename or "").lower(); rows=[]
    if name.endswith(".csv"):
        for r in csv.DictReader(io.StringIO(body.decode("utf-8-sig",errors="replace"))): rows.append(r)
    elif name.endswith(".xlsx"):
        try: import openpyxl
        except ImportError: return None,"openpyxl no instalado. Exporte como CSV."
        tf=tempfile.NamedTemporaryFile(suffix=".xlsx",delete=False); tf.write(body); tf.close()
        try:
            wb=openpyxl.load_workbook(tf.name, read_only=True); data=list(wb.active.iter_rows(values_only=True))
        finally: os.unlink(tf.name)
        if not data: return [],None
        headers=[str(h or "").strip().lower() for h in data[0]]
        for row in data[1:]: rows.append(dict(zip(headers,[("" if c is None else str(c)) for c in row])))
    elif name.endswith(".xls"):
        try: import xlrd
        except ImportError: return None,"xlrd no instalado. Exporte como CSV o XLSX."
        tf=tempfile.NamedTemporaryFile(suffix=".xls",delete=False); tf.write(body); tf.close()
        try:
            ws=xlrd.open_workbook(tf.name).sheet_by_index(0); data=[ws.row_values(i) for i in range(ws.nrows)]
        finally: os.unlink(tf.name)
        if not data: return [],None
        headers=[str(h or "").strip().lower() for h in data[0]]
        for row in data[1:]: rows.append(dict(zip(headers,[("" if c is None else str(c)) for c in row])))
    else:
        return None,"Formato no soportado. Use .xls, .xlsx o .csv"
    return rows,None

def parse_import(body, filename):
    rows,err=rows_from_sheet(body,filename)
    if err: return None,err
    def pick(r,*keys):
        for k in keys:
            if k in r and str(r[k]).strip()!="": return str(r[k]).strip()
        return ""
    norm=[]
    for r in rows:
        item={"codigo":pick(r,"codigo","code","id"),"cap_code":pick(r,"cap_code","capcode","cap"),
              "nombre":pick(r,"nombre","name"),"apellido":pick(r,"apellido","surname","lastname"),
              "area":pick(r,"area","sector"),"baudios":pick(r,"baudios","baud") or "1200",
              "descripcion":pick(r,"descripcion","description","obs")}
        if item["codigo"] and item["cap_code"]: norm.append(item)
    return norm,None

def parse_import_grupos(body, filename):
    rows,err=rows_from_sheet(body,filename)
    if err: return None,err
    def pick(r,*keys):
        for k in keys:
            if k in r and str(r[k]).strip()!="": return str(r[k]).strip()
        return ""
    norm=[]
    for r in rows:
        item={"codigo":pick(r,"codigo","code","id"),
              "nombre":pick(r,"nombre","name"),
              "baudios":pick(r,"baudios","baud") or "1200",
              "cap_codes":pick(r,"cap_codes","capcodes","caps","miembros","cap_code")}
        if item["codigo"] and item["cap_codes"]: norm.append(item)
    return norm,None

class H(BaseHTTPRequestHandler):
    def _auth(self):
        a=self.headers.get("Authorization","")
        return verificar_token(a[7:].strip()) if a.startswith("Bearer ") else False
    def _guard(self):
        if not self._auth():
            jr(self,{"error":"no autorizado"},401); return False
        return True
    def _audit(self, accion, entidad, eid, detalle):
        try:
            a=self.headers.get("Authorization","")
            tok=a[7:].strip() if a.startswith("Bearer ") else ""
            usuario="admin" if tok else "anonimo"
            ip=self.client_address[0] if self.client_address else ""
            registrar_auditoria(usuario,accion,entidad,eid,detalle,ip)
        except Exception: pass
    def serve_file(self, fn, ctype):
        f=os.path.join(FRONT, fn)
        if os.path.exists(f):
            self.send_response(200); self.send_header("Content-Type",ctype); self.end_headers()
            with open(f,"rb") as fh: self.wfile.write(fh.read())
            return True
        self.send_response(404); self.end_headers(); return False
    def do_OPTIONS(self):
        self.send_response(204); self.send_header("Access-Control-Allow-Origin","*")
        self.send_header("Access-Control-Allow-Methods","GET,POST,PUT,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers","Content-Type,Authorization"); self.end_headers()
    def do_GET(self):
        u=urlparse(self.path); p=u.path; q=parse_qs(u.query)
        if p in ("/","/index.html"): return self.serve_file("index.html","text/html; charset=utf-8")
        if p in ("/admin","/admin.html"): return self.serve_file("admin.html","text/html; charset=utf-8")
        if p=="/api/health": return jr(self,{"status":"ok"})
        if p=="/api/version": return jr(self,{"version":all_config().get("version","1.0")})
        if p=="/api/pagers":
            qq=q.get("q",[""])[0]; return jr(self,buscar_pagers(qq) if qq else listar_pagers())
        if p=="/api/grupos":
            qq=q.get("q",[""])[0]; return jr(self,buscar_grupos(qq) if qq else listar_grupos())
        if p in ("/api/historial","/api/bitacora"):
            limit=min(int(q.get("limit",["50"])[0] or 50),500); offset=int(q.get("offset",["0"])[0] or 0)
            return jr(self, historial(q, limit, offset))
        if p in ("/api/historial/export","/api/bitacora/export"):
            rows=historial(q, 100000, 0)["rows"]
            out=io.StringIO(); out.write('\ufeff')
            w=csv.writer(out); w.writerow(["Fecha/Hora","Interno","Codigo","CapCode","Mensaje","Baudios","Estado","Observaciones"])
            for r in rows:
                w.writerow([r.get("fecha_hora"),r.get("interno_origen"),r.get("codigo"),r.get("cap_code"),
                            r.get("mensaje"),r.get("baudios"),r.get("estado"),r.get("observaciones")])
            data=out.getvalue().encode("utf-8")
            self.send_response(200); self.send_header("Content-Type","text/csv; charset=utf-8")
            self.send_header("Content-Disposition",'attachment; filename="historial_pocsag.csv"')
            self.send_header("Content-Length",str(len(data))); self.end_headers(); self.wfile.write(data); return
        if p=="/api/theme":
            c=all_config()
            return jr(self,{k:c.get(k,"") for k in ("theme_acc","theme_acc2","theme_bg","theme_panel","theme_font_heading","theme_font_body")})
        if p=="/api/config":
            if not self._guard(): return
            return jr(self, all_config())
        if p=="/api/smtp/log":
            if not self._guard(): return
            try:
                lf="/opt/pocsag-server/logs/smtp.log"
                if os.path.exists(lf):
                    lines=open(lf,encoding="utf-8",errors="ignore").read().splitlines()[-200:]
                else: lines=[]
                return jr(self, {"lines":lines})
            except Exception as e: return jr(self,{"lines":[],"error":str(e)})
        if p=="/api/smtp/log/clear":
            if not self._guard(): return
            try:
                open("/opt/pocsag-server/logs/smtp.log","w").close()
                return jr(self,{"ok":True})
            except Exception as e: return jr(self,{"error":str(e)})
        if p=="/api/extensions":
            if not self._guard(): return
            return jr(self, listar_extensiones())
        if p=="/api/pbx":
            sub=q.get("cmd",["status"])[0]; acmd=SAFE_CMDS.get(sub)
            if not acmd: return jr(self,{"error":"comando no permitido"},400)
            return jr(self,{"cmd":sub,"salida":ast_run(acmd)})
        if p=="/api/cola":
            if not self._guard(): return
            est=q.get("estado",[""])[0] if q.get("estado") else None
            return jr(self, listar_cola(est))
        if p=="/api/cola/estado":
            if not self._guard(): return
            return jr(self, estado_cola())
        if p=="/api/db/backup":
            if not self._guard(): return
            try:
                bf=backup_db()
                with open(bf,"rb") as f: data=f.read()
                self.send_response(200)
                self.send_header("Content-Type","application/octet-stream")
                self.send_header("Content-Disposition",f'attachment; filename="{os.path.basename(bf)}"')
                self.send_header("Content-Length",str(len(data))); self.end_headers()
                self.wfile.write(data)
            except Exception as e: return jr(self,{"error":str(e)},500)
            return
        if p=="/api/plantillas":
            return jr(self, listar_plantillas())
        if p=="/api/programados":
            if not self._guard(): return
            return jr(self, listar_programados())
        if p=="/api/auditoria":
            if not self._guard(): return
            limit=min(int(q.get("limit",["200"])[0] or 200),1000); offset=int(q.get("offset",["0"])[0] or 0)
            return jr(self, listar_auditoria(limit,offset))
        if p=="/api/stats":
            if not self._guard(): return
            return jr(self, estadisticas())
        if p=="/api/logs":
            if not self._guard(): return
            tipo=q.get("tipo",["api"])[0]; limit=min(int(q.get("limit",["200"])[0] or 200),1000)
            return jr(self, leer_logs(tipo,limit))
        self.send_response(404); self.end_headers()
    def do_POST(self):
        p=self.path
        try:
            if p=="/api/login":
                data=read_body(self); tok=login_validar(data.get("user",""),data.get("pass",""))
                return jr(self,{"token":tok}) if tok else jr(self,{"error":"usuario o clave incorrectos"},401)
            if p=="/api/logout":
                a=self.headers.get("Authorization","")
                if a.startswith("Bearer "): cerrar_sesion(a[7:].strip())
                return jr(self,{"ok":True})
            if p=="/api/enviar":
                data=read_body(self)
                return jr(self, enviar_mensaje(data.get("codigo",""),data.get("mensaje",""),data.get("origen","web")))
            if p=="/api/pagers":
                if not self._guard(): return
                d=read_body(self); pid=crear_pager(d)
                self._audit("crear","pager",pid,f"codigo={d.get('codigo')}")
                return jr(self,{"id":pid})
            if p=="/api/grupos":
                if not self._guard(): return
                d=read_body(self); gid=crear_grupo(d)
                self._audit("crear","grupo",gid,f"codigo={d.get('codigo')}")
                return jr(self,{"id":gid})
            if p=="/api/pagers/import":
                if not self._guard(): return
                ln=int(self.headers.get("Content-Length",0)); body=self.rfile.read(ln)
                rows,err=parse_import(body,unquote(self.headers.get("X-Filename","")))
                if err: return jr(self,{"error":err},400)
                if not rows: return jr(self,{"error":"El archivo no tiene filas validas con codigo y cap_code"},400)
                return jr(self, importar_pagers(rows))
            if p=="/api/grupos/import":
                if not self._guard(): return
                ln=int(self.headers.get("Content-Length",0)); body=self.rfile.read(ln)
                rows,err=parse_import_grupos(body,unquote(self.headers.get("X-Filename","")))
                if err: return jr(self,{"error":err},400)
                if not rows: return jr(self,{"error":"El archivo no tiene filas validas con codigo y cap_codes"},400)
                return jr(self, importar_grupos(rows))
            if p=="/api/extensions":
                if not self._guard(): return
                d=read_body(self); eid=crear_extension(d)
                self._audit("crear","extension",eid,f"numero={d.get('numero')}")
                return jr(self,{"id":eid})
            if p=="/api/plantillas":
                if not self._guard(): return
                d=read_body(self); pid=crear_plantilla(d)
                self._audit("crear","plantilla",pid,f"nombre={d.get('nombre')}")
                return jr(self,{"id":pid})
            if p=="/api/programados":
                if not self._guard(): return
                d=read_body(self); pid=crear_programado(d)
                self._audit("crear","programado",pid,f"codigo={d.get('codigo')}")
                return jr(self,{"id":pid})
            if p=="/api/extensions/aplicar":
                if not self._guard(): return
                if not generar_pjsip_conf(): return jr(self,{"error":"no se pudo escribir /etc/asterisk/pjsip_pocsag.conf (permisos)"},400)
                generar_dialplan_conf()
                return jr(self,{"salida":"Configuracion PJSIP y dialplan regenerados.\n"+ast_run("pjsip reload")+"\n"+ast_run("dialplan reload")})
            if p=="/api/pbx/reload":
                if not self._guard(): return
                out=ast_run("dialplan reload")+"\n"+ast_run("pjsip reload")
                return jr(self,{"salida":out})
            if p=="/api/pbx/restart":
                if not self._guard(): return
                out=ast_run("core restart now")
                return jr(self,{"salida":out})
            if p=="/api/cola/reintentar":
                if not self._guard(): return
                d=read_body(self); reintentar_cola(int(d["id"]))
                return jr(self,{"ok":True})
            if p=="/api/cola/limpiar":
                if not self._guard(): return
                limpiar_cola()
                return jr(self,{"ok":True})
            if p=="/api/db/restore":
                if not self._guard(): return
                ln=int(self.headers.get("Content-Length",0)); body=self.rfile.read(ln)
                try:
                    bk=restore_db(body)
                    return jr(self,{"ok":True,"backup":bk})
                except Exception as e: return jr(self,{"error":str(e)},500)
            if p=="/api/db/backup-email":
                if not self._guard(): return
                d=read_body(self)
                email=d.get("email","") or all_config().get("backup_email","")
                if not email: return jr(self,{"error":"no hay email configurado"},400)
                try:
                    bf=backup_db()
                    r=enviar_email(email,"Backup POCSAG","Backup de base de datos adjunto.",bf)
                    return jr(self, r, 200 if "ok" in r else 400)
                except Exception as e: return jr(self,{"error":str(e)},500)
            if p=="/api/smtp/test":
                if not self._guard(): return
                d=read_body(self)
                try:
                    r=enviar_email(d.get("email",""),"Prueba SMTP POCSAG","Si recibe este mensaje, SMTP funciona correctamente.")
                    return jr(self, r, 200 if "ok" in r else 400)
                except Exception as e: return jr(self,{"error":str(e)},500)
            self.send_response(404); self.end_headers()
        except Exception as e: return jr(self,{"error":str(e)},400)
    def do_PUT(self):
        parts=self.path.split("/"); data=read_body(self)
        try:
            if parts[1]=="api" and parts[2]=="pagers" and len(parts)>3:
                if not self._guard(): return
                if len(parts)>4 and parts[4]=="estado":
                    toggle_pager(int(parts[3]),data.get("activo",1)); self._audit("editar","pager",parts[3],f"activo={data.get('activo')}"); return jr(self,{"ok":True})
                actualizar_pager(int(parts[3]),data); self._audit("editar","pager",parts[3],f"codigo={data.get('codigo')}"); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="grupos" and len(parts)>3:
                if not self._guard(): return
                actualizar_grupo(int(parts[3]),data); self._audit("editar","grupo",parts[3],f"codigo={data.get('codigo')}"); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="extensiones" and len(parts)>3:
                if not self._guard(): return
                actualizar_extension(int(parts[3]),data); self._audit("editar","extension",parts[3],f"numero={data.get('numero')}"); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="plantillas" and len(parts)>3:
                if not self._guard(): return
                actualizar_plantilla(int(parts[3]),data); self._audit("editar","plantilla",parts[3],f"nombre={data.get('nombre')}"); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="programados" and len(parts)>3:
                if not self._guard(): return
                actualizar_programado(int(parts[3]),data); self._audit("editar","programado",parts[3],f"codigo={data.get('codigo')}"); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="config":
                if not self._guard(): return
                for k,v in data.items(): set_config(k,str(v))
                self._audit("editar","config","-",f"claves={list(data.keys())}")
                return jr(self,{"ok":True})
            self.send_response(404); self.end_headers()
        except Exception as e: return jr(self,{"error":str(e)},400)
    def do_DELETE(self):
        parts=self.path.split("/")
        try:
            if parts[1]=="api" and parts[2]=="pagers" and len(parts)>3:
                if not self._guard(): return
                borrar_pager(int(parts[3])); self._audit("eliminar","pager",parts[3],""); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="grupos" and len(parts)>3:
                if not self._guard(): return
                borrar_grupo(int(parts[3])); self._audit("eliminar","grupo",parts[3],""); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="extensiones" and len(parts)>3:
                if not self._guard(): return
                borrar_extension(int(parts[3])); self._audit("eliminar","extension",parts[3],""); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="plantillas" and len(parts)>3:
                if not self._guard(): return
                borrar_plantilla(int(parts[3])); self._audit("eliminar","plantilla",parts[3],""); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="programados" and len(parts)>3:
                if not self._guard(): return
                borrar_programado(int(parts[3])); self._audit("eliminar","programado",parts[3],""); return jr(self,{"ok":True})
            self.send_response(404); self.end_headers()
        except Exception as e: return jr(self,{"error":str(e)},400)
    def log_message(self,*a): pass

if __name__=="__main__":
    print(f"API POCSAG en http://{HOST}:{PORT}")
    ThreadingHTTPServer((HOST,PORT),H).serve_forever()
EOF
mkx "${APP_DIR}/backend/app.py"

# --- frontend/index.html ---
cat > "${APP_DIR}/frontend/index.html" <<'EOF'
<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>POCSAG - Paginacion Hospitalaria</title>
<style>
:root{--bg:#0a0f1e;--panel:#101a2e;--panel2:#17243f;--line:#26334f;--txt:#eaf1fb;--mut:#94a6c6;--acc:#22d3ee;--acc2:#6366f1;--ok:#22c55e;--err:#ef4444;--warn:#f59e0b;--r:16px}
*{box-sizing:border-box}
body{margin:0;font-family:'Segoe UI',system-ui,sans-serif;background:linear-gradient(180deg,var(--bg),#0a0f1c 60%);color:var(--txt);min-height:100vh}
.topbar{position:sticky;top:0;z-index:5;display:flex;align-items:center;justify-content:space-between;gap:1rem;padding:.9rem 1.4rem;background:rgba(11,18,32,.85);backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}
.brand{display:flex;align-items:center;gap:.7rem;font-weight:700;letter-spacing:.2px}
.brand .logo{width:38px;height:38px;border-radius:11px;display:grid;place-items:center;background:linear-gradient(135deg,var(--acc),var(--acc2));font-size:20px}
.brand small{display:block;font-weight:500;color:var(--mut);font-size:.72rem;letter-spacing:.5px}
.pill{display:inline-flex;align-items:center;gap:.4rem;padding:.3rem .7rem;border-radius:999px;font-size:.74rem;background:rgba(20,184,166,.12);color:#5eead4;border:1px solid rgba(20,184,166,.3)}
.pill.off{background:rgba(220,38,38,.12);color:#fca5a5;border-color:rgba(220,38,38,.3)}
.dot{width:8px;height:8px;border-radius:50%;background:#34d399;box-shadow:0 0 8px #34d399}
.pill.off .dot{background:#f87171;box-shadow:0 0 8px #f87171}
.tabs{display:flex;gap:.4rem;padding:.8rem 1.4rem;max-width:980px;margin:0 auto;flex-wrap:wrap}
.tabs button{background:transparent;border:1px solid var(--line);color:var(--mut);border-radius:10px;padding:.55rem 1.1rem;cursor:pointer;font-weight:600;font-size:.86rem;transition:.15s}
.tabs button.active{background:linear-gradient(135deg,var(--acc),var(--acc2));color:#fff;border-color:transparent;box-shadow:0 4px 14px rgba(20,184,166,.3)}
main{max-width:980px;margin:0 auto;padding:.4rem 1.4rem 3rem}
.card{background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:1.4rem;margin-bottom:1.2rem;box-shadow:0 10px 30px rgba(0,0,0,.25)}
.card h2{margin:0 0 1rem;font-size:1.05rem;display:flex;align-items:center;gap:.5rem}
.card h2 .ic{color:var(--acc)}
.field{margin-bottom:.9rem}
label{display:block;font-size:.74rem;color:var(--mut);margin-bottom:.3rem;font-weight:600;letter-spacing:.4px;text-transform:uppercase}
input,select,textarea{width:100%;background:var(--panel2);border:1px solid var(--line);color:var(--txt);border-radius:10px;padding:.6rem .7rem;font-size:.92rem;outline:none;transition:.15s}
input:focus,select:focus,textarea:focus{border-color:var(--acc);box-shadow:0 0 0 3px rgba(20,184,166,.15)}
.row{display:flex;gap:.7rem;flex-wrap:wrap}
.row>*{flex:1;min-width:140px}
.btn{cursor:pointer;border:none;border-radius:10px;padding:.6rem 1.1rem;font-weight:700;font-size:.88rem;transition:.15s;display:inline-flex;align-items:center;gap:.4rem}
.btn:active{transform:translateY(1px)}
.btn-pri{background:linear-gradient(135deg,var(--acc),var(--acc2));color:#fff;box-shadow:0 6px 18px rgba(20,184,166,.3)}
.btn-pri:hover{filter:brightness(1.08)}
.btn-sec{background:var(--panel2);color:var(--txt);border:1px solid var(--line)}
.btn-sec:hover{border-color:var(--acc)}
.btn-ok{background:var(--ok);color:#fff}.btn-del{background:var(--err);color:#fff}
table{width:100%;border-collapse:collapse;font-size:.84rem}
th,td{text-align:left;padding:.55rem .5rem;border-bottom:1px solid var(--line)}
th{color:var(--mut);font-weight:600;font-size:.74rem;text-transform:uppercase;letter-spacing:.5px}
tbody tr:hover{background:rgba(20,184,166,.05)}
.badge{padding:.18rem .55rem;border-radius:999px;font-size:.72rem;font-weight:600}
.badge.ok{background:rgba(22,163,74,.18);color:#86efac}.badge.err{background:rgba(220,38,38,.18);color:#fca5a5}
.filters{display:flex;gap:.6rem;flex-wrap:wrap;align-items:flex-end;margin-bottom:1rem}
.filters>*{flex:1;min-width:130px}
.filters .btn{flex:0 0 auto}
.combo{position:relative}
.combo input{width:100%}
.combo ul{position:absolute;z-index:6;left:0;right:0;margin-top:.2rem;background:var(--panel2);border:1px solid var(--line);border-radius:10px;max-height:280px;overflow:auto;list-style:none;padding:.3rem;box-shadow:0 12px 30px rgba(0,0,0,.4);display:none}
.combo ul.open{display:block}
.combo li{padding:.5rem .6rem;border-radius:7px;cursor:pointer;font-size:.85rem;display:flex;justify-content:space-between;gap:.5rem}
.combo li:hover{background:rgba(20,184,166,.12)}
.combo li .tg{font-size:.7rem;color:var(--acc);font-weight:700}
.pager{display:flex;justify-content:space-between;align-items:center;margin-top:1rem;color:var(--mut);font-size:.84rem;flex-wrap:wrap;gap:.6rem}
.pager button{background:var(--panel2);border:1px solid var(--line);color:var(--txt);border-radius:8px;padding:.35rem .8rem;cursor:pointer}
.pager button:disabled{opacity:.4;cursor:not-allowed}
.toast{margin-top:.8rem;padding:.7rem .9rem;border-radius:10px;font-size:.86rem;display:none}
.toast.show{display:block}
.toast.ok{background:rgba(22,163,74,.14);border:1px solid rgba(22,163,74,.4);color:#86efac}
.toast.err{background:rgba(220,38,38,.14);border:1px solid rgba(220,38,38,.4);color:#fca5a5}
.foot{max-width:980px;margin:0 auto;padding:0 1.4rem 2rem;color:var(--mut);font-size:.78rem;display:flex;justify-content:space-between;flex-wrap:wrap;gap:.6rem}
.foot a{color:var(--acc);text-decoration:none}
.tab{display:none}.tab.active{display:block}
@media(max-width:560px){.row>*{min-width:100%}.topbar{padding:.7rem 1rem;flex-wrap:wrap;gap:.5rem}.tabs{padding:.6rem 1rem;flex-wrap:nowrap;overflow-x:auto;-webkit-overflow-scrolling:touch}.main{padding:.4rem 1rem}.card{padding:1rem}}
</style></head>
<body>
<style>:root{--acc:#0ea5e9;--acc2:#6366f1;--bg:#f4f7fb;--panel:#ffffff;--panel2:#f1f5f9;--line:rgba(15,23,42,.08);--txt:#0f172a;--mut:#64748b;--r:20px}body{font-family:'Inter',ui-sans-serif,system-ui,-apple-system,'Segoe UI',sans-serif!important;color:#0f172a!important;background:radial-gradient(900px 600px at 8% -10%,rgba(14,165,233,.10),transparent 60%),radial-gradient(820px 520px at 102% 0%,rgba(99,102,241,.10),transparent 55%),radial-gradient(760px 760px at 50% 120%,rgba(16,185,129,.08),transparent 60%),#f4f7fb!important;background-attachment:fixed!important}.topbar{backdrop-filter:blur(16px) saturate(150%)!important;-webkit-backdrop-filter:blur(16px) saturate(150%)!important;background:rgba(255,255,255,.75)!important;border-bottom:1px solid rgba(15,23,42,.08)!important}.card{background:rgba(255,255,255,.85)!important;backdrop-filter:blur(16px) saturate(140%)!important;-webkit-backdrop-filter:blur(16px) saturate(140%)!important;border:1px solid rgba(15,23,42,.08)!important;border-radius:var(--r)!important;box-shadow:0 1px 2px rgba(15,23,42,.04),0 12px 30px -12px rgba(15,23,42,.12)!important;transition:transform .25s ease,box-shadow .25s ease!important}.card:hover{transform:translateY(-2px)!important;box-shadow:0 1px 2px rgba(15,23,42,.05),0 20px 40px -12px rgba(15,23,42,.18)!important}input,select,textarea{background:#fff!important;border:1px solid rgba(15,23,42,.12)!important;color:#0f172a!important;border-radius:12px!important}input:focus,select:focus,textarea:focus{border-color:var(--acc)!important;box-shadow:0 0 0 4px rgba(14,165,233,.15)!important}.btn{border-radius:12px!important;transition:.2s!important}.btn-pri{background:linear-gradient(135deg,var(--acc),var(--acc2))!important;color:#fff!important;box-shadow:0 6px 18px -6px rgba(14,165,233,.45)!important}.btn-pri:hover{filter:brightness(1.05)!important;transform:translateY(-1px)!important}.btn-sec{background:#fff!important;color:#0f172a!important;border:1px solid rgba(15,23,42,.12)!important}.btn-sec:hover{border-color:var(--acc)!important;background:#f8fafc!important}.btn-ok{color:#fff!important}.btn-del{color:#fff!important}.brand .logo,.login .logo,.side .brand .logo{box-shadow:0 8px 20px -6px rgba(14,165,233,.4)!important}.tabs button{border-radius:12px!important;border:1px solid rgba(15,23,42,.12)!important;color:#475569!important;background:#fff!important}.tabs button.active{background:linear-gradient(135deg,var(--acc),var(--acc2))!important;color:#fff!important;box-shadow:0 6px 16px -6px rgba(14,165,233,.4)!important;border-color:transparent!important}.side{background:rgba(255,255,255,.8)!important;backdrop-filter:blur(16px) saturate(140%)!important;-webkit-backdrop-filter:blur(16px) saturate(140%)!important;border-right:1px solid rgba(15,23,42,.08)!important}.side nav button{border-radius:12px!important;color:#475569!important}.side nav button:hover{background:#f1f5f9!important;color:#0f172a!important}.side nav button.active{background:linear-gradient(135deg,rgba(14,165,233,.15),rgba(99,102,241,.15))!important;color:#0369a1!important;border:1px solid rgba(14,165,233,.3)!important}.login .box{background:rgba(255,255,255,.92)!important;backdrop-filter:blur(20px) saturate(150%)!important;-webkit-backdrop-filter:blur(20px) saturate(150%)!important;border:1px solid rgba(15,23,42,.08)!important;box-shadow:0 24px 60px -20px rgba(15,23,42,.25)!important}.login h1{color:#0f172a!important}.login p{color:#64748b!important}tbody tr:hover{background:rgba(14,165,233,.06)!important}.pill{background:rgba(14,165,233,.12)!important;color:#0369a1!important;border:1px solid rgba(14,165,233,.25)!important}.dot{box-shadow:0 0 8px #10b981!important}pre{background:#f8fafc!important;border:1px solid rgba(15,23,42,.1)!important;color:#0f172a!important;border-radius:12px!important;padding:.8rem 1rem!important}.badge.ok{background:rgba(16,163,74,.15)!important;color:#15803d!important}.badge.err{background:rgba(220,38,38,.12)!important;color:#b91c1c!important}.toast{color:#0f172a!important}.toast.ok{background:rgba(16,163,74,.12)!important;border:1px solid rgba(16,163,74,.3)!important;color:#15803d!important}.toast.err{background:rgba(220,38,38,.1)!important;border:1px solid rgba(220,38,38,.3)!important;color:#b91c1c!important}.combo ul{background:#fff!important;border:1px solid rgba(15,23,42,.12)!important;box-shadow:0 12px 30px rgba(15,23,42,.12)!important}.combo li:hover{background:rgba(14,165,233,.1)!important}.pager button{background:#fff!important;border:1px solid rgba(15,23,42,.12)!important;color:#0f172a!important}.foot{color:#64748b!important}.foot a{color:var(--acc)!important}th{color:#64748b!important}.card h2{color:#0f172a!important}</style>
<div class="topbar">
  <div class="brand"><div class="logo">🧭</div><div>POCSAG<small>paginacion hospitalaria</small></div></div>
  <span id="h" class="pill"><span class="dot"></span> en linea</span>
  <span id="ver" class="badge mut" style="margin-left:auto">v1.03</span>
</div>
<div class="tabs">
  <button class="active" onclick="tab('enviar',this)">📨 Enviar mensaje</button>
  <button onclick="tab('hist',this)">🕘 Historial</button>
</div>
<main>
<div class="tab active" id="t-enviar"><div class="card">
  <h2><span class="ic">📨</span> Enviar mensaje a un codigo o grupo</h2>
  <div class="field"><label>Buscar destinatario (nombre, apellido, codigo o area)</label>
    <div class="combo" id="cmb">
      <input id="e_q" autocomplete="off" placeholder="Escriba para buscar...">
      <ul id="e_list"></ul>
    </div>
  </div>
  <div class="field"><label>Mensaje (alfanumerico)</label><textarea id="e_msg" rows="3" placeholder="Escriba el mensaje para el pager..."></textarea></div>
  <div class="field" id="e_tpl_wrap" style="display:none"><label>Plantillas rapidas</label><div id="e_tpl" style="display:flex;gap:.4rem;flex-wrap:wrap"></div></div>
  <button class="btn btn-pri" onclick="enviar()">Enviar mensaje</button>
  <div id="e_res" class="toast"></div>
</div></div>
<div class="tab" id="t-hist"><div class="card">
  <h2><span class="ic">🕘</span> Historial de mensajes</h2>
  <div class="filters">
    <div><label>Desde</label><input id="b_desde" type="date"></div>
    <div><label>Hasta</label><input id="b_hasta" type="date"></div>
    <div><label>Codigo</label><input id="b_codigo" placeholder="ej 10"></div>
    <div><label>Interno</label><input id="b_interno" placeholder="ej 101"></div>
    <div><label>Estado</label><select id="b_estado"><option value="">Todos</option><option>enviado</option><option>error</option></select></div>
    <button class="btn btn-pri" onclick="loadHist(0)">Filtrar</button>
    <button class="btn btn-ok" onclick="exportHist()">⬇ Exportar Excel</button>
  </div>
  <div style="overflow-x:auto">
  <table><thead><tr><th>Fecha/Hora</th><th>Interno</th><th>Codigo</th><th>Cap</th><th>Mensaje</th><th>Estado</th></tr></thead><tbody id="bit"></tbody></table>
  </div>
  <div class="pager">
    <span id="pg_info">—</span>
    <div><button id="pg_prev" onclick="pgGo(-1)">← Anterior</button> <button id="pg_next" onclick="pgGo(1)">Siguiente →</button></div>
  </div>
</div></div>
</main>
<div class="foot"><span>Sistema POCSAG · VoIP a pager</span><a href="/admin">Acceso administradores →</a></div>
<script>
const PG=50; let offset=0, total=0, chosen=null, histTimer=null;
function tab(id,el){document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));document.querySelectorAll('.tabs button').forEach(b=>b.classList.remove('active'));document.getElementById('t-'+id).classList.add('active');el.classList.add('active');if(histTimer){clearInterval(histTimer);histTimer=null;}if(id==='hist'){loadHist(0);histTimer=setInterval(()=>loadHist(offset),8000);}}
function toast(ok,msg){const t=document.getElementById('e_res');t.className='toast show '+(ok?'ok':'err');t.textContent=msg;}
async function buscarDest(q){
  const [pe,gr]=await Promise.all([fetch('/api/pagers'+(q?('?q='+encodeURIComponent(q)):'')).then(r=>r.json()),fetch('/api/grupos'+(q?('?q='+encodeURIComponent(q)):'')).then(r=>r.json())]);
  const out=[];
  (pe||[]).filter(x=>x.activo).forEach(x=>out.push({codigo:x.codigo,label:`${x.nombre||''} ${x.apellido||''}`.trim()||x.codigo,sub:`${x.area||x.cap_code} · cap ${x.cap_code}`,tipo:'pager'}));
  (gr||[]).filter(x=>x.activo).forEach(x=>out.push({codigo:x.codigo,label:x.nombre||x.codigo,sub:`GRUPO · ${(x.miembros||[]).length} pagers`,tipo:'grupo'}));
  return out;
}
async function applyTheme(){try{const c=await fetch('/api/theme').then(r=>r.json());const acc=c.theme_acc||'#0ea5e9',acc2=c.theme_acc2||'#6366f1',bg=c.theme_bg||'#f4f7fb',panel=c.theme_panel||'#ffffff',fh=c.theme_font_heading||'Space Grotesk',fb=c.theme_font_body||'Inter';let s=document.getElementById('dyn-theme');if(!s){s=document.createElement('style');s.id='dyn-theme';document.body.appendChild(s);}s.textContent=`:root{--acc:${acc}!important;--acc2:${acc2}!important;--bg:${bg}!important;--panel:${panel}!important}body{background:radial-gradient(900px 600px at 8% -10%,${acc}22,transparent 60%),radial-gradient(820px 520px at 102% 0%,${acc2}22,transparent 55%),${bg}!important}.btn-pri,.tabs button.active,.brand .logo,.login .logo,.side .brand .logo{background:linear-gradient(135deg,${acc},${acc2})!important}h1,h2,h3,.brand,.tabs button,.btn,.login h1{font-family:'${fh}','Inter',sans-serif!important}body{font-family:'${fb}',ui-sans-serif,system-ui,sans-serif!important}`}catch(e){}}
const eq=document.getElementById('e_q'),elist=document.getElementById('e_list');
let btimer=null;
eq.addEventListener('input',()=>{clearTimeout(btimer);btimer=setTimeout(async()=>{const r=await buscarDest(eq.value.trim());renderList(r);},180);});
eq.addEventListener('focus',()=>{if(elist.innerHTML)elist.classList.add('open');});
function renderList(r){elist.innerHTML=r.map(x=>`<li onclick="pickDest('${x.codigo}','${(x.label||'').replace(/'/g,"")}')" data-c="${x.codigo}"><span>${x.label} <span style="color:var(--mut);font-size:.8rem">${x.codigo}</span></span><span class="tg">${x.tipo}</span></li>`).join('');elist.classList.toggle('open',r.length>0);}
function pickDest(codigo,label){chosen=codigo;eq.value=label+' ('+codigo+')';elist.classList.remove('open');}
document.addEventListener('click',e=>{if(!document.getElementById('cmb').contains(e.target))elist.classList.remove('open');});
async function enviar(){
  const codigo=chosen, mensaje=document.getElementById('e_msg').value.trim();
  if(!codigo){toast(false,'Seleccione un destinatario de la lista.');return;}
  if(!mensaje){toast(false,'Escriba un mensaje.');return;}
  const r=await fetch('/api/enviar',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({codigo,mensaje,origen:'web'})}).then(r=>r.json());
  if(r.status==='enviado'||r.status==='encolado'){toast(true,r.status==='encolado'?'Mensaje encolado para envio.':'Mensaje enviado correctamente.');document.getElementById('e_msg').value='';loadHist(offset);}else toast(false,'Error: '+(r.detalle||'no se pudo enviar'));
}
function histQuery(){const p=new URLSearchParams();p.set('limit',PG);p.set('offset',offset);
  const d=document.getElementById('b_desde').value,h=document.getElementById('b_hasta').value,c=document.getElementById('b_codigo').value,i=document.getElementById('b_interno').value,e=document.getElementById('b_estado').value;
  if(d)p.set('fecha_desde',d);if(h)p.set('fecha_hasta',h+'T23:59:59');if(c)p.set('codigo',c);if(i)p.set('interno',i);if(e)p.set('estado',e);return p;}
const badge=e=>`<span class="badge ${e==='enviado'?'ok':'err'}">${e||'-'}</span>`;
async function loadHist(off){offset=off||0;document.getElementById('bit').innerHTML='<tr><td colspan="6" style="text-align:center;color:var(--mut);padding:1.4rem">Cargando...</td></tr>';const r=await fetch('/api/historial?'+histQuery()).then(r=>r.json());total=r.total||0;const rows=r.rows||[];
  document.getElementById('bit').innerHTML=rows.length?rows.map(x=>`<tr><td>${x.fecha_hora}</td><td>${x.interno_origen||''}</td><td>${x.codigo}</td><td>${x.cap_code||''}</td><td>${x.mensaje||''}</td><td>${badge(x.estado)}</td></tr>`).join(''):`<tr><td colspan="6" style="text-align:center;color:var(--mut);padding:1.4rem">Sin registros</td></tr>`;
  document.getElementById('pg_info').textContent=`${rows.length?offset+1:0}-${offset+rows.length} de ${total}`;
  document.getElementById('pg_prev').disabled=offset<=0;document.getElementById('pg_next').disabled=offset+PG>=total;}
function pgGo(d){loadHist(Math.max(0,offset+d*PG));}
function exportHist(){window.open('/api/historial/export?'+(function(){const p=new URLSearchParams();const d=document.getElementById('b_desde').value,h=document.getElementById('b_hasta').value,c=document.getElementById('b_codigo').value,i=document.getElementById('b_interno').value,e=document.getElementById('b_estado').value;if(d)p.set('fecha_desde',d);if(h)p.set('fecha_hasta',h+'T23:59:59');if(c)p.set('codigo',c);if(i)p.set('interno',i);if(e)p.set('estado',e);return p;})(),'_blank');}
async function health(){try{const h=await fetch('/api/health').then(r=>r.json());const p=document.getElementById('h');p.className='pill '+(h.status==='ok'?'':'off');p.innerHTML=`<span class="dot"></span> ${h.status==='ok'?'en linea':'caido'}`;}catch(e){document.getElementById('h').className='pill off';document.getElementById('h').innerHTML='<span class="dot"></span> caido';}}
async function loadTpl(){try{const t=await fetch('/api/plantillas').then(r=>r.json());const act=(t||[]).filter(x=>x.activo);if(!act.length)return;document.getElementById('e_tpl_wrap').style.display='block';document.getElementById('e_tpl').innerHTML=act.map(x=>`<button type="button" class="btn btn-sec btn-sm" onclick="useTpl(${x.id})" data-id="${x.id}">${x.nombre}</button>`).join('');window._tpls=act;}catch(e){}}
function useTpl(id){const t=(window._tpls||[]).find(x=>x.id===id);if(t)document.getElementById('e_msg').value=t.mensaje;}
(async()=>{applyTheme();health();setInterval(health,15000);loadTpl();loadVersion();})();async function loadVersion(){try{const v=await fetch('/api/version').then(r=>r.json());const el=document.getElementById('ver');if(el)el.textContent='v'+(v.version||'1.0');}catch(e){}}
</script>
<style>
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=Space+Grotesk:wght@400;500;600;700&display=swap');
*{font-family:'Inter',ui-sans-serif,system-ui,-apple-system,sans-serif!important}
h1,h2,h3,.brand,.tabs button,.btn,.login h1{font-family:'Space Grotesk','Inter',sans-serif!important;letter-spacing:-.01em!important}
body{background:radial-gradient(900px 600px at 8% -10%,rgba(14,165,233,.15),transparent 60%),radial-gradient(820px 520px at 102% 0%,rgba(99,102,241,.15),transparent 55%),radial-gradient(760px 760px at 50% 120%,rgba(16,185,129,.10),transparent 60%),#f4f7fb!important;background-attachment:fixed!important;color:#0f172a!important}
.brand .logo,.login .logo,.side .brand .logo{background:linear-gradient(135deg,#0ea5e9,#6366f1,#10b981)!important;box-shadow:0 8px 22px -6px rgba(99,102,241,.5)!important}
.topbar{background:rgba(255,255,255,.7)!important;backdrop-filter:blur(18px) saturate(160%)!important;-webkit-backdrop-filter:blur(18px) saturate(160%)!important;border-bottom:1px solid rgba(15,23,42,.07)!important}
.card{background:rgba(255,255,255,.86)!important;backdrop-filter:blur(18px) saturate(150%)!important;-webkit-backdrop-filter:blur(18px) saturate(150%)!important;border:1px solid rgba(15,23,42,.07)!important;border-radius:22px!important;box-shadow:0 1px 2px rgba(15,23,42,.04),0 14px 34px -14px rgba(15,23,42,.16)!important;transition:transform .25s ease,box-shadow .25s ease!important}
.card:hover{transform:translateY(-2px)!important;box-shadow:0 1px 2px rgba(15,23,42,.05),0 22px 44px -14px rgba(15,23,42,.2)!important}
.card h2{font-weight:700!important}
.btn{border-radius:13px!important;font-weight:600!important;transition:.2s!important}
.btn-pri{background:linear-gradient(135deg,#0ea5e9,#6366f1)!important;color:#fff!important;border:none!important;box-shadow:0 8px 20px -6px rgba(99,102,241,.45)!important}
.btn-pri:hover{filter:brightness(1.06)!important;transform:translateY(-1px)!important}
.btn-sec{background:#fff!important;color:#0f172a!important;border:1px solid rgba(15,23,42,.12)!important}
.btn-sec:hover{border-color:#0ea5e9!important;background:#f8fafc!important}
.btn-ok{background:linear-gradient(135deg,#10b981,#059669)!important;color:#fff!important;border:none!important}
.btn-del{background:linear-gradient(135deg,#ef4444,#dc2626)!important;color:#fff!important;border:none!important}
.btn-warn{background:linear-gradient(135deg,#f59e0b,#d97706)!important;color:#fff!important;border:none!important}
.tabs button{background:#fff!important;border:1px solid rgba(15,23,42,.1)!important;color:#475569!important;border-radius:13px!important;font-weight:600!important}
.tabs button.active{background:linear-gradient(135deg,#0ea5e9,#6366f1)!important;color:#fff!important;border-color:transparent!important;box-shadow:0 8px 18px -6px rgba(99,102,241,.45)!important}
.side{background:rgba(255,255,255,.82)!important;backdrop-filter:blur(18px) saturate(150%)!important;-webkit-backdrop-filter:blur(18px) saturate(150%)!important;border-right:1px solid rgba(15,23,42,.07)!important}
.side nav button{border-radius:13px!important;color:#475569!important;font-weight:600!important}
.side nav button:hover{background:#f1f5f9!important;color:#0f172a!important}
.side nav button.active{background:linear-gradient(135deg,rgba(14,165,233,.16),rgba(99,102,241,.16))!important;color:#0369a1!important;border:1px solid rgba(14,165,233,.3)!important}
.login .box{background:rgba(255,255,255,.92)!important;backdrop-filter:blur(24px) saturate(160%)!important;-webkit-backdrop-filter:blur(24px) saturate(160%)!important;border:1px solid rgba(15,23,42,.07)!important;border-radius:26px!important;box-shadow:0 28px 70px -24px rgba(15,23,42,.28)!important}
.login h1{color:#0f172a!important}
.login p{color:#64748b!important}
input,select,textarea{background:#fff!important;border:1px solid rgba(15,23,42,.12)!important;color:#0f172a!important;border-radius:13px!important}
input:focus,select:focus,textarea:focus{border-color:#0ea5e9!important;box-shadow:0 0 0 4px rgba(14,165,233,.16)!important;outline:none!important}
label{color:#64748b!important}
th{color:#64748b!important;font-family:'Space Grotesk',sans-serif!important;letter-spacing:.3px!important}
tbody tr:hover{background:rgba(14,165,233,.06)!important}
.badge.ok{background:rgba(16,163,74,.15)!important;color:#15803d!important}
.badge.err{background:rgba(220,38,38,.12)!important;color:#b91c1c!important}
.badge.mut{background:#f1f5f9!important;color:#64748b!important}
.pill{background:rgba(14,165,233,.12)!important;color:#0369a1!important;border:1px solid rgba(14,165,233,.25)!important;font-weight:600!important}
.pill.off{background:rgba(220,38,38,.12)!important;color:#b91c1c!important;border-color:rgba(220,38,38,.25)!important}
.combo ul{background:#fff!important;border:1px solid rgba(15,23,42,.1)!important;box-shadow:0 16px 40px -12px rgba(15,23,42,.2)!important;border-radius:13px!important}
.combo li:hover{background:rgba(14,165,233,.08)!important}
.sw{background:#cbd5e1!important}
.sw.on{background:linear-gradient(135deg,#10b981,#059669)!important}
pre{background:#f8fafc!important;border:1px solid rgba(15,23,42,.1)!important;color:#0f172a!important;border-radius:13px!important;padding:.8rem 1rem!important}
.toast{border-radius:13px!important}
.toast.ok{background:rgba(16,163,74,.12)!important;border:1px solid rgba(16,163,74,.3)!important;color:#15803d!important}
.toast.err{background:rgba(220,38,38,.1)!important;border:1px solid rgba(220,38,38,.3)!important;color:#b91c1c!important}
</style>
</body></html>
EOF

# --- frontend/admin.html ---
cat > "${APP_DIR}/frontend/admin.html" <<'EOF'
<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>POCSAG - Admin</title>
<style>
:root{--bg:#0a0f1e;--panel:#101a2e;--panel2:#17243f;--line:#26334f;--txt:#eaf1fb;--mut:#94a6c6;--acc:#22d3ee;--acc2:#6366f1;--ok:#22c55e;--err:#ef4444;--warn:#f59e0b;--r:16px}
*{box-sizing:border-box}
body{margin:0;font-family:'Segoe UI',system-ui,sans-serif;background:linear-gradient(180deg,var(--bg),#0a0f1c 60%);color:var(--txt);min-height:100vh}
.login{min-height:100vh;display:grid;place-items:center;padding:1rem}
.login .box{background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:2.2rem;width:100%;max-width:380px;box-shadow:0 20px 60px rgba(0,0,0,.45)}
.login .logo{width:54px;height:54px;border-radius:16px;display:grid;place-items:center;background:linear-gradient(135deg,var(--acc),var(--acc2));font-size:28px;margin:0 auto .8rem}
.login h1{text-align:center;font-size:1.2rem;margin:.2rem 0 .2rem}.login p{text-align:center;color:var(--mut);font-size:.82rem;margin:0 0 1.4rem}
.app{display:flex;min-height:100vh}
.side{width:230px;background:var(--panel);border-right:1px solid var(--line);padding:1rem 0;display:flex;flex-direction:column;position:sticky;top:0;height:100vh}
.side .brand{display:flex;align-items:center;gap:.6rem;padding:.4rem 1rem 1rem;font-weight:700}
.side .brand .logo{width:34px;height:34px;border-radius:10px;display:grid;place-items:center;background:linear-gradient(135deg,var(--acc),var(--acc2));font-size:18px}
.side nav{flex:1;display:flex;flex-direction:column;gap:.2rem;padding:0 .6rem}
.side nav button{background:transparent;border:none;color:var(--mut);text-align:left;padding:.6rem .8rem;border-radius:10px;cursor:pointer;font-size:.9rem;font-weight:600;display:flex;align-items:center;gap:.6rem}
.side nav button:hover{background:var(--panel2);color:var(--txt)}
.side nav button.active{background:linear-gradient(135deg,rgba(20,184,166,.18),rgba(14,165,233,.18));color:var(--acc);border:1px solid rgba(20,184,166,.3)}
.side .bot{padding:.6rem}
.pill{display:inline-flex;align-items:center;gap:.4rem;padding:.3rem .7rem;border-radius:999px;font-size:.74rem;background:rgba(20,184,166,.12);color:#5eead4;border:1px solid rgba(20,184,166,.3)}
.content{flex:1;padding:1.4rem 2rem;max-width:1100px}
.topbar{display:flex;justify-content:space-between;align-items:center;margin-bottom:1.4rem;flex-wrap:wrap;gap:.6rem}
.topbar h1{margin:0;font-size:1.3rem}
.card{background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:1.4rem;margin-bottom:1.2rem;box-shadow:0 10px 30px rgba(0,0,0,.25)}
.card h2{margin:0 0 1rem;font-size:1.05rem;display:flex;align-items:center;gap:.5rem;justify-content:space-between}
.toolbar{display:flex;gap:.6rem;flex-wrap:wrap;margin-bottom:1rem;align-items:center}
.search{flex:1;min-width:200px;position:relative}
.search input{width:100%}
label{display:block;font-size:.72rem;color:var(--mut);margin-bottom:.3rem;font-weight:600;letter-spacing:.4px;text-transform:uppercase}
input,select,textarea{width:100%;background:var(--panel2);border:1px solid var(--line);color:var(--txt);border-radius:10px;padding:.55rem .7rem;font-size:.9rem;outline:none;transition:.15s}
input:focus,select:focus,textarea:focus{border-color:var(--acc);box-shadow:0 0 0 3px rgba(20,184,166,.15)}
.row{display:flex;gap:.7rem;flex-wrap:wrap}.row>*{flex:1;min-width:140px}
.btn{cursor:pointer;border:none;border-radius:10px;padding:.55rem 1rem;font-weight:700;font-size:.85rem;transition:.15s;display:inline-flex;align-items:center;gap:.4rem}
.btn:active{transform:translateY(1px)}
.btn-pri{background:linear-gradient(135deg,var(--acc),var(--acc2));color:#fff}
.btn-pri:hover{filter:brightness(1.08)}
.btn-sec{background:var(--panel2);color:var(--txt);border:1px solid var(--line)}
.btn-sec:hover{border-color:var(--acc)}
.btn-ok{background:var(--ok);color:#fff}.btn-del{background:var(--err);color:#fff}.btn-warn{background:var(--warn);color:#fff}
.btn-sm{padding:.35rem .6rem;font-size:.78rem}
table{width:100%;border-collapse:collapse;font-size:.84rem}
th,td{text-align:left;padding:.5rem .5rem;border-bottom:1px solid var(--line)}
th{color:var(--mut);font-weight:600;font-size:.72rem;text-transform:uppercase;letter-spacing:.5px}
tbody tr:hover{background:rgba(20,184,166,.05)}
.badge{padding:.18rem .5rem;border-radius:999px;font-size:.7rem;font-weight:600}
.badge.ok{background:rgba(22,163,74,.18);color:#86efac}.badge.err{background:rgba(220,38,38,.18);color:#fca5a5}.badge.mut{background:var(--panel2);color:var(--mut)}
.sw{position:relative;width:42px;height:24px;border-radius:999px;background:#334155;cursor:pointer;transition:.15s;border:none}
.sw.on{background:var(--ok)}.sw::after{content:"";position:absolute;top:3px;left:3px;width:18px;height:18px;border-radius:50%;background:#fff;transition:.15s}.sw.on::after{left:21px}
.filters{display:flex;gap:.6rem;flex-wrap:wrap;align-items:flex-end;margin-bottom:1rem}.filters>*{flex:1;min-width:130px}.filters .btn{flex:0 0 auto}
.modal{position:fixed;inset:0;background:rgba(0,0,0,.6);display:none;align-items:center;justify-content:center;z-index:20;padding:1rem}
.modal.open{display:flex}.modal .card{width:100%;max-width:480px;margin:0}
.pager{display:flex;justify-content:space-between;align-items:center;margin-top:1rem;color:var(--mut);font-size:.84rem;flex-wrap:wrap;gap:.6rem}
.pager button{background:var(--panel2);border:1px solid var(--line);color:var(--txt);border-radius:8px;padding:.35rem .8rem;cursor:pointer}.pager button:disabled{opacity:.4;cursor:not-allowed}
pre{background:#0a0f1c;border:1px solid var(--line);border-radius:10px;padding:.8rem;overflow:auto;max-height:340px;font-size:.78rem;white-space:pre-wrap}
.drop{border:2px dashed var(--line);border-radius:14px;padding:1.6rem;text-align:center;color:var(--mut)}
.drop.hover{border-color:var(--acc);background:rgba(20,184,166,.06)}
.toast{margin-top:.8rem;padding:.7rem .9rem;border-radius:10px;font-size:.86rem;display:none}.toast.show{display:block}
.toast.ok{background:rgba(22,163,74,.14);border:1px solid rgba(22,163,74,.4);color:#86efac}.toast.err{background:rgba(220,38,38,.14);border:1px solid rgba(220,38,38,.4);color:#fca5a5}
.tab{display:none}.tab.active{display:block}
@media(max-width:760px){.app{flex-direction:column}.side{width:100%;height:auto;position:sticky;top:0;z-index:30;flex-direction:row;align-items:center;justify-content:space-between;padding:.6rem 1rem;overflow:visible;box-shadow:0 2px 10px rgba(0,0,0,.08)}.side .brand{padding:0}.side .burger{display:inline-flex!important}.side nav{display:none;position:absolute;top:100%;left:0;right:0;flex-direction:column;background:var(--panel);border:1px solid var(--line);border-radius:0 0 14px 14px;padding:.4rem;max-height:72vh;overflow:auto;box-shadow:0 14px 30px rgba(0,0,0,.25);z-index:30}.side nav.open{display:flex}.side .bot{padding:.4rem 0}.content{padding:1rem}}
.side .burger{display:none;width:40px;height:40px;border-radius:12px;border:1px solid var(--line);background:var(--panel2);color:var(--txt);font-size:22px;align-items:center;justify-content:center;cursor:pointer}
</style></head>
<body>
<style>:root{--acc:#0ea5e9;--acc2:#6366f1;--bg:#f4f7fb;--panel:#ffffff;--panel2:#f1f5f9;--line:rgba(15,23,42,.08);--txt:#0f172a;--mut:#64748b;--r:20px}body{font-family:'Inter',ui-sans-serif,system-ui,-apple-system,'Segoe UI',sans-serif!important;color:#0f172a!important;background:radial-gradient(900px 600px at 8% -10%,rgba(14,165,233,.10),transparent 60%),radial-gradient(820px 520px at 102% 0%,rgba(99,102,241,.10),transparent 55%),radial-gradient(760px 760px at 50% 120%,rgba(16,185,129,.08),transparent 60%),#f4f7fb!important;background-attachment:fixed!important}.topbar{backdrop-filter:blur(16px) saturate(150%)!important;-webkit-backdrop-filter:blur(16px) saturate(150%)!important;background:rgba(255,255,255,.75)!important;border-bottom:1px solid rgba(15,23,42,.08)!important}.card{background:rgba(255,255,255,.85)!important;backdrop-filter:blur(16px) saturate(140%)!important;-webkit-backdrop-filter:blur(16px) saturate(140%)!important;border:1px solid rgba(15,23,42,.08)!important;border-radius:var(--r)!important;box-shadow:0 1px 2px rgba(15,23,42,.04),0 12px 30px -12px rgba(15,23,42,.12)!important;transition:transform .25s ease,box-shadow .25s ease!important}.card:hover{transform:translateY(-2px)!important;box-shadow:0 1px 2px rgba(15,23,42,.05),0 20px 40px -12px rgba(15,23,42,.18)!important}input,select,textarea{background:#fff!important;border:1px solid rgba(15,23,42,.12)!important;color:#0f172a!important;border-radius:12px!important}input:focus,select:focus,textarea:focus{border-color:var(--acc)!important;box-shadow:0 0 0 4px rgba(14,165,233,.15)!important}.btn{border-radius:12px!important;transition:.2s!important}.btn-pri{background:linear-gradient(135deg,var(--acc),var(--acc2))!important;color:#fff!important;box-shadow:0 6px 18px -6px rgba(14,165,233,.45)!important}.btn-pri:hover{filter:brightness(1.05)!important;transform:translateY(-1px)!important}.btn-sec{background:#fff!important;color:#0f172a!important;border:1px solid rgba(15,23,42,.12)!important}.btn-sec:hover{border-color:var(--acc)!important;background:#f8fafc!important}.btn-ok{color:#fff!important}.btn-del{color:#fff!important}.brand .logo,.login .logo,.side .brand .logo{box-shadow:0 8px 20px -6px rgba(14,165,233,.4)!important}.tabs button{border-radius:12px!important;border:1px solid rgba(15,23,42,.12)!important;color:#475569!important;background:#fff!important}.tabs button.active{background:linear-gradient(135deg,var(--acc),var(--acc2))!important;color:#fff!important;box-shadow:0 6px 16px -6px rgba(14,165,233,.4)!important;border-color:transparent!important}.side{background:rgba(255,255,255,.8)!important;backdrop-filter:blur(16px) saturate(140%)!important;-webkit-backdrop-filter:blur(16px) saturate(140%)!important;border-right:1px solid rgba(15,23,42,.08)!important}.side nav button{border-radius:12px!important;color:#475569!important}.side nav button:hover{background:#f1f5f9!important;color:#0f172a!important}.side nav button.active{background:linear-gradient(135deg,rgba(14,165,233,.15),rgba(99,102,241,.15))!important;color:#0369a1!important;border:1px solid rgba(14,165,233,.3)!important}.login .box{background:rgba(255,255,255,.92)!important;backdrop-filter:blur(20px) saturate(150%)!important;-webkit-backdrop-filter:blur(20px) saturate(150%)!important;border:1px solid rgba(15,23,42,.08)!important;box-shadow:0 24px 60px -20px rgba(15,23,42,.25)!important}.login h1{color:#0f172a!important}.login p{color:#64748b!important}tbody tr:hover{background:rgba(14,165,233,.06)!important}.pill{background:rgba(14,165,233,.12)!important;color:#0369a1!important;border:1px solid rgba(14,165,233,.25)!important}.dot{box-shadow:0 0 8px #10b981!important}pre{background:#f8fafc!important;border:1px solid rgba(15,23,42,.1)!important;color:#0f172a!important;border-radius:12px!important;padding:.8rem 1rem!important}.badge.ok{background:rgba(16,163,74,.15)!important;color:#15803d!important}.badge.err{background:rgba(220,38,38,.12)!important;color:#b91c1c!important}.toast{color:#0f172a!important}.toast.ok{background:rgba(16,163,74,.12)!important;border:1px solid rgba(16,163,74,.3)!important;color:#15803d!important}.toast.err{background:rgba(220,38,38,.1)!important;border:1px solid rgba(220,38,38,.3)!important;color:#b91c1c!important}.combo ul{background:#fff!important;border:1px solid rgba(15,23,42,.12)!important;box-shadow:0 12px 30px rgba(15,23,42,.12)!important}.combo li:hover{background:rgba(14,165,233,.1)!important}.pager button{background:#fff!important;border:1px solid rgba(15,23,42,.12)!important;color:#0f172a!important}.foot{color:#64748b!important}.foot a{color:var(--acc)!important}th{color:#64748b!important}.card h2{color:#0f172a!important}</style>
<div class="login" id="login">
  <div class="box">
    <div class="logo">🧭</div>
    <h1>Panel de administracion</h1><p>POCSAG · paginacion hospitalaria</p>
    <div style="margin-bottom:.8rem"><label>Usuario</label><input id="lu" autocomplete="off"></div>
    <div style="margin-bottom:1.2rem"><label>Clave</label><input id="lp" type="password" autocomplete="off"></div>
    <button class="btn btn-pri" style="width:100%;justify-content:center" onclick="doLogin()">Ingresar</button>
    <div id="lerr" class="toast err"></div>
  </div>
</div>
<div class="app" id="app" style="display:none">
  <div class="side">
    <div class="brand"><div class="logo">🧭</div><div>POCSAG <small style="display:block;color:var(--mut);font-weight:500;font-size:.7rem">admin</small></div></div>
    <button class="burger" onclick="toggleMenu()" aria-label="menu">☰</button>
    <nav>
      <button class="active" onclick="tab('pagers',this)">👤 Pagers</button>
      <button onclick="tab('enviar',this)">📨 Enviar</button>
      <button onclick="tab('grupos',this)">👥 Grupos</button>
      <button onclick="tab('import',this)">📥 Importar</button>
      <button onclick="tab('ext',this)">☎ Extensiones</button>
      <button onclick="tab('hist',this)">🕘 Historial</button>
      <button onclick="tab('dash',this)">📊 Dashboard</button>
      <button onclick="tab('plantillas',this)">📝 Plantillas</button>
      <button onclick="tab('programados',this)">📅 Programados</button>
      <button onclick="tab('logs',this)">📄 Logs</button>
      <button onclick="tab('aud',this)">🔍 Auditoria</button>
      <button onclick="tab('cfg',this)">⚙ Parametros</button>
      <button onclick="tab('diseno',this)">🎨 Diseno</button>
      <button onclick="tab('pbx',this)">🔀 PBX</button>

      <button onclick="tab('cola',this)">📋 Cola</button>
      <button onclick="tab('bd',this)">💾 Base de datos</button>
    </nav>
    <div class="bot"><span id="h" class="pill">…</span><br><button class="btn btn-sec btn-sm" style="margin-top:.6rem;width:100%;justify-content:center" onclick="logout()">Salir</button></div>
  </div>
  <div class="content">
    <div class="topbar"><h1 id="tit">Pagers</h1><span id="ver" class="badge mut" style="margin-left:auto">v1.03</span></div>
    <div class="tab" id="t-enviar"><div class="card"><h2>📨 Enviar mensaje</h2>
      <div class="field"><label>Buscar destinatario (nombre, codigo o area)</label>
      <div style="position:relative"><input id="s_q" autocomplete="off" placeholder="Escriba para buscar..."><ul id="s_list" style="position:absolute;z-index:6;left:0;right:0;margin-top:.2rem;background:var(--panel2);border:1px solid var(--line);border-radius:10px;max-height:280px;overflow:auto;list-style:none;padding:.3rem;display:none"></ul></div></div>
      <div class="field"><label>Mensaje (alfanumerico)</label><textarea id="s_msg" rows="3" placeholder="Mensaje para el pager..."></textarea></div>
      <button class="btn btn-pri" onclick="sendMsg()">Enviar mensaje</button><div id="s_res" class="toast"></div></div></div>
    <div class="tab active" id="t-pagers"><div class="card"><h2><span>👤 Pagers individuales</span><button class="btn btn-pri btn-sm" onclick="openPager()">+ Nuevo pager</button></h2>
      <div class="toolbar"><div class="search"><input id="pq" placeholder="Buscar por nombre, apellido, codigo o area..."></div></div>
      <div style="overflow-x:auto"><table><thead><tr><th>Codigo</th><th>CapCode</th><th>Nombre</th><th>Apellido</th><th>Area</th><th>Baud</th><th>Activo</th><th></th></tr></thead><tbody id="tb_pagers"></tbody></table></div></div></div>
    <div class="tab" id="t-grupos"><div class="card"><h2><span>👥 Grupos</span><button class="btn btn-pri btn-sm" onclick="openGrupo()">+ Nuevo grupo</button></h2>
      <div class="toolbar"><div class="search"><input id="gq" placeholder="Buscar grupo por codigo o nombre..."></div></div>
      <div style="overflow-x:auto"><table><thead><tr><th>Codigo</th><th>Nombre</th><th>CapCodes</th><th>Baud</th><th></th></tr></thead><tbody id="tb_grupos"></tbody></table></div></div></div>
    <div class="tab" id="t-import"><div class="card"><h2>📥 Importar codigos desde Excel</h2>
      <p style="color:var(--mut);font-size:.85rem">Suba un archivo <b>.xls</b>, <b>.xlsx</b> o <b>.csv</b> con columnas: codigo, cap_code, nombre, apellido, area, baudios, descripcion. Los codigos existentes se actualizan.</p>
      <div class="drop" id="drop"><input type="file" id="ifile" accept=".xls,.xlsx,.csv" style="display:none"><div id="dftxt">Arrastre el archivo aqui o haga click para seleccionar</div></div>
      <div style="margin-top:1rem;display:flex;gap:.6rem;flex-wrap:wrap"><button class="btn btn-pri" id="impbtn" onclick="doImport()" disabled>Importar</button><a class="btn btn-sec" href="data:text/csv;base64,Y29kaWdvLGNhcF9jb2RlLG5vbWJyZSxhcGVsbGlkbyxhcmVhLGJhdWRpb3MsZGVzY3JpcGNpb24KMTAsMDAwMjAyMCxKdWFuLFBlcmV6LEd1YXJkaWEgTWVkaWNhLDEyMDAsTWVkaWNvIGRlIGd1YXJkaWEK" download="plantilla_pagers.csv">Descargar plantilla</a></div>
      <div id="imp_res" class="toast"></div></div>
      <div class="card"><h2>📥 Importar grupos desde Excel</h2>
      <p style="color:var(--mut);font-size:.85rem">Suba un archivo <b>.xls</b>, <b>.xlsx</b> o <b>.csv</b> con columnas: codigo, nombre, baudios, cap_codes (capcodes separados por coma). Los grupos existentes se actualizan.</p>
      <div class="drop" id="dropG"><input type="file" id="ifileG" accept=".xls,.xlsx,.csv" style="display:none"><div id="dftxtG">Arrastre el archivo aqui o haga click para seleccionar</div></div>
      <div style="margin-top:1rem;display:flex;gap:.6rem;flex-wrap:wrap"><button class="btn btn-pri" id="impbtnG" onclick="doImportGrupos()" disabled>Importar grupos</button></div>
      <div id="impG_res" class="toast"></div></div></div>
    <div class="tab" id="t-ext"><div class="card"><h2><span>☎ Extensiones Asterisk</span><button class="btn btn-pri btn-sm" onclick="openExt()">+ Nueva extension</button></h2>
      <div style="display:flex;gap:.6rem;margin-bottom:.8rem"><button class="btn btn-warn btn-sm" onclick="aplicarExt()">Aplicar a Asterisk</button></div>
      <div style="overflow-x:auto"><table><thead><tr><th>Numero</th><th>Clave</th><th>Contexto</th><th>Descripcion</th><th>Activo</th><th></th></tr></thead><tbody id="tb_ext"></tbody></table></div></div></div>
    <div class="tab" id="t-hist"><div class="card"><h2>🕘 Historial de mensajes</h2>
      <div class="filters"><div><label>Desde</label><input id="h_desde" type="date"></div><div><label>Hasta</label><input id="h_hasta" type="date"></div>
      <div><label>Codigo</label><input id="h_codigo"></div><div><label>Interno</label><input id="h_interno"></div>
      <div><label>Estado</label><select id="h_estado"><option value="">Todos</option><option>enviado</option><option>error</option></select></div>
      <button class="btn btn-pri" onclick="loadHist(0)">Filtrar</button><button class="btn btn-ok" onclick="exportHist()">⬇ Excel</button></div>
      <div style="overflow-x:auto"><table><thead><tr><th>Fecha/Hora</th><th>Interno</th><th>Codigo</th><th>Cap</th><th>Mensaje</th><th>Baud</th><th>Estado</th><th>Obs</th></tr></thead><tbody id="tb_hist"></tbody></table></div>
      <div class="pager"><span id="hg_info">—</span><div><button id="hg_prev" onclick="hgGo(-1)">← Anterior</button> <button id="hg_next" onclick="hgGo(1)">Siguiente →</button></div></div></div></div>
    <div class="tab" id="t-cfg"><div class="card"><h2>⚙ Parametros del sistema</h2>
      <div class="row"><div><label>Usuario admin</label><input id="c_admin_user"></div><div><label>Clave admin</label><input id="c_admin_pass" type="text"></div></div>
      <div class="row"><div><label>Timeout mensaje (seg)</label><input id="c_mensaje_timeout" type="number" step="1"></div><div><label>PTT pre-activo (seg)</label><input id="c_ptt_preactivo" type="number" step="0.1"></div>
      <div><label>Timeout digitos (seg)</label><input id="c_digit_timeout" type="number" step="1"></div><div><label>Timeout respuesta (seg)</label><input id="c_response_timeout" type="number" step="1"></div>
      <div><label>Modo prueba (1=si 0=no)</label><input id="c_test_mode" type="number" min="0" max="1"></div></div>
      <button class="btn btn-pri" onclick="saveConfig()">Guardar parametros</button><div id="cfg_res" class="toast"></div>
      <div style="border-top:1px solid var(--line);margin-top:1rem;padding-top:1rem"><h3 style="font-size:.9rem;margin:0 0 .8rem">📧 Configuracion SMTP (para envio de backups por email)</h3>
      <div class="row"><div><label>Servidor SMTP</label><input id="c_smtp_host" placeholder="smtp.gmail.com"></div><div><label>Puerto</label><input id="c_smtp_port" type="number" value="587"></div></div>
      <div class="row"><div><label>Usuario SMTP</label><input id="c_smtp_user"></div><div><label>Clave SMTP</label><input id="c_smtp_pass" type="password"></div></div>
      <div class="row"><div><label>Remitente (email from)</label><input id="c_smtp_from"></div><div><label>Seguridad</label><select id="c_smtp_secure"><option value="tls">TLS</option><option value="ssl">SSL</option><option value="none">Ninguna</option></select></div></div>
      <div class="row"><div><label>Email para recibir backups</label><input id="c_backup_email"></div></div>
      <button class="btn btn-sec" onclick="smtpTest()">Probar SMTP</button>
      <div style="margin-top:1rem;border-top:1px solid var(--line);padding-top:.8rem">
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:.5rem">
          <b style="font-size:.85rem">📜 Log SMTP (diagnostico en tiempo real)</b>
          <div style="display:flex;gap:.4rem">
            <button class="btn btn-sec btn-sm" onclick="loadSmtpLog()">Actualizar</button>
            <button class="btn btn-sec btn-sm" onclick="clearSmtpLog()">Limpiar</button>
          </div>
        </div>
        <pre id="smtp_log" style="max-height:260px;font-size:.72rem;white-space:pre-wrap;background:var(--panel2);border:1px solid var(--line);border-radius:12px;padding:.8rem;overflow:auto">- sin registros todavia. Presiona "Probar SMTP" para generar actividad. -</pre>
      </div></div></div></div>
    <div class="tab" id="t-pbx"><div class="card"><h2>🔀 Gestion del PBX</h2>
      <div style="display:flex;gap:.5rem;flex-wrap:wrap;margin-bottom:.8rem"><button class="btn btn-sec btn-sm" onclick="pbx('status')">Estado</button><button class="btn btn-sec btn-sm" onclick="pbx('peers')">Endpoints</button><button class="btn btn-sec btn-sm" onclick="pbx('channels')">Canales</button><button class="btn btn-sec btn-sm" onclick="pbx('uptime')">Uptime</button><button class="btn btn-warn btn-sm" onclick="pbxReload()">Recargar config</button><button class="btn btn-del btn-sm" onclick="pbxRestart()">Reiniciar PBX</button></div>
      <pre id="pbx_out">—</pre></div></div>

    <div class="tab" id="t-cola"><div class="card"><h2><span>📋 Cola de envios</span><div style="display:flex;gap:.5rem"><button class="btn btn-warn btn-sm" onclick="colaReintentar()">Reintentar fallidos</button><button class="btn btn-sec btn-sm" onclick="colaLimpiar()">Limpiar enviados</button></div></h2>
      <div id="cola_stats" style="display:flex;gap:.6rem;flex-wrap:wrap;margin-bottom:1rem"></div>
      <div style="overflow-x:auto"><table><thead><tr><th>ID</th><th>Fecha encola</th><th>Codigo</th><th>Mensaje</th><th>Origen</th><th>Estado</th><th>Intentos</th><th>Obs</th></tr></thead><tbody id="tb_cola"></tbody></table></div></div></div>
    <div class="tab" id="t-bd"><div class="card"><h2>💾 Base de datos</h2>
      <p style="color:var(--mut);font-size:.85rem;margin-top:0">Realice un backup de la base de datos o restaure desde un archivo anterior.</p>
      <div style="display:flex;gap:.6rem;flex-wrap:wrap;margin-bottom:1rem"><button class="btn btn-pri" onclick="dbBackup()">⬇ Descargar backup</button><button class="btn btn-ok" onclick="dbBackupEmail()">📧 Enviar backup por mail</button></div>
      <div class="drop" id="dropDB"><input type="file" id="ifileDB" accept=".db" style="display:none"><div id="dftxtDB">Arrastre un archivo .db o haga click para restaurar</div></div>
      <div style="margin-top:1rem"><button class="btn btn-del" id="impbtnDB" onclick="dbRestore()" disabled>Restaurar desde archivo</button></div>
      <div id="db_res" class="toast"></div></div>
      <div class="card"><h2>🗓 Programar backup automatico</h2>
      <div class="row"><div><label>Frecuencia</label><select id="c_backup_frecuencia"><option value="diario">Diario</option><option value="semanal">Semanal</option><option value="mensual">Mensual</option></select></div><div><label>Hora</label><input id="c_backup_hora" type="time" value="03:00"></div><div><label>Dia (sem 0=Dom-6 / mens 1-31)</label><input id="c_backup_dia" type="number" min="0" max="31" value="1"></div></div>
      <label style="display:flex;align-items:center;gap:.4rem;margin:.6rem 0"><input type="checkbox" id="c_backup_email_enable" style="width:auto"> Enviar tambien por email (a la direccion de Parametros)</label>
      <button class="btn btn-pri" onclick="addBackupSched()">+ Agregar programacion</button>
      <h3 style="font-size:.9rem;margin:1rem 0 .5rem">Programaciones activas</h3><div id="bk_list" style="display:flex;flex-direction:column;gap:.4rem"></div>
      <div id="bk_res" class="toast"></div></div></div>
    <div class="tab" id="t-dash"><div class="card"><h2>📊 Estadisticas del sistema</h2>
      <div id="dash_stats" style="display:flex;gap:.8rem;flex-wrap:wrap;margin-bottom:1.2rem"></div>
      <div class="card" style="background:var(--panel2);margin-bottom:1rem"><h3 style="font-size:.9rem;margin:0 0 .6rem">Mensajes por dia (ultimos 30 dias)</h3><canvas id="chart_dia" height="120"></canvas></div>
      <div class="card" style="background:var(--panel2);margin-bottom:1rem"><h3 style="font-size:.9rem;margin:0 0 .6rem">Mensajes por hora (hoy)</h3><canvas id="chart_hora" height="120"></canvas></div>
      <div class="card" style="background:var(--panel2)"><h3 style="font-size:.9rem;margin:0 0 .6rem">Pagers mas activos</h3><div id="dash_top"></div></div>
      <button class="btn btn-sec btn-sm" onclick="loadDash()" style="margin-top:1rem">🔄 Actualizar</button></div></div>
    <div class="tab" id="t-plantillas"><div class="card"><h2><span>📝 Plantillas de mensajes</span><button class="btn btn-pri btn-sm" onclick="openPlantilla()">+ Nueva plantilla</button></h2>
      <div style="overflow-x:auto"><table><thead><tr><th>Nombre</th><th>Categoria</th><th>Mensaje</th><th>Orden</th><th>Activo</th><th></th></tr></thead><tbody id="tb_plantillas"></tbody></table></div></div></div>
    <div class="tab" id="t-programados"><div class="card"><h2><span>📅 Envios programados</span><button class="btn btn-pri btn-sm" onclick="openProgramado()">+ Nuevo envio</button></h2>
      <div style="overflow-x:auto"><table><thead><tr><th>Codigo</th><th>Mensaje</th><th>Tipo</th><th>Fecha/Proxima</th><th>Activo</th><th></th></tr></thead><tbody id="tb_programados"></tbody></table></div></div></div>
    <div class="tab" id="t-logs"><div class="card"><h2>📄 Visor de logs</h2>
      <div style="display:flex;gap:.5rem;flex-wrap:wrap;margin-bottom:1rem">
        <button class="btn btn-sec btn-sm" onclick="loadLogs('api')">API</button>
        <button class="btn btn-sec btn-sm" onclick="loadLogs('asterisk')">Asterisk</button>
        <button class="btn btn-sec btn-sm" onclick="loadLogs('cola')">Cola</button>
        <button class="btn btn-sec btn-sm" onclick="loadLogs('scheduler')">Scheduler</button>
        <button class="btn btn-sec btn-sm" onclick="loadLogs('backup')">Backup</button>
        <button class="btn btn-sec btn-sm" onclick="loadLogs('health')">Health</button>
        <button class="btn btn-sec btn-sm" onclick="loadLogs('install')">Instalador</button>
        <button class="btn btn-ok btn-sm" onclick="loadLogs(curLogType)">🔄 Recargar</button>
      </div>
      <pre id="log_out" style="max-height:500px">Seleccione un log para ver.</pre></div></div>
    <div class="tab" id="t-aud"><div class="card"><h2>🔍 Auditoria de cambios</h2>
      <div style="overflow-x:auto"><table><thead><tr><th>Fecha/Hora</th><th>Usuario</th><th>Accion</th><th>Entidad</th><th>ID</th><th>Detalle</th><th>IP</th></tr></thead><tbody id="tb_aud"></tbody></table></div>
      <button class="btn btn-sec btn-sm" onclick="loadAud()" style="margin-top:1rem">🔄 Actualizar</button></div></div>
    <div class="tab" id="t-diseno"><div class="card"><h2>ℹ️ Version del sistema</h2><div id="changelog" style="font-size:.84rem;line-height:1.6;color:var(--mut)"></div></div><div class="card"><h2>🎨 Diseno del panel</h2>
      <p style="color:var(--mut);font-size:.85rem;margin-top:0">Personaliza colores y tipografias. Se aplica al panel publico y al admin.</p>
      <div class="row"><div><label>Color primario</label><input id="th_acc" type="color" value="#0ea5e9"></div><div><label>Color secundario</label><input id="th_acc2" type="color" value="#6366f1"></div><div><label>Fondo</label><input id="th_bg" type="color" value="#f4f7fb"></div><div><label>Panel</label><input id="th_panel" type="color" value="#ffffff"></div></div>
      <div class="row"><div><label>Fuente titulos</label><select id="th_fh"><option>Space Grotesk</option><option>Inter</option><option>Georgia</option><option>system-ui</option><option>monospace</option></select></div><div><label>Fuente cuerpo</label><select id="th_fb"><option>Inter</option><option>Space Grotesk</option><option>Georgia</option><option>system-ui</option><option>monospace</option></select></div></div>
      <div style="display:flex;gap:.5rem;margin-top:1rem"><button class="btn btn-pri" onclick="saveTheme()">Guardar diseno</button><button class="btn btn-sec" onclick="resetTheme()">Restablecer</button></div><div id="th_res" class="toast"></div></div></div>
  </div>
</div>
<div class="modal" id="mPager"><div class="card"><h2 id="mPT">Pager</h2>
  <div class="row"><div><label>Codigo (DTMF)</label><input id="p_codigo"></div><div><label>CapCode</label><input id="p_cap"></div></div>
  <div class="row"><div><label>Nombre</label><input id="p_nombre"></div><div><label>Apellido</label><input id="p_apellido"></div></div>
  <div class="row"><div><label>Area</label><input id="p_area"></div><div><label>Baudios</label><input id="p_baud" type="number" value="1200"></div></div>
  <label>Descripcion</label><input id="p_desc">
  <div style="display:flex;gap:.5rem;margin-top:.9rem"><button class="btn btn-pri" onclick="savePager()">Guardar</button><button class="btn btn-sec" onclick="closeModal('mPager')">Cancelar</button></div></div></div>
<div class="modal" id="mGrupo"><div class="card"><h2 id="mGT">Grupo</h2>
  <div class="row"><div><label>Codigo (DTMF)</label><input id="g_codigo"></div><div><label>Baudios</label><input id="g_baud" type="number" value="1200"></div></div>
  <label>Nombre</label><input id="g_nombre">
  <label>CapCodes (uno por linea, max 20)</label><textarea id="g_miembros" rows="6"></textarea>
  <div style="display:flex;gap:.5rem;margin-top:.9rem"><button class="btn btn-pri" onclick="saveGrupo()">Guardar</button><button class="btn btn-sec" onclick="closeModal('mGrupo')">Cancelar</button></div></div></div>
<div class="modal" id="mExt"><div class="card"><h2 id="mET">Extension</h2>
  <div class="row"><div><label>Numero</label><input id="x_numero"></div><div><label>Clave</label><input id="x_pass"></div></div>
  <label>Contexto</label><input id="x_ctx" value="pocsag-incoming">
  <label>Descripcion</label><input id="x_desc">
  <div style="display:flex;gap:.5rem;margin-top:.9rem"><button class="btn btn-pri" onclick="saveExt()">Guardar</button><button class="btn btn-sec" onclick="closeModal('mExt')">Cancelar</button></div></div></div>
<div class="modal" id="mPlantilla"><div class="card"><h2 id="mPLT">Plantilla</h2>
  <div class="row"><div><label>Nombre</label><input id="pl_nombre"></div><div><label>Categoria</label><input id="pl_cat" value="general"></div></div>
  <label>Mensaje</label><textarea id="pl_mensaje" rows="3"></textarea>
  <div class="row"><div><label>Orden</label><input id="pl_orden" type="number" value="0"></div></div>
  <div style="display:flex;gap:.5rem;margin-top:.9rem"><button class="btn btn-pri" onclick="savePlantilla()">Guardar</button><button class="btn btn-sec" onclick="closeModal('mPlantilla')">Cancelar</button></div></div></div>
<div class="modal" id="mProgramado"><div class="card"><h2 id="mPRT">Envio programado</h2>
  <div class="row"><div><label>Codigo</label><input id="pr_codigo"></div><div><label>Tipo</label><select id="pr_tipo"><option value="unico">Unico</option><option value="diario">Diario</option><option value="semanal">Semanal</option><option value="mensual">Mensual</option></select></div></div>
  <label>Mensaje</label><textarea id="pr_mensaje" rows="3"></textarea>
  <div class="row"><div><label>Fecha programada (unico)</label><input id="pr_fecha" type="datetime-local"></div><div><label>Hora recurrente (HH:MM)</label><input id="pr_hora" type="time" value="08:00"></div></div>
  <div class="row"><div><label>Dia (mensual 1-31)</label><input id="pr_dia" type="number" min="1" max="31" value="1"></div></div>
  <div style="display:flex;gap:.5rem;margin-top:.9rem"><button class="btn btn-pri" onclick="saveProgramado()">Guardar</button><button class="btn btn-sec" onclick="closeModal('mProgramado')">Cancelar</button></div></div></div>
<script>
let TOKEN=localStorage.getItem('pocsag_tok')||'';
let editP=null,editG=null,editX=null,editPL=null,editPR=null; const HPG=50; let hoff=0,htot=0;
function api(m,u,b,raw){const o={method:m,headers:{'Authorization':'Bearer '+TOKEN}};if(b!==undefined){if(raw){o.body=b;}else{o.headers['Content-Type']='application/json';o.body=JSON.stringify(b);}}return fetch(u,o).then(async r=>{if(r.status===401){logout(true);throw new Error('no autorizado');}const txt=await r.text();try{return JSON.parse(txt);}catch(e){return txt;}});}
let histTimer=null;function tab(id,el){document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));document.querySelectorAll('.side nav button').forEach(b=>b.classList.remove('active'));document.getElementById('t-'+id).classList.add('active');el.classList.add('active');const t={enviar:'Enviar mensaje',pagers:'Pagers',grupos:'Grupos',import:'Importar codigos',ext:'Extensiones',hist:'Historial',cfg:'Parametros',pbx:'PBX',cola:'Cola de envios',bd:'Base de datos',dash:'Dashboard',plantillas:'Plantillas',programados:'Envios programados',logs:'Logs del servidor',aud:'Auditoria',diseno:'Diseno del panel'};document.getElementById('tit').textContent=t[id]||'';if(histTimer){clearInterval(histTimer);histTimer=null;}if(id==='pagers')loadPagers();if(id==='grupos')loadGrupos();if(id==='ext')loadExt();if(id==='cfg'){loadConfig();loadSmtpLog();}if(id==='hist'){loadHist(0);histTimer=setInterval(()=>loadHist(hoff),8000);}if(id==='pbx')pbx('status');if(id==='cola'){loadCola();histTimer=setInterval(loadCola,4000);}if(id==='bd')loadBD();if(id==='enviar')initSend();if(id==='dash')loadDash();if(id==='plantillas')loadPlantillas();if(id==='programados')loadProgramados();if(id==='logs')loadLogs('api');if(id==='aud')loadAud();if(id==='diseno'){loadTheme();loadChangelog();}}
function openModal(id){document.getElementById(id).classList.add('open');}
function closeModal(id){document.getElementById(id).classList.remove('open');}
async function doLogin(){const u=document.getElementById('lu').value,p=document.getElementById('lp').value;document.getElementById('lerr').className='toast err';document.getElementById('lerr').textContent='';try{const r=await fetch('/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({user:u,pass:p})}).then(r=>r.json());if(r.token){TOKEN=r.token;localStorage.setItem('pocsag_tok',TOKEN);showApp();}else{document.getElementById('lerr').classList.add('show');document.getElementById('lerr').textContent=r.error||'error';}}catch(e){document.getElementById('lerr').classList.add('show');document.getElementById('lerr').textContent='error de conexion';}}
document.getElementById('lp').addEventListener('keydown',e=>{if(e.key==='Enter')doLogin();});
function logout(silent){TOKEN='';localStorage.removeItem('pocsag_tok');document.getElementById('app').style.display='none';document.getElementById('login').style.display='grid';if(!silent)document.getElementById('lp').value='';}
function toggleMenu(){const n=document.querySelector('.side nav');if(n)n.classList.toggle('open');}
document.addEventListener('click',e=>{const n=document.querySelector('.side nav'),b=document.querySelector('.side .burger');if(!n)return;if(b&&!b.contains(e.target)&&!n.contains(e.target))n.classList.remove('open');if(n.contains(e.target)&&e.target.closest('button'))n.classList.remove('open');});
function showApp(){document.getElementById('login').style.display='none';document.getElementById('app').style.display='flex';tab('pagers',document.querySelector('.side nav button'));}
async function checkTok(){if(!TOKEN){return;}try{await api('GET','/api/extensions');showApp();}catch(e){}}
// Enviar mensaje
let sChosen=null,sTimer=null,sInit=false;
function initSend(){if(sInit)return;sInit=true;const sq=document.getElementById('s_q');sq.addEventListener('input',()=>{clearTimeout(sTimer);sTimer=setTimeout(async()=>{const r=await buscarDestAdmin(sq.value.trim());renderSList(r);},180);});sq.addEventListener('focus',()=>{if(document.getElementById('s_list').innerHTML)document.getElementById('s_list').style.display='block';});}
async function buscarDestAdmin(q){const [pe,gr]=await Promise.all([api('GET','/api/pagers'+(q?('?q='+encodeURIComponent(q)):'')),api('GET','/api/grupos'+(q?('?q='+encodeURIComponent(q)):''))]);const out=[];(pe||[]).filter(x=>x.activo).forEach(x=>out.push({codigo:x.codigo,label:`${x.nombre||''} ${x.apellido||''}`.trim()||x.codigo,tipo:'pager'}));(gr||[]).filter(x=>x.activo).forEach(x=>out.push({codigo:x.codigo,label:x.nombre||x.codigo,tipo:'grupo'}));return out;}
function renderSList(r){const ul=document.getElementById('s_list');ul.innerHTML=r.map(x=>`<li onclick="pickS('${x.codigo}','${(x.label||'').replace(/'/g,'')}')" style="padding:.5rem .6rem;border-radius:7px;cursor:pointer;display:flex;justify-content:space-between"><span>${x.label} <span style="color:var(--mut);font-size:.8rem">${x.codigo}</span></span><span style="font-size:.7rem;color:var(--acc);font-weight:700">${x.tipo}</span></li>`).join('');ul.style.display=r.length?'block':'none';}
function pickS(codigo,label){sChosen=codigo;document.getElementById('s_q').value=label+' ('+codigo+')';document.getElementById('s_list').style.display='none';}
document.addEventListener('click',e=>{const c=document.getElementById('s_q');if(c&&!c.contains(e.target)){const ul=document.getElementById('s_list');if(ul)ul.style.display='none';}});
async function sendMsg(){const t=document.getElementById('s_res');if(!sChosen){t.className='toast show err';t.textContent='Seleccione un destinatario.';return;}const msg=document.getElementById('s_msg').value.trim();if(!msg){t.className='toast show err';t.textContent='Escriba un mensaje.';return;}t.className='toast show ok';t.textContent='Enviando...';const r=await api('POST','/api/enviar',{codigo:sChosen,mensaje:msg,origen:'admin'});if(r.status==='enviado'||r.status==='encolado'){t.className='toast show ok';t.textContent=r.status==='encolado'?'Mensaje encolado para envio.':'Mensaje enviado correctamente.';document.getElementById('s_msg').value='';}else{t.className='toast show err';t.textContent='Error: '+(r.detalle||'no se pudo enviar');}}
// Pagers
async function loadPagers(){const q=document.getElementById('pq').value.trim();document.getElementById('tb_pagers').innerHTML='<tr><td colspan="8" style="color:var(--mut);text-align:center;padding:1rem">Cargando...</td></tr>';const r=await api('GET','/api/pagers'+(q?('?q='+encodeURIComponent(q)):''));document.getElementById('tb_pagers').innerHTML=(r||[]).map(x=>`<tr><td>${x.codigo}</td><td>${x.cap_code}</td><td>${x.nombre||''}</td><td>${x.apellido||''}</td><td>${x.area||''}</td><td>${x.baudios}</td><td><button class="sw ${x.activo?'on':''}" onclick="toggleP(${x.id},${x.activo?0:1})"></button></td><td><button class="btn btn-sec btn-sm" onclick="openPager(${x.id})">✎</button> <button class="btn btn-del btn-sm" onclick="delP(${x.id})">✕</button></td></tr>`).join('')||`<tr><td colspan="8" style="color:var(--mut);text-align:center;padding:1rem">Sin resultados</td></tr>`;}
document.getElementById('pq').addEventListener('input',()=>{clearTimeout(window._pt);window._pt=setTimeout(loadPagers,200);});
async function toggleP(id,act){await api('PUT','/api/pagers/'+id+'/estado',{activo:act});loadPagers();}
async function openPager(id){editP=id||null;let x=null;if(id){const r=await api('GET','/api/pagers');x=(r||[]).find(i=>i.id===id);}['codigo','cap','nombre','apellido','area','desc'].forEach(f=>document.getElementById('p_'+f).value=x?x[f==='cap'?'cap_code':f]||'':'');document.getElementById('p_baud').value=x?x.baudios:1200;document.getElementById('mPT').textContent=id?'Editar pager':'Nuevo pager';openModal('mPager');}
async function savePager(){const d={codigo:document.getElementById('p_codigo').value,cap_code:document.getElementById('p_cap').value,nombre:document.getElementById('p_nombre').value,apellido:document.getElementById('p_apellido').value,area:document.getElementById('p_area').value,baudios:+document.getElementById('p_baud').value,descripcion:document.getElementById('p_desc').value,activo:1};if(editP)await api('PUT','/api/pagers/'+editP,d);else await api('POST','/api/pagers',d);closeModal('mPager');loadPagers();}
async function delP(id){if(confirm('Eliminar pager?')){await api('DELETE','/api/pagers/'+id);loadPagers();}}
// Grupos
async function loadGrupos(){const q=document.getElementById('gq').value.trim();const r=await api('GET','/api/grupos'+(q?('?q='+encodeURIComponent(q)):''));document.getElementById('tb_grupos').innerHTML=(r||[]).map(x=>`<tr><td>${x.codigo}</td><td>${x.nombre||''}</td><td>${(x.miembros||[]).join(', ')}</td><td>${x.baudios}</td><td><button class="btn btn-sec btn-sm" onclick="openGrupo(${x.id})">✎</button> <button class="btn btn-del btn-sm" onclick="delG(${x.id})">✕</button></td></tr>`).join('')||`<tr><td colspan="5" style="color:var(--mut);text-align:center;padding:1rem">Sin resultados</td></tr>`;}
document.getElementById('gq').addEventListener('input',()=>{clearTimeout(window._gt);window._gt=setTimeout(loadGrupos,200);});
async function openGrupo(id){editG=id||null;let x=null;if(id){const r=await api('GET','/api/grupos');x=(r||[]).find(i=>i.id===id);}document.getElementById('g_codigo').value=x?x.codigo:'';document.getElementById('g_nombre').value=x?x.nombre||'':'';document.getElementById('g_miembros').value=x?(x.miembros||[]).join('\n'):'';document.getElementById('g_baud').value=x?x.baudios:1200;document.getElementById('mGT').textContent=id?'Editar grupo':'Nuevo grupo';openModal('mGrupo');}
async function saveGrupo(){const d={codigo:document.getElementById('g_codigo').value,nombre:document.getElementById('g_nombre').value,baudios:+document.getElementById('g_baud').value,miembros:document.getElementById('g_miembros').value.split('\n').map(s=>s.trim()).filter(Boolean).slice(0,20)};if(editG)await api('PUT','/api/grupos/'+editG,d);else await api('POST','/api/grupos',d);closeModal('mGrupo');loadGrupos();}
async function delG(id){if(confirm('Eliminar grupo?')){await api('DELETE','/api/grupos/'+id);loadGrupos();}}
// Import
let impFile=null;const drop=document.getElementById('drop'),ifile=document.getElementById('ifile'),dftxt=document.getElementById('dftxt');
drop.addEventListener('click',()=>ifile.click());
ifile.addEventListener('change',e=>{impFile=e.target.files[0];dftxt.textContent=impFile.name;document.getElementById('impbtn').disabled=false;});
['dragover','dragenter'].forEach(ev=>drop.addEventListener(ev,e=>{e.preventDefault();drop.classList.add('hover');}));
['dragleave','drop'].forEach(ev=>drop.addEventListener(ev,e=>{e.preventDefault();drop.classList.remove('hover');}));
drop.addEventListener('drop',e=>{impFile=e.dataTransfer.files[0];dftxt.textContent=impFile.name;document.getElementById('impbtn').disabled=false;});
async function doImport(){if(!impFile)return;const buf=await impFile.arrayBuffer();const r=await fetch('/api/pagers/import',{method:'POST',headers:{'Authorization':'Bearer '+TOKEN,'X-Filename':encodeURIComponent(impFile.name)},body:buf}).then(async r=>{if(r.status===401){logout(true);throw new Error('no autorizado');}const txt=await r.text();try{return JSON.parse(txt);}catch(e){return txt;}});const t=document.getElementById('imp_res');t.className='toast show '+(r.error?'err':'ok');t.textContent=r.error?('Error: '+r.error):`Importados: ${r.importados} · Errores: ${r.errores}`;if(!r.error){loadPagers();}}
let impGFile=null;const dropG=document.getElementById('dropG'),ifileG=document.getElementById('ifileG'),dftxtG=document.getElementById('dftxtG');
dropG.addEventListener('click',()=>ifileG.click());
ifileG.addEventListener('change',e=>{impGFile=e.target.files[0];dftxtG.textContent=impGFile.name;document.getElementById('impbtnG').disabled=false;});
['dragover','dragenter'].forEach(ev=>dropG.addEventListener(ev,e=>{e.preventDefault();dropG.classList.add('hover');}));
['dragleave','drop'].forEach(ev=>dropG.addEventListener(ev,e=>{e.preventDefault();dropG.classList.remove('hover');}));
dropG.addEventListener('drop',e=>{impGFile=e.dataTransfer.files[0];dftxtG.textContent=impGFile.name;document.getElementById('impbtnG').disabled=false;});
async function doImportGrupos(){if(!impGFile)return;const buf=await impGFile.arrayBuffer();const r=await fetch('/api/grupos/import',{method:'POST',headers:{'Authorization':'Bearer '+TOKEN,'X-Filename':encodeURIComponent(impGFile.name)},body:buf}).then(async r=>{if(r.status===401){logout(true);throw new Error('no autorizado');}const txt=await r.text();try{return JSON.parse(txt);}catch(e){return txt;}});const t=document.getElementById('impG_res');t.className='toast show '+(r.error?'err':'ok');t.textContent=r.error?('Error: '+r.error):`Importados: ${r.importados} · Errores: ${r.errores}`;if(!r.error)loadGrupos();}
// Extensiones
async function loadExt(){const r=await api('GET','/api/extensions');document.getElementById('tb_ext').innerHTML=(r||[]).map(x=>`<tr><td>${x.numero}</td><td>${'*'.repeat((x.password||'').length||4)}</td><td>${x.contexto||''}</td><td>${x.descripcion||''}</td><td><button class="sw ${x.activo?'on':''}" onclick="toggleX(${x.id},${x.activo?0:1})"></button></td><td><button class="btn btn-sec btn-sm" onclick="openExt(${x.id})">✎</button> <button class="btn btn-del btn-sm" onclick="delX(${x.id})">✕</button></td></tr>`).join('')||`<tr><td colspan="6" style="color:var(--mut);text-align:center;padding:1rem">Sin extensiones</td></tr>`;}
async function toggleX(id,act){const r=await api('GET','/api/extensions');const x=(r||[]).find(i=>i.id===id);if(x)await api('PUT','/api/extensiones/'+id,{...x,activo:act});loadExt();}
async function openExt(id){editX=id||null;let x=null;if(id){const r=await api('GET','/api/extensions');x=(r||[]).find(i=>i.id===id);}document.getElementById('x_numero').value=x?x.numero:'';document.getElementById('x_pass').value=x?x.password||'':'';document.getElementById('x_ctx').value=x?x.contexto||'pocsag-incoming':'pocsag-incoming';document.getElementById('x_desc').value=x?x.descripcion||'':'';document.getElementById('mET').textContent=id?'Editar extension':'Nueva extension';openModal('mExt');}
async function saveExt(){const d={numero:document.getElementById('x_numero').value,password:document.getElementById('x_pass').value,contexto:document.getElementById('x_ctx').value,descripcion:document.getElementById('x_desc').value,activo:1};if(editX)await api('PUT','/api/extensiones/'+editX,d);else await api('POST','/api/extensions',d);closeModal('mExt');loadExt();}
async function delX(id){if(confirm('Eliminar extension?')){await api('DELETE','/api/extensiones/'+id);loadExt();}}
async function aplicarExt(){const r=await api('POST','/api/extensions/aplicar');alert(r.salida||r.error||'ok');}
// Historial
function hQuery(){const p=new URLSearchParams();p.set('limit',HPG);p.set('offset',hoff);const d=document.getElementById('h_desde').value,h=document.getElementById('h_hasta').value,c=document.getElementById('h_codigo').value,i=document.getElementById('h_interno').value,e=document.getElementById('h_estado').value;if(d)p.set('fecha_desde',d);if(h)p.set('fecha_hasta',h+'T23:59:59');if(c)p.set('codigo',c);if(i)p.set('interno',i);if(e)p.set('estado',e);return p;}
const badge=e=>`<span class="badge ${e==='enviado'?'ok':'err'}">${e||'-'}</span>`;
async function loadHist(off){hoff=off||0;document.getElementById('tb_hist').innerHTML='<tr><td colspan="8" style="color:var(--mut);text-align:center;padding:1rem">Cargando...</td></tr>';try{const r=await fetch('/api/historial?'+hQuery()).then(r=>r.json());htot=r.total||0;const rows=r.rows||[];document.getElementById('tb_hist').innerHTML=rows.length?rows.map(x=>`<tr><td>${x.fecha_hora}</td><td>${x.interno_origen||''}</td><td>${x.codigo}</td><td>${x.cap_code||''}</td><td>${x.mensaje||''}</td><td>${x.baudios||''}</td><td>${badge(x.estado)}</td><td>${x.observaciones||''}</td></tr>`).join(''):`<tr><td colspan="8" style="color:var(--mut);text-align:center;padding:1rem">Sin registros</td></tr>`;document.getElementById('hg_info').textContent=`${rows.length?hoff+1:0}-${hoff+rows.length} de ${htot}`;document.getElementById('hg_prev').disabled=hoff<=0;document.getElementById('hg_next').disabled=hoff+HPG>=htot;}catch(e){document.getElementById('tb_hist').innerHTML=`<tr><td colspan="8" style="color:var(--err);text-align:center;padding:1rem">Error: ${e.message}</td></tr>`;}}
function hgGo(d){loadHist(Math.max(0,hoff+d*HPG));}
function exportHist(){const p=new URLSearchParams();const d=document.getElementById('h_desde').value,h=document.getElementById('h_hasta').value,c=document.getElementById('h_codigo').value,i=document.getElementById('h_interno').value,e=document.getElementById('h_estado').value;if(d)p.set('fecha_desde',d);if(h)p.set('fecha_hasta',h+'T23:59:59');if(c)p.set('codigo',c);if(i)p.set('interno',i);if(e)p.set('estado',e);window.open('/api/historial/export?'+p,'_blank');}
// Config
async function loadConfig(){const c=await api('GET','/api/config');['admin_user','admin_pass','mensaje_timeout','ptt_preactivo','digit_timeout','response_timeout','test_mode','smtp_host','smtp_port','smtp_user','smtp_pass','smtp_from','smtp_secure','backup_email'].forEach(k=>{const el=document.getElementById('c_'+k);if(el&&c[k]!=null)el.value=c[k];});}
async function saveConfig(){const d={admin_user:document.getElementById('c_admin_user').value,admin_pass:document.getElementById('c_admin_pass').value,mensaje_timeout:document.getElementById('c_mensaje_timeout').value,ptt_preactivo:document.getElementById('c_ptt_preactivo').value,digit_timeout:document.getElementById('c_digit_timeout').value,response_timeout:document.getElementById('c_response_timeout').value,test_mode:document.getElementById('c_test_mode').value,smtp_host:document.getElementById('c_smtp_host').value,smtp_port:document.getElementById('c_smtp_port').value,smtp_user:document.getElementById('c_smtp_user').value,smtp_pass:document.getElementById('c_smtp_pass').value,smtp_from:document.getElementById('c_smtp_from').value,smtp_secure:document.getElementById('c_smtp_secure').value,backup_email:document.getElementById('c_backup_email').value};await api('PUT','/api/config',d);const t=document.getElementById('cfg_res');t.className='toast show ok';t.textContent='Parametros guardados';setTimeout(()=>t.className='toast',2500);}
// Apariencia
async function loadTheme(){const c=await api('GET','/api/config');['acc','acc2','bg','panel'].forEach(k=>{const el=document.getElementById('th_'+k);if(el&&c['theme_'+k])el.value=c['theme_'+k];});const fh=c.theme_font_heading||'Space Grotesk',fb=c.theme_font_body||'Inter';if(document.getElementById('th_fh'))document.getElementById('th_fh').value=fh;if(document.getElementById('th_fb'))document.getElementById('th_fb').value=fb;}
async function saveTheme(){const d={theme_acc:document.getElementById('th_acc').value,theme_acc2:document.getElementById('th_acc2').value,theme_bg:document.getElementById('th_bg').value,theme_panel:document.getElementById('th_panel').value,theme_font_heading:document.getElementById('th_fh').value,theme_font_body:document.getElementById('th_fb').value};await api('PUT','/api/config',d);applyTheme();const t=document.getElementById('th_res');t.className='toast show ok';t.textContent='Diseno guardado';setTimeout(()=>t.className='toast',2500);}
async function resetTheme(){await api('PUT','/api/config',{theme_acc:'#0ea5e9',theme_acc2:'#6366f1',theme_bg:'#f4f7fb',theme_panel:'#ffffff',theme_font_heading:'Space Grotesk',theme_font_body:'Inter'});loadTheme();applyTheme();const t=document.getElementById('th_res');t.className='toast show ok';t.textContent='Valores restablecidos';setTimeout(()=>t.className='toast',2500);}
// Cola
async function loadCola(){try{const stats=await api('GET','/api/cola/estado');const items=await api('GET','/api/cola');const sd=document.getElementById('cola_stats');sd.innerHTML=Object.entries(stats||{}).map(([k,v])=>`<span class="badge ${k==='pendiente'?'mut':k==='enviado'?'ok':(k==='error'||k==='fallido')?'err':'mut'}">${k}: ${v}</span>`).join('')||'<span class="badge mut">cola vacia</span>';const rows=items||[];document.getElementById('tb_cola').innerHTML=rows.length?rows.map(x=>`<tr><td>${x.id}</td><td>${x.fecha_encola}</td><td>${x.codigo}</td><td>${(x.mensaje||'').slice(0,40)}</td><td>${x.origen||''}</td><td><span class="badge ${x.estado==='enviado'?'ok':(x.estado==='error'||x.estado==='fallido')?'err':'mut'}">${x.estado}</span></td><td>${x.intentos||0}</td><td>${(x.observaciones||'').slice(0,30)}</td></tr>`).join(''):`<tr><td colspan="8" style="color:var(--mut);text-align:center;padding:1rem">Cola vacia</td></tr>`;}catch(e){}}
async function colaReintentar(){if(!confirm('Reintentar todos los mensajes fallidos?'))return;for(const est of ['fallido','error']){const items=await api('GET','/api/cola?estado='+est);for(const item of (items||[])){await api('POST','/api/cola/reintentar',{id:item.id});}}loadCola();}
async function colaLimpiar(){if(!confirm('Eliminar todos los mensajes ya enviados de la cola?'))return;await api('POST','/api/cola/limpiar');loadCola();}
// Base de datos
async function dbBackup(){const r=await fetch('/api/db/backup',{headers:{'Authorization':'Bearer '+TOKEN}});if(r.status===401){logout(true);throw new Error('no autorizado');}const blob=await r.blob();const cd=r.headers.get('Content-Disposition')||'';const m=cd.match(/filename="?([^"]+)"?/);const name=m?m[1]:'pocsag_backup.db';const u=URL.createObjectURL(blob);const a=document.createElement('a');a.href=u;a.download=name;document.body.appendChild(a);a.click();a.remove();URL.revokeObjectURL(u);}
async function dbBackupEmail(){const t=document.getElementById('db_res');t.className='toast show ok';t.textContent='Enviando backup por email...';const r=await api('POST','/api/db/backup-email',{});if(r.ok){t.className='toast show ok';t.textContent='Backup enviado por email.';}else{t.className='toast show err';t.textContent='Error: '+(r.error||'no se pudo enviar');}setTimeout(()=>t.className='toast',4000);}
let dbFile=null;const dropDB=document.getElementById('dropDB'),ifileDB=document.getElementById('ifileDB'),dftxtDB=document.getElementById('dftxtDB');
if(dropDB){dropDB.addEventListener('click',()=>ifileDB.click());ifileDB.addEventListener('change',e=>{dbFile=e.target.files[0];dftxtDB.textContent=dbFile.name;document.getElementById('impbtnDB').disabled=false;});['dragover','dragenter'].forEach(ev=>dropDB.addEventListener(ev,e=>{e.preventDefault();dropDB.classList.add('hover');}));['dragleave','drop'].forEach(ev=>dropDB.addEventListener(ev,e=>{e.preventDefault();dropDB.classList.remove('hover');}));dropDB.addEventListener('drop',e=>{dbFile=e.dataTransfer.files[0];dftxtDB.textContent=dbFile.name;document.getElementById('impbtnDB').disabled=false;});}
async function dbRestore(){if(!dbFile)return;if(!confirm('ATENCION: Esto reemplaza la base de datos actual. Asegurese de tener un backup. Continuar?'))return;const buf=await dbFile.arrayBuffer();const t=document.getElementById('db_res');t.className='toast show ok';t.textContent='Restaurando...';const r=await fetch('/api/db/restore',{method:'POST',headers:{'Authorization':'Bearer '+TOKEN},body:buf}).then(r=>r.json());if(r.ok){t.className='toast show ok';t.textContent='Base restaurada. Backup previo: '+r.backup;}else{t.className='toast show err';t.textContent='Error: '+(r.error||'no se pudo restaurar');}}
async function loadBD(){try{const c=await api('GET','/api/config');try{window._bks=JSON.parse(c.backup_schedules||'[]')}catch(e){window._bks=[]}bksRender();}catch(e){}}
function bksRender(){const el=document.getElementById('bk_list'),arr=window._bks||[];el.innerHTML=arr.length?arr.map((s,i)=>`<div style="display:flex;justify-content:space-between;align-items:center;padding:.5rem .7rem;border:1px solid var(--line);border-radius:10px"><span><b>${s.f}</b> a las ${s.h}${s.f!=='diario'?' (dia '+s.d+')':''}${s.e=='1'?' · email':''}</span><button class="btn btn-del btn-sm" onclick="delBackupSched(${i})">✕</button></div>`).join(''):'<div style="color:var(--mut);font-size:.85rem">Sin programaciones. Agregue una arriba.</div>';}
function addBackupSched(){saveSchedules([...(window._bks||[]),{f:document.getElementById('c_backup_frecuencia').value,h:document.getElementById('c_backup_hora').value,d:document.getElementById('c_backup_dia').value,e:document.getElementById('c_backup_email_enable').checked?'1':'0'}]);}
function delBackupSched(i){const a=[...(window._bks||[])];a.splice(i,1);saveSchedules(a);}
async function saveSchedules(arr){window._bks=arr;await api('PUT','/api/config',{backup_schedules:JSON.stringify(arr)});bksRender();const t=document.getElementById('bk_res');t.className='toast show ok';t.textContent='Programacion guardada';setTimeout(()=>t.className='toast',2500);}
// SMTP
async function smtpTest(){const def=(document.getElementById('c_backup_email')||{}).value||'';const email=prompt('Email destino para la prueba:',def);if(!email)return;const t=document.getElementById('cfg_res');t.className='toast';t.textContent='Probando SMTP...';t.className='toast show';try{const r=await api('POST','/api/smtp/test',{email:email});if(r&&r.ok){t.className='toast show ok';t.textContent='Email de prueba enviado a '+email+'. Revisa bandeja y spam.';}else{let m=(r&&r.error)||'no se pudo enviar';if(/auth|login|password|535|534/i.test(m))m+=' -- Si usas Gmail crea una App Password (no sirve la clave comun).';if(/timeout|disconnected|closed|timed out/i.test(m))m+=' -- Proba SSL (puerto 465) o TLS (puerto 587). El sistema ya usa SSL en 465.';t.className='toast show err';t.textContent='Error: '+m;}}catch(e){t.className='toast show err';t.textContent='Error: '+e;}loadSmtpLog();}
async function loadSmtpLog(){const p=document.getElementById('smtp_log');if(!p)return;try{const r=await api('GET','/api/smtp/log');p.textContent=(r.lines&&r.lines.length)?r.lines.join('\n'):'- sin registros todavia -';p.scrollTop=p.scrollHeight;}catch(e){p.textContent='Error: '+e;}}
async function clearSmtpLog(){if(!confirm('Limpiar el log SMTP?'))return;await api('GET','/api/smtp/log/clear');loadSmtpLog();}
// PBX
async function pbx(cmd){const r=await api('GET','/api/pbx?cmd='+cmd);document.getElementById('pbx_out').textContent=r.salida||r.error||'';}
async function pbxReload(){if(!confirm('Recargar configuracion del PBX?'))return;const r=await api('POST','/api/pbx/reload');document.getElementById('pbx_out').textContent=r.salida||'';}
async function pbxRestart(){if(!confirm('Reiniciar PBX? Se cortaran llamadas activas.'))return;const r=await api('POST','/api/pbx/restart');document.getElementById('pbx_out').textContent=r.salida||'';}
async function applyTheme(){try{const c=await fetch('/api/theme').then(r=>r.json());const acc=c.theme_acc||'#0ea5e9',acc2=c.theme_acc2||'#6366f1',bg=c.theme_bg||'#f4f7fb',panel=c.theme_panel||'#ffffff',fh=c.theme_font_heading||'Space Grotesk',fb=c.theme_font_body||'Inter';let s=document.getElementById('dyn-theme');if(!s){s=document.createElement('style');s.id='dyn-theme';document.body.appendChild(s);}s.textContent=`:root{--acc:${acc}!important;--acc2:${acc2}!important;--bg:${bg}!important;--panel:${panel}!important}body{background:radial-gradient(900px 600px at 8% -10%,${acc}22,transparent 60%),radial-gradient(820px 520px at 102% 0%,${acc2}22,transparent 55%),${bg}!important}.btn-pri,.tabs button.active,.brand .logo,.login .logo,.side .brand .logo{background:linear-gradient(135deg,${acc},${acc2})!important}h1,h2,h3,.brand,.tabs button,.btn,.login h1{font-family:'${fh}','Inter',sans-serif!important}body{font-family:'${fb}',ui-sans-serif,system-ui,sans-serif!important}`}catch(e){}}
async function health(){try{const h=await fetch('/api/health').then(r=>r.json());const p=document.getElementById('h');p.textContent=h.status==='ok'?'en linea':'caido';p.className='pill '+(h.status==='ok'?'':'off');}catch(e){}}
// Dashboard
async function loadDash(){try{const s=await api('GET','/api/stats');const sd=document.getElementById('dash_stats');sd.innerHTML=`<div class="card" style="flex:1;min-width:140px;background:var(--panel2);padding:1rem"><div style="color:var(--mut);font-size:.72rem;text-transform:uppercase">Total enviados</div><div style="font-size:1.8rem;font-weight:800">${s.total_enviados||0}</div></div><div class="card" style="flex:1;min-width:140px;background:var(--panel2);padding:1rem"><div style="color:var(--mut);font-size:.72rem;text-transform:uppercase">Enviados OK</div><div style="font-size:1.8rem;font-weight:800;color:#86efac">${s.total_ok||0}</div></div><div class="card" style="flex:1;min-width:140px;background:var(--panel2);padding:1rem"><div style="color:var(--mut);font-size:.72rem;text-transform:uppercase">Errores</div><div style="font-size:1.8rem;font-weight:800;color:#fca5a5">${s.total_err||0}</div></div>`;drawChart('chart_dia',s.por_dia||[],'dia','total');drawChart('chart_hora',s.por_hora||[],'hora','total');const tp=document.getElementById('dash_top');tp.innerHTML=(s.top_pagers||[]).length?(s.top_pagers.map(x=>`<div style="display:flex;justify-content:space-between;padding:.4rem 0;border-bottom:1px solid var(--line)"><span>${x.codigo}</span><strong>${x.total}</strong></div>`).join('')):'<div style="color:var(--mut);padding:1rem">Sin datos</div>';}catch(e){}}
function drawChart(id,data,xkey,ykey){const c=document.getElementById(id);if(!c)return;const ctx=c.getContext('2d');const w=c.width=c.offsetWidth;const h=c.height;ctx.clearRect(0,0,w,h);if(!data.length){ctx.fillStyle='#8aa0bd';ctx.font='13px sans-serif';ctx.fillText('Sin datos',10,20);return;}const max=Math.max(...data.map(d=>d[ykey]||0))||1;const bw=w/Math.max(data.length,1);ctx.fillStyle='#14b8a6';data.forEach((d,i)=>{const bh=(d[ykey]||0)/max*(h-20);ctx.fillRect(i*bw+2,h-bh-15,bw-4,bh);});}
// Plantillas
async function loadPlantillas(){const r=await api('GET','/api/plantillas');document.getElementById('tb_plantillas').innerHTML=(r||[]).map(x=>`<tr><td>${x.nombre}</td><td>${x.categoria||''}</td><td>${(x.mensaje||'').slice(0,60)}</td><td>${x.orden||0}</td><td><span class="badge ${x.activo?'ok':'mut'}">${x.activo?'si':'no'}</span></td><td><button class="btn btn-sec btn-sm" onclick="openPlantilla(${x.id})">✎</button> <button class="btn btn-del btn-sm" onclick="delPlantilla(${x.id})">✕</button></td></tr>`).join('')||`<tr><td colspan="6" style="color:var(--mut);text-align:center;padding:1rem">Sin plantillas</td></tr>`;}
async function openPlantilla(id){editPL=id||null;let x=null;if(id){const r=await api('GET','/api/plantillas');x=(r||[]).find(i=>i.id===id);}document.getElementById('pl_nombre').value=x?x.nombre:'';document.getElementById('pl_cat').value=x?x.categoria||'general':'general';document.getElementById('pl_mensaje').value=x?x.mensaje:'';document.getElementById('pl_orden').value=x?x.orden||0:0;document.getElementById('mPLT').textContent=id?'Editar plantilla':'Nueva plantilla';openModal('mPlantilla');}
async function savePlantilla(){const d={nombre:document.getElementById('pl_nombre').value,mensaje:document.getElementById('pl_mensaje').value,categoria:document.getElementById('pl_cat').value,orden:+document.getElementById('pl_orden').value};if(editPL)await api('PUT','/api/plantillas/'+editPL,d);else await api('POST','/api/plantillas',d);closeModal('mPlantilla');loadPlantillas();}
async function delPlantilla(id){if(confirm('Eliminar plantilla?')){await api('DELETE','/api/plantillas/'+id);loadPlantillas();}}
// Programados
async function loadProgramados(){const r=await api('GET','/api/programados');document.getElementById('tb_programados').innerHTML=(r||[]).map(x=>`<tr><td>${x.codigo}</td><td>${(x.mensaje||'').slice(0,50)}</td><td>${x.tipo||''}</td><td>${x.proxima_ejecucion||x.fecha_programada||''}</td><td><span class="badge ${x.activo?'ok':'mut'}">${x.activo?'si':'no'}</span></td><td><button class="btn btn-sec btn-sm" onclick="openProgramado(${x.id})">✎</button> <button class="btn btn-del btn-sm" onclick="delProgramado(${x.id})">✕</button></td></tr>`).join('')||`<tr><td colspan="6" style="color:var(--mut);text-align:center;padding:1rem">Sin envios programados</td></tr>`;}
async function openProgramado(id){editPR=id||null;let x=null;if(id){const r=await api('GET','/api/programados');x=(r||[]).find(i=>i.id===id);}document.getElementById('pr_codigo').value=x?x.codigo:'';document.getElementById('pr_tipo').value=x?x.tipo||'unico':'unico';document.getElementById('pr_mensaje').value=x?x.mensaje:'';document.getElementById('pr_fecha').value=x?x.fecha_programada||'':'';document.getElementById('pr_hora').value=x?x.recurrencia_hora||'08:00':'08:00';document.getElementById('pr_dia').value=x?x.recurrencia_dia||1:1;document.getElementById('mPRT').textContent=id?'Editar envio':'Nuevo envio programado';openModal('mProgramado');}
async function saveProgramado(){const d={codigo:document.getElementById('pr_codigo').value,mensaje:document.getElementById('pr_mensaje').value,tipo:document.getElementById('pr_tipo').value,fecha_programada:document.getElementById('pr_fecha').value,recurrencia_hora:document.getElementById('pr_hora').value,recurrencia_dia:+document.getElementById('pr_dia').value};if(editPR)await api('PUT','/api/programados/'+editPR,d);else await api('POST','/api/programados',d);closeModal('mProgramado');loadProgramados();}
async function delProgramado(id){if(confirm('Eliminar envio programado?')){await api('DELETE','/api/programados/'+id);loadProgramados();}}
// Logs
let curLogType='api';async function loadLogs(tipo){curLogType=tipo;const r=await api('GET','/api/logs?tipo='+tipo+'&limit=300');document.getElementById('log_out').textContent=(r.lineas||[]).join('\n')||'(log vacio o inexistente)';}
// Auditoria
async function loadAud(){const r=await api('GET','/api/auditoria?limit=200');document.getElementById('tb_aud').innerHTML=(r.rows||[]).map(x=>`<tr><td>${x.fecha_hora}</td><td>${x.usuario||''}</td><td>${x.accion||''}</td><td>${x.entidad||''}</td><td>${x.entidad_id||''}</td><td>${(x.detalle||'').slice(0,50)}</td><td>${x.ip||''}</td></tr>`).join('')||`<tr><td colspan="7" style="color:var(--mut);text-align:center;padding:1rem">Sin registros de auditoria</td></tr>`;}
checkTok();applyTheme();health();setInterval(health,20000);loadVersion();
const CHANGELOG=[['1.03','Fecha y hora de la bitacora y auditoria en hora local del servidor (America/Argentina/Cordoba). Configuracion automatica de zona horaria en el instalador y TZ en los servicios.'],['1.02','Programacion multiple de backups con listado y eliminacion desde el admin. Correccion SMTP: auto-SSL en puerto 465 (evita timeout con TLS en 465).'],['1.01','Programacion de backups (diario/semanal/mensual) desde el panel, con envio por email opcional. Soporte importar .xls. Logs de cola/scheduler/backup. Instalador Raspberry Pi.'],['1.0','Version inicial: panel publico y admin, cola de envios, envios programados, plantillas, dashboard, visor de logs, auditoria, modulo de diseno, gestion PBX, backups por email y sistema de versiones.']];
function loadChangelog(){const el=document.getElementById('changelog');if(el)el.innerHTML=CHANGELOG.map(([v,t])=>`<div style="margin-bottom:.6rem"><b style="color:var(--acc)">v${v}</b><br>${t}</div>`).join('');}
async function loadVersion(){try{const v=await fetch('/api/version').then(r=>r.json());const el=document.getElementById('ver');if(el)el.textContent='v'+(v.version||'1.0');}catch(e){}}
</script>
<style>
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=Space+Grotesk:wght@400;500;600;700&display=swap');
*{font-family:'Inter',ui-sans-serif,system-ui,-apple-system,sans-serif!important}
h1,h2,h3,.brand,.tabs button,.btn,.login h1{font-family:'Space Grotesk','Inter',sans-serif!important;letter-spacing:-.01em!important}
body{background:radial-gradient(900px 600px at 8% -10%,rgba(14,165,233,.15),transparent 60%),radial-gradient(820px 520px at 102% 0%,rgba(99,102,241,.15),transparent 55%),radial-gradient(760px 760px at 50% 120%,rgba(16,185,129,.10),transparent 60%),#f4f7fb!important;background-attachment:fixed!important;color:#0f172a!important}
.brand .logo,.login .logo,.side .brand .logo{background:linear-gradient(135deg,#0ea5e9,#6366f1,#10b981)!important;box-shadow:0 8px 22px -6px rgba(99,102,241,.5)!important}
.topbar{background:rgba(255,255,255,.7)!important;backdrop-filter:blur(18px) saturate(160%)!important;-webkit-backdrop-filter:blur(18px) saturate(160%)!important;border-bottom:1px solid rgba(15,23,42,.07)!important}
.card{background:rgba(255,255,255,.86)!important;backdrop-filter:blur(18px) saturate(150%)!important;-webkit-backdrop-filter:blur(18px) saturate(150%)!important;border:1px solid rgba(15,23,42,.07)!important;border-radius:22px!important;box-shadow:0 1px 2px rgba(15,23,42,.04),0 14px 34px -14px rgba(15,23,42,.16)!important;transition:transform .25s ease,box-shadow .25s ease!important}
.card:hover{transform:translateY(-2px)!important;box-shadow:0 1px 2px rgba(15,23,42,.05),0 22px 44px -14px rgba(15,23,42,.2)!important}
.card h2{font-weight:700!important}
.btn{border-radius:13px!important;font-weight:600!important;transition:.2s!important}
.btn-pri{background:linear-gradient(135deg,#0ea5e9,#6366f1)!important;color:#fff!important;border:none!important;box-shadow:0 8px 20px -6px rgba(99,102,241,.45)!important}
.btn-pri:hover{filter:brightness(1.06)!important;transform:translateY(-1px)!important}
.btn-sec{background:#fff!important;color:#0f172a!important;border:1px solid rgba(15,23,42,.12)!important}
.btn-sec:hover{border-color:#0ea5e9!important;background:#f8fafc!important}
.btn-ok{background:linear-gradient(135deg,#10b981,#059669)!important;color:#fff!important;border:none!important}
.btn-del{background:linear-gradient(135deg,#ef4444,#dc2626)!important;color:#fff!important;border:none!important}
.btn-warn{background:linear-gradient(135deg,#f59e0b,#d97706)!important;color:#fff!important;border:none!important}
.tabs button{background:#fff!important;border:1px solid rgba(15,23,42,.1)!important;color:#475569!important;border-radius:13px!important;font-weight:600!important}
.tabs button.active{background:linear-gradient(135deg,#0ea5e9,#6366f1)!important;color:#fff!important;border-color:transparent!important;box-shadow:0 8px 18px -6px rgba(99,102,241,.45)!important}
.side{background:rgba(255,255,255,.82)!important;backdrop-filter:blur(18px) saturate(150%)!important;-webkit-backdrop-filter:blur(18px) saturate(150%)!important;border-right:1px solid rgba(15,23,42,.07)!important}
.side nav button{border-radius:13px!important;color:#475569!important;font-weight:600!important}
.side nav button:hover{background:#f1f5f9!important;color:#0f172a!important}
.side nav button.active{background:linear-gradient(135deg,rgba(14,165,233,.16),rgba(99,102,241,.16))!important;color:#0369a1!important;border:1px solid rgba(14,165,233,.3)!important}
.login .box{background:rgba(255,255,255,.92)!important;backdrop-filter:blur(24px) saturate(160%)!important;-webkit-backdrop-filter:blur(24px) saturate(160%)!important;border:1px solid rgba(15,23,42,.07)!important;border-radius:26px!important;box-shadow:0 28px 70px -24px rgba(15,23,42,.28)!important}
.login h1{color:#0f172a!important}
.login p{color:#64748b!important}
input,select,textarea{background:#fff!important;border:1px solid rgba(15,23,42,.12)!important;color:#0f172a!important;border-radius:13px!important}
input:focus,select:focus,textarea:focus{border-color:#0ea5e9!important;box-shadow:0 0 0 4px rgba(14,165,233,.16)!important;outline:none!important}
label{color:#64748b!important}
th{color:#64748b!important;font-family:'Space Grotesk',sans-serif!important;letter-spacing:.3px!important}
tbody tr:hover{background:rgba(14,165,233,.06)!important}
.badge.ok{background:rgba(16,163,74,.15)!important;color:#15803d!important}
.badge.err{background:rgba(220,38,38,.12)!important;color:#b91c1c!important}
.badge.mut{background:#f1f5f9!important;color:#64748b!important}
.pill{background:rgba(14,165,233,.12)!important;color:#0369a1!important;border:1px solid rgba(14,165,233,.25)!important;font-weight:600!important}
.pill.off{background:rgba(220,38,38,.12)!important;color:#b91c1c!important;border-color:rgba(220,38,38,.25)!important}
.combo ul{background:#fff!important;border:1px solid rgba(15,23,42,.1)!important;box-shadow:0 16px 40px -12px rgba(15,23,42,.2)!important;border-radius:13px!important}
.combo li:hover{background:rgba(14,165,233,.08)!important}
.sw{background:#cbd5e1!important}
.sw.on{background:linear-gradient(135deg,#10b981,#059669)!important}
pre{background:#f8fafc!important;border:1px solid rgba(15,23,42,.1)!important;color:#0f172a!important;border-radius:13px!important;padding:.8rem 1rem!important}
.toast{border-radius:13px!important}
.toast.ok{background:rgba(16,163,74,.12)!important;border:1px solid rgba(16,163,74,.3)!important;color:#15803d!important}
.toast.err{background:rgba(220,38,38,.1)!important;border:1px solid rgba(220,38,38,.3)!important;color:#b91c1c!important}
</style>
</body></html>
EOF

# --- bin/uninstall.sh ---
cat > "${APP_DIR}/bin/uninstall.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
APP="/opt/pocsag-server"; PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1
[[ $EUID -ne 0 ]] && { echo "root/sudo"; exit 1; }
systemctl disable --now pocsag-monitor pocsag-api pocsag-cola pocsag-scheduler 2>/dev/null||true
rm -f /etc/systemd/system/pocsag-{monitor,api,cola,scheduler}.service
systemctl daemon-reload
rm -f /etc/asterisk/extensions_pocsag.conf /etc/asterisk/pjsip_pocsag.conf
rm -f /var/lib/asterisk/agi-bin/pocsag_handler.py /var/lib/asterisk/agi-bin/pocsag_check.py
rm -f /etc/logrotate.d/pocsag
asterisk -rx "dialplan reload" 2>/dev/null||true
if [[ $PURGE -eq 1 ]]; then rm -rf "$APP"; rm -f /var/log/pocsag-install.log
else cp "$APP/database/pocsag.db" /tmp/pocsag-backup.db 2>/dev/null||true; rm -rf "$APP"; fi
echo "Desinstalacion completa (Asterisk NO se quita)."
EOF
mkx "${APP_DIR}/bin/uninstall.sh"

chown -R "${AST_USER}:${AST_USER}" "${APP_DIR}" 2>/dev/null || true

# ============================ 6. BASE DE DATOS =============================
echo "==> 6/10 Base de datos..."
python3 "${APP_DIR}/database/db_manager.py" init
# Forzar credenciales admin validas (INSERT OR IGNORE preserva valores existentes)
python3 -c "
import sqlite3
c = sqlite3.connect('${APP_DIR}/database/pocsag.db')
c.execute('INSERT OR IGNORE INTO config(clave,valor) VALUES(?,?)', ('admin_user','admin'))
c.execute('INSERT OR IGNORE INTO config(clave,valor) VALUES(?,?)', ('admin_pass','admin123'))
c.execute('INSERT OR REPLACE INTO config(clave,valor) VALUES(?,?)', ('version','${VERSION}'))
c.commit(); c.close()
"
chmod 640 "${APP_DIR}/database/pocsag.db" 2>/dev/null || true

# ============================ 7. DIALPLAN + AGI ============================
echo "==> 7/10 Dialplan + AGI..."
mkdir -p /var/lib/asterisk/agi-bin
cp "${APP_DIR}/agi/pocsag_handler.py" "${APP_DIR}/agi/pocsag_check.py" /var/lib/asterisk/agi-bin/
mkx /var/lib/asterisk/agi-bin/pocsag_handler.py
mkx /var/lib/asterisk/agi-bin/pocsag_check.py
chown -R "${AST_USER}:${AST_USER}" /var/lib/asterisk/agi-bin 2>/dev/null || true

ivr_file="${APP_DIR}/asterisk/pocsag_ivr.conf"
cp "$ivr_file" "${AST_ETC}/extensions_pocsag.conf"
grep -q 'extensions_pocsag.conf' "${AST_ETC}/extensions.conf" 2>/dev/null || echo '#include extensions_pocsag.conf' >> "${AST_ETC}/extensions.conf"
cp "${APP_DIR}/asterisk/pjsip_pocsag.conf" "${AST_ETC}/"
grep -q 'pjsip_pocsag.conf' "${AST_ETC}/pjsip.conf" 2>/dev/null || echo '#include pjsip_pocsag.conf' >> "${AST_ETC}/pjsip.conf"
# Regenerar pjsip + dialplan desde la BD (todas las extensiones activas: 2184-2187)
python3 -c "
import sys; sys.path.insert(0,'${APP_DIR}')
from database.db_manager import generar_pjsip_conf, generar_dialplan_conf
ok1=generar_pjsip_conf(); ok2=generar_dialplan_conf()
print('pjsip='+str(ok1),'dialplan='+str(ok2))
" 2>/dev/null || warn "No se pudo regenerar config desde BD (se usa el estatico)"
log "Dialplan + endpoints integrados (Asterisk nativo)."

# ============================ 8. LOCUCIONES ===============================
echo "==> 8/10 Locuciones IVR..."
if [[ $UPDATE -eq 0 ]]; then
gen(){ local out="${APP_DIR}/audio/$1.gsm"; [[ -f "$out" ]] && return
  espeak -v es -s 160 "$2" -w "${out%.gsm}.wav" 2>/dev/null && sox "${out%.gsm}.wav" -r 8000 -c 1 "$out" 2>/dev/null || warn "No se pudo generar $1"
  rm -f "${out%.gsm}.wav"; }
gen despues-del-tono-marque-codigo "Despues del tono marque el numero de codigo"
gen despues-de-la-senal-su-mensaje "Despues de la senal marque su mensaje"
gen codigo-inexistente "Codigo inexistente"
gen marque-otro-codigo "Por favor marque otro codigo"
gen mensaje-vacio "Mensaje vacio"
gen confirmado "Mensaje enviado"
gen error-envio "Error de envio"
sox -n -r 8000 -c 1 "${APP_DIR}/audio/beep.gsm" synth 0.2 sine 1000 2>/dev/null || warn "beep no generado"
cp "${APP_DIR}"/audio/*.gsm /var/lib/asterisk/sounds/ 2>/dev/null || true
chown -R "${AST_USER}:${AST_USER}" /var/lib/asterisk/sounds 2>/dev/null || true
else
  echo "==> 8/10 Locuciones IVR (omitidas en --update)"
fi

# ============================ 9. SYSTEMD + LOGROTATE ======================
echo "==> 9/10 Servicios + logrotate..."
cp "${APP_DIR}/services/"*.service /etc/systemd/system/
cat > /etc/logrotate.d/pocsag <<EOF
${APP_DIR}/logs/*.log { daily rotate 14 compress missingok notifempty }
EOF
cat > /etc/cron.d/pocsag-cleanup <<'EOF'
# Limpieza diaria de WAV generados (out_*.wav) con mas de 7 dias.
# Las locuciones .gsm del IVR no se tocan.
0 3 * * * root /opt/pocsag-server/scripts/limpiar_audio.sh 7 >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/pocsag-cleanup
cat > /etc/cron.d/pocsag-backup <<'EOF'
*/10 * * * * root /opt/pocsag-server/scripts/backup_auto.sh 7 >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/pocsag-backup
systemctl daemon-reload
systemctl enable --now asterisk 2>/dev/null || warn "Asterisk no pudo activarse"
asterisk -rx "dialplan reload" 2>/dev/null || warn "No se pudo recargar dialplan"
asterisk -rx "pjsip reload" 2>/dev/null || true
systemctl daemon-reload
systemctl restart pocsag-api 2>/dev/null || warn "API no pudo reiniciarse"
systemctl enable pocsag-api 2>/dev/null || true
systemctl restart pocsag-monitor 2>/dev/null || true
systemctl enable pocsag-monitor 2>/dev/null || true
systemctl restart pocsag-cola 2>/dev/null || warn "Cola worker no pudo iniciarse"
systemctl enable pocsag-cola 2>/dev/null || true
systemctl restart pocsag-scheduler 2>/dev/null || warn "Scheduler no pudo iniciarse"
systemctl enable pocsag-scheduler 2>/dev/null || true
sleep 3

# ============================ 10. CHEQUEO ================================
echo "==> 10/10 Chequeo..."
bash "${APP_DIR}/scripts/healthcheck.sh" || warn "Healthcheck reporto problemas"

echo "==> Verificando API..."
if curl -sf "http://localhost:8080/api/health" >/dev/null 2>&1; then
  log "API responde en http://localhost:8080"
else
  warn "API no responde. Diagnostico:"
  systemctl status pocsag-api --no-pager -l 2>/dev/null | head -20 || true
  journalctl -u pocsag-api -n 20 --no-pager 2>/dev/null || true
fi

echo "--------------------------------------------"
if [[ $UPDATE -eq 1 ]]; then
  log "Actualizacion (--update) completada en ${APP_DIR}"
else
  log "Instalacion completada en ${APP_DIR}"
fi
cat <<EOF

  VERSION: ${VERSION}
  MODO: Asterisk nativo
  Panel publico (enviar + historial):  http://<servidor>:8080/
  Panel admin (gestion completa):       http://<servidor>:8080/admin
    Login por defecto: usuario=admin  clave=admin123  (CAMBIAR en Parametros)

PRUEBAS (Zoiper -> 101 -> 2184):
    1) Edita /etc/asterisk/pjsip_pocsag.conf y cambia CAMBIAR_PASSWORD_101
    2) asterisk -rx "pjsip reload"
    3) Zoiper: usuario 101, esa clave, host <servidor>:5060, UDP
    4) Marcas 2184 -> IVR: codigo -> mensaje -> "Mensaje enviado"

  El sistema arranca en MODO PRUEBA (test_mode=1): omite PTT/audio y registra en bitacora.
  Para transmitir de verdad: panel web -> Parametros -> Modo prueba = 0 (y tener PTT/audio calibrados).

  Bitacora: sqlite3 /opt/pocsag-server/database/pocsag.db "SELECT * FROM bitacora ORDER BY id DESC LIMIT 5;"

  Reinstalar desde cero (backup automatico de la base): sudo bash instalador.sh --reset
  Desinstalar POCSAG: sudo /opt/pocsag-server/bin/uninstall.sh
EOF