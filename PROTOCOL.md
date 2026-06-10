# Sinestesia — WebSocket Protocol

> **The single contract between backend and frontend.** Both agents must implement exactly this. If a change is needed, the user must update this file and both agents must re-sync.

## Connection

- **URL**: `ws://localhost:4000/ws/audio`
- **Subprotocol**: none
- **Encoding**: JSON for text frames, raw bytes for binary frames

The connection is initiated by the **frontend** when the user grants microphone permission. Reconnect on close with exponential backoff (250ms, 500ms, 1s, 2s, max 5s).

## Frame conventions

- **Text frames**: JSON objects with a required `"type"` field. Unknown types must be ignored (not error out).
- **Binary frames**: always raw PCM audio chunks. The accompanying metadata (timestamp, sample format) is implicit — see "Audio format" below. The backend treats binary frames as `{type: "audio_chunk"}` implicitly.

## Audio format (binary frames)

- **Sample rate**: **16000 Hz** (downsampled in browser from native 48kHz)
- **Channels**: 1 (mono)
- **Sample format**: **16-bit signed little-endian PCM** (`Int16Array` byte layout)
- **Chunk size**: ~250ms = **4000 samples = 8000 bytes** per frame
- **Cadence**: continuous while the mic is active

The browser is responsible for downsampling and converting `Float32` → `Int16`. The backend forwards bytes directly to Deepgram (which is configured for the same format).

## Frontend → Backend messages

### `expressive` (every ~500ms while singing)
Computed by Essentia.js in the browser.

```json
{
  "type": "expressive",
  "ts": 1717500000123,
  "features": {
    "spectral_centroid": 2400,
    "loudness": 0.72,
    "inharmonicity": 0.12,
    "pitch_salience": 0.85,
    "vocal_quality": "breathy",
    "arousal": 0.4,
    "valence": -0.2
  }
}
```

**Field semantics:**
- `spectral_centroid` (Hz, ~0–8000): perceived brightness.
- `loudness` (0..1): perceived energy.
- `inharmonicity` (0..1): vocal noisiness/roughness; high = breathy/raspy.
- `pitch_salience` (0..1): confidence that a clear pitch exists.
- `vocal_quality`: one of `"breathy" | "belted" | "intimate" | "soaring" | "neutral"`. Derived in browser from a heuristic on the above.
- `arousal` (0..1): calm → energetic.
- `valence` (-1..1): sad → happy.

### `fast_features` (optional, ~10 Hz)
If the frontend wants to share Rail-1 features with the backend (e.g., for the Director to know current intensity). Not required for v1.

```json
{
  "type": "fast_features",
  "ts": 1717500000123,
  "rms": 0.45,
  "tempo_estimate": 92
}
```

### `style` (visual style override)

Changes the art style for subsequent Director prompts. The backend caps the
style at **15 words** and strips quotes/newlines as a sanity guard (the cap
is generous so curated palette entries like `"loose ink sketch on aged paper,
sparse hand-drawn linework, sepia tones"` fit). Sending the same style as the
current one is a no-op; sending a new one resets the Director's conversation
(continuity is intentionally broken so the new style takes effect immediately).

```json
{ "type": "style", "style": "loose ink sketch on aged paper, sparse hand-drawn linework, sepia tones" }
```

After the backend accepts the change, it echoes it back as a server message
so the frontend can confirm what is actually in use.

Default style at session start depends on `IMAGE_MODE` (see backend):
- `story` mode (default): `"loose ink sketch on aged paper, sparse hand-drawn linework, sepia tones"`
- `classic` mode: `"Brazilian cordel woodcut print, black and white, hatched linework"`

The style may also be set automatically by the backend's **StyleCurator** after
the first ~5 final lyrics. When that happens, the echoed `style` message
carries `"source": "curator"` instead of `"source": "user"`.

### `camera` (operator-driven virtual camera) *(added 2026-06-10)*

A persistent camera **velocity** applied by the image pipeline to every
generated frame while non-neutral: the previous frame is warped (zoom/pan)
before each img2img step, so the scene drifts in the chosen direction and the
revealed edges get painted with new content. All values are `-1..1`
(`0` = still); missing fields are treated as `0`. Send a new message whenever
the control changes; send all-zeros (or `{}`) to stop. Reset to neutral on
`reset`.

```json
{ "type": "camera", "zoom": -1, "pan_x": 0.3, "pan_y": 0 }
```

- `zoom`: `> 0` zooms in, `< 0` zooms out (scene recedes — useful when the
  canvas is crowded and a dominant element should shrink).
- `pan_x`: `> 0` pans the camera right (scene slides left, new canvas appears
  on the right). `pan_y`: `> 0` pans up.
- Rates at full deflection (sidecar env-tunable): ~5% zoom and ~5% of the
  frame per generated image. Full deflection is strong — a brief toggle of
  2-3 frames is usually enough; a UI can also send fractional values for
  finer moves.
- Only honoured by the `local_sdxl` image provider; other providers ignore it.

v1 UI can be a single "zoom out" toggle (sends `{zoom: -1}` / `{zoom: 0}`);
the protocol already supports a full 6-direction "cameraman joystick" without
changes.

### `reset` (new song begins)

Resets all song-scoped state on the backend without dropping the WebSocket
or the STT connections. Use this when the singer is about to start a new
song so the Director conversation, accumulated lyrics, image continuity,
and curator lock all start fresh. Faster than reconnecting.

```json
{ "type": "reset" }
```

After the reset the backend pushes a `style` message back with
`"source": "reset"` carrying the **default** style for the current
`IMAGE_MODE` (story → `"loose ink sketch on aged paper, ..."`). The
frontend can use this to clear its style input.

### `ping`
Liveness check. Backend responds with `pong`.

```json
{ "type": "ping" }
```

## Backend → Frontend messages

### `transcript` (interim and final from one of the STT providers)

```json
{
  "type": "transcript",
  "provider": "elevenlabs",
  "ts": 1717500000456,
  "text": "águas de março fechando o verão",
  "is_final": false,
  "latency_ms": 195
}
```

- `provider`: `"elevenlabs"` or `"deepgram"`. In `STT_PROVIDER=both` mode, both providers emit transcripts independently — the frontend may display them side-by-side for A/B comparison, or pick one.
- `text`: the most recent transcription window. May overlap previous `is_final: false` messages.
- `is_final`: `true` when the provider closes a segment. The frontend should display interim text in a lighter style if it shows transcripts.
- `latency_ms`: milliseconds between the last audio chunk send and this transcript receive. Approximate but useful for live comparison.

### `image` (new visual ready)

```json
{
  "type": "image",
  "ts": 1717500001234,
  "url": "https://fal.media/files/elephant/abc123.jpg",
  "prompt": "águas escuras correndo lentas, pedra solitária...",
  "frames": [
    "http://127.0.0.1:8003/img/ab12_m1.jpg",
    "http://127.0.0.1:8003/img/ab12_m2.jpg",
    "http://127.0.0.1:8003/img/ab12.png"
  ],
  "timings": {
    "stt_ms": 195,
    "stt_provider": "deepgram",
    "director_ms": 870,
    "image_ms": 480,
    "total_ms": 1545,
    "image_provider": "local_sdxl"
  }
}
```

- `url`: image URL. Either an HTTPS URL (fal.ai, pollinations) or a `data:image/png;base64,...` URL (google). Three.js `TextureLoader` handles both. Crossfade from the previous one over ~600ms.
- `lyric` *(optional, added 2026-06-10)*: the lyric window (STT text) that the Director was reacting to when it wrote `prompt`. For debug overlays — lets the operator see "letra → prompt → imagem" per frame.
- `frames` *(optional, added 2026-06-10)*: only present when `image_provider` is `local_sdxl`. A **generative morph sequence** from the previous image to the new one — slerp interpolation in SDXL latent space, decoded server-side — ordered by progress and **always ending on the same image as `url`**. Intended frontend behaviour: preload all frames, then play them as a chained morph (each consecutive pair is a mini-crossfade segment spread over the image cadence) instead of a single A→B crossfade. The in-between frames are real decoded images (shapes transform, not pixels dissolving). Clients that ignore `frames` and just use `url` keep working exactly as before.
- `prompt`: included for debugging/overlay; can be ignored visually.
- `timings`: per-cycle latency breakdown. Useful for the `?debug=1` overlay to compare providers.

### `error`

```json
{ "type": "error", "provider": "deepgram", "message": "deepgram: :closed" }
```

The `provider` field is present when the error is scoped to one STT provider.

Non-fatal. Frontend may log; demo continues.

### `style` (echo of accepted style)

Sent right after the backend accepts a `style` client message OR after the
StyleCurator auto-picks a style. Carries the sanitized/capped value plus a
`source` field so the frontend can distinguish user-driven vs auto-curated
changes (e.g. for a small UI badge).

```json
{
  "type": "style",
  "style": "loose ink sketch on aged paper, sparse hand-drawn linework, sepia tones",
  "source": "curator",
  "ts": 1717500000456
}
```

`source`: `"user"` (sent in response to a client `style` message) or
`"curator"` (auto-picked by the backend after a few lyrics).

### `pong`

```json
{ "type": "pong" }
```

## Throughput expectations

| Direction | Frame | Cadence | Notes |
|---|---|---|---|
| FE→BE | binary audio | ~4 Hz (250ms chunks) | 8 KB each, ~32 KB/s |
| FE→BE | `expressive` | ~2 Hz | small JSON |
| BE→FE | `transcript` | bursty, ~2–4 Hz when singing | small JSON |
| BE→FE | `image` | 0.3–1 Hz | URL only, image fetched via HTTPS |

## Failure modes

- **Deepgram WS dropped**: backend emits `error`, attempts reconnect, transcripts pause. Frontend keeps Rail 1 running.
- **Anthropic timeout**: backend skips this image cycle, no `image` frame sent.
- **fal.ai timeout**: same.
- **Browser WS dropped**: frontend reconnects with backoff. Backend tears down session GenServer; new session on reconnect.

## Versioning

If you must evolve the protocol mid-project: bump a `version` field on the first `ping` (and the backend's `pong`) and add a one-line note in this file. **Do not silently change field shapes.**

Changes:
- **2026-06-10**: added optional `frames` array to the `image` message (latent-morph sequence from the local SDXL sidecar). Purely additive — clients ignoring it are unaffected.
- **2026-06-10**: added FE→BE `camera` message (operator-driven zoom/pan applied per generated frame). Additive — backends ignore unknown fields, and not sending it preserves current behaviour.
