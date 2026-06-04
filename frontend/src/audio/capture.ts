// Mic capture: getUserMedia -> AudioWorklet downsampler -> Int16 PCM chunks.
//
// Also exposes the raw MediaStreamSource node so FastFeatures (Rail 1) and the
// ExpressiveAnalyzer (Rail 3) can tap the same graph without re-opening the mic.

import workletUrl from "./downsampler.worklet.js?url";

type ChunkCb = (buf: ArrayBuffer) => void;

export class Capture {
  ctx: AudioContext;
  source: MediaStreamAudioSourceNode | null = null;
  private stream: MediaStream | null = null;
  private worklet: AudioWorkletNode | null = null;
  private chunkCb: ChunkCb = () => {};

  constructor() {
    // 48kHz native; the worklet decimates to 16kHz.
    this.ctx = new AudioContext({ sampleRate: 48000 });
  }

  async start() {
    // Raw vocal: disable all the "helpful" phone-call DSP.
    this.stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        echoCancellation: false,
        noiseSuppression: false,
        autoGainControl: false,
      },
    });

    if (this.ctx.state === "suspended") await this.ctx.resume();

    this.source = this.ctx.createMediaStreamSource(this.stream);

    await this.ctx.audioWorklet.addModule(workletUrl);
    this.worklet = new AudioWorkletNode(this.ctx, "downsampler", {
      numberOfInputs: 1,
      numberOfOutputs: 0,
      channelCount: 1,
      channelCountMode: "explicit",
    });
    this.worklet.port.onmessage = (ev) => this.chunkCb(ev.data as ArrayBuffer);

    this.source.connect(this.worklet);
  }

  /** Connect an extra analysis node to the live mic graph. */
  tap(node: AudioNode) {
    this.source?.connect(node);
  }

  onChunk(cb: ChunkCb) {
    this.chunkCb = cb;
  }

  stop() {
    this.worklet?.disconnect();
    this.source?.disconnect();
    this.stream?.getTracks().forEach((t) => t.stop());
  }
}
