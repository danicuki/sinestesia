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

26. **The opening frame can ALSO be eager, not just reactive — but only once the whole song is known** → Found by the founder testing live: loading lyrics did nothing until real singing had already produced the reactive bootstrap's 15 words, because `maybe_speculate`/`maybe_deepen_lookahead` both require `bootstrap_done?` — there was no canvas yet to seed anything from. Fixed with a THIRD parallel chain, `state.bootstrap_speculation`: `maybe_speculate_bootstrap/1` fires the moment lyrics load (from `load_lyrics`, `reset_song`/`end_song` when lyrics persist), rendering the opening from a coherent chunk of the SCRIPT (see gotcha #29 — originally a fixed word window, since redesigned), and holds it. `maybe_trigger`'s bootstrap branch checks it before ever firing a reactive call: ready → reveal immediately; still rendering → mark `confirmed: true` and wait for its own completion (never fires a second, competing reactive Director call). On reveal, `PerformanceFollower.furthest_match/4` (new — deliberately different from `match/4`, which prefers the NEAREST candidate for a single just-sung line; this needs the FURTHEST line covered by everything sung so far, since the eager render may span several short lines) catches `script_cursor` up to reality before ordinary per-line look-ahead continues. Verified live: fires ~3ms after lyrics load, well before any singing. See `pipeline.ex` → `maybe_speculate_bootstrap`, `reveal_bootstrap_speculation`, `catch_up_position_from_accumulated`.

27. **A lyrics reload needs its OWN staleness guard — `session_id` alone doesn't cover it** → Reloading lyrics mid-song discards + re-arms the eager bootstrap WITHOUT bumping `session_id` (that's reserved for a whole new performance, via `reset_song_state`). So if `Process.exit(pid, :kill)` loses the race against an already-in-flight `send` from the just-discarded attempt, `sid == cur` would still match and a stale result could slip through as if it belonged to the fresh attempt. Fixed with `bootstrap_generation`, a counter bumped every time a fresh eager-bootstrap render actually starts, carried in its messages and checked alongside `sid`. Caught while writing the hermetic tests for gotcha #26, not live — a good reminder that "the same bug class as something already fixed elsewhere" is worth checking for explicitly, not just trusting the existing guard generalizes.

28. **A synthetic Director-done message still spawns a REAL image task — hermetic tests must account for that or become flaky** → Every one of the three look-ahead chains (`speculation`, `prerender`, `bootstrap_speculation`) spawns the actual image-generation Task as a normal side effect of processing a *director*-done success — faking the Director's response doesn't fake the image call downstream of it. A test that injects a synthetic director-done success and THEN injects its own synthetic image-done for the same slot is racing against that real (if fast-failing, e.g. `:no_fal_key`) background call, and whichever lands first differs by run. Fixed by seeding `pipeline_bootstrap_test.exs`'s scenarios directly at whatever status each test needs via `:sys.replace_state`, rather than driving them through the real director-done handler when a later synthetic image-done also needs to land deterministically.

29. **`@bootstrap_min_words` (15) is a fine heuristic when the lyrics are UNKNOWN and an arbitrary one the moment they're not** → Founder's observation, and correct: 15 words is roughly tuned for the reactive path (no script), but once the whole song is pasted there's no reason to guess "how much is enough" — the song's own first STANZA already answers that, whatever its natural length turns out to be. `bootstrap_content_and_target/1` now renders the eager bootstrap from `state.structure.sections`'s first entry (already computed at load time from the pasted lyrics' blank-line breaks) instead of a fixed word window, and stores the line it needs real singing to reach (`target_index`) on the `bootstrap_speculation` struct. `bootstrap_target_reached?/1` gates `maybe_trigger`'s reveal on that line being confirmed (via `furthest_match/4`), not on `accumulated_word_count`. An 8-word single-line stanza ("Numa folha qualquer eu desenho um sol amarelo") now reveals after just that line; a 3-line stanza correctly waits for all 3 — verified with both shapes in `pipeline_bootstrap_test.exs`, and live via replay (log shows `"pre-rendering the opening ... (through line 1)"`, matching the pasted song's real 2-line first stanza).
    - **The tell for "no real stanza info was given"**: `MusicalStructure.analyze/1` always collapses a flat list (the legacy `lines:` array, or lyrics with no blank lines at all) into exactly ONE section spanning the whole script — so `length(state.structure.sections) > 1` is the precise signal that real blank-line breaks exist and the first section can be trusted. Otherwise (one section, or none), fall back to a small fixed window (`@bootstrap_fallback_lines`, 2) rather than trusting "the first section" and waiting for the entire song.
    - The REACTIVE (no-script) bootstrap gate is untouched — `@bootstrap_min_words` still applies there, because without a script there's genuinely no structural signal to lean on instead.

30. **A persistent song library, plain JSON files, no database** → `Sinestesia.SongLibrary` stores one song per file in `SONGS_DIR` (default `../songs`, resolved from the backend's own cwd — same convention `tests/sessions/` already uses). Deliberately not a database: the working set is small (an artist's own repertoire, not a music-industry catalog), and plain files mean `git`/`cp`/hand-editing all just work. `load_song`/`list_songs`/`save_song`/`import_song`/`load_setlist` (PROTOCOL.md "Song library") all funnel through the SAME `load_lyrics/3` every hand-pasted-lyrics path already used — the entire Phase 1-3 look-ahead/structure/eager-bootstrap machinery works identically regardless of where the lyrics came from. **Style ordering matters**: `apply_style/3` resets `director_conversation`, and `load_lyrics`'s `maybe_speculate_bootstrap/1` immediately spawns a Director call against whatever conversation exists — a song's pinned `style` must be applied BEFORE `load_lyrics`, not after, or the eager render (and the conversation it hands back on reveal) reflects the wrong style. See `load_song`/`load_setlist_song` in `pipeline.ex`.

31. **Auto-identification asks a DIFFERENT question than in-song position tracking, and needs its own matching function** → `Sinestesia.SongLibrary.identify/2` searches ACROSS every song's opening line for a few sung words; `PerformanceFollower.match/4` tracks position WITHIN one already-known script. Reusing `match/4` here would be wrong in a subtle way (it's tuned to prefer the nearest of a few nearby CANDIDATE LINES in one song, not to rank many different SONGS against each other) — so `identify/2` computes its own overlap-coefficient score, ranks all candidates, and returns the best one above `SONG_IDENTIFY_THRESHOLD` (0.7 default — deliberately higher than `LYRIC_MATCH_THRESHOLD`, since a short fragment matched against many songs is more ambiguous than matching one already-known song's next line). Wired into `maybe_auto_identify/2` in the transcript handler, gated on `not state.script_active?` so it only ever tries once per song — the moment it succeeds (or lyrics are loaded any other way), the guard blocks it from re-running and fighting a manual load.

32. **A setlist's auto-advance is keyed to a COMPLETED song, not to any reset** → `end_song` (a real performance, minted) advances `setlist_index` and loads the next entry; a plain `reset_song` (the soundcheck/false-start/discard path, no mint) replays the SAME entry instead. Getting this backwards would mean a false start silently skips a song from the show. `advance_setlist_or_rearm/1` is the single place this decision is made — only `end_song`'s handler calls it; `reset_song`'s still calls the plain `maybe_speculate_bootstrap/1`.

33. **Cross-song auto-identify must compare against a CAPPED sung fragment, never the full running transcript** → Found during a full re-read of this session's work. `match_score/2`'s overlap coefficient divides by `min(sung_tokens, line_tokens)`, which collapses to the (short, fixed) opening line's size the moment `sung` exceeds it — so once the denominator is pinned, the score can only ever go UP as more is sung, never down or reset. `maybe_auto_identify/2` originally passed the ENTIRE cumulative transcript (`state.lyrics` joined, unbounded, re-joined and re-checked on every single final line) to `SongLibrary.identify/2` — meaning a long enough genuinely-unrelated performance would eventually, by pure vocabulary coincidence (especially common function words), cross `SONG_IDENTIFY_THRESHOLD` against some catalog song's opening, with no way to self-correct once it did. Fixed by capping the comparison text to the first `@song_identify_max_words` (24) words ever sung before calling `identify/2` — matching the actual design intent ("identify from the first few sung words"), not "eventually stumble onto a match anywhere in the transcript." Regression test: `pipeline_song_library_test.exs` "a long, genuinely unrelated performance never accumulates into a false match" — verified it fails against the uncapped code and passes with the cap.

34. **A HELD eager bootstrap has no escape hatch if the singer is off-script — found live, not by any test** → The founder ran a live session (`SPECULATIVE_LOOKAHEAD`+`MUSICAL_STRUCTURE`+`LOOKAHEAD_DEPTH=3`+`SONG_AUTO_IDENTIFY` all on) where a song was loaded but the singer performed a DIFFERENT song. `maybe_trigger`'s bootstrap branch blocks EVERYTHING — reveal AND the reactive fallback — as long as `state.bootstrap_speculation` is non-nil and `bootstrap_target_reached?/1` is false, and that function does its OWN from-scratch `furthest_match` over `state.lyrics`, completely oblivious to the fact that `match_and_advance/2` (running on the very same final line, moments earlier) had already determined `:no_match` — off-script — and discarded the ordinary `speculation`/`prerender` chain. It never touched `bootstrap_speculation`. Result: with the wrong song loaded, the pipeline sat completely silent, no matter how many real words were spoken — exactly the "even the first render never comes" symptom reported live. Fixed by having `match_and_advance/2`'s `:no_match` clause ALSO call `discard_bootstrap_speculation/1` (not just `discard_speculation/1`), so an off-script performance abandons the eager render and falls through to the SAME plain reactive bootstrap gate (`@bootstrap_min_words`) used when no script is loaded at all — never worse than today's behavior, matching the graceful-fallback principle the rest of Phase 1-3 already relies on. Deliberately scoped narrowly: the sibling `%{}` branch (singer jumped to a DIFFERENT line the ordinary speculation didn't predict, but which the follower DID match — i.e. still on-script) does NOT discard the bootstrap; only a genuine `:no_match` does. Regression test: `pipeline_bootstrap_test.exs` "off-script singing discards a HELD eager bootstrap instead of blocking forever" — verified it fails without the fix (bootstrap_speculation stays stuck) and passes with it.

35. **`SONG_AUTO_IDENTIFY` was cold-start only — the founder's real expectation was continuous re-identification** → After gotcha #34's fix, the founder pointed out the DEEPER expectation: when the wrong song is loaded (or the singer starts an unplanned different one), the system should auto-identify the NEW song and switch, not just recover into generic reactive rendering under the wrong lyrics/structure. The original `maybe_auto_identify/2` only ever runs while `not state.script_active?` — the instant ANY song loads (manually, via setlist, or via a prior auto-identify), it never runs again for the rest of the show, no matter what's sung. Fixed by reusing `match_and_advance/2`'s `:no_match` branch (the exact moment the follower has already decided the performance diverged from the loaded script): it now calls `mid_song_reidentify/2`, which runs `SongLibrary.identify/2` against just the one just-confirmed off-script line — same signal cold-start identify uses ("a few sung words"), same `SONG_IDENTIFY_THRESHOLD`. A match to a DIFFERENT song than `current_song_id` loads it (pushing `song_identified`, returning `:handled` so no stale reactive call fires against the old context); a match to the SAME song already loaded is treated as `:no_match` (no pointless reload loop); no match falls through to the existing gotcha #34 recovery exactly as before. **Also found and fixed while unifying these two call sites**: cold-start `maybe_auto_identify/2` never applied a matched song's PINNED STYLE at all — `load_song`/`load_setlist_song` both apply style before `load_lyrics` (gotcha #30), but the auto-identify path only ever called `load_lyrics` directly, silently skipping styling. Both call sites now share `load_identified_song/3`, which applies style first, closing that gap for cold-start identify too. Regression tests: `pipeline_song_library_test.exs` "on: singing a DIFFERENT catalog song mid-performance switches to it" and "on: auto-identifying a song with a pinned style applies it, same as load_song" — both verified to fail against the pre-fix code.

36. **Amends gotcha #29: "wait for the whole natural stanza" is wrong when the stanza is genuinely long** → Live testing with the real `songs/aquarela.json` catalog entry (not the short 1-2 line examples used while building gotcha #29) showed the eager bootstrap holding the opening frame for 30+ seconds of continuous singing — Aquarela's actual first verse is 8 short lines with no internal blank-line break, so `MusicalStructure.analyze/1` groups them into ONE stanza, and the un-capped design waited for every one of the 8 lines to be confirmed sung before revealing anything. That's nearly the exact perceived-lag problem eager bootstrap exists to kill. Fixed in `stanza_target/1` (called from `bootstrap_content_and_target/1`): walk the stanza's own physical lines in order and stop at the FIRST one where cumulative words reach `@bootstrap_min_words` (15) — or the stanza's last line, whichever comes first. Still reveals at a real line boundary, never mid-sentence (keeping the part of gotcha #29 that mattered), but no longer insists on the stanza's FULL length once there's already enough content for a coherent opening — for Aquarela this now targets line 3 ("É fácil fazer um castelo", 19 cumulative words) instead of line 7, roughly halving the live wait observed. A short stanza (the common case gotcha #29 was tuned around) is unchanged — it still waits for all of its own (few) lines, since they never reach the cap before the stanza ends. The existing "waits for ALL of its own lines" test was rewritten to assert the new capped `target_index`, and a new test modeled directly on Aquarela's real 8-line verse locks in the cap.

37. **Supersedes gotcha #36: even a per-stanza word-count cap is still a hard-coded parameter — the target is now always just the first LINE** → The founder pushed back hard, correctly, on gotcha #36's fix: ANY fixed threshold (a word count, a word count capped per stanza, a line count) is the wrong shape of answer, because "how much content is enough" is genuinely different per song, and a "stanza" is a formatting artifact of whatever site the lyrics came from (Aquarela's real first verse is 8 lines with no internal blank-line break purely because that's how it happened to be transcribed) — not a musically meaningful unit to wait on. `bootstrap_content_and_target/1` no longer looks at `state.structure.sections` or any word/line count at all: it is always just `List.first(state.script)`, the song's first physical line, whatever that line happens to be for THIS song. This is the one unit that needs no per-song tuning to identify — it's always a real, complete, pasted lyric fragment (never a truncated ASR guess, unlike the reactive-only path, which still needs `@bootstrap_min_words` because it genuinely has nothing better than raw STT fragments to go on). `stanza_target/1` and `@bootstrap_fallback_lines` are removed entirely as dead code. For Aquarela this now targets line 0 ("Numa folha qualquer", 3 words) instead of line 3 or line 7 — reveals as soon as that one short line is confirmed sung.
    - **Open, deliberately NOT built**: a genuinely per-song, AI-driven judgment of "is one line actually enough, or does the natural opening phrase need two" (e.g. "Numa folha qualquer" + "Eu desenho um sol amarelo" reads as one sentence split across two lines by whatever site did the transcription). This is buildable the same way `Sinestesia.SongId` already does one-shot LLM calls with a provider chain and a strict timeout — but it MUST stay off the reveal-gate critical path (background Task, hard fallback to "first line" on any slow/failed answer) or it reintroduces exactly the kind of stall this whole gotcha chain has been fighting. Flagged for the founder to decide whether the added external-call risk is worth it before building.

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
