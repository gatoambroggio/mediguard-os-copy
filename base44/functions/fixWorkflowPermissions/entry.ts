import { createClientFromRequest } from 'npm:@base44/sdk@0.8.44';

const OWNER = "gatoambroggio";
const REPO = "mediguard-os-copy";
const WORKFLOW_PATH = ".github/workflows/build-firmware.yml";
const API = "https://api.github.com";

// Workflow YAML con permissions: contents: write (el fix que no llegaba al repo)
const WORKFLOW_YAML = `name: Build Firmware POCSAG 512 baud + 149.255 MHz

on:
  push:
    branches: [main]
    paths:
      - 'src/zetronpoc/firmware/mmdvm_hs_512/**'
  workflow_dispatch:

permissions:
  contents: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repo
        uses: actions/checkout@v4

      - name: Install ARM GCC toolchain
        run: |
          sudo apt-get update
          sudo apt-get install -y gcc-arm-none-eabi libstdc++-arm-none-eabi-newlib libnewlib-arm-none-eabi

      - name: Clone & patch MMDVM_HS
        working-directory: src/zetronpoc/firmware/mmdvm_hs_512
        run: |
          chmod +x clone_and_patch.sh
          ./clone_and_patch.sh

      - name: Verify patches
        working-directory: src/zetronpoc/firmware/mmdvm_hs_512
        run: |
          python3 tools/verify_patches.py MMDVM_HS

      - name: Build firmware
        working-directory: src/zetronpoc/firmware/mmdvm_hs_512
        run: |
          chmod +x build_firmware.sh
          ./build_firmware.sh

      - name: Verify .bin was generated
        run: |
          BIN="src/zetronpoc/firmware/mmdvm_hs_512/firmware_pocsag512_149mhz.bin"
          if [ ! -f "$BIN" ]; then
            echo "ERROR: no se genero $BIN"
            exit 1
          fi
          echo "Binary generated: $BIN ($(stat -c%s "$BIN") bytes)"

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: firmware_pocsag512_149mhz
          path: src/zetronpoc/firmware/mmdvm_hs_512/firmware_pocsag512_149mhz.bin

      - name: Create Release
        if: github.ref == 'refs/heads/main'
        uses: softprops/action-gh-release@v2
        with:
          tag_name: pocsag512-149mhz-latest
          name: Firmware POCSAG 512 baud + 149.255 MHz
          body: |
            Firmware MMDVM_HS compilado con:
            - TCXO: 14.7456 MHz (OSC=14745600)
            - Frecuencia: VHF1_MAX extendido a 150 MHz (soporta 149.255 MHz)
            - Baud: 512 baud POCSAG (REG3 del ADF7021 reconfigurado)
            - Board: Nano_hotSPOT (BI7JTA), DUPLEX (match oficial), UART host
            - Build: make bl (con USB DFU bootloader), flashable a 0x08000000

            Flashear por serial:
              sudo apt install stm32flash gpiod
              sudo ./flash.sh firmware_pocsag512_149mhz.bin
          files: src/zetronpoc/firmware/mmdvm_hs_512/firmware_pocsag512_149mhz.bin
          prerelease: false
          draft: false
`;

function b64encode(str) {
  const bytes = new TextEncoder().encode(str);
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

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
    const isAuthed = await base44.auth.isAuthenticated().catch(() => false);
    if (!isAuthed) {
      return Response.json({ error: "Unauthorized" }, { status: 401 });
    }
    const user = await base44.auth.me();
    if (!user) return Response.json({ error: "Unauthorized" }, { status: 401 });
    if (user.role !== "admin") {
      return Response.json({ error: "Forbidden: admin only" }, { status: 403 });
    }

    const { accessToken } = await base44.asServiceRole.connectors.getConnection("github");
    if (!accessToken) throw new Error("Conector GitHub no autorizado");

    // 1. Get current file (need its SHA to update)
    let currentSha = null;
    let alreadyFixed = false;
    try {
      const current = await gh(
        `/repos/${OWNER}/${REPO}/contents/${encodeURIComponent(WORKFLOW_PATH)}?ref=main`,
        {},
        accessToken
      );
      currentSha = current.sha;
      const currentContent = b64decode(current.content);
      alreadyFixed = currentContent.includes("permissions:") &&
                      currentContent.includes("contents: write");
    } catch (e) {
      // 404 = file doesn't exist yet, that's fine — we create it
    }

    if (alreadyFixed) {
      return Response.json({
        ok: true,
        already_fixed: true,
        message: "El workflow ya tiene permissions: contents: write. No hace falta commitear.",
        path: WORKFLOW_PATH,
      });
    }

    // 2. PUT the new content (create or update)
    const commit = await gh(
      `/repos/${OWNER}/${REPO}/contents/${encodeURIComponent(WORKFLOW_PATH)}`,
      {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          message: "fix: add permissions: contents: write to firmware workflow",
          content: b64encode(WORKFLOW_YAML),
          branch: "main",
          sha: currentSha || undefined,
        }),
      },
      accessToken
    );

    return Response.json({
      ok: true,
      commit_sha: commit.commit.sha,
      commit_url: `https://github.com/${OWNER}/${REPO}/commit/${commit.commit.sha}`,
      path: WORKFLOW_PATH,
      message: "Workflow commiteado con permissions: contents: write. El proximo run del workflow creara el Release.",
    });
  } catch (error) {
    return Response.json({ error: error.message || String(error) }, { status: 500 });
  }
}