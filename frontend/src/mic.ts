// Mic panel — top-left rehearsal chrome: a live input-level meter (so you can
// confirm sound is actually being captured) plus a device picker to switch
// between input sources. Hidden under ?clean=1 for a clean stage demo.

type SelectCb = (deviceId: string) => void;

export class MicPanel {
  private select: HTMLSelectElement;
  private meterFill: HTMLDivElement;
  private readout: HTMLSpanElement;
  private level = 0; // smoothed display level (peak-hold-ish)

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

    wrap.appendChild(row);
    wrap.appendChild(meterRow);
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
}
