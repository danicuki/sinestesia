// Karaoke line — what the voice model heard, painted big enough for the house
// to read, centred in the lower third of the stage. Always on, including
// ?clean=1: the words are part of the show, not rehearsal chrome. Opt out with
// ?no-lyrics (same shape as ?no-verify for the badge).
//
// Interims paint the phrase as it is sung; the final locks it. When the next
// phrase starts, the finished line slides up as the dimmer "previous" line
// instead of being snatched away the moment it completes — with STT the first
// interim of a new phrase is one word, and losing the whole previous line to
// it read as a glitch. A few seconds without words (an instrumental, the end of
// the song) fades the strip out, and the next word starts clean.
//
// Text only, with a shadow rather than a box: the picture is the show and this
// sits on top of it. Pure DOM, pointer-transparent. Reads only PROTOCOL.md
// `transcript` messages — live from the socket, or replayed from a saved
// take's `events` at their recorded times — or a demo sequence's per-frame
// `lyric`.

import type { TranscriptMsg } from "./socket";

// Longest phrase shown. A gapless chorus can run the interim to twenty
// seconds of words; the newest are the ones that matter, so keep the tail.
const MAX_WORDS = 14;
// Silence this long and the strip fades — the singer stopped, or the song did.
const HIDE_AFTER_MS = 7_000;
const FADE_MS = 700;

export interface LyricsOverlayOptions {
  /** CSS distance from the bottom edge — clears the debug strip when it's up. */
  bottom: string;
  /** CSS font-size of the current line; the previous line is ~62% of it. */
  fontSize: string;
}

export class LyricsOverlay {
  private root: HTMLDivElement;
  private prev: HTMLDivElement;
  private cur: HTMLDivElement;
  private curFinal = false;
  private hideTimer: number | null = null;
  private wipeTimer: number | null = null;

  constructor(opts: LyricsOverlayOptions) {
    this.root = document.createElement("div");
    Object.assign(this.root.style, {
      position: "fixed",
      left: "0",
      right: "0",
      bottom: opts.bottom,
      // Under every piece of chrome (gate 10, debug 20, dock 25): the words
      // never cover a button, and a demo that starts behind the start gate
      // doesn't paint over it.
      zIndex: "5",
      display: "flex",
      flexDirection: "column",
      alignItems: "center",
      gap: "0.15em",
      padding: "0 8vw",
      pointerEvents: "none",
      textAlign: "center",
      fontFamily:
        'ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", sans-serif',
      fontSize: opts.fontSize,
      lineHeight: "1.2",
      color: "#fff",
      // Legible over a bright image AND a black one: a tight dark edge plus a
      // wide soft halo, no background box.
      textShadow:
        "0 0 2px rgba(0,0,0,.95), 0 2px 6px rgba(0,0,0,.9), 0 0 28px rgba(0,0,0,.7)",
      opacity: "0",
      transition: `opacity ${FADE_MS}ms ease`,
    } as CSSStyleDeclaration);

    this.prev = document.createElement("div");
    Object.assign(this.prev.style, {
      fontSize: "0.62em",
      fontWeight: "500",
      color: "rgba(255,255,255,0.7)",
      maxWidth: "100%",
    } as CSSStyleDeclaration);

    this.cur = document.createElement("div");
    Object.assign(this.cur.style, {
      fontWeight: "650",
      letterSpacing: "0.01em",
      maxWidth: "100%",
      transition: "opacity 200ms ease",
    } as CSSStyleDeclaration);

    this.root.append(this.prev, this.cur);
    document.body.appendChild(this.root);
  }

  /** Every `transcript` message, interim or final — live from the socket, or
   *  a saved take's recorded transcript replayed at the time it arrived. */
  setTranscript(m: Pick<TranscriptMsg, "text" | "isFinal">) {
    this.show(m.text, m.isFinal);
  }

  /** Demo sequences: the line that was sung for this frame. Empty = musical
   *  introduction, nothing to show. */
  showLine(text: string | undefined) {
    if (!text || !text.trim()) {
      this.clear();
      return;
    }
    this.show(text, true);
  }

  /** Song ended or discarded: wipe at once, no fade — the canvas went black too. */
  clear() {
    this.cancelTimers();
    this.root.style.opacity = "0";
    this.prev.textContent = "";
    this.cur.textContent = "";
    this.curFinal = false;
  }

  private show(raw: string, isFinal: boolean) {
    const text = tail(strip(raw), MAX_WORDS);
    if (!text) return;

    this.cancelTimers();

    // A new phrase after a finished one: promote the final to the upper line.
    // (A final arriving for the phrase the interims were painting replaces
    // them in place; an interim that merely repeats the final changes nothing.)
    if (this.curFinal && text !== this.cur.textContent) {
      this.prev.textContent = this.cur.textContent;
    }

    this.cur.textContent = text;
    // An interim is still being listened to; say so, quietly.
    this.cur.style.opacity = isFinal ? "1" : "0.85";
    this.curFinal = isFinal;
    this.root.style.opacity = "1";

    this.hideTimer = window.setTimeout(() => {
      this.root.style.opacity = "0";
      // Once invisible, forget both lines: a line from before a long
      // instrumental break has nothing to do with what comes next.
      this.wipeTimer = window.setTimeout(() => {
        this.prev.textContent = "";
        this.cur.textContent = "";
        this.curFinal = false;
      }, FADE_MS);
    }, HIDE_AFTER_MS);
  }

  private cancelTimers() {
    if (this.hideTimer !== null) window.clearTimeout(this.hideTimer);
    if (this.wipeTimer !== null) window.clearTimeout(this.wipeTimer);
    this.hideTimer = null;
    this.wipeTimer = null;
  }
}

/** One line of plain words. Some models decorate what they heard —
 *  `<<letra aqui>>` has shown up on stage. The backend drops the markers at
 *  its door; this is the belt to that suspender, for an older backend. */
function strip(raw: string): string {
  return raw.replace(/<<|>>/g, "").replace(/\s+/g, " ").trim();
}

/** The last `n` words, with an ellipsis when something was dropped. */
function tail(text: string, n: number): string {
  const words = text.split(" ");
  if (words.length <= n) return text;
  return "… " + words.slice(-n).join(" ");
}
