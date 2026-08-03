import base44 from "@base44/vite-plugin"
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'
import fs from 'node:fs'
import path from 'node:path'

// Resolve + load non-JS text files (.sh, .py, .html, .sql, ...) imported via the
// @/ alias so the base44 plugin never gets to parse them as JavaScript.
function rawTextFallback() {
  const nonJs = ['sh','py','html','txt','sql','conf','ini','toml','yaml','yml','c','h','service','md']
  const root = process.cwd()
  const extOf = (p) => p.split('.').pop()?.toLowerCase()
  return {
    name: 'raw-text-fallback',
    enforce: 'pre',
    buildStart() {
      try {
        const destDir = path.resolve(root, 'public')
        if (!fs.existsSync(destDir)) fs.mkdirSync(destDir, { recursive: true })
        const inst = path.resolve(root, 'instalador.sh')
        if (fs.existsSync(inst)) fs.copyFileSync(inst, path.resolve(destDir, 'instalador.sh'))
        const instrpi = path.resolve(root, 'instalador_rpi.sh')
        if (fs.existsSync(instrpi)) fs.copyFileSync(instrpi, path.resolve(destDir, 'instalador_rpi.sh'))
        const instclient = path.resolve(root, 'instalador_client.sh')
        if (fs.existsSync(instclient)) fs.copyFileSync(instclient, path.resolve(destDir, 'instalador_client.sh'))
        const srcRoot = path.resolve(root, 'src')
        const destSrc = path.resolve(destDir, 'source', 'src')
        try { fs.rmSync(path.resolve(destDir, 'source'), { recursive: true, force: true }) } catch {}
        const manifest = []
        const skip = new Set(['__pycache__', '.git', 'node_modules'])
        const copyDir = (d, rel) => {
          if (!fs.existsSync(d)) return
          for (const e of fs.readdirSync(d)) {
            if (skip.has(e)) continue
            const fp = path.join(d, e)
            const r = rel ? rel + '/' + e : e
            const st = fs.statSync(fp)
            if (st.isDirectory()) copyDir(fp, r)
            else {
              const dp = path.resolve(destSrc, r)
              fs.mkdirSync(path.dirname(dp), { recursive: true })
              fs.copyFileSync(fp, dp)
              manifest.push('src/' + r)
            }
          }
        }
        copyDir(srcRoot, '')
        fs.writeFileSync(path.resolve(destDir, 'source-manifest.json'), JSON.stringify(manifest))
      } catch {}
    },
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        const u = (req.url || '').split('?')[0];
        if (u === '/instalador.sh') {
          try {
            const c = fs.readFileSync(path.resolve(root, 'instalador.sh'));
            res.setHeader('Content-Type', 'text/plain; charset=utf-8');
            res.end(c);
            return;
          } catch (e) {}
        }
        if (u === '/instalador_rpi.sh') {
          try {
            const c = fs.readFileSync(path.resolve(root, 'instalador_rpi.sh'));
            res.setHeader('Content-Type', 'text/plain; charset=utf-8');
            res.end(c);
            return;
          } catch (e) {}
        }
        if (u === '/instalador_client.sh') {
          try {
            const c = fs.readFileSync(path.resolve(root, 'instalador_client.sh'));
            res.setHeader('Content-Type', 'text/plain; charset=utf-8');
            res.end(c);
            return;
          } catch (e) {}
        }
        next();
      });
    },
    resolveId(source) {
      if (!source || !source.startsWith('@/')) return null
      const stripped = source.replace(/[?#].*$/, '')
      const abs = path.resolve(root, 'src', stripped.slice(3))
      if (!nonJs.includes(extOf(abs))) return null
      return abs
    },
    load(id) {
      if (!id) return null
      const filePath = id.replace(/[?#].*$/, '')
      if (filePath.endsWith('/index.html')) return null
      if (!nonJs.includes(extOf(filePath))) return null
      try {
        const content = fs.readFileSync(filePath, 'utf-8')
        return `export default ${JSON.stringify(content)}`
      } catch {
        return null
      }
    }
  }
}

// https://vite.dev/config/
export default defineConfig({
  plugins: [
    rawTextFallback(),
    base44({
      // Support for legacy code that imports the base44 SDK with @/integrations, @/entities, etc.
      // can be removed if the code has been updated to use the new SDK imports from @base44/sdk
      legacySDKImports: process.env.BASE44_LEGACY_SDK_IMPORTS === 'true',
      hmrNotifier: true,
      navigationNotifier: true,
      analyticsTracker: true,
      visualEditAgent: true
    }),
    react()
  ],
  assetsInclude: ['**/*.sh','**/*.py','**/*.html','**/*.sql','**/*.conf','**/*.service','**/*.txt','**/*.ini','**/*.toml','**/*.yaml','**/*.yml']
});