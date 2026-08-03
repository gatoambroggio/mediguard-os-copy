import React, { useState } from "react";
import { motion } from "framer-motion";
import {
  RadioTower,
  Download,
  Package,
  Terminal,
  Github,
  Copy,
  Check,
  Loader2,
  RefreshCw,
  ShieldCheck,
  ArrowUpRight,
  Zap,
  Boxes,
  Server,
  CheckCircle2,
  AlertTriangle,
  Cpu,
  Database,
  FolderGit2,
} from "lucide-react";
import JSZip from "jszip";

const REPO = "https://github.com/gatoambroggio/ubntpagingsystem.git";
const RAW = "https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/src/zetronpoc/instalador.sh";
const RAW_RPI = "https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/src/zetronpoc/instalador.sh";

const BOOTSTRAP = `#!/usr/bin/env bash
# Instala ZetronPOC (paginacion hospitalaria POCSAG, cliente FreePBX) desde GitHub.
set -euo pipefail
TMP="$(mktemp -d)"
echo "==> Clonando repositorio desde GitHub..."
git clone --depth 1 ${REPO} "$TMP"
cd "$TMP"
echo "==> Ejecutando instalador (podes pasar --update)..."
sudo bash src/zetronpoc/instalador.sh "$@"
echo ""
echo "[OK] ZetronPOC instalado."
echo "     Panel publico: http://localhost:8080/"
echo "     Panel admin  : http://localhost:8080/admin"
`;

const INCLUDES = [
  { icon: RadioTower, label: "10 internos hacia FreePBX" },
  { icon: Cpu, label: "Encoder Zetron 640 (BCH real)" },
  { icon: Server, label: "Asterisk + PJSIP cliente" },
  { icon: Database, label: "SQLite + bitacora" },
  { icon: Boxes, label: "Panel futurista + FreePBX" },
  { icon: ShieldCheck, label: "IVR que contesta (*99)" },
];

const fade = {
  hidden: { opacity: 0, y: 18 },
  show: (i) => ({
    opacity: 1,
    y: 0,
    transition: { delay: 0.06 * i, duration: 0.5, ease: [0.22, 1, 0.36, 1] },
  }),
};

export default function Descarga() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [ok, setOk] = useState("");
  const [copied, setCopied] = useState("");

  const copiar = (txt, id) => {
    navigator.clipboard.writeText(txt);
    setCopied(id);
    setTimeout(() => setCopied(""), 2000);
  };

  const descargarZip = async () => {
    setError("");
    setOk("");
    setBusy(true);
    try {
      const zip = new JSZip();
      const r1 = await fetch(RAW);
      if (!r1.ok) throw new Error("No se pudo obtener instalador.sh (HTTP " + r1.status + ").");
      const instalador = await r1.text();
      if (instalador.length < 1000 || instalador.trimStart().startsWith("<"))
        throw new Error("instalador.sh vino vacio o como HTML.");
      zip.file("instalador.sh", instalador);
      try {
        const r2 = await fetch("/source-manifest.json");
        const txt = await r2.text();
        if (txt && !txt.trimStart().startsWith("<")) {
          const manifest = JSON.parse(txt);
          for (const rel of manifest) {
            const rf = await fetch("/source/" + rel);
            if (!rf.ok) continue;
            const body = await rf.text();
            if (body && !body.trimStart().startsWith("<")) zip.file(rel, body);
          }
        }
      } catch {}
      const blob = await zip.generateAsync({ type: "blob" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = "zetronpoc.zip";
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
      setOk("Descarga lista: zetronpoc.zip con instalador.sh + carpeta src/ completa.");
    } catch (e) {
      setError(e.message || String(e));
    } finally {
      setBusy(false);
    }
  };

  const CmdBlock = ({ id, text, label }) => (
    <div className="bg-black/40 border border-white/10 rounded-2xl px-4 py-3 font-mono text-xs">
      <div className="text-slate-500 mb-1">{label}</div>
      <button
        onClick={() => copiar(text, id)}
        className="flex items-center gap-2 text-emerald-400 hover:text-emerald-300 break-all text-left w-full"
      >
        <span className="flex-1">{text}</span>
        {copied === id ? <Check className="w-3.5 h-3.5 shrink-0" /> : <Copy className="w-3.5 h-3.5 shrink-0" />}
      </button>
    </div>
  );

  return (
    <div className="relative min-h-screen overflow-hidden bg-[#f5f6fb] text-slate-900 font-body">
      {/* aurora */}
      <div className="pointer-events-none fixed inset-0 overflow-hidden">
        <motion.div
          className="absolute -top-40 -left-32 w-[36rem] h-[36rem] rounded-full blur-[130px]"
          style={{ background: "radial-gradient(circle,rgba(14,165,233,.28),transparent 60%)" }}
          animate={{ x: [0, 40, 0], y: [0, 30, 0], scale: [1, 1.1, 1] }}
          transition={{ duration: 16, repeat: Infinity, ease: "easeInOut" }}
        />
        <motion.div
          className="absolute top-1/3 -right-40 w-[32rem] h-[32rem] rounded-full blur-[130px]"
          style={{ background: "radial-gradient(circle,rgba(99,102,241,.26),transparent 60%)" }}
          animate={{ x: [0, -50, 0], y: [0, 40, 0], scale: [1, 1.15, 1] }}
          transition={{ duration: 18, repeat: Infinity, ease: "easeInOut" }}
        />
        <motion.div
          className="absolute bottom-0 left-1/3 w-[30rem] h-[30rem] rounded-full blur-[130px]"
          style={{ background: "radial-gradient(circle,rgba(16,185,129,.22),transparent 60%)" }}
          animate={{ x: [0, 30, 0], y: [0, -30, 0], scale: [1, 1.1, 1] }}
          transition={{ duration: 20, repeat: Infinity, ease: "easeInOut" }}
        />
      </div>

      {/* nav */}
      <motion.header
        initial={{ opacity: 0, y: -10 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.4 }}
        className="relative z-10 max-w-5xl mx-auto px-6 pt-8 flex items-center justify-between"
      >
        <div className="flex items-center gap-2.5">
          <div className="w-10 h-10 rounded-2xl bg-gradient-to-br from-sky-500 via-indigo-500 to-emerald-500 grid place-items-center shadow-lg shadow-indigo-500/30">
            <RadioTower className="w-5 h-5 text-white" />
          </div>
          <div className="leading-tight">
            <div className="font-display font-bold text-slate-900">ZetronPOC</div>
            <div className="text-[11px] text-slate-500 -mt-0.5">Zetron 640 / DaptX-Xtra v2.0</div>
          </div>
        </div>
        <a
          href={REPO}
          target="_blank"
          rel="noreferrer"
          className="flex items-center gap-2 text-sm font-medium text-slate-600 hover:text-slate-900 bg-white/70 backdrop-blur border border-slate-200 rounded-full px-4 py-2 transition"
        >
          <Github className="w-4 h-4" /> GitHub <ArrowUpRight className="w-3.5 h-3.5" />
        </a>
      </motion.header>

      {/* hero */}
      <section className="relative z-10 max-w-5xl mx-auto px-6 pt-14 pb-6 text-center">
        <motion.div
          initial={{ opacity: 0, y: 12 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5 }}
          className="inline-flex items-center gap-2 bg-white/70 backdrop-blur border border-slate-200 rounded-full px-4 py-1.5 text-xs font-medium text-slate-600 mb-6"
        >
          <span className="relative flex h-2 w-2">
            <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"></span>
            <span className="relative inline-flex rounded-full h-2 w-2 bg-emerald-500"></span>
          </span>
          Sistema autonomo &middot; VoIP + Radio &middot; 2026
        </motion.div>

        <motion.h1
          initial={{ opacity: 0, y: 16 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.55, delay: 0.05 }}
          className="font-display font-bold tracking-tight text-slate-900 text-4xl sm:text-5xl md:text-6xl leading-[1.05]"
        >
          Paginacion hospitalaria
          <br />
          <span className="bg-gradient-to-r from-sky-500 via-indigo-500 to-emerald-500 bg-clip-text text-transparent">
            Zetron 640 · DaptX-Xtra sobre VoIP
          </span>
        </motion.h1>

        <motion.p
          initial={{ opacity: 0, y: 16 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.55, delay: 0.12 }}
          className="mt-5 text-slate-600 text-base sm:text-lg max-w-xl mx-auto leading-relaxed"
        >
          Instala en Ubuntu Server 22.04 con una sola linea. ZetronPOC registra internos contra la central
          FreePBX del hospital, contesta con un IVR (probar *99) y entrega un panel tipo FreePBX para
          gestionar extensiones, pagers, encoder y envios. Configurable al 100% desde la web.
        </motion.p>

        <motion.div
          initial={{ opacity: 0, y: 16 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.55, delay: 0.18 }}
          className="mt-8 flex flex-col sm:flex-row gap-3 justify-center"
        >
          <motion.button
            whileHover={{ scale: busy ? 1 : 1.02 }}
            whileTap={{ scale: 0.98 }}
            onClick={descargarZip}
            disabled={busy}
            className="group bg-gradient-to-r from-sky-500 via-indigo-500 to-emerald-500 text-white font-semibold px-7 py-3.5 rounded-2xl shadow-xl shadow-indigo-500/30 flex items-center justify-center gap-2 disabled:opacity-60"
          >
            {busy ? <Loader2 className="w-5 h-5 animate-spin" /> : <Download className="w-5 h-5" />}
            {busy ? "Empaquetando..." : "Descargar paquete completo"}
          </motion.button>
          <a
            href={REPO}
            target="_blank"
            rel="noreferrer"
            className="bg-white/80 backdrop-blur border border-slate-200 text-slate-700 font-semibold px-7 py-3.5 rounded-2xl flex items-center justify-center gap-2 hover:border-indigo-300 hover:text-slate-900 transition"
          >
            <FolderGit2 className="w-5 h-5" /> Ver repositorio
          </a>
        </motion.div>

        {/* tech pills */}
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ duration: 0.5, delay: 0.25 }}
          className="mt-7 flex flex-wrap gap-2 justify-center"
        >
          {["Asterisk", "PJSIP", "FreePBX", "Python", "SQLite", "Ubuntu 22.04"].map((t) => (
            <span
              key={t}
              className="text-xs font-mono text-slate-500 bg-white/60 backdrop-blur border border-slate-200 rounded-full px-3 py-1"
            >
              {t}
            </span>
          ))}
        </motion.div>
      </section>

      {/* includes strip */}
      <section className="relative z-10 max-w-5xl mx-auto px-6 mt-6">
        <motion.div
          initial={{ opacity: 0, y: 14 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.3 }}
          className="grid grid-cols-2 sm:grid-cols-3 gap-3"
        >
          {INCLUDES.map((it) => (
            <div
              key={it.label}
              className="flex items-center gap-2.5 bg-white/70 backdrop-blur border border-slate-200 rounded-2xl px-3.5 py-3"
            >
              <div className="w-8 h-8 rounded-xl bg-gradient-to-br from-sky-500/15 to-indigo-500/15 grid place-items-center shrink-0">
                <it.icon className="w-4 h-4 text-indigo-600" />
              </div>
              <span className="text-sm font-medium text-slate-700">{it.label}</span>
            </div>
          ))}
        </motion.div>
      </section>

      {/* bento */}
      <section className="relative z-10 max-w-5xl mx-auto px-6 mt-8 grid md:grid-cols-3 gap-4">
        {/* big download card */}
        <motion.div
          custom={0}
          variants={fade}
          initial="hidden"
          animate="show"
          className="md:col-span-2 relative rounded-[28px] p-[1px] bg-gradient-to-br from-sky-500/40 via-indigo-500/30 to-emerald-500/40"
        >
          <div className="rounded-[27px] bg-white/80 backdrop-blur-xl p-6 h-full flex flex-col">
            <div className="flex items-start gap-3 mb-4">
              <div className="w-12 h-12 rounded-2xl bg-gradient-to-br from-sky-500 to-indigo-500 grid place-items-center shadow-lg shadow-indigo-500/30 shrink-0">
                <Package className="w-6 h-6 text-white" />
              </div>
              <div>
                <h2 className="font-display font-bold text-lg text-slate-900">Descarga offline (ZIP)</h2>
                <p className="text-sm text-slate-500 leading-relaxed">
                  <code className="font-mono text-indigo-600">instalador.sh</code> + carpeta{" "}
                  <code className="font-mono text-indigo-600">src/</code> completa (ZetronPOC cliente FreePBX).
                </p>
              </div>
            </div>
            <motion.button
              whileHover={{ scale: busy ? 1 : 1.01 }}
              whileTap={{ scale: 0.99 }}
              onClick={descargarZip}
              disabled={busy}
              className="w-full bg-gradient-to-r from-sky-500 via-indigo-500 to-emerald-500 hover:brightness-105 disabled:opacity-60 text-white font-semibold py-3.5 rounded-2xl transition flex items-center justify-center gap-2 shadow-lg shadow-indigo-500/30"
            >
              {busy ? <Loader2 className="w-5 h-5 animate-spin" /> : <Download className="w-5 h-5" />}
              {busy ? "Empaquetando..." : "Descargar zetronpoc.zip"}
            </motion.button>
            {ok && (
              <div className="mt-4 flex items-start gap-2 text-sm text-emerald-700 bg-emerald-500/10 border border-emerald-500/30 rounded-2xl px-4 py-3">
                <CheckCircle2 className="w-4 h-4 shrink-0 mt-0.5" />
                <span>{ok}</span>
              </div>
            )}
            {error && (
              <div className="mt-4 flex items-start gap-2 text-sm text-rose-600 bg-rose-500/10 border border-rose-500/30 rounded-2xl px-4 py-3">
                <AlertTriangle className="w-4 h-4 shrink-0 mt-0.5" />
                <span className="break-words">{error}</span>
              </div>
            )}
          </div>
        </motion.div>

        {/* one-liner */}
        <motion.div
          custom={1}
          variants={fade}
          initial="hidden"
          animate="show"
          className="rounded-[28px] bg-white/70 backdrop-blur-xl border border-slate-200 p-6 flex flex-col"
        >
          <div className="flex items-center gap-2 mb-3">
            <Zap className="w-5 h-5 text-amber-500" />
            <h2 className="font-display font-bold text-slate-900">Instalacion en 1 linea</h2>
          </div>
          <p className="text-xs text-slate-500 mb-3 leading-relaxed">
            Baja el instalador directo de GitHub y ejecuta en el servidor.
          </p>
          <CmdBlock id="a" text={`curl -fsSL ${RAW} | sudo bash`} label="curl | bash" />
        </motion.div>

        {/* clone */}
        <motion.div
          custom={2}
          variants={fade}
          initial="hidden"
          animate="show"
          className="md:col-span-2 rounded-[28px] bg-white/70 backdrop-blur-xl border border-slate-200 p-6 flex flex-col"
        >
          <div className="flex items-center gap-2 mb-3">
            <Github className="w-5 h-5 text-slate-700" />
            <h2 className="font-display font-bold text-slate-900">Clonar repositorio completo</h2>
          </div>
          <p className="text-xs text-slate-500 mb-3 leading-relaxed">
            Trae todo el historial y la carpeta <code className="font-mono text-indigo-600">src/</code> editable.
          </p>
          <CmdBlock
            id="b"
            text={`git clone ${REPO} /tmp/zetronpoc && cd /tmp/zetronpoc && sudo bash src/zetronpoc/instalador.sh`}
            label="git clone"
          />
          <button
            onClick={() => copiar(BOOTSTRAP, "boot")}
            className="mt-3 inline-flex items-center gap-2 text-xs text-slate-600 hover:text-indigo-600 self-start"
          >
            {copied === "boot" ? <Check className="w-3.5 h-3.5" /> : <Copy className="w-3.5 h-3.5" />}
            {copied === "boot" ? "Bootstrap copiado" : "Copiar script instalar-desde-github.sh"}
          </button>
        </motion.div>

        {/* update */}
        <motion.div
          custom={3}
          variants={fade}
          initial="hidden"
          animate="show"
          className="rounded-[28px] bg-white/70 backdrop-blur-xl border border-slate-200 p-6 flex flex-col"
        >
          <div className="flex items-center gap-2 mb-3">
            <RefreshCw className="w-5 h-5 text-sky-500" />
            <h2 className="font-display font-bold text-slate-900">Actualizar sin reinstalar</h2>
          </div>
          <p className="text-xs text-slate-500 mb-3 leading-relaxed">
            Refresca UI/backend sin tocar la base de datos.
          </p>
          <CmdBlock
            id="up"
            text={`sudo bash src/zetronpoc/instalador.sh --update && sudo systemctl restart zetronpoc-api`}
            label="update"
          />
          <p className="text-[11px] text-slate-400 mt-2">
            Despues abri el panel en incognito (Ctrl+Shift+N) para saltear la cache.
          </p>
        </motion.div>

        {/* raspberry pi */}
        <motion.div
          custom={4}
          variants={fade}
          initial="hidden"
          animate="show"
          className="md:col-span-3 rounded-[28px] bg-gradient-to-br from-emerald-500/15 to-green-500/15 border border-emerald-500/30 p-6 flex flex-col"
        >
          <div className="flex items-center gap-2 mb-3">
            <Cpu className="w-5 h-5 text-emerald-600" />
            <h2 className="font-display font-bold text-slate-900">Instalar en Raspberry Pi</h2>
          </div>
          <p className="text-xs text-slate-500 mb-3 leading-relaxed">
            Para Pi 3/4/5 con Raspberry Pi OS (64-bit). Detecta el gpiochip automaticamente
            (Pi 5 usa gpiochip4, Pi 3/4 gpiochip0) y configura el PTT en el BCM 17 por defecto.
          </p>
          <CmdBlock
            id="rpi"
            text={`curl -fsSL ${RAW_RPI} | sudo bash`}
            label="raspberry pi"
          />
          <p className="text-[11px] text-slate-400 mt-2">
            Para otro pin: <code className="font-mono text-emerald-600">sudo POCSAG_GPIO_PIN=18 bash instalador_rpi.sh</code>
          </p>
        </motion.div>
      </section>

      {/* terminal section */}
      <section className="relative z-10 max-w-5xl mx-auto px-6 mt-8">
        <motion.div
          initial={{ opacity: 0, y: 14 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.1 }}
          className="rounded-[28px] bg-slate-900 text-slate-100 p-6 shadow-2xl"
        >
          <div className="flex items-center gap-2 mb-4">
            <Terminal className="w-5 h-5 text-emerald-400" />
            <h2 className="font-display font-bold">Flujo rapido en el servidor</h2>
          </div>
          <div className="font-mono text-xs space-y-2 text-slate-300">
            <div><span className="text-slate-500">$</span> curl -fsSL {RAW} | sudo bash</div>
            <div className="text-emerald-400">{"->"} Instalando ZetronPOC: Asterisk, encoder y servicios cliente...</div>
            <div><span className="text-slate-500">$</span> sudo bash src/zetronpoc/instalador.sh --update</div>
            <div className="text-emerald-400">{"->"} Panel publico: http://localhost:8080/</div>
            <div className="text-emerald-400">{"->"} Panel admin  : http://localhost:8080/admin</div>
          </div>
        </motion.div>
      </section>

      <footer className="relative z-10 max-w-5xl mx-auto px-6 mt-10 mb-10 flex items-center justify-center gap-2 text-xs text-slate-400">
        <Server className="w-3.5 h-3.5" />
        Despliegue en Ubuntu Server 22.04 LTS &middot; ZetronPOC v2.0 · Zetron 640 / DaptX-Xtra
      </footer>
    </div>
  );
}