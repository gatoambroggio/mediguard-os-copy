import React, { useState } from "react";
import { motion } from "framer-motion";
import { Copy, Check, Send, Binary, Hash, FlaskConical, ListChecks } from "lucide-react";

// Patrones numéricos (page_bcd): un solo bit puesto por pasada para aislar cada
// bit del campo de mensaje de 20 bits (5 nibbles).
const NUMERIC_PATTERNS = [
  { msg: "10000", note: "Nibble 0 · bit 0 (valor 1)" },
  { msg: "20000", note: "Nibble 0 · bit 1 (valor 2)" },
  { msg: "40000", note: "Nibble 0 · bit 2 (valor 4)" },
  { msg: "80000", note: "Nibble 0 · bit 3 (valor 8)" },
  { msg: "01000", note: "Nibble 1 · bit 0 (valor 1)" },
  { msg: "00100", note: "Nibble 2 · bit 0 (valor 1)" },
  { msg: "00010", note: "Nibble 3 · bit 0 (valor 1)" },
  { msg: "00001", note: "Nibble 4 · bit 0 (valor 1)" },
];

// Patrones alfanuméricos (page): caracteres ASCII con bit-pattern conocido.
const ALPHA_PATTERNS = [
  { msg: "@@@@@", note: "ASCII 0x40 = 01000000 · solo bit 6" },
  { msg: "     ", note: "ASCII 0x20 = 00100000 · solo bit 5 (5 espacios)" },
  { msg: "AAAAA", note: "ASCII 0x41 = 01000001" },
  { msg: "PPPPP", note: "ASCII 0x50 = 01010000" },
  { msg: "aaaaa", note: "ASCII 0x61 = 01100001" },
];

function buildCmd(cap, mode, msg) {
  const c = (cap || "").trim() || "1234567";
  const m = msg == null ? "" : msg;
  if (mode === "numeric") return `/opt/zetronpoc/agi/dispatch_mqtt.py --bcd ${c} "${m}"`;
  return `/opt/zetronpoc/agi/dispatch_mqtt.py ${c} "${m}"`;
}

export default function TestPagePanel() {
  const [cap, setCap] = useState("1234567");
  const [mode, setMode] = useState("numeric");
  const [msg, setMsg] = useState("10000");
  const [copied, setCopied] = useState("");

  const cmd = buildCmd(cap, mode, msg);
  const patterns = mode === "numeric" ? NUMERIC_PATTERNS : ALPHA_PATTERNS;

  const copiar = (txt, id) => {
    navigator.clipboard.writeText(txt);
    setCopied(id);
    setTimeout(() => setCopied(""), 2000);
  };

  return (
    <motion.div
      initial={{ opacity: 0, y: 14 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.5 }}
      className="rounded-[28px] bg-slate-900 text-slate-100 p-6 shadow-2xl border border-slate-700/50"
    >
      <div className="flex items-center gap-2.5 mb-5">
        <div className="w-10 h-10 rounded-2xl bg-gradient-to-br from-amber-500/20 to-rose-500/20 grid place-items-center border border-amber-400/30">
          <FlaskConical className="w-5 h-5 text-amber-300" />
        </div>
        <div>
          <h2 className="font-display font-bold text-lg text-white">Diagnóstico · Test page</h2>
          <p className="text-xs text-slate-400 leading-relaxed max-w-md">
            Mandá patrones con un solo bit puesto y anotá qué muestra el pager. Con eso deducimos el
            bit-order exacto y parcheamos MMDVMHost.
          </p>
        </div>
      </div>

      <div className="inline-flex rounded-2xl bg-slate-800/80 border border-slate-700 p-1 mb-4">
        <button
          onClick={() => setMode("numeric")}
          className={`flex items-center gap-1.5 px-4 py-2 rounded-xl text-sm font-medium transition ${
            mode === "numeric"
              ? "bg-gradient-to-r from-sky-500 to-indigo-500 text-white shadow"
              : "text-slate-400 hover:text-slate-200"
          }`}
        >
          <Hash className="w-4 h-4" /> Numérico (page_bcd)
        </button>
        <button
          onClick={() => setMode("alpha")}
          className={`flex items-center gap-1.5 px-4 py-2 rounded-xl text-sm font-medium transition ${
            mode === "alpha"
              ? "bg-gradient-to-r from-emerald-500 to-teal-500 text-white shadow"
              : "text-slate-400 hover:text-slate-200"
          }`}
        >
          <Binary className="w-4 h-4" /> Alfanumérico (page)
        </button>
      </div>

      <div className="grid sm:grid-cols-2 gap-3 mb-4">
        <label className="block">
          <span className="block text-[11px] font-medium text-slate-400 mb-1">Cap code del pager</span>
          <input
            value={cap}
            onChange={(e) => setCap(e.target.value)}
            className="w-full bg-slate-800 border border-slate-700 rounded-xl px-3 py-2 text-sm text-slate-100 font-mono outline-none focus:border-amber-400 transition"
          />
        </label>
        <label className="block">
          <span className="block text-[11px] font-medium text-slate-400 mb-1">Mensaje</span>
          <input
            value={msg}
            onChange={(e) => setMsg(e.target.value)}
            className="w-full bg-slate-800 border border-slate-700 rounded-xl px-3 py-2 text-sm text-slate-100 font-mono outline-none focus:border-amber-400 transition"
          />
        </label>
      </div>

      <div className="flex items-center gap-3 bg-slate-950/60 border border-slate-700 rounded-2xl px-4 py-3 mb-6">
        <Send className="w-4 h-4 text-emerald-400 shrink-0" />
        <code className="flex-1 font-mono text-xs text-emerald-300 break-all">{cmd}</code>
        <button onClick={() => copiar(cmd, "cmd")} className="shrink-0 text-slate-400 hover:text-white">
          {copied === "cmd" ? <Check className="w-4 h-4 text-emerald-400" /> : <Copy className="w-4 h-4" />}
        </button>
      </div>

      <div className="flex items-center gap-2 mb-3">
        <ListChecks className="w-4 h-4 text-amber-300" />
        <h3 className="font-display font-semibold text-sm text-slate-200">
          Patrones sugeridos {mode === "numeric" ? "(numéricos)" : "(alfanuméricos)"}
        </h3>
      </div>
      <div className="space-y-2">
        {patterns.map((p) => {
          const c = buildCmd(cap, mode, p.msg);
          const id = "p-" + p.msg + "-" + p.note;
          const shown = p.msg === "     " ? "␣␣␣␣␣" : p.msg;
          return (
            <div
              key={id}
              className="flex items-center gap-3 bg-slate-800/60 border border-slate-700/60 rounded-2xl px-4 py-2.5"
            >
              <code className="font-mono text-sm text-sky-300 w-28 shrink-0">{shown}</code>
              <span className="text-[11px] text-slate-400 flex-1">{p.note}</span>
              <button
                onClick={() => copiar(c, id)}
                className="shrink-0 inline-flex items-center gap-1 text-[11px] bg-white/5 hover:bg-white/10 border border-white/10 rounded-full px-2.5 py-1 transition"
              >
                {copied === id ? <Check className="w-3 h-3 text-emerald-400" /> : <Copy className="w-3 h-3" />}
                {copied === id ? "Copiado" : "Copiar"}
              </button>
            </div>
          );
        })}
      </div>

      <div className="mt-6 text-[11px] text-slate-400 leading-relaxed bg-slate-950/40 border border-slate-700/40 rounded-2xl px-4 py-3">
        <strong className="text-slate-300">Cómo usar:</strong> copiá cada patrón, pegalo en la consola del
        servidor (donde corre MMDVMHost + mosquitto), mirá el display del pager y anotá lo que muestra.
        Después pasame los pares <code className="font-mono text-amber-300">enviado → recibido</code> y deduzco
        la permutación de bits para parchear <code className="font-mono text-amber-300">POCSAGControl.cpp</code>.
        Si el Zetron 640 sigue conectado, mandá los mismos patrones por él como referencia conocida-buena.
      </div>
    </motion.div>
  );
}