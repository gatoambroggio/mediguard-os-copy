#!/usr/bin/env python3
"""
db_manager.py - ZetronPOC v2.0 - Gestor de base de datos y configuracion.
Toda la configuracion (PBX, modulo MMDVM, IVR, GPIO, SMTP, tema) vive en la
tabla config (clave/valor). generar_pjsip_conf() produce un pjsip.conf
SELF-CONTAINED (sin includes). generar_mmdvm_ini() produce el MMDVM.ini.
"""
import sqlite3, os, secrets, time, datetime, subprocess, sys
from contextlib import contextmanager

DEFAULT_DB = "/opt/zetronpoc/database/zetronpoc.db"
PJSIP_CONF = "/etc/asterisk/pjsip.conf"
_TOKENS = {}

@contextmanager
def get_conn(db_path=DEFAULT_DB):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        yield conn; conn.commit()
    finally:
        conn.close()

def init_db(db_path=DEFAULT_DB):
    base = os.path.dirname(__file__)
    with get_conn(db_path) as conn:
        with open(os.path.join(base, "schema.sql"), encoding="utf-8") as f:
            conn.executescript(f.read())
        with open(os.path.join(base, "seed.sql"), encoding="utf-8") as f:
            conn.executescript(f.read())

def get_config(clave, default="", db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        row = conn.execute("SELECT valor FROM config WHERE clave=?", (clave,)).fetchone()
        return row["valor"] if row else default

def set_config(clave, valor, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("INSERT INTO config(clave,valor) VALUES(?,?) "
                     "ON CONFLICT(clave) DO UPDATE SET valor=excluded.valor", (clave, valor))

def all_config(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return {r["clave"]: r["valor"] for r in conn.execute("SELECT * FROM config")}

# ===================== PAGERS =====================
def listar_pagers(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM pagers ORDER BY codigo")]

def buscar_pagers(q, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        if not q:
            return [dict(r) for r in conn.execute("SELECT * FROM pagers ORDER BY codigo")]
        like = "%%%s%%" % q
        return [dict(r) for r in conn.execute(
            "SELECT * FROM pagers WHERE codigo LIKE ? OR cap_code LIKE ? OR nombre LIKE ? "
            "OR apellido LIKE ? OR area LIKE ? ORDER BY codigo", (like, like, like, like, like))]

def crear_pager(data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        cur = conn.execute(
            "INSERT INTO pagers (codigo,cap_code,nombre,apellido,area,baudios,funcion,descripcion,activo) "
            "VALUES (?,?,?,?,?,?,?,?,1)",
            (data["codigo"], data["cap_code"], data.get("nombre"), data.get("apellido"),
             data.get("area"), data.get("baudios", 1200), data.get("funcion", "alphanumeric"),
             data.get("descripcion")))
        return cur.lastrowid

def actualizar_pager(pid, data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute(
            "UPDATE pagers SET codigo=?,cap_code=?,nombre=?,apellido=?,area=?,baudios=?,"
            "funcion=?,descripcion=?,activo=? WHERE id=?",
            (data["codigo"], data["cap_code"], data.get("nombre"), data.get("apellido"),
             data.get("area"), data.get("baudios", 1200), data.get("funcion", "alphanumeric"),
             data.get("descripcion"), int(data.get("activo", 1)), pid))

def toggle_pager(pid, activo, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE pagers SET activo=? WHERE id=?", (int(activo), pid))

def borrar_pager(pid, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM pagers WHERE id=?", (pid,))

def importar_pagers(rows, db_path=DEFAULT_DB):
    n = 0; errores = 0
    with get_conn(db_path) as conn:
        for r in rows:
            try: baud = int(r.get("baudios") or 1200)
            except (ValueError, TypeError): baud = 1200
            try:
                conn.execute(
                    "INSERT INTO pagers (codigo,cap_code,nombre,apellido,area,baudios,funcion,descripcion,activo) "
                    "VALUES (?,?,?,?,?,?,?,?,1) ON CONFLICT(codigo) DO UPDATE SET "
                    "cap_code=excluded.cap_code,nombre=excluded.nombre,apellido=excluded.apellido,"
                    "area=excluded.area,baudios=excluded.baudios,funcion=excluded.funcion,descripcion=excluded.descripcion",
                    (r["codigo"], r["cap_code"], r.get("nombre", ""), r.get("apellido", ""),
                     r.get("area", ""), baud, r.get("funcion", "alphanumeric"), r.get("descripcion", "")))
                n += 1
            except Exception:
                errores += 1
    return {"importados": n, "errores": errores}

# ===================== GRUPOS =====================
def listar_grupos(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        rows = conn.execute("SELECT * FROM grupos ORDER BY codigo").fetchall()
        out = []
        for g in rows:
            miembros = [m["cap_code"] for m in conn.execute(
                "SELECT cap_code FROM grupo_miembros WHERE grupo_id=? ORDER BY orden", (g["id"],)).fetchall()]
            out.append({**dict(g), "miembros": miembros})
        return out

def buscar_grupos(q, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        rows = (conn.execute("SELECT * FROM grupos ORDER BY codigo").fetchall() if not q else
                conn.execute("SELECT * FROM grupos WHERE codigo LIKE ? OR nombre LIKE ? ORDER BY codigo",
                             ("%%%s%%" % q, "%%%s%%" % q)).fetchall())
        out = []
        for g in rows:
            miembros = [m["cap_code"] for m in conn.execute(
                "SELECT cap_code FROM grupo_miembros WHERE grupo_id=? ORDER BY orden", (g["id"],)).fetchall()]
            out.append({**dict(g), "miembros": miembros})
        return out

def crear_grupo(data, db_path=DEFAULT_DB):
    caps = data.get("miembros", [])[:20]
    with get_conn(db_path) as conn:
        cur = conn.execute("INSERT INTO grupos (codigo,nombre,baudios,activo) VALUES (?,?,?,1)",
                           (data["codigo"], data.get("nombre"), data.get("baudios", 1200)))
        gid = cur.lastrowid
        for i, c in enumerate(caps):
            conn.execute("INSERT OR IGNORE INTO grupo_miembros (grupo_id,cap_code,orden) VALUES (?,?,?)", (gid, c, i))
        return gid

def actualizar_grupo(gid, data, db_path=DEFAULT_DB):
    caps = data.get("miembros", [])[:20]
    with get_conn(db_path) as conn:
        conn.execute("UPDATE grupos SET codigo=?,nombre=?,baudios=? WHERE id=?",
                     (data["codigo"], data.get("nombre"), data.get("baudios", 1200), gid))
        conn.execute("DELETE FROM grupo_miembros WHERE grupo_id=?", (gid,))
        for i, c in enumerate(caps):
            conn.execute("INSERT OR IGNORE INTO grupo_miembros (grupo_id,cap_code,orden) VALUES (?,?,?)", (gid, c, i))

def borrar_grupo(gid, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM grupos WHERE id=?", (gid,))

def importar_grupos(rows, db_path=DEFAULT_DB):
    n = 0; errores = 0
    with get_conn(db_path) as conn:
        for r in rows:
            try: baud = int(r.get("baudios") or 1200)
            except (ValueError, TypeError): baud = 1200
            caps = [c.strip() for c in str(r.get("cap_codes", "")).split(",") if c.strip()][:20]
            codigo = r.get("codigo", "")
            if not codigo or not caps: continue
            try:
                conn.execute("INSERT INTO grupos (codigo,nombre,baudios,activo) VALUES (?,?,?,1) "
                    "ON CONFLICT(codigo) DO UPDATE SET nombre=excluded.nombre,baudios=excluded.baudios",
                    (codigo, r.get("nombre", ""), baud))
                gid = conn.execute("SELECT id FROM grupos WHERE codigo=?", (codigo,)).fetchone()["id"]
                conn.execute("DELETE FROM grupo_miembros WHERE grupo_id=?", (gid,))
                for i, c in enumerate(caps):
                    conn.execute("INSERT OR IGNORE INTO grupo_miembros (grupo_id,cap_code,orden) VALUES (?,?,?)", (gid, c, i))
                n += 1
            except Exception:
                errores += 1
    return {"importados": n, "errores": errores}

# ===================== EXTENSIONES =====================
def listar_extensiones(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM extensiones ORDER BY numero")]

def crear_extension(data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        cur = conn.execute("INSERT INTO extensiones (numero,password,contexto,descripcion,activo) VALUES (?,?,?,?,1)",
            (data["numero"], data.get("password", ""), data.get("contexto", "from-hospital") or "from-hospital",
             data.get("descripcion", "")))
        return cur.lastrowid

def actualizar_extension(eid, data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE extensiones SET numero=?,password=?,contexto=?,descripcion=?,activo=? WHERE id=?",
            (data["numero"], data.get("password", ""), data.get("contexto", "from-hospital") or "from-hospital",
             data.get("descripcion", ""), int(data.get("activo", 1)), eid))

def borrar_extension(eid, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM extensiones WHERE id=?", (eid,))

# ===================== GENERACION PJSIP =====================
def generar_pjsip_conf(db_path=DEFAULT_DB):
    cfg = all_config(db_path)
    ip = (cfg.get("hospital_pbx_ip") or "").strip()
    if not ip or ip == "IP_HOSPITAL":
        return False, "Configure la IP del hospital en Parametros antes de aplicar"
    exts = listar_extensiones(db_path)
    activos = [e for e in exts if e["activo"]]
    if not activos:
        return False, "No hay extensiones activas"
    for e in activos:
        if not (e.get("password") or "").strip():
            return False, "La extension %s no tiene clave" % e["numero"]

    transport_bind = cfg.get("transport_bind", "0.0.0.0:5060")
    transport_proto = cfg.get("transport_protocol", "udp")
    codecs = cfg.get("codecs", "ulaw,alaw")
    retry_interval = cfg.get("retry_interval", "60")
    expiration = cfg.get("expiration", "3600")
    pbx_port = (cfg.get("hospital_pbx_port", "5060") or "5060").strip()
    sip_target = ip if pbx_port == "5060" else "%s:%s" % (ip, pbx_port)

    lines = [
        "; pjsip_zetronpoc.conf - Generado por panel admin (ZetronPOC v2.0) - NO editar a mano",
        "; IP central: %s" % ip,
        "; Internos activos: %s" % ", ".join(e["numero"] for e in activos),
        "",
        "[transport-udp]",
        "type=transport",
        "protocol=%s" % transport_proto,
        "bind=%s" % transport_bind,
        "",
    ]
    for e in activos:
        num = e["numero"]; pw = e["password"].strip()
        lines += [
            "; === Interno %s ===" % num,
            "[%s]" % num, "type=endpoint", "context=from-hospital", "disallow=all",
            "allow=%s" % codecs, "transport=transport-udp", "aors=%s" % num,
            "trust_id_inbound=yes", "direct_media=no", "force_rport=yes",
            "rtp_symmetric=yes", "inband_progress=yes", "allow_subscribe=no",
            "rewrite_contact=yes", "",
            "[%s]" % num, "type=aor", "max_contacts=1", "remove_existing=yes", "",
            "[reg-%s]" % num, "type=registration", "transport=transport-udp",
            "outbound_auth=auth-%s" % num, "server_uri=sip:%s" % sip_target,
            "client_uri=sip:%s@%s" % (num, sip_target), "retry_interval=%s" % retry_interval,
            "expiration=%s" % expiration, "contact_user=%s" % num, "",
            "[auth-%s]" % num, "type=auth", "auth_type=userpass",
            "username=%s" % num, "password=%s" % pw, "",
        ]
    try:
        with open(PJSIP_CONF, "w") as f:
            f.write("\n".join(lines) + "\n")
        return True, "Generado: %d endpoint(s) contra %s" % (len(activos), ip)
    except PermissionError:
        return False, "Sin permisos para escribir pjsip_zetronpoc.conf"

# ===================== MMDVM =====================
MMDVM_INI = os.path.join(os.environ.get("ZETRONPOC_DIR", "/opt/zetronpoc"), "mmdvm", "MMDVM.ini")

def generar_mmdvm_ini(db_path=DEFAULT_DB):
    cfg = all_config(db_path)
    def g(k, d=""):
        return (cfg.get(k) or d).strip()
    callsign = g("mmdvm_callsign", "LU1ABC")
    port = g("mmdvm_serial_port", "/dev/ttyUSB0")
    baud = g("mmdvm_baud", "115200")
    freq_mhz = g("mmdvm_frequency", "433.800")
    # MMDVMHost espera RXFrequency/TXFrequency en Hz (ej: 149.255 MHz -> 149255000)
    try:
        freq_hz = str(int(float(freq_mhz) * 1000000))
    except (ValueError, TypeError):
        freq_hz = "433800000"
    pocsag_baud = g("mmdvm_pocsag_baud", "1200")
    duplex = g("mmdvm_duplex", "0")
    tx_invert = g("mmdvm_tx_invert", "0")
    rx_invert = g("mmdvm_rx_invert", "0")
    ptt_invert = g("mmdvm_ptt_invert", "0")
    tx_level = g("mmdvm_tx_level", "50")
    rx_level = g("mmdvm_rx_level", "50")
    tx_offset = g("mmdvm_tx_offset", "0")
    rx_offset = g("mmdvm_rx_offset", "0")
    # TXDelay aumentado por defecto a 500ms para estabilizar PTT en VHF
    ptt_delay = g("mmdvm_ptt_delay", "500")
    rf_level = g("mmdvm_rf_level", "100")
    oscillator = g("mmdvm_oscillator_speed", "14745600")
    display = g("mmdvm_display", "None")
    enable_pocsag = "1" if g("mmdvm_enable_pocsag", "1") == "1" else "0"
    dapnet_enable = "1" if g("mmdvm_dapnet_enable", "0") == "1" else "0"
    dapnet_address = g("mmdvm_dapnet_address", "")
    dapnet_passcode = g("mmdvm_dapnet_passcode", "")
    remote_port = (cfg.get("mmdvm_remote_port", "7642") or "7642").strip() or "7642"
    ini = (
        "# MMDVM.ini - generado por ZetronPOC / MediGuard OS\n"
        "# Modulo MMDVM por puerto serie UART (Protocol=uart)\n\n"
        "[General]\n"
        "Callsign=%s\n"
        "Id=%s000\n"
        "Timeout=180\n"
        "Duplex=%s\n"
        "RFModeHang=10\n"
        "DMR=0\nDSTAR=0\nYSF=0\nP25=0\nNXDN=0\n"
        "POCSAG=%s\n"
        "Display=%s\n\n"
        "[Modem]\n"
        "Protocol=uart\n"
        "UARTPort=%s\n"
        "UARTSpeed=%s\n"
        "RXFrequency=%s\n"
        "TXFrequency=%s\n"
        "TXInvert=%s\n"
        "RXInvert=%s\n"
        "PTTInvert=%s\n"
        "TXDelay=%s\n"
        "RXOffset=%s\n"
        "TXOffset=%s\n"
        "DMRDelay=0\n"
        "RXLevel=%s\n"
        "TXLevel=%s\n"
        "RXDCOffset=0\n"
        "TXDCOffset=0\n"
        "RFLevel=%s\n"
        "RSSIMappingFile=RSSI.dat\n"
        "UseCOSAsLockout=0\n"
        "Trace=0\n"
        "Debug=0\n"
        "OscillatorSpeed=%s\n\n"
        "[POCSAG]\n"
        "Enable=%s\n"
        "Callsign=%s\n\n"
        "[RemoteControl]\n"
        "Enable=1\n"
        "Port=%s\n\n"
        "[DAPNET]\n"
        "Enable=%s\n"
        "Address=%s\n"
        "Passcode=%s\n\n"
        "[Info]\nEnabled=0\n\n"
        "[Log]\nDisplayLevel=1\nFileLevel=1\nFilePath=/var/log/mmdvm\nFileRoot=MMDVM\n"
    ) % (callsign, callsign.replace(" ", ""), duplex, enable_pocsag, display,
         port, baud, freq_hz, freq_hz, tx_invert, rx_invert, ptt_invert, ptt_delay,
         rx_offset, tx_offset, rx_level, tx_level, rf_level, oscillator,
         enable_pocsag, callsign, remote_port,
         dapnet_enable, dapnet_address, dapnet_passcode)
    try:
        os.makedirs(os.path.dirname(MMDVM_INI), exist_ok=True)
        with open(MMDVM_INI, "w") as f:
            f.write(ini)
        return True, "MMDVM.ini generado en %s (frec=%s Hz, puerto=%s, baud=%s)" % (MMDVM_INI, freq_hz, port, baud)
    except PermissionError:
        return False, "sin permisos para escribir %s (ejecute el servicio como root)" % MMDVM_INI
    except Exception as e:
        return False, str(e)

# ===================== DESTINO / ENVIO =====================
def resolver_destino(codigo, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        row = conn.execute("SELECT cap_code,baudios,funcion FROM pagers WHERE codigo=? AND activo=1", (codigo,)).fetchone()
        if row:
            return (row["cap_code"], row["baudios"], "individual")
        grow = conn.execute("SELECT id,baudios FROM grupos WHERE codigo=? AND activo=1", (codigo,)).fetchone()
        if grow:
            members = conn.execute("SELECT cap_code FROM grupo_miembros WHERE grupo_id=? ORDER BY orden", (grow["id"],)).fetchall()
            caps = ",".join(m["cap_code"] for m in members)
            return (caps, grow["baudios"], "grupo")
        return None

def registrar_bitacora(interno, codigo, cap_code, mensaje, baudios, estado, obs="", cola_id=None, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute(
            "INSERT INTO bitacora (fecha_hora,interno_origen,codigo,cap_code,mensaje,baudios,estado,observaciones,cola_id) "
            "VALUES (?,?,?,?,?,?,?,?,?)",
            (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), interno, codigo, cap_code, mensaje,
             baudios, estado, obs, cola_id))

def registrar_envio_encolado(qid, codigo, caps, mensaje, baudios, origen, db_path=DEFAULT_DB):
    """Registra en bitacora (estado='encolado') al encolar, para que el
    mensaje figure en el historial aun si el worker tarda o no esta corriendo."""
    cap_list = [c.strip() for c in str(caps or "").split(",") if c.strip()] or [""]
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with get_conn(db_path) as conn:
        for cap in cap_list:
            conn.execute(
                "INSERT INTO bitacora (fecha_hora,interno_origen,codigo,cap_code,mensaje,baudios,estado,observaciones,cola_id) "
                "VALUES (?,?,?,?,?,?,?,?,?)",
                (ts, origen, codigo, cap, mensaje, baudios, "encolado", "", qid))

def actualizar_bitacora_envio(qid, cap, estado, obs="", db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE bitacora SET estado=?, observaciones=? WHERE cola_id=? AND cap_code=?",
                     (estado, obs, qid, cap))

def marcar_bitacora_error(qid, obs, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE bitacora SET estado='error', observaciones=? WHERE cola_id=?", (obs, qid))

# ===================== COLA =====================
def encolar_mensaje(codigo, caps, mensaje, baudios, origen, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        cur = conn.execute(
            "INSERT INTO cola_envios (fecha_encola,codigo,cap_code,mensaje,baudios,origen,estado) "
            "VALUES (?,?,?,?,?,?,?)",
            (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), codigo, caps, mensaje, baudios, origen, "pendiente"))
        return cur.lastrowid

def enviar_mensaje(codigo, mensaje, origen="web", db_path=DEFAULT_DB):
    try:
        if not codigo or not mensaje:
            return {"status": "error", "detalle": "falta codigo o mensaje"}
        dest = resolver_destino(codigo, db_path)
        if not dest:
            return {"status": "error", "detalle": "codigo inactivo o inexistente"}
        caps, baudios, tipo = dest
        qid = encolar_mensaje(codigo, caps, mensaje, baudios, origen, db_path)
        registrar_envio_encolado(qid, codigo, caps, mensaje, baudios, origen, db_path)
        return {"status": "encolado", "detalle": "mensaje encolado (id=%d)" % qid, "id": qid}
    except Exception as e:
        return {"status": "error", "detalle": "error interno: %s" % str(e)[:200]}

def listar_cola(estado=None, limit=200, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        if estado:
            rows = conn.execute("SELECT * FROM cola_envios WHERE estado=? ORDER BY id DESC LIMIT ?", (estado, limit))
        else:
            rows = conn.execute("SELECT * FROM cola_envios ORDER BY id DESC LIMIT ?", (limit,))
        return [dict(r) for r in rows]

def estado_cola(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return {r["estado"]: r["c"] for r in
                conn.execute("SELECT estado, COUNT(*) as c FROM cola_envios GROUP BY estado")}

def reintentar_cola(cid, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE cola_envios SET estado='pendiente', intentos=0, observaciones='', proximo_intento=NULL "
                     "WHERE id=? AND estado IN ('error','fallido')", (cid,))

def limpiar_cola(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM cola_envios WHERE estado='enviado'")

def procesar_siguiente_cola(db_path=DEFAULT_DB):
    handler = "/var/lib/asterisk/agi-bin/pocsag_handler.py"
    if not os.path.exists(handler):
        handler = os.path.join(os.path.dirname(__file__), "..", "agi", "pocsag_handler.py")
    with get_conn(db_path) as conn:
        row = conn.execute(
            "SELECT * FROM cola_envios WHERE estado='pendiente' AND "
            "(proximo_intento IS NULL OR proximo_intento <= datetime('now','localtime')) "
            "ORDER BY id ASC LIMIT 1").fetchone()
        if not row:
            return None
        conn.execute("UPDATE cola_envios SET estado='enviando', intentos=intentos+1 WHERE id=?", (row["id"],))
        conn.commit()
    item = dict(row)
    try:
        env = dict(os.environ, ZETRONPOC_DIR="/opt/zetronpoc", POCSAG_WORKER="1")
        rc = subprocess.run([sys.executable, handler, item["origen"] or "cola", item["codigo"], item["mensaje"], str(item["id"])],
                            capture_output=True, text=True, timeout=120, env=env)
        ok = rc.returncode == 0
        obs = "" if ok else (rc.stderr or rc.stdout or "fallo").strip()[:200]
    except Exception as e:
        ok = False; obs = str(e)[:200]
    with get_conn(db_path) as conn:
        if ok:
            conn.execute("UPDATE cola_envios SET estado='enviado', fecha_procesado=datetime('now','localtime'), "
                         "observaciones='', proximo_intento=NULL WHERE id=?", (item["id"],))
        else:
            intentos = item["intentos"] + 1
            if intentos < 3:
                conn.execute("UPDATE cola_envios SET estado='pendiente', fecha_procesado=datetime('now','localtime'), "
                             "observaciones=?, proximo_intento=datetime('now','localtime','+10 seconds') WHERE id=?", (obs, item["id"]))
            else:
                conn.execute("UPDATE cola_envios SET estado='fallido', fecha_procesado=datetime('now','localtime'), "
                             "observaciones=?, proximo_intento=NULL WHERE id=?", (obs, item["id"]))
    return item["id"]

# ===================== HISTORIAL =====================
def historial(filtros, limit=50, offset=0, db_path=DEFAULT_DB):
    def val(v): return v[0] if isinstance(v, list) else v
    where = []; args = []
    if filtros.get("fecha_desde"):
        where.append("fecha_hora >= ?"); args.append(val(filtros["fecha_desde"]))
    if filtros.get("fecha_hasta"):
        where.append("fecha_hora <= ?"); args.append(val(filtros["fecha_hasta"]))
    for k, col in (("codigo", "codigo"), ("cap_code", "cap_code"), ("estado", "estado"), ("interno", "interno_origen")):
        v = filtros.get(k); v = val(v) if v else ""
        if v:
            where.append("%s LIKE ?" % col); args.append("%%%s%%" % v)
    wsql = (" WHERE " + " AND ".join(where)) if where else ""
    with get_conn(db_path) as conn:
        total = conn.execute("SELECT COUNT(*) AS c FROM bitacora" + wsql, args).fetchone()["c"]
        rows = [dict(r) for r in conn.execute("SELECT * FROM bitacora" + wsql + " ORDER BY id DESC LIMIT ? OFFSET ?", args + [limit, offset])]
    return {"rows": rows, "total": total, "limit": limit, "offset": offset}

# ===================== AUTH =====================
def login_validar(user, passw, db_path=DEFAULT_DB):
    """Autentica al operador. Auto-repara la BD si falta la tabla config y
    nunca lanza: si la BD es inaccesible, usa admin/admin123 para que el panel
    nunca quede bloqueado por un problema de base de datos."""
    try:
        with get_conn(db_path) as conn:
            conn.execute("CREATE TABLE IF NOT EXISTS config (clave TEXT PRIMARY KEY, valor TEXT)")
            conn.execute("INSERT OR IGNORE INTO config (clave,valor) VALUES ('admin_user','admin')")
            conn.execute("INSERT OR IGNORE INTO config (clave,valor) VALUES ('admin_pass','admin123')")
        au = get_config("admin_user", "admin", db_path)
        ap = get_config("admin_pass", "admin123", db_path)
    except Exception:
        au, ap = "admin", "admin123"
    if user == au and passw == ap:
        tok = secrets.token_hex(16); _TOKENS[tok] = {"user": user, "exp": time.time() + 86400}
        return tok
    return None

def verificar_token(tok):
    v = _TOKENS.get(tok)
    if not v: return False
    exp = v.get("exp") if isinstance(v, dict) else None
    if not isinstance(exp, (int, float)):
        _TOKENS.pop(tok, None); return False
    if time.time() > exp:
        _TOKENS.pop(tok, None); return False
    return True

def token_user(tok, default="sistema"):
    """Devuelve el nombre del operador asociado al token (para auditoria)."""
    v = _TOKENS.get(tok)
    if not v: return default
    exp = v.get("exp") if isinstance(v, dict) else None
    if not isinstance(exp, (int, float)):
        _TOKENS.pop(tok, None); return default
    if time.time() > exp:
        _TOKENS.pop(tok, None); return default
    return v.get("user") or default

def cerrar_sesion(tok):
    _TOKENS.pop(tok, None)

# ===================== PLANTILLAS / PROGRAMADOS =====================
def listar_plantillas(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM plantillas ORDER BY orden,categoria,nombre")]

def crear_plantilla(data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        cur = conn.execute("INSERT INTO plantillas (nombre,mensaje,categoria,orden,activo) VALUES (?,?,?,?,1)",
            (data["nombre"], data["mensaje"], data.get("categoria", "general"), data.get("orden", 0)))
        return cur.lastrowid

def actualizar_plantilla(pid, data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE plantillas SET nombre=?,mensaje=?,categoria=?,orden=?,activo=? WHERE id=?",
            (data["nombre"], data["mensaje"], data.get("categoria", "general"), data.get("orden", 0),
             int(data.get("activo", 1)), pid))

def borrar_plantilla(pid, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM plantillas WHERE id=?", (pid,))

def listar_programados(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM envios_programados ORDER BY proxima_ejecucion")]

def crear_programado(data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        cur = conn.execute(
            "INSERT INTO envios_programados (codigo,mensaje,origen,tipo,fecha_programada,recurrencia_dia,"
            "recurrencia_hora,proxima_ejecucion,activo) VALUES (?,?,?,?,?,?,?,?,1)",
            (data["codigo"], data["mensaje"], data.get("origen", "web"), data.get("tipo", "unico"),
             data.get("fecha_programada"), int(data.get("recurrencia_dia", 0)), data.get("recurrencia_hora", "08:00"),
             data.get("fecha_programada") or data.get("proxima_ejecucion")))
        return cur.lastrowid

def actualizar_programado(pid, data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute(
            "UPDATE envios_programados SET codigo=?,mensaje=?,tipo=?,fecha_programada=?,recurrencia_dia=?,"
            "recurrencia_hora=?,proxima_ejecucion=?,activo=? WHERE id=?",
            (data["codigo"], data["mensaje"], data.get("tipo", "unico"), data.get("fecha_programada"),
             int(data.get("recurrencia_dia", 0)), data.get("recurrencia_hora", "08:00"),
             data.get("fecha_programada") or data.get("proxima_ejecucion"), int(data.get("activo", 1)), pid))

def borrar_programado(pid, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM envios_programados WHERE id=?", (pid,))

def procesar_programados(db_path=DEFAULT_DB):
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with get_conn(db_path) as conn:
        rows = conn.execute("SELECT * FROM envios_programados WHERE activo=1 AND proxima_ejecucion<=? ORDER BY proxima_ejecucion", (now,)).fetchall()
    for r in rows:
        r = dict(r)
        qid = encolar_mensaje(r["codigo"], None, r["mensaje"], 1200, r["origen"] or "programado", db_path)
        dest = resolver_destino(r["codigo"], db_path)
        if dest:
            with get_conn(db_path) as conn:
                conn.execute("UPDATE cola_envios SET cap_code=? WHERE id=?", (dest[0], qid))
        proxima = None
        hora = r["recurrencia_hora"] or "08:00"
        if r["tipo"] == "diario":
            nd = datetime.datetime.now() + datetime.timedelta(days=1)
            proxima = "%04d-%02d-%02d %s:00" % (nd.year, nd.month, nd.day, hora)
        elif r["tipo"] == "semanal":
            nd = datetime.datetime.now() + datetime.timedelta(weeks=1)
            proxima = "%04d-%02d-%02d %s:00" % (nd.year, nd.month, nd.day, hora)
        with get_conn(db_path) as conn:
            if proxima:
                conn.execute("UPDATE envios_programados SET ultima_ejecucion=?,proxima_ejecucion=? WHERE id=?", (now, proxima, r["id"]))
            else:
                conn.execute("UPDATE envios_programados SET ultima_ejecucion=?,activo=0 WHERE id=?", (now, r["id"]))

# ===================== AUDITORIA / STATS / LOGS =====================
def registrar_auditoria(usuario, accion, entidad, entidad_id, detalle, ip="", db_path=DEFAULT_DB):
    """Auditoria en SQLite. Best-effort: crea la tabla si no existe, nunca
    rompe la peticion que lo invoca."""
    try:
        with get_conn(db_path) as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS auditoria ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "fecha_hora TEXT, usuario TEXT, accion TEXT, entidad TEXT, "
                "entidad_id TEXT, detalle TEXT, ip TEXT)")
            conn.execute("INSERT INTO auditoria (fecha_hora,usuario,accion,entidad,entidad_id,detalle,ip) VALUES (?,?,?,?,?,?,?)",
                (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), usuario or "sistema", accion, entidad,
                 str(entidad_id or ""), detalle or "", ip or ""))
    except Exception:
        pass

def listar_auditoria(limit=200, offset=0, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        rows = [dict(r) for r in conn.execute("SELECT * FROM auditoria ORDER BY id DESC LIMIT ? OFFSET ?", (limit, offset))]
        total = conn.execute("SELECT COUNT(*) AS c FROM auditoria").fetchone()["c"]
    return {"rows": rows, "total": total}

def estadisticas(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        hoy = datetime.date.today().isoformat()
        hace30 = (datetime.date.today() - datetime.timedelta(days=30)).isoformat()
        por_dia = [dict(r) for r in conn.execute(
            "SELECT date(fecha_hora) AS dia, COUNT(*) AS total, "
            "SUM(CASE WHEN estado='enviado' THEN 1 ELSE 0 END) AS ok, "
            "SUM(CASE WHEN estado='error' THEN 1 ELSE 0 END) AS err "
            "FROM bitacora WHERE fecha_hora>=? GROUP BY date(fecha_hora) ORDER BY dia", (hace30,))]
        por_hora = [dict(r) for r in conn.execute(
            "SELECT strftime('%H',fecha_hora) AS hora, COUNT(*) AS total FROM bitacora "
            "WHERE date(fecha_hora)=? GROUP BY strftime('%H',fecha_hora) ORDER BY hora", (hoy,))]
        top_pagers = [dict(r) for r in conn.execute(
            "SELECT codigo, COUNT(*) AS total FROM bitacora WHERE fecha_hora>=? "
            "GROUP BY codigo ORDER BY total DESC LIMIT 10", (hace30,))]
        total_env = conn.execute("SELECT COUNT(*) AS c FROM bitacora").fetchone()["c"]
        total_ok = conn.execute("SELECT COUNT(*) AS c FROM bitacora WHERE estado='enviado'").fetchone()["c"]
        total_err = conn.execute("SELECT COUNT(*) AS c FROM bitacora WHERE estado='error'").fetchone()["c"]
    return {"por_dia": por_dia, "por_hora": por_hora, "top_pagers": top_pagers,
            "total_enviados": total_env, "total_ok": total_ok, "total_err": total_err, "cola": estado_cola(db_path)}

def registrar_log(nivel, origen, mensaje, db_path=DEFAULT_DB):
    """Log centralizado en SQLite (tabla logs). Best-effort: crea la tabla si
    no existe, nunca rompe la peticion que lo invoca."""
    try:
        with get_conn(db_path) as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS logs ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "fecha_hora TEXT, nivel TEXT, origen TEXT, mensaje TEXT)")
            conn.execute(
                "INSERT INTO logs (fecha_hora,nivel,origen,mensaje) VALUES (?,?,?,?)",
                (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                 str(nivel)[:16], str(origen)[:32], str(mensaje)[:500]))
    except Exception:
        pass

def leer_logs(tipo, limit=200, db_path=DEFAULT_DB):
    paths = {"asterisk": "/var/log/asterisk/messages", "api": "/opt/zetronpoc/logs/api.log",
             "cola": "/opt/zetronpoc/logs/cola.log", "install": "/var/log/zetronpoc-install.log",
             "scheduler": "/opt/zetronpoc/logs/scheduler.log"}
    path = paths.get(tipo)
    if not path or not os.path.exists(path):
        return {"lineas": [], "path": path or "desconocido"}
    try:
        with open(path, "r", errors="replace") as f:
            lineas = f.readlines()[-limit:]
        return {"lineas": [l.rstrip() for l in lineas], "path": path}
    except Exception as e:
        return {"lineas": [], "path": path, "error": str(e)}

# ===================== BACKUP / EMAIL =====================
def backup_db(db_path=DEFAULT_DB):
    import shutil, time
    backup_dir = os.path.join(os.path.dirname(db_path), "backups")
    os.makedirs(backup_dir, exist_ok=True)
    bf = os.path.join(backup_dir, "zetronpoc_backup_%s.db" % time.strftime("%Y%m%d_%H%M%S"))
    shutil.copy2(db_path, bf)
    return bf

def restore_db(file_data, db_path=DEFAULT_DB):
    import shutil
    bk = db_path + ".pre_restore"
    if os.path.exists(db_path): shutil.copy2(db_path, bk)
    with open(db_path, "wb") as f: f.write(file_data)
    return bk

def enviar_email(to, subject, body, attachment_path=None, db_path=DEFAULT_DB):
    import smtplib
    from email.mime.multipart import MIMEMultipart
    from email.mime.text import MIMEText
    from email.mime.base import MIMEBase
    from email import encoders
    host = get_config("smtp_host", "", db_path)
    if not host: return {"error": "SMTP no configurado"}
    port = int(get_config("smtp_port", "587", db_path))
    user = get_config("smtp_user", "", db_path)
    pwd = get_config("smtp_pass", "", db_path)
    frm = get_config("smtp_from", user, db_path) or user
    secure = get_config("smtp_secure", "tls", db_path)
    msg = MIMEMultipart(); msg["From"] = frm; msg["To"] = to; msg["Subject"] = subject
    msg.attach(MIMEText(body, "plain", "utf-8"))
    if attachment_path and os.path.exists(attachment_path):
        with open(attachment_path, "rb") as f:
            part = MIMEBase("application", "octet-stream"); part.set_payload(f.read()); encoders.encode_base64(part)
            part.add_header("Content-Disposition", 'attachment; filename="%s"' % os.path.basename(attachment_path))
            msg.attach(part)
    try:
        if secure == "ssl" or port == 465:
            server = smtplib.SMTP_SSL(host, port, timeout=30)
        else:
            server = smtplib.SMTP(host, port, timeout=30); server.ehlo()
            if secure == "tls": server.starttls(); server.ehlo()
        if user: server.login(user, pwd)
        server.sendmail(frm, [to], msg.as_string()); server.quit()
        return {"ok": True}
    except Exception as e:
        return {"error": str(e)}

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "init":
        init_db(); print("Base de datos inicializada.")
