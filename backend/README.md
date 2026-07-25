# Sinestesia Backend

Elixir orchestrator (no Phoenix). See `../CONTEXT.md`, `../PROTOCOL.md`,
`../SCOPE_BACKEND.md`, and `../CONFIGURATION.md` for every setting.

## Prereqs

- Elixir 1.17 / OTP 26
- `.env` at repo root (see `../.env.example`). Which keys you need depends on
  the providers you pick — `mix sinestesia.config` shows which are set.
- Only for the fully-local stack: `ollama serve` with `gemma4:12b-mlx` pulled,
  plus the `../local-whisper/` and `../local-sdxl/` sidecars.

## Run

```bash
mix deps.get
mix run --no-halt
```

Listens on `:4000`. Health: `curl localhost:4000/`.
WebSocket: `ws://localhost:4000/ws/audio`.

## What is this box configured to do?

The whole configuration is printed at boot, with a `*` next to every value that
came from the environment rather than a default. To ask again later:

```bash
mix sinestesia.config                      # resolved config, without booting anything
curl localhost:4000/config                 # from a running backend, as JSON
curl 'localhost:4000/config?format=text'   # ...or as the boot banner
```

API keys are never printed — only whether they're set, their length, and their
first/last four characters.

The registry behind all of this is `lib/sinestesia/config.ex`. **Adding or
renaming an env var means editing it in the same commit**, then running
`mix sinestesia.config --write` to regenerate `../CONFIGURATION.md`. `mix test`
fails otherwise — see `../CLAUDE.md`.

Two switches are routinely confused, so the banner resolves them for you:

- `DIRECTOR_PROVIDER` picks the *provider* (`gemma` | `gemini` | `haiku` |
  `zerog`). `OLLAMA_MODEL` names a model, and only applies to `gemma`.
- `IMAGE_PROVIDER` picks who renders; `RENDER_MODE` picks `t2i` or `i2i`. Every
  provider does both. Those two spellings are the only ones the code emits.

## Quick smoke (no frontend)

```bash
# install once: brew install websocat
websocat ws://localhost:4000/ws/audio
> {"type":"ping"}
< {"type":"pong"}
```

Exercise the Director or an image provider directly:

```elixir
iex -S mix
> Sinestesia.Director.build_prompt(%{
    lyrics: ["águas de março fechando o verão"],
    expressive: %{"vocal_quality" => "breathy", "arousal" => 0.3, "valence" => -0.2}
  })

> Sinestesia.ImageGen.generate("marmorized paper texture, tropicalia palette")
```

## Replay a recorded session

Runs a session JSON from `../tests/sessions/` through the full Director → image
chain, with no microphone:

```bash
REPLAY_SPEED=20 mix sinestesia.replay ../tests/sessions/garota-de-ipanema.json --slug ipanema
```

## Architecture

```
AudioSocket (WebSock)
    │
    └── Pipeline (GenServer, one per socket — the brain)
            │
            ├── STT fan-out    ElevenLabs / Deepgram / local Whisper / replay
            ├── Director       Ollama · Gemini · Haiku · 0G sidecar (chain, falls through)
            ├── ImageGen       fal · Cloudflare · Google · Pollinations · local SDXL
            ├── SongId         names the performed song from the transcript, at mint time
            └── mint sidecar   composes the frames, stores provenance, mints on Sui
```

Every rail runs in its own `Task`; results carry the session id they were
spawned with, and are dropped if the song has since been reset. The
`generating?` flag serialises Director → image so the pipeline can't pile up.

Timings are measured *inside* each task and reported separately from the time a
reply spent queued in the pipeline's mailbox — otherwise backpressure reads as
provider latency.

## Tests

```bash
mix test
```

Guards the configuration registry against drift (unregistered env vars, dead
settings, a stale `CONFIGURATION.md`) and the `t2i`/`i2i` normalisation.
