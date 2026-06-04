# Sinestesia — Project Context

> **READ THIS FIRST.** This document briefs an AI agent who has no prior conversation history.
> The user is at a 24h AI hackathon in Lisbon (Vibe-a-thon, Creative AI track) and needs help building this project. Total available work time: ~10–12h split across two days.

## What we are building

**Sinestesia** — a live AI VJ that listens to a singer (Daniella Alcarpe, Brazilian MPB) and projects AI-generated visuals onto the stage in real time, reacting to her voice. Daniel (the user) accompanies her on acoustic guitar.

The system listens in **three parallel rails**:

| Rail | Latency | What it captures | Implementation |
|---|---|---|---|
| 1 — Movement | <50ms | FFT, RMS, onset, pitch | Web Audio AnalyserNode in browser → Three.js shader uniforms directly |
| 2 — Words | ~400ms | Lyrics (interim + final) | Browser PCM → Elixir → Deepgram Nova-3 streaming WebSocket |
| 3 — Expression | ~300ms | Timbre, valence, arousal, vocal quality | Essentia.js in browser → backend |

Words + Expression feed a **Director LLM** (Claude Haiku 4.5) that emits a rich image prompt. Prompt goes to **fal.ai Flux Schnell**, image URL comes back, browser crossfades into the new texture. Meanwhile Rail 1 keeps modulating shaders in real time.

## Why this architecture

- **Two latency budgets**: Rail 1 (instant, browser-only) makes the visual feel "alive" with the voice. Rails 2 + 3 (slower, semantic) generate new imagery every ~1–2s. Users perceive responsiveness from Rail 1; meaning from Rails 2+3.
- **Specialists, not generalists**: a single multimodal LLM would be slower and less explainable. Composing best-in-class specialists (Deepgram for STT, Essentia for features, Gemma for text reasoning, Flux for images) is faster and more controllable.
- **Sovereign by default**: Director runs locally on Gemma. The only cloud dependencies are STT (Deepgram) and image gen (fal.ai). If the venue Wi-Fi dies mid-demo, Rail 1 (movement) and the Director keep running.
- **Browser does what browser does best** (audio capture, WebGL rendering). **Elixir does what BEAM does best** (concurrent stream orchestration via Phoenix-style channels). No language is forced into a role it's bad at.

## Stack (final, do not re-litigate)

- **Backend**: Elixir 1.17 / OTP 26, **Bandit** HTTP server, **Plug** router, **WebSockAdapter** for browser-facing WS, **Mint.WebSocket** for outbound Deepgram WS, **Req** for HTTP APIs, **Jason** for JSON.
- **Frontend**: **Vite** + **TypeScript**, **Three.js**, **Essentia.js** (WASM).
- **Runtime on dev**: Bun for frontend (`bun install`, `bun run dev`).
- **APIs**: Deepgram Nova-3 (STT streaming), fal.ai Flux Schnell (image gen).
- **Local model**: **Gemma 4 12B (MLX) via Ollama** runs the Director (text-only prompt builder). 100% local on the laptop. Anthropic Claude Haiku 4.5 is kept as a fallback only if Gemma times out.
- **Hardware**: MacBook M4 Max 48GB. Gemma runs on the same machine that serves the demo.

## Aesthetic direction (Daniella's curation)

Brazilian modernism: Tarsila do Amaral, Alfredo Volpi, Djanira da Motta e Silva. Xilogravura nordestina. Marmorized paper textures. Tropicália palettes. The Director LLM is prompted with these anchors to keep generated imagery cohesive across a setlist of ~3 songs (~10 min total).

## Hard constraints

- **Total work budget**: 10–12h. Don't refactor; don't over-abstract.
- **No new languages, no new frameworks** beyond the stack above.
- **No local ML/GPU**. If a step needs ML, it's an API.
- **No databases**. Everything is in-memory / per-session.
- **No auth, no users**. Single demo machine.
- **Code is throwaway-grade**: optimized for a stage demo tomorrow, not for production.

## File layout

```
/Users/danicuki/dev/vibeton/
├── CONTEXT.md           ← this file
├── PROTOCOL.md          ← WebSocket contract (the boundary between the two agents)
├── SCOPE_BACKEND.md     ← what the backend agent owns
├── SCOPE_FRONTEND.md    ← what the frontend agent owns
├── README.md
├── .env.example
├── .gitignore
├── backend/             ← Elixir project (owned by backend agent only)
└── frontend/            ← Vite project (owned by frontend agent only)
```

## How agents collaborate

There are **two AI agents** working in parallel — one per terminal. They communicate **only through the WebSocket protocol** defined in `PROTOCOL.md`. Neither agent should ever edit files in the other's directory.

- **Backend agent**: edits only `backend/**` and updates `SCOPE_BACKEND.md`.
- **Frontend agent**: edits only `frontend/**` and updates `SCOPE_FRONTEND.md`.
- **Shared docs** (`CONTEXT.md`, `PROTOCOL.md`, `README.md`, `.env.example`): treat as **read-only** unless the user explicitly says to edit. If you need to change the protocol, **STOP and tell the user first** — the other agent must be informed.

## Where to start

Read your scope file (`SCOPE_BACKEND.md` or `SCOPE_FRONTEND.md`), then `PROTOCOL.md`, then implement your side end-to-end. Use a mock for the other side until integration.
