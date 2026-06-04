# Sinestesia

Live AI VJ — listens to a singer (3 parallel rails) and paints the stage in real time.

## Architecture

```
🎤 Mic
 │
 ├── Trilho 1 (<50ms) ── Web Audio FFT/RMS ──► Three.js shader uniforms
 │      "movement"
 │
 ├── Trilho 2 (~400ms) ── Deepgram Nova-3 stream ──► lyrics ──┐
 │      "words"                                               ├─► Claude Haiku
 │                                                            │   ── prompt
 └── Trilho 3 (~300ms) ── Essentia.js ──► emotion/timbre ─────┘
        "expression"                                          │
                                                              ▼
                                                       fal.ai Flux Schnell
                                                              │
                                                              ▼
                                                      crossfade on screen
```

## Stack

- **Backend**: Elixir + Bandit + Mint.WebSocket
- **Frontend**: Vite + TypeScript + Three.js + Essentia.js
- **Local model**: Gemma 4 12B (MLX) via Ollama — runs the Director prompt builder locally
- **APIs**: Deepgram Nova-3 (STT), fal.ai Flux Schnell (image gen); Anthropic Haiku as optional fallback

## Setup

```bash
cp .env.example .env
# fill in DEEPGRAM_API_KEY, FAL_API_KEY (and optionally ANTHROPIC_API_KEY)

# Ollama with Gemma 4 12B (local Director)
ollama serve &
ollama pull gemma4:12b-mlx

# Backend
cd backend
mix deps.get
mix run --no-halt

# Frontend (new terminal)
cd frontend
bun install
bun run dev
```

Open `http://localhost:5173` in Chrome. Allow mic. Sing.

## Project structure

```
backend/                Elixir orchestrator
  lib/sinestesia/
    application.ex      Supervisor
    router.ex           HTTP + WebSocket mount
    audio_socket.ex     Browser <-> backend channel
    pipeline.ex         Per-session GenServer
    deepgram.ex         STT streaming client
    director.ex         Claude Haiku prompt builder
    image_gen.ex        fal.ai Flux Schnell

frontend/               Vite + Three.js
  src/
    main.ts             Entry
    socket.ts           WebSocket client
    audio/
      capture.ts        getUserMedia + PCM downsampling
      features.ts       Web Audio FFT (Trilho 1)
      expressive.ts     Essentia.js (Trilho 3)
    render/
      scene.ts          Three.js setup
      shaders/          GLSL
```
