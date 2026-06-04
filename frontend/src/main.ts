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

const params = new URLSearchParams(location.search);
const MOCK = params.has("mock");
const DEBUG = params.has("debug");
const CLEAN = params.has("clean"); // hide rehearsal chrome for a clean stage demo

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
function frame() {
  if (fast) {
    fast.update();
    scene.setFast(fast.currentUniforms());
  }
  scene.render();
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

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
    scene.crossfadeTo(MOCK_IMAGES[i]);
    setInterval(() => {
      i = (i + 1) % MOCK_IMAGES.length;
      scene.crossfadeTo(MOCK_IMAGES[i]);
    }, 4000);
  }

  // ---- Audio ----
  const capture = new Capture();
  await capture.start();

  fast = new FastFeatures(capture.ctx);
  capture.tap(fast.node);

  const expressive = new ExpressiveAnalyzer();
  expressive.start();

  // ---- Socket (skipped in mock) ----
  const socket = MOCK ? null : new Socket();
  if (socket) {
    socket.onImage = ({ url, prompt, timings }) => {
      console.log("[main] image:", prompt, timings ?? "");
      scene.crossfadeTo(url);
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
    socket.onOpen = () => console.log("[main] websocket connected");
  }

  // Style control — visible during rehearsal, hidden under ?clean=1.
  if (!CLEAN) {
    const style = new StyleControl((value) => {
      if (socket) socket.sendStyle(value);
      else console.log("[mock] would send style:", value);
    });
    if (socket) socket.onStyle = (accepted) => style.setAccepted(accepted);
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
  });

  console.log("[main] audio started. Sing into the mic — the canvas pulses.");
}
