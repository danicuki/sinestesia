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
style at 5 words and strips quotes/newlines as a sanity guard. Sending the
same style as the current one is a no-op; sending a new one resets the
Director's conversation (continuity is intentionally broken so the new
style takes effect immediately).

```json
{ "type": "style", "style": "watercolor washes" }
```

After the backend accepts the change, it echoes it back as a server message
so the frontend can confirm what is actually in use.

Default style at session start: `"Brazilian cordel woodcut print, black and white, hatched linework"`.

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
  "timings": {
    "stt_ms": 195,
    "stt_provider": "deepgram",
    "director_ms": 870,
    "image_ms": 480,
    "total_ms": 1545,
    "image_provider": "fal"
  }
}
```

- `url`: image URL. Either an HTTPS URL (fal.ai, pollinations) or a `data:image/png;base64,...` URL (google). Three.js `TextureLoader` handles both. Crossfade from the previous one over ~600ms.
- `prompt`: included for debugging/overlay; can be ignored visually.
- `timings`: per-cycle latency breakdown. Useful for the `?debug=1` overlay to compare providers.

### `error`

```json
{ "type": "error", "provider": "deepgram", "message": "deepgram: :closed" }
```

The `provider` field is present when the error is scoped to one STT provider.

Non-fatal. Frontend may log; demo continues.

### `style` (echo of accepted style)

Sent right after the backend accepts a `style` client message, so the frontend
can render the actual sanitized/capped value.

```json
{ "type": "style", "style": "watercolor washes", "ts": 1717500000456 }
```

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
