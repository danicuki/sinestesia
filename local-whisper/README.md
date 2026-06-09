# local-whisper

WebSocket sidecar exposing Whisper (MLX-accelerated) as a streaming STT
service, drop-in compatible with how the Sinestesia backend already talks
to ElevenLabs / Deepgram.

- **Server**: Python WebSocket on `ws://127.0.0.1:8002/transcribe`
- **Audio in**: binary PCM frames — 16 kHz, mono, Int16 LE (same as we
  already send to ElevenLabs and Deepgram)
- **Transcripts out**: JSON text frames `{"type": "transcript", "text": "...", "is_final": bool}`

## Why

- Zero per-minute cost (ElevenLabs Scribe was ~$0.05/min).
- ~150ms first-result latency on M-series, no network roundtrip.
- Works offline — useful for stages with crap wifi.
- Multilingual out of the box (Whisper).

## Hardware

Designed for Apple Silicon (M1+). Uses `mlx-whisper` under the hood, which
runs Whisper on the Apple GPU via MLX. On Intel Mac / Linux, swap to
`faster-whisper` (CTranslate2) — same streaming logic applies, only the
inference call changes. PRs welcome.

## Setup

```bash
cd local-whisper
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

If `pip install mlx-whisper` complains about Python version, you need
Python 3.10+. The simplest fix is [uv](https://docs.astral.sh/uv/):

```bash
brew install uv
uv venv --python 3.11
source .venv/bin/activate
uv pip install -r requirements.txt
```

## Run

```bash
python3 server.py
```

You should see:

```
[INFO] loading model: mlx-community/whisper-small-mlx-q4
[INFO] model loaded and warmed
[INFO] listening on ws://127.0.0.1:8002/transcribe
```

First run downloads the model (~250MB for small-q4) into HuggingFace's cache.

## Configuration (env vars)

| Var | Default | Notes |
|---|---|---|
| `WHISPER_MODEL` | `mlx-community/whisper-small-mlx-q4` | any mlx-whisper compatible repo |
| `WHISPER_LANGUAGE` | _unset_ (autodetect) | e.g. `pt`, `en` to force |
| `INTERIM_INTERVAL_MS` | `600` | how often to emit a rolling preview during speech |
| `VAD_SILENCE_MS` | `650` | trailing silence before a segment is finalized |
| `MIN_SPEECH_MS` | `300` | min speech duration before VAD considers it a segment |
| `MAX_BUFFER_SECS` | `20` | safety cap on the audio buffer |
| `BIND_HOST` | `127.0.0.1` | bind address |
| `BIND_PORT` | `8002` | bind port |

### Model choice (M4 Max, q4 quantized)

| Model | Size | Latency per segment | Quality |
|---|---|---|---|
| `tiny` | ~40 MB | ~50 ms | weak, good for VAD-only testing |
| `base` | ~80 MB | ~80 ms | passable |
| `small` | ~250 MB | ~150 ms | **sweet spot for live demos** |
| `medium` | ~770 MB | ~400 ms | very strong, slight latency cost |
| `large-v3` | ~1.5 GB | ~1 s | best quality, breaks the live latency budget |

## Wire into Sinestesia backend

Once the server is running, set in `backend/.env`:

```
STT_PROVIDER=local_whisper
```

(or `STT_PROVIDER=both` to run it alongside ElevenLabs for A/B in the same
session — both transcripts are pushed to the frontend tagged by provider.)

See `backend/lib/sinestesia/local_whisper_stt.ex`.

## Protocol quirks vs ElevenLabs

- We do not stream partial words mid-utterance; each interim is a full
  re-transcription of the buffer. ElevenLabs does the same in `vad` commit
  mode.
- VAD commit boundary is local — there is no server-side `commit_throttled`
  state to worry about.
- We do not currently send a `committed_transcript` message type; an
  `is_final: true` transcript fulfills the same role.
