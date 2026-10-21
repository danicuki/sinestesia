# STT shoot-out — results and verdict

Measured 2026-10-20 with `mix sinestesia.bench.stt` on the corpus in
`corpus.json`: 9 clips of real singing (564 reference words; pt ×3, en ×2,
it ×2, de ×2 — the duo's own takes plus Demucs vocal stems of studio
recordings) and a 4-language medley streamed as ONE session. Every engine
heard the same 16 kHz PCM at real-time pace in 250 ms chunks, through the
same client modules the stage uses. Scores: WER against the real lyrics under
the follower's normalization (held vowels folded), lag of each final behind
the last word it contains, share of lyric lines `PerformanceFollower` would
have confirmed, and list price per streamed hour.

Machine for the local runs: Strix Halo (Ryzen AI Max, Radeon 8060S), CPU
only — the ROCm 7.0 torch wheel segfaults openai-whisper on gfx1151, so the
realtime path is faster-whisper/CTranslate2 int8 on 12 threads. A Mac with
mlx will be faster per decode; the architecture findings below hold either
way.

## Local Whisper (sidecar `local-whisper/`)

| variant | WER | de | en | it | pt | lines followed | final lag p50 / p90 | partial lag p50 | reveal delay p50 |
|---|---|---|---|---|---|---|---|---|---|
| **large-v3-turbo @12t greedy 4-lang** | **13.0%** | 30.3% | 2.8% | 9.4% | 11.9% | **76.7%** | 2709 / 4405 ms | 1160 ms | 4665 ms |
| large-v3-turbo @12t greedy | 13.0% | 30.3% | 2.8% | 9.4% | 11.9% | 76.7% | 2574 / 3256 ms | 1107 ms | 3264 ms |
| large-v3-turbo @12t finals-only (old sidecar) | 14.5% | 17.4% | 2.8% | 32.5% | 5.5% | 77.8% | 2875 / 3819 ms | — | 3815 ms |
| **small @12t greedy 4-lang** | 24.6% | 38.5% | 2.8% | 37.5% | 18.8% | 70.0% | **1576 / 2340 ms** | **644 ms** | **2443 ms** |
| small @12t (old sidecar) | 26.8% | 68.8% | 2.8% | 35.6% | 11.0% | 61.1% | 1804 / 2857 ms | 791 ms | 2497 ms |
| small @4t (old sidecar, default threads) | 32.0% | 68.8% | 2.8% | 55.0% | 11.0% | 61.1% | 2151 / 3512 ms | 1006 ms | 2769 ms |
| base @4t | 33.1% | 48.6% | 9.4% | 48.1% | 25.7% | 62.2% | 1761 / 2861 ms | 685 ms | 3720 ms |
| medium @12t greedy | 34.4% | 67.0% | 3.8% | 61.3% | 13.3% | 62.2% | 2485 / 3066 ms | 1004 ms | 2971 ms |
| tiny @4t | 51.3% | 90.8% | 16.0% | 69.4% | 35.3% | 54.4% | 1720 / 3357 ms | 940 ms | 2223 ms |
| medium @12t (old sidecar) | 64.4% | 100% | 14.2% | 100% | 45.0% | 33.3% | 10.9 / 20.0 s | 7.7 s | 10.5 s |
| large-v3-turbo @12t (old sidecar) | 94.3% | 91.7% | 100% | 93.1% | 93.6% | 6.7% | 32.7 / 41.0 s | 25.5 s | 32.9 s |

`@Nt` = CTranslate2 threads (`OMP_NUM_THREADS`). "old sidecar" = `server.py`
before the fixes below. Lags include the 250 ms capture chunk, as on stage.

### Language switching (medley: pt → it → de → en, one session, 3 s apart)

| variant | pt-trem | it-pausini | de-fischer | en-letitbe |
|---|---|---|---|---|
| large-v3-turbo greedy 4-lang | 3.8% | 29.0% (alone 9.7%) | 46.3% (alone 37.3%) | 2.8% |
| large-v3-turbo greedy | 3.8% | 29.0% (alone 9.7%) | 74.6% (alone 37.3%) | 2.8% |
| small greedy 4-lang | 15.1% | 16.1% (alone 10.8%) | 71.6% (alone 47.8%) | 0.0% |

With `WHISPER_LANGUAGES=pt,en,it,de` the session locked the right language on
13/13 songs (confidences pt .98–.99, en .96–.97, it .82–.88, de .87–.98) and
switched correctly at every song change. The remaining medley-vs-alone gap is
the first phrase after a switch, decoded before the new lock lands.

### What the bench found in the sidecar (fixed in the same commit)

The spread between "old sidecar" and "greedy" rows is the same models on the
same audio — the serving loop, not model size, was the ceiling:

1. **Offline decode defaults on a realtime path.** faster-whisper's `beam_size=5`
   plus its temperature fallback (up to six decodes when a pass looks
   degenerate) hit exactly what singers do: on *Atemlos*' "oh, oh, oh" intro,
   `small` spent **13 s decoding each 4 s buffer** (base: 1.3 s). Now greedy,
   one pass, 160-token cap (`WHISPER_BEAM_SIZE`, `WHISPER_TEMPERATURE_FALLBACK`,
   `WHISPER_MAX_NEW_TOKENS`); the batch endpoint keeps the offline defaults.
2. **The receive loop awaited the decode.** While a decode ran, no audio was
   drained and VAD did not run, so a slow pass stalled the whole stream —
   that is how turbo fell 30 s behind and medium 10 s. Decodes now run on a
   single-worker executor; interims are skipped (not queued) while one is in
   flight; finals keep their order.
3. **Buffer overflow dropped sung words.** With no 650 ms breath for 20 s (a
   gapless chorus) the oldest audio was discarded. It is now committed as one
   final (`MAX_BUFFER_SECS` semantics changed, same default).
4. **Language locked from a 1–2 s guess.** `medium` locked *Hindi* (0.59) on an
   Italian verse and wrote Devanagari for the whole clip. Now
   `WHISPER_LANGUAGES` restricts the argmax to the show's languages, interims
   never lock, and only a final with ≥ `WHISPER_MIN_LOCK_WORDS` (4) words does
   — the opening seconds of any song score "en 0.4–0.5" on breath and
   vocalizations, which is the trap.

### Local verdict

- **Quality: `large-v3-turbo`** (13.0% WER, 77% of lines followed; en 2.8%,
  it 9.4%, pt 11.9%). German is the weak language for every local model
  (30%+). Finals arrive ~2.7 s behind the voice on this CPU.
- **Latency: `small`** — finals 1.6 s p50, partials 0.6 s — at 24.6% WER and
  70% of lines. That 1.1 s is a real difference on stage (reveals are gated
  on finals).
- `medium` is dominated (worse than turbo, slower than small); `tiny`/`base`
  lose too many words.
- 12 threads vs the default 4 took `small` from 32% to 27% WER on the old
  sidecar — set `OMP_NUM_THREADS` on a CPU box.
- The Mac (mlx) should re-run `--whisper mlx-community/whisper-small-mlx,mlx-community/whisper-large-v3-turbo`
  before choosing: the mlx candidate-language path was written against the
  library's API but could not be executed here.

Settings that encode the verdict for the local sidecar:

```
WHISPER_BACKEND=faster-whisper      # (mlx on the Mac)
WHISPER_MODEL=large-v3-turbo        # or small for the faster finals
WHISPER_LANGUAGES=pt,en,it,de
OMP_NUM_THREADS=12
```

## Cloud engines — PENDING

Not run yet: this machine's `.env` has no `ELEVENLABS_API_KEY`,
`DEEPGRAM_API_KEY` or `GOOGLE_API_KEY`. The variants are wired and selectable
(`--variants eleven,eleven-turn,deepgram,flux,gemini,gemini-live` and the
`-hint` pinned-language twins); each full corpus pass is ~8 minutes of audio
per engine. Vendor facts checked 2026-10-20:

| engine | `.env` | model | list price / h streamed | notes |
|---|---|---|---|---|
| ElevenLabs | `STT_PROVIDER=elevenlabs` | `scribe_v2_realtime` — still the **only** realtime model id the API accepts | $0.39 | new since we integrated: `commit_strategy=turn_prediction` (2026-10-12), `keyterms`, `previous_text`, `filter_background_audio`, `secondary_languages`. `ELEVEN_LANG` now defaults to auto-detect. |
| Deepgram Nova-3 | `STT_PROVIDER=deepgram` `DEEPGRAM_MODEL=nova-3` | Nova-3 Multilingual (`DEEPGRAM_LANGUAGE=multi`, default — was hard-coded `pt-BR`) | $0.348 (promo) | en/es/fr/de/hi/ru/pt/ja/it/nl code-switching |
| Deepgram Flux | `DEEPGRAM_MODEL=flux-general-multi` | turn-based model on `/v2/listen` (GA 2026-04-29) | $0.468 | `EndOfTurn` = final; same 10 languages |
| Gemini 3.5 Transcribe Live | `STT_PROVIDER=gemini` (default model) | `gemini-3.5-transcribe-live` (public preview 2026-08-26) | ~$0.54 ($0.005/min in + $0.004/min out) | dedicated streaming ASR; 10-min sessions (client rolls over on `goAway`); `GEMINI_STT_LANG` empty = auto |
| Gemini 3.8 Live | `GEMINI_STT_MODEL=gemini-3.8-live` | audio-to-audio voice model (stable 2026-09-15) | $0.30 audio in (+$0.018/min if it speaks) | transcript only as a side channel; told to stay silent. Measured for completeness, not a candidate. |

When keys land: `cd backend && mix sinestesia.bench.stt` runs everything
(idle network — each stream is ~40 KB/s up and a saturated uplink inflates
exactly the latency being measured); results accumulate in `bench-stt/` and
`report.md` there is the merged table.
