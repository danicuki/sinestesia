// Visual style control — small input + "nova música" button, top-right. Lets the
// singer steer the art direction and start a fresh song live during rehearsal.
// Hidden under ?clean=1 for a clean stage demo.
//
// Per PROTOCOL.md: on Enter/blur we send { type: "style", style } and the
// backend echoes the accepted (sanitized + capped) value, which we then reflect
// back into the input. No client-side cap or rate-limiting — the backend owns
// sanitization/capping (up to 15 words) and no-ops a repeated style. The
// "nova música" button sends { type: "reset" }; the backend then echoes a style
// with source "reset" which clears the input back to empty.

type SendCb = (style: string) => void;
type ResetCb = () => void;

export class StyleControl {
  private input: HTMLInputElement;
  // Start as "" so an untouched blur (empty value) doesn't emit a needless send.
  private lastSent = "";

  constructor(
    private send: SendCb,
    private requestReset: ResetCb,
  ) {
    const wrap = document.createElement("div");
    Object.assign(wrap.style, {
      position: "fixed",
      top: "10px",
      right: "10px",
      zIndex: "20",
      display: "flex",
      alignItems: "center",
      gap: "6px",
      padding: "6px 8px",
      background: "rgba(0,0,0,0.55)",
      borderRadius: "4px",
      font: "11px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace",
      color: "#e5e7eb",
      opacity: "0.7",
      cursor: "auto",
    } as CSSStyleDeclaration);

    const label = document.createElement("span");
    label.textContent = "style";
    Object.assign(label.style, {
      color: "#9ca3af",
      letterSpacing: "0.1em",
    } as CSSStyleDeclaration);

    this.input = document.createElement("input");
    this.input.type = "text";
    this.input.spellcheck = false;
    this.input.autocomplete = "off";
    this.input.placeholder = "";
    Object.assign(this.input.style, {
      width: "240px",
      background: "transparent",
      border: "1px solid #374151",
      borderRadius: "2px",
      color: "#fff",
      font: "inherit",
      padding: "3px 6px",
      outline: "none",
      cursor: "text",
    } as CSSStyleDeclaration);

    const resetBtn = document.createElement("button");
    resetBtn.type = "button";
    resetBtn.textContent = "nova música";
    Object.assign(resetBtn.style, {
      background: "transparent",
      border: "1px solid #374151",
      borderRadius: "2px",
      color: "#e5e7eb",
      font: "inherit",
      padding: "3px 8px",
      cursor: "pointer",
    } as CSSStyleDeclaration);
    resetBtn.addEventListener("click", () => this.requestReset());

    wrap.appendChild(label);
    wrap.appendChild(this.input);
    wrap.appendChild(resetBtn);
    document.body.appendChild(wrap);

    this.input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        this.submit();
        this.input.blur();
      }
    });
    this.input.addEventListener("blur", () => this.submit());
  }

  private submit() {
    const value = this.input.value.trim();
    if (value === this.lastSent) return; // dedup, not rate-limiting
    this.lastSent = value;
    this.send(value);
  }

  /**
   * Reflect a backend `style` echo. On a "reset" (new song) we clear the input
   * back to empty rather than showing the default — the singer starts blank,
   * exactly like session start. Otherwise mirror the accepted/curated value.
   */
  setAccepted(style: string, source: string) {
    if (source === "reset") {
      this.lastSent = "";
      this.input.value = "";
      return;
    }
    this.lastSent = style;
    // Don't clobber the caret mid-typing; only overwrite if it actually differs.
    if (this.input.value !== style) this.input.value = style;
  }
}
