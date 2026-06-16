# Scope — Backend Agent

> You are the **backend agent**. You own everything under `backend/`. You must not touch `frontend/`. Communicate with the frontend only via the contract in `PROTOCOL.md`.

## Your job in one sentence

Build an Elixir HTTP+WebSocket server that proxies browser audio to Deepgram (streaming STT), combines transcripts with expressive features into a Claude Haiku prompt, generates an image via fal.ai, and pushes the URL back to the browser.

## Reading order

1. `CONTEXT.md` — overall project
2. `PROTOCOL.md` — the wire contract (your inputs and outputs)
3. This file
4. `backend/README.md` (you create it as you go)

## What lives under `backend/`

```
backend/
├── mix.exs                     deps
├── config/
│   ├── config.exs              base config
│   └── runtime.exs             env vars at boot
├── .env.example                local env keys
└── lib/
    ├── mix/
    │   └── tasks/
    │       └── sinestesia.replay.ex  ★ Headless replay & video compiler task
    └── sinestesia/
        ├── application.ex      OTP supervisor tree
        ├── router.ex           Plug.Router; mounts /ws/audio
        ├── audio_socket.ex     WebSock handler (browser <-> backend)
        ├── pipeline.ex         Per-session GenServer orchestrating rails
        ├── deepgram.ex         Mint.WebSocket client to Deepgram Nova-3
        ├── director.ex         Anthropic Haiku call (prompt builder)
        └── image_gen.ex        fal.ai Flux Schnell call

```

## Suggested deps (in `mix.exs`)

```elixir
{:bandit, "~> 1.5"},
{:plug, "~> 1.16"},
{:websock_adapter, "~> 0.5"},
{:mint, "~> 1.6"},
{:mint_web_socket, "~> 1.0"},
{:castore, "~> 1.0"},
{:req, "~> 0.5"},
{:jason, "~> 1.4"},
{:dotenvy, "~> 0.8"}
```

## Implementation guidance

### `application.ex`
- Supervisor with `{Bandit, plug: Sinestesia.Router, port: port}` and `{Registry, keys: :unique, name: Sinestesia.SessionRegistry}`.

### `router.ex`
- `Plug.Router` matching:
  - `GET /` → "ok" health
  - `GET /ws/audio` → upgrade to WebSocket via `WebSockAdapter.upgrade/4` pointing at `Sinestesia.AudioSocket`.

### `audio_socket.ex` (the `WebSock` callback module)
- `init/1`: spawn a session `Pipeline` GenServer (one per socket), store its pid in state.
- `handle_in/2`:
  - `{payload, [opcode: :binary]}` → forward to `Pipeline` as `{:audio_chunk, payload}` (this goes to Deepgram).
  - `{payload, [opcode: :text]}` → `Jason.decode!`, dispatch by `"type"`:
    - `"expressive"` → `{:expressive, features}`
    - `"fast_features"` → `{:fast_features, features}`
    - `"ping"` → reply immediately with `pong`
- `handle_info/2`: receive messages **from** the `Pipeline` (transcripts, images, errors) and push them down the socket as JSON text frames.

### STT providers (`eleven_stt.ex` and `deepgram.ex`)

Two `Mint.WebSocket`-based GenServers, one per provider. Both implement:
- `start_link(parent_pid)` → opens the upstream WS.
- `send_audio(pid, binary)` → forwards a PCM chunk.
- Internal `handle_info` parses incoming frames and emits to the parent:
  `{:transcript, provider, text, is_final, recv_ts_ms}` or
  `{:stt_error, provider, reason}`.

**ElevenLabs (`Sinestesia.ElevenSTT`)** — `wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=scribe_v2_realtime&language_code=por&audio_format=pcm_16000&commit_strategy=vad`. Auth header `xi-api-key`. Audio is wrapped in JSON text frames: `{message_type:"input_audio_chunk", audio_base_64:"...", commit:false, sample_rate:16000}`. Events: `partial_transcript`, `committed_transcript`.

**Deepgram (`Sinestesia.Deepgram`)** — `wss://api.deepgram.com/v1/listen?model=nova-3&language=pt-BR&encoding=linear16&sample_rate=16000&channels=1&interim_results=true&endpointing=300&punctuate=true`. Auth header `Authorization: Token <key>`. Audio sent as raw binary frames. Events parsed from `channel.alternatives[0].transcript` with `is_final`.

The Pipeline chooses which provider(s) to start based on the `STT_PROVIDER` env var:
- `"elevenlabs"` (default) — Scribe v2 only.
- `"deepgram"` — Nova-3 only.
- `"both"` — both run in parallel; transcripts are tagged with provider and logged side-by-side with latency for A/B comparison.

### `pipeline.ex` (GenServer, one per audio socket)
State holds:
```elixir
%{
  parent: pid(),           # the socket process (for replies)
  deepgram: pid(),         # the Deepgram WS GenServer
  lyrics_buffer: [String.t()],
  expressive: map(),
  fast: map(),
  last_image_at: integer(),
  generating?: boolean()
}
```
Handles:
- `{:audio_chunk, bin}` → `Deepgram.send_audio(deepgram, bin)`
- `{:transcript, text, is_final}` → append to buffer; if `is_final`, consider triggering a Director call (see debounce below); push `transcript` message to parent.
- `{:expressive, f}` → store latest features.
- Debounce rule for Director: trigger a Director call **at most every 1.5s** AND only when there's new final transcript content; never trigger if `generating?` is true; reset `generating?` when image returns or after 5s timeout.
- On Director response → call `ImageGen.generate/1` → on success, send `{:image, url, prompt}` to parent.

### `director.ex`
- One function: `build_prompt(%{lyrics: [...], expressive: %{}, fast: %{}}) -> {:ok, prompt} | {:error, _}`.

**Primary path: Gemma 4 12B (MLX) via Ollama (local).**
- POST to `${OLLAMA_URL}/api/chat` with model `${OLLAMA_MODEL}` (default `gemma4:12b-mlx`).
- Body fields:
  - `stream: false`
  - `think: false` ← critical. The MLX build has thinking enabled by default and will burn the token budget on chain-of-thought, returning an empty `content`.
  - `options: { temperature: 0.7, num_predict: 40 }` ← keep output short; ~25 words.
  - `messages`: `[ {role: "system", content: SYSTEM}, {role: "user", content: USER} ]`
- After the first call, Ollama caches the prompt prefix (system + KV cache stays warm). Measured on M4 Max: ~50ms prompt eval on warm calls, ~38 tok/s generation. Expect **~900ms total per warm call** for ~25-word output.
- Read response from `body["message"]["content"]`. Strip whitespace.

**Fallback path: Anthropic Haiku.**
- Triggered only if Gemma errors or exceeds a 1500ms wall-clock timeout.
- If `ANTHROPIC_API_KEY` is unset, skip fallback (just return `{:error, :no_director}` and the pipeline drops this cycle).
- Endpoint: `POST https://api.anthropic.com/v1/messages`, model `claude-haiku-4-5`, max_tokens 60.

**System prompt (used by both paths):**
> "You generate visual prompts for a live AI VJ accompanying a Brazilian MPB singer. Aesthetic anchors: Tarsila do Amaral, Alfredo Volpi, Djanira, xilogravura nordestina, marmorized paper textures, tropicalia palettes. STYLE: short, imagistic, no people or faces, no text, no logos. Output a single visual prompt in English under 25 words. No preamble. No quotes."

**User message format** (plain text, not JSON — Gemma handles natural language better):
```
lyrics: "<recent lyrics joined>"
vocal: <vocal_quality>, arousal <arousal>, valence <valence>
```
Example:
```
lyrics: "águas de março fechando o verão"
vocal: breathy, arousal 0.3, valence -0.2
```

### `image_gen.ex`
- One function: `generate(prompt) -> {:ok, url} | {:error, _}`.
- POST to `https://fal.run/fal-ai/flux/schnell` with header `Authorization: Key <FAL_API_KEY>`, body:
  ```json
  {"prompt": "...", "image_size": "landscape_16_9", "num_inference_steps": 4, "enable_safety_checker": false}
  ```
- Returns `images[0].url`.

### `runtime.exs`
Load env from `.env` via `Dotenvy`, then read:
- `DEEPGRAM_API_KEY` (required)
- `FAL_API_KEY` (required)
- `OLLAMA_URL` (default `http://localhost:11434`)
- `OLLAMA_MODEL` (default `gemma4:12b-mlx`)
- `ANTHROPIC_API_KEY` (optional; enables Haiku fallback if set)
- `PORT` (default 4000)

Put them under `:sinestesia, :config`.

## How to test without the frontend

Use `wscat` (or write a tiny Elixir script) to:
1. Connect to `ws://localhost:4000/ws/audio`.
2. Send a `{"type": "ping"}` text frame → expect `pong`.
3. Send a `{"type": "expressive", ...}` text frame → no error.
4. (Hardest) Stream a 16kHz mono PCM WAV file as binary frames → expect `transcript` frames back.

## Done when

- Backend runs (`mix run --no-halt`) on port 4000.
- Health `GET /` returns 200.
- Connecting via `wscat`, pinging works.
- Streaming the test PCM produces at least one `transcript` frame.
- Sending a fake `expressive` after some `transcripts` produces an `image` frame within ~2s.
- Logs are useful (one line per stage: `[stt] "..."`, `[director] prompt: "..."`, `[image] url: "..."`).

## Things you must NOT do

- Don't add a database, auth, multi-user, or admin UI.
- Don't use Phoenix Framework — too heavy, too much boilerplate. Plain Bandit + Plug + WebSockAdapter.
- Don't try to run Whisper locally via Bumblebee. Deepgram is the STT.
- Don't touch `frontend/`.
- Don't edit `PROTOCOL.md` without telling the user first.

## When you finish

Update this file with a brief "Status" section noting what works and what's open, so the user / frontend agent can read it.

---

## Status (backend agent — 2026-06-04)

**What's in the repo (compiles cleanly, server boots, port 4000 healthy):**

| Module | State |
|---|---|
| `mix.exs` + `config/runtime.exs` + `.env` (root) | ✅ deps installed (`bandit`, `mint_web_socket`, `req`, `dotenvy`, ...) |
| `application.ex` | ✅ supervises Bandit |
| `router.ex` | ✅ `GET /` returns "ok", `GET /ws/audio` upgrades to WebSocket (verified 101 via curl) |
| `audio_socket.ex` | ✅ WebSock handler; binary → Pipeline; `ping` → `pong`; `expressive` → Pipeline |
| `pipeline.ex` | ✅ GenServer per socket; 1.5s debounce on Director; trap_exit on Deepgram with auto-restart; tolerates missing Deepgram key (STT disabled, rest still works) |
| `deepgram.ex` | ⚠️ Mint.WebSocket client implemented but **untested against real Deepgram** — needs `DEEPGRAM_API_KEY` in `.env` plus a real PCM stream to verify |
| `director.ex` | ✅ Gemma 4 12B via Ollama `/api/chat` (think:false, num_predict:40); Haiku fallback when `ANTHROPIC_API_KEY` set; benchmarked ~900ms warm |
| `image_gen.ex` | ✅ Req → fal.ai Flux Schnell |
| `sinestesia.replay.ex` | ✅ Headless replay & video compiler task; supports audio copying, dynamic black instrumental intro generation, adaptive stop-motion synthetic crossfades, and full audio/video synchronization |


**Verified:**
- `mix compile` clean (no warnings after removing one unused attr).
- `mix run --no-halt` boots and Bandit accepts.
- `curl localhost:4000/` → 200 "ok".
- `curl` WebSocket upgrade → 101 Switching Protocols.
- Gemma Director benchmark (separate, before integration): 883–1070ms warm, sane visual prompts.

**Open / needs validation:**
- Deepgram WebSocket: upgrade handshake path is implemented (`Mint.HTTP.connect` → `Mint.WebSocket.upgrade` → `await_upgrade` → `Mint.WebSocket.new`). Untested against the live endpoint. Likely first integration bug surface.
- Pipeline → AudioSocket message flow: code path is straight but never exercised end-to-end. First real test arrives when the frontend pumps PCM.
- No CORS configured. If the frontend runs on a different origin (e.g., 5173 vs 4000), WS works (no CORS preflight) but be aware.

**For the frontend agent:**
The backend is up at `ws://localhost:4000/ws/audio`. You can develop against `?mock=1` indefinitely; when you're ready, just connect. Even without a `DEEPGRAM_API_KEY`, the socket stays open — you'll get one `error` frame about STT being disabled and then everything else (your Rail 1 + your audio chunks being silently dropped) works fine. To exercise the Director→Image path without real STT, send some synthetic `expressive` frames and the pipeline will fire (with empty lyrics, prompts come out aesthetic-only).

