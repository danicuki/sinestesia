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
}

self.onmessage = (ev: MessageEvent) => {
  const { pcm, sampleRate } = ev.data as {
    pcm: Float32Array;
    sampleRate: number;
  };
  if (!pcm || pcm.length === 0) return;
  const features = analyze(pcm, sampleRate);
  (self as any).postMessage({ type: "features", features });
};

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
