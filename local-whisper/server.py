"""
Local Whisper STT WebSocket server for Sinestesia.

Drop-in replacement for ElevenLabs / Deepgram streaming STT. Listens on
ws://localhost:8002/transcribe, expects 16kHz Int16 LE PCM as binary frames,
emits JSON transcripts as text frames matching the protocol the backend
already understands:

    {"type": "transcript", "text": "...", "is_final": false}
    {"type": "transcript", "text": "...", "is_final": true}

Uses:
  - mlx-whisper       Metal-accelerated Whisper on Apple Silicon (M1+)
  - openai-whisper    PyTorch backend for ROCm/CUDA GPUs
  - faster-whisper    CPU/CUDA fallback on Linux/Intel
  - silero-vad        Voice activity detection for segment boundaries

Streaming pattern (similar to ElevenLabs Scribe v2 with VAD commit):
  - Buffer incoming PCM into a numpy float32 array
  - Every INTERIM_INTERVAL_MS, transcribe the un-committed buffer and emit
    as is_final=false (rolling preview)
  - Run Silero VAD on the buffer continuously; when silence > VAD_SILENCE_MS
    is detected after speech, transcribe the segment, emit as is_final=true,
    drop the committed audio from the buffer
"""

import asyncio
import json
import logging
import os
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from dataclasses import dataclass, field
from typing import Optional

import numpy as np
import websockets
try:
    import torch
except Exception:
    torch = None

torch_whisper = None
WhisperModel = None
try:
    import mlx_whisper
except Exception:
    mlx_whisper = None

try:
    from faster_whisper import WhisperModel
    from faster_whisper.audio import decode_audio
except Exception:
    WhisperModel = None

try:
    import whisper as torch_whisper
except Exception:
    torch_whisper = None

# silero-vad ships as a small torch model wrapped in a simple Python API.
# It's CPU-light and gives sub-100ms latency on M-series.
from silero_vad import load_silero_vad, get_speech_timestamps

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("local-whisper")

# ──────────────────────────────────────────────────────────────────────────────
# Tunables — most can be overridden via env vars at server start
# ──────────────────────────────────────────────────────────────────────────────

SAMPLE_RATE = 16_000  # MUST match what the backend / browser sends
DEFAULT_BACKEND = "mlx" if mlx_whisper is not None else "torch" if torch is not None else "faster-whisper"
WHISPER_BACKEND = os.environ.get("WHISPER_BACKEND", DEFAULT_BACKEND)
# Default to small, not medium: when SDXL Turbo + Gemma 12B are also sharing
# the Apple GPU, medium's ~400ms-per-interim load starves the other two and
# Director latency balloons from ~1.5s to ~6s. small (~150ms) leaves headroom.
# If you have a dedicated box for STT (no SDXL/Gemma), bump back to medium.
DEFAULT_MODEL = "mlx-community/whisper-small-mlx" if WHISPER_BACKEND == "mlx" else "small"
MODEL_REPO = os.environ.get("WHISPER_MODEL", DEFAULT_MODEL)
FASTER_WHISPER_DEVICE = os.environ.get("FASTER_WHISPER_DEVICE", "cpu")
FASTER_WHISPER_COMPUTE_TYPE = os.environ.get("FASTER_WHISPER_COMPUTE_TYPE", "int8")
faster_model = None
TORCH_WHISPER_DEVICE = os.environ.get(
    "TORCH_WHISPER_DEVICE",
    "cuda" if torch is not None and torch.cuda.is_available() else "cpu",
)
torch_model = None
# Suggested choices (size / latency tradeoff on M4 Max):
#   mlx-community/whisper-tiny-mlx-q4     ~40MB  ~50ms/segment, weakest
#   mlx-community/whisper-base-mlx-q4     ~80MB  ~80ms/segment
#   mlx-community/whisper-small-mlx-q4    ~250MB ~150ms/segment, sweet spot
#   mlx-community/whisper-medium-mlx-q4   ~770MB ~400ms/segment, very strong
#   mlx-community/whisper-large-v3-mlx-q4 ~1.5GB ~1s/segment, slowest

# Auto-detect by default (like ElevenLabs did) so English / Portuguese / etc.
# all work. Set WHISPER_LANGUAGE=pt (or en, es, ...) to FORCE one language and
# skip detection entirely — useful if you KNOW the set list and want to avoid
# any chance of misdetection.
FORCE_LANGUAGE = os.environ.get("WHISPER_LANGUAGE") or None
LANGUAGE_LOCK_MIN_PROB = float(os.environ.get("WHISPER_LANGUAGE_LOCK_MIN_PROB", "0.55"))
LOW_CONFIDENCE_FALLBACK = os.environ.get("WHISPER_LANGUAGE_FALLBACK") or None

# Whisper's language detection is unreliable on <1s of noisy audio (that's what
# produced the Cyrillic "Думафоля" garbage). We only auto-detect once the
# buffer has at least this much audio; until then we hold off on interims.
MIN_DETECT_SECS = float(os.environ.get("MIN_DETECT_SECS", "1.5"))

# 1200ms (was 600): each interim is a full re-transcription of the buffer, so
# halving the cadence halves Whisper's steady-state GPU load. The Director can
# only fire every 5s anyway, so more frequent interims buy nothing here.
INTERIM_INTERVAL_MS = int(os.environ.get("INTERIM_INTERVAL_MS", "1200"))
VAD_SILENCE_MS = int(os.environ.get("VAD_SILENCE_MS", "650"))
MIN_SPEECH_MS = int(os.environ.get("MIN_SPEECH_MS", "300"))
MAX_BUFFER_SECS = float(os.environ.get("MAX_BUFFER_SECS", "20"))
BIND_HOST = os.environ.get("BIND_HOST", "127.0.0.1")
BIND_PORT = int(os.environ.get("BIND_PORT", "8002"))

# ──────────────────────────────────────────────────────────────────────────────


@dataclass
class Session:
    """Per-connection rolling state."""

    # All audio since the last final commit, as float32 in [-1, 1] mono 16kHz.
    audio: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=np.float32))
    last_interim_at: float = 0.0
    last_interim_text: str = ""
    last_speech_end: Optional[float] = None  # seconds offset in `audio` where speech ended
    speech_started: bool = False
    # Language auto-detected from the audio so far. Updated on each final
    # (a full utterance, where detection is reliable). Interims reuse it so
    # they don't flicker. None until the first reliable detection.
    detected_language: Optional[str] = None


def pcm16_to_float32(buf: bytes) -> np.ndarray:
    """Convert little-endian Int16 PCM bytes → float32 numpy array in [-1, 1]."""
    return np.frombuffer(buf, dtype="<i2").astype(np.float32) / 32768.0


def get_faster_model():
    global faster_model
    if WhisperModel is None:
        raise RuntimeError("faster-whisper is not installed")
    if faster_model is None:
        log.info(
            "loading faster-whisper model: %s on %s (%s)",
            MODEL_REPO,
            FASTER_WHISPER_DEVICE,
            FASTER_WHISPER_COMPUTE_TYPE,
        )
        faster_model = WhisperModel(
            MODEL_REPO,
            device=FASTER_WHISPER_DEVICE,
            compute_type=FASTER_WHISPER_COMPUTE_TYPE,
        )
    return faster_model


def get_torch_model():
    global torch_model
    if torch_whisper is None:
        raise RuntimeError("openai-whisper is not installed")
    if torch_model is None:
        log.info("loading torch Whisper model: %s on %s", MODEL_REPO, TORCH_WHISPER_DEVICE)
        torch_model = torch_whisper.load_model(MODEL_REPO, device=TORCH_WHISPER_DEVICE)
    return torch_model


def transcribe(audio: np.ndarray, language: Optional[str]) -> tuple[str, Optional[str], Optional[float]]:
    """Run Whisper on the given mono float32 audio.
    Returns (text, detected_language). `language=None` triggers auto-detect;
    pass an explicit code to skip detection. Errors are swallowed so a bad
    chunk doesn't kill the session."""
    if len(audio) < int(0.2 * SAMPLE_RATE):
        return "", None, None
    try:
        if WHISPER_BACKEND == "mlx":
            result = mlx_whisper.transcribe(
                audio,
                path_or_hf_repo=MODEL_REPO,
                language=language,
                word_timestamps=False,
                condition_on_previous_text=False,
                no_speech_threshold=0.55,
                verbose=False,
            )
            return (result.get("text") or "").strip(), result.get("language"), None

        if WHISPER_BACKEND == "torch":
            result = get_torch_model().transcribe(
                audio.astype(np.float32),
                language=language,
                fp16=TORCH_WHISPER_DEVICE == "cuda",
                condition_on_previous_text=False,
                no_speech_threshold=0.55,
                word_timestamps=False,
                verbose=False,
            )
            return (result.get("text") or "").strip(), result.get("language"), None

        segments, info = get_faster_model().transcribe(
            audio,
            language=language,
            vad_filter=False,
            condition_on_previous_text=False,
            no_speech_threshold=0.55,
            word_timestamps=False,
            language_detection_threshold=LANGUAGE_LOCK_MIN_PROB,
        )
        text = " ".join(segment.text.strip() for segment in segments).strip()
        detected = getattr(info, "language", None)
        probability = getattr(info, "language_probability", None)

        if (
            language is None
            and LOW_CONFIDENCE_FALLBACK
            and detected
            and probability is not None
            and probability < LANGUAGE_LOCK_MIN_PROB
        ):
            log.info(
                "language %s confidence %.2f below %.2f; retrying as %s",
                detected,
                probability,
                LANGUAGE_LOCK_MIN_PROB,
                LOW_CONFIDENCE_FALLBACK,
            )
            segments, info = get_faster_model().transcribe(
                audio,
                language=LOW_CONFIDENCE_FALLBACK,
                vad_filter=False,
                condition_on_previous_text=False,
                no_speech_threshold=0.55,
                word_timestamps=False,
            )
            text = " ".join(segment.text.strip() for segment in segments).strip()
            return text, LOW_CONFIDENCE_FALLBACK, 1.0

        return text, detected, probability
    except Exception:
        log.exception("transcribe failed on %d-sample audio", len(audio))
        return "", None, None


def vad_speech_segments(audio: np.ndarray, vad_model) -> list[dict]:
    """Return Silero VAD's view of speech regions in `audio`. Empty = silence."""
    if len(audio) < int(0.25 * SAMPLE_RATE):
        return []
    try:
        return get_speech_timestamps(
            audio,
            vad_model,
            sampling_rate=SAMPLE_RATE,
            min_silence_duration_ms=200,
            min_speech_duration_ms=int(MIN_SPEECH_MS),
            return_seconds=True,
        )
    except Exception:
        log.exception("VAD failed on %d-sample audio", len(audio))
        return []


def is_hallucinated(text: str) -> bool:
    """Whisper degenerates into repeated tokens on silence/noise (e.g. the
    classic 'E E E E E ...' or 'Thank you. Thank you.'). Drop those so they
    don't poison the Director's bootstrap with garbage."""
    words = text.split()
    if len(words) < 6:
        return False
    unique = set(w.lower() for w in words)
    # If 6+ words collapse to 1-2 distinct tokens, it's a repetition loop.
    return len(unique) <= 2


async def emit(ws, text: str, is_final: bool):
    if not text:
        return
    if is_hallucinated(text):
        log.info("⊘ dropped hallucination: %r", text[:60])
        return
    msg = json.dumps({"type": "transcript", "text": text, "is_final": is_final})
    await ws.send(msg)
    log.info("→ %s: %r", "FIN" if is_final else "int", text)


def resolve_language(session: Session) -> Optional[str]:
    """Which language code to feed mlx-whisper. FORCE_LANGUAGE wins; otherwise
    use what we've detected so far (None = let Whisper auto-detect)."""
    if FORCE_LANGUAGE:
        return FORCE_LANGUAGE
    return session.detected_language


def maybe_learn_language(session: Session, detected: Optional[str], probability: Optional[float]):
    """Cache the detected language the first time we get one (and not forcing)."""
    if FORCE_LANGUAGE or not detected:
        return
    if probability is not None and probability < LANGUAGE_LOCK_MIN_PROB:
        log.info(
            "language candidate %s ignored at confidence %.2f (< %.2f)",
            detected,
            probability,
            LANGUAGE_LOCK_MIN_PROB,
        )
        return
    if session.detected_language != detected:
        if probability is None:
            log.info("language detected: %s", detected)
        else:
            log.info("language detected: %s (confidence %.2f)", detected, probability)
        session.detected_language = detected


async def handle(ws):
    log.info("client connected from %s", ws.remote_address)
    session = Session()
    vad_model = load_silero_vad()

    try:
        async for message in ws:
            now = time.monotonic()

            if isinstance(message, (bytes, bytearray)):
                chunk = pcm16_to_float32(bytes(message))
                if chunk.size == 0:
                    continue
                session.audio = np.concatenate([session.audio, chunk])

                # Cap the buffer so we don't run unbounded if VAD never commits.
                max_samples = int(MAX_BUFFER_SECS * SAMPLE_RATE)
                if len(session.audio) > max_samples:
                    drop = len(session.audio) - max_samples
                    session.audio = session.audio[drop:]
                    log.warning("buffer overflow, dropped %d samples", drop)

                # Check for end-of-utterance via VAD.
                segments = vad_speech_segments(session.audio, vad_model)
                if segments:
                    session.speech_started = True
                    last = segments[-1]
                    buffer_dur = len(session.audio) / SAMPLE_RATE
                    trailing_silence_s = buffer_dur - last["end"]
                    if trailing_silence_s * 1000 >= VAD_SILENCE_MS:
                        # We have a full utterance. Transcribe everything up to
                        # last["end"], emit as final, drop committed audio.
                        cut_sample = int(last["end"] * SAMPLE_RATE)
                        utterance = session.audio[:cut_sample]
                        # Finals are full utterances → auto-detect is reliable here.
                        lang = resolve_language(session)
                        text, detected, probability = await asyncio.get_event_loop().run_in_executor(
                            None, transcribe, utterance, lang
                        )
                        maybe_learn_language(session, detected, probability)
                        await emit(ws, text, is_final=True)
                        session.audio = session.audio[cut_sample:]
                        session.last_interim_text = ""
                        session.last_interim_at = now
                        session.speech_started = False
                        continue

                # Periodic interim while speech is in progress.
                if session.speech_started and (
                    (now - session.last_interim_at) * 1000 >= INTERIM_INTERVAL_MS
                ):
                    lang = resolve_language(session)
                    buffer_secs = len(session.audio) / SAMPLE_RATE

                    # Don't auto-detect on a short buffer — that's what produced
                    # the Cyrillic garbage. Wait until we have enough audio (or
                    # until a final has already locked in the language).
                    if lang is None and buffer_secs < MIN_DETECT_SECS:
                        session.last_interim_at = now
                    else:
                        audio_snapshot = session.audio.copy()
                        text, detected, probability = await asyncio.get_event_loop().run_in_executor(
                            None, transcribe, audio_snapshot, lang
                        )
                        maybe_learn_language(session, detected, probability)
                        if text and text != session.last_interim_text:
                            await emit(ws, text, is_final=False)
                            session.last_interim_text = text
                        session.last_interim_at = now

            else:
                # Text frame — control message. The backend sends {"type":"reset"}
                # when the operator starts a new song, so we drop the buffered
                # audio and re-detect the language for the new performance.
                try:
                    ctrl = json.loads(message)
                except (ValueError, TypeError):
                    log.debug("non-JSON text frame: %r", message)
                    ctrl = {}

                if ctrl.get("type") == "reset":
                    session.audio = np.zeros(0, dtype=np.float32)
                    session.detected_language = None
                    session.last_interim_text = ""
                    session.last_interim_at = 0.0
                    session.speech_started = False
                    log.info("session reset — buffer cleared, language detection reset")

    except websockets.exceptions.ConnectionClosed as e:
        log.info("client disconnected (%s)", e.code)
    except Exception:
        log.exception("handler crashed")
        raise



# ── Batch transcription (HTTP) ───────────────────────────────────────────────
#
# The WebSocket above is the LIVE path: PCM in, partials out, no word timings.
# Turning a finished recording into a replay session (`mix sinestesia.video`)
# needs the opposite — the whole file at once, with per-word timestamps.
#
# It lives here rather than in a separate tool because this is where the model
# already is: one process, one warm model, reachable by the same Elixir
# backend over the host/port it already knows. The transport is a plain HTTP
# POST of the raw wav bytes (no multipart to parse, no new dependency) served
# on LOCAL_WHISPER_BATCH_PORT by a stdlib handler in a daemon thread.
# (A dedicated port, not BIND_PORT+1: that lands on 8003, which is the local
# SDXL sidecar's default — the two run side by side in an offline setup.)


def transcribe_words(audio: np.ndarray, language: Optional[str]) -> list[dict]:
    """Whole-file transcription with word timings, for offline session building."""
    segments, _info = get_faster_model().transcribe(
        audio,
        language=language,
        vad_filter=True,
        word_timestamps=True,
    )

    words: list[dict] = []
    for seg in segments:
        for w in seg.words or []:
            text = w.word.strip()
            if text:
                words.append({"text": text, "start": w.start, "end": w.end})
    return words


class _BatchHandler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 (stdlib naming)
        parsed = urlparse(self.path)
        if parsed.path != "/transcribe_file":
            self.send_error(404, "only /transcribe_file")
            return

        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            self.send_error(400, "empty body (expected raw wav bytes)")
            return

        raw = self.rfile.read(length)
        query = parse_qs(parsed.query)
        language = (query.get("language") or [None])[0] or None

        try:
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=True) as fh:
                fh.write(raw)
                fh.flush()
                # decode_audio gives the mono float32 at SAMPLE_RATE that the
                # model wants, whatever the input wav's layout happened to be.
                audio = decode_audio(fh.name, sampling_rate=SAMPLE_RATE)
            t0 = time.time()
            words = transcribe_words(audio, language)
            log.info(
                "batch: %d words from %.0fs of audio in %.1fs",
                len(words),
                len(audio) / SAMPLE_RATE,
                time.time() - t0,
            )
            body = json.dumps({"words": words}).encode()
        except Exception as e:  # noqa: BLE001 — report, never kill the server
            log.exception("batch transcription failed")
            self.send_error(500, str(e)[:200])
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # the module logger already reports what matters


BATCH_PORT = int(os.environ.get("LOCAL_WHISPER_BATCH_PORT", "8012"))


def start_batch_server(port: int) -> None:
    server = ThreadingHTTPServer((BIND_HOST, port), _BatchHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    log.info("batch transcription on http://%s:%d/transcribe_file", BIND_HOST, port)


async def main():
    log.info("using Whisper backend: %s", WHISPER_BACKEND)
    log.info("loading model: %s", MODEL_REPO)
    # Warm the model so the first transcript isn't penalized.
    _ = transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32), FORCE_LANGUAGE)
    mode = f"forced={FORCE_LANGUAGE}" if FORCE_LANGUAGE else "auto-detect"
    log.info("model loaded and warmed (language: %s)", mode)

    start_batch_server(BATCH_PORT)

    log.info("listening on ws://%s:%d/transcribe", BIND_HOST, BIND_PORT)
    async with websockets.serve(
        handle,
        BIND_HOST,
        BIND_PORT,
        max_size=10 * 1024 * 1024,
        # Disable keepalive ping — we're on localhost (no NAT timeouts) and
        # Mint.WebSocket on the Elixir side doesn't auto-respond to pings,
        # which caused the server to time us out at exactly 40s. The audio
        # stream itself is constant traffic that proves the conn is alive.
        ping_interval=None,
        ping_timeout=None,
    ):
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log.info("bye")
