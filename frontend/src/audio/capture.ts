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
  // Nodes tapped into the live graph (Rail 1 analyser). Remembered so we can
  // re-wire them onto a fresh source when the mic device is switched.
  private taps: AudioNode[] = [];
  private deviceId: string | undefined;

  constructor() {
    // 48kHz native; the worklet decimates to 16kHz.
    this.ctx = new AudioContext({ sampleRate: 48000 });
  }

  // Raw vocal: disable all the "helpful" phone-call DSP. Optionally pin a device.
  private constraints(deviceId?: string): MediaStreamConstraints {
    const audio: MediaTrackConstraints = {
      echoCancellation: false,
      noiseSuppression: false,
      autoGainControl: false,
    };
    if (deviceId) audio.deviceId = { exact: deviceId };
    return { audio };
  }

  async start(deviceId?: string) {
    this.deviceId = deviceId;
    this.stream = await navigator.mediaDevices.getUserMedia(
      this.constraints(deviceId),
    );

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

  /** Swap to a different mic input without rebuilding the graph or taps. */
  async switchDevice(deviceId: string) {
    if (!this.worklet) return; // not started yet
    if (deviceId === this.deviceId) return;

    const next = await navigator.mediaDevices.getUserMedia(
      this.constraints(deviceId),
    );

    // Tear down the old source + stream, keep the worklet (and its port).
    this.source?.disconnect();
    this.stream?.getTracks().forEach((t) => t.stop());

    this.stream = next;
    this.deviceId = deviceId;
    this.source = this.ctx.createMediaStreamSource(next);
    this.source.connect(this.worklet);
    for (const node of this.taps) this.source.connect(node);
  }

  /** Connect an extra analysis node to the live mic graph. */
  tap(node: AudioNode) {
    this.taps.push(node);
    this.source?.connect(node);
  }

  get currentDeviceId(): string | undefined {
    return this.deviceId;
  }

  /** Available audio input devices (labels populated after permission). */
  static async inputDevices(): Promise<MediaDeviceInfo[]> {
    const all = await navigator.mediaDevices.enumerateDevices();
    return all.filter((d) => d.kind === "audioinput");
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
