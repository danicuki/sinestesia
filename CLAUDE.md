# Working on Sinestesia

Sinestesia is a live audiovisual performance: a singer's voice → STT → an LLM
"Director" → generated images on stage → an NFT minted from the finished song.
It runs in front of an audience, so the constraints are unusual:

- **Latency is the product.** A frame that arrives 3 seconds late is worse than
  a plainer frame that arrives on time. Never put a blockchain round-trip, a
  settlement, or a retry loop on the path between a sung line and a picture.
- **On-chain records are permanent.** A wrong song title, a wrong model
  attribution, or a hallucinated artist is minted forever. Prefer "Untitled"
  and `null` to a confident guess.
- **Failures happen mid-show.** Log lines are read by someone at a sound desk
  with the house lights down. An error that names only its exception type is
  not an error report.

## Configuration: the one rule

`backend/lib/sinestesia/config.ex` is the registry of every environment
variable the backend reads. It feeds the boot banner, `GET /config`,
`mix sinestesia.config`, and the generated section of `CONFIGURATION.md`.

**Adding, renaming or removing an env var means editing the registry in the
same commit, then running:**

```bash
cd backend && mix sinestesia.config --write
```

`mix test` fails if you don't: it cross-checks the registry against every
`System.get_env` in `backend/lib` and `backend/config`, in both directions
(unregistered variables *and* registered-but-dead ones), and against
`CONFIGURATION.md` on disk. Keep the default next to the code that reads it —
the registry records what the default *is*, it doesn't own it.

Settings for the Python sidecars (`local-sdxl/`, `local-whisper/`) live in
their own code and are documented by hand in `CONFIGURATION.md` sections 2–3.

## Naming that has bitten us

- **`t2i` / `i2i`** — the only accepted spellings for the render mode, in code,
  logs, env values and provenance records. Not `img2img`, not `text2img`. The
  legacy spellings are still parsed from `.env` so nobody's setup breaks, but
  nothing emits them.
- **Capabilities, not just switches** — `IMAGE_PROVIDER`, `RENDER_MODE` and
  `COMPOSE_MODE` are independent switches over a grid with holes in it:
  Pollinations has no image-to-image, only fal and the local sidecar can
  inpaint. The table lives in `ImageGen.capabilities/1`; `render_mode/0` and
  `Director.compose?/0` resolve requests against it, and
  `Config.conflicts/0` reports what was downgraded. Adding a provider means
  adding its row — a missing entry fails the test suite, not a show.
- **Provider vs. model** — `DIRECTOR_PROVIDER=zerog` and
  `OLLAMA_MODEL=gemma4:12b-mlx` can both be set; the second is simply inert.
  Never print one as if it were the other. When a provider chain falls through
  to a fallback mid-song, report the model that *actually answered*
  (`Director.last_model/0`, `ImageGen.last_route/0`) — the configured one is a
  lie in exactly the cases that matter.

## Layout

| Path | What it is |
| --- | --- |
| `backend/` | Elixir. The pipeline: STT fan-out, Director, image generation, mint trigger. |
| `frontend/` | TypeScript. The stage view, timings HUD, verification badge. |
| `zerog/` | Node sidecar for 0G Compute verifiable inference (Director). |
| `sui/mint/` | Node sidecar: composes the song's frames, stores provenance, mints on Sui. |
| `local-sdxl/`, `local-whisper/` | Python sidecars for the fully-offline setup. |
