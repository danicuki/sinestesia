// Rail 3 — expressive features, computed off the main thread.
//
// Per the scope we use Essentia.js where it's cheap and reliable (Loudness,
// SpectralCentroidTime). For the trickier ones (pitch salience, inharmonicity)
// and as a total fallback if the WASM fails to load on the venue laptop, we use
// compact hand-rolled DSP. The rail therefore NEVER hard-fails the demo.

let essentia: any = null;
let essentiaReady = false;

(async () => {
  try {
    const mod: any = await import("essentia.js");
    const EssentiaWASM = mod.EssentiaWASM ?? mod.default?.EssentiaWASM;
    const Essentia = mod.Essentia ?? mod.default?.Essentia;
    // EssentiaWASM may be a module object or a factory; both forms exist in the wild.
    const wasm =
      typeof EssentiaWASM === "function" ? await EssentiaWASM() : EssentiaWASM;
    essentia = new Essentia(wasm);
    essentiaReady = true;
  } catch (e) {
    // Stay on DSP fallback.
    essentiaReady = false;
  }
})();

interface Features {
  spectral_centroid: number;
  loudness: number;
  inharmonicity: number;
  pitch_salience: number;
  vocal_quality: "breathy" | "belted" | "intimate" | "soaring" | "neutral";
  arousal: number;
  valence: number;
  semiotics?: {
    passional: number;
    figurativo: number;
    tematico: number;
    oralization: number;
  };
}

interface Melody {
  contour?: string;
  register?: number;
  vibrato?: number;
  energy?: number;
}

self.onmessage = (ev: MessageEvent) => {
  const { pcm, sampleRate } = ev.data as {
    pcm: Float32Array;
    sampleRate: number;
  };
  if (!pcm || pcm.length === 0) return;
  const features = analyze(pcm, sampleRate);
  // Melodic descriptor from the f0 track over the window (null when too little
  // voiced pitch to be meaningful — the main thread then skips sending).
  const melody = computeMelody(pcm, sampleRate, features.loudness);
  features.semiotics = computeSemiotics(features, melody);
  (self as any).postMessage({ type: "features", features, melody });
};

function computeSemiotics(f: Features, m: Melody | null): Features["semiotics"] {
  // Gating de Silêncio (Noise Gate)
  // Se o volume geral for muito baixo (silêncio na sala / ruído de fundo leve),
  // retornamos undefined (ausência de atividade semiótica/silêncio).
  if (f.loudness <= 0.06) {
    return undefined;
  }

  const vib = m?.vibrato ?? 0;
  const salience = f.pitch_salience;
  const arousal = f.arousal;

  // Usamos valores normalizados para loudness e arousal para esticar a faixa de variação,
  // pois em condições normais de uso do microfone, loudness e arousal raramente atingem 1.0.
  const normLoudness = clamp01(f.loudness / 0.35);
  const normArousal = clamp01(arousal / 0.45);

  // 1. Passionalização (Lamento / Canto Lírico Emotivo)
  // Sobe com alto vibrato, qualidade soaring/intimate, e arousal expressivo.
  // Desativado se o pitch não for nítido (baixo salience).
  let passional = 0.45 * vib + 0.3 * (f.vocal_quality === "soaring" || f.vocal_quality === "intimate" ? 0.8 : 0.2) + 0.25 * normArousal;
  if (salience < 0.45) passional = 0;

  // 2. Figurativização (Canto-Fala / Oralização / Bossa / Declamado)
  // Sobe com baixo vibrato, pitch salience moderado (fala é ruidosa), qualidade breathy/intimate e contornos intonativos conversacionais.
  let figurativo = 0.35 * (1 - vib) + 0.3 * (1 - clamp01(salience - 0.2)) + 0.25 * (f.vocal_quality === "breathy" || f.vocal_quality === "intimate" ? 0.8 : 0.3);
  if (m?.contour === "wavering" || m?.contour === "leaping") {
    figurativo += 0.1;
  } else if (m?.contour === "steady") {
    figurativo -= 0.15;
  }

  // 3. Tematização (Rítmico / Dança)
  // Sobe com alta regularidade, energia melódica firme e contorno rítmico regular (steady ou estacato rítmico).
  const normEnergy = m ? clamp01(0.7 * normLoudness + 0.3 * (m.energy ?? 0.5)) : normLoudness;

  // Se houver melodia estável (steady) ou se for estacato rítmico (m === null, mas com som),
  // indica pulsação regular assertiva (motifs curtos e marcados, típicos de dança/marcha).
  const rhythmBonus = (m === null || m.contour === "steady") ? 0.8 : 0.3;
  let tematico = 0.4 * normEnergy + 0.3 * normArousal + 0.3 * rhythmBonus;

  // 4. Grau de Oralização (Marcelo Segreto - da fala pura ao canto puro)
  let oralization = 0;
  if (m === null) {
    // Se não há melodia estável acumulada nos últimos 2s e há som, indica fala fragmentada ou sussurro
    oralization = f.loudness > 0.05 ? 0.85 : 0.0;
  } else if (salience < 0.45) {
    oralization = 0.8 + 0.2 * (1 - vib);
  } else {
    // Canto (salience alta). Mapeamos a transição: salience >= 0.90 zera a oralidade, salience = 0.45 maximiza.
    const factor = clamp01((0.9 - salience) / 0.45);
    oralization = factor * (0.7 + 0.3 * (1 - vib));
  }

  return {
    passional: round3(clamp01(passional)),
    figurativo: round3(clamp01(figurativo)),
    tematico: round3(clamp01(tematico)),
    oralization: round3(clamp01(oralization)),
  };
}

function analyze(x: Float32Array, sr: number): Features {
  // --- Loudness (0..1) ---
  let loudness = dspLoudness(x);
  if (essentiaReady) {
    try {
      const vec = essentia.arrayToVector(x);
      const l = essentia.Loudness(vec).loudness; // ~energy^0.67
      vec.delete?.();
      // Map essentia's open-ended loudness into a perceptual 0..1 with a soft knee.
      loudness = clamp01(Math.pow(l, 0.5) / 6);
    } catch {
      /* keep dsp value */
    }
  }

  // --- Spectral centroid (Hz) ---
  // Use a windowed frame from the tail of the buffer for the spectral measures.
  const frame = lastFrame(x, 2048);
  const win = hann(frame);
  const spec = magnitudeSpectrum(win); // length = frame/2

  let centroid = dspCentroid(spec, sr, win.length);
  if (essentiaReady) {
    try {
      const vec = essentia.arrayToVector(x);
      const c = essentia.SpectralCentroidTime(vec, sr).centroid;
      vec.delete?.();
      if (isFinite(c) && c > 0) centroid = c;
    } catch {
      /* keep dsp value */
    }
  }

  // --- Pitch salience (0..1) via normalized autocorrelation peak ---
  const pitch_salience = dspPitchSalience(frame, sr);

  // --- Inharmonicity proxy (0..1) via spectral flatness ---
  // Noisy/breathy voice => flat spectrum => high value. Tonal => low.
  const inharmonicity = dspSpectralFlatness(spec);

  // --- Derived perceptual hints (rough; only feed the Director LLM) ---
  const centN = clamp01(centroid / 6000); // normalize brightness
  const arousal = clamp01(0.6 * loudness + 0.4 * centN);
  const valence = clamp(centN - inharmonicity, -1, 1);

  const vocal_quality = deriveQuality(
    loudness,
    pitch_salience,
    centN,
    inharmonicity,
  );

  return {
    spectral_centroid: Math.round(centroid),
    loudness: round3(loudness),
    inharmonicity: round3(inharmonicity),
    pitch_salience: round3(pitch_salience),
    vocal_quality,
    arousal: round3(arousal),
    valence: round3(valence),
  };
}

function deriveQuality(
  loud: number,
  salience: number,
  centN: number,
  inharm: number,
): Features["vocal_quality"] {
  if (inharm > 0.45 && loud < 0.4) return "breathy";
  if (loud > 0.6 && salience > 0.55 && centN > 0.45) return "belted";
  if (loud < 0.35 && salience > 0.5) return "intimate";
  if (loud > 0.55 && salience > 0.5) return "soaring";
  return "neutral";
}

// ---------------- Melody descriptor ----------------
//
// Tracks the f0 line across the window and condenses it into the realtime
// `melody` hint (contour/register/vibrato/energy, PROTOCOL.md). Register is
// relative to the singer's observed range, which we learn over the session.

// Singer range in semitones, learned across calls (expands toward extremes).
let regLo = Infinity;
let regHi = -Infinity;

function computeMelody(
  x: Float32Array,
  sr: number,
  loudness: number,
): Melody | null {
  const frame = 1024;
  const hop = 256;
  // f0 (in semitones) for each voiced hop, with its time, so we can read the
  // contour's shape and timing.
  const semis: number[] = [];
  const times: number[] = [];
  for (let start = 0; start + frame <= x.length; start += hop) {
    const f = x.subarray(start, start + frame);
    const { f0, clarity } = frameF0(f, sr);
    if (clarity >= 0.6 && f0 >= 70 && f0 <= 1000) {
      semis.push(hzToSemitone(f0));
      times.push((start + frame / 2) / sr);
    }
  }
  if (semis.length < 4) return null; // not enough voiced pitch to describe

  // Median-of-3 smoothing knocks out lone octave-jump errors before we read
  // the shape, so vibrato/contour aren't fooled by a single bad frame.
  const sm = median3(semis);

  const med = median(sm);
  const lo = percentile(sm, 0.1);
  const hi = percentile(sm, 0.9);
  const slope = linregSlope(times, sm); // semitones per second
  const spread = hi - lo;

  // Largest single hop jump (a third+ => discrete leaps, not a glide).
  let maxJump = 0;
  for (let i = 1; i < sm.length; i++) {
    maxJump = Math.max(maxJump, Math.abs(sm[i] - sm[i - 1]));
  }

  // --- contour ---
  let contour: string;
  if (maxJump > 4) contour = "leaping";
  else if (slope > 1.5) contour = "rising";
  else if (slope < -1.5) contour = "falling";
  else if (spread < 1.2) contour = "steady";
  else contour = "wavering";

  // --- register (relative to the learned range) ---
  regLo = Math.min(regLo, lo);
  regHi = Math.max(regHi, hi);
  let rLo = regLo;
  let rHi = regHi;
  if (rHi - rLo < 7) {
    // Not enough range observed yet — fall back to ~an octave around the median
    // so early notes still read sensibly low/high.
    rLo = med - 6;
    rHi = med + 6;
  }
  const register = clamp01((med - rLo) / (rHi - rLo));

  // --- vibrato (oscillation of the detrended f0, ~4-8Hz, ±musical depth) ---
  const vibrato = estimateVibrato(times, sm, slope, med);

  // --- energy (loudness, lifted a touch by how high in the range it sits) ---
  const energy = clamp01(0.75 * loudness + 0.25 * register);

  return {
    contour,
    register: round2(register),
    vibrato: round2(vibrato),
    energy: round2(energy),
  };
}

// Per-frame f0 via normalized autocorrelation over the vocal range; returns the
// peak strength as a clarity score so unvoiced frames can be dropped.
function frameF0(x: Float32Array, sr: number): { f0: number; clarity: number } {
  const minLag = Math.floor(sr / 1000);
  const maxLag = Math.min(x.length - 1, Math.floor(sr / 70));
  let r0 = 0;
  for (let i = 0; i < x.length; i++) r0 += x[i] * x[i];
  if (r0 < 1e-6) return { f0: 0, clarity: 0 };

  let bestLag = -1;
  let best = 0;
  for (let lag = minLag; lag <= maxLag; lag++) {
    let acc = 0;
    for (let i = 0; i + lag < x.length; i++) acc += x[i] * x[i + lag];
    const norm = acc / r0;
    if (norm > best) {
      best = norm;
      bestLag = lag;
    }
  }
  if (bestLag <= 0) return { f0: 0, clarity: 0 };
  // Parabolic interpolation around the peak using neighbour correlations.
  let lag = bestLag;
  if (bestLag > minLag && bestLag < maxLag) {
    const a = autocorrAt(x, bestLag - 1, r0);
    const b = autocorrAt(x, bestLag, r0);
    const c = autocorrAt(x, bestLag + 1, r0);
    const denom = a - 2 * b + c;
    if (Math.abs(denom) > 1e-9) lag = bestLag - (0.5 * (c - a)) / denom;
  }
  return { f0: sr / lag, clarity: best };
}

function autocorrAt(x: Float32Array, lag: number, r0: number): number {
  let acc = 0;
  for (let i = 0; i + lag < x.length; i++) acc += x[i] * x[i + lag];
  return acc / r0;
}

// Strength of pitch oscillation: detrend the f0 line (remove the contour slope),
// then score by how musical the wobble depth is and whether it cycles at a
// vibrato-like rate (~4-8Hz).
function estimateVibrato(
  times: number[],
  semis: number[],
  slope: number,
  mean: number,
): number {
  const n = semis.length;
  if (n < 6) return 0;
  const res = new Array(n);
  for (let i = 0; i < n; i++) res[i] = semis[i] - (mean + slope * (times[i] - times[0]));
  let sq = 0;
  let crossings = 0;
  for (let i = 0; i < n; i++) {
    sq += res[i] * res[i];
    if (i > 0 && Math.sign(res[i]) !== Math.sign(res[i - 1])) crossings++;
  }
  const rms = Math.sqrt(sq / n); // semitone depth of the wobble
  const dur = times[n - 1] - times[0];
  const freq = dur > 0 ? crossings / 2 / dur : 0; // oscillation rate in Hz
  // Depth: ~0.2 semitone floor up to ~1 semitone = full.
  const depth = clamp01((rms - 0.2) / 0.8);
  // Rate: peak around 4-8Hz, tapering outside that band.
  const rate =
    freq < 3 || freq > 10
      ? 0
      : freq >= 4 && freq <= 8
        ? 1
        : 1 - Math.min(Math.abs(freq - 4), Math.abs(freq - 8)) / 2;
  return clamp01(depth * rate);
}

function hzToSemitone(hz: number): number {
  return 12 * Math.log2(hz / 440); // relative to A4; only differences matter
}

function median(a: number[]): number {
  const s = [...a].sort((x, y) => x - y);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

function percentile(a: number[], p: number): number {
  const s = [...a].sort((x, y) => x - y);
  const idx = Math.max(0, Math.min(s.length - 1, Math.round(p * (s.length - 1))));
  return s[idx];
}

function median3(a: number[]): number[] {
  if (a.length < 3) return a.slice();
  const out = a.slice();
  for (let i = 1; i < a.length - 1; i++) {
    const t = [a[i - 1], a[i], a[i + 1]].sort((x, y) => x - y);
    out[i] = t[1];
  }
  return out;
}

function linregSlope(xs: number[], ys: number[]): number {
  const n = xs.length;
  let sx = 0, sy = 0, sxx = 0, sxy = 0;
  for (let i = 0; i < n; i++) {
    sx += xs[i];
    sy += ys[i];
    sxx += xs[i] * xs[i];
    sxy += xs[i] * ys[i];
  }
  const denom = n * sxx - sx * sx;
  return Math.abs(denom) < 1e-9 ? 0 : (n * sxy - sx * sy) / denom;
}

function round2(v: number): number {
  return Math.round(v * 100) / 100;
}

// ---------------- DSP helpers ----------------

function dspLoudness(x: Float32Array): number {
  let acc = 0;
  for (let i = 0; i < x.length; i++) acc += x[i] * x[i];
  const rms = Math.sqrt(acc / x.length);
  // Perceptual-ish compression so quiet singing still registers.
  return clamp01(Math.pow(rms, 0.6) * 3.2);
}

function lastFrame(x: Float32Array, n: number): Float32Array {
  if (x.length <= n) {
    const f = new Float32Array(n);
    f.set(x, n - x.length);
    return f;
  }
  return x.subarray(x.length - n);
}

function hann(x: Float32Array): Float32Array {
  const n = x.length;
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const w = 0.5 * (1 - Math.cos((2 * Math.PI * i) / (n - 1)));
    out[i] = x[i] * w;
  }
  return out;
}

// Real-input magnitude spectrum via iterative radix-2 FFT.
function magnitudeSpectrum(x: Float32Array): Float32Array {
  const n = x.length;
  const re = Float32Array.from(x);
  const im = new Float32Array(n);
  fft(re, im);
  const half = n >> 1;
  const mag = new Float32Array(half);
  for (let i = 0; i < half; i++) mag[i] = Math.hypot(re[i], im[i]);
  return mag;
}

// In-place iterative Cooley-Tukey FFT (n must be a power of two).
function fft(re: Float32Array, im: Float32Array) {
  const n = re.length;
  // Bit-reversal permutation.
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      [re[i], re[j]] = [re[j], re[i]];
      [im[i], im[j]] = [im[j], im[i]];
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (-2 * Math.PI) / len;
    const wRe = Math.cos(ang);
    const wIm = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let curRe = 1;
      let curIm = 0;
      for (let k = 0; k < len >> 1; k++) {
        const a = i + k;
        const b = i + k + (len >> 1);
        const tRe = re[b] * curRe - im[b] * curIm;
        const tIm = re[b] * curIm + im[b] * curRe;
        re[b] = re[a] - tRe;
        im[b] = im[a] - tIm;
        re[a] += tRe;
        im[a] += tIm;
        const nRe = curRe * wRe - curIm * wIm;
        curIm = curRe * wIm + curIm * wRe;
        curRe = nRe;
      }
    }
  }
}

function dspCentroid(mag: Float32Array, sr: number, frameLen: number): number {
  let num = 0;
  let den = 0;
  const binHz = sr / frameLen;
  for (let i = 0; i < mag.length; i++) {
    num += i * binHz * mag[i];
    den += mag[i];
  }
  return den > 1e-9 ? num / den : 0;
}

function dspSpectralFlatness(mag: Float32Array): number {
  let logSum = 0;
  let arith = 0;
  let count = 0;
  for (let i = 1; i < mag.length; i++) {
    const m = mag[i] + 1e-9;
    logSum += Math.log(m);
    arith += m;
    count++;
  }
  if (count === 0 || arith <= 0) return 0;
  const geo = Math.exp(logSum / count);
  return clamp01(geo / (arith / count));
}

// Normalized-autocorrelation pitch salience over the human-vocal range.
function dspPitchSalience(x: Float32Array, sr: number): number {
  const minF = 70;
  const maxF = 1000;
  const minLag = Math.floor(sr / maxF);
  const maxLag = Math.floor(sr / minF);
  let r0 = 0;
  for (let i = 0; i < x.length; i++) r0 += x[i] * x[i];
  if (r0 < 1e-6) return 0;
  let best = 0;
  for (let lag = minLag; lag <= maxLag && lag < x.length; lag++) {
    let acc = 0;
    for (let i = 0; i + lag < x.length; i++) acc += x[i] * x[i + lag];
    const norm = acc / r0;
    if (norm > best) best = norm;
  }
  return clamp01(best);
}

// ---------------- utils ----------------
function clamp01(v: number): number {
  return v < 0 ? 0 : v > 1 ? 1 : v;
}
function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}
function round3(v: number): number {
  return Math.round(v * 1000) / 1000;
}
