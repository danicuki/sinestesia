// Rail 1 — fast features. Pure Web Audio AnalyserNode, read every animation
// frame, feeds shader uniforms directly. No backend round-trip: this is what
// makes the visual feel glued to the voice.

const FFT_SIZE = 1024;
const BINS = 32; // downsampled spectrum length we hand to the shader

export interface FastUniforms {
  fft: Float32Array; // length BINS, 0..1
  rms: number; // 0..1
  onset: boolean;
}

export class FastFeatures {
  private analyser: AnalyserNode;
  private freqData: Uint8Array<ArrayBuffer>;
  private timeData: Uint8Array<ArrayBuffer>;
  private fftOut = new Float32Array(BINS);

  private rms = 0;
  private rmsHistory: number[] = [];
  private onsetFlag = false;

  constructor(ctx: AudioContext) {
    this.analyser = ctx.createAnalyser();
    this.analyser.fftSize = FFT_SIZE;
    this.analyser.smoothingTimeConstant = 0.4;
    this.freqData = new Uint8Array(
      new ArrayBuffer(this.analyser.frequencyBinCount),
    );
    this.timeData = new Uint8Array(new ArrayBuffer(this.analyser.fftSize));
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
  }

  currentUniforms(): FastUniforms {
    return { fft: this.fftOut, rms: this.rms, onset: this.onsetFlag };
  }
}
