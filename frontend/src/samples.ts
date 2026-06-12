// Dev-only: replay the pre-generated accumulative image sequences (under
// public/samples/) into the Scene, mimicking the cadence of backend `image`
// messages. Lets us iterate the transition shader without a mic or the backend.

export interface SampleFrame {
  idx: number;
  file: string; // relative to /samples/, e.g. "aquarela/frame_01.jpg"
  prompt: string;
  lyric?: string; // the sung line that produced this frame (newer exports only)
}

export interface SampleSequence {
  slug: string;
  title: string;
  description: string;
  style: string;
  frames: SampleFrame[];
  frame_count: number;
  // Optional recipe of the run (PROTOCOL.md, 2026-06-12): a flat string→string
  // map of knobs (image_provider, render_mode, …). Absent on old/hand-made
  // sequences — treat as undefined.
  params?: Record<string, string>;
}

const SAMPLES_BASE = "/samples";

/** Fetch the list of available sample sequences from /samples/index.json. */
export async function loadSequences(): Promise<SampleSequence[]> {
  const res = await fetch(`${SAMPLES_BASE}/index.json`);
  if (!res.ok) throw new Error(`samples index ${res.status}`);
  const data = await res.json();
  return (data.sequences ?? []) as SampleSequence[];
}

/** Absolute (dev-server) URL for a frame. */
export function frameUrl(frame: SampleFrame): string {
  return `${SAMPLES_BASE}/${frame.file}`;
}
