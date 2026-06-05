// WebSocket client — typed against PROTOCOL.md.
// Owns the browser <-> Elixir boundary: sends audio (binary) + expressive
// features (JSON), receives transcripts + image URLs.

export interface ExpressiveFeatures {
  spectral_centroid: number;
  loudness: number;
  inharmonicity: number;
  pitch_salience: number;
  vocal_quality: "breathy" | "belted" | "intimate" | "soaring" | "neutral";
  arousal: number;
  valence: number;
}

// Per-cycle latency breakdown carried on `image` messages (PROTOCOL.md).
export interface Timings {
  stt_ms: number;
  stt_provider: string;
  director_ms: number;
  image_ms: number;
  total_ms: number;
  image_provider: string;
}

export interface TranscriptMsg {
  text: string;
  isFinal: boolean;
  provider?: string;
  latencyMs?: number;
}

export interface ImageMsg {
  url: string;
  prompt: string;
  timings?: Timings;
}

type TranscriptCb = (m: TranscriptMsg) => void;
type ImageCb = (m: ImageMsg) => void;
type ErrorCb = (message: string, provider?: string) => void;
// `source`: "user" (our echo), "curator" (auto-picked), or "reset" (new song).
type StyleCb = (style: string, source: string) => void;

const URL_DEFAULT = "ws://localhost:4000/ws/audio";

// Exponential backoff schedule per PROTOCOL.md: 250ms, 500ms, 1s, 2s, max 5s.
const BACKOFF = [250, 500, 1000, 2000, 5000];

export class Socket {
  private ws: WebSocket | null = null;
  private url: string;
  private closedByUser = false;
  private retry = 0;
  private pingTimer: number | null = null;

  onTranscript: TranscriptCb = () => {};
  onImage: ImageCb = () => {};
  onError: ErrorCb = () => {};
  onStyle: StyleCb = () => {};
  onOpen: () => void = () => {};

  constructor(url: string = URL_DEFAULT) {
    this.url = url;
  }

  connect() {
    this.closedByUser = false;
    this.open();
  }

  private open() {
    try {
      this.ws = new WebSocket(this.url);
    } catch (e) {
      this.scheduleReconnect();
      return;
    }
    this.ws.binaryType = "arraybuffer";

    this.ws.onopen = () => {
      this.retry = 0;
      this.onOpen();
      // Liveness ping every 5s.
      this.pingTimer = window.setInterval(() => this.sendPing(), 5000);
    };

    this.ws.onmessage = (ev) => this.handleMessage(ev);

    this.ws.onerror = () => {
      // onclose will follow; reconnect logic lives there.
    };

    this.ws.onclose = () => {
      if (this.pingTimer !== null) {
        clearInterval(this.pingTimer);
        this.pingTimer = null;
      }
      if (!this.closedByUser) this.scheduleReconnect();
    };
  }

  private scheduleReconnect() {
    const delay = BACKOFF[Math.min(this.retry, BACKOFF.length - 1)];
    this.retry++;
    setTimeout(() => {
      if (!this.closedByUser) this.open();
    }, delay);
  }

  private handleMessage(ev: MessageEvent) {
    // Per protocol, BE->FE is always JSON text. Binary inbound is unexpected.
    if (typeof ev.data !== "string") return;
    let msg: any;
    try {
      msg = JSON.parse(ev.data);
    } catch {
      return;
    }
    switch (msg.type) {
      case "transcript":
        this.onTranscript({
          text: String(msg.text ?? ""),
          isFinal: Boolean(msg.is_final),
          provider: msg.provider ? String(msg.provider) : undefined,
          latencyMs:
            typeof msg.latency_ms === "number" ? msg.latency_ms : undefined,
        });
        break;
      case "image":
        if (msg.url)
          this.onImage({
            url: String(msg.url),
            prompt: String(msg.prompt ?? ""),
            timings: msg.timings as Timings | undefined,
          });
        break;
      case "error":
        this.onError(
          String(msg.message ?? "unknown error"),
          msg.provider ? String(msg.provider) : undefined,
        );
        break;
      case "style":
        // Backend echo of the accepted (sanitized/capped) style. `source`
        // tells us whether it was our own change, the curator, or a reset.
        this.onStyle(String(msg.style ?? ""), String(msg.source ?? "user"));
        break;
      case "pong":
        break;
      default:
        // Unknown types must be ignored, not error out.
        break;
    }
  }

  private get ready(): boolean {
    return this.ws !== null && this.ws.readyState === WebSocket.OPEN;
  }

  sendAudio(buf: ArrayBuffer) {
    if (this.ready) this.ws!.send(buf);
  }

  sendExpressive(features: ExpressiveFeatures) {
    if (!this.ready) return;
    this.ws!.send(
      JSON.stringify({ type: "expressive", ts: Date.now(), features }),
    );
  }

  sendStyle(style: string) {
    if (!this.ready) return;
    this.ws!.send(JSON.stringify({ type: "style", style }));
  }

  // New song: reset all song-scoped backend state without dropping the WS.
  // Backend replies with a `style` echo carrying source "reset".
  sendReset() {
    if (!this.ready) return;
    this.ws!.send(JSON.stringify({ type: "reset" }));
  }

  sendFastFeatures(rms: number, tempo_estimate?: number) {
    if (!this.ready) return;
    this.ws!.send(
      JSON.stringify({
        type: "fast_features",
        ts: Date.now(),
        rms,
        ...(tempo_estimate !== undefined ? { tempo_estimate } : {}),
      }),
    );
  }

  sendPing() {
    if (this.ready) this.ws!.send(JSON.stringify({ type: "ping" }));
  }

  close() {
    this.closedByUser = true;
    if (this.pingTimer !== null) clearInterval(this.pingTimer);
    this.ws?.close();
  }
}
