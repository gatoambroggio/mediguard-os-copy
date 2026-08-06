import React, { useState } from "react";
import { motion } from "framer-motion";
import {
  RadioTower,
  Cpu,
  Usb,
  Cable,
  Send,
  Terminal,
  Copy,
  Check,
  Zap,
  CircuitBoard,
  ArrowLeft,
  ShieldCheck,
} from "lucide-react";
import { Link } from "react-router-dom";
import MmdvmConfig from "@/components/mmdvm/MmdvmConfig";

const PINOUT = [
  ["5V", "VCC del adaptador USB-TTL (o fuente externa 5V)", "rojo"],
  ["GND", "GND comun (adaptador + modulo)", "negro"],
  ["TX (Pi GPIO14)", "RX del adaptador USB-TTL", "blanco"],
  ["RX (Pi GPIO15)", "TX del adaptador USB-TTL", "verde"],
];

const INSTALL_CMDS = [
  ["1", "Dependencias de compilacion", "sudo apt-get update && sudo apt-get install -y git build-essential libudev-dev"],
  ["2", "Clonar MMDVMHost (G4KLX)", "git clone https://github.com/g4klx/MMDVMHost.git /opt/MMDVMHost"],
  ["3", "Compilar MMDVMHost", "cd /opt/MMDVMHost && make -j$(nproc)"],
  ["4", "Dar permisos al puerto serie", "sudo usermod -aG dialout $USER && sudo chmod 666 /dev/ttyUSB0"],
  ["5", "Crear config (pegar MMDVM.ini)", "sudo nano /opt/MMDVMHost/MMDVM.ini"],
  ["6", "Probar conexion con el modulo", "cd /opt/MMDVMHost && ./MMDVMHost MMDVM.ini"],
];

const fade = {
  hidden: { opacity: 0, y: 18 },
  show: (i) => ({ opacity: 1, y: 0, transition: { delay: 0.06 * i, duration: 0.5, ease: [0.22, 1, 0.36, 1] } }),
};

export default function Mmdvm() {
  const [copied, setCopied] = useState("");
  const copiar = (txt, id) => {
    navigator.clipboard.writeText(txt);
    setCopied(id);
    setTimeout(() => setCopied(""), 2000);
  };

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
      </div>

      {/* nav */}
      <motion.header
        initial={{ opacity: 0, y: -10 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.4 }}
        className="relative z-10 max-w-5xl mx-auto px-6 pt-8 flex items-center justify-between"
      >
        <Link to="/" className="flex items-center gap-2.5 group">
          <div className="w-10 h-10 rounded-2xl bg-gradient-to-br from-sky-500 via-indigo-500 to-emerald-500 grid place-items-center shadow-lg shadow-indigo-500/30">
            <RadioTower className="w-5 h-5 text-white" />
          </div>
          <div className="leading-tight">
            <div className="font-display font-bold text-slate-900">ZetronPOC</div>
            <div className="text-[11px] text-slate-500 -mt-0.5">MediGuard OS · MMDVM Serial</div>
          </div>
        </Link>
        <Link
          to="/"
          className="flex items-center gap-2 text-sm font-medium text-slate-600 hover:text-slate-900 bg-white/70 backdrop-blur border border-slate-200 rounded-full px-4 py-2 transition"
        >
          <ArrowLeft className="w-4 h-4" /> Volver
        </Link>
      </motion.header>

      {/* hero */}
      <section className="relative z-10 max-w-5xl mx-auto px-6 pt-14 pb-6 text-center">
        <motion.div
          initial={{ opacity: 0, y: 12 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5 }}
          className="inline-flex items-center gap-2 bg-white/70 backdrop-blur border border-slate-200 rounded-full px-4 py-1.5 text-xs font-medium text-slate-600 mb-6"
        >
          <CircuitBoard className="w-3.5 h-3.5 text-indigo-600" />
          Modulo MMDVM UHF/VHF · Puerto serie · Sin Raspberry
        </motion.div>

        <motion.h1
          initial={{ opacity: 0, y: 16 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.55, delay: 0.05 }}
          className="font-display font-bold tracking-tight text-slate-900 text-4xl sm:text-5xl leading-[1.05]"
        >
          POCSAG por MMDVM
          <br />
          <span className="bg-gradient-to-r from-sky-500 via-indigo-500 to-emerald-500 bg-clip-text text-transparent">
            directo al encoder · sin .wav
          </span>
        </motion.h1>

        <motion.p
          initial={{ opacity: 0, y: 16 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.55, delay: 0.12 }}
          className="mt-5 text-slate-600 text-base sm:text-lg max-w-xl mx-auto leading-relaxed"
        >
          Conectas el modulo MMDVM a la PC con Ubuntu Server por un adaptador USB-TTL, compilas
          MMDVMHost y el sistema genera la FSK de POCSAG con desviacion y timing exactos.
          Reemplaza el audio por .wav que no funciona para paginacion.
        </motion.p>
      </section>

      {/* por que serial */}
      <section className="relative z-10 max-w-5xl mx-auto px-6 mt-4 grid sm:grid-cols-3 gap-3">
        {[
          { icon: Usb, title: "USB-TTL", desc: "Adaptador CP2102/FT232R al header del modulo." },
          { icon: Zap, title: "Sin .wav", desc: "FSK digital exacta, no audio inyectado en FM." },
          { icon: Send, title: "POCSAG nativo", desc: "512 / 1200 / 2400 bps directo del encoder." },
        ].map((c, i) => (
          <motion.div
            key={c.title}
            custom={i}
            variants={fade}
            initial="hidden"
            animate="show"
            className="flex items-center gap-3 bg-white/70 backdrop-blur border border-slate-200 rounded-2xl px-4 py-3.5"
          >
            <div className="w-9 h-9 rounded-xl bg-gradient-to-br from-sky-500/15 to-indigo-500/15 grid place-items-center shrink-0">
              <c.icon className="w-4 h-4 text-indigo-600" />
            </div>
            <div>
              <div className="text-sm font-semibold text-slate-800">{c.title}</div>
              <div className="text-[11px] text-slate-500 leading-snug">{c.desc}</div>
            </div>
          </motion.div>
        ))}
      </section>

      {/* config builder */}
      <section className="relative z-10 max-w-5xl mx-auto px-6 mt-8">
        <motion.div
          initial={{ opacity: 0, y: 14 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.1 }}
        >
          <div className="flex items-center gap-2 mb-3">
            <Cpu className="w-5 h-5 text-indigo-600" />
            <h2 className="font-display font-bold text-slate-900">Generador de configuracion MMDVM.ini</h2>
          </div>
          <p className="text-xs text-slate-500 mb-4">
            Completas los parametros y te arma el <code className="font-mono text-indigo-600">MMDVM.ini</code> listo para
            Ubuntu Server. Lo copias y lo pegas en el servidor.
          </p>
          <MmdvmConfig />
        </motion.div>
      </section>

      {/* pinout */}
      <section className="relative z-10 max-w-5xl mx-auto px-6 mt-8">
        <motion.div
          initial={{ opacity: 0, y: 14 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.1 }}
          className="rounded-[28px] bg-white/80 backdrop-blur-xl border border-slate-200 p-6"
        >
          <div className="flex items-center gap-2 mb-4">
            <Cable className="w-5 h-5 text-emerald-600" />
            <h2 className="font-display font-bold text-slate-900">Conexion USB-TTL al modulo</h2>
          </div>
          <div className="overflow-hidden rounded-2xl border border-slate-200">
            <table className="w-full text-sm">
              <thead className="bg-slate-50 text-slate-500 text-xs">
                <tr>
                  <th className="text-left font-medium px-4 py-2.5">Pin modulo (GPIO Pi)</th>
                  <th className="text-left font-medium px-4 py-2.5">Hacia adaptador USB-TTL</th>
                  <th className="text-left font-medium px-4 py-2.5">Color</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {PINOUT.map((r) => (
                  <tr key={r[0]} className="text-slate-700">
                    <td className="px-4 py-2.5 font-mono text-[13px]">{r[0]}</td>
                    <td className="px-4 py-2.5">{r[1]}</td>
                    <td className="px-4 py-2.5">
                      <span className={`inline-block w-2.5 h-2.5 rounded-full mr-1.5 align-middle ${
                        r[2] === "rojo" ? "bg-rose-500" : r[2] === "negro" ? "bg-slate-800" : r[2] === "blanco" ? "bg-slate-300" : "bg-emerald-500"
                      }`} />
                      <span className="text-xs text-slate-500">{r[2]}</span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="text-[11px] text-slate-400 mt-3">
            Importante: TX del modulo va al RX del adaptador y viceversa. GND comun obligatorio. Si el modulo
            viene como HAT, estos pines son los GPIO 14 (TX) y 15 (RX) del header de 40 pines.
          </p>
        </motion.div>
      </section>

      {/* install steps */}
      <section className="relative z-10 max-w-5xl mx-auto px-6 mt-8">
        <motion.div
          initial={{ opacity: 0, y: 14 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.1 }}
        >
          <div className="flex items-center gap-2 mb-4">
            <Terminal className="w-5 h-5 text-emerald-400" />
            <h2 className="font-display font-bold text-slate-900">Instalacion en Ubuntu Server</h2>
          </div>
          <div className="space-y-2.5">
            {INSTALL_CMDS.map((c) => (
              <div
                key={c[0]}
                className="rounded-2xl bg-slate-900 text-slate-100 px-4 py-3 flex items-center gap-3"
              >
                <span className="shrink-0 w-6 h-6 rounded-full bg-indigo-500/20 text-indigo-300 grid place-items-center text-xs font-bold">
                  {c[0]}
                </span>
                <div className="flex-1 min-w-0">
                  <div className="text-[11px] text-slate-400 mb-0.5">{c[1]}</div>
                  <code className="font-mono text-xs text-emerald-300 break-all">{c[2]}</code>
                </div>
                <button
                  onClick={() => copiar(c[2], c[0])}
                  className="shrink-0 text-slate-400 hover:text-white"
                >
                  {copied === c[0] ? <Check className="w-4 h-4 text-emerald-400" /> : <Copy className="w-4 h-4" />}
                </button>
              </div>
            ))}
          </div>
        </motion.div>
      </section>

      {/* bridge to ZetronPOC */}
      <section className="relative z-10 max-w-5xl mx-auto px-6 mt-8">
        <motion.div
          initial={{ opacity: 0, y: 14 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.1 }}
          className="rounded-[28px] bg-gradient-to-br from-emerald-500/15 to-sky-500/15 border border-emerald-500/30 p-6"
        >
          <div className="flex items-center gap-2 mb-3">
            <ShieldCheck className="w-5 h-5 text-emerald-600" />
            <h2 className="font-display font-bold text-slate-900">Integracion con ZetronPOC</h2>
          </div>
          <p className="text-xs text-slate-600 leading-relaxed">
            Una vez que MMDVMHost corre y responde por el serie, ZetronPOC le envia los mensajes POCSAG del
            panel hospitalario. El encoder del sistema arma el mensaje (RIC + texto) y lo inyecta al MMDVM,
            que lo transmite por la antena UHF/VHF. Los pagers reciben como siempre.
          </p>
          <div className="mt-3 font-mono text-[11px] text-slate-700 bg-white/60 rounded-xl px-4 py-2.5 border border-emerald-500/20">
            Panel ZetronPOC → encoder BCH → MMDVMHost (serial) → MMDVM → antena UHF → pagers
          </div>
        </motion.div>
      </section>

      <footer className="relative z-10 max-w-5xl mx-auto px-6 mt-10 mb-10 flex items-center justify-center gap-2 text-xs text-slate-400">
        <CircuitBoard className="w-3.5 h-3.5" />
        MediGuard OS · Modulo MMDVM Serial · POCSAG nativo
      </footer>
    </div>
  );
}