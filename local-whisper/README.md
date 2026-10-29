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
brew install uv
cd local-whisper
uv venv --managed-python --python 3.11
source .venv/bin/activate
uv pip install -r requirements.txt
```

`--managed-python` matters. Without it, uv takes the first 3.11 it finds on
the machine, and on a Mac that has been migrated from Intel that can be an
x86_64 Homebrew Python under `/usr/local` running through Rosetta. MLX only runs on Apple Silicon.
The symptom is `torch>=2.4.0 has no wheels with a matching platform tag
(e.g. macosx_15_0_x86_64)`, followed later by missing modules. Check with:

```bash
python -c "import platform; print(platform.machine())"   # must print arm64
```

If it prints `x86_64`, run `rm -rf .venv` and repeat the setup.

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
| `WHISPER_MODEL` | `mlx-community/whisper-small-mlx` | any mlx-whisper compatible repo |
| `WHISPER_LANGUAGE` | _unset_ (auto-detect) | set `pt`/`en`/... to FORCE one language and skip detection |
| `MIN_DETECT_SECS` | `1.5` | min audio before trusting auto-detect (avoids misdetection on short/noisy buffers) |
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

## NVIDIA Nemotron (mlx-audio backends)

Two NVIDIA speech models run through this same sidecar on Apple Silicon,
through [mlx-audio](https://github.com/Blaizzy/mlx-audio). Neither is a
Whisper; the env vars keep their `WHISPER_` names because every switch of the
sidecar and of the bench already uses them.

| `WHISPER_BACKEND` | `WHISPER_MODEL` default | what it is | memory |
|---|---|---|---|
| `nemotron-asr` | `mlx-community/nemotron-3.5-asr-streaming-0.6b` | NVIDIA's cache-aware **streaming** FastConformer-RNNT: 40 locales incl. pt-BR, language auto-detected. Built for live audio — the words come out while the phrase is still being sung; the VAD only decides where the phrase ends. | 1.3 GB |
| `nemotron-transcribe` | `nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B` | NVIDIA's 30B-A4B speech LLM (Mamba/MoE, ~4.3B active). An **offline** model — its report: "does not provide native streaming transcription" — so it is driven like Whisper: the VAD cuts phrases, every interim re-decodes the buffer. Promptable: the language is asked of it, with `WHISPER_LANGUAGES` as the labels. | 67.5 GB bf16, ~20 GB at 4-bit |

Install mlx-audio into the venv. PyPI's 0.6.3 (2026-10-28) predates the
Transcribe port, so pin the commit of `main` that has both models:

```bash
cd local-whisper
uv pip install --python .venv/bin/python 'mlx-audio[stt] @ git+https://github.com/Blaizzy/mlx-audio.git@4f1a90ca3d412607df18704c7fd33c380ecb4c4a'
```

### nemotron-asr (streaming, 0.6B)

```bash
WHISPER_BACKEND=nemotron-asr python3 server.py                            # downloads 1.3 GB once
NEMOTRON_LOOKAHEAD_MS=160 WHISPER_BACKEND=nemotron-asr python3 server.py  # faster words, ~1 WER point
```

- `NEMOTRON_LOOKAHEAD_MS` (80 | 160 | 320 | 560 | 1120, default 560): how far
  the encoder looks ahead before committing to a frame — the model was trained
  at each of these. Lower = words appear sooner; NVIDIA's FLEURS table gives up
  about one WER point from 1120 to 80 ms (Portuguese 5.5 → 6.3). Finals do not
  depend on it: at the end of a phrase the session is closed and flushed, so
  the last words come out whatever the look-ahead.
- One RNNT session per phrase: a phrase starts without the previous one as
  left context. Sung phrases are separated by the breath the VAD cut on, so
  that context was mostly silence; it also keeps the decoder's internals out
  of the sidecar, which only calls feed / step / close / cancel.
- `WHISPER_LANGUAGE=pt` pins a locale (`pt` → `pt-BR`; a full locale passes
  through). Otherwise the model detects the language and the sidecar logs the
  `<pt-BR>`-style tag it emits. `WHISPER_LANGUAGES` has no effect here: the
  prompt is one locale, or auto.
- 8-bit build: `WHISPER_MODEL=mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit`.

### nemotron-transcribe (30B-A4B)

The official checkpoint is one 67.5 GB bf16 safetensors file and takes ~66 GB
of memory on MLX. On a 48 GB Mac, quantize the language model to 4-bit first —
the speech and speaker encoders stay unquantized; mlx-audio reports a 20 GB
peak for its 4-bit model:

```bash
hf download nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B --local-dir ~/models/nemotron-transcribe
.venv/bin/python -m mlx_audio.convert --hf-path ~/models/nemotron-transcribe \
  --mlx-path ~/models/nemotron-transcribe-4bit --model-domain stt --quantize --q-bits 4 --q-group-size 64
WHISPER_BACKEND=nemotron-transcribe WHISPER_MODEL=~/models/nemotron-transcribe-4bit python3 server.py
```

Caveats, written down because nobody has run this exact path here yet
(2026-10-29):

- mlx-audio's port was written against NVIDIA's early-access checkpoint
  (`...-EA-0.1.0`, from NGC). The public release has the same `model_type`
  (`nemo_speechlm`), prompt format and 30 s encoder chunking, but carries
  extra weights (the CTC timestamp head, the MTP layers). The sidecar loads
  with `strict=True`, so a weight the port does not know fails loudly at
  start instead of transcribing garbage; if it does, the log names the key.
- Community 4-bit conversions exist and load directly
  (`WHISPER_MODEL=nativ-community/Nemotron-3.5-Transcribe-30B-A4B-EA-4bit`,
  19.3 GB). They are conversions of the early-access weights, published by a
  third party under NVIDIA's *evaluation* license. Safetensors carry no code,
  so the risk is quality, not security: fine for a benchmark row, not for a
  show.
- Word timestamps are not implemented in the port, so the batch endpoint
  (`/transcribe_file`) stays on faster-whisper whatever the realtime backend.
- Speed on a Mac is unmeasured. mlx-audio's own figure: a 54 s clip in 1.6 s
  on an M3 Ultra at 4-bit. What a 3–5 s sung phrase costs on an M3 Max
  (encoder + prompt + a dozen tokens) is what `mix sinestesia.bench.stt`
  will say.

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
