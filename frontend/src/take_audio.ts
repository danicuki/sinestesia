// Take audio — records the mic as a .webm (opus) saved NEXT TO the take JSON,
// not inside it: a standalone audio file can be fed back into the offline
// tools (mix sinestesia.video, transcription benches) to re-generate the same
// performance and compare runs, which a base64 blob buried in JSON cannot.
//
// It records from a MediaStreamDestination node tapped into the Capture graph
// rather than from the mic's MediaStream directly: Capture re-wires its taps
// when the operator switches input devices, so a device switch mid-take keeps
// recording seamlessly instead of going silent.
//
// The recording runs from mic start; the session clock (at_ms 0) starts at the
// FIRST event. The difference is saved as `audio_offset_ms` in the take, and
// the take player shifts reveals by it.

export class TakeAudioRecorder {
  private dest: MediaStreamAudioDestinationNode;
  private rec: MediaRecorder | null = null;
  private chunks: Blob[] = [];
  private startedAt = 0;
  private mime: string;

  constructor(ctx: AudioContext) {
    this.dest = ctx.createMediaStreamDestination();
    this.mime =
      ["audio/webm;codecs=opus", "audio/webm"].find(
        (t) =>
          typeof MediaRecorder !== "undefined" &&
          MediaRecorder.isTypeSupported(t),
      ) ?? "";
  }

  /** Node to hand to Capture.tap() — survives mic device switches. */
  get node(): AudioNode {
    return this.dest;
  }

  /** performance.now() when the current recording started. */
  get startedAtMs(): number {
    return this.startedAt;
  }

  start(): void {
    if (this.rec) return;
    let rec: MediaRecorder;
    try {
      rec = new MediaRecorder(this.dest.stream, {
        ...(this.mime ? { mimeType: this.mime } : {}),
        // Mono vocal; generous enough that a demucs/whisper pass downstream
        // works with the same audio the show heard.
        audioBitsPerSecond: 96_000,
      });
    } catch (err) {
      // A take without audio still saves its JSON — degrade, don't block.
      console.warn("[take] audio recording unavailable:", err);
      return;
    }
    this.chunks = [];
    const chunks = this.chunks;
    rec.ondataavailable = (ev) => {
      if (ev.data.size > 0) chunks.push(ev.data);
    };
    // 1s timeslices so a mid-song snapshot has everything but the last second
    // already chunked (requestData flushes that remainder).
    rec.start(1000);
    this.rec = rec;
    this.startedAt = performance.now();
  }

  /** Discard everything recorded and start a fresh take ("Reset"). */
  restart(): void {
    const rec = this.rec;
    this.rec = null;
    if (rec) {
      // Detach first: stop() fires a final dataavailable, which must not leak
      // the dying take's tail into the fresh one's chunk list.
      rec.ondataavailable = null;
      if (rec.state !== "inactive") rec.stop();
    }
    this.chunks = [];
    this.start();
  }

  /**
   * Everything recorded so far, as one playable blob — WITHOUT stopping the
   * recording: saving a take mid-song must not cost the rest of the song.
   */
  snapshot(): Promise<Blob | null> {
    const rec = this.rec;
    const type = this.mime || "audio/webm";
    if (!rec || rec.state !== "recording") {
      return Promise.resolve(
        this.chunks.length ? new Blob(this.chunks, { type }) : null,
      );
    }
    return new Promise((resolve) => {
      const flush = () => {
        rec.removeEventListener("dataavailable", flush);
        // The ondataavailable property handler (registered first) has already
        // pushed the flushed chunk by the time this listener runs.
        resolve(new Blob(this.chunks, { type }));
      };
      rec.addEventListener("dataavailable", flush);
      rec.requestData();
    });
  }
}
