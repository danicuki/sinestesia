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
