#!/usr/bin/env python3
"""
app.py - ZetronPOC v2.0 - API REST + servidor de estaticos.
http.server puro (sin Flask) para maxima portabilidad. Puerto 8080.
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
    # 1 ping
    pr = subprocess.run(["ping", "-c", "2", "-W", "2", ip], capture_output=True, text=True, timeout=10) if ip else None
    pasos.append({"paso": "Ping a central %s" % ip, "ok": bool(pr and pr.returncode == 0),
                  "salida": (pr.stdout or pr.stderr or "sin IP")[-400:]})
    # 2 sip port
    sr = subprocess.run(["bash", "-c", "timeout 3 bash -c 'echo > /dev/tcp/%s/%s' 2>&1" % (ip, puerto)],
                        capture_output=True, text=True) if ip else None
    pasos.append({"paso": "Puerto SIP %s:%s" % (ip, puerto), "ok": bool(sr and sr.returncode == 0),
                  "salida": "OK" if sr and sr.returncode == 0 else "cerrado/inaccesible"})
    # 3 pjsip conf
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
        u = urllib.parse.urlparse(self.path); p = u.path; q = urllib.parse.parse_qs(u.query)
        # estaticos
        if p == "/" or p == "/index.html": return serve_file(self, os.path.join(FRONT, "index.html"), "text/html; charset=utf-8")
        if p == "/admin" or p == "/admin.html": return serve_file(self, os.path.join(FRONT, "admin.html"), "text/html; charset=utf-8")
        # publicos
        if p == "/api/health": return jok(self, {"status": "ok", "ts": int(time.time())})
        if p == "/api/version": return jok(self, {"version": db.get_config("version", "2.0")})
        if p == "/api/theme": return jok(self, db.all_config())
        if p == "/api/login": return jtext(self, "use POST", 405)
        # auth
        if not need_auth(self): return jok(self, {"error": "no autorizado"}, 401)

        if p == "/api/config": return jok(self, db.all_config())
        if p == "/api/extensions": return jok(self, db.listar_extensiones())
        if p == "/api/extensions/status": return jok(self, ext_status())
        if p == "/api/pagers": return jok(self, db.buscar_pagers(q.get("q", [""])[0]))
        if p == "/api/grupos": return jok(self, db.buscar_grupos(q.get("q", [""])[0]))
        if p == "/api/plantillas": return jok(self, db.listar_plantillas())
        if p == "/api/programados": return jok(self, db.listar_programados())
        if p == "/api/auditoria": return jok(self, db.listar_auditoria(int(q.get("limit", ["200"])[0])))
        if p == "/api/stats": return jok(self, db.estadisticas())
        if p == "/api/cola": return jok(self, db.listar_cola(q.get("estado", [None])[0], int(q.get("limit", ["200"])[0])))
        if p == "/api/cola/estado": return jok(self, db.estado_cola())
        if p == "/api/logs": return jok(self, db.leer_logs(q.get("tipo", ["api"])[0], int(q.get("limit", ["300"])[0])))
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
        return jtext(self, "no encontrado", 404)

    def do_POST(self):
        u = urllib.parse.urlparse(self.path); p = u.path
        if p == "/api/login":
            d = self._json()
            tok = db.login_validar(d.get("user", ""), d.get("pass", ""))
            if tok: return jok(self, {"token": tok})
            return jok(self, {"error": "credenciales invalidas"}, 401)
        if not need_auth(self): return jok(self, {"error": "no autorizado"}, 401)
        d = self._json()
        if p == "/api/enviar": return jok(self, db.enviar_mensaje(d.get("codigo"), d.get("mensaje"), d.get("origen", "web")))
        if p == "/api/extensions":
            return jok(self, {"id": db.crear_extension(d)})
        if p == "/api/extensions/aplicar":
            ok, msg = db.generar_pjsip_conf()
            if ok:
                subprocess.run(["asterisk", "-rx", "pjsip reload"], capture_output=True, timeout=10)
                subprocess.run(["asterisk", "-rx", "pjsip send register"], capture_output=True, timeout=10)
            return jok(self, {"ok": ok, "salida": msg})
        if p == "/api/pagers":
            return jok(self, {"id": db.crear_pager(d)})
        if p == "/api/pagers/import":
            fn = urllib.parse.unquote(self.headers.get("X-Filename", "import.csv"))
            rows, err = parse_rows_from_upload(fn, self._body())
            if err: return jok(self, {"error": err})
            return jok(self, db.importar_pagers(rows))
        if p == "/api/grupos":
            return jok(self, {"id": db.crear_grupo(d)})
        if p == "/api/grupos/import":
            fn = urllib.parse.unquote(self.headers.get("X-Filename", "import.csv"))
            rows, err = parse_rows_from_upload(fn, self._body())
            if err: return jok(self, {"error": err})
            return jok(self, db.importar_grupos(rows))
        if p == "/api/plantillas":
            return jok(self, {"id": db.crear_plantilla(d)})
        if p == "/api/programados":
            return jok(self, {"id": db.crear_programado(d)})
        if p == "/api/cola/reintentar":
            db.reintentar_cola(int(d.get("id", 0))); return jok(self, {"ok": True})
        if p == "/api/cola/limpiar":
            db.limpiar_cola(); return jok(self, {"ok": True})
        if p == "/api/pbx/reload":
            r1 = pbx_run("pjsip reload"); r2 = pbx_run("dialplan reload")
            return jok(self, {"salida": r1.get("salida", "") + "\n" + r2.get("salida", "")})
        if p == "/api/pbx/restart":
            r = subprocess.run(["systemctl", "restart", "asterisk"], capture_output=True, text=True, timeout=20)
            return jok(self, {"salida": r.stdout or r.stderr or "reiniciado"})
        if p == "/api/pbx/force-register":
            r = pbx_run("pjsip send register")
            return jok(self, {"salida": r.get("salida", "ok")})
        if p == "/api/pbx/unregister":
            r = pbx_run("pjsip unregister")
            return jok(self, {"salida": r.get("salida", "ok")})
        if p == "/api/pbx/run":
            return jok(self, pbx_run(d.get("cmd", "")))
        if p == "/api/db/backup-email":
            bf = db.backup_db()
            r = db.enviar_email(db.get_config("backup_email"), "Backup ZetronPOC", "Backup adjunto.", bf)
            return jok(self, r if "ok" in r else {"error": r.get("error", "fallo")})
        if p == "/api/db/restore":
            data = self._body()
            db.restore_db(data); return jok(self, {"ok": True})
        if p == "/api/smtp/test":
            email = d.get("email", db.get_config("backup_email"))
            r = db.enviar_email(email, "ZetronPOC - test SMTP", "Prueba OK")
            return jok(self, r if "ok" in r else {"error": r.get("error", "fallo")})
        return jtext(self, "no encontrado", 404)

    def do_PUT(self):
        if not need_auth(self): return jok(self, {"error": "no autorizado"}, 401)
        u = urllib.parse.urlparse(self.path); p = u.path; d = self._json()
        if p == "/api/config":
            for k, v in d.items(): db.set_config(k, str(v))
            return jok(self, {"ok": True})
        m = re.match(r'/api/extensions/(\d+)$', p)
        if m: db.actualizar_extension(int(m.group(1)), d); return jok(self, {"ok": True})
        m = re.match(r'/api/pagers/(\d+)$', p)
        if m: db.actualizar_pager(int(m.group(1)), d); return jok(self, {"ok": True})
        m = re.match(r'/api/pagers/(\d+)/estado$', p)
        if m: db.toggle_pager(int(m.group(1)), int(d.get("activo", 1))); return jok(self, {"ok": True})
        m = re.match(r'/api/grupos/(\d+)$', p)
        if m: db.actualizar_grupo(int(m.group(1)), d); return jok(self, {"ok": True})
        m = re.match(r'/api/plantillas/(\d+)$', p)
        if m: db.actualizar_plantilla(int(m.group(1)), d); return jok(self, {"ok": True})
        m = re.match(r'/api/programados/(\d+)$', p)
        if m: db.actualizar_programado(int(m.group(1)), d); return jok(self, {"ok": True})
        return jtext(self, "no encontrado", 404)

    def do_DELETE(self):
        if not need_auth(self): return jok(self, {"error": "no autorizado"}, 401)
        p = urllib.parse.urlparse(self.path).path
        m = re.match(r'/api/extensions/(\d+)$', p)
        if m: db.borrar_extension(int(m.group(1))); return jok(self, {"ok": True})
        m = re.match(r'/api/pagers/(\d+)$', p)
        if m: db.borrar_pager(int(m.group(1))); return jok(self, {"ok": True})
        m = re.match(r'/api/grupos/(\d+)$', p)
        if m: db.borrar_grupo(int(m.group(1))); return jok(self, {"ok": True})
        m = re.match(r'/api/plantillas/(\d+)$', p)
        if m: db.borrar_plantilla(int(m.group(1))); return jok(self, {"ok": True})
        m = re.match(r'/api/programados/(\d+)$', p)
        if m: db.borrar_programado(int(m.group(1))); return jok(self, {"ok": True})
        return jtext(self, "no encontrado", 404)

class Server(ThreadingHTTPServer):
    daemon_threads = True

if __name__ == "__main__":
    try:
        os.makedirs(os.path.join(APP_DIR, "logs"), exist_ok=True)
        print("ZetronPOC v2.0 API en http://%s:%d" % (HOST, PORT), flush=True)
        Server((HOST, PORT), Handler).serve_forever()
    except Exception:
        import traceback
        traceback.print_exc()
        raise