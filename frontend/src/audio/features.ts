// Rail 1 — fast features. Pure Web Audio AnalyserNode, read every animation
// frame, feeds shader uniforms directly. No backend round-trip: this is what
// makes the visual feel glued to the voice.

// 2048 (≈43ms @48kHz) gives the time-domain autocorrelation enough room to lock
// onto low sung notes (~2 periods down to ~47Hz) for the live pitch readout,
// without hurting the spectral measures (they downsample generically).
const FFT_SIZE = 2048;
const BINS = 32; // downsampled spectrum length we hand to the shader

export interface FastUniforms {
  fft: Float32Array; // length BINS, 0..1
  rms: number; // 0..1
  onset: boolean;
  centroid: number; // 0..1 spectral centroid (0 = bass/warm, 1 = treble/cool)
}

export class FastFeatures {
  private analyser: AnalyserNode;
  private freqData: Uint8Array<ArrayBuffer>;
  private timeData: Uint8Array<ArrayBuffer>;
  private floatTime: Float32Array; // raw waveform for pitch autocorrelation
  private fftOut = new Float32Array(BINS);
  private sr: number;

  private rms = 0;
  private rmsHistory: number[] = [];
  private onsetFlag = false;
  private centroid = 0.5; // smoothed, starts neutral
  private pitch = 0; // smoothed f0 in Hz, 0 = unvoiced (no clear pitch)

  constructor(ctx: AudioContext) {
    this.sr = ctx.sampleRate;
    this.analyser = ctx.createAnalyser();
    this.analyser.fftSize = FFT_SIZE;
    this.analyser.smoothingTimeConstant = 0.4;
    this.freqData = new Uint8Array(
      new ArrayBuffer(this.analyser.frequencyBinCount),
    );
    this.timeData = new Uint8Array(new ArrayBuffer(this.analyser.fftSize));
    this.floatTime = new Float32Array(this.analyser.fftSize);
  }

  /** The node to connect the mic source into. */
  get node(): AnalyserNode {
    return this.analyser;
  }

  /** Call once per animation frame. */
  update() {
    this.analyser.getByteFrequencyData(this.freqData);
    this.analyser.getByteTimeDomainData(this.timeData);

    // Downsample the spectrum to BINS by block-averaging.
    const per = Math.floor(this.freqData.length / BINS);
    for (let b = 0; b < BINS; b++) {
      let sum = 0;
      for (let j = 0; j < per; j++) sum += this.freqData[b * per + j];
      this.fftOut[b] = sum / per / 255; // 0..1
    }

    // Spectral centroid over the full spectrum: magnitude-weighted mean bin,
    // normalized to 0..1 (0 = energy in the bass, 1 = energy in the treble).
    // Drives the background hue (warm → cool). Smoothed so the tint glides.
    let wsum = 0;
    let msum = 0;
    const N = this.freqData.length;
    for (let i = 0; i < N; i++) {
      const m = this.freqData[i];
      wsum += i * m;
      msum += m;
    }
    const rawCentroid = msum > 0 ? wsum / msum / (N - 1) : this.centroid;
    this.centroid += (rawCentroid - this.centroid) * 0.15; // one-pole smoothing

    // RMS over the time-domain waveform (centered at 128).
    let acc = 0;
    for (let i = 0; i < this.timeData.length; i++) {
      const v = (this.timeData[i] - 128) / 128;
      acc += v * v;
    }
    const rms = Math.sqrt(acc / this.timeData.length);

    // Onset: current RMS notably above the recent running mean.
    this.rmsHistory.push(rms);
    if (this.rmsHistory.length > 8) this.rmsHistory.shift();
    const mean =
      this.rmsHistory.reduce((a, b) => a + b, 0) / this.rmsHistory.length;
    this.onsetFlag = rms > 0.06 && rms > mean * 1.5;

    this.rms = rms;

    // Live pitch (for the on-screen tuner). Raw f0 per frame, then a gentle
    // glide so the readout doesn't jitter — but snap on big jumps / octave
    // changes so a new note lands immediately.
    this.analyser.getFloatTimeDomainData(this.floatTime);
    const f0 = detectPitch(this.floatTime, this.sr);
    if (f0 <= 0) {
      this.pitch = 0; // unvoiced — let the tuner go quiet
    } else if (this.pitch <= 0 || Math.abs(Math.log2(f0 / this.pitch)) > 0.08) {
      this.pitch = f0; // first lock or a real note change: snap
    } else {
      this.pitch += (f0 - this.pitch) * 0.25; // same note: smooth the wobble
    }
  }

  currentUniforms(): FastUniforms {
    return {
      fft: this.fftOut,
      rms: this.rms,
      onset: this.onsetFlag,
      centroid: this.centroid,
    };
  }

  /** Current sung fundamental in Hz, or 0 when no clear pitch is present. */
  pitchHz(): number {
    return this.pitch;
  }
}

// Time-domain pitch detection (ACF2+): autocorrelation with end-trimming and
// parabolic interpolation. Returns 0 when the frame is silent or has no clear
// periodic pitch, so the tuner only shows a note when one is actually sung.
function detectPitch(buf: Float32Array, sr: number): number {
  const SIZE = buf.length;
  let energy = 0;
  for (let i = 0; i < SIZE; i++) energy += buf[i] * buf[i];
  const rms = Math.sqrt(energy / SIZE);
  if (rms < 0.01) return 0; // silence

  // Trim near-silent head/tail so the correlation locks onto the voiced core.
  const thresh = 0.2;
  let start = 0;
  let end = SIZE - 1;
  for (let i = 0; i < SIZE / 2; i++) {
    if (Math.abs(buf[i]) > thresh) {
      start = i;
      break;
    }
  }
  for (let i = 0; i < SIZE / 2; i++) {
    if (Math.abs(buf[SIZE - 1 - i]) > thresh) {
      end = SIZE - 1 - i;
      break;
    }
  }
  const b = end > start ? buf.subarray(start, end + 1) : buf;
  const n = b.length;
  if (n < 64) return 0;

  const c = new Float32Array(n);
  for (let lag = 0; lag < n; lag++) {
    let sum = 0;
    for (let i = 0; i < n - lag; i++) sum += b[i] * b[i + lag];
    c[lag] = sum;
  }

  // Skip the lag-0 main lobe: walk down to the first trough, then take the
  // strongest peak after it (the fundamental period).
  let d = 0;
  while (d < n - 1 && c[d] > c[d + 1]) d++;
  let max = -Infinity;
  let pos = -1;
  for (let lag = d; lag < n; lag++) {
    if (c[lag] > max) {
      max = c[lag];
      pos = lag;
    }
  }
  if (pos <= 0) return 0;
  // Clarity gate: a real pitch correlates strongly relative to total energy.
  if (c[0] <= 0 || max / c[0] < 0.5) return 0;

  // Parabolic interpolation around the peak for sub-sample period accuracy.
  let t0 = pos;
  if (pos > 0 && pos < n - 1) {
    const x1 = c[pos - 1];
    const x2 = c[pos];
    const x3 = c[pos + 1];
    const a = (x1 + x3 - 2 * x2) / 2;
    const bb = (x3 - x1) / 2;
    if (a !== 0) t0 = pos - bb / (2 * a);
  }

  const f0 = sr / t0;
  if (f0 < 70 || f0 > 1100) return 0; // outside the human singing range
  return f0;
}
