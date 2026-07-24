import { createServer } from 'node:http';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { createRelease } from './paint-and-mint.js';
import { WalrusStorage } from './storage/walrus.js';
import { SuiMinter } from './chains/sui.js';
import type { Performance } from './provenance.js';
import { composeAnimatedGif, composeCollage } from './compose.js';

/**
 * HTTP sidecar around the mint pipeline, so the live show can mint the finished
 * painting the instant a song ends. The Elixir backend POSTs the final image +
 * the performance record; we store on Walrus, mint the master 1/1 on Sui, open
 * the print window, and hand back a claim URL for the QR overlay.
 *
 *   GET  /healthz               → ok
 *   POST /release               → { imageBase64, performance } → release receipt
 *   POST /claim                 → { release, to? } → print receipt
 *   GET  /claim?release=<id>    → minimal page that claims a print (QR target)
 *
 * `/claim` (GET) is the audience path: scanning the QR opens a page that mints a
 * free print. For the demo the show wallet pays gas; a production build would
 * connect the visitor's own wallet instead (the POST /claim contract is ready
 * for that — pass `to`).
 */

const PORT = Number(process.env.MINT_PORT ?? '8790');
// Public base the QR encodes. Set to a LAN/tunnel URL so phones can reach it;
// defaults to localhost for a single-machine rehearsal.
const CLAIM_PUBLIC_URL = process.env.CLAIM_PUBLIC_URL ?? `http://localhost:${PORT}`;

function json(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

async function readBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString('utf8');
}

function claimUrl(releaseRef: string): string {
  return `${CLAIM_PUBLIC_URL}/claim?release=${encodeURIComponent(releaseRef)}`;
}

/** Resolve a frame reference (https URL or inline data: URL) to bytes. */
async function resolveFrame(ref: string): Promise<Buffer | null> {
  try {
    if (ref.startsWith('data:')) {
      const b64 = ref.split(',', 2)[1];
      return b64 ? Buffer.from(b64, 'base64') : null;
    }
    const r = await fetch(ref);
    return r.ok ? Buffer.from(await r.arrayBuffer()) : null;
  } catch {
    return null;
  }
}

/** Evenly sample down to `max` before the (bandwidth-heavy) fetch. */
function sampleUrls(urls: string[], max: number): string[] {
  if (urls.length <= max) return urls;
  const out: string[] = [];
  const step = (urls.length - 1) / (max - 1);
  for (let i = 0; i < max; i++) out.push(urls[Math.round(i * step)]!);
  return out;
}

type ComposeMode = 'gif' | 'collage' | 'final';

/** Optional numeric env override (undefined → use the composer's default). */
function numEnv(name: string): number | undefined {
  const v = process.env[name];
  const n = v ? Number(v) : NaN;
  return Number.isFinite(n) ? n : undefined;
}

/**
 * Decide what image actually gets minted. With the song's frame sequence and
 * mode "gif"/"collage", compose the whole-song artifact; otherwise (or on any
 * failure) fall back to the final still in `imageBase64`.
 */
async function buildMintImage(
  imageBase64: string,
  frameUrls: string[] | undefined,
  mode: ComposeMode,
): Promise<{ image: Buffer; kind: string }> {
  const finalStill = Buffer.from(imageBase64, 'base64');
  if (mode === 'final' || !frameUrls || frameUrls.length < 2) {
    return { image: finalStill, kind: 'final' };
  }
  try {
    const picked = sampleUrls(frameUrls, 72);
    const frames = (await Promise.all(picked.map(resolveFrame))).filter(
      (b): b is Buffer => b !== null,
    );
    if (frames.length < 2) return { image: finalStill, kind: 'final' };
    const image =
      mode === 'collage'
        ? await composeCollage(frames, { maxSide: numEnv('MINT_COLLAGE_MAX_SIDE') })
        : await composeAnimatedGif(frames, {
            maxFrames: numEnv('MINT_GIF_MAX_FRAMES'),
            maxSide: numEnv('MINT_GIF_MAX_SIDE'),
            maxTotalMs: numEnv('MINT_GIF_MS'),
          });
    return { image, kind: `${mode} (${frames.length} frames)` };
  } catch (err) {
    console.warn(`[mint] compose failed, using final still: ${(err as Error).message}`);
    return { image: finalStill, kind: 'final' };
  }
}

async function handleRelease(req: IncomingMessage, res: ServerResponse) {
  const body = JSON.parse(await readBody(req)) as {
    imageBase64?: string;
    frameUrls?: string[];
    mode?: ComposeMode;
    performance?: Performance;
  };
  if (!body.imageBase64 || !body.performance) {
    return json(res, 400, { error: 'imageBase64 and performance are required' });
  }

  const { image, kind } = await buildMintImage(body.imageBase64, body.frameUrls, body.mode ?? 'gif');
  console.log(`[mint] minting image: ${kind}, ${image.length} bytes`);
  const result = await createRelease({
    image,
    performance: body.performance,
    storage: new WalrusStorage(),
    minters: [new SuiMinter()],
  });

  const rel = result.releases[0];
  json(res, 200, {
    releaseRef: rel?.releaseRef,
    masterTokenId: rel?.masterTokenId,
    txId: rel?.txId,
    explorerUrl: rel?.explorerUrl,
    provenanceHash: result.provenanceHash,
    traits: result.traits,
    imageUri: result.stored.uri,
    blobId: result.stored.id,
    claimUrl: rel?.releaseRef ? claimUrl(rel.releaseRef) : undefined,
  });
}

async function handleClaim(req: IncomingMessage, res: ServerResponse) {
  const body = JSON.parse(await readBody(req)) as { release?: string; to?: string };
  if (!body.release) return json(res, 400, { error: 'release is required' });
  const receipt = await new SuiMinter().claimPrint(body.release, body.to);
  json(res, 200, receipt);
}

/** Minimal self-contained claim page — the QR target. No external assets. */
function claimPage(release: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sinestesia — claim your print</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center;
    background:#0b1410; color:#eafff2; font:16px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif; }
  .card { max-width:420px; padding:28px; text-align:center; }
  h1 { font-size:20px; margin:0 0 6px; }
  .muted { opacity:.7; font-size:14px; }
  button { margin-top:18px; padding:13px 22px; border-radius:999px; border:1px solid #40e08a;
    background:#40e08a22; color:#eafff2; font-size:16px; font-weight:600; cursor:pointer; }
  button:disabled { opacity:.5; cursor:default; }
  a { color:#40e08a; }
  #out { margin-top:16px; font-size:14px; word-break:break-all; }
</style></head><body><div class="card">
  <h1>Sinestesia</h1>
  <div class="muted">Claim your free print of tonight's live painting.</div>
  <button id="go">Claim my print</button>
  <div id="out"></div>
<script>
  const rel = ${JSON.stringify(release)};
  const go = document.getElementById('go'), out = document.getElementById('out');
  go.onclick = async () => {
    go.disabled = true; out.textContent = 'Minting…';
    try {
      const r = await fetch('/claim', { method:'POST', headers:{'Content-Type':'application/json'},
        body: JSON.stringify({ release: rel }) });
      const j = await r.json();
      if (!r.ok) throw new Error(j.error || 'failed');
      out.innerHTML = 'You own print #' + j.edition + ' 🎉<br><a href="' + j.explorerUrl + '" target="_blank">view on-chain</a>';
    } catch (e) {
      out.textContent = 'Could not claim: ' + e.message; go.disabled = false;
    }
  };
</script></div></body></html>`;
}

const server = createServer((req, res) => {
  void (async () => {
    try {
      const url = new URL(req.url ?? '/', `http://localhost:${PORT}`);

      if (req.method === 'GET' && url.pathname === '/healthz') {
        return json(res, 200, { ok: true });
      }
      if (req.method === 'POST' && url.pathname === '/release') {
        return await handleRelease(req, res);
      }
      if (req.method === 'POST' && url.pathname === '/claim') {
        return await handleClaim(req, res);
      }
      if (req.method === 'GET' && url.pathname === '/claim') {
        const release = url.searchParams.get('release');
        if (!release) return json(res, 400, { error: 'release query param required' });
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        return res.end(claimPage(release));
      }
      json(res, 404, { error: 'not found' });
    } catch (err) {
      console.error('[mint] request failed:', err);
      json(res, 502, { error: (err as Error).message });
    }
  })();
});

server.listen(PORT, () => {
  console.log(`[mint] sidecar on http://127.0.0.1:${PORT}`);
  console.log(`[mint] claim QR base: ${CLAIM_PUBLIC_URL}`);
});
