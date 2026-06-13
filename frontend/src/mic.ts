// Mic panel — top-left rehearsal chrome: a live input-level meter (so you can
// confirm sound is actually being captured) plus a device picker to switch
// between input sources. Hidden under ?clean=1 for a clean stage demo.

type SelectCb = (deviceId: string) => void;

const NOTE_NAMES = [
  "C", "C#", "D", "D#", "E", "F",
  "F#", "G", "G#", "A", "A#", "B",
];

export class MicPanel {
  private select: HTMLSelectElement;
  private meterFill: HTMLDivElement;
  private readout: HTMLSpanElement;
  private level = 0; // smoothed display level (peak-hold-ish)
  private note: HTMLSpanElement;
  private needle: HTMLDivElement;
  private freq: HTMLSpanElement;
  private needlePos = 0.5; // smoothed needle position 0..1 (0.5 = in tune)

  constructor(private onSelect: SelectCb) {
    const wrap = document.createElement("div");
    Object.assign(wrap.style, {
      position: "fixed",
      top: "10px",
      left: "10px",
      zIndex: "20",
      display: "flex",
      flexDirection: "column",
      gap: "5px",
      padding: "6px 8px",
      background: "rgba(0,0,0,0.55)",
      borderRadius: "4px",
      font: "11px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace",
      color: "#e5e7eb",
      opacity: "0.7",
    } as CSSStyleDeclaration);

    // --- Row 1: device picker ---
    const row = document.createElement("div");
    Object.assign(row.style, {
      display: "flex",
      alignItems: "center",
      gap: "6px",
    } as CSSStyleDeclaration);

    const label = document.createElement("span");
    label.textContent = "mic";
    Object.assign(label.style, {
      color: "#9ca3af",
      letterSpacing: "0.1em",
    } as CSSStyleDeclaration);

    this.select = document.createElement("select");
    Object.assign(this.select.style, {
      maxWidth: "220px",
      background: "transparent",
      border: "1px solid #374151",
      borderRadius: "2px",
      color: "#fff",
      font: "inherit",
      padding: "2px 4px",
      outline: "none",
      cursor: "pointer",
    } as CSSStyleDeclaration);
    this.select.addEventListener("change", () => {
      if (this.select.value) this.onSelect(this.select.value);
    });

    row.appendChild(label);
    row.appendChild(this.select);

    // --- Row 2: level meter + numeric readout ---
    const meterRow = document.createElement("div");
    Object.assign(meterRow.style, {
      display: "flex",
      alignItems: "center",
      gap: "6px",
    } as CSSStyleDeclaration);

    const track = document.createElement("div");
    Object.assign(track.style, {
      position: "relative",
      width: "180px",
      height: "8px",
      background: "rgba(255,255,255,0.12)",
      borderRadius: "4px",
      overflow: "hidden",
    } as CSSStyleDeclaration);

    this.meterFill = document.createElement("div");
    Object.assign(this.meterFill.style, {
      position: "absolute",
      left: "0",
      top: "0",
      bottom: "0",
      width: "0%",
      background: "#6ee7b7",
      transition: "width 0.05s linear, background-color 0.1s linear",
    } as CSSStyleDeclaration);
    track.appendChild(this.meterFill);

    this.readout = document.createElement("span");
    this.readout.textContent = "—";
    Object.assign(this.readout.style, {
      color: "#9ca3af",
      minWidth: "34px",
      textAlign: "right",
    } as CSSStyleDeclaration);

    meterRow.appendChild(track);
    meterRow.appendChild(this.readout);

    // --- Row 3: pitch "tuner" — note name, an in-tune needle, and the Hz ---
    const tunerRow = document.createElement("div");
    Object.assign(tunerRow.style, {
      display: "flex",
      alignItems: "center",
      gap: "8px",
    } as CSSStyleDeclaration);

    this.note = document.createElement("span");
    this.note.textContent = "—";
    Object.assign(this.note.style, {
      minWidth: "34px",
      fontWeight: "700",
      fontSize: "13px",
      color: "#e5e7eb",
    } as CSSStyleDeclaration);

    // Needle track: a strip with a center "in tune" tick; the needle slides
    // left (flat) / right (sharp) by the cents offset and greens up near center.
    const ntrack = document.createElement("div");
    Object.assign(ntrack.style, {
      position: "relative",
      width: "180px",
      height: "12px",
      background: "rgba(255,255,255,0.12)",
      borderRadius: "4px",
      overflow: "hidden",
    } as CSSStyleDeclaration);

    const center = document.createElement("div");
    Object.assign(center.style, {
      position: "absolute",
      left: "50%",
      top: "0",
      bottom: "0",
      width: "1px",
      marginLeft: "-0.5px",
      background: "rgba(255,255,255,0.45)",
    } as CSSStyleDeclaration);

    this.needle = document.createElement("div");
    Object.assign(this.needle.style, {
      position: "absolute",
      left: "50%",
      top: "1px",
      bottom: "1px",
      width: "3px",
      marginLeft: "-1.5px",
      background: "#6b7280",
      borderRadius: "2px",
      transition: "left 0.06s linear, background-color 0.1s linear",
    } as CSSStyleDeclaration);

    ntrack.appendChild(center);
    ntrack.appendChild(this.needle);

    this.freq = document.createElement("span");
    this.freq.textContent = "—";
    Object.assign(this.freq.style, {
      color: "#9ca3af",
      minWidth: "52px",
      textAlign: "right",
    } as CSSStyleDeclaration);

    tunerRow.appendChild(this.note);
    tunerRow.appendChild(ntrack);
    tunerRow.appendChild(this.freq);

    wrap.appendChild(row);
    wrap.appendChild(meterRow);
    wrap.appendChild(tunerRow);
    document.body.appendChild(wrap);
  }

  /** Populate the device dropdown; marks the active input as selected. */
  setDevices(devices: MediaDeviceInfo[], currentId?: string) {
    this.select.innerHTML = "";
    devices.forEach((d, i) => {
      const opt = document.createElement("option");
      opt.value = d.deviceId;
      opt.textContent = d.label || `Input ${i + 1}`;
      // <option> on a dark <select> needs explicit colors on some platforms.
      opt.style.color = "#000";
      if (d.deviceId === currentId) opt.selected = true;
      this.select.appendChild(opt);
    });
  }

  /** Feed the live RMS (0..1) each frame. Uses fast-attack / slow-release. */
  setLevel(rms: number) {
    // Linear RMS reads far too low — voice rarely exceeds ~0.2-0.3 RMS, so a
    // linear bar barely moves. OS mic meters are dB-based (logarithmic), which
    // expands the quiet range. Map [FLOOR_DB .. 0 dB] onto [0 .. 1] to match.
    const FLOOR_DB = -55;
    const db = 20 * Math.log10(Math.max(rms, 1e-5));
    const v = Math.max(0, Math.min(1, (db - FLOOR_DB) / -FLOOR_DB));
    // Fast attack so a clap jumps; slow release so the bar is readable.
    this.level = v > this.level ? v : this.level * 0.85 + v * 0.15;
    this.meterFill.style.width = `${this.level * 100}%`;
    // Green → amber → red as it gets hot, so clipping is obvious.
    this.meterFill.style.background =
      this.level > 0.85 ? "#f87171" : this.level > 0.6 ? "#fcd34d" : "#6ee7b7";
    this.readout.textContent = this.level.toFixed(2);
  }

  /**
   * Feed the live fundamental in Hz (0 = no clear pitch). Renders a guitar-
   * tuner readout: nearest note name, a needle showing how flat/sharp (±50
   * cents) the voice is, and the raw frequency.
   */
  setPitch(hz: number) {
    if (hz <= 0) {
      // Unvoiced: ease the needle back to center and dim the labels.
      this.needlePos += (0.5 - this.needlePos) * 0.2;
      this.needle.style.left = `${this.needlePos * 100}%`;
      this.needle.style.background = "#6b7280";
      this.note.textContent = "—";
      this.note.style.color = "#6b7280";
      this.freq.textContent = "—";
      return;
    }

    // Map Hz → nearest equal-tempered semitone (A4 = 440) + cents offset.
    const midi = 69 + 12 * Math.log2(hz / 440);
    const nearest = Math.round(midi);
    const cents = (midi - nearest) * 100; // -50..+50
    const name = NOTE_NAMES[((nearest % 12) + 12) % 12];
    const octave = Math.floor(nearest / 12) - 1;

    this.note.textContent = `${name}${octave}`;
    this.note.style.color = "#e5e7eb";
    this.freq.textContent = `${hz.toFixed(1)} Hz`;

    // Needle: 0.5 = in tune; ±50 cents map to the strip edges. Smoothed so it
    // glides like a real tuner. Green when within ±5 cents, amber otherwise.
    const target = Math.max(0, Math.min(1, 0.5 + cents / 100));
    this.needlePos += (target - this.needlePos) * 0.3;
    this.needle.style.left = `${this.needlePos * 100}%`;
    this.needle.style.background =
      Math.abs(cents) <= 5 ? "#6ee7b7" : Math.abs(cents) <= 20 ? "#fcd34d" : "#f87171";
  }
}
