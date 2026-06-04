# Sinestesia Backend

Elixir orchestrator. See `../CONTEXT.md`, `../PROTOCOL.md`, `../SCOPE_BACKEND.md`.

## Prereqs

- Elixir 1.17 / OTP 26
- `ollama serve` running with `gemma4:12b-mlx` pulled
- `.env` at repo root with `DEEPGRAM_API_KEY` and `FAL_API_KEY`

## Run

```bash
mix deps.get
mix run --no-halt
```

Server listens on `:4000`. Health: `curl localhost:4000/`. WebSocket: `ws://localhost:4000/ws/audio`.

## Quick smoke (no frontend)

```bash
# In a separate terminal — install once: brew install websocat
websocat ws://localhost:4000/ws/audio
> {"type":"ping"}
< {"type":"pong"}
```

To exercise the Director without piping real audio:

```elixir
iex -S mix
> Sinestesia.Director.build_prompt(%{
    lyrics: ["águas de março fechando o verão"],
    expressive: %{"vocal_quality" => "breathy", "arousal" => 0.3, "valence" => -0.2}
  })
```

To exercise fal.ai:

```elixir
> Sinestesia.ImageGen.generate("marmorized paper texture, tropicalia palette, swaying palm silhouettes")
```

## Architecture

```
AudioSocket (WebSock)
    │
    └── Pipeline (GenServer, one per socket)
            │
            ├── Deepgram (GenServer, streams PCM → Mint.WebSocket → STT)
            ├── Director (Req → Ollama Gemma; Haiku fallback)
            └── ImageGen (Req → fal.ai Flux Schnell)
```

Director is debounced to fire at most every 1.5s and only when there's a new final transcript. `generating?` flag prevents pipeline pile-up.

## Status

- [x] Skeleton, deps, config, supervisor
- [x] Router + WebSocket upgrade
- [x] Director (Gemma + Haiku fallback)
- [x] ImageGen (fal.ai)
- [x] Pipeline orchestrator
- [x] AudioSocket
- [x] Deepgram streaming client (untested against real API yet)
- [ ] End-to-end smoke with actual mic input (needs frontend)
