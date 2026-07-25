import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { SuiMinter } from './chains/sui.js';
import { walrusAggregator } from './config.js';
import type { Performance } from './provenance.js';

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
// Optional public base override for the claim QR. Without one, each request
// derives its public origin from Vercel's forwarded headers, so preview,
// production, and custom-domain deployments all emit reachable URLs.
const CONFIGURED_CLAIM_PUBLIC_URL = process.env.CLAIM_PUBLIC_URL?.replace(/\/+$/, '');

function firstHeader(value: string | string[] | undefined): string | undefined {
  const first = (Array.isArray(value) ? value[0] : value)?.split(',', 1)[0]?.trim();
  return first || undefined;
}

function publicOrigin(req: IncomingMessage): string {
  if (CONFIGURED_CLAIM_PUBLIC_URL) return CONFIGURED_CLAIM_PUBLIC_URL;

  const host = firstHeader(req.headers['x-forwarded-host']) ?? firstHeader(req.headers.host);
  const protocol =
    firstHeader(req.headers['x-forwarded-proto']) ?? (process.env.VERCEL ? 'https' : 'http');
  if (host) {
    try {
      return new URL(`${protocol}://${host}`).origin;
    } catch {
      // Fall through to Vercel's system hostname or the local rehearsal URL.
    }
  }

  const vercelHost =
    process.env.VERCEL_PROJECT_PRODUCTION_URL ?? process.env.VERCEL_URL;
  return vercelHost ? `https://${vercelHost}` : `http://localhost:${PORT}`;
}

function json(res: ServerResponse, status: number, body: unknown) {
  // charset=utf-8 is explicit on purpose: lyrics are Portuguese, and a viewer
  // with no declared charset falls back to Latin-1 and renders "é" as "Ã©".
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(body));
}

async function readBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString('utf8');
}

function claimUrl(origin: string, releaseRef: string): string {
  return `${origin}/claim?release=${encodeURIComponent(releaseRef)}`;
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

type ComposeMode = 'webp' | 'gif' | 'collage' | 'final';

/** Optional numeric env override (undefined → use the composer's default). */
function numEnv(name: string): number | undefined {
  const v = process.env[name];
  const n = v ? Number(v) : NaN;
  return Number.isFinite(n) ? n : undefined;
}

/** How frames are fitted onto the animation canvas: 'contain' (default, never
 * crops — letterboxes mixed aspect ratios) or 'cover' (fills, crops overflow). */
function fitEnv(): 'contain' | 'cover' | undefined {
  return process.env.MINT_FIT === 'cover' ? 'cover' : undefined;
}

interface MintImage {
  image: Buffer;
  kind: string;
  ext: string;
  contentType: string;
}

/** sharp format name → file extension + MIME. */
function mimeFor(fmt: string | undefined): { ext: string; contentType: string } {
  switch (fmt) {
    case 'webp':
      return { ext: 'webp', contentType: 'image/webp' };
    case 'gif':
      return { ext: 'gif', contentType: 'image/gif' };
    case 'jpeg':
    case 'jpg':
      return { ext: 'jpg', contentType: 'image/jpeg' };
    default:
      return { ext: 'png', contentType: 'image/png' };
  }
}

function mimeForExt(ext: string): string {
  return mimeFor(ext.toLowerCase()).contentType;
}

/**
 * Image tooling (sharp + the composers) is loaded only when a release is
 * actually being minted. It pulls native binaries, and the public claim
 * deployment never composes anything — so the audience-facing routes must not
 * depend on it loading at all.
 */
async function imageTools() {
  const [{ default: sharp }, compose] = await Promise.all([
    import('sharp'),
    import('./compose.js'),
  ]);
  return { sharp, ...compose };
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
): Promise<MintImage> {
  const { sharp, composeAnimatedGif, composeAnimatedWebp, composeCollage } = await imageTools();
  const finalStill = Buffer.from(imageBase64, 'base64');
  const asFinal = async (): Promise<MintImage> => {
    const meta = await sharp(finalStill).metadata().catch(() => ({ format: 'png' }));
    return { image: finalStill, kind: 'final', ...mimeFor(meta.format) };
  };

  if (mode === 'final' || !frameUrls || frameUrls.length < 2) return asFinal();
  try {
    // Pre-trim before the (bandwidth-heavy) fetch, but well above the composer's
    // frame cap so a normal song's beats are all fetched, not thinned early.
    const picked = sampleUrls(frameUrls, 200);
    const frames = (await Promise.all(picked.map(resolveFrame))).filter(
      (b): b is Buffer => b !== null,
    );
    if (frames.length < 2) return asFinal();

    if (mode === 'collage') {
      const image = await composeCollage(frames, { maxSide: numEnv('MINT_COLLAGE_MAX_SIDE') });
      return { image, kind: `collage (${frames.length} frames)`, ext: 'png', contentType: 'image/png' };
    }
    if (mode === 'gif') {
      const image = await composeAnimatedGif(frames, {
        maxFrames: numEnv('MINT_GIF_MAX_FRAMES'),
        maxSide: numEnv('MINT_GIF_MAX_SIDE'),
        fit: fitEnv(),
        frameMs: numEnv('MINT_FRAME_MS'),
        maxTotalMs: numEnv('MINT_GIF_MS'),
      });
      return { image, kind: `gif (${frames.length} frames)`, ext: 'gif', contentType: 'image/gif' };
    }
    // Default: animated WebP — full colour, smaller, fits the whole song.
    const image = await composeAnimatedWebp(frames, {
      maxFrames: numEnv('MINT_GIF_MAX_FRAMES'),
      maxSide: numEnv('MINT_GIF_MAX_SIDE'),
      fit: fitEnv(),
      frameMs: numEnv('MINT_FRAME_MS'),
      maxTotalMs: numEnv('MINT_GIF_MS'),
      quality: numEnv('MINT_WEBP_QUALITY'),
    });
    return { image, kind: `webp (${frames.length} frames)`, ext: 'webp', contentType: 'image/webp' };
  } catch (err) {
    console.warn(`[mint] compose failed, using final still: ${(err as Error).message}`);
    return asFinal();
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

  const { image, kind, ext } = await buildMintImage(
    body.imageBase64,
    body.frameUrls,
    body.mode ?? 'webp',
  );
  console.log(`[mint] minting image: ${kind}, ${image.length} bytes`);

  // If a public image base is set, the on-chain image_url points at our proxy
  // (which serves the right Content-Type + extension, so it renders in every
  // wallet); otherwise it's the raw Walrus URL. Either way walrus_blob_id is
  // stored on-chain, so the blob stays independently retrievable.
  const imageBase = process.env.MINT_IMAGE_BASE?.replace(/\/$/, '');
  const [{ createRelease }, { WalrusStorage }] = await Promise.all([
    import('./paint-and-mint.js'),
    import('./storage/walrus.js'),
  ]);
  const result = await createRelease({
    image,
    performance: body.performance,
    storage: new WalrusStorage(),
    minters: [new SuiMinter()],
    imageUrl: imageBase ? (s) => `${imageBase}/img/${s.id}.${ext}` : undefined,
  });

  const rel = result.releases[0];
  const origin = publicOrigin(req);
  const onChainImage = imageBase
    ? `${imageBase}/img/${result.stored.id}.${ext}`
    : result.stored.uri;
  json(res, 200, {
    releaseRef: rel?.releaseRef,
    masterTokenId: rel?.masterTokenId,
    txId: rel?.txId,
    explorerUrl: rel?.explorerUrl,
    provenanceHash: result.provenanceHash,
    // The hash preimage: fetch this to read every prompt and model, and to
    // recompute the hash yourself. `GET /provenance/:blobId` verifies it for you.
    //
    // Prefer `provenanceVerifyUrl` for reading: Walrus serves blobs with no
    // content-type, so opening the raw URI in a browser decodes the UTF-8
    // lyrics as Latin-1 ("é" -> "Ã©"). The bytes are correct either way.
    provenanceUri: result.provenance.uri,
    provenanceBlobId: result.provenance.id,
    provenanceVerifyUrl: `${origin}/provenance/${result.provenance.id}`,
    traits: result.traits,
    imageUri: onChainImage,
    walrusUri: result.stored.uri,
    blobId: result.stored.id,
    claimUrl: rel?.releaseRef ? claimUrl(origin, rel.releaseRef) : undefined,
  });
}

async function handleClaim(req: IncomingMessage, res: ServerResponse) {
  const body = JSON.parse(await readBody(req)) as { release?: string; to?: string };
  if (!body.release) return json(res, 400, { error: 'release is required' });
  const receipt = await new SuiMinter().claimPrint(body.release, body.to);
  json(res, 200, receipt);
}

/** Everything needed to display and verify a release. */
interface Certificate {
  release: string;
  onChain: Record<string, unknown> | null;
  traits: Record<string, unknown>;
  /** The hash preimage: prompts, models, transcript. Null if not stored. */
  record: Record<string, unknown> | null;
  /** SHA-256 recomputed from the fetched preimage. */
  computedHash: string | null;
  /** True when the recomputed hash equals the hash minted on-chain. */
  verified: boolean;
  error?: string;
}

/**
 * Assemble a release's certificate: on-chain fields, plus the provenance
 * preimage fetched from storage and re-hashed. The verification is done HERE,
 * server-side, rather than trusting anything the page is handed — an unverified
 * certificate is just a nice-looking claim.
 */
async function buildCertificate(release: string): Promise<Certificate> {
  const base: Certificate = {
    release,
    onChain: null,
    traits: {},
    record: null,
    computedHash: null,
    verified: false,
  };

  try {
    const fields = await new SuiMinter().getRelease(release);
    if (!fields) return { ...base, error: 'release not found on chain' };

    let traits: Record<string, unknown> = {};
    try {
      traits = typeof fields.traits === 'string' ? JSON.parse(fields.traits) : {};
    } catch {
      /* traits stay empty — a malformed blob shouldn't hide the rest */
    }

    const blobId = typeof traits.provenance_blob === 'string' ? traits.provenance_blob : null;
    if (!blobId) {
      // Minted before the preimage was stored: on-chain data still displays.
      return { ...base, onChain: fields, traits, error: 'no provenance preimage stored' };
    }

    const r = await fetch(`${walrusAggregator}/v1/blobs/${blobId}`);
    if (!r.ok) return { ...base, onChain: fields, traits, error: `walrus ${r.status}` };

    const raw = Buffer.from(await r.arrayBuffer());
    const computedHash = createHash('sha256').update(raw).digest('hex');
    const onChainHash = String(fields.provenance_hash ?? '');

    return {
      release,
      onChain: fields,
      traits,
      // Decoded as UTF-8 explicitly; the lyrics are Portuguese.
      record: JSON.parse(raw.toString('utf8')),
      computedHash,
      verified: computedHash === onChainHash,
    };
  } catch (err) {
    return { ...base, error: (err as Error).message };
  }
}

/** Minimal self-contained claim page — the QR target. No external assets. */
function claimPage(release: string, cert: Certificate): string {
  const f = (cert.onChain ?? {}) as Record<string, any>;
  const rec = (cert.record ?? {}) as Record<string, any>;
  const models = (rec.models ?? {}) as Record<string, any>;
  const steps: any[] = Array.isArray(rec.steps) ? rec.steps : [];

  const esc = (s: unknown) =>
    String(s ?? '').replace(/[&<>"]/g, (c) =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c] as string,
    );
  const short = (s: unknown, n = 10) => {
    const v = String(s ?? '');
    return v.length > n * 2 ? `${v.slice(0, n)}…${v.slice(-6)}` : v;
  };
  const modelName = (m: any) =>
    !m ? '—' : [m.provider, m.model].filter(Boolean).join(' · ') || '—';

  const imageUrl = f.image_url ? String(f.image_url) : '';
  const song = f.song ? String(f.song) : 'Untitled';
  const artist = f.artist ? String(f.artist) : '';
  const venue = f.venue ? String(f.venue) : '';
  const when = f.created_at_ms ? new Date(Number(f.created_at_ms)).toLocaleString() : '';

  const directorModels: any[] = Array.isArray(models.director) ? models.director : [];
  const chainRows = [
    ['Speech-to-text', modelName(models.stt)],
    ['Director (LLM)', directorModels.map(modelName).join(', ') || '—'],
    [
      'Image',
      models.image
        ? `${modelName(models.image)}${models.image.route ? ` · ${models.image.route}` : ''}${
            models.image.steps ? ` · ${models.image.steps} steps` : ''
          }`
        : '—',
    ],
    ['Render mode', models.renderMode ?? '—'],
  ]
    .map(
      ([k, v]) =>
        `<div class="row"><span class="k">${esc(k)}</span><span class="v">${esc(v)}</span></div>`,
    )
    .join('');

  const stepRows = steps
    .map((s, i) => {
      const t = s?.t ? new Date(s.t).toLocaleTimeString() : '';
      return `<li><div class="stepmeta"><span class="num">${i + 1}</span><span class="time">${esc(
        t,
      )}</span><span class="model">${esc(modelName(s?.model))}</span></div><div class="prompt">${esc(
        s?.prompt,
      )}</div></li>`;
    })
    .join('');

  const verifyBadge = cert.verified
    ? `<div class="verify ok"><b>✓ Verified</b><span>The stored record hashes to the value minted on-chain.</span></div>`
    : `<div class="verify warn"><b>⚠ Unverified</b><span>${esc(
        cert.error ?? 'Recomputed hash does not match the on-chain hash.',
      )}</span></div>`;

  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sinestesia — ${esc(song)}</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin:0; background:#0b1410; color:#eafff2;
    font:16px/1.55 system-ui,-apple-system,Segoe UI,Roboto,sans-serif; }
  .wrap { max-width:760px; margin:0 auto; padding:28px 20px 64px; }
  header { text-align:center; margin-bottom:22px; }
  .brand { font-size:12px; letter-spacing:.22em; text-transform:uppercase; opacity:.55; }
  h1 { font-size:30px; margin:8px 0 2px; line-height:1.15; }
  .by { opacity:.75; }
  .when { font-size:13px; opacity:.5; margin-top:6px; }
  .art { width:100%; border-radius:14px; border:1px solid #ffffff14; display:block;
    background:#0f1a15; margin:20px 0; }
  .verify { display:flex; flex-direction:column; gap:2px; padding:12px 16px; border-radius:12px;
    margin-bottom:20px; font-size:14px; }
  .verify b { font-size:14px; }
  .verify span { opacity:.75; font-size:13px; }
  .verify.ok { background:#40e08a14; border:1px solid #40e08a55; }
  .verify.warn { background:#e0b04014; border:1px solid #e0b04055; }
  section { border:1px solid #ffffff12; border-radius:14px; padding:18px; margin-bottom:16px;
    background:#ffffff05; }
  h2 { font-size:12px; letter-spacing:.16em; text-transform:uppercase; opacity:.55;
    margin:0 0 12px; font-weight:600; }
  .row { display:flex; justify-content:space-between; gap:16px; padding:7px 0;
    border-bottom:1px solid #ffffff0a; font-size:14px; }
  .row:last-child { border-bottom:0; }
  .k { opacity:.6; flex:0 0 auto; }
  .v { text-align:right; word-break:break-word; }
  code { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12px; opacity:.85;
    word-break:break-all; }
  ol { list-style:none; margin:0; padding:0; counter-reset:s; }
  ol li { padding:11px 0; border-bottom:1px solid #ffffff0a; }
  ol li:last-child { border-bottom:0; }
  .stepmeta { display:flex; gap:10px; align-items:center; font-size:11px; opacity:.5;
    margin-bottom:3px; }
  .num { background:#40e08a22; color:#8ef0bb; border-radius:5px; padding:1px 6px; font-weight:600; }
  .prompt { font-size:14px; }
  .lyrics { font-size:14px; opacity:.8; white-space:pre-wrap; max-height:210px; overflow:auto; }
  a { color:#40e08a; }
  .actions { text-align:center; margin-top:26px; }
  button { padding:14px 26px; border-radius:999px; border:1px solid #40e08a;
    background:#40e08a22; color:#eafff2; font-size:16px; font-weight:600; cursor:pointer; }
  button:disabled { opacity:.5; cursor:default; }
  #out { margin-top:14px; font-size:14px; word-break:break-all; }
  .links { margin-top:14px; font-size:13px; opacity:.75; text-align:center; }
</style></head><body><div class="wrap">
  <header>
    <div class="brand">Sinestesia · Certificate of Authenticity</div>
    <h1>${esc(song)}</h1>
    ${artist ? `<div class="by">${esc(artist)}</div>` : ''}
    <div class="when">${esc([venue, when].filter(Boolean).join(' · '))}</div>
  </header>

  ${imageUrl ? `<img class="art" src="${esc(imageUrl)}" alt="${esc(song)}">` : ''}

  ${verifyBadge}

  <section>
    <h2>How it was made</h2>
    ${chainRows}
  </section>

  ${
    steps.length
      ? `<section><h2>Director prompts (${steps.length})</h2><ol>${stepRows}</ol></section>`
      : ''
  }

  ${
    rec.transcript
      ? `<section><h2>Transcript</h2><div class="lyrics">${esc(rec.transcript)}</div></section>`
      : ''
  }

  <section>
    <h2>On-chain</h2>
    <div class="row"><span class="k">Release</span><span class="v"><code>${esc(
      short(release, 12),
    )}</code></span></div>
    <div class="row"><span class="k">Provenance hash</span><span class="v"><code>${esc(
      short(f.provenance_hash, 12),
    )}</code></span></div>
    <div class="row"><span class="k">Prints minted</span><span class="v">${esc(
      f.prints_minted ?? '0',
    )}</span></div>
    <div class="row"><span class="k">Image blob</span><span class="v"><code>${esc(
      short(f.walrus_blob_id, 10),
    )}</code></span></div>
    ${
      cert.traits.provenance_blob
        ? `<div class="row"><span class="k">Provenance blob</span><span class="v"><code>${esc(
            short(cert.traits.provenance_blob, 10),
          )}</code></span></div>`
        : ''
    }
  </section>

  <div class="actions">
    <button id="go">Claim my print</button>
    <div id="out"></div>
    <div class="links">
      <a href="https://suiscan.xyz/testnet/object/${esc(release)}" target="_blank">View on Suiscan</a>
      · <a href="/certificate?release=${encodeURIComponent(release)}" target="_blank">Raw certificate</a>
      ${
        cert.traits.provenance_blob
          ? `· <a href="/provenance/${esc(cert.traits.provenance_blob)}" target="_blank">Verify provenance</a>`
          : ''
      }
    </div>
  </div>
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

/**
 * The whole router as one async function, so the identical code serves both the
 * local sidecar (`npm run serve`) and the serverless deployment (`api/index.ts`).
 * The claim page the audience scans is then literally the page we test locally —
 * it can't drift from a forked copy.
 */
export async function handleRequest(req: IncomingMessage, res: ServerResponse) {
  {
    {
      try {
      const url = new URL(req.url ?? '/', `http://localhost:${PORT}`);
      // Treat HEAD as GET: wallets, marketplaces and link-preview crawlers
      // HEAD-check an image URL before fetching it, and 404ing there can stop
      // the NFT from rendering. Node omits the body for HEAD automatically.
      const isGet = req.method === 'GET' || req.method === 'HEAD';

      if (isGet && url.pathname === '/healthz') {
        return json(res, 200, { ok: true });
      }
      if (req.method === 'POST' && url.pathname === '/release') {
        return await handleRelease(req, res);
      }
      if (req.method === 'POST' && url.pathname === '/claim') {
        return await handleClaim(req, res);
      }
      if (isGet && url.pathname === '/claim') {
        const release = url.searchParams.get('release');
        if (!release) return json(res, 400, { error: 'release query param required' });
        const cert = await buildCertificate(release);
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        return res.end(claimPage(release, cert));
      }
      // The same certificate as JSON, for anyone who'd rather verify than read.
      if (isGet && url.pathname === '/certificate') {
        const release = url.searchParams.get('release');
        if (!release) return json(res, 400, { error: 'release query param required' });
        return json(res, 200, await buildCertificate(release));
      }
      // The certificate of authenticity: fetch the provenance preimage from
      // storage, recompute its SHA-256, and hand back both. `?raw=1` returns the
      // exact canonical bytes the hash was taken over, so anyone can verify
      // independently rather than trusting this endpoint's own arithmetic.
      if (isGet && url.pathname.startsWith('/provenance/')) {
        const blobId = decodeURIComponent(url.pathname.slice('/provenance/'.length));
        if (!blobId) return json(res, 400, { error: 'blob id required' });
        const r = await fetch(`${walrusAggregator}/v1/blobs/${blobId}`);
        if (!r.ok) return json(res, 502, { error: `walrus ${r.status}` });
        const raw = Buffer.from(await r.arrayBuffer());

        if (url.searchParams.get('raw') === '1') {
          res.writeHead(200, {
            'Content-Type': 'application/json; charset=utf-8',
            'Access-Control-Allow-Origin': '*',
          });
          return res.end(raw);
        }

        const hash = createHash('sha256').update(raw).digest('hex');
        return json(res, 200, {
          provenanceHash: hash,
          blobId,
          // Compare `provenanceHash` against the value stored on-chain: equal
          // means this record is exactly what was minted, untampered.
          record: JSON.parse(raw.toString('utf8')),
        });
      }
      // Content-type-serving proxy for the NFT image: /img/<blobId>.<ext>.
      // Streams the Walrus blob with a proper image MIME + extension so the
      // image renders in wallets/marketplaces that require a content-type
      // (Walrus itself serves blobs untyped with nosniff).
      if (isGet && url.pathname.startsWith('/img/')) {
        const name = decodeURIComponent(url.pathname.slice('/img/'.length));
        const dot = name.lastIndexOf('.');
        const blobId = dot >= 0 ? name.slice(0, dot) : name;
        const ext = dot >= 0 ? name.slice(dot + 1) : 'bin';
        if (!blobId) return json(res, 400, { error: 'blob id required' });
        const r = await fetch(`${walrusAggregator}/v1/blobs/${blobId}`);
        if (!r.ok) return json(res, 502, { error: `walrus ${r.status}` });
        const buf = Buffer.from(await r.arrayBuffer());
        res.writeHead(200, {
          'Content-Type': mimeForExt(ext),
          'Cache-Control': 'public, max-age=31536000, immutable',
          'Access-Control-Allow-Origin': '*',
        });
        return res.end(buf);
      }
      json(res, 404, { error: 'not found' });
      } catch (err) {
        console.error('[mint] request failed:', err);
        json(res, 502, { error: (err as Error).message });
      }
    }
  }
}

<<<<<<< HEAD
/** Start the local sidecar. Not called when imported by the serverless entry. */
export function startServer(port = PORT) {
  const server = createServer((req, res) => void handleRequest(req, res));
  server.listen(port, () => {
    console.log(`[mint] sidecar on http://127.0.0.1:${port}`);
    console.log(`[mint] claim QR base: ${CLAIM_PUBLIC_URL}`);
  });
  return server;
}

// Only listen when run directly (`tsx src/server.ts`), not when imported.
if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  startServer();
}
=======
server.listen(PORT, () => {
  console.log(`[mint] sidecar on http://127.0.0.1:${PORT}`);
  console.log(
    `[mint] claim QR base: ${CONFIGURED_CLAIM_PUBLIC_URL ?? 'derived from each request'}`,
  );
});
>>>>>>> 0c8b8c8c (Fix Vercel mint deployment URLs and types)
