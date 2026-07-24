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
  /**
   * Per-frame delay in ms — how long each beat of the painting is held. This is
   * the main pacing knob; the default is deliberately unhurried so a viewer can
   * actually read each new element appearing.
   */
  frameMs?: number;
  /**
   * Optional total-duration cap (ms). When set, the per-frame delay is the
   * smaller of `frameMs` and `maxTotalMs / frames`, so a very long song can be
   * kept to a bounded loop. Unset by default: pacing wins over total length.
   */
  maxTotalMs?: number;
  /** Hold the last frame this many ms so the finished painting lingers. */
  holdLastMs?: number;
}

/** Per-frame delay: unhurried by default, optionally squeezed by a total cap. */
function frameDelay(count: number, opts: GifOptions): number {
  const target = opts.frameMs ?? 600;
  const capped = opts.maxTotalMs ? Math.min(target, opts.maxTotalMs / count) : target;
  return Math.max(60, Math.round(capped));
}

export async function composeAnimatedGif(frames: Buffer[], opts: GifOptions = {}): Promise<Buffer> {
  if (frames.length === 0) throw new Error('no frames to compose');
  // The backend sends one keyframe per Director beat (~40–60 for a 4-min song),
  // NOT the interpolation frames — so a normal song fits under this cap and every
  // beat is included (cutting beats would lose the song's essence). Sampling is
  // only a safety valve for pathological counts. maxSide keeps 60 frames to a
  // sane weight; raise either via env for higher fidelity.
  const maxFrames = opts.maxFrames ?? 120;
  const maxSide = opts.maxSide ?? 384;
  const holdLastMs = opts.holdLastMs ?? 2_000;

  const selected = sampleEvenly(frames, maxFrames);

  // Canvas size from the first frame's aspect ratio, clamped to maxSide, even dims.
  const meta = await sharp(selected[0]!).metadata();
  const ar = (meta.width ?? 1) / (meta.height ?? 1);
  let w = ar >= 1 ? maxSide : Math.round(maxSide * ar);
  let h = ar >= 1 ? Math.round(maxSide / ar) : maxSide;
  w -= w % 2;
  h -= h % 2;

  const delay = frameDelay(selected.length, opts);

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

/**
 * Same idea as the GIF, but animated WebP: full colour (no 256-colour banding)
 * and roughly half to a third the size, so the *entire* song fits comfortably.
 * The default artifact.
 */
export async function composeAnimatedWebp(frames: Buffer[], opts: GifOptions & { quality?: number } = {}): Promise<Buffer> {
  if (frames.length === 0) throw new Error('no frames to compose');
  const maxFrames = opts.maxFrames ?? 120;
  const maxSide = opts.maxSide ?? 448;
  const holdLastMs = opts.holdLastMs ?? 2_000;
  const quality = opts.quality ?? 70;

  const selected = sampleEvenly(frames, maxFrames);
  const meta = await sharp(selected[0]!).metadata();
  const ar = (meta.width ?? 1) / (meta.height ?? 1);
  let w = ar >= 1 ? maxSide : Math.round(maxSide * ar);
  let h = ar >= 1 ? Math.round(maxSide / ar) : maxSide;
  w -= w % 2;
  h -= h % 2;

  // All frames must share dimensions before joining into an animation.
  const resized = await Promise.all(
    selected.map((f) => sharp(f).resize(w, h, { fit: 'cover' }).toBuffer()),
  );
  const per = frameDelay(resized.length, opts);
  const delays = resized.map((_, i) => (i === resized.length - 1 ? per + holdLastMs : per));

  return sharp(resized, { join: { animated: true } })
    .webp({ quality, effort: 4, delay: delays, loop: 0 })
    .toBuffer();
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
  const maxSide = opts.maxSide ?? 900;
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
