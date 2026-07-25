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
import { AudioPlayerUI } from "./audio_player";
import { VerifyBadge } from "./verify_badge";
import { MintOverlay } from "./mint_overlay";

const params = new URLSearchParams(location.search);
const MOCK = params.has("mock");
const DEBUG = params.has("debug");
const CLEAN = params.has("clean"); // hide rehearsal chrome for a clean stage demo
const DEMO = params.get("demo"); // sample sequence slug (or "" for the default)

const MIC_KEY = "sinestesia.micDeviceId"; // last-used mic, persisted across reloads
const STYLE_KEY = "sinestesia.style"; // last-used visual style, persisted across reloads

const debug = DEBUG ? new DebugOverlay() : null;

// Live "verifiable AI" proof badge — shown on the projection (including clean
// mode) whenever the Director runs on 0G Compute. Opt out with ?no-verify.
const verifyBadge = params.has("no-verify") ? null : new VerifyBadge();

// The song-end mint moment: QR overlay to claim a print of the finished canvas.
const mintOverlay = new MintOverlay();

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
    mic?.setPitch(fast.pitchHz());
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
let activePlayer: AudioPlayerUI | null = null;

async function ensureSequences(): Promise<SampleSequence[]> {
  if (sampleSeqs.length === 0) sampleSeqs = await loadSequences();
  return sampleSeqs;
}

async function playDemo(slug: string) {
  const gen = ++demoGen;
  demoUpdate = null; // freeze current playback while we resolve the new one

  if (activePlayer) {
    activePlayer.destroy();
    activePlayer = null;
  }

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
  let shown = -1;

  debug?.setSampleParams(seq.params);

  if (seq.audio) {
    console.log(`[demo] "${seq.slug}" — ${n} frames, synchronizing with audio: /samples/${seq.audio}`);
    
    // Sort frames by at_ms to ensure monotonic timeline search
    const sortedFrames = [...seq.frames].sort((a, b) => (a.at_ms ?? 0) - (b.at_ms ?? 0));

    activePlayer = new AudioPlayerUI(`/samples/${seq.audio}`, (timeMs) => {
      // Manual trigger on playhead updates for instant visual sync
    });

    demoUpdate = () => {
      if (!activePlayer) return;
      const timeMs = activePlayer.currentTimeMs;

      if (sortedFrames.length === 0) return;

      // Handle musical introduction: before first singing event, keep canvas black
      const firstFrameAt = sortedFrames[0].at_ms ?? 0;
      if (timeMs < firstFrameAt) {
        scene.setBlack();
        if (shown !== -2) {
          debug?.setPrompt("Musical Introduction — Waiting for vocals…");
          debug?.setSampleLyric("");
          shown = -2;
        }
        return;
      }

      // Locate active frame
      let i = 0;
      while (i < sortedFrames.length - 1 && (sortedFrames[i + 1].at_ms ?? 0) <= timeMs) {
        i++;
      }

      if (i < sortedFrames.length - 1) {
        const fCurrent = sortedFrames[i];
        const fNext = sortedFrames[i + 1];
        const dur = (fNext.at_ms ?? 0) - (fCurrent.at_ms ?? 0);
        const elapsed = timeMs - (fCurrent.at_ms ?? 0);
        const t = dur > 0 ? elapsed / dur : 1.0;

        scene.setMorph(texes[i], texes[i + 1], t);
      } else {
        // Last frame, hold at 100%
        scene.setMorph(texes[i], texes[i], 1.0);
      }

      if (i !== shown) {
        debug?.setPrompt(sortedFrames[i].prompt);
        debug?.setSampleLyric(sortedFrames[i].lyric || "");
        shown = i;
      }
    };

    // Auto-play the player
    activePlayer.play();
  } else {
    // Legacy / fallback timer loop
    const uniqueIdxs = new Set(seq.frames.map((f) => f.idx));
    const m = uniqueIdxs.size;
    const ratio = m > 0 ? n / m : 1;
    const stepDur = DEMO_SEGMENT_MS / ratio;

    const start = performance.now();
    console.log(
      `[demo] "${seq.slug}" — ${n} frames, legacy loop @ ${stepDur.toFixed(0)}ms/step (no audio)`,
    );

    demoUpdate = () => {
      const phase = (performance.now() - start) / stepDur;
      const i = Math.floor(phase) % n;
      const t = phase - Math.floor(phase); // linear: constant-speed, no per-step easing
      const next = (i + 1) % n;
      scene.setMorph(texes[i], texes[next], t);
      if (next !== shown) {
        debug?.setPrompt(seq.frames[next].prompt);
        debug?.setSampleLyric(seq.frames[next].lyric);
        shown = next;
      }
    };
  }
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
    socket.onImage = ({ url, prompt, timings, frames, verification }) => {
      console.log("[main] image:", prompt, timings ?? "", "frames:", frames ?? "none");
      scene.transitionTo(url, frames);
      verifyBadge?.update(verification);
      if (debug) {
        debug.setPrompt(prompt);
        if (timings) debug.addTimings(timings);
      }
    };
    // On-chain settlement landed for a receipt shown as "verifying" — resolve it.
    socket.onVerification = (verification) => {
      console.log("[main] verification resolved:", verification);
      verifyBadge?.update(verification);
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
    socket.onMintStatus = () => mintOverlay.showMinting();
    socket.onMint = (m) => {
      console.log("[main] minted:", m);
      void mintOverlay.showResult(m);
    };
    socket.onMintError = (message) => {
      console.warn("[main] mint error:", message);
      mintOverlay.showError(message);
    };
    socket.onOpen = () => {
      console.log("[main] websocket connected");
      // Re-apply the persisted style so a reload restores the chosen look.
      // (The backend starts each session on its own default.)
      if (savedStyle) socket.sendStyle(savedStyle);
    };

    // Trigger the mint at song's end. Keyboard "m" works even in clean/stage
    // mode (where the rehearsal chrome is hidden); a visible button is added
    // below for rehearsal. Ignore "m" while typing in the style input.
    window.addEventListener("keydown", (e) => {
      if (e.key !== "m" && e.key !== "M") return;
      const t = e.target as HTMLElement | null;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA")) return;
      socket.sendMint();
    });

    if (!CLEAN) {
      const mintBtn = document.createElement("button");
      mintBtn.textContent = "Finish & Mint";
      mintBtn.title = "Store on Walrus + mint on Sui (shortcut: m)";
      mintBtn.style.cssText = [
        "position:fixed",
        "right:16px",
        "bottom:16px",
        "z-index:9998",
        "padding:11px 18px",
        "border-radius:999px",
        "border:1px solid rgba(64,224,138,.5)",
        "background:rgba(64,224,138,.15)",
        "color:#eafff2",
        "font:600 14px/1 ui-sans-serif,system-ui,sans-serif",
        "cursor:pointer",
      ].join(";");
      mintBtn.addEventListener("click", () => socket.sendMint());
      document.body.appendChild(mintBtn);
    }
  }

  // Style control + "nova música" reset — visible during rehearsal, hidden
  // under ?clean=1. Prefilled with the persisted style.
  if (!CLEAN) {
    const style = new StyleControl(
      (value) => {
        // Persist the chosen style right away so a reload restores it even if
        // the backend echo is slow or never arrives.
        if (value) localStorage.setItem(STYLE_KEY, value);
        if (socket) socket.sendStyle(value);
        else console.log("[mock] would send style:", value);
      },
      () => {
        // New song: clear the canvas immediately, then tell the backend. The
        // chosen style is kept across songs, so re-send it so the next song
        // starts in the same look (the backend resets to its default on reset).
        scene.clearImage();
        if (socket) {
          socket.sendReset();
          const keep = style.currentStyle();
          if (keep) socket.sendStyle(keep);
        } else {
          console.log("[mock] would send reset (nova música)");
        }
      },
      savedStyle,
    );
    if (socket)
      socket.onStyle = (accepted, source) => {
        style.setAccepted(accepted, source);
        // Persist the chosen style (user- or curator-picked). The reset echo is
        // ignored so "nova música" keeps the current look across reloads.
        if (source !== "reset" && accepted) {
          localStorage.setItem(STYLE_KEY, accepted);
        }
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

  // Realtime melodic descriptor (contour/register/vibrato/energy) — sent while
  // voiced; the backend folds it into the Director's mood (PROTOCOL.md).
  expressive.onMelody((m) => {
    if (socket) socket.sendMelody(m);
    else console.log("[mock] melody", m);
    debug?.setMelody(m);
  });

  console.log("[main] audio started. Sing into the mic — the canvas pulses.");
}
