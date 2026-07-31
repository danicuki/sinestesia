import { mountInDock, panelOpensUpward } from "./dock";
// Lyrics control — a collapsible textarea, bottom-left, where the operator
// pastes the song's lyrics BEFORE it is sung, one stanza per verse/chorus,
// separated by a BLANK LINE (so the backend can tell a verse from a chorus).
// With SPECULATIVE_LOOKAHEAD on, the backend renders each line ahead of the
// singer and reveals it the moment STT confirms it, hiding the render lag; with
// MUSICAL_STRUCTURE on, it also detects verse/chorus/bridge/outro from the
// blank-line stanzas and tells the Director when the song returns to the
// chorus. Hidden under ?clean=1 like the style control.
//
// Per PROTOCOL.md: "Load" sends { type: "lyrics", text }, the RAW textarea
// content (blank lines intact — that's what carries the stanza boundaries to
// the backend's structure detection); "Clear" sends an empty string. There is
// no backend echo — loading lyrics is advisory, and if none are loaded (or the
// singing goes off-script) the backend simply falls back to its reactive
// behaviour, so this control can never break a show.

type SendLyricsCb = (text: string) => void;

export class LyricsControl {
  private textarea: HTMLTextAreaElement;
  private panel: HTMLDivElement;
  private open = false;

  constructor(
    private send: SendLyricsCb,
    initial = "",
  ) {
    const wrap = document.createElement("div");
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
    panelOpensUpward(this.panel);

    this.textarea = document.createElement("textarea");
    this.textarea.spellcheck = false;
    this.textarea.placeholder =
      "Paste the song's lyrics.\nSeparate verse/chorus stanzas\nwith a BLANK LINE.";
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
    mountInDock(wrap);
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

  /** Non-empty, trimmed lines — used only for the "N lines loaded" status text. */
  private nonBlankLines(): string[] {
    return this.textarea.value
      .split(/\r?\n/)
      .map((l) => l.trim())
      .filter((l) => l.length > 0);
  }

  private load() {
    const text = this.textarea.value; // raw — blank lines carry the stanza breaks
    const n = this.nonBlankLines().length;
    this.send(text);
    this.status.textContent = n ? `${n} lines loaded` : "cleared";
  }

  private clear() {
    this.textarea.value = "";
    this.send("");
    this.status.textContent = "cleared";
  }
}
