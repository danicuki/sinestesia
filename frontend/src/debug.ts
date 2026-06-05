// ?debug=1 overlay — bottom-left, small monospace, for live latency/A-B
// inspection during the show. Pure DOM, no chrome elsewhere. Reads the
// `provider` + `latency_ms` on transcripts and the `timings` block on images
// (PROTOCOL.md). Created only when the URL flag is present.

import type { Timings, TranscriptMsg } from "./socket";

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
  private elTranscript: HTMLDivElement;
  private elPrompt: HTMLDivElement;
  private elHistory: HTMLDivElement;

  private history: TimingEntry[] = [];

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

    this.elTranscript = this.section(left, "transcript");
    this.elPrompt = this.section(left, "director prompt");
    this.elHistory = this.section(right, "history (last 5)");

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
