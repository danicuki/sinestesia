# Sinestesia

**Live AI VJ that listens to a singer and paints the stage in real time.**

Built at the Vibe-a-thon (Lisbon) for the Creative AI track. The system turns a Brazilian MPB performance into an evolving hand-drawn scene that grows with every line of the song — like the music video for Toquinho's *Aquarela*, but generated live.

## What it does

A singer takes the stage. The system listens through a single mic and, second by second:

1. **Transcribes the lyrics** in real time (Portuguese, English, any language).
2. **Asks a local LLM** (Gemma 4 12B running on-device) to decide WHAT to draw next — building one continuous, growing illustration.
3. **Generates the next frame** by feeding the previous image back into Flux img2img, so each new element is layered onto the existing drawing instead of resetting.

The result: a single sketch that fills up with the imagery of the song as it's being sung. Sun, castle, glove, umbrella, plane, road to the sea — appearing in the same hand-drawn style as the audience watches.

## Why it's interesting

- **Local-first AI.** The Director (the LLM that decides imagery) runs on a laptop via Ollama with Gemma 4 12B MLX. No cloud round-trip in the critical path. Sovereign AI for a live performance.
- **Accumulative img2img.** Most generative VJ systems flash unrelated images. Sinestesia threads one evolving canvas through the whole song — visual continuity becomes part of the storytelling.
- **Multilingual.** The Director was tuned to handle any language naturally — it pulls visual nouns and ignores the rest.
- **Three parallel rails.** Movement (<50ms FFT to shaders), Words (~400ms STT → Director → image), Expression (~300ms timbre/emotion features). Designed for a live stage where the visuals need to *feel* the voice.

## Stack

- **Backend**: Elixir + Bandit (no Phoenix) — per-session GenServer orchestrating the three rails. Mint.WebSocket for streaming STT clients.
- **Frontend**: Vite + TypeScript + Three.js + Essentia.js.
- **Director**: Gemma 4 12B (MLX) via Ollama, local. Fallback chain to Gemini 2.5 Flash and Claude Haiku 4.5.
- **STT**: ElevenLabs Scribe v2 Realtime (with Deepgram Nova-3 as A/B alternative).
- **Image gen**: fal.ai Flux dev (img2img, low-step), with Flux Schnell for the first frame.

## Live demo video

Showreel (90s): https://youtu.be/BnoYW_fPRuE

https://www.youtube.com/watch?v=c_ZsERk0Al8

Closing showcase at NFC Summit (Creative AI track), Lisbon. Daniella Alcarpe singing — visuals drawn in real time by Sinestesia on the back wall.

## How to run

```bash
# Local Director
ollama serve & ollama pull gemma4:12b-mlx

# Backend (Elixir)
cd backend && mix run --no-halt

# Frontend (Vite)
cd frontend && bun run dev

# Open http://localhost:5173, allow mic, sing.
```

`.env` needs `ELEVENLABS_API_KEY` and `FAL_API_KEY`. See `README.md` for full setup and `PROTOCOL.md` for the WebSocket contract between front and back.

## Team

Daniella Alcarpe (vocals, concept) & Dani Cuki (engineering).
