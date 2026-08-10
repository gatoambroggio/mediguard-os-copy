import React, { useEffect, useState } from "react";
import { motion } from "framer-motion";
import {
  Github,
  Loader2,
  CheckCircle2,
  AlertTriangle,
  ArrowUpRight,
  GitPullRequest,
} from "lucide-react";
import { base44 } from "@/api/base44Client";

// Snapshot build-time del arbol fuente de ZetronPOC (contenido inlined por Vite).
// Solo extensiones de texto: Vite ?raw no provee default export para archivos sin extension (ej. VERSION).
const zetronpocModules = import.meta.glob(
  "/src/zetronpoc/**/*.{py,html,sql,sh,conf,service,md,jsonc,json,txt,ini,cfg,css,js,jsx,ts,tsx}",
  { query: "?raw", import: "default", eager: true }
);

function b64encode(str) {
  const bytes = new TextEncoder().encode(str);
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

function buildFiles() {
  const files = [];
  for (const [path, content] of Object.entries(zetronpocModules)) {
    if (typeof content !== "string" || !content) continue;
    if (content.indexOf("\0") !== -1) continue; // saltea binarios
    files.push({ path: path.replace(/^\//, ""), content_b64: b64encode(content) });
  }
  return files.sort((a, b) => a.path.localeCompare(b.path));
}

async function stageSnapshot() {
  const files = buildFiles();
  const payload = JSON.stringify({ files, staged_at: new Date().toISOString() });
  const file = new File([payload], "zetronpoc-snapshot.json", { type: "application/json" });
  const { file_url } = await base44.integrations.Core.UploadFile({ file });
  await base44.entities.GithubSyncSnapshot.create({
    file_url,
    file_count: files.length,
    label: "auto-stage",
  });
  return { file_url, count: files.length };
}

export default function GithubPublishCard() {
  const [admin, setAdmin] = useState(null);
  const [staging, setStaging] = useState(false);
  const [staged, setStaged] = useState(null);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState(null);
  const [error, setError] = useState("");

  useEffect(() => {
    (async () => {
      try {
        const authed = await base44.auth.isAuthenticated();
        if (!authed) return setAdmin(false);
        const me = await base44.auth.me();
        setAdmin(me && me.role === "admin");
      } catch {
        setAdmin(false);
      }
    })();
  }, []);

  // Prepara un snapshot al montar (alimenta la ruta automatica on-publish)
  useEffect(() => {
    if (admin !== true) return;
    let cancelled = false;
    (async () => {
      try {
        setStaging(true);
        const s = await stageSnapshot();
        if (!cancelled) setStaged(s);
      } catch {
        /* se reintenta al publicar */
      } finally {
        if (!cancelled) setStaging(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [admin]);

  if (admin !== true) return null;

  const publish = async () => {
    setError("");
    setResult(null);
    setBusy(true);
    try {
      setStaging(true);
      const s = await stageSnapshot();
      setStaged(s);
      setStaging(false);
      const res = await base44.functions.invoke("publishToGithub", {
        file_url: s.file_url,
        commit_message: `chore: sync ZetronPOC source (manual) · ${new Date().toISOString()}`,
      });
      const data = res && res.data ? res.data : res;
      if (!data || data.error) throw new Error((data && data.error) || "fallo desconocido");
      setResult(data);
    } catch (e) {
      setError(e.message || String(e));
    } finally {
      setBusy(false);
      setStaging(false);
    }
  };

  return (
    <motion.div
      initial={{ opacity: 0, y: 14 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.5 }}
      className="md:col-span-3 rounded-[28px] bg-gradient-to-br from-slate-900 to-slate-800 text-slate-100 p-6 shadow-2xl border border-slate-700/50"
    >
      <div className="flex items-start justify-between gap-3 mb-4 flex-wrap">
        <div className="flex items-center gap-2.5">
          <div className="w-10 h-10 rounded-2xl bg-gradient-to-br from-slate-700 to-slate-900 grid place-items-center border border-slate-600/50">
            <Github className="w-5 h-5 text-white" />
          </div>
          <div>
            <h2 className="font-display font-bold text-lg text-white">Publicar a GitHub</h2>
            <p className="text-xs text-slate-400 leading-relaxed">
              Commitea el source directo a{" "}
              <code className="font-mono text-sky-400">main</code> (sin PR).
            </p>
          </div>
        </div>
        <span className="text-[11px] font-mono text-slate-400 bg-slate-800/60 border border-slate-700 rounded-full px-3 py-1">
          {staging ? "preparando…" : staged ? `${staged.count} archivos listos` : "—"}
        </span>
      </div>

      <motion.button
        whileHover={{ scale: busy ? 1 : 1.01 }}
        whileTap={{ scale: 0.99 }}
        onClick={publish}
        disabled={busy || staging}
        className="w-full bg-gradient-to-r from-sky-500 via-indigo-500 to-emerald-500 hover:brightness-105 disabled:opacity-60 text-white font-semibold py-3.5 rounded-2xl transition flex items-center justify-center gap-2 shadow-lg shadow-indigo-500/30"
      >
        {busy ? <Loader2 className="w-5 h-5 animate-spin" /> : <GitPullRequest className="w-5 h-5" />}
        {busy ? "Publicando…" : "Publicar a GitHub (push a main)"}
      </motion.button>

      {result && (
        <div className="mt-4 flex items-start gap-2 text-sm bg-emerald-500/10 border border-emerald-500/30 rounded-2xl px-4 py-3">
          <CheckCircle2 className="w-4 h-4 shrink-0 mt-0.5 text-emerald-400" />
          <div className="text-emerald-200">
            {result.files_count} archivos commiteados a{" "}
            <code className="font-mono">{result.branch}</code>.
            <a
              href={result.commit_url}
              target="_blank"
              rel="noreferrer"
              className="ml-2 inline-flex items-center gap-1 underline text-emerald-300 hover:text-emerald-100"
            >
              Ver commit <ArrowUpRight className="w-3.5 h-3.5" />
            </a>
            <div className="mt-1 text-[11px] text-emerald-300/70">
              En el servidor corre <code className="font-mono">bash pullupdate.sh</code> para tomar los cambios.
            </div>
          </div>
        </div>
      )}

      {error && (
        <div className="mt-4 flex items-start gap-2 text-sm text-rose-300 bg-rose-500/10 border border-rose-500/30 rounded-2xl px-4 py-3">
          <AlertTriangle className="w-4 h-4 shrink-0 mt-0.5" />
          <span className="break-words">{error}</span>
        </div>
      )}
    </motion.div>
  );
}