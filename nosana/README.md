# Sinestesia on Nosana

Job definitions for running Sinestesia's sovereign model stack on
[Nosana](https://nosana.com) GPU markets instead of the on-stage laptop.
The engine already speaks each sidecar's protocol over HTTP, so pointing a
provider at a Nosana node is configuration, not code:

| job definition | engine slot | wiring |
| --- | --- | --- |
| `director-gemma4-12b.json` | Director LLM (`DIRECTOR_PROVIDER=gemma`) | `OLLAMA_URL=<service url>` — same `gemma4:12b` the stage runs, served by `ollama/ollama` with port 11434 exposed and a `/api/tags` health check (derived from Nosana's official Gemma4 template) |

Post a job (CLI wallet must hold NOS + a little SOL):

```bash
npx @nosana/cli job post \
  --file nosana/director-gemma4-12b.json \
  --market nvidia-3090 \
  --timeout 60
```

The post output prints the service URL. Measure what the stage would feel:

```bash
# words/second + direction-length budget for the Director
OLLAMA_URL=<service url> mix sinestesia.bench.director --models ollama:gemma4:12b

# a full session replayed against the node, Director latency per sung line
# in the [director] log lines (IMAGE_PROVIDER=none isolates the Director)
DIRECTOR_PROVIDER=gemma OLLAMA_URL=<service url> OLLAMA_MODEL=gemma4:12b \
  IMAGE_PROVIDER=none mix sinestesia.replay ../tests/sessions/dinda.json
```

Markets and live prices: `npx @nosana/cli market list` and
https://explore.nosana.com/markets (2026-10-12: 3090 ≈ $0.17/h,
4090 ≈ $0.29–0.37/h, 5090 ≈ $0.45/h). The MiniMax H3 video template
(first-frame / optional last-frame, 5 s 1344×768 with audio, Blackwell
32 GB) lives in Nosana's catalog as `MiniMax-H3`; a `VideoGen` engine for
it is the natural next template here.
