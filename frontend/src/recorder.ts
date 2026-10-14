// Session recorder — captures a whole performance as it happens, so a run can
// be replayed and picked apart offline instead of being sung again.
//
// It records the two halves that have to be compared to judge whether the
// look-ahead is working: every STT transcript (what was sung, and when), and
// every image the front end actually PUT ON SCREEN (what was drawn, from which
// Director prompt, and when). Reading a backend log tells you when a frame was
// generated; only the browser knows when it was shown.
//
// The `events` array is byte-compatible with tests/sessions/*.json, so a saved
// file drops straight into `REPLAY_FILE=... mix sinestesia.replay` with no
// conversion (tools/log_to_session.py exists precisely because that format had
// to be reconstructed from logs before this). The extra `reveals` key is
// additive — the replay task reads `name`/`style`/`events` and ignores the
// rest — and carries the timing evidence that log scraping cannot recover.
//
// Timestamps are milliseconds from the FIRST recorded event, matching the
// replay clock's own convention (at_ms 0 = start of the take), not wall clock.

export type SessionEvent = { at_ms: number; text: string; final: boolean };

export type SessionReveal = {
  at_ms: number;
  prompt: string;
  url: string;
  timings?: unknown;
};

export type Session = {
  name: string;
  style: string;
  recorded_at: string;
  // The take's own sound, saved as a SIBLING .webm by "Save take" (a separate
  // file, so the same audio feeds re-generation runs for comparison). at_ms 0
  // (the first event) sits `audio_offset_ms` into that file, because the audio
  // records from mic start, not from the first event.
  audio?: string;
  audio_offset_ms?: number;
  events: SessionEvent[];
  reveals: SessionReveal[];
};

export class SessionRecorder {
  private t0: number | null = null;
  private events: SessionEvent[] = [];
  private reveals: SessionReveal[] = [];
  private style = "";
  private name = "";

  // Milliseconds since the first recorded event; starts the clock on the first
  // call so a long idle wait before the downbeat isn't baked into the file.
  private stamp(): number {
    const now = performance.now();
    if (this.t0 === null) this.t0 = now;
    return Math.round(now - this.t0);
  }

  noteTranscript(text: string, isFinal: boolean): void {
    if (!text) return;
    this.events.push({ at_ms: this.stamp(), text, final: isFinal });
  }

  noteReveal(url: string, prompt: string, timings?: unknown): void {
    this.reveals.push({ at_ms: this.stamp(), prompt, url, timings });
  }

  noteStyle(style: string): void {
    this.style = style;
  }

  // The song's name, when the backend tells us what it is (song_loaded /
  // song_identified). Only used to name the downloaded file.
  noteSong(name: string): void {
    if (name) this.name = name;
  }

  get count(): number {
    return this.events.length + this.reveals.length;
  }

  /** performance.now() of the first recorded event; null before any. */
  get startedAtMs(): number | null {
    return this.t0;
  }

  clear(): void {
    this.t0 = null;
    this.events = [];
    this.reveals = [];
  }

  toSession(): Session {
    return {
      name: this.slug(),
      style: this.style,
      recorded_at: new Date().toISOString(),
      // at_ms must be monotonic for the replay clock (see
      // tools/song_to_session.py, which sorts for the same reason).
      events: [...this.events].sort((a, b) => a.at_ms - b.at_ms),
      reveals: [...this.reveals].sort((a, b) => a.at_ms - b.at_ms),
    };
  }

  private slug(): string {
    const base = this.name || "session";
    return (
      base
        .toLowerCase()
        .normalize("NFD")
        .replace(/[\u0300-\u036f]/g, "")
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/(^-|-$)/g, "") || "session"
    );
  }

  // Hands the files to the browser's download flow (the take's JSON, plus its
  // .webm when audio was captured — same base name, so they travel as a pair).
  // Nothing leaves the machine. Remote image URLs are inlined as data URIs
  // first: fal links expire, and a take must replay next month, not just
  // today. A failed fetch keeps the original URL with a warning rather than
  // losing the frame's timing.
  async download(audio?: { blob: Blob; offsetMs: number }): Promise<void> {
    const session = this.toSession();
    session.reveals = await Promise.all(session.reveals.map(inlined));

    const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-");
    const base = `${session.name}-${stamp}`;

    if (audio) {
      session.audio = `${base}.webm`;
      session.audio_offset_ms = Math.max(0, Math.round(audio.offsetMs));
      saveBlob(audio.blob, session.audio);
    }

    saveBlob(
      new Blob([JSON.stringify(session, null, 2)], {
        type: "application/json",
      }),
      `${base}.json`,
    );
  }
}

function saveBlob(blob: Blob, filename: string): void {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

async function inlined(r: SessionReveal): Promise<SessionReveal> {
  if (!/^https?:/.test(r.url)) return r; // data URIs are already durable
  try {
    const res = await fetch(r.url);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const blob = await res.blob();
    const url = await new Promise<string>((resolve, reject) => {
      const fr = new FileReader();
      fr.onload = () => resolve(fr.result as string);
      fr.onerror = () => reject(fr.error);
      fr.readAsDataURL(blob);
    });
    return { ...r, url };
  } catch (err) {
    console.warn(
      "[take] could not inline image (kept the URL — it may expire):",
      r.url,
      err,
    );
    return r;
  }
}
