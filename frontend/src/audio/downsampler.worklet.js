// AudioWorkletProcessor: downsample native rate (48kHz) -> 16kHz mono Int16 PCM.
//
// Runs on the audio render thread. We decimate by an integer factor and emit
// fixed ~250ms chunks (4000 samples @ 16kHz = 8000 bytes) to match PROTOCOL.md.
//
// Decimation-by-N is "good enough" for v1 per the scope. No anti-alias FIR —
// the vocal energy we care about sits well below 8kHz Nyquist anyway.

const TARGET_RATE = 16000;
const CHUNK_SAMPLES = 4000; // 250ms @ 16kHz

class Downsampler extends AudioWorkletProcessor {
  constructor() {
    super();
    // `sampleRate` is a global available inside the worklet scope.
    this.factor = Math.max(1, Math.round(sampleRate / TARGET_RATE));
    this.out = new Int16Array(CHUNK_SAMPLES);
    this.outIdx = 0;
    this.phase = 0; // counts input samples for decimation
  }

  process(inputs) {
    const input = inputs[0];
    if (!input || input.length === 0) return true;
    const ch = input[0]; // mono: first channel only
    if (!ch) return true;

    for (let i = 0; i < ch.length; i++) {
      if (this.phase === 0) {
        // Clamp to [-1,1], scale to Int16.
        let s = ch[i];
        if (s > 1) s = 1;
        else if (s < -1) s = -1;
        this.out[this.outIdx++] = (s * 32767) | 0;

        if (this.outIdx === CHUNK_SAMPLES) {
          // Transfer a copy's buffer to the main thread (zero-copy handoff).
          const copy = this.out.slice(0);
          this.port.postMessage(copy.buffer, [copy.buffer]);
          this.outIdx = 0;
        }
      }
      this.phase = (this.phase + 1) % this.factor;
    }
    return true;
  }
}

registerProcessor("downsampler", Downsampler);
