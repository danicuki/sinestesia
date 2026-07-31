// Lyrics control — a collapsible textarea, bottom-left, where the operator
// pastes the song's lyrics (one line per line) BEFORE it is sung. With the
// backend's SPECULATIVE_LOOKAHEAD on, this lets it render each line ahead of the
// singer and reveal it the moment STT confirms the line, hiding the render lag.
// Hidden under ?clean=1 like the style control.
//
// Per PROTOCOL.md: "Load" sends { type: "lyrics", lines: string[] }; "Clear"
// sends an empty array. There is no backend echo — loading lyrics is advisory,
// and if none are loaded (or the singing goes off-script) the backend simply
// falls back to its reactive behaviour, so this control can never break a show.

type SendLyricsCb = (lines: string[]) => void;

export class LyricsControl {
  private textarea: HTMLTextAreaElement;
  private panel: HTMLDivElement;
  private open = false;

  constructor(
    private send: SendLyricsCb,
    initial = "",
  ) {
    const wrap = document.createElement("div");
    Object.assign(wrap.style, {
      position: "fixed",
      bottom: "10px",
      left: "10px",
      zIndex: "20",
      display: "flex",
      flexDirection: "column",
      alignItems: "flex-start",
      gap: "6px",
      font: "11px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace",
      color: "#e5e7eb",
    } as CSSStyleDeclaration);

    const toggle = document.createElement("button");
    toggle.type = "button";
    toggle.textContent = "lyrics";
    toggle.title = "Paste the song's lyrics for predictive look-ahead";
    Object.assign(toggle.style, {
      background: "rgba(0,0,0,0.55)",
      border: "1px solid #374151",
      borderRadius: "3px",
      color: "#9ca3af",
      font: "inherit",
      letterSpacing: "0.1em",
      padding: "4px 8px",
      cursor: "pointer",
      opacity: "0.7",
    } as CSSStyleDeclaration);
    toggle.addEventListener("click", () => this.toggle());

    this.panel = document.createElement("div");
    Object.assign(this.panel.style, {
      display: "none",
      flexDirection: "column",
      gap: "6px",
      padding: "8px",
      background: "rgba(0,0,0,0.7)",
      border: "1px solid #374151",
      borderRadius: "4px",
    } as CSSStyleDeclaration);

    this.textarea = document.createElement("textarea");
    this.textarea.spellcheck = false;
    this.textarea.placeholder = "Paste the song's lyrics,\none line per line…";
    this.textarea.value = initial;
    Object.assign(this.textarea.style, {
      width: "300px",
      height: "180px",
      resize: "vertical",
      background: "transparent",
      border: "1px solid #374151",
      borderRadius: "2px",
      color: "#fff",
      font: "inherit",
      padding: "6px",
      outline: "none",
    } as CSSStyleDeclaration);

    const row = document.createElement("div");
    Object.assign(row.style, {
      display: "flex",
      gap: "6px",
      alignItems: "center",
    } as CSSStyleDeclaration);

    const loadBtn = this.button("Load", () => this.load());
    const clearBtn = this.button("Clear", () => this.clear());

    this.status = document.createElement("span");
    Object.assign(this.status.style, { color: "#9ca3af" } as CSSStyleDeclaration);

    row.appendChild(loadBtn);
    row.appendChild(clearBtn);
    row.appendChild(this.status);

    this.panel.appendChild(this.textarea);
    this.panel.appendChild(row);

    wrap.appendChild(toggle);
    wrap.appendChild(this.panel);
    document.body.appendChild(wrap);
  }

  private status: HTMLSpanElement;

  private button(text: string, onClick: () => void): HTMLButtonElement {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = text;
    Object.assign(b.style, {
      background: "transparent",
      border: "1px solid #374151",
      borderRadius: "2px",
      color: "#e5e7eb",
      font: "inherit",
      padding: "3px 10px",
      cursor: "pointer",
    } as CSSStyleDeclaration);
    b.addEventListener("click", onClick);
    return b;
  }

  private toggle() {
    this.open = !this.open;
    this.panel.style.display = this.open ? "flex" : "none";
  }

  /** Split the textarea into non-empty, trimmed lines. */
  lines(): string[] {
    return this.textarea.value
      .split(/\r?\n/)
      .map((l) => l.trim())
      .filter((l) => l.length > 0);
  }

  private load() {
    const lines = this.lines();
    this.send(lines);
    this.status.textContent = lines.length ? `${lines.length} lines loaded` : "cleared";
  }

  private clear() {
    this.textarea.value = "";
    this.send([]);
    this.status.textContent = "cleared";
  }
}
