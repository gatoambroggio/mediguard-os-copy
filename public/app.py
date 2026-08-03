#!/usr/bin/env python3
import os, sys, json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
sys.path.insert(0, "/opt/pocsag-server")
from database.db_manager import listar_codigos, bitacora_reciente, crear_codigo, actualizar_codigo, borrar_codigo, enviar_mensaje

HOST=os.environ.get("POCSAG_API_HOST","0.0.0.0")
PORT=int(os.environ.get("POCSAG_API_PORT","8080"))
FRONT="/opt/pocsag-server/frontend"

def jr(h,d,c=200):
    b=json.dumps(d,ensure_ascii=False).encode()
    h.send_response(c); h.send_header("Content-Type","application/json; charset=utf-8")
    h.send_header("Content-Length",str(len(b))); h.end_headers(); h.wfile.write(b)

class H(BaseHTTPRequestHandler):
    def _body(self):
        n=int(self.headers.get("Content-Length",0))
        return json.loads(self.rfile.read(n)) if n else {}
    def do_GET(self):
        if self.path=="/api/codigos": return jr(self,listar_codigos())
        if self.path=="/api/bitacora": return jr(self,bitacora_reciente(50))
        if self.path=="/api/health": return jr(self,{"status":"ok"})
        if self.path in ("/","/index.html"):
            f=os.path.join(FRONT,"index.html")
            if os.path.exists(f):
                self.send_response(200); self.send_header("Content-Type","text/html; charset=utf-8"); self.end_headers()
                with open(f,"rb") as fh: self.wfile.write(fh.read()); return
        self.send_response(404); self.end_headers()
    def do_POST(self):
        try:
            d=self._body()
            if self.path=="/api/enviar":
                return jr(self, enviar_mensaje(d.get("codigo",""), d.get("mensaje",""), d.get("origen","web")))
            if self.path=="/api/codigos":
                crear_codigo(d.get("codigo",""), d.get("tipo","individual"), d.get("cap_code",""), int(d.get("baudios",1200)), d.get("descripcion",""))
                return jr(self,{"status":"ok"})
            if self.path=="/api/codigos/update":
                actualizar_codigo(d.get("codigo",""), d.get("tipo","individual"), d.get("cap_code",""), int(d.get("baudios",1200)), d.get("descripcion",""), int(d.get("activo",1)))
                return jr(self,{"status":"ok"})
            if self.path=="/api/codigos/delete":
                borrar_codigo(d.get("codigo",""))
                return jr(self,{"status":"ok"})
            self.send_response(404); self.end_headers()
        except Exception as e:
            return jr(self,{"status":"error","detalle":str(e)},500)
    def do_OPTIONS(self):
        self.send_response(204); self.send_header("Access-Control-Allow-Origin","*")
        self.send_header("Access-Control-Allow-Methods","GET,POST,OPTIONS")
        self.send_header("Access-Control-Allow-Headers","Content-Type"); self.end_headers()
    def log_message(self,*a): pass

if __name__=="__main__":
    print(f"API POCSAG en http://{HOST}:{PORT}")
    ThreadingHTTPServer((HOST,PORT),H).serve_forever()
