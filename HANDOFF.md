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
- **Frontend**: Vite + TypeScript + Three.js + Essentia.js. Maintained directly in this repo alongside the backend (the old split where a separate agent owned `frontend/` is history). `PROTOCOL.md` is still the FE↔BE contract — update it in the same change as any new message.
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
12. **Glacial 0.18 fps morph stretching bug** → Distributing transition subframe `at_ms` timestamps evenly over the entire segment duration stretches the crossfade across the whole segment. This was fixed by calculating step offsets tightly (e.g., `frame_at_ms = msg.at_ms + (j - 1) * step_dur` with `step_dur` capped at 100ms and floored at 20ms). This ensures transitions complete in ~1.2s and the final frame remains static on screen until the next segment, mirroring the live experience.
13. **JPEG consistency requirement in ffmpeg** → Mixing PNG and JPEG frames inside ffmpeg's concat demuxer causes silent frame-skipping and errors. We implemented a `write_as_jpg` helper in the replay exporter to convert any incoming PNG frames to JPEG via ffmpeg, ensuring all inputs to the demuxer are strictly `.jpg`.
14. **Instrumental intro black canvas padding** → Songs with long instrumental intros (where `first_frame_at_ms > 0`) should show a blank black screen. We automatically query the first frame's resolution via `ffprobe`, generate a matching-resolution `black.jpg` dynamically via `ffmpeg`'s `lavfi` color filter, and prepend it to the concat `input.txt` to cover the intro.
15. **Ffmpeg trailing-frame concat bug** → ffmpeg's concat demuxer can silently truncate the final frame early if it's the last line in the input file. Resolved by duplicating the last frame entry with a small duration to act as a trailing anchor.
16. **Diagnostic `test_out.mp4` vs `video.mp4`** → The direct CLI test file `test_out.mp4` was a transient diagnostic file created to verify transition-smoothness in isolation (deliberately omitting sound and the blank intro). The true, fully compiled asset containing both synchronized audio and the blank instrumental intro is `video.mp4` under `frontend/public/samples/<slug>/video.mp4`.
17. **Director output must be validated, not trusted** → The Director LLM occasionally refuses or asks for clarification ("please provide the first line of the song") instead of emitting a scene. The backend rejects any output that doesn't begin with the canonical scene-opening phrase, so the multi-turn conversation never gets poisoned and meta-commentary never reaches the image model. See `director.ex`.


18. **Predictive look-ahead is a single-slot speculation, not true parallelism** → With `SPECULATIVE_LOOKAHEAD` on and lyrics loaded (`lyrics` WS message, or a session's `lyrics` field in replay), the pipeline renders the *predicted next line* ahead of the singer and HOLDS the frame, revealing it only when STT confirms that line (`PerformanceFollower.match`). There is at most ONE speculation in flight (`state.speculation`), and `maybe_trigger` is blocked whenever it is non-nil — so there is never more than one Director call running at once, same as before. The whole feature is a no-op when the flag is off or no lyrics are loaded: `advance_script` and `maybe_speculate` return early, `speculation` stays nil, and the reactive path is byte-for-byte unchanged. This is why it's safe to ship default-off. See `pipeline.ex` → `maybe_speculate`, `advance_script`, `reveal_speculation`, `discard_speculation`.

19. **A speculation must NOT mutate shared state until it is confirmed** → A speculative Director call runs on a COPY of `director_conversation`; its returned conversation is adopted only in `reveal_speculation`. Likewise `compose_image_request` mutates placement/style bookkeeping (`recent_placements`, `frames_since_style`) — for a speculation those deltas are stashed in `speculation.state_delta` and applied only on reveal, so a mis-predicted (discarded) line leaves no trace: no poisoned conversation, no consumed style-refresh counter, only a wasted (cheap) render. Off-script singing, a skipped verse, or a Director/image error all funnel through `discard_speculation`, which kills the in-flight task and clears the slot, and the reactive path then draws the line she actually sang. Frames are still generated *during* the show and revealed on the real voice, so the mint's "made live" claim stays true.

20. **Musical structure (Phase 2) is derived from lyrics, not audio** → `Sinestesia.MusicalStructure.analyze/1` reads verse/chorus/bridge/outro from the pasted lyrics' **blank-line stanzas** — a stanza whose normalized text repeats is the chorus, occurrence-counted. This needs no online MIR (chroma similarity, beat tracking): the operator already provides the lyrics for look-ahead, and repetition is a much stronger, much cheaper signal than trying to detect "the chorus" acoustically from a single voice with no backing track. Position/section tracking (`current_section`) is INDEPENDENT of `SPECULATIVE_LOOKAHEAD` — it runs off `MUSICAL_STRUCTURE` alone via `track_position/2`, or as a side effect of the look-ahead path's `match_and_advance/2`; either way both funnel through `update_position/2`, which is the only place `current_section` changes and the only place a `structure` WS push fires (on a section boundary). Both flags default off and are independent: look-ahead without structure renders exactly as Phase 1 (no hint text ever appended); structure without look-ahead still tracks position and hints the reactive Director, just without pre-rendering.

21. **The chorus "echo" is a hint, not a literal replay of the old prompt** → `MusicalStructure.hint/1` deliberately does NOT try to inject the FIRST chorus's actual Director output into the return visit's prompt. Story mode's Director already holds the whole multi-turn conversation, so it already remembers what it drew — the hint just says "`[chorus returns (#2) — echo its established imagery]`" and lets the model's own context supply the visual continuity. Simpler, and avoids a second failure mode (a stale anchor phrase fighting the current scene state).

22. **Tempo is an honest best-effort estimate, never a claim** → The browser's `FastFeatures.tempoBpm()` (onset-interval median, octave-folded into 50–200 BPM) and the backend's `Sinestesia.Tempo.smooth/3` (EMA + an 8s staleness window) both return `nil`/`0` far more readily than a number — a solo voice has no drum track, so a wrong-but-confident BPM is worse than "unknown" (CLAUDE.md). `tempo_bpm` only ever reaches the `structure` push (a HUD reading); it is never part of anything provenance- or mint-related. `fast_features`/`sendFastFeatures` existed since before Phase 2 but were never wired end-to-end — the frontend now calls it from the render loop at ~2Hz (`main.ts`), throttled independent of the ~60fps RAF loop.

23. **Deep look-ahead (`LOOKAHEAD_DEPTH`, Phase 3) is a SEPARATE background chain, additive to the speculation slot — never a replacement for it** → `state.prerender` (one background render at a time — img2img is inherently sequential, chaining off the previous frame, so this can never fan out) plus `state.prerendered` (a cache of finished-but-unrevealed frames, keyed by script line index). `speculate_next/1` — the same function Phase 1 already called after every reveal — checks the cache FIRST; a hit is promoted straight into `state.speculation`, skipping the render entirely. `maybe_deepen_lookahead/1` is a hard no-op at the default `LOOKAHEAD_DEPTH=1` (checked first, before anything else), which is why depth=1 reproduces Phase 1/2 exactly — verified by the full pre-Phase-3 test suite passing unmodified. See `pipeline.ex` → `maybe_deepen_lookahead`, `lookahead_frontier`, `start_prerender`, `speculate_next`.

24. **The chain-vs-confirmation race: don't spawn a duplicate render for a line the chain is already working on** → First cut of this feature had a real bug, caught by live replay verification (not by the hermetic tests, which is itself worth remembering): if the singer confirms a line while the deep-lookahead chain is still rendering EXACTLY that line (started it, but hasn't finished), `speculate_next/1`'s cache lookup misses (the render isn't DONE yet, so it's not in `prerendered`) and — before the fix — fell through to spawning a second, completely independent Director/image call for the same line, wasting a render and racing two results against each other. Fixed with a `:pending_prerender` placeholder: when `speculate_next/1` finds `state.prerender.index == next` (in flight, not yet cached), it installs a marker in `state.speculation` instead of spawning — `match_and_advance/2` needs no special case, since its existing generic "matches, not ready yet" clause already handles marking it `confirmed: true`. When the chain's own render finishes (`prerender_image_done`), it checks for exactly this placeholder and promotes+reveals directly (immediately, if already confirmed) instead of caching it. `prerender_director_done`/`prerender_image_done`'s error clauses also clear a stuck placeholder (`recover_from_prerender_failure/2`) and re-trigger `maybe_speculate/1`, so a failure mid-chain can't leave the pipeline stuck waiting for a promotion that will never come. **Takeaway: for any future look-ahead-style feature, verify with a LIVE run, not just hermetic message-injection tests — hermetic tests only exercise the sequences you thought to write, and this exact race only showed up because a real render was slow enough to still be in flight when a real confirmation arrived.**

25. **Deep look-ahead's provenance framing is an open question — do not silently resolve it in code** → Phase 1 could honestly say every shown frame was rendered within seconds of being confirmed sung. Deep look-ahead can legitimately pre-render several lines before they're sung, given enough lead time (e.g. lyrics loaded during a sound-check). The reveal gate is untouched — nothing is EVER shown before it's actually sung — and the per-prompt provenance record still captures exactly when each frame was generated, so the certificate stays accurate either way. What changes is the fair NARRATIVE description of "how live" a deep-lookahead show is. That's the founder's call (README wording, pitch materials, how the certificate is presented), not something to resolve by picking a default — `LOOKAHEAD_DEPTH` defaults to `1` (Phase 1's original meaning) precisely so this question stays open until he decides.

26. **The opening frame can ALSO be eager, not just reactive — but only once the whole song is known** → Found by the founder testing live: loading lyrics did nothing until real singing had already produced the reactive bootstrap's 15 words, because `maybe_speculate`/`maybe_deepen_lookahead` both require `bootstrap_done?` — there was no canvas yet to seed anything from. Fixed with a THIRD parallel chain, `state.bootstrap_speculation`: `maybe_speculate_bootstrap/1` fires the moment lyrics load (from `load_lyrics`, `reset_song`/`end_song` when lyrics persist), rendering the opening from the SCRIPT's own first ~30 words (t2i, no seed — same shape as the reactive bootstrap), and holds it. `maybe_trigger`'s bootstrap branch checks it before ever firing a reactive call: ready → reveal immediately; still rendering → mark `confirmed: true` and wait for its own completion (never fires a second, competing reactive Director call). On reveal, `PerformanceFollower.furthest_match/4` (new — deliberately different from `match/4`, which prefers the NEAREST candidate for a single just-sung line; this needs the FURTHEST line covered by everything sung so far, since the eager render may span several short lines) catches `script_cursor` up to reality before ordinary per-line look-ahead continues. Verified live: fires ~3ms after lyrics load, well before any singing; reveals within ~1s of real singing crossing the threshold. See `pipeline.ex` → `maybe_speculate_bootstrap`, `reveal_bootstrap_speculation`, `catch_up_position_from_accumulated`.

27. **A lyrics reload needs its OWN staleness guard — `session_id` alone doesn't cover it** → Reloading lyrics mid-song discards + re-arms the eager bootstrap WITHOUT bumping `session_id` (that's reserved for a whole new performance, via `reset_song_state`). So if `Process.exit(pid, :kill)` loses the race against an already-in-flight `send` from the just-discarded attempt, `sid == cur` would still match and a stale result could slip through as if it belonged to the fresh attempt. Fixed with `bootstrap_generation`, a counter bumped every time a fresh eager-bootstrap render actually starts, carried in its messages and checked alongside `sid`. Caught while writing the hermetic tests for gotcha #26, not live — a good reminder that "the same bug class as something already fixed elsewhere" is worth checking for explicitly, not just trusting the existing guard generalizes.

28. **A synthetic Director-done message still spawns a REAL image task — hermetic tests must account for that or become flaky** → Every one of the three look-ahead chains (`speculation`, `prerender`, `bootstrap_speculation`) spawns the actual image-generation Task as a normal side effect of processing a *director*-done success — faking the Director's response doesn't fake the image call downstream of it. A test that injects a synthetic director-done success and THEN injects its own synthetic image-done for the same slot is racing against that real (if fast-failing, e.g. `:no_fal_key`) background call, and whichever lands first differs by run. Fixed by seeding `pipeline_bootstrap_test.exs`'s scenarios directly at whatever status each test needs via `:sys.replace_state`, rather than driving them through the real director-done handler when a later synthetic image-done also needs to land deterministically.

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
- Don't change a `frontend/`↔`backend/` message shape without updating `PROTOCOL.md` in the same change — it's the single source of truth for the contract.

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
