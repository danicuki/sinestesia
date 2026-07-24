import sharp from 'sharp';
// gifenc ships as CommonJS; its functions live on the default export.
import gifenc from 'gifenc';
const { GIFEncoder, quantize, applyPalette } = gifenc;

/**
 * Turn the whole song's frame sequence into ONE artifact to mint — so the NFT
 * captures the painting *growing*, not just its final state.
 *
 *  - `composeAnimatedGif` — the frames played back as an animation (the default;
 *    the closest thing to "watch the AI paint the song").
 *  - `composeCollage` — a single contact-sheet grid, as a static fallback.
 *
 * Both are bounded so a long song can't blow up the blob: frames are sampled
 * down to a cap and downscaled, so 30 frames or 300 produce a similar-sized file
 * (that's the answer to "what if there are too many images").
 */

/** Evenly sample `buffers` down to at most `max` (keeps first + last). */
function sampleEvenly<T>(buffers: T[], max: number): T[] {
  if (buffers.length <= max) return buffers;
  const out: T[] = [];
  const step = (buffers.length - 1) / (max - 1);
  for (let i = 0; i < max; i++) out.push(buffers[Math.round(i * step)]!);
  return out;
}

export interface GifOptions {
  /** Cap on frames actually encoded (evenly sampled if more). */
  maxFrames?: number;
  /** Longest side in px; frames are cover-fit to a common size. */
  maxSide?: number;
  /** Target total loop duration (ms); per-frame delay is derived from it. */
  maxTotalMs?: number;
  /** Hold the last frame this many ms so the finished painting lingers. */
  holdLastMs?: number;
}

export async function composeAnimatedGif(frames: Buffer[], opts: GifOptions = {}): Promise<Buffer> {
  if (frames.length === 0) throw new Error('no frames to compose');
  const maxFrames = opts.maxFrames ?? 60;
  const maxSide = opts.maxSide ?? 512;
  const maxTotalMs = opts.maxTotalMs ?? 12_000;
  const holdLastMs = opts.holdLastMs ?? 1_500;

  const selected = sampleEvenly(frames, maxFrames);

  // Canvas size from the first frame's aspect ratio, clamped to maxSide, even dims.
  const meta = await sharp(selected[0]!).metadata();
  const ar = (meta.width ?? 1) / (meta.height ?? 1);
  let w = ar >= 1 ? maxSide : Math.round(maxSide * ar);
  let h = ar >= 1 ? Math.round(maxSide / ar) : maxSide;
  w -= w % 2;
  h -= h % 2;

  // Per-frame delay: fill maxTotalMs across the frames, but keep it watchable.
  const delay = Math.max(80, Math.min(500, Math.round(maxTotalMs / selected.length)));

  const enc = GIFEncoder();
  for (let i = 0; i < selected.length; i++) {
    const rgba = await sharp(selected[i]!)
      .resize(w, h, { fit: 'cover' })
      .ensureAlpha()
      .raw()
      .toBuffer();
    const data = new Uint8Array(rgba.buffer, rgba.byteOffset, rgba.byteLength);
    const palette = quantize(data, 256);
    const index = applyPalette(data, palette);
    const isLast = i === selected.length - 1;
    enc.writeFrame(index, w, h, { palette, delay: isLast ? delay + holdLastMs : delay });
  }
  enc.finish();
  return Buffer.from(enc.bytes());
}

export interface CollageOptions {
  /** Cap on cells (evenly sampled if more). */
  maxCells?: number;
  /** Longest side of the whole collage in px. */
  maxSide?: number;
  /** Gap between cells in px. */
  gap?: number;
}

export async function composeCollage(frames: Buffer[], opts: CollageOptions = {}): Promise<Buffer> {
  if (frames.length === 0) throw new Error('no frames to compose');
  const maxCells = opts.maxCells ?? 49; // 7×7 keeps thumbnails legible
  const maxSide = opts.maxSide ?? 1200;
  const gap = opts.gap ?? 6;

  const selected = sampleEvenly(frames, maxCells);
  const cols = Math.ceil(Math.sqrt(selected.length));
  const rows = Math.ceil(selected.length / cols);
  const cell = Math.floor((maxSide - gap * (cols + 1)) / cols);
  const width = cols * cell + gap * (cols + 1);
  const height = rows * cell + gap * (rows + 1);

  const tiles = await Promise.all(
    selected.map(async (f, i) => ({
      input: await sharp(f).resize(cell, cell, { fit: 'cover' }).toBuffer(),
      left: gap + (i % cols) * (cell + gap),
      top: gap + Math.floor(i / cols) * (cell + gap),
    })),
  );

  return sharp({
    create: { width, height, channels: 3, background: { r: 12, g: 16, b: 12 } },
  })
    .composite(tiles)
    .png()
    .toBuffer();
}
