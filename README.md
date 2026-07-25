# Sinestesia

**Live AI VJ that listens to a singer and draws the stage in real time.**

> **ETHGlobal Lisbon 2026 — Track 02, Extend Open Source.**
> This repo predates the event (first commit 2026-06-04). Everything built
> during the hackathon is in one branch, so the diff is auditable in one click:
> **[`main...feat/hackathon`](https://github.com/danicuki/sinestesia/compare/main...feat/hackathon)**
>
> The feature: the finished painting is minted on **Sui** (artwork on **Walrus**)
> with provenance proving it was made live, and the AI director runs on
> **0G Compute** as TEE-sealed verifiable inference.
> Live claim app: <https://sinestesia-mint.vercel.app>
> Plan and process: [`SUBMISSION.md`](SUBMISSION.md) · [`HACKATHON.md`](HACKATHON.md) · [`DEMO_RUNBOOK.md`](DEMO_RUNBOOK.md)

The visuals don't cut between unrelated images. They accumulate. As the song unfolds, one hand-drawn scene grows on screen — a sun, a castle, a glove, an umbrella — each new element added without erasing what came before. Like the music video for Toquinho's *Aquarela*, but generated live from whatever is being sung.

## 🎬 Watch the live demo

> **[▶ Watch on YouTube](https://www.youtube.com/watch?v=c_ZsERk0Al8)** — Daniella Alcarpe singing on stage in Lisbon, visuals generated live by Sinestesia on the back wall.

[![Sinestesia live demo at NFC Summit Lisbon](https://img.youtube.com/vi/c_ZsERk0Al8/maxresdefault.jpg)](https://www.youtube.com/watch?v=c_ZsERk0Al8)

Built in 24h at the Vibe-a-thon hackathon in Lisbon (Creative AI track, NFC Summit).

## How it works

Three parallel rails listen to the mic. Each runs at a different latency budget and feeds a different visual layer.

```
🎤 Mic
 │
 ├── Rail 1 ── Web Audio FFT/RMS ─────────► Three.js shader uniforms       (<50ms)
 │   "movement"                              (background pulse, brightness, hue)
 │
 ├── Rail 2 ── STT (ElevenLabs / Deepgram) ──► Director (Gemma 12B local)  (~2s)
 │   "words"                                  └─► fal.ai Flux img2img
 │                                                ├─► previous image
 │                                                └─► accumulated prompt
 │                                                    │
 │                                                    ▼
 │                                              crossfade on screen        (~3-4s total)
 │
 └── Rail 3 ── Essentia.js ──► emotion/timbre features ──► (modulates Director prompts)
     "expression"                                          (mood, arousal, valence)
```

The key trick is **accumulative image-to-image**. Every new lyric line is appended to a running multi-turn conversation with Gemma. Gemma's response is a full prompt describing the *entire current drawing* including every element added so far. That prompt is fed to Flux dev img2img with the **previous image as the input**, so Flux is gently nudging an existing canvas rather than generating from scratch. The visual identity persists across the whole song.

A few details that took the most iteration:

- **Bootstrap gate.** The first image dominates the rest of the song via img2img conditioning, so we wait until the singer has produced 15+ words before firing the first Director call. Less and the opening drawing is anemic.
- **Multi-turn caching.** Capping the LLM conversation history at any fixed window invalidates Ollama's prefix cache and triples latency. We just don't cap inside a single song.
- **Output validation.** Gemma occasionally refuses or asks for clarification ("please provide the first line of the song"). The backend rejects any Director output that doesn't begin with the canonical scene-opening phrase, so the conversation never gets poisoned and meta-commentary never reaches Flux.
- **Session invalidation on song-change.** Hitting "new song" kills every in-flight Task (Director, image gen, curator) so we stop paying fal.ai for the old song's frames mid-flight, and bumps a `session_id` to discard any results already in the mailbox. Belt and suspenders.

## Stack

- **Director (the LLM that decides what to draw)**: **Gemma 4 12B (MLX) running locally via Ollama**. This was the call — sovereign, on-device AI in the critical path of a live performance, no cloud round-trip. Fallback chain to Gemini 2.5 Flash and Claude Haiku 4.5 if the local model fails.
- **STT**: ElevenLabs Scribe v2 Realtime as primary, Deepgram Nova-3 as A/B alternative. Toggle with `STT_PROVIDER`. Multilingual — handles Portuguese, English, anything Daniella throws at it.
- **Image gen**: fal.ai Flux dev (img2img, 10-step) for the accumulating canvas; Flux Schnell for the first frame.
- **Backend**: Elixir/OTP. Bandit + Plug + WebSockAdapter (no Phoenix). Mint.WebSocket for outbound streaming clients. Per-session GenServer orchestrates the rails.
- **Frontend**: Vite + TypeScript + Three.js + Essentia.js.

## Why Elixir?

Three streaming clients (browser PCM, ElevenLabs STT, Deepgram STT) and three async pipelines (Director task, image gen task, style curator task) per session. Each rail needs independent supervision, backpressure, and clean session reset. OTP is the right tool — `Task.start` per rail, MapSet of in-flight PIDs in state, `Process.exit(pid, :kill)` on reset to stop paying for old work. The whole orchestrator is one ~600-line GenServer.

## Run it locally

```bash
# 1. Local Director (Gemma via Ollama)
ollama serve &
ollama pull gemma4:12b-mlx

# 2. Env vars
cp .env.example .env
# fill in ELEVENLABS_API_KEY and FAL_API_KEY (others optional)

# 3. Backend
cd backend && mix deps.get && mix run --no-halt

# 4. Frontend (separate terminal)
cd frontend && bun install && bun run dev

# 5. Open http://localhost:5173 in Chrome, allow mic, sing.
```

The `.env` lives at project root and is loaded by `Sinestesia.Application`.

### 🎬 Headless Replay & Video Compilation

You can headlessly replay any recorded session JSON (located under `tests/sessions/`) through the full pipeline (including Director and Image Generation) to export a finished sequence and compile a fully synchronized MP4 video:

```bash
# Replay a session at 20x speed to fetch and generate frames rapidly
REPLAY_SPEED=20 mix sinestesia.replay ../tests/sessions/jorge-vercilo---homem-aranha.json --slug homem-aranha
```

The task automatically exports all generated frames and updates `frontend/public/samples/index.json`.

* **Interactive Audio Sync**: Loading `http://localhost:5173/?demo=homem-aranha` in your browser displays a gorgeous custom glassmorphic audio player at the bottom, keeping the Three.js WebGL crossfade transitions in perfect lockstep with the song's playhead during playback and scrub.
* **Synchronized MP4 Video**: The task automatically compiles a high-compatibility H.264 & AAC video (`video.mp4` under the sample directory) using `ffmpeg`. If a song begins with a long instrumental introduction (e.g. 41s), the video starts with a matching-resolution blank black canvas, followed by rapid, beautiful stop-motion synthetic crossfades (100ms per step) to align perfectly with the song's real timeline.


### ⚙️ System Configuration

Sinestesia is highly configurable, supporting both cloud-bound and 100% offline local AI stacks. Configuration is managed via the `.env` file at the root of the project.

> [!TIP]
> For a complete, in-depth guide to all **40+ active environment variables**, deep-dive hyperparameters, VRAM tuning, and hardware suggestions, see the **[CONFIGURATION.md](file:///Users/danicuki/dev/vibeton/CONFIGURATION.md)** reference guide.

Here are the primary variables you will want to toggle most frequently:

| Environment Variable | Default | Options / Profiles | Description |
| :--- | :--- | :--- | :--- |
| **`STT_PROVIDER`** | `elevenlabs` | `elevenlabs` \| `deepgram` \| `both` \| `local_whisper` | Speech-to-text service used to transcribe real-time vocals. |
| **`DIRECTOR_PROVIDER`** | `gemma` | `gemma` (local) \| `gemini` (cloud) \| `haiku` (cloud) | LLM dispatcher that compiles the accumulative scene description. |
| **`IMAGE_PROVIDER`** | `fal` | `fal` (cloud Flux) \| `local_sdxl` \| `google` \| `cloudflare` | Image-to-image generator that renders the stage canvas. |
| **`IMAGE_MODE`** | `story` | `story` (accumulative canvas) \| `classic` (independent frames) | If `story`, drawings morph and accumulate lyric elements sequentially. |
| **`COMPOSE_MODE`** | `inpaint` | `inpaint` (grid-based ellipse) \| `global` (full re-denoise) | `inpaint` soft-masks elements to guarantee legibility & scene continuity. |


## Repo layout

```
backend/                       Elixir orchestrator (no Phoenix)
  lib/sinestesia/
    application.ex             Supervisor + config
    router.ex                  HTTP + WS mount
    audio_socket.ex            Browser ↔ backend WS handler
    pipeline.ex                ★ Per-session GenServer — the brain
    director.ex                ★ Multi-turn LLM wrapper, story/classic modes
    eleven_stt.ex              ElevenLabs Scribe v2 streaming client
    deepgram.ex                Deepgram Nova-3 streaming client
    image_gen/
      fal.ex                   Flux Schnell text-to-image
      fal_img2img.ex           ★ Flux dev img2img — the workhorse
    style_curator.ex           Auto-style picker (currently disabled)

frontend/                      Vite + TypeScript + Three.js
  src/
    main.ts                    Entry
    socket.ts                  WebSocket client
    audio/
      capture.ts               getUserMedia + PCM downsampling
      features.ts              Web Audio FFT (Rail 1)
      expressive.ts            Essentia.js (Rail 3)
    render/
      scene.ts                 Three.js setup
      shaders/                 GLSL

PROTOCOL.md                    Single source of truth for the WS contract
HANDOFF.md                     Decisions, gotchas, and how to onboard a new contributor
DEMO.md                        Hackathon submission writeup
```

★ = where most of the design lives. Read these first.

## Caveats (this was built in 24h)

- The auto-style curator (a small LLM that picks a sketch style from a palette based on the song's mood) is **disabled in main** — it kept stomping on the operator's manual style choice mid-song. Code is still there (`style_curator.ex`); re-enable by uncommenting one line in `pipeline.ex`.
- Rail 3 (expressive features from Essentia.js) reaches the backend but isn't yet wired into the Director prompt. Next on the list.
- Rail 1 visual reactivity in the frontend is minimal — there's headroom to make the background dance harder with FFT energy.
- Sessions are singletons per backend. Reconnecting the browser tears down the previous Pipeline synchronously before starting a new one (with a hard-kill fallback if it doesn't release in 4s). Multi-singer support would need a Registry change.

## Credits

**Daniella Alcarpe** — vocals, concept, the reason this exists.
**danicuki** — backend engineering, on-stage operator.

Built at the [Vibe-a-thon](https://vibeathon.eu/) in Lisbon, June 2026.

## License

MIT. PRs welcome — especially anything that pushes Rails 1 and 3 further.
