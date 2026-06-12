// ?debug=1 overlay — bottom-left, small monospace, for live latency/A-B
// inspection during the show. Pure DOM, no chrome elsewhere. Reads the
// `provider` + `latency_ms` on transcripts and the `timings` block on images
// (PROTOCOL.md). Created only when the URL flag is present.

import type { ExpressiveFeatures, Timings, TranscriptMsg } from "./socket";
import type { SampleSequence } from "./samples";

const COL = {
  stt: "#6ee7b7", // green
  dir: "#93c5fd", // blue
  img: "#fcd34d", // amber
  tot: "#ffffff", // bold white
  prov: "#9ca3af", // gray
  dim: "#6b7280", // dimmer gray
  interim: "#9ca3af",
  final: "#e5e7eb",
};

interface TimingEntry {
  t: Timings;
  at: number; // performance.now() when received
}

export class DebugOverlay {
  private root: HTMLDivElement;
  private elAudio: HTMLDivElement;
  private elExpressive: HTMLDivElement;
  private elTranscript: HTMLDivElement;
  private elPrompt: HTMLDivElement;
  private elLyric: HTMLDivElement;
  private elHistory: HTMLDivElement;
  private elSamples: HTMLDivElement;
  private elParams: HTMLDivElement;

  private history: TimingEntry[] = [];
  private lastAudioPaint = 0; // throttle the per-frame meter to ~12Hz

  constructor() {
    this.root = document.createElement("div");
    Object.assign(this.root.style, {
      position: "fixed",
      left: "0",
      right: "0",
      bottom: "0",
      zIndex: "20",
      display: "flex",
      alignItems: "flex-start",
      gap: "24px",
      padding: "8px 12px",
      background: "rgba(0,0,0,0.55)",
      font: "11px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace",
      color: COL.final,
      opacity: "0.6",
      pointerEvents: "none",
      whiteSpace: "pre-wrap",
      wordBreak: "break-word",
    } as CSSStyleDeclaration);

    // Left column: live speech + the prompt it produced. Takes the slack so long
    // text wraps here. Right column: the timing history (its top row is the
    // latest cycle, so a separate "current" line is redundant).
    const left = column("1 1 auto");
    const right = column("0 0 auto");

    this.elAudio = this.section(left, "rail 1 — movement");
    this.elExpressive = this.section(left, "rail 3 — expression");
    this.elTranscript = this.section(left, "transcript");
    this.elPrompt = this.section(left, "director prompt");
    this.elLyric = this.section(left, "sample lyric");
    this.elHistory = this.section(right, "history (last 5)");
    this.elSamples = this.section(right, "sample sequences");
    this.elParams = this.section(right, "run params");

    this.root.appendChild(left);
    this.root.appendChild(right);
    document.body.appendChild(this.root);

    // Refresh relative "ago" timestamps once a second.
    window.setInterval(() => this.renderHistory(), 1000);
  }

  private section(parent: HTMLDivElement, label: string): HTMLDivElement {
    const wrap = document.createElement("div");
    wrap.style.marginTop = "6px";
    const head = document.createElement("div");
    head.textContent = label.toUpperCase();
    Object.assign(head.style, {
      color: COL.dim,
      fontSize: "9px",
      letterSpacing: "0.12em",
      marginBottom: "1px",
    } as CSSStyleDeclaration);
    const body = document.createElement("div");
    body.textContent = "—";
    wrap.appendChild(head);
    wrap.appendChild(body);
    parent.appendChild(wrap);
    return body;
  }

  // 1. Last transcript: [provider] +Xms: "texto"
  setTranscript(m: TranscriptMsg) {
    const prov = m.provider ?? "?";
    const lat = m.latencyMs != null ? `+${m.latencyMs}ms` : "";
    this.elTranscript.innerHTML =
      span(`[${prov}]`, COL.prov) +
      (lat ? " " + span(lat, COL.stt) : "") +
      ": " +
      span(`"${escapeHtml(m.text)}"`, m.isFinal ? COL.final : COL.interim);
  }

  // 2. Last Director prompt
  setPrompt(prompt: string) {
    this.elPrompt.textContent = prompt || "—";
  }

  // Sample-replay lyric for the current frame (demo player). Cleared with "—".
  setSampleLyric(lyric?: string) {
    this.elLyric.textContent = lyric || "—";
  }

  // Sample-replay run recipe as a sorted key=value table (demo player). Sorted
  // so two runs line up for visual A/B comparison. Absent params clears it.
  setSampleParams(params?: Record<string, string>) {
    const keys = params ? Object.keys(params).sort() : [];
    if (keys.length === 0) {
      this.elParams.textContent = "—";
      return;
    }
    this.elParams.innerHTML = keys
      .map(
        (k) =>
          span(`${escapeHtml(k)} = `, COL.dim) +
          span(escapeHtml(params![k]), COL.final),
      )
      .join("\n");
  }

  // Live Rail-1 meter (called every frame; throttled to ~12Hz to spare layout).
  setAudio(rms: number, centroid: number, onset: boolean) {
    const now = performance.now();
    if (now - this.lastAudioPaint < 80) return;
    this.lastAudioPaint = now;
    const warmth = centroid < 0.5 ? "warm" : "cool";
    this.elAudio.innerHTML =
      span("RMS ", COL.dim) +
      bar(rms) +
      span(` ${rms.toFixed(2)}`, COL.stt) +
      span("   CENT ", COL.dim) +
      bar(centroid) +
      span(` ${centroid.toFixed(2)} ${warmth}`, COL.dir) +
      (onset ? "  " + span("● ONSET", COL.img, true) : "");
  }

  // Rail-3 expressive snapshot (~2Hz).
  setExpressive(f: ExpressiveFeatures) {
    this.elExpressive.innerHTML =
      span(f.vocal_quality, COL.tot, true) +
      span("  arousal ", COL.dim) +
      span(f.arousal.toFixed(2), COL.stt) +
      span("  valence ", COL.dim) +
      span(f.valence.toFixed(2), f.valence >= 0 ? COL.stt : COL.img) +
      span("  cent ", COL.dim) +
      span(String(Math.round(f.spectral_centroid)), COL.dir);
  }

  // Rolling history of the last 5 cycles (top row = latest).
  addTimings(t: Timings) {
    this.history.unshift({ t, at: performance.now() });
    if (this.history.length > 5) this.history.pop();
    this.renderHistory();
  }

  // STT 195 | DIR 870 | IMG 480 | TOT 1545ms (fal)
  private formatTiming(t: Timings): string {
    return (
      span(`STT ${t.stt_ms}`, COL.stt) +
      span(" | ", COL.dim) +
      span(`DIR ${t.director_ms}`, COL.dir) +
      span(" | ", COL.dim) +
      span(`IMG ${t.image_ms}`, COL.img) +
      span(" | ", COL.dim) +
      span(`TOT ${t.total_ms}ms`, COL.tot, true) +
      " " +
      span(`(${t.image_provider})`, COL.prov)
    );
  }

  private renderHistory() {
    if (this.history.length === 0) {
      this.elHistory.textContent = "—";
      return;
    }
    const now = performance.now();
    this.elHistory.innerHTML = this.history
      .map((e) => {
        const ago = ((now - e.at) / 1000).toFixed(1);
        return span(`-${ago}s`.padStart(7), COL.dim) + "  " + this.formatTiming(e.t);
      })
      .join("\n");
  }

  setError(message: string, provider?: string) {
    const p = provider ? `[${provider}] ` : "";
    this.elTranscript.innerHTML = span(`⚠ ${p}${escapeHtml(message)}`, "#f87171");
  }

  // Clickable list of the pre-generated sample sequences. Picking one replays
  // it into the scene (onPick) so the transition shader can be iterated without
  // a mic or the backend. The overlay root is pointer-transparent, so this
  // section opts back into pointer events.
  setSamples(seqs: SampleSequence[], onPick: (slug: string) => void) {
    this.elSamples.innerHTML = "";
    this.elSamples.style.pointerEvents = "auto";
    for (const s of seqs) {
      const a = document.createElement("a");
      a.href = "#";
      a.textContent = `▸ ${s.title}`;
      a.title = s.description;
      Object.assign(a.style, {
        display: "block",
        color: COL.dir,
        cursor: "pointer",
        textDecoration: "none",
      } as CSSStyleDeclaration);
      a.addEventListener("click", (e) => {
        e.preventDefault();
        onPick(s.slug);
      });
      this.elSamples.appendChild(a);
    }
  }
}

function column(flex: string): HTMLDivElement {
  const col = document.createElement("div");
  col.style.flex = flex;
  col.style.minWidth = "0"; // let the flexible column actually shrink and wrap
  return col;
}

function span(text: string, color: string, bold = false): string {
  return `<span style="color:${color}${bold ? ";font-weight:700" : ""}">${text}</span>`;
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function bar(val: number): string {
  const bars = [" ", "▂", "▃", "▄", "▅", "▆", "▇", "█"];
  const i = Math.floor(Math.max(0, Math.min(1, val)) * 7);
  return `[${bars[i]}]`;
}
