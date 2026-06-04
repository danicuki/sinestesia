# Sinestesia — Frontend

Vite + TypeScript + Three.js live VJ surface. Captures the mic, runs two
browser-side audio analyses, ships audio + features to the Elixir backend over
WebSocket, and renders a fullscreen shader scene that crossfades AI images while
pulsing in real time with the voice.

See `../CONTEXT.md` (project), `../PROTOCOL.md` (wire contract), and
`../SCOPE_FRONTEND.md` (this agent's brief).

## Run

```bash
bun install      # or: npm install
bun run dev      # or: npm run dev  -> http://localhost:5173
```

Click **Sinestesia** to unlock the mic (browsers require a user gesture for
`AudioContext`). Grant mic permission and sing — the canvas pulses immediately
(Rail 1) even before the backend is up.

### Mock mode (develop the render without the backend)

```
http://localhost:5173/?mock=1
```

Skips the WebSocket, rotates 3 sample images every 4s, and logs would-be sends
to the console. The mic + Rail 1 pulsing still run.

## Architecture (three rails)

| Rail | File | What |
|---|---|---|
| 1 — Movement | [src/audio/features.ts](src/audio/features.ts) | `AnalyserNode` → FFT(32) + RMS + onset → shader uniforms every frame. No backend round-trip. |
| 2 — Words | handled by backend | We just send PCM; transcripts come back and are logged. |
| 3 — Expression | [src/audio/expressive.ts](src/audio/expressive.ts) + [worker](src/audio/expressive.worker.ts) | Essentia.js (+ DSP fallback) in a Worker → `expressive` features every 500ms. |

### Audio path

`getUserMedia` → [src/audio/capture.ts](src/audio/capture.ts) →
[AudioWorklet downsampler](src/audio/downsampler.worklet.js) (48k→16k mono,
Int16, 250ms chunks) → `Socket.sendAudio()` (binary) **and** fed to Rail 3.

The same `MediaStreamSource` is tapped by the Rail 1 `AnalyserNode`.

### Render

[src/render/scene.ts](src/render/scene.ts): one fullscreen quad,
`ShaderMaterial`. [fragment.glsl](src/render/shaders/fragment.glsl) mixes two
textures by `uCrossfade` and warps/grades them from `uFftBins`, `uRms`,
`uOnset`. `crossfadeTo(url)` eases over 600ms.

### Socket

[src/socket.ts](src/socket.ts): native `WebSocket` to
`ws://localhost:4000/ws/audio`, typed per PROTOCOL.md, exponential-backoff
reconnect (250ms→5s), 5s liveness ping.

## Notes

- **Essentia.js** is excluded from Vite's dep optimizer and loaded at runtime in
  the worker. If its WASM fails to init (e.g. odd venue browser), the worker
  silently falls back to hand-rolled DSP (FFT centroid, spectral flatness,
  autocorrelation pitch salience) — the expressive rail never hard-fails.
- Built/tested with **npm + Node 18** here (Bun wasn't installed on this box);
  `bun run dev` works the same.

## Status

**Working**

- `dev` server boots on :5173; `index.html`, `main.ts`, GLSL, worklet, and the
  expressive worker all serve/transform cleanly. `tsc --noEmit` is clean.
- Start gate → mic unlock → 16kHz Int16 chunks emitted (binary frames) + fed to
  Rail 3.
- Rail 1 live pulsing wired to shader uniforms every frame.
- Rail 3 emits `expressive` features (Essentia + DSP fallback) every ~500ms.
- Socket reconnect/backoff, ping, and inbound `transcript`/`image`/`error`
  handling per PROTOCOL.md. `image` → 600ms crossfade.
- `?mock=1` render-only path.

**Open / to verify at integration**

- End-to-end with the live backend (transcripts + real fal.ai image URLs) —
  needs the backend running on :4000.
- Essentia WASM init verified only via build/serve; confirm in the actual demo
  browser (fallback covers failure either way).
- Image CORS: `crossfadeTo` uses `THREE.TextureLoader`; fal.media URLs must be
  CORS-readable as WebGL textures (they normally are). On failure we keep the
  current texture and log a warning.
