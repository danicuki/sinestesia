# Scope — Frontend Agent

> You are the **frontend agent**. You own everything under `frontend/`. You must not touch `backend/`. Communicate with the backend only via the contract in `PROTOCOL.md`.

## Your job in one sentence

Build a Vite + TypeScript app that captures the mic, runs two browser-side audio analyses (fast FFT + slower Essentia.js expressive features), sends audio + features to the backend via WebSocket, and renders a fullscreen Three.js scene that crossfades incoming images while pulsing in real time with the voice.

## Reading order

1. `CONTEXT.md` — overall project
2. `PROTOCOL.md` — the wire contract (your inputs and outputs)
3. This file
4. `frontend/README.md` (you create it as you go)

## What lives under `frontend/`

```
frontend/
├── package.json
├── tsconfig.json
├── vite.config.ts
├── index.html
└── src/
    ├── main.ts                 entry: bootstrap audio + render + socket
    ├── socket.ts               WebSocket client (typed by PROTOCOL.md)
    ├── audio/
    │   ├── capture.ts          getUserMedia + AudioWorklet downsampler
    │   ├── features.ts         AnalyserNode → fast features (Trilho 1)
    │   └── expressive.ts       Essentia.js worker (Trilho 3)
    └── render/
        ├── scene.ts            Three.js renderer, fullscreen quad
        └── shaders/
            ├── vertex.glsl
            └── fragment.glsl
```

## Suggested deps (in `package.json`)

```json
{
  "dependencies": {
    "three": "^0.166.0",
    "essentia.js": "^0.1.3"
  },
  "devDependencies": {
    "vite": "^5.4.0",
    "typescript": "^5.5.0",
    "@types/three": "^0.166.0",
    "vite-plugin-glsl": "^1.3.0"
  }
}
```

Use **Bun** to install and run: `bun install`, `bun run dev`. Vite dev server on port 5173.

## Implementation guidance

### `index.html`
- Single full-bleed canvas. Black background. No UI chrome. A small toggle button to start (browsers require a user gesture to start `AudioContext`).

### `main.ts`
- On click → start `AudioContext`, request mic permission, instantiate:
  - `Capture` (getUserMedia + worklet downsampling to 16kHz mono Int16)
  - `FastFeatures` (Web Audio AnalyserNode reading the same MediaStreamSource)
  - `ExpressiveAnalyzer` (Essentia.js in a Worker)
  - `Socket` (WebSocket client)
  - `Scene` (Three.js renderer)
- Wire them:
  - `Capture` emits `Int16Array` chunks of ~250ms → `Socket.sendAudio(buffer)`
  - `FastFeatures` updates `Scene.uniforms` every animation frame (RMS, FFT bins, onset flag)
  - `ExpressiveAnalyzer` emits features every ~500ms → `Socket.sendExpressive(features)`
  - `Socket.onImage(url, prompt)` → `Scene.crossfadeTo(url)`
  - `Socket.onTranscript(text, isFinal)` → log only (no UI in v1)

### `audio/capture.ts`
- `getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false }})` — we want the raw vocal.
- Create `AudioContext({ sampleRate: 48000 })` (browser default; we downsample in the worklet).
- Register an `AudioWorkletProcessor` that:
  - Buffers input `Float32` until it has ~12000 samples (250ms at 48kHz).
  - Downsamples to 16000 Hz (simple decimation by 3 is acceptable v1; an FIR filter is better but optional).
  - Converts to `Int16` (clamp + scale by 32767).
  - Posts the underlying `ArrayBuffer` to the main thread.
- Expose `onChunk(cb: (buf: ArrayBuffer) => void)`.

### `audio/features.ts` — Trilho 1
- One `AnalyserNode` with `fftSize: 1024`, `smoothingTimeConstant: 0.4`.
- Per animation frame:
  - `getByteFrequencyData(arr)` → write into a `Float32Array` uniform of length 32 (downsample by averaging).
  - Compute RMS over time-domain data.
  - Detect onset (RMS jumped > X over last few frames).
- Expose `currentUniforms()` returning `{ fft: Float32Array(32), rms: number, onset: boolean }`.

### `audio/expressive.ts` — Trilho 3
- Run Essentia.js in a Web Worker to avoid blocking the main thread.
- Every ~500ms, feed the last 2s of buffered audio to Essentia and compute:
  - `Loudness`, `SpectralCentroidTime`, `Inharmonicity`, `PitchSalience`.
- Derive `vocal_quality` with a small heuristic:
  - high `inharmonicity` + low `loudness` → `"breathy"`
  - high `loudness` + high `pitch_salience` + high centroid → `"belted"`
  - low `loudness` + clear pitch → `"intimate"`
  - high `loudness` + sustained → `"soaring"`
  - else → `"neutral"`
- Derive `arousal` (≈ loudness blended with centroid) and `valence` (≈ centroid − inharmonicity, normalized to [-1, 1]). These are rough; they only feed the LLM as hints.
- Emit `ExpressiveFeatures` matching `PROTOCOL.md` exactly.

### `render/scene.ts`
- `THREE.WebGLRenderer({ antialias: true })`, fullscreen, devicePixelRatio.
- Orthographic camera, one full-screen `PlaneGeometry` with `ShaderMaterial`.
- Uniforms (initial values in parens):
  ```
  uTime         (0)             seconds since start
  uRms          (0)             0..1, modulates bloom/displacement
  uOnset        (0)             pulses to 1 on onset, decays
  uFftBins      (Float32Array(32))
  uTexCurrent   (null)          current image
  uTexPrev      (null)          previous image
  uCrossfade    (1)             0=prev, 1=current
  ```
- `crossfadeTo(url)`:
  - Load the new image via `THREE.TextureLoader`.
  - Set `uTexPrev = uTexCurrent`, `uTexCurrent = new`.
  - Animate `uCrossfade` from 0 → 1 over 600ms (ease in/out).

### `render/shaders/fragment.glsl`
- Sample both textures; mix by `uCrossfade`.
- Apply post effects driven by uniforms:
  - Sample-position displacement using `uFftBins` (e.g., perturb UV by a function of low/mid/high bands).
  - Brightness/contrast lift on `uOnset`.
  - Color shift via `uRms` (slight saturation pulse).
  - Optional film grain.
- Keep it readable. Comments welcome where the WHY is non-obvious.

### `render/shaders/vertex.glsl`
- Pass-through with `varying vec2 vUv;`.

### `socket.ts`
- Native `WebSocket` to `ws://localhost:4000/ws/audio`.
- Typed message handling per `PROTOCOL.md`.
- `sendAudio(buf: ArrayBuffer)` → `ws.send(buf)` (binary).
- `sendExpressive(f)` and `sendPing()` → JSON text frames.
- Reconnect on close with exponential backoff (250ms → 5s).
- Expose `onTranscript`, `onImage`, `onError` callbacks.

## How to test without the backend

Add a `?mock=1` URL flag that:
- Skips the WebSocket connection.
- Plays a sample image rotation (3 hard-coded URLs) on a timer so you can develop the render.
- Logs would-be sends to console.

## Done when

- `bun run dev` boots, page loads at `http://localhost:5173`.
- Click "Start" → mic permission asked → granted → console shows audio chunks being sent.
- Fullscreen canvas shows a placeholder (a solid color or a starter image).
- Singing into the mic makes the canvas **visibly pulse** in real time (Rail 1 working before backend exists).
- When backend is up: incoming `image` messages crossfade the texture smoothly over ~600ms.
- No console errors during a 60s continuous run.

## Things you must NOT do

- Don't add React, Vue, Svelte, or any UI framework. Plain TS + Three.js.
- Don't add Tailwind or a CSS framework. The page has no chrome.
- Don't add analytics, tracking, error reporting.
- Don't touch `backend/`.
- Don't edit `PROTOCOL.md` without telling the user first.

## When you finish

Update this file with a brief "Status" section noting what works and what's open, so the user / backend agent can read it.

## Status (frontend agent — 2026-06-04)

**Implemented & verified** (`tsc --noEmit` clean, `vite build` green, `vite dev`
boots on :5173 and serves index/main/GLSL/worklet/worker):

- `index.html` start gate (mic needs a user gesture) → full-bleed black canvas.
- `src/audio/capture.ts` + `src/audio/downsampler.worklet.js`: getUserMedia (raw
  vocal, all DSP off) → AudioWorklet decimates 48k→16k mono, Int16, **250ms /
  4000-sample / 8000-byte** chunks per PROTOCOL.md.
- `src/audio/features.ts` (Rail 1): AnalyserNode → FFT(32) + RMS + onset →
  shader uniforms every animation frame. Pulsing works before backend exists.
- `src/audio/expressive.ts` + `expressive.worker.ts` (Rail 3): 2s ring buffer →
  Web Worker every 500ms → `expressive` features exactly matching the protocol
  (spectral_centroid, loudness, inharmonicity, pitch_salience, vocal_quality,
  arousal, valence). **Essentia.js with a pure-DSP fallback** so the rail never
  hard-fails if WASM init misbehaves on the venue laptop.
- `src/socket.ts`: typed WS to `ws://localhost:4000/ws/audio`, binary audio,
  JSON `expressive`/`fast_features`/`ping`, backoff reconnect (250ms→5s), 5s
  ping. Inbound `transcript` (logged), `image` (600ms crossfade), `error`,
  `pong`. Unknown types ignored.
- `src/render/scene.ts` + shaders: fullscreen quad, two-texture crossfade,
  FFT-driven UV warp + RMS saturation/bloom + onset flash + grain + vignette.
- `?mock=1` render-only path (no WS, rotates 3 sample images, logs sends).
- `?debug=1` overlay (`src/debug.ts`): full-width strip along the bottom, small
  monospace, 60% opacity, semi-translucent black (spans the screen so long text
  wraps over fewer vertical lines and covers less of the image). Two columns:
  **left** = last transcript `[provider] +Xms: "texto"` (interim dimmer than
  final) + last Director prompt (takes the slack and wraps); **right** = rolling
  history of the last 5 timing lines `STT | DIR | IMG | TOT ms (provider)`
  color-coded per field, each with a relative `-Xs` timestamp refreshed each
  second (top row = latest cycle, so no separate "current timing" line). Reads the new `provider` /
  `latency_ms` (transcript) and `timings` block (image) from PROTOCOL.md. Socket
  callbacks now pass `TranscriptMsg` / `ImageMsg` objects carrying those fields.
- `src/style.ts` (visual style control): small input top-right (monospace, 70%
  opacity, semi-translucent black, discreet "style" label). Visible during
  rehearsal, hidden under `?clean=1`. Starts **empty** (backend owns the default
  cordel style). On Enter/blur sends `{ type: "style", style }`; the backend echo
  `{ type: "style", style }` is reflected back into the input via `setAccepted`
  (shows the sanitized/capped value). **No client-side cap or rate-limiting** —
  the backend sanitizes and caps (up to 15 words) and no-ops a repeated style; a
  dedup guard on `lastSent` just avoids re-emitting the same value. The echo's
  `source` (`"user"` / `"curator"` / `"reset"`) is passed through; a `"curator"`
  echo mirrors the auto-picked style into the input too. Next to the input sits a
  **"nova música"** button that sends `{ type: "reset" }`; the chosen style is
  **kept across songs** — the backend's `source: "reset"` echo is ignored and the
  current style is re-sent so the new song starts in the same look (only the
  canvas clears). `socket.ts` gained `sendStyle()`, `sendReset()`, an
  `onStyle(style, source)` callback, and a `style` inbound case. The input has a
  **custom dropdown of preset looks** (alphabetically sorted; cordel / charcoal /
  crayon / expressionism / graffiti / ink-sketch / Tarsila / watercolor) that
  opens on focus/click — even when the field already holds a full value — while
  still allowing free text; typing filters the list by substring. (Replaces the
  native `<datalist>`, which hid every option once the field had a value.) The
  active style is **persisted to `localStorage`** (`sinestesia.style`): saved on
  submit, prefilled into the input on load, and re-sent on socket open so a reload
  restores the look. The selected **mic device** is likewise persisted
  (`sinestesia.micDeviceId`) and restored on start with a default fallback if the
  device is gone.
- **Rail 1 (Movement) strengthened** — was computing FFT/RMS/onset and warping
  UVs already; added the three briefing asks: (1) **spectral centroid** computed
  in `features.ts` (magnitude-weighted, normalized 0..1, one-pole smoothed) →
  `uCentroid` → background **hue tint** in the fragment shader (bass = warm,
  treble = cool, via a YIQ hue rotation centered so mid centroid is neutral);
  (2) **RMS → brightness/opacity** (`col *= 0.78 + 0.45*uRms`) on top of the
  existing saturation/bloom; (3) **transient-reactive crossfade** —
  `scene.crossfadeTo` picks its duration from the live onset envelope
  (calm 750ms → hard attack 220ms).
- **Rail 3 → client-side visuals (bonus)** — `scene.setExpressive(f)` feeds
  `uValence`/`uArousal`: positive valence warms + saturates slightly, arousal
  drives image contrast (low = hazy, high = crisp). Expressive still flows to the
  backend unchanged (~2Hz `sendExpressive`).
- **`?debug=1` live meters** — added sections to the overlay: `rail 1 —
  movement` (RMS bar + centroid bar with warm/cool tag + onset flag, repainted
  ~12Hz), `rail 3 — expression` (vocal_quality / arousal / valence / centroid,
  ~2Hz), and `melody → director` (contour / register / vibrato / energy, the
  last hint sent). Verifies the rails are alive at a glance.
- **Mic panel (`src/mic.ts`)** — top-left rehearsal chrome (hidden under
  `?clean=1`): a **live input-level meter** (fast-attack/slow-release RMS bar,
  green→amber→red as it gets hot, with a numeric readout) so you can confirm
  sound is being captured; a **device picker** `<select>` listing audio inputs;
  and a **live pitch "tuner"** (note name + octave, an in-tune needle showing
  ±cents that greens within ±5¢, and the raw Hz). `capture.ts` gained device
  support: `start(deviceId?)`, `switchDevice(deviceId)` (swaps the source +
  re-taps Rail 1 without rebuilding the worklet), `currentDeviceId`, and a
  static `inputDevices()`. The picker hot-swaps the mic mid-session and the list
  re-enumerates on `devicechange`.
- **Live pitch (Rail 1)** — `FastFeatures` now runs a time-domain ACF2+
  autocorrelation (fftSize bumped to 2048) every frame to detect the sung
  fundamental, exposed via `pitchHz()` (0 = unvoiced); it feeds the tuner. Pure
  client-side, no protocol traffic.
- **`melody` FE→BE message** (PROTOCOL.md 2026-06-13) — the Rail-3 worker tracks
  the f0 line across its 2s window (per-hop autocorrelation, median-smoothed to
  drop octave glitches) and condenses it into `{ contour, register, vibrato,
  energy }`: contour from the regression slope / spread / max jump
  (rising/falling/steady/wavering/leaping), register relative to the singer's
  range learned over the session, vibrato from the detrended ~4-8Hz wobble,
  energy from loudness + register reach. Emitted ~2Hz while voiced (null →
  skipped) via `ExpressiveAnalyzer.onMelody` → `Socket.sendMelody`. Fields are
  optional and the message is purely additive; the backend folds it into the
  Director's mood.

**Open / needs integration:**

- End-to-end against the live backend on :4000 (real transcripts + fal.ai image
  URLs). Mock path used so far.
- Confirm Essentia WASM init in the actual demo browser (DSP fallback covers it
  regardless).
- fal.media image URLs must be CORS-readable as WebGL textures (normally fine);
  on load failure we keep the current texture and warn.

**Env notes:** Bun was not installed on this machine, so deps were installed and
the build verified with **npm + Node 18**. `bun install` / `bun run dev` are
unchanged. The expressive worker uses ES module format (`worker.format: "es"` in
`vite.config.ts`) — required because it code-splits essentia.js.
