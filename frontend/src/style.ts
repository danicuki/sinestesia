// Visual style control — small input, top-right. Lets the singer steer the art
// direction live during rehearsal. Hidden under ?clean=1 for a clean stage demo.
//
// Per PROTOCOL.md: on Enter/blur we send { type: "style", style } and the
// backend echoes the accepted (sanitized + 5-word-capped) value, which we then
// reflect back into the input. No client-side rate-limiting — the backend
// no-ops a repeated style.

const WORD_CAP = 5;

type SendCb = (style: string) => void;

function wordCount(s: string): number {
  const t = s.trim();
  return t === "" ? 0 : t.split(/\s+/).length;
}

export class StyleControl {
  private input: HTMLInputElement;
  private counter: HTMLSpanElement;
  // Start as "" so an untouched blur (empty value) doesn't emit a needless send.
  private lastSent = "";

  constructor(private send: SendCb) {
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
      width: "200px",
      background: "transparent",
      border: "1px solid #374151",
      borderRadius: "2px",
      color: "#fff",
      font: "inherit",
      padding: "3px 6px",
      outline: "none",
      cursor: "text",
    } as CSSStyleDeclaration);

    this.counter = document.createElement("span");
    Object.assign(this.counter.style, {
      color: "#6b7280",
      minWidth: "26px",
      textAlign: "right",
    } as CSSStyleDeclaration);

    wrap.appendChild(label);
    wrap.appendChild(this.input);
    wrap.appendChild(this.counter);
    document.body.appendChild(wrap);

    this.input.addEventListener("input", () => this.updateCounter());
    this.input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        this.submit();
        this.input.blur();
      }
    });
    this.input.addEventListener("blur", () => this.submit());

    this.updateCounter();
  }

  private updateCounter() {
    const n = wordCount(this.input.value);
    this.counter.textContent = `${n}/${WORD_CAP}`;
    // Over the cap is allowed — the backend truncates and echoes back the
    // accepted value — but flag it so the singer sees it'll be trimmed.
    this.counter.style.color = n > WORD_CAP ? "#f87171" : "#6b7280";
  }

  private submit() {
    const value = this.input.value.trim();
    if (value === this.lastSent) return; // dedup, not rate-limiting
    this.lastSent = value;
    this.send(value);
  }

  /** Reflect the backend's accepted (possibly truncated) style. */
  setAccepted(style: string) {
    this.lastSent = style;
    // Don't clobber the caret mid-typing; only overwrite if it actually differs.
    if (this.input.value !== style) this.input.value = style;
    this.updateCounter();
  }
}
