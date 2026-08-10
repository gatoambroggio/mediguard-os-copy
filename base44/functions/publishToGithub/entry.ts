import { createClientFromRequest } from 'npm:@base44/sdk@0.8.40';

const OWNER = "gatoambroggio";
const REPO = "mediguard-os-copy";
const API = "https://api.github.com";

function b64decode(b64) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new TextDecoder().decode(bytes);
}

async function gh(path, init, token) {
  const headers = Object.assign(
    {
      "Authorization": `Bearer ${token}`,
      "Accept": "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "Base44-ZetronPOC",
    },
    init.headers || {}
  );
  const res = await fetch(`${API}${path}`, Object.assign({}, init, { headers }));
  const text = await res.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch (_) { body = text; }
  if (!res.ok) {
    const msg = (body && (body.message || body)) || text || `HTTP ${res.status}`;
    throw new Error(`GitHub ${path}: ${typeof msg === "string" ? msg : JSON.stringify(msg).slice(0, 300)}`);
  }
  return body;
}

export default async function(req) {
  try {
    const base44 = createClientFromRequest(req);
    const body = await req.json().catch(() => ({}));
    const isAuthed = await base44.auth.isAuthenticated().catch(() => false);

    let fileUrl = body.file_url || null;
    let mode = "auto";

    if (isAuthed) {
      const user = await base44.auth.me();
      if (!user) return Response.json({ error: "Unauthorized" }, { status: 401 });
      if (user.role !== "admin") return Response.json({ error: "Forbidden: admin only" }, { status: 403 });
      mode = "manual";
      if (!fileUrl) {
        const snaps = await base44.asServiceRole.entities.GithubSyncSnapshot.list("-created_date", 1);
        fileUrl = snaps && snaps[0] ? snaps[0].file_url : null;
      }
    } else {
      // internal / workflow invocation
      if (body.source !== "workflow") {
        return Response.json({ error: "Unauthorized" }, { status: 401 });
      }
      const snaps = await base44.asServiceRole.entities.GithubSyncSnapshot.list("-created_date", 1);
      fileUrl = snaps && snaps[0] ? snaps[0].file_url : null;
    }

    if (!fileUrl) {
      return Response.json(
        { error: "No hay snapshot staged. Abrí la pagina de Descarga como admin para preparar la publicacion." },
        { status: 400 }
      );
    }

    // Download staged snapshot JSON
    const snapRes = await fetch(fileUrl);
    if (!snapRes.ok) throw new Error("No se pudo descargar el snapshot desde " + fileUrl);
    const snap = await snapRes.json();
    const files = Array.isArray(snap.files) ? snap.files : [];
    if (!files.length) return Response.json({ error: "Snapshot vacio" }, { status: 400 });

    const owner = body.owner || OWNER;
    const repo = body.repo || REPO;

    const { accessToken } = await base44.asServiceRole.connectors.getConnection("github");
    if (!accessToken) throw new Error("Conector GitHub no autorizado");

    // 1. main ref sha
    const mainRef = await gh(`/repos/${owner}/${repo}/git/refs/heads/main`, {}, accessToken);
    const mainSha = mainRef.object.sha;

    // 2. base tree sha
    const mainCommit = await gh(`/repos/${owner}/${repo}/git/commits/${mainSha}`, {}, accessToken);
    const baseTreeSha = mainCommit.tree.sha;

    // 3. create blobs (one per file)
    const treeEntries = [];
    for (const f of files) {
      const blob = await gh(
        `/repos/${owner}/${repo}/git/blobs`,
        { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ content: f.content_b64, encoding: "base64" }) },
        accessToken
      );
      treeEntries.push({ path: f.path, mode: "100644", type: "blob", sha: blob.sha });
    }

    // 4. create tree on top of base
    const tree = await gh(
      `/repos/${owner}/${repo}/git/trees`,
      { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ base_tree: baseTreeSha, tree: treeEntries }) },
      accessToken
    );
    const newTreeSha = tree.sha;

    // 5. commit on top of main
    const commitMsg = body.commit_message || `chore: sync ZetronPOC source (${mode}) · ${new Date().toISOString()}`;
    const commit = await gh(
      `/repos/${owner}/${repo}/git/commits`,
      { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ message: commitMsg, tree: newTreeSha, parents: [mainSha] }) },
      accessToken
    );
    const commitSha = commit.sha;

    // 6. fast-forward main directly (no PR merge step) so the server's
    //    instalador.sh / pullupdate.sh (which read raw main) pick it up immediately
    await gh(
      `/repos/${owner}/${repo}/git/refs/heads/main`,
      { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ sha: commitSha }) },
      accessToken
    );

    return Response.json({
      ok: true,
      commit_url: `https://github.com/${owner}/${repo}/commit/${commitSha}`,
      branch: "main",
      files_count: files.length,
      commit_sha: commitSha,
      mode,
    });
  } catch (error) {
    return Response.json({ error: error.message || String(error) }, { status: 500 });
  }
}