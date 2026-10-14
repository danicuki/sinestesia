import { mountInDock } from "./dock";

// "Load take" — plays a saved take back EXACTLY as it happened: the images the
// browser actually put on screen, at the times it showed them, over the take's
// own audio. Pick the take's .json together with its sibling .webm in the file
// dialog (the JSON alone replays silently, on a wall clock).
//
// This is the faithful half of the replay story. `mix sinestesia.replay` is
// the other half — it RE-GENERATES the take through the live pipeline — so a
// new Director or image provider is judged by loading both outputs against
// this ground truth.

export type TakeFrame = { at_ms: number; url: string; prompt: string };

export type TakePlayback = {
  name: string;
  frames: TakeFrame[];
  audioUrl: string | null;
};

type PlayCb = (take: TakePlayback) => void;

export class TakePlayerControl {
  private status: HTMLSpanElement;
  private lastAudioUrl: string | null = null;

  constructor(onPlay: PlayCb) {
    const wrap = document.createElement("div");

    const input = document.createElement("input");
    input.type = "file";
    input.accept = ".json,.webm,application/json,audio/webm";
    input.multiple = true;
    input.hidden = true;
    input.addEventListener("change", () => {
      void this.load(Array.from(input.files ?? []), onPlay);
      input.value = ""; // allow re-picking the same files
    });

    const button = document.createElement("button");
    button.textContent = "Load take";
    button.title =
      "Replay a saved take exactly as it was shown. Pick the take's .json AND its .webm together; the .json alone replays silently.";
    // Same plain-object styling discipline as record_control.ts (copying a
    // live CSSStyleDeclaration throws under strict mode).
    Object.assign(button.style, {
      font: "inherit",
      color: "#e5e7eb",
      background: "rgba(17,24,39,0.75)",
      border: "1px solid rgba(148,163,184,0.4)",
      borderRadius: "4px",
      padding: "4px 8px",
      cursor: "pointer",
    });
    button.addEventListener("click", () => input.click());

    this.status = document.createElement("span");
    this.status.style.opacity = "0.6";

    wrap.append(this.status, button, input);
    mountInDock(wrap);
    wrap.style.flexDirection = "row";
    wrap.style.alignItems = "center";
  }

  private async load(files: File[], onPlay: PlayCb): Promise<void> {
    const json = files.find(
      (f) => f.name.endsWith(".json") || f.type === "application/json",
    );
    const webm = files.find(
      (f) => f.name.endsWith(".webm") || f.type.startsWith("audio/"),
    );
    if (!json) {
      this.say("pick the take's .json");
      return;
    }

    let session: {
      name?: string;
      audio_offset_ms?: number;
      reveals?: { at_ms?: number; url?: string; prompt?: string }[];
    };
    try {
      session = JSON.parse(await json.text());
    } catch {
      this.say("not a take: unreadable JSON");
      return;
    }

    const reveals = Array.isArray(session.reveals) ? session.reveals : [];
    const frames = reveals
      .filter(
        (r) => typeof r?.at_ms === "number" && typeof r?.url === "string",
      )
      .map((r) => ({
        at_ms: r.at_ms as number,
        url: r.url as string,
        prompt: r.prompt ?? "",
      }));
    if (frames.length === 0) {
      // Log-derived sessions (tests/sessions/*) have events but no reveals —
      // those replay through the pipeline, not here.
      this.say("no reveals in this file — replay it with mix sinestesia.replay");
      return;
    }

    // at_ms 0 is the first EVENT; the audio starts earlier, at mic start —
    // shift the frames onto the audio clock when there is one.
    if (webm) {
      const offset = session.audio_offset_ms ?? 0;
      for (const f of frames) f.at_ms += offset;
    }

    if (this.lastAudioUrl) URL.revokeObjectURL(this.lastAudioUrl);
    this.lastAudioUrl = webm ? URL.createObjectURL(webm) : null;

    this.say(webm ? "" : "no .webm picked — silent replay");
    onPlay({
      name: session.name ?? json.name.replace(/\.json$/, ""),
      frames,
      audioUrl: this.lastAudioUrl,
    });
  }

  private say(msg: string): void {
    this.status.textContent = msg;
  }
}
