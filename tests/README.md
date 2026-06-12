# tests/ — session replay harness

Iterate on the Director / image pipeline **without singing the whole song
again**. A session file captures one rehearsal — the transcripts exactly as
the STT emitted them, with their original timing — and the harness replays it
through the real pipeline (Gemma Director → local SDXL → frontend).

## Create a test from a backend log

Save the backend log to a file and run:

```bash
python3 tools/log_to_session.py /path/to/backend.log --name aquarela-tarsila
# wrote tests/sessions/aquarela-tarsila.json (86 events, 83s, style=yes)
```

The converter reads the `[provider] int/FIN +Nms: ...` lines, anchors
timestamps to the first transcript, splits on "song reset" (one file per
song), and records the active style.

## Replay it

**Visual (in the browser)** — watch the projection react without a mic:

```bash
cd backend
STT_PROVIDER=replay REPLAY_FILE=../tests/sessions/aquarela-tarsila.json mix run --no-halt
# open the frontend as usual; playback starts on connect.
# "Nova música" restarts the session from the top.
```

**Headless (no browser, no mic)** — full pipeline, results printed:

```bash
cd backend
mix sinestesia.replay ../tests/sessions/aquarela-tarsila.json
mix sinestesia.replay ../tests/sessions/aquarela-tarsila.json --speed 2
```

Prints every generated image (prompt, URL, director/image timings, morph frame
count) and a summary at the end. Runs on `PORT=4999` so it can coexist with a
live backend (`REPLAY_PORT` to change).

**Watch the run as a video sequence**: after the run, the images are exported
automatically as a frontend sample sequence and played by the existing
continuous-morph demo player:

```
http://localhost:5173/?demo=run-aquarela-tarsila
```

(Also selectable in the `?debug=1` overlay picker.) The default slug
`run-<session-name>` is overwritten on every run — iterate freely. To KEEP a
run for A/B comparison, name it: `--slug experiment-strength-085`.

Requirements (same as a live run): Ollama with the Director model, the
`local-sdxl` sidecar on :8003, and `FAL_API_KEY` for the bootstrap frame.

## Tuning knobs (set as env on the replay command)

| Var | Default | Meaning |
|---|---|---|
| `COMPOSE_MODE` | `inpaint` | `inpaint` = each lyric element is painted into a placement region (guaranteed to appear); `global` = whole-canvas img2img with a scene-list prompt |
| `COMPOSE_ATMOS_STRENGTH` | `0.4` | how much an atmospheric (abstract-lyric) pass may change the whole canvas |
| `SCENE_WINDOW` | `5` | global mode only: how many recent elements the Director re-lists |
| `STYLE_ANCHOR` | off | short per-frame style hint appended to every prompt; `first` = style's first comma-clause (old behavior), custom text overrides. Off by default: repeating a style fragment every frame biases the sequence |
| `STYLE_REFRESH_EVERY` | `4` | every N images, re-apply the full style: with `local_sdxl` as a real whole-canvas `style_pass` in the sidecar (`STYLE_PASS_STRENGTH`); with other providers (fal etc., global mode) appended to the prompt TEXT — prompts in between stay style-free so scene words carry full weight. `0` disables |
| `LOCAL_SDXL_STRENGTH` | `0.78` | global-mode change rate per frame (img2img noise) |
| `LOCAL_SDXL_STEPS` | `3` | scheduler steps; real denoise steps = `int(steps × strength)` |

Note: element-inpaint prompts always carry the full style note — the masked
region is painted from scratch and the prompt is its only style signal (only
the ellipse hears it; atmospheric/global prompts stay style-free).

Example A/B:

```bash
mix sinestesia.replay ../tests/sessions/aquarela-tarsila.json --slug exp-inpaint
COMPOSE_MODE=global SCENE_WINDOW=4 mix sinestesia.replay ../tests/sessions/aquarela-tarsila.json --slug exp-global-w4
```

## Notes

- `REPLAY_SPEED=N` (env) or `--speed N` (task) compresses the *gaps* between
  transcripts. Director min-interval and model latencies are real, so 2x
  yields fewer, denser images than the original performance — fine for
  pipeline iteration, not for judging pacing.
- Replays are not deterministic: the Director and SDXL sample fresh noise each
  run. The harness reproduces the *input*, which is what makes A/B comparison
  of prompt/strength/camera changes meaningful.
- Session format: `{"name", "style"?, "events": [{"at_ms", "text", "final"}]}`.

## Sessions

| File | Source | Length |
|---|---|---|
| `sessions/aquarela-tarsila.json` | Aquarela rehearsal 2026-06-10 10:17 (Tarsila style) | 86 events, 83s |
| `sessions/o-pato.json` | O Pato rehearsal 2026-06-12 (animal protagonist — Director regression: duck must appear) | 26 events, 26s |
| `sessions/garota-de-ipanema.json` | Garota de Ipanema rehearsal 2026-06-12 (person protagonist — Director regression: the girl must appear) | 51 events, 62s |
| `sessions/trem-das-cores.json` | Trem das Cores rehearsal 2026-06-12, graffiti style (no single protagonist — a cascade of colors/images; the protagonist rule must NOT force one) | 105 events, 111s |

The suite is deliberately DIVERSE (animal / person / object-list songs): after any
Director-prompt change, replay ALL of them — a fix that only works on the song
that motivated it is overfitting. Add a session from every rehearsal that
misbehaves: save the backend log and run `tools/log_to_session.py`.
