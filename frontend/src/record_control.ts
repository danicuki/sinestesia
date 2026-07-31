// "Save take" button — bottom-right, next to the other operator controls and
// hidden under ?clean=1 like all of them.
//
// One click downloads the take as JSON: everything sung (with timings) and
// every image that actually reached the screen, with the Director prompt that
// produced it. That file replays with `REPLAY_FILE=... mix sinestesia.replay`,
// so a timing problem can be reproduced and re-tested offline instead of being
// sung again for every attempt.
//
// The counter is the whole UI affordance: it shows the take is being captured
// without needing to be armed, because a recorder you have to remember to start
// is a recorder that is off for the take you actually wanted.

type SaveCb = () => void;
type ClearCb = () => void;

export class RecordControl {
  private button: HTMLButtonElement;
  private counter: HTMLSpanElement;

  constructor(
    private onSave: SaveCb,
    private onClear: ClearCb,
  ) {
    const wrap = document.createElement("div");
    Object.assign(wrap.style, {
      position: "fixed",
      bottom: "10px",
      right: "10px",
      zIndex: "20",
      display: "flex",
      alignItems: "center",
      gap: "8px",
      font: "11px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace",
      color: "#e5e7eb",
    } as CSSStyleDeclaration);

    this.counter = document.createElement("span");
    this.counter.style.opacity = "0.6";
    this.counter.textContent = "0 events";

    this.button = document.createElement("button");
    this.button.textContent = "Save take";
    this.button.title =
      "Download this take as JSON (what was sung + what was shown, with timings). Replays with mix sinestesia.replay.";
    Object.assign(this.button.style, {
      font: "inherit",
      color: "#e5e7eb",
      background: "rgba(17,24,39,0.75)",
      border: "1px solid rgba(148,163,184,0.4)",
      borderRadius: "4px",
      padding: "4px 8px",
      cursor: "pointer",
    } as CSSStyleDeclaration);
    this.button.addEventListener("click", () => this.onSave());

    const clear = document.createElement("button");
    clear.textContent = "Reset";
    clear.title = "Discard what has been captured and start a fresh take.";
    Object.assign(clear.style, this.button.style as unknown as CSSStyleDeclaration);
    clear.style.opacity = "0.7";
    clear.addEventListener("click", () => {
      this.onClear();
      this.setCount(0);
    });

    wrap.append(this.counter, this.button, clear);
    document.body.appendChild(wrap);
  }

  setCount(n: number): void {
    this.counter.textContent = `${n} event${n === 1 ? "" : "s"}`;
  }
}
