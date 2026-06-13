// Rail 3 controller (main thread). Buffers ~2s of mic audio and every ~500ms
// hands it to the worker, which returns ExpressiveFeatures per PROTOCOL.md.

import type { ExpressiveFeatures, MelodyFeatures } from "../socket";

const SR = 16000; // we feed the worker the 16kHz stream we already produce
const WINDOW_SAMPLES = SR * 2; // last 2 seconds
const EMIT_MS = 500;

type FeaturesCb = (f: ExpressiveFeatures) => void;
type MelodyCb = (m: MelodyFeatures) => void;

export class ExpressiveAnalyzer {
  private worker: Worker;
  private ring = new Float32Array(WINDOW_SAMPLES);
  private filled = 0;
  private timer: number | null = null;
  private cb: FeaturesCb = () => {};
  private melodyCb: MelodyCb = () => {};

  constructor() {
    this.worker = new Worker(
      new URL("./expressive.worker.ts", import.meta.url),
      { type: "module" },
    );
    this.worker.onmessage = (ev) => {
      if (ev.data?.type !== "features") return;
      this.cb(ev.data.features);
      // Melody is null when there's too little voiced pitch to describe.
      if (ev.data.melody) this.melodyCb(ev.data.melody);
    };
  }

  start() {
    if (this.timer !== null) return;
    this.timer = window.setInterval(() => this.flush(), EMIT_MS);
  }

  /** Feed a 16kHz Int16 chunk (the same one we ship to the backend). */
  pushPCM(int16: Int16Array) {
    const n = int16.length;
    if (n >= WINDOW_SAMPLES) {
      for (let i = 0; i < WINDOW_SAMPLES; i++)
        this.ring[i] = int16[n - WINDOW_SAMPLES + i] / 32768;
      this.filled = WINDOW_SAMPLES;
      return;
    }
    // Shift left by n, append new samples at the tail.
    this.ring.copyWithin(0, n);
    const base = WINDOW_SAMPLES - n;
    for (let i = 0; i < n; i++) this.ring[base + i] = int16[i] / 32768;
    this.filled = Math.min(WINDOW_SAMPLES, this.filled + n);
  }

  private flush() {
    if (this.filled < SR * 0.25) return; // need at least ~250ms of audio
    // Copy the valid tail so the worker can own the buffer.
    const valid = this.ring.slice(WINDOW_SAMPLES - this.filled);
    this.worker.postMessage({ pcm: valid, sampleRate: SR }, [valid.buffer]);
  }

  onFeatures(cb: FeaturesCb) {
    this.cb = cb;
  }

  onMelody(cb: MelodyCb) {
    this.melodyCb = cb;
  }

  stop() {
    if (this.timer !== null) clearInterval(this.timer);
    this.timer = null;
    this.worker.terminate();
  }
}
