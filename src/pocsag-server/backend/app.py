#!/usr/bin/env python3
"""backend/app.py - API de gestión del sistema POCSAG (Flask, sin dependencias extra)."""
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, "/opt/pocsag-server")
from database.db_manager import listar_codigos, bitacora_reciente  # noqa: E402

HOST = os.environ.get("POCSAG_API_HOST", "0.0.0.0")
PORT = int(os.environ.get("POCSAG_API_PORT", "8080"))
FRONTEND_DIR = "/opt/pocsag-server/frontend"


def json_response(handler, data, code=200):
    import json
    body = json.dumps(data, ensure_ascii=False).encode("utf-8")
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class Handler(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")

    def do_GET(self):
        if self.path == "/api/codigos":
            return json_response(self, listar_codigos())
        if self.path == "/api/bitacora":
            return json_response(self, bitacora_reciente(50))
        if self.path == "/api/health":
            return json_response(self, {"status": "ok"})
        # Servir frontend estático
        if self.path == "/" or self.path == "/index.html":
            f = os.path.join(FRONTEND_DIR, "index.html")
            if os.path.exists(f):
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                with open(f, "rb") as fh:
                    self.wfile.write(fh.read())
                return
        self.send_response(404)
        self.end_headers()

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print(f"API POCSAG en http://{HOST}:{PORT}")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()