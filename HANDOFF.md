# Sinestesia — Handoff Notes

> Read this first. Then read `README.md` and `PROTOCOL.md`. Then skim the
> code referenced below. This document captures decisions and gotchas that
> are NOT obvious from reading code alone.

## What this project is

Live AI VJ for a Brazilian MPB singer (Daniella Alcarpe) at the Vibe-a-thon
in Lisbon. The system listens to her singing in real time and projects
AI-generated visuals on stage. Target: closing showcase at NFC Summit
(Creative AI track). Demo must run from a single laptop with one mic.

The original vision is **3 parallel rails** (`README.md`):

| Rail | Latency target | Source | Output |
|---|---|---|---|
| 1 — Movement | <50ms | Browser FFT/RMS | Three.js shader uniforms |
| 2 — Words | ~400ms | STT (ElevenLabs/Deepgram) | Director (Gemma) → fal img-gen |
| 3 — Expression | ~300ms | Essentia.js | emotion/timbre features |

**Reality:** Rail 2 is solid and the centerpiece. Rails 1 and 3 are
under-built (see "Open priorities" below).

## Stack

- **Backend**: Elixir 1.17 / OTP 26, Bandit + Plug + WebSockAdapter (no Phoenix), Mint.WebSocket for outbound, Req for HTTP.
- **Frontend**: Vite + TypeScript + Three.js + Essentia.js. **A SEPARATE Claude/Codex agent maintains the frontend** — coordinate via PROTOCOL.md and explicit briefings (do not edit `frontend/` from the backend agent without telling the user).
- **Director (LLM)**: Gemma 4 12B (MLX quantized) via local Ollama. Fallback chain → Gemini 2.5 Flash → Claude Haiku 4.5 (latter two via API if env keys set).
- **Image gen**: fal.ai Flux. Two modes — see "Story mode" below.
- **STT**: ElevenLabs Scribe v2 Realtime (default) or Deepgram Nova-3 or both. Toggle with `STT_PROVIDER`.

## Run it

```bash
# Ollama (one terminal)
ollama serve
ollama pull gemma4:12b-mlx     # if not pulled

# Backend
cd backend && mix run --no-halt

# Frontend (separate)
cd frontend && bun run dev
# Open http://localhost:5173, grant mic
```

`.env` at project root (loaded by `backend/lib/sinestesia/application.ex`). Required: `ELEVENLABS_API_KEY` and `FAL_API_KEY`. Optional fallback keys: `DEEPGRAM_API_KEY`, `GOOGLE_API_KEY`, `ANTHROPIC_API_KEY`.

Env vars that matter:
- `STT_PROVIDER`: `elevenlabs` (default) | `deepgram` | `local_whisper` | `both` (eleven+deepgram) | `eleven_local` | `all`
- `DIRECTOR_PROVIDER`: `gemma` (default) | `gemini` | `haiku`
- `IMAGE_PROVIDER`: `fal` (default) | `local_sdxl` (SDXL Turbo via local-sdxl sidecar) | `google` | `pollinations`
- `LOCAL_SDXL_URL`: `http://127.0.0.1:8003` (default — points at the local-sdxl sidecar)
- `IMAGE_MODE`: `story` (default) | `classic` — see next section
- `ELEVEN_COMMIT`: `vad` (default) | `manual`
- `ELEVEN_VAD_SILENCE`: `0.6` (default) — seconds of silence before VAD commits

## Story mode (the main feature)

The system builds **ONE evolving drawing**, element by element, as the song is sung — inspired by the music video for Toquinho's "Aquarela". Implementation:

1. **Director keeps a multi-turn conversation** with Gemma. Each new lyric line is a new `user` turn. The assistant response describes the FULL CURRENT DRAWING (every element added so far + one new element from this line). See `Sinestesia.Director` → `system_prompt(style, :story)`.
2. **Image gen uses Flux dev img2img**, passing the PREVIOUS image URL as the seed. `strength: 0.8` (user-tuned). Higher strength = less pixel-level continuity, more "fresh re-render". The prompt's accumulative list already enforces semantic continuity. See `Sinestesia.ImageGen.FalImg2Img`.
3. **Bootstrap gate**: the FIRST Director call is delayed until the singer has produced ≥15 cumulative words across all final lyrics. Without this, the first image was generated from 4-5 words and dominated the rest of the song via img2img. `bootstrap_done?` flag in Pipeline state prevents re-entry after style changes. See `pipeline.ex` → `maybe_trigger` and `accumulated_word_count`.

Switch back with `IMAGE_MODE=classic` if you want the old behavior (independent images per line, no accumulation).

## Key files

```
backend/lib/sinestesia/
  application.ex          # Supervisor + config loading
  router.ex               # HTTP + WS mount
  audio_socket.ex         # WebSocket handler (browser ↔ backend)
  pipeline.ex             # ★ Per-session GenServer — orchestrates everything
  director.ex             # ★ Multi-turn LLM wrapper, story/classic modes
  style_curator.ex        # Auto-style picker (DISABLED — see below)
  eleven_stt.ex           # ElevenLabs Scribe streaming client
  deepgram.ex             # Deepgram Nova-3 streaming client
  image_gen.ex            # Dispatcher
  image_gen/
    fal.ex                # Flux Schnell t2i (used when no prev image)
    fal_img2img.ex        # ★ Flux dev img2img (story mode workhorse)
    google.ex
    pollinations.ex
PROTOCOL.md               # ★ Single source of truth for FE↔BE protocol
```

★ = most-touched files. Read these first.

## Recent gotchas (in chronological order)

1. **Multiple zombie pipelines on FE reconnect** → fixed by synchronous `GenServer.stop(old_pid, :shutdown, 1000)` in `Pipeline.start_link` + adoption of existing pid in `AudioSocket.init` on `{:already_started, _}`. See `pipeline.ex:34-50`.
2. **Ollama prefix cache breaks on history cap** → `@max_turns 200` in `director.ex` (effectively no cap for one song). Lower caps caused 3× regressions.
3. **`num_predict: 80` minimum on Gemma** → smaller and the style note gets truncated mid-string (`"Brazilian cordel woodcut print, black"`), which makes Flux miss the style.
4. **ElevenLabs interim accumulates entire song into one string** while Deepgram segments per phrase → `pick_current_line` takes only the last N words from whichever provider updated most recently. `@window_words 10`.
5. **`@window_words` MUST be defined before `maybe_trigger`** in `pipeline.ex`. Elixir module attributes are not hoisted. Forgetting this makes `@window_words` resolve to `nil` with no error.
6. **`accumulated_word_count` counts finals, NOT interims**. ElevenLabs in VAD mode commits + resets the interim after each segment, so an interim alone never grows past one line.
7. **Bootstrap must be a one-shot per session**. Without `bootstrap_done?` flag, every style change reset the conversation and re-armed the bootstrap gate, which would deadlock once the interim was small.
8. **Reset must kill in-flight tasks AND invalidate by session_id**. Killing alone has a race (task message already in mailbox); session_id alone wastes fal.ai $ on dead work. Both belt + suspenders. See `Pipeline.handle_cast(:reset_song, ...)` and the `_sid` pattern matches.
9. **fal.ai Flux dev img2img requires `num_inference_steps >= 10`**. 8 returns HTTP 422. `@steps 10` in `fal_img2img.ex`.
10. **First Gemma call is cold** (~4-6s loading the model). `@gemma_timeout_ms 8_000`. Subsequent calls are ~1s warm.
11. **`sanitize_style` caps at 15 words** (not 5 as originally) so palette entries like `"loose ink sketch on aged paper, sparse hand-drawn linework, sepia tones"` fit. PROTOCOL.md is updated; the frontend was told to remove its 5-word cap.

## Disabled / dead code

- **`Sinestesia.StyleCurator`** — auto-picks a style from a 6-entry hard-coded sketch palette after 5 final lyrics. **Disabled** because it kept overwriting the operator's typed style mid-song. Code lives in `style_curator.ex` and `pipeline.ex` (`spawn_curator`, `maybe_curate_style`). To re-enable: add `|> maybe_curate_style()` back to the `is_final ->` branch in `update_text_state`.

## Open priorities

1. **Trilho 1 in the frontend.** FFT/RMS computed in browser should drive visible shader uniforms (background hue, image opacity, subtle camera shake). This is the FRONTEND agent's job — coordinate via the briefing in the conversation history or write a fresh one.
2. **Trilho 3 in the backend.** `expressive` features are received and stored in `state.expressive` but **not used anywhere**. Two cheap wins: (a) inject vocal mood into the Director's user message (`"[mood: breathy, low arousal] <lyric>"`); (b) modulate `@strength` in img2img by arousal.
3. **Latency**. Currently ~3-3.5s end-to-end (Director ~1.2s, Image ~1.5s) warm. Acceptable for the deliberate "drawing" pace of story mode. If pressed for more, dropping Gemma → Haiku via API would cut ~600ms but adds network/cost.
4. **Visual continuity at high `@strength` (0.8)**. User accepts current quality. Lower (0.4-0.5) would lock pixel-level composition harder but risk the new elements looking squeezed. If the user complains "imagens parecem aleatórias", lower strength before doing anything fancier.

## Don'ts

- Don't add a `mkdir` for the memory dir or check existence — write directly to the path the harness gives you.
- Don't reset Gemma's conversation mid-song unless you also reset `last_image_url` (img2img would chain across topical breaks otherwise).
- Don't increase Director output length without bumping `num_predict` — silent truncation makes Flux miss the style.
- Don't run `Task.start` results back into Pipeline state without checking `sid` first.
- Don't edit `frontend/` files — that's another agent's territory. Briefing instead.
- Don't push PROTOCOL.md changes without telling the user — the frontend agent re-syncs from it.

## How to verify a change end-to-end

```bash
cd backend
mix compile                                   # no errors
mix run /tmp/test_story.exs                   # Director still accumulates (see existing test scripts in /tmp)
# Then mic test in browser at http://localhost:5173
```

Watch the backend log for:
```
[director] +1200ms (N turns): A hand-drawn scene showing ...
[image:fal] +1500ms (total ~3000ms ...)
```

End-of-handoff. Welcome aboard.
