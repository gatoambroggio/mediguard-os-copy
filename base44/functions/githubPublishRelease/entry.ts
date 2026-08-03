import { createClientFromRequest } from 'npm:@base44/sdk@0.8.40';

// Publica archivos al repo mediguard-os-copy y genera un release con tag (v1.0, v1.01...).
const OWNER = "gatoambroggio";
const REPO = "mediguard-os-copy";
const API = `https://api.github.com/repos/${OWNER}/${REPO}`;

export default async function(req) {
  try {
    const base44 = createClientFromRequest(req);
    const user = await base44.auth.me();
    if (!user) return Response.json({ error: 'Unauthorized' }, { status: 401 });
    if (user.role !== 'admin') return Response.json({ error: 'Forbidden' }, { status: 403 });

    const body = await req.json();
    const version = String(body.version || "").trim();
    const message = body.message || `Release ${version}`;
    const files = Array.isArray(body.files) ? body.files : [];
    if (!version) return Response.json({ error: 'Falta version' }, { status: 400 });
    if (files.length === 0) return Response.json({ error: 'Falta files' }, { status: 400 });

    const { accessToken } = await base44.asServiceRole.connectors.getConnection("github");
    const headers = {
      Authorization: `Bearer ${accessToken}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "Content-Type": "application/json",
      "User-Agent": "base44-mediguard-os",
    };

    // 1. Ref main actual
    const refRes = await fetch(`${API}/git/refs/heads/main`, { headers });
    if (!refRes.ok) return Response.json({ error: 'No se pudo obtener ref main', detail: await refRes.text() }, { status: 502 });
    const mainSha = (await refRes.json()).object.sha;

    // 2. Tree base
    const commitRes = await fetch(`${API}/git/commits/${mainSha}`, { headers });
    const baseTree = (await commitRes.json()).tree.sha;

    // 3. Blobs por archivo
    const treeEntries = [];
    for (const f of files) {
      const bRes = await fetch(`${API}/git/blobs`, {
        method: "POST", headers,
        body: JSON.stringify({ content: String(f.content), encoding: "utf-8" }),
      });
      if (!bRes.ok) return Response.json({ error: 'blob fallo', path: f.path, detail: await bRes.text() }, { status: 502 });
      treeEntries.push({ path: f.path, mode: "100644", type: "blob", sha: (await bRes.json()).sha });
    }

    // 4. Nuevo tree
    const treeRes = await fetch(`${API}/git/trees`, {
      method: "POST", headers,
      body: JSON.stringify({ base_tree: baseTree, tree: treeEntries }),
    });
    if (!treeRes.ok) return Response.json({ error: 'tree fallo', detail: await treeRes.text() }, { status: 502 });
    const newTreeSha = (await treeRes.json()).sha;

    // 5. Commit
    const newCommitRes = await fetch(`${API}/git/commits`, {
      method: "POST", headers,
      body: JSON.stringify({ message, tree: newTreeSha, parents: [mainSha] }),
    });
    if (!newCommitRes.ok) return Response.json({ error: 'commit fallo', detail: await newCommitRes.text() }, { status: 502 });
    const newCommitSha = (await newCommitRes.json()).sha;

    // 6. Actualizar ref main
    const patchRes = await fetch(`${API}/git/refs/heads/main`, {
      method: "PATCH", headers,
      body: JSON.stringify({ sha: newCommitSha }),
    });
    if (!patchRes.ok) return Response.json({ error: 'ref fallo', detail: await patchRes.text() }, { status: 502 });

    // 7. Release (crea el tag automaticamente)
    const tag = version.startsWith("v") ? version : "v" + version;
    const relRes = await fetch(`${API}/releases`, {
      method: "POST", headers,
      body: JSON.stringify({ tag_name: tag, target_commitish: "main", name: tag, body: message }),
    });
    const relJson = await relRes.json();
    if (!relRes.ok) return Response.json({ error: 'release fallo', detail: relJson }, { status: 502 });

    return Response.json({
      ok: true,
      version: tag,
      commit: newCommitSha,
      files: files.length,
      release_url: relJson.html_url,
      release_id: relJson.id,
    });
  } catch (error) {
    return Response.json({ error: error.message }, { status: 500 });
  }
}