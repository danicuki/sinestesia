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

  // Hands the file to the browser's download flow. Nothing leaves the machine.
  download(): void {
    const session = this.toSession();
    const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-");
    const blob = new Blob([JSON.stringify(session, null, 2)], {
      type: "application/json",
    });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `${session.name}-${stamp}.json`;
    a.click();
    URL.revokeObjectURL(url);
  }
}
