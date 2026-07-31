// Visual style control — small input + "End Song" button, top-right. Lets the
// singer steer the art direction and close out a song live during rehearsal.
// Hidden under ?clean=1 for a clean stage demo.
//
// Per PROTOCOL.md: on Enter/blur we send { type: "style", style } and the
// backend echoes the accepted (sanitized + capped) value, which we then reflect
// back into the input. No client-side cap or rate-limiting — the backend owns
// sanitization/capping (up to 15 words) and no-ops a repeated style. The
// "End Song" button sends { type: "end_song" }, which mints the finished
// painting and resets in one step; the chosen style is kept across songs (the
// backend's reset echo, source "reset", is ignored here).

type SendCb = (style: string) => void;
type EndSongCb = () => void;

// Quick-pick palette offered in the dropdown. Free text still works; these are
// just shortcuts to the looks we know read well on stage. Sorted alphabetically
// (case-insensitive) so the list is easy to scan.
const STYLE_SUGGESTIONS = [
  "loose ink sketch on aged paper, sparse hand-drawn linework, sepia tones",
  "crayon drawing on white paper, childlike, bright simple shapes",
  "graffiti street art",
  "charcoal sketch on grey paper, soft smudges and hatching",
  "watercolor and ink, pale washes, hand-drawn outlines",
  "Brazilian cordel woodcut print, black and white, hatched linework",
  "Colorful Expressionism",
  "Tarsila do Amaral style, Brazilian modernism, bold colors and geometric shapes",
].sort((a, b) => a.localeCompare(b, undefined, { sensitivity: "base" }));

export class StyleControl {
  private input: HTMLInputElement;
  private menu: HTMLDivElement;
  // Start as "" so an untouched blur (empty value) doesn't emit a needless send.
  private lastSent = "";

  constructor(
    private send: SendCb,
    private requestEndSong: EndSongCb,
    initial = "",
  ) {
    const wrap = document.createElement("div");
    const label = document.createElement("span");
    label.textContent = "style";
    Object.assign(label.style, {
      color: "#9ca3af",
      letterSpacing: "0.1em",
    } as CSSStyleDeclaration);

    // Input + custom dropdown live in a relative box so the menu can anchor
    // under the field. A native <datalist> hides every option once the field
    // holds a full value, so we roll our own list that always opens on focus.
    const field = document.createElement("div");
    Object.assign(field.style, {
      position: "relative",
      display: "inline-block",
    } as CSSStyleDeclaration);

    this.input = document.createElement("input");
    this.input.type = "text";
    this.input.spellcheck = false;
    this.input.autocomplete = "off";
    this.input.placeholder = "";
    if (initial) {
      this.input.value = initial;
      this.lastSent = initial; // prefilled value is already "current"
    }
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

    this.menu = document.createElement("div");
    Object.assign(this.menu.style, {
      position: "absolute",
      top: "calc(100% + 4px)",
      left: "0",
      right: "0",
      maxHeight: "240px",
      overflowY: "auto",
      background: "rgba(10,12,16,0.97)",
      border: "1px solid #374151",
      borderRadius: "3px",
      display: "none",
      zIndex: "30",
    } as CSSStyleDeclaration);

    field.appendChild(this.input);
    field.appendChild(this.menu);

    const endBtn = document.createElement("button");
    endBtn.type = "button";
    endBtn.textContent = "End Song";
    endBtn.title = "Mint the painting and start the next song (shortcut: m)";
    Object.assign(endBtn.style, {
      background: "transparent",
      border: "1px solid #374151",
      borderRadius: "2px",
      color: "#e5e7eb",
      font: "inherit",
      padding: "3px 8px",
      cursor: "pointer",
    } as CSSStyleDeclaration);
    endBtn.addEventListener("click", () => this.requestEndSong());

    wrap.appendChild(label);
    wrap.appendChild(field);
    wrap.appendChild(endBtn);
    // Top-right, deliberately NOT in the bottom dock: this is the one control
    // touched mid-song, its autocomplete needs room to drop DOWN, and down
    // there it collided with the panels that open upward.
    Object.assign(wrap.style, {
      position: "fixed",
      top: "10px",
      right: "10px",
      zIndex: "25",
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
    document.body.appendChild(wrap);

    // Open the list whenever the field is focused or clicked, even if it already
    // holds a full value — that was the whole point of replacing <datalist>.
    this.input.addEventListener("focus", () => this.openMenu());
    this.input.addEventListener("click", () => this.openMenu());
    this.input.addEventListener("input", () => this.openMenu());
    this.input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        this.submit();
        this.input.blur();
      } else if (e.key === "Escape") {
        this.closeMenu();
        this.input.blur();
      }
    });
    this.input.addEventListener("blur", () => {
      this.submit();
      this.closeMenu();
    });
  }

  private openMenu() {
    this.renderOptions();
    this.menu.style.display = "block";
  }

  private closeMenu() {
    this.menu.style.display = "none";
  }

  // Options matching the current text. Empty field (or an exact match of a
  // suggestion) shows the whole list so you can browse alternatives; partial
  // typing filters by substring.
  //
  // A filter that matches NOTHING falls back to the whole list rather than
  // showing an empty menu. This field is not a search box over a closed set —
  // any text is a valid style — so typing a custom one used to make the
  // presets vanish, with no way back to them except deleting what you had just
  // written. Browsing the presets and writing your own have to coexist.
  private filtered(): string[] {
    const q = this.input.value.trim().toLowerCase();
    if (!q || STYLE_SUGGESTIONS.some((s) => s.toLowerCase() === q)) {
      return STYLE_SUGGESTIONS;
    }
    const hits = STYLE_SUGGESTIONS.filter((s) => s.toLowerCase().includes(q));
    return hits.length > 0 ? hits : STYLE_SUGGESTIONS;
  }

  private renderOptions() {
    this.menu.innerHTML = "";
    for (const s of this.filtered()) {
      const opt = document.createElement("div");
      opt.textContent = s;
      Object.assign(opt.style, {
        padding: "5px 8px",
        cursor: "pointer",
        color: "#e5e7eb",
        whiteSpace: "nowrap",
        overflow: "hidden",
        textOverflow: "ellipsis",
      } as CSSStyleDeclaration);
      opt.addEventListener("mouseenter", () => {
        opt.style.background = "rgba(147,197,253,0.18)";
      });
      opt.addEventListener("mouseleave", () => {
        opt.style.background = "transparent";
      });
      // mousedown (not click) so we beat the input's blur and keep focus off the
      // race: preventDefault stops the blur, we set + submit, then close.
      opt.addEventListener("mousedown", (e) => {
        e.preventDefault();
        this.input.value = s;
        this.submit();
        this.closeMenu();
        this.input.blur();
      });
      this.menu.appendChild(opt);
    }
  }

  private submit() {
    const value = this.input.value.trim();
    if (value === this.lastSent) return; // dedup, not rate-limiting
    this.lastSent = value;
    this.send(value);
  }

  /** The style currently in the field (used to keep it across an "End Song"). */
  currentStyle(): string {
    return this.input.value.trim();
  }

  /**
   * Reflect a backend `style` echo. A "reset" (new song) echo is ignored — we
   * keep the chosen style across songs rather than blanking it. Otherwise mirror
   * the accepted/curated value.
   */
  setAccepted(style: string, source: string) {
    if (source === "reset") return; // keep the singer's chosen style
    this.lastSent = style;
    // Don't clobber the caret mid-typing; only overwrite if it actually differs.
    if (this.input.value !== style) this.input.value = style;
  }
}
