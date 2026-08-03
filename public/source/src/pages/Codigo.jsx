import React, { useState, useEffect } from "react";
import { motion } from "framer-motion";
import { FileCode, Copy, Check, Server, Terminal } from "lucide-react";

const FILES = [
  { nombre: "frontend/index.html", ruta: "/opt/pocsag-server/frontend/index.html", url: "/frontend.html" },
  { nombre: "backend/app.py", ruta: "/opt/pocsag-server/backend/app.py", url: "/app.py" },
  { nombre: "database/db_manager.py", ruta: "/opt/pocsag-server/database/db_manager.py", url: "/db_manager.py" },
];

export default function Codigo() {
  const [activo, setActivo] = useState(0);
  const [copiado, setCopiado] = useState(false);
  const [contenidos, setContenidos] = useState({});
  const [errores, setErrores] = useState({});

  useEffect(() => {
    if (contenidos[activo] !== undefined || errores[activo]) return;
    let cancelled = false;
    fetch(FILES[activo].url)
      .then((r) => {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.text();
      })
      .then((t) => {
        if (!cancelled) setContenidos((c) => ({ ...c, [activo]: t }));
      })
      .catch((e) => {
        if (!cancelled) setErrores((er) => ({ ...er, [activo]: e.message }));
      });
    return () => {
      cancelled = true;
    };
  }, [activo, contenidos, errores]);

  const copiar = async () => {
    await navigator.clipboard.writeText(contenidos[activo] || "");
    setCopiado(true);
    setTimeout(() => setCopiado(false), 2000);
  };

  const f = FILES[activo];
  const codigo = contenidos[activo];
  const err = errores[activo];

  return (
    <div className="relative min-h-screen overflow-hidden bg-[#070b16] text-slate-100">
      <div className="pointer-events-none fixed inset-0 overflow-hidden">
        <div className="absolute -top-40 -right-40 w-[30rem] h-[30rem] rounded-full bg-indigo-500/15 blur-[120px]" />
        <div className="absolute bottom-0 -left-32 w-[28rem] h-[28rem] rounded-full bg-cyan-500/15 blur-[120px]" />
      </div>

      <div className="relative max-w-5xl mx-auto px-6 py-10">
        <motion.div
          initial={{ opacity: 0, y: 16 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5 }}
          className="flex items-center gap-3 mb-7"
        >
          <div className="w-12 h-12 rounded-3xl bg-gradient-to-br from-emerald-400 via-cyan-400 to-indigo-500 grid place-items-center shadow-xl shadow-cyan-500/30">
            <FileCode className="w-6 h-6 text-white" />
          </div>
          <div>
            <h1 className="text-xl font-bold tracking-tight bg-gradient-to-r from-white to-cyan-200 bg-clip-text text-transparent">
              Archivos del servidor
            </h1>
            <p className="text-sm text-slate-400">Codigo fuente para pegar en el servidor Ubuntu</p>
          </div>
        </motion.div>

        <motion.div
          initial={{ opacity: 0, y: 12 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.1 }}
          className="flex gap-2 mb-4 flex-wrap"
        >
          {FILES.map((file, i) => (
            <button
              key={file.nombre}
              onClick={() => setActivo(i)}
              className={`px-4 py-2 rounded-2xl text-sm font-mono transition-all ${
                i === activo
                  ? "bg-gradient-to-r from-emerald-500 via-cyan-500 to-indigo-500 text-white shadow-md shadow-cyan-500/30"
                  : "bg-white/[0.04] text-slate-300 hover:bg-white/[0.08] border border-white/10"
              }`}
            >
              {file.nombre}
            </button>
          ))}
        </motion.div>

        <motion.div
          initial={{ opacity: 0, y: 12 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.15 }}
          className="flex items-center justify-between mb-3 flex-wrap gap-2"
        >
          <p className="text-slate-400 text-sm flex items-center gap-2">
            <Server className="w-4 h-4 text-cyan-400" />
            Pegalo en <code className="text-emerald-400 font-mono">{f.ruta}</code>
          </p>
          <button
            onClick={copiar}
            disabled={!codigo}
            className="inline-flex items-center gap-2 bg-gradient-to-r from-emerald-500 to-cyan-500 hover:brightness-110 disabled:opacity-50 text-white font-semibold px-4 py-2 rounded-2xl transition-all text-sm shadow-md shadow-cyan-500/25"
          >
            {copiado ? <Check className="w-4 h-4" /> : <Copy className="w-4 h-4" />}
            {copiado ? "Copiado" : "Copiar codigo"}
          </button>
        </motion.div>

        <motion.div
          initial={{ opacity: 0, y: 12 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.2 }}
          className="rounded-3xl bg-black/40 border border-white/10 backdrop-blur-xl overflow-hidden"
        >
          {err ? (
            <div className="p-6 text-sm text-rose-300">
              No se pudo cargar el archivo ({err}). Verifica que exista en el servidor.
            </div>
          ) : codigo === undefined ? (
            <div className="p-6 text-sm text-slate-500 flex items-center gap-2">
              <span className="w-4 h-4 border-2 border-white/10 border-t-cyan-400 rounded-full animate-spin" />
              Cargando...
            </div>
          ) : (
            <pre className="p-5 overflow-auto text-xs leading-relaxed font-mono text-slate-300 max-h-[68vh]">
              <code>{codigo}</code>
            </pre>
          )}
        </motion.div>

        <div className="mt-4 flex items-center gap-2 text-xs text-slate-500">
          <Terminal className="w-3.5 h-3.5 text-cyan-400" />
          Despues de pegar los tres, reinicia el servicio:{" "}
          <code className="text-emerald-400 font-mono">sudo systemctl restart pocsag-api</code>
        </div>
      </div>
    </div>
  );
}