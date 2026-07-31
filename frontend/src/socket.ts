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
  semiotics?: {
    passional: number;
    figurativo: number;
    tematico: number;
    oralization: number;
  };
}

// Realtime melodic descriptor (FE->BE `melody`, PROTOCOL.md 2026-06-13). All
// fields optional — we send what the f0 track supports and omit the rest. The
// backend ages it out after 6s, so a gap just means "no melody info".
export interface MelodyFeatures {
  contour?: string; // "rising" | "falling" | "steady" | "wavering" | "leaping"
  register?: number; // 0 = low/chest, 1 = high/head
  vibrato?: number; // 0..1 oscillation strength
  energy?: number; // 0..1 melodic intensity
}

// Per-cycle latency breakdown carried on `image` messages (PROTOCOL.md).
export interface Timings {
  stt_ms: number;
  stt_provider: string;
  // director_ms/image_ms are provider round-trips measured at the call site.
  director_ms: number;
  image_ms: number;
  // Local SDXL morph pass that runs after the cloud image (t2i + LOCAL_MORPH).
  // Separate from image_ms so it isn't misread as image-provider latency.
  morph_ms?: number;
  // Time the results spent queued in the backend pipeline rather than on a
  // provider. Non-zero means the backend is the bottleneck, not the model.
  queue_ms?: number;
  total_ms: number;
  // True when the frame was rendered AHEAD of the singing (eager bootstrap or
  // deep look-ahead). Its stt_ms is null and its director_ms is a cost paid
  // seconds earlier, so these numbers are not the latency the audience saw.
  prerendered?: boolean;
  // Provider plus the route/steps that actually ran, e.g. "cloudflare img2img 20st".
  image_provider: string;
  // The exact model id that rendered the frame, when the provider reports one.
  image_model?: string | null;
}

export interface TranscriptMsg {
  text: string;
  isFinal: boolean;
  provider?: string;
  latencyMs?: number;
}

// Verifiable-inference receipt, present on `image` messages only when the
// Director prompt was computed on the 0G Compute Network (TEE-sealed).
export interface Verification {
  provider: string;
  model: string;
  chatId: string;
  verified: boolean | null;
  network: string;
}

// Musical structure (BE->FE `structure`, PROTOCOL.md). Pushed on a section
// boundary and on a meaningful tempo change once lyrics + MUSICAL_STRUCTURE are
// active on the backend. Purely informational — never feeds provenance.
export interface StructureMsg {
  section: { label: string; occurrence: number; index: number } | null;
  tempoBpm: number | null;
}

export interface ImageMsg {
  url: string;
  prompt: string;
  timings?: Timings;
  frames?: string[];
  verification?: Verification;
}

// Sent when the finished painting has been stored on Walrus and minted on Sui.
export interface MintMsg {
  releaseRef?: string;
  masterTokenId?: string;
  txId?: string;
  explorerUrl?: string;
  provenanceHash?: string;
  traits?: Record<string, string | number>;
  imageUri?: string;
  /** URL the audience QR encodes — opens the claim page. */
  claimUrl?: string;
  /** Title/artist as identified from the lyrics (or the configured override). */
  song?: string;
  artist?: string;
}

// Song library (Sinestesia.SongLibrary) — PROTOCOL.md "Song library" section.
export interface SongSummary {
  id: string;
  title: string;
  artist?: string;
}

export interface SongLoadedMsg {
  id: string;
  title: string;
  artist?: string;
  setlistIndex?: number;
}

type SongsCb = (songs: SongSummary[]) => void;
type SongLoadedCb = (m: SongLoadedMsg) => void;
type SongIdentifiedCb = (m: SongLoadedMsg) => void;
type SongSavedCb = (m: SongLoadedMsg) => void;
type SongErrorCb = (message: string) => void;

type TranscriptCb = (m: TranscriptMsg) => void;
type ImageCb = (m: ImageMsg) => void;
type ErrorCb = (message: string, provider?: string) => void;
// `source`: "user" (our echo), "curator" (auto-picked), or "reset" (new song).
type StyleCb = (style: string, source: string) => void;
type MintCb = (m: MintMsg) => void;
// "minting" while the release is in flight; message text on failure.
type MintStatusCb = (status: string) => void;
type MintErrorCb = (message: string) => void;
// A previously-pending receipt whose on-chain settlement has now landed.
type VerificationCb = (v: Verification) => void;
type StructureCb = (m: StructureMsg) => void;

const URL_DEFAULT =
  import.meta.env.VITE_WS_URL ?? "ws://localhost:4000/ws/audio";

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
  onMint: MintCb = () => {};
  onMintStatus: MintStatusCb = () => {};
  onMintError: MintErrorCb = () => {};
  onVerification: VerificationCb = () => {};
  onStructure: StructureCb = () => {};
  onSongs: SongsCb = () => {};
  onSongLoaded: SongLoadedCb = () => {};
  onSongIdentified: SongIdentifiedCb = () => {};
  onSongSaved: SongSavedCb = () => {};
  onSongError: SongErrorCb = () => {};
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
            frames: Array.isArray(msg.frames) ? msg.frames.map(String) : undefined,
            verification: msg.verification as Verification | undefined,
          });
        break;
      // Settlement landed for a receipt that shipped as pending — update the badge.
      case "verification":
        if (msg.verification) this.onVerification(msg.verification as Verification);
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
      case "mint_status":
        this.onMintStatus(String(msg.status ?? "minting"));
        break;
      case "mint":
        this.onMint({
          releaseRef: msg.releaseRef ? String(msg.releaseRef) : undefined,
          masterTokenId: msg.masterTokenId ? String(msg.masterTokenId) : undefined,
          txId: msg.txId ? String(msg.txId) : undefined,
          explorerUrl: msg.explorerUrl ? String(msg.explorerUrl) : undefined,
          provenanceHash: msg.provenanceHash ? String(msg.provenanceHash) : undefined,
          traits: msg.traits as Record<string, string | number> | undefined,
          imageUri: msg.imageUri ? String(msg.imageUri) : undefined,
          claimUrl: msg.claimUrl ? String(msg.claimUrl) : undefined,
          song: msg.song ? String(msg.song) : undefined,
          artist: msg.artist ? String(msg.artist) : undefined,
        });
        break;
      case "mint_error":
        this.onMintError(String(msg.message ?? "mint failed"));
        break;
      case "songs":
        this.onSongs(
          Array.isArray(msg.songs)
            ? msg.songs.map((s: any) => ({
                id: String(s.id ?? ""),
                title: String(s.title ?? ""),
                artist: s.artist ? String(s.artist) : undefined,
              }))
            : [],
        );
        break;
      case "song_loaded":
        this.onSongLoaded({
          id: String(msg.id ?? ""),
          title: String(msg.title ?? ""),
          artist: msg.artist ? String(msg.artist) : undefined,
          setlistIndex:
            typeof msg.setlist_index === "number" ? msg.setlist_index : undefined,
        });
        break;
      case "song_identified":
        this.onSongIdentified({
          id: String(msg.id ?? ""),
          title: String(msg.title ?? ""),
          artist: msg.artist ? String(msg.artist) : undefined,
        });
        break;
      case "song_saved":
        this.onSongSaved({
          id: String(msg.id ?? ""),
          title: String(msg.title ?? ""),
          artist: msg.artist ? String(msg.artist) : undefined,
        });
        break;
      case "song_error":
        this.onSongError(String(msg.message ?? "song library error"));
        break;
      case "structure":
        this.onStructure({
          section:
            msg.section && typeof msg.section === "object"
              ? {
                  label: String(msg.section.label ?? ""),
                  occurrence: Number(msg.section.occurrence ?? 1),
                  index: Number(msg.section.index ?? 0),
                }
              : null,
          tempoBpm: typeof msg.tempo_bpm === "number" ? msg.tempo_bpm : null,
        });
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

  // Realtime melodic descriptor (contour/register/vibrato/energy). Sent while
  // voiced; the backend folds it into the Director's mood. Purely additive.
  sendMelody(features: MelodyFeatures) {
    if (!this.ready) return;
    this.ws!.send(
      JSON.stringify({ type: "melody", ts: Date.now(), features }),
    );
  }

  sendStyle(style: string) {
    if (!this.ready) return;
    this.ws!.send(JSON.stringify({ type: "style", style }));
  }

  // Load (or clear) the song's lyrics for predictive look-ahead AND musical
  // structure. `text` is the RAW pasted lyrics — blank lines between stanzas
  // are what let the backend tell a verse from a chorus (MUSICAL_STRUCTURE);
  // look-ahead (SPECULATIVE_LOOKAHEAD) works either way. Empty string clears.
  sendLyrics(text: string) {
    if (!this.ready) return;
    this.ws!.send(JSON.stringify({ type: "lyrics", text }));
  }

  // Song library (Sinestesia.SongLibrary) — PROTOCOL.md "Song library" section.
  sendListSongs() {
    if (!this.ready) return;
    this.ws!.send(JSON.stringify({ type: "list_songs" }));
  }

  sendLoadSong(id: string) {
    if (!this.ready) return;
    this.ws!.send(JSON.stringify({ type: "load_song", id }));
  }

  sendImportSong(url: string, opts: { title?: string; artist?: string; load?: boolean } = {}) {
    if (!this.ready) return;
    this.ws!.send(JSON.stringify({ type: "import_song", url, ...opts }));
  }

  sendSaveSong(attrs: { title: string; artist?: string; lyrics_text?: string }) {
    if (!this.ready) return;
    this.ws!.send(JSON.stringify({ type: "save_song", ...attrs }));
  }

  sendLoadSetlist(ids: string[]) {
    if (!this.ready) return;
    this.ws!.send(JSON.stringify({ type: "load_setlist", ids }));
  }

  // New song: reset all song-scoped backend state without dropping the WS.
  // Backend replies with a `style` echo carrying source "reset".
  sendReset() {
    if (!this.ready) return;
    this.ws!.send(JSON.stringify({ type: "reset" }));
  }

  // Mint the finished painting. Optional song/artist/venue override the backend
  // env defaults. Backend replies with `mint_status` then `mint` (or `mint_error`).
  sendMint(meta: { song?: string; artist?: string; venue?: string } = {}) {
    if (!this.ready) return;
    this.ws!.send(JSON.stringify({ type: "mint", ...meta }));
  }

  // End the song: mint what was painted and reset for the next one, in that
  // order, as a single backend action. Replies are the same as `mint` (plus the
  // `style` echo with source "reset"), so nothing new to handle on this side.
  sendEndSong(meta: { song?: string; artist?: string; venue?: string } = {}) {
    if (!this.ready) return;
    this.ws!.send(JSON.stringify({ type: "end_song", ...meta }));
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
