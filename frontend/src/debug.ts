// ?debug=1 overlay — bottom-left, small monospace, for live latency/A-B
// inspection during the show. Pure DOM, no chrome elsewhere. Reads the
// `provider` + `latency_ms` on transcripts and the `timings` block on images
// (PROTOCOL.md). Created only when the URL flag is present.

import type {
  ExpressiveFeatures,
  MelodyFeatures,
  StructureMsg,
  Timings,
  TranscriptMsg,
} from "./socket";
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
  private elMelody: HTMLDivElement;
  private elSemiotics: HTMLDivElement;
  private elStructure: HTMLDivElement;
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
      // Hard ceiling: instrumentation must never creep up over the picture.
      maxHeight: "30vh",
      overflow: "hidden",
      // Clear the control dock by leaving room BELOW, not beside. Reserving a
      // right margin instead cost the columns a quarter of the screen across
      // their whole height, to dodge a single row of buttons in one corner —
      // and the squeeze put the history back to wrapping every line.
      paddingBottom: "40px",
      background: "rgba(0,0,0,0.55)",
      font: "11px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace",
      color: COL.final,
      opacity: "0.6",
      pointerEvents: "none",
      whiteSpace: "pre-wrap",
      wordBreak: "break-word",
    } as CSSStyleDeclaration);

    // Three columns, not one tall stack plus a sidebar. Eight sections in a
    // single column made the overlay tall enough to eat the middle of the
    // stage — the picture is the show, and this is instrumentation. Spread
    // across three, the strip is about a third as tall for the same content.
    //
    // Grouped by what they answer, so the eye knows where to look: how the
    // voice SOUNDS, what it SAID, and how the run is PERFORMING.
    // Equal thirds. `run` used to be "0 0 auto", so it sized to its widest
    // history row and took whatever it wanted — which, with a full model id on
    // every line, was most of the strip, crushing the other two.
    // Not quite even: the history rows are the widest content in the strip and
    // wrap the moment they're short of room, so `run` gets a little more and
    // the transcript — which wraps gracefully — gives it up.
    const sound = column("1 1 0");
    const words = column("0.85 1 0");
    const run = column("1.3 1 0");

    this.elAudio = this.section(sound, "rail 1 — movement");
    this.elExpressive = this.section(sound, "rail 3 — expression");
    this.elMelody = this.section(sound, "melody → director");
    this.elSemiotics = this.section(sound, "tatit & segreto semiotics (expressive)");

    this.elTranscript = this.section(words, "transcript");
    this.elPrompt = this.section(words, "director prompt");
    this.elStructure = this.section(words, "structure (phase 2 — lyrics look-ahead)");
    this.elLyric = this.section(words, "sample lyric");

    this.elHistory = this.section(run, "history (last 5)");
    this.elSamples = this.section(run, "sample sequences");
    this.elParams = this.section(run, "run params");

    this.root.append(sound, words, run);
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

    if (f.semiotics) {
      const s = f.semiotics;
      this.elSemiotics.innerHTML =
        span("ORALIZAÇÃO (Segreto) ", COL.dim) + bar(s.oralization) + span(` ${s.oralization.toFixed(2)}`, COL.tot, true) + "   " +
        span("PASSIONAL   (Lamento) ", COL.dim) + bar(s.passional) + span(` ${s.passional.toFixed(2)}`, COL.stt) + "\n" +
        span("FIGURATIVO  (Canto-Fala)", COL.dim) + bar(s.figurativo) + span(` ${s.figurativo.toFixed(2)}`, COL.dir) + "   " +
        span("TEMÁTICO    (Ritmo)     ", COL.dim) + bar(s.tematico) + span(` ${s.tematico.toFixed(2)}`, COL.img);
    } else {
      this.elSemiotics.textContent = "—";
    }
  }

  // Realtime melody hint we last sent to the backend (~2Hz while voiced).
  setMelody(m: MelodyFeatures) {
    const parts: string[] = [];
    if (m.contour) parts.push(span(m.contour, COL.tot, true));
    if (m.register != null)
      parts.push(span("reg ", COL.dim) + span(m.register.toFixed(2), COL.stt));
    if (m.vibrato != null)
      parts.push(span("vib ", COL.dim) + span(m.vibrato.toFixed(2), COL.dir));
    if (m.energy != null)
      parts.push(span("en ", COL.dim) + span(m.energy.toFixed(2), COL.img));
    this.elMelody.innerHTML = parts.length ? parts.join("  ") : "—";
  }

  // Current section + tempo (musical structure, pushed only when the backend
  // has lyrics loaded and MUSICAL_STRUCTURE on). `section: null` before any
  // position is known; `tempoBpm: null` is an honest "no confident estimate",
  // not silence — never rendered as 0.
  setStructure(m: StructureMsg) {
    const sectionText = m.section
      ? span(m.section.label.toUpperCase(), COL.tot, true) +
        (m.section.occurrence > 1 ? span(` ×${m.section.occurrence}`, COL.dir) : "") +
        span(`  (line ${m.section.index})`, COL.dim)
      : span("no position yet", COL.dim);
    const tempoText =
      m.tempoBpm != null
        ? span("  ~", COL.dim) + span(`${Math.round(m.tempoBpm)} bpm`, COL.stt)
        : "";
    this.elStructure.innerHTML = sectionText + tempoText;
  }

  // Rolling history of the last 5 cycles (top row = latest).
  addTimings(t: Timings) {
    this.history.unshift({ t, at: performance.now() });
    if (this.history.length > 5) this.history.pop();
    this.renderHistory();
  }

  // STT 195 | DIR 870 | IMG 480 | Q 120 | TOT 1545ms (fal)
  // DIR/IMG are provider round-trips; Q is time queued inside the pipeline, shown
  // separately (and only when non-trivial) so our own backpressure isn't misread
  // as a slow model.
  private formatTiming(t: Timings): string {
    // A pre-rendered frame has no STT leg at all — it was drawn from the pasted
    // lyrics before the line was sung — and its Director cost was paid seconds
    // earlier, so neither belongs in a latency read-out. Printing them anyway
    // gave "STT null | DIR 0", which reads as the Director being instantaneous
    // rather than as the work having already been done. Say what happened.
    if (t.prerendered) {
      return (
        span("PRE", COL.dir, true) +
        span(" | ", COL.dim) +
        span(`IMG ${t.image_ms}`, COL.img) +
        (t.morph_ms && t.morph_ms > 0
          ? span(" | ", COL.dim) + span(`MRP ${t.morph_ms}`, COL.img)
          : "") +
        span("  drawn ahead", COL.dim) +
        " " +
        this.provider(t.image_provider)
      );
    }
    const queue =
      t.queue_ms && t.queue_ms > 0
        ? span(" | ", COL.dim) + span(`Q ${t.queue_ms}`, COL.dim)
        : "";
    const morph =
      t.morph_ms && t.morph_ms > 0
        ? span(" | ", COL.dim) + span(`MRP ${t.morph_ms}`, COL.img)
        : "";
    return (
      span(`STT ${t.stt_ms}`, COL.stt) +
      span(" | ", COL.dim) +
      span(`DIR ${t.director_ms}`, COL.dir) +
      span(" | ", COL.dim) +
      span(`IMG ${t.image_ms}`, COL.img) +
      morph +
      queue +
      span(" | ", COL.dim) +
      span(`TOT ${t.total_ms}ms`, COL.tot, true) +
      " " +
      this.provider(t.image_provider)
    );
  }

  // "cloudflare t2i 6st @cf/bytedance/stable-diffusion-xl-lightning" is most of
  // a line on its own, and repeated down five history rows it forced the whole
  // column wide enough to squeeze the transcript and the rails out of the way.
  // The route (provider + mode + steps) is what's read at a glance; the exact
  // model id matters only when something looks wrong, so it moves to the
  // tooltip and leaves a "…" to say there is more.
  private provider(raw: string | undefined): string {
    const full = raw ?? "?";
    const at = full.indexOf("@");
    if (at < 0) return span(`(${escapeHtml(full)})`, COL.prov);

    const head = full.slice(0, at).trim();
    return `<span style="color:${COL.prov}" title="${escapeHtml(full)}">(${escapeHtml(head)} …)</span>`;
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
  // A combo, not one link per sequence: this list is as long as the sample
  // catalog and it sat in a fixed-height overlay, so every added sequence stole
  // another line from the stage. One row, whatever the catalog size.
  setSamples(seqs: SampleSequence[], onPick: (slug: string) => void) {
    this.elSamples.innerHTML = "";
    this.elSamples.style.pointerEvents = "auto";
    if (seqs.length === 0) return;

    const select = document.createElement("select");
    Object.assign(select.style, {
      maxWidth: "100%",
      background: "rgba(0,0,0,0.55)",
      border: "1px solid #374151",
      borderRadius: "2px",
      color: COL.dir,
      font: "inherit",
      padding: "2px 4px",
      cursor: "pointer",
    } as CSSStyleDeclaration);

    // A placeholder first option, so picking the sequence that happens to be
    // first in the list still fires a change event.
    const placeholder = document.createElement("option");
    placeholder.value = "";
    placeholder.textContent = "▸ play a sample…";
    select.appendChild(placeholder);

    for (const s of seqs) {
      const opt = document.createElement("option");
      opt.value = s.slug;
      opt.textContent = s.title;
      opt.title = s.description;
      select.appendChild(opt);
    }

    select.addEventListener("change", () => {
      const slug = select.value;
      if (!slug) return;
      onPick(slug);
      select.value = ""; // back to the placeholder, ready for the next pick
    });

    this.elSamples.appendChild(select);
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
