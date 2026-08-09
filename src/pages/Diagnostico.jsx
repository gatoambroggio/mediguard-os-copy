import React from "react";
import { motion } from "framer-motion";
import { RadioTower, ArrowLeft, FlaskConical } from "lucide-react";
import { Link } from "react-router-dom";
import TestPagePanel from "@/components/diagnostico/TestPagePanel";

export default function Diagnostico() {
  return (
    <div className="relative min-h-screen overflow-hidden bg-[#0a0e1a] text-slate-100 font-body">
      <div className="pointer-events-none fixed inset-0 overflow-hidden">
        <motion.div
          className="absolute -top-40 -left-32 w-[36rem] h-[36rem] rounded-full blur-[130px]"
          style={{ background: "radial-gradient(circle,rgba(245,158,11,.22),transparent 60%)" }}
          animate={{ x: [0, 40, 0], y: [0, 30, 0], scale: [1, 1.1, 1] }}
          transition={{ duration: 16, repeat: Infinity, ease: "easeInOut" }}
        />
        <motion.div
          className="absolute top-1/3 -right-40 w-[32rem] h-[32rem] rounded-full blur-[130px]"
          style={{ background: "radial-gradient(circle,rgba(244,63,94,.20),transparent 60%)" }}
          animate={{ x: [0, -50, 0], y: [0, 40, 0], scale: [1, 1.15, 1] }}
          transition={{ duration: 18, repeat: Infinity, ease: "easeInOut" }}
        />
      </div>

      <motion.header
        initial={{ opacity: 0, y: -10 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.4 }}
        className="relative z-10 max-w-3xl mx-auto px-6 pt-8 flex items-center justify-between"
      >
        <Link to="/mmdvm" className="flex items-center gap-2.5">
          <div className="w-10 h-10 rounded-2xl bg-gradient-to-br from-sky-500 via-indigo-500 to-emerald-500 grid place-items-center shadow-lg shadow-indigo-500/30">
            <RadioTower className="w-5 h-5 text-white" />
          </div>
          <div className="leading-tight">
            <div className="font-display font-bold text-white">ZetronPOC</div>
            <div className="text-[11px] text-slate-400 -mt-0.5">Diagnóstico · Bit-packing POCSAG</div>
          </div>
        </Link>
        <Link
          to="/mmdvm"
          className="flex items-center gap-2 text-sm font-medium text-slate-300 hover:text-white bg-white/5 backdrop-blur border border-slate-700 rounded-full px-4 py-2 transition"
        >
          <ArrowLeft className="w-4 h-4" /> Volver
        </Link>
      </motion.header>

      <section className="relative z-10 max-w-3xl mx-auto px-6 pt-12 pb-6 text-center">
        <motion.div
          initial={{ opacity: 0, y: 12 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5 }}
          className="inline-flex items-center gap-2 bg-white/5 backdrop-blur border border-slate-700 rounded-full px-4 py-1.5 text-xs font-medium text-slate-300 mb-6"
        >
          <FlaskConical className="w-3.5 h-3.5 text-amber-400" />
          Reverse-engineering del bit-order
        </motion.div>
        <motion.h1
          initial={{ opacity: 0, y: 16 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.55, delay: 0.05 }}
          className="font-display font-bold tracking-tight text-white text-3xl sm:text-4xl leading-[1.1]"
        >
          Test page para deducir el
          <br />
          <span className="bg-gradient-to-r from-amber-400 via-rose-400 to-sky-400 bg-clip-text text-transparent">
            bit-packing del pager
          </span>
        </motion.h1>
        <motion.p
          initial={{ opacity: 0, y: 16 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.55, delay: 0.12 }}
          className="mt-4 text-slate-400 text-sm sm:text-base max-w-xl mx-auto leading-relaxed"
        >
          La RF y el baud ya funcionan (el pager sincroniza). Falta el orden de bits del mensaje. Mandá
          estos patrones por MMDVMHost, anotá qué muestra el display y con eso parcheamos
          <code className="font-mono text-amber-300"> POCSAGControl.cpp</code> para que emita igual que el Zetron 640.
        </motion.p>
      </section>

      <section className="relative z-10 max-w-3xl mx-auto px-6 pb-12">
        <TestPagePanel />
      </section>
    </div>
  );
}