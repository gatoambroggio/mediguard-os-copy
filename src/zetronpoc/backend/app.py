#!/usr/bin/env python3
"""
app.py - ZetronPOC v2.0 - API REST + servidor de estaticos.
http.server puro (sin Flask) para maxima portabilidad. Puerto 8080.

Todas las mutaciones (login, envio, CRUD, apply, pbx, cola, db, config)
registran auditoria (tabla auditoria) y log centralizado (tabla logs).
El repo es la unica fuente de verdad.
"""
import os, sys, json, subprocess, io, time, csv, re, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APP_DIR = os.environ.get("ZETRONPOC_DIR", "/opt/zetronpoc")
sys.path.insert(0, APP_DIR)
sys.path.insert(0, os.path.join(APP_DIR, "database"))
import db_manager as db

HOST, PORT = "0.0.0.0", 8080
FRONT = os.path.join(APP_DIR, "frontend")
ALLOWED_PBX = re.compile(r'^(pjsip show|pjsip send|pjsip unregister|pjsip reload|core show|core restart|'
                         r'dialplan|module show|module reload|sip show|sip reload|iax2 show|reload)\b', re.I)

def jok(handler, data, code=200):
    body = json.dumps(data).encode("utf-8")
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)

def jtext(handler, text, code=200, ct="text/plain; charset=utf-8"):
    body = text.encode("utf-8")
    handler.send_response(code)
    handler.send_header("Content-Type", ct)
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)

def serve_file(handler, path, ct):
    if not os.path.exists(path):
        jtext(handler, "no encontrado", 404); return
    with open(path, "rb") as f: data = f.read()
    handler.send_response(200)
    handler.send_header("Content-Type", ct)
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)

def need_auth(handler):
    tok = handler.headers.get("Authorization", "").replace("Bearer ", "")
    return db.verificar_token(tok)

def _tok(handler):
    return handler.headers.get("Authorization", "").replace("Bearer ", "")

def _ip(handler):
    try: return handler.client_address[0] or ""
    except Exception:
        return ""

def aud(handler, accion, entidad, eid="", detalle=""):
    """Audita una mutacion. Nunca rompe la peticion."""
    try:
        db.registrar_auditoria(db.token_user(_tok(handler)), accion, entidad,
                               str(eid or ""), str(detalle or "")[:240], _ip(handler))
    except Exception:
        pass

def evlog(handler, nivel, origen, mensaje):
    """Log centralizado en la tabla logs."""
    try:
        db.registrar_log(nivel, origen, mensaje)
    except Exception:
        pass

def parse_rows_from_upload(filename, raw):
    rows = []
    if filename.lower().endswith(".csv"):
        text = raw.decode("utf-8", errors="replace")
        sniffer = csv.Sniffer()
        try: delim = sniffer.sniff(text).delimiter
        except Exception: delim = ","
        for r in csv.DictReader(io.StringIO(text), delimiter=delim):
            rows.append({k.strip(): v for k, v in r.items() if k})
    else:
        try:
            import openpyxl
        except ImportError:
            return None, "openpyxl no instalado"
        wb = openpyxl.load_workbook(io.BytesIO(raw), read_only=True)
        ws = wb.active
        keys = [str(c.value).strip() if c.value else "" for c in next(ws.iter_rows())]
        for row in ws.iter_rows(min_row=2):
            vals = [str(c.value).strip() if c.value is not None else "" for c in row]
            rows.append(dict(zip(keys, vals)))
    return rows, None

def pbx_run(cmd):
    if not ALLOWED_PBX.match(cmd):
        return {"error": "comando no permitido"}
    try:
        out = subprocess.run(["asterisk", "-rx", cmd], capture_output=True, text=True, timeout=15)
        return {"salida": (out.stdout or out.stderr or "")[:8000]}
    except Exception as e:
        return {"error": str(e)}

def ext_status():
    out = {}
    try:
        r = subprocess.run(["asterisk", "-rx", "pjsip show registrations"], capture_output=True, text=True, timeout=10)
        for line in (r.stdout or "").splitlines():
            m = re.match(r'\s*(\w+)/(.*?)\s+(\w+)\s+(\S+)', line)
            if m and m.group(3) in ("Registered", "Rejected", "Unregistered", "Trying", "Auth", "Sent"):
                out[m.group(1)] = m.group(3)
    except Exception:
        pass
    return out

def diagnose():
    ip = db.get_config("hospital_pbx_ip", "")
    puerto = db.get_config("hospital_pbx_port", "5060")
    pasos = []
    pr = subprocess.run(["ping", "-c", "2", "-W", "2", ip], capture_output=True, text=True, timeout=10) if ip else None
    pasos.append({"paso": "Ping a central %s" % ip, "ok": bool(pr and pr.returncode == 0),
                  "salida": (pr.stdout or pr.stderr or "sin IP")[-400:]})
    sr = subprocess.run(["bash", "-c", "timeout 3 bash -c 'echo > /dev/tcp/%s/%s' 2>&1" % (ip, puerto)],
                        capture_output=True, text=True) if ip else None
    pasos.append({"paso": "Puerto SIP %s:%s" % (ip, puerto), "ok": bool(sr and sr.returncode == 0),
                  "salida": "OK" if sr and sr.returncode == 0 else "cerrado/inaccesible"})
    conf = ""
    try:
        with open("/etc/asterisk/pjsip.conf") as f: conf = f.read()[:4000]
    except Exception as e:
        conf = "No existe: %s" % e
    reg = pbx_run("pjsip show registrations")["salida"]
    return {"ip": ip, "puerto": puerto, "pasos": pasos,
            "pjsip_conf": conf, "registros": reg,
            "transportes": pbx_run("pjsip show transports")["salida"],
            "log_pjsip": ""}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _body(self):
        n = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(n) if n else b""

    def _json(self):
        try: return json.loads(self._body() or "{}")
        except Exception: return {}

    def do_GET(self):
        try: return self._get()
        except Exception as e:
            import traceback; traceback.print_exc()
            try: return jok(self, {"error": str(e)}, 500)
            except Exception: pass
    def _get(self):
        u = urllib.parse.urlparse(self.path); p = u.path; q = urllib.parse.parse_qs(u.query)
        if p == "/" or p == "/index.html": return serve_file(self, os.path.join(FRONT, "index.html"), "text/html; charset=utf-8")
        if p == "/admin" or p == "/admin.html": return serve_file(self, os.path.join(FRONT, "admin.html"), "text/html; charset=utf-8")
        if p == "/api/health": return jok(self, {"status": "ok", "ts": int(time.time())})
        if p == "/api/version": return jok(self, {"version": db.get_config("version", "2.0")})
        if p == "/api/theme": return jok(self, db.all_config())
        if p == "/api/pagers": return jok(self, db.buscar_pagers(q.get("q", [""])[0]))
        if p == "/api/grupos": return jok(self, db.buscar_grupos(q.get("q", [""])[0]))
        if p == "/api/historial/public":
            return jok(self, db.historial({}, 100, 0))
        if p == "/api/login": return jtext(self, "use POST", 405)
        if not need_auth(self): return jok(self, {"error": "no autorizado"}, 401)

        if p == "/api/config": return jok(self, db.all_config())
        if p == "/api/mmdvm/config": return jok(self, {k: v for k, v in db.all_config().items() if k.startswith("mmdvm_")})
        if p == "/api/extensions": return jok(self, db.listar_extensiones())
        if p == "/api/extensions/status": return jok(self, ext_status())
        if p == "/api/plantillas": return jok(self, db.listar_plantillas())
        if p == "/api/programados": return jok(self, db.listar_programados())
        if p == "/api/auditoria":
            return jok(self, db.listar_auditoria(int(q.get("limit", ["200"])[0]), int(q.get("offset", ["0"])[0])))
        if p == "/api/logs":
            tipo = q.get("tipo", ["api"])[0]
            # logs en BD (tabla logs) cuando tipo=db
            if tipo == "db":
                with db.get_conn() as conn:
                    rows = [dict(r) for r in conn.execute(
                        "SELECT fecha_hora,nivel,origen,mensaje FROM logs ORDER BY id DESC LIMIT ?",
                        (int(q.get("limit", ["300"])[0]),))]
                return jok(self, {"lineas": ["%s [%s] %s: %s" % (r["fecha_hora"], r["nivel"], r["origen"], r["mensaje"]) for r in rows], "path": "sqlite:logs"})
            return jok(self, db.leer_logs(tipo, int(q.get("limit", ["300"])[0])))
        if p == "/api/stats": return jok(self, db.estadisticas())
        if p == "/api/cola": return jok(self, db.listar_cola(q.get("estado", [None])[0], int(q.get("limit", ["200"])[0])))
        if p == "/api/cola/estado": return jok(self, db.estado_cola())
        if p == "/api/historial":
            f = {k: q[k][0] for k in q if k not in ("limit", "offset")}
            return jok(self, db.historial(f, int(q.get("limit", ["50"])[0]), int(q.get("offset", ["0"])[0])))
        if p == "/api/historial/export":
            f = {k: q[k][0] for k in q}
            res = db.historial(f, 10000, 0)["rows"]
            out = io.StringIO()
            w = csv.writer(out); w.writerow(["fecha_hora","interno","codigo","cap_code","mensaje","baudios","estado","obs"])
            for r in res: w.writerow([r.get("fecha_hora"), r.get("interno_origen"), r.get("codigo"), r.get("cap_code"), r.get("mensaje"), r.get("baudios"), r.get("estado"), r.get("observaciones")])
            return jtext(self, out.getvalue(), 200, "text/csv; charset=utf-8")
        if p == "/api/db/backup":
            bf = db.backup_db()
            with open(bf, "rb") as f: data = f.read()
            self.send_response(200); self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="%s"' % os.path.basename(bf))
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        if p == "/api/pbx": return jok(self, pbx_run(q.get("cmd", [""])[0]))
        if p == "/api/pbx/diagnose": return jok(self, diagnose())
        if p == "/api/mmdvm/status":
            bin_ok = os.path.exists("/usr/local/bin/MMDVM-Host")
            svc = "unknown"
            try:
                r = subprocess.run(["systemctl", "is-active", "mmdvmhost"], capture_output=True, text=True, timeout=5)
                svc = (r.stdout or "").strip() or "unknown"
            except Exception:
                pass
            return jok(self, {"installed": bin_ok, "service": svc, "binary": "/usr/local/bin/MMDVM-Host" if bin_ok else None})
        return jtext(self, "no encontrado", 404)

    def do_POST(self):
        try: return self._post()
        except Exception as e:
            import traceback; traceback.print_exc()
            try: return jok(self, {"error": str(e)}, 500)
            except Exception: pass
    def _post(self):
        u = urllib.parse.urlparse(self.path); p = u.path
        if p == "/api/login":
            d = self._json()
            user = d.get("user", "")
            try:
                tok = db.login_validar(user, d.get("pass", ""))
            except Exception as e:
                evlog(self, "error", "api", "login_validar fallo: %s" % str(e)[:120])
                return jok(self, {"error": "base de datos no disponible"}, 401)
            ok = bool(tok)
            try:
                db.registrar_auditoria(user or "?", "login", "auth", "", "ok" if ok else "credenciales invalidas", _ip(self))
            except Exception:
                pass
            evlog(self, "info" if ok else "warn", "api", "login user=%s %s" % (user, "ok" if ok else "fail"))
            if tok: return jok(self, {"token": tok})
            return jok(self, {"error": "credenciales invalidas"}, 401)
        if p == "/api/enviar":
            d = self._json()
            codigo = d.get("codigo", ""); mensaje = d.get("mensaje", ""); origen = d.get("origen", "web")
            res = db.enviar_mensaje(codigo, mensaje, origen)
            # auditar como sistema (endpoint publico) con el origen declarado
            try:
                db.registrar_auditoria(origen or "web", "enviar", "mensaje", str(res.get("id", "")),
                                        "codigo=%s estado=%s" % (codigo, res.get("status", "")), _ip(self))
            except Exception:
                pass
            evlog(self, "info", "api", "enviar codigo=%s estado=%s" % (codigo, res.get("status", "")))
            return jok(self, res)
        if not need_auth(self): return jok(self, {"error": "no autorizado"}, 401)
        d = self._json()
        if p == "/api/mmdvm/apply":
            for k, v in d.items():
                if k.startswith("mmdvm_"):
                    db.set_config(k, "" if v is None else str(v))
            ok, msg = db.generar_mmdvm_ini()
            if not ok:
                aud(self, "aplicar", "mmdvm", "", "fallo: %s" % msg)
                evlog(self, "error", "mmdvm", "apply fallo: %s" % msg)
                return jok(self, {"ok": False, "error": "No se pudo generar MMDVM.ini: %s" % msg})
            try:
                r = subprocess.run(["systemctl", "restart", "mmdvmhost"], capture_output=True, text=True, timeout=20)
            except FileNotFoundError:
                aud(self, "aplicar", "mmdvm", "", "systemctl no disponible")
                return jok(self, {"ok": False, "error": "MMDVM.ini generado, pero systemctl no esta disponible en este host."})
            except subprocess.TimeoutExpired:
                aud(self, "aplicar", "mmdvm", "", "timeout restart")
                return jok(self, {"ok": False, "error": "MMDVM.ini generado, pero el reinicio de mmdvmhost demoro demasiado."})
            if r.returncode != 0:
                svc_err = (r.stderr or r.stdout or "").strip()
                aud(self, "aplicar", "mmdvm", "", "restart fallo: %s" % svc_err[:120])
                evlog(self, "error", "mmdvm", "restart fallo: %s" % svc_err[:200])
                return jok(self, {"ok": False, "error": "MMDVM.ini generado en %s, pero fallo reiniciar el servicio 'mmdvmhost': %s" % (db.MMDVM_INI, svc_err or "verifique que MMDVMHost este instalado")})
            aud(self, "aplicar", "mmdvm", "", "ok")
            evlog(self, "info", "mmdvm", "apply ok en %s" % db.MMDVM_INI)
            return jok(self, {"ok": True, "salida": "MMDVM.ini generado en %s y servicio mmdvmhost reiniciado." % db.MMDVM_INI, "ini": db.MMDVM_INI})
        if p == "/api/mmdvm/install":
            url = "https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/instalador_mmdvm.sh"
            aud(self, "instalar", "mmdvm", "", "inicio")
            evlog(self, "info", "mmdvm", "install inicio")
            try:
                r = subprocess.run(["bash", "-c", "curl -fsSL %s | bash" % url],
                                   capture_output=True, text=True, timeout=600)
                out = (r.stdout or "") + (r.stderr or "")
                aud(self, "instalar", "mmdvm", "", "rc=%s" % r.returncode)
                evlog(self, "info" if r.returncode == 0 else "error", "mmdvm", "install rc=%s" % r.returncode)
                return jok(self, {"ok": r.returncode == 0, "salida": out[-12000:], "code": r.returncode})
            except subprocess.TimeoutExpired:
                aud(self, "instalar", "mmdvm", "", "timeout")
                return jok(self, {"ok": False, "error": "La instalacion demoro mas de 10 minutos. Revisa: journalctl -u mmdvmhost"})
            except Exception as e:
                aud(self, "instalar", "mmdvm", "", "excepcion: %s" % str(e)[:120])
                return jok(self, {"ok": False, "error": str(e)})
        if p == "/api/extensions":
            nid = db.crear_extension(d)
            aud(self, "crear", "extension", nid, d.get("numero", ""))
            return jok(self, {"id": nid})
        if p == "/api/extensions/aplicar":
            ok, msg = db.generar_pjsip_conf()
            if ok:
                subprocess.run(["asterisk", "-rx", "pjsip reload"], capture_output=True, timeout=10)
                subprocess.run(["asterisk", "-rx", "pjsip send register"], capture_output=True, timeout=10)
            aud(self, "aplicar", "extensiones", "", "ok" if ok else "fallo: %s" % msg)
            evlog(self, "info" if ok else "error", "pbx", "extensions/aplicar %s" % msg[:80])
            return jok(self, {"ok": ok, "salida": msg})
        if p == "/api/pagers":
            nid = db.crear_pager(d)
            aud(self, "crear", "pager", nid, d.get("codigo", ""))
            return jok(self, {"id": nid})
        if p == "/api/pagers/import":
            fn = urllib.parse.unquote(self.headers.get("X-Filename", "import.csv"))
            rows, err = parse_rows_from_upload(fn, self._body())
            if err: return jok(self, {"error": err})
            res = db.importar_pagers(rows)
            aud(self, "importar", "pagers", "", "ok=%s err=%s" % (res.get("importados"), res.get("errores")))
            return jok(self, res)
        if p == "/api/grupos":
            nid = db.crear_grupo(d)
            aud(self, "crear", "grupo", nid, d.get("codigo", ""))
            return jok(self, {"id": nid})
        if p == "/api/grupos/import":
            fn = urllib.parse.unquote(self.headers.get("X-Filename", "import.csv"))
            rows, err = parse_rows_from_upload(fn, self._body())
            if err: return jok(self, {"error": err})
            res = db.importar_grupos(rows)
            aud(self, "importar", "grupos", "", "ok=%s err=%s" % (res.get("importados"), res.get("errores")))
            return jok(self, res)
        if p == "/api/plantillas":
            nid = db.crear_plantilla(d)
            aud(self, "crear", "plantilla", nid, d.get("nombre", ""))
            return jok(self, {"id": nid})
        if p == "/api/programados":
            nid = db.crear_programado(d)
            aud(self, "crear", "programado", nid, d.get("codigo", ""))
            return jok(self, {"id": nid})
        if p == "/api/cola/reintentar":
            cid = int(d.get("id", 0))
            db.reintentar_cola(cid)
            aud(self, "reintentar", "cola", cid, "")
            return jok(self, {"ok": True})
        if p == "/api/cola/limpiar":
            db.limpiar_cola()
            aud(self, "limpiar", "cola", "", "")
            return jok(self, {"ok": True})
        if p == "/api/pbx/reload":
            r1 = pbx_run("pjsip reload"); r2 = pbx_run("dialplan reload")
            aud(self, "reload", "pbx", "", "pjsip+dialplan")
            evlog(self, "info", "pbx", "reload")
            return jok(self, {"salida": r1.get("salida", "") + "\n" + r2.get("salida", "")})
        if p == "/api/pbx/restart":
            r = subprocess.run(["systemctl", "restart", "asterisk"], capture_output=True, text=True, timeout=20)
            aud(self, "restart", "pbx", "", "")
            evlog(self, "warn", "pbx", "restart")
            return jok(self, {"salida": r.stdout or r.stderr or "reiniciado"})
        if p == "/api/pbx/force-register":
            r = pbx_run("pjsip send register")
            aud(self, "force-register", "pbx", "", "")
            return jok(self, {"salida": r.get("salida", "ok")})
        if p == "/api/pbx/unregister":
            r = pbx_run("pjsip unregister")
            aud(self, "unregister", "pbx", "", "")
            return jok(self, {"salida": r.get("salida", "ok")})
        if p == "/api/pbx/run":
            cmd = d.get("cmd", "")
            res = pbx_run(cmd)
            aud(self, "run", "pbx", "", cmd[:120])
            evlog(self, "info", "pbx", "run: %s" % cmd[:120])
            return jok(self, res)
        if p == "/api/db/backup-email":
            bf = db.backup_db()
            r = db.enviar_email(db.get_config("backup_email"), "Backup ZetronPOC", "Backup adjunto.", bf)
            aud(self, "backup-email", "db", "", "ok" if "ok" in r else "fallo")
            return jok(self, r if "ok" in r else {"error": r.get("error", "fallo")})
        if p == "/api/db/restore":
            data = self._body()
            db.restore_db(data)
            aud(self, "restore", "db", "", "")
            evlog(self, "warn", "db", "restore")
            return jok(self, {"ok": True})
        if p == "/api/smtp/test":
            email = d.get("email", db.get_config("backup_email"))
            r = db.enviar_email(email, "ZetronPOC - test SMTP", "Prueba OK")
            aud(self, "test", "smtp", "", email or "")
            return jok(self, r if "ok" in r else {"error": r.get("error", "fallo")})
        return jtext(self, "no encontrado", 404)

    def do_PUT(self):
        try: return self._put()
        except Exception as e:
            import traceback; traceback.print_exc()
            try: return jok(self, {"error": str(e)}, 500)
            except Exception: pass
    def _put(self):
        if not need_auth(self): return jok(self, {"error": "no autorizado"}, 401)
        u = urllib.parse.urlparse(self.path); p = u.path; d = self._json()
        if p == "/api/config":
            keys = list(d.keys())
            for k, v in d.items(): db.set_config(k, "" if v is None else str(v))
            aud(self, "guardar", "config", "", "keys=%s" % ",".join(keys)[:200])
            evlog(self, "info", "config", "guardar %d keys" % len(keys))
            return jok(self, {"ok": True})
        m = re.match(r'/api/extensions/(\d+)$', p)
        if m:
            db.actualizar_extension(int(m.group(1)), d)
            aud(self, "actualizar", "extension", m.group(1), d.get("numero", ""))
            return jok(self, {"ok": True})
        m = re.match(r'/api/pagers/(\d+)$', p)
        if m:
            db.actualizar_pager(int(m.group(1)), d)
            aud(self, "actualizar", "pager", m.group(1), d.get("codigo", ""))
            return jok(self, {"ok": True})
        m = re.match(r'/api/pagers/(\d+)/estado$', p)
        if m:
            db.toggle_pager(int(m.group(1)), int(d.get("activo", 1)))
            aud(self, "toggle", "pager", m.group(1), "activo=%s" % d.get("activo", 1))
            return jok(self, {"ok": True})
        m = re.match(r'/api/grupos/(\d+)$', p)
        if m:
            db.actualizar_grupo(int(m.group(1)), d)
            aud(self, "actualizar", "grupo", m.group(1), d.get("codigo", ""))
            return jok(self, {"ok": True})
        m = re.match(r'/api/plantillas/(\d+)$', p)
        if m:
            db.actualizar_plantilla(int(m.group(1)), d)
            aud(self, "actualizar", "plantilla", m.group(1), d.get("nombre", ""))
            return jok(self, {"ok": True})
        m = re.match(r'/api/programados/(\d+)$', p)
        if m:
            db.actualizar_programado(int(m.group(1)), d)
            aud(self, "actualizar", "programado", m.group(1), d.get("codigo", ""))
            return jok(self, {"ok": True})
        return jtext(self, "no encontrado", 404)

    def do_DELETE(self):
        try: return self._delete()
        except Exception as e:
            import traceback; traceback.print_exc()
            try: return jok(self, {"error": str(e)}, 500)
            except Exception: pass
    def _delete(self):
        if not need_auth(self): return jok(self, {"error": "no autorizado"}, 401)
        p = urllib.parse.urlparse(self.path).path
        m = re.match(r'/api/extensions/(\d+)$', p)
        if m:
            db.borrar_extension(int(m.group(1)))
            aud(self, "borrar", "extension", m.group(1), "")
            return jok(self, {"ok": True})
        m = re.match(r'/api/pagers/(\d+)$', p)
        if m:
            db.borrar_pager(int(m.group(1)))
            aud(self, "borrar", "pager", m.group(1), "")
            return jok(self, {"ok": True})
        m = re.match(r'/api/grupos/(\d+)$', p)
        if m:
            db.borrar_grupo(int(m.group(1)))
            aud(self, "borrar", "grupo", m.group(1), "")
            return jok(self, {"ok": True})
        m = re.match(r'/api/plantillas/(\d+)$', p)
        if m:
            db.borrar_plantilla(int(m.group(1)))
            aud(self, "borrar", "plantilla", m.group(1), "")
            return jok(self, {"ok": True})
        m = re.match(r'/api/programados/(\d+)$', p)
        if m:
            db.borrar_programado(int(m.group(1)))
            aud(self, "borrar", "programado", m.group(1), "")
            return jok(self, {"ok": True})
        return jtext(self, "no encontrado", 404)

class Server(ThreadingHTTPServer):
    daemon_threads = True

def _auto_init_db():
    """Garantiza que la base y sus tablas existen al arrancar. Idempotente
    (schema.sql usa CREATE TABLE IF NOT EXISTS). Nunca bloquea el arranque."""
    try:
        db.init_db()
        print("[init] Base de datos verificada/creada.", flush=True)
    except Exception as e:
        print("[init] WARN: no se pudo inicializar la base: %s" % e, flush=True)

if __name__ == "__main__":
    try:
        os.makedirs(os.path.join(APP_DIR, "logs"), exist_ok=True)
        _auto_init_db()
        print("ZetronPOC v2.0 API en http://%s:%d" % (HOST, PORT), flush=True)
        Server((HOST, PORT), Handler).serve_forever()
    except Exception:
        import traceback
        traceback.print_exc()
        raise