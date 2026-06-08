// Entry point: bootstrap audio capture + analysis + socket + render, wire them
// together. Everything starts on a user gesture (the start gate) because
// browsers won't unlock AudioContext otherwise.

import { Capture } from "./audio/capture";
import { FastFeatures } from "./audio/features";
import { ExpressiveAnalyzer } from "./audio/expressive";
import { Socket } from "./socket";
import { Scene } from "./render/scene";
import { DebugOverlay } from "./debug";
import { StyleControl } from "./style";
import { MicPanel } from "./mic";
import { loadSequences, frameUrl, type SampleSequence } from "./samples";

const params = new URLSearchParams(location.search);
const MOCK = params.has("mock");
const DEBUG = params.has("debug");
const CLEAN = params.has("clean"); // hide rehearsal chrome for a clean stage demo
const DEMO = params.get("demo"); // sample sequence slug (or "" for the default)

const MIC_KEY = "sinestesia.micDeviceId"; // last-used mic, persisted across reloads
const STYLE_KEY = "sinestesia.style"; // last-used visual style, persisted across reloads

const debug = DEBUG ? new DebugOverlay() : null;

// Hard-coded sample images for ?mock=1 development without the backend.
const MOCK_IMAGES = [
  "https://picsum.photos/seed/tarsila/1280/720",
  "https://picsum.photos/seed/volpi/1280/720",
  "https://picsum.photos/seed/djanira/1280/720",
];

const canvas = document.getElementById("scene") as HTMLCanvasElement;
const gate = document.getElementById("gate") as HTMLDivElement;
const startBtn = document.getElementById("start") as HTMLButtonElement;

const scene = new Scene(canvas);

// Render loop runs immediately so the placeholder + (mock) images are visible
// even before the mic is unlocked.
let fast: FastFeatures | null = null;
let mic: MicPanel | null = null;
// When a sample sequence is playing, this advances the continuous morph each
// frame (see playDemo). Null on the live path.
let demoUpdate: (() => void) | null = null;
function frame() {
  if (fast) {
    fast.update();
    const u = fast.currentUniforms();
    scene.setFast(u);
    debug?.setAudio(u.rms, u.centroid, u.onset);
    mic?.setLevel(u.rms);
  }
  demoUpdate?.();
  scene.render();
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

// ---- Sample-sequence playback (dev) ----
// Replays the pre-generated accumulative sequences into the scene to iterate
// the transition shader without a mic or backend. Driven by ?demo=<slug> and/or
// the picker in the debug overlay. Works on page load — no audio needed.
//
// Playback is a single continuous timeline over preloaded textures rather than
// discrete "transition then settle" steps: a global phase advances forever and
// the morph chains frame→frame with no pause. Seconds the front takes to sweep
// one accumulation step — bigger = slower, more deliberate morph.
const DEMO_SEGMENT_MS = 5500;

let sampleSeqs: SampleSequence[] = [];
let demoGen = 0; // invalidates a sequence whose textures are still preloading

async function ensureSequences(): Promise<SampleSequence[]> {
  if (sampleSeqs.length === 0) sampleSeqs = await loadSequences();
  return sampleSeqs;
}

async function playDemo(slug: string) {
  const gen = ++demoGen;
  demoUpdate = null; // freeze current playback while we resolve the new one

  let seqs: SampleSequence[];
  try {
    seqs = await ensureSequences();
  } catch (err) {
    console.warn("[demo] failed to load /samples/index.json:", err);
    return;
  }
  const seq = seqs.find((s) => s.slug === slug) ?? seqs[0];
  if (!seq) {
    console.warn("[demo] no sample sequences available");
    return;
  }
  if (seq.slug !== slug) {
    console.warn(
      `[demo] unknown sequence "${slug}" — playing "${seq.slug}". Available:`,
      seqs.map((s) => s.slug).join(", "),
    );
  }

  const texes = await scene
    .preload(seq.frames.map(frameUrl))
    .catch((err) => {
      console.warn(`[demo] failed to preload "${seq.slug}":`, err);
      return null;
    });
  if (!texes) return;
  if (gen !== demoGen) return; // a newer pick superseded us mid-load

  const n = texes.length;
  const start = performance.now();
  let shown = -1;
  console.log(
    `[demo] "${seq.slug}" — ${n} frames, continuous morph @ ${DEMO_SEGMENT_MS}ms/step`,
  );
  demoUpdate = () => {
    const phase = (performance.now() - start) / DEMO_SEGMENT_MS;
    const i = Math.floor(phase) % n;
    const t = phase - Math.floor(phase); // linear: constant-speed, no per-step easing
    const next = (i + 1) % n;
    scene.setMorph(texes[i], texes[next], t);
    if (next !== shown) {
      debug?.setPrompt(seq.frames[next].prompt);
      shown = next;
    }
  };
}

// Populate the debug picker (click a sequence to replay it in the scene).
if (debug) {
  ensureSequences()
    .then((seqs) => debug!.setSamples(seqs, (slug) => playDemo(slug)))
    .catch((err) => console.warn("[debug] samples unavailable:", err));
}

// ?demo=<slug> auto-plays on load, bypassing the mic gate entirely.
if (DEMO !== null) {
  gate.classList.add("hidden");
  playDemo(DEMO);
}

startBtn.addEventListener("click", () => {
  gate.classList.add("hidden");
  start().catch((err) => {
    console.error("[main] start failed:", err);
  });
});

async function start() {
  // ---- Render-only mock path ----
  if (MOCK) {
    console.log("[main] MOCK mode: no websocket, rotating sample images.");
    let i = 0;
    scene.transitionTo(MOCK_IMAGES[i]);
    setInterval(() => {
      i = (i + 1) % MOCK_IMAGES.length;
      scene.transitionTo(MOCK_IMAGES[i]);
    }, 4000);
  }

  // ---- Audio ----
  const capture = new Capture();
  // Restore the last-used mic across reloads. If that device is gone (unplugged,
  // permissions changed), fall back to the browser default.
  const savedMic = localStorage.getItem(MIC_KEY) ?? undefined;
  try {
    await capture.start(savedMic);
  } catch (err) {
    if (savedMic) {
      console.warn("[main] saved mic unavailable, using default:", err);
      localStorage.removeItem(MIC_KEY);
      await capture.start();
    } else {
      throw err;
    }
  }

  fast = new FastFeatures(capture.ctx);
  capture.tap(fast.node);

  // Mic panel — live level meter + input device picker. Visible during
  // rehearsal so you can confirm capture and switch sources; hidden under
  // ?clean=1. Device labels are only populated after permission is granted.
  if (!CLEAN) {
    mic = new MicPanel((deviceId) => {
      capture
        .switchDevice(deviceId)
        .then(() => localStorage.setItem(MIC_KEY, deviceId))
        .catch((err) => console.error("[main] mic switch failed:", err));
    });
    const refreshDevices = async () => {
      mic?.setDevices(await Capture.inputDevices(), capture.currentDeviceId);
    };
    await refreshDevices();
    // Re-enumerate when devices are plugged/unplugged.
    navigator.mediaDevices.addEventListener("devicechange", refreshDevices);
  }

  const expressive = new ExpressiveAnalyzer();
  expressive.start();

  // ---- Socket (skipped in mock) ----
  const savedStyle = localStorage.getItem(STYLE_KEY) ?? "";
  const socket = MOCK ? null : new Socket();
  if (socket) {
    socket.onImage = ({ url, prompt, timings }) => {
      console.log("[main] image:", prompt, timings ?? "");
      scene.transitionTo(url);
      if (debug) {
        debug.setPrompt(prompt);
        if (timings) debug.addTimings(timings);
      }
    };
    socket.onTranscript = (m) => {
      const tag = `[${m.provider ?? "?"}${m.isFinal ? " FINAL" : ""}]`;
      console.log(tag, m.latencyMs != null ? `+${m.latencyMs}ms` : "", m.text);
      debug?.setTranscript(m);
    };
    socket.onError = (message, provider) => {
      console.warn("[backend error]", provider ?? "", message);
      debug?.setError(message, provider);
    };
    socket.onOpen = () => {
      console.log("[main] websocket connected");
      // Re-apply the persisted style so a reload restores the chosen look.
      // (The backend starts each session on its own default.)
      if (savedStyle) socket.sendStyle(savedStyle);
    };
  }

  // Style control + "nova música" reset — visible during rehearsal, hidden
  // under ?clean=1. Prefilled with the persisted style.
  if (!CLEAN) {
    const style = new StyleControl(
      (value) => {
        if (socket) socket.sendStyle(value);
        else console.log("[mock] would send style:", value);
      },
      () => {
        // New song: clear the canvas immediately, then tell the backend.
        scene.clearImage();
        if (socket) socket.sendReset();
        else console.log("[mock] would send reset (nova música)");
      },
      savedStyle,
    );
    if (socket)
      socket.onStyle = (accepted, source) => {
        style.setAccepted(accepted, source);
        // Persist whatever style is now in effect (user- or curator-picked);
        // a reset clears it so the next reload starts blank again.
        if (source === "reset") localStorage.removeItem(STYLE_KEY);
        else if (accepted) localStorage.setItem(STYLE_KEY, accepted);
      };
  }

  if (socket) socket.connect();

  // ---- Wire audio -> socket + expressive ----
  capture.onChunk((buf) => {
    if (socket) socket.sendAudio(buf);
    else console.log("[mock] would send audio chunk", buf.byteLength, "bytes");
    // Feed the same 16kHz PCM to Rail 3.
    expressive.pushPCM(new Int16Array(buf));
  });

  expressive.onFeatures((f) => {
    if (socket) socket.sendExpressive(f);
    else console.log("[mock] expressive", f.vocal_quality, f);
    scene.setExpressive(f); // Rail 3 also nudges client-side color mood
    debug?.setExpressive(f);
  });

  console.log("[main] audio started. Sing into the mic — the canvas pulses.");
}
